#!/bin/bash
# Headless check of the tool-approval cards an agent session draws for
# claude, and of the plan card that ends a Plan-mode turn.
#
# What fails silently here, which is why it is pinned:
#
#  * A new session's FIRST turn is spawned from a draft, so its child
#    carries SIPAI_SESSION_ID = the draft's task uuid for its whole life,
#    while claude names the real session id in its first second and the
#    runner adopts it. A card filter that matches on the session id alone
#    draws none of that turn's approvals: each sits in MCPBridge.pending
#    unseen, the turn waits on it forever, and Stop answers it "Denied by
#    SipAI.". Plan mode meets it nearly every time, since its one approval
#    (ExitPlanMode) ends a planning turn that is usually the session's
#    first.
#  * ExitPlanMode is a plan, not a tool call: the generic permission card
#    would show it as a 260-character JSON line under Allow / Deny /
#    Always. The plan card asks what claude's own terminal asks — "Yes,
#    and use auto mode", "Yes, auto-accept edits", "Yes, manually approve
#    edits", "No, keep planning" with a line for what to change — and an
#    approval moves the session's chip to the mode it named, or the next
#    turn would plan again.
#  * "Allow Always" that remembers the exact command string never matches
#    again: an agent rarely runs the same string twice. Claude's terminal
#    adds the rule claude itself suggests for the call; the approve tool
#    is never given that suggestion, so it reaches the bridge through a
#    PermissionRequest hook and is handed back unchanged. A grant claude
#    keeps in the running process alone has to be replayed to the
#    session's later turns, each of which is a process of its own.
#  * Claude reads ONE --settings value: a second flag silently replaces
#    the first, so what the bridge adds is merged into the launch's own.
#
# Sections 1–2 are the pure rules (the ownership rule, the plan card's
# answers, what Allow Always remembers, the one --settings value, which
# keys reach a card). Section 3 runs the REAL MCPBridge.swift (compiled
# whole, its socket in a throwaway directory) against the REAL
# approver.py in both its modes, reading back exactly what claude would
# receive. Section 4 drives the REAL claude over a fake Messages endpoint
# (plan_server.py) through that bridge — a first turn, a resumed turn,
# plans approved and kept, Accept Edits asking for a command, Allow
# Always through claude's own hook, a session grant replayed to the next
# turn — under throwaway config directories. Token-free; SKIP when claude
# is not installed. Section 5 reads the shipping sources for the wiring.
# Section 6 runs a second real bridge beside the first, the way two
# copies of SipAI share mcp/: a quit must remove only the socket that
# copy bound.
#
# The keyboard on the cards is driven for real in
# Verification/ApprovalCardKeys.
#
# The harness binary is wrapped in a minimal .app: the bridge talks to
# Notification Center, which refuses a process without a bundle.
#
#   ./run.sh                  # this checkout
#   ./run.sh <source-root>    # another checkout
#
# Run it after a Claude Code upgrade: the plan tool's name and input, the
# permission-prompt result shape, `setMode`, the PermissionRequest hook's
# input and the settings keys are claude's to change.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

bridge="$src/SipAI/Models/MCPBridge.swift"
approver="$src/SipAI/Resources/approver.py"
for f in "$bridge" "$approver"; do
  if [ ! -f "$f" ]; then
    echo "PRE-FIX: $f does not exist — nothing to test."
    exit 1
  fi
done
if ! grep -q "static func request(sessionId requestSessionId" "$bridge"; then
  echo "PRE-FIX: MCPBridge.swift has no ownership rule (MCPBridge.request(sessionId:…))."
  echo "  A first turn's approval cards are matched on the session id alone and"
  echo "  never drawn — the failure this harness exists for."
  exit 1
fi

mkdir -p "$out/mcp" "$out/work" "$out/Harness.app/Contents/MacOS"
cp "$approver" "$out/mcp/approver.py"
cat > "$out/Harness.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.sipai.harness.approvalcards</string>
<key>CFBundleExecutable</key><string>harness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

# The bridge draws an agent's questions through the rules in
# AgentQuestions.swift (see Verification/AgentQuestions); a checkout
# older than those rules has no such file and needs none.
sources=("$here/Stubs.swift" "$bridge" "$src/SipAI/Models/SkillModel.swift")
mcp="$src/SipAI/Models/McpElicitation.swift"
if [ -f "$mcp" ]; then sources+=("$mcp"); fi
questions="$src/SipAI/Models/AgentQuestions.swift"
if [ -f "$questions" ]; then sources+=("$questions"); fi
rules="$src/SipAI/Models/ApprovalCardRules.swift"
if [ ! -f "$rules" ]; then
  echo "PRE-FIX: this checkout has no ApprovalCardRules.swift — its plan card offers"
  echo "  no auto mode and no line for what to change, and its Allow Always remembers"
  echo "  the exact command string alone."
  exit 1
fi
sources+=("$rules" "$here/main.swift")
if ! swiftc -O -o "$out/Harness.app/Contents/MacOS/harness" \
  "${sources[@]}" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi

# The reader of claude's own mode records (AgentEventParser.permissionMode)
# compiles with the same neighbours as Verification/SlashCommandOutput,
# whose stubs stand in for the app; it is held to the stdout the real
# claude wrote in section 4.
models="$src/SipAI/Models"
if ! swiftc -O -o "$out/modes" \
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
  "$here/modes/main.swift" 2>"$out/modes-build.log"; then
  cat "$out/modes-build.log" >&2
  exit 1
fi

set +e
APPROVAL_HARNESS_MCP_DIR="$out/mcp" \
  "$out/Harness.app/Contents/MacOS/harness" "$src" "$out/work" "$here"
bridge_status=$?
if [ $bridge_status -eq 141 ]; then
  echo ""
  echo "FAIL  the harness was ended by SIGPIPE: the bridge wrote to a socket whose peer"
  echo "      had gone. In the app that write ends SipAI itself."
fi
"$out/modes" "$out/work"
modes_status=$?
set -e
[ $bridge_status -eq 0 ] && [ $modes_status -eq 0 ]
