package app.ito

import android.app.Application

class ItoApp : Application() {
    lateinit var bridge: Bridge
        private set

    override fun onCreate() {
        super.onCreate()
        bridge = Bridge(this)
        // Started at boot and kept in the foreground, so this is normally a no-op. When the
        // process is woken in the background (an SMS), Android may refuse a fresh start.
        runCatching { BridgeService.start(this) }
    }
}
