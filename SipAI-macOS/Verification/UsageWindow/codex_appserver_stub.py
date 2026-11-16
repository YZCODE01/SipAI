#!/usr/bin/env python3
"""A stand-in for `codex app-server`, for the UsageWindow harness.

Speaks the JSON-RPC lines SipAI's app-server client sends: answers
`initialize`, ignores the `initialized` notification, and answers
`account/rateLimitResetCredit/consume` with the outcome named by
STUB_OUTCOME — `reset`, `nothingToReset`, `noCredit` or
`alreadyRedeemed` as codex's own outcomes; `error` as a JSON-RPC
refusal carrying a message; `silent` as an exit without an answer.
Every consume request's params are appended to STUB_RECORD as one JSON
line, so the harness can tell what SipAI sent.

Nothing here reaches OpenAI, and no reset is ever spent: the real
request is answered only by this file.

Usage:  codex_appserver_stub.py app-server
"""
import json
import os
import sys


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def main():
    outcome = os.environ.get("STUB_OUTCOME", "reset")
    record = os.environ.get("STUB_RECORD")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        method = message.get("method")
        request_id = message.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": request_id,
                  "result": {"userAgent": "codex-stub/0", "codexHome": "/nonexistent"}})
        elif method == "account/rateLimitResetCredit/consume":
            if record:
                with open(record, "a", encoding="utf-8") as f:
                    f.write(json.dumps(message.get("params")) + "\n")
            if outcome == "silent":
                return
            if outcome == "error":
                send({"jsonrpc": "2.0", "id": request_id,
                      "error": {"code": -32600, "message": "stub refusal: try again later"}})
            else:
                send({"jsonrpc": "2.0", "id": request_id, "result": {"outcome": outcome}})
        elif request_id is not None:
            send({"jsonrpc": "2.0", "id": request_id,
                  "error": {"code": -32601, "message": "method not found"}})


if __name__ == "__main__":
    main()
