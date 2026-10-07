import AVFoundation
import AVKit
import Observation
import OSLog
import UIKit

/// Shows the live remote desktop in a system Picture in Picture window.
///
/// The on-screen session registers the sample-buffer layer that already shows
/// the remote screen: the decoded H.264 layer for Fast Connection, or a
/// low-rate framebuffer mirror for Standard VNC. While the window is active the
/// session stays connected in the background. The window is view-only; input
/// resumes when the person returns to Glassy Desk.
@MainActor
@Observable
final class RemotePictureInPictureCoordinator {
    static let shared = RemotePictureInPictureCoordinator()

    nonisolated static let startsAutomaticallyKey = "pictureInPicture.startsAutomatically"
    nonisolated static let defaultStartsAutomatically = true
    /// Posted on the main queue after the window closes, including when the
    /// person closes it while Glassy Desk is in the background.
    nonisolated static let didStopNotification = Notification.Name("RemotePictureInPictureDidStop")

    let isSupported: Bool
    private(set) var isPossible = false
    private(set) var isActive = false
    private(set) var isStarting = false

    /// True while the system window shows, or is about to show, the session.
    var keepsSessionAlive: Bool {
        isActive || isStarting
    }

    /// True when leaving the app is expected to open the window automatically.
    var mayStartAutomatically: Bool {
        isPossible && startsAutomatically
    }

    var startsAutomatically: Bool {
        defaults.object(forKey: Self.startsAutomaticallyKey) as? Bool ?? Self.defaultStartsAutomatically
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private weak var sourceLayer: AVSampleBufferDisplayLayer?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var delegate: RemotePictureInPictureDelegate!

    init(defaults: UserDefaults = .standard,
         isSupported: Bool = AVPictureInPictureController.isPictureInPictureSupported()) {
        self.defaults = defaults
        self.isSupported = isSupported
        delegate = RemotePictureInPictureDelegate(coordinator: self)
    }

    /// Uses `layer` as the window's content. Registering another layer replaces
    /// the previous source, so only the most recent session view is shown.
    func register(_ layer: AVSampleBufferDisplayLayer) {
        guard isSupported, sourceLayer !== layer else { return }

        teardownController()
        sourceLayer = layer
        // AVKit returns no controller on devices without Picture in Picture,
        // including simulators. Source tracking above still applies.
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        activateAudioSession()

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: delegate
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = delegate
        controller.requiresLinearPlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = startsAutomatically
        self.controller = controller

        possibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            let isPossible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                self?.isPossible = isPossible
            }
        }
        AppLog.session.info("Registered a Picture in Picture source")
    }

    /// Releases `layer` if it is the current source. Any active window closes.
    func unregister(_ layer: AVSampleBufferDisplayLayer) {
        guard sourceLayer === layer else { return }

        sourceLayer = nil
        let hadController = controller != nil
        teardownController()
        if hadController {
            deactivateAudioSession()
        }
        AppLog.session.info("Unregistered the Picture in Picture source")
    }

    func start() {
        guard let controller, controller.isPictureInPicturePossible, !keepsSessionAlive else { return }
        AppLog.ui.info("Starting Picture in Picture")
        controller.startPictureInPicture()
    }

    func stop() {
        guard let controller, controller.isPictureInPictureActive else { return }
        AppLog.ui.info("Stopping Picture in Picture")
        controller.stopPictureInPicture()
    }

#if DEBUG
    var debugSourceLayer: AVSampleBufferDisplayLayer? { sourceLayer }
#endif

    func setStartsAutomatically(_ startsAutomatically: Bool) {
        defaults.set(startsAutomatically, forKey: Self.startsAutomaticallyKey)
        controller?.canStartPictureInPictureAutomaticallyFromInline = startsAutomatically
    }

    // MARK: - Delegate callbacks

    fileprivate func willStart() {
        isStarting = true
    }

    fileprivate func didStart() {
        isStarting = false
        isActive = true
        AppLog.session.info("Picture in Picture started")
    }

    fileprivate func failedToStart(_ error: any Error) {
        isStarting = false
        isActive = false
        AppLog.session.error("Picture in Picture failed to start: \(error.localizedDescription, privacy: .public)")
        NotificationCenter.default.post(name: Self.didStopNotification, object: self)
    }

    fileprivate func didStop() {
        isStarting = false
        isActive = false
        AppLog.session.info("Picture in Picture stopped")
        NotificationCenter.default.post(name: Self.didStopNotification, object: self)
    }

    // MARK: - Private

    private func teardownController() {
        possibleObservation?.invalidate()
        possibleObservation = nil
        if let controller, controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        }
        controller?.delegate = nil
        controller = nil
        isPossible = false
        if isActive || isStarting {
            isActive = false
            isStarting = false
            NotificationCenter.default.post(name: Self.didStopNotification, object: self)
        }
    }

    /// AVKit only offers Picture in Picture to apps whose audio session uses
    /// the playback category. Mix with other audio so starting a session never
    /// interrupts music or calls; Glassy Desk itself plays no sound.
    private func activateAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            AppLog.session.error("Could not prepare the audio session for Picture in Picture: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            AppLog.session.debug("Audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// AVKit delegate adapter. A remote desktop is always live: it has no
/// timeline, cannot pause, and cannot skip. AVKit calls the state callbacks on
/// the main thread; the coordinator reference is only read there.
private final class RemotePictureInPictureDelegate: NSObject, @unchecked Sendable,
                                                     AVPictureInPictureControllerDelegate,
                                                     AVPictureInPictureSampleBufferPlaybackDelegate {
    private weak var coordinator: RemotePictureInPictureCoordinator?

    init(coordinator: RemotePictureInPictureCoordinator) {
        self.coordinator = coordinator
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated { coordinator?.willStart() }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated { coordinator?.didStart() }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        MainActor.assumeIsolated { coordinator?.failedToStart(error) }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated { coordinator?.didStop() }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // The session view stays presented underneath the window.
        completionHandler(true)
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        RemotePictureInPicturePlayback.liveTimeRange
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

enum RemotePictureInPicturePlayback {
    /// An unbounded range tells AVKit the content is live, hiding scrubbing.
    static let liveTimeRange = CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
}
