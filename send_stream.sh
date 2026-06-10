#!/usr/bin/env bash
# ==============================================================================
# send_stream.sh
#
# Camera  : Basler a2A4096-30ucPRO  (Sony IMX253, 12.29 MP, global shutter)
# Target  : NVIDIA Jetson Orin NX, JetPack 5.x / 6.x
#
# Reads configuration from stream.conf (same directory).
# Supports one or two simultaneous encoding streams via GStreamer tee.
#
# Usage: ./send_stream.sh [options]
#   --fakesink            encode and discard (no RTSP server needed)
#   --main / --no-main    enable/disable MAIN stream (overrides stream.conf)
#   --main-h264           override MAIN encoder to H.264
#   --main-h265           override MAIN encoder to H.265
#   --enable-sub / --disable-sub   enable/disable SUB stream (overrides stream.conf)
#   --sub-h264            override SUB encoder to H.264
#   --sub-h265            override SUB encoder to H.265
#
# Pipeline (single stream -- MAIN only, default):
#
#  pylonsrc -> nvvidconv -> enc -> queue -> parse -> rtspsink
#  [YUY2/NVMM] [NV12/NVMM]         [4K]              [/main]
#
# Pipeline (dual stream via tee -- SUB_ENABLED=true):
#
#  pylonsrc -> nvvidconv -> tee
#  [YUY2/NVMM] [NV12/NVMM]   |
#                            +----------> enc -> queue -> parse -> rtspsink
#                            |            [4K]                     [/main]
#                            |
#                            \-> scale -> enc -> queue -> parse -> rtspsink
#                                   [4K->1080p]                    [/sub]
#
# (identity probe elements omitted; only functional pipeline stages shown)
#
# See README.md for bandwidth and bitrate reference.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ------------------------------------------------------------------------------
# Load config
# ------------------------------------------------------------------------------
CONF="${SCRIPT_DIR}/stream.conf"
[[ -f "$CONF" ]] || { echo "ERROR: stream.conf not found at ${CONF}" >&2; exit 1; }
# shellcheck source=stream.conf
source "$CONF"


# ------------------------------------------------------------------------------
# Argument parsing -- overrides stream.conf
# ------------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --fakesink)   OUTPUT_MODE="fakesink" ;;
    --main)       MAIN_ENABLED="true" ;;
    --no-main)    MAIN_ENABLED="false" ;;
    --main-h264)  MAIN_ENCODER="h264" ;;
    --main-h265)  MAIN_ENCODER="h265" ;;
    --enable-sub)   SUB_ENABLED="true" ;;
    --disable-sub)  SUB_ENABLED="false" ;;
    --sub-h264)   SUB_ENCODER="h264" ;;
    --sub-h265)   SUB_ENCODER="h265" ;;
    *)
      echo "ERROR: Unknown argument: $arg"
      echo "Usage: $0 [--fakesink] [--main|--no-main] [--main-h264|--main-h265] [--enable-sub|--disable-sub] [--sub-h264|--sub-h265]"
      exit 1
      ;;
  esac
done


# ------------------------------------------------------------------------------
# Validate
# ------------------------------------------------------------------------------
[[ "$MAIN_ENCODER" == "h264" || "$MAIN_ENCODER" == "h265" ]] || {
  echo "ERROR: MAIN_ENCODER must be h264 or h265. Got: ${MAIN_ENCODER}" >&2; exit 1; }
[[ "$SUB_ENCODER"  == "h264" || "$SUB_ENCODER"  == "h265" ]] || {
  echo "ERROR: SUB_ENCODER must be h264 or h265. Got: ${SUB_ENCODER}" >&2; exit 1; }
[[ "$OUTPUT_MODE"  == "rtsp" || "$OUTPUT_MODE"  == "fakesink" ]] || {
  echo "ERROR: OUTPUT_MODE must be rtsp or fakesink. Got: ${OUTPUT_MODE}" >&2; exit 1; }


# ------------------------------------------------------------------------------
# Pre-flight system checks
# ------------------------------------------------------------------------------
export RTSP_HOST RTSP_PORT
if ! "${SCRIPT_DIR}/check_system.sh" --fatal-only "$MAIN_ENCODER" "$OUTPUT_MODE"; then
  echo "ERROR: Pre-flight checks failed. Run ./check_system.sh for details." >&2
  exit 1
