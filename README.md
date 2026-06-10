# Basler a2A4096-30ucPRO -- GStreamer Pipeline

**Camera:** Basler a2A4096-30ucPRO &nbsp;|&nbsp; **Target:** NVIDIA Jetson Orin NX (JetPack 5.x / 6.x)\
&nbsp;|&nbsp; **Script:** `send_stream.sh`

Zero-copy GStreamer pipeline capturing 4K (4096x2160) color (YUY2) from a 12 MP sensor
over USB3, encoding to H.264 or H.265 via NVENC hardware, and streaming over RTSP.
Includes a system health check script and a full bandwidth and bitrate reference for
this camera and interface.

Requires mediamtx running (to stream RTSP), sample config included in repo.
Optional ONVIF server stack (`onvif_simple_server` + `lighttpd`) for NVR auto-discovery.

---

## 0 - Quick Start

### Configuration
Edit **`stream.conf`** to set defaults (sourced by `send_stream.sh`):
- `MAIN_ENABLED` / `SUB_ENABLED` — enable/disable each stream
- `MAIN_ENCODER` / `SUB_ENCODER` — `h264` or `h265`
- `MAIN_BITRATE` / `SUB_BITRATE` — in bps
- `RTSP_HOST` / `RTSP_PORT` — MediaMTX server address
- `ONVIF_ENABLED` / `ONVIF_PORT` / `ONVIF_INTERFACE` — enable ONVIF server for NVR auto-discovery

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

When `ONVIF_ENABLED=true` in `stream.conf`, `send_stream.sh` automatically starts an ONVIF
server stack so NVRs (e.g. Dahua) can auto-discover and record without manual RTSP URL entry.

| Item | Value |
|------|-------|
| ONVIF device URL | `http://JETSON_IP:8080/onvif/device_service` |
| Auto-discovery | WS-Discovery on UDP 3702 — NVR scans LAN automatically |
| Profiles advertised | Profile_Main (H.265 4K `/main`), Profile_Sub (H.264 1080p `/sub`) |

The ONVIF stack is independent of MediaMTX — it only tells the NVR the RTSP URLs;
MediaMTX still serves the actual streams. The ONVIF conf is generated at runtime
from `stream.conf`, so codec, resolution, and paths are always correct.

**Prerequisites** (no prebuilt ARM64 binaries — must build from source):
```bash
# Build onvif_simple_server + wsd_simple_server
git clone https://github.com/roleoroleo/onvif_simple_server
# follow build instructions for aarch64

# Install lighttpd
sudo apt install lighttpd
```

Set `ONVIF_INTERFACE` in `stream.conf` to the network interface facing the NVR (default `eth0`).
The ONVIF conf is generated at runtime from `stream.conf` — codec, resolution, and RTSP paths
are always correct. Run `./start_onvif.sh` standalone or set `ONVIF_ENABLED=true` for
automatic lifecycle management via `send_stream.sh`.

---

## 1 - Basler Camera Specifications

| Property              | Value                                          |
|-----------------------|------------------------------------------------|
| Model                 | Basler a2A4096-30ucPRO                         |
| Sensor                | Sony IMX253 (global shutter CMOS)              |
| Max resolution        | 4096 x 3000 pixels (12.29 MP)                  |
| Sensor format         | 1/1.1 inch                                     |
| Pixel size            | 3.45 um x 3.45 um                              |
| Interface             | USB 3.1 Gen1 (5 Gbps)                          |
| Max FPS (full res)    | 30 fps (sensor limit)                          |
| Shutter type          | Global shutter (no rolling shutter artefact)   |
| ADC depth             | 12-bit                                         |
| Dynamic range         | ~73.4 dB                                       |
| Pixel formats (color) | BayerRG8/10/12/12Packed, RGB8, BGR8, YUV422    |
| PRO extras            | PTP (IEEE 1588) sync, Sequencer, extended I/O  |

The "30" in the model name specifies the maximum frame rate at full resolution.
The script uses YCbCr422_8 (YUY2) at 4096x2160 / 30fps = ~530 MB/s over USB 3.1 Gen1.
This exceeds the conservative Basler ceiling (~380 MB/s) but is confirmed working on the
BOXER-8651AI host controller. Camera framerate is hardware-fixed; caps are metadata only.

---

## 2 - USB Interface

| Standard     | Also known as         | Theoretical | Practical (Basler rated) |
|--------------|-----------------------|-------------|--------------------------|
| USB 3.1 Gen1 | USB 3.0, USB 3.2 Gen1 | 5 Gbps      | ~380 MB/s sustained      |

Practical bandwidth = effective payload rate after USB protocol overhead (~10%).

