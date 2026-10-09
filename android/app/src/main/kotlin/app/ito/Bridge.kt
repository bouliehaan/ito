package app.ito

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.provider.CallLog
import android.provider.ContactsContract
import android.provider.Settings
import android.provider.Telephony
import android.telephony.AccessNetworkConstants
import android.telephony.SubscriptionManager
import android.telephony.ims.ImsManager
import android.telephony.ims.ImsReasonInfo
import android.telephony.ims.ImsRegistrationAttributes
import android.telephony.ims.RegistrationManager
import android.util.Log
import app.ito.link.DhKey
import app.ito.link.Group
import app.ito.link.GroupEngine
import app.ito.link.Numbers
import app.ito.link.PhoneHost
import app.ito.link.PhoneLink
import app.ito.link.Role
import app.ito.link.SendTag
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.Executors

/**
 * The phone half of ito: owns the link, answers the Mac, watches the phone's
 * databases and pushes what changes. One per process (see ItoApp).
 */
class Bridge(val ctx: Context) : PhoneHost {
    val keys = Keys(ctx)
    val io = Executors.newSingleThreadExecutor { r -> Thread(r, "ito-io").apply { isDaemon = true } }
    private val sender = SmsSender(ctx)
    val groups = GroupEngine(File(ctx.filesDir, "groups.json"), { to, body, tag -> sendSms(to, body, tag) }, ::label)
    val store = Store(ctx.contentResolver, groups, ctx.packageName)
    val calls = Calls(this)
    val link = PhoneLink(this, log = { Log.w("ito-link", it) })

    @Volatile var service: BridgeService? = null

    // What the phone screen shows.
    @Volatile var pairingCode: String? = null
        private set
    @Volatile var pairingMac: String? = null
        private set
    @Volatile var linked = 0
        private set
    @Volatile var ims = "unknown"
        private set
    val listeners = CopyOnWriteArraySet<() -> Unit>()
    private fun changed() = listeners.forEach { it() }

    private val worker = HandlerThread("ito-watch").apply { start() }
    private val handler = Handler(worker.looper)
    private var started = false
    private var lastSms = 0L
    private var lastMms = 0L
    private var lastCall = 0L

    /** Sends whose stored row has not been matched to its tag yet. */
    private data class Pending(val key: String, val body: String, val tag: SendTag, val at: Long)
    private val pending = ArrayList<Pending>()

    @Synchronized fun start() {
        if (started) return
        started = true
        io.execute {
            lastSms = store.smsIds().lastOrNull() ?: 0
            lastMms = store.mmsIds().lastOrNull() ?: 0
            lastCall = store.callsAfter(0, Int.MAX_VALUE).lastOrNull()?.getLong("id") ?: 0
        }
        try {
            link.start()
        } catch (e: Exception) {
            Log.e(TAG, "cannot listen on ${PhoneLink.PORT}", e)
        }
        advertise()
        watch(Telephony.Sms.CONTENT_URI, 400) { pushSms() }
        watch(Telephony.Mms.CONTENT_URI, 800) { pushMms() }
        watch(CallLog.Calls.CONTENT_URI, 800) { pushCalls() }
        watch(ContactsContract.Contacts.CONTENT_URI, 10_000) { pushContacts() }
        calls.startLegacy()
        watchIms()
        handler.postDelayed(object : Runnable {
            override fun run() {
                link.broadcast(status().put("t", "status"))
                handler.postDelayed(this, 60_000)
            }
        }, 60_000)
    }

    // --- PhoneHost --------------------------------------------------------------

    override val staticKey: DhKey get() = keys.static

    override fun deviceName(): String =
        Settings.Global.getString(ctx.contentResolver, Settings.Global.DEVICE_NAME) ?: Build.MODEL

    override fun isPinned(key: ByteArray) = keys.isPinned(key)
    override fun pin(key: ByteArray, name: String) = keys.pin(key, name).also { changed() }

