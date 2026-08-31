import SwiftUI

/// A session input field whose Return key submits without resigning focus.
struct RemoteSessionTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    let onSubmit: () -> Void

    init(_ placeholder: String,
         text: Binding<String>,
         isFocused: Binding<Bool>,
         onSubmit: @escaping () -> Void) {
        self.placeholder = placeholder
        _text = text
        _isFocused = isFocused
        self.onSubmit = onSubmit
    }

    func makeUIView(context: Context) -> TextField {
        let textField = TextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.addTarget(context.coordinator,
                            action: #selector(Coordinator.textDidChange(_:)),
                            for: .editingChanged)
        configure(textField)
        return textField
    }

    func updateUIView(_ textField: TextField, context: Context) {
        context.coordinator.parent = self

        if textField.text != text {
            textField.text = text
        }

        configure(textField)
        textField.setFocused(isFocused)
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView textField: TextField,
                      context: Context) -> CGSize? {
        let intrinsicSize = textField.intrinsicContentSize
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }

        return CGSize(width: proposedWidth ?? intrinsicSize.width,
                      height: intrinsicSize.height)
    }

    static func dismantleUIView(_ textField: TextField, coordinator: Coordinator) {
        coordinator.cancelPendingFocusUpdate()
        textField.deactivate()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func configure(_ textField: TextField) {
        textField.placeholder = placeholder
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.borderStyle = .none
        textField.backgroundColor = .clear
        textField.textColor = .label
        textField.tintColor = .tintColor
        textField.setContentHuggingPriority(.required, for: .vertical)
        textField.setContentCompressionResistancePriority(.required, for: .vertical)

        textField.keyboardAppearance = .dark
        textField.keyboardType = .default
        textField.returnKeyType = .default
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.smartDashesType = .no
        textField.smartQuotesType = .no
        textField.smartInsertDeleteType = .no
        textField.inlinePredictionType = .no
        textField.textContentType = nil
    }

    final class TextField: UITextField {
        private var isActive = true
        private var wantsFocus = false
        private var focusTask: Task<Void, Never>?

        override func didMoveToWindow() {
            super.didMoveToWindow()

            if window == nil {
                focusTask?.cancel()
                focusTask = nil
            } else {
                scheduleFocusUpdate()
            }
        }

        func setFocused(_ isFocused: Bool) {
            guard isActive else { return }

            wantsFocus = isFocused
            scheduleFocusUpdate()
        }

        func deactivate() {
            isActive = false
            wantsFocus = false
            focusTask?.cancel()
            focusTask = nil
            delegate = nil

            Task { @MainActor [textField = self] in
                await Task.yield()

                if textField.isFirstResponder {
                    textField.resignFirstResponder()
                }
            }
        }

        private func scheduleFocusUpdate() {
            guard isActive,
                  window != nil,
                  wantsFocus != isFirstResponder,
                  focusTask == nil else {
                return
            }

            focusTask = Task { @MainActor [weak self] in
                await Task.yield()

                guard let self else { return }
                self.focusTask = nil

                guard !Task.isCancelled,
                      self.isActive,
                      self.window != nil else {
                    return
                }

                if self.wantsFocus {
                    guard !self.isFirstResponder else { return }
                    self.becomeFirstResponder()
                } else if self.isFirstResponder {
                    self.resignFirstResponder()
                }
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: RemoteSessionTextField
        private var pendingFocus: Bool?
        private var focusUpdateTask: Task<Void, Never>?

        init(parent: RemoteSessionTextField) {
            self.parent = parent
        }

        @objc func textDidChange(_ textField: UITextField) {
            let updatedText = textField.text ?? ""
            guard parent.text != updatedText else { return }
            parent.text = updatedText
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            reportFocus(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            reportFocus(false)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }

        func cancelPendingFocusUpdate() {
            pendingFocus = nil
            focusUpdateTask?.cancel()
            focusUpdateTask = nil
        }

        private func reportFocus(_ focused: Bool) {
            pendingFocus = focused
            guard focusUpdateTask == nil else { return }

            focusUpdateTask = Task { @MainActor [weak self] in
                await Task.yield()

                guard let self else { return }
                self.focusUpdateTask = nil

                guard !Task.isCancelled,
                      let pendingFocus = self.pendingFocus else {
                    return
                }

                self.pendingFocus = nil
                guard self.parent.isFocused != pendingFocus else { return }
                self.parent.isFocused = pendingFocus
            }
        }
    }
}
