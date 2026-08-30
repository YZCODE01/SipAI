// AgentSession.swift
// Data model + parser for Claude Code agent sessions.
//
// Scanning walks ~/.claude/projects/*/*.jsonl. The history reader emits a
// flat, chronological stream of granular items — user text, assistant
// text, tool_use (with its full input dict), tool_result (with its full
// content body) — so the viewer can render past turns through the SAME
// renderers used for live stream-json events. The shared helpers in
// `AgentRendering.swift` (`fullToolBody`, `fullToolResultBody`, …) do
// the actual formatting; this file only extracts the raw payloads.

import Foundation

/// What kind of run produced a session. Drives the sidebar row icon:
/// a schedule-fired run gets the timer, a spawned subagent the
/// two-person glyph, and only a conversation the user drove gets the
/// speech bubble.
enum AgentSessionOrigin: Hashable {
    case user
    /// Fired by a schedule: a Claude scheduled task's run, or a codex
    /// cron automation.
    case scheduled
    /// Spawned as a child thread by another session (codex multi-agent).
    case subagent
}

/// One discovered session file under `~/.claude/projects`.
struct AgentSession: Identifiable, Hashable {
    /// The session UUID — the JSONL filename with `.jsonl` stripped.
    let id: String
    /// Absolute path to the `.jsonl` on disk.
    let fileURL: URL
    /// Extracted from the first user message (tags stripped, whitespace
    /// collapsed, truncated to 50 chars). Falls back to the session id.
    let title: String
    /// File modification timestamp — the last time ANYTHING was
    /// appended, which during a long turn means the agent's own tool
    /// output. Kept for staleness checks; it is NOT what the sidebar
    /// shows or sorts by (see `lastUserMessageAt`).
    let modifiedAt: Date
    /// When the newest real user message was sent into this session:
    /// the timestamp on the last turn-opening user record, tool
    /// results and claude's own bookkeeping excluded. This is what the
    /// sidebar shows and orders rows by, because it answers the
    /// question a reader actually asks of that column — "when did I
    /// last talk to this?" — where mtime answers "when did the agent
    /// last write a byte", and a session left working for an hour
    /// pins itself to the top of the list for the whole hour on that
    /// measure.
    ///
    /// Nil when no user turn was found in the scanned window (a
    /// transcript of pure bookkeeping, an unreadable file); callers go
    /// through `activityAt`, never this field raw, so the row falls
    /// back to mtime rather than to 1970.
    var lastUserMessageAt: Date? = nil
    /// Best-effort resolved filesystem path of the Claude project directory.
    /// May be nil if the encoded name couldn't be mapped back.
    let projectPath: URL?
    /// Name from the first user message's
    /// `<scheduled-task name="…">` marker. Nil for regular sessions.
    let scheduledTaskName: String?
    /// Which agent owns this session ("claude_code" / "codex" /
    /// "kimi"). Drives history parsing, sidebar sectioning, and the
    /// read-only tier.
    var agentKey: String = "claude_code"
    /// How this session came to exist; `.user` unless a scanner knows
    /// better.
    var origin: AgentSessionOrigin = .user
    /// True when `title` is the neutral "<folder> session" fallback —
    /// the transcript held no ai-title and no visible user text (e.g.
    /// the fresh file `/clear` forks, exited before any prompt). Lets
    /// the sidebar keep relabeling nested scheduled runs and marks the
    /// name as carrying no content.
    var titleIsFallback: Bool = false
    /// True when the WHOLE transcript fit in the inspect window and
    /// held no conversation at all — no visible user text, no
    /// assistant record, no tool activity. The residue of `/clear` +
    /// quit (or a launch abandoned before the first prompt). The
    /// sidebar hides these rows; the files stay on disk and the
    /// center pane can still open one by id.
    var isEmptyShell: Bool = false

    /// The one timestamp the UI may show or sort by. Every display and
    /// every comparison goes through here so the fallback is decided
    /// in ONE place — a list that sorts on one clock and prints
    /// another is the bug where the top row is visibly not the newest.
    var activityAt: Date { lastUserMessageAt ?? modifiedAt }
}

/// One scheduled Claude Code task definition plus all of its discovered runs.
/// Definitions live under `~/.claude/scheduled-tasks/<name>/SKILL.md`; each run
/// remains a normal `AgentSession`, so opening a child uses the existing
/// session viewer and resume flow.
struct ScheduledAgentTask: Identifiable, Hashable {
    let name: String
    let description: String
    let directoryURL: URL
    let skillFileURL: URL
    /// `cwd:` from the SKILL.md frontmatter — where the task actually runs,
    /// as opposed to `directoryURL`, which is where its definition lives.
    /// Nil when the frontmatter omits it. Read for folder grouping.
    let workingDirectory: URL?
    /// The task's discovered runs, newest-first on `activityAt`. `var`
    /// so a just-fired run can be stamped in place without rebuilding
    /// the task (`AgentManager.stampUserMessage`).
    var sessions: [AgentSession]
    /// `agent:` from the frontmatter; tasks predate multi-agent support,
    /// so absent means Claude Code.
    var agent: String = "claude_code"
    /// The full parsed SKILL.md — schedule, prompt, runtime settings.
    /// Nil only for an ORPHAN: a task whose runs exist but whose
    /// definition directory was deleted. The panel shows those
    /// read-only, since there is no file left to revise.
    var definition: ScheduledTaskDefinition? = nil

    var id: String { name }
    /// Same clock as a regular row: when this task last SENT a prompt,
    /// not when its newest run last wrote a byte. `sessions` is
    /// ordered newest-first on that same key by the scanner.
    var lastActive: Date? { sessions.first?.activityAt }

    /// `definition` IS part of equality. It is tempting to leave a whole
    /// prompt body out of a value that keys SwiftUI diffing, but this
    /// value is what feeds `ScheduledTaskPanel`, and SwiftUI skips
    /// re-running a child's body when its inputs compare equal —
    /// excluding `definition` would leave the panel displaying stale
    /// values after an edit that changes only the schedule, the
    /// prompt, or the mode. Tasks number in the handful, unlike
    /// sessions, so the comparison is free.
    ///
    /// `hash` stays keyed on the name alone: it is the stable identity,
    /// and hashing must agree with equality only in the one direction
    /// it does here (equal values hash equally).
    static func == (lhs: ScheduledAgentTask, rhs: ScheduledAgentTask) -> Bool {
        lhs.name == rhs.name
            && lhs.description == rhs.description
            && lhs.sessions == rhs.sessions
            && lhs.agent == rhs.agent
            && lhs.definition == rhs.definition
    }

    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

/// One item in a Claude Code session's replayed history. Ordered
/// chronologically by the scanner: every user message, assistant text
/// block, tool_use, and tool_result gets its own entry.
///
/// The payload `[String: Any]` inside `.toolUse` is not Hashable; that's
/// why `==` / `hash` key off `id` alone — same pattern as
/// `StreamEvent` in `AgentRunner.swift`, so SwiftUI's `ForEach` diffing
/// behaves identically across live and historical streams.
struct AgentSessionHistoryItem: Identifiable, Hashable {
    let id: UUID = UUID()
    let kind: Kind
    /// `uuid` of the JSONL record this item was parsed out of, when it
    /// had one. This is the row's handle back into the transcript, and
    /// it is what `AgentSessionFork` cuts a branch at.
    ///
    /// It has to be the record's uuid rather than a line number:
    /// `readHistory` parses a BOUNDED TAIL of the file, so an index into
    /// what it read is not an index into the file. Nil for items that
    /// have no record behind them — the derived `.interrupted` marker.
    var recordUuid: String? = nil

