#!/bin/bash
# Builds mac/build/ito.app. No Xcode project: SwiftPM compiles, this assembles
# the bundle (Info.plist, fonts, icon) and signs it ad hoc.
#
#   ./build.sh            release build
#   ./build.sh debug      debug build (enables the ITO_SNAPSHOT dev hook)
#
# Ad hoc signing means macOS asks again for the microphone and the Keychain
# after every rebuild (the signature is the identity). Set ITO_SIGN to a
# codesigning identity name to sign with a real certificate instead.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product ito
BIN="$(swift build -c "$CONFIG" --product ito --show-bin-path)/ito"

APP=build/ito.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/ito"
cp Resources/Fonts/*.otf "$APP/Contents/Resources/Fonts/"
cp Resources/ito.icns "$APP/Contents/Resources/ito.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
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
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>ito sends your voice to your phone during calls.</string>
    <key>NSLocalNetworkUsageDescription</key><string>ito finds and talks to your paired phone on this network.</string>
    <key>NSBonjourServices</key><array><string>_ito._tcp</string></array>
</dict>
</plist>
PLIST

codesign --force --sign "${ITO_SIGN:--}" "$APP"
codesign --verify --strict "$APP"
echo "built $APP ($CONFIG)"
