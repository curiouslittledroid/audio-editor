#!/bin/bash
#
# Visual regression suite: renders the real window in several states and asserts
# on the resulting pixels. Produces PNGs in TestOutput/ plus pass/fail output.
#
#   ./tools/uitest.sh
#
set -uo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

ROOT="$PROJECT_ROOT"
OUT="$ROOT/TestOutput"

"$ROOT/build.sh" release >/dev/null || { echo "error: build failed" >&2; exit 1; }
mkdir -p "$OUT"

# Reuse the freshly built bundle for every case.
export AUDIOEDIT_SKIP_BUILD=1

FAILED=0
run_case() {
    local name="$1"; shift
    echo ""
    echo "############################################################"
    echo "# $name"
    echo "############################################################"

    local log="$OUT/$name.log"
    # --uicheck is always on here: this suite exists to run the assertions.
    "$ROOT/tools/capture.sh" "$OUT/$name.png" --uicheck "$@" 2>&1 | tee "$log"
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then FAILED=1; fi

    # Guard against a vacuous pass: the render must have happened *and* the
    # assertions must actually have run and reported clean.
    if ! grep -q "snapshot: wrote" "$log"; then
        echo "  !! $name produced no snapshot"
        FAILED=1
    fi
    if ! grep -q "CHECKS PASSED" "$log"; then
        echo "  !! $name ran no passing assertions"
        FAILED=1
    fi
}

# -------------------------------------------------------------- 1. full view
# bursts fixture: audio at 0.5-1.5s, 3.0-3.4s, 4.5-5.8s; silence in between.
run_case ui-1-full-view \
    --file "$ROOT/TestAudio/bursts-44100-stereo16.wav" \
    --trim 0 6 \
    --loud "0.7-1.3,3.05-3.35,4.7-5.6" \
    --quiet "1.8-2.8,3.6-4.3"

# ------------------------------------------------------------ 2. trimmed view
# Handles must land exactly on the trim points; the playhead on its time.
run_case ui-2-trimmed \
    --file "$ROOT/TestAudio/bursts-44100-stereo16.wav" \
    --trim 1.0 4.5 \
    --playhead 2.5 \
    --loud "1.1-1.4,3.05-3.35" \
    --quiet "2.0-2.8"

# ---------------------------------------------------------------- 3. long file
run_case ui-3-long \
    --file "$ROOT/TestAudio/long-44100-stereo16.wav" \
    --trim 30 150 \
    --playhead 90

# --------------------------------------------------------------- 4. short file
run_case ui-4-short \
    --file "$ROOT/TestAudio/blip-44100-mono16.wav" \
    --trim 0.05 0.30 \
    --playhead 0.20

# ------------------------------------------------------------ 5. mono 24-bit
run_case ui-5-mono-24bit \
    --file "$ROOT/TestAudio/sweep-48000-mono24.wav" \
    --trim 3 9 \
    --playhead 6

echo ""
echo "############################################################"
if [[ $FAILED -eq 0 ]]; then
    echo "# VISUAL CHECKS PASSED          (PNGs in TestOutput/)"
else
    echo "# VISUAL CHECKS FAILED"
fi
echo "############################################################"
exit $FAILED