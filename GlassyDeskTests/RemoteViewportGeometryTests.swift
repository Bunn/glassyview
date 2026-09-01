import Testing
@testable import GlassyDesk

struct RemoteViewportGeometryTests {
    @Test
    func keyboardAvoidanceForcesViewportPanWhenContentOverflows() {
        let intent = RemoteViewportGeometry.gestureIntent(
            pannableAxes: [.vertical],
            pansViewportWithTwoFingers: false,
            forcesViewportPan: true
        )

        #expect(intent == .viewportPan)
    }

    @Test
    func keyboardAvoidanceKeepsRemoteScrollWhenContentFits() {
        let intent = RemoteViewportGeometry.gestureIntent(
            pannableAxes: [],
            pansViewportWithTwoFingers: false,
            forcesViewportPan: true
        )

        #expect(intent == .remoteScroll)
    }

    @Test
    func defaultTwoFingerGestureStillScrollsRemote() {
        let intent = RemoteViewportGeometry.gestureIntent(
            pannableAxes: [.vertical],
            pansViewportWithTwoFingers: false
        )

        #expect(intent == .remoteScroll)
    }

    @Test
    func panViewPreferenceStillPansViewport() {
        let intent = RemoteViewportGeometry.gestureIntent(
            pannableAxes: [.vertical],
            pansViewportWithTwoFingers: true
        )

        #expect(intent == .viewportPan)
    }
}