    /// True for a user-role record the harness injected rather than
    /// anything the user typed — see `AgentSessionScanner.isHarnessNotice`.
    var isSystemNotice: Bool = false

    enum Kind {
        case userText(String)
        case assistantText(String)
        case toolUse(id: String, name: String, input: [String: Any])
        case toolResult(toolUseId: String, content: String, isError: Bool)
        /// The turn above ended without finishing — kill/quit residue,
        /// derived at load time (`AgentSessionScanner.endsMidTurn` +
        /// no live writer), never stored in the JSONL itself.
        case interrupted(message: String)
    }

    static func == (lhs: AgentSessionHistoryItem, rhs: AgentSessionHistoryItem) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A nascent Claude Code session that hasn't been spawned yet.
/// Created by the sidebar's "New session" action and held on
/// `AppState`; the draft composer can change `cwd` until the first
/// send. After the first successful send the draft is converted into a
/// real `AgentSession` (the `session_id` and JSONL file URL are
/// discovered from the subprocess output) and AppState routing
/// transitions to `openAgentSessionId` + `openAgentSessionPath`.
struct ClaudeSessionDraft: Identifiable, Hashable {
    /// Stable identity for SwiftUI diffing while the draft exists.
    /// Has no relation to the eventual Claude `session_id`.
    let id: UUID
    /// Working directory the agent will run from. Required.
    var cwd: URL
    /// Optional user-provided display name persisted into config under
    /// `agent_session_names` once the real session_id is known.
    var name: String?
    /// Which CLI this draft will spawn — an `AgentManager.registry`
    /// key. The name is legacy — a draft is just as legitimately a
    /// codex thread waiting for its first send.
    var agentKey: String

    init(cwd: URL, name: String? = nil, agentKey: String = "claude_code") {
        self.id = UUID()
        self.cwd = cwd
        self.name = name
        self.agentKey = agentKey
    }
}

enum AgentSessionScanner {

    /// Root folder Claude Code writes sessions into.
    static let sessionRoot: URL = {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }()

    // MARK: - Last-user-message cache

    /// `lastUserMessageAt` costs a TAIL read per session, and a scan
    /// walks every session there is, and re-runs on every turn end. A
    /// transcript that has not been written since the last look cannot
    /// have gained a user message, so identity is (size, mtime) and a
    /// hit skips the read entirely — only the handful of files that
    /// actually changed are re-scanned.
    ///
    /// Keyed by path, so a session contributes one entry however many
    /// times it is scanned. Unbounded by design: the ceiling is the
    /// number of session files on disk, which is the same set the scan
    /// already walks.
    private struct TurnStartStamp {
        let size: UInt64
        let mtime: Date
        let date: Date?
    }
    private static var turnStartCache: [String: TurnStartStamp] = [:]
    /// Guards `turnStartCache`. Scans run on detached tasks and two can
    /// overlap (a turn ending while a manual refresh is in flight).
    private static let turnStartCacheLock = NSLock()

    /// Timestamp of the newest real user message in `url`, memoised
    /// against the file's own (size, mtime). `size` and `mtime` come
    /// from the caller's own stat — the scan has already paid for it.
    ///
    /// `read` is the per-format extractor (claude JSONL vs. codex
    /// rollout); the two never name the same path, so one cache serves
    /// both.
    static func cachedLastUserMessageDate(
        of url: URL,
        size: UInt64,
        mtime: Date,
        read: (URL) -> Date? = { lastTurnStartDate(of: $0) }
    ) -> Date? {
        let key = url.path
        turnStartCacheLock.lock()
        let hit = turnStartCache[key]
        turnStartCacheLock.unlock()
        if let hit, hit.size == size, hit.mtime == mtime {
            return hit.date
        }
        let found = read(url)
        turnStartCacheLock.lock()
        turnStartCache[key] = TurnStartStamp(size: size, mtime: mtime,
                                             date: found)
        turnStartCacheLock.unlock()
        return found
    }

    /// Optional run ledger written by a wrapper that fires scheduled
    /// runs from outside the app. Native Claude scheduled runs carry an
    /// XML marker in their first user message; this ledger is the
    /// fallback for wrapper-fired runs that only record a session id
    /// after completion. Absent on most installs, in which case the
    /// lookup is simply empty.
    private static let agentRunsFile: URL = {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".sipai/agent_runs.json")
    }()

    // MARK: - Scratch locations

    /// Temp roots a transcript can be rooted in. Anything run from one of
    /// these is scratch by construction — `claude -p` probes, one-off
    /// experiments, tool scaffolding — and the OS reclaims the directory
    /// anyway, so there is nothing to navigate back to. Listing them
    /// would put a folder group ("tmp") in the sidebar for work nobody
    /// did.
    ///
    /// Matched by LOCATION, never by size or turn count: a short session
    /// in a real project is still the user's, and a long one in `/tmp`
    /// still isn't.
    private static let scratchRoots: [String] = {
        var roots = ["/tmp", "/private/tmp",
                     "/var/tmp", "/private/var/tmp",
                     // Per-user temp: $TMPDIR is …/var/folders/xx/yyy/T/
                     "/var/folders", "/private/var/folders"]
        let tmpdir = URL(fileURLWithPath: NSTemporaryDirectory())
            .standardizedFileURL.path
        if !roots.contains(tmpdir) { roots.append(tmpdir) }
        return roots
    }()

    /// True when `url` sits inside a system temp root. Both the `/tmp`
    /// and `/private/tmp` spellings are listed rather than resolved, so
    /// this never touches the filesystem.
    static func isScratchLocation(_ url: URL?) -> Bool {
        guard let url else { return false }
        let path = url.standardizedFileURL.path
        return scratchRoots.contains {
            path == $0 || path.hasPrefix($0 + "/")
        }
    }

    // MARK: - Scan

    /// Enumerate every `.jsonl` session across every project directory.
    /// Returns sessions sorted newest-first. Unparseable files are skipped.
    static func scan(limit: Int? = nil) -> [AgentSession] {
        let fm = FileManager.default
        var sessions: [AgentSession] = []
        let ledgerTaskNames = scheduledTaskNamesFromRunLedger()
        guard fm.fileExists(atPath: sessionRoot.path),
              let projectDirs = try? fm.contentsOfDirectory(
                at: sessionRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else {
            return []
        }
        for projectDir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectDir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let decoded = resolveClaudeProjectPath(encoded: projectDir.lastPathComponent)
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for url in files where url.pathExtension == "jsonl" {
                let sessionId = url.deletingPathExtension().lastPathComponent
                let inspection = inspectSession(from: url,
                                                decodedProjectPath: decoded)
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
                let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
                var session = AgentSession(
                    id: sessionId,
                    fileURL: url,
                    title: inspection.title,
                    modifiedAt: mtime,
                    // Tail read, memoised against (size, mtime) — see
                    // `cachedLastUserMessageDate`. An unchanged file
                    // costs a dictionary lookup here, not a read.
                    lastUserMessageAt: cachedLastUserMessageDate(
                        of: url, size: size, mtime: mtime),
                    // The transcript's own `cwd` is authoritative — the
                    // encoded dirname can't distinguish "-" from "/",
                    // space, or "." ("IB Native" decodes as "IB/Native").
                    // The decode walk stays as the fallback for files
                    // whose head carries no cwd.
                    projectPath: inspection.cwd ?? decoded,
                    scheduledTaskName: inspection.scheduledTaskName
                        ?? ledgerTaskNames[sessionId]
                )
                session.titleIsFallback = inspection.titleIsFallback
                session.isEmptyShell = inspection.isEmptyShell
                if session.scheduledTaskName != nil {
                    session.origin = .scheduled
                }
                // Scratch sessions never reach the sidebar — but a
                // SCHEDULED run is kept wherever it happened to run.
                // Automation the user set up is theirs to see; hiding
                // it because the wrapper chose a temp cwd would lose
                // real output, which is the opposite of the point.
                if session.scheduledTaskName == nil,
                   Self.isScratchLocation(session.projectPath) {
                    continue
                }
                sessions.append(session)
            }
        }
        sessions.sort { $0.activityAt > $1.activityAt }
        if let limit = limit, limit < sessions.count {
            return Array(sessions.prefix(limit))
        }
        return sessions
    }

