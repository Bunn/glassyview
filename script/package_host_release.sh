#!/usr/bin/env bash
set +x
set -euo pipefail

# Prepare a Developer ID-signed universal app for notarization. This script never
# installs, launches, notarizes, publishes, or removes an existing artifact.
usage() {
  printf 'Usage: %s [--output-manifest PATH] [Developer ID Application identity name or SHA-1]\n' "$0"
  printf 'Alternatively set GLASSY_HOST_CODESIGN_IDENTITY. Outputs go into a new dist/host-release.* directory.\n'
  printf 'Set GLASSY_HOST_KEYCHAIN to use one explicit signing keychain without changing the search list.\n'
  printf 'The optional JSON manifest is created after successful packaging; its parent must exist and the file must not.\n'
}

OUTPUT_MANIFEST=""
POSITIONAL_IDENTITY=""
HAS_POSITIONAL_IDENTITY=false
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --output-manifest)
      if [[ "$#" -lt 2 || -z "$2" || "$2" == --* || -n "$OUTPUT_MANIFEST" ]]; then
        printf 'Provide exactly one nonempty PATH after --output-manifest.\n' >&2
        exit 2
      fi
      OUTPUT_MANIFEST="$2"
      shift 2
      ;;
    --)
      shift
      if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$HAS_POSITIONAL_IDENTITY" == true ) ]]; then
        usage >&2
        exit 2
      fi
      if [[ "$#" -eq 1 ]]; then
        POSITIONAL_IDENTITY="$1"
        HAS_POSITIONAL_IDENTITY=true
        shift
      fi
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ "$HAS_POSITIONAL_IDENTITY" == true ]]; then
        usage >&2
        exit 2
      fi
      POSITIONAL_IDENTITY="$1"
      HAS_POSITIONAL_IDENTITY=true
      shift
      ;;
  esac
done

REQUESTED_IDENTITY="${POSITIONAL_IDENTITY:-${GLASSY_HOST_CODESIGN_IDENTITY:-}}"
if [[ -z "$REQUESTED_IDENTITY" ]]; then
  printf 'A Developer ID Application signing identity is required.\n' >&2
  usage >&2
  exit 2
fi
PROVISIONING_PROFILE="${GLASSY_HOST_PROVISIONING_PROFILE:-}"
if [[ -z "$PROVISIONING_PROFILE" || ! -f "$PROVISIONING_PROFILE" || -L "$PROVISIONING_PROFILE" ]]; then
  printf 'GLASSY_HOST_PROVISIONING_PROFILE must name the CloudKit-enabled Developer ID provisioning profile.\n' >&2
  exit 2
fi
PROVISIONING_PROFILE="$(cd "$(dirname "$PROVISIONING_PROFILE")" && pwd)/$(basename "$PROVISIONING_PROFILE")"
if [[ -n "$OUTPUT_MANIFEST" ]]; then
  MANIFEST_PARENT="$(dirname "$OUTPUT_MANIFEST")"
  if [[ ! -d "$MANIFEST_PARENT" || -e "$OUTPUT_MANIFEST" || -L "$OUTPUT_MANIFEST" || "$OUTPUT_MANIFEST" == */ ]]; then
    printf 'The output manifest must be a new file in an existing directory.\n' >&2
    exit 2
  fi
  OUTPUT_MANIFEST="$(cd "$MANIFEST_PARENT" && pwd)/$(basename "$OUTPUT_MANIFEST")"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/GlassyHost"
RELEASE_CONFIG="$ROOT_DIR/script/host-release.json"
APP_NAME="GlassyHost"
DISPLAY_NAME="Glassy Host"
BUNDLE_ID="dev.bunn.glassydesk.host"
CLOUDKIT_CONTAINER="iCloud.dev.bunn.dejaview"
INFO_PLIST="$PACKAGE_DIR/Support/Info.plist"
ENTITLEMENTS="$PACKAGE_DIR/Support/GlassyHost.entitlements"
ICON="$PACKAGE_DIR/Resources/GlassyHostAppIcon.icns"

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

# Resolve only an exact, usable Developer ID Application identity. Never fall
# back to development or ad-hoc signing, and sign by hash to avoid ambiguity.
IDENTITY_COMMAND=(/usr/bin/security find-identity -v -p codesigning)
SIGNING_COMMAND=(/usr/bin/codesign)
if [[ -n "${GLASSY_HOST_KEYCHAIN:-}" ]]; then
  if [[ ! -f "$GLASSY_HOST_KEYCHAIN" ]]; then
    printf 'GLASSY_HOST_KEYCHAIN must name an existing keychain file.\n' >&2
    exit 2
  fi
  KEYCHAIN_PATH="$(cd "$(dirname "$GLASSY_HOST_KEYCHAIN")" && pwd)/$(basename "$GLASSY_HOST_KEYCHAIN")"
  IDENTITY_COMMAND+=("$KEYCHAIN_PATH")
  SIGNING_COMMAND+=(--keychain "$KEYCHAIN_PATH")
