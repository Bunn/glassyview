import CloudKit
import CryptoKit
import Foundation

enum HostCloudEnrollmentSchema {
    static let containerIdentifier = "iCloud.dev.bunn.dejaview"
    static let zoneName = "GlassyEnrollmentV1"
    static let recordType = "GlassyHostEnrollmentRequestV1"
    static let requestRecordPrefix = "request-"
    static let version: Int64 = 1
    static let requestNonceLength = 32
    static let requestLifetime: TimeInterval = 5 * 60
    static let grantLifetime: TimeInterval = 2 * 60

    static let versionKey = "version"
    static let hostIdentifierKey = "hostIdentifier"
    static let clientIdentifierKey = "clientIdentifier"
    static let deviceNameKey = "deviceName"
    static let clientPublicKeyKey = "clientPublicKey"
    static let requestNonceKey = "requestNonce"
    static let requestedAtKey = "requestedAt"
    static let requestExpiresAtKey = "requestExpiresAt"
    static let fulfilledNonceKey = "fulfilledNonce"
    static let hostEphemeralPublicKeyKey = "hostEphemeralPublicKey"
    static let sealedGrantKey = "sealedGrant"
    static let grantExpiresAtKey = "grantExpiresAt"

    static func requestRecordName(hostIdentifier: Data,
                                  clientIdentifier: Data) -> String {
        requestRecordPrefix + hex(hostIdentifier) + "-" + hex(clientIdentifier)
    }

    static func keyDerivationInfo(hostIdentifier: Data,
                                  clientIdentifier: Data,
                                  requestNonce: Data,
                                  grantExpiresAtMilliseconds: UInt64) -> Data {
        var value = Data("Glassy Host cloud enrollment v1\0".utf8)
        appendBigEndian(UInt64(version), to: &value)
        value.append(hostIdentifier)
        value.append(clientIdentifier)
        value.append(requestNonce)
        appendBigEndian(grantExpiresAtMilliseconds, to: &value)
        return value
    }

    static func clientIdentifier(publicKey: Data) -> Data {
        var identity = Data("Glassy iCloud device identity v1\0".utf8)
        identity.append(publicKey)
        return Data(SHA256.hash(data: identity).prefix(HostProtocol.identifierLength))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func appendBigEndian(_ integer: UInt64, to data: inout Data) {
        var bigEndian = integer.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

enum HostCloudEnrollmentAvailability {
    static var hasEmbeddedProvisioningProfile: Bool {
        FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL
                .appendingPathComponent("Contents/embedded.provisionprofile")
                .path
        )
    }
}

struct HostCloudEnrollmentEnvelope: Equatable, Sendable {
    let hostEphemeralPublicKey: Data
    let sealedGrant: Data

    static func seal(grant: Data,
                     hostIdentifier: Data,
                     clientIdentifier: Data,
                     clientPublicKey: Data,
                     requestNonce: Data,
                     grantExpiresAtMilliseconds: UInt64,
                     privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) throws -> Self {
        guard grant.count == HostProtocol.enrollmentGrantLength,
              hostIdentifier.count == HostProtocol.identifierLength,
              clientIdentifier.count == HostProtocol.identifierLength,
              clientPublicKey.count == HostProtocol.publicKeyLength,
              requestNonce.count == HostCloudEnrollmentSchema.requestNonceLength else {
            throw HostProtocol.ProtocolError.invalidAuthentication
        }

        let clientKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: clientPublicKey
        )
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: clientKey)
        let encryptionKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: requestNonce,
            sharedInfo: HostCloudEnrollmentSchema.keyDerivationInfo(
                hostIdentifier: hostIdentifier,
                clientIdentifier: clientIdentifier,
                requestNonce: requestNonce,
                grantExpiresAtMilliseconds: grantExpiresAtMilliseconds
            ),
            outputByteCount: 32
        )
        let authenticatedData = HostCloudEnrollmentSchema.keyDerivationInfo(
            hostIdentifier: hostIdentifier,
            clientIdentifier: clientIdentifier,
            requestNonce: requestNonce,
            grantExpiresAtMilliseconds: grantExpiresAtMilliseconds
        )
        let sealedBox = try AES.GCM.seal(
            grant,
            using: encryptionKey,
            authenticating: authenticatedData
        )
        guard let combined = sealedBox.combined else {
            throw HostProtocol.ProtocolError.invalidAuthentication
        }
        return Self(
            hostEphemeralPublicKey: privateKey.publicKey.rawRepresentation,
            sealedGrant: combined
        )
    }
}