fi


# ------------------------------------------------------------------------------
# MediaMTX -- start if needed, stop on exit
# ------------------------------------------------------------------------------
MEDIAMTX_PID=""
MEDIAMTX_WE_STARTED=0
LIGHTTPD_PID=""
WSD_PID=""
ONVIF_WE_STARTED=0
ONVIF_LIGHTTPD_CONF="/tmp/lighttpd_onvif_$$.conf"

cleanup() {
  if [[ "$MEDIAMTX_WE_STARTED" -eq 1 && -n "$MEDIAMTX_PID" ]]; then
    echo ""
    echo "Stopping MediaMTX (PID ${MEDIAMTX_PID})..."
    kill "$MEDIAMTX_PID" 2>/dev/null || true
    wait "$MEDIAMTX_PID" 2>/dev/null || true
  fi
  if [[ "$ONVIF_WE_STARTED" -eq 1 ]]; then
    echo "Stopping ONVIF stack..."
    [[ -n "$LIGHTTPD_PID" ]] && { kill "$LIGHTTPD_PID" 2>/dev/null || true; wait "$LIGHTTPD_PID" 2>/dev/null || true; }
    [[ -n "$WSD_PID"      ]] && { kill "$WSD_PID"      2>/dev/null || true; wait "$WSD_PID"      2>/dev/null || true; }
    rm -f "$ONVIF_LIGHTTPD_CONF"
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
      echo "ERROR: MediaMTX not running and binary not found." >&2
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
      nc -z -w1 "$RTSP_HOST" "$RTSP_PORT" 2>/dev/null && { READY=1; break; }
    done
    [[ "$READY" -eq 0 ]] && { echo "ERROR: MediaMTX failed to start." >&2; exit 1; }
    echo "MediaMTX started (PID ${MEDIAMTX_PID})"
  fi
fi


# ------------------------------------------------------------------------------
# ONVIF stack -- start if enabled and not already running
# lighttpd serves onvif_simple_server as CGI; wsd_simple_server handles
# WS-Discovery so NVRs can find the device automatically on the LAN.
# ------------------------------------------------------------------------------
if [[ "$OUTPUT_MODE" == "rtsp" && "${ONVIF_ENABLED:-false}" == "true" ]]; then
  if nc -z -w1 127.0.0.1 "$ONVIF_PORT" 2>/dev/null; then
    echo "ONVIF already running on port ${ONVIF_PORT}"
  else
    _ONVIF_BIN=$(command -v onvif_simple_server 2>/dev/null || true)
    _WSD_BIN=$(command -v wsd_simple_server 2>/dev/null || true)
    _LIGHTTPD_BIN=$(command -v lighttpd 2>/dev/null || true)

    if [[ -z "$_ONVIF_BIN" || -z "$_WSD_BIN" || -z "$_LIGHTTPD_BIN" ]]; then
      echo "WARNING: ONVIF_ENABLED=true but stack not fully installed -- skipping" >&2
      echo "         Missing: onvif_simple_server / wsd_simple_server / lighttpd" >&2
      echo "         Build from: github.com/roleoroleo/onvif_simple_server" >&2
    else
      # Generate lighttpd config pointing CGI at onvif_simple_server
      mkdir -p /tmp/onvif_root/onvif
      cat > "$ONVIF_LIGHTTPD_CONF" <<EOF
server.port          = ${ONVIF_PORT}
server.bind          = "0.0.0.0"
server.document-root = "/tmp/onvif_root"
server.errorlog      = "/tmp/lighttpd_onvif.log"
server.modules       = ("mod_cgi")
cgi.assign           = ( "/onvif/" => "${_ONVIF_BIN}" )
EOF
      echo "Starting lighttpd (ONVIF CGI, port ${ONVIF_PORT})..."
      "$_LIGHTTPD_BIN" -f "$ONVIF_LIGHTTPD_CONF" &
      LIGHTTPD_PID=$!

      # WS-Discovery -- NVR auto-discovery on the LAN
      _ONVIF_IF=$(grep "^ifs=" "${SCRIPT_DIR}/onvif_simple_server.conf" 2>/dev/null \
        | cut -d= -f2 | tr -d ' ' || echo "eth0")
      _ONVIF_IP=$(ip -4 addr show "$_ONVIF_IF" 2>/dev/null \
        | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 || true)

      if [[ -n "$_ONVIF_IP" ]]; then
        "$_WSD_BIN" -i "$_ONVIF_IF" \
          -x "http://${_ONVIF_IP}:${ONVIF_PORT}/onvif/device_service" \
          >/dev/null 2>&1 &
        WSD_PID=$!
      else
        echo "WARNING: Cannot determine IP for interface ${_ONVIF_IF} -- WS-Discovery skipped" >&2
      fi

      ONVIF_WE_STARTED=1

      # Wait for lighttpd to be ready
      READY=0
      for i in 1 2 3; do
        sleep 1
        nc -z -w1 127.0.0.1 "$ONVIF_PORT" 2>/dev/null && { READY=1; break; }
      done
      if [[ "$READY" -eq 1 ]]; then
        echo "ONVIF started -- http://${_ONVIF_IP:-127.0.0.1}:${ONVIF_PORT}/onvif/device_service"
      else
        echo "WARNING: ONVIF lighttpd did not start within 3 seconds -- continuing without ONVIF" >&2
      fi
    fi
  fi
fi


# ------------------------------------------------------------------------------
# Build encoder elements
# ------------------------------------------------------------------------------
build_encoder() {
  local encoder="$1" bitrate="$2" control_rate="$3" iframe="$4"
  case "$encoder" in
    h264)
      # num-Bframes=0 by default on Jetson NVENC (not set -- property name varies across JetPack)
      echo "nvv4l2h264enc bitrate=${bitrate} control-rate=${control_rate} profile=4 iframeinterval=${iframe} insert-sps-pps=1 maxperf-enable=1"
      # TODO: try vbv-size=2000000 (~2 frames) to reduce encoder buffering latency ~80ms
      ;;
    h265)
      echo "nvv4l2h265enc bitrate=${bitrate} control-rate=${control_rate} profile=0 iframeinterval=${iframe} insert-sps-pps=1 maxperf-enable=1"
      ;;
  esac
}

