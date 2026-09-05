import CommonCrypto
import Foundation
import Security

enum PairingPasswordPolicyError: LocalizedError, Equatable {
    case invalidHostIdentifier
    case tooShort
    case tooLong
    case tooManyUTF8Bytes
    case containsControlCharacter
    case derivationFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidHostIdentifier:
            "The Glassy Desk identity is invalid."
        case .tooShort:
            "Use at least 15 characters."
        case .tooLong:
            "Use no more than 128 characters."
        case .tooManyUTF8Bytes:
            "The password is too large when encoded. Use at most 512 UTF-8 bytes."
        case .containsControlCharacter:
            "The password cannot contain line breaks or control characters."
        case .derivationFailed(let status):
            "The secure password credential could not be derived (status \(status))."
        }
    }
}

enum PairingPasswordPolicy {
    static let minimumUnicodeScalarCount = 15
    static let maximumUnicodeScalarCount = 128
    static let maximumUTF8ByteCount = 512
    static let derivedCredentialLength = 32
    static let derivationRounds: UInt32 = 600_000

    private static let saltPrefix = Data(
        "GlassyStream pairing password PBKDF2-SHA256 v1\0".utf8
    )

    /// Applies only NFC normalization. Spaces and case are significant, and
    /// no trimming or case folding is performed.
    static func normalizedPassword(_ password: String) throws -> String {
        let normalized = password.precomposedStringWithCanonicalMapping
        let scalarCount = normalized.unicodeScalars.count
        guard scalarCount >= minimumUnicodeScalarCount else {
            throw PairingPasswordPolicyError.tooShort
        }
        guard scalarCount <= maximumUnicodeScalarCount else {
            throw PairingPasswordPolicyError.tooLong
        }

        let disallowedScalars = CharacterSet.controlCharacters.union(.newlines)
        guard !normalized.unicodeScalars.contains(where: disallowedScalars.contains) else {
            throw PairingPasswordPolicyError.containsControlCharacter
        }

        guard normalized.utf8.count <= maximumUTF8ByteCount else {
            throw PairingPasswordPolicyError.tooManyUTF8Bytes
        }
        return normalized
    }

    static func deriveCredential(
        from password: String,
        hostIdentifier: Data
    ) throws -> Data {
        guard hostIdentifier.count == HostProtocol.identifierLength else {
            throw PairingPasswordPolicyError.invalidHostIdentifier
        }

        let normalized = try normalizedPassword(password)
        var passwordBytes = Array(normalized.utf8)
        defer {
            _ = passwordBytes.withUnsafeMutableBytes { bytes in
                bytes.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
        var salt = saltPrefix
        salt.append(hostIdentifier)
        var credential = Data(repeating: 0, count: derivedCredentialLength)

        let status = passwordBytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                credential.withUnsafeMutableBytes { credentialBuffer in
                    CCKeyDerivationPBKDF(
                        UInt32(kCCPBKDF2),
                        passwordBuffer.bindMemory(to: Int8.self).baseAddress,
                        passwordBuffer.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        saltBuffer.count,
                        UInt32(kCCPRFHmacAlgSHA256),
                        derivationRounds,
                        credentialBuffer.bindMemory(to: UInt8.self).baseAddress,
                        credentialBuffer.count
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            credential.resetBytes(in: credential.startIndex..<credential.endIndex)
            throw PairingPasswordPolicyError.derivationFailed(status)
        }
        return credential
    }
}

enum PairingPasswordStoreError: LocalizedError, Equatable {
    case invalidHostIdentifier
    case invalidCredential
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidHostIdentifier:
            return "The Glassy Desk identity is invalid."
        case .invalidCredential:
            return "The stored pairing password credential is invalid. Set the password again."
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain status \(status)"
            return "The pairing password could not be accessed securely: \(detail)"
        }
    }
}

/// Stores only the password-derived credential. The original password is never
/// persisted, and the item is kept in the user's encrypted macOS login
/// Keychain without opting into iCloud synchronization. The standalone host
/// currently has no provisioning profile, so it deliberately targets the
/// file-based Keychain rather than the entitlement-gated Data Protection one.
struct PairingPasswordStore: Sendable {
    private static let service = "dev.bunn.glassydesk.host.pairing-password.v1"

    func credential(for hostIdentifier: Data) throws -> Data? {
        var query = try baseQuery(for: hostIdentifier)
        query[kSecUseAuthenticationUI] = kSecUseAuthenticationUISkip
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let credential = result as? Data,
                  credential.count == PairingPasswordPolicy.derivedCredentialLength else {
                throw PairingPasswordStoreError.invalidCredential
            }
            return credential
        case errSecItemNotFound:
            return nil
        default:
            throw PairingPasswordStoreError.keychain(status)
        }
    }

    func save(_ credential: Data, for hostIdentifier: Data) throws {
        guard credential.count == PairingPasswordPolicy.derivedCredentialLength else {
            throw PairingPasswordStoreError.invalidCredential
        }

        var identity = try baseQuery(for: hostIdentifier)
        identity[kSecUseAuthenticationUI] = kSecUseAuthenticationUISkip
        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData: credential] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw PairingPasswordStoreError.keychain(updateStatus)
        }

        identity.removeValue(forKey: kSecUseAuthenticationUI)
        identity[kSecValueData] = credential
        let addStatus = SecItemAdd(identity as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PairingPasswordStoreError.keychain(addStatus)
        }
    }

    func deleteCredential(for hostIdentifier: Data) throws {
        let status = SecItemDelete(try baseQuery(for: hostIdentifier) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PairingPasswordStoreError.keychain(status)
        }
    }

    private func baseQuery(for hostIdentifier: Data) throws -> [CFString: Any] {
        guard hostIdentifier.count == HostProtocol.identifierLength else {
            throw PairingPasswordStoreError.invalidHostIdentifier
        }
        let hostHex = hostIdentifier.map { String(format: "%02x", $0) }.joined()
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: "host-\(hostHex)",
            kSecAttrSynchronizable: false
        ]
    }
}
