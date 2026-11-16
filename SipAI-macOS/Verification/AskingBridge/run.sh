#!/bin/bash
# Headless check of the ground codex's and kimi's asking modes stand on:
# one bridge for three front ends, the JSON-RPC peer a turn speaks
# through, and the rules that decide which turns may ask at all.
#
# What fails silently here, which is why it is pinned:
#
#  * A request from an agent's own protocol (codex's app-server, kimi's
#    ACP) must be answered EXACTLY once — by the user's choice, by Stop, by
#    a quit, or at once when it cannot be drawn. An unanswered one holds
#    the agent's turn open with nothing on screen; a second answer is a
#    protocol error mid-turn.
#  * The agent's own "for this session" is the agent's to remember. Written
#    to SipAI's exact-call cache it would answer a later CLAUDE request.
#  * A kimi ExitPlanMode is kimi's plan review, with kimi's answers: routed
#    to claude's plan card it would offer claude's modes.
#  * A JSON-RPC child is read by the same draining loop as every child,
#    and its lines reach the main actor IN ORDER: a turn's last chunk must
#    never be overtaken by the answer that ends the turn. A write to a
#    child that has gone must fail, never SIGPIPE this process.
#  * Chat only never takes an asking front end. A scheduled run runs in its
#    task's mode as picked — an asking mode or a front-end Default asks on
#    cards, as from the composer — and is Non-stop only when its task says
#    so. A claude `manual` or `plan` restored onto another agent's session
#    must never switch it into an asking mode — hence the agent prefix on
#    every value.
#
# Section 1 is the peer, pure. Section 2 drives it against a real child
# (rpc_child.py) through the REAL draining loop, extracted from
# AgentRunner.swift by text, over a pipe and over a terminal. Section 3 is
# the driver and scheduling rules. Section 4 runs the REAL MCPBridge with
# requests in the shape the drivers hand it. Section 5 is the forms an
# agent's questions are read into. Section 6 reads the shipping sources
# for the wiring. Token-free; nothing here talks to an agent.
#
# The bridge half is wrapped in a minimal .app: the bridge talks to
# Notification Center, which refuses a process without a bundle.
#
#   ./run.sh                  # this checkout
#   ./run.sh <source-root>    # another checkout
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

models="$src/SipAI/Models"
runner="$models/AgentRunner.swift"
peer="$models/JSONRPCLinePeer.swift"
if [ ! -f "$peer" ] || ! grep -q "func enqueue(_ req: MCPApprovalRequest)" "$models/MCPBridge.swift"; then
  echo "PRE-FIX: this checkout has no JSON-RPC peer and no bridge entry for another"
  echo "  front end — codex and kimi have no way to put a card in front of the user."
  exit 1
fi

# The REAL drain loop, extracted by text (never copied); `private` is
# widened so the harness can call it.
extracted="$out/Extracted.swift"
{
  echo "import Foundation"
  echo "import Darwin"
  echo "enum Extracted {"
  awk '/static func makeDrainingLineSource\(/ {inside=1}
       inside {print}
       inside && /^    }$/ {exit}' "$runner" | sed 's/private static func/static func/'
  awk '/private final class DrainState/ {inside=1}
       inside {print}
       inside && /^    }$/ {exit}' "$runner" | sed 's/private final class/final class/'
  echo "}"
} > "$extracted"
if ! grep -q "makeDrainingLineSource" "$extracted"; then
  echo "FAIL  makeDrainingLineSource is not where the harness expects it in AgentRunner.swift"
  exit 1
fi

mkdir -p "$out/mcp" "$out/Harness.app/Contents/MacOS"
cat > "$out/Harness.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.sipai.harness.askingbridge</string>
<key>CFBundleExecutable</key><string>harness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

mcp="$models/McpElicitation.swift"
[ -f "$mcp" ] || mcp=""
if ! swiftc -O -o "$out/Harness.app/Contents/MacOS/harness" \
  "$here/Stubs.swift" \
  "$models/AgentQuestions.swift" \
  "$models/ApprovalCardRules.swift" \
  "$models/SkillModel.swift" \
  "$models/MCPBridge.swift" \
  ${mcp:+"$mcp"} \
  "$peer" \
  "$extracted" \
  "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi

# The rules compile with the same neighbours as Verification/ApprovalCards'
# mode reader, whose stubs stand in for the app.
if ! swiftc -O -o "$out/rules" \
  "$here/../KimiCode/Stubs.swift" \
  "$models/AttachmentInline.swift" \
  "$models/SkillModel.swift" \
  "$models/ShellCommands.swift" \
  "$models/AgentSession.swift" \
  "$models/AgentSessionTailer.swift" \
  "$models/AgentEventParsing.swift" \
  "$models/CodexSessions.swift" \
  "$models/CodexRecordedTools.swift" \
  "$models/AgentLaunchOptions.swift" \
  "$models/KimiSessions.swift" \
  "$models/KimiEventParsing.swift" \
  "$models/UnsentAnswers.swift" \
  "$here/rules/main.swift" 2>"$out/rules-build.log"; then
  cat "$out/rules-build.log" >&2
  exit 1
fi

set +e
ASKING_HARNESS_MCP_DIR="$out/mcp" \
  perl -e 'alarm 180; exec @ARGV' "$out/Harness.app/Contents/MacOS/harness" "$src" "$here"
bridge_status=$?
if [ $bridge_status -eq 141 ]; then
  echo ""
  echo "FAIL  the harness was ended by SIGPIPE: a write to a child that had gone was not"
  echo "      told to fail. In the app that write ends SipAI itself."
fi
"$out/rules"
rules_status=$?
set -e
[ $bridge_status -eq 0 ] && [ $rules_status -eq 0 ]
