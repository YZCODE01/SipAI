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
    /// Settable for one caller: a run the scheduler has just started is
    /// filed under its task before its transcript can say so
    /// (`ScheduledAgentTaskScanner.overlaying`).
    var scheduledTaskName: String?
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
    /// When the task was scheduled: the birth time of its definition
    /// DIRECTORY. Never the SKILL.md's own dates — every save replaces
    /// that file, so they move whenever anything is edited. Nil for an
    /// orphan, and wherever the filesystem keeps no birth time.
    var createdAt: Date? = nil

    var id: String { name }
    /// Same clock as a regular row: when this task last SENT a prompt,
    /// not when its newest run last wrote a byte. `sessions` is
    /// ordered newest-first on that same key by the scanner. Nil until
    /// the first run — the row prints "Never".
    var lastRunAt: Date? { sessions.first?.activityAt }
    /// The task's place in the sidebar: its newest run, or the moment it
    /// was scheduled when that is later — so a task just created sits at
    /// the top of its group like a session just sent to, instead of
    /// sinking below every row that has ever run. Scheduling it IS the
    /// user's last word to it until it fires.
    var lastActive: Date? { [lastRunAt, createdAt].compactMap { $0 }.max() }

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
            && lhs.createdAt == rhs.createdAt
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
/// The newest turn a transcript records, read from its turn markers
/// (`CodexSessionScanner.latestTurn`, `KimiSessionScanner.latestTurn`):
/// whether it is still open, when it started, and — once it has ended —
/// how long it took, in the agent's own figures. What a watcher that
/// starts mid-turn reads to know it did, and what the composer's clock
/// rests on after a turn another process ran.
struct RecordedTurn: Equatable {
    var open: Bool
    var startedAt: Date?
    var seconds: Double?
}

struct AgentSessionHistoryItem: Identifiable, Hashable {
    let id: UUID = UUID()
    let kind: Kind
    /// The row's handle back into the transcript, in the writer's own
    /// vocabulary: the `uuid` of the claude JSONL record it was parsed
    /// out of, the `turn_id` of the codex turn it belongs to, the
    /// `message.id` of the kimi user record. It is what a branch is
    /// cut at (`AgentSessionFork`, `CodexSessionFork`, `KimiSessionFork`).
    ///
    /// It has to be an identifier the FILE carries rather than a line
    /// number: `readHistory` parses a BOUNDED TAIL of the file, so an
    /// index into what it read is not an index into the file. Nil for
    /// items that have no record behind them — the derived
    /// `.interrupted` marker — and for the agent's own rows, which are
    /// never branched from.
    var recordUuid: String? = nil

    /// True for a user-role record the harness injected rather than
    /// anything the user typed — see `AgentSessionScanner.isHarnessNotice`.
    var isSystemNotice: Bool = false

    /// True for the user's words sent into a turn already running: a
    /// message steered in mid-turn (claude's `queued_command` with
    /// `commandMode: "prompt"`, codex's second user message of a turn), or
    /// the answer to a question the agent asked without stopping (codex's
    /// `request_user_input_async`). Drawn as the user's — the words are
    /// theirs — but it opens no turn and is not a message to branch from:
    /// a branch cuts at a turn, and editing this row would replace the
    /// prompt of the turn it went into.
    var sentIntoTurn: Bool = false

    /// True on a row in the user column that is part of the agent's answer
    /// rather than the user's own words: a background task reporting back
    /// (claude's task notifications, its Monitor tool's events, kimi's
    /// finished tasks) and the user's reply on a question's card (codex's
    /// question asked without stopping). Compact view draws it inside the
    /// answer's one line — everything between the user's message and the
    /// final message is there.
    var belongsToAnswer: Bool = false

    /// The files a user message carried as inlined attachments
    /// (`AttachmentInline`), for the paperclip line under the bubble.
    /// The row's text has the blocks STRIPPED; the names are read off
    /// the raw record before that, since an agent transcript stores no
    /// `files` key of its own. Empty on every other row.
    var attachedFiles: [String] = []

    /// The skills SipAI loaded WITH this message (the composer's skill
    /// chip, a scheduled task's skills), for the line under the bubble.
    /// Read off the records the load left — claude's command records
    /// above the message, codex's mention line inside it — so a reopen
    /// draws what the live row drew. A skill the user typed is part of
    /// the row's own text instead. Empty on every other row.
    var loadedSkills: [String] = []

    /// On a `.compaction` row: the agent's own record of the summary says
    /// every message the user sent before it is still in the conversation
    /// whole — so a skill the user started there is still held, and is
    /// not sent again (`SkillEvidenceReader.evidence`). Kimi's, when it
    /// did not have to trim them (`KimiSessionScanner
    /// .compactionKeepsUserMessages`); false for every other agent.
    var compactionKeepsUserMessages = false

    /// True on the `.userText` row of a `!` command — the user's own shell
    /// command (`ShellCommands`). Its output is the `.shellOutput` row after
    /// it. A branch is never cut there: neither the terminal's record nor
    /// SipAI's carries the words a fork writer matches on.
    var shellCommand = false

    enum Kind {
        case userText(String)
        case assistantText(String)
        /// A readable thought. The readers keep none unless asked: with
        /// compact view on (`CompactTranscript`) they keep every one, and
        /// otherwise `keepingThoughts` drops every one outside a turn
        /// that ran in Chat only — the only turns that then draw them.
        case thinking(String)
        case toolUse(id: String, name: String, input: [String: Any])
        case toolResult(toolUseId: String, content: String, isError: Bool)
        /// The turn above ended without finishing — kill/quit residue,
        /// derived at load time (`AgentSessionScanner.endsMidTurn` +
        /// no live writer), never stored in the JSONL itself.
        case interrupted(message: String)
        /// The agent summarised the conversation to make room. Figures
        /// are nil for an agent that records none.
        case compaction(preTokens: Int?, postTokens: Int?)
        /// A turn the agent's own record says FAILED, and why, in its
        /// words (kimi's `turn.ended reason: failed` — `KimiSessionScanner
        /// .failedTurnReason`). Drawn as the live error row is, so a
        /// failure reads the same live and reopened.
        case error(message: String)
        /// What a `!` command printed (`shellCommand`).
        case shellOutput(ShellCommandOutput)
    }

    static func == (lhs: AgentSessionHistoryItem, rhs: AgentSessionHistoryItem) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// `items` with every `.thinking` row dropped except inside a turn
    /// whose user row's handle is in `chatOnlyTurns`.
    ///
    /// With compact view off a thought is drawn only inside a Chat only
    /// turn's activity line, and a row that draws nothing must not be in
    /// the list at all: the transcript's display window, its "N older
    /// rows" count and the find engine all count rows, so invisible ones
    /// would spend the window on nothing. A turn opens at a message the
    /// user sent — a notice in the user column opens none, nor does an
    /// answer steered into a turn already running.
    static func keepingThoughts(_ items: [AgentSessionHistoryItem],
                                inTurns chatOnlyTurns: Set<String>)
    -> [AgentSessionHistoryItem] {
        var keep = false
        var out: [AgentSessionHistoryItem] = []
        out.reserveCapacity(items.count)
        for item in items {
            switch item.kind {
            case .userText where !item.isSystemNotice && !item.sentIntoTurn:
                keep = item.recordUuid.map(chatOnlyTurns.contains) ?? false
                out.append(item)
            case .thinking:
                if keep { out.append(item) }
            default:
                out.append(item)
            }
        }
        return out
    }
}

/// Whether agent sessions are drawn compact (Settings → Display, the
/// toolbar's window, View → Agent Session Compact View), for the code that
/// reads a turn: the live parsers, the readers of a turn run elsewhere and
/// the agents' front ends keep a thought where compact view can draw it,
/// and no thought where it cannot.
///
/// Set by `AgentManager` from the display setting, and read from the
/// queues those readers run on, so it is guarded. A thought kept or left
/// out here only decides what a turn's rows hold while it runs: a reopen
/// reads the transcript again with the setting as it stands.
enum CompactTranscript {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var on = false

    static var isOn: Bool {
        lock.lock(); defer { lock.unlock() }
        return on
    }

    static func set(_ value: Bool) {
        lock.lock(); on = value; lock.unlock()
    }
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
    /// Custom group the resulting session is filed into, for a draft
    /// started from a group header's +. Nil for every other route.
    ///
    /// The filing itself happens in `AgentManager.migrateRunner`, when
    /// the session id arrives — the only moment a real key exists to
    /// file under, and one the view being torn down cannot cost.
    var customGroup: String?
    /// Set on the draft the SCHEDULER makes for a run: the task it is a
    /// run of, and the title the scanners will give it. The run is listed
    /// under its task from the instant it has a session id — its
    /// transcript names the task only once its first record is on disk,
    /// and until a scan reads that, the row would otherwise sit among the
    /// ordinary sessions.
    var scheduledRun: ScheduledRunIdentity?
    /// The skills chosen on the draft's chip — nil until the user
    /// chooses, when what its place holds stands
    /// (`AppState.newSessionSkillPicks`), else the agent's pinned skills
    /// (`ConfigManager.agentSkillPreloads`). Filed under the session id in
    /// `AgentManager.migrateRunner`, like `customGroup` and for the same
    /// reason.
    var skillPicks: [String]?
    /// The + the draft was started from — what it is remembered by.
    var place: NewSessionPlace
    /// The chips once its first message has gone: what that message went
    /// out with, and any change made since. Nil before — an unsent new
    /// session's chips are what its place starts with, under what was
    /// changed on it there (`AppState.newSessionChipEdits`).
    /// Kept on the draft, as `skillPicks` is, because what its place
    /// starts with may be another session's setup: a page built again
    /// before the session is named (Settings keeps the draft, and the
    /// switch to the session waits for the page) would show that, the
    /// switch would save it as the session's own picks, and a first turn
    /// that ends unnamed would put back the agent's Non-stop over its own.
    /// The manager files them as the session's picks when its id arrives
    /// (`AgentManager.noteSentDraft`, `migrateRunner`): the page may have
    /// moved on by then, and opening anything else drops the draft.
    var sentOptions: AgentLaunchOptions?

