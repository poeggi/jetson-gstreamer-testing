#!/usr/bin/env bash
# Receive and display the RTSP stream locally using GStreamer hardware decode.
# Requires: NVDEC (nvv4l2decoder) and a display (nv3dsink).
# Usage: ./receive_stream.sh [host] [port] [path]

HOST="${1:-127.0.0.1}"
PORT="${2:-8554}"
PATH_="${3:-/main}"
LATENCY="${4:-200}"

URL="rtsp://${HOST}:${PORT}${PATH_}"

echo "Receiving $URL (latency=${LATENCY}ms, hardware decode)"

# Try hardware sinks in order, fall back to software
if gst-inspect-1.0 nv3dsink >/dev/null 2>&1; then
    SINK="nv3dsink"
elif gst-inspect-1.0 nveglglessink >/dev/null 2>&1; then
    SINK="nveglglessink"
else
    SINK="autovideosink"
fi

echo "  Using sink: ${SINK}"

gst-launch-1.0 \
  rtspsrc location="$URL" latency="$LATENCY" protocols=tcp \
  ! rtph264depay \
  ! h264parse \
  ! nvv4l2decoder \
  ! nvvidconv \
  ! "video/x-raw(memory:NVMM),format=NV12,width=2048,height=1080" \
  ! "${SINK}" sync=false
