# iPhone and iPad screenshots — October 2026

Six App Store screenshots each for iPhone (`APP_IPHONE_67`, 1320 × 2868) and iPad (`APP_IPAD_PRO_3GEN_129`, 2064 × 2752). They replace a set that mixed dark and light artwork and carried up to four lines of copy per image. Every image here follows one recipe: dark navy background, a single headline line, and the device as the subject. The app itself is shown in its dark appearance.

| # | Headline (iPhone / iPad) | Capture |
|---|---|---|
| 01 | Your Mac, in your pocket. / Your Mac, in your hands. | Hosts list behind, live landscape session in front |
| 02 | Every Mac, one tap away. | Hosts list |
| 03 | Type with real Mac keys. | Live session with the Mac key strip |
| 04 | Two ways to connect. | Add Mac |
| 05 | Pair once. Connect fast. | Fast Connection setup |
| 06 | Big screen. Full control. | External-display controller: trackpad and Mac keys on the device, the Mac on a display above |

Not uploaded to App Store Connect yet.

## How they were made

- **Captures** in `raw/` are `xcrun simctl io <device> screenshot` grabs of Glassy Desk 3.1 (`fe7d45e`) in the "Glassy Marketing Sep22" iPhone 16 Pro Max and iPad Pro 13-inch simulators, with the system in dark mode and the status bar overridden to 9:41.
- **The Mac is mocked.** Sessions connected over Standard VNC to `rfb_server.py`, a minimal RFB server that serves `raw/mac-desktop.png` (the same wallpaper-and-Dock grab the Duo set uses). Run it with `python3 rfb_server.py raw/mac-desktop.png 5901`.
- **Device bodies** are drawn by `compose.py`; they are simple dark frames, not Apple's product art.
- **Image 06** shows the real controller screen, but the simulator would not attach an external display: `simctl io screenConfig` powers one on, yet iOS never hands the app a scene for it. The controller captures therefore come from a local debug build in which `ExternalDisplayCoordinator.isExternalDisplayAvailable` starts as `true` behind a `--capture-external-display` launch argument. That change was never committed. The display above the device is drawn by `compose.py` and shows `raw/mac-desktop.png`; it is not a capture of an external screen.

Rebuild with `python3 compose.py` (or `python3 compose.py ipad 02` for one image).

## Edits to app pixels

- **Free-session countdown removed** from the live-session and controller captures, since subscribers never see it. `compose.py` does this in `prepare()`; those files in `raw/` still show it. It sits on black except in `iphone-landscape.png`, where the same desktop pixels are pasted back.
- **Host addresses and one name redrawn** in the Hosts list. The simulator reached the mock Mac at `127.0.0.1:5901` and `:5902`, and Bonjour discovered the build machine by its real name and public address. The images show `192.168.1.x:5900` addresses and "Mac mini" instead. Tile layout, status, and the Fast Connection badge are as captured. Because this repository is public, the redraw is baked into `raw/iphone-hosts.png`, `raw/ipad-hosts.png`, `raw/ipad-add-mac.png`, and `raw/ipad-fast.png`; the original captures are not kept here.
