// KimiSessions.swift
// Scanner + history reader for Kimi Code CLI sessions — the third
// store, alongside `AgentSessionScanner` (~/.claude/projects) and
// `CodexSessionScanner` (~/.codex/sessions).
//
// `SipAI-macOS/Verification/KimiCode/run.sh` exercises this file's
// assumptions against a real install — it spawns real turns in a temp
// cwd and names the file to edit on a FAIL. Re-run it after a kimi
// upgrade; it is the cheapest way to find out the format moved. Facts
// to keep in view:
//
//   * The wire FORMAT is not chat-shaped. `wire.jsonl` is NOT a stream
//     of chat messages — only the user's turns are. Everything the
//     agent does arrives as a `context.append_loop_event` with no
//     `role` anywhere in it, so a generic role-unwrap returns nil for
//     every one of them and `readHistory` would replay the prompts and
//     nothing else. `loopEventMessage` is the translation. Live
//     streaming masks a broken reader here: print-mode stdout IS
//     OpenAI-shaped, so a turn looks right as it streams even when
//     re-reading the transcript is broken. Whenever this file and
//     `KimiEventParsing.swift` seem to disagree about a shape, that is
//     why — they read two different formats.
//   * Kimi appends bookkeeping AS THE USER (`<system-reminder>` /
//     "Auto permission mode is active"). Unfiltered it becomes a user
//     bubble under every prompt and a candidate for the derived title
//     and for `lastUserMessageDate`, which the sidebar prints and
//     sorts on. `isInjectedContext` drops it in `message(from:)`.
//   * Kimi stores no title of its own for a session it ran, so titles
//     are derived from turn 1 and `titleIsFallback` is true for those.
//     The exceptions are a rename (`AgentSessionRename`) and a fork —
//     kimi's own and SipAI's (`KimiSessionFork`) both write `title`
//     into `state.json`. `state.json` also carries `cwd`, which is what
//     keeps kimi sessions out of `$HOME`.
//   * The wire's `runtime.set_binding` names the workspace bucket the
//     session lives under, and kimi refuses a session whose binding and
//     bucket disagree. A branch therefore stays in its source's bucket.
//
// Store layout:
//
//   $KIMI_CODE_HOME/                      (default ~/.kimi-code)
//   ├── config.toml
//   ├── session_index.jsonl
//   └── sessions/
//       └── <workDirKey>/                 one folder per working directory:
//           │                             wd_<leaf>_<sha256(path)[0..<12]>
//           └── <sessionId>/
//               ├── state.json            cwd, timestamps, title when set
//               ├── notify/state.json
//               └── agents/
//                   ├── main/wire.jsonl   the conversation's event stream
//                   └── <subagentId>/wire.jsonl
//
// So a kimi "session file" is a DIRECTORY, not a file — the one shape
// difference from the other two stores. `AgentSession.fileURL` points
// at `agents/main/wire.jsonl` (the thing every reader here parses) and
// `sessionDirectory(of:)` walks back up for the operations that need
// the whole tree (delete).
//
// History items reuse `AgentSessionHistoryItem`, so kimi transcripts
// render through the exact same rows as Claude Code and codex history.

import Foundation

enum KimiSessionScanner {

    // MARK: - Locations

    /// Kimi Code's home, honouring `KIMI_CODE_HOME`.
    ///
    /// Read fresh rather than cached in a `let`: this app is long-lived
    /// and the variable is the documented way to move the store, so a
    /// value latched at launch would keep pointing at a folder the user
    /// has since moved off.
    static var home: URL {
        let env = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code", isDirectory: true)
    }

    static var sessionRoot: URL {
        home.appendingPathComponent("sessions", isDirectory: true)
    }

    static var sessionIndex: URL {
        home.appendingPathComponent("session_index.jsonl")
    }

    static var configFile: URL {
        home.appendingPathComponent("config.toml")
    }

    /// True when the store exists — the read-only tier's availability
    /// signal, independent of whether the `kimi` binary is installed.
    static var storeExists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: sessionRoot.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// `agents/main/wire.jsonl` inside a session directory — the file
    /// every reader in here parses, and the URL an `AgentSession`
    /// carries.
    static func wireFile(inSessionDir dir: URL) -> URL {
        dir.appendingPathComponent("agents/main/wire.jsonl")
    }

