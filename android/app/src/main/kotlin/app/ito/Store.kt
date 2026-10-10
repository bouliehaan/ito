package app.ito

import android.content.ContentResolver
import android.content.ContentUris
import android.database.Cursor
import android.net.Uri
import android.provider.CallLog
import android.provider.ContactsContract
import android.provider.Telephony
import android.util.Base64
import app.ito.link.GroupEngine
import app.ito.link.Numbers
import org.json.JSONArray
import org.json.JSONObject

/**
 * Read-only views of the phone's own databases, as wire rows. The phone's
 * messaging app, dialer and contacts stay the source of truth; ito never
 * writes to them (Android writes ito's sent texts into the SMS store itself).
 */
class Store(private val cr: ContentResolver, private val groups: GroupEngine, private val pkg: String) {

    // --- SMS -----------------------------------------------------------------

    private val smsCols = arrayOf(
        Telephony.Sms._ID, Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY,
        Telephony.Sms.DATE, Telephony.Sms.DATE_SENT, Telephony.Sms.TYPE, Telephony.Sms.READ,
        Telephony.Sms.STATUS, Telephony.Sms.CREATOR,
    )

    fun smsAfter(after: Long, limit: Int): List<JSONObject> =
        query(Telephony.Sms.CONTENT_URI, smsCols, "${Telephony.Sms._ID} > ?", arrayOf(after.toString()),
            "${Telephony.Sms._ID} ASC", limit, ::smsRow)

    fun smsRecent(count: Int): List<JSONObject> =
        query(Telephony.Sms.CONTENT_URI, smsCols, null, null, "${Telephony.Sms._ID} DESC", count, ::smsRow).reversed()

    fun smsById(id: Long): JSONObject? =
        query(Telephony.Sms.CONTENT_URI, smsCols, "${Telephony.Sms._ID} = ?", arrayOf(id.toString()), null, row = ::smsRow).firstOrNull()

    fun smsIds(): LongArray = ids(Telephony.Sms.CONTENT_URI)

    /** Sent rows Android wrote for ito that no tag has claimed yet (see Bridge.claimUnbound). */
    fun ourRecentSent(sinceMs: Long): List<JSONObject> =
        query(Telephony.Sms.CONTENT_URI, smsCols,
            "${Telephony.Sms.CREATOR} = ? AND ${Telephony.Sms.DATE} > ? AND ${Telephony.Sms.TYPE} != ${Telephony.Sms.MESSAGE_TYPE_INBOX}",
            arrayOf(pkg, sinceMs.toString()), "${Telephony.Sms._ID} ASC", row = ::smsRow)

    private fun smsRow(c: Cursor): JSONObject {
        val id = c.getLong(0)
        val address = c.getString(2) ?: ""
        val body = c.getString(3) ?: ""
        val type = c.getInt(6)
        val dateSent = c.getLong(5)
        val o = JSONObject()
            .put("id", id).put("th", c.getLong(1)).put("a", address).put("b", body)
            .put("d", c.getLong(4)).put("ds", dateSent).put("ty", type)
            .put("r", c.getInt(7)).put("st", c.getInt(8))
        if (c.getString(9) == pkg) o.put("ito", true)
        val filed = if (type == Telephony.Sms.MESSAGE_TYPE_INBOX) groups.filedInbound(address, dateSent, body)
        else groups.filedOutbound(id)
        filed?.let { f ->
            o.put("g", f.group)
            f.gm?.let { o.put("gm", it) }
            if (f.relay) o.put("rl", true)
        }
        return o
    }

    // --- MMS (read-only: no cellular data means new ones cannot download) ----

    fun mmsAfter(after: Long, limit: Int): List<JSONObject> =
        query(Telephony.Mms.CONTENT_URI, MMS_COLS, "${Telephony.Mms._ID} > ?", arrayOf(after.toString()),
            "${Telephony.Mms._ID} ASC", limit, ::mmsRow)

    fun mmsRecent(count: Int): List<JSONObject> =
        query(Telephony.Mms.CONTENT_URI, MMS_COLS, null, null, "${Telephony.Mms._ID} DESC", count, ::mmsRow).reversed()

    fun mmsIds(): LongArray = ids(Telephony.Mms.CONTENT_URI)

    private fun mmsRow(c: Cursor): JSONObject {
        val id = c.getLong(0)
        val o = JSONObject()
            .put("id", id).put("th", c.getLong(1))
            .put("d", c.getLong(2) * 1000) // MMS dates are seconds
            .put("box", c.getInt(3)).put("r", c.getInt(5))
        // 130 = m-notification-ind: someone sent an MMS and it never downloaded.
        if (c.getInt(4) == 130) o.put("undl", true)
        val addrs = JSONArray()
        var from: String? = null
        query(Uri.parse("content://mms/$id/addr"), arrayOf("address", "type"), null, null, null) { a ->
            val addr = a.getString(0) ?: ""
            if (addr.isNotEmpty() && addr != "insert-address-token") {
                if (a.getInt(1) == 137) from = addr else addrs.put(addr)
            }
        }
        o.put("from", from ?: "").put("to", addrs)
        val text = StringBuilder()
        val parts = JSONArray()
        query(Uri.parse("content://mms/part"), arrayOf("_id", "ct", "text", "name", "cl"), "mid = ?", arrayOf(id.toString()), null) { p ->
            val ct = p.getString(1) ?: ""
            when {
                ct == "text/plain" -> p.getString(2)?.let { if (text.isNotEmpty()) text.append('\n'); text.append(it) }
                ct == "application/smil" -> Unit
                else -> parts.put(JSONObject().put("pid", p.getLong(0)).put("ct", ct).put("name", p.getString(3) ?: p.getString(4) ?: ""))
            }
        }
        o.put("b", text.toString())
        if (parts.length() > 0) o.put("parts", parts)
        return o
    }

