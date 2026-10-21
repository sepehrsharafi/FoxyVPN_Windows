package com.foxyvpn.app.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.foxyvpn.app.Bridge
import com.foxyvpn.app.FoxyEngine
import com.foxyvpn.app.MainActivity
import com.foxyvpn.app.R
import java.net.InetAddress
import java.util.Locale
import java.util.concurrent.Executors

/**
 * The Android half of the tunnel. All it holds is the TUN interface and the
 * native hev-socks5-tunnel that moves its packets to the local SOCKS5 server
 * (Dart, 127.0.0.1:<port>, started by the app before this service). Everything
 * else (sign-in, the Mozilla upstream, DNS-over-HTTPS) is Dart code in the shared
 * engine ([FoxyEngine]); this service keeps the process, and so the engine,
 * alive as a foreground service.
 *
 * Loops are avoided without protect(): the app's own package is a disallowed
 * application of this VPN, so its sockets (the upstream connection to Mozilla,
 * the control-plane API, pings) never enter the tunnel.
 *
 * Always-on VPN / "Block connections without VPN": the manifest declares the
 * android.net.VpnService action, so the system lists FoxyVPN under Settings >
 * VPN and starts this service with that action. The service then asks Dart to
 * connect (autoStart); Dart owns the account, the location and the session.
 */
class FoxyVpnService : VpnService() {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    private var tun: ParcelFileDescriptor? = null
    private var hevRunning = false
    private var label = "Connected"
    private var generation = 0
    private var foregroundActive = false
    private var autoStartTimeout: Runnable? = null
    private var disconnectWatchdog: Runnable? = null
    private var hevWatch: Runnable? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createChannel()
        val screen = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        ContextCompat.registerReceiver(this, screenReceiver, screen, ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    override fun onDestroy() {
        stopTicker()
        runCatching { unregisterReceiver(screenReceiver) }
        cancelTimeouts()
        // The process may be going away: never leave the interface or hev behind.
        // (Normal stops go through finishTunnel(), which clears the flag itself;
        // clearing it here would race with a quick restart.)
        val unexpected = hevRunning || tun != null
        teardownTunnel()
        if (unexpected) markStopped()
        instance = null
        worker.shutdown()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startTunnel(
                intent.getIntExtra(EXTRA_SOCKS_PORT, 0),
                intent.getStringExtra(EXTRA_LABEL) ?: "Protected",
            )
            ACTION_DISCONNECT -> onDisconnectPressed()
            ACTION_QUICK_CONNECT -> onQuickConnect()
            else -> onSystemStart() // SERVICE_INTERFACE (Always-on VPN) or a restart by the system
        }
        return START_NOT_STICKY
    }

    /** Another VPN took over, or the user revoked the permission. */
    override fun onRevoke() {
        Log.i(TAG, "VPN permission revoked")
        val gen = generation
        finishTunnel(emit = mapOf("type" to "revoked", "gen" to gen))
        super.onRevoke()
    }

    // ---------------------------------------------------------------------------
    // Start
    // ---------------------------------------------------------------------------

    private fun startTunnel(socksPort: Int, newLabel: String) {
        // Must come first: the service was started with startForegroundService().
        label = newLabel
        enterForeground(null)
        cancelTimeouts()
        if (socksPort <= 0) {
            failStart("The local proxy port is missing.")
            return
        }
        // A tunnel from before (a reconnect that skipped stop()) is replaced without
        // a gap in which traffic would leave outside the VPN: the new interface is
        // established FIRST (Android swaps the routes to it at that moment, and its
        // packets wait in the descriptor), then the old hev is stopped (hev is one
        // per process, so it cannot run twice), hev is started on the new
        // descriptor, and only then is the old descriptor closed.
        val previousTun = tun
        val previousHev = hevRunning
        try {
            val fd = buildTun() ?: throw IllegalStateException(
                "Android did not create the VPN interface. The VPN permission may have been removed.",
            )
            if (previousHev) {
                hevRunning = false
                HevSocks5Tunnel.stop()
            }
            tun = fd
            val config = HevConfig.write(this, socksPort)
            if (!HevSocks5Tunnel.start(config, fd.fd)) {
                throw IllegalStateException("The native tunnel could not be started.")
            }
            hevRunning = true
            if (previousHev) {
                lastUp = 0 // the new hev counts from zero; the totals carry on
                lastDown = 0
            } else {
                resetTraffic()
            }
            refreshNotification()
            syncTicker()
            generation++
            closeQuietly(previousTun)
            Log.i(TAG, "tunnel up (generation $generation, socks 127.0.0.1:$socksPort)")
            Bridge.finishStart(generation, null)
            Bridge.emit(mapOf("type" to "started", "gen" to generation))
            watchHev()
        } catch (t: Throwable) {
            Log.w(TAG, "could not start the tunnel", t)
            teardownTunnel()
            closeQuietly(previousTun)
            failStart(t.message ?: "The VPN could not be started.")
        }
    }

