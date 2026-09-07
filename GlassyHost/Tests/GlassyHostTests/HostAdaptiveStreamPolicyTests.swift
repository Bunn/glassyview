import Foundation
import Testing
@testable import GlassyHost

@Test("Receiver progress bounds both outstanding media and stale acknowledgements")
func mediaDeliveryWindowRequiresReceiverProgress() throws {
    var window = HostMediaDeliveryWindow()
    for sequence in UInt64(10)...12 {
        window.sent(sequence: sequence, bytes: 8_000, at: 1)
    }
    #expect(!window.hasCredit(bitRate: 2_000_000))
    #expect(window.oldestAge(at: 1.4) > 0.39)
    #expect(try window.acknowledge(sequence: 11, at: 1.4) != nil)
    #expect(window.hasCredit(bitRate: 2_000_000))
    #expect(window.frames.map(\.sequence) == [12])
    #expect(try window.acknowledge(sequence: 10, at: 2) == nil)
    #expect(throws: HostProtocol.ProtocolError.self) {
        try window.acknowledge(sequence: 13, at: 2)
    }
    #expect(window.frames.map(\.sequence) == [12])
}

@Test("Adaptive stream downshifts below one Mbps and recovers only after sustained progress")
func adaptiveRateCongestionAndRecovery() {
    var policy = HostAdaptiveRatePolicy()
    for time in [0.0, 0.5, 1.0, 1.5, 2.0] {
        policy.acknowledged(deliveryAge: 0.8, queueAge: 0.2, ceiling: 12_000_000, at: time)
    }
    #expect(policy.bitRate == HostAdaptiveRatePolicy.minimumBitRate)
    let lowered = policy.bitRate
    policy.acknowledged(deliveryAge: 0.04, queueAge: 0.01, ceiling: 12_000_000, at: 3)
    policy.acknowledged(deliveryAge: 0.04, queueAge: 0.01, ceiling: 12_000_000, at: 5.9)
    #expect(policy.bitRate == lowered)
    policy.acknowledged(deliveryAge: 0.04, queueAge: 0.01, ceiling: 12_000_000, at: 6)
    #expect(policy.bitRate > lowered)
    policy.constrain(to: 400_000)
    #expect(policy.bitRate == 400_000)
}

@Test("A stalled receiver reduces resolution and cadence without violating the user's quality ceiling")
func adaptiveCaptureTiersRespectCeiling() {
    let low = HostStreamQualityConfiguration(quality: .best, availableBitRate: 350_000)
    #expect(low.maximumWidth == 960)
    #expect(low.maximumHeight == 540)
    #expect(low.framesPerSecond == 8)
    #expect(low.averageBitRate == 350_000)
    let saver = HostStreamQualityConfiguration(quality: .dataSaver, availableBitRate: 12_000_000)
    #expect(saver == HostStreamQualityConfiguration(quality: .dataSaver))
    #expect(HostStreamQualityConfiguration(quality: .best, availableBitRate: nil)
            == HostStreamQualityConfiguration(quality: .best))
}

@Test("Adaptive v1 feedback and status use strict independently negotiated envelopes")
func adaptiveWireEnvelopes() throws {
    let feedback = HostProtocol.StreamFeedback(latestHandledVideoSequence: 0x0102030405060708,
                                               callbackQueueAgeMilliseconds: 123)
    let encoded = HostProtocol.encodeStreamFeedback(feedback)
    #expect(encoded.count == 16)
    #expect(Array(encoded.prefix(8)) == [1,2,3,4,5,6,7,8])
    #expect(try HostProtocol.decodeStreamFeedback(encoded) == feedback)
    var bad = encoded
    bad[15] = 1
    #expect(throws: HostProtocol.ProtocolError.self) { try HostProtocol.decodeStreamFeedback(bad) }
    #expect(throws: HostProtocol.ProtocolError.self) { try HostProtocol.decodeStreamFeedback(encoded + Data([0])) }
    for state in HostProtocol.StreamState.allCases {
        let status = HostProtocol.StreamStatus(state: state, accessibilityGranted: true, ownsInput: false)
        #expect(try HostProtocol.decodeStreamStatus(HostProtocol.encodeStreamStatus(status)) == status)
    }
    #expect(throws: HostProtocol.ProtocolError.self) { try HostProtocol.decodeStreamStatus(Data([1,4,0,0])) }
}

@Test("A view-only disconnect leaves held input with its owner; owner loss transfers control")
func inputOwnershipTransfersOnlyOnOwnerLoss() {
    var policy = HostInputOwnership()
    let first = UUID(), second = UUID(), third = UUID()
    policy.add(first); policy.add(second); policy.add(third)
    #expect(policy.owner == first)
    #expect(policy.remove(second) == false)
    #expect(policy.owner == first)
    #expect(policy.remove(first) == true)
    #expect(policy.owner == third)
    #expect(policy.remove(first) == false)
    #expect(policy.owner == third)
}

@Test("Resuming a viewer preserves its input role and ignores stale removal")
func inputOwnershipResumePreservesRole() {
    var policy = HostInputOwnership()
    let first = UUID(), resumed = UUID(), second = UUID()
    policy.add(first); policy.add(second)
    #expect(policy.replace(first, with: resumed) == true)
    #expect(policy.owner == resumed)
    #expect(policy.remove(first) == false)
    #expect(policy.owner == resumed)
    #expect(policy.remove(resumed) == true)
    #expect(policy.owner == second)
}

@Test("Only oversized IDRs at the floor trigger emergency detail loss, with measured recovery hysteresis")
func emergencyResolutionRequiresMeasuredPressure() {
    var policy = HostAdaptiveRatePolicy()
    for time in stride(from: 0.0, through: 3.0, by: 0.5) { policy.congested(at: time) }
    #expect(policy.bitRate == 350_000)
    #expect(policy.maximumCaptureWidth == nil)
    #expect(policy.oversizedKeyFrame(encodedWidth: 960, at: 4) == false)
    #expect(policy.maximumCaptureWidth == 640)
    #expect(policy.oversizedKeyFrame(encodedWidth: 640, at: 4.6) == false)
    #expect(policy.maximumCaptureWidth == 320)
    #expect(policy.oversizedKeyFrame(encodedWidth: 960, at: 4.8) == false)
    #expect(policy.oversizedKeyFrame(encodedWidth: 320, at: 4.9) == true)
    policy.admittedKeyFrame(bytes: 40_000, at: 5)
    policy.acknowledged(deliveryAge: 0.05, queueAge: 0, ceiling: 350_000, at: 30)
    #expect(policy.maximumCaptureWidth == 320)
    policy.admittedKeyFrame(bytes: 5_000, at: 31)
    policy.acknowledged(deliveryAge: 0.05, queueAge: 0, ceiling: 350_000, at: 40)
    #expect(policy.maximumCaptureWidth == 320)
    policy.acknowledged(deliveryAge: 0.05, queueAge: 0, ceiling: 350_000, at: 46)
    #expect(policy.maximumCaptureWidth == 640)
    let emergency = HostStreamQualityConfiguration(quality: .best, availableBitRate: 350_000,
                                                   maximumCaptureWidth: 320)
    #expect(emergency.maximumWidth == 320)
    #expect(emergency.maximumHeight == 180)
    #expect(emergency.framesPerSecond == 6)
}
