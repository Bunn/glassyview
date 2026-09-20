import Observation
import SwiftUI
import Testing
import UIKit
@testable import GlassyDesk

@MainActor
extension SessionLayoutTests {
    /// Runtime diagnostic: use the Simulator's current fold pose. A synthetic
    /// division cannot reproduce the keyboard host's hardware-region behavior.
    @Test
    func foldedControllerKeyboardPresentationProbe() async throws {
        var stockPresentedKeyboard = false
        for kind in FoldedKeyboardProbeKind.allCases {
            let host = try FoldedKeyboardProbeHost(kind: kind)
            defer { host.close() }
            await host.settle(milliseconds: 200)
            let remoteInput = try #require(host.remoteInput)
            let trackpad = try #require(host.remoteTrackpad)
            let remoteInputID = ObjectIdentifier(remoteInput)
            let originalFocusCallback = remoteInput.onFocusChange
            remoteInput.onFocusChange = { focused in
                print("[FoldedKeyboardProbe] \(kind.rawValue) remote focus=\(focused) id=\(remoteInputID)")
                originalFocusCallback(focused)
            }
            host.log("before focus")
            let originalControlsFrame = try #require(host.controlsFrameInWindow)

            #expect(!host.model.wantsRemoteFocus)
            #expect(!remoteInput.isFirstResponder)
            #expect(trackpad.isFirstResponder)
            #expect(!host.hasVisibleKeyboard)
            #expect(host.disabledInputAncestors.isEmpty)

            switch kind {
            case .stock:
                let field = try #require(host.recorder.stockField)
                #expect(field.becomeFirstResponder())
            case .remote:
                host.model.wantsRemoteFocus = true
            }

            await host.settle(milliseconds: 1_000)
            host.log("after one second")
            #expect(host.window.isKeyWindow)
            #expect(host.remoteInput === remoteInput)
            #expect(host.remoteTrackpad === trackpad)
            switch kind {
            case .stock:
                #expect(host.recorder.stockField?.isFirstResponder == true)
                #expect(!remoteInput.isFirstResponder)
                #expect(!trackpad.isFirstResponder)
                stockPresentedKeyboard = host.hasVisibleKeyboard
            case .remote:
                #expect(host.model.wantsRemoteFocus)
                #expect(remoteInput.isFirstResponder)
                #expect(!trackpad.isFirstResponder)
                #expect(host.disabledInputAncestors.isEmpty)
                // Hardware-keyboard settings can intentionally suppress both
                // keyboards. Compare against the stock control in this run.
                if stockPresentedKeyboard {
                    #expect(host.hasVisibleKeyboard)
                    #expect(host.recorder.didShowCount > 0)
                    try host.checkAttachedAccessorySize()
                }

                // Resize the actual keyboard-aware arrangement at asymmetric
                // local origins. This covers live keyboard delivery, not a
                // synthetic safe-area inset or physical device rotation.
                for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                    host.model.direction = direction
                    for insets in [EdgeInsets(top: 11, leading: 23, bottom: 0, trailing: 7),
                                   EdgeInsets(top: 29, leading: 5, bottom: 0, trailing: 31)] {
                        host.model.containerInsets = insets
                        await host.settle(milliseconds: 200)
                        #expect(host.remoteInput === remoteInput)
                        #expect(host.remoteTrackpad === trackpad)
                        #expect(remoteInput.isFirstResponder)
                        #expect(!trackpad.isFirstResponder)
                        #expect(host.disabledInputAncestors.isEmpty)
                        if stockPresentedKeyboard { #expect(host.hasVisibleKeyboard) }
                    }
                }
                host.model.containerInsets = EdgeInsets()
                host.model.direction = .leftToRight
                await host.settle(milliseconds: 200)

                host.model.wantsRemoteFocus = false
                await host.settle(milliseconds: 1_000)
                host.log("after hiding")
                #expect(!host.model.wantsRemoteFocus)
                #expect(!remoteInput.isFirstResponder)
                #expect(trackpad.isFirstResponder)
                #expect(!host.hasVisibleKeyboard)
                #expect(remoteInput.inputAccessoryViewController?.viewIfLoaded?.window == nil)
                #expect(host.controlsFrameInWindow == originalControlsFrame)
                #expect(host.remoteInput === remoteInput)
                #expect(host.remoteTrackpad === trackpad)
                #expect(host.disabledInputAncestors.isEmpty)

                // Ordinary layout passes must not undo the user's hide action.
                let hiddenShowCount = host.recorder.didShowCount
                await host.settle(milliseconds: 200)
                #expect(!host.model.wantsRemoteFocus)
                #expect(!remoteInput.isFirstResponder)
                #expect(trackpad.isFirstResponder)
                #expect(!host.hasVisibleKeyboard)
                #expect(remoteInput.inputAccessoryViewController?.viewIfLoaded?.window == nil)
                #expect(host.controlsFrameInWindow == originalControlsFrame)
                #expect(host.recorder.didShowCount == hiddenShowCount)

                // A same-window sheet disables hardware forwarding even though
                // the containing window remains key. Restoring eligibility must
                // restore hardware focus without opening the software keyboard.
                host.model.allowsHardwareKeyboardInput = false
                await host.settle(milliseconds: 200)
                #expect(host.window.isKeyWindow)
                #expect(!trackpad.isFirstResponder)
                #expect(!remoteInput.isFirstResponder)
                #expect(!host.model.wantsRemoteFocus)
                #expect(!host.hasVisibleKeyboard)
                #expect(remoteInput.inputAccessoryViewController?.viewIfLoaded?.window == nil)
                #expect(host.controlsFrameInWindow == originalControlsFrame)
                #expect(host.remoteInput === remoteInput)
                #expect(host.remoteTrackpad === trackpad)
                #expect(host.disabledInputAncestors.isEmpty)

                host.model.allowsHardwareKeyboardInput = true
                await host.settle(milliseconds: 200)
                #expect(trackpad.isFirstResponder)
                #expect(!remoteInput.isFirstResponder)
                #expect(!host.model.wantsRemoteFocus)
                #expect(!host.hasVisibleKeyboard)
                #expect(remoteInput.inputAccessoryViewController?.viewIfLoaded?.window == nil)
                #expect(host.controlsFrameInWindow == originalControlsFrame)
                #expect(host.recorder.didShowCount == hiddenShowCount)

                host.model.wantsRemoteFocus = true
                await host.settle(milliseconds: 1_000)
                host.log("after reopening")
                #expect(host.model.wantsRemoteFocus)
                #expect(remoteInput.isFirstResponder)
                #expect(!trackpad.isFirstResponder)
                #expect(host.remoteInput === remoteInput)
                #expect(host.remoteTrackpad === trackpad)
                #expect(host.disabledInputAncestors.isEmpty)
                if stockPresentedKeyboard {
                    #expect(host.hasVisibleKeyboard)
                    #expect(host.recorder.didShowCount > hiddenShowCount)
                    try host.checkAttachedAccessorySize()
                }
            }

            remoteInput.onFocusChange = originalFocusCallback
            host.close()
            await host.settle(milliseconds: 300)
        }
    }
}

