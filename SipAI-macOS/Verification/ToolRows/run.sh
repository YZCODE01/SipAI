#!/bin/bash
# Headless check of what a tool row SAYS — the chip a transcript draws for
# one tool call — and that a row reads the same live and after a reopen,
# for Codex and Kimi Code. Claude Code's live stream and its transcript
# carry the same tool input, so its rows are the renderer's own case.
#
# What regresses silently here, which is why it is pinned:
#
#  * A ROW SAYS WHAT RAN. Codex's file change keeps its files under
#    `changes` (the app-server adds each file's diff), a code-mode search
#    starts with no terms and names them when it ends, and Kimi names a
#    file `path` where Claude names it `file_path`. A reader that looks
#    only for the top-level keys Claude uses draws an empty `{ }` body,
#    the status word "completed" as the output, and a Read row that never
#    names its file.
#  * LIVE AND REOPENED ARE ONE ROW. Codex's code mode runs a script
#    (`exec`) that calls the real tools inside it; the live feed sends
#    what the script ran as items of their own, and the session file keeps
#    the script as the model's call and what it ran as `item_completed`
#    records. A reopen draws the records and not the script — nor codex's
#    own `wait` and `sleep` plumbing — and only while the records say what
#    ran: an older codex wrote no command records, and its scripts stay; a
#    record of a kind no row is drawn from (an MCP tool) leaves its script.
#    An image codex viewed is a row on both feeds ("Viewed image", codex's
#    words), though `codex exec` prints nothing for one.
#  * A KIMI ROW ENDS AS KIMI RECORDED IT. Kimi's headless stdout carries
#    neither a tool's failure nor an image read's text — it prints the
#    image's content blocks as one JSON string — while its session record
#    keeps both; the live row takes them from the record.
#  * A TITLE SIPAI CHOOSES IS IN SIPAI'S LANGUAGE. Codex's events carry
#    only a machine label, so SipAI picks a row's title ("Shell", "Viewed
#    image"), as it does for Claude's Edit ("Update"); those follow Settings
#    → Language. A tool shown by its own name (Read, Bash, an MCP tool's)
#    keeps it in every language.
#
# Section 1 is the renderer, section 2 Codex's live parser, section 3 the
# Codex reopen reader, section 4 Kimi's two feeds, section 5 the wiring,
# read off the sources (the chip needs a window; the runner needs a child).
# Section 6 drives the REAL codex (`codex exec --json` and `codex
# app-server`, plain and code mode) and the REAL kimi against the stand-in
# model endpoint (../ChatOnlyMode/fake_server.py) under throwaway homes —
# token-free — and holds each live row to the row its session file reopens
# as. It is skipped where a CLI is not installed. Section 7 runs the harness
# again in Chinese, with the catalog compiled beside it (`xcstringstool`,
# which comes with Xcode; skipped without it).
#
# Run it after a Codex or Kimi Code upgrade: the item shapes, the record
# shapes and what each prints on stdout are theirs to change.
#
#   ./run.sh                  # this checkout
#   ./run.sh <source-root>    # another checkout
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

models="$src/SipAI/Models"
utilities="$src/SipAI/Utilities"
if [ ! -f "$models/CodexRecordedTools.swift" ]; then
  echo "PRE-FIX: this checkout has no CodexRecordedTools.swift — tool rows are drawn from the call's top-level keys alone."
  exit 1
fi

if ! swiftc -O -o "$out/harness" \
  "$here/../KimiCode/Stubs.swift" \
  "$here/BridgeStub.swift" \
  "$here/LiveRuns.swift" \
  "$models/AttachmentInline.swift" \
  "$models/SkillModel.swift" \
  "$models/ShellCommands.swift" \
  "$models/AgentSession.swift" \
  "$models/AgentSessionTailer.swift" \
  "$models/AgentEventParsing.swift" \
  "$models/CodexEventParsing.swift" \
  "$models/CodexRecordedTools.swift" \
  "$models/CodexSessions.swift" \
  "$models/AgentLaunchOptions.swift" \
  "$models/KimiSessions.swift" \
  "$models/KimiEventParsing.swift" \
  "$models/AgentQuestions.swift" \
  "$models/ApprovalCardRules.swift" \
  "$models/McpElicitation.swift" \
  "$models/JSONRPCLinePeer.swift" \
  "$models/AgentRPCTurn.swift" \
  "$models/CodexAppServer.swift" \
  "$models/CodexAppServerTurn.swift" \
  "$utilities/AgentRendering.swift" \
  "$utilities/ChatOnlyActivity.swift" \
  "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi

# The catalog beside the harness, as the app carries it: the main pass
# runs in English, and section 7 again in Chinese.
titles=0
if xcrun xcstringstool compile "$src/SipAI/Resources/Localizable.xcstrings" --output-directory "$out" \
     >"$out/catalog.log" 2>&1; then
  titles=1
fi

status=0
perl -e 'alarm 600; exec @ARGV' "$out/harness" "$src" "$here/../ChatOnlyMode/fake_server.py" \
  -AppleLanguages '(en)' || status=1
echo ""
if [ "$titles" = 1 ]; then
  perl -e 'alarm 120; exec @ARGV' "$out/harness" "$src" "$here/../ChatOnlyMode/fake_server.py" titles \
    -AppleLanguages '(zh-Hans)' || status=1
else
  echo "7. Titles in SipAI's language"
  echo "  SKIP the catalog did not compile (xcstringstool needs Xcode): $(tail -1 "$out/catalog.log")"
fi
exit $status
