#!/bin/bash
# Compile the REAL kimi readers against fixtures and run them.
#
# This is the half of Kimi Code support that can be checked with no
# `kimi` on the machine: given records of the shape Moonshot documents,
# do the parser and the scanner produce the rows the transcript expects,
# and are this app's known traps closed (JSON null read as absent,
# request traces not replayed, cwd never silently $HOME).
#
# It cannot tell you the fixtures match reality. `./run.sh` against a
# real binary is what does that — run this after editing the readers,
# and that after installing kimi.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/ and the Xcode project never references it.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/kimiharness" \
  "$here/Stubs.swift" \
  "$here/../../SipAI/Models/AgentSession.swift" \
  "$here/../../SipAI/Models/AgentSessionTailer.swift" \
  "$here/../../SipAI/Models/AgentEventParsing.swift" \
  "$here/../../SipAI/Models/CodexSessions.swift" \
  "$here/../../SipAI/Models/AgentLaunchOptions.swift" \
  "$here/../../SipAI/Models/KimiSessions.swift" \
  "$here/../../SipAI/Models/KimiEventParsing.swift" \
  "$here/main.swift"
"$out/kimiharness" "$@"
