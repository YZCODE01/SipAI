// AgentEventParsing.swift
// Shared, side-effect-free parser that turns one line of Claude Code
// stream-json / session JSONL into zero or more `StreamEvent`s.
//
// Both `AgentRunner` (subprocess stdout) and `AgentSessionTailer`
// (live JSONL file monitor) feed lines through this parser. Keeping
// it side-effect-free means the runner can still apply its own
// side effects (session-id discovery, MCP alias registration, tailer
// startup) around the returned events without the parser having to
// know about runner state.

import Foundation

enum AgentEventParser {
    /// Parse one JSONL line into zero or more StreamEvents.
    /// Returns an empty array on parse failure (malformed JSON, unknown
    /// `type`, or an event whose shape we don't render).
    ///
    /// - Parameters:
    ///   - line: raw JSONL line (trailing newline already stripped).
    ///   - fallbackCwd: cwd path used when a system.init event carries
    ///     no `cwd` field — matches the runner's defaulting behavior.
    ///   - includeUserMessages: emit `.userMessage` events for real
    ///     (non-tool_result) user records. The tailer passes true so an
    ///     externally-driven turn shows the question that started it —
    ///     without this the live transcript streamed replies with no
    ///     prompt and only healed on reopen. The runner's stdout path
    ///     keeps the default false: its own `send()` already draws the
    ///     bubble, and `--resume` replays historical user inputs on
    ///     stdout that must not render twice.
    static func parse(line: String, fallbackCwd: URL,
                      includeUserMessages: Bool = false) -> [StreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }

