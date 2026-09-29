// KimiSessionFork.swift
// Branch a Kimi Code session at an earlier user message.
//
// Kimi's own `kimi fork` copies a session whole — from the end, with no
// cut point — and a copy is exactly what a branch is in this store: a
// new session directory holding a PREFIX of the source's wire. So the
// branch is written in the shape kimi's fork writes, cut where the user
// asked:
//
//   sessions/<same bucket>/session_<new uuid>/
//   ├── agents/main/wire.jsonl   every source record ABOVE the edited
//   │                            turn, then {"type":"forked",…} — the
//   │                            one record kimi's fork appends
//   ├── state.json               the source's, with id / title /
//   │                            titleKind / forkedFrom / homedir /
//   │                            createdAt changed and nothing else
//   └── notify/state.json        {"enabled":false}
//   + one line in $KIMI_CODE_HOME/session_index.jsonl
//
// then `kimi --session <new id> --prompt "<edited text>"`, which is what
// `AgentRunner` already does for any kimi session with an id.
//
// No wire record carries the session id — only `agentId` — so the
// prefix is copied untouched; only `state.json` names the session.
// `kimi fork` itself is deliberately NOT run and then cut: it has no
// cut option, and truncating a file kimi just wrote is the one thing
// never done to an agent's store.
//
// The source is never modified. The branch is staged as a dot-prefixed
// directory in the same bucket — every scanner skips hidden entries
// and dot-prefixed ids — and renamed into place, so a half-written
// branch can never be listed, opened, or resumed.

import Foundation

enum KimiSessionFork {

    /// One error vocabulary for every writer: the sentences are about
    /// the message and the transcript, not about an agent.
    typealias ForkError = AgentSessionFork.ForkError

    struct Result {
        let sessionId: String
        let wireURL: URL
    }

    // MARK: - Pure rules (exercised headless)

    /// Index of the first record of the turn `promptId` opened: its
    /// `turn.prompt`, or — for a writer that omits one — the user
    /// `context.append_message` carrying that id. The branch ends
    /// ABOVE it.
    static func cutIndex(lines: [String], promptId: String) -> Int? {
        for (i, line) in lines.enumerated() {
            guard let obj = object(line) else { continue }
            if KimiSessionScanner.turnPromptId(obj) == promptId { return i }
            if let user = KimiSessionScanner.userMessage(obj),
               user.id == promptId { return i }
        }
        return nil
    }

    /// True when a prefix holds an actual conversation — at least one
    /// user message and one record of the agent speaking or acting. A
    /// prefix of bookkeeping alone (`metadata`, `profile.bind`, the
    /// injected reminders) would resume with no context: that is a new
    /// session, not a branch, and the caller starts one.
    static func prefixHoldsConversation(_ lines: [String]) -> Bool {
        var sawUser = false
        var sawAgent = false
        for line in lines {
            guard let obj = object(line) else { continue }
            if let user = KimiSessionScanner.userMessage(obj),
               !user.text.isEmpty {
                sawUser = true
            } else if KimiSessionScanner.isAgentOutput(obj) {
                sawAgent = true
            }
            if sawUser && sawAgent { return true }
        }
        return false
    }

    /// The record kimi's own fork appends after the copied wire.
    static func forkedRecord(now: Date) -> String {
        #"{"type":"forked","agentId":"main","time":\#(epochMilliseconds(now))}"#
    }

