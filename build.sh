#!/bin/bash
#
# Builds AudioEditor and wraps the binary in a proper macOS .app bundle.
#
#   ./build.sh              # release build (default)
#   ./build.sh debug        # debug build
#   ./build.sh release run  # build then launch
#
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/tools/common.sh"

CONFIG="${1:-release}"
ACTION="${2:-}"

cd "$PROJECT_ROOT"

APP="$APP_BUNDLE"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$EXEC_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: expected binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$EXEC_NAME"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [[ -f "$PROJECT_ROOT/Resources/AppIcon.icns" ]]; then
    cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
    || echo "    (ad-hoc signing skipped — the app will still run locally)"

# Nudge Launch Services so the app and its .wav association are picked up.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" >/dev/null 2>&1 || true

echo "==> Done: $APP"

if [[ "$ACTION" == "run" ]]; then
    echo "==> Launching"
    open "$APP"
fi
