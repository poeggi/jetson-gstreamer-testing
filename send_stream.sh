#!/usr/bin/env bash
# ==============================================================================
# send_stream.sh
#
# Camera  : Basler a2A4096-30ucPRO  (Sony IMX253, 12.29 MP, global shutter)
# Target  : NVIDIA Jetson Orin NX, JetPack 6.x or later
#
# Reads configuration from stream.conf (same directory).
# Supports one or two simultaneous encoding streams via GStreamer tee.
#
# Usage: ./send_stream.sh [options]
#   --fakesink            encode and discard (no RTSP server needed)
#   --debug               log frame drops to console (check-imperfect-timestamp)
#   --main / --no-main    enable/disable MAIN stream (overrides stream.conf)
#   --main-h264           override MAIN encoder to H.264
#   --main-h265           override MAIN encoder to H.265
#   --sub / --no-sub      enable/disable SUB stream (overrides stream.conf)
#   --sub-h264            override SUB encoder to H.264
#   --sub-h265            override SUB encoder to H.265
#
# Pipeline (single stream -- MAIN only, use --no-sub):
#
#  pylonsrc -> nvvidconv -> enc -> queue -> parse -> rtspsink
#  [YUY2/NVMM] [NV12/NVMM]         [4K]              [/main]
#
# Pipeline (dual stream via tee -- default, SUB_ENABLED=true):
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

_find_bin() { echo "${SCRIPT_DIR}/bin/$1"; }

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
DEBUG_MODE=0
for arg in "$@"; do
  case "$arg" in
    --fakesink)   OUTPUT_MODE="fakesink" ;;
    --debug)      DEBUG_MODE=1 ;;
    --main)       MAIN_ENABLED="true" ;;
    --no-main)    MAIN_ENABLED="false" ;;
    --main-h264)  MAIN_ENCODER="h264" ;;
    --main-h265)  MAIN_ENCODER="h265" ;;
    --sub)          SUB_ENABLED="true" ;;
    --no-sub)       SUB_ENABLED="false" ;;
    --sub-h264)   SUB_ENCODER="h264" ;;
    --sub-h265)   SUB_ENCODER="h265" ;;
    *)
      echo "ERROR: Unknown argument: $arg"
      echo "Usage: $0 [--fakesink] [--debug] [--main|--no-main] [--main-h264|--main-h265] [--sub|--no-sub] [--sub-h264|--sub-h265]"
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
WSD_PID_FILE="/tmp/wsd_simple_server_$$.pid"
ONVIF_WE_STARTED=0
ONVIF_LIGHTTPD_CONF="/tmp/lighttpd_onvif_$$.conf"

