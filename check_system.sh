#!/usr/bin/env bash
# ==============================================================================
# check_system.sh
#
# Dependency and system health checks for send_stream.sh.
# Called automatically by send_stream.sh before launch (quiet mode).
# Run manually for full diagnostic output:
#
#   ./check_system.sh [--autofix] [h264|h265] [rtsp|fakesink]
#
# Arguments are optional and default to the same values as the pipeline script.
# Exit code: 0 = all critical checks pass, 1 = one or more failures.
# Warnings do not affect the exit code but should be addressed for production.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Prefer bundled bin/ binary over system PATH (onvif_simple_server, wsd_simple_server)
_find_bin() {
  local name="$1"
  if [[ -x "${SCRIPT_DIR}/bin/${name}" ]]; then echo "${SCRIPT_DIR}/bin/${name}"
  else command -v "$name" 2>/dev/null || true
  fi
}

# Source stream.conf so ONVIF_ENABLED, ONVIF_PORT, RTSP_PORT, etc. are available.
# Args below can still override ENCODER and OUTPUT_MODE.
_CONF="${SCRIPT_DIR}/stream.conf"
if [[ -f "$_CONF" ]]; then
  # shellcheck source=stream.conf
  source "$_CONF"
fi


# ==============================================================================
# ARGUMENTS
# ==============================================================================

QUIET=0
FATAL_ONLY=0
AUTOFIX=0
AUTOFIX_PERSIST=0
ENCODER="${MAIN_ENCODER:-h265}"   # default from stream.conf; overridable by arg
OUTPUT_MODE="${OUTPUT_MODE:-rtsp}" # default from stream.conf; overridable by arg

for arg in "$@"; do
  case "$arg" in
    --quiet)            QUIET=1 ;;
    --fatal-only)       QUIET=1; FATAL_ONLY=1 ;;
    --autofix)          AUTOFIX=1 ;;
    --autofix-persist)  AUTOFIX=1; AUTOFIX_PERSIST=1 ;;
    h264|h265)          ENCODER="$arg" ;;
    rtsp|fakesink)      OUTPUT_MODE="$arg" ;;
    *)
      echo "Usage: $0 [--quiet] [--fatal-only] [--autofix] [--autofix-persist] [h264|h265] [rtsp|fakesink]" >&2
      exit 1
      ;;
  esac
done


# ==============================================================================
# OUTPUT HELPERS
# ==============================================================================

FAILURES=0
WARNINGS=0
FIXES_APPLIED=0
FIXES_FAILED=0

section() { if [[ "$QUIET" -eq 0 ]]; then echo ""; echo "--- $1 ---"; fi; }
ok()      { if [[ "$QUIET" -eq 0 ]]; then echo "  [OK]   $1"; fi; }
info()    { if [[ "$QUIET" -eq 0 ]]; then echo "  [INFO] $1"; fi; }
warn()    { if [[ "$FATAL_ONLY" -eq 0 ]]; then echo "  [WARN] $1"; fi; WARNINGS=$(( WARNINGS + 1 )); }
fail()    { echo "  [FAIL] $1"; FAILURES=$(( FAILURES + 1 )); }

# autofix DESCRIPTION COMMAND
# Runs COMMAND when --autofix is set. Skipped silently otherwise.
autofix() {
  if [[ "$AUTOFIX" -eq 0 ]]; then return 0; fi
  local desc="$1" cmd="$2"
  printf "  [FIX]  %s\n" "$desc"
  if eval "$cmd"; then
    echo "  [FIX]  Done."
    FIXES_APPLIED=$(( FIXES_APPLIED + 1 ))
  else
    echo "  [FIX]  FAILED -- may need sudo or manual intervention"
    FIXES_FAILED=$(( FIXES_FAILED + 1 ))
  fi
}

# autofix_persist DESCRIPTION COMMAND
# Runs COMMAND when --autofix-persist is set. Makes the fix survive reboot.
autofix_persist() {
  if [[ "$AUTOFIX_PERSIST" -eq 0 ]]; then return 0; fi
  local desc="$1" cmd="$2"
  printf "  [PERSIST] %s\n" "$desc"
  if eval "$cmd"; then
    echo "  [PERSIST] Done."
    FIXES_APPLIED=$(( FIXES_APPLIED + 1 ))
  else
    echo "  [PERSIST] FAILED -- may need sudo or manual intervention"
    FIXES_FAILED=$(( FIXES_FAILED + 1 ))
  fi
}


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
# Section 7 runs its own fresh gst-inspect under pipefail.
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


set -o pipefail  # restore strict pipeline error handling for all real checks


# ==============================================================================
# 1 - SYSTEM TIME SYNCHRONISATION
# Accurate wall-clock time is needed for Basler chunk timestamp correlation
# and any time-based post-processing of recorded streams. Check that an NTP
# or PTP daemon is active and that the clock offset is within useful bounds.
# ==============================================================================

