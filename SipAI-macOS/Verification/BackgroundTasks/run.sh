#!/bin/bash
# Headless checks for the work an agent leaves running in the background:
# Claude Code's background tasks are allowed only where claude reports
# them, and a SipAI turn stays open until claude has reported every task;
# Kimi Code's tasks and Codex's background terminals are named while the
# turn waits on them; a finished or stopped one reads the same live and on
# reopen — see the header of main.swift for the rules.
#
# Compiles the REAL AgentLaunchOptions.swift (the gate), AgentEventParsing
# .swift (claude's turn rule, the line), CodexEventParsing.swift (codex's),
# AgentSession.swift, KimiSessions.swift and CodexSessions.swift (the
# readers), with the readers' stubs, so it pins the shipped code rather
# than a paraphrase of it.
#
# Section 6 runs the installed claude against the ChatOnlyMode stand-in
# endpoint under a throwaway CLAUDE_CONFIG_DIR, and 6b the installed kimi
# and codex under throwaway homes: no token is spent, and nothing is
# written into the user's own stores. It takes about a minute. Run it
# after a Claude Code, Kimi Code or Codex upgrade: whether a headless run
# waits for a background task, and the records each keeps of one, are the
# CLIs' to change.
#
# Section 7 spends one real claude turn and is opt-in:
#
#   ./run.sh                    # everything token-free
#   SIPAI_BG_LIVE=1 ./run.sh    # plus one real claude turn
#   ./run.sh <source-root>      # point the source pass at another checkout
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
models="$here/../../SipAI/Models"
swiftc -O -o "$out/bgharness" \
  "$here/../KimiCode/Stubs.swift" \
  "$models/AttachmentInline.swift" \
  "$models/SkillModel.swift" \
  "$models/ShellCommands.swift" \
  "$models/AgentSession.swift" \
  "$models/AgentSessionTailer.swift" \
  "$models/AgentEventParsing.swift" \
  "$models/CodexEventParsing.swift" \
  "$models/CodexSessions.swift" \
  "$models/CodexRecordedTools.swift" \
  "$models/AgentLaunchOptions.swift" \
  "$models/KimiSessions.swift" \
  "$models/KimiEventParsing.swift" \
  "$here/main.swift"
"$out/bgharness" "${1:-$here/../..}" "$here/../ChatOnlyMode/fake_server.py"
