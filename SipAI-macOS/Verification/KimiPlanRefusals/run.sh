#!/bin/bash
# Headless check of the Kimi model menu's plan marks: a model Moonshot
# refuses for the plan is marked on its row, for that account, and the
# mark goes when the model answers a turn.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product.
#
# What regresses silently here, which is why it is pinned:
#
#  * MOONSHOT'S ANSWER. A plan that lacks a model is answered 403 "Your
#    current subscription does not have access to <id>." and kimi keeps
#    it, verbatim, in the session's own record (`turn.ended reason:
#    failed`, `error.code provider.auth_error`, `details.statusCode` 403),
#    with each `llm.request` of the turn naming the model and the alias it
#    ran under. Read wrong, the menu never says why every message fails —
#    or marks a model that merely lost its connection.
#  * THE ACCOUNT. A mark is the account's: another kind of sign-in shows
#    none, and the mark goes the next time the model answers (plans
#    change, so the row stays pickable).
#  * THE WIRING. The runner reads the record when a kimi turn ends; the
#    composer's chip and the task card share one menu; Factory reset
#    forgets the marks; every sentence has a zh-Hans value.
#
# Section 3 runs the INSTALLED kimi under a throwaway home against two
# local stand-ins — Moonshot's 403 (refusal.py) and ChatOnlyMode's
# fake_server.py, which completes a turn — and reads the record kimi
# itself wrote. Token-free: nothing reaches Moonshot, nothing of the
# user's is touched, kimi's self-update and telemetry are off for the run.
#
#   ./run.sh                     # this checkout
#   ./run.sh <source-root>       # another checkout
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

sessions="$src/SipAI/Models/KimiSessions.swift"
refusals="$src/SipAI/Models/KimiPlanRefusals.swift"
if [ ! -f "$refusals" ]; then
  echo "PRE-FIX: $refusals does not exist — the menu learns nothing from Moonshot's refusals."
  exit 1
fi

# kimi's turn markers are spelled once (KimiSessionScanner); the three the
# reader uses are EXTRACTED VERBATIM, never copied.
{
  echo "import Foundation"
  echo "enum KimiSessionScanner {"
  for fn in "static func turnPromptId(_ obj: [String: Any]) -> String? {" \
            "static func turnEnded(_ obj: [String: Any]) -> Bool {" \
            "static func failedTurnReason(_ obj: [String: Any]) -> String? {"; do
    # A literal match: the signature's ( ) ? [ ] are not a pattern.
    awk -v sig="    ${fn}" 'index($0, sig) == 1 {inside=1} inside {print} inside && /^    \}$/ {exit}' "$sessions"
    echo
  done
  echo "}"
} > "$out/Extracted.swift"
for required in "func turnPromptId" "func turnEnded" "func failedTurnReason"; do
  if ! grep -q "$required" "$out/Extracted.swift"; then
    echo "  FAIL  '$required' did not extract (the marker under test is not the one shipping)"
    exit 1
  fi
done

if ! swiftc -O -o "$out/refusals" "$out/Extracted.swift" "$refusals" "$here/main.swift" \
  2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi
"$out/refusals" "$src" "$here"
