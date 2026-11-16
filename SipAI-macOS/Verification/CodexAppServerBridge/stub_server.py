#!/usr/bin/env python3
"""A stand-in for `codex app-server` that misbehaves on purpose.

The real app-server (section 2 of the harness) cannot be made to refuse a
turn, lose its thread id or die on cue, and those are exactly the answers
a driver must not go quiet on. This speaks just enough of the protocol —
one JSON value per line on stdin and stdout — to give each of them:

  refuse-turn     `turn/start` is answered with a JSON-RPC error
  mute-turn       …with a JSON-RPC error whose message is EMPTY
  no-thread-id    `thread/start` answers without a thread id
  no-model        `thread/start` names a thread but no model
  no-permissions  `thread/start` states no approval policy — codex's own
                  default permissions cannot be read off it
  profile         `thread/start` names a permission profile in force (and
                  a configured effort and speed), as a config with one does
  old-server      `thread/delete` is refused as a method it does not know
  undrawable      the turn asks for a command approval whose only listed
                  answer is one SipAI never offers, and completes
                  `interrupted` once that request is answered `cancel`
  die             the turn is accepted, then the server exits with a
                  status and a line on stderr, mid-turn
  retry           the turn reports a dropped connection it is retrying,
                  then its answer arrives and the turn completes
  mute-roots      `skills/extraRoots/set` is never answered; the turn is
                  then accepted and completes
  ok              the turn is accepted and completes (and, like an older
                  codex, it knows no `skills/extraRoots/set`: refused as
                  "Method not found")

Usage: stub_server.py <mode> [<log file>]
The log file gets one line per message received, for the harness to read.
"""
import json
import sys

mode = sys.argv[1] if len(sys.argv) > 1 else "ok"
log = open(sys.argv[2], "a") if len(sys.argv) > 2 else None
THREAD = "stub-thread-1"
TURN = "stub-turn-1"
# The thread the turn in flight runs on: the one `turn/start` names.
turn_thread = THREAD


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def reply(i, result):
    send({"jsonrpc": "2.0", "id": i, "result": result})


def refuse(i, message):
    send({"jsonrpc": "2.0", "id": i, "error": {"code": -32600, "message": message}})


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        msg = json.loads(raw)
    except ValueError:
        continue
    if log:
        log.write(json.dumps(msg) + "\n")
        log.flush()
    method, i = msg.get("method"), msg.get("id")
    if method is None:
        # An answer to a request of ours: the approval.
        if mode == "undrawable" and i == 900:
            notify("turn/completed", {"threadId": turn_thread,
                                      "turn": {"id": TURN, "status": "interrupted", "error": None}})
        continue
    if i is None:
        continue  # a notification
    if method == "initialize":
        reply(i, {"userAgent": "stub"})
    elif method in ("thread/start", "thread/resume"):
        # The real app-server states the thread's permissions on every
        # answer: codex's own default for the folder when none was asked.
        permissions = {"approvalPolicy": "on-request", "approvalsReviewer": "user",
                       "sandbox": {"type": "workspaceWrite", "networkAccess": False}}
        if mode == "profile":
            permissions = dict(permissions, activePermissionProfile={"id": "mine", "extends": None},
                               reasoningEffort="high", serviceTier="priority")
        if method == "thread/resume":
            # The thread asked for, with whatever the request stated.
            reply(i, dict(permissions, thread={"id": (msg.get("params") or {}).get("threadId")},
                          model="gpt-sticky"))
        elif mode == "no-thread-id":
            reply(i, dict(permissions, thread={}, model="gpt-stub"))
        elif mode == "no-model":
            reply(i, dict(permissions, thread={"id": THREAD}))
        elif mode == "no-permissions":
            reply(i, {"thread": {"id": THREAD}, "model": "gpt-stub"})
        else:
            reply(i, dict(permissions, thread={"id": THREAD}, model="gpt-stub"))
    elif method == "thread/delete":
        if mode == "old-server":
            refuse(i, "Invalid request: unknown variant `thread/delete`")
        else:
            reply(i, {})
    elif method == "turn/start":
        turn_thread = (msg.get("params") or {}).get("threadId") or THREAD
        if mode == "refuse-turn":
            refuse(i, "Invalid request: scripted refusal")
            continue
        if mode == "mute-turn":
            refuse(i, "")
            continue
        reply(i, {"turn": {"id": TURN, "status": "inProgress", "items": [], "error": None}})
        notify("turn/started", {"threadId": turn_thread, "turn": {"id": TURN, "status": "inProgress"}})
        if mode == "die":
            sys.stderr.write("stub: scripted crash\n")
            sys.stderr.flush()
            sys.exit(3)
        if mode == "retry":
            notify("error", {"threadId": turn_thread, "turnId": TURN, "willRetry": True,
                             "error": {"message": "Reconnecting... 1/5"}})
            notify("item/completed", {"threadId": turn_thread, "turnId": TURN,
                                      "item": {"type": "agentMessage", "id": "msg_1", "text": "got through"}})
            notify("turn/completed", {"threadId": turn_thread,
                                      "turn": {"id": TURN, "status": "completed", "error": None}})
            continue
        if mode == "undrawable":
            send({"jsonrpc": "2.0", "id": 900, "method": "item/commandExecution/requestApproval",
                  "params": {"threadId": turn_thread, "turnId": TURN, "itemId": "call_1",
                             "command": "/bin/zsh -lc 'touch x'", "cwd": "/tmp",
                             "availableDecisions": [
                                 {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["touch"]}}]}})
            continue
        notify("turn/completed", {"threadId": turn_thread,
                                  "turn": {"id": TURN, "status": "completed", "error": None}})
    elif method == "skills/extraRoots/set" and mode == "mute-roots":
        continue  # never answered
    else:
        refuse(i, "Method not found: " + str(method))
