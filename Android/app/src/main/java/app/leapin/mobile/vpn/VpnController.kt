package app.leapin.mobile.vpn

import android.content.Context
import android.content.Intent
import android.net.VpnService

/** Starts and stops the DNS tunnel, asking the system for permission first. */
object VpnController {
    /** Null when permission is already granted; otherwise the consent intent. */
    fun prepare(context: Context): Intent? = VpnService.prepare(context)

    fun start(context: Context) {
        val intent = Intent(context, LeapinVpnService::class.java)
            .setAction(LeapinVpnService.ACTION_START)
        context.startForegroundService(intent)
    }

    fun stop(context: Context) {
        val intent = Intent(context, LeapinVpnService::class.java)
            .setAction(LeapinVpnService.ACTION_STOP)
        context.startService(intent)
    }
}
