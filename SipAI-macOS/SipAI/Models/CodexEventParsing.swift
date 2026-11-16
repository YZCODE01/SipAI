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
    ///   - includeThinking: emit `.thinking` for a `reasoning` item that
    ///     carries a summary. A Chat only turn asks, and any turn while
    ///     compact view is on — the turns that draw thoughts — so every
    ///     other turn's events are what they always were.
    static func parse(line: String, fallbackCwd: URL,
                      includeThinking: Bool = false) -> Parsed {
        guard let obj = decode(line) else { return Parsed() }
        return parse(object: obj, fallbackCwd: fallbackCwd, includeThinking: includeThinking)
    }

    /// One event already decoded — what a stdout line decodes to, and
    /// what a codex app-server item is translated into
    /// (`CodexAppServer.execEvents`), so a turn in an asking mode is drawn
    /// by exactly this code.
    static func parse(object obj: [String: Any], fallbackCwd: URL,
                      includeThinking: Bool = false) -> Parsed {
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
            // A reasoning SUMMARY, when codex was asked for one and the
            // model returned it. Empty text is reasoning with nothing
            // readable to show, and draws nothing.
            if includeThinking, let item = obj["item"] as? [String: Any],
               (item["type"] as? String) == "reasoning" {
                let text = (item["text"] as? String) ?? ""
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return Parsed() }
                return Parsed(events: [StreamEvent(kind: .thinking(text: text))])
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
    /// The runner hands codex a PTY so its stdout line-flushes — through
    /// a pipe a child's output can sit in a block buffer until it exits,
    /// and the turn arrives all at once. The cost of that: lines
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

    /// Item types that are conversation or thinking, never a tool row.
    /// `reasoning` becomes a thought only when asked (see `parse`),
    /// exactly as the claude parser treats `thinking` blocks.
    private static let nonToolItemTypes: Set<String> = [
        "agent_message", "user_message", "reasoning",
        // Codex compacting itself. It carries none of the fields a
        // tool row reads, so pairing it as one draws an empty chip;
        // `completedItemEvents` renders it as the compaction row.
        "context_compaction",
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
        // The agent summarised the conversation to make room. No
        // figures: codex records none, here or in the rollout.
        if type == "context_compaction" {
            return [StreamEvent(kind: .compaction(preTokens: nil,
                                                  postTokens: nil))]
        }
        // A user_message echo would double the bubble `send()` already
        // drew, and reasoning nobody asked for draws nothing.
        // Both are dropped.
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
    ///
    /// A file change keeps its files under `changes`, and a command is
    /// shown as codex ran it less the login shell around it — the shapes a
    /// reopened row takes from codex's records (`CodexToolInput`), so the
    /// row reads the same live and reopened.
    private static func toolInput(from item: [String: Any]) -> [String: Any] {
        let type = item["type"] as? String ?? ""
        if CodexToolInput.fileChangeNames.contains(type) {
            return CodexToolInput.fileChange(fromItemChanges: item["changes"])
        }
        if type == "command_execution", let command = item["command"] as? String, !command.isEmpty {
            return ["command": unwrappedShell(command)]
        }
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
        // A web search names what it looked up only when it completes —
        // under codex's code mode its start carries an empty query — so
        // its result is that spelling (the terms, the page, `'pattern'
        // in <url>`), the same one the rollout keeps for a reopen.
        if (item["type"] as? String) == "web_search",
           let query = (item["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !query.isEmpty {
            return query
        }
        for key in ["aggregated_output", "output", "result", "text"] {
            if let value = item[key] as? String, !value.isEmpty {
                return value
            }
        }
        // A file change says nothing beyond the files its row already
        // names; whether it failed rides the result's flag.
        if CodexToolInput.fileChangeNames.contains(item["type"] as? String ?? "") {
            return ""
        }
        // An item with no text of its own names its status, so its row
        // isn't blank.
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

    /// `<shell> -lc '<command>'` → `<command>`, with the quoting undone;
    /// anything else unchanged — the command as codex runs it, less the
    /// login-shell wrapper it runs it in, on exec's items and the
    /// app-server's alike. Codex wraps in single quotes, and in double
    /// quotes when the command has a single quote of its own
    /// (`/bin/zsh -lc "bash -lc 'make'"`); a double-quoted one is unwrapped
    /// only when nothing inside it is escaped — otherwise the string stays
    /// exactly as codex sent it, wrapper and all, rather than be un-escaped
    /// on a guess.
    static func unwrappedShell(_ raw: String) -> String {
        let shells = ["/bin/zsh", "/bin/bash", "/bin/sh", "zsh", "bash", "sh"]
        for shell in shells {
            for flag in [" -lc ", " -c "] {
                let head = shell + flag
                guard raw.hasPrefix(head) else { continue }
                let body = String(raw.dropFirst(head.count))
                guard body.count >= 2 else { return raw }
                let inner = String(body.dropFirst().dropLast())
                if body.hasPrefix("'"), body.hasSuffix("'") {
                    return inner.replacingOccurrences(of: "'\\''", with: "'")
                }
                if body.hasPrefix("\""), body.hasSuffix("\""),
                   !inner.contains("\\"), !inner.contains("\"") {
                    return inner
                }
                return raw
            }
        }
        return raw
    }
}

/// The commands a codex turn has running, as its items report them — one
/// rule for both of codex's routes: `codex exec --json`'s stdout, and the
/// app-server's items in exec's shape (`CodexAppServer.execEvents`).
///
/// Codex can return from a command while it still runs — in a background
/// terminal, its words — and the model goes on to answer. Such a command
/// is an item started and not yet completed when the answer lands. What
/// becomes of it depends on the route, both measured: `codex exec` stops it
/// when its turn ends, saying so nowhere on stdout; the app-server keeps it
/// running for as long as its process lives, and either holds the turn
/// open until it ends or ends the turn at the answer — one or the other,
/// run to run.
struct CodexBackgroundCommands {
    /// Commands started and not yet completed, in the order they started.
    private(set) var running: [BackgroundTaskEntry] = []

    /// The newest item the turn reported is the model's answer: a finished
    /// agent message that is not commentary between steps.
    private(set) var answered = false

    init() {}

    /// The commands the turn waits on once the model has answered — the
    /// transcript's line naming them.
    var awaited: [BackgroundTaskEntry] { answered ? running : [] }

    /// Read one event in exec's shape.
    mutating func read(object obj: [String: Any]) {
        guard let item = obj["item"] as? [String: Any] else { return }
        let type = item["type"] as? String ?? ""
        let id = item["id"] as? String ?? ""
        switch obj["type"] as? String {
        case "item.started":
            answered = false
            if type == "command_execution", !id.isEmpty, !running.contains(where: { $0.id == id }) {
                running.append(BackgroundTaskEntry(
                    id: id, kind: "command",
                    description: CodexEventParser.unwrappedShell(item["command"] as? String ?? "")))
            }
        case "item.completed":
            // A command finishing is not a step of the turn: the answer
            // before it is still the answer.
            if type == "command_execution" {
                running.removeAll { $0.id == id }
            } else {
                answered = type == "agent_message" && (item["phase"] as? String) != "commentary"
            }
        default:
            break
        }
    }

    /// Read one line of `codex exec --json` stdout.
    mutating func read(line: String) {
        guard line.contains("\"item."),
              let start = line.firstIndex(of: "{"),
              let data = String(line[start...]).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        read(object: obj)
    }
}
