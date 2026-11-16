#!/bin/bash
# Headless checks for what the user does while an agent's turn runs: a
# message sent then waits above the box, to be steered into the turn or
# sent when it ends; one piece of the turn's background work is stopped
# on its own; and codex's own /compact and /review — see the header of
# main.swift for the rules.
#
# Compiles the REAL AgentLaunchOptions.swift (the held message, claude's
# input lines and the echo tracker, codex's commands), AgentEventParsing
# .swift (claude's task rule, the tailer and the waiting row's rule),
# AgentSession.swift and CodexSessions.swift (the readers) and
# CodexReviewGit.swift (the review picker's lists, over a throwaway
# repository, with ProbeStub.swift standing in for the app's process
# runner), and reads the composer, the session page and the runner for
# the wiring.
#
# Section 5 runs the installed claude against the ChatOnlyMode stand-in
# endpoint under a throwaway CLAUDE_CONFIG_DIR with a junk key: no token
# is spent, and nothing is written into the user's own stores. Run it
# after a Claude Code upgrade: how claude takes a message written into a
# running turn, and how it stops one task, are claude's to change. The
# codex half runs in ../CodexAppServerBridge (MT).
#
#   ./run.sh                    # everything, token-free
#   ./run.sh <source-root>      # point the source pass at another checkout
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
models="$here/../../SipAI/Models"
swiftc -O -o "$out/midturnharness" \
  "$here/../KimiCode/Stubs.swift" \
  "$here/ProbeStub.swift" \
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
"$out/midturnharness" "${1:-$here/../..}" "$here/../ChatOnlyMode/fake_server.py"
