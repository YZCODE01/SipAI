// AgentRunner.swift
// Per-session wrapper around one live `claude -p ... --output-format
// stream-json --verbose` subprocess. Exposes an incremental event log
// (@Published events) and a status enum (@Published status) that the
// session view observes via @ObservedObject.
//
// Ownership model: AgentManager caches one AgentRunner per session key
// in its `runners` dict. Keys are either "draft:<UUID>" (before the
// first send discovers a session id) or "<session_id>" (thereafter).
// When a draft's first send surfaces a system.init event with a real
// session id, AgentManager migrates the runner instance under its new
// key, preserving all events already captured.

import Foundation
import AppKit
import Darwin

// MARK: - Event types

/// One event in a session's live stream. Immutable once appended to the
/// runner's events array; identity is by UUID so SwiftUI ForEach diffs
/// stay stable even when multiple events share the same tool/text.
struct StreamEvent: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let kind: StreamEventKind
    /// Context-window footprint of the API call that produced this
    /// event (input + cache creation + cache read + output of that ONE
    /// call), parsed from an assistant record's `message.usage`. Nil on
    /// events whose record carries no usage. Drives the composer's live
    /// token counter — deliberately NOT the `result` event's usage,
    /// which is summed across every call of the turn and overcounts by
    /// the number of tool round-trips.
    let contextTokens: Int?

    /// True for a user-role record the HARNESS injected (a
    /// background-task notification, a scheduled system notice) rather
    /// than anything the user typed. Rendered under a system label —
    /// see `AgentSessionScanner.isHarnessNotice`.
    let isSystemNotice: Bool

    /// Claude's `fast_mode_state` as reported on the `system.init` and
    /// `result` events — "on", "off" or "cooldown" (paused after a
    /// rate limit). Nil on every other event and on agents that report
    /// no such thing. One of the channels `ClaudeFastModeReport`
    /// gathers: it stays "on" while claude's calls are being refused.
    let fastModeState: String?
    /// `fast_mode_disabled_reason` beside it, when claude names what
    /// blocks fast mode for the session ("extra_usage_disabled", …).
    let fastModeDisabledReason: String?
    /// `usage.speed` of the MAIN-LOOP API call this event came from —
    /// "fast" or "standard", what the call actually ran at. Nil on
    /// subagent records, on the harness's own `<synthetic>` text, and
    /// on every event whose record carries no usage.
    let callSpeed: String?

    /// Context window per full model id, as CLAUDE reported it on the
    /// `result` event (`modelUsage[<id>].contextWindow`) — the window
    /// the CLI itself divided by for that turn. Nil on every other
    /// event and on the two agents that report no such thing.
    ///
    /// Confirms and extends the table read out of claude's binary; see
    /// `ConfigManager.setAgentModelContextWindow`. Carried as a FIELD
    /// rather than in the `.result` case, which is pattern-matched in
    /// several places that have no use for it.
    let modelContextWindows: [String: Int]?

    /// The files a `.userMessage` carried as inlined attachments
    /// (`AttachmentInline`), for the paperclip line — the event's text is
    /// the DISPLAY text, blocks stripped, and the names are what is left
    /// of them. Empty on every other event. Set by `AgentRunner.send`,
    /// and by the tailer for a codex or kimi row, which comes through the
    /// reader a reopened transcript uses and so carries the names that
    /// reader read; claude's live parser has none to give.
    let attachedFiles: [String]

    /// True on the `.userMessage` of a turn that ran in Chat only — the
    /// flag the transcript reads to draw that turn's thoughts and web
    /// lookups as one line (`ChatOnlyActivity`). Set by `send` from the
    /// options the turn actually ran with, so switching the chip later
    /// never restyles a turn already on screen. False on every other
    /// event, and on a message another process sent.
    let chatOnlyTurn: Bool

    init(kind: StreamEventKind, contextTokens: Int? = nil,
         isSystemNotice: Bool = false, fastModeState: String? = nil,
         fastModeDisabledReason: String? = nil, callSpeed: String? = nil,
         modelContextWindows: [String: Int]? = nil,
         attachedFiles: [String] = [],
         chatOnlyTurn: Bool = false) {
        self.id = UUID()
        self.timestamp = Date()
        self.kind = kind
        self.contextTokens = contextTokens
        self.isSystemNotice = isSystemNotice
        self.fastModeState = fastModeState
        self.fastModeDisabledReason = fastModeDisabledReason
        self.callSpeed = callSpeed
        self.modelContextWindows = modelContextWindows
        self.attachedFiles = attachedFiles
        self.chatOnlyTurn = chatOnlyTurn
    }

    // Identity-only equality keeps SwiftUI diffs cheap; the kind
    // may contain non-Hashable data in the future.
    static func == (lhs: StreamEvent, rhs: StreamEvent) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum StreamEventKind {
    /// User message the runner sent to Claude — added by `send(text:)`
    /// before the subprocess is spawned so the bubble appears immediately.
    case userMessage(text: String)
    /// One assistant text block. Multiple per turn are possible when
    /// Claude interleaves text with tool calls.
    case assistantText(text: String)
    /// A readable thought — the model's thinking summary. Only ever
    /// present in a Chat only turn: the parsers emit none unless asked,
    /// and the runner asks only for a turn that ran in Chat only, so an
    /// agent turn's event list is exactly what it always was.
    case thinking(text: String)
    /// One tool_use block from an assistant message. The `toolUseId`
    /// ties this to a later `toolResult` carrying the same id. The raw
    /// input dict is carried through so the view can render the rich
    /// per-tool body in full mode (`AgentRendering.fullToolBody`) on top
    /// of the compact one-line summary (`summarizeToolInput`).
    case toolUse(toolUseId: String, name: String, input: [String: Any])
    /// One tool_result block from a follow-up `user`-typed event.
    case toolResult(toolUseId: String, output: String, isError: Bool)
    /// First event in a turn. Carries the session_id that migrates a
    /// draft runner to its permanent key.
    case systemInit(sessionId: String, model: String, cwd: String)
    /// Terminal event of a turn. Token counts come from the stream-json
    /// `usage` block and may be zero on older server versions. NOTE:
    /// that usage is CUMULATIVE across every API call of the turn —
    /// fine for the turn-summary chip, useless for the context counter
    /// (see `StreamEvent.contextTokens`).
    case result(durationMs: Int,
                totalCostUSD: Double?,
                numTurns: Int,
                inputTokens: Int,
                outputTokens: Int)
    /// The agent summarised the conversation to make room and carried
    /// on. Rendered as a quiet system row: the context number is about
    /// to drop by most of its value, and without this the drop has no
    /// explanation on screen. Figures are nil for an agent that records
    /// none (codex).
    case compaction(preTokens: Int?, postTokens: Int?)
    /// Parser or runtime error surfaced to the UI.
    case error(message: String)
    /// The turn was stopped before it finished — the user's Stop
    /// button (own subprocess or an orphaned external one). Rendered
    /// as a quiet system row, not an error: stopping is a normal act.
    case interrupted(message: String)
}

// MARK: - Status

enum RunStatus: Equatable {
    case idle
    case running(startedAt: Date)
    case done(exitCode: Int32, errorMessage: String?)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

// MARK: - Runner

@MainActor
final class AgentRunner: ObservableObject {
    /// Current cache key: "draft:<UUID>" until migration, "<session_id>" after.
    /// Mutated by AgentManager during draft→existing migration.
    var key: String

    /// Which CLI this runner drives — an `AgentManager.registry` key
    /// ("claude_code", "codex" or "kimi"). Fixed for the runner's life:
    /// a session belongs to the agent that recorded it, and every
    /// agent-shaped decision below (binary, argv, stdout schema,
    /// session-file layout, whether the MCP approver applies) reads
    /// from this one value rather than re-deriving it.
    let agentKey: String

    private var isKimi: Bool { agentKey == "kimi" }
    /// The claude path — the only one with an MCP approver, a JSONL
    /// tailer, and a session-id event on stdout. Stated positively so
    /// a fourth agent doesn't quietly inherit all three.
    private var isClaude: Bool { agentKey == "claude_code" }

    /// Working directory the subprocess runs in.
    let cwd: URL

    /// Session id once known (from a system.init event). Nil for a draft
    /// that hasn't sent its first message yet.
    @Published private(set) var sessionId: String?

    /// Absolute path to the JSONL file claude wrote to, once we can
    /// locate it under `~/.claude/projects/*/<session_id>.jsonl`.
    @Published private(set) var sessionFileURL: URL?

    /// User-provided display name carried over from ClaudeSessionDraft.
    /// Stays nil for runners attached to existing sessions (their display
    /// name lives in config.json via ConfigManager.agentSessionDisplayName).
    let initialName: String?

    /// Process-wide MCP bridge. Nil if the app hasn't wired one yet
    /// (defensive — in practice it's set before any runner is created).
    /// Weak to avoid a retain cycle with the bridge's @StateObject
    /// ownership in SipAIApp.
    private weak var bridge: MCPBridge?

    /// 32-char hex identifier used as SIPAI_SESSION_ID for this runner's
    /// FIRST send when no session id is known yet. Once a system.init
    /// event reveals a real session id, the bridge's alias map links
    /// this task_uuid to that session id and subsequent sends switch
    /// to using the session id directly.
    private var taskUuid: String?

    /// Public read-only accessor for this runner's current
    /// SIPAI_SESSION_ID hex task_uuid (if it has one) — exposed for
    /// the UI's approval-card filter, which needs to match a draft
    /// runner's pending approvals by task_uuid before system.init
    /// swaps it for a real session id.
    var taskUuidForBridge: String? { taskUuid }

    /// Live event stream. Grows monotonically for the life of the
    /// runner. Views observe this and render each event as a bubble.
    @Published private(set) var events: [StreamEvent] = []

    /// Context-window footprint from the newest assistant event
    /// carrying usage (0 until the first one) — LIVE: it moves with
    /// every API call of a turn, so the counter appears during the
    /// first turn and grows as tool results join the context, for our
    /// own subprocess and for tailed external turns alike. Published
    /// separately from `events` so the session view can refresh its
    /// token counter without observing the whole event stream —
    /// per-line parent re-renders are exactly what the
    /// RunnerStreamView split avoids. Also immune to the status/result
    /// ordering race: the value travels WITH the event append, not with
    /// the status flip.
    @Published private(set) var lastContextTokens: Int = 0

    /// The context WINDOW the footprint above sits in, when the agent
    /// records one — codex stamps `model_context_window` on the same
    /// rollout record the footprint is read from, and kimi's config
    /// declares `max_context_size` per model. 0 = not recorded (claude
    /// among them), and the occupancy tooltip falls back to its
    /// constant. Published beside `lastContextTokens` so the two ride
    /// the same delivery contract; display-only — nothing is ever
    /// launched with it.
    @Published private(set) var lastContextWindow: Int = 0

    /// Context windows claude reported on the newest `result` event,
    /// per full model id. REPLACED, never merged: `@Published` replays
    /// to every resubscription, so the value has to be idempotent, and
    /// one turn's report is complete for the models that turn ran.
    /// Empty on codex and kimi, which report no such thing.
    @Published private(set) var observedContextWindows: [String: Int] = [:]

    /// What our own subprocess's newest system.init resolved to, PAIRED
    /// with the picker alias that turn was LAUNCHED with. Feeds the
    /// composer's model chip the resolved model the moment a send
    /// starts — the JSONL doesn't carry it until the first assistant
    /// record lands, and an alias like "opus" says nothing about the
    /// version that actually ran. Same delivery pattern as
    /// `lastContextTokens` for the same ordering reasons.
    ///
    /// The pair is the point, and it is one value rather than two
    /// publishers. An observation is only ever ground truth ABOUT THE
    /// ALIAS IT RAN UNDER: an id delivered on its own says "claude
    /// answered with this", and the reader is left to guess which
    /// alias it belongs to — which it can only do by reading whatever
    /// the chips say NOW. A chip the user has since changed then
    /// silently claims a model it never ran (see
    /// `AgentSessionView`'s handler, and `ClaudeModelDisplay.canResolve`
    /// for the contradiction that survives in config once it does).
    struct ResolvedModel: Equatable {
        /// Picker alias the turn was launched with; "" is claude's own
        /// default, which is a legitimate key in the observed-id map.
        let alias: String
        /// Full id claude reported for it ("claude-fable-5").
        let fullId: String
    }
    @Published private(set) var resolvedModel: ResolvedModel? = nil

    /// What claude has said about fast mode on this session's turns —
    /// its reported state and reason, the refusal sentence of the
    /// current turn, and the speed the newest call ran at. Same delivery
    /// shape as `resolvedModel`, and read the same way: the view mirrors
    /// it behind an equality guard. Always empty for codex and kimi.
    @Published private(set) var fastModeReport = ClaudeFastModeReport()

    /// One write per change: a publish re-renders the session view.
    private func updateFastModeReport(_ change: (inout ClaudeFastModeReport) -> Void) {
        var next = fastModeReport
        change(&next)
        if next != fastModeReport { fastModeReport = next }
    }

    /// The alias the in-flight turn was launched with, captured at
    /// `send` — the only moment it is knowable, since the chips are
    /// free to move while the turn runs.
    private var launchedModelAlias: String = ""

    /// Seconds the most recently finished turn took — the very number
    /// the "Sipping…" row was counting up to, read off the same clock
    /// (`status.running(startedAt:)`) at the moment claude emits its
    /// `result`. Feeds the composer's duration chip.
    ///
    /// Stamped at `result`, NOT when the turn finalizes: finalizing
    /// also waits for the child to exit and both readers to drain, and
    /// any lag there is teardown, not thinking time. Same delivery
    /// pattern as `lastContextTokens` — the value travels WITH the
    /// event append, so it cannot race the status flip.
    ///
    /// nil until a turn completes under this runner. A cold-opened
    /// session's last turn is seeded separately, from the transcript
    /// (`AgentSessionView.seededTurnDuration`); a turn finished by
    /// ANOTHER terminal lands here via `noteExternalTurnDuration`,
    /// because this publisher has to stay the single source for the
    /// view's mirror.
    @Published private(set) var lastTurnDuration: Double? = nil

    @Published private(set) var status: RunStatus = .idle

    /// The user text of the turn currently running (nil before the
    /// first send; stale once the turn ends — consult only while
    /// `status.isRunning`). Lets a mid-turn history reload cut the
    /// in-flight turn's records out of the loaded items: the JSONL
    /// already holds them, but `clearEvents()` rightly refuses
    /// mid-turn, so keeping both would render the user's message (and
    /// the turn's partial records) TWICE until the turn finished. Not
    /// the event buffer's first `.userMessage` — the live-buffer trim
    /// can have dropped that on a long turn.
    private(set) var inFlightUserText: String? = nil

    /// Last 500 chars of stderr for surfacing on error.
    ///
    /// Published only at moments that render it — the child's EOF, and
    /// a stall notice — never per line. Every write re-renders the
    /// whole transcript (RunnerStreamView observes this object), and a
    /// chatty child would otherwise do that once per line of warning
    /// spew for the length of a turn.
    @Published private(set) var stderrTail: String = ""

    /// Everything stderr has said so far this turn, capped. NOT
    /// published: this is the buffer, `stderrTail` is the snapshot of
    /// it that the UI is allowed to see.
    private var stderrBuffer: String = ""

    /// True once the current turn has gone `firstOutputGrace` without
    /// producing a single visible event. A LATCH, not a clock — see
    /// `armStallNotice`. Reset by the next send and by the turn ending.
    @Published private(set) var turnProducedNothing: Bool = false

    /// The child's newest word on a connection it is retrying by itself
    /// — codex's "Reconnecting… 3/5 (…)". Live state, not history: it
    /// is replaced by the next notice, cleared by any real output, and
    /// never enters `events`. See `CodexEventParser.Parsed`.
    @Published private(set) var retryNotice: String = ""

    /// The child is summarising the conversation right now.
    ///
    /// STATE, never an event: it is true for the 30-ish seconds a
    /// compaction takes and false afterwards, so writing it into
    /// `events` would put it in the history cache and in every later
    /// reopen. Same lifetime and the same reasoning as `retryNotice`.
    /// Claude only — the other two announce nothing while they compact.
    @Published private(set) var compacting: Bool = false

    /// This turn was sent while SipAI is updating the agent's own
    /// command-line tool, and is waiting for that update to finish
    /// before it spawns (`runOnce`). The user's message is already on
    /// screen; the waiting row says why nothing has happened yet. STATE,
    /// like `compacting`: cleared when the wait ends and when the turn
    /// does, and never written into `events`.
    @Published private(set) var waitingForToolUpdate: Bool = false

