# Basler a2A4096-30ucPRO -- GStreamer Pipeline

**Camera:** Basler a2A4096-30ucPRO &nbsp;|&nbsp; **Target:** NVIDIA Jetson Orin NX (JetPack 5.x / 6.x)\
&nbsp;|&nbsp; **Script:** `send_stream.sh`

Zero-copy GStreamer pipeline: Basler USB camera → NVENC hardware encode → RTSP.
Includes `check_system.sh` for pre-flight checks and optional ONVIF server for NVR auto-discovery.

---

## 0 - Quick Start

### Configuration
Edit **`stream.conf`** - all settings are documented there with sensible defaults.
Two things to verify for your setup:
- `CAMERA_SERIAL` - set if you have multiple Basler cameras (empty = auto-detect first)
- `ONVIF_INTERFACE` - set to the interface facing your NVR (default `eth0`)

### Running
```bash
./send_stream.sh                  # MAIN only (default)
./send_stream.sh --enable-sub     # both streams (MAIN H.265 4K, SUB H.264 1080p)
./send_stream.sh --disable-sub    # MAIN only (explicit)
./send_stream.sh --no-main        # SUB only
./send_stream.sh --main-h264      # override MAIN encoder
./send_stream.sh --sub-h265       # override SUB encoder
./send_stream.sh --fakesink       # test without RTSP server
```

### Viewing (Windows)
```powershell
.\view_stream.ps1                 # MAIN stream (H.265 4K)
.\view_stream.ps1 sub             # SUB stream (H.264 1080p)
```

### Viewing (Linux / Jetson)
```bash
./view_stream.sh                  # MAIN stream via VLC
./receive_stream.sh               # MAIN stream via GStreamer (hardware decode)
./receive_stream.sh sub           # SUB stream via GStreamer
```

### RTSP URLs
| Stream | Open | Authenticated |
|--------|------|---------------|
| MAIN (H.265 4K) | `rtsp://host:8554/main` | `rtsp://guest:guest@host:8554/main-auth` |
| SUB (H.264 1080p) | `rtsp://host:8554/sub` | `rtsp://guest:guest@host:8554/sub-auth` |

### NVR Connection (ONVIF)

Add the Jetson as an IP camera in your NVR - it will appear automatically via WS-Discovery.

| Item | Value |
|------|-------|
| Auto-discovery | WS-Discovery on UDP 3702 |
| ONVIF device URL | `http://JETSON_IP:8080/onvif/device_service` |
| Profiles | Profile_Main (H.265 4K `/main`), Profile_Sub (H.264 1080p `/sub`) |

Can be configured or disabled in `stream.conf` (`ONVIF_ENABLED`, `ONVIF_PORT`, `ONVIF_USER`/`ONVIF_PASSWORD`).

**Prerequisites** (no prebuilt ARM64 binaries - build from source):
```bash
git clone https://github.com/roleoroleo/onvif_simple_server  # follow aarch64 build instructions
sudo apt install lighttpd
```

---

## 1 - Camera and USB

| Property | Value |
|----------|-------|
| Sensor | 1/1.1" Sony IMX253, global shutter |
| Max resolution | 4096 × 3000 (12.3 MP); **pipeline uses 4096 × 2160** (NVENC H.265 limit) |
| Interface | USB 3.1 Gen1 - both camera and Orin NX are Gen1 only (~450 MB/s ceiling) |
| Max FPS | 30 fps hardware-fixed at full resolution |
| Pixel format | Must be `YCbCr422_8` (YUY2) - set in pylon Viewer, stored in camera |

**Why 4096×2160:** Orin NX NVENC supports H.265 up to Level 5.1 (~8.9 MP/frame). 4096×3000 = 12.3 MP exceeds this. 4096×2160 = 8.8 MP is the maximum encodable resolution.

**USB bandwidth:** Nominal YUY2 at 4096×2160/30fps = ~530 MB/s - exceeds the Gen1 ceiling but works in practice. The camera's Compression Beyond (hardware lossless FPGA compression) reduces actual USB payload by 2–3×. Enable in pylon Viewer: `ImageCompressionMode=BaslerCompressionBeyond`, `ImageCompressionRateOption=Lossless`.

---

## 2 - Bitrate Reference

NVENC hardware encoding lacks B-frames and multi-pass, so it needs ~20–30% more bits than software encoders for equivalent quality.