**Both camera and SoM are Gen1 only:**
- **a2A4096-30ucPRO:** USB 3.0 (5 Gbps) interface — Gen1 only, Micro-B connector with screw lock
- **Jetson Orin NX:** Gen1 ports only on the module itself

Gen2 (10 Gbps) is not available on either side and is not relevant to this setup.

**Feasibility key used in tables below:**

| Symbol | Meaning |
|--------|---------|
| OK     | Bandwidth <= 90% of ceiling -- clearly feasible |
| (~)    | Bandwidth 90-100% of ceiling -- borderline; depends on USB host controller quality, cable length (max 3 m for USB3), and host CPU load |
| NO     | Bandwidth exceeds ceiling -- not possible at that fps |

---

## 3 - Pixel Format USB Bandwidth Need at Full Resolution (4096 x 3000)

Bandwidth formula: `width x height x bytes_per_pixel x fps / 1,000,000`

- **B/px** = bytes per pixel transferred over USB
- **BW at 30fps** = USB bandwidth consumed at 30 fps (the camera rated maximum)
- (*) = sensor / firmware limit at 30 fps; not USB limited
- Both camera and SoM are Gen1 only (~380 MB/s Basler conservative ceiling)

| Format          | B/px | BW at 30fps | GStreamer support                    |
|-----------------|------|-------------|--------------------------------------|
| YCbCr422_8      | 2.00 |  737 MB/s*  | OK -- pipeline default (YUY2)        |
| BGR8 / RGB8     | 3.00 | 1106 MB/s   | NO -- VIC rejects BGR/RGB in NVMM    |

(*) Nominal at full 4096x3000. At 4096x2160/30fps = ~530 MB/s. Works on this system
likely due to Basler Compression Beyond lossless compression reducing actual USB payload.

**Key findings:**
- **YCbCr422_8 (YUY2) at 4096x2160 / 30fps = ~530 MB/s** -- exceeds theoretical Gen1
  ceiling but confirmed working. Compression Beyond likely reduces actual USB payload.
- BGR8/RGB8 are NOT supported by nvvidconv VIC hardware as NVMM input -- use YUY2.

---

## 4 - Encoding Bitrate Reference

> **NVENC hardware limit (H.265):** The Orin NX NVENC supports H.265 up to
> Level 5.1, which allows a maximum of **8,912,896 luma samples per frame
> (~8.9 MP)**. 4096 x 3000 = 12.3 MP exceeds this — a hard silicon limit,
> not a tuning issue. **4096 x 2160 = 8.8 MP is the maximum and script default.**

### H.264 vs H.265

**H.264 AVC, High Profile** (`profile=4`, `nvv4l2h264enc`):
- Universally supported by all players, browsers, NVR systems and hardware decoders
- Higher bitrate required for equivalent quality vs H.265
- Lower encode latency on NVENC -- preferred for sub-100 ms preview loops
- Use when client-side decoder compatibility is the primary requirement

**H.265 HEVC, Main Profile** (`profile=0`, `nvv4l2h265enc`):
- ~40-50% lower bitrate for equal perceived quality
- Preferred at 4K and above where bitrate savings are most significant
- Slightly higher encode latency (larger GOP processing)
- Recommended for archival or NVR where bitrate savings justify the higher decode requirement
- Verify your RTSP client / NVR supports H.265 before deploying

## 5-  Bitrate tables

### H.264 High Profile

- **Streaming** = acceptable for remote monitoring; minor artefacts possible in fast motion or high-detail areas under close inspection
- **High quality** = broadcast-level; artefacts not visible at normal viewing distance or during frame-by-frame inspection

Values assume moderate scene motion (factory floor, conveyor, monitoring).
Add ~30% for high-motion content. Subtract ~20% for essentially static scenes.

| Resolution  | FPS | Streaming | High quality | Notes               |
|-------------|-----|-----------|--------------|---------------------|
| 1920 x 1080 |  30 |   6 Mbps  |   12 Mbps    |                     |
| 1920 x 1080 |  60 |  10 Mbps  |   20 Mbps    |                     |
| 2592 x 1944 |  30 |  12 Mbps  |   22 Mbps    | 5 MP                |
| 3840 x 2160 |  30 |  25 Mbps  |   45 Mbps    | 4K UHD              |
| 4096 x 2160 |  30 |  28 Mbps  |   50 Mbps    | 4K DCI -- **SUB default (H.264)**          |

### H.265 Main Profile (recommended)

