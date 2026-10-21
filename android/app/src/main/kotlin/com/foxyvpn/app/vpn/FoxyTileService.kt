package com.foxyvpn.app.vpn

import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import androidx.core.content.ContextCompat
import com.foxyvpn.app.MainActivity
import com.foxyvpn.app.R

/**
 * The "FoxyVPN" Quick Settings tile.
 *
 *  - Off, tap: connect to the fastest location (the service starts the shared
 *    Dart engine, which pings every location and connects to the quickest).
 *  - Connecting or connected, tap: disconnect (same path as the notification's
 *    Disconnect button).
 *  - Signed out: "Sign in first"; a tap opens the app to sign in. The app is opened as well if the
 *    VPN permission was never granted (the system dialog needs an Activity).
 *
 * It is a passive tile (no ACTIVE_TILE meta-data): the system binds it every time
 * the panel is shown, so [onStartListening] always reads fresh status, even after
 * the process was killed. While the panel is open, status changes are pushed with
 * [refreshIfListening].
 */
class FoxyTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        listening = this
        render()
    }

    override fun onStopListening() {
        if (listening === this) listening = null
        super.onStopListening()
    }

    override fun onDestroy() {
        if (listening === this) listening = null
        super.onDestroy()
    }

    override fun onClick() {
        super.onClick()
        Log.i(TAG, "tile click (phase ${TileStatus.phase})")
        try {
            when {
                !TileStatus.isSignedIn(this) -> openApp(quickConnect = false)
                // Only an Activity can show the system VPN consent dialog. The app opens and
                // connects to the fastest location right after the user said yes.
                VpnService.prepare(this) != null -> openApp(quickConnect = true)
                else -> when (effectivePhase()) {
                    TileStatus.Phase.CONNECTING, TileStatus.Phase.CONNECTED -> FoxyVpnService.requestDisconnect()
                    TileStatus.Phase.DISCONNECTING -> Unit
                    TileStatus.Phase.OFF -> quickConnect()
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "tile click failed", t)
        }
        render()
    }

    private fun quickConnect() {
        // Optimistic: a second tap before Dart has reported anything disconnects.
        TileStatus.beginQuickConnect()
        try {
            // A tap on a tile is a user interaction, which Android allows to start a
            // foreground service from the background (also with the specialUse type).
            ContextCompat.startForegroundService(
                this,
                Intent(this, FoxyVpnService::class.java).setAction(FoxyVpnService.ACTION_QUICK_CONNECT),
            )
        } catch (t: Throwable) {
            // E.g. ForegroundServiceStartNotAllowedException: let the app do it.
            Log.w(TAG, "could not start the VPN service from the tile; opening the app", t)
            TileStatus.set(TileStatus.Phase.OFF)
            openApp(quickConnect = true)
        }
    }

    private fun openApp(quickConnect: Boolean) {
        val intent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (quickConnect) intent.putExtra(MainActivity.EXTRA_QUICK_CONNECT, true)
        if (Build.VERSION.SDK_INT >= 34) {
            val pending = PendingIntent.getActivity(
                this,
                REQUEST_OPEN,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            startActivityAndCollapse(pending)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    /** The phase, but "connected" without a running service is not believed. */
    private fun effectivePhase(): TileStatus.Phase {
        val phase = TileStatus.phase
        if (phase == TileStatus.Phase.CONNECTED && FoxyVpnService.instance == null) return TileStatus.Phase.OFF
        return phase
    }

    private fun render() {
        val tile = qsTile ?: return
        val state: Int
        val subtitle: String
        if (!TileStatus.isSignedIn(this)) {
            // Not STATE_UNAVAILABLE: Android drops taps on an unavailable tile (checked on API 36),
            // and a tap is what opens the app to sign in.
            state = Tile.STATE_INACTIVE
            subtitle = getString(R.string.tile_sign_in_first)
        } else {
            val label = TileStatus.label
            when (effectivePhase()) {
                TileStatus.Phase.CONNECTED -> {
                    state = Tile.STATE_ACTIVE
                    subtitle = label ?: getString(R.string.notification_protected)
                }
                // Active as well: the tile reads as "on", and a tap switches it off again.
                TileStatus.Phase.CONNECTING -> {
                    state = Tile.STATE_ACTIVE
                    subtitle = label ?: getString(R.string.notification_connecting)
                }
                TileStatus.Phase.DISCONNECTING -> {
                    state = Tile.STATE_INACTIVE
                    subtitle = getString(R.string.tile_disconnecting)
                }
                TileStatus.Phase.OFF -> {
                    state = Tile.STATE_INACTIVE
                    subtitle = getString(R.string.tile_tap_for_fastest)
                }
            }
        }
        tile.state = state
        tile.label = getString(R.string.app_name)
        if (Build.VERSION.SDK_INT >= 29) tile.subtitle = subtitle
        if (Build.VERSION.SDK_INT >= 30) tile.stateDescription = subtitle
        tile.updateTile()
    }

    companion object {
        private const val TAG = "FoxyTile"
        private const val REQUEST_OPEN = 20
        private val main = Handler(Looper.getMainLooper())

        @Volatile
        private var listening: FoxyTileService? = null

        /** Redraws the tile if the panel is open (any thread); otherwise the next bind reads the status. */
        fun refreshIfListening() {
            if (listening == null) return
            main.post {
                try {
                    listening?.render()
                } catch (t: Throwable) {
                    Log.w(TAG, "could not update the tile", t)
                }
            }
        }
    }
}
