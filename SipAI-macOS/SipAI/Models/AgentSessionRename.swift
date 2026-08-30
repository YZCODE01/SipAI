// AgentSessionRename.swift
// Writing a session's user-set name back into the agent's OWN store, so
// a rename made here also shows in the CLI's session picker.
//
// SipAI has always kept the name in `agent_session_names` in its own
// config.json — shared with the CLI, and the only record for an agent
// that cannot be written to. That entry still decides what the sidebar
// draws. What this file adds is the second write, into the agent's
// store, for the agents that HAVE a custom-title mechanism.
//
// Two rules hold the whole file together:
//
//   * The verdict is keyed on the AGENT, never on a probe at call time
//     and never on a version string — the same rule
//     `AgentSlashCommands.resolvesLocally` follows. An agent nobody has
//     measured answers "no", because the alternative is writing a guess
//     into a store three other clients read.
//   * A rename is the user's word, so the write is a MERGE, never a
//     rebuild. Claude's transcript gets one appended record and nothing
//     else; kimi's `state.json` is read, two keys are changed, and every
//     other key is carried through untouched.
//
// This is the second place in the app that writes into an agent's
// private store (`AgentSessionFork` is the first). Both are held to the
// same standard: speak the agent's own format, touch the smallest thing
// that works, and never rewrite a file we did not author.

import Foundation

enum AgentSessionRename {

    // MARK: - Capability

    /// Whether a rename made in SipAI also reaches the agent's own
    /// session list, or stays SipAI's alone.
    ///
    /// Codex answers NO deliberately, and not for want of an API. Its
    /// thread title lives in codex's own database and its thread upsert
    /// rewrites that column from the rollout's first user message on
    /// every `codex exec` — the command every send goes through, and the
    /// rewrite lands during process startup, before any model call. A
    /// name written there is gone by the next turn, including one
    /// codex's own `/rename` wrote. Writing it anyway would put a value
    /// in another app's database that neither app will still agree with
    /// a minute later.
    static func writesThrough(_ agentKey: String) -> Bool {
        switch agentKey {
        case "claude_code", "kimi": return true
        case "codex": return false
        default: return false
        }
    }

    // MARK: - Failures

    enum Failure: Error {
        /// Nothing on disk to write into yet — a session whose
        /// transcript has not landed, or a kimi session whose directory
        /// cannot be resolved from the wire file. SipAI's own name is
        /// then the only name there is, which is a complete outcome and
        /// not worth interrupting the user for.
        case storeMissing
        /// The store is there and the write did not happen. This one is
        /// reported: the user has been told the session is renamed, and
        /// the agent disagrees.
        case write(String)

        var message: String {
            switch self {
            case .storeMissing: return ""
            case .write(let reason): return reason
            }
        }
    }

    // MARK: - Entry point

    /// Write (or clear) the agent-side name for one session.
    ///
    /// Pass nil or an empty string to clear, which puts the agent back
    /// on its own generated title rather than freezing the current one.
    ///
    /// Does file I/O and is deliberately `nonisolated` — every caller is
    /// a MainActor view, and a rename must not stall the sidebar on a
    /// slow disk.
    nonisolated static func apply(_ name: String?,
                                  sessionId: String,
                                  fileURL: URL,
                                  agentKey: String) throws {
        let title = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch agentKey {
        case "claude_code":
            try applyClaude(title, sessionId: sessionId, fileURL: fileURL)
        case "kimi":
            try applyKimi(title, fileURL: fileURL)
        default:
            throw Failure.storeMissing
        }
    }

    // MARK: - Claude Code

