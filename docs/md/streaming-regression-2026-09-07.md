# Streaming regression follow-up — September 7, 2026

The 0.2.10 hardening introduced two user-visible regressions. The earlier automated checks did not exercise real display readiness or large keyframes on a healthy delayed connection, so they did not justify confidence in those behaviors.

## Reproduced failures

The installed Mac companion was 0.2.10 (14). Its unified logs showed six consecutive authenticated connections ending after approximately 5–6 seconds. Five successive sessions after the first lasted 5.211–5.239 seconds, followed by a roughly one-second retry. Their RTT was 57–73 ms; the first five connections had no retransmitted bytes. There were no host protocol-rejection logs. This supports a client timer failure, rather than network instability, as the immediate cause of the loop.

The previous client watched `AVSampleBufferDisplayLayer.isReadyForDisplay` with KVO. Apple's SDK header explicitly says this property is not key-value observable and directs callers to `AVSampleBufferDisplayLayerReadyForDisplayDidChangeNotification`. A new integration test used a real VideoToolbox-encoded H.264 frame and visible display layer. With the old observer, the native layer became ready, the app's readiness state stayed false, and the five-second recovery timer failed the session.

The host also treated a large keyframe as congestion before measuring its delivery. A real-encoder reproduction on an unrestricted local connection reduced a 1280-pixel capture through 960, 640 and 320 pixels, and bitrate through 2 Mbps, 1 Mbps, 500 kbps and 350 kbps. Its first delivered image was only 320 pixels wide after 1.81 seconds. This was content-driven degradation on a fast link. Best additionally started at the Data Saver tier and increased only gradually.

The three-frame acknowledgment window was too small for 60 fps with 60–100 ms RTT plus batched feedback. That could discard valid reference frames and trigger unnecessary keyframe requests even when bandwidth was sufficient.

## Validation record

Before-change logs and measurements are retained locally:

- `/tmp/glassydesk-regression-mac.log` — original Mac unified logs, not committed because they contain local network metadata.
- `/tmp/glassy-stream-regression-connection-summary.json` — connection timing summary with addresses and device names removed.
- `/tmp/glassy-healthy-best-before.json` — unrestricted real-encoder quality regression.
- `/tmp/glassydesk-video-presentation-before.log` — real display-layer regression test failing on the old client.

The client now uses the documented display-readiness notification, reads the current property, and guards updates by connection generation, display-layer identity and decoder-flush epoch. Observer cleanup follows attachment/reset/deinitialization.

The focused client run passed **13 tests in 3 suites**. Its real-decoder test exercised initial playback, format replacement and same-layer connection reset, waiting 5.3 seconds after each. A separate test confirmed that a configured decoder receiving no keyframe still reaches its bounded timeout. After-change log: `/tmp/glassydesk-video-presentation-after.log`.

## Host repair

Best retains its selected 12 Mbps target. A new adaptive viewer receives one bounded preview until its first video acknowledgment; a healthy connection immediately restores the selected detail. The host measures transfer time separately from the initial authentication round trip and feedback batching. A preview exceeding 200 KB can temporarily use a smaller preview; that decision does not reduce the selected bitrate or permanently limit resolution. An already-running encoder cannot bypass preview admission with a cached full-size frame. Historical clients keep their existing protocol and have a one-second fallback if they send no post-authentication messages.

Receiver credit now allows up to 16 frames, with independent byte and age limits. Pending media allows 12 frames under the existing 150 ms age budget. Large IDRs are evaluated against their expected transfer time, rather than a fixed low-latency threshold regardless of size. Bitrate-only changes and a new codec configuration no longer generate redundant host IDRs. Actual decoder/drop recovery requests remain intact. The client test also confirms that a normal configuration plus its following IDR sends no additional keyframe request.

The existing shared-encoder design remains: one slow viewer can constrain the shared capture. A new viewer's brief preview can temporarily resize the shared stream. Independent quality per viewer would require separate encoding streams and is outside this repair.

## Completed checks

