#!/bin/bash
# Headless check that a turn ANOTHER process runs on a Codex or Kimi
# Code session — a terminal, another app, a turn SipAI orphaned by
# relaunching — is watched the way a Claude Code one is: drawn live, its
# sidebar dot lit while it runs and put out when it ends, a writer killed
# mid-turn noticed, a session opened mid-turn seen as running. See the
# header of main.swift for the passes.
#
# Compiled from the SHIPPING sources, never copied: the tailer
# (AgentSessionTailer.swift, with `ExternalWriterProbe`), the three
# readers, and `StreamEvent` / `StreamEventKind` EXTRACTED from
# AgentRunner.swift, which needs the whole app. Stubs.swift stands in
# for the app types around them.
#
#   ./run.sh                               # all three passes; pass 3
#                                          # drives the REAL codex and
#                                          # kimi over throwaway homes
#                                          # against ../ChatOnlyMode/
#                                          # fake_server.py — token-free —
#                                          # and says SKIP for a CLI that
#                                          # is not installed
#   SIPAI_EXTWATCH_SKIP_LIVE=1 ./run.sh    # passes 1 and 2 only
#
# Run it after a Codex or Kimi Code upgrade: the turn markers, codex's
# thread writer lock and kimi's process are all theirs to change, and a
# failure is silent in the app — a terminal turn that simply never
# lights its dot, or a dot that never goes out.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

runner="$src/SipAI/Models/AgentRunner.swift"
model="$src/SipAI/Models/AgentCLIUpdates.swift"
{
  echo "import Foundation"
  awk '/^struct StreamEvent: /{f=1} f{print} f&&/^\}/{exit}' "$runner"
  awk '/^enum StreamEventKind /{f=1} f{print} f&&/^\}/{exit}' "$runner"
  # The codex catalog the readers' files reach for needs the app-server
  # client — extracted the way Verification/AgentSessionFork does it.
  for decl in "struct CLIVersion" "struct CLIBinaryFingerprint" "enum AgentCLIProbe" \
              "enum CodexAppServerCall" "enum CodexModelListRefresh" \
              "enum CodexConfigWrite" "extension CodexConfigRead"; do
    awk -v pat="^${decl}[ :]" '$0 ~ pat, /^\}/' "$model"
    echo
  done
} > "$out/Extracted.swift"
if ! grep -q "enum StreamEventKind" "$out/Extracted.swift"; then
  echo "could not extract StreamEvent / StreamEventKind from $runner" >&2
  exit 1
fi
if ! grep -q "enum ExternalWriterProbe" "$src/SipAI/Models/AgentSessionTailer.swift"; then
  echo "PRE-FIX: AgentSessionTailer.swift has no ExternalWriterProbe — the"
  echo "  tailer watches Claude Code sessions only, so a Codex or Kimi Code"
  echo "  turn run in a terminal never lights its dot. That is the gap this"
  echo "  harness is for."
  exit 1
fi

if ! swiftc -O -o "$out/extwatch" \
  "$here/Stubs.swift" "$out/Extracted.swift" "$here/main.swift" \
  "$src/SipAI/Models/AttachmentInline.swift" \
  "$src/SipAI/Models/AgentSession.swift" \
  "$src/SipAI/Models/AgentEventParsing.swift" \
  "$src/SipAI/Models/AgentSessionTailer.swift" \
  "$src/SipAI/Models/CodexSessions.swift" \
  "$src/SipAI/Models/CodexEventParsing.swift" \
  "$src/SipAI/Models/KimiSessions.swift" \
  "$src/SipAI/Models/KimiEventParsing.swift" \
  "$src/SipAI/Models/AgentLaunchOptions.swift" \
  "$src/SipAI/Models/KimiToolPolicy.swift" \
  "$src/SipAI/Models/ConfigManager.swift" \
  "$src/SipAI/Models/ProviderCatalog.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi

# The stand-in for a running kimi: a real executable NAMED kimi that
# only waits, which is all the process probe can see of one.
printf '#include <unistd.h>\nint main(void) { for (;;) pause(); }\n' > "$out/standin.c"
cc -O -o "$out/kimi-standin" "$out/standin.c"

SIPAI_EXTWATCH_SERVER="$here/../ChatOnlyMode/fake_server.py" \
SIPAI_EXTWATCH_STANDIN="$out/kimi-standin" \
  "$out/extwatch" "$src/SipAI/Models/AgentSessionTailer.swift"
