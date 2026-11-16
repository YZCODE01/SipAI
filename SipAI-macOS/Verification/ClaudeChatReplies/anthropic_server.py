#!/usr/bin/env python3
"""A local stand-in for Anthropic's Messages API, for main.swift.

Answers in the shapes Anthropic documents for current models: thinking
blocks ahead of the text, with an empty `thinking` field (the
`display: "omitted"` default), a `signature_delta`, `ping` events, an
`error` event mid-stream, and `GET /v1/models/{id}` carrying the model's
`max_tokens`. What each model id does is in MODELS and `messages` below.

Every request is logged; `GET /harness/log` hands the log back so the
harness can read what the client sent. Prints its port on one line, then
serves until its stdin closes. Binds 127.0.0.1 only.
"""
import http.server
import json
import sys
import threading
import time

# A model's published `max_tokens`; None is published as null, and a
# model missing here answers 404 the way an unknown id does.
MODELS = {
    "claude-thinks": 64000,
    "claude-thinks-cut": 32000,
    "claude-no-stream": 8192,
    "claude-null-max": None,
    "claude-overloaded": 4096,
    "claude-slow-lookup": 64000,
}

# Seconds a model's `GET /v1/models/{id}` takes to answer, so a Stop
# can land while the lookup is still on its way.
LOOKUP_DELAY = {"claude-slow-lookup": 1.0}

LOG = []
LOCK = threading.Lock()

THINKING = {"type": "thinking", "thinking": "", "signature": "EqQBharness"}


def message_start(model):
    return {"type": "message_start", "message": {
        "id": "msg_harness", "type": "message", "role": "assistant",
        "content": [], "model": model, "stop_reason": None,
        "stop_sequence": None, "usage": {"input_tokens": 25, "output_tokens": 1}}}


def thinking_block(index):
    return [
        {"type": "content_block_start", "index": index,
         "content_block": {"type": "thinking", "thinking": "", "signature": ""}},
        {"type": "content_block_delta", "index": index,
         "delta": {"type": "thinking_delta", "thinking": ""}},
        {"type": "content_block_delta", "index": index,
         "delta": {"type": "signature_delta", "signature": "EqQBharness"}},
        {"type": "content_block_stop", "index": index},
    ]


def text_block(index, pieces):
    events = [{"type": "content_block_start", "index": index,
               "content_block": {"type": "text", "text": ""}}]
    for piece in pieces:
        events.append({"type": "content_block_delta", "index": index,
                       "delta": {"type": "text_delta", "text": piece}})
    events.append({"type": "content_block_stop", "index": index})
    return events


def message_end(stop, output_tokens):
    return [{"type": "message_delta",
             "delta": {"stop_reason": stop, "stop_sequence": None},
             "usage": {"output_tokens": output_tokens}},
            {"type": "message_stop"}]


def whole(model, content, stop, output_tokens):
    return {"id": "msg_harness", "type": "message", "role": "assistant",
            "model": model, "content": content, "stop_reason": stop,
            "stop_sequence": None,
            "usage": {"input_tokens": 25, "output_tokens": output_tokens}}


def messages(model, stream):
    """(status, events or None, json body or None) for one request."""
    if model == "claude-thinks":
        if stream:
            return 200, ([message_start(model)] + thinking_block(0)
                         + [{"type": "ping"},
                            # A type the client has never seen: Anthropic's
                            # versioning policy says new ones may be added.
                            {"type": "harness_unknown_event", "payload": 1}]
                         + text_block(1, ["The answer", " is 42."])
                         + message_end("end_turn", 15)), None
        return 200, None, whole(model, [THINKING, {"type": "text", "text": "The answer is 42."}],
                                "end_turn", 15)
    if model == "claude-thinks-cut":
        if stream:
            return 200, ([message_start(model)] + thinking_block(0)
                         + message_end("max_tokens", 32000)), None
        return 200, None, whole(model, [THINKING], "max_tokens", 32000)
    if model == "claude-no-stream":
        if stream:
            return 400, None, {"type": "error", "error": {
                "type": "invalid_request_error",
                "message": "stream: Extra inputs are not permitted"}}
        return 200, None, whole(model, [THINKING,
                                        {"type": "text", "text": "Part one. "},
                                        {"type": "text", "text": "Part two."}],
                                "end_turn", 9)
    if model == "claude-overloaded":
        if stream:
            return 200, [message_start(model),
                         {"type": "error", "error": {"type": "overloaded_error",
                                                     "message": "Overloaded"}}], None
        return 529, None, {"type": "error", "error": {"type": "overloaded_error",
                                                      "message": "Overloaded"}}
    if stream:
        return 200, ([message_start(model)] + text_block(0, ["Plain reply."])
                     + message_end("end_turn", 3)), None
    return 200, None, whole(model, [{"type": "text", "text": "Plain reply."}], "end_turn", 3)


class Handler(http.server.BaseHTTPRequestHandler):
    def record(self, body):
        with LOCK:
            LOG.append({
                "method": self.command,
                "path": self.path,
                "x-api-key": self.headers.get("x-api-key"),
                "anthropic-version": self.headers.get("anthropic-version"),
                "body": body,
            })

    def send_json(self, status, obj):
        data = json.dumps(obj).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass  # the client gave the request up (a Stop)

    def do_GET(self):
        if self.path == "/harness/log":
            with LOCK:
                snapshot = list(LOG)
            self.send_json(200, snapshot)
            return
        self.record(None)
        prefix = "/v1/models/"
        if self.path.startswith(prefix):
            model = self.path[len(prefix):]
            if model in MODELS:
                time.sleep(LOOKUP_DELAY.get(model, 0))
                self.send_json(200, {"type": "model", "id": model, "display_name": model,
                                     "max_tokens": MODELS[model]})
                return
            self.send_json(404, {"type": "error", "error": {
                "type": "not_found_error", "message": "model: " + model}})
            return
        self.send_json(404, {"type": "error", "error": {"type": "not_found_error",
                                                        "message": "Not found"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw or b"null")
        except ValueError:
            body = None
        self.record(body)
        if self.path != "/v1/messages" or not isinstance(body, dict):
            self.send_json(404, {"type": "error", "error": {"type": "not_found_error",
                                                            "message": "Not found"}})
            return
        status, events, obj = messages(body.get("model"), body.get("stream") is True)
        if events is None:
            self.send_json(status, obj)
            return
        self.send_response(status)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        for event in events:
            self.wfile.write(("event: %s\ndata: %s\n\n"
                              % (event["type"], json.dumps(event))).encode())
            self.wfile.flush()

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
threading.Thread(target=server.serve_forever, daemon=True).start()
sys.stdin.read()
