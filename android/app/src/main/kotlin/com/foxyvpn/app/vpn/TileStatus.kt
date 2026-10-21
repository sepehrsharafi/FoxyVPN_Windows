package com.foxyvpn.app.vpn

import android.content.Context
import java.io.File

/**
 * What the Quick Settings tile ([FoxyTileService]) shows, in one place.
 *
 * Dart owns the session, so it reports the phase and the text
 * (`setTileState`, see Bridge.kt); the service reports the end of a tunnel
 * ([FoxyVpnService.markStopped]). The phase only lives in memory: if the process
 * dies the VPN is gone with it, and the tile correctly starts again as "off".
 * "Signed in" is also kept on disk, because the tile can be shown (and tapped)
 * while the app process, and with it Dart, is not running.
 */
object TileStatus {
    enum class Phase { OFF, CONNECTING, CONNECTED, DISCONNECTING }

    private const val PREFS = "foxyvpn"
    private const val KEY_SIGNED_IN = "tile_signed_in"

    @Volatile
    var phase: Phase = Phase.OFF
        private set

    /** The text under "FoxyVPN" while connected / connecting ("Protected . Austria"). Null = default text. */
    @Volatile
    var label: String? = null
        private set

    fun isSignedIn(context: Context): Boolean {
        val app = context.applicationContext
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.contains(KEY_SIGNED_IN)) return prefs.getBoolean(KEY_SIGNED_IN, false)
        // The app has not reported yet (updated, never opened since): the encrypted
        // sign-in file existing is the same answer SecureStore would give.
        return File(app.filesDir, "secure/auth.bin").exists()
    }

    fun setSignedIn(context: Context, signedIn: Boolean) {
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_SIGNED_IN, signedIn).apply()
    }

    /**
     * True from the tap on the tile (or the app opened by it) until the quick
     * connect has become a connection or ended. While it is pending the app may
     * still report "off" (Dart is starting up, or pinging): that must not flip
     * the tile back.
     */
    @Volatile
    private var quickConnectPending = false

    /** Sets the phase and refreshes the tile if it is on screen. Any thread. */
    fun set(phase: Phase, label: String? = null) {
        if (phase == Phase.OFF) quickConnectPending = false
        this.phase = phase
        this.label = if (phase == Phase.OFF) null else label
        FoxyTileService.refreshIfListening()
    }

    /** A quick connect was requested: the tile reads "connecting" until it is over. */
    fun beginQuickConnect() {
        set(Phase.CONNECTING, null)
        quickConnectPending = true
    }

    /** The app's own report (Bridge: setTileState). */
    fun fromApp(phase: Phase, label: String?) {
        if (phase == Phase.OFF && quickConnectPending) return
        if (phase != Phase.OFF) quickConnectPending = false
        set(phase, label)
    }

    fun parsePhase(name: String?): Phase = when (name) {
        "connecting" -> Phase.CONNECTING
        "connected" -> Phase.CONNECTED
        "disconnecting" -> Phase.DISCONNECTING
        else -> Phase.OFF
    }
}
