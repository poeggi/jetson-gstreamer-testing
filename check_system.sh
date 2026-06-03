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
# 0 - PLATFORM AND PLUGIN VERSIONS
# Informational only -- no failures or warnings raised here. Provides context
# for interpreting all checks that follow, and for bug reports.
# ==============================================================================

# Section 0 uses pipelines for version detection only. Disable pipefail here
# to prevent SIGPIPE (e.g. from sed when head-1 exits early) or any other
# non-zero exit from an informational command crashing the script under the
# bash 5.0 bug where set -e fires inside $() even with || true present.
# Full set -euo pipefail is restored at the start of section 1.
set +o pipefail

# Compute pylonsrc caps once here for the version display below.
# Section 1 runs its own fresh gst-inspect under pipefail.
_PYLON_CAPS=$(gst-inspect-1.0 pylonsrc 2>/dev/null || true)

section "Platform and plugin versions"

# L4T / JetPack version
_L4T_FILE="/etc/nv_tegra_release"
if [[ -f "$_L4T_FILE" ]]; then
  _L4T_LINE=$(head -1 "$_L4T_FILE")
  _L4T_MAJ=$(echo "$_L4T_LINE" | sed -n 's/# R\([0-9]*\) .*/\1/p')
  _L4T_REV=$(echo "$_L4T_LINE" | sed -n 's/.*REVISION: \([^,]*\).*/\1/p')
  _L4T_DATE=$(echo "$_L4T_LINE" | sed -n 's/.*DATE: //p')
  case "${_L4T_MAJ:-0}" in
    35) _JP="JetPack 5.x" ;;
    36) _JP="JetPack 6.x" ;;
    *)  _JP="JetPack version unknown" ;;
  esac
  info "L4T: R${_L4T_MAJ}.${_L4T_REV}  (${_JP})"
  info "     Built: ${_L4T_DATE}"
else
  info "L4T: /etc/nv_tegra_release not found"
fi

# GStreamer version
_GST_VER=$(gst-launch-1.0 --version 2>/dev/null | sed -n 's/^GStreamer //p' | head -1 || true)
info "GStreamer: ${_GST_VER:-not found}"

# Basler pylon GStreamer plugin version + NVMM status (derived from _PYLON_CAPS)
if [[ -n "$_PYLON_CAPS" ]]; then
  _PYLON_VER=$(echo "$_PYLON_CAPS" | awk '/^  Version/{print $2; exit}')
  _NVMM="not supported"
  if echo "$_PYLON_CAPS" | grep -qi "memory:NVMM"; then _NVMM="supported"; fi
  info "Basler pylon plugin: ${_PYLON_VER:-unknown}  |  NVMM: ${_NVMM}"
else
  info "Basler pylon plugin: not found or failed to load"
fi


# ==============================================================================
# 1 - GSTREAMER DEPENDENCIES
# ==============================================================================

set -o pipefail  # restore strict pipeline error handling for all real checks
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

# NVMM support check.
# Blocking failure only in color mode: pylonsrc must output NVMM directly
# so frames go USB DMA -> GPU with no system RAM intermediate.
# In bayer mode this is irrelevant: nvvidconv always handles the one
# unavoidable system RAM -> NVMM copy after bayer2rgb, regardless of
# whether pylonsrc itself advertises NVMM caps.
if gst-inspect-1.0 pylonsrc >/dev/null 2>&1; then
  if gst-inspect-1.0 pylonsrc 2>/dev/null | grep -i "memory:NVMM" > /dev/null; then
    ok "pylonsrc NVMM caps: zero-copy color capture path available"
  elif [[ "$CAPTURE_MODE" == "color" ]]; then
    fail "pylonsrc does not advertise NVMM caps (memory:NVMM)"
    fail "     Color capture requires a system RAM -> GPU copy per frame."
    fail "     Upgrade to an NVMM-capable pylon GStreamer plugin:"
    fail "     github.com/basler/gst-plugin-pylon/releases"
  else
    warn "pylonsrc does not advertise NVMM caps (memory:NVMM)"
    warn "     Bayer mode is unaffected -- nvvidconv handles system RAM -> NVMM after bayer2rgb."
    warn "     Color mode would require an NVMM-capable plugin if switched:"
    warn "     github.com/basler/gst-plugin-pylon/releases"
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