    private fun closeQuietly(fd: ParcelFileDescriptor?) {
        try {
            fd?.close()
        } catch (_: Throwable) {
        }
    }

    // ---------------------------------------------------------------------------
    // Watching hev
    // ---------------------------------------------------------------------------

    /**
     * HevSocks5Tunnel.start() is true as soon as the native thread exists, but hev
     * can quit a moment later (a config or descriptor error), and then everything
     * routed into the TUN would go nowhere. So hev is checked shortly after the
     * start, and then every few seconds while connected.
     */
    private fun watchHev() {
        val gen = generation
        val watch = object : Runnable {
            private var first = true

            override fun run() {
                if (gen != generation || !hevRunning) return
                if (!HevSocks5Tunnel.isRunning()) {
                    val message = if (first) {
                        "The VPN tunnel engine quit right after it started. Please try connecting again."
                    } else {
                        "The VPN tunnel engine stopped unexpectedly. Please connect again."
                    }
                    Log.w(TAG, "hev is not running (generation $gen): $message")
                    onHevDied(message)
                    return
                }
                first = false
                main.postDelayed(this, HEV_WATCH_MS)
            }
        }
        hevWatch = watch
        main.postDelayed(watch, HEV_STARTUP_CHECK_MS)
    }

    /** hev ended on its own: close the interface (no black hole), tell Dart, end the service. */
    private fun onHevDied(message: String) {
        finishTunnel(emit = mapOf("type" to "error", "gen" to generation, "message" to message))
    }

    private fun failStart(message: String) {
        markStopped()
        Bridge.finishStart(generation, message)
        leaveForeground()
        stopSelf()
    }

    /** Android's Builder for the TUN interface: addresses, routes, DNS, excluded apps. */
    private fun buildTun(): ParcelFileDescriptor? {
        val builder = Builder()
            .setSession("FoxyVPN")
            .setMtu(HevConfig.MTU)
            .addAddress(HevConfig.TUN_ADDRESS_V4, HevConfig.TUN_PREFIX_V4)
            .addRoute("0.0.0.0", 0)
            .addDnsServer(HevConfig.DNS_SERVER)

        // IPv6 is tunnelled for real, like on Windows, so nothing leaks around it.
        try {
            builder.addAddress(HevConfig.TUN_ADDRESS_V6, HevConfig.TUN_PREFIX_V6)
            builder.addRoute("::", 0)
        } catch (t: Throwable) {
            Log.w(TAG, "IPv6 is not available for the tunnel", t)
        }

        if (Build.VERSION.SDK_INT >= 29) builder.setMetered(false)

        // Local networks stay off the tunnel (Mozilla's server refuses private
        // destinations anyway): printers, casting, hotspot clients keep working.
        // Below Android 13 there is no excludeRoute(): everything goes to the tunnel.
        if (Build.VERSION.SDK_INT >= 33) {
            for ((address, length) in EXCLUDED_ROUTES) {
                try {
                    builder.excludeRoute(IpPrefix(InetAddress.getByName(address), length))
                } catch (t: Throwable) {
                    Log.w(TAG, "could not exclude $address/$length", t)
                }
            }
        }

        // The app's own sockets (upstream to Mozilla, control plane, pings) go out
        // directly. This is what prevents a loop, so failing here is fatal.
        builder.addDisallowedApplication(packageName)
        return builder.establish()
    }

