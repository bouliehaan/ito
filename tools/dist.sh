#!/bin/bash
# Release files for the version in /VERSION, into dist/ (gitignored):
#   ito-X.Y.Z.dmg          the Mac app, universal, drag to Applications
#   ito-magisk-X.Y.Z.zip   the phone bridge as a privileged system app
#   SHA256SUMS
# Builds only. Tagging and publishing stay manual (see the release notes on GitHub).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
DIST="$ROOT/dist"
rm -rf "$DIST"; mkdir -p "$DIST"

(cd "$ROOT/android" && ./gradlew -q :link:test && magisk/build.sh)
cp "$ROOT/android/magisk/out/ito-magisk.zip" "$DIST/ito-magisk-$VERSION.zip"

# Never with a personal Apple Development cert: its name and email would ship in the DMG.
(cd "$ROOT/mac" && swift test >/dev/null && ITO_PUBLIC=1 ./build.sh release)
APP="$ROOT/mac/build/ito.app"
codesign --verify --deep --strict "$APP"
if codesign -dvv "$APP" 2>&1 | grep -q '^Authority=Apple Development'; then echo "refusing: personal cert on a public build" >&2; exit 1; fi
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/ito.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "ito $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DIST/ito-$VERSION.dmg"
rm -rf "$STAGE"
hdiutil verify -quiet "$DIST/ito-$VERSION.dmg"

(cd "$DIST" && shasum -a 256 ito-*.dmg ito-magisk-*.zip > SHA256SUMS)
ls -la "$DIST"; cat "$DIST/SHA256SUMS"
