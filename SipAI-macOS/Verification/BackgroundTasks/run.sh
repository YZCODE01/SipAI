#!/bin/bash
# Headless check that a backgrounded task can no longer be silently
# discarded by a SipAI-driven `claude -p` turn — see the header of
# main.swift for the rule and the measurements behind it.
#
# `ClaudePrintMode` is EXTRACTED VERBATIM from the shipping
# AgentLaunchOptions.swift rather than restated here: a harness holding
# its own copy of the rule under test passes for the wrong reason. It
# needs nothing but Foundation, so nothing else compiles.
#
# Section 4 is the one that matters over time. The whole fix rests on
# one undocumented environment variable read out of claude's bundled
# binary; if a future Claude Code drops or renames it, background tasks
# return and fail exactly as silently as before. Run this after a Claude
# Code upgrade.
#
# Section 5 spends tokens on a real turn and is opt-in:
#
#   ./run.sh                    # structural + binary checks, free
#   SIPAI_BG_LIVE=1 ./run.sh    # plus one real claude turn
#   ./run.sh <source-root>      # point the source pass at another checkout
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

opts="$here/../../SipAI/Models/AgentLaunchOptions.swift"
awk '/^enum ClaudePrintMode \{/,/^\}/' "$opts" > "$out/ClaudePrintMode.swift"
if ! grep -q "static func environmentOverlay" "$out/ClaudePrintMode.swift"; then
  echo "  FAIL  ClaudePrintMode not found in $opts"
  echo "        (nothing keeps a claude child from reaching for a"
  echo "         background task that will be killed 5 s later)"
  exit 1
fi

swiftc -O -o "$out/bgharness" \
  "$out/ClaudePrintMode.swift" "$here/main.swift"
"$out/bgharness" "${1:-$here/../..}"
