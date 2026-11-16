#!/usr/bin/env python3
"""SipAI permission-prompt MCP server.

Stdio MCP server that Claude Code spawns via ``--permission-prompt-tool
mcp__sipai__approve``.  When Claude Code needs to approve a tool call, it
invokes the ``approve`` tool on this server, which forwards the request to
the main SipAI process over a Unix domain socket and returns SipAI's
verdict back to Claude Code.

Stdlib-only.  Speaks newline-delimited JSON-RPC 2.0 on stdio (the MCP
stdio transport) and newline-delimited JSON on the Unix socket (the SipAI
wire protocol defined in ``mcp_design.md``).

All diagnostic output goes to stderr so it never contaminates the MCP
JSON-RPC channel on stdout.

Run with ``--permission-context`` it is something else: a Claude Code
``PermissionRequest`` hook.  Claude Code runs the hook beside the approve
tool above — both at once, whichever answers first decides — and hands it
what the approve tool is never given: its own suggestions for the call
(``permission_suggestions``: the rule its terminal offers as "don't ask
again for …").  The hook passes them to SipAI over the same socket and
decides nothing: it prints nothing and exits 0 whatever happens, so the
approve tool's answer is the one Claude Code takes.

Run with ``--elicitation`` it is a Claude Code ``Elicitation`` hook: an MCP
server asks the user for input mid-call (a form, or a link to open).
Under ``-p`` Claude Code has no dialog for one and cancels it unless a hook
answers.  The hook hands the request to SipAI over the same socket, waits
for the user's answer for as long as they take, and prints it as the
hook's output.  When SipAI cannot be reached it prints nothing, and Claude
Code answers the server as it would without the hook.
"""

from __future__ import annotations

import json
import os
import socket
import sys
import traceback
import uuid

# Protocol version to advertise in ``initialize``.  Clients may request a
# different version; we echo back whatever they sent when it's a string
# (MCP is permissive about this).
_DEFAULT_MCP_PROTOCOL_VERSION = "2024-11-05"

_SIPAI_WIRE_VERSION = 1
_TOOL_NAME = "approve"
_SERVER_NAME = "sipai"
_SERVER_VERSION = "0.1.0"

_DISCONNECT_MSG = "SipAI is not running — cannot approve tool calls."


def _log(msg: str) -> None:
    """Write a diagnostic line to stderr.  Stdout is reserved for JSON-RPC."""
    try:
        sys.stderr.write(f"[sipai-approver] {msg}\n")
        sys.stderr.flush()
    except Exception:
        pass


# ── Unix socket client ────────────────────────────────────────────────────

def _socket_path() -> str | None:
    """Return the SipAI approval socket path, or None if unconfigured."""
    return os.environ.get("SIPAI_APPROVER_SOCKET") or None


def _ask_sipai(tool_name: str, tool_input: dict) -> dict:
    """Send an approval request to SipAI and return its response dict.

    On any connection error returns a synthetic deny response so the
    caller can map it to a ``behavior: deny`` verdict.
    """
    sock_path = _socket_path()
    if not sock_path:
        return {"verdict": "deny", "message": _DISCONNECT_MSG}

    session_env = os.environ.get("SIPAI_SESSION_ID", "") or ""
    session_id, task_uuid = _split_session_id(session_env)

    request = {
        "v": _SIPAI_WIRE_VERSION,
        "kind": "approval_request",
        "request_id": uuid.uuid4().hex,
        "session_id": session_id,
        "task_uuid": task_uuid,
        "tool_name": tool_name,
        "tool_input": tool_input if isinstance(tool_input, dict) else {},
    }

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(sock_path)
        except (FileNotFoundError, ConnectionRefusedError, OSError) as e:
            _log(f"connect({sock_path}) failed: {e}")
            return {"verdict": "deny", "message": _DISCONNECT_MSG}
        try:
            payload = (json.dumps(request, ensure_ascii=False) + "\n").encode("utf-8")
            sock.sendall(payload)
            sock.shutdown(socket.SHUT_WR)
            # Read until newline, for as long as the user takes.  Claude
            # Code itself gives up on a silent call at its MCP idle limit;
            # SipAI raises that limit in this server's config entry.
            buf = bytearray()
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buf.extend(chunk)
                if b"\n" in buf:
                    break
        finally:
            try:
                sock.close()
            except Exception:
                pass
    except Exception as e:
        _log(f"socket I/O failed: {e}")
        return {"verdict": "deny", "message": _DISCONNECT_MSG}

    line = bytes(buf).split(b"\n", 1)[0].decode("utf-8", errors="replace").strip()
    if not line:
        return {"verdict": "deny", "message": _DISCONNECT_MSG}
    try:
        resp = json.loads(line)
    except json.JSONDecodeError as e:
        _log(f"invalid JSON from SipAI: {e}")
        return {"verdict": "deny", "message": "SipAI sent an invalid response."}
    if not isinstance(resp, dict):
        return {"verdict": "deny", "message": "SipAI sent an invalid response."}
    return resp


