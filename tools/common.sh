#!/bin/bash
#
# Shared environment for the project scripts. Source it; do not execute it.
#
#   source "$(dirname "$0")/common.sh"      # from tools/
#   source "$(dirname "$0")/tools/common.sh" # from the repo root
#
# Provides: PROJECT_ROOT, APP_NAME, EXEC_NAME, APP_BUNDLE, APP_BINARY, and a
# working Swift toolchain.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Audio Editor"
EXEC_NAME="AudioEditor"
APP_BUNDLE="$PROJECT_ROOT/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"

# Use whichever Swift toolchain is active — Xcode, once installed and licensed.
# Fall back to Command Line Tools only when the Xcode licence gate is blocking
# the compiler: clearing that gate needs an interactive `sudo xcodebuild
# -license`, whereas this package builds fine with CLT alone.
if [[ -z "${DEVELOPER_DIR:-}" ]] \
   && ! defaults read /Library/Preferences/com.apple.dt.Xcode.plist IDELastGMLicenseAgreedTo >/dev/null 2>&1 \
   && [[ -d /Library/Developer/CommandLineTools ]]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi