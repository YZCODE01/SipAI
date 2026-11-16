// AgentSessionView.swift
// Center-column viewer + sender for a Claude Code agent session. Renders
// historical JSONL turns at the top and then observes a per-session
// AgentRunner whose live events (user message, assistant text, tool_use,
// tool_result, system init, result, error) stream in below. A bottom
// input card dispatches sends to the runner; a Stop button cancels.
//
// Rendering is Claude-Desktop-like rather than CLI-like: tool activity
// collapses into compact chips that fold their own result away and
// expand on click, and the turn's session/cost plumbing stays out of the
// conversation entirely — `system init` and `result` render nothing here,
// because the composer strip already carries the turn clock and the
// context-token count.

import SwiftUI
import Combine

struct AgentSessionView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var agents: AgentManager
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var mcpBridge: MCPBridge
    @EnvironmentObject var notesManager: NotesManager
    @Environment(\.sipFontScale) private var fontScale
    /// Observed for ONE value: the codex window `resolvedContextWindow`
    /// hands the composer's chip, which moves when the user changes
    /// `model_context_window` from Settings → Help. The catalog
    /// publishes on a file fingerprint change — never per event — so
    /// this costs a column re-render only when codex's config or cache
    /// actually moved. (This view still does not observe the runner.)
    @ObservedObject private var codexCatalog = CodexCatalog.shared

    @State private var historicalItems: [AgentSessionHistoryItem] = []
    @State private var isLoading: Bool = false

    /// Parsed history per session id — what makes clicking BETWEEN
    /// sessions feel instant: a revisit renders synchronously from
    /// here (no async load, warm markdown cache) and skips the disk
    /// read entirely when the file is unchanged.
    ///
    /// Owned by `AgentManager`, NOT by this view. The center pane
    /// tears this view down whenever the user opens a chat or a note
    /// (ContentView's router), so view-owned state made every session
    /// cold again after any detour out of the agent section — the
    /// second visit paid the same read as the first.
    private var historyCache: AgentHistoryCache { agents.historyCache }
    /// Bumped when a cache-hit refresh swaps newer content in place —
    /// tells RunnerStreamView to pull to the new end.
    @State private var repositionNonce = 0

    @State private var inputDraft: String = ""
    /// The identity whose text currently sits in `inputDraft` — the
    /// stash target on the NEXT switch. Same loaded-identity pattern
    /// as ChatView's `loadedChatSlug`: by the time
    /// onChange fires, `mode` already points at the INCOMING session,
    /// so stashing under it would file the outgoing text wrongly.
    ///
    /// The stash itself is `AppState.composerDrafts`, NOT view state:
    /// ContentView's router tears this whole view down on any detour to
    /// a chat or a note, so a view-owned dictionary lost every unsent
    /// prompt the moment the user looked at something else.
    @State private var loadedDraftKey: String? = nil
    /// The schedule set up on a new session (the composer's calendar
    /// control), owned here like `inputDraft` and kept with it on
    /// `AppState` under the same key: held in the composer, it would be
    /// gone after every detour while the text beside it came back. Only
    /// a new session's key ever holds one.
    @State private var scheduleDraft = ScheduleDraft()
    /// The chips the new session on screen starts with, from its place's
    /// memory (`newSessionStartingSetup`), under what was changed on it
    /// there (`NewSessionChipEdits`). Worked out once, when the new session
    /// opens, and kept with its id so no render reads another new
    /// session's.
    @State private var newSessionStart: NewSessionStart? = nil

    private struct NewSessionStart {
        let draftId: UUID
        let options: AgentLaunchOptions
    }
    /// Per-result expansion state. Shared by live and historical tool
    /// results — `eventId` / `item.id` serve the same role in both paths.
    @State private var expandedToolResults: Set<UUID> = []
    /// Which activity lines are open (a Chat only turn's, or any turn's in
    /// compact view), keyed by each line's first member's row id. A set of
    /// its own: a line that opens with a tool call would otherwise share
    /// its key with that call's chip, and opening one would open the other.
    @State private var expandedActivityLines: Set<UUID> = []

    /// The open session's turns that ran in Chat only, by the handle each
    /// user row carries (`ConfigManager.agentChatOnlyTurns`) — the turns
    /// a reopened transcript draws with their steps on one line.
    private var chatOnlyTurnHandles: Set<String> {
        guard case .existing(let id, _, _, _) = mode else { return [] }
        return config.agentChatOnlyTurns(for: id)
    }

    /// The sent message currently open for editing (row id), its draft
    /// text, and whether the fork is being written. Held on THIS view,
    /// not on the row: the transcript re-renders on every streamed event
    /// and swaps its whole item list on a history reload, so row-owned
    /// state would lose a half-typed edit to either. Same reasoning as
    /// `expandedToolResults`.
    @State private var editingRowId: UUID? = nil
    @State private var editDraft: String = ""
    @State private var branching: Bool = false
    /// Codex's review picker, opened by `/review` typed in the box. It
    /// belongs to the transcript it was opened over, like an edit.
    @State private var reviewPickerOpen = false
    /// Surfaced in the composer's existing alert slot — a branch that
    /// cannot be cut must say so, not fail quietly.
    @State private var branchError: String? = nil
    /// The failure alert's title when it is not the branch's — Send in the
    /// message editor fails as "Could not go back to this message".
    @State private var branchErrorTitle: String? = nil

    /// Composer selections (permission mode / model / effort). Seeded
    /// from config, saved when the user picks (`userPicks`) — never on a
    /// seed — and attached to every send. Survives the draft→existing
    /// transition because it lives here rather than on the runner.
    @State private var launchOptions: AgentLaunchOptions = AgentLaunchOptions()
    /// Files staged for the next message (`AgentAttachment`: a path the
    /// agent reads itself, or in Chat only the file loaded the chat
    /// page's way), owned here like `inputDraft` and stashed with it on
    /// `AppState` — the router tears this view down on every detour, and
    /// a staged file must survive one the way a half-typed message does.
    @State private var stagedAttachments: [AgentAttachment] = []
    /// Whether `attachmentNotice` was made under Chat only. A note is
    /// shown only in the mode it was made under: Chat only's rules (no
    /// folders, the text ceiling, a file cut short) are no other mode's,
    /// and the note comes back when the chip does.
    @State private var attachmentNoticeIsChatOnly = false
    /// A refusal or a truncation note from the last attach, shown above
    /// the composer until dismissed or the next attach.
    @State private var attachmentNotice: String? = nil

    /// How full the context window was, parsed from the session's own
    /// store when an existing session opens. Live events take
    /// precedence (see `displayContextTokens`).
    @State private var seededContextTokens: Int = 0

    /// The WINDOW that number sits in, when the agent RECORDS one
    /// beside it (codex stamps `model_context_window` on the rollout
    /// record; kimi's window is joined from its config by the model on
    /// the usage record). 0 = not recorded — claude among them, whose
    /// window is resolved from the MODEL instead
    /// (`ContextWindowResolver`). Two feeds with one authority each,
    /// exactly like the numbers they ride with.
    @State private var seededContextWindow: Int = 0

    /// The model that produced the seeded number. A window belongs to a
    /// model, so the number and the model that made it must travel
    /// together — a window resolved from some other model would state
    /// the wrong occupancy with no way to tell.
    @State private var seededContextModel: String? = nil

    /// Newest context-token total delivered by the runner's
    /// `$lastContextTokens` publisher. Mirrored into local @State (which
    /// the body reads) because this view deliberately does NOT observe
    /// the runner — only RunnerStreamView does, so streaming doesn't
    /// re-render the whole column. Carrying the VALUE through the
    /// publisher (instead of re-reading `runner.events` on a status
    /// flip) also sidesteps the actor-scheduling race where the
    /// turn-end re-render lands before the result event does.
    @State private var liveContextTokens: Int = 0

    /// Live mirror of the runner's `$lastContextWindow`, guarded and
    /// reset exactly like `liveContextTokens`.
    @State private var liveContextWindow: Int = 0

    /// The speed codex saved for this session's thread (`CodexKeptSpeed`):
    /// read from the rollout when the session opens and after a turn
    /// another process ran, and the runner's after each of ours. The
    /// composer greys its speed switches on it.
    @State private var codexSavedSpeed: CodexKeptSpeed.Saved = .unknown

    /// Live mirror of the model behind `liveContextTokens` — same
    /// pairing rule as `seededContextModel`, and guarded on its OWN
    /// mirror like every other live feed here.
    @State private var liveContextModel: String = ""

    /// What the runner last published about claude's own context
    /// windows. Held only to guard the write into config against
    /// `@Published`'s replay; nothing renders it.
    @State private var observedWindowsMirror: [String: Int] = [:]

    /// Latest finished turn's duration — two feeds, mirroring the token
    /// counter.
    ///
    /// `live` is the turn clock read at the `result` event of a turn
    /// THIS app ran, mirrored from the runner's `$lastTurnDuration`. It
    /// survives a detour with no extra bookkeeping: the @State dies
    /// when the router replaces the view, and @Published's
    /// replay-on-resubscribe puts it back from the (cached,
    /// per-session) runner on the next render.
    ///
    /// `seeded` is the cold read from the transcript, so a session this
    /// app has never driven still shows its last turn's time. Live wins
    /// when both exist; 0 / nil in both means no finished turn is known
    /// and the chip stays hidden.
    @State private var seededTurnDuration: Double = 0
    @State private var liveTurnDuration: Double? = nil

    /// Mirror of the runner's `$userWait` — the time the running turn
    /// has spent waiting on the user's cards, which the clock leaves
    /// out. Mirrored rather than read off the runner, because this view
    /// does not observe it; same delivery as the two above.
    @State private var livePause = TurnPause()

    /// Mirror of the runner's `$resolvedModel`, held for the same
    /// reason as the two above: the feed replays on every render, and
    /// the handler has to be able to tell a REPLAY from a new
    /// observation. Nothing renders this — it is the guard's memory.
    @State private var liveResolvedModel: AgentRunner.ResolvedModel? = nil
    /// Mirror of the runner's `fastModeReport`, guarded like the other
    /// three live feeds.
    @State private var liveFastModeReport = ClaudeFastModeReport()
    /// Mirror of the runner's `codexSpeedReport`, guarded the same way.
    @State private var liveCodexSpeedReport = CodexSpeedReport()
    /// The speed the transcript's newest main-loop call ran at — the
    /// fast switch's outcome before a turn of ours has said anything,
    /// read with the context seed and cached with it.
    @State private var seededCallSpeed: String? = nil

    /// Mirrors of the runner's external-turn state (this view
    /// deliberately does not observe the runner — see the token
    /// counter note). Start instant makes the turn clock tick for a
    /// turn another process is running; stoppable enables the
    /// composer's Stop for orphaned `-p` writers.
    @State private var externalTurnStart: Date? = nil
    @State private var externalStoppable: Bool = false

    /// One-click session-note generation (composer's note button).
    @State private var noteGenerating = false
    @State private var noteError: String? = nil

    /// Local slash-commands found by `reload()` when the transcript
    /// yields zero visible turns; feeds the empty state's explanation.
    @State private var emptySessionCommands: [String] = []

    /// Cmd+F over this transcript. Owned here rather than by the bar or
    /// by `RunnerStreamView`: the composer's button toggles it and a
    /// global-search result seeds it, both of which outlive the bar.
    @StateObject private var find = TranscriptFindState()
    /// True when the loaded transcript is only the newest slice of the
    /// file — the turn cap bit, or the file is bigger than the read
    /// budget. Drives the find bar's scope note (what keeps "3 of 47"
    /// from reading as "47 in this session") AND the transcript's
    /// "Show earlier" button, which must keep offering while older
    /// turns exist ON DISK — the loaded rows running out is not the
    /// session's start.
    @State private var historyPartial: Bool = false
    /// Byte budget the CURRENT `historicalItems` were read with — the
    /// rung of the widen ladder already spent. Starts at the ordinary
    /// open's bound and moves only forward; a widen to a SMALLER
    /// budget would replace loaded rows with fewer.
    @State private var historyLoadedBudget: Int = AgentSessionScanner.historyByteBudget
    /// Bytes the loaded history covered beyond the session's own file
    /// — a codex branch's inherited prefix. Added to the file's size
    /// wherever partiality is judged: a branch's own rollout is a few
    /// KB, and judged on that alone a long inherited prefix bounded by
    /// the read would pass for the whole conversation.
    @State private var inheritedHistoryBytes: UInt64 = 0
    /// Whether that read reached the file's start, where the reader says
    /// (claude's: its window counts conversation, skipping the request
    /// records most of a long transcript is made of, so the file's size
    /// can be far past the budget with nothing left unread). nil: judged
    /// by size.
    @State private var historyReadReachedStart: Bool? = nil
    /// Whether the 50-turn cap applied to that read. Only the initial
    /// open caps turns; every widen reads `maxTurns: .max`, so a
    /// partiality verdict after one is about bytes alone.
    @State private var historyTurnCapApplies: Bool = true
    /// Static, honest statement for the one state the button cannot
    /// help: the ladder is exhausted and the file is STILL bigger than
    /// the widest read. nil otherwise. Computed where partiality is
    /// (never in `body` — it names file sizes, and a body that stats
    /// the filesystem runs on every streamed event).
    @State private var historyTruncationNote: String? = nil
    @State private var wideningHistory: Bool = false

    /// Set just before handleSessionIdDiscovered flips AppState so the
    /// openAgentSessionId onChange can tell the draft→existing
    /// MIGRATION (same conversation — keep whatever the user is
    /// typing) from a real session switch (clear the composer so text
    /// can't follow the user into another session).
    @State private var migrationFlipInFlight = false

    // MARK: - Session mode

    private enum SessionMode: Equatable {
        case draft(ClaudeSessionDraft)
        case existing(id: String, fileURL: URL, cwd: URL, resolvedSession: AgentSession?)
        case empty

        static func == (lhs: SessionMode, rhs: SessionMode) -> Bool {
            switch (lhs, rhs) {
            case (.empty, .empty): return true
            case (.draft(let a), .draft(let b)): return a.id == b.id
            case (.existing(let a, _, _, _), .existing(let b, _, _, _)): return a == b
            default: return false
            }
        }
    }

    private var mode: SessionMode {
        if let draft = appState.pendingClaudeSessionDraft {
            return .draft(draft)
        }
        if let id = appState.openAgentSessionId,
           let url = appState.openAgentSessionPath {
            let resolved = agents.sessions.first(where: { $0.id == id })
            let cwd = resolved?.projectPath
                ?? URL(fileURLWithPath: NSHomeDirectory())
            return .existing(id: id, fileURL: url, cwd: cwd, resolvedSession: resolved)
        }
        return .empty
    }

    /// The runner currently driving the center column, or nil in .empty
    /// mode. Uses the AgentManager factories so runner identity is stable
    /// across SwiftUI re-resolves (e.g. through the draft→existing
    /// transition).
    ///
    /// Draft mode deliberately reads the cache without creating: the
    /// runner captures its cwd at init, so creating it on first render
    /// would freeze the composer's folder control before the user ever
    /// sends. `handleSend` creates it with the folder chosen at that
    /// moment.
    private var currentRunner: AgentRunner? {
        switch mode {
        case .draft(let d):
            return agents.cachedRunner(forDraft: d)
        case .existing(let id, let url, let cwd, let resolved):
            return agents.runner(forSessionId: id, fileURL: url, cwd: cwd,
                                 agentKey: resolved?.agentKey ?? "claude_code")
        case .empty:
            return nil
        }
    }

    /// Draft-mode empty state needs the cwd; this accessor hands it to
    /// the subview without requiring the subview to reach back into
    /// AppState.
    private var draftCwdForEmptyState: URL? {
        if case .draft(let d) = mode { return d.cwd }
        return nil
    }

    /// Custom group a draft started from a group header's + will be
    /// filed into, named on the empty state so the filing is visible
    /// before the first send rather than only afterwards, in the
    /// sidebar. Nil for every other route into this view.
    ///
    /// Membership is re-read on every pass, under the same test the
    /// filing itself makes in `AgentManager.migrateRunner`: a group
    /// deleted while its draft sits open is no group, and a page that
    /// kept saying "It will appear in the “Work” group" over a filing
    /// that cannot happen would be the one thing on screen that is
    /// wrong. (A rename is followed by the sidebar into the draft
    /// itself; only a group that is GONE reads as nil here.)
    private var draftCustomGroup: String? {
        guard case .draft(let d) = mode, let group = d.customGroup,
              config.agentCustomGroups(for: d.agentKey).contains(group)
        else { return nil }
        return group
    }

    /// The custom group a BRANCH of the open session belongs in: the
    /// session's own filing, else — for a scheduled run, which carries
    /// no filing of its own — its task's. A branch is the same
    /// conversation continued elsewhere and keeps the parent's working
    /// folder; unfiled, it sits under Ungrouped while its parent sits
    /// in a group. Decided here, written by `AgentManager`
    /// (membership-tested at the write, like the +'s filing), so the
    /// view never files anything itself. Read at the click: a group
    /// renamed while the fork runs fails the membership test and the
    /// branch is simply unfiled — the same window the + accepts.
    private var branchCustomGroup: String? {
        guard case .existing(let id, _, _, let resolved) = mode else { return nil }
        if let group = config.agentSessionGroup(for: id) { return group }
        guard let task = resolved?.scheduledTaskName else { return nil }
        return config.agentSessionGroup(
            for: AgentListItem.groupItemKey(forScheduledTaskName: task))
    }

    /// Stable identity of the transcript currently on screen — the key
    /// the composer-draft stash files this view's text under.
    ///
    /// A new session's key is the PLACE it was started from
    /// (`NewSessionPlace`), never the draft's own id:
    /// `ClaudeSessionDraft.init` mints a fresh UUID on every +, and
    /// leaving the draft nils `pendingClaudeSessionDraft` outright, so a
    /// per-draft key would file text typed into a new session under an
    /// identity nothing could ever ask for again. The same + asks for the
    /// same place, as a chat group's new chat asks for that group's slot
    /// (`chatDraftKey`).
    private var transcriptKey: String? {
        switch mode {
        case .draft(let d): return d.place.draftKey(agentKey: d.agentKey)
        case .existing(let id, _, _, _): return id
        case .empty: return nil
        }
    }

    /// Which new session is on screen and under which key — what tells a
    /// rename of its custom group (same draft, new key) from a switch to
    /// another new session (`adoptRenamedPlace`).
    private struct DraftPlaceIdentity: Equatable {
        let id: UUID
        let key: String
    }

    private var draftPlaceIdentity: DraftPlaceIdentity? {
        guard case .draft(let d) = mode else { return nil }
        return DraftPlaceIdentity(id: d.id, key: d.place.draftKey(agentKey: d.agentKey))
    }

    /// Stash the outgoing session's unsent text, restore the incoming
    /// session's — and with the text, the schedule a new session had set
    /// up. Both switch onChanges call this; when one logical switch fires
    /// both, the second call sees old == new and is a no-op.
    private func stashAndRestoreComposerDraft() {
        if migrationFlipInFlight {
            // Draft → session re-key of the SAME conversation. The two
            // switch onChanges fire in unspecified order, so this can
            // run before the flag is consumed — keep the composer text
            // in place and just adopt the new key.
            rekeyComposerDraft()
            return
        }
        let newKey = transcriptKey
        if let old = loadedDraftKey, old != newKey {
            appState.setComposerDraft(inputDraft,
                                      for: AppState.agentDraftKey(old))
            appState.setComposerAttachments(stagedAttachments,
                                            for: AppState.agentDraftKey(old))
            appState.setComposerSchedule(scheduleDraft,
                                         for: AppState.agentDraftKey(old))
        }
        if loadedDraftKey != newKey {
            inputDraft = appState.composerDraft(
                for: AppState.agentDraftKey(newKey))
            stagedAttachments = appState.composerAttachments(
                for: AppState.agentDraftKey(newKey))
            scheduleDraft = appState.composerSchedule(
                for: AppState.agentDraftKey(newKey))
            attachmentNotice = nil
            loadedDraftKey = newKey
            takeUnsentAnswersIntoBox()
        }
    }

    /// The conversation didn't change, its KEY did (draft → discovered
    /// session id). Adopt the new key and carry the text over.
    ///
    /// The carry is load-bearing because writes happen per keystroke:
    /// this path leaves `inputDraft` untouched on purpose, so no
    /// `onChange` fires, so nothing would ever file the text under the
    /// new key — anything typed in the window between the first send
    /// and session-id discovery would sit under the new session's place
    /// for good and read as lost the next time the session was opened.
    private func rekeyComposerDraft() {
        let old = loadedDraftKey
        loadedDraftKey = transcriptKey
        stashComposerDraft()
        stashComposerAttachments()
        if let old, old != loadedDraftKey {
            appState.setComposerDraft("", for: AppState.agentDraftKey(old))
            appState.setComposerAttachments([], for: AppState.agentDraftKey(old))
        }
        // The session it became cannot be scheduled: whatever schedule
        // the page holds stays behind (a message sent from the composer
        // has used its new session's up already, in `handleSend`).
        scheduleDraft = ScheduleDraft()
    }

    /// Adopt the store's text for whatever is on screen. Called on
    /// appear, where there is no outgoing identity to stash: this view
    /// is re-created from scratch after any trip through a chat or a
    /// note, and `loadedDraftKey` is nil on that first pass. Stashing
    /// the (empty) composer under the incoming key first would DELETE
    /// the draft we are about to restore.
    private func restoreComposerDraft() {
        loadedDraftKey = transcriptKey
        inputDraft = appState.composerDraft(
            for: AppState.agentDraftKey(transcriptKey))
        stagedAttachments = appState.composerAttachments(
            for: AppState.agentDraftKey(transcriptKey))
        scheduleDraft = appState.composerSchedule(
            for: AppState.agentDraftKey(transcriptKey))
        takeUnsentAnswersIntoBox()
    }

    /// What the user had started on a question the agent asked without
    /// stopping, handed back when its card went (`AgentRunner.unsentAnswers`)
    /// — into this session's box (`UnsentAnswers.boxText`). Taken only while
    /// the box holds the text of the session whose runner kept it: an
    /// answer from a session not on screen waits on its runner until its
    /// page shows it, and lands in no other session's box.
    private func takeUnsentAnswersIntoBox() {
        guard let runner = currentRunner, loadedDraftKey != nil,
              loadedDraftKey == transcriptKey,
              let answers = runner.takeUnsentAnswers() else { return }
        inputDraft = UnsentAnswers.boxText(answers, over: inputDraft)
    }

    /// Write the live text through to the store. Called on every
    /// change, so the store is ALWAYS current.
    ///
    /// A teardown stash would leave a half-typed prompt depending on
    /// one `.onDisappear` callback firing with `@State` still readable
    /// — and it could do worse than fail: `setComposerDraft("")`
    /// DELETES the key, so a teardown that reads `inputDraft` back as
    /// its initial "" would erase whatever was already stashed.
    /// Writing through on change removes the question entirely: no
    /// lifecycle callback has to fire, in any order, for the text to
    /// survive. The store is a plain dictionary and is deliberately
    /// not `@Published`, so this costs no re-render.
    private func stashComposerDraft() {
        guard let key = loadedDraftKey else { return }
        appState.setComposerDraft(inputDraft, for: AppState.agentDraftKey(key))
    }

    /// The staged files, written through on every change — the same
    /// rule as the text, for the same reason.
    private func stashComposerAttachments() {
        guard let key = loadedDraftKey else { return }
        appState.setComposerAttachments(stagedAttachments,
                                        for: AppState.agentDraftKey(key))
    }

    /// A new session's schedule, written through on every change — the
    /// same rule as the text, for the same reason.
    private func stashComposerSchedule() {
        guard let key = loadedDraftKey else { return }
        appState.setComposerSchedule(scheduleDraft, for: AppState.agentDraftKey(key))
    }

    // MARK: - Read-only tier

    /// Which agent owns the open session — including a draft, which is
    /// born from whichever sidebar section's New-session row started it.
    private var sessionAgentKey: String {
        switch mode {
        case .existing(_, _, _, let resolved):
            return resolved?.agentKey ?? "claude_code"
        case .draft(let d):
            return d.agentKey
        case .empty:
            return "claude_code"
        }
    }

    /// The open session's agent, under whatever name the user has given
    /// it in Settings. Goes through `config.agentLabel` for BOTH agents:
    /// the label is editable per agent, and a hardcoded "Codex" here
    /// would ignore a rename the sidebar section header honours — the
    /// same agent named two ways one pane apart.
    private var sessionAgentName: String {
        let fallback = AgentManager.registry
            .first { $0.key == sessionAgentKey }?.name ?? "Claude Code"
        return config.agentLabel(for: sessionAgentKey, defaultName: fallback)
    }

    /// A session is driven only while its agent is LISTED (installed,
    /// signed in, not hidden — `AgentPresence`). There is no read-only
    /// state any more: ContentView closes this pane the moment the
    /// agent stops being listed, so the guard below is for the send
    /// that races that close.
    private var agentIsListed: Bool {
        agents.isAgentReady(sessionAgentKey)
    }

    /// The scheduled task whose panel belongs above this transcript, if
    /// the sidebar opened one. Resolved live from AgentManager so an
    /// edit or a finished run refreshes the panel without any wiring
    /// here.
    private var openScheduledTask: ScheduledAgentTask? {
        guard let name = appState.openScheduledTaskName else { return nil }
        return agents.scheduledTasks.first { $0.name == name }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The band between the top bar and the transcript — the one
            // Settings keeps above its column too (`SipDesign.pageTopBand`),
            // so a section's first line sits where a transcript's first
            // row does. No title bar below — the message stream is the
            // only content above the input card. A scheduled-task panel
            // takes this inset over instead (see its `topInset`): a
            // spacer above it painted window background over the card,
            // which reads as a gap between the window top and the panel.
            if openScheduledTask == nil {
                Spacer().frame(height: SipDesign.pageTopBand)
            }
            if case .empty = mode, let task = openScheduledTask {
                // The task's own page, opened from its row with no run
                // under it — whether or not it has run: nothing to
                // transcribe and nothing to send, so the settings ARE the
                // page. No banner, no welcome hero, no composer.
                ScheduledTaskPanel(task: task, presentation: .page,
                                   atWindowTop: true)
            } else {
            if let task = openScheduledTask {
                // Outside the transcript's re-scope, like the composer:
                // the panel reads the tier at the design-size convention
                // (see `ScheduledTaskPanel.fontScale`).
                ScheduledTaskPanel(task: task, atWindowTop: true)
            }
            // Find bar — above the transcript, never over the composer
            // or the newest turn.
            if find.isOpen {
                findBarSection
            }
            if let runner = currentRunner {
                runnerStream(runner)
            } else if case .draft = mode {
                // Draft before its first send: no runner exists yet, by
                // design — the composer's folder choice must stay open.
                draftWelcome
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if mode != .empty {
                inputArea
            }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(branchErrorTitle ?? String(localized: "Could not create the branch",
                                          comment: "Title of the alert shown when forking a session fails"),
               isPresented: Binding(
                   get: { branchError != nil },
                   set: { if !$0 { branchError = nil; branchErrorTitle = nil } }
               )) {
            Button(role: .cancel) { branchError = nil; branchErrorTitle = nil } label: {
                Text("OK", comment: "Dismiss the branch-failure alert")
            }
        } message: {
            Text(branchError ?? "")
        }
        // Cmd+F. An invisible zero-size button rather than an app-level
        // menu command: the shortcut has to reach the transcript that
        // is actually on screen, and the router replaces this view
        // whenever that changes.
        .background {
            Button {
                if find.isOpen { find.close() } else { openFind() }
            } label: { Color.clear }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
            .disabled(!hasSearchableTranscript)
        }
        .onAppear {
            if loadedDraftKey == nil { restoreComposerDraft() }
            reload()
            seedLaunchOptions()
            consumePendingFind()
        }
        .onChange(of: appState.pendingFindQuery) { _, _ in consumePendingFind() }
        // Every keystroke goes straight to the store. No `.onDisappear`
        // stash: see `stashComposerDraft` for why relying on teardown
        // both lost drafts and erased them.
        .onChange(of: scheduleDraft) { _, _ in stashComposerSchedule() }
        .onChange(of: launchOptions) { _, new in keepSentOptions(new) }
        .onChange(of: draftPlaceIdentity) { old, new in adoptRenamedPlace(from: old, to: new) }
        .onChange(of: inputDraft) { _, _ in stashComposerDraft() }
        .onChange(of: stagedAttachments) { _, _ in stashComposerAttachments() }
        // Files staged as paths must travel inside a Chat only message,
        // so they are read the moment they are waiting for one — while
        // the user is still writing, not at send.
        .onChange(of: stagedPathsAwaitChatOnly) { _, waiting in
            if waiting { loadStagedFilesForChatOnly() }
        }
        .onChange(of: appState.openAgentSessionId) { _, _ in
            // A real switch STASHES the composer text under the session
            // it was typed for and restores whatever the incoming
            // session had — half-typed text must neither follow the
            // user into another session (one keystroke would send it
            // to the wrong claude) nor be thrown away. The migration
            // flip keeps the text in place: same conversation, new id.
            if migrationFlipInFlight {
                migrationFlipInFlight = false
                rekeyComposerDraft()
                reload(migratedFromDraft: true)
            } else {
                stashAndRestoreComposerDraft()
                reload()
            }
            seedLaunchOptions()
        }
        .onChange(of: appState.pendingClaudeSessionDraft?.id) { _, _ in
            stashAndRestoreComposerDraft()
            // Reset the composer's readouts only while a DRAFT actually
            // owns the pane. This fires on the draft ARRIVING (where the
            // reset is the point — the outgoing session's token count and
            // turn time must not read as the new draft's) and on it going
            // AWAY, which is a different event entirely: the draft is
            // nil'd by AppState's own didSet whenever an existing session
            // opens, and by the draft→existing migration. In both of
            // those the pane is showing a real session whose values
            // `reload()` has just seeded (or which the live turn owns),
            // and zeroing here blanks a number that is on screen and
            // correct — with nothing to restore it, since a cache-hit
            // reload returns early on an unchanged file.
            //
            // A mode test rather than a re-ordering of the two onChange
            // blocks: which of them SwiftUI runs first for one update is
            // not something to depend on, and the answer is the same
            // either way.
            if case .draft = mode {
                refreshNewSessionStart()
                seededContextTokens = 0
                seededContextModel = nil
                seededCallSpeed = nil
                liveContextTokens = 0
                liveContextModel = ""
                seededTurnDuration = 0
                liveTurnDuration = nil
                livePause = TurnPause()
            }
            seedLaunchOptions()
        }
        .onChange(of: currentRunner?.status.isRunning ?? false) { _, _ in
            // The Non-stop switch shows the RUNNING turn's own setting
            // (`applySeededOptions`), and a turn that ends takes it away
            // again: a scheduled run is Non-stop when its task says so, and
            // the session it leaves behind asks as the user's own pick
            // says.
            restoreNonStopPick()
        }
        .onChange(of: currentRunner?.sessionId) { _, newSessionId in
            // When a draft's runner discovers a session_id, flip AppState
            // and persist the draft's in-memory picks against the new key.
            handleSessionIdDiscovered(newSessionId)
        }
        .onReceive(sessionFilePublisher) { url in
            // The id and its transcript do NOT arrive together — the
            // child announces the id first and writes the file a beat
            // later, so the flip above usually runs with no path to
            // route to and bails. This is the second half of the same
            // event; without it a new session stays in draft mode for
            // its whole life, and everything the pane derives from a
            // session id (its token seed included) never happens.
            guard url != nil else { return }
            handleSessionIdDiscovered(currentRunner?.sessionId)
        }
        .onReceive(contextUsagePublisher) { (usage: (Int, Int, CodexKeptSpeed.Saved)) in
            adoptContextUsage(usage.0, usage.1, usage.2)
        }
        .onReceive(turnDurationPublisher) { value in
            // Equality-guarded like the token feed, same reason.
            guard let value, value > 0, value != liveTurnDuration else { return }
            liveTurnDuration = value
        }
        .onReceive(userWaitPublisher) { value in
            guard value != livePause else { return }
            livePause = value
        }
        .onReceive(unsentAnswersPublisher) { answers in
            guard answers != nil else { return }
            takeUnsentAnswersIntoBox()
        }
        .onReceive(externalTurnPublisher) { (inProgress: Bool) in
            handleExternalTurnFlip(inProgress)
        }
        .onReceive(externalTurnStartPublisher) { value in
            // Equality-guarded like the token feed (@Published replays
            // on every resubscribe). The replay also heals session
            // switches: the incoming runner's current value — nil for
            // an idle session — lands within a frame.
            guard value != externalTurnStart else { return }
            externalTurnStart = value
        }
        .onReceive(externalStoppablePublisher) { pid in
            let stoppable = pid != nil
            guard stoppable != externalStoppable else { return }
            externalStoppable = stoppable
        }
        .onReceive(liveModelIdPublisher) { (resolved: AgentRunner.ResolvedModel?) in
            adoptResolvedModel(resolved)
        }
        .onReceive(fastModePublisher) { (report: ClaudeFastModeReport) in
            adoptFastModeReport(report)
        }
        .onReceive(codexSpeedPublisher) { (report: CodexSpeedReport) in
            guard report != liveCodexSpeedReport else { return }
            liveCodexSpeedReport = report
        }
        .onReceive(observedWindowsPublisher) { (windows: [String: Int]) in
            adoptObservedWindows(windows)
        }
    }

    /// File what claude reported about its own context windows.
    ///
    /// Guarded on its OWN mirror, like every live feed here: `@Published`
    /// replays to each resubscription and `onReceive` resubscribes per
    /// render, so an unguarded handler would rewrite config on every
    /// pass. Claude-only by construction — the other two publish an
    /// empty map, and `windows` is empty on every event but `result`.
    private func adoptObservedWindows(_ windows: [String: Int]) {
        guard !windows.isEmpty, windows != observedWindowsMirror else { return }
        observedWindowsMirror = windows
        for (model, window) in windows {
            config.setAgentModelContextWindow(window, forModelId: model)
        }
    }

    private func adoptFastModeReport(_ report: ClaudeFastModeReport) {
        guard report != liveFastModeReport else { return }
        liveFastModeReport = report
        // Claude sets its credits verdict from the response header, so a
        // call that just reported is the moment it can have moved. Two
        // stats when it has not.
        if sessionAgentKey == "claude_code" {
            ClaudeCapabilities.shared.refreshUsageCreditsBlock()
        }
    }

    /// What the composer states about fast mode: the live report, with
    /// the transcript's newest call speed carried beside it as history —
    /// `ClaudeFastMode.verdict` ranks it below the live channels and the
    /// cached credits verdict.
    private var fastModeReport: ClaudeFastModeReport {
        var report = liveFastModeReport
        report.seededSpeed = seededCallSpeed
        return report
    }

    /// The subprocess's system.init names the model that will actually
    /// serve the turn — more precise than the picker alias.
    ///
    /// Equality-guarded against THIS FEED'S OWN mirror, like the token
    /// and duration feeds: @Published replays its current value to
    /// every resubscription and onReceive resubscribes per render, so
    /// an unguarded handler re-runs on every frame carrying a value
    /// that can be several turns old.
    ///
    /// Guarding on `launchOptions` instead — which is what this did —
    /// inverts the guard into a trigger. The user picks a different
    /// model, the pick clears `modelFullId`, and the very next render
    /// replays the OLD turn's id into a handler that now reads "this
    /// is new": the chip snaps back to the model the session was
    /// already running, and `setAgentModelFullId` files that id under
    /// the alias the user just picked, renaming it in every picker on
    /// this machine, permanently.
    private func adoptResolvedModel(_ resolved: AgentRunner.ResolvedModel?) {
        guard let resolved, !resolved.fullId.isEmpty,
              resolved != liveResolvedModel else { return }
        liveResolvedModel = resolved
        // Remember what THAT alias (or "" = claude's default)
        // resolved to — the fallback behind the binary's own alias
        // table for the picker rows, and the hover's record of what
        // actually ran. The alias rides with the id from the runner
        // precisely so this cannot be attributed to whatever the chip
        // says now.
        config.setAgentModelFullId(resolved.fullId,
                                   forAlias: resolved.alias)
        // An observation is an input to "Other models" — the pool it
        // draws from and, on a binary without the alias table, the
        // anchor it is drawn below — so the section is recomputed
        // here, whether or not this session's chip still shows the
        // alias: the section is not about this session.
        ClaudeModelCatalog.refreshOtherModels(config: config)
        // Refine the recorded id only while the chip still shows the
        // alias this observation is about. A pick made since describes
        // a model that has not run yet. The title does not read the
        // recorded id — it names what the alias resolves to NOW — so
        // this only keeps the hover's "last ran as" current.
        guard (launchOptions.model ?? "") == resolved.alias,
              launchOptions.modelFullId != resolved.fullId else { return }
        // A mirror of recorded state, not a pick: written to the state
        // alone, which saves nothing (only `userPicks` saves).
        launchOptions.modelFullId = resolved.fullId
    }

    /// The current runner's context-token feed. The value is published
    /// as assistant EVENTS carrying usage are appended (see
    /// AgentRunner) — live during the turn, from its first API call —
    /// so it can never race the status flip; the replay-on-subscribe
    /// also heals any emission a re-render gap might have missed.
    private var contextUsagePublisher: AnyPublisher<(Int, Int, CodexKeptSpeed.Saved), Never> {
        guard let runner = currentRunner else {
            return Empty().eraseToAnyPublisher()
        }
        // The window rides the same delivery as the tokens it divides;
        // combineLatest re-emits on either and replays both on
        // (re)subscription, exactly like the single feed did. Codex's
        // saved speed is read from the same rollout at the same moments,
        // and rides with them.
        return runner.$lastContextTokens
            .combineLatest(runner.$lastContextWindow, runner.$codexSavedSpeed)
            .eraseToAnyPublisher()
    }

    /// Handler bodies for the feeds above live in METHODS, not in the
    /// `.onReceive` closures: the body's modifier chain sits at the
    /// type-checker's complexity limit, and a closure of any size in
    /// it is inference work multiplied by the whole chain.
    private func adoptContextUsage(_ tokens: Int, _ window: Int,
                                   _ saved: CodexKeptSpeed.Saved) {
        // Equality guards: @Published replays its current value to
        // every (re)subscription, and onReceive resubscribes per
        // render — without them that replay would loop. Each value is
        // guarded on its OWN mirror.
        if tokens > 0, tokens != liveContextTokens {
            liveContextTokens = tokens
        }
        if window > 0, window != liveContextWindow {
            liveContextWindow = window
        }
        if saved != .unknown, saved != codexSavedSpeed {
            codexSavedSpeed = saved
        }
    }

    private func handleExternalTurnFlip(_ inProgress: Bool) {
        if inProgress {
            // Proof the session is NOT abandoned: something is
            // writing to it right now. Any "Interrupted" marker
            // derived at load time was a snapshot of a gap — the
            // exact case where the turn's answer then lands
            // underneath a marker saying it never finished.
            dropInterruptedMarker()
            return
        }
        // External turns (another terminal) never emit a `.result`
        // stream event here — re-derive the footprint from the
        // session file the external writer just finished writing.
        // Same for the mode/model/effort chips: the external turn
        // may have switched any of them.
        guard case .existing(_, let url, _, _) = mode else { return }
        // Per agent, like every other read keyed on a session's
        // owner: the three scanners decode different schemas, and
        // claude's would quietly answer 0 on a codex rollout — the
        // tailer this publisher rides watches all three.
        if sessionAgentKey == "codex" {
            let info = CodexSessionScanner.lastContextInfo(of: url)
            if info.tokens > 0 { liveContextTokens = info.tokens }
            if info.window > 0 { liveContextWindow = info.window }
            // The other process may have set the thread's speed.
            if case let saved = Self.codexSavedSpeed(of: url), saved != .unknown {
                codexSavedSpeed = saved
            }
        } else if sessionAgentKey == "kimi" {
            // Kimi's own reader, joined to its config window — the
            // claude scanner answers 0 on a kimi wire, which would
            // read as "no usage yet" rather than as the wrong reader.
            let usage = KimiSessionScanner.lastContextUsage(of: url)
            if usage.tokens > 0 { liveContextTokens = usage.tokens }
            if let model = usage.model, !model.isEmpty {
                liveContextModel = model
                KimiCatalog.shared.ensureLoaded()
                if let w = KimiCatalog.shared.maxContextSize(forModel: model),
                   w > 0 {
                    liveContextWindow = w
                }
            }
        } else if sessionAgentKey == "claude_code" {
            let usage = AgentSessionScanner.lastContextTokens(of: url)
            if usage.tokens > 0 { liveContextTokens = usage.tokens }
            if let model = usage.model, !model.isEmpty {
                liveContextModel = model
            }
        }
        // Refresh the clock's resting value from the turn the other
        // terminal just finished — we have no live clock for it, so
        // the transcript is the only source, in each agent's own
        // figures (codex `duration_ms`, kimi `durationMs`). OFF-MAIN,
        // unlike the token read above it: this scan can escalate to a
        // 4 MB read, and doing that on the main actor at every external
        // turn boundary is a visible stall on a big session.
        let agent = sessionAgentKey
        Task.detached(priority: .utility) {
            let took: Double
            switch agent {
            case "codex":
                took = CodexSessionScanner.latestTurn(of: url)?.seconds ?? 0
            case "kimi":
                took = KimiSessionScanner.latestTurn(of: url)?.seconds ?? 0
            case "claude_code":
                took = AgentSessionScanner.lastTurnDurationSeconds(of: url)
            default:
                took = 0
            }
            guard took > 0 else { return }
            await MainActor.run {
                // The user may have switched sessions mid-read.
                guard case .existing(_, let current, _, _) = mode,
                      current == url else { return }
                // Into the runner, not `liveTurnDuration` — the
                // publisher's replay would otherwise put the older
                // in-app value straight back. See
                // `noteExternalTurnDuration`.
                currentRunner?.noteExternalTurnDuration(took)
            }
        }
        seedLaunchOptions()
    }

    /// The runner's transcript path, which for a draft's first turn is
    /// resolved AFTER the session id (see `AgentRunner.awaitSessionFile`).
    /// Same delivery contract as `contextUsagePublisher`.
    private var sessionFilePublisher: AnyPublisher<URL?, Never> {
        guard let runner = currentRunner else {
            return Empty().eraseToAnyPublisher()
        }
        return runner.$sessionFileURL.eraseToAnyPublisher()
    }

    /// The runner's latest finished-turn duration — see
    /// `contextUsagePublisher` for the delivery contract it mirrors.
    private var turnDurationPublisher: AnyPublisher<Double?, Never> {
        guard let runner = currentRunner else {
            return Empty().eraseToAnyPublisher()
        }
        return runner.$lastTurnDuration.eraseToAnyPublisher()
    }

    /// The running turn's waits on the user's cards — see
    /// `contextUsagePublisher` for the delivery contract it mirrors.
    private var userWaitPublisher: AnyPublisher<TurnPause, Never> {
        guard let runner = currentRunner else {
            return Empty().eraseToAnyPublisher()
        }
        return runner.$userWait.eraseToAnyPublisher()
    }

    /// An answer handed back when its card went (`AgentRunner.unsentAnswers`).
    /// The replay on every resubscribe is harmless: taking it empties it.
    private var unsentAnswersPublisher: AnyPublisher<String?, Never> {
        guard let runner = currentRunner else {
            return Empty().eraseToAnyPublisher()
        }
        return runner.$unsentAnswers.eraseToAnyPublisher()
    }

    /// External-writer signal; dropFirst skips the replay so the file
    /// rescan runs only on real turn boundaries.
    private var externalTurnPublisher: AnyPublisher<Bool, Never> {
        guard let runner = currentRunner else {
            return Empty().eraseToAnyPublisher()
        }
        return runner.$externalInProgress.dropFirst().eraseToAnyPublisher()
    }

    /// External turn's start instant (transcript stamp) — feeds the
    /// composer clock. Replay-on-subscribe keeps it correct across
    /// session switches, like the token feed.
    private var externalTurnStartPublisher: AnyPublisher<Date?, Never> {
        guard let runner = currentRunner else {
            return Empty().eraseToAnyPublisher()
        }
        return runner.$externalTurnStartedAt.eraseToAnyPublisher()
    }

    /// Whether the external writer is a killable orphaned `-p` run —
    /// feeds the composer's Stop enablement.
    private var externalStoppablePublisher: AnyPublisher<Int32?, Never> {
        guard let runner = currentRunner else {
            return Empty().eraseToAnyPublisher()
        }
        return runner.$externalStoppablePid.eraseToAnyPublisher()
    }

    /// Resolved-model feed from the runner's system.init events; keeps
    /// the composer's model chip on the exact model id mid-session.
    /// Carries the alias the turn was launched with — see
    /// `AgentRunner.ResolvedModel`.
    private var liveModelIdPublisher: AnyPublisher<AgentRunner.ResolvedModel?, Never> {
        guard let runner = currentRunner else {
            return Empty().eraseToAnyPublisher()
        }
        return runner.$resolvedModel.eraseToAnyPublisher()
    }

    private var fastModePublisher: AnyPublisher<ClaudeFastModeReport, Never> {
        guard let runner = currentRunner else {
            return Empty().eraseToAnyPublisher()
        }
        return runner.$fastModeReport.eraseToAnyPublisher()
    }

    private var codexSpeedPublisher: AnyPublisher<CodexSpeedReport, Never> {
        guard let runner = currentRunner else {
            return Empty().eraseToAnyPublisher()
        }
        return runner.$codexSpeedReport.eraseToAnyPublisher()
    }

    private var observedWindowsPublisher: AnyPublisher<[String: Int], Never> {
        guard let runner = currentRunner else {
            return Empty().eraseToAnyPublisher()
        }
        return runner.$observedContextWindows.eraseToAnyPublisher()
    }

    // MARK: - Empty (.empty-mode fallback)

    @ViewBuilder
    private var emptyState: some View {
        VStack {
            Spacer()
            // Agent-neutral: this is the no-session-at-all state, and
            // it is reached with no agent chosen yet.
            Text("Open or start an agent session to begin.",
                 comment: "Center column state when no session is resolved at all")
                .font(.system(size: 13 * SipFont.contentScale(fontScale)))
                .foregroundColor(ChatDesign.textSecondary)
            Spacer()
        }
    }

    // A task's page — its row opened it, so no run is under it — renders
    // `ScheduledTaskPanel(presentation: .page)` instead of this.

    /// Centered hero for an unsent draft, mirroring ChatView's empty
    /// state. The working folder lives in the composer's control strip,
    /// so this stays a plain invitation.
    @ViewBuilder
    private var draftWelcome: some View {
        VStack(spacing: 14) {
            Spacer()
            HStack(alignment: .bottom, spacing: 12) {
                // Size-matched rendition — see ChatView's empty state,
                // which pairs the same 67 pt mark with 28 pt text
                // (`TaglineFit.baseFontSize`). Keeping both heroes on that
                // pairing is why the title is 28 rather than a free choice.
                Image("SipAI-Logo-67")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 67)
                Text(String(localized: "New \(sessionAgentName) session",
                            comment: "Draft empty-state title; placeholder is the user-editable agent label"))
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(SipDesign.textPrimary)
                    .tracking(-0.4)
            }
            Text("Pick model, effort, mode, folder, and schedule below, then describe the task.",
                 comment: "Draft empty-state hint under the title")
                .font(.system(size: 15 * SipFont.contentScale(fontScale)))
                .foregroundColor(ChatDesign.textSecondary)
            Spacer()
        }
    }

    // MARK: - Input area

    /// Context-window footprint driving the composer's token counter:
    /// the newest live value (delivered by the runner's publisher, or a
    /// file rescan after an external turn) wins; before any live turn,
    /// the value seeded from the session JSONL.
    private var displayContextTokens: Int {
        liveContextTokens > 0 ? liveContextTokens : seededContextTokens
    }

    /// The window an agent RECORDED beside the number, same precedence
    /// as the number it divides. 0/nil for claude, which records none;
    /// `resolvedContextWindow` is what the chip actually reads.
    private var displayContextWindow: Int? {
        if liveContextWindow > 0 { return liveContextWindow }
        return seededContextWindow > 0 ? seededContextWindow : nil
    }

    /// The window the composer's percentage is drawn over — the
    /// SELECTED model's, falling back to the model that produced the
    /// number, and nil when neither is known (the chip then states the
    /// count and says the window is unknown).
    ///
    /// The rule itself lives in `ContextWindowResolver` so all three
    /// agents share one; this only supplies the lookups, which are
    /// MainActor state it cannot hold.
    private var resolvedContextWindow: Int? {
        let numeratorModel = liveContextModel.isEmpty
            ? seededContextModel : liveContextModel
        // A CONCRETE pick (a full id in `model`) resolves itself; an
        // alias resolves through what the NEXT send will run — the
        // binary's table, the observed map as its fallback — never
        // through the id the session last ran under, which is
        // display-only (`modelFullId`, the hover).
        let picked = launchOptions.model ?? ""
        return ContextWindowResolver.resolve(
            agentKey: sessionAgentKey,
            selectedAlias: launchOptions.model,
            selectedFullId: ClaudeModelDisplay.isFullId(picked) ? picked : nil,
            numeratorModel: numeratorModel,
            recordedWindow: displayContextWindow ?? 0,
            aliasToId: { config.resolvedModelId(forAlias: $0) },
            binaryWindow: { id in
                guard let binary = AgentManager.binaryPath(for: "claude_code")
                else { return nil }
                return ClaudeModelCatalog.contextWindow(forModelId: id,
                                                        binary: binary)
            },
            learnedWindow: { config.agentModelContextWindow(forModelId: $0) },
            catalogWindow: { selection in
                sessionAgentKey == "codex"
                    // Default is the model codex's config names in this
                    // session's folder, which a project may set.
                    ? codexCatalog.contextWindow(forModel: selection?.isEmpty == false
                        ? selection
                        : codexCatalog.defaultModel(forFolder: composerFolder.path))
                    : sessionAgentKey == "kimi"
                        ? KimiCatalog.shared.maxContextSize(forModel: selection)
                        : nil
            })
    }

    /// Same shape for the turn clock's resting value: a turn this app
    /// ran wins, else whatever the transcript's newest finished turn
    /// says, else nil (chip hidden — nothing has ever run here).
    private var displayTurnDuration: Double? {
        if let live = liveTurnDuration, live > 0 { return live }
        return seededTurnDuration > 0 ? seededTurnDuration : nil
    }

    /// Start instant of the in-flight turn, or nil when nothing is
    /// running — the composer's turn clock counts from it.
    ///
    /// Read straight off the runner's status rather than mirrored into
    /// @State: this view re-renders on `AgentManager.inFlightSends`,
    /// which is written on exactly the status flips that change this
    /// value. The ticking itself belongs to `TurnClockChip`, so nothing
    /// here re-renders per second.
    private var turnStartedAt: Date? {
        if case .running(let startedAt) = currentRunner?.status {
            // Moved later by every wait on one of the turn's cards that
            // has ended, so the clock counts the turn's working time.
            return startedAt.addingTimeInterval(livePause.total)
        }
        // A turn some OTHER process is running ticks from the
        // transcript's own stamp (mirrored into @State because this
        // view doesn't observe the runner; re-renders arrive via
        // `externalInFlightSessions`, written on the same flips).
        if currentRunner?.externalInProgress == true {
            return externalTurnStart
        }
        return nil
    }

    /// When the running turn began waiting on the user — a question, a
    /// plan or a permission card — or nil. The clock holds still from
    /// here.
    private var turnPausedAt: Date? {
        guard currentRunner?.status.isRunning == true else { return nil }
        return livePause.since
    }

    /// Folder shown in the composer. Draft cwd until the first send;
    /// the session's project path afterwards.
    private var composerFolder: URL {
        switch mode {
        case .draft(let d): return d.cwd
        case .existing(_, _, let cwd, _): return cwd
        case .empty: return URL(fileURLWithPath: NSHomeDirectory())
        }
    }

    private var isDraftBeforeFirstSend: Bool {
        if case .draft = mode { return currentRunner == nil }
        return false
    }

    /// Once a session exists it cannot retroactively become a scheduled
    /// task, so the schedule control is draft-only.
    private var isScheduleAvailable: Bool {
        if case .draft = mode { return true }
        return false
    }

    /// `(task name, run time)` when the open session was produced by a
    /// scheduled task — rendered as a read-only tag in the composer.
    private var scheduledRunInfo: (name: String, time: Date)? {
        guard case .existing(_, _, _, let resolved) = mode,
              let session = resolved,
              let taskName = session.scheduledTaskName
        else { return nil }
        // mtime ON PURPOSE, unlike the sidebar row's `activityAt`: this
        // tag is labelled "Latest run FINISHED at …", and the last byte
        // written is what finished means. Do not "align" it with the
        // sidebar without also changing the sentence.
        return (name: taskName, time: session.modifiedAt)
    }

    @ViewBuilder
    private var inputArea: some View {
        AgentComposer(
            draft: $inputDraft,
            agentKey: sessionAgentKey,
            sending: currentRunner?.status.isRunning ?? false,
            externalBusy: currentRunner?.externalInProgress ?? false,
            externalStoppable: externalStoppable,
            placeholder: inputPlaceholder,
            sessionIdTokens: agents.knownSessionIds,
            options: userPicks,
            fastModeReport: fastModeReport,
            codexSpeedReport: liveCodexSpeedReport,
            claudeAccount: sessionAgentKey == "claude_code"
                ? UsageMonitor.shared.accounts["claude_code"] : nil,
            codexSessionSpeed: isDraftBeforeFirstSend ? nil : codexSavedSpeed,
            attachments: stagedAttachments,
            onStageFiles: stageAttachments,
            onRemoveAttachment: removeAttachment,
            attachmentNotice: attachmentNoticeIsChatOnly == chatOnlyInForce ? attachmentNotice : nil,
            onDismissAttachmentNotice: { attachmentNotice = nil },
            folder: composerFolder,
            folderEditable: isDraftBeforeFirstSend,
            onFolderChange: { url in
                appState.pendingClaudeSessionDraft?.cwd = url
                // The draft's picks are read where its session will run.
                if showsSkillChip, !skillPicks.isEmpty {
                    SkillCatalog.shared.ensurePicksReadable(skillPicks, agent: sessionAgentKey, folder: url)
                }
            },
            customGroup: draftCustomGroup,
            scheduleAvailable: isScheduleAvailable,
            scheduleDraft: $scheduleDraft,
            scheduledRunInfo: scheduledRunInfo,
            onGenerateNote: { generateSessionNote(extraPrompt: $0) },
            noteGenerating: noteGenerating,
            canGenerateNote: canGenerateSessionNote,
            find: find,
            canFind: hasSearchableTranscript,
            skillPicks: showsSkillChip ? skillPicks : nil,
            onSkillPicksChange: { setSkillPicks($0) },
            skillHeld: {
                SkillPreload.held(picks: skillPicks, evidence: skillEvidence())
            },
            onOpenSkillSettings: { appState.openSettings(.skills) },
            contextTokens: displayContextTokens,
            contextWindowTokens: resolvedContextWindow,
            turnStartedAt: turnStartedAt,
            turnPausedAt: turnPausedAt,
            lastTurnDuration: displayTurnDuration,
            onSend: handleSend,
            onStop: handleStop,
            held: currentRunner?.held,
            onSteerHeld: { currentRunner?.steerHeld($0) },
            onSendHeld: { id in
                guard !branching, !sendIsHeld, let runner = currentRunner,
                      !runner.externalInProgress else { return }
                // A message the user sends: the session is alive again, so a
                // load-time "Interrupted" marker the reopened page derived
                // for the stopped turn must not sit between it and this one.
                if runner.sendHeldNow(id) { dropInterruptedMarker() }
            },
            onCancelHeld: { takeBackHeld($0) },
            reviewPickerFolder: reviewPickerOpen ? composerFolder : nil,
            onReviewChosen: { target, label in
                // Left open where nothing could start, so the choice is
                // not lost with the click.
                if startCodexCommand(.review(target), label: label, clearsBox: false) {
                    reviewPickerOpen = false
                }
            },
            onReviewCancelled: { reviewPickerOpen = false },
            onScheduleCreated: { [unsent = unsentNewSession] name in
                agents.noteScheduledTaskCreated(named: name)
                // The task took the staged files into its prompt, as the
                // send would have taken them into the message.
                stagedAttachments = []
                attachmentNotice = nil
                if let unsent { useUpNewSessionSkills(unsent) }
            }
        )
        .padding(.horizontal, 60)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .alert(String(localized: "Note generation failed",
                      comment: "Title of the session-note error alert"),
               isPresented: Binding(
                   get: { noteError != nil },
                   set: { if !$0 { noteError = nil } }
               )) {
            Button(role: .cancel) { noteError = nil } label: {
                Text("OK", comment: "Dismiss the session-note error alert")
            }
        } message: {
            Text(noteError ?? "")
        }
    }

    // MARK: - Find in transcript

    /// Open the bar, having first worked out whether the counter can
    /// honestly claim to describe the whole session.
    private func openFind(seed: String? = nil) {
        evaluateHistoryScope()
        find.open(seed: seed)
    }

    /// Whether there is anything on screen to find in.
    ///
    /// Reads the runner's events WITHOUT observing it — this view
    /// deliberately does not (see the token counter's note), so the
    /// live half of this is a snapshot that refreshes on the next
    /// column re-render rather than per event. Good enough to gate a
    /// button; the transcript itself never depends on it.
    private var hasSearchableTranscript: Bool {
        !historicalItems.isEmpty || !(currentRunner?.events.isEmpty ?? true)
    }

    private var partialScopeNote: String {
        String(localized: "Only the loaded part of this session is being searched.",
               comment: "Find bar note when the transcript on screen is a bounded tail of the file")
    }

    /// The widen ladder: each rung re-reads the transcript with a
    /// bigger (still bounded) tail. The first rung is search's own
    /// budget; past the last, `historyTruncationNote` states what was
    /// left unread instead of a button that could not deliver. Budgets
    /// stay BOUNDS — "read it all" on a transcript that can run to
    /// hundreds of MB is the freeze `historyByteBudget` exists to
    /// prevent; the ceiling is a deliberate multiple of it that covers
    /// every session on a working machine.
    private static let historyWidenLadder = [
        SearchTextExtractor.searchByteBudget,
        256 * 1024 * 1024,
    ]

    /// The next rung above what is already loaded; nil at the ceiling.
    private var nextWidenBudget: Int? {
        Self.historyWidenLadder.first { $0 > historyLoadedBudget }
    }

    /// Older turns exist on disk AND a wider read can still fetch them
    /// — what keeps "Show earlier" offered past the loaded rows, and
    /// what the find bar's widen offer needs too. At the ladder's
    /// ceiling this is false while `historyPartial` stays true: the
    /// scope note still says partial, and an action that would re-read
    /// the same bytes is not offered.
    private var historyHasMore: Bool {
        historyPartial && nextWidenBudget != nil
    }

    /// The transcript, with its long init — its own builder because
    /// the main body's modifier chain sits at the type-checker's
    /// complexity limit, and this call is the heaviest expression in
    /// it.
    private func runnerStream(_ runner: AgentRunner) -> some View {
        RunnerStreamView(
            runner: runner,
            historicalItems: historicalItems,
            isLoadingHistory: isLoading,
            historyHasMore: historyHasMore,
            isWideningHistory: wideningHistory,
            historyTruncationNote: historyTruncationNote,
            onLoadEarlier: loadEarlierHistory,
            expandedToolResults: $expandedToolResults,
            expandedActivityLines: $expandedActivityLines,
            chatOnlyTurns: chatOnlyTurnHandles,
            compact: config.display.agentCompactView,
            draftCwd: draftCwdForEmptyState,
            draftCustomGroup: draftCustomGroup,
            emptySessionCommands: emptySessionCommands,
            assistantLabel: sessionAgentName,
            repositionNonce: repositionNonce,
            find: find,
            canBranch: canBranch,
            editingRowId: $editingRowId,
            editDraft: $editDraft,
            // The editor's button also waits while the chips hold a send
            // (`sendIsHeld`): a branch is made to be sent into, with those
            // chips, and the line above the composer says why it waits.
            branching: branching || sendIsHeld,
            onBeginEdit: { rowId, text, loadedSkills in
                beginMessageEdit(rowId: rowId, text: text, loadedSkills: loadedSkills)
            },
            onCreateBranch: { recordUuid, original, edited, skip in
                createSessionBranch(recordUuid: recordUuid, originalText: original,
                                    newText: edited, skippingNewer: skip)
            },
            onSendInPlace: { rowId, recordUuid, original, edited, skip in
                editSessionInPlace(rowId: rowId, recordUuid: recordUuid, originalText: original,
                                   newText: edited, skippingNewer: skip)
            },
            rewindSupport: rewindSupport,
            onCancelEdit: cancelMessageEdit,
            onModeAdopted: adoptSessionMode(_:),
            onImplementPlan: implementProposedPlan
        )
        // New structural identity per session: session switches
        // otherwise reuse the view (same type, same position), so
        // onAppear never re-fires and two sessions with equal capped
        // history counts kept each other's scroll offset instead of
        // landing at the newest turn.
        .id(runner.key)
        // Transcript text tracks the sidebar row size (13 pt at
        // Default) instead of the chat-content scale, so session text
        // never outsizes the session's own name.
        .environment(\.sipFontScale, SipFont.contentScale(fontScale))
        .environment(\.sipCodeFileTitle, codeFileTitle)
        // A reply's relative file links are read from the session's own
        // folder; `searchableRows` counts the same drawing.
        .environment(\.sipFileLinkBase, runner.cwd.path)
        // Compact view switched with this session open: the read on the
        // page kept the thoughts the old setting draws. Read it again, in
        // place — the history cache refuses an entry read the other way.
        .onChange(of: config.display.agentCompactView) { _, _ in
            if case .existing(_, let url, _, _) = mode {
                startHistoryLoad(url: url, viaSpinner: false)
            }
        }
    }

    /// What a code block's Save names the file after: the session's name
    /// as the sidebar lists it — a rename, else the scanner's title. A
    /// title that is only the session's id is no name.
    private var codeFileTitle: String? {
        guard case .existing(let id, _, _, let resolved) = mode else { return nil }
        if let custom = config.agentSessionDisplayName(for: id) { return custom }
        guard let session = resolved, session.title != session.id else { return nil }
        return session.title
    }

    /// Find bar with its widen offer — its own builder because the
    /// main body's modifier chain sits at the type-checker's
    /// complexity limit.
    @ViewBuilder
    private var findBarSection: some View {
        FindBar(find: find,
                scopeNote: historyPartial ? partialScopeNote : nil,
                widenTitle: historyHasMore
                    ? String(localized: "Search whole session",
                             comment: "Find bar action that re-reads the full transcript")
                    : nil,
                onWiden: historyHasMore ? widenHistoryForSearch : nil,
                widening: wideningHistory)
            .padding(.horizontal, 60)
            .padding(.bottom, 8)
            .transition(.opacity)
    }

    /// Is what is loaded the whole conversation?
    ///
    /// Two things mean "there is more": the 50-turn cap bit (initial
    /// opens only — every widen reads `maxTurns: .max`), or the read
    /// stopped short of the file's start — the walk's own word for a
    /// claude read (`historyReadReachedStart`), the file's size against
    /// the budget the rows were read with for codex and kimi.
    /// Evaluated at discrete moments — a load landing, a widen
    /// landing, the find bar opening — never per render: it stats the
    /// file, and a body that touches the filesystem runs on every
    /// streamed event.
    private func evaluateHistoryScope() {
        guard case .existing(_, let url, _, _) = mode else {
            historyPartial = false
            historyTruncationNote = nil
            return
        }
        updateHistoryScope(items: historicalItems,
                           fileSize: Self.fileStat(url)?.size ?? 0)
    }

    /// One verdict, shared by the find bar's scope note and the
    /// transcript's "Show earlier" — asked two ways they drift, and a
    /// counter's caveat ends up disagreeing with the button under it.
    private func updateHistoryScope(items: [AgentSessionHistoryItem],
                                    fileSize ownSize: UInt64) {
        let capBit: Bool
        if historyTurnCapApplies {
            let turns = items.reduce(into: 0) { total, item in
                if case .userText = item.kind { total += 1 }
            }
            capBit = turns >= 50
        } else {
            capBit = false
        }
        // A codex branch is read in two bounded halves — the inherited
        // prefix out of its parent, then its own file — each held to
        // the budget on its own. Judged on the SUM, two halves that
        // both fit would offer a "Show earlier" that reveals nothing;
        // judged on the own file alone, a long inherited prefix bounded
        // by the read would pass for the whole conversation.
        let budget = UInt64(historyLoadedBudget)
        let ownUnread = historyReadReachedStart.map { !$0 } ?? (ownSize > budget)
        historyPartial = capBit || ownUnread || inheritedHistoryBytes > budget
        let fileSize = ownSize + inheritedHistoryBytes
        // The one state "Show earlier" cannot help: ladder exhausted,
        // file still bigger than the widest read. Say so, with the
        // sizes — a bound the reader cannot see reads as "this is the
        // whole session" (the no-silent-caps rule).
        if historyPartial, nextWidenBudget == nil {
            let total = ByteCountFormatter.string(
                fromByteCount: Int64(fileSize), countStyle: .file)
            let shown = ByteCountFormatter.string(
                fromByteCount: Int64(historyLoadedBudget), countStyle: .file)
            historyTruncationNote = String(
                localized: "Earlier turns aren't loaded — this session's transcript is \(total) and the newest \(shown) are shown.",
                comment: "Static note atop a transcript too big to load whole; placeholders are the file size and the loaded size")
        } else {
            historyTruncationNote = nil
        }
    }

    /// "Show earlier" ran out of loaded rows with the session's start
    /// still on disk: climb one rung.
    private func loadEarlierHistory() {
        guard let next = nextWidenBudget else { return }
        widenHistory(toBudget: next)
    }

    /// The find bar's "Search whole session" — the same climb, so the
    /// two features cannot hold two ideas of what is loaded.
    private func widenHistoryForSearch() {
        guard let next = nextWidenBudget else { return }
        widenHistory(toBudget: next)
    }

    /// Re-read the transcript with a bigger (still bounded) budget and
    /// swap it in.
    ///
    /// Deliberately NOT written into `AgentHistoryCache`: that cache
    /// feeds every ordinary open, and seeding it with a near-whole-file
    /// read would make every later visit to this session pay for one
    /// click.
    ///
    /// No jump afterwards, on purpose. The re-read mints fresh row ids,
    /// so a find's active match cannot be preserved by identity (and
    /// expanded tool chips collapse); sending the reader anywhere would
    /// render every row between here and there. The counter updates;
    /// ↑ walks back one match — and one window growth — at a time, and
    /// "Show earlier" reveals the next 200 rows above the top exactly
    /// as an ordinary reveal does.
    ///
    /// It lands through `adoptHistory` like an ordinary load: the re-read
    /// holds every turn the live buffer has drawn since the session was
    /// opened — the running one included — and keeping both draws those
    /// turns twice.
    private func widenHistory(toBudget budget: Int) {
        guard case .existing(_, let url, _, _) = mode, !wideningHistory,
              budget > historyLoadedBudget else { return }
        wideningHistory = true
        let agentKey = sessionAgentKey
        // The same thoughts rule as an ordinary load (`startHistoryLoad`).
        let chatOnlyTurns = chatOnlyTurnHandles
        let allThoughts = config.display.agentCompactView
        let withThoughts = allThoughts || !chatOnlyTurns.isEmpty
        let wordlessFailure = AgentAskingMode.wordlessFailureMessage(agentName: sessionAgentName)
        let turnAtRead = currentRunner?.status.runningSince
        Task {
            let (items, reachedStart) = await Task.detached(priority: .userInitiated) {
                () -> ([AgentSessionHistoryItem], Bool?) in
                let read: [AgentSessionHistoryItem]
                var reached: Bool? = nil
                switch agentKey {
                case "codex":
                    read = CodexSessionScanner.readHistory(
                        of: url, maxTurns: .max, byteBudget: budget,
                        includeThinking: withThoughts)
                case "kimi":
                    read = KimiSessionScanner.readHistory(
                        of: url, maxTurns: .max, byteBudget: budget,
                        includeThinking: withThoughts, wordlessFailure: wordlessFailure)
                case "claude_code":
                    let reading = AgentSessionScanner.readHistoryReaching(
                        of: url, maxTurns: .max, byteBudget: budget,
                        includeThinking: withThoughts)
                    read = reading.items
                    reached = reading.reachedStart
                default:
                    // No reader for this agent's transcript: no rows.
                    read = []
                }
                return (Self.keepingThoughts(read, all: allThoughts, in: chatOnlyTurns), reached)
            }.value
            // The user may have switched sessions mid-read.
            guard case .existing(_, let current, _, _) = mode, current == url else {
                wideningHistory = false
                return
            }
            wideningHistory = false
            // The same rule as an ordinary load: a turn that ended during
            // the read may be cut short in it.
            if TranscriptSeam.readIsStale(turnStartAtRead: turnAtRead,
                                          turnStartNow: currentRunner?.status.runningSince) {
                widenHistory(toBudget: budget)
                return
            }
            // A failed read keeps what is on screen; partiality stays
            // true, so the button remains and a later click retries.
            guard !items.isEmpty else { return }
            adoptHistory(items, fromFile: true)
            historyLoadedBudget = budget
            historyTurnCapApplies = false
            historyReadReachedStart = reachedStart
            updateHistoryScope(items: items,
                               fileSize: Self.fileStat(url)?.size ?? 0)
        }
    }

    /// Adopt a query handed over by a global-search result.
    ///
    /// Deferred one runloop turn: the route that carried it may still
    /// be settling, and `reload()` closes the find on a real switch —
    /// this has to land after that, not before it.
    private func consumePendingFind() {
        guard let query = appState.pendingFindQuery, !query.isEmpty else { return }
        guard appState.openAgentSessionId != nil else { return }
        appState.pendingFindQuery = nil
        DispatchQueue.main.async {
            openFind(seed: query)
            find.requestJump()
        }
    }

    // MARK: - Session note generation

    /// Conversation-shaped view of the session: user prompts and
    /// assistant narration from the loaded history plus this run's live
    /// events (the two never overlap: every read leaves the live buffer
    /// only what it does not hold — `adoptHistory`). Tool calls/outputs are
    /// deliberately omitted; the narration already describes what was
    /// done, which is what a summary note needs.
    private func sessionTranscriptMessages() -> [ChatMessage] {
        var msgs: [ChatMessage] = []
        for item in historicalItems {
            switch item.kind {
            case .userText(let t):
                msgs.append(ChatMessage(role: "user", content: t))
            case .assistantText(let t):
                msgs.append(ChatMessage(role: "assistant", content: t))
            default:
                break
            }
        }
        if let events = currentRunner?.events {
            for event in events {
                switch event.kind {
                case .userMessage(let t):
                    msgs.append(ChatMessage(role: "user", content: t))
                case .assistantText(let t):
                    msgs.append(ChatMessage(role: "assistant", content: t))
                default:
                    break
                }
            }
        }
        return msgs
    }

    private var canGenerateSessionNote: Bool {
        guard config.noteGeneratingModel ?? appState.activeModel ?? config.defaultModel != nil
        else { return false }
        return !historicalItems.isEmpty || !(currentRunner?.events.isEmpty ?? true)
    }

    /// Mirror of ChatView.generateNote for agent sessions: summarize the
    /// transcript with the configured note model and open the result.
    /// `extraPrompt` (the note-prompt box) rides along in the generation
    /// request and is recorded in the note's metadata.
    private func generateSessionNote(extraPrompt: String? = nil) {
        guard !noteGenerating else { return }
        let msgs = sessionTranscriptMessages()
        guard !msgs.isEmpty else {
            noteError = String(
                localized: "Nothing to summarise — the session has no messages yet.",
                comment: "Session-note error for an empty transcript")
            return
        }
        guard let modelId = config.noteGeneratingModel
                ?? appState.activeModel ?? config.defaultModel else {
            noteError = String(
                localized: "No chat model configured. Add one in Settings → Chat Settings.",
                comment: "Session-note error when no model exists")
            return
        }

        noteGenerating = true
        var transcript = NotesManager.formatTranscript(
            msgs,
            userLabel: config.display.userLabel,
            aiLabel: sessionAgentName)
        let extra = extraPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let extra, !extra.isEmpty {
            transcript += "\n\nAdditional instructions from the user for this note: \(extra)"
        }
        let sourceTitle = String(
            localized: "\(sessionAgentName) session",
            comment: "Source label recorded on notes generated from an agent session")
        let snapshot = [ChatMessage(role: "user", content: transcript)]
        let client = APIClient(config: config)

        Task { @MainActor in
            do {
                let result = try await client.sendChat(
                    messages: snapshot,
                    modelId: modelId,
                    systemPrompt: NotesManager.notePromptSystem
                )
                noteGenerating = false
                if let stored = notesManager.createNote(
                    content: result.text,
                    sourceTitle: sourceTitle,
                    modelId: modelId,
                    extraInstructions: extra
                ) {
                    appState.openNoteId = stored.id
                } else {
                    noteError = String(
                        localized: "Failed to write note to disk.",
                        comment: "Session-note error when persistence fails")
                }
            } catch {
                noteGenerating = false
                noteError = error.localizedDescription
            }
        }
    }

    private var inputPlaceholder: String {
        if case .empty = mode { return "" }
        // Chat only: the box invites a conversation, not a task.
        if chatOnlyInForce {
            return String(localized: "Chat with \(sessionAgentName)…",
                          comment: "Input placeholder while the mode chip is on Chat only; placeholder is the agent label")
        }
        switch mode {
        case .draft:
            return String(localized: "Describe a task for \(sessionAgentName)…",
                          comment: "Input placeholder in draft mode")
        case .existing:
            return String(localized: "Send a message to \(sessionAgentName)…",
                          comment: "Input placeholder for an existing session")
        case .empty:
            return ""
        }
    }

    /// Chat only as it APPLIES: the chip's pick, where the installed CLI
    /// offers the row (`ChatOnlyGate`). Below the gate a saved pick is
    /// ignored — the composer shows Default, and `sendOptions` sends
    /// Default — so the two cannot disagree.
    private var chatOnlyInForce: Bool {
        launchOptions.chatOnly && ChatOnlyGate.offered(agentKey: sessionAgentKey)
    }

    /// Why an image cannot go in this session's Chat only message, or nil
    /// where it can. A Chat only image rides each agent's own image
    /// channel (claude stream-json, codex `-i`, kimi's server) — every
    /// agent but a RESUMED kimi turn, which is `--prompt --session` and
    /// has no image input. So a kimi session that already exists refuses
    /// an image up front, where the refusal is a choice rather than a
    /// send that silently sent the words alone. Outside Chat only an
    /// image is a path like any other file, and the agent opens it.
    private func chatOnlyImageRefusal(_ name: String) -> String? {
        guard sessionAgentKey == "kimi", !ChatOnlyImages.kimiResumeAcceptsImages,
              case .existing = mode else { return nil }
        return String(localized: "\(name) — an image can only be attached to a NEW \(sessionAgentName) chat. Start one, or attach a text file or a PDF.",
                      comment: "Image refused on a resumed kimi session; placeholders are the file name and the agent label")
    }

    // MARK: - Skills

    /// The robot chip, on every agent. Kimi's headless turn cannot load
    /// a skill by name, so a Kimi turn that loads one runs through
    /// kimi's own front end, whatever the mode (`AgentTurnDriver.pick`)
    /// — one skill per message (`SkillAgent.oneSkillPerMessage`).
    private var showsSkillChip: Bool {
        SkillAgent.all.contains(sessionAgentKey)
    }

    /// The skills chosen on this session's chip — a draft's until its
    /// first send, the session's own after. A draft whose own picks are
    /// untouched shows what was set at its place
    /// (`AppState.newSessionSkillPicks`: the draft itself is dropped the
    /// moment anything else opens), else the agent's pinned skills. Never
    /// what another session chose: skills load into the conversation, and
    /// a new session started with another's would load them unasked.
    private var skillPicks: [String] {
        switch mode {
        case .draft(let d):
            return d.skillPicks
                ?? appState.newSessionSkillPicks(for: newSessionStoreKey(d))
                ?? config.agentSkillPreloads(for: d.agentKey)
        case .existing(let id, _, _, _): return config.agentSessionSkillPicks(for: id) ?? []
        case .empty: return []
        }
    }

    private func setSkillPicks(_ picks: [String]) {
        switch mode {
        case .draft(let d):
            appState.pendingClaudeSessionDraft?.skillPicks = picks
            // Kept for the next new session started from the same + until
            // the first message goes — after that they are this session's,
            // filed with it when its session id arrives.
            if isDraftBeforeFirstSend {
                appState.setNewSessionSkillPicks(picks, for: newSessionStoreKey(d))
            } else if let draft = appState.pendingClaudeSessionDraft {
                agents.noteSentDraft(draft)
            }
        case .existing(let id, _, _, _): config.setAgentSessionSkillPicks(picks, for: id)
        case .empty: return
        }
        SkillCatalog.shared.ensurePicksReadable(picks, agent: sessionAgentKey, folder: composerFolder)
    }

    /// The unsent new session on screen — its id, and where what was set
    /// up on it waits — or nil. Read when the composer's closures are
    /// made: a task made from it lands after its file is written, when
    /// the page may show another conversation.
    private var unsentNewSession: (id: UUID, key: String)? {
        guard case .draft(let d) = mode, isDraftBeforeFirstSend else { return nil }
        return (d.id, newSessionStoreKey(d))
    }

    /// A task made from an unsent new session took the skills its runs
    /// load, as it took the message and the schedule: they are the task's
    /// now. Left ticked, they would be on the next new session from the
    /// same +, as if carried over from the task. Its chips stay, as they
    /// would for any new session started there.
    private func useUpNewSessionSkills(_ unsent: (id: UUID, key: String)) {
        appState.setNewSessionSkillPicks(nil, for: unsent.key)
        if appState.pendingClaudeSessionDraft?.id == unsent.id {
            appState.pendingClaudeSessionDraft?.skillPicks = nil
        }
    }

    private static func skillMark(_ item: AgentSessionHistoryItem) -> SkillTranscriptMark? {
        switch item.kind {
        case .userText(let text) where !item.isSystemNotice:
            return .user(text: text, loadedSkills: item.loadedSkills)
        case .toolUse(_, let name, let input):
            return .tool(name: name, input: input)
        case .compaction:
            return .compaction(keepsUserLoads: item.compactionKeepsUserMessages)
        default:
            return nil
        }
    }

    private static func skillMark(_ event: StreamEvent) -> SkillTranscriptMark? {
        switch event.kind {
        case .userMessage(let text) where !event.isSystemNotice:
            return .user(text: text, loadedSkills: event.loadedSkills)
        case .toolUse(_, let name, let input):
            return .tool(name: name, input: input)
        case .compaction:
            return .compaction(keepsUserLoads: event.compactionKeepsUserMessages)
        case .assistantText, .thinking, .toolResult, .result:
            // The agent answered: what was sent before this reached it.
            return .answered
        default:
            return nil
        }
    }

    /// The live buffer's marks. A live row is drawn when Send is pressed,
    /// so only a message the agent answered counts — or the one whose
    /// turn is running now (`SkillEvidenceReader.delivered`).
    private func liveSkillMarks(_ events: [StreamEvent]) -> [SkillTranscriptMark] {
        SkillEvidenceReader.delivered(events.compactMap(Self.skillMark),
                                      turnInFlight: currentRunner?.status.isRunning ?? false)
    }

    /// What the conversation shows about its skills: the loaded
    /// history, then what this launch's turns added. Read at the moment
    /// it is needed, never per render.
    private func skillEvidence() -> [SkillEvidence] {
        var marks = historicalItems.compactMap(Self.skillMark)
        marks += liveSkillMarks(currentRunner?.events ?? [])
        return SkillEvidenceReader.evidence(marks, agent: sessionAgentKey)
    }

    /// The same, for a branch cut at the row whose handle is `cut` — or,
    /// for a live row, at the first live message reading `originalText`.
    private func skillEvidence(above cut: String, originalText: String) -> [SkillEvidence] {
        var marks: [SkillTranscriptMark] = []
        for item in historicalItems {
            if case .userText = item.kind, item.recordUuid == cut {
                return SkillEvidenceReader.evidence(marks, agent: sessionAgentKey)
            }
            if let mark = Self.skillMark(item) { marks.append(mark) }
        }
        let wanted = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        var above: [StreamEvent] = []
        for event in currentRunner?.events ?? [] {
            if case .userMessage(let text) = event.kind, !event.isSystemNotice,
               text.trimmingCharacters(in: .whitespacesAndNewlines) == wanted { break }
            above.append(event)
        }
        marks += liveSkillMarks(above)
        return SkillEvidenceReader.evidence(marks, agent: sessionAgentKey)
    }

    /// The chosen skills one send loads: those the conversation does not
    /// hold, loadable here — none in Chat only, and none with a claude
    /// or kimi message that opens on a command of its own (the chosen
    /// ones wait for the next message).
    /// A command, by the one rule that tells one from a pasted path
    /// (`AgentSlashCommands.leadingCommand`): `/Users/me/notes.md` is
    /// the user's own words, and its message loads what is chosen.
    private func skillTriggers(for text: String, options: AgentLaunchOptions,
                               evidence: [SkillEvidence]) -> [SkillTrigger] {
        guard showsSkillChip, !options.chatOnly else { return [] }
        let picks = skillPicks
        guard !picks.isEmpty else { return [] }
        // A message that opens on a command of its own: claude takes one
        // leading command, kimi's front end one leading `/skill:` — the
        // chosen ones wait for the next message.
        if sessionAgentKey == SkillAgent.claude || sessionAgentKey == SkillAgent.kimi,
           AgentSlashCommands.leadingCommand(in: text) != nil { return [] }
        // A claude known to be older than the one the batch was measured
        // on is sent none — also before the folder's skills are read,
        // when no list is there yet to carry the reason.
        if sessionAgentKey == SkillAgent.claude, SkillCatalog.claudeBatchRefusal() != nil { return [] }
        // Kimi loads a skill only through its own front end: until the
        // installed kimi is known to have one, a pick waits.
        let frontEnd = AskingModeGate.frontEnd(agentKey: sessionAgentKey)
        if sessionAgentKey == SkillAgent.kimi, frontEnd != .offered { return [] }
        let catalog = SkillCatalog.shared
        let choices = catalog.snapshot(folder: composerFolder) == nil
            ? nil : catalog.choices(
                agent: sessionAgentKey, folder: composerFolder,
                codexSend: AskingModeGate.subfolderSkillSend(
                    agentKey: sessionAgentKey, mode: options.permissionMode,
                    chatOnly: options.chatOnly))
        return SkillPickReport.triggers(picks: picks, choices: choices, evidence: evidence,
                                        sendsUnread: sessionAgentKey == SkillAgent.claude,
                                        onePerMessage: SkillAgent.oneSkillPerMessage(sessionAgentKey))
    }

    /// What a send actually runs with: the chips, with a Chat only pick
    /// the gate refuses cleared — and, for codex, the speed resolved to
    /// the `-c service_tier=` this send passes. Resolved HERE, per send
    /// and never persisted: the chip's Default follows codex's own
    /// config for this folder and the model's catalog default as they
    /// stand now. A scheduled run is the other resolution: it passes the
    /// task's own pick verbatim, or nothing, so a task with no speed runs
    /// at what `codex exec` resolves by itself (`AgentLaunchOptions
    /// .scheduledRun`).
    private var sendOptions: AgentLaunchOptions {
        var options = launchOptions
        if options.chatOnly && !chatOnlyInForce { options.chatOnly = false }
        if sessionAgentKey == "codex" {
            options.codexServiceTierOverride = CodexCatalog.shared
                .serviceTierOverride(for: options, folder: composerFolder.path)
        }
        return options
    }

    // MARK: - Attachments

    /// Stage files for the next message. The + and a drop both come here,
    /// so both refuse the same things in the same words
    /// (`AgentAttachment.staging`): outside Chat only a file is a path the
    /// agent reads itself; in Chat only it is read, decoded and measured
    /// now, by the chat page's rules.
    private func stageAttachments(_ urls: [URL]) {
        let before = stagedAttachments.count
        let result = AgentAttachment.staging(urls, onto: stagedAttachments,
                                             chatOnly: chatOnlyInForce,
                                             imageRefusal: chatOnlyImageRefusal)
        stagedAttachments = result.staged
        attachmentNotice = attachNotice(refused: result.refused,
                                        staged: result.staged.count > before)
        attachmentNoticeIsChatOnly = chatOnlyInForce
    }

    /// Files staged as paths while Chat only is in force, for the session
    /// they were staged in. Whatever makes it true — the chip moved to
    /// Chat only, the Chat only gate read at last, a session opened with
    /// its files waiting — they are read at once. Before the composer has
    /// taken the incoming session's files (`loadedDraftKey`), the staged
    /// files are still the outgoing session's, and are not this mode's.
    private var stagedPathsAwaitChatOnly: Bool {
        chatOnlyInForce && transcriptKey != nil && loadedDraftKey == transcriptKey
            && stagedAttachments.contains { $0.loaded == nil }
    }

    /// Chat only is in force: each file staged as a path is read now, and
    /// one that cannot travel in a Chat only message comes off with its
    /// reason. Answers whether every staged file could stay.
    @discardableResult
    private func loadStagedFilesForChatOnly() -> Bool {
        guard stagedAttachments.contains(where: { $0.loaded == nil }) else { return true }
        let result = AgentAttachment.loadingForChatOnly(stagedAttachments,
                                                        imageRefusal: chatOnlyImageRefusal)
        stagedAttachments = result.staged
        attachmentNotice = attachNotice(refused: result.refused, staged: true)
        attachmentNoticeIsChatOnly = true
        return result.refused.isEmpty
    }

    /// The note above the composer: what was turned away, and — the chips
    /// being the receipt for the rest — the one thing a chip cannot show,
    /// that a file was cut short.
    private func attachNotice(refused: [String], staged: Bool) -> String? {
        var notes: [String] = []
        if !refused.isEmpty { notes.append(refused.joined(separator: "\n")) }
        if staged {
            let cut = stagedAttachments.compactMap(\.loaded).filter { $0.textTruncated }
            if !cut.isEmpty {
                let byCap = Dictionary(grouping: cut) { a in
                    if case .pdf = a.kind { return AttachmentLimits.pdfTextCharLimit }
                    return AttachmentLimits.textCharLimit
                }
                notes.append(byCap.sorted { $0.key < $1.key }.map { cap, files in
                    String(
                        localized: "Only the first \(cap / 1000)k characters of \(files.map(\.name).joined(separator: ", ")) are sent.",
                        comment: "Banner: an attached file was truncated to the inline limit")
                }.joined(separator: "\n"))
            }
        }
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }

    private func removeAttachment(_ id: UUID) {
        stagedAttachments.removeAll { $0.id == id }
    }

    /// The message as the agent receives it. Outside Chat only: the user's
    /// words, then one path marker per file — the agent reads the files
    /// itself. In Chat only: one inlined block per file ahead of the
    /// words, exactly as the chat page composes it. Either way the
    /// transcript strips the markers back out and names the files on the
    /// paperclip line (`AttachmentInline`).
    private func outgoingText(for text: String, chatOnly: Bool) -> String {
        guard chatOnly else {
            return AttachmentInline.appendingReferences(stagedAttachments.map(\.reference),
                                                        to: text)
        }
        let blocks = stagedAttachments.compactMap(\.loaded).compactMap { a -> String? in
            if case .image = a.kind {
                // An image's bytes go a side channel; only its NAME
                // rides the text, so the bubble and a reopened
                // transcript name it the way a text attachment is named.
                return AttachmentInline.imageMarker(name: a.name)
            }
            guard let t = a.text, !t.isEmpty else { return nil }
            return ChatAttachment.inlineBlock(name: a.name, text: t,
                                              truncated: a.textTruncated)
        }
        guard !blocks.isEmpty else { return text }
        return blocks.joined(separator: "\n\n") + "\n\n" + text
    }

    /// The staged images, resolved to the payload the runner's image
    /// channels need — a Chat only send's alone. Text rides the body.
    private func outgoingImages() -> [AgentImage] {
        stagedAttachments.compactMap(\.loaded).compactMap { a in
            guard case .image(let mediaType) = a.kind, let b64 = a.base64 else { return nil }
            return AgentImage(name: a.name, base64: b64, mediaType: mediaType)
        }
    }

    /// Whether a send from this session must wait on the chips as they
    /// stand: a saved Chat only pick whose gate has not been read — unread,
    /// the gate answers false, and `sendOptions` would clear the pick and
    /// run an agent turn — or an asking pick the installed CLI cannot run
    /// yet, or at all (`AskingModeGate`): held, never sent as a mode that
    /// does not ask.
    ///
    /// EVERY send this view makes asks it, not the composer's alone: a
    /// branch's first message and "Implement this plan" run with the same
    /// chips, and one that skipped it would run the turn the composer is
    /// refusing to.
    private var sendIsHeld: Bool {
        if launchOptions.chatOnly, !ChatOnlyGate.settled(agentKey: sessionAgentKey) { return true }
        return AskingModeGate.hold(agentKey: sessionAgentKey, mode: launchOptions.permissionMode,
                                   chatOnly: launchOptions.chatOnly) != nil
    }

    private func handleSend() {
        // While the message editor's Send or Create Branch is under way the
        // session is not this message's: Send may be taking it back to an
        // earlier message, and a turn started under it would race the cut.
        if branching { return }
        // The composer holds this send already (`chatOnlyPending`, its
        // asking hold); this is the backstop.
        if sendIsHeld { return }
        // Codex's own `/compact` and `/review`, typed alone: run as its
        // terminal runs them, never sent to the model as words.
        // A `!` command: run as the agent's terminal runs one, or held
        // above the box while a turn of ours runs (`ShellCommands`). One
        // the installed tool cannot run yet waits, as the composer says.
        if let command = typedShellCommand {
            switch command.verdict {
            case .runs:
                startShellCommand(command.line)
                return
            case .pending, .needsNewer:
                return
            case .noRoute:
                break
            }
        }
        if let command = typedCodexCommand {
            switch command {
            case .compact:
                startCodexCommand(.compact,
                                  label: inputDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                  clearsBox: true)
            case .review:
                // The picker takes the command's place, as in codex's
                // terminal: closed with ×, the box is empty.
                inputDraft = ""
                stashComposerDraft()
                reviewPickerOpen = true
            }
            return
        }
        let typed = inputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var sending = sendOptions
        // A file staged as a path cannot travel in a Chat only message,
        // and the chip can come to rest on Chat only without this view
        // seeing it turn (a saved pick whose gate was read meanwhile). So
        // the files are read here too; one that cannot go comes off with
        // its reason, and the message waits for the user to read it.
        if sending.chatOnly, !loadStagedFilesForChatOnly() { return }
        let attaching = stagedAttachments
        guard !typed.isEmpty || !attaching.isEmpty, agentIsListed else { return }
        let text = attaching.isEmpty ? typed
            : outgoingText(for: typed, chatOnly: sending.chatOnly)
        let images = sending.chatOnly ? outgoingImages() : []
        sending.skillTriggers = skillTriggers(for: typed, options: sending,
                                              evidence: skillEvidence())

        // Draft: the runner is created here, on first send, so it
        // captures the folder the composer shows right now — and the
        // skills its chip goes out with, the agent's defaults when the
        // user chose none, which `migrateRunner` files under the id.
        let runner: AgentRunner?
        switch mode {
        case .draft(var d):
            if d.skillPicks == nil {
                d.skillPicks = skillPicks
                appState.pendingClaudeSessionDraft?.skillPicks = d.skillPicks
            }
            runner = agents.runner(forDraft: d)
        case .existing, .empty:
            runner = currentRunner
        }
        guard let runner = runner else { return }

        // A turn of ours runs: the message waits above the box until it
        // is steered into the turn, or the turn ends (`HeldMessage`).
        if runner.status.isRunning {
            if runner.hold(text: text, options: sending, images: images,
                           boxText: typed, boxFiles: attaching.map(\.url)) {
                clearSentComposer(clearsAttachments: !attaching.isEmpty)
                recordSentOptions()
            }
            return
        }
        if runner.send(text: text, options: sending, images: images) {
            // The session is demonstrably alive again — a stale
            // load-time marker must not sit between the old turn and
            // this new one.
            dropInterruptedMarker()
            clearSentComposer(clearsAttachments: !attaching.isEmpty)
            useUpNewSession()
            recordSentOptions()
        }
    }

    /// The box after a message went — sent, or held above the box. The
    /// stashed copy goes too, or switching away and back would resurrect
    /// the just-sent text into the composer.
    private func clearSentComposer(clearsAttachments: Bool) {
        inputDraft = ""
        if clearsAttachments {
            stagedAttachments = []
            attachmentNotice = nil
        }
        stashComposerDraft()
        stashComposerAttachments()
    }

    /// × on a message held above the box: it goes nowhere, and what the
    /// box held when it was sent comes back to be changed — its words ahead
    /// of anything typed since, its files staged again as the + stages them
    /// (one staged since is not doubled; one gone since is refused, with
    /// the reason above the box).
    private func takeBackHeld(_ id: UUID) {
        guard let runner = currentRunner, let message = runner.takeBackHeld(id) else { return }
        inputDraft = message.boxText(over: inputDraft)
        if !message.boxFiles.isEmpty { stageAttachments(message.boxFiles) }
        stashComposerDraft()
        stashComposerAttachments()
    }

    /// A new session's first message uses up what was set up for it beside
    /// the text: its skills went with it and are the session's now, and a
    /// schedule left unarmed has nothing left to schedule. The next new
    /// session starts afresh.
    private func useUpNewSession() {
        guard case .draft(let d) = mode else { return }
        // Its chips go on with it (`sentOptions`), as its skills do — and
        // to the manager, which files them under the session id when it
        // arrives, whichever page is on screen by then.
        appState.pendingClaudeSessionDraft?.sentOptions = launchOptions
        if let sent = appState.pendingClaudeSessionDraft { agents.noteSentDraft(sent) }
        appState.setNewSessionSkillPicks(nil, for: newSessionStoreKey(d))
        appState.setNewSessionChipEdits(nil, for: newSessionStoreKey(d))
        scheduleDraft = ScheduleDraft()
        stashComposerSchedule()
    }

    /// Record what this session runs with. Persisting what each send used
    /// means the transcript guess in `seedLaunchOptions` is only ever
    /// needed for a session this app has never driven.
    private func recordSentOptions() {
        if case .existing(let id, _, _, _) = mode {
            config.setAgentSessionLaunchOptions(launchOptions, for: id)
        }
    }

    /// The `!` command the box holds, and what Send does with it — the rule
    /// the composer's hint follows (`ShellCommandRoute`). A message with
    /// files staged is a message.
    private var typedShellCommand: (line: String, verdict: ShellCommandVerdict)? {
        guard stagedAttachments.isEmpty,
              let line = ShellCommandInput.command(in: inputDraft),
              let verdict = ShellCommandRoute.verdict(agentKey: sessionAgentKey) else { return nil }
        return (line, verdict)
    }

    /// Run a `!` command now, or hold it above the box while a turn of ours
    /// runs — it never goes into a turn. Nothing runs under another
    /// process's turn on the session.
    private func startShellCommand(_ command: String) {
        guard agentIsListed, !branching, !sendIsHeld else { return }
        let runner: AgentRunner?
        switch mode {
        case .draft(var d):
            if d.skillPicks == nil {
                d.skillPicks = skillPicks
                appState.pendingClaudeSessionDraft?.skillPicks = d.skillPicks
            }
            runner = agents.runner(forDraft: d)
        case .existing, .empty:
            runner = currentRunner
        }
        guard let runner else { return }
        let options = sendOptions
        if runner.status.isRunning {
            if runner.hold(text: ShellCommandInput.display(command), options: options,
                           shellCommand: command) {
                clearSentComposer(clearsAttachments: false)
                recordSentOptions()
            }
            return
        }
        guard !runner.externalInProgress,
              runner.runShellCommand(command, options: options) else { return }
        dropInterruptedMarker()
        clearSentComposer(clearsAttachments: false)
        useUpNewSession()
        recordSentOptions()
    }

    /// Codex's own command the box holds, typed alone: `/compact` on a
    /// session that has a conversation to summarise, `/review` outside Chat
    /// only (a review reads the folder). Through codex's app-server, so
    /// where the installed codex has one; the composer's hint follows the
    /// same rule.
    private var typedCodexCommand: CodexCommand? {
        guard sessionAgentKey == "codex", stagedAttachments.isEmpty,
              AskingModeGate.frontEnd(agentKey: sessionAgentKey) == .offered,
              let command = CodexCommand.parse(inputDraft) else { return nil }
        switch command {
        case .compact: return isDraftBeforeFirstSend ? nil : .compact
        case .review: return chatOnlyInForce ? nil : .review
        }
    }

    /// Run one of codex's own commands now, or hold it above the box while
    /// a turn runs, where it reads as `label` until it runs. False when it
    /// went nowhere.
    @discardableResult
    private func startCodexCommand(_ command: CodexCommandTurn, label: String, clearsBox: Bool) -> Bool {
        guard agentIsListed, !branching, !sendIsHeld else { return false }
        let runner: AgentRunner?
        switch mode {
        case .draft(var d):
            if d.skillPicks == nil {
                d.skillPicks = skillPicks
                appState.pendingClaudeSessionDraft?.skillPicks = d.skillPicks
            }
            runner = agents.runner(forDraft: d)
        case .existing, .empty:
            runner = currentRunner
        }
        guard let runner else { return false }
        let options = sendOptions
        if runner.status.isRunning {
            // What × on the held command puts back in the box: the command
            // as it was typed — a review is picked after typing `/review`.
            let typed: String
            if case .review = command { typed = "/review" } else { typed = label }
            guard runner.hold(text: label, options: options,
                              codexCommand: command, boxText: typed) else { return false }
            if clearsBox { clearSentComposer(clearsAttachments: false) }
            return true
        }
        guard !runner.externalInProgress,
              runner.runCodexCommand(command, options: options) else { return false }
        dropInterruptedMarker()
        if clearsBox { clearSentComposer(clearsAttachments: false) }
        useUpNewSession()
        recordSentOptions()
        return true
    }

    /// "Yes, implement in …" on a finished codex Plan turn: as codex's
    /// terminal does it — the session leaves Plan for the mode the answer
    /// names (Default, codex's own default setting; Workspace Write; Full
    /// Access for a session that was in it), for this session alone, and
    /// codex's own words for it are sent. What the user is typing in the
    /// composer stays there.
    ///
    /// The card names the mode, so the chip goes to it from wherever it
    /// has been moved since the plan — Chat only included. And it is
    /// answered only by a message that WENT (`send` takes the card down):
    /// while the turn cannot be sent — another process mid-turn on the
    /// thread — the card stays up and the chip stays put, rather than a
    /// click that takes the offer away and sends nothing.
    private func implementProposedPlan(mode spelling: String) {
        let target: String? = spelling == AgentAskingMode.adoptDefault ? nil : spelling
        guard let runner = currentRunner, agentIsListed, !branching,
              !runner.status.isRunning, !runner.externalInProgress,
              AskingModeGate.hold(agentKey: sessionAgentKey, mode: target, chatOnly: false) == nil
        else { return }
        var next = launchOptions
        // One writer for both fields — see `ChatOnlyMode.select`.
        ChatOnlyMode.select(target, into: &next)
        // For this session alone, as a card's mode switch is
        // (`adoptSessionMode`) — never the agent's sticky pick.
        applySeededOptions(next)
        var sending = sendOptions
        sending.skillTriggers = skillTriggers(for: CodexAppServer.implementPlanMessage,
                                              options: sending, evidence: skillEvidence())
        if runner.send(text: CodexAppServer.implementPlanMessage, options: sending) {
            dropInterruptedMarker()
        }
        if case .existing(let id, _, _, _) = mode {
            config.setAgentSessionLaunchOptions(launchOptions, for: id)
        }
    }

    // MARK: - Branching from an earlier message

    /// Whether the transcript offers the branch pencil at all.
    ///
    /// Only a real, writable session can be branched: a draft has no
    /// transcript to cut, and a session with a turn in flight — ours,
    /// or another terminal's where that is known — is being APPENDED TO
    /// right now, so any prefix copied would be a guess about where the
    /// conversation ends.
    ///
    /// Every agent, under one rule. Each has its own writer
    /// (`AgentSessionFork`, `CodexSessionFork`, `KimiSessionFork`) and
    /// `createSessionBranch` dispatches on the AGENT, never on a probe
    /// at click time. `externalInProgress` is fed by the tailer for all
    /// three — for a session this app has a runner for — so the pencil
    /// goes down through a turn another process is running, where a
    /// kimi cut would land above the live tail and codex refuses to
    /// fork through a turn that is still running.
    private var canBranch: Bool {
        guard case .existing = mode, agentIsListed,
              AgentSessionFork.hasWriter(agentKey: sessionAgentKey) else { return false }
        guard let runner = currentRunner else { return false }
        return !runner.status.isRunning && !runner.externalInProgress
    }

    /// `loadedSkills`: the skills the row names under its words. A kimi
    /// message the user opened on a skill command of their own
    /// (`/skill:name words`) is drawn as its words with the skill under
    /// them, as a message the chip loaded one with is — but that command
    /// was part of what they SENT, and a branch re-sends only what the
    /// chip holds. So the editor opens on the message as sent, unless the
    /// skill is one the chip has: seeded with the words alone, editing
    /// such a message quietly dropped its skill.
    private func beginMessageEdit(rowId: UUID, text: String, loadedSkills: [String]) {
        if sessionAgentKey == SkillAgent.kimi, loadedSkills.count == 1, let skill = loadedSkills.first,
           !skillPicks.contains(where: { $0.lowercased() == skill.lowercased() }) {
            editDraft = KimiAcp.promptText(text, skill: skill)
        } else {
            editDraft = text
        }
        editingRowId = rowId
    }

    private func cancelMessageEdit() {
        editingRowId = nil
        editDraft = ""
    }

    /// The files the LIVE row being edited named. A live row has no
    /// handle into the transcript and is found there by its words; a
    /// message of attached files alone has none, and the files it named
    /// are what find it (`resolveCutPoint(…attachedFiles:)`).
    private var editedLiveRowFiles: [String] {
        guard let id = editingRowId,
              let event = currentRunner?.events.first(where: { $0.id == id })
        else { return [] }
        return event.attachedFiles
    }

    /// Fork the session at the edited message and send the new text into
    /// the branch. The source session is never touched.
    ///
    /// `recordUuid` is the row's handle into the transcript, in the
    /// writer's own vocabulary (claude record uuid, codex turn id, kimi
    /// message id). History rows carry it; LIVE rows (a message sent
    /// this run, still only in the runner's event buffer) don't, and
    /// are resolved by matching their text against the transcript —
    /// the same identification `TranscriptSeam.cut` already makes.
    ///
    /// Three writers, ONE tail: whichever agent forked, the lineage,
    /// the name, the launch options, the runner (BEFORE routing, with
    /// the cwd and the agent handed in), the route and the send happen
    /// in the same order, written once.
    private func createSessionBranch(recordUuid: String?,
                                     originalText: String,
                                     newText: String,
                                     skippingNewer: Int = 0) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Held with the composer's own send: a branch made while its first
        // message cannot go would run that message in a mode the chips do
        // not say (the editor's button is disabled meanwhile; this is the
        // backstop).
        guard !text.isEmpty, !branching, !sendIsHeld,
              case .existing(let sourceId, let url, let cwd, _) = mode
        else { return }
        let agentKey = sessionAgentKey
        // Read now, with the parent still on screen: by the time the
        // fork returns the user may be looking at something else.
        let customGroup = branchCustomGroup
        // Read while the row is still the one being edited.
        let attachedFiles = recordUuid == nil ? editedLiveRowFiles : []

        branching = true
        // Explicitly MainActor: everything after the detached fork
        // touches @State, AppState, ConfigManager and AgentManager.
        Task { @MainActor in
            do {
                let forked: (id: String, fileURL: URL, cut: String)
                switch agentKey {
                case "codex":
                    forked = try await forkCodex(rollout: url, threadId: sourceId,
                                                 recordUuid: recordUuid,
                                                 originalText: originalText,
                                                 attachedFiles: attachedFiles,
                                                 skippingNewer: skippingNewer)
                case "kimi":
                    forked = try await forkKimi(wire: url, cwd: cwd,
                                                recordUuid: recordUuid,
                                                originalText: originalText,
                                                attachedFiles: attachedFiles,
                                                skippingNewer: skippingNewer,
                                                title: AgentSessionFork.branchTitle(from: text))
                case "claude_code":
                    forked = try await forkClaude(source: url,
                                                  recordUuid: recordUuid,
                                                  originalText: originalText,
                                                  attachedFiles: attachedFiles,
                                                  skippingNewer: skippingNewer)
                default:
                    throw AgentSessionFork.ForkError.agentNotSupported
                }

                branching = false
                let newId = forked.id
                let title = AgentSessionFork.branchTitle(from: text)
                // The branch exists now, whatever the user does next, so
                // everything that DESCRIBES it is written now: lineage,
                // its name, its launch options, and its row. Named from
                // the message that starts it — the branch inherits no
                // generated title (the claude fork drops the parent's,
                // the kimi fork writes this name, a codex fork has none
                // yet), so without this it would sit in the sidebar
                // under a name derived from a conversation it has just
                // diverged from, or with no name and no glyph at all.
                config.setAgentSessionBranch(source: sourceId,
                                             recordUuid: forked.cut,
                                             for: newId)
                config.copyAgentChatOnlyTurns(from: sourceId, to: newId)
                config.copyAgentSessionSkillPicks(from: sourceId, to: newId)
                // What the branch's own history holds is what lies above
                // the cut: read now, while the parent's rows are on screen.
                let branchEvidence = skillEvidence(above: forked.cut, originalText: originalText)
                config.setAgentSessionDisplayName(title, for: newId)
                config.setAgentSessionLaunchOptions(launchOptions, for: newId)
                // Runner BEFORE routing, with the cwd and the agent
                // handed in — see `registerBranchedSession` for why that
                // order is a correctness rule and not a preference. The
                // parent's custom group rides along and is filed there,
                // before the row.
                let runner = agents.registerBranchedSession(
                    id: newId,
                    fileURL: forked.fileURL,
                    cwd: cwd,
                    title: title,
                    agentKey: agentKey,
                    customGroup: customGroup
                )
                // The user may have moved on while the branch was being
                // made. It is complete, listed and named — it simply
                // waits in the sidebar with the edited text unsent, as
                // the branch's own composer draft, so opening it finds
                // the message ready — but hijacking the centre pane out
                // from under them is not on.
                guard case .existing(let stillOpen, _, _, _) = mode,
                      stillOpen == sourceId else {
                    appState.setComposerDraft(text, for: AppState.agentDraftKey(newId))
                    return
                }
                // A hold that began while the branch was being made (the
                // CLI changed under it): the branch opens with the message
                // in its composer, where the line above it says why. Filed
                // before the route moves, so the pane finds it on arrival.
                let held = sendIsHeld
                if held {
                    appState.setComposerDraft(text, for: AppState.agentDraftKey(newId))
                }
                cancelMessageEdit()
                // A branch is its own session, not another run of
                // whatever scheduled task this transcript belonged to.
                appState.openScheduledTaskName = nil
                appState.openAgentSessionId = newId
                appState.openAgentSessionPath = forked.fileURL
                guard !held else { return }
                var sending = sendOptions
                sending.skillTriggers = skillTriggers(for: text, options: sending,
                                                      evidence: branchEvidence)
                runner.send(text: text, options: sending)
            } catch AgentSessionFork.ForkError.nothingToBranch {
                // Editing the session's FIRST message. There is no
                // shared history to carry, which makes the branch simply
                // a new session in the same folder — so make one, rather
                // than answering a reasonable request with an error.
                branching = false
                // Moved on meanwhile: nothing was created, so the edited
                // text goes back to the source's composer rather than
                // being lost with the click.
                guard case .existing(let stillOpen, _, _, _) = mode,
                      stillOpen == sourceId, !sendIsHeld else {
                    appState.setComposerDraft(text, for: AppState.agentDraftKey(sourceId))
                    return
                }
                startBranchAsNewSession(cwd: cwd, text: text,
                                        customGroup: customGroup)
            } catch AgentSessionFork.ForkError.agentUnavailable {
                branching = false
                branchError = String(
                    localized: "\(sessionAgentName) did not answer, so the branch was not created.",
                    comment: "Branch error when the agent's own fork call got no reply; placeholder is the agent's label")
            } catch {
                branching = false
                branchError = error.localizedDescription
            }
        }
    }

    /// Whether the installed tool can take this session back to a message
    /// — the Send in the message editor (`AgentSessionRewind.support`).
    private var rewindSupport: AgentSessionRewind.Support {
        AgentSessionRewind.support(
            agentKey: sessionAgentKey,
            claudeNamesFlag: ClaudeCapabilities.shared.namesResumeSessionAt,
            codexVersion: AgentCLIUpdateMonitor.shared.installed["codex"]?.text,
            kimiVersion: AgentCLIUpdateMonitor.shared.installed["kimi"]?.text)
    }

    /// Send in the message editor: the session goes back to the edited
    /// message — the message and everything after it leave the
    /// conversation — and the edit is sent there, in THIS session: its
    /// name, its place in the sidebar and its id stay. Each agent's own
    /// mechanism (`AgentSessionRewind`): claude takes the cut with the
    /// send itself, codex and kimi make it first and the send continues
    /// from it. The first message has nothing above it to go back to, and
    /// starts a new session instead, as Create Branch does.
    ///
    /// Once codex or kimi has made the cut the edit is sent whatever the
    /// user does next — the session is cut, and only the send completes
    /// it. Rows are cut on screen only while this session is the one
    /// shown; any later open reads the file, where the cut is the agent's.
    private func editSessionInPlace(rowId: UUID, recordUuid: String?,
                                    originalText: String, newText: String,
                                    skippingNewer: Int) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !branching, !sendIsHeld, canBranch,
              rewindSupport == .offered,
              case .existing(let sessionId, let url, let cwd, _) = mode,
              let runner = currentRunner
        else { return }
        let agentKey = sessionAgentKey
        let customGroup = branchCustomGroup
        // What the conversation above the message holds, read while its
        // rows are still on screen: a skill loaded only in the turns being
        // replaced is not loaded any more.
        let evidence = skillEvidence(above: recordUuid ?? "", originalText: originalText)
        // The chips the edit goes with, read now, while this session is the
        // one shown: the view outlives a switch to another session, and read
        // after codex's or kimi's own call they would be that session's.
        let chips: AgentLaunchOptions = {
            var options = sendOptions
            options.skillTriggers = skillTriggers(for: text, options: options, evidence: evidence)
            return options
        }()
        // Read while the row is still the one being edited: a live message
        // of attached files alone is found by the files it named.
        let attachedFiles = recordUuid == nil ? editedLiveRowFiles : []

        branching = true
        Task { @MainActor in
            do {
                var resumeAt: String? = nil
                switch agentKey {
                case "codex":
                    let file = try await revertCodex(rollout: url, threadId: sessionId,
                                                     recordUuid: recordUuid, originalText: originalText,
                                                     attachedFiles: attachedFiles,
                                                     skippingNewer: skippingNewer)
                    runner.adoptRewoundRollout(file)
                    if appState.openAgentSessionId == sessionId {
                        appState.openAgentSessionPath = file
                    }
                    // The sidebar's row still names the old file, and a
                    // click on it would open the turns codex just took back.
                    agents.reloadSessions()
                case "kimi":
                    try await undoKimi(wire: url, sessionId: sessionId, cwd: cwd,
                                       recordUuid: recordUuid, originalText: originalText,
                                       attachedFiles: attachedFiles,
                                       skippingNewer: skippingNewer)
                case "claude_code":
                    resumeAt = try await claudeEntry(above: recordUuid, in: url,
                                                     originalText: originalText,
                                                     attachedFiles: attachedFiles,
                                                     skippingNewer: skippingNewer)
                default:
                    throw AgentSessionFork.ForkError.agentNotSupported
                }
                branching = false
                historyCache.forget(sessionId)
                if case .existing(let shown, _, _, _) = mode, shown == sessionId {
                    cutTranscript(at: rowId)
                    cancelMessageEdit()
                }
                var sending = chips
                sending.claudeResumeAt = resumeAt
                runner.send(text: text, options: sending)
            } catch AgentSessionFork.ForkError.nothingToBranch {
                // The first message: nothing above it to go back to.
                branching = false
                guard case .existing(let shown, _, _, _) = mode, shown == sessionId, !sendIsHeld else {
                    appState.setComposerDraft(text, for: AppState.agentDraftKey(sessionId))
                    return
                }
                startBranchAsNewSession(cwd: cwd, text: text, customGroup: customGroup)
            } catch AgentSessionFork.ForkError.agentUnavailable {
                branching = false
                branchErrorTitle = Self.inPlaceFailureTitle
                branchError = String(
                    localized: "\(sessionAgentName) did not answer, so nothing changed.",
                    comment: "Edit-in-place error when the agent's own call got no reply; placeholder is the agent's label")
            } catch {
                branching = false
                branchErrorTitle = Self.inPlaceFailureTitle
                branchError = error.localizedDescription
            }
        }
    }

    private static var inPlaceFailureTitle: String {
        String(localized: "Could not go back to this message",
               comment: "Title of the alert shown when editing a message in place fails")
    }

    /// The page after Send: the edited row and every row below it go, so
    /// the conversation ends above it until the edit's own row is drawn.
    /// The live rows all lie below the history rows.
    private func cutTranscript(at rowId: UUID) {
        if let at = historicalItems.firstIndex(where: { $0.id == rowId }) {
            historicalItems.removeSubrange(at...)
            currentRunner?.discardEvents(from: nil)
        } else {
            currentRunner?.discardEvents(from: rowId)
        }
    }

    /// Claude: the entry above the edited record, which the edit's turn
    /// resumes at (`--resume-session-at`). Nothing is written until then.
    private func claudeEntry(above recordUuid: String?, in url: URL,
                             originalText: String, attachedFiles: [String],
                             skippingNewer: Int) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try AgentSessionRewind.claudeResumeEntry(recordUuid: recordUuid, in: url,
                                                     originalText: originalText,
                                                     attachedFiles: attachedFiles,
                                                     skippingNewer: skippingNewer)
        }.value
    }

    /// Codex: the thread reverted to before the edited message's turn, by
    /// codex; answers the thread's new rollout.
    private func revertCodex(rollout url: URL, threadId: String, recordUuid: String?,
                             originalText: String, attachedFiles: [String],
                             skippingNewer: Int) async throws -> URL {
        guard let binary = AgentManager.binaryPath(for: "codex") else {
            throw AgentSessionFork.ForkError.agentUnavailable
        }
        let cut = try await Task.detached(priority: .userInitiated) {
            try AgentSessionRewind.codexRevertTurn(recordUuid: recordUuid, in: url,
                                                   originalText: originalText,
                                                   attachedFiles: attachedFiles,
                                                   skippingNewer: skippingNewer)
        }.value
        switch await AgentSessionRewind.revertCodex(threadId: threadId, beforeTurnId: cut,
                                                    binary: binary) {
        case .reverted(let file): return file
        case .refused(let words): throw AgentSessionRewind.RewindError.refused(words)
        case .unsupported, .unavailable: throw AgentSessionFork.ForkError.agentUnavailable
        }
    }

    /// Kimi: the turns from the edited message on undone by kimi's own
    /// server (`:undo`, what its `/undo` calls).
    private func undoKimi(wire url: URL, sessionId: String, cwd: URL, recordUuid: String?,
                          originalText: String, attachedFiles: [String],
                          skippingNewer: Int) async throws {
        guard let binary = AgentManager.binaryPath(for: "kimi") else {
            throw AgentSessionFork.ForkError.agentUnavailable
        }
        let target = try await Task.detached(priority: .userInitiated) {
            try AgentSessionRewind.kimiUndoTarget(recordUuid: recordUuid, in: url, originalText: originalText,
                                                  attachedFiles: attachedFiles, skippingNewer: skippingNewer)
        }.value
        guard let path = AgentSessionRewind.kimiUndoPath(sessionId: sessionId) else {
            throw AgentSessionFork.ForkError.cutPointNotFound
        }
        let namesTurn = AgentSessionRewind.kimiUndoNamesTurn(
            kimiVersion: AgentCLIUpdateMonitor.shared.installed["kimi"]?.text)
        switch await KimiWebServerCall.Session.start(binary: binary, scratchDirectory: cwd) {
        case .failed(let why):
            throw AgentSessionRewind.RewindError.refused(why)
        case .started(let server):
            var body: [String: Any] = ["count": target.count]
            if namesTurn {
                // The turn the edited message opened, from kimi's own turn
                // list, newest page first: its id is a hash of a counter
                // only kimi's server holds.
                var below: Int? = nil
                var turnId: String? = nil
                pages: for _ in 0..<50 {
                    let list = AgentSessionRewind.kimiTurnsPath(sessionId: sessionId, beforeOrdinal: below)
                    guard let list else { break }
                    switch await server.request(method: "GET", path: list) {
                    case .failure(let error):
                        await server.shutdown()
                        throw AgentSessionRewind.RewindError.refused(error.localizedDescription)
                    case .success(let data):
                        let page = AgentSessionRewind.kimiTurnsPage(from: data, messageId: target.messageId)
                        guard let page else {
                            await server.shutdown()
                            throw AgentSessionRewind.RewindError.refused(AgentSessionRewind.kimiWords(in: data))
                        }
                        if let found = page.turnId {
                            turnId = found
                            break pages
                        }
                        guard page.hasMore, let oldest = page.oldestOrdinal else { break pages }
                        below = oldest
                    }
                }
                guard let turnId else {
                    await server.shutdown()
                    throw AgentSessionFork.ForkError.cutPointNotFound
                }
                body = ["turn_id": turnId]
            }
            let answer = await server.request(method: "POST", path: path, body: body)
            await server.shutdown()
            switch answer {
            case .failure(let error):
                throw AgentSessionRewind.RewindError.refused(error.localizedDescription)
            case .success(let data):
                if case .refused(let words) = AgentSessionRewind.kimiUndoOutcome(from: data) {
                    throw AgentSessionRewind.RewindError.refused(words)
                }
            }
        }
    }

    /// Claude: a new transcript beside the original, holding the prefix.
    private func forkClaude(source url: URL, recordUuid: String?,
                            originalText: String, attachedFiles: [String],
                            skippingNewer: Int) async throws
    -> (id: String, fileURL: URL, cut: String) {
        try await Task.detached(priority: .userInitiated) {
            guard let cut = recordUuid
                    ?? AgentSessionFork.resolveCutPoint(
                        matchingUserText: originalText, attachedFiles: attachedFiles, in: url,
                        skippingNewest: skippingNewer)
            else { throw AgentSessionFork.ForkError.cutPointNotFound }
            let result = try AgentSessionFork.fork(source: url,
                                                   cutAtRecordUuid: cut)
            return (result.sessionId, result.fileURL, cut)
        }.value
    }

    /// Codex: forked by codex itself, through its app-server. The cut
    /// is the turn the edited message opened; codex is asked to fork
    /// through the turn before it.
    private func forkCodex(rollout url: URL, threadId: String,
                           recordUuid: String?, originalText: String,
                           attachedFiles: [String],
                           skippingNewer: Int) async throws
    -> (id: String, fileURL: URL, cut: String) {
        guard let binary = AgentManager.binaryPath(for: "codex") else {
            throw AgentSessionFork.ForkError.agentUnavailable
        }
        let cut = try await Task.detached(priority: .userInitiated) {
            () -> String in
            guard let cut = recordUuid
                    ?? CodexSessionFork.resolveCutPoint(
                        matchingUserText: originalText, attachedFiles: attachedFiles, in: url,
                        skippingNewest: skippingNewer)
            else { throw AgentSessionFork.ForkError.cutPointNotFound }
            return cut
        }.value
        // A branch keeps its parent's speed (`CodexKeptSpeed`), so its
        // switches stay what the parent's say.
        let result = try await CodexSessionFork.fork(
            rollout: url, threadId: threadId, cutAtTurnId: cut, binary: binary,
            keepsSpeed: CodexKeptSpeed.keeps(
                codexVersion: AgentCLIUpdateMonitor.shared.installed["codex"]?.text))
        return (result.threadId, result.rolloutURL, cut)
    }

    /// Kimi: a new session directory beside the original, in the shape
    /// kimi's own fork writes, holding the wire prefix.
    private func forkKimi(wire url: URL, cwd: URL, recordUuid: String?,
                          originalText: String, attachedFiles: [String],
                          skippingNewer: Int,
                          title: String) async throws
    -> (id: String, fileURL: URL, cut: String) {
        try await Task.detached(priority: .userInitiated) {
            guard let cut = recordUuid
                    ?? KimiSessionFork.resolveCutPoint(
                        matchingUserText: originalText, attachedFiles: attachedFiles, in: url,
                        skippingNewest: skippingNewer)
            else { throw AgentSessionFork.ForkError.cutPointNotFound }
            let result = try KimiSessionFork.fork(sourceWire: url,
                                                  cutAtPromptId: cut,
                                                  title: title, cwd: cwd)
            return (result.sessionId, result.wireURL, cut)
        }.value
    }

    /// The degenerate branch: nothing above the edited message, so this
    /// is a fresh session carrying only the new text. Goes through the
    /// ordinary draft path — the same one "+ New session" uses — so
    /// session-id discovery, the runner migration and the sidebar row
    /// all behave exactly as they do for any other new session.
    private func startBranchAsNewSession(cwd: URL, text: String,
                                         customGroup: String?) {
        // The SAME agent: a draft defaults to claude, and a branch of a
        // codex or kimi session that spawned claude would be a different
        // conversation with a different tool, not a fresh start. The
        // parent's custom group rides the draft, and `migrateRunner`
        // files it when the id arrives — exactly as the group +'s does.
        var draft = ClaudeSessionDraft(cwd: cwd, agentKey: sessionAgentKey,
                                       customGroup: customGroup)
        draft.place = .branch(draft.id)
        // The parent's chosen skills, all of which load again: the new
        // session holds nothing yet.
        draft.skillPicks = skillPicks
        // The chips its first message goes out with are the new session's
        // own from now (`sentOptions`), as after any first send: the page
        // the draft opens on seeds from them, and the switch to the
        // session saves them. Without them the page seeds the agent's
        // latest choices, and the switch saves those over the parent's.
        draft.sentOptions = launchOptions
        var sending = sendOptions
        // A codex session keeps its saved speed (`CodexKeptSpeed`), which
        // its chips show: the new session is born at that speed too, as a
        // branch made at a later message is forked at it.
        if sessionAgentKey == "codex",
           CodexKeptSpeed.keeps(codexVersion: AgentCLIUpdateMonitor.shared.installed["codex"]?.text),
           let tier = CodexKeptSpeed.forkTier(codexSavedSpeed) {
            draft.sentOptions?.serviceTier = tier
            sending.serviceTier = tier
            sending.codexServiceTierOverride = tier
        }
        sending.skillTriggers = skillTriggers(for: text, options: sending, evidence: [])
        cancelMessageEdit()
        appState.openScheduledTaskName = nil
        appState.pendingClaudeSessionDraft = draft
        agents.runner(forDraft: draft).send(text: text, options: sending)
        agents.noteSentDraft(draft)
    }

    /// Retract a load-time "Interrupted" marker once the session
    /// proves itself alive (an external writer resumed, or the user
    /// sent into it). The marker answers "does this transcript end
    /// mid-thought with nobody writing" — true at load, false now.
    ///
    /// Also dropped from the parsed-history cache, or the next open of
    /// this session would render it again from the cached copy before
    /// the refresh read lands.
    private func dropInterruptedMarker() {
        if case .existing(let sid, _, _, _) = mode {
            historyCache.dropInterruptedMarker(for: sid)
        }
        guard historicalItems.contains(where: {
            if case .interrupted = $0.kind { return true }
            return false
        }) else { return }
        historicalItems.removeAll {
            if case .interrupted = $0.kind { return true }
            return false
        }
    }

    private func handleStop() {
        guard let runner = currentRunner else { return }
        if runner.status.isRunning {
            // Our own subprocess — SIGTERM it (SIGKILL follows if
            // ignored).
            runner.cancel()
        } else {
            // An orphaned external `-p` writer; no-op for anything
            // else (the composer disables the button then).
            runner.stopExternalTurn()
        }
    }

    // MARK: - Launch-option seeding

    /// Learn versioned model names for the composer's picker rows from
    /// what Claude Code has already recorded on this machine — its own
    /// state file plus the newest sessions (see `ClaudeModelCatalog`).
    /// Runs once per app launch, off-main.
    ///
    /// Deliberately NOT gated on the "" default mapping still being
    /// unknown: such a gate would freeze the whole map after the first
    /// pass, pinning every alias to whatever version it had then and
    /// leaving a family never sent from this app with no version at
    /// all. The merge only ever moves an alias FORWARD (highest
    /// version wins, which is what an alias means), and a live
    /// system.init observation still overwrites with ground truth.
    private func refreshObservedModelNames() {
        ClaudeModelCatalog.refreshObservedNames(
            config: config,
            sessionURLs: Array(
                agents.sessions.lazy
                    .filter { $0.agentKey == "claude_code" }
                    .prefix(20)
                    .map(\.fileURL)
            )
        )
    }

    // MARK: - A new session's place

    /// Where a new session's unsent text, files, schedule, chips and
    /// skills are kept: its place's key (`transcriptKey`), as the store
    /// spells it.
    private func newSessionStoreKey(_ d: ClaudeSessionDraft) -> String {
        AppState.agentDraftKey(d.place.draftKey(agentKey: d.agentKey))
    }

    /// Work out `newSessionStart` for the new session on screen, once —
    /// first forgetting what waits for custom groups that are gone — and
    /// read what its skills need before its first send: a page built
    /// again after a detour asks for its picks before they are known.
    private func refreshNewSessionStart() {
        guard case .draft(let d) = mode, newSessionStart?.draftId != d.id else { return }
        appState.dropNewSessions(ofGroupsNotIn: config.agentCustomGroups(for: d.agentKey),
                                 agentKey: d.agentKey)
        newSessionStart = newSessionStartingSetup(for: d)
        if showsSkillChip, !skillPicks.isEmpty {
            SkillCatalog.shared.ensurePicksReadable(skillPicks, agent: sessionAgentKey,
                                                    folder: composerFolder)
        }
    }

    /// What a new session's chips start from, under whatever was changed
    /// on them at its place (`NewSessionChipEdits`): those of its group's
    /// newest session (`NewSessionPlace.startingSetup`) — mode, model,
    /// effort, speed, Non-stop / Chat only, as the group's + already takes
    /// that session's folder; a new session whose first message has gone
    /// counts from that moment, named or not — else the agent's latest
    /// choices: for no group, and for a group with nothing to remember
    /// yet. Its skills and schedule are not part of it: those belong to
    /// the one session they were set on, and a new session starts with
    /// the agent's pinned skills alone (`skillPicks`) and no schedule.
    private func newSessionStartingSetup(for d: ClaudeSessionDraft) -> NewSessionStart {
        let agent = d.agentKey
        let start = d.place.startingSetup(
            among: agents.regularSessions(for: agent),
            unnamed: agents.unnamedNewSessions(for: agent),
            customGroups: config.agentCustomGroups(for: agent),
            assignments: config.agentSessionGroupAssignments,
            setup: { config.agentSessionLaunchOptions(for: $0) })
        var options = start?.options ?? config.agentLaunchOptions(for: agent)
        // The id that session last ran under names ITS model; the chip's
        // hover would read it as this new session's "last ran as".
        options.modelFullId = nil
        // Where codex keeps that session's speed, its chips show the speed
        // it keeps, which its pick need not be (`CodexKeptSpeed`).
        if agent == "codex", let session = start?.session,
           CodexKeptSpeed.applies(
               codexVersion: AgentCLIUpdateMonitor.shared.installed["codex"]?.text,
               driver: AgentTurnDriver.pick(
                   agentKey: agent, options: options, isNewSession: false,
                   frontEndOffered: AskingModeGate.frontEnd(agentKey: agent) == .offered)) {
            options.serviceTier = CodexKeptSpeed.startingTier(
                pick: options.serviceTier, saved: Self.codexSavedSpeed(of: session.fileURL))
        }
        return NewSessionStart(draftId: d.id, options: options)
    }

    /// A new session's chips once its first message has gone: the new
    /// session's own, kept on it until the session is named (`sentOptions`)
    /// — and on the manager's copy, which is what the session is filed with
    /// if this page has moved on by then. Before its first message, what
    /// the user changes is kept for its place where the pick is made
    /// (`keepNewSessionPick`).
    private func keepSentOptions(_ options: AgentLaunchOptions) {
        guard case .draft(let d) = mode, loadedDraftKey == transcriptKey,
              !isDraftBeforeFirstSend, let sent = d.sentOptions, sent != options else { return }
        appState.pendingClaudeSessionDraft?.sentOptions = options
        if let draft = appState.pendingClaudeSessionDraft { agents.noteSentDraft(draft) }
    }

    /// A pick on an unsent new session's chips, kept for its place chip by
    /// chip (`NewSessionChipEdits`): the chips it moved come back as they
    /// were left, and the others go on following what the place starts
    /// with — its group's newest session as that moves on.
    private func keepNewSessionPick(from old: AgentLaunchOptions, to new: AgentLaunchOptions) {
        guard case .draft(let d) = mode, isDraftBeforeFirstSend else { return }
        let key = newSessionStoreKey(d)
        var edits = appState.newSessionChipEdits(for: key) ?? NewSessionChipEdits()
        edits.note(from: old, to: new)
        appState.setNewSessionChipEdits(edits, for: key)
    }

    /// What `model` offers on the chips, for fitting an unsent new
    /// session's kept chips to the model they land on
    /// (`NewSessionChipEdits.applied`): read off the catalogs the
    /// composer's menus read, the way it reads them, except that what is
    /// not known yet is nil and drops nothing — a catalog still loading
    /// must not take a saved level.
    private func newSessionChipOffer(forModel model: String?) -> ModelOffer {
        let folder = composerFolder
        switch sessionAgentKey {
        case "kimi":
            return ModelOffer(efforts: KimiCatalog.shared.effortLevels(forModel: model),
                              fastMode: false)
        case "codex":
            let codex = CodexCatalog.shared
            let slug = (model?.isEmpty == false) ? model : codex.defaultModel(forFolder: folder.path)
            return ModelOffer(efforts: codex.effortLevels(forModel: slug),
                              tiers: codex.speedTiers(forModel: model, folder: folder.path)?
                                .tiers.map(\.id))
        case "claude_code":
            let caps = ClaudeCapabilities.shared
            let id = config.resolvedClaudeModelId(
                picked: model, configuredDefault: ClaudeModelCatalog.configuredDefaultModel(cwd: folder))
            // Claude offers fast mode on Anthropic's own API alone.
            let cloud = ClaudeModelCatalog.childEnvironmentFacts().provider != nil
            return ModelOffer(efforts: caps.effortLevels(forModelId: id),
                              fastMode: cloud ? false : caps.fastModeSupported(forModelId: id))
        default:
            // An agent this app has no code for offers no effort and no
            // speed: a kept level or switch is dropped, not carried over.
            return ModelOffer(efforts: [], fastMode: false)
        }
    }

    /// The new session on screen kept its id and changed its key: its
    /// custom group was renamed, and what was kept for it moved with the
    /// name (`AppState.renameNewSessionGroup`). The page takes the new key
    /// and carries nothing. A switch to another new session changes the
    /// id too, and is `stashAndRestoreComposerDraft`'s.
    private func adoptRenamedPlace(from old: DraftPlaceIdentity?, to new: DraftPlaceIdentity?) {
        guard let old, let new, old.id == new.id, old.key != new.key,
              loadedDraftKey == old.key else { return }
        loadedDraftKey = new.key
    }

    /// Seed the composer's mode / model / effort chips. An existing
    /// session shows its own latest recorded values — every writer
    /// (this app, a terminal, the desktop app) records them in the
    /// JSONL — so reopening picks up exactly where it left off.
    /// A new session shows its own chips once its first message has gone,
    /// else what its place starts with, under the chips changed on it there.
    private func seedLaunchOptions() {
        refreshObservedModelNames()
        switch mode {
        case .existing(let id, let url, _, _):
            // What the thread runs at, whatever its picks say
            // (`CodexKeptSpeed`). A read that finds no record leaves what
            // the runner already knows: a new thread's first turn has not
            // written one when the page flips from its draft.
            if sessionAgentKey == "codex",
               case let read = Self.codexSavedSpeed(of: url), read != .unknown {
                codexSavedSpeed = read
            }
            // The user's own explicit picks for THIS session win over
            // anything the transcript recorded — an external writer
            // (same session driven from a terminal) records ITS mode
            // there, and re-deriving from it would flip the user's
            // "Auto" chip to "Manual" on every switch-back.
            if let saved = config.agentSessionLaunchOptions(for: id) {
                applySeededOptions(saved)
                return
            }
            // OVERLAY, never wholesale replace. A field the scan does
            // not find means "not in the window I read" — never "the
            // user chose claude's default", which claude records
            // explicitly as `permissionMode: "default"`. Building the
            // options straight out of the scan would conflate the two:
            // a session whose newest `permissionMode` record has
            // scrolled out of the read window would silently lose its
            // mode — the chip moves to Default, the next send drops
            // the `--permission-mode` flag, and claude then RECORDS
            // `default`, making the wrong answer permanent.
            //
            // The base is the sticky global prefs — the values a fresh
            // send would use — not `launchOptions`, which on a switch
            // still holds the OUTGOING session's picks.
            var seeded = config.agentLaunchOptions(for: sessionAgentKey)
            // The scan below reads CLAUDE's session JSONL. A codex
            // rollout is a different schema, so it would find nothing
            // and cost a tail read per session open to do it; more to
            // the point, seeding a codex session from claude's sticky
            // prefs would put `-m opus` on a codex command line.
            guard sessionAgentKey == "claude_code" else {
                applySeededOptions(seeded)
                return
            }
            let scanned = AgentSessionScanner.lastLaunchOptions(of: url)
            if let mode = scanned.permissionMode { seeded.permissionMode = mode }
            if let effort = scanned.effort { seeded.effort = effort }
            // The recorded speed is an OUTCOME: a refused call records
            // standard too, so only a fast record may move the switch.
            seeded.fastMode = ClaudeFastMode.seededSwitch(
                base: seeded.fastMode, newestCallRanFast: scanned.fastMode)
            if let fullId = scanned.model {
                // Keep the full id alongside the alias: the picker
                // matches on the alias row, and the hover names the
                // model the session last ran under. The chip's TITLE
                // does not read it — it names what the alias resolves
                // to now, which after a CLI update is a different
                // model from the one recorded here.
                seeded.model = composerModelValue(forFullId: fullId)
                seeded.modelFullId = fullId
            }
            applySeededOptions(seeded)
        case .draft(let d):
            refreshNewSessionStart()
            let start = newSessionStart?.options ?? config.agentLaunchOptions(for: sessionAgentKey)
            applySeededOptions(d.sentOptions
                ?? appState.newSessionChipEdits(for: newSessionStoreKey(d))?
                    .applied(to: start, offer: newSessionChipOffer(forModel:))
                ?? start)
        case .empty:
            applySeededOptions(config.agentLaunchOptions(for: sessionAgentKey))
        }
    }

    /// The speed a codex rollout says its thread saved (`CodexSessionScanner
    /// .savedServiceTier`), as the composer reads it.
    private static func codexSavedSpeed(of url: URL) -> CodexKeptSpeed.Saved {
        let saved = CodexSessionScanner.savedServiceTier(of: url)
        return saved.found ? .tier(saved.tier) : .unknown
    }

    /// SipAI's own update of the chips: what a session recorded, the
    /// sticky picks, a card's mode switch. Written to the state alone —
    /// it is not the user's pick and saves nothing; the callers that
    /// must also save do so themselves, on purpose.
    private func applySeededOptions(_ options: AgentLaunchOptions) {
        var options = options
        // A turn in flight declines or shows questions as it was sent — a
        // scheduled run as its task says — and the chip says what the turn
        // does, whatever the saved pick is. Only while it runs:
        // `restoreNonStopPick` puts the saved pick back when it ends.
        if let runner = currentRunner, runner.status.isRunning {
            options.nonStop = runner.nonStop
        }
        guard options != launchOptions else { return }
        launchOptions = options
    }

    /// The composer's chips write through this binding — the only place a
    /// change of mode, model, effort or switch is the user's own pick,
    /// and so the only one that saves it.
    ///
    /// Telling the user's picks from SipAI's own updates AFTER the fact
    /// cannot be done: an `onChange` on `launchOptions` sees both, and a
    /// flag set by each update of SipAI's miscounts — SwiftUI may deliver
    /// two of them as two changes (a new session's page opened again
    /// while its first message runs: the model refine, then the flip's
    /// seed), and the second would be saved as the user's pick, for the
    /// session and as the default for new sessions; or merge two into one
    /// change, and a count would then swallow the user's next pick.
    private var userPicks: Binding<AgentLaunchOptions> {
        Binding(
            get: { launchOptions },
            set: { picked in
                let old = launchOptions
                launchOptions = picked
                guard picked != old else { return }
                saveUserPick(picked, replacing: old)
            })
    }

    /// Save a pick the user made on the chips, and let the turn in flight
    /// know what it needs to.
    private func saveUserPick(_ new: AgentLaunchOptions, replacing old: AgentLaunchOptions) {
        // What is saved is the user's own pick: with a turn running,
        // the Non-stop switch shows THAT turn's setting, which is the
        // pick only when this edit flipped it (`ownPick`).
        let picked = ownPick(new, nonStopFlipped: old.nonStop != new.nonStop)
        // Per AGENT. The two CLIs share this picker but not its
        // vocabulary — "bypassPermissions" is meaningless to codex
        // and "workspace-write" to claude — so one sticky slot
        // would hand each agent the other's last choice.
        config.setAgentLaunchOptions(picked, for: sessionAgentKey)
        if case .existing(let id, _, _, _) = mode {
            config.setAgentSessionLaunchOptions(picked, for: id)
        }
        keepNewSessionPick(from: old, to: picked)
        // Non-stop also reaches the turn in flight: turned on, a
        // question already on screen is declined and the turn goes on.
        if old.nonStop != new.nonStop {
            currentRunner?.setNonStop(new.nonStop)
        }
        // A codex chip moved to Plan: the mode it left is the one the
        // session was in before it planned — what "Implement this
        // plan?" may offer Full Access on.
        if new.permissionMode == AgentAskingMode.codexPlan,
           old.permissionMode != AgentAskingMode.codexPlan {
            currentRunner?.noteCodexChipLeftForPlan(
                previous: old.chatOnly ? nil : old.permissionMode)
        }
    }

    /// Put the Non-stop switch back on the user's own pick — this
    /// session's, else the agent's sticky one — through the seeding path,
    /// which shows a running turn's own setting over it and writes
    /// nothing back. Without it a Non-stop scheduled run watched while it
    /// ran would leave its Non-stop on the chip, and the first message
    /// typed into that session afterwards would be sent, and saved,
    /// Non-stop.
    private func restoreNonStopPick() {
        var next = launchOptions
        next.nonStop = savedNonStopPick()
        applySeededOptions(next)
    }

    /// The user's own Non-stop pick: this session's as config has it — a
    /// new session's own once its first message has gone — else the
    /// agent's sticky one.
    private func savedNonStopPick() -> Bool {
        if case .existing(let id, _, _, _) = mode,
           let mine = config.agentSessionLaunchOptions(for: id) {
            return mine.nonStop
        }
        // A new session whose first message has gone keeps the pick that
        // message went out with — its place may have started it on a
        // setup other than the agent's sticky one.
        if case .draft(let d) = mode, let sent = d.sentOptions {
            return sent.nonStop
        }
        return config.agentLaunchOptions(for: sessionAgentKey).nonStop
    }

    /// `options` as the user's own pick, fit to save. With a turn running
    /// the Non-stop switch shows THAT turn's setting
    /// (`applySeededOptions`), which is the pick only when the edit
    /// being saved flipped it: an edit of another chip, or a card's mode
    /// switch, made while a scheduled run is watched would otherwise save
    /// the run's Non-stop as the session's — and as the agent's sticky
    /// pick, so every later new session would start Non-stop.
    private func ownPick(_ options: AgentLaunchOptions,
                         nonStopFlipped: Bool = false) -> AgentLaunchOptions {
        guard !nonStopFlipped, currentRunner?.status.isRunning == true else { return options }
        var picked = options
        picked.nonStop = savedNonStopPick()
        return picked
    }

    /// A card switched claude to another permission mode, and the chip
    /// follows. A plan card's approval names the mode the session carries
    /// on in ("Yes, and use auto mode", "Yes, auto-accept edits", …), and
    /// "Allow Always" on an edit switches it to accept-edits; claude makes
    /// the switch inside the turn, but every LATER turn is launched from
    /// the chip. Left where it was, a chip still on Plan would launch the
    /// next turn with `--permission-mode plan` and plan again ("you MUST
    /// NOT make any edits"), undoing the approval, and a chip on Manual
    /// would go back to asking about every edit the user had just
    /// allowed for the session.
    ///
    /// Whatever the chip said before: the user chose the mode on the
    /// card, for the session. Written for this session alone — never the
    /// agent's sticky pick for new sessions, so a user who starts every
    /// session on Plan keeps doing so. A draft carries it into its
    /// session with the rest of its picks (`handleSessionIdDiscovered`).
    ///
    /// One exception to "whatever the chip said": an answer that only
    /// ENDS the planning moves a chip that is on Plan, to Default, and no
    /// other (`AgentAskingMode.adoption`). `target` is a mode as the chip
    /// spells it, or `AgentAskingMode.adoptDefault` /
    /// `adoptLeavingPlan`.
    private func adoptSessionMode(_ target: String) {
        guard !launchOptions.chatOnly,
              case .set(let mode) = AgentAskingMode.adoption(of: target,
                                                             from: launchOptions.permissionMode),
              launchOptions.permissionMode != mode
        else { return }
        var next = launchOptions
        next.permissionMode = mode
        applySeededOptions(next)
        if case .existing(let id, _, _, _) = self.mode {
            // A card is answered mid-turn: the switch's overlay is not
            // the pick (`ownPick`).
            config.setAgentSessionLaunchOptions(ownPick(next), for: id)
        }
    }

    /// The JSONL records full model ids ("claude-fable-5"); the
    /// composer's picker rows are claude's aliases ("fable", "sonnet"…).
    /// Map onto the alias the id contains so the chip matches a picker
    /// row; an id no alias matches is used verbatim — `--model` accepts
    /// full ids too.
    private func composerModelValue(forFullId id: String) -> String {
        let lower = id.lowercased()
        if let alias = ClaudeCapabilities.shared.modelAliases.first(
            where: { lower.contains($0.lowercased()) }
        ) {
            return alias
        }
        return id
    }

    // MARK: - Session-id discovery → AppState transition

    private func handleSessionIdDiscovered(_ newSessionId: String?) {
        guard case .draft(let d) = mode,
              let id = newSessionId,
              !id.isEmpty,
              let runner = currentRunner,
              let url = runner.sessionFileURL
        else { return }
        // Persist custom display name against the now-known session id.
        if let name = d.name, !name.isEmpty {
            config.setAgentSessionDisplayName(name, for: id)
        }
        // Carry the composer picks the draft was sent with — they are
        // the user's explicit choices for this new session — and the
        // skill chip's. The manager has filed both under the id already
        // (`AgentManager.migrateRunner`, kept in step by `noteSentDraft`),
        // for a page that moves on before the session is named; here they
        // are written as this page has them at the switch.
        config.setAgentSessionLaunchOptions(launchOptions, for: id)
        if let picks = appState.pendingClaudeSessionDraft?.skillPicks {
            config.setAgentSessionSkillPicks(picks, for: id)
        }
        // Also persist last-cwd so the next new-session draft starts
        // there — under the DRAFT's agent, or a codex send would move
        // the claude section's new-session folder.
        config.setAgentLastCwd(d.cwd, for: d.agentKey)
        // Flip AppState. AgentManager already migrated the runner dict
        // and injected a placeholder session row via its callback.
        migrationFlipInFlight = true
        appState.pendingClaudeSessionDraft = nil
        appState.openAgentSessionId = id
        appState.openAgentSessionPath = url
        // The migration kept the draft key as an alias so this view
        // could observe the discovered session id; routing now points
        // at the session key, so the alias can go.
        agents.releaseDraftRunner(draftId: d.id)
    }

    // MARK: - Historical JSONL loading

    /// - Parameter migratedFromDraft: this is the draft→session flip of the
    ///   conversation already on screen, not a session being opened.
    private func reload(migratedFromDraft: Bool = false) {
        // The chosen skills' paths and states, read before the next send
        // needs them (codex's mentions name a skill by its exact path) —
        // and a subfolder's, for a pick that is none of the folder's own.
        if showsSkillChip, !skillPicks.isEmpty {
            SkillCatalog.shared.ensurePicksReadable(skillPicks, agent: sessionAgentKey,
                                                    folder: composerFolder)
        }
        // An open edit belongs to the transcript it was opened in. This
        // also covers the branch flow's own routing flip, where the edit
        // has already been closed — a second clear costs nothing.
        editingRowId = nil
        editDraft = ""
        // So does the review picker — except over the draft→session flip,
        // which is the same conversation.
        if !migratedFromDraft { reviewPickerOpen = false }
        // So does a find: a query left standing would count matches in
        // a transcript nobody asked it about, and the widened-scope
        // flags describe the file being left behind. Arrival from a
        // global-search result re-opens it a runloop turn later
        // (`consumePendingFind`), so this cannot fight that.
        find.close()
        historyLoadedBudget = AgentSessionScanner.historyByteBudget
        historyTurnCapApplies = true
        historyPartial = false
        historyTruncationNote = nil
        inheritedHistoryBytes = 0
        historyReadReachedStart = nil
        wideningHistory = false
        guard case .existing(_, let url, _, _) = mode else {
            // Draft mode: nothing on disk yet. RunnerStreamView
            // handles its empty state.
            historicalItems = []
            expandedToolResults = []
            expandedActivityLines = []
            seededContextTokens = 0
            seededContextWindow = 0
            seededContextModel = nil
            liveContextTokens = 0
            liveContextWindow = 0
            codexSavedSpeed = .unknown
            liveContextModel = ""
            seededTurnDuration = 0
            liveTurnDuration = nil
            livePause = TurnPause()
            liveResolvedModel = nil
            liveFastModeReport = ClaudeFastModeReport()
            liveCodexSpeedReport = CodexSpeedReport()
            seededCallSpeed = nil
            externalTurnStart = nil
            externalStoppable = false
            emptySessionCommands = []
            isLoading = false
            return
        }
        // A kimi session a Chat only turn left with its tools switched
        // off (a crash between the policy write and its restore) is put
        // right the moment it is opened — the launch heal covers the
        // ones nobody opens. The heal skips a session with a turn of
        // ours in flight.
        if case .existing(let id, _, _, _) = mode, sessionAgentKey == "kimi" {
            agents.healKimiToolPolicies(sessionId: id)
            agents.healKimiRuntimeBindings(sessionId: id)
        }
        // The draft→session flip of the conversation already on screen
        // reads nothing (`TranscriptSeam.readsTranscript`): the live
        // buffer holds the whole session, mid-first-turn or with that
        // turn already over — the transcript is found a beat after its
        // id, and a turn that fails, or is answered without the model, is
        // over in tens of milliseconds. A read would REPLACE the live
        // rows with the file's, and what only the buffer holds would go
        // with them: the error row of a turn that failed, an answer the
        // agent gave without recording it (kimi's own slash commands).
        // Every other reload reads — an empty page with a turn running
        // included: this view is rebuilt after every detour, a draft or a
        // task page leaves it empty as well, and the buffer may hold no
        // more than the running turn.
        if let runner = currentRunner,
           !TranscriptSeam.readsTranscript(draftFlip: migratedFromDraft,
                                           historyOnScreen: !historicalItems.isEmpty,
                                           turnRunning: runner.status.isRunning,
                                           liveRows: runner.events.count) {
            isLoading = false
            return
        }
        expandedToolResults = []
        expandedActivityLines = []
        // The publisher's replay repopulates this from the (per-session)
        // cached runner right after the switch — resetting first keeps a
        // previous session's total from flashing on the new one. Same
        // for the duration chip and the external-turn mirrors.
        liveContextTokens = 0
        liveContextWindow = 0
        codexSavedSpeed = .unknown
        liveContextModel = ""
        liveTurnDuration = nil
        livePause = TurnPause()
        // Cleared with them: the incoming runner replays its own value
        // within a frame, and a mirror still holding the OUTGOING
        // session's pair would suppress an identical observation here
        // as though it had already been seen.
        liveResolvedModel = nil
        liveFastModeReport = ClaudeFastModeReport()
        liveCodexSpeedReport = CodexSpeedReport()
        externalTurnStart = nil
        externalStoppable = false

        // Cache hit: render the last parsed history NOW — the click
        // shows content immediately, at its end. File unchanged →
        // done, no disk read at all. Changed → swap in the fresh read
        // when it lands and pull to the new end.
        if case .existing(let sid, _, _, _) = mode,
           let cached = historyCache.entry(for: sid) {
            // A read made with compact view on kept every turn's thoughts;
            // with it off since, only a Chat only turn's draw. Put on the
            // page as it was, the rest would sit in the rows unseen until
            // the fresh read below lands.
            let items = cached.allThoughts && !config.display.agentCompactView
                ? AgentSessionHistoryItem.keepingThoughts(cached.items,
                                                          inTurns: chatOnlyTurnHandles)
                : cached.items
            // Re-warm the markdown cache SYNCHRONOUSLY for the rows
            // the first frame renders — the parse cache is shared and
            // bounded, so another session's rows may have evicted
            // these since the last visit, and this path skips the
            // loader (whose prewarm covers first visits).
            Self.prewarmMarkdown(items, tail: 30)
            adoptHistory(items, fromFile: false)
            seededContextTokens = cached.contextTokens
            seededContextWindow = cached.contextWindow
            seededContextModel = cached.contextModel
            seededCallSpeed = cached.lastCallSpeed
            seededTurnDuration = cached.turnDuration
            emptySessionCommands = cached.commands
            isLoading = false
            // A cache hit swaps content in with no isLoading flip to
            // announce it, and the incoming RunnerStreamView was built
            // one pass EARLIER — while `historicalItems` still held the
            // outgoing session's rows. Say so explicitly rather than
            // relying on the swap's own geometry to imply it.
            repositionNonce &+= 1
            let stat = Self.fileStat(url)
            // "Show earlier" needs the partial verdict from the first
            // frame, not from the find bar opening. Cache entries are
            // always initial-budget reads (widens never store), and
            // `reload()` reset the budget a moment ago, so the inputs
            // agree with what this cache entry was read with.
            inheritedHistoryBytes = cached.inheritedBytes
            historyReadReachedStart = cached.readReachedStart
            updateHistoryScope(items: items,
                               fileSize: stat?.size ?? 0)
            // An unchanged file is not enough: a Chat only turn recorded
            // since the read had its thoughts left out of it, and a read
            // made before compact view was switched kept the wrong ones.
            if let stat,
               stat.size == cached.fileSize, stat.mtime == cached.fileMtime,
               cached.chatOnlyTurns == chatOnlyTurnHandles,
               cached.allThoughts == config.display.agentCompactView {
                return
            }
            startHistoryLoad(url: url, viaSpinner: false)
            return
        }

        isLoading = true
        seededContextTokens = 0
        seededContextWindow = 0
        seededContextModel = nil
        seededCallSpeed = nil
        seededTurnDuration = 0
        emptySessionCommands = []
        startHistoryLoad(url: url, viaSpinner: true)
    }

    /// Read + parse the transcript off-main and land it. `viaSpinner`
    /// distinguishes a first visit (loading state up; the isLoading
    /// flip tells RunnerStreamView the whole transcript arrived) from
    /// a cache refresh (content already on screen; swap it in place
    /// and pull to the new end via `repositionNonce`).
    private func startHistoryLoad(url: URL, viaSpinner: Bool) {
        let agentKey = sessionAgentKey
        // Read on the MainActor, before the detached read: the readers
        // keep every thought while compact view is on, and otherwise only
        // for a session that has Chat only turns, where `keepingThoughts`
        // then drops every one outside those turns — what is cached is
        // exactly what draws.
        let chatOnlyTurns = chatOnlyTurnHandles
        let allThoughts = config.display.agentCompactView
        let withThoughts = allThoughts || !chatOnlyTurns.isEmpty
        // Kimi's reader names the agent in a failed turn's row when kimi
        // gave no words for it, and only the view knows the label.
        let wordlessFailure = AgentAskingMode.wordlessFailureMessage(agentName: sessionAgentName)
        // Stat BEFORE the read: an append racing the read makes the
        // cache look stale next open — a refresh, never a miss.
        let stat = Self.fileStat(url)
        let turnAtRead = currentRunner?.status.runningSince
        Task {
            let ownSize = stat?.size ?? 0
            let loaded = await Task.detached(priority: .userInitiated)
            { () -> (items: [AgentSessionHistoryItem], contextTokens: Int,
                     contextWindow: Int, contextModel: String?,
                     turnDuration: Double, commands: [String],
                     inheritedBytes: UInt64, lastCallSpeed: String?,
                     reachedStart: Bool?) in
                if agentKey == "codex" {
                    // No turn duration: codex reports no wall-clock time
                    // anywhere, in the stream or the rollout. The context
                    // footprint IS on record though — one `token_count`
                    // per API call — and a hardcoded 0 here would keep
                    // the composer's context chip from ever appearing on
                    // a codex session (the chip hides itself at 0).
                    let items = Self.keepingThoughts(
                        CodexSessionScanner.readHistory(of: url,
                                                        includeThinking: withThoughts),
                        all: allThoughts, in: chatOnlyTurns)
                    Self.prewarmMarkdown(items)
                    let info = CodexSessionScanner.lastContextInfo(of: url)
                    // A branch's history reaches into its parent; what
                    // the read covered beyond this file is what the
                    // partiality verdict has to count.
                    let extent = CodexSessionScanner.historyExtent(of: url)
                    let inherited = extent > ownSize ? extent - ownSize : 0
                    return (items, info.tokens, info.window, nil, 0, [], inherited, nil, nil)
                }
                if agentKey == "kimi" {
                    // No derived "Interrupted" marker: the two liveness
                    // proofs it needs (claude's heartbeat store,
                    // `endsMidTurn`) are both claude-shaped. Claiming a
                    // turn was interrupted on weaker evidence is worse
                    // than staying silent — it sits above an answer
                    // that did arrive.
                    //
                    // The context total IS on record, one
                    // `usage.record` per turn. A hardcoded 0 here would
                    // be the same defect the codex branch above
                    // documents: the chip hides itself at 0, so a
                    // wrong 0 is indistinguishable from a fresh session
                    // and nothing says why.
                    let items = Self.keepingThoughts(
                        KimiSessionScanner.readHistory(of: url,
                                                       includeThinking: withThoughts,
                                                       wordlessFailure: wordlessFailure),
                        all: allThoughts, in: chatOnlyTurns)
                    Self.prewarmMarkdown(items)
                    // Tokens travel with the MODEL, not a window: the
                    // window is a config fact (`max_context_size`) and
                    // the catalog holding it is MainActor state, so
                    // the join happens after this task lands.
                    let usage = KimiSessionScanner.lastContextUsage(of: url)
                    return (items, usage.tokens, 0, usage.model, 0, [], 0, nil, nil)
                }
                // A transcript no reader is named for is read by none: an
                // empty page, never another agent's reader on its file.
                guard agentKey == "claude_code" else {
                    return ([], 0, 0, nil, 0, [], 0, nil, nil)
                }
                let reading = AgentSessionScanner.readHistoryReaching(
                    of: url, includeThinking: withThoughts)
                var items = Self.keepingThoughts(reading.items, all: allThoughts, in: chatOnlyTurns)
                // Kill/quit residue: the newest turn's records simply
                // stop, with no turn-end marker, and nothing is still
                // writing. Say "interrupted" explicitly instead of
                // letting the transcript end mid-thought.
                //
                // Two independent liveness proofs are required, because
                // claiming this wrongly is worse than staying silent —
                // the marker then sits above an answer that did arrive:
                //   * claude's own heartbeat must not say busy, and
                //   * the file must have been quiet for a moment. A
                //     writer between records is mid-turn even if its
                //     heartbeat is unreadable (an older claude, a
                //     cleaned sessions dir).
                // The marker is still only a snapshot of this instant —
                // `dropInterruptedMarker` retracts it if the session
                // turns out to be alive after all.
                if !items.isEmpty, AgentSessionScanner.endsMidTurn(of: url) {
                    let sid = url.deletingPathExtension().lastPathComponent
                    let quietFor = Self.fileStat(url)
                        .map { Date().timeIntervalSince($0.mtime) } ?? .infinity
                    if ClaudeSessionStatusStore.verdict(sessionId: sid) != .busy,
                       quietFor >= 5 {
                        items.append(AgentSessionHistoryItem(kind: .interrupted(
                            message: AgentRunner.interruptedByUserMessage)))
                    }
                }
                // Warm the markdown cache for the rows the first frame
                // renders — cold parses during row realization were
                // most of the visible click-to-content delay.
                Self.prewarmMarkdown(items)
                // Zero visible turns: name what the file DOES hold so
                // the empty state can explain itself (a `/clear` fork
                // that was exited records only local commands).
                let commands = items.isEmpty
                    ? AgentSessionScanner.localCommandNames(of: url)
                    : []
                let usage = AgentSessionScanner.lastContextTokens(of: url)
                return (items,
                        usage.tokens,
                        // Claude records no window in the transcript —
                        // it is resolved from the model instead
                        // (`ContextWindowResolver`), which is why the
                        // model rides out of the read.
                        0, usage.model,
                        // Off-main by construction — this is the only
                        // place the transcript is read for the clock.
                        AgentSessionScanner.lastTurnDurationSeconds(of: url),
                        commands, 0, usage.speed, reading.reachedStart)
            }.value
            guard case .existing(let sid, let current, _, _) = mode, current == url else {
                // The user switched away mid-load.
                return
            }
            // The turn this read began under has ended since: the read may
            // stop short of its end, which the live buffer drew.
            if TranscriptSeam.readIsStale(turnStartAtRead: turnAtRead,
                                          turnStartNow: currentRunner?.status.runningSince) {
                startHistoryLoad(url: url, viaSpinner: viaSpinner)
                return
            }
            // Kimi's window joins here: the wire named the model, the
            // config names that model's `max_context_size`, and the
            // catalog holding the config is MainActor state the
            // detached read could not touch. `ensureLoaded()` is one
            // stat when nothing changed.
            var window = loaded.contextWindow
            if window == 0, agentKey == "kimi", let model = loaded.contextModel {
                KimiCatalog.shared.ensureLoaded()
                if let w = KimiCatalog.shared.maxContextSize(forModel: model),
                   w > 0 {
                    window = w
                }
            }
            historyCache.store(
                AgentHistoryCache.Entry(
                    items: loaded.items,
                    contextTokens: loaded.contextTokens,
                    contextWindow: window,
                    contextModel: loaded.contextModel,
                    lastCallSpeed: loaded.lastCallSpeed,
                    turnDuration: loaded.turnDuration,
                    commands: loaded.commands,
                    fileSize: stat?.size ?? 0,
                    fileMtime: stat?.mtime ?? .distantPast,
                    inheritedBytes: loaded.inheritedBytes,
                    readReachedStart: loaded.reachedStart,
                    chatOnlyTurns: chatOnlyTurns,
                    allThoughts: allThoughts
                ),
                for: sid
            )
            inheritedHistoryBytes = loaded.inheritedBytes
            historyReadReachedStart = loaded.reachedStart
            adoptHistory(loaded.items, fromFile: true)
            // This read used the DEFAULT budget whatever the view held
            // before (a reload of a widened transcript lands here too),
            // so the scope verdict is judged against that budget, not a
            // stale wider one.
            historyLoadedBudget = AgentSessionScanner.historyByteBudget
            historyTurnCapApplies = true
            updateHistoryScope(items: loaded.items,
                               fileSize: stat?.size ?? 0)
            seededContextTokens = loaded.contextTokens
            seededContextWindow = window
            seededContextModel = loaded.contextModel
            seededCallSpeed = loaded.lastCallSpeed
            // Into the runner as well, for the same reason
            // `noteExternalTurnDuration` exists: `reload()` cleared the
            // live mirror a moment ago and the runner's replay is about
            // to refill it, so a total left over from an earlier turn of
            // ours would outrank this freshly-read one — the composer
            // would go on showing the older number over a transcript
            // that has moved on. This read IS of the current file, so it
            // is never the staler of the two.
            currentRunner?.noteTranscriptContextTokens(loaded.contextTokens,
                                                       window: window)
            seededTurnDuration = loaded.turnDuration
            emptySessionCommands = loaded.commands
            if viaSpinner {
                isLoading = false
            } else {
                repositionNonce &+= 1
            }
        }
    }

    /// Put a read of the transcript on the page, meeting the live buffer
    /// below it exactly (`TranscriptSeam`): the read cut where the
    /// running turn begins, and the buffer left with what the read does
    /// not hold — nothing with no turn running, the running turn alone
    /// once a read of the file has reached its start. Every read lands
    /// here: the history cache's copy (`fromFile: false`, which may
    /// predate turns the buffer holds), a read of the file, and "Show
    /// earlier".
    private func adoptHistory(_ read: [AgentSessionHistoryItem], fromFile: Bool) {
        let runner = currentRunner
        let cut = TranscriptSeam.cut(
            read, runningTurnText: runner?.runningTurnStart != nil ? runner?.inFlightUserText : nil)
        historicalItems = cut.items
        switch TranscriptSeam.liveBuffer(turnRunning: runner?.status.isRunning ?? false,
                                         readFromFile: fromFile,
                                         readHeldRunningTurn: cut.heldRunningTurn) {
        case .nothing: runner?.clearEvents()
        case .runningTurn: runner?.dropTurnsBeforeRunningTurn()
        case .everything: break
        }
    }

    /// Feed the newest renderable texts through the markdown parser so
    /// first render is cache hits. The loader calls it off-main for
    /// the whole display window; the cache-hit open calls it on-main
    /// for just the visible tail (warm rows are ~free; cold ones cost
    /// a few ms up front instead of an empty-frame stall after the
    /// switch).
    ///
    /// Nonisolated for the off-main callers, like `fileStat` below: it
    /// touches no view state, and `MarkdownRenderer`'s cache is
    /// lock-guarded precisely so prewarming can run off the render path.
    nonisolated private static func prewarmMarkdown(_ items: [AgentSessionHistoryItem],
                                                    tail: Int = 40) {
        var texts: [String] = []
        for item in items.suffix(tail) {
            switch item.kind {
            case .userText(let t), .assistantText(let t):
                texts.append(t)
            default:
                break
            }
        }
        MarkdownRenderer.prewarm(texts)
    }

    /// The thoughts a read keeps: every one while compact view is on
    /// (`all`), else `AgentSessionHistoryItem.keepingThoughts` for a read
    /// that asked for thoughts only because the session has Chat only
    /// turns — a no-op for one that has none, so it pays nothing.
    /// Nonisolated for the detached readers.
    nonisolated private static func keepingThoughts(
        _ items: [AgentSessionHistoryItem], all: Bool, in turns: Set<String>)
    -> [AgentSessionHistoryItem] {
        all || turns.isEmpty ? items
            : AgentSessionHistoryItem.keepingThoughts(items, inTurns: turns)
    }

    /// Nonisolated: the history loader stats the file from its
    /// detached read task (the marker's quiet-window check).
    ///
    /// `size` is the size of the TEXT — what the partiality verdict
    /// weighs a bounded read against: a compressed codex rollout's is
    /// what it decodes to, read off the file whichever form codex has
    /// left it in (`SessionFileCompression`).
    nonisolated private static func fileStat(_ url: URL)
    -> (size: UInt64, mtime: Date)? {
        var file = url
        if SessionFileCompression.isCompressed(url),
           FileManager.default.fileExists(atPath: SessionFileCompression.unpacked(url).path) {
            file = SessionFileCompression.unpacked(url)
        } else if !FileManager.default.fileExists(atPath: url.path) {
            file = SessionFileCompression.packed(url)
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = SessionFileCompression.isCompressed(file)
                ? AgentSessionScanner.contentSize(of: file)
                : (attrs[.size] as? NSNumber)?.uint64Value
        else { return nil }
        return (size, mtime)
    }
}

