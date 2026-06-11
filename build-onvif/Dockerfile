# Build onvif_simple_server and wsd_simple_server for linux/arm64 (Jetson Orin NX).
# Uses QEMU emulation via Docker's --platform flag -- requires Docker Desktop with
# multi-arch support (enabled by default on Windows/Mac with Docker Desktop 4+).
#
# Usage: see build-onvif.ps1 in the repo root.
#
# Produces statically linked binaries -- no runtime library dependencies on the Jetson.

FROM --platform=linux/arm64 ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc make git ca-certificates \
        libtomcrypt-dev \
        zlib1g-dev \
        libjson-c-dev \
    && rm -rf /var/lib/apt/lists/*

ARG TAG=0.0.4
RUN git clone --depth 1 --branch "${TAG}" \
    https://github.com/roleoroleo/onvif_simple_server /src

WORKDIR /src

# Makefile.static links all dependencies statically so the binary runs on any
# JetPack version without requiring matching library versions on the Jetson.
RUN make -f Makefile.static

RUN file onvif_simple_server wsd_simple_server && \
    ls -lh onvif_simple_server wsd_simple_server
