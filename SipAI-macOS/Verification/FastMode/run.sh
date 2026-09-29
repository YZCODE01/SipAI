#!/bin/bash
# Headless check of fast mode and codex's speed — which models take it,
# what a turn actually gets, and that the composer's words match the
# wire. See the header of main.swift for the rules.
#
# Compiles the REAL AgentLaunchOptions.swift, AgentEventParsing.swift and
# AgentSession.swift, so this pins the shipped rules and readers rather
# than a paraphrase of them. Sections 6 and 7 run the installed claude
# and codex against the local fake endpoint in ../ChatOnlyMode, each
# under a throwaway home and config directory with a junk key: no
# provider is reached and no token is spent. Nothing under ~/.claude,
# ~/.codex or ~/Library/Application Support/SipAI is read or written.
#
# Run it after a Claude Code or Codex upgrade, and after touching the
# fast switch, the speed section, or anything that reads a call's usage.
#
#   ./run.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/fastmodeharness" \
  "$here/../KimiCode/Stubs.swift" \
  "$here/../../SipAI/Models/AttachmentInline.swift" \
  "$here/../../SipAI/Models/AgentSession.swift" \
  "$here/../../SipAI/Models/AgentSessionTailer.swift" \
  "$here/../../SipAI/Models/AgentEventParsing.swift" \
  "$here/../../SipAI/Models/CodexSessions.swift" \
  "$here/../../SipAI/Models/AgentLaunchOptions.swift" \
  "$here/../../SipAI/Models/KimiSessions.swift" \
  "$here/../../SipAI/Models/KimiEventParsing.swift" \
  "$here/main.swift"
"$out/fastmodeharness" "$here"
