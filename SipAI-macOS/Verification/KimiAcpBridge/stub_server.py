#!/usr/bin/env python3
"""A stand-in for `kimi acp` that misbehaves on purpose.

The real server (section 2 of the harness) cannot be made to answer in
another protocol version, lose its session id or die on cue, and those are
exactly the answers a driver must not go quiet on. This speaks just enough
of the Agent Client Protocol — one JSON value per line on stdin and stdout
— to give each of them:

  wrong-version   `initialize` answers protocol version 2
  no-session-id   `session/new` answers without a session id
  die             the session is opened, then the server exits with a
                  status and a line on stderr as the prompt arrives
  mute-mode       `session/set_mode` is refused with an EMPTY message
  mute-prompt     `session/prompt` is refused with an EMPTY message

Usage: stub_server.py <mode> <log file>
The log file gets one line per method received, for the harness to read.
"""
import json
import sys

mode = sys.argv[1] if len(sys.argv) > 1 else "die"
log = open(sys.argv[2], "a") if len(sys.argv) > 2 else None


def reply(i, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": i, "result": result}) + "\n")
    sys.stdout.flush()


def refuse(i, message):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": i,
                                 "error": {"code": -32000, "message": message}}) + "\n")
    sys.stdout.flush()


for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        msg = json.loads(raw)
    except ValueError:
        continue
    method, i = msg.get("method"), msg.get("id")
    if log and method:
        log.write(method + "\n")
        log.flush()
    if method is None or i is None:
        continue
    if method == "initialize":
        reply(i, {"protocolVersion": 2 if mode == "wrong-version" else 1})
    elif method == "session/new":
        reply(i, {} if mode == "no-session-id" else {"sessionId": "session_stub"})
    elif method == "session/set_mode" and mode == "mute-mode":
        refuse(i, "")
    elif method == "session/prompt" and mode == "mute-prompt":
        refuse(i, "")
    elif method == "session/prompt":
        sys.stderr.write("stub: scripted crash\n")
        sys.stderr.flush()
        sys.exit(3)
    else:
        reply(i, {})