    // ---------------------------------------------------------------------------
    // Always-on VPN
    // ---------------------------------------------------------------------------

    private fun onSystemStart() {
        if (hevRunning) return
        Log.i(TAG, "started by the system (Always-on VPN)")
        enterForeground(null)
        FoxyEngine.ensure(applicationContext) // Dart must be running even without an Activity
        markStarting()
        Bridge.requestAutoStart()
        armStartTimeout("always-on")
    }

    /** Gives up (and ends the service) if no tunnel came of a start that Dart was asked to make. */
    private fun armStartTimeout(what: String) {
        cancelTimeouts()
        val timeout = Runnable {
            if (!hevRunning) {
                Log.w(TAG, "no connection came of the $what start; giving up")
                markStopped()
                leaveForeground()
                stopSelf()
            }
        }
        autoStartTimeout = timeout
        main.postDelayed(timeout, AUTO_START_TIMEOUT_MS)
    }

    // ---------------------------------------------------------------------------
    // Quick Settings tile
    // ---------------------------------------------------------------------------

    /**
     * The tile asked for the fastest location. Started with startForegroundService(),
     * so it must call startForeground() first; then the shared engine is made sure of
     * (no Activity needed once the VPN permission is granted) and Dart is asked to
     * ping, pick and connect. Dart ends the service again if nothing comes of it.
     */
    private fun onQuickConnect() {
        enterForeground(if (hevRunning) label else null)
        if (hevRunning) return // already up (a second tap racing the first): nothing to do
        Log.i(TAG, "quick connect from the tile")
        FoxyEngine.ensure(applicationContext)
        markStarting()
        Bridge.requestQuickConnect()
        armStartTimeout("quick connect")
    }

    // ---------------------------------------------------------------------------
    // Stop
    // ---------------------------------------------------------------------------

    /** The "Disconnect" action of the notification. Dart owns the session, so it is asked to disconnect. */
    fun onDisconnectPressed() {
        if (!hevRunning && !keepEngineAlive) {
            leaveForeground()
            stopSelf()
            return
        }
        if (Bridge.hasListener()) {
            Bridge.emit(mapOf("type" to "disconnectRequested", "gen" to generation))
            // If Dart does not answer, do it ourselves.
            val watchdog = Runnable {
                if (hevRunning || keepEngineAlive) {
                    Log.w(TAG, "Dart did not disconnect in time; stopping the tunnel")
                    finishTunnel(emit = mapOf("type" to "stopped", "gen" to generation, "reason" to "notification"))
                }
            }
            disconnectWatchdog?.let { main.removeCallbacks(it) }
            disconnectWatchdog = watchdog
            main.postDelayed(watchdog, DISCONNECT_WATCHDOG_MS)
        } else {
            finishTunnel(emit = mapOf("type" to "stopped", "gen" to generation, "reason" to "notification"))
        }
    }

    /** Dart asked to stop (disconnect, or a tunnel that failed after it started). */
    fun stopFromApp(done: () -> Unit) {
        finishTunnel(emit = null, done = done)
    }

    /**
     * Tears the tunnel down on a worker thread (hev's stop joins its native
     * thread), then leaves the foreground and ends the service on the main thread.
     */
    private fun finishTunnel(emit: Map<String, Any?>?, done: (() -> Unit)? = null) {
        cancelTimeouts()
        val wasRunning = hevRunning
        hevRunning = false
        val fd = tun
        tun = null
        val run = Runnable {
            if (wasRunning) {
                try {
                    HevSocks5Tunnel.stop()
                } catch (t: Throwable) {
                    Log.w(TAG, "stopping hev failed", t)
                }
            }
            try {
                fd?.close()
            } catch (_: Throwable) {
            }
            main.post {
                markStopped()
                leaveForeground()
                stopSelf()
                if (emit != null) Bridge.emit(emit)
                done?.invoke()
            }
        }
        try {
            worker.execute(run)
        } catch (_: Throwable) {
            run.run() // the executor is already shut down (service destroyed)
        }
    }

