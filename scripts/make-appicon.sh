#!/bin/sh
# make-appicon.sh — (re)generate Resources/AppIcon.icns from make-appicon.swift.
# Run once; build-app.sh copies the result into the bundle.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/Resources"
mkdir -p "$RES"
TMP="$(mktemp -d)"
swift "$ROOT/scripts/make-appicon.swift" "$TMP"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$RES/AppIcon.icns"
rm -rf "$TMP"
echo "Wrote $RES/AppIcon.icns"