// MARK: - RunnerStreamView

// `TranscriptGeometry` and the follow rule itself live in
// `Utilities/TranscriptFollow.swift` — one object, shared with
// `ChatView`.

/// The held row's distance from the newest row — see
/// `RunnerStreamView.heldAnchor` for why it is an object and not `@State`.
private final class HeldRowAnchor {
    var fromEnd: Int? = nil
}

/// Observes one AgentRunner and renders its live events below the
/// JSONL-derived historical turns. Split out as an @ObservedObject
/// subview so SwiftUI re-renders on event-buffer mutations without
/// forcing the parent to own the observation.
private struct RunnerStreamView: View {
    @ObservedObject var runner: AgentRunner
    @EnvironmentObject var mcpBridge: MCPBridge
    @EnvironmentObject var config: ConfigManager
    /// Read at key time only, for `ApprovalCardKeys.overlayHasKeys`.
    @EnvironmentObject var appState: AppState

    /// This transcript's agent under the user's own label — the runner
    /// knows which CLI it drives, so nothing here has to be told.
    private var agentName: String {
        let fallback = AgentManager.registry
            .first { $0.key == runner.agentKey }?.name ?? "Claude Code"
        return config.agentLabel(for: runner.agentKey, defaultName: fallback)
    }
    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.sipLineSpacingFactor) private var lineSpacingFactor

    /// The tier's line pitch over Default's — every fixed gap between
    /// rows in this transcript is a Default-tier value times this, so
    /// two turns never sit closer together than two wrapped lines of
    /// one of them. Same rule, same function, as the markdown renderer
    /// (`SipFont.transcriptGapScale`).
    private var gapScale: CGFloat {
        SipFont.transcriptGapScale(fontScale: fontScale,
                                   lineSpacingFactor: lineSpacingFactor)
    }

    /// Gap between the lines of an expanded tool body. Each row is a
    /// LINE of output, so the rows are spaced exactly as the wrapped
    /// lines inside one of them are — floored at the design's 1 pt.
    private var toolRowSpacing: CGFloat {
        max(1 * gapScale, 13 * fontScale * lineSpacingFactor)
    }

    /// Historical items from the JSONL file on disk, rendered ABOVE
    /// the live event list. Empty on a fresh draft. Each item goes
    /// through the same `toolActivityChip` / `orphanResultChip` /
    /// `MessageBubble` renderers used for live events, so the visual
    /// shape of past and present turns is identical.
    let historicalItems: [AgentSessionHistoryItem]
    let isLoadingHistory: Bool

    /// Older turns exist ON DISK beyond `historicalItems` and a wider
    /// read can still fetch them. Keeps "Show earlier" offered when
    /// the loaded rows run out — without it the button silently
    /// vanished at the read bound (50 turns of an 8 MB tail) with the
    /// session's start unreachable, however long the file was.
    let historyHasMore: Bool
    /// A wider read is in flight; the button says so and stops taking
    /// clicks it could not serve.
    let isWideningHistory: Bool
    /// Non-nil once the widen ladder is exhausted with the file still
    /// bigger than the widest read — rendered as a STATIC line in the
    /// button's place, naming the sizes (the no-silent-caps rule).
    let historyTruncationNote: String?
    /// Climb one rung of the parent's widen ladder.
    let onLoadEarlier: () -> Void

    /// Shared with the live path — `eventId` for live rows, `item.id`
    /// for historical rows. The two never collide because both are
    /// freshly-minted UUIDs.
    @Binding var expandedToolResults: Set<UUID>

    /// Which activity lines are open — the parent's state, for the reason
    /// `expandedToolResults` is.
    @Binding var expandedActivityLines: Set<UUID>

    /// The handles of this session's turns that ran in Chat only
    /// (`ConfigManager.agentChatOnlyTurns`). A history turn whose user
    /// row carries one draws its thoughts and web lookups as one line; a
    /// live turn says so itself (`StreamEvent.chatOnlyTurn`).
    let chatOnlyTurns: Set<String>

    /// Compact view (Settings → Display, the toolbar's window, View →
    /// Agent Session Compact View): every turn's run of thoughts and tool
    /// calls drawn as one line, the agent's name once per answer.
    let compact: Bool

    /// In draft mode (no history, no events yet) this is shown to
    /// explain the target cwd.
    let draftCwd: URL?

    /// Custom group the draft will be filed into, or nil. Shown beside
    /// the cwd for the same reason: both are decisions the + made on
    /// the user's behalf, and neither is visible anywhere else until
    /// the session exists.
    let draftCustomGroup: String?

    /// Local slash-commands found in a zero-turn transcript ("/clear",
    /// "/exit"). Rendered under the empty state so the file's origin
    /// isn't a mystery.
    let emptySessionCommands: [String]

    /// Label to use for assistant-side `MessageBubble`s (honouring the
    /// user's renamed Claude Code label). Passed all the way down so
    /// both live events and historical turns share the override.
    let assistantLabel: String

    /// Bumped by the parent after an in-place history swap (cache-hit
    /// refresh landed newer content) — pull to the new end.
    let repositionNonce: Int

    /// Cmd+F over this transcript. Owned by the PARENT (the composer's
    /// button toggles it and a global-search result seeds it), observed
    /// here because this is the view that holds the rows, the render
    /// windows and the scroll position — everything a jump needs.
    @ObservedObject var find: TranscriptFindState

    // MARK: Branching
    //
    // All of it is the parent's state, passed down. A transcript row is
    // re-rendered on every streamed event and re-created wholesale by a
    // history swap, so nothing about a half-typed edit may live here.

    /// Whether user rows offer the branch pencil at all (see
    /// `AgentSessionView.canBranch`).
    let canBranch: Bool
    @Binding var editingRowId: UUID?
    @Binding var editDraft: String
    let branching: Bool
    /// `(the row, its text, the skills it names under it)`.
    let onBeginEdit: (UUID, String, [String]) -> Void
    /// `(record uuid or nil for a live row, the original text, the
    /// edited text, and — for a live row, whose record is resolved by a
    /// newest-first text match — how many newer live rows say the same
    /// thing, so the pencil on the older of two identical rows cuts at
    /// that one)`.
    let onCreateBranch: (String?, String, String, Int) -> Void
    /// Send: `(the row, then onCreateBranch's four)` — the session goes
    /// back to the row and the edit is sent there
    /// (`AgentSessionView.editSessionInPlace`).
    let onSendInPlace: (UUID, String?, String, String, Int) -> Void
    /// Whether the installed tool can take this session back to a message
    /// (`AgentSessionRewind.support`).
    let rewindSupport: AgentSessionRewind.Support
    let onCancelEdit: () -> Void
    /// A card switched claude to another permission mode — a plan
    /// approved into one, an edit allowed for good; the argument is that
    /// mode as the chip spells it (`AgentSessionView.adoptSessionMode`).
    let onModeAdopted: (String) -> Void
    /// "Yes, implement in …" on the card a codex Plan turn ends with; the
    /// argument is the mode it names, as the chip spells it
    /// (`AgentSessionView.implementProposedPlan`).
    let onImplementPlan: (String) -> Void

    init(runner: AgentRunner,
         historicalItems: [AgentSessionHistoryItem],
         isLoadingHistory: Bool,
         historyHasMore: Bool,
         isWideningHistory: Bool,
         historyTruncationNote: String?,
         onLoadEarlier: @escaping () -> Void,
         expandedToolResults: Binding<Set<UUID>>,
         expandedActivityLines: Binding<Set<UUID>>,
         chatOnlyTurns: Set<String>,
         compact: Bool,
         draftCwd: URL?,
         draftCustomGroup: String?,
         emptySessionCommands: [String],
         assistantLabel: String,
         repositionNonce: Int,
         find: TranscriptFindState,
         canBranch: Bool,
         editingRowId: Binding<UUID?>,
         editDraft: Binding<String>,
         branching: Bool,
         onBeginEdit: @escaping (UUID, String, [String]) -> Void,
         onCreateBranch: @escaping (String?, String, String, Int) -> Void,
         onSendInPlace: @escaping (UUID, String?, String, String, Int) -> Void,
         rewindSupport: AgentSessionRewind.Support,
         onCancelEdit: @escaping () -> Void,
         onModeAdopted: @escaping (String) -> Void,
         onImplementPlan: @escaping (String) -> Void) {
        self.runner = runner
        self.historicalItems = historicalItems
        self.isLoadingHistory = isLoadingHistory
        self.historyHasMore = historyHasMore
        self.isWideningHistory = isWideningHistory
        self.historyTruncationNote = historyTruncationNote
        self.onLoadEarlier = onLoadEarlier
        self._expandedToolResults = expandedToolResults
        self._expandedActivityLines = expandedActivityLines
        self.chatOnlyTurns = chatOnlyTurns
        self.compact = compact
        self.draftCwd = draftCwd
        self.draftCustomGroup = draftCustomGroup
        self.emptySessionCommands = emptySessionCommands
        self.assistantLabel = assistantLabel
        self.repositionNonce = repositionNonce
        self.find = find
        self.canBranch = canBranch
        self._editingRowId = editingRowId
        self._editDraft = editDraft
        self.branching = branching
        self.onBeginEdit = onBeginEdit
        self.onCreateBranch = onCreateBranch
        self.onSendInPlace = onSendInPlace
        self.rewindSupport = rewindSupport
        self.onCancelEdit = onCancelEdit
        self.onModeAdopted = onModeAdopted
        self.onImplementPlan = onImplementPlan
    }

    // Nothing in this view is time-based, deliberately — a 1 Hz tick
    // would re-render the entire transcript once a second for the
    // whole of every turn, on top of the re-render each streamed
    // event already causes. The clock lives in the composer strip's
    // `TurnClockChip`, a leaf view.

    /// Whether the "Loading session history…" row has earned its
    /// place. A warm transcript read finishes in a few tens of
    /// milliseconds, and a spinner that appears and vanishes inside
    /// that window reads as a flicker rather than as progress — so
    /// nothing renders until the read has actually been slow. The
    /// token invalidates a pending arm when the read lands first
    /// (`isLoadingHistory` is a `let` captured by VALUE in escaping
    /// closures, so it cannot be re-checked there; @State can).
    @State private var showLoadingRow = false
    @State private var loadToken = 0

    private func armLoadingRow() {
        loadToken &+= 1
        let token = loadToken
        if showLoadingRow { showLoadingRow = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if loadToken == token { showLoadingRow = true }
        }
    }

    // MARK: - Tool use ↔ result pairing (desktop style)

    /// A tool result folded into its originating tool-use chip.
    private struct PairedResult {
        let output: String
        let isError: Bool
    }

    /// Pair every tool result with its tool use across BOTH the
    /// historical items and the live event stream, so a chip shows its
    /// outcome inline and the standalone result row disappears. Results
    /// whose use isn't in the visible window (history cap) stay
    /// unconsumed and render as orphan chips.
    private var toolPairing: Pairing {
        var knownUses: Set<String> = []
        for item in historicalItems {
            if case .toolUse(let id, _, _) = item.kind { knownUses.insert(id) }
        }
        for event in runner.events {
            if case .toolUse(let id, _, _) = event.kind { knownUses.insert(id) }
        }
        var byUse: [String: PairedResult] = [:]
        var consumed: Set<UUID> = []
        func claim(_ rowId: UUID, _ toolUseId: String,
                   _ output: String, _ isError: Bool) {
            guard knownUses.contains(toolUseId), byUse[toolUseId] == nil else {
                return
            }
            byUse[toolUseId] = PairedResult(output: output, isError: isError)
            consumed.insert(rowId)
        }
        for item in historicalItems {
            if case .toolResult(let tid, let content, let isError) = item.kind {
                claim(item.id, tid, content, isError)
            }
        }
        for event in runner.events {
            if case .toolResult(let tid, let output, let isError) = event.kind {
                claim(event.id, tid, output, isError)
            }
        }

        return (byUse, consumed)
    }

    private typealias Pairing = (byUseId: [String: PairedResult],
                                 consumed: Set<UUID>)

    // MARK: - Activity lines
    //
    // A Chat only turn draws its thoughts and web lookups as ONE line
    // under the question, and with compact view on so does every turn's
    // run of thoughts and tool calls; `ChatOnlyActivity` holds the rules.
    // The layout is computed once per render pass over every row this view
    // holds, like `toolPairing`, and with compact view off costs nothing
    // for a session with no Chat only turn in it.

    /// One member of an activity line: a row from either array.
    private enum ActivityMember: Identifiable {
        case history(AgentSessionHistoryItem)
        case event(StreamEvent)

        var id: UUID {
            switch self {
            case .history(let item): return item.id
            case .event(let event): return event.id
            }
        }
    }

    /// A line as drawn: its key (its first member's row id, the one the
    /// open set remembers), the row it is drawn at, and its members.
    private struct ActivityLineRender {
        let key: UUID
        let anchorId: UUID
        let group: ChatOnlyActivity.Group
        let members: [ActivityMember]
        let isLive: Bool
    }

    private struct ActivityLayout {
        /// The line drawn at each anchor row.
        var lines: [UUID: ActivityLineRender] = [:]
        /// Member row id → its line's key. A member draws inside its
        /// line and never on its own.
        var lineOfMember: [UUID: UUID] = [:]

        /// A line is still being written. It IS the waiting row then —
        /// the same spinner, where "Sipping…" would be — so no second one
        /// is drawn under it (a background task's notice opens no row of
        /// its own: it is the live line's newest words).
        var hasLiveLine: Bool { lines.values.contains(where: \.isLive) }

        static let empty = ActivityLayout()
    }

    /// The fold's plan and the rows it leaves drawn, kept for as long as
    /// the rows are what they were (`activityPlan`). A CLASS in plain
    /// `@State`, like `HeldRowAnchor`: nothing is drawn from it that the
    /// rows do not already decide, and as rendered state every pass that
    /// filled it would re-render the transcript once more.
    final class ActivityPlanCache {
        struct Key: Equatable {
            let historyCount: Int
            let historyFirst: UUID?, historyLast: UUID?
            let eventCount: Int
            let eventFirst: UUID?, eventLast: UUID?
            let compact: Bool, turnRunning: Bool, answerSettled: Bool
            let chatOnlyTurns: Set<String>
            let trimmedHeadChatOnly: Bool
        }
        var key: Key?
        var plan: ChatOnlyActivity.Plan = .empty
        /// Per row over history + live buffer: whether it is drawn on its
        /// own at the transcript's top level — a row of its own, or the
        /// first member of a line (a line counts once, however many rows
        /// it holds). A result folded into its chip, plumbing and every
        /// later member of a line draw nothing there. Empty when nothing
        /// folds.
        var drawn: [Bool] = []

        /// Nothing folds: no plan, every row as it is.
        static let none = ActivityPlanCache()
    }

    /// Whether anything folds at all: compact view, a recorded Chat only
    /// turn, or a live one (whose message the live buffer may have
    /// trimmed away). Otherwise every row draws as it always has, and the
    /// plan is never worked out.
    private var anythingFolds: Bool {
        compact || !chatOnlyTurns.isEmpty || runner.trimmedHeadChatOnly
            || runner.events.contains(where: \.chatOnlyTurn)
    }

    /// The fold over every row, and which rows it leaves drawn on their
    /// own, worked out once per state of the rows: the window, the layout,
    /// the name pass and find each ask, several times a pass.
    private func activityPlan(pairing given: Pairing? = nil) -> ActivityPlanCache {
        guard anythingFolds else { return .none }
        let turnRunning = runner.status.isRunning || runner.externalInProgress
        let answerSettled = !runner.awaitedBackgroundTasks.isEmpty
        let key = ActivityPlanCache.Key(
            historyCount: historicalItems.count,
            historyFirst: historicalItems.first?.id, historyLast: historicalItems.last?.id,
            eventCount: runner.events.count,
            eventFirst: runner.events.first?.id, eventLast: runner.events.last?.id,
            compact: compact, turnRunning: turnRunning, answerSettled: answerSettled,
            chatOnlyTurns: chatOnlyTurns, trimmedHeadChatOnly: runner.trimmedHeadChatOnly)
        if planCache.key == key { return planCache }
        let pairing = given ?? toolPairing
        let h = historicalItems.count
        let rows = activityRows(pairing: pairing)
        let plan = ChatOnlyActivity.plan(
            rows, turnRunning: turnRunning,
            liveStart: ChatOnlyActivity.LiveStart(row: h, chatOnly: runner.trimmedHeadChatOnly),
            compact: compact, answerSettled: answerSettled)
        var drawn = [Bool](repeating: true, count: rows.count)
        for (i, item) in historicalItems.enumerated() {
            switch item.kind {
            case .thinking: drawn[i] = false
            case .toolResult: drawn[i] = !pairing.consumed.contains(item.id)
            default: break
            }
        }
        for (j, event) in runner.events.enumerated() {
            switch event.kind {
            case .thinking, .systemInit, .result: drawn[h + j] = false
            case .toolResult: drawn[h + j] = !pairing.consumed.contains(event.id)
            default: break
            }
        }
        for group in plan.groups {
            for member in group.members.dropFirst() { drawn[member] = false }
            if let first = group.members.first { drawn[first] = true }
        }
        planCache.key = key
        planCache.plan = plan
        planCache.drawn = drawn
        return planCache
    }

    /// Every row reduced to what the fold reads (`ChatOnlyActivity.Row`).
    private func activityRows(pairing: Pairing) -> [ChatOnlyActivity.Row] {
        var rows: [ChatOnlyActivity.Row] = []
        rows.reserveCapacity(historicalItems.count + runner.events.count)
        // A compaction's summary is a notice in the user column that the
        // agent goes on after, inside the same answer — not one that
        // opens an answer of its own.
        var afterCompaction = false
        func toolRow(_ id: String, _ name: String,
                     _ input: [String: Any]) -> ChatOnlyActivity.Row {
            // The agent's question with its answer and a plan put to the
            // user are steps like any other: their cards stand apart while
            // they wait, and once answered they are in the line.
            let result = pairing.byUseId[id]
            return .toolUse(name: name, title: AgentRendering.displayToolName(name),
                            input: input, resultText: result?.output,
                            failed: result?.isError ?? false)
        }
        func userRow(_ text: String, notice: Bool, sentIntoTurn: Bool, belongsToAnswer: Bool,
                     chatOnly: @autoclosure () -> Bool) -> ChatOnlyActivity.Row {
            // A background task reporting back and the user's reply on a
            // question's card are part of the agent's answer: inside its
            // line, whichever turn carried them.
            if belongsToAnswer { return .notice(text) }
            // The user's own words sent into the running turn, and a
            // notice the turn took in as it went.
            if sentIntoTurn { return notice ? .notice(text) : .split }
            if notice { return afterCompaction ? .notice(text) : .answerStart }
            return .turnStart(chatOnly: chatOnly())
        }
        func add(_ row: ChatOnlyActivity.Row, compaction: Bool = false) {
            rows.append(row)
            switch row {
            case .invisible, .turnBoundary: return
            default: afterCompaction = compaction
            }
        }
        for item in historicalItems {
            switch item.kind {
            case .userText(let text):
                add(userRow(text, notice: item.isSystemNotice, sentIntoTurn: item.sentIntoTurn,
                            belongsToAnswer: item.belongsToAnswer,
                            chatOnly: item.recordUuid.map(chatOnlyTurns.contains) ?? false))
            case .assistantText(let text):
                add(.words(text))
            case .interrupted(let message), .error(let message):
                add(.outcome(message))
            case .compaction(let pre, let post):
                add(.notice(Self.compactionMessage(preTokens: pre, postTokens: post)), compaction: true)
            case .shellOutput:
                add(.answerStart)
            case .thinking(let text):
                add(.thought(text))
            case .toolUse(let id, let name, let input):
                add(toolRow(id, name, input))
            case .toolResult:
                add(.toolResult)
            }
        }
        for event in runner.events {
            switch event.kind {
            case .userMessage(let text):
                add(userRow(text, notice: event.isSystemNotice, sentIntoTurn: event.sentIntoTurn,
                            belongsToAnswer: event.belongsToAnswer,
                            chatOnly: event.chatOnlyTurn))
            case .assistantText(let text):
                add(.words(text))
            case .error(let message), .interrupted(let message):
                add(.outcome(message))
            case .compaction(let pre, let post):
                add(.notice(Self.compactionMessage(preTokens: pre, postTokens: post)), compaction: true)
            case .shellOutput:
                add(.answerStart)
            case .thinking(let text):
                add(.thought(text))
            case .toolUse(let id, let name, let input):
                add(toolRow(id, name, input))
            case .toolResult:
                add(.toolResult)
            // A turn's start: inside an answer, a turn the agent runs on
            // its own — for an event of claude's Monitor tool it is all
            // claude prints, so the final message is the newest turn's.
            case .systemInit: add(.turnBoundary)
            case .result: add(.invisible)
            }
        }
        return rows
    }

    /// `pairing` is the pass's own `toolPairing`: a codex search run
    /// through code mode names its query only in its result.
    private func activityLayout(pairing: Pairing) -> ActivityLayout {
        let plan = activityPlan(pairing: pairing).plan
        guard !plan.groups.isEmpty else { return .empty }
        let h = historicalItems.count
        func member(_ i: Int) -> ActivityMember {
            i < h ? .history(historicalItems[i]) : .event(runner.events[i - h])
        }
        // Both render windows are suffixes; a line is drawn at its first
        // member inside its array's window.
        let historyStart = h - displayedHistory.count
        let liveStart = h + runner.events.count - displayedEvents.count
        var layout = ActivityLayout()
        for (index, group) in plan.groups.enumerated() {
            let members = group.members.map(member)
            let key = members[0].id
            for m in members { layout.lineOfMember[m.id] = key }
            let windowStart = group.members[0] < h ? historyStart : liveStart
            guard let anchor = group.anchor(windowStart: windowStart) else { continue }
            let anchorId = member(anchor).id
            layout.lines[anchorId] = ActivityLineRender(
                key: key, anchorId: anchorId, group: group, members: members,
                isLive: plan.lastGroupIsLive && index == plan.groups.count - 1)
        }
        return layout
    }

    /// Who draws the agent's name in this pass (`ChatOnlyActivity.names`).
    private struct NameLayout {
        /// Chips and lines with the name above them, and bubbles whose
        /// header is the name.
        var named: Set<UUID> = []
        /// The agent's words drawn with NO header.
        var quiet: Set<UUID> = []
        /// The name goes over "Sipping…".
        var waitingNamed = false
    }

    /// Computed once per pass, after `activityLayout`, over every row: an
    /// answer opens at a row in the user column and its name goes to the
    /// first row it draws — a line at its anchor, a chip, its words; in an
    /// answer drawn compact, the first one the display window draws.
    private func transcriptNames(pairing: Pairing, activity: ActivityLayout) -> NameLayout {
        let h = historicalItems.count
        let historyStart = h - displayedHistory.count
        let liveFrom = runner.events.count - displayedEvents.count
        var rows: [ChatOnlyActivity.NameRow] = []
        var onScreen: [Bool] = []
        var ids: [UUID] = []
        rows.reserveCapacity(h + runner.events.count)
        onScreen.reserveCapacity(h + runner.events.count)
        ids.reserveCapacity(h + runner.events.count)
        func drawn(_ id: UUID, _ row: ChatOnlyActivity.NameRow) -> ChatOnlyActivity.NameRow {
            if activity.lines[id] != nil { return .line }
            if activity.lineOfMember[id] != nil { return .silent }
            return row
        }
        for (i, item) in historicalItems.enumerated() {
            onScreen.append(i >= historyStart)
            let row: ChatOnlyActivity.NameRow
            switch item.kind {
            // A notice or a reply in the user column is structure — unless a
            // line holds it (a compaction's summary, a notice the turn took
            // in), where it is one of the answer's own rows.
            case .userText:
                row = item.isSystemNotice || item.sentIntoTurn
                    ? drawn(item.id, .userColumn)
                    : .turnStart(chatOnly: item.recordUuid.map(chatOnlyTurns.contains) ?? false)
            // A `!` command's output is the command's, not the agent's: an
            // answer after it is one of its own.
            case .shellOutput: row = .userColumn
            case .assistantText: row = drawn(item.id, .words)
            case .toolUse: row = drawn(item.id, .chip)
            case .thinking: row = drawn(item.id, .silent)
            // Folded into its chip, or a rare orphan chip: neither opens an
            // answer nor names it.
            case .toolResult: row = drawn(item.id, .note)
            case .interrupted, .compaction, .error: row = drawn(item.id, .note)
            }
            rows.append(row)
            ids.append(item.id)
        }
        for (j, event) in runner.events.enumerated() {
            onScreen.append(j >= liveFrom)
            let row: ChatOnlyActivity.NameRow
            switch event.kind {
            case .userMessage:
                row = event.isSystemNotice || event.sentIntoTurn
                    ? drawn(event.id, .userColumn) : .turnStart(chatOnly: event.chatOnlyTurn)
            case .shellOutput: row = .userColumn
            case .assistantText: row = drawn(event.id, .words)
            case .toolUse: row = drawn(event.id, .chip)
            case .thinking: row = drawn(event.id, .silent)
            case .toolResult: row = drawn(event.id, .note)
            case .interrupted, .compaction, .error: row = drawn(event.id, .note)
            case .systemInit, .result: row = .silent
            }
            rows.append(row)
            ids.append(event.id)
        }
        let names = ChatOnlyActivity.names(
            rows, compact: compact,
            liveStart: ChatOnlyActivity.LiveStart(row: h, chatOnly: runner.trimmedHeadChatOnly),
            onScreen: onScreen)
        var out = NameLayout()
        for i in names.named { out.named.insert(ids[i]) }
        for i in names.quiet { out.quiet.insert(ids[i]) }
        out.waitingNamed = names.waitingNamed
        return out
    }

    // MARK: - Find in transcript
    //
    // The contract with `transcriptStack`: this list holds exactly the
    // rows the stack DRAWS, in draw order, and each row's text is the
    // concatenation of the pieces that row draws, also in order. A row
    // present here but not drawn (or the reverse) puts the counter and
    // the highlights on different transcripts.
    //
    // Matches cover the WHOLE loaded history, not the rendered window —
    // the window (`transcriptWindow`) is a rendering bound, and a find
    // that could only see 40 rows would be answering a different question
    // than the one asked. Jumping past the window grows it
    // (`jumpToActiveMatch`).

    /// Title of an orphaned tool result's chip. One constant, because
    /// the chip renders it and the search counts it, and a second
    /// spelling would put one match's worth of drift between them.
    private static var orphanChipTitle: String {
        String(localized: "Output",
               comment: "Chip title for a tool result without its call in view")
    }

    /// One tool chip's searchable pieces, in the order `chipShell`
    /// draws them: title, summary, the input body rows, then the
    /// folded result's rows.
    ///
    /// Collapsed chips are counted too. Their matches are simply not
    /// visible yet — jumping to one expands it — and making the count
    /// depend on what happens to be open would change the total every
    /// time a chevron is clicked.
    private func chipTexts(name: String, input: [String: Any],
                           result: PairedResult?) -> [String] {
        let summary = AgentRendering.toolSummary(name: name, input: input, resultOutput: result?.output)
        var texts = [AgentRendering.displayToolName(name), summary]
        texts += AgentRendering.fullToolBody(name: name, input: input).map(\.text)
        if let result {
            texts += AgentRendering.toolResultRows(name: name, output: result.output).map(\.text)
        }
        return texts
    }

    /// The agent's words inside an opened line: its bubble without the
    /// name, which the line already carries, and with find's highlight.
    private func memberWords(id: UUID, text: String) -> some View {
        MessageBubble(
            message: ChatMessage(id: id, role: "assistant", content: text),
            assistantLabelOverride: assistantLabel,
            showsHeader: false
        )
        .environment(\.sipSearchSlot, find.slot(forRow: id))
    }

    /// Title of a thought's row inside an opened line — the word each
    /// agent's own terminal puts over a thought. Composed, not the
    /// thought's own words, so it is not one of the row's pieces (the
    /// compaction row's rule).
    private static var thoughtChipTitle: String {
        String(localized: "Thinking",
               comment: "Title of one of the model's thoughts, a row inside an opened activity line; click it to read the whole thought")
    }

    /// A thought row's searchable pieces, in the order `thoughtRow`
    /// draws them: the first line on the closed row, then the whole
    /// thought (counted while closed — the collapsed-chip rule).
    private func thoughtTexts(_ text: String) -> [String] {
        [ChatOnlyActivity.headline(of: text), MarkdownRenderer.plainText(text, fileBase: runner.cwd.path)]
    }

    private func orphanChipTexts(output: String) -> [String] {
        [Self.orphanChipTitle, AgentRendering.summarizeToolResult(output)]
            + AgentRendering.fullToolResultBody(output).map(\.text)
    }

    /// Split a row's base slot across the row's own pieces, so piece `i`
    /// starts where piece `i-1`'s matches ended.
    private func pieceSlots(_ texts: [String],
                            base: SearchHighlightSlot) -> [SearchHighlightSlot] {
        guard base.isActive else {
            return Array(repeating: .inactive, count: texts.count)
        }
        var out: [SearchHighlightSlot] = []
        out.reserveCapacity(texts.count)
        var running = 0
        for text in texts {
            out.append(base.advanced(by: running))
            running += SearchMatching.count(of: base.query, in: text)
        }
        return out
    }

    /// Every drawn row, in draw order. Built only while a query is live
    /// — `TranscriptFindState.refresh` never calls the closure
    /// otherwise, which is what keeps this off the streaming path
    /// entirely when nobody is searching.
    ///
    /// With a find OPEN during a turn this runs per streamed event, so
    /// each row's text comes through `rowTextCache`: rows are immutable
    /// once created, and re-deriving a tool chip's body means splitting
    /// tens of kilobytes of output on the MainActor four times a second.
    private func searchableRows() -> [FindableRow] {
        let pairing = toolPairing
        // A thought draws only inside its line, so it is counted only
        // where it has one.
        let inLine = activityLayout(pairing: pairing).lineOfMember
        var rows: [FindableRow] = []
        rows.reserveCapacity(historicalItems.count + runner.events.count)
        // Exactly the rows that still exist, handed back to the memo at
        // the end so a cap-trimmed event's entry goes with it.
        var live: [TranscriptRowTextCache.Key: String] = [:]
        let fileBase = runner.cwd.path

        func add(_ id: UUID, resolved: Bool = false, _ build: () -> String) {
            let key = TranscriptRowTextCache.Key(id: id, resolved: resolved)
            let text = rowTextCache.text(for: key, build: build)
            live[key] = text
            rows.append(FindableRow(id: id, text: text))
        }

        for item in historicalItems {
            switch item.kind {
            case .userText(let text) where item.shellCommand:
                add(item.id) { MarkdownRenderer.plainText(ShellCommandInput.markdown(text), fileBase: fileBase) }
            case .userText(let text), .assistantText(let text):
                add(item.id) { MarkdownRenderer.plainText(text, fileBase: fileBase) }
            case .shellOutput(let output):
                add(item.id) { output.shown.text }
            // Drawn inside its turn's activity line (a Chat only turn's,
            // or any turn's in compact view), and counted while that line
            // is closed — the collapsed-chip rule.
            case .thinking(let text):
                guard inLine[item.id] != nil else { continue }
                add(item.id) { thoughtTexts(text).joined(separator: "\n") }
            case .toolUse(let id, let name, let input):
                let result = pairing.byUseId[id]
                add(item.id, resolved: result != nil) {
                    chipTexts(name: name, input: input, result: result)
                        .joined(separator: "\n")
                }
            case .toolResult(_, let content, _):
                // A consumed result is drawn inside its tool-use chip,
                // where it has already been counted.
                guard !pairing.consumed.contains(item.id) else { continue }
                add(item.id) {
                    orphanChipTexts(output: content).joined(separator: "\n")
                }
            case .interrupted(let message), .error(let message):
                add(item.id) { message }
            // Composed at render time from localized strings, so there
            // is nothing here to match a query against — see
            // `GlobalSearch.flatten`.
            case .compaction:
                continue
            }
        }

        for event in runner.events {
            switch event.kind {
            case .userMessage(let text) where event.shellCommand:
                add(event.id) { MarkdownRenderer.plainText(ShellCommandInput.markdown(text), fileBase: fileBase) }
            case .userMessage(let text), .assistantText(let text):
                add(event.id) { MarkdownRenderer.plainText(text, fileBase: fileBase) }
            case .shellOutput(let output):
                add(event.id) { output.shown.text }
            case .thinking(let text):
                guard inLine[event.id] != nil else { continue }
                add(event.id) { thoughtTexts(text).joined(separator: "\n") }
            case .toolUse(let id, let name, let input):
                let result = pairing.byUseId[id]
                add(event.id, resolved: result != nil) {
                    chipTexts(name: name, input: input, result: result)
                        .joined(separator: "\n")
                }
            case .toolResult(_, let output, _):
                guard !pairing.consumed.contains(event.id) else { continue }
                add(event.id) {
                    orphanChipTexts(output: output).joined(separator: "\n")
                }
            case .error(let message), .interrupted(let message):
                add(event.id) { message }
            // systemInit / result draw nothing (`EmptyView`), so they
            // are not rows; a compaction row's text is composed at
            // render time and so has nothing to match.
            case .systemInit, .result, .compaction:
                continue
            }
        }
        rowTextCache.replace(with: live)
        return rows
    }

    func refreshFind() {
        find.refresh { searchableRows() }
    }

    /// Bring the active match on screen. Grows whichever render window
    /// the match falls outside of, and opens a collapsed chip so the
    /// highlight it is naming can actually be seen.
    private func jumpToActiveMatch(_ proxy: ScrollViewProxy) {
        guard let match = find.activeMatch else { return }
        // A tool chip hides its body until opened. Inserting a row id
        // that is not a chip is harmless — the set is only ever
        // consulted by `chipShell`.
        expandedToolResults.insert(match.rowId)

        // The window is one run back from the newest row, over history
        // and the live buffer alike, so what matters is the match's place
        // in that run.
        //
        // Located by ROW ID, never by `match.rowIndex`: that index runs
        // over the SEARCHABLE rows, which skip every tool result folded
        // into its call, while the window runs over the raw arrays. On
        // any transcript with tool activity — i.e. all of them — the two
        // disagree, and the window would be grown by the wrong amount.
        var grew = false
        if let index = rowIndex(of: match.rowId), index < transcriptWindow.top {
            revealRows(through: index)
            grew = true
        }
        // A match inside a closed activity line: open the line too. Its
        // steps only exist once it is laid out open, so the scroll waits
        // a pass, like a window that grew.
        if let line = activityLayout(pairing: toolPairing).lineOfMember[match.rowId],
           !expandedActivityLines.contains(line) {
            expandedActivityLines.insert(line)
            grew = true
        }
        // Restores the follow engine's snap budget: our own jump
        // produces geometry samples and the engine must be able to
        // spend them. The sample itself takes the transcript OUT of
        // follow mode, so nothing pulls back to the end afterwards.
        follow.noteInput()
        let scroll = {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(match.rowId, anchor: .center)
            }
        }
        // A row grown into the window does not exist until that window
        // has been laid out; an id scrolled to in the same pass
        // resolves to nothing.
        if grew {
            DispatchQueue.main.async(execute: scroll)
        } else {
            scroll()
        }
    }

    /// Pending approvals belonging to this runner's session, by the
    /// bridge's one ownership rule. A session's FIRST turn asks under
    /// the draft's task uuid for as long as that child lives, so the
    /// runner's own uuid must keep matching after its session id is
    /// known — see `MCPBridge.request(sessionId:taskUuid:…)`.
    /// The card on the shared keyboard: the newest one a turn waits on,
    /// else the plan follow-up.
    private var activeCardId: String? {
        approvalsForRunner.last?.id ?? (showsPlanFollowUp ? planFollowUpCardId : nil)
    }

    /// "Implement this plan?" is up: a codex Plan turn ended on a plan, the
    /// turn is over, no card is waiting, and nobody else is mid-turn on
    /// the thread (an answer would be a second writer on it).
    private var showsPlanFollowUp: Bool {
        runner.planFollowUp != nil && !runner.status.isRunning
            && !runner.externalInProgress && approvalsForRunner.isEmpty
    }

    private var planFollowUpCardId: String { "plan-follow-up:" + runner.key }

    private var approvalsForRunner: [MCPApprovalRequest] {
        mcpBridge.pending(forSession: runner.sessionId,
                          taskUuid: runner.taskUuidForBridge)
    }

    /// Rows drawn above the newest live ones (`TranscriptSeam.window`):
    /// with no live rows — at open — the history rows that render first.
    /// They are laid out EAGERLY (see `transcriptStack`), so this is the
    /// knob that trades open-time cost against how far back you can
    /// scroll before "Show earlier", which adds 200. The live rows below
    /// them are capped at `TranscriptSeam.liveRows` — mostly one-line
    /// tool chips, and an EMPTY stack at open (`clearEvents()`), so their
    /// cost is paid a row at a time as a turn streams. Reset per session
    /// by the parent's `.id(runner.key)`.
    @State private var earlierRows = 40

    /// The first drawn row while the reader is away from the end, so the
    /// window holds still under them instead of sliding (`TranscriptSeam
    /// .window`). An id, not an index: the live buffer is cut back from
    /// the front, and an index would then name another row. Nil while
    /// they follow the end.
    @State private var heldTopId: UUID? = nil

    /// The held row's distance from the newest row, kept beside its id
    /// (`TranscriptSeam.heldIndex`): every history row's id is minted per
    /// parse, so a read landing while the window is held — a wider read
    /// behind "Show earlier", a read taken again after its turn ended —
    /// leaves the id naming nothing, and a window with no held row slides,
    /// the rows above the reader with it. An object, not `@State`: it is
    /// refreshed on every sample and every streamed row while the id
    /// still resolves, and nothing is drawn from it that the id does not
    /// already decide — written as `@State` that often, it would re-render
    /// the transcript once more per row for the length of a hold.
    @State private var heldAnchor = HeldRowAnchor()

    /// `activityPlan`'s memo.
    @State private var planCache = ActivityPlanCache()

    /// The rows drawn, over `historicalItems` and the live buffer below.
    private var transcriptWindow: TranscriptSeam.Window {
        TranscriptSeam.window(historyCount: historicalItems.count,
                              liveCount: runner.events.count,
                              earlierRows: earlierRows,
                              heldTop: heldIndex,
                              draws: drawnRows)
    }

    /// In compact view the window, its "Show earlier" and its reveals count
    /// rows DRAWN, a line once (`ActivityPlanCache.drawn`); drawn in full,
    /// rows. Nil when nothing is folded.
    private var drawnRows: ((Int) -> Bool)? {
        guard compact else { return nil }
        let drawn = activityPlan().drawn
        guard drawn.count == rowCount else { return nil }
        return { drawn[$0] }
    }

    /// Rows above the window, as the window counts them.
    private func rowsAbove(_ window: TranscriptSeam.Window) -> Int {
        guard let draws = drawnRows else { return window.top }
        return TranscriptSeam.drawnCount(0..<window.top, draws)
    }

    private var rowCount: Int { historicalItems.count + runner.events.count }

    /// Where the held row is now, by the rule.
    private var heldIndex: Int? {
        guard let id = heldTopId else { return nil }
        return TranscriptSeam.heldIndex(resolved: rowIndex(of: id),
                                        fromEnd: heldAnchor.fromEnd,
                                        rowCount: rowCount)
    }

    /// Hold the window at `index`: the row's id, and its distance from the
    /// newest row for the read that takes the id away. Writes state only
    /// when the id changes — a new row, or a row's id given back after a
    /// read.
    private func holdWindow(at index: Int) {
        guard let id = rowId(at: index) else { return }
        if id != heldTopId { heldTopId = id }
        heldAnchor.fromEnd = rowCount - index
    }

    private func releaseHold() {
        heldTopId = nil
        heldAnchor.fromEnd = nil
    }

    private var displayedHistory: ArraySlice<AgentSessionHistoryItem> {
        historicalItems.suffix(transcriptWindow.historyShown)
    }

    private var displayedEvents: ArraySlice<StreamEvent> {
        runner.events.suffix(transcriptWindow.liveShown)
    }

    /// A row's place over history + live buffer, the window's index space.
    private func rowIndex(of id: UUID) -> Int? {
        if let i = historicalItems.firstIndex(where: { $0.id == id }) { return i }
        return runner.events.firstIndex(where: { $0.id == id })
            .map { historicalItems.count + $0 }
    }

    private func rowId(at index: Int) -> UUID? {
        let h = historicalItems.count
        if index < h { return index >= 0 ? historicalItems[index].id : nil }
        return index - h < runner.events.count ? runner.events[index - h].id : nil
    }

    /// Hold the window when the reader leaves the end, let it go once
    /// they are at it (`TranscriptSeam.holdChange`). Asked after every
    /// sample the follow engine takes; writes state only when the answer
    /// changes it.
    private func syncWindowHold(_ geometry: TranscriptGeometry) {
        let held = heldIndex
        switch TranscriptSeam.holdChange(following: follow.isNearBottom,
                                         distanceFromEnd: Double(geometry.distanceFromEnd),
                                         heldRowOnPage: held != nil) {
        case .hold: holdWindow(at: transcriptWindow.top)
        case .letGo: releaseHold()
        // Held: the row's distance kept current, and its id given back
        // once a read has re-minted the history's.
        case .none: if let held { holdWindow(at: held) }
        }
    }

    /// "Show earlier": 200 more rows above the first row drawn — counted
    /// from that row, not added to the last count, since a held window
    /// has grown past its count (`TranscriptSeam.earlierRowsAfterShowEarlier`).
    /// A held window is held at its new top — grown alone, it would slide
    /// back down to the old one, a row per streamed row. The 200 are added
    /// whole even when fewer rows are loaded above: a wider read of the
    /// file is under way then, and the rows it lands are drawn at once.
    /// In compact view all of this is counted in drawn rows (`drawnRows`).
    private func showEarlierRows() {
        let top = transcriptWindow.top
        if let draws = drawnRows {
            let h = historicalItems.count
            earlierRows = TranscriptSeam.earlierRowsAfterShowEarlier(
                top: TranscriptSeam.drawnCount(0..<top, draws), earlierRows: earlierRows,
                historyCount: TranscriptSeam.drawnCount(0..<h, draws),
                liveCount: TranscriptSeam.drawnCount(h..<rowCount, draws))
            if heldTopId != nil {
                holdWindow(at: TranscriptSeam.start(holding: TranscriptSeam.drawnCount(top..<rowCount, draws) + 200,
                                                    before: rowCount, draws))
            }
            return
        }
        earlierRows = TranscriptSeam.earlierRowsAfterShowEarlier(top: top, earlierRows: earlierRows,
                                                                 historyCount: historicalItems.count,
                                                                 liveCount: runner.events.count)
        if heldTopId != nil { holdWindow(at: max(0, top - 200)) }
    }

    /// Grow the window up to a few rows above `index`, held the same way.
    /// In compact view a row inside a line is revealed through the line's
    /// FIRST member: the window counts a line there and draws it there,
    /// and a line whose members all sit above the window is not drawn at
    /// all. Grown to the matched member alone, the only drawn row between
    /// it and the window's top can be the answer's last words — the
    /// window stops there, and a find jump lands on nothing.
    private func revealRows(through index: Int) {
        let top = transcriptWindow.top
        let through = drawnRows == nil
            ? index
            : activityPlan().plan.group(containing: index)?.members.first ?? index
        let newTop = max(0, through - 5)
        guard newTop < top else { return }
        earlierRows += drawnRows.map { TranscriptSeam.drawnCount(newTop..<top, $0) } ?? top - newTop
        if heldTopId != nil { holdWindow(at: newTop) }
    }

    // MARK: Bottom-follow engine
    //
    // The transcript opens at its end because the scroll view is BORN
    // there (`ScrollPosition(edge: .bottom)`), not because anything
    // measures a wrong position afterwards and corrects it. Everything
    // this view does after that is one rule: when the CONTENT grows
    // under a reader who was already at the end, stay at the end.
    //
    // Hiding the transcript until geometry confirms arrival produces
    // the blank-until-scroll failure: the hide is a visible dead beat,
    // and a reveal that depends on a geometry sample can strand the
    // view invisible. Do not reintroduce a correction loop here.

    /// The scroll view's position. Initialised AT the bottom edge, so
    /// the first frame is already at the newest row — there is no
    /// arrival to detect and therefore nothing to hide.
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    /// The follow rule, its thresholds, and the budget that stops it
    /// re-entering off its own output. Plain `@State` holding a CLASS
    /// on purpose: none of its fields are rendered, so mutating them
    /// must not invalidate this body. See
    /// `Utilities/TranscriptFollow.swift`.
    @State private var follow = TranscriptFollow(label: "transcript")

    /// The line being read, kept under the top of the transcript when the
    /// text size changes while it is on screen (View → Zoom In / Zoom Out
    /// / Actual Size). A class in plain `@State`, like `follow`: written on
    /// every layout, never drawn. See `Utilities/ReadingPlace.swift`.
    @State private var readingPlace = ReadingPlace()

    /// Searchable text per row, so a find left open during a turn does
    /// not re-derive every chip on every streamed event. A class in
    /// plain `@State` for the same reason `follow` is one: nothing it
    /// holds is rendered.
    @State private var rowTextCache = TranscriptRowTextCache()

    /// Arrow keys and Return for the newest card at the end of this
    /// transcript. A class in plain `@State`, like `follow`: nothing it
    /// holds is rendered — the cards hear it through its publisher.
    @State private var cardKeys = ApprovalCardKeys()

    /// Go to the newest row. Unlike `scrollTo(id:)` this asks the
    /// scroll view for its own bottom edge, so it does not depend on
    /// resolving a row through lazy content of unknown height.
    private func scrollToEnd() {
        scrollPosition.scrollTo(edge: .bottom)
    }

    /// The size every row is laid out at — what tells `readingPlace` a
    /// layout from the one before it.
    private var readingSize: ReadingPlace.Size {
        ReadingPlace.Size(fontScale: fontScale, lineSpacing: lineSpacingFactor)
    }

    /// Back to the line being read after a change of size. Asked only for
    /// a reader who was not following the end — `readingPlace` judges that
    /// on the layout before the change, since a page that shrinks can
    /// clamp a reader mid-page to the end.
    private func restoreReadingPlace(_ offset: CGFloat) {
        scrollPosition.scrollTo(y: offset)
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            transcriptStack
                .coordinateSpace(.named(ReadingPlace.space))
        }
        // Born at the end. This is the whole "sessions open at their
        // newest row" feature — an initial position the scroll view
        // honours on its first layout pass, not a jump performed
        // afterwards and hidden until it lands.
        .scrollPosition($scrollPosition)
        // One sample for the follow engine and `readingPlace`, so the
        // verdict that rides with an edge is the verdict for that edge.
        .onScrollGeometryChange(for: ScrollSample.self) { geo in
            ScrollSample(geo)
        } action: { [readingSize] old, new in
            if new.geometry != old.geometry {
                if follow.geometryChanged(from: old.geometry, to: new.geometry) == .snapToEnd {
                    scrollToEnd()
                }
                syncWindowHold(new.geometry)
            }
            readingPlace.noteEdge(new.edge, following: follow.isNearBottom, size: readingSize)
        }
        // Who is moving the scroll view, asked of the scroll view
        // itself. Geometry deltas cannot answer this — a sample says
        // the end moved, never whose hand did it — and guessing from
        // them is what let the follow engine fight the reader.
        .onScrollPhaseChange { _, phase, context in
            let geometry = TranscriptGeometry(context.geometry)
            if follow.phaseChanged(to: phase, geometry: geometry) {
                scrollToEnd()
            }
            if follow.readerIsScrolling { readingPlace.readerScrolled() }
            syncWindowHold(geometry)
        }
        .onAppear {
            // Born mid-read (the parent's own onAppear calls reload()
            // before this view exists) sees no onChange — arm the
            // delayed spinner here too.
            if isLoadingHistory { armLoadingRow() }
            // A card is answered from the keyboard only while the end of
            // the transcript, where it is drawn, is on screen — and while
            // no overlay of the window (the settings menu, the search
            // palette, the usage window) has the keys for itself.
            cardKeys.cardIsInView = { [follow] in follow.isNearBottom }
            cardKeys.overlayHasKeys = { [weak appState = appState] in appState?.overlayHoldsKeys ?? false }
            cardKeys.install()
        }
        .onDisappear { cardKeys.remove() }
        .background(CardWindowReader { [cardKeys] window in cardKeys.window = window })
        .onChange(of: activeCardId, initial: true) { _, newest in
            cardKeys.setActiveCard(newest)
        }
        .onChange(of: showsPlanFollowUp) { _, shown in
            guard shown, !find.isAnchored else { return }
            follow.forceFollow()
            withAnimation(.easeOut(duration: 0.2)) { scrollToEnd() }
        }
        .onChange(of: isLoadingHistory) { _, loading in
            // The async load landed (fires even when the reloaded item
            // COUNT matches the old one — reopening the same session —
            // where an items.count trigger stays silent).
            if loading {
                armLoadingRow()
            } else {
                loadToken &+= 1        // cancel a pending arm
                if showLoadingRow { showLoadingRow = false }
                // Whole transcript swapped in at once: go to ITS end.
                // The geometry feed carries it the rest of the way as
                // rows realise at their true heights — which is what
                // the snap budget is sized for.
                follow.forceFollow()
                scrollToEnd()
                // The rows only exist now. A find seeded by a search
                // result opened before this landed, and an item COUNT
                // that happens to match the outgoing session's leaves
                // the count-based refresh silent.
                refreshFind()
            }
        }
        // A change of text size re-lays out every row: real input, like a
        // history swap, so the follow engine may spend snaps keeping the
        // end. A reader elsewhere keeps their line through `readingPlace`.
        .onChange(of: readingSize) { _, _ in follow.noteInput() }
        .onChange(of: repositionNonce) { _, _ in
            // In-place history swap (cache-hit refresh landed newer
            // content) — pull to the new end unless the reader has
            // already moved away from it.
            guard follow.isNearBottom else { return }
            follow.noteInput()
            scrollToEnd()
        }
        // Live events and approval cards both render at the END of the
        // stack, so following the stream and revealing either of them is
        // the same request: go to the bottom edge.
        //
        // Every one of these is REAL input, so each restores the
        // geometry path's snap budget. That is what keeps the budget
        // from starving a live stream: a turn emitting rows re-arms it
        // on every event, and it can only run out when the engine is
        // snapping against nothing but itself.
        .onChange(of: runner.events.count) { _, _ in
            // Not while the reader is mid-gesture — an event landing
            // then is the same yank the geometry path no longer does,
            // arriving by another door. The phase handler takes up
            // the slack when they let go.
            follow.noteInput()
            // The held row's distance from the newest row moves with
            // every row streamed under it, drawn or not.
            if let i = heldTopId.flatMap(rowIndex(of:)) { heldAnchor.fromEnd = rowCount - i }
            if follow.isNearBottom, !follow.readerIsScrolling { scrollToEnd() }
            refreshFind()
        }
        .onChange(of: approvalsForRunner.count) { _, _ in
            guard !find.isAnchored else { return }
            follow.forceFollow()
            withAnimation(.easeOut(duration: 0.2)) { scrollToEnd() }
        }
        .onChange(of: runner.status) { _, new in
            // Not while a find is anchored: the reader is standing on
            // a match they asked for, and a turn starting is not their
            // request to leave it. Same reasoning as the follow
            // engine's rule about never scrolling under the reader.
            if new.isRunning, !find.isAnchored {
                follow.forceFollow()
                withAnimation(.easeOut(duration: 0.2)) { scrollToEnd() }
            }
        }
        .onChange(of: historicalItems.count) { _, _ in refreshFind() }
        .onChange(of: find.query) { _, _ in
            // Incremental find: each keystroke re-counts, and the move
            // to match 1 lands once the typing settles — see
            // `requestJumpSettled`.
            refreshFind()
            find.requestJumpSettled()
        }
        .onChange(of: find.isOpen) { _, open in
            refreshFind()
            if !open {
                // Closing returns the reader to where a transcript
                // always belongs.
                follow.forceFollow()
                scrollToEnd()
            }
        }
        .onChange(of: find.jumpNonce) { _, _ in jumpToActiveMatch(proxy) }
        }
    }

    /// The transcript column proper.
    ///
    /// The history window is a plain `VStack`, NOT a `LazyVStack`, and
    /// that is load-bearing: a lazy stack does not know its own height
    /// until its rows realize, so the bottom edge the scroll view is
    /// born at is an ESTIMATE. On a huge session (very tall rows) the
    /// estimate is far enough off that the opening jump lands outside
    /// the realized content and the transcript renders blank until a
    /// scroll forces realization — reproducibly on a very large
    /// session, and only on the FIRST open (a revisit hits the parsed
    /// cache, so the view is built with its content already in hand
    /// and lays out correctly). Eager rows make the height exact, so
    /// there is no estimate to be wrong.
    ///
    /// This is why the window is CAPPED (`earlierRows`): eager means
    /// every row in the window is laid out up front, so the window has
    /// to stay small enough for that to be cheap.
    ///
    /// The LIVE rows below it are eager and capped
    /// (`TranscriptSeam.liveRows`), in the same window, for a second
    /// reason — a lazy tail's estimated height moves as
    /// rows realize, and the follow engine cannot tell that movement
    /// from real content growth. See the note at the live block below,
    /// and `Utilities/TranscriptFollow.swift`.
    @ViewBuilder
    private var transcriptStack: some View {
        VStack(alignment: .leading, spacing: 12 * gapScale) {
                    if isLoadingHistory {
                        // Deliberately empty until the read is slow
                        // enough to explain — see `showLoadingRow`.
                        if showLoadingRow { historyLoadingRow }
                    } else if historicalItems.isEmpty && runner.events.isEmpty
                              && !runner.status.isRunning {
                        emptyState
                    } else {
                        // Computed once per render pass, not per row —
                        // it walks the full item + event lists.
                        let pairing = toolPairing
                        // Same: every row, once per pass.
                        let activity = activityLayout(pairing: pairing)
                        let names = transcriptNames(pairing: pairing, activity: activity)
                        // ONE "Show earlier", at the top of the one run of
                        // rows the window draws (`TranscriptSeam.window`):
                        // what it counts is every row above that run, the
                        // live buffer's included — in compact view every
                        // DRAWN row, a line once (`rowsAbove`).
                        let window = transcriptWindow
                        let older = rowsAbove(window)
                        if older > 0 || historyHasMore {
                            Button {
                                // Fetch AHEAD of need: once the loaded
                                // remainder is under one reveal, kick
                                // the wider read so the next click has
                                // rows waiting. The 200 rows stand
                                // either way — when the read lands, the
                                // window reveals the next ~200 rows
                                // above the top exactly as an ordinary
                                // reveal does, and the button returns
                                // with the true remainder.
                                if historyHasMore, older < 200 {
                                    onLoadEarlier()
                                }
                                showEarlierRows()
                            } label: {
                                Group {
                                    if older > 0 {
                                        Text(String(localized: "Show earlier — \(older) older rows",
                                                    comment: "Button above a truncated transcript; placeholder is the hidden row count"))
                                    } else if isWideningHistory {
                                        Text(String(localized: "Loading earlier turns…",
                                                    comment: "Disabled state of the Show-earlier button while older turns are read from disk"))
                                    } else {
                                        // No count: the remainder is
                                        // unparsed rows on disk, and a
                                        // number here would be a guess
                                        // stated as a fact.
                                        Text(String(localized: "Show earlier — load older turns",
                                                    comment: "Show-earlier button when older turns must first be read from disk"))
                                    }
                                }
                                .font(.system(size: 12 * fontScale))
                                .foregroundColor(ChatDesign.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            // With loaded rows still hidden a click can
                            // always reveal; only a pure fetch-click
                            // has nothing to do while one is running.
                            .disabled(isWideningHistory && older <= 0)
                        } else if let note = historyTruncationNote {
                            Text(note)
                                .font(.system(size: 12 * fontScale))
                                .foregroundColor(ChatDesign.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        // EAGER on purpose — see the container's note.
                        ForEach(displayedHistory) { item in
                            historyRow(item, pairing: pairing, activity: activity, names: names)
                        }
                        // Live rows are EAGER and CAPPED, in the same
                        // window as the history above. A lazy stack's total
                        // height is an estimate that MOVES as
                        // `ScrollViewHelper.prefetch` realizes rows;
                        // the follow engine reads that movement as
                        // content growth, and its snap realizes more
                        // rows — layout feeding itself. Eager rows
                        // make the height exact, so there is no
                        // estimate to churn; the cap is what keeps
                        // eager affordable, and at OPEN this stack is
                        // empty (`clearEvents()`), so the opening
                        // height stays exact and the cost is paid a
                        // row at a time as a turn streams.
                        if !runner.events.isEmpty
                            || !approvalsForRunner.isEmpty || showsPlanFollowUp {
                            VStack(alignment: .leading, spacing: 12 * gapScale) {
                                ForEach(displayedEvents) { event in
                                    eventRow(event, pairing: pairing, activity: activity, names: names)
                                }
                                ForEach(approvalsForRunner) { req in
                                    // Only the newest card owns Return/Escape —
                                    // with several pending, duplicate shortcut
                                    // registrations resolve an arbitrary one.
                                    // No explicit .id scroll anchors: both rows
                                    // live at the END of the stack, so reaching
                                    // them is `scrollTo(edge: .bottom)`. The
                                    // ScrollViewReader wrapping the body serves
                                    // the find bar's match jumps, not these rows.
                                    approvalCard(req,
                                                 ownsKeyboardShortcuts:
                                                    req.id == approvalsForRunner.last?.id)
                                }
                                // Once a codex Plan turn is over: whether to
                                // carry its plan out. Never under a card a
                                // turn waits on.
                                if showsPlanFollowUp {
                                    CodexPlanFollowUpCard(
                                        cardId: planFollowUpCardId,
                                        choices: CodexAppServer.planFollowUpChoices(
                                            modeBeforePlan: runner.codexModeBeforePlan),
                                        ownsKeys: true,
                                        keys: cardKeys, onImplement: onImplementPlan,
                                        onStay: { runner.dismissPlanFollowUp() })
                                }
                                // Only until the agent's first output
                                // lands — see `awaitingFirstAgentEvent`.
                                // Not shown under an approval card: there
                                // the wait is on the USER, not on the
                                // agent, and a spinner would say the
                                // opposite. Nor under a live line, which
                                // is this row already.
                                if awaitingFirstAgentEvent && approvalsForRunner.isEmpty
                                    && !activity.hasLiveLine {
                                    // In an answer drawn compact the name
                                    // stands over it, where the first step
                                    // will be — nothing moves when it lands.
                                    if names.waitingNamed {
                                        VStack(alignment: .leading, spacing: 4 * gapScale) {
                                            agentLabelHeader
                                            waitingRow
                                        }
                                    } else {
                                        waitingRow
                                    }
                                }
                                // ONE row, replaced in place, for as
                                // long as the child is retrying — see
                                // AgentRunner.retryNotice. Outside the
                                // waiting row because a stream can drop
                                // mid-turn, long after the first output.
                                if runner.status.isRunning,
                                   !runner.retryNotice.isEmpty {
                                    retryNoticeRow
                                }
                                // Same shape and the same reason as the
                                // retry notice: the child goes quiet
                                // for half a minute while it summarises
                                // the conversation, and silence there
                                // reads as a hang. Outside the waiting
                                // row because a compaction happens
                                // mid-turn, after plenty of output.
                                if runner.status.isRunning, runner.compacting {
                                    compactingRow
                                }
                                // The answer has landed and the turn goes
                                // on: claude and kimi wait for background
                                // tasks they started and report each in a
                                // turn of their own, and codex's turn waits
                                // for a command still running. The clock
                                // and Stop say the turn runs; this says
                                // what it waits for.
                                if runner.status.isRunning,
                                   !runner.awaitedBackgroundTasks.isEmpty {
                                    backgroundTaskRow
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, SipDesign.pageContentInset)
    }

    // MARK: - Empty / loading states

    private var historyLoadingRow: some View {
        VStack(spacing: 6) {
            Spacer()
            ProgressView().controlSize(.small)
            Text("Loading session history…",
                 comment: "State while the JSONL is being parsed")
                .font(.system(size: 13 * fontScale))
                .foregroundColor(ChatDesign.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cwd = draftCwd {
                Text(String(localized: "Ready to start a new \(agentName) session in:",
                            comment: "Empty-state header for a draft session before the first message; placeholder is the agent label"))
                    .font(.system(size: 13 * fontScale))
                    .foregroundColor(ChatDesign.textSecondary)
                Text(cwd.path)
                    .font(.system(size: 13 * fontScale, design: .monospaced))
                    .foregroundColor(ChatDesign.textSecondary)
                if let group = draftCustomGroup {
                    // String(localized:) then the verbatim Text
                    // overload: the interpolated-literal form
                    // markdown-parses, and a group name is the user's
                    // own text — an _underscored_ one would render
                    // italicised, with the underscores eaten.
                    Text(String(localized: "It will appear in the “\(group)” group.",
                                comment: "Draft empty-state line naming the custom group the new session will be filed into; placeholder is the group name"))
                        .font(.system(size: 13 * fontScale))
                        .foregroundColor(ChatDesign.textSecondary)
                        .padding(.top, 6)
                }
                Text("Type your first message below.",
                     comment: "Empty-state hint for a draft session")
                    .font(.system(size: 13 * fontScale))
                    .foregroundColor(ChatDesign.textSecondary)
                    .padding(.top, 8)
            } else {
                Text("No visible turns in this session yet.",
                     comment: "Existing-session empty state")
                    .font(.system(size: 13 * fontScale))
                    .foregroundColor(ChatDesign.textSecondary)
                if !emptySessionCommands.isEmpty {
                    Text(String(localized: "Only local commands were recorded: \(emptySessionCommands.joined(separator: ", ")). Running /clear starts a fresh session file — quitting right after leaves it like this.",
                                comment: "Existing-session empty state detail; placeholder lists the slash commands found in the file"))
                        .font(.system(size: 12 * fontScale))
                        .foregroundColor(ChatDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 24)
    }

    // MARK: - Rows, with activity lines

    /// One history row as the stack draws it: the activity line when
    /// this row is where a line is drawn, nothing when the row is a
    /// member drawn inside a line, else the row itself.
    ///
    /// The row id rides here rather than on the `ForEach`: an id on a
    /// member that draws nothing would sit beside the SAME id inside the
    /// opened line, and a find jump scrolls to an id.
    @ViewBuilder
    private func historyRow(_ item: AgentSessionHistoryItem, pairing: Pairing,
                            activity: ActivityLayout, names: NameLayout) -> some View {
        if let line = activity.lines[item.id] {
            activityLine(line, pairing: pairing, named: names.named.contains(item.id))
                .id(item.id)
                .readingPlaceRow(item.id, place: readingPlace, size: readingSize,
                                 restore: restoreReadingPlace)
        } else if activity.lineOfMember[item.id] == nil {
            renderHistoricalItem(item, pairing: pairing, names: names)
                .id(item.id)
                .readingPlaceRow(item.id, place: readingPlace, size: readingSize,
                                 restore: restoreReadingPlace)
        }
    }

    /// `historyRow` for a live event.
    @ViewBuilder
    private func eventRow(_ event: StreamEvent, pairing: Pairing,
                          activity: ActivityLayout, names: NameLayout) -> some View {
        if let line = activity.lines[event.id] {
            activityLine(line, pairing: pairing, named: names.named.contains(event.id))
                .id(event.id)
                .readingPlaceRow(event.id, place: readingPlace, size: readingSize,
                                 restore: restoreReadingPlace)
        } else if activity.lineOfMember[event.id] == nil {
            renderEvent(event, pairing: pairing, names: names)
                .id(event.id)
                .readingPlaceRow(event.id, place: readingPlace, size: readingSize,
                                 restore: restoreReadingPlace)
        }
    }

    private static var showStepsHint: String {
        String(localized: "Show the steps",
               comment: "Tooltip on an activity line that is closed: click to see its steps (the model's thoughts and tool calls)")
    }

    private static var hideStepsHint: String {
        String(localized: "Hide the steps",
               comment: "Tooltip on an activity line that is open: click to hide its steps")
    }

    /// The agent's work as ONE line: everything an answer did between the
    /// user's message and its final message — every answer's in compact
    /// view, a Chat only turn's always — the words it said along the way
    /// included.
    ///
    /// While the line is still being written it IS the waiting row —
    /// the same spinner, size, colour and padding as `waitingRow` — with
    /// the newest step's or message's words where "Sipping…" was, so the
    /// line changes in place as the model works. Once the answer is done,
    /// the spinner becomes a symbol and the words a summary
    /// (`ChatOnlyActivity.summaryText`, one rule for every agent), with
    /// the orange triangle when a step failed.
    ///
    /// `named` puts the agent's name over it: the line opens the answer
    /// (`ChatOnlyActivity.names` — the name once per answer). Nothing
    /// here is time-based — the words change when the agent reports a
    /// step, and never on a clock.
    private func activityLine(_ line: ActivityLineRender,
                              pairing: Pairing, named: Bool) -> some View {
        let open = expandedActivityLines.contains(line.key)
        let summary = ChatOnlyActivity.summary(of: line.group.steps,
                                               failures: line.group.failures,
                                               messages: line.group.messages)
        let text = line.isLive
            ? (ChatOnlyActivity.livePhrase(of: line.group)
               ?? String(localized: "Sipping…",
                         comment: "Shown while waiting for the model"))
            : ChatOnlyActivity.summaryText(summary)
        let hint = open ? Self.hideStepsHint : Self.showStepsHint
        return VStack(alignment: .leading, spacing: 0) {
            if named {
                // The bubble's own gap between its name and its words.
                agentLabelHeader
                    .padding(.bottom, 4 * gapScale)
            }
            Button {
                if open { expandedActivityLines.remove(line.key) }
                else { expandedActivityLines.insert(line.key) }
            } label: {
                HStack(spacing: 8) {
                    Group {
                        if line.isLive {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: ChatOnlyActivity.symbol(
                                for: summary, agentTurn: line.group.agentTurn))
                                .font(.system(size: 12 * SipFont.contentRatio(fontScale)))
                                .foregroundColor(ChatDesign.textSecondary)
                        }
                    }
                    // A frame around tier-scaled glyphs scales with them.
                    .frame(width: 16 * SipFont.contentRatio(fontScale),
                           height: 16 * SipFont.contentRatio(fontScale))
                    // Model- and page-derived words: verbatim, never
                    // markdown-parsed.
                    Text(verbatim: text)
                        .font(.system(size: 13 * SipFont.contentRatio(fontScale)))
                        .foregroundColor(ChatDesign.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // The chip's failure mark, at the chip's size.
                    if summary.failures > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10 * SipFont.contentRatio(fontScale)))
                            .foregroundColor(.orange)
                    }
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9 * SipFont.contentRatio(fontScale),
                                      weight: .semibold))
                        .foregroundColor(ChatDesign.textHint)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                // A line is a button with no frame of its own; the fill
                // under the pointer says it opens.
                .hoverFill(cornerRadius: 6)
            }
            .buttonStyle(.plain)
            .help(hint)
            .accessibilityLabel(text)
            .accessibilityHint(hint)
            if open {
                activitySteps(line, pairing: pairing)
            }
        }
    }

    /// The opened line: every member in order under a thin rule — a
    /// thought as a row of its own (`thoughtRow`), each tool call as the
    /// ordinary tool chip, so its input shows at the first click and its
    /// output at the second, and the agent's words and the notices as the
    /// full transcript draws them (the words without the name: the line
    /// carries it).
    private func activitySteps(_ line: ActivityLineRender,
                               pairing: Pairing) -> some View {
        VStack(alignment: .leading, spacing: 6 * gapScale) {
            ForEach(line.members) { member in
                activityMember(member, pairing: pairing,
                               isAnchor: member.id == line.anchorId)
            }
        }
        .padding(.leading, 16)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(ChatDesign.border)
                .frame(width: 1)
        }
        // The rule under the header's glyph, the steps under its words.
        .padding(.leading, 16)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    /// One member inside an opened line. It carries its own row id —
    /// except the anchor, whose id the whole line already carries — so a
    /// find jump to a thought or a chip lands on it.
    @ViewBuilder
    private func activityMember(_ member: ActivityMember, pairing: Pairing,
                                isAnchor: Bool) -> some View {
        if isAnchor {
            activityMemberContent(member, pairing: pairing)
        } else {
            activityMemberContent(member, pairing: pairing)
                .id(member.id)
        }
    }

    @ViewBuilder
    private func activityMemberContent(_ member: ActivityMember,
                                       pairing: Pairing) -> some View {
        switch member {
        case .history(let item):
            switch item.kind {
            case .thinking(let text):
                thoughtRow(id: item.id, text: text)
            case .toolUse(let id, let name, let input):
                toolActivityChip(chipId: item.id, name: name, input: input,
                                 result: pairing.byUseId[id])
            case .toolResult(_, let content, let isError):
                if !pairing.consumed.contains(item.id) {
                    orphanResultChip(chipId: item.id, output: content,
                                     isError: isError)
                }
            case .assistantText(let text):
                memberWords(id: item.id, text: text)
            default:
                renderHistoricalItem(item, pairing: pairing, names: NameLayout())
            }
        case .event(let event):
            switch event.kind {
            case .thinking(let text):
                thoughtRow(id: event.id, text: text)
            case .toolUse(let id, let name, let input):
                toolActivityChip(chipId: event.id, name: name, input: input,
                                 result: pairing.byUseId[id])
            case .toolResult(_, let output, let isError):
                if !pairing.consumed.contains(event.id) {
                    orphanResultChip(chipId: event.id, output: output,
                                     isError: isError)
                }
            case .assistantText(let text):
                memberWords(id: event.id, text: text)
            default:
                renderEvent(event, pairing: pairing, names: NameLayout())
            }
        }
    }

    /// A thought inside an opened line, as a row in the tool chip's
    /// shape: closed, it names itself and the thought's first line; a
    /// click opens the whole thought — the markdown renderer at 13/14 of
    /// the answer's size, in the secondary colour, the reasoning beside
    /// the answer and not the answer. Its expanded state is the chips'
    /// (`expandedToolResults`), so a find jump to it opens it.
    private func thoughtRow(id: UUID, text: String) -> some View {
        let texts = thoughtTexts(text)
        let slots = pieceSlots(texts, base: find.slot(forRow: id))
        return chipShell(chipId: id,
                         symbol: "lightbulb",
                         title: Self.thoughtChipTitle,
                         summary: texts[0],
                         isError: false,
                         showsSpinner: false,
                         summarySlot: slotAt(slots, 0)) {
            MarkdownRenderer.render(text)
                .environment(\.sipMarkdownTextColor, ChatDesign.textSecondary)
                .environment(\.sipFontScale, fontScale * 13 / 14)
                .environment(\.sipSearchSlot, slotAt(slots, 1))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Historical item rendering

    /// Fan each history item out to the same renderer the live path
    /// uses. Tool uses and tool results land in `toolActivityChip` /
    /// `orphanResultChip`, so Edit-diff rendering and per-chip
    /// tap-to-expand come for free — and stay automatically in sync
    /// with any future changes to the live path.
    @ViewBuilder
    private func renderHistoricalItem(
        _ item: AgentSessionHistoryItem,
        pairing: Pairing,
        names: NameLayout
    ) -> some View {
        switch item.kind {
        case .userText(let text):
            // Stable id (the row's own), NOT ChatMessage's default
            // UUID(): a fresh id per render pass makes every visible
            // bubble's inputs "changed" on every streamed burst, so
            // SwiftUI can never skip the subtree.
            userRow(rowId: item.id, text: text, recordUuid: item.recordUuid,
                    isSystemNotice: item.isSystemNotice,
                    sentIntoTurn: item.sentIntoTurn,
                    attachedFiles: item.attachedFiles,
                    loadedSkills: item.loadedSkills,
                    shellCommand: item.shellCommand)
                .environment(\.sipSearchSlot, find.slot(forRow: item.id))
        case .assistantText(let text):
            MessageBubble(
                message: ChatMessage(id: item.id, role: "assistant", content: text),
                assistantLabelOverride: assistantLabel,
                showsHeader: !names.quiet.contains(item.id)
            )
            .environment(\.sipSearchSlot, find.slot(forRow: item.id))
        case .toolUse(let id, let name, let input):
            toolActivityChip(chipId: item.id, name: name, input: input,
                             result: pairing.byUseId[id],
                             showsLabel: names.named.contains(item.id))
        case .toolResult(_, let content, let isError):
            if !pairing.consumed.contains(item.id) {
                orphanResultChip(chipId: item.id, output: content,
                                 isError: isError)
            }
        case .interrupted(let message):
            interruptedRow(message: message, slot: find.slot(forRow: item.id))
        case .error(let message):
            errorRow(message: message, slot: find.slot(forRow: item.id))
        case .compaction(let pre, let post):
            compactionRow(preTokens: pre, postTokens: post,
                          slot: find.slot(forRow: item.id))
        case .shellOutput(let output):
            shellOutputRow(output, slot: find.slot(forRow: item.id))
        case .thinking:
            // Drawn only inside its turn's activity line.
            EmptyView()
        }
    }

    /// Label shown in place of the user's name on a harness-injected
    /// notice — a task notification is a user-role record, but "You"
    /// on a message the user never typed reads as someone else using
    /// their account.
    private static var systemNoticeLabel: String {
        String(localized: "System",
               comment: "Transcript label on an automated notice rendered in the user column")
    }

    /// One message the user sent — the only row kind that can be
    /// branched from, so history and live rows share this one renderer
    /// rather than each growing their own copy of the edit affordance.
    @ViewBuilder
    private func userRow(rowId: UUID, text: String,
                         recordUuid: String?,
                         isSystemNotice: Bool = false,
                         sentIntoTurn: Bool = false,
                         attachedFiles: [String] = [],
                         loadedSkills: [String] = [],
                         shellCommand: Bool = false,
                         newerIdentical: @escaping () -> Int = { 0 }) -> some View {
        if editingRowId == rowId {
            let blocked = sendBlockedReason(forRow: rowId)
            BranchEditor(
                text: $editDraft,
                // `!canBranch` covers a turn that STARTED while the
                // editor was open — from the composer below it, or from
                // another terminal. Forking then would copy a prefix out
                // of a file that is being appended to, i.e. guess where
                // the conversation ends; going back to the message would
                // cut a turn that is still being written.
                busy: branching || !canBranch,
                explanation: blocked ?? String(
                    localized: "Send replaces this message and everything after it. Files \(assistantLabel) changed stay as they are. Create Branch starts a new session and keeps this one.",
                    comment: "Explanation under the message editor in an agent transcript; the placeholder is the agent's label"),
                onSend: { onSendInPlace(rowId, recordUuid, text, editDraft, newerIdentical()) },
                sendBlocked: blocked != nil || rewindSupport != .offered,
                onCreate: { onCreateBranch(recordUuid, text, editDraft, newerIdentical()) },
                onCancel: onCancelEdit
            )
        } else {
            MessageBubble(
                // The paperclip line under the bubble, the chat page's
                // shape: the names an inlined message carried, off the
                // record (history) or the send (live).
                // A `!` command is drawn as the line it was, never read as
                // markdown.
                message: ChatMessage(id: rowId, role: "user",
                                     content: shellCommand ? ShellCommandInput.markdown(text) : text,
                                     files: attachedFiles.isEmpty ? nil
                                         : attachedFiles.joined(separator: ", ")),
                assistantLabelOverride: assistantLabel,
                userLabelOverride: isSystemNotice ? Self.systemNoticeLabel : nil,
                // A notice in the user column is not the user's message
                // — a task notification, a compaction summary — and has
                // no record of its own to cut at; the pencil would only
                // ever answer with an error. Nor is an answer steered into
                // a running turn: a branch cuts at a turn, and editing the
                // answer would replace the prompt of the turn it went into.
                // A `!` command is not a message to edit or branch at:
                // neither its record nor its row carries the words a
                // branch is cut at (`AgentSessionHistoryItem.shellCommand`).
                onEdit: (canBranch && editingRowId == nil && !isSystemNotice && !sentIntoTurn
                         && !shellCommand)
                    ? { onBeginEdit(rowId, text, loadedSkills) } : nil,
                loadedSkills: loadedSkills
            )
        }
    }

    /// Why Send cannot take the session back to this row, or nil when it
    /// can (the installed tool's support aside, which disables Send with
    /// the ordinary sentence while it is still being read).
    ///
    /// A message above a summary is one the agent no longer holds as it
    /// was: Kimi Code refuses to undo across one, and each tool's own
    /// terminal offers only the messages after it. Create Branch is how to
    /// start again from such a message.
    private func sendBlockedReason(forRow rowId: UUID) -> String? {
        if rewindSupport == .needsNewer {
            return String(
                localized: "Send needs a newer version of \(assistantLabel). Create Branch starts a new session and keeps this one.",
                comment: "Message editor: the installed agent cannot go back to a message; the placeholder is the agent's label")
        }
        guard summarizedBelow(rowId) else { return nil }
        return String(
            localized: "\(assistantLabel) summarised the conversation after this message, so Send can't go back to it. Create Branch starts a new session and keeps this one.",
            comment: "Message editor: a compaction sits below the edited message; the placeholder is the agent's label")
    }

    /// Whether a compaction row lies below the row, in what is on screen.
    private func summarizedBelow(_ rowId: UUID) -> Bool {
        let liveCompaction = { (events: ArraySlice<StreamEvent>) in
            events.contains { if case .compaction = $0.kind { return true }; return false }
        }
        if let at = historicalItems.firstIndex(where: { $0.id == rowId }) {
            let below = historicalItems[(at + 1)...].contains {
                if case .compaction = $0.kind { return true }
                return false
            }
            return below || liveCompaction(runner.events[...])
        }
        if let at = runner.events.firstIndex(where: { $0.id == rowId }) {
            return liveCompaction(runner.events[(at + 1)...])
        }
        return false
    }

    /// How many live user rows BELOW this one say the same thing. A
    /// live row's record is resolved by a newest-first text match, so
    /// the pencil on the older of two identical live rows ("continue",
    /// twice this visit) must say how many newer ones to skip, or the
    /// branch would cut at the wrong one — silently, the text being the
    /// same. History rows carry their record and never need this.
    private func newerIdenticalLiveRows(after id: UUID, text: String) -> Int {
        guard let at = runner.events.firstIndex(where: { $0.id == id }) else { return 0 }
        // A message of attached files alone has no words, and its files
        // are what it says: its record is found by them, so the rows to
        // skip are the newer ones naming the same files.
        let files = text.isEmpty ? runner.events[at].attachedFiles : []
        var count = 0
        for event in runner.events[(at + 1)...] {
            if case .userMessage(let t) = event.kind, !event.isSystemNotice, t == text,
               !text.isEmpty || event.attachedFiles == files {
                count += 1
            }
        }
        return count
    }

    // MARK: - Live event rendering

    @ViewBuilder
    private func renderEvent(
        _ event: StreamEvent,
        pairing: Pairing,
        names: NameLayout
    ) -> some View {
        switch event.kind {
        case .userMessage(let text):
            // Stable id — see renderHistoricalItem. No record uuid: this
            // message has only ever existed in the live buffer, so the
            // fork resolves its transcript record by text — newest
            // first, which is why the row says how many newer live rows
            // repeat it (counted at the click, not per pass).
            userRow(rowId: event.id, text: text, recordUuid: nil,
                    isSystemNotice: event.isSystemNotice,
                    sentIntoTurn: event.sentIntoTurn,
                    attachedFiles: event.attachedFiles,
                    loadedSkills: event.loadedSkills,
                    shellCommand: event.shellCommand,
                    newerIdentical: { newerIdenticalLiveRows(after: event.id, text: text) })
                .environment(\.sipSearchSlot, find.slot(forRow: event.id))
        case .assistantText(let text):
            MessageBubble(
                message: ChatMessage(id: event.id, role: "assistant", content: text),
                assistantLabelOverride: assistantLabel,
                showsHeader: !names.quiet.contains(event.id)
            )
            .environment(\.sipSearchSlot, find.slot(forRow: event.id))
        case .toolUse(let id, let name, let input):
            toolActivityChip(chipId: event.id, name: name, input: input,
                             result: pairing.byUseId[id],
                             showsLabel: names.named.contains(event.id))
        case .toolResult(_, let output, let isError):
            if !pairing.consumed.contains(event.id) {
                orphanResultChip(chipId: event.id, output: output,
                                 isError: isError)
            }
        case .systemInit:
            // Session plumbing stays out of the conversation, the way
            // Claude Desktop shows none of it.
            EmptyView()
        case .result:
            // The turn total lives in the composer's duration chip
            // (AgentComposer), not in the transcript.
            EmptyView()
        case .error(let message):
            errorRow(message: message, slot: find.slot(forRow: event.id))
        case .interrupted(let message):
            interruptedRow(message: message, slot: find.slot(forRow: event.id))
        case .compaction(let pre, let post):
            compactionRow(preTokens: pre, postTokens: post,
                          slot: find.slot(forRow: event.id))
        case .shellOutput(let output):
            shellOutputRow(output, slot: find.slot(forRow: event.id))
        case .thinking:
            // Drawn only inside its turn's activity line.
            EmptyView()
        }
    }

    /// What a `!` command printed, under its row: a code block — Copy and
    /// Save on hover, searched like any drawn text — and a quiet line for
    /// what the block cannot say: a failure's exit code, a Stop, a command
    /// the agent did not run (in its own words), or no output at all. A long
    /// output is drawn as its start (`ShellCommandOutput.shown`), and says so.
    private func shellOutputRow(_ output: ShellCommandOutput,
                                slot: SearchHighlightSlot) -> some View {
        let shown = output.shown
        let cutNote: String? = shown.cut
            ? String(localized: "Only the start of the output is shown.",
                     comment: "Transcript line under a ! command whose output is too long to draw whole")
            : nil
        let note: String? = {
            if let notRun = output.notRun { return notRun }
            if output.interrupted {
                return String(localized: "Stopped before it finished",
                              comment: "Transcript line under a ! command the user stopped")
            }
            if output.failed {
                if let code = output.exitCode {
                    return String(localized: "Exit code \(code)",
                                  comment: "Transcript line under a ! command that failed; placeholder is its exit code")
                }
                return String(localized: "The command failed",
                              comment: "Transcript line under a ! command that failed without an exit code")
            }
            if shown.text.isEmpty {
                return String(localized: "No output",
                              comment: "Transcript line under a ! command that printed nothing")
            }
            return nil
        }()
        return VStack(alignment: .leading, spacing: 4) {
            if !shown.text.isEmpty {
                CodeBlockView(language: "", code: shown.text, slot: slot)
            }
            ForEach(Array([cutNote, note].compactMap { $0 }.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 12 * SipFont.contentRatio(fontScale)))
                    .foregroundColor(ChatDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Quiet system row for a turn that was stopped before finishing —
    /// deliberately not `errorRow`: stopping is a normal act, so it
    /// speaks in the transcript's secondary voice, not in red.
    private func interruptedRow(message: String,
                                slot: SearchHighlightSlot = .inactive) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "stop.circle")
                // Sizes these rows SHOW at Default, inside the content re-scope:
                // `contentRatio` is 1 there, where a raw multiply lands 7 % under.
                .font(.system(size: 12 * SipFont.contentRatio(fontScale)))
                .foregroundColor(ChatDesign.textSecondary)
            Text(AttributedString.highlighting(message, slot: slot).0)
                .font(.system(size: 12 * SipFont.contentRatio(fontScale)))
                .foregroundColor(ChatDesign.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// The agent summarised the conversation to make room and carried
    /// on.
    ///
    /// Quiet, like `interruptedRow` and for the same reason: compacting
    /// is a normal thing for an agent to do, not a failure. It earns a
    /// row because the composer's context chip is about to fall by most
    /// of its value, and a gauge that drops with nothing on screen
    /// explaining it reads as a bug.
    ///
    /// Static — no clock, no progress. Figures only when the agent
    /// recorded them; codex records none and the row simply says less.
    /// The compaction row's words — also what a live line says when the
    /// compaction is the newest thing in it.
    static func compactionMessage(preTokens: Int?, postTokens: Int?) -> String {
        if let pre = preTokens, let post = postTokens {
            return String(
                localized: "Conversation compacted (\(ContextUsageFormat.compact(pre)) → \(ContextUsageFormat.compact(post)) tokens)",
                comment: "Transcript row after the agent summarised the conversation, with before and after sizes")
        }
        return String(
            localized: "Conversation compacted",
            comment: "Transcript row after the agent summarised the conversation")
    }

    private func compactionRow(preTokens: Int?, postTokens: Int?,
                               slot: SearchHighlightSlot = .inactive) -> some View {
        let message = Self.compactionMessage(preTokens: preTokens, postTokens: postTokens)
        return HStack(spacing: 6) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 12 * SipFont.contentRatio(fontScale)))
                .foregroundColor(ChatDesign.textSecondary)
            Text(AttributedString.highlighting(message, slot: slot).0)
                .font(.system(size: 12 * SipFont.contentRatio(fontScale)))
                .foregroundColor(ChatDesign.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Desktop-style tool chips

    /// One tool call as a Claude-Desktop-like row: a subdued full-width
    /// chip (chevron · tool icon · name · dim summary) that expands in
    /// place to the full input body plus the paired result. Collapsed by
    /// default — the transcript reads as prose with quiet activity
    /// markers between messages, not as a terminal log.
    @ViewBuilder
    /// `showsLabel` puts the agent's name above the chip. True only when
    /// this chip OPENS the answer (`transcriptNames`) — a turn that
    /// starts by reading a file otherwise showed no attribution at all,
    /// because the header lives in `MessageBubble` and a tool call never
    /// goes through it.
    private func toolActivityChip(chipId: UUID,
                                  name: String,
                                  input: [String: Any],
                                  result: PairedResult?,
                                  showsLabel: Bool = false) -> some View {
        let summary = AgentRendering.toolSummary(name: name, input: input, resultOutput: result?.output)
        let rows = AgentRendering.fullToolBody(name: name, input: input)
        let resultRows = result.map { AgentRendering.toolResultRows(name: name, output: $0.output) } ?? []
        // The chip's matches, split across the pieces it draws in the
        // order it draws them. `chipTexts` is the same list the find
        // engine counted this row in, so index i here is piece i there.
        let slots = pieceSlots(chipTexts(name: name, input: input, result: result),
                               base: find.slot(forRow: chipId))
        VStack(alignment: .leading, spacing: 4 * gapScale) {
            if showsLabel { agentLabelHeader }
            chipShell(
                chipId: chipId,
                symbol: AgentRendering.toolSymbol(name),
                title: AgentRendering.displayToolName(name),
                summary: summary,
                isError: result?.isError ?? false,
                showsSpinner: result == nil && runner.status.isRunning,
                // A call that has ended with nothing to show below its
                // header — a Codex search, its terms beside the title —
                // does not open onto an empty card.
                opens: result == nil || !rows.isEmpty || !resultRows.isEmpty,
                titleSlot: slots.first ?? .inactive,
                summarySlot: slots.count > 1 ? slots[1] : .inactive
            ) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    toolBodyText(row: row,
                                 slot: slotAt(slots, 2 + index))
                }
                if let result = result, !resultRows.isEmpty {
                    if !rows.isEmpty {
                        Divider().padding(.vertical, 4)
                    }
                    chipResultRows(result, rows: resultRows, slotOffset: 2 + rows.count, slots: slots)
                }
            }
        }
    }

    /// Bounds-checked slot lookup. The piece list and the drawn pieces
    /// are built from the same producers, so a mismatch should be
    /// impossible — but a highlight is cosmetic and must never be able
    /// to trap on a transcript.
    private func slotAt(_ slots: [SearchHighlightSlot], _ index: Int) -> SearchHighlightSlot {
        slots.indices.contains(index) ? slots[index] : .inactive
    }

    /// The header a text bubble draws, for a turn whose first output is
    /// a tool call. Same size, weight and colour as `MessageBubble`'s,
    /// deliberately — it is the same thing, just above a different row.
    private var agentLabelHeader: some View {
        Text(verbatim: assistantLabel)
            .font(.system(size: 13 * fontScale, weight: .semibold))
            .foregroundColor(ChatMarkdownStyle.label)
    }

    /// A tool result whose use fell outside the visible window (the
    /// history cap trims whole turns). Rare, but dropping it silently
    /// would hide real output.
    @ViewBuilder
    private func orphanResultChip(chipId: UUID,
                                  output: String,
                                  isError: Bool) -> some View {
        let slots = pieceSlots(orphanChipTexts(output: output),
                               base: find.slot(forRow: chipId))
        chipShell(
            chipId: chipId,
            symbol: "arrow.turn.down.right",
            title: Self.orphanChipTitle,
            summary: AgentRendering.summarizeToolResult(output),
            isError: isError,
            showsSpinner: false,
            titleSlot: slots.first ?? .inactive,
            summarySlot: slots.count > 1 ? slots[1] : .inactive
        ) {
            chipResultRows(PairedResult(output: output, isError: isError),
                           slotOffset: 2, slots: slots)
        }
    }

    /// `rows` the chip has already worked out (`AgentRendering
    /// .toolResultRows`), else the result's own body.
    @ViewBuilder
    private func chipResultRows(_ result: PairedResult,
                                rows given: [AgentRendering.ToolBodyRow]? = nil,
                                slotOffset: Int = 0,
                                slots: [SearchHighlightSlot] = []) -> some View {
        let rows = given ?? AgentRendering.fullToolResultBody(result.output)
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            HStack(spacing: 0) {
                if result.isError && row == rows.first {
                    Text("⚠ ")
                        .font(.system(size: 13 * fontScale))
                        .foregroundColor(.orange)
                }
                toolBodyText(row: row, slot: slotAt(slots, slotOffset + index))
            }
        }
    }

    /// Shared chip chrome: collapsed header row + expandable body card.
    @ViewBuilder
    private func chipShell<Body: View>(chipId: UUID,
                                       symbol: String,
                                       title: String,
                                       summary: String,
                                       isError: Bool,
                                       showsSpinner: Bool,
                                       opens: Bool = true,
                                       titleSlot: SearchHighlightSlot = .inactive,
                                       summarySlot: SearchHighlightSlot = .inactive,
                                       @ViewBuilder body: () -> Body) -> some View {
        let expanded = opens && expandedToolResults.contains(chipId)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard opens else { return }
                if expanded { expandedToolResults.remove(chipId) }
                else { expandedToolResults.insert(chipId) }
            } label: {
                HStack(spacing: 7) {
                    // A chip that does not open keeps the chevron's place,
                    // so its title lines up with every other chip's.
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9 * SipFont.contentRatio(fontScale), weight: .semibold))
                        .foregroundColor(ChatDesign.textHint)
                        .opacity(opens ? 1 : 0)
                        .frame(width: 10)
                    Image(systemName: symbol)
                        .font(.system(size: 11 * SipFont.contentRatio(fontScale)))
                        .foregroundColor(ChatDesign.textSecondary)
                    Text(AttributedString.highlighting(title, slot: titleSlot).0)
                        .font(.system(size: 12 * fontScale, weight: .medium))
                        .foregroundColor(ChatDesign.textSecondary)
                    if !summary.isEmpty {
                        Text(AttributedString.highlighting(summary, slot: summarySlot).0)
                            .font(.system(size: 12 * fontScale))
                            .foregroundColor(ChatDesign.textHint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if isError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10 * SipFont.contentRatio(fontScale)))
                            .foregroundColor(.orange)
                    }
                    if showsSpinner {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ChatDesign.cardBg.opacity(0.55))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: toolRowSpacing) {
                    body()
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ChatDesign.cardBg.opacity(0.35))
                )
                .padding(.top, 3)
                .padding(.leading, 17)
            }
        }
    }

    @ViewBuilder
    private func toolBodyText(row: AgentRendering.ToolBodyRow,
                              slot: SearchHighlightSlot = .inactive) -> some View {
        let font: Font = row.monospaced
            ? .system(size: 13 * fontScale, design: .monospaced)
            : .system(size: 13 * fontScale)
        // Highlight rides the ATTRIBUTED form, which leaves each
        // style's own foreground colour (diff green/red included)
        // exactly where it was — the tint is a background wash.
        let text = AttributedString.highlighting(row.text, slot: slot).0
        let styled: Text = {
            switch row.style {
            case .plain:
                return Text(text).foregroundColor(ChatDesign.textPrimary)
            case .dim:
                return Text(text).foregroundColor(ChatDesign.textSecondary)
            case .diffAdd:
                return Text(text).foregroundColor(ChatMarkdownStyle.diffAdded)
            case .diffRemove:
                return Text(text).foregroundColor(ChatMarkdownStyle.diffRemoved)
            case .bold:
                return Text(text)
                    .foregroundColor(ChatDesign.textPrimary)
                    .fontWeight(.semibold)
            }
        }()
        styled
            .font(font)
            .lineSpacing(13 * fontScale * lineSpacingFactor)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Error row

    private func errorRow(message: String,
                          slot: SearchHighlightSlot = .inactive) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // The interrupted row's sizes: what it shows at Default, inside
            // the content re-scope, where a raw multiply lands 7 % under.
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12 * SipFont.contentRatio(fontScale)))
                .foregroundColor(.orange)
            Text(AttributedString.highlighting(message, slot: slot).0)
                .font(.system(size: 12 * SipFont.contentRatio(fontScale)))
                .foregroundColor(ChatDesign.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                )
        )
    }

    // MARK: - Approval card

    /// ExitPlanMode is a plan to approve, not a tool call to allow: it
    /// gets the plan card. A question is not a permission either: it gets
    /// the question card, where the user answers it. Every other request
    /// gets the permission card. A request from codex's or kimi's own
    /// protocol, or an MCP server's form or link, carries how it is drawn
    /// (`presentation`), and gets the cards drawn from it — FIRST, so a
    /// kimi ExitPlanMode never reaches claude's plan card. They all live in their own files
    /// (`ApprovalCards.swift`, `AskingCards.swift`, `AgentQuestionCard
    /// .swift`) and share one keyboard (`cardKeys`): only the newest card
    /// takes it.
    @ViewBuilder
    private func approvalCard(_ req: MCPApprovalRequest,
                              ownsKeyboardShortcuts: Bool) -> some View {
        if let content = req.permissionContent {
            AgentPermissionCard(request: req, content: content,
                                ownsKeys: ownsKeyboardShortcuts, keys: cardKeys,
                                onModeAdopted: onModeAdopted)
        } else if let content = req.planContent {
            AgentPlanReviewCard(request: req, content: content,
                                ownsKeys: ownsKeyboardShortcuts, keys: cardKeys,
                                onModeAdopted: onModeAdopted)
        } else if let content = req.linkContent {
            AgentLinkCard(request: req, content: content,
                          ownsKeys: ownsKeyboardShortcuts, keys: cardKeys)
        } else if req.toolName == MCPBridge.planApprovalTool {
            PlanApprovalCard(request: req, agentName: agentName,
                             ownsKeys: ownsKeyboardShortcuts, keys: cardKeys,
                             listedModes: ClaudeCapabilities.shared.permissionModes.map(\.name),
                             modeBeforePlan: runner.modeBeforePlan,
                             savedNote: mcpBridge.cardNotes[req.id],
                             onModeAdopted: onModeAdopted)
        } else if let form = req.question {
            AgentQuestionCard(request: req, form: form, agentName: agentName,
                              ownsKeys: ownsKeyboardShortcuts, keys: cardKeys,
                              savedDraft: mcpBridge.questionDrafts[req.id])
        } else {
            ToolApprovalCard(request: req, folder: runner.cwd, ownsKeys: ownsKeyboardShortcuts,
                             keys: cardKeys, onModeAdopted: onModeAdopted)
        }
    }

    // MARK: - Waiting row

    /// True from the moment a turn is sent until the first thing the agent
    /// actually produces lands — the dead stretch under the user's own
    /// message, where a running clock in the composer is not enough to
    /// stop the page reading as stale.
    ///
    /// The walk back stops at the turn's own message (`WaitingRow`), so a
    /// second send in an existing session gets the row again rather than
    /// reading the previous turn's output as this turn's. A compaction row
    /// is not the agent answering: the spinner stays under it.
    private var awaitingFirstAgentEvent: Bool {
        runner.status.isRunning
            && WaitingRow.awaitsAgent(runner.events, compactionIsOutput: false)
    }

    /// Spinner + "Sipping…", and deliberately NO elapsed time.
    ///
    /// No label above it in an agent turn drawn in full: the attribution
    /// belongs to the answer, and the label arrives with the first real
    /// row (`MessageBubble`'s header, or the chip's when a tool call
    /// opens the turn — `transcriptNames`). Where the answer is drawn
    /// with the name once (compact view, a Chat only turn) the name
    /// stands over this row instead (`NameLayout.waitingNamed`), where
    /// the first step will be, so nothing moves when it lands.
    ///
    /// This row is static, appears for one gap per turn, and must stay
    /// that way — a time here would put the 1 Hz whole-transcript
    /// re-render back for the length of every turn. The clock lives in
    /// the composer strip (`TurnClockChip`). Do not put a time back
    /// into it.
    ///
    /// While the turn waits for SipAI's update of the agent's own tool
    /// (`AgentRunner.waitingForToolUpdate`), the same row says so instead
    /// of "Sipping…": the message is queued, not lost, and goes out the
    /// moment the update finishes. Just as static — it changes when the
    /// wait does, never on a clock.
    private var waitingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The activity line shares this exact shape, so
            // "Sipping…" turning into its first step is a text change in
            // place — keep the two in step (`Verification/ChatOnlyActivity`).
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Group {
                    if runner.waitingForToolUpdate {
                        // Localized-with-interpolation, not an
                        // interpolated literal: the label is the user's
                        // own and must not be markdown-parsed.
                        Text(String(localized: "\(agentName) is updating. Your message will be sent when the update finishes.",
                                    comment: "Transcript, under a message sent while SipAI updates the agent's command-line tool; placeholder is the agent's label"))
                    } else {
                        Text("Sipping…",
                             comment: "Spinner shown between the user's message and Claude's first output")
                    }
                }
                .font(.system(size: 13 * SipFont.contentRatio(fontScale)))
                .foregroundColor(ChatDesign.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            if runner.turnProducedNothing { stalledNoticeRow }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// The child is summarising the conversation right now — half a
    /// minute during which it says nothing else, which without this
    /// reads as a hang.
    ///
    /// Static, like every other in-progress row here: a time in the
    /// transcript re-renders the whole thing once a second for as long
    /// as it shows. The clock lives in the composer's chip.
    private var compactingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Compacting context…",
                 comment: "Shown while the agent summarises the conversation to free context")
                .font(.system(size: 13 * SipFont.contentRatio(fontScale)))
                .foregroundColor(ChatDesign.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// The background work a turn whose answer has landed is waiting on
    /// (`AgentRunner.awaitedBackgroundTasks`). Static, like every other
    /// in-progress row here: no time in it, and it changes only when the
    /// work does.
    ///
    /// Where a piece of work can be stopped on its own — claude's tasks,
    /// codex's background terminals — it has a line of its own with a Stop:
    /// that work alone stops, and the turn goes on waiting for the rest.
    /// Kimi's front end has no such request; the composer's Stop ends the
    /// turn and its work together.
    private var backgroundTaskRow: some View {
        let tasks = runner.awaitedBackgroundTasks
        let terminals = runner.agentKey == "codex"
        return VStack(alignment: .leading, spacing: 4) {
            if runner.canStopBackgroundTasks {
                ForEach(tasks, id: \.id) { task in
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        backgroundTaskText(BackgroundTaskLine.text([task], terminals: terminals))
                        Spacer(minLength: 8)
                        BackgroundTaskStopButton(
                            stopping: runner.stoppingBackgroundTasks.contains(task.id),
                            terminal: terminals,
                            fontSize: 12 * SipFont.contentRatio(fontScale)
                        ) {
                            runner.stopBackgroundTask(id: task.id)
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    backgroundTaskText(BackgroundTaskLine.text(tasks, terminals: terminals))
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// A String expression: task descriptions and commands are the agent's
    /// words and must not be markdown-parsed.
    private func backgroundTaskText(_ line: String) -> some View {
        Text(line)
            .font(.system(size: 13 * SipFont.contentRatio(fontScale)))
            .foregroundColor(ChatDesign.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The child is retrying a dropped stream and has said so. Static
    /// and singular by construction: the runner holds only the NEWEST
    /// notice, so this row rewrites itself rather than stacking, and
    /// carries no clock of its own (see `waitingRow`).
    private var retryNoticeRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11 * fontScale))
                .foregroundColor(ChatDesign.textSecondary)
            // Child-derived text — verbatim, never markdown-parsed.
            Text(verbatim: runner.retryNotice)
                .font(.system(size: 11 * fontScale))
                .foregroundColor(ChatDesign.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(ChatDesign.cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(ChatDesign.border, lineWidth: 1)
                )
        )
        .padding(.horizontal, 8)
    }

    /// Shown under the spinner once the runner latches
    /// `turnProducedNothing` — `AgentRunner.firstOutputGrace` of a
    /// turn producing literally nothing. The sentence NAMES that
    /// duration, so the two move together or the row states a wait
    /// the runner never made.
    ///
    /// It exists because that failure had no other voice. Every other
    /// way a turn goes wrong ends with the child exiting, and a
    /// non-zero exit gets an `errorRow` carrying stderr; an agent with
    /// no route to the network exits never and says nothing, so the
    /// session sat on a bare "Sipping…" indefinitely and the user had
    /// no reason to suspect the network over the model being slow.
    /// Hence naming the one cause that produces exactly this shape.
    ///
    /// Not styled as an error, because it isn't one — the turn is
    /// still running and may still answer. And STATIC, like the row it
    /// sits under: see `waitingRow` above for why nothing in this
    /// transcript is allowed to tick.
    private var stalledNoticeRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Localized-with-interpolation, not an interpolated
            // literal: the label is the user's own and must not be
            // markdown-parsed on its way to the screen.
            Text(String(localized: "No output from \(agentName) yet.",
                        comment: "Heading of the stalled-turn notice; placeholder is the agent's label"))
                .font(.system(size: 12 * fontScale, weight: .medium))
                .foregroundColor(ChatDesign.textPrimary)
            Text("The turn is still running, but nothing has come back for 5 minutes. This may be fine. However, if it persists for too long, it may indicate a blocked or misconfigured network route, which looks exactly like this because the agent retries in silence. In that case, please check your network connection and settings, or search online to see whether the AI provider is down.",
                 comment: "Body of the stalled-turn notice")
                .font(.system(size: 11 * fontScale))
                .foregroundColor(ChatDesign.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // Child-derived text — verbatim, never markdown-parsed.
            if !runner.stderrTail.isEmpty {
                Text(verbatim: runner.stderrTail)
                    .font(.system(size: 10 * fontScale, design: .monospaced))
                    .foregroundColor(ChatDesign.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(ChatDesign.cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(ChatDesign.border, lineWidth: 1)
                )
        )
    }
}

/// Stop on one line of the background work a turn waits on: that work
/// alone stops (`AgentRunner.stopBackgroundTask`), and the turn goes on
/// waiting for the rest. Reads "Stopping…" until the work is gone.
private struct BackgroundTaskStopButton: View {
    let stopping: Bool
    /// A codex background terminal, which runs a command.
    let terminal: Bool
    let fontSize: CGFloat
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(stopping
                 ? String(localized: "Stopping…",
                          comment: "Transcript: a background task or command the user stopped, until it is gone")
                 : String(localized: "Stop",
                          comment: "Transcript: stop one background task or command the turn waits on"))
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(stopping ? ChatDesign.textSecondary : ChatDesign.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovered && !stopping ? Color.gray.opacity(0.2) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(stopping)
        .onHover { hovered = $0 }
        .help(terminal
              ? String(localized: "Stop only this command",
                       comment: "Hover hint on Stop beside one of Codex's background terminals")
              : String(localized: "Stop only this task",
                       comment: "Hover hint on Stop beside one background task of the turn"))
    }
}
