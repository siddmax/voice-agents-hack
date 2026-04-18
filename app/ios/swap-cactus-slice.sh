#!/bin/bash
# Swap ios/Frameworks/cactus.framework between simulator and device slices
# of the upstream cactus.xcframework. Required because Flutter's BUILD_DIR
# override breaks the CocoaPods xcframework slice resolver — see DEMO.md
# "Vendoring note" for the long story.
#
# Usage: ./ios/swap-cactus-slice.sh sim     # arm64 simulator slice
#        ./ios/swap-cactus-slice.sh device  # arm64 iphoneos slice
set -euo pipefail

cd "$(dirname "$0")"

XCF="Frameworks/cactus.xcframework"
DEST="Frameworks/cactus.framework"

case "${1:-}" in
  sim)    SRC="$XCF/ios-arm64-simulator/cactus.framework" ;;
  device) SRC="$XCF/ios-arm64/cactus.framework" ;;
  *) echo "usage: $0 {sim|device}" >&2; exit 1 ;;
esac

[ -d "$SRC" ] || { echo "ERROR: $SRC not found. Run cactus/flutter/build.sh first." >&2; exit 1; }

rm -rf "$DEST"
cp -R "$SRC" "$DEST"
echo "Swapped to $1 slice."
