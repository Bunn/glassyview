import CryptoKit
import Foundation

/// Durable device permissions. Credential salts are public diversification
/// values; the root secret remains in the existing protected credential store.
/// A revoked record is retained even after it disappears from the device list.
final class HostDeviceAccessStore: @unchecked Sendable {
    private struct Device: Codable {
        let identifier: Data
        var name: String
        var lastConnectedAt: Date
        var resumeSalt: Data?
        var isRevoked: Bool
    }

    private struct State: Codable {
        var version = 1
        var allowsConnections = true
        var permitsLegacyResume = true
        var devices: [Device] = []

        static var failClosed: State {
            State(allowsConnections: false, permitsLegacyResume: false)
        }
    }

    private let lock = NSLock()
    private let fileURL: URL
    private var state: State

    init(fileURL: URL = defaultFileURL) {
        self.fileURL = fileURL
        do {
            let data = try Data(contentsOf: fileURL)
            let loaded = try JSONDecoder().decode(State.self, from: data)
            guard loaded.version == 1,
                  loaded.devices.allSatisfy({
                      $0.identifier.count == HostProtocol.identifierLength
                          && ($0.resumeSalt == nil || $0.resumeSalt?.count == 32)
                  }),
                  Set(loaded.devices.map(\.identifier)).count == loaded.devices.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            state = loaded
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            state = State()
        } catch {
            // Never turn damaged or unreadable revocation data into permission
            // to reuse an old credential. The owner can enable connections and
            // pair devices again using a fresh code or password.
            state = .failClosed
            HostLog.security.error("Could not read device permissions; connections are disabled")
        }
    }

    var allowsConnections: Bool {
        lock.withLock { state.allowsConnections }
    }

    func pairedDevices(connectedIdentifiers: Set<Data> = []) -> [HostPairedDevice] {
        lock.withLock {
            state.devices.filter { !$0.isRevoked }.map { device in
                HostPairedDevice(
                    id: device.identifier,
                    name: device.name,
                    lastConnectedAt: device.lastConnectedAt,
                    isConnected: connectedIdentifiers.contains(device.identifier)
                )
            }.sorted {
                if $0.isConnected != $1.isConnected { return $0.isConnected }
                return $0.lastConnectedAt > $1.lastConnectedAt
            }
        }
    }

    func setAllowsConnections(_ allowsConnections: Bool) throws {
        try update { $0.allowsConnections = allowsConnections }
    }

    /// Call only after validating the encrypted handshake proof. Bootstrap
    /// pairing is the only operation that can grant a revoked identity access.
    func recordAuthentication(identifier: Data,
                              name: String,
                              isBootstrapPairing: Bool,
                              at date: Date = Date()) throws {
        guard identifier.count == HostProtocol.identifierLength else {
            throw HostProtocol.ProtocolError.invalidAuthentication
        }
        try update { state in
            guard state.allowsConnections else {
                throw HostProtocol.ProtocolError.invalidAuthentication
            }
            if let index = state.devices.firstIndex(where: { $0.identifier == identifier }) {
                guard isBootstrapPairing || !state.devices[index].isRevoked else {
                    throw HostProtocol.ProtocolError.invalidAuthentication
                }
                state.devices[index].name = Self.displayName(name)
                state.devices[index].lastConnectedAt = date
                state.devices[index].isRevoked = false
            } else {
                guard isBootstrapPairing || state.permitsLegacyResume else {
                    throw HostProtocol.ProtocolError.invalidAuthentication
                }
                state.devices.append(Device(
                    identifier: identifier,
                    name: Self.displayName(name),
                    lastConnectedAt: date,
                    resumeSalt: isBootstrapPairing ? Self.makeResumeSalt() : nil,
                    isRevoked: false
                ))
            }
        }
    }

    /// Cloud enrollment may create a new device or refresh an active one, but
    /// it never overrides an explicit revocation. QR/password pairing remains
    /// available when the owner wants to restore that identity.
    func recordCloudEnrollmentAuthentication(identifier: Data,
                                             name: String,
                                             at date: Date = Date()) throws {
        guard identifier.count == HostProtocol.identifierLength else {
            throw HostProtocol.ProtocolError.invalidAuthentication
        }
        try update { state in
            guard state.allowsConnections else {
                throw HostProtocol.ProtocolError.invalidAuthentication
            }
            if let index = state.devices.firstIndex(where: { $0.identifier == identifier }) {
                guard !state.devices[index].isRevoked else {
                    throw HostProtocol.ProtocolError.invalidAuthentication
                }
                state.devices[index].name = Self.displayName(name)
                state.devices[index].lastConnectedAt = date
            } else {
                state.devices.append(Device(
                    identifier: identifier,
                    name: Self.displayName(name),
                    lastConnectedAt: date,
                    resumeSalt: Self.makeResumeSalt(),
                    isRevoked: false
                ))
            }
        }
    }

    func permitsCloudEnrollment(identifier: Data) -> Bool {
        lock.withLock {
            guard state.allowsConnections,
                  identifier.count == HostProtocol.identifierLength else { return false }
            return state.devices.first(where: { $0.identifier == identifier })?.isRevoked != true
        }
    }

    func revoke(identifier: Data) throws {
        try update { state in
            guard let index = state.devices.firstIndex(where: { $0.identifier == identifier }) else {
                return
            }
            state.devices[index].isRevoked = true
            // Rotating the derivation salt also invalidates the old credential
            // after a later code/password pairing restores this identity.
            state.devices[index].resumeSalt = Self.makeResumeSalt()
        }
    }

    func resumeSecret(rootSecret: SymmetricKey, identifier: Data) throws -> Data {
        try lock.withLock {
            guard state.allowsConnections,
                  identifier.count == HostProtocol.identifierLength else {
                throw HostProtocol.ProtocolError.invalidAuthentication
            }
            guard let device = state.devices.first(where: { $0.identifier == identifier }) else {
                guard state.permitsLegacyResume else {
                    throw HostProtocol.ProtocolError.invalidAuthentication
                }
                return try HostProtocol.resumeSecret(rootSecret: rootSecret, clientIdentifier: identifier)
            }
            guard !device.isRevoked else {
                throw HostProtocol.ProtocolError.invalidAuthentication
            }
            guard let salt = device.resumeSalt else {
                return try HostProtocol.resumeSecret(rootSecret: rootSecret, clientIdentifier: identifier)
            }
            var info = Data("GlassyHost revocable client resume secret v1\0".utf8)
            info.append(identifier)
            let key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: rootSecret,
                salt: salt,
                info: info,
                outputByteCount: HostProtocol.resumeSecretLength
            )
            return key.withUnsafeBytes { Data($0) }
        }
    }

    func removeAllDevices() throws {
        try update {
            $0.devices.removeAll()
            $0.permitsLegacyResume = false
        }
    }

    private func update(_ mutation: (inout State) throws -> Void) throws {
        try lock.withLock {
            var updated = state
            try mutation(&updated)
            let data = try JSONEncoder().encode(updated)
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: fileURL, options: .atomic)
            state = updated
            // Permission metadata must not roll back the in-memory permission
            // after an atomic write has already committed the revocation.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    private static func makeResumeSalt() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    private static func displayName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Glassy device" : String(cleaned.prefix(100))
    }

    private static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlassyHost", isDirectory: true)
            .appendingPathComponent("device-access-v1.json")
    }
}
