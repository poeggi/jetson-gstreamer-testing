#!/usr/bin/env bash
# Native build of onvif_simple_server + wsd_simple_server on the Jetson (arm64).
# Run this script directly on the Jetson -- no Docker or QEMU required.
#
# Requirements (install once):
#   sudo apt-get install git gcc make libjson-c-dev zlib1g-dev wget xz-utils
#
# Usage (run from repo root):
#   ./bin/sources/build-on-device.sh
#   ./bin/sources/build-on-device.sh --branch feature/my-branch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BIN_DIR="${REPO_DIR}/bin"
BRANCH="feature/onvif-mac-uuid"
FORK_URL="https://github.com/poeggi/onvif_simple_server.git"
SRC_DIR="${SCRIPT_DIR}/onvif_simple_server"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch) BRANCH="$2"; shift 2 ;;
        *) echo "Usage: $0 [--branch BRANCH]" >&2; exit 1 ;;
    esac
done

ARCH="$(uname -m)"
[[ "$ARCH" == "aarch64" ]] || {
    echo "ERROR: this script is for native arm64 (aarch64) builds only; got $ARCH." >&2
    echo "       For cross-compilation from Windows, use bin/sources/cross-build-windows.ps1." >&2
    exit 1
}

echo ""
echo "Building onvif_simple_server + wsd_simple_server"
echo "  Platform : native arm64 (Jetson, no Docker)"
echo "  Branch   : ${BRANCH}  (poeggi/onvif_simple_server)"
echo "  Output   : ${BIN_DIR}"
echo ""

# Clone or update the fork into bin/sources/onvif_simple_server/
# (gitignored -- not committed to this repo)
if [[ -d "${SRC_DIR}/.git" ]]; then
    echo "Updating existing clone..."
    git -C "${SRC_DIR}" fetch origin
    git -C "${SRC_DIR}" checkout "${BRANCH}"
    git -C "${SRC_DIR}" pull --ff-only origin "${BRANCH}"
else
    echo "Cloning ${FORK_URL} branch ${BRANCH}..."
    git clone --depth 1 --branch "${BRANCH}" "${FORK_URL}" "${SRC_DIR}"
fi

TMP_BUILD="$(mktemp -d)"
trap 'rm -rf "$TMP_BUILD"' EXIT

cp -r "${SRC_DIR}/"* "${TMP_BUILD}/"

# Build bundled libtomcrypt
cd "${TMP_BUILD}/extras"
wget -q https://github.com/libtom/libtomcrypt/releases/download/v1.18.2/crypt-1.18.2.tar.xz
tar Jxf crypt-1.18.2.tar.xz
ln -sf libtomcrypt-1.18.2 libtomcrypt
cd libtomcrypt
CFLAGS="-DLTC_NOTHING -DLTC_SHA1 -DLTC_BASE64" make -s libtomcrypt.a

cd "${TMP_BUILD}"
make CC=gcc STRIP=strip \
    INCLUDE="-Iextras/libtomcrypt/src/headers -ffunction-sections -fdata-sections" \
    LIBS_O="-static -Wl,--gc-sections extras/libtomcrypt/libtomcrypt.a -ljson-c -lz -lpthread -lrt" \
    LIBS_W="-static -Wl,--gc-sections" \
    onvif_simple_server wsd_simple_server

file onvif_simple_server wsd_simple_server | grep -q "statically linked" || {
    echo "ERROR: binaries are not statically linked" >&2; exit 1
}

cp onvif_simple_server wsd_simple_server "${BIN_DIR}/"

echo ""
echo "Done."
ls -lh "${BIN_DIR}/onvif_simple_server" "${BIN_DIR}/wsd_simple_server"
echo ""
echo "Next steps:"
echo "  git add bin/onvif_simple_server bin/wsd_simple_server"
echo "  git commit -m 'update arm64 onvif/wsd binaries'"
