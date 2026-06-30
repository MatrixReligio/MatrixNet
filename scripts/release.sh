#!/usr/bin/env bash
#
# Build, sign (Developer ID), notarize, staple, and package MatrixNet into a DMG.
# Requires a stored notarytool keychain profile named "matrixnet-notary".
#
#   xcrun notarytool store-credentials matrixnet-notary \
#       --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
#
# Usage: ./scripts/release.sh [version]
set -euo pipefail

VERSION="${1:-0.1.0}"
VERSION="${VERSION#v}"
SCHEME="MatrixNet"
APP="build/Build/Products/Release/MatrixNet.app"
DIST="dist"
NOTARY_PROFILE="${NOTARY_PROFILE:-matrixnet-notary}"

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building $SCHEME ($VERSION)"
# Build unsigned, then sign inside-out: the App Group capability makes Xcode's
# managed signing demand a provisioning profile, which Developer ID does not need.
xcodebuild -project MatrixNet.xcodeproj -scheme "$SCHEME" -configuration Release \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO clean build

echo "==> Signing (Developer ID, inside-out)"
./scripts/sign.sh "$APP"

# A release must ship the GeoIP database (gitignored; built before this script in
# CI/locally). Without it the world map and country flags are blank — fail the
# release rather than silently shipping a broken map (regression guard). The 10 MB
# floor also asserts the IPv6 section is present: the IPv4-only table is ~3.5 MB,
# while IPv4+IPv6 (format v2) is ~15 MB, so a dropped IPv6 section fails here.
GEOIP="$APP/Contents/Resources/geoip.dat"
if [ ! -s "$GEOIP" ] || [ "$(stat -f%z "$GEOIP")" -lt 10000000 ]; then
  echo "ERROR: $GEOIP missing or too small (IPv6 section likely absent) — run scripts/build-geoip.sh." >&2
  exit 1
fi
echo "==> GeoIP database bundled ($(stat -f%z "$GEOIP") bytes)"

mkdir -p "$DIST"
DMG="$DIST/MatrixNet-$VERSION.dmg"

echo "==> Building DMG: $DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "MatrixNet" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

# Notarize the DMG itself (covers the signed app inside), then staple the DMG.
echo "==> Submitting DMG for notarization"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# Gatekeeper-verify the notarized app *inside* the DMG (running spctl directly on
# the DMG reports "no usable signature" because a DMG isn't code-signed — only
# notarized + stapled, which `stapler validate` above already checked — so a
# direct DMG assessment is not a meaningful check).
echo "==> Verifying app Gatekeeper acceptance"
MOUNT="$(mktemp -d)"
hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT"
# Capture spctl's own exit status: piping to `head` or appending `|| true` would
# mask a Gatekeeper rejection and let a broken build ship. `|| status=$?` keeps
# `set -e` from aborting before we can clean up the mount.
gatekeeper_status=0
spctl -a -t exec -vvv "$MOUNT/MatrixNet.app" || gatekeeper_status=$?
hdiutil detach "$MOUNT" -quiet || true
rm -rf "$MOUNT"
if [ "$gatekeeper_status" -ne 0 ]; then
  echo "ERROR: Gatekeeper rejected the app inside the DMG (spctl status $gatekeeper_status)." >&2
  exit 1
fi

# Generate the EdDSA-signed Sparkle appcast so auto-update can detect this build.
# generate_appcast reads the DMG's version, signs it with the EdDSA private key
# (from the login keychain locally, or SPARKLE_PRIVATE_KEY in CI), and writes
# dist/appcast.xml whose enclosure URL points at the GitHub release asset.
SPARKLE_BIN="${SPARKLE_BIN:-}"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
[ -n "$SPARKLE_BIN" ] || GENERATE_APPCAST="$(command -v generate_appcast || true)"
if [ -x "$GENERATE_APPCAST" ]; then
  echo "==> Generating Sparkle appcast"
  KEYARGS=()
  KEYFILE=""
  if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    # generate_appcast's --ed-key-file needs a real file path (process
    # substitution /dev/fd/* is not seekable and fails to load).
    KEYFILE="$(mktemp)"
    printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEYFILE"
    KEYARGS=(--ed-key-file "$KEYFILE")
  fi
  # Expand KEYARGS only if non-empty: under `set -u`, macOS's bash 3.2 treats
  # "${KEYARGS[@]}" on an empty array as an unbound variable and aborts. The
  # `${arr[@]+"${arr[@]}"}` idiom expands to nothing when empty (local runs sign
  # with the login-keychain key and set no --ed-key-file), else to the elements.
  "$GENERATE_APPCAST" ${KEYARGS[@]+"${KEYARGS[@]}"} \
    --download-url-prefix "https://github.com/MatrixReligio/MatrixNet/releases/download/v$VERSION/" \
    "$DIST"
  [ -n "$KEYFILE" ] && rm -f "$KEYFILE"
  echo "appcast: $DIST/appcast.xml"
else
  echo "WARN: generate_appcast not found (set SPARKLE_BIN); skipping appcast." >&2
fi

echo "==> Done: $DMG"
