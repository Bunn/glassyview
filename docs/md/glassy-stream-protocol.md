# Glassy Stream v1: adaptive delivery and runtime status

The transport remains protocol version 1, TCP, with the existing authenticated
pairing and resume handshake. Existing H.264 configuration, access-unit, input,
quality and cursor messages retain their layouts. Integer fields are big-endian.

## Negotiation and compatibility

ServerHello capability bit 7 (`0x00000080`, `adaptiveStream`) advertises receiver
feedback and runtime status. A compatible client sends an encrypted
`streamFeedback` with sequence zero immediately after authentication. This is the
explicit subscription; the host sends no `hostStreamStatus` messages before it.
An old client can ignore the capability and continue the original v1 exchange.
A new client sends neither new message to a host without the capability.

Capability support describes protocol support, not current macOS permission.
Runtime status separately describes capture and the viewer's control role.

## Client-to-host feedback: message 0x16

Payload is exactly 16 bytes:

| Offset | Type | Meaning |
| --- | --- | --- |
| 0 | UInt64 | Highest video packet sequence handled or deliberately discarded by the receiver; zero subscribes before the first video |
| 8 | UInt32 | Oldest local callback-queue age represented by this feedback, in milliseconds; 0–60000 |
| 12 | UInt32 | Reserved, must be zero |

The acknowledged sequence is the authenticated **video packet's** sequence, not
a frame timestamp, frame count or feedback packet sequence. A receiver may
acknowledge deliberate dependency-aware drops so the host can release credit and
send a fresh keyframe. It must never acknowledge video it has not received. The
current client coalesces feedback for 30 ms. Duplicate/older acknowledgements are
harmless; acknowledgements beyond the last sent video sequence are rejected.

The host retains a small sequence/size/send-time ledger. No more than three
unacknowledged video frames are admitted, and an additional byte limit scales
with bitrate. Thus Network.framework accepting bytes into TCP does not create
fresh media credit. Age is measured on the host's monotonic clock; the client
reports its own local queue age separately. No device-clock subtraction is used.

## Host-to-client status: message 0x17

Payload is exactly four bytes:

| Offset | Type | Meaning |
| --- | --- | --- |
| 0 | UInt8 | Capture state below |
| 1 | UInt8 | Flags: bit 0 Accessibility granted; bit 1 this viewer owns input |
| 2 | UInt16 | Reserved, must be zero |

State values: `0 starting`, `1 streaming`, `2 stopped`,
`3 screenPermissionRequired`, `4 displayUnavailable`, `5 captureFailed`.
All other state/flag values and trailing bytes are rejected. Messages are sent
only to subscribed clients. The host publishes lifecycle changes, input-role
changes, and permission changes; connected hosts refresh permission status every
five seconds in addition to local activation checks. A displayed video frame is
not permission to inject input when the runtime status says view-only.

## Queueing and adaptation

Pending host packets retain plaintext until final send order. Control responses
can pass unsent media before sequence assignment and encryption, preserving
strict authenticated ordering without reordering ciphertext. Codec changes
remove obsolete queued video. Pending media has a 150 ms age budget and a small
frame limit. Dropping a dependent frame discards the unsent dependency chain;
recovery resumes at a fresh IDR. New pending IDRs replace obsolete pending IDRs.

The user-selected quality remains a ceiling. Subscribed viewers initially use a
2 Mbps budget, downshift promptly under delayed progress, and increase only
after sustained timely feedback. The shared encoder uses the most constrained
viewer's budget. Bitrate updates happen in place. Capture dimensions and cadence
move through 960×540/8 fps, 1280×720/12–15 fps, 1920×1080/30 fps and
3840×2160/60 fps tiers, bounded by the selected preset. The minimum bitrate is
350 kbps. Capture tier changes update the existing ScreenCaptureKit stream;
a single reconciler applies changes to completion before rechecking the latest
budget, including A→B→A changes while framework calls are suspended.