/// Watches a private CloudKit zone for requests created by Glassy Desk devices
/// signed into the same Apple Account. Responses contain an X25519/AES-GCM
/// envelope, so another device in the account cannot read the one-time grant.
@MainActor
final class HostCloudEnrollmentService {
    private struct Request {
        let record: CKRecord
        let clientIdentifier: Data
        let clientPublicKey: Data
        let nonce: Data
        let expiresAt: Date
    }

    private static let idlePollInterval: TimeInterval = 60
    private static let fastPollDelays: [Duration] = [
        .zero, .seconds(1), .seconds(2), .seconds(3)
    ]
    // The burst itself spans six seconds. A twelve-second start-to-start gate
    // caps hostile refreshes while guaranteeing a new arrival waits at most
    // six seconds, inside the client's eight-second enrollment budget.
    private static let fastPollCooldown: TimeInterval = 12
    private static let maximumRetryInterval: TimeInterval = 30

    private let database: CKDatabase
    private let deviceAccessStore: HostDeviceAccessStore
    private let grantStore: HostEnrollmentGrantStore
    private let zoneID = CKRecordZone.ID(
        zoneName: HostCloudEnrollmentSchema.zoneName,
        ownerName: CKCurrentUserDefaultName
    )

    private var monitorTask: Task<Void, Never>?
    private var fastPollTask: Task<Void, Never>?
    private var activeGeneration: UUID?
    private var activeHostIdentifier: Data?
    private var changeToken: CKServerChangeToken?
    private var isZoneReady = false
    private var retryInterval: TimeInterval = 1
    private var retryNotBefore: Date?
    private var nextFastPollAt = Date.distantPast
    private var synchronizingGenerations: Set<UUID> = []
    private var requestedSynchronizations: Set<UUID> = []

    init(container: CKContainer = CKContainer(
        identifier: HostCloudEnrollmentSchema.containerIdentifier
    ),
         deviceAccessStore: HostDeviceAccessStore,
         grantStore: HostEnrollmentGrantStore) {
        database = container.privateCloudDatabase
        self.deviceAccessStore = deviceAccessStore
        self.grantStore = grantStore
    }

    deinit {
        monitorTask?.cancel()
        fastPollTask?.cancel()
    }

    func start(hostIdentifier: Data) {
        guard hostIdentifier.count == HostProtocol.identifierLength else { return }
        monitorTask?.cancel()
        fastPollTask?.cancel()
        let generation = UUID()
        activeGeneration = generation
        activeHostIdentifier = hostIdentifier
        changeToken = nil
        isZoneReady = false
        retryInterval = 1
        retryNotBefore = nil
        nextFastPollAt = .distantPast
        synchronizingGenerations.removeAll()
        requestedSynchronizations.removeAll()
        fastPollTask = nil
        grantStore.removeAll()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.monitorOnce(
                    generation: generation
                ) else { return }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        fastPollTask?.cancel()
        monitorTask = nil
        fastPollTask = nil
        activeGeneration = nil
        activeHostIdentifier = nil
        changeToken = nil
        isZoneReady = false
        retryNotBefore = nil
        synchronizingGenerations.removeAll()
        requestedSynchronizations.removeAll()
        grantStore.removeAll()
    }

