// KimiEventParsing.swift
// Shared, side-effect-free parser that turns one line of
// `kimi --prompt … --output-format stream-json` stdout into zero or
// more `StreamEvent`s — the Kimi Code counterpart of
// `AgentEventParser` (claude) and `CodexEventParser` (codex).
//
// See the header of KimiSessions.swift, and note that the two files
// read DIFFERENT formats: stdout is chat-shaped, the on-disk
// `wire.jsonl` is not.
//
// Two stdout shapes the docs do not mention at all. The first record of
// a run is a version banner:
//
//   {"role":"meta","type":"system.version","version":"…"}
//
// It falls to the `default:` case below and renders nothing, which is
// the right outcome — a version banner is not a transcript row. Do not
// "handle" it into one. The LAST record announces the session id
// (`session.resume_hint`), which `announcedSessionId` reads; see its
// doc comment. Note also that kimi's failures do NOT arrive as JSON on
// stdout: a failed run prints `error: failed to run prompt: …` on
// STDERR and exits non-zero, i.e. it reaches the user through
// `AgentRunner.stderrTail`, not through `errorMessage(from:)`.
//
// Kimi's stream-json is the plainest of the three: one OpenAI-style
// CHAT MESSAGE per line, exactly the objects an API request would carry
// (kimi docs → "Print mode"):
//
//   {"role":"user","content":"text"}
//   {"role":"assistant","content":"text","tool_calls":[
//       {"type":"function","id":"tc_1",
//        "function":{"name":"ToolName","arguments":"{…}"}}]}
//   {"role":"tool","tool_call_id":"tc_1","content":"result"}
//
// Two consequences the rest of the app has to live with, both handled
// at the `AgentRunner` end rather than papered over here:
//
//   * The session id arrives LAST, not first. Claude opens with
//     `system.init` and codex with `thread.started`; kimi opens with
//     the conversation and announces the id on its way out, so nothing
//     can be keyed off the opening record. `announcedSessionId` reads
//     the announcement and `AgentRunner` adopts it, with the store
//     diff (`KimiSessionScanner.discoverSession` /
//     `AgentRunner.startKimiSessionDiscovery`) kept as the fallback for
//     a turn that dies before reaching its last line.
//   * There is NO turn-result event and no usage block on stdout. The
//     context-token counter is therefore fed by re-reading the wire
//     file's `usage.record` at turn end instead
//     (`KimiSessionScanner.lastContextTokens`, published through
//     `AgentRunner.refreshKimiContextTokens`). `turn.ended.durationMs`
//     is on disk but unread — the composer's duration chip is stamped
//     from the runner's own turn clock when the turn finalizes.
//
// Everything below lands in the same `StreamEvent` / `StreamEventKind`
// the other two paths use, which is why the renderers, the transcript
// and the composer need no Kimi awareness at all.

import Foundation

enum KimiEventParser {

    /// The session id kimi announces on stdout, if this line is that
    /// announcement.
    ///
    /// A print-mode run's LAST line is
    ///   {"role":"meta","type":"session.resume_hint",
    ///    "session_id":"session_…","command":"kimi -r session_…",
    ///    "content":"To resume this session: …"}
    ///
    /// Read separately from `parse` rather than turned into a
    /// `.systemInit` event, because it is not a transcript row and
    /// `.systemInit` carries claude-specific consequences (starting the
    /// JSONL tailer, registering the MCP alias) that a kimi runner must
    /// not take. `AgentRunner` feeds it to `adoptDiscoveredSession`,
    /// the same landing point the store-diff fallback uses.
    ///
    /// The `type` is required as well as the key: `session_id` could
    /// plausibly appear on some future meta record that is not an
    /// announcement, and adopting an id from the wrong one would pin
    /// every later send to the wrong conversation.
    static func announcedSessionId(line: String) -> String? {
        guard let obj = decode(line),
              (obj["type"] as? String) == "session.resume_hint"
        else { return nil }
        let id = (obj["session_id"] as? String)
            ?? (obj["sessionId"] as? String) ?? ""
        return id.isEmpty ? nil : id
    }