    struct ScheduledRunIdentity: Hashable {
        let taskName: String
        let title: String
    }

    init(cwd: URL, name: String? = nil, agentKey: String,
         customGroup: String? = nil, place: NewSessionPlace = .none) {
        self.id = UUID()
        self.cwd = cwd
        self.name = name
        self.agentKey = agentKey
        self.customGroup = customGroup
        self.place = place
    }
}

/// Where a new session was started from: a folder header's +, a custom
/// group's +, Ungrouped's, or the section's own "+ New session", which is
/// no group. Each place keeps its own unsent new session — the message,
/// attached files, schedule and skills set on it, and the chips changed
/// on it — the way each chat group keeps its own unsent new chat. Every
/// other chip starts from the place's own memory (the group's newest
/// session's; the agent's latest choices for no group); nothing starts
/// with another session's skills or a schedule. Every place sits in one
/// agent's section, so a place is per agent and nothing set up for one
/// agent turns up under another's +.
///
/// The + clicked decides the place — a custom group's + is that group's
/// place though its session also runs in a folder — and nothing moves it
/// afterwards but a rename of its custom group. A branch started as a new
/// session has a place of its own, so it neither takes nor leaves an
/// unsent message where a + would find it.
enum NewSessionPlace: Hashable {
    case none
    /// The folder's path, as the folder header keys it.
    case folder(String)
    /// The custom group's name. Groups are keyed by name.
    case custom(String)
    case ungrouped
    case branch(UUID)

    /// The key a new session started here files its unsent text, files,
    /// schedule, chips and skills under (`AppState.agentDraftKey`'s
    /// argument). The `new:` prefix keeps these apart from session ids.
    func draftKey(agentKey: String) -> String {
        switch self {
        case .none: return "new:\(agentKey):none"
        case .folder(let path): return "new:\(agentKey):folder:\(path)"
        case .custom(let name): return Self.customKeyPrefix(agentKey: agentKey) + name
        case .ungrouped: return "new:\(agentKey):ungrouped"
        case .branch(let id): return "new:branch:\(id.uuidString)"
        }
    }

    /// Every custom group's key for `agentKey` starts with this, the
    /// group's name after it.
    static func customKeyPrefix(agentKey: String) -> String {
        "new:\(agentKey):custom:"
    }

    /// The place of a + that does not name one itself — every + but a
    /// folder header's: its custom group, else Ungrouped while the
    /// sessions are grouped by Custom (where a session filed nowhere is
    /// listed), else no group at all.
    static func of(customGroup: String?, groupedByCustom: Bool) -> NewSessionPlace {
        if let group = customGroup { return .custom(group) }
        return groupedByCustom ? .ungrouped : .none
    }

    /// The session a new session started here takes its chips from: the
    /// newest one in this group — by its last user message, as the
    /// sidebar dates its rows — whose setup SipAI has on record
    /// (`hasSetup`). A session only ever run in a terminal has none, and
    /// the next one answers. Nil for a place that is no group, and for a
    /// group holding no such session: the caller falls back to the
    /// agent's latest choices.
    ///
    /// Membership is the sidebar's own (`AgentSessionGrouping.buckets`): a
    /// folder by its standardized path, a custom group by an assignment
    /// naming a group that still exists, Ungrouped for every other
    /// session. `sessions` are one agent's regular sessions (scheduled runs
    /// are not); only the ones the user started count — a spawned subagent
    /// or an automation is passed over.
    func newestSession(among sessions: [AgentSession],
                       customGroups: [String],
                       assignments: [String: String],
                       hasSetup: (String) -> Bool) -> AgentSession? {
        func belongs(_ session: AgentSession) -> Bool {
            switch self {
            case .folder(let path):
                return session.projectPath?.standardizedFileURL.path == path
            case .custom(let name):
                return assignments[session.id] == name && customGroups.contains(name)
            case .ungrouped:
                guard let name = assignments[session.id] else { return true }
                return !customGroups.contains(name)
            case .none, .branch:
                return false
            }
        }
        return sessions
            .filter { $0.origin == .user && belongs($0) }
            .sorted { $0.activityAt > $1.activityAt }
            .first { hasSetup($0.id) }
    }

    /// The setup a new session started here starts its chips from: that
    /// of the newest session in this group (`newestSession`), a new
    /// session whose first message has gone counted from that moment
    /// (`UnnamedNewSession`) — and the session it was read off, nil for
    /// one with no session id yet. Its row and its picks come with its
    /// id, seconds after the message went; a + clicked in between would
    /// otherwise start from the session before it. Nil where nothing
    /// answers: the caller falls back to the agent's latest choices.
    func startingSetup(among sessions: [AgentSession],
                       unnamed: [UnnamedNewSession],
                       customGroups: [String],
                       assignments: [String: String],
                       setup: (String) -> AgentLaunchOptions?)
    -> (options: AgentLaunchOptions, session: AgentSession?)? {
        let waiting = Dictionary(unnamed.map { ($0.row.id, $0) }, uniquingKeysWith: { a, _ in a })
        var filed = assignments
        for new in unnamed { filed[new.row.id] = new.draft.customGroup }
        guard let newest = newestSession(
            among: sessions + unnamed.map(\.row), customGroups: customGroups,
            assignments: filed,
            hasSetup: { waiting[$0]?.draft.sentOptions != nil || setup($0) != nil })
        else { return nil }
        if let sent = waiting[newest.id]?.draft.sentOptions { return (sent, nil) }
        return setup(newest.id).map { ($0, newest) }
    }
}

/// A new session whose first message has gone and whose session id has
/// not come yet (`AgentManager.unnamedNewSessions`), as the page that
/// sent it last left it. It has no row and no picks on record until the
/// id arrives — but it is its group's newest session from the moment its
/// message went.
struct UnnamedNewSession {
    let draft: ClaudeSessionDraft
    /// When its first message went.
    let sentAt: Date

