#!/usr/bin/env bash
# ==============================================================================
# diagnose_pipeline.sh
#
# Systematically tests each GStreamer pipeline stage on Jetson Orin NX,
# adding one element at a time to identify exactly which element fails.
# Mirrors send_stream.sh: same elements, same properties, same defaults
# (color YUY2 NVMM capture, H.264, fakesink output).
#
# Section 7 uses videotestsrc as source. videotestsrc outputs system RAM
# so nvvidconv performs RAM->NVMM in addition to format conversion; in
# production pylonsrc delivers NVMM directly and nvvidconv is format-only.
# Section 8 tests the real pylonsrc source (camera must be connected).
#
# Must be run on the Jetson itself.
# Usage: ./diagnose_pipeline.sh
# ==============================================================================

set -uo pipefail

BUFFERS=10          # frames per synthetic test (videotestsrc)
CAM_BUFFERS=20      # frames per camera test (pylonsrc) -- limited for speed
                    # but same resolution as production
W=4096              # production resolution (NVENC H.264 level limit)
H=2160              # 4096x2160 = 8.8 MP
FPS=30              # camera native framerate (hardware fixed at 30fps)
BITRATE=28000000    # production bitrate (H.264 CBR, 28 Mbps at 4K/30fps)

PASS=0
FAIL=0
WARNINGS=0
STOP=0              # set to 1 on first failure; all subsequent tests are skipped

CRITICAL="gst_element_make_from_uri"

# Queue strings matching send_stream.sh exactly
Q="queue max-size-buffers=2 max-size-bytes=0 max-size-time=0 leaky=downstream"
Q_ENC_OUT="queue max-size-buffers=4 max-size-bytes=0 max-size-time=0"

# Detect pylonsrc NVMM support (same check as check_system.sh and send_stream.sh)
PYLONSRC_NVMM=0
if gst-inspect-1.0 pylonsrc >/dev/null 2>&1 && \
   gst-inspect-1.0 pylonsrc 2>/dev/null | grep -i "memory:NVMM" > /dev/null; then
  PYLONSRC_NVMM=1
fi


# ==============================================================================
# HELPERS
# ==============================================================================

# run_test LABEL [TIMEOUT_SEC] PIPELINE_STRING...
# Passes the pipeline as quoted args, matching send_stream.sh.
# Stops at the first failure (STOP=1).
# Optional TIMEOUT_SEC (default 30): if pipeline times out after this many
# seconds, treat as [OK] if timeout_is_ok=1, else [FAIL].
run_test() {
  local label="$1"
  local timeout_sec=30
  local timeout_is_ok=0
  shift

  # Check if next arg is a number (timeout override)
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    timeout_sec="$1"
    timeout_is_ok="$2"  # 1 = timeout is OK, 0 = timeout is failure
    shift 2
  fi

  if [[ "$STOP" -eq 1 ]]; then
    printf "  %-57s[SKIP]\n" "${label}"
    return 0
  fi

  printf "  %-57s" "${label}"

  local out rc=0
  # shellcheck disable=SC2068
  out=$(timeout "$timeout_sec" gst-launch-1.0 -e $@ 2>&1) || rc=$?
  if [[ $rc -eq 124 ]]; then
    if [[ $timeout_is_ok -eq 1 ]]; then
      echo "[OK] (ran ${timeout_sec}s, no errors)"
      PASS=$(( PASS + 1 ))
      return 0
    else
      echo "[FAIL] <-- pipeline hung (did not exit within ${timeout_sec}s)"
      FAIL=$(( FAIL + 1 ))
      STOP=1
      return 1
    fi
  fi

  if echo "$out" | grep -q "${CRITICAL}"; then
    echo "[FAIL] <-- gst_element_make_from_uri triggered"
    echo "         $(echo "$out" | grep "${CRITICAL}" | head -1)"
    FAIL=$(( FAIL + 1 ))
    STOP=1
    return 1
  elif echo "$out" | grep -qiE "syntax error|erroneous pipeline|no element|could not link"; then
    local msg
    msg=$(echo "$out" | grep -iE "syntax error|erroneous pipeline|no element|could not link" | head -1)
    echo "[FAIL] <-- ${msg}"
    FAIL=$(( FAIL + 1 ))
    STOP=1
    return 1
  else
    echo "[OK]"
    PASS=$(( PASS + 1 ))
    return 0
  fi
}



