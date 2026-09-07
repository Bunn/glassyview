import CoreGraphics
import Foundation
import Network
import Observation

enum GlassyStreamSessionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case failed
}

/// A UI-facing error from either the encrypted transport or the H.264 renderer.
enum GlassyStreamSessionError: Error, LocalizedError, Sendable {
    case cancelled
    case connectionEndedBeforeAuthentication
    case videoReadinessTimedOut
    case transport(GlassyStreamClientError)
    case video(GlassyStreamVideoRendererError)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            String(localized: "The fast connection was cancelled.")
        case .connectionEndedBeforeAuthentication:
            String(localized: "Glassy Desk ended the connection before authentication completed.")
        case .videoReadinessTimedOut:
            String(localized: "The secure connection succeeded, but Glassy Desk could not start video automatically. On the Mac, check Screen Recording access and the selected display, then reconnect.")
        case let .transport(error):
            error.localizedDescription
        case let .video(error):
            error.localizedDescription
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .cancelled:
            nil
        case .connectionEndedBeforeAuthentication:
            String(localized: "Make sure Glassy Desk is running. For remote access, connect Tailscale on both devices and verify TCP port 51515 is allowed by your tailnet policy.")
        case .videoReadinessTimedOut:
            String(localized: "Open Glassy Desk, allow Screen Recording, check the selected display, and reconnect.")
        case let .transport(error):
            switch error {
            case .pairingCodeRequired:
                String(localized: "Enter the current twelve-symbol code, or choose Password if Glassy Desk has a reusable pairing password configured.")
            case .invalidPairingCode, .authenticationRejected:
                String(localized: "Check the selected code or password and try pairing again.")
            case .invalidPairingPassword:
                String(localized: "Use a 15 through 128 character password without control characters or line breaks.")
            case .pairingPasswordRequiresTailscale:
                String(localized: "Connect Tailscale on this iPad, confirm the selected peer is your Mac, and save its 100.64–100.127 address, Tailscale IPv6 address, or full .ts.net name. Otherwise, use the one-time code.")
            case .pairingPasswordUnsupported:
                String(localized: "Update Glassy Desk or pair with its current one-time code instead.")
            case .pairingPasswordDerivationFailed:
                String(localized: "Restart Glassy Desk and try again, or use the current one-time code.")
            case .hostIdentityMismatch:
                String(localized: "The saved address reached a different Mac. Check the Tailscale name or IP, or choose Pair a Different Mac in the machine editor.")
            case .directInputUnsupported, .unsupportedHostVersion:
                String(localized: "Update Glassy Desk on both devices, then try again.")
            case .credentialStoreFailed:
                String(localized: "Check Keychain access on this device, then pair again.")
            default:
                String(localized: "Make sure Glassy Desk is running. For remote access, connect Tailscale on both devices and verify the saved address and TCP port 51515.")
            }
        case .video:
            String(localized: "Reconnect to request a fresh video configuration and keyframe.")
        }
    }
}

