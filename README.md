# Basler a2A4096-30ucPRO -- GStreamer Pipeline Reference

**Camera:** Basler a2A4096-30ucPRO &nbsp;|&nbsp; **Target:** NVIDIA Jetson Orin NX (JetPack 5.x / 6.x) &nbsp;|&nbsp; **Script:** `basler_pipeline.sh`

Zero-copy GStreamer pipeline capturing 12 MP color (YUY2) over USB3, encoding to H.264
via NVENC hardware, and streaming over RTSP. Includes a system health check script
and a full bandwidth and bitrate reference for this camera and interface.

---

## 1 - Camera Specifications

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
| USB 3.1 Gen2 | USB 3.2 Gen2          | 10 Gbps     | ~800 MB/s sustained      |

Practical bandwidth = effective payload rate after USB protocol overhead (~10%).

**Jetson Orin NX:** The module provides USB 3.1 Gen1 ports only. Gen2 (10 Gbps)
requires a carrier board with a PCIe-attached USB 3.2 Gen2 host controller
(e.g. reference carrier + VL805 or ASM3142).

**Feasibility key used in tables below:**

| Symbol | Meaning |
|--------|---------|
| OK     | Bandwidth <= 90% of ceiling -- clearly feasible |
| (~)    | Bandwidth 90-100% of ceiling -- borderline; depends on USB host controller quality, cable length (max 3 m for USB3), and host CPU load |
| NO     | Bandwidth exceeds ceiling -- not possible at that fps |

---

## 3 - Pixel Format Bandwidth at Full Resolution (4096 x 3000)

Bandwidth formula: `width x height x bytes_per_pixel x fps / 1,000,000`

- **B/px** = bytes per pixel transferred over USB
- **BW at 30fps** = USB bandwidth consumed at 30 fps (the camera rated maximum)
- **Gen1 max** = maximum achievable fps on USB 3.1 Gen1 (~380 MB/s)
- **Gen2 max** = maximum achievable fps on USB 3.1 Gen2 (~800 MB/s)
- (*) = sensor / firmware limit at 30 fps; not USB limited

| Format          | B/px | BW at 30fps | Gen1 max fps | Gen2 max fps | GStreamer support        |
|-----------------|------|-------------|--------------|--------------|--------------------------|
| BayerRG8        | 1.00 |  369 MB/s   |  30  (~)     |  30  (*)     | OK  via bayer2rgb        |
| BayerRG12Packed | 1.50 |  553 MB/s   |  20  NO      |  30  (*)     | NO  (custom plugin req.) |
| BayerRG10       | 2.00 |  737 MB/s   |  15  NO      |  30  (*)     | NO  (custom plugin req.) |
| BayerRG12       | 2.00 |  737 MB/s   |  15  NO      |  30  (*)     | NO  (custom plugin req.) |
| YCbCr422_8      | 2.00 |  737 MB/s   |  15  NO      |  30  (*)     | OK  nvvidconv direct     |
| BGR8 / RGB8     | 3.00 | 1106 MB/s   |  10  NO      |  21  NO      | OK  nvvidconv direct     |

**Key findings:**
- **YCbCr422_8 (YUY2) at 4096x2160 / 30fps = ~530 MB/s** -- exceeds the theoretical Gen1
  ceiling but confirmed working on BOXER-8651AI. This is the pipeline default format.
- BGR8/RGB8 are NOT supported by nvvidconv VIC hardware as NVMM input -- use YUY2.
- BGR8/RGB8 at 30 fps exceeds even Gen2. Maximum is ~21 fps on Gen2.

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

### Bitrate table -- H.264 High Profile

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
| 3840 x 2160 |  60 |  40 Mbps  |   70 Mbps    | 4K UHD, Gen2 only                          |
| 4096 x 2160 |  30 |  28 Mbps  |   50 Mbps    | 4K DCI -- **script default (H.264)**       |
| 4096 x 3000 |  25 |  35 Mbps  |   62 Mbps    | 12 MP full sensor (Level 6.0 req.)         |
| 4096 x 3000 |  30 |  42 Mbps  |   74 Mbps    | 12 MP full sensor (Level 6.0 req.), Gen2   |

### Bitrate table -- H.265 Main Profile (recommended for 12MP)

| Resolution  | FPS | Streaming | High quality | Notes                   |
|-------------|-----|-----------|--------------|-------------------------|
| 1920 x 1080 |  30 |   4 Mbps  |    8 Mbps    |                         |
| 1920 x 1080 |  60 |   6 Mbps  |   12 Mbps    |                         |
| 2592 x 1944 |  30 |   7 Mbps  |   14 Mbps    | 5 MP                    |
| 3840 x 2160 |  30 |  15 Mbps  |   28 Mbps    | 4K UHD                  |
| 3840 x 2160 |  60 |  22 Mbps  |   40 Mbps    | 4K UHD, Gen2 only                          |
| 4096 x 2160 |  30 |  16 Mbps  |   30 Mbps    | 4K DCI (--h265 flag)                       |
| 4096 x 3000 |  25 |  20 Mbps  |   38 Mbps    | 12 MP full sensor (Level 6.0 req.)         |
| 4096 x 3000 |  30 |  25 Mbps  |   45 Mbps    | 12 MP full sensor (Level 6.0 req.), Gen2   |

### Rate control

**CBR (`control-rate=1`)** -- Constant bitrate. Recommended for RTSP delivery.
Keeps network buffer usage predictable and avoids playback stalls. Quality
drops slightly in complex frames.

