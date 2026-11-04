#!/bin/sh
# Removes FoxyVPN's privileged network helper. Run as root. Asks nothing, always exits 0
# (unless not root: exit 2).
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LABEL=com.foxyvpn.helper
SUPPORT_DIR="/Library/Application Support/FoxyVPN"
HELPER="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SOCKET="/var/run/$LABEL.sock"

if [ "$(/usr/bin/id -u)" != "0" ]; then
    echo "uninstall.sh must be run as root." >&2
    exit 2
fi

# bootout first: the helper restores DNS and routes on SIGTERM. Wait for its socket to go away.
/bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
i=0
while [ -S "$SOCKET" ] && [ "$i" -lt 20 ]; do
    /bin/sleep 0.25
    i=$((i + 1))
done
/bin/launchctl remove "$LABEL" >/dev/null 2>&1 || true

# If the daemon was not running, still undo DNS/routes left in state.json.
if [ -x "$HELPER" ] && [ -f "$SUPPORT_DIR/state.json" ]; then
    "$HELPER" --restore >/dev/null 2>&1 || true
fi

/bin/rm -f "$SOCKET" "$PLIST" "$HELPER"
/bin/rm -f "$SUPPORT_DIR/tun2socks" "$SUPPORT_DIR/helper.json" "$SUPPORT_DIR/helper.json.tmp" \
    "$SUPPORT_DIR/state.json" "$SUPPORT_DIR/state.json.tmp" "$SUPPORT_DIR/helper.log" "$SUPPORT_DIR/helper.log.1"
/bin/rmdir "$SUPPORT_DIR" >/dev/null 2>&1 || true
exit 0
