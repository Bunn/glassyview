import Testing
import SwiftUI
import UIKit
@testable import GlassyDesk

@MainActor
extension SessionLayoutTests {
    @Test
    func softwareControllerHonorsInitialFocusOnlyAfterItsWindowBecomesKey() async throws {
        let host = try RemoteKeyboardFocusHost(makeKey: false)
        defer { host.close() }
        let input = host.makeSoftwareInput(focused: true)
        await host.settle()
        #expect(!host.window.isKeyWindow)
        #expect(!input.isFirstResponder)

        host.window.makeKeyAndVisible()
        await host.settle()
        #expect(input.isFirstResponder)
        #expect(!host.screen.isFirstResponder)
    }

    @Test
    func softwareControllerNeedsNewIntentAfterMenuWindowDismisses() async throws {
        let host = try RemoteKeyboardFocusHost()
        defer { host.close() }
        let input = host.makeSoftwareInput(focused: true)
        await host.settle()
        #expect(input.isFirstResponder)

        let menu = UIWindow(windowScene: host.scene)
        menu.rootViewController = UIViewController()
        menu.windowLevel = .alert
        menu.makeKeyAndVisible()
        defer { menu.isHidden = true }
        await host.settle()
        #expect(!input.isFirstResponder)

        // A delayed binding update can still contain the previous true value.
        // It must not steal the menu's key window or queue an automatic return.
        input.setFocus(true, request: 0)
        await host.settle()
        #expect(menu.isKeyWindow)
        #expect(!input.isFirstResponder)
        menu.isHidden = true
        host.window.makeKeyAndVisible()
        await host.settle()
        #expect(!input.isFirstResponder)

        input.setFocus(true, request: 1)
        await host.settle()
        #expect(input.isFirstResponder)
        input.setFocus(false, request: 1)
        await host.settle()
        #expect(!input.isFirstResponder)
        input.setFocus(true, request: 1)
        await host.settle()
        #expect(input.isFirstResponder)
    }

    @Test
    func softwareBlurDefersUntilAfterLayoutAndNewShowIntentCancelsIt() async throws {
        let host = try RemoteKeyboardFocusHost()
        defer { host.close() }
        let input = host.makeSoftwareInput(focused: true)
        await host.settle()
        #expect(input.isFirstResponder)

        input.setFocus(false, request: 0)
        #expect(input.isFirstResponder)
        input.setFocus(true, request: 1)
        await host.settle()
        #expect(input.isFirstResponder)

        input.setFocus(false, request: 1)
        #expect(input.isFirstResponder)
        await host.settle()
        #expect(!input.isFirstResponder)
    }

    @Test
    func deactivatedSoftwareControllerCancelsPendingFocusAndLateInput() async throws {
        let host = try RemoteKeyboardFocusHost()
        defer { host.close() }
        let input = host.makeSoftwareInput(focused: false)
        await host.settle()
        var insertedTexts: [String] = []
        var deleteCount = 0
        var returnCount = 0
        input.onInsertText = { insertedTexts.append($0) }
        input.onDeleteBackward = { deleteCount += 1 }
        input.onReturn = { returnCount += 1 }

        input.setFocus(true, request: 1)
        input.deactivate()
        await host.settle()
        input.setFocus(true, request: 2)
        input.insertText("late text\n")
        input.deleteBackward()
        await host.settle()

        #expect(!input.isFirstResponder)
        #expect(!input.canBecomeFirstResponder)
        #expect(insertedTexts.isEmpty)
        #expect(deleteCount == 0)
        #expect(returnCount == 0)
    }

    @Test
    func hardwareFocusDoesNotPresentKeyboardOrResizeViewport() async throws {
        let host = try RemoteKeyboardFocusHost()
        defer { host.close() }
        await host.settle()
        let initialBounds = host.screen.bounds
        host.keyboardEvents.reset()

        host.screen.setAcceptsHardwareKeyboardInput(true)
        await host.settle()

        #expect(host.window.isKeyWindow)
        #expect(host.screen.isFirstResponder)
        #expect(host.screen.bounds == initialBounds)
        #expect(host.keyboardEvents.willShowCount == 0)
        #expect(host.keyboardEvents.didShowCount == 0)
    }