section "System time synchronisation"

_TIME_SYNCED=0
_NTP_METHOD=""
_NTP_OFFSET_MS=""
_NTP_OFFSET_BAD=0

# Collect sync state silently -- all methods tried, first success wins.

# Method 1: timedatectl (systemd-timesyncd or chrony via systemd)
if command -v timedatectl >/dev/null 2>&1; then
  _TD=$(timedatectl show 2>/dev/null || true)
  if echo "$_TD" | grep -q "NTPSynchronized=yes"; then
    _TIME_SYNCED=1
    _NTP_METHOD="timedatectl"
    # offset via timesync-status (newer systemd only; silently absent if unavailable)
    _TS_OFF=$(timedatectl timesync-status 2>/dev/null \
      | awk '/Offset:/{print $2, $3}' || true)
    [[ -n "$_TS_OFF" ]] && _NTP_OFFSET_MS="$_TS_OFF"
  fi
fi

# Method 2: chronyc tracking (also gives precise offset in seconds)
if command -v chronyc >/dev/null 2>&1; then
  _CHRONY=$(chronyc tracking 2>/dev/null || true)
  if [[ -n "$_CHRONY" ]] && ! echo "$_CHRONY" | grep -q "0\.0\.0\.0\|Not synchronised"; then
    _TIME_SYNCED=1
    _NTP_METHOD="chrony"
    _COFF=$(echo "$_CHRONY" | awk '/System time/{print $4}')
    if [[ -n "$_COFF" ]]; then
      _NTP_OFFSET_MS=$(awk "BEGIN {printf \"%.2f ms\", ${_COFF} * 1000}")
      _NTP_OFFSET_BAD=$(awk "BEGIN {print (${_COFF} < 0 ? -${_COFF} : ${_COFF}) > 0.1}")
    fi
  fi
fi

# Method 3: ntpq (ntpd -- active peer indicated by leading '*')
if [[ "$_TIME_SYNCED" -eq 0 ]] && command -v ntpq >/dev/null 2>&1; then
  if ntpq -c peers 2>/dev/null | grep -q "^\*"; then
    _TIME_SYNCED=1
    _NTP_METHOD="ntpd"
  fi
fi

# Single consolidated output line
if [[ "$_TIME_SYNCED" -eq 1 ]]; then
  _NTP_DETAIL="${_NTP_METHOD}"
  [[ -n "$_NTP_OFFSET_MS" ]] && _NTP_DETAIL="${_NTP_METHOD}, offset ${_NTP_OFFSET_MS}"
  if [[ "$_NTP_OFFSET_BAD" -eq 1 ]]; then
    warn "System time: synchronized via ${_NTP_DETAIL} -- offset > 100 ms, chunk timestamps unreliable"
  else
    ok "System time: synchronized via ${_NTP_DETAIL}"
  fi
else
  warn "System time: not synchronized -- no active NTP daemon detected"
  warn "     Accurate time needed for Basler chunk timestamp correlation."
  warn "     Fix now  : sudo ntpdate -u pool.ntp.org  (one-shot sync)"
  warn "     Persist  : sudo timedatectl set-ntp true  (or: sudo apt install chrony)"
  if command -v ntpdate >/dev/null 2>&1; then
    autofix "Force time sync via ntpdate" "sudo ntpdate -u pool.ntp.org"
  elif command -v chronyc >/dev/null 2>&1; then
    autofix "Force time step via chronyc" "sudo chronyc makestep"
  fi
  autofix_persist "Enable NTP via timedatectl" "sudo timedatectl set-ntp true"
fi


# ==============================================================================
# 2 - MEMORY: AVAILABLE RAM, CMA, AND SWAP
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
  warn "     Disable now  : sudo swapoff -a"
  warn "     Persist      : sudo sed -i '/swap/Id' /etc/fstab"
  autofix "Disable swap" "sudo swapoff -a"
  autofix_persist "Remove swap entries from /etc/fstab" "sudo sed -i '/swap/Id' /etc/fstab"
fi

ZRAM_COUNT=$(ls /dev/zram* 2>/dev/null | wc -l || echo 0)
if [[ "$ZRAM_COUNT" -gt 0 ]]; then
  warn "zram: ${ZRAM_COUNT} device(s) active -- compressed swap adds CPU overhead under pressure"
  warn "     Disable now  : sudo swapoff /dev/zram0  (or: sudo systemctl stop zramswap)"
  warn "     Persist      : sudo systemctl disable zramswap"
  autofix "Disable zram swap" "for z in /dev/zram*; do sudo swapoff \"\$z\" 2>/dev/null || true; done"
  autofix_persist "Disable zramswap service" "sudo systemctl disable zramswap 2>/dev/null || sudo systemctl disable systemd-zram-setup@zram0.service 2>/dev/null || true"
