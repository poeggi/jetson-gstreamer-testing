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

gst-launch-1.0 \
  rtspsrc location="$URL" latency="$LATENCY" protocols=tcp \
  ! rtph264depay \
  ! h264parse \
  ! nvv4l2decoder \
  ! nvvidconv \
  ! nveglglessink sync=false
