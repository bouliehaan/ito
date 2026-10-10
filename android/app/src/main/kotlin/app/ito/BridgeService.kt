package app.ito

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * Keeps the bridge alive. The phone might be on a charger in a drawer or in a
 * pocket; ito can't assume either. A foreground service, an exemption from
 * Doze (the Magisk module grants it), and a partial wake lock only while a Mac
 * is linked AND the phone is charging: free on power, and on battery the link's
 * own traffic wakes the phone when it needs to.
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
        registerReceiver(power, IntentFilter().apply {
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
        })
        refresh()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_USE_PHONE) bridge.calls.releaseToPhone()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private val power = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) = refresh()
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(power) }
        bridge.service = null
        wake?.takeIf { it.isHeld }?.release()
        super.onDestroy()
    }

    /** Linked Macs or power changed: update the notification and the wake lock. */
    fun refresh() {
        val plugged = (registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
        val hold = bridge.linked > 0 && plugged
        if (hold && wake?.isHeld != true) {
            wake = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ito:link").apply { setReferenceCounted(false); acquire() }
        } else if (!hold) {
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
        val b = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_ito)
            .setContentTitle("ito")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
        if (inCall) {
            // Picking up the phone always works: one tap takes the call off the Mac.
            val use = PendingIntent.getService(this, 1, Intent(this, BridgeService::class.java).setAction(ACTION_USE_PHONE),
                PendingIntent.FLAG_IMMUTABLE)
            b.addAction(Notification.Action.Builder(null, "use phone", use).build())
        }
        return b.build()
    }

    companion object {
        private const val CHANNEL = "link"
        private const val ACTION_USE_PHONE = "app.ito.USE_PHONE"

        fun start(ctx: Context) = ctx.startForegroundService(Intent(ctx, BridgeService::class.java))
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) = BridgeService.start(ctx).let { }
}