    // MARK: - History

    /// Walk a Claude Code JSONL and emit granular history items in
    /// chronological order: each `tool_use` and `tool_result` becomes
    /// its own item so the viewer can render it through the same
    /// helpers the live stream uses.
    ///
    /// `maxTurns` caps the number of **user-text** entries, not total
    /// items, so a single heavy tool-using turn doesn't consume the
    /// budget.
    /// History byte budget: parse only the newest slice of oversized
    /// transcripts — the turn cap keeps only recent turns anyway, and
    /// multi-hundred-MB session files are normal for heavy use. A
    /// whole-file Data + String + per-line JSON pass on every open is
    /// a "Loading session history" freeze waiting to happen.
    ///
    /// Internal, not private: it is the FIRST rung of the view's
    /// widen ladder (`AgentSessionView.historyWidenLadder`), and two
    /// spellings of the same bound is how "Show earlier" comes to
    /// disagree with what was actually read.
    static let historyByteBudget = 8 * 1024 * 1024

    /// `byteBudget` overrides the tail size for callers that need the
    /// WHOLE conversation rather than the newest slice — global search
    /// indexing, and the find bar's "search the whole session". It stays
    /// a bound (never "read it all"): a budget is what keeps a
    /// pathological transcript from being pulled into memory entire.
    static func readHistory(of url: URL, maxTurns: Int = 50,
                            byteBudget: Int? = nil) -> [AgentSessionHistoryItem] {
        // Lossy decode + bounded tail. STRICT decoding returns nil —
        // an EMPTY transcript for the whole session — whenever a
        // snapshot of a file another claude is MID-WRITING ends inside
        // a multibyte character. A partial edge line just fails JSON
        // parsing and is skipped, exactly like the stream readers.
        guard let text = boundedTail(of: url,
                                     budget: byteBudget ?? Self.historyByteBudget)
        else {
            return []
        }
        var items: [AgentSessionHistoryItem] = []

        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
            else { return }

            // The record's own id, carried onto every item it produces —
            // the handle a transcript row needs to point back at its
            // line in the file (see `AgentSessionHistoryItem.recordUuid`
            // and `AgentSessionFork`).
            let recordUuid = obj["uuid"] as? String

            switch obj["type"] as? String ?? "" {
            case "user":
                let msg = obj["message"] as? [String: Any] ?? [:]
                let content = msg["content"]
                // A user record with `toolUseResult` is the model feeding
                // itself a tool's output, not a real user message.
                // NSNull-safe: JSON null must read as absent.
                if obj["toolUseResult"] != nil,
                   !(obj["toolUseResult"] is NSNull) {
                    items.append(parseToolResult(
                        userContent: content,
                        fallback: obj["toolUseResult"],
                        recordUuid: recordUuid
                    ))
                    return
                }
                let raw = content ?? obj["content"] ?? ""
                let rawText = extractText(fromContent: raw)
                let cleaned = cleanUserText(rawText)
                if !cleaned.isEmpty {
                    items.append(AgentSessionHistoryItem(
                        kind: .userText(cleaned), recordUuid: recordUuid,
                        isSystemNotice: isHarnessNotice(rawText)))
                }

            case "assistant":
                let msg = obj["message"] as? [String: Any] ?? [:]
                let content = msg["content"]
                // `<synthetic>` marks text the HARNESS produced and no
                // model ever said — a usage-limit notice, "No response
                // requested.", a failed-auth line. The live feeds label
                // it a system notice, so the reload has to as well or
                // the same row changes speaker when history takes over.
                items.append(contentsOf: parseAssistantBlocks(
                    content, recordUuid: recordUuid,
                    isSynthetic: (msg["model"] as? String) == "<synthetic>"))

            case "system":
                // A local slash command's answer — the one system record
                // that renders. Dropping it left the command visible
                // with its reply gone: the reply IS on screen while the
                // turn streams (stdout carries it as a `<synthetic>`
                // assistant record), so the reload that replaces the
                // live buffer with this read was what made it vanish.
                //
                // Rendered as a system NOTICE in the user column, not as
                // assistant text: the CLI printed it, the model never
                // said it.
                if let output = localCommandOutput(fromRecord: obj) {
                    items.append(AgentSessionHistoryItem(
                        kind: .userText(output), recordUuid: recordUuid,
                        isSystemNotice: true))
                }

            default:
                break  // "result", unknown types — silently skipped
            }
        }

        // Turn-based cap: count only user-text items so a 50-turn limit
        // isn't eaten by a single heavy tool-use turn's 40+ items.
        let userIndices = items.enumerated().compactMap { i, it -> Int? in
            if case .userText = it.kind { return i }
            return nil
        }
        if userIndices.count <= maxTurns { return items }
        let startIdx = userIndices[userIndices.count - maxTurns]
        return Array(items[startIdx...])
    }

    /// Read the last `budget` bytes of a file (or all of it when
    /// smaller), lossy-decoded. Newest-value scans must be bounded —
    /// these run on every session open and turn end, and session
    /// JSONLs grow into the hundreds of MB. Lossy on purpose: reads
    /// race live writers, and a strict decode fails WHOLE on a
    /// mid-character edge instead of losing one edge line.
    static func boundedTail(of url: URL, budget: Int = 256 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(budget) ? size - UInt64(budget) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: budget) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The session's most recently recorded launch options, read from
    /// the JSONL every writer shares (this app, a terminal, the desktop
    /// app): top-level `permissionMode` on user records, `effort`
    /// and `message.model` on assistant records. Scans newest-first and
    /// stops once all three are found; sidechain (subagent) records are
    /// skipped so a subagent's model can't masquerade as the session's.
    /// A field that comes back nil was NOT FOUND in the window read —
    /// which is not the same as "the session used claude's default".
    /// Claude records its default explicitly (`permissionMode:
    /// "default"`), so callers must treat nil as "unknown, leave the
    /// current value alone", never as a value to apply. See
    /// `AgentSessionView.seedLaunchOptions`.
    static func lastLaunchOptions(of url: URL)
    -> (permissionMode: String?, model: String?, effort: String?) {
        // Escalating windows, for `permissionMode` specifically.
        // `model` and `effort` ride ASSISTANT records, of which a turn
        // writes many, so they always sit near the tail. But
        // `permissionMode` is written ONCE PER TURN, on the user record
        // that opens it — so the newest one is however far back that
        // turn's own records reach, which on a session with big turns
        // can be well past the standard 256 KB window. Missing it is
        // self-perpetuating: a nil mode drops the flag from the next
        // send, claude then records `default`, and every later read
        // agrees. Widen only when the narrow read found no mode, and
        // stop at the file's own size; most sessions never pay for the
        // second pass.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        var found: (permissionMode: String?, model: String?, effort: String?)
            = (nil, nil, nil)
        for budget in [256 * 1024, 4 * 1024 * 1024] {
            found = launchOptionsScan(of: url, budget: budget)
            if found.permissionMode != nil { break }
            if let size, size <= UInt64(budget) { break }
        }
        return found
    }