/// Owns one Glassy Stream transport and its low-latency video renderer.
///
/// `connect` returns as soon as the encrypted session is authenticated. The
/// controller continues consuming video events until `disconnect` is called or
/// the transport fails.
@MainActor
@Observable
final class GlassyStreamSessionController {
    private(set) var state: GlassyStreamSessionState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChanged?(state, error)
        }
    }
    private(set) var error: GlassyStreamSessionError?
    private(set) var authentication: GlassyStreamAuthentication?
    private(set) var videoDimensions: CGSize?
    private(set) var hostStatus: GlassyStreamHostStatus?

    var isConnected: Bool {
        state == .connected
    }

    @ObservationIgnored
    let renderer: GlassyStreamVideoRenderer

    @ObservationIgnored
    private let client: GlassyStreamClient

    @ObservationIgnored
    private let videoReadinessTimeout: TimeInterval

    @ObservationIgnored
    private var activeGeneration: UUID?

    @ObservationIgnored
    private var authenticationWaiter: AuthenticationWaiter?

    @ObservationIgnored
    private var videoReadinessTask: Task<Void, Never>?

    @ObservationIgnored
    var onStateChanged: (@MainActor @Sendable (GlassyStreamSessionState, GlassyStreamSessionError?) -> Void)?

    @ObservationIgnored
    var onVideoDimensionsChanged: (@MainActor @Sendable (CGSize?) -> Void)?

    @ObservationIgnored
    var onCursorPositionChanged: (@MainActor @Sendable (GlassyStreamCursorPosition) -> Void)?

    init(
        client: GlassyStreamClient = GlassyStreamClient(),
        renderer: GlassyStreamVideoRenderer = GlassyStreamVideoRenderer(),
        videoReadinessTimeout: TimeInterval = 15
    ) {
        self.client = client
        self.renderer = renderer
        self.videoReadinessTimeout = videoReadinessTimeout
    }

    /// Opens an encrypted Glassy Stream connection and waits for authentication.
    ///
    /// Pass `nil` for `bootstrapCredential` to resume a previously paired saved
    /// machine. A new call replaces any in-flight or connected session owned by
    /// this controller.
    @discardableResult
    func connect(
        endpoint: NWEndpoint,
        savedMachineID: UUID,
        bootstrapCredential: GlassyStreamBootstrapCredential?,
        expectedHostIdentifier: Data? = nil,
        desiredQuality: RemoteSessionQuality = .best,
        fallbackEndpoints: [NWEndpoint] = []
    ) async throws -> GlassyStreamAuthentication {
        disconnectCurrentSession(clearError: true)

        let generation = UUID()
        activeGeneration = generation
        authentication = nil
        hostStatus = nil
        videoDimensions = nil
        error = nil
        state = .connecting
        renderer.reset()
        installRendererCallbacks(generation: generation)

        let configuration = GlassyStreamConnectionConfiguration(
            endpoint: endpoint,
            savedMachineID: savedMachineID,
            bootstrapCredential: bootstrapCredential,
            expectedHostIdentifier: expectedHostIdentifier,
            desiredQuality: desiredQuality,
            fallbackEndpoints: fallbackEndpoints
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<GlassyStreamAuthentication, Error>) in
                guard activeGeneration == generation, state == .connecting else {
                    continuation.resume(throwing: GlassyStreamSessionError.cancelled)
                    return
                }

                authenticationWaiter = AuthenticationWaiter(
                    generation: generation,
                    continuation: continuation
                )

                let consumeMedia = renderer.makeMediaConsumer()
                client.connect(
                    configuration: configuration,
                    callbackQueue: renderer.mediaQueue,
                    callbacks: GlassyStreamClientCallbacks(
                        onEvent: { [weak self] event in
                            if consumeMedia(event) { return }
                            Task { @MainActor [weak self] in
                                self?.receive(event, generation: generation)
                            }
                        },
                        onCompletion: { [weak self] result in
                            Task { @MainActor [weak self] in
                                self?.complete(result, generation: generation)
                            }
                        }
                    )
                )
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancel(generation: generation)
            }
        }
    }

    /// Stops networking, clears the displayed image, and returns to idle.
    func disconnect() {
        disconnectCurrentSession(clearError: true)
    }

    func setStreamQuality(_ quality: RemoteSessionQuality) {
        guard state == .connected,
              authentication?.supportsStreamQuality == true else { return }
        client.setStreamQuality(quality)
    }

#if DEBUG
    func debugSimulateConnectionInterruption() {
        guard let activeGeneration, state == .connected else { return }
        fail(.transport(.connectionClosed), generation: activeGeneration)
    }
