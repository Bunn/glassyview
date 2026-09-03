# Host connections and QR pairing

Glassy Host now uses a native macOS sidebar with Connections and Display & Control. Login preferences and security options live in a separate Settings window. System materials adapt to appearance and accessibility settings; macOS 26 uses native Liquid Glass buttons, with standard controls on macOS 14–15.

## Connect a device

1. Open Glassy Host on the Mac and allow Screen Recording and Accessibility for viewing and control.
2. Choose **Add Device**. Connect the Mac and iPhone or iPad to the same local network, or connect a VPN such as Tailscale or WireGuard that lets them reach each other.
3. In Glassy Desk, choose **Scan QR Code**. Review the Mac’s name and address, then choose **Pair & Connect**.
4. Use **Enter Code** on the Mac and **Enter Code Manually** on the client when a camera is unavailable. Existing direct-address and Tailscale password pairing remain available.

The custom QR code uses an opaque, high-contrast surface, rounded modules, a small display mark, and a four-module quiet zone. Before presentation, Vision verifies that the image decodes to the exact invitation; simpler QR styles are fallback options. Codes refresh automatically every minute. Credentials are passed through the existing authenticated, encrypted handshake and are never logged by the QR flow.

The versioned invitation is `glassydesk://pair`. Version 2 includes `v`, `host`, `port`, `name`, `code`, `expires`, and `id` (the 16-byte host identifier in canonical base64), plus up to seven repeated `alt` host fields. Addresses share the advertised port. The client strictly validates fields, host identity, address count, total size, and expiry; it continues accepting version 1 invitations. Scanning stays inside the app and requires an explicit connection confirmation; the invitation is not registered as a system URL handler.

## Local networks and VPNs

Glassy Host discovers its active network interface addresses, including LAN, Tailscale, and WireGuard tunnel addresses, and refreshes them when the network changes. Its Bonjour `.local` name remains a LAN fallback. Down, loopback, multicast, and link-local addresses that require a device-specific scope are excluded. A bounded set of eight routes keeps the QR readable while retaining both local and VPN options.

Glassy Desk uses the system’s routing table and tries the advertised routes with short staggered starts. It validates each route’s ServerHello against the scanned or previously pinned Mac identity before selecting one connection. Only the winner proceeds to the existing encrypted authentication exchange. Failed routes do not consume the pairing credential; the remaining connections are cancelled. The app saves the address that authenticated and retains the alternatives for later connections and automatic reconnects. Reachability checks consider the whole saved route set, so an unavailable LAN address does not hide an available VPN route.

Connect the VPN before scanning so its addresses are included. If the Mac’s VPN configuration changes after pairing, scanning a fresh QR updates the saved routes without changing the pinned Mac identity. The apps use existing VPN connectivity; they do not configure VPN accounts, routing policies, or firewall rules. Reusable-password bootstrap retains its existing Tailscale-only restrictions; QR/code pairing and authenticated resume work on any reachable supported route.

The networking implementation uses Apple’s [Network framework](https://developer.apple.com/documentation/network) and system interface enumeration. Tailscale’s [MagicDNS](https://tailscale.com/docs/features/magicdns) names are distinct from the Mac’s LAN Bonjour name, so the QR includes numeric VPN addresses instead of relying on `.local` resolution remotely.

## Manage access

Paired devices show their last connection time and current connection status. Existing installations discover previously paired device names when those devices next reconnect. **Revoke Access** disconnects that device and invalidates its saved resume credential across restarts. Fresh pairing can restore access without reviving the revoked credential.

**Allow connections** pauses the listener, remote input, and screen sharing. The preference persists across launches. Sharing normally starts on demand; **Share Continuously** is an explicit override in Display & Control.

## Preview and validation

Run `./script/build_and_run.sh --preview` to build and launch the local `dist/Glassy Host.app` without replacing the app in Applications. The regular run script’s install behavior is unchanged.

Host tests cover address filtering and ranking, versioned invitation validation, exact Vision QR decoding with mixed LAN/VPN addresses, persisted access and revocation, and existing stream behavior. Client tests cover legacy and v2 parsing, saved-route persistence and identity checks, route selection and cancellation, and the existing encrypted pairing flow. Physical cross-network camera testing requires an iPhone or iPad with both updated apps and a configured VPN.
