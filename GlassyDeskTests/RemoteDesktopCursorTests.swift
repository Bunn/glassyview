import CoreGraphics
import RoyalVNCKit
import Testing
@testable import GlassyDesk

@MainActor
struct RemoteDesktopCursorTests {
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
        touchMode: RemoteTouchMode
    ) throws -> (
        RemoteDesktopView<VNCSession>.ScreenView,
        CGImage,
        TestSession
    ) {
        let session = TestSession(
            touchMode: touchMode,
            cursorLocation: CGPoint(x: 1_280, y: 720)
        )
        let view = RemoteDesktopView<VNCSession>.ScreenView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
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
                imageSize: CGSize(width: 2_560, height: 1_440),
                dirtyRect: nil
            )
        )
        view.layoutIfNeeded()
        view.display(cursor: nil)

        return (view, image, session)
    }

    private final class TestSession: RemoteSessionInputControlling {
        var touchMode: RemoteTouchMode
        var cursorLocation: CGPoint

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
        func scroll(_ direction: RemoteScrollDirection, steps: UInt32) {}
        func pressAtCursor() {}
        func releaseAtCursor() {}
        func setModifier(_ modifier: RemoteModifierKey, isPressed: Bool) {}
        func releaseHeldModifiers() {}
        func sendText(_ text: String, modifiers: [VNCKeyCode]) {}
        func sendKey(_ keyCode: VNCKeyCode, modifiers: [VNCKeyCode]) {}
        func sendReturn() {}
    }
}
