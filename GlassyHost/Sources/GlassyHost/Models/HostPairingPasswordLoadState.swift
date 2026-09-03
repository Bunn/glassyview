import Foundation

/// An optional Keychain read may finish after a local password action or host
/// key rotation. Such an old result must never reinstall its credential.
struct HostPairingPasswordLoadState {
    struct Request: Sendable {
        fileprivate let hostIdentifier: Data
        fileprivate let revision: UUID
    }

    private var revision = UUID()

    mutating func begin(for hostIdentifier: Data) -> Request {
        invalidate()
        return Request(hostIdentifier: hostIdentifier, revision: revision)
    }

    mutating func invalidate() {
        revision = UUID()
    }

    func accepts(_ request: Request, hostIdentifier: Data?) -> Bool {
        request.revision == revision && request.hostIdentifier == hostIdentifier
    }
}
