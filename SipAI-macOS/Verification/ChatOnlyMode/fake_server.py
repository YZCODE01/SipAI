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
{"name": …, "input": {…}}), every later one with text. A LIST of such
objects scripts a turn step by step: the first request gets the first,
a request carrying k tool results the (k+1)-th, and text once the list
runs out (a request with no tool result after the first is a side
request, and gets text). The harness
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
`--anthropic-delay S` does the same for a Messages request answered with
text (a scripted tool call still comes at once), so a message can reach
claude while its answer is being written.

`--chat-script <file>` scripts the chat-completions (kimi) route turn by
turn. The file holds a list of {"marker": …, "steps": [ … ]}; a request
whose newest marked user message carries a marker is answered with the
step whose index is the number of tool results after that message, so a
turn walks its steps as its tools run, and anything past the last step
(or unmarked, like a side request for a title) is answered "OK". A step
is any of: {"text": …} streamed word by word; {"tool_calls": [{"id",
"name", "arguments": {…}}]}; {"think": …} before either; {"error":
{"status": n, "body": {…}}}; {"delay": S} before answering. In a text or
an argument, {PLAN_FILE} is the plan file the request names and {CWD}
the working folder the request names. `--chat-gap S` waits S seconds
between the chunks of a scripted text, so a client can be watched
receiving them one by one.

`--responses-script <file>` does the same for the Responses (codex) route:
the newest user message carrying a marker picks the entry, and the number
of tool outputs after it picks the step. A step is any of: {"text": …};
{"function_call": {"name", "arguments": {…}, "call_id"?, "namespace"?}}
(an MCP server's tool: "namespace": "mcp__<server>", "name": the tool); {"custom_tool_call":
{"name", "input", "call_id"?}} (codex's freeform `apply_patch`); {"delay": S}
before answering; {"error": {"status": n, "body": {…}}}. {CWD} is the
working folder codex's environment context names.

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
anthropic_delay = 0.0
think = False
refuse_fast = None
rate_limit_fast = None
chat_script = None
responses_script = None
chat_gap = 0.0
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
    elif a == "--anthropic-delay":
        anthropic_delay = float(args.pop(0))
    elif a == "--think":
        think = True
    elif a == "--chat-script":
        with open(args.pop(0)) as f:
            chat_script = json.load(f)
    elif a == "--responses-script":
        with open(args.pop(0)) as f:
            responses_script = json.load(f)
    elif a == "--chat-gap":
        chat_gap = float(args.pop(0))
    elif a == "--refuse-fast":
        refuse_fast = args.pop(0)
    elif a == "--rate-limit-fast":
        rate_limit_fast = args.pop(0)

os.makedirs(record_dir, exist_ok=True)
counter_lock = threading.Lock()
counter = [0]
responses_seen = [0]
messages_seen = [0]
anthropic_steps = (None if anthropic_script is None
                   else anthropic_script if isinstance(anthropic_script, list)
                   else [anthropic_script])


def tool_results_in(body):
    """How many tool results a Messages request carries: the steps of a
    scripted turn that have run."""
    if not isinstance(body, dict):
        return 0
    n = 0
    for message in body.get("messages") or []:
        content = message.get("content") if isinstance(message, dict) else None
        if isinstance(content, list):
            n += sum(1 for b in content if isinstance(b, dict) and b.get("type") == "tool_result")
    return n


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
                self._anthropic(body, speed="fast" if wants_fast else "standard")
        elif path.endswith("/responses"):
            step = scripted_responses_step(body) if responses_script else None
            if step is not None:
                _responses_step_impl(self, step, body, n)
            else:
                self._responses(n)
        elif path.endswith("/chat/completions"):
            step = scripted_chat_step(body) if chat_script else None
            if step is not None:
                self._chat_step(step, body)
            else:
                self._chat()
        elif path.endswith("/count_tokens"):
            self._json({"input_tokens": 10})
        else:
            self._json({"ok": True})

    def _anthropic(self, body, speed="standard"):
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
        step = None
        if anthropic_steps:
            ran = tool_results_in(body)
            if first:
                step = 0
            elif 0 < ran < len(anthropic_steps):
                step = ran
        if step is not None:
            tool = anthropic_steps[step]
            self._sse([
                ev("message_start", {"type": "message_start", "message": {
                    "id": "msg_fake_tool", "type": "message", "role": "assistant",
                    "model": "fake-model", "content": [], "stop_reason": None,
                    "stop_sequence": None,
                    "usage": {"input_tokens": 10, "output_tokens": 1, "speed": speed}}}),
            ] + thought(0) + [
                ev("content_block_start", {"type": "content_block_start", "index": first_index,
                                           "content_block": {"type": "tool_use",
                                                             "id": "toolu_harness_%d" % (step + 1),
                                                             "name": tool["name"],
                                                             "input": {}}}),
                ev("content_block_delta", {"type": "content_block_delta", "index": first_index,
                                           "delta": {"type": "input_json_delta",
                                                     "partial_json": json.dumps(tool["input"])}}),
                ev("content_block_stop", {"type": "content_block_stop", "index": first_index}),
                ev("message_delta", {"type": "message_delta",
                                     "delta": {"stop_reason": "tool_use", "stop_sequence": None},
                                     "usage": {"output_tokens": 1}}),
                ev("message_stop", {"type": "message_stop"}),
            ])
            return
        if anthropic_delay > 0:
            time.sleep(anthropic_delay)
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


def _text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content if isinstance(p, dict))
    return ""


