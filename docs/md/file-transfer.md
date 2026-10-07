# File transfer

During a Fast Connection session, the **Files** section of Session Options sends files between the iPhone or iPad and the Mac:

- **Send Files to Mac…** opens the Files picker. **Send Photos to Mac…** opens the Photos picker. On iPad, files can also be dragged onto the remote desktop.
- **Get Selected Files from Mac** sends the files selected in the Mac's frontmost Finder window. Select them on the streamed desktop first.

The Mac saves received files in **Downloads** under a unique name (`Report.pdf`, `Report 2.pdf`, …) and bounces the Downloads stack. The device saves received files in **Files › On My iPhone/iPad › Glassy Desk › From Mac**; each finished row offers Share and Show in Files. A floating panel shows progress, cancellation, and results.

Standard VNC does not support file transfer. The Files section appears only when the connected Mac advertises the capability and this device controls the Mac. View-only devices cannot start transfers.

## Mac companion behavior

- **Glassy Desk Settings › Security › Allow file transfers** turns the feature off. Offers and requests are then declined with an explanation.
- Getting the Finder selection uses Apple Events. The first request shows macOS's "control Finder" prompt on the Mac, which a remote viewer can answer on the streamed screen. Reading files in Desktop, Documents, or Downloads, and the first save to Downloads, may show the usual Files and Folders prompts. The companion declares `NSAppleEventsUsageDescription` and the hardened-runtime `com.apple.security.automation.apple-events` entitlement.
- Folders and packages are skipped; compress them in Finder first. A request sends at most 20 files.
- The Mac keeps 512 MB free and declines files that would not fit. The device keeps 256 MB free.

## Protocol

Protocol v1 advertises `fileTransfer` at capability bit 8. Neither side sends these messages to a peer without the capability, so older clients and hosts are unaffected. All payloads travel inside the existing encrypted, sequenced session; integers are big-endian. Every message starts with a 16-byte transfer or request identifier chosen by its sender.

| Kind | Name | Direction | Payload after the identifier |
| --- | --- | --- | --- |
| `0x30` | offer | sender → receiver | UInt64 size (≤ 64 GiB), UInt16-prefixed UTF-8 name (1–255 bytes) |
| `0x31` | chunk | sender → receiver | UInt64 offset, 1–32,768 data bytes |
| `0x32` | acknowledge | receiver → sender | UInt64 total bytes written |
| `0x33` | complete | sender → receiver | 32-byte SHA-256 of the whole file |
| `0x34` | result | either | UInt8 status, UInt16-prefixed UTF-8 detail (≤ 1,024 bytes) |
| `0x35` | request | device → Mac | UInt8 source (`1` = Finder selection) |

Statuses: `0` completed, `1` cancelled, `2` declined, `3` failed, `4` integrity failure, `5` disabled, `6` permission required, `7` nothing selected, `8` unsupported item, `9` insufficient space, `10` too large.

A transfer runs: offer → acknowledge(0) to accept, or result to decline → chunks in order → complete → result. The sender keeps at most four chunks (128 KiB) unacknowledged, so file data never builds a backlog ahead of input or video; acknowledgements grant more credit. The receiver writes to a private temporary file, requires each chunk at the expected offset, and moves the file into place only when its length and SHA-256 match; otherwise it replies with an integrity failure and deletes the partial file. Either side may send a cancelled result at any time. Names are reduced to one path component without separators, control characters, or a leading dot.

A request is answered with zero or more offers followed by a result for the request identifier. The device accepts offers only while one of its requests is open.

On the Mac, the network core forwards file messages in receive order to `HostFileTransferService`, which keeps one `FileTransferEngine` per connection. Offers and requests are accepted only from the connection that owns input. Chunks, offers, and completions use a FIFO `bulk` send policy that is never dropped; acknowledgements and results use the control policy and pass pending media. On iOS, file messages bypass the main actor and go straight from the media callback queue to the engine, preserving order.

`FileTransferWire.swift` and `FileTransferEngine.swift` are compiled into both apps. Keep the copies in `dejaview/Services/FileTransfer/` and `GlassyHost/Sources/GlassyHost/FileTransfer/` identical; `sharedFileTransferSourcesMatch` fails if they differ.

## Limits

Transfers belong to one connection. Leaving Glassy Desk, losing the network, or reconnecting fails unfinished transfers and deletes partial files; send them again afterward. Keep Glassy Desk open (or in Picture in Picture) while large files transfer.

## Verification

Host tests cover the wire format, kind mapping, name sanitization, the shared-source check, multi-chunk and empty transfers with flow control, corruption, decline, cancel, disconnect, folders, input-owner gating, the Allow setting, Downloads naming, and Finder requests (offers precede the request result). iOS tests cover uploads, solicited downloads into the Files folder, unsolicited offers, request messages, disconnects, and negotiation in both directions over an encrypted loopback connection.

Before release, verify with a physical device and a signed companion build:

1. Send a large video from Photos, a document from Files, and (on iPad) a dragged file. Confirm Downloads naming and the Dock bounce.
2. Select several files and a folder in Finder, then Get Selected Files. Accept the Automation prompt on the stream. Confirm the files open from Files and the folder is reported as skipped.
3. Cancel from the device during a large upload and download; confirm no partial files remain on either side.
4. Turn off Allow file transfers on the Mac and confirm both directions are declined with an explanation.
5. Connect a second device as view-only and confirm the Files section is hidden.
