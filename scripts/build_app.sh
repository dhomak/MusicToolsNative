#!/bin/bash
# Beta build of the pure-Swift MusicTools.app (uses system ffmpeg; no Python/Perl).
#   ./scripts/build_app.sh /path/to/your/music-tools
set -euo pipefail
APP_NAME="MusicTools"
REPO="${1:?Usage: build_app.sh /path/to/your/music-tools (dir holding the scripts)}"
ICON_SRC="${ICON_SRC:-/Users/aalien/sandbox/split-cue/build/icon.icns}"
SCRIPTS=(flac_downsampler.sh)

# Locate the scripts up front (repo root or a scripts/ subdir) and fail fast.
SRC=""
for cand in "$REPO" "$REPO/scripts"; do
  [ -f "$cand/flac_downsampler.sh" ] && { SRC="$cand"; break; }
done
if [ -z "$SRC" ]; then
  echo "error: scripts not found under '$REPO' (looked in ./ and ./scripts/)." >&2
  echo "       Point this at the directory that contains: ${SCRIPTS[*]}" >&2
  exit 1
fi
missing=(); for s in "${SCRIPTS[@]}"; do [ -f "$SRC/$s" ] || missing+=("$s"); done
if [ ${#missing[@]} -gt 0 ]; then
  echo "error: these scripts are missing from '$SRC': ${missing[*]}" >&2
  exit 1
fi
echo "==> scripts: $SRC"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
APP="build/$APP_NAME.app"; RES="$APP/Contents/Resources"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$RES/scripts"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP/Contents/Info.plist"
[ -f "$ICON_SRC" ] && cp "$ICON_SRC" "$RES/AppIcon.icns" || echo "warning: no icon at $ICON_SRC"
for s in "${SCRIPTS[@]}"; do cp "$SRC/$s" "$RES/scripts/$s"; done
codesign --force --deep --sign - "$APP"
echo "Built $APP (beta: system ffmpeg)"
echo "Run: open \"$APP\"  (first launch: right-click -> Open)"
