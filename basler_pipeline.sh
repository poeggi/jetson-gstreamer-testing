#!/usr/bin/env bash
# ==============================================================================
# basler_pipeline.sh
#
# Camera  : Basler a2A4096-30ucPRO  (Sony IMX253, 12.29 MP, global shutter)
# Target  : NVIDIA Jetson Orin NX, JetPack 5.x / 6.x
# Plugin  : Basler pylon GStreamer plugin (pylonsrc)
#
# NVMM memory strategy (NVIDIA best practice for USB cameras):
#   1. pylonsrc delivers frames into system RAM. This one copy is unavoidable
#      for USB -- the USB DMA engine writes into host memory, not GPU memory.
#   2. nvvidconv transfers the frame to NVMM using the VIC hardware block.
#      nvbuf-memory-type=4 selects NVBUF_MEM_SURFACE_ARRAY, the Jetson-native
#      NVMM surface type consumed directly by NVENC with zero extra copies.
#   3. Every element after nvvidconv (encoder, parser, payloader, sink)
#      operates on NVMM buffers. No CPU copies occur past this point.
#
# Capture modes:
#   color -- pylonsrc outputs BGR/RGB (3 bytes/px). Full pipeline:
#              pylonsrc -> nvvidconv(NVMM) -> nvv4l2encXXX
#            Simplest path but highest USB bandwidth cost.
#
#   bayer -- pylonsrc outputs BayerRG8 (1 byte/px, ~3x less USB bandwidth).
#              pylonsrc -> bayer2rgb(CPU NEON SIMD) -> nvvidconv(NVMM) -> enc
#            CPU debayer cost at 12MP/25fps is ~1-2 A78AE cores.
#            Required for 12 MP at 25 fps on USB 3.1 Gen1 (~380 MB/s ceiling).
#
# See README.md for:
#   - Camera spec table
#   - USB bandwidth table (all pixel formats, Gen1 vs Gen2)
#   - Encoding bitrate recommendations (H.264 and H.265)
#   - Recommended configurations per use case
#
# Prerequisites on Jetson (run dependency checks below first):
#   - gstreamer1.0-tools
#   - gstreamer1.0-plugins-good   (rtph264pay, rtph265pay)
#   - gstreamer1.0-plugins-bad    (bayer2rgb, h264parse, h265parse, rtspclientsink)
#   - NVIDIA JetPack GStreamer    (nvvidconv, nvv4l2h264enc, nvv4l2h265enc)
#   - Basler pylon GStreamer pkg  (pylonsrc) -- from baslerweb.com/downloads
#   - MediaMTX RTSP server        (for OUTPUT_MODE=rtsp) -- github.com/bluenviron/mediamtx
# ==============================================================================

set -euo pipefail


# ==============================================================================
# CONFIGURATION
# Defaults target: a2A4096-30ucPRO at full resolution, 25 fps, USB 3.1 Gen1.
# See README.md for detailed bandwidth and bitrate tables before changing these.
# ==============================================================================

# Camera serial number.
# Leave empty to auto-connect to the first Basler USB camera detected by pylon.
# Find your serial number with: gst-launch-1.0 pylonsrc num-buffers=1 ! fakesink
# or via the pylon Viewer application.
CAMERA_SERIAL=""

# Sensor resolution. The a2A4096-30ucPRO maximum is 4096 x 3000.
# Using the full sensor resolution. Reduce for higher frame rates or lower
# USB bandwidth (ROI mode -- configure ROI offset in pylon if needed).
WIDTH=4096
HEIGHT=3000

# Frame rate in frames per second.
# Camera rated maximum at full resolution: 30 fps (BayerRG8, barely within Gen1).
# 25 fps provides ~19% headroom below the Gen1 ceiling -- recommended default.
# Increase to 30 only after confirming your USB host controller sustains 369 MB/s.
FRAMERATE=25

