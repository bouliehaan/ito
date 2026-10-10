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
hold): it mixes a playback stream into the call and mutes the phone's mic while it
plays. Audio policy hands it to a track that is routed explicitly to the Telephony Tx
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
- **The phone while a Mac has the call.** It's held on the earpiece at minimum volume
  (restored afterwards, even after a crash); in-call music mutes its mic. Tapping
  "use phone" on ito's notification, or switching the route on the phone, hands the
  call back.

## the Mac side

Apple's voice processing (echo cancellation) when the devices allow it. A Bluetooth
headset in call mode can refuse it (-10875); then the plain engine runs (no echo to
cancel in headphones), remembered per device so the next call starts instantly.
