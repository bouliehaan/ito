package app.ito

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.LinearLayout
import android.widget.ScrollView
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Status, pairing, permissions. Everything else happens on the Mac. */
class MainActivity : Activity() {
    private val bridge get() = (application as ItoApp).bridge
    private lateinit var body: LinearLayout
    private val main = Handler(Looper.getMainLooper())
    private val onChange: () -> Unit = { main.post(::render) }
    private var pairingOpenedAt = 0L
    private val tick = object : Runnable {
        override fun run() {
            render()
            if (bridge.link.pairingOpen) main.postDelayed(this, 1000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val scroll = ScrollView(this).apply {
            setBackgroundColor(Ui.BG)
            addView(body, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            setOnApplyWindowInsetsListener { v, insets ->
                val bars = insets.getInsets(WindowInsets.Type.systemBars())
                val pad = Ui.dp(this@MainActivity, 24f)
                body.setPadding(pad, bars.top + pad, pad, bars.bottom + pad)
                insets
            }
        }
        setContentView(scroll)
        BridgeService.start(this)
    }

    override fun onResume() {
        super.onResume()
        bridge.listeners += onChange
        render()
    }

    override fun onPause() {
        bridge.listeners -= onChange
        main.removeCallbacks(tick)
        super.onPause()
    }

    private fun render() {
        val ctx = this
        body.removeAllViews()

        body.addView(Ui.text(ctx, "ito", 46f, isBold = true))
        body.addView(Ui.text(ctx, "phone bridge · ${packageManager.getPackageInfo(packageName, 0).versionName}", 14f, Ui.MUTED))

        // status
        body.addView(Ui.section(ctx, "status"))
        val st = bridge.status()
        body.addView(Ui.row(ctx, "link", when (bridge.linked) {
            0 -> "listening · :6969"
            1 -> "1 mac linked"
            else -> "${bridge.linked} macs linked"
        }))
        body.addView(Ui.row(ctx, "wi-fi calling", bridge.ims, if (bridge.ims == "wifi") Ui.TEXT else Ui.DIM))
        body.addView(Ui.row(ctx, "calls", when {
            bridge.calls.fullControl -> "full control"
            else -> "ringing + decline only"
        }, if (bridge.calls.fullControl) Ui.TEXT else Ui.DIM))
        val audio = bridge.calls.audio.interceptable()
        body.addView(Ui.row(ctx, "call audio", when (audio) {
            true -> "over the link"
            false -> "not supported by this rom"
            null -> "needs the system install"
        }, if (audio == true) Ui.TEXT else Ui.DIM))
        body.addView(Ui.row(ctx, "battery", "${st.optInt("batt")}%" + if (st.optBoolean("plugged")) " · on power" else " · NOT on power",
            if (st.optBoolean("plugged")) Ui.TEXT else Ui.DANGER))

        // pairing
        body.addView(Ui.section(ctx, "pairing"))
        val code = bridge.pairingCode
        when {
            code != null -> {
                val card = Ui.card(ctx)
                card.addView(Ui.label(ctx, "does your mac show"))
                card.addView(Ui.text(ctx, code.substring(0, 3) + " " + code.substring(3), 40f, isBold = true).apply {
                    letterSpacing = 0.08f
                    setPadding(0, Ui.dp(ctx, 8f), 0, Ui.dp(ctx, 4f))
                })
                card.addView(Ui.text(ctx, bridge.pairingMac ?: "", 14f, Ui.DIM))
                val buttons = LinearLayout(ctx).apply { setPadding(0, Ui.dp(ctx, 18f), 0, 0) }
                buttons.addView(Ui.button(ctx, "it matches", primary = true) { bridge.link.confirmPairing(true) })
                buttons.addView(spacer())
                buttons.addView(Ui.button(ctx, "no", danger = true) { bridge.link.confirmPairing(false) })
                card.addView(buttons)
                body.addView(card)
            }
            bridge.link.pairingOpen -> {
                val left = ((pairingOpenedAt + PAIR_MS - System.currentTimeMillis()) / 1000).coerceAtLeast(0)
                body.addView(Ui.text(ctx, "waiting for a mac… %d:%02d".format(left / 60, left % 60), 16f, Ui.DIM))
                body.addView(Ui.text(ctx, "on the mac: ito → pair a phone", 14f, Ui.MUTED).apply { setPadding(0, Ui.dp(ctx, 4f), 0, Ui.dp(ctx, 14f)) })
                body.addView(Ui.button(ctx, "cancel") { bridge.link.closePairing(); render() }.wrap())
            }
            else -> body.addView(Ui.button(ctx, "pair a mac", primary = true) {
                pairingOpenedAt = System.currentTimeMillis()
                bridge.link.openPairing(PAIR_MS)
                main.post(tick)
            }.wrap())
        }

        // macs
        val peers = bridge.keys.peers()
        if (peers.isNotEmpty()) {
            body.addView(Ui.section(ctx, "macs"))
            val fmt = SimpleDateFormat("MMM d", Locale.US)
            peers.forEach { p ->
                val row = LinearLayout(ctx).apply { setPadding(0, Ui.dp(ctx, 6f), 0, Ui.dp(ctx, 6f)) }
                val col = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
                col.addView(Ui.text(ctx, p.name, 16f))
                col.addView(Ui.text(ctx, "paired " + fmt.format(Date(p.added)).lowercase(), 13f, Ui.MUTED))
                row.addView(col, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                row.addView(Ui.button(ctx, "unpair", danger = true) { bridge.keys.unpin(p.key); render() })
                body.addView(row)
            }
        }

        // permissions
        val missing = PERMISSIONS.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) {
            body.addView(Ui.section(ctx, "permissions"))
            body.addView(Ui.text(ctx, missing.joinToString("\n") { it.substringAfterLast('.').lowercase().replace('_', ' ') }, 14f, Ui.DIM))
            body.addView(spacer(12f))
            body.addView(Ui.button(ctx, "grant", primary = true) { requestPermissions(missing.toTypedArray(), 1) }.wrap())
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        bridge.calls.startLegacy()
        render()
    }

    private fun spacer(dp: Float = 10f) = android.view.View(this).apply {
        layoutParams = LinearLayout.LayoutParams(Ui.dp(this@MainActivity, dp), Ui.dp(this@MainActivity, dp))
    }

    private fun android.view.View.wrap() = apply {
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
    }

    companion object {
        private const val PAIR_MS = 120_000L
        private val PERMISSIONS = listOf(
            Manifest.permission.READ_SMS, Manifest.permission.RECEIVE_SMS, Manifest.permission.SEND_SMS,
            Manifest.permission.RECEIVE_MMS, Manifest.permission.READ_CONTACTS, Manifest.permission.READ_CALL_LOG,
            Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_PHONE_NUMBERS, Manifest.permission.CALL_PHONE,
            Manifest.permission.ANSWER_PHONE_CALLS, Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS,
        )
    }
}