    /// Parse one line of kimi stream-json stdout into zero or more
    /// StreamEvents. Returns an empty array for lines we don't render.
    ///
    /// - Parameters:
    ///   - line: raw stdout line (trailing newline already stripped).
    ///   - fallbackCwd: unused today — kept so the three parsers share
    ///     one call shape in `AgentRunner.handleStdoutLine`.
    static func parse(line: String, fallbackCwd: URL) -> [StreamEvent] {
        guard let obj = decode(line) else { return [] }

        // An error can arrive either as its own object or attached to a
        // message; check before the role switch so neither shape is
        // silently dropped.
        if let message = errorMessage(from: obj), obj["role"] == nil {
            return [StreamEvent(kind: .error(message: message))]
        }

        switch (obj["role"] as? String) ?? "" {
        case "assistant":
            var events: [StreamEvent] = []
            let text = contentText(obj["content"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                events.append(StreamEvent(kind: .assistantText(text: text)))
            }
            for call in toolCalls(from: obj["tool_calls"] as? [Any] ?? []) {
                events.append(StreamEvent(kind: .toolUse(
                    toolUseId: call.id, name: call.name, input: call.input)))
            }
            return events

        case "tool":
            // Without an id the row cannot be paired with its call, and
            // an unpaired result renders as an orphan block. Kimi's
            // documented shape always carries one.
            guard let id = (obj["tool_call_id"] as? String)
                    ?? (obj["toolCallId"] as? String), !id.isEmpty
            else { return [] }
            return [StreamEvent(kind: .toolResult(
                toolUseId: id,
                output: contentText(obj["content"]),
                isError: isFailure(obj)))]

        case "user":
            // `send()` already drew this bubble. Echoing it would
            // double every message — the same reason the codex parser
            // drops `user_message`.
            return []

        default:
            // `system` / `developer` records are the prompt kimi was
            // primed with, and anything unrecognised is not ours to
            // invent a row for.
            return []
        }
    }

    // MARK: - Line decoding

    /// JSON-decode one stdout line, tolerating what a PTY does to it.
    ///
    /// The runner hands every agent a PTY so its stdout line-flushes
    /// (see CLAUDE.md → "Agent-session streaming"). Under a PTY,
    /// lines arrive CRLF-terminated and the FIRST one carries
    /// `^D^H^H` tty-handshake bytes, both of which `JSONSerialization`
    /// rejects SILENTLY — the turn renders nothing at all. Kimi is a
    /// Node process behind the same PTY, so it gets the same treatment:
    /// drop everything before the opening brace, and trim newlines
    /// rather than only spaces (`.whitespaces` does NOT include `\r`).
    private static func decode(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{") else { return nil }
        let json = String(trimmed[start...])
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Content

    /// Flatten a chat message's `content` into display text.
    ///
    /// A string in the simple case; OpenAI's multimodal array shape
    /// (`[{"type":"text","text":…}]`) is accepted too, because the same
    /// wire format allows it and a tool result is as likely to arrive
    /// as blocks. Non-text blocks contribute nothing rather than a
    /// placeholder — a transcript row that says "[image]" where kimi
    /// said nothing is an invention.
    ///
    /// Internal (not private) because `KimiSessionScanner` reads the
    /// same message shape out of `wire.jsonl`; two copies of this is
    /// how the live stream and the replayed history drift apart.
    static func contentText(_ raw: Any?) -> String {
        if let text = raw as? String { return text }
        guard let blocks = raw as? [Any] else { return "" }
        var parts: [String] = []
        for block in blocks {
            if let text = block as? String {
                parts.append(text)
            } else if let dict = block as? [String: Any] {
                if let text = dict["text"] as? String, !text.isEmpty {
                    parts.append(text)
                } else if let text = dict["content"] as? String, !text.isEmpty {
                    parts.append(text)
                }
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Tool calls

    /// Decode a `tool_calls` array into the runner's tool-row shape.
    ///
    /// `function.arguments` is a JSON STRING in the OpenAI wire format,
    /// so it is parsed back into a dict for `AgentRendering` to
    /// summarize the same way it summarizes a claude `tool_use.input`.
    /// Arguments that aren't an object (or aren't valid JSON at all)
    /// are carried through under `command`, which is the key every
    /// shared renderer already looks at first.
    static func toolCalls(from raw: [Any])
    -> [(id: String, name: String, input: [String: Any])] {
        var out: [(id: String, name: String, input: [String: Any])] = []
        for case let entry as [String: Any] in raw {
            let function = (entry["function"] as? [String: Any]) ?? entry
            let name = (function["name"] as? String)
                ?? (entry["name"] as? String) ?? "tool"
            let id = (entry["id"] as? String)
                ?? (entry["tool_call_id"] as? String)
                ?? UUID().uuidString
            out.append((id: id, name: name,
                        input: arguments(function["arguments"]
                                         ?? entry["arguments"])))
        }
        return out
    }

    private static func arguments(_ raw: Any?) -> [String: Any] {
        if let dict = raw as? [String: Any] { return dict }
        guard let text = raw as? String,
              !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return [:]
        }
        if let data = text.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data))
            as? [String: Any] {
            return dict
        }
        return ["command": text]
    }

    // MARK: - Presence

    /// A key's value, with JSON `null` read as ABSENT.
    ///
    /// `JSONSerialization` surfaces JSON null as `NSNull`, which is NOT
    /// Swift's nil — so a bare `obj["x"] != nil` answers TRUE for a key
    /// the writer explicitly nulled. Claude's stream-json writes
    /// `"parent_tool_use_id": null` on main-loop events, so a bare
    /// nil-check there classifies every main event as a subagent. Any
    /// presence check on agent JSON goes through here.
    static func present(_ obj: [String: Any], _ key: String) -> Any? {
        guard let value = obj[key], !(value is NSNull) else { return nil }
        return value
    }

    // MARK: - Errors

    private static func isFailure(_ obj: [String: Any]) -> Bool {
        if let flag = obj["is_error"] as? Bool { return flag }
        if let flag = obj["isError"] as? Bool { return flag }
        if let code = obj["exit_code"] as? Int, code != 0 { return true }
        if let status = obj["status"] as? String {
            return status == "failed" || status == "error"
        }
        return present(obj, "error") != nil
    }

    private static func errorMessage(from obj: [String: Any]) -> String? {
        if let error = obj["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            return String(localized: "Kimi reported an error but gave no detail.",
                          comment: "Fallback message for a kimi error record")
        }
        if let error = obj["error"] as? String, !error.isEmpty { return error }
        guard (obj["type"] as? String) == "error" else { return nil }
        if let message = obj["message"] as? String, !message.isEmpty {
            return message
        }
        return String(localized: "Kimi reported an error but gave no detail.",
                      comment: "Fallback message for a kimi error record")
    }
}
