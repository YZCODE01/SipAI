#!/bin/bash
# Verification/SidebarBrandLockup/run.sh
#
# Pins the logo renditions and the one alignment they carry.
#
# Everything here fails SILENTLY — a wrong rendition still draws, still
# swaps with the appearance, and still builds:
#
#   * Transparent margin under the cup lifts the glass off the wordmark's
#     baseline. `.lastTextBaseline` aligns the text to the image's BOTTOM
#     EDGE, so the crop IS the alignment; the previous renditions carried
#     2-3 pt down there and the mark floated for the app's whole life.
#   * An @2x that is not exactly twice its @1x lays the lockup out
#     differently on a Retina display than on a 1x one — and the machine
#     that renders the asset usually only has one of the two. The
#     previous 67 pt pair was 45x67 against 89x134.
#   * A light/dark pair that disagrees on size shifts the mark sideways
#     when the appearance changes.
#   * An opaque background plate reads as a tight crop, because there is
#     no transparency left to measure.
#
# Run after: re-rendering the logo, changing a rendition's height, or
# touching the brand header's alignment or insets in LeftSidebar.
#
# Offline and non-destructive: it reads the asset catalog and builds the
# app into its normal DerivedData.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"          # SipAI-macOS
ASSETS="$ROOT/SipAI/Resources/Assets.xcassets"

echo "== SidebarBrandLockup verification =="
echo

# ---------------------------------------------------------------- 1
echo "1. Rendition geometry (read off the PNGs)"
swift "$HERE/geometry.swift" \
    "$ASSETS/SipAI-Logo-54.imageset" \
    "$ASSETS/SipAI-Logo-67.imageset" \
    "$ASSETS/SipAI-Logo-86.imageset"
GEOM=$?
echo

# ---------------------------------------------------------------- 2
# The layout half needs the COMPILED catalog: `Image("SipAI-Logo-54")`
# reads Assets.car, and actool is what turns four PNGs and a
# Contents.json into the appearance-keyed entries the app looks up. A
# check against the source PNGs would not notice a Contents.json that
# never names the dark files.
echo "2. The lockup's alignment (real SwiftUI layout, real Assets.car)"

APP="$(xcodebuild -project "$ROOT/SipAI.xcodeproj" -scheme SipAI -configuration Debug \
        -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')/SipAI.app"

if [ ! -d "$APP" ]; then
    echo "  building SipAI (Debug) — no product at $APP"
    if ! xcodebuild -project "$ROOT/SipAI.xcodeproj" -scheme SipAI \
            -configuration Debug build >/dev/null 2>&1; then
        echo "  FAIL  the build failed; run xcodebuild by hand to see why"
        exit 1
    fi
fi

swift "$HERE/probe.swift" "$APP"
PROBE=$?
echo

if [ "$GEOM" -eq 0 ] && [ "$PROBE" -eq 0 ]; then
    echo "SidebarBrandLockup: OK"
    exit 0
fi
echo "SidebarBrandLockup: FAILED"
exit 1