else
  ok "zram: not active"
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
# draw 20-28W and are not required -- color mode NVENC has comfortable
# headroom at reduced clocks. The watt value is parsed from the mode name
# string (MODE_15W, 7W, etc.); MAXN/MAXN_SUPER are matched by name first.
# Modes at or below 10W (NX 10W, Nano 7W) are flagged as potentially
# marginal for sustained 4K/30fps color capture and encode.

if command -v nvpmodel >/dev/null 2>&1; then
  POWER_LINE=$(nvpmodel -q 2>/dev/null | grep "NV Power Mode" | head -1 || true)
  _PMODE_W=$(echo "$POWER_LINE" | grep -oE '[0-9]+W' | head -1 | tr -d 'W' || echo "")

  if echo "$POWER_LINE" | grep -qi "MAXN"; then
    ok "nvpmodel: $POWER_LINE"
    info "NOTE: MAXN/MAXN_SUPER (~20-28W) is more than this pipeline requires."
    info "      15W sustains 4K/30fps with headroom on all supported modules."
    info "      List available modes: sudo nvpmodel --list-modes"
  elif [[ -n "$_PMODE_W" && "$_PMODE_W" -le 10 ]]; then
    warn "nvpmodel: $POWER_LINE"
    warn "     ${_PMODE_W}W may be marginal for 4K/30fps color NVMM capture and encode."
    warn "     Consider the 15W mode: sudo nvpmodel --list-modes"
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
    warn "     Fix now  : sudo jetson_clocks  (pins all clocks at max; adds ~3-5 W)"
    warn "     Persist  : add 'jetson_clocks' to /etc/rc.local before 'exit 0'"
    autofix "Pin clocks with jetson_clocks" "sudo jetson_clocks"
    autofix_persist "Add jetson_clocks to /etc/rc.local" "grep -qF 'jetson_clocks' /etc/rc.local 2>/dev/null || echo 'jetson_clocks' | sudo tee -a /etc/rc.local >/dev/null"
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
    warn "     Fix now  : sudo jetson_clocks"
    warn "     Persist  : add 'jetson_clocks' to /etc/rc.local before 'exit 0'"
    autofix "Pin clocks with jetson_clocks" "sudo jetson_clocks"
    autofix_persist "Add jetson_clocks to /etc/rc.local" "grep -qF 'jetson_clocks' /etc/rc.local 2>/dev/null || echo 'jetson_clocks' | sudo tee -a /etc/rc.local >/dev/null"
  else
    ok "CPU0 clock: ${CUR_GHZ} GHz (${PCT}% of ${MAX_GHZ} GHz max)"
  fi
fi

# CPU idle C-states -- deepest state only.
# On Jetson Orin NX the deepest C-state (C7, core power-gate) has a 5 ms wake
# latency. At 30fps (33 ms frame time) this consumes 15% of the frame budget
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
        warn "     at 30fps this is $(( DEEP_LATENCY * 100 / 33000 ))% of the frame budget per wake."
        warn "     Disable only this state; WFI and shallower states stay on to save power."
        warn "     Fix now  : ${_DIS}"
        warn "     Persist  : add the above command to /etc/rc.local before 'exit 0'"
        autofix "Disable deepest C-state ${DEEP_NAME}" "${_DIS}"
        autofix_persist "Add C-state disable to /etc/rc.local" "grep -qF 'cpuidle/state${DEEP_IDX}/disable' /etc/rc.local 2>/dev/null || echo '${_DIS}' | sudo tee -a /etc/rc.local >/dev/null"
      fi
    elif [[ "$DEEP_LATENCY" -ge 500 ]]; then
      if [[ "$DEEP_DISABLED" -eq 1 ]]; then
        ok "Deepest C-state ${DEEP_NAME} (${DEEP_LATENCY} us) disabled"
        info "NOTE: ${DEEP_LATENCY} us is borderline. Re-enable if power is the priority:"
        info "      ${_ENA}"
      else
        info "Deepest C-state ${DEEP_NAME} (${DEEP_LATENCY} us): borderline for 30fps"
        info "     Disable if frame jitter is observed: ${_DIS}"
      fi
    else
      ok "Deepest C-state ${DEEP_NAME} (${DEEP_LATENCY} us): acceptable latency for 30fps"
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
# 5 - USB BUFFER MEMORY AND AUTOSUSPEND
# usbfs_memory_mb caps the RAM the USB subsystem can pin for DMA buffers.
# The pylon SDK pre-allocates a ring of capture buffers (default: 10 buffers).
# At 12 MP YUY2 NV12: 10 x ~18 MB = ~180 MB minimum. 256 MB gives headroom
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
    fail "usbfs_memory_mb = ${USB_MEM} MB -- too low (need >= ${USB_MEM_MIN} MB for single 12 MP camera)"
    fail "     Fix now : sudo sh -c 'echo ${USB_MEM_MIN} > ${USB_MEM_FILE}'"
    fail "     Persist : add the above line to /etc/rc.local before 'exit 0'"
    autofix "Set usbfs_memory_mb to ${USB_MEM_MIN}" "sudo sh -c 'echo ${USB_MEM_MIN} > ${USB_MEM_FILE}'"
    autofix_persist "Add usbfs_memory_mb to /etc/rc.local" "grep -qF 'usbfs_memory_mb' /etc/rc.local 2>/dev/null || echo 'echo ${USB_MEM_MIN} > ${USB_MEM_FILE}' | sudo tee -a /etc/rc.local >/dev/null"
  else
    ok "usbfs_memory_mb = ${USB_MEM} MB"
  fi