    /** Synchronous variant for onDestroy. */
    private fun teardownTunnel() {
        val wasRunning = hevRunning
        hevRunning = false
        if (wasRunning) {
            try {
                HevSocks5Tunnel.stop()
            } catch (_: Throwable) {
            }
        }
        try {
            tun?.close()
        } catch (_: Throwable) {
        }
        tun = null
    }

    private fun cancelTimeouts() {
        autoStartTimeout?.let { main.removeCallbacks(it) }
        autoStartTimeout = null
        disconnectWatchdog?.let { main.removeCallbacks(it) }
        disconnectWatchdog = null
        hevWatch?.let { main.removeCallbacks(it) }
        hevWatch = null
    }

    // ---------------------------------------------------------------------------
    // Notification (foreground service)
    // ---------------------------------------------------------------------------

    /** The location ("Austria"), or "Reconnecting…"; set by Dart. */
    fun setLabel(newLabel: String) {
        if (newLabel.isEmpty() || newLabel == label) return
        label = newLabel
        refreshNotification()
    }

    private fun refreshNotification() {
        if (!foregroundActive) return
        getSystemService(NotificationManager::class.java)
            ?.let { runCatching { it.notify(NOTIFICATION_ID, buildNotification(if (hevRunning) label else null)) } }
    }