    /// Opens a short, coalesced polling window when a device reaches the TCP
    /// listener. CloudKit has no always-on polling cost while the host is idle,
    /// but a request created alongside route selection is still answered fast.
    func requestFastPoll() {
        guard let generation = activeGeneration,
              activeHostIdentifier != nil,
              fastPollTask == nil else { return }
        let delay = max(0, nextFastPollAt.timeIntervalSinceNow)
        nextFastPollAt = Date().addingTimeInterval(
            delay + Self.fastPollCooldown
        )
        fastPollTask = Task { [weak self] in
            do {
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
                for pollDelay in Self.fastPollDelays {
                    if pollDelay != .zero {
                        try await Task.sleep(for: pollDelay)
                    }
                    guard let self,
                          self.isActive(generation: generation) else { return }
                    await self.synchronize(generation: generation)
                }
            } catch {
                return
            }
            guard let self, self.isActive(generation: generation) else { return }
            self.fastPollTask = nil
        }
    }

    private func monitorOnce(generation: UUID) async -> TimeInterval? {
        guard isActive(generation: generation) else { return nil }
        await synchronize(generation: generation)
        guard isActive(generation: generation) else { return nil }
        return max(
            0.1,
            retryNotBefore?.timeIntervalSinceNow
                ?? Self.idlePollInterval
        )
    }