- Full iOS simulator suite: **149 passed**, with no failures, skips or compiler diagnostics. Result: `~/Library/Developer/XcodeBuildMCP/workspaces/glassyview-14cc3760fa08/result-bundles/test_sim_2026-09-07T11-47-52-310Z_pid53694_5c50079c.xcresult`.
- Additional real-video assertions passed after the full suite: normal config/IDR emits zero extra requests across startup, format replacement and reset; missing video still times out. Production renderer code was unchanged for this additional assertion. Log: `/tmp/glassydesk-video-keyframe-requests.log`.
- **142 Mac tests passed.** Log: `/tmp/glassy-host-regression-build.log`.
- Previous client/current host and current client/previous host each authenticated, delivered 20 frames, exchanged input/pong and reported no unsupported messages.

[Final transport and real-encoder measurements](../performance/glassy-stream-regression-fixed-2026-09-07.json):

| Scenario | Result |
| --- | --- |
| Unrestricted local connection, 3840-pixel noisy source | Full-size frame in 0.560 s; bitrate stays 12 Mbps |
| 100 ms RTT, same source | Full-size frame in 1.227 s; bitrate stays 12 Mbps |
| Already-running full-size encoder, new viewer, 100 ms RTT | Full-size frame in 1.469 s; bitrate stays 12 Mbps |
| Sustained real encoding | Each healthy case schedules five periodic IDRs over at least 11 s; full-size encoding persists |
| 100 ms RTT, nominal 60 fps synthetic producer | 591/600 frames delivered, nine startup drops; p95 callback age 59.3 ms, max 61.7 ms; pong 106.8 ms |
| 500 kbps, desktop pattern / scaled noise / native 640-pixel noise | First-frame callback 0.622 / 1.496 / 3.399 s; measured starting budgets approximately 397–399 kbps |

The transport rows measure callback age and encoded frame delivery, not physical screen-to-display latency or actual rendered FPS. The nominal 60 fps fixture produced its 600 frames over 12.3 s on this run. The readiness tests use the real simulator decoder; a physical iPad was not connected.

## Signed build and live playback

The universal Mac 0.2.11 (15) candidate passed Release packaging with compiler warnings treated as errors, code-signature verification and arm64/x86_64 checks. The generic iOS device Release build passed without compiler diagnostics; that build disables signing and is not an App Store upload. Logs: `/tmp/glassy-host-0.2.11-candidate-build.log` and `/tmp/glassydesk-regression-release-build.log`.

The signed Mac candidate was installed at the existing `/Applications/Glassy Host.app` path. Both old and new apps satisfy each other's designated code requirement and retain the same Developer ID team and bundle identifier. Existing paired iPads and capture permissions remained available. A verified backup of the previous app was retained locally.

A normal UI pairing from the iPhone simulator exercised the installed Mac's real ScreenCaptureKit capture and the corrected client renderer. Authentication occurred at 13:10:24.954 local time; the encoder produced its preview at 576×360, then actual 1680×1050 video at 13:10:26.402, using the selected 60 fps / 12 Mbps configuration. Full capture therefore returned about 1.45 seconds after authentication, without requiring manual pointer movement. The frame-rate value is configuration, not a measured rendering rate.

The app displayed the real desktop and reached its normal one-minute free-session limit with no five-second reconnection loop. Mac logs showed one authentication and no bitrate reduction during this session. The simulator was then stopped and its temporary Mac approval revoked; existing iPad approvals remained intact. Runtime evidence: `/tmp/glassy-host-0.2.11-live-all.log`. This is actual Mac capture through the normal encrypted transport into the simulator, not physical iPad validation.

Mac **0.2.11 (15)** was published through Sparkle from commit `7892edfb5acf128c972179f7fe66440c2075ed97`. The final notarized app is installed on this Mac and reports Ready to connect. The live Mac download page points to the new installer. See [release verification](../releases/macos-0.2.11-verification.md) for artifact checksums and deployment evidence.

The reconnect correction also requires the updated iPhone/iPad app. Its source is committed and validated, but no physical device was connected for installation and this repair did not publish an iOS build. iCloud and persistence changes remain outside this repair.