    /// The branch's `state.json`: the source's object with exactly the
    /// keys kimi's own fork changes.
    ///
    /// `title` is the branch's derived name with `titleKind:
    /// "replaceable"` — the shape kimi's fork gives its own "Fork: <id>"
    /// — so kimi is free to write a generated title over it later, and
    /// `isCustomTitle` stays false because this is the branch's birth
    /// record, not a rename. Without a title of its own the branch would
    /// derive one from the copied first message and sit in every picker
    /// under its parent's name. Every other key is carried through:
    /// kimi rewrites this file itself and `cwd` is in it — a session
    /// with no recorded cwd resumes in the home folder.
    static func rewrittenState(source: [String: Any], sourceId: String,
                               sourceDir: URL, newId: String, newDir: URL,
                               title: String, now: Date) -> [String: Any] {
        var state = source
        state["id"] = newId
        state["title"] = title
        state["titleKind"] = "replaceable"
        state["forkedFrom"] = sourceId
        state["isCustomTitle"] = false
        state["createdAt"] = epochMilliseconds(now)
        if state["version"] == nil { state["version"] = 2 }
        if state["archived"] == nil { state["archived"] = false }
        if state["custom"] == nil { state["custom"] = [String: Any]() }
        // Only `main` travels: the branch copies the main wire alone, so
        // a subagent entry (`agent-N`, its own wire beside `main`) would
        // point at a directory the branch does not have. The main home
        // moves with the directory — a homedir that does not start
        // with the source directory (a store moved after the session
        // was written) is re-pointed by its leaf instead.
        let sourceAgents = (state["agents"] as? [String: Any]) ?? [:]
        var main = (sourceAgents["main"] as? [String: Any]) ?? [:]
        let sourcePath = sourceDir.standardizedFileURL.path
        let home = (main["homedir"] as? String) ?? ""
        if !home.isEmpty, home.hasPrefix(sourcePath) {
            main["homedir"] = newDir.path + home.dropFirst(sourcePath.count)
        } else {
            main["homedir"] = newDir.appendingPathComponent("agents/main").path
        }
        if main["type"] == nil { main["type"] = "main" }
        state["agents"] = ["main": main]
        return state
    }

    /// One line of `session_index.jsonl`, in kimi's spelling and key
    /// order.
    static func indexLine(sessionId: String, dir: URL, cwd: URL?) -> String? {
        func quoted(_ s: String) -> String? {
            guard let data = try? JSONSerialization.data(
                withJSONObject: [s], options: [.withoutEscapingSlashes]),
                  let text = String(data: data, encoding: .utf8),
                  text.hasPrefix("["), text.hasSuffix("]")
            else { return nil }
            return String(text.dropFirst().dropLast())
        }
        guard let id = quoted(sessionId), let path = quoted(dir.path)
        else { return nil }
        var line = #"{"sessionId":\#(id),"sessionDir":\#(path)"#
        if let cwd, let work = quoted(cwd.path) {
            line += #","workDir":\#(work)"#
        }
        return line + "}"
    }