def scripted_chat_step(body):
    """The scripted step this request is answered with, or None."""
    if not isinstance(body, dict):
        return None
    messages = body.get("messages") or []
    for i in range(len(messages) - 1, -1, -1):
        m = messages[i]
        if m.get("role") != "user":
            continue
        text = _text_of(m.get("content"))
        # The longest marker first: one marker may contain another.
        for entry in sorted(chat_script, key=lambda e: -len(e["marker"])):
            if entry["marker"] in text:
                results = sum(1 for later in messages[i + 1:] if later.get("role") == "tool")
                steps = entry["steps"]
                return steps[results] if results < len(steps) else None
    return None


PLAN_FILE_RE = __import__("re").compile(r"(/[^\s\"'`]*?/plans/[A-Za-z0-9._-]+\.md)")
CWD_RE = __import__("re").compile(r"(?:[Ww]orking directory|cwd)[^/]*(/[^\s\"'`]+)")
CODEX_CWD_RE = __import__("re").compile(r"<cwd>(/[^<]+)</cwd>")


def _fill(value, body_text, cwd_re=CWD_RE):
    if isinstance(value, str):
        if "{PLAN_FILE}" in value:
            m = PLAN_FILE_RE.search(body_text)
            value = value.replace("{PLAN_FILE}", m.group(1) if m else "/tmp/plan.md")
        if "{CWD}" in value:
            m = cwd_re.search(body_text)
            value = value.replace("{CWD}", m.group(1) if m else "/tmp")
        return value
    if isinstance(value, dict):
        return {k: _fill(v, body_text, cwd_re) for k, v in value.items()}
    if isinstance(value, list):
        return [_fill(v, body_text, cwd_re) for v in value]
    return value


def _chat_step_impl(handler, step, body):
    body_text = json.dumps(body)
    if step.get("delay"):
        time.sleep(float(step["delay"]))
    if "error" in step:
        err = step["error"]
        handler._json(err.get("body", {"error": {"message": "scripted failure"}}),
                      status=int(err.get("status", 500)))
        return
    base = {"id": "chatcmpl-fake", "object": "chat.completion.chunk",
            "created": int(time.time()), "model": "fake-model"}
    def chunk(delta, finish=None, usage=None):
        obj = dict(base)
        obj["choices"] = [{"index": 0, "delta": delta, "finish_reason": finish}]
        if usage:
            obj["usage"] = usage
        return "data: %s\n\n" % json.dumps(obj)
    # Streamed for real (chunked), so `--chat-gap` reaches the client as
    # gaps: the server is HTTP/1.1, and a body with neither a length nor
    # chunks never ends.
    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream")
    handler.send_header("Cache-Control", "no-cache")
    handler.send_header("Transfer-Encoding", "chunked")
    handler.end_headers()
    def emit(text):
        data = text.encode()
        handler.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
        handler.wfile.flush()
    if step.get("think"):
        emit(chunk({"role": "assistant", "reasoning_content": step["think"]}))
    finish = "stop"
    if "tool_calls" in step:
        calls = _fill(step["tool_calls"], body_text)
        for k, call in enumerate(calls):
            emit(chunk({"role": "assistant", "tool_calls": [{
                "index": k, "id": call.get("id", "call_%d" % k), "type": "function",
                "function": {"name": call["name"], "arguments": json.dumps(call.get("arguments", {}))}}]}))
        finish = "tool_calls"
    else:
        words = _fill(step.get("text", "OK"), body_text).split(" ")
        for k, w in enumerate(words):
            emit(chunk({"role": "assistant", "content": w + (" " if k < len(words) - 1 else "")}))
            if chat_gap > 0 and k < len(words) - 1:
                time.sleep(chat_gap)
    emit(chunk({}, finish=finish, usage={"prompt_tokens": 10, "completion_tokens": 1, "total_tokens": 11}))
    emit("data: [DONE]\n\n")
    handler.wfile.write(b"0\r\n\r\n")
    handler.wfile.flush()


