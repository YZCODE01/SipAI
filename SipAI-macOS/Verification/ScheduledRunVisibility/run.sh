#!/bin/bash
# Headless check that a SCHEDULED run stays visible in every agent's
# scanner — see the header of main.swift for the rule and the bug it
# was written for.
#
# Builds throwaway kimi and codex stores under ~/Library/Caches (NOT
# $TMPDIR — that is itself a scratch root, which would make every
# fixture look like a probe) and asks the real scanners what they
# return. Removes them again on the way out.
#
# Run it after touching any scanner's session filter, and after adding
# a fourth agent — this is the rule a new store is most likely to miss,
# because the wrong version looks right and fails silently.
#
#   ./run.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/schedvisharness" \
  "$here/../KimiCode/Stubs.swift" \
  "$here/../../SipAI/Models/AgentSession.swift" \
  "$here/../../SipAI/Models/AgentSessionTailer.swift" \
  "$here/../../SipAI/Models/AgentEventParsing.swift" \
  "$here/../../SipAI/Models/CodexSessions.swift" \
  "$here/../../SipAI/Models/AgentLaunchOptions.swift" \
  "$here/../../SipAI/Models/KimiSessions.swift" \
  "$here/../../SipAI/Models/KimiEventParsing.swift" \
  "$here/main.swift"
"$out/schedvisharness" "$@"
