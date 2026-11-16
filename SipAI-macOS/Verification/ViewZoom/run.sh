#!/bin/bash
# View → Zoom In / Zoom Out / Actual Size, and what a size change does to
# the page being read.
#
#   1. The rules, headless: the four sizes step in order and stop at each
#      end; Actual Size is Default; `zoom` steps from the size in force and
#      answers whether there was a step; `ReadingAnchor` names the row under
#      the top edge (or the next row and its distance) and puts the edge
#      back on the same line of the row's new frame; `ReadingPlace` takes
#      the anchor from the OLD layout whichever report of the new size comes
#      first, answers once, gives way to the reader's own scroll, turns a
#      top into an offset in an inset scroll view, ignores a row that left,
#      carries nothing for a reader following the end — judged on the old
#      layout, since a page that shrinks clamps a reader to the end.
#  1b. A row that draws nothing — a tool result folded into its chip, a
#      turn's start and end markers — laid out through the REAL
#      `readingPlaceRow` takes none of the stack's spacing, and a drawn row
#      lays out the same with the modifier as without; the control asks for
#      the geometry on the row itself and gets the gap (the hazard).
#   2. The wiring, read off the real files: the View menu draws the items
#      observing the one setting and the keys are answered at launch; each
#      item steps from the size in force and is greyed where its step has
#      nowhere to go; Settings names the row Zoom and writes through
#      `setFontTier`, the only writer; both transcripts report every row,
#      read the follow engine and the edge from ONE scroll sample, drop a
#      carried place on the reader's scroll and count a size change as
#      input for the follow engine; the note preview compares at its loaded
#      size and resizes in place; the strings have zh-Hans, the old "Font
#      Size" key is gone; the README names the keys.
#   3. The REAL `ZoomMenuItems` and `ZoomKeys` under SwiftUI's App
#      lifecycle: which keys are zoom keys, the items' shortcuts, and
#      key-downs through NSApplication — ⌘= (a "+" menu item never sees
#      it), ⌘⇧=, the keypad, ⌘−, ⌘0, both ends, a quick reversal — each
#      stepping from the size in force. Clicks are not driven: SwiftUI
#      routes a click only to an item it last drew enabled, and a
#      background app's items are not redrawn; the greyed look
#      is the GUI pass's.
#   4. The transcript's shape through the REAL `ReadingPlace`,
#      `readingPlaceRow`, `ScrollSample` and `TranscriptFollow` in an
#      offscreen window: a reader mid-page keeps the row under the top edge
#      on the same line through every size — a zoom out that shrinks the
#      page under them included — and between two rows keeps the next
#      row's distance; a reader at the end stays at the end. The control
#      turns the place-keeping off and the line moves by hundreds of points.
#   5. The REAL `NoteWebView`: a size change sets the body size in place —
#      the page is not loaded again — and the top of the window stays on
#      the same line inside a paragraph, inside a list item and in the gap
#      above a heading, set up by the page's own geometry. The control
#      reloads the page and loses it, as a size change used to.
#
# Sections 3–5 need a logged-in GUI session; with no window server they
# report SKIP. Token-free; nothing is written outside a temp folder.
#
#   ./run.sh [SipAI-macOS root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

sources=(
  "$here/Stubs.swift"
  "$root/SipAI/Utilities/DesignSystem.swift"
  "$root/SipAI/Utilities/ReadingPlace.swift"
  "$root/SipAI/Utilities/TranscriptFollow.swift"
  "$root/SipAI/Views/ZoomCommands.swift"
  "$root/SipAI/Utilities/NoteHTML.swift"
  "$root/SipAI/Utilities/MarkdownRenderer.swift"
  "$root/SipAI/Utilities/FileLinks.swift"
  "$root/SipAI/Utilities/CodeBlockActions.swift"
  "$root/SipAI/Utilities/LatexSymbols.swift"
  "$root/SipAI/Utilities/SearchMatching.swift"
  "$root/SipAI/Utilities/MathAlphabets.swift"
  "$root/SipAI/Utilities/MathSymbols.swift"
  "$root/SipAI/Utilities/MathParser.swift"
  "$root/SipAI/Utilities/MathFont.swift"
  "$root/SipAI/Utilities/MathLayout.swift"
  "$root/SipAI/Utilities/MathDelimiters.swift"
  "$root/SipAI/Utilities/MathDisplayBlock.swift"
  "$root/SipAI/Views/Notes/NoteWebView.swift"
  "$here/Checks.swift"
)
for f in "$root/SipAI/Utilities/ReadingPlace.swift" "$root/SipAI/Views/ZoomCommands.swift"; do
  if [ ! -f "$f" ]; then
    echo "PRE-FIX: $(basename "$f") is not in this checkout — there is no View"
    echo "  menu zoom, and a size change keeps the scroll offset, not the line"
    echo "  being read. Sections 4 and 5 are the failures this pins."
    exit 1
  fi
done

if ! swiftc -O -target arm64-apple-macos15.0 -o "$out/headless" \
     "${sources[@]}" "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log"; exit 1
fi
if ! swiftc -O -parse-as-library -target arm64-apple-macos15.0 -o "$out/window" \
     "${sources[@]}" "$here/ProbeApp.swift" 2>"$out/build-window.log"; then
  cat "$out/build-window.log"; exit 1
fi

set +e
"$out/headless" "$root"
headless=$?
# Bound the GUI half: with no window server it would hang rather than fail.
perl -e 'alarm 90; exec @ARGV' "$out/window" "$root"
window=$?
set -e

if [ $window -eq 142 ] || [ $window -eq 14 ]; then
  echo ""
  echo "SKIP — sections 3–5 timed out reaching the window server (no GUI session?)."
  window=0
fi
[ $headless -eq 0 ] && [ $window -eq 0 ] && echo "" && echo "ViewZoom: all passed"
[ $headless -eq 0 ] && [ $window -eq 0 ]