        switch (obj["type"] as? String) ?? "" {
        case "system":
            return parseSystem(obj, fallbackCwd: fallbackCwd,
                               includeLocalCommands: includeUserMessages)
        case "assistant":
            return parseAssistant(obj)
        case "user":
            let toolResults = parseUserToolResult(obj)
            if !toolResults.isEmpty || !includeUserMessages {
                return toolResults
            }
            let rawText = AgentSessionScanner.extractText(
                fromContent: ((obj["message"] as? [String: Any]) ?? [:])["content"] ?? "")
            let text = AgentSessionScanner.cleanUserText(rawText)
            guard !text.isEmpty else { return [] }
            // A compaction summary is written as a USER record, and it
            // is not the user's words — the same rule, and the same
            // reason, as a harness notice. (Only the tailer sees this:
            // our own subprocess reports the summary on stdout without
            // the flag, and that copy is dropped with the other
            // replayed user records.)
            let isSummary = (obj["isCompactSummary"] as? Bool) == true
            return [StreamEvent(
                kind: .userMessage(text: text),
                isSystemNotice: AgentSessionScanner.isHarnessNotice(rawText)
                    || isSummary)]
        case "result":
            return parseResult(obj)
        default:
            return []
        }
    }

    // MARK: - Per-type parsing

    private static func parseSystem(_ obj: [String: Any],
                                    fallbackCwd: URL,
                                    includeLocalCommands: Bool) -> [StreamEvent] {
        // A local slash command's answer, for a turn run somewhere else.
        // Gated with the user messages and for the same reason: this
        // record exists only in the JSONL, so only the tailer can reach
        // it. Our own subprocess reports the answer on stdout instead
        // (as a `<synthetic>` assistant record), and its tailer resumes
        // past these bytes — so the two feeds cannot double up.
        if includeLocalCommands,
           let output = AgentSessionScanner.localCommandOutput(fromRecord: obj) {
            return [StreamEvent(kind: .userMessage(text: output),
                                isSystemNotice: true)]
        }
        // The agent summarised the conversation and carried on. The
        // context number is about to fall by most of its value, so the
        // transcript says why — on this feed and on the reload alike.
        if (obj["subtype"] as? String) == "compact_boundary" {
            let meta = (obj["compact_metadata"] as? [String: Any]) ?? [:]
            return [StreamEvent(kind: .compaction(
                preTokens: positiveInt(meta["pre_tokens"]),
                postTokens: positiveInt(meta["post_tokens"])))]
        }
        guard (obj["subtype"] as? String) == "init" else { return [] }
        let sid = (obj["session_id"] as? String) ?? ""
        let model = (obj["model"] as? String) ?? ""
        let cwdStr = (obj["cwd"] as? String) ?? fallbackCwd.path
        return [StreamEvent(kind: .systemInit(
            sessionId: sid, model: model, cwd: cwdStr
        ), fastModeState: obj["fast_mode_state"] as? String)]
    }

    /// How full the context window is right now: the INPUT side of ONE
    /// API call — fresh input plus the cached prefix, which together are
    /// the whole conversation as the model just saw it. Assistant
    /// records carry this per call in `message.usage`, the only place
    /// the real context size lives; the `result` event's usage is
    /// summed across every call of the turn and overcounts by the
    /// number of tool round-trips.
    ///
    /// The call's OWN output is deliberately excluded. Claude Code's
    /// context indicator is `input + cache_creation + cache_read` over
    /// the window, and kimi's status bar computes the same quantity —
    /// adding the reply here would put this chip a few percent above
    /// what the agent's own terminal says about the same session.
    private static func contextFootprint(ofUsage usage: [String: Any]?) -> Int? {
        guard let usage = usage else { return nil }
        let total = intField(usage["input_tokens"])
            + intField(usage["cache_creation_input_tokens"])
            + intField(usage["cache_read_input_tokens"])
        return total > 0 ? total : nil
    }

    private static func parseAssistant(_ obj: [String: Any]) -> [StreamEvent] {
        let msg = (obj["message"] as? [String: Any]) ?? [:]
        // Stamped on every event of this record: any of them updating
        // the runner's counter is equivalent, and a record whose blocks
        // all render (text + tool_use) still yields one value.
        // SUBAGENT records are excluded: a Task subagent runs in its
        // own small fresh context, and stream-json interleaves its
        // assistant events (tagged `parent_tool_use_id`; transcripts
        // use `isSidechain`) with the main loop's — stamping both
        // would whipsaw the composer counter between that small fresh
        // context and the session's real one on every Task-heavy turn.
        // String cast, NOT a nil-check: stream-json writes
        // "parent_tool_use_id": null on MAIN events, JSONSerialization
        // surfaces that as NSNull — which is != nil — and a bare
        // check would classify every main event as a subagent,
        // freezing the token counter for the whole in-app send path.
        let isSubagent = (obj["parent_tool_use_id"] as? String) != nil
            || (obj["isSidechain"] as? Bool) == true
        let ctx = isSubagent
            ? nil
            : contextFootprint(ofUsage: msg["usage"] as? [String: Any])
        // `model: "<synthetic>"` is claude's own marker for text the
        // HARNESS produced and no model ever said — a local slash
        // command's answer under `-p`, a post-command notice. Attributing
        // it to the assistant makes the same answer change speaker when
        // the transcript is re-read from disk, where it arrives as a
        // `local_command` record and renders as a system notice.
        // Text only: any other block type keeps its ordinary shape.
        let isSynthetic = (msg["model"] as? String) == "<synthetic>"
        func textEvent(_ t: String) -> StreamEvent {
            isSynthetic
                ? StreamEvent(kind: .userMessage(text: t), contextTokens: ctx,
                              isSystemNotice: true)
                : StreamEvent(kind: .assistantText(text: t), contextTokens: ctx)
        }
        let content = msg["content"]
        guard let arr = content as? [Any] else {
            // Plain-string assistant messages: emit whole.
            if let s = content as? String, !s.isEmpty {
                return [textEvent(s)]
            }
            return []
        }
        var out: [StreamEvent] = []
        for block in arr {
            guard let dict = block as? [String: Any] else { continue }
            switch (dict["type"] as? String) ?? "" {
            case "text":
                if let t = dict["text"] as? String,
                   !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(textEvent(t))
                }
            case "tool_use":
                let name = (dict["name"] as? String) ?? ""
                let id = (dict["id"] as? String) ?? UUID().uuidString
                let input = dict["input"] as? [String: Any] ?? [:]
                out.append(StreamEvent(kind: .toolUse(
                    toolUseId: id, name: name, input: input
                ), contextTokens: ctx))
            default:
                break  // "thinking" and other content types: silently ignored
            }
        }
        return out
    }

    private static func parseUserToolResult(_ obj: [String: Any]) -> [StreamEvent] {
        // Filter to actual tool_result payloads — `user` events that
        // aren't tool_result (i.e. a normal user input being replayed
        // in a resume) carry no tool_result block.
        let msg = (obj["message"] as? [String: Any]) ?? [:]
        guard let content = msg["content"] as? [Any] else { return [] }
        var out: [StreamEvent] = []
        for block in content {
            guard let dict = block as? [String: Any],
                  (dict["type"] as? String) == "tool_result"
            else { continue }
            let toolUseId = (dict["tool_use_id"] as? String) ?? ""
            let isError = (dict["is_error"] as? Bool) ?? false
            let output = textFromToolResultContent(dict["content"])
            out.append(StreamEvent(kind: .toolResult(
                toolUseId: toolUseId, output: output, isError: isError
            )))
        }
        return out
    }

    private static func parseResult(_ obj: [String: Any]) -> [StreamEvent] {
        let durationMs = (obj["duration_ms"] as? Int)
            ?? Int((obj["duration_ms"] as? Double) ?? 0)
        let cost = obj["total_cost_usd"] as? Double
        let numTurns = (obj["num_turns"] as? Int) ?? 0
        let usage = (obj["usage"] as? [String: Any]) ?? [:]
        // Turn totals for the summary chip only. Deriving the CONTEXT
        // counter from this block is wrong by construction: result
        // usage sums every API call of the turn, so cache_read alone
        // multiplies the real context by the number of tool
        // round-trips. The context counter reads per-call assistant
        // usage instead (`contextFootprint`).
        let inTok = intField(usage["input_tokens"])
        let outTok = intField(usage["output_tokens"])
        // Claude's own window arithmetic, per model that ran this turn.
        // The transcript records this nowhere, and `system.init` does
        // not carry it either — this event is the only channel, which
        // is why it is read here rather than inferred.
        var windows: [String: Int] = [:]
        for (model, entry) in (obj["modelUsage"] as? [String: Any]) ?? [:] {
            guard let fields = entry as? [String: Any],
                  let window = (fields["contextWindow"] as? NSNumber)?.intValue,
                  window > 0, !model.isEmpty
            else { continue }
            windows[model] = window
        }
        return [StreamEvent(kind: .result(
            durationMs: durationMs,
            totalCostUSD: cost,
            numTurns: numTurns,
            inputTokens: inTok,
            outputTokens: outTok
        ), fastModeState: obj["fast_mode_state"] as? String,
           modelContextWindows: windows.isEmpty ? nil : windows)]
    }

    /// Whether the child is summarising the conversation right now:
    /// true when it says so, false when it reports the outcome, nil for
    /// every other line.
    ///
    /// A separate read rather than an event, because this is STATE — it
    /// is true for the half-minute a compaction runs and false after,
    /// and an event would be written into the transcript's history and
    /// replayed on every reopen.
    static func compactingSignal(line: String) -> Bool? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.contains("\"status\""),
              let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              (obj["type"] as? String) == "system",
              (obj["subtype"] as? String) == "status"
        else { return nil }
        if obj["compact_result"] != nil,
           !(obj["compact_result"] is NSNull) { return false }
        if (obj["status"] as? String) == "compacting" { return true }
        return nil
    }

    /// A positive integer field, or nil — an absent figure and a zero
    /// are the same thing here, and a row must not state "0 tokens".
    private static func positiveInt(_ value: Any?) -> Int? {
        let n = intField(value)
        return n > 0 ? n : nil
    }

    private static func intField(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return 0
    }

    // MARK: - Helpers

    /// Tool_result `content` can be a string or an array of blocks.
    /// Flatten to a single string for display.
    static func textFromToolResultContent(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let arr = content as? [Any] else { return "" }
        var parts: [String] = []
        for block in arr {
            if let dict = block as? [String: Any],
               (dict["type"] as? String) == "text",
               let t = dict["text"] as? String {
                parts.append(t)
            } else if let s = block as? String {
                parts.append(s)
            }
        }
        return parts.joined(separator: "\n")
    }
}
