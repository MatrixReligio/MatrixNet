#!/usr/bin/env bash
#
# Downloads the DB-IP Country Lite dataset (CC-BY-4.0) and converts it to the
# compact binary range table bundled with the app at App/Resources/geoip.dat.
# The dataset is NOT committed (it is large and updated monthly); run this before
# building a release, or rely on AddressScope-only classification without it.
#
# Attribution (required by CC-BY-4.0): "IP Geolocation by DB-IP" (https://db-ip.com).
set -euo pipefail

MONTH="${1:-$(date +%Y-%m)}"
URL="https://download.db-ip.com/free/dbip-country-lite-${MONTH}.csv.gz"
TMP="$(mktemp -d)"
OUT="App/Resources/geoip.dat"

echo "==> Downloading $URL"
if ! curl -fsSL "$URL" -o "$TMP/dbip.csv.gz"; then
  echo "Download failed (dataset for $MONTH may not be published yet). Try a previous month: ./scripts/build-geoip.sh 2026-05"
  exit 1
fi

gunzip -f "$TMP/dbip.csv.gz"
mkdir -p App/Resources
swift Tools/GeoIPConvert/main.swift "$TMP/dbip.csv" "$OUT"
rm -rf "$TMP"
echo "==> Done: $OUT"
