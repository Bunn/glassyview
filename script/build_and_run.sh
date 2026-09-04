#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="GlassyHost"
DISPLAY_NAME="Glassy Host"
BUNDLE_ID="dev.bunn.glassydesk.host"
CLOUDKIT_CONTAINER="iCloud.dev.bunn.dejaview"
EXPECTED_TEAM_IDENTIFIER="B2RUA6XMHC"

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

plist_array_contains() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local count
  local index
  local value
  if ! count="$(/usr/bin/plutil -extract "$key" raw -expect array -o - "$plist" 2>/dev/null)" \
      || [[ ! "$count" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  for ((index = 0; index < count; index++)); do
    value="$(/usr/bin/plutil -extract "$key.$index" raw -expect string -o - "$plist")"
    if [[ "$value" == "$expected" ]]; then
      return 0
    fi
  done
  return 1
}

plist_prefix_array_contains() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local count
  local index
  local value
  if ! count="$(/usr/bin/plutil -extract "$key" raw -expect array -o - "$plist" 2>/dev/null)" \
      || [[ ! "$count" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  for ((index = 0; index < count; index++)); do
    value="$(/usr/bin/plutil -extract "$key.$index" raw -expect string -o - "$plist")"
    if [[ "${value%.}" == "$expected" ]]; then
      return 0
    fi
  done
  return 1
}

profile_signing_identity() {
  local required_kind="$1"
  local identity_line
  local identity_pattern='^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"(.+)"$'
  local candidate_hash
  local candidate_name
  local valid_identities
  valid_identities="$(/usr/bin/security find-identity -v -p codesigning)"
  while IFS= read -r identity_line; do
    if [[ "$identity_line" =~ $identity_pattern ]]; then
      candidate_hash="${BASH_REMATCH[1]}"
      candidate_name="${BASH_REMATCH[2]}"
      if [[ "$candidate_name" == "$required_kind:"*"($EXPECTED_TEAM_IDENTIFIER)" \
            && "$PROFILE_CERTIFICATE_HASHES" == *"$candidate_hash"* ]]; then
        printf '%s' "$candidate_hash"
        return 0
      fi
    fi
  done <<< "$valid_identities"
  return 1
}

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build --package-path "$PACKAGE_DIR" --product "$APP_NAME"
BUILD_DIR="$(swift build --package-path "$PACKAGE_DIR" --show-bin-path)"

rm -rf "$STAGED_APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"
cp "$BUILD_DIR/$APP_NAME" "$STAGED_APP_BINARY"
cp "$PACKAGE_DIR/Support/Info.plist" "$APP_CONTENTS/Info.plist"
cp "$PACKAGE_DIR/Resources/GlassyHostAppIcon.icns" "$APP_RESOURCES/GlassyHostAppIcon.icns"
# Preserve Sparkle's framework symlinks and helper executable permissions.
/usr/bin/ditto "$BUILD_DIR/Sparkle.framework" "$SPARKLE_FRAMEWORK"
chmod +x "$STAGED_APP_BINARY"

# Reuse the profile imported for releases without exposing its base64 value.
# This makes the normal local command interoperate with Production CloudKit
# TestFlight clients when a matching Developer ID identity is installed.
PROVISIONING_PROFILE="${GLASSY_HOST_PROVISIONING_PROFILE:-}"
PROFILE_WORK_DIR=""
if [[ -z "$PROVISIONING_PROFILE" ]]; then
  PROFILE_WORK_DIR="$(mktemp -d "$DIST_DIR/.glassy-host-profile.XXXXXX")"
  trap 'if [[ -n "$PROFILE_WORK_DIR" ]]; then rm -rf "$PROFILE_WORK_DIR"; fi' EXIT
  SAVED_PROFILE="$PROFILE_WORK_DIR/GlassyHost.provisionprofile"
  if python3 "$ROOT_DIR/script/_materialize_host_cloudkit_profile.py" "$SAVED_PROFILE"; then
    PROVISIONING_PROFILE="$SAVED_PROFILE"
  else
    materialize_status="$?"
    if [[ "$materialize_status" -ne 3 ]]; then
      echo "Could not read the saved CloudKit provisioning profile." >&2
      exit 2
    fi
    rm -rf "$PROFILE_WORK_DIR"
    PROFILE_WORK_DIR=""
    trap - EXIT
  fi
elif [[ ! -f "$PROVISIONING_PROFILE" || -L "$PROVISIONING_PROFILE" ]]; then
  echo "GLASSY_HOST_PROVISIONING_PROFILE must name a regular provisioning profile file." >&2
  exit 2
fi

PROFILE_ENVIRONMENT_HINT=""
PROFILE_CERTIFICATE_HASHES=""
if [[ -n "$PROVISIONING_PROFILE" ]]; then
  if [[ -z "$PROFILE_WORK_DIR" ]]; then
    PROFILE_WORK_DIR="$(mktemp -d "$DIST_DIR/.glassy-host-profile.XXXXXX")"
    trap 'if [[ -n "$PROFILE_WORK_DIR" ]]; then rm -rf "$PROFILE_WORK_DIR"; fi' EXIT
  fi
  PROFILE_HINT="$PROFILE_WORK_DIR/profile-hint.plist"
  /usr/bin/security cms -D -i "$PROVISIONING_PROFILE" -o "$PROFILE_HINT"
  PROFILE_ENVIRONMENT_HINT="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-environment' "$PROFILE_HINT")"
  PROFILE_CERTIFICATE_COUNT_HINT="$(/usr/bin/plutil -extract DeveloperCertificates raw -expect array -o - "$PROFILE_HINT" 2>/dev/null || true)"
  if [[ ! "$PROFILE_CERTIFICATE_COUNT_HINT" =~ ^[1-9][0-9]*$ ]]; then
    echo "The CloudKit provisioning profile does not authorize a signing certificate." >&2
    exit 2
  fi
  for ((certificate_index = 0; certificate_index < PROFILE_CERTIFICATE_COUNT_HINT; certificate_index++)); do
    HINT_CERTIFICATE="$PROFILE_WORK_DIR/profile-certificate-$certificate_index.der"
    /usr/bin/plutil -extract "DeveloperCertificates.$certificate_index" raw -expect data -o - "$PROFILE_HINT" \
      | /usr/bin/base64 -D > "$HINT_CERTIFICATE"
    CERTIFICATE_HASH="$(/usr/bin/shasum -a 1 "$HINT_CERTIFICATE" | /usr/bin/awk '{ print toupper($1) }')"
    PROFILE_CERTIFICATE_HASHES="$PROFILE_CERTIFICATE_HASHES $CERTIFICATE_HASH"
  done
fi

CODESIGN_IDENTITY="${GLASSY_HOST_CODESIGN_IDENTITY:-}"
if [[ -z "$CODESIGN_IDENTITY" && "$PROFILE_ENVIRONMENT_HINT" == "Production" ]]; then
  CODESIGN_IDENTITY="$(profile_signing_identity "Developer ID Application" || true)"
fi
if [[ -z "$CODESIGN_IDENTITY" && "$PROFILE_ENVIRONMENT_HINT" == "Development" ]]; then
  CODESIGN_IDENTITY="$(profile_signing_identity "Apple Development" || true)"
fi
if [[ -z "$CODESIGN_IDENTITY" && -z "$PROVISIONING_PROFILE" ]]; then
  CODESIGN_IDENTITY="$(
    /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/awk -F '"' -v team="$EXPECTED_TEAM_IDENTIFIER" \
          '/Apple Development/ && index($0, "(" team ")") { print $2; exit }'
  )"
fi
if [[ -z "$CODESIGN_IDENTITY" && -z "$PROVISIONING_PROFILE" ]]; then
  CODESIGN_IDENTITY="$(
    /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/awk -F '"' '/Apple Development/ { print $2; exit }'
  )"
