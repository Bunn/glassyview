import CoreGraphics
import RoyalVNCKit
import Testing
import UIKit
@testable import GlassyDesk

@MainActor
struct RemoteDesktopCursorTests {
    @Test
    func keyboardViewportResizePreservesApparentScale() throws {
        let initialFrame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        let (view, _, session) = try makeView(
            touchMode: .direct,
            frame: initialFrame,
            imageSize: CGSize(width: 1_000, height: 1_000)
        )
        let window = try makeWindow(frame: initialFrame)
        window.addSubview(view)
        view.setFitsContentToWindow(true)
        view.layoutIfNeeded()
        let framebufferSize = view.debugFramebufferFrame.size

        view.frame = CGRect(x: 0, y: 0, width: 1_024, height: 700)
        view.layoutIfNeeded()

        #expect(framebufferSize == CGSize(width: 1_024, height: 1_024))
        #expect(view.debugFramebufferFrame.size == framebufferSize)
        #expect(view.debugZoomScale == 1)
        withExtendedLifetime((window, session)) {}
    }

    @Test
    func keyboardViewportCanZoomOutUntilEntireContentIsVisible() throws {
        let (view, window, session) = try makeKeyboardConstrainedView()

        view.setKeyboardAvoidanceActive(true)
        view.setZoomScale(0.1, notify: false)

        let expectedMinimum: CGFloat = 700.0 / 1_024.0
        #expect(abs(view.debugMinimumZoomScale - expectedMinimum) < 0.001)
        #expect(abs(view.debugZoomScale - expectedMinimum) < 0.001)
        #expect(abs(view.debugFramebufferFrame.width - 700) < 0.001)
        #expect(abs(view.debugFramebufferFrame.height - 700) < 0.001)
        #expect(abs(view.debugFramebufferFrame.minY) < 0.001)
        #expect(abs(view.debugFramebufferFrame.maxY - view.bounds.maxY) < 0.001)
        withExtendedLifetime((window, session)) {}
    }

    @Test
    func keyboardFitZoomUsesTheTighterViewportAxis() throws {
        let (view, window, session) = try makeKeyboardConstrainedView(
            imageSize: CGSize(width: 1_600, height: 900),
            constrainedSize: CGSize(width: 800, height: 500)
        )

        view.setKeyboardAvoidanceActive(true)
        view.setZoomScale(0.1, notify: false)

        let expectedMinimum: CGFloat = 800.0 / 1_024.0
        #expect(abs(view.debugMinimumZoomScale - expectedMinimum) < 0.001)
        #expect(abs(view.debugFramebufferFrame.width - 800) < 0.001)
        #expect(abs(view.debugFramebufferFrame.height - 450) < 0.001)
        #expect(view.debugFramebufferFrame.minX >= 0)
        #expect(view.debugFramebufferFrame.maxX <= view.bounds.maxX)
        #expect(view.debugFramebufferFrame.minY >= 0)
        #expect(view.debugFramebufferFrame.maxY <= view.bounds.maxY)
        withExtendedLifetime((window, session)) {}
    }

    @Test
    func keyboardFitZoomReconcilesWhenTheViewportGrows() throws {
        let (view, window, session) = try makeKeyboardConstrainedView()
        view.setKeyboardAvoidanceActive(true)
        view.setZoomScale(0.1, notify: false)

        view.frame = CGRect(x: 0, y: 0, width: 1_024, height: 900)
        view.layoutIfNeeded()

        let expectedMinimum: CGFloat = 900.0 / 1_024.0
        #expect(abs(view.debugMinimumZoomScale - expectedMinimum) < 0.001)
        #expect(abs(view.debugZoomScale - expectedMinimum) < 0.001)
        #expect(abs(view.debugFramebufferFrame.height - 900) < 0.001)
        withExtendedLifetime((window, session)) {}
    }

    @Test
    func keyboardViewportUsesTwoFingerTouchPanAtMinimumZoom() throws {
        let (view, window, session) = try makeKeyboardConstrainedView()
        let centeredFrame = view.debugFramebufferFrame

        view.setKeyboardAvoidanceActive(true)
        view.debugRouteTwoFingerTouchPan(by: CGPoint(x: 0, y: -1_000))
        let pannedFrame = view.debugFramebufferFrame
        view.setZoomScale(1, notify: false)

        #expect(view.debugZoomScale == 1)
        #expect(pannedFrame.minY < centeredFrame.minY)
        #expect(abs(pannedFrame.maxY - view.bounds.maxY) < 0.001)
        #expect(view.debugFramebufferFrame == pannedFrame)
        #expect(session.scrollCallCount == 0)
        withExtendedLifetime((window, session)) {}
    }

