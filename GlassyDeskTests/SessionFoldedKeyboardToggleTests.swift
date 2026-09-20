import SwiftUI
import Testing
import UIKit
@testable import GlassyDesk

@MainActor
extension SessionLayoutTests {
    @Test
    func productionFoldedSessionStartsHiddenAndRetainsInputWhileTogglingKeyboard() async throws {
        let host = try ProductionFoldedSessionHost()
        defer { host.close() }
        await host.settle()
        guard host.recorder.isSeparated else {
            print("[FoldedSessionToggle] No active division; folded-only assertions require a folded runtime.")
            return
        }

        let input = try #require(host.remoteInput)
        #expect(!input.isFirstResponder)
        host.log("hidden by default")
        await host.settle()

        // Exercise the actual responder and its callback to SessionView's focus
        // binding. SwiftUI's AX button tree is unavailable in this unit-test host.
        input.setFocus(true, request: 1)
        await host.settle()
        #expect(host.remoteInput === input)
        #expect(input.isFirstResponder)
        #expect(input.isUserInteractionEnabled)
        host.expectVisibleKeyboardWithinWindow()
        host.log("keyboard shown")
        await host.settle()

        input.setFocus(false, request: 1)
        await host.settle()
        #expect(host.remoteInput === input)
        #expect(!input.isFirstResponder)
        host.log("keyboard hidden again")
        await host.settle()
    }
}

@MainActor
private final class ProductionFoldedSessionRecorder {
    var isSeparated = false
}

private struct ProductionFoldedSessionFixture: View {
    let session: SessionLayoutRemoteSession
    let subscriptions: SubscriptionStore
    let recorder: ProductionFoldedSessionRecorder

    var body: some View {
        SessionView(session: session, preferences: .constant(.default), sessionTitle: "Folded session test")
            .environment(subscriptions)
            .background {
                GeometryReader { geometry in
                    let frames = SessionPaneGeometry.frames(
                        in: CGRect(origin: .zero, size: geometry.size),
                        divisions: activeReservedRegionFrames(in: geometry, includeOcclusions: false),
                        occlusions: activeReservedRegionFrames(in: geometry, includeDivisions: false)
                    )
                    Color.clear.onChange(of: frames.isSeparated, initial: true) { _, separated in
                        recorder.isSeparated = separated
                    }
                }
                .ignoresSafeArea(.keyboard)
            }
    }
}

@MainActor
private final class ProductionFoldedSessionHost {
    let scene: UIWindowScene
    let window: UIWindow
    let hosting: UIHostingController<ProductionFoldedSessionFixture>
    let recorder = ProductionFoldedSessionRecorder()
    private let previousKeyWindow: UIWindow?

    init() throws {
        scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        // Initialization only reads cached access; this fixture never refreshes
        // offerings, customer info, or any purchase operation.
        hosting = UIHostingController(rootView: ProductionFoldedSessionFixture(
            session: try SessionLayoutRemoteSession(), subscriptions: SubscriptionStore(), recorder: recorder
        ))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
    }

    var remoteInput: RemoteSoftwareKeyboardInput.InputView? {
        findInput(in: hosting.view)
    }

    var keyboardFrame: CGRect {
        hosting.view.convert(hosting.view.keyboardLayoutGuide.layoutFrame, to: window)
    }

    func expectVisibleKeyboardWithinWindow() {
        let frame = keyboardFrame
        #expect(frame.width > 0)
        #expect(frame.height > window.safeAreaInsets.bottom + 1)
        #expect(frame.minX >= window.bounds.minX - 1)
        #expect(frame.minY >= window.bounds.minY - 1)
        #expect(frame.maxX <= window.bounds.maxX + 1)
        #expect(frame.maxY <= window.bounds.maxY + 1)
    }

    func log(_ phase: String) {
        print("[FoldedSessionToggle] \(phase) keyboard=\(keyboardFrame) window=\(window.bounds) firstResponder=\(remoteInput?.isFirstResponder ?? false)")
    }

    func settle() async {
        for _ in 0..<25 {
            hosting.view.setNeedsLayout()
            hosting.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    func close() {
        remoteInput?.deactivate()
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }

    private func findInput(in view: UIView) -> RemoteSoftwareKeyboardInput.InputView? {
        if let input = view as? RemoteSoftwareKeyboardInput.InputView { return input }
        return view.subviews.lazy.compactMap { self.findInput(in: $0) }.first
    }

}
