#!/bin/bash
#
# Rebuilds Resources/AppIcon.icns from Resources/AppIcon.png.
#
# The master PNG is 1024x1024 with a transparent surround and the artwork drawn
# at Apple's standard 824pt body size, so every size here is a straight
# downscale. Run this after replacing the master.
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER="Resources/AppIcon.png"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" "$MASTER" --out "$SET/icon_$2.png" >/dev/null
done

iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$SET")"
echo "==> Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
