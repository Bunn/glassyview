#!/usr/bin/env bash
set -euo pipefail

# Prepare a Developer ID-signed universal app for notarization. This script never
# installs, launches, notarizes, publishes, or removes an existing artifact.
usage() {
  printf 'Usage: %s [Developer ID Application identity name or SHA-1]\n' "$0"
  printf 'Alternatively set GLASSY_HOST_CODESIGN_IDENTITY. Outputs go into a new dist/host-release.* directory.\n'
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if [[ "$#" -gt 1 ]]; then
  usage >&2
  exit 2
fi

REQUESTED_IDENTITY="${1:-${GLASSY_HOST_CODESIGN_IDENTITY:-}}"
if [[ -z "$REQUESTED_IDENTITY" ]]; then
  printf 'A Developer ID Application signing identity is required.\n' >&2
  usage >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/GlassyHost"
APP_NAME="GlassyHost"
DISPLAY_NAME="Glassy Host"
BUNDLE_ID="dev.bunn.glassydesk.host"
INFO_PLIST="$PACKAGE_DIR/Support/Info.plist"
ENTITLEMENTS="$PACKAGE_DIR/Support/GlassyHost.entitlements"
ICON="$PACKAGE_DIR/Resources/GlassyHostAppIcon.icns"

# Resolve only an exact, usable Developer ID Application identity. Never fall
# back to development or ad-hoc signing, and sign by hash to avoid ambiguity.
VALID_IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning)"
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

for required_file in "$INFO_PLIST" "$ENTITLEMENTS" "$ICON" "$PACKAGE_DIR/Package.resolved"; do
  if [[ ! -f "$required_file" ]]; then
    printf 'Required release input is missing: %s\n' "$required_file" >&2
    exit 1
  fi
done
/usr/bin/plutil -lint "$INFO_PLIST" "$ENTITLEMENTS"
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

# Seal nested Sparkle code inside-out using this app's Developer ID identity.
# Keep the helpers' existing entitlements; the host uses only its normal
# entitlements file, never the development-only library-validation exception.
for sparkle_code in \
  "$SPARKLE_FRAMEWORK/Versions/Current/Autoupdate" \
  "$SPARKLE_FRAMEWORK/Versions/Current/Updater.app" \
  "$SPARKLE_FRAMEWORK/Versions/Current/XPCServices/Downloader.xpc" \
  "$SPARKLE_FRAMEWORK/Versions/Current/XPCServices/Installer.xpc" \
  "$SPARKLE_FRAMEWORK"; do
  /usr/bin/codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    --preserve-metadata=entitlements \
    "$sparkle_code"
  /usr/bin/codesign --verify --strict "$sparkle_code"
done
/usr/bin/codesign \
  --force \
  --sign "$SIGNING_IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --options runtime \
  --timestamp \
  --entitlements "$ENTITLEMENTS" \
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
printf '\nSigned app: %s\nXcode archive: %s\nNotarization submission ZIP: %s\n' "$APP_BUNDLE" "$ARCHIVE" "$SUBMISSION_ZIP"
printf 'Not yet notarized or ready to publish. After acceptance, staple and validate the app, then create and Sparkle-sign a fresh download ZIP.\n'
