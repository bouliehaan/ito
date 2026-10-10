package app.ito.link

import org.json.JSONArray
import org.json.JSONObject
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Everything the link needs from the phone. The Android app and :fakephone both implement it. */
interface PhoneHost {
    val staticKey: DhKey
    fun deviceName(): String

    fun isPinned(key: ByteArray): Boolean
    fun pin(key: ByteArray, name: String)

    /** Show the pairing code on the phone (null hides it). The phone user answers via [PhoneLink.confirmPairing]. */
    fun showPairing(code: String?, macName: String?)
    fun onSessionsChanged(count: Int) {}

    fun hello(): JSONObject
    fun status(): JSONObject

    fun smsAfter(id: Long, limit: Int): List<JSONObject>
    fun smsRecent(count: Int): List<JSONObject>
    fun smsIds(): LongArray
    fun mmsAfter(id: Long, limit: Int): List<JSONObject>
    fun mmsRecent(count: Int): List<JSONObject>
    fun mmsIds(): LongArray
    fun callsAfter(id: Long, limit: Int): List<JSONObject>
    fun contacts(): List<JSONObject>
    fun groups(): List<Group>

    /** Everything else a trusted Mac can ask for: send, gsend, group.*, refile, photo, call control. */
    fun handle(session: PhoneLink.Session, msg: JSONObject)
    fun onAudio(session: PhoneLink.Session, frame: ByteArray) {}
    fun onSessionClosed(session: PhoneLink.Session) {}
}

/**
 * The phone's listener. Macs connect in; every connection does the Noise XX
 * handshake, then is either trusted (its key is pinned), pairing (the phone
 * user opened a pairing window), or refused and closed.
 */
