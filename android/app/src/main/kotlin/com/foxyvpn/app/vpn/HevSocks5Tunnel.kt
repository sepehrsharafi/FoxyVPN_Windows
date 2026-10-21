package com.foxyvpn.app.vpn

import android.util.Log

/**
 * JNI wrapper around hev-socks5-tunnel (MIT, https://github.com/heiher/hev-socks5-tunnel).
 *
 * The native library registers these four methods for exactly this class name
 * (see android/app/src/main/jni/Android.mk: PKGNAME / CLSNAME), so the class
 * and the method names must not change. Same approach as the original FoxyVPN
 * Android app (https://github.com/vauth/FoxyVPN, MIT).
 *
 * hev reads IP packets from the TUN file descriptor, terminates TCP / UDP in
 * its own user-space stack and forwards every flow to the SOCKS5 server on
 * 127.0.0.1 (our Dart SOCKS server). It never closes the descriptor it is given.
 */
object HevSocks5Tunnel {
    private const val TAG = "HevSocks5Tunnel"

    private external fun TProxyStartService(configPath: String, fd: Int): Boolean
    private external fun TProxyStopService(): Boolean
    private external fun TProxyIsRunning(): Boolean
    private external fun TProxyGetStats(): LongArray

    init {
        System.loadLibrary("hev-socks5-tunnel")
    }

    fun start(configPath: String, tunFd: Int): Boolean =
        try {
            TProxyStartService(configPath, tunFd)
        } catch (t: Throwable) {
            Log.e(TAG, "could not start hev-socks5-tunnel", t)
            false
        }

    /** Blocks until the native worker thread has ended. */
    fun stop(): Boolean =
        try {
            TProxyStopService()
        } catch (t: Throwable) {
            Log.w(TAG, "could not stop hev-socks5-tunnel", t)
            false
        }

    fun isRunning(): Boolean =
        try {
            TProxyIsRunning()
        } catch (t: Throwable) {
            false
        }

    /** tx packets, tx bytes, rx packets, rx bytes. */
    fun stats(): LongArray =
        try {
            TProxyGetStats()
        } catch (t: Throwable) {
            LongArray(4)
        }
}
