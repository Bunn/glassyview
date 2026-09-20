import CoreGraphics
import Testing
@testable import GlassyDesk

struct RemoteViewportGeometryTests {
    @Test(arguments: [
        CGSize(width: 390, height: 844),
        CGSize(width: 678, height: 466),
        CGSize(width: 951, height: 669),
        CGSize(width: 669, height: 951),
        CGSize(width: 320, height: 669),
        CGSize(width: 1_024, height: 1_366),
        CGSize(width: 1_366, height: 1_024),
        CGSize(width: 951, height: 260)
    ])
    func fittedDesktopRemainsEntirelyVisibleForLocalAspectRatios(viewportSize: CGSize) {
        let contentSize = CGSize(width: 2_560, height: 1_440)
        let scale = min(viewportSize.width / contentSize.width,
                        viewportSize.height / contentSize.height)
        // A nonzero local origin also models asymmetric container placement.
        let bounds = CGRect(origin: CGPoint(x: 43, y: 19), size: viewportSize)
        let frame = RemoteViewportGeometry.contentFrame(contentSize: contentSize,
                                                        viewportBounds: bounds,
                                                        effectiveScale: scale,
                                                        center: CGPoint(x: 2_000, y: 300))

        #expect(frame.minX >= bounds.minX - 0.001)
        #expect(frame.maxX <= bounds.maxX + 0.001)
        #expect(frame.minY >= bounds.minY - 0.001)
        #expect(frame.maxY <= bounds.maxY + 0.001)
        #expect(abs(frame.midX - bounds.midX) < 0.001)
        #expect(abs(frame.midY - bounds.midY) < 0.001)
    }

    @Test
    func zoomedDesktopCoversViewportAtEveryClampedEdge() {
        let bounds = CGRect(x: 23, y: 17, width: 500, height: 300)
        for center in [CGPoint(x: -100, y: -100), CGPoint(x: 10_000, y: 10_000)] {
            let frame = RemoteViewportGeometry.contentFrame(contentSize: CGSize(width: 1_600, height: 900),
                                                            viewportBounds: bounds,
                                                            effectiveScale: 1,
                                                            center: center)
            #expect(frame.contains(bounds))
        }
    }

    @Test
    func hitTestingUsesRenderedFrameAndRemoteDisplayOrigin() {
        let frame = CGRect(x: -150, y: 70, width: 800, height: 450)
        let source = CGRect(x: 1_920, y: 160, width: 1_600, height: 900)
        let point = RemoteViewportGeometry.framebufferPoint(for: CGPoint(x: 250, y: 295),
                                                            contentFrame: frame, sourceFrame: source)
        #expect(point == CGPoint(x: 2_720, y: 610))
        #expect(RemoteViewportGeometry.framebufferPoint(for: CGPoint(x: 250, y: 69),
                                                       contentFrame: frame, sourceFrame: source) == nil)
    }

    @Test
    func emptyResizeCannotProduceInvalidFramesOrInput() {
        let contentSize = CGSize(width: 1_600, height: 900)
        #expect(RemoteViewportGeometry.contentFrame(contentSize: contentSize,
                                                    viewportBounds: .zero, effectiveScale: 1,
                                                    center: .zero) == .zero)
        #expect(RemoteViewportGeometry.framebufferPoint(for: .zero, contentFrame: .zero,
                                                       sourceFrame: CGRect(origin: .zero, size: contentSize)) == nil)
    }

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