    /// The single pending finalize bound on the turn — armed by Stop
    /// (`armTurnFinalize`), and by the child's exit when a reader
    /// misses its EOF.
    private var turnEndWatchdog: Task<Void, Never>? = nil

    /// Separate slot from `turnEndWatchdog` on purpose: that one is
    /// single-occupancy by design ("at any moment exactly one pending
    /// bound on the turn"), and the stall notice must be able to be
    /// pending at the same time as a finalize bound without either
    /// cancelling the other.
    private var stallNoticeTask: Task<Void, Never>? = nil

    // MARK: Callbacks (set by AgentManager when creating)

    /// Fired on the MainActor exactly once when a system.init event
    /// reveals a session id for a runner that didn't already have one.
    /// AgentManager uses this to migrate the runners dict key.
    var onSessionIdDiscovered: ((_ sessionId: String, _ fileURL: URL?) -> Void)?

    /// Fired on every status transition. AgentManager uses this to
    /// maintain its `inFlightSends` dictionary (the sidebar activity
    /// dot and any future cross-session queries read from there).
    var onStatusChange: ((_ key: String, _ status: RunStatus) -> Void)?

    /// Fired on every `externalInProgress` transition (an external
    /// Claude Code process appending to the same session JSONL).
    /// AgentManager uses this to maintain its `externalInFlightSessions`
    /// set for the sidebar activity dot. Always called with the
    /// runner's current session id; a runner without a session id yet
    /// (fresh draft) will never see an external-in-progress event
    /// because its JSONL doesn't exist to be appended to.
    var onExternalInProgressChange: ((_ sessionId: String, _ inProgress: Bool) -> Void)?

    /// The journal behind a kimi Chat only turn (`KimiToolPolicy`): a
    /// record means "SipAI is about to write the session's tool-policy
    /// file; this is what was there", nil means "put back, forget it".
    /// Wired by `AgentManager` into config so a crash mid-turn is healed
    /// at the next launch. The runner never touches config itself.
    var onKimiToolPolicyJournal: ((_ sessionId: String,
                                   _ record: KimiToolPolicy.RestoreRecord?) -> Void)?

    /// The restore owed for the kimi `--prompt` turn in flight, applied
    /// by whichever caller ends the turn first (`finalizeTurn`, a spawn
    /// failure) — first caller wins, like `stampTurnDuration`.
    private var pendingKimiRestore: (sessionId: String, file: URL,
                                     record: KimiToolPolicy.RestoreRecord)? = nil

    /// A kimi Chat only turn is running through kimi's local server
    /// (`runKimiWebTurn`) — no child process of ours, so Stop must not
    /// end the turn before that task has aborted the prompt, shut the
    /// server down and put the tool-policy file back; see `cancel()`.
    /// Held as the turn's `runToken`: a stopped server turn's teardown
    /// can outlive the bound Stop arms, and must not clear the flag of
    /// a newer turn that started meanwhile.
    private var kimiWebTurnToken: Int? = nil
    private var kimiWebTurnInFlight: Bool { kimiWebTurnToken == runToken }

    /// Temp image files written for a codex `-i` turn, removed when the
    /// turn ends — the same first-caller-wins cleanup shape as the kimi
    /// tool-policy restore. Codex reads the files while it runs; nothing
    /// keeps them afterwards.
    private var pendingCodexImageFiles: [URL] = []

    /// A finished Chat only turn's handle into the transcript — its user
    /// record's id in the reader's own vocabulary (claude record `uuid`,
    /// codex `turn_id`, kimi prompt id) — so the turn keeps its look when
    /// the session is reopened. No agent records that a turn ran in Chat
    /// only, so SipAI remembers it. Wired by `AgentManager` into config;
    /// the runner never touches config itself.
    var onChatOnlyTurnRecorded: ((_ sessionId: String, _ handle: String) -> Void)?

    /// Whether the turn in flight (or the newest one) ran in Chat only.
    /// Decides whether the parsers keep the model's thoughts: an agent
    /// turn's events never carry one.
    private var turnChatOnly = false

    /// This turn's handle has been resolved and handed out — at its
    /// `result` or at `finalizeTurn`, whichever comes first, like
    /// `stampTurnDuration`.
    private var chatOnlyTurnRecorded = false

    /// Kimi prints no thinking on stdout; its wire records every step's.
    /// How many of this turn's wire thoughts are already in `events`
    /// (they are placed in order — see `placeKimiThoughts`), and the
    /// single-flight state of the read that fetches them.
    private var kimiThoughtsPlaced = 0
    private var kimiThoughtSyncRunning = false
    private var kimiThoughtSyncPending = false
    private var kimiThoughtSyncFinal = false

    /// What the turn the live buffer opens inside ran as, once the front
    /// trim has cut that turn's message away (`trimLiveEventsIfNeeded`):
    /// the transcript reads it to keep the rest of a Chat only turn on
    /// its one line (`ChatOnlyActivity.LiveStart`). Changes only with
    /// `events`, whose publish re-renders the view.
    private(set) var trimmedHeadChatOnly = false

    /// `true` while a separate Claude Code process (another terminal,
    /// a scheduled task, another SipAI instance) is mid-turn against
    /// the same session JSONL. Drives the sidebar activity dot and
    /// disables the send button to prevent concurrent writes.
    @Published private(set) var externalInProgress: Bool = false

    /// Start instant of the external turn, read from the transcript's
    /// OWN record stamps (the writer has no clock of ours, but its
    /// records carry timestamps). Non-nil only while
    /// `externalInProgress`; lets the composer's turn clock tick for
    /// a turn some other process is running — most importantly one
    /// this app orphaned by relaunching mid-turn.
    @Published private(set) var externalTurnStartedAt: Date? = nil

    /// pid of an external writer this app may STOP: a headless
    /// `claude -p` (`entrypoint: "sdk-cli"` heartbeat — e.g. a turn
    /// orphaned by an app relaunch). nil while the writer is an
    /// interactive terminal claude (stopping that belongs to its own
    /// terminal — the composer shows a disabled Stop instead) or
    /// can't be identified at all.
    @Published private(set) var externalStoppablePid: Int32? = nil

    /// Whether the external turn being watched was stopped from this
    /// app's composer (`stopExternalTurn`). Read at its end by the
    /// sidebar's unread rule, the way `turnWasStoppedByUser` is for a
    /// turn of ours: a run the user ended leaves no steady dot. The
    /// end arrives through the tailer's sweep, seconds after the
    /// click, by when the user may have moved on. Reset when the next
    /// external turn starts.
    private(set) var externalTurnWasStoppedByUser: Bool = false

    // MARK: Private

    private var process: Process?
    private var runTask: Task<Void, Never>?

    /// Bumped by every `send`. Every bounded fallback captures it and
    /// refuses to act if the runner has moved on to a later turn, so a
    /// timer armed for turn N can never finalize turn N+1.
    private var runToken: Int = 0

    /// Set by the first Stop of a turn. The `.interrupted` row is a
    /// statement about the turn, not about the click: without this,
    /// pressing Stop while the previous press was still taking effect
    /// would stamp a fresh row per press.
    private var stopRequested: Bool = false

    /// Whether the turn that just ended was ended by the user — the Stop
    /// button, or quitting SipAI, which stops through the same
    /// `cancel()`. Read at the turn's end by the sidebar's unread rule:
    /// a run the user ended leaves no steady dot behind. Reset by the
    /// next send.
    var turnWasStoppedByUser: Bool { stopRequested }

    /// Whether THIS turn has already had its duration recorded. The
    /// chip must show thinking time, so the first stamp wins and every
    /// later caller no-ops: `result` (claude, codex) is the moment the
    /// answer landed, whereas finalizing also waits on the child's exit
    /// and the readers' drain, which is teardown.
    ///
    /// Kimi has no result event of any kind — its stream is plain chat
    /// messages — so for a kimi turn the finalize stamp is the ONLY
    /// one, and without it the composer's clock would run for the whole
    /// turn and then vanish instead of freezing on the total.
    private var turnDurationStamped: Bool = false

    /// Freeze the composer's turn clock on the elapsed time so far.
    /// First caller of a turn wins; see `turnDurationStamped`.
    private func stampTurnDuration() {
        guard !turnDurationStamped,
              case .running(let startedAt) = status else { return }
        turnDurationStamped = true
        lastTurnDuration = Date().timeIntervalSince(startedAt)
    }

    /// Refresh `lastContextTokens` from a codex session's rollout file.
    ///
    /// Codex's stdout carries no PER-CALL usage — only `turn.completed`,
    /// whose block is summed across the turn's API calls — so the token
    /// chip cannot ride the event stream the way claude's does. The
    /// rollout does carry it, one `token_count` record per call, so a
    /// codex turn refreshes the chip by re-reading that file instead.
    ///
    /// Called on every stdout line of a codex turn (`throttled`), at
    /// `result`, and again from `finalizeTurn`.
    ///
    /// The throttled calls are what make the chip move DURING a turn:
    /// codex appends a `token_count` record per API call, interleaved
    /// with the turn's items, so the number the user is watching climb
    /// is on disk long before the turn ends. Reading it only at the end
    /// left the chip frozen for the whole run.
    ///
    /// `result` and `finalizeTurn` bypass the throttle because they are
    /// the EXACT values: the last one written before `task_complete`,
    /// and the only stamp a stopped or crashed turn ever gets — same
    /// reasoning as `stampTurnDuration`.
    ///
    /// Off-main: the read is bounded, but a rollout runs to megabytes
    /// and this is the MainActor. The re-read is deliberately NOT
    /// gated on `sessionFileURL` being known at call time — see
    /// `finalizeTurn`, which locates a draft's rollout late.
    private func refreshCodexContextTokens(throttled: Bool = false) {
        guard agentKey == "codex", let url = sessionFileURL else { return }
        let now = Date()
        if throttled,
           now.timeIntervalSince(lastCodexTokenRead) < Self.storeTokenReadInterval {
            return
        }
        lastCodexTokenRead = now
        Task.detached(priority: .utility) { [weak self] in
            let info = CodexSessionScanner.lastContextInfo(of: url)
            guard info.tokens > 0 else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if info.tokens != self.lastContextTokens {
                    self.lastContextTokens = info.tokens
                }
                // Window only when the record carried one — a 0 must
                // not erase a window an earlier record stated.
                if info.window > 0, info.window != self.lastContextWindow {
                    self.lastContextWindow = info.window
                }
            }
        }
    }

    /// Floor on how often a streaming turn may re-read an agent's
    /// store for usage. The read is a bounded tail, but a busy turn
    /// emits lines faster than the chip can meaningfully change.
    private static let storeTokenReadInterval: TimeInterval = 1
    private var lastCodexTokenRead: Date = .distantPast
    private var lastKimiTokenRead: Date = .distantPast

