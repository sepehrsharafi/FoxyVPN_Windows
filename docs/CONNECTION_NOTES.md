# Connection notes: what we found, what we built, what is left

State as of 2026-11-12 (version 1.0.9). Read this before touching the VPN data path.

## TL;DR

- On Windows and Android the VPN traffic is carried by **foxy-core**, a Go engine in `core/`.
  It uses Go's own HTTP/2 client (`golang.org/x/net/http2`) and a Firefox TLS ClientHello
  (uTLS) to talk to Mozilla's VPN edge (Fastly MASQUE). It also runs the local SOCKS5 server
  that the tunnel (tun2socks on Windows, hev-socks5-tunnel on Android) talks to.
- The **control plane is untouched and must stay that way**: sign-in, the 406 edge
  challenge, the 451 workaround, the Cloudflare Worker relay, pass fetching and renewal, and
  the server list all stay in Dart. The engine never talks to the relay or to Mozilla's APIs.
- macOS still uses the old pure-Dart path, and CI no longer builds macOS on push (manual
  runs only).
- Windows result: no more drops, roughly 2× the speed of the Dart path, and uploads no longer
  freeze downloads. The remaining limits are mostly the user's line and which location is used.

## Do not touch (406/451 fixes)

These files are the control plane. Every change in this work left them byte-identical.
Check with `git diff --stat 51e2c5c -- <files>` before every push.

- `lib/http_util.dart`
- `lib/control_relay.dart`
- `lib/control_h2.dart`
- `lib/edge_challenge.dart`
- `lib/fxa.dart`
- `lib/guardian.dart`
- `lib/firefox_identity.dart`
- `lib/servers.dart`
- `lib/account.dart`
- `relay/`

The Cloudflare Worker relay (`FOXY_RELAY_URL`, `relay/cloudflare/`) only carries control-plane
requests: FxA, Guardian token and pass, and the server list. VPN traffic never goes through it.

## Architecture now

```text
Windows: apps -> Wintun adapter -> tun2socks.exe --proxy socks5://127.0.0.1:<engine socks port>
Android: apps -> VpnService TUN -> hev-socks5-tunnel -> 127.0.0.1:<engine socks port>
                                    |
                               foxy-core (Go, one process per VPN session)
                                 SOCKS5: CONNECT -> HTTP/2 CONNECT stream
                                         UDP ASSOCIATE -> CONNECT-UDP (RFC 9298 capsules)
                                         UDP :53 -> DNS over HTTPS to cloudflare-dns.com,
                                                    carried through the tunnel
                                 one or more HTTP/2 connections (uTLS Firefox hello)
                                    |  pinned edge IPv4 (e.g. 23.235.42.x:2499), /32 bypass route
                               Mozilla VPN edge (Fastly) -> internet
```

- **Dart (`lib/tunnel/vpn_session.dart`):**
  - Fetches the pass and starts the engine through `lib/tunnel/connector.dart` and
    `lib/tunnel/engine.dart` (`EngineUpstream`).
  - Gives it the token on stdin, reads its events from stdout, and uses the engine's
    `socks_port` for the tunnel.
  - Renews the pass on `auth_failed`, and adds the engine's `stats` to the byte counters used
    by the speed display and the quota.
- **Dart `LocalSocksServer` (`lib/tunnel/socks_server.dart`):** still started, but only used
  in three cases:
  - on macOS;
  - when "direct fallback" is enabled (Windows setting);
  - when the engine is missing or fails to start (automatic fallback, which logs
    `foxy-core did not start (...); using the built-in HTTP/2 client`).
- **Old Dart HTTP/2 upstream (`lib/tunnel/upstream.dart` + vendored `third_party/http2`):**
  kept for macOS and as the fallback. It has our patches 1–12 (see
  `third_party/http2/PATCHES.md`).

### Engine process protocol (`core/`, spec details in the code comments)

- **Arguments:** `foxy-core --server <host>:<port> --ip <IPv4> [--socks] [--socks-port N] [--sndbuf N]`.
- **stdin:** JSON lines `{"token":"..."}`. The first line is required before anything connects;
  later lines replace the token for new streams. stdin EOF makes the engine exit at once.
- **stdout events (JSON lines):**
  - `listening`: port, secret, `socks_port`.
  - `connected`: `tls: "tls1.3 h2 firefox|go"`.
  - `error`: the first connection failed.
  - `lost` and `reconnected`.
  - `log`: rate-limited.
  - `stats`: cumulative up/down, at most once a second.
  - `auth_failed`: at most once per 5 s.
