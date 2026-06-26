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

mkdir -p "$DIST"
ZIP="$DIST/MatrixNet.zip"
echo "==> Submitting for notarization"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$ZIP"

echo "==> Stapling ticket"
xcrun stapler staple "$APP"

DMG="$DIST/MatrixNet-$VERSION.dmg"
echo "==> Building DMG: $DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "MatrixNet" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo "==> Stapling DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Done: $DMG"
