#!/bin/bash
# Builds android/magisk/out/ito-magisk.zip: ito as a PRIVILEGED system app.
#
# That is what unlocks the call half of ito:
#   CONTROL_INCALL_EXPERIENCE   see and control every call (non-UI in-call service)
#   CALL_AUDIO_INTERCEPTION     the call's audio, both directions, over the link
#   MODIFY_PHONE_STATE          required by audio policy for the uplink (TELEPHONY_TX) track
#   READ_PRECISE_PHONE_STATE    whether Wi-Fi Calling is registered
#   START_*_FROM_BACKGROUND     go microphone-foreground for a call while ito is in the background
#
# A privileged app that asks for a privileged permission missing from its
# allowlist can stop the phone booting, so the allowlist is generated from the
# APK's own manifest, and the build FAILS on any permission this script has
# not classified. Adding a permission to AndroidManifest.xml means adding it here.
set -euo pipefail
cd "$(dirname "$0")/.."

PRIVILEGED="CONTROL_INCALL_EXPERIENCE CALL_AUDIO_INTERCEPTION MODIFY_PHONE_STATE READ_PRECISE_PHONE_STATE START_ACTIVITIES_FROM_BACKGROUND START_FOREGROUND_SERVICES_FROM_BACKGROUND"
ORDINARY="INTERNET ACCESS_NETWORK_STATE ACCESS_WIFI_STATE CHANGE_NETWORK_STATE WAKE_LOCK FOREGROUND_SERVICE FOREGROUND_SERVICE_CONNECTED_DEVICE FOREGROUND_SERVICE_MICROPHONE RECEIVE_BOOT_COMPLETED POST_NOTIFICATIONS READ_SMS RECEIVE_SMS SEND_SMS RECEIVE_MMS READ_CONTACTS READ_CALL_LOG READ_PHONE_STATE READ_PHONE_NUMBERS CALL_PHONE ANSWER_PHONE_CALLS RECORD_AUDIO MODIFY_AUDIO_SETTINGS"

[ -f keystore/keystore.properties ] || tools/keystore.sh
./gradlew -q :app:assembleRelease
APK=app/build/outputs/apk/release/app-release.apk
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
"$BT/apksigner" verify "$APK"

PKG="$("$BT/aapt2" dump packagename "$APK")"
VERSION="$("$BT/aapt2" dump badging "$APK" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p")"
CODE="$("$BT/aapt2" dump badging "$APK" | sed -n "s/.*versionCode='\([^']*\)'.*/\1/p")"
REQUESTED="$("$BT/aapt2" dump permissions "$APK" | sed -n "s/^uses-permission: name='android.permission.\([A-Z_]*\)'.*/\1/p")"
OTHER="$("$BT/aapt2" dump permissions "$APK" | sed -n "s/^uses-permission: name='\([^']*\)'.*/\1/p" | grep -v '^android.permission.' || true)"
# AGP adds this one to every app; it is signature-only to the app itself.
OTHER="$(echo "$OTHER" | grep -v "^$PKG.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION$" || true)"
[ -z "$OTHER" ] || { echo "unclassified non-android permission(s): $OTHER" >&2; exit 1; }

ALLOW=""
for p in $REQUESTED; do
  if [[ " $PRIVILEGED " == *" $p "* ]]; then ALLOW+="        <permission name=\"android.permission.$p\" />"$'\n'
  elif [[ " $ORDINARY " != *" $p "* ]]; then echo "unclassified permission $p: add it to PRIVILEGED or ORDINARY in $0" >&2; exit 1
  fi
done

