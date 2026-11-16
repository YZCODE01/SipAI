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
    ///   - includeThinking: emit `.thinking` for a thinking block that
    ///     carries text. A Chat only turn asks, and any turn while compact
    ///     view is on — their thoughts are drawn inside the turn's activity
    ///     lines — so every other turn's events are exactly what they
    ///     always were. Claude is asked for readable thinking on a Chat
    ///     only turn (`ChatOnlyArgv.claudeThinkingSummaries`) and where the
    ///     user's own `showThinkingSummaries` asks; elsewhere its blocks
    ///     hold claude's own short notes, or nothing.
    static func parse(line: String, fallbackCwd: URL,
                      includeUserMessages: Bool = false,
                      includeThinking: Bool = false) -> [StreamEvent] {
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
            return parseAssistant(obj, includeThinking: includeThinking)
        case "user":
            let toolResults = parseUserToolResult(obj)
            if !toolResults.isEmpty || !includeUserMessages {
                return toolResults
            }
            let rawText = AgentSessionScanner.extractText(
                fromContent: ((obj["message"] as? [String: Any]) ?? [:])["content"] ?? "")
            // A `!` command run in claude's own terminal: its rows read as
            // the reopened transcript draws them (`ClaudeShellCommand`).
            if let shell = ClaudeShellCommand.rows(
                fromContent: ((obj["message"] as? [String: Any]) ?? [:])["content"] ?? "") {
                return shell.map { row in
                    switch row {
                    case .command(let command):
                        return StreamEvent(kind: .userMessage(text: ShellCommandInput.display(command)),
                                           shellCommand: true)
                    case .output(let output):
                        return StreamEvent(kind: .shellOutput(output))
                    }
                }
            }
            // A background task's notification reads as the reopened
            // transcript draws it; a line has no earlier tool call to name
            // an agent's task by, so claude's own summary stands there.
            let taskNotice = ClaudeTaskNotice.saved(rawText, description: { _ in nil })
            let text = taskNotice ?? AgentSessionScanner.cleanUserText(rawText)
            // Attached files ride the row as the reopened transcript's do,
            // read off the raw text before the strip removes their
            // markers — and a message of files alone is still a message.
            let attached = AttachmentInline.names(in: rawText)
            guard !text.isEmpty || !attached.isEmpty else { return [] }
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
                    || isSummary,
                belongsToAnswer: taskNotice != nil,
                attachedFiles: attached)]
        case "result":
            return parseResult(obj)
        case "attachment":
            // What a request carried mid-turn — kept only in the
            // transcript, so only the tailer meets it: a message the user
            // sent into the turn (the user's words, opening no turn), or a
            // background task's notification.
            guard includeUserMessages else { return [] }
            if let prompt = AgentSessionScanner.queuedPrompt(obj) {
                let text = AgentSessionScanner.cleanUserText(prompt)
                let attached = AttachmentInline.names(in: prompt)
                guard !text.isEmpty || !attached.isEmpty else { return [] }
                return [StreamEvent(kind: .userMessage(text: text), sentIntoTurn: true,
                                    attachedFiles: attached)]
            }
            guard let notice = AgentSessionScanner.queuedTaskNotice(obj, description: { _ in nil })
            else { return [] }
            return [StreamEvent(kind: .userMessage(text: notice), isSystemNotice: true,
                                sentIntoTurn: true, belongsToAnswer: true)]
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
        ), fastModeState: obj["fast_mode_state"] as? String,
           fastModeDisabledReason: obj["fast_mode_disabled_reason"] as? String)]
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

    private static func parseAssistant(_ obj: [String: Any],
                                       includeThinking: Bool) -> [StreamEvent] {
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
        // What the call actually ran at — the ground truth behind the
        // fast switch, main loop only, for the same reason as `ctx`.
        let speed: String? = isSubagent || isSynthetic ? nil
            : ((msg["usage"] as? [String: Any])?["speed"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
        func textEvent(_ t: String) -> StreamEvent {
            isSynthetic
                ? StreamEvent(kind: .userMessage(text: t), contextTokens: ctx,
                              isSystemNotice: true)
                : StreamEvent(kind: .assistantText(text: t), contextTokens: ctx,
                              callSpeed: speed)
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
                ), contextTokens: ctx, callSpeed: speed))
            case "thinking" where includeThinking && !isSubagent:
                // An empty block is thinking the API was asked to leave
                // out (the signature alone); it has nothing to draw.
                if let t = dict["thinking"] as? String,
                   !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(StreamEvent(kind: .thinking(text: t), contextTokens: ctx,
                                           callSpeed: speed))
                }
            default:
                break  // other content types: silently ignored
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
           fastModeDisabledReason: obj["fast_mode_disabled_reason"] as? String,
           modelContextWindows: windows.isEmpty ? nil : windows,
           turnFailure: turnFailure(ofResult: obj),
           refusedAsTooLong: refusedAsTooLong(ofResult: obj))]
    }

    /// Whether claude refused the turn BEFORE sending anything because its
    /// own estimate of the request was over the model's limit: "Prompt is
    /// too long", `terminal_reason: "blocking_limit"`, no API call made. An
    /// API's own prompt-too-long refusal is not this one — claude compacts
    /// by itself after that and answers.
    static func refusedAsTooLong(ofResult obj: [String: Any]) -> Bool {
        (obj["is_error"] as? Bool) == true
            && (obj["terminal_reason"] as? String) == "blocking_limit"
    }

    /// Whether a claude message refused as too long before anything was
    /// sent (`StreamEvent.refusedAsTooLong`) is sent once more, as the same
    /// turn.
    ///
    /// When a process starts on a session whose instruction files (a
    /// CLAUDE.md, a memory file) changed since the conversation's last copy,
    /// claude attaches each changed file again, whole. Its check for the
    /// model's limit counts that copy and its compaction before sending does
    /// not, so near the limit the message is refused without a compaction
    /// tried. Sent once more, it finds the copy already in the conversation:
    /// claude compacts first, then answers. SipAI starts a process for every
    /// message, so it meets this after any edit to those files, where
    /// claude's own terminal keeps one process and meets it only on a resume.
    ///
    /// Only where the re-send can do what the first attempt could not:
    ///  * a session that existed before the message — compacting cannot
    ///    make a new session's own message smaller;
    ///  * nothing ran in the attempt: no model output, no tool call, no
    ///    compaction row — a re-send must never repeat work;
    ///  * claude did not try to compact in it (`compactionTried`): tried and
    ///    refused all the same, the re-send would meet the same refusal;
    ///  * once per message, and never after Stop.
    static func resendsTooLongRefusal(_ result: StreamEvent,
                                      attempt: ArraySlice<StreamEvent>,
                                      resumedSession: Bool,
                                      compactionTried: Bool,
                                      alreadyResent: Bool,
                                      stopped: Bool) -> Bool {
        guard result.refusedAsTooLong, resumedSession, !compactionTried,
              !alreadyResent, !stopped else { return false }
        return attempt.allSatisfy { event in
            switch event.kind {
            // The handshake, a row of SipAI's own (a skill it could not
            // load), and claude's own notice of the refusal.
            case .systemInit, .result, .error: return true
            case .userMessage: return event.isSystemNotice
            default: return false
            }
        }
    }

    /// Claude's own verdict on the turn a `result` ends: the words of a
    /// turn it calls failed (`is_error`), "" for one it failed without
    /// words, nil for one that went through. `subtype` cannot say it — an
    /// API's refusal, a connection that never opened and a failed login
    /// all end on a "success" result, with `is_error` and the words in
    /// `result`; a turn cut off at a limit ends on an error subtype whose
    /// words are only in `errors`. A local command claude answers itself
    /// is no failure even when it is not available here: claude does not
    /// call it one.
    static func turnFailure(ofResult obj: [String: Any]) -> String? {
        guard (obj["is_error"] as? Bool) == true else { return nil }
        if let words = (obj["result"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty {
            return words
        }
        return ((obj["errors"] as? [Any]) ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Whether the rows just before a failed turn's `result` already say
    /// its words, so a row of SipAI's own would say them twice: claude
    /// writes an API's refusal as a message of its own (`<synthetic>`, a
    /// system notice here) just before the result that repeats it. A turn
    /// cut off at a limit has no such message, and its words would
    /// otherwise be on no row at all.
    static func failureIsShown(_ words: String, before events: ArraySlice<StreamEvent>) -> Bool {
        guard let newest = events.last else { return false }
        let said: String
        switch newest.kind {
        case .userMessage(let text) where newest.isSystemNotice: said = text
        case .assistantText(let text): said = text
        case .error(let message): said = message
        default: return false
        }
        return said.trimmingCharacters(in: .whitespacesAndNewlines)
            == words.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Claude's own line for an API call it is retrying by itself — its
    /// terminal's "API error · Retrying in 4s · attempt 3/10" — without
    /// the countdown: this line is not a clock. Claude says nothing else
    /// while it retries, ten times over minutes when the connection is
    /// down, and reports each attempt on stdout as a `system`/`api_retry`
    /// record carrying the attempt, the limit, the wait, the HTTP status
    /// and a category, never the error's own words; so the line keeps the
    /// label claude's terminal shows on its first attempts. Read beside
    /// the parse, like `compactingSignal`: it is the state of the
    /// connection, and no transcript keeps it. Nil for every other line.
    static func retryNotice(line: String) -> String? {
        guard line.contains("\"api_retry\"") else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              (obj["type"] as? String) == "system",
              (obj["subtype"] as? String) == "api_retry",
              let attempt = (obj["attempt"] as? NSNumber)?.intValue,
              let limit = (obj["max_retries"] as? NSNumber)?.intValue
        else { return nil }
        return "API error · Retrying · attempt \(attempt)/\(limit)"
    }

    /// Claude's own sentence when the API refused a call's fast mode for
    /// want of usage credits — the `system` notification keyed
    /// `ClaudeFastMode.refusalKey` ("Fast mode disabled · usage credits
    /// exhausted") — or nil for every other line.
    ///
    /// Read beside the parse rather than as an event, like
    /// `compactingSignal`: it is STATE (the session's fast mode is not
    /// being served), which the chip shows, and no transcript keeps it.
    static func fastModeRefusal(line: String) -> String? {
        guard line.contains(ClaudeFastMode.refusalKey) else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              (obj["type"] as? String) == "system",
              (obj["subtype"] as? String) == "notification",
              (obj["key"] as? String) == ClaudeFastMode.refusalKey
        else { return nil }
        let text = ((obj["text"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
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

    /// The permission mode claude says its session is in: named by the
    /// `init` record a turn opens with, and again by a `status` record
    /// each time the mode changes inside the turn — a plan approved into
    /// accept-edits, the agent entering plan mode by itself. nil for
    /// every other line.
    ///
    /// A separate read rather than an event for the same reason as
    /// `compactingSignal`: this is state the runner keeps, not a row.
    static func permissionMode(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.contains("\"permissionMode\""),
              let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              (obj["type"] as? String) == "system",
              let subtype = obj["subtype"] as? String,
              subtype == "init" || subtype == "status",
              // A subagent's records describe its own context, not the
              // session's.
              !(obj["parent_tool_use_id"] is String),
              let mode = obj["permissionMode"] as? String, !mode.isEmpty
        else { return nil }
        return mode
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

/// The transcript's waiting row — the spinner and "Sipping…" under the
/// user's message until the agent's first output of the turn lands — and
/// the stall notice it carries when a turn says nothing for minutes
/// (`AgentRunner.turnProducedNothing`). Both ask the one question below,
/// over the runner's live buffer.
enum WaitingRow {

    /// Whether the newest turn in `events` has had nothing back from the
    /// agent yet: walking back from the newest event, the turn's own
    /// message comes before anything the agent produced.
    ///
    /// A row sent into a turn already running (`sentIntoTurn`: the user's
    /// answer to a question the agent asked without stopping, a message
    /// steered in, a background task's notice claude hands the model with
    /// its next request) is walked past. It opens no turn, and what the
    /// agent produced above it is this turn's: taken for the turn's
    /// message, it brings "Sipping…" back under it, as though a new message
    /// had been sent, while the turn simply goes on. Any other notice in
    /// the user column — one claude opens its report on, kimi's, a review
    /// starting — still ends the walk: the agent is about to answer it.
    ///
    /// `.systemInit` is never output: it is the handshake and lands in
    /// milliseconds, so counted, the row would blink once and never be
    /// seen, and no stall would ever be noticed. A compaction row is not
    /// the agent answering — the spinner stays under it — but it is
    /// something on screen, so the stall notice, which says nothing has
    /// come back, takes it as output (`compactionIsOutput`). A `!`
    /// command's output row (`.shellOutput`) is walked past too: it is the
    /// user's command's, and the agent's answer to it is still to come.
    static func awaitsAgent(_ events: [StreamEvent], compactionIsOutput: Bool) -> Bool {
        for event in events.reversed() {
            switch event.kind {
            case .userMessage where event.sentIntoTurn: continue
            case .userMessage: return true
            case .systemInit: continue
            case .compaction where !compactionIsOutput: continue
            case .shellOutput: continue
            default: return false
            }
        }
        return true
    }
}

/// One piece of work an agent left running in the background — a command
/// or an agent of claude's or kimi's, a background terminal of codex's —
/// in the agent's own terms.
struct BackgroundTaskEntry: Equatable {
    let id: String
    /// The agent's own kind for it: claude's `task_type` (`local_bash`,
    /// `local_agent`, …), kimi's `kind` (`process`, `agent`, …), codex's
    /// `command`.
    let kind: String
    /// What names it on screen: the description the tool call that started
    /// it gave, or for a codex terminal the command it runs.
    let description: String
}

/// The transcript's static line while a turn whose answer has landed waits
/// on background work it started: "Waiting for a background task: Run the
/// tests". Codex calls such work a background terminal, and its line says
/// so (`terminals`). No time in it: it changes only when the work does.
enum BackgroundTaskLine {

    /// The longest name the line spells out. A codex terminal is named by
    /// its command, which can be a script of many lines; its first line
    /// names it.
    static let nameLimit = 80

    static func text(_ tasks: [BackgroundTaskEntry], terminals: Bool) -> String {
        let names = tasks.map { shown($0.description) }.filter { !$0.isEmpty }
        let list = ListFormatter.localizedString(byJoining: names)
        if terminals {
            if tasks.count == 1 {
                return list.isEmpty
                    ? String(localized: "Waiting for a background terminal.",
                             comment: "Transcript line while Codex's answer has landed and the turn waits for a command still running in a background terminal; the command is unknown")
                    : String(localized: "Waiting for a background terminal: \(list)",
                             comment: "Transcript line while Codex's answer has landed and the turn waits for a command still running in a background terminal; placeholder is the command")
            }
            return list.isEmpty
                ? String(localized: "Waiting for \(tasks.count) background terminals.",
                         comment: "Transcript line while Codex's answer has landed and the turn waits for several commands still running in background terminals; placeholder is how many")
                : String(localized: "Waiting for \(tasks.count) background terminals: \(list)",
                         comment: "Transcript line while Codex's answer has landed and the turn waits for several commands still running in background terminals; placeholders are how many and the commands")
        }
        if tasks.count == 1 {
            return list.isEmpty
                ? String(localized: "Waiting for a background task.",
                         comment: "Transcript line while the agent's answer has landed and it waits for a background task it started; the task has no name")
                : String(localized: "Waiting for a background task: \(list)",
                         comment: "Transcript line while the agent's answer has landed and it waits for a background task it started; placeholder is the task's description")
        }
        return list.isEmpty
            ? String(localized: "Waiting for \(tasks.count) background tasks.",
                     comment: "Transcript line while the agent's answer has landed and it waits for several background tasks it started; placeholder is how many")
            : String(localized: "Waiting for \(tasks.count) background tasks: \(list)",
                     comment: "Transcript line while the agent's answer has landed and it waits for several background tasks it started; placeholders are how many and their descriptions")
    }

    /// A name as the line spells it: its first line that holds anything,
    /// cut at `nameLimit` characters.
    static func shown(_ name: String) -> String {
        let first = name.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return first.count > nameLimit ? String(first.prefix(nameLimit)) + "…" : first
    }
}

/// A headless claude turn's background tasks as claude reports them on
/// stdout, and the rule for when such a turn is over. `AgentRunner` feeds
/// it every stdout line of a claude turn (`read(line:)`) and every request
/// that goes to the model (`noteRequestStarted`): a tool's result going
/// back, or a new turn's `system/init`.
///
/// Claude keeps a run going while a background task it started is
/// running, and when one ends it hands the model the task's notification:
/// with the next request if the model is still working, or in a turn of
/// its own once the model has answered. So a `result` ends the turn only
/// when no task is running and no notification is still waiting for a
/// request. Read wrongly either way the turn misleads: ended at the first
/// answer, it looks finished while claude still works and the next send
/// kills the task; held for a notification a request already carried, it
/// waits for a turn that never comes, until claude exits.
///
/// A command that runs long in the FOREGROUND reports itself the same way
/// (`task_started` with `is_backgrounded: false`, then a notification)
/// and is no background task: it draws no notice and holds nothing.
struct ClaudeBackgroundTasks {

    /// The tasks claude counts as running, from its newest
    /// `background_tasks_changed` list.
    private(set) var running: [BackgroundTaskEntry] = []

    /// Notifications of background tasks that no request has carried to
    /// the model yet.
    private(set) var undelivered = 0

    /// Every background task this turn has seen, by id: a notification
    /// names its task by id alone.
    private var known: [String: BackgroundTaskEntry] = [:]

    /// Tasks the user stopped from the line naming them (`stop_task`).
    /// Measured: claude stops one at once, starts no turn to report it and
    /// keeps nothing of it in the transcript — so its notification is owed
    /// to no one and draws no notice, which a reopen would not draw either.
    private var stoppedByUser: Set<String> = []

    /// Whether this turn started a background task.
    var sawTask: Bool { !known.isEmpty }

    /// Whether a `result` is the turn's end: claude owes no report.
    var resultEndsTurn: Bool { running.isEmpty && undelivered == 0 }

    /// A request went to the model; it carries every notification claude
    /// had queued.
    mutating func noteRequestStarted() { undelivered = 0 }

    /// The user asked claude to stop this task.
    mutating func noteStoppedByUser(id: String) { stoppedByUser.insert(id) }

    /// Whether a task's notice drawn now goes into the turn claude is still
    /// working on — claude hands the model the notification with its next
    /// request — rather than opening the turn claude runs on it once it has
    /// answered: its report. Read off the live buffer, where claude works
    /// from each `system/init` to that turn's `result`.
    static func noticeGoesIntoRunningTurn(after events: [StreamEvent]) -> Bool {
        for event in events.reversed() {
            switch event.kind {
            case .systemInit: return true
            case .result: return false
            default: continue
            }
        }
        return true
    }

    /// Read one stdout line. Returns the notice to draw when the line
    /// reports a background task ending (`ClaudeTaskNotice`), nil for
    /// every other line.
    mutating func read(line: String) -> String? {
        guard line.contains("background_tasks_changed") || line.contains("task_started")
                || line.contains("task_notification"),
              let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["type"] as? String == "system"
        else { return nil }
        switch obj["subtype"] as? String {
        case "background_tasks_changed":
            running = ((obj["tasks"] as? [[String: Any]]) ?? []).compactMap(Self.entry)
            for task in running { known[task.id] = task }
            return nil
        case "task_started":
            if (obj["is_backgrounded"] as? Bool) == true, let task = Self.entry(obj) {
                known[task.id] = task
            }
            return nil
        case "task_notification":
            guard let id = obj["task_id"] as? String, let task = known[id],
                  !stoppedByUser.contains(id) else { return nil }
            undelivered += 1
            return ClaudeTaskNotice.text(status: obj["status"] as? String ?? "",
                                         summary: obj["summary"] as? String,
                                         kind: task.kind, description: task.description)
        default:
            return nil
        }
    }

    /// One task of claude's list or of its `task_started`. Nil for what
    /// claude keeps for itself (`ambient`, never drawn and never waited
    /// for) and for an agent its caller waits on (`awaited`) — neither is
    /// a background task.
    private static func entry(_ object: [String: Any]) -> BackgroundTaskEntry? {
        guard let id = object["task_id"] as? String, !id.isEmpty,
              (object["ambient"] as? Bool) != true,
              (object["awaited"] as? Bool) != true
        else { return nil }
        return BackgroundTaskEntry(id: id, kind: object["task_type"] as? String ?? "",
                                   description: object["description"] as? String ?? "")
    }
}
