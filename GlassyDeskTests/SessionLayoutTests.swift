import Combine
import Observation
import RoyalVNCKit
import SwiftUI
import Testing
import UIKit
@testable import GlassyDesk

/// These exercise real SwiftUI hosting and the runtime's arrangement implementation.
/// Resizing a hosted view is not a substitute for Simulator/hardware fold transitions.
@Suite(.serialized)
@MainActor
struct SessionLayoutTests {
    @Test
    func measuredInputOverlayPreservesDesktopScaleAndRevealsCursor() async throws {
        let model = SessionLayoutTestModel()
        model.size = CGSize(width: 500, height: 400)
        let recorder = SessionLayoutRecorder()
        recorder.remoteSession = try SessionLayoutRemoteSession()
        let host = try SessionLayoutHost(model: model, recorder: recorder, usesArrangement: true)
        defer { host.close() }

        await host.settle()
        let screen = try #require(findRemoteScreen(in: host.hosting.view))
        let initialBounds = screen.bounds
        let initialFrame = screen.debugFramebufferFrame
        let viewportSnapshot = try #require(recorder.viewportSnapshot)
        #expect(recorder.measuredInputBarHeight == 0)

        // This is the production ordering: activating the input bar starts its
        // UIViewRepresentable update while the newly inserted bar still has a
        // zero measured height. SwiftUI later supplies the real overlay inset.
        model.showsInputBar = true
        await host.settle()

        let resized = try #require(findRemoteScreen(in: host.hosting.view))
        let cursorY = resized.debugFramebufferFrame.minY + resized.debugFramebufferFrame.height * 0.95
        #expect(resized === screen)
        #expect(recorder.measuredInputBarHeight == 116)
        let expectedReduction: CGFloat = viewportSnapshot.divisionFrames.isEmpty ? 116 : 0
        #expect(abs(resized.bounds.height - (initialBounds.height - expectedReduction)) < 1)
        #expect(abs(resized.debugFramebufferFrame.height - initialFrame.height) < 1)
        #expect(cursorY <= resized.bounds.maxY + 1)
    }

    private func findRemoteScreen(in view: UIView) -> RemoteDesktopView<SessionLayoutRemoteSession>.ScreenView? {
        if let screen = view as? RemoteDesktopView<SessionLayoutRemoteSession>.ScreenView { return screen }
        return view.subviews.lazy.compactMap { findRemoteScreen(in: $0) }.first
    }

