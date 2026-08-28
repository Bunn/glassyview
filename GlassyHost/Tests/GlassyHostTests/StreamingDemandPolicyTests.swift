import Testing
@testable import GlassyHost

@Test("The first authenticated viewer starts capture on demand")
func firstAuthenticatedViewerStartsOnDemandCapture() {
    var policy = StreamingDemandPolicy()

    #expect(policy.authenticatedClientCountChanged(to: 0).isEmpty)
    #expect(
        policy.authenticatedClientCountChanged(to: 1)
            == [.cancelOnDemandStop, .startCapture(.onDemand)]
    )
    #expect(policy.ownership == .onDemand)
    #expect(policy.wantsCapture)

    #expect(policy.authenticatedClientCountChanged(to: 2).isEmpty)
}

@Test("The last authenticated viewer schedules an on-demand stop")
func lastAuthenticatedViewerSchedulesStop() {
    var policy = StreamingDemandPolicy()
    _ = policy.authenticatedClientCountChanged(to: 1)

    #expect(
        policy.authenticatedClientCountChanged(to: 0)
            == [.scheduleOnDemandStop]
    )
    #expect(policy.onDemandStopGraceExpired() == [.stopCapture])
    #expect(!policy.wantsCapture)
}

@Test("A reconnect during grace keeps on-demand capture alive")
func reconnectCancelsOnDemandStop() {
    var policy = StreamingDemandPolicy()
    _ = policy.authenticatedClientCountChanged(to: 1)
    _ = policy.authenticatedClientCountChanged(to: 0)

    #expect(
        policy.authenticatedClientCountChanged(to: 1)
            == [.cancelOnDemandStop]
    )
    #expect(policy.onDemandStopGraceExpired().isEmpty)
    #expect(policy.ownership == .onDemand)
}

@Test("Manual capture stays active after the last viewer leaves")
func manualCaptureIgnoresViewerDisconnect() {
    var policy = StreamingDemandPolicy()
    #expect(
        policy.requestManualStart()
            == [.cancelOnDemandStop, .startCapture(.manual)]
    )
    _ = policy.authenticatedClientCountChanged(to: 1)

    #expect(policy.authenticatedClientCountChanged(to: 0).isEmpty)
    #expect(policy.onDemandStopGraceExpired().isEmpty)
    #expect(policy.ownership == .manual)
}

@Test("An on-demand stream can be promoted to manual always-on capture")
func onDemandCaptureCanBecomeManual() {
    var policy = StreamingDemandPolicy()
    _ = policy.authenticatedClientCountChanged(to: 1)

    #expect(policy.requestManualStart() == [.cancelOnDemandStop])
    #expect(policy.ownership == .manual)
    #expect(policy.authenticatedClientCountChanged(to: 0).isEmpty)
}

@Test("Manual stop suppresses restart while current viewers remain")
func manualStopSuppressesImmediateDemandRestart() {
    var policy = StreamingDemandPolicy()
    _ = policy.authenticatedClientCountChanged(to: 1)

    #expect(
        policy.requestManualStop()
            == [.cancelOnDemandStop, .stopCapture]
    )
    #expect(policy.authenticatedClientCountChanged(to: 2).isEmpty)
    #expect(!policy.wantsCapture)

    _ = policy.authenticatedClientCountChanged(to: 0)
    #expect(
        policy.authenticatedClientCountChanged(to: 1)
            == [.cancelOnDemandStop, .startCapture(.onDemand)]
    )
}

@Test("A failed capture start clears pending demand")
func failedStartClearsDemand() {
    var policy = StreamingDemandPolicy()
    _ = policy.authenticatedClientCountChanged(to: 1)

    #expect(policy.captureStartFailed() == [.cancelOnDemandStop])
    #expect(!policy.wantsCapture)
}

@Test("A retryable capture failure keeps authenticated demand alive")
func retryableFailurePreservesAuthenticatedDemand() {
    var policy = StreamingDemandPolicy()
    _ = policy.authenticatedClientCountChanged(to: 1)

    let effects = policy.captureStartFailed(isRetryable: true)
    #expect(effects == [.cancelOnDemandStop])
    #expect(policy.ownership == .onDemand)
    #expect(policy.wantsCapture)
}

@Test("A retryable failure keeps manual ownership but not stale on-demand ownership")
func retryableFailureRequiresCurrentDemand() {
    var manualPolicy = StreamingDemandPolicy()
    _ = manualPolicy.requestManualStart()
    let manualEffects = manualPolicy.captureStartFailed(isRetryable: true)
    #expect(manualEffects == [.cancelOnDemandStop])
    #expect(manualPolicy.ownership == .manual)

    var staleOnDemandPolicy = StreamingDemandPolicy()
    _ = staleOnDemandPolicy.authenticatedClientCountChanged(to: 1)
    _ = staleOnDemandPolicy.authenticatedClientCountChanged(to: 0)
    let staleOnDemandEffects = staleOnDemandPolicy.captureStartFailed(
        isRetryable: true
    )
    #expect(staleOnDemandEffects == [.cancelOnDemandStop])
    #expect(!staleOnDemandPolicy.wantsCapture)
}

@Test("Manual stop still wins while a failed manual pipeline is retryable")
func manualStopCancelsRetryableManualDemand() {
    var policy = StreamingDemandPolicy()
    _ = policy.authenticatedClientCountChanged(to: 1)
    _ = policy.requestManualStart()
    _ = policy.captureStartFailed(isRetryable: true)

    let stopEffects = policy.requestManualStop()
    #expect(stopEffects == [.cancelOnDemandStop, .stopCapture])
    #expect(!policy.wantsCapture)
    let additionalViewerEffects = policy.authenticatedClientCountChanged(to: 2)
    #expect(additionalViewerEffects.isEmpty)
}