_UUID_LEN_WITH_DASHES = 36
_UUID_LEN_NO_DASHES = 32


def _split_session_id(raw: str) -> tuple[str | None, str | None]:
    """Decide whether ``SIPAI_SESSION_ID`` is a Claude UUID or a task uuid.

    Returns ``(session_id, task_uuid)``; exactly one is non-None when
    ``raw`` is non-empty, or both are None when unset.
    """
    if not raw:
        return None, None
    # A real Claude Code session UUID is a canonical UUIDv4 with dashes.
    if len(raw) == _UUID_LEN_WITH_DASHES and raw.count("-") == 4:
        try:
            uuid.UUID(raw)
            return raw, None
        except ValueError:
            pass
    # 32-char hex (uuid4().hex) — our SipAI task_uuid format.
    if len(raw) == _UUID_LEN_NO_DASHES:
        try:
            int(raw, 16)
            return None, raw
        except ValueError:
            pass
    # Anything else — treat opaquely as a task_uuid so routing still works.
    return None, raw


# ── MCP JSON-RPC plumbing ─────────────────────────────────────────────────

def _send(obj: dict) -> None:
    """Write one JSON-RPC message as a single line on stdout."""
    line = json.dumps(obj, ensure_ascii=False)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def _result(req_id, result: dict) -> None:
    _send({"jsonrpc": "2.0", "id": req_id, "result": result})


