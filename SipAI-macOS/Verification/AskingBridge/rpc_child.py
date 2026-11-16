#!/usr/bin/env python3
"""A JSON-RPC child in the shape of codex's app-server and kimi's ACP
server: one JSON value per line on stdout, requests on stdin.

It first ASKS the client something (a server->client request), reports
the answer back as a notification, answers a `ping` request of the
client's, and exits 0 at EOF on stdin. With `--crlf` it ends its lines as
a terminal would. Nothing here is part of the app."""
import json, sys

crlf = "--crlf" in sys.argv[1:]
end = "\r\n" if crlf else "\n"

def send(obj):
    sys.stdout.write(json.dumps(obj) + end)
    sys.stdout.flush()

send({"jsonrpc": "2.0", "id": "srv-1", "method": "ask", "params": {"what": "may I?"}})
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    if msg.get("id") == "srv-1" and "result" in msg:
        send({"jsonrpc": "2.0", "method": "answered", "params": msg["result"]})
    elif msg.get("method") == "ping":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {"pong": msg.get("params")}})
sys.exit(0)