else
  warn "Cannot read ${USB_MEM_FILE} -- usbcore module may not be loaded"
fi

USB_AS_FILE="/sys/module/usbcore/parameters/autosuspend"

# XHCI interrupt moderation (IMOD) -- groups USB transfer completions to reduce
# interrupt rate. Linux default is 4000 (1ms). 0 = disabled (every transfer fires
# an interrupt). Reading via debugfs; low priority warning if disabled.
IMOD_VALUE=""
for IMOD_FILE in /sys/kernel/debug/usb/xhci*/interrupter_0/IMOD \
                  /sys/kernel/debug/usb/xhci*/IMOD; do
  if [[ -f "$IMOD_FILE" ]]; then
    IMOD_VALUE=$(cat "$IMOD_FILE" 2>/dev/null || true)
    break
  fi
done
if [[ -z "$IMOD_VALUE" ]]; then
  info "XHCI IMOD: cannot read (debugfs not mounted or path differs on this kernel)"
elif [[ "$IMOD_VALUE" == "0" || "$IMOD_VALUE" == "0x0" ]]; then
  warn "XHCI interrupt moderation (IMOD) is DISABLED -- every USB transfer fires an interrupt"
  warn "     At 530 MB/s this significantly increases CPU interrupt overhead."
  warn "     Linux default is 4000 (1ms coalescing). Check device tree or kernel config."
else
  ok "XHCI interrupt moderation: IMOD=${IMOD_VALUE} ($(( ${IMOD_VALUE} * 250 / 1000 )) us coalescing interval)"
fi
if [[ -f "$USB_AS_FILE" ]]; then
  USB_AS=$(cat "$USB_AS_FILE")
  if [[ "$USB_AS" -lt 0 ]]; then
    ok "USB autosuspend: disabled (autosuspend=${USB_AS})"
  else
    warn "USB autosuspend: enabled (delay=${USB_AS} s) -- intermittent latency spikes"
    warn "     Disable now  : sudo sh -c 'echo -1 > ${USB_AS_FILE}'"
    warn "     Persist      : echo 'options usbcore autosuspend=-1' | sudo tee /etc/modprobe.d/usbcore.conf"
    warn "                    (alternative: add 'usbcore.autosuspend=-1' to GRUB_CMDLINE_LINUX)"
    autofix "Disable USB autosuspend" "sudo sh -c 'echo -1 > ${USB_AS_FILE}'"
    autofix_persist "Persist autosuspend disable via modprobe.d" "echo 'options usbcore autosuspend=-1' | sudo tee /etc/modprobe.d/usbcore.conf >/dev/null"
  fi
else
  warn "Cannot read ${USB_AS_FILE} -- usbcore module may not be loaded"
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
      fail "     Camera is on a USB 2.0 port or hub. At 4K/30fps the pipeline"
      fail "     needs ~530 MB/s; USB 2.0 provides ~40 MB/s. Plug directly into"
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

# pylonsrc framerate control check.
# In gst-plugin-pylon, framerate is controlled via GStreamer caps negotiation only
# (no named property). Some plugin versions silently ignore the caps framerate and
# run at the camera's hardware maximum. Test by requesting a reduced framerate
# and comparing against the negotiated result.
# Skipped in --fatal-only mode: opens/closes camera (1-3 s), produces warn/info only.
if [[ "$FATAL_ONLY" -eq 0 ]] && gst-inspect-1.0 pylonsrc >/dev/null 2>&1; then
  _TEST_FPS="15"
  _CAPS_OUT=$(gst-launch-1.0 -v pylonsrc num-buffers=1 \
    ! "video/x-raw(memory:NVMM),format=YUY2,framerate=${_TEST_FPS}/1" \
    ! fakesink 2>&1) || true
  _NEG_FPS=$(echo "$_CAPS_OUT" | grep "pylonsrc0.GstPad:src: caps" \
    | grep -o "framerate=(fraction)[^,)]*" | sed 's/framerate=(fraction)//') || true
  if [[ -z "$_NEG_FPS" ]]; then
    info "pylonsrc framerate control: could not determine (camera may not be connected)"
  elif [[ "$_NEG_FPS" == "${_TEST_FPS}/1" ]]; then
    ok "pylonsrc framerate control: caps negotiation supported (${_NEG_FPS} fps honored)"
  else
    warn "pylonsrc framerate control: NOT supported by this plugin version"
    warn "     Requested ${_TEST_FPS}/1 fps via caps, camera negotiated ${_NEG_FPS}"
    warn "     Camera runs at hardware-fixed rate regardless of caps framerate field."
    warn "     Upgrade gst-plugin-pylon: https://github.com/basler/gst-plugin-pylon/releases"
  fi
