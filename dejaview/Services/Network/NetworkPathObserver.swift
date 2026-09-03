import Darwin
import Foundation
import Network
import Observation

enum NetworkPathStatus: Equatable, Sendable {
    case satisfied
    case unsatisfied
    case requiresConnection

    init(_ status: NWPath.Status) {
        switch status {
        case .satisfied:
            self = .satisfied
        case .unsatisfied:
            self = .unsatisfied
        case .requiresConnection:
            self = .requiresConnection
        @unknown default:
            self = .unsatisfied
        }
    }

    var logDescription: String {
        switch self {
        case .satisfied:
            "satisfied"
        case .unsatisfied:
            "unsatisfied"
        case .requiresConnection:
            "requiresConnection"
        }
    }
}

struct NetworkPathSnapshot: Equatable, Sendable {
    let status: NetworkPathStatus
    let usesWiFi: Bool
    let usesCellular: Bool
    let usesWiredEthernet: Bool
    let isExpensive: Bool
    let isConstrained: Bool
    let interfaceSignature: [String]

    init(_ path: NWPath) {
        status = NetworkPathStatus(path.status)
        usesWiFi = path.usesInterfaceType(.wifi)
        usesCellular = path.usesInterfaceType(.cellular)
        usesWiredEthernet = path.usesInterfaceType(.wiredEthernet)
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        // Wi-Fi can remain satisfied while a split-tunnel VPN connects or
        // receives a new address. Include that change in snapshot equality.
        interfaceSignature = Self.activeInterfaceSignature()
    }

    var logDescription: String {
        "status=\(status.logDescription) wifi=\(usesWiFi) cellular=\(usesCellular) wired=\(usesWiredEthernet) expensive=\(isExpensive) constrained=\(isConstrained) interfaces=\(interfaceSignature.count)"
    }

    private static func activeInterfaceSignature() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }

        var signature = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let interface = entry.pointee
            guard interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
                    || address.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &buffer, socklen_t(buffer.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let numericAddress = String(decoding: buffer.prefix { $0 != 0 }.map {
                UInt8(bitPattern: $0)
            }, as: UTF8.self)
            signature.insert("\(String(cString: interface.ifa_name)):\(numericAddress)")
        }
        return signature.sorted()
    }
}

@MainActor
@Observable
final class NetworkPathObserver {
    private(set) var snapshot: NetworkPathSnapshot?

    @ObservationIgnored
    private var monitor: NWPathMonitor?

    @ObservationIgnored
    private var tunnelMonitor: NWPathMonitor?

    @ObservationIgnored
    private var generation = UUID()

    func start() {
        guard monitor == nil else { return }

        let generation = UUID()
        self.generation = generation
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = NetworkPathSnapshot(path)

            Task { @MainActor in
                guard let self, self.generation == generation, self.monitor != nil else { return }
                self.snapshot = snapshot
            }
        }
        // Observe tunnel availability separately: the default route often
        // remains Wi-Fi when Tailscale or WireGuard adds private routes.
        let tunnelMonitor = NWPathMonitor(requiredInterfaceType: .other)
        tunnelMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation, let monitor = self.monitor,
                      self.snapshot != nil else { return }
                let snapshot = NetworkPathSnapshot(monitor.currentPath)
                self.snapshot = snapshot
            }
        }

        self.monitor = monitor
        self.tunnelMonitor = tunnelMonitor
        monitor.start(queue: .main)
        tunnelMonitor.start(queue: .main)
    }

    func stop() {
        generation = UUID()
        monitor?.cancel()
        tunnelMonitor?.cancel()
        monitor = nil
        tunnelMonitor = nil
        snapshot = nil
    }
}
