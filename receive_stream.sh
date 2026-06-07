#!/usr/bin/env bash
# Receive and display an RTSP stream locally using GStreamer hardware decode.
# Requires: NVDEC (nvv4l2decoder) and a display (nv3dsink).
#
# Usage: ./receive_stream.sh [main|sub] [host] [port] [latency_ms]
#   main  -- 4K stream, scaled to 50% (2048x1080) for display  (default)
#   sub   -- 1080p stream, displayed at native resolution

STREAM="${1:-main}"
HOST="${2:-127.0.0.1}"
PORT="${3:-8554}"
LATENCY="${4:-200}"

case "$STREAM" in
  main)
    PATH_="/main"
    SCALE_CAPS="video/x-raw(memory:NVMM),format=NV12,width=2048,height=1080"  # 50% of 4096x2160
    WIN_W=2048
    WIN_H=1080
    ;;
  sub)
    PATH_="/sub"
    SCALE_CAPS="video/x-raw(memory:NVMM),format=NV12,width=1920,height=1080"  # native 1080p
    WIN_W=1920
    WIN_H=1080
    ;;
  *)
    echo "ERROR: Unknown stream '$STREAM'. Use 'main' or 'sub'."
    echo "Usage: $0 [main|sub] [host] [port] [latency_ms]"
    exit 1
    ;;
esac

URL="rtsp://${HOST}:${PORT}${PATH_}"
echo "Receiving ${STREAM} stream: $URL (latency=${LATENCY}ms)"

gst-launch-1.0 \
  rtspsrc location="$URL" latency="$LATENCY" protocols=tcp \
  ! rtph264depay \
  ! h264parse \
  ! nvv4l2decoder \
  ! nvvidconv \
  ! "${SCALE_CAPS}" \
  ! nv3dsink window-width=${WIN_W} window-height=${WIN_H} sync=false
