# Accessibility changes and first-install pointer control

## Report and cause

On a new Mac, granting Screen Recording could require an app relaunch. Granting Accessibility afterward did not ask for a relaunch. Direct Screen Access then completed, but pointer control worked only after restarting the Mac app again.

The host had two competing Accessibility checks. `HostPermissionController` read current authorization in a fresh instance of the signed executable. `RemoteInputService.handle` and its held-input cleanup independently called `AXIsProcessTrusted()` in the long-running host. When that process-local result retained its original denial, the setup UI and stream status could report access while every input packet was silently discarded. Direct Screen Access checks capture, so its success could not repair that input gate.

A regression test reproduced this mismatch before the fix: a fresh granted status plus a stale false input check produced zero mouse events. This is a deterministic reproduction of the application failure path, not a claim that the machine's live macOS permission database was reset or that a new-install system dialog sequence was exercised.

## Change

- Feed every fresh permission result into the serial input queue, including checks performed inside Direct Screen Access confirmation.
- Start with Accessibility denied and use that refreshed result for pointer, scroll, keyboard, text, clipboard, and held-input cleanup. Remove the second process-local trust check. macOS still enforces authorization when events are posted.
- On revocation or a failed probe, attempt to balance held input and close the gate. A later successful grant enables the same service instance again.
- After Direct Screen Access confirmation, reconcile input availability and publish the current stream status. Retain the existing focus refresh and five-second connected-session refresh.

## Automated verification

- The regression failed before the permission-gate change: expected `.mouseMoved`, received no events.
- All 24 focused permission, input, and clipboard tests passed after the change.
- All 146 macOS host tests passed with `swift test --package-path GlassyHost`.
- `./script/build_and_run.sh --verify` built, installed, and launched `/Applications/Glassy Desk.app`; `codesign --verify --deep --strict` passed. The Connections window displayed “Ready to connect.” This machine has no valid signing identities, so the script used ad-hoc signing and the local app displayed all three permission steps as incomplete. A development build with that new signature needs permissions granted again; this launch does not validate production permission continuity.
- New cases cover Accessibility granted through ordinary refresh and through Direct Screen Access confirmation, all input types, revocation, failed probes, balanced held buttons/modifiers/keys, and recovery without reconstructing the input service.
- Event posting and clipboard writes are intercepted in these tests; they do not move the local pointer or edit the local clipboard.

## Fresh-Mac acceptance check

This remains a manual acceptance check using the fixed signed app on a fresh Mac or test account:

1. Launch the app with no permissions. Grant Screen Recording and accept any relaunch macOS requests.
2. Grant Accessibility while leaving that relaunched app running.
3. Return to the app and confirm Direct Screen Access. Allow the macOS capture dialog.
4. Connect an iPhone or iPad. Verify pointer movement, clicks, drag, scroll, typing, and explicit clipboard paste without restarting the Mac app again.
5. During a connection, revoke Accessibility. Verify that input becomes unavailable after permission refresh, then grant it again and verify recovery in the same app process.

The change addresses the conflicting Accessibility gate; macOS's separate Screen Recording relaunch requirement remains applicable when presented by the system.
