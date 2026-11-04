#!/bin/bash
# Live end-to-end test of the macOS helper, for a GitHub Actions macos runner:
#   sudo bash macos_helper/ci/smoke.sh /path/to/FoxyVPN.app
# Installs the helper, routes all traffic into the tunnel (through a fake SOCKS5 server whose own
# sockets are pinned to the real network), checks routes/DNS/traffic, then checks that a client
# crash and an explicit stop both restore the Mac, and finally uninstalls.
# macOS ships bash 3.2 and BSD tools: no timeout, no associative arrays, no GNU flags here.
set -u
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

APP_ARG="${1:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER_SRC="$(cd "$HERE/.." && pwd)"
SOCKET="/var/run/com.foxyvpn.helper.sock"
SUPPORT="/Library/Application Support/FoxyVPN"
PLIST="/Library/LaunchDaemons/com.foxyvpn.helper.plist"
BYPASS_IP="203.0.113.99"

PASSES=0
FAILED=0
INSTALLED=0
CLIENT_PID=""
SOCKS_PID=""
WORK=""
APP=""

pass() { PASSES=$((PASSES + 1)); echo "PASS: $*"; }
dump_log() {
    for f in "$SUPPORT/helper.log" "$SUPPORT/helper.log.1"; do
        if [ -f "$f" ]; then echo "---- $f ----"; /usr/bin/tail -n 200 "$f"; fi
    done
    if [ -n "$WORK" ] && [ -f "$WORK/socks.log" ]; then echo "---- fake socks log ----"; /usr/bin/tail -n 50 "$WORK/socks.log"; fi
}
fail() {
    echo "FAIL: $*"
    FAILED=1
    dump_log
    exit 1
}

# Always put the runner's network back, whatever happened.
cleanup() {
    rc=$?
    set +e
    [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" >/dev/null 2>&1
    [ -n "$SOCKS_PID" ] && kill "$SOCKS_PID" >/dev/null 2>&1
    [ -n "$APP" ] && /bin/rm -f "$APP/Contents/MacOS/foxyvpn-smoke-client"
    if [ "$INSTALLED" = "1" ]; then
        if [ "$FAILED" = "0" ] && [ "$rc" != "0" ]; then dump_log; fi
        /bin/sh "$APP/Contents/Resources/helper/uninstall.sh" >/dev/null 2>&1
    fi
    if [ -n "$WORK" ] && [ -f "$WORK/dns.before" ]; then
        # Last resort: put the saved DNS back ourselves if anything differs.
        snapshot_dns > "$WORK/dns.final" 2>/dev/null
        if ! /usr/bin/cmp -s "$WORK/dns.before" "$WORK/dns.final"; then
            echo "WARN: DNS differs at the end, restoring it by hand"
            restore_dns_from "$WORK/dns.before"
        fi
    fi
    [ -n "$WORK" ] && /bin/rm -rf "$WORK"
    if [ "$FAILED" = "0" ] && [ "$rc" = "0" ]; then
        echo "ALL CHECKS PASSED ($PASSES)"
    else
        echo "SMOKE TEST FAILED"
        [ "$rc" = "0" ] && rc=1
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'echo "interrupted"; exit 130' INT TERM

# One line per enabled service: "<service>|<servers on one line, or empty>".
snapshot_dns() {
    /usr/sbin/networksetup -listallnetworkservices | /usr/bin/sed '1d' | while IFS= read -r svc; do
        case "$svc" in "" | "*"*) continue ;; esac
        out="$(/usr/sbin/networksetup -getdnsservers "$svc" 2>&1)"
        case "$out" in
            "There aren't any"*) out="" ;;
            *) out="$(printf '%s' "$out" | /usr/bin/tr '\n' ' ')" ;;
        esac
        printf '%s|%s\n' "$svc" "$out"
    done
}

restore_dns_from() {
    while IFS= read -r line; do
        svc="${line%%|*}"
        servers="${line#*|}"
        if [ -z "$servers" ]; then servers="empty"; fi
        # shellcheck disable=SC2086
        /usr/sbin/networksetup -setdnsservers "$svc" $servers >/dev/null 2>&1
    done < "$1"
}

