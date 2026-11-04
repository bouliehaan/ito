package app.ito.link

import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/*
 * The wall: a secondbrain dashboard on the same Wi-Fi (github.com/bouliehaan/secondbrain).
 *
 * The phone tells it who has texted you and not been answered, so "text from
 * mom" is on the wall while the phone is in a drawer and the Mac is asleep.
 * Who, how many and when: never what the text says. The phone posts the whole
 * list whenever it changes and every ten minutes besides; each post replaces
 * the last, so a text that has been read or answered just isn't in the next one.
 *
 * The wall made a 32-byte key (enable-ito on the wall prints it), the Mac
 * handed it over the link, and every post is signed with it:
 *
 *   POST <wall>/secondbrain/ito
 *   X-Ito-Time: <ms>
 *   X-Ito-Signature: hex HMAC-SHA256(key, "ito-wall/1\n" + time + "\n" + body)
 *
 * Signed, not encrypted: the wall shows these names on a screen and serves
 * its page to the whole LAN, so hiding them on the way there would hide
 * nothing. The signature is what keeps anything else on the network from
 * putting a fake "text from mom" up.
 */

/** Where the wall is and the key it made. */
class WallConfig private constructor(val url: String, val key: ByteArray) {
    fun toJson(): JSONObject = JSONObject().put("url", url).put("key", Wall.b64(key))

    override fun equals(other: Any?) = other is WallConfig && other.url == url && other.key.contentEquals(key)
    override fun hashCode() = url.hashCode()

    companion object {
        /**
         * [url] as enable-ito prints it (http://192.168.1.50:43761), cut to scheme, host and
         * port; [key] as it prints it, 43 characters of base64url. Null when either is not that.
         */
        fun of(url: String, key: String): WallConfig? {
            val u = runCatching { URI(url.trim()) }.getOrNull() ?: return null
            val scheme = u.scheme?.lowercase()
            if (scheme != "http" && scheme != "https") return null
            val host = u.host?.takeIf { it.isNotEmpty() } ?: return null
            val k = key.trim()
            if (!Regex("[A-Za-z0-9_-]{43}").matches(k)) return null
            val bytes = runCatching { Base64.getUrlDecoder().decode(k) }.getOrNull()?.takeIf { it.size == 32 } ?: return null
            val hostPart = if (host.contains(':') && !host.startsWith("[")) "[$host]" else host
            return WallConfig("$scheme://$hostPart" + (if (u.port > 0) ":${u.port}" else ""), bytes)
        }

        fun fromJson(o: JSONObject): WallConfig? = of(o.optString("url"), o.optString("key"))
    }
}

/** One text, as much of it as the wall needs: never the body. */
data class WallText(
    /** The Mac's name for the conversation: "t:<thread id>", or "g:<group id>" when filed in an ito group. */
    val key: String,
    val address: String,
    val incoming: Boolean,
    /** The phone's own read flag: read in the phone's messaging app. */
    val read: Boolean,
    val date: Long,
)

/** What the phone last heard from the wall, for the Mac's settings and the phone's screen. */
data class WallState(val at: Long, val ok: Boolean, val cards: Int?, val error: String?) {
    fun toJson(): JSONObject = JSONObject().put("at", at).put("ok", ok)
        .put("cards", cards ?: JSONObject.NULL).put("err", error ?: JSONObject.NULL)
}

object Wall {
    const val PATH = "/secondbrain/ito"
    const val CONTENT_TYPE = "application/x-ito-wall"
    private const val CONTEXT = "ito-wall/1"

    /** How far back a text can still be news. The wall decides how long each one stays up (two hours); this only bounds the list. */
    const val LOOKBACK_MS = 12 * 3_600_000L
    const val MAX_TEXTS = 20

    fun b64(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    fun sign(key: ByteArray, time: Long, body: ByteArray): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        mac.update("$CONTEXT\n$time\n".toByteArray())
        return mac.doFinal(body).toHex()
    }

