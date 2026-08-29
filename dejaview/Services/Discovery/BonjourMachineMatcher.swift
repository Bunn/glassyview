import Foundation
import Network

enum BonjourMachineMatcher {
    static func glassyHost(
        matching service: DiscoveredService,
        among hosts: [DiscoveredGlassyHost]
    ) -> DiscoveredGlassyHost? {
        guard let serviceHost = service.host,
              let serviceAddress = CanonicalHost(serviceHost) else {
            return nil
        }

        let addressMatches = hosts.filter { host in
            guard let resolvedHost = host.resolvedHost else { return false }
            return CanonicalHost(resolvedHost) == serviceAddress
        }

        guard !addressMatches.isEmpty else { return nil }

        let logicalMatches = Dictionary(grouping: addressMatches) { host in
            LogicalGlassyHost(
                address: serviceAddress,
                port: host.resolvedPort,
                name: normalizedServiceName(host.name)
            )
        }

        if logicalMatches.count == 1 {
            return logicalMatches.values.first?.sorted(by: { $0.id < $1.id }).first
        }

        let serviceName = normalizedServiceName(service.name)
        let sameNameMatches = logicalMatches.filter { logicalHost, _ in
            logicalHost.name == serviceName
        }

        guard sameNameMatches.count == 1 else { return nil }
        return sameNameMatches.values.first?.sorted(by: { $0.id < $1.id }).first
    }

    private static func normalizedServiceName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}

private struct LogicalGlassyHost: Hashable {
    let address: CanonicalHost
    let port: UInt16?
    let name: String
}

private enum CanonicalHost: Hashable {
    case ipv4(Data)
    case ipv6(Data)
    case name(String)

    init?(_ value: String) {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if normalized.hasPrefix("["), normalized.hasSuffix("]") {
            normalized.removeFirst()
            normalized.removeLast()
        }

        if let scopeIndex = normalized.firstIndex(of: "%") {
            normalized = String(normalized[..<scopeIndex])
        }

        if let address = IPv4Address(normalized) {
            self = .ipv4(address.rawValue)
        } else if let address = IPv6Address(normalized) {
            self = .ipv6(address.rawValue)
        } else {
            self = .name(
                normalized
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    .precomposedStringWithCanonicalMapping
                    .lowercased()
            )
        }
    }
}
