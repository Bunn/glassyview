# Curtain Mode

During a Fast Connection session, turn on **Session Options › Curtain Mode** to cover the Mac's displays and ignore its own keyboard, mouse, and trackpad while this device controls it. The streamed desktop is unaffected. People at the Mac see "This Mac is being used remotely" instead of your work. The setting is remembered per Mac and requested again on every connection.

Curtain Mode needs a companion build with the capability, and only the device that controls the Mac can use it. On the Mac, **Settings › Security › Allow Curtain Mode** turns it off. Standard VNC does not offer it.

## How the Mac covers its screen

- `HostCurtainService` places one borderless window per display at `CGShieldingWindowLevel()`, on every Space and over full-screen apps. The window ignores mouse events, so remote clicks reach the apps underneath.
- Shields are created transparent, `ScreenCaptureService.setExcludedWindowIDs` updates the running `SCStream` filter to leave them out, and only then do they become opaque. No streamed frame contains a shield. Capture restarts reuse the exclusion list and reapply it once started.
- Display changes rebuild the shields and their exclusions.

## How local input is ignored

Every event the companion injects for the remote device is posted through `HostSyntheticInput.post`, which stores a marker in `kCGEventSourceUserData`. While the curtain is up, `HostLocalInputBlocker` installs an active event tap at the HID location and drops keyboard, pointer, scroll, tablet, gesture, and system-defined (media and brightness key) events without the marker. A tap that macOS disables for timing is re-enabled. Creating the tap requires Accessibility; without it the shields still appear and the status says local input is not blocked, which the device explains.

## When it ends

- The controlling device turns it off.
- That device disconnects and does not ask again within 15 seconds. The grace period covers automatic reconnection and short app switches, so the desktop does not flash to people at the Mac; Picture in Picture keeps the connection, and the curtain, alive.
- The Mac turns off Allow Curtain Mode or stops allowing connections.
- The companion quits, which removes its windows and event tap.

There is deliberately no local override, matching Apple Remote Desktop: anyone at the Mac could otherwise reveal the remote person's work.

## Protocol

Capability bit 9 (`0x00000200`, `curtainMode`) negotiates two messages inside the encrypted session:

| Kind | Direction | Payload |
| --- | --- | --- |
| `0x25` curtain request | device → Mac | 4 bytes: UInt8 `0` off or `1` on, three zero bytes |
| `0x26` curtain status | Mac → device | 4 bytes: UInt8 state (`0` off, `1` on, `2` unavailable, `3` failed), UInt8 flags (bit 0: local input blocked), two zero bytes |

A device's first request subscribes it to status; the Mac replies with the current state, then broadcasts every change to subscribed connections. Older clients never subscribe, so they never receive status. A request from a view-only device, or while the Mac disallows the feature, gets `unavailable` only on that connection. A failure to hide the screen from capture lifts the curtain and reports `failed` to the requester. Statuses are never coalesced, so a rejection is not replaced by the state that follows it.

## Verification

Host tests cover both payloads, the advertised capability, ownership and permission rules, the reconnect grace period (including a new connection asking again), the input filter's marker, raising and lowering with recorded capture exclusions, private rejections, turning the feature off while active, and degraded operation without Accessibility. iOS tests cover negotiation in both directions over an encrypted loopback, payload validation, the session's handling of each status, and the per-Mac preference.

Before release, verify with a signed companion on a Mac with two displays:

1. Turn Curtain Mode on. Confirm both displays show the shield locally while the device still streams and controls the desktop, including a full-screen app and another Space.
2. Confirm the Mac's keyboard, trackpad, and media keys do nothing locally, and remote typing, clicking, scrolling, and Paste to Mac still work.
3. Background Glassy Desk briefly and return within 15 seconds; then leave for longer. Confirm the curtain stays, then lifts, and returns on reconnect.
4. Revoke Accessibility and confirm the device explains that local input still works.
5. Disconnect a display while the curtain is up and confirm the remaining display stays covered and the stream never shows the shield.
