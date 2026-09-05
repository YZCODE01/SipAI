// CodexSessions.swift
// Scanner + history reader for OpenAI Codex sessions.
//
// Codex stores one rollout file per recording under
// ~/.codex/sessions/YYYY/MM/DD/rollout-<stamp>-<uuid>.jsonl. Line 1 is
// a session_meta record whose payload carries the session id and cwd;
// ~/.codex/session_index.jsonl maps id → thread_name — the display
// name Codex Desktop shows, so reading it gives SipAI the same names.
//
// History items reuse `AgentSessionHistoryItem`, so codex transcripts
// render through the exact same rows as Claude Code history.

import Foundation

enum CodexSessionScanner {

    /// Root folder Codex (CLI and Desktop alike) writes rollouts into.
    static let sessionRoot: URL = {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }()

    private static let sessionIndex: URL = {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
    }()

    /// User records that are context plumbing, not conversation.
    ///
    /// `<scheduled-task` must never go into this list: the marker is a
    /// PAIRED EMPTY tag with the prompt OUTSIDE it, so a prefix match
    /// on the whole record would classify the entire first message of
    /// every scheduled run as injected context — the prompt gone from
    /// the transcript, from the derived title, and from the
    /// last-user-message timestamp the sidebar sorts on. It is
    /// stripped instead (`strippedTaskMarker`), which is what claude's
    /// `cleanUserText` does with the same tag.
    private static let contextPrefixes = [
        "<environment_context>", "<user_instructions>", "<turn_context>",
        "<permissions", "<recommended_plugins>",
        "<app_context>", "<collaboration_mode>",
    ]

