# iPhone Duo screenshots — October 2026

Three App Store screenshots for the iPhone Duo display type (`APP_IPHONE_DUO`, 2007 × 2853 PNG), in the dark short-headline style that won the September 2026 product page experiment (`../PPO-2026-09-22`). They feature the notebook pose: half-fold the Duo and the lower half becomes a trackpad or keyboard for the Mac.

| File | Headline | Capture |
|---|---|---|
| `en-US/duo/01-half-fold-laptop.png` | Fold it. / It's a laptop. | `raw/half-fold-trackpad.png` |
| `en-US/duo/02-trackpad.png` | Point. Scroll. / Right-click. | `raw/half-fold-trackpad.png` + touch points |
| `en-US/duo/03-keyboard.png` | Type. / Like a laptop. | `raw/half-fold-keyboard.png` |

## How they were made

- **Captures** are unedited `xcrun simctl io <duo> screenshot` grabs of the inner display. Glassy Desk 3.0 (this branch) ran in the iPhone Duo Simulator, half-folded in Device Hub, with a live Standard VNC session.
- **The Mac is mocked.** The session connected to a minimal local RFB server serving `raw/mac-desktop.png`. That is a ScreenCaptureKit grab of a Mac's wallpaper, desktop icons, Dock and menu bar, with all app windows excluded. Everything else on screen is real app UI.
- **Edits to app pixels:** only the free-session countdown, which subscribers never see, was removed. Under the trackpad toolbar it sits on pure black and is filled black. With the keyboard up it sits over the desktop, so the same pixels from `raw/mac-desktop.png` are pasted back in.
- **Device:** `device3d.py` builds a 3D model of the open Duo. The screen shape is the simulator's own inner-display mask (`chrome/inner-screen-mask.png`, rasterized from the iPhone Duo device type's framebuffer-mask PDF). The rim, bezel and hinge notches follow Device Hub's rendering. Each half is planar, so captures map onto it with an exact perspective transform.
- **Copy** matches shipped behavior. The trackpad hint in `ExternalSessionControllerView` reads "Move with one finger • Scroll with two • Two-finger tap to right-click".

Rebuild with `python3 compose.py` (or `python3 compose.py 02` for one image). Camera angles are per-shot in `SHOTS`.

## Uploaded

9 October 2026: uploaded to version 3.0 (en-US, which every other locale falls back to) as a new `APP_IPHONE_DUO` set. Receipt: `receipts/v3.0-duo-upload.json`.
