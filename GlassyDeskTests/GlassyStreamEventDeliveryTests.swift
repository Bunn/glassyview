import Foundation
import Testing
@testable import GlassyDesk

struct GlassyStreamEventDeliveryTests {
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
    let queue = DispatchQueue(label: "GlassyStreamEventDeliveryTests")
    var clock: TimeInterval = 0
    var events: [GlassyStreamEvent] = []
    var retired: [(UInt64, UInt32)] = []
    var recoveries = 0
    let configuration = GlassyStreamVideoConfiguration(nalUnitHeaderLength: 4, parameterSets: [Data([1])])
    lazy var delivery = GlassyStreamEventDelivery(queue: queue,
        callbacks: .init(onEvent: { [weak self] event in self?.events.append(event) }, onCompletion: { _ in }),
        maximumFrames: 3, maximumBytes: 12, now: { [weak self] in self?.clock ?? 0 },
        onRetired: { [weak self] sequence, age in self?.retired.append((sequence, age)) },
        onRecovery: { [weak self] in self?.recoveries += 1 })

    func frame(key: Bool) -> GlassyStreamEvent {
        .videoAccessUnit(.init(data: Data([0, 0, 0, 1]), presentationTime: 0, duration: nil, isKeyFrame: key))
    }
}
