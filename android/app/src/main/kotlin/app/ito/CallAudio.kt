package app.ito

import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Process
import android.util.Log
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Call audio over the link, using Android's own call-redirection API
 * (AudioManager.getCallDownlinkExtractionAudioRecord /
 * getCallUplinkInjectionAudioTrack, API 33, @SystemApi). It needs
 * CALL_AUDIO_INTERCEPTION, i.e. the Magisk system install, and a device whose
 * audio policy declares the Telephony Tx/Rx devices. The V60's does
 * (voice_tx -> "Telephony Tx", "Telephony Rx" -> voice_rx), which is why this
 * path exists at all. Whether LG's IMS honours it on a Wi-Fi call is the one
 * thing only the phone can answer: see docs/CALLS.md.
 *
 * Wire: 16 kHz mono s16le, 20 ms (320 samples) per frame, prefixed by a u32
 * sequence number. Uncompressed is 256 kbit/s each way, nothing on a LAN, and
 * means no codec in either app.
 */
class CallAudio(private val ctx: Context) {
    private val am = ctx.getSystemService(AudioManager::class.java)

    @Volatile private var record: AudioRecord? = null
    @Volatile private var track: AudioTrack? = null
    @Volatile var running = false
        private set
    private val inbox = ArrayBlockingQueue<ByteArray>(32)

    val permitted: Boolean
        get() = ctx.checkSelfPermission(PERMISSION) == PackageManager.PERMISSION_GRANTED

    /** null = cannot ask (not a system install). */
    fun interceptable(): Boolean? {
        if (!permitted) return null
        return runCatching { am.javaClass.getMethod("isPstnCallAudioInterceptable").invoke(am) as Boolean }
            .onFailure { Log.w(TAG, "isPstnCallAudioInterceptable failed", it) }
            .getOrNull()
    }

    /**
     * [started] = the downlink runs (the Mac hears the call). [problem] = what was refused:
     * with started=false nothing runs (worth retrying while Telecom switches the audio
     * mode); with started=true only the uplink failed, so the Mac can hear but not be heard.
     */
    data class Start(val started: Boolean, val problem: String?)

