import AppKit
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class HostController {
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
    nonisolated(unsafe)
    private var pairingCodeTimer: Timer?

    @ObservationIgnored
    private var isPrepared = false

    @ObservationIgnored
    private var isServerReady = false

    @ObservationIgnored
    private var isHandlingPipelineFailure = false

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

    var startsAtLogin: Bool {
        loginItemStatus.isRequested
    }

    deinit {
        pairingCodeTimer?.invalidate()
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
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }

        if isStreaming {
            await stopStreaming()
        } else {
            await startStreaming()
        }
    }

    func startStreaming() async {
        guard !isStreaming else { return }
        guard isServerReady else {
            lastError = "The authenticated local streaming service is not ready yet."
            return
        }

        updateScreenRecordingAuthorization()
        if screenRecordingAuthorization != .granted {
            requestScreenRecordingPermission()
            guard screenRecordingAuthorization == .granted else {
                lastError = "Allow Screen Recording in System Settings, then start streaming again."
                return
            }
        }

        runState = .starting
        lastError = nil
        await refreshDisplays()

        let server = hostServer
        let encoder = H264Encoder(
            configuration: .init(
                expectedFrameRate: 60,
                averageBitRate: 12_000_000,
                keyFrameIntervalSeconds: 2
            ),
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
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    await self?.handlePipelineFailure(error)
                }
            }
        )
        self.encoder = encoder
        hostServer.setKeyFrameRequestHandler { [weak encoder] in
            encoder?.requestKeyFrame()
        }

        do {
            try await captureService.start(
                displayID: selectedDisplayID,
                configuration: .init(
                    framesPerSecond: 60,
                    maximumWidth: 3_840,
                    maximumHeight: 2_160,
                    showsCursor: true
                )
            )

            let frames = captureService.frames
            frameTask = Task { [weak self, encoder] in
                do {
                    for await frame in frames {
                        try Task.checkCancellation()
                        try await encoder.encode(frame)
                    }
                } catch is CancellationError {
                    // Normal shutdown.
                } catch {
                    await self?.handlePipelineFailure(error)
                }
            }

            isStreaming = true
            remoteInputService.setEnabled(true)
            if isServerReady {
                runState = .ready
            }
            HostLog.capture.info("Started 60 fps display capture")
        } catch {
            await encoder.finish()
            self.encoder = nil
            hostServer.setKeyFrameRequestHandler(nil)
            fail(with: error)
        }
    }

    func stopStreaming() async {
        remoteInputService.setEnabled(false)
        frameTask?.cancel()
        frameTask = nil
        await captureService.stop()
        await encoder?.finish()
        encoder = nil
        hostServer.setKeyFrameRequestHandler(nil)
        isStreaming = false
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
            clientCount = 0
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

    private func startServer(pairingSecret: PairingSecret) {
        hostServer.start(
            pairingSecret: pairingSecret.keyData,
            onClientCountChange: { [weak self] count in
                Task { @MainActor in
                    guard let self else { return }
                    let previousCount = self.clientCount
                    self.clientCount = count
                    if count < previousCount {
                        self.remoteInputService.releasePressedInput()
                    }
                }
            },
            onStatusChange: { [weak self] status in
                Task { @MainActor in
                    self?.handleServerStatus(status)
                }
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
            remoteInputService.setEnabled(false)
            isServerReady = false
            serverPort = nil
            runState = .failed(message)
            lastError = message
            if isStreaming {
                Task {
                    await stopStreaming()
                }
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
        case .stopped:
            if isStreaming && !isTransitioning {
                isStreaming = false
                remoteInputService.setEnabled(false)
            }
        case .failed(let message):
            Task {
                await handlePipelineFailure(HostPipelineError(message: message))
            }
        }
    }

    private func handlePipelineFailure(_ error: any Error) async {
        guard !isHandlingPipelineFailure else { return }
        isHandlingPipelineFailure = true
        await stopStreaming()
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

private struct HostPipelineError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}
