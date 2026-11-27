#!/bin/bash
# HapticGlow: copy prepared lock-screen (Aerial) files into the system catalog. Run as root, once per action.
#   lockscreen-install.sh install|remove <stage dir> <allowed temp prefix>
# The app builds <stage dir> in its own private temp folder: <UUID>.mov, <UUID>.jpg, entries.json and,
# for "remove", remove.txt (one UUID per line, the entries to delete). Nothing else is read or written.
set -euo pipefail

MODE="${1:-}"; STAGE="${2:-}"; PREFIX="${3:-}"
BASE="/Library/Application Support/com.apple.idleassetsd/Customer"
UUID_RE='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'

die() { echo "HapticGlow: $*" >&2; exit 1; }

[ "$MODE" = install ] || [ "$MODE" = remove ] || die "mode must be install or remove"
[ -d "$BASE" ] || die "catalog folder not found: $BASE"

# The stage folder must be a real directory (no symlink) inside the app's temp folder, named by the app.
[ -d "$STAGE" ] && [ ! -L "$STAGE" ] || die "stage is not a directory"
STAGE_REAL="$(cd "$STAGE" && pwd -P)"
PREFIX_REAL="$(cd "$PREFIX" && pwd -P)"
case "$STAGE_REAL" in "$PREFIX_REAL"/HapticGlowLock-*) ;; *) die "stage is outside the app temp folder" ;; esac

# Only these file names are accepted, and none may be a symlink.
for f in "$STAGE_REAL"/*; do
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then continue; fi
  n="$(basename "$f")"
  if [ -L "$f" ]; then die "symlink in stage: $n"; fi
  case "$n" in
    entries.json|remove.txt) ;;
    *.mov|*.jpg) [[ "${n%.*}" =~ $UUID_RE ]] || die "bad file name: $n" ;;
    *) die "unexpected file: $n" ;;
  esac
done
[ -f "$STAGE_REAL/entries.json" ] || die "entries.json missing in stage"
/usr/bin/plutil -extract assets raw -o /dev/null "$STAGE_REAL/entries.json" 2>/dev/null || die "entries.json is not valid JSON"

mkdir -p "$BASE/4KSDR240FPS" "$BASE/snapshots"

# Keep the original catalog before the first change.
if [ -f "$BASE/entries.json" ] && ! ls "$BASE"/entries.json.hapticglow-backup-* >/dev/null 2>&1; then
  cp -p "$BASE/entries.json" "$BASE/entries.json.hapticglow-backup-$(date +%Y%m%d-%H%M%S)"
fi

if [ "$MODE" = install ]; then
  for f in "$STAGE_REAL"/*.mov; do
    if [ -f "$f" ]; then install -m 644 "$f" "$BASE/4KSDR240FPS/$(basename "$f")"; fi
  done
  for f in "$STAGE_REAL"/*.jpg; do
    if [ -f "$f" ]; then install -m 644 "$f" "$BASE/snapshots/$(basename "$f")"; fi
  done
else
  [ -f "$STAGE_REAL/remove.txt" ] || die "remove.txt missing in stage"
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    [[ "$id" =~ $UUID_RE ]] || die "bad id in remove.txt"
    rm -f "$BASE/4KSDR240FPS/$id.mov" "$BASE/snapshots/$id.jpg"
  done < "$STAGE_REAL/remove.txt"
fi

install -m 644 "$STAGE_REAL/entries.json" "$BASE/entries.json.new"
mv -f "$BASE/entries.json.new" "$BASE/entries.json"

# Make the wallpaper agents read the catalog again (launchd restarts both).
killall WallpaperAgent 2>/dev/null || true
killall idleassetsd 2>/dev/null || true
echo "ok"
