import AppKit
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class HostController {
    private enum ServerEvent: Sendable {
        case authenticatedClientCount(Int)
        case status(HostServer.Status)
        case streamQuality(HostProtocol.StreamQuality)
    }

    private(set) var runState: HostRunState = .stopped
    private(set) var screenRecordingAuthorization: ScreenRecordingAuthorization = .unknown
    private(set) var accessibilityAuthorization: AccessibilityAuthorization = .unknown
    private(set) var displays: [CaptureDisplay] = []
    private(set) var isStreaming = false
    private(set) var isTransitioning = false
    private(set) var clientCount = 0
    private(set) var pairingCode = "Starting…"
    private(set) var pairingCodeRemainingSeconds = 0
    private(set) var serverPort: UInt16?
    private(set) var lastError: String?
    private(set) var loginItemStatus: LoginItemRegistrationStatus = .notRegistered
    private(set) var isUpdatingLoginItem = false
    private(set) var loginItemError: String?

    private var streamingDemand = StreamingDemandPolicy()

    var selectedDisplayID: CGDirectDisplayID? {
        didSet {
            remoteInputService.setDisplayID(selectedDisplayID)
        }
    }

    private let pairingSecretStore = PairingSecretStore()
    private let hostServer = HostServer()
    private let loginItemService = LoginItemService()
    private let remoteInputService = RemoteInputService()

    @ObservationIgnored
    private lazy var captureService = ScreenCaptureService { [weak self] event in
        Task { @MainActor in
            self?.handleCaptureEvent(event)
        }
    }

    @ObservationIgnored
    private var encoder: H264Encoder?

    @ObservationIgnored
    private var frameTask: Task<Void, Never>?

    @ObservationIgnored
    private var onDemandStopTask: Task<Void, Never>?

    @ObservationIgnored
    private var serverEventTask: Task<Void, Never>?

    @ObservationIgnored
    private var serverEventContinuation: AsyncStream<ServerEvent>.Continuation?

    @ObservationIgnored
    nonisolated(unsafe)
    private var pairingCodeTimer: Timer?

    @ObservationIgnored
    private var isPrepared = false

    @ObservationIgnored
    private var isServerReady = false

    @ObservationIgnored
    private var isHandlingPipelineFailure = false

    @ObservationIgnored
    private var pipelineGenerations = HostPipelineGenerationTracker()

    @ObservationIgnored
    private var desiredStreamQuality: HostProtocol.StreamQuality = .best

    @ObservationIgnored
    private var activeStreamQuality: HostProtocol.StreamQuality?

    @ObservationIgnored
    private var pendingStreamQualityUpgrade: HostProtocol.StreamQuality?

    @ObservationIgnored
    private var streamQualityUpgradeTask: Task<Void, Never>?

    @ObservationIgnored
    private var initialOnDemandStartTask: Task<Void, Never>?

    @ObservationIgnored
    private var isInitialOnDemandStartDeferred = false

    private static let onDemandStopGrace: Duration = .seconds(5)
    private static let streamQualityUpgradeDebounce: Duration = .milliseconds(400)
    private static let initialOnDemandStartDelay: Duration = .milliseconds(200)

    var displayName: String {
        if let selectedDisplayID,
           let display = displays.first(where: { $0.id == selectedDisplayID }) {
            return display.name
        }
        return displays.first(where: \.isMain)?.name ?? "Main Display"
    }

    var menuBarSystemImage: String {
        if case .failed = runState {
            return "exclamationmark.triangle.fill"
        }
        return isStreaming ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle"
    }

    var streamingOwnership: StreamingDemandPolicy.Ownership? {
        streamingDemand.ownership
    }

    var isOnDemandStreaming: Bool {
        isStreaming && streamingOwnership == .onDemand
    }

    var captureStatusText: String {
        if isInitialOnDemandStartDeferred && clientCount > 0 {
            return "Starting capture…"
        }
        if isTransitioning {
            return streamingDemand.wantsCapture ? "Starting capture…" : "Stopping capture…"
        }
        if isStreaming {
            if streamingOwnership == .manual {
                return "Streaming continuously until you stop it"
            }
            return clientCount == 0
                ? "Waiting five seconds for an authenticated device to reconnect"
                : "Streaming on demand for an authenticated device"
        }
        if clientCount > 0 {
            return lastError == nil
                ? "Capture was stopped manually for the current connection"
                : "Capture could not start for the current connection"
        }
        return "Ready — screen capture starts after an authenticated device connects"
    }

    var startsAtLogin: Bool {
        loginItemStatus.isRequested
    }

    deinit {
        pairingCodeTimer?.invalidate()
        onDemandStopTask?.cancel()
        streamQualityUpgradeTask?.cancel()
        initialOnDemandStartTask?.cancel()
        serverEventContinuation?.finish()
        serverEventTask?.cancel()
        remoteInputService.setEnabled(false)
        hostServer.stop()
    }

    func prepare() async {
        guard !isPrepared else { return }
        isPrepared = true
        runState = .starting
        refreshAuthorizationStatuses()
        refreshLoginItemStatus()
        remoteInputService.setDisplayID(selectedDisplayID)
        hostServer.setRemoteInputHandler { [remoteInputService] event in
            remoteInputService.handle(event)
        }
        do {
            let store = pairingSecretStore
            let pairingSecret = try await Task.detached(priority: .userInitiated) {
                try store.loadOrCreate()
            }.value
            startServer(pairingSecret: pairingSecret)
            startPairingCodeRefresh()
        } catch {
            fail(with: error)
            return
        }

        if screenRecordingAuthorization == .granted {
            await refreshDisplays()
        }
    }

    func toggleStreaming() async {
        if streamingDemand.wantsCapture || isStreaming {
            await stopStreaming()
        } else {
            await startStreaming()
        }
    }

    /// Explicit user start. Unlike authenticated on-demand capture, this keeps
    /// recording active until the user explicitly stops it.
    func startStreaming() async {
        guard !isTransitioning else { return }
        let effects = streamingDemand.requestManualStart()
        applyStreamingDemandEffects(effects)
        updateInitialOnDemandStartCoalescing()
        await reconcileCapturePipeline()
    }

    func keepStreamingAfterDisconnect() async {
        guard !isTransitioning else { return }
        let effects = streamingDemand.requestManualStart()
        applyStreamingDemandEffects(effects)
        updateInitialOnDemandStartCoalescing()
        await reconcileCapturePipeline()
    }

    func stopStreaming() async {
        guard !isTransitioning else { return }
        let effects = streamingDemand.requestManualStop()
        applyStreamingDemandEffects(effects)
        updateInitialOnDemandStartCoalescing()
        await reconcileCapturePipeline()
    }

    private func startCapturePipeline(
        quality: HostProtocol.StreamQuality
    ) async -> Bool {
        guard !isStreaming else { return true }
        guard isServerReady else {
            lastError = "The authenticated local streaming service is not ready yet."
            return false
        }

        let streamConfiguration = HostStreamQualityConfiguration(quality: quality)

        let requestedOwnership = streamingDemand.ownership
        updateScreenRecordingAuthorization()
        if screenRecordingAuthorization != .granted {
            // A remote connection must never cause a macOS consent prompt.
            // Permission requests remain tied to an explicit local user action.
            if requestedOwnership == .manual {
                requestScreenRecordingPermission()
            }
            guard screenRecordingAuthorization == .granted else {
                lastError = requestedOwnership == .onDemand
                    ? "Screen Recording permission is required for on-demand streaming. Allow it locally, then reconnect."
                    : "Allow Screen Recording in System Settings, then start streaming again."
                return false
            }
        }

        runState = .starting
        lastError = nil
        await refreshDisplays()

        let pipelineGeneration = pipelineGenerations.begin()
        let server = hostServer
        let encoder = H264Encoder(
            configuration: streamConfiguration.encoderConfiguration,
            outputHandler: { output in
                switch output {
                case .codecConfiguration(let configuration):
                    server.broadcastCodecConfiguration(
                        parameterSets: configuration.parameterSets,
                        nalUnitHeaderLength: configuration.nalUnitHeaderLength
                    )
                case .accessUnit(let accessUnit):
                    server.broadcastVideoAccessUnit(
                        accessUnit.data,
                        presentationTimeSeconds: accessUnit.presentationTimeSeconds,
                        durationSeconds: accessUnit.durationSeconds,
                        isKeyFrame: accessUnit.isKeyFrame
                    )
                }
            },
            errorHandler: { [weak self, pipelineGeneration] error in
                Task { @MainActor in
                    await self?.handlePipelineFailure(
                        error,
                        generation: pipelineGeneration
                    )
                }
            }
        )
        self.encoder = encoder
        hostServer.setKeyFrameRequestHandler { [weak encoder] in
            encoder?.requestKeyFrame()
        }

        do {
            let frames = try await captureService.start(
                displayID: selectedDisplayID,
                configuration: streamConfiguration.screenCaptureConfiguration,
                pipelineGeneration: pipelineGeneration
            )

            frameTask = Task { [weak self, encoder, pipelineGeneration] in
                do {
                    for await frame in frames {
                        try Task.checkCancellation()
                        try await encoder.encode(frame)
                    }
                } catch is CancellationError {
                    // Normal shutdown.
                } catch {
                    let failure = HostPipelineError(message: error.localizedDescription)
                    Task { @MainActor [weak self] in
                        await self?.handlePipelineFailure(
                            failure,
                            generation: pipelineGeneration
                        )
                    }
                }
            }

            isStreaming = true
            activeStreamQuality = quality
            remoteInputService.setEnabled(true)
            if isServerReady {
                runState = .ready
            }
            HostLog.capture.info(
                "Started \(streamConfiguration.framesPerSecond, privacy: .public) fps display capture at up to \(streamConfiguration.maximumWidth, privacy: .public)x\(streamConfiguration.maximumHeight, privacy: .public)"
            )
            return true
        } catch {
            pipelineGenerations.invalidate(pipelineGeneration)
            await encoder.finish()
            self.encoder = nil
            hostServer.setKeyFrameRequestHandler(nil)
            await hostServer.clearVideoState()
            fail(with: error)
            return false
        }
    }

    private func stopCapturePipeline() async {
        pipelineGenerations.invalidate()
        streamQualityUpgradeTask?.cancel()
        streamQualityUpgradeTask = nil
        remoteInputService.setEnabled(false)
        let frameTaskToStop = frameTask
        frameTask = nil
        frameTaskToStop?.cancel()
        await captureService.stop()
        if let frameTaskToStop {
            await frameTaskToStop.value
        }
        await encoder?.finish()
        encoder = nil
        hostServer.setKeyFrameRequestHandler(nil)
        await hostServer.clearVideoState()
        isStreaming = false
        activeStreamQuality = nil
        if !streamingDemand.wantsCapture,
           let pendingStreamQualityUpgrade {
            desiredStreamQuality = pendingStreamQualityUpgrade
            self.pendingStreamQualityUpgrade = nil
        }
        if isServerReady {
            runState = .ready
        } else if case .failed = runState {
            // Preserve the actionable server failure.
        } else {
            runState = .stopped
        }
        HostLog.capture.info("Stopped display capture")
    }

    func requestScreenRecordingPermission() {
        let granted = CGRequestScreenCaptureAccess()
        screenRecordingAuthorization = granted ? .granted : .denied
        if granted {
            Task {
                await refreshDisplays()
            }
        }
    }

    func requestAccessibilityPermission() {
        accessibilityAuthorization = RemoteInputService.requestAccessibilityAccess()
            ? .granted
            : .denied
    }

    func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshAuthorizationStatuses() {
        updateScreenRecordingAuthorization()
        accessibilityAuthorization = RemoteInputService.isAccessibilityGranted
            ? .granted
            : .denied
    }

    func setStartsAtLogin(_ enabled: Bool) {
        guard !isUpdatingLoginItem else { return }
        isUpdatingLoginItem = true
        defer { isUpdatingLoginItem = false }

        do {
            try loginItemService.setEnabled(enabled)
            loginItemStatus = loginItemService.status
            loginItemError = nil
            HostLog.app.notice("Start at login changed to \(enabled, privacy: .public)")
        } catch {
            loginItemStatus = loginItemService.status
            loginItemError = error.localizedDescription
            HostLog.app.error(
                "Could not change start at login: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func refreshLoginItemStatus() {
        let previousStatus = loginItemStatus
        loginItemStatus = loginItemService.status
        if loginItemStatus != previousStatus, loginItemStatus != .notFound {
            loginItemError = nil
        }
    }

    func openLoginItemSettings() {
        loginItemService.openSystemSettings()
    }

    func replacePairingKey() {
        do {
            let secret = try pairingSecretStore.replace()
            hostServer.replacePairingSecretAndRestart(secret.keyData)
            refreshPairingCode()
            let effects = streamingDemand.authenticatedClientCountChanged(to: 0)
            clientCount = streamingDemand.authenticatedClientCount
            remoteInputService.releasePressedInput()
            applyStreamingDemandEffects(effects)
            updateInitialOnDemandStartCoalescing()
            Task {
                await reconcileCapturePipeline()
            }
            lastError = nil
            HostLog.security.notice("Replaced the host pairing key")
        } catch {
            fail(with: error)
        }
    }

    func refreshDisplays() async {
        do {
            let availableDisplays = try await captureService.availableDisplays()
            displays = availableDisplays
            if selectedDisplayID == nil
                || !availableDisplays.contains(where: { $0.id == selectedDisplayID }) {
                selectedDisplayID = availableDisplays.first(where: \.isMain)?.id
                    ?? availableDisplays.first?.id
            }
        } catch {
            displays = []
            lastError = error.localizedDescription
            updateScreenRecordingAuthorization()
        }
    }

    private func handleAuthenticatedClientCountChange(_ count: Int) async {
        let previousCount = clientCount
        let effects = streamingDemand.authenticatedClientCountChanged(to: count)
        clientCount = streamingDemand.authenticatedClientCount
        if clientCount < previousCount {
            remoteInputService.releasePressedInput()
        }
        applyStreamingDemandEffects(effects)
        updateInitialOnDemandStartCoalescing()
        if clientCount > 0 {
            schedulePendingStreamQualityUpgradeIfNeeded()
        }
        await reconcileCapturePipeline()
    }

    private func handleStreamQualityChange(
        _ quality: HostProtocol.StreamQuality
    ) async {
        let previousRequestedQuality = pendingStreamQualityUpgrade
            ?? desiredStreamQuality
        guard quality != previousRequestedQuality else { return }

        let baselineQuality = activeStreamQuality ?? desiredStreamQuality
        let decision = HostStreamQualityUpdatePolicy.decision(
            currentQuality: baselineQuality,
            requestedQuality: quality,
            hasPipeline: isStreaming || isTransitioning,
            authenticatedClientCount: clientCount,
            isOnDemandGrace: isOnDemandStreaming && clientCount == 0
        )
        HostLog.capture.notice(
            "Stream quality changed to \(String(describing: quality), privacy: .public)"
        )

        switch decision {
        case .applyImmediately:
            cancelPendingStreamQualityUpgrade()
            desiredStreamQuality = quality
            if isInitialOnDemandStartDeferred,
               clientCount > 0,
               streamingOwnership == .onDemand {
                // The first viewer supplied an explicit preset during the
                // coalescing window, so there is no reason to wait for the
                // legacy-client fallback timer.
                cancelInitialOnDemandStartDelay()
            }
            await reconcileCapturePipeline()
        case .debounceUpgrade:
            pendingStreamQualityUpgrade = quality
            schedulePendingStreamQualityUpgradeIfNeeded()
        case .holdUpgrade:
            streamQualityUpgradeTask?.cancel()
            streamQualityUpgradeTask = nil
            pendingStreamQualityUpgrade = quality
        }
    }

    private func schedulePendingStreamQualityUpgradeIfNeeded() {
        guard pendingStreamQualityUpgrade != nil,
              isStreaming,
              clientCount > 0 || streamingOwnership == .manual else { return }

        streamQualityUpgradeTask?.cancel()
        streamQualityUpgradeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.streamQualityUpgradeDebounce)
            } catch {
                return
            }
            guard let self else { return }
            self.streamQualityUpgradeTask = nil

            guard self.clientCount > 0 || self.streamingOwnership == .manual,
                  self.isStreaming,
                  !self.isTransitioning,
                  let activeQuality = self.activeStreamQuality,
                  let pendingQuality = self.pendingStreamQualityUpgrade,
                  pendingQuality.rawValue > activeQuality.rawValue else { return }

            self.pendingStreamQualityUpgrade = nil
            self.desiredStreamQuality = pendingQuality
            await self.reconcileCapturePipeline()
        }
    }

    private func cancelPendingStreamQualityUpgrade(
        settleRequestedQuality: Bool = false
    ) {
        streamQualityUpgradeTask?.cancel()
        streamQualityUpgradeTask = nil
        if settleRequestedQuality,
           let pendingStreamQualityUpgrade {
            desiredStreamQuality = pendingStreamQualityUpgrade
        }
        pendingStreamQualityUpgrade = nil
    }

    private func updateInitialOnDemandStartCoalescing() {
        let decision = HostInitialOnDemandStartPolicy.decision(
            ownership: streamingOwnership,
            hasPipeline: isStreaming || isTransitioning,
            authenticatedClientCount: clientCount
        )

        switch decision {
        case .doNotDelay:
            cancelInitialOnDemandStartDelay()
        case .coalesce:
            scheduleInitialOnDemandStartIfNeeded()
        case .waitForViewer:
            initialOnDemandStartTask?.cancel()
            initialOnDemandStartTask = nil
            isInitialOnDemandStartDeferred = true
        }
    }

    private func scheduleInitialOnDemandStartIfNeeded() {
        isInitialOnDemandStartDeferred = true
        guard initialOnDemandStartTask == nil else { return }

        initialOnDemandStartTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.initialOnDemandStartDelay)
            } catch {
                return
            }
            guard let self else { return }
            self.initialOnDemandStartTask = nil

            guard self.streamingOwnership == .onDemand,
                  self.clientCount > 0,
                  !self.isStreaming else {
                self.isInitialOnDemandStartDeferred =
                    self.streamingOwnership == .onDemand && !self.isStreaming
                return
            }

            self.isInitialOnDemandStartDeferred = false
            await self.reconcileCapturePipeline()
        }
    }

    private func cancelInitialOnDemandStartDelay() {
        initialOnDemandStartTask?.cancel()
        initialOnDemandStartTask = nil
        isInitialOnDemandStartDeferred = false
    }

    private func applyStreamingDemandEffects(
        _ effects: [StreamingDemandPolicy.Effect]
    ) {
        for effect in effects {
            switch effect {
            case .cancelOnDemandStop:
                onDemandStopTask?.cancel()
                onDemandStopTask = nil
            case .scheduleOnDemandStop:
                scheduleOnDemandStop()
            case .startCapture(let ownership):
                HostLog.capture.notice(
                    "Capture requested by \(String(describing: ownership), privacy: .public) demand"
                )
            case .stopCapture:
                cancelInitialOnDemandStartDelay()
            }
        }
    }

    private func scheduleOnDemandStop() {
        onDemandStopTask?.cancel()
        onDemandStopTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.onDemandStopGrace)
            } catch {
                return
            }
            guard let self else { return }
            self.onDemandStopTask = nil
            let effects = self.streamingDemand.onDemandStopGraceExpired()
            self.applyStreamingDemandEffects(effects)
            await self.reconcileCapturePipeline()
        }
    }

    /// Reconciles desired ownership and quality with the media pipeline.
    /// Authentication, quality requests, manual actions, and the grace timer all
    /// run on the main actor, while the loop rechecks both desired values after
    /// every suspension to close lifecycle races.
    private func reconcileCapturePipeline() async {
        guard !isTransitioning else { return }
        guard !(isInitialOnDemandStartDeferred
            && !isStreaming
            && streamingOwnership == .onDemand) else { return }
        isTransitioning = true
        defer {
            isTransitioning = false
            schedulePendingStreamQualityUpgradeIfNeeded()
        }

        while streamingDemand.wantsCapture != isStreaming
            || (isStreaming && activeStreamQuality != desiredStreamQuality) {
            if !streamingDemand.wantsCapture || isStreaming {
                await stopCapturePipeline()
            } else {
                let qualityToStart = desiredStreamQuality
                let didStart = await startCapturePipeline(quality: qualityToStart)
                if !didStart {
                    let effects = streamingDemand.captureStartFailed()
                    applyStreamingDemandEffects(effects)
                    return
                }
            }
        }
    }

    private func startServer(pairingSecret: PairingSecret) {
        serverEventContinuation?.finish()
        serverEventTask?.cancel()

        let (events, continuation) = AsyncStream<ServerEvent>.makeStream()
        serverEventContinuation = continuation
        serverEventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }

                switch event {
                case .authenticatedClientCount(let count):
                    await handleAuthenticatedClientCountChange(count)
                case .status(let status):
                    handleServerStatus(status)
                case .streamQuality(let quality):
                    await handleStreamQualityChange(quality)
                }
            }
        }

        hostServer.setStreamQualityHandler { quality in
            continuation.yield(.streamQuality(quality))
        }

        hostServer.start(
            pairingSecret: pairingSecret.keyData,
            onClientCountChange: { count in
                continuation.yield(.authenticatedClientCount(count))
            },
            onStatusChange: { status in
                continuation.yield(.status(status))
            }
        )
    }

    private func handleServerStatus(_ status: HostServer.Status) {
        switch status {
        case .stopped:
            remoteInputService.setEnabled(false)
            isServerReady = false
            serverPort = nil
            if !isStreaming {
                runState = .stopped
            }
        case .starting:
            remoteInputService.setEnabled(false)
            isServerReady = false
            serverPort = nil
            runState = .starting
        case .listening(let port):
            remoteInputService.setEnabled(isStreaming)
            isServerReady = true
            serverPort = port
            runState = .ready
            lastError = nil
            refreshPairingCode()
        case .failed(let message):
            cancelPendingStreamQualityUpgrade(settleRequestedQuality: true)
            cancelInitialOnDemandStartDelay()
            remoteInputService.setEnabled(false)
            isServerReady = false
            serverPort = nil
            runState = .failed(message)
            lastError = message
            let effects = streamingDemand.forceStop()
            applyStreamingDemandEffects(effects)
            Task {
                await reconcileCapturePipeline()
            }
        }
    }

    private func startPairingCodeRefresh() {
        pairingCodeTimer?.invalidate()
        refreshPairingCode()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPairingCode()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pairingCodeTimer = timer
    }

    private func refreshPairingCode() {
        guard let code = hostServer.currentPairingCode() else {
            pairingCode = "Unavailable"
            pairingCodeRemainingSeconds = 0
            return
        }
        pairingCode = code.value
        pairingCodeRemainingSeconds = max(
            0,
            Int(ceil(code.expiresAt.timeIntervalSinceNow))
        )
    }

    private func updateScreenRecordingAuthorization() {
        screenRecordingAuthorization = CGPreflightScreenCaptureAccess()
            ? .granted
            : .denied
    }

    private func handleCaptureEvent(_ event: ScreenCaptureEvent) {
        switch event {
        case .started:
            break
        case .stopped(let generation):
            if pipelineGenerations.isCurrent(generation),
               isStreaming,
               !isTransitioning {
                pipelineGenerations.invalidate(generation)
                cancelPendingStreamQualityUpgrade(settleRequestedQuality: true)
                isStreaming = false
                activeStreamQuality = nil
                remoteInputService.setEnabled(false)
                let effects = streamingDemand.forceStop()
                applyStreamingDemandEffects(effects)
            }
        case .failed(let message, let generation):
            Task {
                await handlePipelineFailure(
                    HostPipelineError(message: message),
                    generation: generation
                )
            }
        }
    }

    private func handlePipelineFailure(
        _ error: any Error,
        generation: HostPipelineGeneration
    ) async {
        guard pipelineGenerations.isCurrent(generation),
              !isHandlingPipelineFailure else { return }
        isHandlingPipelineFailure = true
        let effects = streamingDemand.forceStop()
        applyStreamingDemandEffects(effects)
        await stopCapturePipeline()
        isHandlingPipelineFailure = false
        fail(with: error)
    }

    private func fail(with error: any Error) {
        let message = error.localizedDescription
        lastError = message
        runState = .failed(message)
        HostLog.app.error("Glassy Host failed: \(message, privacy: .public)")
    }
}

