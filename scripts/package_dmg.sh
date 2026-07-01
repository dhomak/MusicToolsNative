#!/bin/bash
# Packages build/MusicTools.app into a distributable DMG (drag-to-Applications).
#
#   ./scripts/package_dmg.sh
#
# Optional:
#   DEV_ID="Developer ID Application: Name (TEAMID)"   -> signs the DMG
#   NOTARY_PROFILE=musictools-profile                  -> notarizes + staples
#
# Run after build_dist.sh (or build_app.sh), on macOS.
set -euo pipefail

APP_NAME="MusicTools"
VOL_NAME="Music Tools"
WORK="$(pwd)/build"
APP="$WORK/$APP_NAME.app"
DMG="$WORK/$APP_NAME.dmg"
DEV_ID="${DEV_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

[ -d "$APP" ] || { echo "error: $APP not found — run build_dist.sh first" >&2; exit 1; }

# Stage: the app + an /Applications symlink so users drag-install.
STAGE="$WORK/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> creating DMG"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "$DEV_ID" ]; then
  echo "==> signing DMG"
  codesign --force --sign "$DEV_ID" "$DMG"
fi

if [ -n "$NOTARY_PROFILE" ]; then
  echo "==> notarizing DMG (a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo ""
ls -lh "$DMG"
echo "Built $DMG"
