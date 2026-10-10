package app.ito

import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telecom.Call
import android.telecom.InCallService
import android.telecom.TelecomManager
import android.telecom.VideoProfile
import android.telephony.PhoneStateListener
import android.telephony.TelephonyManager
import android.util.Log
import app.ito.link.PhoneLink
import org.json.JSONObject
import java.util.WeakHashMap
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Bound by Telecom for every call, with no UI of its own (the phone's dialer
 * stays the dialer). Only happens when ito holds CONTROL_INCALL_EXPERIENCE,
 * i.e. the system install.
 */
class CallMonitor : InCallService() {
    private val calls get() = (application as ItoApp).bridge.calls

    override fun onCallAdded(call: Call) = calls.onAdded(this, call)
    override fun onCallRemoved(call: Call) = calls.onRemoved(call)
    @Deprecated("CallAudioState is how Telecom still reports the route to an in-call service")
    override fun onCallAudioStateChanged(state: android.telecom.CallAudioState) = calls.onRouteChanged(state.route)
    override fun onUnbind(intent: android.content.Intent?): Boolean {
        calls.onUnbound(this)
        return super.onUnbind(intent)
    }
}

/**
 * Every call the phone has, as the Mac sees it, and the Mac's hands on them.
 *
 * Two levels:
 *  - system install: full control through CallMonitor, and audio over the
 *    link through [CallAudio].
 *  - plain install: the legacy phone-state broadcast shows ringing / in call /
 *    idle on the Mac and lets it decline. Audio stays on the phone.
 */
class Calls(private val bridge: Bridge) {
    private val ids = WeakHashMap<Call, String>()
    private val calls = ConcurrentHashMap<String, Call>()
    private val nextId = AtomicInteger(1)
    @Volatile private var service: InCallService? = null

    val audio = CallAudio(bridge.ctx).also { a ->
        a.onMacQuiet = {
            Log.w("ito-calls", "no microphone from the Mac")
            audioOwner?.post(JSONObject().put("t", "error").put("for", "audio")
                .put("msg", "the call isn't getting your Mac's microphone, so the phone's own mic is on"))
        }
        a.onMacLive = { live -> main.post { macMicLive(live) } }
    }
    @Volatile private var audioOwner: PhoneLink.Session? = null
    @Volatile private var audioCall: String? = null
    /** Calls a Mac answered or dialed: audio follows them there as soon as they go active. */
    private val wantsAudio = ConcurrentHashMap<String, PhoneLink.Session>()
    @Volatile private var pendingDial: PhoneLink.Session? = null

    private val telecom get() = bridge.ctx.getSystemService(TelecomManager::class.java)

    val fullControl: Boolean
        get() = bridge.ctx.checkSelfPermission("android.permission.CONTROL_INCALL_EXPERIENCE") == PackageManager.PERMISSION_GRANTED

    // --- Telecom side ----------------------------------------------------------

    fun onAdded(svc: InCallService, call: Call) {
        service = svc
        val id = "c" + nextId.getAndIncrement()
        synchronized(ids) { ids[call] = id }
        calls[id] = call
        if (call.details.callDirection == Call.Details.DIRECTION_OUTGOING) {
            pendingDial?.let { wantsAudio[id] = it }
            pendingDial = null
        }
        call.registerCallback(object : Call.Callback() {
            override fun onStateChanged(c: Call, state: Int) = changed(c)
            override fun onDetailsChanged(c: Call, details: Call.Details) = changed(c)
        })
        changed(call)
    }

    fun onRemoved(call: Call) {
        val id = idOf(call) ?: return
        calls.remove(id)
        wantsAudio.remove(id)
        if (audioCall == id) stopAudio()
        bridge.link.broadcast(stateJson(id, call).put("state", "ended"))
    }

    fun onUnbound(svc: InCallService) {
        if (service === svc) service = null
    }

    private fun changed(call: Call) {
        val id = idOf(call) ?: return
        val state = call.details.state
        // Outgoing: open the audio while dialing, so the Mac hears the ringback.
        val outgoing = call.details.callDirection == Call.Details.DIRECTION_OUTGOING
        if (state == Call.STATE_ACTIVE || (outgoing && state == Call.STATE_DIALING)) wantsAudio.remove(id)?.let { startAudio(id, it) }
        if (state == Call.STATE_DISCONNECTED && audioCall == id) stopAudio()
        bridge.link.broadcast(stateJson(id, call))
    }

    private fun idOf(call: Call) = synchronized(ids) { ids[call] }

    private fun stateJson(id: String, call: Call): JSONObject {
        val d = call.details
        val number = d.handle?.schemeSpecificPart ?: ""
        return JSONObject()
            .put("t", "call").put("id", id)
            .put("state", stateName(d.state))
            .put("n", number)
            .put("nm", d.contactDisplayName ?: bridge.store.nameFor(number) ?: "")
            .put("dir", if (d.callDirection == Call.Details.DIRECTION_OUTGOING) "out" else "in")
            .put("since", d.connectTimeMillis)
            .put("audio", audioCall == id)
            .put("full", true)
    }

