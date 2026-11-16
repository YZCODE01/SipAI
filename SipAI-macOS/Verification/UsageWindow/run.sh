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
#  * KIMI'S ANSWER SHAPE. `kimi web`'s usage route answers in a shape
#    kimi changes, and a shape read wrong is an ok answer with nothing
#    in it: a card with a title, no figures and no error. Section 4b
#    measures the shape through the REAL `kimi web`, pointed at
#    kimi_upstream.py under a throwaway home with a planted login —
#    token-free, nothing of the user's touched — and fails if SipAI's
#    reader does not get the stand-in's figures back.
#  * The WIRING. The coin is gated on the monitor, the scrim closes the
#    window, the footer's clock is a leaf TimelineView, and nothing in
#    the app reads a keychain item, a credentials file, or a vendor
#    usage endpoint directly.
#  * The STRINGS. Every new key must carry a zh-Hans value.
#  * SETTINGS → USAGE'S LAYOUT of the tools' own reports. Claude's
#    "What's contributing" block is a table of claude's words, and is
#    shown whole wherever its shape is not one claude prints — a reworded
#    line must not drop out of the page. Codex's year of token activity
#    follows codex's own terminal (fifty-two weeks of its days in UTC,
#    its four grades, nothing after today), and a square names its
#    tokens exactly.
#    Sections 1c and 3b pin the readers; the render pass draws both in an
#    offscreen window (a window server only; USAGE_RENDER=<dir> writes
#    PNGs) and points at a square.
#  * THE RESET. Settings → Usage uses a codex limit reset through
#    codex's own app-server, and a reset used cannot be undone — nor
#    tried for real without spending one. Section 3c drives the REAL
#    app-server client against codex_appserver_stub.py: the reset the
#    confirmation named and no other, a fresh key per attempt and the
#    same key for a retry of a failed one, every outcome in codex's
#    words. The live section only reads codex's generated protocol for
#    the request's name and fields; nothing here uses a real reset.
#
# Run it after any agent CLI upgrade: the claude text and cache keys,
# the codex RPC payloads and kimi's server routes are each somebody
# else's to change.
#
#   ./run.sh                     # this checkout
#   ./run.sh <source-root>       # another checkout
#   SIPAI_USAGE_LIVE=1 ./run.sh  # + the three real probes, claude's report,
#                                #   codex's history and protocol (token-free)
#   USAGE_RENDER=<dir> ./run.sh  # + PNGs of claude's table and codex's year
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
if ! grep -q "^struct ClaudeContributing" "$src/SipAI/Models/PlanUsage.swift" \
   || ! grep -q "^struct CodexActivityCalendar" "$src/SipAI/Models/PlanUsage.swift"; then
  echo "PRE-FIX: PlanUsage.swift has no ClaudeContributing / CodexActivityCalendar —"
  echo "  Settings → Usage prints claude's block as raw text and draws thirty"
  echo "  days of codex's history as bars."
  exit 1
fi

if ! swiftc -O -o "$out/usage" \
  "$here/Stubs.swift" "$out/Extracted.swift" "$here/main.swift" \
  "$src/SipAI/Models/PlanUsage.swift" "$src/SipAI/Models/KimiMembership.swift" \
  "$src/SipAI/Models/CLIStartFailure.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi
set +e
"$out/usage" "$src" "$here"
status=$?
set -e

# The render pass draws the REAL views, extracted by text from
# UsagePane.swift — each a column-0 `private struct` closed by a column-0
# `}` — beside the real PlanUsage.swift and DesignSystem.swift. A bubble
# under a made-up pointer goes through the shared gate (../SyntheticHover):
# the pass runs with macOS reporting the cursor visible, so that pointer
# reaches SwiftUI, and a SKIP is left for any other cause.
pane="$src/SipAI/Views/Settings/UsagePane.swift"
{
  echo "import SwiftUI"
  echo "import AppKit"
  for decl in "struct ClaudeContributingView" "struct CodexHistoryFigures" \
              "struct TokenActivityCalendar" "struct WidthDrivenHeight"; do
    awk -v pat="private ${decl}" 'index($0, pat) == 1 {f=1} f{print} f&&/^\}/{exit}' "$pane" \
      | sed 's/^private //'
    echo
  done
} > "$out/UsageViews.swift"
for required in "struct ClaudeContributingView" "struct CodexHistoryFigures" \
                "struct TokenActivityCalendar" "struct WidthDrivenHeight"; do
  if ! grep -q "^${required}" "$out/UsageViews.swift"; then
    echo "PRE-FIX: UsagePane.swift has no ${required}."
    exit 1
  fi
done
if ! swiftc -O -o "$out/render" \
  "$here/Stubs.swift" "$out/Extracted.swift" "$src/SipAI/Models/PlanUsage.swift" \
  "$src/SipAI/Models/KimiMembership.swift" "$src/SipAI/Models/CLIStartFailure.swift" \
  "$src/SipAI/Utilities/DesignSystem.swift" "$out/UsageViews.swift" \
  "$here/../SyntheticHover/SyntheticHover.swift" \
  "$here/Render/main.swift" 2>"$out/render-build.log"; then
  cat "$out/render-build.log" >&2
  exit 1
fi
source "$here/../SyntheticHover/cursor_visible.sh"
cursor_preload "$out" || { echo "  FAIL cursor_visibility.c did not build" >&2; exit 1; }
echo ""
echo "8. Render — claude's table and codex's year, drawn"
# Bounded: with no window server the process would hang rather than fail.
# With none, nothing is ever drawn; stopped by the clock once a page has
# been, the run is a view that hung — a FAIL, never the skip. It sees macOS
# report the cursor visible, so a made-up pointer reaches SwiftUI
# (../SyntheticHover).
set +e
cursor_visible_within 120 "$out/render" | tee "$out/render.log"
render=${PIPESTATUS[0]}
set -e
if [ $render -eq 142 ] || [ $render -eq 14 ]; then
  if grep -Eq '^  (ok|FAIL) ' "$out/render.log"; then
    echo "  FAIL the render pass stopped answering after it had drawn a page"
    render=1
  else
    echo "  SKIP — timed out reaching the window server (no GUI session?)."
    render=0
  fi
fi
[ $status -eq 0 ] && [ $render -eq 0 ]