    @Synchronized fun start(sink: (ByteArray) -> Unit): Start {
        if (running) return Start(true, null)
        if (!permitted) return Start(false, "call audio needs the system install (android/magisk)")
        lastProblem = null
        val (rec, downVia) = openDownlink() ?: return Start(false, lastProblem ?: "downlink refused")
        lastProblem = null
        val opened = openUplink()
        val trk = opened?.first
        val uplinkProblem = if (trk == null) (lastProblem ?: "uplink refused") else null
        Log.i(TAG, "call audio: downlink via $downVia, uplink via ${opened?.second ?: "nothing ($uplinkProblem)"}")
        uplinkVia = opened?.second
        record = rec
        track = trk
        inbox.clear()
        downFrames = 0; downPeak = 0; upFrames = 0; upPeak = 0; upStarved = 0
        running = true
        rec.startRecording()
        trk?.play()

        Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            var seq = 0
            val pcm = ByteArray(FRAME_BYTES)
            val began = System.currentTimeMillis()
            var lastReport = began
            var upAtReport = 0L
            var quiet = false
            while (running) {
                var got = 0
                while (got < FRAME_BYTES && running) {
                    val n = rec.read(pcm, got, FRAME_BYTES - got)
                    if (n <= 0) break
                    got += n
                }
                if (got < FRAME_BYTES) continue
                downFrames++
                downPeak = maxOf(downPeak, peak(pcm))
                sink(ByteBuffer.allocate(4 + FRAME_BYTES).putInt(seq++).put(pcm).array())
                val now = System.currentTimeMillis()
                if (now - lastReport >= 5000) {
                    // Levels, not just counts: a path can deliver frames of perfect silence.
                    Log.i(TAG, "call audio: down $downFrames frames peak $downPeak · up $upFrames frames peak $upPeak, $upStarved silent fills")
                    downPeak = 0; upPeak = 0
                    lastReport = now
                    // Nothing from the Mac's microphone for a whole report (after a few
                    // seconds of grace to get going): say so once, so the Mac can show it.
                    val fresh = upFrames > upAtReport
                    upAtReport = upFrames
                    if (trk != null && !fresh && !quiet && now - began > 6000) { quiet = true; onMacQuiet?.invoke() }
                    if (fresh) quiet = false
                }
            }
        }, "ito-downlink").start()

        if (trk == null) return Start(true, uplinkProblem)

        Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            val silence = ByteArray(FRAME_BYTES)
            while (running) {
                // Keep the uplink fed: silence when the Mac is late, never a gap.
                val f = inbox.poll(40, TimeUnit.MILLISECONDS)
                val pcm = if (f != null && f.size == 4 + FRAME_BYTES) f.copyOfRange(4, f.size) else silence
                if (pcm === silence) upStarved++ else { upFrames++; upPeak = maxOf(upPeak, peak(pcm)) }
                trk.write(pcm, 0, pcm.size, AudioTrack.WRITE_BLOCKING)
            }
        }, "ito-uplink").start()
        return Start(true, null)
    }

    /** "in-call music" or "call redirection" while running; null when there is no uplink. */
    @Volatile var uplinkVia: String? = null
        private set

    /** The Mac's microphone stopped arriving (or never did) during a call. Audio thread. */
    @Volatile var onMacQuiet: (() -> Unit)? = null

    @Volatile private var lastProblem: String? = null
    @Volatile private var downFrames = 0L
    @Volatile private var downPeak = 0
    @Volatile private var upFrames = 0L
    @Volatile private var upPeak = 0
    @Volatile private var upStarved = 0L

    private val inFmt = AudioFormat.Builder().setSampleRate(RATE).setEncoding(AudioFormat.ENCODING_PCM_16BIT)
        .setChannelMask(AudioFormat.CHANNEL_IN_MONO).build()
    private val outFmt = AudioFormat.Builder().setSampleRate(RATE).setEncoding(AudioFormat.ENCODING_PCM_16BIT)
        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build()

    /**
     * The other person. First choice: the redirection API's downlink record, proven on
     * the V60 (Qualcomm's "incall-rec-downlink" path, the call stays on the earpiece).
     * Fallback: plain VOICE_DOWNLINK capture, the same HAL path by the older door.
     */
    private fun openDownlink(): Pair<AudioRecord, String>? {
        try {
            return (am.javaClass.getMethod("getCallDownlinkExtractionAudioRecord", AudioFormat::class.java).invoke(am, inFmt) as AudioRecord) to "call redirection"
        } catch (e: Exception) {
            lastProblem = "downlink: ${rootMessage(e)}"
            Log.i(TAG, "redirection downlink refused, trying voice-downlink capture: $lastProblem")
        }
        try {
            @Suppress("MissingPermission")
            val r = AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.VOICE_DOWNLINK)
                .setAudioFormat(inFmt)
                .setBufferSizeInBytes(maxOf(AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT), FRAME_BYTES * 8))
                .build()
            if (r.state == AudioRecord.STATE_INITIALIZED) return r to "call recording (voice downlink)"
            r.release()
            lastProblem = (lastProblem?.let { "$it; " } ?: "") + "voice-downlink capture did not initialise"
        } catch (e: Exception) {
            lastProblem = (lastProblem?.let { "$it; " } ?: "") + "voice-downlink: ${rootMessage(e)}"
        }
        return null
    }

    /**
     * You. First choice: Qualcomm's in-call music ("incall_music_uplink"), which mixes a
     * playback stream into the uplink. It does NOT mute the phone's own mic by itself; it
     * makes a call mute act on the mic alone, so Calls mutes the call once this runs. Audio
     * policy only selects it for a track routed explicitly to the Telephony Tx device, and
     * on the V60 that needs two things the Magisk module supplies: the HAL feature
     * property and an incall_music → Telephony Tx route in the policy file.
     * Fallback: the redirection API's injection track (its "afe-proxy-playback" route
     * does not exist on this ROM, so it opens but carries nothing).
     */
    private fun openUplink(): Pair<AudioTrack, String>? {
        val tx = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { it.type == AudioDeviceInfo.TYPE_TELEPHONY }
        if (tx != null) {
            try {
                val t = AudioTrack.Builder()
                    .setAudioAttributes(AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                    .setAudioFormat(outFmt)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .setBufferSizeInBytes(maxOf(AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT), FRAME_BYTES * 6))
                    .build()
                t.setPreferredDevice(tx)
                // A track re-routes when it starts, so start it and push one frame of silence
                // before asking where it went. Never let the Mac's voice come out of the
                // phone's speaker instead: keep it only if it landed on the telephony device.
                if (t.state == AudioTrack.STATE_INITIALIZED) {
                    t.play()
                    t.write(ByteArray(FRAME_BYTES), 0, FRAME_BYTES, AudioTrack.WRITE_BLOCKING)
                    if (t.routedDevice?.type == AudioDeviceInfo.TYPE_TELEPHONY) return t to "in-call music"
                    lastProblem = "uplink: in-call music not routed (went to ${t.routedDevice?.type ?: "nothing"})"
                    runCatching { t.stop() }
                }
                t.release()
            } catch (e: Exception) {
                lastProblem = "uplink: ${rootMessage(e)}"
            }
        } else {
            lastProblem = "uplink: no telephony output device"
        }
        return try {
            (am.javaClass.getMethod("getCallUplinkInjectionAudioTrack", AudioFormat::class.java).invoke(am, outFmt) as AudioTrack) to "call redirection"
        } catch (e: Exception) {
            lastProblem = (lastProblem?.let { "$it; " } ?: "") + "redirection: ${rootMessage(e)}"
            null
        }
    }

    private fun peak(pcm: ByteArray): Int {
        var p = 0
        var i = 0
        while (i < pcm.size - 1) {
            val v = (pcm[i].toInt() and 0xff) or (pcm[i + 1].toInt() shl 8)
            val a = kotlin.math.abs(v.toShort().toInt())
            if (a > p) p = a
            i += 2
        }
        return p
    }

    /** A frame of Mac microphone. Latency beats completeness: past ~120 ms of backlog, drop the oldest. */
    fun onMacFrame(frame: ByteArray) {
        if (!running) return
        while (inbox.size > MAX_BACKLOG) inbox.poll()
        inbox.offer(frame)
    }

    @Synchronized fun stop() {
        if (!running) return
        running = false
        runCatching { record?.stop() }
        runCatching { record?.release() }
        runCatching { track?.stop() }
        runCatching { track?.release() }
        record = null
        track = null
        uplinkVia = null
        inbox.clear()
    }

    private fun rootMessage(e: Throwable): String {
        var t: Throwable = e
        while (t.cause != null) t = t.cause!!
        return "${t.javaClass.simpleName}: ${t.message}"
    }

    companion object {
        const val PERMISSION = "android.permission.CALL_AUDIO_INTERCEPTION"
        const val RATE = 16_000
        const val FRAME_BYTES = 640
        private const val MAX_BACKLOG = 6
        private const val TAG = "ito-audio"
    }
}
