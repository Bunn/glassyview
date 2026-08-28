# Glassy Host

Glassy Host is the macOS companion for Glassy Desk. It advertises an authenticated local service over Bonjour and can capture a selected display with ScreenCaptureKit, encode it as low-latency H.264 with VideoToolbox, and stream frames to paired clients.

## Run

From the repository root:

```sh
./script/build_and_run.sh
```

The script builds and signs `dist/Glassy Host.app`, installs a verified copy at `/Applications/Glassy Host.app`, then opens the installed app. You can also use the repository's Codex **Run** action.

Grant Screen Recording and Accessibility access locally, then leave Glassy Host running. Its lightweight `_glassydesk._tcp` listener remains available without recording the screen. Capture starts automatically after a Glassy Desk device completes the authenticated pairing or resume handshake, then stops five seconds after the final device disconnects. **Start Streaming Continuously** is available as an explicit always-on override.

Connected Glassy Desk devices can request Data Saver (720p/15 FPS/~2 Mbps), Balanced (1080p/30 FPS/~5 Mbps), or Best (up to 4K/60 FPS/~12 Mbps). The host accepts only these bounded presets and reconfigures capture and H.264 encoding without dropping the authenticated session. Because one encoder serves every connected device, the most bandwidth-conscious active request determines the shared stream.

## Verify

```sh
swift test --package-path GlassyHost
./script/build_and_run.sh --verify
```

The package is intentionally separate from the iOS Xcode project so both apps remain independently buildable in the same repository. Glassy Desk discovers the host over Bonjour, authenticates its encrypted video and input session, and disconnects the Glassy session when the iPad app enters the background so idle capture can shut down.

## Signing

The build script prefers an Apple Development identity and uses Keychain for the long-lived pairing credential in that case. If no development identity is installed, it creates an ad-hoc signed app and keeps the 256-bit credential in an owner-only Application Support file. Ad-hoc rebuilds can require Screen Recording permission to be granted again because their signing identity is not stable.
