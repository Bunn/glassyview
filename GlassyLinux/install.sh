#!/usr/bin/env bash
# Builds Glassy Desk for Linux and installs it for the current user:
#   ~/.local/bin/glassy-desk  and an app-launcher entry.
set -euo pipefail

cd "$(dirname "$0")"

missing=()
pkg-config --exists libavcodec || missing+=(ffmpeg)
pkg-config --exists sdl2 || missing+=(sdl2-compat)
command -v cargo >/dev/null || missing+=(rust)
command -v clang >/dev/null || missing+=(clang)
if (( ${#missing[@]} )); then
  echo "Install the build dependencies first:  sudo pacman -S --needed ${missing[*]}" >&2
  exit 1
fi

cargo build --release
install -Dm755 target/release/glassy-desk "$HOME/.local/bin/glassy-desk"
"$HOME/.local/bin/glassy-desk" install-desktop

# Omarchy bar widget (skipped on other desktops).
if command -v omarchy-shell >/dev/null; then
  plugin_dir="$HOME/.config/omarchy/plugins/glassydesk.macs"
  mkdir -p "$plugin_dir"
  cp omarchy-plugin/manifest.json omarchy-plugin/Panel.qml "$plugin_dir/"
  omarchy-shell -q shell rescanPlugins
  if ! grep -q '"glassydesk.macs"' "$HOME/.config/omarchy/shell.json" 2>/dev/null; then
    omarchy plugin enable glassydesk.macs --after omarchy.tailscale || omarchy plugin enable glassydesk.macs --section right
  fi
  echo "Installed the Glassy Desk bar widget"
fi

echo
echo "Installed ~/.local/bin/glassy-desk"
echo "Pair with your Mac:   glassy-desk pair            (discovers nearby Macs)"
echo "                      glassy-desk pair <address>  (Tailscale or a specific IP)"
echo "Then connect:         glassy-desk                 (or 'Glassy Desk' in the app launcher)"
