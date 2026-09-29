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

    /// Hardware Cmd-V normally pastes the Mac's own clipboard, so Cmd-C on the
    /// Mac followed by Cmd-V stays entirely on the Mac. The iOS clipboard is
    /// pushed only when it changed after the last remote copy or paste.
    var tracksRemoteClipboardOwnership: Bool { false }
    var pasteboardChangeCount: () -> Int = { UIPasteboard.general.changeCount }
    private var handledPasteboardChangeCount: Int?

    /// Checking the change count never reads content or triggers a paste prompt.
    var hasFreshLocalClipboard: Bool {
        guard hasPasteboardText() else { return false }
        guard tracksRemoteClipboardOwnership else { return true }
        return pasteboardChangeCount() != handledPasteboardChangeCount
    }

    func noteRemoteClipboardChange() {
        handledPasteboardChangeCount = pasteboardChangeCount()
    }

    override var keyCommands: [UIKeyCommand]? {
        guard acceptsRemotePaste, hasFreshLocalClipboard else { return super.keyCommands }
        let paste = UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(paste(_:)))
        paste.discoverabilityTitle = String(localized: "Paste to Mac")
        paste.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [paste]
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            // Checking types is allowed without reading cross-app content.
            return acceptsRemotePaste && hasFreshLocalClipboard
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        guard acceptsRemotePaste,
              let text = readPasteboardText(),
              !text.isEmpty else { return }
        noteRemoteClipboardChange()
        sendPasteText(text)
    }

    func routesThroughSystemPaste(keyCode: UIKeyboardHIDUsage,
                                 modifiers: UIKeyModifierFlags) -> Bool {
        let shortcutModifiers = modifiers.intersection([.command, .control, .alternate, .shift])
        return acceptsRemotePaste && hasFreshLocalClipboard
            && keyCode == .keyboardV && shortcutModifiers == .command
    }
}
