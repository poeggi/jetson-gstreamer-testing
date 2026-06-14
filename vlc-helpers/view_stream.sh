#!/usr/bin/env bash
# View an RTSP stream with low-latency VLC settings.
# Note: caching below 200ms may not work reliably with H.265 (VLC drops frames).
#
# Usage: ./vlc-helpers/view_stream.sh [main|sub|main-auth|sub-auth] [host] [port] [caching_ms]
#   main       -- 4K H.265 stream  (default, no auth)
#   sub        -- 1080p H.264 stream (no auth)
#   main-auth  -- 4K H.265 stream  (guest:guest)
#   sub-auth   -- 1080p H.264 stream (guest:guest)

STREAM="${1:-main}"
HOST="${2:-192.168.1.252}"
PORT="${3:-8554}"
CACHING="${4:-200}"

case "$STREAM" in
  main)      PATH_="/main";      CRED="" ;;
  sub)       PATH_="/sub";       CRED="" ;;
  main-auth) PATH_="/main-auth"; CRED="guest:guest@" ;;
  sub-auth)  PATH_="/sub-auth";  CRED="guest:guest@" ;;
  *)
    echo "ERROR: Unknown stream '$STREAM'. Use 'main', 'sub', 'main-auth', or 'sub-auth'."
    echo "Usage: $0 [main|sub|main-auth|sub-auth] [host] [port] [caching_ms]"
    exit 1
    ;;
esac

URL="rtsp://${CRED}${HOST}:${PORT}${PATH_}"

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
