// AgentSessionRewind.swift
// Edit an earlier message IN PLACE: the session goes back to the edited
// message and the edit is sent there, as each tool's own terminal does it
// (Claude Code's /rewind, Codex's Esc Esc "edit previous message", Kimi
// Code's /undo). Create Branch (`AgentSessionFork` and its two siblings)
// is the other way to edit a message: a new session, this one kept.
//
// Each agent through its own mechanism; this app writes nothing into a
// store:
//
//  * Claude — one flag on the turn that sends the edit: `-p --resume <id>
//    --resume-session-at <the entry above the edited message>`
//    (`ClaudeCapabilities.resumeSessionAtFlag`, which also reads whether
//    the installed claude has it: the flag is not in `--help`). Claude
//    parents the new message at that entry; the replaced turns stay in
//    the file as a branch it never loads again, which the reader leaves
//    out (`ClaudeConversationLine`).
//  * Codex — `thread/revert {threadId, beforeTurnId}` over its app-server,
//    the thread loaded first (`thread/resume`; alone the revert answers
//    "thread not found"). The thread keeps its id and goes on in a new
//    rollout whose `history_base` names the kept prefix; the next send —
//    `codex exec resume`, or the app-server's own turn — continues there.
//  * Kimi — its local server's `POST /api/v1/sessions/<id>:undo`, the call
//    its own `/undo` makes. A kimi from `kimiTurnUndoFloor` names the turn
//    the edited message opened (`{turn_id}`, an id only its own turn list
//    gives: `GET …/agents/main/turns`), and undoes that turn and every one
//    after it; an older one takes `{count}`, the turns from the edited
//    message to the end, as kimi counts them. The installed version
//    decides which goes, never a second try in the other shape: the
//    newer kimi refuses a count, but an older one reads any body as a
//    count — one, when it gives none — so a body naming a turn would take
//    back the wrong turns there. Kimi answers a refusal with a non-zero
//    `code`, its sentence in `msg`.
//
// The first message has nothing above it to go back to: claude has no
// entry to resume at, and codex refuses to empty a thread, so the caller
// starts a new session instead, as Create Branch does
// (`ForkError.nothingToBranch`). Files the agent changed are not touched.

import Foundation

enum AgentSessionRewind {

    typealias ForkError = AgentSessionFork.ForkError

