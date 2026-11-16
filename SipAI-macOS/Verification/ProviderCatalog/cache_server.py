#!/usr/bin/env python3
"""A local stand-in for a model provider, for main.swift's section 10.

Every request — GET or POST — is answered with a small JSON body and
`Cache-Control: public, max-age=3600`, the answer a web cache keeps, so a
client that caches has something to keep. Prints its port on one line,
then serves until its stdin closes.
"""
import http.server
import json
import socketserver
import sys
import threading


class Handler(http.server.BaseHTTPRequestHandler):
    def answer(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        body = json.dumps({"object": "list", "data": [{"id": "harness-model"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "public, max-age=3600")
        self.end_headers()
        self.wfile.write(body)

    do_GET = answer
    do_POST = answer

    def log_message(self, *args):
        pass


server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
threading.Thread(target=server.serve_forever, daemon=True).start()
sys.stdin.read()
