// CodexEventParsing.swift
// Shared, side-effect-free parser that turns one line of
// `codex exec --json` stdout into zero or more `StreamEvent`s — the
// Codex counterpart of `AgentEventParser`.
//
// Codex speaks TWO different JSONL schemas, and this file decodes only
// the first:
//
//   1. `codex exec --json` STDOUT — a flat event stream
//      (`thread.started` / `turn.started` / `item.*` / `turn.completed`).
//      That is what a live turn this app spawned emits, and what this
//      parser reads.
//   2. The ROLLOUT file under ~/.codex/sessions — a different, richer
//      record shape (`session_meta` / `response_item` / `event_msg`).
//      `CodexSessionScanner` owns that one.
//
// They are NOT interchangeable: stdout says
// `{"type":"item.completed","item":{"type":"agent_message",…}}`
// where the rollout says `{"type":"event_msg","payload":{"type":
// "agent_message",…}}`. Feeding either parser the other's lines yields
// silence, not an error — so keep the two readers apart.
//
// The target types are unchanged: everything below lands in the same
// `StreamEvent` / `StreamEventKind` the Claude path uses, which is why
// the renderers, the transcript, and the composer needed no Codex
// awareness at all.

import Foundation

enum CodexEventParser {

    /// One line's worth of output: rows for the transcript, plus at
    /// most one TRANSIENT notice that must never become a row.
    ///
    /// Codex reports a dropped stream as an ordinary `error` event and
    /// retries by itself, so a rate-limited turn emits one of those per
    /// attempt while the turn is still perfectly alive. Appending them
    /// buries the conversation under "Reconnecting… 3/5" rows and
    /// duplicates the failure text, since a turn that really does die
    /// ends with `turn.failed` carrying the same message.
    struct Parsed {
        var events: [StreamEvent] = []
        var notice: String? = nil
    }

    /// Parse one line of `codex exec --json` stdout.
    ///
    /// - Parameters:
    ///   - line: raw stdout line (trailing newline already stripped).
    ///   - fallbackCwd: cwd reported on `.systemInit` — codex's
    ///     `thread.started` carries no cwd of its own.
    static func parse(line: String, fallbackCwd: URL) -> Parsed {
        guard let obj = decode(line) else { return Parsed() }

        switch (obj["type"] as? String) ?? "" {
        case "thread.started":
            // The thread id IS the session id: it names the rollout
            // file (rollout-<stamp>-<thread_id>.jsonl) and is what
            // `codex exec resume <id>` takes. Emitting it as
            // `.systemInit` is what migrates a draft runner onto its
            // permanent key, exactly as claude's system.init does.
            //
            // Model and cwd are deliberately blank: codex does not
            // report either here. `AgentRunner.resolvedModel` already
            // guards on a non-empty model, so the composer keeps
            // showing the picker's alias rather than being blanked by
            // this.
            let tid = (obj["thread_id"] as? String) ?? ""
            guard !tid.isEmpty else { return Parsed() }
            return Parsed(events: [StreamEvent(kind: .systemInit(
                sessionId: tid, model: "", cwd: fallbackCwd.path))])

        case "item.started":
            // Tool activity opens a row here and resolves on
            // `item.completed`, mirroring claude's tool_use →
            // tool_result pairing (both keyed by the item id).
            return Parsed(events: toolUseEvents(from: obj))

        case "item.completed":
            // An `error` ITEM is codex talking about its own transport
            // ("Falling back from WebSockets to HTTPS transport…"), not
            // a tool finishing. It carries none of the fields a tool
            // row reads, so pairing it as one produces an orphan result
            // with an empty body — the item has no `item.started`.
            if let item = obj["item"] as? [String: Any],
               (item["type"] as? String) == "error" {
                return Parsed(notice: noticeMessage(item["message"]))
            }
            return Parsed(events: completedItemEvents(from: obj))

        case "turn.completed":
            return Parsed(events: [resultEvent(from: obj)])

        // The turn is over and this is why — the one codex failure that
        // is a transcript row.
        case "turn.failed":
            return Parsed(events: [StreamEvent(
                kind: .error(message: failureMessage(from: obj)))])

        // Retry progress, and the failure text repeated once just
        // before `turn.failed` says the same thing. See `Parsed`.
        case "error":
            return Parsed(notice: noticeMessage(obj["message"]))

        // `turn.started` and `item.updated` carry nothing the
        // transcript shows. `item.updated` is deliberately dropped
        // rather than rendered: it repeats an in-flight item, and
        // emitting it would stack duplicate tool rows for one call.
        default:
            return Parsed()
        }
    }