# NVENC hardware functional test -- separate from plugin presence.
# The plugin may be installed for forward compatibility while NVENC silicon is
# absent (e.g. current Orin Nano; future variants may add hardware NVENC).
# Runs a minimal 64x64 test encode; catches missing hardware at pre-flight
# rather than letting the pipeline fail mid-stream with a cryptic error.
_NVENC_ELEM=""
case "$ENCODER" in
  h264) _NVENC_ELEM="nvv4l2h264enc" ;;
  h265) _NVENC_ELEM="nvv4l2h265enc" ;;
esac
if gst-inspect-1.0 "${_NVENC_ELEM}" >/dev/null 2>&1; then
  _NVENC_CAPS="video/x-raw(memory:NVMM),format=NV12,width=64,height=64,framerate=30/1"
  if gst-launch-1.0 -e videotestsrc num-buffers=10 \
       ! video/x-raw,format=NV12,width=64,height=64,framerate=30/1 \
       ! nvvidconv nvbuf-memory-type=4 \
       ! "${_NVENC_CAPS}" \
       ! "${_NVENC_ELEM}" ! fakesink sync=false >/dev/null 2>&1; then
    ok "NVENC hardware: ${_NVENC_ELEM} functional (test encode passed)"
  else
    fail "NVENC hardware: ${_NVENC_ELEM} plugin present but test encode failed"
    fail "     NVENC silicon may be absent on this SoM. This pipeline requires"
    fail "     hardware H.265/H.264 encoding; software cannot sustain 12MP/25fps."
  fi
fi

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
# 2 - USB BUFFER MEMORY AND AUTOSUSPEND
# usbfs_memory_mb caps the RAM the USB subsystem can pin for DMA buffers.
# The pylon SDK pre-allocates a ring of capture buffers (default: 10 buffers).
# At 12 MP BayerRG8: 10 x 12.3 MB = 123 MB minimum. 256 MB gives 2x headroom
# for a single camera. Scale to 512 MB if running two cameras on one host.
# The kernel default of 16 MB causes immediate frame drops at this resolution.
#
# USB autosuspend suspends USB devices after an idle period. A streaming camera
# is never truly idle between frames, but some host controllers still trigger
# suspend during driver init or brief timing gaps, causing intermittent latency
# spikes. Must be disabled globally for continuous camera streaming.
# ==============================================================================

section "USB buffer memory and autosuspend"

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

USB_AS_FILE="/sys/module/usbcore/parameters/autosuspend"
if [[ -f "$USB_AS_FILE" ]]; then
  USB_AS=$(cat "$USB_AS_FILE")
  if [[ "$USB_AS" -lt 0 ]]; then
    ok "USB autosuspend: disabled (autosuspend=${USB_AS})"
  else
    warn "USB autosuspend: enabled (delay=${USB_AS} s) -- intermittent latency spikes"
    warn "     Disable now  : sudo sh -c 'echo -1 > ${USB_AS_FILE}'"
    warn "     Persist      : add 'usbcore.autosuspend=-1' to GRUB_CMDLINE_LINUX"
    warn "                    in /etc/default/grub, then sudo update-grub"
  fi
else
  warn "Cannot read ${USB_AS_FILE} -- usbcore module may not be loaded"
fi


# ==============================================================================
# 3 - JETSON POWER AND CLOCK CONFIGURATION
# nvpmodel and jetson_clocks control CPU, GPU and memory clock limits.
# Running in a low-power mode caps clocks and will cause pipeline stalls.
# ==============================================================================

