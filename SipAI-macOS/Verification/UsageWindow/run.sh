#!/bin/bash
# Headless check of the plan-usage window: the toolbar coin, the file
# layer that decides whether it renders, the three CLI answers it
# parses, and the probes that fetch them.
#
# Nothing here is part of the app target: this directory sits outside
# SipAI/, so these files are never compiled into the product.
#
# What regresses silently here, which is why it is pinned:
#
#  * The ACCOUNT VERDICT. Claude's login is `oauthAccount` in
#    ~/.claude.json and an API source anywhere overrides it; codex's is
#    `auth_mode` in auth.json; kimi's is the managed provider beside its
#    token file. Read one wrong and the coin either hides on a plan
#    user or opens onto an empty window for an API-key user — and
#    nothing errors either way.
#  * The PARSERS. Claude answers as text whose shape IS the verdict;
#    codex and kimi answer JSON whose keys are theirs to move. A label
#    matched rather than parsed loses the per-family row the day a
#    family is renamed.
#  * The WIRING. The coin is gated on the monitor, the scrim closes the
#    window, the footer's clock is a leaf TimelineView, and nothing in
#    the app reads a keychain item, a credentials file, or a vendor
#    usage endpoint directly.
#  * The STRINGS. Every new key must carry a zh-Hans value.
#
# Run it after any agent CLI upgrade: the claude text and cache keys,
# the codex RPC payloads and kimi's server routes are each somebody
# else's to change.
#
#   ./run.sh                     # this checkout
#   ./run.sh <source-root>       # another checkout
#   SIPAI_USAGE_LIVE=1 ./run.sh  # + the three real probes (token-free)
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

updates="$src/SipAI/Models/AgentCLIUpdates.swift"
launch="$src/SipAI/Models/AgentLaunchOptions.swift"

# The probe runner, the app-server client and the TOML scalar reader,
# EXTRACTED VERBATIM from the shipping files — a harness holding its
# own copy passes for the wrong reason. A top-level `}` in column 1
# closes each declaration.
{
  echo "import Foundation"
  for decl in "struct CLIVersion" "struct CLIBinaryFingerprint" "enum AgentCLIProbe" \
              "enum CodexAppServerCall"; do
    awk -v pat="^${decl}[ :]" '$0 ~ pat, /^\}/' "$updates"
    echo
  done
  awk -v pat="^enum TomlScalar[ :]" '$0 ~ pat, /^\}/' "$launch"
} > "$out/Extracted.swift"

for required in "enum CodexAppServerCall" "static func run(binary: String, requests:" \
                "currentDirectory: String? = nil" "enum TomlScalar"; do
  if ! grep -q "$required" "$out/Extracted.swift"; then
    echo "PRE-FIX: '$required' is not in the extracted declarations —"
    echo "  this checkout has no plan-usage probes to check."
    exit 1
  fi
done

if [ ! -f "$src/SipAI/Models/PlanUsage.swift" ]; then
  echo "PRE-FIX: $src/SipAI/Models/PlanUsage.swift does not exist."
  exit 1
fi

if ! swiftc -O -o "$out/usage" \
  "$here/Stubs.swift" "$out/Extracted.swift" "$here/main.swift" \
  "$src/SipAI/Models/PlanUsage.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi
"$out/usage" "$src"
