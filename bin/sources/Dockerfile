# Build onvif_simple_server and wsd_simple_server for linux/arm64 (Jetson Orin NX).
# Uses QEMU emulation via Docker's --platform flag -- requires Docker Desktop with
# multi-arch support (enabled by default on Windows/Mac with Docker Desktop 4+).
#
# Build context must be the repo root (see build/build.ps1).
# Usage: see build/build.ps1
#
# Produces statically linked binaries -- no runtime library dependencies, runs on any JetPack version.
# Build will FAIL if the output is not statically linked.

FROM --platform=linux/arm64 ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc libc6-dev make git ca-certificates wget xz-utils file \
        libjson-c-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Clone our fork which includes UUID v5, dual-stack WSD, and auto-detected address.
ARG BRANCH=feature/onvif-mac-uuid
# CACHE_BUST: pass --build-arg "CACHE_BUST=$(date +%s)" to force a fresh clone when
# the branch HEAD has changed but the BRANCH arg itself has not.
ARG CACHE_BUST=0
RUN git clone --depth 1 --branch "${BRANCH}" \
    https://github.com/poeggi/onvif_simple_server /src

WORKDIR /src

# Build bundled libtomcrypt as a static library (provides SHA-1 / base64 for utils.c).
RUN cd /src/extras && \
    wget -q https://github.com/libtom/libtomcrypt/releases/download/v1.18.2/crypt-1.18.2.tar.xz && \
    tar Jxf crypt-1.18.2.tar.xz && \
    ln -sf libtomcrypt-1.18.2 libtomcrypt && \
    cd libtomcrypt && \
    CFLAGS="-DLTC_NOTHING -DLTC_SHA1 -DLTC_BASE64" make -s libtomcrypt.a

RUN make -C /src \
        CC=gcc STRIP=strip \
        INCLUDE="-Iextras/libtomcrypt/src/headers -ffunction-sections -fdata-sections" \
        LIBS_O="-static -Wl,--gc-sections extras/libtomcrypt/libtomcrypt.a -ljson-c -lz -lpthread -lrt" \
        LIBS_W="-static -Wl,--gc-sections" \
        onvif_simple_server wsd_simple_server

# Verify static linking -- fail the build if either binary is dynamically linked.
RUN file onvif_simple_server wsd_simple_server && \
    ls -lh onvif_simple_server wsd_simple_server && \
    file onvif_simple_server | grep -q "statically linked" || \
        { echo "ERROR: onvif_simple_server is not statically linked"; exit 1; } && \
    file wsd_simple_server    | grep -q "statically linked" || \
        { echo "ERROR: wsd_simple_server is not statically linked";    exit 1; }
