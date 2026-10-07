import Observation
import SwiftUI
import Testing
import UIKit
@testable import GlassyDesk

// Extend the serialized hosting suite so its temporary UIWindows never race.
// These inject division rectangles; actual hardware region delivery is separate.
extension SessionLayoutTests {
    @Test
    func laptopPaneTransitionsPreserveDesktopPanAndSeparateControlsInBothDirections() async throws {
        let model = LaptopLayoutModel()
        let recorder = try makeLaptopRecorder()
        let host = try LaptopLayoutHost(model: model, recorder: recorder)
        defer { host.close() }
        await host.settle()

        let desktop = try #require(recorder.desktop)
        let controls = try #require(recorder.controls)
        desktop.setZoomScale(2, notify: false)
        desktop.debugRouteTwoFingerTouchPan(by: CGPoint(x: -55, y: -38))
        let initialRenderedFrame = desktop.debugFramebufferFrame
        let initialAnchor = try #require(desktop.debugFramebufferPoint(
            for: CGPoint(x: desktop.bounds.midX, y: desktop.bounds.midY)))
        #expect(desktop.debugManualViewportPositionActive)

        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            model.direction = direction
            for divisions in [[Self.laptopHorizontalDivision], [Self.laptopVerticalDivision], []] {
                model.divisions = divisions
                await host.settle()

                let currentDesktop = try #require(recorder.desktop)
                let currentControls = try #require(recorder.controls)
                let viewport = try #require(recorder.viewport)
                let frames = SessionPaneGeometry.frames(in: model.fullBounds,
                                                        divisions: divisions,
                                                        occlusions: [])
                let contentFrame = currentDesktop.convert(currentDesktop.bounds, to: viewport)
                let controlsFrame = currentControls.convert(currentControls.bounds, to: viewport)
                #expect(currentDesktop === desktop)
                #expect(currentControls === controls)
                #expect(recorder.desktopCreationCount == 1)
                #expect(recorder.controlsCreationCount == 1)
                #expect(currentDesktop.debugZoomScale == 2)
                expectLaptopFrame(contentFrame, matches: physicalLaptopFrame(frames.content,
                                                                             model: model))
                expectLaptopFrame(controlsFrame, matches: physicalLaptopFrame(frames.controls,
                                                                              model: model))

                if let division = divisions.first {
                    #expect(frames.isSeparated)
                    let overlap = contentFrame.intersection(controlsFrame)
                    #expect(overlap.isEmpty || overlap.width < 1 || overlap.height < 1)
                    if division.width > division.height {
                        #expect(contentFrame.maxY <= division.minY + 1)
                        #expect(controlsFrame.minY >= division.maxY - 1)
                    } else if direction == .leftToRight {
                        #expect(contentFrame.maxX <= division.minX + 1)
                        #expect(controlsFrame.minX >= division.maxX - 1)
                    } else {
                        // SwiftUI mirrors both the queried region coordinates
                        // and the custom Layout's semantic leading/trailing.
                        #expect(contentFrame.minX >= model.fullBounds.width - division.minX - 1)
                        #expect(controlsFrame.maxX <= model.fullBounds.width - division.maxX + 1)
                    }
                } else {
                    #expect(!frames.isSeparated)
                    expectLaptopFrame(currentDesktop.debugFramebufferFrame, matches: initialRenderedFrame)
                    let anchor = try #require(currentDesktop.debugFramebufferPoint(
                        for: CGPoint(x: currentDesktop.bounds.midX, y: currentDesktop.bounds.midY)))
                    #expect(abs(anchor.x - initialAnchor.x) < 0.01)
                    #expect(abs(anchor.y - initialAnchor.y) < 0.01)
                }
            }
        }
    }

    @Test
    func laptopKeyboardClipsVisiblePanesWithoutMovingTheirFullGeometryOrReplacingDesktop() async throws {
        let model = LaptopLayoutModel()
        model.divisions = [Self.laptopHorizontalDivision]
        let recorder = try makeLaptopRecorder()
        let host = try LaptopLayoutHost(model: model, recorder: recorder)
        defer { host.close() }
        await host.settle()

        let desktop = try #require(recorder.desktop)
        let controls = try #require(recorder.controls)
        let originalRenderedFrame = desktop.debugFramebufferFrame
        let fullFrames = SessionPaneGeometry.frames(in: model.fullBounds,
                                                    divisions: model.divisions,
                                                    occlusions: [])
        #expect(fullFrames.isSeparated)

        for height: CGFloat in [500, 430, 410, 800] {
            // The system keyboard reduces the visible scene, but the physical
            // fold remains at the same coordinate in its unobscured geometry.
            model.visibleHeight = height
            await host.settle()

            let currentDesktop = try #require(recorder.desktop)
            let currentControls = try #require(recorder.controls)
            let viewport = try #require(recorder.viewport)
            let contentFrame = currentDesktop.convert(currentDesktop.bounds, to: viewport)
            let controlsFrame = currentControls.convert(currentControls.bounds, to: viewport)
            #expect(currentDesktop === desktop)
            #expect(currentControls === controls)
            #expect(recorder.desktopCreationCount == 1)
            #expect(recorder.controlsCreationCount == 1)
            expectLaptopFrame(contentFrame, matches: model.visibleFrame(fullFrames.content))
            expectLaptopFrame(controlsFrame, matches: model.visibleFrame(fullFrames.controls))
            expectLaptopFrame(currentDesktop.debugFramebufferFrame, matches: originalRenderedFrame)
            #expect(contentFrame.maxY <= height + 1)
            #expect(controlsFrame.maxY <= height + 1)

            // An entirely keyboard-covered control pane must have no native
            // hit target extending beneath its visible clipping boundary.
            let belowVisible = viewport.convert(CGPoint(x: viewport.bounds.midX, y: height + 20),
                                                to: host.hosting.view)
            let hit = host.hosting.view.hitTest(belowVisible, with: nil)
            #expect(hit !== currentDesktop)
            #expect(hit !== currentControls)
        }
    }

    private static let laptopHorizontalDivision = CGRect(x: 0, y: 390, width: 700, height: 20)
    private static let laptopVerticalDivision = CGRect(x: 340, y: 0, width: 20, height: 800)

    private func makeLaptopRecorder() throws -> LaptopLayoutRecorder {
        let context = try #require(CGContext(data: nil, width: 1, height: 1,
                                            bitsPerComponent: 8, bytesPerRow: 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return LaptopLayoutRecorder(framebuffer: RemoteFramebufferUpdate(
            image: try #require(context.makeImage()),
            imageSize: CGSize(width: 1_000, height: 1_000), dirtyRect: nil))
    }

    private func physicalLaptopFrame(_ frame: CGRect, model: LaptopLayoutModel) -> CGRect {
        guard model.direction == .rightToLeft else { return frame }
        return CGRect(x: model.fullBounds.width - frame.maxX, y: frame.minY,
                      width: frame.width, height: frame.height)
    }

    private func expectLaptopFrame(_ frame: CGRect, matches expected: CGRect) {
        #expect(abs(frame.minX - expected.minX) < 1)
        #expect(abs(frame.minY - expected.minY) < 1)
        #expect(abs(frame.width - expected.width) < 1)
        #expect(abs(frame.height - expected.height) < 1)
    }
}

