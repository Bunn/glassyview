import CommonCrypto
import Foundation

/// Shared client-side policy and key derivation for the optional reusable
/// Glassy Host pairing password. Keep every constant byte-for-byte aligned
/// with the host implementation.
enum GlassyStreamPairingPassword {
    static let minimumUnicodeScalarCount = 15
    static let maximumUnicodeScalarCount = 128
    static let maximumUTF8ByteCount = 512

    private static let iterationCount: UInt32 = 600_000
    private static let derivedCredentialLength = 32
    private static let saltDomain = Data(
        "GlassyStream pairing password PBKDF2-SHA256 v1\0".utf8
    )

    enum ValidationFailure: Equatable, Sendable {
        case tooShort
        case tooLong
        case tooManyBytes
        case containsControlCharacter

        var message: String {
            switch self {
            case .tooShort:
                String(localized: "Use at least \(minimumUnicodeScalarCount) characters.")
            case .tooLong:
                String(localized: "Use no more than \(maximumUnicodeScalarCount) characters.")
            case .tooManyBytes:
                String(localized: "Use a password no larger than \(maximumUTF8ByteCount) UTF-8 bytes.")
            case .containsControlCharacter:
                String(localized: "Passwords cannot contain control characters or line breaks.")
            }
        }
    }

    /// Applies NFC normalization without trimming or changing case.
    static func normalized(_ password: String) -> String {
        password.precomposedStringWithCanonicalMapping
    }

    static func validationFailure(for password: String) -> ValidationFailure? {
        let normalizedPassword = normalized(password)
        let scalarCount = normalizedPassword.unicodeScalars.count

        guard scalarCount >= minimumUnicodeScalarCount else { return .tooShort }
        guard scalarCount <= maximumUnicodeScalarCount else { return .tooLong }
        guard normalizedPassword.utf8.count <= maximumUTF8ByteCount else {
            return .tooManyBytes
        }

        let controls = CharacterSet.controlCharacters
        let newlines = CharacterSet.newlines
        guard normalizedPassword.unicodeScalars.allSatisfy({ scalar in
            !controls.contains(scalar) && !newlines.contains(scalar)
        }) else {
            return .containsControlCharacter
        }

        return nil
    }

    static func validated(_ password: String) -> String? {
        guard validationFailure(for: password) == nil else { return nil }
        return normalized(password)
    }

    static func deriveCredential(
        from password: String,
        hostIdentifier: Data
    ) throws -> Data {
        guard let normalizedPassword = validated(password) else {
            throw GlassyStreamClientError.invalidPairingPassword
        }
        guard hostIdentifier.count == GlassyStreamWire.identifierLength else {
            throw GlassyStreamClientError.protocolViolation(
                "the pairing-password host identifier is not 16 bytes"
            )
        }

        var passwordBytes = Array(normalizedPassword.utf8)
        defer {
            _ = passwordBytes.withUnsafeMutableBytes { bytes in
                bytes.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }

        var salt = saltDomain
        salt.append(hostIdentifier)
        var credential = Data(count: derivedCredentialLength)

        let status = passwordBytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                credential.withUnsafeMutableBytes { credentialBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.bindMemory(to: Int8.self).baseAddress,
                        passwordBuffer.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        saltBuffer.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterationCount,
                        credentialBuffer.bindMemory(to: UInt8.self).baseAddress,
                        credentialBuffer.count
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            credential.resetBytes(in: credential.startIndex..<credential.endIndex)
            throw GlassyStreamClientError.pairingPasswordDerivationFailed(status)
        }
        return credential
    }
}
