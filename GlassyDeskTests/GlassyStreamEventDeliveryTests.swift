import Foundation
import Testing
@testable import GlassyDesk

struct GlassyStreamEventDeliveryTests {
    @Test func defaultCapacityPreservesAHealthyWindowDeliveredAsOneBurst() {
        let h = DeliveryHarness(useDefaultCapacity: true)
        h.queue.suspend()
        h.delivery.offer(.videoConfiguration(h.configuration))
        // TCP/Wi-Fi may deliver one complete host credit window together.
        // Every frame is fresh and the whole dependency chain is present.
        for sequence in 1...16 {
            h.delivery.offer(h.frame(key: sequence == 1), sequence: UInt64(sequence))
        }
        h.queue.resume()
        h.waitForDrain()
        #expect(h.events.count == 17)
        #expect(!h.events.contains(.videoDiscontinuity))
        #expect(h.recoveries == 0)
        #expect(h.retired.map(\.0).max() == 16)
    }

    @Test func defaultCapacityStillRejectsExpiredBurst() {
        let h = DeliveryHarness(useDefaultCapacity: true)
        h.queue.suspend()
        h.delivery.offer(.videoConfiguration(h.configuration))
        for sequence in 1...16 {
            h.delivery.offer(h.frame(key: sequence == 1), sequence: UInt64(sequence))
        }
        h.clock = 0.151
        h.queue.resume()
        h.waitForDrain()
        #expect(h.events == [.videoConfiguration(h.configuration), .videoDiscontinuity])
        #expect(h.recoveries == 1)
        #expect(h.retired.map(\.0).max() == 16)
    }

    @Test func overflowDropsBrokenDependenciesUntilFreshKeyFrame() {
        let h = DeliveryHarness()
        h.queue.suspend()
        h.delivery.offer(.videoConfiguration(h.configuration))
        for sequence in 1...20 {
            h.delivery.offer(h.frame(key: sequence == 1), sequence: UInt64(sequence))
            #expect(h.delivery.pendingMediaBytes <= 12)
        }
        h.delivery.offer(h.frame(key: true), sequence: 21)
        h.queue.resume()
        h.queue.sync {}
        #expect(h.events == [.videoConfiguration(h.configuration), .videoDiscontinuity, h.frame(key: true)])
        #expect(h.recoveries == 1)
        #expect(h.retired.map(\.0).max() == 21)
    }

    @Test func stalledCallbackQueueNeverDeliversExpiredMedia() {
        let h = DeliveryHarness()
        h.queue.suspend()
        h.delivery.offer(.videoConfiguration(h.configuration))
        h.delivery.offer(h.frame(key: true), sequence: 1)
        h.delivery.offer(h.frame(key: false), sequence: 2)
        h.clock = 1
        h.queue.resume()
        h.queue.sync {}
        #expect(h.events == [.videoConfiguration(h.configuration), .videoDiscontinuity])
        #expect(h.recoveries == 1)
        #expect(h.retired.contains { $0.0 == 2 && $0.1 == 1_000 })
    }

    @Test func configurationReplacementNeverMixesOldFramesWithNewFormat() {
        let h = DeliveryHarness()
        let newer = GlassyStreamVideoConfiguration(nalUnitHeaderLength: 4, parameterSets: [Data([2])])
        h.queue.suspend()
        h.delivery.offer(.videoConfiguration(h.configuration))
        h.delivery.offer(h.frame(key: true), sequence: 1)
        h.delivery.offer(.videoConfiguration(newer))
        h.delivery.offer(h.frame(key: false), sequence: 2)
        h.delivery.offer(h.frame(key: true), sequence: 3)
        h.queue.resume()
        h.queue.sync {}
        #expect(h.events == [.videoConfiguration(newer), h.frame(key: true)])
        #expect(h.retired.map(\.0).max() == 3)
    }

