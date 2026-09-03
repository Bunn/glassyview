import Foundation
import Network

/// Untrusted details read from the Mac's QR code. Authentication still uses the
/// rotating one-time code, and requires explicit confirmation in the pairing UI.
struct GlassyHostPairingInvitation: Equatable, Sendable {
    let host: String
    let port: UInt16
    let name: String
    let code: GlassyHostPairingCode
    let expiresAt: Date

    enum ValidationError: LocalizedError, Equatable {
        case invalidCode
        case expired

        var errorDescription: String? {
            switch self {
            case .invalidCode:
                String(localized: "This isn’t a valid Glassy Host pairing QR code. Scan the code displayed in Glassy Host on your Mac.")
            case .expired:
                String(localized: "This pairing code has expired. Scan the current QR code on your Mac.")
            }
        }
    }

    init(scannedValue: String, now: Date = .now) throws {
        guard scannedValue.utf8.count <= 2_048,
              scannedValue.hasPrefix("glassydesk://pair?"),
              let components = URLComponents(string: scannedValue),
              components.string == scannedValue,
              components.scheme == "glassydesk",
              components.host == "pair",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty,
              components.fragment == nil,
              let items = components.queryItems,
              items.count == 6,
              Set(items.map(\.name)) == ["v", "host", "port", "name", "code", "expires"] else {
            throw ValidationError.invalidCode
        }

        // The key count and set check above reject duplicate and unknown keys.
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["v"] == "1",
              let host = values["host"], Self.isValidHost(host),
              let portText = values["port"], Self.isASCIIDigits(portText),
              let port = UInt16(portText), port > 0,
              let name = values["name"], !name.isEmpty, name.utf8.count <= 255,
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0)
                  || CharacterSet.illegalCharacters.contains($0)
                  || (0x202A...0x202E).contains($0.value)
                  || (0x2066...0x2069).contains($0.value) }),
              let codeText = values["code"], codeText.utf8.count == GlassyHostPairingCode.symbolCount,
              let code = GlassyHostPairingCode(codeText), code.rawValue == codeText,
              let expirationText = values["expires"], expirationText.count <= 11,
              Self.isASCIIDigits(expirationText),
              let expiration = TimeInterval(expirationText), expiration.isFinite,
              expiration <= now.timeIntervalSince1970 + 600 else {
            throw ValidationError.invalidCode
        }

        let expiresAt = Date(timeIntervalSince1970: expiration)
        guard expiresAt > now else { throw ValidationError.expired }
        self.host = host
        self.port = port
        self.name = name
        self.code = code
        self.expiresAt = expiresAt
    }

    var candidate: GlassyStreamEndpointCandidate {
        let address = GlassyStreamDirectAddress(host: host, port: port)
        return GlassyStreamEndpointCandidate(
            id: "qr:\(address.displayValue)",
            name: name,
            detail: address.displayValue,
            source: .direct,
            endpoint: address.endpoint,
            directAddress: address
        )
    }

    /// Match only equivalent direct addresses. A display name is not evidence
    /// that an unpaired, saved Mac and the scanned Mac are the same device.
    func matchesAddress(_ address: GlassyStreamDirectAddress) -> Bool {
        guard port == address.port else { return false }
        if let lhs = IPv6Address(host), let rhs = IPv6Address(address.host) {
            return lhs.rawValue == rhs.rawValue
        }
        if let lhs = IPv4Address(host), let rhs = IPv4Address(address.host) {
            return lhs.rawValue == rhs.rawValue
        }
        func canonicalHost(_ value: String) -> String {
            let lowercase = value.lowercased()
            return lowercase.hasSuffix(".") ? String(lowercase.dropLast()) : lowercase
        }
        return canonicalHost(host) == canonicalHost(address.host)
    }

    private static func isASCIIDigits(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy(\.isASCII) else { return false }
        if IPv4Address(host) != nil || IPv6Address(host) != nil { return true }

        let hostname = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63
                && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (65...90).contains($0)
                    || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}
