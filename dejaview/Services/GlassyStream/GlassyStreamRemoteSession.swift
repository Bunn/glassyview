import Combine
import CoreGraphics
import Foundation
import Network
import OSLog
import RoyalVNCKit

/// A complete Glassy Stream remote session: H.264 video plus authenticated
/// keyboard, pointer, and scroll input. It intentionally has no VNC dependency
/// beyond the shared `VNCKeyCode` value type required by the app's input API.
@MainActor
final class GlassyStreamRemoteSession: ObservableObject, @MainActor RemoteSessionControlling {
    @Published private(set) var status: RemoteSessionStatus = .idle
    @Published private(set) var quality: RemoteSessionQuality = .best
    @Published private(set) var supportedQualities: [RemoteSessionQuality] = [.best]
    @Published private(set) var preferredFrameRate: RemoteFrameRate = .responsive
    @Published private(set) var touchMode: RemoteTouchMode = .direct
    @Published private(set) var displays: [RemoteDisplay] = []
    @Published private(set) var displaySelection: RemoteDisplaySelection = .all

    let controller: GlassyStreamSessionController

    private let framebufferUpdateSubject = CurrentValueSubject<RemoteFramebufferUpdate, Never>(.empty)
    private let cursorSubject = CurrentValueSubject<RemoteCursor?, Never>(nil)
    private let cursorLocationSubject = CurrentValueSubject<CGPoint, Never>(.zero)
    private var framebufferSize: CGSize = .zero
    private(set) var cursorLocation: CGPoint = .zero {
        didSet {
            cursorLocationSubject.send(cursorLocation)
        }
    }
    private var remoteCursorPosition: GlassyStreamCursorPosition?
    private var pointerButtons: GlassyStreamPointerButtons = []
    private var heldModifierKeys: Set<RemoteModifierKey> = []
    private var retryConfiguration: ConnectionConfiguration?
    private var retryTask: Task<Void, Never>?
    private var retryGeneration = UUID()
    private var automaticReconnectConnectionGeneration: UUID?
    private let automaticReconnectPolicy = AutomaticReconnectPolicy()
    private var automaticReconnectAttempt = 0
    private var hasConnectedAtLeastOnce = false
    private var disconnectRequested = false
    private var isSuspendedForBackground = false
    private var networkPathStatus: NetworkPathStatus?
    private var lastDisconnectMessage: String?
    private let fallbackSavedMachineID = UUID()

    var framebufferUpdatePublisher: AnyPublisher<RemoteFramebufferUpdate, Never> {
        framebufferUpdateSubject.eraseToAnyPublisher()
    }

    var cursor: RemoteCursor? {
        cursorSubject.value
    }

    var cursorPublisher: AnyPublisher<RemoteCursor?, Never> {
        cursorSubject.eraseToAnyPublisher()
    }

    var cursorLocationPublisher: AnyPublisher<CGPoint, Never> {
        cursorLocationSubject.eraseToAnyPublisher()
    }

    var displayOptions: [RemoteDisplayOption] {
        []
    }

    var selectedDisplayFrame: CGRect? {
        nil
    }

    init(controller: GlassyStreamSessionController = GlassyStreamSessionController()) {
        self.controller = controller

        controller.onStateChanged = { [weak self] state, error in
            self?.controllerStateChanged(state, error: error)
        }
        controller.onVideoDimensionsChanged = { [weak self] dimensions in
            self?.updateVideoDimensions(dimensions)
        }
        controller.onCursorPositionChanged = { [weak self] position in
            self?.updateRemoteCursorPosition(position)
        }
    }

    /// Opens a discovered Glassy Host and returns its authenticated identity.
    /// After first pairing, pass that identity back on every resume attempt so
    /// a saved machine can never silently connect to another nearby Mac.
    @discardableResult
    func connect(
        endpoint: NWEndpoint,
        savedMachineID: UUID,
        pairingCode: String?,
        expectedHostIdentifier: Data? = nil,
        desiredQuality: RemoteSessionQuality = .best
    ) async throws -> GlassyStreamAuthentication {
        cancelRetryTask()
        automaticReconnectAttempt = 0
        hasConnectedAtLeastOnce = false
        disconnectRequested = false
        isSuspendedForBackground = false
        lastDisconnectMessage = nil
        quality = desiredQuality
        let configuration = ConnectionConfiguration(
            endpoint: endpoint,
            savedMachineID: savedMachineID,
            pairingCode: pairingCode,
            expectedHostIdentifier: expectedHostIdentifier,
            desiredQuality: desiredQuality
        )
        retryConfiguration = configuration
        return try await connect(using: configuration)
    }

