# App lock (Face ID, Touch ID, Optic ID, or passcode)

Turn on **Settings › Security › Require Face ID** (the label follows the device's biometry) to hide Glassy Desk until the person authenticates. Choose when it locks again after leaving the app: immediately, or after 1, 5, or 15 minutes in the background.

## Behavior

- Glassy Desk starts locked and asks to unlock as soon as it becomes active. A failed or cancelled attempt leaves it locked with an **Unlock** button; errors appear under the button.
- Authentication uses `LAPolicy.deviceOwnerAuthentication`, so the device passcode is always a fallback and a lockout never makes the app unusable. Devices without a passcode cannot turn the lock on.
- Turning the lock on or off requires authenticating first, so someone holding an unlocked device cannot quietly remove it.
- Whenever the app is inactive or in the background, every window is covered, so the app switcher never shows a remote screen. Becoming inactive alone (Control Center, the Face ID prompt) never locks; only time in the background counts toward the delay.
- Sessions keep running underneath the cover. Picture in Picture, if already started, keeps showing its window; returning to the app closes it as usual and shows the lock first.

## Implementation

`AppLockController` holds the setting (`appLock.isEnabled`, `appLock.relockDelay` in `UserDefaults`) and the lock state, and receives app-level scene-phase changes from `DejaViewApp`. `AppLockCoverInstaller` sits in each scene's root view — the main window group and the external-display scene — and manages a separate window at `UIWindow.Level.alert + 1`, above sheets, the full-screen session, and menus. The interactive cover becomes the key window, which moves hardware-keyboard focus away from the remote desktop so keystrokes cannot reach the Mac while locked; unlocking returns key status to the scene's window. External displays get a plain cover without controls.

`NSFaceIDUsageDescription` is declared in `Support/Info.plist` and `InfoPlist.xcstrings`.

## Verification

`AppLockControllerTests` cover authentication when enabling and disabling, devices without a passcode, launch locking, the relock delay, inactive-only obscuring, failed and repeated unlocks, and the cover window's level and key-window handling.

Before release, verify on a physical device with Face ID and one with Touch ID:

1. Enable the lock, background the app, and confirm the app switcher shows the cover.
2. Return within and after the delay; confirm it locks only after the delay.
3. Start a session, lock, and confirm hardware-keyboard keys do nothing on the Mac until unlocked.
4. Cancel Face ID, then unlock with the passcode fallback.
5. With an external display in controller mode, confirm the display is covered while locked.