    @Test func equivalentConfigurationPreservesQueuedDependencies() {
        let h = DeliveryHarness()
        let equivalent = GlassyStreamVideoConfiguration(
            nalUnitHeaderLength: 4, parameterSets: [Data([1])])
        h.queue.suspend()
        h.delivery.offer(.videoConfiguration(h.configuration))
        h.delivery.offer(h.frame(key: true), sequence: 1)
        h.delivery.offer(h.frame(key: false), sequence: 2)
        h.delivery.offer(.videoConfiguration(equivalent))
        h.delivery.offer(h.frame(key: false), sequence: 3)
        #expect(h.delivery.pendingMediaBytes == 12)
        #expect(h.retired.isEmpty)
        h.queue.resume()
        h.waitForDrain()
        #expect(h.events == [.videoConfiguration(h.configuration), h.frame(key: true),
                             h.frame(key: false), h.frame(key: false)])
        #expect(h.recoveries == 0)
        #expect(h.retired.map(\.0).max() == 3)
    }

    @Test func newConnectionStillReceivesPreviouslyUsedConfiguration() {
        let previous = DeliveryHarness()
        previous.delivery.offer(.videoConfiguration(previous.configuration))
        previous.waitForDrain()
        previous.delivery.cancel()

        // Each authenticated connection owns a fresh mailbox. Remembering an
        // identical format in the retired connection must not skip bootstrap.
        let current = DeliveryHarness()
        current.queue.suspend()
        current.delivery.offer(.videoConfiguration(previous.configuration))
        current.delivery.offer(current.frame(key: true), sequence: 1)
        current.queue.resume()
        current.waitForDrain()
        #expect(current.events == [.videoConfiguration(current.configuration), current.frame(key: true)])
        #expect(current.recoveries == 0)
    }

    @Test func cursorFloodCoalescesAndCancellationRetiresQueuedCallbacks() {
        let h = DeliveryHarness()
        h.queue.suspend()
        for x in 0..<1_000 {
            h.delivery.offer(.cursorPosition(.init(x: UInt16(x), y: 1)))
        }
        h.queue.resume()
        h.queue.sync {}
        #expect(h.events == [.cursorPosition(.init(x: 999, y: 1))])
        h.queue.suspend()
        h.delivery.offer(h.frame(key: true), sequence: 1)
        h.delivery.cancel()
        h.queue.resume()
        h.queue.sync {}
        #expect(h.events.count == 1)
        #expect(h.delivery.pendingMediaBytes == 0)
    }

    @Test func rejectsOversizeKeyframeWithoutUnboundedRetention() {
        let h = DeliveryHarness()
        h.queue.suspend()
        let unit = GlassyStreamVideoAccessUnit(data: Data(repeating: 1, count: 13), presentationTime: 0,
                                             duration: nil, isKeyFrame: true)
        h.delivery.offer(.videoAccessUnit(unit), sequence: 7)
        #expect(h.delivery.pendingMediaBytes == 0)
        h.queue.resume()
        h.queue.sync {}
        #expect(h.events == [.videoDiscontinuity])
        #expect(h.recoveries == 1)
        #expect(h.retired.map(\.0).max() == 7)
    }

    @Test func strictAdaptiveStatusAndFeedbackWireLayout() throws {
        #expect(GlassyStreamWire.encodeStreamFeedback(sequence: 0x0102030405060708, queueAgeMilliseconds: 0x090A0B0C)
                == Data([1,2,3,4,5,6,7,8,9,10,11,12,0,0,0,0]))
        let status = try GlassyStreamWire.decodeHostStreamStatus(Data([1, 3, 0, 0]))
        #expect(status.state == .streaming && status.ownsInput && status.accessibilityGranted)
        #expect(status.message == nil)
        for invalid in [Data([6, 0, 0, 0]), Data([1, 4, 0, 0]), Data([1, 0, 0, 1]), Data([1, 0, 0]), Data([1, 0, 0, 0, 0])] {
            #expect(throws: GlassyStreamClientError.self) {
                try GlassyStreamWire.decodeHostStreamStatus(invalid)
            }
        }
    }
}

/// All mutation happens while the queue is suspended or in its callback, and
/// each test joins the queue before inspecting captured output.
private final class DeliveryHarness: @unchecked Sendable {
    let useDefaultCapacity: Bool
    let queue = DispatchQueue(label: "GlassyStreamEventDeliveryTests")
    var clock: TimeInterval = 0
    var events: [GlassyStreamEvent] = []
    var retired: [(UInt64, UInt32)] = []
    var recoveries = 0
    let configuration = GlassyStreamVideoConfiguration(nalUnitHeaderLength: 4, parameterSets: [Data([1])])
    lazy var delivery: GlassyStreamEventDelivery = {
        let callbacks = GlassyStreamClientCallbacks(
            onEvent: { [weak self] event in self?.events.append(event) }, onCompletion: { _ in })
        let now: @Sendable () -> TimeInterval = { [weak self] in self?.clock ?? 0 }
        let onRetired: @Sendable (UInt64, UInt32) -> Void = { [weak self] sequence, age in
            self?.retired.append((sequence, age))
        }
        let onRecovery: @Sendable () -> Void = { [weak self] in self?.recoveries += 1 }
        if useDefaultCapacity {
            return GlassyStreamEventDelivery(queue: queue, callbacks: callbacks,
                now: now, onRetired: onRetired, onRecovery: onRecovery)
        }
        return GlassyStreamEventDelivery(queue: queue, callbacks: callbacks,
            maximumFrames: 3, maximumBytes: 12,
            now: now, onRetired: onRetired, onRecovery: onRecovery)
    }()

    init(useDefaultCapacity: Bool = false) {
        self.useDefaultCapacity = useDefaultCapacity
    }

    func waitForDrain() {
        // A drain yields after eight callbacks. Allow all bounded batches to
        // finish before inspecting the captured events on the test thread.
        for _ in 0..<4 { queue.sync {} }
    }

    func frame(key: Bool) -> GlassyStreamEvent {
        .videoAccessUnit(.init(data: Data([0, 0, 0, 1]), presentationTime: 0, duration: nil, isKeyFrame: key))
    }
}
