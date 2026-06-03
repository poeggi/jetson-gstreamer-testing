#!/usr/bin/env bash
# ==============================================================================
# diagnose_pipeline.sh
#
# Systematically tests each GStreamer pipeline stage on Jetson Orin NX,
# adding one element at a time to identify exactly which element triggers
# the gst_element_make_from_uri CRITICAL assertion or a syntax error.
#
# Mirrors basler_pipeline.sh exactly: same elements, same properties, same
# default mode (bayer capture, H.265, fakesink).
#
# Must be run on the Jetson itself. Camera must be connected for sections
# marked "(camera required)".
#
# Usage:
#   ./diagnose_pipeline.sh
# ==============================================================================

set -uo pipefail

BUFFERS=30          # frames per test -- enough to confirm pipeline runs
W=640               # small resolution for speed; full-res at the end
H=480
FPS=30
BITRATE=4000000

PASS=0
FAIL=0
STOP=0              # set to 1 on first failure; all subsequent tests are skipped

CRITICAL="gst_element_make_from_uri"

# Queue strings matching basler_pipeline.sh exactly
Q="queue max-size-buffers=2 max-size-bytes=0 max-size-time=0 leaky=downstream"
Q_ENC_OUT="queue max-size-buffers=4 max-size-bytes=0 max-size-time=0"

# Detect pylonsrc NVMM support (same check as check_system.sh and basler_pipeline.sh)
PYLONSRC_NVMM=0
if gst-inspect-1.0 pylonsrc >/dev/null 2>&1 && \
   gst-inspect-1.0 pylonsrc 2>/dev/null | grep -qi "memory:NVMM"; then
  PYLONSRC_NVMM=1
fi


# ==============================================================================
# HELPERS
# ==============================================================================

