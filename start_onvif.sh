#!/usr/bin/env bash
# ==============================================================================
# start_onvif.sh
#
# Standalone start/stop for the ONVIF server stack.
# Reads settings from stream.conf -- no separate ONVIF conf file needed.
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
CONF="${SCRIPT_DIR}/stream.conf"
[[ -f "$CONF" ]] || { echo "ERROR: stream.conf not found at ${CONF}" >&2; exit 1; }
# shellcheck source=stream.conf
source "$CONF"

ONVIF_PORT="${ONVIF_PORT:-8080}"
ONVIF_INTERFACE="${ONVIF_INTERFACE:-eth0}"

LIGHTTPD_CONF="/tmp/lighttpd_onvif_standalone.conf"
LIGHTTPD_PID_FILE="/tmp/lighttpd_onvif_standalone.pid"
WSD_PID_FILE="/tmp/wsd_simple_server.pid"
ONVIF_SERVER_CONF="/tmp/onvif_simple_server_${ONVIF_PORT}.conf"

# ------------------------------------------------------------------------------
die() { echo "ERROR: $1" >&2; exit 1; }

check_deps() {
  for bin in onvif_simple_server wsd_simple_server lighttpd; do
    command -v "$bin" >/dev/null 2>&1 || \
      die "$bin not found. See github.com/roleoroleo/onvif_simple_server"
  done
}

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
generate_onvif_conf() {
  cat > "$ONVIF_SERVER_CONF" <<EOF
model=Jetson-Basler-4K
manufacturer=Custom
firmware_ver=0.1
hardware_id=JetsonOrinNX
serial_num=000000000001

ifs=${ONVIF_INTERFACE}
port=${ONVIF_PORT}

scope=onvif://www.onvif.org/Profile/Streaming
scope=onvif://www.onvif.org/Profile/S
scope=onvif://www.onvif.org/Profile/T

adv_enable_media2=1

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
    cat >> "$ONVIF_SERVER_CONF" <<EOF

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
}

generate_lighttpd_conf() {
  local onvif_bin
  onvif_bin=$(command -v onvif_simple_server)
  mkdir -p /tmp/onvif_root/onvif
  cat > "$LIGHTTPD_CONF" <<EOF
server.port          = ${ONVIF_PORT}
server.bind          = "0.0.0.0"
server.document-root = "/tmp/onvif_root"
server.pid-file      = "${LIGHTTPD_PID_FILE}"
server.errorlog      = "/tmp/lighttpd_onvif.log"
server.modules       = ("mod_cgi", "mod_setenv")
setenv.add-environment = ("CONF_FILE" => "${ONVIF_SERVER_CONF}")
cgi.assign = ( "/onvif/" => "${onvif_bin}" )
EOF
}

# ------------------------------------------------------------------------------
do_start() {
  check_deps
  do_stop

  generate_onvif_conf
  generate_lighttpd_conf

  DEVICE_IP=$(ip -4 addr show "$ONVIF_INTERFACE" 2>/dev/null \
    | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 || true)
  [[ -n "$DEVICE_IP" ]] || die "Cannot determine IP for interface ${ONVIF_INTERFACE}"

  wsd_simple_server \
    -i "$ONVIF_INTERFACE" \
    -x "http://${DEVICE_IP}:${ONVIF_PORT}/onvif/device_service" \
    -p "$WSD_PID_FILE" \
    >/dev/null 2>&1 &

  lighttpd -f "$LIGHTTPD_CONF"

  echo "======================================================"
  echo "  ONVIF server running"
  echo "  Interface : ${ONVIF_INTERFACE} (${DEVICE_IP})"
  echo "  ONVIF URL : http://${DEVICE_IP}:${ONVIF_PORT}/onvif/device_service"
  echo "  Discovery : WS-Discovery active (UDP 3702)"
  _STREAMS="MAIN (${MAIN_ENCODER^^} ${MAIN_WIDTH}x${MAIN_HEIGHT})"
  [[ "${SUB_ENABLED:-false}" == "true" ]] && _STREAMS="${_STREAMS}, SUB (${SUB_ENCODER^^} ${SUB_WIDTH}x${SUB_HEIGHT})"
  echo "  Streams   : ${_STREAMS}"
  echo "======================================================"
}

# ------------------------------------------------------------------------------
case "${1:-}" in
  --stop) do_stop ;;
  "")     do_start ;;
  *)      echo "Usage: $0 [--stop]"; exit 1 ;;
esac
