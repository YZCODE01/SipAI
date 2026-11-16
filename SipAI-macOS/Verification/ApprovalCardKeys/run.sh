#!/bin/bash
# The keyboard on the cards an agent's turn waits on — the permission
# card, the plan card and the question card — driven for real: the REAL
# cards in an offscreen window, the REAL key monitor (ApprovalCardKeys),
# the REAL agent composer's text box beside them, the REAL MCPBridge and
# the REAL approver.py, with key-down events sent through NSApplication
# the way a keyboard sends them.
#
# What fails silently here, which is why it is pinned:
#
#  * Return typed into a half-written message must never answer a card —
#    it would approve a command. The keys are a card's only while nothing
#    is being edited, or while the session's own message box is EMPTY.
#  * The filled button is the one Return takes. A highlight that does not
#    follow the arrow keys, or a Return that takes another answer than the
#    highlighted one, is a card that lies about what it will do.
#  * A Return already on its way when a card appears, or held down across
#    two cards, must not answer what nobody has read.
#  * A card scrolled out of sight, a card that is not the newest, a key
#    aimed at another window or at a sheet: none may be answered.
#  * An overlay of the window's own with keys of its own — the sidebar's
#    settings menu — takes them through SwiftUI focus, which the window
#    dispatches AFTER a local monitor has seen the key; under it the
#    first responder is the hosting view, as when nothing has focus. The
#    monitor has to be TOLD such an overlay is up, or the Return that
#    picks a settings section allows the tool call behind the scrim.
#  * "Allow Always" hands claude back the rule claude itself suggested for
#    the call — reported by approver.py's hook mode — and nothing else.
#  * The cards codex and kimi ask for through their own protocols
#    (AskingCards.swift) are on the SAME keyboard: Return takes the agent's
#    first acceptance, the arrows walk the agent's own answers, an answer
#    "for this session" is handed to the agent and never written to
#    SipAI's exact-call cache, and "Implement this plan?" takes the keys
#    only when no card a turn waits on is up.
#
# Needs a logged-in GUI session (a window server); it reports SKIP without
# one. The window is offscreen and the app is never activated, so it takes
# no keystroke from whatever the user is doing.
#
#   ./run.sh                  # this checkout
#   ./run.sh <source-root>    # another checkout
#   CARD_KEYS_RENDER=<dir> ./run.sh   # also write PNGs of the cards
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

bridge="$src/SipAI/Models/MCPBridge.swift"
rules="$src/SipAI/Models/ApprovalCardRules.swift"
cards="$src/SipAI/Views/Chat/ApprovalCards.swift"
approver="$src/SipAI/Resources/approver.py"
composer="$src/SipAI/Views/Chat/AgentComposer.swift"
input="$src/SipAI/Views/Chat/MessageInput.swift"
if [ ! -f "$rules" ] || [ ! -f "$cards" ]; then
  echo "PRE-FIX: this checkout has no ApprovalCardRules.swift / ApprovalCards.swift —"
  echo "  its cards take Return through a default-button shortcut alone, which the"
  echo "  message box swallows whenever it has focus, and no arrow key moves a choice."
  exit 1
fi

# The composer's text box and the text view it is built around, verbatim
# out of the shipping files (never a copy), plus the one line that lets
# the box hand its keys to a card.
{
  echo "import SwiftUI"
  echo "import AppKit"
  awk '/^struct GrowingTextField: NSViewRepresentable \{/{f=1} f{print} f&&/^\}/{exit}' "$composer"
  echo
  awk '/^final class DropForwardingTextView: NSTextView \{/{f=1} f{print} f&&/^\}/{exit}' "$input"
  echo
  grep -x 'extension DropForwardingTextView: CardKeyYielding {}' "$input" || true
} > "$out/Extracted.swift"
if ! grep -q "CardKeyYielding" "$out/Extracted.swift"; then
  echo "FAIL  MessageInput.swift no longer declares DropForwardingTextView: CardKeyYielding —"
  echo "      the message box keeps every key, and no card can be answered from the keyboard."
  exit 1
fi

mkdir -p "$out/mcp" "$out/work" "$out/Harness.app/Contents/MacOS"
cp "$approver" "$out/mcp/approver.py"
cat > "$out/Harness.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.sipai.harness.approvalcardkeys</string>
<key>CFBundleExecutable</key><string>harness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

# An MCP server's forms and links (McpElicitation.swift), which the bridge
# and the cards lean on; a checkout older than them has no such file.
mcp="$src/SipAI/Models/McpElicitation.swift"
[ -f "$mcp" ] || mcp=""
u="$src/SipAI/Utilities"
if ! swiftc -O -target arm64-apple-macos15.0 -o "$out/Harness.app/Contents/MacOS/harness" \
  "$here/Stubs.swift" \
  "$u/DesignSystem.swift" \
  "$u/LatexSymbols.swift" \
  "$u/SearchMatching.swift" \
  "$u/MathAlphabets.swift" \
  "$u/MathSymbols.swift" \
  "$u/MathParser.swift" \
  "$u/MathFont.swift" \
  "$u/MathLayout.swift" \
  "$u/MathDelimiters.swift" \
  "$u/MathDisplayBlock.swift" \
  "$u/MarkdownRenderer.swift" \
  "$u/FileLinks.swift" \
  "$u/CodeBlockActions.swift" \
  "$src/SipAI/Models/AgentQuestions.swift" \
  ${mcp:+"$mcp"} \
  "$rules" \
  "$src/SipAI/Models/SkillModel.swift" \
  "$bridge" \
  "$cards" \
  "$src/SipAI/Views/Chat/AskingCards.swift" \
  "$src/SipAI/Views/Chat/AgentQuestionCard.swift" \
  "$out/Extracted.swift" \
  "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi

# Bound the GUI pass: with no window server the process would hang rather
# than fail.
set +e
CARDKEYS_HARNESS_MCP_DIR="$out/mcp" \
  perl -e 'alarm 120; exec @ARGV' "$out/Harness.app/Contents/MacOS/harness" "$src" "$out/work"
status=$?
set -e
if [ $status -eq 142 ] || [ $status -eq 14 ]; then
  echo ""
  echo "SKIP — timed out reaching the window server (no GUI session?)."
  exit 0
fi
exit $status
