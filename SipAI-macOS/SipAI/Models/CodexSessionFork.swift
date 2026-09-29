// CodexSessionFork.swift
// Branch a Codex session at an earlier user message — THROUGH codex.
//
// Codex forks its own threads: `codex app-server` answers `thread/fork`
// with a new thread whose history is the source's up to a turn, and
// `codex exec resume <new id>` — what `AgentRunner` already runs for
// every send — carries on from there. Nothing is written into the
// store by this app. The fork's rollout is codex's, in codex's format,
// and it holds NO copy of the prefix: its `session_meta` names the
// parent (`forked_from_id`) and the parent's first ordinal that is not
// inherited (`forked_from_ordinal_exclusive`), and codex rebuilds the
// history from the parent's file on every resume. `CodexSessionScanner
// .readHistory` follows the same reference, so a branch renders whole
// here as well — and so does a fork made in a terminal.
//
// The cut is `lastTurnId`: "fork through this turn, inclusive", i.e.
// the id of the turn BEFORE the edited message. Codex also offers
// `beforeTurnId` — the more direct spelling — but refuses it unless the
// client opts into its experimental API on `initialize`, and an
// experimental field is one a codex update can drop. Both were measured
// to retain exactly the same turns.
//
// Two consequences follow from a fork being a REFERENCE rather than a
// copy, and both are codex's own, not this app's: the branch depends on
// its parent staying on disk (delete the parent and the branch keeps
// only its own turns, in codex too), and a fork of a fork resolves up
// the chain.

import Foundation

enum CodexSessionFork {

    /// One error vocabulary for every writer: the sentences are about
    /// the message and the transcript, not about an agent.
    typealias ForkError = AgentSessionFork.ForkError

    struct Result: Equatable {
        let threadId: String
        let rolloutURL: URL
    }

    enum Outcome: Equatable {
        case forked(Result)
        /// Codex answered and declined, in its own words.
        case refused(String)
        /// No codex, no app-server, or no answer inside the ceiling.
        case unavailable
    }

    // MARK: - Pure rules (exercised headless)

    /// Every turn a rollout opened, in order, by the id its
    /// `task_started` carries — the vocabulary
    /// `CodexSessionScanner.turnStarted` reads for the history rows.
    static func turnSequence(lines: [String]) -> [String] {
        var out: [String] = []
        for line in lines {
            guard let data = line.trimmingCharacters(in: .whitespaces)
                    .data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  let id = CodexSessionScanner.turnStarted(obj)
            else { continue }
            if out.last != id { out.append(id) }
        }
        return out
    }

    /// The turn to fork THROUGH so that `turnId` and everything after it
    /// is left behind: the one before it. Nil when `turnId` opens the
    /// sequence — there is nothing above it to branch from, which is
    /// the caller's `nothingToBranch`.
    static func previousTurn(before turnId: String, in sequence: [String]) -> String? {
        guard let at = sequence.firstIndex(of: turnId), at > 0 else { return nil }
        return sequence[at - 1]
    }

