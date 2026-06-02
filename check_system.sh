#!/usr/bin/env bash
# ==============================================================================
# check_system.sh
#
# Dependency and system health checks for basler_pipeline.sh.
# Called automatically by basler_pipeline.sh before launch (quiet mode).
# Run manually for full diagnostic output:
#
#   ./check_system.sh [bayer|color] [h264|h265] [rtsp|fakesink]
#
# Arguments are optional and default to the same values as the pipeline script.
# Exit code: 0 = all critical checks pass, 1 = one or more failures.
# Warnings do not affect the exit code but should be addressed for production.
# ==============================================================================

set -euo pipefail


# ==============================================================================
# ARGUMENTS
# ==============================================================================

QUIET=0
CAPTURE_MODE="bayer"
ENCODER="h265"
OUTPUT_MODE="rtsp"

for arg in "$@"; do
  case "$arg" in
    --quiet)          QUIET=1 ;;
    bayer|color)      CAPTURE_MODE="$arg" ;;
    h264|h265)        ENCODER="$arg" ;;
    rtsp|fakesink)    OUTPUT_MODE="$arg" ;;
    *)
      echo "Usage: $0 [--quiet] [bayer|color] [h264|h265] [rtsp|fakesink]" >&2
      exit 1
      ;;
  esac
done


# ==============================================================================
# OUTPUT HELPERS
# ==============================================================================

FAILURES=0
WARNINGS=0

section() { [[ "$QUIET" -eq 0 ]] && echo "" && echo "--- $1 ---"; return 0; }
ok()      { [[ "$QUIET" -eq 0 ]] && echo "  [OK]   $1"; return 0; }
info()    { [[ "$QUIET" -eq 0 ]] && echo "  [INFO] $1"; return 0; }
warn()    { echo "  [WARN] $1"; WARNINGS=$(( WARNINGS + 1 )); }
fail()    { echo "  [FAIL] $1"; FAILURES=$(( FAILURES + 1 )); }


# ==============================================================================
# 1 - GSTREAMER DEPENDENCIES
# ==============================================================================

section "GStreamer dependencies"

check_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "command not found: $1  -- fix: $2"
  else
    ok "command: $1"
  fi
}

check_plugin() {
  if ! gst-inspect-1.0 "$1" >/dev/null 2>&1; then
    fail "GStreamer plugin missing: $1  -- fix: $2"
  else
    ok "plugin: $1"
  fi
}

check_cmd gst-launch-1.0  "sudo apt install gstreamer1.0-tools"
check_cmd gst-inspect-1.0 "sudo apt install gstreamer1.0-tools"
check_cmd nc              "sudo apt install netcat-openbsd"

check_plugin pylonsrc  "install Basler pylon GStreamer package from baslerweb.com/downloads"

# NVMM support check -- mandatory for zero-copy color capture.
# Basler pylon GStreamer plugin >= 2.x advertises video/x-raw(memory:NVMM)
# when built against the Jetson CUDA/NVMM headers. Without this, the color
# capture path must copy every frame from system RAM into GPU memory via
# nvvidconv (one full-frame DMA per frame). bayer mode still requires one
# system RAM -> NVMM copy regardless (bayer2rgb has no NVMM counterpart).
_PYLON_CAPS=$(gst-inspect-1.0 pylonsrc 2>/dev/null || true)
if [[ -n "$_PYLON_CAPS" ]]; then
  if echo "$_PYLON_CAPS" | grep -qi "memory:NVMM"; then
    ok "pylonsrc NVMM caps: zero-copy color capture path available"
  else
    fail "pylonsrc does not advertise NVMM caps (memory:NVMM)"
    fail "     Color capture requires a system RAM -> GPU copy per frame."
    fail "     Upgrade to an NVMM-capable pylon GStreamer plugin:"
    fail "     github.com/basler/gst-plugin-pylon/releases"
  fi
fi