struct HostStreamQualityUpdatePolicy: Sendable {
    enum Decision: Equatable, Sendable {
        case applyImmediately
        case debounceUpgrade
        case holdUpgrade
    }

    static func decision(
        currentQuality: HostProtocol.StreamQuality,
        requestedQuality: HostProtocol.StreamQuality,
        hasPipeline: Bool,
        authenticatedClientCount: Int,
        isOnDemandGrace: Bool
    ) -> Decision {
        guard hasPipeline else { return .applyImmediately }
        guard requestedQuality.rawValue > currentQuality.rawValue else {
            return .applyImmediately
        }
        if authenticatedClientCount == 0, isOnDemandGrace {
            return .holdUpgrade
        }
        return .debounceUpgrade
    }
}

struct HostInitialOnDemandStartPolicy: Sendable {
    enum Decision: Equatable, Sendable {
        case doNotDelay
        case coalesce
        case waitForViewer
    }

    static func decision(
        ownership: StreamingDemandPolicy.Ownership?,
        hasPipeline: Bool,
        authenticatedClientCount: Int
    ) -> Decision {
        guard ownership == .onDemand, !hasPipeline else { return .doNotDelay }
        return authenticatedClientCount > 0 ? .coalesce : .waitForViewer
    }
}

struct HostPipelineGeneration: Equatable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

struct HostPipelineGenerationTracker: Sendable {
    private(set) var current: HostPipelineGeneration?

    mutating func begin() -> HostPipelineGeneration {
        let generation = HostPipelineGeneration()
        current = generation
        return generation
    }

    mutating func invalidate(_ generation: HostPipelineGeneration? = nil) {
        if let generation, generation != current { return }
        current = nil
    }

    func isCurrent(_ generation: HostPipelineGeneration) -> Bool {
        generation == current
    }
}

private struct HostPipelineError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}
