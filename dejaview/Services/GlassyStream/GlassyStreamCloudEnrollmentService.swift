@preconcurrency import CloudKit
import CryptoKit
import Foundation
import Security

protocol GlassyStreamCloudEnrollmentGrantProviding: Sendable {
    func requestGrant(
        hostIdentifier: Data,
        identity: GlassyStreamDeviceIdentity,
        deviceName: String
    ) async throws -> Data?
}

struct GlassyStreamNoCloudEnrollmentGrantProvider: GlassyStreamCloudEnrollmentGrantProviding {
    func requestGrant(
        hostIdentifier: Data,
        identity: GlassyStreamDeviceIdentity,
        deviceName: String
    ) async throws -> Data? {
        nil
    }
}

enum GlassyStreamCloudEnrollmentError: Error, LocalizedError, Sendable {
    case accountUnavailable
    case malformedIdentity
    case malformedResponse
    case responseExpired

    var errorDescription: String? {
        switch self {
        case .accountUnavailable:
            String(localized: "iCloud is not available for automatic Glassy Host approval.")
        case .malformedIdentity:
            String(localized: "This device could not create a valid Glassy Host enrollment identity.")
        case .malformedResponse:
            String(localized: "Glassy Host returned an invalid iCloud enrollment response.")
        case .responseExpired:
            String(localized: "The iCloud enrollment response expired before it could be used.")
        }
    }
}

enum GlassyStreamCloudEnrollmentSchema {
    static let containerIdentifier = DejaViewModelContainer.cloudKitContainerIdentifier
    static let zoneName = "GlassyEnrollmentV1"
    static let recordType = "GlassyHostEnrollmentRequestV1"
    static let version: Int64 = 1
    static let requestLifetime: TimeInterval = 5 * 60
    static let maximumGrantLifetime: TimeInterval = 5 * 60

    static let versionField = "version"
    static let hostIdentifierField = "hostIdentifier"
    static let clientIdentifierField = "clientIdentifier"
    static let deviceNameField = "deviceName"
    static let clientPublicKeyField = "clientPublicKey"
    static let requestNonceField = "requestNonce"
    static let requestedAtField = "requestedAt"
    static let requestExpiresAtField = "requestExpiresAt"
    static let fulfilledNonceField = "fulfilledNonce"
    static let hostEphemeralPublicKeyField = "hostEphemeralPublicKey"
    static let sealedGrantField = "sealedGrant"
    static let grantExpiresAtField = "grantExpiresAt"

    static let zoneID = CKRecordZone.ID(
        zoneName: zoneName,
        ownerName: CKCurrentUserDefaultName
    )

    static func recordID(hostIdentifier: Data, clientIdentifier: Data) -> CKRecord.ID {
        CKRecord.ID(
            recordName: "request-\(hostIdentifier.hexString)-\(clientIdentifier.hexString)",
            zoneID: zoneID
        )
    }
}

enum GlassyStreamCloudEnrollmentCrypto {
    private static let contextDomain = Data("Glassy Host cloud enrollment v1\0".utf8)

    static func context(
        version: Int64,
        hostIdentifier: Data,
        clientIdentifier: Data,
        requestNonce: Data,
        grantExpiresAt: Date
    ) throws -> Data {
        guard version == GlassyStreamCloudEnrollmentSchema.version,
              hostIdentifier.count == GlassyStreamWire.identifierLength,
              clientIdentifier.count == GlassyStreamWire.identifierLength,
              requestNonce.count == GlassyStreamWire.nonceLength else {
            throw GlassyStreamCloudEnrollmentError.malformedResponse
        }

        let milliseconds = grantExpiresAt.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds <= Double(UInt64.max) else {
            throw GlassyStreamCloudEnrollmentError.malformedResponse
        }

        var value = contextDomain
        value.appendBigEndian(UInt64(version))
        value.append(hostIdentifier)
        value.append(clientIdentifier)
        value.append(requestNonce)
        value.appendBigEndian(UInt64(milliseconds.rounded()))
        return value
    }

