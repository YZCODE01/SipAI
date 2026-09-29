// CodexSessions.swift
// Scanner + history reader for OpenAI Codex sessions.
//
// Codex stores one rollout file per recording under
// ~/.codex/sessions/YYYY/MM/DD/rollout-<stamp>-<uuid>.jsonl. Line 1 is
// a session_meta record whose payload carries the session id and cwd;
// ~/.codex/session_index.jsonl maps id → thread_name — the display
// name Codex Desktop shows, so reading it gives SipAI the same names.
//
// A FORKED thread — codex's own `codex fork`, or a SipAI branch made
// through `CodexSessionFork` — holds no copy of its history. Its
// rollout's `session_meta` names the parent and the first parent
// ordinal that is not inherited, and codex rebuilds the prefix from the
// parent's file on every resume; `readHistory` follows the same
// reference (`forkOrigin` / `inheritedLines`), so a fork renders whole.
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
        // Inlined attachment blocks go first, matched as a pair
        // (`AttachmentInline`): this is codex's one user-text cleaner,
        // so the row, the derived title and the fork's text match all
        // see the user's own words. The names the paperclip line prints
        // are read off the raw text by the caller before this runs.
        let text = AttachmentInline.stripping(text)
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

    /// The words of a user record's content blocks, joined. Codex wraps
    /// every image it is handed (`exec -i`, a paste in its terminal) in
    /// text blocks of its own — `<image name=[Image #1] path="…">`, the
    /// image, `</image>` (measured) — which are its bookkeeping, not the
    /// user's words: read as text they title a session with a temp path,
    /// put the tags in the bubble, and defeat every match against the
    /// words the user sent. Dropped as a PAIR around the image block, so
    /// a message that merely quotes such a tag keeps it. The one joiner
    /// for every user-text read here.
    static func userText(fromContent content: [Any]) -> String {
        func isImage(_ index: Int) -> Bool {
            guard content.indices.contains(index) else { return false }
            return ((content[index] as? [String: Any])?["type"] as? String) == "input_image"
        }
        var parts: [String] = []
        for (index, block) in content.enumerated() {
            guard let dict = block as? [String: Any],
                  let text = dict["text"] as? String, !text.isEmpty else { continue }
            let bare = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isImage(index + 1), bare.hasPrefix("<image name="), bare.hasSuffix(">") { continue }
            if isImage(index - 1), bare == "</image>" { continue }
            parts.append(text)
        }
        return parts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            let joined = userText(fromContent: content)
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
            if rolloutName(name, isFor: sessionId) {
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
                    let joined = userText(fromContent: content)
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

    // MARK: - Turn markers

    /// The records that open and close a turn in a rollout, read in ONE
    /// place: the history reader stamps user rows with them, the fork
    /// cuts on them, and a live watcher of an external turn would flip
    /// on them. Two spellings of this vocabulary is how those drift.
    ///
    /// A turn opens with `event_msg` → `task_started {turn_id}`; the
    /// `turn_context` and the user's `message` follow it. It closes
    /// with `task_complete {turn_id}`, or `turn_aborted {turn_id,
    /// reason}` for one that was interrupted.
    static func turnStarted(_ obj: [String: Any]) -> String? {
        guard (obj["type"] as? String) == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              (payload["type"] as? String) == "task_started",
              let id = payload["turn_id"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    static func turnEnded(_ obj: [String: Any]) -> String? {
        guard (obj["type"] as? String) == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              let kind = payload["type"] as? String,
              kind == "task_complete" || kind == "turn_aborted",
              let id = payload["turn_id"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    /// The newest turn the rollout's tail records (see `RecordedTurn`),
    /// through the two markers above: open after a `task_started` with
    /// no end behind it. Its start is codex's own `started_at` (epoch
    /// seconds), else the record's timestamp; its length codex's own
    /// `duration_ms`. Nil when the tail holds no marker at all.
    ///
    /// Only lines naming a marker are parsed — the read runs when a
    /// watcher starts and at every turn's end, and a tail is mostly
    /// tool output.
    static func latestTurn(of url: URL, budget: Int = 1024 * 1024) -> RecordedTurn? {
        // Escalating window, the rule every tail reader here follows: a
        // session opened mid-turn asks with the whole turn's output
        // between its start marker and EOF, and one tool-heavy turn can
        // push that marker past the first window — read as "no turn",
        // the session would sit unlit and ungated through it. Only a
        // file with no marker in the first window pays for the second.
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                    as? NSNumber)?.uint64Value
        let wide = 8 * 1024 * 1024
        for window in (budget < wide ? [budget, wide] : [budget]) {
            if let found = latestTurnScan(of: url, budget: window) { return found }
            if let size, size <= UInt64(window) { break }
        }
        return nil
    }

    private static func latestTurnScan(of url: URL, budget: Int) -> RecordedTurn? {
        guard let text = AgentSessionScanner.boundedTail(of: url, budget: budget)
        else { return nil }
        var latest: RecordedTurn? = nil
        text.enumerateLines { line, _ in
            guard line.contains("task_started") || line.contains("task_complete")
                    || line.contains("turn_aborted"),
                  let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any]
            else { return }
            let payload = obj["payload"] as? [String: Any]
            if turnStarted(obj) != nil {
                let started = (payload?["started_at"] as? NSNumber)
                    .map { Date(timeIntervalSince1970: $0.doubleValue) }
                    ?? AgentSessionScanner.isoDate(obj["timestamp"])
                latest = RecordedTurn(open: true, startedAt: started, seconds: nil)
            } else if turnEnded(obj) != nil {
                var turn = latest ?? RecordedTurn(open: false, startedAt: nil, seconds: nil)
                turn.open = false
                if let ms = (payload?["duration_ms"] as? NSNumber)?.doubleValue, ms > 0 {
                    turn.seconds = ms / 1000
                } else if let start = turn.startedAt,
                          let end = AgentSessionScanner.isoDate(obj["timestamp"]) {
                    turn.seconds = end.timeIntervalSince(start)
                }
                latest = turn
            }
        }
        return latest
    }

    // MARK: - Fork reference

    /// Where a forked rollout's history begins: the parent thread and
    /// the parent's first ordinal that is NOT inherited.
    ///
    /// Codex's own fork copies nothing. The new rollout's `session_meta`
    /// names `forked_from_id` and `forked_from_ordinal_exclusive`, and
    /// codex rebuilds the prefix from the parent's file on every resume
    /// — so a reader that opens the one file sees a conversation that
    /// starts mid-way, and a fork made in a terminal renders as an
    /// empty transcript. This reader follows the reference the same
    /// way codex does.
    ///
    /// BOTH fields are required. A subagent's rollout carries
    /// `forked_from_id` too (its parent thread) with a
    /// `subagent_history_start_ordinal` instead of the exclusive
    /// ordinal, and it is not a prefix of its parent: splicing one
    /// would replay the parent's whole conversation above every
    /// subagent row.
    struct ForkOrigin: Equatable {
        let parentId: String
        let exclusiveOrdinal: Int
    }

    static func forkOrigin(ofHeadLine line: String) -> ForkOrigin? {
        guard let data = line.trimmingCharacters(in: .whitespaces)
                .data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              (obj["type"] as? String) == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let parent = payload["forked_from_id"] as? String,
              !parent.isEmpty,
              let exclusive = (payload["forked_from_ordinal_exclusive"]
                                as? NSNumber)?.intValue
        else { return nil }
        return ForkOrigin(parentId: parent, exclusiveOrdinal: exclusive)
    }

    static func forkOrigin(of url: URL) -> ForkOrigin? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        // The meta record alone can run tens of KB (base instructions
        // ride in it); the window only has to reach its end.
        let head = handle.readData(ofLength: 512 * 1024)
        let text = String(decoding: head, as: UTF8.self)
        guard let first = text.split(separator: "\n",
                                     omittingEmptySubsequences: true).first
        else { return nil }
        return forkOrigin(ofHeadLine: String(first))
    }

    /// Whether `name` is the file codex writes for session `id`:
    /// `rollout-<timestamp>-<id>.jsonl`. Exact, never a substring — an
    /// id is read out of file content, and one as short as `-` is in
    /// every rollout's name, which on the delete path means every
    /// rollout in the store.
    static func rolloutName(_ name: String, isFor id: String) -> Bool {
        !id.isEmpty && name.hasPrefix("rollout-") && name.hasSuffix("-\(id).jsonl")
    }

    /// Newest rollout whose FILENAME carries this thread id.
    ///
    /// Filename-only on purpose. `rolloutFiles(forSessionId:)` answers
    /// the same question authoritatively, but falls back to reading a
    /// 512 KB head from every rollout that doesn't match — hundreds of
    /// files, at the end of every turn and on every open of a branch.
    /// Codex always embeds the id in the name
    /// (`rollout-<stamp>-<uuid>.jsonl`), so the cheap check is the
    /// right one here; the authoritative walk stays where deletion
    /// needs it.
    ///
    /// `root` is the store to look in; the default is the real one, and
    /// a harness hands in a throwaway.
    static func rolloutFile(namedForId id: String,
                            root: URL = sessionRoot) -> URL? {
        guard !id.isEmpty,
              let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        var newest: (url: URL, at: Date)? = nil
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard rolloutName(name, isFor: id) else { continue }
            let at = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest == nil || at > newest!.at { newest = (url, at) }
        }
        return newest?.url
    }

    /// A record's `ordinal`, read off the line's head without a full
    /// parse — the field sits second on every rollout line
    /// (`{"timestamp":…,"ordinal":N,…}`), and the prefix scan below
    /// visits every line of a parent up to the cut, which on a long
    /// session is most of a very large file. Falls back to a parse when
    /// the head does not carry it, and to `index` for a record with no
    /// ordinal at all (an older codex).
    static func ordinal(ofLine line: Substring, index: Int) -> Int {
        let head = line.prefix(96)
        if let r = head.range(of: "\"ordinal\":") {
            // ASCII digits only, and never more than fit: a line is file
            // content, and an unbounded run of digits would overflow the
            // accumulation and trap. Anything else falls to the parse.
            var n = 0
            var digits = 0
            for ch in head[r.upperBound...] {
                guard ch.isASCII, let d = ch.wholeNumberValue, digits < 18 else { break }
                n = n * 10 + d
                digits += 1
            }
            if digits > 0, digits < 18 { return n }
        }
        if let data = line.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data))
            as? [String: Any],
           let n = (obj["ordinal"] as? NSNumber)?.intValue {
            return n
        }
        return index
    }

    /// The parent's records BELOW the cut, newest `budget` bytes of
    /// them, and the byte offset the cut sits at.
    ///
    /// Ordinals are monotone in a rollout, so the inherited part is a
    /// PREFIX of the parent's file and the scan can stop at the first
    /// record at or past the cut. The window drops its OLDEST lines to
    /// stay under budget, so the turns nearest the cut — the ones the
    /// branch diverged from — are what survives a bound. Streamed a
    /// chunk at a time: the parent can be hundreds of MB, and a whole-
    /// file read is the freeze every other reader here avoids.
    private static let prefixChunk = 1 << 20

    static func inheritedPrefix(of parent: URL, belowOrdinal cut: Int,
                                budget: Int)
    -> (lines: [String], bytes: Int, cutOffset: UInt64) {
        guard let reader = try? FileHandle(forReadingFrom: parent) else {
            return ([], 0, 0)
        }
        defer { try? reader.close() }
        // The budget window drops its OLDEST lines from a moving head:
        // `removeFirst` shifts every line kept, once per line read.
        var kept: [String] = []
        var head = 0
        var keptBytes = 0
        var offset: UInt64 = 0
        var index = 0
        var leftover = Data()
        var reachedCut = false

        func take(_ lineData: Data) -> Bool {
            // Lossy on purpose — a read can land inside a multibyte
            // character of a file codex is still writing.
            let line = String(decoding: lineData, as: UTF8.self)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { index += 1 }
            guard !trimmed.isEmpty else { return true }
            if ordinal(ofLine: Substring(trimmed), index: index) >= cut {
                return false
            }
            kept.append(trimmed)
            keptBytes += trimmed.utf8.count + 1
            while keptBytes > budget, head < kept.count {
                keptBytes -= kept[head].utf8.count + 1
                head += 1
            }
            if head > 4096, head * 2 > kept.count {
                kept.removeFirst(head)
                head = 0
            }
            return true
        }

        // Lines are consumed by a cursor and the buffer is compacted once
        // per chunk: removing each line from the front shifts the rest of
        // the chunk, once per line — quadratic in a chunk of short lines.
        outer: while true {
            let chunk = (try? reader.read(upToCount: prefixChunk)) ?? Data()
            if chunk.isEmpty { break }
            leftover.append(chunk)
            var start = leftover.startIndex
            while let nl = leftover[start...].firstIndex(of: 0x0A) {
                let lineData = leftover.subdata(in: start..<nl)
                let consumed = UInt64(nl - start + 1)
                start = nl + 1
                if !take(lineData) { reachedCut = true; break outer }
                offset += consumed
            }
            leftover.removeSubrange(leftover.startIndex..<start)
        }
        if !reachedCut, !leftover.isEmpty, take(leftover) {
            offset += UInt64(leftover.count)
        }
        return (Array(kept[head...]), keptBytes, offset)
    }

    /// Everything a forked rollout inherits, oldest first, following
    /// the chain up through a fork of a fork. Each level contributes
    /// the parent's records below THAT level's cut, and a parent that
    /// is itself a fork is cut at the smaller of the two bounds. A
    /// missing parent (deleted, in codex or here) contributes nothing:
    /// the branch then shows its own turns alone, exactly as codex's
    /// own picker would. Depth-capped so a cycle written by a broken
    /// store cannot recurse forever.
    static let forkDepthCap = 8

    static func inheritedLines(for origin: ForkOrigin, budget: Int,
                               root: URL = sessionRoot,
                               depth: Int = 0) -> [String] {
        guard depth < forkDepthCap,
              let parent = rolloutFile(namedForId: origin.parentId, root: root)
        else { return [] }
        var lines: [String] = []
        if let grand = forkOrigin(of: parent) {
            let bound = ForkOrigin(
                parentId: grand.parentId,
                exclusiveOrdinal: min(grand.exclusiveOrdinal,
                                      origin.exclusiveOrdinal))
            lines = inheritedLines(for: bound, budget: budget, root: root,
                                   depth: depth + 1)
        }
        lines.append(contentsOf: inheritedPrefix(
            of: parent, belowOrdinal: origin.exclusiveOrdinal,
            budget: budget).lines)
        // ONE budget for the whole chain, not one per level: the
        // grandparent's lines are the oldest, so they are the ones a
        // bound drops first — the same newest-wins rule each level
        // applies to itself.
        var total = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        var drop = 0
        while total > budget, drop < lines.count {
            total -= lines[drop].utf8.count + 1
            drop += 1
        }
        return drop == 0 ? lines : Array(lines[drop...])
    }

    /// Every turn a rollout opened, oldest first, by the id its
    /// `task_started` carries — streamed over the WHOLE file with no
    /// line retained, so a multi-hundred-MB rollout costs a pass and
    /// no memory. `belowOrdinal` stops at a fork's cut for a parent.
    static func turnIds(of url: URL, belowOrdinal cut: Int? = nil) -> [String] {
        guard let reader = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? reader.close() }
        var ids: [String] = []
        var index = 0
        var leftover = Data()
        var stop = false

        func take(_ lineData: Data) {
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            defer { index += 1 }
            guard !line.isEmpty else { return }
            if let cut, ordinal(ofLine: Substring(line), index: index) >= cut {
                stop = true
                return
            }
            // Cheap pre-filter; correctness comes from the parse.
            guard line.contains("\"task_started\""),
                  let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  let id = turnStarted(obj) else { return }
            if ids.last != id { ids.append(id) }
        }

        // Consumed by a cursor, compacted once per chunk (see
        // `inheritedPrefix`).
        outer: while !stop {
            let chunk = (try? reader.read(upToCount: prefixChunk)) ?? Data()
            if chunk.isEmpty { break }
            leftover.append(chunk)
            var start = leftover.startIndex
            while let nl = leftover[start...].firstIndex(of: 0x0A) {
                let lineData = leftover.subdata(in: start..<nl)
                start = nl + 1
                take(lineData)
                if stop { break outer }
            }
            leftover.removeSubrange(leftover.startIndex..<start)
        }
        if !stop, !leftover.isEmpty { take(leftover) }
        return ids
    }

    /// The turns a forked rollout inherits, oldest first, up the same
    /// chain `inheritedLines` walks — for the fork, which has to name
    /// the turn BEFORE a cut and must not be bounded by a read budget:
    /// a cut whose predecessor fell outside a window would read as the
    /// first turn, and "nothing to branch from" starts a NEW session.
    static func inheritedTurnIds(for origin: ForkOrigin,
                                 root: URL = sessionRoot,
                                 depth: Int = 0) -> [String] {
        guard depth < forkDepthCap,
              let parent = rolloutFile(namedForId: origin.parentId, root: root)
        else { return [] }
        var ids: [String] = []
        if let grand = forkOrigin(of: parent) {
            let bound = ForkOrigin(
                parentId: grand.parentId,
                exclusiveOrdinal: min(grand.exclusiveOrdinal,
                                      origin.exclusiveOrdinal))
            ids = inheritedTurnIds(for: bound, root: root, depth: depth + 1)
        }
        for id in turnIds(of: parent, belowOrdinal: origin.exclusiveOrdinal)
        where ids.last != id {
            ids.append(id)
        }
        return ids
    }

    /// The bytes a history read of this rollout actually covers: its
    /// own size plus, for a fork, the inherited prefix up the chain.
    /// What the transcript's "Show earlier" and the find bar's scope
    /// note judge partiality against — a branch's own file is tiny,
    /// and judged on that alone a long inherited prefix bounded by the
    /// read would pass for the whole conversation.
    static func historyExtent(of url: URL, root: URL = sessionRoot) -> UInt64 {
        let own = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                   as? NSNumber)?.uint64Value ?? 0
        var total = own
        var origin = forkOrigin(of: url)
        var depth = 0
        while let o = origin, depth < forkDepthCap,
              let parent = rolloutFile(namedForId: o.parentId, root: root) {
            // A zero budget keeps no lines; only the offset is wanted.
            total += inheritedPrefix(of: parent, belowOrdinal: o.exclusiveOrdinal,
                                     budget: 0).cutOffset
            let grand = forkOrigin(of: parent)
            origin = grand.map {
                ForkOrigin(parentId: $0.parentId,
                           exclusiveOrdinal: min($0.exclusiveOrdinal,
                                                 o.exclusiveOrdinal))
            }
            depth += 1
        }
        return total
    }

    // MARK: - History

    /// One rollout record at a time into history rows.
    ///
    /// A struct rather than a function over the whole file so the
    /// same decoder can be fed the parent's inherited prefix and then
    /// the branch's own records, and — later — the lines a live
    /// watcher of an external turn appends. It remembers the turn it
    /// is inside: a user row's handle back into the transcript
    /// (`AgentSessionHistoryItem.recordUuid`) is the `turn_id` of the
    /// `task_started` that opened it, which is what a fork cuts on.
    struct RolloutDecoder {
        private(set) var currentTurnId: String? = nil
        /// Web searches already given a row, by id — see the search case
        /// in `items(forLine:)`.
        private var seenWebSearchIds: Set<String> = []
        /// Searches given a row in the turn under way whose OTHER record
        /// has not arrived yet, by kind. A search is recorded twice: its
        /// `item_completed` and, one ordinal later, a `web_search_call`
        /// — and the call carries no `id` at all, so the pair cannot be
        /// matched by id. It is matched by COUNT within the turn: the
        /// second record of a pair is skipped whichever kind it is, and
        /// two searches for one query stay two rows.
        private var unpairedSearchItems = 0
        private var unpairedSearchCalls = 0
        /// Keep reasoning summaries as `.thinking` rows (see
        /// `readHistory`). Off, a reasoning record reads as nothing.
        var includeThinking = false

        init(includeThinking: Bool = false) {
            self.includeThinking = includeThinking
        }

        mutating func items(forLine line: String) -> [AgentSessionHistoryItem] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData))
                    as? [String: Any]
            else { return [] }
            if let turn = CodexSessionScanner.turnStarted(obj) {
                currentTurnId = turn
                unpairedSearchItems = 0
                unpairedSearchCalls = 0
                return []
            }
            guard let payload = obj["payload"] as? [String: Any] else {
                return []
            }

            // A web search's own record (`item_completed`, a `WebSearch`
            // item, or an `Extension` of kind `web.search`). Under codex's
            // code mode it is the ONLY record of a search — the call that
            // ran it is an `exec` script — and it carries the spelling the
            // live feed shows (the terms, or the page). Beside the older
            // `web_search_call` the same search has both records:
            // whichever comes first is the row, and the other is skipped
            // — by id where the records carry one, else by count within
            // the turn — so a search is never drawn or counted twice.
            if (obj["type"] as? String) == "event_msg",
               (payload["type"] as? String) == "item_completed",
               let item = payload["item"] as? [String: Any],
               CodexSessionScanner.isWebSearchItem(item) {
                if let id = item["id"] as? String, !id.isEmpty,
                   !seenWebSearchIds.insert(id).inserted {
                    if unpairedSearchCalls > 0 { unpairedSearchCalls -= 1 }
                    return []
                }
                guard let summary = CodexSessionScanner.compactValue(item["query"])
                        ?? CodexSessionScanner.webSearchSummary(
                            item["action"] as? [String: Any] ?? [:])
                else { return [] }
                if unpairedSearchCalls > 0 {
                    unpairedSearchCalls -= 1
                    return []
                }
                unpairedSearchItems += 1
                return [AgentSessionHistoryItem(
                    kind: .toolUse(id: UUID().uuidString,
                                   name: "web_search_call",
                                   input: ["command": summary]))]
            }

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
                return [AgentSessionHistoryItem(
                    kind: .compaction(preTokens: nil, postTokens: nil))]
            }

            if let role = payload["role"] as? String,
               let content = payload["content"] as? [Any],
               role == "user" || role == "assistant" {
                let joined = CodexSessionScanner.userText(fromContent: content)
                guard !joined.isEmpty else { return [] }
                if role == "user" {
                    if CodexSessionScanner.isContextText(joined) {
                        return []
                    }
                    // Show the prompt, not the bookkeeping tag that
                    // filed the run under its task — nor the inlined
                    // attachment blocks, whose names ride the row.
                    var item = AgentSessionHistoryItem(
                        kind: .userText(CodexSessionScanner.strippedTaskMarker(joined)),
                        recordUuid: currentTurnId)
                    item.attachedFiles = AttachmentInline.names(in: joined)
                    return [item]
                }
                return [AgentSessionHistoryItem(kind: .assistantText(joined))]
            }

            switch payload["type"] as? String {
            case "reasoning" where includeThinking:
                // The readable part is the SUMMARY; the rest of the
                // record is encrypted. A reasoning record whose summary
                // came back empty has nothing to draw.
                let summary = (payload["summary"] as? [Any] ?? [])
                    .compactMap { ($0 as? [String: Any])?["text"] as? String }
                    .joined(separator: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !summary.isEmpty else { return [] }
                return [AgentSessionHistoryItem(kind: .thinking(summary))]
            case "function_call", "local_shell_call", "custom_tool_call",
                 "web_search_call":
                // The same search already read off its `item_completed`
                // record — see above.
                let isSearchCall = payload["type"] as? String == "web_search_call"
                if isSearchCall,
                   let id = payload["id"] as? String, !id.isEmpty,
                   !seenWebSearchIds.insert(id).inserted {
                    if unpairedSearchItems > 0 { unpairedSearchItems -= 1 }
                    return []
                }
                // A tool row with nothing to say is pure noise in a
                // read-only transcript — show it with its arguments or
                // not at all.
                guard let summary = CodexSessionScanner.toolCallSummary(payload)
                else { return [] }
                if isSearchCall {
                    if unpairedSearchItems > 0 {
                        unpairedSearchItems -= 1
                        return []
                    }
                    unpairedSearchCalls += 1
                }
                let name = (payload["name"] as? String)
                    ?? (payload["type"] as? String) ?? "tool"
                return [AgentSessionHistoryItem(
                    kind: .toolUse(id: UUID().uuidString,
                                   name: name,
                                   input: ["command": summary]))]
            default:
                return []
            }
        }
    }

    /// Walk a rollout and emit history items in chronological order.
    /// The conversation lives in payloads carrying `role` + `content`
    /// blocks; tool activity (`function_call` and friends) becomes
    /// `.toolUse` markers so the shared renderers show it inline.
    ///
    /// A forked rollout is read as codex reads it: the parent's
    /// records below the cut first (`inheritedLines`), then its own.
    ///
    /// `includeThinking` keeps reasoning summaries as `.thinking` rows,
    /// for a session with Chat only turns in it; the caller then applies
    /// `AgentSessionHistoryItem.keepingThoughts`.
    static func readHistory(of url: URL, maxTurns: Int = 50,
                            byteBudget: Int? = nil,
                            root: URL = sessionRoot,
                            includeThinking: Bool = false)
    -> [AgentSessionHistoryItem] {
        // Same contract as AgentSessionScanner.readHistory: bounded
        // tail + lossy decode, so a live rollout mid-write can lose at
        // most one edge line — never the whole transcript — and an
        // oversized file can't freeze the open. `byteBudget` widens the
        // tail for whole-conversation callers (search); it never
        // removes the bound. The inherited prefix of a fork is held to
        // the same budget.
        let budget = byteBudget ?? (8 * 1024 * 1024)
        guard let text = AgentSessionScanner.boundedTail(of: url, budget: budget)
        else {
            return []
        }
        var decoder = RolloutDecoder(includeThinking: includeThinking)
        var items: [AgentSessionHistoryItem] = []
        if let origin = forkOrigin(of: url) {
            for line in inheritedLines(for: origin, budget: budget, root: root) {
                items.append(contentsOf: decoder.items(forLine: line))
            }
        }
        text.enumerateLines { line, _ in
            items.append(contentsOf: decoder.items(forLine: line))
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
        if payload["type"] as? String == "web_search_call" {
            return webSearchSummary(payload["action"] as? [String: Any] ?? [:])
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

    /// A web search's `item_completed` item: `WebSearch`, or code mode's
    /// `Extension` of kind `web.search`.
    static func isWebSearchItem(_ item: [String: Any]) -> Bool {
        switch item["type"] as? String {
        case "WebSearch": return true
        case "Extension": return (item["kind"] as? String) == "web.search"
        default: return false
        }
    }

    /// A web search call's line. The rollout records only its `action`,
    /// and the live feed (`codex exec --json`) spells the same call's
    /// `query` as the search terms, the page opened, or
    /// `'pattern' in <url>` (measured) — so the row is spelled that way
    /// here too, and reads the same live and on reopen. Without this the
    /// call has no `arguments` to summarise and the row is dropped.
    private static func webSearchSummary(_ action: [String: Any]) -> String? {
        // The `item_completed` records spell the action camelCased.
        switch action["type"] as? String {
        case "open_page", "openPage":
            return compactValue(action["url"])
        case "find_in_page", "findInPage":
            let pattern = (action["pattern"] as? String) ?? ""
            let url = (action["url"] as? String) ?? ""
            guard !pattern.isEmpty, !url.isEmpty else {
                return compactValue(pattern.isEmpty ? url : pattern)
            }
            return compactValue("'\(pattern)' in \(url)")
        default:
            return compactValue(action["query"]) ?? compactValue(action["queries"])
        }
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

