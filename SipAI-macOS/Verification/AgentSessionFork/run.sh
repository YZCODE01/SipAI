#!/bin/bash
# Headless check of session branching — the three things in this app
# that WRITE into (or ask for a write into) an agent's private session
# store: `AgentSessionFork` (claude, a prefix transcript), `KimiSessionFork`
# (kimi, a prefix session directory in `kimi fork`'s own shape) and
# `CodexSessionFork` (codex, a `thread/fork` through codex's app-server,
# which writes a REFERENCE rather than a copy — so the codex reader's
# splice of a fork's inherited prefix is checked here too).
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product. The REAL
# scanners and writers are compiled, with stand-ins for the app types
# around them (Stubs.swift), and the app-server client is extracted
# verbatim from the shipping file the way Verification/CodexContextWindow
# does it.
#
# Run it after any change to the three fork files or the two readers,
# and after a Claude Code, Codex or Kimi Code upgrade: `thread/fork` is
# codex's, the `forked` record and the `state.json` keys are kimi's,
# and the claude transcript format is claude's — all somebody else's to
# change, and every failure here is silent in the app (a branch that
# resumes with the wrong history looks exactly like one that resumed
# with the right one).
#
#   ./run.sh                     # pure rules + token-free live checks
#                                # (the real codex and kimi over
#                                # throwaway stores; SKIP without them)
#   ./run.sh <session.jsonl>     # + fork a COPY of a real claude
#                                # transcript end to end
#   SIPAI_FORK_LIVE=1 ./run.sh   # + two real turns (a few tokens each):
#                                # `codex exec resume` on a branch, and
#                                # kimi answering from a hand-written
#                                # prefix. The kimi one runs in your
#                                # REAL store (credentials live there)
#                                # and prints the branch id to delete.
#
# Give the claude pass a COPY, never a session you care about. The fork
# never modifies its source (there is a check for exactly that), but
# the branch it writes lands in the same directory.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

model="$src/SipAI/Models/AgentCLIUpdates.swift"

# The app-server client, EXTRACTED VERBATIM from the shipping file — a
# harness holding its own copy of the client passes for the wrong
# reason. A top-level `}` in column 1 closes each declaration.
{
  echo "import Foundation"
  for decl in "struct CLIVersion" "struct CLIBinaryFingerprint" "enum AgentCLIProbe" \
              "enum CodexAppServerCall" "enum CodexModelListRefresh" \
              "enum CodexConfigWrite" "extension CodexConfigRead"; do
    awk -v pat="^${decl}[ :]" '$0 ~ pat, /^\}/' "$model"
    echo
  done
} > "$out/Extracted.swift"

for required in "enum CodexAppServerCall" "static func run(binary:"; do
  if ! grep -q "$required" "$out/Extracted.swift"; then
    echo "PRE-FIX: '$required' is not in $model — this checkout has no"
    echo "  app-server client, so codex cannot be asked to fork."
    exit 1
  fi
done

for required in "SipAI/Models/CodexSessionFork.swift" "SipAI/Models/KimiSessionFork.swift"; do
  if [ ! -f "$src/$required" ]; then
    echo "PRE-FIX: $required is absent — this checkout branches claude"
    echo "  sessions only. That is the failure this harness is for."
    exit 1
  fi
done

if ! swiftc -O -o "$out/forkharness" \
  "$here/Stubs.swift" "$out/Extracted.swift" "$here/main.swift" \
  "$src/SipAI/Models/AttachmentInline.swift" \
  "$src/SipAI/Models/AgentSession.swift" \
  "$src/SipAI/Models/AgentEventParsing.swift" \
  "$src/SipAI/Models/AgentSessionFork.swift" \
  "$src/SipAI/Models/CodexSessions.swift" \
  "$src/SipAI/Models/CodexEventParsing.swift" \
  "$src/SipAI/Models/CodexSessionFork.swift" \
  "$src/SipAI/Models/KimiSessions.swift" \
  "$src/SipAI/Models/KimiEventParsing.swift" \
  "$src/SipAI/Models/KimiSessionFork.swift" \
  "$src/SipAI/Models/AgentLaunchOptions.swift" \
  "$src/SipAI/Models/KimiToolPolicy.swift" \
  "$src/SipAI/Models/ConfigManager.swift" \
  "$src/SipAI/Models/ProviderCatalog.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi

SIPAI_FORK_SRC="$src" SIPAI_FORK_FIXTURES="$here/fixtures" \
  "$out/forkharness" "$@"