fi


# Basler Compression Beyond check.
# The a2A4096-30ucPRO (PRO variant) supports hardware lossless compression in the
# camera FPGA, reducing USB bandwidth by 2-3x. gst-plugin-pylon decompresses
# transparently. This may explain why 530 MB/s YUY2 works on Gen1.
# Check: (1) plugin supports decompression, (2) camera has it enabled.
# Skipped in --fatal-only mode: opens/closes camera (1-3 s), produces info only.
if [[ "$FATAL_ONLY" -eq 0 ]] && gst-inspect-1.0 pylonsrc >/dev/null 2>&1; then
  _COMPRESS_SUPPORT=$(gst-inspect-1.0 pylonsrc 2>/dev/null | grep -i "compress" || true)
  if [[ -n "$_COMPRESS_SUPPORT" ]]; then
    ok "pylonsrc Compression Beyond: plugin supports decompression"
    # Check if camera has it enabled by inspecting negotiated caps for compression hint
    _COMP_OUT=$(gst-launch-1.0 -v pylonsrc num-buffers=1 ! fakesink 2>&1) || true
    if echo "$_COMP_OUT" | grep -qi "compress"; then
      ok "Compression Beyond: active on camera -- USB bandwidth is reduced"
    else
      info "Compression Beyond: plugin supports it but camera setting unknown"
      info "     Enable in pylon Viewer: ImageCompressionMode=BaslerCompressionBeyond"
      info "     ImageCompressionRateOption=Lossless  (2-3x USB bandwidth reduction)"
    fi
  else
    info "Compression Beyond: not supported by this plugin version"
    info "     Upgrade gst-plugin-pylon for lossless USB bandwidth reduction:"
    info "     https://github.com/basler/gst-plugin-pylon/releases"
  fi
fi

# Basler chunk timestamp check.
# ChunkModeActive appends hardware metadata (timestamp, frame counter, exposure)
# to each buffer. On the a2A4096-30ucPRO (Pro) the timestamp is driven by the
# camera's internal clock, which can be synchronized to network time via PTP
# (IEEE 1588). Chunk timestamp is optional for streaming but required if you
# need per-frame timing accuracy (e.g. for AI pipelines or post-sync).
# Check: (1) plugin exposes ChunkModeActive property, (2) camera accepts it.
# Skipped in --fatal-only mode: opens/closes camera (1-3 s), produces warn/info only.
if [[ "$FATAL_ONLY" -eq 0 ]] && gst-inspect-1.0 pylonsrc >/dev/null 2>&1; then
  _CHUNK_PROP=$(gst-inspect-1.0 pylonsrc 2>/dev/null \
    | grep -i "ChunkModeActive\|chunk.mode.active" || true)
  if [[ -n "$_CHUNK_PROP" ]]; then
    ok "pylonsrc: ChunkModeActive property available"
    # Try enabling chunk mode and capturing one frame. Failure means the camera
    # rejected the property (firmware/model limitation) or no camera is connected.
    _CHUNK_OUT=$(gst-launch-1.0 pylonsrc num-buffers=1 ChunkModeActive=true \
      ! fakesink sync=false 2>&1 || true)
    if echo "$_CHUNK_OUT" | grep -qi "error"; then
      warn "Chunk timestamp: ChunkModeActive=true was rejected by camera or plugin"
      warn "     Camera may not support chunk mode or no camera is connected."
    else
      ok "Chunk timestamp: ChunkModeActive=true accepted -- hardware timestamps active"
      info "     Pro model supports PTP (IEEE 1588) for network-synced timestamps."
      info "     Enable PTP in pylon Viewer: GevIEEE1588 = true"
      info "     Verify sync: GevIEEE1588Status should reach 'Slave' or 'Master'."
    fi
  else
    info "Chunk timestamp: pylonsrc does not expose ChunkModeActive property"
    info "     Upgrade gst-plugin-pylon for chunk timestamp support:"
    info "     https://github.com/basler/gst-plugin-pylon/releases"
  fi
fi


