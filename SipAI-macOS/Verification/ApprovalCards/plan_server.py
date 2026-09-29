#!/usr/bin/env python3
"""A fake Anthropic Messages endpoint for the ApprovalCards harness.

Answers claude's MAIN-LOOP requests (the ones that carry `tools`) with a
SEQUENCE of scripted tool_use blocks, one per request, then plain text
("OK") once the steps run out. Side requests (no tools) always get text,
so they never consume a step. In a step's string input, `{PLAN_FILE}` is
replaced by the plan file path found in the request (claude names it in
its plan-mode reminder). Every request is recorded as
<record-dir>/NNNN.json = {"path", "body"}. No token is ever spent:
nothing here reaches a provider.

Usage:  plan_server.py <record-dir> <steps.json>
The bound port is printed on stdout as `PORT=<n>`.
"""
import json
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

record_dir = sys.argv[1]
with open(sys.argv[2]) as f:
    steps = json.load(f)
os.makedirs(record_dir, exist_ok=True)
lock = threading.Lock()
counter = [0]
next_step = [0]
PLAN_PATH = re.compile(r'(/[^"\\\s]*?/plans/[A-Za-z0-9._-]+\.md)')


def fill(value, plan):
    if isinstance(value, str):
        return value.replace("{PLAN_FILE}", plan or "")
    if isinstance(value, dict):
        return {k: fill(v, plan) for k, v in value.items()}
    if isinstance(value, list):
        return [fill(v, plan) for v in value]
    return value


def event(name, obj):
    return "event: %s\ndata: %s\n\n" % (name, json.dumps(obj))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, content_type, payload):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()

    def do_GET(self):
        self._send("application/json", json.dumps(
            {"object": "list", "data": [{"id": "fake-model", "object": "model"}]}).encode())

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try:
            body = json.loads(raw)
        except Exception:
            body = {"_raw": raw.decode("utf-8", "replace")}
        with lock:
            counter[0] += 1
            n = counter[0]
        with open(os.path.join(record_dir, "%04d.json" % n), "w") as f:
            json.dump({"path": self.path, "body": body}, f)
        if not self.path.split("?")[0].endswith("/messages"):
            self._send("application/json", json.dumps({"input_tokens": 10}).encode())
            return
        found = PLAN_PATH.search(json.dumps(body))
        plan = found.group(1) if found else None
        step = None
        if isinstance(body, dict) and body.get("tools"):
            with lock:
                if next_step[0] < len(steps):
                    step = steps[next_step[0]]
                    next_step[0] += 1
        start = event("message_start", {"type": "message_start", "message": {
            "id": "msg_harness_%d" % n, "type": "message", "role": "assistant",
            "model": "fake-model", "content": [], "stop_reason": None,
            "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 1}}})
        if step is not None:
            block = {"type": "tool_use", "id": "toolu_harness_%d" % n,
                     "name": step["name"], "input": {}}
            delta = {"type": "input_json_delta",
                     "partial_json": json.dumps(fill(step["input"], plan))}
            stop = "tool_use"
        else:
            block = {"type": "text", "text": ""}
            delta = {"type": "text_delta", "text": "OK"}
            stop = "end_turn"
        events = [start,
                  event("content_block_start", {"type": "content_block_start", "index": 0,
                                                "content_block": block}),
                  event("content_block_delta", {"type": "content_block_delta", "index": 0,
                                                "delta": delta}),
                  event("content_block_stop", {"type": "content_block_stop", "index": 0}),
                  event("message_delta", {"type": "message_delta",
                                          "delta": {"stop_reason": stop, "stop_sequence": None},
                                          "usage": {"output_tokens": 1}}),
                  event("message_stop", {"type": "message_stop"})]
        self._send("text/event-stream", "".join(events).encode())


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
print("PORT=%d" % server.server_address[1], flush=True)
try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
