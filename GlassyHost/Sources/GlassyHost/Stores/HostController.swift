import AppKit
import Combine
import CoreGraphics
import Foundation
import Observation
import PermissionFlow

@MainActor
@Observable
final class HostController {
    private enum ServerEvent: Sendable {
        case authenticatedClientCount(Int)
        case status(HostServer.Status)
        case streamQuality(HostProtocol.StreamQuality)
        case pairedDevices([HostPairedDevice])
    }

    private(set) var runState: HostRunState = .stopped
    private(set) var screenRecordingAuthorization: ScreenRecordingAuthorization = .unknown
    private(set) var accessibilityAuthorization: AccessibilityAuthorization = .unknown
    private(set) var displays: [CaptureDisplay] = []
    private(set) var isStreaming = false
    private(set) var clientCount = 0
    private(set) var pairingCode = "Starting…"
    private(set) var pairingCodeRemainingSeconds = 0
    private(set) var pairingCodeExpiresAt: Date?
    private(set) var pairingAddresses: [String] = []
    private(set) var pairingHostIdentifier: Data?
    private(set) var pairedDevices: [HostPairedDevice] = []
    private(set) var allowsConnections = true
    private(set) var isUpdatingConnectionAccess = false
    private(set) var isPairingPasswordConfigured = false
    private(set) var isLoadingPairingPassword = false
    private(set) var isUpdatingPairingPassword = false
    private(set) var pairingPasswordError: String?
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
    private let pairingPasswordStore = PairingPasswordStore()
    private let hostServer = HostServer()
    private let loginItemService = LoginItemService()
    private let remoteInputService = RemoteInputService()

    @ObservationIgnored
    private var permissionFlowController: PermissionFlowController?

    @ObservationIgnored
    private var authorizationActivationObserver: AnyCancellable?

    @ObservationIgnored
    private let pairingAddressService = HostPairingAddressService()

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
    private var hostIdentifier: Data?

    @ObservationIgnored
    private var pairingPasswordLoadTask: Task<Void, Never>?

    @ObservationIgnored
    private var pairingPasswordLoadState = HostPairingPasswordLoadState()

    private var pipelineReconciliation = HostPipelineReconciliationState()

    @ObservationIgnored
    private var pipelineReconciliationWaiters: [CheckedContinuation<Void, Never>] = []

    @ObservationIgnored
    private var pendingPipelineFailure: HostPendingPipelineFailure?

    @ObservationIgnored
    private var pipelineRetryTask: Task<Void, Never>?

    @ObservationIgnored
    private var pipelineRetryStabilityTask: Task<Void, Never>?

    @ObservationIgnored
    private var pipelineRetryAttempt = 0

    private var isPipelineRetryDeferred = false

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
    private static let pipelineRetryStabilityInterval: Duration = .seconds(10)

