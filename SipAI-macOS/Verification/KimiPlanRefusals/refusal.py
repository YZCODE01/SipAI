#!/usr/bin/env python3
"""A stand-in for Moonshot's Kimi Code API refusing a model the plan lacks.

Every POST (kimi's chat completions) is answered 403 with the sentence
Moonshot's error reference gives for it — "Your current subscription does
not have access to <model>." — naming the model the request asked for, in
an OpenAI-style error body. Requests are appended to <record-file> as one
JSON line each ({"path", "model"}). Nothing here reaches Moonshot.

Usage:  refusal.py <record-file>
The port is printed on stdout as `PORT=<n>` once bound.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            body = {}
        model = body.get("model", "")
        with open(RECORD, "a", encoding="utf-8") as f:
            f.write(json.dumps({"path": self.path, "model": model}) + "\n")
        payload = json.dumps({"error": {
            "message": f"Your current subscription does not have access to {model}.",
            "type": "permission_denied_error",
        }}).encode("utf-8")
        self.send_response(403)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    RECORD = sys.argv[1]
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(f"PORT={server.server_address[1]}", flush=True)
    server.serve_forever()