echo ""
echo "======================================================"
echo "  GStreamer Stage Diagnostic -- Jetson Orin NX"
echo "  Using ${W}x${H} @ ${FPS}fps, ${BUFFERS} frames per test"
echo "======================================================"
echo ""

# ==============================================================================
# PRE-FLIGHT CHECKS (critical issues that block all tests)
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if ! "${SCRIPT_DIR}/check_system.sh" --fatal-only; then
  echo "ERROR: Pre-flight checks failed. Run ./check_system.sh for details." >&2
  exit 1
fi


# ==============================================================================
# SECTION 1: Baseline -- no NVIDIA elements
# ==============================================================================
echo ""
echo "--- 1. Baseline (no NVIDIA elements) ---"

run_test "videotestsrc ! fakesink" \
  "videotestsrc num-buffers=${BUFFERS} ! fakesink sync=false"

run_test "videotestsrc ! identity ! fakesink" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! identity name=test silent=true check-imperfect-timestamp=true \
   ! fakesink sync=false"

run_test "videotestsrc ! queue ! fakesink" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! ${Q} \
   ! fakesink sync=false"


# ==============================================================================
# SECTION 2: nvvidconv -- system RAM to NVMM
# ==============================================================================
echo ""
echo "--- 2. nvvidconv ---"

run_test "videotestsrc ! nvvidconv ! fakesink" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvvidconv \
   ! fakesink sync=false"

run_test "... nvvidconv nvbuf-memory-type=4 ! fakesink" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvvidconv nvbuf-memory-type=4 \
   ! fakesink sync=false"

run_test "... nvvidconv(4) ! NVMM caps ! fakesink" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! fakesink sync=false"


# ==============================================================================
# SECTION 3: Encoders
# ==============================================================================
echo ""
echo "--- 3. nvv4l2h265enc ---"

run_test "... ! nvv4l2h265enc (minimal) ! fakesink" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvv4l2h265enc \
   ! fakesink sync=false"

run_test "... nvv4l2h265enc + bitrate + control-rate + profile" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvv4l2h265enc bitrate=${BITRATE} control-rate=1 profile=0 \
   ! fakesink sync=false"

run_test "... + iframeinterval + insert-sps-pps + maxperf-enable" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvv4l2h265enc bitrate=${BITRATE} control-rate=1 profile=0 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
   ! fakesink sync=false"

echo ""
echo "--- 4. nvv4l2h264enc ---"

run_test "... nvv4l2h264enc full props ! fakesink" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvv4l2h264enc bitrate=${BITRATE} control-rate=1 profile=4 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
   ! fakesink sync=false"


# ==============================================================================
# SECTION 5: Parsers
# ==============================================================================
echo ""
echo "--- 5. Parsers ---"

run_test "... ! nvv4l2h265enc ! h265parse config-interval=-1 ! fakesink" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvv4l2h265enc bitrate=${BITRATE} control-rate=1 profile=0 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
   ! h265parse config-interval=-1 \
   ! fakesink sync=false"

run_test "... ! nvv4l2h264enc ! h264parse config-interval=-1 ! fakesink" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvv4l2h264enc bitrate=${BITRATE} control-rate=1 profile=4 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
   ! h264parse config-interval=-1 \
   ! fakesink sync=false"


# ==============================================================================
# SECTION 6: pylonsrc NVMM capability
#
# Mirrors the mandatory check in check_system.sh and send_stream.sh.
# Tests whether the color NVMM-direct path is available on this system.
# Also validates that the NVMM-to-NVMM pipeline (nvvidconv NVMM->NVMM)
# works correctly -- this is the path used in color mode after pylonsrc
# outputs a frame in NVMM.
# ==============================================================================
echo ""
echo "--- 6. pylonsrc NVMM capability (mandatory for color zero-copy path) ---"

