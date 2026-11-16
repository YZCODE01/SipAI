#!/bin/bash
# The skill catalog's reads — headless, the REAL SkillCatalog.swift driven
# the way Settings → Agent Skills drives it, over a throwaway tree and a
# throwaway home.
#
# Pins: a folder's read never looks below it (the walk is asked for on its
# own); a chosen folder's subfolders are read one after another, and only
# while the page asks — a list replaces what was waiting, an empty one
# lets it all go; a write that lands while a subfolder is being read has
# it read again; a folder read directly while it waited is not read
# twice; an older walk never lands on a newer one's; and a skill named on
# a card is looked up in the session's own folder.
#
# No agent tool is started. `AgentManager.binaryPath` answers from a
# table the harness fills, and "codex" there leads to a stand-in for the
# app-server call that records which folder was asked and holds the read
# in flight — after the folder's files have been scanned, which is where
# a real read spends its time. The home folder is the scratch one:
# Foundation honours CFFIXED_USER_HOME (and ignores HOME), so the global
# skills folders the catalog reads are under it, not the user's own.
#
#   ./run.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
m="$src/SipAI/Models"

# The shared model stubs, with the one answer this harness has to steer.
sed 's|nonisolated static func binaryPath(for key: String) -> String? { nil }|nonisolated static func binaryPath(for key: String) -> String? { CatalogHarness.binaries[key] }|' \
  "$here/../KimiCode/Stubs.swift" > "$out/ModelStubs.swift"
grep -q 'CatalogHarness.binaries\[key\]' "$out/ModelStubs.swift" \
  || { echo "FAIL could not steer AgentManager.binaryPath in KimiCode/Stubs.swift"; exit 1; }

if ! swiftc -O -o "$out/catalogharness" \
  "$out/ModelStubs.swift" \
  "$here/Stubs.swift" \
  "$m/AttachmentInline.swift" \
  "$m/SkillModel.swift" \
  "$m/SkillOps.swift" \
  "$m/SkillCatalog.swift" \
  "$m/ShellCommands.swift" \
  "$m/AgentSession.swift" \
  "$m/AgentSessionTailer.swift" \
  "$m/AgentEventParsing.swift" \
  "$m/AgentSessionFork.swift" \
  "$m/CodexSessions.swift" \
  "$m/CodexRecordedTools.swift" \
  "$m/AgentLaunchOptions.swift" \
  "$m/KimiSessions.swift" \
  "$m/KimiEventParsing.swift" \
  "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi
mkdir -p "$out/home"
set +e
CFFIXED_USER_HOME="$out/home" perl -e 'alarm 240; exec @ARGV' "$out/catalogharness" "$out/home"
status=$?
if [ $status -eq 142 ]; then echo "FAIL the harness did not finish inside 240 s"; exit 1; fi
exit $status
