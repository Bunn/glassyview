# Glassy Stream performance review — 4 September 2026

Reviewed commit `08226c1`: the Glassy Desk iOS/iPadOS client and Glassy Host macOS companion. The native video path is a good foundation, but it currently lets congestion turn into seconds of stale video. Automatic bandwidth adaptation, bounded client delivery, and idle-screen recovery should take priority over cosmetic SwiftUI optimization.

This review adds a repeatable diagnostic probe and results. Application behavior is unchanged. The measurements below use the production transport code compiled with optimization on macOS, plus a separate real VideoToolbox encoder experiment. They are not physical-device frame-rate or capture-to-display measurements.

## Reproduced behavior

The [probe](../../script/performance/run_stream_audit.py) connects the actual host and client through authenticated, encrypted loopback TCP. It injects synthetic payloads with host monotonic timestamps and records their age at the client callback. The constrained cases insert a proxy that paces downstream bytes at a **2 Mbps ceiling**; scheduling and TCP overhead lower achieved throughput. Reverse traffic is unpaced. No desktop capture, keyboard injection, real pairing credentials, or saved machine data are used.

| Scenario | Actual offered payload rate | Frames observed / offered | p95 callback age | Maximum age | Ping → pong callback |
| --- | ---: | ---: | ---: | ---: | ---: |
| Unconstrained loopback | 8.92 Mbps | 180 / 180 | 1.27 ms | 1.57 ms | 0.82 ms |
| One-second consumer stall | 9.04 Mbps | 180 / 180 | 827 ms | 1,002 ms | 356 ms |
| Proxy capped at 2 Mbps | 9.32 Mbps | 51 / 180 | 3,765 ms | 3,873 ms | 3,435 ms |
| Same cap, manually reduced synthetic source | 0.73 Mbps | 60 / 60 | 41.5 ms | 42.5 ms | 38.0 ms |

The overloaded capped case was observed for 6.87 seconds; the reduced-source case for 7.56 seconds. Unobserved frames may still be buffered and are **not** a measured drop count. The reduced-source comparison changes payload size and cadence manually; it demonstrates the value of fitting traffic to the available bandwidth, not a shipped adaptive encoder or an image-quality result. Quality remained `best` in every probe connection.

The consumer-stall case eventually delivered all 180 frames, including 43 more than 100 ms old and 24 more than 500 ms old. The client does not discard that stale callback backlog before delivery.

The idle-encoder experiment produced three initial frames, then **zero new outputs during one second after `requestKeyFrame()` with no new captured input**. Supplying the next synthetic frame produced a keyframe. There were no encoder errors.

Raw results, environment details, and limitations are saved in [glassy-stream-2026-09-04.json](../performance/glassy-stream-2026-09-04.json).

## Findings, ordered by impact

### 1. P1 — Adapt bandwidth automatically, including below 2 Mbps

The host has only three fixed presets: 2, 5, and 12 Mbps, with corresponding resolution and frame-rate limits. The client defaults to Best and sends the saved/user-selected preference. There is no transport feedback controller that lowers the encoder budget when delivery falls behind. `sendPing` has no application caller, and the session controller ignores pong events.

