#!/usr/bin/env bash
set -euo pipefail

# Compile the same icon for local and distribution bundles before code signing.
if [[ "$#" -ne 1 || ! -f "$1/Info.plist" ]]; then
  printf 'Usage: %s APP_CONTENTS_DIRECTORY\n' "$0" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_CONTENTS="$1"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$INFO_PLIST")"
MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"
ICON_SOURCE="$ROOT_DIR/GlassyHost/Resources/$ICON_NAME.icon"
if [[ ! -f "$ICON_SOURCE/icon.json" ]]; then
  printf 'The Icon Composer source is missing: %s\n' "$ICON_SOURCE" >&2
  exit 1
fi

ICON_WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/glassy-host-icon.XXXXXX")"
trap 'rm -rf "$ICON_WORKSPACE"' EXIT
mkdir -p "$ICON_WORKSPACE/compiled" "$APP_CONTENTS/Resources"

# Keep fallback generation enabled: macOS 14/15 and the DMG volume still need
# the compiler's flattened representations; macOS 26 uses the icon stack.
/usr/bin/xcrun actool \
  --output-format human-readable-text \
  --notices --warnings --errors \
  --platform macosx \
  --target-device mac \
  --lightweight-asset-runtime-mode enabled \
  --app-icon "$ICON_NAME" \
  --minimum-deployment-target "$MINIMUM_OS" \
  --output-partial-info-plist "$ICON_WORKSPACE/Info.plist" \
  --compile "$ICON_WORKSPACE/compiled" \
  "$ICON_SOURCE"

for key in CFBundleIconName CFBundleIconFile; do
  compiled_name="$(/usr/libexec/PlistBuddy -c "Print :$key" "$ICON_WORKSPACE/Info.plist")"
  bundle_name="$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST")"
  if [[ "$compiled_name" != "$bundle_name" ]]; then
    printf 'Compiled icon metadata does not match %s in the app Info.plist.\n' "$key" >&2
    exit 1
  fi
done
for resource in Assets.car "$ICON_NAME.icns"; do
  if [[ ! -s "$ICON_WORKSPACE/compiled/$resource" ]]; then
    printf 'The icon compiler did not produce %s. Use Xcode 26 or later.\n' "$resource" >&2
    exit 1
  fi
  cp "$ICON_WORKSPACE/compiled/$resource" "$APP_CONTENTS/Resources/$resource"
done