    /**
     * The report: one entry per conversation with something unanswered in it.
     *
     * A text is unanswered while it is unread on the phone, newer than what the Mac has
     * shown you ([seen], the Mac's read marks), and newer than anything you have sent
     * into that conversation since: replying from either end is reading it.
     *
     * [name] is the contact's name for a number, [group] an ito group's name by id;
     * either may answer null.
     */
    fun report(
        texts: List<WallText>,
        seen: Map<String, Long>,
        now: Long,
        name: (String) -> String?,
        group: (String) -> String?,
    ): JSONObject {
        val list = JSONArray()
        texts.filter { now - it.date <= LOOKBACK_MS }
            .groupBy { it.key }
            .mapNotNull { (key, rows) ->
                val answered = rows.filter { !it.incoming }.maxOfOrNull { it.date } ?: 0
                val since = maxOf(answered, seen[key] ?: 0)
                val waiting = rows.filter { it.incoming && !it.read && it.date > since }.sortedBy { it.date }
                if (waiting.isEmpty()) null else key to waiting
            }
            .sortedByDescending { (_, waiting) -> waiting.last().date }
            .take(MAX_TEXTS)
            .forEach { (key, waiting) ->
                val newest = waiting.last()
                val who = name(newest.address)?.trim()?.takeIf { it.isNotEmpty() }
                val o = JSONObject()
                    .put("id", sha256("ito-wall/$key".toByteArray()).toHex().take(12))
                    .put("from", who ?: pretty(newest.address))
                    .put("n", waiting.size)
                    .put("at", newest.date)
                    // A saved short code is still a machine: it gets a machine's half hour.
                    .put("person", isPhoneNumber(newest.address))
                if (key.startsWith("g:")) group(key.removePrefix("g:"))?.let { o.put("group", it) }
                list.put(o)
            }
        return JSONObject().put("v", 1).put("texts", list)
    }

    /** A real phone number, not a short code (72975) or a name ("T-Mobile"). */
    fun isPhoneNumber(address: String) = address.count(Char::isDigit) >= 7 && address.none(Char::isLetter)

    /** (555) 123-4567 for a North American number, as the Mac shows it; anything else as it came. */
    fun pretty(address: String): String {
        val d = address.filter(Char::isDigit)
        val ten = if (d.length == 11 && d.startsWith("1")) d.drop(1) else d
        if (ten.length != 10 || address.any(Char::isLetter)) return address.trim()
        return "(${ten.substring(0, 3)}) ${ten.substring(3, 6)}-${ten.substring(6)}"
    }

    /**
     * Post one report and say how it went, in words for the Mac's settings. Blocking:
     * call it off any thread that has other work.
     */
    fun post(config: WallConfig, report: JSONObject, now: Long = System.currentTimeMillis(), timeoutMs: Int = 8000): WallState {
        val body = report.toString().toByteArray()
        val c = try {
            URI(config.url + PATH).toURL().openConnection() as HttpURLConnection
        } catch (e: Exception) {
            return WallState(now, false, null, "bad address: ${e.message}")
        }
        return try {
            c.requestMethod = "POST"
            c.connectTimeout = timeoutMs
            c.readTimeout = timeoutMs
            c.doOutput = true
            c.instanceFollowRedirects = false
            c.useCaches = false
            c.setFixedLengthStreamingMode(body.size)
            c.setRequestProperty("Content-Type", CONTENT_TYPE)
            c.setRequestProperty("X-Ito-Time", now.toString())
            c.setRequestProperty("X-Ito-Signature", sign(config.key, now, body))
            c.outputStream.use { it.write(body) }
            val status = c.responseCode
            val text = (if (status < 400) c.inputStream else c.errorStream)?.use { it.readBytes().decodeToString() } ?: ""
            val answer = runCatching { JSONObject(text) }.getOrNull()
            when {
                status == 200 && answer?.optBoolean("ok") == true -> WallState(now, true, answer.optInt("cards"), null)
                else -> WallState(now, false, null, refusal(status, answer))
            }
        } catch (e: IOException) {
            WallState(now, false, null, "not answering (${e.message ?: e.javaClass.simpleName})")
        } finally {
            c.disconnect()
        }
    }

    private fun refusal(status: Int, answer: JSONObject?): String = when (answer?.optString("error")) {
        "signature" -> "the wall refused the key. run enable-ito on the wall and paste its line again"
        "clock" -> "the phone's clock is ${Math.abs(answer.optLong("skewMs")) / 60_000} min off the wall's"
        "stale" -> "the wall already has a newer report"
        "off" -> "ito is not set up on the wall. run enable-ito there"
        else -> when (status) {
            403 -> "the wall does not let this phone's address in (ipWhitelist in its config.js)"
            404 -> "no ito on that address. is it the wall, and is secondbrain up to date?"
            else -> "the wall answered $status"
        }
    }
}