Evidence: [preset limits](../../GlassyHost/Sources/GlassyHost/Models/HostStreamQualityConfiguration.swift#L7), [client default](../../dejaview/Services/GlassyStream/GlassyStreamTypes.swift#L82), [quality request after authentication](../../dejaview/Services/GlassyStream/GlassyStreamClient.swift#L618), and the constrained-link probe above. Actual encoder output varies with screen content; a 2 Mbps target is not a constant 2 Mbps stream. Nevertheless, there is no lower target for sustained motion on a sub-2-Mbps connection.

**Improve:** Treat the selected quality as a ceiling. Start conservatively on an unmeasured remote route, collect acknowledged delivery/queue-age feedback, lower bitrate promptly under congestion, and increase it cautiously after sustained stability. Allow a sub-1-Mbps operating range, lowering resolution and FPS when necessary to preserve readable text and responsive controls. Preserve headroom for keyframes, encryption, transport overhead, and competing traffic. Keep local queue timing separate from cross-device timestamps unless clock offset has been estimated.

A prerequisite is cheaper bitrate updates. [Quality reconciliation currently stops and restarts capture](../../GlassyHost/Sources/GlassyHost/Stores/HostController.swift#L1046), recreates the encoder, and clears video state. Updating bitrate frequently through that path would create repeated pauses. Change supported encoder rate properties in place; reserve capture/format changes for slower, debounced decisions. Continue considering the most constrained viewer when sharing one encoder.

**Effort:** Large across both apps. **Validation:** Step capacity through 5 → 2 → 0.5 → 5 Mbps while scrolling text; verify bounded age, reduced bitrate, recovery without reconnecting, and readable output. Add a negotiated feedback/control extension compatible with existing paired clients.

### 2. P1 — Bound media by age and protect control responses from the video backlog

[The host queue](../../GlassyHost/Sources/GlassyHost/Services/HostServer.swift#L267) permits 10 messages or 24 MiB per client. It removes queued delta frames only once those limits are exceeded, keeps keyframes, and sends video, cursor positions, and pong responses in [one FIFO](../../GlassyHost/Sources/GlassyHost/Services/HostServer.swift#L1283). There is no oldest-frame deadline. Ten 25 KB frames alone require about one second to serialize at 2 Mbps, before other buffering and overhead.

The queue tracks its own pending bytes and one in-flight send. `contentProcessed` means the networking stack processed the data; it is not evidence that the remote app rendered it. The 3.44-second pong delay in the bandwidth probe demonstrates the resulting end-to-end backlog. See [Apple's send-completion contract](https://developer.apple.com/documentation/network/nwconnection/sendcompletion).

**Improve:** Introduce a small media-age budget and admission control before encryption. Drop a broken dependency chain as a unit, coalesce recovery requests, and resume at a fresh keyframe. Replace obsolete pending keyframe generations when safe instead of accumulating them. Use receiver progress to account for data already accepted by TCP; shrinking the application queue alone cannot remove bytes already in the reliable stream. Prioritize small control replies, and evaluate a separate authenticated control channel if the shared stream still misses latency goals.

Sequence numbers are currently assigned and authenticated [before queue admission](../../GlassyHost/Sources/GlassyHost/Services/HostServer.swift#L1213). Reordering already encrypted packets would violate the receiver's strictly increasing sequence check. Assign sequence numbers at final send order, or use properly separated sequence/nonce domains for separate channels.

TCP is full duplex: this finding does not mean an outgoing video frame directly serializes an incoming pointer event. The measured delay is for the host-to-client response; image feedback and cursor telemetry also travel in that direction. Keyboard/pointer latency must be measured separately.

**Effort:** Medium to large. **Validation:** Repeat the capped-link probe; add large keyframe bursts, two viewers, and a receiver that pauses reads. Verify bounded queue age and no replay failures, damaged reference chains, keyframe storms, or slow-client disconnect loops.

### 3. P1 — Bound delivery before the iOS main queue and move media preparation off it

[`GlassyStreamClient.deliver`](../../dejaview/Services/GlassyStream/GlassyStreamClient.swift#L780) schedules a new asynchronous block for every event with no pending-byte, event-count, or age limit. The [session controller targets the main queue](../../dejaview/Services/GlassyStream/GlassyStreamSessionController.swift#L179). The renderer's single pending slot is downstream of this queue, so it cannot prevent callbacks retaining old frames during a UI stall. The optional `eventStream` convenience is also unbounded, although the app uses callbacks.

The renderer is entirely main-actor isolated. It validates access units, allocates compressed sample storage, [copies the payload](../../dejaview/Services/GlassyStream/GlassyStreamVideoRenderer.swift#L632), and enqueues the sample there. Native decoding is already delegated to AVFoundation; the problem is the work and queueing before it. The callback-stall probe reproduced the backlog with the actual main-queue dispatch path. Physical iOS UI/decode cost still needs profiling.

**Improve:** Use a dedicated serial media worker with one scheduled drain and explicit count/byte/age limits. Preserve configuration-to-keyframe ordering; after dropping a reference frame, discard dependent deltas and request recovery. Send only state/dimension changes to the main actor. Keep view attachment/layout on the main actor while moving sample preparation and enqueueing to the media worker. Apple explicitly supports background enqueueing through [`sampleBufferRenderer`](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/samplebufferrenderer).

**Effort:** Medium. **Validation:** Stall the main thread while video continues; check UI recovery, bounded retained payload bytes, fresh video on resumption, and safe disconnect/reconfiguration/external-display transitions. Do not replace the event stream with an indiscriminate newest-element buffer: losing codec configuration or an H.264 reference frame breaks decoding.

### 4. P1 — Answer keyframe requests even when the desktop is static

[`H264Encoder.requestKeyFrame`](../../GlassyHost/Sources/GlassyHost/Services/H264Encoder.swift#L129) only sets a flag for the next submitted frame. [Capture accepts only complete changed frames](../../GlassyHost/Sources/GlassyHost/Services/ScreenCaptureService.swift#L358). Apple documents that an [idle capture status](https://developer.apple.com/documentation/screencapturekit/scframestatus/idle) means no new frame was generated because the display did not change. A joining viewer receives [cached configuration and a keyframe request](../../GlassyHost/Sources/GlassyHost/Services/HostServer.swift#L1116), but no retained image is re-encoded to satisfy that request.

This can leave a new viewer, reattached display, or recovering decoder waiting for desktop activity. The encoder-level behavior was reproduced; a real static-screen join/recovery is still required to measure the user-visible delay. The nominal two-second keyframe interval does not create input frames when capture is idle.

**Improve:** Retain one latest valid captured pixel buffer and explicitly re-encode it with a fresh monotonic timestamp when recovery is requested. Bound and coalesce requests, and clear the retained buffer on capture generation/display changes. Avoid restoring a timer that encodes continuously while the screen is idle.

**Effort:** Medium. **Validation:** Join an already-running, unchanged desktop, reattach an external display, and force recovery without moving the host mouse. Each should get a valid fresh keyframe promptly, with no continuous idle encoding.

### 5. P2 — Evaluate VideoToolbox's explicit low-latency rate-control mode

[Encoder creation passes `encoderSpecification: nil`](../../GlassyHost/Sources/GlassyHost/Services/H264Encoder.swift#L185). The existing real-time flag, disabled frame reordering, one-frame delay hint, and speed preference are useful. Apple additionally recommends requesting `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` when creating a conferencing encoder: [current sample and guidance](https://developer.apple.com/documentation/videotoolbox/encoding-video-for-low-latency-conferencing).

**Improve:** Feature-test that mode, retain a supported fallback, and log the actual encoder/hardware selection and accepted tuning properties. Compare encode latency, keyframe sizes, actual bitrate, and text quality before enabling it by default. The existing `encode` await bounds submissions to its dispatch queue; it completes after submission to VideoToolbox, not after output. Measure outstanding encode work particularly where the optional maximum-delay hint is unsupported.

The capture-consumption task also inherits the [host controller's main actor](../../GlassyHost/Sources/GlassyHost/Stores/HostController.swift#L477). Move its per-frame cursor sampling and submission to a dedicated worker if traces show desktop UI activity delaying it.

**Effort:** Small configuration experiment, medium profiling work. **Confidence:** Configuration omission is confirmed; the size of the performance gain and any quality tradeoff are not measured.

### 6. P2 — Measure actual presentation and distinguish recovery from reconnection

[`renderedFrameCount` increments immediately after enqueue](../../dejaview/Services/GlassyStream/GlassyStreamVideoRenderer.swift#L325), and the first enqueue cancels the startup readiness timer. That is not confirmation of a displayed frame. There are no Glassy Stream signposts for capture, encode, transport backlog, decode, presentation, or input acknowledgment. Existing rendering signposts cover the VNC path.

The renderer's decoder-recovery path also invokes `onError`, whose [controller handler](../../dejaview/Services/GlassyStream/GlassyStreamSessionController.swift#L299) disconnects and resets the entire session. A recoverable decoder flush can therefore turn into full reconnection rather than remaining within video recovery. This is code-backed; a real decoder-failure trace was not captured.

**Improve:** Count enqueued and displayed frames separately; add sampled signposts and periodic queue/bitrate/RTT metrics. Use [AVFoundation video performance metrics](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/loadvideoperformancemetrics(completionhandler:)) where supported. Separate recoverable decode flush/keyframe recovery from fatal configuration, protocol, or authentication errors. Add a recovery deadline without treating an unchanged screen as a network failure.

**Effort:** Medium. **Validation:** Record Release traces on physical iPhone/iPad and the Mac, including first visible frame, input-to-visible-response, p50/p95/p99 queue age, encode/decode duration, memory high-water mark, CPU, thermal state, and battery usage.

## Existing strengths and verification

Preserve the native IOSurface/NV12 capture path, three-buffer capture pool, newest-only unencoded-frame relay, dedicated encoder/network queues, encrypted binary media, native AVFoundation display surface, disabled frame reordering, coalesced cursor telemetry, conservative multi-viewer quality arbitration, and on-demand capture shutdown. Those are appropriate foundations for a fast stream. Route racing is already bounded and starts fallback candidates after 180 ms, so connection discovery is not the leading issue found here.

The focused host run passed **37 tests**, covering protocol framing/authentication, quality policy, capture generations, encoder-property fallback, and stream lifecycle. The iOS simulator run passed **29 selected tests**, covering real loopback pairing/route handoff, route races, saved routes, cursor reconciliation, and session preferences. Neither suite currently establishes sustained throughput, presentation latency, packet-loss behavior, or idle-screen recovery.

Run the diagnostic again from the repository root:

```sh
python3 script/performance/run_stream_audit.py
```

The runner compiles current source in a temporary directory with `swiftc -O -swift-version 6`. It copies a few intact model declarations to avoid pulling UI/persistence dependencies into the command-line executable. Password-route discovery is explicitly unavailable in this code-pairing-only fixture. Only the temporary host copy changes network binding to loopback and disables Bonjour. The application source and the normal test targets remain unchanged.

To repeat the host checks:

```sh
swift test --package-path GlassyHost --filter 'codecConfigurationDoesNotSurviveCaptureStop|conservativeStreamQualityArbitration|frameRelayRestartsAfterConsumerCancellation|H264|streamQuality|StreamQuality|streamingDemand|StreamingDemand|hostProtocol|HostProtocol'
```

The iOS run used the `GlassyDesk` scheme on an iPhone 17 Pro simulator running iOS 26.5, selecting `GlassyStreamRouteLoopbackTests`, `GlassyStreamRouteRaceTests`, `GlassyStreamCursorReconcilerTests`, `GlassyStreamSavedRoutesTests`, and `SessionPreferencesTests` from `GlassyDeskTests`. The app and test bundle built successfully. This was a Debug correctness run, not a device performance benchmark.

## Implementation order and acceptance targets

Start with minimal queue/receiver-progress instrumentation and the idle-keyframe fix. Then implement bounded iOS delivery and adaptive encoder rate control together with host admission control. Follow with the encoder-mode experiment. A new media protocol or codec should follow evidence that these changes are insufficient.

Proposed acceptance targets, to validate rather than assume:

| Test condition | Required result |
| --- | --- |
| Active desktop over 0.5, 1, 2, and 5 Mbps caps | Automatically reduce bitrate/FPS/resolution; bounded age and readable text; no repeated reconnects |
| Cap changes and 50–150 ms RTT with added jitter | Rapid downshift, cautious recovery, no growing seconds-long backlog |
| 1% and 3% injected packet loss | Measure retransmission stalls and control-response delay; compare against the no-loss baseline |
| One-second client UI stall | Bounded media memory; video becomes current promptly after resumption |
| Static desktop, second viewer, and display reattachment | Fresh keyframe without requiring host-side activity |
| One slow viewer and one fast viewer | Shared-stream behavior remains predictable; no repeated keyframe bursts or capture restarts |
| Ten-minute physical-device Release run | Stable memory, actual presentation FPS, CPU/energy and thermal evidence |

Use an initial **100–150 ms software media-queue budget** as a tuning target, with transport RTT and serialization measured separately. A timer threshold alone cannot guarantee this on every link; the bitrate and recovery policy must respond when it is missed. These targets require real H.264 content and physical-device validation before calling the app fast on poor connections.