    /** Sent to a Mac that connects mid-call, so it can show what is going on. */
    fun snapshot(): List<JSONObject> = calls.entries.map { (id, c) -> stateJson(id, c) }

    // --- Mac side ---------------------------------------------------------------

    fun handle(session: PhoneLink.Session, m: JSONObject) {
        val id = m.optString("id")
        val call = calls[id]
        when (m.getString("t")) {
            "dial" -> {
                val n = m.getString("n").filter { it.isDigit() || it == '+' || it == '*' || it == '#' }
                require(n.isNotEmpty()) { "no number" }
                pendingDial = session
                telecom.placeCall(Uri.fromParts("tel", n, null), Bundle())
            }
            "answer" -> {
                if (call != null) {
                    wantsAudio[id] = session
                    call.answer(VideoProfile.STATE_AUDIO_ONLY)
                } else legacyAnswer()
            }
            "decline" -> if (call != null) call.reject(false, null) else legacyEnd()
            "hangup" -> if (call != null) call.disconnect() else legacyEnd()
            "dtmf" -> call?.let { c ->
                val digit = m.getString("d").first()
                // Held 160 ms, one at a time. A play immediately followed by stop is too short
                // for IMS to send a DTMF event and the far end never sees the digit.
                dtmf.execute {
                    Log.i("ito-calls", "dtmf $digit")
                    c.playDtmfTone(digit)
                    Thread.sleep(160)
                    c.stopDtmfTone()
                    Thread.sleep(80)
                }
            }
            "hold" -> call?.let { if (m.optBoolean("on")) it.hold() else it.unhold() }
            "audio" -> if (m.optBoolean("on")) {
                if (call?.details?.state == Call.STATE_ACTIVE) startAudio(id, session) else wantsAudio[id] = session
            } else if (audioCall == id) stopAudio()
        }
    }

    fun onSessionClosed(session: PhoneLink.Session) {
        wantsAudio.entries.removeIf { it.value === session }
        if (audioOwner === session) stopAudio() // the call carries on, on the phone
    }

    fun onMacAudio(session: PhoneLink.Session, frame: ByteArray) {
        if (session === audioOwner) audio.onMacFrame(frame)
    }

    private val main = Handler(Looper.getMainLooper())
    private val dtmf = java.util.concurrent.Executors.newSingleThreadExecutor { r -> Thread(r, "ito-dtmf").apply { isDaemon = true } }
    private val am get() = bridge.ctx.getSystemService(android.media.AudioManager::class.java)
    private val prefs get() = bridge.ctx.getSharedPreferences("calls", android.content.Context.MODE_PRIVATE)
    private var quietSince = 0L

    /**
     * While a Mac carries the call, the phone itself stays out of it: the call is held on
     * the earpiece (never the loudspeaker) at the lowest volume, and its mic is muted
     * while, and only while, the Mac's mic is really arriving (see [macMicLive]). Volume
     * and mic come back afterwards.
     */
    @Suppress("DEPRECATION")
    private fun quietPhone(on: Boolean) {
        val stream = android.media.AudioManager.STREAM_VOICE_CALL
        runCatching {
            if (on) {
                // On disk, not in memory: if ito dies mid-call, the next start puts it back.
                if (!prefs.contains(SAVED_VOLUME)) prefs.edit().putInt(SAVED_VOLUME, am.getStreamVolume(stream)).commit()
                quietSince = System.currentTimeMillis()
                service?.setAudioRoute(android.telecom.CallAudioState.ROUTE_EARPIECE)
                am.setStreamVolume(stream, am.getStreamMinVolume(stream), 0)
            } else {
                restoreVolume()
            }
        }.onFailure { Log.w("ito-calls", "could not quiet the phone: $it") }
    }

    /**
     * The phone's mic is off only while the Mac's voice is actually reaching the call,
     * and back on the moment it stops. Muting it as soon as the Mac took the call left
     * calls with no voice at all whenever the Mac's mic failed to start; this way the
     * worst case is the phone's mic, never silence. In-call music does not silence the
     * phone's mic on its own; it makes a call mute act on the mic alone, so the Mac's
     * voice keeps flowing while the phone's mic is off. Main thread.
     */
    private fun macMicLive(live: Boolean) {
        if (audioCall == null) return
        if (!live) return unmutePhone()
        if (audio.uplinkVia != "in-call music" || service?.callAudioState?.isMuted == true) return
        prefs.edit().putBoolean(MUTED_BY_ITO, true).commit()
        runCatching { service?.setMuted(true) }.onFailure { Log.w("ito-calls", "could not mute the phone: $it") }
        Log.i("ito-calls", "Mac mic arriving: phone mic muted")
    }

    /** Also called at every start: undo a quieting that a crash or restart left behind. */
    fun restoreVolume() {
        if (audioCall != null) return
        unmutePhone()
        if (!prefs.contains(SAVED_VOLUME)) return
        runCatching { am.setStreamVolume(android.media.AudioManager.STREAM_VOICE_CALL, prefs.getInt(SAVED_VOLUME, 0), 0) }
        prefs.edit().remove(SAVED_VOLUME).commit()
    }

