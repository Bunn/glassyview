# Glassy Desk for Mac

Glassy Desk for Mac is the macOS companion for Glassy Desk. It advertises an authenticated local service over Bonjour and can capture a selected display with ScreenCaptureKit, encode it as low-latency H.264 with VideoToolbox, and stream frames to paired clients.

Both apps display the name **Glassy Desk**. Setup and download copy uses **Glassy Desk for Mac** to identify the desktop app; iOS calls its streaming method **Fast Connection**, alongside **Standard VNC**. The `GlassyHost` executable and package, bundle identifier, protocol identifiers, credential namespaces, and update URLs retain their existing technical names.

## Run

From the repository root:

```sh
./script/build_and_run.sh
```

The script builds and signs `dist/Glassy Desk.app`, installs a verified copy at `/Applications/Glassy Desk.app`, then opens the installed app. You can also use the repository's Codex **Run** action.

Grant Screen Recording and Accessibility access locally, then leave Glassy Desk for Mac running. Its lightweight `_glassydesk._tcp` listener remains available without recording the screen. Capture starts automatically after a Glassy Desk device completes the authenticated pairing or resume handshake, then stops five seconds after the final device disconnects. **Share Continuously** in Display & Control is available as an explicit always-on override.

### Pair new devices with a QR code, code, or password

Choose **Add Device** in Connections. On your iPhone or iPad, choose **Add Mac → Set Up Fast Connection → Scan Mac’s Code** in Glassy Desk. Review the Mac on the device and choose **Pair & Connect**. The custom QR refreshes every minute and includes the connection address. **Pair Manually** provides a camera-free alternative. Device names, last connection times, and access controls appear in Connections; existing paired devices populate the list the next time they connect. Revoking a device invalidates its saved credential, and **Allow connections** can pause access entirely.

The rotating 12-symbol code shown by Glassy Desk for Mac is available whenever connections are allowed. If copying that code is inconvenient for a remote Tailscale Mac, choose **Set Password…** in Settings → Security. A new Glassy Desk device can then explicitly choose Password while using the Mac's Tailscale `100.64.0.0/10` address, Tailscale IPv6 address, or full `.ts.net` MagicDNS name. Before pairing, confirm Tailscale is connected on both devices and the selected tailnet peer is the intended Mac. Glassy Desk checks for a recognizable Tailscale address and an active VPN route, and intentionally requires the one-time code for Nearby, ordinary LAN, and other raw TCP routes. This is an operational trust requirement: the password handshake is not a PAKE, so the rotating code remains the safer choice whenever the route or peer is uncertain. Devices that are already paired continue using their device- and host-bound resume credential, so they do not need the code or password again.

Pairing passwords must contain 15–128 characters. Spaces are allowed and significant; line breaks and control characters are not. Use a long, unique passphrase for a remotely reachable Mac. Glassy Desk for Mac applies NFC normalization and 600,000 rounds of PBKDF2-HMAC-SHA256, then saves only the resulting 32-byte, host-bound credential in the encrypted macOS login Keychain without enabling iCloud synchronization. The plaintext password is never stored, logged, or displayed.

Changing or removing the password does not disconnect authenticated viewers and does not unpair existing devices. Replacing the host pairing key intentionally unpairs every device and removes the password because the password credential is bound to that host identity.

Connected Glassy Desk devices can request Data Saver (720p/15 FPS/~2 Mbps), Balanced (1080p/30 FPS/~5 Mbps), or Best (up to 4K/60 FPS/~12 Mbps). The host accepts only these bounded presets and reconfigures capture and H.264 encoding without dropping the authenticated session. Because one encoder serves every connected device, the most bandwidth-conscious active request determines the shared stream.

## Connect remotely with Tailscale

Tailscale provides a private route to a remote Mac without exposing Glassy Desk for Mac to the public internet:

1. Install Tailscale on the Mac and iPad, sign in to the same tailnet, and confirm both devices appear online.
2. Install and run the current compatible Glassy Desk versions on both devices. Leave Glassy Desk for Mac running and grant its Screen Recording and Accessibility permissions.
3. In Tailscale on the Mac, copy the Mac's MagicDNS name or `100.x.y.z` address.
4. In Glassy Desk, edit the saved Mac, select **Fast Connection**, enter that Tailscale name or address, and use TCP port `51515`.
5. Connect and enter either the pairing code currently shown by Glassy Desk for Mac on that remote Mac or its configured pairing password. The credential must belong to the Mac whose Tailscale address you entered.

The nearby-host picker uses Bonjour, which normally discovers only Macs on the iPad's local network. A remote Tailscale Mac is therefore not expected to appear in that list; connect with its saved address instead. Do not configure router port forwarding or expose port `51515` publicly.

