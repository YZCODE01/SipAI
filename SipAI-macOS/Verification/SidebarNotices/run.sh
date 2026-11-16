#!/bin/bash
# Headless check of the bubble beside the sidebar's logo — see the header
# of main.swift for what it pins and why.
#
# Compiles the REAL SidebarNotices.swift, UpdateNotices.swift,
# SidebarBrandLockup.swift and DesignSystem.swift (never copied), plus
# the bubble's colour extracted from MarkdownRenderer.swift, and renders
# the real lockup with the real logo rendition read straight off the
# asset catalog's PNGs. Stubs.swift stands in for the one app type the
# colour's enum names. The last pass READS the shipping sources for the
# wiring a headless run cannot reach. The fill under a made-up pointer goes
# through the shared gate (../SyntheticHover): the lockup runs with macOS
# reporting the cursor visible, so that pointer reaches SwiftUI, and a SKIP is
# left for any other cause.
#
# Offline, and touches nothing outside a temp folder: the driver's
# preferences go to a suite named by an absolute temp path.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

app="$root/SipAI"
for f in "$app/Models/SidebarNotices.swift" "$app/Views/Sidebar/SidebarBrandLockup.swift"; do
  if [ ! -f "$f" ]; then
    echo "PRE-FIX: $f is missing — the notices beside the logo are a one-line"
    echo "  update message in the wordmark's place: no bubble, no update on offer"
    echo "  with an Update button, nothing when a card waits or a turn ends."
    exit 1
  fi
done

# The bubble's fill is the running turn clock's colour, which lives in the
# renderer's style enum; the enum alone, closed by a column-1 brace.
{
  echo "import SwiftUI"
  echo "import AppKit"
  awk '/^enum ChatMarkdownStyle/,/^\}/' "$app/Utilities/MarkdownRenderer.swift"
} > "$out/ChatMarkdownStyle.swift"
if ! grep -q "static let inlineCode" "$out/ChatMarkdownStyle.swift"; then
  echo "  FAIL  ChatMarkdownStyle.inlineCode did not extract from MarkdownRenderer.swift"
  exit 1
fi

if ! swiftc -O -target arm64-apple-macos15.0 -o "$out/notices" \
  "$here/Stubs.swift" \
  "$out/ChatMarkdownStyle.swift" \
  "$app/Utilities/DesignSystem.swift" \
  "$app/Models/UpdateNotices.swift" \
  "$app/Models/SidebarNotices.swift" \
  "$app/Views/Sidebar/SidebarBrandLockup.swift" \
  "$here/../SyntheticHover/SyntheticHover.swift" \
  "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log"
  exit 1
fi

source "$here/../SyntheticHover/cursor_visible.sh"
cursor_preload "$out" || { echo "  FAIL cursor_visibility.c did not build"; exit 1; }
# The lockup sees macOS report the cursor visible, so a made-up pointer
# reaches SwiftUI (../SyntheticHover).
set +e
cursor_visible_within 180 "$out/notices" "$root"
status=$?
set -e
if [ $status -eq 142 ] || [ $status -eq 14 ]; then
  echo "  FAIL  the harness did not finish in 180 s"
  exit 1
fi
exit $status
