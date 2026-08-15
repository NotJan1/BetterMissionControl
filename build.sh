#!/bin/bash
#
# Builds BetterMissionControl.app.
#
# SwiftPM only produces a bare executable, but macOS will not hand out
# Accessibility or Screen Recording permission to one — those are granted to a
# signed .app bundle. So this script compiles, assembles the bundle by hand,
# and ad-hoc signs it.
#
#   ./build.sh          debug build, then assemble
#   ./build.sh release  optimised build
#   ./build.sh run      build, assemble, and launch
#
set -euo pipefail

cd "$(dirname "$0")"

MODE="${1:-debug}"
LAUNCH=false
if [ "$MODE" = "run" ]; then
  MODE="debug"
  LAUNCH=true
fi

APP_NAME="BetterMissionControl"
DIST_DIR="dist"
APP="$DIST_DIR/$APP_NAME.app"

echo "==> Compiling ($MODE, arm64)"
swift build -c "$MODE" --arch arm64

BIN_PATH="$(swift build -c "$MODE" --arch arm64 --show-bin-path)/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
  echo "error: expected binary at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. Enough for local use; a Developer ID certificate replaces
# the '-' identity at release time, alongside notarytool.
#
# Note: an ad-hoc signature changes every time the code changes, and macOS ties
# granted permissions to that signature. After a rebuild you may have to
# re-tick the app in System Settings > Privacy & Security.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "==> Built $APP"

if [ "$LAUNCH" = true ]; then
  echo "==> Launching"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  open "$APP"
fi
