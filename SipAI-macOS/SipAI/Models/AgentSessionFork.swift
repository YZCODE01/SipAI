// AgentSessionFork.swift
// Branch a Claude Code session at an earlier user message.
//
// "Edit an earlier message and continue from there" has no CLI flag:
// `claude -p` offers --resume (from the end), --continue, and
// --fork-session (also from the end). What it DOES accept is a session
// file we wrote ourselves, as long as it is a clean linear PREFIX of a
// real transcript with a new session id.
//
// (This file is claude's writer. `CodexSessionFork` and `KimiSessionFork`
// are the other two; they share this file's error vocabulary and
// `branchTitle`, and each speaks its own agent's format.)
//
// So a branch is a new session file:
//
//   ~/.claude/projects/<same project dir>/<new uuid>.jsonl
//       = the source's records up to (not including) the record the
//         user is editing, less any turn a rewind dropped above it
//         (`ClaudeConversationLine`), with `sessionId` rewritten and the
//         uuid/parentUuid chain left intact.
//
// then `claude --resume <new uuid> -p "<edited text>"`, which is what
// `AgentRunner` already does for any session with an id.
//
// Two facts hold this together, and one of them is a trap:
//
//  * A hand-written prefix file with a new session id resumes cleanly
//    and independently of the source.
//  * Appending a RE-PARENTED user record to the SAME file does NOT
//    branch it: claude ignores the injected record and attaches its
//    next turn to the real tail. Do not "simplify" this file into an
//    append.
//
// The source transcript is never modified. Everything here is read-only
// against it, and the branch is written to a temp file in the same
// directory and moved into place, so a half-written branch can never be
// scanned, resumed, or listed.

import Foundation

enum AgentSessionFork {

    // MARK: - Errors

    /// Shared by all three writers (`CodexSessionFork`, `KimiSessionFork`
    /// alias it): the sentences are about the message and the
    /// transcript, so one vocabulary serves every agent and the view
    /// catches one type.
    enum ForkError: LocalizedError {
        /// The record the row pointed at is no longer in the transcript
        /// (compacted away, or the file was rewritten under us).
        case cutPointNotFound
        /// Nothing above the cut point but bookkeeping — there is no
        /// conversation to branch FROM. The caller should start a fresh
        /// session with the edited text instead.
        case nothingToBranch
        case unreadableSource
        case writeFailed(String)
        /// The agent that forks its own threads (codex) gave no answer
        /// — no CLI, no app-server, or the ceiling passed. The view
        /// words this one with the agent's label; the description here
        /// names none.
        case agentUnavailable
        /// An agent SipAI has no branch writer for (`hasWriter`).
        case agentNotSupported

        var errorDescription: String? {
            switch self {
            case .agentNotSupported:
                return String(localized: "SipAI doesn’t support this for this agent yet.",
                              comment: "Refusal for an agent SipAI has no code for")
            case .agentUnavailable:
                return String(localized: "The command-line tool did not answer, so the branch was not created.",
                              comment: "Branch error when the agent's own fork call got no reply")
            case .cutPointNotFound:
                return String(localized: "Could not find that message in the session transcript — it may have been compacted away.",
                              comment: "Branch error when the cut-point record is gone")
            case .nothingToBranch:
                return String(localized: "There is nothing before that message to branch from.",
                              comment: "Branch error when the chosen message is the first one")
            case .unreadableSource:
                return String(localized: "Could not read the session transcript.",
                              comment: "Branch error when the source JSONL cannot be opened")
            case .writeFailed(let detail):
                return String(localized: "Could not write the branch: \(detail)",
                              comment: "Branch error when the new session file cannot be written")
            }
        }
    }

    struct Result {
        let sessionId: String
        let fileURL: URL
    }

    /// Whether a branch writer exists for `agentKey` — the agents the
    /// session view's branch dispatches on. Any other agent is offered no
    /// pencil: written as another agent's transcript, its branch would be
    /// a file its own CLI cannot read.
    static func hasWriter(agentKey: String) -> Bool {
        switch agentKey {
        case "claude_code", "codex", "kimi": return true
        default: return false
        }
    }

    // MARK: - Per-line rule (pure — exercised headless)