    private static func launchOptionsScan(of url: URL, budget: Int)
    -> (permissionMode: String?, model: String?, effort: String?) {
        guard let text = boundedTail(of: url, budget: budget) else {
            return (nil, nil, nil)
        }
        var mode: String? = nil
        var model: String? = nil
        var effort: String? = nil
        for line in text.split(separator: "\n").reversed() {
            if mode != nil && model != nil && effort != nil { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Cheap substring prefilter before paying for JSON parsing.
            let interesting = (mode == nil && trimmed.contains("\"permissionMode\""))
                || (effort == nil && trimmed.contains("\"effort\""))
                || (model == nil && trimmed.contains("\"model\""))
            guard interesting,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
            else { continue }
            if (obj["isSidechain"] as? Bool) == true { continue }
            if mode == nil, let m = obj["permissionMode"] as? String, !m.isEmpty {
                mode = m
            }
            if effort == nil, let e = obj["effort"] as? String, !e.isEmpty {
                effort = e
            }
            if model == nil,
               let msg = obj["message"] as? [String: Any],
               let mdl = msg["model"] as? String,
               !mdl.isEmpty, mdl != "<synthetic>" {
                model = mdl
            }
        }
        return (mode, model, effort)
    }

    /// Context-window footprint of a session's most recent assistant
    /// record: `usage.input_tokens + cache_creation + cache_read +
    /// output_tokens`.
    /// Seeds the composer's usage ring when opening an existing session
    /// (live assistant events take over once a turn streams). Returns 0
    /// if the file is unreadable or no assistant record carries usage.
    static func lastContextTokens(of url: URL) -> Int {
        guard let text = boundedTail(of: url) else {
            return 0
        }
        var last = 0
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  trimmed.contains("\"usage\""),
                  let lineData = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  // Subagent records run in their own small context —
                  // mirroring lastLaunchOptions' sidechain skip (and
                  // the parser's parent_tool_use_id skip).
                  (obj["isSidechain"] as? Bool) != true,
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any]
            else { return }
            func intField(_ value: Any?) -> Int {
                if let i = value as? Int { return i }
                if let d = value as? Double { return Int(d) }
                return 0
            }
            // Mirror AgentEventParser.contextFootprint: the reply's own
            // output joins the next request's context, so it counts.
            let total = intField(usage["input_tokens"])
                + intField(usage["cache_creation_input_tokens"])
                + intField(usage["cache_read_input_tokens"])
                + intField(usage["output_tokens"])
            if total > 0 { last = total }
        }
        return last
    }

    /// Seconds the NEWEST finished turn in this transcript took — the
    /// cold seed for the composer's turn clock, so a session this app
    /// has not run still shows its last turn's time. 0 when no finished
    /// turn is in reach.
    ///
    /// Walks backwards to the newest turn END and answers from whatever
    /// kind it turns out to be. Both kinds are needed:
    ///
    /// * `{"type":"system","subtype":"turn_duration","durationMs":…}` —
    ///   claude's own number, used verbatim. Only a minority of
    ///   transcripts carry one, so it cannot be the sole source; a
    ///   `turn_duration`-only seed leaves most of the store blank.
    /// * otherwise the assistant record whose `stop_reason` terminates
    ///   the turn, timed back to the user prompt that opened it. The
    ///   walk takes the newest turn end of EITHER kind rather than
    ///   preferring the recorded one: a turn can end after the newest
    ///   recorded `turn_duration`, and the derived value is then the
    ///   more current answer.
    ///
    /// `away_summary` / `stop_hook_summary` are deliberately NOT turn
    /// ends here even though `AgentSessionTailer` treats them as
    /// liveness signals: they are written when the user walks away,
    /// minutes after the turn, and timing to them would inflate every
    /// derived value by exactly that idle gap.
    ///
    /// There is no `type: "result"` branch: stream-json emits those,
    /// the transcript does not.
    ///
    /// Reads files. Call it off the main thread (see
    /// `AgentSessionView.startHistoryLoad`).
    static func lastTurnDurationSeconds(of url: URL) -> Double {
        // Escalating windows, for the same reason `lastLaunchOptions`
        // needs them: the turn END is always near the tail, but the
        // PROMPT that opened it is however far back that turn's own
        // records reach, and a tool-heavy turn buries it well past the
        // standard window.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        for budget in [256 * 1024, 4 * 1024 * 1024] {
            let seconds = turnDurationScan(of: url, budget: budget)
            if seconds > 0 { return seconds }
            if let size, size <= UInt64(budget) { break }
        }
        return 0
    }

    private static func turnDurationScan(of url: URL, budget: Int) -> Double {
        guard let text = boundedTail(of: url, budget: budget) else { return 0 }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

        func object(_ line: Substring) -> [String: Any]? {
            guard let data = line.trimmingCharacters(in: .whitespaces)
                    .data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        // Newest turn end, whichever kind comes first walking back.
        var endIndex: Int? = nil
        var endedAt: Date? = nil
        var index = lines.count - 1
        while index >= 0 {
            let line = lines[index]
            // Cheap pre-filter; correctness comes from the parse below.
            if line.contains("turn_duration") || line.contains("stop_reason") {
                if let obj = object(line), (obj["isSidechain"] as? Bool) != true {
                    let type = obj["type"] as? String
                    if type == "system", obj["subtype"] as? String == "turn_duration" {
                        let ms = obj["durationMs"]
                        let value = (ms as? Int) ?? Int((ms as? Double) ?? 0)
                        if value > 0 { return Double(value) / 1000.0 }
                    }
                    if type == "assistant",
                       let msg = obj["message"] as? [String: Any],
                       let stop = msg["stop_reason"] as? String,
                       AgentSessionTailer.terminatingStopReasons.contains(stop),
                       let ts = isoDate(obj["timestamp"]) {
                        endIndex = index
                        endedAt = ts
                        break
                    }
                }
            }
            index -= 1
        }
        guard let endIdx = endIndex, let end = endedAt else { return 0 }

        // Back to the user prompt that opened it. A `tool_result`
        // round-trip is also `type: user` and must not count as the
        // turn's start — that is claude answering itself mid-turn.
        var back = endIdx - 1
        while back >= 0 {
            if lines[back].contains("\"user\""),
               let obj = object(lines[back]), isTurnStartUser(obj),
               let start = isoDate(obj["timestamp"]) {
                let seconds = end.timeIntervalSince(start)
                return seconds > 0 ? seconds : 0
            }
            back -= 1
        }
        return 0
    }

    /// A real user prompt: not a subagent record, not a `tool_result`
    /// round-trip, not a meta/system-injected record.
    private static func isTurnStartUser(_ obj: [String: Any]) -> Bool {
        guard obj["type"] as? String == "user",
              (obj["isSidechain"] as? Bool) != true,
              (obj["isMeta"] as? Bool) != true else { return false }
        if let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]],
           blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
            return false
        }
        return true
    }

    /// Timestamp of the newest turn-START user record — when the turn
    /// currently in flight began, read from the writer's OWN record
    /// stamps. Powers the composer's turn clock for turns some other
    /// process is running (an orphaned `claude -p` after an app
    /// relaunch, another SipAI instance): this app has no local clock
    /// for those, but the transcript does, so the chip can tick
    /// truthfully instead of sitting dead. Escalating windows for the
    /// same reason `lastLaunchOptions` needs them — the opening user
    /// record sits a whole turn's records back from EOF on a
    /// tool-heavy turn.
    ///
    /// Reads files; call off the main thread.
    static func lastTurnStartDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        for budget in [256 * 1024, 4 * 1024 * 1024] {
            if let found = turnStartScan(of: url, budget: budget) {
                return found
            }
            if let size, size <= UInt64(budget) { break }
        }
        return nil
    }

    private static func turnStartScan(of url: URL, budget: Int) -> Date? {
        guard let text = boundedTail(of: url, budget: budget) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            // Cheap pre-filter; correctness comes from the parse.
            guard line.contains("\"user\"") else { continue }
            guard let data = line.trimmingCharacters(in: .whitespaces)
                    .data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  isTurnStartUser(obj) else { continue }
            // Wrapper-only records (system-reminder injections) and the
            // synthetic interrupt record are claude bookkeeping, not
            // the user opening a turn — same rule as the tailer's
            // liveness check.
            let msg = obj["message"] as? [String: Any] ?? [:]
            let rawText = extractText(fromContent: msg["content"] ?? "")
            let text = cleanSessionMetaText(rawText)
            guard !text.isEmpty,
                  !text.hasPrefix("[Request interrupted"),
                  !isHarnessNotice(rawText) else { continue }
            return isoDate(obj["timestamp"])
        }
        return nil
    }

    /// True when the transcript's newest liveness signal says a turn
    /// is still OPEN — the records simply stop, with no result, no
    /// terminating stop_reason, no turn-end system marker and no
    /// interrupt record after them. Combined with "no live writer"
    /// (`ClaudeSessionStatusStore`) this is the residue of a kill:
    /// the turn was stopped before it finished, and the transcript
    /// should say so instead of ending mid-thought.
    ///
    /// Reads files; call off the main thread.
    static func endsMidTurn(of url: URL) -> Bool {
        guard let text = boundedTail(of: url) else { return false }
        var state: Bool? = nil
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any]
            else { return }
            if let signal = AgentSessionTailer.progressState(forRawRecord: obj) {
                state = signal
            }
        }
        return state == true
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// Transcript timestamps are ISO-8601 with fractional seconds
    /// ("2026-08-11T10:10:07.809Z"); the plain parser is the fallback
    /// for any writer that omits them. Shared with the codex scanner,
    /// whose rollout records stamp the same shape — one parser rather
    /// than two that could drift on the fractional-seconds case.
    static func isoDate(_ value: Any?) -> Date? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    // MARK: - Payload parsing

    /// Walk an `assistant` record's `message.content` and emit one item
    /// per block. Thinking blocks are silently skipped.
    ///
    /// `isSynthetic` re-attributes TEXT only, and mirrors
    /// `AgentEventParser.parseAssistant` block for block — the two
    /// render the same records on the reload and live paths, and a rule
    /// that lives in one of them makes a row change speaker between
    /// them. Any other block type keeps its ordinary shape.
    private static func parseAssistantBlocks(_ content: Any?,
                                             recordUuid: String? = nil,
                                             isSynthetic: Bool = false)
    -> [AgentSessionHistoryItem] {
        func textItem(_ t: String) -> AgentSessionHistoryItem {
            isSynthetic
                ? AgentSessionHistoryItem(kind: .userText(t),
                                          recordUuid: recordUuid,
                                          isSystemNotice: true)
                : AgentSessionHistoryItem(kind: .assistantText(t),
                                          recordUuid: recordUuid)
        }
        if let s = content as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [textItem(t)]
        }
        guard let arr = content as? [Any] else { return [] }
        var out: [AgentSessionHistoryItem] = []
        for block in arr {
            guard let dict = block as? [String: Any] else { continue }
            switch dict["type"] as? String {
            case "text":
                if let raw = dict["text"] as? String {
                    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { out.append(textItem(t)) }
                }
            case "tool_use":
                let name = (dict["name"] as? String) ?? "Tool"
                let id = (dict["id"] as? String) ?? UUID().uuidString
                let input = (dict["input"] as? [String: Any]) ?? [:]
                out.append(AgentSessionHistoryItem(
                    kind: .toolUse(id: id, name: name, input: input),
                    recordUuid: recordUuid
                ))
            default:
                break  // "thinking" and anything else we don't surface
            }
        }
        return out
    }

    /// Parse a `user + toolUseResult` record into a `.toolResult` item.
    /// Prefers the `tool_result` block inside `message.content` when
    /// present (that's where `tool_use_id` and `is_error` live); falls
    /// back to the top-level `toolUseResult` field otherwise.
    private static func parseToolResult(userContent: Any?,
                                        fallback: Any?,
                                        recordUuid: String? = nil) -> AgentSessionHistoryItem {
        var payload: Any? = nil
        var toolUseId = ""
        var isError = false

        if let arr = userContent as? [Any] {
            for block in arr {
                guard let dict = block as? [String: Any],
                      (dict["type"] as? String) == "tool_result"
                else { continue }
                payload = dict["content"]
                toolUseId = (dict["tool_use_id"] as? String) ?? toolUseId
                isError = (dict["is_error"] as? Bool) ?? isError
                break
            }
        }
        if payload == nil {
            payload = fallback
        }

        let text = textFromToolResultContent(payload)
        return AgentSessionHistoryItem(
            kind: .toolResult(
                toolUseId: toolUseId,
                content: text,
                isError: isError
            ),
            recordUuid: recordUuid
        )
    }

    /// Flatten a `tool_result`-style content field (string, array of
    /// blocks, or nested object) into a single display string. Mirrors
    /// the live-path helper inside `AgentRunner`.
    private static func textFromToolResultContent(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [Any] {
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
        if let dict = content as? [String: Any] {
            // Claude sometimes drops the wrapping array and passes a
            // single block dict directly; pick up its text field.
            if let t = dict["text"] as? String { return t }
            if let inner = dict["content"] {
                return textFromToolResultContent(inner)
            }
        }
        if let v = content { return String(describing: v) }
        return ""
    }

    // MARK: - Content extraction

    /// Extract visible text from a `message.content` that may be a string or
    /// an array of content blocks.
    /// Internal (not private): AgentSessionTailer's turn-liveness check
    /// needs the same extraction for user records.
    static func extractText(fromContent content: Any) -> String {
        if let s = content as? String {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let arr = content as? [Any] {
            var parts: [String] = []
            for block in arr {
                if let dict = block as? [String: Any],
                   dict["type"] as? String == "text",
                   let t = dict["text"] as? String {
                    parts.append(t)
                } else if let s = block as? String {
                    parts.append(s)
                }
            }
            return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(describing: content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Title extraction

    /// Inspect the first real user record for its scheduled-task marker while
    /// also finding the first non-empty visible user title. The marker must be
    /// read before `cleanUserText` removes it. If the scheduled wrapper is the
    /// only content in the first record, title discovery continues to a later
    /// visible user message while the task association stays fixed.
    /// Byte budget for title/marker discovery — a bounded tail.
    /// A whole-file read here would make every sidebar rescan re-read
    /// multi-hundred-MB session stores and allocate file-sized strings.
    private static let inspectByteBudget = 256 * 1024

    private static func inspectSession(from url: URL, decodedProjectPath: URL?)
    -> (title: String, scheduledTaskName: String?, cwd: URL?,
        titleIsFallback: Bool, isEmptyShell: Bool) {
        // Everything this function needs lives at the edges of the
        // file: the session's cwd, the scheduled-task marker, and the
        // fallback title in the FIRST records (head); the newest
        // ai-title near EOF (tail). A line cut in half at a window edge
        // simply fails JSON parsing and is skipped.
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            // Unreadable is not provably empty — keep the row visible.
            return (neutralTitle(for: decodedProjectPath), nil, nil, true, false)
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let headData = (try? handle.read(upToCount: Self.inspectByteBudget))
            ?? Data()
        let text = String(decoding: headData, as: UTF8.self)
        var tailText = text
        if size > UInt64(Self.inspectByteBudget) {
            try? handle.seek(toOffset: size - UInt64(Self.inspectByteBudget))
            let tailData = (try? handle.read(upToCount: Self.inspectByteBudget))
                ?? Data()
            tailText = String(decoding: tailData, as: UTF8.self)
        }
        // Claude writes `{"type": "ai-title", "aiTitle": "…"}` records —
        // the name Claude Desktop shows. Prefer the newest one so
        // SipAI's names match the desktop app; the first-user-message
        // derivation below stays as the fallback for sessions that
        // haven't been titled yet. The scheduled-task marker still has
        // to be read from the first user record either way.
        let aiTitle = extractAiTitle(from: tailText)
        var result: String? = nil
        var scheduledTaskName: String? = nil
        var sessionCwd: URL? = nil
        var sawConversation = false
        var checkedFirstUserRecord = false
        var firstCommandName: String? = nil
        text.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
            else { return }
            // Read off the DECODED content, never the raw line: `\/` is
            // a legal JSON spelling of "/", so `</command-name>` can
            // reach the file as `<\/command-name>` and a raw-line match
            // silently finds nothing. Claude files the command name on
            // a user record for most commands and on a system record
            // for others, so both shapes are tried. Last-resort title
            // only.
            if firstCommandName == nil {
                let content = ((obj["message"] as? [String: Any])?["content"])
                    ?? obj["content"] ?? ""
                let decoded = extractText(fromContent: content)
                if decoded.contains("<command-name>") {
                    firstCommandName = extractCommandName(from: decoded)
                }
            }
            // Nearly every record stamps the working directory; the
            // first one settles the session's real project root.
            if sessionCwd == nil, let c = obj["cwd"] as? String,
               c.hasPrefix("/") {
                sessionCwd = URL(fileURLWithPath: c, isDirectory: true)
            }
            // Any REAL assistant record or tool round-trip is
            // conversation — the discriminator between a real session
            // and a `/clear` shell that only ever logged local
            // commands. "Real" excludes `model: "<synthetic>"`: claude
            // writes a synthetic assistant record ("No response
            // requested.") after every `/exit`-style command, so a
            // pure command shell still carries assistant records and
            // would otherwise dodge shell detection.
            if !sawConversation, let t = obj["type"] as? String {
                if t == "user", obj["toolUseResult"] != nil,
                   !(obj["toolUseResult"] is NSNull) {
                    sawConversation = true
                } else if t == "assistant" {
                    let model = ((obj["message"] as? [String: Any])?["model"]
                                    as? String) ?? ""
                    if model != "<synthetic>" { sawConversation = true }
                } else if t == "system",
                          localCommandOutput(fromRecord: obj) != nil {
                    // A slash command that ANSWERED. The session holds
                    // something the user asked for and can read back, so
                    // hiding it loses the answer along with the row —
                    // and `/mcp` in this app is exactly that session.
                    //
                    // Still judged on the answer's TEXT, which is what
                    // keeps the shells this test exists for hidden: a
                    // command that printed nothing writes an empty
                    // wrapper, and `/clear` writes no transcript at all.
                    sawConversation = true
                }
            }
            if obj["type"] as? String != "user" { return }
            if obj["toolUseResult"] != nil,
               !(obj["toolUseResult"] is NSNull) { return }
            let msg = obj["message"] as? [String: Any] ?? [:]
            let raw = msg["content"] ?? obj["content"] ?? ""
            let pick = firstUserText(raw)
            if !checkedFirstUserRecord {
                scheduledTaskName = extractScheduledTaskName(from: pick)
                checkedFirstUserRecord = true
            }
            guard !pick.isEmpty else { return }
            // Title derivation uses the META cleaner: a session whose
            // first record is a slash command must fall through to the
            // next real message, not be named "/clear clear".
            let cleaned = cleanSessionMetaText(pick)
            guard !cleaned.isEmpty else { return }
            let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                                   .joined(separator: " ")
            if collapsed.count > 50 {
                result = String(collapsed.prefix(47)) + "..."
            } else {
                result = collapsed
            }
            // With an ai-title in hand only the scheduled-task marker
            // and cwd were still needed — both live in the first
            // records, which have now been seen. Stopping here can
            // leave cwd nil only if no head record carried one, and
            // then the decode fallback covers it.
            stop = true
        }
        if let aiTitle = aiTitle {
            return (aiTitle, scheduledTaskName, sessionCwd, false, false)
        }
        if let result = result {
            return (result, scheduledTaskName, sessionCwd, false, false)
        }
        // Only a file we saw IN FULL can be declared empty — a bigger
        // file may hold its conversation past the inspect window.
        let emptyShell = !sawConversation
            && size <= UInt64(Self.inspectByteBudget)
        // Nothing the user typed, but a command they ran. Naming the row
        // "/mcp" beats "<folder> session" for a session whose whole
        // content is that command — and several of them in one folder
        // are otherwise indistinguishable. Last resort only: a session
        // that opens with a slash command and goes on to a real message
        // is named by the message, which is what keeps this from
        // reviving "/clear clear" as a title.
        if let command = firstCommandName {
            return (command, scheduledTaskName, sessionCwd, true, emptyShell)
        }
        return (neutralTitle(for: sessionCwd ?? decodedProjectPath),
                scheduledTaskName, sessionCwd, true, emptyShell)
    }

    /// A transcript with no visible user text is named after its folder
    /// instead of surfacing a raw UUID in the sidebar. `CodexSessions`
    /// has its own `neutralTitle` for the same reason.
    private static func neutralTitle(for folder: URL?) -> String {
        if let name = folder?.lastPathComponent, !name.isEmpty,
           name != FileManager.default.homeDirectoryForCurrentUser.lastPathComponent {
            return "\(name) session"
        }
        return String(localized: "New Claude session",
                      comment: "Fallback title for a Claude session with no user text")
    }

    /// The `<command-name>` entries in a transcript's head — what a
    /// zero-turn session actually holds ("/clear", "/exit", …). Lets
    /// the empty state explain the file instead of presenting a
    /// mystery. Order-preserving, deduplicated, bounded read.
    static func localCommandNames(of url: URL, limit: Int = 6) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: Self.inspectByteBudget)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard let regex = try? NSRegularExpression(
            pattern: "<command-name>([^<]+)</command-name>") else { return [] }
        var names: [String] = []
        text.enumerateLines { line, stop in
            guard line.contains("<command-name>") else { return }
            let range = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: range) {
                guard match.numberOfRanges > 1,
                      let r = Range(match.range(at: 1), in: line) else { continue }
                let name = String(line[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, !names.contains(name) {
                    names.append(name)
                }
                if names.count >= limit {
                    stop = true
                    return
                }
            }
        }
        return names
    }

    private static let commandNameRegex = try? NSRegularExpression(
        pattern: "<command-name>([^<]+)</command-name>")

    /// The first `<command-name>` in one raw JSONL line, or nil.
    /// Cached regex: this runs per record of every session inspect.
    static func extractCommandName(from line: String) -> String? {
        guard let regex = commandNameRegex else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: line) else { return nil }
        let name = String(line[r])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Inner text of the `<local-command-stdout>` / `<local-command-stderr>`
    /// wrappers, matched as a PAIR rather than by stripping bare tags:
    /// `/model` prints "Usage: /model <name>", and a generic `<[^>]+>`
    /// pass eats the `<name>` out of the answer it is meant to recover.
    private static let localCommandBodyRegex = try? NSRegularExpression(
        pattern: "<local-command-(?:stdout|stderr)>([\\s\\S]*?)"
               + "</local-command-(?:stdout|stderr)>")

    /// Interactive claude styles some of this output; `-p` does not.
    /// A CSI sequence reaching a bubble renders as literal escape junk.
    private static let ansiEscapeRegex = try? NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

    /// What a local slash command printed — `/mcp`, `/model`, `/context`.
    ///
    /// This record is the ONLY place that answer is stored. Under `-p`
    /// it also comes back on stdout as an assistant record stamped
    /// `model: "<synthetic>"`, but claude never writes that record to
    /// the transcript, so anything reading the file back has to recover
    /// the answer from here or lose it.
    ///
    /// Nil for the two shapes that carry no answer, both of which claude
    /// writes routinely: a bare echo of the command (no wrapper at all)
    /// and an empty wrapper. Judging on CONTENT rather than on the
    /// record's presence is what keeps a pure `/clear` shell empty.
    static func localCommandOutput(fromRecord obj: [String: Any]) -> String? {
        guard (obj["type"] as? String) == "system",
              (obj["subtype"] as? String) == "local_command",
              let content = obj["content"] as? String,
              content.contains("<local-command-std"),
              let regex = localCommandBodyRegex
        else { return nil }
        let range = NSRange(content.startIndex..., in: content)
        var parts: [String] = []
        for match in regex.matches(in: content, range: range) {
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: content) else { continue }
            let piece = String(content[r])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { parts.append(piece) }
        }
        guard !parts.isEmpty else { return nil }
        return strippingANSI(parts.joined(separator: "\n"))
    }

    private static func strippingANSI(_ text: String) -> String {
        guard text.contains("\u{1B}"), let regex = ansiEscapeRegex else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: "")
    }

    /// The newest `ai-title` record, scanned from the transcript tail —
    /// Claude re-emits the record as the session evolves, so the last
    /// ~256 KB nearly always holds the current one. Collapsed and
    /// length-capped exactly like the derived titles.
    private static func extractAiTitle(from text: String) -> String? {
        let tail = String(text.suffix(256 * 1024))
        var found: String? = nil
        tail.enumerateLines { line, _ in
            guard line.contains("\"ai-title\"") else { return }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  obj["type"] as? String == "ai-title",
                  let raw = obj["aiTitle"] as? String else { return }
            let collapsed = raw
                .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                .joined(separator: " ")
            guard !collapsed.isEmpty else { return }
            found = collapsed.count > 50
                ? String(collapsed.prefix(47)) + "..."
                : collapsed
        }
        return found
    }

    /// First-user-text extraction: if content is a list, take the first
    /// text-typed block or the first string; if it's a plain string,
    /// return it; otherwise empty.
    private static func firstUserText(_ content: Any) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [Any] {
            for block in arr {
                if let dict = block as? [String: Any],
                   dict["type"] as? String == "text",
                   let t = dict["text"] as? String {
                    return t
                }
                if let s = block as? String {
                    return s
                }
            }
            return ""
        }
        return ""
    }

    /// Extract the task key from a Claude scheduled-run marker. Attribute
    /// order is intentionally unrestricted; both quote styles are accepted.
    /// This pattern — anchored inside the `<scheduled-task…>` tag, both
    /// quote styles — is canonical.
    /// Internal, not private: `CodexSessionScanner` files codex runs
    /// under the same marker, and duplicating this regex is how the two
    /// scanners would drift into classifying the same run differently.
    static func extractScheduledTaskName(from text: String) -> String? {
        guard text.contains("<scheduled-task") else { return nil }
        // The value is delimited by the quote that OPENED it (group 1,
        // back-referenced), not by "either quote character" — an
        // either-quote class would cut a name at its first apostrophe
        // and file the run under a task nothing else knows about, so
        // the run vanishes from the task's panel. SipAI's own
        // `slugify` reduces an apostrophe to `-`, but a hand-made task
        // directory is under no such rule.
        let pattern = #"<scheduled-task\b[^>]*?\bname\s*=\s*(["'])([^>]*?)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges > 2,
              let range = Range(match.range(at: 2), in: text)
        else { return nil }
        let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Read the optional run ledger into a session-id → task-name
    /// lookup. Invalid or incomplete lines are skipped.
    private static func scheduledTaskNamesFromRunLedger() -> [String: String] {
        guard let data = try? Data(contentsOf: agentRunsFile),
              let text = String(data: data, encoding: .utf8) else {
            return [:]
        }
        var result: [String: String] = [:]
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  let sessionId = obj["session_id"] as? String,
                  !sessionId.isEmpty,
                  let taskName = obj["task_name"] as? String,
                  !taskName.isEmpty else { return }
            result[sessionId] = taskName
        }
        return result
    }

    /// DISPLAY cleaner: strip only `<scheduled-task>`,
    /// `<system-reminder>` and `<local-command-caveat>` WITH their
    /// content, then bare XML tags,
    /// keeping the inner text of command wrappers. Used by `readHistory`
    /// and the tailer's live user-message emission. Do NOT extend this
    /// list with the title tags: doing so makes every slash-command
    /// turn and every message carrying `<local-command-stdout>` output
    /// clean to empty and VANISH from the transcript.
    static func cleanUserText(_ text: String) -> String {
        stripWrappers(text, patterns: [
            "<scheduled-task[^>]*>[\\s\\S]*?</scheduled-task>",
            "<system-reminder>[\\s\\S]*?</system-reminder>",
            "<local-command-caveat>[\\s\\S]*?</local-command-caveat>",
            "<[^>]+>",
        ])
    }

    /// A user-role record the HARNESS wrote — a background-task
    /// notification or an automated system notice — rather than
    /// anything the user typed. Judged on the RAW record text: the
    /// display cleaners strip the very tags that identify it. These
    /// rows render under a system label instead of the user's name,
    /// and must not count as the user opening a turn — a notification
    /// landing hours later would otherwise re-time the session's
    /// sidebar row.
    static func isHarnessNotice(_ rawText: String) -> Bool {
        let t = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("<task-notification>")
            || t.hasPrefix("[SYSTEM NOTIFICATION")
            || t.hasPrefix("<system-reminder>")
    }

    /// META cleaner: also strips the command wrappers WITH content.
    /// For TITLES (a `/clear`
    /// session must not be named "/clear clear") and for the tailer's
    /// turn-liveness text check (a record that is ONLY command/system
    /// wrappers is claude bookkeeping, not the user starting a turn).
    static func cleanSessionMetaText(_ text: String) -> String {
        stripWrappers(text, patterns: [
            "<scheduled-task[^>]*>[\\s\\S]*?</scheduled-task>",
            "<command-name>[\\s\\S]*?</command-name>",
            "<command-message>[\\s\\S]*?</command-message>",
            "<command-args>[\\s\\S]*?</command-args>",
            "<local-command-stdout>[\\s\\S]*?</local-command-stdout>",
            "<local-command-stderr>[\\s\\S]*?</local-command-stderr>",
            "<system-reminder>[\\s\\S]*?</system-reminder>",
            "<local-command-caveat>[\\s\\S]*?</local-command-caveat>",
            "<[^>]+>",
        ])
    }

    /// Pattern → compiled regex, built once per unique pattern for the
    /// process lifetime. `stripWrappers` runs per user record inside
    /// `readHistory`, `inspectSession`, AND the tailer's per-record
    /// liveness check — compiling 4–9 NSRegularExpressions per call
    /// would put regex compilation in the innermost loop of every scan
    /// and every read burst. The pattern set is a small fixed
    /// vocabulary, so the cache never grows past ~13 entries.
    private static let wrapperRegexCache: [String: NSRegularExpression] = {
        let all = [
            "<scheduled-task[^>]*>[\\s\\S]*?</scheduled-task>",
            "<system-reminder>[\\s\\S]*?</system-reminder>",
            "<local-command-caveat>[\\s\\S]*?</local-command-caveat>",
            "<command-name>[\\s\\S]*?</command-name>",
            "<command-message>[\\s\\S]*?</command-message>",
            "<command-args>[\\s\\S]*?</command-args>",
            "<local-command-stdout>[\\s\\S]*?</local-command-stdout>",
            "<local-command-stderr>[\\s\\S]*?</local-command-stderr>",
            "<[^>]+>",
        ]
        var map: [String: NSRegularExpression] = [:]
        for p in all {
            map[p] = try? NSRegularExpression(pattern: p, options: [])
        }
        return map
    }()

    private static func stripWrappers(_ text: String,
                                      patterns: [String]) -> String {
        // Cheap pre-check: no '<' means no wrapper can match — skip all
        // regex passes (the common case for ordinary user prose).
        guard text.contains("<") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var s = text
        for p in patterns {
            guard let regex = wrapperRegexCache[p]
                    ?? (try? NSRegularExpression(pattern: p, options: []))
            else { continue }
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Claude project path resolution

    /// Walks the filesystem from `/` trying to match multi-segment
    /// folder names (dashes are ambiguous —
    /// could be `/`, a space, or a literal `-`). Falls back to the naive
    /// slash decoding if nothing on disk matches.
    static func resolveClaudeProjectPath(encoded: String) -> URL? {
        let trimmed = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        let parts = trimmed.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return nil }
        let fm = FileManager.default

        func walk(base: URL, remaining: ArraySlice<String>) -> URL? {
            if remaining.isEmpty {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue {
                    return base
                }
                return nil
            }
            let startIdx = remaining.startIndex
            for i in 1...remaining.count {
                let segment = remaining[startIdx..<(startIdx + i)].joined(separator: " ")
                let next = base.appendingPathComponent(segment, isDirectory: true)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: next.path, isDirectory: &isDir), isDir.boolValue {
                    if let resolved = walk(base: next, remaining: remaining[(startIdx + i)...]) {
                        return resolved
                    }
                }
            }
            return nil
        }

        let root = URL(fileURLWithPath: "/")
        if let resolved = walk(base: root, remaining: parts[...]) {
            return resolved
        }
        // Naive fallback: treat dashes as slashes. Better than nothing.
        return URL(fileURLWithPath: "/" + parts.joined(separator: "/"))
    }
}

