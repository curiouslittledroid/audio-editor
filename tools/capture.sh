#!/bin/bash
#
# Renders the Audio Editor window to a PNG, using the app's own layer-tree
# capture (so no Screen Recording permission is needed).
#
# Configuration is passed through the environment, never argv: AppKit parses
# `-flag value` pairs out of the argument list and treats a leftover token as
# "open this document", which stops SwiftUI from creating a window at all.
#
#   ./tools/capture.sh <out.png> [opts]
#
#   --file <wav>        load a file          --trim <start> <end>
#   --fade <in>,<out>   linear fades in seconds at the trim boundaries
#   --playhead <sec>    place the playhead   --loop
#   --size <WxH>        window size          --banner "error:msg" | "info:msg"
#   --uicheck           also run pixel assertions
#   --loud  a-b,c-d     times expected to be loud
#   --quiet a-b,c-d     times expected to be silent
#
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

OUT="${1:?usage: capture.sh <out.png> [options...]}"
shift

ROOT="$PROJECT_ROOT"
BIN="$APP_BINARY"

# Always refresh the bundle: these tests run the .app, and a stale one silently
# tests old code. Set AUDIOEDIT_SKIP_BUILD=1 to reuse the existing bundle.
if [[ "${AUDIOEDIT_SKIP_BUILD:-0}" != "1" ]]; then
    "$ROOT/build.sh" release >/dev/null || { echo "error: build failed" >&2; exit 1; }
fi

[[ -x "$BIN" ]] || { echo "error: no binary at $BIN" >&2; exit 1; }

unset AUDIOEDIT_SNAPSHOT AUDIOEDIT_FILE AUDIOEDIT_TRIM AUDIOEDIT_FADE AUDIOEDIT_PLAYHEAD \
      AUDIOEDIT_LOOP AUDIOEDIT_SIZE AUDIOEDIT_BANNER AUDIOEDIT_UICHECK \
      AUDIOEDIT_LOUD AUDIOEDIT_QUIET AUDIOEDIT_SETTLE AUDIOEDIT_SELFTEST 2>/dev/null || true

export AUDIOEDIT_SNAPSHOT="$OUT"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)      export AUDIOEDIT_FILE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
        --trim)      export AUDIOEDIT_TRIM="$2,$3"; shift 3 ;;
        --fade)      export AUDIOEDIT_FADE="$2"; shift 2 ;;
        --playhead)  export AUDIOEDIT_PLAYHEAD="$2"; shift 2 ;;
        --loop)      export AUDIOEDIT_LOOP=1; shift ;;
        --size)      export AUDIOEDIT_SIZE="$2"; shift 2 ;;
        --banner)    export AUDIOEDIT_BANNER="$2"; shift 2 ;;
        --uicheck)   export AUDIOEDIT_UICHECK=1; shift ;;
        --loud)      export AUDIOEDIT_LOUD="$2"; shift 2 ;;
        --quiet)     export AUDIOEDIT_QUIET="$2"; shift 2 ;;
        --settle)    export AUDIOEDIT_SETTLE="$2"; shift 2 ;;
        *) echo "capture.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

pkill -f "$APP_NAME.app/Contents/MacOS/$EXEC_NAME" 2>/dev/null || true
sleep 0.5

"$BIN"
