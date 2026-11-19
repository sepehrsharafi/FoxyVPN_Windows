package com.foxyvpn.app.vpn

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.ConnectivityManager
import android.os.Build
import android.os.Process
import android.util.Log
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.InetSocketAddress

/**
 * Which app moved how many bytes through the VPN (Android 10+).
 *
 * hev counts the bytes of every connection (hev-flow-stats.c). A thread here
 * drains those counts and asks Android who owns each connection
 * ([ConnectivityManager.getConnectionOwnerUid], allowed for the active VPN app
 * and only for its own connections). The totals per app wait here until Dart
 * takes them ([take]) and stores them on the device.
 *
 * Nothing here touches the traffic: hev only adds to counters, and if this
 * thread is slow or stops, hev keeps forwarding exactly as before.
 */
object AppUsageMonitor {
    private const val TAG = "AppUsageMonitor"
    private const val UNKNOWN = -1

    /** Records of hev-flow-stats: see put in hev_flow_stats_drain. */
    private const val R_SEQ = 0
    private const val R_FLAGS = 1
    private const val R_SPORT = 2
    private const val R_DPORT = 3
    private const val R_SRC = 4
    private const val R_DST = 6
    private const val R_TX = 8
    private const val R_RX = 9

    /** The thread that should be draining; an older one ends when it sees it was replaced. */
    @Volatile
    private var thread: Thread? = null

    /** hev's drain fills one shared native buffer: one caller at a time. */
    private val drainLock = Any()

    /** uid -> [up, down] since the last [take]. */
    private val pending = HashMap<Int, LongArray>()

    val supported: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    /** Main thread. */
    fun start(context: Context) {
        if (!supported || thread != null) return
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return
        HevSocks5Tunnel.enableFlows(true)
        val t = Thread({ loop(cm) }, "foxy-app-usage").apply {
            isDaemon = true
            priority = Thread.MIN_PRIORITY + 1
        }
        thread = t
        t.start()
    }

    /** Main thread. */
    fun stop() {
        if (thread == null) return
        thread = null
        HevSocks5Tunnel.enableFlows(false) // wakes a waiting drain
    }

    private fun drain(waitMs: Int): LongArray = synchronized(drainLock) { HevSocks5Tunnel.drainFlows(waitMs) }

    /** Takes what was counted since the last call: [[uid, up, down], ...]. */
    fun take(): List<List<Long>> = synchronized(pending) {
        val out = pending.map { (uid, b) -> listOf(uid.toLong(), b[0], b[1]) }
        pending.clear()
        out
    }

    private fun loop(cm: ConnectivityManager) {
        val owners = HashMap<Long, Int>() // flow seq -> uid
        val me = Thread.currentThread()
        try {
            while (thread === me) {
                handle(cm, owners, drain(1000))
            }
            handle(cm, owners, drain(0)) // what the last connections moved
        } catch (t: Throwable) {
            Log.w(TAG, "app usage stopped", t)
        }
    }

    private fun handle(cm: ConnectivityManager, owners: HashMap<Long, Int>, r: LongArray) {
        val n = HevSocks5Tunnel.FLOW_RECORD
        var i = 0
        while (i + n <= r.size) {
            val seq = r[i + R_SEQ]
            val flags = r[i + R_FLAGS]
            val proto = (flags and 0xff).toInt()
            val family = ((flags shr 8) and 0xff).toInt()
            val closed = (flags shr 16) and 1L == 1L
            val isNew = (flags shr 17) and 1L == 1L
            var uid = owners[seq]
            if (uid == null || isNew) {
                uid = if (closed && isNew) UNKNOWN else resolve(cm, proto, family, r, i)
                owners[seq] = uid
            }
            val up = r[i + R_TX]
            val down = r[i + R_RX]
            if (up > 0 || down > 0) {
                synchronized(pending) {
                    val b = pending.getOrPut(uid) { LongArray(2) }
                    b[0] += up
                    b[1] += down
                }
            }
            if (closed) owners.remove(seq)
            i += n
        }
    }

    private fun resolve(cm: ConnectivityManager, proto: Int, family: Int, r: LongArray, i: Int): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return UNKNOWN
        return try {
            val src = InetSocketAddress(address(family, r[i + R_SRC], r[i + R_SRC + 1]), r[i + R_SPORT].toInt())
            val dst = InetSocketAddress(address(family, r[i + R_DST], r[i + R_DST + 1]), r[i + R_DPORT].toInt())
            val uid = cm.getConnectionOwnerUid(proto, src, dst)
            if (uid == Process.INVALID_UID) UNKNOWN else uid
        } catch (_: Throwable) {
            UNKNOWN
        }
    }

    private fun address(family: Int, hi: Long, lo: Long): InetAddress {
        val b = ByteArray(16)
        for (k in 0 until 8) {
            b[k] = (hi shr (56 - 8 * k)).toByte()
            b[8 + k] = (lo shr (56 - 8 * k)).toByte()
        }
        return InetAddress.getByAddress(if (family == 6) b else b.copyOf(4))
    }

    // ---------------------------------------------------------------------------
    // Names and icons, for Dart
    // ---------------------------------------------------------------------------

    /** {id, name}: id is the package name (stable across updates), or a fixed key. */
    fun describe(context: Context, uid: Int): Map<String, String> {
        if (uid == UNKNOWN) return mapOf("id" to "other", "name" to "Other")
        val pm = context.packageManager
        val packages = try {
            pm.getPackagesForUid(uid)
        } catch (_: Throwable) {
            null
        }
        val appId = uid % 100_000
        if (packages.isNullOrEmpty() || appId < Process.FIRST_APPLICATION_UID) {
            val name = when (appId) {
                0, 1000 -> "Android system"
                1051 -> "DNS"
                else -> try {
                    pm.getNameForUid(uid)
                } catch (_: Throwable) {
                    null
                }?.substringBefore(':')?.replaceFirstChar { it.uppercase() } ?: "Android system"
            }
            return mapOf("id" to "system:$name", "name" to name)
        }
        val pkg = packages.sorted().first()
        val label = try {
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
        } catch (_: Throwable) {
            pkg
        }
        return mapOf("id" to pkg, "name" to label)
    }

    /** The app's icon as a PNG of [size] px, or null. */
    fun icon(context: Context, pkg: String, size: Int): ByteArray? = try {
        val drawable = context.packageManager.getApplicationIcon(pkg)
        val px = size.coerceIn(16, 256)
        val bitmap = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, px, px)
        drawable.draw(canvas)
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        bitmap.recycle()
        out.toByteArray()
    } catch (_: PackageManager.NameNotFoundException) {
        null
    } catch (t: Throwable) {
        Log.w(TAG, "icon for $pkg failed", t)
        null
    }
}