fi
VALID_IDENTITIES="$("${IDENTITY_COMMAND[@]}")"
IDENTITY_PATTERN='^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"(Developer ID Application: .+)"$'
REQUESTED_HASH="$(printf '%s' "$REQUESTED_IDENTITY" | /usr/bin/tr '[:lower:]' '[:upper:]')"
IDENTITY_COUNT=0
SIGNING_IDENTITY=""
SIGNING_IDENTITY_NAME=""
while IFS= read -r identity_line; do
  if [[ "$identity_line" =~ $IDENTITY_PATTERN ]]; then
    candidate_hash="${BASH_REMATCH[1]}"
    candidate_name="${BASH_REMATCH[2]}"
    if [[ "$REQUESTED_IDENTITY" == "$candidate_name" || "$REQUESTED_HASH" == "$candidate_hash" ]]; then
      SIGNING_IDENTITY="$candidate_hash"
      SIGNING_IDENTITY_NAME="$candidate_name"
      IDENTITY_COUNT=$((IDENTITY_COUNT + 1))
    fi
  fi
done <<< "$VALID_IDENTITIES"
if [[ "$IDENTITY_COUNT" -ne 1 ]]; then
  printf 'Expected exactly one valid Developer ID Application identity matching the requested name or SHA-1; found %s.\n' "$IDENTITY_COUNT" >&2
  exit 1
fi

for required_file in "$INFO_PLIST" "$ENTITLEMENTS" "$ICON" "$PACKAGE_DIR/Package.resolved" "$RELEASE_CONFIG"; do
  if [[ ! -f "$required_file" ]]; then
    printf 'Required release input is missing: %s\n' "$required_file" >&2
    exit 1
  fi
done
/usr/bin/plutil -lint "$INFO_PLIST" "$ENTITLEMENTS"
EXPECTED_TEAM_IDENTIFIER="$(/usr/bin/plutil -extract team_id raw -expect string -o - "$RELEASE_CONFIG")"
if [[ ! "$EXPECTED_TEAM_IDENTIFIER" =~ ^[A-Z0-9]{10}$ ]]; then
  printf 'The release configuration has no valid Apple Developer team identifier.\n' >&2
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")" != "$BUNDLE_ID" ]]; then
  printf 'The app bundle identifier does not match the release configuration.\n' >&2
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ || ! "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  printf 'Release version and build number must each contain one to three numeric components.\n' >&2
  exit 1
fi

# Match the dependency lockfile and reuse SwiftPM's normal build cache. Supplying
# both architectures makes SwiftPM produce one universal macOS executable.
BUILD_OPTIONS=(
  --package-path "$PACKAGE_DIR"
  --configuration release
  --product "$APP_NAME"
  --arch arm64
  --arch x86_64
  --force-resolved-versions
  -Xswiftc -warnings-as-errors
)
swift build "${BUILD_OPTIONS[@]}"
BUILD_DIR="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
SPARKLE_ARTIFACT="$PACKAGE_DIR/.build/artifacts/sparkle/Sparkle"
if [[ ! -d "$BUILD_DIR/Sparkle.framework" || ! -f "$SPARKLE_ARTIFACT/LICENSE" ]]; then
  printf 'The resolved Sparkle framework or its artifact-root LICENSE is missing.\n' >&2
  exit 1
fi
/usr/bin/xcrun lipo "$BUILD_DIR/$APP_NAME" -verify_arch arm64 x86_64