class PhoneLink(
    private val host: PhoneHost,
    private val port: Int = PORT,
    private val log: (String) -> Unit = { System.err.println("ito-link: $it") },
) {
    private val sessions = CopyOnWriteArrayList<Session>()
    @Volatile private var server: ServerSocket? = null
    @Volatile private var pairingUntil = 0L
    @Volatile private var pairing: Session? = null

    val trustedCount get() = sessions.count { it.trusted }

    /** The real port, for when the link was started on port 0 (tests). */
    val boundPort: Int get() = server?.localPort ?: -1

    fun start() {
        val ss = ServerSocket()
        ss.reuseAddress = true
        ss.bind(InetSocketAddress(port))
        server = ss
        Thread({
            while (!ss.isClosed) {
                val s = try { ss.accept() } catch (e: Exception) { break }
                if (sessions.size >= MAX_SESSIONS) { runCatching { s.close() }; continue }
                Thread({ serve(s) }, "ito-session").apply { isDaemon = true }.start()
            }
        }, "ito-accept").apply { isDaemon = true }.start()
    }

    fun stop() {
        runCatching { server?.close() }
        sessions.forEach { it.close() }
    }

    /** The phone user opened pairing. Only one Mac can pair per window. */
    fun openPairing(ms: Long = 120_000) {
        pairingUntil = System.currentTimeMillis() + ms
    }

    fun closePairing() {
        pairingUntil = 0
        pairing?.let { it.pairNo("cancelled on the phone") }
    }

    val pairingOpen get() = System.currentTimeMillis() < pairingUntil

    fun confirmPairing(ok: Boolean) {
        val p = pairing ?: return
        if (ok) p.localOk() else p.pairNo("rejected on the phone")
    }

    /** To every trusted Mac. */
    fun broadcast(msg: JSONObject) = sessions.filter { it.trusted }.forEach { it.post(msg) }

    fun broadcastRows(type: String, rows: List<JSONObject>) =
        sessions.filter { it.trusted }.forEach { it.postRows(type, rows) }

    fun sessions(): List<Session> = sessions.filter { it.trusted }

    private fun serve(socket: Socket) {
        val ch = try {
            Channel.accept(socket, host.staticKey, JSONObject().put("name", host.deviceName()).put("v", 1))
        } catch (e: Exception) {
            runCatching { socket.close() }
            return
        }
        val session = Session(ch)
        sessions += session
        try {
            session.run()
        } catch (e: Exception) {
            if (e !is java.io.EOFException && e !is java.net.SocketException) log("session ended: $e")
        } finally {
            session.close()
            sessions -= session
            if (pairing === session) {
                pairing = null
                host.showPairing(null, null)
            }
            host.onSessionClosed(session)
            host.onSessionsChanged(trustedCount)
        }
    }

    inner class Session internal constructor(private val ch: Channel) {
        @Volatile var trusted = false
            private set
        val macName: String = ch.remoteHello.optString("name", "mac").take(64)
        val address get() = ch.remoteAddress

        // One writer thread per session keeps sync and pushes in order and off the reader.
        private val outq: ExecutorService = Executors.newSingleThreadExecutor { r ->
            Thread(r, "ito-out").apply { isDaemon = true }
        }

        private var phoneNonce: ByteArray? = null
        private var code: String? = null
        @Volatile private var localOk = false
        @Volatile private var remoteOk = false

        internal fun run() {
            when {
                host.isPinned(ch.remoteStatic) -> becomeTrusted()
                pairingOpen && pairing == null -> startPairing()
                else -> {
                    ch.sendJson(JSONObject().put("t", "auth").put("state", "refused")
                        .put("why", if (pairingOpen) "another mac is pairing" else "this mac is not paired. open pairing on the phone first"))
                    return
                }
            }
            while (true) {
                val (kind, body) = try {
                    ch.receive()
                } catch (e: SocketTimeoutException) {
                    return
                }
                when (kind) {
                    Kind.JSON -> onJson(JSONObject(String(body, Charsets.UTF_8)))
                    Kind.AUDIO -> if (trusted) host.onAudio(this, body)
                }
            }
        }

        private fun onJson(m: JSONObject) {
            val t = m.optString("t")
            if (!trusted) {
                onPairing(t, m)
                return
            }
            when (t) {
                "ping" -> post(JSONObject().put("t", "pong"))
                "sync" -> outq.execute { runCatching { sync(m) }.onFailure { log("sync failed: $it") } }
                else -> runCatching { host.handle(this, m) }.onFailure {
                    post(JSONObject().put("t", "error").put("for", t).put("msg", it.message ?: it.toString()))
                }
            }
        }

        // --- pairing -----------------------------------------------------------

        private fun startPairing() {
            pairing = this
            ch.sendJson(JSONObject().put("t", "auth").put("state", "pairing"))
            phoneNonce = Sas.nonce()
            ch.sendJson(JSONObject().put("t", "pair.commit").put("c", Sas.commit(phoneNonce!!).toHex()))
            setReadTimeout(PAIRING_TIMEOUT_MS)
        }

        private fun onPairing(t: String, m: JSONObject) {
            if (pairing !== this) throw IllegalStateException("not pairing")
            when (t) {
                "pair.nonce" -> {
                    check(code == null) { "nonce twice" }
                    val macNonce = hex(m.getString("n"))
                    require(macNonce.size == 32) { "bad nonce" }
                    ch.sendJson(JSONObject().put("t", "pair.reveal").put("n", phoneNonce!!.toHex()))
                    code = Sas.code(ch.handshakeHash, macNonce, phoneNonce!!)
                    host.showPairing(code, macName)
                }
                "pair.ok" -> {
                    check(code != null) { "ok before code" }
                    remoteOk = true
                    maybeFinishPairing()
                }
                "pair.no" -> throw IllegalStateException("mac rejected the code")
                else -> throw IllegalStateException("unexpected $t while pairing")
            }
        }

        internal fun localOk() {
            if (code == null) return
            localOk = true
            maybeFinishPairing()
        }

        internal fun pairNo(why: String) {
            runCatching { ch.sendJson(JSONObject().put("t", "pair.no").put("why", why)) }
            close()
        }

        @Synchronized private fun maybeFinishPairing() {
            if (!localOk || !remoteOk || trusted) return
            host.pin(ch.remoteStatic, macName)
            pairing = null
            pairingUntil = 0
            host.showPairing(null, null)
            becomeTrusted()
        }

        private fun becomeTrusted() {
            // The same Mac again (it slept, or its Wi-Fi blinked): its old session is dead but
            // would otherwise linger until the 45 s idle timeout, counted as a second Mac.
            sessions.filter { it !== this && it.trusted && it.ch.remoteStatic.contentEquals(ch.remoteStatic) }
                .forEach { it.close() }
            trusted = true
            setReadTimeout(IDLE_TIMEOUT_MS)
            ch.sendJson(JSONObject().put("t", "auth").put("state", "trusted"))
            post(host.hello().put("t", "hello"))
            post(host.status().put("t", "status"))
            host.onSessionsChanged(trustedCount)
        }

        // A live Mac pings every 15 s, so a trusted session that goes 45 s silent is gone.
        private fun setReadTimeout(ms: Int) = ch.setReadTimeout(ms)

        // --- sync --------------------------------------------------------------

        private fun sync(m: JSONObject) {
            val smsAfter = m.optLong("sms", 0)
            val mmsAfter = m.optLong("mms", 0)
            val callsAfter = m.optLong("calls", 0)
            val contactsHash = m.optString("contacts", "")

            sendNow(JSONObject().put("t", "groups").put("groups", JSONArray(host.groups().map(Group::toJson))))

            val contacts = host.contacts()
            val hash = sha256(JSONArray(contacts).toString().toByteArray()).toHex().take(16)
            if (hash != contactsHash) sendRowsNow("contacts", contacts, extra = JSONObject().put("hash", hash))

            var after = smsAfter
            while (true) {
                val page = host.smsAfter(after, PAGE)
                if (page.isEmpty()) break
                sendRowsNow("sms", page)
                after = page.last().getLong("id")
                if (page.size < PAGE) break
            }
            // Statuses and filing of recent rows can change after the Mac saw them.
            if (smsAfter > 0) sendRowsNow("sms", host.smsRecent(RECENT))
            sendIdsNow("sms.ids", host.smsIds())

            var mAfter = mmsAfter
            while (true) {
                val page = host.mmsAfter(mAfter, PAGE)
                if (page.isEmpty()) break
                sendRowsNow("mms", page)
                mAfter = page.last().getLong("id")
                if (page.size < PAGE) break
            }
            if (mmsAfter > 0) sendRowsNow("mms", host.mmsRecent(RECENT / 5))
            sendIdsNow("mms.ids", host.mmsIds())

            var cAfter = callsAfter
            while (true) {
                val page = host.callsAfter(cAfter, PAGE)
                if (page.isEmpty()) break
                sendRowsNow("calls", page)
                cAfter = page.last().getLong("id")
                if (page.size < PAGE) break
            }
            sendNow(JSONObject().put("t", "synced"))
        }

        // --- outbound ----------------------------------------------------------

        fun post(msg: JSONObject) {
            if (!outq.isShutdown) runCatching { outq.execute { sendNow(msg) } }
        }

        fun postRows(type: String, rows: List<JSONObject>) {
            if (rows.isEmpty() || outq.isShutdown) return
            runCatching { outq.execute { sendRowsNow(type, rows) } }
        }

        fun sendAudio(frame: ByteArray) {
            if (trusted) runCatching { ch.send(Kind.AUDIO, frame) }
        }

        private fun sendNow(msg: JSONObject) {
            runCatching { ch.sendJson(msg) }.onFailure { close() }
        }

        /** Rows packed into frames well under the 64 KiB Noise limit. */
        private fun sendRowsNow(type: String, rows: List<JSONObject>, extra: JSONObject? = null) {
            var batch = JSONArray()
            var size = 0
            fun flush(last: Boolean) {
                val msg = JSONObject().put("t", type).put("rows", batch)
                if (last) {
                    msg.put("done", true)
                    extra?.keys()?.forEach { msg.put(it, extra.get(it)) }
                }
                sendNow(msg)
                batch = JSONArray()
                size = 0
            }
            for (r in rows) {
                val s = r.toString()
                if (size + s.length > BATCH_BYTES && batch.length() > 0) flush(false)
                batch.put(r)
                size += s.length + 1
            }
            flush(true)
        }

        private fun sendIdsNow(type: String, ids: LongArray) {
            val chunk = 4000
            var i = 0
            do {
                val end = minOf(ids.size, i + chunk)
                val arr = JSONArray()
                for (j in i until end) arr.put(ids[j])
                sendNow(JSONObject().put("t", type).put("ids", arr).put("done", end == ids.size))
                i = end
            } while (i < ids.size)
        }

        fun close() {
            outq.shutdown()
            runCatching { outq.awaitTermination(200, TimeUnit.MILLISECONDS) }
            ch.close()
        }
    }

    companion object {
        /** House rule: meme ports. The phone is its own host, so 6969 is free there. */
        const val PORT = 6969
        const val SERVICE_TYPE = "_ito._tcp"
        private const val MAX_SESSIONS = 6
        private const val PAGE = 500
        private const val RECENT = 300
        private const val BATCH_BYTES = 48_000
        private const val IDLE_TIMEOUT_MS = 45_000
        private const val PAIRING_TIMEOUT_MS = 150_000
    }
}
