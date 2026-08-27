import Foundation
import Network
import Observation
import OSLog

enum GlassyHostDiscoveryState: Equatable {
    case stopped
    case searching
    case ready
    case failed(String)
}

struct DiscoveredGlassyHost: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

/// Discovers the optional Glassy Host companion app on the local network.
///
/// This is deliberately separate from `BonjourBrowser`: Screen Sharing hosts
/// advertise `_rfb._tcp`, while Glassy Host advertises its own versioned stream
/// protocol. Keeping the result endpoint intact lets the future fast-session
/// transport connect through Bonjour without first flattening it to an IP.
@MainActor
@Observable
final class GlassyHostBrowser {
    static let serviceType = "_glassydesk._tcp"

    private(set) var hosts: [DiscoveredGlassyHost] = []
    private(set) var state: GlassyHostDiscoveryState = .stopped

    @ObservationIgnored
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }

        AppLog.discovery.info("Starting Bonjour browser for \(Self.serviceType, privacy: .public)")
        state = .searching

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil),
                                using: parameters)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.update(with: results)
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handle(state)
            }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        guard browser != nil || state != .stopped else { return }

        AppLog.discovery.info("Stopping Glassy Host discovery")
        browser?.cancel()
        browser = nil
        hosts = []
        state = .stopped
    }

    private func handle(_ browserState: NWBrowser.State) {
        switch browserState {
        case .setup:
            break

        case .ready:
            state = .ready
            AppLog.discovery.info("Glassy Host Bonjour browser ready")

        case .waiting(let error):
            state = .searching
            AppLog.discovery.warning("Glassy Host discovery waiting: \(String(describing: error), privacy: .public)")

        case .failed(let error):
            let message = error.localizedDescription
            state = .failed(message)
            hosts = []
            AppLog.discovery.error("Glassy Host discovery failed: \(message, privacy: .public)")

        case .cancelled:
            if browser != nil {
                state = .stopped
            }

        @unknown default:
            state = .failed("Discovery entered an unknown state.")
            hosts = []
        }
    }

    private func update(with results: Set<NWBrowser.Result>) {
        hosts = results.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }

            return DiscoveredGlassyHost(id: String(describing: result.endpoint),
                                        name: name,
                                        endpoint: result.endpoint)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        AppLog.discovery.info("Glassy Host discovery found \(self.hosts.count, privacy: .public) companion hosts")
    }
}
