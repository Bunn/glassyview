import AVFoundation
import CoreMedia
import Testing
import UIKit
import RoyalVNCKit
@testable import GlassyDesk

@MainActor
struct PictureInPictureTests {
    @Test
    func throttleKeepsTheInlineMirrorCheapAndFollowsTheActiveWindow() {
        var throttle = FramebufferPictureInPictureThrottle()
        func submits(at time: TimeInterval, active: Bool = false) -> Bool {
            throttle.shouldSubmit(at: time, isPictureInPictureActive: active)
        }

        #expect(submits(at: 10) == true)
        #expect(submits(at: 10.5) == false)
        #expect(submits(at: 11) == true)

        #expect(submits(at: 11.03, active: true) == false)
        #expect(submits(at: 11.07, active: true) == true)

        // A clock that moves backwards never stalls the mirror.
        #expect(submits(at: 5) == true)

        throttle.reset()
        #expect(submits(at: 5.1) == true)
    }

    @Test
    func framesAreScaledToEvenDimensionsAndDisplayImmediately() throws {
        let image = try makeImage(width: 3_841, height: 1_080)
        var pool = FramebufferPixelBufferPool()
        let sampleBuffer = try #require(
            FramebufferPictureInPictureFeeder.makeSampleBuffer(from: image, pool: &pool)
        )
        let dimensions = try dimensions(of: sampleBuffer)
        #expect(dimensions.width == 1_280)
        #expect(dimensions.height == 360)

        let attachments = try #require(
            CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        )
        #expect(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)

        // Same output size reuses the pool; a new size replaces it.
        let firstPool = try #require(pool.pool)
        _ = FramebufferPictureInPictureFeeder.makeSampleBuffer(from: image, pool: &pool)
        #expect(pool.pool === firstPool)
        _ = FramebufferPictureInPictureFeeder.makeSampleBuffer(from: try makeImage(width: 640, height: 480), pool: &pool)
        #expect(pool.pool !== firstPool)
        #expect(pool.width == 640 && pool.height == 480)
    }

    @Test
    func cropShowsOnlyTheSelectedDisplay() throws {
        let image = try makeImage(width: 5_120, height: 1_440)
        var pool = FramebufferPixelBufferPool()
        let selected = try #require(
            FramebufferPictureInPictureFeeder.makeSampleBuffer(
                from: image,
                crop: CGRect(x: 2_560, y: 0, width: 2_560, height: 1_440),
                pool: &pool
            )
        )
        let dimensions = try dimensions(of: selected)
        #expect(dimensions.width == 1_280)
        #expect(dimensions.height == 720)

        // An empty or out-of-bounds crop falls back to the whole framebuffer.
        let fallback = try #require(
            FramebufferPictureInPictureFeeder.makeSampleBuffer(
                from: image,
                crop: CGRect(x: 9_000, y: 9_000, width: 10, height: 10),
                pool: &pool
            )
        )
        #expect(try self.dimensions(of: fallback).height == 360)
    }

    @Test
    func coordinatorPersistsAutomaticStartAndIgnoresUnsupportedDevices() throws {
        let suiteName = "PictureInPictureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = RemotePictureInPictureCoordinator(defaults: defaults, isSupported: false)
        #expect(coordinator.startsAutomatically == RemotePictureInPictureCoordinator.defaultStartsAutomatically)
        coordinator.setStartsAutomatically(false)
        #expect(!coordinator.startsAutomatically)
        #expect(defaults.bool(forKey: RemotePictureInPictureCoordinator.startsAutomaticallyKey) == false)

        coordinator.register(AVSampleBufferDisplayLayer())
        #expect(coordinator.debugSourceLayer == nil)
        #expect(!coordinator.isPossible)
        #expect(!coordinator.keepsSessionAlive)
        #expect(!coordinator.mayStartAutomatically)
        coordinator.start()
        #expect(!coordinator.keepsSessionAlive)
    }

    @Test
    func liveContentHasNoTimeline() {
        let range = RemotePictureInPicturePlayback.liveTimeRange
        #expect(range.start == .negativeInfinity)
        #expect(range.duration == .positiveInfinity)
    }

    @Test
    func standardVNCSessionRegistersACoveredMirrorOnlyWhileOnScreen() throws {
        // Simulators report Picture in Picture as unsupported; the view wiring
        // is still exercised against a coordinator that accepts sources.
        let coordinator = RemotePictureInPictureCoordinator(isSupported: true)
        let window = try makeWindow()
        let view = RemoteDesktopView<VNCSession>.ScreenView(frame: window.bounds)
        view.pictureInPictureCoordinator = coordinator
        let session = StubSession()
        view.session = session
        view.display(framebufferUpdate: RemoteFramebufferUpdate(image: try makeImage(width: 64, height: 36),
                                                               imageSize: CGSize(width: 64, height: 36),
                                                               dirtyRect: nil))
        view.setProvidesPictureInPicture(true)
        #expect(view.debugPictureInPictureSourceLayer == nil)

        window.addSubview(view)
        view.layoutIfNeeded()
        let sourceLayer = try #require(view.debugPictureInPictureSourceLayer)
        #expect(coordinator.debugSourceLayer === sourceLayer)
        #expect(view.debugPictureInPictureSourceIsBelowFramebuffer)

        view.removeFromSuperview()
        #expect(coordinator.debugSourceLayer == nil)
        #expect(view.debugPictureInPictureSourceLayer == nil)

        window.addSubview(view)
        #expect(coordinator.debugSourceLayer === view.debugPictureInPictureSourceLayer)
        view.setProvidesPictureInPicture(false)
        #expect(coordinator.debugSourceLayer == nil)
        withExtendedLifetime((window, session)) {}
    }

    @Test
    func fastConnectionRegistersItsDecodedLayerInsteadOfAMirror() throws {
        // Simulators report Picture in Picture as unsupported; the view wiring
        // is still exercised against a coordinator that accepts sources.
        let coordinator = RemotePictureInPictureCoordinator(isSupported: true)
        let window = try makeWindow()
        let view = RemoteDesktopView<VNCSession>.ScreenView(frame: window.bounds)
        view.pictureInPictureCoordinator = coordinator
        let session = StubSession()
        view.session = session
        let renderer = GlassyStreamVideoRenderer()
        view.setGlassyStreamRenderer(renderer)
        view.setProvidesPictureInPicture(true)
        window.addSubview(view)

        #expect(view.debugPictureInPictureSourceLayer == nil)
        let registered = try #require(coordinator.debugSourceLayer)
        #expect(registered.superlayer === view.layer || registered.superlayer?.superlayer === view.layer)

        view.prepareForDismantle()
        #expect(coordinator.debugSourceLayer == nil)
        withExtendedLifetime((window, session, renderer)) {}
    }

    // MARK: - Fixtures

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(UIColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func dimensions(of sampleBuffer: CMSampleBuffer) throws -> CMVideoDimensions {
        let format = try #require(CMSampleBufferGetFormatDescription(sampleBuffer))
        return CMVideoFormatDescriptionGetDimensions(format)
    }

    private func makeWindow() throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.isHidden = false
        return window
    }

    private final class StubSession: RemoteSessionInputControlling {
        var touchMode: RemoteTouchMode = .direct
        var cursorLocation: CGPoint = .zero

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
