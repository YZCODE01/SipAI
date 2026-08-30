// AgentSessionFork.swift
// Branch a Claude Code session at an earlier user message.
//
// "Edit an earlier message and continue from there" has no CLI flag:
// `claude -p` offers --resume (from the end), --continue, and
// --fork-session (also from the end). What it DOES accept is a session
// file we wrote ourselves, as long as it is a clean linear PREFIX of a
// real transcript with a new session id.
//
// So a branch is a new session file:
//
//   ~/.claude/projects/<same project dir>/<new uuid>.jsonl
//       = every record of the source up to (not including) the record
//         the user is editing, with `sessionId` rewritten and the
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

        var errorDescription: String? {
            switch self {
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
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .drop }
        guard let data = trimmed.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any]
        else {
            // Unparseable: a line torn by a live writer at EOF, or
            // garbage. It cannot be the cut point and its `sessionId`
            // cannot be rewritten, so carrying it forward would plant
            // the SOURCE's id inside the branch. Drop it.
            return .drop
        }
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
        // record nothing else.
        if (obj["type"] as? String) == "user",
           trimmed.contains("<scheduled-task") {
            obj["message"] = strippingScheduledTaskMarker(obj["message"])
        }
        // Every record that carries the session id has to be re-pointed;
        // `uuid`/`parentUuid` are deliberately left alone so the chain
        // the prefix already forms stays valid.
        if obj["sessionId"] is String {
            obj["sessionId"] = newSessionId
        }
        guard let out = try? JSONSerialization.data(
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
        guard var dict = message as? [String: Any],
              let regex = scheduledTaskMarker else { return message }
        func stripped(_ text: String) -> String? {
            guard text.contains("<scheduled-task") else { return nil }
            let out = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? nil : out
        }
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
    /// `AgentSessionView.trimmedForInFlight` already makes between a
    /// live event and its record.
    ///
    /// Newest-first, because a repeated prompt ("continue") should
    /// branch at the one you can see, not at its first occurrence.
    /// Reads files; call it off the main thread.
    static func resolveCutPoint(matchingUserText text: String,
                                in url: URL) -> String? {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        // Escalating windows, for the same reason `lastLaunchOptions`
        // needs them: a tool-heavy turn buries its opening user record
        // well past the standard tail.
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        for budget in [256 * 1024, 4 * 1024 * 1024, 64 * 1024 * 1024] {
            if let found = cutPointScan(text: wanted, in: url, budget: budget) {
                return found
            }
            if let size, size <= UInt64(budget) { break }
        }
        return nil
    }

    private static func cutPointScan(text: String, in url: URL,
                                     budget: Int) -> String? {
        guard let window = AgentSessionScanner.boundedTail(of: url,
                                                           budget: budget)
        else { return nil }
        for line in window.split(separator: "\n").reversed() {
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
                  let uuid = obj["uuid"] as? String
            else { continue }
            let msg = obj["message"] as? [String: Any] ?? [:]
            let body = AgentSessionScanner.cleanUserText(
                AgentSessionScanner.extractText(
                    fromContent: msg["content"] ?? obj["content"] ?? ""))
            if body == text { return uuid }
        }
        return nil
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

        var kept: [String] = []
        var leftover = Data()
        var reachedCut = false

        func consume(_ lineData: Data) -> Bool {
            // Lossy decode on purpose: a read can land inside a
            // multibyte character of a file another claude is writing,
            // and a strict decode would fail the WHOLE branch over one
            // edge line. Same rule as `readHistory`.
            let line = String(decoding: lineData, as: UTF8.self)
            switch verdict(forLine: line,
                           cutAtRecordUuid: cutAtRecordUuid,
                           newSessionId: newSessionId) {
            case .stop:  return false
            case .drop:  return true
            case .keep(let rewritten):
                kept.append(rewritten)
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
        guard prefixHoldsConversation(kept) else {
            throw ForkError.nothingToBranch
        }

        let payload = Data((kept.joined(separator: "\n") + "\n").utf8)
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
