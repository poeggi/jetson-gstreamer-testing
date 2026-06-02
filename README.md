# Basler a2A4096-30ucPRO -- GStreamer Pipeline Reference
# NVIDIA Jetson Orin NX

==============================================================================
Camera: Basler a2A4096-30ucPRO
Target: NVIDIA Jetson Orin NX (JetPack 5.x / 6.x)
Script: basler_pipeline.sh
==============================================================================


## 1 - Camera Specifications

| Property               | Value                                          |
|------------------------|------------------------------------------------|
| Model                  | Basler a2A4096-30ucPRO                         |
| Sensor                 | Sony IMX253 (global shutter CMOS)              |
| Max resolution         | 4096 x 3000 pixels (12.29 MP)                  |
| Sensor format          | 1/1.1 inch                                     |
| Pixel size             | 3.45 um x 3.45 um                              |
| Interface              | USB 3.1 Gen1 (5 Gbps)                          |
| Max FPS (full res)     | 30 fps -- BayerRG8 only on Gen1 (sensor limit) |
| Shutter type           | Global shutter (no rolling shutter artefact)   |
| ADC depth              | 12-bit                                         |
| Dynamic range          | ~73.4 dB                                       |
| Pixel formats (color)  | BayerRG8/10/12/12Packed, RGB8, BGR8, YUV422    |
| PRO extras             | PTP (IEEE 1588) sync, Sequencer, extended I/O  |

Note: the "30" in the model name specifies the maximum frame rate at full
resolution over USB 3.1 Gen1. This rate is achievable ONLY with BayerRG8
(1 byte/px = 369 MB/s -- just inside the Gen1 practical ceiling of ~380 MB/s).
Our script defaults to 25 fps to provide comfortable headroom on Gen1.


## 2 - USB Interface

| Standard      | Also known as         | Theoretical | Practical (Basler rated) |
|---------------|-----------------------|-------------|--------------------------|
| USB 3.1 Gen1  | USB 3.0, USB 3.2 Gen1 | 5 Gbps      | ~380 MB/s sustained      |
| USB 3.1 Gen2  | USB 3.2 Gen2          | 10 Gbps     | ~800 MB/s sustained      |

Theoretical bandwidth = raw link speed.
Practical bandwidth = effective payload rate after USB protocol overhead (~10 %).

Jetson Orin NX note:
  The module provides USB 3.1 Gen1 ports only.
  Gen2 (10 Gbps) requires a carrier board with a PCIe-attached USB 3.2 Gen2
  host controller (e.g. Jetson Orin NX reference carrier + VL805 or ASM3142).

Feasibility key used in tables below:
  OK   = bandwidth <= 90% of ceiling -- clearly feasible
  (~)  = bandwidth 90-100% of ceiling -- borderline; depends on USB host
         controller quality, cable length (max 3 m for USB3), and host CPU load
  NO   = bandwidth exceeds ceiling -- not possible at that fps


## 3 - Pixel Format Bandwidth at Full Resolution (4096 x 3000)

Bandwidth formula: width x height x bytes_per_pixel x fps / 1,000,000

Columns:
  B/px        = bytes per pixel transferred over USB
  BW at 30fps = USB bandwidth consumed at 30 fps (the camera rated maximum)
  Gen1 max    = maximum achievable fps on USB 3.1 Gen1 (~380 MB/s)
  Gen2 max    = maximum achievable fps on USB 3.1 Gen2 (~800 MB/s)
               (*) = sensor / firmware limit at 30 fps; not USB limited

| Format           | B/px | BW at 30fps | Gen1 max fps | Gen2 max fps | GStreamer support        |
|------------------|------|-------------|--------------|--------------|--------------------------|
| BayerRG8         | 1.00 |  369 MB/s   |  30  (~)     |  30  (*)     | OK  via bayer2rgb        |
| BayerRG12Packed  | 1.50 |  553 MB/s   |  20  NO      |  30  (*)     | NO  (custom plugin req.) |
| BayerRG10        | 2.00 |  737 MB/s   |  15  NO      |  30  (*)     | NO  (custom plugin req.) |
| BayerRG12        | 2.00 |  737 MB/s   |  15  NO      |  30  (*)     | NO  (custom plugin req.) |
| YCbCr422_8       | 2.00 |  737 MB/s   |  15  NO      |  30  (*)     | OK  nvvidconv direct     |
| BGR8 / RGB8      | 3.00 | 1106 MB/s   |  10  NO      |  21  NO      | OK  nvvidconv direct     |

