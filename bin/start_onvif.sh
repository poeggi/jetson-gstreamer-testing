#!/usr/bin/env bash
# ==============================================================================
# start_onvif.sh -- standalone start/stop for the ONVIF server stack.
# Reads settings from stream.conf (same as send_stream.sh).
# Usage: ./bin/start_onvif.sh [--stop]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONF="${REPO_DIR}/stream.conf"
[[ -f "$CONF" ]] || { echo "ERROR: stream.conf not found at ${CONF}" >&2; exit 1; }
# shellcheck source=stream.conf
source "$CONF"

ONVIF_PORT="${ONVIF_PORT:-8080}"

LIGHTTPD_CONF="/tmp/lighttpd_onvif_standalone.conf"
LIGHTTPD_PID_FILE="/tmp/lighttpd_onvif_standalone.pid"
WSD_PID_FILE="/tmp/wsd_simple_server.pid"
ONVIF_SERVER_CONF="/tmp/onvif_simple_server_${ONVIF_PORT}.conf"

die() { echo "ERROR: $1" >&2; exit 1; }

check_deps() {
  for bin in onvif_simple_server wsd_simple_server; do
    [[ -x "${SCRIPT_DIR}/${bin}" ]] || \
      die "${bin} not found in bin/. Run bin/sources/cross-build-windows.ps1 (Windows) or bin/sources/build-on-device.sh (Jetson)"
  done
  command -v lighttpd >/dev/null 2>&1 || \
    die "lighttpd not found. Install: sudo apt install lighttpd"
}

# ------------------------------------------------------------------------------
do_stop() {
  if [[ -f "$WSD_PID_FILE" ]]; then
    kill "$(cat "$WSD_PID_FILE")" 2>/dev/null || true
    rm -f "$WSD_PID_FILE"
    echo "wsd_simple_server stopped"
  fi
  if [[ -f "$LIGHTTPD_PID_FILE" ]]; then
    kill "$(cat "$LIGHTTPD_PID_FILE")" 2>/dev/null || true
    rm -f "$LIGHTTPD_PID_FILE"
    echo "lighttpd stopped"
  fi
}

# ------------------------------------------------------------------------------
generate_onvif_conf() {
  cat > "$ONVIF_SERVER_CONF" <<EOF
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
      >> "$ONVIF_SERVER_CONF"
  fi
  cat >> "$ONVIF_SERVER_CONF" <<EOF

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
  local onvif_bin="${SCRIPT_DIR}/onvif_simple_server"

  # onvif_simple_server opens /var/log/onvif_simple_server.log before parsing
  # args and exits if it can't write it. Pre-create once via check_system.sh
  # --autofix; warn here if it hasn't been done yet.
  if [[ ! -w /var/log/onvif_simple_server.log ]]; then
    echo "WARNING: /var/log/onvif_simple_server.log not writable -- ONVIF CGI will fail" >&2
    echo "         Fix once: sudo touch /var/log/onvif_simple_server.log && sudo chmod 666 /var/log/onvif_simple_server.log" >&2
  fi

  # Shell wrapper per service: calls binary with -c to pass our conf and
  # appends the service name so the binary routes to the right handler.
  mkdir -p /tmp/onvif_root/onvif
  for _svc in device_service media_service media2_service \
              ptz_service events_service deviceio_service; do
    printf '#!/bin/sh\nexec "%s" -c "%s" %s\n' \
      "${onvif_bin}" "${ONVIF_SERVER_CONF}" "${_svc}" \
      > "/tmp/onvif_root/onvif/${_svc}"
    chmod +x "/tmp/onvif_root/onvif/${_svc}"
  done

  cat > "$LIGHTTPD_CONF" <<EOF
server.port          = ${ONVIF_PORT}
server.bind          = "0.0.0.0"
server.document-root = "/tmp/onvif_root"
server.pid-file      = "${LIGHTTPD_PID_FILE}"
server.errorlog      = "/tmp/lighttpd_onvif.log"
server.modules       = ("mod_cgi")
cgi.assign           = ( "" => "" )
EOF
}

# ------------------------------------------------------------------------------
do_start() {
  check_deps
  do_stop

  generate_onvif_conf
  generate_lighttpd_conf

  local wsd_bin="${SCRIPT_DIR}/wsd_simple_server" wsd_args
  # -f keeps wsd foreground so $! is the real PID; we write it to the pid file
  # for do_stop. Templates bundled alongside; /etc/wsd_simple_server/ not needed.
  wsd_args=(
    -x "http://%s:${ONVIF_PORT}/onvif/device_service"
    -t "${SCRIPT_DIR}/wsd_files"
    -f
  )
  # Pass explicit interface override only when set; otherwise wsd auto-detects
  [[ -n "${ONVIF_INTERFACE:-}" ]] && wsd_args+=(-i "$ONVIF_INTERFACE")
  "$wsd_bin" "${wsd_args[@]}" >/dev/null 2>&1 &
  echo $! > "$WSD_PID_FILE"

  lighttpd -f "$LIGHTTPD_CONF"

  echo "======================================================"
  echo "  ONVIF server running"
  echo "  Interface : ${ONVIF_INTERFACE:-(auto-detected by wsd)}"
  echo "  ONVIF URL : http://<device-ip>:${ONVIF_PORT}/onvif/device_service"
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