build_parser() {
  case "$1" in
    h264) echo "h264parse config-interval=-1" ;;
    h265) echo "h265parse config-interval=-1" ;;
  esac
}

build_output() {
  local mode="$1" path="$2"
  case "$mode" in
    fakesink) echo "fakesink sync=false" ;;
    rtsp)     echo "rtspclientsink location=\"rtsp://${RTSP_HOST}:${RTSP_PORT}${path}\" protocols=tcp" ;;
  esac
}

MAIN_ENC=$(build_encoder "$MAIN_ENCODER" "$MAIN_BITRATE" "$MAIN_CONTROL_RATE" "$MAIN_IFRAME_INTERVAL")
MAIN_PARSE=$(build_parser "$MAIN_ENCODER")
MAIN_OUTPUT=$(build_output "$OUTPUT_MODE" "$MAIN_RTSP_PATH")

SUB_ENC=$(build_encoder "$SUB_ENCODER" "$SUB_BITRATE" "$SUB_CONTROL_RATE" "$SUB_IFRAME_INTERVAL")
SUB_PARSE=$(build_parser "$SUB_ENCODER")
SUB_OUTPUT=$(build_output "$OUTPUT_MODE" "$SUB_RTSP_PATH")


# ------------------------------------------------------------------------------
# Build pipeline
# ------------------------------------------------------------------------------
SERIAL_PROP=""
[[ -n "$CAMERA_SERIAL" ]] && SERIAL_PROP="serial=${CAMERA_SERIAL}"

CAPS_SRC="video/x-raw(memory:NVMM),format=${PIXEL_FORMAT},width=${MAIN_WIDTH},height=${MAIN_HEIGHT},framerate=${FRAMERATE}/1"
CAPS_NVMM="video/x-raw(memory:NVMM),format=NV12,width=${MAIN_WIDTH},height=${MAIN_HEIGHT},framerate=${FRAMERATE}/1"
Q="queue max-size-buffers=2 max-size-bytes=0 max-size-time=0 leaky=downstream"
Q_ENC="queue max-size-buffers=4 max-size-bytes=0 max-size-time=0"
IDN_CAM="identity name=cam silent=true check-imperfect-timestamp=true"
IDN_PRE="identity name=pre-enc silent=true check-imperfect-timestamp=true"
IDN_POST="identity name=post-enc silent=true check-imperfect-timestamp=true"
IDN_SUB_PRE="identity name=sub-pre-enc silent=true check-imperfect-timestamp=true"
IDN_SUB_POST="identity name=sub-post-enc silent=true check-imperfect-timestamp=true"