section "Jetson power and clock configuration"

# nvpmodel: 15W is the design target across all supported modules:
#   Orin NX 8GB, Orin NX 16GB, and future NVENC-capable Orin Nano variants.
# All have a dedicated 15W mode separate from MAXN. MAXN and MAXN_SUPER
# draw 20-28W and are not required -- bayer2rgb uses ~1 A78AE core and NVENC
# has comfortable headroom at reduced clocks. The watt value is parsed from
# the mode name string (MODE_15W, 7W, etc.); MAXN/MAXN_SUPER are matched by
# name first. Modes at or below 10W (NX 10W, Nano 7W) are flagged as
# potentially marginal for sustained bayer capture at full resolution/fps.

if command -v nvpmodel >/dev/null 2>&1; then
  POWER_LINE=$(nvpmodel -q 2>/dev/null | grep "NV Power Mode" | head -1 || true)
  _PMODE_W=$(echo "$POWER_LINE" | grep -oE '[0-9]+W' | head -1 | tr -d 'W' || echo "")

  if echo "$POWER_LINE" | grep -qi "MAXN"; then
    ok "nvpmodel: $POWER_LINE"
    info "NOTE: MAXN/MAXN_SUPER (~20-28W) is more than this pipeline requires."
    info "      15W sustains 12MP/25fps with headroom on all supported modules."
    info "      List available modes: sudo nvpmodel --list-modes"
  elif [[ -n "$_PMODE_W" && "$_PMODE_W" -le 10 ]]; then
    warn "nvpmodel: $POWER_LINE"
    warn "     ${_PMODE_W}W may be marginal for bayer2rgb at 12MP/25fps."
    warn "     Color mode (CAPTURE_MODE=color) bypasses CPU debayer and is safe at ${_PMODE_W}W."
    warn "     For bayer mode consider the 15W mode: sudo nvpmodel --list-modes"
  else
    ok "nvpmodel: $POWER_LINE -- recommended production target for this pipeline"
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
    ok "CPU governor: ${GOV}$([ "$PINNED" -eq 1 ] && echo " (clocks pinned -- jetson_clocks active)")"
    info "NOTE: Pinned clocks prevent frequency scaling in the ~35 ms idle gaps"
    info "      between frames (~3-5 W extra continuously). The schedutil governor"
    info "      often scales up fast enough -- worth testing without jetson_clocks."
  else
    warn "CPU governor: ${GOV} -- clocks may scale down between frames"
    warn "     Slow scale-up on frame arrival can stall the pipeline under load."
    warn "     Fix: sudo jetson_clocks  (pins all clocks at max; adds ~3-5 W)"
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

# CPU idle C-states -- deepest state only.
# On Jetson Orin NX the deepest C-state (C7, core power-gate) has a 5 ms wake
# latency. At 25fps (40 ms frame time) this consumes 12.5% of the frame budget
# and causes measurable scheduling jitter when multiple pipeline threads wake
# simultaneously on a frame arrival. Only this deepest state needs disabling;
# WFI (state0) and any intermediate states are negligible and should remain
# enabled to save power in the idle gaps between frames.
# Note: jetson_clocks does NOT disable C-states -- this is a separate action.

