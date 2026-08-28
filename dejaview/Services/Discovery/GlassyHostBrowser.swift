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

    @ObservationIgnored
    private var browserGeneration = UUID()

    @ObservationIgnored
    private var restartTask: Task<Void, Never>?

    @ObservationIgnored
    private var restartAttempt = 0

    @ObservationIgnored
    private let restartPolicy = AutomaticReconnectPolicy()

    func start() {
        guard browser == nil else { return }

        startBrowser()
    }

    func restart(keepingCurrentHosts: Bool) {
        AppLog.discovery.info(
            "Restarting Glassy Host discovery; keepingCurrentHosts=\(keepingCurrentHosts, privacy: .public)"
        )
        restartTask?.cancel()
        restartTask = nil
        restartAttempt = 0
        disposeCurrentBrowser()
        if !keepingCurrentHosts {
            hosts = []
        }
        startBrowser()
    }

    private func startBrowser() {
        guard browser == nil else { return }

        AppLog.discovery.info("Starting Bonjour browser for \(Self.serviceType, privacy: .public)")
        state = .searching

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil),
                                using: parameters)
        let generation = UUID()
        browserGeneration = generation

        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            Task { @MainActor in
                guard let browser else { return }
                self?.update(with: results, browser: browser, generation: generation)
            }
        }

        browser.stateUpdateHandler = { [weak self, weak browser] state in
            Task { @MainActor in
                guard let browser else { return }
                self?.handle(state, browser: browser, generation: generation)
            }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        guard browser != nil || state != .stopped else { return }

        AppLog.discovery.info("Stopping Glassy Host discovery")
        restartTask?.cancel()
        restartTask = nil
        restartAttempt = 0
        disposeCurrentBrowser()
        hosts = []
        state = .stopped
    }

    private func handle(
        _ browserState: NWBrowser.State,
        browser: NWBrowser,
        generation: UUID
    ) {
        guard browserGeneration == generation, self.browser === browser else { return }

        switch browserState {
        case .setup:
            break

        case .ready:
            restartTask?.cancel()
            restartTask = nil
            restartAttempt = 0
            state = .ready
            AppLog.discovery.info("Glassy Host Bonjour browser ready")

        case .waiting(let error):
            state = .searching
            AppLog.discovery.warning("Glassy Host discovery waiting: \(String(describing: error), privacy: .public)")

        case .failed(let error):
            let message = error.localizedDescription
            state = .failed(message)
            AppLog.discovery.error("Glassy Host discovery failed: \(message, privacy: .public)")
            disposeCurrentBrowser()
            scheduleRestartAfterFailure()

        case .cancelled:
            break

        @unknown default:
            state = .failed("Discovery entered an unknown state.")
            AppLog.discovery.error("Glassy Host discovery entered an unknown state")
            disposeCurrentBrowser()
            scheduleRestartAfterFailure()
        }
    }

    private func update(
        with results: Set<NWBrowser.Result>,
        browser: NWBrowser,
        generation: UUID
    ) {
        guard browserGeneration == generation, self.browser === browser else { return }

        hosts = results.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }

            return DiscoveredGlassyHost(id: String(describing: result.endpoint),
                                        name: name,
                                        endpoint: result.endpoint)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        AppLog.discovery.info("Glassy Host discovery found \(self.hosts.count, privacy: .public) companion hosts")
    }

    private func scheduleRestartAfterFailure() {
        // Discovery is long-lived app infrastructure, so it must not become
        // permanently inert after a fixed number of transient failures. Ramp
        // up through the shared policy, then keep retrying at its capped delay
        // until the browser becomes ready or the owner explicitly stops it.
        let attempt = min(restartAttempt + 1, restartPolicy.maximumAttempts)
        guard let delay = restartPolicy.delay(beforeAttempt: attempt) else { return }

        restartAttempt = attempt
        restartTask?.cancel()
        AppLog.discovery.info(
            "Scheduling Glassy Host discovery restart; backoffStep=\(attempt, privacy: .public) delaySeconds=\(delay, privacy: .public)"
        )
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.browser == nil else { return }
            self.restartTask = nil
            self.startBrowser()
        }
    }

    private func disposeCurrentBrowser() {
        browserGeneration = UUID()
        browser?.browseResultsChangedHandler = nil
        browser?.stateUpdateHandler = nil
        browser?.cancel()
        browser = nil
    }
}