Key findings:
  - BayerRG8 is the ONLY format that reaches the camera-rated 30 fps on Gen1,
    and only just barely (~97% of the Gen1 ceiling).  Use 25 fps for headroom.
  - All debayered and high-bit-depth formats require Gen2 for 30 fps operation.
  - BGR8/RGB8 at 30 fps exceeds even Gen2. Maximum is ~21 fps on Gen2.
  - BayerRG12Packed bandwidth-wise fits on Gen2 at 30 fps but requires a custom
    GStreamer debayer plugin -- stock bayer2rgb handles 8-bit only.


## 4 - Encoding Bitrate Reference

### H.264 vs H.265 overview

H.264 AVC, High Profile (profile=4, nvv4l2h264enc):
  - Universally supported by all players, browsers, NVR systems and hardware
  - Higher bitrate required for equivalent quality vs H.265
  - Lower encode latency on NVENC -- preferred for sub-100 ms preview loops
  - Use when client-side decoder compatibility is a requirement

H.265 HEVC, Main Profile (profile=0, nvv4l2h265enc):
  - ~40-50% lower bitrate for equal perceived quality
  - Preferred at 4K and above where bitrate savings are most significant
  - Slightly higher encode latency (larger GOP processing)
  - Recommended for this project (12MP at 25fps, see script default)
  - Verify your RTSP client / NVR supports H.265 before deploying

### Bitrate table -- H.264 High Profile

"Streaming"    = acceptable for remote monitoring; minor artefacts possible in
                 fast motion or high-detail areas under close inspection.
"High quality" = broadcast-level; artefacts not visible at normal viewing distance
                 or during frame-by-frame inspection.

Values assume moderate scene motion (factory floor, conveyor, monitoring).
Add ~30% for high-motion content. Subtract ~20% for essentially static scenes.

| Resolution    | FPS | Streaming | High quality | Notes                   |
|---------------|-----|-----------|--------------|-------------------------|
| 1920 x 1080   |  30 |   6 Mbps  |   12 Mbps    |                         |
| 1920 x 1080   |  60 |  10 Mbps  |   20 Mbps    |                         |
| 2592 x 1944   |  30 |  12 Mbps  |   22 Mbps    | 5 MP                    |
| 3840 x 2160   |  30 |  25 Mbps  |   45 Mbps    | 4K UHD                  |
| 3840 x 2160   |  60 |  40 Mbps  |   70 Mbps    | 4K UHD, Gen2 only       |
| 4096 x 3000   |  25 |  35 Mbps  |   62 Mbps    | 12 MP (this camera)     |
| 4096 x 3000   |  30 |  42 Mbps  |   74 Mbps    | 12 MP, Gen2 only        |

### Bitrate table -- H.265 Main Profile (recommended for 12MP)

| Resolution    | FPS | Streaming | High quality | Notes                   |
|---------------|-----|-----------|--------------|-------------------------|
| 1920 x 1080   |  30 |   4 Mbps  |    8 Mbps    |                         |
| 1920 x 1080   |  60 |   6 Mbps  |   12 Mbps    |                         |
| 2592 x 1944   |  30 |   7 Mbps  |   14 Mbps    | 5 MP                    |
| 3840 x 2160   |  30 |  15 Mbps  |   28 Mbps    | 4K UHD                  |
| 3840 x 2160   |  60 |  22 Mbps  |   40 Mbps    | 4K UHD, Gen2 only       |
| 4096 x 3000   |  25 |  20 Mbps  |   38 Mbps    | 12 MP -- script default |
| 4096 x 3000   |  30 |  25 Mbps  |   45 Mbps    | 12 MP, Gen2 only        |