| Resolution  | FPS | Streaming | High quality | Notes                   |
|-------------|-----|-----------|--------------|-------------------------|
| 1920 x 1080 |  30 |   4 Mbps  |    8 Mbps    |                         |
| 1920 x 1080 |  60 |   6 Mbps  |   12 Mbps    |                         |
| 2592 x 1944 |  30 |   7 Mbps  |   14 Mbps    | 5 MP                    |
| 3840 x 2160 |  30 |  15 Mbps  |   28 Mbps    | 4K UHD                  |
| 4096 x 2160 |  30 |  16 Mbps  |   30 Mbps    | 4K DCI -- **MAIN default (H.265)**         |

### Rate control

**CBR (`control-rate=1`)** -- Constant bitrate. Recommended for RTSP delivery.
Keeps network buffer usage predictable and avoids playback stalls. Quality
drops slightly in complex frames.

**VBR (`control-rate=2`)** -- Variable bitrate. Better perceived quality;
allocates more bits to complex frames. Can produce momentary bandwidth spikes
2-3x above the average. Use on high-bandwidth private links or local NVR only.

### Keyframe interval

Script default is 15 (one iFrame every 15 frames). Set `IFRAME_INTERVAL = FRAMERATE` for 1 keyframe per second.

- Shorter interval: faster stream join and packet-loss recovery; higher overhead
- Longer interval: lower overhead; slower recovery -- avoid above 2x FRAMERATE for RTSP over WAN

---

## 6 - Recommended Configurations

Both camera and SoM are USB 3.1 Gen1 only. Nominal YUY2 bandwidth at 4096x2160/30fps
(~530 MB/s) exceeds the theoretical Gen1 ceiling but works in practice -- likely due to
Basler Compression Beyond lossless compression reducing actual USB payload to ~175-265 MB/s.

| Goal                       | Format      | Resolution  | FPS | Nominal BW | Notes                             |
|----------------------------|-------------|-------------|-----|------------|-----------------------------------|
| **4K DCI color (default)** | YCbCr422_8  | 4096 x 2160 |  30 | ~530 MB/s  | Confirmed working (Compression Beyond likely active (TBC!)) |
| 4K UHD color               | YCbCr422_8  | 3840 x 2160 |  30 |  498 MB/s  | OK                                |
| 1080p high fps             | YCbCr422_8  | 1920 x 1080 |  60 |  249 MB/s  | OK                                |

---

## 7 - GStreamer Element Compatibility

| Format          | GStreamer media type           | NVMM input | nvvidconv | Pipeline path               |
|-----------------|-------------------------------|------------|-----------|-----------------------------|
| YCbCr422_8      | video/x-raw,format=YUY2       | YES        | OK        | **pylonsrc->nvvidconv->enc (default)** |
| GRAY8 (mono)    | video/x-raw,format=GRAY8      | YES        | OK        | pylonsrc->nvvidconv->enc    |
| BGR8 / RGB8     | video/x-raw,format=BGR or RGB | NO         | n/a       | Not usable in NVMM mode     |

**USB buffer memory (`usbfs_memory_mb`):** The Linux kernel default is 16 MB.
The pylon SDK pre-allocates a ring of capture buffers (default: 10 buffers).
At 4096x2160 YUY2 NV12 that is 10 x ~18 MB = ~180 MB minimum. Set to **256 MB**
for a single camera (1.4x headroom), or 512 MB for two cameras on one host.
Basler's blanket recommendation of 1000 MB is sized for multi-camera setups
and is excessive for a single camera.

```bash
# Apply now (no reboot needed):
sudo sh -c 'echo 256 > /sys/module/usbcore/parameters/usbfs_memory_mb'

# Persist across reboots -- add to /etc/rc.local before 'exit 0':
echo 256 > /sys/module/usbcore/parameters/usbfs_memory_mb
```

---

**Basler Compression Beyond (lossless in-camera compression):**
The a2A4096-30ucPRO supports Compression Beyond — a hardware lossless codec in the
camera FPGA that reduces USB bandwidth by 2-3× depending on scene content. This may
explain why YUY2 at 4096x2160/30fps (~530 MB/s theoretical) works on USB 3.1 Gen1
(~450 MB/s physical ceiling): the actual USB transfer is compressed data, transparently
decompressed by pylonsrc before entering GStreamer.

Configure in pylon Viewer:
- `ImageCompressionMode` → `BaslerCompressionBeyond`
- `ImageCompressionRateOption` → `Lossless`

