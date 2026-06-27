#!/usr/bin/env bash
#
# Downloads the IPsum aggregate threat list and converts it to the compact binary
# table bundled with the app at App/Resources/threatlist.dat. The list is NOT
# committed (it changes daily); run this before a release, or rely on the
# previously-published rolling asset that the app auto-downloads.
#
# IPsum (https://github.com/stamparm/ipsum) is released under the Unlicense
# (public domain). Level 3 = IPs present on 3+ independent blocklists (a low
# false-positive threshold).
set -euo pipefail

LEVEL="${1:-3}"
URL="https://raw.githubusercontent.com/stamparm/ipsum/master/levels/${LEVEL}.txt"
TMP="$(mktemp -d)"
OUT="App/Resources/threatlist.dat"

echo "==> Downloading $URL"
if ! curl -fsSL "$URL" -o "$TMP/ipsum.txt"; then
  echo "Download failed for level $LEVEL."
  exit 1
fi

mkdir -p App/Resources
swift Tools/ThreatConvert/main.swift "$TMP/ipsum.txt" "$OUT"
rm -rf "$TMP"
echo "==> Done: $OUT"