### Rate control (CONTROL_RATE in script)

  CBR (control-rate=1)  Constant bitrate.
      Recommended for RTSP delivery. Keeps network buffer usage predictable
      and avoids playback stalls. Quality drops slightly in complex frames.

  VBR (control-rate=2)  Variable bitrate.
      Better perceived quality -- allocates more bits to complex frames.
      Can produce momentary bandwidth spikes 2-3x above the average bitrate.
      Use when streaming over a high-bandwidth private link or to a local NVR.

### Keyframe interval (IFRAME_INTERVAL in script)

  Recommendation: set IFRAME_INTERVAL = FRAMERATE (1 keyframe per second).
  This means 25 for 25 fps -- the script default.

  Shorter interval -> faster stream join and packet-loss recovery; higher overhead.
  Longer interval -> lower overhead; slower recovery; avoid for RTSP over WAN.
  For stable LAN: 2x FRAMERATE is acceptable.


## 5 - Recommended Configurations

### USB 3.1 Gen1 -- Jetson Orin NX onboard ports

| Goal                 | Format    | Resolution    | FPS | Bandwidth  | Notes                       |
|----------------------|-----------|---------------|-----|------------|-----------------------------|
| 12 MP standard       | BayerRG8  | 4096 x 3000   |  25 |  307 MB/s  | OK  -- script default       |
| 12 MP max rated fps  | BayerRG8  | 4096 x 3000   |  30 |  369 MB/s  | (~) -- verify USB host      |
| 5 MP high fps        | BayerRG8  | 2592 x 1944   |  60 |  302 MB/s  | OK                          |
| 4K standard          | BGR8      | 3840 x 2160   |  14 |  348 MB/s  | OK  -- no debayer CPU cost  |
| 4K 30fps             | BayerRG8  | 3840 x 2160   |  30 |  249 MB/s  | OK                          |
| 1080p high fps       | BayerRG8  | 1920 x 1080   | 120 |  249 MB/s  | OK                          |

### USB 3.1 Gen2 -- carrier board PCIe USB controller

| Goal                 | Format        | Resolution    | FPS | Bandwidth  | Notes                       |
|----------------------|---------------|---------------|-----|------------|-----------------------------|
| 12 MP at 30 fps      | BayerRG8      | 4096 x 3000   |  30 |  369 MB/s  | OK  -- sensor limit         |
| 12 MP 12-bit 20 fps  | BayerRG12Pack | 4096 x 3000   |  20 |  369 MB/s  | OK  -- custom debayer req.  |
| 4K all formats       | BayerRG12Pack | 3840 x 2160   |  30 |  373 MB/s  | (~) -- custom debayer req.  |
| 4K 30fps color       | YCbCr422_8    | 3840 x 2160   |  30 |  498 MB/s  | OK  -- nvvidconv direct     |
| 1080p max fps        | BayerRG8      | 1920 x 1080   | 240 |  498 MB/s  | OK  -- NVENC limit: 240fps  |


## 6 - GStreamer Element Compatibility

| Format          | GStreamer media type            | bayer2rgb | nvvidconv | Pipeline path               |
|-----------------|--------------------------------|-----------|-----------|-----------------------------|
| BayerRG8        | video/x-bayer,format=rggb      | OK        | NO direct | pylonsrc->bayer2rgb->nvvid  |
| BayerRG12Packed | video/x-bayer (non-standard)   | NO        | NO        | custom plugin required      |
| BayerRG10/12    | video/x-bayer (non-standard)   | NO        | NO        | custom plugin required      |
| BGR8 / RGB8     | video/x-raw,format=BGR or RGB  | n/a       | OK direct | pylonsrc->nvvidconv->enc    |
| YCbCr422_8      | video/x-raw,format=YUY2        | n/a       | OK direct | pylonsrc->nvvidconv->enc    |
| GRAY8 (mono)    | video/x-raw,format=GRAY8       | n/a       | OK direct | pylonsrc->nvvidconv->enc    |

nvvidconv note:
  nvvidconv input must be in system RAM (video/x-raw without NVMM qualifier).
  nvvidconv output is placed in NVMM (video/x-raw(memory:NVMM)) using
  nvbuf-memory-type=4 (NVBUF_MEM_SURFACE_ARRAY) -- the correct Jetson type.
  All elements after nvvidconv (encoder, payloader, sink) access NVMM directly
  with zero additional CPU copies.