A per-rate byte budget detects unusually large independent frames. During
bootstrap, oversized IDRs halve the budget at most every 250 ms and are withheld
while the encoder moves to a deliverable tier. Repeated oversized IDRs at the
350 kbps floor enable emergency 640×360 and then 320×180 capture (8/6 fps).
Ordinary low-bandwidth desktops retain their normal detail unless actual encoded
frame size requires this fallback. Only an actual final-tier encoded image can
use the final one-IDR admission escape; a retained large image cannot slip
through merely because a smaller capture was requested. One final-tier
protocol-valid IDR may consume all receiver credit until acknowledged, preventing
an endless rejection/recovery loop even if an encoder overshoots its rate target.

Restoring emergency detail requires fifteen seconds of hysteresis and measured
keyframe size with at least six-fold headroom against the byte budget. This
prevents unchanged high-entropy content from repeatedly oscillating into large
keyframes. Initial discovery, one-frame serialization and physical device
presentation still contribute latency beyond pending-queue age. The receiver
deadline accounts for outstanding byte size, with an 8–60 second bound. Legacy
clients retain the protocol's maximum frame envelope, but have no receiver-credit
or automatic adaptation guarantee.

The encoder retains its established real-time H.264 Main profile with frame
reordering disabled. A low-latency rate-control experiment did not bound
worst-case high-entropy keyframes, so that mode is not enabled by this patch.
On the development Mac, synthetic high-entropy NV12 input produced approximately
305 kB IDRs at 960×540, 166 kB at 640×360, and 54 kB at 320×180 with the same nominal
350 kbps encoder budget. These observations motivate the measured emergency
resolution policy; they are not universal frame-size guarantees.

The host retains one latest capture buffer. A recovery request re-encodes it
with a new monotonic timestamp when the desktop is static; requests coalesce
and no continuous idle-encoding timer runs. Encoder configuration also bounds
its input dimensions using VideoToolbox pixel transfer. This resizes retained
idle capture deterministically and prevents old large capture buffers from
reaching the network while ScreenCaptureKit applies a new configuration. No new
`.complete` capture frame is required to recover at the smaller tier. Normal
frames avoid the extra transfer once ScreenCaptureKit supplies the chosen size.
Capture retirement cancels recovery work and releases the retained buffer and
transfer session. VideoToolbox emits new SPS/PPS before the corresponding
new-size keyframe; host configuration handling removes obsolete queued video.

## Input ownership

The first authenticated viewer owns keyboard, pointer, scroll and clipboard
input. Later viewers are view-only. A view-only disconnect does not release the
owner's held input. When the owner disconnects or is revoked, the host completes
input cleanup before transferring control to the next authenticated viewer.
Resuming the same viewer preserves its place/role and retires stale input before
the replacement connection can inject anything. New status subscribers receive
an explicit `ownsInput` flag. Older viewers remain wire-compatible but cannot
display the newly negotiated view-only explanation.

## Verification

Run host tests with `swift test --package-path GlassyHost`.
`script/performance/run_stream_audit.py` compiles current host/client transport
in a temporary loopback-only fixture, exercises bounded delivery and an adaptive
500 kbps synthetic source, and checks real VideoToolbox idle recovery. A separate
high-entropy bootstrap uses one synthetic 1280×720 pixel buffer, no later capture
input, real encoding, a 500 kbps proxy, emergency rescaling and receiver feedback;
it asserts the first video callback arrives within five seconds. The September 7
run delivered a 29,451-byte keyframe after 2.229 seconds. The last
third of each run reports steady-state callback age separately from startup.
Synthetic media is not a physical-device FPS, image-quality or input-to-display
benchmark.

Run `python3 script/performance/run_stream_audit.py --compatibility legacy-client`
and the same command with `--compatibility legacy-host` to compile the selected
peer's pre-adaptive committed source against the other peer's working-tree source. Each
checks encrypted authentication, video delivery, text input, pong responses and
absence of unnegotiated status messages. This fixture intentionally covers the
current protocol extension against commit
`485335bc393c173d5f6e39cd5ef73932036ee6fa` by default. Use `--legacy-revision`
to test another known historical implementation.
