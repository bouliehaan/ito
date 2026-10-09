# ito

糸, thread. From 糸電話, the tin-can telephone: two cups and a string.

Your Android phone, on your Mac. Put the phone on a charger, put it in a drawer,
and text and call from the Mac for as long as you like.

- **texts**: every SMS in and out, full history, the phone's contacts, banners you
  can reply to without opening anything
- **calls**: the Mac rings. You answer and talk through the Mac's mic and speakers
  (Apple's echo cancellation). Keypad and hold work too.
- **group texts without MMS**: MMS needs mobile data; a phone on Wi-Fi Calling has
  none. ito groups run on the phone over plain SMS, and *relay* groups forward each
  reply to everyone else, so they work as a real group chat through your number.
- **no server, no account, no cloud**: phone and Mac talk directly over an
  end-to-end-encrypted link (Noise XX), paired once by comparing a six-digit code.

Built for one phone: an LG V60 on LineageOS + Magisk, no cell signal, Wi-Fi Calling and
SMS over IMS ([lgv60-ims-sms](../lgv60-ims-sms)). Texts work on any Android 13+ phone.
Calls need a rooted phone (see below).

## status, 2026-10-09

| | |
|---|---|
| crypto + link | verified: both Noise implementations reproduce the official cacophony vector; the Swift client pairs with, syncs from and group-sends through the Kotlin phone over a real socket (`swift test`) |
| Mac app | verified against the fake phone: pairing, threads, relay group, calls tab, settings, call panel all rendered (`tools/snapshot.sh`) |
| Android app | builds clean, 180 KB. **Not yet run on the V60.** |
| call audio | **unverified, and the one real unknown.** Android has a documented API for it and the V60's audio policy declares the devices it needs, but whether LG's IMS honours it on a Wi-Fi call is only answerable on the phone. [docs/CALLS.md](docs/CALLS.md) is the test, plus the fallback. |

## what's where

| path | what |
|---|---|
| `android/link` | the wire, plain Kotlin/JVM: Noise, pairing, framing, the phone's server, group routing. Tested on the host. |
| `android/app` | the phone bridge: reads SMS/MMS/contacts/call log, sends texts, runs groups, controls calls, carries call audio. No AndroidX. |
| `android/fakephone` | a JVM stand-in for the phone with made-up data, for building the Mac app without the V60 |
| `android/magisk` | builds the module that installs ito as a privileged system app (the call half) |
| `mac/` | the Mac app: SwiftUI + `ItoKit` (Noise on CryptoKit, link client, SQLite mirror, call audio) |
| `vectors/` | the Noise test vector both test suites read |
| `docs/` | [DESIGN](docs/DESIGN.md) (why it is built this way), [PROTOCOL](docs/PROTOCOL.md), [CALLS](docs/CALLS.md) |

## build

```
mac/build.sh                         # -> mac/build/ito.app
android/magisk/build.sh              # -> android/magisk/out/ito-magisk.zip (+ ito-release.apk)
```

Gates: `cd android && ./gradlew :link:test` and `cd mac && swift test` (needs
`./gradlew :fakephone:installDist` first for the interop test).

The first `magisk/build.sh` makes `android/keystore/` (gitignored). **Back it up.** A
system app only accepts updates signed with the same key.

## install

**Phone, system install (texts + calls).** Magisk, same as the IMS module:

```
adb push android/magisk/out/ito-magisk.zip /sdcard/Download/
adb shell su -c "magisk --install-module /sdcard/Download/ito-magisk.zip"
adb reboot
```

Uninstall any plain (`adb install`) copy of ito first: a debug-signed copy and the
system copy have different keys and Android will refuse one of them. If the phone ever
fails to boot after this, hold volume-down while it boots: Magisk safe mode disables
modules.

**Phone, plain install (texts only):** `adb install android/magisk/out/ito-release.apk`

Then open ito on the phone, tap **grant**, and leave it. It starts itself after reboots.

**Mac:** copy `mac/build/ito.app` to /Applications and open it. Settings → pick the phone →
compare the six digits on both screens → accept on both.

`tools/phone-status.sh` reports, read-only and without root, what state ito is in on the
phone.

## things to know

- **After the phone reboots, unlock it once.** Android keeps app data encrypted until
  the first unlock, so ito (and SMS itself) is asleep until then. LineageOS nightlies
  reboot to update. If the phone has no lock screen this happens by itself.
- **OTA updates drop Magisk modules** unless Magisk is reinstalled to the inactive slot
  after the update, same as the IMS module.
- **Keep RCS off** in any Google Messages install. RCS chats bypass SMS entirely and
  would never reach ito.
- **MMS is read-only.** Old picture messages and MMS groups show up; new ones can't
  download without mobile data, and ito says so in the thread. An old MMS group has a
  one-click "make it an ito group".
- The Mac app is signed ad hoc, so macOS asks again for the microphone and Keychain after
  each rebuild. `ITO_SIGN="<identity>" mac/build.sh` signs with a real certificate.
