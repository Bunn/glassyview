import Combine
import Foundation
import CoreGraphics
import OSLog
import RoyalVNCKit

/// Owns the `VNCConnection`, implements its delegate, and publishes
/// connection state + framebuffer images for SwiftUI to observe.
/// RoyalVNCKit delegate callbacks are bridged back to the main actor before
/// mutating session state.
final class VNCSession: NSObject, ObservableObject, RemoteSessionControlling, @unchecked Sendable {
    @Published var status: RemoteSessionStatus = .idle
    @Published private(set) var quality: RemoteSessionQuality = .best
    @Published private(set) var preferredFrameRate: RemoteFrameRate = .balanced
    @Published private(set) var touchMode: RemoteTouchMode = .direct
    @Published private(set) var displays: [RemoteDisplay] = []
    @Published private(set) var displaySelection: RemoteDisplaySelection = .all

    /// Current framebuffer updates, published outside `objectWillChange` so
    /// display-rate updates don't invalidate SwiftUI (see the protocol note).
    private let framebufferUpdateSubject = CurrentValueSubject<RemoteFramebufferUpdate, Never>(.empty)
    private let cursorSubject = CurrentValueSubject<RemoteCursor?, Never>(nil)
    private let cursorLocationSubject = CurrentValueSubject<CGPoint, Never>(.zero)
    private var currentFramebufferSize: CGSize = .zero
    private let framebufferThrottleLock = NSLock()
    private var pendingFramebuffer: VNCFramebuffer?
    private var pendingFramebufferImageSize: CGSize = .zero
    private var pendingFramebufferDirtyRect: CGRect?
    private var framebufferFlushTask: Task<Void, Never>?
    private var lastFramebufferPublishTime: TimeInterval = 0
    private var framebufferPublishInterval = RemoteFrameRate.balanced.updateInterval
    private static let renderingSignposter = OSSignposter(logger: AppLog.pointsOfInterest)

    var framebufferUpdatePublisher: AnyPublisher<RemoteFramebufferUpdate, Never> {
        framebufferUpdateSubject.eraseToAnyPublisher()
    }

    var cursor: RemoteCursor? {
        get { cursorSubject.value }
        set { cursorSubject.send(newValue) }
    }

    var cursorPublisher: AnyPublisher<RemoteCursor?, Never> {
        cursorSubject.eraseToAnyPublisher()
    }

    var cursorLocationPublisher: AnyPublisher<CGPoint, Never> {
        cursorLocationSubject.eraseToAnyPublisher()
    }

    var displayOptions: [RemoteDisplayOption] {
        Self.displayOptions(for: displays, framebufferFrame: framebufferFrameForDisplaySelection)
    }

    var selectedDisplayFrame: CGRect? {
        switch displaySelection {
        case .all:
            return nil
        case .display(let id):
            return displays.first { $0.id == id }?.frame
        case .region(let region):
            guard let framebufferFrame = framebufferFrameForDisplaySelection else { return nil }

            return region.frame(in: framebufferFrame)
        }
    }

    /// Last known remote cursor position (framebuffer coordinates).
    private(set) var cursorLocation: CGPoint = .zero {
        didSet {
            cursorLocationSubject.send(cursorLocation)
        }
    }

    private(set) var connection: VNCConnection?

    private var host = ""
    private var port: UInt16 = 5900
    private var username = ""
    private var password = ""
    private let automaticReconnectPolicy = AutomaticReconnectPolicy()
    private var automaticReconnectTask: Task<Void, Never>?
    private var settingsReconnectTask: Task<Void, Never>?
    private var automaticReconnectAttempt = 0
    private var settingsReconnectPending = false
    private var hasConnectedAtLeastOnce = false
    private var disconnectRequested = false
    private var networkPathStatus: NetworkPathStatus?
    private var lastDisconnectMessage: String?
    private var heldModifierKeys: Set<RemoteModifierKey> = []
    private static let combinedFramebufferAspectRatioThreshold: CGFloat = 2.4

    var supportedQualities: [RemoteSessionQuality] {
        [.best]
    }

    // MARK: - Lifecycle

    func connect(host: String, port: UInt16, username: String, password: String) {
        cancelReconnectTasks()
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        automaticReconnectAttempt = 0
        settingsReconnectPending = false
        hasConnectedAtLeastOnce = false
        disconnectRequested = false
        lastDisconnectMessage = nil

        startConnection()
    }