    override fun showPairing(code: String?, macName: String?) {
        pairingCode = code
        pairingMac = macName
        changed()
    }

    override fun onSessionsChanged(count: Int) {
        linked = count
        service?.refresh()
        changed()
        // A Mac that arrives mid-call should see the call.
        if (count > 0) calls.snapshot().forEach(link::broadcast)
    }

    override fun hello(): JSONObject = JSONObject()
        .put("name", deviceName())
        .put("model", Build.MODEL)
        .put("android", Build.VERSION.RELEASE)
        .put("number", ownNumber())
        .put("fp", keys.fingerprint)
        .put("system", calls.fullControl)
        .put("callAudio", when (calls.audio.interceptable()) {
            true -> "ok"
            false -> "unsupported"
            null -> "needs-system-install"
        })
        .put("sms", hasSmsPermissions())

    override fun status(): JSONObject {
        val bm = ctx.getSystemService(BatteryManager::class.java)
        val sticky = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val cm = ctx.getSystemService(ConnectivityManager::class.java)
        val wifi = cm.getNetworkCapabilities(cm.activeNetwork)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        return JSONObject()
            .put("batt", bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY))
            .put("charging", bm.isCharging)
            .put("plugged", (sticky?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0)
            .put("temp", (sticky?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0) / 10.0)
            .put("wifi", wifi)
            .put("ims", ims)
    }

    override fun smsAfter(id: Long, limit: Int) = store.smsAfter(id, limit)
    override fun smsRecent(count: Int) = store.smsRecent(count)
    override fun smsIds() = store.smsIds()
    override fun mmsAfter(id: Long, limit: Int) = store.mmsAfter(id, limit)
    override fun mmsRecent(count: Int) = store.mmsRecent(count)
    override fun mmsIds() = store.mmsIds()
    override fun callsAfter(id: Long, limit: Int) = store.callsAfter(id, limit)
    override fun contacts() = store.contacts()
    override fun groups(): List<Group> = groups.all()

    override fun handle(session: PhoneLink.Session, msg: JSONObject) {
        when (val t = msg.getString("t")) {
            "send" -> {
                val to = msg.getJSONArray("to")
                val body = msg.getString("body")
                require(body.isNotBlank()) { "empty message" }
                for (i in 0 until to.length()) {
                    val n = to.getString(i)
                    groups.noteDirect(n)
                    sendSms(n, body, SendTag(msg.optString("cid").ifEmpty { null }, null, null, Role.DIRECT))
                }
            }
            "gsend" -> {
                val body = msg.getString("body")
                require(body.isNotBlank()) { "empty message" }
                groups.send(msg.getString("g"), body, msg.optString("cid").ifEmpty { null })
            }
            "group.save" -> {
                val g = msg.getJSONObject("g")
                val members = g.getJSONArray("members").let { a -> List(a.length()) { a.getString(it) } }
                val saved = groups.save(g.optString("name"), members, g.optBoolean("relay"), g.optString("id").ifEmpty { null })
                pushGroups()
                session.post(JSONObject().put("t", "group.saved").put("cid", msg.optString("cid")).put("id", saved.id))
            }
            "group.delete" -> {
                groups.delete(msg.getString("id"))
                pushGroups()
            }
            "refile" -> {
                val id = msg.getLong("id")
                val row = store.smsById(id) ?: throw IllegalArgumentException("no such message")
                require(row.getInt("ty") == Telephony.Sms.MESSAGE_TYPE_INBOX) { "only received texts can be moved" }
                val g = if (msg.isNull("g")) null else msg.optString("g").ifEmpty { null }
                groups.refile(row.getString("a"), row.getString("b"), row.getLong("ds"), g)
                store.smsById(id)?.let { link.broadcastRows("sms", listOf(it)) }
            }
            "photo" -> {
                val k = msg.getString("k")
                session.post(JSONObject().put("t", "photo").put("k", k).put("jpeg", store.photo(k) ?: JSONObject.NULL))
            }
            "mmspart" -> sendPart(session, msg.getLong("pid"))
            "dial", "answer", "decline", "hangup", "dtmf", "hold", "audio" -> calls.handle(session, msg)
            else -> throw IllegalArgumentException("unknown request $t")
        }
    }

