# bin/sources/ -- ONVIF binary build system

This directory contains the build system for compiling `onvif_simple_server` and
`wsd_simple_server` for linux/arm64 (Jetson Orin NX).

## What it builds

| Binary | Source |
|--------|--------|
| `onvif_simple_server` | [poeggi/onvif_simple_server](https://github.com/poeggi/onvif_simple_server) fork, branch `feature/onvif-mac-uuid` |
| `wsd_simple_server` | same |

Both binaries are built **fully statically linked** and placed into `../../bin/`
(the repo-level `bin/` directory). They run on any JetPack version without
needing matching glibc or other shared libs.

---

## Source code

Sources live in the [poeggi/onvif_simple_server](https://github.com/poeggi/onvif_simple_server)
fork on branch `feature/onvif-mac-uuid`. This fork carries our modifications on top of
[roleoroleo/onvif_simple_server](https://github.com/roleoroleo/onvif_simple_server).

Work on the fork at: `d:\repos\onvif_simple_server` (or clone it fresh anywhere).

### Key modifications

| File | What changed |
|------|-------------|
| `wsd_simple_server.c` | Auto interface/IP detection (no `-i` flag); dual-stack `-6` support; deduped SHA-1/UUID/MAC |
| `conf.c` | Fixed missing `#include <net/if.h>` (IFNAMSIZ); fixed printf format string bug |
| `utils.c` / `utils.h` | MAC-based UUID v5 (stable ONVIF device UUID); SHA-1 helpers shared by both binaries |

All changes are documented as numbered patch files in `patches/` (generated with
`git format-patch origin/master..HEAD`).

---

## Build scripts

| Script | When to use |
|--------|-------------|
| `cross-build-windows.ps1` | **Windows:** Docker Desktop cross-compiles for arm64 via QEMU |
| `build-on-device.sh` | **Jetson:** native arm64 build, clones fork directly |

### Windows (cross-compile)

Requirements: Docker Desktop 4.x+ with multi-arch support (enabled by default).

```powershell
# Run from repo root:
.\bin\sources\cross-build-windows.ps1                                      # default branch
.\bin\sources\cross-build-windows.ps1 -Branch feature/onvif-mac-uuid      # specific branch
```

First run: 5–15 min (Docker pulls arm64 Ubuntu image via QEMU). Subsequent runs: fast (cache).

To force a fresh clone when the branch HEAD changed without the branch name changing:

```powershell
docker build --build-arg "CACHE_BUST=$(Get-Date -UFormat %s)" ...
```

### Jetson (native build)

Requirements (install once):
```bash
sudo apt-get install git gcc make libjson-c-dev zlib1g-dev wget xz-utils
```

```bash
# Run from repo root:
./bin/sources/build-on-device.sh
```

Clones the fork into `bin/sources/onvif_simple_server/` (gitignored — never committed).
On subsequent runs the existing clone is updated via `git pull`. Only `libtomcrypt`
is downloaded separately at build time.

---

## Bundled dependency: libtomcrypt

The Makefile requires `extras/libtomcrypt/libtomcrypt.a`.
Both build scripts compile it from [libtom/libtomcrypt](https://github.com/libtom/libtomcrypt)
v1.18.2 with a minimal subset (SHA1 + Base64 only).

---

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Multi-stage arm64 image; clones from GitHub fork and builds |
| `cross-build-windows.ps1` | Windows PowerShell driver: builds Docker image, extracts binaries to `bin/` |
| `build-on-device.sh` | Native Jetson build script; clones fork, builds into `bin/` |
| `patches/` | `git format-patch` series: all our changes vs upstream master |
| `onvif_simple_server/` | *(gitignored)* Local fork clone, created by `build-on-device.sh` |