fi
if [[ -z "$CODESIGN_IDENTITY" ]]; then
  if [[ -n "$PROVISIONING_PROFILE" ]]; then
    echo "No installed signing identity matches the CloudKit provisioning profile." >&2
    exit 2
  else
    CODESIGN_IDENTITY="-"
  fi
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
PROFILE_INFO=""
PROFILE_APP_IDENTIFIER=""
PROFILE_TEAM_IDENTIFIER=""
PROFILE_ENVIRONMENT=""
PROFILE_CERTIFICATE_COUNT="0"
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  # Local ad-hoc builds have no team identity for hardened library validation.
  CODESIGN_ENTITLEMENTS="$PACKAGE_DIR/Support/GlassyHostAdHoc.entitlements"
else
  CODESIGN_ENTITLEMENTS="$PACKAGE_DIR/Support/GlassyHostLocal.entitlements"
  if [[ -n "$PROVISIONING_PROFILE" ]]; then
    PROFILE_INFO="$PROFILE_WORK_DIR/glassy-host-profile.plist"
    /usr/bin/security cms -D -i "$PROVISIONING_PROFILE" -o "$PROFILE_INFO"
    PROFILE_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-environment' "$PROFILE_INFO")"
    if ! PROFILE_APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_INFO" 2>/dev/null)"; then
      PROFILE_APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_INFO")"
    fi
    if PROFILE_LEGACY_APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_INFO" 2>/dev/null)" \
        && [[ "$PROFILE_LEGACY_APP_IDENTIFIER" != "$PROFILE_APP_IDENTIFIER" ]]; then
      echo "The provisioning profile contains conflicting Mac and legacy App IDs." >&2
      exit 2
    fi
    PROFILE_TEAM_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$PROFILE_INFO")"
    PROFILE_CERTIFICATE_COUNT="$(/usr/bin/plutil -extract DeveloperCertificates raw -expect array -o - "$PROFILE_INFO" 2>/dev/null || true)"
    PROFILE_PROVISIONS_ALL_DEVICES="$(/usr/bin/plutil -extract ProvisionsAllDevices raw -expect bool -o - "$PROFILE_INFO" 2>/dev/null || true)"
    PROFILE_EXPIRATION="$(/usr/bin/plutil -extract ExpirationDate raw -expect date -o - "$PROFILE_INFO" 2>/dev/null || true)"
    PROFILE_EXPIRATION_EPOCH="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$PROFILE_EXPIRATION" '+%s' 2>/dev/null || true)"
    case "$PROFILE_APP_IDENTIFIER" in
      *."$BUNDLE_ID")
        PROFILE_APP_IDENTIFIER_PREFIX="${PROFILE_APP_IDENTIFIER%.$BUNDLE_ID}"
        ;;
      *)
        PROFILE_APP_IDENTIFIER_PREFIX=""
        ;;
    esac
    PROFILE_PREFIX_MATCH=false
    if plist_prefix_array_contains "$PROFILE_INFO" ApplicationIdentifierPrefix "$PROFILE_APP_IDENTIFIER_PREFIX"; then
      PROFILE_PREFIX_MATCH=true
    fi
    PROFILE_TEAM_MATCH=false
    if plist_array_contains "$PROFILE_INFO" TeamIdentifier "$EXPECTED_TEAM_IDENTIFIER"; then
      PROFILE_TEAM_MATCH=true
    fi
    PROFILE_CONTAINER_MATCH=false
    if plist_array_contains "$PROFILE_INFO" \
        'Entitlements.com\.apple\.developer\.icloud-container-identifiers' "$CLOUDKIT_CONTAINER"; then
      PROFILE_CONTAINER_MATCH=true
    fi
    PROFILE_SERVICE_MATCH=false
    if plist_array_contains "$PROFILE_INFO" \
        'Entitlements.com\.apple\.developer\.icloud-services' CloudKit; then
      PROFILE_SERVICE_MATCH=true
    fi
    if [[ -z "$PROFILE_APP_IDENTIFIER_PREFIX" \
          || "$PROFILE_PREFIX_MATCH" != true \
          || "$PROFILE_TEAM_MATCH" != true \
          || "$PROFILE_TEAM_IDENTIFIER" != "$EXPECTED_TEAM_IDENTIFIER" \
          || ! "$PROFILE_CERTIFICATE_COUNT" =~ ^[1-9][0-9]*$ \
          || ! "$PROFILE_EXPIRATION_EPOCH" =~ ^[0-9]+$ \
          || "$PROFILE_EXPIRATION_EPOCH" -le "$(/bin/date -u '+%s')" \
          || ( "$PROFILE_ENVIRONMENT" == "Production" \
               && "$PROFILE_PROVISIONS_ALL_DEVICES" != "true" ) \
          || "$PROFILE_CONTAINER_MATCH" != true \
          || "$PROFILE_SERVICE_MATCH" != true ]]; then
      echo "The provisioning profile must grant this host bundle CloudKit access for the configured team." >&2
      exit 2
    fi
    BASE_ENTITLEMENTS=""
    case "$PROFILE_ENVIRONMENT" in
      Development)
        BASE_ENTITLEMENTS="$PACKAGE_DIR/Support/GlassyHostDevelopment.entitlements"
        ;;
      Production)
        BASE_ENTITLEMENTS="$PACKAGE_DIR/Support/GlassyHost.entitlements"
        ;;
      *)
        echo "The provisioning profile has no supported CloudKit environment." >&2
        exit 2
        ;;
    esac
    CODESIGN_ENTITLEMENTS="$PROFILE_WORK_DIR/GlassyHost-effective.entitlements"
    cp "$BASE_ENTITLEMENTS" "$CODESIGN_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $PROFILE_APP_IDENTIFIER" "$CODESIGN_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $PROFILE_TEAM_IDENTIFIER" "$CODESIGN_ENTITLEMENTS"
    /usr/bin/plutil -lint "$CODESIGN_ENTITLEMENTS"
    cp "$PROVISIONING_PROFILE" "$APP_CONTENTS/embedded.provisionprofile"
  else
    echo "warning: set GLASSY_HOST_PROVISIONING_PROFILE to enable private iCloud enrollment in this local build" >&2
  fi
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

