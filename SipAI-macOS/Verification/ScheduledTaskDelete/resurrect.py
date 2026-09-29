#!/usr/bin/env python3
"""Does claude write its transcript again when the file is deleted while a
turn is in flight and the process is then stopped (SipAI's Stop: SIGTERM
to the child's process group)?

The reason a scheduled task's "Delete all" — and a session's Delete —
stops a running run and waits for it to END before removing its files.

Token-free: claude talks to a local endpoint that accepts the request and
never answers, under a throwaway CLAUDE_CONFIG_DIR, with a junk key.
Prints one line per order:

  <order>: exit <code>; file back: <True|False>; records <n> <types>
"""
import glob
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Hang(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        self.rfile.read(n)
        time.sleep(60)          # never answer: the turn stays in flight

    def do_GET(self):
        self.send_response(404)
        self.end_headers()

    def log_message(self, *args):
        pass


def trial(claude, port, order):
    home = tempfile.mkdtemp(prefix="sipai-taskdelete-")
    cfg, cwd = os.path.join(home, "cfg"), os.path.join(home, "cwd")
    os.makedirs(cfg)
    os.makedirs(cwd)
    env = dict(os.environ, CLAUDE_CONFIG_DIR=cfg,
               ANTHROPIC_BASE_URL=f"http://127.0.0.1:{port}",
               ANTHROPIC_API_KEY="sk-ant-harness-junk")
    env.pop("CLAUDE_CODE_CHILD_SESSION", None)
    p = subprocess.Popen([claude, "-p", "Reply with OK.", "--output-format",
                          "stream-json", "--verbose"],
                         cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    try:
        path = None
        for _ in range(300):
            found = glob.glob(os.path.join(cfg, "projects", "*", "*.jsonl"))
            if found:
                path = found[0]
                break
            time.sleep(0.05)
        if not path:
            print(f"{order}: no transcript appeared")
            return
        time.sleep(1.0)     # the turn is now waiting on the endpoint
        if order == "delete-then-stop":
            os.remove(path)
            os.killpg(p.pid, signal.SIGTERM)
        else:
            os.killpg(p.pid, signal.SIGTERM)
            p.wait(timeout=10)
            os.remove(path)
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
        time.sleep(2.0)
        back = os.path.exists(path)
        kinds = []
        if back:
            for line in open(path).read().splitlines():
                if line.strip().startswith("{"):
                    kinds.append(json.loads(line).get("type"))
        print(f"{order}: exit {p.returncode}; file back: {back}; records {len(kinds)} {kinds}")
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGKILL)
        shutil.rmtree(home, ignore_errors=True)


def main():
    claude = sys.argv[1]
    server = ThreadingHTTPServer(("127.0.0.1", 0), Hang)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    for order in ("delete-then-stop", "stop-then-delete"):
        trial(claude, server.server_address[1], order)


if __name__ == "__main__":
    main()