    init() {
        allowsConnections = hostServer.allowsConnections
        pairedDevices = hostServer.pairedDevices
        // The menu-bar host outlives its dashboard. A Settings visit must also
        // refresh permissions when the guide was opened without a main window.
        authorizationActivationObserver = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshAuthorizationStatuses()
            }
    }

    var isTransitioning: Bool {
        pipelineReconciliation.hasOwner
    }

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
        if !allowsConnections {
            return "Connections are off. Enable them to connect a device."
        }
        if isPipelineRetryDeferred {
            return "Recovering screen stream…"
        }
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
        pipelineRetryTask?.cancel()
        pipelineRetryStabilityTask?.cancel()
        pairingPasswordLoadTask?.cancel()
        serverEventContinuation?.finish()
        serverEventTask?.cancel()
        remoteInputService.setEnabled(false)
        hostServer.stop()
    }

    func prepare() async {
        guard !isPrepared else { return }
        isPrepared = true
        pairingAddressService.start { [weak self] addresses in
            Task { @MainActor [weak self] in
                guard let self, pairingAddresses != addresses else { return }
                pairingAddresses = addresses
            }
        }
        runState = .starting
        refreshAuthorizationStatuses()
        refreshLoginItemStatus()
        remoteInputService.setDisplayID(selectedDisplayID)
        hostServer.setRemoteInputHandler { [remoteInputService] event in
            remoteInputService.handle(event)
        }
        hostServer.setAuthenticatedClientReplacementHandler { [remoteInputService] in
            remoteInputService.releasePressedInput()
        }
        do {
            let store = pairingSecretStore
            let pairingSecret = try await Task.detached(priority: .userInitiated) {
                try store.loadOrCreate()
            }.value
            let identifier = HostServer.makeHostIdentifier(from: pairingSecret.keyData)
            hostIdentifier = identifier
            pairingHostIdentifier = identifier

            startServer(
                pairingSecret: pairingSecret,
                pairingPasswordCredential: nil
            )
            startPairingCodeRefresh()
            loadPairingPassword(for: identifier)
        } catch {
            fail(with: error)
            return
        }

        if screenRecordingAuthorization == .granted {
            await refreshDisplays()
        }
    }

    private func loadPairingPassword(for identifier: Data) {
        let request = pairingPasswordLoadState.begin(for: identifier)
        let passwordStore = pairingPasswordStore
        isLoadingPairingPassword = true
        pairingPasswordLoadTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try passwordStore.credential(for: identifier) }
            }.value
            guard let self, !Task.isCancelled,
                  pairingPasswordLoadState.accepts(request, hostIdentifier: hostIdentifier) else { return }
            isLoadingPairingPassword = false
            pairingPasswordLoadTask = nil
            switch result {
            case .success(let credential):
                hostServer.setPairingPasswordCredential(credential)
                isPairingPasswordConfigured = credential != nil
                pairingPasswordError = nil
            case .failure(let error):
                // Keychain may fail or remain busy. Neither outcome blocks
                // QR/code pairing, Bonjour, or display discovery.
                isPairingPasswordConfigured = false
                pairingPasswordError = error.localizedDescription
                HostLog.security.error("Could not load the optional pairing password credential")
            }
        }
    }

    private func invalidatePairingPasswordLoad() {
        pairingPasswordLoadState.invalidate()
        pairingPasswordLoadTask?.cancel()
        pairingPasswordLoadTask = nil
        isLoadingPairingPassword = false
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
        guard allowsConnections else { return }
        let effects = streamingDemand.requestManualStart()
        applyStreamingDemandEffects(effects)
        updateInitialOnDemandStartCoalescing()
        await reconcileCapturePipeline()
    }

    func keepStreamingAfterDisconnect() async {
        guard allowsConnections else { return }
        let effects = streamingDemand.requestManualStart()
        applyStreamingDemandEffects(effects)
        updateInitialOnDemandStartCoalescing()
        await reconcileCapturePipeline()
    }

    func stopStreaming() async {
        let effects = streamingDemand.requestManualStop()
        applyStreamingDemandEffects(effects)
        updateInitialOnDemandStartCoalescing()
        await reconcileCapturePipeline()
    }

    func setAllowsConnections(_ allowsConnections: Bool) async {
        guard !isUpdatingConnectionAccess, self.allowsConnections != allowsConnections else { return }
        isUpdatingConnectionAccess = true
        let previousValue = self.allowsConnections
        let previousServerReady = isServerReady
        let previousServerPort = serverPort
        self.allowsConnections = allowsConnections
        defer { isUpdatingConnectionAccess = false }

        if !allowsConnections {
            // Close the local input gate before suspending. Buffered listener
            // callbacks must not revive capture while shutdown is in progress.
            remoteInputService.setEnabled(false)
            isServerReady = false
            serverPort = nil
            refreshPairingCode()
        }
        do {
            try await hostServer.setAllowsConnections(allowsConnections)
            if !allowsConnections {
                cancelPendingStreamQualityUpgrade(settleRequestedQuality: true)
                cancelInitialOnDemandStartDelay()
                let effects = streamingDemand.forceStop()
                applyStreamingDemandEffects(effects)
                await handleAuthenticatedClientCountChange(0)
                await reconcileCapturePipeline()
                if pipelineReconciliation.hasOwner {
                    await withCheckedContinuation { continuation in
                        pipelineReconciliationWaiters.append(continuation)
                    }
                }
                runState = .stopped
            }
            lastError = nil
        } catch {
            self.allowsConnections = previousValue
            lastError = "Could not save connection access: \(error.localizedDescription)"
            if previousValue {
                // A failed atomic write leaves the server running with its
                // original permissions. Restore the local presentation/gate.
                isServerReady = previousServerReady
                serverPort = previousServerPort
                remoteInputService.setEnabled(previousServerReady && isStreaming)
            }
        }
        refreshPairingCode()
    }

    func revokeDevice(id: Data) async {
        guard !isUpdatingConnectionAccess else { return }
        isUpdatingConnectionAccess = true
        defer { isUpdatingConnectionAccess = false }
        do {
            try await hostServer.revokeDevice(id: id)
            pairedDevices.removeAll { $0.id == id }
            lastError = nil
        } catch {
            lastError = "Could not revoke device access: \(error.localizedDescription)"
        }
    }

    private func startCapturePipeline(
        quality: HostProtocol.StreamQuality
    ) async -> HostCapturePipelineStartResult {
        guard !isStreaming else { return .started }
        guard allowsConnections, isServerReady else {
            lastError = "The authenticated local streaming service is not ready yet."
            return .terminalFailure
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
                return .terminalFailure
            }
        }

        runState = .starting
        lastError = nil
        await refreshDisplays()
        guard allowsConnections, isServerReady, streamingDemand.wantsCapture else {
            return .superseded
        }

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
            let captureDisplayID = selectedDisplayID
                ?? displays.first(where: \.isMain)?.id
                ?? displays.first?.id
                ?? CGMainDisplayID()
            let cursorDisplayBounds = CGDisplayBounds(captureDisplayID)
            let frames = try await captureService.start(
                displayID: captureDisplayID,
                configuration: streamConfiguration.screenCaptureConfiguration,
                pipelineGeneration: pipelineGeneration
            )
            guard pipelineGenerations.isCurrent(pipelineGeneration) else {
                return .superseded
            }

            frameTask = Task { [weak self, encoder, pipelineGeneration] in
                var cursorPositionTracker = HostCursorPositionTracker()
                do {
                    for await frame in frames {
                        try Task.checkCancellation()
                        switch cursorPositionTracker.update(
                            for: CGEvent(source: nil)?.location,
                            in: cursorDisplayBounds
                        ) {
                        case .some(.position(let cursorPosition)):
                            server.broadcastCursorPosition(cursorPosition)
                        case .some(.unavailable):
                            server.clearCursorPosition()
                        case .none:
                            break
                        }
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
            remoteInputService.setEnabled(allowsConnections && isServerReady)
            if isServerReady {
                runState = .ready
            }
            HostLog.capture.info(
                "Started \(streamConfiguration.framesPerSecond, privacy: .public) fps display capture at up to \(streamConfiguration.maximumWidth, privacy: .public)x\(streamConfiguration.maximumHeight, privacy: .public)"
            )
            capturePipelineDidStart(generation: pipelineGeneration)
            return .started
        } catch {
            pipelineGenerations.invalidate(pipelineGeneration)
            if self.encoder === encoder {
                self.encoder = nil
                hostServer.setKeyFrameRequestHandler(nil)
            }
            await encoder.finish()
            await hostServer.clearVideoState()
            fail(with: error)
            return .retryableFailure
        }
    }

    private func stopCapturePipeline(
        retiring generation: HostPipelineGeneration? = nil
    ) async {
        pipelineGenerations.invalidate(generation)
        cancelPipelineRetry(resetAttempt: generation == nil)
        streamQualityUpgradeTask?.cancel()
        streamQualityUpgradeTask = nil
        remoteInputService.setEnabled(false)

        // Detach the retiring resources before suspending. Reentrant lifecycle
        // events can update desired state while cleanup is in flight, but only
        // the reconciliation owner may install a successor after these locals
        // have been fully retired.
        let frameTaskToStop = frameTask
        frameTask = nil
        let encoderToStop = encoder
        encoder = nil
        hostServer.setKeyFrameRequestHandler(nil)

        frameTaskToStop?.cancel()
        await captureService.stop()
        if let frameTaskToStop {
            await frameTaskToStop.value
        }
        await encoderToStop?.finish()
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
        guidePermission(.screenRecording)
    }

    func requestAccessibilityPermission() {
        guidePermission(.accessibility)
    }

    func refreshAuthorizationStatuses() {
        let previouslyAllowedScreenRecording = screenRecordingAuthorization == .granted
        updateScreenRecordingAuthorization()
        accessibilityAuthorization = RemoteInputService.isAccessibilityGranted
            ? .granted
            : .denied

        // Preparing the host loads displays separately. After a Settings visit,
        // make the display picker available as soon as macOS reports access.
        if !previouslyAllowedScreenRecording,
           screenRecordingAuthorization == .granted,
           isServerReady {
            Task { await refreshDisplays() }
        }

        if let pane = permissionFlowController?.currentPane,
           (pane == .screenRecording && screenRecordingAuthorization == .granted)
            || (pane == .accessibility && accessibilityAuthorization == .granted) {
            permissionFlowController?.closePanel()
            permissionFlowController = nil
        }
    }

    private func guidePermission(_ pane: PermissionFlowPane) {
        refreshAuthorizationStatuses()
        guard (pane == .screenRecording && screenRecordingAuthorization != .granted)
            || (pane == .accessibility && accessibilityAuthorization != .granted) else { return }

        // Keep one guide across dashboard windows and menu-bar actions. Do not
        // request Accessibility just to position the Screen Recording guide.
        if permissionFlowController == nil {
            permissionFlowController = PermissionFlow.makeController(
                configuration: .init(promptForAccessibilityTrust: false)
            )
        }
        let pointer = NSEvent.mouseLocation
        permissionFlowController?.authorize(
            pane: pane,
            suggestedAppURLs: [Bundle.main.bundleURL],
            sourceFrameInScreen: CGRect(x: pointer.x - 16, y: pointer.y - 16, width: 32, height: 32)
        )
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

    @discardableResult
    func setPairingPassword(_ password: String) async -> Bool {
        guard !isUpdatingPairingPassword else { return false }
        guard let hostIdentifier else {
            pairingPasswordError = PairingPasswordPolicyError.invalidHostIdentifier
                .localizedDescription
            return false
        }

        invalidatePairingPasswordLoad()
        isUpdatingPairingPassword = true
        defer { isUpdatingPairingPassword = false }
        do {
            let store = pairingPasswordStore
            let credential = try await Task.detached(priority: .userInitiated) {
                let credential = try PairingPasswordPolicy.deriveCredential(
                    from: password,
                    hostIdentifier: hostIdentifier
                )
                try store.save(credential, for: hostIdentifier)
                return credential
            }.value
            hostServer.setPairingPasswordCredential(credential)
            isPairingPasswordConfigured = true
            pairingPasswordError = nil
            HostLog.security.notice("Configured an optional pairing password")
            return true
        } catch {
            pairingPasswordError = error.localizedDescription
            HostLog.security.error("Could not configure the optional pairing password")
            return false
        }
    }

    @discardableResult
    func removePairingPassword() async -> Bool {
        guard !isUpdatingPairingPassword else { return false }
        guard let hostIdentifier else {
            pairingPasswordError = PairingPasswordPolicyError.invalidHostIdentifier
                .localizedDescription
            return false
        }

        invalidatePairingPasswordLoad()
        isUpdatingPairingPassword = true
        defer { isUpdatingPairingPassword = false }
        do {
            let store = pairingPasswordStore
            try await Task.detached(priority: .userInitiated) {
                try store.deleteCredential(for: hostIdentifier)
            }.value
            hostServer.setPairingPasswordCredential(nil)
            isPairingPasswordConfigured = false
            pairingPasswordError = nil
            HostLog.security.notice("Removed the optional pairing password")
            return true
        } catch {
            pairingPasswordError = error.localizedDescription
            HostLog.security.error("Could not remove the optional pairing password")
            return false
        }
    }

    func replacePairingKey() async {
        guard !isUpdatingPairingPassword else { return }
        invalidatePairingPasswordLoad()
        isUpdatingPairingPassword = true
        defer { isUpdatingPairingPassword = false }

        do {
            if let hostIdentifier {
                let passwordStore = pairingPasswordStore
                try await Task.detached(priority: .userInitiated) {
                    try passwordStore.deleteCredential(for: hostIdentifier)
                }.value
            }
            hostServer.setPairingPasswordCredential(nil)
            isPairingPasswordConfigured = false
            pairingPasswordError = nil

            let secretStore = pairingSecretStore
            let secret = try await Task.detached(priority: .userInitiated) {
                try secretStore.replace()
            }.value
            hostIdentifier = HostServer.makeHostIdentifier(from: secret.keyData)
            pairingHostIdentifier = hostIdentifier
            hostServer.replacePairingSecretAndRestart(secret.keyData)
            refreshPairingCode()
            let effects = streamingDemand.authenticatedClientCountChanged(to: 0)
            clientCount = streamingDemand.authenticatedClientCount
            remoteInputService.releasePressedInput()
            applyStreamingDemandEffects(effects)
            updateInitialOnDemandStartCoalescing()
            await reconcileCapturePipeline()
            lastError = nil
            HostLog.security.notice(
                "Replaced the host pairing key and disabled its optional pairing password"
            )
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
        guard allowsConnections || count == 0 else { return }
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

    private func schedulePipelineRetryIfNeeded() {
        guard streamingDemand.wantsCapture else {
            cancelPipelineRetry(resetAttempt: true)
            return
        }
        guard pipelineRetryTask == nil else { return }

        pipelineRetryAttempt += 1
        let attempt = pipelineRetryAttempt
        let delay = HostPipelineRetryPolicy.delay(forAttempt: attempt)
        isPipelineRetryDeferred = true
        HostLog.capture.notice(
            "Retrying capture after transient pipeline failure (attempt \(attempt, privacy: .public))"
        )

        pipelineRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            self.pipelineRetryTask = nil
            self.isPipelineRetryDeferred = false
            guard self.streamingDemand.wantsCapture else {
                self.pipelineRetryAttempt = 0
                return
            }
            await self.reconcileCapturePipeline()
        }
    }

    private func capturePipelineDidStart(
        generation: HostPipelineGeneration
    ) {
        pipelineRetryTask?.cancel()
        pipelineRetryTask = nil
        isPipelineRetryDeferred = false
        pipelineRetryStabilityTask?.cancel()
        pipelineRetryStabilityTask = nil

        guard pipelineRetryAttempt > 0 else { return }
        pipelineRetryStabilityTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.pipelineRetryStabilityInterval)
            } catch {
                return
            }
            guard let self,
                  self.pipelineGenerations.isCurrent(generation),
                  self.isStreaming else { return }
            self.pipelineRetryAttempt = 0
            self.pipelineRetryStabilityTask = nil
        }
    }

    private func cancelPipelineRetry(resetAttempt: Bool) {
        pipelineRetryTask?.cancel()
        pipelineRetryTask = nil
        pipelineRetryStabilityTask?.cancel()
        pipelineRetryStabilityTask = nil
        isPipelineRetryDeferred = false
        if resetAttempt {
            pipelineRetryAttempt = 0
        }
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
                cancelPipelineRetry(resetAttempt: true)
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
    /// run on the main actor. Reentrant callers only mark the state dirty; the
    /// existing owner then rechecks failure, demand, and quality after every
    /// suspension. This keeps all pipeline cleanup and replacement serialized.
    private func reconcileCapturePipeline() async {
        guard pipelineReconciliation.request() else { return }
        defer {
            pipelineReconciliation.release()
            let waiters = pipelineReconciliationWaiters
            pipelineReconciliationWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            schedulePendingStreamQualityUpgradeIfNeeded()
        }

        while true {
            pipelineReconciliation.beginPass()

            if let failure = pendingPipelineFailure {
                pendingPipelineFailure = nil
                await stopCapturePipeline(retiring: failure.generation)
                fail(with: failure.error)
                let effects = streamingDemand.captureStartFailed(
                    isRetryable: true
                )
                applyStreamingDemandEffects(effects)
                schedulePipelineRetryIfNeeded()
            } else if !(isInitialOnDemandStartDeferred
                && !isStreaming
                && streamingOwnership == .onDemand)
                && !isPipelineRetryDeferred {
                if !streamingDemand.wantsCapture
                    || (isStreaming && activeStreamQuality != desiredStreamQuality) {
                    await stopCapturePipeline()
                } else if streamingDemand.wantsCapture, !isStreaming {
                    let qualityToStart = desiredStreamQuality
                    let result = await startCapturePipeline(quality: qualityToStart)
                    if pendingPipelineFailure == nil {
                        switch result {
                        case .started, .superseded:
                            break
                        case .retryableFailure:
                            let effects = streamingDemand.captureStartFailed(
                                isRetryable: true
                            )
                            applyStreamingDemandEffects(effects)
                            schedulePipelineRetryIfNeeded()
                        case .terminalFailure:
                            let effects = streamingDemand.captureStartFailed(
                                isRetryable: false
                            )
                            applyStreamingDemandEffects(effects)
                            cancelPipelineRetry(resetAttempt: true)
                        }
                    }
                }
            }

            guard pipelineReconciliation.shouldContinue(
                isReconciled: isCapturePipelineReconciled
            ) else { return }
        }
    }

    private var isCapturePipelineReconciled: Bool {
        guard pendingPipelineFailure == nil else { return false }
        if isInitialOnDemandStartDeferred,
           !isStreaming,
           streamingOwnership == .onDemand {
            return true
        }
        if isPipelineRetryDeferred,
           !isStreaming,
           streamingDemand.wantsCapture {
            return true
        }
        return streamingDemand.wantsCapture == isStreaming
            && (!isStreaming || activeStreamQuality == desiredStreamQuality)
    }

    private func startServer(
        pairingSecret: PairingSecret,
        pairingPasswordCredential: Data?
    ) {
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
                case .pairedDevices(let devices):
                    pairedDevices = devices
                }
            }
        }

        hostServer.setStreamQualityHandler { quality in
            continuation.yield(.streamQuality(quality))
        }
        hostServer.setPairedDevicesHandler { devices in
            continuation.yield(.pairedDevices(devices))
        }

        hostServer.start(
            pairingSecret: pairingSecret.keyData,
            pairingPasswordCredential: pairingPasswordCredential,
            onClientCountChange: { count in
                continuation.yield(.authenticatedClientCount(count))
            },
            onStatusChange: { status in
                continuation.yield(.status(status))
            }
        )
    }

    private func handleServerStatus(_ status: HostServer.Status) {
        if !allowsConnections {
            remoteInputService.setEnabled(false)
            isServerReady = false
            serverPort = nil
            runState = .stopped
            refreshPairingCode()
            return
        }
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
        guard allowsConnections, let code = hostServer.currentPairingCode() else {
            pairingCode = allowsConnections ? "Unavailable" : "Connections off"
            pairingCodeRemainingSeconds = 0
            pairingCodeExpiresAt = nil
            return
        }
        pairingCode = code.value
        pairingCodeExpiresAt = code.expiresAt
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
            Task {
                await handlePipelineFailure(
                    HostPipelineError(message: "Screen capture stopped unexpectedly."),
                    generation: generation
                )
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
        guard pipelineGenerations.isCurrent(generation) else { return }

        // Invalidate before any suspension so duplicate callbacks and callbacks
        // from a retiring encoder cannot affect a later generation. Demand is
        // intentionally retained: explicit manual stop still clears it, while
        // authenticated viewers cause reconciliation to replace this pipeline.
        pipelineGenerations.invalidate(generation)
        pendingPipelineFailure = HostPendingPipelineFailure(
            generation: generation,
            error: HostPipelineError(message: error.localizedDescription)
        )
        await reconcileCapturePipeline()
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

struct HostPipelineRetryPolicy: Sendable {
    static func delay(forAttempt attempt: Int) -> Duration {
        switch max(1, attempt) {
        case 1:
            .milliseconds(250)
        case 2:
            .milliseconds(500)
        case 3:
            .seconds(1)
        case 4:
            .seconds(2)
        default:
            .seconds(4)
        }
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

/// Coalesces lifecycle changes while one main-actor task owns pipeline
/// transitions. A request made during an `await` is never lost: it causes the
/// owner to run another pass with the newest controller state.
struct HostPipelineReconciliationState: Sendable {
    private(set) var hasOwner = false
    private(set) var hasPendingRequest = false

    /// Returns `true` only to the caller that acquires transition ownership.
    mutating func request() -> Bool {
        hasPendingRequest = true
        guard !hasOwner else { return false }
        hasOwner = true
        return true
    }

    mutating func beginPass() {
        precondition(hasOwner)
        hasPendingRequest = false
    }

    func shouldContinue(isReconciled: Bool) -> Bool {
        hasPendingRequest || !isReconciled
    }

    mutating func release() {
        precondition(hasOwner)
        hasOwner = false
        hasPendingRequest = false
    }
}

private struct HostPendingPipelineFailure: Sendable {
    let generation: HostPipelineGeneration
    let error: HostPipelineError
}

private enum HostCapturePipelineStartResult: Equatable, Sendable {
    case started
    case retryableFailure
    case terminalFailure
    case superseded
}

private struct HostPipelineError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}
