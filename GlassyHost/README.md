# Glassy Host

Glassy Host is the macOS companion for Glassy Desk. It advertises an authenticated local service over Bonjour and can capture a selected display with ScreenCaptureKit, encode it as low-latency H.264 with VideoToolbox, and stream frames to paired clients.

## Run

From the repository root:

```sh
./script/build_and_run.sh
```

The script builds and signs `dist/Glassy Host.app`, then opens it. You can also use the repository's Codex **Run** action.

Grant Screen Recording access when macOS asks, choose a display, and select **Start Streaming**. The host advertises `_glassydesk._tcp` while it is running; video is sent only after the versioned pairing handshake succeeds.

## Verify

```sh
swift test --package-path GlassyHost
./script/build_and_run.sh --verify
```

The package is intentionally separate from the iOS Xcode project so both apps remain independently buildable in the same repository. The current iOS app can discover Glassy Host but does not yet implement the matching H.264 client/decoder, so end-to-end Glassy Desk sessions still use VNC until that client work is added.

## Signing

The build script prefers an Apple Development identity and uses Keychain for the long-lived pairing credential in that case. If no development identity is installed, it creates an ad-hoc signed app and keeps the 256-bit credential in an owner-only Application Support file. Ad-hoc rebuilds can require Screen Recording permission to be granted again because their signing identity is not stable.
