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

    /// True on a row in the user column sent into a turn already running —
    /// the user's words (a message steered in, the answer to a question
    /// the agent asked without stopping; `AgentSessionHistoryItem
    /// .sentIntoTurn`), or a background task's notice claude hands the
    /// model with its next request (`ClaudeBackgroundTasks
    /// .noticeGoesIntoRunningTurn`): no turn of its own — nothing to branch
    /// from, nothing opened, no "Sipping…" brought back under it.
    let sentIntoTurn: Bool

    /// True on a row in the user column that is part of the agent's answer:
    /// a background task reporting back, the user's reply on a question's
    /// card (`AgentSessionHistoryItem.belongsToAnswer`). Compact view draws
    /// it inside the answer's one line.
    let belongsToAnswer: Bool

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

    /// On a `result` event: the words of a turn the agent itself called
    /// FAILED — claude's `is_error` — and "" for one it failed without
    /// words. Nil on a turn that went through and on every other event.
    /// Claude's reader alone sets it: codex and kimi end a failed turn by
    /// other routes (a non-zero exit, their drivers' `noteTurnFailed`).
    /// A field rather than part of the `.result` case, for
    /// `modelContextWindows`' reason.
    let turnFailure: String?

    /// On a `result` event: claude refused the turn before sending
    /// anything, its own estimate of the request being over the model's
    /// limit (`AgentEventParser.refusedAsTooLong`). False on every other
    /// event. A field for `modelContextWindows`' reason.
    let refusedAsTooLong: Bool

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

    /// The skills a `.userMessage` loaded, for the line under the bubble
    /// — set by `send` from the skills it triggered, and by the readers
    /// from the agent's own record of the load, so a reopened message
    /// names the same skills. Empty on every other event.
    let loadedSkills: [String]

    /// On a `.compaction` event: the agent's own record of the summary
    /// says every message the user sent before it is still in the
    /// conversation whole (`AgentSessionHistoryItem
    /// .compactionKeepsUserMessages`). Kimi's alone can; false elsewhere.
    let compactionKeepsUserMessages: Bool

    /// True on the `.userMessage` of a `!` command — the user's own shell
    /// command, run the way the agent's terminal runs one (`ShellCommands`).
    /// Its text is the command as `ShellCommandInput.display` spells it,
    /// and its output is the `.shellOutput` row after it.
    let shellCommand: Bool

    init(kind: StreamEventKind, contextTokens: Int? = nil,
         isSystemNotice: Bool = false, sentIntoTurn: Bool = false,
         belongsToAnswer: Bool = false,
         fastModeState: String? = nil,
         fastModeDisabledReason: String? = nil, callSpeed: String? = nil,
         modelContextWindows: [String: Int]? = nil,
         turnFailure: String? = nil,
         refusedAsTooLong: Bool = false,
         attachedFiles: [String] = [],
         chatOnlyTurn: Bool = false,
         loadedSkills: [String] = [],
         compactionKeepsUserMessages: Bool = false,
         shellCommand: Bool = false) {
        self.id = UUID()
        self.timestamp = Date()
        self.kind = kind
        self.contextTokens = contextTokens
        self.isSystemNotice = isSystemNotice
        self.sentIntoTurn = sentIntoTurn
        self.belongsToAnswer = belongsToAnswer
        self.fastModeState = fastModeState
        self.fastModeDisabledReason = fastModeDisabledReason
        self.callSpeed = callSpeed
        self.modelContextWindows = modelContextWindows
        self.turnFailure = turnFailure
        self.refusedAsTooLong = refusedAsTooLong
        self.attachedFiles = attachedFiles
        self.chatOnlyTurn = chatOnlyTurn
        self.loadedSkills = loadedSkills
        self.compactionKeepsUserMessages = compactionKeepsUserMessages
        self.shellCommand = shellCommand
    }

    /// The same event — the same row, drawn at the same moment — naming
    /// other skills under its message. For a load the row was drawn with
    /// and the agent then turned out not to have made
    /// (`AgentRunner.retractSkillLoads`): the row keeps its identity, so
    /// nothing the user had open on it moves.
    func replacingLoadedSkills(_ skills: [String]) -> StreamEvent {
        StreamEvent(copying: self, loadedSkills: skills)
    }

    /// The same event — the same row, drawn at the same moment — with
    /// another `kind` or other skills under it. A row amended after it was
    /// drawn keeps its identity, so nothing the user has open on it moves:
    /// a kimi tool's result as its session record has it
    /// (`KimiToolEnding`), the skills a load turned out not to make.
    init(copying event: StreamEvent, kind: StreamEventKind? = nil, loadedSkills: [String]? = nil) {
        self.id = event.id
        self.timestamp = event.timestamp
        self.kind = kind ?? event.kind
        self.contextTokens = event.contextTokens
        self.isSystemNotice = event.isSystemNotice
        self.sentIntoTurn = event.sentIntoTurn
        self.belongsToAnswer = event.belongsToAnswer
        self.fastModeState = event.fastModeState
        self.fastModeDisabledReason = event.fastModeDisabledReason
        self.callSpeed = event.callSpeed
        self.modelContextWindows = event.modelContextWindows
        self.turnFailure = event.turnFailure
        self.refusedAsTooLong = event.refusedAsTooLong
        self.attachedFiles = event.attachedFiles
        self.chatOnlyTurn = event.chatOnlyTurn
        self.loadedSkills = loadedSkills ?? event.loadedSkills
        self.compactionKeepsUserMessages = event.compactionKeepsUserMessages
        self.shellCommand = event.shellCommand
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
    /// A readable thought — the model's thinking summary. Present only
    /// where a line draws it: in a Chat only turn, and in every turn while
    /// compact view is on (`keepsThoughts`). The parsers emit none unless
    /// asked, so with compact view off an agent turn's event list is
    /// exactly what it always was.
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
    /// What a `!` command printed, drawn under its row
    /// (`StreamEvent.shellCommand`).
    case shellOutput(ShellCommandOutput)
}

/// Whether SipAI can run a `!` command the way the agent's terminal runs
/// one (`ShellCommands`), over what the app has read of the installed
/// tool (`ShellCommandSupport`): claude where its input can be held open,
/// codex where its app-server has `thread/shellCommand`. Kimi Code offers
/// apps no route, and its `!` is sent as an ordinary message. The composer
/// and the session view both read it, so the hint and Send cannot
/// disagree.
@MainActor
enum ShellCommandRoute {
    static func verdict(agentKey: String) -> ShellCommandVerdict? {
        ShellCommandSupport.verdict(
            agentKey: agentKey,
            claudeVersion: AgentManager.installedClaudeVersion()?.text,
            claudeReplayListed: ClaudeCapabilities.shared.chatOnlyHelp?.listsReplayUserMessages,
            codexVersion: AgentCLIUpdateMonitor.shared.installed["codex"]?.text)
    }
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

    /// When the running turn began; nil while none is running.
    var runningSince: Date? {
        if case .running(let startedAt) = self { return startedAt }
        return nil
    }
}

/// The messages sent while a runner's turn runs (`HeldMessage`), and what
/// may be done with them now. Its own object so the strip above the message
/// box redraws on these alone, never on the stream of transcript events.
@MainActor
final class HeldMessageQueue: ObservableObject {
    /// Oldest first: what goes next when the turn ends.
    @Published fileprivate(set) var messages: [HeldMessage] = []
    /// The running turn takes a message steered into it now.
    @Published fileprivate(set) var steerable = false
    /// A turn of the runner is running: a held message waits for its end.
    @Published fileprivate(set) var turnRunning = false
    /// Why the last message steered into the turn did not go, in the
    /// agent's words where it gave any; cleared by the next.
    @Published fileprivate(set) var refusal: String? = nil
}

