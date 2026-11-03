# Copy from the Mac to iOS

Copy something on the Mac while you control it, and it's on your iPhone or iPad. There's no button to press: a short "Copied to iPhone" confirmation with a one-line preview appears at the top of the session, with a light tap, and touches keep reaching the Mac underneath it. Switch to any app and paste.

- **Copy from Mac** in the session menu fetches whatever is on the Mac's clipboard right now, such as something a long-running job put there.
- **Copy Automatically** in the same menu turns the automatic behavior off on this device. It's on by default.
- **Allow copying to devices** in the Mac's Settings › Security turns the whole feature off for that Mac.
- **Copied files:** copying files in Finder shows **Get Files**, which uses [file transfer](file-transfer.md) to fetch the files selected in Finder. It's offered only when file transfer is available.

This version carries plain text up to 1 MiB, including Unicode and multiple lines. A lone web address also pastes as a link. Images and rich formatting aren't carried yet. It requires Fast Connection and companion support on the Mac; Standard VNC, older companions, and Glassy Desk for Linux are unaffected. For the other direction, see [paste from iOS to the Mac](clipboard-paste.md).

## What leaves the Mac

The Mac sends only what the controlling device copied:

1. A device follows the clipboard only after asking, and only for its connection. Each new connection asks again. Older clients never ask, so they never receive the new message.
2. While a device follows, the host checks the pasteboard's change count four times a second. The check stops when the last follower leaves. Whatever is already on the clipboard when following starts is not sent.
3. When the count changes, the host looks at the item's types, which macOS allows without a paste alert. Items marked by [nspasteboard.org](https://nspasteboard.org) types such as `org.nspasteboard.ConcealedType`, which password managers set, are never read. Neither is text that just arrived from a device, which carries a private `dev.bunn.glassydesk.from-device` type so it can't bounce back.
4. The host reads the text only if the controlling device sent input in the previous 5 seconds. Copies made by someone at the Mac, by a background app, or by Universal Clipboard stay on the Mac. **Copy from Mac** is the way to get those on purpose, though it never reads private items.
5. The network core re-checks that the recipient still controls the Mac before queuing the message.

Text is neither logged nor saved by either app. On iOS it's written with `localOnly`, because Universal Clipboard would otherwise hand it straight back to a Mac on the same Apple Account, which would see a new copy and send it again.

## macOS paste privacy

macOS can show an alert when an app reads the general pasteboard without a paste from the person using it, and a read made for a remote device doesn't count as one. The person can choose in System Settings › Privacy & Security › Paste from Other Apps.

- **Allow:** copying is silent.
- **Don't Allow** (`accessBehavior == .alwaysDeny`): the host doesn't try. The device explains how to change this, once per connection for automatic copies.
- **Ask:** the alert appears on the Mac and in the stream, and the read waits on the service's own queue until it's answered. Input and video aren't affected. Whether a remote click can answer the alert still needs checking on a physical Mac.

As of November 2026, a `swift` process on macOS 27.2 reported `.alwaysAllow`. Apple's headers describe asking as the default, so don't assume every Mac behaves this way.

## Transport

Protocol v1 advertises `clipboardCopy` at capability bit 10.

| Message | Direction | Payload |
| --- | --- | --- |
| `0x27` `clipboardCopyRequest` | Client → host | `[request, 0, 0, 0]`: 0 stop following, 1 follow, 2 send now |
| `0x28` `clipboardCopy` | Host → client | `[outcome, flags, 0, 0]`, then UTF-8 text for outcome 0 only |

Outcomes are 0 text, 1 empty, 2 files, 3 too large, 4 concealed, 5 not allowed, 6 blocked by macOS, and 7 unsupported. Flag bit 0 marks an automatic copy. The client treats a message from a host that didn't advertise the capability as a protocol violation. Text uses the `bulk` send policy, which keeps it in order and never drops it. Up to 1 MiB can delay video and input on a slow link while it sends.

## Verification

Host tests cover the codec, type classification, the recent-input rule, private and device-sourced items going unread, stopping and disconnecting, the size limit, denial, and every requested outcome. iOS tests cover decoding, malformed payloads, previews, link items, turning automatic copying off, and encrypted loopback transfers to hosts with and without support.

Before release, verify on a physical iPhone or iPad with a compatible Mac build:

1. Copy multiline Unicode text on the Mac with Cmd-C and with a context menu. Switch to Notes and paste. Confirm it's exact, with one toast per copy.
2. Copy a web address and paste it into Safari's address bar and Messages.
3. Copy a password from a password manager. Confirm no toast and that the iOS clipboard is unchanged.
4. Paste from the device to the Mac. Confirm no toast comes back. Repeat with the Mac and device on the same Apple Account with Handoff on, and confirm the copies don't loop.
5. Copy on the Mac's own keyboard while connected, more than 5 seconds after the last remote input. Confirm nothing reaches the device, then use **Copy from Mac** and confirm it does.
6. Set Glassy Desk to Ask and to Don't Allow in Paste from Other Apps, with and without Curtain Mode. Confirm what the alert does and that the session stays responsive.
7. Copy a file in Finder and tap **Get Files**. Reconnect, then confirm automatic copying still works. Confirm a view-only device receives nothing.
