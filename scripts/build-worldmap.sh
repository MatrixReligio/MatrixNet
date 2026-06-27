#!/usr/bin/env bash
#
# Builds the static dotted world map bundled with the app from the public-domain
# Natural Earth 1:110m admin-0 countries dataset. Coastlines and borders do not
# move, so this asset is generated once and committed (unlike the GeoIP/threat
# datasets, which refresh at runtime) — there is no runtime map download.
#
# Attribution: map data from Natural Earth (https://www.naturalearthdata.com),
# public domain.
#
# Usage: ./scripts/build-worldmap.sh [gridWidth gridHeight]
set -euo pipefail

URL="https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_admin_0_countries.geojson"
GRIDW="${1:-180}"
GRIDH="${2:-90}"
TMP="$(mktemp -d)"
OUT="App/Resources/worldmap.dat"

echo "==> Downloading $URL"
if ! curl -fsSL "$URL" -o "$TMP/countries.geojson"; then
  echo "Download failed."
  exit 1
fi

mkdir -p App/Resources
echo "==> Converting to $OUT (grid ${GRIDW}x${GRIDH})"
swift run -c release MapConvert "$TMP/countries.geojson" "$OUT" "$GRIDW" "$GRIDH"
rm -rf "$TMP"
echo "==> Done: $OUT"