    /// What becomes of one source line in the branch.
    ///
    /// Split out as a pure function of (line, cut point, new id) so the
    /// rule can be exercised without a filesystem, the same way
    /// `ScheduledTaskScheduler.decide` and `TranscriptFollow` are. The
    /// streaming copy below is then only plumbing.
    enum LineVerdict: Equatable {
        /// Rewritten line, ready to write.
        case keep(String)
        /// Claude bookkeeping the branch must not inherit.
        case drop
        /// The cut point — the branch ends ABOVE this line.
        case stop
    }

    static func verdict(forLine line: String,
                        cutAtRecordUuid: String,
                        newSessionId: String) -> LineVerdict {
        guard let obj = record(line) else {
            // Unparseable: a line torn by a live writer at EOF, or
            // garbage. It cannot be the cut point and its `sessionId`
            // cannot be rewritten, so carrying it forward would plant
            // the SOURCE's id inside the branch. Drop it.
            return .drop
        }
        return verdict(forRecord: obj, cutAtRecordUuid: cutAtRecordUuid,
                       newSessionId: newSessionId)
    }

    private static func record(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func verdict(forRecord record: [String: Any],
                        cutAtRecordUuid: String,
                        newSessionId: String) -> LineVerdict {
        var obj = record
        if (obj["uuid"] as? String) == cutAtRecordUuid {
            return .stop
        }
        // The branch is a different conversation from here on; letting
        // it inherit the parent's title would put two rows in the
        // sidebar under one name. The branch is named from the edited
        // message instead (see the caller), and claude is free to write
        // its own ai-title later.
        //
        // BOTH title records go. `ai-title` is the generated one;
        // `custom-title` is the one a rename writes, in either app, and
        // it outranks the generated title — so carrying it forward
        // would pin the branch to its parent's name for good, past
        // anything claude later generates for it.
        if let type = obj["type"] as? String,
           type == "ai-title" || type == "custom-title" {
            return .drop
        }
        // A branch of a SCHEDULED run is not another run of that task —
        // the user started it by hand. The `<scheduled-task name="…">`
        // marker in the prefix's first user record is what both scanners
        // file a session under, so carrying it forward would nest the
        // branch inside the task, count it among the task's runs, and
        // drag the task's "last active" to now. The marker is a paired
        // EMPTY tag with the prompt outside it, so removing it costs the
        // record nothing else; a record without one is handed back as it
        // was.
        if (obj["type"] as? String) == "user" {
            obj["message"] = strippingScheduledTaskMarker(obj["message"])
        }
        // Every record that carries the session id has to be re-pointed;
        // `uuid`/`parentUuid` are deliberately left alone so the chain
        // the prefix already forms stays valid.
        if obj["sessionId"] is String {
            obj["sessionId"] = newSessionId
        }
        // A line can hold a number JSON cannot write back (`1e400` reads
        // as infinity); serialising it raises an exception no `try?`
        // catches, so it is dropped here instead of aborting the app.
        guard JSONSerialization.isValidJSONObject(obj),
              let out = try? JSONSerialization.data(
            withJSONObject: obj, options: [.withoutEscapingSlashes]),
              let text = String(data: out, encoding: .utf8)
        else {
            return .drop
        }
        return .keep(text)
    }

    private static let scheduledTaskMarker = try? NSRegularExpression(
        pattern: #"<scheduled-task\b[^>]*>[\s\S]*?</scheduled-task>"#)

    /// Remove the scheduled-run marker from a user record's message,
    /// leaving the prompt. Handles both content shapes claude writes (a
    /// plain string, or an array of blocks).
    ///
    /// Refuses to empty a record: if the marker was the whole content,
    /// the message is left exactly as it was. An empty text block is not
    /// something to hand to the API to find out about, and a branch that
    /// keeps one stray marker is a far smaller problem than a branch
    /// that won't resume.
    static func strippingScheduledTaskMarker(_ message: Any?) -> Any? {
        guard var dict = message as? [String: Any] else { return message }
        func stripped(_ text: String) -> String? { strippedScheduledTaskMarker(fromText: text) }
        if let s = dict["content"] as? String {
            guard let out = stripped(s) else { return message }
            dict["content"] = out
            return dict
        }
        if let blocks = dict["content"] as? [Any] {
            var changed = false
            let rewritten: [Any] = blocks.map { block in
                guard var b = block as? [String: Any],
                      b["type"] as? String == "text",
                      let t = b["text"] as? String,
                      let out = stripped(t) else { return block }
                b["text"] = out
                changed = true
                return b
            }
            guard changed else { return message }
            dict["content"] = rewritten
            return dict
        }
        return message
    }

    /// `text` without the scheduled-run marker, or nil when it holds none
    /// — or holds nothing else, which is left as it is (see above).
    static func strippedScheduledTaskMarker(fromText text: String) -> String? {
        guard text.contains("<scheduled-task"), let regex = scheduledTaskMarker else { return nil }
        let out = regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// True when a prefix holds an actual conversation — at least one
    /// user record and one non-synthetic assistant record. A prefix of
    /// pure bookkeeping (`queue-operation`, `mode`) would scan as an
    /// empty shell, be hidden from the sidebar, and resume with no
    /// context at all; that is a new session, not a branch.
    static func prefixHoldsConversation(_ lines: [String]) -> Bool {
        var sawUser = false
        var sawAssistant = false
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "user":
                // A tool_result round-trip is claude answering itself.
                if obj["toolUseResult"] != nil,
                   !(obj["toolUseResult"] is NSNull) { continue }
                sawUser = true
            case "assistant":
                let model = ((obj["message"] as? [String: Any])?["model"]
                                as? String) ?? ""
                if model != "<synthetic>" { sawAssistant = true }
            default:
                continue
            }
            if sawUser && sawAssistant { return true }
        }
        return false
    }

    // MARK: - Cut-point resolution

    /// The `uuid` of the newest turn-opening user record whose visible
    /// text matches `text`.
    ///
    /// History rows carry their record uuid outright
    /// (`AgentSessionHistoryItem.recordUuid`); this is for LIVE rows —
    /// the message you sent a minute ago, still in the runner's event
    /// buffer, which never went through the transcript reader. Matching
    /// on the cleaned text is the same identification
    /// `TranscriptSeam.cut` already makes between a live event and its
    /// record.
    ///
    /// Newest-first, because a repeated prompt ("continue") should
    /// branch at the one you can see, not at its first occurrence —
    /// and `skippingNewest` is how many newer occurrences of the same
    /// text the caller can see BELOW the one it means, so the pencil on
    /// the older of two identical live rows cuts at that one.
    ///
    /// A message of attached files alone has no words to match: its
    /// record is the one with no words whose attachment markers name
    /// `files`, the live row's own (`StreamEvent.attachedFiles`), read
    /// through the same `AttachmentInline.names` the reader draws the
    /// paperclip line with.
    /// Reads files; call it off the main thread.
    static func resolveCutPoint(matchingUserText text: String,
                                attachedFiles files: [String] = [],
                                in url: URL,
                                skippingNewest skip: Int = 0) -> String? {
        // The reader's own normalisation on BOTH sides: it sweeps bare
        // `<…>` tags out of a record's text (`cleanUserText`), so a
        // message that spells a generic type (`Vec<String>`) matches its
        // record only once the wanted text has been through the same
        // cleaner.
        let wanted = AgentSessionScanner.cleanUserText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty || !files.isEmpty else { return nil }
        // Escalating windows, for the same reason `lastLaunchOptions`
        // needs them: a tool-heavy turn buries its opening user record
        // well past the standard tail. They count conversation bytes
        // (`AgentSessionScanner.conversationTail`), not claude's request
        // records.
        for budget in [256 * 1024, 4 * 1024 * 1024, 64 * 1024 * 1024] {
            guard let tail = AgentSessionScanner.conversationTail(of: url, budget: budget)
            else { break }
            if let found = cutPointScan(text: wanted, files: files, window: tail.text,
                                        skippingNewest: skip) {
                return found
            }
            if tail.reachedStart { break }
        }
        return nil
    }

    private static func cutPointScan(text: String, files: [String], window: String,
                                     skippingNewest skip: Int) -> String? {
        var remaining = skip
        var seen = Set<String>()
        let lines = Array(window.split(separator: "\n").reversed())
        // A turn a rewind dropped is still in the file with the same words
        // as a message on screen; matched newest-first, it would take the
        // cut meant for the older message the user is editing.
        var conversation = ClaudeConversationLine()
        for line in lines.reversed() {
            if let data = line.trimmingCharacters(in: .whitespaces).data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                conversation.note(obj)
            }
        }
        let dropped = conversation.dropped()
        for (index, line) in lines.enumerated() {
            // Cheap pre-filter; correctness comes from the parse.
            guard line.contains("\"user\"") else { continue }
            guard let data = line.trimmingCharacters(in: .whitespaces)
                    .data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  obj["type"] as? String == "user",
                  (obj["isSidechain"] as? Bool) != true,
                  (obj["isMeta"] as? Bool) != true,
                  obj["toolUseResult"] == nil || obj["toolUseResult"] is NSNull,
                  let uuid = obj["uuid"] as? String,
                  !dropped.contains(uuid),
                  // One record, one occurrence — the reader's rule
                  // (`readHistory`). Claude writes a message's record a
                  // second time under the same uuid when it compacts
                  // right before sending it (a message sent once more
                  // after "Prompt is too long"); counted twice, the copy
                  // takes the skip meant for the older identical row, and
                  // that row's pencil cuts at the wrong message.
                  seen.insert(uuid).inserted
            else { continue }
            let msg = obj["message"] as? [String: Any] ?? [:]
            let raw = AgentSessionScanner.extractText(
                fromContent: msg["content"] ?? obj["content"] ?? "")
            let body = AgentSessionScanner.cleanUserText(raw)
            // A command the user typed is drawn in the words they typed
            // (`ClaudeSkillLoadReader`), which is not how its record's
            // wrappers clean — so a live `/name words` row is matched in
            // that spelling too.
            let typed = SkillRecords.claudeCommand(in: raw).map { command in
                command.args.isEmpty
                    ? "/" + command.name
                    : "/" + command.name + " " + AgentSessionScanner.cleanUserText(command.args)
            }
            guard body == text || typed == text else { continue }
            // No words: every record of files alone reads the same, and
            // the files are what tell this one apart.
            guard !text.isEmpty || AttachmentInline.names(in: raw) == files else { continue }
            if remaining == 0 {
                return skillLoadsAbove(lines[(index + 1)...]) ?? uuid
            }
            remaining -= 1
        }
        return nil
    }

