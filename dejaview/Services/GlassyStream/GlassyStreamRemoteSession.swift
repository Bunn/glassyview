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
    @Published private(set) var preferredFrameRate: RemoteFrameRate = .responsive
    @Published private(set) var touchMode: RemoteTouchMode = .direct
    @Published private(set) var displays: [RemoteDisplay] = []
    @Published private(set) var displaySelection: RemoteDisplaySelection = .all

    let controller: GlassyStreamSessionController

    private let framebufferUpdateSubject = CurrentValueSubject<RemoteFramebufferUpdate, Never>(.empty)
    private let cursorSubject = CurrentValueSubject<RemoteCursor?, Never>(nil)
    private var framebufferSize: CGSize = .zero
    private(set) var cursorLocation: CGPoint = .zero
    private var pointerButtons: GlassyStreamPointerButtons = []
    private var heldModifierKeys: Set<RemoteModifierKey> = []
    private var retryConfiguration: ConnectionConfiguration?
    private var retryTask: Task<Void, Never>?
    private var retryGeneration = UUID()
    private var disconnectRequested = false
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
    }

    /// Opens a discovered Glassy Host and returns its authenticated identity.
    /// After first pairing, pass that identity back on every resume attempt so
    /// a saved machine can never silently connect to another nearby Mac.
    @discardableResult
    func connect(
        endpoint: NWEndpoint,
        savedMachineID: UUID,
        pairingCode: String?,
        expectedHostIdentifier: Data? = nil
    ) async throws -> GlassyStreamAuthentication {
        cancelRetryTask()
        let configuration = ConnectionConfiguration(
            endpoint: endpoint,
            savedMachineID: savedMachineID,
            pairingCode: pairingCode,
            expectedHostIdentifier: expectedHostIdentifier
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
            expectedHostIdentifier: nil
        )
        retryConfiguration = configuration
        startRetryTask(using: configuration)
    }

    func disconnect() {
        disconnectRequested = true
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
        cancelRetryTask()
        releaseActiveInputState()
        controller.disconnect()
        retryConfiguration = nil
        clearGeometry()
        status = .idle
        disconnectRequested = false
    }

    func retryConnect() {
        guard case .disconnected = status,
              let retryConfiguration else { return }

        startRetryTask(using: retryConfiguration)
    }

    func cancelReconnect() {
        cancelRetryTask()
        disconnectRequested = true
        releaseActiveInputState()
        controller.disconnect()
        clearGeometry()
        status = .disconnected(nil)
    }

    func updateNetworkPathStatus(_ status: NetworkPathStatus) {
        // NWConnection reports path transitions and terminal failures to the
        // controller. Manual Retry remains available in SessionView.
    }

    func applyPreferences(_ preferences: SessionPreferences) {
        let preferences = preferences.normalized
        touchMode = preferences.touchMode
        setPreferredFrameRate(preferences.frameRate)
        displaySelection = .all
    }

    func setQuality(_ newQuality: RemoteSessionQuality) {
        quality = newQuality
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
        releaseActiveInputState()
        controller.disconnect()
        status = .disconnected("The Glassy Stream connection was interrupted for testing.")
    }
#endif

    // MARK: - Connection state

    private func connect(
        using configuration: ConnectionConfiguration
    ) async throws -> GlassyStreamAuthentication {
        disconnectRequested = false
        releaseActiveInputState()
        clearGeometry()
        status = .connecting

        do {
            let authentication = try await controller.connect(
                endpoint: configuration.endpoint,
                savedMachineID: configuration.savedMachineID,
                pairingCode: configuration.pairingCode,
                expectedHostIdentifier: configuration.expectedHostIdentifier
            )
            retryConfiguration = ConnectionConfiguration(
                endpoint: configuration.endpoint,
                savedMachineID: configuration.savedMachineID,
                pairingCode: nil,
                expectedHostIdentifier: authentication.hostIdentifier
            )
            status = .connected
            return authentication
        } catch {
            if !disconnectRequested {
                status = .disconnected(error.localizedDescription)
            }
            throw error
        }
    }

    private func startRetryTask(using configuration: ConnectionConfiguration) {
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

    private func cancelRetryTask() {
        retryGeneration = UUID()
        retryTask?.cancel()
        retryTask = nil
    }

    private func controllerStateChanged(
        _ state: GlassyStreamSessionState,
        error: GlassyStreamSessionError?
    ) {
        switch state {
        case .idle:
            if disconnectRequested, status != .idle {
                status = .disconnected(nil)
            }
        case .connecting:
            status = .connecting
        case .connected:
            status = .connected
        case .failed:
            releaseLocalInputState()
            clearGeometry()
            status = .disconnected(
                error?.localizedDescription ?? "The Glassy Stream connection ended."
            )
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
        if previousSize == .zero {
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
}