# Source segment: camera capture through format conversion (shared by all branches)
SRC="pylonsrc ${SERIAL_PROP} ! ${CAPS_SRC} ! ${IDN_CAM} ! ${Q} ! nvvidconv nvbuf-memory-type=4 ! ${CAPS_NVMM}"

[[ "$MAIN_ENABLED" != "true" && "$SUB_ENABLED" != "true" ]] && {
  echo "ERROR: Both MAIN and SUB are disabled. Enable at least one stream." >&2; exit 1; }

CAPS_SUB_NVMM="video/x-raw(memory:NVMM),format=NV12,width=${SUB_WIDTH},height=${SUB_HEIGHT},framerate=${FRAMERATE}/1"
MAIN_BRANCH="${Q} ! ${IDN_PRE} ! ${MAIN_ENC} ! ${IDN_POST} ! ${Q_ENC} ! ${MAIN_PARSE} ! ${MAIN_OUTPUT}"
SUB_BRANCH="${Q} ! ${IDN_SUB_PRE} ! nvvidconv nvbuf-memory-type=4 ! ${CAPS_SUB_NVMM} ! ${SUB_ENC} ! ${IDN_SUB_POST} ! ${Q_ENC} ! ${SUB_PARSE} ! ${SUB_OUTPUT}"

if [[ "$MAIN_ENABLED" == "true" && "$SUB_ENABLED" == "true" ]]; then
  PIPELINE="${SRC} ! tee name=t t. ! ${MAIN_BRANCH} t. ! ${SUB_BRANCH}"
elif [[ "$MAIN_ENABLED" == "true" ]]; then
  PIPELINE="${SRC} ! ${IDN_PRE} ! ${MAIN_ENC} ! ${IDN_POST} ! ${Q_ENC} ! ${MAIN_PARSE} ! ${MAIN_OUTPUT}"
else
  PIPELINE="${SRC} ! ${SUB_BRANCH}"
fi


# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
BW=$(( MAIN_WIDTH * MAIN_HEIGHT * FRAMERATE * 2 / 1000000 ))
echo "======================================================"
echo "  Basler a2A4096-30ucPRO -- Jetson Orin NX"
echo "======================================================"
echo "  Camera         : ${CAMERA_SERIAL:-auto-detect}"
echo "  Capture        : ${MAIN_WIDTH}x${MAIN_HEIGHT} @ ${FRAMERATE}fps ${PIXEL_FORMAT} (~${BW} MB/s)"
if [[ "$MAIN_ENABLED" == "true" ]]; then
echo "  MAIN stream    : ${MAIN_ENCODER^^} ${MAIN_BITRATE}bps ${MAIN_WIDTH}x${MAIN_HEIGHT} -> ${OUTPUT_MODE} (${MAIN_RTSP_PATH})"
else
echo "  MAIN stream    : disabled  (--main or set MAIN_ENABLED=true in stream.conf)"
fi
if [[ "$SUB_ENABLED" == "true" ]]; then
echo "  SUB stream     : ${SUB_ENCODER^^} ${SUB_BITRATE}bps ${SUB_WIDTH}x${SUB_HEIGHT} -> ${OUTPUT_MODE} (${SUB_RTSP_PATH})"
else
echo "  SUB stream     : disabled  (--enable-sub or set SUB_ENABLED=true in stream.conf)"
fi
if [[ "$OUTPUT_MODE" == "rtsp" ]]; then
[[ "$MAIN_ENABLED" == "true" ]] && echo "  MAIN URL       : rtsp://${RTSP_HOST}:${RTSP_PORT}${MAIN_RTSP_PATH}"
[[ "$SUB_ENABLED"  == "true" ]] && echo "  SUB URL        : rtsp://${RTSP_HOST}:${RTSP_PORT}${SUB_RTSP_PATH}"
fi
echo "======================================================"
echo ""

# Launch (-e sends EOS on interrupt so encoder flushes cleanly)
# shellcheck disable=SC2086
gst-launch-1.0 -e $PIPELINE
