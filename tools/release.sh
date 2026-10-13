#!/bin/bash
#
# Packages a distributable build and (optionally) publishes it as a GitHub
# release.
#
#   ./tools/release.sh 1.0.0              # build + package + verify, no network
#   ./tools/release.sh 1.0.0 --draft      # also create a DRAFT release for review
#   ./tools/release.sh 1.0.0 --publish    # create and publish the release
#
# Artifacts land in dist/release/:
#   AudioEditor-<version>-macos-universal.zip   (ditto archive, drag to /Applications)
#   AudioEditor-<version>-macos-universal.dmg   (drag-to-Applications disk image)
#   SHA256SUMS.txt
#
# NOTE ON GATEKEEPER: the app is ad-hoc signed, because there is no Developer ID
# certificate on this machine. Anyone who downloads it sees "Apple cannot check
# 'Audio Editor' for malicious software" and must approve it once via
# System Settings > Privacy & Security > Open Anyway. See README.md. Supplying
# SIGN_IDENTITY (and notarising) removes that friction entirely.
#
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

VERSION="${1:-}"
MODE="${2:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "usage: release.sh <version> [--draft|--publish]" >&2
    echo "   eg: release.sh 1.0.0" >&2
    exit 2
fi

TAG="v$VERSION"
OUT="$PROJECT_ROOT/dist/release"
STAGE_NAME="Audio Editor.app"
ZIP_NAME="AudioEditor-$VERSION-macos-universal.zip"
DMG_NAME="AudioEditor-$VERSION-macos-universal.dmg"

cd "$PROJECT_ROOT"

# ---------------------------------------------------------------- preflight
# Only tracked modifications matter; untracked scratch files are ignored.
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    if [[ "${AUDIOEDIT_RELEASE_ALLOW_DIRTY:-0}" == "1" ]]; then
        echo "warning: releasing with uncommitted changes (AUDIOEDIT_RELEASE_ALLOW_DIRTY=1)" >&2
    elif [[ -t 0 ]]; then
        echo "warning: you have uncommitted changes." >&2
        echo "         The release should point at a commit others can reproduce." >&2
        read -r -p "         Continue anyway? [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]] || exit 1
    else
        echo "error: uncommitted changes." >&2
        echo "       Commit first, or set AUDIOEDIT_RELEASE_ALLOW_DIRTY=1 to override." >&2
        exit 1
    fi
fi

COMMIT="$(git rev-parse HEAD)"
echo "==> Releasing $TAG from $COMMIT"

# ------------------------------------------------------------------- build
echo
echo "==> Building universal release"
AUDIOEDIT_VERSION="$VERSION" AUDIOEDIT_UNIVERSAL=1 "$PROJECT_ROOT/build.sh" release

APP="$APP_BUNDLE"

# ----------------------------------------------------------------- verify
echo
echo "==> Verifying the bundle"
FAILED=0
check() { if eval "$2"; then echo "    ok    $1"; else echo "    FAIL  $1"; FAILED=1; fi; }

check "signature verifies"        "codesign --verify --deep --strict '$APP' >/dev/null 2>&1"
check "contains arm64"            "lipo -archs '$APP/Contents/MacOS/$EXEC_NAME' | grep -q arm64"
check "contains x86_64"           "lipo -archs '$APP/Contents/MacOS/$EXEC_NAME' | grep -q x86_64"
check "bundle version is $VERSION" "[[ \"\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '$APP/Contents/Info.plist')\" == '$VERSION' ]]"
check "declares .wav handling"    "/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:CFBundleTypeExtensions:0' '$APP/Contents/Info.plist' | grep -q wav"
check "launches"                  "AUDIOEDIT_SNAPSHOT=/tmp/release-smoke.png AUDIOEDIT_SETTLE=1 '$APP/Contents/MacOS/$EXEC_NAME' >/dev/null 2>&1 && [[ -s /tmp/release-smoke.png ]]"
echo "    (smoke test rendered /tmp/release-smoke.png)"