private enum FoldedKeyboardProbeKind: String, CaseIterable {
    // Run the standard control first so its evidence survives a remote-input hang.
    case stock, remote
}

@MainActor
@Observable
private final class FoldedKeyboardProbeModel {
    var wantsRemoteFocus = false
    var allowsHardwareKeyboardInput = true
    var direction = LayoutDirection.leftToRight
    var containerInsets = EdgeInsets()
    var heldModifiers: Set<RemoteModifierKey> = []
    var zoomScale: CGFloat = 1
}

@MainActor
private final class FoldedKeyboardProbeRecorder {
    var stockField: UITextField?
    var controlsView: UIView?
    var separationChanges: [Bool] = []
    var willShowCount = 0
    var didShowCount = 0
    var willHideCount = 0
    var didHideCount = 0
    var frameChangeCount = 0
    var lastNotificationFrame: CGRect?
}

private struct FoldedKeyboardProbeFixture: View {
    let kind: FoldedKeyboardProbeKind
    let model: FoldedKeyboardProbeModel
    let recorder: FoldedKeyboardProbeRecorder
    let session: SessionLayoutRemoteSession

    var body: some View {
        SessionArrangement(onSeparationChange: { separated in
            recorder.separationChanges.append(separated)
            print("[FoldedKeyboardProbe] \(kind.rawValue) separated=\(separated)")
        }) {
            SessionRemoteContent(session: session, reconnectState: nil,
                                 zoomScale: Binding(get: { model.zoomScale }, set: { model.zoomScale = $0 }),
                                 followsCursor: true,
                                 acceptsHardwareKeyboardInput: false,
                                 acceptsPointerInput: false,
                                 touchModeOverride: .trackpad)
        } controls: {
            VStack(spacing: 4) {
                // Include a small controls row while keeping the production
                // controller and its responder subtree intact.
                Color.clear.frame(height: 44)
                ExternalSessionControllerView(
                    session: session,
                    sessionTitle: "Keyboard presentation probe",
                    heldModifierKeys: Binding(get: { model.heldModifiers }, set: { model.heldModifiers = $0 }),
                    isKeyboardFocused: Binding(get: { model.wantsRemoteFocus }, set: { model.wantsRemoteFocus = $0 }),
                    stopControllerMode: {}, presentation: .folded,
                    allowsHardwareKeyboardInput: model.allowsHardwareKeyboardInput
                )
                .overlay(alignment: .bottom) {
                    if kind != .remote {
                        FoldedStockTextField(recorder: recorder)
                            .frame(width: 1, height: 1)
                            .accessibilityHidden(true)
                    }
                }
            }
            .background { FoldedKeyboardPaneProbe(recorder: recorder) }
        }
        .padding(model.containerInsets)
        .environment(\.layoutDirection, model.direction)
        .background { Color.black.ignoresSafeArea() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
    }
}

private struct FoldedStockTextField: UIViewRepresentable {
    let recorder: FoldedKeyboardProbeRecorder

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.keyboardAppearance = .dark
        field.textColor = .clear
        field.tintColor = .clear
        recorder.stockField = field
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {}
}

private struct FoldedKeyboardPaneProbe: UIViewRepresentable {
    let recorder: FoldedKeyboardProbeRecorder

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        recorder.controlsView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

@MainActor
private final class FoldedKeyboardProbeHost {
    let kind: FoldedKeyboardProbeKind
    let window: UIWindow
    let hosting: UIHostingController<FoldedKeyboardProbeFixture>
    let model = FoldedKeyboardProbeModel()
    let recorder = FoldedKeyboardProbeRecorder()
    private let previousKeyWindow: UIWindow?
    private var observers: [NSObjectProtocol] = []
    private var isClosed = false

