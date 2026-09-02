# Glassy Host

Glassy Host is the macOS companion for Glassy Desk. It advertises an authenticated local service over Bonjour and can capture a selected display with ScreenCaptureKit, encode it as low-latency H.264 with VideoToolbox, and stream frames to paired clients.

## Run

From the repository root:

```sh
./script/build_and_run.sh
```

The script builds and signs `dist/Glassy Host.app`, installs a verified copy at `/Applications/Glassy Host.app`, then opens the installed app. You can also use the repository's Codex **Run** action.

Grant Screen Recording and Accessibility access locally, then leave Glassy Host running. Its lightweight `_glassydesk._tcp` listener remains available without recording the screen. Capture starts automatically after a Glassy Desk device completes the authenticated pairing or resume handshake, then stops five seconds after the final device disconnects. **Start Streaming Continuously** is available as an explicit always-on override.

### Pair new devices with a code or password

The rotating 12-symbol code shown by Glassy Host is the default and is always available. If copying that code is inconvenient for a remote Tailscale Mac, choose **Set Password…** in the pairing section. A new Glassy Desk device can then explicitly choose Password while using the Mac's Tailscale `100.64.0.0/10` address, Tailscale IPv6 address, or full `.ts.net` MagicDNS name. Before pairing, confirm Tailscale is connected on both devices and the selected tailnet peer is the intended Mac. Glassy Desk checks for a recognizable Tailscale address and an active VPN route, and intentionally requires the one-time code for Nearby, ordinary LAN, and other raw TCP routes. This is an operational trust requirement: the password handshake is not a PAKE, so the rotating code remains the safer choice whenever the route or peer is uncertain. Devices that are already paired continue using their device- and host-bound resume credential, so they do not need the code or password again.

Pairing passwords must contain 15–128 characters. Spaces are allowed and significant; line breaks and control characters are not. Use a long, unique passphrase for a remotely reachable Mac. Glassy Host applies NFC normalization and 600,000 rounds of PBKDF2-HMAC-SHA256, then saves only the resulting 32-byte, host-bound credential in the encrypted macOS login Keychain without enabling iCloud synchronization. The plaintext password is never stored, logged, or displayed.

Changing or removing the password does not disconnect authenticated viewers and does not unpair existing devices. Replacing the host pairing key intentionally unpairs every device and removes the password because the password credential is bound to that host identity.

Connected Glassy Desk devices can request Data Saver (720p/15 FPS/~2 Mbps), Balanced (1080p/30 FPS/~5 Mbps), or Best (up to 4K/60 FPS/~12 Mbps). The host accepts only these bounded presets and reconfigures capture and H.264 encoding without dropping the authenticated session. Because one encoder serves every connected device, the most bandwidth-conscious active request determines the shared stream.

## Connect remotely with Tailscale

Tailscale provides a private route to a remote Mac without exposing Glassy Host to the public internet:

1. Install Tailscale on the Mac and iPad, sign in to the same tailnet, and confirm both devices appear online.
2. Install and run the same current Glassy Desk/Glassy Host version on both devices. Leave Glassy Host running and grant its Screen Recording and Accessibility permissions.
3. In Tailscale on the Mac, copy the Mac's MagicDNS name or `100.x.y.z` address.
4. In Glassy Desk, edit the saved Mac, select **Glassy Stream**, enter that Tailscale name or address, and use TCP port `51515`.
5. Connect and enter either the pairing code currently shown by Glassy Host on that remote Mac or its configured pairing password. The credential must belong to the Mac whose Tailscale address you entered.

The nearby-host picker uses Bonjour, which normally discovers only Macs on the iPad's local network. A remote Tailscale Mac is therefore not expected to appear in that list; connect with its saved address instead. Do not configure router port forwarding or expose port `51515` publicly.

If the direct connection cannot be established, verify that both devices still show as online in the same tailnet, that the tailnet's access-control policy permits the iPad to reach the Mac on TCP `51515`, and that the macOS firewall allows the current Glassy Host app. Rebuilding or replacing only one side can also produce protocol or authentication errors, so deploy compatible Glassy Desk and Glassy Host builds together.

## Verify

```sh
swift test --package-path GlassyHost
./script/build_and_run.sh --verify
```

The package is intentionally separate from the iOS Xcode project so both apps remain independently buildable in the same repository. Glassy Desk discovers the host over Bonjour, authenticates its encrypted video and input session, and disconnects the Glassy session when the iPad app enters the background so idle capture can shut down.

## Signing

The build script prefers an Apple Development identity and uses Keychain for the long-lived pairing credential in that case. If no development identity is installed, it creates an ad-hoc signed app and keeps the 256-bit host credential in an owner-only Application Support file. The optional reusable password credential never uses that fallback: it is stored only in the macOS login Keychain, and an access failure leaves rotating-code pairing available. Ad-hoc rebuilds can require Screen Recording permission to be granted again and may not retain Keychain access because their signing identity is not stable.

The script embeds and signs Sparkle and its helpers with the host's signing identity. Local ad-hoc builds use a separate entitlement to disable library validation so they can load Sparkle without a team identity; development-signed builds retain library validation. Both keep the hardened runtime enabled.

## Software updates

**Check for Updates…** is available in the application menu and the menu bar extra. The shared updater starts only when `Support/Info.plist` contains both:

- `SUFeedURL`: an absolute HTTPS appcast URL with a host, without embedded credentials or a fragment.
- `SUPublicEDKey`: the base64-encoded, 32-byte Ed25519 public key produced by Sparkle's `generate_keys` tool. Never add its private signing key to the app or repository.

These settings are deliberately absent until the real feed and signing key are ready. Missing or invalid settings leave the menu action disabled and Sparkle entirely stopped, without update requests or permission prompts. Startup errors are logged and also leave the menu action disabled. Once configured, Sparkle manages update-check permission and scheduling using its standard preferences.

A requested install-and-relaunch waits while authenticated remote sessions are connected, then resumes after the last client disconnects, even with the dashboard and menus closed. A canceled update discards its pending installation. Explicitly quitting the app remains allowed; Sparkle retains its standard install-on-quit behavior. No download hosting or release-signing workflow is configured yet.
