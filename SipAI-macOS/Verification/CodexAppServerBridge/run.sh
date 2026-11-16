#!/bin/bash
# Codex's own front end — Default (codex's own default setting) and Plan — run
# through `codex app-server`, the front end codex's own terminal and app
# drive, because that is where codex ASKS. `codex exec` refuses every
# approval and question itself.
#
# What fails silently here, which is why it is pinned:
#
#  * A card in codex's words, with the answers codex lists for the
#    request — less the two that write a rule for every codex session on
#    the Mac. The diff of a file change is on the item codex announced
#    just before asking, not on the request.
#  * The command on a card is the WHOLE command. Codex sends a summary of
#    what a command reads beside it (`commandActions`), and for a compound
#    command that summary is one part: `cat a | tee /elsewhere/b` comes
#    with `cat a`. A card drawn from it shows a read where the answer
#    runs a write.
#  * What a turn states: model, effort, speed and collaboration mode are
#    the THREAD's once named, in later processes too, and a null effort
#    does not clear one — a Default turn that left any out would run on
#    whatever an earlier turn set. With NO model configured (a config
#    never given a pick) there is still one to state: codex's own default, off its
#    `model/list` answer — unstated, a Default chip runs the model the
#    turn before it picked.
#  * The approval policy is the thread's too: a turn that states none
#    runs on the last turn's (after Full Access, never asking). So a
#    Default turn asks codex for its own default for the folder — on a
#    resumed thread a turnless `thread/start`, deleted the moment it has
#    answered (left loaded it runs a second set of the user's MCP servers
#    and holds a writer lock) — and states it: read-only in a folder the
#    config does not trust, workspace-write in one it does. The sandbox
#    goes back as the permission PROFILE where one is in force: a legacy
#    mode stated over a user's own profile replaces it.
#  * What a turn leaves on Default — model, effort, speed — is codex's own
#    answer for the folder, a trusted project's config included. Resolved
#    from SipAI's reading alone, a scheduled run stated the user file's
#    model, the model's default effort, and cleared the configured speed.
#  * Plan mode is the thread's: a `codex exec` turn after a Plan turn runs
#    under the plan instructions until something sets it back.
#  * An app-server item drawn through exec's parser, so a turn reads the
#    same in either mode; a `<proposed_plan>` block drawn after the words
#    around it, live and reopened alike.
#  * The child's stdin stays open until the turn completes: codex aborts a
#    turn whose stdin closes, at once.
#  * A new thread becomes the session only once codex ACCEPTS its first
#    turn: a thread with no turn has no rollout, nothing can open it
#    again, and an id adopted before a refused `turn/start` would fail
#    every later message with "no rollout found".
#  * A turn never ends without a row: an answer the driver cannot read, a
#    request it cannot draw (answered `cancel`, which ends the turn), a
#    server that dies under the conversation.
#  * A command codex leaves running in a background terminal when its
#    answer lands holds the turn until it ends (BT): codex ends the turn
#    at the answer one run and waits for the command the next, and stops
#    the command the moment the conversation closes.
#
# Section 1 is the rules, pure. Section 2 drives the REAL driver
# (CodexAppServerTurn) through the REAL peer against the REAL `codex
# app-server` over a throwaway CODEX_HOME whose provider is
# ../ChatOnlyMode/fake_server.py's scripted Responses route — token-free —
# and through stub_server.py, a stand-in that misbehaves on purpose (a
# refused turn, with words and without, a missing id, an undrawable
# request, a crash), since the real one cannot be made to. Section 3 reads the shipping sources for the
# wiring.
#
# Run it after a Codex upgrade: the request methods, the decisions, the
# item shapes, the plan item and the thread's settings are all codex's to
# change.
#
#   ./run.sh                  # this checkout
#   ./run.sh <source-root>    # another checkout
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

models="$src/SipAI/Models"
if [ ! -f "$models/CodexAppServer.swift" ] || [ ! -f "$models/CodexAppServerTurn.swift" ]; then
  echo "PRE-FIX: this checkout has no codex app-server driver — codex's asking modes cannot run."
  exit 1
fi

if ! swiftc -O -o "$out/harness" \
  "$here/../KimiCode/Stubs.swift" \
  "$models/AttachmentInline.swift" \
  "$models/SkillModel.swift" \
  "$models/ShellCommands.swift" \
  "$models/AgentSession.swift" \
  "$models/AgentSessionTailer.swift" \
  "$models/AgentEventParsing.swift" \
  "$models/CodexEventParsing.swift" \
  "$models/CodexSessions.swift" \
  "$models/CodexRecordedTools.swift" \
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
  "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi

perl -e 'alarm 600; exec @ARGV' "$out/harness" "$src" "$here/../ChatOnlyMode/fake_server.py" "$here/stub_server.py" \
  "$here/../AgentQuestions/mcp_form_server.py"
