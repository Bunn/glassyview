import Foundation
import Security

/// Short-lived, one-time credentials issued through the user's private
/// CloudKit database. A grant is bound to one device identity and is removed
/// only after its authenticated proof succeeds.
final class HostEnrollmentGrantStore: @unchecked Sendable {
    private struct Entry {
        let requestNonce: Data
        let grant: Data
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var entries: [Data: Entry] = [:]

    func issue(clientIdentifier: Data,
               requestNonce: Data,
               expiresAt: Date,
               now: Date = Date()) throws -> Data {
        guard clientIdentifier.count == HostProtocol.identifierLength,
              requestNonce.count == HostCloudEnrollmentSchema.requestNonceLength,
              expiresAt > now else {
            throw HostProtocol.ProtocolError.invalidAuthentication
        }

        return try lock.withLock {
            pruneLocked(at: now)
            if let existing = entries[clientIdentifier],
               existing.requestNonce == requestNonce {
                entries[clientIdentifier] = Entry(
                    requestNonce: requestNonce,
                    grant: existing.grant,
                    expiresAt: expiresAt
                )
                return existing.grant
            }

            var grant = Data(count: HostProtocol.enrollmentGrantLength)
            let status = grant.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let baseAddress = bytes.baseAddress else { return errSecParam }
                return SecRandomCopyBytes(kSecRandomDefault, bytes.count, baseAddress)
            }
            guard status == errSecSuccess else {
                throw HostProtocol.ProtocolError.invalidAuthentication
            }
            entries[clientIdentifier] = Entry(
                requestNonce: requestNonce,
                grant: grant,
                expiresAt: expiresAt
            )
            return grant
        }
    }

    func credential(clientIdentifier: Data, now: Date = Date()) throws -> Data {
        try lock.withLock {
            pruneLocked(at: now)
            guard let entry = entries[clientIdentifier] else {
                throw HostProtocol.ProtocolError.invalidAuthentication
            }
            return entry.grant
        }
    }

    /// Atomically proves that the credential is still live and consumes it.
    /// This closes the race between two connections presenting one grant.
    func consume(clientIdentifier: Data,
                 credential: Data,
                 now: Date = Date()) -> Bool {
        lock.withLock {
            pruneLocked(at: now)
            guard let entry = entries[clientIdentifier],
                  entry.grant == credential else { return false }
            entries.removeValue(forKey: clientIdentifier)
            return true
        }
    }

    func removeAll() {
        lock.withLock {
            entries.removeAll()
        }
    }

    func remove(clientIdentifier: Data) {
        _ = lock.withLock {
            entries.removeValue(forKey: clientIdentifier)
        }
    }

    func remove(clientIdentifier: Data, requestNonce: Data) {
        lock.withLock {
            guard entries[clientIdentifier]?.requestNonce == requestNonce else { return }
            _ = entries.removeValue(forKey: clientIdentifier)
        }
    }

    func prune(at date: Date = Date()) {
        lock.withLock {
            pruneLocked(at: date)
        }
    }

    private func pruneLocked(at date: Date) {
        entries = entries.filter { $0.value.expiresAt > date }
    }
}
