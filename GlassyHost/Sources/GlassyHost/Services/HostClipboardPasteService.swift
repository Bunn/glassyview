import AppKit
import CoreGraphics

/// Runs on the serial remote-input queue. Never reads or monitors either
/// clipboard, and leaves the received text available for subsequent Mac pastes.
struct HostClipboardPasteService: Sendable {
    var writeText: @Sendable (String) -> Bool = { text in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
    var postKey: @Sendable (CGKeyCode, Bool, CGEventFlags) -> Void = { code, isDown, flags in
        guard let event = CGEvent(keyboardEventSource: nil,
                                  virtualKey: code,
                                  keyDown: isDown) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    func paste(_ text: String) {
        guard (1...HostProtocol.maximumClipboardTextLength).contains(text.utf8.count),
              writeText(text) else { return }

        // Use only Command even if the remote shortcut strip holds Shift or
        // Option; those modifiers would turn a plain paste into another action.
        postKey(9, true, .maskCommand) // kVK_ANSI_V
        postKey(9, false, .maskCommand)
    }
}
