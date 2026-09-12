# Sleep, screen saver, and Fast Connection recovery

## Findings

Standard VNC uses macOS's built-in Screen Sharing. Fast Connection uses the Glassy Desk companion in the logged-in user session, a separate TCP/Bonjour listener, and ScreenCaptureKit. These paths had different wake behavior:

1. The iOS connection flow, Wake and Connect action, and MAC address editor explicitly restricted Wake-on-LAN to Standard VNC.
2. The host started capture after authentication without declaring remote display activity. A network wake can leave the display/framebuffer unavailable. Apple's IOPM documentation specifically directs remote clients that need the framebuffer/GPU to `IOPMAssertionDeclareUserActivity` with `kIOPMUserActiveRemote`.
3. Every display-discovery error erased the completed Direct Screen Access step. A temporary missing-display or capture-service interruption then became a terminal permission failure, requiring local interaction instead of retrying.
4. The host did not observe system wake, display wake, or session activation. An apparently ready listener or capture pipeline could outlive the system resources it used before sleep.
5. Blank/suspended ScreenCaptureKit frames were discarded without notifying the client. During initial connection, that could end in a video-readiness timeout despite successful authentication.

These are verified code paths. A physical sleep/lock sequence on the reporting Mac has not been reproduced in this run.

## Changes

- Enable the existing configured Wake-on-LAN path and editor for both connection modes; keep endpoint probing and cancellation behavior.
- After the first authenticated viewer arrives, declare remote display activity before capture and hold an idle-display-sleep assertion. The assertion also prevents idle system sleep. Release all assertions after the last disconnect, connection access is disabled, or the service exits. Unauthenticated sockets and idle listening do not acquire them.
- Observe `NSWorkspace` wake/session notifications. Full system wake retires old transports and recreates the listener while preserving pairing identity, passwords, callbacks, and access rules. Screen/session wake refreshes the current capture generation through the existing serialized reconciliation path.
- Preserve explicit continuous-sharing demand while the listener recovers, and retry an interrupted permission probe without treating an unknown result as a denial.
- Only an actual ScreenCaptureKit `userDeclined` error invalidates Direct Screen Access. Missing displays and transient capture failures remain retryable. A fresh system permission revocation still fails closed.
- Publish `displayUnavailable` on blank/suspended frames and resume on complete frames. Normal idle frames do not change availability. Clients already pause video-readiness/recovery deadlines for this status; input remains disabled while the display is unavailable.

## Validation

`swift test --package-path GlassyHost`: **152 tests passed**. New coverage includes:

- No display wake for unauthenticated/disabled access; one resource hold across multiple viewers; release on final disconnect, disabled access, and teardown; retry after assertion failure.
- A real ephemeral TCP/Bonjour listener is recreated on a simulated system-wake request, preserves its pairing code, and stays stopped if connections were disabled.
- Transient ScreenCaptureKit failures preserve completed setup and capture demand; explicit denial still requires local confirmation.
- Blank/suspended/idle/complete frame sequences produce only the appropriate availability transitions.

The iOS app and test bundle built successfully, and **19 tests in three suites passed** on iPhone 18 Pro / iOS 27 Simulator: `GlassyStreamVideoRecoveryTests`, `GlassyStreamHostBindingTests`, and `GlassyStreamSavedRoutesTests`. The new renderer test uses a real video configuration and AVFoundation display layer: `displayUnavailable` pauses the five-second recovery deadline; returning to `streaming` restores the deadline when no replacement frame arrives. Run with normal simulator signing so the app receives its required CloudKit entitlements:

```sh
xcodebuild test -project dejaview.xcodeproj -scheme GlassyDesk \
  -destination 'platform=iOS Simulator,id=9207CE4F-8A4C-4E6F-AE50-46D7B96E5022' \
  -parallel-testing-enabled NO -enableCodeCoverage NO \
  -only-testing:GlassyDeskTests/GlassyStreamVideoRecoveryTests \
  -only-testing:GlassyDeskTests/GlassyStreamHostBindingTests \
  -only-testing:GlassyDeskTests/GlassyStreamSavedRoutesTests
```

The installed Mac app was left in place. This machine has no valid Mac signing identity; installing another ad-hoc build would disturb its existing permission setup. The Mac build was validated through the full SwiftPM test run.

The current host has automatic sleep/display sleep disabled, so the tests inject lifecycle events and frame statuses instead of forcing this remotely accessed development Mac to sleep. No power settings, login requirements, or system permissions were changed.

## Physical acceptance checks

Use a normally signed host build with established permissions and the matching updated iPhone/iPad app:

1. Start the screen saver or let the display turn off while leaving the Mac logged in. Connect a paired device directly with Fast Connection. Check that capture starts without first opening Standard VNC.
2. Let a configured Mac enter full sleep. On the same LAN, connect or select Wake and Connect using its correct interface MAC address. Verify wake, authentication, and the first frame.
3. Put an active session through explicit sleep/wake and a lock/unlock cycle. Verify reconnection/capture recovery without restarting the app or repeating Direct Screen Access setup.
4. Confirm the Mac still requires its normal password to unlock. If macOS withholds capture while locked, the client should stay connected with the waiting-for-display message and resume on unlock.
5. Disconnect all viewers and confirm no Glassy Desk power assertions remain (`pmset -g assertions`). Test disabled connection access and manual Stop as well.
6. Test both idle and continuous-sharing modes, plus Wi-Fi/Ethernet and the supported macOS versions/hardware.

## Boundaries and references

A completely sleeping computer must be awakened before its application can execute. Wake-on-LAN depends on hardware, macOS settings, and a usable local network path. A normal Tailscale connection does not deliver LAN broadcasts to an offline peer. Lid closure, power-off, logout, and FileVault before the first login are separate from display sleep; this change does not turn the companion into a pre-login system service.

- [Apple: Share Mac resources during sleep](https://support.apple.com/guide/mac-help/share-your-mac-resources-when-its-in-sleep-mh27905/mac)
- [Apple: IOPMAssertionDeclareUserActivity](https://developer.apple.com/documentation/iokit/1557127-iopmassertiondeclareuseractivity)
- [Apple: Turn Mac Screen Sharing on or off](https://support.apple.com/guide/mac-help/turn-mac-screen-sharing-on-or-off-mh11848/mac)
- Installed SDK: `IOKit/pwr_mgt/IOPMLib.h` documents that idle-display assertions do not wake a display already off, do not prevent explicit/lid sleep, and require a remote-user activity declaration for framebuffer/GPU access after a network wake.
