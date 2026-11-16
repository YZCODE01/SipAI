#!/bin/bash
# The gate the pointer harnesses share — SyntheticHover.swift, compiled by
# NewSessionSetup, UsageWindow, SkillsPane, SidebarNotices and LinkPointers —
# and the library they run under (cursor_visible.sh, cursor_visibility.c):
# their test programs see macOS report the cursor visible, which is what
# SwiftUI waits for before it honours a made-up pointer. A check of what
# appears under that pointer still goes through the gate: should a plain test
# view get no hover even so, the check prints SKIP and why instead of failing
# (or passing with nothing tested).
#
#   1. The gate with its probe's answer given: hover dead (each check a
#      SKIP, none judged), alive (each judged by the harness's own check),
#      and gone in the middle of a run (the failure a SKIP, and every later
#      check too).
#   2. The real probe: under macOS's answer put to "hidden" it gets no hover
#      and under "visible" it does; it answers within its bound, pointed
#      beside its view it counts no hover, and with
#      SIPAI_SYNTHETIC_HOVER_OFF=1 it answers no and each skip names the
#      switch.
#   3. The five harnesses compile the gate, judge their pointer checks
#      through it, and run their programs with the cursor reported visible;
#      the bounded run names the library inside perl.
# Then a note — not a check — saying what the probe answers under macOS's
# real answer on this Mac now.
#
# SIPAI_SYNTHETIC_HOVER_OFF=1, given to any of the five, shows their skips.
#
#   ./run.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

source "$here/cursor_visible.sh"
if ! swiftc -O -target "$(uname -m)-apple-macos15.0" -o "$out/hover" \
     "$here/SyntheticHover.swift" "$here/main.swift" 2> "$out/build.log"; then
  cat "$out/build.log"
  echo "  FAIL the gate and its checks did not compile"
  exit 1
fi
cursor_preload "$out" || { echo "  FAIL cursor_visibility.c did not build"; exit 1; }
# Bounded: with no window server the probe's window never answers.
cursor_visible_within 60 "$out/hover" "$here/.."
status=$?
if [ $status -eq 142 ] || [ $status -eq 14 ]; then
  echo "  SKIP no window server answered"
  exit 0
fi
exit $status
