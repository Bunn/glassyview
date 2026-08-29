import Foundation
import Network

/// A validated direct address for Glassy Host.
///
/// A Glassy Stream port can be supplied separately or inline (`host:port`).
/// Inline ports take precedence so pasted Tailscale and VPN endpoints work as
/// expected.
struct GlassyStreamDirectAddress: Equatable, Hashable, Sendable {
    let host: String
    let port: UInt16

    /// A conservative, locally checkable Tailscale address marker used to
    /// keep reusable-password bootstrap off unauthenticated Bonjour/raw TCP
    /// routes. Short MagicDNS names are intentionally excluded because they
    /// are indistinguishable from ordinary LAN DNS names before connecting.
    var isRecognizedTailscaleAddress: Bool {
        var normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while normalizedHost.hasSuffix(".") {
            normalizedHost.removeLast()
        }

        if normalizedHost.hasSuffix(".ts.net"),
           normalizedHost.count > ".ts.net".count {
            return true
        }

        if let ipv6Address = IPv6Address(normalizedHost) {
            return ipv6Address.rawValue.prefix(6) == Data([
                0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0
            ])
        }

        guard let ipv4Address = IPv4Address(normalizedHost) else { return false }
        let octets = [UInt8](ipv4Address.rawValue)
        return octets.count == 4
            && octets[0] == 100
            && (64...127).contains(octets[1])
    }

    var endpoint: NWEndpoint {
        .hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
    }

    var displayValue: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

enum GlassyStreamEndpointSource: Equatable, Sendable {
    case direct
    case bonjour

    var title: String {
        switch self {
        case .direct:
            "Direct"
        case .bonjour:
            "Nearby"
        }
    }
}

/// One connection route shown to the user or attempted by the session layer.
struct GlassyStreamEndpointCandidate: Identifiable, @unchecked Sendable {
    let id: String
    let name: String
    let detail: String
    let source: GlassyStreamEndpointSource
    let endpoint: NWEndpoint
    let directAddress: GlassyStreamDirectAddress?
}

/// Creates reliable Glassy Stream routes from persisted and discovered hosts.
enum GlassyStreamEndpoint {
    /// Glassy Host's stable TCP listener in the dynamic/private port range.
    static let defaultPort: UInt16 = 51_515

    private static let supportedSchemes = ["glassystream", "glassy", "tcp"]

