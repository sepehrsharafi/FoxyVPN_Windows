package com.foxyvpn.app

import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.foxyvpn.app.vpn.FoxyTileService
import com.foxyvpn.app.vpn.FoxyVpnService
import com.foxyvpn.app.vpn.TileStatus
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * Dart <-> Kotlin. One MethodChannel (`foxyvpn/vpn`) and one EventChannel
 * (`foxyvpn/vpn/events`), both on the main (platform) thread.
 *
 * Methods (all return a Future in Dart):
 *   prepare()                      -> bool   VPN consent (VpnService.prepare); shows the system dialog if needed
 *   start({socksPort, label})      -> int    starts the foreground service, TUN and hev; returns the tunnel generation
 *   stop()                         -> null   tears everything down (idempotent)
 *   setLabel({label})              -> null   updates the notification text
 *   setTileState({signedIn, phase?, label?}) -> null   what the Quick Settings tile shows (phase: off, connecting, connected, disconnecting)
 *   status()                       -> {active: bool}
 *   filesDir()                     -> String app-private files directory
 *   requestNotifications()         -> bool   POST_NOTIFICATIONS on Android 13+ (asked once)
 *   takeAutoStart()                -> bool   true once if Android started the service (Always-on VPN)
 *   secureGet/securePut/secureDelete({key[, value]})   Android Keystore AES-GCM storage
 *
 * Events (maps with a "type"): started, stopped, revoked, error (+ message),
 * disconnectRequested (the user pressed Disconnect in the notification or tapped the
 * tile while it was on), quickConnect (the tile wants the fastest location) and
 * autoStart (Android asked for the VPN, Always-on). Tunnel events carry "gen".
 */
object Bridge {
    private const val TAG = "FoxyBridge"
    const val METHOD_CHANNEL = "foxyvpn/vpn"
    const val EVENT_CHANNEL = "foxyvpn/vpn/events"

    private val main = Handler(Looper.getMainLooper())

    private var appContext: Context? = null
    private var sink: EventChannel.EventSink? = null
    private var activity: WeakReference<MainActivity>? = null
    private var secure: SecureStore? = null
    private var pendingStart: MethodChannel.Result? = null

    /** Events that happened while Dart was not listening (kept briefly). */
    private val backlog = ArrayDeque<Map<String, Any?>>()

    @Volatile
    private var autoStartPending = false

