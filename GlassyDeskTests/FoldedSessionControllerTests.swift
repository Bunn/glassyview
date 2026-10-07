import Observation
import SwiftUI
import Testing
import UIKit
@testable import GlassyDesk

extension SessionLayoutTests {
    @Test
    func foldedControllerKeepsShortcutsWithKeyboardAndRetainsItsTrackpadWhenResized() async throws {
        let model = FoldedControllerTestModel()
        let session = try SessionLayoutRemoteSession()
        let recorder = FoldedControllerRecorder()
        let host = try FoldedControllerHost(model: model, session: session, recorder: recorder)
        defer { host.close() }
        await host.settle()

        let trackpad = try #require(findFoldedNativeView(
            RemoteDesktopView<SessionLayoutRemoteSession>.ScreenView.self, in: host.hosting.view))
        let keyboard = try #require(findFoldedNativeView(
            RemoteSoftwareKeyboardInput.InputView.self, in: host.hosting.view))
        let accessory = try #require(keyboard.inputAccessoryViewController)
        #expect(!model.isKeyboardFocused)
        #expect(!keyboard.isFirstResponder)
        #expect(session.modifierReleaseCount == 0)
        #expect(!accessory.view.isDescendant(of: host.hosting.view))

        // Match an explicit keyboard request and an accessory modifier toggle.
        // The non-key window keeps this test independent of OS keyboard geometry.
        model.isKeyboardFocused = true
        model.heldModifierKeys = [.command]
        session.setModifier(.command, isPressed: true)
        await host.settle()
        #expect(session.modifierReleaseCount == 0)

        for size in [CGSize(width: 350, height: 180), CGSize(width: 150, height: 100),
                     CGSize(width: 700, height: 300)] {
            model.size = size
            await host.settle()

            let currentTrackpad = try #require(findFoldedNativeView(
                RemoteDesktopView<SessionLayoutRemoteSession>.ScreenView.self, in: host.hosting.view))
            let currentKeyboard = try #require(findFoldedNativeView(
                RemoteSoftwareKeyboardInput.InputView.self, in: host.hosting.view))
            let viewport = try #require(recorder.viewport)
            let frame = currentTrackpad.convert(currentTrackpad.bounds, to: viewport)
            #expect(currentTrackpad === trackpad)
            #expect(currentKeyboard === keyboard)
            #expect(currentKeyboard.inputAccessoryViewController === accessory)
            #expect(abs(viewport.bounds.width - size.width) < 1)
            #expect(abs(viewport.bounds.height - size.height) < 1)
            #expect(frame.minX >= 0)
            #expect(frame.minY >= 0 && frame.minY <= 5)
            #expect(frame.maxX <= size.width + 1)
            #expect(frame.maxY <= size.height + 1)
            #expect(frame.width >= size.width - 17)
            let trackpadPoint = currentTrackpad.convert(CGPoint(x: currentTrackpad.bounds.midX,
                                                               y: currentTrackpad.bounds.midY),
                                                       to: host.hosting.view)
            #expect(host.hosting.view.hitTest(trackpadPoint, with: nil) === currentTrackpad)
            // The trackpad contains no special-key strip at any pane size.
            #expect(abs(frame.height - (size.height - 8)) < 1)
            #expect(model.heldModifierKeys == [.command])
            #expect(session.heldModifiers == [.command])
            #expect(session.modifierReleaseCount == 0)
            #expect(model.isKeyboardFocused)
            #expect(!currentKeyboard.isFirstResponder)
        }

        // Exercise the real mounted keyboard responder's forwarding callback.
        keyboard.insertText("Folded keyboard")
        #expect(session.insertedText == ["Folded keyboard"])
        model.isKeyboardFocused = false
        await host.settle()
        #expect(!model.isKeyboardFocused)
        #expect(!keyboard.isFirstResponder)
        // The session parent owns modifier release on keyboard hide and mode
        // exit; geometry changes in this controller must not release them.
        #expect(session.modifierReleaseCount == 0)
    }

    private func findFoldedNativeView<NativeView: UIView>(_ type: NativeView.Type,
                                                         in view: UIView) -> NativeView? {
        if let matching = view as? NativeView { return matching }
        return view.subviews.lazy.compactMap { findFoldedNativeView(type, in: $0) }.first
    }
}

@MainActor
@Observable
private final class FoldedControllerTestModel {
    var size = CGSize(width: 700, height: 300)
    var heldModifierKeys: Set<RemoteModifierKey> = []
    var isKeyboardFocused = false
}

@MainActor
private final class FoldedControllerRecorder {
    var viewport: UIView?
}

private struct FoldedControllerViewport: UIViewRepresentable {
    let recorder: FoldedControllerRecorder

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        recorder.viewport = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct FoldedControllerFixture: View {
    let model: FoldedControllerTestModel
    let session: SessionLayoutRemoteSession
    let recorder: FoldedControllerRecorder

    var body: some View {
        @Bindable var model = model
        GeometryReader { _ in
            ExternalSessionControllerView(session: session,
                                          sessionTitle: "Layout Test Mac",
                                          heldModifierKeys: $model.heldModifierKeys,
                                          isKeyboardFocused: $model.isKeyboardFocused,
                                          stopControllerMode: {},
                                          presentation: .folded)
                .frame(width: model.size.width, height: model.size.height)
                .background { FoldedControllerViewport(recorder: recorder) }
                .transaction { $0.animation = nil }
        }
    }
}

@MainActor
private final class FoldedControllerHost {
    let window: UIWindow
    let parent: UIViewController
    let hosting: UIHostingController<FoldedControllerFixture>

    init(model: FoldedControllerTestModel, session: SessionLayoutRemoteSession,
         recorder: FoldedControllerRecorder) throws {
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        parent = UIViewController()
        hosting = UIHostingController(rootView: FoldedControllerFixture(model: model,
                                                                        session: session,
                                                                        recorder: recorder))
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