# ------------------------------------------------------------------------------
# CAPTURE_MODE: how pixel data is read from the camera and handed to the encoder
# ------------------------------------------------------------------------------
# "color"  pylonsrc emits BGR8 (or format in PIXEL_FORMAT below).
#          The camera FPGA debayers internally; USB cost is 3 bytes/pixel.
#          4096x3000 BGR8 at 25fps = 922 MB/s -- NOT feasible on Gen1.
#          Use color mode only at lower resolutions / fps on Gen1, or on Gen2.
#
# "bayer"  pylonsrc emits raw BayerRG8; USB cost is 1 byte/pixel.
#          4096x3000 BayerRG8 at 25fps = 307 MB/s -- fits on Gen1 with headroom.
#          Debayering is performed on Jetson by bayer2rgb (CPU, NEON SIMD).
#          Limitation: bayer2rgb only supports 8-bit Bayer. For 12-bit quality,
#          use CAPTURE_MODE=color with pylon configured to output BGR8 in-camera.
#
CAPTURE_MODE="bayer"

# Pixel format for CAPTURE_MODE=color (ignored in bayer mode).
#   BGR   - Basler pylon default output; nvvidconv -> NV12 fastest path
#   RGB   - equally fast; some post-processing pipelines prefer RGB
#   GRAY8 - monochrome sensor output; NV12 chroma planes will be neutral grey
PIXEL_FORMAT="BGR"

# Bayer mosaic pattern for CAPTURE_MODE=bayer (ignored in color mode).
# The a2A4096-30ucPRO uses an RGGB pattern (standard for most Basler color models).
# Verify in the pylon Viewer under Analog Controls -> Pixel Format.
#   rggb  - standard; most Basler color cameras (daA, acA, a2A series)
#   bggr  - some Sony sensor variants
#   gbrg  - uncommon; check datasheet
#   grbg  - uncommon; check datasheet
BAYER_FORMAT="rggb"

# ------------------------------------------------------------------------------
# ENCODER
# ------------------------------------------------------------------------------
# "h264"  H.264 AVC High Profile. Broadest client compatibility; higher bitrate.
# "h265"  H.265 HEVC Main Profile. ~40-50% smaller at equal quality.
#         Recommended for 12MP -- the bitrate saving is significant at this size.
#         Verify your RTSP client / NVR supports HEVC before deploying.
ENCODER="h265"

# Target encode bitrate in bits per second.
# Current default: 20 Mbps H.265, streaming quality at 12MP/25fps.
# Raise to ~38 Mbps for high quality (minimal visible artefacts).
# See README.md section 4 for full bitrate table by codec, resolution and fps.
BITRATE=20000000

# Keyframe (IDR frame) interval in frames.
# Rule of thumb: set equal to FRAMERATE for 1 IDR per second (good for RTSP).
# Lower -> faster stream join and packet-loss recovery, slightly higher bitrate.
# Higher -> lower overhead; avoid going above 2x FRAMERATE for RTSP streams.
IFRAME_INTERVAL=25

# Rate control mode:
#   1 = CBR (constant bitrate) -- recommended for RTSP.
#       Maintains a steady output rate; prevents buffer stalls at the receiver.
#       Momentarily complex frames may drop a little quality to hit the target.
#   2 = VBR (variable bitrate) -- better quality for local NVR or archival.
#       Allocates extra bits to complex frames; can spike 2-3x above average.
#       Only use on high-bandwidth private links where spikes are acceptable.
CONTROL_RATE=1

# ------------------------------------------------------------------------------
# OUTPUT_MODE
# ------------------------------------------------------------------------------
# "fakesink"  Encode and discard. Use this first to validate camera detection,
#             caps negotiation, Bayer debayering, and encode performance without
#             needing an RTSP server running.
#             Diagnostic tip: prefix launch with GST_DEBUG=*:3 for verbose caps
#             negotiation tracing.  Example:
#               GST_DEBUG=*:3 ./basler_pipeline.sh 2>&1 | grep -i caps
#
# "rtsp"      Push encoded stream to an RTSP server via ANNOUNCE/RECORD (TCP).
#             rtspclientsink reads NVMM buffers directly from the encoder --
#             zero additional CPU copies between encode and network transmit.
#             An RTSP server must be running before launching this script.
#             MediaMTX quickstart: download binary, run ./mediamtx (port 8554).
#               https://github.com/bluenviron/mediamtx/releases
#
OUTPUT_MODE="rtsp"