check_plugin nvvidconv  "re-run JetPack installer"
check_plugin identity   "sudo apt install gstreamer1.0-plugins-base"

if [[ "$CAPTURE_MODE" == "bayer" ]]; then
  check_plugin bayer2rgb "sudo apt install gstreamer1.0-plugins-bad"
fi

case "$ENCODER" in
  h264)
    check_plugin nvv4l2h264enc "re-run JetPack installer"
    check_plugin h264parse     "sudo apt install gstreamer1.0-plugins-bad"
    ;;
  h265)
    check_plugin nvv4l2h265enc "re-run JetPack installer"
    check_plugin h265parse     "sudo apt install gstreamer1.0-plugins-bad"
    ;;
esac

if [[ "$OUTPUT_MODE" == "rtsp" ]]; then
  case "$ENCODER" in
    h264) check_plugin rtph264pay "sudo apt install gstreamer1.0-plugins-good" ;;
    h265) check_plugin rtph265pay "sudo apt install gstreamer1.0-plugins-good" ;;
  esac
  check_plugin rtspclientsink "sudo apt install gstreamer1.0-plugins-bad"

  # Find the MediaMTX binary. The pipeline script will start it automatically
  # if not already running, so we verify it is findable and actually starts.
  RTSP_HOST="${RTSP_HOST:-127.0.0.1}"
  RTSP_PORT="${RTSP_PORT:-8554}"
  SCRIPT_DIR_CHECK="$(cd "$(dirname "$0")" && pwd)"

  MEDIAMTX_BIN=""
  for loc in \
    "$(command -v mediamtx 2>/dev/null || true)" \
    /usr/local/bin/mediamtx \
    "${HOME}/mediamtx" \
    "${SCRIPT_DIR_CHECK}/mediamtx"; do
    [[ -n "$loc" && -x "$loc" ]] && { MEDIAMTX_BIN="$loc"; break; }
  done

  if [[ -z "$MEDIAMTX_BIN" ]]; then
    fail "mediamtx binary not found in PATH or common locations"
    fail "     Download for ARM64 from: github.com/bluenviron/mediamtx/releases"
    fail "     Place in /usr/local/bin/ or alongside these scripts"
  else
    ok "mediamtx binary: ${MEDIAMTX_BIN}"

    # If already running, just confirm; otherwise start briefly to verify it works.
    MEDIAMTX_CHECK_PID=""
    if nc -z -w1 "$RTSP_HOST" "$RTSP_PORT" 2>/dev/null; then
      ok "MediaMTX already running at ${RTSP_HOST}:${RTSP_PORT}"
    else
      [[ "$QUIET" -eq 0 ]] && echo "  [....] Starting MediaMTX briefly to verify..."
      "$MEDIAMTX_BIN" >/dev/null 2>&1 &
      MEDIAMTX_CHECK_PID=$!
      STARTED=0
      for i in 1 2 3 4 5; do
        sleep 1
        if nc -z -w1 "$RTSP_HOST" "$RTSP_PORT" 2>/dev/null; then
          STARTED=1; break
        fi
      done
      if [[ "$STARTED" -eq 1 ]]; then
        ok "MediaMTX starts successfully"
      else
        fail "MediaMTX found but did not start within 5 seconds"
      fi
      kill "$MEDIAMTX_CHECK_PID" 2>/dev/null || true
      wait "$MEDIAMTX_CHECK_PID" 2>/dev/null || true
    fi
  fi
fi


# ==============================================================================
# 2 - USB BUFFER MEMORY
# usbfs_memory_mb caps the RAM the USB subsystem can pin for DMA buffers.
# The pylon SDK pre-allocates a ring of capture buffers (default: 10 buffers).
# At 12 MP BayerRG8: 10 x 12.3 MB = 123 MB minimum. 256 MB gives 2x headroom
# for a single camera. Scale to 512 MB if running two cameras on one host.
# The kernel default of 16 MB causes immediate frame drops at this resolution.
# ==============================================================================

