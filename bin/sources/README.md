# bin/sources/ -- ONVIF binary build system

This directory contains the build system for compiling `onvif_simple_server` and
`wsd_simple_server` for linux/arm64 (Jetson Orin NX).

## What it builds

| Binary | Source |
|--------|--------|
| `onvif_simple_server` | `src/` (local copy, see below) |
| `wsd_simple_server` | `src/` (local copy, see below) |

Both binaries are built **fully statically linked** and placed into `../../bin/`
(the repo-level `bin/` directory). They run on any JetPack version without
needing matching glibc or other shared libs.

---

## Source code (`src/`)

`src/` is a local copy of the [poeggi/onvif_simple_server](https://github.com/poeggi/onvif_simple_server)
fork, tracking branch `feature/onvif-mac-uuid`. This fork carries our modifications
on top of [roleoroleo/onvif_simple_server](https://github.com/roleoroleo/onvif_simple_server).

### Key modifications in this fork

| File | What changed |
|------|-------------|
| `wsd_simple_server.c` | Automatic interface/IP detection (no `-i` flag needed); dual-stack `-6` support; removed duplicate SHA-1/UUID/MAC implementations |
| `conf.c` | Fixed missing `#include <net/if.h>` (IFNAMSIZ); fixed printf format string bug |
| `utils.c` / `utils.h` | MAC-based UUID v5 (stable ONVIF device UUID); SHA-1 helpers shared by both binaries |

The local `src/` copy exists so that:
- `build-on-device.sh` can build natively on the Jetson without internet access
- The exact modified sources that produced the committed binaries are visible in this repo

**Keeping `src/` in sync:** after pulling new commits from the fork, copy the changed
files from the clone into `src/` and rebuild.

---

## Build scripts

| Script | When to use |
|--------|-------------|
| `cross-build-windows.ps1` | **Windows:** Docker Desktop cross-compiles for arm64 via QEMU |
| `build-on-device.sh` | **Jetson:** native arm64 build, no Docker required |

### Windows (cross-compile)

Requirements: Docker Desktop 4.x+ with multi-arch support (enabled by default).

```powershell
# Run from repo root:
.\bin\sources\cross-build-windows.ps1                                    # default branch
.\bin\sources\cross-build-windows.ps1 -Branch feature/dual-stack-onvif  # specific branch
```

First run: 5–15 min (Docker pulls arm64 Ubuntu image via QEMU). Subsequent runs: fast (cache).
The `Dockerfile` clones from the GitHub fork and builds from there.

To force a fresh clone when the branch HEAD changed without the branch name changing:

```powershell
docker build --build-arg "CACHE_BUST=$(Get-Date -UFormat %s)" ...
```

(The `CACHE_BUST` ARG in the Dockerfile is wired up for this purpose.)

### Jetson (native build)

Requirements (install once):
```bash
sudo apt-get install gcc make libjson-c-dev zlib1g-dev wget xz-utils
```

```bash
# Run from repo root:
./bin/sources/build-on-device.sh
```

Builds from `bin/sources/src/` directly — no internet required for sources.
Only `libtomcrypt` is downloaded from GitHub releases at build time.

---

## Bundled dependency: libtomcrypt

The Makefile requires `extras/libtomcrypt/libtomcrypt.a`.
Both build scripts compile it from [libtom/libtomcrypt](https://github.com/libtom/libtomcrypt)
v1.18.2 with a minimal subset (SHA1 + Base64 only).

---

## Files

| File | Purpose |
|------|---------|
| `src/` | Local copy of modified source code (poeggi fork, feature/onvif-mac-uuid) |
| `Dockerfile` | Multi-stage arm64 image; clones from GitHub fork and builds |
| `cross-build-windows.ps1` | Windows PowerShell driver: builds Docker image, extracts binaries to `bin/` |
| `build-on-device.sh` | Native Jetson build script; builds from `src/` into `bin/` |