    /// The tool said no, in its own words ("Nothing to undo: would cross a
    /// compaction boundary", "the selected prompt belongs to a turn that
    /// is still in progress") — the whole explanation, shown as it is.
    enum RewindError: LocalizedError {
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .refused(let words): return words
            }
        }
    }

    // MARK: - Claude

    /// Where claude resumes to edit a record in place.
    enum ClaudeAnchor: Equatable {
        /// The record's own parent — the last entry above the message.
        case entry(String)
        /// Nothing above the record holds a conversation.
        case firstMessage
        case notFound
    }

    /// The entry above record `uuid` — the parent of its NEWEST copy
    /// (claude writes a message twice under one uuid when it compacts
    /// right before sending it, and its own map keeps the last). Read off
    /// escalating tail windows; the message being edited is usually near
    /// the end.
    ///
    /// `.firstMessage` when the line above the record holds no real
    /// exchange — no parent at all, or only bookkeeping and a slash
    /// command's answer up to the top. That is the rule a branch's prefix
    /// is held to (`AgentSessionFork.prefixHoldsConversation`): the edit
    /// would resume with no context, which is a new session.
    nonisolated static func claudeAnchor(aboveRecord uuid: String, in url: URL) -> ClaudeAnchor {
        guard !uuid.isEmpty else { return .notFound }
        // Conversation bytes (`AgentSessionScanner.conversationTail`):
        // claude's request records hang off nothing and hold no message.
        let budgets = [256 * 1024, 4 * 1024 * 1024, 64 * 1024 * 1024]
        for budget in budgets {
            guard let tail = AgentSessionScanner.conversationTail(of: url, budget: budget)
            else { break }
            let window = tail.text
            let whole = tail.reachedStart
            // Every main-line record in the window: what it hangs off, and
            // its line. A later copy replaces an earlier one.
            var records: [String: (above: String?, line: String)] = [:]
            for raw in window.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard let data = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let id = obj["uuid"] as? String, !id.isEmpty,
                      (obj["isSidechain"] as? Bool) != true else { continue }
                records[id] = (ClaudeConversationLine.entryAbove(obj), line)
            }
            guard let found = records[uuid] else {
                if whole { break }
                continue
            }
            guard let parent = found.above else { return .firstMessage }
            var chain: [String] = []
            var seen = Set<String>()
            var cursor: String? = parent
            var runsAboveWindow = false
            while let id = cursor, seen.insert(id).inserted {
                guard let record = records[id] else {
                    runsAboveWindow = !whole
                    break
                }
                chain.append(record.line)
                cursor = record.above
            }
            if AgentSessionFork.prefixHoldsConversation(chain) { return .entry(parent) }
            if !runsAboveWindow { return .firstMessage }
            // The line goes on above the widest window: there is more
            // conversation up there than any tail read here can hold.
            if budget == budgets.last { return .entry(parent) }
        }
        return .notFound
    }

    // MARK: - Codex

    /// The revert as codex's app-server takes it: the thread loaded first,
    /// then reverted to the prefix before `beforeTurnId`. Ids 2 and 3.
    nonisolated static func codexRevertRequests(threadId: String, beforeTurnId: String) -> [String]? {
        let resume: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "thread/resume",
                                     "params": ["threadId": threadId, "excludeTurns": true]]
        let revert: [String: Any] = ["jsonrpc": "2.0", "id": 3, "method": "thread/revert",
                                     "params": ["threadId": threadId, "beforeTurnId": beforeTurnId]]
        var lines: [String] = []
        for request in [resume, revert] {
            guard JSONSerialization.isValidJSONObject(request),
                  let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
            lines.append(String(decoding: data, as: UTF8.self))
        }
        return lines
    }

    enum CodexOutcome: Equatable {
        /// The thread's current rollout now: the revert's new segment.
        case reverted(URL)
        /// Codex's own words.
        case refused(String)
        /// A codex that does not know the request.
        case unsupported
        /// No app-server, or no answer inside its ceiling.
        case unavailable
    }

    /// The revert's answer, read the way the protocol spells it:
    /// `result.thread.path` (the new segment, absolute) or an `error` whose
    /// `message` is codex's sentence; `-32601` is a method it does not have.
    nonisolated static func codexRevertOutcome(from answers: [Int: [String: Any]]) -> CodexOutcome {
        // A load codex refused — the thread is gone, or another codex holds
        // it (its terminal's server keeps a thread loaded while idle) — is
        // the reason, whatever the revert then answered without it.
        if let error = answers[2]?["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return .refused(message)
        }
        guard let answer = answers[3] else { return .unavailable }
        if let result = answer["result"] as? [String: Any],
           let thread = result["thread"] as? [String: Any],
           let path = thread["path"] as? String, !path.isEmpty {
            return .reverted(URL(fileURLWithPath: path))
        }
        if let error = answer["error"] as? [String: Any] {
            if (error["code"] as? NSNumber)?.intValue == -32601 { return .unsupported }
            let message = (error["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "thread/revert failed"
            return .refused(message)
        }
        return .unavailable
    }

    /// Revert through codex. Reads nothing, writes nothing itself: codex
    /// writes the new segment.
    static func revertCodex(threadId: String, beforeTurnId: String,
                            binary: String) async -> CodexOutcome {
        guard let requests = codexRevertRequests(threadId: threadId, beforeTurnId: beforeTurnId)
        else { return .refused("could not build the request") }
        let answers = await CodexAppServerCall.run(binary: binary, requests: requests,
                                                   awaiting: [2, 3])
        return codexRevertOutcome(from: answers)
    }

    // MARK: - Kimi

    /// How kimi's undo is asked to edit the message `promptId` opened.
    enum KimiCount: Equatable {
        /// The turns from the message to the end, as kimi counts them.
        case count(Int)
        /// The message opens kimi's conversation: nothing above it.
        case firstMessage
        case notFound
    }

    /// The turns an undo takes back for an edit of `promptId`: kimi's undo
    /// anchors from that message to the end, after every undo the wire
    /// already holds is folded the way kimi folds it
    /// (`KimiSessionScanner.UndoFold`) — counted over the raw records, an
    /// earlier undo's turns would be counted again and kimi asked to take
    /// back more than the user meant.
    nonisolated static func kimiUndoCount(forPrompt promptId: String, in wire: URL) -> KimiCount {
        guard !promptId.isEmpty else { return .notFound }
        let size = ((try? FileManager.default.attributesOfItem(atPath: wire.path))?[.size]
                    as? NSNumber)?.intValue ?? 0
        for budget in [4 * 1024 * 1024, 64 * 1024 * 1024] {
            guard let window = AgentSessionScanner.boundedTail(of: wire, budget: budget) else { break }
            let whole = size <= budget
            var anchors: [String?] = []
            var undo = KimiSessionScanner.UndoFold()
            var currentPrompt: String? = nil
            for line in window.split(separator: "\n") {
                guard let data = line.trimmingCharacters(in: .whitespaces).data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { continue }
                if let prompt = KimiSessionScanner.turnPromptId(obj) {
                    currentPrompt = prompt
                    continue
                }
                let signal = KimiSessionScanner.UndoFold.signal(of: obj)
                if let cut = undo.apply(signal, at: anchors.count, windowIsWhole: whole) {
                    anchors.removeSubrange(cut...)
                }
                guard signal == .anchor else { continue }
                let id = ((obj["message"] as? [String: Any])?["id"] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 } ?? currentPrompt
                anchors.append(id)
            }
            if let at = anchors.lastIndex(where: { $0 == promptId }) {
                if at == 0, whole { return .firstMessage }
                return .count(anchors.count - at)
            }
            if whole { break }
        }
        return .notFound
    }

    /// The route kimi's own `/undo` calls, for `sessionId`.
    nonisolated static func kimiUndoPath(sessionId: String) -> String? {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !sessionId.isEmpty,
              let encoded = sessionId.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return "/api/v1/sessions/\(encoded):undo"
    }

    enum KimiOutcome: Equatable {
        case undone
        /// Kimi's own words.
        case refused(String)
    }

    /// Kimi's answer to the undo: `code` 0 is done; anything else is a
    /// refusal in `msg` ("Nothing to undo: would cross a compaction
    /// boundary"), on an HTTP 200 like a success.
    nonisolated static func kimiUndoOutcome(from data: Data) -> KimiOutcome {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = (obj["code"] as? NSNumber)?.intValue else {
            return .refused(String(decoding: data.prefix(300), as: UTF8.self))
        }
        if code == 0 { return .undone }
        let message = (obj["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "code \(code)"
        return .refused(message)
    }

    /// What to say for an answer of kimi's that SipAI cannot use: kimi's
    /// own words when it refused, else the answer itself.
    nonisolated static func kimiWords(in data: Data) -> String {
        if case .refused(let words) = kimiUndoOutcome(from: data) { return words }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }

    /// The kimi whose undo names a TURN (`{turn_id}`), measured: its turn
    /// ids are a hash of a counter only kimi's server holds
    /// (`t_` + 12 hex digits), so the id comes from its own turn list.
    /// An older kimi takes the count of turns (`{count}`), one when the
    /// body gives none; this one refuses the count ("Invalid input → at
    /// turn_id"). Sending an older kimi a turn id would undo one turn,
    /// whichever was meant.
    static let kimiTurnUndoFloor = "2.6.1"

    /// Whether the installed kimi's undo names a turn. A version not read
    /// yet answers no: the count is the measured older call.
    nonisolated static func kimiUndoNamesTurn(kimiVersion: String?) -> Bool {
        ChatOnlyAvailability.versionAtLeast(kimiVersion, kimiTurnUndoFloor)
    }

    /// The route kimi's server lists the main agent's turns at, oldest
    /// first: its newest page, or the turns below `beforeOrdinal`.
    nonisolated static func kimiTurnsPath(sessionId: String, beforeOrdinal: Int? = nil) -> String? {
        guard let undo = kimiUndoPath(sessionId: sessionId) else { return nil }
        let session = undo.dropLast(":undo".count)
        let below = beforeOrdinal.map { "&before_ordinal=\($0)" } ?? ""
        return "\(session)/agents/main/turns?page_size=200\(below)"
    }

    /// What one page of kimi's turn list says about the turn `messageId`
    /// opened.
    struct KimiTurnsPage: Equatable {
        /// The turn the message opened, when this page holds it.
        var turnId: String?
        /// The page's lowest ordinal: the next page is the turns below it.
        var oldestOrdinal: Int?
        var hasMore: Bool
    }

    /// Read a page of kimi's turn list (`{code: 0, data: {turns,
    /// has_more}}`). A turn is named by the message that opens it: its
    /// `user_message` item placed as the opener carries the message's id
    /// as `item_id` and its prompt among `prompt_ids` — the id SipAI's rows
    /// carry (`message.id`). Nil for an answer of another shape.
    nonisolated static func kimiTurnsPage(from data: Data, messageId: String) -> KimiTurnsPage? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["code"] as? NSNumber)?.intValue == 0,
              let page = obj["data"] as? [String: Any],
              let turns = page["turns"] as? [[String: Any]] else { return nil }
        var result = KimiTurnsPage(turnId: nil, oldestOrdinal: nil,
                                   hasMore: (page["has_more"] as? Bool) ?? false)
        for turn in turns {
            if let ordinal = (turn["ordinal"] as? NSNumber)?.intValue {
                result.oldestOrdinal = min(result.oldestOrdinal ?? ordinal, ordinal)
            }
            let opener = (turn["items"] as? [[String: Any]])?.first {
                $0["type"] as? String == "user_message" && $0["placement"] as? String == "opener"
            }
            guard let opener, !messageId.isEmpty,
                  opener["item_id"] as? String == messageId
                    || ((opener["prompt_ids"] as? [String]) ?? []).contains(messageId),
                  let id = turn["turn_id"] as? String, !id.isEmpty else { continue }
            result.turnId = id
        }
        return result
    }

    // MARK: - The edited message, per agent

    // Each finds the edited message the way a branch finds it: a history
    // row by the record handle it carries (`recordUuid`), a live row by
    // its words, newest first past `skippingNewer` identical newer live
    // rows — or, for a message of attached files alone, by the files it
    // named (`attachedFiles`, the live row's own; empty for any other row).
    // `ForkError.nothingToBranch` is a first message — nothing above it to
    // go back to — which starts a new session instead.

    /// Claude: the entry the edit's turn resumes at. Nothing is written
    /// until that turn runs.
    nonisolated static func claudeResumeEntry(recordUuid: String?, in url: URL,
                                              originalText: String,
                                              attachedFiles: [String] = [],
                                              skippingNewer: Int) throws -> String {
        guard let cut = recordUuid
                ?? AgentSessionFork.resolveCutPoint(matchingUserText: originalText,
                                                    attachedFiles: attachedFiles, in: url,
                                                    skippingNewest: skippingNewer)
        else { throw ForkError.cutPointNotFound }
        switch claudeAnchor(aboveRecord: cut, in: url) {
        case .entry(let entry): return entry
        case .firstMessage: throw ForkError.nothingToBranch
        case .notFound: throw ForkError.cutPointNotFound
        }
    }

    /// Codex: the turn the revert cuts before — the edited message's own,
    /// inherited or not.
    nonisolated static func codexRevertTurn(recordUuid: String?, in url: URL,
                                            originalText: String,
                                            attachedFiles: [String] = [],
                                            skippingNewer: Int) throws -> String {
        guard let cut = recordUuid
                ?? CodexSessionFork.resolveCutPoint(matchingUserText: originalText,
                                                    attachedFiles: attachedFiles, in: url,
                                                    skippingNewest: skippingNewer)
        else { throw ForkError.cutPointNotFound }
        let sequence = CodexSessionFork.turnSequence(of: url)
        guard sequence.contains(cut) else { throw ForkError.cutPointNotFound }
        guard CodexSessionFork.previousTurn(before: cut, in: sequence) != nil else {
            throw ForkError.nothingToBranch
        }
        return cut
    }

    /// Kimi: the edited message's id and the turns an undo of it takes
    /// back — the id is what kimi's turn list names the turn by
    /// (`kimiTurnsPage`), the count what an older kimi's undo takes.
    nonisolated static func kimiUndoTarget(recordUuid: String?, in wire: URL,
                                           originalText: String,
                                           attachedFiles: [String] = [],
                                           skippingNewer: Int) throws -> (messageId: String, count: Int) {
        guard let cut = recordUuid
                ?? KimiSessionFork.resolveCutPoint(matchingUserText: originalText,
                                                   attachedFiles: attachedFiles, in: wire,
                                                   skippingNewest: skippingNewer)
        else { throw ForkError.cutPointNotFound }
        switch kimiUndoCount(forPrompt: cut, in: wire) {
        case .count(let n): return (cut, n)
        case .firstMessage: throw ForkError.nothingToBranch
        case .notFound: throw ForkError.cutPointNotFound
        }
    }

    // MARK: - Which agents can

    /// The versions each was measured on: an older one is not known to
    /// have the call.
    static let codexVersionFloor = "0.162.1"
    static let kimiVersionFloor = "2.2.0"

    enum Support: Equatable {
        case offered
        /// The installed tool has not been read yet.
        case pending
        /// The installed tool is older than the one measured, or does not
        /// name the call.
        case needsNewer
        /// An agent SipAI has no rewind for: Send stays off, and nothing
        /// says a newer version would help.
        case unsupported
    }

    /// Whether the installed tool can take a session back to a message.
    /// Claude's answer is the executable's own
    /// (`ClaudeCapabilities.executable(_:names:)`); codex's and kimi's the
    /// version the call was measured on.
    nonisolated static func support(agentKey: String, claudeNamesFlag: Bool?,
                                    codexVersion: String?, kimiVersion: String?) -> Support {
        switch agentKey {
        case "codex":
            guard let codexVersion else { return .pending }
            return ChatOnlyAvailability.versionAtLeast(codexVersion, codexVersionFloor) ? .offered : .needsNewer
        case "kimi":
            guard let kimiVersion else { return .pending }
            return ChatOnlyAvailability.versionAtLeast(kimiVersion, kimiVersionFloor) ? .offered : .needsNewer
        case "claude_code":
            guard let claudeNamesFlag else { return .pending }
            return claudeNamesFlag ? .offered : .needsNewer
        default:
            return .unsupported
        }
    }
}