#endif

    private func receive(_ event: GlassyStreamEvent, generation: UUID) {
        guard activeGeneration == generation else { return }

        switch event {
        case let .authenticated(authentication):
            self.authentication = authentication
            state = .connected
            scheduleVideoReadinessTimeout(generation: generation)
            takeAuthenticationWaiter(generation: generation)?
                .resume(returning: authentication)

        case .videoConfiguration, .videoAccessUnit, .videoDiscontinuity:
            break // Consumed synchronously on the bounded media worker.

        case .hostStreamStatus(let status):
            hostStatus = status
            if status.state != .starting && status.state != .streaming {
                // Keep the authenticated connection alive so local permission
                // recovery can resume it and the actionable host status remains.
                cancelVideoReadinessTimeout()
            } else if !renderer.isDisplayingVideo, videoReadinessTask == nil {
                scheduleVideoReadinessTimeout(generation: generation)
            }

        case let .cursorPosition(position):
            guard state == .connected,
                  authentication?.supportsCursorPositionUpdates == true else { return }
            onCursorPositionChanged?(position)

        case .pong:
            break
        }
    }

    private func complete(
        _ result: Result<Void, GlassyStreamClientError>,
        generation: UUID
    ) {
        guard activeGeneration == generation else { return }

        switch result {
        case .success:
            if state == .connecting {
                fail(.connectionEndedBeforeAuthentication, generation: generation)
            } else {
                disconnectCurrentSession(clearError: true)
            }

        case let .failure(clientError):
            if case .cancelled = clientError {
                cancel(generation: generation)
            } else {
                fail(.transport(clientError), generation: generation)
            }
        }
    }

    private func installRendererCallbacks(generation: UUID) {
        renderer.onError = { [weak self] rendererError in
            self?.fail(.video(rendererError), generation: generation)
        }

        renderer.onKeyFrameNeeded = { [weak self] in
            guard let self,
                  self.activeGeneration == generation,
                  self.state == .connected else { return }
            self.client.requestKeyFrame()
        }
        renderer.onStateChanged = { [weak self] rendererState in
            guard let self, self.activeGeneration == generation else { return }
            // Enqueueing is not proof of visible video. The layer's readiness
            // observation below owns initial presentation success.
            if case .failed = rendererState {
                self.cancelVideoReadinessTimeout()
            } else if rendererState == .waitingForConfiguration || rendererState == .waitingForKeyFrame {
                self.resumeVideoReadinessTimeoutIfNeeded(generation: generation)
            }
        }
        renderer.onPresentationReady = { [weak self] in
            guard let self, self.activeGeneration == generation else { return }
            self.cancelVideoReadinessTimeout()
        }
        renderer.onPresentationLost = { [weak self] in
            self?.resumeVideoReadinessTimeoutIfNeeded(generation: generation)
        }
        renderer.onVideoDimensionsChanged = { [weak self] dimensions in
            guard let self, self.activeGeneration == generation else { return }
            self.videoDimensions = dimensions
            self.onVideoDimensionsChanged?(dimensions)
        }
    }

    private func fail(_ sessionError: GlassyStreamSessionError, generation: UUID) {
        guard activeGeneration == generation else { return }

        activeGeneration = nil
        let waiter = takeAuthenticationWaiter(generation: generation)
        cancelVideoReadinessTimeout()
        renderer.onError = nil
        renderer.onKeyFrameNeeded = nil
        renderer.onStateChanged = nil
        renderer.onVideoDimensionsChanged = nil
        renderer.onPresentationReady = nil
        renderer.onPresentationLost = nil
        client.disconnect()
        renderer.reset()
        authentication = nil
        hostStatus = nil
        videoDimensions = nil
        error = sessionError
        state = .failed
        waiter?.resume(throwing: sessionError)
    }

    private func cancel(generation: UUID) {
        guard activeGeneration == generation else { return }
        disconnectCurrentSession(clearError: true)
    }

    private func disconnectCurrentSession(clearError: Bool) {
        let generation = activeGeneration
        activeGeneration = nil
        cancelVideoReadinessTimeout()

        let waiter: CheckedContinuation<GlassyStreamAuthentication, Error>?
        if let generation {
            waiter = takeAuthenticationWaiter(generation: generation)
        } else {
            waiter = nil
        }

        renderer.onError = nil
        renderer.onKeyFrameNeeded = nil
        renderer.onStateChanged = nil
        renderer.onVideoDimensionsChanged = nil
        renderer.onPresentationReady = nil
        renderer.onPresentationLost = nil
        client.disconnect()
        renderer.reset()
        authentication = nil
        hostStatus = nil
        videoDimensions = nil
        state = .idle
        if clearError {
            error = nil
        }
        waiter?.resume(throwing: GlassyStreamSessionError.cancelled)
    }

    func sendPointerInput(
        x: UInt16,
        y: UInt16,
        buttons: GlassyStreamPointerButtons
    ) {
        guard canSendInput else { return }
        client.sendPointerInput(x: x, y: y, buttons: buttons)
    }

    func sendScrollInput(
        direction: GlassyStreamScrollDirection,
        steps: UInt16
    ) {
        guard canSendInput else { return }
        client.sendScrollInput(direction: direction, steps: steps)
    }

    func sendKeyInput(keysym: UInt32, isDown: Bool) {
        guard canSendInput else { return }
        client.sendKeyInput(keysym: keysym, isDown: isDown)
    }

    func sendTextInput(
        _ text: String,
        modifiers: GlassyStreamTextModifiers = []
    ) {
        guard canSendInput else { return }
        client.sendTextInput(text, modifiers: modifiers)
    }

    func pasteClipboardText(_ text: String) {
        guard canSendInput,
              authentication?.supportsClipboardPaste == true else { return }
        client.pasteClipboardText(text)
    }

    private var canSendInput: Bool {
        guard state == .connected else { return false }
        guard let hostStatus else { return true } // Older hosts have no status extension.
        return hostStatus.state == .streaming && hostStatus.accessibilityGranted && hostStatus.ownsInput
    }

    private func resumeVideoReadinessTimeoutIfNeeded(generation: UUID) {
        guard activeGeneration == generation, state == .connected,
              videoReadinessTask == nil, !renderer.isDisplayingVideo else { return }
        if let hostStatus, hostStatus.state != .starting && hostStatus.state != .streaming { return }
        scheduleVideoReadinessTimeout(generation: generation)
    }

    private func scheduleVideoReadinessTimeout(generation: UUID) {
        cancelVideoReadinessTimeout()
        guard !renderer.isDisplayingVideo else { return }
        if let hostStatus, hostStatus.state != .starting && hostStatus.state != .streaming { return }
        guard videoReadinessTimeout.isFinite, videoReadinessTimeout > 0 else {
            fail(.videoReadinessTimedOut, generation: generation)
            return
        }

        videoReadinessTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.videoReadinessTimeout ?? 0))
            guard !Task.isCancelled,
                  let self,
                  self.activeGeneration == generation,
                  self.state == .connected else { return }
            self.videoReadinessTask = nil
            guard self.renderer.isDisplayingVideo else {
                self.fail(.videoReadinessTimedOut, generation: generation)
                return
            }
        }
    }

    private func cancelVideoReadinessTimeout() {
        videoReadinessTask?.cancel()
        videoReadinessTask = nil
    }

    private func takeAuthenticationWaiter(
        generation: UUID
    ) -> CheckedContinuation<GlassyStreamAuthentication, Error>? {
        guard authenticationWaiter?.generation == generation else { return nil }
        let continuation = authenticationWaiter?.continuation
        authenticationWaiter = nil
        return continuation
    }
}

private struct AuthenticationWaiter {
    let generation: UUID
    let continuation: CheckedContinuation<GlassyStreamAuthentication, Error>
}