bayer2rgb note:
  Standard GStreamer element from gst-plugins-bad.
  Implements bilinear Bayer demosaic in software using NEON SIMD on A78AE cores.
  At 12MP x 25fps (~300 Mpx/s) this uses approximately 1-2 CPU cores.
  For more than two simultaneous cameras, a custom CUDA-based debayer element
  should be considered to offload the demosaic to the GPU.


## 7 - RTSP Client Configuration (Low Latency)

The pipeline sender contributes ~85-130ms of latency (camera exposure + NVENC).
Most RTSP players add a large jitter buffer on top by default. This must be
reduced manually or the perceived latency will be 1-2 seconds regardless of
how well the sender performs.

Expected total latency with the settings below:
  Sender pipeline      ~85-130ms
  Receiver buffer      ~200-300ms
  --------------------------------
  Total                ~300-430ms   (well below 1 second)


### VLC (recommended for quick testing)

Single-line, copy-paste ready -- replace the URL if needed:

  vlc --rtsp-tcp --network-caching=300 --clock-synchro=0 --no-audio rtsp://127.0.0.1:8554/stream

Parameter reference:
  --rtsp-tcp          Force RTP over TCP. Matches the sender (protocols=tcp).
                      Prevents UDP packet loss causing decoder artefacts.
  --network-caching=300
                      Jitter buffer in milliseconds. 300ms is stable on a
                      direct LAN connection. Lower to 150ms on loopback only.
                      Do NOT go below 100ms -- VLC will stutter under any load.
  --clock-synchro=0   Disables VLC clock synchronisation against the stream.
                      Without this, VLC accumulates extra buffer trying to lock
                      to a clock signal that a live RTSP stream may not provide.
  --no-audio          Suppresses audio-track error messages (our stream is
                      video only) and prevents audio buffering from adding delay.

For H.265 streams, verify VLC has a working H.265 decoder:
  VLC -> Tools -> Codec Information -> look for HEVC or H.265 in the Codec field.
  Modern VLC (3.x+) includes H.265 support on all platforms.


### GStreamer receiver (same machine or another Jetson)

Software decode (any Linux machine with GStreamer):

  gst-launch-1.0 \
    rtspsrc location=rtsp://127.0.0.1:8554/stream latency=200 protocols=tcp \
    ! rtph265depay \
    ! h265parse \
    ! avdec_h265 \
    ! videoconvert \
    ! autovideosink sync=false

Hardware decode (receiving Jetson with NVDEC):

  gst-launch-1.0 \
    rtspsrc location=rtsp://127.0.0.1:8554/stream latency=200 protocols=tcp \
    ! rtph265depay \
    ! h265parse \
    ! nvv4l2decoder \
    ! nv3dsink sync=false

For H.264 streams replace rtph265depay/h265parse/avdec_h265 with
rtph264depay/h264parse/avdec_h264 (or nvv4l2decoder works for both codecs).

GStreamer parameter reference:
  latency=200    Jitter buffer in milliseconds on the rtspsrc element.
                 Equivalent to VLC --network-caching. 200ms is reliable on LAN.
  protocols=tcp  Force TCP transport, matching the sender.
  sync=false     The sink runs as fast as frames arrive rather than pacing to
                 a presentation clock. Removes one more source of added delay.


## 8 - Notes on 12-bit Bayer over Gen1

BayerRG12Packed at 4096x3000 x 25fps = ~461 MB/s.
This exceeds the Gen1 practical ceiling of ~380 MB/s -- not feasible on Gen1.

If 12-bit dynamic range is required on Gen1, the only option is to configure
the pylon SDK to perform in-camera debayering and output BGR8/RGB8 or YUV422.
The camera FPGA handles the demosaic and the result is sent over USB.
This trades bandwidth savings for a higher USB byte count (3 bytes/px for BGR8).

To configure in-camera debayering:
  pylon Viewer: Analog Controls -> Pixel Format -> BGR8 or RGB8
  GenICam:      PixelFormat = "BGR8"  (or "RGB8", "YCbCr422_8")
  Script:       Set CAPTURE_MODE=color, PIXEL_FORMAT=BGR (or RGB, or GRAY8)
