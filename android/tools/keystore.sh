#!/bin/bash
# Makes the release signing key once: android/keystore/ (gitignored).
# ito runs as a system app, and Android only lets a system app be updated by
# an APK signed with the same key. Back this directory up; losing it means
# reinstalling the Magisk module before the next update.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=keystore
[ -f "$DIR/keystore.properties" ] && { echo "keystore already exists"; exit 0; }
mkdir -p "$DIR"
chmod 700 "$DIR"
PASS="$(openssl rand -hex 24)"
keytool -genkeypair -keystore "$DIR/ito-release.jks" -alias ito -keyalg RSA -keysize 4096 -validity 36500 \
  -storepass "$PASS" -keypass "$PASS" -dname "CN=ito" >/dev/null 2>&1
cat > "$DIR/keystore.properties" <<PROPS
storeFile=ito-release.jks
storePassword=$PASS
keyAlias=ito
keyPassword=$PASS
PROPS
chmod 600 "$DIR"/*
echo "made $DIR/ito-release.jks — back it up"
