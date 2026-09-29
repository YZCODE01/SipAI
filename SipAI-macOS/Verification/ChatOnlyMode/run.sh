#!/bin/bash
# Headless check of the composer's "Chat only" mode — a persona-swapped
# turn inside an agent session whose only tools look things up on the
# web, for all three agents.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product. The REAL
# rules are compiled — `ChatOnlyArgv`, `ChatOnlyPersona`,
# `ChatOnlyAvailability` extracted verbatim from AgentLaunchOptions.swift,
# `KimiToolPolicy`, `KimiWebTurn`, `AttachmentInline`, the three
# transcript readers, and `KimiWebServerCall` out of PlanUsage.swift —
# with stand-ins for the app types around them (Stubs.swift).
#
# What regresses silently here, which is why it is pinned:
#
#  * The ARGV. Three claude flags are variadic and swallow the `--resume`
#    id if anything but a flag follows them; the web tools must be
#    PRE-APPROVED, since the turn carries no approver (a scripted call
#    runs with the pair and is refused without it); codex takes an unknown
#    `-c` key SILENTLY, so a switch renamed upstream leaves the tools
#    on under a chip that says otherwise; the codex persona must never
#    ride a thread's FIRST turn (the birth rule).
#  * The KIMI FILE DANCE. `tool-policy/state.json` is honoured by
#    `--prompt`, outlives kimi's server, and must be restored; a Chat
#    only turn records a snapshot of its kept web tools alone, so the
#    name source is the newest ORDINARY turn's; the server refuses `disabled_tools`
#    without `profile` + `model`, and refuses `--prompt` on a session it
#    created until its first prompt.
#  * The GATES. The row is offered only where the installed CLI names
#    the switches; a saved pick below the gate is ignored.
#  * The READERS. An inlined attachment block is stripped from every
#    user row on reopen and its names ride the paperclip line — on all
#    three readers, matched as a pair. A codex web search row reads the
#    same live and on reopen (the rollout keeps only its `action`).
#
# The CLI sections drive the REAL binaries against a FAKE local endpoint
# (fake_server.py: Anthropic Messages, OpenAI Responses, OpenAI chat
# completions — records every request, answers "OK") under throwaway
# homes. Token-free; SKIP for a CLI that is not installed. Every failure
# names the file to edit.
#
#   ./run.sh                        # this checkout
#   ./run.sh <source-root>          # another checkout
#   SIPAI_CHATONLY_LIVE=1 ./run.sh  # + one real Chat only turn, one
#                                   #   Default turn and one web lookup
#                                   #   per agent (tokens)
#   SIPAI_CHATONLY_LIVE_THOUGHTS=1 ./run.sh
#                                   # + one real Chat only web lookup per
#                                   #   agent, checking the model's
#                                   #   thoughts come back readable and
#                                   #   group into one line (tokens)
#
# Run it after any agent CLI upgrade: three of the four traps here are
# somebody else's to move.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

launch="$src/SipAI/Models/AgentLaunchOptions.swift"
updates="$src/SipAI/Models/AgentCLIUpdates.swift"

# ---- PRE-FIX: the feature must exist before anything can be checked.
for required in "enum ChatOnlyArgv" "enum ChatOnlyPersona" "enum ChatOnlyAvailability" \
                "enum ChatOnlyMode" "var chatOnly: Bool"; do
  if ! grep -q "$required" "$launch"; then
    echo "PRE-FIX: '$required' is not in $launch —"
    echo "  this checkout has no Chat only mode. That is the failure this"
    echo "  harness exists for."
    exit 1
  fi
done
for required in Models/KimiToolPolicy.swift Models/KimiWebTurn.swift \
                Models/AttachmentInline.swift Models/PlanUsage.swift; do
  if [ ! -f "$src/SipAI/$required" ]; then
    echo "PRE-FIX: $required is absent — this checkout has no Chat only mode."
    exit 1
  fi
done

# The app-server client and the probe runner, EXTRACTED VERBATIM from
# the shipping file — a harness holding its own copy passes for the
# wrong reason. A top-level `}` in column 1 closes each declaration.
{
  echo "import Foundation"
  for decl in "struct CLIVersion" "struct CLIBinaryFingerprint" "enum AgentCLIProbe" \
              "enum CodexAppServerCall" "enum CodexModelListRefresh" \
              "enum CodexConfigWrite" "extension CodexConfigRead"; do
    awk -v pat="^${decl}[ :]" '$0 ~ pat, /^\}/' "$updates"
    echo
  done
} > "$out/Extracted.swift"

for required in "enum CodexAppServerCall" "enum AgentCLIProbe"; do
  if ! grep -q "$required" "$out/Extracted.swift"; then
    echo "PRE-FIX: '$required' is not in $updates."
    exit 1
  fi
done

if ! swiftc -O -o "$out/chatonly" \
  "$here/Stubs.swift" "$out/Extracted.swift" "$here/main.swift" \
  "$src/SipAI/Models/AgentLaunchOptions.swift" \
  "$src/SipAI/Models/ConfigManager.swift" \
  "$src/SipAI/Models/ProviderCatalog.swift" \
  "$src/SipAI/Models/AttachmentInline.swift" \
  "$src/SipAI/Models/KimiToolPolicy.swift" \
  "$src/SipAI/Models/KimiWebTurn.swift" \
  "$src/SipAI/Models/PlanUsage.swift" \
  "$src/SipAI/Models/AgentSession.swift" \
  "$src/SipAI/Models/AgentEventParsing.swift" \
  "$src/SipAI/Models/CodexSessions.swift" \
  "$src/SipAI/Models/CodexEventParsing.swift" \
  "$src/SipAI/Models/KimiSessions.swift" \
  "$src/SipAI/Models/KimiEventParsing.swift" \
  "$src/SipAI/Utilities/ChatOnlyActivity.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi

SIPAI_CHATONLY_SRC="$src" SIPAI_CHATONLY_FIXTURES="$here/fixtures" \
SIPAI_CHATONLY_SERVER="$here/fake_server.py" \
  "$out/chatonly"