    /// Locate a session directory by id, without knowing its bucket.
    ///
    /// Kimi's own `session_index.jsonl` answers this directly, and is
    /// tried first — it records `sessionDir` verbatim. The directory
    /// walk behind it covers the window where a just-created session is
    /// on disk but the index has not been flushed, which is exactly
    /// when `AgentRunner` asks (the id arrives on stdout at turn end).
    static func sessionDirectory(forId id: String) -> URL? {
        // The id is joined into a path below, and the directory found is
        // written into (a Chat only turn's tool-policy file): a plain
        // component only, and the index's `sessionDir` only when it has
        // the store's own shape — `sessions/<bucket>/<id>` — rather than
        // wherever a line of that file says.
        guard !id.isEmpty, !id.hasPrefix("."), !id.contains("/"),
              !id.contains("\u{0}") else { return nil }
        if let dir = indexedSessionDirectory(forId: id),
           dir.lastPathComponent == id,
           sessionDirectory(of: dir)?.standardizedFileURL.path == dir.standardizedFileURL.path {
            return dir
        }
        let fm = FileManager.default
        guard let buckets = try? fm.contentsOfDirectory(
            at: sessionRoot, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return nil }
        for bucket in buckets {
            let candidate = bucket.appendingPathComponent(id, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue {
                return candidate
            }
        }
        return nil
    }

    /// `sessionDir` for one id out of kimi's index, if it is listed.
    private static func indexedSessionDirectory(forId id: String) -> URL? {
        guard let text = AgentSessionScanner.boundedTail(
            of: sessionIndex, budget: 1024 * 1024) else { return nil }
        var found: URL? = nil
        text.enumerateLines { line, _ in
            guard let data = line.trimmingCharacters(in: .whitespaces)
                    .data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  (obj["sessionId"] as? String) == id,
                  let dir = obj["sessionDir"] as? String, !dir.isEmpty
            else { return }
            // Keep scanning: the NEWEST entry for an id wins, the same
            // rule `indexEntries` follows.
            found = URL(fileURLWithPath: dir, isDirectory: true)
        }
        return found
    }

    /// The session directory a wire file (or anything under it) belongs
    /// to: walk up until the parent is the workdir bucket, i.e. until
    /// the component's own parent's parent is `sessions/`.
    ///
    /// Derived by SHAPE rather than by "drop three components", so a
    /// session whose wire file could not be located (and whose
    /// `fileURL` is therefore the directory itself) resolves too.
    static func sessionDirectory(of url: URL) -> URL? {
        let rootPath = sessionRoot.standardizedFileURL.path
        var candidate = url.standardizedFileURL
        // At most a handful of hops: sessions/<key>/<id>/agents/main/f.
        for _ in 0..<8 {
            let parent = candidate.deletingLastPathComponent()
            let grand = parent.deletingLastPathComponent()
            if grand.standardizedFileURL.path == rootPath {
                return candidate
            }
            if parent.path == candidate.path { return nil }  // hit "/"
            candidate = parent
        }
        return nil
    }

    // MARK: - Scan

    /// Enumerate every session directory two levels under `sessions/`.
    /// Returns sessions sorted newest-first, tagged `agentKey == "kimi"`.
    static func scan(limit: Int? = nil) -> [AgentSession] {
        let fm = FileManager.default
        guard storeExists,
              let buckets = try? fm.contentsOfDirectory(
                at: sessionRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else { return [] }

        let index = indexEntries()
        var sessions: [AgentSession] = []

        for bucket in buckets {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: bucket.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            guard let entries = try? fm.contentsOfDirectory(
                at: bucket,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { continue }

            // One state read per session, done up front, because the
            // bucket's own working directory is derived from them —
            // see `bucketCwd` below.
            var rows: [(dir: URL, id: String,
                        state: (title: String?, cwd: URL?, createdAt: Date?))] = []
            for dir in entries {
                var entryIsDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &entryIsDir),
                      entryIsDir.boolValue else { continue }
                let id = dir.lastPathComponent
                guard !id.isEmpty, !id.hasPrefix(".") else { continue }
                rows.append((dir, id, readState(of: dir)))
            }

            // Every session in a bucket shares one working directory —
            // that is what the bucket IS — so one session that records
            // its cwd answers for all of them. That matters because a
            // session with no cwd resolves to `$HOME` when it is
            // resumed (`AgentSessionView.SessionMode.existing`), which
            // is the silent wrong-folder failure CLAUDE.md warns about:
            // the session opens, sends, and edits files somewhere the
            // user never chose. Evidence order is state.json, then
            // kimi's index, then a decode of the bucket name — the same
            // cwd-first, decode-last rule the claude scanner follows,
            // because the encoding is lossy and can only ever be a
            // guess.
            let bucketCwd = Self.bucketCwd(
                bucket: bucket,
                states: rows.map(\.state.cwd),
                indexed: rows.map { index[$0.id]?.cwd })

            for row in rows {
                let (dir, id, state) = row
                let wire = wireFile(inSessionDir: dir)
                let cwd = state.cwd ?? index[id]?.cwd ?? bucketCwd

                let wireAttrs = try? fm.attributesOfItem(atPath: wire.path)
                let wireSize = (wireAttrs?[.size] as? NSNumber)?.uint64Value ?? 0
                let wireMtime = (wireAttrs?[.modificationDate] as? Date)
                let dirMtime = (try? fm.attributesOfItem(atPath: dir.path))
                    .flatMap { $0[.modificationDate] as? Date }
                let mtime = [wireMtime, dirMtime, state.createdAt]
                    .compactMap { $0 }.max() ?? .distantPast

                // A session with no wire file — or an empty one — has no
                // conversation yet. Judged on BYTES rather than on
                // "readHistory found nothing" deliberately: the wire
                // reader below stays defensive about record shapes it
                // does not recognise, and deriving emptiness from the
                // parse would hide every kimi session from the sidebar
                // the moment the format moves.
                let emptyShell = wireSize == 0

                let head = emptyShell ? nil : readFirstUserMessage(of: wire)
                let taskName = head.flatMap {
                    AgentSessionScanner.extractScheduledTaskName(from: $0)
                }
                // Same scratch rule as both other scanners: a session
                // rooted in a temp directory is a probe, not work to
                // come back to — but a SCHEDULED run is kept wherever
                // it happened to run. Automation the user set up is
                // theirs to see, and a wrapper is free to pick a temp
                // cwd; hiding those loses real output.
                //
                // This is judged AFTER the head read for exactly that
                // reason: the marker lives in the first user record, so
                // an early bail on the cwd alone cannot know whether it
                // is dropping a probe or a task's only run.
                if taskName == nil,
                   AgentSessionScanner.isScratchLocation(cwd) { continue }

                let derived = head.map { derivedTitle(from: $0) } ?? nil
                let indexed = index[id]?.title
                let title = indexed
                    ?? state.title
                    ?? derived
                    ?? neutralTitle(for: cwd)

                var session = AgentSession(
                    id: id,
                    fileURL: wire,
                    title: title,
                    modifiedAt: mtime,
                    // Memoised against (size, mtime) in the shared
                    // cache, like both other scanners — an unchanged
                    // session costs a dictionary lookup, not a tail
                    // read, and a scan walks every session on every
                    // turn end.
                    lastUserMessageAt: AgentSessionScanner.cachedLastUserMessageDate(
                        of: wire, size: wireSize, mtime: mtime,
                        read: { lastUserMessageDate(of: $0) }),
                    projectPath: cwd,
                    scheduledTaskName: taskName,
                    agentKey: "kimi"
                )
                if session.scheduledTaskName != nil { session.origin = .scheduled }
                session.titleIsFallback =
                    (indexed == nil && state.title == nil && derived == nil)
                session.isEmptyShell = emptyShell
                sessions.append(session)
            }
        }

        sessions.sort { $0.activityAt > $1.activityAt }
        if let limit, limit < sessions.count {
            return Array(sessions.prefix(limit))
        }
        return sessions
    }

    /// The working directory a whole bucket belongs to. Evidence order
    /// is state.json, then kimi's index, then a decode of the bucket
    /// name — cwd first, decode last, because the encoding is lossy and
    /// can only ever be a guess (CLAUDE.md → "Agent-session project
    /// paths"). Nil when nothing on disk answers.
    private static func bucketCwd(bucket: URL,
                                  states: [URL?],
                                  indexed: [URL?]) -> URL? {
        states.compactMap { $0 }.first
            ?? indexed.compactMap { $0 }.first
            ?? decodeWorkDirKey(bucket.lastPathComponent)
    }

    /// The same question for a bucket the caller has not already read —
    /// one state.json per session in it, which is what
    /// `discoverSession` can afford for the handful of candidates a
    /// single turn produces.
    private static func bucketCwd(of bucket: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: bucket, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return bucketCwd(bucket: bucket,
                         states: entries.map { readState(of: $0).cwd },
                         indexed: [])
    }

    /// Every session id currently on disk. Snapshotted before a draft's
    /// first send so `discoverSession` can tell the session kimi is
    /// about to create from the ones that were already there — see
    /// `AgentRunner.startKimiSessionDiscovery`.
    static func sessionIds() -> Set<String> {
        let fm = FileManager.default
        guard storeExists,
              let buckets = try? fm.contentsOfDirectory(
                at: sessionRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else { return [] }
        var out: Set<String> = []
        for bucket in buckets {
            guard let entries = try? fm.contentsOfDirectory(
                at: bucket,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { continue }
            for dir in entries where !dir.lastPathComponent.hasPrefix(".") {
                out.insert(dir.lastPathComponent)
            }
        }
        return out
    }

    /// The session a just-spawned `kimi --prompt` run created — read off
    /// the store, because kimi names it on stdout only with the turn's
    /// FINAL answer (`session.resume_hint`, `KimiEventParser
    /// .announcedSessionId`), where claude and codex name theirs first
    /// (`system.init` / `thread.started`). Kimi will not take an id from
    /// the caller either: `--session` with a new id is refused as "not
    /// found".
    ///
    /// Four filters, and an answer only when ONE directory passes them
    /// all: the id is not one that existed before the spawn (`known`); the
    /// directory is younger than the send (`since`, with a few seconds of
    /// slack for clock and stat granularity); its working directory — its
    /// own, or its BUCKET's, since a bucket is a working directory — is
    /// ours or unknown; and its first user message is exactly the text
    /// this run sent (`prompt`). The last is what tells two runs in one
    /// folder apart — a scheduled run firing while the user starts a
    /// session there, a `kimi` started in a terminal at the same moment —
    /// where "the newest new directory" handed both runs the same id and
    /// bound one to the other's conversation.
    ///
    /// A new directory in this folder whose first message has not landed
    /// yet (it follows the directory by a tenth of a second) is UNDECIDED,
    /// and while one exists the answer is nil — never "the one that has
    /// landed": two runs sending the same words land their messages tens
    /// of milliseconds apart, and a poll between the two would find one
    /// match and hand BOTH runners that session. The caller asks again.
    /// Two that both hold the sent text cannot be told apart from here,
    /// so there is no guess either: the run's own announcement names it
    /// at the turn's end.
    static func discoverSession(cwd: URL,
                                excluding known: Set<String>,
                                since: Date,
                                prompt: String) -> (id: String, fileURL: URL)? {
        let fm = FileManager.default
        guard storeExists,
              let buckets = try? fm.contentsOfDirectory(
                at: sessionRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else { return nil }
        let cutoff = since.addingTimeInterval(-5)
        let wanted = cwd.standardizedFileURL.path
        let sent = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sent.isEmpty else { return nil }
        var matches: [(id: String, url: URL)] = []
        var undecided = false

        for bucket in buckets {
            guard let entries = try? fm.contentsOfDirectory(
                at: bucket,
                includingPropertiesForKeys: [.creationDateKey,
                                             .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            // Read once per bucket, not once per candidate.
            var resolvedBucketCwd: URL?? = nil
            for dir in entries {
                let id = dir.lastPathComponent
                guard !id.hasPrefix("."), !known.contains(id) else { continue }
                let values = try? dir.resourceValues(
                    forKeys: [.creationDateKey, .contentModificationDateKey])
                let born = values?.creationDate
                    ?? values?.contentModificationDate
                    ?? .distantPast
                guard born >= cutoff else { continue }
                if resolvedBucketCwd == nil {
                    resolvedBucketCwd = .some(bucketCwd(of: bucket))
                }
                let recorded = readState(of: dir).cwd
                    ?? (resolvedBucketCwd ?? nil)
                if let recorded,
                   recorded.standardizedFileURL.path != wanted {
                    continue
                }
                guard let first = readFirstUserMessage(of: wireFile(inSessionDir: dir)) else {
                    undecided = true
                    continue
                }
                if first == sent { matches.append((id, dir)) }
            }
        }
        guard !undecided, matches.count == 1, let found = matches.first else { return nil }
        return (found.id, wireFile(inSessionDir: found.url))
    }

    // MARK: - state.json

    /// Title / cwd / creation time out of a session's `state.json`.
    ///
    /// The docs say the file "contains session metadata including title
    /// and creation timestamp" and name no keys, so each value is
    /// looked up under several plausible spellings and a missing one
    /// simply stays nil. Tolerance rather than a guessed schema: a nil
    /// here costs a nicer title or a folder group, never the session.
    private static func readState(of dir: URL)
    -> (title: String?, cwd: URL?, createdAt: Date?) {
        let url = dir.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any]
        else { return (nil, nil, nil) }
        // Some writers nest the interesting half under a wrapper key.
        var obj = root
        for key in ["session", "meta", "metadata", "state"] {
            if let nested = root[key] as? [String: Any] {
                obj = nested.merging(root) { nestedValue, _ in nestedValue }
                break
            }
        }
        func string(_ keys: [String]) -> String? {
            for key in keys {
                if let value = obj[key] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return nil
        }
        let title = string(["title", "name", "summary", "sessionTitle"])
        let cwdPath = string(["cwd", "workDir", "work_dir", "workingDirectory",
                              "working_directory", "directory", "root",
                              "projectPath", "project_path"])
        let cwd = cwdPath.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath,
                isDirectory: true)
        }
        var created: Date? = nil
        for key in ["createdAt", "created_at", "created", "startedAt",
                    "started_at", "timestamp"] {
            if let value = obj[key], let date = flexibleDate(value) {
                created = date
                break
            }
        }
        return (title, cwd, created)
    }

    /// `{session_id: (title, cwd)}` from kimi's own index, when it has
    /// one. Later lines win, matching how an append-only index records
    /// updates — the same contract as codex's `session_index.jsonl`.
    /// Every key is looked up under a couple of spellings, for the same
    /// reason `readState` does.
    private static func indexEntries() -> [String: (title: String?, cwd: URL?)] {
        // Lossy decode: this index is appended to live, and a strict
        // decode of a snapshot that ends mid-character would drop
        // EVERY entry in the read, not just the torn line.
        guard let data = try? Data(contentsOf: sessionIndex) else { return [:] }
        var out: [String: (title: String?, cwd: URL?)] = [:]
        String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData))
                    as? [String: Any] else { return }
            guard let id = (obj["id"] as? String)
                    ?? (obj["sessionId"] as? String)
                    ?? (obj["session_id"] as? String),
                  !id.isEmpty else { return }
            let name = ((obj["title"] as? String)
                        ?? (obj["name"] as? String)
                        ?? (obj["thread_name"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let path = ((obj["cwd"] as? String)
                        ?? (obj["workDir"] as? String)
                        ?? (obj["work_dir"] as? String)
                        ?? (obj["workingDirectory"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cwd = (path?.isEmpty == false)
                ? URL(fileURLWithPath: (path! as NSString).expandingTildeInPath,
                      isDirectory: true)
                : nil
            // A later line updating only one field must not blank the
            // other — merge rather than overwrite.
            let existing = out[id]
            out[id] = (title: (name?.isEmpty == false ? name : nil)
                              ?? existing?.title,
                       cwd: cwd ?? existing?.cwd)
        }
        return out
    }

    /// Last-resort decode of the `<workDirKey>` bucket name.
    ///
    /// The encoding is undocumented, so this only attempts the one
    /// shape it can VERIFY: a claude-style dash-encoded absolute path,
    /// accepted only when the walk lands on a directory that actually
    /// exists. A hash — the other likely encoding — matches nothing on
    /// disk and correctly yields nil, leaving the session ungrouped
    /// rather than filed under an invented folder.
    private static func decodeWorkDirKey(_ key: String) -> URL? {
        guard key.contains("-") || key.hasPrefix("/") else { return nil }
        if key.hasPrefix("/") {
            let url = URL(fileURLWithPath: key, isDirectory: true)
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path,
                                                  isDirectory: &isDir)
                && isDir.boolValue ? url : nil
        }
        guard let resolved = AgentSessionScanner
            .resolveClaudeProjectPath(encoded: key) else { return nil }
        // `resolveClaudeProjectPath` falls back to a naive dash→slash
        // split that need not exist; only an on-disk hit is evidence.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path,
                                             isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return resolved
    }

    // MARK: - Titles

    private static func derivedTitle(from text: String) -> String? {
        let body = AgentSessionScanner.cleanUserText(text)
        let collapsed = body
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 50
            ? String(collapsed.prefix(47)) + "..."
            : collapsed
    }

    private static func neutralTitle(for cwd: URL?) -> String {
        if let folder = cwd?.lastPathComponent, !folder.isEmpty,
           folder != FileManager.default
               .homeDirectoryForCurrentUser.lastPathComponent {
            return "\(folder) session"
        }
        return String(localized: "New Kimi session",
                      comment: "Fallback title for a Kimi session with no name")
    }

    // MARK: - Wire records

    /// One decoded wire record, reduced to the chat message inside it.
    private struct WireMessage {
        let role: String
        let text: String
        let toolCalls: [(id: String, name: String, input: [String: Any])]
        let toolCallId: String?
        let isError: Bool
        let timestamp: Date?
        /// The message's own id (`message.id`, a `msg_…` ulid on a
        /// user record) — the `promptId` the turn's `turn.prompt` and
        /// `prompt.completed` records carry, and therefore the handle a
        /// user row keeps into the wire (`AgentSessionHistoryItem
        /// .recordUuid`). Nil on the agent's half, which is loop events.
        let id: String?
    }

    /// Records that are not conversation and must never be replayed.
    ///
    /// The docs say `wire.jsonl` "also carries a request trace — the
    /// tool schemas, request parameters, and MCP tool listings sent to
    /// the model". A request trace embeds the WHOLE conversation as it
    /// was sent, so rendering one would print every earlier message
    /// again, once per turn, growing quadratically down the transcript.
    /// Anything carrying a `messages` array or a `tools` list is that
    /// record, not a message.
    ///
    /// Presence goes through `KimiEventParser.present`, never a bare
    /// `!= nil`: `JSONSerialization` reports JSON null as `NSNull`, so
    /// a record that spells `"tools": null` would otherwise be
    /// classified as a trace and its message silently dropped.
    private static func isRequestTrace(_ obj: [String: Any]) -> Bool {
        if KimiEventParser.present(obj, "messages") != nil
            || KimiEventParser.present(obj, "tools") != nil { return true }
        if let type = obj["type"] as? String {
            let lowered = type.lowercased()
            if lowered.contains("request") || lowered.contains("trace") {
                return true
            }
        }
        return false
    }

    /// Pull the chat message out of one wire line, whatever it is
    /// wrapped in. Returns nil for bookkeeping records.
    ///
    /// Kimi's PRINT-MODE stdout is bare `{"role":…,"content":…}`
    /// objects; the wire file records the user's turns as
    /// `context.append_message` envelopes and the agent's half as loop
    /// events (`loopEventMessage`). The reader stays defensive about
    /// record shapes it does not recognise — the envelope keys tried
    /// here are the conventional ones, and anything else is skipped
    /// rather than guessed at.
    private static func message(from obj: [String: Any]) -> WireMessage? {
        guard !isRequestTrace(obj) else { return nil }
        // The wire file is NOT a stream of chat messages the way
        // print-mode stdout is. Only the USER's turns arrive as one —
        // `context.append_message` with a nested `message` the generic
        // unwrap below already finds. Everything the AGENT does arrives
        // as a loop EVENT with no `role` anywhere in it, so a generic
        // role-unwrap returns nil for every one of them — which is why
        // `loopEventMessage` is consulted first.
        if let loop = loopEventMessage(obj) { return loop }
        var body = obj
        if body["role"] as? String == nil {
            for key in ["message", "payload", "data", "event", "item"] {
                if let nested = body[key] as? [String: Any],
                   nested["role"] as? String != nil {
                    body = nested
                    break
                }
            }
        }
        guard let role = body["role"] as? String, !role.isEmpty else {
            return nil
        }
        let text = KimiEventParser.contentText(body["content"])
        if role == "user", isInjectedContext(text) { return nil }
        var calls: [(id: String, name: String, input: [String: Any])] = []
        if let raw = body["tool_calls"] as? [Any] {
            calls = KimiEventParser.toolCalls(from: raw)
        }
        var timestamp: Date? = nil
        for key in ["timestamp", "ts", "time", "created_at", "createdAt"] {
            if let found = flexibleDate(KimiEventParser.present(obj, key))
                ?? flexibleDate(KimiEventParser.present(body, key)) {
                timestamp = found
                break
            }
        }
        let messageId = (body["id"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        return WireMessage(
            role: role,
            text: text,
            toolCalls: calls,
            toolCallId: (body["tool_call_id"] as? String)
                ?? (body["toolCallId"] as? String),
            isError: (body["is_error"] as? Bool)
                ?? (KimiEventParser.present(body, "error") != nil),
            timestamp: timestamp,
            id: messageId)
    }

    /// How full the context window is on the newest API call, for the
    /// composer's context chip — the kimi counterpart of
    /// `CodexSessionScanner.lastContextTokens`.
    ///
    /// The wire carries one `usage.record` per STEP, i.e. per LLM call
    /// (its `usageScope` says "turn", but a session's records match its
    /// `step.end`s one for one). The `usage` object splits the input
    /// into `inputOther`, `inputCacheRead` and `inputCacheCreation`,
    /// which SUM to the input side of that call — reading `inputOther`
    /// alone would under-report by the whole cached prefix.
    ///
    /// `output` is deliberately NOT added: kimi's own status bar
    /// divides the input side by the model's window, as claude's
    /// indicator does, and this chip must agree with the terminal the
    /// user can put beside it.
    ///
    /// `usageScope` is REQUIRED to be `turn`. A block summed across a
    /// whole session or turn's worth of API calls overcounts the real
    /// context by the number of calls, so a record scoped to anything
    /// else is not a context footprint and is skipped rather than
    /// added in.
    ///
    /// Newest record wins even when it DROPS — a compaction genuinely
    /// lowers the footprint, and the smaller number is the honest one.
    static func lastContextTokens(of wire: URL) -> Int {
        lastContextUsage(of: wire).tokens
    }

    /// The footprint PLUS the model that produced it. The record's
    /// `model` string IS the config alias (measured:
    /// `"model":"moonshot-ai/kimi-k3"` against
    /// `[models."moonshot-ai/kimi-k3"]` in the same install's
    /// config.toml), which is what lets the occupancy tooltip divide by
    /// that entry's `max_context_size` instead of a constant — kimi
    /// windows on this machine run from 262,144 to 1,048,576 where the
    /// constant says 200,000. The join itself lives at the caller
    /// (`KimiCatalog.maxContextSize(forModel:)`): this scan runs off
    /// the main actor and the catalog is MainActor state.
    static func lastContextUsage(of wire: URL) -> (tokens: Int, model: String?) {
        // Escalating bounded tail, same shape as `lastUserMessageDate`:
        // the newest usage record sits near the end, and only a file
        // that comes up empty pays for the wider read.
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: wire.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        for budget in [256 * 1024, 4 * 1024 * 1024] {
            if let found = usageScan(of: wire, budget: budget),
               found.tokens > 0 {
                return found
            }
            if let size, size <= UInt64(budget) { break }
        }
        return (0, nil)
    }

    private static func usageScan(of wire: URL,
                                  budget: Int) -> (tokens: Int, model: String?)? {
        guard let text = AgentSessionScanner.boundedTail(
            of: wire, budget: budget) else { return nil }
        var newest: (tokens: Int, model: String?)? = nil
        text.enumerateLines { line, _ in
            guard let data = line.trimmingCharacters(in: .whitespaces)
                    .data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  (obj["type"] as? String) == "usage.record",
                  (obj["usageScope"] as? String) == "turn",
                  let usage = obj["usage"] as? [String: Any]
            else { return }
            let total = ["inputOther", "inputCacheRead",
                         "inputCacheCreation"]
                .reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
            // Model rides the winning record, like the codex window:
            // a mid-session model switch moves footprint and window
            // together or not at all.
            if total > 0 { newest = (total, obj["model"] as? String) }
        }
        return newest
    }

    /// Bookkeeping kimi appends to the conversation AS THE USER.
    ///
    /// Every turn writes a second `context.append_message` with
    /// `role: "user"` holding `<system-reminder>\nAuto permission
    /// mode is active…`. Left in, it renders as a user bubble under
    /// every prompt, and — worse than noise — it is a candidate for
    /// the DERIVED TITLE and for `lastUserMessageDate`, which is the
    /// value the sidebar prints and sorts on. Filtered here, in
    /// `message(from:)`, so the transcript, the title and the
    /// timestamp all agree; the codex scanner solves the same problem
    /// the same way (`contextPrefixes` / `isContextText`).
    private static func isInjectedContext(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<system-reminder>")
    }

    /// The agent's half of the conversation, which kimi records as
    /// `context.append_loop_event` envelopes rather than as messages.
    ///
    /// The three event shapes:
    ///
    ///   {"type":"context.append_loop_event","time":…,
    ///    "event":{"type":"content.part","part":{"type":"text",
    ///                                           "text":"PROBE"}}}
    ///   {"type":"context.append_loop_event",
    ///    "event":{"type":"tool.call","toolCallId":"Write_0",
    ///             "name":"Write","args":{…}}}
    ///   {"type":"context.append_loop_event",
    ///    "event":{"type":"tool.result","toolCallId":"Write_0",
    ///             "result":{"output":"Wrote 5 bytes to probe.txt"}}}
    ///
    /// `step.begin` / `step.end` are bookkeeping and fall out of the
    /// switch. So does `part.type == "think"`, which is the model's
    /// reasoning: it is not an assistant TURN, and rendering it as one
    /// would put the deliberation and the answer on screen as two equal
    /// replies. A Chat only turn draws it inside the turn's activity
    /// line instead, read through `thought(_:)`.
    private static func loopEventMessage(_ obj: [String: Any])
    -> WireMessage? {
        guard (obj["type"] as? String) == "context.append_loop_event",
              let event = obj["event"] as? [String: Any],
              let kind = event["type"] as? String
        else { return nil }
        // The stamp is on the ENVELOPE, not the event.
        let stamp = flexibleDate(KimiEventParser.present(obj, "time"))

        switch kind {
        case "content.part":
            guard let part = event["part"] as? [String: Any],
                  (part["type"] as? String) == "text",
                  let text = part["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return WireMessage(role: "assistant", text: text, toolCalls: [],
                               toolCallId: nil, isError: false,
                               timestamp: stamp, id: nil)

        case "tool.call":
            guard let id = event["toolCallId"] as? String, !id.isEmpty,
                  let name = event["name"] as? String, !name.isEmpty
            else { return nil }
            return WireMessage(
                role: "assistant", text: "",
                toolCalls: [(id: id, name: name,
                             input: (event["args"] as? [String: Any]) ?? [:])],
                toolCallId: nil, isError: false, timestamp: stamp, id: nil)

        case "tool.result":
            guard let id = event["toolCallId"] as? String, !id.isEmpty
            else { return nil }
            let result = event["result"] as? [String: Any]
            // `output` is what a successful Write reports. The other
            // spellings are defensive fallbacks — a tool whose result
            // we cannot read renders as an empty row, never as a
            // missing one, because the row is what pairs with the call.
            let output = (result?["output"] as? String)
                ?? KimiEventParser.contentText(result?["content"])
            let failed = (result?["isError"] as? Bool)
                ?? (result?["is_error"] as? Bool)
                ?? (KimiEventParser.present(result ?? [:], "error") != nil)
            return WireMessage(role: "tool", text: output, toolCalls: [],
                               toolCallId: id, isError: failed,
                               timestamp: stamp, id: nil)

        default:
            return nil
        }
    }

    /// First real user message in a session, for title + scheduled-task
    /// derivation. Reads a bounded HEAD — the opening message is at the
    /// start of the file by definition.
    private static func readFirstUserMessage(of wire: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: wire) else {
            return nil
        }
        defer { try? handle.close() }
        // Generous, because a wire file opens with request-trace
        // records that carry whole tool schemas.
        let head = handle.readData(ofLength: 512 * 1024)
        for line in String(decoding: head, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.trimmingCharacters(in: .whitespaces)
                    .data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  let msg = message(from: obj), msg.role == "user"
            else { continue }
            let text = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            return text
        }
        return nil
    }

    /// Timestamp of the newest real user message — the value the
    /// sidebar prints and sorts on (`AgentSession.activityAt`).
    ///
    /// Returns nil when the wire records carry no timestamp we
    /// recognise, and nil is the honest answer: `activityAt` then falls
    /// back to the file's mtime. That fallback is worse than a real
    /// stamp (see CLAUDE.md → "Sidebar rows are timed by the last USER
    /// message"), but inventing one would be worse still.
    static func lastUserMessageDate(of wire: URL) -> Date? {
        // Escalating window, same as both other scanners: one
        // tool-heavy turn can push the turn's opening record well past
        // a small tail, and only a file that comes up empty pays for
        // the wider read.
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: wire.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        for budget in [256 * 1024, 4 * 1024 * 1024] {
            if let found = userMessageScan(of: wire, budget: budget) {
                return found
            }
            if let size, size <= UInt64(budget) { break }
        }
        return nil
    }

    private static func userMessageScan(of wire: URL, budget: Int) -> Date? {
        guard let text = AgentSessionScanner.boundedTail(of: wire,
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
                  let msg = message(from: obj), msg.role == "user",
                  !msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                      .isEmpty,
                  let stamp = msg.timestamp
            else { continue }
            return stamp
        }
        return nil
    }

    /// ISO-8601 (both fractional shapes) or a numeric epoch in seconds
    /// or milliseconds. Which of those kimi writes is not documented,
    /// so all three are accepted; the millisecond cut-off is the year
    /// 2001 in seconds, far below any plausible session date.
    private static func flexibleDate(_ value: Any?) -> Date? {
        if let date = AgentSessionScanner.isoDate(value) { return date }
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        guard raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 1_000_000_000_000
                    ? raw / 1000 : raw)
    }

    // MARK: - Turn markers

    /// The records that open and close a turn in a wire file, read in
    /// ONE place: the history reader stamps user rows with the prompt
    /// id, the fork cuts on it, and a live watcher of an external turn
    /// would flip on these. Two spellings of this vocabulary is how
    /// those drift.
    ///
    /// A turn opens with `turn.prompt {promptId}`, immediately followed
    /// by the `context.append_message` whose `message.id` IS that
    /// prompt id; it closes with `turn.ended {turnId, reason}` and then
    /// `prompt.completed {promptId}`. No record carries the session id
    /// — only `agentId` — which is what lets a copied prefix stand as a
    /// new session without a rewrite.
    static func turnPromptId(_ obj: [String: Any]) -> String? {
        guard (obj["type"] as? String) == "turn.prompt",
              let id = obj["promptId"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    static func promptCompletedId(_ obj: [String: Any]) -> String? {
        guard (obj["type"] as? String) == "prompt.completed",
              let id = obj["promptId"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    static func turnEnded(_ obj: [String: Any]) -> Bool {
        (obj["type"] as? String) == "turn.ended"
    }

    /// The newest turn the wire's tail records (see `RecordedTurn`),
    /// through the markers above: open after a `turn.prompt` with no
    /// `turn.ended` (or `prompt.completed`) behind it — including the
    /// turn a finished background task opens with a prompt of its own.
    /// Its start is the prompt record's `time`, its length kimi's own
    /// `durationMs`. Nil when the tail holds no marker.
    ///
    /// Only lines naming a marker are parsed, for the reason the codex
    /// reader gives.
    static func latestTurn(of wire: URL, budget: Int = 1024 * 1024) -> RecordedTurn? {
        // Escalating window, for the reason the codex reader gives.
        let size = ((try? FileManager.default.attributesOfItem(atPath: wire.path))?[.size]
                    as? NSNumber)?.uint64Value
        let wide = 8 * 1024 * 1024
        for window in (budget < wide ? [budget, wide] : [budget]) {
            if let found = latestTurnScan(of: wire, budget: window) { return found }
            if let size, size <= UInt64(window) { break }
        }
        return nil
    }

    private static func latestTurnScan(of wire: URL, budget: Int) -> RecordedTurn? {
        guard let text = AgentSessionScanner.boundedTail(of: wire, budget: budget)
        else { return nil }
        var latest: RecordedTurn? = nil
        text.enumerateLines { line, _ in
            guard line.contains("turn.prompt") || line.contains("turn.ended")
                    || line.contains("prompt.completed"),
                  let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any]
            else { return }
            if turnPromptId(obj) != nil {
                latest = RecordedTurn(open: true, startedAt: flexibleDate(obj["time"]),
                                      seconds: nil)
            } else if turnEnded(obj) || promptCompletedId(obj) != nil {
                var turn = latest ?? RecordedTurn(open: false, startedAt: nil, seconds: nil)
                turn.open = false
                if let ms = (obj["durationMs"] as? NSNumber)?.doubleValue, ms > 0 {
                    turn.seconds = ms / 1000
                }
                latest = turn
            }
        }
        return latest
    }

    /// The user message a `context.append_message` record carries —
    /// its id and its cleaned text — or nil for every other record,
    /// including the bookkeeping kimi appends AS the user, which
    /// `message(from:)` already refuses.
    static func userMessage(_ obj: [String: Any]) -> (id: String?, text: String)? {
        guard (obj["type"] as? String) == "context.append_message",
              let msg = message(from: obj), msg.role == "user"
        else { return nil }
        return (msg.id, AgentSessionScanner.cleanUserText(msg.text))
    }

    /// The text of a `think` part — the model's reasoning for one step,
    /// which kimi records on the wire and never prints on stdout — or
    /// nil for every other record and for a thought with no text.
    ///
    ///   {"type":"context.append_loop_event",
    ///    "event":{"type":"content.part",
    ///             "part":{"type":"think","think":"…"}}}
    static func thought(_ obj: [String: Any]) -> String? {
        guard (obj["type"] as? String) == "context.append_loop_event",
              let event = obj["event"] as? [String: Any],
              (event["type"] as? String) == "content.part",
              let part = event["part"] as? [String: Any],
              (part["type"] as? String) == "think",
              let text = (part["think"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    /// One row of a live kimi turn, as far as placing its thoughts goes.
    enum LiveRow: Equatable {
        case toolUse(id: String)
        case toolResult
        case text(String)
        case thought
        /// Anything else — an error, an interrupted marker.
        case other
    }

    /// Where a kimi Chat only turn's thoughts go among the rows its
    /// stdout produced — kimi prints none of them, and its wire records
    /// each one before the step it led to.
    ///
    /// `wireItems` is the wire read with thoughts, and only the records
    /// after its LAST user message count — the turn's own. A tail
    /// holding a single user message comes back whole, the end of the
    /// turn before it included, and a thought from there would shift
    /// every placement after it; a tail with no user message at all
    /// opened inside the turn, where thoughts cannot be counted from the
    /// start, so none are placed (the reopened transcript has them).
    /// `turnRows` are the live rows after the user's message.
    ///
    /// Each thought is anchored to the row that followed it on the wire —
    /// the tool call with the same id, or the answer text — and placed
    /// BEFORE that row. Placed strictly in order, starting after the
    /// `alreadyPlaced` first: a thought whose row has not reached stdout
    /// yet stops the walk until a later read. Only a `final` read places
    /// the leftovers (a step cut off by Stop), after the turn's last
    /// step or word, ahead of an error or interrupted row. A new anchor
    /// is looked for AFTER the previous one, so a sentence the turn says
    /// twice anchors each thought to its own saying.
    ///
    /// Returns insertion positions in order, each an index into
    /// `turnRows` as it stands after the placements before it.
    static func thoughtPlacements(wireItems: [AgentSessionHistoryItem],
                                  turnRows: [LiveRow],
                                  alreadyPlaced: Int,
                                  final: Bool) -> [(text: String, at: Int)] {
        // `item` tells two sayings of the same words apart.
        enum Anchor: Equatable { case tool(String), text(String, item: Int), none }
        guard let opened = wireItems.lastIndex(where: { item in
            if case .userText = item.kind { return !item.isSystemNotice }
            return false
        }) else { return [] }
        var thoughts: [(text: String, anchor: Anchor)] = []
        var waiting: [String] = []
        for index in wireItems.indices where index > opened {
            switch wireItems[index].kind {
            case .thinking(let text):
                waiting.append(text)
            case .toolUse(let id, _, _):
                thoughts += waiting.map { ($0, .tool(id)) }
                waiting = []
            case .assistantText(let text):
                thoughts += waiting.map { ($0, .text(text, item: index)) }
                waiting = []
            default:
                break
            }
        }
        thoughts += waiting.map { ($0, .none) }
        guard alreadyPlaced < thoughts.count else { return [] }

        func trimmed(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Contained, not equal: one stdout message can carry what the
        // wire split into several text parts.
        func says(_ row: LiveRow, _ text: String) -> Bool {
            if case .text(let shown) = row { return trimmed(shown).contains(trimmed(text)) }
            return false
        }
        var rows = turnRows
        // Rows before `from` belong to steps already placed.
        var from = 0
        if alreadyPlaced > 0 {
            var seen = 0
            for (i, row) in rows.enumerated() where row == .thought {
                seen += 1
                if seen == alreadyPlaced { from = i + 1; break }
            }
        }
        // The previous thought's anchor and where its row is now.
        var previous: (anchor: Anchor, row: Int)? = nil
        var placements: [(text: String, at: Int)] = []
        for thought in thoughts.dropFirst(alreadyPlaced) {
            var at: Int?
            if let previous, thought.anchor != .none, previous.anchor == thought.anchor {
                // Two thoughts before one step: both go before it, in order.
                at = previous.row
            } else {
                switch thought.anchor {
                case .tool(let id):
                    at = rows[from...].firstIndex(of: .toolUse(id: id))
                case .text(let text, _):
                    at = rows[from...].firstIndex { says($0, text) }
                    // Or the previous anchor's own message, carrying a
                    // later part of it: these words must follow those.
                    if at == nil, let previous,
                       case .text(let before, _) = previous.anchor,
                       case .text(let shown) = rows[previous.row],
                       let range = trimmed(shown).range(of: trimmed(before)),
                       trimmed(shown)[range.upperBound...].contains(trimmed(text)) {
                        at = previous.row
                    }
                case .none:
                    at = final
                        ? max(from, rows.lastIndex { $0 != .other }.map { $0 + 1 } ?? 0)
                        : nil
                }
            }
            guard let at else { break }
            rows.insert(.thought, at: at)
            placements.append((thought.text, at))
            // Its anchor row is one further down now; a new anchor is
            // looked for after it.
            previous = (thought.anchor, at + 1)
            from = thought.anchor == .none ? at + 1 : at + 2
        }
        return placements
    }

    /// True for a record that is the AGENT speaking or acting — a loop
    /// event carrying a text part or a tool call. What a prefix must
    /// hold, beside a user message, to count as a conversation.
    static func isAgentOutput(_ obj: [String: Any]) -> Bool {
        guard let msg = loopEventMessage(obj) else { return false }
        return msg.role == "assistant"
    }

    // MARK: - History

    /// One wire record at a time into history rows.
    ///
    /// A struct rather than a function over the whole file so the
    /// same decoder can be fed a prefix and then a tail — and, later,
    /// the lines a live watcher of an external turn appends. It
    /// remembers the prompt the turn it is inside was opened with,
    /// which is the only turn state the wire carries.
    struct WireDecoder {
        private(set) var currentPromptId: String? = nil
        /// Keep `think` parts as `.thinking` rows (see `readHistory`).
        /// Off, a thought reads as nothing — see `loopEventMessage`.
        var includeThinking = false

        init(includeThinking: Bool = false) {
            self.includeThinking = includeThinking
        }

        mutating func items(forLine line: String) -> [AgentSessionHistoryItem] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any]
            else { return [] }

            if let prompt = KimiSessionScanner.turnPromptId(obj) {
                currentPromptId = prompt
                return []
            }

            if includeThinking, let thought = KimiSessionScanner.thought(obj) {
                return [AgentSessionHistoryItem(kind: .thinking(thought))]
            }

            // The agent summarised the conversation and carried on.
            // Checked before `message(from:)`, which reports nil for
            // this record — the row and its summary would otherwise be
            // dropped, leaving the context chip's fall unexplained.
            //
            // Kimi keeps the summary INSIDE the record rather than
            // writing it as a separate user turn, so nothing here can
            // be mistaken for the user's own words; it is labelled a
            // system notice for the same reason claude's flagged
            // record is.
            if (obj["type"] as? String) == "context.apply_compaction" {
                func positive(_ v: Any?) -> Int? {
                    guard let n = (v as? NSNumber)?.intValue, n > 0
                    else { return nil }
                    return n
                }
                var out = [AgentSessionHistoryItem(
                    kind: .compaction(preTokens: positive(obj["tokensBefore"]),
                                      postTokens: positive(obj["tokensAfter"])))]
                if let summary = (obj["summary"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !summary.isEmpty {
                    out.append(AgentSessionHistoryItem(
                        kind: .userText(summary), isSystemNotice: true))
                }
                return out
            }

            guard let msg = KimiSessionScanner.message(from: obj) else {
                return []
            }

            switch msg.role {
            case "user":
                // Show the prompt, not the bookkeeping tag that filed
                // it under its task — same as both other readers. The
                // row's handle is the record's own message id, with
                // the turn's prompt id as the fallback for a writer
                // that omits one.
                let body = AgentSessionScanner.cleanUserText(msg.text)
                // Inlined attachments: the names come off the raw text,
                // before the strip inside `cleanUserText`.
                let attached = AttachmentInline.names(in: msg.text)
                guard !body.isEmpty || !attached.isEmpty else { return [] }
                var item = AgentSessionHistoryItem(
                    kind: .userText(body),
                    recordUuid: msg.id ?? currentPromptId)
                item.attachedFiles = attached
                return [item]

            case "assistant":
                var out: [AgentSessionHistoryItem] = []
                let body = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    out.append(AgentSessionHistoryItem(
                        kind: .assistantText(body)))
                }
                for call in msg.toolCalls {
                    out.append(AgentSessionHistoryItem(kind: .toolUse(
                        id: call.id, name: call.name, input: call.input)))
                }
                return out

            case "tool":
                guard let id = msg.toolCallId else { return [] }
                return [AgentSessionHistoryItem(kind: .toolResult(
                    toolUseId: id, content: msg.text, isError: msg.isError))]

            default:
                // `system` / `developer` records are the prompt kimi was
                // primed with, not conversation.
                return []
            }
        }
    }

    /// Walk a session's wire file and emit history items in
    /// chronological order.
    ///
    /// `includeThinking` keeps each step's `think` part as a `.thinking`
    /// row, for a session with Chat only turns in it (the caller then
    /// applies `AgentSessionHistoryItem.keepingThoughts`) and for the
    /// runner's own Chat only turn, whose thoughts reach it no other way.
    static func readHistory(of wire: URL, maxTurns: Int = 50,
                            byteBudget: Int? = nil,
                            includeThinking: Bool = false)
    -> [AgentSessionHistoryItem] {
        // Same contract as both other readers: bounded tail + lossy
        // decode, so a live file mid-write can lose at most one edge
        // line — never the whole transcript — and an oversized one
        // can't freeze the open. `byteBudget` widens the tail for
        // whole-conversation callers (search); it never removes the
        // bound.
        guard let text = AgentSessionScanner.boundedTail(
            of: wire, budget: byteBudget ?? (8 * 1024 * 1024))
        else { return [] }

        var decoder = WireDecoder(includeThinking: includeThinking)
        var items: [AgentSessionHistoryItem] = []
        text.enumerateLines { line, _ in
            items.append(contentsOf: decoder.items(forLine: line))
        }

        // Same turn-based cap as the other two readers.
        let userIndices = items.enumerated().compactMap { i, it -> Int? in
            if case .userText = it.kind { return i }
            return nil
        }
        if userIndices.count <= maxTurns { return items }
        let startIdx = userIndices[userIndices.count - maxTurns]
        return Array(items[startIdx...])
    }
}
