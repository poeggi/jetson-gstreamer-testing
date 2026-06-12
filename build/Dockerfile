# Build onvif_simple_server and wsd_simple_server for linux/arm64 (Jetson Orin NX).
# Uses QEMU emulation via Docker's --platform flag -- requires Docker Desktop with
# multi-arch support (enabled by default on Windows/Mac with Docker Desktop 4+).
#
# Usage: see build/build.ps1
#
# Produces statically linked binaries -- no runtime library dependencies, runs on any JetPack version.

FROM --platform=linux/arm64 ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc make git ca-certificates wget xz-utils \
    && rm -rf /var/lib/apt/lists/*

ARG TAG=0.0.4
RUN git clone --depth 1 --branch "${TAG}" \
    https://github.com/roleoroleo/onvif_simple_server /src

WORKDIR /src

# Build libtomcrypt (bundled dependency required by the Makefile).
RUN cd /src/extras && \
    wget -q https://github.com/libtom/libtomcrypt/releases/download/v1.18.2/crypt-1.18.2.tar.xz && \
    tar Jxf crypt-1.18.2.tar.xz && \
    ln -sf libtomcrypt-1.18.2 libtomcrypt && \
    cd libtomcrypt && \
    CFLAGS="-DLTC_NOTHING -DLTC_SHA1 -DLTC_BASE64" make -s libtomcrypt.a

RUN make -C /src \
        CC=gcc STRIP=strip \
        LIBS_O="-static -Wl,--gc-sections extras/libtomcrypt/libtomcrypt.a -lpthread -lrt" \
        LIBS_W="-static -Wl,--gc-sections" \
        onvif_simple_server wsd_simple_server

RUN file onvif_simple_server wsd_simple_server && \
    ls -lh onvif_simple_server wsd_simple_server
