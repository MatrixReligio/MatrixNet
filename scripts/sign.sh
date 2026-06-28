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
# Secure timestamp by default (required for notarization). A local-only install
# can pass TIMESTAMP=--timestamp=none to avoid contacting Apple's timestamp
# server (e.g. when a VPN/proxy blocks it); such a build is NOT notarizable.
TS="${TIMESTAMP:---timestamp}"
WIDGET="$APP/Contents/PlugIns/MatrixNetWidget.appex"
HELPER="$APP/Contents/MacOS/MatrixNetHelper"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

# Sparkle ships nested helpers (XPC services, the updater app, the Autoupdate
# tool) that must each be signed inside-out with Hardened Runtime before the
# framework and the app, or notarization/Gatekeeper rejects them.
if [ -d "$SPARKLE" ]; then
  echo "==> Signing Sparkle components"
  SV="$SPARKLE/Versions/B"
  codesign --force $TS --options runtime --sign "$IDENTITY" \
    "$SV/XPCServices/Downloader.xpc" \
    "$SV/XPCServices/Installer.xpc"
  codesign --force $TS --options runtime --sign "$IDENTITY" \
    "$SV/Updater.app"
  codesign --force $TS --options runtime --sign "$IDENTITY" \
    "$SV/Autoupdate"
  codesign --force $TS --options runtime --sign "$IDENTITY" "$SPARKLE"
fi

echo "==> Signing privileged helper"
codesign --force $TS --options runtime --sign "$IDENTITY" "$HELPER"

echo "==> Signing widget extension"
codesign --force $TS --options runtime \
  --entitlements Widget/MatrixNetWidget.entitlements \
  --sign "$IDENTITY" "$WIDGET"

echo "==> Signing app"
codesign --force $TS --options runtime \
  --entitlements App/MatrixNet.entitlements \
  --sign "$IDENTITY" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"

# The widget is a sandboxed extension that reads live metrics from the shared App
# Group container. If codesign drops the group from its entitlements the widget
# silently shows no data, so assert the group survived signing.
echo "==> Verifying widget App Group entitlement"
if ! codesign -d --entitlements - "$WIDGET" 2>/dev/null \
    | grep -q "4DUQGD879H.com.matrixreligio.matrixnet"; then
  echo "ERROR: widget is missing the App Group entitlement after signing" >&2
  codesign -d --entitlements - "$WIDGET" 2>/dev/null | grep -A3 application-groups >&2 || true
  exit 1
fi

# The main app must keep the same App Group entitlement: without it, the moment
# the app touches its Group Container macOS shows the "wants to access data from
# other apps" TCC prompt to every user, on every launch. Assert it survived
# signing so a dropped entitlement fails the build instead of shipping.
echo "==> Verifying app App Group entitlement"
if ! codesign -d --entitlements - "$APP" 2>/dev/null \
    | grep -q "4DUQGD879H.com.matrixreligio.matrixnet"; then
  echo "ERROR: app is missing the App Group entitlement after signing" >&2
  codesign -d --entitlements - "$APP" 2>/dev/null | grep -A3 application-groups >&2 || true
  exit 1
fi
echo "OK"
