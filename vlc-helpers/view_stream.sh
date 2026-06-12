#!/usr/bin/env bash
# View an RTSP stream with low-latency VLC settings.
# Note: caching below 200ms may not work reliably with H.265 (VLC drops frames).
#
# Usage: ./view_stream.sh [main|sub] [host] [port] [caching_ms]
#   main  -- 4K H.265 stream  (default)
#   sub   -- 1080p H.264 stream

STREAM="${1:-main}"
HOST="${2:-192.168.1.252}"
PORT="${3:-8554}"
CACHING="${4:-200}"

case "$STREAM" in
  main) PATH_="/main" ;;
  sub)  PATH_="/sub" ;;
  *)
    echo "ERROR: Unknown stream '$STREAM'. Use 'main' or 'sub'."
    echo "Usage: $0 [main|sub] [host] [port] [caching_ms]"
    exit 1
    ;;
esac

URL="rtsp://${HOST}:${PORT}${PATH_}"

if command -v vlc >/dev/null 2>&1; then
    echo "Connecting to ${STREAM} stream: $URL (caching=${CACHING}ms)"
    vlc --rtsp-tcp --network-caching="$CACHING" --clock-synchro=0 --no-audio "$URL"
elif command -v cvlc >/dev/null 2>&1; then
    echo "Connecting to ${STREAM} stream: $URL (caching=${CACHING}ms)"
    cvlc --rtsp-tcp --network-caching="$CACHING" --clock-synchro=0 --no-audio "$URL"
else
    echo "ERROR: VLC not found. Install with: sudo apt install vlc"
    exit 1
fi