    @Test
    func reservedContainerResizesWithoutReplacingContent() async throws {
        let model = SessionLayoutTestModel()
        let recorder = SessionLayoutRecorder()
        let host = try SessionLayoutHost(model: model, recorder: recorder, usesArrangement: false)
        defer { host.close() }

        await host.settle()
        let initialContent = try #require(recorder.views[.content])
        initialContent.accessibilityValue = "retained draft"

        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for size in Self.viewportSizes {
                model.size = size
                model.direction = direction
                await host.settle()

                let content = try #require(recorder.views[.content])
                let viewport = try #require(recorder.views[.viewport])
                let frame = content.convert(content.bounds, to: viewport)
                let snapshot = try #require(recorder.viewportSnapshot)

                #expect(content === initialContent)
                #expect(content.accessibilityValue == "retained draft")
                #expect(recorder.creationCounts[.content] == 1)
                #expect(abs(viewport.bounds.width - size.width) < 1)
                #expect(abs(viewport.bounds.height - size.height) < 1)
                expectContained(frame, in: viewport.bounds)

                // A container with no hardware intersections must not invent gutters.
                if snapshot.reservedFrames.isEmpty {
                    #expect(abs(frame.width - size.width) < 1)
                    #expect(abs(frame.height - size.height) < 1)
                }
                for region in snapshot.reservedFrames {
                    let physicalRegion = direction == .rightToLeft
                        ? CGRect(x: size.width - region.maxX, y: region.minY,
                                 width: region.width, height: region.height)
                        : region
                    let overlap = frame.intersection(physicalRegion)
                    #expect(overlap.isEmpty || overlap.width < 1 || overlap.height < 1)
                }
            }
        }
    }

    @Test
    func arrangementPreservesBothPanesAndPassesTouchesThroughEmptyControls() async throws {
        let model = SessionLayoutTestModel()
        let recorder = SessionLayoutRecorder()
        let host = try SessionLayoutHost(model: model, recorder: recorder, usesArrangement: true)
        defer { host.close() }

        await host.settle()
        let initialContent = try #require(recorder.views[.content])
        let initialControls = try #require(recorder.views[.controls])
        initialContent.accessibilityValue = "retained viewport"
        initialControls.accessibilityValue = "retained controls"

        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for size in Self.viewportSizes {
                model.size = size
                model.direction = direction
                await host.settle()

                let content = try #require(recorder.views[.content])
                let controls = try #require(recorder.views[.controls])
                let viewport = try #require(recorder.views[.viewport])
                let contentFrame = content.convert(content.bounds, to: viewport)
                let controlsFrame = controls.convert(controls.bounds, to: viewport)
                #expect(content === initialContent)
                #expect(controls === initialControls)
                #expect(content.accessibilityValue == "retained viewport")
                #expect(controls.accessibilityValue == "retained controls")
                #expect(recorder.creationCounts[.content] == 1)
                #expect(recorder.creationCounts[.controls] == 1)
                expectContained(contentFrame, in: viewport.bounds)
                expectContained(controlsFrame, in: viewport.bounds)
                #expect(abs(controlsFrame.width - 44) < 1)
                #expect(abs(controlsFrame.height - 44) < 1)

                // UIKit hit testing must reach the desktop through the blank area
                // of the full-size primary controls pane in overlay mode.
                let desktopPoint = content.convert(CGPoint(x: content.bounds.midX,
                                                          y: content.bounds.midY),
                                                   to: host.hosting.view)
                #expect(host.hosting.view.hitTest(desktopPoint, with: nil) === content)
                let controlPoint = controls.convert(CGPoint(x: controls.bounds.midX,
                                                           y: controls.bounds.midY),
                                                    to: host.hosting.view)
                #expect(host.hosting.view.hitTest(controlPoint, with: nil) === controls)
            }
        }
    }

    @Test
    func arrangementResizesAtAsymmetricOriginsWithoutReplacingItsPanes() async throws {
        let model = SessionLayoutTestModel()
        let recorder = SessionLayoutRecorder()
        let host = try SessionLayoutHost(model: model, recorder: recorder, usesArrangement: true)
        defer { host.close() }
        await host.settle()
        let initialContent = try #require(recorder.views[.content])
        let initialControls = try #require(recorder.views[.controls])

        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            model.direction = direction
            for (size, origin) in [(CGSize(width: 390, height: 780), CGPoint(x: 31, y: 57)),
                                   (CGSize(width: 720, height: 340), CGPoint(x: 53, y: 29)),
                                   (CGSize(width: 390, height: 780), CGPoint(x: 17, y: 83))] {
                model.size = size
                model.origin = origin
                await host.settle()

                let viewport = try #require(recorder.views[.viewport])
                let content = try #require(recorder.views[.content])
                let controls = try #require(recorder.views[.controls])
                let contentFrame = content.convert(content.bounds, to: viewport)
                let controlsFrame = controls.convert(controls.bounds, to: viewport)
                #expect(content === initialContent)
                #expect(controls === initialControls)
                #expect(recorder.creationCounts[.content] == 1)
                #expect(recorder.creationCounts[.controls] == 1)
                #expect(viewport.convert(viewport.bounds, to: host.hosting.view).origin != .zero)
                expectContained(contentFrame, in: viewport.bounds)
                expectContained(controlsFrame, in: viewport.bounds)
                let controlPoint = controls.convert(CGPoint(x: controls.bounds.midX,
                                                           y: controls.bounds.midY),
                                                     to: host.hosting.view)
                #expect(host.hosting.view.hitTest(controlPoint, with: nil) === controls)
            }
        }
    }

    @Test
    func inputOverlayInsetReducesOnlyTheOverlaidContentAndKeepsIdentity() async throws {
        let model = SessionLayoutTestModel()
        let recorder = SessionLayoutRecorder()
        let host = try SessionLayoutHost(model: model, recorder: recorder, usesArrangement: true)
        defer { host.close() }

        await host.settle()
        let initialContent = try #require(recorder.views[.content])
        let initialControls = try #require(recorder.views[.controls])
        let baselineContent = try #require(recorder.contentSnapshot)
        let baselineContentSize = initialContent.bounds.size
        let baselineControlsFrame = initialControls.convert(initialControls.bounds, to: host.hosting.view)
        let viewportSnapshot = try #require(recorder.viewportSnapshot)

        for inset: CGFloat in [72, 116, 0] {
            model.bottomInset = inset
            await host.settle()

            let currentContent = try #require(recorder.contentSnapshot)
            let content = try #require(recorder.views[.content])
            let controls = try #require(recorder.views[.controls])
            let controlsFrame = controls.convert(controls.bounds, to: host.hosting.view)
            // A real active division gives the input controls their own pane;
            // only the flat overlay layout should reserve their height in media.
            let expectedReduction = viewportSnapshot.divisionFrames.isEmpty ? inset : 0
            // GeometryReader already receives the reduced proposed size. Its
            // reported bottom inset is metadata, not another reduction to apply.
            #expect(abs(currentContent.size.height
                        - (baselineContent.size.height - expectedReduction)) < 1)
            #expect(abs(content.bounds.height
                        - (baselineContentSize.height - expectedReduction)) < 1)
            #expect(abs(currentContent.size.width - baselineContent.size.width) < 1)
            #expect(abs(content.bounds.width - baselineContentSize.width) < 1)
            #expect(abs(currentContent.safeAreaInsets.bottom
                        - baselineContent.safeAreaInsets.bottom - expectedReduction) < 1)
            #expect(controlsFrame == baselineControlsFrame)
            #expect(content === initialContent)
            #expect(controls === initialControls)
            #expect(recorder.creationCounts[.content] == 1)
            #expect(recorder.creationCounts[.controls] == 1)
        }
    }

    private static let viewportSizes = [
        CGSize(width: 390, height: 780),
        CGSize(width: 720, height: 340),
        CGSize(width: 700, height: 700),
        CGSize(width: 240, height: 220),
        CGSize(width: 820, height: 1_080),
        CGSize(width: 390, height: 780)
    ]

    private func expectContained(_ frame: CGRect, in bounds: CGRect) {
        #expect(frame.width > 0)
        #expect(frame.height > 0)
        #expect(frame.minX >= bounds.minX - 1)
        #expect(frame.minY >= bounds.minY - 1)
        #expect(frame.maxX <= bounds.maxX + 1)
        #expect(frame.maxY <= bounds.maxY + 1)
    }
}