    /// The row it will be: in the draft's folder, dated by its message,
    /// and filed under the draft's custom group when the id arrives
    /// (`AgentManager.migrateRunner`). Its id is the draft's runner key,
    /// which no session id can be.
    var row: AgentSession {
        AgentSession(id: "draft:\(draft.id.uuidString)", fileURL: draft.cwd, title: "",
                     modifiedAt: sentAt, lastUserMessageAt: sentAt, projectPath: draft.cwd,
                     agentKey: draft.agentKey)
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
    /// `read` is the per-format extractor (claude JSONL, codex rollout,
    /// kimi wire), passed by every scanner: the formats never name the
    /// same path, so one cache serves them all.
    static func cachedLastUserMessageDate(
        of url: URL,
        size: UInt64,
        mtime: Date,
        read: (URL) -> Date?
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
                        of: url, size: size, mtime: mtime,
                        read: { lastTurnStartDate(of: $0) }),
                    // The transcript's own `cwd` is authoritative — the
                    // encoded dirname can't distinguish "-" from "/",
                    // space, or "." ("My App" decodes as "My/App").
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

    /// How claude's own record of a stopped turn begins — a user-role
    /// record nobody typed.
    static let interruptionPrefix = "[Request interrupted"

    /// `byteBudget` overrides the tail size for callers that need the
    /// WHOLE conversation rather than the newest slice — global search
    /// indexing, and the find bar's "search the whole session". It stays
    /// a bound (never "read it all"): a budget is what keeps a
    /// pathological transcript from being pulled into memory entire.
    ///
    /// `includeThinking` keeps the thinking blocks that carry text, as
    /// `.thinking` rows: every one while compact view is on, and for a
    /// session with Chat only turns in it, where the caller then applies
    /// `AgentSessionHistoryItem.keepingThoughts`. Everything else reads
    /// without them.
    static func readHistory(of url: URL, maxTurns: Int = 50,
                            byteBudget: Int? = nil,
                            includeThinking: Bool = false) -> [AgentSessionHistoryItem] {
        readHistoryReaching(of: url, maxTurns: maxTurns, byteBudget: byteBudget,
                            includeThinking: includeThinking).items
    }

    /// `readHistory`, and whether its window reached the file's start
    /// (`conversationTail`): what "Show earlier" offers more on.
    static func readHistoryReaching(of url: URL, maxTurns: Int = 50,
                                    byteBudget: Int? = nil,
                                    includeThinking: Bool = false)
    -> (items: [AgentSessionHistoryItem], reachedStart: Bool) {
        // Lossy decode + bounded tail. STRICT decoding returns nil —
        // an EMPTY transcript for the whole session — whenever a
        // snapshot of a file another claude is MID-WRITING ends inside
        // a multibyte character. A partial edge line just fails JSON
        // parsing and is skipped, exactly like the stream readers.
        guard let tail = conversationTail(of: url,
                                          budget: byteBudget ?? Self.historyByteBudget)
        else {
            return ([], true)
        }
        let text = tail.text
        var items: [AgentSessionHistoryItem] = []
        var skillLoads = ClaudeSkillLoadReader()
        var seenRecords = Set<String>()
        var conversation = ClaudeConversationLine()

        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
            else { return }
            conversation.note(obj)

            // The record's own id, carried onto every item it produces —
            // the handle a transcript row needs to point back at its
            // line in the file (see `AgentSessionHistoryItem.recordUuid`
            // and `AgentSessionFork`).
            let recordUuid = obj["uuid"] as? String
            // One record, one row. Claude writes a message's user record a
            // second time, under the same uuid, when it compacts right
            // before sending that message, as it does for a message sent
            // again after "Prompt is too long". Drawn twice, the message
            // would appear once more on reopen than it did live.
            if let uuid = recordUuid, !seenRecords.insert(uuid).inserted { return }

            switch obj["type"] as? String ?? "" {
            case "user":
                let msg = obj["message"] as? [String: Any] ?? [:]
                let content = msg["content"]
                // A user record with `toolUseResult` is the model feeding
                // itself a tool's output, not a real user message.
                // NSNull-safe: JSON null must read as absent.
                if obj["toolUseResult"] != nil,
                   !(obj["toolUseResult"] is NSNull) {
                    items.append(contentsOf: skillLoads.flush())
                    items.append(parseToolResult(
                        userContent: content,
                        fallback: obj["toolUseResult"],
                        recordUuid: recordUuid
                    ))
                    return
                }
                let raw = content ?? obj["content"] ?? ""
                let rawText = extractText(fromContent: raw)
                // A skill being loaded: the command record and the text
                // claude expands it into. Neither is a row of its own —
                // see `ClaudeSkillLoadReader`.
                let step = skillLoads.consume(record: obj, rawText: rawText)
                items.append(contentsOf: step.rows)
                if step.absorbed { return }
                // A `!` command, as claude's terminal keeps one and as SipAI
                // hands it over: the input row is the user's row, the output
                // row is drawn under it.
                if let shell = ClaudeShellCommand.rows(fromContent: raw) {
                    items.append(contentsOf: skillLoads.flush())
                    for row in shell {
                        switch row {
                        case .command(let command):
                            var item = AgentSessionHistoryItem(
                                kind: .userText(ShellCommandInput.display(command)), recordUuid: recordUuid)
                            item.shellCommand = true
                            items.append(item)
                        case .output(let output):
                            items.append(AgentSessionHistoryItem(kind: .shellOutput(output),
                                                                 recordUuid: recordUuid))
                        }
                    }
                    return
                }
                // A background task's notification is drawn in the words
                // the live feed drew it in, never as the tag-stripped
                // inside of the record (ids, a temp path, a note to the
                // model).
                let taskNotice = ClaudeTaskNotice.saved(rawText) {
                    Self.toolCallDescription($0, in: items)
                }
                let cleaned = taskNotice ?? cleanUserText(rawText)
                // Inlined attachments: the names come off the RAW text,
                // before the strip inside `cleanUserText` removes the
                // blocks they ride in.
                let attached = AttachmentInline.names(in: rawText)
                if !cleaned.isEmpty || !attached.isEmpty {
                    // A compaction summary is a user-role record that
                    // the user never wrote — labelled like a harness
                    // notice, and for the same reason.
                    let isSummary = (obj["isCompactSummary"] as? Bool) == true
                    let isNotice = isHarnessNotice(rawText) || isSummary
                    var item = AgentSessionHistoryItem(
                        kind: .userText(cleaned), recordUuid: recordUuid,
                        isSystemNotice: isNotice)
                    item.attachedFiles = attached
                    // A background task reporting back is part of the
                    // agent's answer, not a message of the user's.
                    item.belongsToAnswer = taskNotice != nil
                    // Loads ride the user's next MESSAGE. A notice is not
                    // one, and neither is claude's own record of a stop
                    // ("[Request interrupted by user]") — a skill typed
                    // alone and stopped keeps its own row.
                    if isNotice || cleaned.hasPrefix(Self.interruptionPrefix) {
                        items.append(contentsOf: skillLoads.flush())
                    } else if (obj["isMeta"] as? Bool) != true {
                        skillLoads.attach(to: &item)
                    }
                    items.append(item)
                }

            case "assistant":
                items.append(contentsOf: skillLoads.flush())
                let msg = obj["message"] as? [String: Any] ?? [:]
                let content = msg["content"]
                // A `!` command claude did not answer: its rows went in with
                // no model request, and claude closed them with this line.
                // Bookkeeping, not words of claude's.
                if (msg["model"] as? String) == "<synthetic>",
                   let last = items.last, case .shellOutput = last.kind,
                   extractText(fromContent: content ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines) == ClaudeShellCommand.noResponseText {
                    return
                }
                // `<synthetic>` marks text the HARNESS produced and no
                // model ever said — a usage-limit notice, "No response
                // requested.", a failed-auth line. The live feeds label
                // it a system notice, so the reload has to as well or
                // the same row changes speaker when history takes over.
                items.append(contentsOf: parseAssistantBlocks(
                    content, recordUuid: recordUuid,
                    isSynthetic: (msg["model"] as? String) == "<synthetic>",
                    includeThinking: includeThinking))

            case "system":
                items.append(contentsOf: skillLoads.flush())
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
                    return
                }
                // The other system record that renders: the agent
                // summarised the conversation and carried on. Without
                // it the summary appears mid-turn with nothing saying
                // where it came from, and the context chip's drop has
                // no explanation. Note the camelCase spelling — the
                // stream writes the same metadata snake_cased.
                if (obj["subtype"] as? String) == "compact_boundary" {
                    let meta = (obj["compactMetadata"] as? [String: Any]) ?? [:]
                    // Absent and zero are the same thing here: a row
                    // must not state "0 tokens".
                    func positive(_ v: Any?) -> Int? {
                        guard let n = (v as? NSNumber)?.intValue, n > 0
                        else { return nil }
                        return n
                    }
                    items.append(AgentSessionHistoryItem(
                        kind: .compaction(preTokens: positive(meta["preTokens"]),
                                          postTokens: positive(meta["postTokens"])),
                        recordUuid: recordUuid))
                }

            case "attachment":
                // A message the user sent into the turn while it worked,
                // handed to the model with the next step: claude keeps it
                // as a queued command, not a user record. The user's
                // words, opening no turn of its own.
                if let prompt = queuedPrompt(obj) {
                    let cleaned = cleanUserText(prompt)
                    let attached = AttachmentInline.names(in: prompt)
                    guard !cleaned.isEmpty || !attached.isEmpty else { return }
                    items.append(contentsOf: skillLoads.flush())
                    var item = AgentSessionHistoryItem(kind: .userText(cleaned),
                                                       recordUuid: recordUuid)
                    item.attachedFiles = attached
                    item.sentIntoTurn = true
                    items.append(item)
                    return
                }
                // A background task's notification that reached the model
                // mid-turn, carried by the next request: claude keeps it
                // as a queued command, and the live feed drew it — in the
                // turn, opening none.
                guard let notice = queuedTaskNotice(obj, description: {
                    Self.toolCallDescription($0, in: items)
                }) else { return }
                items.append(contentsOf: skillLoads.flush())
                var item = AgentSessionHistoryItem(
                    kind: .userText(notice), recordUuid: recordUuid,
                    isSystemNotice: true)
                item.sentIntoTurn = true
                item.belongsToAnswer = true
                items.append(item)

            default:
                break  // "result", unknown types — silently skipped
            }
        }
        items.append(contentsOf: skillLoads.flush())
        // Every row carries the record it came from, so a turn a rewind
        // dropped leaves with its rows (`ClaudeConversationLine`).
        let dropped = conversation.dropped()
        if !dropped.isEmpty {
            items.removeAll { $0.recordUuid.map(dropped.contains) ?? false }
        }