    @Test
    func pointerGatingDoesNotSynchronouslyResignTheHardwareResponder() async throws {
        let host = try RemoteKeyboardFocusHost()
        defer { host.close() }
        host.screen.setAcceptsHardwareKeyboardInput(true)
        await host.settle()
        #expect(host.screen.isFirstResponder)
        let point = CGPoint(x: host.screen.bounds.midX, y: host.screen.bounds.midY)
        #expect(host.screen.point(inside: point, with: nil))

        // SwiftUI can update both gates during fold/keyboard layout. Pointer
        // gating must not force UIKit to resign inside that layout transaction.
        host.screen.setAcceptsHardwareKeyboardInput(false)
        host.screen.setAcceptsPointerInput(false)
        #expect(host.screen.isUserInteractionEnabled)
        #expect(host.screen.isFirstResponder)
        #expect(!host.screen.point(inside: point, with: nil))
        await host.settle()
        #expect(!host.screen.isFirstResponder)

        host.screen.setAcceptsPointerInput(true)
        #expect(host.screen.point(inside: point, with: nil))
        #expect(!host.screen.isFirstResponder)
        host.keyboardEvents.reset()
        host.screen.setAcceptsHardwareKeyboardInput(true)
        await host.settle()
        #expect(host.screen.isFirstResponder)
        #expect(host.keyboardEvents.willShowCount == 0)
        #expect(host.keyboardEvents.didShowCount == 0)
    }

    @Test
    func softwareTextFieldKeepsFocusUntilHardwareFocusIsExplicitlyRequested() async throws {
        let host = try RemoteKeyboardFocusHost()
        defer { host.close() }
        host.screen.setAcceptsHardwareKeyboardInput(true)
        await host.settle()
        #expect(host.screen.isFirstResponder)

        host.screen.setAcceptsHardwareKeyboardInput(false)
        await host.settle()
        #expect(host.textField.becomeFirstResponder())
        await host.settle()
        #expect(host.textField.isFirstResponder)
        #expect(!host.screen.isFirstResponder)

        // An ordinary layout pass must not steal an editor's responder status.
        host.screen.setNeedsLayout()
        await host.settle()
        #expect(host.textField.isFirstResponder)

        host.textField.resignFirstResponder()
        await host.settle()
        host.keyboardEvents.reset()
        host.screen.setAcceptsHardwareKeyboardInput(true)
        await host.settle()
        #expect(host.screen.isFirstResponder)
        #expect(!host.textField.isFirstResponder)
        #expect(host.keyboardEvents.willShowCount == 0)
        #expect(host.keyboardEvents.didShowCount == 0)
    }

    @Test
    func menuWindowPreventsHardwareFocusStealingAndReturningKeyDoesNotReclaimIt() async throws {
        let host = try RemoteKeyboardFocusHost()
        defer { host.close() }
        host.screen.setAcceptsHardwareKeyboardInput(true)
        await host.settle()
        #expect(host.screen.isFirstResponder)

        let menu = UIWindow(windowScene: host.scene)
        menu.rootViewController = UIViewController()
        menu.windowLevel = .alert
        menu.makeKeyAndVisible()
        defer { menu.isHidden = true }
        await host.settle()
        #expect(menu.isKeyWindow)
        #expect(!host.screen.isFirstResponder)

        host.screen.setAcceptsHardwareKeyboardInput(false)
        host.screen.setAcceptsHardwareKeyboardInput(true)
        await host.settle()
        #expect(menu.isKeyWindow)
        #expect(!host.screen.isFirstResponder)

        menu.isHidden = true
        host.window.makeKeyAndVisible()
        await host.settle()
        #expect(host.window.isKeyWindow)
        #expect(!host.screen.isFirstResponder)

        host.keyboardEvents.reset()
        host.screen.setAcceptsHardwareKeyboardInput(false)
        host.screen.setAcceptsHardwareKeyboardInput(true)
        await host.settle()
        #expect(host.screen.isFirstResponder)
        #expect(host.keyboardEvents.willShowCount == 0)
        #expect(host.keyboardEvents.didShowCount == 0)
    }
}

