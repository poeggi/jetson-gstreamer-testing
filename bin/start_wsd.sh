#!/usr/bin/env bash
# ==============================================================================
# start_wsd.sh -- start/stop WS-Discovery daemon only.
# Useful to restart discovery without restarting the full ONVIF HTTP stack.
# The ONVIF HTTP port (ONVIF_PORT) is used purely for the advertised URL.
# Usage: ./bin/start_wsd.sh [--stop]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONF="${REPO_DIR}/stream.conf"
[[ -f "$CONF" ]] || { echo "ERROR: stream.conf not found at ${CONF}" >&2; exit 1; }
# shellcheck source=stream.conf
source "$CONF"

ONVIF_PORT="${ONVIF_PORT:-8080}"
WSD_PID_FILE="/tmp/wsd_simple_server.pid"

die() { echo "ERROR: $1" >&2; exit 1; }

do_stop() {
  if [[ -f "$WSD_PID_FILE" ]]; then
    kill "$(cat "$WSD_PID_FILE")" 2>/dev/null || true
    rm -f "$WSD_PID_FILE"
    echo "wsd_simple_server stopped"
  else
    echo "wsd_simple_server: no PID file found"
  fi
}

do_start() {
  local wsd_bin="${SCRIPT_DIR}/wsd_simple_server" wsd_args
  [[ -x "$wsd_bin" ]] || die "wsd_simple_server not found in bin/. Run bin/sources/cross-build-windows.ps1 (Windows) or bin/sources/build-on-device.sh (Jetson)"

  do_stop 2>/dev/null || true

  wsd_args=(
    -x "http://%s:${ONVIF_PORT}/onvif/device_service"
    -6 "http://[%s]:${ONVIF_PORT}/onvif/device_service"
    -p "$WSD_PID_FILE"
  )
  # Pass explicit interface override only when set; otherwise wsd auto-detects
  [[ -n "${ONVIF_INTERFACE:-}" ]] && wsd_args+=(-i "$ONVIF_INTERFACE")
  "$wsd_bin" "${wsd_args[@]}" >/dev/null 2>&1 &

  echo "wsd_simple_server started"
  echo "  Interface : ${ONVIF_INTERFACE:-(auto-detected by wsd)}"
  echo "  Advertising : http://<device-ip>:${ONVIF_PORT}/onvif/device_service"
}

case "${1:-}" in
  --stop) do_stop ;;
  "")     do_start ;;
  *)      echo "Usage: $0 [--stop]"; exit 1 ;;
esac