CSTATE_DIR="/sys/devices/system/cpu/cpu0/cpuidle"
if [[ -d "$CSTATE_DIR" ]]; then
  DEEP_LATENCY=0
  DEEP_IDX=-1
  DEEP_NAME=""
  DEEP_DISABLED=0
  STATE_COUNT=0

  for STATE_PATH in "${CSTATE_DIR}"/state*/; do
    [[ -f "${STATE_PATH}latency" ]] || continue
    _LAT=$(cat "${STATE_PATH}latency" 2>/dev/null || echo 0)
    if [[ "$_LAT" -gt "$DEEP_LATENCY" ]]; then
      DEEP_LATENCY="$_LAT"
      DEEP_IDX=$(basename "$STATE_PATH" | tr -d 'state')
      DEEP_NAME=$(cat "${STATE_PATH}name" 2>/dev/null || echo "unknown")
      DEEP_DISABLED=$(cat "${STATE_PATH}disable" 2>/dev/null || echo 0)
    fi
    STATE_COUNT=$(( STATE_COUNT + 1 ))
  done

  if [[ "$DEEP_IDX" -ge 0 && "$STATE_COUNT" -gt 1 ]]; then
    _DIS="for f in /sys/devices/system/cpu/cpu*/cpuidle/state${DEEP_IDX}/disable; do echo 1 | sudo tee \$f >/dev/null; done"
    _ENA="for f in /sys/devices/system/cpu/cpu*/cpuidle/state${DEEP_IDX}/disable; do echo 0 | sudo tee \$f >/dev/null; done"

    if [[ "$DEEP_LATENCY" -ge 2000 ]]; then
      if [[ "$DEEP_DISABLED" -eq 1 ]]; then
        ok "Deepest C-state ${DEEP_NAME} (${DEEP_LATENCY} us) disabled -- good for low jitter"
        info "NOTE: Keeping ${DEEP_NAME} disabled costs some idle power. Shallower C-states"
        info "      remain enabled and continue to save power between frames. Re-enable"
        info "      if power budget is the priority: ${_ENA}"
      else
        warn "Deepest C-state ${DEEP_NAME} (${DEEP_LATENCY} us) is enabled"
        warn "     ${DEEP_LATENCY} us wake latency = $(( DEEP_LATENCY / 1000 )) ms per event;"
        warn "     at 25fps this is $(( DEEP_LATENCY * 100 / 40000 ))% of the frame budget per wake."
        warn "     Disable only this state; WFI and shallower states stay on to save power."
        warn "     Fix: ${_DIS}"
      fi
    elif [[ "$DEEP_LATENCY" -ge 500 ]]; then
      if [[ "$DEEP_DISABLED" -eq 1 ]]; then
        ok "Deepest C-state ${DEEP_NAME} (${DEEP_LATENCY} us) disabled"
        info "NOTE: ${DEEP_LATENCY} us is borderline. Re-enable if power is the priority:"
        info "      ${_ENA}"
      else
        info "Deepest C-state ${DEEP_NAME} (${DEEP_LATENCY} us): borderline for 25fps"
        info "     Disable if frame jitter is observed: ${_DIS}"
      fi
    else
      ok "Deepest C-state ${DEEP_NAME} (${DEEP_LATENCY} us): acceptable latency for 25fps"
    fi
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
# 7 - MEMORY: AVAILABLE RAM, CMA, AND SWAP
# Pipeline buffers, NVMM surfaces, and encoder working memory compete for RAM.
#
# CMA (Contiguous Memory Allocator): NVMM allocations on Jetson come from CMA.
# Insufficient CMA causes random NVMM allocation failures after extended runtime
# as the pool fragments. At 12 MP NV12: ~18 MB per frame; with encoder in-flight
# buffers the pipeline needs ~200 MB of CMA headroom. 256 MB is the minimum.
#
# Swap: even if never actively used, the kernel can trigger page reclaim and
# compaction accounting under memory pressure, introducing latency spikes in
# NVMM allocation and DMA operations. Streaming workloads should run swap-free.
# ==============================================================================

section "Memory: available RAM, CMA, and swap"

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

