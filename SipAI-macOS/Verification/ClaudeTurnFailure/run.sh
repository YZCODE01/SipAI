#!/bin/bash
# Headless check that a Claude Code turn claude itself says FAILED ends
# failed in SipAI — see the header of main.swift for the rule.
#
# Compiles the REAL AgentEventParsing.swift (and what it leans on), so
# this pins the shipped reader rather than a paraphrase of it, and reads
# AgentRunner.swift and ScheduledTaskScheduler.swift for the wiring.
# Section 4 runs the installed claude against the local fake endpoint in
# ../ChatOnlyMode, the stand-in beside this file (too_long_server.py) and
# a port nothing listens on, under a throwaway home and config directory
# with a junk key: no provider is reached and no token is spent. Nothing under ~/.claude or
# ~/Library/Application Support/SipAI is read or written.
#
# Run it after a Claude Code upgrade: the result's fields are claude's
# to rename.
#
#   ./run.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/claudeturnfailureharness" \
  "$here/../KimiCode/Stubs.swift" \
  "$here/../../SipAI/Models/AttachmentInline.swift" \
  "$here/../../SipAI/Models/SkillModel.swift" \
  "$here/../../SipAI/Models/ShellCommands.swift" \
  "$here/../../SipAI/Models/AgentSession.swift" \
  "$here/../../SipAI/Models/AgentSessionTailer.swift" \
  "$here/../../SipAI/Models/AgentEventParsing.swift" \
  "$here/../../SipAI/Models/CodexSessions.swift" \
  "$here/../../SipAI/Models/CodexRecordedTools.swift" \
  "$here/../../SipAI/Models/AgentLaunchOptions.swift" \
  "$here/../../SipAI/Models/KimiSessions.swift" \
  "$here/../../SipAI/Models/KimiEventParsing.swift" \
  "$here/main.swift"
"$out/claudeturnfailureharness" "$here"