    private func startConnection(preservingStatus: Bool = false) {
        AppLog.session.info("Connecting to VNC host \(self.host, privacy: .public):\(self.port, privacy: .public); usernameProvided=\(!self.username.isEmpty, privacy: .public); quality=\(self.quality.rawValue, privacy: .public); frameRate=\(self.preferredFrameRate.rawValue, privacy: .public); automaticReconnectAttempt=\(self.automaticReconnectAttempt, privacy: .public)")

        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: host,
            port: port,
            isShared: true,
            isScalingEnabled: true,
            useDisplayLink: true,
            inputMode: .forwardKeyboardShortcutsEvenIfInUseLocally,
            // RoyalVNC polls UIPasteboard when enabled, prompting on cross-app
            // reads. Clipboard access belongs to native, user-initiated paste.
            isClipboardRedirectionEnabled: false,
            colorDepth: .depth24Bit,
            frameEncodings: .default
        )

        let connection = VNCConnection(settings: settings)
        connection.delegate = self
        self.connection = connection // Keep a strong reference

        if !preservingStatus {
            status = .connecting
        }

        connection.connect()
    }

    func disconnect() {
        AppLog.session.info("Disconnect requested")
        disconnectRequested = true
        settingsReconnectPending = false
        cancelReconnectTasks()
        releaseHeldModifiers()

        if let connection {
            connection.disconnect()
        } else {
            finishDisconnected(message: lastDisconnectMessage)
        }
    }

    /// Returns the session to a clean state after the session UI is dismissed.
    func reset() {
        AppLog.session.info("Resetting session state")
        disconnectRequested = true
        settingsReconnectPending = false
        automaticReconnectAttempt = 0
        hasConnectedAtLeastOnce = false
        lastDisconnectMessage = nil
        networkPathStatus = nil
        cancelReconnectTasks()
        releaseHeldModifiers()
        cancelPendingFramebufferUpdates()
        connection?.delegate = nil
        connection = nil
        clearFramebuffer()
        cursor = nil
        displays = []
        displaySelection = .all
        status = .idle
    }

    // MARK: - Live settings changes
    //
    // `VNCConnection.Settings` is immutable, so changing quality mid-session
    // briefly reconnects with the new settings.

    func applyPreferences(_ preferences: SessionPreferences) {
        let preferences = preferences.normalized

        touchMode = preferences.touchMode
        displaySelection = displays.isEmpty
            ? preferences.displaySelection
            : normalizedDisplaySelection(preferences.displaySelection)
        setPreferredFrameRate(preferences.frameRate)

        AppLog.session.info("Applied session preferences; touchMode=\(preferences.touchMode.rawValue, privacy: .public) display=\(self.displaySelection.logDescription, privacy: .public) frameRate=\(preferences.frameRate.rawValue, privacy: .public)")
    }

    func setQuality(_ newQuality: RemoteSessionQuality) {
        guard supportedQualities.contains(newQuality) else { return }
        guard newQuality != quality else { return }

        AppLog.session.info("Changing quality from \(self.quality.title, privacy: .public) to \(newQuality.title, privacy: .public)")
        quality = newQuality
        applySettingsChange()
    }

    func setPreferredFrameRate(_ frameRate: RemoteFrameRate) {
        guard frameRate != preferredFrameRate else { return }

        framebufferThrottleLock.lock()
        framebufferPublishInterval = frameRate.updateInterval
        framebufferThrottleLock.unlock()

        preferredFrameRate = frameRate
        AppLog.rendering.info("Remote frame rate preference changed; framesPerSecond=\(frameRate.rawValue, privacy: .public)")
    }

    func setDisplaySelection(_ selection: RemoteDisplaySelection) {
        let normalizedSelection = normalizedDisplaySelection(selection)
        guard normalizedSelection != displaySelection else { return }

        displaySelection = normalizedSelection
        clampCursorToSelectableBounds()

        AppLog.session.info("Display selection changed to \(self.displaySelection.logDescription, privacy: .public)")
    }

    private func applySettingsChange() {
        // Only reconnect for an established session; never stack reconnects.
        guard status == .connected, !settingsReconnectPending else {
            AppLog.session.debug("Skipped settings reconnect; status=\(String(describing: self.status), privacy: .public) reconnectPending=\(self.settingsReconnectPending, privacy: .public)")
            return
        }

        AppLog.session.info("Applying settings change by reconnecting session")
        releaseHeldModifiers()
        disconnectRequested = false
        settingsReconnectPending = true
        connection?.disconnect()
    }

    /// Retries the last connection (e.g. from the disconnected screen).
    func retryConnect() {
        guard !host.isEmpty else {
            AppLog.session.warning("Retry requested without a previous connection")
            return
        }

        switch status {
        case .disconnected:
            AppLog.session.info("Manually retrying connection to \(self.host, privacy: .public):\(self.port, privacy: .public)")
            cancelReconnectTasks()
            automaticReconnectAttempt = 0
            disconnectRequested = false
            startConnection()

        case .reconnecting(let reconnectState) where reconnectState.canRetryImmediately:
            AppLog.session.info("Retrying automatic reconnect immediately; attempt=\(reconnectState.attempt, privacy: .public)")
            cancelAutomaticReconnect()
            performAutomaticReconnectAttempt(reconnectState.attempt)

        default:
            AppLog.session.warning("Retry requested while connection state was \(self.status.logDescription, privacy: .public)")
        }
    }

    func cancelReconnect() {
        guard case .reconnecting = status else { return }

        AppLog.session.info("Automatic reconnect cancelled")
        disconnectRequested = true
        cancelAutomaticReconnect()
        releaseHeldModifiers()

        if let connection {
            connection.delegate = nil
            connection.disconnect()
            self.connection = nil
        }

        finishDisconnected(message: lastDisconnectMessage)
    }

    func updateNetworkPathStatus(_ pathStatus: NetworkPathStatus) {
        networkPathStatus = pathStatus

        guard case .reconnecting(let reconnectState) = status else { return }

        switch pathStatus {
        case .satisfied:
            guard reconnectState.phase == .waitingForNetwork else { return }

            AppLog.session.info("Network became available during reconnect; retrying now")
            performAutomaticReconnectAttempt(reconnectState.attempt)

        case .unsatisfied, .requiresConnection:
            guard case .waiting = reconnectState.phase else { return }

            AppLog.session.info("Network became unavailable during reconnect; pausing retry countdown")
            cancelAutomaticReconnect()
            status = .reconnecting(RemoteReconnectState(attempt: reconnectState.attempt,
                                                        maximumAttempts: reconnectState.maximumAttempts,
                                                        phase: .waitingForNetwork))
        }
    }

