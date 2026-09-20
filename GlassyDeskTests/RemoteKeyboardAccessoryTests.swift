import SwiftUI
import Testing
import UIKit
@testable import GlassyDesk

@MainActor
extension SessionLayoutTests {
    @Test
    func softwareKeyboardAccessoryKeepsItsContentAndResponderAcrossUpdates() async throws {
        let host = try KeyboardAccessoryTestHost()
        defer { host.close() }
        let input = host.input
        let recorder = KeyboardAccessoryRecorder()
        input.setAccessoryContent(AnyView(KeyboardAccessoryProbe(recorder: recorder, value: 0)))

        let accessory = try #require(input.inputAccessoryViewController)
        accessory.loadViewIfNeeded()
        let hosting = try #require(accessory.children.first as? UIHostingController<AnyView>)
        #expect(accessory.children.count == 1)
        #expect(hosting.parent === accessory)
        #expect(hosting.safeAreaRegions.isEmpty)
        #expect(input.inputView == nil)
        #expect(!input.isFirstResponder)

        var streamedText: [String] = []
        input.onInsertText = { streamedText.append($0) }
        input.setFocus(true, request: 1)
        await host.settle()
        #expect(input.isFirstResponder)
        let container = try #require(accessory.view.superview)
        #expect(container.bounds.width > 0)
        #expect(abs(accessory.view.bounds.width - container.bounds.width) < 1)
        #expect(abs(accessory.view.bounds.height - 52) < 1)
        let originalProbe = try #require(recorder.view)
        input.insertText("a")

        for value in 1...5 {
            input.setAccessoryContent(AnyView(KeyboardAccessoryProbe(recorder: recorder, value: value)))
            input.setFocus(true, request: 1)
            await host.settle()
            #expect(input.inputAccessoryViewController === accessory)
            #expect(accessory.children.first === hosting)
            #expect(recorder.view === originalProbe)
            #expect(input.isFirstResponder)
        }
        #expect(recorder.creationCount == 1)
        #expect(originalProbe.text == "5")
        input.insertText("b")
        #expect(streamedText == ["a", "b"])

        input.setFocus(false, request: 1)
        await host.settle()
        #expect(!input.isFirstResponder)
        #expect(input.inputAccessoryViewController === accessory)
        input.setFocus(true, request: 2)
        await host.settle()
        #expect(input.isFirstResponder)
        #expect(input.inputAccessoryViewController === accessory)
        #expect(recorder.creationCount == 1)
    }

    @Test
    func removingAccessoryPreservesSystemInputAndDeactivationCancelsFurtherEntry() async throws {
        let host = try KeyboardAccessoryTestHost()
        defer { host.close() }
        let input = host.input
        input.setAccessoryContent(AnyView(Text("Special keys")))
        input.setFocus(true, request: 1)
        await host.settle()
        #expect(input.isFirstResponder)
        #expect(input.inputAccessoryViewController != nil)

        input.setAccessoryContent(nil)
        await host.settle()
        #expect(input.inputAccessoryViewController == nil)
        #expect(input.inputView == nil)
        #expect(input.isFirstResponder)

        // An accessory replacement may have a deferred UIKit reload pending.
        // Ending the session must cancel it along with further input and focus.
        var streamedText: [String] = []
        input.onInsertText = { streamedText.append($0) }
        input.setAccessoryContent(AnyView(Text("Replacement special keys")))
        input.deactivate()
        input.setAccessoryContent(AnyView(Text("Late special keys")))
        input.setFocus(true, request: 2)
        input.insertText("late")
        await host.settle()
        #expect(input.inputAccessoryViewController == nil)
        #expect(!input.isFirstResponder)
        #expect(!input.canBecomeFirstResponder)
        #expect(streamedText.isEmpty)
    }
}

@MainActor
private final class KeyboardAccessoryRecorder {
    var view: UILabel?
    var creationCount = 0
}

private struct KeyboardAccessoryProbe: UIViewRepresentable {
    let recorder: KeyboardAccessoryRecorder
    let value: Int

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        recorder.creationCount += 1
        recorder.view = label
        return label
    }

    func updateUIView(_ uiView: UILabel, context: Context) {
        uiView.text = String(value)
    }
}

private struct KeyboardAccessoryResponderSurface: UIViewRepresentable {
    let input: RemoteSoftwareKeyboardInput.InputView

    func makeUIView(context: Context) -> RemoteSoftwareKeyboardInput.InputView { input }
    func updateUIView(_ uiView: RemoteSoftwareKeyboardInput.InputView, context: Context) {}
}

@MainActor
private final class KeyboardAccessoryTestHost {
    let window: UIWindow
    let input = RemoteSoftwareKeyboardInput.InputView()
    let hosting: UIHostingController<KeyboardAccessoryResponderSurface>
    private weak var previousKeyWindow: UIWindow?

    init() throws {
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        hosting = UIHostingController(rootView: KeyboardAccessoryResponderSurface(input: input))
        hosting.safeAreaRegions = []
        window.rootViewController = hosting
        window.makeKeyAndVisible()
    }

    func settle() async {
        for _ in 0..<8 {
            hosting.view.setNeedsLayout()
            hosting.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    func close() {
        input.deactivate()
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }
}