    /** Only a mute ito made: a call the user muted on the phone stays muted. */
    private fun unmutePhone() {
        if (!prefs.getBoolean(MUTED_BY_ITO, false)) return
        runCatching { service?.setMuted(false) ?: am.setMicrophoneMute(false) }
            .onFailure { Log.w("ito-calls", "could not unmute the phone: $it") }
        prefs.edit().remove(MUTED_BY_ITO).commit()
        Log.i("ito-calls", "phone mic back on")
    }

    /**
     * Someone picked up the phone: the call's route changed on the phone itself (speaker,
     * a headset, Bluetooth) while a Mac carried it. The phone always wins; hand it back.
     */
    fun onRouteChanged(route: Int) {
        if (audioCall == null || route == android.telecom.CallAudioState.ROUTE_EARPIECE) return
        if (System.currentTimeMillis() - quietSince < 1500) return // our own switch settling
        Log.i("ito-calls", "route changed on the phone ($route): call goes back to the phone")
        releaseToPhone()
    }

    /** The phone takes the call back from the Mac: audio stops, volume and mic return. */
    fun releaseToPhone() {
        val owner = audioOwner
        stopAudio()
        owner?.post(JSONObject().put("t", "error").put("for", "audio").put("msg", "the call moved to the phone"))
    }

    private fun startAudio(id: String, session: PhoneLink.Session, attempt: Int = 0) {
        if (!calls.containsKey(id)) return
        if (audioCall != null && audioCall != id) stopAudio()
        bridge.service?.promoteForCall(true)
        val result = audio.start { frame -> session.sendAudio(frame) }
        if (!result.started) {
            // Telecom can report the call before it has switched the audio mode to
            // "in call", and the redirection API refuses until it has. Give it a moment.
            if (attempt < 8) {
                main.postDelayed({ startAudio(id, session, attempt + 1) }, 250)
                return
            }
            Log.w("ito-calls", "call audio failed: ${result.problem}")
            bridge.service?.promoteForCall(false)
            session.post(JSONObject().put("t", "error").put("for", "audio").put("msg", result.problem))
            return
        }
        if (result.problem == null) Log.i("ito-calls", "call audio up both ways for $id")
        result.problem?.let {
            Log.w("ito-calls", "call audio is one-way: $it")
            session.post(JSONObject().put("t", "error").put("for", "audio").put("msg", "you can hear them, they can't hear you ($it)"))
        }
        audioOwner = session
        audioCall = id
        quietPhone(true)
        calls[id]?.let { bridge.link.broadcast(stateJson(id, it)) }
    }

    private fun stopAudio() {
        // The phone's mic first, while in-call music still makes the mute a mic-only one.
        unmutePhone()
        audio.stop()
        val id = audioCall
        audioOwner = null
        audioCall = null
        quietPhone(false) // after audioCall is cleared: restoreVolume refuses during a Mac call
        bridge.service?.promoteForCall(false)
        id?.let { calls[it] }?.let { bridge.link.broadcast(stateJson(id, it)) }
    }

    // --- plain install fallback ---------------------------------------------------

    @Suppress("DEPRECATION")
    private val legacy = object : PhoneStateListener() {
        override fun onCallStateChanged(state: Int, number: String?) {
            if (fullControl) return
            val s = when (state) {
                TelephonyManager.CALL_STATE_RINGING -> "ringing"
                TelephonyManager.CALL_STATE_OFFHOOK -> "active"
                else -> "ended"
            }
            val n = number ?: ""
            bridge.link.broadcast(
                JSONObject().put("t", "call").put("id", "legacy").put("state", s).put("n", n)
                    .put("nm", if (n.isEmpty()) "" else bridge.store.nameFor(n) ?: "")
                    .put("dir", "in").put("audio", false).put("full", false),
            )
        }
    }

    @Suppress("DEPRECATION")
    fun startLegacy() {
        if (fullControl) return
        runCatching {
            bridge.ctx.getSystemService(TelephonyManager::class.java).listen(legacy, PhoneStateListener.LISTEN_CALL_STATE)
        }
    }

    @Suppress("DEPRECATION", "MissingPermission")
    private fun legacyAnswer() = runCatching { telecom.acceptRingingCall() }

    @Suppress("MissingPermission")
    private fun legacyEnd() = runCatching { telecom.endCall() }

    private companion object {
        const val SAVED_VOLUME = "voiceVolumeBeforeMac"
        const val MUTED_BY_ITO = "micMutedForMac"
    }

    private fun stateName(s: Int) = when (s) {
        Call.STATE_RINGING, Call.STATE_SIMULATED_RINGING -> "ringing"
        Call.STATE_DIALING, Call.STATE_CONNECTING, Call.STATE_NEW, Call.STATE_SELECT_PHONE_ACCOUNT, Call.STATE_PULLING_CALL -> "dialing"
        Call.STATE_ACTIVE, Call.STATE_AUDIO_PROCESSING -> "active"
        Call.STATE_HOLDING -> "held"
        Call.STATE_DISCONNECTING, Call.STATE_DISCONNECTED -> "ended"
        else -> "dialing"
    }
}
