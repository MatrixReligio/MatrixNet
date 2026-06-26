#!/usr/bin/env bash
#
# Signs MatrixNet.app inside-out with Developer ID + Hardened Runtime, applying
# per-target entitlements (App Group). Used because the App Group capability
# makes Xcode's managed signing demand a provisioning profile, which Developer ID
# (non-App-Store) distribution does not need — codesign embeds the entitlement
# directly.
#
# Usage: ./scripts/sign.sh <path-to-MatrixNet.app>
set -euo pipefail

APP="${1:-build/Build/Products/Release/MatrixNet.app}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: MatrixReligio LLC (4DUQGD879H)}"
WIDGET="$APP/Contents/PlugIns/MatrixNetWidget.appex"
HELPER="$APP/Contents/MacOS/MatrixNetHelper"

echo "==> Signing privileged helper"
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$HELPER"

echo "==> Signing widget extension"
codesign --force --timestamp --options runtime \
  --entitlements Widget/MatrixNetWidget.entitlements \
  --sign "$IDENTITY" "$WIDGET"

echo "==> Signing app"
codesign --force --timestamp --options runtime \
  --entitlements App/MatrixNet.entitlements \
  --sign "$IDENTITY" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "OK"