/// Scans scheduled-task definitions and joins them to the sessions tagged with
/// the same stable task name. Task folders with no runs are retained, and
/// tagged runs whose definition was removed are kept under a fallback parent
/// rather than disappearing from the sidebar.
enum ScheduledAgentTaskScanner {
    static let taskRoot: URL = {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/scheduled-tasks", isDirectory: true)
    }()

    static func scan(grouping sessions: [AgentSession]) -> [ScheduledAgentTask] {
        let fm = FileManager.default
        var definitions: [String: (description: String, directory: URL,
                                   skill: URL, cwd: URL?, agent: String,
                                   parsed: ScheduledTaskDefinition?)] = [:]

        if let taskDirectories = try? fm.contentsOfDirectory(
            at: taskRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for directory in taskDirectories {
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                let name = directory.lastPathComponent
                let skill = directory.appendingPathComponent("SKILL.md")
                let parsed = ScheduledTaskDefinition.read(name: name, skillFile: skill)
                definitions[name] = (
                    description: parsed?.description ?? name,
                    directory: directory,
                    skill: skill,
                    cwd: parsed?.workingDirectory,
                    agent: parsed?.agent ?? "claude_code",
                    parsed: parsed
                )
            }
        }

        var sessionsByTask: [String: [AgentSession]] = [:]
        for session in sessions {
            guard let taskName = session.scheduledTaskName, !taskName.isEmpty else {
                continue
            }
            sessionsByTask[taskName, default: []].append(session)
        }

        // Include orphaned tagged runs even if their task definition was
        // deleted after those runs completed.
        for taskName in sessionsByTask.keys where definitions[taskName] == nil {
            let directory = taskRoot.appendingPathComponent(taskName, isDirectory: true)
            definitions[taskName] = (
                description: taskName,
                directory: directory,
                skill: directory.appendingPathComponent("SKILL.md"),
                cwd: nil,
                // The frontmatter that named the agent is gone, so the
                // runs answer for it — each carries the store it was
                // read from. Hardcoding claude here would file an
                // orphaned codex or kimi task under the Claude Code
                // section: `scheduledTasks(for:)` splits on exactly this.
                agent: sessionsByTask[taskName]?.first?.agentKey ?? "claude_code",
                parsed: nil
            )
        }

        var tasks = definitions.map { name, definition in
            // Newest-first on the SAME clock the task row prints
            // (`lastActive` reads `sessions.first`), so a task cannot
            // show one run's time while another sits at the top.
            let runs = (sessionsByTask[name] ?? [])
                .sorted { $0.activityAt > $1.activityAt }
            return ScheduledAgentTask(
                name: name,
                description: definition.description,
                directoryURL: definition.directory,
                skillFileURL: definition.skill,
                workingDirectory: definition.cwd,
                sessions: runs,
                agent: definition.agent,
                definition: definition.parsed
            )
        }

        // Recently-run scheduled tasks first, followed by never-run
        // definitions in stable alphabetical order.
        tasks.sort { lhs, rhs in
            switch (lhs.lastActive, rhs.lastActive) {
            case let (left?, right?):
                if left != right { return left > right }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
        return tasks
    }

    // Frontmatter parsing, quote stripping and `cwd:` expansion all
    // live on `ScheduledTaskDefinition` — one parser shared by the
    // scanner, the scheduler and the editor, so the three can never
    // disagree about what a task file says.
}
