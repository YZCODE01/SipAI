#!/usr/bin/env python3
"""A stand-in MCP server whose tools ask the user for input.

Speaks MCP over stdio (one JSON-RPC message per line). Each `ask_*` tool
sends the client an `elicitation/create` while its call is open, and
answers the call with what came back, so a harness reads the user's
answer in the tool's result:

    ELICITED {"action": …, "content": …}      (or {"error": …})

  write_note    no annotations: codex asks before running it
  read_note     read only: runs without asking
  ask_form      a form: a required text with a description, a titled
                single choice, a legacy enum with enumNames, a yes/no with
                a default, an integer from 1 to 9, a multiple choice
  ask_confirm   a form with no fields (a yes-or-no)
  ask_url       a link to open (URL mode)

Usage:  mcp_form_server.py <log-file>
Every message the client sends is appended to <log-file>, one per line
("IN <json>"), so a harness can read the client's `initialize`
capabilities and the answers. No network, nothing outside the log file.
"""
import itertools
import json
import sys
import threading

LOG = open(sys.argv[1], "a") if len(sys.argv) > 1 else None
out_lock = threading.Lock()
pending = {}
ids = itertools.count(1000)


def log(text):
    if LOG:
        LOG.write(text + "\n")
        LOG.flush()


def send(obj):
    with out_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


READ_ONLY = {"readOnlyHint": True}
NO_INPUT = {"type": "object", "properties": {}}
TOOLS = [
    {"name": "write_note", "description": "Write a note.", "inputSchema": NO_INPUT},
    {"name": "read_note", "description": "Read a note.", "annotations": READ_ONLY,
     "inputSchema": NO_INPUT},
    {"name": "ask_form", "description": "Ask the user a few things.", "annotations": READ_ONLY,
     "inputSchema": NO_INPUT},
    {"name": "ask_confirm", "description": "Ask the user to confirm.", "annotations": READ_ONLY,
     "inputSchema": NO_INPUT},
    {"name": "ask_url", "description": "Ask the user to open a link.", "annotations": READ_ONLY,
     "inputSchema": NO_INPUT},
]

FORM = {
    "type": "object",
    "properties": {
        "name": {"type": "string", "title": "Your name",
                 "description": "What should the report call you?"},
        "color": {"type": "string", "title": "Favourite colour",
                  "oneOf": [{"const": "red", "title": "Red"}, {"const": "blue", "title": "Blue"}]},
        "size": {"type": "string", "title": "Size", "enum": ["s", "m", "l"],
                 "enumNames": ["Small", "Medium", "Large"]},
        "subscribe": {"type": "boolean", "title": "Subscribe", "default": False},
        "count": {"type": "integer", "title": "How many", "minimum": 1, "maximum": 9},
        "tags": {"type": "array", "title": "Tags",
                 "items": {"anyOf": [{"const": "a", "title": "Alpha"},
                                     {"const": "b", "title": "Beta"},
                                     {"const": "c", "title": "Gamma"}]},
                 "maxItems": 2},
    },
    "required": ["name", "color"],
}


def elicit(params, reply_to):
    rid = next(ids)
    done = threading.Event()
    box = {}
    pending[rid] = (done, box)
    send({"jsonrpc": "2.0", "id": rid, "method": "elicitation/create", "params": params})
    done.wait(600)
    msg = box.get("msg", {"error": "no answer"})
    answer = msg.get("result", {"error": msg.get("error")})
    send({"jsonrpc": "2.0", "id": reply_to,
          "result": {"content": [{"type": "text",
                                  "text": "ELICITED " + json.dumps(answer, sort_keys=True)}]}})


ASKS = {
    "ask_form": {"mode": "form", "message": "Tell the report about you", "requestedSchema": FORM},
    "ask_confirm": {"mode": "form", "message": "Send the report now?", "requestedSchema": NO_INPUT},
    "ask_url": {"mode": "url", "message": "Sign in to the report service",
                "url": "https://example.com/sign-in?step=1", "elicitationId": "harness-link-1"},
}

for line in sys.stdin:
    try:
        msg = json.loads(line)
    except Exception:
        continue
    log("IN " + json.dumps(msg, sort_keys=True))
    if "method" not in msg and msg.get("id") in pending:
        done, box = pending.pop(msg["id"])
        box["msg"] = msg
        done.set()
        continue
    method, mid = msg.get("method"), msg.get("id")
    if method == "initialize":
        version = (msg.get("params") or {}).get("protocolVersion", "2025-06-18")
        send({"jsonrpc": "2.0", "id": mid,
              "result": {"protocolVersion": version, "capabilities": {"tools": {}},
                         "serverInfo": {"name": "harness-forms", "version": "1"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
    elif method == "tools/call":
        name = (msg.get("params") or {}).get("name")
        if name in ASKS:
            threading.Thread(target=elicit, args=(ASKS[name], mid), daemon=True).start()
        else:
            send({"jsonrpc": "2.0", "id": mid,
                  "result": {"content": [{"type": "text",
                                          "text": "WROTE" if name == "write_note" else "READ"}]}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
