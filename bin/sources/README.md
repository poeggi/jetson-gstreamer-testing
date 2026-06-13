# bin/sources/ -- ONVIF binary build system

This directory contains the build system for compiling `onvif_simple_server` and
`wsd_simple_server` for linux/arm64 (Jetson Orin NX).

## What it builds

| Binary | Source |
|--------|--------|
| `onvif_simple_server` | [poeggi/onvif_simple_server](https://github.com/poeggi/onvif_simple_server) fork, branch `feature/onvif-uuid` |
| `wsd_simple_server` | same |

Both binaries are built **fully statically linked** and placed into `../../bin/`
(the repo-level `bin/` directory). They run on any JetPack version without
needing matching glibc or other shared libs.

---

## Source code

Sources live in the [poeggi/onvif_simple_server](https://github.com/poeggi/onvif_simple_server)
fork on branch `feature/onvif-uuid`. This fork carries our modifications on top of
[roleoroleo/onvif_simple_server](https://github.com/roleoroleo/onvif_simple_server).

Work on the fork at: `d:\repos\onvif_simple_server` (or clone it fresh anywhere).

### Key modifications

Changes are split across two upstream PRs:

**PR #47 -- interface auto-detection** (`pr47-*` patches)
| File | What changed |
|------|-------------|
| `conf.c` | Fixed missing `#include <net/if.h>` (IFNAMSIZ); fixed printf format string bug |
| `utils.c` / `utils.h` | `get_mac_by_ifname`, `get_mac_by_ip`, `get_ifname_by_addr`, `detect_local_address` moved here as non-static |
| `wsd_simple_server.c` | Removed static copies of above (now shared via utils.h); `-i` flag now optional (auto-detects from routing table) |
| `onvif_simple_server.h` | Added `address[46]` / `address_url[48]` fields; `ifs=` config now optional |

**PR #49 -- stable UUID v5 via MAC (GetEndpointReference)** (`pr49-*` patches)
| File | What changed |
|------|-------------|
| `utils.c` / `utils.h` | SHA-1 helpers (RFC 3174, UUID v5 only); `gen_uuid_v5_mac()` public function |
| `onvif_simple_server.h` | Added `device_uuid[37]` field |
| `conf.c` | UUID generated at startup from MAC; falls back to random UUID if MAC unavailable |
| `device_service.c` / `.h` | `device_get_endpoint_reference()` serving GetEndpointReference.xml |
| `onvif_simple_server.c` | Dispatch for GetEndpointReference |
| `Makefile` / `test/` | `make test` runs unit tests (15/15); no crypto library needed |

All changes are in `patches/` as `git format-patch` series named `pr47-*` and `pr49-*`.

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
.\bin\sources\cross-build-windows.ps1                                      # default branch (feature/onvif-uuid)
.\bin\sources\cross-build-windows.ps1 -Branch feature/onvif-uuid          # explicit branch
```

First run: 5-15 min (Docker pulls arm64 Ubuntu image via QEMU). Subsequent runs: fast (cache).

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

Clones the fork into `bin/sources/onvif_simple_server/` (gitignored -- never committed).
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
