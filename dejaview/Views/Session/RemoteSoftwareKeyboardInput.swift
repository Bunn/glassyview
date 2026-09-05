import SwiftUI

/// A non-rendering input responder that forwards the system keyboard directly
/// to a remote session without keeping a local text buffer.
struct RemoteSoftwareKeyboardInput: UIViewRepresentable {
    let focusRequest: Int
    @Binding var isFocused: Bool
    let onInsertText: (String) -> Void
    let onDeleteBackward: () -> Void
    let onReturn: () -> Void
    var onPasteText: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(isFocused: $isFocused)
    }

    func makeUIView(context: Context) -> InputView {
        let inputView = InputView()
        inputView.onFocusChange = context.coordinator.setFocus(_:)
        update(inputView)
        return inputView
    }

    func updateUIView(_ inputView: InputView, context: Context) {
        context.coordinator.isFocused = $isFocused
        update(inputView)
    }

    static func dismantleUIView(_ inputView: InputView, coordinator: Coordinator) {
        inputView.deactivate()
        coordinator.cancelPendingFocusUpdate()
    }

    private func update(_ inputView: InputView) {
        inputView.onInsertText = onInsertText
        inputView.onDeleteBackward = onDeleteBackward
        inputView.onReturn = onReturn
        inputView.onPasteText = onPasteText
        inputView.setFocus(isFocused, request: focusRequest)
    }

    @MainActor
    final class Coordinator {
        var isFocused: Binding<Bool>
        private var focusUpdateTask: Task<Void, Never>?

        init(isFocused: Binding<Bool>) {
            self.isFocused = isFocused
        }

        func setFocus(_ focused: Bool) {
            focusUpdateTask?.cancel()
            focusUpdateTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                guard self.isFocused.wrappedValue != focused else { return }
                self.isFocused.wrappedValue = focused
            }
        }

        func cancelPendingFocusUpdate() {
            focusUpdateTask?.cancel()
            focusUpdateTask = nil
        }
    }

    final class InputView: RemoteClipboardInputView, UIKeyInput {
        var onInsertText: (String) -> Void = { _ in }
        var onDeleteBackward: () -> Void = {}
        var onReturn: () -> Void = {}
        var onFocusChange: (Bool) -> Void = { _ in }
        var onPasteText: ((String) -> Void)?

        override var acceptsRemotePaste: Bool { onPasteText != nil }

        override func sendPasteText(_ text: String) {
            onPasteText?(text)
        }

        var autocapitalizationType: UITextAutocapitalizationType = .none
        var autocorrectionType: UITextAutocorrectionType = .no
        var spellCheckingType: UITextSpellCheckingType = .no
        var smartQuotesType: UITextSmartQuotesType = .no
        var smartDashesType: UITextSmartDashesType = .no
        var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
        var inlinePredictionType: UITextInlinePredictionType = .no
        var keyboardAppearance: UIKeyboardAppearance = .dark
        var keyboardType: UIKeyboardType = .default
        var returnKeyType: UIReturnKeyType = .default

        override var canBecomeFirstResponder: Bool { true }

        // The remote insertion point may have content even though this local
        // responder does not. Returning true keeps Backspace available.
        var hasText: Bool { true }

        private var latestFocusRequest: Int?
        private var isActive = true
        private var wantsFocus = false
        private var lastReportedFocus: Bool?

        override init(frame: CGRect) {
            super.init(frame: frame)
            configure()
        }

        convenience init() {
            self.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configure()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()

            if window != nil {
                focusWhenPossible()
            } else if isFirstResponder {
                _ = resignFirstResponder()
            }
        }

        override func becomeFirstResponder() -> Bool {
            let becameFirstResponder = super.becomeFirstResponder()

            if becameFirstResponder {
                wantsFocus = true
                reportFocus(true)
            }

            return becameFirstResponder
        }

        override func resignFirstResponder() -> Bool {
            wantsFocus = false
            let resignedFirstResponder = super.resignFirstResponder()

            if resignedFirstResponder {
                reportFocus(false)
            }

            return resignedFirstResponder
        }

        func setFocus(_ focused: Bool, request: Int) {
            let focusRequestChanged = latestFocusRequest != request

            latestFocusRequest = request
            wantsFocus = focused

            if focused {
                if focusRequestChanged || !isFirstResponder {
                    focusWhenPossible()
                }
            } else if isFirstResponder {
                _ = resignFirstResponder()
            }
        }

        func deactivate() {
            isActive = false
            onPasteText = nil
            latestFocusRequest = nil
            wantsFocus = false

            if isFirstResponder {
                _ = resignFirstResponder()
            }
        }

        func insertText(_ text: String) {
            let normalizedText = text
                .replacing("\r\n", with: "\n")
                .replacing("\r", with: "\n")
            guard !normalizedText.isEmpty else { return }

            let segments = normalizedText.split(separator: "\n", omittingEmptySubsequences: false)

            for (index, segment) in segments.enumerated() {
                if !segment.isEmpty {
                    onInsertText(String(segment))
                }

                if index < segments.count - 1 {
                    onReturn()
                }
            }
        }

        func deleteBackward() {
            onDeleteBackward()
        }

        private func configure() {
            backgroundColor = .clear
            isAccessibilityElement = false
            inputAssistantItem.leadingBarButtonGroups = []
            inputAssistantItem.trailingBarButtonGroups = []
        }

        private func focusWhenPossible() {
            guard isActive, wantsFocus, window != nil, !isFirstResponder else { return }

            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self,
                      self.isActive,
                      self.wantsFocus,
                      self.window != nil else {
                    return
                }
                _ = self.becomeFirstResponder()
            }
        }

        private func reportFocus(_ focused: Bool) {
            guard lastReportedFocus != focused else { return }
            lastReportedFocus = focused
            onFocusChange(focused)
        }
    }
}