    /// The first record of the skill loads a message rode in with, read
    /// upward from just above it (`older`, newest first) — the handle the
    /// reopened row carries (`ClaudeSkillLoadReader`), so a branch cut
    /// at the live row leaves the loads out with the message, exactly as
    /// one cut at the reopened row does. Nil when no load sits there.
    private static func skillLoadsAbove<S: Sequence>(_ older: S) -> String?
    where S.Element == Substring {
        var cut: String? = nil
        // The expansion read just below the record being looked at —
        // whether its text alone says so, and the prompt it belongs to.
        // Read upward, the expansion comes BEFORE its command, so which
        // command it follows is settled one record later.
        var body: (certain: Bool, promptId: String?)? = nil
        for line in older {
            guard let data = line.trimmingCharacters(in: .whitespaces)
                    .data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any]
            else { continue }
            let type = obj["type"] as? String
            guard type == "user" else {
                // Bookkeeping between the loads (`attachment`,
                // `queue-operation`) belongs to them; a message from
                // anyone ends the run.
                if type == "assistant" || type == "system" { break }
                continue
            }
            if obj["toolUseResult"] != nil, !(obj["toolUseResult"] is NSNull) { break }
            let msg = obj["message"] as? [String: Any] ?? [:]
            let raw = AgentSessionScanner.extractText(
                fromContent: msg["content"] ?? obj["content"] ?? "")
            if (obj["isMeta"] as? Bool) == true {
                guard body == nil else { break }
                body = (SkillRecords.isClaudeSkillBody(raw), obj["promptId"] as? String)
                continue
            }
            guard let expansion = body,
                  let command = SkillRecords.claudeCommand(in: raw),
                  command.args.isEmpty,
                  expansion.certain
                    || (expansion.promptId != nil && expansion.promptId == obj["promptId"] as? String),
                  let uuid = obj["uuid"] as? String
            else { break }
            cut = uuid
            body = nil
        }
        return cut
    }

    // MARK: - Fork

    /// Read chunk for the streaming copy. The prefix can be the whole of
    /// a multi-hundred-MB transcript, so this never holds more than one
    /// chunk plus one line in memory — the same discipline every other
    /// reader in this app keeps (`boundedTail`, the runner's stdout
    /// loop, the tailer).
    private static let copyChunk = 1 << 20   // 1 MiB

    /// Write the branch. Returns the new session id and its file.
    ///
    /// Reads and writes files, and parses every line of the prefix.
    /// Call it off the main thread.
    static func fork(source: URL,
                     cutAtRecordUuid: String) throws -> Result {
        let newSessionId = UUID().uuidString.lowercased()
        let directory = source.deletingLastPathComponent()
        let destination = directory
            .appendingPathComponent("\(newSessionId).jsonl")
        // Staged in the same directory (so the move is atomic and stays
        // on one volume) and DOT-PREFIXED, because every scanner in this
        // app walks that directory with `.skipsHiddenFiles` — a branch
        // that is still being written must not be listed, opened, or
        // resumed.
        let staging = directory
            .appendingPathComponent(".sipai-branch-\(newSessionId).jsonl")

        guard let reader = try? FileHandle(forReadingFrom: source) else {
            throw ForkError.unreadableSource
        }
        defer { try? reader.close() }

        // Each kept line with the record it came from — and, for a
        // `last-prompt`, the leaf it names — so a turn a rewind dropped
        // above the cut stays out of the branch: claude resumes a branch
        // from its newest record, and a dropped turn copied in would
        // become the conversation the branch continues.
        var kept: [(uuid: String?, leaf: String?, line: String)] = []
        var conversation = ClaudeConversationLine()
        var cutParent: String?
        var leftover = Data()
        var reachedCut = false

        func consume(_ lineData: Data) -> Bool {
            // Lossy decode on purpose: a read can land inside a
            // multibyte character of a file another claude is writing,
            // and a strict decode would fail the WHOLE branch over one
            // edge line. Same rule as `readHistory`.
            let line = String(decoding: lineData, as: UTF8.self)
            guard let obj = record(line) else { return true }
            switch verdict(forRecord: obj,
                           cutAtRecordUuid: cutAtRecordUuid,
                           newSessionId: newSessionId) {
            case .stop:
                cutParent = (obj["parentUuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return false
            case .drop:
                conversation.note(obj)
                return true
            case .keep(let rewritten):
                conversation.note(obj)
                let isMarker = obj["type"] as? String == "last-prompt"
                kept.append((obj["uuid"] as? String,
                             isMarker ? obj["leafUuid"] as? String : nil,
                             rewritten))
                return true
            }
        }

        outer: while true {
            let chunk = (try? reader.read(upToCount: copyChunk)) ?? Data()
            if chunk.isEmpty { break }
            leftover.append(chunk)
            while let nl = leftover.firstIndex(of: 0x0A) {
                let lineData = leftover.subdata(
                    in: leftover.startIndex..<nl)
                leftover.removeSubrange(leftover.startIndex...nl)
                if !consume(lineData) { reachedCut = true; break outer }
            }
        }
        // A final line with no trailing newline (the file's very last
        // record while claude is mid-write).
        if !reachedCut, !leftover.isEmpty {
            if !consume(leftover) { reachedCut = true }
        }

        guard reachedCut else { throw ForkError.cutPointNotFound }
        // The line above the edited message: its parent and that
        // parent's line. A message with no parent opens the conversation,
        // and nothing above it is the conversation — a turn a rewind to
        // the very start dropped is still there in the file.
        let lines: [String]
        if let cutParent {
            let dropped = conversation.dropped(endingAt: cutParent)
            lines = kept.filter { line in
                !(line.uuid.map(dropped.contains) ?? false)
                    && !(line.leaf.map(dropped.contains) ?? false)
            }.map(\.line)
        } else {
            lines = []
        }
        guard prefixHoldsConversation(lines) else {
            throw ForkError.nothingToBranch
        }

        let payload = Data((lines.joined(separator: "\n") + "\n").utf8)
        do {
            try payload.write(to: staging, options: .atomic)
            // Never overwrite: `newSessionId` is a fresh UUID, so a
            // collision means something is very wrong and silently
            // clobbering someone's transcript is the worst possible
            // answer.
            guard !FileManager.default.fileExists(atPath: destination.path)
            else {
                try? FileManager.default.removeItem(at: staging)
                throw ForkError.writeFailed("session id collision")
            }
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch let error as ForkError {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw ForkError.writeFailed(error.localizedDescription)
        }
        return Result(sessionId: newSessionId, fileURL: destination)
    }

    // MARK: - Naming

    /// Sidebar name for a branch, derived from the message that starts
    /// it — the same rule the scanner uses to title a session with no
    /// ai-title, applied up front because the branch inherits none (the
    /// parent's is dropped) and a branch must not sit in the list under
    /// its parent's name.
    static func branchTitle(from text: String) -> String {
        let collapsed = AgentSessionScanner.cleanUserText(text)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !collapsed.isEmpty else {
            return String(localized: "Branch",
                          comment: "Fallback sidebar name for a session branch with no usable text")
        }
        return collapsed.count > 50
            ? String(collapsed.prefix(47)) + "..."
            : collapsed
    }
}
