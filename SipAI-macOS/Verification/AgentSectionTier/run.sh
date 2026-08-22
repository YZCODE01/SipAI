#!/bin/bash
# Headless check that an agent's sidebar section describes itself
# honestly — see the header of main.swift for the rule and the bug it
# was written for.
#
# The tier enum is EXTRACTED VERBATIM from the shipping
# AgentSessionGrouping.swift rather than restated here: a harness
# holding its own copy of the rule under test passes for the wrong
# reason. Everything it needs is Foundation, so nothing else compiles.
#
# The second pass READS the two views that consume it. An explicit
# source root points that pass at another checkout — against 1.0.0 it
# fails, which is what makes the checks worth having.
#
# Run it after touching the section header, the not-installed / read-only
# rows, or the list of sections LeftSidebar builds.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

grouping="$here/../../SipAI/Models/AgentSessionGrouping.swift"
awk '/^enum AgentSectionTier \{/,/^\}/' "$grouping" > "$out/AgentSectionTier.swift"
if ! grep -q "static func resolve" "$out/AgentSectionTier.swift"; then
  echo "  FAIL  AgentSectionTier not found in $grouping"
  echo "        (the rule the header, the body and the grouping menu"
  echo "         share does not exist — nothing keeps them in step)"
  exit 1
fi

swiftc -O -o "$out/tierharness" \
  "$out/AgentSectionTier.swift" "$here/main.swift"
"$out/tierharness" "${1:-$here/../..}"
