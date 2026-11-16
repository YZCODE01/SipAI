#!/usr/bin/env python3
"""A stand-in Messages endpoint for ClaudeTurnFailure's "too long" section.

Claude decides whether a conversation is near its limit from the usage
the API reports, so this endpoint reports whatever context the harness
writes to <record-dir>/reported (a token count; 3000 when the file is
missing) on every reply to a request that still holds the old
conversation (HARNESS-OLD-CONVERSATION). After a compaction the old
conversation is gone, and the reply reports 3000.

  * a compaction request (claude's summary prompt) is answered with a
    summary;
  * a request holding the old conversation AND the changed instructions
    (HARNESS-INSTRUCTIONS-V2) is refused the way the API refuses a
    prompt over the model's limit: a 400 "prompt is too long";
  * anything else is answered "OK".

Each request is recorded as one line of <record-dir>/requests.jsonl:
{"kind", "bytes", "old", "new", "marks"} — "marks" the HARNESS-* words of
an edited message's section that the request holds. No token is ever
spent: nothing here reaches a provider.

Usage: too_long_server.py <record-dir>   (prints PORT=<n> once bound)
"""
import json
import os
import sys
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler

record_dir = sys.argv[1]
lock = threading.Lock()


def reported_context():
    try:
        with open(os.path.join(record_dir, "reported")) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return 3000


def newest_user_text(body):
    for message in reversed(body.get("messages") or []):
        if message.get("role") != "user":
            continue
        content = message.get("content")
        if isinstance(content, str):
            return content
        return "\n".join(block.get("text", "") for block in content or []
                         if isinstance(block, dict) and block.get("type") == "text")
    return ""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("content-length") or 0))
        try:
            body = json.loads(raw)
        except ValueError:
            body = {}
        text = raw.decode("utf-8", "replace")
        old = "HARNESS-OLD-CONVERSATION" in text
        new = "HARNESS-INSTRUCTIONS-V2" in text
        newest = newest_user_text(body)
        if not self.path.split("?")[0].endswith("/messages"):
            kind = "other"
            self.send_response(404)
            self.end_headers()
        elif "Respond with TEXT ONLY" in newest:
            kind = "compact"
            self.reply("<analysis>a</analysis>\n<summary>The earlier conversation.</summary>", 3000, body)
        elif old and new:
            kind = "refused"
            payload = json.dumps({"type": "error", "error": {
                "type": "invalid_request_error",
                "message": "prompt is too long: %d tokens > %d maximum"
                           % (reported_context() + 150000, reported_context() + 60000)}}).encode()
            self.send_response(400)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        else:
            kind = "ok"
            self.reply("OK", reported_context() if old else 3000, body)
        with lock:
            with open(os.path.join(record_dir, "requests.jsonl"), "a") as f:
                marks = [m for m in ("HARNESS-SECOND-MESSAGE", "HARNESS-EDITED") if m in text]
                f.write(json.dumps({"kind": kind, "bytes": len(raw), "old": old, "new": new,
                                    "marks": marks}) + "\n")

    def reply(self, text, context, body):
        def event(name, obj):
            return "event: %s\ndata: %s\n\n" % (name, json.dumps(obj))
        usage = {"input_tokens": 2, "cache_creation_input_tokens": 0,
                 "cache_read_input_tokens": max(0, context - 2), "output_tokens": 5}
        data = "".join([
            event("message_start", {"type": "message_start", "message": {
                "id": "msg_harness", "type": "message", "role": "assistant",
                "model": body.get("model") or "harness-model", "content": [],
                "stop_reason": None, "stop_sequence": None, "usage": usage}}),
            event("content_block_start", {"type": "content_block_start", "index": 0,
                                          "content_block": {"type": "text", "text": ""}}),
            event("content_block_delta", {"type": "content_block_delta", "index": 0,
                                          "delta": {"type": "text_delta", "text": text}}),
            event("content_block_stop", {"type": "content_block_stop", "index": 0}),
            event("message_delta", {"type": "message_delta",
                                    "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                    "usage": {"output_tokens": 5}}),
            event("message_stop", {"type": "message_stop"}),
        ]).encode()
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


server = HTTPServer(("127.0.0.1", 0), Handler)
print("PORT=%d" % server.server_address[1], flush=True)
server.serve_forever()