# Every invocation gets a fresh workspace. Failed output remains available for
# inspection; no cleanup trap can remove a previous or in-progress release.
mkdir -p "$ROOT_DIR/dist"
RELEASE_DIR="$(mktemp -d "$ROOT_DIR/dist/host-release.XXXXXX")"
ARCHIVE="$RELEASE_DIR/GlassyHost.xcarchive"
APP_BUNDLE="$ARCHIVE/Products/Applications/$DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_BINARY="$APP_CONTENTS/MacOS/$APP_NAME"
SPARKLE_FRAMEWORK="$APP_CONTENTS/Frameworks/Sparkle.framework"
SUBMISSION_ZIP="$RELEASE_DIR/GlassyHost-$VERSION-$BUILD_NUMBER-notarization.zip"
printf 'Release workspace: %s\n' "$RELEASE_DIR"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources" "$APP_CONTENTS/Frameworks"
cp "$BUILD_DIR/$APP_NAME" "$APP_BINARY"
cp "$INFO_PLIST" "$APP_CONTENTS/Info.plist"
cp "$ICON" "$APP_CONTENTS/Resources/GlassyHostAppIcon.icns"
cp "$SPARKLE_ARTIFACT/LICENSE" "$APP_CONTENTS/Resources/Sparkle-LICENSE.txt"
cp "$PROVISIONING_PROFILE" "$APP_CONTENTS/embedded.provisionprofile"
# Preserve the framework's version symlinks and helper executable permissions.
/usr/bin/ditto "$BUILD_DIR/Sparkle.framework" "$SPARKLE_FRAMEWORK"
chmod +x "$APP_BINARY"
/usr/libexec/PlistBuddy -c 'Set :GlassyHostPairingSecretStorage keychain' "$APP_CONTENTS/Info.plist"
# SwiftPM does not add Xcode's platform metadata to this hand-assembled bundle.
if ! /usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms' "$APP_CONTENTS/Info.plist" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c 'Add :CFBundleSupportedPlatforms array' "$APP_CONTENTS/Info.plist"
fi
/usr/bin/plutil -replace CFBundleSupportedPlatforms -json '["MacOSX"]' "$APP_CONTENTS/Info.plist"
if ! /usr/libexec/PlistBuddy -c 'Print :DTPlatformName' "$APP_CONTENTS/Info.plist" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c 'Add :DTPlatformName string macosx' "$APP_CONTENTS/Info.plist"
fi
/usr/bin/plutil -replace DTPlatformName -string macosx "$APP_CONTENTS/Info.plist"
/usr/bin/plutil -lint "$APP_CONTENTS/Info.plist"

# A Developer ID app needs an embedded distribution provisioning profile for
# CloudKit. Validate its identity and private-container grants before sealing it
# into the app, so a release cannot silently ship with enrollment disabled.
PROFILE_INFO="$RELEASE_DIR/embedded-profile.plist"
if ! /usr/bin/security cms -D -i "$PROVISIONING_PROFILE" -o "$PROFILE_INFO"; then
  printf 'The CloudKit provisioning profile could not be decoded.\n' >&2
  exit 1
fi
if ! PROFILE_APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_INFO" 2>/dev/null)"; then
  PROFILE_APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_INFO")"
fi
if PROFILE_LEGACY_APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_INFO" 2>/dev/null)" \
    && [[ "$PROFILE_LEGACY_APP_IDENTIFIER" != "$PROFILE_APP_IDENTIFIER" ]]; then
  printf 'The provisioning profile contains conflicting Mac and legacy App IDs.\n' >&2
  exit 1
fi
PROFILE_TEAM_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$PROFILE_INFO")"
PROFILE_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-environment' "$PROFILE_INFO")"
PROFILE_PROVISIONS_ALL_DEVICES="$(/usr/bin/plutil -extract ProvisionsAllDevices raw -expect bool -o - "$PROFILE_INFO" 2>/dev/null || true)"
PROFILE_CERTIFICATE_COUNT="$(/usr/bin/plutil -extract DeveloperCertificates raw -expect array -o - "$PROFILE_INFO" 2>/dev/null || true)"
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
      || "$PROFILE_TEAM_IDENTIFIER" != "$EXPECTED_TEAM_IDENTIFIER" \
      || "$PROFILE_PROVISIONS_ALL_DEVICES" != "true" \
      || ! "$PROFILE_CERTIFICATE_COUNT" =~ ^[1-9][0-9]*$ \
      || ! "$PROFILE_EXPIRATION_EPOCH" =~ ^[0-9]+$ \
      || "$PROFILE_EXPIRATION_EPOCH" -le "$(/bin/date -u '+%s')" \
      || "$PROFILE_PREFIX_MATCH" != true \
      || "$PROFILE_TEAM_MATCH" != true \
      || "$PROFILE_ENVIRONMENT" != "Production" \
      || "$PROFILE_CONTAINER_MATCH" != true \
      || "$PROFILE_SERVICE_MATCH" != true ]]; then
  printf 'The provisioning profile must be a matching Developer ID profile that grants this host Production CloudKit access.\n' >&2
  exit 1
fi