    private func synchronize(generation: UUID) async {
        guard isActive(generation: generation) else { return }
        if synchronizingGenerations.contains(generation) {
            requestedSynchronizations.insert(generation)
            return
        }
        if let retryNotBefore, retryNotBefore > Date() { return }

        synchronizingGenerations.insert(generation)
        defer {
            synchronizingGenerations.remove(generation)
            if requestedSynchronizations.remove(generation) != nil,
               isActive(generation: generation) {
                Task { [weak self] in
                    await self?.synchronize(generation: generation)
                }
            }
        }

        do {
            guard let hostIdentifier = activeHostIdentifier else { return }
            if !isZoneReady {
                try await ensureZone()
                guard isActive(generation: generation) else { return }
                isZoneReady = true
            }
            try await fetchChanges(
                hostIdentifier: hostIdentifier,
                generation: generation
            )
            guard isActive(generation: generation) else { return }
            retryInterval = 1
            retryNotBefore = nil
        } catch is CancellationError {
            return
        } catch {
            guard isActive(generation: generation) else { return }
            if Self.containsCloudError(error, codes: [.zoneNotFound, .userDeletedZone]) {
                changeToken = nil
                isZoneReady = false
                retryNotBefore = nil
                requestedSynchronizations.insert(generation)
                return
            }
            if Self.containsCloudError(error, codes: [.changeTokenExpired]) {
                changeToken = nil
                retryNotBefore = nil
                requestedSynchronizations.insert(generation)
                return
            }
            let delay = max(
                0.1,
                Self.cloudRetryDelay(error) ?? retryInterval
            )
            retryNotBefore = Date().addingTimeInterval(delay)
            retryInterval = min(
                max(delay * 2, retryInterval * 2),
                Self.maximumRetryInterval
            )
            HostLog.security.debug(
                "Private iCloud enrollment is temporarily unavailable: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func ensureZone() async throws {
        let result = try await database.modifyRecordZones(
            saving: [CKRecordZone(zoneID: zoneID)],
            deleting: []
        )
        guard let saved = result.saveResults[zoneID] else {
            throw CKError(.internalError)
        }
        _ = try saved.get()
    }

    private func fetchChanges(hostIdentifier: Data,
                              generation: UUID) async throws {
        var nextToken = changeToken
        repeat {
            let changes = try await database.recordZoneChanges(
                inZoneWith: zoneID,
                since: nextToken
            )
            guard isActive(generation: generation) else {
                throw CancellationError()
            }
            for result in changes.modificationResultsByID.values {
                let modification = try result.get()
                try await process(
                    modification.record,
                    hostIdentifier: hostIdentifier,
                    generation: generation
                )
            }
            nextToken = changes.changeToken
            guard isActive(generation: generation) else {
                throw CancellationError()
            }
            changeToken = nextToken
            if !changes.moreComing { return }
        } while !Task.isCancelled
    }

    private func process(_ record: CKRecord,
                         hostIdentifier: Data,
                         generation: UUID,
                         now: Date = Date()) async throws {
        guard isActive(generation: generation) else {
            throw CancellationError()
        }
        if let expiredRequest = expiredRequestBinding(
            in: record,
            hostIdentifier: hostIdentifier,
            now: now
        ) {
            grantStore.remove(
                clientIdentifier: expiredRequest.clientIdentifier,
                requestNonce: expiredRequest.requestNonce
            )
            // Deleting only by record ID has no change-tag precondition and
            // could erase a fresh request that replaced this stale change.
            // The client overwrites its deterministic record on the next try.
            return
        }
        guard let request = validatedRequest(
            from: record,
            hostIdentifier: hostIdentifier,
            now: now
        ) else { return }
        guard deviceAccessStore.permitsCloudEnrollment(
            identifier: request.clientIdentifier
        ) else {
            HostLog.security.notice("Ignored iCloud enrollment for a revoked device identity")
            return
        }

        let requestedGrantExpiry = min(
            request.expiresAt,
            now.addingTimeInterval(HostCloudEnrollmentSchema.grantLifetime)
        )
        let grantExpiryMilliseconds = UInt64(
            (requestedGrantExpiry.timeIntervalSince1970 * 1_000).rounded()
        )
        let grantExpiry = Date(
            timeIntervalSince1970: TimeInterval(grantExpiryMilliseconds) / 1_000
        )
        guard isActive(generation: generation) else {
            throw CancellationError()
        }
        let grant = try grantStore.issue(
            clientIdentifier: request.clientIdentifier,
            requestNonce: request.nonce,
            expiresAt: grantExpiry,
            now: now
        )
        let envelope = try HostCloudEnrollmentEnvelope.seal(
            grant: grant,
            hostIdentifier: hostIdentifier,
            clientIdentifier: request.clientIdentifier,
            clientPublicKey: request.clientPublicKey,
            requestNonce: request.nonce,
            grantExpiresAtMilliseconds: grantExpiryMilliseconds
        )

        request.record[HostCloudEnrollmentSchema.fulfilledNonceKey] = request.nonce as CKRecordValue
        request.record[HostCloudEnrollmentSchema.hostEphemeralPublicKeyKey] =
            envelope.hostEphemeralPublicKey as CKRecordValue
        request.record.encryptedValues[HostCloudEnrollmentSchema.sealedGrantKey] =
            envelope.sealedGrant as CKRecordValue
        request.record[HostCloudEnrollmentSchema.grantExpiresAtKey] = grantExpiry as CKRecordValue

        guard isActive(generation: generation) else {
            throw CancellationError()
        }
        let result = try await database.modifyRecords(
            saving: [request.record],
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
        guard let saved = result.saveResults[request.record.recordID] else {
            throw CKError(.internalError)
        }
        _ = try saved.get()
        guard isActive(generation: generation) else {
            throw CancellationError()
        }
        HostLog.security.info("Issued a one-time private iCloud enrollment grant")
    }

    private func isActive(generation: UUID) -> Bool {
        activeGeneration == generation && !Task.isCancelled
    }

    private static func containsCloudError(_ error: Error,
                                           codes: Set<CKError.Code>) -> Bool {
        let cloudError = error as NSError
        if cloudError.domain == CKErrorDomain,
           let code = CKError.Code(rawValue: cloudError.code),
           codes.contains(code) {
            return true
        }
        guard let partialErrors = cloudError.userInfo[CKPartialErrorsByItemIDKey]
                as? [AnyHashable: NSError] else { return false }
        return partialErrors.values.contains {
            containsCloudError($0, codes: codes)
        }
    }

    private static func cloudRetryDelay(_ error: Error) -> TimeInterval? {
        let cloudError = error as NSError
        if let delay = cloudError.userInfo[CKErrorRetryAfterKey] as? NSNumber {
            return delay.doubleValue
        }
        guard let partialErrors = cloudError.userInfo[CKPartialErrorsByItemIDKey]
                as? [AnyHashable: NSError] else { return nil }
        return partialErrors.values.compactMap(cloudRetryDelay).max()
    }

    private func expiredRequestBinding(in record: CKRecord,
                                       hostIdentifier: Data,
                                       now: Date) -> (
        clientIdentifier: Data,
        requestNonce: Data
    )? {
        guard record.recordType == HostCloudEnrollmentSchema.recordType,
              let requestedHost = record[HostCloudEnrollmentSchema.hostIdentifierKey] as? Data,
              requestedHost == hostIdentifier,
              let clientIdentifier = record[HostCloudEnrollmentSchema.clientIdentifierKey] as? Data,
              clientIdentifier.count == HostProtocol.identifierLength,
              let requestNonce = record[HostCloudEnrollmentSchema.requestNonceKey] as? Data,
              requestNonce.count == HostCloudEnrollmentSchema.requestNonceLength,
              record.recordID.recordName == HostCloudEnrollmentSchema.requestRecordName(
                hostIdentifier: hostIdentifier,
                clientIdentifier: clientIdentifier
              ) else { return nil }
        let requestExpiry = record[HostCloudEnrollmentSchema.requestExpiresAtKey] as? Date
        let grantExpiry = record[HostCloudEnrollmentSchema.grantExpiresAtKey] as? Date
        guard requestExpiry.map({ $0 <= now }) == true
                || grantExpiry.map({ $0 <= now }) == true else { return nil }
        return (clientIdentifier, requestNonce)
    }

    private func validatedRequest(from record: CKRecord,
                                  hostIdentifier: Data,
                                  now: Date) -> Request? {
        guard record.recordType == HostCloudEnrollmentSchema.recordType,
              (record[HostCloudEnrollmentSchema.versionKey] as? NSNumber)?.int64Value
                == HostCloudEnrollmentSchema.version,
              let requestedHost = record[HostCloudEnrollmentSchema.hostIdentifierKey] as? Data,
              requestedHost == hostIdentifier,
              let clientIdentifier = record[HostCloudEnrollmentSchema.clientIdentifierKey] as? Data,
              clientIdentifier.count == HostProtocol.identifierLength,
              record.recordID.recordName == HostCloudEnrollmentSchema.requestRecordName(
                hostIdentifier: hostIdentifier,
                clientIdentifier: clientIdentifier
              ),
              let deviceName = record[HostCloudEnrollmentSchema.deviceNameKey] as? String,
              !deviceName.isEmpty,
              deviceName.utf8.count <= 512,
              let clientPublicKey = record[HostCloudEnrollmentSchema.clientPublicKeyKey] as? Data,
              clientPublicKey.count == HostProtocol.publicKeyLength,
              clientIdentifier == HostCloudEnrollmentSchema.clientIdentifier(
                publicKey: clientPublicKey
              ),
              let requestNonce = record[HostCloudEnrollmentSchema.requestNonceKey] as? Data,
              requestNonce.count == HostCloudEnrollmentSchema.requestNonceLength,
              let requestedAt = record[HostCloudEnrollmentSchema.requestedAtKey] as? Date,
              let requestedExpiry = record[HostCloudEnrollmentSchema.requestExpiresAtKey] as? Date,
              let serverModifiedAt = record.modificationDate,
              serverModifiedAt >= now.addingTimeInterval(-HostCloudEnrollmentSchema.requestLifetime),
              requestedAt >= now.addingTimeInterval(-HostCloudEnrollmentSchema.requestLifetime),
              requestedAt <= now.addingTimeInterval(30),
              requestedAt <= requestedExpiry,
              requestedExpiry <= requestedAt.addingTimeInterval(
                HostCloudEnrollmentSchema.requestLifetime
              ),
              requestedExpiry > now,
              (record[HostCloudEnrollmentSchema.fulfilledNonceKey] as? Data) != requestNonce else {
            return nil
        }
        return Request(
            record: record,
            clientIdentifier: clientIdentifier,
            clientPublicKey: clientPublicKey,
            nonce: requestNonce,
            expiresAt: requestedExpiry
        )
    }
}
