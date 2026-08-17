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

# Sign with the local self-signed identity if it exists, falling back to
# ad-hoc.
#
# This matters more than it looks. An ad-hoc signature has no stable identity,
# and macOS ties granted permissions to the exact code hash — so every rebuild
# looks like a brand new app and Screen Recording and Accessibility are quietly
# denied, while their switches stay on in System Settings. A real certificate
# gives the app a fixed identity and the grants survive rebuilds.
#
# Run ./scripts/create-signing-identity.sh once to set it up. A Developer ID
# certificate replaces it for release builds, alongside notarytool.
IDENTITY="Better Mission Control Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "==> Signing as '$IDENTITY'"
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null 2>&1
else
  echo "==> Signing (ad-hoc)"
  echo "    Tip: run ./scripts/create-signing-identity.sh once and macOS will"
  echo "    stop asking for permissions again after every rebuild."
  codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
fi

echo "==> Built $APP"

if [ "$LAUNCH" = true ]; then
  echo "==> Launching"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  open "$APP"
fi
