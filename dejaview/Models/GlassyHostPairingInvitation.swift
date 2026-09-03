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
    let expectedHostIdentifier: Data?
    let addresses: [GlassyStreamDirectAddress]

    var alternateAddresses: [GlassyStreamDirectAddress] { Array(addresses.dropFirst()) }

    enum ValidationError: LocalizedError, Equatable {
        case invalidCode
        case expired
        case unsupportedVersion

        var errorDescription: String? {
            switch self {
            case .invalidCode:
                String(localized: "This isn’t a valid Glassy Host pairing QR code. Scan the code displayed in Glassy Host on your Mac.")
            case .expired:
                String(localized: "This pairing code has expired. Scan the current QR code on your Mac.")
            case .unsupportedVersion:
                String(localized: "This Glassy Host uses a newer pairing format. Update Glassy Desk, then scan the QR code again.")
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
              let items = components.queryItems, items.count <= 14 else {
            throw ValidationError.invalidCode
        }

        let versionItems = items.filter { $0.name == "v" }
        guard versionItems.count == 1,
              let version = versionItems[0].value else { throw ValidationError.invalidCode }
        guard version == "1" || version == "2" else {
            guard Self.isCanonicalPositiveInteger(version) else {
                throw ValidationError.invalidCode
            }
            throw ValidationError.unsupportedVersion
        }
        let requiredKeys: Set<String> = version == "1"
            ? ["v", "host", "port", "name", "code", "expires"]
            : ["v", "host", "port", "name", "code", "expires", "id"]
        let requiredItems = items.filter { $0.name != "alt" }
        let alternateItems = items.filter { $0.name == "alt" }
        guard requiredItems.count == requiredKeys.count,
              Set(requiredItems.map(\.name)) == requiredKeys,
              alternateItems.count <= 7,
              version == "2" || alternateItems.isEmpty else { throw ValidationError.invalidCode }

        // Only `alt` may repeat, and it is unavailable in the legacy format.
        let values = Dictionary(uniqueKeysWithValues: requiredItems.map { ($0.name, $0.value ?? "") })
        guard let host = values["host"], Self.isValidHost(host),
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
        let expectedHostIdentifier: Data?
        if version == "2" {
            guard let encodedIdentifier = values["id"], encodedIdentifier.utf8.count == 24,
                  let identifier = Data(base64Encoded: encodedIdentifier), identifier.count == 16,
                  identifier.base64EncodedString() == encodedIdentifier else {
                throw ValidationError.invalidCode
            }
            expectedHostIdentifier = identifier
        } else {
            expectedHostIdentifier = nil
        }
        var addresses = [GlassyStreamDirectAddress(host: host, port: port)]
        var identities = Set(addresses.map(\.canonicalIdentity))
        for item in alternateItems {
            guard let alternateHost = item.value, Self.isValidHost(alternateHost) else {
                throw ValidationError.invalidCode
            }
            let address = GlassyStreamDirectAddress(host: alternateHost, port: port)
            guard identities.insert(address.canonicalIdentity).inserted else {
                throw ValidationError.invalidCode
            }
            addresses.append(address)
        }
        self.host = host
        self.port = port
        self.name = name
        self.code = code
        self.expiresAt = expiresAt
        self.expectedHostIdentifier = expectedHostIdentifier
        self.addresses = addresses
    }

    var candidate: GlassyStreamEndpointCandidate {
        let address = GlassyStreamDirectAddress(host: host, port: port)
        return GlassyStreamEndpointCandidate(
            id: "qr:\(address.displayValue)",
            name: name,
            detail: address.displayValue,
            source: .direct,
            endpoint: address.endpoint,
            directAddress: address,
            expectedHostIdentifier: expectedHostIdentifier,
            alternateAddresses: alternateAddresses
        )
    }

    /// Match only equivalent direct addresses. A display name is not evidence
    /// that an unpaired, saved Mac and the scanned Mac are the same device.
    func matchesAddress(_ address: GlassyStreamDirectAddress) -> Bool {
        addresses.contains { $0.canonicalIdentity == address.canonicalIdentity }
    }

    private static func isASCIIDigits(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func isCanonicalPositiveInteger(_ value: String) -> Bool {
        guard value.utf8.count <= 20,
              isASCIIDigits(value),
              let number = UInt64(value), number > 0 else { return false }
        return String(number) == value
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.contains("%"),
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
