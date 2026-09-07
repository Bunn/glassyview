# Streaming continuity follow-up — September 7, 2026

The prior recovery fix stopped the reconnect loop but missed a visible playback regression: an in-session decoder recovery explicitly removed the last displayed image before replacement video arrived. The earlier tests checked decoding and deadlines, not continuous presentation during that gap.

## Evidence

A fresh Mac log captured one viewer session from 13:37:35.052 to 13:38:41.941 local time. The host created four encoder sessions, including the initial full-size capture, startup preview, a reduced tier, and return to the display's native 1680×1050 size. The last encoder recreation occurred at 13:38:00.124; subsequent bitrate and cadence increases did not recreate it. This rules out continuous host encoder restarts as the sole explanation for repeated flashes throughout this session. Local log: `/tmp/glassy-black-flash-host-live.log`; raw connection logs remain uncommitted.

The client callback mailbox admitted only three frames while the host could send sixteen before waiting for acknowledgment. A deterministic test delivered one fresh sixteen-frame window while the callback queue was briefly occupied. The old client discarded the valid dependency chain and requested recovery; the baseline failed three assertions. A separate expired-burst test retains the existing 150 ms limit.

Every configuration and dependency recovery called `flush(removingDisplayedImage: true)`. A new real VideoToolbox/AVFoundation test checks the actual displayed pixel buffer during a 200 ms gap before the replacement keyframe, rather than checking only facade state or connection survival. Initial inspection also caught that separate reads of an unchanged displayed image can return different CVPixelBuffer wrapper objects, so wrapper identity cannot prove fresh decoding.

The host had a separate format-ordering race: codec updates entered its network queue independently from a coalescing video mailbox. Two rapid format/keyframe pairs could send the later keyframe between two configuration messages; the client then discarded it when the later configuration arrived. A paused-queue loopback probe reproduced zero delivered video frames until another keyframe was explicitly supplied. Baseline: `/tmp/glassy-codec-order-before.json`.

## Host validation

The host now attaches the configuration snapshot to each access unit before coalescing and publishes any changed configuration on the same network drain as its frame. The same paused-queue probe delivers one matched configuration/keyframe immediately and suppresses an identical later configuration. Result: `/tmp/glassy-codec-order-after.json`.

All **144 Mac tests passed**. A real VideoToolbox test also verifies that bitrate/cadence changes and recovery keyframes do not repeatedly emit codec configuration. Both legacy-client/current-host and current-client/legacy-host probes delivered a configuration and 20 video frames, exchanged input and pong, and reported zero errors or unsupported status messages.

The universal Mac **0.2.12 (16)** Release candidate passed warnings-as-errors compilation and signature/architecture checks. Log: `/tmp/glassy-host-0.2.12-candidate-build.log`.

The [final host measurements](../performance/glassy-stream-continuity-2026-09-07.json) also preserve the prior quality repair: full 3840-pixel frames arrived in 0.637 s unrestricted, 1.228 s at 100 ms RTT and 1.202 s for a new viewer joining a cached full-size encoder. All three held the 12 Mbps Best target through six full-resolution IDRs over 11.90–12.45 seconds. The synthetic sustained fixture delivered 589/600 frames with p95 callback age 59.4 ms and pong 108.8 ms; its producer actually ran at about 49.3 fps, so this is not a measured 60 fps display result. The three 500 kbps bootstrap cases passed in 0.690, 1.547 and 3.356 seconds. All fixtures reported zero errors.

## Presentation contract

AVFoundation's [flush API](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/flush(removingdisplayedimage:completionhandler:)) distinguishes discarding pending decoder data from removing the displayed image. A direct native test confirmed that `flush(false)` preserves the actual image while resetting display readiness to false; a newly decoded replacement restores readiness to true. This allows the existing fresh-presentation watchdog to remain intact without using pixel-buffer wrapper identity as proof of recovery.

In-session configuration, discontinuity and decoder recovery now preserve the old image. Initial startup, reset, detach and terminal invalid-input cleanup still clear it when appropriate. A generation/epoch guard distinguishes intentional preservation from unexpected image loss; retained image presence only controls visible UI state, while native readiness alone completes recovery. The waiting card stays hidden while a usable image remains visible. Recovery start/completion logs are bounded to state changes.

All **20 focused tests in three suites passed** in 56.6 seconds with no compiler warnings or errors. The real decoder test checks actual image presence at 20 ms intervals through four 200 ms recovery gaps, for 40 continuity assertions. Each replacement keyframe restores native readiness and survives the following 5.3-second deadline check. Separate missing/non-keyframe and invalid-IDR cases preserve the image but still fail within the five-second recovery deadline. Reset removes the image. Log: `/tmp/glassydesk-video-continuity-after.log`.

A native 1920×1080 IDR plus fifteen dependent frames also passes without dependency drops. This burst did not reproduce native decoder backpressure on the simulator, so the worker's pending-slot policy remains unchanged. The separately reproduced callback-mailbox overflow is fixed with sixteen-frame capacity, retaining the existing 16 MiB/150 ms bounds. Exact repeated configurations preserve pending frames; a changed configuration or a new connection still establishes its own dependency chain.

## Full validation

The full simulator suite passed **156 tests**, with zero failures, skips, compiler warnings or errors. Result: `~/Library/Developer/XcodeBuildMCP/workspaces/glassyview-14cc3760fa08/result-bundles/test_sim_2026-09-07T12-53-45-212Z_pid53694_b283c5a5.xcresult`.

The generic iOS device Release build also passed without compiler diagnostics. It uses disabled signing to validate compilation, not to produce an installable or uploaded App Store build. Log: `/tmp/glassydesk-black-flash-release-build.log`. The corrected client is **1.3 (4)**. Independent reviews covered image-retention/deadline guards, mailbox ordering, and host configuration/frame pairing, with no new blocker found.

## Scope

The repair addresses image retention during recovery, unnecessary client dependency drops, duplicate configuration handling and host configuration/frame ordering. iCloud and persistence remain excluded. No physical iPad was connected for installation or direct verification; installing the corrected client remains necessary. Sparkle only distributes the Mac companion.