    static func openGrant(
        sealedGrant: Data,
        hostEphemeralPublicKey: Data,
        identity: GlassyStreamDeviceIdentity,
        hostIdentifier: Data,
        clientIdentifier: Data,
        requestNonce: Data,
        grantExpiresAt: Date,
        now: Date = .now
    ) throws -> Data {
        guard grantExpiresAt > now,
              grantExpiresAt.timeIntervalSince(now)
                <= GlassyStreamCloudEnrollmentSchema.maximumGrantLifetime else {
            throw GlassyStreamCloudEnrollmentError.responseExpired
        }
        guard hostEphemeralPublicKey.count == GlassyStreamWire.publicKeyLength else {
            throw GlassyStreamCloudEnrollmentError.malformedResponse
        }

        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let publicKey: Curve25519.KeyAgreement.PublicKey
        do {
            privateKey = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: identity.privateKey
            )
            publicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: hostEphemeralPublicKey
            )
        } catch {
            throw GlassyStreamCloudEnrollmentError.malformedResponse
        }

        let context = try context(
            version: GlassyStreamCloudEnrollmentSchema.version,
            hostIdentifier: hostIdentifier,
            clientIdentifier: clientIdentifier,
            requestNonce: requestNonce,
            grantExpiresAt: grantExpiresAt
        )
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: requestNonce,
            sharedInfo: context,
            outputByteCount: 32
        )
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: sealedGrant)
            let grant = try AES.GCM.open(
                sealedBox,
                using: key,
                authenticating: context
            )
            guard grant.count == GlassyStreamWire.enrollmentGrantLength else {
                throw GlassyStreamCloudEnrollmentError.malformedResponse
            }
            return grant
        } catch let error as GlassyStreamCloudEnrollmentError {
            throw error
        } catch {
            throw GlassyStreamCloudEnrollmentError.malformedResponse
        }
    }
}