If the direct connection cannot be established, verify that both devices still show as online in the same tailnet, that the tailnet's access-control policy permits the iPad to reach the Mac on TCP `51515`, and that the macOS firewall allows the current Glassy Desk for Mac app. Rebuilding or replacing only one side can also produce protocol or authentication errors, so deploy compatible Glassy Desk and Glassy Desk for Mac builds together.

## Verify

```sh
swift test --package-path GlassyHost
./script/build_and_run.sh --verify
```

The package is intentionally separate from the iOS Xcode project so both apps remain independently buildable in the same repository. Glassy Desk discovers the host over Bonjour, authenticates its encrypted video and input session, and disconnects the Glassy session when the iPad app enters the background so idle capture can shut down.

## Signing

The build script prefers an Apple Development identity and uses Keychain for the long-lived pairing credential in that case. If no development identity is installed, it creates an ad-hoc signed app and keeps the 256-bit host credential in an owner-only Application Support file. The optional reusable password credential never uses that fallback: it is stored only in the macOS login Keychain, and an access failure leaves rotating-code pairing available. Ad-hoc rebuilds can require Screen Recording permission to be granted again and may not retain Keychain access because their signing identity is not stable.

The script embeds and signs Sparkle and its helpers with the host's signing identity. Local ad-hoc builds use a separate entitlement to disable library validation so they can load Sparkle without a team identity; development-signed builds retain library validation. Both keep the hardened runtime enabled.

### Package a release

Follow [Release Glassy Desk for Mac](../docs/macos-release.md) for credential setup, versioning, recovery, and a manual CI example. From the source repository, the release command builds and signs the universal app, notarizes and staples it, signs the final archive with Sparkle, and publishes the GitHub release and Cloudflare Pages feed:

```sh
./script/release_host.sh --notes /path/to/release-notes.md
```

Increment both version and build in `Support/Info.plist` before a new release. The automation does not bump versions or commit or push source changes. The lower-level `package_host_release.sh` remains available for packaging only; its notarization ZIP is not a finished release.

## Software updates

**Check for Updates…** is available in the application menu and the menu bar extra. The shared updater starts only when `Support/Info.plist` contains both:

- `SUFeedURL`: an absolute HTTPS appcast URL with a host, without embedded credentials or a fragment.
- `SUPublicEDKey`: the base64-encoded, 32-byte Ed25519 public key produced by Sparkle's `generate_keys` tool. Never add its private signing key to the app or repository.

The production feed URL and public signing key are configured. Newly built app bundles use `https://glassydesk-host.pages.dev/glassy-host/appcast.xml` directly; no custom domain or DNS setup is required. Missing or invalid settings leave the menu action disabled and Sparkle entirely stopped, without update requests or permission prompts. Startup errors are logged and also leave the menu action disabled. Sparkle manages update-check permission and scheduling using its standard preferences.

The private signing key is stored in the macOS login Keychain under the Sparkle account `dev.bunn.glassydesk.host`; it is not stored in this repository. Use `--account dev.bunn.glassydesk.host` with Sparkle's `generate_keys`, `sign_update`, and `generate_appcast` tools. To retrieve only the public key:

```sh
GlassyHost/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account dev.bunn.glassydesk.host -p
```

The production feed is published in the public distribution repository at `glassy-host/appcast.xml`. Its first release is version `0.1.2` (build `3`), a Developer ID-signed, Apple-notarized universal app for macOS 14 or later, available from [GitHub Releases](https://github.com/Bunn/GlassyDesk-Host/releases/tag/v0.1.2). The ZIP contains the stapled notarization ticket and is signed with the configured Sparkle key. Cloudflare Pages project `glassydesk-host` serves the feed at `https://glassydesk-host.pages.dev/glassy-host/appcast.xml` with `Content-Type: application/rss+xml; charset=utf-8` and `Cache-Control: no-cache, max-age=0, must-revalidate, no-transform`.

The public distribution repository is `Bunn/GlassyDesk-Host`. It contains only `glassy-host/appcast.xml` and `_headers`. Signed, notarized app archives belong in that repository's GitHub Releases, not its Git tree, and the feed must reference version-specific release asset URLs. Keep source code and private signing keys out of the public repository. Back up the signing Keychain securely before distributing releases.

A requested install-and-relaunch waits while authenticated remote sessions are connected, then resumes after the last client disconnects, even with the dashboard and menus closed. A canceled update discards its pending installation. Explicitly quitting the app remains allowed; Sparkle retains its standard install-on-quit behavior. Hosting uses Cloudflare Pages and GitHub Releases; R2 is not required. Pages uses direct uploads, so pushing the public repository alone does not deploy feed changes. The [release automation](../docs/macos-release.md) handles packaging, notarization, publication, and direct deployment.
