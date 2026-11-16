#!/usr/bin/env python3
"""A stand-in Anthropic Messages endpoint for the SessionRewind harness.

Every reply has an id of its own and says REPLY-<n>, and every request
body is recorded in <record-dir>/NNNN.json as {"path", "body"}. Token-free:
nothing here reaches a provider.

The harness's shared stand-in (ChatOnlyMode/fake_server.py) answers every
call with one fixed message id, and claude merges assistant records that
share a message id when it rebuilds a conversation — so a reply of a turn a
rewind dropped would ride along with a kept one, and the request the
harness reads would not be the conversation claude holds.

Usage: anthropic_echo.py <record-dir>   (prints PORT=<n> once bound)
"""
import itertools
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

record_dir = sys.argv[1]
os.makedirs(record_dir, exist_ok=True)
counter = itertools.count(1)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"data":[{"id":"claude-haiku-4-5","type":"model"}]}')

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        n = next(counter)
        with open(os.path.join(record_dir, "%04d.json" % n), "w") as fh:
            json.dump({"path": self.path, "body": body}, fh)
        if "count_tokens" in self.path:
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"input_tokens": 10}')
            return

        def event(name, obj):
            return "event: %s\ndata: %s\n\n" % (name, json.dumps(obj))

        stream = "".join([
            event("message_start", {"type": "message_start", "message": {
                "id": "msg_echo_%d" % n, "type": "message", "role": "assistant",
                "model": body.get("model", "claude-haiku-4-5"), "content": [],
                "stop_reason": None, "stop_sequence": None,
                "usage": {"input_tokens": 10, "output_tokens": 1}}}),
            event("content_block_start", {"type": "content_block_start", "index": 0,
                                          "content_block": {"type": "text", "text": ""}}),
            event("content_block_delta", {"type": "content_block_delta", "index": 0,
                                          "delta": {"type": "text_delta", "text": "REPLY-%d" % n}}),
            event("content_block_stop", {"type": "content_block_stop", "index": 0}),
            event("message_delta", {"type": "message_delta",
                                    "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                    "usage": {"output_tokens": 2}}),
            event("message_stop", {"type": "message_stop"}),
        ])
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        self.wfile.write(stream.encode())


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print("PORT=%d" % server.server_address[1], flush=True)
server.serve_forever()
