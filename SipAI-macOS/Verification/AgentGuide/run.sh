#!/bin/bash
# Headless check of Settings → Agent Guide and the presence rule that
# holds the feature together — see the header of AgentGuide.swift.
#
# The rules under test are EXTRACTED VERBATIM from the shipping
# AgentGuide.swift (and the scheduler's `decide` from
# ScheduledTaskScheduler.swift) rather than restated here: a harness
# holding its own copy of a rule passes for the wrong reason.
# PlanUsage.swift is compiled whole (the account kinds, the detector,
# kimi's server session); the probe runner, the app-server client and
# the release table come out of AgentCLIUpdates.swift.
#
# The second pass READS the shipping sources for the wiring a headless
# run cannot reach — the sidebar gating on presence, the ADD row, the
# closed pane, the scheduler input, the one writer of hidden_agents,
# the retired read-only tier, the String Catalog entries.
#
#   ./run.sh [source-root]
#   SIPAI_AGENTGUIDE_LIVE=1 ./run.sh      # + the real codex app-server login
#                                         #   start/cancel/key/logout and kimi's
#                                         #   server login routes, under throwaway
#                                         #   homes; `claude auth status --json`
#   SIPAI_AGENTGUIDE_INSTALL=1 ./run.sh   # + the three installs for real under a
#                                         #   throwaway HOME (downloads ~500 MB),
#                                         #   then each delete plan
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

guide="$src/SipAI/Models/AgentGuide.swift"
updates="$src/SipAI/Models/AgentCLIUpdates.swift"
launch="$src/SipAI/Models/AgentLaunchOptions.swift"
scheduler="$src/SipAI/Models/ScheduledTaskScheduler.swift"
for f in "$guide" "$updates" "$launch" "$scheduler" "$src/SipAI/Models/PlanUsage.swift"; do
  if [ ! -f "$f" ]; then
    echo "PRE-FIX: $f does not exist — nothing to test."
    exit 1
  fi
done

# Everything that is a pure rule, a parser or a transport, pulled out
# whole. A top-level `}` in column 1 closes each declaration.
{
  echo "import Foundation"
  echo "import AppKit"
  echo "import CryptoKit"
  for decl in "struct CLIVersion" "struct CLIBinaryFingerprint" "enum AgentCLIProbe" \
              "enum CodexAppServerCall" "struct AgentCLIRelease"; do
    awk -v pat="^${decl}[ :]" '$0 ~ pat, /^\}/' "$updates"
    echo
  done
  awk -v pat="^enum TomlScalar[ :]" '$0 ~ pat, /^\}/' "$launch"
  echo
  for decl in "enum AgentPresence" "enum AgentAddRow" "struct ClaudeAuthStatus" \
              "enum KimiServerAnswer" "enum KimiConfigProviders" "enum KimiCatalogListing" \
              "enum AgentInstallSource" "enum AgentDeletePlan" "enum AgentInstallRoute" "enum KimiSite" \
              "enum AgentSignIn" "enum TerminalText" "enum CodexPackageInstall" \
              "enum AgentAccountProbe" "final class CodexAppServerSession"; do
    awk -v pat="^${decl}[ :]" '$0 ~ pat, /^\}/' "$guide"
    echo
  done
  # The scheduler's rule, in a shell carrying its two windows.
  echo "enum ScheduledTaskScheduler {"
  grep -E "^\s+nonisolated static let (liveWindow|catchUpWindow): TimeInterval" "$scheduler"
  awk '/^    enum Decision: Equatable \{/ {inside=1} inside {print} inside && /^    \}$/ {exit}' "$scheduler"
  awk '/^    nonisolated static func decide\(_ def: ScheduledTaskDefinition,/ {inside=1} inside {print} inside && /^    \}$/ {exit}' "$scheduler"
  echo "}"
} > "$out/Extracted.swift"

for required in "static func resolve(installed: Bool," "static func carry(previous:" \
                "static func label(presences:" "static func detect(agentKey: String," \
                "static func make(agentKey: String," "static func route(agentKey: String)" \
                "static func expectedDigest(sums:" "static func needsRCLine(loginShellPath:" \
                "agentListed: Bool = true," "static func scrubbed(_ output:" \
                "static func modelIds(from output:" "static func strippingEscapes(_ text:" \
                "static func reconcile(file: PlanAccountKind," "let apiKeySource: String?" \
                "final class CodexAppServerSession" "static func signatureProblem(packageRoot root: String,"; do
  if ! grep -q "$required" "$out/Extracted.swift"; then
    echo "  FAIL  '$required' did not extract"
    echo "        (the rule under test is not the one shipping)"
    exit 1
  fi
done

if ! swiftc -O -o "$out/guide" \
  "$here/Stubs.swift" "$out/Extracted.swift" "$here/main.swift" \
  "$src/SipAI/Models/PlanUsage.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi
"$out/guide" "$src"

if [ "${SIPAI_AGENTGUIDE_INSTALL:-0}" = "1" ]; then
  echo
  echo "Live installs under a throwaway HOME (SIPAI_AGENTGUIDE_INSTALL=1)"
  bash "$here/install-live.sh" "$src"
fi
