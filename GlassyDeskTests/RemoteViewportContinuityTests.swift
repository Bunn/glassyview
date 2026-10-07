import CoreGraphics
import RoyalVNCKit
import Testing
import UIKit
@testable import GlassyDesk

@MainActor
struct RemoteViewportContinuityTests {
    @Test
    func keyboardActivationRevealsCursorOnceWithoutOverridingLaterResizes() throws {
        let view = try makeView(size: CGSize(width: 400, height: 600),
                                imageSize: CGSize(width: 1_000, height: 1_000))
        let session = CursorSession(cursorLocation: CGPoint(x: 500, y: 950))
        view.session = session
        view.setFollowsCursor(true)
        view.setFittingViewportSize(CGSize(width: 400, height: 600))
        view.layoutIfNeeded()

        view.setKeyboardAvoidanceActive(true)
        view.frame.size.height = 200
        view.layoutIfNeeded()
        #expect(abs(view.debugFramebufferFrame.maxY - 200) < 0.001)

        // The keyboard's activation was handled. A subsequent resize uses the
        // same anchor instead of moving it again toward a stationary cursor.
        view.frame.size.height = 100
        view.layoutIfNeeded()
        #expect(abs(view.debugFramebufferFrame.maxY - 150) < 0.001)
        withExtendedLifetime(session) {}
    }

    @Test
    func panAnchorSurvivesWideShortAndEmptyIntermediateViewports() throws {
        let originalSize = CGSize(width: 500, height: 400)
        let view = try makeView(size: originalSize)
        view.setPansViewportWithTwoFingers(true)
        view.setZoomScale(2, notify: false)
        view.debugRouteTwoFingerTouchPan(by: CGPoint(x: -80, y: -25))
        let originalFrame = view.debugFramebufferFrame
        let originalCenter = view.debugFramebufferPoint(for: CGPoint(x: 250, y: 200))

        // At this shape the horizontal axis fits, but its remote anchor should
        // still be available when the user returns to the original shape.
        for size in [CGSize(width: 1_000, height: 250), .zero, originalSize] {
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutIfNeeded()
        }

        #expect(view.debugZoomScale == 2)
        #expect(view.debugFramebufferFrame == originalFrame)
        #expect(view.debugFramebufferPoint(for: CGPoint(x: 250, y: 200)) == originalCenter)
    }

    @Test
    func localUnobscuredPaneControlsFittingAndKeyboardZoom() throws {
        let view = try makeView(size: CGSize(width: 400, height: 600),
                                imageSize: CGSize(width: 1_000, height: 1_000))
        view.setFittingViewportSize(CGSize(width: 400, height: 600))
        view.layoutIfNeeded()

        view.setKeyboardAvoidanceActive(true)
        view.frame.size.height = 200
        view.layoutIfNeeded()
        #expect(view.debugFramebufferFrame.size == CGSize(width: 400, height: 400))

        view.setZoomScale(0.1, notify: false)
        #expect(view.debugMinimumZoomScale == 0.5)
        #expect(view.debugFramebufferFrame.size == CGSize(width: 200, height: 200))

        // Folding with the keyboard open updates the local fit, independently
        // of any surrounding window or another arrangement pane.
        view.setFittingViewportSize(CGSize(width: 600, height: 400))
        view.frame.size = CGSize(width: 600, height: 240)
        view.layoutIfNeeded()
        #expect(abs(view.debugZoomScale - 0.6) < 0.001)
        #expect(abs(view.debugFramebufferFrame.height - 240) < 0.001)
    }

    @Test
    func inputMappingTracksResizedSelectedDisplay() throws {
        let view = try makeView(size: CGSize(width: 500, height: 400),
                                imageSize: CGSize(width: 3_200, height: 900))
        view.setVisibleFramebufferFrame(CGRect(x: 1_600, y: 0, width: 1_600, height: 900))
        view.setZoomScale(2, notify: false)

        for size in [CGSize(width: 669, height: 951), CGSize(width: 951, height: 669),
                     CGSize(width: 320, height: 460), CGSize(width: 1_024, height: 768)] {
            view.frame.size = size
            view.layoutIfNeeded()
            let rendered = view.debugFramebufferFrame
            let point = CGPoint(x: rendered.midX, y: rendered.midY)
            #expect(view.debugFramebufferPoint(for: point) == CGPoint(x: 2_400, y: 450))
        }
    }

    @Test
    func hostResolutionChangePreservesRelativePanAnchor() throws {
        let view = try makeView(size: CGSize(width: 500, height: 400))
        view.setZoomScale(2, notify: false)
        view.setPansViewportWithTwoFingers(true)
        view.debugRouteTwoFingerTouchPan(by: CGPoint(x: -80, y: -25))
        let originalFrame = view.debugFramebufferFrame

        // Flush through the normal selected-frame setter so frame throttling
        // does not make the assertion depend on a display-link tick.
        view.display(framebufferUpdate: try makeUpdate(imageSize: CGSize(width: 3_200, height: 1_800)))
        view.setVisibleFramebufferFrame(nil)
        view.layoutIfNeeded()

        #expect(view.debugZoomScale == 2)
        let resizedFrame = view.debugFramebufferFrame
        // Normalizing a remote anchor can introduce subpixel floating-point
        // rounding even when the visible content stays in the same place.
        #expect(abs(resizedFrame.minX - originalFrame.minX) < 0.001)
        #expect(abs(resizedFrame.minY - originalFrame.minY) < 0.001)
        #expect(abs(resizedFrame.width - originalFrame.width) < 0.001)
        #expect(abs(resizedFrame.height - originalFrame.height) < 0.001)
    }

    private func makeView(size: CGSize,
                          imageSize: CGSize = CGSize(width: 1_600, height: 900)) throws -> RemoteDesktopView<VNCSession>.ScreenView {
        let view = RemoteDesktopView<VNCSession>.ScreenView(frame: CGRect(origin: .zero, size: size))
        view.setFollowsCursor(false)
        view.display(framebufferUpdate: try makeUpdate(imageSize: imageSize))
        view.layoutIfNeeded()
        return view
    }

    private func makeUpdate(imageSize: CGSize) throws -> RemoteFramebufferUpdate {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return RemoteFramebufferUpdate(image: try #require(context.makeImage()),
                                       imageSize: imageSize, dirtyRect: nil)
    }

    private final class CursorSession: RemoteSessionInputControlling {
        let touchMode: RemoteTouchMode = .direct
        var cursorLocation: CGPoint

        init(cursorLocation: CGPoint) { self.cursorLocation = cursorLocation }

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
