#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="GlassyHost"
DISPLAY_NAME="Glassy Desk"
BUNDLE_ID="dev.bunn.glassydesk.host"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/GlassyHost"
DIST_DIR="$ROOT_DIR/dist"
STAGED_APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"
INSTALLED_APP_BUNDLE="/Applications/$DISPLAY_NAME.app"
APP_CONTENTS="$STAGED_APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
SPARKLE_FRAMEWORK="$APP_FRAMEWORKS/Sparkle.framework"
STAGED_APP_BINARY="$APP_MACOS/$APP_NAME"
INSTALLED_APP_BINARY="$INSTALLED_APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [[ "$MODE" == "--preview" ]]; then
  # Replace only an earlier preview from this checkout. The installed app may
  # be serving a paired device and must keep its listener and identity.
  for preview_pid in $(pgrep -x "$APP_NAME" || true); do
    preview_command="$(ps -p "$preview_pid" -o args= 2>/dev/null || true)"
    if [[ "$preview_command" == "$STAGED_APP_BINARY --glassy-preview" ]]; then
      kill "$preview_pid" 2>/dev/null || true
    fi
  done
else
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

swift build --package-path "$PACKAGE_DIR" --product "$APP_NAME"
BUILD_DIR="$(swift build --package-path "$PACKAGE_DIR" --show-bin-path)"

rm -rf "$STAGED_APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"
cp "$BUILD_DIR/$APP_NAME" "$STAGED_APP_BINARY"
cp "$PACKAGE_DIR/Support/Info.plist" "$APP_CONTENTS/Info.plist"
"$ROOT_DIR/script/compile_host_icon.sh" "$APP_CONTENTS"
# SwiftPM resource bundles must travel with the installed app for localization.
/usr/bin/ditto "$BUILD_DIR/PermissionFlow_PermissionFlow.bundle" "$APP_RESOURCES/PermissionFlow_PermissionFlow.bundle"
cp "$PACKAGE_DIR/.build/checkouts/PermissionFlow/LICENSE" "$APP_RESOURCES/PermissionFlow-LICENSE.txt"
# Preserve Sparkle's framework symlinks and helper executable permissions.
/usr/bin/ditto "$BUILD_DIR/Sparkle.framework" "$SPARKLE_FRAMEWORK"
chmod +x "$STAGED_APP_BINARY"

CODESIGN_IDENTITY="${GLASSY_HOST_CODESIGN_IDENTITY:-}"
if [[ -z "$CODESIGN_IDENTITY" ]]; then
  CODESIGN_IDENTITY="$(
    /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/awk -F '"' '/Apple Development/ && /B2RUA6XMHC/ { print $2; exit }'
  )"
fi
if [[ -z "$CODESIGN_IDENTITY" ]]; then
  CODESIGN_IDENTITY="$(
    /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/awk -F '"' '/Apple Development/ { print $2; exit }'
  )"
fi
if [[ -z "$CODESIGN_IDENTITY" ]]; then
  CODESIGN_IDENTITY="-"
fi
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "warning: using ad-hoc signing for local development" >&2
  echo "warning: Screen Recording permission may need to be granted again after rebuilds" >&2
else
  /usr/libexec/PlistBuddy \
    -c "Set :GlassyHostPairingSecretStorage keychain" \
    "$APP_CONTENTS/Info.plist"
fi

CODESIGN_ENTITLEMENTS="$PACKAGE_DIR/Support/GlassyHost.entitlements"
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  # Local ad-hoc builds have no team identity for hardened library validation.
  CODESIGN_ENTITLEMENTS="$PACKAGE_DIR/Support/GlassyHostAdHoc.entitlements"
fi

# Sign nested code inside-out with the host's identity before sealing the app.
for sparkle_code in \
  "$SPARKLE_FRAMEWORK/Versions/Current/Autoupdate" \
  "$SPARKLE_FRAMEWORK/Versions/Current/Updater.app" \
  "$SPARKLE_FRAMEWORK/Versions/Current/XPCServices/Downloader.xpc" \
  "$SPARKLE_FRAMEWORK/Versions/Current/XPCServices/Installer.xpc" \
  "$SPARKLE_FRAMEWORK"; do
  /usr/bin/codesign \
    --force \
    --sign "$CODESIGN_IDENTITY" \
    --options runtime \
    --preserve-metadata=entitlements \
    "$sparkle_code" >/dev/null
done

/usr/bin/codesign \
  --force \
  --sign "$CODESIGN_IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --options runtime \
  --entitlements "$CODESIGN_ENTITLEMENTS" \
  "$STAGED_APP_BUNDLE" >/dev/null

install_app() {
  local install_workspace
  local install_candidate
  local previous_install
  local had_previous_install=0

  install_workspace="$(mktemp -d "/Applications/.glassy-host-install.XXXXXX")"
  install_candidate="$install_workspace/$DISPLAY_NAME.app"
  previous_install="$install_workspace/Previous Glassy Desk.app"

  /usr/bin/ditto "$STAGED_APP_BUNDLE" "$install_candidate"
  /usr/bin/codesign --verify --deep --strict "$install_candidate"

  if [[ -e "$INSTALLED_APP_BUNDLE" || -L "$INSTALLED_APP_BUNDLE" ]]; then
    /bin/mv "$INSTALLED_APP_BUNDLE" "$previous_install"
    had_previous_install=1
  fi

  if /bin/mv "$install_candidate" "$INSTALLED_APP_BUNDLE"; then
    /bin/rm -rf "$install_workspace"
    echo "Installed $DISPLAY_NAME at $INSTALLED_APP_BUNDLE"
    return
  fi

  if [[ "$had_previous_install" -eq 1 ]]; then
    /bin/mv "$previous_install" "$INSTALLED_APP_BUNDLE"
  fi
  /bin/rm -rf "$install_workspace"
  echo "Could not install $DISPLAY_NAME in /Applications." >&2
  return 1
}

if [[ "$MODE" != "--preview" ]]; then
  install_app
fi

open_app() {
  /usr/bin/open -n "$INSTALLED_APP_BUNDLE"
}

case "$MODE" in
  --preview)
    /usr/bin/open -n "$STAGED_APP_BUNDLE" --args --glassy-preview
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$INSTALLED_APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _ in {1..20}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        sleep 1
        if pgrep -x "$APP_NAME" >/dev/null; then
          exit 0
        fi
        break
      fi
      sleep 0.25
    done
    echo "$DISPLAY_NAME did not remain running after launch." >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--preview|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
