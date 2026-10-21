package com.foxyvpn.app

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * The one Flutter engine of the app, kept in [FlutterEngineCache].
 *
 * Why it exists (the "process model"): the tunnel core (sign-in, the Mozilla
 * HTTP/2 upstream, the local SOCKS5 server, DNS-over-HTTPS) is Dart and runs in
 * this engine's isolate. If the engine died with the Activity, swiping the app
 * from the recent apps list would cut the VPN. So the engine does not belong to
 * the Activity:
 *
 *  - [MainActivity] only attaches its view to this engine (cached engine id), and
 *    never destroys it while the VPN is on or being started.
 *  - The foreground service ([com.foxyvpn.app.vpn.FoxyVpnService]) keeps the
 *    process alive, and with it this engine. The Dart code keeps running with no
 *    window, with the screen off, and after the task was removed.
 *  - When the Activity is finished and the VPN is off, the engine is destroyed
 *    to free memory ([destroyIfIdle]).
 *  - The engine is also created here when Android itself starts the service
 *    (Always-on VPN) before any Activity exists.
 */
object FoxyEngine {
    const val ID = "foxyvpn_main"

    @Synchronized
    fun ensure(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ID)?.let { if (it.dartExecutor.isExecutingDart) return it }

        val app = context.applicationContext
        val engine = FlutterEngine(app)
        GeneratedPluginRegistrant.registerWith(engine)
        Bridge.attach(engine, app)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        cache.put(ID, engine)
        return engine
    }

    /** Called when the last Activity is gone: free the engine unless the VPN needs it. */
    @Synchronized
    fun destroyIfIdle() {
        if (com.foxyvpn.app.vpn.FoxyVpnService.keepEngineAlive) return
        val cache = FlutterEngineCache.getInstance()
        val engine = cache.get(ID) ?: return
        cache.remove(ID)
        Bridge.detach()
        com.foxyvpn.app.vpn.TileStatus.set(com.foxyvpn.app.vpn.TileStatus.Phase.OFF) // Dart is gone
        engine.destroy()
    }
}