# ==============================================================================
# 7 - GSTREAMER PIPELINE STACK
# GStreamer tools, plugins, and NVENC hardware required to run the pipeline.
# Also checks for debug and tracing overhead that can degrade performance.
# ==============================================================================

section "GStreamer pipeline stack"

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

# Running GStreamer pipeline check.
# A parallel gst-launch-1.0 process will compete for the camera, NVMM pool,
# and NVENC hardware. This is treated as a severe warning regardless of mode.
_GST_PIDS=$(pgrep -x gst-launch-1.0 2>/dev/null || true)
if [[ -n "$_GST_PIDS" ]]; then
  _GST_PID_LIST=$(echo "$_GST_PIDS" | tr '\n' ' ' | sed 's/ $//')
  warn "gst-launch-1.0 already running -- PID(s): ${_GST_PID_LIST}"
  warn "     A parallel pipeline will compete for the camera, NVMM pool, and NVENC."
  warn "     Stop it first: kill ${_GST_PID_LIST}"
else
  ok "No other gst-launch-1.0 instances running"
fi

check_plugin pylonsrc  "install Basler pylon GStreamer package from baslerweb.com/downloads"

# NVMM support check -- color mode requires pylonsrc to output NVMM directly
# so frames go USB DMA -> GPU with no system RAM intermediate.
if gst-inspect-1.0 pylonsrc >/dev/null 2>&1; then
  if gst-inspect-1.0 pylonsrc 2>/dev/null | grep -i "memory:NVMM" > /dev/null; then
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
  # 320x240: well above the H.265 NVENC minimum CTU size on Orin NX.
  # 64x64 is below the hardware minimum and causes a false failure.
  _NVENC_CAPS="video/x-raw(memory:NVMM),format=NV12,width=320,height=240,framerate=30/1"
  if gst-launch-1.0 -e videotestsrc num-buffers=10 \
       ! video/x-raw,format=NV12,width=320,height=240,framerate=30/1 \
       ! nvvidconv nvbuf-memory-type=4 \
       ! "${_NVENC_CAPS}" \
       ! "${_NVENC_ELEM}" ! fakesink sync=false >/dev/null 2>&1; then
    ok "NVENC hardware: ${_NVENC_ELEM} functional (test encode passed)"
  else
    fail "NVENC hardware: ${_NVENC_ELEM} plugin present but test encode failed"
    fail "     NVENC silicon may be absent on this SoM. This pipeline requires"
    fail "     hardware H.264/H.265 encoding; software cannot sustain 4K/30fps."
  fi
fi

if [[ "$OUTPUT_MODE" == "rtsp" ]]; then
  case "$ENCODER" in
    h264) check_plugin rtph264pay "sudo apt install gstreamer1.0-plugins-good" ;;
    h265) check_plugin rtph265pay "sudo apt install gstreamer1.0-plugins-good" ;;
  esac
  check_plugin rtspclientsink "sudo apt install gstreamer1.0-plugins-bad"
fi

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
    warn "     Disable now  : sudo sh -c 'echo 0 > ${FTRACE_FILE}'"
    warn "     Persist      : not needed -- ftrace resets on reboot unless explicitly re-enabled"
    autofix "Disable ftrace" "sudo sh -c 'echo 0 > ${FTRACE_FILE}'"
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
# 8 - RTSP AND ONVIF INFRASTRUCTURE
# MediaMTX RTSP server and network socket buffers (rtsp mode only).
# ONVIF device server for NVR auto-discovery (always checked).
# ==============================================================================

section "RTSP and ONVIF infrastructure"