@MainActor
private final class RemoteKeyboardEvents {
    var willShowCount = 0
    var didShowCount = 0

    func reset() {
        willShowCount = 0
        didShowCount = 0
    }
}

@MainActor
private final class RemoteKeyboardFocusHost {
    let scene: UIWindowScene
    let window: UIWindow
    let controller: UIViewController
    let hosting: UIHostingController<RemoteHardwareFocusSurface>
    let screen = RemoteDesktopView<VNCSession>.ScreenView()
    let textField = UITextField()
    let keyboardEvents = RemoteKeyboardEvents()
    private let previousKeyWindow: UIWindow?
    private var observers: [NSObjectProtocol] = []
    private var softwareHosting: UIHostingController<RemoteSoftwareFocusSurface>?

    init(makeKey: Bool = true) throws {
        scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        controller = UIViewController()
        hosting = UIHostingController(rootView: RemoteHardwareFocusSurface(screen: screen))
        hosting.safeAreaRegions = []
        window.rootViewController = controller
        screen.setAcceptsHardwareKeyboardInput(false)
        controller.addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: controller.view.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: controller.view.keyboardLayoutGuide.topAnchor)
        ])
        hosting.didMove(toParent: controller)
        textField.frame = CGRect(x: 20, y: 20, width: 240, height: 44)
        textField.placeholder = "Focus handoff"
        controller.view.addSubview(textField)

        let events = keyboardEvents
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIResponder.keyboardWillShowNotification,
                               object: nil, queue: .main) { [weak events] _ in
                MainActor.assumeIsolated { events?.willShowCount += 1 }
            },
            center.addObserver(forName: UIResponder.keyboardDidShowNotification,
                               object: nil, queue: .main) { [weak events] _ in
                MainActor.assumeIsolated { events?.didShowCount += 1 }
            }
        ]
        if makeKey {
            window.makeKeyAndVisible()
        } else {
            window.isHidden = false
        }
    }

    func makeSoftwareInput(focused: Bool) -> RemoteSoftwareKeyboardInput.InputView {
        let input = RemoteSoftwareKeyboardInput.InputView()
        input.setFocus(focused, request: 0)
        let hosting = UIHostingController(rootView: RemoteSoftwareFocusSurface(input: input))
        hosting.safeAreaRegions = []
        controller.addChild(hosting)
        hosting.view.frame = CGRect(x: 20, y: 80, width: 1, height: 1)
        controller.view.addSubview(hosting.view)
        hosting.didMove(toParent: controller)
        softwareHosting = hosting
        return input
    }

    func settle() async {
        // Allow deferred responder requests and UIKit's keyboard animation to
        // finish before inspecting notification counts and local geometry.
        for _ in 0..<12 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    func close() {
        screen.setAcceptsHardwareKeyboardInput(false)
        screen.resignFirstResponder()
        textField.resignFirstResponder()
        if let softwareHosting {
            softwareHosting.rootView.input.deactivate()
            softwareHosting.willMove(toParent: nil)
            softwareHosting.view.removeFromSuperview()
            softwareHosting.removeFromParent()
            self.softwareHosting = nil
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        window.isHidden = true
        hosting.willMove(toParent: nil)
        hosting.view.removeFromSuperview()
        hosting.removeFromParent()
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }
}

/// Preserve the SwiftUI hosting responder chain used by the real remote view.
private struct RemoteHardwareFocusSurface: UIViewRepresentable {
    let screen: RemoteDesktopView<VNCSession>.ScreenView

    func makeUIView(context: Context) -> RemoteDesktopView<VNCSession>.ScreenView { screen }
    func updateUIView(_ uiView: RemoteDesktopView<VNCSession>.ScreenView, context: Context) {}
}

private struct RemoteSoftwareFocusSurface: UIViewRepresentable {
    let input: RemoteSoftwareKeyboardInput.InputView

    func makeUIView(context: Context) -> RemoteSoftwareKeyboardInput.InputView { input }
    func updateUIView(_ uiView: RemoteSoftwareKeyboardInput.InputView, context: Context) {}
}
