#!/bin/bash
# Builds mac/build/ito.app. No Xcode project: SwiftPM compiles, this assembles
# the bundle (Info.plist, fonts, icon) and signs it.
#
#   ./build.sh            release build
#   ./build.sh debug      debug build (enables the ITO_SNAPSHOT dev hook)
#
# Signing: with the local identity from tools/signing.sh (~/.ito-signing) the app
# keeps one identity across rebuilds, so macOS does not re-ask for the Keychain,
# microphone and local network each time. Without it, ad hoc. ITO_SIGN overrides.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
VERSION="$(cat ../VERSION)"
BUILD="$(echo "$VERSION" | awk -F. '{ print $1 * 10000 + $2 * 100 + $3 }')"
# Release builds are universal (Apple silicon + Intel); debug builds are host-only.
ARCHS=()
[ "$CONFIG" = release ] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" --product ito ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c "$CONFIG" --product ito ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/ito"

APP=build/ito.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/ito"
cp Resources/Fonts/*.otf "$APP/Contents/Resources/Fonts/"
cp Resources/ito.icns "$APP/Contents/Resources/ito.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>app.ito</string>
    <key>CFBundleName</key><string>ito</string>
    <key>CFBundleDisplayName</key><string>ito</string>
    <key>CFBundleExecutable</key><string>ito</string>
    <key>CFBundleIconFile</key><string>ito</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>ito sends your voice to your phone during calls.</string>
    <key>NSLocalNetworkUsageDescription</key><string>ito finds and talks to your paired phone on this network.</string>
    <key>NSBonjourServices</key><array><string>_ito._tcp</string></array>
</dict>
</plist>
PLIST

KC="$HOME/.ito-signing/ito-signing.keychain-db"
if [ -n "${ITO_SIGN:-}" ]; then
  codesign --force --sign "$ITO_SIGN" "$APP"
elif [ -f "$KC" ]; then
  security unlock-keychain -p "$(cat "$HOME/.ito-signing/keychain.pass")" "$KC"
  codesign --force --keychain "$KC" --sign "ito local signing" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "built $APP ($CONFIG)"