gst-plugin-pylon handles decompression automatically (added in v1.0, issue #98).
Check status: `gst-inspect-1.0 pylonsrc | grep -i compress`

---

**nvvidconv:** Accepts YUY2 (and other YUV formats) in NVMM and converts to NV12 in NVMM
using the VIC hardware block (`nvbuf-memory-type=4` = NVBUF_MEM_SURFACE_ARRAY). All
elements after nvvidconv operate on NVMM buffers with zero CPU copies. Note: packed
RGB formats (BGR8/RGB8) are NOT accepted by VIC as NVMM input -- use YUY2 instead.

---

## 8 - RTSP Client Configuration (Low Latency)

The pipeline sender contributes ~60-100ms of latency (camera exposure + NVENC H.264 ULL preset).
Most RTSP players add a large jitter buffer on top by default and must be tuned.

| Source          | Latency         |
|-----------------|-----------------|
| Camera + USB    | ~33ms           |
| nvvidconv + enc | ~33-66ms        |
| Sender total    | ~72-106ms       |
| VLC buffer      | 200ms           |
| H.264 decode    | ~10-20ms        |
| **Total**       | **~282-326ms**  |

### VLC (recommended for quick testing)

Use the provided `view_stream.ps1` (Windows) or `view_stream.sh` (Linux) scripts, or manually:

```
vlc --rtsp-tcp --network-caching=200 --clock-synchro=0 --no-audio rtsp://192.168.1.252:8554/main
```

| Parameter               | Effect |
|-------------------------|--------|
| `--rtsp-tcp`            | Force RTP over TCP. Matches the sender (`protocols=tcp`). Prevents UDP packet loss artefacts. |
| `--network-caching=200` | Jitter buffer in ms. 200ms confirmed minimum for H.265; H.264 is stable at 200ms. Do not go below 200ms -- VLC will drop frames. |
| `--clock-synchro=0`     | Disables VLC clock sync against the stream. Without this, VLC accumulates extra buffer trying to lock to a clock signal that a live RTSP stream may not provide. |
| `--no-audio`            | Suppresses audio-track error messages (video-only stream) and prevents audio buffering from adding delay. |

For H.265 streams verify VLC has a working H.265 decoder:
`VLC -> Tools -> Codec Information` -- look for HEVC or H.265 in the Codec field.
Modern VLC (3.x+) includes H.265 support on all platforms.

### GStreamer receiver (same machine or another Jetson)

Software decode (any Linux machine):

**MAIN stream (H.265 default)** — software decode:
```bash
gst-launch-1.0 \
  rtspsrc location=rtsp://192.168.1.252:8554/main latency=200 protocols=tcp \
  ! rtph265depay ! h265parse ! avdec_h265 ! videoconvert ! autovideosink sync=false
```

**SUB stream (H.264 default)** — software decode:
```bash
gst-launch-1.0 \
  rtspsrc location=rtsp://192.168.1.252:8554/sub latency=200 protocols=tcp \
  ! rtph264depay ! h264parse ! avdec_h264 ! videoconvert ! autovideosink sync=false
```

Hardware decode on Jetson (nvv4l2decoder handles both H.264 and H.265):
```bash
# MAIN (H.265)
gst-launch-1.0 rtspsrc location=rtsp://192.168.1.252:8554/main latency=200 protocols=tcp \
  ! rtph265depay ! h265parse ! nvv4l2decoder ! nv3dsink sync=false

# SUB (H.264)
gst-launch-1.0 rtspsrc location=rtsp://192.168.1.252:8554/sub latency=200 protocols=tcp \
  ! rtph264depay ! h264parse ! nvv4l2decoder ! nv3dsink sync=false
```

Use `receive_stream.sh main` or `receive_stream.sh sub` for the above with correct codec pre-configured.

| Parameter      | Effect |
|----------------|--------|
| `latency=200`  | Jitter buffer in ms on the rtspsrc element. Equivalent to VLC `--network-caching`. 200ms is reliable on LAN. |
| `protocols=tcp`| Force TCP transport, matching the sender. |
| `sync=false`   | Sink runs as fast as frames arrive rather than pacing to a presentation clock. Removes one additional source of delay. |

---

## 9 - Camera Pixel Format Configuration

The pipeline uses YCbCr422_8 (YUY2) -- the only color format that works in NVMM mode
with nvvidconv on Jetson. Configure via pylon Viewer (persistent, stored in camera):

| Method       | Setting |
|--------------|---------|
| pylon Viewer | Camera Features → PixelFormat → YCbCr422_8 |
| Script       | `PIXEL_FORMAT=YUY2` (default, do not change) |

**Note:** pylonsrc does not expose a GStreamer property for pixel format -- it must be
set in pylon Viewer or via the camera's persistent user set. Without explicit format
constraint in caps, pylonsrc defaults to GRAY8 (monochrome).

NOTE: the Gray8 pipeline has NOT yet been confirmed working!
