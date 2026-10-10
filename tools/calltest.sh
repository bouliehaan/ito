#!/bin/bash
# Dev: a call out and a call in, the Mac against the fake phone, on this Mac's real
# audio devices (with headphones on you hear the fake caller's 440 Hz tone). Prints, for
# each, when your mic was flowing relative to when the call connected: anything after
# is the start of the conversation lost to the headset switching to call mode.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT=46970
(cd "$ROOT/android" && ./gradlew -q :fakephone:installDist)
(cd "$ROOT/mac" && ./build.sh debug >/dev/null)
PHONE_DIR="$(mktemp -d)"
OUT="$(mktemp -d)"
# The fake phone's side: someone calls about 26 s in, after the Mac's own call is done.
( sleep 26; echo "ring +15550100004"; sleep 25 ) \
  | "$ROOT/android/fakephone/build/install/fakephone/bin/fakephone" --port $PORT --auto --no-mdns --dir "$PHONE_DIR" > "$OUT/fakephone.log" 2>&1 &
PHONE=$!
trap 'kill $PHONE 2>/dev/null; rm -rf "$PHONE_DIR"' EXIT
sleep 3
# Through LaunchServices, not the binary: macOS only lets an app it launched use the mic.
open -n -W --env ITO_CALLTEST="127.0.0.1:$PORT" --stdout "$OUT/mac.log" --stderr "$OUT/mac.log" "$ROOT/mac/build/ito.app"
grep calltest "$OUT/mac.log"
echo "logs: $OUT"