if [[ -n "$PROFILE_APP_IDENTIFIER" ]]; then
  SIGNED_ENTITLEMENTS="$PROFILE_WORK_DIR/GlassyHost-signed.entitlements"
  /usr/bin/codesign --display --entitlements - --xml "$STAGED_APP_BUNDLE" > "$SIGNED_ENTITLEMENTS"
  SIGNED_APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$SIGNED_ENTITLEMENTS")"
  SIGNED_TEAM_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$SIGNED_ENTITLEMENTS")"
  SIGNED_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$SIGNED_ENTITLEMENTS")"
  SIGNED_CONTAINER_MATCH=false
  if plist_array_contains "$SIGNED_ENTITLEMENTS" \
      'com\.apple\.developer\.icloud-container-identifiers' "$CLOUDKIT_CONTAINER"; then
    SIGNED_CONTAINER_MATCH=true
  fi
  SIGNED_SERVICE_MATCH=false
  if plist_array_contains "$SIGNED_ENTITLEMENTS" \
      'com\.apple\.developer\.icloud-services' CloudKit; then
    SIGNED_SERVICE_MATCH=true
  fi
  SIGNING_DETAILS="$(/usr/bin/codesign -d --verbose=4 "$STAGED_APP_BUNDLE" 2>&1)"
  SIGNING_TEAM_IDENTIFIER="$(printf '%s\n' "$SIGNING_DETAILS" | /usr/bin/awk -F= '/^TeamIdentifier=/ { print $2 }')"
  if [[ "$SIGNED_APP_IDENTIFIER" != "$PROFILE_APP_IDENTIFIER" \
        || "$SIGNED_TEAM_IDENTIFIER" != "$EXPECTED_TEAM_IDENTIFIER" \
        || "$SIGNING_TEAM_IDENTIFIER" != "$EXPECTED_TEAM_IDENTIFIER" \
        || "$SIGNED_ENVIRONMENT" != "$PROFILE_ENVIRONMENT" \
        || "$SIGNED_CONTAINER_MATCH" != true \
        || "$SIGNED_SERVICE_MATCH" != true ]]; then
    echo "The signed app does not claim the CloudKit entitlements authorized by its profile." >&2
    exit 2
  fi

  SIGNER_CERTIFICATE_PREFIX="$PROFILE_WORK_DIR/glassy-host-signer-certificate"
  /usr/bin/codesign --display --extract-certificates "$SIGNER_CERTIFICATE_PREFIX" "$STAGED_APP_BUNDLE"
  SIGNER_CERTIFICATE="${SIGNER_CERTIFICATE_PREFIX}0"
  PROFILE_CERTIFICATE="$PROFILE_WORK_DIR/glassy-host-profile-certificate.der"
  CERTIFICATE_MATCH=false
  for ((certificate_index = 0; certificate_index < PROFILE_CERTIFICATE_COUNT; certificate_index++)); do
    /usr/bin/plutil -extract "DeveloperCertificates.$certificate_index" raw -expect data -o - "$PROFILE_INFO" \
      | /usr/bin/base64 -D > "$PROFILE_CERTIFICATE"
    if /usr/bin/cmp -s "$SIGNER_CERTIFICATE" "$PROFILE_CERTIFICATE"; then
      CERTIFICATE_MATCH=true
      break
    fi
  done
  if [[ "$CERTIFICATE_MATCH" != true ]]; then
    echo "The signing certificate is not authorized by the CloudKit provisioning profile." >&2
    exit 2
  fi
  rm -f "$PROFILE_INFO" "$PROFILE_CERTIFICATE" "$SIGNER_CERTIFICATE_PREFIX"{0,1,2,3,4}
fi

install_app() {
  local install_workspace
  local install_candidate
  local previous_install
  local had_previous_install=0

  install_workspace="$(mktemp -d "/Applications/.glassy-host-install.XXXXXX")"
  install_candidate="$install_workspace/$DISPLAY_NAME.app"
  previous_install="$install_workspace/Previous Glassy Host.app"

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
