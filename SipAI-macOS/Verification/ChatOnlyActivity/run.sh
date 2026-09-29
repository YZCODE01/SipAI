#!/bin/bash
# Headless check of how a Chat only turn is DRAWN: the model's thoughts
# and web lookups on ONE line under the question, naming the newest step
# while the turn runs and settling into a one-line summary — one rule for
# every agent — that opens into the steps.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product. The REAL
# rules are compiled — `Utilities/ChatOnlyActivity.swift`, alone, since
# it is pure — and the wiring around them is checked by READING the
# sources (the view needs a window; the runner needs a child).
#
# What regresses silently here, which is why it is pinned:
#
#  * AGENT TURNS UNCHANGED. Thoughts are kept only when a caller asks,
#    and only a Chat only turn asks: every parser and reader defaults to
#    leaving them out, the runner asks per turn, the tailer never asks.
#    A thought in an agent turn would sit in the transcript's rows
#    invisibly, spending its display window.
#  * THE LINE IS THE WAITING ROW. Same spinner, size, colour and padding,
#    so "Sipping…" turns into the newest step in place, and no agent
#    label above it (the label belongs to the answer).
#  * ONE SUMMARY RULE for all three agents, parts in a fixed order.
#  * FIND counts a thought while its line is closed, and a jump opens
#    the line — the collapsed-chip rule — and never a thought with no
#    line to draw it in.
#  * A TURN KEEPS ITS LOOK: recorded at its `result` as well as at
#    finalize, re-read when the cache predates the record, and kept on
#    its line when the live buffer's front trim cuts its message away.
#
#   ./run.sh                  # this checkout
#   ./run.sh <source-root>    # another checkout
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

rules="$src/SipAI/Utilities/ChatOnlyActivity.swift"
if [ ! -f "$rules" ]; then
  echo "PRE-FIX: $rules is absent — this checkout draws a Chat only turn's"
  echo "  steps as separate rows. That is the failure this harness exists for."
  exit 1
fi

if ! swiftc -O -o "$out/activity" "$here/main.swift" "$rules" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi

SIPAI_ACTIVITY_SRC="$src" "$out/activity"
