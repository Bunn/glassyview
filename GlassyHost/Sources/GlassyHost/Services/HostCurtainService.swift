import AppKit
import CoreGraphics
import OSLog
import SwiftUI

/// Decides when Curtain Mode is on. Pure state, so every rule is testable.
///
/// Only the device that controls the Mac may turn the curtain on or off. It
/// stays on while that device is connected, and for a short grace period after
/// it disconnects so automatic reconnection does not flash the desktop to
/// anyone at the Mac. A reconnecting device asks again; otherwise it lifts.
struct HostCurtainPolicy: Equatable, Sendable {
    static let reconnectGrace: TimeInterval = 15

    enum Action: Equatable, Sendable {
        case none
        case activate
        case deactivate
        /// Tell the requester only; nothing changes.
        case reject(HostProtocol.CurtainState)
    }

    private(set) var isActive = false
    private(set) var curtainClient: UUID?
    private(set) var graceDeadline: Date?

    mutating func request(from client: UUID, enabled: Bool, isInputOwner: Bool, isAllowed: Bool) -> Action {
        guard isInputOwner else { return .reject(.unavailable) }
        if enabled {
            guard isAllowed else { return .reject(.unavailable) }
            curtainClient = client
            graceDeadline = nil
            if isActive { return .none }
            isActive = true
            return .activate
        }
        return lift()
    }

    /// Starts the grace period when the curtain's device disconnects.
    mutating func clientEnded(_ client: UUID, at date: Date) {
        guard isActive, client == curtainClient else { return }
        curtainClient = nil
        graceDeadline = date.addingTimeInterval(Self.reconnectGrace)
    }

    /// Lifts the curtain once the grace period passes without a new request.
    mutating func expireGrace(at date: Date) -> Action {
        guard isActive, curtainClient == nil, let graceDeadline, date >= graceDeadline else { return .none }
        return lift()
    }

    /// Lifts the curtain because the Mac turned the feature off or stopped sharing.
    mutating func lift() -> Action {
        curtainClient = nil
        graceDeadline = nil
        guard isActive else { return .none }
        isActive = false
        return .deactivate
    }
}

/// Covers every display with an opaque window that screen capture leaves
/// out, and ignores the Mac's own keyboard, mouse, and trackpad, while a
/// paired device controls the Mac.
@MainActor
final class HostCurtainService {
    static let allowsCurtainKey = "curtain.allowsCurtainMode"
    static let defaultAllowsCurtain = true

    /// Publishes a status to every interested connection, or with a target,
    /// to that connection only.
    typealias StatusPublisher = @Sendable (HostProtocol.CurtainStatus, UUID?) -> Void
    typealias CaptureExclusion = @Sendable (Set<CGWindowID>) async throws -> Void

    private let publish: StatusPublisher
    private let excludeFromCapture: CaptureExclusion
    private let defaults: UserDefaults
    private let inputBlocker: any HostLocalInputBlocking
    private let makesShields: Bool
    private var policy = HostCurtainPolicy()
    private var shields: [NSWindow] = []
    private var graceTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var operation: Task<Void, Never>?
    private(set) var status = HostProtocol.CurtainStatus.off

    init(publish: @escaping StatusPublisher,
         excludeFromCapture: @escaping CaptureExclusion,
         defaults: UserDefaults = .standard,
         inputBlocker: any HostLocalInputBlocking = HostLocalInputBlocker(),
         makesShields: Bool = true) {
        self.publish = publish
        self.excludeFromCapture = excludeFromCapture
        self.defaults = defaults
        self.inputBlocker = inputBlocker
        self.makesShields = makesShields
    }

    var isAllowed: Bool {
        get { defaults.object(forKey: Self.allowsCurtainKey) as? Bool ?? Self.defaultAllowsCurtain }
        set {
            defaults.set(newValue, forKey: Self.allowsCurtainKey)
            if !newValue { apply(policy.lift()) }
        }
    }

    var isActive: Bool { policy.isActive }

    func handleRequest(from client: UUID, enabled: Bool, isInputOwner: Bool) {
        let action = policy.request(from: client, enabled: enabled, isInputOwner: isInputOwner, isAllowed: isAllowed)
        if case let .reject(state) = action {
            publish(HostProtocol.CurtainStatus(state: state, blocksLocalInput: false), client)
            return
        }
        if action == .none { publish(status, client) }
        apply(action)
    }

