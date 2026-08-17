#!/bin/bash
# Headless check that a local slash command's ANSWER survives the round
# trip through the transcript — see the header of main.swift for the
# rule and the bug it was written for.
#
# Compiles the REAL AgentSession.swift and AgentEventParsing.swift, so
# this pins the shipped readers rather than a paraphrase of them. The
# fixtures are record shapes captured from real `claude -p` runs.
#
# Section 3 needs the real session root: `inspectSession` is private and
# only reachable through `scan()`, which reads ~/.claude/projects. It
# writes ONE uniquely-named throwaway project directory in there and
# removes it again on the way out. Nothing existing is touched.
#
# Run it after a Claude Code upgrade, and after touching anything that
# decides what a transcript record renders as: it is the cheapest way to
# find out that the record carrying a command's answer has moved.
#
#   ./run.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/slashcmdharness" \
  "$here/../KimiCode/Stubs.swift" \
  "$here/../../SipAI/Models/AgentSession.swift" \
  "$here/../../SipAI/Models/AgentSessionTailer.swift" \
  "$here/../../SipAI/Models/AgentEventParsing.swift" \
  "$here/../../SipAI/Models/CodexSessions.swift" \
  "$here/../../SipAI/Models/AgentLaunchOptions.swift" \
  "$here/../../SipAI/Models/KimiSessions.swift" \
  "$here/../../SipAI/Models/KimiEventParsing.swift" \
  "$here/main.swift"
"$out/slashcmdharness" "$@"