    /// Claude records a renamed session as an appended transcript record
    /// AND a sidecar file, and it needs both for the same reason we do:
    /// the record is authoritative but scrolls out of the window claude
    /// reads when listing sessions, and the sidecar is what still
    /// answers after that.
    ///
    /// Order matters on the CLEAR path only: the record goes first, so a
    /// crash between the two steps leaves the session cleared with a
    /// stale sidecar — which reads correctly, because the sidecar is
    /// consulted only when the window carries no title record at all.
    /// The other order would resurrect the old name.
    private static func applyClaude(_ title: String,
                                    sessionId: String,
                                    fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw Failure.storeMissing
        }
        try appendCustomTitleRecord(title, sessionId: sessionId, to: fileURL)
        let sidecar = claudeSidecarURL(sessionId: sessionId, transcript: fileURL)
        if title.isEmpty {
            try? FileManager.default.removeItem(at: sidecar)
        } else {
            try writeClaudeSidecar(title, to: sidecar)
        }
    }

    /// `<projectDir>/<sessionId>/custom-title.json`, beside the
    /// transcript rather than inside it. Claude already keeps per-session
    /// working files in that directory.
    private static func claudeSidecarURL(sessionId: String,
                                         transcript: URL) -> URL {
        transcript
            .deletingLastPathComponent()
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("custom-title.json")
    }

    /// The record claude's own rename writes:
    ///
    ///     {"type":"custom-title","customTitle":"…","sessionId":"…", …}
    ///
    /// It outranks the generated `ai-title`, and the NEWEST such record
    /// in the file wins — so clearing is an appended record carrying an
    /// EMPTY title, not a rewrite of the file to remove the old one. We
    /// do not rewrite transcripts.
    ///
    /// **The JSON must be COMPACT.** Claude finds this record by testing
    /// each line for the literal substring `"type":"custom-title"`
    /// before parsing anything. A pretty-printed record — one space
    /// after the colon — matches nothing and is silently ignored, and
    /// the rename appears to have done nothing at all.
    private static func appendCustomTitleRecord(_ title: String,
                                                sessionId: String,
                                                to url: URL) throws {
        let record: [String: Any] = [
            "type": "custom-title",
            "customTitle": title,
            "sessionId": sessionId,
            "uuid": UUID().uuidString.lowercased(),
            "timestamp": iso8601UTC.string(from: Date()),
        ]
        let data: Data
        do {
            // .sortedKeys for a deterministic line; NO .prettyPrinted,
            // see above. Slashes stay unescaped so a title carrying a
            // path reads the way claude's own writer would spell it.
            data = try JSONSerialization.data(
                withJSONObject: record,
                options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw Failure.write(error.localizedDescription)
        }
        try appendLine(data, to: url)
    }

    /// One `O_APPEND` write of one whole line.
    ///
    /// `O_APPEND` is what makes this safe next to a live claude: the
    /// kernel places the write at the end atomically, so a turn being
    /// streamed into the same file cannot interleave with it. Seeking to
    /// the end and then writing — what `FileHandle` does — has a gap
    /// between the two in which claude can append, and the record lands
    /// on top of a turn.
    private static func appendLine(_ payload: Data, to url: URL) throws {
        var bytes = Data()
        // A transcript ends in a newline. If a writer was cut off
        // mid-line it does not, and appending straight onto that
        // fragment would fuse our record to a half-written one and cost
        // both. A blank line is the harmless alternative — every reader
        // of this format skips empty lines.
        if !endsWithNewline(url) { bytes.append(0x0A) }
        bytes.append(payload)
        bytes.append(0x0A)

        let fd = open(url.path, O_WRONLY | O_APPEND)
        guard fd >= 0 else {
            throw Failure.write(String(cString: strerror(errno)))
        }
        defer { close(fd) }
        var written = 0
        try bytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            while written < buf.count {
                let n = write(fd, base.advanced(by: written), buf.count - written)
                if n > 0 { written += n; continue }
                if n < 0 && errno == EINTR { continue }
                throw Failure.write(String(cString: strerror(errno)))
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

    /// `{"customTitle":"…"}`, written atomically so a claude reading it
    /// mid-write sees the old file or the new one and never half of
    /// either. Permissions match what claude gives its own: the
    /// directory owner-only, the file owner-read/write.
    private static func writeClaudeSidecar(_ title: String, to url: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(
                withJSONObject: ["customTitle": title],
                options: [.withoutEscapingSlashes])
            try data.write(to: url, options: [.atomic])
            try? fm.setAttributes([.posixPermissions: 0o600],
                                  ofItemAtPath: url.path)
        } catch {
            throw Failure.write(error.localizedDescription)
        }
    }

    // MARK: - Kimi Code

    /// Kimi keeps the name in the session's own `state.json`, as
    /// `title` plus an `isCustomTitle` flag, and reads the two together
    /// — a title without the flag is a different thing to kimi, so both
    /// move or neither does.
    ///
    /// Read, change two keys, write the whole object back. Kimi rewrites
    /// this file itself on every session update, so anything dropped
    /// here is dropped for good: `cwd` is in there, and a kimi session
    /// with no recorded cwd resumes in the home folder.
    private static func applyKimi(_ title: String, fileURL: URL) throws {
        guard let dir = KimiSessionScanner.sessionDirectory(of: fileURL) else {
            throw Failure.storeMissing
        }
        let state = dir.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: state) else {
            throw Failure.storeMissing
        }
        guard var object = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] else {
            throw Failure.write("state.json is not a JSON object")
        }
        if title.isEmpty {
            // Dropping the key rather than storing "" — kimi reads a
            // present `title` of any value as the session's name.
            object.removeValue(forKey: "title")
            object["isCustomTitle"] = false
        } else {
            object["title"] = title
            object["isCustomTitle"] = true
        }
        do {
            var out = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            out.append(0x0A)
            try out.write(to: state, options: [.atomic])
        } catch {
            throw Failure.write(error.localizedDescription)
        }
    }

    // MARK: - Shared

    private static let iso8601UTC: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