- **Line protocol** on the loopback port: one request line `<secret> TCP|UDP <host> <port>`,
  answered with `OK` or `ERR <status> <proxy-status> <msg>`, then raw bytes. The Dart side
  still uses it for its own flows (DoH, exit check, macOS-style dialing).
- **Windows:** `foxy-core.exe` sits next to `foxyvpn.exe`.
- **Android:** `libfoxycore.so` is in `jniLibs/<abi>/` and is executed from
  `applicationInfo.nativeLibraryDir`. That needs `useLegacyPackaging = true` in
  `android/app/build.gradle.kts`. The app's own UID is excluded from the VPN, so the engine's
  sockets bypass the tunnel.

### Probe mode: the "real delay" of the Locations page (`core/probe.go`, `lib/tunnel/location_probe.dart`)

Every location sits behind the same nearby Fastly edge, so a TCP connect time says nothing about
a location (dead exits looked great). The Locations page now shows the time of one real request
through each location's exit, like v2rayN.

- **Arguments:** `foxy-core --probe --ip <edge IPv4> [--concurrency 4] [--timeout 5s]`
  (`--timeout` is per server and includes the TLS dial).
- **stdin:** `{"token":"..."}` then one `{"probe":["host:port", ...]}` line. EOF before both lines: exit.
- **stdout:** per server `{"type":"probe","server":"host:port","ms":123}` or
  `{"type":"probe","server":"...","error":"timeout|auth|<short>"}` (`auth` = 401/403/407 or
  `x-fastly-proxy-auth-failed`), then `{"type":"probe_done"}`, then the process exits.
- **What is measured:** per server a fresh TLS connection (Firefox hello, SNI = that host) to the
  pinned IP, HTTP/2, one `CONNECT cp.cloudflare.com:80` (same request shape as flows), then
  `GET /generate_204`. The time is CONNECT sent -> HTTP status line (204 or 200) received. The TLS
  handshake to the edge is excluded (same for every location). The connection is closed right after.
  At most `--concurrency` servers run at once. The token is never logged.