# codesign does not merge restricted entitlements from an embedded profile.
# Add the profile-authorized identity values to the narrow release allowlist.
EFFECTIVE_ENTITLEMENTS="$RELEASE_DIR/GlassyHost-effective.entitlements"
cp "$ENTITLEMENTS" "$EFFECTIVE_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $PROFILE_APP_IDENTIFIER" "$EFFECTIVE_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $PROFILE_TEAM_IDENTIFIER" "$EFFECTIVE_ENTITLEMENTS"
/usr/bin/plutil -lint "$EFFECTIVE_ENTITLEMENTS"

# Seal nested Sparkle code inside-out using this app's Developer ID identity.
# Keep the helpers' existing entitlements; the host uses only its normal
# entitlements file, never the development-only library-validation exception.
for sparkle_code in \
  "$SPARKLE_FRAMEWORK/Versions/Current/Autoupdate" \
  "$SPARKLE_FRAMEWORK/Versions/Current/Updater.app" \
  "$SPARKLE_FRAMEWORK/Versions/Current/XPCServices/Downloader.xpc" \
  "$SPARKLE_FRAMEWORK/Versions/Current/XPCServices/Installer.xpc" \
  "$SPARKLE_FRAMEWORK"; do
  "${SIGNING_COMMAND[@]}" \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    --preserve-metadata=entitlements \
    "$sparkle_code"
  /usr/bin/codesign --verify --strict "$sparkle_code"
done
"${SIGNING_COMMAND[@]}" \
  --force \
  --sign "$SIGNING_IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --options runtime \
  --timestamp \
  --entitlements "$EFFECTIVE_ENTITLEMENTS" \
  "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
/usr/bin/xcrun lipo "$APP_BINARY" -verify_arch arm64 x86_64
/usr/bin/xcrun lipo "$SPARKLE_FRAMEWORK/Sparkle" -verify_arch arm64 x86_64

SIGNING_DETAILS="$(/usr/bin/codesign -d --verbose=4 "$APP_BUNDLE" 2>&1)"
SIGNING_AUTHORITY="$(printf '%s\n' "$SIGNING_DETAILS" | /usr/bin/awk '/^Authority=/ { sub(/^Authority=/, ""); print; exit }')"
SIGNING_TIMESTAMP="$(printf '%s\n' "$SIGNING_DETAILS" | /usr/bin/awk '/^Timestamp=/ { sub(/^Timestamp=/, ""); print }')"
RUNTIME_PATTERN='flags=0x[[:xdigit:]]+\([^)]*runtime[^)]*\)'
if [[ "$SIGNING_AUTHORITY" != "$SIGNING_IDENTITY_NAME" || -z "$SIGNING_TIMESTAMP" || "$SIGNING_TIMESTAMP" == "none" || ! "$SIGNING_DETAILS" =~ $RUNTIME_PATTERN ]]; then
  printf 'The app signature must have the requested Developer ID Application authority, a secure timestamp, and hardened runtime.\n' >&2
  exit 1
fi
TEAM_ID="$(printf '%s\n' "$SIGNING_DETAILS" | /usr/bin/awk -F= '/^TeamIdentifier=/ { print $2 }')"
if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  printf 'The signed app does not have a valid Developer ID team identifier.\n' >&2
  exit 1
fi
if [[ "$TEAM_ID" != "$EXPECTED_TEAM_IDENTIFIER" || "$TEAM_ID" != "$PROFILE_TEAM_IDENTIFIER" ]]; then
  printf 'The Developer ID identity and CloudKit provisioning profile belong to different teams.\n' >&2
  exit 1
fi

SIGNED_ENTITLEMENTS="$RELEASE_DIR/GlassyHost-signed.entitlements"
if ! /usr/bin/codesign --display --entitlements - --xml "$APP_BUNDLE" > "$SIGNED_ENTITLEMENTS"; then
  printf 'The signed app entitlements could not be read.\n' >&2
  exit 1
fi
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
if [[ "$SIGNED_APP_IDENTIFIER" != "$PROFILE_APP_IDENTIFIER" \
      || "$SIGNED_TEAM_IDENTIFIER" != "$EXPECTED_TEAM_IDENTIFIER" \
      || "$SIGNED_ENVIRONMENT" != "$PROFILE_ENVIRONMENT" \
      || "$SIGNED_CONTAINER_MATCH" != true \
      || "$SIGNED_SERVICE_MATCH" != true ]]; then
  printf 'The signed app does not claim the Production CloudKit entitlements authorized by its profile.\n' >&2
  exit 1
fi

SIGNER_CERTIFICATE_PREFIX="$RELEASE_DIR/signer-certificate"
/usr/bin/codesign --display --extract-certificates "$SIGNER_CERTIFICATE_PREFIX" "$APP_BUNDLE"
SIGNER_CERTIFICATE="${SIGNER_CERTIFICATE_PREFIX}0"
PROFILE_CERTIFICATE="$RELEASE_DIR/profile-certificate.der"
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
  printf 'The signing certificate is not authorized by the CloudKit provisioning profile.\n' >&2
  exit 1
