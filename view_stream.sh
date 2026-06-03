#!/usr/bin/env bash
# View the RTSP stream with low-latency settings.
# Usage: ./view_stream.sh [host] [port] [path] [caching_ms]

HOST="${1:-192.168.1.252}"
PORT="${2:-8554}"
PATH_="${3:-/main}"
CACHING="${4:-200}"

URL="rtsp://${HOST}:${PORT}${PATH_}"

if command -v vlc >/dev/null 2>&1; then
    echo "Connecting to $URL (caching=${CACHING}ms)"
    vlc --rtsp-tcp --network-caching="$CACHING" --clock-synchro=0 --no-audio "$URL"
elif command -v cvlc >/dev/null 2>&1; then
    echo "Connecting to $URL (caching=${CACHING}ms)"
    cvlc --rtsp-tcp --network-caching="$CACHING" --clock-synchro=0 --no-audio "$URL"
else
    echo "ERROR: VLC not found. Install with: sudo apt install vlc"
    exit 1
fi
