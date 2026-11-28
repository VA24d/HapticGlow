#!/bin/bash
# Build HapticGlow.app with plain swiftc (no Xcode / SwiftPM needed).
#   ./build.sh              release build -> build/HapticGlow.app
#   ./build.sh typecheck    fast type-check of all sources, no output binary
#   ./build.sh debug        unoptimised build with symbols
#   ./build.sh install      release build, then install to /Applications/HapticGlow.app
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
BUILD="$ROOT/build"
APP="$BUILD/HapticGlow.app"
MODE="${1:-release}"
mkdir -p "$BUILD"

# Command Line Tools ship a stale duplicate of the SwiftBridging module map, which breaks every
# Foundation import ("redefinition of module 'SwiftBridging'"). Hide it with a VFS overlay.
# Full Xcode toolchains (CI runners, developer machines) do not have the problem, so the overlay
# is only applied when the active developer directory is the Command Line Tools and the stale
# module map is present. Force it on or off with HAPTICGLOW_VFS_OVERLAY=1 or 0.
CLT_MAP="/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap"
NEED_OVERLAY=0
if [ -n "${HAPTICGLOW_VFS_OVERLAY:-}" ]; then
  NEED_OVERLAY="$HAPTICGLOW_VFS_OVERLAY"
elif [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ] && [ -f "$CLT_MAP" ]; then
  NEED_OVERLAY=1
fi
OVERLAY=()
if [ "$NEED_OVERLAY" = "1" ]; then
  : > "$BUILD/empty.modulemap"
  cat > "$BUILD/overlay.yaml" <<EOF
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "directory",
  "name": "/Library/Developer/CommandLineTools/usr/include/swift",
  "contents": [ { "type": "file", "name": "module.modulemap", "external-contents": "$BUILD/empty.modulemap" } ] } ] }
EOF
  OVERLAY=(-vfsoverlay "$BUILD/overlay.yaml")
fi

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find Sources -name '*.swift' | sort)
COMMON=(-swift-version 5 -target arm64-apple-macos26.0 -parse-as-library
        -module-name HapticGlow)
COMMON+=(${OVERLAY[@]+"${OVERLAY[@]}"})

case "$MODE" in
  typecheck)
    exec swiftc -typecheck "${COMMON[@]}" "${SOURCES[@]}"
    ;;
  debug) OPT=(-Onone -g) ;;
  *)     OPT=(-O -wmo) ;;
esac

echo "› compiling ${#SOURCES[@]} files ($MODE)"
swiftc "${OPT[@]}" "${COMMON[@]}" "${SOURCES[@]}" -o "$BUILD/HapticGlow"

echo "› assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/HapticGlow" "$APP/Contents/MacOS/HapticGlow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
rsync -a --delete --exclude '.DS_Store' Sounds/ "$APP/Contents/Resources/Sounds/"
rsync -a --delete --exclude '.DS_Store' Resources/DefaultWallpapers/ "$APP/Contents/Resources/DefaultWallpapers/"
cp Resources/lockscreen-install.sh "$APP/Contents/Resources/lockscreen-install.sh"
cp LICENSE.md "$APP/Contents/Resources/LICENSE.md"
cp NOTICE.md "$APP/Contents/Resources/NOTICE.md"

# A stable identity keeps the designated requirement (identifier + certificate) the same across
# rebuilds, so macOS privacy grants (System Audio Recording, Input Monitoring) survive. Ad-hoc
# signatures pin grants to the cdhash, which changes on every build and silently revokes them.
SIGN_ID="${HAPTICGLOW_SIGN_ID:-HapticGlow Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  echo "› signing ($SIGN_ID)"
  codesign --force --sign "$SIGN_ID" --options runtime --entitlements Resources/HapticGlow.entitlements --timestamp=none "$APP" >/dev/null
else
  echo "› signing (ad-hoc; permissions reset on every rebuild - see README)"
  codesign --force --sign - --options runtime --entitlements Resources/HapticGlow.entitlements --timestamp=none "$APP" >/dev/null
fi

if [ "$MODE" = "install" ]; then
  DEST="${HAPTICGLOW_INSTALL_DIR:-/Applications}/HapticGlow.app"
  # Quit a running copy so the bundle can be replaced; it restores the backlight on SIGTERM.
  pkill -TERM -f "$DEST/Contents/MacOS/HapticGlow" 2>/dev/null || true
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  # One installed copy only: a second bundle with the same id confuses Launch Services and Spotlight.
  rm -rf "$ROOT/HapticGlow.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true
  echo "› installed $DEST"
fi
echo "✓ $APP"