if [[ "$OUTPUT_MODE" == "rtsp" ]]; then
  # Verify config file is present (moved from repo root to blueprints/ in v0.7+)
  _MEDIAMTX_CONF="${SCRIPT_DIR}/blueprints/mediamtx.yml"
  if [[ -f "$_MEDIAMTX_CONF" ]]; then
    ok "MediaMTX config: blueprints/mediamtx.yml"
  else
    fail "MediaMTX config not found: blueprints/mediamtx.yml"
  fi

  # Find the MediaMTX binary. The pipeline script will start it automatically
  # if not already running, so we verify it is findable and actually starts.
  RTSP_HOST="${RTSP_HOST:-127.0.0.1}"
  RTSP_PORT="${RTSP_PORT:-8554}"
  MEDIAMTX_BIN=""
  for loc in \
    "$(command -v mediamtx 2>/dev/null || true)" \
    /usr/local/bin/mediamtx \
    "${HOME}/mediamtx" \
    "${SCRIPT_DIR}/mediamtx"; do
    [[ -n "$loc" && -x "$loc" ]] && { MEDIAMTX_BIN="$loc"; break; }
  done

  if [[ -z "$MEDIAMTX_BIN" ]]; then
    fail "mediamtx binary not found in PATH or common locations"
    fail "     Download for ARM64 from: github.com/bluenviron/mediamtx/releases"
    fail "     Place in /usr/local/bin/ or alongside these scripts"
  else
    ok "mediamtx binary: ${MEDIAMTX_BIN}"

    # In manual mode: start briefly to verify it actually works.
    # Skipped in --fatal-only mode: up to 5 s sleep loop, false-fails on loaded systems.
    if [[ "$FATAL_ONLY" -eq 0 ]]; then
      if nc -z -w1 "$RTSP_HOST" "$RTSP_PORT" 2>/dev/null; then
        ok "MediaMTX already running at ${RTSP_HOST}:${RTSP_PORT}"
      else
        echo "  [....] Starting MediaMTX briefly to verify..."
        "$MEDIAMTX_BIN" "${SCRIPT_DIR}/blueprints/mediamtx.yml" >/dev/null 2>&1 &
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
          warn "MediaMTX found but did not start within 5 seconds -- verify manually"
        fi
        kill "$MEDIAMTX_CHECK_PID" 2>/dev/null || true
        wait "$MEDIAMTX_CHECK_PID" 2>/dev/null || true
      fi
    fi
  fi

  # rtspclientsink sends the H.265 stream over a TCP socket. At 35-62 Mbps
  # the kernel send buffer must be large enough to absorb one full GOP without
  # blocking the pipeline. Linux defaults (~208 KB) are far too small.
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
    autofix "Set net.core.rmem_max to ${NET_REC}" "sudo sysctl -w net.core.rmem_max=${NET_REC}"
    autofix_persist "Persist rmem_max in /etc/sysctl.conf" "grep -qF 'rmem_max' /etc/sysctl.conf 2>/dev/null || echo 'net.core.rmem_max=${NET_REC}' | sudo tee -a /etc/sysctl.conf >/dev/null"
  fi

  if [[ "$NET_WMEM" -ge "$NET_MIN" ]]; then
    ok "net.core.wmem_max = $(( NET_WMEM / 1024 )) KB"
  else
    warn "net.core.wmem_max = $(( NET_WMEM / 1024 )) KB -- below 2 MB minimum"
    warn "     rtspclientsink will block the pipeline at bitrates above ~20 Mbps."
    warn "     Fix now : sudo sysctl -w net.core.wmem_max=${NET_REC}"
    warn "     Persist : echo 'net.core.wmem_max=${NET_REC}' | sudo tee -a /etc/sysctl.conf"
    autofix "Set net.core.wmem_max to ${NET_REC}" "sudo sysctl -w net.core.wmem_max=${NET_REC}"
    autofix_persist "Persist wmem_max in /etc/sysctl.conf" "grep -qF 'wmem_max' /etc/sysctl.conf 2>/dev/null || echo 'net.core.wmem_max=${NET_REC}' | sudo tee -a /etc/sysctl.conf >/dev/null"
  fi
fi

# ONVIF server check.
# onvif_simple_server exposes MediaMTX RTSP streams as an ONVIF Profile S/T
# device so NVRs (e.g. Dahua) can discover and record without manual RTSP URL
# entry. It is a CGI binary -- requires lighttpd and wsd_simple_server.
ONVIF_PORT="${ONVIF_PORT:-8080}"
_ONVIF_BIN=$(_find_bin onvif_simple_server)
_WSD_BIN=$(_find_bin wsd_simple_server)
_LIGHTTPD_BIN=$(_find_bin lighttpd)

_ONVIF_SERIAL="${ONVIF_SERIAL:-SN1234567890}"
_SERIAL_FIX="_s=\$(cat /sys/bus/platform/devices/*/fuse/serial_number 2>/dev/null | head -1 | tr -d '[:space:]'); [[ -n \"\$_s\" ]] && sed -i \"s|^ONVIF_SERIAL=.*|ONVIF_SERIAL=\$_s|\" \"${_CONF}\""
if [[ "$_ONVIF_SERIAL" == "SN1234567890" ]]; then
  warn "ONVIF serial_num is the default 'SN1234567890' -- NVR cannot distinguish units"
  warn "     Persist : ${_SERIAL_FIX}"
  autofix_persist "Set ONVIF_SERIAL from Jetson board serial in stream.conf" "${_SERIAL_FIX}"
else
  ok "ONVIF serial_num: ${_ONVIF_SERIAL}"
fi