/// The write end of a claude child's stdin while its turn takes messages
/// (`ClaudeSteer`): lines written in order, off the main actor — an image
/// message can be larger than the pipe's buffer, and a write blocks until
/// claude drains it.
final class ClaudeInputPipe: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "sipai.claude.input")
    /// Touched on `queue` only.
    private var closed = false

    init(handle: FileHandle) {
        self.handle = handle
        // A claude that exits first — a startup failure, a Stop — would
        // deliver SIGPIPE to this process and end it. Told not to, the
        // write fails with EPIPE and is dropped.
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func write(_ line: String) {
        queue.async { [self] in
            guard !closed else { return }
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    /// End of input: claude winds down once its turn is over — after
    /// reporting a background task it still owes — and exits.
    func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            try? handle.close()
        }
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

    /// The speed a codex session's thread saved, read from its rollout
    /// with the context figure (`CodexSessionScanner.savedServiceTier`):
    /// the speed its exec turns run at whatever the switches say
    /// (`CodexKeptSpeed`). `.unknown` until a read finds the record, and
    /// never set back to it, so a read that missed cannot blank what an
    /// earlier one found.
    @Published private(set) var codexSavedSpeed: CodexKeptSpeed.Saved = .unknown

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

    /// What codex said about the faster speed the latest message asked for
    /// (`CodexSpeedReport`) — the model chip's bolt. Delivered and read as
    /// `fastModeReport` is. Always empty for claude and kimi.
    @Published private(set) var codexSpeedReport = CodexSpeedReport()

    /// One write per change, as above.
    private func setCodexSpeedReport(_ report: CodexSpeedReport) {
        if report != codexSpeedReport { codexSpeedReport = report }
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

    /// Time the running turn has spent waiting on the user — a question
    /// to answer, a plan to approve, a permission to give — which the
    /// composer's clock leaves out, since the turn is waiting, not
    /// working. Claude's own terminal pauses its turn timer the same way,
    /// for as long as any of its prompts is open. Paused exactly while
    /// the turn is running and a card of THIS runner is pending on the
    /// bridge (`syncUserWait`). Reset by every send and every reopened
    /// segment, like the clock it corrects.
    ///
    /// Kept BESIDE `status.running(startedAt:)`, never folded into it:
    /// a status write re-stamps the session's row in the sidebar
    /// (`AgentManager`'s `onStatusChange`), and an answered card is not a
    /// new message. Published on a change only — RunnerStreamView
    /// observes this object, so every publish re-renders the transcript.
    @Published private(set) var userWait = TurnPause()

    /// The permission mode the running turn was in before it entered
    /// plan mode — the mode it was launched in, or the one a card
    /// switched it to since; nil for a turn launched on Plan. Read from
    /// claude's own `system` records as they stream. It is what a plan
    /// card offers to go back to, and the one mode claude lets a plan
    /// approval switch to Bypass from.
    private(set) var modeBeforePlan: String? = nil

    /// The mode a codex session was in before it planned, as the chip
    /// spells it (`AgentAskingMode.adoptDefault` for Default): the mode
    /// the chip left for Plan (`noteCodexChipLeftForPlan`), else the mode
    /// of the last send that was not a Plan one; nil when this launch saw
    /// neither. "Implement this plan?" offers Full Access only to a
    /// session that was in it — the rule Claude Code's plan dialog keeps
    /// for Bypass.
    private(set) var codexModeBeforePlan: String? = nil

    /// The user moved the chip to Plan from `previous` (nil: Default, or
    /// Chat only — neither is Full Access). The chip is the session's mode
    /// whether or not a message went in it: a session reopened on Full
    /// Access and switched to Plan was in Full Access before it planned,
    /// and one moved to Read Only first was not.
    func noteCodexChipLeftForPlan(previous: String?) {
        guard agentKey == "codex" else { return }
        codexModeBeforePlan = previous ?? AgentAskingMode.adoptDefault
    }

    /// Whether this turn declines questions instead of showing them —
    /// the composer's Non-stop switch as this turn was sent with it, and
    /// as it has been flipped since (`setNonStop`). Read by the bridge's
    /// question policy (`AgentManager`) when a question arrives.
    private(set) var nonStop = false

    /// The user text of the turn currently running (nil before the
    /// first send; stale once the turn ends — consult only while
    /// `status.isRunning`), and the live row `send` drew it as. A
    /// history read cuts the running turn's records out of what it read
    /// at that text (`TranscriptSeam.cut`): the file already holds them,
    /// but `clearEvents()` rightly refuses mid-turn, so keeping both
    /// would draw the user's message (and the turn's partial records)
    /// TWICE until the turn finished. The row is how the read finds
    /// where the turn begins in the buffer (`runningTurnStart`) — never
    /// the buffer's first `.userMessage`, which is an earlier turn's
    /// while the session stays on screen across turns, and which the
    /// live-buffer trim can have dropped on a long turn.
    private(set) var inFlightUserText: String? = nil
    /// The files the same message attached (`StreamEvent.attachedFiles`):
    /// what identifies its record when it is files alone and its text is
    /// "".
    private var inFlightUserFiles: [String] = []
    private var runningTurnOpening: UUID? = nil

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
    /// — codex's "Reconnecting… 3/5 (…)", kimi's "Retrying (3/10) · …",
    /// claude's "API error · Retrying · attempt 3/10". Live state, not
    /// history: it is replaced by the next notice, cleared by any real
    /// output, and never enters `events`. See `CodexEventParser.Parsed`,
    /// `KimiSessionScanner.retryNotice` and `AgentEventParser.retryNotice`.
    @Published private(set) var retryNotice: String = ""

    /// The plan a codex Plan turn ended on, while the user has not yet said
    /// whether to carry it out — codex's "Implement this plan?". Not a
    /// card the turn waits on (the turn is over), so nothing pauses and
    /// nothing is notified. Cleared by the answer and by any send.
    @Published private(set) var planFollowUp: String? = nil

    /// The user answered "Implement this plan?" — either way.
    func dismissPlanFollowUp() {
        if planFollowUp != nil { planFollowUp = nil }
    }

    /// What the user had started on a question the turn did not wait on
    /// (codex's question asked without stopping) when its card went — at
    /// the turn's end, at Stop, with the child — for the session's message
    /// box, as Codex's own terminal moves an unsent answer into its own.
    /// Held here because the page showing the session may be torn down,
    /// and taken once by the page that shows it (`takeUnsentAnswers`).
    @Published private(set) var unsentAnswers: String? = nil

    func takeUnsentAnswers() -> String? {
        guard let answers = unsentAnswers else { return nil }
        unsentAnswers = nil
        return answers
    }

    private func keepUnsentAnswers(_ text: String) {
        unsentAnswers = unsentAnswers.map { $0 + "\n\n" + text } ?? text
    }

    /// The child is summarising the conversation right now.
    ///
    /// STATE, never an event: it is true for the 30-ish seconds a
    /// compaction takes and false afterwards, so writing it into
    /// `events` would put it in the history cache and in every later
    /// reopen. Same lifetime and the same reasoning as `retryNotice`.
    /// Claude only — the other two announce nothing while they compact.
    @Published private(set) var compacting: Bool = false

    /// The background work a turn whose answer has landed is still
    /// waiting on — the transcript's line naming it: claude's tasks while
    /// its answer is held (`resultHeldForBackgroundTasks`), kimi's while
    /// its record shows no turn open and a task running, codex's
    /// terminals while its answer waits on a command. Empty otherwise.
    /// STATE, never an event, like `compacting`: a reopen draws the
    /// tasks' own notices and the report, not the wait.
    @Published private(set) var awaitedBackgroundTasks: [BackgroundTaskEntry] = []

    /// The running claude turn's background tasks as claude reports them
    /// (`ClaudeBackgroundTasks`): which are running, and whether one's
    /// notification has not yet reached the model. Reset by every send.
    private var backgroundTasks = ClaudeBackgroundTasks()

    /// Background tasks the user asked to stop from the line naming them,
    /// while the stop goes through: their buttons wait. Reset by every send.
    @Published private(set) var stoppingBackgroundTasks: Set<String> = []

    /// The user stopped a claude background task this turn: claude reports
    /// no such task, so once none is left the held answer is the turn's end
    /// (`endHeldTurnIfOwedNothing`).
    private var userStoppedATask = false

    /// Messages the user sent while a turn runs (`HeldMessage`): held above
    /// the message box until steered into the turn, sent or cancelled —
    /// otherwise sent as the next message when a turn ends on its own.
    let held = HeldMessageQueue()

    /// A claude child's stdin, held open while its turn works so a message
    /// can be steered in and a background task stopped (`ClaudeSteer`). nil
    /// for a turn run the old way — the prompt positional, stdin empty — and
    /// once the turn has ended.
    private var claudeInput: ClaudeInputPipe?

    /// The messages steered into the claude turn that claude has not taken
    /// yet, read off what it prints back (`ClaudeSteerTracker`).
    private var claudeSteers = ClaudeSteerTracker()

    /// claude is working on a turn: from the spawn, and from each turn it
    /// starts in the process (`system/init`), to that turn's `result`.
    private var claudeWorking = false

    /// What a front end's driver last said about taking a message mid-turn
    /// (`AgentRPCHost.setSteerable`).
    private var rpcSteerable = false

    /// The turn runs one of codex's own commands (`/compact`, `/review`)
    /// and opens on no message of the user's: its first notice stands for
    /// the opening row (`runningTurnOpening`).
    private var commandTurn = false

    /// A claude `!` command this turn runs (`ClaudeShellCommand`): its
    /// command, whether its output is still to come, and whether claude
    /// answers it.
    private struct ClaudeShellTurn {
        let command: String
        var awaitingOutput = true
        var quiet = false
        /// Where the terminal's command line writes the folder the command
        /// ended in (`ClaudeTerminalShell`); nil when no shell could run it
        /// the terminal's way and it ran as typed.
        var folderFile: String? = nil
        /// Claude's `CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR`: every command
        /// starts in the session's folder.
        var maintainsSessionFolder = false
    }
    private var claudeShell: ClaudeShellTurn?
    /// The folder the next claude `!` command starts in: where the last one
    /// ended, while inside the session's folder (`ClaudeTerminalShell
    /// .nextFolder`); nil for the session's folder. Kept for the runner's
    /// life, as claude's terminal keeps it for its own.
    private var claudeShellFolder: String?
    /// How many empty `result`s the rows handed to claude without a model
    /// request still owe — passed over by `apply`, like a skill load's; the
    /// last one ends a `!` claude does not answer.
    private var pendingShellResults = 0

    /// The commands a `codex exec` turn has running (`CodexBackgroundCommands`)
    /// — one still running when the turn completes is stopped with it.
    /// Reset by every send.
    private var codexCommands = CodexBackgroundCommands()

    /// A `result` landed while claude still owed a report — a background
    /// task's, or the answer to a message steered into the turn that it had
    /// not read yet — and the turn was kept going (`apply`).
    private var resultHeldForBackgroundTasks = false

    /// The verdict a held `result` carried — the failure row is drawn
    /// when it lands; the turn ends on it once claude has reported its
    /// tasks, or exits without doing so.
    private var heldTurnFailure: String?

    /// Where the clock of a turn that started background tasks began,
    /// kept when its visible segment ends: a segment claude opens after
    /// that (`reopenTurnSegment`) is the same turn going on.
    private var endedSegmentStart: Date?

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

    /// The journal behind a kimi ACP turn's runtime binding
    /// (`KimiRuntimeBinding.restore`): true means "a turn is binding this
    /// session to ACP's runtime; hand it back", false "handed back,
    /// forget it". Wired by `AgentManager` into config, so a session a
    /// crash left bound — without its file and command tools in kimi's
    /// own terminal — is healed at the next launch.
    var onKimiBindingJournal: ((_ sessionId: String, _ owed: Bool) -> Void)?

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

    /// The turn running over its agent's own JSON-RPC protocol
    /// (`runRPCTurn`) while its child lives: the turn's token, its peer and
    /// its driver. Cleared by `finalizeTurn`, whichever caller gets there.
    private var rpcTurn: (token: Int, peer: JSONRPCLinePeer, driver: AgentRPCTurn)? = nil

    /// The RPC turn's protocol was done with it (its driver's `run`
    /// returned) before its child exited. A child that exits after that —
    /// however it exits — reports no error of its own.
    private var rpcTurnCompleted = false

    /// What the RPC turn's driver last said the turn failed on — a row it
    /// has already put on the transcript (`AgentRPCHost.noteTurnFailed`).
    private var rpcTurnFailure: String? = nil

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
    /// With compact view off it decides whether the parsers keep the
    /// model's thoughts: an agent turn's events then carry none.
    private var turnChatOnly = false

    /// The turn in flight is kimi's headless run, whose thoughts are read
    /// back off the session's record (`syncKimiThoughts`). A `kimi acp`
    /// turn's follower carries its own, and reading them back too would
    /// draw each one twice.
    private var turnIsKimiHeadless = false

    /// Whether this turn's events keep the model's thoughts: a Chat only
    /// turn's always, any turn's while compact view is on — the turns that
    /// draw them. Elsewhere a thought would be a row that draws nothing.
    private var keepsThoughts: Bool { turnChatOnly || CompactTranscript.isOn }

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

    /// A headless kimi turn's background tasks, read off the session's
    /// record while the turn runs (`watchKimiTasks`): kimi's stdout says
    /// nothing of a task ending, nor of the notification kimi then sends
    /// itself. The record is read from where the turn began; for a new
    /// session, from its start once kimi has made it.
    private var kimiTasks = KimiSessionScanner.BackgroundTasks()
    private var kimiTaskReader: KimiSessionScanner.RecordReader?
    private var kimiTaskReadFrom: UInt64 = 0
    private var kimiTaskWatch: Task<Void, Never>?
    /// How often the record is read while such a turn runs.
    private static let kimiTaskPollInterval: UInt64 = 500_000_000
    /// How the turn's tool calls ended, by call id, as the record has them
    /// and stdout does not (`KimiToolEnding`): a failure, an image read's
    /// text. One whose row stdout has not printed yet waits here for it
    /// (`apply`).
    private var kimiToolEndings: [String: KimiToolEnding] = [:]

    /// How many empty `result`s the skill messages of this claude turn
    /// still owe (`SkillWire.claudeStdinLines`) — passed over by `apply`
    /// so they do not end the visible turn.
    private var pendingSkillLoadResults = 0
    /// The skills those messages load, in the order they were written —
    /// each named against its own `result` (`ClaudeSkillLoadCheck`) —
    /// and the commands claude last said the session has.
    private var pendingSkillLoadNames: [String] = []
    private var claudeSlashCommands: Set<String>? = nil

    /// The skills a send triggers, as the bubble names them: none in Chat
    /// only (skills are off there for every agent), and none for an agent
    /// SipAI cannot load a skill into by name.
    static func skillNames(for options: AgentLaunchOptions, agentKey: String) -> [String] {
        guard !options.chatOnly else { return [] }
        switch agentKey {
        case SkillAgent.claude: return options.skillTriggers.map(\.name)
        // Only what the message really carries: a skill that cannot be
        // spelled as a mention is not sent, so it is not named.
        case SkillAgent.codex: return SkillWire.codexLoads(options.skillTriggers).map(\.name)
        // One per message, through kimi's own front end
        // (`KimiAcp.promptText`).
        case SkillAgent.kimi: return options.skillTriggers.prefix(1).map(\.name)
        default: return []
        }
    }

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

    /// A claude message refused as too long before anything was sent goes
    /// once more (`AgentEventParser.resendsTooLongRefusal`). Whether this
    /// turn's session existed before its message — the one kind of turn
    /// the re-send can help — and whether claude said it was compacting in
    /// the attempt now streaming, set by `send` and by each attempt.
    private var turnResumedSession = false
    private var attemptTriedCompaction = false
    /// This message has been sent once more already.
    private var tooLongResendUsed = false
    /// The attempt now ending was refused that way: `runOnce` sends the
    /// message again once its child has exited.
    private var tooLongResendPending = false

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

    /// Freeze the composer's turn clock on the elapsed time so far — the
    /// turn's WORKING time: every wait on a card is left out, including
    /// one still open (a turn stopped with a card up is stamped before
    /// the card is cleared). First caller of a turn wins; see
    /// `turnDurationStamped`.
    private func stampTurnDuration() {
        guard !turnDurationStamped,
              case .running(let startedAt) = status else { return }
        turnDurationStamped = true
        lastTurnDuration = userWait.activeElapsed(startedAt: startedAt, now: Date())
    }

    // MARK: - Questions

    /// Whether the claude this runner started is still alive. A question
    /// can only come from a live child, and only a live child can take an
    /// answer — `status.isRunning` is no proof of either: it stays true
    /// for the seconds a stopped child takes to die, and a child may
    /// still be working on after its `result` ended the visible turn.
    var hasLiveChild: Bool { process?.isRunning == true }

    /// The composer's Non-stop switch was flipped while this runner's turn
    /// may be running. Turned on, a question already on screen is
    /// declined at once (with Non-stop's words) and the turn goes on;
    /// turned off, only the turn's NEXT question is shown.
    func setNonStop(_ on: Bool) {
        nonStop = on
        if on {
            bridge?.declineQuestions(sessionId: sessionId, taskUuid: taskUuid)
        }
    }

    /// Keep `userWait` in step with the bridge: paused exactly while
    /// this runner's turn is running and one of ITS cards is pending — a
    /// question, a plan, a permission alike, matched by the bridge's one
    /// ownership rule, so a first turn's card (tagged with the draft's
    /// uuid) pauses its clock too. Called whenever the bridge's pending
    /// list changes (`AgentManager`) and on every status change.
    ///
    /// A card the turn does not wait on (`MCPApprovalRequest.turnWaits`)
    /// is left out: the agent keeps working while it is up, and holding
    /// the clock would take that working time off the turn.
    func syncUserWait() {
        guard let bridge else { return }
        let waiting = status.isRunning && bridge.pending.contains {
            $0.turnWaits && bridge.belongs($0, toSession: sessionId, taskUuid: taskUuid)
        }
        var next = userWait
        if waiting { next.pause(at: Date()) } else { next.resume(at: Date()) }
        if next != userWait { userWait = next }
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
            let saved = CodexSessionScanner.savedServiceTier(of: url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if saved.found, self.codexSavedSpeed != .tier(saved.tier) {
                    self.codexSavedSpeed = .tier(saved.tier)
                }
                guard info.tokens > 0 else { return }
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
         agentKey: String) {
        self.key = key
        self.cwd = cwd
        self.sessionId = sessionId
        self.sessionFileURL = sessionFileURL
        self.initialName = initialName
        self.agentKey = agentKey
        // Every runner holds the bridge: it is where a turn's cards wait,
        // whichever front end asked for them — claude's approver, or
        // codex's and kimi's own protocols. Holding
        // it is not USING the approver: that is a claude-only protocol
        // (`--mcp-config` plus `--permission-prompt-tool`), and its runtime,
        // environment and argv stay behind `isClaude` (`runOnce`,
        // `claudeArguments`). A codex or kimi turn that cannot ask —
        // `codex exec`, `kimi --prompt` — puts nothing on the bridge, so
        // its clock never pauses and Stop finds nothing to answer.
        self.bridge = bridge

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
        startTurn(text: text, options: options, images: images, command: nil)
    }

    /// A `!` command: the user's own shell command, run the way the agent's
    /// terminal runs one (`ShellCommands`) — claude's through its own
    /// headless message for it, then handed to claude as its terminal hands
    /// it over; codex's through its app-server (`thread/shellCommand`).
    /// Kimi offers apps no route. Returns false when refused (mid-turn, no
    /// route), so the composer keeps the draft.
    @discardableResult
    func runShellCommand(_ command: String, options: AgentLaunchOptions) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isClaude || agentKey == "codex" else { return false }
        return startTurn(text: ShellCommandInput.display(trimmed), options: options, images: [],
                         command: agentKey == "codex" ? .shell(trimmed) : nil,
                         shellCommand: trimmed)
    }

    /// Run one of codex's own commands — its terminal's `/compact` and
    /// `/review` — as a turn of its own through its app-server. No message
    /// of the user's opens it: what it draws is codex's own (the compaction
    /// row; the review's notices and the review), as a reopen draws it.
    @discardableResult
    func runCodexCommand(_ command: CodexCommandTurn, options: AgentLaunchOptions) -> Bool {
        guard agentKey == "codex" else { return false }
        return startTurn(text: "", options: options, images: [], command: command)
    }

    private func startTurn(text: String, options: AgentLaunchOptions, images: [AgentImage],
                           command: CodexCommandTurn?, shellCommand: String? = nil) -> Bool {
        guard !status.isRunning else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || command != nil else { return false }

        // The previous child can still be alive after its turn ended —
        // winding down, or holding on for work it never reported as a
        // background task (one it did report keeps the turn running, so
        // no send gets here). This send supersedes it, and two `claude
        // -p` processes must never drive one session: the newcomer's
        // session-lock takeover kills whichever it decides is stale,
        // which can be the turn that was just asked for.
        if let p = process, p.isRunning {
            killChild(reason: "superseded by a new send")
        }
        // A turn over JSON-RPC whose child is still winding down has its
        // conversation closed with it: that turn's own finalize no-ops
        // once this send moves the run token, and nothing it still says
        // may reach the new turn.
        if let rpc = rpcTurn {
            rpc.peer.close(reason: "superseded by a new send")
            rpcTurn = nil
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
        // A leading line of skill mentions is stripped for codex alone,
        // whose reader strips it on reopen; claude's and kimi's keep a
        // first line shaped like one, so their live row must too.
        var display = CodexSessionScanner.strippedTaskMarker(
            trimmed, mentionLine: agentKey == SkillAgent.codex)
        var loaded = Self.skillNames(for: options, agentKey: agentKey)
        // A kimi message the user opened on a skill command themselves,
        // sent through kimi's front end, which starts that skill with the
        // rest as its input: drawn as the reader draws its record — the
        // words, the skill named under them — or the live row and its
        // record disagree (the branch pencil's match, a mid-turn reload's
        // cut). Read off the WIRE text, by kimi's own rule
        // (`KimiAcp.slashCommand`), because that is what kimi reads: a
        // scheduled run's prompt opens on its marker, which is no command
        // to kimi — read off the cleaned text, a task whose prompt began
        // `/skill:x` was drawn as a load that never happened. A skill's
        // bare name is a command to kimi too, where the session has it.
        // A `!` command loads no skill: it is a command, not a message.
        if shellCommand != nil { loaded = [] }
        if agentKey == SkillAgent.kimi, loaded.isEmpty, !options.chatOnly, shellCommand == nil,
           AgentAskingMode.runsThroughFrontEnd(
               agentKey: agentKey, mode: options.permissionMode, chatOnly: false,
               frontEndOffered: AskingModeGate.frontEnd(agentKey: agentKey) == .offered),
           let typed = KimiAcp.typedSkill(trimmed, isSkill: { [cwd] name in
               SkillDirectory.lookup(name, SkillAgent.kimi, cwd) != nil
           }) {
            let words = CodexSessionScanner.strippedTaskMarker(typed.message, mentionLine: false)
            if !words.isEmpty {
                display = words
                loaded = [typed.name]
            }
        }
        // A codex command opens on no message of the user's: codex records
        // none, and a reopen draws what codex does (`commandTurn`). A `!`
        // command is the user's own line, codex's included.
        if command == nil || shellCommand != nil {
            let opening = StreamEvent(kind: .userMessage(text: display),
                                      attachedFiles: shellCommand == nil
                                          ? AttachmentInline.names(in: trimmed) : [],
                                      chatOnlyTurn: options.chatOnly && shellCommand == nil,
                                      loadedSkills: loaded,
                                      shellCommand: shellCommand != nil)
            events.append(opening)
            runningTurnOpening = opening.id
            inFlightUserText = display
            inFlightUserFiles = opening.attachedFiles
        } else {
            runningTurnOpening = nil
            inFlightUserText = nil
            inFlightUserFiles = []
        }
        commandTurn = command != nil && shellCommand == nil
        turnChatOnly = options.chatOnly && command == nil && shellCommand == nil
        turnIsKimiHeadless = false
        // Claude's `!`: run first, then handed over (`handOverShellOutput`).
        // Codex's is its driver's (`CodexCommandTurn.shell`).
        claudeShell = isClaude ? shellCommand.map { ClaudeShellTurn(command: $0) } : nil
        pendingShellResults = 0
        // A plan offered to carry out is answered by sending anything.
        dismissPlanFollowUp()
        chatOnlyTurnRecorded = false
        kimiThoughtsPlaced = 0
        kimiThoughtSyncPending = false
        kimiThoughtSyncFinal = false
        stopKimiTaskWatch()
        // Whatever the chips say when this turn's system.init lands is
        // not what this turn ran as — the user is free to move them
        // mid-turn. Captured here, it can only ever describe this send.
        launchedModelAlias = options.model ?? ""
        // A refusal describes the turn it happened in; the next one asks
        // for fast mode afresh (credits may have been added meanwhile).
        updateFastModeReport { $0.refusal = nil }
        // Codex says for each message whether it can run the speed asked
        // for; the previous message's answer is not this one's.
        setCodexSpeedReport(agentKey == "codex"
            ? .asking(options.codexServiceTierOverride) : CodexSpeedReport())
        stderrTail = ""
        stderrBuffer = ""
        retryNotice = ""
        compacting = false
        disarmTurnEndWatchdog()
        runToken &+= 1
        stopRequested = false
        turnDurationStamped = false
        backgroundTasks = ClaudeBackgroundTasks()
        codexCommands = CodexBackgroundCommands()
        clearHeldBackgroundTasks()
        endedSegmentStart = nil
        turnResumedSession = !(sessionId?.isEmpty ?? true)
        attemptTriedCompaction = false
        tooLongResendUsed = false
        tooLongResendPending = false
        // A child left from the turn before has had its input closed; this
        // turn opens its own (`runOnce`).
        closeClaudeInput()
        claudeSteers = ClaudeSteerTracker()
        claudeWorking = false
        rpcSteerable = false
        userStoppedATask = false
        stoppingBackgroundTasks = []
        // The turn's own question policy and a fresh pause, both before
        // the status flip (which re-derives the pause from the bridge).
        // Non-stop decides only a turn that can ask — the rule the
        // composer's switch reads, off and greyed elsewhere. A question
        // that still reaches the user in such a turn — one codex asks
        // without stopping, in a fixed mode — is shown: declined under a
        // pick the switch keeps but does not show, it would vanish unseen.
        nonStop = options.nonStop && AgentAskingMode.asksQuestions(
            agentKey: agentKey, mode: options.permissionMode, chatOnly: options.chatOnly,
            frontEndOffered: true)
        if userWait != TurnPause() { userWait = TurnPause() }
        modeBeforePlan = nil
        if agentKey == "codex", !options.chatOnly,
           options.permissionMode != AgentAskingMode.codexPlan {
            codexModeBeforePlan = options.permissionMode ?? AgentAskingMode.adoptDefault
        }
        kimiDiscoveryTask?.cancel()
        stdoutReaderFinished = false
        stderrReaderFinished = false
        childExitObserved = false
        rpcTurnCompleted = false
        rpcTurnFailure = nil
        setStatus(.running(startedAt: Date()))
        // After the status flip: the notice is only ever published on
        // a turn this guard says is still running. A `!` command prints
        // nothing until it is done, and a long one is no agent's silence.
        if shellCommand == nil { armStallNotice() }

        runTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runOnce(text: trimmed, options: options, images: images, command: command)
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
            // Nothing more goes into the turn: what was steered in and not
            // yet taken waits above the box again, for the user to send.
            closeClaudeInput()
            returnUntakenSteers()
            // Freeze the composer's duration chip at the stop instant —
            // a killed turn never emits the `result` event that
            // normally stamps this.
            stampTurnDuration()
            // Stop ends the background tasks with the turn (claude takes
            // them down when it is signalled), so nothing is waited on.
            clearHeldBackgroundTasks()
            events.append(StreamEvent(kind: .interrupted(message:
                Self.interruptedByUserMessage)))
            // A dead claude can never consume an answer — clear its
            // pending approval cards instead of leaving ghost
            // questions on screen (the MCP handler thread would
            // otherwise block on its semaphore forever).
            cancelPendingApprovals()
            // A turn over the agent's own protocol is told so in that
            // protocol first — its cards were answered just above — and
            // given the agent's own grace to wind down, so the transcript
            // records the turn as stopped rather than cut off. The task is
            // NOT cancelled yet: that would SIGTERM the child at once
            // (`waitForExit`). A second Stop finds `stopRequested` set and
            // kills straight away.
            if let rpc = rpcTurn, rpc.token == runToken,
               let p = process, p.isRunning {
                let grace = rpc.driver.interrupt(peer: rpc.peer)
                let token = runToken
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
                    guard let self, self.runToken == token,
                          let p = self.process, p.isRunning else { return }
                    self.runTask?.cancel()
                    self.killChild(reason: "Stop")
                }
                armTurnFinalize(after: grace + Self.stopGrace, reason: "Stop, after the agent's interrupt")
                return
            }
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
    /// (or, for a draft, its task_uuid), keeping what the user had started
    /// on a question the turn did not wait on.
    private func cancelPendingApprovals() {
        let unsent = bridge?.cancelPending(sessionId: sessionId, taskUuid: taskUuid) ?? []
        for text in unsent { keepUnsentAnswers(text) }
    }

    // MARK: - Messages sent while the turn runs

    /// Hold a message sent while this runner's turn runs (`HeldMessage`).
    /// False when no turn runs: the message is an ordinary send then.
    @discardableResult
    func hold(text: String, options: AgentLaunchOptions, images: [AgentImage] = [],
              codexCommand: CodexCommandTurn? = nil, shellCommand: String? = nil,
              boxText: String? = nil, boxFiles: [URL] = []) -> Bool {
        guard status.isRunning else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Drawn as `send` draws a message: the user's own words, the files
        // on the paperclip line.
        let display = CodexSessionScanner.strippedTaskMarker(
            trimmed, mentionLine: agentKey == SkillAgent.codex)
        held.messages.append(HeldMessage(text: trimmed, display: display,
                                         attachedFiles: AttachmentInline.names(in: trimmed),
                                         images: images, options: options,
                                         codexCommand: agentKey == "codex" ? codexCommand : nil,
                                         shellCommand: shellCommand,
                                         boxText: boxText, boxFiles: boxFiles))
        held.refusal = nil
        return true
    }

    /// Send a held message as a message of its own — or run the codex
    /// command it is. False when it could not start.
    private func sendHeld(_ message: HeldMessage) -> Bool {
        if let command = message.shellCommand {
            return runShellCommand(command, options: message.options)
        }
        if let command = message.codexCommand {
            return runCodexCommand(command, options: message.options)
        }
        return send(text: message.text, options: message.options, images: message.images)
    }

    /// Hand a held message to the running turn: claude reads it from its
    /// open stdin, codex takes it over `turn/steer`. It stays above the
    /// box, marked sent, until the agent takes it; its row is drawn then,
    /// where the agent's own record puts it (`drawSteerTaken`).
    func steerHeld(_ id: UUID) {
        guard held.steerable, let index = held.messages.firstIndex(where: { $0.id == id }),
              !held.messages[index].steered, held.messages[index].canGoIntoTurn
        else { return }
        let message = held.messages[index]
        held.refusal = nil
        if isClaude, let input = claudeInput {
            held.messages[index].steered = true
            claudeSteers.wrote(message.text)
            input.write(message.images.isEmpty
                        ? ClaudeSteer.userLine(text: message.text)
                        : ChatOnlyImages.claudeStdinLine(text: message.text, images: message.images))
            return
        }
        guard let rpc = rpcTurn, rpc.token == runToken else { return }
        held.messages[index].steered = true
        let token = runToken
        let name = agentDisplayName
        Task { [weak self] in
            let refusal = await rpc.driver.steer(text: message.text, peer: rpc.peer)
            guard let self, let refusal else { return }
            // Not taken: it waits for the turn's end again, and says why.
            if let i = self.held.messages.firstIndex(where: { $0.id == id }) {
                self.held.messages[i].steered = false
            }
            guard self.runToken == token else { return }
            self.held.refusal = refusal.isEmpty
                ? String(localized: "\(name) didn’t take the message now. It will be sent when this turn ends.",
                         comment: "Above the agent composer: a message steered into the running turn was not taken; placeholder is the agent label")
                : String(localized: "\(name) didn’t take the message now: \(refusal)",
                         comment: "Above the agent composer: a message steered into the running turn was refused; placeholders are the agent label and the agent's own words")
        }
    }

    /// The agent took a message steered into the turn: it leaves the strip
    /// and its row goes into the transcript here, as the agent's record
    /// keeps it — the user's words sent into the turn, opening none
    /// (`StreamEvent.sentIntoTurn`), or a message of its own when claude
    /// had already answered and ran it as a turn after (`opensTurn`).
    private func drawSteerTaken(text: String, opensTurn: Bool) {
        let key = ClaudeSteerTracker.key(text)
        guard let index = held.messages.firstIndex(where: {
            $0.steered && ClaudeSteerTracker.key($0.text) == key
        }) else { return }
        let message = held.messages.remove(at: index)
        events.append(StreamEvent(kind: .userMessage(text: message.display), sentIntoTurn: !opensTurn,
                                  attachedFiles: message.attachedFiles,
                                  chatOnlyTurn: turnChatOnly))
    }

    /// Send a held message now, as a message of its own — no turn runs: the
    /// last one was stopped, or this message could not go when it ended.
    /// True when it went.
    @discardableResult
    func sendHeldNow(_ id: UUID) -> Bool {
        guard !status.isRunning, !externalInProgress,
              let message = held.messages.first(where: { $0.id == id && !$0.steered }),
              sendHeld(message)
        else { return false }
        held.messages.removeAll { $0.id == id }
        return true
    }

    /// Take a held message back: it goes nowhere, and the caller puts what
    /// the box held for it back in the box (`HeldMessage.boxText`). One
    /// already steered into the turn is the agent's now, and stays.
    func takeBackHeld(_ id: UUID) -> HeldMessage? {
        guard let index = held.messages.firstIndex(where: { $0.id == id && !$0.steered })
        else { return nil }
        held.refusal = nil
        return held.messages.remove(at: index)
    }

    /// A turn ended on its own: the oldest held message goes now, as the
    /// next message. Never after Stop — the user stopped, and what they held
    /// waits for them — and never into a session another process is
    /// running a turn on.
    private func releaseHeldMessage() {
        guard !stopRequested, held.messages.contains(where: { !$0.steered }) else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.status.isRunning, self.process == nil, !self.stopRequested,
                  !self.externalInProgress,
                  let next = self.held.messages.first(where: { !$0.steered }) else { return }
            if self.sendHeld(next) {
                self.held.messages.removeAll { $0.id == next.id }
            }
        }
    }

    /// Messages steered into a turn that ended before the agent took them —
    /// stopped, or its child gone: they wait above the box again.
    private func returnUntakenSteers() {
        _ = claudeSteers.dropUnread()
        for i in held.messages.indices where held.messages[i].steered {
            held.messages[i].steered = false
        }
    }

    /// Whether the running turn takes a message steered into it now: a
    /// claude turn with its input open while claude works, or a front end
    /// whose driver says so; never after Stop. Called wherever any of that
    /// changes, `setStatus` included.
    private func refreshSteerable() {
        let running = status.isRunning
        var on = false
        if running, !stopRequested {
            if isClaude {
                on = claudeInput != nil && claudeWorking
            } else if let rpc = rpcTurn, rpc.token == runToken {
                on = rpcSteerable
            }
        }
        if held.steerable != on { held.steerable = on }
        if held.turnRunning != running { held.turnRunning = running }
    }

    /// End of claude's input for this turn: it winds down and exits once it
    /// has nothing left to do.
    private func closeClaudeInput() {
        guard let input = claudeInput else { return }
        claudeInput = nil
        input.close()
        refreshSteerable()
    }

    /// A `!` command's output, as claude printed it back: drawn under the
    /// command's row, then handed to claude as its terminal hands it over —
    /// the input row, the output row (claude's own long-output form past its
    /// cap), and a model request to answer it unless claude's
    /// `respondToBashCommands` says not to (`ClaudeShellCommand`). Nothing
    /// goes in after Stop, nor for a command claude did not run: its input
    /// closes and claude exits.
    private func handOverShellOutput(_ printed: ShellCommandOutput) {
        guard var shell = claudeShell else { return }
        shell.awaitingOutput = false
        claudeShell = shell
        var reported: String? = nil
        if let file = shell.folderFile {
            reported = (try? String(contentsOfFile: file, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(atPath: file)
        }
        // Stopped, or not run: drawn as claude printed it, and nothing goes in.
        guard !printed.interrupted, printed.notRun == nil else {
            appendShellOutputRow(printed)
            closeClaudeInput()
            return
        }
        // The folder the next `!` starts in, as claude's terminal keeps it.
        let sessionFolder = Self.physicalPath(cwd.path)
        let next = shell.folderFile == nil
            ? (folder: claudeShellFolder, resetNote: false)
            : ClaudeTerminalShell.nextFolder(
                reported: printed.exitCode == 0 && reported?.isEmpty == false ? reported : nil,
                current: claudeShellFolder, sessionFolder: sessionFolder,
                maintainsSessionFolder: shell.maintainsSessionFolder)
        claudeShellFolder = next.folder
        // The terminal's command line makes its two streams one; anything on
        // the error stream came from the `/bin/sh` that started it.
        var merged = printed.stdout
        if !printed.stderr.isEmpty {
            if !merged.isEmpty, !merged.hasSuffix("\n") { merged += "\n" }
            merged += printed.stderr
        }
        let output = ClaudeShellCommand.terminalOutput(
            merged: merged, exitCode: printed.exitCode,
            folderResetTo: next.resetNote ? sessionFolder : nil)
        appendShellOutputRow(output)
        guard !stopRequested, let input = claudeInput else {
            closeClaudeInput()
            return
        }
        let settings = Self.claudeSettings(cwd: cwd)
        let responds = ClaudeShellCommand.responds(settings: settings)
        let cap = ClaudeShellCommand.outputCap(settings: settings)
        let stdoutRow: String
        let stderrRow: String
        if output.reportedFailure {
            stdoutRow = ""
            stderrRow = ClaudeShellCommand.errorText(output.stderr, cap: cap)
        } else if output.stdout.isEmpty {
            stdoutRow = ClaudeShellCommand.noOutputText
            stderrRow = output.stderr
        } else {
            let saved = output.stdout.count > cap ? saveShellOutput(output.stdout) : nil
            stdoutRow = ClaudeShellCommand.modelStdout(output.stdout, cap: cap, savedPath: saved)
            stderrRow = output.stderr
        }
        // One message, its rows as text blocks: claude keeps it whole
        // (`ClaudeShellCommand`).
        var rows: [String] = responds ? [] : [ClaudeShellCommand.quietNote]
        rows.append(ClaudeShellCommand.inputRow(shell.command))
        rows.append(ClaudeShellCommand.outputRow(stdout: stdoutRow, stderr: stderrRow))
        pendingShellResults = responds ? 0 : 1
        claudeShell?.quiet = !responds
        input.write(ClaudeShellCommand.rowsLine(rows, query: responds))
        // Asked to answer, claude works on the rows now, and a message held
        // meanwhile may be steered into that answer.
        if responds { claudeWorking = true; refreshSteerable() }
    }

    /// A `!` command's output row: under its command's row, above a Stop's.
    private func appendShellOutputRow(_ output: ShellCommandOutput) {
        let row = StreamEvent(kind: .shellOutput(output))
        if let last = events.last, case .interrupted = last.kind {
            events.insert(row, at: events.index(before: events.endIndex))
        } else {
            events.append(row)
        }
    }

    /// Claude's headless message for a `!` command: the command line claude's
    /// terminal builds (`ClaudeTerminalShell`) — the user's shell and startup
    /// file, input from `/dev/null`, the folder it ends in written back — in
    /// the folder the last `!` ended in. Claude's environment is the child's
    /// with the `env` blocks of its settings on top, as claude applies them.
    /// Where no shell can run it so, the command goes as typed.
    private func claudeShellLine(_ command: String, environment: [String: String]) -> String {
        let settings = Self.claudeSettings(cwd: cwd)
        var claudeEnvironment = environment
        for (name, value) in ClaudeTerminalShell.settingsEnvironment(settings) {
            claudeEnvironment[name] = value
        }
        var isFolder: ObjCBool = false
        let start: String
        if let folder = claudeShellFolder,
           FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue {
            start = folder
        } else {
            claudeShellFolder = nil
            start = Self.physicalPath(cwd.path)
        }
        guard let shell = ClaudeTerminalShell.shell(
            environment: claudeEnvironment,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return ClaudeShellCommand.bashCommandLine(command, cwd: start)
        }
        let folderFile = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("sipai-shell-\(UUID().uuidString)-cwd")
        claudeShell?.folderFile = folderFile
        claudeShell?.maintainsSessionFolder = ClaudeTerminalShell.isOn(
            claudeEnvironment["CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR"])
        return ClaudeShellCommand.bashCommandLine(
            ClaudeTerminalShell.commandLine(command, shell: shell,
                                            home: claudeEnvironment["HOME"] ?? NSHomeDirectory(),
                                            folderFile: folderFile),
            cwd: start)
    }

    /// A folder as a process inside it reports it (`pwd -P`): every link
    /// resolved, `/private` included.
    private static func physicalPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(path, &buffer).map { String(cString: $0) } ?? path
    }

    /// Claude's settings files in the order claude applies them — the
    /// user's, then the folder's project and local files — for the two
    /// settings a `!` command reads, and `showThinkingSummaries`.
    private static func claudeSettings(cwd: URL) -> [Data] {
        let files = ClaudeModelCatalog.userSettingsFiles + [
            cwd.appendingPathComponent(".claude/settings.json"),
            cwd.appendingPathComponent(".claude/settings.local.json"),
        ]
        return files.compactMap { try? Data(contentsOf: $0) }
    }

    /// The whole of a long `!` output, where claude's terminal keeps one: a
    /// file in the session's `tool-results` folder. Nil while the session
    /// has no file yet, or when the write fails — the model then gets the
    /// head alone, in claude's own words for that.
    private func saveShellOutput(_ stdout: String) -> String? {
        guard isClaude, let file = sessionFileURL,
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        let folder = file.deletingPathExtension()
            .appendingPathComponent("tool-results", isDirectory: true)
        let target = folder.appendingPathComponent(ClaudeShellCommand.savedOutputName())
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(stdout.utf8).write(to: target, options: .atomic)
            return target.path
        } catch {
            return nil
        }
    }

    /// A claude turn held for background work that is all over with no
    /// report owed — the user stopped the last task from the line naming
    /// it, and claude reports no such task — and with nothing steered in
    /// still unread: no further `result` is coming, so the held answer is
    /// the turn's end. Its input closes, and claude exits.
    private func endHeldTurnIfOwedNothing() {
        guard isClaude, claudeInput != nil, userStoppedATask, resultHeldForBackgroundTasks,
              status.isRunning, !stopRequested, !claudeWorking,
              backgroundTasks.resultEndsTurn, !claudeSteers.pending
        else { return }
        stampTurnDuration()
        endTurnSegment()
        closeClaudeInput()
    }

    /// Whether a background task the turn waits on can be stopped on its
    /// own: claude's through its open input (`stop_task`), codex's through
    /// its app-server. Kimi's front end has no such request — Stop ends the
    /// turn and every task with it.
    var canStopBackgroundTasks: Bool {
        guard status.isRunning, !stopRequested else { return false }
        if isClaude { return claudeInput != nil }
        if agentKey == "codex", let rpc = rpcTurn, rpc.token == runToken { return true }
        return false
    }

    /// Stop one background task the turn waits on, from the line naming
    /// it. The turn goes on waiting for the rest; with none left it ends.
    func stopBackgroundTask(id: String) {
        guard canStopBackgroundTasks, !stoppingBackgroundTasks.contains(id) else { return }
        stoppingBackgroundTasks.insert(id)
        if isClaude, let input = claudeInput {
            userStoppedATask = true
            backgroundTasks.noteStoppedByUser(id: id)
            input.write(ClaudeSteer.stopTaskLine(taskId: id, requestId: UUID().uuidString))
            return
        }
        guard let rpc = rpcTurn, rpc.token == runToken else { return }
        let token = runToken
        Task { [weak self] in
            let stopped = await rpc.driver.stopBackgroundTask(id: id, peer: rpc.peer)
            guard let self, self.runToken == token, !stopped else { return }
            self.stoppingBackgroundTasks.remove(id)
        }
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
    /// while background tasks it started are still running, and streams
    /// FURTHER SEGMENTS when they complete — a task notification, then a
    /// fresh turn reporting it, in the same process. A `result` claude
    /// gives while it still owes such a report does not end the turn at
    /// all (`apply`, `ClaudeBackgroundTasks`). Killing the child merely
    /// for being alive after `result` cuts pending work off mid-flight,
    /// so nothing here touches the process, the readers or the tailer.
    /// `handleStdoutLine` reopens the turn when another segment arrives;
    /// the child's own exit runs the full cleanup in `finalizeTurn`; a
    /// child that lingers with nothing left to say costs an idle
    /// process, and the next send reaps it.
    ///
    /// - Parameter failure: the words of a turn the agent itself called
    ///   failed at its result (`StreamEvent.turnFailure`). The status set
    ///   here is the turn's last — `finalizeTurn` flips no status after
    ///   it, and the scheduler records a run by its code and words alone —
    ///   so a failure ends on a failing code here, or a failed scheduled
    ///   run is recorded "done".
    private func endTurnSegment(failure: String? = nil) {
        guard status.isRunning else { return }
        // An answer held for background tasks ends the turn on its own
        // verdict where the report's result carries none.
        let failure = failure ?? heldTurnFailure
        endedSegmentStart = backgroundTasks.sawTask ? status.runningSince : nil
        clearHeldBackgroundTasks()
        disarmStallNotice()
        retryNotice = ""
        compacting = false
        setStatus(.done(exitCode: failure == nil ? 0 : -1, errorMessage: failure))
    }

    /// A new segment is streaming from a child whose previous segment
    /// already ended — the turn is live again, clocked from now. A turn
    /// that started background tasks keeps its clock instead: claude
    /// reporting one is that turn going on, and a clock restarted from
    /// zero would end on the report's seconds alone. Its waits on a card
    /// stay left out, so the pause is kept with the start.
    private func reopenTurnSegment() {
        turnDurationStamped = false
        if let start = endedSegmentStart {
            endedSegmentStart = nil
            setStatus(.running(startedAt: start))
            return
        }
        if userWait != TurnPause() { userWait = TurnPause() }
        setStatus(.running(startedAt: Date()))
    }

    /// Nothing is held for background tasks any more: the turn ended, was
    /// stopped, or a new one began.
    private func clearHeldBackgroundTasks() {
        resultHeldForBackgroundTasks = false
        heldTurnFailure = nil
        if !awaitedBackgroundTasks.isEmpty { awaitedBackgroundTasks = [] }
    }

    /// Start the second attempt of a message claude refused as too long
    /// (`AgentEventParser.resendsTooLongRefusal`). It is the same turn: its
    /// clock runs on and nothing has been stamped. The message is drawn a
    /// second time, as claude records it — the re-send writes a second
    /// record of the same words, which a reopened session draws too. A new
    /// run token, so nothing armed for the refused attempt (the bound its
    /// child's exit armed, its stall notice) can act on this one.
    private func beginTooLongResend() {
        tooLongResendUsed = true
        disarmTurnEndWatchdog()
        runToken &+= 1
        process = nil
        stdoutReaderFinished = false
        stderrReaderFinished = false
        childExitObserved = false
        stderrTail = ""
        stderrBuffer = ""
        retryNotice = ""
        compacting = false
        attemptTriedCompaction = false
        if let row = events.last(where: Self.isMessageRow) {
            events.append(StreamEvent(kind: row.kind, attachedFiles: row.attachedFiles,
                                      chatOnlyTurn: row.chatOnlyTurn,
                                      loadedSkills: row.loadedSkills))
        }
        armStallNotice()
    }

    /// A refused attempt's child has nothing left to do — nothing ran — and
    /// exits at once; the re-send waits for that exit. One that lingers is
    /// reaped the way the next send reaps a child that outlived its turn.
    private func reapRefusedChildIfItLingers() {
        let token = runToken
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.stopGrace * 1_000_000_000))
            guard let self, self.runToken == token, self.tooLongResendPending,
                  let p = self.process, p.isRunning else { return }
            self.killChild(reason: "a turn refused as too long, before its re-send")
        }
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

    /// How long a Default turn on codex or kimi waits for the installed
    /// CLI's version, when it has not been read yet, before deciding which
    /// front end to run through — longer than the read itself may take
    /// (`AgentCLIProbe.versionCeiling`). The version is read at launch, so
    /// this is spent in the first moments of a launch, or on a CLI whose
    /// version cannot be read at all.
    static let frontEndVerdictWait: TimeInterval = 15

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
                  // A card IS something coming back: a turn whose first
                  // act was to ask the user — a codex Plan question, a kimi
                  // permission — has been heard from, however long the
                  // answer then took, and no row precedes such a card.
                  self.userWait == TurnPause(),
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

    /// Whether this turn has yet produced anything the user can see: the
    /// waiting row's own rule (`WaitingRow`), with a compaction row counted
    /// as something seen.
    private var awaitingFirstOutput: Bool {
        WaitingRow.awaitsAgent(events, compactionIsOutput: true)
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
    ///
    /// - Parameter errorRowShown: `errorMessage` is already on the
    ///   transcript, as the driver's own row: the turn ends on it without
    ///   a second one.
    @discardableResult
    private func finalizeTurn(token: Int,
                              exitCode: Int32,
                              errorMessage: String?,
                              errorRowShown: Bool = false,
                              fallbackReason: String? = nil) -> Bool {
        // Two things can still be owed here: the visible turn's state
        // flip (a turn that never got a `result` — crash, kill, spawn
        // failure) and the process cleanup. Either suffices to proceed;
        // a call with neither left to do is the idempotent no-op.
        guard token == runToken, status.isRunning || process != nil else {
            return false
        }
        // When the turn began, before its status flips below: the record
        // read at the end belongs to this turn only from that moment on.
        let turnBegan: Date? = {
            if case .running(let startedAt) = status { return startedAt }
            return nil
        }()
        disarmTurnEndWatchdog()
        // A kimi Chat only turn wrote the session's tool-policy file;
        // the child is gone (or being killed), so put it back now —
        // whichever of the finalize callers got here first.
        restoreKimiToolPolicyIfPending()
        // A codex image turn's temp files have been read by now.
        cleanupCodexImageFilesIfPending()
        // A `!` command that never reported its folder (a Stop, a crash)
        // leaves the file it would have written it to.
        if let file = claudeShell?.folderFile {
            try? FileManager.default.removeItem(atPath: file)
        }
        // A turn over JSON-RPC: its conversation is over, whatever is
        // still in flight. Nothing more it sends is read.
        if let rpc = rpcTurn, rpc.token == token {
            rpc.peer.close(reason: "the turn ended")
            rpcTurn = nil
        }
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
            if let errText = errorMessage, !errorRowShown {
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
            // A claude that exits while its answer was held for
            // background tasks ends the turn on that answer's verdict:
            // its row is already drawn, and a failed scheduled run must
            // not be recorded done.
            var exitCode = exitCode, errorMessage = errorMessage
            if let held = heldTurnFailure {
                if exitCode == 0 { exitCode = -1 }
                if errorMessage == nil { errorMessage = held }
            }
            setStatus(.done(exitCode: exitCode, errorMessage: errorMessage))
        }
        clearHeldBackgroundTasks()
        process = nil
        // Whatever claude was still to read goes nowhere now: a message
        // steered in and never taken waits above the box again.
        closeClaudeInput()
        returnUntakenSteers()
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
        // stdout (a stopped turn) — and a background task's notice.
        syncKimiThoughts(final: true)
        finishKimiTaskWatch(token: token)
        // A model Moonshot refused for the plan, or one that answered: the
        // model menu marks it, or stops marking it.
        noteKimiPlanRefusals(turnBegan: turnBegan)
        recordChatOnlyTurnIfNeeded()
        // A message held while the turn ran goes next, now that its child
        // is gone — unless the user stopped the turn.
        releaseHeldMessage()
        return true
    }

    // MARK: - Chat only turns: the record and kimi's thoughts

    /// Hand out a finished Chat only turn's handle (see
    /// `onChatOnlyTurnRecorded`), resolved off the main thread by the
    /// same newest-first match the branch writers use for a live row: its
    /// words, or — for a message of attached files alone, whose words are
    /// "" — the files it named. Best effort: a turn whose record cannot be
    /// found keeps its look until the session is reopened, then reads as
    /// an agent turn.
    private func recordChatOnlyTurnIfNeeded() {
        guard turnChatOnly, !chatOnlyTurnRecorded,
              let sid = sessionId, !sid.isEmpty,
              let text = inFlightUserText else { return }
        chatOnlyTurnRecorded = true
        let files = inFlightUserFiles
        let key = agentKey
        let known = sessionFileURL
        Task.detached(priority: .utility) { [weak self] in
            guard let url = known ?? Self.locateSessionFile(id: sid, agentKey: key)
            else { return }
            let handle: String?
            switch key {
            case "codex":
                handle = CodexSessionFork.resolveCutPoint(matchingUserText: text,
                                                          attachedFiles: files, in: url)
            case "kimi":
                handle = KimiSessionFork.resolveCutPoint(matchingUserText: text,
                                                         attachedFiles: files, in: url)
            case "claude_code":
                handle = AgentSessionFork.resolveCutPoint(matchingUserText: text,
                                                          attachedFiles: files, in: url)
            default:
                handle = nil
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
        guard isKimi, turnChatOnly || (turnIsKimiHeadless && CompactTranscript.isOn) else { return }
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

    // MARK: A headless kimi turn's background tasks

    /// Read a headless kimi turn's record for its background tasks while
    /// the turn runs, from `offset` — the record's size before the turn
    /// began, 0 for a new session, whose record this turn starts. The turn
    /// itself stays running through kimi's wait for a task by construction
    /// (kimi's stdout has no turn-end event, so the turn ends when kimi
    /// exits); what the record adds is the line naming the task and kimi's
    /// notice of its end, which kimi's stdout never carries — and how each
    /// tool call ended (`KimiToolEnding`), which it does not carry either.
    private func watchKimiTasks(from offset: UInt64, token: Int) {
        stopKimiTaskWatch()
        kimiTaskReadFrom = offset
        kimiTaskWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.runToken == token else { return }
                await self.readKimiTasks(token: token)
                try? await Task.sleep(nanoseconds: Self.kimiTaskPollInterval)
            }
        }
    }

    private func stopKimiTaskWatch() {
        kimiTaskWatch?.cancel()
        kimiTaskWatch = nil
        kimiTaskReader = nil
        kimiTasks = KimiSessionScanner.BackgroundTasks()
        kimiToolEndings = [:]
    }

    /// The turn has ended: the record is read once more — a notice the
    /// timer had not reached yet is placed — and the watch stops.
    private func finishKimiTaskWatch(token: Int) {
        guard kimiTaskWatch != nil else { return }
        kimiTaskWatch?.cancel()
        kimiTaskWatch = nil
        Task { @MainActor [weak self] in
            await self?.readKimiTasks(token: token)
        }
    }

    /// One read of the record: what it has gained, the tasks it now shows
    /// the turn waiting on, and kimi's notice of each task that ended.
    private func readKimiTasks(token: Int) async {
        guard token == runToken else { return }
        if kimiTaskReader == nil {
            // A new session's record is there once kimi has named it.
            guard let wire = sessionFileURL
                    ?? sessionId.flatMap({ KimiSessionScanner.sessionDirectory(forId: $0) })
                        .map({ KimiSessionScanner.wireFile(inSessionDir: $0) })
            else { return }
            kimiTaskReader = KimiSessionScanner.RecordReader(offset: kimiTaskReadFrom) { from in
                await Task.detached(priority: .utility) {
                    KimiSessionScanner.RecordTail.read(wire, from: from)
                }.value
            }
        }
        guard let reader = kimiTaskReader else { return }
        let lines = await reader.newLines()
        guard token == runToken, reader === kimiTaskReader else { return }
        let now = Date()
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            // How a tool call ended, which stdout does not say: its row is
            // set to it, or — not printed yet — gets it as it is appended.
            if let ending = KimiEventParser.toolEnding(record: record) {
                if let index = events.lastIndex(where: {
                    if case .toolResult(let id, _, _) = $0.kind { return id == ending.toolCallId }
                    return false
                }) {
                    if let kind = ending.correcting(events[index].kind) {
                        events[index] = StreamEvent(copying: events[index], kind: kind)
                    }
                } else {
                    kimiToolEndings[ending.toolCallId] = ending
                }
            }
            guard let notice = kimiTasks.feed(record: record, now: now) else { continue }
            // Never after Stop: the task goes down with the turn, and the
            // interrupted row says the turn was stopped.
            if !stopRequested { placeKimiTaskNotice(notice.text, writtenAt: notice.time) }
        }
        let awaited = status.isRunning && !stopRequested ? kimiTasks.awaited : []
        if awaitedBackgroundTasks != awaited { awaitedBackgroundTasks = awaited }
    }

    /// Put kimi's notice of a task that ended where kimi wrote it: before
    /// the first of this turn's rows that arrived after it — the report of
    /// the turn kimi opens on it — else at the end. The record is read on a
    /// timer, so the report's rows can be on screen before the notice is
    /// read; kimi writes the notification before it asks the model for the
    /// report, so every row of the report arrives after its time.
    private func placeKimiTaskNotice(_ text: String, writtenAt: Date?) {
        let notice = StreamEvent(kind: .userMessage(text: text), isSystemNotice: true,
                                 belongsToAnswer: true)
        let start = events.lastIndex(where: Self.opensTurn).map { $0 + 1 } ?? events.startIndex
        if let writtenAt,
           let at = events[start...].firstIndex(where: { $0.timestamp >= writtenAt }) {
            events.insert(notice, at: at)
        } else {
            events.append(notice)
        }
        trimLiveEventsIfNeeded()
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
        // And so is the offer to carry out the plan this app's last turn
        // ended on: the conversation has moved on in another process, and
        // "Implement the plan." would now be said to whatever that left.
        dismissPlanFollowUp()
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
            case "claude_code":
                start = AgentSessionScanner.lastTurnStartDate(of: url)
                stoppable = sid.flatMap {
                    ClaudeSessionStatusStore.stoppableExternalPid(sessionId: $0)
                }
            default:
                start = nil
                stoppable = nil
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

    /// Drop the live event buffer. The session view calls this when a
    /// history read lands with no turn running (`TranscriptSeam
    /// .liveBuffer`): the file on disk is the superset of every FINISHED
    /// turn, so keeping the buffer would render those turns twice
    /// (history copy above, live copy below). Refused mid-turn — the
    /// current turn's events aren't fully on disk yet.
    func clearEvents() {
        guard !status.isRunning else { return }
        events.removeAll()
        trimmedHeadChatOnly = false
    }

    /// Drop the thoughts kept for agent turns, once compact view is off:
    /// outside a Chat only turn nothing draws a thought then, and a row
    /// that draws nothing spends the display window and its "older rows"
    /// count. A Chat only turn keeps its own.
    func dropAgentTurnThoughts() {
        var chatOnly = trimmedHeadChatOnly
        var kept: [StreamEvent] = []
        kept.reserveCapacity(events.count)
        for event in events {
            if case .userMessage = event.kind, !event.isSystemNotice, !event.sentIntoTurn {
                chatOnly = event.chatOnlyTurn
            }
            if case .thinking = event.kind, !chatOnly { continue }
            kept.append(event)
        }
        if kept.count != events.count { events = kept }
    }

    /// Drop the live rows from `id` on — all of them when `id` is nil,
    /// none when it is not in the buffer: an earlier message edited in
    /// place takes the conversation back above it. Refused mid-turn, like
    /// `clearEvents`.
    func discardEvents(from id: UUID?) {
        guard !status.isRunning else { return }
        guard let id else {
            events.removeAll()
            trimmedHeadChatOnly = false
            return
        }
        guard let at = events.firstIndex(where: { $0.id == id }) else { return }
        events.removeSubrange(at...)
    }

    /// A codex thread reverted to an earlier message goes on in a NEW
    /// rollout (`AgentSessionRewind`); the old one is never
    /// written again. The transcript, the tailer and the token chip move
    /// to it — a tailer left on the old file would watch a file nothing
    /// writes.
    func adoptRewoundRollout(_ url: URL) {
        guard agentKey == "codex", url != sessionFileURL else { return }
        tailer?.stop()
        tailer = nil
        sessionFileURL = url
        startTailer(at: url, initialOffset: Self.currentSize(of: url))
        refreshCodexContextTokens()
    }

    /// Where the running turn begins in the live buffer — the index of
    /// the row `send` opened it with — or nil while no turn of ours is
    /// running, and once the front trim has cut that row away.
    var runningTurnStart: Int? {
        guard status.isRunning else { return nil }
        return TranscriptSeam.runningTurnStart(in: events, opening: runningTurnOpening)
    }

    /// `clearEvents()` for a turn still running: drop every turn the
    /// buffer holds BEFORE the running one, which then opens it. The view
    /// calls this when a read of the file held the running turn's opening
    /// record (`TranscriptSeam.liveBuffer`) — a read taken after every
    /// earlier turn had ended, and so holding them all.
    func dropTurnsBeforeRunningTurn() {
        guard let start = runningTurnStart, start > 0 else { return }
        events.removeFirst(start)
        trimmedHeadChatOnly = false
    }

    // MARK: - Argument construction

    private func claudeArguments(text: String,
                                 options: AgentLaunchOptions,
                                 streamJSONInput: Bool = false,
                                 replayUserMessages: Bool = false) -> [String] {
        // A turn whose messages come on stdin — one that takes a message
        // while it works, an image turn, one loading skills — reads them as
        // stream-json, so the positional prompt is dropped and
        // `--input-format stream-json` is added; `-p` stays (the input
        // format is only valid with it). Otherwise the prompt is
        // positional. `--replay-user-messages` makes claude print each
        // message back as it takes it (`ClaudeSteerTracker`).
        var args: [String] = streamJSONInput
            ? ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
            : ["-p", text, "--output-format", "stream-json", "--verbose"]
        if streamJSONInput, replayUserMessages { args.append(ClaudeSteer.replayFlag) }
        args.append(contentsOf: options.flags(for: agentKey))
        // A chosen skill of a SUBFOLDER of the session's folder: claude is
        // not started with that folder's skills, and `--add-dir` lists
        // them as the project's for this turn, so its quiet load finds
        // one (`SkillSubfolderReach`). The folder is inside the session's
        // own — no file access is added — and its CLAUDE.md is not read.
        // Variadic: every value is followed by another flag, never by
        // the prompt.
        if !options.chatOnly {
            for dir in SkillTrigger.claudeAddDirs(options.skillTriggers) {
                args.append(contentsOf: ["--add-dir", dir])
            }
        }
        // Chat only: web lookups only, no MCP, the persona — in `ChatOnlyArgv`'s
        // order, BEFORE `--resume`, because two of its flags are
        // variadic and would swallow the id. The snapshot-off flag
        // rides every claude turn, but only when the installed `--help`
        // lists it (an unknown flag is a startup error).
        // Readable thinking on an agent turn follows the user's own Claude
        // setting, as in claude's terminal (`claudeAsksThinkingSummaries`).
        args.append(contentsOf: ChatOnlyArgv.claude(
            options: options,
            snapshotFlagListed: ClaudeCapabilities.shared.chatOnlyHelp?.listsSnapshot == true,
            thinkingDisplayAccepted: ClaudeCapabilities.shared.acceptsThinkingSummaries == true,
            thinkingSummariesAsked: !options.chatOnly
                && ChatOnlyArgv.claudeAsksThinkingSummaries(Self.claudeSettings(cwd: cwd))))
        if let id = sessionId, !id.isEmpty {
            args.append("--resume")
            args.append(id)
            // An earlier message edited in place: claude parents this one
            // at the entry above it, and the turns it replaces are left
            // behind as a branch it does not load again.
            if let entry = options.claudeResumeAt, !entry.isEmpty {
                args.append(contentsOf: [ClaudeCapabilities.resumeSessionAtFlag, entry])
            }
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
            // The hooks that report claude's "don't ask again" suggestions
            // and put an MCP server's forms and links on a card, and the
            // grants of this session's earlier turns — merged into the
            // launch's one `--settings` value, since claude reads only the
            // last of two (Fast mode already passes one).
            args = ClaudeSettingsArgv.merging(
                bridge.launchSettings(sessionId: sessionId, taskUuid: taskUuid),
                into: args)
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
        // runs at what `codex exec` resolves by itself. On a RESUMED
        // thread a codex that keeps a thread's speed (`CodexKeptSpeed`)
        // runs the tier its rollout saved and ignores the pin: the pin
        // decides a new thread's speed, and a thread with no record
        // takes it.
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
    ///    every tool call on its own: this command IS kimi's Never Ask,
    ///    the one mode it runs. Kimi's other modes run through `kimi
    ///    acp` (`KimiAcpTurn`), and never reach this argv.
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
                         images: [AgentImage] = [],
                         command: CodexCommandTurn? = nil) async {
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

        // Another kimi has this session open — its terminal, its desktop
        // app, an editor — and kimi's own lock says which
        // (`KimiSessionLock`). A headless kimi would be refused there, but
        // one over kimi's front end would run and write beside the holder:
        // so neither starts, and the turn says why, before anything is
        // spawned or written.
        if agentKey == "kimi", let sid = sessionId, !sid.isEmpty,
           let holder = KimiSessionLock.heldElsewhere(sessionId: sid) {
            let message = KimiSessionLock.occupiedMessage(holder, agentName: agentDisplayName)
            events.append(StreamEvent(kind: .error(message: message)))
            setStatus(.done(exitCode: -1, errorMessage: message))
            return
        }

        // Which front end this send runs through (`AgentTurnDriver.pick`).
        // Default runs through codex's and kimi's own front end wherever
        // the installed CLI has one, and headless below the floor, and so
        // do codex's fixed modes. Its version is read at launch and after
        // every update; a turn sent before that read lands asks for it and
        // waits, bounded (`frontEndVerdictWait`). A version that still
        // cannot be read ends a Default turn with words: run headless on a
        // guess, a kimi turn under a chip reading Default would approve
        // every tool call itself. A fixed codex mode runs headless then:
        // `codex exec` enforces the same mode (`AgentAskingMode
        // .isCodexFixed`). A kimi turn that loads a chosen skill asks too,
        // in any mode: only kimi's front end loads one
        // (`AgentTurnDriver.pick`).
        var frontEndOffered = false
        let fixedCodexMode = agentKey == "codex" && AgentAskingMode.isCodexFixed(options.permissionMode)
        if (agentKey == "codex" || agentKey == "kimi"), !options.chatOnly,
           options.permissionMode == nil || fixedCodexMode
            || (agentKey == "kimi" && !options.skillTriggers.isEmpty) {
            let deadline = Date().addingTimeInterval(Self.frontEndVerdictWait)
            var verdict = AskingModeGate.frontEnd(agentKey: agentKey)
            if verdict == .pending {
                Task { await AgentCLIUpdateMonitor.shared.refreshLocal() }
            }
            while verdict == .pending, Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard turnStillOurs() else { return }
                verdict = AskingModeGate.frontEnd(agentKey: agentKey)
            }
            guard verdict != .pending || fixedCodexMode else {
                // The sentence is the status's too: a scheduled run's record
                // says why the run did not start in these words. A tool that
                // cannot start has no version to read, and says why itself.
                let agentName = agentDisplayName
                let message = AgentCLIUpdateMonitor.shared.startFailures[agentKey]
                    .flatMap(CLIStartFailure.reason(in:))
                    .map { reason in
                        String(localized: "\(agentName) can’t start: \(reason)",
                               comment: "Runner error: a turn was not started because the installed command-line tool stops with an error when asked its version; placeholders are the agent label and the line the tool printed")
                    }
                    ?? AgentAskingMode.unreadVersionMessage(agentName: agentDisplayName)
                events.append(StreamEvent(kind: .error(message: message)))
                setStatus(.done(exitCode: -1, errorMessage: message))
                return
            }
            frontEndOffered = verdict == .offered
        }
        let driver = AgentTurnDriver.pick(agentKey: agentKey, options: options,
                                          isNewSession: sessionId?.isEmpty ?? true,
                                          frontEndOffered: frontEndOffered)
        // An agent this app has no route for is refused here, before
        // anything is prepared or spawned: run as another CLI's turn it
        // would get that CLI's flags, and its output that CLI's parser.
        guard driver != .unsupported else {
            let message = String(localized: "SipAI doesn’t support this for this agent yet.",
                                 comment: "Refusal for an agent SipAI has no code for")
            events.append(StreamEvent(kind: .error(message: message)))
            setStatus(.done(exitCode: -1, errorMessage: message))
            return
        }
        turnIsKimiHeadless = isKimi && driver == .kimiPrint

        // One of codex's own commands (`/compact`, `/review`): a turn of its
        // own through codex's app-server, whatever the mode — `codex exec`
        // has neither, and would send the words to the model. The composer
        // offers them only where the installed codex has the front end.
        if let command {
            guard agentKey == "codex", AskingModeGate.frontEnd(agentKey: agentKey) == .offered,
                  let turn = makeRPCTurn(.codexAppServer, text: "", options: options, images: [],
                                         textWithoutSubfolderSkills: "", command: command)
            else {
                let message = String(localized: "This needs a newer \(agentDisplayName). Update it in Settings → Updates.",
                                     comment: "Runner error: a Codex command (/compact, /review) needs Codex's app-server, which the installed Codex lacks; placeholder is the agent label")
                events.append(StreamEvent(kind: .error(message: message)))
                setStatus(.done(exitCode: -1, errorMessage: message))
                return
            }
            await runRPCTurn(turn, binary: binary)
            return
        }

        // The skills this send loads, in each agent's own spelling: codex
        // reads a mention line ahead of the text (its exec and app-server
        // front ends alike); claude reads one message per skill ahead of
        // the text, on stdin, below. The bubble already shows the user's
        // own words with the skills named under them (`send`).
        let skillNames = Self.skillNames(for: options, agentKey: agentKey)
        // A skill moved since its folder was read goes by name instead of
        // by a path codex no longer has (`SkillWire.codexTriggers`). A
        // subfolder's skill is codex's only through its app-server, told
        // of the subfolder first (`SkillSubfolderReach`): a headless turn
        // is sent none — the chip offers none there, and a mention codex
        // cannot place loads nothing, saying nothing.
        let codexTriggers = driver == .codexExec
            ? options.skillTriggers.filter { $0.skillsFolder == nil } : options.skillTriggers
        // …and its row stops naming them. The chip offers a subfolder's
        // skill while the installed codex's version is still unread (the
        // turn waits for it above); one that then runs headless drew its
        // message with a skill it never carried.
        if agentKey == "codex", codexTriggers.count != options.skillTriggers.count {
            retractSkillLoads(options.skillTriggers.filter { $0.skillsFolder != nil }.map(\.name))
        }
        func codexWire(_ triggers: [SkillTrigger]) -> String {
            guard agentKey == "codex", !SkillWire.codexLoads(triggers).isEmpty else { return text }
            return SkillWire.codexText(
                skills: SkillWire.codexTriggers(triggers,
                                                exists: { FileManager.default.fileExists(atPath: $0) }),
                text: text)
        }
        let wireText = skillNames.isEmpty ? text : codexWire(codexTriggers)
        // What an app-server turn sends instead when codex cannot be told
        // of a subfolder's skills: the message without their mentions,
        // which would load nothing and be read back as loads on reopen.
        let wireTextWithoutSubfolders = skillNames.isEmpty ? text
            : codexWire(codexTriggers.filter { $0.skillsFolder == nil })

        // A kimi turn loads a skill only through kimi's own front end.
        // The composer sends none without one; a scheduled run gets here
        // when the installed kimi's version was read only after the run's
        // skills were resolved, and it turned out to have no front end.
        // The run then goes headless WITHOUT its skill — said, and its row
        // no longer naming it — never with a skill drawn that was not sent.
        if isKimi, driver != .kimiAcp, !options.chatOnly, !options.skillTriggers.isEmpty {
            retractSkillLoads(nil)
            if let name = options.skillTriggers.first?.name {
                events.append(StreamEvent(kind: .error(message: String(
                    localized: "The skill “\(name)” can’t be loaded: \(SkillSubfolderReach.newerAgentNeeded)",
                    comment: "Scheduled-run failure: a task's skill cannot be loaded; placeholders are the skill and why"))))
            }
        }

        // A kimi session an ACP turn left bound to ACP's runtime runs
        // without its file and command tools until it is handed back.
        // Every turn's own end hands it back; this is for the one whose
        // end has not been reached — a child still exiting, a crash.
        if isKimi, let id = sessionId, !id.isEmpty {
            await restoreKimiBinding(sessionId: id)
            guard turnStillOurs() else { return }
            // A headless turn cannot answer a plan review, and in plan mode
            // it can edit nothing: a session an Ask turn left there leaves
            // it first. Ask turns set their mode every time.
            if driver == .kimiPrint {
                await leaveKimiPlanModeIfLeftOn(sessionId: id, binary: binary)
                guard turnStillOurs() else { return }
            }
        }

        // A codex thread a Plan turn left in plan mode runs a headless turn
        // under the plan instructions: it is put back first. An asking
        // turn states its own mode.
        if agentKey == "codex", driver == .codexExec, let id = sessionId, !id.isEmpty {
            await leaveCodexPlanModeIfLeftOn(sessionId: id, binary: binary)
            guard turnStillOurs() else { return }
        }
        // A new exec thread is born at the speed its first message pins,
        // and codex keeps it (`CodexKeptSpeed`): known from this send, a
        // beat before the rollout records it. A send that pins none runs
        // at codex's config, which the rollout then says.
        if agentKey == "codex", driver == .codexExec, sessionId?.isEmpty != false,
           let pinned = options.codexServiceTierOverride {
            codexSavedSpeed = .tier(pinned)
        }

        // A kimi DRAFT's first Chat only turn has no session directory
        // to put a tool-policy file in, and a session born through
        // kimi's server refuses `--prompt` until its first prompt — so
        // that one turn goes through the server. Every later turn is
        // the ordinary spawn below, around the policy file.
        if driver == .kimiWeb {
            await runKimiWebTurn(text: text, options: options, images: images, binary: binary)
            return
        }

        // The agent's own front end: the turn runs through its interactive
        // protocol, where it can ask the user (`runRPCTurn`) — and, for
        // codex's fixed modes, where its speed is its own and a command it
        // leaves running is not stopped with it.
        if driver.speaksJSONRPC {
            guard let turn = makeRPCTurn(driver, text: wireText, options: options, images: images,
                                         textWithoutSubfolderSkills: wireTextWithoutSubfolders) else {
                events.append(StreamEvent(kind: .error(message:
                    String(localized: "This mode isn’t available in the installed \(agentDisplayName). Pick another mode and send again.",
                           comment: "Runner error when a mode that asks the user is picked but the installed agent CLI cannot run it; placeholder is the agent label"))))
                setStatus(.done(exitCode: -1, errorMessage: "asking mode unavailable"))
                return
            }
            await runRPCTurn(turn, binary: binary)
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
        if isClaude, let bridge = bridge {
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
        //
        // A turn that loads skills goes the same way: one stream-json
        // message per skill, each marked not to start a model call, then
        // the text — claude expands every skill and makes ONE model
        // request holding all of them and the text. Each skill message
        // answers with an empty `result` of its own before the turn's,
        // which `apply` passes over (`pendingSkillLoadResults`). Images
        // ride Chat only alone, which loads no skills, so the two never
        // meet.
        let claudeSkillLines: String? = (isClaude && !skillNames.isEmpty && images.isEmpty)
            ? SkillWire.claudeStdinLines(skills: skillNames, text: text)
            : nil
        pendingSkillLoadResults = claudeSkillLines == nil ? 0 : skillNames.count
        pendingSkillLoadNames = claudeSkillLines == nil ? [] : skillNames
        claudeSlashCommands = nil
        // A claude that takes a message while it works (`ClaudeSteer`)
        // gets its prompt on stdin too, as the first message there, and
        // keeps stdin open until the turn ends.
        let claudeTakesInput = isClaude && ClaudeSteer.takesInput(
            installedClaude: AgentManager.installedClaudeVersion()?.text,
            replayListed: ClaudeCapabilities.shared.chatOnlyHelp?.listsReplayUserMessages == true)
        // A `!` command needs claude's input held open: it is run there,
        // and the rows its terminal writes go in after it.
        if isClaude, claudeShell != nil, !claudeTakesInput {
            let message = ShellCommandWords.needsNewer(agentName: agentDisplayName)
            events.append(StreamEvent(kind: .error(message: message)))
            setStatus(.done(exitCode: -1, errorMessage: message))
            return
        }
        // A `!` command's line is built once claude's environment is known,
        // below (`claudeShellLine`).
        var claudeStdinLine: String? = claudeShell.map { ClaudeShellCommand.bashCommandLine($0.command) }
            ?? claudeSkillLines ??
            ((isClaude && !images.isEmpty)
             ? ChatOnlyImages.claudeStdinLine(text: text, images: images)
             : (claudeTakesInput ? ClaudeSteer.userLine(text: text) : nil))

        let args: [String]
        switch agentKey {
        case "codex": args = codexArguments(text: wireText, options: options, imageFiles: codexImageFiles)
        case "kimi":  args = kimiArguments(text: text, options: options)
        case "claude_code":
            args = claudeArguments(text: claudeShell == nil ? text : "", options: options,
                                   streamJSONInput: claudeStdinLine != nil,
                                   replayUserMessages: claudeTakesInput)
        default:
            // Refused at `AgentTurnDriver.unsupported` above; ended here
            // too, never spawned with another CLI's argv.
            let message = String(localized: "SipAI doesn’t support this for this agent yet.",
                                 comment: "Refusal for an agent SipAI has no code for")
            events.append(StreamEvent(kind: .error(message: message)))
            setStatus(.done(exitCode: -1, errorMessage: message))
            return
        }

        // Kimi names its session on stdout only with the turn's final
        // answer, so a draft's id is read back off the store meanwhile —
        // and telling OUR new session apart from the ones already there
        // needs the "before" list taken before the child can create
        // anything. Cheap: two levels of directory names, no file reads.
        let kimiKnownIds: Set<String> =
            (isKimi && (sessionId?.isEmpty ?? true))
            ? KimiSessionScanner.sessionIds() : []
        // Where this turn's records will begin, for its background tasks and
        // how its tool calls ended (`watchKimiTasks`): the record's size
        // before kimi can add to it. A Chat only turn starts no task, and
        // its web lookups end in the record as any tool call does.
        let watchesKimiTasks = isKimi && driver == .kimiPrint
        let kimiRecordStart: UInt64 = {
            guard watchesKimiTasks, let id = sessionId, !id.isEmpty,
                  let wire = sessionFileURL
                    ?? KimiSessionScanner.sessionDirectory(forId: id)
                        .map({ KimiSessionScanner.wireFile(inSessionDir: $0) })
            else { return 0 }
            return Self.currentSize(of: wire)
        }()

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
        // hand it an explicitly empty one. A claude turn whose messages
        // come on stdin (`--input-format stream-json`: one that takes a
        // message while it works, an image turn, one loading skills) gets
        // a pipe, written below.
        let stdinPipe: Pipe? = claudeStdinLine != nil ? Pipe() : nil
        p.standardInput = stdinPipe ?? FileHandle.nullDevice

        // Build PATH-rich env + overlay MCP-related vars. The await is
        // load-bearing: `buildEnvironment` reads the login shell's
        // captured environment for the proxy settings, and that read
        // BLOCKS while the capture is still in flight — which on the
        // MainActor would freeze the app. Normally a no-op; `warmUp()`
        // has run since launch.
        // Whether the installed claude reports a background task it was
        // left waiting on: its version, and the setting its wait sits
        // behind as claude last cached it — read off the main actor
        // before the guard below, which then covers this await too.
        let claudeVersion = isClaude ? AgentManager.installedClaudeVersion()?.text : nil
        let claudeShellWait = isClaude ? await Self.cachedClaudeShellWait() : nil
        await ShellEnvironment.prepare()
        guard turnStillOurs() else {
            restoreKimiToolPolicyIfPending()
            cleanupCodexImageFilesIfPending()
            return
        }
        var env = Self.buildEnvironment()
        if isClaude, let bridge = bridge {
            for (k, v) in bridge.environmentOverlay(sessionIdOrTaskUuid: sipaiIdentity) {
                env[k] = v
            }
        }
        // Background tasks: allowed where the installed claude waits for
        // one and reports it, switched off everywhere else — an older
        // claude kills a still-running task five seconds after the
        // turn's `result`, and nothing on either feed says so. See
        // `ClaudePrintMode.environmentOverlay` for why the switch
        // OVERRIDES anything inherited, and why codex and kimi are left
        // alone.
        for (k, v) in ClaudePrintMode.environmentOverlay(agentKey: agentKey,
                                                         installedClaude: claudeVersion,
                                                         cachedShellWait: claudeShellWait) {
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
        if let shell = claudeShell {
            claudeStdinLine = claudeShellLine(shell.command, environment: env)
        }

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

        // A claude that takes messages while it works: its input stays
        // open, the prompt first, until the turn ends (`closeClaudeInput`).
        if claudeTakesInput, let line = claudeStdinLine, let pipe = stdinPipe {
            let input = ClaudeInputPipe(handle: pipe.fileHandleForWriting)
            input.write(line)
            claudeInput = input
            // A `!` command is not a model turn: nothing steers into it
            // until claude is asked to answer it.
            claudeSteers = ClaudeSteerTracker(prompt: claudeShell == nil ? text : nil)
            claudeWorking = claudeShell == nil
            refreshSteerable()
        } else if let line = claudeStdinLine, let pipe = stdinPipe {
            // claude's image turn (or one loading skills) on a claude that
            // takes no message mid-turn: hand it the stream-json user
            // record(s) and close the write end, so it reads them and
            // reaches EOF. Done off the MainActor — the payload is a few
            // hundred KB of base64 and the write can block until claude
            // drains it.
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
        if watchesKimiTasks { watchKimiTasks(from: kimiRecordStart, token: token) }

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

        // Claude refused the message as too long before sending anything
        // (`apply`), and its child has gone: the message goes once more,
        // as the same turn, and claude compacts before it sends it. A Stop
        // meanwhile ends the turn the ordinary way below.
        if tooLongResendPending {
            tooLongResendPending = false
            if turnStillOurs() {
                beginTooLongResend()
                // An edit in place made its cut with the refused attempt:
                // that message already hangs off the entry it went back
                // to, with the instruction files claude attached for it.
                // Going back again would drop that copy and be refused
                // the same way.
                var again = options
                again.claudeResumeAt = nil
                await runOnce(text: text, options: again, images: images)
                return
            }
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
    ///
    /// Live streaming needs both halves: the child's stdout must be a
    /// PTY (`makeChildStdoutSource` — Node block-buffers a pipe until
    /// the child exits) AND this loop must run off the MainActor, where
    /// it would queue behind every re-render. Drop either and a turn's
    /// events arrive in one burst at the end.
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

    /// The stdout of a turn over JSON-RPC: the same draining loop, every
    /// complete line handed to the peer ON the reader's queue — the peer
    /// decodes it there and delivers it to the main actor in arrival
    /// order (`JSONRPCLinePeer`), which a `Task` per line would not.
    private func readRPCStdout(handle: FileHandle, peer: JSONRPCLinePeer) async {
        let fd = handle.fileDescriptor
        guard fd >= 0 else {
            peer.receiveEOF()
            return
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let source = Self.makeDrainingLineSource(
                fd: fd,
                label: "sipai.runner.rpc.\(UUID().uuidString)",
                owner: self,
                onLine: { line in peer.receive(line: line) },
                // A newline-less tail is half a message — dropped.
                onEnd: { _ in
                    peer.receiveEOF()
                    cont.resume()
                }
            )
            source.resume()
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
            var read = CodexEventParser.parse(line: line, fallbackCwd: cwd,
                                              includeThinking: keepsThoughts)
            // A command still running in a background terminal when an exec
            // turn completes: codex stops it with the turn, and says so
            // nowhere on stdout — while the answer may say it is under way.
            // Said before the turn's end; never after Stop.
            codexCommands.read(line: line)
            if !stopRequested, !codexCommands.running.isEmpty,
               read.events.contains(where: { if case .result = $0.kind { return true } else { return false } }) {
                read.events = codexCommands.running.map {
                    StreamEvent(kind: .userMessage(text: CodexBackgroundNotice.stopped(command: $0.description)),
                                isSystemNotice: true)
                } + read.events
                codexCommands = CodexBackgroundCommands()
            }
            parsed = read.events
            // Newest notice REPLACES the previous one, and any real
            // output clears it: this is the state of the connection,
            // not a log of it. Codex's warning that it runs the message
            // without the speed asked for is the model chip's to say
            // (`CodexSpeedReport`), as on the app-server's route.
            if let notice = read.notice {
                if let dropped = CodexSpeed.droppedTier(warning: notice),
                   dropped == codexSpeedReport.asked {
                    setCodexSpeedReport(CodexSpeedReport(asked: dropped, dropped: true))
                } else {
                    retryNotice = notice
                }
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
            // Kimi retrying a model request it got no answer to — up to
            // ten attempts over minutes, with nothing else on stdout
            // meanwhile. Held like codex's notice above.
            if let notice = KimiEventParser.retryNotice(line: line) {
                retryNotice = notice
            } else if !parsed.isEmpty {
                retryNotice = ""
            }
        case "claude_code":
            // Claude announces a compaction starting and finishing on
            // `system`/`status` records. Consulted BEFORE the parse,
            // which deliberately turns those into nothing: a
            // compaction takes half a minute during which the child
            // says nothing else, and an unexplained silence there is
            // the shape of a hang.
            if let flag = AgentEventParser.compactingSignal(line: line) {
                compacting = flag
                if flag { attemptTriedCompaction = true }
            }
            // The mode the turn is in, as claude states it at launch and
            // on every change. Plan itself is not kept: what a plan card
            // needs is the mode the turn planned OUT of.
            if let mode = AgentEventParser.permissionMode(line: line), mode != "plan" {
                modeBeforePlan = mode
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
            // A skill loaded ahead of the message that claude did not
            // have: its message went into the conversation as the words
            // "/name", and only these two records say so
            // (`ClaudeSkillLoadCheck`). Read before the parse, which keeps
            // neither field.
            if !pendingSkillLoadNames.isEmpty {
                if let commands = ClaudeSkillLoadCheck.slashCommands(initLine: line) {
                    claudeSlashCommands = commands
                } else if let ran = ClaudeSkillLoadCheck.ranCommand(resultLine: line) {
                    let name = pendingSkillLoadNames.removeFirst()
                    if ClaudeSkillLoadCheck.failed(name: name, slashCommands: claudeSlashCommands,
                                                   ranCommand: ran) {
                        retractSkillLoads([name])
                        events.append(StreamEvent(kind: .error(message:
                            SkillLoadWords.notFound(agentName: agentDisplayName, skill: name))))
                    }
                }
            }
            // A background task the turn started: what claude reports
            // running, and a notice when one ends. Read before the parse,
            // which turns these records into nothing. No notice after
            // Stop: the task goes down with the turn, the interrupted row
            // already says the turn was stopped, and claude keeps nothing
            // of it for a reopen to draw. A notice drawn while claude still
            // works on its turn goes into that turn and opens nothing
            // (`sentIntoTurn`), so no "Sipping…" comes back under it; one
            // drawn after claude's answer opens the report claude runs on it.
            var taskNotices: [StreamEvent] = []
            if let notice = backgroundTasks.read(line: line), !stopRequested {
                taskNotices.append(StreamEvent(
                    kind: .userMessage(text: notice), isSystemNotice: true,
                    sentIntoTurn: ClaudeBackgroundTasks.noticeGoesIntoRunningTurn(after: events),
                    belongsToAnswer: true))
            }
            if resultHeldForBackgroundTasks,
               awaitedBackgroundTasks != backgroundTasks.running {
                awaitedBackgroundTasks = backgroundTasks.running
                stoppingBackgroundTasks.formIntersection(Set(awaitedBackgroundTasks.map(\.id)))
            }
            // claude took a message steered into the turn: printed back the
            // moment it reads it, with the step that carries it or as its
            // own turn starts — which is where its row belongs.
            if claudeInput != nil, let taken = claudeSteers.read(line: line) {
                drawSteerTaken(text: taken.words, opensTurn: taken.opensTurn)
            }
            // A `!` command's output: drawn, then handed to claude as its
            // terminal hands it over.
            if claudeShell?.awaitingOutput == true,
               let row = ClaudeShellCommand.userRowText(line: line),
               let output = ClaudeShellCommand.output(fromRow: row) {
                handOverShellOutput(output)
            }
            endHeldTurnIfOwedNothing()
            parsed = AgentEventParser.parse(line: line, fallbackCwd: cwd,
                                            includeThinking: keepsThoughts) + taskNotices
            // Claude retrying an API call by itself — ten attempts over
            // minutes when the connection is down, with nothing else on
            // stdout meanwhile. Held like codex's and kimi's notices.
            if let notice = AgentEventParser.retryNotice(line: line) {
                retryNotice = notice
            } else if !parsed.isEmpty {
                retryNotice = ""
            }
        default:
            // No parser for this agent: `runOnce` spawns it no child, so
            // there is nothing of its own to read here.
            parsed = []
        }
        apply(parsed)
    }

    /// A skill this turn's message was drawn as loading was not loaded
    /// after all (`names` nil: every one it names). The row stops naming
    /// it — a live row's `loadedSkills` is what the chip takes for "in the
    /// conversation" (`SkillEvidenceReader`), so left standing the skill
    /// read as loaded and was never sent again — and the folder's skills
    /// are read again, its subfolders searched afresh for the skill
    /// (`SkillCatalog.noteLoadFailed`), so what the chip offers next is
    /// what is there. The row keeps its identity: nothing the user has
    /// open on it moves.
    private func retractSkillLoads(_ names: [String]?) {
        guard let index = events.lastIndex(where: Self.isMessageRow) else { return }
        let event = events[index]
        let drop = names.map { Set($0.map { $0.lowercased() }) }
        let kept = event.loadedSkills.filter { name in
            guard let drop else { return false }
            return !drop.contains(name.lowercased())
        }
        guard kept.count != event.loadedSkills.count else { return }
        let gone = event.loadedSkills.filter { name in !kept.contains(name) }
        events[index] = event.replacingLoadedSkills(kept)
        SkillCatalog.shared.noteLoadFailed(gone, agent: agentKey, folder: cwd)
    }

    /// A message the user sent — not a notice in the user column, not
    /// words sent into a turn already running.
    private static func isMessageRow(_ event: StreamEvent) -> Bool {
        if case .userMessage = event.kind { return !event.isSystemNotice && !event.sentIntoTurn }
        return false
    }

    /// The events of the attempt a `result` (the newest event) ends:
    /// everything after the turn's newest message row, the result left out.
    /// Without that row (trimmed from the buffer's front by a long attempt)
    /// it is the whole buffer — output, which never reads as an attempt in
    /// which nothing ran.
    private func attemptBeforeResult() -> ArraySlice<StreamEvent> {
        guard !events.isEmpty else { return [] }
        let end = events.index(before: events.endIndex)
        let start = events[..<end].lastIndex(where: Self.isMessageRow).map { $0 + 1 }
            ?? events.startIndex
        return events[start..<end]
    }

    /// Append a turn's events and act on what each says — the ONE path
    /// for every front end: a parsed line of a headless child's stdout,
    /// and the events a JSON-RPC driver emits (`AgentRPCHost.emit`), so
    /// the clock, the context chip, a turn's segments and the session's
    /// discovery treat them alike.
    private func apply(_ parsed: [StreamEvent]) {
        for event in parsed {
            // Any real output means the summarising is over, whether or
            // not the finishing record was seen.
            if compacting { compacting = false }
            // A renderable event after this turn's own segment ended
            // means the child began a NEW segment (a background task
            // completed and re-invoked the model) — the turn is live
            // again. Never after Stop: a dying child's last events
            // must not resurrect a turn the user ended.
            // Each skill a claude turn loads ahead of the text answers
            // with an empty `result` (no model call, `num_turns` 0) before
            // the turn's own. Those are bookkeeping: appended, one would
            // end the visible turn before it began.
            if pendingSkillLoadResults > 0, case .result(_, _, let turns, _, _) = event.kind, turns == 0 {
                pendingSkillLoadResults -= 1
                continue
            }
            // So does each row of a `!` command handed over without a model
            // request; the last ends a `!` claude does not answer, its input
            // closed so claude exits and the turn ends with it.
            if pendingShellResults > 0, case .result(_, _, let turns, _, _) = event.kind, turns == 0 {
                pendingShellResults -= 1
                claudeWorking = false
                refreshSteerable()
                if pendingShellResults == 0, claudeShell?.quiet == true {
                    closeClaudeInput()
                }
                continue
            }
            if !status.isRunning, !stopRequested,
               let p = process, p.isRunning {
                if case .result = event.kind {} else { reopenTurnSegment() }
            }
            // claude works on a turn from its `system/init` to its
            // `result`, the window in which a message steered into it is
            // taken at the next step (`ClaudeSteer`) — but not from a `!`
            // command's handshake: claude works on that only once its rows
            // are handed over for an answer (`handOverShellOutput`). Flipped
            // here, a message held while the command ran was offered Steer,
            // and the result of the turn it opened closed the input before
            // the command's output went in.
            if isClaude, claudeInput != nil {
                switch event.kind {
                case .systemInit: claudeWorking = claudeShell?.awaitingOutput != true; refreshSteerable()
                case .result: claudeWorking = false; refreshSteerable()
                default: break
                }
            }
            // A tool's result going back to the model, or a new turn
            // starting: either request carries every task notification
            // claude has queued (`ClaudeBackgroundTasks`).
            if isClaude {
                switch event.kind {
                case .toolResult, .systemInit: backgroundTasks.noteRequestStarted()
                default: break
                }
            }
            // A kimi tool's ending, read off its record before stdout
            // printed the row: the row is appended as the record has it.
            if isKimi, case .toolResult(let id, _, _) = event.kind,
               let ending = kimiToolEndings.removeValue(forKey: id),
               let kind = ending.correcting(event.kind) {
                events.append(StreamEvent(copying: event, kind: kind))
            } else {
                events.append(event)
            }
            // A codex command's turn opens on no message of the user's: its
            // first notice ("Code review started: …") stands for the opening
            // row, which a mid-turn reload cuts its read at, as the reader
            // draws the same notice from codex's record.
            if commandTurn, runningTurnOpening == nil, event.isSystemNotice,
               case .userMessage(let text) = event.kind {
                runningTurnOpening = event.id
                inFlightUserText = text
            }
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
                // Claude refused the message as too long before sending
                // anything, and sent once more it compacts first
                // (`AgentEventParser.resendsTooLongRefusal`): the turn goes
                // on — no clock stamp, no verdict, no end — and `runOnce`
                // sends the message again once this child has exited.
                // Claude's notice of the refusal stays: the transcript has
                // it too.
                if isClaude, !tooLongResendPending,
                   AgentEventParser.resendsTooLongRefusal(
                       event, attempt: attemptBeforeResult(),
                       resumedSession: turnResumedSession,
                       compactionTried: attemptTriedCompaction,
                       alreadyResent: tooLongResendUsed,
                       stopped: stopRequested) {
                    tooLongResendPending = true
                    // The refused attempt ran nothing: its input closes so
                    // its child exits, and the re-send opens its own. A
                    // message steered into it was never taken.
                    closeClaudeInput()
                    returnUntakenSteers()
                    reapRefusedChildIfItLingers()
                    continue
                }
                // The agent's own verdict on the turn: said once — claude
                // already wrote an API's refusal as a message of its own —
                // and never read off a turn the user stopped: Stop is Stop.
                let failure = stopRequested ? nil : event.turnFailure.map {
                    $0.isEmpty ? AgentAskingMode.wordlessFailureMessage(agentName: agentDisplayName) : $0
                }
                if let failure, status.isRunning,
                   !AgentEventParser.failureIsShown(failure, before: events.dropLast()) {
                    events.append(StreamEvent(kind: .error(message: failure)))
                }
                // A background task the turn started is still running, or
                // its notification has not reached the model: claude keeps
                // the run going and reports the task in a turn of its own,
                // so this answer is not the turn's end. The turn stays
                // running — the clock goes on counting, Stop stays, Send
                // waits, the transcript names the tasks — and ends at the
                // report's `result`, or when claude exits without one.
                // So is an answer given while a message steered into the
                // turn is still unread: claude answers it in a turn of its
                // own right after this one, in the same process.
                if isClaude, status.isRunning, !stopRequested,
                   !backgroundTasks.resultEndsTurn || (claudeInput != nil && claudeSteers.pending) {
                    if let failure { heldTurnFailure = failure }
                    resultHeldForBackgroundTasks = true
                    awaitedBackgroundTasks = backgroundTasks.running
                    continue
                }
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
                endTurnSegment(failure: failure)
                // The turn is over: claude's input closes, and claude exits
                // once it has nothing left to do.
                closeClaudeInput()
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

    // MARK: A turn over the agent's own protocol (its front end)

    /// The driver for a turn through the agent's own front end, or nil when
    /// the installed CLI cannot run it. Each agent's driver plugs in here.
    private func makeRPCTurn(_ driver: AgentTurnDriver, text: String,
                             options: AgentLaunchOptions,
                             images: [AgentImage],
                             textWithoutSubfolderSkills: String,
                             command: CodexCommandTurn? = nil) -> AgentRPCTurn? {
        switch driver {
        case .kimiAcp:
            // Effort rides the environment, as on kimi's headless turn.
            // Kimi's own configured mode, read as the file says it now: what
            // a resumed session on Default runs in, and what a plan approved
            // "then Default" continues in — in any turn, since kimi reviews
            // a plan in whatever mode the model drew it up.
            return KimiAcpTurn(
                text: text, options: options,
                environment: KimiCapabilities.environmentOverlay(agentKey: agentKey,
                                                                 effort: options.effort),
                agentName: agentDisplayName,
                clientVersion: Self.appVersion,
                defaultPermissionMode: KimiCatalog.readDefaultPermissionMode())
        case .codexAppServer:
            // What the turn runs as, stated in full: a value the chip leaves
            // on Default is resolved the way `codex exec` resolves it, since
            // the thread keeps whatever an earlier turn named — codex's own
            // answer for the folder once the turn has it (`defaults`), and
            // SipAI's reading of the config where codex states none: the
            // folder's configured model, else codex's own default. The
            // speed is the send's own pin, else the folder's configured
            // tier.
            let catalog = CodexCatalog.shared
            let folder = cwd.path
            let model = options.model, effort = options.effort
            let tier = options.codexServiceTierOverride
            let subfolderSkills = options.chatOnly ? [] : options.skillTriggers.filter { $0.skillsFolder != nil }
            return CodexAppServerTurn(
                text: text, options: options, command: command,
                extraSkillRoots: SkillTrigger.codexExtraRoots(subfolderSkills),
                subfolderSkills: subfolderSkills.map(\.name),
                textWithoutSubfolderSkills: textWithoutSubfolderSkills,
                settings: { defaults in
                    CodexAppServer.turnSettings(
                        model: model, effort: effort,
                        folderModel: catalog.turnDefaultModel(forFolder: folder),
                        folderEffort: catalog.configuredEffort(forFolder: folder),
                        modelDefaultEffort: { catalog.modelDefaultEffort(forModel: $0) },
                        serviceTier: tier, defaults: defaults)
                },
                agentName: agentDisplayName,
                clientVersion: Self.appVersion)
        default:
            return nil
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Hand a kimi session back from ACP's runtime if a turn left it bound
    /// there (`KimiRuntimeBinding.restore`), and clear its journal entry once
    /// nothing is owed. Off the main actor: the session's record is read.
    private func restoreKimiBinding(sessionId id: String) async {
        let restored = await Task.detached(priority: .userInitiated) { () -> Bool? in
            guard let dir = KimiSessionScanner.sessionDirectory(forId: id) else { return nil }
            return KimiRuntimeBinding.restore(sessionDir: dir)
        }.value
        // A session that is gone owes nothing either.
        if restored != false { onKimiBindingJournal?(id, false) }
    }

    /// An ACP Plan turn leaves its session IN plan mode, and kimi replays
    /// it on every later run: a headless turn there refuses every edit
    /// under a chip that says Never Ask (`KimiAcp.planModeOn`). So
    /// before one, kimi itself is asked to leave plan mode over a short
    /// ACP conversation of its own (`KimiAcpTurn.leavePlanMode`), drained
    /// by the same loop as every child, and the binding that conversation
    /// leaves is handed back. A session not in plan mode costs a read.
    private func leaveKimiPlanModeIfLeftOn(sessionId id: String, binary: String) async {
        let leftOn = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let dir = KimiSessionScanner.sessionDirectory(forId: id) else { return false }
            return KimiAcp.planModeLeftOn(wire: KimiSessionScanner.wireFile(inSessionDir: dir))
        }.value
        guard leftOn else { return }
        // The conversation binds the session to ACP's runtime: journalled
        // first, as an Ask turn is.
        onKimiBindingJournal?(id, true)
        let left = await runSideConversation(binary: binary, arguments: KimiAcp.arguments,
                                             label: "sipai.kimi.planmode") { peer in
            await KimiAcpTurn.leavePlanMode(
                peer: peer, sessionId: id, cwd: KimiWebTurn.resolvedPath(self.cwd),
                clientVersion: Self.appVersion)
        }
        await restoreKimiBinding(sessionId: id)
        if left != true {
            NSLog("%@", "SipAI: kimi did not take session \(id) out of plan mode; "
                  + "this headless turn runs in it.")
        }
    }

    /// A codex Plan turn leaves its THREAD in plan mode, and codex runs
    /// every later turn under the plan instructions — `codex exec`'s
    /// included, its questions answered with nothing
    /// (`CodexAppServer.planModeLeftOn`). So before a headless turn on such
    /// a thread, codex itself is asked to put it back in Default mode over a
    /// short app-server conversation of its own (`CodexAppServerTurn
    /// .leavePlanMode`). Ask turns state their mode every time. A thread
    /// not in plan mode costs a read.
    private func leaveCodexPlanModeIfLeftOn(sessionId id: String, binary: String) async {
        let known = sessionFileURL
        let leftOn = await Task.detached(priority: .userInitiated) { () -> (on: Bool, model: String?) in
            guard let rollout = known ?? Self.locateSessionFile(id: id, agentKey: "codex")
            else { return (false, nil) }
            return CodexAppServer.planModeLeftOn(rollout: rollout)
        }.value
        guard leftOn.on, let model = leftOn.model, !model.isEmpty else { return }
        let left = await runSideConversation(binary: binary, arguments: CodexAppServer.arguments,
                                             label: "sipai.codex.planmode") { peer in
            await CodexAppServerTurn.leavePlanMode(
                peer: peer, threadId: id,
                cwd: CodexConfigRead.physicalPath(self.cwd.path),
                model: model, clientVersion: Self.appVersion)
        }
        if left != true {
            NSLog("%@", "SipAI: codex did not take thread \(id) out of plan mode; "
                  + "this headless turn runs in it.")
        }
    }

    /// A short conversation with a fresh child of an agent's protocol
    /// server, outside any turn: spawned, drained by the one loop, and
    /// ended as a turn's child is — its stdin closed once `body` is done,
    /// and stopped if it has not exited a few seconds later. nil when the
    /// child could not be started; otherwise `body`'s verdict.
    private func runSideConversation(binary: String, arguments: [String], label: String,
                                     _ body: (JSONRPCLinePeer) async -> Bool) async -> Bool? {
        await ShellEnvironment.prepare()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = arguments
        p.currentDirectoryURL = cwd
        p.environment = Self.buildEnvironment()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            NSLog("%@", "SipAI: could not start \(label): \(error.localizedDescription)")
            return nil
        }
        let writeFD = dup(stdinPipe.fileHandleForWriting.fileDescriptor)
        try? stdinPipe.fileHandleForWriting.close()
        let peer = JSONRPCLinePeer(label: label, writing: writeFD,
                                   deliver: JSONRPCLinePeer.deliverOnMainQueue)
        // The reader keeps the descriptor OPEN until it has seen the end of
        // the stream: this function returns as soon as the child is gone (or
        // has been told to go), which can be a moment before the reader
        // finds that out. Closed under an armed read source, the
        // descriptor's NUMBER goes to whatever is opened next — the stdout
        // of the turn about to be spawned — and the stale source would then
        // read that child's output away from its own reader.
        let readHandle = stdoutPipe.fileHandleForReading
        let fd = readHandle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        let source = Self.makeDrainingLineSource(
            fd: fd, label: "\(label).\(UUID().uuidString)", owner: self,
            onLine: { line in peer.receive(line: line) },
            onEnd: { _ in
                peer.receiveEOF()
                withExtendedLifetime(readHandle) {}
            })
        source.resume()

        let verdict = await body(peer)
        // Done with it: its stdin closes and it exits on its own (measured
        // in tens of milliseconds); one that has not is stopped.
        peer.finishWriting()
        let deadline = Date().addingTimeInterval(AgentRPCTurnDefaults.exitGrace)
        while p.isRunning, Date() < deadline {
            await Self.pause(0.05)
        }
        if p.isRunning { p.terminate() }
        peer.close(reason: "\(label) done")
        return verdict
    }

    /// A pause that holds in a CANCELLED task too. `Task.sleep` returns at
    /// once there — and Stop cancels the task a side conversation runs in —
    /// so a loop waiting on a child with it would spin on the main actor
    /// for the whole of its bound.
    private static func pause(_ seconds: TimeInterval) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                cont.resume()
            }
        }
    }

    /// Run one turn through the agent's own JSON-RPC protocol. The child is
    /// spawned, drained and waited on exactly as a headless child is — a
    /// turn still ends when the CHILD dies (`finalizeTurn` from the join,
    /// or a bound) — with two differences: its stdin is a pipe that stays
    /// open for the conversation, and its stdout is read by a peer
    /// (`JSONRPCLinePeer`) rather than parsed as events. The driver speaks
    /// the protocol on the main actor; when it is done with the turn the
    /// child's stdin closes, and a child that has not exited a few seconds
    /// later is stopped.
    private func runRPCTurn(_ turn: AgentRPCTurn, binary: String) async {
        let token = runToken
        func turnStillOurs() -> Bool {
            token == runToken && !stopRequested && status.isRunning && !Task.isCancelled
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = turn.arguments
        p.currentDirectoryURL = cwd
        // The conversation's own channel. Passed as the Pipe itself, so
        // Foundation closes the parent's copy of the read end and a write
        // to a child that has gone fails instead of blocking.
        let stdinPipe = Pipe()
        p.standardInput = stdinPipe

        await ShellEnvironment.prepare()
        guard turnStillOurs() else {
            if status.isRunning, token == runToken {
                finalizeTurn(token: token, exitCode: -1, errorMessage: nil)
            }
            return
        }
        var env = Self.buildEnvironment()
        for (k, v) in turn.environment { env[k] = v }
        p.environment = env

        let stdoutSource = turn.stdoutIsTerminal
            ? Self.makeChildStdoutSource() : Self.makeChildPipeSource()
        let stderrPipe = Pipe()
        p.standardOutput = stdoutSource.handleForChild
        p.standardError = stderrPipe

        // A draft's turn gets a uuid of its own, as a headless first turn
        // does: its cards carry it beside the session id, so the bridge's
        // one ownership rule finds them for every caller — the notification
        // hook too, which judges a card by the DRAFT while the pane has not
        // yet flipped to the session the agent just named.
        if sessionId?.isEmpty ?? true, taskUuid == nil {
            taskUuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }

        // Our child is about to become the session's writer.
        tailer?.suspend()

        // An ACP turn binds a kimi session to ACP's runtime the moment it
        // opens it. Journalled before the child can, so a crash mid-turn
        // still knows to hand it back (a new session is journalled when
        // kimi names it, `adoptRPCSession`).
        if isKimi, let id = sessionId, !id.isEmpty { onKimiBindingJournal?(id, true) }

        // Installed before run(): see `runOnce`.
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
            if let url = sessionFileURL {
                tailer?.resume(atOffset: Self.currentSize(of: url))
            }
            return
        }
        stdoutSource.afterSpawn()
        process = p

        // The peer owns a descriptor of its own for the child's stdin, and
        // closes it exactly once; the pipe's handle is let go now.
        let writeFD = dup(stdinPipe.fileHandleForWriting.fileDescriptor)
        try? stdinPipe.fileHandleForWriting.close()
        let peer = JSONRPCLinePeer(label: "sipai.rpc.\(agentKey)", writing: writeFD,
                                   deliver: JSONRPCLinePeer.deliverOnMainQueue)
        // A line that is not JSON-RPC is the child talking about itself —
        // kept with its stderr, where a failed turn's words are read.
        peer.onUnparsed = { [weak self] line in self?.appendStderrLine(line) }
        rpcTurn = (token, peer, turn)
        let host = RPCHost(runner: self, token: token)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.readRPCStdout(handle: stdoutSource.readHandle, peer: peer)
                await self?.noteReaderFinished(.stdout, token: token)
            }
            group.addTask { [weak self] in
                await self?.readStderr(handle: stderrPipe.fileHandleForReading)
                await self?.noteReaderFinished(.stderr, token: token)
            }
            group.addTask { [weak self] in
                await self?.waitForExit(process: p, waiter: exitWaiter)
                await self?.noteReaderFinished(.childExit, token: token)
            }
            group.addTask { @MainActor [weak self] in
                await turn.run(peer: peer, host: host)
                // The protocol is done with the turn: the child's stdin
                // closes, and a child that reads until EOF exits. One that
                // has not a few seconds later is stopped — a turn ends
                // when the child dies, and this one has nothing left to do.
                //
                // Done, that is, only while the conversation is still OPEN.
                // A driver also returns when the conversation ends under it
                // — the child gone mid-turn — and leaves that to the runner
                // to say: counted as done, such a turn would end with no row
                // at all.
                if !peer.isClosed { self?.noteRPCTurnCompleted(token: token) }
                peer.finishWriting()
                // The driver says how long its child needs from here: one
                // with work of its own to end first (kimi stopping its
                // background tasks) must not be stopped mid-way.
                self?.boundRPCChildExit(token: token, grace: turn.exitGrace)
            }
            await group.waitForAll()
        }

        // The child is gone: the session goes back to kimi's own runtime
        // before the turn is over, so whatever runs it next — this app's
        // next turn, kimi in a terminal — has its tools.
        if isKimi, let id = sessionId, !id.isEmpty {
            await restoreKimiBinding(sessionId: id)
        }

        var exitCode = Self.exitCodeIfExited(p)
        var errText: String? = nil
        var errorRowShown = false
        switch AgentRPCTurnEnd.outcome(
            protocolDone: rpcTurnCompleted, stopped: stopRequested || Task.isCancelled,
            driverFailure: rpcTurnFailure,
            childReport: {
                let name = AgentManager.registry
                    .first { $0.key == agentKey }?.name ?? agentKey
                return stderrTail.isEmpty
                    ? String(localized: "\(name) exited with code \(exitCode).",
                             comment: "Fallback exit-code message when stderr is empty; placeholder is the agent name")
                    : stderrTail
            }) {
        case .ended:
            break
        case .failedAsSaid(let words):
            errText = words
            errorRowShown = true
        case .cutShort(let words):
            errText = words
        }
        // A turn that ended on an error row is a failed turn, and a
        // scheduled run reads only the exit code: a child that closed
        // cleanly on a failure it reported, or that left quietly
        // mid-protocol, must not read as a run that succeeded.
        if errText != nil, exitCode == 0 { exitCode = -1 }
        finalizeTurn(token: token, exitCode: exitCode, errorMessage: errText,
                     errorRowShown: errorRowShown)
    }

    private func noteRPCTurnCompleted(token: Int) {
        guard token == runToken else { return }
        rpcTurnCompleted = true
    }

    /// A child has `grace` to exit once its protocol is done with the turn
    /// and its stdin has closed (`AgentRPCTurn.exitGrace`); one still there
    /// after that is stopped.
    private func boundRPCChildExit(token: Int, grace: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard let self, self.runToken == token,
                  let p = self.process, p.isRunning else { return }
            self.killChild(reason: "its protocol ended the turn")
        }
    }

    /// The runner's side of a driver's turn. Every call is checked against
    /// the turn's token: a superseded turn emits nothing, and a card it
    /// asks for — or one asked for after Stop — is answered cancelled at
    /// once, never drawn.
    @MainActor
    private final class RPCHost: AgentRPCHost {
        private weak var runner: AgentRunner?
        private let token: Int

        init(runner: AgentRunner, token: Int) {
            self.runner = runner
            self.token = token
        }

        private var live: AgentRunner? {
            guard let runner, runner.runToken == token else { return nil }
            return runner
        }

        var cwd: URL { runner?.cwd ?? URL(fileURLWithPath: NSHomeDirectory()) }
        var sessionId: String? { runner?.sessionId }
        var turnIsLive: Bool {
            guard let runner = live else { return false }
            return !runner.stopRequested && runner.status.isRunning
        }

        func adoptSession(id: String) {
            guard let runner = live else { return }
            runner.adoptRPCSession(id: id)
        }

        func emit(_ events: [StreamEvent]) {
            guard let runner = live, !events.isEmpty else { return }
            runner.apply(events)
        }

        func setNotice(_ text: String?) {
            guard let runner = live else { return }
            runner.retryNotice = text ?? ""
        }

        func noteTurnFailed(_ message: String) {
            guard let runner = live else { return }
            runner.rpcTurnFailure = message
        }

        func noteSpeed(asked: String, served: Bool) {
            guard let runner = live else { return }
            runner.setCodexSpeedReport(CodexSpeedReport(asked: CodexSpeed.normalized(asked),
                                                        dropped: !served))
        }

        func setAwaitedBackgroundTasks(_ tasks: [BackgroundTaskEntry]) {
            guard let runner = live else { return }
            // Stop ends the work with the turn: nothing is waited on.
            let shown = runner.stopRequested || !runner.status.isRunning ? [] : tasks
            if runner.awaitedBackgroundTasks != shown { runner.awaitedBackgroundTasks = shown }
        }

        func noteContextUsage(tokens: Int, window: Int?) {
            guard let runner = live else { return }
            if tokens > 0, tokens != runner.lastContextTokens { runner.lastContextTokens = tokens }
            if let window, window > 0, window != runner.lastContextWindow {
                runner.lastContextWindow = window
            }
        }

        @discardableResult
        func present(_ card: AgentCardRequest) -> String? {
            guard let runner = live, !runner.stopRequested, let bridge = runner.bridge else {
                card.respond(.cancelled)
                return nil
            }
            let request = MCPApprovalRequest(
                agentKey: runner.agentKey,
                sessionId: runner.sessionId,
                taskUuid: runner.taskUuid,
                toolName: card.toolName,
                toolInput: card.toolInput,
                presentation: card.presentation,
                question: card.question,
                turnWaits: card.turnWaits,
                respond: card.respond)
            bridge.enqueue(request)
            return request.id
        }

        func withdraw(cardId: String) {
            if let unsent = runner?.bridge?.withdraw(requestId: cardId) {
                runner?.keepUnsentAnswers(unsent)
            }
        }

        func offerPlanFollowUp(_ plan: String) {
            guard let runner = live, !runner.stopRequested else { return }
            runner.planFollowUp = plan
        }

        func retractSkillLoads(_ names: [String]?) {
            guard let runner = live else { return }
            runner.retractSkillLoads(names)
        }

        func setSteerable(_ on: Bool) {
            guard let runner = live else { return }
            runner.rpcSteerable = on
            runner.refreshSteerable()
        }

        func steerTaken(text: String) {
            guard let runner = live else { return }
            runner.drawSteerTaken(text: text, opensTurn: false)
        }

        func setCompacting(_ on: Bool) {
            guard let runner = live else { return }
            let shown = on && !runner.stopRequested && runner.status.isRunning
            if runner.compacting != shown { runner.compacting = shown }
        }
    }

    /// A new session's id, named by its agent's own protocol before the
    /// first message is sent: adopted the way a discovered id is, and its
    /// transcript waited for — the protocol names the session before the
    /// file it writes exists.
    private func adoptRPCSession(id: String) {
        guard sessionId == nil, !id.isEmpty else { return }
        if isKimi { onKimiBindingJournal?(id, true) }
        adoptDiscoveredSession(id: id, fileURL: nil)
        // Taken up as a transcript found after the fact is: the tailer
        // started (and held while this child writes), the path announced.
        if let url = locateSessionFile(id: id) {
            adoptSessionFile(url, id: id)
        } else {
            awaitSessionFile(id: id)
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
    /// "Sipping…" spinner holds until then, with kimi's retry line under
    /// it while kimi retries. Idle includes a turn kimi ended as failed,
    /// which ends here as failed, in kimi's words.
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

        func serverDidNotStart(_ why: String) {
            fail(String(localized: "\(agentDisplayName)'s local server did not start: \(why)",
                        comment: "Runner error when kimi web could not be started for a Chat only turn; placeholders are the agent label and the reason"))
        }
        var session: KimiWebServerCall.Session
        switch await KimiWebServerCall.Session.start(binary: binary, scratchDirectory: cwd) {
        case .failed(let why):
            serverDidNotStart(why)
            return
        case .started(let started):
            session = started
        }
        if token != runToken || Task.isCancelled {
            await session.shutdown()
            _ = stopped()
            return
        }

        let binding = KimiWebTurn.Binding.of(kimiVersion: AgentCLIUpdateMonitor.shared.installed["kimi"]?.text)
        let sid: String
        switch await KimiWebTurn.createSession(session, cwd: cwd, model: model, binding: binding) {
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
        let policyFile = KimiSessionScanner.sessionDirectory(forId: sid)
            .map { KimiToolPolicy.disabledFile(sessionDir: $0) }
        if binding == .atCreation {
            // A kimi that binds at creation applies a session's tool
            // policy when it OPENS the session, and a prompt's own list
            // not to that prompt's turn (measured: the list stored, every
            // tool still sent). So the session it just made and bound is
            // closed, its policy file written the way a resumed Chat only
            // turn writes it — journal first, restored by whichever
            // caller ends the turn — and a fresh server opens it for the
            // prompt.
            await session.shutdown()
            if stopped() { return }
            guard await prepareKimiToolPolicy(sessionId: sid) else {
                guard token == runToken else { return }
                finalizeTurn(token: token, exitCode: -1, errorMessage: "Chat only refused", errorRowShown: true)
                return
            }
            switch await KimiWebServerCall.Session.start(binary: binary, scratchDirectory: cwd) {
            case .failed(let why):
                serverDidNotStart(why)
                return
            case .started(let started):
                session = started
            }
            if token != runToken || Task.isCancelled {
                await session.shutdown()
                _ = stopped()
                return
            }
        } else {
            // The server writes the policy file for this prompt; what was
            // there before is nothing, and that is what goes back —
            // through the same first-caller-wins slot the `--prompt` path
            // uses, so the bounded finalize a Stop arms (`cancel()`)
            // restores it too when the server stops answering.
            onKimiToolPolicyJournal?(sid, .absent)
            if let policyFile {
                pendingKimiRestore = (sid, policyFile, .absent)
            }
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
                                        binding: binding, images: images) {
        case .failure(let failure):
            await session.shutdown()
            restore()
            fail(Self.kimiWebFailureText(failure, agent: agentDisplayName))
            return
        case .success(let id):
            promptId = id
        }

        // While kimi works, the record is read for one thing only: its
        // retries of a model request it gets no answer to, the line an
        // ACP turn shows — up to ten attempts over minutes, and nothing
        // else from kimi meanwhile. The answer itself is read whole
        // below, once the session is idle.
        let retries = watchKimiRetries(sessionId: sid, token: token)
        let idle = await KimiWebTurn.waitIdle(session, sessionId: sid) { Task.isCancelled }
        retries.cancel()
        if idle != nil {
            await session.shutdown()
        } else {
            // Stop (the task was cancelled) or the server stopped
            // answering: the action route, then the shutdown that
            // certainly ends it.
            await KimiWebTurn.abort(session, sessionId: sid, promptId: promptId)
        }
        restore()
        guard token == runToken else { return }
        // Idle is not answered: a turn kimi ended as failed is idle too,
        // and says why only in its record.
        var failure: String? = nil
        if let idle {
            let wordless = AgentAskingMode.wordlessFailureMessage(agentName: agentDisplayName)
            var items: [AgentSessionHistoryItem] = []
            if let wire = sessionFileURL ?? KimiSessionScanner.sessionDirectory(forId: sid)
                .map({ KimiSessionScanner.wireFile(inSessionDir: $0) }) {
                // The answer, off the wire: the turn's rows after our own
                // prompt.
                // Thoughts included: this path only ever runs a Chat only
                // turn, and the wire is the only place kimi records them.
                items = await Task.detached(priority: .utility) {
                    KimiSessionScanner.readHistory(of: wire, maxTurns: 1,
                                                   includeThinking: true,
                                                   wordlessFailure: wordless)
                }.value
                guard token == runToken else { return }
            }
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
                case .error:
                    // The turn failed: `fail` below says it, and ends the
                    // turn as failed — what a scheduled run records.
                    break
                case .compaction, .interrupted, .shellOutput:
                    // None is a row this runner writes: a compaction
                    // row comes off the parsers on the live feeds and
                    // off the reader on reopen (a first prompt cannot
                    // compact anyway), the interrupted marker is
                    // derived at load time, and this turn runs no `!`.
                    break
                }
            }
            trimLiveEventsIfNeeded()
            failure = KimiWebTurn.failure(in: items, lastTurnReason: idle.lastTurnReason,
                                          wordless: wordless)
        }
        if let failure {
            fail(failure)
        } else if idle != nil {
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

    /// A Chat only server turn's retry line, off kimi's record while the
    /// turn waits on the server: polled at the server's own pace, through
    /// the rule an ACP turn's record is read by (`KimiSessionScanner
    /// .RetryWatch`). The caller cancels it when the wait ends; the turn's
    /// end clears the line.
    private func watchKimiRetries(sessionId sid: String, token: Int) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            var wire: URL? = nil
            var tail = KimiSessionScanner.RecordTail()
            var retry = KimiSessionScanner.RetryWatch()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(KimiWebTurn.pollInterval * 1_000_000_000))
                guard let self, token == self.runToken, !Task.isCancelled else { return }
                if wire == nil {
                    if let adopted = self.sessionFileURL {
                        wire = adopted
                    } else {
                        wire = await Task.detached(priority: .utility) {
                            KimiSessionScanner.sessionDirectory(forId: sid)
                                .map { KimiSessionScanner.wireFile(inSessionDir: $0) }
                        }.value
                    }
                }
                guard let url = wire else { continue }
                let from = tail.offset
                let data = await Task.detached(priority: .utility) {
                    KimiSessionScanner.RecordTail.read(url, from: from)
                }.value
                guard !data.isEmpty, !Task.isCancelled, token == self.runToken else { continue }
                for line in tail.lines(adding: data) { retry.feed(line: line) }
                // Set only on a change: every write re-renders the
                // transcript, and most reads bring none.
                let notice = retry.notice ?? ""
                if notice != self.retryNotice { self.retryNotice = notice }
            }
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
    /// `system.init` event takes through `applySubprocessSideEffects`. The
    /// alias is registered as there: a card filed under the draft's uuid
    /// then belongs to the session for every caller that knows only the id.
    ///
    /// A transcript found WITH the id is taken up as one found after the
    /// fact is (`adoptSessionFile`), tailer included — held while this
    /// turn's own child writes. Without one, a session born here is never
    /// watched: a turn run on it from a terminal lights no dot and holds no
    /// composer, and a second writer can be sent in beside it.
    private func adoptDiscoveredSession(id: String, fileURL: URL?) {
        guard sessionId == nil, !id.isEmpty else { return }
        sessionId = id
        if let tu = taskUuid {
            bridge?.registerAlias(taskUuid: tu, sessionId: id)
        }
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            adoptSessionFile(fileURL, id: id)
        } else {
            sessionFileURL = fileURL
            onSessionIdDiscovered?(id, fileURL)
        }
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
        // A turn that starts or ends changes whether a card on screen
        // pauses the clock, and what a message sent now may do.
        syncUserWait()
        refreshSteerable()
    }

    // MARK: - Helpers

    /// The setting claude's wait for a background task sits behind, as
    /// claude last cached it in `~/.claude.json`
    /// (`ClaudePrintMode.cachedShellWait`). Read off the main actor: the
    /// file holds claude's whole cached state, and a send must not wait
    /// on it there.
    nonisolated static func cachedClaudeShellWait() async -> Bool? {
        await Task.detached(priority: .userInitiated) {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude.json")
            return ClaudePrintMode.cachedShellWait(claudeJSON: try? Data(contentsOf: url))
        }.value
    }

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

    /// A plain pipe for a child's stdout, for a protocol whose agent was
    /// measured to write each line out as it goes — a terminal would only
    /// add carriage returns to it.
    nonisolated static func makeChildPipeSource() -> ChildStdoutSource {
        let pipe = Pipe()
        return ChildStdoutSource(
            handleForChild: pipe.fileHandleForWriting,
            readHandle: pipe.fileHandleForReading,
            slaveFDToClose: -1,
            childHandleNeedsClose: true
        )
    }

    /// Current size in bytes of a session file's text, or 0 if it can't
    /// be read. Used to seed tailer offsets at "EOF-equivalent" — for a
    /// compressed codex rollout, the text it decodes to: its watcher
    /// follows the plain file codex unpacks it into (`startTailer`),
    /// which starts as exactly that text.
    fileprivate static func currentSize(of url: URL) -> UInt64 {
        AgentSessionScanner.contentSize(of: url) ?? 0
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
        // A compressed rollout is never written again: codex unpacks it to
        // the plain name the moment it loads the thread, and goes on there
        // — so that is the file to watch, from the text the compressed one
        // holds (`currentSize`).
        let compressed = agentKey == "codex" && SessionFileCompression.isCompressed(url)
        let watched = compressed ? SessionFileCompression.unpacked(url) : url
        let format: AgentSessionTailer.Format
        switch agentKey {
        case "codex":
            // The writer lock is named for the thread; the session id IS
            // the thread id, and so is the rollout file name's tail.
            let threadId = sessionId.flatMap { $0.isEmpty ? nil : $0 }
                ?? Self.rolloutThreadId(watched)
            format = .codex(threadId: threadId,
                            sessionRoot: CodexSessionScanner.sessionRoot)
        case "kimi":
            // The folder a live kimi process reports is a real path, as
            // is the one kimi records for the session.
            format = .kimi(workDir: KimiWebTurn.resolvedPath(cwd))
        case "claude_code":
            format = .claude
        default:
            // No reader for this agent's transcript: nothing to watch.
            return
        }
        let t = AgentSessionTailer(
            fileURL: watched,
            fallbackCwd: cwd,
            format: format,
            wordlessFailure: AgentAskingMode.wordlessFailureMessage(agentName: agentDisplayName),
            openRetry: compressed ? .seconds(3) : .milliseconds(500),
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
        let name = SessionFileCompression.unpacked(url).deletingPathExtension().lastPathComponent
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
    /// in the user column opens none, nor do words sent into a turn
    /// already running (a message steered in, an answer).
    private static func opensTurn(_ event: StreamEvent) -> Bool {
        if case .userMessage = event.kind { return !event.isSystemNotice && !event.sentIntoTurn }
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
        case "claude_code": return locateSessionFile(id: id)
        default:      return nil
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
