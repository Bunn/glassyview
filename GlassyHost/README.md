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

## Connect remotely with Tailscale

Tailscale provides a private route to a remote Mac without exposing Glassy Host to the public internet:

1. Install Tailscale on the Mac and iPad, sign in to the same tailnet, and confirm both devices appear online.
2. Install and run the same current Glassy Desk/Glassy Host version on both devices. Leave Glassy Host running and grant its Screen Recording and Accessibility permissions.
3. In Tailscale on the Mac, copy the Mac's MagicDNS name or `100.x.y.z` address.
4. In Glassy Desk, edit the saved Mac, select **Glassy Stream**, enter that Tailscale name or address, and use TCP port `51515`.
5. Connect and enter the pairing code currently shown by Glassy Host on that remote Mac. The code must come from the Mac whose Tailscale address you entered.

The nearby-host picker uses Bonjour, which normally discovers only Macs on the iPad's local network. A remote Tailscale Mac is therefore not expected to appear in that list; connect with its saved address instead. Do not configure router port forwarding or expose port `51515` publicly.

If the direct connection cannot be established, verify that both devices still show as online in the same tailnet, that the tailnet's access-control policy permits the iPad to reach the Mac on TCP `51515`, and that the macOS firewall allows the current Glassy Host app. Rebuilding or replacing only one side can also produce protocol or authentication errors, so deploy compatible Glassy Desk and Glassy Host builds together.

## Verify

```sh
swift test --package-path GlassyHost
./script/build_and_run.sh --verify
```

The package is intentionally separate from the iOS Xcode project so both apps remain independently buildable in the same repository. Glassy Desk discovers the host over Bonjour, authenticates its encrypted video and input session, and disconnects the Glassy session when the iPad app enters the background so idle capture can shut down.

## Signing

The build script prefers an Apple Development identity and uses Keychain for the long-lived pairing credential in that case. If no development identity is installed, it creates an ad-hoc signed app and keeps the 256-bit credential in an owner-only Application Support file. Ad-hoc rebuilds can require Screen Recording permission to be granted again because their signing identity is not stable.
