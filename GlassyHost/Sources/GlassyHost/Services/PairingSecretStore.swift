import Foundation
import Security

struct PairingSecret: Equatable, Sendable {
    let keyData: Data
}

enum PairingSecretStoreError: LocalizedError {
    case keychain(OSStatus)
    case randomGeneration(OSStatus)
    case invalidFallbackFile

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "The pairing key could not be stored securely (Keychain status \(status))."
        case .randomGeneration(let status):
            "A secure pairing key could not be generated (Security status \(status))."
        case .invalidFallbackFile:
            "The local pairing key file is invalid."
        }
    }
}

struct PairingSecretStore: Sendable {
    private enum StorageMode: Sendable {
        case keychain
        case protectedFile
    }

    private let service = "dev.bunn.glassydesk.host.pairing"
    private let account = "primary-host-key"
    private let storageMode: StorageMode

    init() {
        storageMode = Bundle.main.object(
            forInfoDictionaryKey: "GlassyHostPairingSecretStorage"
        ) as? String == "keychain" ? .keychain : .protectedFile
    }

    func loadOrCreate() throws -> PairingSecret {
        guard storageMode == .keychain else {
            HostLog.security.info(
                "Using an owner-only Application Support pairing credential for this development signature"
            )
            return try loadOrCreateFallbackFile()
        }

        do {
            if let existing = try load() {
                return existing
            }

            return try replaceInKeychain()
        } catch PairingSecretStoreError.keychain(let status)
            where Self.shouldUseFileFallback(for: status) {
            HostLog.security.warning(
                "Keychain identity is unavailable for this local signature; using a protected Application Support key"
            )
            return try loadOrCreateFallbackFile()
        }
    }

    func replace() throws -> PairingSecret {
        guard storageMode == .keychain else {
            let secret = try makeSecret()
            try saveFallbackFile(secret)
            return secret
        }

        do {
            return try replaceInKeychain()
        } catch PairingSecretStoreError.keychain(let status)
            where Self.shouldUseFileFallback(for: status) {
            let secret = try makeSecret()
            try saveFallbackFile(secret)
            return secret
        }
    }

    private func replaceInKeychain() throws -> PairingSecret {
        let secret = try makeSecret()
        try save(secret)
        return secret
    }

    private func makeSecret() throws -> PairingSecret {
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else {
            throw PairingSecretStoreError.randomGeneration(randomStatus)
        }

        return PairingSecret(keyData: Data(bytes))
    }

    private func load() throws -> PairingSecret? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseAuthenticationUI: kSecUseAuthenticationUISkip,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw PairingSecretStoreError.keychain(errSecDecode)
            }
            guard data.count == 32 else { return nil }
            return PairingSecret(keyData: data)
        case errSecItemNotFound:
            return nil
        default:
            throw PairingSecretStoreError.keychain(status)
        }
    }

    private func save(_ secret: PairingSecret) throws {
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseAuthenticationUI: kSecUseAuthenticationUISkip
        ]

        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData: secret.keyData] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw PairingSecretStoreError.keychain(updateStatus)
        }

        var add = identity
        add.removeValue(forKey: kSecUseAuthenticationUI)
        add[kSecValueData] = secret.keyData
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PairingSecretStoreError.keychain(addStatus)
        }
    }

    private func loadOrCreateFallbackFile() throws -> PairingSecret {
        let url = try fallbackFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard data.count == 32 else {
                throw PairingSecretStoreError.invalidFallbackFile
            }
            return PairingSecret(keyData: data)
        }

        let secret = try makeSecret()
        try saveFallbackFile(secret)
        return secret
    }

    private func saveFallbackFile(_ secret: PairingSecret) throws {
        let url = try fallbackFileURL()
        try secret.keyData.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func fallbackFileURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent(
            "GlassyHost",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory.appendingPathComponent("pairing-secret-v1")
    }

    private static func shouldUseFileFallback(for status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed
            || status == errSecAuthFailed
            || status == errSecUserCanceled
    }
}
