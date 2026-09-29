#!/bin/bash
# Headless check that a CLI stays on screen while SipAI updates it, and
# that the update which lands is said where it can be seen — see the
# header of main.swift for the two failures this was written for.
#
# The update monitor is EXTRACTED WHOLE from the shipping
# AgentCLIUpdates.swift (the class and the pure types it uses), and the
# badge / announcer file is compiled whole, so the replay drives the real
# rows, the real re-stat and the real announcer. Stubs.swift stands in
# for the app types the monitor reaches for; none of them carries a rule.
#
# Draws nothing and touches no network: the release endpoint is served
# in-process, the "codex" is a shell script in a temp folder, and the
# sheet geometry is measured on windows that are never ordered in.
#
#   ./run.sh [source-root]
#   SIPAI_UPDMID_GUI=1 ./run.sh     # also presents a REAL SwiftUI sheet
#                                   # (two windows flash on screen)
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

model="$root/SipAI/Models/AgentCLIUpdates.swift"
notices="$root/SipAI/Models/UpdateNotices.swift"
for f in "$model" "$notices"; do
  if [ ! -f "$f" ]; then
    echo "  FAIL  $f not found"
    exit 1
  fi
done

# The pure types, each closed by a top-level `}` in column 1, then the
# monitor class — which in the source sits under its own `@MainActor`.
{
  echo "import AppKit"
  echo "import Combine"
  echo "import Foundation"
  for decl in "struct CLIVersion" "enum CLIUpdateStatus" "enum AgentCLIUpdateRules" \
              "struct AgentCLIRelease" "struct CLIBinaryFingerprint" "enum AgentCLIProbe"; do
    awk -v pat="^${decl}[ :]" '$0 ~ pat, /^\}/' "$model"
    echo
  done
  echo "@MainActor"
  awk '/^final class AgentCLIUpdateMonitor/, /^\}/' "$model"
} > "$out/Extracted.swift"

for required in "final class AgentCLIUpdateMonitor" "func refreshInstalledAgents" \
                "func refreshLocal" "private func finishUpdate" "func update(agentKey key: String)"; do
  if ! grep -q "$required" "$out/Extracted.swift"; then
    echo "  FAIL  '$required' did not extract from $model"
    echo "        (the code under test is not the code shipping)"
    exit 1
  fi
done

swiftc -swift-version 5 -o "$out/updmid" \
  "$here/Stubs.swift" "$out/Extracted.swift" "$notices" "$here/main.swift"
"$out/updmid" "$root"