cleanup() {
  # Stop ONVIF first -- NVRs stop discovering before RTSP goes away
  if [[ "$ONVIF_WE_STARTED" -eq 1 ]]; then
    echo "Stopping ONVIF stack..."
    # wsd daemonizes itself: real PID is in the pid file, not $!
    _wsd_kill_pid="${WSD_PID}"
    [[ -f "$WSD_PID_FILE" ]] && _wsd_kill_pid="$(cat "$WSD_PID_FILE" 2>/dev/null || true)"
    [[ -n "$_wsd_kill_pid" ]] && kill "$_wsd_kill_pid" 2>/dev/null || true
    rm -f "$WSD_PID_FILE"
    [[ -n "$LIGHTTPD_PID" ]] && { kill "$LIGHTTPD_PID" 2>/dev/null || true; wait "$LIGHTTPD_PID" 2>/dev/null || true; }
    rm -f "$ONVIF_LIGHTTPD_CONF"
  fi
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
      echo "ERROR: MediaMTX not running and binary not found." >&2
      echo "       Download from github.com/bluenviron/mediamtx/releases" >&2
      exit 1
    }
    echo "Starting MediaMTX (${MEDIAMTX_BIN})..."
    if [[ "$DEBUG_MODE" -eq 1 ]]; then
      "$MEDIAMTX_BIN" "${SCRIPT_DIR}/blueprints/mediamtx.yml" &
    else
      "$MEDIAMTX_BIN" "${SCRIPT_DIR}/blueprints/mediamtx.yml" >/dev/null 2>&1 &
    fi
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
# ------------------------------------------------------------------------------
if [[ "$OUTPUT_MODE" == "rtsp" && "${ONVIF_ENABLED:-false}" == "true" ]]; then
  if nc -z -w1 127.0.0.1 "$ONVIF_PORT" 2>/dev/null; then
    echo "ONVIF already running on port ${ONVIF_PORT}"
  else
    _ONVIF_BIN=$(_find_bin onvif_simple_server)
    _WSD_BIN=$(_find_bin wsd_simple_server)
    _LIGHTTPD_BIN=$(command -v lighttpd 2>/dev/null || true)

    if [[ -z "$_ONVIF_BIN" || -z "$_WSD_BIN" || -z "$_LIGHTTPD_BIN" ]]; then
      echo "WARNING: ONVIF_ENABLED=true but stack not fully installed -- skipping" >&2
      echo "         onvif_simple_server / wsd_simple_server: run ./bin/sources/cross-build-windows.ps1 (Windows)" >&2
      echo "         lighttpd: sudo apt install lighttpd" >&2
    else
      # Generate onvif_simple_server conf from stream.conf values
      _ONVIF_SERVER_CONF="/tmp/onvif_simple_server_${ONVIF_PORT}.conf"
      cat > "$_ONVIF_SERVER_CONF" <<EOF
model=Jetson-Basler-4K
manufacturer=Custom
firmware_ver=0.1
hardware_id=JetsonOrinNX
serial_num=${ONVIF_SERIAL:-SN1234567890}

port=${ONVIF_PORT}

scope=onvif://www.onvif.org/Profile/Streaming
scope=onvif://www.onvif.org/Profile/S
scope=onvif://www.onvif.org/Profile/T

adv_enable_media2=1
EOF
      if [[ -n "${ONVIF_USER:-}" ]]; then
        printf "user=%s\npassword=%s\n" "$ONVIF_USER" "${ONVIF_PASSWORD:-}" \
          >> "$_ONVIF_SERVER_CONF"
      fi
      cat >> "$_ONVIF_SERVER_CONF" <<EOF

name=Profile_Main
width=${MAIN_WIDTH}
height=${MAIN_HEIGHT}
url=rtsp://%s:${RTSP_PORT}${MAIN_RTSP_PATH}
snapurl=
type=${MAIN_ENCODER^^}
audio_encoder=NONE
audio_decoder=NONE
EOF
      if [[ "${SUB_ENABLED:-false}" == "true" ]]; then
        cat >> "$_ONVIF_SERVER_CONF" <<EOF

name=Profile_Sub
width=${SUB_WIDTH}
height=${SUB_HEIGHT}
url=rtsp://%s:${RTSP_PORT}${SUB_RTSP_PATH}
snapurl=
type=${SUB_ENCODER^^}
audio_encoder=NONE
audio_decoder=NONE
EOF
      fi

      # onvif_simple_server opens /var/log/onvif_simple_server.log before
      # parsing args and exits if it can't write it -- pre-create it once.
      sudo touch /var/log/onvif_simple_server.log 2>/dev/null \
        && sudo chmod 666 /var/log/onvif_simple_server.log 2>/dev/null || true

      # Create a shell wrapper per service endpoint in the document root.
      # lighttpd (cgi.assign = "" => "") executes them directly; each wrapper
      # calls the binary with -c to pass our generated conf, and appends the
      # service name as a trailing arg so the binary routes to the right handler.
      mkdir -p /tmp/onvif_root/onvif
      for _svc in device_service media_service media2_service \
                  ptz_service events_service deviceio_service; do
        printf '#!/bin/sh\nexec "%s" -c "%s" %s\n' \
          "${_ONVIF_BIN}" "${_ONVIF_SERVER_CONF}" "${_svc}" \
          > "/tmp/onvif_root/onvif/${_svc}"
        chmod +x "/tmp/onvif_root/onvif/${_svc}"
      done

      _LIGHTTPD_ERRORLOG="/tmp/lighttpd_onvif.log"
      [[ "$DEBUG_MODE" -eq 1 ]] && _LIGHTTPD_ERRORLOG="/dev/stderr"
      cat > "$ONVIF_LIGHTTPD_CONF" <<EOF
