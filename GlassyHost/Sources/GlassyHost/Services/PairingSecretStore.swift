import Foundation
import Security

struct PairingSecret: Equatable, Sendable {
    let keyData: Data
}

enum PairingSecretStoreError: LocalizedError {
    case keychain(OSStatus)
    case randomGeneration(OSStatus)
    case invalidFallbackFile
    case invalidKeychainData

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "The pairing key is unavailable (Keychain status \(status)). Unlock your login Keychain or restore Glassy Desk's access, then try again."
        case .randomGeneration(let status):
            "A secure pairing key could not be generated (Security status \(status))."
        case .invalidFallbackFile:
            "The local pairing key file is invalid."
        case .invalidKeychainData:
            "The stored pairing key is invalid. Restore Keychain access or explicitly reset pairing."
        }
    }
}

struct PairingSecretStore: Sendable {
    enum StorageMode: Sendable {
        case keychain
        case protectedFile
    }

    private let storageMode: StorageMode
    private let keychain: any PairingSecretKeychainStoring

    init(storageMode: StorageMode? = nil,
         keychain: any PairingSecretKeychainStoring = SystemPairingSecretKeychain()) {
        self.storageMode = storageMode ?? (Bundle.main.object(
            forInfoDictionaryKey: "GlassyHostPairingSecretStorage"
        ) as? String == "protected-file" ? .protectedFile : .keychain)
        self.keychain = keychain
    }

    func loadOrCreate() throws -> PairingSecret {
        guard storageMode == .keychain else {
            HostLog.security.info(
                "Using an owner-only Application Support pairing credential for this development signature"
            )
            return try loadOrCreateFallbackFile()
        }

        // Keychain errors must never create a second host identity. A locked
        // Keychain or changed signing ACL is recoverable without re-pairing.
        if let data = try keychain.load() {
            guard data.count == 32 else { throw PairingSecretStoreError.invalidKeychainData }
            return PairingSecret(keyData: data)
        }
        return try replaceInKeychain()
    }

    func replace() throws -> PairingSecret {
        guard storageMode == .keychain else {
            let secret = try makeSecret()
            try saveFallbackFile(secret)
            return secret
        }

        return try replaceInKeychain()
    }

    private func replaceInKeychain() throws -> PairingSecret {
        let secret = try makeSecret()
        try keychain.save(secret.keyData)
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
}

/// The production namespace and Security.framework behavior remain isolated
/// here so identity recovery can be tested without accessing a user's keys.
protocol PairingSecretKeychainStoring: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

struct SystemPairingSecretKeychain: PairingSecretKeychainStoring {
    private let service = "dev.bunn.glassydesk.host.pairing"
    private let account = "primary-host-key"

    func load() throws -> Data? {
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
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw PairingSecretStoreError.keychain(status)
        }
    }

    func save(_ data: Data) throws {
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseAuthenticationUI: kSecUseAuthenticationUISkip
        ]

        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw PairingSecretStoreError.keychain(updateStatus)
        }

        var add = identity
        add.removeValue(forKey: kSecUseAuthenticationUI)
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PairingSecretStoreError.keychain(addStatus)
        }
    }

}
