#!/bin/bash
# One-time: a local self-signed code-signing identity for the Mac app, in its own
# keychain (~/.ito-signing), never the login keychain. With it the app keeps the same
# identity across rebuilds, so macOS stops re-asking for the Keychain, the microphone
# and local network after every build. Untrusted on purpose: it only has to be stable,
# and a locally built app is never quarantined.
set -euo pipefail
D="$HOME/.ito-signing"
KC="$D/ito-signing.keychain-db"
[ -f "$KC" ] && { echo "already set up: $KC"; exit 0; }
mkdir -p "$D"; chmod 700 "$D"; cd "$D"
PW="$(openssl rand -hex 16)"; echo "$PW" > keychain.pass; chmod 600 keychain.pass
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 7300 -nodes -subj "/CN=ito local signing" \
  -addext "extendedKeyUsage=critical,codeSigning" -addext "keyUsage=critical,digitalSignature" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null
openssl pkcs12 -export -legacy -out ito.p12 -inkey key.pem -in cert.pem -passout "pass:$PW" 2>/dev/null \
  || openssl pkcs12 -export -out ito.p12 -inkey key.pem -in cert.pem -passout "pass:$PW"
security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PW" "$KC"
security import ito.p12 -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null
rm -f key.pem ito.p12
echo "made $KC"
