package app.ito

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * Keeps the bridge alive. The phone lives on a charger in a drawer, so Doze
 * never engages; a foreground service is all it takes, plus a partial wake
 * lock while a Mac is linked so nothing waits on the CPU waking up.
 */
class BridgeService : Service() {
    private val bridge get() = (application as ItoApp).bridge
    private var wake: PowerManager.WakeLock? = null
    private var inCall = false

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "link", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) },
        )
        foreground()
        bridge.service = this
        bridge.start()
        refresh()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = START_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        bridge.service = null
        wake?.takeIf { it.isHeld }?.release()
        super.onDestroy()
    }

    /** Linked-Mac count changed: update the notification and the wake lock. */
    fun refresh() {
        val linked = bridge.linked > 0
        if (linked && wake?.isHeld != true) {
            wake = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ito:link").apply { setReferenceCounted(false); acquire() }
        } else if (!linked) {
            wake?.takeIf { it.isHeld }?.release()
        }
        foreground()
    }

    /** During a Mac call the service also has to be a microphone service, or the downlink capture is refused. */
    fun promoteForCall(on: Boolean) {
        inCall = on
        foreground()
    }

    private fun foreground() {
        var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        if (inCall) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        try {
            startForeground(1, notification(), type)
        } catch (e: Exception) {
            Log.w("ito", "foreground type $type refused", e)
            if (inCall) startForeground(1, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        }
    }

    private fun notification(): Notification {
        val text = when {
            inCall -> "call on your mac"
            bridge.linked == 1 -> "1 mac linked"
            bridge.linked > 1 -> "${bridge.linked} macs linked"
            else -> "waiting for your mac"
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_launcher_fg)
            .setContentTitle("ito")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL = "link"

        fun start(ctx: Context) = ctx.startForegroundService(Intent(ctx, BridgeService::class.java))
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) = BridgeService.start(ctx).let { }
}