if [[ "$PYLONSRC_NVMM" -eq 1 ]]; then
  printf "  %-57s[OK]  zero-copy color path available\n" "pylonsrc NVMM caps"
else
  printf "  %-57s[FAIL]\n" "pylonsrc NVMM caps"
  echo "         memory:NVMM not found in pylonsrc caps."
  echo "         Color capture requires a system RAM -> GPU copy per frame."
  echo "         Upgrade: github.com/basler/gst-plugin-pylon/releases"
  FAIL=$(( FAIL + 1 ))
fi

# Test the NVMM -> NVMM processing path that color mode uses after pylonsrc.
# videotestsrc cannot output NVMM directly, so we seed with nvvidconv first
# to create an NVMM buffer, then exercise the remaining NVMM-only stages.
echo ""
echo "  NVMM-to-NVMM path (simulated: nvvidconv seeds NVMM, rest stays in NVMM)"

run_test "nvmm seed -> nvvidconv(NVMM->NVMM NV12) -> fakesink" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=BGRx,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! fakesink sync=false"

run_test "nvmm seed -> nvv4l2h265enc -> h265parse -> fakesink (full NVMM chain)" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=BGRx,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! nvv4l2h265enc bitrate=${BITRATE} control-rate=1 profile=0 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
   ! h265parse config-interval=-1 \
   ! fakesink sync=false"


# ==============================================================================
# SECTION 7: Full send_stream.sh equivalent (videotestsrc, color mode, no camera)
#
# Mirrors the color-mode pipeline from send_stream.sh element by element.
# videotestsrc cannot output NVMM directly, so a BGRx caps step simulates
# the format pylonsrc would put into NVMM (in production: USB DMA -> GPU).
#
#   src ! BGRx caps                     videotestsrc simulating pylonsrc color
#   -> identity(cam)
#   -> queue
#   -> nvvidconv nvbuf-memory-type=4    BGRx -> NV12, system RAM -> NVMM
#   -> NVMM NV12 caps
#   -> identity(pre-enc)
#   -> nvv4l2h264enc (all props as in send_stream.sh)
#   -> identity(post-enc)
#   -> queue(post-enc)
#   -> h264parse config-interval=-1
#   -> fakesink
#
# The first [FAIL] here pinpoints the element that is the root cause.
# ==============================================================================
echo ""
echo "--- 7. Full send_stream.sh equivalent -- color mode (videotestsrc, no camera) ---"
STOP=0  # reset so this section always runs regardless of earlier failures

run_test "src ! BGRx caps ! fakesink" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=BGRx,width=${W},height=${H},framerate=${FPS}/1 \
   ! fakesink sync=false"

run_test "+ identity name=cam check-imperfect-timestamp=true" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=BGRx,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! fakesink sync=false"

run_test "+ queue(pre-nvvidconv, leaky=downstream)" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=BGRx,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! fakesink sync=false"

run_test "+ nvvidconv nvbuf-memory-type=4 (BGRx -> NV12 NVMM)" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=BGRx,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! nvvidconv nvbuf-memory-type=4 \
   ! fakesink sync=false"

run_test "+ NV12 NVMM caps filter" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=BGRx,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! fakesink sync=false"

run_test "+ identity name=pre-enc check-imperfect-timestamp=true" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=BGRx,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=pre-enc silent=true check-imperfect-timestamp=true \
   ! fakesink sync=false"

run_test "+ nvv4l2h264enc (all send_stream.sh props)" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=BGRx,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=pre-enc silent=true check-imperfect-timestamp=true \
   ! nvv4l2h264enc bitrate=${BITRATE} control-rate=1 profile=4 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
   ! fakesink sync=false"