- **Dart side (`VpnController`):**
  - A round runs at startup (after the account check), when the Locations page opens with delays
    older than 5 min, and on refresh. One round at a time. Results show as they arrive. A failed
    location shows "Unavailable".
  - Recommended on connect uses the cache if it is under 5 min old; otherwise one round, waited for
    at most 8 s (best answer so far), then Mozilla's pick if nothing answered.
  - **Token:** no new control-plane traffic. The probe reuses a pass the app already holds: the one
    from the startup / sign-in account check (`_checkAccount`), the running `VpnSession`'s token
    while connected, or the last session's token after a disconnect. A pass is never fetched for
    the probe.
  - **Edge IP:** connected -> `VpnSession.upstreamAddress` (only the pinned IP has a bypass route).
    Disconnected -> resolved like connect does (`UpstreamSession.resolveIPv4` of the first
    server's host).
  - **Fallback:** no engine (macOS), no usable pass, the probe failing at once, or the edge
    rejecting the pass for every location -> the old TCP ping, and the page says "Connection time
    only". While connected, a TCP-only round is not run (it would go through the tunnel).

## Build and CI

- **Go engine:**
  - Always build with **`-tags http2legacy`**. On Go 1.27+, x/net/http2 otherwise wraps
    net/http's client, which rejects the `:protocol` pseudo-header that CONNECT-UDP needs.
  - The edge advertises `SETTINGS_ENABLE_CONNECT_PROTOCOL`, so extended CONNECT works.
- **Android ABIs:**
  - arm64 (real phones) is built as `GOOS=android GOARCH=arm64 CGO_ENABLED=0`, which avoids
    syscalls Android's seccomp filter kills.
  - armeabi-v7a and x86_64 are static `GOOS=linux` builds, because `GOOS=android` needs cgo
    for them.
- **`.github/workflows/build.yml`:**
  - Push to `main` builds Windows (installer + zip, Flutter tests, engine vet/test) and Android.
  - macOS runs only through Actions → Build → Run workflow (default unticked).
  - The macOS dmg step retries `hdiutil` (one transient failure was seen).
- **Local machine:**
  - Windows Developer Mode is off, so `flutter build windows` fails locally (it needs
    symlinks). Real builds come from CI.
  - Go 1.27.3 is at `C:\Users\11\sdk\go1.27.3`, not on PATH. Google's downloads and module
    proxy are blocked from this network: use `GOPROXY=https://goproxy.cn,direct`. Go itself
    came from `mirrors.aliyun.com/golang/` (sha256 checked).
  - `flutter test` and `go test -tags http2legacy ./...` (in `core/`) both run locally.
- **Commits:** plain messages, no Claude attribution.

## Timeline of findings (why things are the way they are)

1. **Frequent drops on Windows.**
   - The log showed `Connection to upstream lost, reconnecting` every 1–4 minutes, each one
     killing every open connection.
   - First fix: the Dart keep-alive counted a late PING ACK (queued behind megabytes of data on
     a slow line) as a dead connection. Now any bytes received count as alive. The ping runs
     every 10 s with a 10 s timeout.
   - Diagnostics added: the reason for each loss, GOAWAY details, and the helper's FIN/reset
     reporting.
2. **The real cause of the drops:**
   - Fastly sent `GOAWAY PROTOCOL_ERROR "unexpected stream id in RST_STREAM frame"`.
   - The Dart http2 library wrote RST_STREAM directly to the socket, so a cancel could
     overtake its own still-queued HEADERS.
   - Fixed in `third_party/http2` (patch 11, test `test/http2_rst_order_test.dart`).
   - The Go engine does not have this bug.
3. **Uploads froze everything.** Reproduced: with an upload running, downloads went to 0 B/s
   and new pages timed out.
   - Cause: one shared HTTP/2 connection. New-stream HEADERS waited behind queued upload DATA.
   - Fixed in the Dart http2 (patch 12: HEADERS may pass other streams' DATA).
   - The upload source on this PC is MEGAsync and Telegram Desktop, among others.
   - An attempt to cap kernel send buffers (64 KiB / 256 KiB) made things **slower** and was
     removed.
4. **TLS fingerprint.**
   - Arman VPN (github.com/armanlife/arman-vpn-client, GPL-3.0, so **do not copy its code**)
     reached ~1 MB/s on the same line with a Go core, a Firefox uTLS hello and x/net http2.
   - Dart cannot change its ClientHello. A Go TLS helper (`foxy-tls`) was tried first and
     gave ~3× on a single download. It was later replaced by the full engine.
5. **Go engine (foxy-core v1)** replaced the Dart HTTP/2 upstream on Windows and Android.
   - Live checks: TLS 1.3 + h2 with the Firefox hello, CONNECT and CONNECT-UDP accepted by the
     edge, and the process exits cleanly.
6. **The Dart SOCKS relay was the last Windows bottleneck.**
   - Same engine, same moment: read directly 0.81 / 0.45 MB/s vs through Dart's
     `LocalSocksServer` 0.41 / 0.29 MB/s.
   - Dart socket relaying is much slower on Windows than on Android, which explains the
     long-running "phone fine, PC slow".
   - foxy-core v2 serves SOCKS5 itself. Measured live: engine SOCKS 0.85 MB/s vs Dart SOCKS
     0.41 MB/s.

## Measurements on the user's PC (Ethernet, same modem as the phone)

| What | Result |
|---|---|
| No VPN, Cloudflare, 1 connection | 1.9 MB/s |
| No VPN, Fastly CDN, 1 / 4 connections | 0.88 / ~1.2 MB/s total |
| Old Dart path, 1 download | 0.25–0.34 MB/s, drops every 1–4 min |
| Engine with its own SOCKS (installed build), 1 / 4 downloads | 0.46 / 0.66 MB/s |
| Download while uploading, old → now | 0 → 0.29 MB/s |
| New page while uploading, old → now | timeout → 6.9 s |
| Engine, 1 vs 4 separate HTTP/2 connections (lossy line) | 0.52 vs 0.88 MB/s total |
| Ping to the edge | ~110–160 ms |

- The PC retransmits about 1.6% of its TCP segments. The line varies a lot from minute to
  minute, so compare numbers taken back to back.
- The edge allows `MAX_CONCURRENT_STREAMS=1000`.
- Idle HTTP/2 connections are not cut (3 minutes tested). The old cuts were the RST bug.

## PC environment notes (user's Windows machine)

- Other VPN services are installed and running: NordVPN (incl. Threat Protection), ExpressVPN,
  OpenVPN Connect, and Cisco AnyConnect (not present).
- MEGAsync uploads in the background.
- The Ethernet NIC (2.5 GbE Realtek) negotiates only 100 Mbps, which points to the cable or
  port. It isn't the bottleneck at current speeds.
- The log is `%APPDATA%\FoxyVPN\log.txt` (rotated to `log.old.txt`).
- The install is `C:\Program Files\FoxyVPN\`. Installing over an old version is fine.
  `Removed orphaned adapter "FoxyVPN 1"` in the log is harmless.

## Reading the log

| Line | Meaning |
|---|---|
| `foxy-core: connected (tls1.3 h2 firefox)` | The engine is up. `go` instead of `firefox` means the Firefox hello failed and the fallback was used. |
| `SOCKS on 127.0.0.1:N` | On Windows/Android with the engine, this is the engine's SOCKS port. |
| `foxy-core did not start (...)` | Fell back to the Dart path. Check that foxy-core.exe / libfoxycore.so exists. |
| `foxy-core: connection lost: ...` / `reconnected` | Engine-level reconnects (should be rare). |
| `Opening a flow failed: ...; upstream ...` | Why a connection could not open (rate-limited). |
| `UDP to X refused by Mozilla's server (HTTP 502); ignoring it for 5 minutes` | Normal: the edge forbids some UDP (NetBIOS, port 53, etc.). |
| `HTTP 451 ... retrying with a doubled leading slash` | Normal: the 451 workaround in the control plane. |
| tun2socks `CONNECT: connection refused` | The edge refused that destination (502). A few are normal. |

## How to benchmark the engine live (uses the user's saved sign-in for one pass request)

- Write a throwaway test under `test/` (delete it after) that:
  - gets the pass with `await Account().proxyPass()`;
  - starts `EngineUpstream.connect(ServerNode(host, 2499), token: pass.token,
    executable: '<repo>/build/foxy-core.exe', pinnedAddress: InternetAddress(ip))`;
  - then either uses `curl -x socks5h://127.0.0.1:<engine.socksPort> <big file>`, or reads
    `engine.open('dl-cdn.alpinelinux.org', 80)` directly with an HTTP GET.
- `speed.cloudflare.com` returns 403 to Dart's TLS client, so use the alpine ISO over plain HTTP.
- Build the exe first: `cd core && CGO_ENABLED=0 go build -tags http2legacy -trimpath
  -ldflags "-s -w -H windowsgui" -o ../build/foxy-core.exe .`.
- Use an edge IP from the current log (`Connected via ...`). While the VPN is on, only the
  pinned IP has a bypass route.

## Done in 1.0.9 (2026-11-12)

- **Connection pool:** the engine keeps 3 HTTP/2 connections (`--conns`, default 3, 1–8) and
  puts each new flow on the least busy one. Losing one of them is not `lost`; it is redialed
  in the background (a failed extra dial waits 10 s). `core/upstream.go`.
- **Real delay instead of ping** on the Locations page and for Recommended (see "Probe mode").
  It measures latency through each exit, not throughput. Not yet seen working against the real
  edge (the dev PC's traffic goes through another TUN at 198.18.0.1): check the app log on a
  real device after the first round.
- **`auth_failed`** inside its 5 s window is now queued and sent when the window ends.
- **Half-closed streams** (client sent FIN) are cancelled after 5 min without a download byte.
- Decided against: upload rate cap (user's call); HTTP/3 left for later.

## Open items / ideas (not started, in priority order)

1. **HTTP/3 (QUIC) as an experiment.** quic-go is MIT; the edge port is 2499. Unproven on this
   line.
2. **Engine SOCKS port after a crash:** if `--socks-port` cannot be re-bound, the reconnect
   fails (logged `Engine SOCKS port changed`). Following the new port means restarting
   tun2socks/hev and the Wintun setup; judged too risky for now.
3. **macOS:** still on the Dart path, and CI is paused for it. When resumed, ship foxy-core in
   the app bundle (darwin arm64/amd64) and enable the engine SOCKS path for macOS in
   `VpnSession.engineSocksPlatform`.
4. **Licensing:**
   - FoxyVPN is MIT. The engine uses only BSD/MIT deps (x/net, uTLS, Go stdlib).
   - Arman's code is GPL-3.0. Do not copy from it; reading it for ideas is fine.
   - Mozilla VPN's client (mozilla-mobile/mozilla-vpn-client) is MPL-2.0. Its server scoring
     (`src/serverlatency.cpp`: ICMP ping of WireGuard servers, 8 parallel, every 30 min, cooldown
     after failures) was read for ideas only.
