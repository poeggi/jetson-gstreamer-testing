#!/usr/bin/env bash
# ==============================================================================
# start_wsd.sh -- start/stop WS-Discovery daemon only.
# Useful to restart discovery without restarting the full ONVIF HTTP stack.
# The ONVIF HTTP port (ONVIF_PORT) is used purely for the advertised URL.
# Usage: ./bin/start_wsd.sh [--stop] [--debug]
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
DEBUG_MODE=0

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
  local wsd_bin="${SCRIPT_DIR}/wsd_simple_server"
  [[ -x "$wsd_bin" ]] || die "wsd_simple_server not found in bin/. Run bin/sources/cross-build-windows.ps1 (Windows) or bin/sources/build-on-device.sh (Jetson)"

  # wsd opens /var/log/wsd_simple_server.log before arg parsing; fclose(NULL)
  # segfault if the file is not writable. Check before starting.
  if [[ ! -w /var/log/wsd_simple_server.log ]]; then
    echo "ERROR: /var/log/wsd_simple_server.log not writable -- wsd will segfault" >&2
    echo "       Fix once: sudo touch /var/log/wsd_simple_server.log && sudo chmod 666 /var/log/wsd_simple_server.log" >&2
    echo "       Or run  : ${REPO_DIR}/check_system.sh --autofix" >&2
    exit 1
  fi

  do_stop 2>/dev/null || true

  # -f keeps wsd foreground so $! is the real PID; write it to pid file for do_stop.
  # -p is mandatory even in foreground mode or wsd prints usage and exits.
  # Templates bundled in bin/wsd_files/; /etc/wsd_simple_server/ not required.
  local wsd_args=(
    -x "http://%s:${ONVIF_PORT}/onvif/device_service"
    -t "${SCRIPT_DIR}/wsd_files"
    -p "$WSD_PID_FILE"
    -f
  )
  [[ -n "${ONVIF_INTERFACE:-}" ]] && wsd_args+=(-i "$ONVIF_INTERFACE")
  [[ "$DEBUG_MODE" -eq 1 ]] && wsd_args+=(-d 5)

  if [[ "$DEBUG_MODE" -eq 1 ]]; then
    echo "Starting wsd_simple_server (debug -- verbose output follows)..."
    echo "  Interface   : ${ONVIF_INTERFACE:-(auto-detected by wsd)}"
    echo "  Advertising : http://<device-ip>:${ONVIF_PORT}/onvif/device_service"
    echo "  Log         : /var/log/wsd_simple_server.log"
    echo "------------------------------------------------------"
    "$wsd_bin" "${wsd_args[@]}" &
  else
    "$wsd_bin" "${wsd_args[@]}" >/dev/null 2>&1 &
  fi
  echo $! > "$WSD_PID_FILE"

  if [[ "$DEBUG_MODE" -eq 0 ]]; then
    echo "wsd_simple_server started (PID $(cat "$WSD_PID_FILE"))"
    echo "  Interface   : ${ONVIF_INTERFACE:-(auto-detected by wsd)}"
    echo "  Advertising : http://<device-ip>:${ONVIF_PORT}/onvif/device_service"
  fi
}

case "${1:-}" in
  --stop)  do_stop ;;
  --debug) DEBUG_MODE=1; do_start ;;
  "")      do_start ;;
  *)       echo "Usage: $0 [--stop] [--debug]"; exit 1 ;;
esac
