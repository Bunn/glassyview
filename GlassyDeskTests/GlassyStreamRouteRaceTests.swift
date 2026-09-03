import CryptoKit
import Foundation
import Network
import Testing
@testable import GlassyDesk

struct GlassyStreamRouteRaceTests {
    @Test
    func stalledPrimaryDoesNotDelayReachableFallback() throws {
        let harness = RouteRaceHarness()
        try harness.queue.sync {
            harness.race.start()
            let primary = try #require(harness.transport(0))
            primary.ready() // TCP connected, but the server never sends hello.
            harness.clock.advance(to: GlassyStreamRouteRace.stagger)
            let fallback = try #require(harness.transport(1))
            fallback.ready()
            let hello = try routeHello(identifier: harness.hostID)
            fallback.deliver(hello)

            #expect(harness.selections.count == 1)
            #expect(harness.selections.first?.transport.endpoint == harness.endpoints[1])
            #expect(harness.selections.first?.prefetchedData == hello)
            #expect(primary.isCancelled)
            #expect(!fallback.isCancelled)
            #expect(harness.clock.now < 1)
        }
    }

    @Test
    func wrongHostNeverReceivesBootstrapAndDoesNotBlockCorrectHost() throws {
        let harness = RouteRaceHarness()
        try harness.queue.sync {
            harness.race.start()
            let wrong = try #require(harness.transport(0))
            wrong.ready()
            wrong.deliver(try routeHello(identifier: Data(repeating: 0x99, count: 16)))
            let correct = try #require(harness.transport(1))
            correct.ready()
            correct.deliver(try routeHello(identifier: harness.hostID))

            #expect(wrong.isCancelled)
            #expect(harness.bootstrapRecipients == [harness.endpoints[1]])
            #expect(harness.failures.isEmpty)
        }
    }

    @Test
    func simultaneousValidHellosSelectExactlyOneBootstrapRecipient() throws {
        let harness = RouteRaceHarness()
        try harness.queue.sync {
            harness.race.start()
            let first = try #require(harness.transport(0))
            first.ready()
            let lateFirstCallback = try #require(first.receiveCallback)
            harness.clock.advance(to: GlassyStreamRouteRace.stagger)
            let second = try #require(harness.transport(1))
            second.ready()
            let lateSecondCallback = try #require(second.receiveCallback)
            let hello = try routeHello(identifier: harness.hostID)
            second.deliver(hello)
            // Network callbacks may already have been queued before cancel.
            lateFirstCallback(hello, false, nil)
            lateSecondCallback(hello, false, nil)
            harness.clock.advance(to: 20)
            #expect(harness.bootstrapRecipients == [harness.endpoints[1]])
            #expect(harness.selections.count == 1)
            #expect(harness.failures.isEmpty)
        }
    }

    @Test
    func cancellationRetiresPendingRoutesAndLateCallbacks() throws {
        let harness = RouteRaceHarness()
        try harness.queue.sync {
            harness.race.start()
            let first = try #require(harness.transport(0))
            first.ready()
            let lateCallback = try #require(first.receiveCallback)
            harness.race.cancel()
            lateCallback(try routeHello(identifier: harness.hostID), false, nil)
            harness.clock.advance(to: 20)
            #expect(first.isCancelled)
            #expect(harness.transport(1) == nil)
            #expect(harness.selections.isEmpty)
            #expect(harness.failures.isEmpty)
        }
    }

    @Test
    func staleCancelledGenerationCannotWinReplacementRace() throws {
        let old = RouteRaceHarness()
        let fresh = RouteRaceHarness()
        let lateCallback = try old.queue.sync {
            old.race.start()
            let first = try #require(old.transport(0))
            first.ready()
            let callback = try #require(first.receiveCallback)
            old.race.cancel()
            return callback
        }
        try fresh.queue.sync {
            fresh.race.start()
            let first = try #require(fresh.transport(0))
            first.ready()
            first.deliver(try routeHello(identifier: fresh.hostID))
        }
        try old.queue.sync {
            lateCallback(try routeHello(identifier: old.hostID), false, nil)
            #expect(old.bootstrapRecipients.isEmpty)
        }
        fresh.queue.sync { #expect(fresh.bootstrapRecipients == [fresh.endpoints[0]]) }
    }

    @Test
    func allRoutesHaveOneBoundedDeadlineAndPreserveIdentityFailure() throws {
        let harness = RouteRaceHarness()
        try harness.queue.sync {
            harness.race.start()
            let wrong = try #require(harness.transport(0))
            wrong.ready()
            wrong.deliver(try routeHello(identifier: Data(repeating: 0x99, count: 16)))
            harness.clock.advance(to: GlassyStreamRouteRace.timeout)
            #expect(harness.failures.count == 1)
            if case .hostIdentityMismatch = harness.failures.first {} else {
                Issue.record("Identity mismatch was replaced with an unrelated timeout")
            }
            let allCancelled = harness.transports.allSatisfy { $0.isCancelled }
            #expect(allCancelled)
            #expect(harness.bootstrapRecipients.isEmpty)
        }
    }

    @Test
    func oneTimeCodeUsesNormalOSRoutesWhilePasswordStillRequiresVPN() throws {
        for requiresVPN in [false, true] {
            let harness = RouteRaceHarness(requiresVPN: requiresVPN)
            try harness.queue.sync {
                harness.race.start()
                let first = try #require(harness.transport(0))
                first.usesVPNInterface = false
                first.ready()
                if requiresVPN {
                    #expect(first.isCancelled)
                    let second = try #require(harness.transport(1))
                    second.usesVPNInterface = true
                    second.ready()
                    second.deliver(try routeHello(identifier: harness.hostID))
                    #expect(harness.bootstrapRecipients == [harness.endpoints[1]])
                } else {
                    first.deliver(try routeHello(identifier: harness.hostID))
                    #expect(harness.bootstrapRecipients == [harness.endpoints[0]])
                }
            }
        }
    }

    @Test
    func fragmentedHelloIsRetainedAndMalformedRouteCanFallBack() throws {
        let harness = RouteRaceHarness()
        try harness.queue.sync {
            harness.race.start()
            let first = try #require(harness.transport(0))
            first.ready()
            first.deliver(Data(repeating: 0, count: GlassyStreamWire.headerLength))
            #expect(first.isCancelled)
            let second = try #require(harness.transport(1))
            second.ready()
            let hello = try routeHello(identifier: harness.hostID)
            second.deliver(Data(hello.prefix(13)))
            #expect(harness.selections.isEmpty)
            second.deliver(Data(hello.dropFirst(13)))
            #expect(harness.selections.first?.prefetchedData == hello)
        }
    }

    @Test
    func routeCountIsBoundedAndDuplicateEndpointsAreNotOpenedTwice() {
        let harness = RouteRaceHarness(routeCount: 12, duplicateFirst: true)
        harness.queue.sync {
            harness.race.start()
            harness.clock.advance(to: 2)
            #expect(harness.transports.count == GlassyStreamRouteRace.maximumRoutes)
            #expect(Set(harness.transports.map(\.endpoint)).count == harness.transports.count)
            harness.race.cancel()
        }
    }
}

private final class RouteRaceHarness: @unchecked Sendable {
    let queue = DispatchQueue(label: "test.glassy.route-race")
    let clock = RouteTestClock()
    let hostID = Data(repeating: 0x42, count: 16)
    let endpoints: [NWEndpoint]
    let requiresVPN: Bool
    var transports: [TestRouteTransport] = []
    var selections: [GlassyStreamRouteRace.Selection] = []
    var failures: [GlassyStreamClientError] = []
    var bootstrapRecipients: [NWEndpoint] = []

