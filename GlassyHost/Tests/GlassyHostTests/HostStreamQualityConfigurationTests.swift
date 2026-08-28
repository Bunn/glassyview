import Testing
@testable import GlassyHost

@Test("Stream quality presets map to capture and encoder limits")
func streamQualityPresetConfiguration() {
    let expectations: [(
        quality: HostProtocol.StreamQuality,
        maximumWidth: Int,
        maximumHeight: Int,
        framesPerSecond: Int,
        averageBitRate: Int
    )] = [
        (.dataSaver, 1_280, 720, 15, 2_000_000),
        (.balanced, 1_920, 1_080, 30, 5_000_000),
        (.best, 3_840, 2_160, 60, 12_000_000)
    ]

    for expected in expectations {
        let configuration = HostStreamQualityConfiguration(
            quality: expected.quality
        )
        let capture = configuration.screenCaptureConfiguration
        let encoder = configuration.encoderConfiguration

        #expect(configuration.maximumWidth == expected.maximumWidth)
        #expect(configuration.maximumHeight == expected.maximumHeight)
        #expect(configuration.framesPerSecond == expected.framesPerSecond)
        #expect(configuration.averageBitRate == expected.averageBitRate)
        #expect(capture.maximumWidth == expected.maximumWidth)
        #expect(capture.maximumHeight == expected.maximumHeight)
        #expect(capture.framesPerSecond == expected.framesPerSecond)
        #expect(capture.showsCursor)
        #expect(encoder.expectedFrameRate == expected.framesPerSecond)
        #expect(encoder.averageBitRate == expected.averageBitRate)
        #expect(encoder.keyFrameIntervalSeconds == 2)
    }
}

@Test("Stream quality update policy applies downgrades and defers upgrades")
func streamQualityUpdatePolicy() {
    #expect(
        HostStreamQualityUpdatePolicy.decision(
            currentQuality: .dataSaver,
            requestedQuality: .best,
            hasPipeline: false,
            authenticatedClientCount: 1,
            isOnDemandGrace: false
        ) == .applyImmediately
    )
    #expect(
        HostStreamQualityUpdatePolicy.decision(
            currentQuality: .best,
            requestedQuality: .balanced,
            hasPipeline: true,
            authenticatedClientCount: 1,
            isOnDemandGrace: false
        ) == .applyImmediately
    )
    #expect(
        HostStreamQualityUpdatePolicy.decision(
            currentQuality: .dataSaver,
            requestedQuality: .best,
            hasPipeline: true,
            authenticatedClientCount: 1,
            isOnDemandGrace: false
        ) == .debounceUpgrade
    )
    #expect(
        HostStreamQualityUpdatePolicy.decision(
            currentQuality: .dataSaver,
            requestedQuality: .best,
            hasPipeline: true,
            authenticatedClientCount: 0,
            isOnDemandGrace: true
        ) == .holdUpgrade
    )
}

@Test("Initial on-demand starts coalesce without delaying manual or active capture")
func initialOnDemandStartPolicy() {
    #expect(
        HostInitialOnDemandStartPolicy.decision(
            ownership: .onDemand,
            hasPipeline: false,
            authenticatedClientCount: 1
        ) == .coalesce
    )
    #expect(
        HostInitialOnDemandStartPolicy.decision(
            ownership: .onDemand,
            hasPipeline: false,
            authenticatedClientCount: 0
        ) == .waitForViewer
    )
    #expect(
        HostInitialOnDemandStartPolicy.decision(
            ownership: .manual,
            hasPipeline: false,
            authenticatedClientCount: 1
        ) == .doNotDelay
    )
    #expect(
        HostInitialOnDemandStartPolicy.decision(
            ownership: .onDemand,
            hasPipeline: true,
            authenticatedClientCount: 1
        ) == .doNotDelay
    )
}

@Test("Pipeline generations reject callbacks from retiring encoders")
func pipelineGenerationTracking() {
    var tracker = HostPipelineGenerationTracker()
    let retiringGeneration = tracker.begin()
    #expect(tracker.isCurrent(retiringGeneration))

    tracker.invalidate()
    #expect(!tracker.isCurrent(retiringGeneration))

    let replacementGeneration = tracker.begin()
    #expect(tracker.isCurrent(replacementGeneration))
    #expect(!tracker.isCurrent(retiringGeneration))

    tracker.invalidate(retiringGeneration)
    #expect(tracker.isCurrent(replacementGeneration))
}

@Test("Reentrant pipeline reconciliation requests stay with one owner")
func pipelineReconciliationCoalescesReentrantRequests() {
    var state = HostPipelineReconciliationState()

    let acquiredInitialOwnership = state.request()
    #expect(acquiredInitialOwnership)
    #expect(state.hasOwner)
    state.beginPass()

    // Simulates an authentication or quality callback arriving while the
    // owner's transition is suspended.
    let reentrantCallerAcquiredOwnership = state.request()
    #expect(!reentrantCallerAcquiredOwnership)
    #expect(state.hasPendingRequest)
    #expect(state.shouldContinue(isReconciled: true))

    state.beginPass()
    #expect(!state.hasPendingRequest)
    #expect(!state.shouldContinue(isReconciled: true))

    state.release()
    #expect(!state.hasOwner)
    let reacquiredOwnership = state.request()
    #expect(reacquiredOwnership)
}

@Test("Pipeline reconciliation keeps ownership until state matches demand")
func pipelineReconciliationDrainsStateMismatch() {
    var state = HostPipelineReconciliationState()

    let acquiredOwnership = state.request()
    #expect(acquiredOwnership)
    state.beginPass()
    #expect(state.shouldContinue(isReconciled: false))

    state.beginPass()
    #expect(!state.shouldContinue(isReconciled: true))
    state.release()
}

@Test("Pipeline recovery uses capped exponential backoff")
func pipelineRetryBackoff() {
    #expect(HostPipelineRetryPolicy.delay(forAttempt: 1) == .milliseconds(250))
    #expect(HostPipelineRetryPolicy.delay(forAttempt: 2) == .milliseconds(500))
    #expect(HostPipelineRetryPolicy.delay(forAttempt: 3) == .seconds(1))
    #expect(HostPipelineRetryPolicy.delay(forAttempt: 4) == .seconds(2))
    #expect(HostPipelineRetryPolicy.delay(forAttempt: 5) == .seconds(4))
    #expect(HostPipelineRetryPolicy.delay(forAttempt: 50) == .seconds(4))
}