    /// The same refresh for kimi, and for the same reason: its stdout
    /// carries no usage at all, so the chip is fed from the wire file
    /// (`usage.record`) at the end of a turn instead of from an event.
    ///
    /// Kimi is the one agent whose `sessionFileURL` may still be nil at
    /// `result` — the id arrives on the LAST stdout line, and on a
    /// draft's first turn that is roughly when this runs. The finalize
    /// call is what covers it: by then `adoptDiscoveredSession` has
    /// landed, so a first turn's chip appears without waiting for the
    /// session to be reopened.
    private func refreshKimiContextTokens(throttled: Bool = false) {
        guard agentKey == "kimi", let url = sessionFileURL else { return }
        let now = Date()
        if throttled,
           now.timeIntervalSince(lastKimiTokenRead) < Self.storeTokenReadInterval {
            return
        }
        lastKimiTokenRead = now
        Task.detached(priority: .utility) { [weak self] in
            let usage = KimiSessionScanner.lastContextUsage(of: url)
            guard usage.tokens > 0 else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if usage.tokens != self.lastContextTokens {
                    self.lastContextTokens = usage.tokens
                }
                // The record names its model; the config names that
                // model's window. Joined here because the catalog is
                // MainActor state and the scan above is not. A model
                // the catalog does not know keeps the previous window
                // rather than erasing it with a guess. `ensureLoaded`
                // is one stat when nothing changed — a session driven
                // before the composer ever appeared still resolves.
                KimiCatalog.shared.ensureLoaded()
                if let window = KimiCatalog.shared
                    .maxContextSize(forModel: usage.model),
                   window > 0, window != self.lastContextWindow {
                    self.lastContextWindow = window
                }
            }
        }
    }

    /// Which of `runOnce`'s three child tasks have finished, for the
    /// diagnostic the finalize fallback logs. A turn should never need
    /// the fallback; when it does, this says whether stdout, stderr or
    /// the exit wait was the one that never came back.
    private var stdoutReaderFinished = false
    private var stderrReaderFinished = false
    private var childExitObserved = false

    /// File-system monitor for external activity on this session's
    /// JSONL. Created lazily once `sessionFileURL` is known — at init
    /// time for an existing session, or inside `handleSystemEvent` for
    /// a draft after its first turn reveals the session id.
    private var tailer: AgentSessionTailer?

    /// Poller that reads a kimi session's id back off the store — the
    /// stand-in for a `system.init` / `thread.started` event, which kimi
    /// sends only as its final answer's `session.resume_hint`. See
    /// `startKimiSessionDiscovery`.
    private var kimiDiscoveryTask: Task<Void, Never>?

    // MARK: Init

    init(key: String, cwd: URL,
         sessionId: String?, sessionFileURL: URL? = nil,
         initialName: String?,
         bridge: MCPBridge?,
         agentKey: String = "claude_code") {
        self.key = key
        self.cwd = cwd
        self.sessionId = sessionId
        self.sessionFileURL = sessionFileURL
        self.initialName = initialName
        self.agentKey = agentKey
        // The approver is a claude-only protocol (it is wired through
        // `--mcp-config` plus `--permission-prompt-tool`), so a codex
        // or kimi runner deliberately holds no reference to it — see
        // `runOnce`. Kimi does take `--mcp-config`, but it has no
        // permission-prompt hook to route a verdict back through, and
        // its print mode auto-approves every tool call regardless
        // (`--prompt` implies `--afk`), so there would be nothing for
        // the bridge to be asked.
        self.bridge = agentKey == "claude_code" ? bridge : nil

        // Existing-session runners get their tailer up front. Drafts
        // defer this to `handleSystemEvent` once a session id surfaces.
        if let url = sessionFileURL {
            startTailer(at: url, initialOffset: Self.currentSize(of: url))
        }
    }

    deinit {
        tailer?.stop()
        kimiDiscoveryTask?.cancel()
        stallNoticeTask?.cancel()
        sessionFileSearch?.cancel()
    }

    // MARK: - Public API

    /// Kick off a new turn. No-op if the runner is already running.
    /// Appends a `.userMessage` event immediately so the bubble shows
    /// before the subprocess is even spawned. `options` carries the
    /// composer's per-send permission mode / model / effort choices.
    /// Returns false when the send was refused (mid-turn or empty text)
    /// so the composer can keep the draft instead of dropping it.
    @discardableResult
    func send(text: String, options: AgentLaunchOptions = AgentLaunchOptions(),
              images: [AgentImage] = []) -> Bool {
        guard !status.isRunning else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // The previous child can still be alive after its turn ended —
        // waiting on background tasks it started. This send supersedes
        // that wait, and two `claude -p` processes must never drive one
        // session: the newcomer's session-lock takeover kills whichever
        // it decides is stale, which can be the turn that was just
        // asked for.
        if let p = process, p.isRunning {
            killChild(reason: "superseded by a new send")
        }

        // The WIRE text is the composed message, inlined attachment
        // blocks included; the BUBBLE shows the user's own words with a
        // paperclip line naming the files — the same split the readers
        // make on reopen (`AttachmentInline`), so a mid-turn reload's
        // cut (`inFlightUserText`), the branch pencil's text match and
        // the find pipeline all see one spelling: the displayed one.
        // The `<scheduled-task>` marker a fired run is prefixed with is
        // filing, not words, and every reader strips it too — left in
        // here, the live row would draw the tag and never match its
        // record (no cut on a mid-turn reload, no branch from the row).
        let display = CodexSessionScanner.strippedTaskMarker(trimmed)
        events.append(StreamEvent(kind: .userMessage(text: display),
                                  attachedFiles: AttachmentInline.names(in: trimmed),
                                  chatOnlyTurn: options.chatOnly))
        inFlightUserText = display
        turnChatOnly = options.chatOnly
        chatOnlyTurnRecorded = false
        kimiThoughtsPlaced = 0
        kimiThoughtSyncPending = false
        kimiThoughtSyncFinal = false
        // Whatever the chips say when this turn's system.init lands is
        // not what this turn ran as — the user is free to move them
        // mid-turn. Captured here, it can only ever describe this send.
        launchedModelAlias = options.model ?? ""
        // A refusal describes the turn it happened in; the next one asks
        // for fast mode afresh (credits may have been added meanwhile).
        updateFastModeReport { $0.refusal = nil }
        stderrTail = ""
        stderrBuffer = ""
        retryNotice = ""
        compacting = false
        disarmTurnEndWatchdog()
        runToken &+= 1
        stopRequested = false
        turnDurationStamped = false
        kimiDiscoveryTask?.cancel()
        stdoutReaderFinished = false
        stderrReaderFinished = false
        childExitObserved = false
        setStatus(.running(startedAt: Date()))
        // After the status flip: the notice is only ever published on
        // a turn this guard says is still running.
        armStallNotice()

        runTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runOnce(text: trimmed, options: options, images: images)
        }
        return true
    }

    /// Stop. Terminates the subprocess and insists if SIGTERM is
    /// ignored — and then makes sure the TURN ends, whether or not the
    /// child was still there to kill.
    ///
    /// Killing the child is normally enough: its death closes the last
    /// PTY slave and the last stderr write end, both readers reach EOF,
    /// `runOnce`'s group joins and the status flips. But Stop must not
    /// DEPEND on that — the hard case is a child that is ALREADY GONE
    /// while a reader never saw its EOF. `killChild` no-ops on a dead
    /// child, so a Stop that only killed would have nothing to act on
    /// and the status would stay `.running` forever. So: kill if there
    /// is something to kill, and bound the wait for the join either
    /// way.
    ///
    /// Also called for idle runners (session delete, app quit sweeps) —
    /// the running-only side effects are guarded so those stay no-ops.
    func cancel() {
        disarmTurnEndWatchdog()
        guard case .running = status else {
            runTask?.cancel()
            killChild(reason: "Stop")
            return
        }
        if !stopRequested {
            stopRequested = true
            // Freeze the composer's duration chip at the stop instant —
            // a killed turn never emits the `result` event that
            // normally stamps this.
            stampTurnDuration()
            events.append(StreamEvent(kind: .interrupted(message:
                Self.interruptedByUserMessage)))
            // A dead claude can never consume an answer — clear its
            // pending approval cards instead of leaving ghost
            // questions on screen (the MCP handler thread would
            // otherwise block on its semaphore forever).
            cancelPendingApprovals()
        }
        runTask?.cancel()
        if let p = process, p.isRunning {
            killChild(reason: "Stop")
            // Past killChild's own 3 s SIGTERM→SIGKILL escalation, so
            // the child is certainly gone by the time this fires.
            armTurnFinalize(after: Self.stopGrace, reason: "Stop")
        } else if kimiWebTurnInFlight {
            // No child of ours to kill: the turn runs through kimi's
            // local server, and the cancelled task aborts the prompt,
            // shuts the server down, puts the session's tool-policy
            // file back and THEN finalizes. Ending the turn here would
            // let the next send start under that teardown — two writers
            // on one session, and the new turn's policy file removed
            // from under it by the old turn's restore. The bound is for
            // a server that stops answering.
            armTurnFinalize(after: Self.stopGrace, reason: "Stop, kimi web turn")
        } else {
            // Nothing to kill. Whatever the readers are doing, the turn
            // is over the moment the child is gone — end it now.
            finalizeTurn(token: runToken,
                         exitCode: Self.exitCodeIfExited(process),
                         errorMessage: nil,
                         fallbackReason: "Stop, child already gone")
        }
    }

    /// One wording for every stop surface, so the live row and the
    /// derived history marker read as the same thing. Nonisolated —
    /// the history loader reads it from a detached task.
    nonisolated static var interruptedByUserMessage: String {
        String(localized: "Interrupted — this turn was stopped before it finished.",
               comment: "Transcript row after the user stops a running turn")
    }

    /// Force-deny any approval cards still pending for this session
    /// (or, for a draft, its task_uuid).
    private func cancelPendingApprovals() {
        bridge?.cancelPending(sessionId: sessionId, taskUuid: taskUuid)
    }

    /// SIGTERM now; SIGKILL a few seconds later if it was ignored.
    ///
    /// The SIGTERM reaches claude's whole process GROUP: `Process` makes
    /// the child the leader of a group of its own, and `terminate()`
    /// signals that group — the MCP approver claude started is in it
    /// (its Bash tool shells lead groups of their own). The SIGKILL
    /// escalation goes to the claude pid alone, and nothing here signals
    /// a group by hand: no descendant of `claude` inherits our
    /// descriptors — tool subprocesses get /dev/null plus a temp file,
    /// MCP stdio servers get socketpairs — so the only holder of our PTY
    /// slave is claude itself, and killing claude alone is enough for
    /// both readers to reach EOF.
    private func killChild(reason: String) {
        guard let p = process, p.isRunning else { return }
        let pid = p.processIdentifier
        let agent = agentKey
        p.terminate()
        // Escalate against the CAPTURED handle, not `self.process`: a
        // superseding send replaces that property immediately, and the
        // old child must still be escalated if it ignores SIGTERM.
        // `p.isRunning` is pid-recycling-safe — it answers for this
        // Process object's own unreaped child.
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard p.isRunning else { return }
            NSLog("%@", "SipAI: \(agent) (pid \(pid)) ignored SIGTERM after \(reason) — sending SIGKILL.")
            kill(pid, SIGKILL)
        }
    }

    /// How long a finalize fallback waits after the child is known to be
    /// gone. Longer than `killChild`'s 3 s SIGTERM→SIGKILL escalation so
    /// the ordinary path — child dies, readers EOF, group joins — always
    /// wins the race and the fallback stays a fallback.
    private static let stopGrace: TimeInterval = 4

    /// How long the readers may keep the turn "running" after the child
    /// is already gone. They are draining a few KB of kernel buffer at
    /// that point, which takes milliseconds; this is three orders of
    /// magnitude of headroom, and the readers keep running after it
    /// fires, so anything still in flight is still parsed and appended.
    private static let readerDrainGrace: TimeInterval = 5

    /// `result` ends the VISIBLE turn, never the process. A `claude -p`
    /// child legitimately outlives its result event: it stays alive
    /// while background tasks it started are still running and streams
    /// FURTHER SEGMENTS when they complete — measured, one process:
    /// result → minutes of quiet → task notification → a new user
    /// record and a fresh assistant turn. Killing the child merely for
    /// being alive after `result` cuts that pending work off mid-
    /// flight, so nothing here touches the process, the readers or the
    /// tailer. `handleStdoutLine` reopens the turn when another
    /// segment arrives; the child's own exit runs the full cleanup in
    /// `finalizeTurn`; a child that lingers with nothing left to say
    /// costs an idle process, and the next send reaps it.
    private func endTurnSegment() {
        guard status.isRunning else { return }
        disarmStallNotice()
        retryNotice = ""
        compacting = false
        setStatus(.done(exitCode: 0, errorMessage: nil))
    }

    /// A new segment is streaming from a child whose previous segment
    /// already ended — the turn is live again, clocked from now.
    private func reopenTurnSegment() {
        turnDurationStamped = false
        setStatus(.running(startedAt: Date()))
    }

    /// Arm the bounded finalize used by Stop. Single-slot: at any
    /// moment there is exactly one pending bound on the turn.
    private func armTurnFinalize(after delay: TimeInterval, reason: String) {
        disarmTurnEndWatchdog()
        let token = runToken
        turnEndWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self,
                  self.runToken == token, self.status.isRunning else { return }
            self.finalizeTurn(token: token,
                              exitCode: Self.exitCodeIfExited(self.process),
                              errorMessage: nil,
                              fallbackReason: reason)
        }
    }

    private func disarmTurnEndWatchdog() {
        turnEndWatchdog?.cancel()
        turnEndWatchdog = nil
    }

    /// How long a turn may produce NOTHING before the transcript says
    /// so. Generous on purpose: a cold agent start behind a slow link,
    /// or a first tool call that takes a while to come back, can
    /// legitimately run for minutes before the first visible event,
    /// and this row is worth nothing if it cries wolf.
    ///
    /// `AgentSessionView.stalledNoticeRow` NAMES this duration in its
    /// sentence, in every language it is translated into. Moving the
    /// number here means moving that string and its translations with
    /// it, or the transcript reports a wait it never made.
    private static let firstOutputGrace: TimeInterval = 300

    /// Bound the SILENCE at the start of a turn — the one failure mode
    /// the transcript had no way to describe.
    ///
    /// Every other way a turn goes wrong ends with the child EXITING,
    /// and a non-zero exit surfaces `stderrTail` as an error row. An
    /// agent that cannot reach the network does neither: it retries in
    /// silence — empty stdout, empty stderr, no exit — so the session
    /// shows a bare "Sipping…" and nothing else for as long as the
    /// user's patience lasts. Nothing is wrong that the user can see;
    /// that is the entire problem.
    ///
    /// This does NOT touch the turn's lifecycle. Nothing is killed, no
    /// status flips, no finalize is armed: a turn that is merely slow
    /// is still a turn, and the agent may yet answer. It publishes ONE
    /// latch, once, and the view puts a static line under the spinner
    /// it is already showing.
    ///
    /// A latch and not a countdown, deliberately — see `waitingRow`
    /// and the "nothing in the transcript may be TIME-based" rule: a
    /// ticking row re-renders the entire transcript once a second for
    /// the length of every turn, which is why the elapsed time lives
    /// two panes away in the composer's `TurnClockChip`. The cost here
    /// is one re-render per stalled turn.
    private func armStallNotice() {
        stallNoticeTask?.cancel()
        turnProducedNothing = false
        let token = runToken
        stallNoticeTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.firstOutputGrace * 1_000_000_000))
            guard !Task.isCancelled, let self,
                  self.runToken == token, self.status.isRunning,
                  self.awaitingFirstOutput,
                  // A retry notice already says why nothing is coming
                  // back, and says it accurately. This row's guess at
                  // the cause would contradict it.
                  self.retryNotice.isEmpty else { return }
            // Publish what the child has said on stderr by now. The
            // reader otherwise only assigns at EOF, so on a turn that
            // never exits its buffer is never seen — and a hung agent
            // that DID explain itself there deserves to be read.
            self.publishStderrTail()
            self.turnProducedNothing = true
            NSLog("%@", "SipAI: \(self.agentKey) turn produced no output in "
                  + "\(Int(Self.firstOutputGrace))s — "
                  + (self.stderrTail.isEmpty
                     ? "stderr empty (a blocked network route looks exactly like this)"
                     : "stderr: \(self.stderrTail)"))
        }
    }

    private func disarmStallNotice() {
        stallNoticeTask?.cancel()
        stallNoticeTask = nil
        turnProducedNothing = false
    }

    /// Whether this turn has yet produced anything the user can see.
    ///
    /// Mirrors `RunnerStreamView.awaitingFirstAgentEvent`, including
    /// the reason `.systemInit` does not count: the handshake lands in
    /// milliseconds, so counting it would mask every stall there is.
    private var awaitingFirstOutput: Bool {
        for event in events.reversed() {
            switch event.kind {
            case .userMessage: return true
            case .systemInit: continue
            default: return false
            }
        }
        return true
    }

    /// Hand the UI the current stderr buffer. The only writer of
    /// `stderrTail`; see that property for why it isn't per line.
    private func publishStderrTail() {
        stderrTail = String(stderrBuffer.suffix(500))
    }

    /// A process's exit code, or -1 while it is still running.
    ///
    /// NEVER read `terminationStatus` unguarded: Foundation raises on a
    /// process that hasn't exited, and the finalize fallbacks can run
    /// while the child is (pathologically) still alive.
    private static func exitCodeIfExited(_ p: Process?) -> Int32 {
        guard let p, !p.isRunning else { return -1 }
        return p.terminationStatus
    }

    /// End the turn: flip the status, drop the child, and hand the
    /// session's JSONL back to the tailer.
    ///
    /// Idempotent and token-scoped, because it now has three callers —
    /// `runOnce`'s normal join, the turn-end watchdog, and Stop — and
    /// the losers of that race must do nothing at all. `runToken` is
    /// what keeps a fallback armed for turn N from finalizing turn N+1.
    ///
    /// Deliberately NOT gated on the readers. Draining the last bytes of
    /// stdout is a data concern; whether a turn is still running is a
    /// state concern, and gating the second on the first lets a single
    /// missed EOF pin the UI at "Sipping…" forever.
    @discardableResult
    private func finalizeTurn(token: Int,
                              exitCode: Int32,
                              errorMessage: String?,
                              fallbackReason: String? = nil) -> Bool {
        // Two things can still be owed here: the visible turn's state
        // flip (a turn that never got a `result` — crash, kill, spawn
        // failure) and the process cleanup. Either suffices to proceed;
        // a call with neither left to do is the idempotent no-op.
        guard token == runToken, status.isRunning || process != nil else {
            return false
        }
        disarmTurnEndWatchdog()
        // A kimi Chat only turn wrote the session's tool-policy file;
        // the child is gone (or being killed), so put it back now —
        // whichever of the finalize callers got here first.
        restoreKimiToolPolicyIfPending()
        // A codex image turn's temp files have been read by now.
        cleanupCodexImageFilesIfPending()
        if status.isRunning {
            if let reason = fallbackReason {
                // The ordinary path finalizes from the join, so reaching
                // here at all means a reader never came back. Name which
                // one — this log line is the only evidence of which.
                NSLog("%@", "SipAI: finalizing turn without the readers (\(reason)) — "
                      + "stdout=\(stdoutReaderFinished ? "done" : "STUCK") "
                      + "stderr=\(stderrReaderFinished ? "done" : "STUCK") "
                      + "childExit=\(childExitObserved ? "seen" : "NOT SEEN")")
            }
            if let errText = errorMessage {
                events.append(StreamEvent(kind: .error(message: errText)))
            }
            // The turn is over, so the notice has nothing left to warn
            // about — whatever happened is now described by the error
            // row, the answer, or the interrupted row.
            disarmStallNotice()
            retryNotice = ""
            compacting = false
            waitingForToolUpdate = false
            // Last chance to freeze the composer's clock. A no-op for a
            // turn that emitted `result` or was stopped; the only stamp
            // a kimi turn ever gets, since its stdout has no turn-end
            // event.
            stampTurnDuration()
            setStatus(.done(exitCode: exitCode, errorMessage: errorMessage))
        }
        process = nil
        // The child is gone — any approval card still pending for this
        // session is unanswerable now (its asker died). Normally the
        // turn can't end with one up (claude blocks on the answer),
        // but a crash or kill can leave one; without this the card and
        // its sidebar badge outlive the question forever.
        cancelPendingApprovals()

        // Late session-file discovery: system.init announces the id
        // before claude has created the JSONL, and a one-shot miss would
        // leave the draft permanently half-migrated (no tailer, no
        // external-turn detection, view never flips to the existing
        // session). `awaitSessionFile` normally lands it within a poll
        // of the announcement; this is the backstop for a turn that died
        // first, and the file certainly exists once the turn is over.
        if sessionFileURL == nil, let sid = sessionId,
           let url = locateSessionFile(id: sid) {
            adoptSessionFile(url, id: sid)
        }

        // Subprocess has finished writing. Resume the tailer at the
        // current file size so any future external appends are picked
        // up without replaying records our own subprocess just wrote.
        if let url = sessionFileURL {
            tailer?.resume(atOffset: Self.currentSize(of: url))
        }
        // Backstop for the codex and kimi context chips, after the
        // late-discovery block above has had its chance to name the
        // store file. A turn that was stopped or that died never
        // emitted the `result` that normally carries this — same
        // reasoning as `stampTurnDuration`. For kimi this is also the
        // FIRST chance on a draft's opening turn, whose session id
        // only arrives with the last stdout line.
        refreshCodexContextTokens()
        refreshKimiContextTokens()
        // The wire is complete: every thought of a kimi Chat only turn
        // can be placed now, including one whose step never reached
        // stdout (a stopped turn).
        syncKimiThoughts(final: true)
        recordChatOnlyTurnIfNeeded()
        return true
    }

    // MARK: - Chat only turns: the record and kimi's thoughts

    /// Hand out a finished Chat only turn's handle (see
    /// `onChatOnlyTurnRecorded`), resolved off the main thread by the
    /// same newest-first text match the branch writers use for a live
    /// row. Best effort: a turn whose record cannot be found keeps its
    /// look until the session is reopened, then reads as an agent turn.
    private func recordChatOnlyTurnIfNeeded() {
        guard turnChatOnly, !chatOnlyTurnRecorded,
              let sid = sessionId, !sid.isEmpty,
              let text = inFlightUserText else { return }
        chatOnlyTurnRecorded = true
        let key = agentKey
        let known = sessionFileURL
        Task.detached(priority: .utility) { [weak self] in
            guard let url = known ?? Self.locateSessionFile(id: sid, agentKey: key)
            else { return }
            let handle: String?
            switch key {
            case "codex":
                handle = CodexSessionFork.resolveCutPoint(matchingUserText: text, in: url)
            case "kimi":
                handle = KimiSessionFork.resolveCutPoint(matchingUserText: text, in: url)
            default:
                handle = AgentSessionFork.resolveCutPoint(matchingUserText: text, in: url)
            }
            guard let handle, !handle.isEmpty else { return }
            await MainActor.run { [weak self] in
                self?.onChatOnlyTurnRecorded?(sid, handle)
            }
        }
    }

    /// Read this kimi Chat only turn's thoughts back off the wire and
    /// place the ones not yet in `events`.
    ///
    /// Kimi's print-mode stdout carries no thinking at all, while its
    /// wire records every step's. Single-flight: a request that arrives
    /// while a read is running is folded into one more read after it,
    /// and `final` is sticky across that fold — the finalize call must
    /// never be absorbed by an earlier, non-final read.
    private func syncKimiThoughts(final: Bool = false) {
        guard isKimi, turnChatOnly else { return }
        if final { kimiThoughtSyncFinal = true }
        guard !kimiThoughtSyncRunning else {
            kimiThoughtSyncPending = true
            return
        }
        guard let wire = sessionFileURL
                ?? sessionId.flatMap({ KimiSessionScanner.sessionDirectory(forId: $0) })
                    .map({ KimiSessionScanner.wireFile(inSessionDir: $0) })
        else { return }
        kimiThoughtSyncRunning = true
        kimiThoughtSyncPending = false
        let isFinal = kimiThoughtSyncFinal
        let token = runToken
        Task.detached(priority: .utility) { [weak self] in
            // The current turn only, from a tail that comfortably holds
            // one chat turn: this runs once per step.
            let items = KimiSessionScanner.readHistory(
                of: wire, maxTurns: 1, byteBudget: 2 * 1024 * 1024,
                includeThinking: true)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.kimiThoughtSyncRunning = false
                if token == self.runToken {
                    self.placeKimiThoughts(from: items, final: isFinal)
                }
                if self.kimiThoughtSyncPending {
                    self.syncKimiThoughts()
                }
            }
        }
    }

    /// Insert the wire's thoughts into this turn's events where
    /// `KimiSessionScanner.thoughtPlacements` says — each BEFORE the row
    /// it led to — and never by replacing events: replacing would mint
    /// new row ids and collapse whatever the user had opened.
    private func placeKimiThoughts(from items: [AgentSessionHistoryItem],
                                   final: Bool) {
        guard let start = events.lastIndex(where: Self.opensTurn) else { return }
        let rows: [KimiSessionScanner.LiveRow] = events[(start + 1)...].map { event in
            switch event.kind {
            case .toolUse(let id, _, _): return .toolUse(id: id)
            case .toolResult: return .toolResult
            case .assistantText(let text): return .text(text)
            case .thinking: return .thought
            default: return .other
            }
        }
        for placement in KimiSessionScanner.thoughtPlacements(
            wireItems: items, turnRows: rows,
            alreadyPlaced: kimiThoughtsPlaced, final: final) {
            events.insert(StreamEvent(kind: .thinking(text: placement.text)),
                          at: start + 1 + placement.at)
            kimiThoughtsPlaced += 1
        }
    }

    /// Stop a turn some OTHER claude process is running on this
    /// session — the app-relaunch orphan case. Only ever a headless
    /// `-p`/SDK writer (`externalStoppablePid` stays nil for
    /// interactive terminals), and re-verified at signal time: a pid
    /// number alone can be recycled between render and click, so the
    /// heartbeat must still name this session under a live
    /// agent-looking process. Same SIGTERM → SIGKILL escalation as
    /// `killChild`.
    func stopExternalTurn() {
        guard let pid = externalStoppablePid,
              let sid = sessionId, !sid.isEmpty else { return }
        guard ClaudeSessionStatusStore.pidStillOwnsSession(pid: pid,
                                                          sessionId: sid) else {
            externalStoppablePid = nil
            return
        }
        externalTurnWasStoppedByUser = true
        // Freeze the chip on the turn's own clock (transcript stamp);
        // the tailer's idle sweep flips the running state off once the
        // writer is gone.
        if let start = externalTurnStartedAt {
            lastTurnDuration = Date().timeIntervalSince(start)
        }
        events.append(StreamEvent(kind: .interrupted(message:
            Self.interruptedByUserMessage)))
        kill(pid, SIGTERM)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, let sid = self.sessionId else { return }
            if ClaudeSessionStatusStore.pidStillOwnsSession(pid: pid,
                                                            sessionId: sid) {
                NSLog("%@", "SipAI: external claude (pid \(pid)) ignored SIGTERM — sending SIGKILL.")
                kill(pid, SIGKILL)
            }
        }
    }

    /// React to the tailer's liveness flips: derive the external
    /// turn's start instant and whether its writer is stoppable (both
    /// need file/store reads — off-main), clear both when it ends.
    private func handleExternalProgressFlip(_ inProgress: Bool) {
        guard inProgress else {
            externalTurnStartedAt = nil
            externalStoppablePid = nil
            return
        }
        // A fresh turn: whatever the user did to the last one is over.
        externalTurnWasStoppedByUser = false
        guard let url = sessionFileURL else { return }
        let sid = sessionId
        let agent = agentKey
        Task.detached(priority: .utility) { [weak self] in
            // Each agent's own record of when the turn began. Only claude
            // leaves a writer this app may stop — a headless `claude -p`
            // it orphaned; codex and kimi keep a disabled Stop, like an
            // interactive terminal claude.
            let start: Date?
            let stoppable: Int32?
            switch agent {
            case "codex":
                start = CodexSessionScanner.latestTurn(of: url)?.startedAt
                stoppable = nil
            case "kimi":
                start = KimiSessionScanner.latestTurn(of: url)?.startedAt
                stoppable = nil
            default:
                start = AgentSessionScanner.lastTurnStartDate(of: url)
                stoppable = sid.flatMap {
                    ClaudeSessionStatusStore.stoppableExternalPid(sessionId: $0)
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.externalInProgress else { return }
                if let start { self.externalTurnStartedAt = start }
                self.externalStoppablePid = stoppable
            }
        }
    }

    /// Record a finished turn that ran somewhere else (same session,
    /// another terminal), read back from the transcript because an
    /// external turn has no clock of ours to read.
    ///
    /// It goes through the RUNNER rather than straight into the view's
    /// mirror because `@Published` replays its current value to every
    /// resubscription, and `onReceive` resubscribes on each render — a
    /// value parked only in the view would be overwritten by the replay
    /// of this older one within a frame.
    func noteExternalTurnDuration(_ seconds: Double) {
        guard seconds > 0 else { return }
        lastTurnDuration = seconds
    }

    /// Adopt a context total the session view just read off the
    /// transcript. Same reasoning as `noteExternalTurnDuration`, and the
    /// same reason it cannot be parked in the view alone: the reload
    /// clears the view's mirror and the replay of THIS value refills it,
    /// so a total the runner still remembers from an earlier turn would
    /// win over the fresher one from disk within a frame.
    ///
    /// Refused while a turn of ours is running — the live stream is then
    /// the newer source, and a read taken mid-turn is behind it. An
    /// external turn is the opposite case: the transcript is the only
    /// place its usage is recorded, so it must be able to land here.
    func noteTranscriptContextTokens(_ total: Int, window: Int = 0) {
        guard total > 0, !status.isRunning else { return }
        lastContextTokens = total
        // Same delivery rule as the total it rides with; 0 means the
        // read found none and must not erase a window already known.
        if window > 0 { lastContextWindow = window }
    }

    /// Drop the live event buffer. The session view calls this after a
    /// completed history reload: the JSONL on disk is the superset of
    /// every FINISHED turn, so keeping the buffer would render those
    /// turns twice (history copy above, live copy below). Refused
    /// mid-turn — the current turn's events aren't fully on disk yet.
    func clearEvents() {
        guard !status.isRunning else { return }
        events.removeAll()
        trimmedHeadChatOnly = false
    }

    // MARK: - Argument construction

    private func claudeArguments(text: String,
                                 options: AgentLaunchOptions,
                                 streamJSONInput: Bool = false) -> [String] {
        // An image turn reads its whole prompt (text + image blocks) as
        // a stream-json message on stdin, so the positional prompt is
        // dropped and `--input-format stream-json` is added; `-p` stays
        // (the input format is only valid with it). Every other turn
        // passes the prompt positionally.
        var args: [String] = streamJSONInput
            ? ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
            : ["-p", text, "--output-format", "stream-json", "--verbose"]
        args.append(contentsOf: options.flags(for: agentKey))
        // Chat only: web lookups only, no MCP, the persona — in `ChatOnlyArgv`'s
        // order, BEFORE `--resume`, because two of its flags are
        // variadic and would swallow the id. The snapshot-off flag
        // rides every claude turn, but only when the installed `--help`
        // lists it (an unknown flag is a startup error).
        args.append(contentsOf: ChatOnlyArgv.claude(
            options: options,
            snapshotFlagListed: ClaudeCapabilities.shared.chatOnlyHelp?.listsSnapshot == true,
            thinkingDisplayAccepted: ClaudeCapabilities.shared.acceptsThinkingSummaries == true))
        if let id = sessionId, !id.isEmpty {
            args.append("--resume")
            args.append(id)
        }
        // The only tools left are the web lookups, pre-approved by the
        // list itself, so there is nothing to approve: the bridge's
        // `--mcp-config … --permission-prompt-tool …` pair is omitted on
        // a Chat only turn — and it would re-add the approver as an MCP
        // server the empty strict config just removed. The environment
        // overlay stays: harmless, and the alias registration on
        // `system.init` still has a bridge to talk to.
        if let bridge = bridge, !options.chatOnly {
            args.append(contentsOf: bridge.argsForClaude())
        }
        return args
    }

    /// `codex exec` — the headless, JSONL-streaming counterpart of
    /// `claude -p --output-format stream-json`.
    ///
    /// Two shapes, because resume is a SUBCOMMAND here rather than a
    /// flag: `codex exec [OPTS] <prompt>` for a new thread and
    /// `codex exec resume [OPTS] <id> <prompt>` to continue one. Both
    /// take their positional arguments last, so every option is
    /// appended before them.
    private func codexArguments(text: String,
                                options: AgentLaunchOptions,
                                imageFiles: [URL] = []) -> [String] {
        var args = ["exec"]
        let resuming = (sessionId?.isEmpty == false)
        if resuming { args.append("resume") }
        // `--json` is the whole contract with `CodexEventParser`.
        args.append("--json")
        // Codex refuses to run outside a git repo or a trusted
        // directory — "Not inside a trusted directory and
        // --skip-git-repo-check was not specified", exit 1, before a
        // single event is emitted. SipAI lets people point a session at
        // ANY folder, so that check would turn ordinary folders into a
        // dead end with no in-app way out. The real safety boundary is
        // the sandbox flag below, which is preserved either way.
        args.append("--skip-git-repo-check")
        // NB: no `--color`. `codex exec` accepts it, `codex exec
        // resume` does not ("unexpected argument '--color'", exit 2) —
        // and since every send after the first resumes, it would break
        // every follow-up turn while the first one worked. It is not
        // needed anyway: `--json` output arrives clean under our PTY,
        // no colour codes.
        //
        // The speed rides `codexServiceTierOverride`, which the
        // composer's send resolved against the model's advertised tiers
        // (`CodexCatalog.serviceTierOverride`); a send that set none
        // runs at what `codex exec` resolves by itself.
        args.append(contentsOf: options.flags(for: agentKey))
        // Chat only: the `-c` switch set, and the persona file on RESUMED
        // turns only — `bornPlain` is exactly `resuming`, which is the
        // birth rule (a thread must never be born with the persona; see
        // `ChatOnlyArgv.codex`). The file itself is ensured by `runOnce`
        // before the spawn.
        args.append(contentsOf: ChatOnlyArgv.codex(
            options: options, bornPlain: resuming,
            personaFile: SipaiPaths.chatOnlyInstructionsFile.path))
        // The session id (resume only), the positional prompt, then
        // `-i <file>` per image — the order is a correctness rule
        // (`-i` is variadic on `codex exec` and would swallow the
        // prompt if placed first), spelled once in `ChatOnlyImages` so
        // the harness can pin it.
        args.append(contentsOf: ChatOnlyImages.codexTrailingArgs(
            resuming: resuming, sessionId: sessionId, text: text,
            imageFiles: imageFiles.map(\.path)))
        return args
    }

    /// Write each image to a temp file for a codex `-i` turn and return
    /// the paths. Best effort — a file that cannot be written is
    /// dropped (its name still rides the message text, so the bubble is
    /// honest), rather than failing the whole turn.
    private func writeCodexImageFiles(_ images: [AgentImage]) -> [URL] {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(Self.codexImageDirectoryPrefix + UUID().uuidString.prefix(8),
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [URL] = []
        for (i, image) in images.enumerated() {
            guard let data = Data(base64Encoded: image.base64) else { continue }
            let ext = ChatOnlyImages.codexFileExtension(mediaType: image.mediaType)
            let file = dir.appendingPathComponent("image-\(i).\(ext)")
            if (try? data.write(to: file)) != nil { files.append(file) }
        }
        return files
    }

    nonisolated static let codexImageDirectoryPrefix = "sipai-codex-image-"

    /// At launch: remove the image folders a crash or a force-quit left
    /// in the temp folder — a user's screenshots, kept past their turn.
    /// Only folders an hour old: the temp folder is shared with any other
    /// copy of SipAI running, whose turn may still be reading its own.
    nonisolated static func sweepStaleCodexImageFiles(now: Date = Date()) {
        let fm = FileManager.default
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(codexImageDirectoryPrefix) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            if now.timeIntervalSince(modified) > 60 * 60 {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Remove the temp image files a codex turn was handed. Called from
    /// `finalizeTurn` (first caller wins, like the kimi tool-policy
    /// restore) and from the spawn-failure path.
    private func cleanupCodexImageFilesIfPending() {
        guard !pendingCodexImageFiles.isEmpty else { return }
        let files = pendingCodexImageFiles
        pendingCodexImageFiles = []
        let dirs = Set(files.map { $0.deletingLastPathComponent() })
        for file in files { try? FileManager.default.removeItem(at: file) }
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
    }

    /// `kimi --prompt … --output-format stream-json` — the headless,
    /// JSONL-streaming counterpart of `claude -p --output-format
    /// stream-json` and `codex exec --json`.
    ///
    /// The argv is deliberately the SMALLEST set kimi's published
    /// references agree on, because the failure mode of a wrong flag
    /// is not a degraded feature — an argument kimi doesn't recognise
    /// exits 2 before a single event is emitted, i.e. the whole turn
    /// dies. What is left out, and why:
    ///
    ///  * No `--print`. The newer reference documents `--prompt` as
    ///    "run a single prompt non-interactively", and does not list
    ///    `--print` among the flags at all; the older one has both.
    ///    `--prompt` alone is the intersection.
    ///  * No `--work-dir`. Only the older reference carries it, and
    ///    `Process.currentDirectoryURL` already puts the child in the
    ///    right folder, so the flag would be risk without a job.
    ///  * No permission-mode flag, ever. Kimi rejects the combination
    ///    outright — "--prompt cannot be used with --yolo, --auto, or
    ///    --plan" — because print mode implies `--afk` and approves
    ///    every tool call on its own. That is also why the composer
    ///    shows kimi a fixed auto-approve chip instead of a picker: an
    ///    option that cannot be sent must not be offered.
    ///  * No effort flag — because kimi has none, NOT because it has
    ///    no effort. It grades thinking low → max and takes the per-run
    ///    override through the ENVIRONMENT, which `runOnce` overlays
    ///    onto the child (`KimiCapabilities.environmentOverlay`).
    ///
    /// `--output-format` is documented as valid ONLY alongside
    /// `--prompt`, which this always passes, and `--session <id>` is
    /// how every send after the first continues the conversation.
    private func kimiArguments(text: String,
                               options: AgentLaunchOptions) -> [String] {
        var args = ["--prompt", text]
        // The whole contract with `KimiEventParser`.
        args.append(contentsOf: ["--output-format", "stream-json"])
        args.append(contentsOf: options.flags(for: agentKey))
        if let id = sessionId, !id.isEmpty {
            args.append(contentsOf: ["--session", id])
        }
        return args
    }

    // MARK: - Run loop

    private func runOnce(text: String, options: AgentLaunchOptions,
                         images: [AgentImage] = []) async {
        // Every await below is a moment Stop can land in. `cancel()`
        // finalizes a turn with no child at once; a spawn after that
        // would stream a ghost turn under the interrupted row, and a
        // second send meanwhile would find this one's policy file and
        // temp files still in the way. So after each await: still ours,
        // or put everything prepared so far back and stop.
        let token = runToken
        func turnStillOurs() -> Bool {
            token == runToken && !stopRequested && status.isRunning && !Task.isCancelled
        }

        // SipAI is replacing this tool's binary right now. A spawn in the
        // middle of that can find half a tool (an npm install removes the
        // package before it writes the new one), so the turn waits for
        // the update and runs on whatever version it leaves — FIRST,
        // before anything below reads the binary's path. The wait is not
        // the agent's silence: the stall notice is armed for the spawn,
        // not for the queue. A Stop meanwhile ends the turn at once
        // (`cancel()` finalizes a turn with no child); this task then
        // finds its turn gone when the update ends, and runs nothing.
        if AgentCLIUpdateMonitor.shared.isUpdating(agentKey) {
            disarmStallNotice()
            waitingForToolUpdate = true
            await AgentCLIUpdateMonitor.shared.waitForUpdate(agentKey: agentKey)
            guard turnStillOurs() else { return }
            waitingForToolUpdate = false
            armStallNotice()
        }

        guard let binary = AgentManager.binaryPath(for: agentKey) else {
            let name = AgentManager.registry
                .first { $0.key == agentKey }?.name ?? agentKey
            events.append(StreamEvent(kind: .error(message:
                String(localized: "\(name) is not installed on this machine.",
                       comment: "Runner error when an agent binary is missing"))))
            setStatus(.done(exitCode: -1,
                            errorMessage: "\(name) not installed."))
            return
        }

        // A kimi DRAFT's first Chat only turn has no session directory
        // to put a tool-policy file in, and a session born through
        // kimi's server refuses `--prompt` until its first prompt — so
        // that one turn goes through the server. Every later turn is
        // the ordinary spawn below, around the policy file.
        if isKimi, options.chatOnly, sessionId?.isEmpty ?? true {
            await runKimiWebTurn(text: text, options: options, images: images, binary: binary)
            return
        }

        // A resumed kimi turn is `--prompt --session`, which has no
        // image input — so an image cannot reach the model on one, and
        // sending the words alone would be a silent drop. The composer
        // refuses images on a resumed kimi session at stage time
        // (`ChatOnlyImages.kimiResumeAcceptsImages`); this is the
        // backstop, so nothing ever runs a turn whose picture went
        // nowhere.
        if isKimi, !images.isEmpty, !(sessionId?.isEmpty ?? true) {
            events.append(StreamEvent(kind: .error(message:
                String(localized: "An image can only be attached to a NEW \(agentDisplayName) chat, not to one already under way.",
                       comment: "Runner error: images are refused on a resumed kimi session; placeholder is the agent label"))))
            setStatus(.done(exitCode: -1, errorMessage: "images unsupported on a resumed kimi turn"))
            return
        }

        // Codex reads the Chat only persona from a FILE; make sure it
        // says what the constant says before the spawn.
        if agentKey == "codex", options.chatOnly {
            do {
                try ChatOnlyPersona.ensureFile(at: SipaiPaths.chatOnlyInstructionsFile)
            } catch {
                events.append(StreamEvent(kind: .error(message:
                    String(localized: "Chat only could not be prepared: \(error.localizedDescription)",
                           comment: "Runner error when the Chat only persona file cannot be written; placeholder is the system's error text"))))
                setStatus(.done(exitCode: -1, errorMessage: error.localizedDescription))
                return
            }
        }

        // Ensure MCP runtime is up before spawning claude.
        // Safe to call from every send — `ensureRuntime` is idempotent.
        if let bridge = bridge {
            do {
                try bridge.ensureRuntime()
            } catch {
                events.append(StreamEvent(kind: .error(message:
                    String(localized: "MCP approver setup failed: \(error.localizedDescription)",
                           comment: "Runner error when MCPBridge.ensureRuntime throws"))))
                setStatus(.done(exitCode: -1, errorMessage: error.localizedDescription))
                return
            }
        }

        // Decide which identifier we pass as SIPAI_SESSION_ID.
        // Existing session → dashed session UUID.
        // Fresh draft     → 32-char hex task_uuid we generate once.
        let sipaiIdentity: String = {
            if let id = sessionId, !id.isEmpty {
                return id
            }
            if let existing = taskUuid {
                return existing
            }
            let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            taskUuid = fresh
            return fresh
        }()

        // Images travel each CLI's own image channel. Codex reads FILES
        // (`-i <path>`), so its images are written to temp files now and
        // removed when the turn ends; claude reads a stream-json message
        // on STDIN, built below and written after the spawn. Kimi never
        // reaches here with images (a draft goes through the server; a
        // resume was refused above).
        var codexImageFiles: [URL] = []
        if agentKey == "codex", !images.isEmpty {
            codexImageFiles = writeCodexImageFiles(images)
            // Added to, never replacing: a send that supersedes a turn
            // still winding down moves the run token, so that turn's
            // finalize no-ops — its files are only ever removed here.
            pendingCodexImageFiles += codexImageFiles
        }
        // claude's stdin line, when this turn carries images: the whole
        // prompt (text + image blocks) comes from stdin under
        // `--input-format stream-json`, so nothing positional is passed.
        let claudeStdinLine: String? =
            (agentKey != "codex" && !isKimi && !images.isEmpty)
            ? ChatOnlyImages.claudeStdinLine(text: text, images: images)
            : nil

        let args: [String]
        switch agentKey {
        case "codex": args = codexArguments(text: text, options: options, imageFiles: codexImageFiles)
        case "kimi":  args = kimiArguments(text: text, options: options)
        default:      args = claudeArguments(text: text, options: options,
                                             streamJSONInput: claudeStdinLine != nil)
        }

        // Kimi names its session on stdout only with the turn's final
        // answer, so a draft's id is read back off the store meanwhile —
        // and telling OUR new session apart from the ones already there
        // needs the "before" list taken before the child can create
        // anything. Cheap: two levels of directory names, no file reads.
        let kimiKnownIds: Set<String> =
            (isKimi && (sessionId?.isEmpty ?? true))
            ? KimiSessionScanner.sessionIds() : []

        // A resumed kimi Chat only turn: the session's tool-policy file
        // is written NOW (journaled first) and put back when the turn
        // ends. A file of a shape this app does not know refuses the
        // send — nothing is written, no turn runs with tools under a
        // chip that says otherwise.
        if isKimi, options.chatOnly, let id = sessionId, !id.isEmpty {
            guard await prepareKimiToolPolicy(sessionId: id) else {
                setStatus(.done(exitCode: -1, errorMessage: "Chat only refused"))
                return
            }
        }
        guard turnStillOurs() else {
            restoreKimiToolPolicyIfPending()
            cleanupCodexImageFilesIfPending()
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        p.currentDirectoryURL = cwd
        // `codex exec` reads its prompt from stdin when stdin is not a
        // terminal, and BLOCKS until EOF — a piped stdin hangs the
        // turn forever on "Reading additional input from stdin…". A
        // GUI app's inherited stdin is not something to gamble on, so
        // hand it an explicitly empty one. Harmless for claude, which
        // never reads stdin under `-p` — EXCEPT the one image turn,
        // where the prompt (text + image blocks) is the stream-json
        // message written below and stdin must be a pipe we close.
        let stdinPipe: Pipe? = claudeStdinLine != nil ? Pipe() : nil
        p.standardInput = stdinPipe ?? FileHandle.nullDevice

        // Build PATH-rich env + overlay MCP-related vars. The await is
        // load-bearing: `buildEnvironment` reads the login shell's
        // captured environment for the proxy settings, and that read
        // BLOCKS while the capture is still in flight — which on the
        // MainActor would freeze the app. Normally a no-op; `warmUp()`
        // has run since launch.
        await ShellEnvironment.prepare()
        guard turnStillOurs() else {
            restoreKimiToolPolicyIfPending()
            cleanupCodexImageFilesIfPending()
            return
        }
        var env = Self.buildEnvironment()
        if let bridge = bridge {
            for (k, v) in bridge.environmentOverlay(sessionIdOrTaskUuid: sipaiIdentity) {
                env[k] = v
            }
        }
        // Background tasks do not survive `claude -p` — a still-running
        // one is killed five seconds after the turn's `result`, and
        // nothing on either feed says so. Disabling the feature makes
        // claude drop `run_in_background` from the Bash tool's schema
        // outright, so the agent runs the command in the foreground
        // where its result can actually land. See
        // `ClaudePrintMode.environmentOverlay` for the measurements,
        // for why this OVERRIDES anything inherited from the user's
        // shell rather than deferring to it, and for why codex and kimi
        // are deliberately left alone.
        for (k, v) in ClaudePrintMode.environmentOverlay(agentKey: agentKey) {
            env[k] = v
        }
        // Kimi's effort is the one per-send choice that does not travel
        // as an argument — it has no flag, so the composer's chip
        // arrives here or nowhere. Applied AFTER `buildEnvironment`,
        // which starts from our own process environment: a
        // KIMI_MODEL_THINKING_EFFORT exported in the user's shell must
        // not outrank the level they just picked in the composer.
        for (k, v) in KimiCapabilities.environmentOverlay(
            agentKey: agentKey, effort: options.effort) {
            env[k] = v
        }
        p.environment = env

        // Route stdout through a PTY so Node (claude) line-flushes.
        // Without this, claude's stdout is block-buffered and the whole
        // turn's stream-json arrives only after the process exits — the
        // UI sees one big burst instead of incremental events.
        let stdoutSource = Self.makeChildStdoutSource()
        let stderrPipe = Pipe()
        p.standardOutput = stdoutSource.handleForChild
        p.standardError = stderrPipe

        // Our subprocess is about to become the active writer on the
        // session JSONL. Suspend the external-activity tailer so it
        // doesn't re-render records we're producing ourselves.
        tailer?.suspend()

        // The termination handler MUST be installed before run(): a
        // handler assigned after an instant-exit child has already been
        // reaped never fires, which would leak waitForExit's
        // continuation and pin status at .running forever (spinner
        // never stops, Stop can't help because the process isn't
        // running).
        let exitWaiter = ExitWaiter()
        p.terminationHandler = { _ in exitWaiter.markExited() }

        do {
            try p.run()
        } catch {
            let name = AgentManager.registry
                .first { $0.key == agentKey }?.name ?? agentKey
            events.append(StreamEvent(kind: .error(message:
                String(localized: "Could not start \(name): \(error.localizedDescription)",
                       comment: "Runner error when Process.run() throws"))))
            setStatus(.done(exitCode: -1, errorMessage: error.localizedDescription))
            stdoutSource.cleanup()
            // No child ever read the policy file: put it straight back.
            restoreKimiToolPolicyIfPending()
            // Nor the temp image files: remove them.
            cleanupCodexImageFilesIfPending()
            // Failed to spawn — tailer is back to being the only writer.
            // Resume immediately so it keeps watching.
            if let url = sessionFileURL {
                tailer?.resume(atOffset: Self.currentSize(of: url))
            }
            return
        }
        // Close the parent's copy of the PTY slave (if any) so the
        // master fd gets EOF when the child exits.
        stdoutSource.afterSpawn()
        process = p

        // claude's image turn: hand it the stream-json user record and
        // close the write end, so it reads one message and reaches EOF
        // (the turn is exactly that message). Done off the MainActor —
        // the payload is a few hundred KB of base64 and the write can
        // block until claude drains it.
        if let line = claudeStdinLine, let pipe = stdinPipe {
            let handle = pipe.fileHandleForWriting
            // The payload is larger than the pipe's buffer, so the write
            // blocks until claude drains it — and a claude that exits
            // first (a startup failure, a Stop in the first second)
            // would deliver SIGPIPE to THIS process and end it. Told
            // not to, the write fails with EPIPE and the task ends.
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            Task.detached(priority: .utility) {
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            }
        }

        if isKimi, sessionId == nil {
            startKimiSessionDiscovery(excluding: kimiKnownIds, since: Date(),
                                      prompt: text)
        }

        // Two concurrent readers: stdout (line-oriented JSON events)
        // and stderr (buffered as text, surfaced only on error). `token`
        // is this turn's, captured at the top of the function.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.readStdout(handle: stdoutSource.readHandle)
                await self?.noteReaderFinished(.stdout, token: token)
            }
            group.addTask { [weak self] in
                await self?.readStderr(handle: stderrPipe.fileHandleForReading)
                await self?.noteReaderFinished(.stderr, token: token)
            }
            // Wait for termination from a dedicated task so the readers
            // can keep pulling bytes until EOF.
            group.addTask { [weak self] in
                await self?.waitForExit(process: p, waiter: exitWaiter)
                await self?.noteReaderFinished(.childExit, token: token)
            }
            await group.waitForAll()
        }

        // All three child tasks have joined — process is done, both
        // pipes are drained. This is the ORDINARY end of a turn; the
        // bounded fallbacks exist only for when it never arrives, and
        // `finalizeTurn` makes whichever gets there first the one that
        // counts.
        let exitCode = Self.exitCodeIfExited(p)
        let errText: String? = {
            if Task.isCancelled { return nil }  // user-initiated, not an error
            if exitCode == 0 { return nil }
            let name = AgentManager.registry
                .first { $0.key == agentKey }?.name ?? agentKey
            let tail = stderrTail.isEmpty
                ? String(localized: "\(name) exited with code \(exitCode).",
                         comment: "Fallback exit-code message when stderr is empty; placeholder is the agent name")
                : stderrTail
            return tail
        }()
        finalizeTurn(token: token, exitCode: exitCode, errorMessage: errText)
    }

    /// The three things a turn waits on, tracked only so the finalize
    /// fallback can name the one that didn't come back.
    private enum TurnWait { case stdout, stderr, childExit }

    private func noteReaderFinished(_ which: TurnWait, token: Int) {
        guard token == runToken else { return }
        switch which {
        case .stdout:    stdoutReaderFinished = true
        case .stderr:    stderrReaderFinished = true
        case .childExit:
            childExitObserved = true
            // The child is gone: the readers are at EOF or will be
            // within milliseconds, and the turn is over either way.
            // This is the bound that does NOT depend on having parsed
            // a `result` — the turn-end watchdog is armed by that
            // event, so a wedge that swallows it (or that happens
            // before it lands) would otherwise have nothing at all
            // holding it, and the user would be back to pressing Stop.
            if status.isRunning {
                armTurnFinalize(after: Self.readerDrainGrace,
                                reason: "child exited, readers still draining")
            }
        }
    }

    // MARK: Stdout reader

    /// Read the child's stdout (PTY master or pipe) line-by-line on a
    /// dedicated background queue and hop each complete line to the
    /// MainActor for parsing. The loop itself is
    /// `makeDrainingLineSource`, shared with the stderr reader; this is
    /// its stdout binding. Same shape as
    /// `AgentSessionTailer.handleExtend`.
    /// See CLAUDE.md → "Agent-session streaming" for the invariant.
    private func readStdout(handle: FileHandle) async {
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let source = Self.makeDrainingLineSource(
                    fd: fd,
                    label: "sipai.runner.stdout.\(UUID().uuidString)",
                    owner: self,
                    onLine: { [weak self] line in
                        Task { @MainActor [weak self] in
                            await self?.handleStdoutLine(line)
                        }
                    },
                    // A newline-less tail is half a JSONL record, never
                    // an event — dropped, as it always was.
                    onEnd: { _ in cont.resume() }
                )
                source.resume()
            }
        } onCancel: {
            // Nothing to do, deliberately. This reader ends on EOF, and
            // EOF is guaranteed: the only holder of the child side of
            // this PTY is `claude` itself (no descendant of it inherits
            // our descriptors), and `cancel()` guarantees claude dies.
            // Do not add machinery here to force the reader closed —
            // a grandchild-holds-the-PTY deadlock cannot actually
            // occur, and cross-queue teardown of a live DispatchSource
            // is exactly the kind of complexity that breaks this path.
        }
    }

    // MARK: Draining line reader — stdout AND stderr

    /// Build a read source that drains `fd` line by line on a serial
    /// queue of its own, handing each complete line to `onLine` and —
    /// exactly once, at the true end of the stream — the newline-less
    /// tail to `onEnd`. Both readers of a child ride this ONE loop:
    /// stdout's PTY master and stderr's pipe. Two spellings of it is
    /// how the drain rules drift, and every one of them has cost a
    /// hung turn.
    ///
    /// Why not `FileHandle.bytes.lines`: Foundation performs that
    /// iterator's blocking `read()` inside one shared internal actor,
    /// so every reader in the process queues behind whichever one is
    /// parked — a second child's stderr is not read until the first
    /// child EXITS — and a loop driven from the MainActor issues its
    /// next read only after the previous line was delivered there, so
    /// a stalled main thread stops the drain outright. On the stdout
    /// side the same shape round-trips every line through the actor
    /// and makes bytes-available bursts look like end-of-run bursts.
    /// See CLAUDE.md → "Agent-session streaming".
    ///
    /// `owner` is observed weakly: a source whose runner has been
    /// deallocated cancels itself, since nothing is left to consume
    /// its lines. Pass nil for a source with no owner.
    /// Internal rather than private since the Agent Guide's sign-in
    /// child (`claude auth login` on a PTY) binds the same loop — the
    /// third binding; a fourth spelling of the drain is the thing this
    /// helper exists to prevent.
    nonisolated static func makeDrainingLineSource(
        fd: Int32,
        label: String,
        owner: AnyObject?,
        onLine: @escaping (String) -> Void,
        onEnd: @escaping (Data) -> Void
    ) -> DispatchSourceRead {
        let queue = DispatchQueue(label: label, qos: .userInitiated)
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: queue
        )
        // State captured by reference so the handler closures share
        // one leftover buffer + one end guard.
        let state = DrainState()
        let hasOwner = owner != nil
        weak let weakOwner = owner

        source.setEventHandler {
            if hasOwner, weakOwner == nil {
                source.cancel()
                return
            }
            let bufSize = 4096
            var buf = [UInt8](repeating: 0, count: bufSize)
            var accumulated = Data()
            // Set when this same invocation both read bytes and hit
            // EOF: the bytes must still be parsed — they are the tail
            // of the turn, `result` included — and only then may the
            // source be cancelled. Returning straight from the EOF
            // branch would throw that last read away.
            var atEnd = false
            while true {
                // errno is captured WITH the result, inside the
                // closure. It is thread-local but not call-local, and
                // the buffer's exclusivity/retain epilogue sits between
                // the syscall and any later read of it. Every errno
                // that is not EAGAIN ends this reader, and this reader
                // is the only thing draining the child's descriptor —
                // so a stale value read here is paid for by the whole
                // turn.
                let (n, err): (Int, Int32) =
                    buf.withUnsafeMutableBufferPointer { ptr in
                        let r = read(fd, ptr.baseAddress, bufSize)
                        return (r, r < 0 ? errno : 0)
                    }
                if n > 0 {
                    accumulated.append(buf, count: n)
                    // Keep reading. A short read does NOT mean the
                    // descriptor is drained: a PTY master hands back
                    // one line-discipline block per call, so short is
                    // the NORM here, not the exception. Stopping on it
                    // leaves the rest queued and keeps this reader
                    // permanently a wake behind the child — which is
                    // the state in which the child fills the PTY and
                    // blocks in write(), and the state in which a child
                    // that exits takes the unread tail of its turn
                    // (`result` included) down with it.
                    continue
                }
                if n == 0 {
                    // The last writer is closed: the child is gone and
                    // no further byte can arrive. This is the one true
                    // end of stream.
                    atEnd = true
                    break
                }
                if err == EINTR {
                    // A signal landed mid-syscall. Nothing ended; read
                    // again. Counting this as end-of-stream cancels the
                    // source under a LIVE child, and then nothing
                    // drains its stdout: the child blocks in write()
                    // forever, and since every turn-end bound waits on
                    // the child exiting, the turn never ends either.
                    // The session sits at "Sipping…" until the app is
                    // quit.
                    continue
                }
                if err == EAGAIN || err == EWOULDBLOCK {
                    // Drained. The source re-arms and fires again when
                    // the child writes more.
                    break
                }
                // A descriptor that can only keep failing. It has to
                // end the reader: leaving the source armed on it
                // re-enters this handler in a tight spin.
                atEnd = true
                break
            }
            defer { if atEnd { source.cancel() } }
            if accumulated.isEmpty { return }
            // Split on newline BYTES and decode complete lines only. A
            // read() ending mid-UTF-8-sequence must not discard the
            // burst (a whole-chunk String(data:) decode returns nil
            // there, silently dropping every event in the read and
            // desyncing leftover).
            state.leftover.append(accumulated)
            while let nl = state.leftover.firstIndex(of: 0x0A) {
                let lineData = state.leftover.subdata(
                    in: state.leftover.startIndex..<nl)
                state.leftover.removeSubrange(
                    state.leftover.startIndex...nl)
                guard let line = String(data: lineData,
                                        encoding: .utf8) else {
                    continue  // corrupt single line — skip it alone
                }
                onLine(line)
            }
        }
        source.setCancelHandler {
            if state.ended { return }
            state.ended = true
            onEnd(state.leftover)
        }
        return source
    }

    /// Mutable state shared between a draining source's event and
    /// cancel handlers. A reference type so both closures observe the
    /// same `leftover` buffer and `ended` flag without @escaping-inout
    /// gymnastics. Both handlers run on the source's own serial queue,
    /// so no locking is needed.
    private final class DrainState {
        var leftover = Data()
        var ended: Bool = false
    }

    /// Parse one JSONL line into zero or more StreamEvents and apply
    /// the runner's side effects. Parsing is delegated to the shared
    /// `AgentEventParser` so the tailer (external activity) and this
    /// path (our own subprocess) see identical event shapes.
    private func handleStdoutLine(_ line: String) async {
        // Each CLI has its own stdout schema — see the headers of
        // CodexEventParsing.swift and KimiEventParsing.swift. All three
        // land in the same StreamEvent types, so everything downstream
        // of here is agent-agnostic.
        let parsed: [StreamEvent]
        switch agentKey {
        case "codex":
            let read = CodexEventParser.parse(line: line, fallbackCwd: cwd,
                                              includeThinking: turnChatOnly)
            parsed = read.events
            // Newest notice REPLACES the previous one, and any real
            // output clears it: this is the state of the connection,
            // not a log of it.
            if let notice = read.notice {
                retryNotice = notice
            } else if !read.events.isEmpty {
                retryNotice = ""
            }
        case "kimi":
            // Kimi names its session on stdout exactly once, right after
            // the turn's final answer:
            //   {"role":"meta","type":"session.resume_hint",
            //    "session_id":"session_…","command":"kimi -r session_…"}
            // It is the authority, but it comes LAST — a long turn names
            // its session minutes in — so a draft's id is normally read
            // off the store long before it (`startKimiSessionDiscovery`),
            // and this is what a turn whose directory the store read
            // could not single out lands on. An announcement that names
            // a DIFFERENT session from the one adopted says the store
            // read picked someone else's; that is said in the log, since
            // by then the session has been routed, named and filed.
            if let announced = KimiEventParser.announcedSessionId(line: line) {
                if sessionId == nil {
                    adoptDiscoveredSession(
                        id: announced,
                        fileURL: KimiSessionScanner.wireFile(
                            inSessionDir: KimiSessionScanner
                                .sessionDirectory(forId: announced) ?? cwd))
                } else if let adopted = sessionId, adopted != announced {
                    NSLog("%@", "SipAI: kimi named this turn's session \(announced), "
                          + "but the runner in \(cwd.path) had adopted \(adopted) "
                          + "from the store — the next send resumes \(adopted).")
                }
            }
            parsed = KimiEventParser.parse(line: line, fallbackCwd: cwd)
        default:
            // Claude announces a compaction starting and finishing on
            // `system`/`status` records. Consulted BEFORE the parse,
            // which deliberately turns those into nothing: a
            // compaction takes half a minute during which the child
            // says nothing else, and an unexplained silence there is
            // the shape of a hang.
            if let flag = AgentEventParser.compactingSignal(line: line) {
                compacting = flag
            }
            // A refused fast call: claude says so once per turn and
            // re-sends the call at standard speed. The parse turns the
            // notification into nothing, so it is read here. The call it
            // refers to runs standard, so it is recorded as such at once —
            // otherwise the previous turn's fast call would read as the
            // newest until the re-sent call's first event lands.
            if let refusal = AgentEventParser.fastModeRefusal(line: line) {
                updateFastModeReport {
                    $0.refusal = refusal
                    $0.lastSpeed = "standard"
                }
            }
            parsed = AgentEventParser.parse(line: line, fallbackCwd: cwd,
                                            includeThinking: turnChatOnly)
        }
        for event in parsed {
            // Any real output means the summarising is over, whether or
            // not the finishing record was seen.
            if compacting { compacting = false }
            // A renderable event after this turn's own segment ended
            // means the child began a NEW segment (a background task
            // completed and re-invoked the model) — the turn is live
            // again. Never after Stop: a dying child's last events
            // must not resurrect a turn the user ended.
            if !status.isRunning, !stopRequested,
               let p = process, p.isRunning {
                if case .result = event.kind {} else { reopenTurnSegment() }
            }
            events.append(event)
            if let ctx = event.contextTokens, ctx > 0 {
                lastContextTokens = ctx
            }
            if let state = event.fastModeState {
                // The reason rides the same two events as the state, so
                // an event that states one and not the other clears it.
                updateFastModeReport {
                    $0.state = state
                    $0.disabledReason = event.fastModeDisabledReason
                        .flatMap { $0.isEmpty ? nil : $0 }
                }
            }
            if let speed = event.callSpeed {
                updateFastModeReport { $0.lastSpeed = speed }
            }
            if let windows = event.modelContextWindows, !windows.isEmpty,
               windows != observedContextWindows {
                observedContextWindows = windows
            }
            if case .systemInit(_, let model, _) = event.kind,
               !model.isEmpty, model != "<synthetic>",
               agentKey == "claude_code" {
                // Claude only: what this feeds is claude's ALIAS→id
                // map, and a codex slug or a kimi one is not an alias
                // resolving to anything. Codex reports no model here
                // today and kimi emits no system.init at all, so the
                // guard costs nothing now and is what stops the day
                // either starts reporting one from filing another
                // agent's vocabulary in that map.
                resolvedModel = ResolvedModel(alias: launchedModelAlias,
                                              fullId: model)
            }
            if case .result = event.kind {
                // This segment is over. Read the Sipping… clock (one
                // subtraction, no transcript scanning) and end the
                // visible turn — the process is not touched.
                stampTurnDuration()
                // Codex and kimi: neither stream carries per-call
                // usage, so the context chip is refreshed from the store
                // file instead. No-op for claude, whose events carry it
                // themselves.
                refreshCodexContextTokens()
                refreshKimiContextTokens()
                endTurnSegment()
                // The turn's record is on disk by its answer, so a Chat
                // only turn is filed now as well as at finalize: a send
                // that supersedes a child still winding down moves the
                // run token first, and THIS turn's finalize then no-ops.
                recordChatOnlyTurnIfNeeded()
            }
            applySubprocessSideEffects(for: event)
        }
        // Mid-turn: codex has just written another `token_count` to its
        // rollout and kimi another `usage.record` to its wire, one per
        // API call in both cases. Throttled, and a no-op for claude,
        // whose chip rides its own event stream. Without the kimi call
        // its chip would sit frozen for the whole run and only land at
        // finalize, where the other two move per call.
        if !parsed.isEmpty {
            refreshCodexContextTokens(throttled: true)
            refreshKimiContextTokens(throttled: true)
            // A kimi step has just landed on stdout, and the thought
            // that led to it is on the wire by now.
            syncKimiThoughts()
        }
        trimLiveEventsIfNeeded()
    }

    /// Non-parsing side effects that only apply to OUR subprocess's
    /// stdout stream: session-id discovery, tailer bootstrap, and
    /// MCP-alias registration. The tailer (reading from the JSONL file)
    /// deliberately skips these — external Claude Code writes its own
    /// system.init blocks but they don't tell us anything new.
    private func applySubprocessSideEffects(for event: StreamEvent) {
        guard case let .systemInit(sid, _, _) = event.kind, !sid.isEmpty else {
            return
        }
        // First-time discovery: locate the JSONL file, notify the
        // manager (so it can migrate the draft runner's key), and start
        // the tailer in suspended state — our subprocess is currently
        // the active writer; the tailer takes over after runOnce ends.
        if sessionId == nil {
            let fileURL = locateSessionFile(id: sid)
            sessionId = sid
            sessionFileURL = fileURL
            onSessionIdDiscovered?(sid, fileURL)
            if let url = fileURL {
                let size = Self.currentSize(of: url)
                startTailer(at: url, initialOffset: size)
                // Subprocess is still streaming — the tailer was just
                // created and is running, so we immediately suspend it.
                // runOnce's finalizer will resume it at the new EOF.
                tailer?.suspend()
            } else {
                // `system.init` announces the id BEFORE the transcript
                // exists — measured, repeatedly, on a plain first send.
                // A one-shot existence check therefore comes back nil
                // most of the time, and everything keyed on the file
                // silently does nothing for the whole session: no
                // tailer, no token read for codex/kimi (whose chips have
                // no other source), and no draft→existing flip in the
                // session view, which needs a path to route to.
                awaitSessionFile(id: sid)
            }
        }
        // Register alias so 4b's cache can promote any task_uuid-scoped
        // approvals to the real session_id scope.
        if let tu = taskUuid {
            bridge?.registerAlias(taskUuid: tu, sessionId: sid)
        }
    }

    // MARK: Kimi Chat only — the policy file and the server path

    /// The agent's name as Settings → Labels spells it, for the
    /// sentences this runner writes into the transcript. Provided by
    /// `AgentManager` (which holds the config); the registry's default
    /// name is the fallback for a runner nobody wired.
    var agentLabelProvider: (() -> String)?

    private var agentDisplayName: String {
        agentLabelProvider?()
            ?? AgentManager.registry.first { $0.key == agentKey }?.name
            ?? agentKey
    }

    /// Capture, journal and write the session's `tool-policy/state.json`
    /// for the turn about to run. False = refused, with the reason
    /// already on the transcript.
    private func prepareKimiToolPolicy(sessionId id: String) async -> Bool {
        guard let dir = KimiSessionScanner.sessionDirectory(forId: id) else {
            events.append(StreamEvent(kind: .error(message:
                String(localized: "Chat only can't be applied to this session — its folder in \(agentDisplayName)'s store could not be found.",
                       comment: "Runner error: a kimi session directory is missing for a Chat only turn; placeholder is the agent label"))))
            return false
        }
        let file = KimiToolPolicy.disabledFile(sessionDir: dir)
        let wire = KimiSessionScanner.wireFile(inSessionDir: dir)
        let root = KimiSessionScanner.sessionRoot
        // Reads and a store walk, bounded but not for the MainActor.
        let plan = await Task.detached(priority: .utility) {
            () -> (capture: KimiToolPolicy.Capture, names: [String]) in
            let capture = KimiToolPolicy.capture(at: file)
            let own = KimiToolPolicy.names(fromWire: wire)
            let store = own == nil ? KimiToolPolicy.newestNames(inStore: root) : nil
            return (capture, KimiToolPolicy.namesToDisable(sessionSnapshot: own,
                                                          storeSnapshot: store))
        }.value
        switch plan.capture {
        case .unknownShape:
            events.append(StreamEvent(kind: .error(message:
                String(localized: "Chat only can't be applied to this session — \(agentDisplayName)'s tool-policy file has a shape SipAI doesn't know.",
                       comment: "Runner error: a kimi session's tool-policy/state.json is not the measured shape; placeholder is the agent label"))))
            return false
        case .record(let record):
            // Journal BEFORE the write, so a crash between the two
            // still knows what to put back.
            onKimiToolPolicyJournal?(id, record)
            do {
                try KimiToolPolicy.write(names: plan.names, to: file)
            } catch {
                onKimiToolPolicyJournal?(id, nil)
                events.append(StreamEvent(kind: .error(message:
                    String(localized: "Chat only could not be prepared: \(error.localizedDescription)",
                           comment: "Runner error when the Chat only persona file cannot be written; placeholder is the system's error text"))))
                return false
            }
            pendingKimiRestore = (id, file, record)
            return true
        }
    }

    /// Put the session's policy file back and clear the journal. A
    /// restore that fails keeps its journal entry, which is what the
    /// launch and session-open heals act on.
    private func restoreKimiToolPolicyIfPending() {
        guard let pending = pendingKimiRestore else { return }
        pendingKimiRestore = nil
        do {
            try KimiToolPolicy.restore(pending.record, at: pending.file)
            onKimiToolPolicyJournal?(pending.sessionId, nil)
        } catch {
            NSLog("%@", "SipAI: could not restore \(pending.file.path): "
                  + "\(error.localizedDescription) — the journal keeps it for the next launch.")
        }
    }

    /// A new kimi session's first Chat only turn, through kimi's local
    /// server (`KimiWebTurn`). No stdout to stream: the answer is read
    /// off the wire whole once the session reports idle, so the static
    /// "Sipping…" spinner holds until then.
    private func runKimiWebTurn(text: String, options: AgentLaunchOptions,
                                images: [AgentImage] = [], binary: String) async {
        let token = runToken
        kimiWebTurnToken = token
        defer { if kimiWebTurnToken == token { kimiWebTurnToken = nil } }
        func fail(_ message: String) {
            guard token == runToken else { return }
            finalizeTurn(token: token, exitCode: -1, errorMessage: message)
        }
        /// Stop landed (the task is cancelled): the interrupted row is on
        /// the transcript already (`cancel()` wrote it), so the turn ends
        /// quietly here. True when the caller should return.
        func stopped() -> Bool {
            guard token == runToken else { return true }
            guard Task.isCancelled else { return false }
            finalizeTurn(token: token, exitCode: 0, errorMessage: nil)
            return true
        }
        // The first prompt binds the model, so it has to name one: the
        // chip's pick, else kimi's own `default_model`.
        KimiCatalog.shared.ensureLoaded()
        guard let model = (options.model?.isEmpty == false ? options.model
                           : KimiCatalog.shared.defaultModel) else {
            fail(String(localized: "\(agentDisplayName) has no model configured, so a new session cannot start.",
                        comment: "Runner error: kimi's config.toml names no default_model; placeholder is the agent label"))
            return
        }
        let root = KimiSessionScanner.sessionRoot
        let disabled = await Task.detached(priority: .utility) {
            KimiToolPolicy.namesToDisable(sessionSnapshot: nil,
                                          storeSnapshot: KimiToolPolicy.newestNames(inStore: root))
        }.value
        if stopped() { return }

        let session: KimiWebServerCall.Session
        switch await KimiWebServerCall.Session.start(binary: binary, scratchDirectory: cwd) {
        case .failed(let why):
            fail(String(localized: "\(agentDisplayName)'s local server did not start: \(why)",
                        comment: "Runner error when kimi web could not be started for a Chat only turn; placeholders are the agent label and the reason"))
            return
        case .started(let started):
            session = started
        }
        if token != runToken || Task.isCancelled {
            await session.shutdown()
            _ = stopped()
            return
        }

        let sid: String
        switch await KimiWebTurn.createSession(session, cwd: cwd) {
        case .failure(let failure):
            await session.shutdown()
            fail(Self.kimiWebFailureText(failure, agent: agentDisplayName))
            return
        case .success(let id):
            sid = id
        }
        if token != runToken || Task.isCancelled {
            await session.shutdown()
            _ = stopped()
            return
        }
        // The id is known at once — announce it the way a `system.init`
        // would, and let the file watcher re-announce with the wire once
        // the prompt has written it (`awaitSessionFile`).
        adoptDiscoveredSession(id: sid, fileURL: nil)
        awaitSessionFile(id: sid)
        // The server writes the policy file for this prompt; what was
        // there before is nothing, and that is what goes back — through
        // the same first-caller-wins slot the `--prompt` path uses, so
        // the bounded finalize a Stop arms (`cancel()`) restores it too
        // when the server stops answering.
        let policyFile = KimiSessionScanner.sessionDirectory(forId: sid)
            .map { KimiToolPolicy.disabledFile(sessionDir: $0) }
        onKimiToolPolicyJournal?(sid, .absent)
        if let policyFile {
            pendingKimiRestore = (sid, policyFile, .absent)
        }
        func restore() {
            if policyFile != nil {
                // Only while this turn still owns the slot. A Stop's
                // bounded finalize may have ended the turn already —
                // restoring its record then — and the next turn may
                // have put its own record here since: restoring THAT
                // would take its policy file away while it runs.
                guard token == runToken else { return }
                restoreKimiToolPolicyIfPending()
            } else {
                // No directory to look in: nothing was written, so the
                // journal entry has nothing to restore.
                onKimiToolPolicyJournal?(sid, nil)
            }
        }

        let promptId: String
        switch await KimiWebTurn.prompt(session, sessionId: sid, text: text,
                                        model: model, disabledTools: disabled,
                                        images: images) {
        case .failure(let failure):
            await session.shutdown()
            restore()
            fail(Self.kimiWebFailureText(failure, agent: agentDisplayName))
            return
        case .success(let id):
            promptId = id
        }

        let idle = await KimiWebTurn.waitIdle(session, sessionId: sid) { Task.isCancelled }
        if idle {
            await session.shutdown()
        } else {
            // Stop (the task was cancelled) or the server stopped
            // answering: the action route, then the shutdown that
            // certainly ends it.
            await KimiWebTurn.abort(session, sessionId: sid, promptId: promptId)
        }
        restore()
        guard token == runToken else { return }
        if idle, let wire = sessionFileURL ?? KimiSessionScanner.sessionDirectory(forId: sid)
            .map({ KimiSessionScanner.wireFile(inSessionDir: $0) }) {
            // The answer, off the wire: the turn's rows after our own
            // prompt.
            // Thoughts included: this path only ever runs a Chat only
            // turn, and the wire is the only place kimi records them.
            let items = await Task.detached(priority: .utility) {
                KimiSessionScanner.readHistory(of: wire, maxTurns: 1,
                                               includeThinking: true)
            }.value
            guard token == runToken else { return }
            var sawPrompt = false
            for item in items {
                switch item.kind {
                case .userText where !sawPrompt:
                    sawPrompt = true
                case .userText(let t):
                    events.append(StreamEvent(kind: .userMessage(text: t),
                                              isSystemNotice: item.isSystemNotice))
                case .assistantText(let t):
                    events.append(StreamEvent(kind: .assistantText(text: t)))
                case .thinking(let t):
                    events.append(StreamEvent(kind: .thinking(text: t)))
                    // Placed already, in order — the finalize read
                    // (`syncKimiThoughts`) must not place it again.
                    kimiThoughtsPlaced += 1
                case .toolUse(let id, let name, let input):
                    events.append(StreamEvent(kind: .toolUse(toolUseId: id, name: name, input: input)))
                case .toolResult(let id, let content, let isError):
                    events.append(StreamEvent(kind: .toolResult(toolUseId: id, output: content, isError: isError)))
                case .compaction, .interrupted:
                    // Neither is a row this runner writes: a compaction
                    // row comes off the parsers on the live feeds and
                    // off the reader on reopen (a first prompt cannot
                    // compact anyway), and the interrupted marker is
                    // derived at load time.
                    break
                }
            }
            trimLiveEventsIfNeeded()
        }
        if idle {
            finalizeTurn(token: token, exitCode: 0, errorMessage: nil)
        } else if Task.isCancelled {
            // Stopped: the prompt is aborted, the server is down and the
            // policy file is back — the turn `cancel()` held open for
            // exactly that ends now (its interrupted row is already on
            // the transcript).
            finalizeTurn(token: token, exitCode: 0, errorMessage: nil)
        } else {
            fail(String(localized: "\(agentDisplayName)'s local server stopped answering before the turn finished.",
                        comment: "Runner error when kimi web went silent during a Chat only turn; placeholder is the agent label"))
        }
    }

    private static func kimiWebFailureText(_ failure: KimiWebTurn.Failure,
                                           agent: String) -> String {
        switch failure {
        case .unavailable(let why):
            return String(localized: "\(agent)'s local server did not answer: \(why)",
                          comment: "Runner error when kimi web failed a Chat only request; placeholders are the agent label and the reason")
        case .refused(let why):
            return String(localized: "\(agent) refused the Chat only turn: \(why)",
                          comment: "Runner error when kimi web refused a Chat only prompt; placeholders are the agent label and kimi's own sentence")
        }
    }

    // MARK: Late transcript-file discovery

    /// How often the store is re-checked for a transcript whose id is
    /// already known, and for how long. The cap is a runaway guard, not
    /// an expectation — the file normally lands within a poll or two of
    /// `system.init`, and the turn's own end re-checks once more.
    private static let sessionFileRetryInterval: TimeInterval = 0.3
    private static let sessionFileRetryGrace: TimeInterval = 30
    private var sessionFileSearch: Task<Void, Never>? = nil

    /// Watch for the transcript of an already-announced session id to
    /// appear, and adopt it the moment it does.
    ///
    /// The id and the file do NOT arrive together: `system.init` is the
    /// first thing the child says, and the transcript is written a beat
    /// later. Everything downstream is keyed on the FILE, so a runner
    /// that never picks it up spends the whole session with no tailer,
    /// no token source for codex/kimi, and — because
    /// `AgentSessionView.handleSessionIdDiscovered` has no path to route
    /// to — a session view stuck in draft mode.
    private func awaitSessionFile(id: String) {
        guard sessionFileSearch == nil, !id.isEmpty else { return }
        let key = agentKey
        sessionFileSearch = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(Self.sessionFileRetryGrace)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.sessionFileRetryInterval * 1_000_000_000))
                guard let self, self.sessionFileURL == nil else { return }
                // Off-main: the claude spelling lists every project
                // directory and stats a candidate in each, and this runs
                // while a turn is streaming.
                let found = await Task.detached(priority: .utility) {
                    Self.locateSessionFile(id: id, agentKey: key)
                }.value
                // Re-check across the await — `runOnce`'s own backstop
                // can have landed the file while this was looking.
                guard self.sessionFileURL == nil else { return }
                guard let found else { continue }
                self.adoptSessionFile(found, id: id)
                return
            }
        }
    }

    /// Take up a transcript found after the fact, doing everything
    /// `applySubprocessSideEffects` would have done had the file existed
    /// when the id was announced.
    private func adoptSessionFile(_ url: URL, id: String) {
        guard sessionFileURL == nil else { return }
        sessionFileURL = url
        sessionFileSearch?.cancel()
        sessionFileSearch = nil
        startTailer(at: url, initialOffset: Self.currentSize(of: url))
        // Our own child is still the writer while the turn runs;
        // `runOnce`'s finalizer resumes the tailer at the new EOF.
        if status.isRunning { tailer?.suspend() }
        // Re-announce: the first call carried a nil URL, so any listener
        // that needs the path (the session view's draft→existing flip)
        // could not act on it. `AgentManager.migrateRunner` has already
        // done its half and no-ops on the repeat.
        onSessionIdDiscovered?(id, url)
        // The chips these two feed have no other source, and a turn that
        // started before the file existed has usage on record by now.
        refreshCodexContextTokens()
        refreshKimiContextTokens()
    }

    // MARK: Kimi session-id discovery

    /// How often the store is re-checked, and for how long in total.
    /// The cap is a runaway guard, not an expectation — a session
    /// directory that has not appeared two minutes after the child was
    /// spawned is not going to.
    private static let kimiDiscoveryInterval: UInt64 = 500_000_000  // 0.5 s
    private static let kimiDiscoveryMaxAttempts = 240               // ~120 s
    /// Attempts granted AFTER the turn ends. Kimi may only flush its
    /// session at the end of a print-mode run, so the poller must
    /// outlive the child rather than stopping with it.
    private static let kimiDiscoveryPostTurnAttempts = 6            // ~3 s

    /// Read a just-created kimi session's id back off the store.
    ///
    /// Claude and codex hand their session id to the runner on stdout
    /// (`system.init` / `thread.started`); that event is what migrates
    /// a draft runner onto its permanent key, injects the sidebar row,
    /// flips AppState's routing and — most consequentially — lets every
    /// later send pass `--session <id>` and CONTINUE the conversation.
    /// Kimi names its session only with the turn's final answer, so
    /// without this a draft would stay a draft for the whole of its
    /// first turn, and a turn that died before its last line would
    /// leave the next send starting a brand-new session.
    ///
    /// The lookup is deliberately narrow — an id absent from the
    /// pre-spawn snapshot, in a directory younger than the send, whose
    /// recorded cwd (when it has one) is ours, whose first message is
    /// the text this turn sent, and the ONLY one that is all four
    /// (`KimiSessionScanner.discoverSession`) — so a second kimi started
    /// in the same folder at the same moment is never adopted in its
    /// place.
    private func startKimiSessionDiscovery(excluding known: Set<String>,
                                           since: Date,
                                           prompt: String) {
        kimiDiscoveryTask?.cancel()
        let token = runToken
        let dir = cwd
        kimiDiscoveryTask = Task { [weak self] in
            var postTurn = 0
            for _ in 0..<Self.kimiDiscoveryMaxAttempts {
                if Task.isCancelled { return }
                guard let self, self.runToken == token,
                      self.sessionId == nil else { return }
                let found = await Task.detached(priority: .utility) {
                    KimiSessionScanner.discoverSession(
                        cwd: dir, excluding: known, since: since,
                        prompt: prompt)
                }.value
                if Task.isCancelled || self.runToken != token { return }
                if let found {
                    self.adoptDiscoveredSession(id: found.id,
                                                fileURL: found.fileURL)
                    return
                }
                // The turn ending is not the end of the search — but it
                // does bound it.
                if !self.status.isRunning {
                    postTurn += 1
                    if postTurn > Self.kimiDiscoveryPostTurnAttempts {
                        self.logKimiDiscoveryGaveUp("turn ended")
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: Self.kimiDiscoveryInterval)
            }
            self?.logKimiDiscoveryGaveUp("attempt cap")
        }
    }

    /// Giving up is the one outcome with a lasting consequence — the
    /// next send has no `--session` to pass, so it opens a SECOND
    /// conversation and the agent appears to have forgotten everything.
    /// If it ever happens, this log line is the whole diagnosis.
    private func logKimiDiscoveryGaveUp(_ why: String) {
        NSLog("%@", "SipAI: could not single out this turn's kimi session "
              + "under \(KimiSessionScanner.sessionRoot.path) for "
              + "\(cwd.path) (\(why)), and kimi did not name it — the next "
              + "send will start a new session.")
    }

    /// Adopt an id discovered off the store, taking the same route a
    /// `system.init` event takes through `applySubprocessSideEffects` —
    /// minus the tailer (which decodes claude JSONL) and the MCP alias
    /// (kimi runners hold no bridge).
    private func adoptDiscoveredSession(id: String, fileURL: URL?) {
        guard sessionId == nil, !id.isEmpty else { return }
        sessionId = id
        sessionFileURL = fileURL
        onSessionIdDiscovered?(id, fileURL)
    }

    // MARK: Stderr reader

    /// Accumulates into `stderrBuffer` — a plain property, not the
    /// published one — so a stall notice can read the tail of a child
    /// that has NOT exited. Buffering into a local assigned at EOF
    /// would mean an agent explaining itself on stderr while hanging
    /// says it to nobody: a hung child never reaches EOF.
    private func readStderr(handle: FileHandle) async {
        stderrBuffer = ""
        let fd = handle.fileDescriptor
        guard fd >= 0 else {
            publishStderrTail()
            return
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        // The same draining source as stdout, over the pipe's read
        // end. It ends at EOF and nowhere else — `killChild` guarantees
        // that EOF, and `finalizeTurn` never waits on a reader — so
        // there is no cancel path here, and there must not be one.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let source = Self.makeDrainingLineSource(
                fd: fd,
                label: "sipai.runner.stderr.\(UUID().uuidString)",
                owner: self,
                onLine: { [weak self] line in
                    Task { @MainActor [weak self] in
                        self?.appendStderrLine(line)
                    }
                },
                onEnd: { [weak self] leftover in
                    // A fatal message is routinely the last thing a
                    // child writes, and routinely without a newline.
                    // It is the line the error row exists to show.
                    // The continuation is resumed from INSIDE the hop
                    // that appends it, so `publishStderrTail()` below
                    // cannot run before the tail is in the buffer —
                    // ordering by construction, not by relying on two
                    // separately enqueued MainActor jobs staying FIFO.
                    let tail = leftover.isEmpty
                        ? nil : String(data: leftover, encoding: .utf8)
                    Task { @MainActor [weak self] in
                        if let tail { self?.appendStderrLine(tail) }
                        cont.resume()
                    }
                }
            )
            source.resume()
        }
        publishStderrTail()
    }

    /// One stderr line (as the drain split it, on `\n`) into the plain
    /// buffer. The line iterator this replaced also broke lines on a
    /// bare CR, NEL, LS and PS and swallowed the CR of a CRLF; a
    /// progress bar redrawing itself with `\r` therefore arrived as
    /// separate lines, and keeps doing so. Capped at ~2kB so a child
    /// that narrates forever cannot grow it without bound.
    private func appendStderrLine(_ rawLine: String) {
        var line = Substring(rawLine)
        if line.hasSuffix("\r") { line.removeLast() }
        let separators: Set<Character> = ["\r", "\u{85}", "\u{2028}", "\u{2029}"]
        for piece in line.split(omittingEmptySubsequences: false,
                                whereSeparator: { separators.contains($0) }) {
            if !stderrBuffer.isEmpty { stderrBuffer += "\n" }
            stderrBuffer += piece
        }
        if stderrBuffer.count > 2048 {
            stderrBuffer = String(stderrBuffer.suffix(2048))
        }
    }

    // MARK: Wait-for-exit

    private func waitForExit(process p: Process, waiter: ExitWaiter) async {
        await withTaskCancellationHandler {
            await waiter.wait()
        } onCancel: {
            // Escalate, don't just ask — and never resume the waiter
            // early. `runOnce` reads `p.terminationStatus` the moment
            // the group joins, and Foundation raises if that is read on
            // a process that is still alive; the continuation must stay
            // parked until the child is genuinely gone. Making sure it
            // GOES is `killChild`'s job.
            if p.isRunning { p.terminate() }
        }
    }

    /// Bridges Process.terminationHandler (installed BEFORE run(), see
    /// runOnce) to an awaitable. Handles both orders: exit-before-wait
    /// resumes immediately, wait-before-exit parks the continuation.
    private final class ExitWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var exited = false
        private var cont: CheckedContinuation<Void, Never>?

        func markExited() {
            lock.lock()
            exited = true
            let c = cont
            cont = nil
            lock.unlock()
            c?.resume()
        }

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if exited {
                    lock.unlock()
                    c.resume()
                    return
                }
                cont = c
                lock.unlock()
            }
        }
    }

    // MARK: Status

    private func setStatus(_ new: RunStatus) {
        status = new
        onStatusChange?(key, new)
    }

    // MARK: - Helpers

    /// Build a PATH-rich environment mirroring AgentManager's detection
    /// logic so helper tools (node, npm, git) are findable from the GUI.
    ///
    /// Not private, because `AgentCLIProbe` spawns the same CLIs to ask
    /// their version and to run their own updaters, and those children
    /// need exactly this environment for exactly the reasons below.
    /// A second spelling of it there is the drift this app has already
    /// paid for once — see the search-path list.
    nonisolated static func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // The SAME directories detection looks in — one list, not a
        // hand-copied second spelling that can drift — so an agent we
        // were willing to launch can always find its own siblings
        // (kimi, for one, ships its helper binaries beside itself in
        // ~/.kimi-code/bin). Folding in the login shell's PATH (which
        // `searchPaths` does) is also what gives the child the
        // toolchain a terminal user takes for granted — same gap as
        // the proxy variables below, and by this point on the spawn
        // path `ShellEnvironment.prepare()` has already been awaited,
        // so the capture is in hand rather than empty.
        stripDynamicLinkerVars(from: &env)
        var dirs = AgentManager.searchPaths
        dirs.append(contentsOf: ["/usr/sbin", "/sbin"])
        let existing = env["PATH"] ?? ""
        let merged = dirs.joined(separator: ":") + (existing.isEmpty ? "" : ":" + existing)
        env["PATH"] = merged
        overlayProxyVars(into: &env)
        return env
    }

    /// Drop every `DYLD_*` variable before handing the environment to an
    /// agent CLI.
    ///
    /// Symptom this exists for: an agent turn produces no output and no
    /// session, and the transcript shows a NATIVE crash — for kimi,
    /// `Assertion failed: (magic) == (kMagic)` inside
    /// `node::sea::FindSingleExecutableResource`.
    ///
    /// `buildEnvironment` starts from `ProcessInfo.processInfo.
    /// environment`, and a debug build launched by Xcode carries
    /// `DYLD_INSERT_LIBRARIES=…/libMainThreadChecker.dylib` plus
    /// `DYLD_FRAMEWORK_PATH` / `DYLD_LIBRARY_PATH` pointing into
    /// DerivedData. Children inherit all of it. Kimi ships as a Node
    /// SEA — a single executable with its JavaScript stored in a Mach-O
    /// section — and an inserted dylib perturbs the image the SEA
    /// loader reads that section back out of, so the blob fails its
    /// magic-number check and node aborts before running a line of
    /// kimi. Claude and codex survive the same environment only by
    /// construction: claude is a plain script behind a `node` shim and
    /// codex is a Rust binary, neither of which reads itself.
    ///
    /// The rule is general, not a kimi workaround, which is why it
    /// strips the whole family rather than the one name that was
    /// caught: every `DYLD_*` variable is an instruction about how to
    /// assemble THIS process's image graph — SipAI's frameworks, its
    /// debug dylib, its instrumentation. None of it describes an
    /// unrelated CLI, and forwarding it can only ever range from
    /// pointless to fatal. It also covers the non-Xcode cases nobody
    /// would think to test: a `DYLD_INSERT_LIBRARIES` exported in the
    /// user's own shell (which `ShellEnvironment` would otherwise carry
    /// in), or injected by security software.
    ///
    /// `__XPC_DYLD_*` goes too: launchd forwards the same values under
    /// that prefix, and dyld reads them back.
    ///
    /// Deliberately NOT extended to the rest of Xcode's injections
    /// (`NSUnbufferedIO`, `OS_ACTIVITY_DT_MODE`, `MallocNanoZone`).
    /// Those are inert in a child, and a blanket "scrub anything that
    /// looks like Xcode" would be guesswork where this is a
    /// reproduction.
    nonisolated private static func stripDynamicLinkerVars(from env: inout [String: String]) {
        for key in env.keys
        where key.hasPrefix("DYLD_") || key.hasPrefix("__XPC_DYLD_") {
            env.removeValue(forKey: key)
        }
    }

    /// Forward the proxy variables a terminal user takes for granted
    /// and a GUI app does not have.
    ///
    /// Same gap `ShellEnvironment` already exists to close for API
    /// keys: launched from the Dock, Finder or Xcode we inherit
    /// LAUNCHD's environment, never the exports in ~/.zshrc. What makes
    /// it worse here than for a key is that there is no error to read.
    ///
    /// Every agent CLI we spawn reads these variables and NOTHING else
    /// — codex is Rust/reqwest, claude and kimi are Node, and none of
    /// them consults the macOS System Configuration proxy. So on a
    /// machine whose system proxy is SOCKS-only, CFNetwork applies it
    /// transparently to our OWN URLSession traffic (the app's chat
    /// works, the model list loads, everything looks connected) while
    /// every agent turn is left with no route to the network at all —
    /// and a blocked agent does not fail, it silently retries forever.
    ///
    /// Both spellings travel because the convention is split — curl and
    /// Node prefer lowercase, reqwest reads either — and a proxy set in
    /// only one case is a proxy half the toolchain ignores. Only names
    /// MISSING from the process environment are filled in, so a value
    /// from launchd or an Xcode scheme still wins; this is a fallback,
    /// not an override.
    ///
    /// Do NOT let this call `ShellEnvironment.resolve` on an uncaptured
    /// snapshot from the MainActor — `runOnce` awaits
    /// `ShellEnvironment.prepare()` first for that reason.
    nonisolated private static func overlayProxyVars(into env: inout [String: String]) {
        for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                     "http_proxy", "https_proxy", "all_proxy", "no_proxy"] {
            guard env[name]?.isEmpty ?? true,
                  let value = ShellEnvironment.resolve(name) else { continue }
            env[name] = value
        }
    }

    /// How the child's stdout is wired up. Prefers a PTY so Node's
    /// stdio flushes per line; falls back to a plain pipe if openpty()
    /// fails (extremely rare on macOS).
    struct ChildStdoutSource {
        /// FileHandle handed to Process.standardOutput. For the PTY
        /// path this is the slave side; for the pipe fallback, the
        /// write end.
        let handleForChild: FileHandle
        /// FileHandle the parent reads from. Master side of the PTY,
        /// or the pipe's read end.
        let readHandle: FileHandle
        /// PTY slave fd the parent keeps a reference to so it can
        /// close it post-spawn. `-1` for the pipe fallback.
        let slaveFDToClose: Int32

        /// True for the Pipe() fallback: NSTask does not close a
        /// caller-supplied FileHandle in the parent, so the parent's
        /// write end must be closed post-spawn or the reader never
        /// sees EOF and the turn hangs at exit. Closed via the
        /// HANDLE (not the raw fd) so its dealloc can't double-close
        /// a recycled descriptor.
        let childHandleNeedsClose: Bool

        /// Called after Process.run() succeeds: drop the parent's copy
        /// of the child-side endpoint (PTY slave fd, or the pipe's
        /// write end) so the read side receives EOF at child exit.
        func afterSpawn() {
            if slaveFDToClose >= 0 {
                close(slaveFDToClose)
            }
            if childHandleNeedsClose {
                try? handleForChild.close()
            }
        }

        /// Called when the process fails to spawn — tear down any fds
        /// we acquired so we don't leak on the error path.
        func cleanup() {
            if slaveFDToClose >= 0 {
                close(slaveFDToClose)
            }
            if childHandleNeedsClose {
                try? handleForChild.close()
            }
            try? readHandle.close()
        }
    }

    /// Try openpty() first; fall back to Pipe() if that fails.
    /// Internal for the same reason as `makeDrainingLineSource`.
    nonisolated static func makeChildStdoutSource() -> ChildStdoutSource {
        var masterFD: Int32 = 0
        var slaveFD: Int32 = 0
        if openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 {
            let master = FileHandle(fileDescriptor: masterFD,
                                    closeOnDealloc: true)
            let slave = FileHandle(fileDescriptor: slaveFD,
                                   closeOnDealloc: false)
            return ChildStdoutSource(
                handleForChild: slave,
                readHandle: master,
                slaveFDToClose: slaveFD,
                childHandleNeedsClose: false
            )
        }
        let pipe = Pipe()
        return ChildStdoutSource(
            handleForChild: pipe.fileHandleForWriting,
            readHandle: pipe.fileHandleForReading,
            slaveFDToClose: -1,
            childHandleNeedsClose: true
        )
    }

    /// Current size in bytes of a file, or 0 if it can't be stat'd.
    /// Used to seed tailer offsets at "EOF-equivalent".
    fileprivate static func currentSize(of url: URL) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ), let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }

    /// Create + start the external-activity tailer for this session.
    /// No-op if one is already running. The callbacks bounce back to
    /// the MainActor (the runner's events array and
    /// `externalInProgress` flag both live there).
    private func startTailer(at url: URL, initialOffset: UInt64) {
        guard tailer == nil else { return }
        // Each CLI's transcript is its own schema, and each leaves its
        // own sign of a live writer — the tailer is told which
        // (`AgentSessionTailer.Format`). Our OWN turns stream over stdout
        // whatever the agent; this is for the turn another process runs
        // on the session: a terminal, another app, a turn this app
        // orphaned by relaunching.
        let format: AgentSessionTailer.Format
        switch agentKey {
        case "codex":
            // The writer lock is named for the thread; the session id IS
            // the thread id, and so is the rollout file name's tail.
            let threadId = sessionId.flatMap { $0.isEmpty ? nil : $0 }
                ?? Self.rolloutThreadId(url)
            format = .codex(threadId: threadId,
                            sessionRoot: CodexSessionScanner.sessionRoot)
        case "kimi":
            // The folder a live kimi process reports is a real path, as
            // is the one kimi records for the session.
            format = .kimi(workDir: KimiWebTurn.resolvedPath(cwd))
        default:
            format = .claude
        }
        let t = AgentSessionTailer(
            fileURL: url,
            fallbackCwd: cwd,
            format: format,
            onEvents: { [weak self] batch in
                self?.appendTailedEvents(batch)
            },
            onExternalInProgressChange: { [weak self] newValue in
                guard let self = self else { return }
                self.externalInProgress = newValue
                self.handleExternalProgressFlip(newValue)
                if let sid = self.sessionId, !sid.isEmpty {
                    self.onExternalInProgressChange?(sid, newValue)
                }
            }
        )
        t.start(initialOffset: initialOffset)
        tailer = t
    }

    /// The thread id a codex rollout is named for: `rollout-<stamp>-<id>
    /// .jsonl`, the id being the last 36 characters. Empty when the name
    /// is not that shape — the lock test then answers "no writer", and the
    /// turn is left to the staleness guard.
    nonisolated static func rolloutThreadId(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count >= 36 else { return "" }
        let id = String(name.suffix(36))
        return UUID(uuidString: id) != nil ? id.lowercased() : ""
    }

    /// Live-buffer cap. An external watch can stream for hours; without
    /// a cap the buffer — and the cost of every append-triggered
    /// re-render — grows without bound, enough to freeze the app while
    /// a big external session streams in the background. Reloads
    /// re-cover anything trimmed from disk; the +200 hysteresis keeps
    /// the trim amortized instead of per-append.
    private static let liveEventCap = 800

    /// Append one tailed read-burst as a single `events` mutation
    /// (one SwiftUI re-render per burst, not per line).
    private func appendTailedEvents(_ batch: [StreamEvent]) {
        guard !batch.isEmpty else { return }
        events.append(contentsOf: batch)
        // External turns update the live token counter too — the
        // newest usage in the burst wins. (The view's turn-end rescan
        // stays as the safety net for bursts the cap trimmed.)
        for event in batch.reversed() {
            if let ctx = event.contextTokens, ctx > 0 {
                lastContextTokens = ctx
                break
            }
        }
        // The speed the newest call ran at, whoever sent the turn — the
        // chip states it only while this session's own switch asks for
        // fast mode.
        if let speed = batch.last(where: { $0.callSpeed != nil })?.callSpeed {
            updateFastModeReport { $0.lastSpeed = speed }
        }
        // Codex and kimi carry no usage on the rows themselves; their
        // stores record it per call, and the same throttled reads our
        // own turns use keep the chip moving through one another process
        // runs.
        refreshCodexContextTokens(throttled: true)
        refreshKimiContextTokens(throttled: true)
        trimLiveEventsIfNeeded()
    }

    private func trimLiveEventsIfNeeded() {
        if events.count > Self.liveEventCap + 200 {
            let cut = events.count - Self.liveEventCap
            // The newest turn opened inside the cut is the one the buffer
            // now opens in. None there: it still opens inside the turn it
            // opened in before, and the flag already says what that was.
            if let opener = events[..<cut].last(where: Self.opensTurn) {
                trimmedHeadChatOnly = opener.chatOnlyTurn
            }
            events.removeFirst(cut)
        }
    }

    /// A message the user sent — the event a turn opens with. A notice
    /// in the user column opens none.
    private static func opensTurn(_ event: StreamEvent) -> Bool {
        if case .userMessage = event.kind { return !event.isSystemNotice }
        return false
    }

    /// The transcript file a newly-discovered session id belongs to.
    ///
    /// `nonisolated` because the retry below runs it off the main actor:
    /// the claude spelling lists every project directory and stats a
    /// candidate in each, which is not something to repeat on the
    /// MainActor while a turn is streaming. It reads two `let`s and the
    /// file system, nothing else.
    nonisolated static func locateSessionFile(id: String,
                                              agentKey: String) -> URL? {
        switch agentKey {
        case "codex": return CodexSessionScanner.rolloutFile(namedForId: id)
        case "kimi":  return locateKimiWireFile(id: id)
        default:      return locateSessionFile(id: id)
        }
    }

    private func locateSessionFile(id: String) -> URL? {
        Self.locateSessionFile(id: id, agentKey: agentKey)
    }

    /// `sessions/*/<id>/agents/main/wire.jsonl`. The session id IS the
    /// directory name, so this is a two-level directory listing rather
    /// than a content search — no file is opened.
    nonisolated private static func locateKimiWireFile(id: String) -> URL? {
        guard !id.isEmpty, KimiSessionScanner.storeExists,
              let buckets = try? FileManager.default.contentsOfDirectory(
                at: KimiSessionScanner.sessionRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else { return nil }
        for bucket in buckets {
            let dir = bucket.appendingPathComponent(id, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.path,
                                              isDirectory: &isDir),
               isDir.boolValue {
                return KimiSessionScanner.wireFile(inSessionDir: dir)
            }
        }
        return nil
    }

    /// Glob `~/.claude/projects/*/<id>.jsonl` for the JSONL file that
    /// matches a newly-discovered session id.
    nonisolated private static func locateSessionFile(id: String) -> URL? {
        let root = AgentSessionScanner.sessionRoot
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for dir in projectDirs {
            let candidate = dir.appendingPathComponent("\(id).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