    fun attach(engine: FlutterEngine, context: Context) {
        appContext = context
        secure = SecureStore(context)
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result) }
        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    sink = events
                    while (backlog.isNotEmpty()) events.success(backlog.removeFirst())
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            },
        )
    }

    fun detach() {
        sink = null
        pendingStart = null
        backlog.clear()
    }

    fun setActivity(a: MainActivity?) {
        activity = a?.let { WeakReference(it) }
    }

    fun clearActivity(a: MainActivity) {
        if (activity?.get() === a) activity = null
    }

    /** Sends an event to Dart (any thread). */
    fun emit(event: Map<String, Any?>) {
        main.post {
            val s = sink
            if (s != null) {
                s.success(event)
            } else {
                backlog.addLast(event)
                while (backlog.size > 16) backlog.removeFirst()
            }
        }
    }

    fun hasListener(): Boolean = sink != null

    /** Android started the service on its own (Always-on VPN): Dart should connect. */
    fun requestAutoStart() {
        autoStartPending = true
        emit(mapOf("type" to "autoStart"))
    }

    /**
     * The Quick Settings tile (or the app opened by it) wants the fastest
     * location: Dart pings, picks and connects. Queued in the backlog if Dart is
     * not listening yet (the engine may have just been started without an Activity).
     */
    fun requestQuickConnect() {
        TileStatus.beginQuickConnect()
        emit(mapOf("type" to "quickConnect"))
    }

    /** Called by the service when the start finished (message null = success). */
    fun finishStart(generation: Int, errorMessage: String?) {
        main.post {
            val result = pendingStart ?: return@post
            pendingStart = null
            if (errorMessage == null) {
                result.success(generation)
            } else {
                result.error("start_failed", errorMessage, null)
            }
        }
    }

    // ---------------------------------------------------------------------------

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val context = appContext ?: return result.error("no_context", "Not attached", null)
        try {
            when (call.method) {
                "filesDir" -> result.success(context.filesDir.absolutePath)
                "prepare" -> prepare(context, result)
                "start" -> start(context, call, result)
                "stop" -> {
                    val service = FoxyVpnService.instance
                    if (service == null) {
                        FoxyVpnService.markStopped()
                        result.success(null)
                    } else {
                        service.stopFromApp { result.success(null) }
                    }
                }
                "setLabel" -> {
                    FoxyVpnService.instance?.setLabel(call.argument<String>("label") ?: "")
                    result.success(null)
                }
                "setTileState" -> {
                    TileStatus.setSignedIn(context, call.argument<Boolean>("signedIn") ?: false)
                    val phase = call.argument<String>("phase")
                    // No phase = only the sign-in changed (the app is still starting).
                    if (phase != null) TileStatus.fromApp(TileStatus.parsePhase(phase), call.argument<String>("label"))
                    else FoxyTileService.refreshIfListening()
                    result.success(null)
                }
                "status" -> result.success(mapOf("active" to FoxyVpnService.keepEngineAlive))
                "requestNotifications" -> requestNotifications(context, result)
                "takeAutoStart" -> {
                    val pending = autoStartPending
                    autoStartPending = false
                    result.success(pending)
                }
                "secureGet" -> result.success(secure!!.get(requireKey(call)))
                "securePut" -> {
                    secure!!.put(requireKey(call), call.argument<String>("value") ?: "")
                    result.success(null)
                }
                "secureDelete" -> {
                    secure!!.delete(requireKey(call))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "${call.method} failed", t)
            result.error("failed", t.message ?: t.javaClass.simpleName, null)
        }
    }

    private fun requireKey(call: MethodCall): String =
        call.argument<String>("key") ?: throw IllegalArgumentException("missing key")

    private fun prepare(context: Context, result: MethodChannel.Result) {
        if (VpnService.prepare(context) == null) {
            result.success(true)
            return
        }
        val a = activity?.get()
        if (a == null) {
            // Consent needs a visible Activity; without one the answer is "not granted".
            result.success(false)
            return
        }
        a.requestVpnConsent { granted -> result.success(granted) }
    }

    private fun start(context: Context, call: MethodCall, result: MethodChannel.Result) {
        val port = call.argument<Int>("socksPort") ?: return result.error("bad_args", "socksPort", null)
        val label = call.argument<String>("label") ?: "Connected"
        if (VpnService.prepare(context) != null) {
            return result.error("not_prepared", "The VPN permission has not been granted.", null)
        }
        if (pendingStart != null) {
            return result.error("busy", "A start is already in progress.", null)
        }
        autoStartPending = false
        pendingStart = result
        FoxyVpnService.markStarting()
        try {
            ContextCompat.startForegroundService(
                context,
                Intent(context, FoxyVpnService::class.java)
                    .setAction(FoxyVpnService.ACTION_START)
                    .putExtra(FoxyVpnService.EXTRA_SOCKS_PORT, port)
                    .putExtra(FoxyVpnService.EXTRA_LABEL, label),
            )
        } catch (t: Throwable) {
            pendingStart = null
            FoxyVpnService.markStopped()
            Log.w(TAG, "could not start the VPN service", t)
            result.error("start_failed", t.message ?: "Android would not start the VPN service.", null)
        }
    }

    private fun requestNotifications(context: Context, result: MethodChannel.Result) {
        if (android.os.Build.VERSION.SDK_INT < 33 || NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            result.success(true)
            return
        }
        val a = activity?.get()
        if (a == null) {
            result.success(false)
            return
        }
        a.requestNotificationPermission { granted -> result.success(granted) }
    }
}