    /// The request line: `thread/fork` with the cut, under the id the
    /// shared client waits on. `excludeTurns` because the answer's
    /// hydrated history is not read — the rollout is. No `cwd`, `model`
    /// or sandbox override: the branch inherits its parent's, and every
    /// later send passes the composer's chips on the command line as it
    /// does for any session.
    static func request(threadId: String, lastTurnId: String) -> String? {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": CodexAppServerCall.answerId,
            "method": "thread/fork",
            "params": [
                "threadId": threadId,
                "lastTurnId": lastTurnId,
                "excludeTurns": true,
            ] as [String: Any],
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The answer, read the way the protocol spells it: `result.thread`
    /// carrying `id` and `path` (the new rollout, absolute), or an
    /// `error` whose `message` is codex's own sentence.
    static func outcome(from answer: [String: Any]?) -> Outcome {
        guard let answer else { return .unavailable }
        if let result = answer["result"] as? [String: Any],
           let thread = result["thread"] as? [String: Any],
           let id = thread["id"] as? String, !id.isEmpty {
            let path = (thread["path"] as? String) ?? ""
            let url = path.isEmpty
                ? CodexSessionScanner.rolloutFile(namedForId: id)
                : URL(fileURLWithPath: path)
            guard let url else {
                return .refused("codex named no rollout for the new thread")
            }
            return .forked(Result(threadId: id, rolloutURL: url))
        }
        if let error = answer["error"] as? [String: Any] {
            let message = (error["message"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 } ?? "thread/fork failed"
            return .refused(message)
        }
        return .unavailable
    }

    // MARK: - Cut-point resolution

    /// The turn id of the newest user record whose cleaned text matches
    /// `text` — for LIVE rows, which never went through the rollout
    /// reader and carry no handle. The same identification
    /// `AgentSessionView.trimmedForInFlight` makes between a live event
    /// and its record; newest-first, so a repeated prompt branches at
    /// the one on screen. Reads files; call it off the main thread.
    static func resolveCutPoint(matchingUserText text: String,
                                in rollout: URL,
                                root: URL = CodexSessionScanner.sessionRoot,
                                skippingNewest skip: Int = 0) -> String? {
        // The reader's own cleaner on both sides, so a row and its
        // record spell the text one way.
        let wanted = CodexSessionScanner.strippedTaskMarker(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: rollout.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        var ownMatches = 0
        for budget in [256 * 1024, 4 * 1024 * 1024, 64 * 1024 * 1024] {
            guard let window = AgentSessionScanner.boundedTail(of: rollout,
                                                               budget: budget)
            else { return nil }
            let scan = cutPointScan(text: wanted,
                                    lines: window.split(separator: "\n").map(String.init),
                                    skippingNewest: skip)
            ownMatches = scan.matches
            // A match with no handle: the window opened inside its turn,
            // below the `task_started` — widen rather than fall back to
            // an older occurrence.
            if scan.found, let handle = scan.handle { return handle }
            if let size, size <= UInt64(budget) { break }
        }
        // Nothing (or not enough) in the branch's own file: on a fork
        // the row can be an inherited one — its record lives in the
        // parent — so the same walk runs over the inherited prefix,
        // newest last, skipping what the own file already accounted for.
        if let origin = CodexSessionScanner.forkOrigin(of: rollout) {
            let scan = cutPointScan(
                text: wanted,
                lines: CodexSessionScanner.inheritedLines(
                    for: origin, budget: 64 * 1024 * 1024, root: root),
                skippingNewest: max(0, skip - ownMatches))
            return scan.found ? scan.handle : nil
        }
        return nil
    }

    /// Forward through the real decoder, collecting every match: a
    /// user row's handle is the turn that opened it, which sits above
    /// the record and is only known walking forward. The answer is the
    /// newest match less the ones to skip; `handle` nil on a found
    /// match means that record's turn opened above the window.
    private static func cutPointScan(text: String, lines: [String],
                                     skippingNewest skip: Int)
    -> (found: Bool, handle: String?, matches: Int) {
        var decoder = CodexSessionScanner.RolloutDecoder()
        var matches: [String?] = []
        for line in lines {
            for item in decoder.items(forLine: line) {
                if case .userText(let body) = item.kind, body == text {
                    matches.append(item.recordUuid)
                }
            }
        }
        guard matches.count > skip else { return (false, nil, matches.count) }
        return (true, matches[matches.count - 1 - skip], matches.count)
    }

    // MARK: - Fork

    /// Every turn the rollout — and, for a fork, its inherited prefix —
    /// opened, oldest first. The cut a user row names is a turn in
    /// here, and the turn before it is what codex is asked to fork
    /// through; codex resolves an inherited turn id itself (measured:
    /// a fork of a fork through the turn it inherited succeeds).
    ///
    /// Streamed whole and unbounded on purpose: a window that missed a
    /// cut's predecessor would answer "first turn", and that answer
    /// starts a NEW session instead of a branch.
    static func turnSequence(of rollout: URL,
                             root: URL = CodexSessionScanner.sessionRoot) -> [String] {
        var ids: [String] = []
        if let origin = CodexSessionScanner.forkOrigin(of: rollout) {
            ids = CodexSessionScanner.inheritedTurnIds(for: origin, root: root)
        }
        for id in CodexSessionScanner.turnIds(of: rollout) where ids.last != id {
            ids.append(id)
        }
        return ids
    }

    /// Fork through codex. Returns the new thread and its rollout.
    ///
    /// `cutAtTurnId` is the turn the edited message opened. Throws
    /// `nothingToBranch` when it is the first turn (the caller starts a
    /// fresh session instead) and `writeFailed` with codex's own words
    /// when codex declines.
    static func fork(rollout: URL, threadId: String, cutAtTurnId: String,
                     binary: String,
                     root: URL = CodexSessionScanner.sessionRoot) async throws -> Result {
        let sequence = await Task.detached(priority: .userInitiated) {
            turnSequence(of: rollout, root: root)
        }.value
        guard sequence.contains(cutAtTurnId) else {
            throw ForkError.cutPointNotFound
        }
        guard let last = previousTurn(before: cutAtTurnId, in: sequence) else {
            throw ForkError.nothingToBranch
        }
        guard let line = request(threadId: threadId, lastTurnId: last) else {
            throw ForkError.writeFailed("could not build the request")
        }
        switch outcome(from: await CodexAppServerCall.run(binary: binary,
                                                         request: line)) {
        case .forked(let result):
            return result
        case .refused(let message):
            throw ForkError.writeFailed(message)
        case .unavailable:
            throw ForkError.agentUnavailable
        }
    }
}
