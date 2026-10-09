# calls: the one thing only the phone can answer

Everything else in ito is ordinary Android and is tested on the host. Call audio is the
exception: it goes through `AudioManager.getCallDownlinkExtractionAudioRecord` and
`getCallUplinkInjectionAudioTrack` (Android 13, `@SystemApi`), and whether they carry a
live **Wi-Fi Calling** call on this phone depends on LG's IMS stack and the Qualcomm
audio HAL underneath.

## why it is worth trying

The V60's LineageOS audio policy (`device/lge/timelm`, `configs/audio/audio_policy_configuration.xml`)
declares exactly what the API looks for:

- attached devices `Telephony Tx` and `Telephony Rx`
- routes `voice_tx → Telephony Tx` and `Telephony Rx → voice_rx`

`isPstnCallAudioInterceptable()` returns true when both devices are attached, so the API
should at least open. Whether audio actually flows on an IMS-over-Wi-Fi call is the open
question.

## the test, after installing the Magisk module

1. `tools/phone-status.sh`: `install: system (privileged)`, and `CALL_AUDIO_INTERCEPTION granted`.
2. ito on the phone, status: `call audio: over the link` (that is `isPstnCallAudioInterceptable() == true`).
3. From another phone, call the V60. The Mac rings. Answer on the Mac.
   - **You hear them**: the downlink works.
   - **They hear you**: the uplink works.
   - Errors show as a notice on the Mac (`downlink: …` / `uplink: …`) and in
     `adb logcat -s ito-audio ito-calls`.
4. Dial out from the Mac, same checks.

Note: in this mode the phone's own mic stays open alongside the injected Mac audio
(the call is not in "redirect" mode). In a drawer that adds drawer silence. If it turns
out to matter, the next step is muting the phone mic during Mac calls, which needs
testing because on some Qualcomm builds muting also mutes the injected audio.

## if it does not carry audio

The fallback is **Bluetooth Hands-Free**: the Mac acts as a car kit, and the phone routes
call audio to it like any headset. `IOBluetoothHandsFreeDevice` is still in the macOS 27
SDK, not deprecated: dial, answer, end, DTMF, SCO audio. Costs: Bluetooth range (the phone's
drawer must be within ~10 m), HFP voice quality (16 kHz at best), and another pairing.
Call *control* would stay on the ito link; only the audio would move to Bluetooth.

Nothing of the fallback is built yet. Build it only if step 3 fails.