fi
rm -f "$PROFILE_INFO" "$PROFILE_CERTIFICATE" "$SIGNER_CERTIFICATE_PREFIX"{0,1,2,3,4}

# Standard archive metadata lets Xcode Organizer use the signed-in developer
# account for distribution. It is only an archive, not proof of notarization.
ARCHIVE_INFO="$ARCHIVE/Info.plist"
/usr/bin/plutil -create xml1 "$ARCHIVE_INFO"
/usr/bin/plutil -insert ArchiveVersion -integer 2 "$ARCHIVE_INFO"
/usr/bin/plutil -insert CreationDate -date "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$ARCHIVE_INFO"
/usr/bin/plutil -insert Name -string "$DISPLAY_NAME" "$ARCHIVE_INFO"
/usr/bin/plutil -insert SchemeName -string "$APP_NAME" "$ARCHIVE_INFO"
/usr/bin/plutil -insert ApplicationProperties -dictionary "$ARCHIVE_INFO"
/usr/bin/plutil -insert ApplicationProperties.ApplicationPath -string "Applications/$DISPLAY_NAME.app" "$ARCHIVE_INFO"
/usr/bin/plutil -insert ApplicationProperties.CFBundleIdentifier -string "$BUNDLE_ID" "$ARCHIVE_INFO"
/usr/bin/plutil -insert ApplicationProperties.CFBundleShortVersionString -string "$VERSION" "$ARCHIVE_INFO"
/usr/bin/plutil -insert ApplicationProperties.CFBundleVersion -string "$BUILD_NUMBER" "$ARCHIVE_INFO"
/usr/bin/plutil -insert ApplicationProperties.SigningIdentity -string "$SIGNING_IDENTITY_NAME" "$ARCHIVE_INFO"
/usr/bin/plutil -insert ApplicationProperties.Team -string "$TEAM_ID" "$ARCHIVE_INFO"
/usr/bin/plutil -insert ApplicationProperties.Architectures -array "$ARCHIVE_INFO"
/usr/bin/plutil -insert ApplicationProperties.Architectures.0 -string arm64 "$ARCHIVE_INFO"
/usr/bin/plutil -insert ApplicationProperties.Architectures.1 -string x86_64 "$ARCHIVE_INFO"
/usr/bin/plutil -lint "$ARCHIVE_INFO"
if [[ -d "$BUILD_DIR/$APP_NAME.dSYM" ]]; then
  /usr/bin/ditto "$BUILD_DIR/$APP_NAME.dSYM" "$ARCHIVE/dSYMs/$APP_NAME.dSYM"
fi

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$SUBMISSION_ZIP"
if [[ -n "$OUTPUT_MANIFEST" ]]; then
  # Build JSON through plutil so paths with quotes or Unicode remain valid.
  # Publish without overwriting a manifest created by a concurrent invocation.
  MANIFEST_TEMP="$(mktemp "$OUTPUT_MANIFEST.tmp.XXXXXX")"
  trap 'rm -f "$MANIFEST_TEMP"' EXIT
  /usr/bin/plutil -create xml1 "$MANIFEST_TEMP"
  /usr/bin/plutil -insert app -string "$APP_BUNDLE" "$MANIFEST_TEMP"
  /usr/bin/plutil -insert archive -string "$ARCHIVE" "$MANIFEST_TEMP"
  /usr/bin/plutil -insert submission_zip -string "$SUBMISSION_ZIP" "$MANIFEST_TEMP"
  /usr/bin/plutil -insert version -string "$VERSION" "$MANIFEST_TEMP"
  /usr/bin/plutil -insert build -string "$BUILD_NUMBER" "$MANIFEST_TEMP"
  /usr/bin/plutil -insert sparkle_tools -string "$SPARKLE_ARTIFACT/bin" "$MANIFEST_TEMP"
  /usr/bin/plutil -convert json "$MANIFEST_TEMP"
  ln -h "$MANIFEST_TEMP" "$OUTPUT_MANIFEST"
  rm -f "$MANIFEST_TEMP"
  trap - EXIT
fi
printf '\nSigned app: %s\nXcode archive: %s\nNotarization submission ZIP: %s\n' "$APP_BUNDLE" "$ARCHIVE" "$SUBMISSION_ZIP"
printf 'Not yet notarized or ready to publish. After acceptance, staple and validate the app, then create and Sparkle-sign a fresh download ZIP.\n'
