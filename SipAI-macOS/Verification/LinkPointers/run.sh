#!/bin/bash
# Headless checks for the pointing hand over links, compiled from the REAL
# DesignSystem.swift (LinkButton, LinkHotspots, `linkPointers`), with the
# views read for the wiring.
#
#   §1  Where a Text's links are, in the units SwiftUI's own layout
#       reports (UTF-16 offsets): ASCII, Chinese and emoji ahead of a
#       link, two links, a link with bold inside it (one span).
#   §2  The regions laid over real Text layouts, offscreen: a click on a
#       link's ink opens that link through the environment's `openURL`
#       (plain, selectable, centred, wrapped onto two lines, after
#       Chinese and emoji, two links side by side, bold inside a link);
#       a click beside it opens nothing; in selectable text the point
#       over a link is SwiftUI's own view (its pointer) and every other
#       point stays the selection field's (its I-beam, its selection).
#       A link the view says is not followed (`linkHotspotBehavior`: a
#       reply's link to a missing file) takes its click and opens nothing,
#       plain or selectable; a followed one with hover text still opens.
#   §3  The shared link button: blue and underlined, grey while disabled.
#   §4  The pointer and the wiring, read from the sources: every link
#       region and link button carries `.pointerStyle(.link)`, no view
#       pushes the hand by hand, and every link in the app is one of the
#       two. Plus a tripwire: SwiftUI's hosting view still puts the arrow
#       back over a hand pushed on hover — why the push is not used. The
#       tripwire points with a made-up pointer, so it goes through the
#       shared gate (../SyntheticHover): the links run with macOS
#       reporting the cursor visible, so that pointer reaches SwiftUI, and a
#       SKIP is left for any other cause.
#
# The pointer itself is drawn only by a real, active window under the
# real mouse; nothing here can show it, so §4 reads it from the source.
#
# Pointed at a tree that predates the change (`./run.sh <source-root>`),
# §1–§3 fail for want of the pieces and §4 says what the old views do.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-$here/../..}"
root="$(cd "$root" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

design="$root/SipAI/Utilities/DesignSystem.swift"
flags=()
grep -q "^enum LinkHotspots" "$design" && flags+=(-D LINK_HOTSPOTS)
grep -q "^struct LinkButton: View" "$design" && flags+=(-D LINK_BUTTON)
grep -q "^struct LinkHotspotBehavior" "$design" && flags+=(-D LINK_HOTSPOT_BEHAVIOR)

swiftc -O -target arm64-apple-macos15.0 "${flags[@]}" -o "$out/links" \
  "$design" "$here/../SyntheticHover/SyntheticHover.swift" "$here/main.swift"

source "$here/../SyntheticHover/cursor_visible.sh"
cursor_preload "$out" || { echo "  FAIL cursor_visibility.c did not build"; exit 1; }
# The links see macOS report the cursor visible, so a made-up pointer reaches
# SwiftUI (../SyntheticHover).
( cursor_visible "$out/links" "$root" )
