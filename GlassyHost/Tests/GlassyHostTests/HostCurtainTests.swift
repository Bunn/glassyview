import CoreGraphics
import Foundation
import Testing
@testable import GlassyHost

@Test("Curtain messages use exact four-byte payloads and capability bit 9")
func curtainProtocolCodec() throws {
    #expect(HostProtocol.Capabilities.curtainMode.rawValue == 1 << 9)
    #expect(HostProtocol.advertisedCapabilities.contains(.curtainMode))
    #expect(HostProtocol.MessageKind.curtainRequest.rawValue == 0x25)
    #expect(HostProtocol.MessageKind.curtainStatus.rawValue == 0x26)

    #expect(HostProtocol.encodeCurtainRequest(enabled: true) == Data([1, 0, 0, 0]))
    #expect(try HostProtocol.decodeCurtainRequest(Data([0, 0, 0, 0])) == false)
    #expect(try HostProtocol.decodeCurtainRequest(Data([1, 0, 0, 0])))
    for invalid in [Data(), Data([2, 0, 0, 0]), Data([1, 0, 1, 0]), Data([1, 0, 0])] {
        #expect(throws: HostProtocol.ProtocolError.self) { try HostProtocol.decodeCurtainRequest(invalid) }
    }

    for state in HostProtocol.CurtainState.allCases {
        for blocks in [false, true] {
            let status = HostProtocol.CurtainStatus(state: state, blocksLocalInput: blocks)
            #expect(try HostProtocol.decodeCurtainStatus(HostProtocol.encodeCurtainStatus(status)) == status)
        }
    }
    for invalid in [Data([4, 0, 0, 0]), Data([1, 2, 0, 0]), Data([1, 0, 0, 1]), Data([1, 0, 0, 0, 0])] {
        #expect(throws: HostProtocol.ProtocolError.self) { try HostProtocol.decodeCurtainStatus(invalid) }
    }
}

@Test("Only the controlling device can raise or lower the curtain, and only when allowed")
func curtainPolicyOwnership() {
    var policy = HostCurtainPolicy()
    let owner = UUID()
    let viewer = UUID()

    #expect(policy.request(from: viewer, enabled: true, isInputOwner: false, isAllowed: true) == .reject(.unavailable))
    #expect(policy.request(from: owner, enabled: true, isInputOwner: true, isAllowed: false) == .reject(.unavailable))
    #expect(!policy.isActive)

    #expect(policy.request(from: owner, enabled: true, isInputOwner: true, isAllowed: true) == .activate)
    #expect(policy.request(from: owner, enabled: true, isInputOwner: true, isAllowed: true) == .none)
    #expect(policy.request(from: viewer, enabled: false, isInputOwner: false, isAllowed: true) == .reject(.unavailable))
    #expect(policy.isActive)
    #expect(policy.request(from: owner, enabled: false, isInputOwner: true, isAllowed: true) == .deactivate)
    #expect(policy.request(from: owner, enabled: false, isInputOwner: true, isAllowed: true) == .none)
}

@Test("A disconnect lifts the curtain only after the reconnect grace period")
func curtainPolicyGrace() {
    var policy = HostCurtainPolicy()
    let device = UUID()
    let start = Date(timeIntervalSince1970: 1_000)
    _ = policy.request(from: device, enabled: true, isInputOwner: true, isAllowed: true)

    // Another connection ending changes nothing.
    policy.clientEnded(UUID(), at: start)
    #expect(policy.graceDeadline == nil)

    policy.clientEnded(device, at: start)
    #expect(policy.expireGrace(at: start.addingTimeInterval(HostCurtainPolicy.reconnectGrace - 1)) == .none)

    // Reconnecting and asking again keeps it up through the old deadline.
    let reconnected = UUID()
    #expect(policy.request(from: reconnected, enabled: true, isInputOwner: true, isAllowed: true) == .none)
    #expect(policy.expireGrace(at: start.addingTimeInterval(HostCurtainPolicy.reconnectGrace + 1)) == .none)
    #expect(policy.isActive)

    policy.clientEnded(reconnected, at: start)
    #expect(policy.expireGrace(at: start.addingTimeInterval(HostCurtainPolicy.reconnectGrace)) == .deactivate)
    #expect(!policy.isActive)
    #expect(policy.lift() == .none)
}

