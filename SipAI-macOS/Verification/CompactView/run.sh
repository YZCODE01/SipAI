#!/bin/bash
# Headless checks for Compact view's three switches — the toolbar's agent
# session view window, Settings → Display → Agent sessions, and View →
# Agent Session Compact View (⌃⌘O) — which move ONE setting,
# `display.agent_compact_view`.
#
#   §1  The REAL window (TranscriptViewWindow.swift, compiled with the
#       real DesignSystem.swift) laid out offscreen at every size: its
#       width follows the size and stops at its cap, its wrapped line is
#       never clipped, and it grows with the tier's line spacing.
#       `COMPACT_VIEW_RENDER=<dir>` writes a PNG per size.
#   §2  The REAL View menu item under SwiftUI's App lifecycle: it shows
#       ⌃⌘O, and the key turns the setting on and off through the menu.
#       That a press flips the value in force even where the item still
#       draws the other one (SwiftUI does not redraw a background app's
#       menu on every change) is read off the source in §3: a stale item
#       cannot be made on demand.
#   §3  The wiring, read off the sources: the button between the
#       magnifier and the plan-usage T, drawn whenever an agent is listed;
#       its window under it over a scrim; one dropdown at a time; the
#       card keys stand down while it is up; Escape closes it; the menu
#       item and its shortcut; the Display switch; the config key; the
#       Help answer.
#   §4  Every new string has its zh-Hans value in the String Catalog.
#
# How a transcript is DRAWN compact — the line, the name once per answer,
# thoughts — is `Verification/ChatOnlyActivity`'s; the Claude thinking
# request is `Verification/ChatOnlyMode`'s.
#
# Pointed at a tree that predates the feature (`./run.sh <source-root>`)
# it says PRE-FIX.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-$here/../..}"
root="$(cd "$root" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

window="$root/SipAI/Views/TranscriptViewWindow.swift"
if [ ! -f "$window" ]; then
  echo "PRE-FIX: $window is absent — this checkout has no Compact view."
  exit 1
fi

if ! swiftc -O -target arm64-apple-macos15.0 -o "$out/compactview" \
  "$root/SipAI/Utilities/DesignSystem.swift" "$window" \
  "$here/Checks.swift" "$here/ProbeApp.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi

# One app process (SwiftUI builds the View menu only under its App
# lifecycle), which needs a window server; bounded, and a timeout reads as
# SKIP.
set +e
perl -e 'alarm 120; exec @ARGV' "$out/compactview" "$root"
status=$?
set -e
if [ $status -eq 142 ] || [ $status -eq 14 ]; then
  echo ""
  echo "SKIP — the probe app timed out reaching the window server (no GUI"
  echo "       session?). Rerun in a logged-in session."
  exit 0
fi
exit $status
