# Host connections and QR pairing

Glassy Host now uses a native macOS sidebar with Connections and Display & Control. Login preferences and security options live in a separate Settings window. System materials adapt to appearance and accessibility settings; macOS 26 uses native Liquid Glass buttons, with standard controls on macOS 14–15.

## Connect a device

1. Open Glassy Host on the Mac and allow Screen Recording and Accessibility for viewing and control.
2. Choose **Add Device**. Keep the Mac and iPhone or iPad on the same local network.
3. In Glassy Desk, choose **Scan QR Code**. Review the Mac’s name and address, then choose **Pair & Connect**.
4. Use **Enter Code** on the Mac and **Enter Code Manually** on the client when a camera is unavailable. Existing direct-address and Tailscale password pairing remain available.

The custom QR code uses an opaque, high-contrast surface, rounded modules, a small display mark, and a four-module quiet zone. Before presentation, Vision verifies that the image decodes to the exact invitation; simpler QR styles are fallback options. Codes refresh automatically every minute. Credentials are passed through the existing authenticated, encrypted handshake and are never logged by the QR flow.

The versioned invitation is `glassydesk://pair` with `v`, `host`, `port`, `name`, `code`, and `expires` query items. The client strictly validates the format and expiry. Scanning stays inside the app and requires an explicit connection confirmation; the invitation is not registered as a system URL handler.

## Manage access

Paired devices show their last connection time and current connection status. Existing installations discover previously paired device names when those devices next reconnect. **Revoke Access** disconnects that device and invalidates its saved resume credential across restarts. Fresh pairing can restore access without reviving the revoked credential.

**Allow connections** pauses the listener, remote input, and screen sharing. The preference persists across launches. Sharing normally starts on demand; **Share Continuously** is an explicit override in Display & Control.

## Preview and validation

Run `./script/build_and_run.sh --preview` to build and launch the local `dist/Glassy Host.app` without replacing the app in Applications. The regular run script’s install behavior is unchanged.

Host tests cover invitation validation, exact Vision QR decoding, persisted access and revocation, and existing stream behavior. The iOS app and test target compile, and invitation/feature-flag tests run in a standalone Swift Testing harness. End-to-end camera acquisition still needs an iPhone or iPad with the updated client.
