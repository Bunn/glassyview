# Remote Host Connectivity Plan

## Goal

Make a Glassy Host running on a remote Mac easy and secure to reach from Glassy Desk without asking ordinary users to configure routers, firewalls, VPNs, dynamic DNS, or public ports.

The recommended product is an optional **Glassy Remote** service:

- Keep local Bonjour connections account-free.
- Use Sign in with Apple for the remote-access account, avoiding a new password.
- Enrol each host with a short-lived QR code or setup code.
- Have Glassy Host establish an outbound connection over port 443.
- Prefer a direct peer-to-peer path when available and fall back to an opaque regional relay.
- Preserve the existing Glassy application-layer authentication and encryption inside every transport.
- Offer Tailscale and direct addresses as advanced, bring-your-own-network options.

Accounts and iCloud can provide identity, discovery, authorization, and synchronization. They do not, by themselves, make a private Mac reachable through NAT or carry the screen stream.

## Option evaluation

| Option | User setup | NAT and CGNAT | Security | Main limitation | Product role |
| --- | --- | --- | --- | --- | --- |
| Glassy account and outbound relay | Sign in once and scan a host QR code | Works because both endpoints connect outbound | Excellent when the existing end-to-end protocol remains inside the relay | Requires a backend, relay operations, and bandwidth | Default consumer experience |
| Private iCloud/CloudKit plus a real transport | Nearly automatic when both devices use the same Apple Account | Does not provide connectivity | Strong for sparse metadata and signed enrolment records | Requires iCloud on both devices and still needs a direct or relayed route | Optional same-user convenience layer |
| Tailscale on both devices | Install twice, approve the iOS VPN, and join the same tailnet | Handles NAT with direct UDP and encrypted relay fallback | Excellent WireGuard transport plus Glassy encryption | Extra app/account, one-active-VPN conflicts on iOS, and sharing steps | Beta, self-hosted, and advanced mode |
| Cloudflare Tunnel with Cloudflare One client | Configure a tunnel and enrol the client | Works through outbound tunnels | Strong private routing | Enterprise-oriented administration and VPN-client friction | Managed organization deployments only |
| Public tunnel or public port | Configure a hostname, port, and possibly router/firewall rules | Public tunnels work; direct ports often fail behind CGNAT | Application encryption can remain strong, but the listener is exposed to scanning and denial of service | Difficult setup, public exposure, and inconsistent reachability | Expert-only escape hatch |
| Raw WireGuard | Provision peers, keys, routes, and usually a reachable hub | Needs a reachable peer or hub | Excellent transport encryption | Reimplements much of Tailscale's control plane with worse onboarding | Not recommended |

## Recommended architecture

### 1. Preserve the local path

Bonjour remains the fastest path on a trusted local network and continues to work without an account or internet connection.

The same stable host identity and pairing state must work whether a session uses Bonjour, a direct address, Tailscale, or a Glassy relay. Changing transport must never silently create a new trusted host.

### 2. Create an optional Glassy account

Use Sign in with Apple as the initial account provider. The account exists to manage:

- the user's host directory;
- host ownership;
- approved viewer devices;
- short-lived connection authorization;
- device revocation;
- subscriptions, quotas, and relay abuse controls;
- optional host sharing in the future.

The account is a control-plane identity. Signing into the account alone must not authorize screen viewing or remote input.

Local Bonjour use should remain available without signing in. This also keeps remote-access account requirements proportionate to the feature.

### 3. Enrol a host with a QR code

On first enabling Remote Access, Glassy Host should:

1. Generate a long-lived host signing key whose private part never leaves the Mac.
2. Open an authenticated outbound connection to the control plane.
3. Request a cryptographically random, single-use, short-lived claim token.
4. Display the token as a QR code and a copyable fallback code.
5. Show the account and viewer device that claimed the host and require confirmation where practical.

Glassy Desk should:

1. Authenticate the user with Sign in with Apple.
2. Scan the QR code or accept its universal link.
3. Generate its own device key locally.
4. Bind the host public key and viewer public key through the one-time claim.
5. Complete the existing Glassy pairing proof before remote control is enabled.

The QR payload must contain only a one-time claim and public metadata, never the host root secret or a reusable resume credential.

### 4. Use an outbound-only relay first

For the first consumer release, both Glassy Host and Glassy Desk connect outbound to a regional relay over port 443. This avoids inbound firewall rules, router configuration, dynamic DNS, and CGNAT failures.

For each session, the control plane issues a short-lived capability scoped to:

- one viewer device;
- one host;
- one session;
- an expiration time;
- the allowed protocol version and features.

