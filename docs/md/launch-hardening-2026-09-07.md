# Launch hardening — 7 September 2026

This follow-up implements the non-iCloud code defects from the [launch audit](launch-readiness-2026-09-07.md). The original report is retained as the before-change evidence. The Mac release **0.2.10 (14)** is [published and verified](../releases/macos-0.2.10-verification.md); the accompanying iOS changes remain in the upcoming **1.3** source.

## Changes

- Host video admission is bounded by count, bytes, receiver progress and age. Control messages are prioritized before final sequencing/encryption. Compatible clients report consumed/discarded video progress and queue age, enabling conservative bitrate, capture size and frame-rate adaptation below 1 Mbps. Selected quality remains a ceiling; a slow viewer constrains the shared capture stream.
- Client media moves through one bounded mailbox and a serial decoder worker instead of frame-sized main-queue callbacks. Expired reference chains are discarded together, followed by a keyframe request. Cursor/status updates coalesce, and delayed callbacks cannot configure a later connection's decoder.
- Idle desktop recovery re-encodes one retained capture buffer with monotonic timestamps and coalesced requests. Decoder recovery requires presentation readiness rather than an enqueue counter, has a bounded retry deadline, and explains host permission/sharing failures.
- The first authenticated viewer owns input. View-only disconnects cannot release another viewer's keys. Controller retirement and revocation release ordinary held keys as well as modifiers and mouse buttons.
- Production Keychain failures fail closed and preserve the existing Mac pairing root. Invalid stored roots produce an actionable error. Both protocol implementations reject equal directional GCM nonce prefixes before encrypted traffic.
- Forgetting, rebinding or deleting a saved Mac removes its local Fast Connection resume credentials first. Cleanup errors preserve the saved row and explain how to retry. This does not revoke the separate approval on the Mac; remove the device in the Mac's Connections view for that.
- Cached paid access is applied before network discovery. Customer information and offerings refresh independently, and entitlement observation has its own task. Restore, subscription management, policy and terms remain reachable without a loaded paywall.
- Optional analytics requires fresh opt-in. Opt-out cancels pending aggregate uploads and requests deletion of optional RevenueCat customer attributes. App/widget privacy manifests and complete dependency notices are included; unused icon renditions are preserved outside the compiled asset set.
- Wake-on-LAN controls and help are scoped to Standard VNC. Public policy and product-description portions of the terms now cover Fast Connection and the Mac companion. The Mac landing page's embedded download advances to 0.2.10.

The additive feedback/status extension is negotiated within protocol v1. Older iOS clients receive no unknown status messages; newer clients do not send feedback to hosts that lack the capability. Existing bundle identifiers, host identity namespace, approved-device records, Developer ID identity, Sparkle key and feed URL remain unchanged.

## Deliberately deferred

Per the release owner's instruction, no iCloud/CloudKit capabilities, entitlements, schema, sync behavior, password persistence, SwiftData recovery or legacy persistence migration is changed. The original audit's storage-related findings remain open in that deferred scope.

## Validation scope

The validation record below is populated from completed tests and exact release artifacts. Synthetic transport results measure callback age, not physical capture-to-display latency. Simulator tests do not establish real-device thermal performance or App Store acceptance.

App Store Connect remains unauthenticated in this environment. App privacy answers, processed iOS build/review metadata, agreements, product availability, export-compliance answers and a production signed iOS archive must still be verified before an iOS App Store submission. Updating an app manifest or website does not update App Store privacy answers. These external launch gates are separate from publishing the notarized Mac companion through Sparkle.

A full physical matrix across macOS 14/current, Intel/Apple silicon, real iPhone/iPad, Tailscale/mobile transitions, actual keyboard layouts, permissions, sleep/wake, sustained thermals and paid sandbox transactions has not been completed by this source-hardening run. Preserve those gates before making a blanket broad-launch readiness claim.

## Completed automated checks

- Full iOS simulator suite: **147 tests in 23 suites passed**, including mailbox overflow/expiry/configuration/cancellation, recovery deadlines and generation isolation, nonce separation, real isolated Keychain credential deletion, input/session logic, subscription resilience and analytics cancellation. Result: `/tmp/glassydesk-final-fixes-20260907.xcresult`.
- Mac release orchestration: **87 tests passed**, including interrupted notarization/publication recovery, immutable artifact handling and explicit local Cloudflare OAuth recovery. Log: `/tmp/glassy-release-oauth-tests.log`.
- App and widget manifests pass plist validation; both manifests and `ThirdPartyNotices.txt` are present in the simulator app bundle. No unassigned AppIcon-child warning in the integration build.
- Release dry run resolves Mac **0.2.10 (14)** to the existing `Bunn/GlassyDesk-Host` repository and `glassydesk-host.pages.dev/glassy-host/appcast.xml` without changing signing/update identity.
- Generic iOS device **Release build passed** with signing disabled (70 seconds), without compiler warnings. The final Release bundle contains the first-party app manifest, widget-extension manifest and dependency notice. Version remains 1.3 (3), minimum iOS 26.0. Log: `/tmp/glassydesk-final-release-build.log`.
- A separate simulator build/run passed without diagnostics. Visual/runtime inspection confirmed native Restore/Manage controls, direct policy/terms links, analytics off, the one-minute free-session disclosure and separate Fast Connection/Standard VNC setup guidance.
- Universal Mac **Release packaging passed with warnings treated as errors**. The signed pre-notarization app passes deep/strict code verification, contains both arm64 and x86_64, selects production Keychain storage, and bundles Sparkle/PermissionFlow licenses. Receipt: `/tmp/glassydesk-0.2.10-preflight-package.json`. This is pre-publication packaging evidence, not a notarization claim.
- Final Mac suite: **136 tests passed**, including input ownership, adaptive credit/rate/emergency-resolution policies, strict protocol extension parsing, Keychain failures, real VideoToolbox keyframe production, rate updates and retained-buffer resizing. Log: `/tmp/glassy-host-stream-fixes-build.log`.
- Both cross-version probes passed: previous client/current host and current client/previous host authenticate, deliver video, exchange input/pong and avoid unnegotiated messages. The committed compatibility runner uses the audited `485335b` protocol implementations.

## Performance follow-up

The [final optimized probe results](../performance/glassy-stream-fixed-2026-09-07.json) preserve the full measurements and scope. The same 2 Mbps overfeed scenario now has **201 ms p95 callback age**, **284 ms maximum**, and **90 ms pong delay**, compared with the audit's 3,770 ms p95 and 3,418 ms pong delay. The producer now honors recovery requests; this is still synthetic transport evidence, not real display latency.

At 500 kbps with the producer following adaptive feedback, the final third has **249 ms p95 / 264 ms maximum callback age**. Initial adaptation peaks at 609 ms. In the one-second callback-stall scenario, pending media is discarded and p95 callback age is 0.54 ms; the one callback deliberately blocked by the fixture still measures about one second. An in-flight user callback cannot be preempted.

A real VideoToolbox bootstrap test sends one 1280×720 noise capture, with no subsequent capture input, through the 500 kbps transport. The receiver gets its first independently decodable **29,451-byte** frame in **2.23 seconds**, after bitrate steps 2M→1M→500k→350k and emergency widths 640→320. This verifies recovery below the client deadline without requiring desktop activity. Emergency detail restores only after measured headroom and hysteresis; frame-size and physical-latency guarantees still depend on content and hardware.
