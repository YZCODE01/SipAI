#!/bin/bash
# Headless check that SipAI reads a session the way its own CLI replays
# it after a rewind — an earlier message edited in place:
#
#   Claude Code  Esc Esc / /rewind, and `-p --resume-session-at`: the
#                next message is parented at the entry above the edit,
#                and the replaced turns stay in the file as a branch.
#   Codex        Esc Esc / `thread/revert`: the thread goes on in a NEW
#                rollout whose `history_base` names the kept prefix.
#   Kimi Code    `/undo` / its server's `:undo`: a `context.undo {count}`
#                record (with `agent.switched` and `context.undone`).
#
# What a wrong reader shows is the dropped turns still on screen — and,
# for codex, the turns sent after the revert missing — with nothing saying
# so. A branch made from such a session must carry only the kept line.
#
# Nothing here is part of the app target. The REAL readers and branch
# writers are compiled with the stand-ins the AgentSessionFork harness
# uses for the same files, and the app-server client is extracted from
# the shipping source.
#
#   ./run.sh                               # rules over synthetic stores,
#                                          # then the real CLIs (token-free)
#   SIPAI_REWIND_SRC=<checkout> ./run.sh   # the same against another
#                                          # checkout's readers
#
# Section 1–3 builds stores in each CLI's measured shape. Sections 4–6
# drive the installed claude, codex and kimi against local stand-in
# endpoints under throwaway homes (no provider, no token), and SKIP a CLI
# that is missing or does not name the call. Run it after a Claude Code,
# Codex or Kimi Code upgrade: the flag, the segment format and the undo
# records are each tool's to change.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${SIPAI_REWIND_SRC:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

model="$src/SipAI/Models/AgentCLIUpdates.swift"
{
  echo "import Foundation"
  for decl in "struct CLIVersion" "struct CLIBinaryFingerprint" "enum AgentCLIProbe" \
              "enum CodexAppServerCall" "enum CodexModelListRefresh" \
              "enum CodexConfigWrite" "extension CodexConfigRead"; do
    awk -v pat="^${decl}[ :]" '$0 ~ pat, /^\}/' "$model"
    echo
  done
} > "$out/Extracted.swift"

if ! swiftc -O -o "$out/rewind" \
  "$here/../AgentSessionFork/Stubs.swift" "$out/Extracted.swift" "$here/main.swift" \
  "$src/SipAI/Models/AttachmentInline.swift" \
  "$src/SipAI/Models/SkillModel.swift" \
  "$src/SipAI/Models/ShellCommands.swift" \
  "$src/SipAI/Models/AgentSession.swift" \
  "$src/SipAI/Models/AgentEventParsing.swift" \
  "$src/SipAI/Models/AgentSessionFork.swift" \
  "$src/SipAI/Models/CodexSessions.swift" \
  "$src/SipAI/Models/CodexRecordedTools.swift" \
  "$src/SipAI/Models/CodexEventParsing.swift" \
  "$src/SipAI/Models/CodexSessionFork.swift" \
  "$src/SipAI/Models/KimiSessions.swift" \
  "$src/SipAI/Models/KimiEventParsing.swift" \
  "$src/SipAI/Models/KimiSessionFork.swift" \
  "$src/SipAI/Models/AgentSessionRewind.swift" \
  "$src/SipAI/Models/AgentLaunchOptions.swift" \
  "$src/SipAI/Models/KimiToolPolicy.swift" \
  "$src/SipAI/Models/ConfigManager.swift" \
  "$src/SipAI/Models/ProviderCatalog.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi

# The listing and the kimi branch read Foundation's home and kimi's home:
# both point at a throwaway, never at the real stores.
home="$out/session-rewind-home"
mkdir -p "$home/.kimi-code/sessions"
status=0
CFFIXED_USER_HOME="$home" KIMI_CODE_HOME="$home/.kimi-code" "$out/rewind" rules || status=1
echo
"$out/rewind" wiring "$src" || status=1
python3 -I "$here/live.py" "$out/rewind" "$out/live" || status=1
if [ $status -eq 0 ]; then echo; echo "SessionRewind: all passed"; else echo; echo "SessionRewind: FAILED"; fi
exit $status