    private static func noticeMessage(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Line decoding

    /// JSON-decode one stdout line, tolerating what a PTY does to it.
    ///
    /// The runner hands codex a PTY so its stdout line-flushes (same
    /// reason as claude — see CLAUDE.md). The cost of that: lines
    /// arrive CRLF-terminated, and the FIRST line is prefixed with
    /// terminal control bytes (`^D^H^H`) from the tty handshake.
    /// `JSONSerialization` rejects both, and the failure is silent —
    /// the turn simply renders nothing.
    ///
    /// So: drop everything before the opening brace, and trim newlines
    /// rather than only spaces (`.whitespaces` does NOT include `\r`).
    private static func decode(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{") else { return nil }
        let json = String(trimmed[start...])
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Items

    /// Item types that are conversation or private thinking, never a
    /// tool row. `reasoning` is dropped exactly as the claude parser
    /// drops `thinking` blocks.
    private static let nonToolItemTypes: Set<String> = [
        "agent_message", "user_message", "reasoning",
    ]

    private static func toolUseEvents(from obj: [String: Any]) -> [StreamEvent] {
        guard let item = obj["item"] as? [String: Any],
              let type = item["type"] as? String,
              !nonToolItemTypes.contains(type) else { return [] }
        let id = (item["id"] as? String) ?? UUID().uuidString
        return [StreamEvent(kind: .toolUse(
            toolUseId: id, name: type, input: toolInput(from: item)))]
    }

    private static func completedItemEvents(from obj: [String: Any])
    -> [StreamEvent] {
        guard let item = obj["item"] as? [String: Any] else { return [] }
        let type = (item["type"] as? String) ?? ""

        if type == "agent_message" {
            let text = (item["text"] as? String) ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return [] }
            return [StreamEvent(kind: .assistantText(text: text))]
        }
        // A user_message echo would double the bubble `send()` already
        // drew; reasoning is private. Both are dropped.
        if nonToolItemTypes.contains(type) { return [] }

        let id = (item["id"] as? String) ?? UUID().uuidString
        return [StreamEvent(kind: .toolResult(
            toolUseId: id,
            output: toolOutput(from: item),
            isError: isFailure(item)))]
    }

    /// Input dict for a tool row. Keyed to what the shared renderers
    /// already look for, so codex tool rows summarize through the same
    /// `AgentRendering` path as claude's — `command` first, since that
    /// is what `CodexSessionScanner` puts in its history items too.
    private static func toolInput(from item: [String: Any]) -> [String: Any] {
        var input: [String: Any] = [:]
        for key in ["command", "path", "file_path", "query", "url", "name"] {
            if let value = item[key] as? String, !value.isEmpty {
                input[key] = value
            }
        }
        if input.isEmpty, let raw = item["arguments"] {
            // MCP-style items carry their call under `arguments`, as
            // either a nested object or a JSON string.
            if let dict = raw as? [String: Any] {
                input = dict
            } else if let text = raw as? String, !text.isEmpty {
                input["command"] = text
            }
        }
        return input
    }

    /// Human-visible output of a finished tool item.
    private static func toolOutput(from item: [String: Any]) -> String {
        for key in ["aggregated_output", "output", "result", "text"] {
            if let value = item[key] as? String, !value.isEmpty {
                return value
            }
        }
        // A patch/file-change item reports what it touched rather than
        // emitting text; name the change so the row isn't blank.
        if let status = item["status"] as? String, !status.isEmpty {
            return status
        }
        return ""
    }

    private static func isFailure(_ item: [String: Any]) -> Bool {
        if let code = item["exit_code"] as? Int, code != 0 { return true }
        if let status = item["status"] as? String {
            return status == "failed" || status == "error"
        }
        return false
    }

    // MARK: - Turn result

    private static func resultEvent(from obj: [String: Any]) -> StreamEvent {
        let usage = (obj["usage"] as? [String: Any]) ?? [:]
        // Turn TOTALS, for the summary chip only.
        //
        // These must never feed the composer's context counter:
        // `usage` is CUMULATIVE, summed across every API call of the
        // turn. Codex's stdout stream carries no per-call usage to
        // substitute (the rollout's `event_msg`/`token_count` records
        // do, but those are the other schema), so `contextTokens` is
        // left nil here rather than stamped with a number that grows
        // with tool round-trips.
        let inTok = intField(usage["input_tokens"])
        let outTok = intField(usage["output_tokens"])
        // Codex reports no wall-clock duration. 0 is correct rather
        // than invented: the composer's duration chip is stamped by the
        // runner off its own turn clock when this event lands.
        return StreamEvent(kind: .result(
            durationMs: 0,
            totalCostUSD: nil,
            numTurns: 1,
            inputTokens: inTok,
            outputTokens: outTok))
    }

    private static func failureMessage(from obj: [String: Any]) -> String {
        if let message = obj["message"] as? String, !message.isEmpty {
            return message
        }
        if let error = obj["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        if let error = obj["error"] as? String, !error.isEmpty {
            return error
        }
        return String(localized: "Codex reported an error but gave no detail.",
                      comment: "Fallback message for a codex turn.failed event")
    }

    private static func intField(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return 0
    }
}