    /// Direct-host compatibility for `RemoteSessionControlling`. Glassy Stream
    /// callers normally use the Bonjour-endpoint overload above so the saved
    /// machine UUID and expected host identity are available.
    func connect(host: String, port: UInt16, username: String, password: String) {
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            status = .disconnected("The Glassy Stream port is invalid.")
            return
        }

        let configuration = ConnectionConfiguration(
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: networkPort),
            savedMachineID: fallbackSavedMachineID,
            pairingCode: nil,
            expectedHostIdentifier: nil,
            desiredQuality: quality
        )
        cancelRetryTask()
        automaticReconnectAttempt = 0
        hasConnectedAtLeastOnce = false
        disconnectRequested = false
        isSuspendedForBackground = false
        lastDisconnectMessage = nil
        retryConfiguration = configuration
        startOneShotConnectionTask(using: configuration)
    }

    func disconnect() {
        disconnectRequested = true
        isSuspendedForBackground = false
        cancelRetryTask()
        releaseActiveInputState()
        controller.disconnect()
        clearGeometry()

        if status != .idle {
            status = .disconnected(nil)
        }
    }

    func reset() {
        disconnectRequested = true
        isSuspendedForBackground = false
        cancelRetryTask()
        releaseActiveInputState()
        controller.disconnect()
        retryConfiguration = nil
        automaticReconnectAttempt = 0
        hasConnectedAtLeastOnce = false
        networkPathStatus = nil
        lastDisconnectMessage = nil
        clearGeometry()
        supportedQualities = [.best]
        status = .idle
        disconnectRequested = false
    }

    /// iOS suspends ordinary TCP work shortly after the app backgrounds. Retire
    /// the current transport deliberately, but preserve the authenticated resume
    /// configuration and the presented session so foregrounding can recover in
    /// place instead of forcing the user back through discovery.
    @discardableResult
    func suspendForBackground() -> Bool {
        guard retryConfiguration != nil else { return false }

        switch status {
        case .connected, .connecting, .reconnecting:
            break
        case .idle, .disconnected:
            return false
        }

        AppLog.session.info("Suspending Glassy Stream for app backgrounding")
        isSuspendedForBackground = true
        disconnectRequested = false
        cancelRetryTask()
        releaseActiveInputState()
        controller.disconnect()
        clearGeometry()

        let attempt = max(1, automaticReconnectAttempt + 1)
        status = .reconnecting(
            RemoteReconnectState(
                attempt: min(attempt, automaticReconnectPolicy.maximumAttempts),
                maximumAttempts: automaticReconnectPolicy.maximumAttempts,
                phase: .waitingForForeground
            )
        )
        return true
    }

    /// Resumes a session that was deliberately retired before suspension. The
    /// first foreground attempt is immediate; later transient failures use the
    /// normal bounded backoff policy.
    @discardableResult
    func resumeAfterBackground() -> Bool {
        guard isSuspendedForBackground,
              retryConfiguration != nil else { return false }

        AppLog.session.info("Resuming Glassy Stream after app foregrounding")
        isSuspendedForBackground = false
        disconnectRequested = false
        launchAutomaticReconnect(startingAttempt: 1, firstAttemptIsImmediate: true)
        return true
    }

    func retryConnect() {
        guard retryConfiguration != nil else { return }

        switch status {
        case .disconnected:
            automaticReconnectAttempt = 0
            disconnectRequested = false
            isSuspendedForBackground = false
            launchAutomaticReconnect(startingAttempt: 1, firstAttemptIsImmediate: true)

        case .reconnecting(let reconnectState) where reconnectState.canRetryImmediately:
            disconnectRequested = false
            isSuspendedForBackground = false
            launchAutomaticReconnect(
                startingAttempt: reconnectState.attempt,
                firstAttemptIsImmediate: true
            )

        default:
            AppLog.session.warning(
                "Glassy Stream retry ignored while status was \(self.status.logDescription, privacy: .public)"
            )
        }
    }

    func cancelReconnect() {
        cancelRetryTask()
        disconnectRequested = true
        isSuspendedForBackground = false
        releaseActiveInputState()
        controller.disconnect()
        clearGeometry()
        status = .disconnected(lastDisconnectMessage)
    }

    func updateNetworkPathStatus(_ status: NetworkPathStatus) {
        networkPathStatus = status

        guard case .reconnecting(let reconnectState) = self.status,
              !isSuspendedForBackground else { return }

        switch status {
        case .satisfied:
            break
        case .unsatisfied, .requiresConnection:
            self.status = .reconnecting(
                RemoteReconnectState(
                    attempt: reconnectState.attempt,
                    maximumAttempts: reconnectState.maximumAttempts,
                    phase: .waitingForNetwork
                )
            )
        }
    }

    func applyPreferences(_ preferences: SessionPreferences) {
        let preferences = preferences.normalized
        touchMode = preferences.touchMode
        setPreferredFrameRate(preferences.frameRate)
        if status == .connected {
            setQuality(preferences.quality)
        } else {
            quality = preferences.quality
            retryConfiguration?.desiredQuality = preferences.quality
        }
        displaySelection = .all
    }

    func setQuality(_ newQuality: RemoteSessionQuality) {
        guard supportedQualities.contains(newQuality) else { return }
        guard newQuality != quality else { return }

        quality = newQuality
        retryConfiguration?.desiredQuality = newQuality
        controller.setStreamQuality(newQuality)
    }

    func setPreferredFrameRate(_ frameRate: RemoteFrameRate) {
        preferredFrameRate = frameRate
    }

    func setDisplaySelection(_ selection: RemoteDisplaySelection) {
        displaySelection = .all
    }

    func toggleTouchMode() {
        touchMode = touchMode == .direct ? .trackpad : .direct
    }

    // MARK: - Pointer input

    func leftButtonDown(at point: CGPoint) {
        guard canSendPointerInput else { return }
        cursorLocation = clampedPoint(point)
        pointerButtons.insert(.left)
        sendCurrentPointer()
    }

    func leftButtonUp(at point: CGPoint) {
        guard canSendPointerInput else {
            pointerButtons.remove(.left)
            return
        }
        cursorLocation = clampedPoint(point)
        pointerButtons.remove(.left)
        sendCurrentPointer()
    }

    func moveCursor(by delta: CGPoint, dragging: Bool) {
        moveCursor(
            to: CGPoint(x: cursorLocation.x + delta.x,
                        y: cursorLocation.y + delta.y),
            dragging: dragging
        )
    }

    func moveCursor(to point: CGPoint, dragging: Bool) {
        guard canSendPointerInput else { return }
        cursorLocation = clampedPoint(point)
        if dragging {
            pointerButtons.insert(.left)
        }
        sendCurrentPointer()
    }

    func clickAtCursor() {
        leftButtonDown(at: cursorLocation)
        leftButtonUp(at: cursorLocation)
    }

    func rightClick(at point: CGPoint) {
        guard canSendPointerInput else { return }
        cursorLocation = clampedPoint(point)
        let originalButtons = pointerButtons
        pointerButtons.insert(.right)
        sendCurrentPointer()
        pointerButtons = originalButtons
        sendCurrentPointer()
    }

    func rightClickAtCursor() {
        rightClick(at: cursorLocation)
    }

    func scroll(_ direction: RemoteScrollDirection, steps: UInt32) {
        guard canSendInput, steps > 0 else { return }

        let glassyDirection: GlassyStreamScrollDirection = switch direction {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }

        var remainingSteps = steps
        while remainingSteps > 0 {
            let batch = UInt16(min(remainingSteps, 64))
            controller.sendScrollInput(direction: glassyDirection, steps: batch)
            remainingSteps -= UInt32(batch)
        }
    }

    func pressAtCursor() {
        leftButtonDown(at: cursorLocation)
    }

    func releaseAtCursor() {
        leftButtonUp(at: cursorLocation)
    }

    // MARK: - Keyboard input

    func setModifier(_ modifier: RemoteModifierKey, isPressed: Bool) {
        let isHeld = heldModifierKeys.contains(modifier)
        guard canSendInput, isHeld != isPressed else { return }

        if isPressed {
            heldModifierKeys.insert(modifier)
        } else {
            heldModifierKeys.remove(modifier)
        }
        controller.sendKeyInput(
            keysym: keysym(for: modifier.keyCode),
            isDown: isPressed
        )
    }

    func releaseHeldModifiers() {
        guard !heldModifierKeys.isEmpty else { return }

        if canSendInput {
            for modifier in RemoteModifierKey.allCases.reversed()
            where heldModifierKeys.contains(modifier) {
                controller.sendKeyInput(
                    keysym: keysym(for: modifier.keyCode),
                    isDown: false
                )
            }
        }
        heldModifierKeys.removeAll()
    }

    func sendText(_ text: String, modifiers: [VNCKeyCode]) {
        guard canSendInput, !text.isEmpty else { return }
        let modifierMask = textModifierMask(for: modifiers)
            .union(textModifierMask(for: heldModifierKeys.map(\.keyCode)))

        for chunk in utf8Chunks(text, maximumByteCount: 4_096) {
            controller.sendTextInput(chunk, modifiers: modifierMask)
        }
    }

    func sendKey(_ keyCode: VNCKeyCode, modifiers: [VNCKeyCode]) {
        guard canSendInput else { return }

        let heldKeysyms = Set(heldModifierKeys.map { keysym(for: $0.keyCode) })
        let transientModifiers = modifiers.filter {
            !heldKeysyms.contains(keysym(for: $0))
        }

        transientModifiers.forEach {
            controller.sendKeyInput(keysym: keysym(for: $0), isDown: true)
        }
        controller.sendKeyInput(keysym: keysym(for: keyCode), isDown: true)
        controller.sendKeyInput(keysym: keysym(for: keyCode), isDown: false)
        transientModifiers.reversed().forEach {
            controller.sendKeyInput(keysym: keysym(for: $0), isDown: false)
        }
    }

    func sendReturn() {
        sendKey(.return, modifiers: [])
    }