    init(kind: FoldedKeyboardProbeKind) throws {
        self.kind = kind
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        hosting = UIHostingController(rootView: FoldedKeyboardProbeFixture(
            kind: kind, model: model, recorder: recorder, session: try SessionLayoutRemoteSession()
        ))
        window.rootViewController = hosting
        let recorder = recorder
        let notifications = [UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification,
                             UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification,
                             UIResponder.keyboardWillChangeFrameNotification]
        observers = notifications.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                MainActor.assumeIsolated {
                    switch name {
                    case UIResponder.keyboardWillShowNotification: recorder.willShowCount += 1
                    case UIResponder.keyboardDidShowNotification: recorder.didShowCount += 1
                    case UIResponder.keyboardWillHideNotification: recorder.willHideCount += 1
                    case UIResponder.keyboardDidHideNotification: recorder.didHideCount += 1
                    default: recorder.frameChangeCount += 1
                    }
                    recorder.lastNotificationFrame = frame
                    print("[FoldedKeyboardProbe] \(kind.rawValue) \(name.rawValue) frame=\(String(describing: frame))")
                }
            }
        }
        window.makeKeyAndVisible()
    }

    var remoteInput: RemoteSoftwareKeyboardInput.InputView? {
        findInput(in: hosting.view)
    }

    var remoteTrackpad: RemoteDesktopView<SessionLayoutRemoteSession>.ScreenView? {
        findTrackpad(in: hosting.view)
    }

    var controlsFrameInWindow: CGRect? {
        recorder.controlsView.map { $0.convert($0.bounds, to: window) }
    }

    var hasVisibleKeyboard: Bool {
        // iOS 26 can retain the accessory height in keyboardLayoutGuide after
        // didHide, even after the accessory detaches and layout fully restores.
        // Once a keyboard event exists, use its public screen-coordinate frame.
        if let frame = recorder.lastNotificationFrame, let scene = window.windowScene {
            let windowFrame = window.convert(frame, from: scene.screen.coordinateSpace)
            let localFrame = hosting.view.convert(windowFrame, from: window)
            let visible = localFrame.intersection(hosting.view.bounds)
            return !visible.isNull && visible.width > 1 && visible.height > 1
        }
        let visible = hosting.view.keyboardLayoutGuide.layoutFrame.intersection(hosting.view.bounds)
        return !visible.isNull && visible.height > hosting.view.safeAreaInsets.bottom + 1
    }