    static func isRecognizedTailscaleEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, port) = endpoint,
              let address = directAddress(
                  from: String(describing: host),
                  defaultPort: port.rawValue
              ) else {
            return false
        }
        return address.isRecognizedTailscaleAddress
    }

    /// Returns the persisted Glassy Stream port, migrating records created
    /// while the hidden field still contained VNC's default port.
    static func effectivePort(for machine: SavedMachine) -> UInt16 {
        if machine.connectionMode == .glassyStream,
           machine.port == 0 || machine.port == 5_900 {
            return defaultPort
        }

        return machine.port > 0 ? machine.port : defaultPort
    }

    /// Parses a direct Glassy Host address.
    ///
    /// Accepted forms include `mac-mini`, `100.64.0.2`,
    /// `mac-mini:51515`, `[fd7a:115c:a1e0::1]:51515`, a bare IPv6 address,
    /// and the same forms prefixed by `glassystream://`, `glassy://`, or
    /// `tcp://`. IPv6 ports must use brackets so they are unambiguous.
    static func directAddress(
        from input: String,
        defaultPort: UInt16 = Self.defaultPort
    ) -> GlassyStreamDirectAddress? {
        guard defaultPort > 0 else { return nil }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let schemeSeparator = trimmed.range(of: "://") {
            let scheme = String(trimmed[..<schemeSeparator.lowerBound]).lowercased()
            guard supportedSchemes.contains(scheme) else { return nil }
            return directAddress(fromURLString: trimmed, defaultPort: defaultPort)
        }

        guard !trimmed.contains("/"),
              !trimmed.contains("?"),
              !trimmed.contains("#"),
              !trimmed.contains("@") else {
            return nil
        }

        if trimmed.hasPrefix("[") {
            return directAddress(fromBracketedInput: trimmed, defaultPort: defaultPort)
        }

        let colonCount = trimmed.reduce(into: 0) { count, character in
            if character == ":" { count += 1 }
        }

        switch colonCount {
        case 0:
            return makeAddress(host: trimmed, port: defaultPort)

        case 1:
            guard let separator = trimmed.lastIndex(of: ":") else { return nil }
            let host = String(trimmed[..<separator])
            let portText = String(trimmed[trimmed.index(after: separator)...])
            guard let port = parsePort(portText) else { return nil }
            return makeAddress(host: host, port: port)

        default:
            // A bare IPv6 address never consumes its final component as a
            // port. Callers must use `[address]:port` for an explicit port.
            return makeAddress(host: trimmed, port: defaultPort)
        }
    }

    /// Builds the direct route saved for a machine, if it has a usable host.
    static func directCandidate(for machine: SavedMachine) -> GlassyStreamEndpointCandidate? {
        guard let address = directAddress(
            from: machine.host,
            defaultPort: effectivePort(for: machine)
        ) else {
            return nil
        }

        let name = firstNonempty(
            machine.glassyHostName,
            machine.name,
            address.host
        ) ?? address.host

        return GlassyStreamEndpointCandidate(
            id: "direct:\(address.canonicalIdentity)",
            name: name,
            detail: address.displayValue,
            source: .direct,
            endpoint: address.endpoint,
            directAddress: address
        )
    }

    /// Returns stable connection candidates with the saved direct route first.
    ///
    /// An explicit direct address is authoritative during first pairing. Once
    /// paired, only a Bonjour result whose name exactly matches the
    /// authenticated host is admitted as a fallback. Exact duplicate routes
    /// are removed and deterministic tie-breaks keep picker/retry order stable.
    static func candidates(
        for machine: SavedMachine,
        discoveredHosts: [DiscoveredGlassyHost]
    ) -> [GlassyStreamEndpointCandidate] {
        let pairedHostName = machine.glassyHostName.flatMap(normalizedNonempty)
        let isPaired = hasValidPinnedIdentity(machine.glassyHostIdentifier)
        let preferredNames = [pairedHostName, normalizedNonempty(machine.name)]
            .compactMap { $0 }

        var candidates: [GlassyStreamEndpointCandidate] = []
        var identities = Set<String>()

        if let direct = directCandidate(for: machine) {
            candidates.append(direct)
            identities.insert(endpointIdentity(direct.endpoint))
        }
        let hasDirectCandidate = !candidates.isEmpty

        let discovered = discoveredHosts
            .filter { host in
                if isPaired {
                    // The authenticated host name is the only Bonjour hint
                    // safe enough to use with a pinned host identity. The
                    // identity is still verified during authentication.
                    guard let pairedHostName else { return false }
                    return normalizedName(host.name) == pairedHostName
                }

                // A typed/saved address is explicit user intent. Do not put a
                // different nearby Mac into the first-pairing route list.
                return !hasDirectCandidate
            }
            .sorted { lhs, rhs in
                let lhsPreferred = preferredNames.contains(normalizedName(lhs.name))
                let rhsPreferred = preferredNames.contains(normalizedName(rhs.name))
                if lhsPreferred != rhsPreferred { return lhsPreferred }

                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return endpointIdentity(lhs.endpoint) < endpointIdentity(rhs.endpoint)
            }

        for host in discovered {
            let endpointID = endpointIdentity(host.endpoint)
            let candidateID = "bonjour:\(endpointID)"
            guard identities.insert(endpointID).inserted else { continue }

            candidates.append(
                GlassyStreamEndpointCandidate(
                    id: candidateID,
                    name: host.name,
                    detail: GlassyStreamEndpointSource.bonjour.title,
                    source: .bonjour,
                    endpoint: host.endpoint,
                    directAddress: nil
                )
            )
        }

        return candidates
    }

    private static func directAddress(
        fromURLString input: String,
        defaultPort: UInt16
    ) -> GlassyStreamDirectAddress? {
        guard let components = URLComponents(string: input),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              var host = components.host,
              !host.isEmpty else {
            return nil
        }

        // Foundation currently preserves IPv6 brackets in URLComponents.host
        // on Apple platforms, while other Foundation versions may omit them.
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }

        let port: UInt16
        if let componentPort = components.port {
            guard let parsedPort = UInt16(exactly: componentPort), parsedPort > 0 else {
                return nil
            }
            port = parsedPort
        } else {
            port = defaultPort
        }

        return makeAddress(host: host, port: port)
    }

    private static func directAddress(
        fromBracketedInput input: String,
        defaultPort: UInt16
    ) -> GlassyStreamDirectAddress? {
        guard let closingBracket = input.firstIndex(of: "]") else { return nil }

        let hostStart = input.index(after: input.startIndex)
        let host = String(input[hostStart..<closingBracket])
        let suffixStart = input.index(after: closingBracket)
        let suffix = String(input[suffixStart...])

        if suffix.isEmpty {
            return makeAddress(host: host, port: defaultPort)
        }

        guard suffix.hasPrefix(":"), suffix.dropFirst().allSatisfy(\.isNumber),
              let port = parsePort(String(suffix.dropFirst())) else {
            return nil
        }
        return makeAddress(host: host, port: port)
    }

    private static func makeAddress(
        host: String,
        port: UInt16
    ) -> GlassyStreamDirectAddress? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              port > 0,
              host.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                  !CharacterSet.controlCharacters.contains(scalar)
              }),
              !host.contains("["),
              !host.contains("]") else {
            return nil
        }

        return GlassyStreamDirectAddress(host: host, port: port)
    }

    private static func parsePort(_ value: String) -> UInt16? {
        guard !value.isEmpty,
              value.allSatisfy(\.isNumber),
              let port = UInt16(value),
              port > 0 else {
            return nil
        }
        return port
    }

    private static func endpointIdentity(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case let .hostPort(host, port):
            return "host:\(canonicalHost(String(describing: host))):\(port.rawValue)"

        case let .service(name, type, domain, interface):
            let interfaceDescription = interface.map(String.init(describing:)) ?? ""
            return ["service", name, type, domain, interfaceDescription]
                .map(normalizedName)
                .joined(separator: ":")

        case let .unix(path):
            return "unix:\(path)"

        case let .url(url):
            return "url:\(url.absoluteString.lowercased())"

        case let .opaque(value):
            return "opaque:\(String(describing: value).lowercased())"

        @unknown default:
            return String(describing: endpoint).lowercased()
        }
    }

    private static func firstNonempty(_ values: String?...) -> String? {
        for value in values {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func normalizedNonempty(_ value: String) -> String? {
        let normalized = normalizedName(value)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func hasValidPinnedIdentity(_ encodedIdentifier: String?) -> Bool {
        guard let encodedIdentifier = encodedIdentifier?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
        let identifier = Data(base64Encoded: encodedIdentifier) else {
            return false
        }
        return identifier.count == GlassyStreamWire.identifierLength
    }

    private static func canonicalHost(_ host: String) -> String {
        var normalized = normalizedName(host)
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized
    }
}

private extension GlassyStreamDirectAddress {
    var canonicalIdentity: String {
        var normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while normalizedHost.hasSuffix(".") {
            normalizedHost.removeLast()
        }
        return "\(normalizedHost):\(port)"
    }
}
