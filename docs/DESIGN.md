# design

Why ito is built the way it is. Each section is a decision and what it costs.

## nothing already did this

Checked 2026-10-09:

- **Google Messages for web**: texts, RCS and MMS from a browser. It needs Google Messages
  as the phone's SMS app with Google's servers in the middle, and has no calls.
- **HandsFree 2** (Mac, closed source): calls and SMS over Bluetooth, no app on the
  phone. Bluetooth range only, and nothing for group texting without MMS.
- **KDE Connect**: texts and notifications. No call audio.
- **Phone Link / Intel Unison / Dell Mobile Connect**: Windows-only or discontinued.

None of them does calls and texts, encrypted end to end, with group texting that survives
having no MMS. So ito exists.

## the link: Wi-Fi, phone listens, Mac dials in

The phone holds the SIM, so it is the end everything hangs off: it listens on **6969**
(meme-port rule; nothing else runs on the phone) and advertises `_ito._tcp` over mDNS.
The Mac finds it, or uses a typed address. Where the phone is doesn't matter: a pocket,
the desk, a charger in a drawer. When it leaves the network the link waits, the phone
carries on as a phone, and the Mac catches up when it's back.

- Not USB: it would tie the phone to the Mac. Wi-Fi reaches it anywhere in the house.
- Not Bluetooth: range, throughput for history sync, and macOS's Bluetooth stack is not
  something to depend on for the whole product. (It is the fallback for call audio,
  see CALLS.md.)
- Away from home: put both on Tailscale and type the phone's tailnet address in
  settings. No relay server of ours, ever.

The mDNS name is `ito-<first 8 hex of the phone key's SHA-256>`: the LAN learns that an
ito phone exists, not whose.

## power

ito can't assume the phone is on a charger. The bridge is a foreground service that the
Magisk module exempts from Doze (`allow-in-power-save`, like system messaging apps), and
it holds a wake lock only while a Mac is linked *and* the phone is charging. On battery
the link's own traffic wakes it. The Mac's only battery notice is the phone's own kind: one
heads-up at 15% when not charging.

## security

- **Noise_XX_25519_ChaChaPoly_SHA256**, written from the spec on each platform's own
  crypto (CryptoKit; Conscrypt/SunJCE). No third-party crypto in either app. Both
  implementations are pinned to the same official test vector, and a cross-language test
  runs the real handshake between them.
- **Trust is a pinned static key on each side.** The phone talks only to Macs it has
  paired. The Mac talks only to the phone it paired, and refuses a phone whose key
  changed (that is either a reinstall or an attack, and the fix for a reinstall is
  "forget and pair again", on purpose).
- **Pairing is numeric comparison with a commitment** (Bluetooth SSP's construction),
  inside the Noise channel. A code taken straight from the handshake hash would be
  breakable: a man in the middle finishes one leg, then grinds its last handshake
  message on the other leg until the two 6-digit codes collide. A million tries is
  milliseconds. Here the phone commits to its nonce before seeing the Mac's, so each side's
  code includes randomness the attacker could not choose: one in a million per attempt,
  and every attempt needs a person to approve it. Pairing is only possible while the phone
  user has a 2-minute pairing window open.
- **Keys at rest**: the phone's private key is sealed with an AES key that lives in the
  Android Keystore (hardware-backed) and cannot be exported. The Mac's is in the login
  Keychain. Message history on the Mac is a 0600 SQLite file in a 0700 directory, under
  FileVault.
- **What a stranger on the Wi-Fi gets**: a port that does a Noise handshake and then
  hangs up, plus the fact that an ito phone exists.
- **Lost Mac**: unpair it on the phone (ito → macs → unpair). Its key stops working
  immediately.

## texts: alongside the phone's messaging app, not instead of it

ito is **not** the default SMS app. The phone's own messaging app keeps receiving and
storing every text, and ito reads the same store, listens for arrivals and sends through
`SmsManager`. Android writes ito's sent texts into the store itself, tagged
`creator=app.ito`, and hands back the row's URI. That is how a group copy gets filed.

Why: ito stays purely additive (uninstall it and nothing changed), the phone stays a
working phone if you pick it up, and it is less code that can lose a message. The cost:
ito cannot mark texts read *on the phone*, so read state lives on the Mac. A text counts
as unread if it is unread on the phone *and* newer than what the Mac has shown you.

Sync: the Mac remembers the highest row id it has; on connect it asks for everything
after that, the most recent 300 again (statuses and filing change), and the phone's
full id list (deleted on the phone means deleted on the Mac). Live changes are pushed
by content observers within half a second.

## groups without MMS

MMS rides cellular data. With only Wi-Fi Calling there is none, so a group is something
the phone runs itself, hub and spoke, over SMS from your one number:

- **sending** to a group = one SMS per member, all carrying one group-message id so the
  Mac shows one bubble ("→ 3 · delivered").
- **broadcast** groups: replies come back only to you, threaded into the group.
  Nobody sees anybody else. No privacy risk at all.
- **relay** groups: a real group chat. A member's reply is forwarded to every other
  member as `sam: text` (first name from your contacts, or the last 4 digits). The first
  text each member gets carries one line, `(group text with alex, jo. replies go to everyone)`,
  so nobody is relayed without knowing it is a group.

**Routing a reply.** One number means a reply carries no group id. The phone answers
"what is this person replying to?" with what it last sent them: if the latest thing that
went to Sam was group G, and recently enough, Sam's reply belongs to G. Texting Sam 1:1
takes Sam back out.

**The windows differ on purpose.** Filing a reply into a broadcast group only changes
where you see it, so the window is 24 h. Relaying puts someone's words in front of other
people, so a relay group goes quiet after 2 h: a text after that comes only to you. If it
*was* meant for the group, right-click → "move into #group and relay it". The reverse,
"move out of the group", fixes the filing (it cannot unsend a relay).

**Cost:** a relayed reply in a group of N is N−1 more SMS from your plan.

The engine is plain Kotlin in `android/link/Groups.kt`, tested against an injected
clock: windows, intros once per member, direct texts ending group context, refile,
restart persistence.

## calls

Two levels, decided by how ito is installed:

| install | what calls do |
|---|---|
| plain app | the Mac shows ringing and can decline. Audio stays on the phone. |
| system app (Magisk module) | full control: answer, dial, hang up, hold, keypad. Audio over the link to the Mac. |

The system install exists for three privileged permissions:
`CONTROL_INCALL_EXPERIENCE` (Telecom binds ito's in-call service with no UI, so the
phone's dialer stays the dialer), `CALL_AUDIO_INTERCEPTION` (Android 13's call
redirection API: an `AudioRecord` on the call's downlink and an `AudioTrack` into its
uplink) and the background-start pair that lets the bridge become a microphone
foreground service from the background.

Audio is 16 kHz mono PCM, 20 ms frames, uncompressed: 256 kbit/s each way, nothing on a
LAN, and no codec in either app. The Mac side runs Apple's voice processing (echo
cancellation, noise suppression), which is what stops the caller hearing themselves out
of your speakers.

The allowlist the module ships is generated from the APK's manifest, and the module build
fails on any permission it has not classified, because a privileged app missing an
allowlisted permission can stop the phone booting.

## the Mac app

SwiftUI, no Xcode project: SwiftPM builds, `mac/build.sh` assembles the bundle. 2 MB.
`ItoKit` holds everything that is not UI and is what the tests exercise. Look: the
samo-server console. Neutral black → grey → white, Office Code Pro, hard corners, white
as the only accent, `//` section heads, `>` command titles, corner ticks on cards. ito
is always lowercase.