OUT=magisk/out
STAGE="$OUT/stage"
rm -rf "$OUT"
mkdir -p "$STAGE/system/priv-app/ito" "$STAGE/system/etc/permissions" "$STAGE/system/etc/sysconfig"
cp -R magisk/template/META-INF "$STAGE/"
cp "$APK" "$STAGE/system/priv-app/ito/ito.apk"
# Android reuses its parsed copy of a system app while the app's DIRECTORY looks older
# than the cache, and Magisk mounts that directory with a 1970 timestamp. Without this,
# a module update keeps running the previous APK forever. Drop ito's entry each boot.
cat > "$STAGE/post-fs-data.sh" <<'SH'
#!/system/bin/sh
# Runs before Magisk mounts module files, so it can shape them.
MODDIR=${0%/*}
rm -f /data/system/package_cache/*/ito-*

# Call uplink. Qualcomm's in-call music route mixes a playback stream into the call
# and mutes the phone's own mic while it plays. Two changes to the phone's OWN policy
# file make audio policy hand it to ito's uplink track:
#  - the incall_music output becomes a mixed output (LG declared it DIRECT, and policy
#    never offers a direct output to a plain PCM track), opened at boot on Telephony Tx;
#  - Telephony Tx becomes its ONLY destination: it is removed from the earpiece, speaker
#    and headset routes, so no ordinary sound can ever be mixed into a call.
# Regenerated from the untouched original every boot (this runs before Magisk mounts
# anything), and dropped entirely unless the result is exactly what is expected.
SRC=/vendor/etc/audio_policy_configuration.xml
DST=$MODDIR/system/vendor/etc/audio_policy_configuration.xml
mkdir -p "${DST%/*}"
rm -f "$DST" "$DST.tmp"
if [ -f "$SRC" ]; then
  sed -e 's/flags="AUDIO_OUTPUT_FLAG_DIRECT|AUDIO_OUTPUT_FLAG_INCALL_MUSIC"/flags="AUDIO_OUTPUT_FLAG_INCALL_MUSIC"/' \
      -e 's/,incall_music//g' \
      -e '/sink="Telephony Tx"/{n;s/sources="voice_tx"/sources="voice_tx,incall_music"/;}' "$SRC" > "$DST.tmp"
  if [ "$(wc -l < "$DST.tmp")" = "$(wc -l < "$SRC")" ] && \
     [ "$(grep -o 'incall_music' "$DST.tmp" | wc -l)" = "2" ] && \
     [ "$(grep -c 'sources="voice_tx,incall_music"' "$DST.tmp")" = "1" ] && \
     [ "$(grep -c 'flags="AUDIO_OUTPUT_FLAG_INCALL_MUSIC"' "$DST.tmp")" = "1" ]; then
    mv "$DST.tmp" "$DST"
    chmod 644 "$DST"
    chcon u:object_r:vendor_configs_file:s0 "$DST" 2>/dev/null
  fi
  rm -f "$DST.tmp"
fi
SH
chmod 755 "$STAGE/post-fs-data.sh"
# The HAL side of in-call music is off unless this is set before the audio HAL starts.
echo "vendor.audio.feature.incall_music.enable=true" > "$STAGE/system.prop"
cat > "$STAGE/module.prop" <<PROP
id=ito
name=ito
version=v$VERSION
versionCode=$CODE
author=ito
description=ito phone bridge as a privileged system app: call control and call audio for the Mac.
PROP
cat > "$STAGE/system/etc/permissions/privapp-permissions-$PKG.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by android/magisk/build.sh from the APK's manifest. -->
<permissions>
    <privapp-permissions package="$PKG">
$ALLOW    </privapp-permissions>
</permissions>
XML
# hidden-api: the call-audio API is @SystemApi, reached by reflection; system apps
#   on this list are exempt from the hidden-API filter.
# allow-in-power-save: the phone may be in a pocket, not on a charger; Doze would
#   otherwise cut the link after a while unplugged (the same exemption system
#   messaging apps get).
cat > "$STAGE/system/etc/sysconfig/$PKG.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<config>
    <hidden-api-whitelisted-app package="$PKG" />
    <allow-in-power-save package="$PKG" />
</config>
XML
(cd "$STAGE" && zip -qr -X ../ito-magisk.zip .)
cp "$APK" "$OUT/ito-release.apk"
echo "allowlisted:"; echo "$ALLOW" | sed -n 's/.*name="\([^"]*\)".*/  \1/p'
echo "built $OUT/ito-magisk.zip ($PKG $VERSION)"
