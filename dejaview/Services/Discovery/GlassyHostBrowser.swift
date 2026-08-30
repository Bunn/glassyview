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
    var resolvedHost: String?
    var resolvedPort: UInt16?

    var isResolved: Bool {
        resolvedHost != nil && resolvedPort != nil
    }
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
    private var discoveredEndpoints: [String: NWEndpoint] = [:]

    @ObservationIgnored
    private var resolveConnections: [String: NWConnection] = [:]

    @ObservationIgnored
    private var resolveTimeouts: [String: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var resolveRetryTasks: [String: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var resolveAttempts: [String: Int] = [:]

    @ObservationIgnored
    private var resolveRecoveryTasks: [String: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var browserGeneration = UUID()

    @ObservationIgnored
    private var restartTask: Task<Void, Never>?

    @ObservationIgnored
    private var restartAttempt = 0

    @ObservationIgnored
    private let restartPolicy = AutomaticReconnectPolicy()

    @ObservationIgnored
    private let resolveTimeout: TimeInterval = 5

    @ObservationIgnored
    private let resolveRetryDelay: TimeInterval = 2

    @ObservationIgnored
    private let maxResolveAttempts = 3

    @ObservationIgnored
    private let resolveRecoveryDelay: TimeInterval = 30

    func start() {
        guard FeatureFlags.isGlassyStreamEnabled else { return }
        guard browser == nil else { return }

        startBrowser()
    }

    func restart(keepingCurrentHosts: Bool) {
        guard FeatureFlags.isGlassyStreamEnabled else {
            stop()
            return
        }

        AppLog.discovery.info(
            "Restarting Glassy Host discovery; keepingCurrentHosts=\(keepingCurrentHosts, privacy: .public)"
        )
        restartTask?.cancel()
        restartTask = nil
        restartAttempt = 0
        disposeCurrentBrowser(keepingCurrentHosts: keepingCurrentHosts)
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
        disposeCurrentBrowser(keepingCurrentHosts: false)
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
            resolveMissingHosts(generation: generation)

        case .waiting(let error):
            state = .searching
            cancelAllResolutions()
            resolveAttempts.removeAll()
            invalidateResolvedHosts()
            AppLog.discovery.warning("Glassy Host discovery waiting: \(String(describing: error), privacy: .public)")

        case .failed(let error):
            let message = error.localizedDescription
            state = .failed(message)
            AppLog.discovery.error("Glassy Host discovery failed: \(message, privacy: .public)")
            disposeCurrentBrowser(keepingCurrentHosts: true)
            scheduleRestartAfterFailure()

        case .cancelled:
            break

        @unknown default:
            state = .failed("Discovery entered an unknown state.")
            AppLog.discovery.error("Glassy Host discovery entered an unknown state")
            disposeCurrentBrowser(keepingCurrentHosts: true)
            scheduleRestartAfterFailure()
        }
    }

    private func update(
        with results: Set<NWBrowser.Result>,
        browser: NWBrowser,
        generation: UUID
    ) {
        guard browserGeneration == generation, self.browser === browser else { return }

        var activeEndpoints: [String: NWEndpoint] = [:]
        var updatedHosts: [DiscoveredGlassyHost] = []

        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }

            let id = Self.endpointIdentity(result.endpoint)
            activeEndpoints[id] = result.endpoint

            if let existing = hosts.first(where: { $0.id == id }) {
                updatedHosts.append(existing)
            } else {
                updatedHosts.append(
                    DiscoveredGlassyHost(
                        id: id,
                        name: name,
                        endpoint: result.endpoint,
                        resolvedHost: nil,
                        resolvedPort: nil
                    )
                )
            }
        }

        let removedIDs = Set(discoveredEndpoints.keys).subtracting(activeEndpoints.keys)
        for id in removedIDs {
            cancelResolution(for: id)
            resolveAttempts[id] = nil
        }

        discoveredEndpoints = activeEndpoints
        hosts = updatedHosts.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }

        resolveMissingHosts(generation: generation)

        AppLog.discovery.info("Glassy Host discovery found \(self.hosts.count, privacy: .public) companion hosts")
    }

    private func resolveMissingHosts(generation: UUID) {
        guard browserGeneration == generation, browser != nil else { return }

        for host in hosts where !host.isResolved {
            let id = host.id
            guard resolveConnections[id] == nil,
                  resolveRetryTasks[id] == nil,
                  resolveRecoveryTasks[id] == nil,
                  let endpoint = discoveredEndpoints[id] else {
                continue
            }

            resolve(endpoint, id: id, preferIPv4: true, generation: generation)
        }
    }

    /// Resolves the Bonjour service to a comparable address while retaining
    /// the original service endpoint for authenticated Glassy Stream traffic.
    private func resolve(
        _ endpoint: NWEndpoint,
        id: String,
        preferIPv4: Bool,
        generation: UUID
    ) {
        guard browserGeneration == generation,
              discoveredEndpoints[id] != nil,
              hosts.contains(where: { $0.id == id && !$0.isResolved }) else {
            return
        }

        cancelResolution(for: id)

        if preferIPv4 {
            resolveAttempts[id, default: 0] += 1
        }

        let attempt = resolveAttempts[id, default: 1]
        let name = hosts.first(where: { $0.id == id })?.name ?? id
        AppLog.discovery.debug(
            "Resolving Glassy Host '\(name, privacy: .public)' attempt=\(attempt, privacy: .public) preferIPv4=\(preferIPv4, privacy: .public)"
        )

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if preferIPv4,
           let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }

        let connection = NWConnection(to: endpoint, using: parameters)
        resolveConnections[id] = connection
        scheduleResolveTimeout(
            for: id,
            endpoint: endpoint,
            connection: connection,
            preferIPv4: preferIPv4,
            generation: generation
        )

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.browserGeneration == generation else { return }

                switch state {
                case .ready:
                    let remoteEndpoint = connection.currentPath?.remoteEndpoint
                    guard self.finishResolutionConnection(connection, id: id) else { return }

                    guard case .hostPort(let host, let port)? = remoteEndpoint else {
                        AppLog.discovery.warning(
                            "Resolved Glassy Host '\(name, privacy: .public)' without a hostPort endpoint"
                        )
                        self.continueAfterResolveFailure(
                            endpoint: endpoint,
                            id: id,
                            preferIPv4: preferIPv4,
                            generation: generation
                        )
                        return
                    }

                    let hostString = Self.string(from: host)
                    AppLog.discovery.info(
                        "Resolved Glassy Host '\(name, privacy: .public)' to \(hostString, privacy: .public):\(port.rawValue, privacy: .public)"
                    )

                    guard self.discoveredEndpoints[id] != nil,
                          let index = self.hosts.firstIndex(where: { $0.id == id }) else {
                        return
                    }

                    self.hosts[index].resolvedHost = hostString
                    self.hosts[index].resolvedPort = port.rawValue
                    self.resolveAttempts[id] = nil

                case .waiting(let error):
                    AppLog.discovery.debug(
                        "Glassy Host resolve waiting for '\(name, privacy: .public)': \(String(describing: error), privacy: .public)"
                    )

                case .failed(let error):
                    guard self.finishResolutionConnection(connection, id: id) else { return }
                    AppLog.discovery.warning(
                        "Glassy Host resolve failed for '\(name, privacy: .public)': \(String(describing: error), privacy: .public)"
                    )
                    self.continueAfterResolveFailure(
                        endpoint: endpoint,
                        id: id,
                        preferIPv4: preferIPv4,
                        generation: generation
                    )

                case .cancelled:
                    _ = self.finishResolutionConnection(connection, id: id)

                default:
                    break
                }
            }
        }

        connection.start(queue: .main)
    }

    private func scheduleResolveTimeout(
        for id: String,
        endpoint: NWEndpoint,
        connection: NWConnection,
        preferIPv4: Bool,
        generation: UUID
    ) {
        resolveTimeouts[id]?.cancel()

        let timeoutMilliseconds = Int(resolveTimeout * 1_000)
        resolveTimeouts[id] = Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(for: .milliseconds(timeoutMilliseconds))
            guard !Task.isCancelled,
                  let self,
                  let connection,
                  self.browserGeneration == generation,
                  self.resolveConnections[id] === connection else {
                return
            }

            let name = self.hosts.first(where: { $0.id == id })?.name ?? id
            AppLog.discovery.warning(
                "Glassy Host resolve timed out for '\(name, privacy: .public)' preferIPv4=\(preferIPv4, privacy: .public)"
            )
            guard self.finishResolutionConnection(connection, id: id) else { return }
            self.continueAfterResolveFailure(
                endpoint: endpoint,
                id: id,
                preferIPv4: preferIPv4,
                generation: generation
            )
        }
    }

    private func continueAfterResolveFailure(
        endpoint: NWEndpoint,
        id: String,
        preferIPv4: Bool,
        generation: UUID
    ) {
        guard browserGeneration == generation,
              discoveredEndpoints[id] != nil,
              hosts.contains(where: { $0.id == id && !$0.isResolved }) else {
            return
        }

        if preferIPv4 {
            resolve(endpoint, id: id, preferIPv4: false, generation: generation)
        } else {
            finishResolveFailure(endpoint: endpoint, id: id, generation: generation)
        }
    }

    private func finishResolveFailure(
        endpoint: NWEndpoint,
        id: String,
        generation: UUID
    ) {
        guard browserGeneration == generation,
              discoveredEndpoints[id] != nil,
              hosts.contains(where: { $0.id == id && !$0.isResolved }) else {
            return
        }

        let attempts = resolveAttempts[id, default: 0]
        guard attempts < maxResolveAttempts else {
            let name = hosts.first(where: { $0.id == id })?.name ?? id
            AppLog.discovery.warning(
                "Pausing Glassy Host resolution for '\(name, privacy: .public)' after \(attempts, privacy: .public) attempts; retaining its Bonjour endpoint and scheduling recovery"
            )
            resolveAttempts[id] = nil
            scheduleResolveRecovery(endpoint: endpoint, id: id, generation: generation)
            return
        }

        scheduleResolveRetry(endpoint: endpoint, id: id, generation: generation)
    }

    private func scheduleResolveRetry(
        endpoint: NWEndpoint,
        id: String,
        generation: UUID
    ) {
        guard resolveRetryTasks[id] == nil else { return }

        let name = hosts.first(where: { $0.id == id })?.name ?? id
        AppLog.discovery.info("Scheduling Glassy Host resolve retry for '\(name, privacy: .public)'")

        let retryMilliseconds = Int(resolveRetryDelay * 1_000)
        resolveRetryTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(retryMilliseconds))
            guard !Task.isCancelled, let self else { return }

            self.resolveRetryTasks[id] = nil
            guard self.browserGeneration == generation,
                  self.discoveredEndpoints[id] != nil,
                  self.hosts.contains(where: { $0.id == id && !$0.isResolved }) else {
                return
            }

            self.resolve(endpoint, id: id, preferIPv4: true, generation: generation)
        }
    }

    private func scheduleResolveRecovery(
        endpoint: NWEndpoint,
        id: String,
        generation: UUID
    ) {
        guard resolveRecoveryTasks[id] == nil else { return }

        let name = hosts.first(where: { $0.id == id })?.name ?? id
        AppLog.discovery.info(
            "Scheduling slow Glassy Host resolve recovery for '\(name, privacy: .public)'"
        )

        let recoveryMilliseconds = Int(resolveRecoveryDelay * 1_000)
        resolveRecoveryTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(recoveryMilliseconds))
            guard !Task.isCancelled, let self else { return }

            self.resolveRecoveryTasks[id] = nil
            guard self.browserGeneration == generation,
                  self.discoveredEndpoints[id] != nil,
                  self.hosts.contains(where: { $0.id == id && !$0.isResolved }) else {
                return
            }

            self.resolve(endpoint, id: id, preferIPv4: true, generation: generation)
        }
    }

    private func finishResolutionConnection(_ connection: NWConnection, id: String) -> Bool {
        guard resolveConnections[id] === connection else { return false }

        resolveTimeouts[id]?.cancel()
        resolveTimeouts[id] = nil
        resolveConnections[id] = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        return true
    }

    private func cancelAllResolutions() {
        let connections = Array(resolveConnections.values)
        resolveConnections.removeAll()
        for connection in connections {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }

        resolveTimeouts.values.forEach { $0.cancel() }
        resolveTimeouts.removeAll()

        resolveRetryTasks.values.forEach { $0.cancel() }
        resolveRetryTasks.removeAll()

        resolveRecoveryTasks.values.forEach { $0.cancel() }
        resolveRecoveryTasks.removeAll()
    }

    private func cancelResolution(for id: String) {
        if let connection = resolveConnections.removeValue(forKey: id) {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }

        resolveTimeouts[id]?.cancel()
        resolveTimeouts[id] = nil

        resolveRetryTasks[id]?.cancel()
        resolveRetryTasks[id] = nil

        resolveRecoveryTasks[id]?.cancel()
        resolveRecoveryTasks[id] = nil
    }

    private func invalidateResolvedHosts() {
        for index in hosts.indices {
            hosts[index].resolvedHost = nil
            hosts[index].resolvedPort = nil
        }
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

    private func disposeCurrentBrowser(keepingCurrentHosts: Bool) {
        browserGeneration = UUID()
        browser?.browseResultsChangedHandler = nil
        browser?.stateUpdateHandler = nil
        browser?.cancel()
        browser = nil
        discoveredEndpoints.removeAll()
        cancelAllResolutions()
        resolveAttempts.removeAll()

        if keepingCurrentHosts {
            invalidateResolvedHosts()
        } else {
            hosts = []
        }
    }

    private static func endpointIdentity(_ endpoint: NWEndpoint) -> String {
        String(describing: endpoint)
    }

    private static func string(from host: NWEndpoint.Host) -> String {
        var hostString: String

        switch host {
        case .ipv4(let address):
            hostString = "\(address)"
        case .ipv6(let address):
            hostString = "\(address)"
        case .name(let name, _):
            hostString = name
        @unknown default:
            hostString = "\(host)"
        }

        if let percentIndex = hostString.firstIndex(of: "%") {
            hostString = String(hostString[..<percentIndex])
        }

        return hostString
    }
}
