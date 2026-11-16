#!/bin/bash
# Headless check of the question bridge: claude's AskUserQuestion drawn
# as a card and answered back through the approver, the Non-stop switch
# that declines a question instead, and the turn clock that leaves out
# every wait on the user — a question, a plan, a permission alike.
#
# What fails silently here, which is why it is pinned:
#
#  * An allow that carries no `answers` reads to the agent as "The user did
#    not answer the questions." The card would look answered, and the
#    agent would carry on without the answer.
#  * A multi-select answer sent as an array reaches the model as "A,B"; a
#    ", "-joined string reads as written and still counts as picked labels.
#  * A question declined without a card must not post a notification, and
#    Non-stop's words win over every other reason — a scheduled run is
#    never told to wait, or to ask in text.
#  * Claude abandons a permission prompt its server has been silent on for
#    30 minutes unless the server's config raises that limit; the tool's
#    result is then an error while the card is still on screen.
#  * A reopened transcript's last-turn time must leave out the waits the
#    live clock left out, as far as the transcript shows them — a
#    question, a plan handed over for approval — or the two disagree
#    after a relaunch.
#  * "Chat about this" must end in the agent ASKING the user what to
#    clarify, not in it guessing an answer or asking the same card again.
#
# The keyboard on the card is driven for real in
# Verification/ApprovalCardKeys.
#
# Sections 1–2 are the pure rules (AgentQuestions.swift). Section 3 runs
# the REAL MCPBridge.swift (compiled whole, its socket in a throwaway
# directory) against the REAL approver.py. Section 4 drives the REAL
# claude over a fake Messages endpoint (../ApprovalCards/plan_server.py)
# through that bridge, under throwaway config directories — token-free;
# SKIP when claude is not installed. SIPAI_QUESTIONS_SLOW=1 adds the
# idle-limit check (about 80 s). Section 5 reads the shipping sources for
# the wiring. Section 6 drives the REAL transcript reader
# (AgentSession.swift) over a synthetic transcript.
#
# The bridge binary is wrapped in a minimal .app: the bridge talks to
# Notification Center, which refuses a process without a bundle.
#
#   ./run.sh                  # this checkout
#   ./run.sh <source-root>    # another checkout
#
# Run it after a Claude Code upgrade: the question tool's input and its
# result, and the MCP config's per-server keys, are claude's to change.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

bridge="$src/SipAI/Models/MCPBridge.swift"
questions="$src/SipAI/Models/AgentQuestions.swift"
rules="$src/SipAI/Models/ApprovalCardRules.swift"
approver="$src/SipAI/Resources/approver.py"
for f in "$bridge" "$approver"; do
  if [ ! -f "$f" ]; then
    echo "PRE-FIX: $f does not exist — nothing to test."
    exit 1
  fi
done
if [ ! -f "$questions" ] || ! grep -q "static let questionTool" "$bridge"; then
  echo "PRE-FIX: this checkout declines every AskUserQuestion before it reaches"
  echo "  the user (MCPBridge's nonInteractiveTools door) — there is no question"
  echo "  card to test."
  exit 1
fi

mkdir -p "$out/mcp" "$out/work" "$out/Harness.app/Contents/MacOS"
cp "$approver" "$out/mcp/approver.py"
cat > "$out/Harness.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.sipai.harness.agentquestions</string>
<key>CFBundleExecutable</key><string>harness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

# The cards' shared rules (the keyboard's grid, what a bridge request may
# carry) live beside the question rules; a checkout older than them has
# no such file and needs none.
sources=("$here/Stubs.swift" "$questions" "$bridge" "$src/SipAI/Models/SkillModel.swift")
# An MCP server's forms and links are drawn by McpElicitation.swift, which
# the bridge leans on; a checkout older than them has no such file.
mcp="$src/SipAI/Models/McpElicitation.swift"
if [ -f "$mcp" ]; then sources+=("$mcp"); fi
if [ -f "$rules" ]; then sources+=("$rules"); fi
sources+=("$here/main.swift")
if ! swiftc -O -o "$out/Harness.app/Contents/MacOS/harness" \
  "${sources[@]}" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi

# The transcript reader compiles with the same neighbours as
# Verification/SlashCommandOutput, whose stubs stand in for the app.
models="$src/SipAI/Models"
if ! swiftc -O -o "$out/reader" \
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
  "$here/reader/main.swift" 2>"$out/reader-build.log"; then
  cat "$out/reader-build.log" >&2
  exit 1
fi

set +e
QUESTIONS_HARNESS_MCP_DIR="$out/mcp" \
  "$out/Harness.app/Contents/MacOS/harness" "$src" "$out/work" "$here"
bridge_status=$?
"$out/reader" "$out/work"
reader_status=$?
set -e
[ $bridge_status -eq 0 ] && [ $reader_status -eq 0 ]