# RTSP server endpoint -- only used when OUTPUT_MODE=rtsp.
RTSP_HOST="127.0.0.1"
RTSP_PORT="8554"
RTSP_PATH="/main"


# ==============================================================================
# ARGUMENT PARSING -- overrides configuration defaults above
# ==============================================================================

for arg in "$@"; do
  case "$arg" in
    --fakesink)
      OUTPUT_MODE="fakesink"
      ;;
    *)
      echo "ERROR: Unknown argument: $arg"
      echo "Usage: $0 [--fakesink]"
      exit 1
      ;;
  esac
done


# ==============================================================================
# PRE-FLIGHT
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export RTSP_HOST RTSP_PORT
if ! "${SCRIPT_DIR}/check_system.sh" --quiet "$CAPTURE_MODE" "$ENCODER" "$OUTPUT_MODE"; then
  echo "ERROR: Pre-flight checks failed. Run ./check_system.sh for details." >&2
  exit 1
fi


# ==============================================================================
# VALIDATE SETTINGS
# ==============================================================================

[[ "$CAPTURE_MODE" != "color" && "$CAPTURE_MODE" != "bayer" ]] && {
  echo "ERROR: CAPTURE_MODE must be 'color' or 'bayer'. Got: '${CAPTURE_MODE}'" >&2
  exit 1
}

[[ "$ENCODER" != "h264" && "$ENCODER" != "h265" ]] && {
  echo "ERROR: ENCODER must be 'h264' or 'h265'. Got: '${ENCODER}'" >&2
  exit 1
}

[[ "$OUTPUT_MODE" != "fakesink" && "$OUTPUT_MODE" != "rtsp" ]] && {
  echo "ERROR: OUTPUT_MODE must be 'fakesink' or 'rtsp'. Got: '${OUTPUT_MODE}'" >&2
  exit 1
}


# ==============================================================================
# NVMM CAPABILITY CHECK
# pylonsrc must advertise NVMM caps so the color capture path places frames
# directly into GPU memory. Without NVMM, nvvidconv must copy every frame
# from system RAM into NVMM -- one full-frame DMA per frame, per second.
# bayer mode always requires one system RAM -> NVMM copy (bayer2rgb outputs
# system RAM; no NVMM-capable Bayer debayer exists in standard GStreamer).
# ==============================================================================

if ! gst-inspect-1.0 pylonsrc 2>/dev/null | grep -i "memory:NVMM" > /dev/null; then
  echo "ERROR: pylonsrc does not advertise NVMM caps on this system." >&2
  echo "       Color capture cannot avoid a system RAM -> GPU copy per frame." >&2
  echo "       Upgrade the pylon GStreamer plugin:" >&2
  echo "       github.com/basler/gst-plugin-pylon/releases" >&2
  exit 1
fi


# ==============================================================================
# MEDIAMTX -- start if needed, stop on exit (RTSP mode only)
# ==============================================================================

MEDIAMTX_PID=""
MEDIAMTX_WE_STARTED=0

