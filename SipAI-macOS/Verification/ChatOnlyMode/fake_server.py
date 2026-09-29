#!/usr/bin/env python3
"""A fake model endpoint for the ChatOnlyMode harness.

Speaks the three wire dialects the agent CLIs use, records every
request it receives as one JSON file, and answers a minimal streamed
reply so the CLI completes its turn. No token is ever spent: nothing
here reaches a provider.

  POST …/v1/messages          Anthropic Messages (claude)       → SSE
  POST …/responses            OpenAI Responses (codex)          → SSE
  POST …/chat/completions     OpenAI chat completions (kimi)    → SSE

Usage:  fake_server.py <record-dir> [--port N] [--script <file>]
                       [--anthropic-script <file>] [--chat-delay S]
                       [--responses-delay S]
                       [--think] [--refuse-fast <reason>]
                       [--rate-limit-fast <seconds>]

Each request lands in <record-dir>/NNNN.json as
  {"method", "path", "headers", "body"}   (body parsed as JSON)
and the port is printed on stdout as `PORT=<n>` once bound.

A script file, when given, makes the Responses route emit ONE tool
call on its first request and text on every later one — the harness
uses it to prove codex refuses `apply_patch` under read-only/never.
The file holds the JSON of the function_call item to emit.

An Anthropic script does the same for the Messages route: its first
request is answered with ONE tool_use block (the file holds
{"name": …, "input": {…}}), every later one with text. The harness
uses it to prove a Chat only turn's web tools are pre-approved — the
tool actually runs — rather than refused for want of an approver.

`--refuse-fast <reason>` answers a Messages request that asks for fast
mode (`"speed": "fast"`) the way the API does for an account whose usage
credits are unavailable: a 429 carrying
`anthropic-ratelimit-unified-overage-disabled-reason: <reason>`. Claude
then re-sends the call at standard speed. `--rate-limit-fast <seconds>`
answers it with a plain 429 and that `retry-after` instead: a long one
puts claude's fast mode into its cooldown (the call re-sent at standard
speed), a short one is retried as fast. Every Messages reply states the
speed it was served at in its usage (`"speed"`), as the API does.

`--chat-delay S` and `--responses-delay S` make the chat-completions
(kimi) and Responses (codex) routes wait S seconds before answering, so
a turn can be caught mid-flight — the abort probe, and the
ExternalTurnWatch harness watching a turn another process runs.

`--think` opens every reply with a THOUGHT, in each dialect's own shape:
a `thinking` block (Messages), a `reasoning` item with a summary
(Responses), `reasoning_content` (chat completions) — the text is
HARNESS-THOUGHT. The harness uses it to follow a thought from each CLI's
wire to its stdout and its transcript.
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

record_dir = sys.argv[1]
port = 0
script = None
anthropic_script = None
chat_delay = 0.0
responses_delay = 0.0
think = False
refuse_fast = None
rate_limit_fast = None
THOUGHT = "HARNESS-THOUGHT: weighing the question before answering."
args = sys.argv[2:]
while args:
    a = args.pop(0)
    if a == "--port":
        port = int(args.pop(0))
    elif a == "--script":
        with open(args.pop(0)) as f:
            script = json.load(f)
    elif a == "--anthropic-script":
        with open(args.pop(0)) as f:
            anthropic_script = json.load(f)
    elif a == "--chat-delay":
        # Seconds the chat-completions route sleeps before answering,
        # so a turn can be caught mid-flight (the abort probe).
        chat_delay = float(args.pop(0))
    elif a == "--responses-delay":
        responses_delay = float(args.pop(0))
    elif a == "--think":
        think = True
    elif a == "--refuse-fast":
        refuse_fast = args.pop(0)
    elif a == "--rate-limit-fast":
        rate_limit_fast = args.pop(0)

os.makedirs(record_dir, exist_ok=True)
counter_lock = threading.Lock()
counter = [0]
responses_seen = [0]
messages_seen = [0]


def record(method, path, headers, body):
    with counter_lock:
        counter[0] += 1
        n = counter[0]
    entry = {"method": method, "path": path,
             "headers": {k: v for k, v in headers.items()},
             "body": body}
    with open(os.path.join(record_dir, "%04d.json" % n), "w") as f:
        json.dump(entry, f)
    return n


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        pass

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            return json.loads(raw.decode("utf-8")) if raw else None
        except Exception:
            return {"_raw": raw.decode("utf-8", "replace")}

    def _sse(self, events):
        payload = "".join(events).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()

    def _json(self, obj, status=200, headers=()):
        payload = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()

    def do_GET(self):
        body = self._read_body()
        record("GET", self.path, self.headers, body)
        if self.path.rstrip("/").endswith("/models"):
            self._json({"object": "list", "data": [{"id": "fake-model", "object": "model"}]})
        else:
            self._json({"ok": True})

    def do_POST(self):
        body = self._read_body()
        n = record("POST", self.path, self.headers, body)
        path = self.path.split("?")[0]
        if path.endswith("/messages"):
            wants_fast = isinstance(body, dict) and body.get("speed") == "fast"
            if wants_fast and rate_limit_fast:
                self._json({"type": "error",
                            "error": {"type": "rate_limit_error", "message": "rate limited"}},
                           status=429, headers=[("retry-after", rate_limit_fast)])
            elif wants_fast and refuse_fast:
                self._json({"type": "error",
                            "error": {"type": "rate_limit_error",
                                      "message": "Fast mode requires usage credits"}},
                           status=429,
                           headers=[("anthropic-ratelimit-unified-overage-disabled-reason",
                                     refuse_fast)])
            else:
                self._anthropic(speed="fast" if wants_fast else "standard")
        elif path.endswith("/responses"):
            self._responses(n)
        elif path.endswith("/chat/completions"):
            self._chat()
        elif path.endswith("/count_tokens"):
            self._json({"input_tokens": 10})
        else:
            self._json({"ok": True})

    def _anthropic(self, speed="standard"):
        def ev(name, obj):
            return "event: %s\ndata: %s\n\n" % (name, json.dumps(obj))

        def thought(index):
            if not think:
                return []
            return [
                ev("content_block_start", {"type": "content_block_start", "index": index,
                                           "content_block": {"type": "thinking", "thinking": "", "signature": ""}}),
                ev("content_block_delta", {"type": "content_block_delta", "index": index,
                                           "delta": {"type": "thinking_delta", "thinking": THOUGHT}}),
                ev("content_block_delta", {"type": "content_block_delta", "index": index,
                                           "delta": {"type": "signature_delta", "signature": "c2lnbmF0dXJl"}}),
                ev("content_block_stop", {"type": "content_block_stop", "index": index}),
            ]
        first_index = 1 if think else 0
        with counter_lock:
            messages_seen[0] += 1
            first = messages_seen[0] == 1
        if anthropic_script is not None and first:
            self._sse([
                ev("message_start", {"type": "message_start", "message": {
                    "id": "msg_fake_tool", "type": "message", "role": "assistant",
                    "model": "fake-model", "content": [], "stop_reason": None,
                    "stop_sequence": None,
                    "usage": {"input_tokens": 10, "output_tokens": 1, "speed": speed}}}),
            ] + thought(0) + [
                ev("content_block_start", {"type": "content_block_start", "index": first_index,
                                           "content_block": {"type": "tool_use",
                                                             "id": "toolu_harness_1",
                                                             "name": anthropic_script["name"],
                                                             "input": {}}}),
                ev("content_block_delta", {"type": "content_block_delta", "index": first_index,
                                           "delta": {"type": "input_json_delta",
                                                     "partial_json": json.dumps(anthropic_script["input"])}}),
                ev("content_block_stop", {"type": "content_block_stop", "index": first_index}),
                ev("message_delta", {"type": "message_delta",
                                     "delta": {"stop_reason": "tool_use", "stop_sequence": None},
                                     "usage": {"output_tokens": 1}}),
                ev("message_stop", {"type": "message_stop"}),
            ])
            return
        self._sse([
            ev("message_start", {"type": "message_start", "message": {
                "id": "msg_fake", "type": "message", "role": "assistant",
                "model": "fake-model", "content": [], "stop_reason": None,
                "stop_sequence": None,
                "usage": {"input_tokens": 10, "output_tokens": 1, "speed": speed}}}),
        ] + thought(0) + [
            ev("content_block_start", {"type": "content_block_start", "index": first_index,
                                       "content_block": {"type": "text", "text": ""}}),
            ev("content_block_delta", {"type": "content_block_delta", "index": first_index,
                                       "delta": {"type": "text_delta", "text": "OK"}}),
            ev("content_block_stop", {"type": "content_block_stop", "index": first_index}),
            ev("message_delta", {"type": "message_delta",
                                 "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                 "usage": {"output_tokens": 1}}),
            ev("message_stop", {"type": "message_stop"}),
        ])

    def _responses(self, n):
        if responses_delay > 0:
            time.sleep(responses_delay)
        def ev(obj):
            return "event: %s\ndata: %s\n\n" % (obj["type"], json.dumps(obj))
        with counter_lock:
            responses_seen[0] += 1
            first = responses_seen[0] == 1
        if script is not None and first:
            item = dict(script)
            item.setdefault("id", "fc_fake")
            item.setdefault("status", "completed")
            output = [item]
        else:
            output = [{"id": "msg_fake", "type": "message", "role": "assistant",
                       "status": "completed",
                       "content": [{"type": "output_text", "text": "OK", "annotations": []}]}]
        if think:
            output = [{"id": "rs_fake_%d" % n, "type": "reasoning",
                       "summary": [{"type": "summary_text", "text": "**Weighing it**\n\n" + THOUGHT}],
                       "encrypted_content": None}] + output
        events = [ev({"type": "response.created",
                      "response": {"id": "resp_fake", "object": "response",
                                   "created_at": int(time.time()),
                                   "status": "in_progress", "output": []}})]
        for i, item in enumerate(output):
            events.append(ev({"type": "response.output_item.added",
                              "output_index": i, "item": item}))
            if item["type"] == "reasoning":
                text = item["summary"][0]["text"]
                events.append(ev({"type": "response.reasoning_summary_part.added", "item_id": item["id"],
                                  "output_index": i, "summary_index": 0,
                                  "part": {"type": "summary_text", "text": ""}}))
                events.append(ev({"type": "response.reasoning_summary_text.delta", "item_id": item["id"],
                                  "output_index": i, "summary_index": 0, "delta": text}))
                events.append(ev({"type": "response.reasoning_summary_text.done", "item_id": item["id"],
                                  "output_index": i, "summary_index": 0, "text": text}))
                events.append(ev({"type": "response.reasoning_summary_part.done", "item_id": item["id"],
                                  "output_index": i, "summary_index": 0, "part": item["summary"][0]}))
            if item["type"] == "message":
                events.append(ev({"type": "response.output_text.delta", "item_id": item["id"],
                                  "output_index": i, "content_index": 0, "delta": "OK"}))
            events.append(ev({"type": "response.output_item.done",
                              "output_index": i, "item": item}))
        events.append(ev({"type": "response.completed",
                          "response": {"id": "resp_fake", "object": "response",
                                       "created_at": int(time.time()),
                                       "status": "completed", "output": output,
                                       "usage": {"input_tokens": 10,
                                                 "input_tokens_details": {"cached_tokens": 0},
                                                 "output_tokens": 1,
                                                 "output_tokens_details": {"reasoning_tokens": 0},
                                                 "total_tokens": 11}}}))
        self._sse(events)

    def _chat(self):
        if chat_delay > 0:
            time.sleep(chat_delay)
        def chunk(obj):
            return "data: %s\n\n" % json.dumps(obj)
        base = {"id": "chatcmpl-fake", "object": "chat.completion.chunk",
                "created": int(time.time()), "model": "fake-model"}
        first = dict(base)
        first["choices"] = [{"index": 0, "delta": {"role": "assistant", "content": "OK"},
                             "finish_reason": None}]
        last = dict(base)
        last["choices"] = [{"index": 0, "delta": {}, "finish_reason": "stop"}]
        last["usage"] = {"prompt_tokens": 10, "completion_tokens": 1, "total_tokens": 11}
        chunks = [chunk(first), chunk(last), "data: [DONE]\n\n"]
        if think:
            reasoning = dict(base)
            reasoning["choices"] = [{"index": 0, "delta": {"role": "assistant", "reasoning_content": THOUGHT},
                                     "finish_reason": None}]
            chunks = [chunk(reasoning)] + chunks
        self._sse(chunks)


server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
server.daemon_threads = True
print("PORT=%d" % server.server_address[1], flush=True)
try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