CMA_KB=$(grep "^CmaTotal:" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
if [[ "$CMA_KB" -gt 0 ]]; then
  CMA_MB=$(( CMA_KB / 1024 ))
  if [[ "$CMA_MB" -lt 128 ]]; then
    fail "CmaTotal: ${CMA_MB} MB -- too small for 12 MP NVMM pipeline (minimum 256 MB)"
    fail "     Add 'cma=256M' to GRUB_CMDLINE_LINUX in /etc/default/grub"
    fail "     or to the device tree bootargs, then reboot."
  elif [[ "$CMA_MB" -lt 256 ]]; then
    warn "CmaTotal: ${CMA_MB} MB -- below recommended 256 MB; NVMM alloc may fail under load"
    warn "     Add 'cma=256M' to GRUB_CMDLINE_LINUX in /etc/default/grub, then reboot."
  else
    ok "CmaTotal: ${CMA_MB} MB"
  fi
else
  warn "Cannot read CmaTotal from /proc/meminfo -- kernel may lack CMA support"
fi

SWAP_KB=$(grep "^SwapTotal:" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
if [[ "$SWAP_KB" -eq 0 ]]; then
  ok "Swap: not configured"
else
  SWAP_MB=$(( SWAP_KB / 1024 ))
  SWAP_FREE_KB=$(grep "^SwapFree:" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
  SWAP_USED_MB=$(( (SWAP_KB - SWAP_FREE_KB) / 1024 ))
  warn "Swap: ${SWAP_MB} MB configured, ${SWAP_USED_MB} MB in use"
  warn "     Swap causes latency spikes in NVMM allocation and DMA under pressure."
  warn "     Disable: sudo swapoff -a  (remove from /etc/fstab for persistence)"
fi

ZRAM_COUNT=$(ls /dev/zram* 2>/dev/null | wc -l || echo 0)
if [[ "$ZRAM_COUNT" -gt 0 ]]; then
  warn "zram: ${ZRAM_COUNT} device(s) active -- compressed swap adds CPU overhead under pressure"
  warn "     Disable: sudo swapoff /dev/zram0  (or systemctl stop zramswap)"
else
  ok "zram: not active"
fi


# ==============================================================================
# 8 - NETWORK SOCKET BUFFERS (RTSP mode only)
# rtspclientsink sends the H.265 stream over a TCP socket. At 35-62 Mbps
# (12 MP streaming to high-quality range), the kernel send buffer must be
# large enough to absorb one full GOP without blocking the pipeline.
# At 25 fps with IFRAME_INTERVAL=25 (1 GOP/s): peak burst is ~4-8 MB.
# Linux defaults (wmem_max ~208 KB) are far too small and cause rtspclientsink
# to block, stalling the encoder queue and eventually dropping frames upstream.
# ==============================================================================

if [[ "$OUTPUT_MODE" == "rtsp" ]]; then
  section "Network socket buffers"

  NET_MIN=2097152   # 2 MB minimum; 4 MB recommended for sustained 60 Mbps
  NET_REC=4194304   # 4 MB

  NET_RMEM=$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 0)
  NET_WMEM=$(cat /proc/sys/net/core/wmem_max 2>/dev/null || echo 0)

  if [[ "$NET_RMEM" -ge "$NET_MIN" ]]; then
    ok "net.core.rmem_max = $(( NET_RMEM / 1024 )) KB"
  else
    warn "net.core.rmem_max = $(( NET_RMEM / 1024 )) KB -- below 2 MB minimum"
    warn "     Fix now : sudo sysctl -w net.core.rmem_max=${NET_REC}"
    warn "     Persist : echo 'net.core.rmem_max=${NET_REC}' | sudo tee -a /etc/sysctl.conf"
  fi

  if [[ "$NET_WMEM" -ge "$NET_MIN" ]]; then
    ok "net.core.wmem_max = $(( NET_WMEM / 1024 )) KB"
  else
    warn "net.core.wmem_max = $(( NET_WMEM / 1024 )) KB -- below 2 MB minimum"
    warn "     rtspclientsink will block the pipeline at bitrates above ~20 Mbps."
    warn "     Fix now : sudo sysctl -w net.core.wmem_max=${NET_REC}"
    warn "     Persist : echo 'net.core.wmem_max=${NET_REC}' | sudo tee -a /etc/sysctl.conf"
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