cleanup() {
  if [[ "$MEDIAMTX_WE_STARTED" -eq 1 && -n "$MEDIAMTX_PID" ]]; then
    echo ""
    echo "Stopping MediaMTX (PID ${MEDIAMTX_PID})..."
    kill "$MEDIAMTX_PID" 2>/dev/null || true
    wait "$MEDIAMTX_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

find_mediamtx() {
  for loc in \
    "$(command -v mediamtx 2>/dev/null || true)" \
    /usr/local/bin/mediamtx \
    "${HOME}/mediamtx" \
    "${SCRIPT_DIR}/mediamtx"; do
    [[ -n "$loc" && -x "$loc" ]] && echo "$loc" && return 0
  done
  return 1
}

if [[ "$OUTPUT_MODE" == "rtsp" ]]; then
  if nc -z -w1 "$RTSP_HOST" "$RTSP_PORT" 2>/dev/null; then
    echo "MediaMTX already running at ${RTSP_HOST}:${RTSP_PORT}"
  else
    MEDIAMTX_BIN=$(find_mediamtx) || {
      echo "ERROR: MediaMTX not running and binary not found in PATH or common locations." >&2
      echo "       Download from github.com/bluenviron/mediamtx/releases" >&2
      exit 1
    }
    echo "Starting MediaMTX (${MEDIAMTX_BIN})..."
    "$MEDIAMTX_BIN" >/dev/null 2>&1 &
    MEDIAMTX_PID=$!
    MEDIAMTX_WE_STARTED=1

    READY=0
    for i in 1 2 3 4 5; do
      sleep 1
      if nc -z -w1 "$RTSP_HOST" "$RTSP_PORT" 2>/dev/null; then
        READY=1
        break
      fi
    done
    [[ "$READY" -eq 0 ]] && {
      echo "ERROR: MediaMTX failed to start within 5 seconds." >&2
      exit 1
    }
    echo "MediaMTX started (PID ${MEDIAMTX_PID})"
  fi
fi


# ==============================================================================
# BUILD ENCODER ELEMENTS
# ==============================================================================

case "$ENCODER" in
  h264)
    # nvv4l2h264enc -- NVENC H.264 hardware encoder
    #   bitrate        : target output bitrate in bps
    #   control-rate   : 1=CBR, 2=VBR (see CONTROL_RATE above)
    #   profile        : 4=High Profile -- best compression, broad compatibility
    #   iframeinterval : IDR frame every N frames
    #   insert-sps-pps : prepend SPS/PPS before every IDR frame; required so
    #                    late-joining RTSP clients can decode without waiting
    #   maxperf-enable : disable power-saving throttling; keeps encode latency
    #                    stable at full frame rate
    #
    # h264parse
    #   config-interval=-1 : re-emit SPS/PPS in-band with every IDR; ensures
    #                        any element downstream (rtspclientsink, file mux)
    #                        always has the codec parameters available
    # num-Bframes defaults to 0 on Jetson NVENC -- not set explicitly because
    # the property name varies across JetPack versions and an unknown property
    # causes silent pipeline construction failure.
    ENC_ELEMENT="nvv4l2h264enc \
      bitrate=${BITRATE} \
      control-rate=${CONTROL_RATE} \
      profile=4 \
      iframeinterval=${IFRAME_INTERVAL} \
      insert-sps-pps=1 \
      maxperf-enable=1"
    PARSE_ELEMENT="h264parse config-interval=-1"
    RTP_ELEMENT="rtph264pay pt=96 config-interval=-1"
    ;;
  h265)
    # nvv4l2h265enc -- NVENC H.265 hardware encoder
    #   profile=0 : Main Profile (HEVC Tier Main); widely supported
    #   All other parameters same semantics as H.264 encoder above
    # num-Bframes defaults to 0 on Jetson NVENC -- not set explicitly because
    # the property name varies across JetPack versions and an unknown property
    # causes silent pipeline construction failure.
    ENC_ELEMENT="nvv4l2h265enc \
      bitrate=${BITRATE} \
      control-rate=${CONTROL_RATE} \
      profile=0 \
      iframeinterval=${IFRAME_INTERVAL} \
      insert-sps-pps=1 \
      maxperf-enable=1"
    PARSE_ELEMENT="h265parse config-interval=-1"
    RTP_ELEMENT="rtph265pay pt=96 config-interval=-1"
    ;;
esac


# ==============================================================================
# BUILD SOURCE SEGMENT
# ==============================================================================

# Optional camera serial property for pylonsrc
SERIAL_PROP=""
[[ -n "$CAMERA_SERIAL" ]] && SERIAL_PROP="serial=${CAMERA_SERIAL}"