#if DEBUG
    func debugSimulateConnectionInterruption() {
        guard status == .connected, let connection else {
            AppLog.session.warning("DEBUG reconnect test ignored because no session is connected")
            return
        }

        AppLog.session.warning("DEBUG simulating unexpected VNC connection interruption")
        disconnectRequested = false
        settingsReconnectPending = false
        connection.disconnect()
    }
#endif

    private var isNetworkAvailable: Bool {
        networkPathStatus == nil || networkPathStatus == .satisfied
    }

    private func beginAutomaticReconnect(message: String?) {
        lastDisconnectMessage = message ?? String(localized: "The connection was interrupted.")

        let attempt = automaticReconnectAttempt + 1

        guard let delay = automaticReconnectPolicy.delay(beforeAttempt: attempt) else {
            let message = String(localized: "Glassy Desk couldn't reconnect after \(automaticReconnectPolicy.maximumAttempts) attempts.")
            AppLog.session.error("Automatic reconnect attempts exhausted")
            finishDisconnected(message: message)
            return
        }

        automaticReconnectAttempt = attempt

        guard isNetworkAvailable else {
            AppLog.session.info("Waiting for network before automatic reconnect attempt \(attempt, privacy: .public)")
            status = .reconnecting(RemoteReconnectState(attempt: attempt,
                                                        maximumAttempts: automaticReconnectPolicy.maximumAttempts,
                                                        phase: .waitingForNetwork))
            return
        }

        scheduleAutomaticReconnectAttempt(attempt, after: delay)
    }

    private func scheduleAutomaticReconnectAttempt(_ attempt: Int, after delay: TimeInterval) {
        cancelAutomaticReconnect()

        let retryDate = Date.now.addingTimeInterval(delay)
        status = .reconnecting(RemoteReconnectState(attempt: attempt,
                                                    maximumAttempts: automaticReconnectPolicy.maximumAttempts,
                                                    phase: .waiting(until: retryDate)))

        AppLog.session.info("Scheduling automatic reconnect; attempt=\(attempt, privacy: .public) delaySeconds=\(delay, privacy: .public)")

        automaticReconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }

            self?.automaticReconnectTask = nil
            self?.performAutomaticReconnectAttempt(attempt)
        }
    }

    private func performAutomaticReconnectAttempt(_ attempt: Int) {
        guard !disconnectRequested,
              automaticReconnectAttempt == attempt else {
            return
        }

        guard isNetworkAvailable else {
            status = .reconnecting(RemoteReconnectState(attempt: attempt,
                                                        maximumAttempts: automaticReconnectPolicy.maximumAttempts,
                                                        phase: .waitingForNetwork))
            return
        }

        automaticReconnectTask = nil
        status = .reconnecting(RemoteReconnectState(attempt: attempt,
                                                    maximumAttempts: automaticReconnectPolicy.maximumAttempts,
                                                    phase: .connecting))
        startConnection(preservingStatus: true)
    }

    private func scheduleSettingsReconnect() {
        settingsReconnectTask?.cancel()
        status = .connecting
        AppLog.session.info("Scheduling reconnect after settings change")

        settingsReconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            guard self.status == .connecting,
                  self.connection == nil,
                  !self.disconnectRequested else {
                return
            }

            self.settingsReconnectTask = nil
            self.startConnection()
        }
    }

    private func finishDisconnected(message: String?) {
        cancelReconnectTasks()
        cancelPendingFramebufferUpdates()
        connection?.delegate = nil
        connection = nil
        clearFramebuffer()
        cursor = nil
        automaticReconnectAttempt = 0
        status = .disconnected(message)
    }

    private func cancelAutomaticReconnect() {
        automaticReconnectTask?.cancel()
        automaticReconnectTask = nil
    }

    private func cancelReconnectTasks() {
        cancelAutomaticReconnect()
        settingsReconnectTask?.cancel()
        settingsReconnectTask = nil
    }

    private static func isRetryableConnectionFailure(_ error: Error?) -> Bool {
        guard let error else { return true }
        guard let vncError = error as? VNCError else { return false }

        switch vncError {
        case .connection(let connectionError):
            if case .cancelled = connectionError {
                return false
            } else {
                return true
            }
        case .authentication, .protocol:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Pointer input
    //
    // Drags are implemented by repeatedly sending mouseButtonDown at the
    // new coordinates (VNC pointer events carry position + button mask,
    // so "still down, new position" is exactly a drag), then mouseButtonUp.

    func leftButtonDown(at point: CGPoint) {
        cursorLocation = point
        connection?.mouseButtonDown(.left,
                                    x: UInt16(clamping: Int(point.x)),
                                    y: UInt16(clamping: Int(point.y)))
    }

    func leftButtonUp(at point: CGPoint) {
        cursorLocation = point
        connection?.mouseButtonUp(.left,
                                  x: UInt16(clamping: Int(point.x)),
                                  y: UInt16(clamping: Int(point.y)))
    }

    // MARK: - Trackpad-style (relative) pointer input

    func toggleTouchMode() {
        touchMode = touchMode == .direct ? .trackpad : .direct
        AppLog.input.info("Touch mode changed to \(String(describing: self.touchMode), privacy: .public)")
    }

    /// Moves the cursor by a delta (framebuffer coordinates), clamped to the
    /// framebuffer. If `dragging`, the left button stays held while moving.
    func moveCursor(by delta: CGPoint, dragging: Bool) {
        let point = CGPoint(x: cursorLocation.x + delta.x,
                            y: cursorLocation.y + delta.y)

        moveCursor(to: point, dragging: dragging)
    }

    func moveCursor(to point: CGPoint, dragging: Bool = false) {
        guard currentFramebufferSize.width > 0,
              currentFramebufferSize.height > 0 else { return }

        let clamped = clampedCursorPoint(point)

        cursorLocation = clamped

        let x = UInt16(clamping: Int(clamped.x))
        let y = UInt16(clamping: Int(clamped.y))

        if dragging {
            // Position + button mask still set = drag.
            connection?.mouseButtonDown(.left, x: x, y: y)
        } else {
            connection?.mouseMove(x: x, y: y)
        }
    }

    func clickAtCursor() {
        AppLog.input.debug("Left click at cursor x=\(self.cursorLocation.x, privacy: .public) y=\(self.cursorLocation.y, privacy: .public)")
        leftButtonDown(at: cursorLocation)
        leftButtonUp(at: cursorLocation)
    }

    // MARK: - Right click & scroll

    func rightClick(at point: CGPoint) {
        let clamped = clampedCursorPoint(point)

        AppLog.input.debug("Right click at x=\(clamped.x, privacy: .public) y=\(clamped.y, privacy: .public)")
        cursorLocation = clamped

        let x = UInt16(clamping: Int(clamped.x))
        let y = UInt16(clamping: Int(clamped.y))

        connection?.mouseButtonDown(.right, x: x, y: y)
        connection?.mouseButtonUp(.right, x: x, y: y)
    }

    func rightClickAtCursor() {
        rightClick(at: cursorLocation)
    }

    func scroll(_ direction: RemoteScrollDirection, steps: UInt32 = 1) {
        guard steps > 0 else { return }

        AppLog.input.debug("Scroll \(String(describing: direction), privacy: .public) steps=\(steps, privacy: .public) at x=\(self.cursorLocation.x, privacy: .public) y=\(self.cursorLocation.y, privacy: .public)")
        let x = UInt16(clamping: Int(cursorLocation.x))
        let y = UInt16(clamping: Int(cursorLocation.y))

        let wheel: VNCMouseWheel

        switch direction {
        case .up:
            wheel = .up
        case .down:
            wheel = .down
        case .left:
            wheel = .left
        case .right:
            wheel = .right
        }

        connection?.mouseWheel(wheel, x: x, y: y, steps: steps)
    }

    func pressAtCursor() {
        leftButtonDown(at: cursorLocation)
    }

    func releaseAtCursor() {
        leftButtonUp(at: cursorLocation)
    }

    // MARK: - Held keyboard modifiers

    func setModifier(_ modifier: RemoteModifierKey, isPressed: Bool) {
        let isCurrentlyPressed = heldModifierKeys.contains(modifier)
        guard isPressed != isCurrentlyPressed else { return }

        if isPressed {
            heldModifierKeys.insert(modifier)
            connection?.keyDown(modifier.keyCode)
        } else {
            heldModifierKeys.remove(modifier)
            connection?.keyUp(modifier.keyCode)
        }

        AppLog.input.debug("Remote modifier changed; modifier=\(modifier.rawValue, privacy: .public) pressed=\(isPressed, privacy: .public)")
    }

    func releaseHeldModifiers() {
        guard !heldModifierKeys.isEmpty else { return }

        for modifier in RemoteModifierKey.allCases.reversed() where heldModifierKeys.contains(modifier) {
            connection?.keyUp(modifier.keyCode)
        }

        heldModifierKeys.removeAll()
        AppLog.input.debug("Released held remote modifiers")
    }

    // MARK: - Keyboard input

    func sendText(_ text: String, modifiers: [VNCKeyCode] = []) {
        guard let connection else { return }

        AppLog.input.debug("Sending text to remote; characterCount=\(text.count, privacy: .public) modifiers=\(modifiers.count, privacy: .public)")
        let transientModifiers = transientModifiers(from: modifiers)
        transientModifiers.forEach { connection.keyDown($0) }

        for keyCode in VNCKeyCode.keyCodesFrom(characters: text) {
            connection.keyDown(keyCode)
            connection.keyUp(keyCode)
        }

        transientModifiers.reversed().forEach { connection.keyUp($0) }
    }

    func sendKey(_ keyCode: VNCKeyCode, modifiers: [VNCKeyCode] = []) {
        guard let connection else { return }

        AppLog.input.debug("Sending key to remote; key=\(String(describing: keyCode), privacy: .public) modifiers=\(modifiers.count, privacy: .public)")
        let transientModifiers = transientModifiers(from: modifiers)
        transientModifiers.forEach { connection.keyDown($0) }
        connection.keyDown(keyCode)
        connection.keyUp(keyCode)
        transientModifiers.reversed().forEach { connection.keyUp($0) }
    }

    func sendReturn() {
        sendKey(.return)
    }

    private func transientModifiers(from modifiers: [VNCKeyCode]) -> [VNCKeyCode] {
        let heldModifierRawValues = Set(heldModifierKeys.map(\.keyCode.rawValue))

        return modifiers.filter { !heldModifierRawValues.contains($0.rawValue) }
    }

    private func publishFramebuffer(_ image: CGImage?,
                                    imageSize: CGSize,
                                    dirtyRect: CGRect? = nil) {
        currentFramebufferSize = imageSize
        if image != nil {
            recordFramebufferPublishTime()
        }

        framebufferUpdateSubject.send(RemoteFramebufferUpdate(image: image,
                                                              imageSize: imageSize,
                                                              dirtyRect: dirtyRect))
    }

    private func clearFramebuffer() {
        publishFramebuffer(nil, imageSize: .zero)
    }

    private static func cgImage(from framebuffer: VNCFramebuffer) -> CGImage? {
        let signpostID = renderingSignposter.makeSignpostID()
        let state = renderingSignposter.beginInterval("VNC framebuffer CG image", id: signpostID)
        defer {
            renderingSignposter.endInterval("VNC framebuffer CG image", state)
        }

        return framebuffer.cgImage
    }

    private func enqueueFramebufferUpdate(framebuffer: VNCFramebuffer,
                                          imageSize: CGSize,
                                          dirtyRect: CGRect) {
        let taskDelay: TimeInterval?
        let shouldFlushImmediately: Bool

        framebufferThrottleLock.lock()

        pendingFramebuffer = framebuffer
        pendingFramebufferImageSize = imageSize

        if let pendingFramebufferDirtyRect {
            self.pendingFramebufferDirtyRect = pendingFramebufferDirtyRect.union(dirtyRect)
        } else {
            pendingFramebufferDirtyRect = dirtyRect
        }

        if framebufferFlushTask == nil {
            let elapsed = ProcessInfo.processInfo.systemUptime - lastFramebufferPublishTime
            if elapsed >= framebufferPublishInterval {
                taskDelay = nil
                shouldFlushImmediately = true
            } else {
                taskDelay = framebufferPublishInterval - elapsed
                shouldFlushImmediately = false
            }
        } else {
            taskDelay = nil
            shouldFlushImmediately = false
        }

        if let taskDelay {
            let delayMilliseconds = Int64(max(1, (taskDelay * 1000).rounded(.up)))
            framebufferFlushTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
                guard !Task.isCancelled else { return }

                self?.flushPendingFramebufferUpdate()
            }
        }

        framebufferThrottleLock.unlock()

        if shouldFlushImmediately {
            flushPendingFramebufferUpdate()
        }
    }

    private func flushPendingFramebufferUpdate() {
        let framebuffer: VNCFramebuffer?
        let imageSize: CGSize
        let dirtyRect: CGRect?

        framebufferThrottleLock.lock()

        framebufferFlushTask?.cancel()
        framebufferFlushTask = nil

        framebuffer = pendingFramebuffer
        imageSize = pendingFramebufferImageSize
        dirtyRect = pendingFramebufferDirtyRect

        pendingFramebuffer = nil
        pendingFramebufferImageSize = .zero
        pendingFramebufferDirtyRect = nil
        lastFramebufferPublishTime = ProcessInfo.processInfo.systemUptime

        framebufferThrottleLock.unlock()

        guard let framebuffer else { return }

        let cgImage = Self.cgImage(from: framebuffer)

        Task { @MainActor [weak self] in
            self?.publishFramebuffer(cgImage,
                                     imageSize: imageSize,
                                     dirtyRect: dirtyRect)
        }
    }

    private func cancelPendingFramebufferUpdates() {
        framebufferThrottleLock.lock()

        framebufferFlushTask?.cancel()
        framebufferFlushTask = nil
        pendingFramebuffer = nil
        pendingFramebufferImageSize = .zero
        pendingFramebufferDirtyRect = nil

        framebufferThrottleLock.unlock()
    }

    private func recordFramebufferPublishTime() {
        framebufferThrottleLock.lock()
        lastFramebufferPublishTime = ProcessInfo.processInfo.systemUptime
        framebufferThrottleLock.unlock()
    }

    // MARK: - Display selection

    private var framebufferFrameForDisplaySelection: CGRect? {
        if currentFramebufferSize.width > 0,
           currentFramebufferSize.height > 0 {
            return CGRect(x: 0,
                          y: 0,
                          width: currentFramebufferSize.width,
                          height: currentFramebufferSize.height)
        }

        if displays.count == 1 {
            return displays[0].frame
        }

        return nil
    }

    private func updateDisplays(_ newDisplays: [RemoteDisplay]) {
        let previousCount = displays.count
        let previousSelection = displaySelection
        displays = newDisplays
        displaySelection = normalizedDisplaySelection(displaySelection)
        clampCursorToSelectableBounds()

        let layoutDescription = Self.displayLayoutDescription(newDisplays)
        let optionDescription = displayOptions.map(\.logDescription).joined(separator: "; ")
        AppLog.session.info("Remote display layout updated; previousCount=\(previousCount, privacy: .public) count=\(newDisplays.count, privacy: .public) selectionBefore=\(previousSelection.logDescription, privacy: .public) selectionAfter=\(self.displaySelection.logDescription, privacy: .public) optionCount=\(self.displayOptions.count, privacy: .public) options=\(optionDescription, privacy: .public) layout=\(layoutDescription, privacy: .public)")

        if newDisplays.count <= 1 {
            AppLog.session.warning("VNC server reported \(newDisplays.count, privacy: .public) screen(s). If the remote Mac has multiple physical displays, it is exposing them as one combined framebuffer or not exposing extended desktop metadata.")
        }
    }

    private static func remoteDisplays(from screens: [VNCScreen]) -> [RemoteDisplay] {
        screens
            .sorted {
                if $0.cgFrame.minY == $1.cgFrame.minY {
                    $0.cgFrame.minX < $1.cgFrame.minX
                } else {
                    $0.cgFrame.minY < $1.cgFrame.minY
                }
            }
            .enumerated()
            .map { index, screen in
                RemoteDisplay(id: screen.id,
                              name: String(localized: "Display \(index + 1)"),
                              frame: screen.cgFrame)
            }
    }

    private static func displayOptions(for displays: [RemoteDisplay],
                                       framebufferFrame: CGRect?) -> [RemoteDisplayOption] {
        var options = [
            RemoteDisplayOption(selection: .all,
                                title: String(localized: "All Displays"),
                                systemImage: "rectangle.split.2x1")
        ]

        if displays.count > 1 {
            options.append(contentsOf: displays.map { display in
                RemoteDisplayOption(selection: .display(display.id),
                                    title: display.menuTitle,
                                    systemImage: "display")
            })
        } else if let framebufferFrame {
            options.append(contentsOf: fallbackDisplayRegions(for: framebufferFrame).map { region in
                RemoteDisplayOption(selection: .region(region),
                                    title: region.title,
                                    systemImage: region.systemImage)
            })
        }

        return options
    }

    private static func fallbackDisplayRegions(for framebufferFrame: CGRect) -> [RemoteDisplayRegion] {
        guard framebufferFrame.width > 0, framebufferFrame.height > 0 else { return [] }

        let aspectRatio = framebufferFrame.width / framebufferFrame.height

        if aspectRatio >= combinedFramebufferAspectRatioThreshold {
            return [.left, .right]
        } else if aspectRatio <= 1 / combinedFramebufferAspectRatioThreshold {
            return [.top, .bottom]
        } else {
            return []
        }
    }

    private static func displayLayoutDescription(_ displays: [RemoteDisplay]) -> String {
        guard !displays.isEmpty else { return "none" }

        return displays.map(\.logDescription).joined(separator: "; ")
    }

    private static func screenLayoutDescription(from screens: [VNCScreen]) -> String {
        guard !screens.isEmpty else { return "none" }

        return screens
            .sorted {
                if $0.cgFrame.minY == $1.cgFrame.minY {
                    $0.cgFrame.minX < $1.cgFrame.minX
                } else {
                    $0.cgFrame.minY < $1.cgFrame.minY
                }
            }
            .map { screen in
                let frame = screen.cgFrame
                let minX = Int(frame.minX.rounded())
                let minY = Int(frame.minY.rounded())
                let width = Int(frame.width.rounded())
                let height = Int(frame.height.rounded())

                return "id=\(screen.id) frame=(x:\(minX),y:\(minY),w:\(width),h:\(height))"
            }
            .joined(separator: "; ")
    }

    private func normalizedDisplaySelection(_ selection: RemoteDisplaySelection) -> RemoteDisplaySelection {
        switch selection {
        case .all:
            return .all
        case .display(let id):
            if displays.count > 1, displays.contains(where: { $0.id == id }) {
                return selection
            } else {
                let availableIDs = displays.map { String($0.id) }.joined(separator: ",")
                AppLog.session.warning("Display selection normalized to all; reason=missingDisplay requested=\(selection.logDescription, privacy: .public) availableDisplayIDs=\(availableIDs, privacy: .public)")

                return .all
            }
        case .region(let region):
            guard displays.count <= 1,
                  let framebufferFrame = framebufferFrameForDisplaySelection,
                  Self.fallbackDisplayRegions(for: framebufferFrame).contains(region) else {
                AppLog.session.warning("Display selection normalized to all; reason=invalidRegion requested=\(selection.logDescription, privacy: .public) reportedDisplayCount=\(self.displays.count, privacy: .public)")

                return .all
            }

            return selection
        }
    }

    private var selectableCursorBounds: CGRect? {
        guard currentFramebufferSize.width > 0,
              currentFramebufferSize.height > 0 else {
            return nil
        }

        let framebufferBounds = CGRect(x: 0,
                                       y: 0,
                                       width: currentFramebufferSize.width,
                                       height: currentFramebufferSize.height)

        guard let selectedDisplayFrame else { return framebufferBounds }

        let displayBounds = selectedDisplayFrame.intersection(framebufferBounds)

        return displayBounds.isNull ? framebufferBounds : displayBounds
    }

    private func clampedCursorPoint(_ point: CGPoint) -> CGPoint {
        guard let bounds = selectableCursorBounds else { return point }

        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                       y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func clampCursorToSelectableBounds() {
        cursorLocation = clampedCursorPoint(cursorLocation)
    }
}

// MARK: - VNCConnectionDelegate

extension VNCSession: VNCConnectionDelegate {
    func connection(_ connection: VNCConnection,
                    stateDidChange connectionState: VNCConnection.ConnectionState) {
        let status = connectionState.status
        let connectionID = ObjectIdentifier(connection)
        let retryableConnectionFailure = Self.isRetryableConnectionFailure(connectionState.error)
        let userFacingMessage: String?

        if let error = connectionState.error as? VNCError,
           error.shouldDisplayToUser {
            userFacingMessage = error.localizedDescription
        } else {
            userFacingMessage = nil
        }

        let errorDescription = connectionState.error?.localizedDescription

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.connection.map(ObjectIdentifier.init) == connectionID else {
                AppLog.session.debug("Ignored state change from stale VNC connection")
                return
            }

            AppLog.session.info("VNC connection state changed to \(String(describing: status), privacy: .public)")

            switch status {
            case .connecting:
                if case .reconnecting = self.status {
                    break
                }

                self.status = .connecting
            case .connected:
                self.cancelReconnectTasks()
                self.automaticReconnectAttempt = 0
                self.settingsReconnectPending = false
                self.hasConnectedAtLeastOnce = true
                self.disconnectRequested = false
                self.lastDisconnectMessage = nil
                self.status = .connected
            case .disconnected:
                if let errorDescription {
                    AppLog.session.error("VNC disconnected with error: \(errorDescription, privacy: .public)")
                } else {
                    AppLog.session.info("VNC disconnected without error")
                }

                self.connection?.delegate = nil
                self.releaseHeldModifiers()
                self.cancelPendingFramebufferUpdates()
                self.connection = nil

                if self.settingsReconnectPending {
                    // Settings changed mid-session: reconnect with new settings.
                    // Wait for macOS's Screen Sharing daemon to release the old
                    // session first — reconnecting instantly gets the new
                    // connection reset (and rapid retries can make the Mac
                    // refuse connections for a while).
                    self.settingsReconnectPending = false
                    self.clearFramebuffer()
                    self.cursor = nil
                    self.scheduleSettingsReconnect()
                } else if self.hasConnectedAtLeastOnce,
                          !self.disconnectRequested,
                          retryableConnectionFailure {
                    self.beginAutomaticReconnect(message: userFacingMessage)
                } else {
                    self.finishDisconnected(message: userFacingMessage)
                }
            default:
                break
            }
        }
    }

    func connection(_ connection: VNCConnection,
                    credentialFor authenticationType: VNCAuthenticationType,
                    completion: @escaping (VNCCredential?) -> Void) {
        AppLog.session.info("Credential requested for authentication type \(String(describing: authenticationType), privacy: .public)")

        // macOS Screen Sharing usually negotiates Apple Remote Desktop auth
        // (username + password). Legacy VNC password auth only needs a password.
        if authenticationType.requiresUsername {
            completion(VNCUsernamePasswordCredential(username: username,
                                                     password: password))
        } else if authenticationType.requiresPassword {
            completion(VNCPasswordCredential(password: password))
        } else {
            completion(nil)
        }
    }

    func connection(_ connection: VNCConnection,
                    didCreateFramebuffer framebuffer: VNCFramebuffer) {
        cancelPendingFramebufferUpdates()

        let cgImage = Self.cgImage(from: framebuffer)
        let imageSize = framebuffer.cgSize
        let screens = framebuffer.screens
        let displays = Self.remoteDisplays(from: screens)
        let screenCount = screens.count
        let screenLayout = Self.screenLayoutDescription(from: screens)

        Task { @MainActor [weak self] in
            guard let self else { return }

            self.publishFramebuffer(cgImage, imageSize: imageSize)
            self.updateDisplays(displays)

            if cgImage != nil {
                AppLog.session.info("Created framebuffer width=\(imageSize.width, privacy: .public) height=\(imageSize.height, privacy: .public) vncScreenCount=\(screenCount, privacy: .public) vncScreens=\(screenLayout, privacy: .public)")
            } else {
                AppLog.session.warning("Created framebuffer without a CGImage; vncScreenCount=\(screenCount, privacy: .public) vncScreens=\(screenLayout, privacy: .public)")
            }

            // Start the trackpad cursor at the center of the screen.
            if self.cursorLocation == .zero,
               imageSize.width > 0,
               imageSize.height > 0 {
                self.cursorLocation = CGPoint(x: imageSize.width / 2,
                                              y: imageSize.height / 2)
            }
        }
    }

    func connection(_ connection: VNCConnection,
                    didResizeFramebuffer framebuffer: VNCFramebuffer) {
        cancelPendingFramebufferUpdates()

        let cgImage = Self.cgImage(from: framebuffer)
        let imageSize = framebuffer.cgSize
        let screens = framebuffer.screens
        let displays = Self.remoteDisplays(from: screens)
        let screenCount = screens.count
        let screenLayout = Self.screenLayoutDescription(from: screens)

        Task { @MainActor [weak self] in
            guard let self else { return }

            self.publishFramebuffer(cgImage, imageSize: imageSize)
            self.updateDisplays(displays)

            if cgImage != nil {
                AppLog.session.info("Resized framebuffer width=\(imageSize.width, privacy: .public) height=\(imageSize.height, privacy: .public) vncScreenCount=\(screenCount, privacy: .public) vncScreens=\(screenLayout, privacy: .public)")
            } else {
                AppLog.session.warning("Resized framebuffer without a CGImage; vncScreenCount=\(screenCount, privacy: .public) vncScreens=\(screenLayout, privacy: .public)")
            }
        }
    }

    func connection(_ connection: VNCConnection,
                    didUpdateFramebuffer framebuffer: VNCFramebuffer,
                    x: UInt16, y: UInt16,
                    width: UInt16, height: UInt16) {
        let imageSize = framebuffer.cgSize
        let dirtyRect = CGRect(x: CGFloat(x),
                               y: CGFloat(y),
                               width: CGFloat(width),
                               height: CGFloat(height))

        enqueueFramebufferUpdate(framebuffer: framebuffer,
                                 imageSize: imageSize,
                                 dirtyRect: dirtyRect)
    }

    func connection(_ connection: VNCConnection,
                    didUpdateCursor cursor: VNCCursor) {
        let remoteCursor: RemoteCursor?

        if cursor.isEmpty {
            remoteCursor = nil
        } else if let image = cursor.cgImage {
            remoteCursor = RemoteCursor(image: image,
                                        hotspot: cursor.cgHotspot,
                                        size: cursor.cgSize)
        } else {
            remoteCursor = nil
        }

        Task { @MainActor [weak self] in
            self?.cursor = remoteCursor
        }
    }
}