/// Exchanges a device-bound request through the user's private CloudKit
/// database. Glassy Host encrypts a short-lived, one-time grant to the public
/// key in the request; another device on the same Apple Account can see the
/// record but cannot decrypt the credential.
actor GlassyStreamCloudEnrollmentService: GlassyStreamCloudEnrollmentGrantProviding {
    private enum ReusableRequest {
        case pending(Data)
    }

    private let container: CKContainer
    private let database: CKDatabase
    private let waitDuration: Duration
    private var hasPreparedZone = false

    init(
        containerIdentifier: String = GlassyStreamCloudEnrollmentSchema.containerIdentifier,
        waitDuration: Duration = .seconds(8)
    ) {
        let container = CKContainer(identifier: containerIdentifier)
        self.container = container
        database = container.privateCloudDatabase
        self.waitDuration = waitDuration
    }

    func requestGrant(
        hostIdentifier: Data,
        identity: GlassyStreamDeviceIdentity,
        deviceName: String
    ) async throws -> Data? {
        let clientIdentifier = try identity.clientIdentifier
        let clientPublicKey = try identity.publicKey
        guard hostIdentifier.count == GlassyStreamWire.identifierLength,
              clientIdentifier.count == GlassyStreamWire.identifierLength,
              clientPublicKey.count == GlassyStreamWire.publicKeyLength else {
            throw GlassyStreamCloudEnrollmentError.malformedIdentity
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: waitDuration)
        do {
            return try await requestGrant(
                hostIdentifier: hostIdentifier,
                clientIdentifier: clientIdentifier,
                clientPublicKey: clientPublicKey,
                identity: identity,
                deviceName: deviceName,
                deadline: deadline,
                clock: clock
            )
        } catch {
            guard isMissingZone(error), clock.now < deadline else { throw error }
            // A user can delete the private database zone while this actor is
            // alive. Invalidate the cached setup and retry once within the same
            // overall request budget.
            hasPreparedZone = false
            return try await requestGrant(
                hostIdentifier: hostIdentifier,
                clientIdentifier: clientIdentifier,
                clientPublicKey: clientPublicKey,
                identity: identity,
                deviceName: deviceName,
                deadline: deadline,
                clock: clock
            )
        }
    }

    private func requestGrant(
        hostIdentifier: Data,
        clientIdentifier: Data,
        clientPublicKey: Data,
        identity: GlassyStreamDeviceIdentity,
        deviceName: String,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async throws -> Data? {
        guard clock.now < deadline else { return nil }

        let accountStatus = try await container.accountStatus()
        try Task.checkCancellation()
        guard accountStatus == .available else {
            throw GlassyStreamCloudEnrollmentError.accountUnavailable
        }
        guard clock.now < deadline else { return nil }
        try await prepareZoneIfNeeded()
        try Task.checkCancellation()
        guard clock.now < deadline else { return nil }

        let now = Date.now
        let recordID = GlassyStreamCloudEnrollmentSchema.recordID(
            hostIdentifier: hostIdentifier,
            clientIdentifier: clientIdentifier
        )
        let storedRecord = try await existingRecord(withID: recordID)
        try Task.checkCancellation()
        guard clock.now < deadline else { return nil }
        let requestNonce: Data
        if let storedRecord,
           let reusable = try? reusableRequest(
               from: storedRecord,
               hostIdentifier: hostIdentifier,
               clientIdentifier: clientIdentifier,
               clientPublicKey: clientPublicKey,
               now: now
           ) {
            switch reusable {
            case let .pending(nonce):
                requestNonce = nonce
            }
            // Touch a still-live request on every connection attempt. If the
            // Mac previously had Connections disabled (or was offline), its
            // CloudKit change token may already be past the original write.
            // Updating these fields creates a fresh change without replacing
            // the nonce or racing a concurrently written response.
            storedRecord[GlassyStreamCloudEnrollmentSchema.deviceNameField] =
                sanitizedDeviceName(deviceName) as NSString
            storedRecord[GlassyStreamCloudEnrollmentSchema.requestedAtField] = now as NSDate
            storedRecord[GlassyStreamCloudEnrollmentSchema.requestExpiresAtField] =
                now.addingTimeInterval(
                    GlassyStreamCloudEnrollmentSchema.requestLifetime
                ) as NSDate
            try await saveChangedKeys(storedRecord)
            try Task.checkCancellation()
            guard clock.now < deadline else { return nil }
        } else {
            requestNonce = try secureRandomData(count: GlassyStreamWire.nonceLength)
            let requestExpiresAt = now.addingTimeInterval(
                GlassyStreamCloudEnrollmentSchema.requestLifetime
            )
            let record = storedRecord ?? CKRecord(
                recordType: GlassyStreamCloudEnrollmentSchema.recordType,
                recordID: recordID
            )

            record[GlassyStreamCloudEnrollmentSchema.versionField] = NSNumber(
                value: GlassyStreamCloudEnrollmentSchema.version
            )
            record[GlassyStreamCloudEnrollmentSchema.hostIdentifierField] = hostIdentifier as NSData
            record[GlassyStreamCloudEnrollmentSchema.clientIdentifierField] = clientIdentifier as NSData
            record[GlassyStreamCloudEnrollmentSchema.deviceNameField] = sanitizedDeviceName(deviceName) as NSString
            record[GlassyStreamCloudEnrollmentSchema.clientPublicKeyField] = clientPublicKey as NSData
            record[GlassyStreamCloudEnrollmentSchema.requestNonceField] = requestNonce as NSData
            record[GlassyStreamCloudEnrollmentSchema.requestedAtField] = now as NSDate
            record[GlassyStreamCloudEnrollmentSchema.requestExpiresAtField] = requestExpiresAt as NSDate
            record[GlassyStreamCloudEnrollmentSchema.fulfilledNonceField] = nil
            record[GlassyStreamCloudEnrollmentSchema.hostEphemeralPublicKeyField] = nil
            record[GlassyStreamCloudEnrollmentSchema.grantExpiresAtField] = nil
            record.encryptedValues[GlassyStreamCloudEnrollmentSchema.sealedGrantField] = nil
            try await saveChangedKeys(record)
            try Task.checkCancellation()
            guard clock.now < deadline else { return nil }
        }

        var delay = Duration.milliseconds(200)
        while clock.now < deadline {
            try Task.checkCancellation()
            let response = try await existingRecord(withID: recordID)
            try Task.checkCancellation()
            if let response,
               let grant = try grant(
                   from: response,
                   hostIdentifier: hostIdentifier,
                   clientIdentifier: clientIdentifier,
                   requestNonce: requestNonce,
                   identity: identity
               ) {
                // Keep the response until the host accepts the grant. The
                // authenticated path removes it; deleting here can make a
                // cancelled connection consume another attempt's response.
                return grant
            }

            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { break }
            try await Task.sleep(for: min(delay, remaining))
            delay = min(delay * 2, .seconds(1))
        }
        return nil
    }

    private func prepareZoneIfNeeded() async throws {
        guard !hasPreparedZone else { return }
        let zone = CKRecordZone(zoneID: GlassyStreamCloudEnrollmentSchema.zoneID)
        let result = try await database.modifyRecordZones(
            saving: [zone],
            deleting: []
        )
        guard let saveResult = result.saveResults[zone.zoneID] else {
            throw GlassyStreamCloudEnrollmentError.malformedResponse
        }
        _ = try saveResult.get()
        hasPreparedZone = true
    }

    private func existingRecord(withID recordID: CKRecord.ID) async throws -> CKRecord? {
        let results = try await database.records(for: [recordID])
        guard let result = results[recordID] else { return nil }
        do {
            return try result.get()
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func saveChangedKeys(_ record: CKRecord) async throws {
        let result = try await database.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .changedKeys,
            atomically: true
        )
        guard let saveResult = result.saveResults[record.recordID] else {
            throw GlassyStreamCloudEnrollmentError.malformedResponse
        }
        _ = try saveResult.get()
    }

    private func isMissingZone(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == CKErrorDomain,
           nsError.code == CKError.zoneNotFound.rawValue
            || nsError.code == CKError.userDeletedZone.rawValue {
            return true
        }
        guard let partialErrors = nsError.userInfo[CKPartialErrorsByItemIDKey]
                as? [AnyHashable: NSError] else {
            return false
        }
        return partialErrors.values.contains { isMissingZone($0) }
    }

    private func grant(
        from record: CKRecord,
        hostIdentifier: Data,
        clientIdentifier: Data,
        requestNonce: Data,
        identity: GlassyStreamDeviceIdentity
    ) throws -> Data? {
        guard let fulfilledNonce = record[
            GlassyStreamCloudEnrollmentSchema.fulfilledNonceField
        ] as? Data else {
            return nil
        }
        guard fulfilledNonce == requestNonce,
              (record[GlassyStreamCloudEnrollmentSchema.versionField] as? NSNumber)?.int64Value
                == GlassyStreamCloudEnrollmentSchema.version,
              record[GlassyStreamCloudEnrollmentSchema.hostIdentifierField] as? Data
                == hostIdentifier,
              record[GlassyStreamCloudEnrollmentSchema.clientIdentifierField] as? Data
                == clientIdentifier,
              let hostEphemeralPublicKey = record[
                  GlassyStreamCloudEnrollmentSchema.hostEphemeralPublicKeyField
              ] as? Data,
              let sealedGrant = record.encryptedValues[
                  GlassyStreamCloudEnrollmentSchema.sealedGrantField
              ] as? Data,
              let grantExpiresAt = record[
                  GlassyStreamCloudEnrollmentSchema.grantExpiresAtField
              ] as? Date else {
            throw GlassyStreamCloudEnrollmentError.malformedResponse
        }

        return try GlassyStreamCloudEnrollmentCrypto.openGrant(
            sealedGrant: sealedGrant,
            hostEphemeralPublicKey: hostEphemeralPublicKey,
            identity: identity,
            hostIdentifier: hostIdentifier,
            clientIdentifier: clientIdentifier,
            requestNonce: requestNonce,
            grantExpiresAt: grantExpiresAt
        )
    }

    private func reusableRequest(
        from record: CKRecord,
        hostIdentifier: Data,
        clientIdentifier: Data,
        clientPublicKey: Data,
        now: Date
    ) throws -> ReusableRequest {
        guard (record[GlassyStreamCloudEnrollmentSchema.versionField] as? NSNumber)?.int64Value
                == GlassyStreamCloudEnrollmentSchema.version,
              record[GlassyStreamCloudEnrollmentSchema.hostIdentifierField] as? Data
                == hostIdentifier,
              record[GlassyStreamCloudEnrollmentSchema.clientIdentifierField] as? Data
                == clientIdentifier,
              record[GlassyStreamCloudEnrollmentSchema.clientPublicKeyField] as? Data
                == clientPublicKey,
              let requestNonce = record[
                  GlassyStreamCloudEnrollmentSchema.requestNonceField
              ] as? Data,
              requestNonce.count == GlassyStreamWire.nonceLength,
              let requestedAt = record[
                  GlassyStreamCloudEnrollmentSchema.requestedAtField
              ] as? Date,
              let requestExpiresAt = record[
                  GlassyStreamCloudEnrollmentSchema.requestExpiresAtField
              ] as? Date,
              requestedAt <= now.addingTimeInterval(30),
              requestedAt >= now.addingTimeInterval(
                  -GlassyStreamCloudEnrollmentSchema.requestLifetime
              ),
              requestExpiresAt > now,
              requestExpiresAt <= requestedAt.addingTimeInterval(
                  GlassyStreamCloudEnrollmentSchema.requestLifetime + 1
              ) else {
            throw GlassyStreamCloudEnrollmentError.malformedResponse
        }

        guard record[GlassyStreamCloudEnrollmentSchema.fulfilledNonceField] == nil else {
            // Grants are one-time credentials. A response retained from an
            // earlier connection may already have been consumed even when its
            // AuthenticationAccepted packet never reached this device.
            throw GlassyStreamCloudEnrollmentError.malformedResponse
        }
        return .pending(requestNonce)
    }

    private func sanitizedDeviceName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "Glassy Desk" : trimmed).prefix(128))
    }

    private func secureRandomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw GlassyStreamClientError.credentialStoreFailed(
                SecCopyErrorMessageString(status, nil) as String?
                    ?? "Security status \(status)"
            )
        }
        return data
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    mutating func appendBigEndian<Integer: FixedWidthInteger>(_ value: Integer) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