    @Test
    func manualKeyboardPanCanRevealTopWhileCursorFollowingIsEnabled() throws {
        let (view, window, session) = try makeKeyboardConstrainedView(
            constrainedSize: CGSize(width: 1_024, height: 276),
            cursorLocation: CGPoint(x: 500, y: 500)
        )
        let centeredFrame = view.debugFramebufferFrame

        view.setFollowsCursor(true)
        view.setKeyboardAvoidanceActive(true)
        view.debugRouteTwoFingerTouchPan(by: CGPoint(x: 0, y: 1_000))
        view.setNeedsLayout()
        view.layoutIfNeeded()

        #expect(centeredFrame.minY < 0)
        #expect(abs(view.debugFramebufferFrame.minY) < 0.001)
        #expect(view.debugFramebufferFrame.maxY > view.bounds.maxY)
        #expect(session.scrollCallCount == 0)
        withExtendedLifetime((window, session)) {}
    }

    @Test
    func cursorFollowingResumesAfterManualKeyboardPanWhenCursorMovesOutward() throws {
        let (view, window, session) = try makeKeyboardConstrainedView(
            constrainedSize: CGSize(width: 1_024, height: 276),
            cursorLocation: CGPoint(x: 500, y: 500)
        )

        view.setFollowsCursor(true)
        view.setKeyboardAvoidanceActive(true)
        view.debugRouteTwoFingerTouchPan(by: CGPoint(x: 0, y: 1_000))
        let manuallyPannedFrame = view.debugFramebufferFrame

        session.cursorLocation = CGPoint(x: 500, y: 900)
        view.display(cursorLocation: session.cursorLocation)

        #expect(abs(manuallyPannedFrame.minY) < 0.001)
        #expect(view.debugFramebufferFrame.minY < manuallyPannedFrame.minY)
        withExtendedLifetime((window, session)) {}
    }

    @Test
    func manualViewportPositionClearsWhenExpandedViewportFitsContent() throws {
        let (view, window, session) = try makeKeyboardConstrainedView(
            constrainedSize: CGSize(width: 1_024, height: 276),
            cursorLocation: CGPoint(x: 500, y: 500)
        )

        view.setKeyboardAvoidanceActive(true)
        view.debugRouteTwoFingerTouchPan(by: CGPoint(x: 0, y: 1_000))
        #expect(view.debugManualViewportPositionActive)

        view.setKeyboardAvoidanceActive(false)
        view.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        view.layoutIfNeeded()

        #expect(!view.debugManualViewportPositionActive)
        withExtendedLifetime((window, session)) {}
    }

    @Test
    func keyboardViewportUsesContinuousPointerPanAtMinimumZoom() throws {
        let (view, window, session) = try makeKeyboardConstrainedView()
        let centeredFrame = view.debugFramebufferFrame

        view.setKeyboardAvoidanceActive(true)
        view.debugRouteContinuousPointerPan(by: CGPoint(x: 0, y: -1_000))

        #expect(view.debugZoomScale == 1)
        #expect(view.debugFramebufferFrame.minY < centeredFrame.minY)
        #expect(abs(view.debugFramebufferFrame.maxY - view.bounds.maxY) < 0.001)
        #expect(session.scrollCallCount == 0)
        withExtendedLifetime((window, session)) {}
    }

    @Test
    func twoFingerTouchStillScrollsRemoteWithoutKeyboardAvoidance() throws {
        let (view, window, session) = try makeKeyboardConstrainedView()
        let centeredFrame = view.debugFramebufferFrame

        view.debugRouteTwoFingerTouchPan(by: CGPoint(x: 0, y: -1_000))

        #expect(view.debugFramebufferFrame == centeredFrame)
        #expect(session.scrollCallCount == 1)
        withExtendedLifetime((window, session)) {}
    }

    @Test
    func discretePointerWheelStillScrollsRemoteDuringKeyboardAvoidance() throws {
        let (view, window, session) = try makeKeyboardConstrainedView()
        let centeredFrame = view.debugFramebufferFrame

        view.setKeyboardAvoidanceActive(true)
        view.debugRouteDiscretePointerWheel(by: CGPoint(x: 0, y: -1_000))

        #expect(view.debugFramebufferFrame == centeredFrame)
        #expect(session.scrollCallCount == 1)
        withExtendedLifetime((window, session)) {}
    }

    @Test
    func trackpadDotIsHiddenByDefaultWhenServerDoesNotProvideCursorShape() throws {
        let (view, _, session) = try makeView(touchMode: .trackpad)

        #expect(!view.debugCursorIsVisible)
        #expect(!view.debugUsesFallbackCursor)
        #expect(view.debugCursorFrame == .zero)
        withExtendedLifetime(session) {}
    }

    @Test
    func trackpadDotCanBeEnabledAtReducedSize() throws {
        let (view, _, session) = try makeView(touchMode: .trackpad)

        view.setShowsTrackpadCursorDot(true)

        #expect(view.debugCursorIsVisible)
        #expect(view.debugUsesFallbackCursor)
        #expect(view.debugCursorFrame.size == CGSize(width: 12, height: 12))
        withExtendedLifetime(session) {}
    }