    override fun onAudio(session: PhoneLink.Session, frame: ByteArray) = calls.onMacAudio(session, frame)

    override fun onSessionClosed(session: PhoneLink.Session) = calls.onSessionClosed(session)

    // --- texts --------------------------------------------------------------------

    private fun sendSms(to: String, body: String, tag: SendTag) {
        synchronized(pending) {
            pending += Pending(Numbers.key(to), body, tag, System.currentTimeMillis())
            pending.removeAll { System.currentTimeMillis() - it.at > 10 * 60_000 }
        }
        sender.send(to, body, tag)
    }

    fun onSent(tag: SendTag, to: String, ok: Boolean, error: Int, smsId: Long?, last: Boolean) {
        if (smsId != null) {
            groups.bindSent(tag, smsId)
            synchronized(pending) { pending.removeAll { it.tag == tag && it.key == Numbers.key(to) } }
            store.smsById(smsId)?.let { link.broadcastRows("sms", listOf(it)) }
        }
        if (tag.cid != null && (last || !ok)) {
            link.broadcast(JSONObject().put("t", "sent").put("cid", tag.cid).put("to", to).put("ok", ok).put("err", error))
        }
    }

    fun onDelivered(smsId: Long?) {
        smsId?.let(store::smsById)?.let { link.broadcastRows("sms", listOf(it)) }
    }

    fun onInbound(from: String, body: String, sentAt: Long) {
        groups.onInbound(from, body, sentAt)
        // The messaging app stores the row on its own schedule; push again once it has.
        handler.postDelayed({ pushSms() }, 1500)
    }

    /**
     * Fallback for a sent-intent that came back without the row's uri: match
     * ito's own stored rows to the sends still waiting, by recipient and text.
     */
    private fun claimUnbound(rows: List<JSONObject>): List<JSONObject> = rows.map { row ->
        if (!row.optBoolean("ito") || row.has("g") || row.getInt("ty") == Telephony.Sms.MESSAGE_TYPE_INBOX) return@map row
        val match = synchronized(pending) {
            pending.firstOrNull { it.key == Numbers.key(row.getString("a")) && it.body == row.getString("b") }
                ?.also { pending.remove(it) }
        } ?: return@map row
        if (match.tag.group == null) return@map row
        groups.bindSent(match.tag, row.getLong("id"))
        store.smsById(row.getLong("id")) ?: row
    }

    private fun pushSms() {
        val fresh = store.smsAfter(lastSms, 500)
        val recent = store.smsRecent(40)
        val rows = (fresh + recent).distinctBy { it.getLong("id") }
        if (fresh.isNotEmpty()) lastSms = fresh.last().getLong("id")
        link.broadcastRows("sms", claimUnbound(rows))
    }

    private fun pushMms() {
        val fresh = store.mmsAfter(lastMms, 100)
        if (fresh.isNotEmpty()) lastMms = fresh.last().getLong("id")
        link.broadcastRows("mms", (fresh + store.mmsRecent(10)).distinctBy { it.getLong("id") })
    }

    private fun pushCalls() {
        val fresh = store.callsAfter(lastCall, 200)
        if (fresh.isEmpty()) return
        lastCall = fresh.last().getLong("id")
        link.broadcastRows("calls", fresh)
    }

    private fun pushContacts() {
        if (link.trustedCount == 0) return
        link.broadcastRows("contacts", store.contacts())
    }

    private fun pushGroups() =
        link.broadcast(JSONObject().put("t", "groups").put("groups", JSONArray(groups.all().map(Group::toJson))))