def _error(req_id, code: int, message: str) -> None:
    _send({"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}})


# ── MCP method handlers ───────────────────────────────────────────────────

def _handle_initialize(req_id, params: dict) -> None:
    requested_version = params.get("protocolVersion") if isinstance(params, dict) else None
    version = requested_version if isinstance(requested_version, str) else _DEFAULT_MCP_PROTOCOL_VERSION
    _result(req_id, {
        "protocolVersion": version,
        "capabilities": {"tools": {}},
        "serverInfo": {"name": _SERVER_NAME + "-approver", "version": _SERVER_VERSION},
    })


def _tool_schema() -> dict:
    """JSON schema for the ``approve`` tool's input.

    Claude Code passes the pending tool call as ``tool_name`` + ``input``
    (and sometimes ``tool_use_id``).  We accept additional properties so
    the schema doesn't reject future fields.
    """
    return {
        "type": "object",
        "properties": {
            "tool_name": {"type": "string", "description": "Name of the tool Claude wants to use."},
            "input": {"type": "object", "description": "Input Claude wants to pass to that tool."},
            "tool_use_id": {"type": "string", "description": "Claude's internal tool-use id."},
        },
        "required": ["tool_name", "input"],
        "additionalProperties": True,
    }


def _handle_tools_list(req_id) -> None:
    _result(req_id, {
        "tools": [
            {
                "name": _TOOL_NAME,
                "description": (
                    "Ask the user (via SipAI) whether Claude Code may use the proposed "
                    "tool with the given input.  Returns a JSON-stringified object of "
                    "shape {\"behavior\": \"allow\"|\"deny\", \"message\"?: str, "
                    "\"updatedInput\"?: object}."
                ),
                "inputSchema": _tool_schema(),
            }
        ]
    })


def _extract_tool_call(arguments: dict) -> tuple[str, dict]:
    """Pull (tool_name, tool_input) out of the tool-call arguments.

    Claude Code's exact shape may vary; be defensive.
    """
    if not isinstance(arguments, dict):
        return "", {}
    tool_name = arguments.get("tool_name") or arguments.get("toolName") or ""
    tool_input = arguments.get("input") or arguments.get("tool_input") or {}
    if not isinstance(tool_name, str):
        tool_name = str(tool_name)
    if not isinstance(tool_input, dict):
        tool_input = {}
    return tool_name, tool_input


def _approve_content(verdict: str, message: str | None, updated_input,
                     original_input: dict | None = None,
                     updated_permissions=None) -> dict:
    """Build the single-content-block response Claude Code expects.

    Response text is a JSON-stringified ``{behavior, message?, updatedInput?,
    updatedPermissions?}``.  On allow, ``updatedInput`` is always present:
    either the SipAI-supplied modified input, or the original input Claude
    Code sent (so the tool call runs with the exact input Claude proposed).
    Claude Code rejects an allow response that omits ``updatedInput`` as a
    validation error.  ``updatedPermissions`` rides an allow only when SipAI
    sent some — a plan approval's ``setMode``, or the rule "Allow Always"
    hands back — which Claude Code applies as it runs the tool.
    """
    body: dict = {"behavior": "allow" if verdict == "allow" else "deny"}
    if body["behavior"] == "deny":
        body["message"] = message or "Denied."
    else:
        if isinstance(updated_input, dict):
            body["updatedInput"] = updated_input
        else:
            body["updatedInput"] = original_input if isinstance(original_input, dict) else {}
        if isinstance(updated_permissions, list) and updated_permissions:
            body["updatedPermissions"] = updated_permissions
    return {
        "content": [{"type": "text", "text": json.dumps(body, ensure_ascii=False)}],
    }


def _handle_tools_call(req_id, params: dict) -> None:
    """Handle ``tools/call`` — this is the hot path."""
    if not isinstance(params, dict):
        _result(req_id, _approve_content("deny", "Malformed tools/call params.", None))
        return
    name = params.get("name")
    if name != _TOOL_NAME:
        _error(req_id, -32601, f"Unknown tool: {name!r}")
        return
    arguments = params.get("arguments") or {}
    tool_name, tool_input = _extract_tool_call(arguments)
    if not tool_name:
        _result(req_id, _approve_content("deny", "Missing tool_name in approval request.", None))
        return
    try:
        resp = _ask_sipai(tool_name, tool_input)
    except Exception as e:
        _log(f"_ask_sipai unhandled error: {e!r}")
        _log(traceback.format_exc())
        _result(req_id, _approve_content("deny", f"Approver error: {e}", None))
        return
    verdict = resp.get("verdict") if isinstance(resp, dict) else None
    if verdict not in ("allow", "deny"):
        verdict = "deny"
    message = resp.get("message") if isinstance(resp, dict) else None
    updated = resp.get("updated_input") if isinstance(resp, dict) else None
    permissions = resp.get("updated_permissions") if isinstance(resp, dict) else None
    _result(req_id, _approve_content(verdict, message, updated, original_input=tool_input,
                                     updated_permissions=permissions))


# ── Dispatch loop ─────────────────────────────────────────────────────────

def _dispatch(msg: dict) -> None:
    """Route one parsed JSON-RPC message."""
    method = msg.get("method")
    req_id = msg.get("id")
    params = msg.get("params") or {}
    is_notification = req_id is None  # JSON-RPC: no id ⇒ notification

    if is_notification:
        # We don't need to act on any notifications; the MCP lifecycle
        # (``notifications/initialized``, ``notifications/cancelled``, …)
        # doesn't require server-side state for our single-tool server.
        return

    try:
        if method == "initialize":
            _handle_initialize(req_id, params)
        elif method == "tools/list":
            _handle_tools_list(req_id)
        elif method == "tools/call":
            _handle_tools_call(req_id, params)
        elif method in ("ping",):
            _result(req_id, {})
        elif method in ("prompts/list",):
            _result(req_id, {"prompts": []})
        elif method in ("resources/list",):
            _result(req_id, {"resources": []})
        elif method in ("resources/templates/list",):
            _result(req_id, {"resourceTemplates": []})
        else:
            _error(req_id, -32601, f"Method not found: {method}")
    except Exception as e:
        _log(f"dispatch error for {method}: {e!r}")
        _log(traceback.format_exc())
        try:
            _error(req_id, -32603, f"Internal error: {e}")
        except Exception:
            pass


# ── PermissionRequest hook mode ───────────────────────────────────────────

_CONTEXT_SEND_TIMEOUT_S = 2.0


def _send_permission_context(payload: dict) -> None:
    """Hand Claude Code's suggestions for a call to SipAI.

    Best effort throughout: SipAI not running, an old SipAI that does not
    know this message, a slow socket — each leaves the approval exactly
    as it would have been without the hook.  Nothing is read back: SipAI
    matches the suggestions to the approval request itself, whichever of
    the two reaches it first.
    """
    sock_path = _socket_path()
    if not sock_path or not isinstance(payload, dict):
        return
    tool_name = payload.get("tool_name")
    tool_input = payload.get("tool_input")
    suggestions = payload.get("permission_suggestions")
    if not isinstance(tool_name, str) or not tool_name:
        return
    if not isinstance(suggestions, list) or not suggestions:
        return
    session_id, task_uuid = _split_session_id(os.environ.get("SIPAI_SESSION_ID", "") or "")
    message = {
        "v": _SIPAI_WIRE_VERSION,
        "kind": "permission_context",
        "request_id": uuid.uuid4().hex,
        "session_id": session_id,
        "task_uuid": task_uuid,
        "tool_name": tool_name,
        "tool_input": tool_input if isinstance(tool_input, dict) else {},
        "suggestions": suggestions,
    }
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(_CONTEXT_SEND_TIMEOUT_S)
        sock.connect(sock_path)
        sock.sendall((json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8"))
        sock.shutdown(socket.SHUT_WR)
    finally:
        try:
            sock.close()
        except Exception:
            pass


def hook_main() -> int:
    """PermissionRequest hook: read the hook input, tell SipAI, decide nothing."""
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        _send_permission_context(payload)
    except Exception as e:
        _log(f"permission-context hook: {e!r}")
    return 0


# ── Elicitation hook mode ─────────────────────────────────────────────────

_ELICITATION_ACTIONS = ("accept", "decline", "cancel")


def _field_order(payload: dict) -> list:
    """The form's fields in the order the server listed them.

    ``json`` keeps an object's key order, which SipAI's own parser does
    not, so the order travels beside the request.
    """
    schema = payload.get("requested_schema")
    properties = schema.get("properties") if isinstance(schema, dict) else None
    return list(properties.keys()) if isinstance(properties, dict) else []


def _ask_sipai_elicitation(payload: dict) -> dict | None:
    """Hand an MCP server's request to SipAI; return its answer, or None.

    Blocks until the user answers — Claude Code ends the hook when its
    timeout runs out.  None when SipAI cannot be reached or answers
    something unreadable.
    """
    sock_path = _socket_path()
    if not sock_path:
        return None
    session_id, task_uuid = _split_session_id(os.environ.get("SIPAI_SESSION_ID", "") or "")
    message = {
        "v": _SIPAI_WIRE_VERSION,
        "kind": "elicitation_request",
        "request_id": uuid.uuid4().hex,
        "session_id": session_id,
        "task_uuid": task_uuid,
        "hook_input": payload,
        "field_order": _field_order(payload),
    }
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        try:
            sock.connect(sock_path)
        except OSError as e:
            _log(f"elicitation: connect({sock_path}) failed: {e}")
            return None
        sock.sendall((json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8"))
        sock.shutdown(socket.SHUT_WR)
        buf = bytearray()
        while b"\n" not in buf:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf.extend(chunk)
    except OSError as e:
        _log(f"elicitation: socket I/O failed: {e}")
        return None
    finally:
        try:
            sock.close()
        except Exception:
            pass
    line = bytes(buf).split(b"\n", 1)[0].decode("utf-8", errors="replace").strip()
    try:
        answer = json.loads(line) if line else None
    except json.JSONDecodeError:
        return None
    if not isinstance(answer, dict) or answer.get("action") not in _ELICITATION_ACTIONS:
        return None
    return answer


def elicitation_main() -> int:
    """Elicitation hook: ask the user through SipAI, print the answer."""
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        if not isinstance(payload, dict):
            return 0
        answer = _ask_sipai_elicitation(payload)
        if answer is None:
            return 0
        output = {"hookEventName": "Elicitation", "action": answer["action"]}
        if answer["action"] == "accept" and isinstance(answer.get("content"), dict):
            output["content"] = answer["content"]
        sys.stdout.write(json.dumps({"hookSpecificOutput": output}, ensure_ascii=False))
        sys.stdout.flush()
    except Exception as e:
        _log(f"elicitation hook: {e!r}")
    return 0


def main() -> int:
    """Read newline-delimited JSON-RPC from stdin and respond on stdout."""
    try:
        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError as e:
                _log(f"bad JSON on stdin: {e}")
                continue
            if not isinstance(msg, dict):
                continue
            _dispatch(msg)
    except KeyboardInterrupt:
        return 0
    except Exception as e:
        _log(f"fatal: {e!r}")
        _log(traceback.format_exc())
        return 1
    return 0


if __name__ == "__main__":
    if "--permission-context" in sys.argv[1:]:
        sys.exit(hook_main())
    if "--elicitation" in sys.argv[1:]:
        sys.exit(elicitation_main())
    sys.exit(main())