@MainActor
@Observable
private final class SessionLayoutTestModel {
    var size = CGSize(width: 390, height: 780)
    var origin = CGPoint.zero
    var direction = LayoutDirection.leftToRight
    var bottomInset: CGFloat = 0
    var showsInputBar = false
}

private enum SessionLayoutProbeRole: Hashable {
    case viewport, content, controls
}

@MainActor
private final class SessionLayoutRecorder {
    var views: [SessionLayoutProbeRole: UIView] = [:]
    var creationCounts: [SessionLayoutProbeRole: Int] = [:]
    var viewportSnapshot: SessionLayoutSnapshot?
    var contentSnapshot: SessionLayoutSnapshot?
    var remoteSession: SessionLayoutRemoteSession?
    var measuredInputBarHeight: CGFloat = 0
}

private struct SessionLayoutSnapshot: Equatable {
    var size: CGSize
    var safeAreaInsets: EdgeInsets
    var reservedFrames: [CGRect]
    var divisionFrames: [CGRect]

    @MainActor
    init(_ geometry: GeometryProxy) {
        size = geometry.size
        safeAreaInsets = geometry.safeAreaInsets
        reservedFrames = activeReservedRegionFrames(in: geometry)
        divisionFrames = activeReservedRegionFrames(in: geometry, includeOcclusions: false)
    }

}

private struct SessionLayoutProbe: UIViewRepresentable {
    let role: SessionLayoutProbeRole
    let recorder: SessionLayoutRecorder

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = role != .viewport
        recorder.views[role] = view
        recorder.creationCounts[role, default: 0] += 1
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct SessionLayoutFixture: View {
    @State private var measuredInputBarHeight: CGFloat = 0
    @State private var zoomScale: CGFloat = 1
    let model: SessionLayoutTestModel
    let recorder: SessionLayoutRecorder
    let usesArrangement: Bool

    var body: some View {
        GeometryReader { _ in
            Group {
                if usesArrangement {
                    SessionArrangement(overlayBottomInset: recorder.remoteSession == nil ? model.bottomInset : measuredInputBarHeight) {
                        measuredContent
                    } controls: {
                        VStack(spacing: 0) {
                            HStack(spacing: 0) {
                                Spacer(minLength: 0)
                                SessionLayoutProbe(role: .controls, recorder: recorder)
                                    .frame(width: 44, height: 44)
                            }
                            Spacer(minLength: 0)
                            if model.showsInputBar {
                                Color.clear
                                    .frame(height: 116)
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                        measuredInputBarHeight = height
                                        recorder.measuredInputBarHeight = height
                                    }
                            }
                        }
                    }
                } else {
                    ReservedRegionContainer { measuredContent }
                }
            }
            .frame(width: model.size.width, height: model.size.height)
            .background {
                SessionLayoutProbe(role: .viewport, recorder: recorder)
            }
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .allowsHitTesting(false)
                        .onChange(of: SessionLayoutSnapshot(geometry), initial: true) { _, snapshot in
                            recorder.viewportSnapshot = snapshot
                        }
                }
            }
            .environment(\.layoutDirection, model.direction)
            .transaction { $0.animation = nil }
            .offset(x: model.origin.x, y: model.origin.y)
        }
    }

    @ViewBuilder
    private var measuredContent: some View {
        if let session = recorder.remoteSession {
            ZStack {
                Color.black.ignoresSafeArea()
                SessionRemoteContent(session: session, reconnectState: nil,
                                     zoomScale: $zoomScale, followsCursor: true,
                                     keyboardAvoidanceActive: model.showsInputBar,
                                     acceptsHardwareKeyboardInput: false)
            }
        } else {
            GeometryReader { geometry in
                SessionLayoutProbe(role: .content, recorder: recorder)
                    .onChange(of: SessionLayoutSnapshot(geometry), initial: true) { _, snapshot in
                        recorder.contentSnapshot = snapshot
                    }
            }
        }
    }
}

