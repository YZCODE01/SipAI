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
    /// as ChatView's `loadedChatSlug` (see CLAUDE.md): by the time
    /// onChange fires, `mode` already points at the INCOMING session,
    /// so stashing under it would file the outgoing text wrongly.
    ///
    /// The stash itself is `AppState.composerDrafts`, NOT view state:
    /// ContentView's router tears this whole view down on any detour to
    /// a chat or a note, so a view-owned dictionary lost every unsent
    /// prompt the moment the user looked at something else.
    @State private var loadedDraftKey: String? = nil
    /// Per-result expansion state. Shared by live and historical tool
    /// results — `eventId` / `item.id` serve the same role in both paths.
    @State private var expandedToolResults: Set<UUID> = []

    /// The sent message currently open for editing (row id), its draft
    /// text, and whether the fork is being written. Held on THIS view,
    /// not on the row: the transcript re-renders on every streamed event
    /// and swaps its whole item list on a history reload, so row-owned
    /// state would lose a half-typed edit to either. Same reasoning as
    /// `expandedToolResults`.
    @State private var editingRowId: UUID? = nil
    @State private var editDraft: String = ""
    @State private var branching: Bool = false
    /// Surfaced in the composer's existing alert slot — a branch that
    /// cannot be cut must say so, not fail quietly.
    @State private var branchError: String? = nil

    /// Composer selections (permission mode / model / effort). Seeded
    /// from config, persisted on every change, and attached to every
    /// send. Survives the draft→existing transition because it lives
    /// here rather than on the runner.
    @State private var launchOptions: AgentLaunchOptions = AgentLaunchOptions()
    /// True while `launchOptions` is being set programmatically (seeded
    /// from a session's own recorded values or the global prefs).
    /// Consumed by the `onChange` persist — only USER edits may update
    /// the sticky global launch prefs, or merely opening a session
    /// would clobber them.
    @State private var seedingOptions: Bool = false

    /// Context-window footprint parsed from the session JSONL when an
    /// existing session opens. Live `.result` events take precedence
    /// (see `displayContextTokens`).
    @State private var seededContextTokens: Int = 0

    /// Newest context-token total delivered by the runner's
    /// `$lastContextTokens` publisher. Mirrored into local @State (which
    /// the body reads) because this view deliberately does NOT observe
    /// the runner — only RunnerStreamView does, so streaming doesn't
    /// re-render the whole column. Carrying the VALUE through the
    /// publisher (instead of re-reading `runner.events` on a status
    /// flip) also sidesteps the actor-scheduling race where the
    /// turn-end re-render lands before the result event does.
    @State private var liveContextTokens: Int = 0

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
    /// file — the turn cap bit, or the file is bigger than the tail
    /// budget. Drives the find bar's scope note, which is what keeps
    /// "3 of 47" from reading as "47 in this session".
    @State private var historyPartial: Bool = false
    /// Set once "Search whole session" has re-read with the search
    /// budget, so the offer is not made twice.
    @State private var historyWidened: Bool = false
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

    /// Stable identity of the transcript currently on screen — the key
    /// the composer-draft stash files this view's text under.
    ///
    /// Every unsent draft shares ONE slot, deliberately.
    /// `ClaudeSessionDraft.init` mints a fresh UUID on every "+ New
    /// session", and leaving the draft nils `pendingClaudeSessionDraft`
    /// outright — so a per-draft key would file text typed into a new
    /// session under an identity nothing could ever ask for again.
    /// There is only ever one pending draft (it's a single optional on
    /// AppState), exactly as there is only ever one unsent new chat,
    /// and `chatDraftKey` gives that a single stable slot for the same
    /// reason. Two drafts in a row inherit the same unsent text, which
    /// is the point.
    private var transcriptKey: String? {
        switch mode {
        case .draft: return "draft:new"
        case .existing(let id, _, _, _): return id
        case .empty: return nil
        }
    }

    /// Stash the outgoing session's unsent text, restore the incoming
    /// session's. Both switch onChanges call this; when one logical
    /// switch fires both, the second call sees old == new and is a
    /// no-op.
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
        }
        if loadedDraftKey != newKey {
            inputDraft = appState.composerDraft(
                for: AppState.agentDraftKey(newKey))
            loadedDraftKey = newKey
        }
    }

    /// The conversation didn't change, its KEY did (draft → discovered
    /// session id). Adopt the new key and carry the text over.
    ///
    /// The carry is load-bearing now that writes happen per keystroke:
    /// this path leaves `inputDraft` untouched on purpose, so no
    /// `onChange` fires, so nothing would ever file the text under the
    /// new key — anything typed in the window between the first send
    /// and session-id discovery would sit under `draft:new` forever and
    /// read as lost the next time the session was opened.
    private func rekeyComposerDraft() {
        let old = loadedDraftKey
        loadedDraftKey = transcriptKey
        stashComposerDraft()
        if let old, old != loadedDraftKey {
            appState.setComposerDraft("", for: AppState.agentDraftKey(old))
        }
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

    /// True when the open session can be read but not driven from here.
    ///
    /// ONE rule, for every agent: a session is interactive exactly when
    /// its CLI is installed AND signed in (`isAgentReady`). The
    /// composer is replaced by a banner otherwise; nothing spawns, so a
    /// read-only session never becomes "active".
    ///
    /// No TUI is embedded for any agent — claude is driven headless
    /// (`claude -p --output-format stream-json`) and `codex exec
    /// --json` is the same shape — so the tier is purely a question
    /// about CREDENTIALS, never about which agent owns the session.
    private var isReadOnly: Bool {
        guard case .existing = mode else { return false }
        return !agents.isAgentReady(sessionAgentKey)
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
            // Reserve vertical room for the window's traffic lights
            // overlay. No title bar below — the message stream is the
            // only content above the input card. A scheduled-task panel
            // takes this inset over instead (see its `topInset`): a
            // spacer above it painted window background over the card,
            // which reads as a gap between the window top and the panel.
            if openScheduledTask == nil {
                Spacer().frame(height: 44)
            }
            if case .empty = mode, let task = openScheduledTask {
                // A task with no runs: nothing to transcribe and nothing
                // to send, so the settings ARE the page. No banner, no
                // welcome hero, no composer.
                ScheduledTaskPanel(task: task, presentation: .page,
                                   atWindowTop: true)
            } else {
            if let task = openScheduledTask {
                // Fixed type sizes: the panel is window chrome, like a
                // title bar, and reads against the transcript below it
                // rather than scaling with it.
                ScheduledTaskPanel(task: task, atWindowTop: true)
            }
            // Find bar — above the transcript, never over the composer
            // or the newest turn.
            if find.isOpen {
                FindBar(find: find,
                        scopeNote: historyPartial ? partialScopeNote : nil,
                        widenTitle: historyPartial
                            ? String(localized: "Search whole session",
                                     comment: "Find bar action that re-reads the full transcript")
                            : nil,
                        onWiden: historyPartial ? widenHistoryForSearch : nil,
                        widening: wideningHistory)
                    .padding(.horizontal, 60)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
            if let runner = currentRunner {
                RunnerStreamView(
                    runner: runner,
                    historicalItems: historicalItems,
                    isLoadingHistory: isLoading,
                    expandedToolResults: $expandedToolResults,
                    draftCwd: draftCwdForEmptyState,
                    emptySessionCommands: emptySessionCommands,
                    assistantLabel: sessionAgentName,
                    repositionNonce: repositionNonce,
                    find: find,
                    canBranch: canBranch,
                    editingRowId: $editingRowId,
                    editDraft: $editDraft,
                    branching: branching,
                    onBeginEdit: beginMessageEdit,
                    onCreateBranch: createSessionBranch,
                    onCancelEdit: cancelMessageEdit
                )
                // New structural identity per session: session switches
                // otherwise reuse the view (same type, same position),
                // so onAppear never re-fires and two sessions with
                // equal capped history counts kept each other's scroll
                // offset instead of landing at the newest turn.
                .id(runner.key)
                // Transcript text tracks the sidebar row size (13 pt at
                // Default) instead of the chat-content scale, so session
                // text never outsizes the session's own name.
                .environment(\.sipFontScale, SipFont.contentScale(fontScale))
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
                if isReadOnly {
                    readOnlyBar
                } else {
                    inputArea
                }
            }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(String(localized: "Could not create the branch",
                      comment: "Title of the alert shown when forking a session fails"),
               isPresented: Binding(
                   get: { branchError != nil },
                   set: { if !$0 { branchError = nil } }
               )) {
            Button(role: .cancel) { branchError = nil } label: {
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
        .onChange(of: inputDraft) { _, _ in stashComposerDraft() }
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
            } else {
                stashAndRestoreComposerDraft()
            }
            reload()
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
                seededContextTokens = 0
                liveContextTokens = 0
                seededTurnDuration = 0
                liveTurnDuration = nil
            }
            seedLaunchOptions()
        }
        .onChange(of: launchOptions) { _, new in
            // Programmatic seeds mirror what a session already recorded;
            // only user edits become the sticky prefs for future drafts
            // — and, for an open session, the per-session picks that
            // survive switching away and back.
            if seedingOptions { seedingOptions = false; return }
            // Per AGENT. The two CLIs share this picker but not its
            // vocabulary — "bypassPermissions" is meaningless to codex
            // and "workspace-write" to claude — so one sticky slot
            // would hand each agent the other's last choice.
            config.setAgentLaunchOptions(new, for: sessionAgentKey)
            if case .existing(let id, _, _, _) = mode {
                config.setAgentSessionLaunchOptions(new, for: id)
            }
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
        .onReceive(contextTokensPublisher) { value in
            // Equality guard: @Published replays its current value to
            // every (re)subscription, and onReceive resubscribes per
            // render — without the guard that replay would loop.
            guard value > 0, value != liveContextTokens else { return }
            liveContextTokens = value
        }
        .onReceive(turnDurationPublisher) { value in
            // Equality-guarded like the token feed, same reason.
            guard let value, value > 0, value != liveTurnDuration else { return }
            liveTurnDuration = value
        }
        .onReceive(externalTurnPublisher) { inProgress in
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
            // session file the external claude just finished writing.
            // Same for the mode/model/effort chips: the external turn
            // may have switched any of them.
            guard case .existing(_, let url, _, _) = mode else { return }
            // Per agent, like every other read keyed on a session's
            // owner: the two scanners decode different schemas, and
            // claude's would quietly answer 0 on a codex rollout. This
            // publisher rides the tailer, which only claude starts;
            // the per-agent branch keeps the wrong scanner from ever
            // being wired in.
            let scanned = sessionAgentKey == "codex"
                ? CodexSessionScanner.lastContextTokens(of: url)
                : AgentSessionScanner.lastContextTokens(of: url)
            if scanned > 0 { liveContextTokens = scanned }
            // Refresh the clock's resting value from the turn the other
            // terminal just finished — we have no live clock for it, so
            // the transcript is the only source. OFF-MAIN, unlike the
            // token read above it: this scan can escalate to a 4 MB
            // read, and doing that on the main actor at every external
            // turn boundary is a visible stall on a big session.
            Task.detached(priority: .utility) {
                let took = AgentSessionScanner.lastTurnDurationSeconds(of: url)
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
        .onReceive(liveModelIdPublisher) { fullId in
            // The subprocess's system.init names the model that will
            // actually serve the turn — more precise than the picker
            // alias. Equality-guarded like the token feed (@Published
            // replays on resubscribe).
            guard let fullId, !fullId.isEmpty,
                  launchOptions.modelFullId != fullId else { return }
            // Remember what this alias (or "" = claude's default)
            // resolved to — the only no-hardcoding source of versioned
            // names for fresh drafts and the picker rows.
            config.setAgentModelFullId(fullId,
                                       forAlias: launchOptions.model ?? "")
            // A mirror of recorded state, not a user edit: arm the
            // seeding flag so onChange skips persisting it as a pref.
            seedingOptions = true
            launchOptions.modelFullId = fullId
        }
    }

    /// The current runner's context-token feed. The value is published
    /// as assistant EVENTS carrying usage are appended (see
    /// AgentRunner) — live during the turn, from its first API call —
    /// so it can never race the status flip; the replay-on-subscribe
    /// also heals any emission a re-render gap might have missed.
    private var contextTokensPublisher: AnyPublisher<Int, Never> {
        guard let runner = currentRunner else {
            return Empty().eraseToAnyPublisher()
        }
        return runner.$lastContextTokens.eraseToAnyPublisher()
    }

    /// The runner's transcript path, which for a draft's first turn is
    /// resolved AFTER the session id (see `AgentRunner.awaitSessionFile`).
    /// Same delivery contract as `contextTokensPublisher`.
    private var sessionFilePublisher: AnyPublisher<URL?, Never> {
        guard let runner = currentRunner else {
            return Empty().eraseToAnyPublisher()
        }
        return runner.$sessionFileURL.eraseToAnyPublisher()
    }

    /// The runner's latest finished-turn duration — see
    /// `contextTokensPublisher` for the delivery contract it mirrors.
    private var turnDurationPublisher: AnyPublisher<Double?, Never> {
        guard let runner = currentRunner else {
            return Empty().eraseToAnyPublisher()
        }
        return runner.$lastTurnDuration.eraseToAnyPublisher()
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
    private var liveModelIdPublisher: AnyPublisher<String?, Never> {
        guard let runner = currentRunner else {
            return Empty().eraseToAnyPublisher()
        }
        return runner.$lastModelId.eraseToAnyPublisher()
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

    // A task with no runs renders `ScheduledTaskPanel(presentation:
    // .page)` — the settings page IS the answer to "nothing has run".

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
            return startedAt
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

    /// Replaces the composer for read-only sessions: the transcript
    /// above stays fully readable, nothing can be sent, and the bar's
    /// message says what to install or configure to continue the
    /// session.
    @ViewBuilder
    private var readOnlyBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 11))
                .foregroundColor(ChatDesign.textSecondary)
            Text(readOnlyMessage)
                .font(.system(size: 12))
                .foregroundColor(ChatDesign.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            // This bar shows exactly when `isAgentReady` is false; a
            // session whose CLI is signed in gets the real composer
            // instead.
        }
        .padding(.horizontal, 70)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var readOnlyMessage: String {
        if sessionAgentKey == "kimi" {
            // Only one flavour here, unlike codex: kimi has no auth
            // probe (see `AgentManager.isAgentReady`), so an installed
            // kimi is never read-only and this line only ever means
            // "the CLI is missing".
            // Names the install SCRIPT from Moonshot's own docs rather
            // than an npm package: the docs publish the script line
            // verbatim and leave the package name to a linked page, and
            // a guessed `npm install -g …` that 404s is worse than no
            // command at all.
            return String(
                localized: "Read-only — install the Kimi Code CLI (curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash) to continue this session.",
                comment: "Read-only bar message for a kimi session without the CLI")
        }
        if sessionAgentKey == "codex" {
            if agents.isAgentInstalled("codex") {
                return String(
                    localized: "Read-only — the Codex CLI is installed but not signed in. Configure it (codex login or an API key) to continue this session.",
                    comment: "Read-only bar message for a codex session when the CLI lacks auth")
            }
            return String(
                localized: "Read-only — install the Codex CLI (npm install -g @openai/codex) to continue this session.",
                comment: "Read-only bar message for a codex session without the CLI")
        }
        return String(
            localized: "Read-only — install the Claude Code CLI (npm install -g @anthropic-ai/claude-code) to continue this session.",
            comment: "Read-only bar message for a claude session without the CLI")
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
            options: $launchOptions,
            folder: composerFolder,
            folderEditable: isDraftBeforeFirstSend,
            onFolderChange: { url in
                appState.pendingClaudeSessionDraft?.cwd = url
            },
            scheduleAvailable: isScheduleAvailable,
            scheduledRunInfo: scheduledRunInfo,
            onGenerateNote: { generateSessionNote(extraPrompt: $0) },
            noteGenerating: noteGenerating,
            canGenerateNote: canGenerateSessionNote,
            find: find,
            canFind: hasSearchableTranscript,
            contextTokens: displayContextTokens,
            turnStartedAt: turnStartedAt,
            lastTurnDuration: displayTurnDuration,
            onSend: handleSend,
            onStop: handleStop,
            onScheduleCreated: {
                agents.reloadSessions()
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

    /// Is what is loaded the whole conversation?
    ///
    /// `readHistory` returns the newest 50 turns of an 8 MB tail, so
    /// two things mean "there is more": the turn cap was reached, or
    /// the file is bigger than the tail. Evaluated when the bar OPENS
    /// rather than per render — it stats the file, and a body that
    /// touches the filesystem runs on every streamed event.
    private func evaluateHistoryScope() {
        guard case .existing(_, let url, _, _) = mode, !historyWidened else {
            historyPartial = false
            return
        }
        let turns = historicalItems.reduce(into: 0) { total, item in
            if case .userText = item.kind { total += 1 }
        }
        let big = (Self.fileStat(url)?.size ?? 0) > UInt64(8 * 1024 * 1024)
        historyPartial = turns >= 50 || big
    }

    /// Re-read the transcript with search's own (larger, still bounded)
    /// budget so the counter can describe the whole file.
    ///
    /// Deliberately NOT written into `AgentHistoryCache`: that cache
    /// feeds every ordinary open, and seeding it with a whole-file read
    /// would make every later visit to this session pay for one find.
    ///
    /// No jump afterwards, on purpose. The re-read mints fresh row ids,
    /// so the active match cannot be preserved by identity, and sending
    /// the reader to match 1 of 400 would render every row between here
    /// and the start of the session. The counter updates; ↑ walks back
    /// one match — and one window growth — at a time.
    private func widenHistoryForSearch() {
        guard case .existing(_, let url, _, _) = mode, !wideningHistory else { return }
        wideningHistory = true
        let agentKey = sessionAgentKey
        Task {
            let items = await Task.detached(priority: .userInitiated) {
                () -> [AgentSessionHistoryItem] in
                let budget = SearchTextExtractor.searchByteBudget
                switch agentKey {
                case "codex":
                    return CodexSessionScanner.readHistory(
                        of: url, maxTurns: .max, byteBudget: budget)
                case "kimi":
                    return KimiSessionScanner.readHistory(
                        of: url, maxTurns: .max, byteBudget: budget)
                default:
                    return AgentSessionScanner.readHistory(
                        of: url, maxTurns: .max, byteBudget: budget)
                }
            }.value
            // The user may have switched sessions mid-read.
            guard case .existing(_, let current, _, _) = mode, current == url else {
                wideningHistory = false
                return
            }
            wideningHistory = false
            guard !items.isEmpty else { return }
            historicalItems = items
            historyWidened = true
            historyPartial = false
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
    /// events (the two never overlap — history is read once at open,
    /// live events only accumulate afterwards). Tool calls/outputs are
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
                localized: "No chat model configured. Add one in Settings → Chat models.",
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

    private func handleSend() {
        let text = inputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Draft: the runner is created here, on first send, so it
        // captures the folder the composer shows right now.
        let runner: AgentRunner?
        switch mode {
        case .draft(let d):
            runner = agents.runner(forDraft: d)
        case .existing, .empty:
            runner = currentRunner
        }
        guard let runner = runner else { return }

        if runner.send(text: text, options: launchOptions) {
            // The session is demonstrably alive again — a stale
            // load-time marker must not sit between the old turn and
            // this new one.
            dropInterruptedMarker()
            inputDraft = ""
            // Drop any stashed copy too, or switching away and back
            // would resurrect the just-sent text into the composer.
            stashComposerDraft()
            // Record what this session actually ran with. Persisting
            // what each send used means the transcript guess in
            // `seedLaunchOptions` is only ever needed for a session
            // this app has never driven.
            if case .existing(let id, _, _, _) = mode {
                config.setAgentSessionLaunchOptions(launchOptions, for: id)
            }
        }
    }

    // MARK: - Branching from an earlier message

    /// Whether the transcript offers the branch pencil at all.
    ///
    /// Only a real, writable claude session can be branched: a draft has
    /// no transcript to cut, and a session with a turn in flight — ours
    /// or another terminal's — is being APPENDED TO right now, so any
    /// prefix we copied would be a guess about where the conversation
    /// ends.
    ///
    /// The claude-only restriction is not about the read-only tier. It
    /// is that `AgentSessionFork` writes a claude session JSONL: it
    /// rewrites `sessionId` on every record and relies on `--resume
    /// <new uuid>` finding the file under `~/.claude/projects`. A
    /// codex branch would have to write a rollout.
    private var canBranch: Bool {
        guard case .existing = mode, !isReadOnly,
              sessionAgentKey == "claude_code" else { return false }
        guard let runner = currentRunner else { return false }
        return !runner.status.isRunning && !runner.externalInProgress
    }

    private func beginMessageEdit(rowId: UUID, text: String) {
        editDraft = text
        editingRowId = rowId
    }

    private func cancelMessageEdit() {
        editingRowId = nil
        editDraft = ""
    }

    /// Fork the session at the edited message and send the new text into
    /// the branch. The source session is never touched.
    ///
    /// `recordUuid` is the transcript record the row came from. History
    /// rows carry it; LIVE rows (a message sent this run, still only in
    /// the runner's event buffer) don't, and are resolved by matching
    /// their text against the transcript — the same identification
    /// `trimmedForInFlight` already makes.
    private func createSessionBranch(recordUuid: String?,
                                     originalText: String,
                                     newText: String) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !branching,
              case .existing(let sourceId, let url, let cwd, _) = mode
        else { return }

        branching = true
        // Explicitly MainActor: everything after the detached read
        // touches @State, AppState, ConfigManager and AgentManager.
        Task { @MainActor in
            do {
                let forked = try await Task.detached(priority: .userInitiated) {
                    () -> (result: AgentSessionFork.Result, cut: String) in
                    guard let cut = recordUuid
                            ?? AgentSessionFork.resolveCutPoint(
                                matchingUserText: originalText, in: url)
                    else { throw AgentSessionFork.ForkError.cutPointNotFound }
                    return (try AgentSessionFork.fork(source: url,
                                                      cutAtRecordUuid: cut),
                            cut)
                }.value

                branching = false
                // The user may have moved on while the prefix was being
                // written. The branch file is complete and harmless — it
                // will simply appear in the sidebar as its own session —
                // but hijacking the centre pane out from under them is
                // not on.
                guard case .existing(let stillOpen, _, _, _) = mode,
                      stillOpen == sourceId else { return }

                let newId = forked.result.sessionId
                config.setAgentSessionBranch(source: sourceId,
                                             recordUuid: forked.cut,
                                             for: newId)
                // Named from the message that starts it. The branch
                // inherits no ai-title (the fork drops the parent's), so
                // without this it would sit in the sidebar under a name
                // derived from a conversation it has just diverged from.
                config.setAgentSessionDisplayName(
                    AgentSessionFork.branchTitle(from: text), for: newId)
                config.setAgentSessionLaunchOptions(launchOptions, for: newId)

                // Runner BEFORE routing, with the cwd handed in — see
                // `registerBranchedSession` for why that order is a
                // correctness rule and not a preference.
                let runner = agents.registerBranchedSession(
                    id: newId,
                    fileURL: forked.result.fileURL,
                    cwd: cwd,
                    title: AgentSessionFork.branchTitle(from: text)
                )
                cancelMessageEdit()
                // A branch is its own session, not another run of
                // whatever scheduled task this transcript belonged to.
                appState.openScheduledTaskName = nil
                appState.openAgentSessionId = newId
                appState.openAgentSessionPath = forked.result.fileURL
                runner.send(text: text, options: launchOptions)
            } catch AgentSessionFork.ForkError.nothingToBranch {
                // Editing the session's FIRST message. There is no
                // shared history to carry, which makes the branch simply
                // a new session in the same folder — so make one, rather
                // than answering a reasonable request with an error.
                branching = false
                guard case .existing(let stillOpen, _, _, _) = mode,
                      stillOpen == sourceId else { return }
                startBranchAsNewSession(cwd: cwd, text: text)
            } catch {
                branching = false
                branchError = error.localizedDescription
            }
        }
    }

    /// The degenerate branch: nothing above the edited message, so this
    /// is a fresh session carrying only the new text. Goes through the
    /// ordinary draft path — the same one "+ New session" uses — so
    /// session-id discovery, the runner migration and the sidebar row
    /// all behave exactly as they do for any other new session.
    private func startBranchAsNewSession(cwd: URL, text: String) {
        let draft = ClaudeSessionDraft(cwd: cwd)
        cancelMessageEdit()
        appState.openScheduledTaskName = nil
        appState.pendingClaudeSessionDraft = draft
        agents.runner(forDraft: draft).send(text: text, options: launchOptions)
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

    /// Seed the composer's mode / model / effort chips. An existing
    /// session shows its own latest recorded values — every writer
    /// (this app, a terminal, the desktop app) records them in the
    /// JSONL — so reopening picks up exactly where it left off.
    /// Drafts fall back to the sticky global launch prefs.
    private func seedLaunchOptions() {
        refreshObservedModelNames()
        switch mode {
        case .existing(let id, let url, _, _):
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
            if let fullId = scanned.model {
                // Keep the full id alongside the alias: the chip shows
                // the versioned name ("Opus 5"), the picker matches on
                // the alias row.
                seeded.model = composerModelValue(forFullId: fullId)
                seeded.modelFullId = fullId
            }
            applySeededOptions(seeded)
        case .draft, .empty:
            applySeededOptions(config.agentLaunchOptions(for: sessionAgentKey))
        }
    }

    /// Equality-guarded so the `seedingOptions` flag is armed only when
    /// `onChange` will actually fire to consume it — arming it on a
    /// no-op assignment would swallow the user's next real edit.
    private func applySeededOptions(_ options: AgentLaunchOptions) {
        guard options != launchOptions else { return }
        seedingOptions = true
        launchOptions = options
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
        // the user's explicit choices for this new session.
        config.setAgentSessionLaunchOptions(launchOptions, for: id)
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

    private func reload() {
        // An open edit belongs to the transcript it was opened in. This
        // also covers the branch flow's own routing flip, where the edit
        // has already been closed — a second clear costs nothing.
        editingRowId = nil
        editDraft = ""
        // So does a find: a query left standing would count matches in
        // a transcript nobody asked it about, and the widened-scope
        // flags describe the file being left behind. Arrival from a
        // global-search result re-opens it a runloop turn later
        // (`consumePendingFind`), so this cannot fight that.
        find.close()
        historyWidened = false
        historyPartial = false
        wideningHistory = false
        guard case .existing(_, let url, _, _) = mode else {
            // Draft mode: nothing on disk yet. RunnerStreamView
            // handles its empty state.
            historicalItems = []
            expandedToolResults = []
            seededContextTokens = 0
            liveContextTokens = 0
            seededTurnDuration = 0
            liveTurnDuration = nil
            externalTurnStart = nil
            externalStoppable = false
            emptySessionCommands = []
            isLoading = false
            return
        }
        // Draft→existing migration mid-first-turn: the JSONL already
        // holds the first user record the runner is rendering live, so
        // a disk read here duplicated the first bubble. There is no
        // history a fresh draft could be missing — keep the (already
        // empty) list and let the stream carry the whole session.
        if let runner = currentRunner, runner.status.isRunning,
           historicalItems.isEmpty {
            isLoading = false
            return
        }
        expandedToolResults = []
        // The publisher's replay repopulates this from the (per-session)
        // cached runner right after the switch — resetting first keeps a
        // previous session's total from flashing on the new one. Same
        // for the duration chip and the external-turn mirrors.
        liveContextTokens = 0
        liveTurnDuration = nil
        externalTurnStart = nil
        externalStoppable = false

        // Cache hit: render the last parsed history NOW — the click
        // shows content immediately, at its end. File unchanged →
        // done, no disk read at all. Changed → swap in the fresh read
        // when it lands and pull to the new end.
        if case .existing(let sid, _, _, _) = mode,
           let cached = historyCache.entry(for: sid) {
            // Re-warm the markdown cache SYNCHRONOUSLY for the rows
            // the first frame renders — the parse cache is shared and
            // bounded, so another session's rows may have evicted
            // these since the last visit, and this path skips the
            // loader (whose prewarm covers first visits).
            Self.prewarmMarkdown(cached.items, tail: 30)
            historicalItems = trimmedForInFlight(cached.items)
            seededContextTokens = cached.contextTokens
            seededTurnDuration = cached.turnDuration
            emptySessionCommands = cached.commands
            isLoading = false
            // A cache hit swaps content in with no isLoading flip to
            // announce it, and the incoming RunnerStreamView was built
            // one pass EARLIER — while `historicalItems` still held the
            // outgoing session's rows. Say so explicitly rather than
            // relying on the swap's own geometry to imply it.
            repositionNonce &+= 1
            currentRunner?.clearEvents()
            if let stat = Self.fileStat(url),
               stat.size == cached.fileSize, stat.mtime == cached.fileMtime {
                return
            }
            startHistoryLoad(url: url, viaSpinner: false)
            return
        }

        isLoading = true
        seededContextTokens = 0
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
        // Stat BEFORE the read: an append racing the read makes the
        // cache look stale next open — a refresh, never a miss.
        let stat = Self.fileStat(url)
        Task {
            let loaded = await Task.detached(priority: .userInitiated)
            { () -> (items: [AgentSessionHistoryItem], contextTokens: Int,
                     turnDuration: Double, commands: [String]) in
                if agentKey == "codex" {
                    // No turn duration: codex reports no wall-clock time
                    // anywhere, in the stream or the rollout. The context
                    // footprint IS on record though — one `token_count`
                    // per API call — and a hardcoded 0 here would keep
                    // the composer's token chip from ever appearing on
                    // a codex session (the chip hides itself at 0).
                    let items = CodexSessionScanner.readHistory(of: url)
                    Self.prewarmMarkdown(items)
                    return (items,
                            CodexSessionScanner.lastContextTokens(of: url),
                            0, [])
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
                    let items = KimiSessionScanner.readHistory(of: url)
                    Self.prewarmMarkdown(items)
                    return (items,
                            KimiSessionScanner.lastContextTokens(of: url),
                            0, [])
                }
                var items = AgentSessionScanner.readHistory(of: url)
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
                return (items,
                        AgentSessionScanner.lastContextTokens(of: url),
                        // Off-main by construction — this is the only
                        // place the transcript is read for the clock.
                        AgentSessionScanner.lastTurnDurationSeconds(of: url),
                        commands)
            }.value
            guard case .existing(let sid, let current, _, _) = mode, current == url else {
                // The user switched away mid-load.
                return
            }
            historyCache.store(
                AgentHistoryCache.Entry(
                    items: loaded.items,
                    contextTokens: loaded.contextTokens,
                    turnDuration: loaded.turnDuration,
                    commands: loaded.commands,
                    fileSize: stat?.size ?? 0,
                    fileMtime: stat?.mtime ?? .distantPast
                ),
                for: sid
            )
            historicalItems = trimmedForInFlight(loaded.items)
            seededContextTokens = loaded.contextTokens
            // Into the runner as well, for the same reason
            // `noteExternalTurnDuration` exists: `reload()` cleared the
            // live mirror a moment ago and the runner's replay is about
            // to refill it, so a total left over from an earlier turn of
            // ours would outrank this freshly-read one — the composer
            // would go on showing the older number over a transcript
            // that has moved on. This read IS of the current file, so it
            // is never the staler of the two.
            currentRunner?.noteTranscriptContextTokens(loaded.contextTokens)
            seededTurnDuration = loaded.turnDuration
            emptySessionCommands = loaded.commands
            if viaSpinner {
                isLoading = false
            } else {
                repositionNonce &+= 1
            }
            // The freshly-read history now covers every finished turn,
            // including ones this runner streamed live earlier — drop
            // the live buffer or those turns render twice. No-op while
            // a turn is running (clearEvents refuses mid-turn).
            currentRunner?.clearEvents()
        }
    }

    /// See the in-flight-turn overlap note: the JSONL already holds a
    /// running turn's records, but the live event buffer owns rendering
    /// that turn (`clearEvents()` refuses mid-turn) — keeping both
    /// showed the user's message and the turn's partial records TWICE
    /// until the turn ended. Cut history at the in-flight turn's start
    /// — but ONLY while the live buffer still holds the turn's
    /// `.userMessage` head: the cap trims old events from the front,
    /// and cutting past a trimmed buffer EATS the turn's middle.
    private func trimmedForInFlight(
        _ loaded: [AgentSessionHistoryItem]
    ) -> [AgentSessionHistoryItem] {
        guard let runner = currentRunner, runner.status.isRunning,
              let sent = runner.inFlightUserText,
              runner.events.contains(where: { event in
                  if case .userMessage(let t) = event.kind { return t == sent }
                  return false
              }),
              let cut = loaded.lastIndex(where: { item in
                  if case .userText(let t) = item.kind { return t == sent }
                  return false
              })
        else { return loaded }
        var items = loaded
        items.removeSubrange(cut...)
        return items
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

    /// Nonisolated: the history loader stats the file from its
    /// detached read task (the marker's quiet-window check).
    nonisolated private static func fileStat(_ url: URL)
    -> (size: UInt64, mtime: Date)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        return (size, mtime)
    }
}

// MARK: - Approval button hover

/// Hover feedback for the approval card's four verdict buttons. They
/// keep their system bezels (one of them is `.borderedProminent` — a
/// custom style would mean re-drawing that), so the hover cue is a
/// slight lift + brighten on top of the bezel rather than a background
/// wash behind it, which reads as a halo around a bezel's edges.
private struct ApprovalButtonHover: ViewModifier {
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovered ? 1.04 : 1)
            .brightness(hovered ? 0.05 : 0)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .onHover { hovered = $0 }
    }
}

// MARK: - RunnerStreamView

// `TranscriptGeometry` and the follow rule itself live in
// `Utilities/TranscriptFollow.swift` — one object, shared with
// `ChatView`.

/// Observes one AgentRunner and renders its live events below the
/// JSONL-derived historical turns. Split out as an @ObservedObject
/// subview so SwiftUI re-renders on event-buffer mutations without
/// forcing the parent to own the observation.
private struct RunnerStreamView: View {
    @ObservedObject var runner: AgentRunner
    @EnvironmentObject var mcpBridge: MCPBridge
    @EnvironmentObject var config: ConfigManager

    /// This transcript's agent under the user's own label — the runner
    /// knows which CLI it drives, so nothing here has to be told.
    private var agentName: String {
        let fallback = AgentManager.registry
            .first { $0.key == runner.agentKey }?.name ?? "Claude Code"
        return config.agentLabel(for: runner.agentKey, defaultName: fallback)
    }
    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.sipLineSpacingFactor) private var lineSpacingFactor

    /// Historical items from the JSONL file on disk, rendered ABOVE
    /// the live event list. Empty on a fresh draft. Each item goes
    /// through the same `toolActivityChip` / `orphanResultChip` /
    /// `MessageBubble` renderers used for live events, so the visual
    /// shape of past and present turns is identical.
    let historicalItems: [AgentSessionHistoryItem]
    let isLoadingHistory: Bool

    /// Shared with the live path — `eventId` for live rows, `item.id`
    /// for historical rows. The two never collide because both are
    /// freshly-minted UUIDs.
    @Binding var expandedToolResults: Set<UUID>

    /// In draft mode (no history, no events yet) this is shown to
    /// explain the target cwd.
    let draftCwd: URL?

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
    let onBeginEdit: (UUID, String) -> Void
    /// `(record uuid or nil for a live row, the original text, the
    /// edited text)`.
    let onCreateBranch: (String?, String, String) -> Void
    let onCancelEdit: () -> Void

    init(runner: AgentRunner,
         historicalItems: [AgentSessionHistoryItem],
         isLoadingHistory: Bool,
         expandedToolResults: Binding<Set<UUID>>,
         draftCwd: URL?,
         emptySessionCommands: [String],
         assistantLabel: String,
         repositionNonce: Int,
         find: TranscriptFindState,
         canBranch: Bool,
         editingRowId: Binding<UUID?>,
         editDraft: Binding<String>,
         branching: Bool,
         onBeginEdit: @escaping (UUID, String) -> Void,
         onCreateBranch: @escaping (String?, String, String) -> Void,
         onCancelEdit: @escaping () -> Void) {
        self.runner = runner
        self.historicalItems = historicalItems
        self.isLoadingHistory = isLoadingHistory
        self._expandedToolResults = expandedToolResults
        self.draftCwd = draftCwd
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
        self.onCancelEdit = onCancelEdit
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
    private var toolPairing: (byUseId: [String: PairedResult],
                             consumed: Set<UUID>,
                             labelled: Set<UUID>) {
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

        // Third product of the same walk: which tool chips OPEN the
        // agent's answer and therefore have to carry the label a text
        // bubble would have carried.
        //
        // `MessageBubble` draws the "Claude Code" header, and only
        // `.assistantText` / `.userText` rows go through it — so a turn
        // whose first output is a tool call (very common: the agent
        // reads a file before saying anything) began with an unattributed
        // chip. Marked here rather than in the row renderer because a
        // row cannot see what came before it, and this walk is already
        // paid for once per render pass.
        var labelled: Set<UUID> = []
        var sawAgentRow = false
        func advance(isUser: Bool, isTool: Bool, id: UUID) {
            if isUser { sawAgentRow = false; return }
            if isTool, !sawAgentRow { labelled.insert(id) }
            sawAgentRow = true
        }
        for item in historicalItems {
            switch item.kind {
            case .userText: advance(isUser: true, isTool: false, id: item.id)
            case .assistantText: advance(isUser: false, isTool: false, id: item.id)
            case .toolUse: advance(isUser: false, isTool: true, id: item.id)
            // Folded into its own chip, or a rare orphan — neither opens
            // a block, and neither should end one. Same for the
            // interrupted marker: a terminal note, not a block.
            case .toolResult, .interrupted: break
            }
        }
        for event in runner.events {
            switch event.kind {
            case .userMessage: advance(isUser: true, isTool: false, id: event.id)
            case .assistantText: advance(isUser: false, isTool: false, id: event.id)
            case .toolUse: advance(isUser: false, isTool: true, id: event.id)
            // systemInit / result / error / toolResult: not block starts.
            default: break
            }
        }
        return (byUse, consumed, labelled)
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
    // `historyDisplayCap` is a rendering bound, and a find that could
    // only see 40 rows would be answering a different question than the
    // one asked. Jumping past the window grows it (`jumpToActiveMatch`).

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
        var texts = [AgentRendering.displayToolName(name),
                     AgentRendering.summarizeToolInput(name: name, input: input)]
        texts += AgentRendering.fullToolBody(name: name, input: input).map(\.text)
        if let result {
            texts += AgentRendering.fullToolResultBody(result.output).map(\.text)
        }
        return texts
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
        var rows: [FindableRow] = []
        rows.reserveCapacity(historicalItems.count + runner.events.count)
        // Exactly the rows that still exist, handed back to the memo at
        // the end so a cap-trimmed event's entry goes with it.
        var live: [TranscriptRowTextCache.Key: String] = [:]

        func add(_ id: UUID, resolved: Bool = false, _ build: () -> String) {
            let key = TranscriptRowTextCache.Key(id: id, resolved: resolved)
            let text = rowTextCache.text(for: key, build: build)
            live[key] = text
            rows.append(FindableRow(id: id, text: text))
        }

        for item in historicalItems {
            switch item.kind {
            case .userText(let text), .assistantText(let text):
                add(item.id) { MarkdownRenderer.plainText(text) }
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
            case .interrupted(let message):
                add(item.id) { message }
            }
        }

        for event in runner.events {
            switch event.kind {
            case .userMessage(let text), .assistantText(let text):
                add(event.id) { MarkdownRenderer.plainText(text) }
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
            // are not rows.
            case .systemInit, .result:
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

        // Both windows are SUFFIXES, so what matters is the match's
        // distance from the newest row.
        //
        // Located by ROW ID, never by `match.rowIndex`: that index runs
        // over the SEARCHABLE rows, which skip every tool result folded
        // into its call, while the windows are suffixes of the raw
        // arrays. On any transcript with tool activity — i.e. all of
        // them — the two disagree, and the window would be grown by the
        // wrong amount.
        var grew = false
        if let index = historicalItems.firstIndex(where: { $0.id == match.rowId }) {
            let fromEnd = historicalItems.count - index
            if fromEnd > historyDisplayCap {
                historyDisplayCap = fromEnd + 5
                grew = true
            }
        } else if let index = runner.events.firstIndex(where: { $0.id == match.rowId }) {
            let fromEnd = runner.events.count - index
            if fromEnd > liveDisplayCap {
                liveDisplayCap = fromEnd + 5
                grew = true
            }
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

    /// Pending approvals belonging to this runner's session.
    /// Matches on either session_id (existing-session runner) or
    /// task_uuid (draft runner before system.init has fired).
    private var approvalsForRunner: [MCPApprovalRequest] {
        mcpBridge.pending.filter { req in
            if let sid = runner.sessionId, !sid.isEmpty {
                return req.sessionId == sid
            }
            if let key = runner.taskUuidForBridge {
                return req.taskUuid == key
            }
            return false
        }
    }

    /// How many of the newest history rows render initially. These are
    /// laid out EAGERLY (see `transcriptStack`), so this is the knob
    /// that trades open-time cost against how far back you can scroll
    /// before "Show earlier". Reset per session by the parent's
    /// `.id(runner.key)`.
    @State private var historyDisplayCap = 40

    private var displayedHistory: ArraySlice<AgentSessionHistoryItem> {
        historicalItems.suffix(historyDisplayCap)
    }

    /// How many of the newest LIVE rows render. Same trade as
    /// `historyDisplayCap` — these are laid out eagerly too now — but a
    /// looser cap, because live rows are mostly one-line tool chips and
    /// because this stack is EMPTY at open (`clearEvents()`), so the
    /// cost is paid a row at a time as a turn streams rather than all
    /// at once. `AgentRunner.liveEventCap` (800) is the buffer's own
    /// ceiling; this is the rendered window into it.
    @State private var liveDisplayCap = 150

    private var displayedEvents: ArraySlice<StreamEvent> {
        runner.events.suffix(liveDisplayCap)
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

    /// Searchable text per row, so a find left open during a turn does
    /// not re-derive every chip on every streamed event. A class in
    /// plain `@State` for the same reason `follow` is one: nothing it
    /// holds is rendered.
    @State private var rowTextCache = TranscriptRowTextCache()

    /// Go to the newest row. Unlike `scrollTo(id:)` this asks the
    /// scroll view for its own bottom edge, so it does not depend on
    /// resolving a row through lazy content of unknown height.
    private func scrollToEnd() {
        scrollPosition.scrollTo(edge: .bottom)
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            transcriptStack
        }
        // Born at the end. This is the whole "sessions open at their
        // newest row" feature — an initial position the scroll view
        // honours on its first layout pass, not a jump performed
        // afterwards and hidden until it lands.
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: TranscriptGeometry.self) { geo in
            TranscriptGeometry(geo)
        } action: { old, new in
            if follow.geometryChanged(from: old, to: new) == .snapToEnd {
                scrollToEnd()
            }
        }
        // Who is moving the scroll view, asked of the scroll view
        // itself. Geometry deltas cannot answer this — a sample says
        // the end moved, never whose hand did it — and guessing from
        // them is what let the follow engine fight the reader.
        .onScrollPhaseChange { _, phase, context in
            if follow.phaseChanged(to: phase,
                                   geometry: TranscriptGeometry(context.geometry)) {
                scrollToEnd()
            }
        }
        .onAppear {
            // Born mid-read (the parent's own onAppear calls reload()
            // before this view exists) sees no onChange — arm the
            // delayed spinner here too.
            if isLoadingHistory { armLoadingRow() }
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
    /// This is why the window is CAPPED (`historyDisplayCap`): eager
    /// means every row in the window is laid out up front, so the
    /// window has to stay small enough for that to be cheap.
    ///
    /// The LIVE rows below it are eager and capped (`liveDisplayCap`)
    /// for a second reason — a lazy tail's estimated height moves as
    /// rows realize, and the follow engine cannot tell that movement
    /// from real content growth. See the note at the live block below,
    /// and `Utilities/TranscriptFollow.swift`.
    @ViewBuilder
    private var transcriptStack: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        let pairing: (byUseId: [String: PairedResult],
                                      consumed: Set<UUID>,
                                      labelled: Set<UUID>) = toolPairing
                        if historicalItems.count > historyDisplayCap {
                            Button {
                                historyDisplayCap += 200
                            } label: {
                                Text(String(localized: "Show earlier — \(historicalItems.count - historyDisplayCap) older rows",
                                            comment: "Button above a truncated transcript; placeholder is the hidden row count"))
                                    .font(.system(size: 12 * fontScale))
                                    .foregroundColor(ChatDesign.textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        // EAGER on purpose — see the container's note.
                        ForEach(displayedHistory) { item in
                            renderHistoricalItem(item, pairing: pairing)
                                .id(item.id)
                        }
                        // Live rows are EAGER and CAPPED, like the
                        // history window above. A lazy stack's total
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
                            || !approvalsForRunner.isEmpty {
                            if runner.events.count > liveDisplayCap {
                                Button {
                                    liveDisplayCap += 200
                                } label: {
                                    Text(String(localized: "Show earlier — \(runner.events.count - liveDisplayCap) older rows in this turn",
                                                comment: "Button above a truncated live event stream; placeholder is the hidden row count"))
                                        .font(.system(size: 12 * fontScale))
                                        .foregroundColor(ChatDesign.textSecondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(displayedEvents) { event in
                                    renderEvent(event, pairing: pairing)
                                        .id(event.id)
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
                                // Only until Claude's first output lands
                                // — see `awaitingFirstAgentEvent`. Not
                                // shown under an approval card: there
                                // the wait is on the USER, not on
                                // Claude, and a spinner would say the
                                // opposite.
                                if awaitingFirstAgentEvent
                                    && approvalsForRunner.isEmpty {
                                    waitingRow
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
                            }
                        }
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 16)
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

    // MARK: - Historical item rendering

    /// Fan each history item out to the same renderer the live path
    /// uses. Tool uses and tool results land in `toolActivityChip` /
    /// `orphanResultChip`, so Edit-diff rendering and per-chip
    /// tap-to-expand come for free — and stay automatically in sync
    /// with any future changes to the live path.
    @ViewBuilder
    private func renderHistoricalItem(
        _ item: AgentSessionHistoryItem,
        pairing: (byUseId: [String: PairedResult],
                  consumed: Set<UUID>,
                  labelled: Set<UUID>)
    ) -> some View {
        switch item.kind {
        case .userText(let text):
            // Stable id (the row's own), NOT ChatMessage's default
            // UUID(): a fresh id per render pass makes every visible
            // bubble's inputs "changed" on every streamed burst, so
            // SwiftUI can never skip the subtree.
            userRow(rowId: item.id, text: text, recordUuid: item.recordUuid,
                    isSystemNotice: item.isSystemNotice)
                .environment(\.sipSearchSlot, find.slot(forRow: item.id))
        case .assistantText(let text):
            MessageBubble(
                message: ChatMessage(id: item.id, role: "assistant", content: text),
                assistantLabelOverride: assistantLabel
            )
            .environment(\.sipSearchSlot, find.slot(forRow: item.id))
        case .toolUse(let id, let name, let input):
            toolActivityChip(chipId: item.id, name: name, input: input,
                             result: pairing.byUseId[id],
                             showsLabel: pairing.labelled.contains(item.id))
        case .toolResult(_, let content, let isError):
            if !pairing.consumed.contains(item.id) {
                orphanResultChip(chipId: item.id, output: content,
                                 isError: isError)
            }
        case .interrupted(let message):
            interruptedRow(message: message, slot: find.slot(forRow: item.id))
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
                         isSystemNotice: Bool = false) -> some View {
        if editingRowId == rowId {
            BranchEditor(
                text: $editDraft,
                // `!canBranch` covers a turn that STARTED while the
                // editor was open — from the composer below it, or from
                // another terminal. Forking then would copy a prefix out
                // of a file that is being appended to, i.e. guess where
                // the conversation ends.
                busy: branching || !canBranch,
                explanation: String(
                    localized: "Starts a new session from this point. This one is kept as it is.",
                    comment: "Explanation under the branch editor in an agent transcript"),
                onCreate: { onCreateBranch(recordUuid, text, editDraft) },
                onCancel: onCancelEdit
            )
        } else {
            MessageBubble(
                message: ChatMessage(id: rowId, role: "user", content: text),
                assistantLabelOverride: assistantLabel,
                userLabelOverride: isSystemNotice ? Self.systemNoticeLabel : nil,
                onEdit: (canBranch && editingRowId == nil)
                    ? { onBeginEdit(rowId, text) } : nil,
                editHint: String(
                    localized: "Create a new session branch from here",
                    comment: "Tooltip for the branch pencil on a sent agent message")
            )
        }
    }

    // MARK: - Live event rendering

    @ViewBuilder
    private func renderEvent(
        _ event: StreamEvent,
        pairing: (byUseId: [String: PairedResult],
                  consumed: Set<UUID>,
                  labelled: Set<UUID>)
    ) -> some View {
        switch event.kind {
        case .userMessage(let text):
            // Stable id — see renderHistoricalItem. No record uuid: this
            // message has only ever existed in the live buffer, so the
            // fork resolves its transcript record by text.
            userRow(rowId: event.id, text: text, recordUuid: nil,
                    isSystemNotice: event.isSystemNotice)
                .environment(\.sipSearchSlot, find.slot(forRow: event.id))
        case .assistantText(let text):
            MessageBubble(
                message: ChatMessage(id: event.id, role: "assistant", content: text),
                assistantLabelOverride: assistantLabel
            )
            .environment(\.sipSearchSlot, find.slot(forRow: event.id))
        case .toolUse(let id, let name, let input):
            toolActivityChip(chipId: event.id, name: name, input: input,
                             result: pairing.byUseId[id],
                             showsLabel: pairing.labelled.contains(event.id))
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
        }
    }

    /// Quiet system row for a turn that was stopped before finishing —
    /// deliberately not `errorRow`: stopping is a normal act, so it
    /// speaks in the transcript's secondary voice, not in red.
    private func interruptedRow(message: String,
                                slot: SearchHighlightSlot = .inactive) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "stop.circle")
                .font(.system(size: 12))
                .foregroundColor(ChatDesign.textSecondary)
            Text(AttributedString.highlighting(message, slot: slot).0)
                .font(.system(size: 12))
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
    /// this chip OPENS the answer (see `toolPairing.labelled`) — a turn
    /// that starts by reading a file otherwise showed no attribution at
    /// all, because the header lives in `MessageBubble` and a tool call
    /// never goes through it.
    private func toolActivityChip(chipId: UUID,
                                  name: String,
                                  input: [String: Any],
                                  result: PairedResult?,
                                  showsLabel: Bool = false) -> some View {
        let summary = AgentRendering.summarizeToolInput(name: name, input: input)
        let rows = AgentRendering.fullToolBody(name: name, input: input)
        // The chip's matches, split across the pieces it draws in the
        // order it draws them. `chipTexts` is the same list the find
        // engine counted this row in, so index i here is piece i there.
        let slots = pieceSlots(chipTexts(name: name, input: input, result: result),
                               base: find.slot(forRow: chipId))
        VStack(alignment: .leading, spacing: 4) {
            if showsLabel { agentLabelHeader }
            chipShell(
                chipId: chipId,
                symbol: AgentRendering.toolSymbol(name),
                title: AgentRendering.displayToolName(name),
                summary: summary,
                isError: result?.isError ?? false,
                showsSpinner: result == nil && runner.status.isRunning,
                titleSlot: slots.first ?? .inactive,
                summarySlot: slots.count > 1 ? slots[1] : .inactive
            ) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    toolBodyText(row: row,
                                 slot: slotAt(slots, 2 + index))
                }
                if let result = result {
                    if !rows.isEmpty {
                        Divider().padding(.vertical, 4)
                    }
                    chipResultRows(result, slotOffset: 2 + rows.count, slots: slots)
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

    @ViewBuilder
    private func chipResultRows(_ result: PairedResult,
                                slotOffset: Int = 0,
                                slots: [SearchHighlightSlot] = []) -> some View {
        let rows = AgentRendering.fullToolResultBody(result.output)
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
                                       titleSlot: SearchHighlightSlot = .inactive,
                                       summarySlot: SearchHighlightSlot = .inactive,
                                       @ViewBuilder body: () -> Body) -> some View {
        let expanded = expandedToolResults.contains(chipId)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded { expandedToolResults.remove(chipId) }
                else { expandedToolResults.insert(chipId) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(ChatDesign.textHint)
                        .frame(width: 10)
                    Image(systemName: symbol)
                        .font(.system(size: 11))
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
                            .font(.system(size: 10))
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
                VStack(alignment: .leading, spacing: 1) {
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
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.orange)
            Text(AttributedString.highlighting(message, slot: slot).0)
                .font(.system(size: 12 * fontScale))
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

    private func approvalCard(_ req: MCPApprovalRequest,
                              ownsKeyboardShortcuts: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.orange)
                Text("Permission request",
                     comment: "Approval card title")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ChatDesign.textPrimary)
                Spacer(minLength: 8)
                Text(req.toolName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(ChatDesign.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(ChatDesign.cardBg)
                    )
            }
            if !req.inputPreview.isEmpty {
                Text(req.inputPreview)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(ChatDesign.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(ChatDesign.cardBg.opacity(0.5))
                    )
            }
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        mcpBridge.resolve(requestId: req.id, verdict: .denyAlways)
                    } label: {
                        Text("Deny Always",
                             comment: "Approval card button — remember deny for matching future calls")
                            .font(.system(size: 12))
                            .frame(minWidth: 88)
                    }
                    .modifier(ApprovalButtonHover())
                    Button {
                        mcpBridge.resolve(requestId: req.id, verdict: .allowAlways)
                    } label: {
                        Text("Allow Always",
                             comment: "Approval card button — remember allow for matching future calls")
                            .font(.system(size: 12))
                            .frame(minWidth: 88)
                    }
                    .modifier(ApprovalButtonHover())
                }
                HStack(spacing: 8) {
                    Button {
                        mcpBridge.resolve(requestId: req.id, verdict: .deny)
                    } label: {
                        Text("Deny",
                             comment: "Approval card deny button — one-shot")
                            .font(.system(size: 13, weight: .medium))
                            .frame(minWidth: 88)
                    }
                    .keyboardShortcut(ownsKeyboardShortcuts ? .cancelAction : nil)
                    .modifier(ApprovalButtonHover())
                    Button {
                        mcpBridge.resolve(requestId: req.id, verdict: .allow)
                    } label: {
                        Text("Allow",
                             comment: "Approval card allow button — one-shot")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(minWidth: 88)
                    }
                    .keyboardShortcut(ownsKeyboardShortcuts ? .defaultAction : nil)
                    .buttonStyle(.borderedProminent)
                    .modifier(ApprovalButtonHover())
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                )
        )
    }

    // MARK: - Waiting row

    /// True from the moment a turn is sent until the first thing Claude
    /// actually produces lands — the dead stretch under the user's own
    /// message, where a running clock in the composer is not enough to
    /// stop the page reading as stale.
    ///
    /// Walks back only as far as the turn's own `.userMessage`, so a
    /// second send in an existing session gets the row again rather
    /// than reading the previous turn's output as this turn's.
    /// `systemInit` does NOT count as output: it is the handshake and
    /// lands in milliseconds, so counting it would make the row blink
    /// once and never be seen.
    private var awaitingFirstAgentEvent: Bool {
        guard runner.status.isRunning else { return false }
        for event in runner.events.reversed() {
            switch event.kind {
            case .userMessage: return true
            case .systemInit: continue
            default: return false
            }
        }
        return true
    }

    /// Spinner + "Sipping…", and deliberately NO elapsed time.
    ///
    /// No label above it either: the attribution belongs to the
    /// answer, and putting it over a placeholder makes the wait look
    /// like a message. The label arrives with the first real row
    /// (`MessageBubble`'s header, or `toolPairing.labelled` when a
    /// tool call opens the turn).
    ///
    /// This row is static, appears for one gap per turn, and must stay
    /// that way — a time here would put the 1 Hz whole-transcript
    /// re-render back for the length of every turn. The clock lives in
    /// the composer strip (`TurnClockChip`). Do not put a time back
    /// into it.
    private var waitingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Sipping…",
                     comment: "Spinner shown between the user's message and Claude's first output")
                    .font(.system(size: 13))
                    .foregroundColor(ChatDesign.textSecondary)
                Spacer()
            }
            if runner.turnProducedNothing { stalledNoticeRow }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
    /// `turnProducedNothing` — a full minute of a turn producing
    /// literally nothing.
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
            Text("The turn is still running, but nothing has come back for a minute. This may be fine. However, if it persists for too long, it may indicate a blocked or misconfigured network route, which looks exactly like this because the agent retries in silence — agent CLIs read the HTTP_PROXY and HTTPS_PROXY environment variables and ignore the macOS system proxy setting.",
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