The relay joins the two authenticated channels and forwards opaque binary Glassy frames. Pairing codes, resume credentials, host private keys, session keys, screen pixels, and input contents must remain unavailable to the relay.

A compromised relay can still observe connection metadata, delay traffic, or deny service. Privacy documentation and operational controls should acknowledge that boundary.

### 5. Separate control and media

The current protocol sends video and input over one TCP connection. That is acceptable for an initial local implementation but can allow a lost or congested video segment to delay pointer and keyboard events over a WAN.

Remote transport should provide separate queues or streams for:

- reliable, high-priority input and session control;
- video configuration and keyframes;
- newest-frame-oriented video data.

Two WebSocket/TCP channels are a pragmatic first relay implementation because the current protocol is already stream-oriented. A later QUIC or WebRTC transport can provide independent streams, datagrams, congestion feedback, and better loss behavior.

QUIC improves multiplexing but does not solve NAT traversal. Direct connectivity still needs rendezvous plus ICE/STUN-like candidate discovery and a TURN or proprietary relay fallback.

### 6. Add direct connectivity later

Once the relay experience is reliable, exchange endpoint candidates through the control plane and attempt a direct encrypted path. Keep the relay active during negotiation and use it whenever direct connectivity is unavailable or degrades.

Connection selection should prefer:

1. local Bonjour;
2. an already-reachable direct or private-overlay endpoint;
3. direct WAN traversal;
4. the regional relay.

Direct connectivity reduces latency and relay bandwidth. The current quality presets target roughly 2, 5, or 12 Mbps (about 0.9, 2.25, or 5.4 GB per hour for one fully relayed outbound stream), making both quality selection and direct-path success economically meaningful as usage grows.

## iCloud and CloudKit

The iOS client already uses a private CloudKit-backed SwiftData store for saved-machine metadata. CloudKit can also provide a near-zero-setup discovery and enrolment path when the Mac and iPhone or iPad use the same Apple Account.

A safe iCloud flow would be:

1. The host keeps its private key device-local and writes a signed, expiring registration containing its public key, protocol capabilities, and route metadata to the user's private CloudKit database.
2. A new iOS device creates its own local keypair and writes an enrolment request containing its public key and nonce.
3. The host writes a per-client grant signed by the host and encrypted to the client key.
4. The client proves possession of that key during the Glassy handshake.
5. The host can revoke each grant independently.

Use CloudKit only for sparse control-plane records. Do not use it for rapid presence heartbeats, session signaling that requires low latency, or media transport. CloudKit notifications can be delayed or coalesced and should be treated as hints to fetch current state.

Never synchronize the host root secret or reusable per-client resume secrets through CloudKit or iCloud Keychain. This would increase the blast radius of a compromised Apple Account and make per-device revocation weaker.

Private CloudKit is also not universal: it requires an active iCloud account on both Apple devices. A hosted Mac using a different or no Apple Account needs the QR/account path.

CloudKit Sharing may later support an explicit **Share this Mac** feature, with private invited participants, limited permissions, expiration, and revocation. A public "anyone with the link" share must never carry durable remote-control authority.

## Tailscale support

Tailscale is the lowest-engineering secure route to a remote-access beta and a strong long-term advanced option.

Required Glassy changes are relatively small:

- make the Glassy Host listener port stable or configurable;
- connect Glassy Stream using the saved direct host and port rather than requiring a Bonjour endpoint;
- accept Tailscale MagicDNS names and Tailscale IP addresses;
- keep host-identity pinning and the Glassy encrypted handshake;
- add setup guidance and useful reachability errors.

The separate Tailscale app should own the VPN route initially. Glassy Desk would not need a Network Extension entitlement.

Do not ship a reusable Tailscale auth key or place every customer in a vendor-owned tailnet. Tailscale OAuth clients are administrative service identities, and delegated device provisioning is not a general cross-customer consumer account system.

Embedding TailscaleKit may be worth a production proof of concept later, but it should not become foundational until its App Store, signing, authorization, update, and support characteristics have been validated.

## Security requirements

Remote screen and input access is highly privileged. Before enabling the feature:

- Keep every private host and viewer key device-local in Keychain or Secure Enclave-backed storage where applicable.
- Store a host-side allowlist of viewer devices and support individual revocation.
- Require explicit first-time host pairing even when both devices use the same account.
- Use single-use claim tokens with at least 128 bits of entropy and short expiration.
- Use short-lived, narrowly scoped relay/session tickets.
- Preserve application-layer encryption across direct, VPN, and relay paths.
- Never silently fall back after an identity mismatch or authentication failure.
- Keep Remote Access off until explicitly enabled and provide a clear kill switch.
- Show an unmistakable local indicator while a remote viewer is connected.
- List authorized devices and recent sessions in Glassy Host.
- Notify the owner about newly approved devices and unusual access.
- Rate-limit claims, handshakes, unauthenticated connections, and relay allocations.
- Support host-key rotation and account/device recovery without weakening existing pairing.
- Minimize retained connection metadata and document what the service can observe.