        // Turn-based cap: count only user-text items so a 50-turn limit
        // isn't eaten by a single heavy tool-use turn's 40+ items.
        let userIndices = items.enumerated().compactMap { i, it -> Int? in
            if case .userText = it.kind { return i }
            return nil
        }
        if userIndices.count <= maxTurns { return (items, tail.reachedStart) }
        let startIdx = userIndices[userIndices.count - maxTurns]
        return (Array(items[startIdx...]), tail.reachedStart)
    }

    /// Read the last `budget` bytes of a file (or all of it when
    /// smaller), lossy-decoded. Newest-value scans must be bounded —
    /// these run on every session open and turn end, and session
    /// JSONLs grow into the hundreds of MB. Lossy on purpose: reads
    /// race live writers, and a strict decode fails WHOLE on a
    /// mid-character edge instead of losing one edge line.
    ///
    /// A compressed session file (`SessionFileCompression`) is read as
    /// the text it holds: there is no seeking into a zstd frame, so the
    /// whole file is decoded and only its last `budget` bytes are kept.
    static func boundedTail(of url: URL, budget: Int = 256 * 1024) -> String? {
        if SessionFileCompression.isCompressed(url) {
            // Codex unpacks a rollout the moment it loads the thread
            // again, and the text is then the plain file's.
            let unpacked = SessionFileCompression.unpacked(url)
            if FileManager.default.fileExists(atPath: unpacked.path) {
                return boundedTail(of: unpacked, budget: budget)
            }
            return compressedTail(of: url, budget: budget)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            // Packed since the URL was read.
            return compressedTail(of: url, budget: budget)
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

    /// `boundedTail` of a file that is compressed, or that codex has
    /// packed or unpacked since its URL was read (`SessionFileReader
    /// .open` follows it). Nil when there is nothing to read.
    private static func compressedTail(of url: URL, budget: Int) -> String? {
        guard let reader = SessionFileReader.open(url) else { return nil }
        defer { reader.close() }
        let keep = max(budget, 0)
        var tail = Data()
        while true {
            let chunk = reader.read(upToCount: 1 << 20)
            if chunk.isEmpty { break }
            tail.append(chunk)
            // Trimmed in slices, never per chunk: dropping the front
            // copies what stays.
            if tail.count > keep * 2 + (1 << 20) {
                tail.removeFirst(tail.count - keep)
            }
        }
        if tail.count > keep { tail = Data(tail.suffix(keep)) }
        return String(decoding: tail, as: UTF8.self)
    }

    /// The first `count` bytes of a session file's text (all of it when
    /// smaller) — decoded, for a compressed one. Nil when the file
    /// cannot be read.
    static func head(of url: URL, count: Int) -> Data? {
        guard let reader = SessionFileReader.open(url) else { return nil }
        defer { reader.close() }
        var data = Data()
        while data.count < count {
            let chunk = reader.read(upToCount: count - data.count)
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }

    /// How many bytes of text a session file holds: its size on disk,
    /// or what a compressed one decodes to — the size its frame states
    /// (codex's do), else counted by decoding it. What a bounded read is
    /// judged against ("was the whole file read?") and what a byte offset
    /// into the text is measured in.
    static func contentSize(of url: URL) -> UInt64? {
        if !SessionFileCompression.isCompressed(url),
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
            as? NSNumber {
            return size.uint64Value
        }
        guard let reader = SessionFileReader.open(url) else { return nil }
        defer { reader.close() }
        if let size = reader.textSize { return size }
        var total: UInt64 = 0
        while true {
            let chunk = reader.read(upToCount: 1 << 20)
            if chunk.isEmpty { break }
            total += UInt64(chunk.count)
        }
        return total
    }
    /// The newest `budget` bytes of a claude transcript's CONVERSATION,
    /// lossy-decoded, and whether the walk reached the file's start.
    ///
    /// Claude also writes each API request it makes into the transcript —
    /// its system prompt, tools and parameters, as `api-request`,
    /// `api-request-blob` and `api-request-shape` records, each line
    /// opening with `{"type":"api-request`. They are no part of the
    /// conversation (no `uuid`, nothing hangs off them), and at the end of
    /// a long session they can outweigh it nine to one: counted against a
    /// window, they push the session's prompts, its newest
    /// `permissionMode` and its newest usage out of every bounded read. So
    /// this walk goes back from the end a chunk at a time, drops those
    /// lines by their first bytes (no parse), keeps whole lines until
    /// `budget` bytes of everything else are in hand, and reads at most
    /// sixteen times the budget of the file — enough for that ratio, and
    /// still a bound. The newest line may be a live writer's half line;
    /// it fails JSON parsing downstream, as with `boundedTail`.
    ///
    /// `reachedStart` false means older conversation may sit above the
    /// window: the partiality verdict a transcript's "Show earlier" needs,
    /// which the file's size can no longer give (most of a long file may
    /// be records the window never had to hold).
    static func conversationTail(of url: URL, budget: Int)
    -> (text: String, reachedStart: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let ceiling = UInt64(max(budget, 1)) * 16
        let chunkSize: UInt64 = 1 << 20
        var position = size
        var readBytes: UInt64 = 0
        // The bytes of the oldest line seen so far, whose start lies
        // before `position` (not read yet).
        var pending = Data()
        // Newest first; each a copy, so no chunk outlives its pass.
        var kept: [Data] = []
        var keptBytes = 0

        /// Keeps a conversation line; false once the budget is in hand.
        func take(_ line: Data) -> Bool {
            if line.isEmpty || isRequestRecord(line) { return true }
            kept.append(line.withUnsafeBytes { Data($0) })
            keptBytes += line.count + 1
            return keptBytes < budget
        }

        var full = false
        while position > 0, !full, readBytes < ceiling {
            let count = min(chunkSize, position)
            position -= count
            try? handle.seek(toOffset: position)
            guard var chunk = try? handle.read(upToCount: Int(count)) else { return nil }
            readBytes += UInt64(chunk.count)
            chunk.append(pending)
            // Whole lines newest first; the piece before the first
            // newline starts further back and waits for the next chunk.
            // The newline search is Foundation's own: a collection walk
            // over `Data` goes through its representation per byte, and
            // in a build without optimisation that cost the sidebar's
            // whole-store scan nine times its old length.
            var end = chunk.endIndex
            while let found = chunk.range(of: Self.newlineByte, options: .backwards,
                                          in: chunk.startIndex..<end) {
                let newline = found.lowerBound
                if !take(chunk[(newline + 1)..<end]) { full = true; break }
                end = newline
            }
            pending = chunk[chunk.startIndex..<end].withUnsafeBytes { Data($0) }
        }
        var reachedStart = false
        if !full, position == 0 {
            // The file's first line, with no newline above it.
            _ = take(pending)
            reachedStart = true
        }
        // Appended, never a joined sequence read byte by byte.
        var text = Data(capacity: keptBytes)
        for (index, line) in kept.reversed().enumerated() {
            if index > 0 { text.append(0x0A) }
            text.append(line)
        }
        return (String(decoding: text, as: UTF8.self), reachedStart)
    }

    /// Whether a transcript line is one of claude's request records
    /// (`conversationTail`): each opens `{"type":"api-request`, the
    /// `-blob` and `-shape` kinds included. Read off the first bytes, so
    /// the biggest lines claude writes are never parsed to be thrown away.
    static func isRequestRecord(_ line: Data) -> Bool {
        line.prefix(64).range(of: requestRecordMarker) != nil
    }

    private static let requestRecordMarker = Data(#"{"type":"api-request"#.utf8)
    private static let newlineByte = Data([0x0A])

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
    -> (permissionMode: String?, model: String?, effort: String?, fastMode: Bool?) {
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
        // stop once a window held the whole conversation; most sessions
        // never pay for the second pass. The windows count conversation
        // (`conversationTail`): claude's request records between a
        // turn's opening record and EOF are what pushed it out of them.
        var found: (permissionMode: String?, model: String?, effort: String?,
                    fastMode: Bool?) = (nil, nil, nil, nil)
        for budget in [256 * 1024, 4 * 1024 * 1024] {
            guard let tail = conversationTail(of: url, budget: budget) else { break }
            found = launchOptionsScan(tail.text)
            if found.permissionMode != nil || tail.reachedStart { break }
        }
        return found
    }

    private static func launchOptionsScan(_ text: String)
    -> (permissionMode: String?, model: String?, effort: String?, fastMode: Bool?) {
        var mode: String? = nil
        var model: String? = nil
        var effort: String? = nil
        // Whether the newest API call ran in fast mode: assistant
        // records carry `usage.speed` ("fast" / "standard") on claude
        // builds that know the mode, and nothing at all on older ones
        // — nil then, never false. Even false is an outcome, not a
        // choice (a refused call records standard), so the seed lets
        // only true move the switch (`ClaudeFastMode.seededSwitch`).
        var fast: Bool? = nil
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
                if fast == nil,
                   let usage = msg["usage"] as? [String: Any],
                   let speed = usage["speed"] as? String, !speed.isEmpty {
                    fast = (speed == "fast")
                }
            }
        }
        return (mode, model, effort, fast)
    }

    /// How full the context window is, read off a session's most recent
    /// main-loop assistant record: `usage.input_tokens +
    /// cache_creation + cache_read` — the INPUT side of that call, which
    /// is the whole conversation as the model last saw it. The call's
    /// own output is excluded for the reason given on
    /// `AgentEventParser.contextFootprint`: it is what claude's and
    /// kimi's own context indicators count, and counting the reply too
    /// would disagree with them.
    ///
    /// Seeds the composer's context chip when opening an existing
    /// session (live assistant events take over once a turn streams),
    /// and rides out with the model that produced it — the chip divides
    /// by a WINDOW, and a window belongs to a model — and with the speed
    /// that call ran at, the fast switch's outcome on reopen. Returns
    /// 0 / nil if the file is unreadable or no assistant record carries
    /// usage.
    static func lastContextTokens(of url: URL) -> (tokens: Int, model: String?, speed: String?) {
        // Conversation bytes only: a call still in flight has written
        // its request records after the newest answered call's usage.
        guard let text = conversationTail(of: url, budget: 256 * 1024)?.text else {
            return (0, nil, nil)
        }
        var last = 0
        var lastModel: String? = nil
        var lastSpeed: String? = nil
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
            // Mirrors AgentEventParser.contextFootprint — input side
            // only, and the two must never drift: they feed the same
            // chip, one from disk and one from the stream.
            let total = intField(usage["input_tokens"])
                + intField(usage["cache_creation_input_tokens"])
                + intField(usage["cache_read_input_tokens"])
            // The model rides the record that WON, the same rule as the
            // codex window and the kimi model: a mid-session model
            // switch moves the number and its window together or not at
            // all. Kept verbatim, `[1m]` included — that suffix names a
            // different window.
            if total > 0 {
                last = total
                lastModel = (msg["model"] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 }
                // What that call ran at — the fast switch's outcome as
                // the transcript keeps it (`ClaudeFastModeReport`).
                lastSpeed = (usage["speed"] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 }
            }
        }
        return (last, lastModel, lastSpeed)
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
        // standard window. Counted in conversation bytes
        // (`conversationTail`), as `lastLaunchOptions` counts them.
        for budget in [256 * 1024, 4 * 1024 * 1024] {
            guard let tail = conversationTail(of: url, budget: budget) else { break }
            let seconds = turnDurationScan(tail.text)
            if seconds > 0 || tail.reachedStart { return seconds }
        }
        return 0
    }

    private static func turnDurationScan(_ text: String) -> Double {
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
        //
        // On the way, every wait on the user that the transcript can
        // show is left out: the composer's clock held still through it
        // while the turn ran. A question and a plan handed over for
        // approval are calls that do nothing BUT wait for the user, so
        // the whole gap between the call's tool_use record and the
        // record carrying its result is the wait. Walking backwards, the
        // result is met first.
        //
        // A permission card's wait is not recoverable this way: the gap
        // around an ordinary tool call is the wait plus the tool's own
        // run, and nothing in the transcript says where one ends.
        var answeredAt: [String: Date] = [:]
        var waits: [(from: Date, to: Date)] = []
        var back = endIdx - 1
        while back >= 0 {
            let line = lines[back]
            let mayBeUser = line.contains("\"user\"")
            let mayAsk = userWaitTools.contains { line.contains("\"\($0)\"") }
            if mayBeUser || mayAsk, let obj = object(line) {
                let type = obj["type"] as? String
                if type == "user" {
                    if isTurnStartUser(obj), let start = isoDate(obj["timestamp"]) {
                        let seconds = end.timeIntervalSince(start) - unionLength(of: waits)
                        return seconds > 0 ? seconds : 0
                    }
                    if let at = isoDate(obj["timestamp"]) {
                        for id in toolResultIds(in: obj) { answeredAt[id] = at }
                    }
                } else if type == "assistant", mayAsk, let asked = isoDate(obj["timestamp"]) {
                    for id in userWaitToolUseIds(in: obj) {
                        if let at = answeredAt[id], at > asked {
                            waits.append((asked, at))
                        }
                    }
                }
            }
            back -= 1
        }
        return 0
    }

    /// The calls whose whole life is a wait on the user: claude's
    /// question tool, and the call that hands a plan over for approval.
    private static let userWaitTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// How long the given waits cover between them. Two that overlap are
    /// one stretch of waiting, not two — the live clock stops once while
    /// any card is up.
    private static func unionLength(of waits: [(from: Date, to: Date)]) -> TimeInterval {
        var total: TimeInterval = 0
        var covered: Date? = nil
        for wait in waits.sorted(by: { $0.from < $1.from }) {
            let from = max(wait.from, covered ?? wait.from)
            if wait.to > from {
                total += wait.to.timeIntervalSince(from)
                covered = wait.to
            }
        }
        return total
    }

    /// The tool calls a user record answers — its `tool_result` blocks.
    private static func toolResultIds(in obj: [String: Any]) -> [String] {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { block in
            block["type"] as? String == "tool_result" ? block["tool_use_id"] as? String : nil
        }
    }

    /// The calls in an assistant record that only wait on the user
    /// (`userWaitTools`).
    private static func userWaitToolUseIds(in obj: [String: Any]) -> [String] {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { block in
            guard block["type"] as? String == "tool_use",
                  let name = block["name"] as? String, userWaitTools.contains(name) else { return nil }
            return block["id"] as? String
        }
    }

    /// A real user prompt: not a subagent record, not a `tool_result`
    /// round-trip, not a meta/system-injected record.
    private static func isTurnStartUser(_ obj: [String: Any]) -> Bool {
        guard obj["type"] as? String == "user",
              (obj["isSidechain"] as? Bool) != true,
              (obj["isMeta"] as? Bool) != true,
              // A compaction summary is written as a user record in the
              // middle of a turn. Counted as a turn start it re-times
              // the sidebar row (`activityAt`) and the composer's clock
              // for an external turn to the moment the agent summarised
              // itself.
              (obj["isCompactSummary"] as? Bool) != true else { return false }
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
        for budget in [256 * 1024, 4 * 1024 * 1024] {
            guard let tail = conversationTail(of: url, budget: budget) else { break }
            if let found = turnStartScan(tail.text) { return found }
            if tail.reachedStart { break }
        }
        return nil
    }

    private static func turnStartScan(_ text: String) -> Date? {
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
            // liveness check. A message of attached files alone is the
            // user's, words or not.
            let msg = obj["message"] as? [String: Any] ?? [:]
            let rawText = extractText(fromContent: msg["content"] ?? "")
            let text = cleanSessionMetaText(rawText)
            guard !text.isEmpty || !AttachmentInline.names(in: rawText).isEmpty,
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
        guard let text = conversationTail(of: url, budget: 256 * 1024)?.text else { return false }
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
                                             isSynthetic: Bool = false,
                                             includeThinking: Bool = false)
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
            case "thinking" where includeThinking:
                // Mirrors `AgentEventParser.parseAssistant`: an empty
                // block is thinking the API left out, with nothing to draw.
                if let raw = dict["thinking"] as? String {
                    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        out.append(AgentSessionHistoryItem(kind: .thinking(t),
                                                           recordUuid: recordUuid))
                    }
                }
            default:
                break  // anything else we don't surface
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

    /// The head read again, wider, for a session whose first window ends
    /// before its first message. A turn that loads skills opens with
    /// them — each one's whole text, ahead of the prompt — and several
    /// long ones fill the ordinary window: the prompt then sits past it,
    /// and with it the marker that files a scheduled run under its task
    /// and the words the session is named by.
    private static let inspectWideBudget = 4 * 1024 * 1024

    /// Internal, not private: the harness reads real transcripts through
    /// it (`Verification/Skills`).
    static func inspectSession(from url: URL, decodedProjectPath: URL?)
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
            // Conversation bytes: the newest title can sit behind more
            // request records than the window holds.
            tailText = conversationTail(of: url, budget: Self.inspectByteBudget)?.text ?? ""
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
        // A typed skill command with arguments (`/review-pr the auth
        // module`), held until the next record shows it WAS a skill —
        // and the `promptId` of the command record just read, which the
        // text it expands into carries too.
        var heldSkillTitle: String? = nil
        var heldCommandPrompt: String? = nil
        func scan(_ text: String) {
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
                let isMeta = (obj["isMeta"] as? Bool) == true
                // A skill's expanded text is the skill, not anything the
                // user said: never a title, and it carries no marker. It
                // does settle a held command: that one was a skill, typed
                // with words the session can be named by.
                if SkillRecords.isClaudeExpansion(obj, text: pick,
                                                  afterCommandPrompt: heldCommandPrompt) {
                    if let title = heldSkillTitle {
                        result = title
                        stop = true
                    }
                    return
                }
                heldSkillTitle = nil
                let command = isMeta ? nil : SkillRecords.claudeCommand(in: pick)
                heldCommandPrompt = command == nil ? nil : (obj["promptId"] as? String)
                // The scheduled-task marker rides the prompt, which skills a
                // run loads go AHEAD of — so a command record is not the
                // record that answers whether this is a run.
                if !checkedFirstUserRecord, !isMeta, command == nil {
                    scheduledTaskName = extractScheduledTaskName(from: pick)
                    checkedFirstUserRecord = true
                }
                // A session opened by a `!` command is named as its row
                // reads (`!ls`) — what codex's and kimi's readers name it —
                // never by what the command printed.
                if let shell = ClaudeShellCommand.rows(fromContent: raw) {
                    guard case .command(let line)? = shell.first else { return }
                    result = Self.collapsedTitle(ShellCommandInput.display(line))
                    stop = true
                    return
                }
                guard !pick.isEmpty else { return }
                if let command, !command.args.isEmpty {
                    let typed = cleanSessionMetaText(command.args)
                    if !typed.isEmpty {
                        heldSkillTitle = Self.collapsedTitle("/" + command.name + " " + typed)
                    }
                }
                // Title derivation uses the META cleaner: a session whose
                // first record is a slash command must fall through to the
                // next real message, not be named "/clear clear".
                let cleaned = cleanSessionMetaText(pick)
                guard !cleaned.isEmpty else { return }
                result = Self.collapsedTitle(cleaned)
                // With an ai-title in hand only the scheduled-task marker
                // and cwd were still needed — both live in the first
                // records, which have now been seen. Stopping here can
                // leave cwd nil only if no head record carried one, and
                // then the decode fallback covers it.
                stop = true
            }
        }
        scan(text)
        // The window ended inside the commands a session opens with — no
        // message of the user's reached yet, and more file to read: the
        // head is read again, wider. Only a session that OPENS on
        // commands pays for it, and only until its first message is in
        // the ordinary window's reach.
        if !checkedFirstUserRecord, result == nil, firstCommandName != nil,
           size > UInt64(Self.inspectByteBudget) {
            try? handle.seek(toOffset: 0)
            let wide = (try? handle.read(upToCount: Self.inspectWideBudget)) ?? Data()
            heldSkillTitle = nil
            heldCommandPrompt = nil
            scan(String(decoding: wide, as: UTF8.self))
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

    /// The title a session opened by `prompt` will be listed under before
    /// the agent names it: tags stripped, whitespace collapsed, 50
    /// characters at most — the rule all three scanners apply to a first
    /// message. What a scheduled run is called from the instant it
    /// starts, so its row does not change name when the scan catches up.
    static func title(fromPrompt prompt: String) -> String? {
        let collapsed = collapsedTitle(cleanUserText(prompt))
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Already-cleaned text as a title: whitespace collapsed, 50
    /// characters at most.
    private static func collapsedTitle(_ cleaned: String) -> String {
        let collapsed = cleaned
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return collapsed.count > 50 ? String(collapsed.prefix(47)) + "..." : collapsed
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

    fileprivate static func strippingANSI(_ text: String) -> String {
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
        // Inlined attachment blocks FIRST, matched as a pair: the
        // generic `<[^>]+>` sweep below would eat the block's tags and
        // leave the whole file's contents standing in the bubble. The
        // names the paperclip line prints are read off the raw text by
        // the caller before this runs.
        stripWrappers(AttachmentInline.stripping(text), patterns: [
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
    /// The words of a message the user sent into a turn while it worked,
    /// as claude keeps it once the next step carried it to the model: a
    /// queued-command attachment in `prompt` mode (a background task's
    /// notification rides the same record in `task-notification` mode).
    /// nil for any other attachment.
    static func queuedPrompt(_ record: [String: Any]) -> String? {
        guard let attachment = record["attachment"] as? [String: Any],
              attachment["type"] as? String == "queued_command",
              attachment["commandMode"] as? String == "prompt",
              let prompt = attachment["prompt"] as? String
        else { return nil }
        return prompt
    }

    /// The notice of a background task's notification claude kept as a
    /// queued-command attachment — the one it handed the model with a
    /// request mid-turn — or nil for any other attachment.
    static func queuedTaskNotice(_ record: [String: Any],
                                 description: (String) -> String?) -> String? {
        guard let attachment = record["attachment"] as? [String: Any],
              attachment["type"] as? String == "queued_command",
              attachment["commandMode"] as? String == "task-notification",
              let prompt = attachment["prompt"] as? String
        else { return nil }
        return ClaudeTaskNotice.saved(prompt, description: description)
    }

    /// The description the tool call `toolUseId` was given, newest first
    /// among the rows read so far: what names a background task in its
    /// notice.
    static func toolCallDescription(_ toolUseId: String,
                                    in items: [AgentSessionHistoryItem]) -> String? {
        for item in items.reversed() {
            if case .toolUse(let id, _, let input) = item.kind, id == toolUseId {
                return input["description"] as? String
            }
        }
        return nil
    }

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
    /// wrappers is claude bookkeeping, not the user starting a turn). A
    /// `!` command's output goes with its tags the same way: a session is
    /// titled by the command, never by what it printed, and the output
    /// alone starts no turn.
    static func cleanSessionMetaText(_ text: String) -> String {
        // Same first step as `cleanUserText`: a session whose first
        // message carried an attachment must not be TITLED by the file.
        stripWrappers(AttachmentInline.stripping(text), patterns: [
            "<scheduled-task[^>]*>[\\s\\S]*?</scheduled-task>",
            "<command-name>[\\s\\S]*?</command-name>",
            "<command-message>[\\s\\S]*?</command-message>",
            "<command-args>[\\s\\S]*?</command-args>",
            "<local-command-stdout>[\\s\\S]*?</local-command-stdout>",
            "<local-command-stderr>[\\s\\S]*?</local-command-stderr>",
            "<bash-stdout>[\\s\\S]*?</bash-stdout>",
            "<bash-stderr>[\\s\\S]*?</bash-stderr>",
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
            "<bash-stdout>[\\s\\S]*?</bash-stdout>",
            "<bash-stderr>[\\s\\S]*?</bash-stderr>",
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

/// The words a finished or stopped Claude Code background task is drawn
/// with — one rule for the live feed (claude's `system/task_notification`
/// on stdout, read by `ClaudeBackgroundTasks`) and for the transcript (the
/// `<task-notification>` record claude saves, read by
/// `AgentSessionScanner.readHistory` and the tailer), so a reopened session
/// says what the running one said. Drawn as a system notice: claude wrote
/// it, nobody typed it.
enum ClaudeTaskNotice {

    /// A command's notification carries claude's own sentence about the
    /// task ("Background command "Run the tests" completed (exit code
    /// 0)"), the same on stdout and in the saved record, and it is drawn
    /// as claude said it. Any other kind is named by the description of
    /// the tool call that started it, in SipAI's words: an agent's
    /// notification carries the agent's ANSWER on stdout where its saved
    /// record says `Agent "…" finished`, so neither is the same on both
    /// feeds. A summary that is only the description says no more than
    /// the description, and is put in a sentence too.
    static func text(status: String, summary: String?, kind: String?, description: String?) -> String {
        let said = (summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == "local_bash", !said.isEmpty, said != name { return said }
        let subject = name.isEmpty && kind == "local_bash" ? said : name
        switch status {
        case "completed":
            return subject.isEmpty
                ? String(localized: "A background task finished.",
                         comment: "Transcript notice: a background task the agent started has finished; its name is unknown")
                : String(localized: "Background task finished: \(subject)",
                         comment: "Transcript notice: a background task the agent started has finished; placeholder is the task's description")
        case "failed":
            return subject.isEmpty
                ? String(localized: "A background task failed.",
                         comment: "Transcript notice: a background task the agent started has failed; its name is unknown")
                : String(localized: "Background task failed: \(subject)",
                         comment: "Transcript notice: a background task the agent started has failed; placeholder is the task's description")
        default:
            return subject.isEmpty
                ? String(localized: "A background task was stopped.",
                         comment: "Transcript notice: a background task the agent started was stopped before it finished; its name is unknown")
                : String(localized: "Background task stopped: \(subject)",
                         comment: "Transcript notice: a background task the agent started was stopped before it finished; placeholder is the task's description")
        }
    }

    /// The notice a saved `<task-notification>` is drawn as, or nil when
    /// `raw` is not one. Claude saves it as a user record when it starts a
    /// turn of its own for the notification, and as a queued-command
    /// attachment when a request carried it mid-turn. A record holding the
    /// task's `<result>` is an agent's; `description` looks up the tool
    /// call that started the task (by its `<tool-use-id>`) where the
    /// reader has read it, and without that claude's own summary stands.
    ///
    /// One event of claude's Monitor tool — a line the watched command
    /// printed — reads as claude's own terminal draws it: the event's first
    /// line that says something, then the watch's description (`Monitor
    /// event: Build exit=0 12s · sweep results`). The description alone is
    /// the same sentence for every event of a watch. Claude escapes `&`,
    /// `<` and `>` in both, and the event is the command's own output,
    /// colours included; an event with a bare `<` is not one claude wrote,
    /// and claude's summary stands.
    static func saved(_ raw: String, description: (String) -> String?) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("<task-notification>") else { return nil }
        let monitorPrefix = "Monitor event: \""
        let collapsed: (Substring) -> String = { part in
            let words = part.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return words.count > 500 ? String(words.prefix(500)) + "…" : words
        }
        if let summary = element("summary", in: text).map(ClaudeShellCommand.unescape),
           summary.hasPrefix(monitorPrefix), summary.hasSuffix("\""), summary.count > monitorPrefix.count,
           let event = element("event", in: text), !event.contains("<"),
           let headline = AgentSessionScanner.strippingANSI(ClaudeShellCommand.unescape(event))
               .split(whereSeparator: \.isNewline).lazy.map(collapsed).first(where: { !$0.isEmpty }) {
            let watch = collapsed(summary.dropFirst(monitorPrefix.count).dropLast())
            return watch.isEmpty ? "Monitor event: \(headline)" : "Monitor event: \(headline) · \(watch)"
        }
        let status = element("status", in: text) ?? ""
        let summary = element("summary", in: text)
        guard !status.isEmpty || summary != nil else { return nil }
        let name = element("tool-use-id", in: text).flatMap(description)
        let isAgent = element("result", in: text) != nil
        if isAgent, name == nil, let summary, !summary.isEmpty { return summary }
        return Self.text(status: status, summary: summary,
                         kind: isAgent ? "local_agent" : "local_bash", description: name)
    }

    /// The text of the first `<tag>…</tag>` in `text`, trimmed.
    private static func element(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return text[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Which records of a claude transcript belong to turns a rewind dropped.
///
/// Claude never removes a record. Its transcript is a tree through
/// `parentUuid`, and a rewind — Esc Esc or `/rewind` in its terminal, or
/// `-p --resume-session-at` — parents the next message at the entry above
/// the edited one, leaving the replaced turns in the file as a branch
/// claude does not load again: it rebuilds the conversation by walking
/// back from its newest leaf. A reader that draws records in file order
/// therefore draws turns the agent no longer has.
///
/// The current line is the walk back from the newest record — or from
/// the leaf of a `last-prompt` marked `rewound` written after it, which
/// claude's terminal records when a rewind has not yet been followed by a
/// message — crossing a compaction through `logicalParentUuid`. A branch
/// off that line is dropped only when it holds a real prompt: a rewind
/// always cuts at a user message, and the line's other side branches
/// hold none (a parallel tool call's result is parented at its call,
/// beside the next call, and claude keeps it). A second ROOT holding a
/// prompt is dropped when the line itself reaches a root — a rewind to
/// before the first message. Within a bounded read, a branch whose fork
/// point lies above the window cannot be told apart and is kept.
struct ClaudeConversationLine {
    private struct Entry {
        let parent: String?
        let isPrompt: Bool
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var newest: String?
    private var rewoundLeaf: String?

    /// Feed one parsed record, in file order.
    mutating func note(_ obj: [String: Any]) {
        if obj["type"] as? String == "last-prompt" {
            if (obj["rewound"] as? Bool) == true,
               let leaf = obj["leafUuid"] as? String, !leaf.isEmpty {
                rewoundLeaf = leaf
            }
            return
        }
        guard let uuid = obj["uuid"] as? String, !uuid.isEmpty,
              (obj["isSidechain"] as? Bool) != true else { return }
        // A record written twice under one uuid (claude does it when it
        // compacts right before sending a message) keeps the links of its
        // LAST copy — claude's own map does the same.
        if entries[uuid] == nil { order.append(uuid) }
        entries[uuid] = Entry(parent: Self.entryAbove(obj), isPrompt: Self.isPrompt(obj))
        newest = uuid
        rewoundLeaf = nil
    }

    /// The record a record hangs off: its `parentUuid`, or across a
    /// compaction the `logicalParentUuid` the boundary keeps.
    static func entryAbove(_ obj: [String: Any]) -> String? {
        (obj["parentUuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (obj["logicalParentUuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The uuids off the current line, ending at `leaf` (default: the
    /// line claude would resume).
    func dropped(endingAt leaf: String? = nil) -> Set<String> {
        guard let start = leaf ?? rewoundLeaf.flatMap({ entries[$0] == nil ? nil : $0 }) ?? newest,
              entries[start] != nil else { return [] }
        var line = Set<String>()
        var top = start
        var cursor: String? = start
        while let c = cursor, let entry = entries[c], line.insert(c).inserted {
            top = c
            cursor = entry.parent
        }
        var children: [String: [String]] = [:]
        var roots: [String] = []
        for uuid in order {
            if let parent = entries[uuid]?.parent {
                children[parent, default: []].append(uuid)
            } else {
                roots.append(uuid)
            }
        }
        var dropped = Set<String>()
        var visited = line
        func dropIfPrompted(_ branch: String) {
            var stack = [branch]
            var members: [String] = []
            var prompted = false
            while let x = stack.popLast() {
                guard visited.insert(x).inserted else { continue }
                members.append(x)
                if entries[x]?.isPrompt == true { prompted = true }
                stack.append(contentsOf: children[x] ?? [])
            }
            if prompted { dropped.formUnion(members) }
        }
        for node in order where line.contains(node) {
            for child in children[node] ?? [] where !line.contains(child) {
                dropIfPrompted(child)
            }
        }
        // Only for a line that followed a link: a transcript whose writer
        // chains nothing has a root per record, and none of them is a
        // beginning a rewind left behind.
        if line.count > 1, entries[top]?.parent == nil {
            for root in roots where !line.contains(root) {
                dropIfPrompted(root)
            }
        }
        return dropped
    }

    /// A message the user sent: a user record that opens a turn — words,
    /// attached files, or a command they typed — and not a tool's result,
    /// a skill's expansion, a summary, a harness notice or claude's own
    /// record of a stop.
    static func isPrompt(_ obj: [String: Any]) -> Bool {
        guard obj["type"] as? String == "user",
              (obj["isMeta"] as? Bool) != true,
              (obj["isCompactSummary"] as? Bool) != true,
              obj["toolUseResult"] == nil || obj["toolUseResult"] is NSNull
        else { return false }
        let message = obj["message"] as? [String: Any] ?? [:]
        if let blocks = message["content"] as? [[String: Any]],
           blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
            return false
        }
        let raw = AgentSessionScanner.extractText(fromContent: message["content"] ?? obj["content"] ?? "")
        guard !AgentSessionScanner.isHarnessNotice(raw) else { return false }
        let text = AgentSessionScanner.cleanSessionMetaText(raw)
        if text.hasPrefix(AgentSessionScanner.interruptionPrefix) { return false }
        return !text.isEmpty
            || !AttachmentInline.names(in: raw).isEmpty
            || SkillRecords.claudeCommand(in: raw) != nil
    }
}

/// How a claude transcript's skill loads become rows, fed one user
/// record at a time by `AgentSessionScanner.readHistory`.
///
/// A loaded skill leaves two user records: the COMMAND (`<command-name>
/// /name</command-name>`, with `<command-args>` when it was given any)
/// and the text claude expands it into (`isMeta`, carrying the command's
/// own `promptId`; "Base directory for this skill: …" first when the
/// skill has a folder — a skill claude ships itself, and a command file,
/// expand into their text alone). The expanded text is never a row — it
/// is the skill, not anything anybody said, and it is often pages long.
/// The command's shape is only known once the NEXT user record is read:
/// a built-in command (`/mcp`, `/model`) writes no expanded text, so a
/// command record is HELD until then and, when it turns out not to have
/// expanded into anything, drawn exactly as before.
///
/// * A skill command WITHOUT arguments waits for the message it rode
///   in with. SipAI's skill chip sends each skill as its own message
///   ahead of the user's text (`SkillWire.claudeStdinLines`), so the
///   loads are followed by that text, which takes them as its
///   `loadedSkills` — the same line the live row drew. Its handle is the
///   FIRST load's record: a branch cut at the row takes the loads with
///   it, as it takes the message.
/// * Anything else ending the run of loads first — the model's answer,
///   a tool round-trip, the end of the file — means the user typed the
///   command alone, and it becomes a row of its own spelled as typed
///   (`/name`), which is what the live row said.
/// * A skill command WITH arguments is a message the user typed
///   (`/name args`), drawn in those words.
struct ClaudeSkillLoadReader {
    struct Step {
        var rows: [AgentSessionHistoryItem] = []
        /// The record was part of a skill load and must not be read as
        /// a message.
        var absorbed = false
    }

    private struct Held {
        let name: String
        let args: String
        let rawText: String
        let recordUuid: String?
        /// The command record's `promptId`, which the text it expands
        /// into carries too (`SkillRecords.isClaudeExpansion`).
        let promptId: String?
    }

    private var held: Held?
    private var loads: [(name: String, recordUuid: String?)] = []

    /// One user record that is not a tool result. `record` is the
    /// decoded line: what makes a record an expansion is what it carries,
    /// not how its text begins.
    mutating func consume(record: [String: Any], rawText: String) -> Step {
        let isMeta = (record["isMeta"] as? Bool) == true
        let recordUuid = record["uuid"] as? String
        if SkillRecords.isClaudeExpansion(record, text: rawText,
                                          afterCommandPrompt: held?.promptId) {
            guard let command = held else {
                // The model's own Skill call: its expanded text follows
                // the tool round-trip, which already drew the call.
                return Step(absorbed: true)
            }
            held = nil
            if command.args.isEmpty {
                loads.append((command.name, command.recordUuid))
                return Step(absorbed: true)
            }
            var step = Step(rows: flushLoads(), absorbed: true)
            step.rows.append(AgentSessionHistoryItem(
                kind: .userText("/" + command.name + " "
                                + AgentSessionScanner.cleanUserText(command.args)),
                recordUuid: command.recordUuid))
            return step
        }
        var step = Step(rows: flushHeld())
        if !isMeta, let command = SkillRecords.claudeCommand(in: rawText) {
            held = Held(name: command.name, args: command.args,
                        rawText: rawText, recordUuid: recordUuid,
                        promptId: record["promptId"] as? String)
            step.absorbed = true
        }
        return step
    }

    /// The pending loads go onto the message they rode in with.
    mutating func attach(to item: inout AgentSessionHistoryItem) {
        guard !loads.isEmpty else { return }
        item.loadedSkills = loads.map(\.name)
        if let first = loads.first?.recordUuid { item.recordUuid = first }
        loads = []
    }

    /// Whatever is pending, as the rows it stands for. Called wherever a
    /// run of loads can no longer be followed by its message.
    mutating func flush() -> [AgentSessionHistoryItem] {
        flushHeld() + flushLoads()
    }

    private mutating func flushHeld() -> [AgentSessionHistoryItem] {
        guard let command = held else { return [] }
        held = nil
        var rows = flushLoads()
        let cleaned = AgentSessionScanner.cleanUserText(command.rawText)
        if !cleaned.isEmpty {
            rows.append(AgentSessionHistoryItem(kind: .userText(cleaned),
                                                recordUuid: command.recordUuid))
        }
        return rows
    }

    private mutating func flushLoads() -> [AgentSessionHistoryItem] {
        guard !loads.isEmpty else { return [] }
        let row = AgentSessionHistoryItem(
            kind: .userText(loads.map { "/" + $0.name }.joined(separator: " ")),
            recordUuid: loads.first?.recordUuid)
        loads = []
        return [row]
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

    /// One task directory as the scanner reads it.
    struct Definition {
        let description: String
        let directory: URL
        let skill: URL
        let cwd: URL?
        let agent: String
        let parsed: ScheduledTaskDefinition?
        let createdAt: Date?
    }

    /// Read one task directory, or nil when `directory` is not one.
    /// The scan and the composer's just-created listing both go through
    /// here, so a task reads the same whichever of them saw it first.
    static func definition(in directory: URL) -> Definition? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let name = directory.lastPathComponent
        let skill = directory.appendingPathComponent("SKILL.md")
        let parsed = ScheduledTaskDefinition.read(name: name, skillFile: skill)
        let created = (try? directory.resourceValues(forKeys: [.creationDateKey]))?
            .creationDate
        return Definition(
            description: parsed?.description ?? name,
            directory: directory,
            skill: skill,
            cwd: parsed?.workingDirectory,
            agent: parsed?.agent ?? "claude_code",
            parsed: parsed,
            createdAt: created
        )
    }

    /// A task with no runs yet, read from its directory — what the
    /// sidebar lists the moment the composer has written one, before
    /// the rescan that follows reaches it.
    static func newTask(named name: String) -> ScheduledAgentTask? {
        guard !name.isEmpty, !name.hasPrefix("."),
              let definition = definition(
                  in: taskRoot.appendingPathComponent(name, isDirectory: true))
        else { return nil }
        return ScheduledAgentTask(
            name: name,
            description: definition.description,
            directoryURL: definition.directory,
            skillFileURL: definition.skill,
            workingDirectory: definition.cwd,
            sessions: [],
            agent: definition.agent,
            definition: definition.parsed,
            createdAt: definition.createdAt
        )
    }

    static func scan(grouping sessions: [AgentSession]) -> [ScheduledAgentTask] {
        let fm = FileManager.default
        var definitions: [String: Definition] = [:]

        if let taskDirectories = try? fm.contentsOfDirectory(
            at: taskRoot,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for directory in taskDirectories {
                guard let definition = definition(in: directory) else { continue }
                definitions[directory.lastPathComponent] = definition
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
            definitions[taskName] = Definition(
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
                parsed: nil,
                createdAt: nil
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
                definition: definition.parsed,
                createdAt: definition.createdAt
            )
        }

        // Most recently active first — a run, or the task being
        // scheduled — then anything with no date at all in stable
        // alphabetical order.
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

    // MARK: - Runs the scheduler has just started

    /// A run the app started for a task, known before its transcript can
    /// say so: the task, the title its prompt gives it, and when it began.
    struct LiveScheduledRun: Equatable {
        let taskName: String
        let title: String
        let startedAt: Date
    }

    /// How long a run that is no longer in flight keeps its filing when
    /// the transcript still names no task. Its marker is written with its
    /// first record, so a scan after the turn ends has read it; past this
    /// the disk is the authority, as it is for every other row.
    static let liveRunSettleWindow: TimeInterval = 60

    /// Lay the runs the scheduler started (`runs`, keyed by session id)
    /// over lists that may not have read their marker yet: each run's row
    /// is filed under its task in `sessions` — which takes it out of the
    /// ordinary sessions — and put among that task's runs.
    ///
    /// `diskFiled` is the ids a SCAN read a task marker for, off the
    /// transcript itself. Only that retires a run: the rows handed in may
    /// carry a task name this app wrote (a placeholder, or an earlier pass
    /// of this rule), and reading that as the disk speaking would drop the
    /// run from both lists until the next scan. A run is also retired once
    /// it is neither in flight (`running`) nor younger than
    /// `liveRunSettleWindow` — past that the disk decides, as it does for
    /// every other row. Idempotent, and pure, so the rule runs headless.
    static func overlaying(_ runs: [String: LiveScheduledRun],
                           sessions: [AgentSession],
                           tasks: [ScheduledAgentTask],
                           diskFiled: Set<String>,
                           running: Set<String>,
                           now: Date) -> (sessions: [AgentSession],
                                          tasks: [ScheduledAgentTask],
                                          runs: [String: LiveScheduledRun]) {
        guard !runs.isEmpty else { return (sessions, tasks, runs) }
        var sessions = sessions
        var tasks = tasks
        var held: [String: LiveScheduledRun] = [:]
        for (id, run) in runs {
            // The scan's own grouping already holds it.
            if diskFiled.contains(id) { continue }
            guard running.contains(id)
                    || now.timeIntervalSince(run.startedAt) < liveRunSettleWindow
            else { continue }
            held[id] = run
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { continue }
            sessions[index].scheduledTaskName = run.taskName
            sessions[index].origin = .scheduled
            if let task = tasks.firstIndex(where: { $0.name == run.taskName }),
               !tasks[task].sessions.contains(where: { $0.id == id }) {
                tasks[task].sessions.append(sessions[index])
                // Newest first, the order the scanner hands runs over in
                // and the one `lastRunAt` reads.
                tasks[task].sessions.sort { $0.activityAt > $1.activityAt }
            }
        }
        return (sessions, tasks, held)
    }
}

// MARK: - Compressed session files

/// A decoder over one compressed file, handing out the decoded text a
/// chunk at a time.
protocol SessionFileDecoder: AnyObject {
    /// Up to `count` decoded bytes; empty at the end — and from the first
    /// byte that does not decode, which a reader takes as the end, the way
    /// a plain reader takes a file cut off mid-record.
    func read(upToCount count: Int) -> Data
}

/// Session files that lie on disk COMPRESSED. A codex rollout nobody has
/// touched for a while is kept as `<name>.jsonl.zst` — one zstd frame,
/// its decoded size stated in the frame's header, no checksum, the
/// modification time kept — with the `.jsonl` removed. Codex unpacks it
/// back to `<name>.jsonl`, byte for byte, the moment it loads the thread
/// again (a resume, a fork, a listing of its turns), removes the `.zst`,
/// and appends there. So a URL read earlier may name either form;
/// `SessionFileReader.open` follows the file to whichever is on disk.
enum SessionFileCompression {
    static let suffix = ".zst"

    /// Opens a compressed file for decoding. Installed by the app at
    /// launch (`ZstdFileDecoder`, the bundled zstd decoder) before any
    /// session is read; nil where it is not linked — a harness that does
    /// not test this — and a compressed file then reads as unreadable,
    /// which is how every reader treated one before.
    nonisolated(unsafe) static var decoder: ((URL) -> SessionFileDecoder?)? = nil
    /// The decoded size a compressed file's frame states, nil when it
    /// states none. Installed with `decoder`.
    nonisolated(unsafe) static var statedSize: ((URL) -> UInt64?)? = nil

    /// What one read decodes at most. A real rollout decodes to well
    /// under this; a file built to decode without end stops here.
    static let decodedLimit: UInt64 = 1 << 32

    static func isCompressed(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix(suffix)
    }

    /// `<name>.jsonl` for `<name>.jsonl.zst`; any other URL as it is.
    static func unpacked(_ url: URL) -> URL {
        guard isCompressed(url) else { return url }
        let name = url.lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent(String(name.dropLast(suffix.count)))
    }

    /// `<name>.zst` for `<name>`; a compressed URL as it is.
    static func packed(_ url: URL) -> URL {
        guard !isCompressed(url) else { return url }
        return url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + suffix)
    }
}

/// A session file's text, a chunk at a time, whether the file lies on
/// disk as written or compressed (`SessionFileCompression`).
final class SessionFileReader {
    private let handle: FileHandle?
    private let decoder: SessionFileDecoder?
    private var remaining: UInt64
    /// How many bytes of text the file holds when that is known without
    /// reading it: a plain file's size, or the size a compressed file's
    /// frame states.
    let textSize: UInt64?

    private init(handle: FileHandle) {
        self.handle = handle
        decoder = nil
        remaining = .max
        var size: UInt64? = nil
        if let end = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil {
            size = end
        }
        textSize = size
    }

    private init(decoder: SessionFileDecoder, statedSize: UInt64?, limit: UInt64) {
        handle = nil
        self.decoder = decoder
        remaining = limit
        textSize = statedSize
    }

    /// The file `url` names, or the other form of it when codex has
    /// packed or unpacked it since the URL was read. A plain file wins
    /// while both are on disk: it is the one codex writes to. Nil when
    /// neither can be read — a compressed one included, when no decoder
    /// is installed. `limit` bounds what a compressed file decodes to.
    static func open(_ url: URL,
                     limit: UInt64 = SessionFileCompression.decodedLimit) -> SessionFileReader? {
        let plain = SessionFileCompression.unpacked(url)
        if let handle = try? FileHandle(forReadingFrom: plain) {
            return SessionFileReader(handle: handle)
        }
        let packed = SessionFileCompression.packed(url)
        guard let decoder = SessionFileCompression.decoder?(packed) else { return nil }
        return SessionFileReader(decoder: decoder,
                                 statedSize: SessionFileCompression.statedSize?(packed),
                                 limit: limit)
    }

    /// Up to `count` bytes of text; empty at the end.
    func read(upToCount count: Int) -> Data {
        guard count > 0 else { return Data() }
        if let handle {
            return (try? handle.read(upToCount: count)) ?? Data()
        }
        guard remaining > 0, let decoder else { return Data() }
        let chunk = decoder.read(upToCount: Int(min(UInt64(count), remaining)))
        remaining -= UInt64(chunk.count)
        return chunk
    }

    func close() {
        try? handle?.close()
    }
}
