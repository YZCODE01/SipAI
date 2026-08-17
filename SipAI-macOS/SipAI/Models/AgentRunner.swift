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

    init(kind: StreamEventKind, contextTokens: Int? = nil,
         isSystemNotice: Bool = false) {
        self.id = UUID()
        self.timestamp = Date()
        self.kind = kind
        self.contextTokens = contextTokens
        self.isSystemNotice = isSystemNotice
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

    /// Full model id from the newest system.init event of OUR
    /// subprocess ("claude-opus-5"). Feeds the composer's model chip
    /// the resolved model the moment a send starts — the JSONL doesn't
    /// carry it until the first assistant record lands, and an alias
    /// like "opus" says nothing about the version that actually ran.
    /// Same delivery pattern as `lastContextTokens` for the same
    /// ordering reasons.
    @Published private(set) var lastModelId: String? = nil

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
           now.timeIntervalSince(lastCodexTokenRead) < Self.codexTokenReadInterval {
            return
        }
        lastCodexTokenRead = now
        Task.detached(priority: .utility) { [weak self] in
            let total = CodexSessionScanner.lastContextTokens(of: url)
            guard total > 0 else { return }
            await MainActor.run { [weak self] in
                guard let self, total != self.lastContextTokens else { return }
                self.lastContextTokens = total
            }
        }
    }

    /// Floor on how often a streaming turn may re-read the rollout.
    /// The read is a bounded tail, but a busy turn emits items faster
    /// than the chip can meaningfully change.
    private static let codexTokenReadInterval: TimeInterval = 1
    private var lastCodexTokenRead: Date = .distantPast

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
    private func refreshKimiContextTokens() {
        guard agentKey == "kimi", let url = sessionFileURL else { return }
        Task.detached(priority: .utility) { [weak self] in
            let total = KimiSessionScanner.lastContextTokens(of: url)
            guard total > 0 else { return }
            await MainActor.run { [weak self] in
                guard let self, total != self.lastContextTokens else { return }
                self.lastContextTokens = total
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
    /// stand-in for the `system.init` / `thread.started` event kimi's
    /// stdout doesn't have. See `startKimiSessionDiscovery`.
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
    func send(text: String, options: AgentLaunchOptions = AgentLaunchOptions()) -> Bool {
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

        events.append(StreamEvent(kind: .userMessage(text: trimmed)))
        inFlightUserText = trimmed
        stderrTail = ""
        stderrBuffer = ""
        retryNotice = ""
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
            await self.runOnce(text: trimmed, options: options)
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
    /// The claude pid ONLY, deliberately. No descendant of `claude`
    /// inherits our descriptors — tool subprocesses get /dev/null plus
    /// a temp file, MCP stdio servers get socketpairs — so the only
    /// holder of our PTY slave is claude itself, and killing claude
    /// alone is enough for both readers to reach EOF. Signalling the
    /// process GROUP would be actively wrong: Foundation gives us no
    /// way to put the child in a group of its own, so its group is
    /// OURS, and `kill(-pgid)` would take down SipAI with it.
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
    /// so. Generous on purpose: a cold agent start behind a slow link
    /// can legitimately take tens of seconds to first token, and this
    /// row is worth nothing if it cries wolf.
    private static let firstOutputGrace: TimeInterval = 60

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
        // Backstop for the codex and kimi token chips, after the
        // late-discovery block above has had its chance to name the
        // store file. A turn that was stopped or that died never
        // emitted the `result` that normally carries this — same
        // reasoning as `stampTurnDuration`. For kimi this is also the
        // FIRST chance on a draft's opening turn, whose session id
        // only arrives with the last stdout line.
        refreshCodexContextTokens()
        refreshKimiContextTokens()
        return true
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
        guard let url = sessionFileURL else { return }
        let sid = sessionId
        Task.detached(priority: .utility) { [weak self] in
            let start = AgentSessionScanner.lastTurnStartDate(of: url)
            let stoppable = sid.flatMap {
                ClaudeSessionStatusStore.stoppableExternalPid(sessionId: $0)
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
    func noteTranscriptContextTokens(_ total: Int) {
        guard total > 0, !status.isRunning else { return }
        lastContextTokens = total
    }

    /// Drop the live event buffer. The session view calls this after a
    /// completed history reload: the JSONL on disk is the superset of
    /// every FINISHED turn, so keeping the buffer would render those
    /// turns twice (history copy above, live copy below). Refused
    /// mid-turn — the current turn's events aren't fully on disk yet.
    func clearEvents() {
        guard !status.isRunning else { return }
        events.removeAll()
    }

    // MARK: - Argument construction

    private func claudeArguments(text: String,
                                 options: AgentLaunchOptions) -> [String] {
        var args: [String] = [
            "-p", text,
            "--output-format", "stream-json",
            "--verbose",
        ]
        args.append(contentsOf: options.flags(for: agentKey))
        if let id = sessionId, !id.isEmpty {
            args.append("--resume")
            args.append(id)
        }
        if let bridge = bridge {
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
                                options: AgentLaunchOptions) -> [String] {
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
        args.append(contentsOf: options.flags(for: agentKey))
        if resuming, let id = sessionId { args.append(id) }
        args.append(text)
        return args
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

    private func runOnce(text: String, options: AgentLaunchOptions) async {
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

        let args: [String]
        switch agentKey {
        case "codex": args = codexArguments(text: text, options: options)
        case "kimi":  args = kimiArguments(text: text, options: options)
        default:      args = claudeArguments(text: text, options: options)
        }

        // Kimi announces no session id on stdout, so a draft's id is
        // read back off the store afterwards — and telling OUR new
        // session apart from the ones already there needs the "before"
        // list taken before the child can create anything. Cheap: two
        // levels of directory names, no file reads.
        let kimiKnownIds: Set<String> =
            (isKimi && (sessionId?.isEmpty ?? true))
            ? KimiSessionScanner.sessionIds() : []

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        p.currentDirectoryURL = cwd
        // `codex exec` reads its prompt from stdin when stdin is not a
        // terminal, and BLOCKS until EOF — a piped stdin hangs the
        // turn forever on "Reading additional input from stdin…". A
        // GUI app's inherited stdin is not something to gamble on, so
        // hand it an explicitly empty one. Harmless for claude, which
        // never reads stdin under `-p`.
        p.standardInput = FileHandle.nullDevice

        // Build PATH-rich env + overlay MCP-related vars. The await is
        // load-bearing: `buildEnvironment` reads the login shell's
        // captured environment for the proxy settings, and that read
        // BLOCKS while the capture is still in flight — which on the
        // MainActor would freeze the app. Normally a no-op; `warmUp()`
        // has run since launch.
        await ShellEnvironment.prepare()
        var env = Self.buildEnvironment()
        if let bridge = bridge {
            for (k, v) in bridge.environmentOverlay(sessionIdOrTaskUuid: sipaiIdentity) {
                env[k] = v
            }
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

        if isKimi, sessionId == nil {
            startKimiSessionDiscovery(excluding: kimiKnownIds, since: Date())
        }

        // Two concurrent readers: stdout (line-oriented JSON events)
        // and stderr (buffered as text, surfaced only on error).
        let token = runToken
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
    /// MainActor for parsing. Same shape as
    /// `AgentSessionTailer.handleExtend`.
    ///
    /// Why not `for try await line in handle.bytes.lines`: that iterator
    /// round-trips every line through this actor, so a busy main actor
    /// can make bytes-available bursts look like end-of-run bursts to
    /// the view. Reading on a background queue and only hopping back
    /// once per line keeps streaming visually incremental.
    /// See CLAUDE.md → "Agent-session streaming" for the invariant.
    private func readStdout(handle: FileHandle) async {
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let queue = DispatchQueue(label: "sipai.runner.stdout.\(UUID().uuidString)",
                                          qos: .userInitiated)
                let source = DispatchSource.makeReadSource(
                    fileDescriptor: fd, queue: queue
                )
                // State captured by reference so the handler closures
                // share one leftover buffer + one resume guard.
                let state = StdoutReadState()

                source.setEventHandler { [weak self] in
                    guard let self = self else {
                        source.cancel()
                        return
                    }
                    let bufSize = 4096
                    var buf = [UInt8](repeating: 0, count: bufSize)
                    var accumulated = Data()
                    // Set when this same invocation both read bytes and
                    // hit EOF: the bytes must still be parsed — they are
                    // the tail of the turn, `result` included — and only
                    // then may the source be cancelled. Returning
                    // straight from the EOF branch would throw that
                    // last read away.
                    var atEnd = false
                    while true {
                        // errno is captured WITH the result, inside the
                        // closure. It is thread-local but not call-local,
                        // and the buffer's exclusivity/retain epilogue
                        // sits between the syscall and any later read of
                        // it. Every errno that is not EAGAIN ends this
                        // reader, and this reader is the only thing
                        // draining the child's stdout — so a stale value
                        // read here is paid for by the whole turn.
                        let (n, err): (Int, Int32) =
                            buf.withUnsafeMutableBufferPointer { ptr in
                                let r = read(fd, ptr.baseAddress, bufSize)
                                return (r, r < 0 ? errno : 0)
                            }
                        if n > 0 {
                            accumulated.append(buf, count: n)
                            // Keep reading. A short read does NOT mean
                            // the descriptor is drained: a PTY master
                            // hands back one line-discipline block per
                            // call, so short is the NORM here, not the
                            // exception. Stopping on it leaves the rest
                            // queued and keeps this reader permanently a
                            // wake behind the child — which is the state
                            // in which the child fills the PTY and blocks
                            // in write(), and the state in which a child
                            // that exits takes the unread tail of its
                            // turn (`result` included) down with it.
                            continue
                        }
                        if n == 0 {
                            // The last slave is closed: the child is gone
                            // and no further byte can arrive. This is the
                            // one true end of stream.
                            atEnd = true
                            break
                        }
                        if err == EINTR {
                            // A signal landed mid-syscall. Nothing ended;
                            // read again. Counting this as end-of-stream
                            // cancels the source under a LIVE child, and
                            // then nothing drains its stdout: the child
                            // blocks in write() forever, and since every
                            // turn-end bound waits on the child exiting,
                            // the turn never ends either. The session
                            // sits at "Sipping…" until the app is quit.
                            continue
                        }
                        if err == EAGAIN || err == EWOULDBLOCK {
                            // Drained. The source re-arms and fires again
                            // when the child writes more.
                            break
                        }
                        // A descriptor that can only keep failing. It has
                        // to end the reader: leaving the source armed on
                        // it re-enters this handler in a tight spin.
                        atEnd = true
                        break
                    }
                    defer { if atEnd { source.cancel() } }
                    if accumulated.isEmpty { return }
                    // Split on newline BYTES and decode complete lines
                    // only. A read() ending mid-UTF-8-sequence must not
                    // discard the burst (a whole-chunk String(data:)
                    // decode returns nil there, silently dropping
                    // every event in the read and desyncing leftover).
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
                        let captured = line
                        Task { @MainActor [weak self] in
                            await self?.handleStdoutLine(captured)
                        }
                    }
                }
                source.setCancelHandler {
                    if state.resumed { return }
                    state.resumed = true
                    cont.resume()
                }
                source.resume()
                state.source = source
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

    /// Mutable state shared between the DispatchSource's event and
    /// cancel handlers in `readStdout`. A reference type so both
    /// closures observe the same `leftover` buffer and `resumed` flag
    /// without @escaping-inout gymnastics. Both handlers run on the
    /// source's own serial queue, so no locking is needed.
    private final class StdoutReadState {
        var leftover = Data()
        var resumed: Bool = false
        var source: DispatchSourceRead?
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
            let read = CodexEventParser.parse(line: line, fallbackCwd: cwd)
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
            // Kimi DOES announce its session id, as the last stdout
            // line of a print-mode run:
            //   {"role":"meta","type":"session.resume_hint",
            //    "session_id":"session_…","command":"kimi -r session_…"}
            // Taking it is strictly better than the store diff below it
            // (`startKimiSessionDiscovery`), which infers the same value
            // by watching for a directory that wasn't there before: the
            // announcement is authoritative, immediate, and cannot pick
            // the wrong session when two runs start together. The diff
            // stays as the fallback for a turn that dies before its
            // last line — which is exactly what a crashing child does.
            if sessionId == nil,
               let announced = KimiEventParser.announcedSessionId(line: line) {
                adoptDiscoveredSession(
                    id: announced,
                    fileURL: KimiSessionScanner.wireFile(
                        inSessionDir: KimiSessionScanner
                            .sessionDirectory(forId: announced) ?? cwd))
            }
            parsed = KimiEventParser.parse(line: line, fallbackCwd: cwd)
        default:      parsed = AgentEventParser.parse(line: line, fallbackCwd: cwd)
        }
        for event in parsed {
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
            if case .systemInit(_, let model, _) = event.kind,
               !model.isEmpty, model != "<synthetic>" {
                lastModelId = model
            }
            if case .result = event.kind {
                // This segment is over. Read the Sipping… clock (one
                // subtraction, no transcript scanning) and end the
                // visible turn — the process is not touched.
                stampTurnDuration()
                // Codex and kimi: neither stream carries per-call
                // usage, so the token chip is refreshed from the store
                // file instead. No-op for claude, whose events carry it
                // themselves.
                refreshCodexContextTokens()
                refreshKimiContextTokens()
                endTurnSegment()
            }
            applySubprocessSideEffects(for: event)
        }
        // Mid-turn: codex has just written another `token_count` to its
        // rollout, one per API call. Throttled, and a no-op for the two
        // agents whose chips ride their own event stream.
        if !parsed.isEmpty { refreshCodexContextTokens(throttled: true) }
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
    /// Kimi's documented stream-json is plain chat messages and carries
    /// no id at all, so without this each send would silently start a
    /// brand-new session and the agent would have no memory of the
    /// turn before.
    ///
    /// The lookup is deliberately narrow: an id absent from the
    /// pre-spawn snapshot, in a directory younger than the send, whose
    /// recorded cwd (when it has one) is ours. Everything else is left
    /// alone, so a second kimi running elsewhere cannot be adopted.
    private func startKimiSessionDiscovery(excluding known: Set<String>,
                                           since: Date) {
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
                        cwd: dir, excluding: known, since: since)
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
        NSLog("%@", "SipAI: no kimi session directory appeared under "
              + "\(KimiSessionScanner.sessionRoot.path) for the turn in "
              + "\(cwd.path) (\(why)) — the next send will start a new "
              + "session.")
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
        do {
            for try await line in handle.bytes.lines {
                if Task.isCancelled { break }
                if !stderrBuffer.isEmpty { stderrBuffer += "\n" }
                stderrBuffer += line
                // Cap at ~2kB to avoid unbounded growth.
                if stderrBuffer.count > 2048 {
                    stderrBuffer = String(stderrBuffer.suffix(2048))
                }
            }
        } catch {
            // Expected on cancellation / EOF.
        }
        publishStderrTail()
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
    private static func buildEnvironment() -> [String: String] {
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
    private static func stripDynamicLinkerVars(from env: inout [String: String]) {
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
    private static func overlayProxyVars(into env: inout [String: String]) {
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
    private struct ChildStdoutSource {
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
    private static func makeChildStdoutSource() -> ChildStdoutSource {
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
        // The tailer decodes claude's session JSONL. A codex rollout —
        // and a kimi wire file — are different schemas entirely (see
        // CodexEventParsing.swift / KimiEventParsing.swift), so
        // pointing it at one costs an fd and two timers per browsed
        // session to produce no events at all. Our OWN codex and kimi
        // turns stream over stdout and never need this; an external
        // codex or kimi turn is not watched live.
        guard isClaude else { return }
        let t = AgentSessionTailer(
            fileURL: url,
            fallbackCwd: cwd,
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
        trimLiveEventsIfNeeded()
    }

    private func trimLiveEventsIfNeeded() {
        if events.count > Self.liveEventCap + 200 {
            events.removeFirst(events.count - Self.liveEventCap)
        }
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
        case "codex": return locateCodexRollout(id: id)
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

    /// Newest rollout whose FILENAME carries this thread id.
    ///
    /// Filename-only on purpose. `CodexSessionScanner.rolloutFiles`
    /// answers the same question authoritatively, but falls back to
    /// reading a 512 KB head from every rollout that doesn't match —
    /// hundreds of files, on the MainActor, at the end of every turn.
    /// Codex always embeds the id in the name
    /// (`rollout-<stamp>-<uuid>.jsonl`), so the cheap check is the
    /// right one here; the authoritative walk stays where deletion
    /// needs it.
    nonisolated private static func locateCodexRollout(id: String) -> URL? {
        guard !id.isEmpty,
              let walker = FileManager.default.enumerator(
                at: CodexSessionScanner.sessionRoot,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        var newest: (url: URL, at: Date)? = nil
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
                  name.contains(id) else { continue }
            let at = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest == nil || at > newest!.at { newest = (url, at) }
        }
        return newest?.url
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
