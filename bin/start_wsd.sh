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
ONVIF_INTERFACE="${ONVIF_INTERFACE:-eth0}"
WSD_PID_FILE="/tmp/wsd_simple_server.pid"

_find_bin() {
  local name="$1"
  if [[ -x "${SCRIPT_DIR}/${name}" ]]; then echo "${SCRIPT_DIR}/${name}"
  else command -v "$name" 2>/dev/null || true
  fi
}

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
  local wsd_bin
  wsd_bin=$(_find_bin wsd_simple_server)
  [[ -n "$wsd_bin" ]] || die "wsd_simple_server not found in bin/ or PATH"

  DEVICE_IP=$(ip -4 addr show "$ONVIF_INTERFACE" 2>/dev/null \
    | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 || true)
  [[ -n "$DEVICE_IP" ]] || die "Cannot determine IP for interface ${ONVIF_INTERFACE}"

  do_stop 2>/dev/null || true

  "$wsd_bin" \
    -x "http://${DEVICE_IP}:${ONVIF_PORT}/onvif/device_service" \
    -p "$WSD_PID_FILE" \
    >/dev/null 2>&1 &

  echo "wsd_simple_server started"
  echo "  Interface : ${ONVIF_INTERFACE} (${DEVICE_IP})"
  echo "  Advertising : http://${DEVICE_IP}:${ONVIF_PORT}/onvif/device_service"
}

case "${1:-}" in
  --stop) do_stop ;;
  "")     do_start ;;
  *)      echo "Usage: $0 [--stop]"; exit 1 ;;
esac
