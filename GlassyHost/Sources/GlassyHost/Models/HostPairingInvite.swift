import Foundation
import Network
import SystemConfiguration

/// A short-lived pairing invitation understood by the GlassyDesk client.
/// It carries the rotating pairing code, never the host's persistent secret.
struct HostPairingInvite: Equatable, Sendable {
    let host: String
    let port: UInt16
    let name: String
    let code: String
    let expiresAt: Date

    /// Versioned URL understood by the client's in-app pairing scanner.
    /// Invalid fields fail closed instead of producing a partially usable invite.
    var urlString: String? {
        guard Self.isValidHost(host), port > 0,
              !name.isEmpty,
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              name.utf8.count <= 255,
              !name.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
                      || CharacterSet.illegalCharacters.contains($0)
                      || (0x202A...0x202E).contains($0.value)
                      || (0x2066...0x2069).contains($0.value)
              }),
              code.utf8.count == HostProtocol.pairingCodeSymbolCount,
              code.allSatisfy({ "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".contains($0) }) else {
            return nil
        }

        let expiration = expiresAt.timeIntervalSince1970.rounded(.down)
        guard expiration.isFinite, expiration > 0,
              expiration < Double(Int64.max) else { return nil }

        var components = URLComponents()
        components.scheme = "glassydesk"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "expires", value: String(Int64(expiration)))
        ]
        return components.url?.absoluteString
    }

    /// macOS's Bonjour hostname is resolvable from another device on the LAN.
    /// A display name, localhost, or an arbitrary interface address is not a substitute.
    static func localHostAddress() -> String? {
        guard let localName = SCDynamicStoreCopyLocalHostName(nil) as String?,
              !localName.isEmpty else { return nil }
        let address = localName + ".local"
        return isValidHost(address) ? address : nil
    }

    private static func isValidHost(_ host: String) -> Bool {
        if IPv4Address(host) != nil || IPv6Address(host) != nil { return true }
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let lettersAndDigits = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return labels.allSatisfy { label in
            guard let first = label.first, let last = label.last,
                  label.utf8.count <= 63,
                  lettersAndDigits.contains(first), lettersAndDigits.contains(last) else {
                return false
            }
            return label.allSatisfy { lettersAndDigits.contains($0) || $0 == "-" }
        }
    }
}
