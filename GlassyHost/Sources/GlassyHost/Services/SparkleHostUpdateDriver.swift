import Foundation
import Sparkle

@MainActor
protocol HostUpdateDriver: AnyObject {
    var canCheckForUpdates: Bool { get }
    var onCanCheckForUpdatesChange: (@MainActor (Bool) -> Void)? { get set }

    func start() throws
    func checkForUpdates()
}

@MainActor
final class SparkleHostUpdateDriver: HostUpdateDriver {
    var onCanCheckForUpdatesChange: (@MainActor (Bool) -> Void)?

    private let controller: SPUStandardUpdaterController
    private var availabilityObservation: NSKeyValueObservation?

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    init(delegate: any SPUUpdaterDelegate) {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        availabilityObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.new]
        ) { [weak self] _, _ in
            // Sparkle's updater and its KVO notifications are main-thread-only.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onCanCheckForUpdatesChange?(self.canCheckForUpdates)
            }
        }
    }

    func start() throws {
        // Unlike the controller's startUpdater(), this reports configuration
        // errors to our owner without presenting a delayed modal alert.
        try controller.updater.start()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