# NVMM caps string -- asserted after nvvidconv to lock downstream to NVMM NV12.
# NV12 is the native input format for NVENC on Jetson. Asserting it explicitly
# prevents GStreamer from inserting an unwanted software conversion fallback.
CAPS_NVMM="video/x-raw(memory:NVMM),format=NV12,width=${WIDTH},height=${HEIGHT},framerate=${FRAMERATE}/1"

if [[ "$CAPTURE_MODE" == "bayer" ]]; then
  # --- Bayer path ---
  #
  # pylonsrc emits video/x-bayer (system RAM, 1 byte/px).
  # The caps string locks pylon to the correct Bayer pattern and size so
  # caps negotiation does not accidentally select a different pixel format.
  #
  # bayer2rgb performs bilinear Bayer demosaic entirely in software using
  # Orc/NEON SIMD. Output is video/x-raw,format=RGB (still system RAM).
  # This is the only standard GStreamer path for Bayer -- no NVMM Bayer
  # support exists in nvvidconv or the NVENC engine.
  #
  # nvvidconv performs a single DMA-assisted copy from system RAM into NVMM
  # (NVBUF_MEM_SURFACE_ARRAY, nvbuf-memory-type=4), converting RGB -> NV12
  # using the VIC hardware block. This is the one unavoidable system RAM ->
  # NVMM step in bayer mode: bayer2rgb has no NVMM-capable counterpart in
  # standard GStreamer. All elements after nvvidconv use NVMM exclusively.
  CAPS_BAYER="video/x-bayer,format=${BAYER_FORMAT},width=${WIDTH},height=${HEIGHT},framerate=${FRAMERATE}/1"
  # Queue parameters used throughout:
  #   max-size-buffers=2   : hold at most 2 frames between stages
  #   max-size-bytes=0     : disable byte-based limit (use buffer count only)
  #   max-size-time=0      : disable time-based limit -- the default (1s) would
  #                          silently blow the latency budget; must be zero here
  #   leaky=downstream     : if full, drop the oldest unprocessed frame rather
  #                          than blocking the upstream stage
  # Queues hold GstBuffer references only -- NVMM data never moves. Zero-copy
  # is fully preserved. Each queue also creates a dedicated pipeline thread,
  # allowing stages to run in parallel rather than sequentially.
  Q="queue max-size-buffers=2 max-size-bytes=0 max-size-time=0 leaky=downstream"
  SRC_SEGMENT="pylonsrc ${SERIAL_PROP} \
    ! ${CAPS_BAYER} \
    ! identity name=cam     silent=true check-imperfect-timestamp=true \
    ! ${Q} \
    ! bayer2rgb \
    ! ${Q} \
    ! nvvidconv nvbuf-memory-type=4 \
    ! ${CAPS_NVMM} \
    ! identity name=pre-enc silent=true check-imperfect-timestamp=true"

else
  # --- Color path (NVMM direct -- zero system RAM copy) ---
  #
  # pylonsrc places each captured frame directly into NVMM: USB DMA writes
  # into GPU-accessible memory with no system RAM intermediate. The camera
  # FPGA debayers internally; pylonsrc negotiates a color format in NVMM.
  # format= is intentionally unconstrained so caps negotiation selects the
  # best NVMM format pylonsrc supports (BGRA, RGBA, NV12, etc.).
  # nvvidconv converts that format to NV12 entirely within NVMM via the VIC
  # hardware block -- no memory copy, format conversion only.
  # Zero CPU copies between camera capture and NVENC encoder.
  CAPS_SRC="video/x-raw(memory:NVMM),width=${WIDTH},height=${HEIGHT},framerate=${FRAMERATE}/1"
  Q="queue max-size-buffers=2 max-size-bytes=0 max-size-time=0 leaky=downstream"
  SRC_SEGMENT="pylonsrc ${SERIAL_PROP} \
    ! ${CAPS_SRC} \
    ! identity name=cam     silent=true check-imperfect-timestamp=true \
    ! ${Q} \
    ! nvvidconv nvbuf-memory-type=4 \
    ! ${CAPS_NVMM} \
    ! identity name=pre-enc silent=true check-imperfect-timestamp=true"
fi