server.port          = ${ONVIF_PORT}
server.bind          = "0.0.0.0"
server.document-root = "/tmp/onvif_root"
server.errorlog      = "${_LIGHTTPD_ERRORLOG}"
server.modules       = ("mod_cgi")
cgi.assign           = ( "" => "" )
EOF
      echo "Starting lighttpd (ONVIF CGI, port ${ONVIF_PORT})..."
      "$_LIGHTTPD_BIN" -D -f "$ONVIF_LIGHTTPD_CONF" &
      LIGHTTPD_PID=$!

      # wsd daemonizes itself (double-fork); -p is required or it prints usage
      # and exits. Real daemon PID is written to the pid file after fork.
      wsd_args=(
        -x "http://%s:${ONVIF_PORT}/onvif/device_service"
        -p "$WSD_PID_FILE"
      )
      [[ -n "${ONVIF_INTERFACE:-}" ]] && wsd_args+=(-i "$ONVIF_INTERFACE")
      if [[ "$DEBUG_MODE" -eq 1 ]]; then
        # -f keeps it foreground so $! is the real PID and -d 5 enables trace logging.
        # Logs go to /var/log/wsd_simple_server.log (may need sudo to read).
        wsd_args+=(-f -d 5)
        "$_WSD_BIN" "${wsd_args[@]}" &
        WSD_PID=$!
      else
        "$_WSD_BIN" "${wsd_args[@]}" >/dev/null 2>&1
        sleep 0.5
        WSD_PID=$(cat "$WSD_PID_FILE" 2>/dev/null || true)
      fi

      ONVIF_WE_STARTED=1

      READY=0
      for i in 1 2 3; do
        sleep 1
        nc -z -w1 127.0.0.1 "$ONVIF_PORT" 2>/dev/null && { READY=1; break; }
      done
      if [[ "$READY" -eq 1 ]]; then
        echo "ONVIF started -- http://<device-ip>:${ONVIF_PORT}/onvif/device_service"
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
_IDN_SILENT="true"
[[ "${DEBUG_MODE:-0}" -eq 1 ]] && _IDN_SILENT="false"
IDN_CAM="identity name=cam silent=${_IDN_SILENT} check-imperfect-timestamp=true"
IDN_PRE="identity name=pre-enc silent=${_IDN_SILENT} check-imperfect-timestamp=true"
IDN_POST="identity name=post-enc silent=${_IDN_SILENT} check-imperfect-timestamp=true"
IDN_SUB_PRE="identity name=sub-pre-enc silent=${_IDN_SILENT} check-imperfect-timestamp=true"
IDN_SUB_POST="identity name=sub-post-enc silent=${_IDN_SILENT} check-imperfect-timestamp=true"

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
if [[ "$DEBUG_MODE" -eq 1 ]]; then
echo "  Debug          : frame drop logging active (check-imperfect-timestamp)"
fi
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
if [[ "${ONVIF_ENABLED:-false}" == "true" ]]; then
echo "  ONVIF          : enabled (port ${ONVIF_PORT}) -- NVR auto-discovery active"
else
echo "  ONVIF          : disabled  (set ONVIF_ENABLED=true in stream.conf)"
fi
fi
echo "======================================================"
echo ""

# Launch (-e sends EOS on interrupt so encoder flushes cleanly)
# shellcheck disable=SC2086
gst-launch-1.0 -e $PIPELINE
