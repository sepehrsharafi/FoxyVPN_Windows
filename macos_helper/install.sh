#!/bin/sh
# Installs (or upgrades) FoxyVPN's privileged network helper. Run as root:
#   install.sh /Applications/FoxyVPN.app
# Idempotent. Exit codes: 0 ok, 2 not root, 64 bad arguments, 1 anything else.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LABEL=com.foxyvpn.helper
SUPPORT_DIR="/Library/Application Support/FoxyVPN"
HELPER_DEST="/Library/PrivilegedHelperTools/$LABEL"
PLIST_DEST="/Library/LaunchDaemons/$LABEL.plist"
SOCKET="/var/run/$LABEL.sock"

if [ "$(/usr/bin/id -u)" != "0" ]; then
    echo "install.sh must be run as root." >&2
    exit 2
fi

APP="${1:-}"
# Tolerate trailing slashes.
while [ "${APP%/}" != "$APP" ]; do APP="${APP%/}"; done
case "$APP" in
    /*.app) ;;
    *) echo "Usage: install.sh /path/to/FoxyVPN.app (absolute path ending in .app)" >&2; exit 64 ;;
esac
SRC="$APP/Contents/Resources/helper"
for f in foxyvpn-helper tun2socks com.foxyvpn.helper.plist; do
    if [ ! -f "$SRC/$f" ]; then
        echo "FoxyVPN's helper files are missing ($SRC/$f)." >&2
        exit 64
    fi
done

# Stop a running helper first: on SIGTERM it restores DNS and routes. Wait for its socket to go.
/bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
i=0
while [ -S "$SOCKET" ] && [ "$i" -lt 20 ]; do
    /bin/sleep 0.25
    i=$((i + 1))
done

/bin/mkdir -p "/Library/PrivilegedHelperTools" "$SUPPORT_DIR" "/Library/LaunchDaemons"
/usr/sbin/chown root:wheel "$SUPPORT_DIR"
/bin/chmod 755 "$SUPPORT_DIR"

# install_file <source> <destination> <mode>: copy without xattrs, then move into place.
install_file() {
    tmp="$2.new.$$"
    /bin/rm -f "$tmp"
    /bin/cp -X "$1" "$tmp"
    /usr/bin/xattr -c "$tmp" >/dev/null 2>&1 || true
    /usr/sbin/chown root:wheel "$tmp"
    /bin/chmod "$3" "$tmp"
    /bin/mv -f "$tmp" "$2"
}

install_file "$SRC/foxyvpn-helper" "$HELPER_DEST" 755
install_file "$SRC/tun2socks" "$SUPPORT_DIR/tun2socks" 755
install_file "$SRC/com.foxyvpn.helper.plist" "$PLIST_DEST" 644
/usr/bin/plutil -lint "$PLIST_DEST" >/dev/null

# The helper writes helper.json itself, so the app path never needs shell JSON escaping.
"$HELPER_DEST" --write-config "$APP"
/usr/sbin/chown root:wheel "$SUPPORT_DIR/helper.json"
/bin/chmod 644 "$SUPPORT_DIR/helper.json"

# state.json and helper.log belong to the helper; just make sure the permissions are right.
[ ! -f "$SUPPORT_DIR/state.json" ] || { /usr/sbin/chown root:wheel "$SUPPORT_DIR/state.json"; /bin/chmod 600 "$SUPPORT_DIR/state.json"; }
[ ! -f "$SUPPORT_DIR/helper.log" ] || { /usr/sbin/chown root:wheel "$SUPPORT_DIR/helper.log"; /bin/chmod 644 "$SUPPORT_DIR/helper.log"; }

/bin/launchctl enable "system/$LABEL" >/dev/null 2>&1 || true
if ! /bin/launchctl bootstrap system "$PLIST_DEST" >/dev/null 2>&1; then
    /bin/launchctl load -w "$PLIST_DEST" || { echo "Could not start FoxyVPN's network helper." >&2; exit 1; }
fi

i=0
while [ ! -S "$SOCKET" ] && [ "$i" -lt 20 ]; do
    /bin/sleep 0.25
    i=$((i + 1))
done
if [ ! -S "$SOCKET" ]; then
    echo "FoxyVPN's network helper did not start." >&2
    exit 1
fi
exit 0
