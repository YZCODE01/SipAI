#!/bin/bash
# Headless check of the history-widen path — the machinery behind
# "Show earlier" reaching a long session's FIRST message.
#
# Two halves, and both regress silently:
#
#  * Behavioural — the REAL `AgentSessionScanner.readHistory` against
#    synthetic transcripts that trip each bound (the 50-turn cap, the
#    8 MB byte budget), proving a widened read reaches turn 1 where
#    the default read cannot. If the bounds move, these move with
#    them: the fixtures are sized off `historyByteBudget` itself.
#
#  * Structural — the view wiring in `AgentSessionView.swift` that no
#    harness can instantiate: the widen applies `trimmedForInFlight`,
#    never writes `AgentHistoryCache`, the button offers past the
#    loaded rows (`historyHasMore`), the ladder exists, and the
#    ceiling states its truncation instead of going silent.
#
# Nothing here is part of the app target.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/historywiden" \
  "$here/Stubs.swift" "$here/main.swift" \
  "$src/SipAI/Models/AgentSession.swift"
"$out/historywiden" "$src/SipAI/Views/Chat/AgentSessionView.swift"
