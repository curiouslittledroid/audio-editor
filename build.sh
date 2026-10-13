#!/bin/bash
#
# Builds AudioEditor and wraps the binary in a proper macOS .app bundle.
#
#   ./build.sh                       # release build (default)
#   ./build.sh debug                 # debug build
#   ./build.sh release run           # build then launch
#
# Environment:
#   AUDIOEDIT_VERSION=1.2.0    stamp CFBundleShortVersionString into the bundle
#   AUDIOEDIT_BUILD=42         stamp CFBundleVersion (defaults to the git commit count)
#   AUDIOEDIT_UNIVERSAL=1      build a fat binary for both arm64 and x86_64
#
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/tools/common.sh"

CONFIG="${1:-release}"
ACTION="${2:-}"

cd "$PROJECT_ROOT"

APP="$APP_BUNDLE"

# `"${arr[@]}"` on an empty array trips `set -u` under bash 3.2, so expand guardedly.
ARCH_FLAGS=()
if [[ "${AUDIOEDIT_UNIVERSAL:-0}" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi
expand_archs() { swift "$@" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}; }

echo "==> Building ($CONFIG${ARCH_FLAGS:+ universal})"
expand_archs build -c "$CONFIG"

BIN_PATH="$(expand_archs build -c "$CONFIG" --show-bin-path)/$EXEC_NAME"
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

# MIT requires the licence text to travel with copies of the software, so the
# distributed bundle carries it. Copied before signing, since the signature
# covers the bundle contents.
cp "$PROJECT_ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Stamp versions into the assembled copy only, so the plist in Resources/ stays
# a clean template.
if [[ -n "${AUDIOEDIT_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $AUDIOEDIT_VERSION" \
        "$APP/Contents/Info.plist"
fi
BUILD_NUMBER="${AUDIOEDIT_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# Sign with a Developer ID when one is supplied, otherwise ad-hoc. The hardened
# runtime is required for notarisation, so it is switched on with the identity.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Signing as: $SIGN_IDENTITY"
    if ! codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$APP" 2>/dev/null; then
        echo "error: signing with '$SIGN_IDENTITY' failed. Check the identity with" >&2
        echo "       'security find-identity -v -p codesigning'." >&2
        exit 1
    fi
else
    echo "==> Signing (ad-hoc — downloaders will need to approve the app once)"
    codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
        || echo "    (ad-hoc signing skipped — the app will still run locally)"
fi
codesign --verify --deep --strict "$APP" >/dev/null 2>&1 \
    && echo "    signature verifies" \
    || { echo "    error: signature failed to verify" >&2; exit 1; }

# Nudge Launch Services so the app and its .wav association are picked up.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" >/dev/null 2>&1 || true

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/$EXEC_NAME" 2>/dev/null || echo '?')"
echo "==> Done: $APP  (v$VERSION build $BUILD_NUMBER, $ARCHS)"

if [[ "$ACTION" == "run" ]]; then
    echo "==> Launching"
    open "$APP"
fi