Handler._chat_step = lambda self, step, body: _chat_step_impl(self, step, body)


def scripted_responses_step(body):
    """The scripted Responses step this request is answered with, or None."""
    if not isinstance(body, dict):
        return None
    items = body.get("input") or []
    for i in range(len(items) - 1, -1, -1):
        it = items[i]
        if it.get("type") != "message" or it.get("role") != "user":
            continue
        text = _text_of(it.get("content"))
        for entry in sorted(responses_script, key=lambda e: -len(e["marker"])):
            if entry["marker"] in text:
                results = sum(1 for later in items[i + 1:]
                              if later.get("type") in ("function_call_output", "custom_tool_call_output"))
                steps = entry["steps"]
                return steps[results] if results < len(steps) else None
    return None


def _responses_step_impl(handler, step, body, n):
    body_text = json.dumps(body)
    if step.get("delay"):
        time.sleep(float(step["delay"]))
    if "error" in step:
        err = step["error"]
        handler._json(err.get("body", {"error": {"message": "scripted failure"}}),
                      status=int(err.get("status", 500)))
        return
    def ev(obj):
        return "event: %s\ndata: %s\n\n" % (obj["type"], json.dumps(obj))
    if "function_call" in step:
        call = _fill(step["function_call"], body_text, CODEX_CWD_RE)
        item = {"id": "fc_%d" % n, "type": "function_call", "status": "completed",
                "call_id": call.get("call_id", "call_%d" % n), "name": call["name"],
                "arguments": json.dumps(call.get("arguments", {}))}
        # Codex files an MCP server's tools under a namespace
        # (`mcp__<server>`), and runs a call only when it names it.
        if call.get("namespace"):
            item["namespace"] = call["namespace"]
    elif "custom_tool_call" in step:
        call = _fill(step["custom_tool_call"], body_text, CODEX_CWD_RE)
        item = {"id": "ctc_%d" % n, "type": "custom_tool_call", "status": "completed",
                "call_id": call.get("call_id", "call_%d" % n), "name": call["name"],
                "input": call.get("input", "")}
    else:
        text = _fill(step.get("text", "OK"), body_text, CODEX_CWD_RE)
        item = {"id": "msg_%d" % n, "type": "message", "role": "assistant", "status": "completed",
                "content": [{"type": "output_text", "text": text, "annotations": []}]}
    events = [ev({"type": "response.created",
                  "response": {"id": "resp_%d" % n, "object": "response",
                               "created_at": int(time.time()), "status": "in_progress", "output": []}}),
              ev({"type": "response.output_item.added", "output_index": 0, "item": item})]
    if item["type"] == "message":
        events.append(ev({"type": "response.output_text.delta", "item_id": item["id"],
                          "output_index": 0, "content_index": 0,
                          "delta": item["content"][0]["text"]}))
    events.append(ev({"type": "response.output_item.done", "output_index": 0, "item": item}))
    events.append(ev({"type": "response.completed",
                      "response": {"id": "resp_%d" % n, "object": "response",
                                   "created_at": int(time.time()), "status": "completed",
                                   "output": [item],
                                   "usage": {"input_tokens": 10,
                                             "input_tokens_details": {"cached_tokens": 0},
                                             "output_tokens": 1,
                                             "output_tokens_details": {"reasoning_tokens": 0},
                                             "total_tokens": 11}}}))
    handler._sse(events)

server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
server.daemon_threads = True
print("PORT=%d" % server.server_address[1], flush=True)
try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
