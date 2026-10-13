#!/bin/bash
#
# Runs the headless audio-pipeline self test over every fixture in TestAudio/.
# Regenerate fixtures first with: swift tools/make-test-audio.swift
#
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

ROOT="$PROJECT_ROOT"
BIN="$APP_BINARY"

# Always refresh the bundle: these tests run the .app, and a stale one silently
# tests old code. Set AUDIOEDIT_SKIP_BUILD=1 to reuse the existing bundle.
if [[ "${AUDIOEDIT_SKIP_BUILD:-0}" != "1" ]]; then
    "$ROOT/build.sh" release >/dev/null || { echo "error: build failed" >&2; exit 1; }
fi

[[ -x "$BIN" ]] || { echo "error: no binary at $BIN" >&2; exit 1; }

FIXTURE_DIR="$ROOT/TestAudio"

# Fixtures are generated rather than committed, so a fresh clone has none.
if [[ ! -d "$FIXTURE_DIR" && $# -eq 0 ]]; then
    echo "==> No fixtures yet; generating them (swift tools/make-test-audio.swift)"
    swift "$ROOT/tools/make-test-audio.swift" >/dev/null \
        || { echo "error: could not generate fixtures" >&2; exit 1; }
fi

FILES=("$@")
if [[ ${#FILES[@]} -eq 0 ]]; then
    for f in "$FIXTURE_DIR"/*.wav; do
        [[ -e "$f" ]] && FILES+=("$f")
    done
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "error: no fixtures found. Run: swift tools/make-test-audio.swift" >&2
    exit 1
fi

"$BIN" --selftest "${FILES[@]}"