final class SessionLayoutRemoteSession: RemoteSessionControlling {
    let objectWillChange = ObservableObjectPublisher()
    let status: RemoteSessionStatus = .connected
    let touchMode: RemoteTouchMode = .direct
    let cursorLocation = CGPoint(x: 500, y: 950)
    let cursor: RemoteCursor? = nil
    let quality: RemoteSessionQuality = .balanced
    let supportedQualities: [RemoteSessionQuality] = [.balanced]
    let preferredFrameRate: RemoteFrameRate = .balanced
    let displays: [RemoteDisplay] = []
    let displayOptions: [RemoteDisplayOption] = []
    let displaySelection: RemoteDisplaySelection = .all
    let selectedDisplayFrame: CGRect? = nil
    private let framebuffer: RemoteFramebufferUpdate
    private(set) var modifierReleaseCount = 0
    private(set) var heldModifiers: Set<RemoteModifierKey> = []
    private(set) var insertedText: [String] = []

    init() throws {
        let context = try #require(CGContext(data: nil, width: 1, height: 1,
                                            bitsPerComponent: 8, bytesPerRow: 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        framebuffer = RemoteFramebufferUpdate(image: try #require(context.makeImage()),
                                              imageSize: CGSize(width: 1_000, height: 1_000),
                                              dirtyRect: nil)
    }

    var framebufferUpdatePublisher: AnyPublisher<RemoteFramebufferUpdate, Never> { Just(framebuffer).eraseToAnyPublisher() }
    var cursorPublisher: AnyPublisher<RemoteCursor?, Never> { Just(cursor).eraseToAnyPublisher() }
    var cursorLocationPublisher: AnyPublisher<CGPoint, Never> { Just(cursorLocation).eraseToAnyPublisher() }

    func connect(host: String, port: UInt16, username: String, password: String) {}
    func disconnect() {}
    func reset() {}
    func applyPreferences(_ preferences: SessionPreferences) {}
    func setQuality(_ newQuality: RemoteSessionQuality) {}
    func setPreferredFrameRate(_ frameRate: RemoteFrameRate) {}
    func setDisplaySelection(_ selection: RemoteDisplaySelection) {}
    func toggleTouchMode() {}
    func retryConnect() {}
    func cancelReconnect() {}
    func updateNetworkPathStatus(_ status: NetworkPathStatus) {}
    func debugSimulateConnectionInterruption() {}
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
    func setModifier(_ modifier: RemoteModifierKey, isPressed: Bool) {
        if isPressed { heldModifiers.insert(modifier) } else { heldModifiers.remove(modifier) }
    }
    func releaseHeldModifiers() {
        modifierReleaseCount += 1
        heldModifiers.removeAll()
    }
    func sendText(_ text: String, modifiers: [VNCKeyCode]) { insertedText.append(text) }
    func sendKey(_ keyCode: VNCKeyCode, modifiers: [VNCKeyCode]) {}
    func sendReturn() {}
}

@MainActor
private final class SessionLayoutHost {
    let window: UIWindow
    let parent: UIViewController
    let hosting: UIHostingController<SessionLayoutFixture>

    init(model: SessionLayoutTestModel, recorder: SessionLayoutRecorder,
         usesArrangement: Bool) throws {
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first)
        window = UIWindow(windowScene: scene)
        parent = UIViewController()
        hosting = UIHostingController(rootView: SessionLayoutFixture(model: model,
                                                                     recorder: recorder,
                                                                     usesArrangement: usesArrangement))
        // Control the test viewport explicitly; device safe-area delivery is tested
        // by the app's runtime matrix, not by these synthetic container sizes.
        hosting.safeAreaRegions = []
        window.rootViewController = parent
        parent.addChild(hosting)
        parent.view.addSubview(hosting.view)
        hosting.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 1_400)
        hosting.didMove(toParent: parent)
        window.isHidden = false
    }

    func settle() async {
        // Hosting updates and native arrangement layout can span more than one
        // main-run-loop pass even when SwiftUI animations are disabled.
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
