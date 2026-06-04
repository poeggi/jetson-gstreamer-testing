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
# Capture: color YUY2 -- pylonsrc outputs YCbCr422_8 (YUY2) directly into NVMM.
#   Pipeline: pylonsrc(YUY2/NVMM) -> nvvidconv(NV12/NVMM) -> nvv4l2encXXX
#   Camera runs at hardware-fixed 30fps; framerate in caps is metadata only.
#
# See README.md for:
#   - Camera spec table
#   - USB bandwidth table (all pixel formats, Gen1 vs Gen2)
#   - Encoding bitrate recommendations (H.264 and H.265)
#   - Recommended configurations per use case
#
# Prerequisites on Jetson (run dependency checks below first):
#   - gstreamer1.0-tools
#   - gstreamer1.0-plugins-good   (for RTP utilities)
#   - gstreamer1.0-plugins-bad    (h264parse, h265parse, rtspclientsink)
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
# HEIGHT is limited to 2160 by the Orin NX NVENC H.265 Level 5.1 ceiling:
#   ~8,912,896 luma samples/frame (~8.9 MP). 4096 x 3000 = 12.3 MP exceeds
#   that limit (hard silicon, not tunable). 4096 x 2160 = 8.8 MP -- fits.
# To centre the crop on the sensor: set OffsetY = 420 in pylon Viewer
#   (OffsetY = (3000 - 2160) / 2 = 420).
WIDTH=4096
HEIGHT=2160

# Frame rate in frames per second.
# Camera native rate is 30fps (hardware fixed; framerate in caps is metadata only).
# 4096x2160 YUY2 at 30fps = ~530 MB/s -- confirmed working on this system.
FRAMERATE=30

# Pixel format for color capture.
# Must be a format that nvvidconv's VIC hardware accepts as NVMM input.
# Packed RGB formats (BGR, RGB) are NOT supported by VIC in NVMM mode.
#   YUY2  - YUV 4:2:2 packed, 2 bytes/px; VIC-compatible NVMM; zero CPU copies
#   UYVY  - same as YUY2; alternative byte order if YUY2 causes issues
#   GRAY8 - monochrome; NV12 chroma planes will be neutral grey
PIXEL_FORMAT="YUY2"

# ------------------------------------------------------------------------------
# ENCODER
# ------------------------------------------------------------------------------
# "h264"  H.264 AVC High Profile. Broadest client compatibility; higher bitrate.
# "h265"  H.265 HEVC Main Profile. ~40-50% smaller at equal quality.
#         Recommended for 4K DCI -- the bitrate saving is significant at this size.
#         Verify your RTSP client / NVR supports HEVC before deploying.
ENCODER="h264"

# Target encode bitrate in bits per second.
# 28 Mbps H.265 = high quality at 4096x2160 / 25fps; artefacts not visible
# under frame-by-frame inspection. 13 Mbps = streaming quality (remote monitoring).
# See README.md section 4 for full bitrate table by codec, resolution and fps.
BITRATE=28000000

# Keyframe (IDR frame) interval in frames.
# Rule of thumb: set equal to FRAMERATE for 1 IDR per second (good for RTSP).
# Lower -> faster stream join and packet-loss recovery, slightly higher bitrate.
# Higher -> lower overhead; avoid going above 2x FRAMERATE for RTSP streams.
IFRAME_INTERVAL=15

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
#             caps negotiation, and encode performance without needing an RTSP
#             server running.
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
    --fakesink)   OUTPUT_MODE="fakesink" ;;
    --h264)       ENCODER="h264" ;;
    --h265)       ENCODER="h265" ;;
    *)
      echo "ERROR: Unknown argument: $arg"
      echo "Usage: $0 [--fakesink] [--h264|--h265]"
      exit 1
      ;;
  esac
done


# ==============================================================================
# PRE-FLIGHT
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export RTSP_HOST RTSP_PORT
if ! "${SCRIPT_DIR}/check_system.sh" --fatal-only "$ENCODER" "$OUTPUT_MODE"; then
  echo "ERROR: Pre-flight checks failed. Run ./check_system.sh for details." >&2
  exit 1
fi


# ==============================================================================
# VALIDATE SETTINGS
# ==============================================================================

[[ "$ENCODER" != "h264" && "$ENCODER" != "h265" ]] && {
  echo "ERROR: ENCODER must be 'h264' or 'h265'. Got: '${ENCODER}'" >&2
  exit 1
}

[[ "$OUTPUT_MODE" != "fakesink" && "$OUTPUT_MODE" != "rtsp" ]] && {
  echo "ERROR: OUTPUT_MODE must be 'fakesink' or 'rtsp'. Got: '${OUTPUT_MODE}'" >&2
  exit 1
}


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
    # TODO: try vbv-size=2000000 (~2 frames at 28 Mbps) to reduce encoder
    # internal buffering latency from ~143ms default to ~66ms. Trade-off:
    # less headroom for scene complexity -- test with enforcement camera content.
    # Add: vbv-size=2000000 \ to ENC_ELEMENT above.
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
    # TODO: try vbv-size=2000000 (~2 frames at 28 Mbps) -- same as H.264 above.
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