# ==============================================================================
# BUILD OUTPUT SEGMENT
# ==============================================================================

case "$OUTPUT_MODE" in
  fakesink)
    # fakesink discards all buffers.
    # sync=false: run as fast as the encoder produces; no wall-clock pacing.
    # This lets you measure the pipeline's sustained throughput capacity without
    # being artificially throttled to real-time by a display or network sink.
    OUTPUT_SEGMENT="fakesink sync=false"
    ;;
  rtsp)
    RTSP_URL="rtsp://${RTSP_HOST}:${RTSP_PORT}${RTSP_PATH}"
    # rtph264/5pay packetizes the encoded bitstream into RTP packets.
    #   pt=96          : dynamic RTP payload type (standard for H.264/H.265)
    #   config-interval=-1 : inject SPS/PPS/VPS into every RTP access unit;
    #                        allows RTSP clients to join mid-stream
    #
    # rtspclientsink pushes the stream to an RTSP server using ANNOUNCE/RECORD.
    #   protocols=tcp  : force TCP transport. UDP can lose packets causing
    #                    decoder errors; TCP is reliable and preferred for LAN.
    #                    For WAN with firewalled UDP, TCP is also the safe choice.
    OUTPUT_SEGMENT="${RTP_ELEMENT} ! rtspclientsink location=\"${RTSP_URL}\" protocols=tcp"
    ;;
esac


# ==============================================================================
# ASSEMBLE PIPELINE
# ==============================================================================
#
# Full logical flow -- each arrow is one ! in gst-launch-1.0 syntax:
#
#  [bayer mode]
#    pylonsrc
#      -> caps(x-bayer)         lock USB pixel format
#      -> identity(cam)         timestamp monitor: USB receive / frame drops
#      -> bayer2rgb             CPU NEON SIMD demosaic: Bayer -> RGB (system RAM)
#      -> nvvidconv             VIC HW: RGB -> NV12, copy system RAM -> NVMM
#      -> caps(NVMM/NV12)       assert NVMM buffer type for encoder
#      -> identity(pre-enc)     timestamp monitor: debayer + VIC stage
#      -> nvv4l2h265enc         NVENC hardware encoder (stays in NVMM)
#      -> identity(post-enc)    timestamp monitor: encoder output rate
#      -> h265parse             NAL framing; re-injects VPS/SPS/PPS in-band
#      -> [fakesink | rtph265pay -> rtspclientsink]
#
#  [color mode]
#    pylonsrc
#      -> caps(x-raw/BGR)       lock USB pixel format
#      -> identity(cam)         timestamp monitor: USB receive / frame drops
#      -> nvvidconv             VIC HW: BGR -> NV12, copy system RAM -> NVMM
#      -> caps(NVMM/NV12)       assert NVMM buffer type for encoder
#      -> identity(pre-enc)     timestamp monitor: VIC stage
#      -> nvv4l2h265enc         NVENC hardware encoder (stays in NVMM)
#      -> identity(post-enc)    timestamp monitor: encoder output rate
#      -> h265parse             NAL framing; re-injects VPS/SPS/PPS in-band
#      -> [fakesink | rtph265pay -> rtspclientsink]
#
# identity elements are zero-copy passthroughs. They hold no data and make
# no allocations. check-imperfect-timestamp does one integer comparison per
# buffer and prints a single warning line only when timing is off.
#
# Expected end-to-end latency budget (sender side, 25fps):
#
#   Camera exposure + USB DMA   ~40ms   (one frame -- unavoidable at 25fps)
#   bayer2rgb + nvvidconv         <2ms   (NEON SIMD + VIC hardware)
#   NVENC internal pipeline     ~40-80ms (1-2 frames; num-Bframes=0 keeps this low)
#   h265parse + rtp payloader     <2ms
#   rtspclientsink TCP (LAN)      <5ms
#   -------------------------------------------
#   Sender total              ~85-130ms   (well below 1 second)
#
# Note: the receiver (VLC, GStreamer rtspsrc) adds its own jitter buffer on
# top of this. Default is 1000ms in VLC and 200ms in GStreamer rtspsrc.
# To reduce perceived latency on the receiver side:
#   VLC : Media -> Open Network -> Show more -> set Caching to 100ms
#         or from command line: vlc --rtsp-caching=100 rtsp://...
#   GStreamer rtspsrc: add latency=100 property to rtspsrc element

