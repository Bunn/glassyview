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
            "The Glassy Stream connection was cancelled."
        case .connectionEndedBeforeAuthentication:
            "Glassy Host ended the connection before authentication completed."
        case .videoReadinessTimedOut:
            "The secure connection succeeded, but Glassy Host could not start video automatically. On the Mac, check Screen Recording access and the selected display, then reconnect."
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
            "Make sure Glassy Host is running, then try again."
        case .videoReadinessTimedOut:
            "Open Glassy Host, allow Screen Recording, check the selected display, and reconnect."
        case let .transport(error):
            switch error {
            case .pairingCodeRequired:
                "Enter the current twelve-symbol code shown by Glassy Host."
            case .invalidPairingCode, .authenticationRejected:
                "Check the code shown by Glassy Host and try pairing again."
            default:
                "Make sure the iPad and Mac are on the same network, then try again."
            }
        case .video:
            "Reconnect to request a fresh video configuration and keyframe."
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
    /// Pass `nil` for `pairingCode` to resume a previously paired saved machine.
    /// A new call replaces any in-flight or connected session owned by this
    /// controller.
    @discardableResult
    func connect(
        endpoint: NWEndpoint,
        savedMachineID: UUID,
        pairingCode: String?,
        expectedHostIdentifier: Data? = nil,
        desiredQuality: RemoteSessionQuality = .best
    ) async throws -> GlassyStreamAuthentication {
        disconnectCurrentSession(clearError: true)

        let generation = UUID()
        activeGeneration = generation
        authentication = nil
        videoDimensions = nil
        error = nil
        state = .connecting
        renderer.reset()
        installRendererCallbacks(generation: generation)

        let configuration = GlassyStreamConnectionConfiguration(
            endpoint: endpoint,
            savedMachineID: savedMachineID,
            pairingCode: pairingCode,
            expectedHostIdentifier: expectedHostIdentifier,
            desiredQuality: desiredQuality
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

                client.connect(
                    configuration: configuration,
                    callbackQueue: .main,
                    callbacks: GlassyStreamClientCallbacks(
                        onEvent: { [weak self] event in
                            MainActor.assumeIsolated {
                                self?.receive(event, generation: generation)
                            }
                        },
                        onCompletion: { [weak self] result in
                            MainActor.assumeIsolated {
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

        case let .videoConfiguration(configuration):
            guard state == .connected else { return }
            do {
                try renderer.configure(
                    parameterSets: configuration.parameterSets,
                    nalUnitHeaderLength: configuration.nalUnitHeaderLength
                )
            } catch let rendererError as GlassyStreamVideoRendererError {
                fail(.video(rendererError), generation: generation)
            } catch {
                fail(
                    .video(.decoder(error.localizedDescription)),
                    generation: generation
                )
            }

        case let .videoAccessUnit(accessUnit):
            guard state == .connected else { return }
            do {
                try renderer.enqueue(
                    avccData: accessUnit.data,
                    presentationTime: accessUnit.presentationTime,
                    duration: accessUnit.duration,
                    isKeyFrame: accessUnit.isKeyFrame
                )
            } catch let rendererError as GlassyStreamVideoRendererError {
                fail(.video(rendererError), generation: generation)
            } catch {
                fail(
                    .video(.decoder(error.localizedDescription)),
                    generation: generation
                )
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
            if case .rendering = rendererState {
                self.cancelVideoReadinessTimeout()
            }
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
        client.disconnect()
        renderer.reset()
        authentication = nil
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
        client.disconnect()
        renderer.reset()
        authentication = nil
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
        guard state == .connected else { return }
        client.sendPointerInput(x: x, y: y, buttons: buttons)
    }

    func sendScrollInput(
        direction: GlassyStreamScrollDirection,
        steps: UInt16
    ) {
        guard state == .connected else { return }
        client.sendScrollInput(direction: direction, steps: steps)
    }

    func sendKeyInput(keysym: UInt32, isDown: Bool) {
        guard state == .connected else { return }
        client.sendKeyInput(keysym: keysym, isDown: isDown)
    }

    func sendTextInput(
        _ text: String,
        modifiers: GlassyStreamTextModifiers = []
    ) {
        guard state == .connected else { return }
        client.sendTextInput(text, modifiers: modifiers)
    }

    private func scheduleVideoReadinessTimeout(generation: UUID) {
        cancelVideoReadinessTimeout()
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
            guard case .rendering = self.renderer.state else {
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