# --- Color path (NVMM direct -- zero system RAM copy) ---
#
# pylonsrc outputs YUY2 frames directly into NVMM (USB DMA -> GPU, no system RAM copy).
# Explicit format constraint is mandatory: without it pylonsrc defaults to GRAY8
# during caps negotiation. Packed RGB (BGR/RGB) rejected by VIC in NVMM mode.
# nvvidconv converts YUY2 -> NV12 within NVMM via VIC hardware (zero copy).
#
# Queue parameters:
#   max-size-buffers=2   : hold at most 2 frames between stages
#   max-size-bytes=0     : disable byte limit (use buffer count only)
#   max-size-time=0      : disable time limit (default 1s blows latency budget)
#   leaky=downstream     : drop oldest frame if full, never block upstream
# Queues hold GstBuffer references only -- NVMM data never moves.
# Each queue also creates a dedicated pipeline thread for parallel stage execution.
CAPS_SRC="video/x-raw(memory:NVMM),format=${PIXEL_FORMAT},width=${WIDTH},height=${HEIGHT},framerate=${FRAMERATE}/1"
Q="queue max-size-buffers=2 max-size-bytes=0 max-size-time=0 leaky=downstream"
SRC_SEGMENT="pylonsrc ${SERIAL_PROP} \
  ! ${CAPS_SRC} \
  ! identity name=cam     silent=true check-imperfect-timestamp=true \
  ! ${Q} \
  ! nvvidconv nvbuf-memory-type=4 \
  ! ${CAPS_NVMM} \
  ! identity name=pre-enc silent=true check-imperfect-timestamp=true"


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
    # rtspclientsink pushes the stream to an RTSP server using ANNOUNCE/RECORD.
    # Note: rtspclientsink handles RTP payload internally; h265parse provides
    # NAL framing and SPS/PPS/VPS re-injection which rtspclientsink needs.
    #   protocols=tcp  : force TCP transport. UDP can lose packets causing
    #                    decoder errors; TCP is reliable and preferred for LAN.
    #                    For WAN with firewalled UDP, TCP is also the safe choice.
    OUTPUT_SEGMENT="rtspclientsink location=\"${RTSP_URL}\" protocols=tcp"
    ;;
esac


# ==============================================================================
# ASSEMBLE PIPELINE
# ==============================================================================
#
# Full logical flow -- each arrow is one ! in gst-launch-1.0 syntax:
#
#  [color mode -- YUY2 NVMM zero-copy]
#    pylonsrc
#      -> caps(NVMM/YUY2)       lock format; prevents pylonsrc defaulting to GRAY8
#      -> identity(cam)         timestamp monitor: USB receive / frame drops
#      -> queue(leaky)          decouple capture thread from VIC thread
#      -> nvvidconv             VIC HW: YUY2 -> NV12 (stays in NVMM, zero copy)
#      -> caps(NVMM/NV12)       assert NVMM NV12 for NVENC
#      -> identity(pre-enc)     timestamp monitor: VIC output
#      -> nvv4l2h265enc         NVENC hardware encoder (stays in NVMM)
#      -> identity(post-enc)    timestamp monitor: encoder output rate
#      -> queue(post-enc)       decouple encoder from parser/network
#      -> h265parse             NAL framing; re-injects VPS/SPS/PPS in-band
#      -> [fakesink | rtspclientsink]
#
# identity elements are zero-copy passthroughs with one integer comparison per
# buffer. check-imperfect-timestamp prints a warning only when timing is off.
#
# Expected end-to-end latency budget (sender side, 30fps):
#
#   Camera exposure + USB DMA   ~33ms   (one frame at 30fps)
#   nvvidconv YUY2->NV12          <1ms   (VIC hardware, stays in NVMM)
#   NVENC internal pipeline     ~33-66ms (1-2 frames; num-Bframes=0 keeps this low)
#   h264parse                     <1ms
#   rtspclientsink TCP (LAN)      <5ms
#   -------------------------------------------
#   Sender total              ~72-106ms
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

# Single-line assignment so word-splitting of $PIPELINE produces clean tokens.
# A heredoc with \ line continuations embeds literal backslashes in the string;
# after word-splitting those become standalone \ tokens that confuse gst-launch.
PIPELINE="${SRC_SEGMENT} ! ${ENC_ELEMENT} ! ${IDN_POST_ENC} ! ${Q_ENC_OUT} ! ${PARSE_ELEMENT} ! ${OUTPUT_SEGMENT}"


# ==============================================================================
# PRINT SUMMARY AND LAUNCH
# ==============================================================================

# YUY2 = 4:2:2 packed = 2 bytes per pixel
BW_MBYTES=$(( WIDTH * HEIGHT * FRAMERATE / 1000000 ))
BW_LABEL="$(( BW_MBYTES * 2 )) MB/s  (${PIXEL_FORMAT}, 2 bytes/px)"

echo "======================================================"
echo "  Basler a2A4096-30ucPRO -- Jetson Orin NX Pipeline"
echo "======================================================"
echo "  Camera serial  : ${CAMERA_SERIAL:-auto-detect}"
echo "  Resolution     : ${WIDTH}x${HEIGHT} @ ${FRAMERATE} fps"
echo "  Capture mode   : COLOR  (${PIXEL_FORMAT} NVMM -> NV12)"
echo "  Memory path    : zero CPU copies -- USB DMA direct to NVMM"
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
