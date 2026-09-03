import Foundation
import Network

enum MachineReachabilityProber {
    @MainActor
    static func status(host: String,
                       port: UInt16,
                       timeout: Duration = .seconds(2)) async -> MachineReachabilityStatus {
        await MachineReachabilityProbe(host: host, port: port, timeout: timeout).start()
    }

    /// A saved Mac can have an unreachable LAN address while its VPN address
    /// is available. Check the bounded route set together and stop at the first
    /// reachable address, cancelling the remaining probes immediately.
    @MainActor
    static func status(addresses: [GlassyStreamDirectAddress],
                       timeout: Duration = .seconds(2)) async -> MachineReachabilityStatus {
        var seen = Set<GlassyStreamDirectAddress>()
        let addresses = Array(addresses.filter { seen.insert($0).inserted }.prefix(8))
        guard !addresses.isEmpty, !Task.isCancelled else { return .unreachable }

        return await withTaskGroup(of: MachineReachabilityStatus.self) { group in
            for address in addresses {
                group.addTask {
                    await status(host: address.host, port: address.port, timeout: timeout)
                }
            }
            for await result in group {
                if result == .reachable {
                    group.cancelAll()
                    return .reachable
                }
            }
            return .unreachable
        }
    }
}

@MainActor
private final class MachineReachabilityProbe {
    private let host: String
    private let port: UInt16
    private let timeout: Duration

    private var connection: NWConnection?
    private var continuation: CheckedContinuation<MachineReachabilityStatus, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false

    init(host: String, port: UInt16, timeout: Duration) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.timeout = timeout
    }

    func start() async -> MachineReachabilityStatus {
        guard !Task.isCancelled, !host.isEmpty,
              let networkPort = NWEndpoint.Port(rawValue: port) else {
            AppLog.reachability.info("Skipping saved machine reachability probe for invalid endpoint; host=\(self.host, privacy: .public) port=\(self.port, privacy: .public)")
            return .unreachable
        }

        AppLog.reachability.debug("Starting TCP reachability probe; endpoint=\(self.endpointDescription, privacy: .public)")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    finish(.unreachable)
                    return
                }

                let connection = NWConnection(host: NWEndpoint.Host(host),
                                              port: networkPort,
                                              using: .tcp)
                self.connection = connection

                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        self?.handle(state)
                    }
                }

                let timeout = self.timeout
                timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.logTimeout()
                    self?.finish(.unreachable)
                }

                connection.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.unreachable)
            }
        }
    }

    private func handle(_ state: NWConnection.State) {
        AppLog.reachability.debug("TCP reachability probe state changed; endpoint=\(self.endpointDescription, privacy: .public) state=\(Self.description(for: state), privacy: .public)")

        switch state {
        case .ready:
            finish(.reachable)
        case .failed:
            finish(.unreachable)
        case .waiting:
            // A VPN or local-network permission can become available while
            // connecting. Keep this route alive until its bounded timeout.
            break
        case .cancelled:
            break
        default:
            break
        }
    }

    private func finish(_ status: MachineReachabilityStatus) {
        guard !didFinish else {
            AppLog.reachability.debug("Ignoring duplicate TCP reachability probe finish; endpoint=\(self.endpointDescription, privacy: .public) status=\(status.title, privacy: .public)")
            return
        }

        didFinish = true
        AppLog.reachability.info("Finished TCP reachability probe; endpoint=\(self.endpointDescription, privacy: .public) status=\(status.title, privacy: .public)")
        timeoutTask?.cancel()
        timeoutTask = nil
        connection?.cancel()
        connection = nil
        continuation?.resume(returning: status)
        continuation = nil
    }

    private var endpointDescription: String {
        "\(host):\(port)"
    }

    private func logTimeout() {
        AppLog.reachability.info("TCP reachability probe timed out; endpoint=\(self.endpointDescription, privacy: .public)")
    }

    private static func description(for state: NWConnection.State) -> String {
        switch state {
        case .setup:
            "setup"
        case .waiting(let error):
            "waiting(\(String(describing: error)))"
        case .preparing:
            "preparing"
        case .ready:
            "ready"
        case .failed(let error):
            "failed(\(String(describing: error)))"
        case .cancelled:
            "cancelled"
        @unknown default:
            "unknown"
        }
    }
}
