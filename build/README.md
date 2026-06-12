# build/ -- Cross-compilation for ONVIF binaries

This directory contains the Docker-based build system that cross-compiles the ONVIF
server stack for linux/arm64 (Jetson Orin NX).

## What it builds

| Binary | Source | Version |
|--------|--------|---------|
| `onvif_simple_server` | [roleoroleo/onvif_simple_server](https://github.com/roleoroleo/onvif_simple_server) | 0.0.4 (default) |
| `wsd_simple_server` | same repo | 0.0.4 (default) |

Both are part of the same upstream project and built from the same Makefile in one pass.
Output goes to `../bin/` (the repo-level `bin/` directory).

### Linking

Binaries are built **fully statically linked** -- no runtime library dependencies.
They run on any JetPack version without needing matching glibc or other shared libs.

### Bundled dependency: libtomcrypt

The upstream Makefile requires `extras/libtomcrypt/libtomcrypt.a`.
The Dockerfile builds it from the [libtom/libtomcrypt](https://github.com/libtom/libtomcrypt)
v1.18.2 source (minimal subset: SHA1 + Base64 only) before building the main targets.

---

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Multi-stage build; runs inside Docker using QEMU arm64 emulation |
| `build.ps1` | Windows PowerShell driver: builds the Docker image, extracts binaries to `bin/` |

---

## Requirements

- **Windows** with Docker Desktop 4.x+ (multi-arch / QEMU emulation enabled by default)
- Internet access on first run (pulls `ubuntu:22.04`, clones source, downloads libtomcrypt)

---

## Usage

Run from the **repo root**:

```powershell
.\build\build.ps1              # build tag 0.0.4 (default)
.\build\build.ps1 -Tag 0.0.3  # build a specific upstream release tag
```

First run: 5-15 min (Docker pulls arm64 Ubuntu image via QEMU).
Subsequent runs: fast (image and layer cache reused).

After building, commit the updated binaries:

```powershell
git add bin/onvif_simple_server bin/wsd_simple_server
git commit -m "Update ONVIF binaries to vX.X.X"
```

---

## Architecture note

Target: `linux/arm64` -- Jetson Orin NX (Cortex-A78AE).
The build runs natively inside an arm64 Docker container via QEMU; no cross-compiler
toolchain is needed on the host.
