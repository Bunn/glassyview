import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class HostUpdateController: NSObject, SPUUpdaterDelegate {
    let isConfigured: Bool
    private(set) var canCheckForUpdates = false
    private(set) var isInstallationDeferred = false
    private(set) var startupError: String?

    @ObservationIgnored
    private let hasActiveSessions: @MainActor () -> Bool

    @ObservationIgnored
    private let makeDriver: @MainActor (any SPUUpdaterDelegate) -> any HostUpdateDriver

    @ObservationIgnored
    private var driver: (any HostUpdateDriver)?

    @ObservationIgnored
    private var hasAttemptedStart = false

    @ObservationIgnored
    private var didStart = false

    @ObservationIgnored
    private var pendingInstallation: (id: UUID, resume: () -> Void)?

    var statusMessage: String {
        if !isConfigured {
            return "Updates are not configured in this build."
        }
        if startupError != nil {
            return "The updater could not start. Check the app log for details."
        }
        if isInstallationDeferred {
            return "The update will install after all remote sessions disconnect."
        }
        return "Check for a new version of Glassy Desk."
    }

    init(
        configuration: HostUpdateConfiguration? = HostUpdateConfiguration(
            infoDictionary: Bundle.main.infoDictionary ?? [:]
        ),
        hasActiveSessions: @escaping @MainActor () -> Bool = { false },
        makeDriver: @escaping @MainActor (any SPUUpdaterDelegate) -> any HostUpdateDriver = {
            SparkleHostUpdateDriver(delegate: $0)
        }
    ) {
        isConfigured = configuration != nil
        self.hasActiveSessions = hasActiveSessions
        self.makeDriver = makeDriver
        super.init()
    }

    func startIfConfigured() {
        // Do not even construct Sparkle for unconfigured development builds:
        // there must be no update traffic, permission prompts, or timers.
        guard isConfigured, !hasAttemptedStart else { return }
        hasAttemptedStart = true

        let driver = makeDriver(self)
        self.driver = driver
        driver.onCanCheckForUpdatesChange = { [weak self] canCheck in
            self?.refreshAvailability(canCheck: canCheck)
        }
        do {
            try driver.start()
            didStart = true
            refreshAvailability(canCheck: driver.canCheckForUpdates)
        } catch {
            startupError = error.localizedDescription
            canCheckForUpdates = false
            HostLog.app.error("Could not start the updater: \(error.localizedDescription, privacy: .public)")
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        driver?.checkForUpdates()
    }

    func postponeInstallationIfNeeded(_ installHandler: @escaping () -> Void) -> Bool {
        guard hasActiveSessions() else { return false }
        let id = UUID()
        pendingInstallation = (id, installHandler)
        isInstallationDeferred = true
        canCheckForUpdates = false
        observeSessionEnd(for: id)
        return true
    }

    func resumeInstallationIfPossible() {
        guard !hasActiveSessions(), let pending = pendingInstallation else { return }
        // Sparkle asks to postpone only once. Re-check the live session state
        // and consume the callback before invoking it, including on reentry.
        cancelDeferredInstallation()
        pending.resume()
    }

    func cancelDeferredInstallation() {
        pendingInstallation = nil
        isInstallationDeferred = false
        refreshAvailability(canCheck: driver?.canCheckForUpdates ?? false)
    }

    private func refreshAvailability(canCheck: Bool) {
        canCheckForUpdates = didStart && canCheck && !isInstallationDeferred
    }

    private func observeSessionEnd(for id: UUID) {
        guard pendingInstallation?.id == id else { return }
        withObservationTracking {
            _ = hasActiveSessions()
        } onChange: { [weak self] in
            // Observation fires before the count changes. Read the committed
            // value on the next main-actor turn, independently of any window.
            Task { @MainActor [weak self] in
                guard let self, self.pendingInstallation?.id == id else { return }
                self.resumeInstallationIfPossible()
                self.observeSessionEnd(for: id)
            }
        }
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        postponeInstallationIfNeeded(installHandler)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        cancelDeferredInstallation()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        cancelDeferredInstallation()
    }
}
