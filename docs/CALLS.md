# calls: how the audio actually gets in and out

Verified on the V60, 2026-10-09: outgoing calls, voicemail PINs from the Mac keypad, a
voicemail left on another line that sounded like the headphones, not the phone.

## the other person (downlink)

`AudioManager.getCallDownlinkExtractionAudioRecord` (Android 13 call redirection,
`@SystemApi`, needs `CALL_AUDIO_INTERCEPTION`). On this phone it lands on Qualcomm's
call-recording path, `incall-rec-downlink`, and the call stays on the earpiece. Plain
`VOICE_DOWNLINK` capture is the fallback.

## you (uplink)

Android's own injection track (`getCallUplinkInjectionAudioTrack`) opens but carries
nothing here: it plays to the `afe-proxy-playback` route, which this ROM's mixer paths
do not have, so the caller heard the phone's own mic instead.

What works is Qualcomm's **in-call music** (`incall_music_uplink`, built for music on
hold): it mixes a playback stream into the call. It does **not** mute the phone's mic by
itself (an early version of this doc said it did, and calls carried the phone's mic
underneath). What it does is change what a call mute means: while it plays, a mute cuts
the mic device only (`voice_set_device_mute_flag`, "use_device_mute" in the HAL log)
instead of the whole uplink. So ito mutes the call while in-call music runs **and** the
Mac's voice is actually arriving (300 ms of it unbroken), unmutes the moment it stops
(1.5 s without), and unmutes before handing the call back. Muting before in-call music
runs would silence the Mac too, and muting as soon as the Mac took the call (0.2.3) left
calls with no voice at all whenever the Mac's mic failed to start. Audio policy hands it to a track that is routed explicitly to the Telephony Tx
device (`setPreferredDevice(TYPE_TELEPHONY)`, usage `VOICE_COMMUNICATION`), but on the
V60 three things stood in the way. The Magisk module fixes all three:

1. **The HAL feature is off.** `vendor.audio.feature.incall_music.enable=true`
   (module `system.prop`). The V60 runs LG's prebuilt HAL, which reads that property.
2. **LG declared the `incall_music` output DIRECT.** AOSP's `openDirectOutput` never
   offers a direct output to a plain PCM track. The overlay makes it a mixed output.
3. **It had no route to Telephony Tx**, and did have routes to the earpiece, speaker and
   headsets. The overlay makes Telephony Tx its **only** route, so nothing but ito's
   uplink can ever be mixed into a call.

The overlay is `post-fs-data.sh`: every boot, before Magisk mounts anything, it rebuilds
`/vendor/etc/audio_policy_configuration.xml` from the phone's untouched original with
exactly those edits, checks the result (line count, exactly two `incall_music`
mentions), and drops the overlay entirely if anything is off. `ito-audio` in logcat
logs which path each direction used and the levels every 5 s.

Proof in the HAL log: `adev_open_output_stream: Stream picks up usecase (incall_music_uplink)`.

## the bits a phone normally does locally

- **Ringback.** Telecom plays it on the phone itself (RingbackPlayer) when the network
  sends none, so it never travels the call. The Mac synthesizes US ringback while an
  outgoing call is dialing and the line is silent.
- **Keypad tones.** Each digit is held 160 ms and sent one at a time; back-to-back
  play/stop is too short for IMS. The Mac plays the tone locally too.
- **The phone while a Mac has the call.** It's held on the earpiece at minimum volume and
  its mic is muted while the Mac's mic is arriving (both restored afterwards, even after a
  crash). If the Mac's mic stops arriving, the phone's mic comes back on, so the worst
  case is the phone's mic and never silence, and the Mac shows it. Tapping
  "use phone" on ito's notification, or switching the route on the phone, hands the
  call back.

## the Mac side

Two shapes, chosen per call (`mac/Sources/ItoKit/CallAudio.swift`):

- **Speakers, nothing Bluetooth:** one engine with Apple's voice processing (echo
  cancellation), so the caller doesn't hear themselves out of your speakers. If it's
  refused twice (a USB audio interface here does, -10875) or runs with a deaf mic, that
  input is remembered and gets the split.
- **Bluetooth (headphones or headset), either side:** no echo to cancel, so the mic and
  the player are separate. A headset's mic is read straight from the HAL (an IOProc);
  any other mic through an input-only engine pinned to its device. The player is an
  output-only engine.

Opening a headset's mic switches it from music mode to call mode: it plays a tone, the
output goes from 44.1 kHz to the mic's rate, and whatever engine plays to it stops. Only
the player is rebuilt. The mic must not be: an AVAudioEngine stops itself on every device
change, a headset changes several times while it switches, and an engine reopened
mid-switch can hang for seconds and fail (`-10868`). While the mic is closed the headset
drops back to music mode and switches again, tone after tone. That (with rebuilding on
the *same* engine, which keeps the old format forever) is how 0.2.3 calls died, and in
0.2.4 it still hit about one call start in four. The IOProc stays started through the
changes, comes up in ~50 ms, and has never needed a rebuild. (An engine opening a mic
that an IOProc already holds takes ~6 s, so the two never share a mic.)

**The tone before the call, not in it.** The call's audio starts when you click: dialing,
the headset switches while the phone dials; answering, the Mac answers once the mic is
delivering and the headset has switched (~0.7 s, never more than 2.5 s), so the caller
hears one more ring instead of you hearing a tone over their hello. Before the phone
carries the call, the mic's frames go nowhere. If it never does, the audio stops after 10 s.

Every (re)build is a new AVAudioEngine; retries carry a generation number so only one
chain runs per side. A mic quiet for 6 s is rebuilt, twice at most, then the user is told.
Multi-input interfaces are mixed down, so a mic on input 2 is heard.

Testing on real devices, no phone needed (debug builds; both run long enough to cover the
headset's switch, which a 3 s test never reached):

- `cd mac && ./build.sh debug && open -n -W --env ITO_AUDIOTEST=15 --stdout /dev/stdout
  build/ito.app`: the engine alone, one line a second (mic frames, peak, devices, how long
  the main thread froze).
- `tools/calltest.sh`: a call out and a call in against the fake phone, through the app's
  own call flow. For each, when your mic was flowing relative to when the call connected.

Logs: `/usr/bin/log show --info --predicate 'subsystem == "app.ito"'` (categories `link`
and `audio`).
