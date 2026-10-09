#!/bin/bash
# Read-only report of ito on the phone over adb. Changes nothing, needs no root.
#   tools/phone-status.sh            the plugged-in phone
#   ANDROID_SERIAL=xyz tools/...     a specific one
set -uo pipefail
PKG=app.ito
adb get-state >/dev/null 2>&1 || { echo "no phone on adb"; exit 1; }
echo "phone:      $(adb shell getprop ro.product.model | tr -d '\r') · android $(adb shell getprop ro.build.version.release | tr -d '\r') · $(adb shell getprop ro.lineage.version | tr -d '\r')"
path="$(adb shell pm path $PKG 2>/dev/null | tr -d '\r')"
[ -n "$path" ] || { echo "ito:        NOT INSTALLED"; exit 0; }
dump="$(adb shell dumpsys package $PKG | tr -d '\r')"
echo "ito:        $(echo "$dump" | sed -n 's/^ *versionName=//p' | head -1) at ${path#package:}"
if echo "$dump" | grep -q 'privateFlags=.*PRIVILEGED'; then echo "install:    system (privileged) — calls enabled"
else echo "install:    plain app — texts only; calls need android/magisk/ito-magisk.zip"; fi
for p in CONTROL_INCALL_EXPERIENCE CALL_AUDIO_INTERCEPTION READ_PRECISE_PHONE_STATE START_ACTIVITIES_FROM_BACKGROUND \
         READ_SMS RECEIVE_SMS SEND_SMS READ_CONTACTS READ_CALL_LOG READ_PHONE_STATE CALL_PHONE ANSWER_PHONE_CALLS RECORD_AUDIO; do
  if echo "$dump" | grep -q "android.permission.$p: granted=true"; then s=granted; else s="-"; fi
  printf '  %-36s %s\n' "$p" "$s"
done
if adb shell dumpsys activity services $PKG 2>/dev/null | grep -q BridgeService; then echo "bridge:     running"; else echo "bridge:     NOT running (open ito on the phone once)"; fi
tel="$(adb shell dumpsys media.audio_policy 2>/dev/null | tr -d '\r' | grep -c -i -E 'telephony (tx|rx)')"
echo "audio:      telephony tx/rx devices mentioned $tel times in the audio policy (call audio needs both)"
echo "recent log:"
adb logcat -d -s ito ito-link ito-audio ito-calls 2>/dev/null | tail -8 | sed 's/^/  /'
