import Darwin
import Foundation
import Network
import SystemConfiguration

/// Reads addresses assigned to this Mac, including point-to-point VPN
/// interfaces. No VPN account, SDK, or private configuration is required.
final class HostPairingAddressService: @unchecked Sendable {
    typealias Handler = @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "dev.bunn.glassydesk.host.pairing-addresses", qos: .utility)
    private let monitor = NWPathMonitor()
    private let snapshotProvider: @Sendable () -> [String]
    private let refreshInterval: DispatchTimeInterval
    private var timer: DispatchSourceTimer?
    private var handler: Handler?
    private var lastAddresses: [String]?

    init(snapshotProvider: @escaping @Sendable () -> [String] = HostPairingAddressService.currentAddresses,
         refreshInterval: DispatchTimeInterval = .seconds(2)) {
        self.snapshotProvider = snapshotProvider
        self.refreshInterval = refreshInterval
    }

    deinit {
        monitor.cancel()
        timer?.cancel()
    }

    func start(_ handler: @escaping Handler) {
        queue.async { [weak self] in
            guard let self, self.handler == nil else { return }
            self.handler = handler
            refreshLocked()
            monitor.pathUpdateHandler = { [weak self] _ in self?.refreshLocked() }
            monitor.start(queue: queue)
            // A split-tunnel VPN can add/remove an address without changing
            // the default path. Re-read the interface list as well, publishing
            // only actual changes so an unchanged QR code is never redrawn.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + refreshInterval, repeating: refreshInterval, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.refreshLocked() }
            self.timer = timer
            timer.resume()
        }
    }

    private func refreshLocked() {
        let addresses = snapshotProvider()
        guard addresses != lastAddresses else { return }
        lastAddresses = addresses
        handler?(addresses)
    }

    static func currentAddresses() -> [String] {
        HostPairingAddressPolicy.select(
            from: interfaceAddresses(),
            localHostName: SCDynamicStoreCopyLocalHostName(nil) as String?
        )
    }

    static func interfaceAddresses() -> [HostPairingInterfaceAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var result: [HostPairingInterfaceAddress] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
                    || address.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            // Scope identifiers have meaning only on the originating device.
            // Routable IPv6 needs no scope; link-local addresses are rejected
            // below even after removing their interface suffix.
            let host = HostPairingHostAddress.string(from: buffer).split(separator: "%", maxSplits: 1).first.map(String.init) ?? ""
            result.append(HostPairingInterfaceAddress(
                interfaceName: String(cString: entry.pointee.ifa_name),
                address: host,
                flags: entry.pointee.ifa_flags
            ))
        }
        return result
    }
}

struct HostPairingInterfaceAddress: Equatable, Sendable {
    let interfaceName: String
    let address: String
    let flags: UInt32
}

enum HostPairingAddressPolicy {
    static let maximumAddresses = 8

    /// Preserve VPN, LAN, IPv4, and IPv6 coverage before filling remaining
    /// slots. A large set of temporary IPv6 addresses cannot crowd out IPv4 or
    /// the local DNS fallback. Tailscale ranges get preference within VPNs.
    static func select(from interfaces: [HostPairingInterfaceAddress], localHostName: String?) -> [String] {
        struct Candidate {
            let host: String
            let interfaceName: String
            let group: Int
            let isTailscaleRange: Bool
        }
        var candidates: [Candidate] = []
        for entry in interfaces {
            guard entry.flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  entry.flags & UInt32(IFF_LOOPBACK) == 0,
                  let host = HostPairingHostAddress.normalized(entry.address),
                  let family = HostPairingHostAddress.family(of: host) else { continue }
            let tailscale = isTailscaleAddress(host)
            let isVPN = tailscale || entry.flags & UInt32(IFF_POINTOPOINT) != 0
                || ["utun", "tun", "tap", "wg", "ipsec", "ppp"].contains(where: entry.interfaceName.hasPrefix)
            let group = family == AF_INET ? (isVPN ? 0 : 1) : (isVPN ? 2 : 3)
            candidates.append(Candidate(host: host, interfaceName: entry.interfaceName,
                                        group: group, isTailscaleRange: tailscale))
        }
        candidates.sort {
            if $0.isTailscaleRange != $1.isTailscaleRange { return $0.isTailscaleRange }
            if $0.interfaceName != $1.interfaceName { return $0.interfaceName < $1.interfaceName }
            return $0.host < $1.host
        }
        var seen = Set<String>()
        var groups = (0..<4).map { group in
            candidates.filter { $0.group == group && seen.insert($0.host).inserted }.map(\.host)
        }
        let localAddress = localHostName.flatMap {
            HostPairingHostAddress.normalized($0.hasSuffix(".local") ? $0 : $0 + ".local")
        }
        let numericLimit = maximumAddresses - (localAddress == nil ? 0 : 1)
        var result: [String] = []
        while result.count < numericLimit {
            var added = false
            for index in groups.indices where !groups[index].isEmpty && result.count < numericLimit {
                result.append(groups[index].removeFirst())
                added = true
            }
            if !added { break }
        }
        if let localAddress, !result.contains(localAddress) { result.append(localAddress) }
        return result
    }

    private static func isTailscaleAddress(_ host: String) -> Bool {
        if let address = IPv4Address(host) {
            let bytes = Array(address.rawValue)
            return bytes[0] == 100 && (64...127).contains(bytes[1])
        }
        if let address = IPv6Address(host) {
            return Array(address.rawValue.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
        }
        return false
    }
}

enum HostPairingHostAddress {
    static func family(of host: String) -> Int32? {
        if IPv4Address(host) != nil { return AF_INET }
        if IPv6Address(host) != nil { return AF_INET6 }
        return nil
    }

    /// Canonicalization also lets the invite reject equivalent duplicate
    /// addresses such as an expanded IPv6 literal and its compressed form.
    static func normalized(_ host: String) -> String? {
        guard !host.isEmpty, !host.contains("%") else { return nil }
        if let address = IPv4Address(host) {
            let bytes = Array(address.rawValue)
            guard bytes[0] != 0, bytes[0] != 127, bytes[0] < 224,
                  !(bytes[0] == 169 && bytes[1] == 254) else { return nil }
            return bytes.map(String.init).joined(separator: ".")
        }
        if let address = IPv6Address(host) {
            let bytes = Array(address.rawValue)
            guard bytes.contains(where: { $0 != 0 }),
                  bytes != Array(repeating: 0, count: 15) + [1],
                  bytes[0] != 0xff,
                  !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80),
                  !(bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff) else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let converted = bytes.withUnsafeBytes {
                inet_ntop(AF_INET6, $0.baseAddress, &buffer, socklen_t(buffer.count)) != nil
            }
            return converted ? string(from: buffer) : nil
        }
        guard host.utf8.count <= 253,
              !host.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let lettersAndDigits = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        guard labels.allSatisfy({ label in
            guard let first = label.first, let last = label.last, label.utf8.count <= 63,
                  lettersAndDigits.contains(first), lettersAndDigits.contains(last) else { return false }
            return label.allSatisfy { lettersAndDigits.contains($0) || $0 == "-" }
        }) else { return nil }
        return host.lowercased()
    }

    static func string(from buffer: [CChar]) -> String {
        String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