    @Test
    func hostCursorTakesPriorityOverEnabledTrackpadDot() throws {
        let (view, image, session) = try makeView(touchMode: .trackpad)

        view.setShowsTrackpadCursorDot(true)
        #expect(view.debugUsesFallbackCursor)

        view.display(
            cursor: RemoteCursor(
                image: image,
                hotspot: CGPoint(x: 2, y: 2),
                size: CGSize(width: 32, height: 32)
            )
        )

        #expect(view.debugCursorIsVisible)
        #expect(!view.debugUsesFallbackCursor)
        #expect(view.debugCursorFrame.width >= 24)
        #expect(view.debugCursorFrame.height >= 24)

        view.display(cursor: nil)
        #expect(view.debugUsesFallbackCursor)
        #expect(view.debugCursorFrame.size == CGSize(width: 12, height: 12))
        withExtendedLifetime(session) {}
    }

    @Test
    func cursorOverlayCanStayHiddenOnExternalControllerTrackpad() throws {
        let (view, _, session) = try makeView(touchMode: .trackpad)

        view.setShowsTrackpadCursorDot(true)
        #expect(view.debugCursorIsVisible)

        view.setShowsCursorOverlay(false)

        #expect(!view.debugCursorIsVisible)
        #expect(view.debugCursorFrame == .zero)
        withExtendedLifetime(session) {}
    }

    @Test
    func enabledTrackpadDotDoesNotAppearInDirectMode() throws {
        let (view, _, session) = try makeView(touchMode: .direct)

        view.setShowsTrackpadCursorDot(true)

        #expect(!view.debugCursorIsVisible)
        #expect(!view.debugUsesFallbackCursor)
        #expect(view.debugCursorFrame == .zero)
        withExtendedLifetime(session) {}
    }

    @Test
    func hostCursorRemainsVisibleWithoutPointerInput() throws {
        let (view, image, session) = try makeView(touchMode: .direct)

        view.setAcceptsPointerInput(false)
        view.setTouchModeOverride(.trackpad)
        view.display(
            cursor: RemoteCursor(
                image: image,
                hotspot: CGPoint(x: 2, y: 2),
                size: CGSize(width: 32, height: 32)
            )
        )

        #expect(view.debugCursorIsVisible)
        #expect(!view.debugUsesFallbackCursor)
        withExtendedLifetime(session) {}
    }

    private func makeView(
        touchMode: RemoteTouchMode,
        frame: CGRect = CGRect(x: 0, y: 0, width: 390, height: 844),
        imageSize: CGSize = CGSize(width: 2_560, height: 1_440),
        cursorLocation: CGPoint = CGPoint(x: 1_280, y: 720)
    ) throws -> (
        RemoteDesktopView<VNCSession>.ScreenView,
        CGImage,
        TestSession
    ) {
        let session = TestSession(
            touchMode: touchMode,
            cursorLocation: cursorLocation
        )
        let view = RemoteDesktopView<VNCSession>.ScreenView(
            frame: frame
        )
        view.session = session
        view.setTouchModeOverride(nil)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let image = try #require(context.makeImage())
        view.display(
            framebufferUpdate: RemoteFramebufferUpdate(
                image: image,
                imageSize: imageSize,
                dirtyRect: nil
            )
        )
        view.layoutIfNeeded()
        view.display(cursor: nil)

        return (view, image, session)
    }

    private func makeWindow(frame: CGRect) throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = frame
        return window
    }

    private func makeKeyboardConstrainedView(
        imageSize: CGSize = CGSize(width: 1_000, height: 1_000),
        constrainedSize: CGSize = CGSize(width: 1_024, height: 700),
        cursorLocation: CGPoint = CGPoint(x: 1_280, y: 720)
    ) throws -> (
        RemoteDesktopView<VNCSession>.ScreenView,
        UIWindow,
        TestSession
    ) {
        let initialFrame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        let (view, _, session) = try makeView(
            touchMode: .direct,
            frame: initialFrame,
            imageSize: imageSize,
            cursorLocation: cursorLocation
        )
        let window = try makeWindow(frame: initialFrame)
        window.addSubview(view)
        view.setFitsContentToWindow(true)
        view.frame = CGRect(origin: .zero, size: constrainedSize)
        view.layoutIfNeeded()
        return (view, window, session)
    }

    private final class TestSession: RemoteSessionInputControlling {
        var touchMode: RemoteTouchMode
        var cursorLocation: CGPoint
        private(set) var scrollCallCount = 0

        init(touchMode: RemoteTouchMode, cursorLocation: CGPoint) {
            self.touchMode = touchMode
            self.cursorLocation = cursorLocation
        }

        func leftButtonDown(at point: CGPoint) {}
        func leftButtonUp(at point: CGPoint) {}
        func moveCursor(by delta: CGPoint, dragging: Bool) {}
        func moveCursor(to point: CGPoint, dragging: Bool) {}
        func clickAtCursor() {}
        func rightClick(at point: CGPoint) {}
        func rightClickAtCursor() {}
        func scroll(_ direction: RemoteScrollDirection, steps: UInt32) {
            scrollCallCount += 1
        }
        func pressAtCursor() {}
        func releaseAtCursor() {}
        func setModifier(_ modifier: RemoteModifierKey, isPressed: Bool) {}
        func releaseHeldModifiers() {}
        func sendText(_ text: String, modifiers: [VNCKeyCode]) {}
        func sendKey(_ keyCode: VNCKeyCode, modifiers: [VNCKeyCode]) {}
        func sendReturn() {}
    }
}
