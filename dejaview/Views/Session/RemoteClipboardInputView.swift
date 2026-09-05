import UIKit

/// Routes the system Paste action to a remote insertion point. Reading the
/// clipboard is confined to UIKit's explicit paste action (Cmd-V/edit menu).
/// Never call paste programmatically from a custom button: use PasteButton.
class RemoteClipboardInputView: UIView {
    var acceptsRemotePaste: Bool { false }

    // Kept at the UI boundary so permission behavior can be checked without
    // touching the user's clipboard in tests.
    var readPasteboardText: () -> String? = { UIPasteboard.general.string }
    var hasPasteboardText: () -> Bool = { UIPasteboard.general.hasStrings }

    func sendPasteText(_ text: String) {}

    override var keyCommands: [UIKeyCommand]? {
        guard acceptsRemotePaste else { return super.keyCommands }
        let paste = UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(paste(_:)))
        paste.discoverabilityTitle = String(localized: "Paste to Mac")
        paste.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [paste]
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            // Checking types is allowed without reading cross-app content.
            return acceptsRemotePaste && hasPasteboardText()
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        guard acceptsRemotePaste,
              let text = readPasteboardText(),
              !text.isEmpty else { return }
        sendPasteText(text)
    }

    func routesThroughSystemPaste(keyCode: UIKeyboardHIDUsage,
                                 modifiers: UIKeyModifierFlags) -> Bool {
        let shortcutModifiers = modifiers.intersection([.command, .control, .alternate, .shift])
        return acceptsRemotePaste && keyCode == .keyboardV && shortcutModifiers == .command
    }
}