    func clientEnded(_ client: UUID) {
        policy.clientEnded(client, at: Date())
        guard policy.graceDeadline != nil else { return }
        graceTask?.cancel()
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(HostCurtainPolicy.reconnectGrace))
            guard !Task.isCancelled, let self else { return }
            apply(policy.expireGrace(at: Date()))
        }
    }

    /// Lifts the curtain immediately, for example when sharing stops.
    func liftNow() {
        apply(policy.lift())
    }

    // MARK: - Effects

    private func apply(_ action: HostCurtainPolicy.Action) {
        switch action {
        case .none, .reject:
            return
        case .activate:
            graceTask?.cancel()
            enqueue { await self.raise() }
        case .deactivate:
            graceTask?.cancel()
            enqueue { await self.lower() }
        }
    }

    /// Runs raise/lower strictly in order, even across their awaits.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = operation
        operation = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func raise() async {
        guard policy.isActive else { return }
        do {
            try await placeShields()
        } catch {
            HostLog.network.error("Curtain Mode could not hide the screen from capture: \(error.localizedDescription, privacy: .public)")
            let requester = policy.curtainClient
            removeShields()
            _ = policy.lift()
            try? await excludeFromCapture([])
            if let requester {
                publish(HostProtocol.CurtainStatus(state: .failed, blocksLocalInput: false), requester)
            }
            status = .off
            publish(status, nil)
            return
        }
        guard policy.isActive else { return await lower() }
        let blocks = inputBlocker.start()
        status = HostProtocol.CurtainStatus(state: .on, blocksLocalInput: blocks)
        publish(status, nil)
        observeScreenChanges()
        HostLog.network.info("Curtain Mode on; local input blocked=\(blocks, privacy: .public)")
    }

    private func lower() async {
        guard !policy.isActive else { return }
        inputBlocker.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        removeShields()
        try? await excludeFromCapture([])
        status = .off
        publish(status, nil)
        HostLog.network.info("Curtain Mode off")
    }

    /// Shields are created invisible, excluded from capture, and only then
    /// shown, so no streamed frame ever contains them.
    private func placeShields() async throws {
        removeShields()
        guard makesShields else {
            try await excludeFromCapture([])
            return
        }
        shields = NSScreen.screens.map(Self.makeShield(for:))
        shields.forEach { $0.orderFrontRegardless() }
        try await excludeFromCapture(Set(shields.map { CGWindowID($0.windowNumber) }))
        shields.forEach { $0.alphaValue = 1 }
    }

    private func removeShields() {
        shields.forEach { $0.orderOut(nil) }
        shields.removeAll()
    }

    private func observeScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.policy.isActive else { return }
                self.enqueue { await self.raise() }
            }
        }
    }

    private static func makeShield(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.hasShadow = false
        // Remote clicks pass through to the apps underneath.
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: HostCurtainShieldView())
        window.setFrame(screen.frame, display: false)
        return window
    }
}

private struct HostCurtainShieldView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "lock.display")
                    .font(.system(size: 56, weight: .regular))
                Text("This Mac is being used remotely")
                    .font(.title2.weight(.semibold))
                Text("Glassy Desk Curtain Mode is on. The screen returns when the remote session ends.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
    }
}

@MainActor
protocol HostLocalInputBlocking: AnyObject {
    /// Returns false when macOS refuses to block input.
    func start() -> Bool
    func stop()
}

/// Drops hardware input at the HID level while Curtain Mode is on. Remote
/// input carries `HostSyntheticInput.marker` and passes through.
final class HostLocalInputBlocker: HostLocalInputBlocking {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    /// Returns false when macOS refuses the tap, for example without Accessibility.
    func start() -> Bool {
        if tap != nil { return true }
        let mask = Self.blockedEventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let userInfo {
                    let blocker = Unmanaged<HostLocalInputBlocker>.fromOpaque(userInfo).takeUnretainedValue()
                    if let tap = blocker.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return HostLocalInputBlocker.allows(event) ? Unmanaged.passUnretained(event) : nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    isolated deinit {
        stop()
    }

    nonisolated static func allows(_ event: CGEvent) -> Bool {
        HostSyntheticInput.isSynthetic(event)
    }

    /// Keyboard, pointer, scroll, tablet, gesture, and system-defined (media
    /// and brightness key) events.
    nonisolated static let blockedEventTypes: [UInt32] = [
        CGEventType.keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        .mouseMoved, .scrollWheel, .tabletPointer, .tabletProximity
    ].map(\.rawValue) + [
        14, // NX_SYSDEFINED
        18, 19, 20, // rotate, begin and end gesture
        29, 30, 31, 32, 34 // gesture, magnify, swipe, smart magnify, pressure
    ]
}