    /// The scheduled-task marker removed, leaving the prompt. A record
    /// holding ONLY the marker reduces to "" and is then classified as
    /// context by `isContextText`, which is correct — there is no
    /// message in it.
    static func strippedTaskMarker(_ text: String) -> String {
        guard text.contains("<scheduled-task") else { return text }
        let pattern = "<scheduled-task[^>]*>[\\s\\S]*?</scheduled-task>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex
            .stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Not everything codex injects is tag-wrapped: the project's
    /// AGENTS.md and a dump of user attachments arrive as plain markdown
    /// in a `role: "user"` record ahead of the real message. Treating
    /// those as conversation would title sessions
    /// "# AGENTS.md instructions for …" and hide the automation header
    /// behind them.
    private static let contextHeadingRegex = try! NSRegularExpression(
        pattern: #"\A# (?:AGENTS\.md instructions for |[\w ]+ mentioned by the user:)"#
    )

    /// True when a codex user record is injected context, not a message.
    /// Judged on the record with any scheduled-task marker removed, so
    /// a fired run is classified by what its author actually wrote.
    private static func isContextText(_ text: String) -> Bool {
        let body = strippedTaskMarker(text)
        if body.isEmpty { return true }
        if contextPrefixes.contains(where: body.hasPrefix) { return true }
        let range = NSRange(location: 0, length: (body as NSString).length)
        return contextHeadingRegex.firstMatch(in: body, range: range) != nil
    }

    /// The cron-automation header a scheduled run opens with:
    /// `Automation: <name>\nAutomation ID: <id>` before the user prompt.
    /// The one on-disk marker separating an automation run from a thread
    /// the user typed into. The id token must be non-empty.
    private static let automationRegex = try! NSRegularExpression(
        pattern: #"\AAutomation:[ \t]*([^\r\n]*?)[ \t]*\r?\nAutomation ID:[ \t]*\S+"#
    )

    /// True when the store exists — the read-only tier's availability
    /// signal, independent of whether the `codex` binary is installed.
    static var storeExists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: sessionRoot.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Scan

    /// Enumerate every rollout file. A session id can own several
    /// rollouts (a resume records a new one); the newest represents the
    /// session. Returns sessions sorted newest-first, tagged
    /// `agentKey == "codex"`.
    static func scan(limit: Int? = nil) -> [AgentSession] {
        let fm = FileManager.default
        guard storeExists,
              let walker = fm.enumerator(
                at: sessionRoot,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else {
            return []
        }
        let names = indexNames()
        var newestById: [String: AgentSession] = [:]
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else {
                continue
            }
            guard let meta = readMeta(of: url) else { continue }
            // Same scratch rule as the claude scanner: a rollout rooted
            // in a temp directory is a probe, not work to come back to
            // — but a SCHEDULED run is kept wherever it happened to
            // run. Automation the user set up is theirs to see, and a
            // wrapper is free to pick a temp cwd; hiding those loses
            // real output. The verdict needs the marker in hand, which
            // is why it sits after the meta read: a bail on the cwd
            // alone cannot know whether it is dropping a probe or a
            // task's only run — and `ScheduledAgentTaskScanner` groups
            // over this same list, so a dropped run would vanish from
            // its task as well as from the sidebar.
            if meta.scheduledTaskName == nil,
               AgentSessionScanner.isScratchLocation(meta.cwd) { continue }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            // Same name-sync ladder as claude: codex's own name (what
            // Codex Desktop shows) first, then whatever the run's origin
            // names it (automation name / subagent nickname), then a
            // title derived from the opening user message, then the
            // neutral folder fallback.
            let title = names[meta.id]
                ?? meta.originTitle
                ?? meta.derivedTitle
                ?? neutralTitle(for: meta.cwd)
            let session = AgentSession(
                id: meta.id,
                fileURL: url,
                title: title,
                modifiedAt: mtime,
                // Memoised against (size, mtime) in the shared cache —
                // a rollout that has not been written since the last
                // scan costs a lookup, not a tail read.
                lastUserMessageAt: AgentSessionScanner.cachedLastUserMessageDate(
                    of: url, size: size, mtime: mtime,
                    read: { lastUserMessageDate(of: $0) }),
                projectPath: meta.cwd,
                // `ScheduledAgentTaskScanner` groups on exactly this
                // value — leaving it nil would file every codex run of
                // a task as a loose session while the task itself
                // reports no runs.
                scheduledTaskName: meta.scheduledTaskName,
                agentKey: "codex",
                origin: meta.origin
            )
            if let known = newestById[meta.id] {
                // Which rollout REPRESENTS the session is still an
                // mtime question — it asks which file was written
                // last, not when its owner last spoke. A resume whose
                // first prompt has not landed yet has no user record
                // at all, and picking by `activityAt` there would keep
                // showing the abandoned older rollout.
                if session.modifiedAt > known.modifiedAt {
                    newestById[meta.id] = session
                }
            } else {
                newestById[meta.id] = session
            }
        }
        var sessions = Array(newestById.values)
        sessions.sort { $0.activityAt > $1.activityAt }
        if let limit = limit, limit < sessions.count {
            return Array(sessions.prefix(limit))
        }
        return sessions
    }

    // MARK: - Last user message

    /// Timestamp of the newest real user message in a rollout — the
    /// codex counterpart of `AgentSessionScanner.lastTurnStartDate`,
    /// and the value the sidebar shows and sorts on.
    ///
    /// Rollout records carry their own top-level `timestamp`, so this
    /// is read, never inferred from the file's mtime. Injected context
    /// blocks (`isContextText` — environment dumps, instruction
    /// preambles) are user-ROLE records that the user did not type;
    /// counting them would stamp a session at the moment codex
    /// re-primed it rather than at the moment its owner spoke.
    ///
    /// Escalating window for the same reason as the claude side: one
    /// tool-heavy turn can push the turn's opening record well past a
    /// small tail, and only a file with nothing found in the first
    /// window pays for the second.
    static func lastUserMessageDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        for budget in [256 * 1024, 4 * 1024 * 1024] {
            if let found = userMessageScan(of: url, budget: budget) {
                return found
            }
            if let size, size <= UInt64(budget) { break }
        }
        return nil
    }