# run_test LABEL PIPELINE_STRING
# Passes the pipeline as a single quoted string, matching basler_pipeline.sh.
# Stops at the first failure (STOP=1).
run_test() {
  local label="$1"
  shift

  if [[ "$STOP" -eq 1 ]]; then
    printf "  %-57s[SKIP]\n" "${label}"
    return 0
  fi

  printf "  %-57s" "${label}"

  local out
  out=$(gst-launch-1.0 -e "$@" 2>&1) || true

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

# run_compare LABEL PIPELINE_STRING
# Runs the same pipeline string TWO ways, side by side -- does NOT stop on
# failure. Used to compare single-string vs word-split launch methods.
run_compare() {
  local label="$1"
  local pipe="$2"

  # Method A: single quoted string (exactly as basler_pipeline.sh calls gst-launch)
  printf "  %-57s" "${label} [single-string]"
  local out
  out=$(gst-launch-1.0 -e "$pipe" 2>&1) || true
  if echo "$out" | grep -q "${CRITICAL}"; then
    echo "[FAIL] gst_element_make_from_uri"
  elif echo "$out" | grep -qiE "syntax error|erroneous pipeline|no element|could not link"; then
    echo "[FAIL] $(echo "$out" | grep -iE "syntax error|erroneous pipeline|no element|could not link" | head -1)"
  else
    echo "[OK]"
  fi

  # Method B: word-split (unquoted -- the proposed fix for basler_pipeline.sh).
  # (memory:NVMM) in caps strings is not a glob pattern; no file expansion occurs.
  printf "  %-57s" "${label} [word-split]"
  out=$(gst-launch-1.0 -e $pipe 2>&1) || true
  if echo "$out" | grep -q "${CRITICAL}"; then
    echo "[FAIL] gst_element_make_from_uri"
  elif echo "$out" | grep -qiE "syntax error|erroneous pipeline|no element|could not link"; then
    echo "[FAIL] $(echo "$out" | grep -iE "syntax error|erroneous pipeline|no element|could not link" | head -1)"
  else
    echo "[OK]"
  fi
}


echo ""
echo "======================================================"
echo "  GStreamer Stage Diagnostic -- Jetson Orin NX"
echo "  Using ${W}x${H} @ ${FPS}fps, ${BUFFERS} frames per test"
echo "======================================================"


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

run_test "videotestsrc ! bayer2rgb ! fakesink" \
  "videotestsrc num-buffers=${BUFFERS} pattern=snow \
   ! video/x-raw,format=GRAY8,width=${W},height=${H},framerate=${FPS}/1 \
   ! bayer2rgb \
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
# Mirrors the mandatory check in check_system.sh and basler_pipeline.sh.
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
# SECTION 7: Full basler_pipeline.sh equivalent (videotestsrc, no camera)
#
# Mirrors the bayer-mode pipeline from basler_pipeline.sh element by element:
#   videotestsrc (simulating pylonsrc)
#   -> x-bayer caps
#   -> identity(cam, check-imperfect-timestamp)
#   -> queue(pre-bayer)
#   -> bayer2rgb
#   -> queue(pre-nvvidconv)
#   -> nvvidconv nvbuf-memory-type=4
#   -> NVMM caps
#   -> identity(pre-enc, check-imperfect-timestamp)
#   -> nvv4l2h265enc (all props as in basler_pipeline.sh)
#   -> identity(post-enc, check-imperfect-timestamp)
#   -> queue(post-enc)
#   -> h265parse config-interval=-1
#   -> fakesink
#
# The first [FAIL] here pinpoints the element that is the root cause.
# ==============================================================================
echo ""
echo "--- 7. Full basler_pipeline.sh equivalent (videotestsrc, no camera) ---"
STOP=0  # reset so this section always runs regardless of earlier failures

run_test "src ! x-bayer caps ! fakesink" \
  "videotestsrc num-buffers=${BUFFERS} pattern=snow \
   ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 \
   ! fakesink sync=false"

run_test "+ identity name=cam check-imperfect-timestamp=true" \
  "videotestsrc num-buffers=${BUFFERS} pattern=snow \
   ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! fakesink sync=false"

run_test "+ queue(pre-bayer, leaky=downstream)" \
  "videotestsrc num-buffers=${BUFFERS} pattern=snow \
   ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! fakesink sync=false"

run_test "+ bayer2rgb" \
  "videotestsrc num-buffers=${BUFFERS} pattern=snow \
   ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! bayer2rgb \
   ! fakesink sync=false"

run_test "+ queue(pre-nvvidconv, leaky=downstream)" \
  "videotestsrc num-buffers=${BUFFERS} pattern=snow \
   ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! bayer2rgb \
   ! ${Q} \
   ! fakesink sync=false"

run_test "+ nvvidconv nvbuf-memory-type=4" \
  "videotestsrc num-buffers=${BUFFERS} pattern=snow \
   ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! bayer2rgb \
   ! ${Q} \
   ! nvvidconv nvbuf-memory-type=4 \
   ! fakesink sync=false"

run_test "+ NVMM caps filter" \
  "videotestsrc num-buffers=${BUFFERS} pattern=snow \
   ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! bayer2rgb \
   ! ${Q} \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! fakesink sync=false"

run_test "+ identity name=pre-enc check-imperfect-timestamp=true" \
  "videotestsrc num-buffers=${BUFFERS} pattern=snow \
   ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! bayer2rgb \
   ! ${Q} \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=pre-enc silent=true check-imperfect-timestamp=true \
   ! fakesink sync=false"

run_test "+ nvv4l2h265enc (all basler_pipeline.sh props)" \
  "videotestsrc num-buffers=${BUFFERS} pattern=snow \
   ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! bayer2rgb \
   ! ${Q} \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=pre-enc silent=true check-imperfect-timestamp=true \
   ! nvv4l2h265enc bitrate=${BITRATE} control-rate=1 profile=0 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
   ! fakesink sync=false"

run_test "+ identity name=post-enc check-imperfect-timestamp=true" \
  "videotestsrc num-buffers=${BUFFERS} pattern=snow \
   ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! bayer2rgb \
   ! ${Q} \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=pre-enc silent=true check-imperfect-timestamp=true \
   ! nvv4l2h265enc bitrate=${BITRATE} control-rate=1 profile=0 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
   ! identity name=post-enc silent=true check-imperfect-timestamp=true \
   ! fakesink sync=false"

run_test "+ queue(post-enc output)" \
  "videotestsrc num-buffers=${BUFFERS} pattern=snow \
   ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! bayer2rgb \
   ! ${Q} \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=pre-enc silent=true check-imperfect-timestamp=true \
   ! nvv4l2h265enc bitrate=${BITRATE} control-rate=1 profile=0 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
   ! identity name=post-enc silent=true check-imperfect-timestamp=true \
   ! ${Q_ENC_OUT} \
   ! fakesink sync=false"

run_test "+ h265parse config-interval=-1 (full pipeline complete)" \
  "videotestsrc num-buffers=${BUFFERS} pattern=snow \
   ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! bayer2rgb \
   ! ${Q} \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=pre-enc silent=true check-imperfect-timestamp=true \
   ! nvv4l2h265enc bitrate=${BITRATE} control-rate=1 profile=0 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
   ! identity name=post-enc silent=true check-imperfect-timestamp=true \
   ! ${Q_ENC_OUT} \
   ! h265parse config-interval=-1 \
   ! fakesink sync=false"


# ==============================================================================
# SECTION 8: Launch method comparison
#
# Tests the complete basler_pipeline.sh-equivalent string TWO ways:
#   [single-string] -- exactly as basler_pipeline.sh calls gst-launch
#   [word-split]    -- the proposed fix (unquoted PIPELINE variable)
#
# If [single-string] fails but [word-split] passes, the root cause is the
# single-argument passing method, not the pipeline content itself.
# ==============================================================================
echo ""
echo "--- 8. Launch method comparison (single-string vs word-split) ---"

FULL_PIPE="videotestsrc num-buffers=${BUFFERS} pattern=snow ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 ! identity name=cam silent=true check-imperfect-timestamp=true ! ${Q} ! bayer2rgb ! ${Q} ! nvvidconv nvbuf-memory-type=4 ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 ! identity name=pre-enc silent=true check-imperfect-timestamp=true ! nvv4l2h265enc bitrate=${BITRATE} control-rate=1 profile=0 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 ! identity name=post-enc silent=true check-imperfect-timestamp=true ! ${Q_ENC_OUT} ! h265parse config-interval=-1 ! fakesink sync=false"

run_compare "full pipeline (bayer -> h265 -> fakesink)" "$FULL_PIPE"


# ==============================================================================
# SECTION 9: RTSP output
#
# Tests the rtspclientsink path. Skipped automatically if MediaMTX is not
# running. Start MediaMTX first: ./mediamtx  (port 8554)
# ==============================================================================
echo ""
echo "--- 9. RTSP output (requires MediaMTX at 127.0.0.1:8554) ---"

RTSP_HOST="127.0.0.1"
RTSP_PORT="8554"

if nc -z -w1 "$RTSP_HOST" "$RTSP_PORT" 2>/dev/null; then
  RTSP_URL="rtsp://${RTSP_HOST}:${RTSP_PORT}/diag"
  STOP=0

  run_test "rtph265pay ! rtspclientsink location=rtsp://... (bare)" \
    "videotestsrc num-buffers=${BUFFERS} \
     ! video/x-raw,format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
     ! nvvidconv nvbuf-memory-type=4 \
     ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
     ! nvv4l2h265enc bitrate=${BITRATE} control-rate=1 profile=0 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
     ! h265parse config-interval=-1 \
     ! rtph265pay pt=96 config-interval=-1 \
     ! rtspclientsink location=${RTSP_URL} protocols=tcp"

  run_test "rtspclientsink location=\"rtsp://...\" (quoted URI value)" \
    "videotestsrc num-buffers=${BUFFERS} \
     ! video/x-raw,format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
     ! nvvidconv nvbuf-memory-type=4 \
     ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
     ! nvv4l2h265enc bitrate=${BITRATE} control-rate=1 profile=0 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
     ! h265parse config-interval=-1 \
     ! rtph265pay pt=96 config-interval=-1 \
     ! rtspclientsink location=\"${RTSP_URL}\" protocols=tcp"

  RTSP_FULL="videotestsrc num-buffers=${BUFFERS} pattern=snow ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 ! identity name=cam silent=true check-imperfect-timestamp=true ! ${Q} ! bayer2rgb ! ${Q} ! nvvidconv nvbuf-memory-type=4 ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 ! identity name=pre-enc silent=true check-imperfect-timestamp=true ! nvv4l2h265enc bitrate=${BITRATE} control-rate=1 profile=0 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 ! identity name=post-enc silent=true check-imperfect-timestamp=true ! ${Q_ENC_OUT} ! h265parse config-interval=-1 ! rtph265pay pt=96 config-interval=-1 ! rtspclientsink location=\"${RTSP_URL}\" protocols=tcp"
  run_compare "full RTSP pipeline (single-string vs word-split)" "$RTSP_FULL"
else
  echo "  [SKIP] MediaMTX not running at ${RTSP_HOST}:${RTSP_PORT}"
  echo "         Start with: ./mediamtx"
fi


# ==============================================================================
# SECTION 10: pylonsrc (camera required)
# ==============================================================================
echo ""
echo "--- 10. pylonsrc (camera must be connected) ---"

run_test "pylonsrc ! fakesink" \
  "pylonsrc num-buffers=${BUFFERS} ! fakesink sync=false"

run_test "pylonsrc ! video/x-bayer caps ! fakesink" \
  "pylonsrc num-buffers=${BUFFERS} \
   ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 \
   ! fakesink sync=false"

run_test "pylonsrc ! identity name=cam check-imperfect-timestamp=true" \
  "pylonsrc num-buffers=${BUFFERS} \
   ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! fakesink sync=false"

run_test "pylonsrc ! queue ! bayer2rgb ! queue ! nvvidconv ! fakesink" \
  "pylonsrc num-buffers=${BUFFERS} \
   ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! bayer2rgb \
   ! ${Q} \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! fakesink sync=false"

run_test "pylonsrc full bayer pipeline (small res)" \
  "pylonsrc num-buffers=${BUFFERS} \
   ! video/x-bayer,format=rggb,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=cam silent=true check-imperfect-timestamp=true \
   ! ${Q} \
   ! bayer2rgb \
   ! ${Q} \
   ! nvvidconv nvbuf-memory-type=4 \
   ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
   ! identity name=pre-enc silent=true check-imperfect-timestamp=true \
   ! nvv4l2h265enc bitrate=${BITRATE} control-rate=1 profile=0 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
   ! identity name=post-enc silent=true check-imperfect-timestamp=true \
   ! ${Q_ENC_OUT} \
   ! h265parse config-interval=-1 \
   ! fakesink sync=false"

# NVMM direct color path (matches basler_pipeline.sh CAPTURE_MODE=color with NVMM)
if [[ "$PYLONSRC_NVMM" -eq 1 ]]; then
  echo ""
  echo "  pylonsrc NVMM color path (requires NVMM-capable pylon plugin)"
  STOP=0

  run_test "pylonsrc NVMM direct -> nvvidconv(NVMM->NV12) -> fakesink" \
    "pylonsrc num-buffers=${BUFFERS} \
     ! video/x-raw(memory:NVMM),width=${W},height=${H},framerate=${FPS}/1 \
     ! nvvidconv nvbuf-memory-type=4 \
     ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
     ! fakesink sync=false"

  run_test "pylonsrc NVMM + full encode chain (zero-copy color path)" \
    "pylonsrc num-buffers=${BUFFERS} \
     ! video/x-raw(memory:NVMM),width=${W},height=${H},framerate=${FPS}/1 \
     ! identity name=cam silent=true check-imperfect-timestamp=true \
     ! ${Q} \
     ! nvvidconv nvbuf-memory-type=4 \
     ! video/x-raw(memory:NVMM),format=NV12,width=${W},height=${H},framerate=${FPS}/1 \
     ! identity name=pre-enc silent=true check-imperfect-timestamp=true \
     ! nvv4l2h265enc bitrate=${BITRATE} control-rate=1 profile=0 iframeinterval=${FPS} insert-sps-pps=1 maxperf-enable=1 \
     ! identity name=post-enc silent=true check-imperfect-timestamp=true \
     ! ${Q_ENC_OUT} \
     ! h265parse config-interval=-1 \
     ! fakesink sync=false"
else
  echo "  [SKIP] pylonsrc NVMM color path -- NVMM caps not available on this system"
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
  echo "  Section 7 shows whether the issue is the launch"
  echo "  method (single-string) or the pipeline content."
fi
echo "======================================================"
echo ""
