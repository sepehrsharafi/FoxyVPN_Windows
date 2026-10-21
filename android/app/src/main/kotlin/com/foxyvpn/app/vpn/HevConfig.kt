package com.foxyvpn.app.vpn

import android.content.Context
import java.io.File

/**
 * The configuration file for hev-socks5-tunnel (YAML).
 *
 * Choices (see lib/platform/android_tun.dart and docs/DESIGN.md "Android"):
 *  - UDP goes out as SOCKS5 UDP ASSOCIATE to our own server. That server answers
 *    port 53 itself through DNS-over-HTTPS and relays everything else as
 *    CONNECT-UDP, exactly like on Windows. So the VPN's DNS server
 *    ([DNS_SERVER], only an address inside the tunnel subnet) needs no special
 *    handling here.
 *  - hev's "mapdns" (fake IPs for domain names) is OFF on purpose: our SOCKS
 *    server already resolves names by DoH, and the Windows build works the same
 *    way, so both platforms behave alike.
 *  - The addresses are the tunnel's own (198.18.0.0/15 and a private /64), the
 *    same as the Windows adapter.
 */
object HevConfig {
    const val FILE_NAME = "hev-socks5-tunnel.yaml"

    /** 198.18.0.0/15 is the benchmarking range: never used on a real network. */
    const val TUN_ADDRESS_V4 = "198.18.0.1"
    const val TUN_PREFIX_V4 = 15
    const val TUN_ADDRESS_V6 = "fd66:6f78:7976::1"
    const val TUN_PREFIX_V6 = 64

    /** Inside the tunnel subnet, so queries to it go through the TUN into our SOCKS UDP path. */
    const val DNS_SERVER = "198.18.0.2"

    const val MTU = 1500

    fun write(context: Context, socksPort: Int): String {
        val yaml = """
            tunnel:
              mtu: $MTU
              ipv4: '$TUN_ADDRESS_V4'
              ipv6: '$TUN_ADDRESS_V6'
              icmp: 'reply'
            socks5:
              port: $socksPort
              address: '127.0.0.1'
              udp: 'udp'
            misc:
              task-stack-size: 86016
              connect-timeout: 20000
              tcp-read-write-timeout: 300000
              udp-read-write-timeout: 60000
              tcp-buffer-size: 65536
              udp-recv-buffer-size: 524288
              udp-copy-buffer-nums: 16
              max-session-count: 0
              limit-nofile: 32768
              log-level: 'warn'
        """.trimIndent() + "\n"
        val file = File(context.filesDir, FILE_NAME)
        file.writeText(yaml)
        return file.absolutePath
    }
}