section "USB buffer memory"

USB_MEM_FILE="/sys/module/usbcore/parameters/usbfs_memory_mb"
USB_MEM_MIN=256

if [[ -f "$USB_MEM_FILE" ]]; then
  USB_MEM=$(cat "$USB_MEM_FILE")
  if [[ "$USB_MEM" -lt "$USB_MEM_MIN" ]]; then
    warn "usbfs_memory_mb = ${USB_MEM} MB -- too low (need >= ${USB_MEM_MIN} MB for single 12 MP camera)"
    warn "     Fix now : sudo sh -c 'echo ${USB_MEM_MIN} > ${USB_MEM_FILE}'"
    warn "     Persist : add the above line to /etc/rc.local before 'exit 0'"
  else
    ok "usbfs_memory_mb = ${USB_MEM} MB"
  fi
else
  warn "Cannot read ${USB_MEM_FILE} -- usbcore module may not be loaded"
fi


# ==============================================================================
# 3 - JETSON POWER AND CLOCK CONFIGURATION
# nvpmodel and jetson_clocks control CPU, GPU and memory clock limits.
# Running in a low-power mode caps clocks and will cause pipeline stalls.
# ==============================================================================

section "Jetson power and clock configuration"

# nvpmodel: check for MAXN (mode 0 = all engines at maximum)
if command -v nvpmodel >/dev/null 2>&1; then
  POWER_LINE=$(nvpmodel -q 2>/dev/null | grep "NV Power Mode" | head -1 || true)
  if echo "$POWER_LINE" | grep -q "MAXN"; then
    ok "nvpmodel: $POWER_LINE"
  else
    warn "nvpmodel: $POWER_LINE"
    warn "     Fix: sudo nvpmodel -m 0  (MAXN = unrestricted performance)"
  fi
else
  warn "nvpmodel not found -- cannot verify power mode"
fi

# CPU frequency governor.
# jetson_clocks does NOT change the governor name -- it pins the clock by
# setting scaling_min_freq = scaling_max_freq, leaving the governor as
# 'schedutil'. Both 'performance' and a pinned 'schedutil' are acceptable.
# Only flag governors that can actually reduce the clock (e.g. powersave).
GOV_FILE="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
MIN_FILE="/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq"
MAX_FILE_GOV="/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq"
if [[ -f "$GOV_FILE" ]]; then
  GOV=$(cat "$GOV_FILE")
  PINNED=0
  if [[ -f "$MIN_FILE" && -f "$MAX_FILE_GOV" ]]; then
    GOV_MIN=$(cat "$MIN_FILE")
    GOV_MAX=$(cat "$MAX_FILE_GOV")
    [[ "$GOV_MIN" -eq "$GOV_MAX" ]] && PINNED=1
  fi
  if [[ "$GOV" == "performance" || "$PINNED" -eq 1 ]]; then
    ok "CPU governor: ${GOV}$([ "$PINNED" -eq 1 ] && echo " (clocks pinned at max -- jetson_clocks active)")"
  else
    warn "CPU governor: ${GOV} -- clocks are not pinned and may scale down"
    warn "     Fix: sudo jetson_clocks"
  fi
else
  warn "Cannot read CPU governor from ${GOV_FILE}"
fi

# CPU clock: compare current vs maximum to detect throttling or jetson_clocks off
CUR_FILE="/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
MAX_FILE="/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq"
if [[ -f "$CUR_FILE" && -f "$MAX_FILE" ]]; then
  CUR=$(cat "$CUR_FILE")
  MAX=$(cat "$MAX_FILE")
  PCT=$(( CUR * 100 / MAX ))
  CUR_GHZ=$(awk "BEGIN {printf \"%.2f\", ${CUR}/1000000}")
  MAX_GHZ=$(awk "BEGIN {printf \"%.2f\", ${MAX}/1000000}")
  if [[ "$PCT" -lt 90 ]]; then
    warn "CPU0 clock: ${CUR_GHZ} GHz (${PCT}% of ${MAX_GHZ} GHz max)"
    warn "     Possible cause: jetson_clocks not running, or thermal throttle"
    warn "     Fix: sudo jetson_clocks"
  else
    ok "CPU0 clock: ${CUR_GHZ} GHz (${PCT}% of ${MAX_GHZ} GHz max)"
  fi
