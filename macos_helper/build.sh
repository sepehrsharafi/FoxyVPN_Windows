#!/bin/sh
# Builds the universal helper: build.sh <outDir>  ->  <outDir>/foxyvpn-helper (ad-hoc signed).
# Needs macOS (lipo, codesign) and Go 1.22+ on PATH.
set -eu
if [ "$#" -ne 1 ]; then
    echo "Usage: build.sh <outDir>" >&2
    exit 64
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$1"
OUT="$(cd "$1" && pwd)/foxyvpn-helper"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/foxyhelper.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

cd "$HERE"
for arch in arm64 amd64; do
    GOOS=darwin GOARCH="$arch" CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$TMP/helper-$arch" .
done
rm -f "$OUT"
lipo -create -output "$OUT" "$TMP/helper-arm64" "$TMP/helper-amd64"
chmod 755 "$OUT"
codesign --force --sign - "$OUT"
echo "Built $OUT"
