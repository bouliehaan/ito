package app.ito

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Telephony
import android.telephony.SmsManager
import app.ito.link.Role
import app.ito.link.SendTag
import java.util.UUID

/**
 * Sending. ito is not the default SMS app, so Android itself writes each sent
 * text into the SMS store (creator = app.ito) and hands the row's uri back in
 * the sent-intent's fill-in. That uri is how a group copy gets filed.
 */
class SmsSender(private val ctx: Context) {
    fun send(to: String, body: String, tag: SendTag) {
        val sm = ctx.getSystemService(SmsManager::class.java)
        val parts = sm.divideMessage(body)
        val sent = ArrayList<PendingIntent>(parts.size)
        val delivered = ArrayList<PendingIntent>(parts.size)
        for (i in parts.indices) {
            sent += pending(SentReceiver.ACTION_SENT, to, tag, i, parts.size)
            delivered += pending(SentReceiver.ACTION_DELIVERED, to, tag, i, parts.size)
        }
        if (parts.size == 1) sm.sendTextMessage(to, null, parts[0], sent[0], delivered[0])
        else sm.sendMultipartTextMessage(to, null, parts, sent, delivered)
    }

    private fun pending(action: String, to: String, tag: SendTag, part: Int, count: Int): PendingIntent {
        // A unique data uri keeps PendingIntents from being matched (and reused) across sends.
        val i = Intent(action, Uri.parse("ito://send/" + UUID.randomUUID())).setClass(ctx, SentReceiver::class.java)
            .putExtra("to", to).putExtra("cid", tag.cid).putExtra("group", tag.group)
            .putExtra("gm", tag.gm).putExtra("role", tag.role.name)
            .putExtra("part", part).putExtra("count", count)
        // Mutable on purpose: Android fills in the error code and the stored row's uri.
        return PendingIntent.getBroadcast(ctx, 0, i,
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_ONE_SHOT)
    }
}

class SentReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val bridge = (ctx.applicationContext as ItoApp).bridge
        val tag = SendTag(
            cid = intent.getStringExtra("cid"),
            group = intent.getStringExtra("group"),
            gm = intent.getStringExtra("gm"),
            role = runCatching { Role.valueOf(intent.getStringExtra("role") ?: "") }.getOrDefault(Role.DIRECT),
        )
        val uri = intent.getStringExtra("uri")?.let(Uri::parse)
        when (intent.action) {
            ACTION_SENT -> bridge.onSent(
                tag = tag,
                to = intent.getStringExtra("to") ?: "",
                ok = resultCode == Activity.RESULT_OK,
                error = resultCode,
                smsId = Store.smsIdOf(uri),
                last = intent.getIntExtra("part", 0) == intent.getIntExtra("count", 1) - 1,
            )
            ACTION_DELIVERED -> bridge.onDelivered(Store.smsIdOf(uri))
        }
    }

    companion object {
        const val ACTION_SENT = "app.ito.SENT"
        const val ACTION_DELIVERED = "app.ito.DELIVERED"
    }
}

/**
 * Receiving. The phone's messaging app still gets every text and stores it;
 * ito only needs the moment of arrival to route it into a group (and relay it)
 * before the Mac sees the stored row.
 */
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val msgs = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        if (msgs.isEmpty()) return
        val from = msgs[0].displayOriginatingAddress ?: msgs[0].originatingAddress ?: return
        val body = msgs.joinToString("") { it.displayMessageBody ?: it.messageBody ?: "" }
        val sentAt = msgs[0].timestampMillis
        val app = ctx.applicationContext as ItoApp
        val pending = goAsync()
        app.bridge.io.execute {
            try {
                app.bridge.onInbound(from, body, sentAt)
            } finally {
                pending.finish()
            }
        }
    }
}
