# Glassy Host streaming

## Goal

When a paired Glassy Host companion is running on the target Mac, Glassy Desk should use a low-latency native video path. When it is absent or not ready, the default **Automatic** mode should fall back to standard VNC without preventing a connection.

The user-facing modes are:

- **Automatic** (default): prefer an authenticated, compatible Glassy Host; otherwise use VNC.
- **VNC Only**: never probe or connect to Glassy Host.

An advanced “Host Only” mode should wait until the companion transport can produce actionable pairing, permission, and compatibility errors.

## Reference technology

The local `command-canvas` project does not stream video. Its useful pieces are the control-plane design: Bonjour discovery, `Network.framework`, explicit pairing, Keychain tokens, fresh session keys, authenticated messages, and replay protection.

The Simulator preview used while developing CommandCanvas is provided by `serve-sim`. Its reusable media ideas are:

- Capture into a `CVPixelBuffer`.
- Keep only the newest frame when capture, encoding, or sending is backpressured.
- Use VideoToolbox’s real-time, low-latency H.264 configuration with frame reordering disabled.
- Send compact binary codec configuration, keyframe, and delta-frame messages.
- Seed a new viewer and force an immediate keyframe instead of waiting for the normal keyframe interval.

`serve-sim` gets its source frames and input through private Simulator frameworks. Those parts cannot capture or control a real Mac and must not ship in Glassy Desk. The Mac companion should use public [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) and [VideoToolbox](https://developer.apple.com/documentation/videotoolbox/encoding-video-for-low-latency-conferencing) APIs.

## Proposed architecture

```text
Glassy Desk (iOS/iPadOS)                    Glassy Host (macOS)

Connection planner                         Bonjour _glassydesk._tcp
  |                                        Pairing + capability handshake
  +-- HostStreamSession <== control =====> Authenticated input/control
  |        |                               ScreenCaptureKit
  |        +=========== media =========== VideoToolbox H.264
  |        |                               newest-frame-only queues
  |        +-- hardware decode
  |        +-- native pixel-buffer render
  |
  +-- VNCSession <======================== macOS Screen Sharing
```

The media and control paths should be separate. Pointer and keyboard events must not wait behind a congested video frame.

## Discovery and identity

- Glassy Host advertises `_glassydesk._tcp` and a small, non-secret TXT capability hint.
- Bonjour presence means only “a service is nearby”; it is not proof of identity or readiness.
- Pairing creates a stable host identifier and a high-entropy device-local secret. Stable signed builds keep it in Keychain; ad-hoc development builds use an owner-only Application Support file so Keychain ACL churn cannot stall launch.
- A saved machine is associated with that paired identifier, not matched by display name or current IP address.
- Every connection performs an authenticated version/capability handshake before selecting the host stream.
- Host readiness includes Screen Recording permission for video and Accessibility permission for control.

## Automatic fallback policy

Automatic mode may fall back to VNC for benign availability failures:

- no paired companion service;
- discovery or connection timeout;
- host app not running;
- capture permission not granted;
- no mutually supported protocol or codec.

It must not silently downgrade after an identity mismatch, failed authentication, replay detection, malformed authenticated traffic, or protocol-integrity failure. Those cases need an explicit security error.

## Rendering boundary

The current VNC path publishes a full `CGImage` and draws it with Core Graphics. That is useful for the first compatibility proof, but converting every decoded 60 fps frame to a `CGImage` would erase much of the companion path’s latency and power advantage.

The production fast path should publish decoded pixel/sample buffers and render through a native video or Metal-backed surface. `RemoteSessionControlling` also needs app-owned key and modifier types instead of exposing RoyalVNC key codes.

## Delivery slices

1. **Preference and discovery:** persisted Automatic/VNC-only setting, separate Bonjour browser, and nearby-host status. VNC remains the only session transport.
2. **Shared protocol and pairing:** capability models, authenticated handshake, Keychain identity, companion association, and loopback tests.
3. **Read-only stream:** ScreenCaptureKit host capture, low-latency H.264, bounded media queues, iOS hardware decode, and native rendering.
4. **Adaptive session:** connection planner, VNC fallback reasons, reconnect behavior, and transport-neutral display models.
5. **Remote input:** authenticated pointer, scroll, and keyboard events plus macOS permission UX.
6. **Measure and tune:** first-frame time, input round-trip time, dropped frames, encode/decode latency, bitrate, CPU, and battery before describing the mode as “ultra-fast.”

The current repository implements slice 1 and the macOS side of slices 2 and 3: authenticated pairing, ScreenCaptureKit capture, low-latency H.264 encoding, Bonjour service advertisement, and bounded media queues. The matching iOS handshake, decoder, and renderer are not implemented yet. Until that client exists, selecting Automatic intentionally preserves the existing VNC connection behavior.