route_iface() { /sbin/route -n get "$1" 2>/dev/null | /usr/bin/awk '/interface:/ {print $2; exit}'; }

# wait_for <seconds> <description> <command...>: poll every 0.25 s.
wait_for() {
    limit=$(($1 * 4))
    desc="$2"
    shift 2
    n=0
    while [ "$n" -lt "$limit" ]; do
        if "$@" >/dev/null 2>&1; then return 0; fi
        /bin/sleep 0.25
        n=$((n + 1))
    done
    return 1
}

iface_gone() { ! /sbin/ifconfig "$1" >/dev/null 2>&1; }
no_half_routes() { ! /usr/sbin/netstat -rn -f inet | /usr/bin/awk '$1 == "0/1" || $1 == "128.0/1" {f = 1} END {exit !f}'; }
dns_restored() { snapshot_dns > "$WORK/dns.now" 2>/dev/null && /usr/bin/cmp -s "$WORK/dns.before" "$WORK/dns.now"; }
resolver1() { /usr/sbin/scutil --dns | /usr/bin/awk '/^resolver #1$/ {f = 1; next} /^resolver #/ {f = 0} f && /nameserver\[0\]/ {print $3; exit}'; }
resolver_is_tunnel() { [ "$(resolver1)" = "198.18.0.2" ]; }
route_is_tun() { [ "$(route_iface 1.1.1.1)" = "$UTUN" ]; }

json_field() { /usr/bin/sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | /usr/bin/head -n 1; }

# ---------------------------------------------------------------- setup
[ "$(/usr/bin/id -u)" = "0" ] || { echo "FAIL: run with sudo"; exit 1; }
[ -n "$APP_ARG" ] && [ -d "$APP_ARG" ] || { echo "FAIL: usage: sudo bash smoke.sh /path/to/FoxyVPN.app"; exit 1; }
APP="$(cd "$APP_ARG" && pwd -P)"
[ -f "$APP/Contents/Resources/helper/install.sh" ] || fail "helper files missing in $APP/Contents/Resources/helper"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/foxysmoke.XXXXXX")" || fail "cannot create a temp folder"

snapshot_dns > "$WORK/dns.before" || fail "cannot read DNS settings"
echo "DNS before:"; /bin/cat "$WORK/dns.before"
[ -s "$WORK/dns.before" ] || fail "no network services found"

PHYS_IFACE="$(route_iface default)"
[ -n "$PHYS_IFACE" ] || fail "the runner has no default route"
echo "Physical interface: $PHYS_IFACE"

GO="$(command -v go || true)"
[ -n "$GO" ] || for g in /usr/local/go/bin/go /opt/homebrew/bin/go; do [ -x "$g" ] && GO="$g" && break; done
[ -n "$GO" ] || fail "Go is not available to build the test programs"
export GOCACHE="$WORK/gocache" GOPATH="$WORK/gopath" GOFLAGS="-mod=mod" CGO_ENABLED=0 HOME="${HOME:-$WORK}"
(cd "$HELPER_SRC" && "$GO" build -o "$WORK/fakesocks" ./ci/fakesocks && "$GO" build -o "$WORK/client" ./ci/client) \
    || fail "could not build the test programs"
pass "test programs built"

# ---------------------------------------------------------------- install
/bin/sh "$APP/Contents/Resources/helper/install.sh" "$APP" || fail "install.sh failed"
INSTALLED=1
[ -S "$SOCKET" ] || fail "helper socket did not appear"
[ -f "$SUPPORT/helper.json" ] && [ -f "$SUPPORT/tun2socks" ] && [ -f "$PLIST" ] && [ -x /Library/PrivilegedHelperTools/com.foxyvpn.helper ] \
    || fail "installed files missing"
[ "$(/usr/bin/stat -f %Lp "$SUPPORT/helper.json")" = "644" ] || fail "helper.json has the wrong mode"
pass "installed, socket is up"

