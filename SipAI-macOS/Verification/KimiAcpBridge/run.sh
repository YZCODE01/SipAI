#!/bin/bash
# Kimi's own front end — Default (kimi's own configured mode), Ask When
# Needed, Plan — runs through `kimi acp`, kimi's own Agent Client Protocol
# server, because that is the front end through which kimi ASKS. `kimi
# --prompt` approves everything itself (Never Ask).
#
# What fails silently here, which is why it is pinned:
#
#  * The mode a turn states. Kimi applies its config to a session it
#    creates, so a new session on Default is told nothing — a mode stated
#    there replaces kimi's own reading and cancels the plan mode a
#    `default_plan_mode` config opened it in. And kimi REFUSES a second
#    `plan` for a session already planning ("Internal error"): the
#    message after Revise is a Plan turn on exactly such a session.
#  * A plan approved "then Default" continues in kimi's configured mode
#    in ANY turn, and Return starts on the mode the turn was sent in.
#  * `/compact` is answered first and begun after: let go of at the
#    answer, kimi records the compaction cancelled.
#  * A card in kimi's words: its options verbatim, its plan with the file
#    it was saved to, its question form read whole. A card that cannot be
#    drawn is answered at once (cancelled / declined), never with an
#    error — kimi reads a failed request as a reason to ask again.
#  * The transcript is drawn from the session's own record through the
#    reader a reopened session uses, so a live turn and the same turn
#    reopened read alike; the prompt's own row is not drawn twice.
#  * A provider's failure: ACP ends such a turn as if it had succeeded,
#    and only the record says why.
#  * An ACP turn binds the session to ACP's runtime and kimi replays the
#    last binding — every later run of the session, kimi's own terminal
#    included, then lacks Bash, Write, Edit, Glob, Grep and Agent. Kimi
#    still lists them in the request and answers `Tool "Bash" not found`
#    only when the model calls one, so what is checked is a tool that RAN.
#    The binding is handed back after every turn, in kimi's own record:
#    the one the wire's newest binding used, in every agent's wire — a
#    subagent an ACP turn started keeps ACP's runtime in a wire of its own.
#  * A session made for a turn that was stopped before its message went
#    is removed, never left behind as an empty row.
#  * A kimi that dies mid-turn leaves its turn open in the record for
#    good (no `turn.ended`): the driver must return at once, with the
#    conversation closed, rather than wait on that — or the dead turn
#    stays "running" and the runner cannot say what happened.
#  * A turn never ends without a row: an answer the driver cannot read
#    (another protocol version, a session opened without an id) says so.
#  * A background task: kimi records its end and, a moment later, the
#    turn it runs on it. A read between the two finds no task and no
#    turn; a clock started at the prompt would cut a turn whose task took
#    longer than the clock. Both end the turn with the task's report
#    never drawn — and kimi's notification of it is a user-role record
#    that is not the user's.
#  * Handing a session back reads binding RECORDS: a tail that merely
#    names the record (a search for it) holds none, and stopping there
#    leaves the session on ACP's runtime with its journal cleared.
#
# Section 1 is the rules, pure. Section 2 drives the REAL driver
# (KimiAcpTurn) through the REAL peer against the REAL `kimi acp` over a
# throwaway KIMI_CODE_HOME whose provider is ../ChatOnlyMode/fake_server.py
# — token-free — and through stub_server.py, a stand-in that misbehaves on
# purpose (another protocol version, a missing id, a crash, a refusal with
# no words), since the real one cannot be made to. Section 3 reads the shipping sources for the wiring.
# SIPAI_KIMIACP_SLOW=1 adds the background tasks (~25 s): the turn kept up
# until kimi's own follow-up turn is over, and Stop with a task running —
# kimi given its own wind-down, in which it stops the task, with the
# SIGTERM that leaves the task running as the control.
#
# Run it after a Kimi Code upgrade: the option ids, the form's shape, the
# record's types and the binding are all kimi's to change.
#
#   ./run.sh                  # this checkout
#   ./run.sh <source-root>    # another checkout
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/../..}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

models="$src/SipAI/Models"
if [ ! -f "$models/KimiAcp.swift" ] || [ ! -f "$models/KimiAcpTurn.swift" ]; then
  echo "PRE-FIX: this checkout has no kimi ACP driver — kimi's asking modes cannot run."
  exit 1
fi

# The REAL physical-path rule, extracted by text (never copied).
{
  echo "import Foundation"
  echo "enum KimiWebTurn {"
  awk '/static func resolvedPath\(_ url: URL\) -> String \{/ {inside=1}
       inside {print}
       inside && /^    }$/ {exit}' "$models/KimiWebTurn.swift"
  echo "}"
} > "$out/Extracted.swift"
if ! grep -q "realpath" "$out/Extracted.swift"; then
  echo "FAIL  KimiWebTurn.resolvedPath is not where the harness expects it"
  exit 1
fi

if ! swiftc -O -o "$out/harness" \
  "$here/../KimiCode/Stubs.swift" \
  "$out/Extracted.swift" \
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
  "$models/AgentQuestions.swift" \
  "$models/ApprovalCardRules.swift" \
  "$models/JSONRPCLinePeer.swift" \
  "$models/AgentRPCTurn.swift" \
  "$models/KimiAcp.swift" \
  "$models/KimiAcpTurn.swift" \
  "$here/main.swift" 2>"$out/build.log"; then
  cat "$out/build.log" >&2
  exit 1
fi

perl -e 'alarm 600; exec @ARGV' "$out/harness" "$src" "$here/../ChatOnlyMode/fake_server.py" "$here/stub_server.py" \
  "$here/../AgentQuestions/mcp_form_server.py"