stream.conf defaults match the Recommended column.

### H.265 Main Profile (MAIN stream)

| Resolution | FPS | Streaming floor | Recommended | Quality ceiling |
|------------|-----|-----------------|-------------|-----------------|
| 4096 × 2160 | 30 | 16 Mbps | **20 Mbps** | 28 Mbps |
| 1920 × 1080 | 30 |  4 Mbps |  **6 Mbps** |  8 Mbps |

### H.264 High Profile (SUB stream)

| Resolution | FPS | Streaming floor | Recommended | Quality ceiling |
|------------|-----|-----------------|-------------|-----------------|
| 1920 × 1080 | 30 |  5 Mbps |  **6 Mbps** | 12 Mbps |

### Rate control and keyframe interval

**CBR** (`control-rate=1`) - recommended for RTSP; predictable network buffer usage.
**VBR** (`control-rate=2`) - better perceived quality; can spike 2–3× above average - use on private LAN only.

**Keyframe interval** default 15 frames (2 IDR/sec at 30fps). Shorter = faster stream join and loss recovery. Longer = lower overhead; avoid >2× framerate over WAN.

---

## 3 - Recommended Configurations

Both camera and Orin NX are USB 3.1 Gen1 only. Nominal YUY2 bandwidth at 4096×2160/30fps (~530 MB/s) exceeds the theoretical ceiling but works - Compression Beyond likely reduces actual USB payload to ~175–265 MB/s.

| Goal | Resolution | FPS | Nominal BW | Notes |
|------|------------|-----|------------|-------|
| **4K DCI (default)** | 4096 × 2160 | 30 | ~530 MB/s | Confirmed working (Compression Beyond likely active) |
| 4K UHD | 3840 × 2160 | 30 | ~498 MB/s | Within Gen1 ceiling |

This camera is hardware-fixed at 30 fps maximum - higher fps is not achievable at any resolution.

---

## 4 - GStreamer Notes

| Format | NVMM input | Pipeline path |
|--------|------------|---------------|
| YCbCr422_8 (YUY2) | YES | **Default** - pylonsrc NVMM → nvvidconv → NVENC |
| GRAY8 | YES | Mono path (not confirmed working) |
| BGR8 / RGB8 | NO | VIC hardware rejects packed RGB in NVMM mode |

**nvvidconv** converts YUY2 → NV12 via the VIC hardware block (`nvbuf-memory-type=4`). All downstream elements operate on NVMM buffers - zero CPU copies.

**Pixel format** must be configured in pylon Viewer (`PixelFormat → YCbCr422_8`) and is stored persistently in the camera. Without this, pylonsrc defaults to GRAY8 (monochrome).

---

## 5 - RTSP Client (Low Latency)

Pipeline sender contributes ~70–100 ms (camera exposure + NVENC). Most clients add a jitter buffer on top.

### VLC

Use `view_stream.ps1` / `view_stream.sh`, or manually:
```
vlc --rtsp-tcp --network-caching=200 --clock-synchro=0 --no-audio rtsp://HOST:8554/main
```

| Parameter | Effect |
|-----------|--------|
| `--rtsp-tcp` | Force RTP over TCP; prevents UDP loss artefacts |
| `--network-caching=200` | 200 ms jitter buffer - do not go below, VLC will drop frames |
| `--clock-synchro=0` | Disable VLC clock sync against the stream; avoids extra buffering |
| `--no-audio` | Suppress audio error messages; prevent audio buffering delay |

### GStreamer receiver

```bash
# MAIN (H.265) - software decode
gst-launch-1.0 rtspsrc location=rtsp://HOST:8554/main latency=200 protocols=tcp \
  ! rtph265depay ! h265parse ! avdec_h265 ! videoconvert ! autovideosink sync=false

# SUB (H.264) - software decode
gst-launch-1.0 rtspsrc location=rtsp://HOST:8554/sub latency=200 protocols=tcp \
  ! rtph264depay ! h264parse ! avdec_h264 ! videoconvert ! autovideosink sync=false

# Hardware decode on Jetson (nvv4l2decoder handles both H.264 and H.265)
gst-launch-1.0 rtspsrc location=rtsp://HOST:8554/main latency=200 protocols=tcp \
  ! rtph265depay ! h265parse ! nvv4l2decoder ! nv3dsink sync=false
```

Use `receive_stream.sh [main|sub]` for the above with the correct codec pre-configured.