    lazy var race = GlassyStreamRouteRace(
        endpoints: endpoints,
        expectedHostIdentifier: hostID,
        requiresVPNInterface: requiresVPN,
        queue: queue,
        factory: { [unowned self] endpoint in
            let transport = TestRouteTransport(endpoint: endpoint)
            transports.append(transport)
            return transport
        },
        scheduler: { [clock] delay, work in clock.schedule(after: delay, work: work) }
    ) { [unowned self] result in
        switch result {
        case let .success(selection):
            selections.append(selection)
            // Models the sole authentication handoff, not a per-route retry.
            bootstrapRecipients.append(selection.transport.endpoint)
        case let .failure(error): failures.append(error)
        }
    }

    init(routeCount: Int = 2, duplicateFirst: Bool = false, requiresVPN: Bool = false) {
        let routes: [NWEndpoint] = (0..<routeCount).map {
            .hostPort(host: NWEndpoint.Host("192.0.2.\($0 + 1)"), port: 51515)
        }
        endpoints = duplicateFirst ? [routes[0]] + routes : routes
        self.requiresVPN = requiresVPN
    }

    func transport(_ index: Int) -> TestRouteTransport? {
        transports.first { $0.endpoint == endpoints[index] }
    }
}

private final class RouteTestClock: @unchecked Sendable {
    var now: TimeInterval = 0
    private var work: [(TimeInterval, DispatchWorkItem)] = []

    func schedule(after delay: TimeInterval, work item: DispatchWorkItem) {
        work.append((now + delay, item))
    }

    func advance(to deadline: TimeInterval) {
        while let next = work.enumerated().filter({ $0.element.0 <= deadline })
            .min(by: { $0.element.0 < $1.element.0 }) {
            work.remove(at: next.offset)
            now = next.element.0
            if !next.element.1.isCancelled { next.element.1.perform() }
        }
        now = deadline
    }
}

private final class TestRouteTransport: GlassyStreamRouteTransport, @unchecked Sendable {
    let endpoint: NWEndpoint
    var networkConnection: NWConnection? { nil }
    var usesVPNInterface = false
    var isCancelled = false
    var stateCallback: (@Sendable (GlassyStreamRouteState) -> Void)?
    var receiveCallback: (@Sendable (Data?, Bool, GlassyStreamClientError?) -> Void)?

    init(endpoint: NWEndpoint) { self.endpoint = endpoint }
    func start(on queue: DispatchQueue, state: @escaping @Sendable (GlassyStreamRouteState) -> Void) {
        stateCallback = state
    }
    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, GlassyStreamClientError?) -> Void) {
        receiveCallback = completion
    }
    func detachStateHandler() { stateCallback = nil }
    func cancel() { isCancelled = true }
    func ready() { stateCallback?(.ready) }
    func deliver(_ data: Data) {
        let callback = receiveCallback
        receiveCallback = nil
        callback?(data, false, nil)
    }
}

private func routeHello(identifier: Data, publicKey: Data = Data(repeating: 0x51, count: 32)) throws -> Data {
    var payload = identifier
    payload.append(Data(repeating: 0x31, count: 32))
    payload.append(publicKey)
    payload.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1]) // pairing window
    payload.append(contentsOf: [0, 60])
    payload.append(contentsOf: [0, 0, 0, 7]) // encrypted H.264 and direct input
    let name = Data("Fixture Mac".utf8)
    payload.append(contentsOf: [0, UInt8(name.count)])
    payload.append(name)
    return try GlassyStreamWire.encode(.init(kind: .serverHello, flags: [], sequence: 1, payload: payload))
}