    private static func userMessageScan(of url: URL, budget: Int) -> Date? {
        guard let text = AgentSessionScanner.boundedTail(of: url,
                                                         budget: budget)
        else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            // Cheap pre-filter; correctness comes from the parse below.
            guard line.contains("\"user\"") else { continue }
            guard let data = line.trimmingCharacters(in: .whitespaces)
                    .data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  payload["role"] as? String == "user",
                  let content = payload["content"] as? [Any]
            else { continue }
            var parts: [String] = []
            for block in content {
                if let dict = block as? [String: Any],
                   let t = dict["text"] as? String, !t.isEmpty {
                    parts.append(t)
                }
            }
            let joined = parts.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty, !isContextText(joined) else { continue }
            return AgentSessionScanner.isoDate(obj["timestamp"])
        }
        return nil
    }

    // MARK: - Context footprint

    /// How full the context window is on this rollout's most recent API
    /// call — the codex counterpart of
    /// `AgentSessionScanner.lastContextTokens`, and what seeds the
    /// composer's context chip. 0 when the rollout carries no usage
    /// record.
    ///
    /// Read from `event_msg` → `token_count` →
    /// `info.last_token_usage`. WHICH of the two usage blocks is read
    /// is the whole correctness question here: `total_token_usage` is
    /// summed across every API call of the SESSION and overcounts the
    /// real context by orders of magnitude on a long one (it also
    /// RESETS on a `thread_settings_applied` record, so it is not even
    /// a session total); `last_token_usage` describes the newest call
    /// alone. The same hazard is why `CodexEventParser` stamps no
    /// context on `turn.completed`.
    ///
    /// `input_tokens` is the value, not `total_tokens`: codex's input
    /// already INCLUDES the cached prefix, so it IS the input side of
    /// that call — the same quantity claude reaches by adding its
    /// cache fields in, and the one claude's and kimi's own context
    /// indicators divide by the window. `total_tokens` adds the
    /// reply, which those indicators exclude.
    ///
    /// The total is the FALLBACK, and it is load-bearing: rollouts
    /// from an older codex populate `total_tokens` alone and leave
    /// every component 0, so reading
    /// the input alone would report those sessions as having no usage
    /// at all.
    static func lastContextTokens(of url: URL) -> Int {
        lastContextInfo(of: url).tokens
    }

    /// The footprint PLUS the window it sits in.
    /// `info.model_context_window` rides the very record the footprint
    /// is read from, so the occupancy tooltip can divide by the model's
    /// real window instead of a constant — the recorded window on this
    /// machine is 258,400 where the shared constant says 200,000, which
    /// overstates every codex session's usage. `window` is 0 when the
    /// record carries none (older rollouts), and the caller falls back.
    static func lastContextInfo(of url: URL) -> (tokens: Int, window: Int) {
        // Escalating window for the same reason as `lastUserMessageDate`:
        // one oversized tool-output record can push the newest
        // token_count past a small tail. The second window is a safety
        // net that all but never runs, and only a file that misses the
        // first pays for it.
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        for budget in [256 * 1024, 4 * 1024 * 1024] {
            let found = contextTokenScan(of: url, budget: budget)
            if found.tokens > 0 { return found }
            if let size, size <= UInt64(budget) { break }
        }
        return (0, 0)
    }

    private static func contextTokenScan(of url: URL,
                                         budget: Int) -> (tokens: Int, window: Int) {
        guard let text = AgentSessionScanner.boundedTail(of: url,
                                                         budget: budget)
        else { return (0, 0) }
        var last = 0
        var window = 0
        func intField(_ value: Any?) -> Int {
            if let i = value as? Int { return i }
            if let d = value as? Double { return Int(d) }
            return 0
        }
        text.enumerateLines { line, _ in
            // Cheap pre-filter; correctness comes from the parse below.
            guard line.contains("\"token_count\"") else { return }
            guard let data = line.trimmingCharacters(in: .whitespaces)
                    .data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["last_token_usage"] as? [String: Any]
            else { return }
            // Input side first; the old schema's total-only records
            // fall back to the total rather than reading as empty.
            let input = intField(usage["input_tokens"])
            let total = input > 0 ? input : intField(usage["total_tokens"])
            // Forward walk, so the NEWEST record wins. It may legitimately
            // be smaller than the one before it — a compaction drops the
            // number back down, and that lower number is the honest
            // one to show. The window travels WITH the record that won:
            // a mid-session model switch changes both together, and a
            // stale window against a fresh number misstates the
            // occupancy exactly the way a constant did.
            if total > 0 {
                last = total
                window = intField(info["model_context_window"])
            }
        }
        return (last, window)
    }

    /// Every rollout file belonging to one session id. A resume records
    /// a new rollout for the same session, and the scanner surfaces only
    /// the newest — deletion has to remove the whole set or the session
    /// resurrects from an older rollout on the next scan.
    static func rolloutFiles(forSessionId sessionId: String) -> [URL] {
        let fm = FileManager.default
        guard storeExists,
              let walker = fm.enumerator(
                at: sessionRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else {
            return []
        }
        var found: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else {
                continue
            }
            // The filename embeds the session UUID — cheap pre-filter;
            // the meta read confirms (older files could clash on names).
            if name.contains(sessionId) {
                found.append(url)
            } else if let meta = readMeta(of: url), meta.id == sessionId {
                found.append(url)
            }
        }
        return found
    }

    /// `(session_id, cwd, derivedTitle)` from a rollout's head. The id
    /// falls back to the UUID embedded in the filename when the meta
    /// line is unreadable.
    ///
    /// `derivedTitle` is the codex counterpart of claude's local title
    /// derivation, used when the session has no `thread_name` in the
    /// index (Codex Desktop's subagent sessions usually don't): the
    /// first meaningful user message, collapsed and capped like claude
    /// titles, falling back to the subagent's nickname. The head window
    /// is half a megabyte because the session_meta line alone runs
    /// ~40 KB and an instruction echo of similar size can precede the
    /// first real user message.
    private static func readMeta(of url: URL)
    -> (id: String, cwd: URL?, derivedTitle: String?,
        origin: AgentSessionOrigin, originTitle: String?,
        scheduledTaskName: String?)? {
        var id: String? = nil
        var cwd: URL? = nil
        var nickname: String? = nil
        var derived: String? = nil
        var origin: AgentSessionOrigin = .user
        var originTitle: String? = nil
        var scheduledTaskName: String? = nil
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let head = handle.readData(ofLength: 512 * 1024)
            // Lossy on purpose: the 512 KB byte window can cut a
            // multi-byte character, and strict decoding would then
            // reject the WHOLE head — misclassifying the session. Only
            // the final partial line is affected, and it is discarded
            // regardless.
            let text = String(decoding: head, as: UTF8.self)
            do {
                let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                if let firstLine = lines.first,
                   let data = firstLine.data(using: .utf8),
                   let obj = (try? JSONSerialization.jsonObject(with: data))
                        as? [String: Any],
                   let payload = obj["payload"] as? [String: Any] {
                    id = payload["id"] as? String
                    nickname = payload["agent_nickname"] as? String
                    if let path = payload["cwd"] as? String, !path.isEmpty {
                        cwd = URL(fileURLWithPath: path, isDirectory: true)
                    }
                    // Spawned child threads mark themselves in the
                    // session_meta record. Codex Desktop nests them
                    // under the parent; in a flat list they need their
                    // own identity — and the parent's replayed prompt
                    // must not become their title (all siblings share
                    // it), so the spawn metadata names them instead.
                    let source = payload["source"] as? [String: Any]
                    let sub = source?["subagent"] as? [String: Any]
                    if sub != nil || payload["thread_source"] as? String == "subagent" {
                        origin = .subagent
                        if let spawn = sub?["thread_spawn"] as? [String: Any] {
                            let nick = spawn["agent_nickname"] as? String
                            let leaf = (spawn["agent_path"] as? String)?
                                .split(separator: "/").last.map(String.init)
                            switch (nick, leaf) {
                            case (let n?, let l?): originTitle = "\(n) · \(l)"
                            case (let n?, nil): originTitle = n
                            default: break
                            }
                        } else if let role = sub?["other"] as? String,
                                  !role.isEmpty {
                            originTitle = "\(role.capitalized) check"
                        }
                    }
                }
                for line in lines.dropFirst() {
                    guard let data = line.data(using: .utf8),
                          let obj = (try? JSONSerialization.jsonObject(with: data))
                            as? [String: Any],
                          let payload = obj["payload"] as? [String: Any],
                          payload["role"] as? String == "user",
                          let content = payload["content"] as? [Any]
                    else { continue }
                    var parts: [String] = []
                    for block in content {
                        if let dict = block as? [String: Any],
                           let t = dict["text"] as? String, !t.isEmpty {
                            parts.append(t)
                        }
                    }
                    let joined = parts.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !isContextText(joined) else { continue }
                    // A run SipAI fired carries the same marker the
                    // claude scanner reads, and is filed under the same
                    // task — one shared extractor so the two agents
                    // cannot classify one marker differently.
                    if let task = AgentSessionScanner
                        .extractScheduledTaskName(from: joined) {
                        scheduledTaskName = task
                        origin = .scheduled
                    }
                    let body = strippedTaskMarker(joined)
                    // A cron automation opens its first real message
                    // with the automation header.
                    if origin == .user {
                        let range = NSRange(location: 0,
                                            length: (body as NSString).length)
                        if let m = automationRegex.firstMatch(in: body,
                                                              range: range) {
                            origin = .scheduled
                            let name = (body as NSString)
                                .substring(with: m.range(at: 1))
                            if !name.isEmpty { originTitle = name }
                        }
                    }
                    let collapsed = body
                        .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                        .joined(separator: " ")
                    guard !collapsed.isEmpty else { continue }
                    derived = collapsed.count > 50
                        ? String(collapsed.prefix(47)) + "..."
                        : collapsed
                    break
                }
            }
        }
        if derived == nil, let nick = nickname, !nick.isEmpty {
            derived = "\(nick) (subagent)"
        }
        if id == nil {
            // rollout-<stamp>-<uuid>.jsonl — take the trailing UUID.
            let stem = url.deletingPathExtension().lastPathComponent
            let parts = stem.split(separator: "-")
            if parts.count >= 5 {
                let tail = parts.suffix(5).joined(separator: "-")
                if UUID(uuidString: tail) != nil { id = tail }
            }
        }
        guard let sid = id, !sid.isEmpty else { return nil }
        return (sid, cwd, derived, origin, originTitle, scheduledTaskName)
    }

    /// `{session_id: thread_name}` from codex's own index — later lines
    /// win, matching how codex appends updates.
    private static func indexNames() -> [String: String] {
        // Lossy: codex appends to this index live, and a strict decode
        // of a snapshot that ends mid-character would drop EVERY name.
        guard let data = try? Data(contentsOf: sessionIndex) else {
            return [:]
        }
        let text = String(decoding: data, as: UTF8.self)
        var names: [String: String] = [:]
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  let id = obj["id"] as? String,
                  let name = obj["thread_name"] as? String else { return }
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty && !cleaned.isEmpty {
                names[id] = cleaned
            }
        }
        return names
    }

    private static func neutralTitle(for cwd: URL?) -> String {
        if let folder = cwd?.lastPathComponent, !folder.isEmpty,
           folder != FileManager.default
               .homeDirectoryForCurrentUser.lastPathComponent {
            return "\(folder) session"
        }
        return String(localized: "New Codex session",
                      comment: "Fallback title for a codex session with no name")
    }

    // MARK: - History

    /// Walk a rollout and emit history items in chronological order.
    /// The conversation lives in payloads carrying `role` + `content`
    /// blocks; tool activity (`function_call` and friends) becomes
    /// `.toolUse` markers so the shared renderers show it inline.
    static func readHistory(of url: URL, maxTurns: Int = 50,
                            byteBudget: Int? = nil)
    -> [AgentSessionHistoryItem] {
        // Same contract as AgentSessionScanner.readHistory: bounded
        // tail + lossy decode, so a live rollout mid-write can lose at
        // most one edge line — never the whole transcript — and an
        // oversized file can't freeze the open. `byteBudget` widens the
        // tail for whole-conversation callers (search); it never
        // removes the bound.
        guard let text = AgentSessionScanner.boundedTail(
            of: url, budget: byteBudget ?? (8 * 1024 * 1024))
        else {
            return []
        }
        var items: [AgentSessionHistoryItem] = []
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData))
                    as? [String: Any],
                  let payload = obj["payload"] as? [String: Any]
            else { return }

            // The agent summarised the conversation and carried on.
            // Codex states no before/after figures, so the row says so
            // without them — the same row every agent gets, minus what
            // this one does not record.
            //
            // `replacement_history` is deliberately NOT rendered: it is
            // the retained ORIGINAL user turns kept verbatim (codex
            // writes no summary text), and the rollout still holds
            // those turns above this record. Rendering it would replay
            // the conversation a second time.
            if (obj["type"] as? String) == "compacted" {
                items.append(AgentSessionHistoryItem(
                    kind: .compaction(preTokens: nil, postTokens: nil)))
                return
            }

            if let role = payload["role"] as? String,
               let content = payload["content"] as? [Any],
               role == "user" || role == "assistant" {
                var parts: [String] = []
                for block in content {
                    if let dict = block as? [String: Any],
                       let t = dict["text"] as? String, !t.isEmpty {
                        parts.append(t)
                    }
                }
                let joined = parts.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !joined.isEmpty else { return }
                if role == "user" {
                    if isContextText(joined) {
                        return
                    }
                    // Show the prompt, not the bookkeeping tag that
                    // filed the run under its task.
                    items.append(AgentSessionHistoryItem(
                        kind: .userText(strippedTaskMarker(joined))))
                } else {
                    items.append(AgentSessionHistoryItem(
                        kind: .assistantText(joined)))
                }
                return
            }

            switch payload["type"] as? String {
            case "function_call", "local_shell_call", "custom_tool_call",
                 "web_search_call":
                // A tool row with nothing to say is pure noise in a
                // read-only transcript — show it with its arguments or
                // not at all.
                guard let summary = toolCallSummary(payload) else { break }
                let name = (payload["name"] as? String)
                    ?? (payload["type"] as? String) ?? "tool"
                items.append(AgentSessionHistoryItem(
                    kind: .toolUse(id: UUID().uuidString,
                                   name: name,
                                   input: ["command": summary])))
            default:
                break
            }
        }

        // Same turn-based cap as the Claude reader.
        let userIndices = items.enumerated().compactMap { i, it -> Int? in
            if case .userText = it.kind { return i }
            return nil
        }
        if userIndices.count <= maxTurns { return items }
        let startIdx = userIndices[userIndices.count - maxTurns]
        return Array(items[startIdx...])
    }

    // MARK: - Tool-call summaries

    /// Argument keys most likely to say what a tool call actually did.
    private static let summaryKeys = [
        "description", "summary", "cmd", "command", "name", "message",
        "query", "path", "file_path", "url", "prompt", "target", "pattern",
    ]

    /// One human-readable line for a codex tool-call record, or nil —
    /// the interesting part lives in `arguments` (a JSON string on
    /// function_call), `input` (free text on custom_tool_call) or
    /// `action.command` (local_shell_call).
    private static func toolCallSummary(_ payload: [String: Any]) -> String? {
        if payload["type"] as? String == "local_shell_call" {
            let action = payload["action"] as? [String: Any] ?? [:]
            return compactValue(action["command"])
        }
        let raw = payload["arguments"] ?? payload["input"]
        var parsed: [String: Any]? = nil
        if let dict = raw as? [String: Any] {
            parsed = dict
        } else if let s = raw as? String,
                  !s.trimmingCharacters(in: .whitespaces).isEmpty {
            if let data = s.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any] {
                parsed = obj
            } else {
                // custom_tool_call input is often plain code, not JSON.
                return compactValue(s)
            }
        }
        guard let args = parsed else { return nil }
        for key in summaryKeys {
            if let summary = compactValue(args[key]) { return summary }
        }
        for value in args.values {
            if let summary = compactValue(value) { return summary }
        }
        return nil
    }

    /// Collapse a scalar (or scalar list) into one ≤80-char line.
    /// Long single-word base64-ish values are opaque blobs (encrypted
    /// payloads, tokens) and read as noise — rejected so the caller
    /// tries the next field. Paths and URLs survive via their slashes.
    private static func compactValue(_ value: Any?, limit: Int = 80) -> String? {
        var text: String? = nil
        if let s = value as? String {
            text = s
        } else if let arr = value as? [Any] {
            var parts: [String] = []
            for element in arr {
                if let s = element as? String { parts.append(s) }
                else if let n = element as? NSNumber { parts.append(n.stringValue) }
                else { return nil }
            }
            text = parts.isEmpty ? nil : parts.joined(separator: " ")
        } else if let n = value as? NSNumber {
            text = n.stringValue
        }
        guard let raw = text else { return nil }
        let compact = raw
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !compact.isEmpty else { return nil }
        if compact.count >= 40 && !compact.contains(" ") {
            let opaque = compact.allSatisfy {
                $0.isLetter || $0.isNumber || "+_=-".contains($0)
            }
            if opaque { return nil }
        }
        if compact.count > limit {
            return String(compact.prefix(limit - 1)) + "…"
        }
        return compact
    }
}

