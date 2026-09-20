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
    // The responder stays nongeneric so its UIKit identity does not depend on
    // whether an accessory is available in the current presentation.
    var accessoryContent: AnyView?

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
        inputView.setAccessoryContent(accessoryContent)
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

        override var canBecomeFirstResponder: Bool { isActive }

        override var inputAccessoryViewController: UIInputViewController? {
            accessoryController
        }

        // The remote insertion point may have content even though this local
        // responder does not. Returning true keeps Backspace available.
        var hasText: Bool { true }

        private var latestFocusRequest: Int?
        private var isActive = true
        private var wantsFocus = false
        private var requestedFocus = false
        private var hasPendingFocusRequest = false
        private var lastReportedFocus: Bool?
        private var focusTask: Task<Void, Never>?
        private var accessoryController: RemoteKeyboardAccessoryController?
        private var accessoryReloadTask: Task<Void, Never>?
        private var keyWindowObservers: [NotificationObserver] = []

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

            registerKeyWindowObservers()
            if window != nil {
                focusWhenPossible()
            } else {
                cancelFocusTask()
                if isFirstResponder {
                    _ = resignFirstResponder()
                }
            }
        }

        override func becomeFirstResponder() -> Bool {
            guard isActive, window?.isKeyWindow == true else { return false }
            let becameFirstResponder = super.becomeFirstResponder()

            if becameFirstResponder {
                wantsFocus = true
                hasPendingFocusRequest = false
                reportFocus(true)
            }

            return becameFirstResponder
        }

        override func resignFirstResponder() -> Bool {
            cancelFocusTask()
            cancelAccessoryReload()
            wantsFocus = false
            hasPendingFocusRequest = false
            let resignedFirstResponder = super.resignFirstResponder()

            if resignedFirstResponder {
                reportFocus(false)
            }

            return resignedFirstResponder
        }

        func setAccessoryContent(_ content: AnyView?) {
            guard isActive else { return }
            let previouslyHadAccessory = accessoryController != nil
            if let content {
                if let accessoryController {
                    accessoryController.updateContent(content)
                } else {
                    accessoryController = RemoteKeyboardAccessoryController(content: content)
                }
            } else {
                accessoryController = nil
            }

            // Binding and session updates only update the retained SwiftUI host.
            // Reload UIKit's input views only when the accessory is added/removed.
            guard previouslyHadAccessory != (accessoryController != nil) else { return }
            cancelAccessoryReload()
            guard isFirstResponder else { return }
            accessoryReloadTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                self.accessoryReloadTask = nil
                guard self.isActive, self.isFirstResponder else { return }
                self.reloadInputViews()
            }
        }

        func setFocus(_ focused: Bool, request: Int) {
            guard isActive else { return }
            let focusRequestChanged = latestFocusRequest != request
            let focusIntentChanged = requestedFocus != focused

            latestFocusRequest = request
            requestedFocus = focused

            if focused {
                // Repeated SwiftUI updates aren't permission to reclaim focus
                // from a menu or another editor. A new request or explicit
                // false-to-true intent is needed after losing the responder.
                if focusRequestChanged || focusIntentChanged {
                    cancelFocusTask()
                    wantsFocus = true
                    hasPendingFocusRequest = true
                }
                focusWhenPossible()
            } else {
                cancelFocusTask()
                wantsFocus = false
                hasPendingFocusRequest = false
                blurWhenPossible()
            }
        }

        func deactivate() {
            isActive = false
            cancelFocusTask()
            cancelAccessoryReload()
            keyWindowObservers.removeAll()
            onPasteText = nil
            latestFocusRequest = nil
            wantsFocus = false
            requestedFocus = false
            hasPendingFocusRequest = false

            if isFirstResponder {
                _ = resignFirstResponder()
            }
            accessoryController = nil
        }

        func insertText(_ text: String) {
            guard isActive else { return }
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
            guard isActive else { return }
            onDeleteBackward()
        }

        private func configure() {
            backgroundColor = .clear
            isAccessibilityElement = false
            inputAssistantItem.leadingBarButtonGroups = []
            inputAssistantItem.trailingBarButtonGroups = []
        }

        private func focusWhenPossible() {
            guard isActive, wantsFocus, hasPendingFocusRequest,
                  window?.isKeyWindow == true else { return }
            guard !isFirstResponder else {
                hasPendingFocusRequest = false
                return
            }
            guard focusTask == nil else { return }

            focusTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.focusTask = nil
                guard self.isActive, self.wantsFocus,
                      self.hasPendingFocusRequest,
                      self.window?.isKeyWindow == true,
                      !self.isFirstResponder else {
                    return
                }
                _ = self.becomeFirstResponder()
            }
        }

        private func cancelFocusTask() {
            focusTask?.cancel()
            focusTask = nil
        }

        private func blurWhenPossible() {
            guard isFirstResponder else { return }
            // A binding update may arrive during SwiftUI/keyboard layout.
            // Resign after that transaction, just as we defer becoming focused.
            focusTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.focusTask = nil
                guard self.isActive, !self.wantsFocus, self.isFirstResponder else { return }
                _ = self.resignFirstResponder()
            }
        }

        private func cancelAccessoryReload() {
            accessoryReloadTask?.cancel()
            accessoryReloadTask = nil
        }

        private func registerKeyWindowObservers() {
            keyWindowObservers.removeAll()
            guard isActive, let window else { return }
            let center = NotificationCenter.default
            keyWindowObservers = [
                NotificationObserver(center.addObserver(forName: UIWindow.didBecomeKeyNotification,
                                                        object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        // Honor an initial or explicit request that was made
                        // before its window became key, never a focus loss.
                        self?.focusWhenPossible()
                    }
                }),
                NotificationObserver(center.addObserver(forName: UIWindow.didResignKeyNotification,
                                                        object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.cancelFocusTask()
                        self.wantsFocus = false
                        self.hasPendingFocusRequest = false
                        self.blurWhenPossible()
                    }
                })
            ]
        }

        private final class NotificationObserver: @unchecked Sendable {
            private let token: NSObjectProtocol
            init(_ token: NSObjectProtocol) { self.token = token }
            deinit { NotificationCenter.default.removeObserver(token) }
        }

        deinit {
            focusTask?.cancel()
            accessoryReloadTask?.cancel()
        }

        private func reportFocus(_ focused: Bool) {
            guard lastReportedFocus != focused else { return }
            lastReportedFocus = focused
            onFocusChange(focused)
        }
    }
}