run_test "+ identity name=post-enc check-imperfect-timestamp=true" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=BGRx,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=pre-enc silent=true check-imperfect-timestamp=true \
   ! nvv4l2h264enc bitrate=${BITRATE} control-rate=1 profile=4 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
   ! identity name=post-enc silent=true check-imperfect-timestamp=true \
   ! fakesink sync=false"

run_test "+ queue(post-enc output)" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=BGRx,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=pre-enc silent=true check-imperfect-timestamp=true \
   ! nvv4l2h264enc bitrate=${BITRATE} control-rate=1 profile=4 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
   ! identity name=post-enc silent=true check-imperfect-timestamp=true \
   ! ${Q_ENC_OUT} \
   ! fakesink sync=false"

run_test "+ h264parse config-interval=-1" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=BGRx,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=pre-enc silent=true check-imperfect-timestamp=true \
   ! nvv4l2h264enc bitrate=${BITRATE} control-rate=1 profile=4 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
   ! identity name=post-enc silent=true check-imperfect-timestamp=true \
   ! ${Q_ENC_OUT} \
   ! h264parse config-interval=-1 \
   ! fakesink sync=false"

run_test "+ rtph264pay pt=96 config-interval=-1 (full chain to RTP payloader)" \
  "videotestsrc num-buffers=${BUFFERS} \
   ! video/x-raw,format=BGRx,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=pre-enc silent=true check-imperfect-timestamp=true \
   ! nvv4l2h264enc bitrate=${BITRATE} control-rate=1 profile=4 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
   ! identity name=post-enc silent=true check-imperfect-timestamp=true \
   ! ${Q_ENC_OUT} \
   ! h264parse config-interval=-1 \
   ! rtph264pay pt=96 config-interval=-1 \
   ! fakesink sync=false"


# ==============================================================================
# SECTION 8: pylonsrc (camera required)
# ==============================================================================
echo ""
echo "--- 8. pylonsrc (camera must be connected, ${CAM_BUFFERS} frames per test) ---"

# CRITICAL: Verify camera outputs a color format (YUY2/UYVY/BGR/RGB), not GRAY8
# Also verify the negotiated framerate matches the requested production framerate.
echo ""
echo "  [FORMAT CHECK] Camera pixel format and framerate"
out=$(gst-launch-1.0 -v pylonsrc num-buffers=1 ! "video/x-raw(memory:NVMM),format=YUY2,width=${W},height=${H},framerate=${FPS}/1" ! fakesink 2>&1)
fmt=$(echo "$out" | grep "pylonsrc0.GstPad:src: caps" | grep -o "format=(string)[^,)]*" | sed 's/format=(string)//')
negotiated_fps=$(echo "$out" | grep "pylonsrc0.GstPad:src: caps" | grep -o "framerate=(fraction)[^,)]*" | sed 's/framerate=(fraction)//')
if echo "$fmt" | grep -qE "^BGR$|^RGB$|^YUY2$|^UYVY$"; then
  printf "  %-57s[OK]  camera outputs %s (color)\n" "Camera format" "$fmt"
else
  printf "  %-57s[FAIL] camera outputs %s (should be YUY2 for NVMM path)\n" "Camera format" "$fmt"
  echo ""
  echo "         SOLUTION: Configure camera pixel format in pylon Viewer"
  echo "           - Launch: /opt/pylon/bin/pylonviewer"
  echo "           - Connect to camera"
  echo "           - Camera Features → PixelFormat → select YCbCr422_8 (= YUY2)"
  echo "           - Save camera settings"
  echo "         After configuring, re-run diagnose_pipeline.sh"
  FAIL=$(( FAIL + 1 ))
  STOP=1
fi

# Framerate check -- camera may not support exact fraction and negotiate differently
expected_fps="${FPS}/1"
if [[ -z "$negotiated_fps" ]]; then
  printf "  %-57s[WARN] could not read negotiated framerate\n" "Camera framerate"