CLIENT="$APP/Contents/MacOS/foxyvpn-smoke-client"
/bin/cp "$WORK/client" "$CLIENT" || fail "cannot copy the test client into the app"
/bin/chmod 755 "$CLIENT"
HELLO="$("$CLIENT" hello "$SOCKET")" || fail "hello failed: $HELLO"
echo "hello: $HELLO"
case "$HELLO" in *'"version":"1"'*) pass "hello reports version 1" ;; *) fail "unexpected hello reply: $HELLO" ;; esac

# The stranger check: a client outside the app must be refused (hello still works).
/bin/cp "$WORK/client" "$WORK/outsider"
OUT="$("$WORK/outsider" probe "$SOCKET" 2>&1)"
case "$OUT" in *"Not allowed"*) pass "a client outside the app bundle is refused" ;; *) fail "unexpected answer for an outsider: $OUT" ;; esac
OUT="$("$CLIENT" probe "$SOCKET" 2>&1)"
case "$OUT" in *'"ok":true'*) pass "a client inside the app bundle is accepted" ;; *) fail "the in-bundle client was refused: $OUT" ;; esac

# ---------------------------------------------------------------- fake SOCKS5 server
# DNS goes to the resolver the Mac uses right now (CI VMs may block public
# resolvers such as 1.1.1.1); read before the tunnel changes it.
REAL_DNS="$(resolver1)"
case "$REAL_DNS" in ''|198.18.0.2|*:*) REAL_DNS=1.1.1.1 ;; esac
echo "real resolver: $REAL_DNS"
"$WORK/fakesocks" -iface "$PHYS_IFACE" -resolver "$REAL_DNS:53" -log "$WORK/socks.log" -portfile "$WORK/socks.port" >"$WORK/socks.out" 2>&1 &
SOCKS_PID=$!
wait_for 10 "fake socks port file" test -s "$WORK/socks.port" || fail "fake SOCKS server did not start: $(/bin/cat "$WORK/socks.out" 2>/dev/null)"
SOCKS_PORT="$(/bin/cat "$WORK/socks.port")"
pass "fake SOCKS5 server on 127.0.0.1:$SOCKS_PORT"
: > "$WORK/socks.log"

# run_session <mode stop|crash> <tag>: start the tunnel, wait until it is ready.
run_session() {
    /bin/rm -f "$WORK/ready.$2" "$WORK/release.$2"
    "$CLIENT" session "$SOCKET" "$SOCKS_PORT" "$BYPASS_IP" "$WORK/ready.$2" "$WORK/release.$2" "$1" >"$WORK/client.$2.out" 2>&1 &
    CLIENT_PID=$!
    wait_for 30 "tunnel start" test -s "$WORK/ready.$2" || fail "the tunnel did not start: $(/bin/cat "$WORK/client.$2.out" 2>/dev/null)"
    READY="$(/bin/cat "$WORK/ready.$2")"
    case "$READY" in ERROR*) fail "start was refused: $READY" ;; esac
    echo "start reply: $READY"
    UTUN="$(printf '%s' "$READY" | json_field interface)"
    case "$UTUN" in utun[0-9]*) ;; *) fail "no utun name in the start reply: $READY" ;; esac
}

check_tunnel_is_up() {
    wait_for 5 "route" route_is_tun || fail "route to 1.1.1.1 goes through '$(route_iface 1.1.1.1)', not $UTUN"
    pass "route -n get 1.1.1.1 uses $UTUN"
    [ "$(route_iface "$BYPASS_IP")" = "$PHYS_IFACE" ] || fail "bypass address $BYPASS_IP does not use $PHYS_IFACE (uses '$(route_iface "$BYPASS_IP")')"
    pass "bypass address stays on $PHYS_IFACE"
    wait_for 8 "dns" resolver_is_tunnel || fail "scutil --dns resolver #1 is '$(resolver1)', expected 198.18.0.2"
    pass "scutil --dns resolver #1 is 198.18.0.2"
}

