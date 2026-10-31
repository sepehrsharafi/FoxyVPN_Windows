package com.foxyvpn.app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Hosts the Flutter UI. The engine itself is shared and long-lived ([FoxyEngine]),
 * this Activity only attaches to it; closing the Activity does not stop the VPN.
 *
 * It also owns the two system dialogs that need an Activity, using the
 * Activity Result API: the VPN consent ([VpnService.prepare]) and the Android 13+
 * notification permission.
 */
class MainActivity : FlutterFragmentActivity() {
    private var vpnConsentCallback: ((Boolean) -> Unit)? = null
    private var notificationCallback: ((Boolean) -> Unit)? = null

    private val vpnConsent = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val callback = vpnConsentCallback
        vpnConsentCallback = null
        callback?.invoke(result.resultCode == RESULT_OK)
    }

    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val callback = notificationCallback
        notificationCallback = null
        callback?.invoke(granted)
    }

    // The engine comes from the cache, created before the fragment looks for it.
    override fun getCachedEngineId(): String = FoxyEngine.ID

    override fun onCreate(savedInstanceState: Bundle?) {
        FoxyEngine.ensure(applicationContext)
        Bridge.setActivity(this)
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) handleQuickConnectIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleQuickConnectIntent(intent)
    }

    /**
     * The tile opened the app because the VPN permission is missing: connect once it is granted.
     * Other intents (launcher, long-press on the tile via QS_TILE_PREFERENCES) just show the app.
     */
    private fun handleQuickConnectIntent(intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_QUICK_CONNECT, false) != true) return
        intent.removeExtra(EXTRA_QUICK_CONNECT)
        Bridge.requestQuickConnect()
    }

    // Engine setup is done once in FoxyEngine (also used without an Activity).
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) = Unit

    override fun onDestroy() {
        vpnConsentCallback?.invoke(false)
        vpnConsentCallback = null
        notificationCallback?.invoke(false)
        notificationCallback = null
        Bridge.clearActivity(this)
        super.onDestroy()
        // Swiping the app away finishes the Activity. The engine (and the VPN) stays
        // while the tunnel is up or starting; otherwise it is released.
        if (isFinishing) FoxyEngine.destroyIfIdle()
    }

    /** Shows the system "Connection request" dialog if the permission is not granted yet. */
    fun requestVpnConsent(callback: (Boolean) -> Unit) {
        val intent: Intent? = VpnService.prepare(this)
        if (intent == null) {
            callback(true)
            return
        }
        vpnConsentCallback?.invoke(false)
        vpnConsentCallback = callback
        vpnConsent.launch(intent)
    }

    /** Android 13+: POST_NOTIFICATIONS, asked at most once (the system may not show it again anyway). */
    fun requestNotificationPermission(callback: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT < 33) {
            callback(true)
            return
        }
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getBoolean(KEY_NOTIFICATIONS_ASKED, false)) {
            callback(false)
            return
        }
        prefs.edit().putBoolean(KEY_NOTIFICATIONS_ASKED, true).apply()
        notificationCallback?.invoke(false)
        notificationCallback = callback
        notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    companion object {
        /** Set by the Quick Settings tile when it had to open the app (VPN permission): connect to the fastest location. */
        const val EXTRA_QUICK_CONNECT = "com.foxyvpn.app.extra.QUICK_CONNECT"

        private const val PREFS = "foxyvpn"
        private const val KEY_NOTIFICATIONS_ASKED = "notifications_asked"
    }
}
