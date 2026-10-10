#!/bin/bash
# Regenerates every icon from tools/icon.py: the SVG master, the Mac .icns, and the
# Android adaptive, themed and status-bar drawables. macOS only (qlmanage, sips, iconutil).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/android/app/src/main/res"
mkdir -p "$ROOT/art" "$RES/drawable"

python3 -I "$ROOT/tools/icon.py" svg  > "$ROOT/art/ito-icon.svg"
python3 -I "$ROOT/tools/icon.py" fg   > "$RES/drawable/ic_launcher_fg.xml"
python3 -I "$ROOT/tools/icon.py" mono > "$RES/drawable/ic_launcher_mono.xml"
python3 -I "$ROOT/tools/icon.py" stat > "$RES/drawable/ic_stat_ito.xml"

TMP="$(mktemp -d)"
qlmanage -t -s 1024 -o "$TMP" "$ROOT/art/ito-icon.svg" >/dev/null 2>&1
MASTER="$TMP/ito-icon.svg.png"
[ -f "$MASTER" ] || { echo "render failed" >&2; exit 1; }
cp "$MASTER" "$ROOT/art/ito-icon.png"
SET="$TMP/ito.iconset"; mkdir -p "$SET"
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
  sips -z "${spec%%:*}" "${spec%%:*}" "$MASTER" --out "$SET/icon_${spec#*:}.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT/mac/Resources/ito.icns"
rm -rf "$TMP"
echo "icons regenerated"