check_traffic() {
    : > "$WORK/socks.log"
    # Port 80 is answered by the fake server itself with a marker, so getting
    # the marker back proves name lookup and TCP both went through the tunnel.
    BODY="$(/usr/bin/curl -sS --max-time 15 http://example.com/ 2>&1)" || fail "curl http://example.com failed through the tunnel: $BODY"
    case "$BODY" in
        *FOXY-TUNNEL-OK*) pass "curl got the fake SOCKS server's answer: TCP went through the tunnel ($(/usr/bin/grep 'CONNECT .*:80' "$WORK/socks.log" | /usr/bin/head -n 1))" ;;
        *) fail "curl did not get the fake SOCKS server's answer (traffic bypassed the tunnel): $BODY" ;;
    esac
    if /usr/bin/grep -q 'DNS example.com' "$WORK/socks.log"; then
        pass "the DNS query for example.com went through the tunnel"
    else
        echo "WARN: no DNS query for example.com seen by the fake server (cached answer?)"
    fi
}

check_restored() { # <seconds>
    wait_for "$1" "iface gone" iface_gone "$UTUN" || fail "$UTUN still exists after $1 s"
    wait_for "$1" "routes gone" no_half_routes || fail "0/1 or 128.0/1 routes still present after $1 s"
    [ "$(route_iface 1.1.1.1)" = "$PHYS_IFACE" ] || fail "1.1.1.1 routes via '$(route_iface 1.1.1.1)' after teardown, expected $PHYS_IFACE"
    wait_for "$1" "dns restored" dns_restored || { echo "DNS now:"; /bin/cat "$WORK/dns.now"; fail "DNS settings were not restored"; }
    pass "interface, routes and DNS are back to normal"
}

# ---------------------------------------------------------------- round 1: client crash
echo "== round 1: the client disappears without 'stop' =="
run_session crash r1
check_tunnel_is_up
check_traffic
: > "$WORK/release.r1"
wait "$CLIENT_PID" 2>/dev/null; CLIENT_PID=""
check_restored 5

# ---------------------------------------------------------------- round 2: explicit stop
echo "== round 2: explicit stop =="
run_session stop r2
check_tunnel_is_up
check_traffic
: > "$WORK/release.r2"
wait "$CLIENT_PID" 2>/dev/null; CLIENT_PID=""
check_restored 5

# ---------------------------------------------------------------- upgrade
# An app update re-runs install.sh over a running helper.
/bin/sh "$APP/Contents/Resources/helper/install.sh" "$APP" || fail "re-running install.sh (upgrade) failed"
wait_for 10 "socket after upgrade" test -S "$SOCKET" || fail "no socket after the upgrade"
OUT="$("$CLIENT" probe "$SOCKET" 2>&1)"
case "$OUT" in *'"ok":true'*) pass "upgrade: the helper came back and answers" ;; *) fail "after the upgrade the helper did not answer: $OUT" ;; esac

# ---------------------------------------------------------------- uninstall
/bin/rm -f "$CLIENT"
/bin/sh "$APP/Contents/Resources/helper/uninstall.sh" || fail "uninstall.sh failed"
INSTALLED=0
wait_for 5 "socket gone" test ! -S "$SOCKET" || fail "socket still exists after uninstall"
[ ! -e "$PLIST" ] || fail "plist still exists after uninstall"
[ ! -e /Library/PrivilegedHelperTools/com.foxyvpn.helper ] || fail "helper binary still exists after uninstall"
[ ! -e "$SUPPORT/tun2socks" ] && [ ! -e "$SUPPORT/helper.json" ] && [ ! -e "$SUPPORT/state.json" ] && [ ! -e "$SUPPORT/helper.log" ] \
    || fail "support files still exist after uninstall"
if /bin/launchctl print system/com.foxyvpn.helper >/dev/null 2>&1; then
    /bin/launchctl print system/com.foxyvpn.helper 2>&1 | /usr/bin/head -n 25
    fail "the launchd job is still loaded"
fi
dns_restored || fail "DNS differs after uninstall"
pass "uninstalled cleanly"
exit 0