if [[ -n "$_ONVIF_BIN" && -n "$_WSD_BIN" && -n "$_LIGHTTPD_BIN" ]]; then
  ok "ONVIF: onvif_simple_server, wsd_simple_server, lighttpd all present"

  # Verify bundled (cross-compiled) binaries can actually execute on this CPU.
  # Exit 126 = exec format error (wrong arch / bad ELF). Anything else means
  # the binary ran (even if it exited non-zero due to missing CGI environment).
  for _chk in onvif_simple_server wsd_simple_server; do
    _chk_path=$(_find_bin "$_chk")
    if [[ "$_chk_path" == "${SCRIPT_DIR}/bin/"* ]]; then
      _chk_ec=0
      timeout 1 "$_chk_path" >/dev/null 2>&1 || _chk_ec=$?
      if [[ $_chk_ec -eq 126 ]]; then
        if [[ "${ONVIF_ENABLED:-false}" == "true" ]]; then
          fail "ONVIF: bin/${_chk} cannot execute -- wrong CPU architecture or bad binary"
          fail "     Re-run ./bin/sources/cross-build-windows.ps1 (Windows) or ./bin/sources/build-on-device.sh (Jetson)"
        else
          warn "ONVIF: bin/${_chk} cannot execute -- wrong CPU architecture or bad binary"
          warn "     Not active now (ONVIF_ENABLED=false), but fix before enabling"
        fi
      else
        ok "ONVIF: bin/${_chk} runs on this CPU"
      fi
    fi
  done

  _WSD_PIDS=$(pgrep -x wsd_simple_server 2>/dev/null || true)
  if nc -z -w1 127.0.0.1 "$ONVIF_PORT" 2>/dev/null; then
    ok "ONVIF: lighttpd running on port ${ONVIF_PORT}"
    if [[ -n "$_WSD_PIDS" ]]; then
      ok "ONVIF: wsd_simple_server running (WS-Discovery active)"
    else
      warn "ONVIF: wsd_simple_server not running -- NVR auto-discovery inactive"
      warn "     Restart via send_stream.sh or ./bin/start_onvif.sh"
    fi
  else
    # lighttpd not running -- check for stray wsd that could block a fresh start
    if [[ -n "$_WSD_PIDS" ]]; then
      _WSD_PID_LIST=$(echo "$_WSD_PIDS" | tr '\n' ' ' | sed 's/ $//')
      warn "ONVIF: stray wsd_simple_server running (PID ${_WSD_PID_LIST}) but lighttpd is not"
      warn "     This may prevent WS-Discovery from starting cleanly."
      warn "     Stop it: kill ${_WSD_PID_LIST}"
    else
      info "ONVIF: installed but not running (port ${ONVIF_PORT} not listening)"
      info "     Start via send_stream.sh (ONVIF_ENABLED=true) or ./bin/start_onvif.sh"
    fi
  fi
else
  _MISSING=""
  [[ -z "$_ONVIF_BIN"    ]] && _MISSING="${_MISSING} onvif_simple_server"
  [[ -z "$_WSD_BIN"      ]] && _MISSING="${_MISSING} wsd_simple_server"
  [[ -z "$_LIGHTTPD_BIN" ]] && _MISSING="${_MISSING} lighttpd"
  warn "ONVIF: not available -- missing:${_MISSING}"
  warn "     onvif_simple_server / wsd_simple_server: run ./bin/sources/cross-build-windows.ps1 (Windows) or ./bin/sources/build-on-device.sh (Jetson)"
  warn "     lighttpd: sudo apt install lighttpd"
  warn "     Run ./bin/start_onvif.sh after installing to enable NVR discovery"
fi


# ==============================================================================
# SUMMARY
# ==============================================================================

echo ""
echo "======================================================"
if [[ "$FAILURES" -gt 0 && "$WARNINGS" -gt 0 ]]; then
  echo "  ${FAILURES} failure(s)  |  ${WARNINGS} warning(s)"
elif [[ "$FAILURES" -gt 0 ]]; then
  echo "  ${FAILURES} failure(s)  |  no warnings"
elif [[ "$WARNINGS" -gt 0 ]]; then
  echo "  No failures  |  ${WARNINGS} warning(s)"
else
  echo "  No failures, no warnings"
fi
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "  GOOD TO GO -- pipeline ready to launch."
  if [[ "$WARNINGS" -gt 0 ]]; then echo "  Warnings above may affect performance or reliability."; fi
else
  echo "  NOT READY -- fix ${FAILURES} failure(s) before launching."
fi
if [[ "$AUTOFIX" -eq 1 ]]; then
  echo ""
  echo "  Autofix: ${FIXES_APPLIED} applied, ${FIXES_FAILED} failed"
  if [[ "$AUTOFIX_PERSIST" -eq 1 ]]; then
    if [[ "$FIXES_APPLIED" -gt 0 ]]; then echo "  Note: runtime and persistent fixes applied. GRUB-based items (CMA, autosuspend) still need manual steps."; fi
  else
    if [[ "$FIXES_APPLIED" -gt 0 ]]; then echo "  Note: runtime fixes applied. Run with --autofix-persist to also write persistent fixes."; fi
  fi
fi
echo "======================================================"
echo ""

[[ "$FAILURES" -eq 0 ]]