The current host derives a resume secret from its root secret and client identifier without maintaining an authorization record. Add an allowlist or independently stored per-client grants before exposing the listener through a remote service; otherwise rotating the root secret is the only complete way to revoke previously paired clients.

## Repository implications

The existing code provides much of the required session security but is LAN-first:

- `GlassyHostBrowser` discovers `_glassydesk._tcp` through Bonjour.
- `HostServer` uses an OS-assigned TCP port and advertises it locally.
- `GlassyStreamClient` can already connect to either Bonjour or a direct host/port endpoint.
- The current Glassy Stream UI and reconnect flow select only Bonjour-discovered hosts.
- The protocol already uses a short-lived pairing code, ephemeral Curve25519 agreement, authenticated proofs, host identity pinning, sequence validation, and AES-GCM encrypted frames.
- Viewer resume credentials are device-local and explicitly non-synchronizable.
- Client saved-machine metadata already uses a private CloudKit container, while Glassy Host has no CloudKit integration.

Remote Host still means a remote Mac. Glassy Host requires macOS, an active graphical user context, a capturable display, and locally granted Screen Recording and Accessibility permissions. Remote connections must not trigger those consent prompts.

## Delivery phases

### Phase 1: Advanced direct access

- Assign a stable/configurable Glassy Host port.
- Wire saved direct endpoints into Glassy Stream pairing and reconnect.
- Add Tailscale/MagicDNS guidance.
- Add diagnostics for host reachability, identity mismatch, and VPN state.
- Preserve Bonjour as the preferred local route.

### Phase 2: Account and enrolment

- Add Sign in with Apple to Glassy Desk.
- Build the user, host, and viewer-device directory.
- Add host signing keys and per-device grants.
- Implement QR/universal-link host claims.
- Add authorized-device and revocation UI to Glassy Host.

### Phase 3: Opaque relay

- Add the outbound host connection and regional relay.
- Issue short-lived session capabilities.
- Carry the existing encrypted Glassy frames without relay decryption.
- Separate control and media channels.
- Add reconnect, regional failover, usage limits, metrics, and abuse controls.

### Phase 4: Direct-path optimization

- Exchange direct endpoint candidates through the control plane.
- Prefer direct UDP/QUIC where possible.
- Retain TURN or proprietary relay fallback.
- Measure direct-path success, first-frame latency, input latency, bitrate, relay usage, and reconnect behavior.

### Phase 5: Optional iCloud convenience and sharing

- Add private CloudKit host registration for same-Apple-Account discovery.
- Exchange signed per-device enrolment grants without synchronizing root secrets.
- Add explicit private host sharing with roles, expiry, and revocation.

## Decision summary

- **Default:** Sign in with Apple, QR host enrolment, outbound opaque relay, then direct-path optimization.
- **No-account local mode:** retain Bonjour and current device pairing.
- **Advanced mode:** Tailscale/MagicDNS and manually reachable endpoints.
- **iCloud:** optional same-user discovery and enrolment, never the media transport.
- **Avoid:** public ports, public tunnels, raw WireGuard provisioning, and shared bearer keys as normal onboarding.

## References

- [Sign in with Apple REST API](https://developer.apple.com/documentation/signinwithapplerestapi)
- [CloudKit private database](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase)
- [CloudKit encrypted data](https://developer.apple.com/documentation/cloudkit/encrypting-user-data)
- [CloudKit shared records](https://developer.apple.com/documentation/cloudkit/shared-records)
- [Apple Network.framework QUIC](https://developer.apple.com/documentation/network/nwprotocolquic)
- [Apple networking API guidance](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)
- [Tailscale iOS setup](https://tailscale.com/docs/install/ios)
- [Tailscale connection types](https://tailscale.com/docs/reference/connection-types)
- [Tailscale and other VPNs](https://tailscale.com/docs/reference/faq/other-vpns)
- [Cloudflare arbitrary TCP access](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/non-http/cloudflared-authentication/arbitrary-tcp/)
- [Cloudflare Realtime TURN pricing](https://developers.cloudflare.com/realtime/turn/faq/)
- [ICE, RFC 8445](https://www.rfc-editor.org/info/rfc8445/)
- [TURN, RFC 8656](https://www.rfc-editor.org/rfc/rfc8656.html)
