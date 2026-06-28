#!/usr/bin/env bash
#
# Builds MatrixNet, signs it with Developer ID + the real entitlements, and
# launches it for a local UI smoke test.
#
# WHY THIS EXISTS: a plain `swift build` or `xcodebuild ... CODE_SIGNING_ALLOWED=NO`
# produces an ad-hoc binary with NO entitlements. Without the
# `com.apple.security.application-groups` entitlement, the moment the app touches
# its App Group container (`~/Library/Group Containers/...`) macOS (Sequoia+)
# shows the "MatrixNet wants to access data from other apps" TCC prompt — on every
# launch. The shipped, notarized Developer ID build carries that entitlement and
# is silent; an ad-hoc dev build is not. Always smoke-test a *signed* build so the
# local run behaves like what users get (and never trains anyone to dismiss that
# prompt). See scripts/sign.sh and App/MatrixNet.entitlements.
#
# Usage: ./scripts/smoke.sh [Debug|Release]   (default: Release)
set -euo pipefail

CONFIG="${1:-Release}"
DERIVED="build"
APP="$DERIVED/Build/Products/$CONFIG/MatrixNet.app"

echo "==> Generating project"
xcodegen generate >/dev/null

echo "==> Building ($CONFIG, ad-hoc; re-signed below)"
xcodebuild -scheme MatrixNet -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build >/dev/null

echo "==> Signing with Developer ID + entitlements (local, un-notarized)"
# Local timestamp=none: avoids contacting Apple's TSA; fine for a local launch,
# NOT for distribution. The entitlement is what matters here — it makes the app
# own its App Group container so no TCC prompt appears.
TIMESTAMP=--timestamp=none ./scripts/sign.sh "$APP"

echo "==> Launching $APP"
open -n "$APP"
echo "OK — launched a signed build; no 'access other apps data' prompt should appear."
