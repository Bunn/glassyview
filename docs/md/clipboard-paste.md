# Paste from iOS to the Mac

Copy text in another iPhone/iPad app, return to the connected remote desktop, and tap **Paste to Mac** beside the keyboard control. With a hardware keyboard, press **Cmd-V** while the desktop has focus. External-display controller mode supports the same action. In the local “Type to send” field, native Paste still inserts text into that local field for editing before sending.

This version supports plain text, including Unicode and multiple lines, up to 1 MiB of UTF-8. It requires Fast Connection and companion support on the Mac. Images, files, rich formatting, and Mac-to-iOS clipboard transfer are outside this feature. The Paste control appears only after a compatible Mac authenticates. Standard VNC keeps its existing keyboard behavior.

## Avoiding permission loops

iOS checks intent when an app reads content copied by another app. Apple's [native paste control and system paste action](https://developer.apple.com/videos/play/wwdc2022/10096/) provide the supported flow for pasting without the extra permission dialog.

- The visible control uses SwiftUI `PasteButton`; its callback receives the text without a separate pasteboard read.
- The desktop and external software-keyboard responder register the standard `paste:` action for Cmd-V. They read the clipboard once, only in that action. Availability checks inspect types with `hasStrings`, not content.
- A denied or empty read ends that action. There is no retry, foreground clipboard read, clipboard-change observer, or clipboard timer.
- RoyalVNC's automatic clipboard redirection stays disabled because it polls clipboard content.

## Transport and host behavior

Protocol v1 advertises `clipboardPaste` at capability bit 6. Message kind `0x24` carries 1–1,048,576 bytes of UTF-8 directly, with no text normalization. The client checks capability support after authentication and again on its network queue. Empty and oversized local content is rejected before sending; oversized input reports an error without closing the connection. Reconnecting clears the capability.

The message uses the existing encrypted, sequenced, client-to-host input channel. Host decoding rejects empty, oversized, and invalid UTF-8 payloads. The remote-input queue applies the existing control-enabled and Accessibility gates, writes `NSPasteboard.general`, then posts the V key down/up with exactly the Command flag. A failed clipboard write never sends the key events. Text is neither logged nor saved to app storage and remains available on the Mac clipboard. There is no clipboard readback or delayed restoration of old contents.

## Verification

Host tests cover authenticated payloads, validation boundaries, exact Unicode/whitespace preservation, failed writes, repeated explicit pastes, and remote-control permission gates. iOS tests cover content-free availability checks, exactly one read/send per paste, no denied-read retries, shortcut routing, external keyboard newline handling, and encrypted loopback transfers to hosts with and without support, including reconnects.

Before release, verify on a physical iPhone/iPad with a compatible Mac build:

1. Copy multiline Unicode text in Notes or Safari, return to Glassy Desk, focus a scratch document on the Mac, and tap Paste. Confirm one exact insertion without a permission prompt.
2. Repeat with Cmd-V, including a second paste of unchanged clipboard content. Confirm there is one insertion per gesture.
3. Deny direct clipboard access in iOS Settings if available. Confirm the native Paste control still works and returning to the app never requests clipboard access.
4. Try empty/non-text clipboard content, reconnecting, and external-display controller mode. Confirm no stale text or delayed paste is sent.
5. Confirm that an older companion and Standard VNC retain normal input and that the new Paste control is absent.