fi


# ==============================================================================
# 4 - THERMAL THROTTLING
# If the SoC is hot, the kernel reduces clock speeds automatically.
# This can cause the pipeline to stall and drop frames unpredictably.
# ==============================================================================

section "Thermal state"

THROTTLED=0
for POLICY in /sys/devices/system/cpu/cpufreq/policy*/; do
  [[ -f "${POLICY}scaling_cur_freq" && -f "${POLICY}scaling_max_freq" ]] || continue
  CUR=$(cat "${POLICY}scaling_cur_freq")
  MAX=$(cat "${POLICY}scaling_max_freq")
  PCT=$(( CUR * 100 / MAX ))
  NAME=$(basename "$POLICY")
  if [[ "$PCT" -lt 80 ]]; then
    warn "Thermal throttle on ${NAME}: running at ${PCT}% of max clock"
    THROTTLED=1
  else
    ok "${NAME}: ${PCT}% of max clock"
  fi
done

# SoC temperature zones
for ZONE in /sys/class/thermal/thermal_zone*/; do
  [[ -f "${ZONE}temp" && -f "${ZONE}type" ]] || continue
  ZONE_TYPE=$(cat "${ZONE}type")
  TEMP_RAW=$(cat "${ZONE}temp")
  TEMP_C=$(awk "BEGIN {printf \"%.1f\", ${TEMP_RAW}/1000}")
  # Warn above 80 C
  TEMP_INT=$(( TEMP_RAW / 1000 ))
  if [[ "$TEMP_INT" -ge 80 ]]; then
    warn "High temperature: ${ZONE_TYPE} = ${TEMP_C} C -- thermal throttle likely"
  elif [[ "$TEMP_INT" -ge 70 ]]; then
    warn "Elevated temperature: ${ZONE_TYPE} = ${TEMP_C} C -- monitor for throttle"
  else
    ok "Thermal zone ${ZONE_TYPE}: ${TEMP_C} C"
  fi
done


# ==============================================================================
# 5 - KERNEL TRACING AND DEBUG OVERHEAD
# Active ftrace, high GST_DEBUG levels, and kernel debug features add
# scheduling latency and can cause dropped frames.
# ==============================================================================

section "Debug and tracing overhead"

# GST_DEBUG: if set it causes per-buffer logging overhead in every element
if [[ -n "${GST_DEBUG:-}" ]]; then
  warn "GST_DEBUG is set: '${GST_DEBUG}'"
  warn "     Per-element logging adds CPU overhead -- unset for production"
  warn "     Unset: unset GST_DEBUG"
else
  ok "GST_DEBUG is not set"
fi

# ftrace: active kernel function tracing adds measurable scheduling latency
FTRACE_FILE="/sys/kernel/debug/tracing/tracing_on"
if [[ -f "$FTRACE_FILE" ]]; then
  FTRACE=$(cat "$FTRACE_FILE" 2>/dev/null || echo "0")
  if [[ "$FTRACE" == "1" ]]; then
    warn "ftrace is active -- kernel function tracing adds scheduling overhead"
    warn "     Disable: sudo sh -c 'echo 0 > ${FTRACE_FILE}'"
  else
    ok "ftrace is inactive"
  fi
fi

# perf: check if perf_event_paranoid is restrictive (informational only)
PERF_FILE="/proc/sys/kernel/perf_event_paranoid"
if [[ -f "$PERF_FILE" ]]; then
  PERF_VAL=$(cat "$PERF_FILE")
  info "perf_event_paranoid = ${PERF_VAL}"
