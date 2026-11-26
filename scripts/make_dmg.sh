#!/bin/bash
# Package build/HapticGlow.app into a compressed disk image.
#   scripts/make_dmg.sh [APP_PATH] [OUT_DMG]
# Defaults: build/HapticGlow.app -> build/HapticGlow-<version>.dmg
# The image holds the app, a symlink to /Applications, LICENSE.md and NOTICE.md.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/HapticGlow.app}"
[ -d "$APP" ] || { echo "app bundle not found: $APP" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT="${2:-build/HapticGlow-$VERSION.dmg}"
VOLNAME="HapticGlow $VERSION"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/HapticGlow.app"
ln -s /Applications "$STAGE/Applications"
cp LICENSE.md "$STAGE/LICENSE.md"
cp NOTICE.md "$STAGE/NOTICE.md"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
echo "$OUT ($(du -h "$OUT" | cut -f1))"
