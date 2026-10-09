#!/bin/bash
# Dev: renders the Mac UI against the fake phone, in a throwaway identity and
# store. PNGs land in the directory given (default: a temp dir).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$(mktemp -d)/ito-snapshots}"
mkdir -p "$OUT"
PORT=46969
(cd "$ROOT/android" && ./gradlew -q :fakephone:installDist)
(cd "$ROOT/mac" && ./build.sh debug >/dev/null)
PHONE_DIR="$(mktemp -d)"
# The fake phone's side of the story: two replies to the group, then a call.
( sleep 14; echo "in +15550100001 8 works for me"; sleep 1.5; echo "in +15550100002 same. jo's driving"; sleep 9; echo "ring +15550100004"; sleep 40 ) \
  | "$ROOT/android/fakephone/build/install/fakephone/bin/fakephone" --port $PORT --auto --no-mdns --dir "$PHONE_DIR" > "$OUT/fakephone.log" 2>&1 &
PHONE=$!
trap 'kill $PHONE 2>/dev/null; rm -rf "$PHONE_DIR"' EXIT
sleep 3
ITO_SNAPSHOT="$OUT" ITO_HOST="127.0.0.1:$PORT" "$ROOT/mac/build/ito.app/Contents/MacOS/ito"
echo "$OUT"