elif [[ "$negotiated_fps" == "$expected_fps" ]]; then
  printf "  %-57s[OK]  camera runs at %s fps\n" "Camera framerate" "$FPS"
else
  printf "  %-57s[WARN] requested %s fps, camera negotiated %s\n" "Camera framerate" "$expected_fps" "$negotiated_fps"
  echo "         Camera does not support exactly ${FPS}fps -- pipeline will run at ${negotiated_fps}."
  echo "         To match: set FRAMERATE to a value the camera natively supports."
  WARNINGS=$(( WARNINGS + 1 ))
fi

run_test "pylonsrc ! fakesink" 10 1 \
  "pylonsrc num-buffers=${CAM_BUFFERS} ! fakesink sync=false"

# Color path (primary -- YUY2 NVMM zero-copy, matches send_stream.sh default)
if [[ "$PYLONSRC_NVMM" -eq 1 ]]; then
  echo ""
  echo "  Color path (primary -- YUY2 NVMM zero-copy)"
  STOP=0

  run_test "pylonsrc NVMM direct -> nvvidconv(NVMM->NV12) -> fakesink" 10 1 \
    "pylonsrc num-buffers=${CAM_BUFFERS} \
     ! video/x-raw(memory:NVMM),format=YUY2,width=${W},height=${H},framerate=${FPS}/1 \
     ! nvvidconv nvbuf-memory-type=4 \
     ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
     ! fakesink sync=false"

  run_test "pylonsrc full color pipeline (NVMM zero-copy)" 10 1 \
    "pylonsrc num-buffers=${CAM_BUFFERS} \
     ! video/x-raw(memory:NVMM),format=YUY2,width=${W},height=${H},framerate=${FPS}/1 \
     ! identity name=cam silent=true check-imperfect-timestamp=true \
     ! ${Q} \
     ! nvvidconv nvbuf-memory-type=4 \
     ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
     ! identity name=pre-enc silent=true check-imperfect-timestamp=true \
     ! nvv4l2h264enc bitrate=${BITRATE} control-rate=1 profile=4 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
     ! identity name=post-enc silent=true check-imperfect-timestamp=true \
     ! ${Q_ENC_OUT} \
     ! h264parse config-interval=-1 \
     ! fakesink sync=false"

  # Test the full production chain with rtspclientsink (requires MediaMTX running)
  RTSP_HOST="127.0.0.1"
  RTSP_PORT="8554"
  if nc -z -w1 "$RTSP_HOST" "$RTSP_PORT" 2>/dev/null; then
    RTSP_URL="rtsp://${RTSP_HOST}:${RTSP_PORT}/diag"
    run_test "pylonsrc full chain + rtspclientsink (production)" 10 1 \
      "pylonsrc num-buffers=${CAM_BUFFERS} \
       ! video/x-raw(memory:NVMM),format=YUY2,width=${W},height=${H},framerate=${FPS}/1 \
       ! identity name=cam silent=true check-imperfect-timestamp=true \
       ! ${Q} \
       ! nvvidconv nvbuf-memory-type=4 \
       ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
       ! identity name=pre-enc silent=true check-imperfect-timestamp=true \
       ! nvv4l2h264enc bitrate=${BITRATE} control-rate=1 profile=4 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
       ! identity name=post-enc silent=true check-imperfect-timestamp=true \
       ! ${Q_ENC_OUT} \
       ! h264parse config-interval=-1 \
       ! rtspclientsink location=\"${RTSP_URL}\" protocols=tcp"
  else
    echo ""
    echo "  [SKIP] rtspclientsink test -- MediaMTX not running at ${RTSP_HOST}:${RTSP_PORT}"
  fi
else
  echo "  [SKIP] Color path -- NVMM caps not available (upgrade pylon plugin)"
fi



# ==============================================================================
# SUMMARY
# ==============================================================================
echo ""
echo "======================================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
  echo "  The first [FAIL] in each section pinpoints the"
  echo "  element or property that introduces the error."
fi
echo "======================================================"
echo ""