[[ $FAILED -eq 0 ]] || { echo "error: verification failed" >&2; exit 1; }

# --------------------------------------------------------------- package
echo
echo "==> Packaging"
rm -rf "$OUT"
mkdir -p "$OUT"

# ditto is Apple's recommended archiver for bundles: it preserves the code
# signature, symlinks and extended attributes that `zip` can drop.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP_NAME"
echo "    $ZIP_NAME"

# A disk image with an /Applications symlink gives the familiar drag-to-install.
DMG_STAGE="$(mktemp -d)"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -quiet -volname "Audio Editor" -srcfolder "$DMG_STAGE" \
    -ov -format UDZO "$OUT/$DMG_NAME"
rm -rf "$DMG_STAGE"
echo "    $DMG_NAME"

# Checksums so downloaders can verify what they got.
( cd "$OUT" && shasum -a 256 "$ZIP_NAME" "$DMG_NAME" > SHA256SUMS.txt )
echo "    SHA256SUMS.txt"

echo
echo "==> Artifacts in dist/release/"
ls -lh "$OUT" | tail -n +2 | awk '{printf "    %-8s %s\n", $5, $NF}'

# ---------------------------------------------------------- release notes
NOTES="$(mktemp)"
cat > "$NOTES" <<NOTES_EOF
Native macOS audio trimmer. Open a \`.wav\`, see its waveform, play it, drag the
in/out handles to trim, and export the kept region to a new \`.wav\`.

Universal binary: Apple Silicon and Intel. Requires macOS 15 or later.

### Install

1. Download \`$DMG_NAME\` (or the \`.zip\`) and open it.
2. Drag **Audio Editor** into your Applications folder.
3. **First launch — macOS will block it.** The app is not notarised by Apple, so
   macOS says it *"cannot check Audio Editor for malicious software"*. To allow it:
   - Open **System Settings → Privacy & Security**, scroll down and click
     **Open Anyway**, then confirm with **Open**.
   - This is a one-off; the app opens normally afterwards.

   If you would rather not trust it, you can build it yourself from source in
   about ten seconds: \`./build.sh release run\`.

### Verify your download

\`\`\`
shasum -a 256 -c SHA256SUMS.txt
\`\`\`

Checksums are also in \`SHA256SUMS.txt\` on this release.
NOTES_EOF

echo
echo "==> Release notes written to $NOTES"

# --------------------------------------------------------------- publish
case "$MODE" in
    --publish) FLAGS="" ;;
    --draft)   FLAGS="--draft" ;;
    "") 
        echo
        echo "Nothing published (no --draft/--publish given). To publish:"
        echo "  gh release create $TAG --target $COMMIT --title \"Audio Editor $VERSION\" \\"
        echo "      --notes-file $NOTES \\"
        echo "      \"$OUT/$ZIP_NAME\" \"$OUT/$DMG_NAME\" \"$OUT/SHA256SUMS.txt\""
        exit 0
        ;;
    *) echo "error: unknown mode '$MODE' (use --draft or --publish)" >&2; exit 2 ;;
esac

if ! command -v gh >/dev/null 2>&1; then
    echo "error: the GitHub CLI (gh) is required to publish. Install it, or upload" >&2
    echo "       the files in $OUT by hand." >&2
    exit 1
fi

echo
echo "==> Creating GitHub release $TAG${FLAGS:+ ($MODE)}"
gh release create "$TAG" \
    --target "$COMMIT" \
    --title "Audio Editor $VERSION" \
    --notes-file "$NOTES" \
    ${FLAGS:+$FLAGS} \
    "$OUT/$ZIP_NAME" "$OUT/$DMG_NAME" "$OUT/SHA256SUMS.txt"

echo
echo "==> Done: $(gh release view "$TAG" --json url --jq .url 2>/dev/null || echo "$TAG")"