#if DEBUG
    func debugSimulateConnectionInterruption() {
        guard status == .connected else { return }
        AppLog.session.warning("DEBUG simulating unexpected Glassy Stream interruption")
        controller.debugSimulateConnectionInterruption()
    }
#endif

    // MARK: - Connection state

    private func connect(
        using configuration: ConnectionConfiguration,
        preservingReconnectStatus: Bool = false
    ) async throws -> GlassyStreamAuthentication {
        disconnectRequested = false
        isSuspendedForBackground = false
        releaseActiveInputState()
        clearGeometry()
        supportedQualities = [.best]
        quality = configuration.desiredQuality
        if !preservingReconnectStatus {
            status = .connecting
        }

        do {
            let authentication = try await controller.connect(
                endpoint: configuration.endpoint,
                savedMachineID: configuration.savedMachineID,
                pairingCode: configuration.pairingCode,
                expectedHostIdentifier: configuration.expectedHostIdentifier,
                desiredQuality: configuration.desiredQuality
            )
            try Task.checkCancellation()
            guard !disconnectRequested,
                  !isSuspendedForBackground,
                  controller.state == .connected else {
                throw GlassyStreamSessionError.cancelled
            }
            supportedQualities = authentication.supportsStreamQuality
                ? RemoteSessionQuality.allCases
                : [.best]
            // Keep the user's requested preset even when an older host cannot
            // negotiate it. The options menu is capability-gated, and retaining
            // this value prevents a legacy connection from overwriting the saved
            // per-machine preference.
            quality = configuration.desiredQuality
            retryConfiguration = ConnectionConfiguration(
                endpoint: configuration.endpoint,
                savedMachineID: configuration.savedMachineID,
                pairingCode: nil,
                expectedHostIdentifier: authentication.hostIdentifier,
                desiredQuality: configuration.desiredQuality
            )
            automaticReconnectAttempt = 0
            hasConnectedAtLeastOnce = true
            lastDisconnectMessage = nil
            status = .connected
            return authentication
        } catch {
            if !disconnectRequested,
               !isSuspendedForBackground,
               retryTask == nil {
                status = .disconnected(error.localizedDescription)
            }
            throw error
        }
    }

    private func startOneShotConnectionTask(using configuration: ConnectionConfiguration) {
        cancelRetryTask()
        disconnectRequested = false
        let generation = UUID()
        retryGeneration = generation
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.retryGeneration == generation {
                    self.retryTask = nil
                }
            }
            do {
                _ = try await self.connect(using: configuration)
            } catch {
                // `connect(using:)` publishes the actionable failure.
            }
        }
    }

    private func launchAutomaticReconnect(
        startingAttempt: Int,
        firstAttemptIsImmediate: Bool = false
    ) {
        guard retryConfiguration != nil,
              !disconnectRequested,
              !isSuspendedForBackground else { return }

        cancelRetryTask()
        let generation = UUID()
        retryGeneration = generation
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.retryGeneration == generation {
                    self.retryTask = nil
                }
            }

            var attempt = max(1, startingAttempt)
            var shouldConnectImmediately = firstAttemptIsImmediate

            while !Task.isCancelled,
                  self.retryGeneration == generation,
                  !self.disconnectRequested,
                  !self.isSuspendedForBackground {
                guard let policyDelay = self.automaticReconnectPolicy.delay(
                    beforeAttempt: attempt
                ) else {
                    self.automaticReconnectAttempt = 0
                    self.status = .disconnected(
                        "Glassy Desk couldn't reconnect after \(self.automaticReconnectPolicy.maximumAttempts) attempts."
                    )
                    return
                }

                self.automaticReconnectAttempt = attempt

                var waitedForNetwork = false
                while !self.isNetworkAvailable {
                    waitedForNetwork = true
                    self.status = .reconnecting(
                        RemoteReconnectState(
                            attempt: attempt,
                            maximumAttempts: self.automaticReconnectPolicy.maximumAttempts,
                            phase: .waitingForNetwork
                        )
                    )
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled,
                          self.retryGeneration == generation,
                          !self.disconnectRequested,
                          !self.isSuspendedForBackground else { return }
                }
                if waitedForNetwork {
                    shouldConnectImmediately = true
                }

                let delay = shouldConnectImmediately ? 0 : policyDelay
                shouldConnectImmediately = false
                if delay > 0 {
                    let retryDate = Date.now.addingTimeInterval(delay)
                    self.status = .reconnecting(
                        RemoteReconnectState(
                            attempt: attempt,
                            maximumAttempts: self.automaticReconnectPolicy.maximumAttempts,
                            phase: .waiting(until: retryDate)
                        )
                    )
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }
                }

                guard !Task.isCancelled,
                      self.retryGeneration == generation,
                      !self.disconnectRequested,
                      !self.isSuspendedForBackground else { return }

                guard self.isNetworkAvailable else {
                    // The path changed during the backoff. Preserve this
                    // attempt and connect immediately once it is usable again
                    // instead of applying the same delay a second time.
                    shouldConnectImmediately = true
                    continue
                }
                guard let configuration = self.retryConfiguration else { return }

                self.status = .reconnecting(
                    RemoteReconnectState(
                        attempt: attempt,
                        maximumAttempts: self.automaticReconnectPolicy.maximumAttempts,
                        phase: .connecting
                    )
                )
                AppLog.session.info(
                    "Attempting Glassy Stream automatic reconnect; attempt=\(attempt, privacy: .public)"
                )

                let connectionGeneration = UUID()
                self.automaticReconnectConnectionGeneration = connectionGeneration
                do {
                    _ = try await self.connect(
                        using: configuration,
                        preservingReconnectStatus: true
                    )
                    if self.automaticReconnectConnectionGeneration == connectionGeneration {
                        self.automaticReconnectConnectionGeneration = nil
                    }
                    return
                } catch {
                    if self.automaticReconnectConnectionGeneration == connectionGeneration {
                        self.automaticReconnectConnectionGeneration = nil
                    }
                    guard !Task.isCancelled,
                          self.retryGeneration == generation,
                          !self.disconnectRequested,
                          !self.isSuspendedForBackground else { return }

                    guard Self.isRetryableConnectionFailure(error) else {
                        self.automaticReconnectAttempt = 0
                        self.status = .disconnected(error.localizedDescription)
                        return
                    }

                    self.lastDisconnectMessage = error.localizedDescription
                    attempt += 1
                }
            }
        }
    }

    private func cancelRetryTask() {
        retryGeneration = UUID()
        automaticReconnectConnectionGeneration = nil
        retryTask?.cancel()
        retryTask = nil
    }

    private func controllerStateChanged(
        _ state: GlassyStreamSessionState,
        error: GlassyStreamSessionError?
    ) {
        switch state {
        case .idle:
            if isSuspendedForBackground {
                let attempt = max(1, automaticReconnectAttempt + 1)
                status = .reconnecting(
                    RemoteReconnectState(
                        attempt: min(attempt, automaticReconnectPolicy.maximumAttempts),
                        maximumAttempts: automaticReconnectPolicy.maximumAttempts,
                        phase: .waitingForForeground
                    )
                )
            } else if disconnectRequested, status != .idle {
                status = .disconnected(lastDisconnectMessage)
            }
        case .connecting:
            if case .reconnecting = status {
                break
            }
            status = .connecting
        case .connected:
            hasConnectedAtLeastOnce = true
            status = .connected
        case .failed:
            releaseLocalInputState()
            clearGeometry()
            let message = error?.localizedDescription
                ?? "The Glassy Stream connection ended."
            lastDisconnectMessage = message

            if automaticReconnectConnectionGeneration != nil {
                // The retry loop owns the next state transition and will inspect
                // the thrown error to decide whether another attempt is safe.
                return
            }

            if hasConnectedAtLeastOnce,
               !disconnectRequested,
               !isSuspendedForBackground,
               Self.isRetryableConnectionFailure(error) {
                launchAutomaticReconnect(startingAttempt: 1)
            } else {
                automaticReconnectAttempt = 0
                status = .disconnected(message)
            }
        }
    }

    private var isNetworkAvailable: Bool {
        networkPathStatus == nil || networkPathStatus == .satisfied
    }

    private static func isRetryableConnectionFailure(_ error: Error?) -> Bool {
        guard let error else { return true }
        guard let sessionError = error as? GlassyStreamSessionError else {
            return false
        }

        switch sessionError {
        case .connectionEndedBeforeAuthentication, .videoReadinessTimedOut, .video:
            return true
        case .cancelled:
            return false
        case .transport(let clientError):
            switch clientError {
            case .alreadyConnecting,
                 .connectionFailed,
                 .connectionClosed,
                 .authenticationTimedOut:
                return true
            case .cancelled,
                 .pairingCodeRequired,
                 .invalidPairingCode,
                 .authenticationRejected,
                 .hostIdentityMismatch,
                 .directInputUnsupported,
                 .unsupportedHostVersion,
                 .protocolViolation,
                 .credentialStoreFailed:
                return false
            }
        }
    }

    // MARK: - Geometry and encoding

    private var canSendInput: Bool {
        status == .connected
            && controller.state == .connected
    }

    private var canSendPointerInput: Bool {
        canSendInput
            && framebufferSize.width > 0
            && framebufferSize.height > 0
    }

    private func updateVideoDimensions(_ dimensions: CGSize?) {
        guard let dimensions,
              dimensions.width.isFinite,
              dimensions.height.isFinite,
              dimensions.width > 0,
              dimensions.height > 0 else {
            clearGeometry()
            return
        }

        let previousSize = framebufferSize
        framebufferSize = dimensions
        if let remoteCursorPosition {
            cursorLocation = framebufferPoint(for: remoteCursorPosition)
        } else if previousSize == .zero {
            cursorLocation = CGPoint(x: dimensions.width / 2,
                                     y: dimensions.height / 2)
        } else {
            cursorLocation = clampedPoint(cursorLocation)
        }
        displays = [
            RemoteDisplay(
                id: 1,
                name: "Glassy Stream",
                frame: CGRect(origin: .zero, size: dimensions)
            )
        ]
        framebufferUpdateSubject.send(
            RemoteFramebufferUpdate(
                image: Self.geometryImage,
                imageSize: dimensions,
                dirtyRect: nil
            )
        )
    }

    private func clearGeometry() {
        framebufferSize = .zero
        cursorLocation = .zero
        remoteCursorPosition = nil
        displays = []
        cursorSubject.send(nil)
        framebufferUpdateSubject.send(.empty)
    }

    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        guard point.x.isFinite, point.y.isFinite,
              framebufferSize.width > 0,
              framebufferSize.height > 0 else { return cursorLocation }

        return CGPoint(
            x: min(max(point.x, 0), max(framebufferSize.width - 1, 0)),
            y: min(max(point.y, 0), max(framebufferSize.height - 1, 0))
        )
    }

    private func updateRemoteCursorPosition(_ position: GlassyStreamCursorPosition) {
        remoteCursorPosition = position
        guard framebufferSize.width > 0,
              framebufferSize.height > 0 else { return }
        cursorLocation = framebufferPoint(for: position)
    }

    private func framebufferPoint(
        for position: GlassyStreamCursorPosition
    ) -> CGPoint {
        CGPoint(
            x: framebufferCoordinate(position.x, length: framebufferSize.width),
            y: framebufferCoordinate(position.y, length: framebufferSize.height)
        )
    }

    private func framebufferCoordinate(_ value: UInt16, length: CGFloat) -> CGFloat {
        guard length > 1 else { return 0 }
        return CGFloat(value) / CGFloat(UInt16.max) * (length - 1)
    }

    private func sendCurrentPointer() {
        guard canSendPointerInput else { return }
        controller.sendPointerInput(
            x: normalizedCoordinate(cursorLocation.x, length: framebufferSize.width),
            y: normalizedCoordinate(cursorLocation.y, length: framebufferSize.height),
            buttons: pointerButtons
        )
    }

    private func normalizedCoordinate(_ value: CGFloat, length: CGFloat) -> UInt16 {
        guard length > 1 else { return 0 }
        let normalized = min(max(value / (length - 1), 0), 1)
        return UInt16(clamping: Int((normalized * CGFloat(UInt16.max)).rounded()))
    }

    private func releaseActiveInputState() {
        if canSendPointerInput, !pointerButtons.isEmpty {
            pointerButtons = []
            sendCurrentPointer()
        } else {
            pointerButtons = []
        }
        releaseHeldModifiers()
    }

    private func releaseLocalInputState() {
        pointerButtons = []
        heldModifierKeys.removeAll()
    }

    private func keysym(for keyCode: VNCKeyCode) -> UInt32 {
        UInt32(keyCode.rawValue)
    }

    private func textModifierMask(
        for keyCodes: [VNCKeyCode]
    ) -> GlassyStreamTextModifiers {
        var mask: GlassyStreamTextModifiers = []
        for keyCode in keyCodes {
            let value = keysym(for: keyCode)
            if value == keysym(for: RemoteModifierKey.command.keyCode) {
                mask.insert(.command)
            } else if value == keysym(for: RemoteModifierKey.shift.keyCode) {
                mask.insert(.shift)
            } else if value == keysym(for: RemoteModifierKey.option.keyCode) {
                mask.insert(.option)
            } else if value == keysym(for: RemoteModifierKey.control.keyCode) {
                mask.insert(.control)
            }
        }
        return mask
    }

    private func utf8Chunks(
        _ text: String,
        maximumByteCount: Int
    ) -> [String] {
        var chunks: [String] = []
        var scalars = String.UnicodeScalarView()
        var byteCount = 0

        for scalar in text.unicodeScalars {
            let scalarByteCount = String(scalar).utf8.count
            if byteCount + scalarByteCount > maximumByteCount, !scalars.isEmpty {
                chunks.append(String(scalars))
                scalars = String.UnicodeScalarView()
                byteCount = 0
            }
            scalars.append(scalar)
            byteCount += scalarByteCount
        }

        if !scalars.isEmpty {
            chunks.append(String(scalars))
        }
        return chunks
    }

    private static let geometryImage: CGImage = {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let data = Data(repeating: 0, count: 4) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }()
}

private struct ConnectionConfiguration: @unchecked Sendable {
    let endpoint: NWEndpoint
    let savedMachineID: UUID
    let pairingCode: String?
    let expectedHostIdentifier: Data?
    var desiredQuality: RemoteSessionQuality
}
