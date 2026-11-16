#!/bin/bash
# UnknownAgent — an agent SipAI has no code for is refused, never run as
# Claude Code.
#
# Every switch that dispatches on an agent names each agent it serves, and
# an agent none of them names gets a fail-closed answer: no turn spawned
# (an error row says so), no transcript read, no branch, no Send in place,
# no skills folder, Default alone on the chips with no effort and no speed,
# and words that name no other agent's store. A default arm that answered
# with Claude Code's path instead would run the agent's turn with claude's
# flags and claude's parser, fork its transcript as claude JSONL and link
# its skills into claude's folder — silently, since nothing fails.
#
# Section 1 compiles the REAL pure rules (the turn driver, the flags, the
# asking modes, Chat only, slash commands, `!` routes, claude's child
# environment, rewind, the branch writers, rename, the skills folders and
# switches, the release table and the install routes) and asks each about a
# key no agent has, and about the three agents, whose answers must not
# move. Section 2 reads the sources: a switch over an agent that names
# Codex or Kimi Code names Claude Code too; no "not Codex and not Kimi"
# test stands for Claude Code; no parameter defaults to claude's key; and
# the few places that keep claude's key on purpose are the ones its list
# names, each with its reason (`scan.py`).
#
# Token-free: no CLI is run, nothing is written outside a temp folder.
#   SIPAI_UNKNOWN_AGENT_SRC=<SipAI-macOS folder>   check another checkout
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${SIPAI_UNKNOWN_AGENT_SRC:-$here/../..}"
m="$src/SipAI/Models"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

echo "UnknownAgent — $src"

# The release table and the version types from AgentCLIUpdates.swift, the
# install routes from AgentGuide.swift: each pulled out whole (a top-level
# `}` in column 1 closes a declaration).
{
  echo "import Foundation"
  for decl in "struct CLIVersion" "struct CLIBinaryFingerprint" "enum AgentCLIProbe" \
              "enum CodexAppServerCall" "enum CodexModelListRefresh" \
              "enum CodexConfigWrite" "extension CodexConfigRead" "struct AgentCLIRelease"; do
    awk -v pat="^${decl}[ :]" '$0 ~ pat, /^\}/' "$m/AgentCLIUpdates.swift"
    echo
  done
  for decl in "enum AgentInstallRoute" "enum KimiSite" "enum AgentSignIn"; do
    awk -v pat="^${decl}[ :]" '$0 ~ pat, /^\}/' "$m/AgentGuide.swift"
    echo
  done
} > "$out/Extracted.swift"
for required in "static func measured(agentKey: String)" "static func route(agentKey: String)"; do
  if ! grep -q "$required" "$out/Extracted.swift"; then
    echo "  FAIL  '$required' did not extract (the rule under test is not the one shipping)"
    exit 1
  fi
done

echo
echo "1. The rules, asked about a key no agent has"
if ! swiftc -O -o "$out/unknownagent" \
  "$here/../AgentSessionFork/Stubs.swift" "$out/Extracted.swift" "$here/main.swift" \
  "$m/AttachmentInline.swift" \
  "$m/SkillModel.swift" \
  "$m/ShellCommands.swift" \
  "$m/AgentSession.swift" \
  "$m/AgentEventParsing.swift" \
  "$m/AgentSessionFork.swift" \
  "$m/AgentSessionRename.swift" \
  "$m/CodexSessions.swift" \
  "$m/CodexRecordedTools.swift" \
  "$m/CodexEventParsing.swift" \
  "$m/CodexSessionFork.swift" \
  "$m/KimiSessions.swift" \
  "$m/KimiEventParsing.swift" \
  "$m/KimiSessionFork.swift" \
  "$m/AgentSessionRewind.swift" \
  "$m/AgentLaunchOptions.swift" \
  "$m/KimiToolPolicy.swift" \
  "$m/ConfigManager.swift" \
  "$m/ProviderCatalog.swift" 2>"$out/build.log"; then
  sed -n '1,40p' "$out/build.log" >&2
  echo "  FAIL  the rules did not compile against these sources"
  section1=1
else
  section1=0
  "$out/unknownagent" || section1=1
fi

echo
echo "2. The sources, read"
section2=0
python3 -I "$here/scan.py" "$src/SipAI" || section2=1

echo
if [ "$section1" = 0 ] && [ "$section2" = 0 ]; then
  echo "UnknownAgent: PASS"
else
  echo "UnknownAgent: FAIL"
  exit 1
fi
