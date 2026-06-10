#!/usr/bin/env bash
# ==============================================================================
# start_onvif.sh
#
# Starts the ONVIF server stack alongside MediaMTX so NVRs can discover
# and record the streams without manual RTSP URL entry.
#
# Stack:
#   lighttpd            -- HTTP server, serves onvif_simple_server as CGI
#   onvif_simple_server -- CGI handler for ONVIF SOAP requests
#   wsd_simple_server   -- WS-Discovery daemon (UDP 3702, NVR auto-discovery)
#
# Prerequisites (no prebuilt ARM64 binaries -- must build from source):
#   github.com/roleoroleo/onvif_simple_server
#   sudo apt install lighttpd
#
# Usage: ./start_onvif.sh [--stop]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="${SCRIPT_DIR}/onvif_simple_server.conf"
LIGHTTPD_CONF="${SCRIPT_DIR}/lighttpd_onvif.conf"
WSD_PID_FILE="/var/run/wsd_simple_server.pid"
LIGHTTPD_PID_FILE="/var/run/lighttpd_onvif.pid"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
die() { echo "ERROR: $1" >&2; exit 1; }

check_deps() {
  for bin in onvif_simple_server wsd_simple_server lighttpd; do
    command -v "$bin" >/dev/null 2>&1 || \
      die "$bin not found. See github.com/roleoroleo/onvif_simple_server"
  done
  [[ -f "$CONF" ]] || die "onvif_simple_server.conf not found at ${CONF}"
}

# Read interface and port from config
read_conf() {
  IFS_NAME=$(grep "^ifs=" "$CONF" | cut -d= -f2 | tr -d ' ')
  PORT=$(grep "^port=" "$CONF" | cut -d= -f2 | tr -d ' ')
  IFS_NAME="${IFS_NAME:-eth0}"
  PORT="${PORT:-8080}"
}

# ------------------------------------------------------------------------------
# Stop
# ------------------------------------------------------------------------------
do_stop() {
  if [[ -f "$LIGHTTPD_PID_FILE" ]]; then
    kill "$(cat "$LIGHTTPD_PID_FILE")" 2>/dev/null || true
    rm -f "$LIGHTTPD_PID_FILE"
    echo "lighttpd stopped"
  fi
  if [[ -f "$WSD_PID_FILE" ]]; then
    kill "$(cat "$WSD_PID_FILE")" 2>/dev/null || true
    rm -f "$WSD_PID_FILE"
    echo "wsd_simple_server stopped"
  fi
}

# ------------------------------------------------------------------------------
# Generate minimal lighttpd config pointing CGI at onvif_simple_server
# ------------------------------------------------------------------------------
write_lighttpd_conf() {
  local onvif_bin
  onvif_bin=$(command -v onvif_simple_server)
  cat > "$LIGHTTPD_CONF" <<EOF
server.port          = ${PORT}
server.bind          = "0.0.0.0"
server.document-root = "/tmp/onvif_root"
server.pid-file      = "${LIGHTTPD_PID_FILE}"
server.errorlog      = "/var/log/lighttpd_onvif.log"
server.modules       = ("mod_cgi")
cgi.assign = ( "/onvif/" => "${onvif_bin}" )
EOF
  mkdir -p /tmp/onvif_root/onvif
}

# ------------------------------------------------------------------------------
# Start
# ------------------------------------------------------------------------------
do_start() {
  check_deps
  read_conf

  # Stop any existing instance first
  do_stop

  write_lighttpd_conf

  # WS-Discovery -- allows NVRs to auto-discover the device on the LAN
  DEVICE_IP=$(ip -4 addr show "$IFS_NAME" 2>/dev/null \
    | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 || true)
  [[ -n "$DEVICE_IP" ]] || die "Cannot determine IP for interface ${IFS_NAME}"

  wsd_simple_server \
    -i "$IFS_NAME" \
    -x "http://${DEVICE_IP}:${PORT}/onvif/device_service" \
    -p "$WSD_PID_FILE" \
    >/dev/null 2>&1 &

  # lighttpd (serves onvif_simple_server CGI)
  lighttpd -f "$LIGHTTPD_CONF"

  echo "======================================================"
  echo "  ONVIF server running"
  echo "  Interface : ${IFS_NAME} (${DEVICE_IP})"
  echo "  ONVIF URL : http://${DEVICE_IP}:${PORT}/onvif/device_service"
  echo "  Discovery : WS-Discovery active (UDP 3702)"
  echo "  Streams   : /main (H.265 4K)  /sub (H.264 1080p)"
  echo "======================================================"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
case "${1:-}" in
  --stop) do_stop ;;
  "")     do_start ;;
  *)      echo "Usage: $0 [--stop]"; exit 1 ;;
esac
