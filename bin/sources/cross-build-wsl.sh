#!/usr/bin/env bash
# Build onvif_simple_server + wsd_simple_server for linux/arm64 via WSL2 cross-compiler.
#
# Run from WSL2 Ubuntu-22.04 (or invoke via PowerShell):
#   wsl -d Ubuntu-22.04 -- bash bin/sources/cross-build-wsl.sh
#   wsl -d Ubuntu-22.04 -- bash bin/sources/cross-build-wsl.sh feature/onvif-uuid
#
# Prerequisites (one-time):
#   sudo apt install gcc-aarch64-linux-gnu
#   sudo dpkg --add-architecture arm64
#   sudo apt install libjson-c-dev:arm64 zlib1g-dev:arm64
#
# Output: bin/onvif_simple_server and bin/wsd_simple_server (linux/arm64, statically linked)

set -e

BRANCH="${1:-feature/onvif-mac-uuid}"
LTCVER="1.18.2"
SRC="/tmp/onvif-build"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="$REPO_ROOT/bin"

rm -rf "$SRC"

echo "==> Cloning $BRANCH from poeggi/onvif_simple_server"
git clone --depth 1 --branch "$BRANCH" https://github.com/poeggi/onvif_simple_server "$SRC"

echo "==> Building libtomcrypt for arm64"
cd "$SRC/extras"
wget -q "https://github.com/libtom/libtomcrypt/releases/download/v${LTCVER}/crypt-${LTCVER}.tar.xz"
tar Jxf "crypt-${LTCVER}.tar.xz"
ln -sf "libtomcrypt-${LTCVER}" libtomcrypt
cd libtomcrypt
CFLAGS="-DLTC_NOTHING -DLTC_SHA1 -DLTC_BASE64" CC=aarch64-linux-gnu-gcc make -s libtomcrypt.a

echo "==> Building onvif_simple_server + wsd_simple_server (arm64)"
make -C "$SRC" \
    CC=aarch64-linux-gnu-gcc \
    STRIP=aarch64-linux-gnu-strip \
    INCLUDE="-I$SRC/extras/libtomcrypt/src/headers -ffunction-sections -fdata-sections" \
    LIBS_O="-static -Wl,--gc-sections $SRC/extras/libtomcrypt/libtomcrypt.a -ljson-c -lz -lpthread -lrt" \
    LIBS_W="-static -Wl,--gc-sections" \
    onvif_simple_server wsd_simple_server

echo "==> Verifying static linking"
file "$SRC/onvif_simple_server" "$SRC/wsd_simple_server"
ls -lh "$SRC/onvif_simple_server" "$SRC/wsd_simple_server"

echo "==> Copying to $OUT"
cp "$SRC/onvif_simple_server" "$SRC/wsd_simple_server" "$OUT/"
ls -lh "$OUT/onvif_simple_server" "$OUT/wsd_simple_server"
echo "==> Done. Next: git add bin/onvif_simple_server bin/wsd_simple_server && git commit"