IDN_POST_ENC="identity name=post-enc silent=true check-imperfect-timestamp=true"

# Post-encoder queue: decouples NVENC from the parser and network sink.
# Larger buffer (4) is safe here -- encoded bitstream frames are small (~100KB)
# and do not consume NVMM pool surfaces.
# No leaky: dropping encoded frames would produce a corrupt RTSP stream.
Q_ENC_OUT="queue max-size-buffers=4 max-size-bytes=0 max-size-time=0"

read -r -d '' PIPELINE << PIPELINE_EOF || true
${SRC_SEGMENT} \
  ! ${ENC_ELEMENT} \
  ! ${IDN_POST_ENC} \
  ! ${Q_ENC_OUT} \
  ! ${PARSE_ELEMENT} \
  ! ${OUTPUT_SEGMENT}
PIPELINE_EOF


# ==============================================================================
# PRINT SUMMARY AND LAUNCH
# ==============================================================================

BW_MBYTES=$(( WIDTH * HEIGHT * FRAMERATE / 1000000 ))
if [[ "$CAPTURE_MODE" == "bayer" ]]; then
  BW_LABEL="${BW_MBYTES} MB/s  (BayerRG8, 1 byte/px)"
else
  BW_LABEL="$(( BW_MBYTES * 3 )) MB/s  (${PIXEL_FORMAT}, 3 bytes/px)"
fi

echo "======================================================"
echo "  Basler a2A4096-30ucPRO -- Jetson Orin NX Pipeline"
echo "======================================================"
echo "  Camera serial  : ${CAMERA_SERIAL:-auto-detect}"
echo "  Resolution     : ${WIDTH}x${HEIGHT} @ ${FRAMERATE} fps"
if [[ "$CAPTURE_MODE" == "bayer" ]]; then
  echo "  Capture mode   : BAYER  (${BAYER_FORMAT} -> bayer2rgb -> NV12)"
  echo "  Memory path    : one system RAM -> NVMM copy (bayer2rgb limitation)"
else
  echo "  Capture mode   : COLOR  (NVMM direct -> NV12)"
  echo "  Memory path    : zero CPU copies -- USB DMA direct to NVMM"
fi
echo "  USB bandwidth  : ~${BW_LABEL}"
echo "  Encoder        : ${ENCODER^^}  ${BITRATE} bps  $([ "$CONTROL_RATE" = "1" ] && echo CBR || echo VBR)"
echo "  Keyframe int.  : every ${IFRAME_INTERVAL} frames"
echo "  Output         : ${OUTPUT_MODE}"
[[ "$OUTPUT_MODE" = "rtsp" ]] && echo "  RTSP URL       : rtsp://${RTSP_HOST}:${RTSP_PORT}${RTSP_PATH}"
echo "======================================================"
echo ""
echo "Pipeline:"
echo "  gst-launch-1.0 -e ${PIPELINE}"
echo ""

# Launch.
# -e sends EOS on SIGINT or SIGTERM so the encoder flushes its internal buffer
# and the stream ends cleanly rather than cutting off mid-GOP.
# Note: intentionally NOT using exec here so the shell process stays alive,
# which allows the EXIT trap above to stop MediaMTX when the pipeline ends.
# $PIPELINE is unquoted so the shell word-splits it into the multiple tokens
# gst-launch-1.0 expects. Passing the whole pipeline as one quoted string
# triggers gst-launch URI detection on some JetPack versions, causing a
# spurious gst_element_make_from_uri assertion and a follow-on syntax error.
# location="rtsp://..." in OUTPUT_SEGMENT is already quoted so it survives
# word-splitting as one token even in RTSP mode.
# shellcheck disable=SC2086
gst-launch-1.0 -e $PIPELINE
