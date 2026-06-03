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
| Max FPS (full res)    | 30 fps -- BayerRG8 only on Gen1 (sensor limit) |
| Shutter type          | Global shutter (no rolling shutter artefact)   |
| ADC depth             | 12-bit                                         |
| Dynamic range         | ~73.4 dB                                       |
| Pixel formats (color) | BayerRG8/10/12/12Packed, RGB8, BGR8, YUV422    |
| PRO extras            | PTP (IEEE 1588) sync, Sequencer, extended I/O  |

The "30" in the model name specifies the maximum frame rate at full resolution
over USB 3.1 Gen1. This rate is achievable ONLY with BayerRG8 (1 byte/px =
369 MB/s -- just inside the Gen1 practical ceiling of ~380 MB/s).
The script runs at 30 fps (camera hardware-fixed rate; framerate caps are metadata only).

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
- BayerRG8 is the ONLY format that reaches the camera-rated 30 fps on Gen1,
  and only just barely (~97% of the ceiling). Use 25 fps for headroom.
- All debayered and high-bit-depth formats require Gen2 for 30 fps operation.
- BGR8/RGB8 at 30 fps exceeds even Gen2. Maximum is ~21 fps on Gen2.
- BayerRG12Packed fits bandwidth-wise on Gen2 at 30 fps but requires a custom
  GStreamer debayer plugin -- stock `bayer2rgb` handles 8-bit only.

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

| Goal                | Format   | Resolution  | FPS | Bandwidth | Notes                      |
|---------------------|----------|-------------|-----|-----------|----------------------------|
| 4K DCI bayer        | BayerRG8 | 4096 x 2160 |  25 | 221 MB/s  | OK -- Gen1 bayer option    |
| 12 MP standard      | BayerRG8 | 4096 x 3000 |  25 | 307 MB/s  | OK                         |
| 12 MP max rated fps | BayerRG8 | 4096 x 3000 |  30 | 369 MB/s  | (~) -- verify USB host     |
| 5 MP high fps       | BayerRG8 | 2592 x 1944 |  60 | 302 MB/s  | OK                         |
| 4K standard         | BGR8     | 3840 x 2160 |  14 | 348 MB/s  | OK -- no debayer CPU cost  |
| 4K 30fps            | BayerRG8 | 3840 x 2160 |  30 | 249 MB/s  | OK                         |
| 1080p high fps      | BayerRG8 | 1920 x 1080 | 120 | 249 MB/s  | OK                         |

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

| Format          | GStreamer media type           | bayer2rgb | nvvidconv | Pipeline path              |
|-----------------|-------------------------------|-----------|-----------|----------------------------|
| BayerRG8        | video/x-bayer,format=rggb     | OK        | NO direct | pylonsrc->bayer2rgb->nvvid |
| BayerRG12Packed | video/x-bayer (non-standard)  | NO        | NO        | custom plugin required     |
| BayerRG10/12    | video/x-bayer (non-standard)  | NO        | NO        | custom plugin required     |
| BGR8 / RGB8     | video/x-raw,format=BGR or RGB | n/a       | OK direct | pylonsrc->nvvidconv->enc   |
| YCbCr422_8      | video/x-raw,format=YUY2       | n/a       | OK direct | pylonsrc->nvvidconv->enc   |
| GRAY8 (mono)    | video/x-raw,format=GRAY8      | n/a       | OK direct | pylonsrc->nvvidconv->enc   |

**USB buffer memory (`usbfs_memory_mb`):** The Linux kernel default is 16 MB.
The pylon SDK pre-allocates a ring of capture buffers (default: 10 buffers).
At 12 MP BayerRG8 that is 10 x 12.3 MB = ~123 MB minimum. Set to **256 MB**
for a single camera (2x headroom), or 512 MB for two cameras on one host.
Basler's blanket recommendation of 1000 MB is sized for multi-camera setups
and is excessive for a single camera.

```bash
# Apply now (no reboot needed):
sudo sh -c 'echo 256 > /sys/module/usbcore/parameters/usbfs_memory_mb'

# Persist across reboots -- add to /etc/rc.local before 'exit 0':
echo 256 > /sys/module/usbcore/parameters/usbfs_memory_mb
```

---

**nvvidconv:** Input must be in system RAM (`video/x-raw` without NVMM qualifier).
Output is placed in NVMM (`video/x-raw(memory:NVMM)`) using `nvbuf-memory-type=4`
(NVBUF_MEM_SURFACE_ARRAY -- the correct Jetson surface type). All elements after
nvvidconv access NVMM directly with zero additional CPU copies.

**bayer2rgb:** Standard GStreamer element from `gst-plugins-bad`. Implements
bilinear Bayer demosaic in software using NEON SIMD on A78AE cores. At 12MP x 25fps
(~300 Mpx/s) this uses approximately 1-2 CPU cores. For more than two simultaneous
cameras, a custom CUDA-based debayer element should be considered.

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

## 8 - Notes on 12-bit Bayer over Gen1

BayerRG12Packed at 4096x3000 x 25fps = ~461 MB/s, which exceeds the Gen1
practical ceiling of ~380 MB/s. Not feasible on Gen1.

If 12-bit dynamic range is required on Gen1, configure the pylon SDK to perform
in-camera debayering and output BGR8/RGB8. The camera FPGA handles the demosaic
and sends the result over USB. This trades bandwidth savings for 3 bytes/pixel.

To configure in-camera debayering:

| Method       | Setting |
|--------------|---------|
| pylon Viewer | Camera Features -> PixelFormat -> YCbCr422_8 (YUY2, recommended) or BGR8 |
| GenICam      | `PixelFormat = "YCbCr422_8"` (or `"BGR8"`, `"RGB8"`) |
| Script       | `PIXEL_FORMAT=YUY2` (default) -- must be VIC-compatible in NVMM (not BGR/RGB) |
