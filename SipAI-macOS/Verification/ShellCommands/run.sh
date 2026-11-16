#!/bin/bash
# Headless checks for a `!` command — the user's own shell command, run in
# SipAI as each agent's terminal runs one (see the header of main.swift).
#
# Compiles the REAL ShellCommands.swift (the rules), the three readers
# (AgentSession.swift, CodexSessions.swift, KimiSessions.swift, with the
# live parser and the tailer) and AgentLaunchOptions.swift, and reads the
# runner, the codex driver, the composer and the session page for the
# wiring.
#
# Sections 3 and 4 run the installed claude and codex against the
# ChatOnlyMode stand-in endpoint, under a throwaway CLAUDE_CONFIG_DIR /
# CODEX_HOME with a junk key: no token is spent, nothing is written into
# the user's own stores, and nothing reaches a provider. A missing CLI is
# reported as SKIP. Run it after a Claude Code or Codex upgrade: claude's
# `bash_command` message and the rows its terminal writes, and codex's
# `thread/shellCommand` and its record, are each CLI's to change.
#
#   ./run.sh                    # everything, token-free
#   ./run.sh <source-root>      # point the source pass at another checkout
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
models="$here/../../SipAI/Models"
swiftc -O -o "$out/shellharness" \
  "$here/../KimiCode/Stubs.swift" \
  "$here/../MidTurnMessages/ProbeStub.swift" \
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
  "$models/CodexReviewGit.swift" \
  "$here/main.swift"
"$out/shellharness" "${1:-$here/../..}" "$here/../ChatOnlyMode/fake_server.py"
