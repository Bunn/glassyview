import CryptoKit
import Foundation
import Security

struct GlassyStreamDeviceIdentity: Equatable, Sendable {
    let privateKey: Data

    var publicKey: Data {
        get throws {
            try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: privateKey
            ).publicKey.rawRepresentation
        }
    }

    var clientIdentifier: Data {
        get throws {
            try GlassyStreamDeviceIdentityDerivation.clientIdentifier(
                publicKey: publicKey
            )
        }
    }
}

enum GlassyStreamDeviceIdentityDerivation {
    static func clientIdentifier(publicKey: Data) throws -> Data {
        guard publicKey.count == GlassyStreamWire.publicKeyLength else {
            throw GlassyStreamCloudEnrollmentError.malformedIdentity
        }
        var material = Data("Glassy iCloud device identity v1\0".utf8)
        material.append(publicKey)
        return Data(SHA256.hash(data: material).prefix(GlassyStreamWire.identifierLength))
    }
}

protocol GlassyStreamDeviceIdentityStoring: Sendable {
    func identity(hostIdentifier: Data) throws -> GlassyStreamDeviceIdentity
}

/// Keeps one stable, private identity for this installation. The key
/// never enters CloudKit; only its public half is placed in an enrollment
/// request. The wire identifier is derived from that public key, allowing the
/// Mac to reject a request whose claimed identity was substituted.
struct GlassyStreamKeychainDeviceIdentityStore: GlassyStreamDeviceIdentityStoring {
    private static let service = "dev.bunn.glassydesk.glassy-stream.device-identity.v1"
    private static let account = "device"
    private static let encodedLength = 40

    func identity(hostIdentifier: Data) throws -> GlassyStreamDeviceIdentity {
        guard hostIdentifier.count == GlassyStreamWire.identifierLength else {
            throw GlassyStreamClientError.credentialStoreFailed(
                "The Glassy Host identity is malformed."
            )
        }

        let query = baseQuery()
        var readQuery = query
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
        switch readStatus {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw GlassyStreamClientError.credentialStoreFailed(
                    "The stored Glassy Stream device identity is unreadable."
                )
            }
            do {
                return try decode(data)
            } catch {
                // A partial restore or interrupted write must not permanently
                // brick both automatic enrollment and explicit QR pairing.
                let deleteStatus = SecItemDelete(query as CFDictionary)
                guard deleteStatus == errSecSuccess
                        || deleteStatus == errSecItemNotFound else {
                    throw storeError(deleteStatus)
                }
            }
        case errSecItemNotFound:
            break
        default:
            throw storeError(readStatus)
        }

        let identity = GlassyStreamDeviceIdentity(
            privateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        )
        var addQuery = query
        addQuery[kSecValueData as String] = encode(identity)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Another connection can win the first-use race. Always use the
            // identity that reached Keychain so concurrent requests agree.
            var retryResult: AnyObject?
            let retryStatus = SecItemCopyMatching(readQuery as CFDictionary, &retryResult)
            guard retryStatus == errSecSuccess, let data = retryResult as? Data else {
                throw storeError(retryStatus)
            }
            return try decode(data)
        }
        guard addStatus == errSecSuccess else {
            throw storeError(addStatus)
        }
        return identity
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false
        ]
    }

    private func encode(_ identity: GlassyStreamDeviceIdentity) -> Data {
        var value = Data("GSDI".utf8)
        value.append(1)
        value.append(contentsOf: [0, 0, 0])
        value.append(identity.privateKey)
        return value
    }

    private func decode(_ data: Data) throws -> GlassyStreamDeviceIdentity {
        guard data.count == Self.encodedLength,
              data.prefix(4) == Data("GSDI".utf8),
              data[data.startIndex + 4] == 1,
              data[(data.startIndex + 5)..<(data.startIndex + 8)].allSatisfy({ $0 == 0 }) else {
            throw GlassyStreamClientError.credentialStoreFailed(
                "The stored Glassy Stream device identity has an unsupported format."
            )
        }

        let identity = GlassyStreamDeviceIdentity(
            privateKey: Data(data[(data.startIndex + 8)..<data.endIndex])
        )
        do {
            _ = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identity.privateKey)
            return identity
        } catch {
            throw GlassyStreamClientError.credentialStoreFailed(
                "The stored Glassy Stream device key is invalid."
            )
        }
    }

    private func storeError(_ status: OSStatus) -> GlassyStreamClientError {
        let message = SecCopyErrorMessageString(status, nil) as String?
            ?? "Keychain status \(status)"
        return .credentialStoreFailed(message)
    }
}
