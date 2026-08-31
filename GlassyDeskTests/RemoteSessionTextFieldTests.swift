import SwiftUI
import Testing
import UIKit
@testable import GlassyDesk

@MainActor
struct RemoteSessionTextFieldTests {
    @Test
    func focusDelegateUpdatesAreDeferredAndCoalesced() async {
        let focused = BindingBox(false)
        let text = BindingBox("")
        let field = RemoteSessionTextField(
            "Placeholder",
            text: text.binding,
            isFocused: focused.binding,
            onSubmit: {}
        )
        let coordinator = field.makeCoordinator()
        let textField = UITextField()

        for _ in 0..<5 {
            coordinator.textFieldDidBeginEditing(textField)
        }

        #expect(!focused.value)
        #expect(focused.writeCount == 0)

        await waitUntil { focused.value }
        #expect(focused.writeCount == 1)

        for _ in 0..<5 {
            coordinator.textFieldDidEndEditing(textField)
        }

        #expect(focused.value)
        await waitUntil { !focused.value }
        #expect(focused.writeCount == 2)
    }

    @Test
    func cancellingPendingFocusUpdatePreventsLateBindingWrite() async {
        let focused = BindingBox(false)
        let text = BindingBox("")
        let field = RemoteSessionTextField(
            "Placeholder",
            text: text.binding,
            isFocused: focused.binding,
            onSubmit: {}
        )
        let coordinator = field.makeCoordinator()

        coordinator.textFieldDidBeginEditing(UITextField())
        coordinator.cancelPendingFocusUpdate()

        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(!focused.value)
        #expect(focused.writeCount == 0)
    }

    @Test
    func returnSubmitsWithoutChangingFocusBinding() {
        let focused = BindingBox(false)
        let text = BindingBox("")
        let submissionCount = BindingBox(0)
        let field = RemoteSessionTextField(
            "Placeholder",
            text: text.binding,
            isFocused: focused.binding,
            onSubmit: { submissionCount.value += 1 }
        )
        let coordinator = field.makeCoordinator()

        let shouldReturn = coordinator.textFieldShouldReturn(UITextField())

        #expect(!shouldReturn)
        #expect(submissionCount.value == 1)
        #expect(!focused.value)
        #expect(focused.writeCount == 0)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<20 {
            if condition() {
                return
            }

            await Task.yield()
        }
    }
}

private final class BindingBox<Value>: @unchecked Sendable {
    var value: Value
    private(set) var writeCount = 0

    init(_ value: Value) {
        self.value = value
    }

    var binding: Binding<Value> {
        Binding(
            get: { self.value },
            set: { value in
                self.value = value
                self.writeCount += 1
            }
        )
    }
}
