import Testing
@testable import GlassyDesk

struct GlassyStreamCursorReconcilerTests {
    private let now = ContinuousClock().now

    @Test
    func staleTelemetryCannotRewindLatestLocalTarget() {
        var reconciler = GlassyStreamCursorReconciler()
        let start = position(10_000)
        let firstLocalTarget = position(20_000)
        let secondLocalTarget = position(30_000)

        let acceptedStart = reconciler.receiveRemotePosition(start, at: now)
        #expect(acceptedStart)

        reconciler.recordLocalPosition(firstLocalTarget, at: now)
        let acceptedFirstStaleSample = reconciler.receiveRemotePosition(
            position(12_000),
            at: now.advanced(by: .seconds(1))
        )
        #expect(!acceptedFirstStaleSample)
        #expect(reconciler.preferredPosition == firstLocalTarget)

        reconciler.recordLocalPosition(
            secondLocalTarget,
            at: now.advanced(by: .seconds(2))
        )
        let acceptedOldTarget = reconciler.receiveRemotePosition(
            firstLocalTarget,
            at: now.advanced(by: .seconds(3))
        )
        #expect(!acceptedOldTarget)
        #expect(reconciler.preferredPosition == secondLocalTarget)
    }

    @Test
    func matchingCoordinatesCannotFalselyAcknowledgeReversal() {
        var reconciler = GlassyStreamCursorReconciler()
        let startingPosition = position(10_000)
        let intermediateTarget = position(20_000)

        _ = reconciler.receiveRemotePosition(startingPosition, at: now)
        reconciler.recordLocalPosition(intermediateTarget, at: now)

        // Reversing to a previously reported coordinate is a new local command,
        // not proof that the host has caught up to it.
        reconciler.recordLocalPosition(
            startingPosition,
            at: now.advanced(by: .seconds(1))
        )
        let acceptedSameCoordinate = reconciler.receiveRemotePosition(
            startingPosition,
            at: now.advanced(by: .seconds(2))
        )
        #expect(!acceptedSameCoordinate)
        #expect(reconciler.pendingLocalPosition == startingPosition)

        let acceptedIntermediateEcho = reconciler.receiveRemotePosition(
            intermediateTarget,
            at: now.advanced(by: .seconds(3))
        )
        #expect(!acceptedIntermediateEcho)
        #expect(reconciler.preferredPosition == startingPosition)
    }

    @Test
    func everyLocalMoveExtendsAuthorityWindow() {
        var reconciler = GlassyStreamCursorReconciler()
        reconciler.recordLocalPosition(position(20_000), at: now)
        reconciler.recordLocalPosition(
            position(30_000),
            at: now.advanced(by: .seconds(4))
        )

        let acceptedFromOriginalDeadline = reconciler.receiveRemotePosition(
            position(10_000),
            at: now.advanced(by: .seconds(6))
        )
        #expect(!acceptedFromOriginalDeadline)
        #expect(reconciler.preferredPosition == position(30_000))
    }

    @Test
    func hostTelemetryIsAcceptedWithoutOutstandingLocalInput() {
        var reconciler = GlassyStreamCursorReconciler()
        let remotePosition = position(25_000)

        let accepted = reconciler.receiveRemotePosition(remotePosition, at: now)
        #expect(accepted)
        #expect(reconciler.preferredPosition == remotePosition)
    }

    @Test
    func remoteControlResumesAfterLocalAuthorityExpires() {
        var reconciler = GlassyStreamCursorReconciler()
        _ = reconciler.receiveRemotePosition(position(10_000), at: now)
        reconciler.recordLocalPosition(position(20_000), at: now)

        let acceptedEarlyRemoteMovement = reconciler.receiveRemotePosition(
            position(30_000),
            at: now.advanced(by: .seconds(4))
        )
        #expect(!acceptedEarlyRemoteMovement)

        let acceptedLaterRemoteMovement = reconciler.receiveRemotePosition(
            position(31_000),
            at: now.advanced(by: .seconds(6))
        )
        #expect(acceptedLaterRemoteMovement)
        #expect(reconciler.pendingLocalPosition == nil)
        #expect(reconciler.preferredPosition == position(31_000))
    }

    @Test
    func deadlineDiscardsAmbiguousDeferredSampleWhenHostStopsMoving() {
        var reconciler = GlassyStreamCursorReconciler()
        let localTarget = position(20_000)
        reconciler.recordLocalPosition(localTarget, at: now)
        let accepted = reconciler.receiveRemotePosition(
            position(21_000),
            at: now.advanced(by: .seconds(4))
        )
        #expect(!accepted)

        // Merely reaching the deadline cannot make the known-ambiguous sample
        // authoritative; it remains ignored until a new sample arrives.
        #expect(reconciler.pendingLocalPosition == localTarget)
        #expect(reconciler.preferredPosition == localTarget)

        let acceptedFreshSample = reconciler.receiveRemotePosition(
            position(22_000),
            at: now.advanced(by: .seconds(6))
        )
        #expect(acceptedFreshSample)
        #expect(reconciler.preferredPosition == position(22_000))
    }

    @Test
    func resetClearsRemoteAndLocalState() {
        var reconciler = GlassyStreamCursorReconciler()
        _ = reconciler.receiveRemotePosition(position(10_000), at: now)
        reconciler.recordLocalPosition(position(20_000), at: now)

        reconciler.reset()

        #expect(reconciler.latestRemotePosition == nil)
        #expect(reconciler.pendingLocalPosition == nil)
        #expect(reconciler.preferredPosition == nil)
    }

    private func position(_ value: UInt16) -> GlassyStreamCursorPosition {
        GlassyStreamCursorPosition(x: value, y: value)
    }
}
