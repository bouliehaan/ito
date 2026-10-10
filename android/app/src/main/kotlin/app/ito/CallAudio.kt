package app.ito

import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
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
        val inFmt = AudioFormat.Builder().setSampleRate(RATE).setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO).build()
        val outFmt = AudioFormat.Builder().setSampleRate(RATE).setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build()
        val rec = try {
            am.javaClass.getMethod("getCallDownlinkExtractionAudioRecord", AudioFormat::class.java).invoke(am, inFmt) as AudioRecord
        } catch (e: Exception) {
            return Start(false, "downlink: ${rootMessage(e)}")
        }
        // The uplink needs MODIFY_PHONE_STATE on top of CALL_AUDIO_INTERCEPTION (audio
        // policy's TELEPHONY_TX check). If it is refused anyway, keep the downlink:
        // hearing the call beats silence, and the Mac says why it cannot be heard.
        var uplinkProblem: String? = null
        val trk = try {
            am.javaClass.getMethod("getCallUplinkInjectionAudioTrack", AudioFormat::class.java).invoke(am, outFmt) as AudioTrack
        } catch (e: Exception) {
            uplinkProblem = "uplink: ${rootMessage(e)}"
            null
        }
        record = rec
        track = trk
        inbox.clear()
        running = true
        rec.startRecording()
        trk?.play()

        Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            var seq = 0
            val pcm = ByteArray(FRAME_BYTES)
            while (running) {
                var got = 0
                while (got < FRAME_BYTES && running) {
                    val n = rec.read(pcm, got, FRAME_BYTES - got)
                    if (n <= 0) break
                    got += n
                }
                if (got < FRAME_BYTES) continue
                sink(ByteBuffer.allocate(4 + FRAME_BYTES).putInt(seq++).put(pcm).array())
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
                trk.write(pcm, 0, pcm.size, AudioTrack.WRITE_BLOCKING)
            }
        }, "ito-uplink").start()
        return Start(true, null)
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
