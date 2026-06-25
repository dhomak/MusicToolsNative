#!/bin/bash
# Self-contained, arm64-only MusicTools.app — bundles ffmpeg only. No Node, no Python, no Perl.
#   ./scripts/build_dist.sh /path/to/your/music-tools
set -euo pipefail
APP_NAME="MusicTools"
REPO="${1:?Usage: build_dist.sh /path/to/your/music-tools}"
ICON_SRC="${ICON_SRC:-/Users/aalien/sandbox/split-cue/build/icon.icns}"
DEV_ID="${DEV_ID:-}"
VARCH=arm64
SCRIPTS=(flac_downsampler.sh)
[ "$(uname -m)" = arm64 ] || echo "warning: host isn't arm64" >&2

# Locate the scripts up front and fail fast.
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

WORK="$(pwd)/build"; APP="$WORK/$APP_NAME.app"; RES="$APP/Contents/Resources"; VENDOR="$RES/vendor"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$RES/scripts" "$VENDOR/bin/$VARCH"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"; cp Info.plist "$APP/Contents/Info.plist"
[ -f "$ICON_SRC" ] && cp "$ICON_SRC" "$RES/AppIcon.icns" || echo "warning: no icon"
for s in "${SCRIPTS[@]}"; do cp "$SRC/$s" "$RES/scripts/$s"; done

echo "==> static arm64 ffmpeg + ffprobe"
FFT="$WORK/fftmp"; rm -rf "$FFT"; mkdir -p "$FFT"
( cd "$FFT" && npm init -y >/dev/null 2>&1 && npm i ffmpeg-ffprobe-static --no-save --no-audit --no-fund >/dev/null 2>&1 )
for t in ffmpeg ffprobe; do
  f="$(find "$FFT/node_modules/ffmpeg-ffprobe-static" -maxdepth 2 -type f -name "$t" 2>/dev/null | head -1 || true)"
  [ -n "$f" ] && { cp "$f" "$VENDOR/bin/$VARCH/$t"; chmod +x "$VENDOR/bin/$VARCH/$t"; } \
    || echo "  !! $t not fetched — drop an arm64 static build into $VENDOR/bin/$VARCH/"
done

if [ -n "$DEV_ID" ]; then
  echo "==> signing (Developer ID, hardened runtime)"
  find "$RES" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0 \
    | while IFS= read -r -d '' f; do codesign --force --timestamp --options runtime --sign "$DEV_ID" "$f" 2>/dev/null || true; done
  codesign --force --deep --timestamp --options runtime --entitlements MusicTools.entitlements --sign "$DEV_ID" "$APP"
else
  echo "==> ad-hoc signing"; codesign --force --deep --sign - "$APP"
fi
du -sh "$APP"; echo "Built $APP  (arm64, self-contained — ffmpeg only, no Node/Python/Perl)"