fi


# ==============================================================================
# 6 - CAMERA HARDWARE DETECTION
# ==============================================================================

section "Camera hardware"

# Basler USB vendor ID is 0x2676.
# Speed is read from sysfs rather than parsing lsusb -t output.
# The sysfs 'speed' file reports the negotiated link speed in Mbps:
#   480   = USB 2.0 High Speed  (far too slow for 12 MP)
#   5000  = USB 3.1 Gen1 SuperSpeed  (correct)
#   10000 = USB 3.1 Gen2 SuperSpeed+ (correct)
BASLER_VID="2676"
BASLER_DEV_PATH=""

for DEV_PATH in /sys/bus/usb/devices/*/; do
  [[ -f "${DEV_PATH}idVendor" ]] || continue
  VENDOR=$(cat "${DEV_PATH}idVendor" 2>/dev/null || echo "")
  if [[ "$VENDOR" == "$BASLER_VID" ]]; then
    BASLER_DEV_PATH="$DEV_PATH"
    break
  fi
done

if [[ -n "$BASLER_DEV_PATH" ]]; then
  PRODUCT=$(cat "${BASLER_DEV_PATH}product" 2>/dev/null || echo "unknown model")
  SPEED=$(cat   "${BASLER_DEV_PATH}speed"   2>/dev/null || echo "unknown")
  ok "Basler camera detected: ${PRODUCT}"

  case "$SPEED" in
    5000)
      ok "USB connection speed: ${SPEED} Mbps -- USB 3.1 Gen1 SuperSpeed (correct)"
      ;;
    10000)
      ok "USB connection speed: ${SPEED} Mbps -- USB 3.1 Gen2 SuperSpeed+ (correct)"
      ;;
    480)
      fail "USB connection speed: ${SPEED} Mbps -- USB 2.0 High Speed"
      fail "     Camera is on a USB 2.0 port or hub. At 12MP/25fps the pipeline"
      fail "     needs 307 MB/s; USB 2.0 provides ~40 MB/s. Plug directly into"
      fail "     a USB 3.x blue port on the Jetson carrier board."
      ;;
    *)
      warn "USB connection speed: ${SPEED} Mbps -- expected 5000 or 10000"
      ;;
  esac
else
  warn "No Basler camera detected in sysfs (vendor ID ${BASLER_VID})"
  warn "     Verify camera is powered on and USB cable is firmly seated"
  warn "     Check: lsusb | grep ${BASLER_VID}"
fi


# ==============================================================================
# 7 - AVAILABLE MEMORY
# Pipeline buffers, NVMM surfaces, and encoder working memory compete for RAM.
# ==============================================================================

section "Available memory"

AVAIL_MB=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print int($2/1024)}' || echo 0)
if [[ "$AVAIL_MB" -gt 0 ]]; then
  if [[ "$AVAIL_MB" -lt 1500 ]]; then
    warn "Low available RAM: ${AVAIL_MB} MB -- pipeline buffers may cause swapping"
  elif [[ "$AVAIL_MB" -lt 3000 ]]; then
    warn "Available RAM: ${AVAIL_MB} MB -- acceptable but monitor for pressure"
  else
    ok "Available RAM: ${AVAIL_MB} MB"
  fi
fi


# ==============================================================================
# SUMMARY
# ==============================================================================

echo ""
echo "======================================================"
if [[ "$FAILURES" -gt 0 ]]; then
  echo "  RESULT: ${FAILURES} failure(s), ${WARNINGS} warning(s)"
  echo "  Fix failures before running the pipeline."
elif [[ "$WARNINGS" -gt 0 ]]; then
  echo "  RESULT: 0 failures, ${WARNINGS} warning(s)"
  echo "  Warnings do not block launch but may affect performance."
else
  echo "  RESULT: All checks passed."
fi
echo "======================================================"
echo ""

[[ "$FAILURES" -eq 0 ]]