@MainActor
@Observable
private final class LaptopLayoutModel {
    let fullBounds = CGRect(x: 0, y: 0, width: 700, height: 800)
    var visibleHeight: CGFloat = 800
    var divisions: [CGRect] = []
    var direction = LayoutDirection.leftToRight

    func visibleFrame(_ frame: CGRect) -> CGRect {
        let visible = frame.intersection(CGRect(x: 0, y: 0, width: fullBounds.width,
                                               height: visibleHeight))
        return visible.isNull
            ? CGRect(x: frame.minX, y: min(frame.minY, visibleHeight), width: frame.width, height: 0)
            : visible
    }
}

@MainActor
private final class LaptopLayoutRecorder {
    let framebuffer: RemoteFramebufferUpdate
    var desktop: RemoteDesktopView<VNCSession>.ScreenView?
    var controls: UIView?
    var viewport: UIView?
    var desktopCreationCount = 0
    var controlsCreationCount = 0

    init(framebuffer: RemoteFramebufferUpdate) {
        self.framebuffer = framebuffer
    }
}

private struct LaptopDesktopProbe: UIViewRepresentable {
    let recorder: LaptopLayoutRecorder
    let fittingSize: CGSize

    func makeUIView(context: Context) -> RemoteDesktopView<VNCSession>.ScreenView {
        let view = RemoteDesktopView<VNCSession>.ScreenView(frame: .zero)
        view.setAcceptsHardwareKeyboardInput(false)
        view.setFollowsCursor(false)
        view.setPansViewportWithTwoFingers(true)
        view.display(framebufferUpdate: recorder.framebuffer)
        recorder.desktop = view
        recorder.desktopCreationCount += 1
        return view
    }

    func updateUIView(_ view: RemoteDesktopView<VNCSession>.ScreenView, context: Context) {
        view.setFittingViewportSize(fittingSize)
    }
}

private struct LaptopSurfaceProbe: UIViewRepresentable {
    let recorder: LaptopLayoutRecorder
    var isViewport = false
    var acceptsInput = false

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        if isViewport {
            recorder.viewport = view
        } else {
            recorder.controls = view
            recorder.controlsCreationCount += 1
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        view.isUserInteractionEnabled = acceptsInput
    }
}

private struct LaptopLayoutFixture: View {
    let model: LaptopLayoutModel
    let recorder: LaptopLayoutRecorder

    var body: some View {
        GeometryReader { _ in
            let frames = SessionPaneGeometry.frames(in: model.fullBounds,
                                                    divisions: model.divisions,
                                                    occlusions: [])
            SessionPaneLayout(contentFrame: model.visibleFrame(frames.content),
                              controlsFrame: model.visibleFrame(frames.controls)) {
                LaptopDesktopProbe(recorder: recorder, fittingSize: frames.content.size)
                LaptopSurfaceProbe(recorder: recorder, acceptsInput: frames.isSeparated)
            }
            .frame(width: model.fullBounds.width, height: model.visibleHeight)
            .background { LaptopSurfaceProbe(recorder: recorder, isViewport: true) }
            .environment(\.layoutDirection, model.direction)
            .transaction { $0.animation = nil }
        }
    }
}

@MainActor
private final class LaptopLayoutHost {
    let window: UIWindow
    let parent: UIViewController
    let hosting: UIHostingController<LaptopLayoutFixture>

    init(model: LaptopLayoutModel, recorder: LaptopLayoutRecorder) throws {
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        parent = UIViewController()
        hosting = UIHostingController(rootView: LaptopLayoutFixture(model: model, recorder: recorder))
        hosting.safeAreaRegions = []
        window.rootViewController = parent
        parent.addChild(hosting)
        parent.view.addSubview(hosting.view)
        hosting.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 1_400)
        hosting.didMove(toParent: parent)
        window.isHidden = false
    }

    func settle() async {
        for _ in 0..<5 {
            window.layoutIfNeeded()
            parent.view.layoutIfNeeded()
            hosting.view.setNeedsLayout()
            hosting.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func close() {
        window.isHidden = true
        hosting.willMove(toParent: nil)
        hosting.view.removeFromSuperview()
        hosting.removeFromParent()
        window.rootViewController = nil
    }
}