    private fun sendPart(session: PhoneLink.Session, pid: Long) {
        val (ct, bytes) = store.mmsPart(pid) ?: run {
            session.post(JSONObject().put("t", "mmspart").put("pid", pid).put("missing", true))
            return
        }
        val chunk = 36_000
        val n = maxOf(1, (bytes.size + chunk - 1) / chunk)
        for (i in 0 until n) {
            val slice = bytes.copyOfRange(i * chunk, minOf(bytes.size, (i + 1) * chunk))
            session.post(JSONObject().put("t", "mmspart").put("pid", pid).put("ct", ct).put("i", i).put("n", n)
                .put("data", android.util.Base64.encodeToString(slice, android.util.Base64.NO_WRAP)))
        }
    }

    /** Relayed group texts are signed with a first name, never a full name or a number. */
    fun label(number: String): String =
        store.nameFor(number)?.trim()?.split(Regex("\\s+"))?.firstOrNull()?.lowercase()?.takeIf { it.isNotEmpty() }
            ?: ("…" + Numbers.key(number).takeLast(4))

    // --- plumbing -------------------------------------------------------------------

    private fun watch(uri: android.net.Uri, debounceMs: Long, push: () -> Unit) {
        val run = Runnable { if (link.trustedCount > 0) runCatching(push).onFailure { Log.w(TAG, "push failed", it) } }
        runCatching {
            ctx.contentResolver.registerContentObserver(uri, true, object : ContentObserver(handler) {
                override fun onChange(selfChange: Boolean) {
                    handler.removeCallbacks(run)
                    handler.postDelayed(run, debounceMs)
                }
            })
        }.onFailure { Log.w(TAG, "cannot watch $uri (permission?)", it) }
    }

    private fun advertise() {
        val nsd = ctx.getSystemService(NsdManager::class.java)
        val info = NsdServiceInfo().apply {
            // Named by key fingerprint, not by device or owner: the LAN learns nothing personal.
            serviceName = "ito-${keys.fingerprint}"
            serviceType = PhoneLink.SERVICE_TYPE
            port = PhoneLink.PORT
            setAttribute("fp", keys.fingerprint)
            setAttribute("v", "1")
        }
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(i: NsdServiceInfo) { Log.i(TAG, "advertised ${i.serviceName}") }
            override fun onRegistrationFailed(i: NsdServiceInfo, code: Int) { Log.w(TAG, "mdns failed $code") }
            override fun onServiceUnregistered(i: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(i: NsdServiceInfo, code: Int) = Unit
        })
    }

    private fun watchIms() {
        runCatching {
            val sub = SubscriptionManager.getDefaultSmsSubscriptionId()
            ctx.getSystemService(ImsManager::class.java).getImsMmTelManager(sub).registerImsRegistrationCallback(io, object : RegistrationManager.RegistrationCallback() {
                override fun onRegistered(attributes: ImsRegistrationAttributes) {
                    ims = if (attributes.transportType == AccessNetworkConstants.TRANSPORT_TYPE_WLAN) "wifi" else "cellular"
                    imsChanged()
                }
                override fun onRegistering(attributes: ImsRegistrationAttributes) { ims = "registering"; imsChanged() }
                override fun onUnregistered(info: ImsReasonInfo) { ims = "off"; imsChanged() }
            })
        }.onFailure { Log.i(TAG, "ims state unavailable: ${it.message}") }
    }

    private fun imsChanged() {
        changed()
        link.broadcast(status().put("t", "status"))
    }

    @Suppress("MissingPermission")
    private fun ownNumber(): String = runCatching {
        val sm = ctx.getSystemService(SubscriptionManager::class.java)
        sm.getPhoneNumber(SubscriptionManager.getDefaultSmsSubscriptionId())
    }.getOrNull() ?: ""

    fun hasSmsPermissions(): Boolean = listOf(
        android.Manifest.permission.READ_SMS, android.Manifest.permission.RECEIVE_SMS, android.Manifest.permission.SEND_SMS,
    ).all { ctx.checkSelfPermission(it) == android.content.pm.PackageManager.PERMISSION_GRANTED }

    companion object {
        private const val TAG = "ito"
    }
}
