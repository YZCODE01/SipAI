#!/bin/bash
# Headless check of the agent-CLI update status feature — see the header
# of main.swift for the rule and the failure it was written for.
#
# The types under test are EXTRACTED VERBATIM from the shipping
# AgentCLIUpdates.swift rather than restated here: a harness holding its
# own copy of the rule passes for the wrong reason. Only the three app
# types the probe reaches for (AgentManager, AgentRunner,
# ShellEnvironment) are stood in for, and none of them carries a rule.
#
# The second pass READS the shipping sources for the wiring a headless
# run cannot reach — the shared child environment, the null stdin, the
# absence of a process-group kill, the factory-reset registration and
# the String Catalog entries. An explicit source root points that pass
# at another checkout.
#
# Run it after touching AgentCLIUpdates.swift, and after any agent CLI
# upgrade: every measured fact in the release table (endpoint, payload
# shape, update subcommand) is somebody else's to change.
#
#   ./run.sh [source-root]
#   SIPAI_CLIUPD_LIVE=1 ./run.sh    # also fetches the real endpoints
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

model="$root/SipAI/Models/AgentCLIUpdates.swift"
if [ ! -f "$model" ]; then
  echo "  FAIL  $model not found"
  echo "        (the feature's model file — nothing to test)"
  exit 1
fi
# The badge and the header's queue live beside it, and are compiled
# WHOLE: nothing in that file reaches for an app type.
notices="$root/SipAI/Models/UpdateNotices.swift"
if [ ! -f "$notices" ]; then
  echo "  FAIL  $notices not found"
  echo "        (the badge and the announcement queue — nothing to test)"
  exit 1
fi

# Everything that is a pure rule or a filesystem read, pulled out whole.
# A top-level `}` in column 1 closes each declaration.
{
  echo "import Foundation"
  for decl in "struct CLIVersion" "enum CLIUpdateStatus" "enum AgentCLIUpdateRules" \
              "struct AgentCLIRelease" "struct CLIBinaryFingerprint" "enum AgentCLIProbe" \
              "enum CodexAppServerCall" "enum CodexModelListRefresh" \
              "enum CodexConfigWrite"; do
    awk -v pat="^${decl}[ :]" '$0 ~ pat, /^\}/' "$model"
    echo
  done
} > "$out/Extracted.swift"

for required in "static func parse" "static func decideStatus" "static func updateAction" \
                "static func updateVerdict" "static func badgeVersion" "static func autoUpdateIsDue" \
                "static func measured" "static func versionFromClaudeVersionsSymlink"; do
  if ! grep -q "$required" "$out/Extracted.swift"; then
    echo "  FAIL  '$required' did not extract from $model"
    echo "        (the rule under test is not the one shipping)"
    exit 1
  fi
done

swiftc -O -o "$out/cliupdharness" \
  "$here/Stubs.swift" "$out/Extracted.swift" "$notices" "$here/main.swift"
"$out/cliupdharness" "$root"