@Test("Only marked remote input passes the local input filter")
func curtainInputFilter() throws {
    let local = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    #expect(!HostLocalInputBlocker.allows(local))
    let remote = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                      mouseCursorPosition: .zero, mouseButton: .left))
    HostSyntheticInput.mark(remote)
    #expect(HostLocalInputBlocker.allows(remote))
    #expect(HostSyntheticInput.isSynthetic(remote))

    let types = Set(HostLocalInputBlocker.blockedEventTypes)
    for type: CGEventType in [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDragged, .scrollWheel] {
        #expect(types.contains(type.rawValue))
    }
    #expect(!types.contains(CGEventType.tapDisabledByTimeout.rawValue))
}

@MainActor
@Test("Raising excludes shields before reporting, and lowering restores capture")
func curtainServiceLifecycle() async throws {
    let recorder = CurtainRecorder()
    let blocker = FakeInputBlocker(succeeds: true)
    let defaults = try #require(UserDefaults(suiteName: "HostCurtainTests.\(UUID().uuidString)"))
    let service = HostCurtainService(
        publish: { status, target in recorder.published(status, target) },
        excludeFromCapture: { ids in recorder.excluded(ids) },
        defaults: defaults,
        inputBlocker: blocker,
        makesShields: false
    )
    let owner = UUID()

    service.handleRequest(from: owner, enabled: true, isInputOwner: true)
    try await recorder.waitFor { $0.statuses.last?.0.state == .on }
    #expect(recorder.snapshot.statuses.last?.0 == .init(state: .on, blocksLocalInput: true))
    #expect(recorder.snapshot.statuses.last?.1 == nil, "Broadcast to every interested connection")
    #expect(blocker.isRunning)
    #expect(service.isActive)

    // A view-only request is answered privately and changes nothing.
    let viewer = UUID()
    service.handleRequest(from: viewer, enabled: false, isInputOwner: false)
    #expect(recorder.snapshot.statuses.last?.0.state == .unavailable)
    #expect(recorder.snapshot.statuses.last?.1 == viewer)
    #expect(service.isActive)

    // Turning the feature off on the Mac lifts the curtain at once.
    service.isAllowed = false
    try await recorder.waitFor { $0.statuses.last?.0 == .off }
    #expect(!blocker.isRunning)
    #expect(recorder.snapshot.exclusions.last == [])
    service.handleRequest(from: owner, enabled: true, isInputOwner: true)
    #expect(recorder.snapshot.statuses.last?.0.state == .unavailable)
    #expect(!service.isActive)
}

@MainActor
@Test("Without Accessibility the curtain still hides the screen and says input is not blocked")
func curtainWithoutInputBlocking() async throws {
    let recorder = CurtainRecorder()
    let service = HostCurtainService(
        publish: { status, target in recorder.published(status, target) },
        excludeFromCapture: { ids in recorder.excluded(ids) },
        defaults: try #require(UserDefaults(suiteName: "HostCurtainTests.\(UUID().uuidString)")),
        inputBlocker: FakeInputBlocker(succeeds: false),
        makesShields: false
    )
    service.handleRequest(from: UUID(), enabled: true, isInputOwner: true)
    try await recorder.waitFor { $0.statuses.last?.0.state == .on }
    #expect(recorder.snapshot.statuses.last?.0.blocksLocalInput == false)
    service.liftNow()
    try await recorder.waitFor { $0.statuses.last?.0 == .off }
}

// MARK: - Fixtures

@MainActor
private final class FakeInputBlocker: HostLocalInputBlocking {
    let succeeds: Bool
    private(set) var isRunning = false
    init(succeeds: Bool) { self.succeeds = succeeds }
    func start() -> Bool {
        isRunning = succeeds
        return succeeds
    }
    func stop() { isRunning = false }
}

private final class CurtainRecorder: @unchecked Sendable {
    struct Snapshot {
        var statuses: [(HostProtocol.CurtainStatus, UUID?)] = []
        var exclusions: [Set<CGWindowID>] = []
    }

    private let lock = NSLock()
    private var state = Snapshot()
    var snapshot: Snapshot { lock.withLock { state } }

    func published(_ status: HostProtocol.CurtainStatus, _ target: UUID?) {
        lock.withLock { state.statuses.append((status, target)) }
    }

    func excluded(_ ids: Set<CGWindowID>) {
        lock.withLock { state.exclusions.append(ids) }
    }

    func waitFor(_ condition: @Sendable (Snapshot) -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(snapshot) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for Curtain Mode")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