    private fun createChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.notification_channel_name),
            NotificationManager.IMPORTANCE_LOW, // no sound, no pop-up
        ).apply {
            description = getString(R.string.notification_channel_description)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    // Built once; each refresh only swaps the two lines of text.
    private val notificationBuilder: NotificationCompat.Builder by lazy {
        val open = PendingIntent.getActivity(
            this,
            REQUEST_OPEN,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val disconnect = PendingIntent.getService(
            this,
            REQUEST_DISCONNECT,
            Intent(this, FoxyVpnService::class.java).setAction(ACTION_DISCONNECT),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_foxy)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setLocalOnly(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .addAction(0, getString(R.string.notification_disconnect), disconnect)
    }

    /**
     * Collapsed, it already says everything (Android shows "FoxyVPN" in the
     * header, so the app name is not repeated):
     *
     *     Austria
     *     ↓ 1.2 MB/s   ↑ 84 KB/s   ·   312 MB
     *
     * [location] null = still connecting: just "Connecting…".
     */
    private fun buildNotification(location: String?): Notification {
        val b = notificationBuilder
        if (location == null) {
            b.setContentTitle(getString(R.string.notification_connecting)).setContentText(null)
        } else {
            b.setContentTitle(location).setContentText(
                "↓ ${formatBytes(downRate.toLong())}/s   ↑ ${formatBytes(upRate.toLong())}/s   ·   " +
                    formatBytes(upTotal + downTotal),
            )
        }
        return b.build()
    }

    private fun enterForeground(location: String?) {
        val notification = buildNotification(location)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        foregroundActive = true
        syncTicker()
    }

    private fun leaveForeground() {
        stopTicker()
        if (!foregroundActive) return
        foregroundActive = false
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Throwable) {
        }
    }

    // ---------------------------------------------------------------------------
    // Live traffic, read from hev's own counters once a second. Only while the
    // screen is on: nobody can see the notification otherwise, and the phone
    // stays asleep.
    // ---------------------------------------------------------------------------

    private var upTotal = 0L
    private var downTotal = 0L
    private var lastUp = 0L
    private var lastDown = 0L
    private var upRate = 0.0
    private var downRate = 0.0
    private var lastSampleAt = 0L // 0 = the next sample only sets the baseline for the rates
    private var ticking = false

    private val ticker = object : Runnable {
        override fun run() {
            sampleTraffic()
            refreshNotification()
            main.postDelayed(this, 1000)
        }
    }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = syncTicker()
    }

    /** A new connection (not a reconnect inside one) starts the counts from zero. */
    private fun resetTraffic() {
        upTotal = 0
        downTotal = 0
        lastUp = 0
        lastDown = 0
        upRate = 0.0
        downRate = 0.0
        lastSampleAt = 0
    }

    private fun sampleTraffic() {
        if (!hevRunning) return
        // tx = read from the interface (upload), rx = written to it (download).
        // hev starts from zero after a restart (reconnect), hence the "else".
        val s = HevSocks5Tunnel.stats()
        val up = s.getOrElse(1) { 0L }
        val down = s.getOrElse(3) { 0L }
        val dUp = if (up >= lastUp) up - lastUp else up
        val dDown = if (down >= lastDown) down - lastDown else down
        lastUp = up
        lastDown = down
        upTotal += dUp
        downTotal += dDown
        val now = SystemClock.elapsedRealtime()
        if (lastSampleAt != 0L) {
            val seconds = ((now - lastSampleAt).coerceAtLeast(1)) / 1000.0
            upRate = 0.5 * upRate + 0.5 * (dUp / seconds)
            downRate = 0.5 * downRate + 0.5 * (dDown / seconds)
        }
        lastSampleAt = now
    }

    private fun syncTicker() {
        val interactive = getSystemService(PowerManager::class.java)?.isInteractive ?: true
        if (foregroundActive && hevRunning && interactive) {
            if (ticking) return
            ticking = true
            // Bytes moved while the screen was off still count; the speed starts fresh.
            sampleTraffic()
            upRate = 0.0
            downRate = 0.0
            main.post(ticker)
        } else {
            stopTicker()
            lastSampleAt = 0
        }
    }

    private fun stopTicker() {
        ticking = false
        main.removeCallbacks(ticker)
    }

    private fun formatBytes(bytes: Long): String {
        val units = arrayOf("B", "KB", "MB", "GB", "TB")
        var value = bytes.coerceAtLeast(0).toDouble()
        var unit = 0
        while (value >= 1024 && unit < units.size - 1) {
            value /= 1024
            unit++
        }
        return if (unit == 0) "${value.toLong()} ${units[unit]}" else String.format(Locale.US, "%.1f %s", value, units[unit])
    }


    companion object {
        private const val TAG = "FoxyVpnService"
        const val ACTION_START = "com.foxyvpn.app.action.START"
        const val ACTION_DISCONNECT = "com.foxyvpn.app.action.DISCONNECT"
        const val ACTION_QUICK_CONNECT = "com.foxyvpn.app.QUICK_CONNECT_FASTEST"
        const val EXTRA_SOCKS_PORT = "socksPort"
        const val EXTRA_LABEL = "label"

        private const val CHANNEL_ID = "vpn_status"
        private const val NOTIFICATION_ID = 1
        private const val REQUEST_OPEN = 0
        private const val REQUEST_DISCONNECT = 1
        private const val AUTO_START_TIMEOUT_MS = 60_000L
        private const val DISCONNECT_WATCHDOG_MS = 5_000L
        private const val HEV_STARTUP_CHECK_MS = 250L
        private const val HEV_WATCH_MS = 5_000L

        /** Local and private ranges kept off the tunnel (Android 13+), like on Windows. */
        private val EXCLUDED_ROUTES = listOf(
            "10.0.0.0" to 8,
            "172.16.0.0" to 12,
            "192.168.0.0" to 16,
            "100.64.0.0" to 10, // CGNAT, Tailscale
            "169.254.0.0" to 16, // link-local
            "224.0.0.0" to 4, // multicast
            "fc00::" to 7, // unique-local
            "fe80::" to 10, // link-local
            "ff00::" to 8, // multicast
        )

        @Volatile
        var instance: FoxyVpnService? = null
            private set

        @Volatile
        private var requested = false

        /** True while the VPN is being started or is up: the Flutter engine must stay alive. */
        val keepEngineAlive: Boolean get() = requested

        fun markStarting() {
            requested = true
        }

        fun markStopped() {
            requested = false
            TileStatus.set(TileStatus.Phase.OFF)
        }

        /**
         * Disconnect, from the tile: the same path as the notification button when the
         * service is running; otherwise (Dart is still connecting, before the service
         * started) Dart is asked directly. Main thread.
         */
        fun requestDisconnect() {
            val service = instance
            when {
                service != null -> service.onDisconnectPressed()
                Bridge.hasListener() -> Bridge.emit(mapOf("type" to "disconnectRequested"))
                else -> markStopped()
            }
        }
    }
}
