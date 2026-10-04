# Glassy Desk for Linux

A Fast Connection client for [Glassy Desk for Mac](../GlassyHost/README.md), built for Omarchy (Arch + Hyprland) and other Wayland or X11 desktops. It speaks the same encrypted Glassy Stream v1 protocol as the iPhone/iPad app, including pairing, resume credentials, adaptive delivery, keyboard, pointer, scroll, quality presets, and clipboard paste.

## Install

Omarchy already ships everything the build needs except, possibly, Rust and clang:

```sh
sudo pacman -S --needed rust clang ffmpeg sdl2-compat   # skip what you have
./GlassyLinux/install.sh
```

This builds a release binary, installs `~/.local/bin/glassy-desk`, and adds a **Glassy Desk** entry to the app launcher.

Hardware decoding uses VA-API. Intel GPUs need `intel-media-driver` (Omarchy installs it on Intel machines). Use `--software-decode` to rule VA-API out while troubleshooting.

## Pair and connect

On the Mac, open Glassy Desk → **Connections → Add Device → Pair Manually** to show the rotating 12-symbol code. Then on Linux:

```sh
glassy-desk pair                    # finds Macs on the local network, asks for the code
glassy-desk pair 192.168.1.20       # or pair a specific address
glassy-desk pair mac.tailnet.ts.net --password   # reusable password, Tailscale routes only
```

After pairing, the viewer opens immediately. The Mac shows this computer (by hostname) in Connections, where you can revoke it.

Later connections resume with a saved device credential, so no code is needed:

```sh
glassy-desk                         # one saved Mac: connects; several: shows a picker
glassy-desk connect mini            # by name (or unique prefix) or address
glassy-desk list
glassy-desk status                  # online / offline / connected (--json, --nearby)
glassy-desk disconnect mini
glassy-desk forget mini
glassy-desk discover
```

When it's started from the app launcher, pickers and prompts use Omarchy's own menu (`omarchy-menu-select` / `omarchy-menu-input`).

## Using the viewer

| Linux | Mac |
| --- | --- |
| Super | ⌘ Command |
| Alt | ⌥ Option |
| Ctrl | ⌃ Control (`--ctrl-as-cmd` swaps Ctrl and Super) |
| Left / right click, wheel, touchpad scroll | same |

Press **Super+F** (Omarchy's fullscreen binding) to make the stream fullscreen. While fullscreen, the window captures every shortcut (Wayland keyboard-shortcuts-inhibit), so Super+Tab, Super+Space and similar go to the Mac. Only Super+F stays local: it leaves fullscreen and gives the keyboard back. In a normal window, Hyprland and Omarchy handle Super combinations first, and only keys they don't bind reach the Mac.

The other local hotkeys all use **Ctrl+Alt+Shift**:

| Hotkey | Action |
| --- | --- |
| Ctrl+Alt+Shift+G | Turn fullscreen keyboard capture off or on |
| Ctrl+Alt+Shift+F | Toggle fullscreen |
| Ctrl+Alt+Shift+V | Paste the Linux clipboard into the Mac's active app |
| Ctrl+Alt+Shift+1 / 2 / 3 | Data Saver / Balanced / Best quality (remembered per Mac) |
| Ctrl+Alt+Shift+C | Show or hide the local pointer |
| Ctrl+Alt+Shift+Q | Disconnect |

The Mac cursor is part of the video, so the Linux pointer is hidden over the window by default (`--show-local-cursor` keeps it visible). Keys and buttons held while the window loses focus are released on the Mac so modifiers never get stuck. If the network drops, the viewer reconnects automatically with the saved credential. Host status, such as view-only mode, missing Mac permissions or a sleeping display, appears in the window title and as a desktop notification.

Other options: `--quality data-saver|balanced|best`, `--fullscreen`, `--no-keyboard-grab`, `--invert-scroll`, `--scroll-speed 2.0`.

### Omarchy bar widget

`install.sh` also installs the **Glassy Desk** bar widget (`omarchy-plugin/`, installed as `~/.config/omarchy/plugins/glassydesk.macs/`) and places it after Tailscale. It follows the Tailscale and Agents widgets:

- The icon is dimmed when no paired Mac is reachable and highlighted while a viewer is open. Its tooltip shows the counts.
- **Left click** opens a panel listing your Macs as connected, online or offline, plus unpaired Macs found nearby. Click a Mac to connect, or to focus its viewer if one is already open. The ✕ on a connected Mac disconnects it, and a nearby Mac or **Pair a Mac…** opens pairing in a floating terminal. Arrow keys and Enter work in the panel.
- **Right click** connects to the most recently used reachable Mac. **Middle click** refreshes.

The widget reads `glassy-desk status --json`, which checks reachability with a plain TCP connect (like the iOS app) and never authenticates. Open it from a keybinding with `omarchy-shell shell toggle glassydesk.macs`. Remove it with `omarchy plugin disable glassydesk.macs`.

### Hyprland

The window class is `dev.bunn.glassydesk.linux`, for example:

```ini
windowrule = workspace 5, class:dev.bunn.glassydesk.linux
bind = SUPER SHIFT, M, exec, glassy-desk connect mini
```

## Security and storage

- Pairing follows the iOS app: an X25519 exchange authenticated with HMAC over the transcript, keyed by the one-time code, the PBKDF2-derived password credential, or the per-device resume secret. All traffic after that is AES-256-GCM with direction-separated nonces and strict sequence checks.
- Saved Macs live in `~/.local/share/glassy-desk/machines.json`, mode 0600 in a 0700 directory. The code and password are never stored, only the random host-bound resume secret the Mac issues. `forget` deletes it locally; revoke the device on the Mac to invalidate it there.
- A saved Mac is pinned to its host identity. Connecting to an address that answers as a different Mac fails instead of silently authenticating.
- Password pairing is refused unless the address is a Tailscale IP (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) or a full `.ts.net` name, as on iOS.

## Remote Macs over Tailscale

Bonjour discovery only covers the local network. For a remote Mac, pair with its Tailscale address or MagicDNS name. Enter the rotating code, or `--password` if one is configured on the Mac. Don't expose TCP 51515 publicly.

## Layout

| File | Role |
| --- | --- |
| `src/wire.rs` | Frame format, message layouts, transcript and key schedule (mirrors `HostProtocol.swift`) |
| `src/session.rs` | Route race, handshake, reader thread, ordered encrypted sender |
| `src/decoder.rs` | libavcodec H.264 (VA-API → NV12, or software I420), newest-frame mailbox, receiver feedback |
| `src/viewer.rs` | SDL window, rendering, input, hotkeys, keep-alive pings, reconnect |
| `src/keymap.rs` | SDL keycodes → X11 keysyms the host maps to Mac virtual keys |
| `src/password.rs` | Pairing-password NFC/PBKDF2 derivation and Tailscale address policy |
| `src/store.rs` | Saved Macs and resume credentials |
| `src/discover.rs` | `_glassydesk._tcp` Bonjour browsing |

Run the tests with `cargo test`. The PBKDF2 test uses the host's fixed protocol vector, so a key-schedule drift fails locally.