    func checkAttachedAccessorySize() throws {
        let accessory = try #require(remoteInput?.inputAccessoryViewController?.viewIfLoaded)
        let container = try #require(accessory.superview)
        #expect(accessory.window != nil)
        #expect(container.bounds.width > 0)
        #expect(abs(accessory.bounds.width - container.bounds.width) < 1)
        #expect(abs(accessory.bounds.height - 52) < 1)
    }

    var disabledInputAncestors: [String] {
        var disabled: [String] = []
        var view: UIView? = remoteInput
        while let current = view {
            if !current.isUserInteractionEnabled {
                disabled.append(String(describing: type(of: current)))
            }
            view = current.superview
        }
        return disabled
    }

    func settle(milliseconds: Int) async {
        for _ in 0..<(milliseconds / 40) {
            hosting.view.setNeedsLayout()
            hosting.view.layoutIfNeeded()
            if model.wantsRemoteFocus && !isClosed {
                // A fully covered controls pane may be zero sized. Disabling
                // its responder during keyboard layout re-enters UIKit's
                // keyboard dismissal and can prevent the animation completing.
                #expect(disabledInputAncestors.isEmpty)
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    func log(_ phase: String) {
        let input = remoteInput
        let inputFrame = input.map { $0.convert($0.bounds, to: window) }
        let stockFrame = recorder.stockField.map { $0.convert($0.bounds, to: window) }
        print("[FoldedKeyboardProbe] \(kind.rawValue) \(phase) key=\(window.isKeyWindow) remoteFirst=\(input?.isFirstResponder ?? false) stockFirst=\(recorder.stockField?.isFirstResponder ?? false) remoteFrame=\(String(describing: inputFrame)) stockFrame=\(String(describing: stockFrame)) controlsFrame=\(String(describing: controlsFrameInWindow)) window=\(window.bounds) host=\(hosting.view.bounds) safe=\(hosting.view.safeAreaInsets) keyboardGuide=\(hosting.view.keyboardLayoutGuide.layoutFrame) visible=\(hasVisibleKeyboard) show=\(recorder.willShowCount)/\(recorder.didShowCount) hide=\(recorder.willHideCount)/\(recorder.didHideCount) frameChanges=\(recorder.frameChangeCount) separated=\(recorder.separationChanges) disabledAncestors=\(disabledInputAncestors)")
        if let accessory = input?.inputAccessoryViewController, accessory.isViewLoaded {
            let accessoryView = accessory.view!
            let accessoryWindow = accessoryView.window
            let accessoryFrame = accessoryWindow.map { accessoryView.convert(accessoryView.bounds, to: $0) }
            var ancestors: [String] = []
            var current: UIView? = accessoryView
            while let view = current {
                ancestors.append("\(type(of: view)) frame=\(view.frame) bounds=\(view.bounds) hidden=\(view.isHidden) alpha=\(view.alpha) clips=\(view.clipsToBounds)")
                current = view.superview
            }
            print("[FoldedKeyboardProbeAccessory] \(kind.rawValue) \(phase) window=\(String(describing: accessoryWindow)) frameInAccessoryWindow=\(String(describing: accessoryFrame)) lastKeyboardFrame=\(String(describing: recorder.lastNotificationFrame)) ancestors=\(ancestors)")
        } else {
            print("[FoldedKeyboardProbeAccessory] \(kind.rawValue) \(phase) accessory not loaded")
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        recorder.stockField?.resignFirstResponder()
        remoteInput?.deactivate()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }

    private func findInput(in view: UIView) -> RemoteSoftwareKeyboardInput.InputView? {
        if let input = view as? RemoteSoftwareKeyboardInput.InputView { return input }
        return view.subviews.lazy.compactMap { self.findInput(in: $0) }.first
    }

    private func findTrackpad(in view: UIView) -> RemoteDesktopView<SessionLayoutRemoteSession>.ScreenView? {
        // Both native responders stay enabled. The fixture's desktop renders a
        // framebuffer on black; its non-rendering trackpad has a clear background.
        if let trackpad = view as? RemoteDesktopView<SessionLayoutRemoteSession>.ScreenView,
           trackpad.backgroundColor == .clear {
            return trackpad
        }
        return view.subviews.lazy.compactMap { self.findTrackpad(in: $0) }.first
    }
}
