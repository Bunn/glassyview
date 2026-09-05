# Glassy Desk

Starter iOS client for macOS Screen Sharing (VNC/RFB), built on [RoyalVNC](https://github.com/royalapplications/royalvnc).

## Setup

1. Open `dejaview.xcodeproj` in Xcode (26 or later).
2. Wait for Xcode to resolve the RoyalVNC Swift package.
3. Select the GlassyDesk target → Signing & Capabilities → choose your development team.
4. Build and run on a device or simulator on the same network as the target Mac.

On the target Mac: System Settings → General → Sharing → enable **Screen Sharing**.

## macOS companion

[Glassy Desk for Mac](GlassyHost/README.md) provides authenticated fast, encrypted connections. See [Release Glassy Desk for Mac](docs/macos-release.md) for the one-command build, notarization, Sparkle signing, and publication workflow, including local credentials and a manual CI example.

## What's included

- **Bonjour discovery** of `_rfb._tcp` services. Each discovered Mac is eagerly resolved to an IPv4 address (shown in the row); tapping fills host + port.
- **Apple Remote Desktop auth**: enter your macOS username + password. If username is left blank and the server uses legacy VNC auth, only the password is sent.
- **Rendering**: full-screen framebuffer drawn into a `CALayer` (aspect-fit), status bar and home indicator hidden.
- **Input**: tap = left click, drag = click-drag; a floating glass pill toggles a keystroke bar and disconnects.
- **Liquid Glass** styling using iOS 26-native `glassEffect`, `.glass`/`.glassProminent` buttons, and morphing glass controls.
- **Options menu**: bottom-right glass button with per-machine Fast Connection quality presets (Data Saver at 720p/15 FPS/~2 Mbps, Balanced at 1080p/30 FPS/~5 Mbps, or Best at up to 4K/60 FPS/~12 Mbps), plus VNC frame-rate, trackpad-mode, and external-display controls. Glassy quality changes reconfigure the host stream without disconnecting the session.
- **Saved machines**: one-tap connect entries with editable name/host/port/login (`MachineStore`). Metadata, encrypted passwords, and connection history are stored in SwiftData with private CloudKit sync; passwords are also cached locally in the Keychain.

## Notes & next steps

- First connection triggers iOS's Local Network permission prompt (keys are in `Support/Info.plist`, merged with the generated Info.plist).
- The API usage follows RoyalVNC's `USAGE.md` on `main`. If the branch API drifts, pin the package to a release tag in the project's Package Dependencies.
- Performance: the whole framebuffer image is republished on every update. For production, render only the dirty rect passed to `didUpdateFramebuffer`.
- Not implemented yet: right-click (try a long-press gesture → `.right` button), scroll wheel, pinch-to-zoom, modifier keys, remote cursor rendering, and a user-facing recents view.
- macOS Sonoma+ "high-performance" screen sharing is a separate proprietary protocol; third-party clients use the classic VNC path (this is fine — macOS still serves it).
