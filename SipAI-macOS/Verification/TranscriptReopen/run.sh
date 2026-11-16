#!/bin/bash
# Headless check that coming back to a session while a turn of ours is
# running draws every earlier turn above that turn, each once — and that
# a read of the transcript and the runner's live buffer meet exactly
# everywhere else a read lands ("Show earlier", a session reopened after
# its turn ended, the draft→session flip). See the header of main.swift
# for the three passes.
#
# Compiled from the SHIPPING sources, never copied: the rule
# (Utilities/TranscriptSeam.swift), the three readers, and `StreamEvent`
# / `StreamEventKind` EXTRACTED from AgentRunner.swift, which needs the
# whole app. Stubs.swift stands in for the app types around the readers.
# Nothing is spawned, nothing touches a real session store: every
# transcript is written into a throwaway folder in each CLI's own shape.
#
#   ./run.sh [source-root]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "${1:-$here/../..}" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

if [ ! -f "$src/SipAI/Utilities/TranscriptSeam.swift" ]; then
  echo "PRE-FIX: $src has no SipAI/Utilities/TranscriptSeam.swift — reload()"
  echo "  skips the read whenever nothing from disk is on screen and a turn of"
  echo "  ours is running, so a session opened again mid-turn (after a chat,"
  echo "  a note, Settings, a draft or a task page) shows the running turn and"
  echo "  nothing above it. That is the gap this harness is for."
  exit 1
fi

runner="$src/SipAI/Models/AgentRunner.swift"
{
  echo "import Foundation"
  awk '/^struct StreamEvent: /{f=1} f{print} f&&/^\}/{exit}' "$runner"
  awk '/^enum StreamEventKind /{f=1} f{print} f&&/^\}/{exit}' "$runner"
} > "$out/Extracted.swift"
if ! grep -q "enum StreamEventKind" "$out/Extracted.swift"; then
  echo "could not extract StreamEvent / StreamEventKind from $runner" >&2
  exit 1
fi

if ! swiftc -O -o "$out/reopen" \
  "$here/Stubs.swift" "$out/Extracted.swift" "$here/main.swift" \
  "$src/SipAI/Utilities/TranscriptSeam.swift" \
  "$src/SipAI/Models/AttachmentInline.swift" \
  "$src/SipAI/Models/SkillModel.swift" \
  "$src/SipAI/Models/ShellCommands.swift" \
  "$src/SipAI/Models/AgentSession.swift" \
  "$src/SipAI/Models/AgentEventParsing.swift" \
  "$src/SipAI/Models/AgentSessionTailer.swift" \
  "$src/SipAI/Models/CodexSessions.swift" \
  "$src/SipAI/Models/CodexRecordedTools.swift" \
  "$src/SipAI/Models/AgentLaunchOptions.swift" \
  "$src/SipAI/Models/KimiSessions.swift" \
  "$src/SipAI/Models/KimiEventParsing.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi
"$out/reopen" "$src"