    /** Raw bytes of one MMS attachment, for the Mac to show on demand. */
    fun mmsPart(pid: Long): Pair<String, ByteArray>? {
        val ct = query(Uri.parse("content://mms/part"), arrayOf("ct"), "_id = ?", arrayOf(pid.toString()), null) { it.getString(0) }
            .firstOrNull() ?: return null
        val bytes = cr.openInputStream(Uri.parse("content://mms/part/$pid"))?.use { it.readBytes() } ?: return null
        return ct to bytes
    }

    // --- Calls ---------------------------------------------------------------

    fun callsAfter(after: Long, limit: Int): List<JSONObject> =
        query(CallLog.Calls.CONTENT_URI,
            arrayOf(CallLog.Calls._ID, CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.TYPE, CallLog.Calls.DATE, CallLog.Calls.DURATION),
            "${CallLog.Calls._ID} > ?", arrayOf(after.toString()), "${CallLog.Calls._ID} ASC", limit = limit) { c ->
            JSONObject().put("id", c.getLong(0)).put("n", c.getString(1) ?: "").put("nm", c.getString(2) ?: "")
                .put("ty", c.getInt(3)).put("d", c.getLong(4)).put("dur", c.getLong(5))
        }

    fun callsRecent(count: Int): List<JSONObject> =
        query(CallLog.Calls.CONTENT_URI, arrayOf(CallLog.Calls._ID), null, null, "${CallLog.Calls._ID} DESC", limit = count) { c ->
            JSONObject().put("id", c.getLong(0))
        }

    // --- Contacts ------------------------------------------------------------

    fun contacts(): List<JSONObject> {
        val byKey = LinkedHashMap<String, JSONObject>()
        query(ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Phone.LOOKUP_KEY,
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
                ContactsContract.CommonDataKinds.Phone.PHOTO_THUMBNAIL_URI,
            ), null, null, ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " ASC") { c ->
            val key = c.getString(0) ?: return@query
            val o = byKey.getOrPut(key) {
                JSONObject().put("k", key).put("n", c.getString(1) ?: "").put("p", JSONArray()).put("ph", c.getString(3) != null)
            }
            val num = c.getString(2) ?: return@query
            val arr = o.getJSONArray("p")
            if ((0 until arr.length()).none { Numbers.same(arr.getString(it), num) }) arr.put(num)
        }
        return byKey.values.toList()
    }

    /** Name lookup for relay labels and call screens. */
    fun nameFor(number: String): String? {
        val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
        return runCatching {
            query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null) { it.getString(0) }.firstOrNull()
        }.getOrNull()
    }

    fun photo(lookupKey: String): String? = runCatching {
        val lookup = Uri.withAppendedPath(ContactsContract.Contacts.CONTENT_LOOKUP_URI, lookupKey)
        val contact = ContactsContract.Contacts.lookupContact(cr, lookup) ?: return null
        ContactsContract.Contacts.openContactPhotoInputStream(cr, contact, false)?.use {
            Base64.encodeToString(it.readBytes(), Base64.NO_WRAP)
        }
    }.getOrNull()

    // --- plumbing ------------------------------------------------------------

    private fun ids(uri: Uri): LongArray {
        val out = ArrayList<Long>()
        query(uri, arrayOf("_id"), null, null, "_id ASC") { out += it.getLong(0) }
        return out.toLongArray()
    }

    /**
     * [limit] stops reading the cursor; it is never put in the SQL. Android 16's
     * call-log provider rejects "LIMIT" in a sort order outright ("Invalid token
     * LIMIT"), and the others are not promised to accept it either.
     */
    private fun <T> query(
        uri: Uri, cols: Array<String>, sel: String?, args: Array<String>?, order: String?,
        limit: Int = Int.MAX_VALUE, row: (Cursor) -> T?,
    ): List<T> {
        val out = ArrayList<T>()
        cr.query(uri, cols, sel, args, order)?.use { c ->
            while (out.size < limit && c.moveToNext()) row(c)?.let(out::add)
        }
        return out
    }

    companion object {
        private val MMS_COLS = arrayOf(
            Telephony.Mms._ID, Telephony.Mms.THREAD_ID, Telephony.Mms.DATE, Telephony.Mms.MESSAGE_BOX,
            Telephony.Mms.MESSAGE_TYPE, Telephony.Mms.READ,
        )

        fun smsIdOf(uri: Uri?): Long? = uri?.let { runCatching { ContentUris.parseId(it) }.getOrNull() }?.takeIf { it > 0 }
    }
}
