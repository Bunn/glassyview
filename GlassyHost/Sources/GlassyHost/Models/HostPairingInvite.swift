import Foundation
import SystemConfiguration

/// A short-lived pairing invitation understood by the GlassyDesk client.
/// It carries the rotating pairing code, never the host's persistent secret.
struct HostPairingInvite: Equatable, Sendable {
    let host: String
    let port: UInt16
    let name: String
    let code: String
    let expiresAt: Date
    let hostIdentifier: Data
    let alternateHosts: [String]

    init(host: String, port: UInt16, name: String, code: String, expiresAt: Date,
         hostIdentifier: Data, alternateHosts: [String] = []) {
        self.host = host
        self.port = port
        self.name = name
        self.code = code
        self.expiresAt = expiresAt
        self.hostIdentifier = hostIdentifier
        self.alternateHosts = alternateHosts
    }

    /// Versioned URL understood by the client's in-app pairing scanner.
    /// Invalid fields fail closed instead of producing a partially usable invite.
    var urlString: String? {
        let hosts = [host] + alternateHosts
        let normalizedHosts = hosts.compactMap(HostPairingHostAddress.normalized)
        guard hosts.count <= HostPairingAddressPolicy.maximumAddresses,
              normalizedHosts.count == hosts.count,
              Set(normalizedHosts).count == hosts.count,
              hostIdentifier.count == HostProtocol.identifierLength,
              port > 0,
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
            URLQueryItem(name: "v", value: "2"),
            URLQueryItem(name: "host", value: normalizedHosts[0]),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "expires", value: String(Int64(expiration))),
            URLQueryItem(name: "id", value: hostIdentifier.base64EncodedString())
        ] + normalizedHosts.dropFirst().map { URLQueryItem(name: "alt", value: $0) }
        // Preserve standard base64 even if a QR handoff passes through a
        // query decoder that treats an unescaped plus as a form-style space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url?.absoluteString, url.utf8.count <= 2_048 else { return nil }
        return url
    }

    /// Bonjour is a useful LAN fallback. Invitations also carry active numeric
    /// addresses because another network may not resolve this local DNS name.
    static func localHostAddress() -> String? {
        guard let localName = SCDynamicStoreCopyLocalHostName(nil) as String?,
              !localName.isEmpty else { return nil }
        let address = localName + ".local"
        return HostPairingHostAddress.normalized(address)
    }
}