**VBR (`control-rate=2`)** -- Variable bitrate. Better perceived quality;
allocates more bits to complex frames. Can produce momentary bandwidth spikes
2-3x above the average. Use on high-bandwidth private links or local NVR only.

### Keyframe interval

Set `IFRAME_INTERVAL = FRAMERATE` for 1 keyframe per second (30 at 30 fps -- the script default).

- Shorter interval: faster stream join and packet-loss recovery; higher overhead
- Longer interval: lower overhead; slower recovery -- avoid above 2x FRAMERATE for RTSP over WAN

---

## 5 - Recommended Configurations

**Note:** Color mode (YUY2) at 4096 x 2160 x 30fps = ~530 MB/s — confirmed working on BOXER-8651AI Gen1 host controller despite exceeding the conservative Basler ~380 MB/s ceiling.

### USB 3.1 Gen1 -- Jetson Orin NX onboard ports

| Goal                    | Format      | Resolution  | FPS | Bandwidth | Notes                             |
|-------------------------|-------------|-------------|-----|-----------|-----------------------------------|
| **4K DCI color (default)** | YCbCr422_8 | 4096 x 2160 | 30 | ~530 MB/s | Confirmed working on BOXER-8651AI |
| 4K UHD color            | YCbCr422_8  | 3840 x 2160 |  30 | 498 MB/s  | OK                                |
| 1080p high fps          | YCbCr422_8  | 1920 x 1080 |  60 | 249 MB/s  | OK                                |

### USB 3.1 Gen2 -- carrier board PCIe USB controller

| Goal                    | Format        | Resolution  | FPS | Bandwidth | Notes                      |
|-------------------------|---------------|-------------|-----|-----------|----------------------------|
| 4K DCI color (default)  | YCbCr422_8    | 4096 x 2160 |  30 | 530 MB/s  | OK -- zero-copy NVMM       |
| 12 MP at 30 fps         | BayerRG8      | 4096 x 3000 |  30 | 369 MB/s  | OK -- sensor limit         |
| 12 MP 12-bit at 20 fps  | BayerRG12Pack | 4096 x 3000 |  20 | 369 MB/s  | OK -- custom debayer req.  |
| 4K all formats          | BayerRG12Pack | 3840 x 2160 |  30 | 373 MB/s  | (~) -- custom debayer req. |
| 4K 30fps color          | YCbCr422_8    | 3840 x 2160 |  30 | 498 MB/s  | OK -- nvvidconv direct     |
| 1080p max fps           | BayerRG8      | 1920 x 1080 | 240 | 498 MB/s  | OK -- NVENC limit: 240fps  |

---

## 6 - GStreamer Element Compatibility

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

**nvvidconv:** Accepts YUY2 (and other YUV formats) in NVMM and converts to NV12 in NVMM
using the VIC hardware block (`nvbuf-memory-type=4` = NVBUF_MEM_SURFACE_ARRAY). All
elements after nvvidconv operate on NVMM buffers with zero CPU copies. Note: packed
RGB formats (BGR8/RGB8) are NOT accepted by VIC as NVMM input -- use YUY2 instead.

---

## 7 - RTSP Client Configuration (Low Latency)

The pipeline sender contributes ~60-100ms of latency (camera exposure + NVENC H.264 ULL preset).
Most RTSP players add a large jitter buffer on top by default and must be tuned.

| Source          | Latency        |
|-----------------|----------------|
| Camera + USB    | ~33ms          |
| nvvidconv + enc | ~20-40ms       |
| Sender total    | ~55-75ms       |
| VLC buffer      | 200ms          |
| H.264 decode    | ~10-20ms       |
| **Total**       | **~265-295ms** |

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

```bash
gst-launch-1.0 \
  rtspsrc location=rtsp://192.168.1.252:8554/main latency=200 protocols=tcp \
  ! rtph264depay \
  ! h264parse \
  ! avdec_h264 \
  ! videoconvert \
  ! autovideosink sync=false
```

Hardware decode (receiving Jetson with NVDEC):

```bash
gst-launch-1.0 \
  rtspsrc location=rtsp://192.168.1.252:8554/main latency=200 protocols=tcp \
  ! rtph264depay \
  ! h264parse \
  ! nvv4l2decoder \
  ! nv3dsink sync=false
```

For H.265 streams (when using `--h265` flag) replace `rtph264depay`, `h264parse`, `avdec_h264` with
`rtph265depay`, `h265parse`, `avdec_h265` (or keep `nvv4l2decoder` -- it handles both codecs).

| Parameter      | Effect |
|----------------|--------|
| `latency=200`  | Jitter buffer in ms on the rtspsrc element. Equivalent to VLC `--network-caching`. 200ms is reliable on LAN. |
| `protocols=tcp`| Force TCP transport, matching the sender. |
| `sync=false`   | Sink runs as fast as frames arrive rather than pacing to a presentation clock. Removes one additional source of delay. |

---

## 8 - Camera Pixel Format Configuration

The pipeline uses YCbCr422_8 (YUY2) -- the only color format that works in NVMM mode
with nvvidconv on Jetson. Configure via pylon Viewer (persistent, stored in camera):

| Method       | Setting |
|--------------|---------|
| pylon Viewer | Camera Features → PixelFormat → YCbCr422_8 |
| Script       | `PIXEL_FORMAT=YUY2` (default, do not change) |

**Note:** pylonsrc does not expose a GStreamer property for pixel format -- it must be
set in pylon Viewer or via the camera's persistent user set. Without explicit format
constraint in caps, pylonsrc defaults to GRAY8 (monochrome).