    /// The copied first user record with any `<scheduled-task>` marker
    /// removed. A branch of a scheduled run is not another run of that
    /// task — the user started it by hand — and the marker is what the
    /// scanner files a session under. The message shape is the one the
    /// claude fork already strips (`content` as text blocks), so the
    /// rule is shared rather than respelled; a record the rewrite
    /// cannot re-serialise is kept as it was.
    static func strippingScheduledTaskMarker(fromUserLine line: String) -> String {
        guard line.contains("<scheduled-task"),
              var obj = object(line),
              (obj["type"] as? String) == "context.append_message",
              let message = obj["message"]
        else { return line }
        obj["message"] = AgentSessionFork.strippingScheduledTaskMarker(message)
        // A number JSON cannot write back raises, uncatchably.
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.withoutEscapingSlashes]),
              let out = String(data: data, encoding: .utf8)
        else { return line }
        return out
    }

    // MARK: - Cut-point resolution

    /// The prompt id of the newest user record whose cleaned text
    /// matches `text` — for LIVE rows, which never went through the
    /// wire reader and carry no handle. The same identification
    /// `AgentSessionView.trimmedForInFlight` makes between a live event
    /// and its record; newest-first, so a repeated prompt branches at
    /// the one on screen. Reads files; call it off the main thread.
    static func resolveCutPoint(matchingUserText text: String,
                                in wire: URL,
                                skippingNewest skip: Int = 0) -> String? {
        // The reader's own cleaner on both sides (`userMessage` answers
        // `cleanUserText`), so a message spelling a bare `<…>` matches.
        let wanted = AgentSessionScanner.cleanUserText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: wire.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        for budget in [256 * 1024, 4 * 1024 * 1024, 64 * 1024 * 1024] {
            if let found = cutPointScan(text: wanted, in: wire, budget: budget,
                                        skippingNewest: skip) {
                return found
            }
            if let size, size <= UInt64(budget) { break }
        }
        return nil
    }

    private static func cutPointScan(text: String, in wire: URL,
                                     budget: Int,
                                     skippingNewest skip: Int) -> String? {
        guard let window = AgentSessionScanner.boundedTail(of: wire,
                                                           budget: budget)
        else { return nil }
        // Forward, collecting every match: a user record without an id
        // of its own is identified by the `turn.prompt` before it, which
        // a reverse walk would only meet after the record. The answer is
        // the newest, less the ones the caller says to skip.
        var currentPrompt: String? = nil
        var matches: [String] = []
        for line in window.split(separator: "\n") {
            guard let obj = object(String(line)) else { continue }
            if let prompt = KimiSessionScanner.turnPromptId(obj) {
                currentPrompt = prompt
                continue
            }
            guard let user = KimiSessionScanner.userMessage(obj),
                  user.text == text,
                  let handle = user.id ?? currentPrompt
            else { continue }
            matches.append(handle)
        }
        guard matches.count > skip else { return nil }
        return matches[matches.count - 1 - skip]
    }

    // MARK: - Fork

    /// Read chunk for the streaming copy — the same discipline as the
    /// claude fork; a wire file is smaller as a rule, but the rule is
    /// the reader's, not the file's.
    private static let copyChunk = 1 << 20   // 1 MiB

    /// Write the branch. Returns the new session id and its wire file.
    ///
    /// Reads and writes files, and parses every line of the prefix.
    /// Call it off the main thread.
    static func fork(sourceWire: URL, cutAtPromptId: String,
                     title: String, cwd: URL?) throws -> Result {
        guard let sourceDir = KimiSessionScanner.sessionDirectory(of: sourceWire)
        else { throw ForkError.unreadableSource }
        let sourceId = sourceDir.lastPathComponent
        let bucket = sourceDir.deletingLastPathComponent()
        let newId = "session_" + UUID().uuidString.lowercased()
        let destination = bucket.appendingPathComponent(newId, isDirectory: true)
        let staging = bucket.appendingPathComponent(".sipai-branch-\(newId)",
                                                    isDirectory: true)

        // --- the prefix ---
        guard let reader = try? FileHandle(forReadingFrom: sourceWire) else {
            throw ForkError.unreadableSource
        }
        defer { try? reader.close() }
        var kept: [String] = []
        var leftover = Data()
        var reachedCut = false

        func consume(_ lineData: Data) -> Bool {
            // Lossy decode on purpose: a read can land inside a
            // multibyte character of a file another kimi is writing,
            // and a strict decode would fail the WHOLE branch over one
            // edge line. Same rule as `readHistory`.
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return true }
            if let obj = object(line) {
                if KimiSessionScanner.turnPromptId(obj) == cutAtPromptId {
                    return false
                }
                if let user = KimiSessionScanner.userMessage(obj),
                   user.id == cutAtPromptId {
                    return false
                }
                kept.append(line)
            }
            // An unparseable line is torn (a live writer at EOF) or
            // garbage: it cannot be the cut point, and copying it would
            // plant a broken record in a file kimi has to parse. Drop it.
            return true
        }

        outer: while true {
            let chunk = (try? reader.read(upToCount: copyChunk)) ?? Data()
            if chunk.isEmpty { break }
            leftover.append(chunk)
            while let nl = leftover.firstIndex(of: 0x0A) {
                let lineData = leftover.subdata(in: leftover.startIndex..<nl)
                leftover.removeSubrange(leftover.startIndex...nl)
                if !consume(lineData) { reachedCut = true; break outer }
            }
        }
        if !reachedCut, !leftover.isEmpty {
            if !consume(leftover) { reachedCut = true }
        }
        guard reachedCut else { throw ForkError.cutPointNotFound }
        guard prefixHoldsConversation(kept) else {
            throw ForkError.nothingToBranch
        }
        // The marker matters on the FIRST user record alone — that is
        // the one the scanner files a session under — so only that
        // record is touched; a later message that merely quotes the tag
        // is the user's own text and stays.
        if let first = kept.firstIndex(where: {
            object($0).flatMap(KimiSessionScanner.userMessage) != nil
        }), kept[first].contains("<scheduled-task") {
            kept[first] = strippingScheduledTaskMarker(fromUserLine: kept[first])
        }

        // --- the files ---
        let fm = FileManager.default
        let now = Date()
        var sourceState: [String: Any] = [:]
        if let data = try? Data(contentsOf: sourceDir.appendingPathComponent("state.json")),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            sourceState = obj
        }
        if sourceState["cwd"] == nil, let cwd {
            sourceState["cwd"] = cwd.path
        }
        let state = rewrittenState(source: sourceState, sourceId: sourceId,
                                   sourceDir: sourceDir, newId: newId,
                                   newDir: destination, title: title, now: now)
        // Parsed file content can hold a number JSON cannot write back
        // (`1e400` reads as infinity), and serialising one raises an
        // exception no `catch` sees — the app would abort on a branch.
        guard JSONSerialization.isValidJSONObject(state) else {
            throw ForkError.unreadableSource
        }
        do {
            try? fm.removeItem(at: staging)
            try fm.createDirectory(
                at: staging.appendingPathComponent("agents/main", isDirectory: true),
                withIntermediateDirectories: true)
            try fm.createDirectory(
                at: staging.appendingPathComponent("notify", isDirectory: true),
                withIntermediateDirectories: true)
            let wire = Data((kept.joined(separator: "\n") + "\n"
                             + forkedRecord(now: now) + "\n").utf8)
            try wire.write(to: KimiSessionScanner.wireFile(inSessionDir: staging),
                           options: .atomic)
            let stateData = try JSONSerialization.data(
                withJSONObject: state,
                options: [.sortedKeys, .withoutEscapingSlashes])
            try stateData.write(to: staging.appendingPathComponent("state.json"),
                                options: .atomic)
            try Data(#"{"enabled":false}"#.utf8).write(
                to: staging.appendingPathComponent("notify/state.json"),
                options: .atomic)
            // Never overwrite: `newId` is a fresh UUID, so a collision
            // means something is very wrong and silently clobbering a
            // session is the worst possible answer.
            guard !fm.fileExists(atPath: destination.path) else {
                try? fm.removeItem(at: staging)
                throw ForkError.writeFailed("session id collision")
            }
            try fm.moveItem(at: staging, to: destination)
        } catch let error as ForkError {
            throw error
        } catch {
            try? fm.removeItem(at: staging)
            throw ForkError.writeFailed(error.localizedDescription)
        }

        // --- the index, LAST ---
        // A listed directory that is not there yet is the failure that
        // costs the most, so the line goes after the move. Best effort:
        // kimi lists and resolves a directory the index does not name
        // (measured), so a branch that missed its line is still a
        // session, and refusing it here would tear down a branch that
        // works. One O_APPEND write of one whole line, the same rule as
        // the claude rename record.
        let workDir = (state["cwd"] as? String).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? cwd
        if let line = indexLine(sessionId: newId, dir: destination, cwd: workDir) {
            do {
                try appendLine(Data(line.utf8), to: KimiSessionScanner.sessionIndex)
            } catch {
                NSLog("%@", "SipAI: kimi branch \(newId) written but not added to "
                      + "\(KimiSessionScanner.sessionIndex.path): "
                      + "\(error.localizedDescription)")
            }
        }
        return Result(sessionId: newId,
                      wireURL: KimiSessionScanner.wireFile(inSessionDir: destination))
    }

    // MARK: - Shared

    private static func object(_ line: String) -> [String: Any]? {
        guard let data = line.trimmingCharacters(in: .whitespaces)
                .data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func epochMilliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// One `O_APPEND` write of one whole line — the kernel places it at
    /// the end atomically, so a kimi appending to the same index cannot
    /// interleave with it. The file is created if kimi has not written
    /// one yet. A file that does not end in a newline was cut off
    /// mid-record: the line goes after a blank line rather than fusing
    /// onto the fragment and costing both.
    private static func appendLine(_ payload: Data, to url: URL) throws {
        var bytes = Data()
        if !endsWithNewline(url) { bytes.append(0x0A) }
        bytes.append(payload)
        bytes.append(0x0A)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw ForkError.writeFailed(String(cString: strerror(errno)))
        }
        defer { close(fd) }
        var written = 0
        try bytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            while written < buf.count {
                let n = write(fd, base.advanced(by: written), buf.count - written)
                if n > 0 { written += n; continue }
                if n < 0 && errno == EINTR { continue }
                throw ForkError.writeFailed(String(cString: strerror(errno)))
            }
        }
    }

    private static func endsWithNewline(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return true }
        try? handle.seek(toOffset: size - 1)
        guard let last = try? handle.read(upToCount: 1), let byte = last.first
        else { return true }
        return byte == 0x0A
    }
}
