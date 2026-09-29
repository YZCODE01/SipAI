// AgentManager.swift
// Detects installed agent CLIs and tracks seen/unseen state.

import Foundation
import Combine

struct AgentInfo: Identifiable, Hashable {
    let key: String
    let name: String
    let cmd: String
    /// Session store location relative to the home directory — the
    /// default spelling, for readers that need one; a store alone earns
    /// nothing in the sidebar (see `AgentPresence`).
    let storeDir: String
    var id: String { key }
}

/// Read-through cache of parsed transcripts, one entry per session id.
///
/// A revisit renders synchronously from here — no disk read, no parse,
/// and `MarkdownRenderer`'s cache still warm — which is the whole
/// difference between a session opening instantly and opening after a
/// visible beat.
///
/// Eviction is LEAST-RECENTLY-USED rather than wholesale: a wholesale
/// clear would throw away every other warm transcript to admit one
/// more, making cycling through a handful of sessions cold on every
/// open. Each entry holds the parsed text of up to the reader's byte
/// budget, so the entry ceiling stays deliberately small.
@MainActor
final class AgentHistoryCache {
    struct Entry {
        let items: [AgentSessionHistoryItem]
        let contextTokens: Int
        /// Window the number sits in, when the agent records one
        /// beside it (codex rollout, kimi config joined by model);
        /// 0 = unknown. Cached because a cache hit on an unchanged file
        /// returns before any re-read — without it the chip would lose
        /// its window until the next turn.
        let contextWindow: Int
        /// The model that produced `contextTokens`. Cached for the same
        /// reason as the window, and needed even when the window is
        /// known: claude records no window anywhere, so its window is
        /// resolved from this model.
        let contextModel: String?
        /// The speed that same call ran at ("fast" / "standard") — the
        /// fast switch's outcome as the transcript keeps it; nil when
        /// the record says nothing, and always nil off claude.
        let lastCallSpeed: String?
        /// Seconds the transcript's newest finished turn took — the
        /// cold seed for the composer's turn clock, 0 when unknown.
        let turnDuration: Double
        let commands: [String]
        let fileSize: UInt64
        let fileMtime: Date
        /// Bytes the read covered BEYOND this file — a codex branch's
        /// inherited prefix, read out of its parent (`CodexSessionScanner
        /// .historyExtent`). 0 for every other session. Cached because
        /// the partiality verdict ("Show earlier", the find bar's scope
        /// note) is judged on a cache hit too, and a branch's own file
        /// is tiny.
        let inheritedBytes: UInt64
        /// The Chat only turns the read kept thoughts for
        /// (`ConfigManager.agentChatOnlyTurns`). A turn recorded after
        /// the read — the record lands a beat after the turn's answer —
        /// leaves the entry stale on an unchanged file: that turn's
        /// thoughts were never read, and it would draw as an agent turn.
        let chatOnlyTurns: Set<String>
    }

    private static let capacity = 8

    private var entries: [String: Entry] = [:]
    /// Session ids, least-recently-used first.
    private var useOrder: [String] = []

    func entry(for sessionId: String) -> Entry? {
        guard let found = entries[sessionId] else { return nil }
        touch(sessionId)
        return found
    }

    func store(_ entry: Entry, for sessionId: String) {
        entries[sessionId] = entry
        touch(sessionId)
        while useOrder.count > Self.capacity, let oldest = useOrder.first {
            useOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    /// Strip a derived "Interrupted" marker from a cached transcript.
    /// The marker is a snapshot of "ends mid-thought, nobody writing";
    /// once the session proves otherwise, the cached copy has to
    /// forget it too — a cache hit renders before the refresh read
    /// lands, so a stale marker would flash back on every revisit.
    func dropInterruptedMarker(for sessionId: String) {
        guard let existing = entries[sessionId] else { return }
        let cleaned = existing.items.filter {
            if case .interrupted = $0.kind { return false }
            return true
        }
        guard cleaned.count != existing.items.count else { return }
        entries[sessionId] = Entry(
            items: cleaned,
            contextTokens: existing.contextTokens,
            contextWindow: existing.contextWindow,
            contextModel: existing.contextModel,
            lastCallSpeed: existing.lastCallSpeed,
            turnDuration: existing.turnDuration,
            commands: existing.commands,
            fileSize: existing.fileSize,
            fileMtime: existing.fileMtime,
            inheritedBytes: existing.inheritedBytes,
            chatOnlyTurns: existing.chatOnlyTurns
        )
    }

    private func touch(_ sessionId: String) {
        if let existing = useOrder.firstIndex(of: sessionId) {
            useOrder.remove(at: existing)
        }
        useOrder.append(sessionId)
    }
}

@MainActor
final class AgentManager: ObservableObject {
    /// All known agent CLIs.
    nonisolated static let registry: [AgentInfo] = [
        AgentInfo(key: "claude_code", name: "Claude Code", cmd: "claude",
                  storeDir: ".claude/projects"),
        AgentInfo(key: "codex", name: "Codex", cmd: "codex",
                  storeDir: ".codex/sessions"),
        // Kimi Code's store moves with `KIMI_CODE_HOME`, so `storeDir`
        // is only its default spelling — `storeExists` asks
        // `KimiSessionScanner` instead, which honours the variable.
        AgentInfo(key: "kimi", name: "Kimi Code", cmd: "kimi",
                  storeDir: ".kimi-code/sessions"),
    ]

    /// Agent CLIs detected on this machine (binary found on disk).
    @Published private(set) var installedAgents: [AgentInfo] = []

    /// True if at least one agent CLI is installed on this machine.
    var hasInstalledAgent: Bool {
        !installedAgents.isEmpty
    }

    // MARK: - Presence

    /// What the app may show of each agent — see `AgentPresence`. ONE
    /// derivation (`recomputePresence`) over three inputs owned by
    /// three things: the binary (`reload`), the account verdict (the
    /// usage monitor's file layer, absorbed through `accountsSink`),
    /// and `hidden_agents` (written only through `setHidden`).
    @Published private(set) var presences: [String: AgentPresence] = [:]

    /// The listed agents, in registry order — what every surface reads:
    /// the sidebar's sections, the ADD row, search, the usage coin, the
    /// update rows, the scheduler.
    @Published private(set) var listedAgents: [AgentInfo] = []

    /// The CARRIED verdict per agent (`AgentPresence.carry`): a fresh
    /// `.unknown` keeps the last settled answer. Absent until the first
    /// read completes, which is what `.pending` means.
    private var carriedVerdicts: [String: PlanAccountKind] = [:]
    private var accountsSink: AnyCancellable? = nil
    private var firstReloadDone = false

    /// `.pending` until the first `reload` has run — the frame before
    /// it must draw neither a section nor the ADD row.
    func presence(for key: String) -> AgentPresence {
        presences[key] ?? .pending
    }

    /// Installed, signed in and not hidden — the one question every
    /// "can this agent be driven" site asks.
    func isAgentReady(_ key: String) -> Bool {
        presence(for: key) == .listed
    }

    func isAgentInstalled(_ key: String) -> Bool {
        installedAgents.contains(where: { $0.key == key })
    }

    /// The Guide's checkbox. The one writer of `hidden_agents`; the
    /// consequences follow from `recomputePresence` in the same call.
    func setHidden(_ hidden: Bool, for key: String) {
        guard let config else { return }
        var keys = Set(config.hiddenAgents)
        if hidden { keys.insert(key) } else { keys.remove(key) }
        config.setHiddenAgents(Array(keys))
        recomputePresence()
    }

    /// Re-run detection with the config the manager was configured
    /// with — the Guide's actions call this the moment an install, a
    /// delete or a sign-in lands rather than waiting for the tick.
    func reloadNow() {
        guard let config else { return }
        reload(config: config)
    }

    /// The agent's name as the user set it (Settings → Labels), else its
    /// default — for a sentence written where no view holds the config
    /// (the scheduler's run records). The same rule every user-visible
    /// sentence follows: no agent named outright.
    func agentLabel(for key: String) -> String {
        let name = Self.registry.first { $0.key == key }?.name ?? key
        return config?.agentLabel(for: key, defaultName: name) ?? name
    }

    private func absorbAccounts(_ accounts: [String: PlanAccountKind]) {
        for (key, fresh) in accounts {
            carriedVerdicts[key] = AgentPresence.carry(previous: carriedVerdicts[key], fresh: fresh)
        }
        recomputePresence()
    }

    /// The derivation. Publishes only on change; feeds the two other
    /// monitors the facts they need (the shown set, the hidden set).
    func recomputePresence() {
        let hidden = Set(config?.hiddenAgents ?? [])
        var next: [String: AgentPresence] = [:]
        for agent in Self.registry {
            next[agent.key] = AgentPresence.resolve(
                installed: isAgentInstalled(agent.key),
                verdict: carriedVerdicts[agent.key],
                hidden: hidden.contains(agent.key))
        }
        if next != presences { presences = next }
        let listed = Self.registry.filter { next[$0.key] == .listed }
        if listed != listedAgents { listedAgents = listed }
        UsageMonitor.shared.setShown(Set(listed.map(\.key)))
        AgentCLIUpdateMonitor.shared.setHiddenAgents(
            Set(Self.registry.map(\.key).filter { next[$0] == .hiddenByUser }))
    }

    /// Agent sessions discovered under `~/.claude/projects`, sorted newest-first.
    /// Empty until `reloadSessions` completes at least once.
    @Published private(set) var sessions: [AgentSession] = [] {
        didSet { knownSessionIds = Set(sessions.map(\.id)) }
    }

    /// Every listed session's id — what the agent composer draws on a
    /// grey token (`SessionIdTokens`). Kept beside `sessions` rather than
    /// derived where it is read: the composer hands it to its text view
    /// on every keystroke. Not published on its own; it changes only
    /// with `sessions`, which is.
    private(set) var knownSessionIds: Set<String> = []

    /// Scheduled task definitions joined to their discovered run sessions.
    /// Includes task folders that have never run.
    @Published private(set) var scheduledTasks: [ScheduledAgentTask] = []

    /// Sessions that are not runs of a scheduled task. The sidebar applies
    /// its display cap to this derived list while `sessions` retains every
    /// run for center-pane lookup and resume behavior. Empty shells —
    /// `/clear`-orphan files with no conversation at all — are hidden
    /// from the sidebar entirely, but stay in `sessions` so nothing
    /// else loses resolution.
    var regularSessions: [AgentSession] {
        sessions.filter { $0.scheduledTaskName == nil && !$0.isEmptyShell }
    }

    /// One provider's slice of `regularSessions` — each sidebar section
    /// lists its own agent.
    func regularSessions(for agentKey: String) -> [AgentSession] {
        regularSessions.filter { $0.agentKey == agentKey }
    }

    func scheduledTasks(for agentKey: String) -> [ScheduledAgentTask] {
        scheduledTasks.filter { $0.agent == agentKey }
    }

    /// True while a scan is in flight. Views use this to render a spinner.
    @Published private(set) var isScanning: Bool = false

    /// Monotonic id of the newest `reloadSessions` call. Scans run
    /// detached and can finish out of order — without this guard, an
    /// older scan completing last would resurrect a just-deleted
    /// session (and its sidebar group) until the next reload.
    private var scanGeneration: Int = 0

    /// Sessions (or drafts) currently mid-subprocess. Key shape:
    ///   - "draft:<UUID>" while a draft is sending its first message
    ///   - "<session_id>" once the session has been spawned at least once
    /// Written by AgentRunner's `onStatusChange` callback. The sidebar
    /// activity dot and any future cross-session queries read this.
    @Published private(set) var inFlightSends: [String: String] = [:]

    /// Session ids whose JSONL is currently being appended to by an
    /// *external* Claude Code process — another terminal, a scheduled
    /// task, a second SipAI instance. Written by AgentRunner's
    /// `onExternalInProgressChange` callback. Drafts never appear here
    /// (their JSONL doesn't exist until after system.init). The sidebar
    /// activity dot is shown when a session id is in either this set
    /// OR `inFlightSends`.
    @Published private(set) var externalInFlightSessions: Set<String> = []

    // MARK: - Unread runs and the open session

    /// The session the centre pane shows, as ContentView reports it
    /// (`noteOpenSession`) — nil for a chat, a note, a draft, a task
    /// page with no runs. A run that ends while its session is open
    /// leaves no steady dot: the user is looking at it.
    private(set) var openSessionId: String? = nil

    /// The tier the open session stood in when it was opened, raised if
    /// it has run since. Its sidebar place is held there until the user
    /// opens anything else — see `SidebarTier.placed`.
    @Published private(set) var openSessionHeldTier: SidebarTier? = nil

    /// Called whenever the centre pane's session changes. Opening a
    /// session is what reads it: its unread mark goes, and its place is
    /// held at the tier it had a moment ago.
    func noteOpenSession(_ id: String?) {
        guard id != openSessionId else { return }
        openSessionId = id
        guard let id, !id.isEmpty else {
            openSessionHeldTier = nil
            return
        }
        // Read BEFORE the clear, or an unread session would be held at
        // the tier it has only because it was just opened.
        openSessionHeldTier = actualTier(forSession: id)
        config?.clearAgentSessionUnread([id])
    }

    func isSessionRunning(_ id: String) -> Bool {
        inFlightSends[id] != nil || externalInFlightSessions.contains(id)
    }

    func isSessionUnread(_ id: String) -> Bool {
        config?.agentUnreadSessions.contains(id) ?? false
    }

    /// What is true of a session now — the tier its DOT follows.
    func actualTier(forSession id: String) -> SidebarTier {
        SidebarTier.of(running: isSessionRunning(id), unread: isSessionUnread(id))
    }

    /// Where a session is PLACED: its actual tier, or for the open
    /// session the better of that and the one it is held at.
    func sidebarTier(forSession id: String) -> SidebarTier {
        SidebarTier.placed(actualTier(forSession: id),
                           heldSinceOpened: id == openSessionId ? openSessionHeldTier : nil)
    }

    /// A run of the open session started: its place may rise, and is
    /// then held there until the user moves on.
    private func noteRunStarted(sessionId id: String) {
        guard !id.isEmpty, id == openSessionId else { return }
        openSessionHeldTier = .running
    }

    /// A run of `sessionId` just ended. It leaves the steady dot unless
    /// the user is looking at the session — by its id, or through the
    /// draft it is still becoming — or ended the run themselves (Stop,
    /// or quitting SipAI; the composer's Stop on a turn another process
    /// ran) — or the run never got a session id, which leaves nothing
    /// to open.
    private func noteRunEnded(sessionId id: String, stoppedByUser: Bool) {
        guard !id.isEmpty, !id.hasPrefix("draft:"), !stoppedByUser,
              id != openSessionId, !isOpenDraftsSession(id) else { return }
        config?.markAgentSessionUnread(id)
    }

    /// The draft the centre pane shows, as ContentView reports it
    /// (`noteOpenDraft`). Its first turn runs under `draft:<id>` and is
    /// migrated to its session id at `system.init`, but the pane flips
    /// to that id only when the transcript file lands, a beat later
    /// (`AgentRunner.awaitSessionFile`) — and a turn that ends inside
    /// that beat (a local slash command answers in milliseconds) is one
    /// the user is looking at. The draft key stays an alias of the
    /// runner until the flip (`releaseDraftRunner`), which is what makes
    /// the session it became answerable here.
    private var openDraftKey: String? = nil

    func noteOpenDraft(_ id: UUID?) {
        openDraftKey = id.map { "draft:\($0.uuidString)" }
    }

    private func isOpenDraftsSession(_ id: String) -> Bool {
        guard let key = openDraftKey, let runner = runners[key] else { return false }
        return runner.key == id
    }

    /// Per-session runner cache. Key is `"draft:<UUID>"` before a
    /// draft's first system.init event is seen, `"<session_id>"`
    /// thereafter. Exactly one runner per key.
    ///
    /// Deliberately NOT `@Published`, for the same reason as
    /// `historyCache` below and one more that is a correctness rule:
    /// `runner(forSessionId:)` populates this lazily, and its caller
    /// `AgentSessionView.currentRunner` is a computed property read
    /// from `body`. Publishing the insert would mutate observed state
    /// DURING view evaluation — SwiftUI's "Publishing changes from
    /// within view updates is not allowed" undefined behavior — once
    /// per session whose runner isn't cached yet. (The draft path
    /// likewise reads the cache without creating, via
    /// `cachedRunner(forDraft:)`.)
    ///
    /// Nothing renders off this dictionary, which is what makes the
    /// plain `var` correct rather than merely quieter: the only
    /// readers outside this class are the AppKit quit delegate
    /// (`SipAIApp.applicationShouldTerminate`), and views take session
    /// liveness from `inFlightSends` / `externalInFlightSessions` —
    /// published separately for exactly this reason. A view that needs
    /// ONE runner observes that runner (`RunnerStreamView`), never the
    /// collection holding it.
    private(set) var runners: [String: AgentRunner] = [:]

    /// A turn of this agent in flight, ours or another terminal's — what
    /// an update of its binary waits for, from the Update button and
    /// the automatic update alike. An external turn is attributed
    /// through the session it is writing to; the set is empty or tiny.
    func hasTurnInFlight(agentKey: String) -> Bool {
        if runners.values.contains(where: { $0.agentKey == agentKey && $0.status.isRunning }) {
            return true
        }
        return externalInFlightSessions.contains { id in
            sessions.first(where: { $0.id == id })?.agentKey == agentKey
        }
    }

    /// Parsed transcript history, keyed by session id. Deliberately NOT
    /// `@Published` — it is a read-through cache for one view, and
    /// publishing it would re-render the sidebar on every session open.
    /// Lives here rather than on `AgentSessionView` because the center
    /// pane tears that view down on any detour to a chat or a note.
    let historyCache = AgentHistoryCache()

    /// Weak reference to the process-wide MCP bridge. Set once from
    /// `SipAIApp.onAppear` via `configure(bridge:config:)` before any
    /// runner is created. `AgentRunner` reads this on first send to obtain
    /// its MCP args + env overlay. Weak to avoid retain cycles — the
    /// bridge is owned by `SipAIApp`'s `@StateObject`.
    private weak var mcpBridge: MCPBridge?

    /// Weak reference to the app's config, for the one thing this
    /// manager writes: a draft's custom-group filing, at the moment the
    /// session id arrives (`migrateRunner`). Weak for the same reason
    /// as the bridge — both are `@StateObject`s owned by `SipAIApp`.
    private weak var config: ConfigManager?

    func configure(bridge: MCPBridge, config: ConfigManager) {
        mcpBridge = bridge
        self.config = config
    }

    /// Stop every turn THIS app is running, the way the Stop button and
    /// an explicit quit do: SIGTERM, SIGKILL if ignored, pending
    /// approval cards force-denied, one `.interrupted` row per turn.
    ///
    /// Used by the factory reset. A wipe must not leave our own
    /// subprocesses streaming into a transcript — or raising approval
    /// cards over an app that has been put back to onboarding. The
    /// SESSIONS are untouched: they live in the agent CLI's own store,
    /// and a stopped turn simply shows the usual derived "Interrupted"
    /// marker next time it is opened.
    ///
    /// `cancel()` no-ops on an idle runner, but filtering first keeps
    /// this from stamping "Interrupted" onto turns that already ended.
    func stopAllRunningTurns() {
        for runner in runners.values where runner.status.isRunning {
            runner.cancel()
        }
    }

    // MARK: - Runner factories

    /// The already-created runner for a draft, if its first send has
    /// happened. Never creates one — the draft composer calls this so
    /// a not-yet-sent draft keeps its cwd editable (the runner captures
    /// cwd at creation, so creating it on first render would freeze the
    /// folder choice).
    func cachedRunner(forDraft draft: ClaudeSessionDraft) -> AgentRunner? {
        runners["draft:\(draft.id.uuidString)"]
    }

    /// Drop the draft-key alias left behind by `migrateRunner`. Called
    /// by AgentSessionView after it has flipped AppState routing from
    /// the draft to the discovered session id; the runner stays cached
    /// under that session id.
    func releaseDraftRunner(draftId: UUID) {
        let key = "draft:\(draftId.uuidString)"
        guard let runner = runners[key], runner.key != key else { return }
        runners.removeValue(forKey: key)
    }

    /// Resolve (or create) the runner for a draft. The runner
    /// inherits the draft's cwd + display name; its key is
    /// `"draft:<UUID>"` until the first send migrates it.
    // MARK: - Kimi tool-policy heal

    /// Put back any kimi session's `tool-policy/state.json` that a Chat
    /// only turn wrote and never restored — a crash, a force-quit, a
    /// kill mid-turn. Read from the journal config keeps
    /// (`kimiToolPolicyRestores`), applied for every session that has
    /// no turn of ours in flight, and cleared as it lands. Called at
    /// launch (`sessionId` nil: every entry) and on session open (that
    /// session's entry alone). A session left with its tools switched
    /// off would stay that way in the user's terminal too, which is why
    /// this exists.
    func healKimiToolPolicies(sessionId only: String? = nil) {
        guard let config else { return }
        let journal = config.kimiToolPolicyRestores()
        for (id, record) in journal {
            if let only, only != id { continue }
            // A turn of ours on this session is the one that will
            // restore it; healing underneath it would put the tools
            // back mid-turn.
            if let runner = runners[id], runner.status.isRunning { continue }
            guard let dir = KimiSessionScanner.sessionDirectory(forId: id) else {
                // The session is gone — nothing to restore into.
                config.clearKimiToolPolicyRestore(for: id)
                continue
            }
            let file = KimiToolPolicy.disabledFile(sessionDir: dir)
            do {
                try KimiToolPolicy.restore(record, at: file)
                config.clearKimiToolPolicyRestore(for: id)
            } catch {
                NSLog("%@", "SipAI: could not restore \(file.path): \(error.localizedDescription)")
            }
        }
    }

    func runner(forDraft draft: ClaudeSessionDraft) -> AgentRunner {
        let key = "draft:\(draft.id.uuidString)"
        if let existing = runners[key] { return existing }
        let runner = AgentRunner(
            key: key,
            cwd: draft.cwd,
            sessionId: nil,
            initialName: draft.name,
            bridge: mcpBridge,
            agentKey: draft.agentKey
        )
        wireCallbacks(on: runner, forDraft: draft)
        runners[key] = runner
        return runner
    }

    /// Resolve (or create) the runner for an existing session, keyed by
    /// session id. Used by AgentSessionView even when AppState's routing
    /// has a session id + file URL but `sessions` hasn't caught up yet
    /// (the draft→existing transition's tiny window before the async
    /// `reloadSessions()` finishes).
    ///
    /// `agentKey` names the CLI that owns the session, and every
    /// agent-shaped decision (argv, stdout schema, whether the live
    /// JSONL tailer applies) is the runner's to make from it — callers
    /// no longer pass those in one at a time.
    func runner(forSessionId id: String, fileURL: URL, cwd: URL,
                agentKey: String = "claude_code") -> AgentRunner {
        if let existing = runners[id] { return existing }
        let runner = AgentRunner(
            key: id,
            cwd: cwd,
            sessionId: id,
            sessionFileURL: fileURL,
            initialName: nil,
            bridge: mcpBridge,
            agentKey: agentKey
        )
        wireCallbacks(on: runner, forDraft: nil)
        runners[id] = runner
        return runner
    }

    // MARK: - Runner callbacks

    private func wireCallbacks(on runner: AgentRunner,
                               forDraft draft: ClaudeSessionDraft?) {
        runner.onStatusChange = { [weak self, weak runner] key, status in
            // Called on the MainActor (runner is @MainActor).
            guard let self = self else { return }
            if status.isRunning {
                self.inFlightSends[key] = UUID().uuidString
                // A turn starting IS a user message being sent —
                // whether the sender was the composer or the scheduler
                // (scheduled runs go through this same path). Stamp
                // now rather than waiting for the scan on turn end: a
                // row that only rises to the top of its group once the
                // agent has finished answers the wrong question, and
                // "finished" can be an hour later.
                self.stampUserMessage(sessionId: runner?.sessionId ?? key)
                self.noteRunStarted(sessionId: runner?.sessionId ?? key)
            } else if self.inFlightSends.removeValue(forKey: key) != nil {
                // A turn just ENDED (there was an in-flight token to
                // clear — a plain `.idle` assignment is not a turn).
                self.noteRunEnded(sessionId: runner?.sessionId ?? key,
                                  stoppedByUser: runner?.turnWasStoppedByUser ?? false)
                // The session's file mtime moved, and that timestamp is
                // on screen: the composer's scheduled-run tag and every
                // sidebar row's relative time. `sessions` is only
                // rebuilt by an explicit rescan, so without this the tag
                // kept showing the PREVIOUS turn's finish time until
                // something unrelated forced a reload.
                self.reloadSessions()
            }
        }
        runner.onSessionIdDiscovered = { [weak self, weak runner] sessionId, fileURL in
            guard let self = self, let runner = runner else { return }
            self.migrateRunner(runner: runner,
                               newSessionId: sessionId,
                               fileURL: fileURL,
                               draft: draft)
        }
        runner.onKimiToolPolicyJournal = { [weak self] sessionId, record in
            guard let config = self?.config else { return }
            if let record {
                config.setKimiToolPolicyRestore(record, for: sessionId)
            } else {
                config.clearKimiToolPolicyRestore(for: sessionId)
            }
        }
        runner.onChatOnlyTurnRecorded = { [weak self] sessionId, handle in
            self?.config?.noteAgentChatOnlyTurn(handle, for: sessionId)
        }
        runner.agentLabelProvider = { [weak self, weak runner] in
            guard let runner else { return "" }
            let fallback = AgentManager.registry
                .first { $0.key == runner.agentKey }?.name ?? runner.agentKey
            return self?.config?.agentLabel(for: runner.agentKey,
                                            defaultName: fallback) ?? fallback
        }
        runner.onExternalInProgressChange = { [weak self, weak runner] sessionId, inProgress in
            guard let self = self else { return }
            if inProgress {
                self.externalInFlightSessions.insert(sessionId)
                // Someone typed into this session from another
                // terminal. Approximate (the tailer notices within a
                // flush interval, and only for sessions this app has
                // a runner for), and deliberately so: the next scan
                // reads the record's own stamp off disk and replaces
                // it. Sessions with no runner simply wait for that
                // scan — there is no watcher on every file.
                self.stampUserMessage(sessionId: sessionId)
                self.noteRunStarted(sessionId: sessionId)
            } else if self.externalInFlightSessions.remove(sessionId) != nil {
                // A turn another process ran has ended — the same
                // steady dot as one of ours, and the same exemption for
                // one the user stopped: the composer's Stop on an
                // orphaned headless claude ends its turn through the
                // tailer's sweep, seconds after the click, by when the
                // user may have moved on.
                self.noteRunEnded(sessionId: sessionId,
                                  stoppedByUser: runner?.externalTurnWasStoppedByUser ?? false)
            }
        }
    }

    // MARK: - Filing a new session into a custom group

    /// File a session the app just created into a custom group — a
    /// draft started from a group's +, or a branch of a session that
    /// sits in one. The caller decides the group; this writes it, and
    /// it is the ONLY writer on either route, so the two cannot drift.
    ///
    /// Membership is tested per AGENT at the moment of writing: a group
    /// deleted (or renamed, which is the same thing — groups are keyed
    /// by name) between the decision and the write leaves the session
    /// simply unfiled, where writing anyway would leave config pointing
    /// at a group that no longer exists.
    ///
    /// Must run BEFORE the placeholder row is inserted, on both routes
    /// that insert one. The insert re-renders the sidebar at once;
    /// filed after, the row appears under Ungrouped and then jumps.
    private func fileSession(_ id: String, inGroup group: String?,
                             agentKey: String) {
        guard let group, let config = self.config,
              config.agentCustomGroups(for: agentKey).contains(group)
        else { return }
        config.setAgentSessionGroup(group, for: id)
    }

    // MARK: - Draft → existing migration

    /// Called on the MainActor when a draft runner's first turn
    /// emits a system.init event. Moves the runner under its new
    /// session-id key, migrates inFlightSends, persists the custom
    /// display name (if any), and injects a placeholder row into
    /// `sessions` so the view can resolve the new session immediately
    /// while the async disk scan catches up.
    private func migrateRunner(runner: AgentRunner,
                               newSessionId: String,
                               fileURL: URL?,
                               draft: ClaudeSessionDraft?) {
        let oldKey = runner.key
        guard oldKey != newSessionId else { return }

        // The old draft key stays in the dict as an alias to the same
        // runner. Dropping it here would strand the open draft view:
        // its next render resolves the draft key, finds nothing, and
        // would either lose the live stream or spin up a fresh runner —
        // and `currentRunner?.sessionId` would read nil, so the
        // draft→existing AppState flip in AgentSessionView could never
        // fire. The view removes the alias via `releaseDraftRunner`
        // once it has flipped.
        runner.key = newSessionId
        runners[newSessionId] = runner

        // Migrate inFlightSends if we had a token under the old key.
        if let token = inFlightSends.removeValue(forKey: oldKey) {
            inFlightSends[newSessionId] = token
        }

        // A draft started from a custom group's + is filed the instant
        // it HAS a key to file under — a draft has no session id, and
        // the send happens under one no session will ever have.
        //
        // Here rather than in the view's own discovery handler: the
        // centre pane is torn down by any detour to a chat or a note,
        // so a filing addressed to the view is lost exactly when the
        // user starts a turn and looks at something else; this runs
        // from the runner's callback with the draft captured, whether
        // or not a view is alive. Before the placeholder — see
        // `fileSession`.
        fileSession(newSessionId, inGroup: draft?.customGroup,
                    agentKey: runner.agentKey)

        // A run the scheduler started belongs to its task from now on,
        // not from the scan that first reads its marker off disk — the
        // transcript is written a beat after the id arrives, and until a
        // scan has read it the row would sit among the ordinary sessions
        // and only move into its task at the turn's end.
        if let run = draft?.scheduledRun {
            liveScheduledRuns[newSessionId] = ScheduledAgentTaskScanner.LiveScheduledRun(
                taskName: run.taskName, title: run.title, startedAt: Date())
        }

        // Inject a placeholder session so the view can resolve it
        // synchronously; the async reloadSessions() below will
        // replace the placeholder with the real parsed row.
        if !sessions.contains(where: { $0.id == newSessionId }) {
            let placeholderTitle = draft?.scheduledRun?.title ?? draft?.name ?? String(
                localized: "New session",
                comment: "Placeholder title for a just-migrated session before JSONL parse")
            var placeholder = AgentSession(
                id: newSessionId,
                fileURL: fileURL ?? SipaiPaths.dataDir
                    .appendingPathComponent("\(Self.unresolvedPlaceholderPrefix)\(newSessionId).jsonl"),
                title: placeholderTitle,
                modifiedAt: Date(),
                projectPath: runner.cwd,
                scheduledTaskName: draft?.scheduledRun?.taskName,
                // Without this a codex draft's placeholder row files
                // itself under the Claude section until the next scan
                // corrects it — the row visibly jumps sections.
                agentKey: runner.agentKey
            )
            if placeholder.scheduledTaskName != nil { placeholder.origin = .scheduled }
            sessions.insert(placeholder, at: 0)
        }
        // Among its task's runs too, before the stamp below re-sorts them.
        // No scan has spoken here, so nothing counts as filed by the disk.
        let filed = filingLiveScheduledRuns(sessions: sessions, tasks: scheduledTasks,
                                            diskFiled: [])
        sessions = filed.sessions
        scheduledTasks = filed.tasks
        // The send that revealed this id happened under the DRAFT key,
        // so the stamp `onStatusChange` recorded is filed under a name
        // no session will ever have. Re-file it now that the session
        // has one, and the first turn orders like every later one.
        stampUserMessage(sessionId: newSessionId)

        reloadSessions()
    }

    // MARK: - Branches

    /// Adopt a session a branch just created (`AgentSessionFork`,
    /// `CodexSessionFork`, `KimiSessionFork`) and hand back its runner,
    /// ready to send.
    ///
    /// Same shape as `migrateRunner`'s placeholder injection, and for the
    /// same two reasons — one cosmetic, one a correctness trap:
    ///
    ///  * The row has to be in `sessions` NOW. The user pressed a button;
    ///    the branch appearing in the sidebar a rescan later reads as
    ///    nothing having happened.
    ///  * `AgentSessionView.SessionMode.existing` resolves a session's
    ///    cwd by looking it up in `sessions`, falling back to `$HOME`
    ///    when it is not there yet — and `AgentRunner` captures its cwd
    ///    at init and is cached forever after. Routing to a session the
    ///    scan has not seen would therefore pin the branch's subprocess
    ///    to the home folder permanently. Creating the runner HERE, with
    ///    the cwd handed in, closes that window whatever the scan does.
    ///
    /// `agentKey` rides both: the placeholder row files itself under
    /// that agent's section (defaulted, a codex branch sat under the
    /// Claude section until the next scan moved it — the row visibly
    /// jumping), and the runner spawns that agent's CLI.
    ///
    /// `customGroup` is the group the branch belongs in — its parent's,
    /// decided by the caller — and is written here, before the row,
    /// for the reasons on `fileSession`. Without it a branch is only
    /// half where its parent is: it keeps the parent's working folder,
    /// so Folder grouping looks right, and lands under Ungrouped in
    /// Custom.
    @discardableResult
    func registerBranchedSession(id: String, fileURL: URL, cwd: URL,
                                 title: String, agentKey: String,
                                 customGroup: String? = nil) -> AgentRunner {
        fileSession(id, inGroup: customGroup, agentKey: agentKey)
        if !sessions.contains(where: { $0.id == id }) {
            var placeholder = AgentSession(
                id: id,
                fileURL: fileURL,
                title: title,
                modifiedAt: Date(),
                projectPath: cwd,
                scheduledTaskName: nil,
                agentKey: agentKey
            )
            // A branch is born at the top of the list: the user just
            // sent into it. Without this the row sorts on `modifiedAt`
            // of a file whose newest record was copied from the parent's
            // history, and it would land wherever that turn happened.
            placeholder.lastUserMessageAt = Date()
            sessions.insert(placeholder, at: 0)
        }
        stampUserMessage(sessionId: id)
        let runner = runner(forSessionId: id, fileURL: fileURL, cwd: cwd,
                            agentKey: agentKey)
        reloadSessions()
        return runner
    }

    /// Refresh detection. Call on app launch and when returning to main view.
    func reload(config: ConfigManager) {
        if self.config == nil { self.config = config }
        var installed: [AgentInfo] = []
        // A tool SipAI is updating stays installed while its binary is
        // missing mid-update (`AgentCLIUpdateRules.countsAsInstalled`):
        // judged on the binary alone, an npm update took the section
        // away — and with it any open page and the scheduler's runs —
        // for the whole download.
        let updates = AgentCLIUpdateMonitor.shared
        for agent in Self.registry where AgentCLIUpdateRules.countsAsInstalled(
            binaryFound: Self.isInstalled(agent.cmd),
            updating: updates.isUpdating(agent.key)) {
            installed.append(agent)
        }
        // Assign only on change — this also runs from the 5 s
        // re-detection tick, and identical reassignment would trigger a
        // needless sidebar re-render every cycle.
        if installedAgents != installed {
            // A binary that went takes its verdict with it, so a
            // reinstall starts from a fresh read rather than the old
            // answer.
            let gone = Set(Self.registry.map(\.key)).subtracting(installed.map(\.key))
            for key in gone { carriedVerdicts[key] = nil }
            installedAgents = installed
        }
        if accountsSink == nil {
            // ASYNCHRONOUS on purpose. `@Published` emits from `willSet`,
            // and a synchronous sink would run `recomputePresence` —
            // which feeds the monitor's shown set, which calls the
            // monitor's `recompute` — INSIDE the monitor's own
            // `accounts = next` assignment: a nested recompute over the
            // half-assigned value, and the same value published twice.
            // The launch pass does not wait for this: it PULLS below.
            accountsSink = UsageMonitor.shared.$accounts
                .receive(on: DispatchQueue.main)
                .sink { [weak self] accounts in self?.absorbAccounts(accounts) }
        }
        // The account verdict — the file layer the usage coin reads —
        // is what decides "signed in". The FIRST pass reads it NOW so
        // the first frame the sidebar draws already knows; every later
        // tick reads detached and publishes only on a changed digest.
        // Every INSTALLED agent is read, listed or not: skipping an
        // unlisted one would mean it could never be listed again.
        if !firstReloadDone {
            firstReloadDone = true
            UsageMonitor.shared.readAccountsNow(installed: installed)
        } else {
            UsageMonitor.shared.refreshAccounts(installed: installed)
        }
        // The pull: whatever the monitor holds right now (the launch
        // read just landed; a probe verdict from the Guide too) decides
        // presence in this same call, not a run-loop turn later.
        absorbAccounts(UsageMonitor.shared.accounts)
    }

    /// Re-check CLI availability every few seconds so installing an
    /// agent CLI while the app is open flips its section from read-only
    /// to interactive without a relaunch.
    private var detectionTimer: Timer?

    func startDetectionRechecks(config: ConfigManager) {
        guard detectionTimer == nil else { return }
        detectionTimer = Timer.scheduledTimer(
            withTimeInterval: 5.0, repeats: true
        ) { [weak self, weak config] _ in
            Task { @MainActor [weak self, weak config] in
                guard let self = self, let config = config else { return }
                self.reload(config: config)
            }
        }
    }

    // MARK: - Sessions

    /// Re-scan `~/.claude/projects` and scheduled-task definitions. Disk work
    /// runs on a detached task so the UI stays responsive; all sessions are
    /// retained because scheduled runs may be older than the sidebar's
    /// regular-session display limit.
    func reloadSessions() {
        isScanning = true
        scanGeneration += 1
        let generation = scanGeneration
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                // Every store, one merged newest-first list; each row is
                // tagged with its agent so the sidebar sections and the
                // history readers can split them back apart.
                var sessions = AgentSessionScanner.scan()
                sessions.append(contentsOf: CodexSessionScanner.scan())
                sessions.append(contentsOf: KimiSessionScanner.scan())
                // Same key the sidebar orders by, so the merged list is
                // already in display order — see `AgentSession.activityAt`.
                sessions.sort { $0.activityAt > $1.activityAt }
                let scheduledTasks = ScheduledAgentTaskScanner.scan(grouping: sessions)
                return (sessions: sessions, scheduledTasks: scheduledTasks)
            }.value
            guard let self = self, generation == self.scanGeneration else { return }
            // Stamps first: a scan that lands between the send and
            // claude flushing the user record would otherwise hand back
            // a row dated BEFORE the message the user just watched
            // themselves send, and drop it back down the list.
            // What the transcripts themselves said, read BEFORE any
            // placeholder joins the list: only that retires a live run.
            let diskFiled = Set(result.sessions
                .filter { $0.scheduledTaskName != nil }.map(\.id))
            let filed = self.filingLiveScheduledRuns(
                sessions: self.preservingLiveSessions(
                    self.applyingPendingStamps(result.sessions)),
                tasks: self.applyingPendingStamps(tasks: result.scheduledTasks),
                diskFiled: diskFiled)
            // A delete still under way: its rows stay off the lists
            // until its files are gone (see `delete(_:task:)`).
            let deleting = self.deletingSessionIds
            self.sessions = deleting.isEmpty ? filed.sessions
                : filed.sessions.filter { !deleting.contains($0.id) }
            self.scheduledTasks = deleting.isEmpty && self.deletingTaskNames.isEmpty
                ? filed.tasks
                : Self.leaving(filed.tasks, sessionIds: deleting,
                               taskNames: self.deletingTaskNames)
            self.isScanning = false
        }
    }

    /// The composer has just written a scheduled task. List it NOW — at
    /// the top of its group, which is where its creation date sorts it
    /// (`ScheduledAgentTask.lastActive`) — and rescan for the rest.
    ///
    /// The rescan walks every agent's store and can take a moment on a
    /// large one; without this the task appears only when it lands. A
    /// scan that finishes first already holds the task and is kept.
    func noteScheduledTaskCreated(named name: String) {
        reloadSessions()
        Task { [weak self] in
            let task = await Task.detached(priority: .userInitiated) {
                ScheduledAgentTaskScanner.newTask(named: name)
            }.value
            guard let self, let task,
                  !self.scheduledTasks.contains(where: { $0.name == name })
            else { return }
            self.scheduledTasks.append(task)
        }
    }

    // MARK: - Scheduled runs in flight

    /// Runs the scheduler started whose transcripts may not name their
    /// task yet, keyed by session id. Written by `migrateRunner`, pruned
    /// by `filingLiveScheduledRuns` — an entry lives only until the disk
    /// says the same thing, like `pendingUserStamps`.
    private var liveScheduledRuns: [String: ScheduledAgentTaskScanner.LiveScheduledRun] = [:]

    /// File every run in `liveScheduledRuns` under its task in the given
    /// lists (`ScheduledAgentTaskScanner.overlaying`, the pure rule) and
    /// retire the entries the disk has caught up with — `diskFiled`, the
    /// ids a scan read a task marker for.
    private func filingLiveScheduledRuns(sessions: [AgentSession],
                                         tasks: [ScheduledAgentTask],
                                         diskFiled: Set<String>)
    -> (sessions: [AgentSession], tasks: [ScheduledAgentTask]) {
        guard !liveScheduledRuns.isEmpty else { return (sessions, tasks) }
        var running: Set<String> = []
        for runner in runners.values where runner.status.isRunning {
            if let id = runner.sessionId, !id.isEmpty { running.insert(id) }
        }
        let result = ScheduledAgentTaskScanner.overlaying(
            liveScheduledRuns, sessions: sessions, tasks: tasks,
            diskFiled: diskFiled, running: running, now: Date())
        liveScheduledRuns = result.runs
        return (result.sessions, result.tasks)
    }

    // MARK: - User-message stamps

    /// Stamps applied ahead of the disk, keyed by session id. An entry
    /// exists only while the transcript has not caught up: as soon as a
    /// scan reports a user-message time at or past the stamp, the
    /// override is dropped (see `preservingLiveSessions`), so the disk
    /// is always the eventual authority and nothing can pin a row to a
    /// value the file disagrees with forever.
    private var pendingUserStamps: [String: Date] = [:]

    /// Record that the user (or the scheduler) just sent a message into
    /// `sessionId`, and re-order immediately.
    ///
    /// The sidebar's whole ordering is `AgentListItem.activityDate`,
    /// sorted before bucketing, so moving this one value is what makes
    /// the row jump to the top of its group in every grouping mode —
    /// no group-specific code, and no rescan to wait for. Unknown ids
    /// (a draft's first send, before `migrateRunner` injects its row)
    /// are recorded anyway: that row arrives with `modifiedAt` of the
    /// same instant, and the stamp is there for the scan that follows.
    func stampUserMessage(sessionId: String, at date: Date = Date()) {
        guard !sessionId.isEmpty else { return }
        pendingUserStamps[sessionId] = date
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[idx].lastUserMessageAt = date
            sessions.sort { $0.activityAt > $1.activityAt }
        }
        // A scheduled run is ALSO a row in its task's `sessions`, and
        // the task's own timestamp reads `sessions.first`. Without
        // this the run rose in the session list while its task sat
        // where it was.
        for i in scheduledTasks.indices {
            guard let j = scheduledTasks[i].sessions
                .firstIndex(where: { $0.id == sessionId }) else { continue }
            scheduledTasks[i].sessions[j].lastUserMessageAt = date
            scheduledTasks[i].sessions.sort { $0.activityAt > $1.activityAt }
            break
        }
    }

    /// Overlay `pendingUserStamps` onto a fresh scan, and retire every
    /// entry the transcript has caught up with.
    ///
    /// The disk is the authority; this only covers the gap before it
    /// becomes one. An entry survives exactly as long as the file
    /// disagrees with it, so nothing here can hold a row at a time the
    /// transcript never recorded.
    private func applyingPendingStamps(_ scanned: [AgentSession])
    -> [AgentSession] {
        guard !pendingUserStamps.isEmpty else { return scanned }
        var out = scanned
        for i in out.indices {
            guard let stamp = pendingUserStamps[out[i].id] else { continue }
            if let onDisk = out[i].lastUserMessageAt, onDisk >= stamp {
                pendingUserStamps.removeValue(forKey: out[i].id)
            } else {
                out[i].lastUserMessageAt = stamp
            }
        }
        // Entries this scan does not name at all are a draft key (never
        // a real session id) or a deleted session — except in the first
        // seconds, where a just-spawned session legitimately may not be
        // on disk yet. Bounds the map without a timer.
        let known = Set(out.map(\.id))
        let now = Date()
        pendingUserStamps = pendingUserStamps.filter { id, at in
            known.contains(id) || now.timeIntervalSince(at) < 60
        }
        out.sort { $0.activityAt > $1.activityAt }
        return out
    }

    /// The same overlay for a task's runs, so a scheduled task's own
    /// timestamp (`lastActive`, i.e. `sessions.first`) moves with the
    /// run it fired. Runs the sessions overlay first, so the map it
    /// reads has already been pruned.
    private func applyingPendingStamps(tasks: [ScheduledAgentTask])
    -> [ScheduledAgentTask] {
        guard !pendingUserStamps.isEmpty else { return tasks }
        var out = tasks
        for i in out.indices {
            var touched = false
            for j in out[i].sessions.indices {
                guard let stamp = pendingUserStamps[out[i].sessions[j].id],
                      (out[i].sessions[j].lastUserMessageAt ?? .distantPast) < stamp
                else { continue }
                out[i].sessions[j].lastUserMessageAt = stamp
                touched = true
            }
            if touched {
                out[i].sessions.sort { $0.activityAt > $1.activityAt }
            }
        }
        return out
    }

    /// A scan can race the first instants of a just-spawned session:
    /// the JSONL may not exist yet, or may hold only claude's
    /// `queue-operation` bookkeeping — which classifies as an empty
    /// shell. Either way a draft's row would VANISH from the sidebar
    /// the moment its first send revealed a session id
    /// (`migrateRunner`'s own rescan lands precisely inside that
    /// window) and stay gone until the next unrelated rescan. The
    /// manager knows better than the disk here: a session with a turn
    /// in flight is by definition not an abandoned shell, so it stays
    /// listed — the follow-up scan on turn end replaces the
    /// placeholder with the real parsed row.
    private func preservingLiveSessions(_ scanned: [AgentSession]) -> [AgentSession] {
        var liveIds: Set<String> = []
        for runner in runners.values where runner.status.isRunning {
            if let sid = runner.sessionId, !sid.isEmpty {
                liveIds.insert(sid)
            }
        }
        guard !liveIds.isEmpty else { return scanned }
        var out = scanned
        for id in liveIds {
            if let idx = out.firstIndex(where: { $0.id == id }) {
                out[idx].isEmptyShell = false
            } else if let runner = runners[id] {
                // A scheduled run keeps the title and the task it was
                // started with — the same placeholder `migrateRunner`
                // made, not a generic one the next line then has to fix.
                let run = liveScheduledRuns[id]
                var placeholder = AgentSession(
                    id: id,
                    fileURL: runner.sessionFileURL ?? SipaiPaths.dataDir
                        .appendingPathComponent("\(Self.unresolvedPlaceholderPrefix)\(id).jsonl"),
                    title: run?.title ?? runner.initialName ?? String(
                        localized: "New session",
                        comment: "Placeholder title for a just-migrated session before JSONL parse"),
                    modifiedAt: Date(),
                    projectPath: runner.cwd,
                    scheduledTaskName: run?.taskName,
                    agentKey: runner.agentKey
                )
                if run != nil { placeholder.origin = .scheduled }
                out.insert(placeholder, at: 0)
            }
        }
        return out
    }

    // MARK: - Deleting sessions

    /// Sessions and scheduled tasks whose delete has not finished. A scan
    /// that lands in the meantime would list them again — one already in
    /// flight read the disk before the delete, and a run stopped for it
    /// rescans as it ends — so `reloadSessions` leaves them out until
    /// their files are gone.
    private var deletingSessionIds: Set<String> = []
    private var deletingTaskNames: Set<String> = []

    /// The longest a delete waits for a run it stopped to END before
    /// removing the run's files: past `AgentRunner`'s own stop bound
    /// (4 s), by which a stopped turn has ended whether or not its child
    /// answered SIGTERM.
    private static let deletionStopWait: TimeInterval = 6

    /// Delete a session's on-disk transcript(s) and forget its runner.
    /// Claude sessions are one JSONL; codex sessions can own several
    /// rollout files (one per resume) and all of them must go, or the
    /// session resurrects from an older rollout on the next scan; a
    /// kimi session is a whole DIRECTORY (state + one wire file per
    /// agent), so removing the file the row points at would leave the
    /// session listed and unreadable.
    func deleteSession(_ session: AgentSession) {
        delete([session], task: nil)
    }

    /// A scheduled task's "Delete all": its definition and every run it
    /// made. The task leaves the sidebar at once and in one piece —
    /// deleted run by run, and definition apart, it would first shrink
    /// and then turn into an orphan (runs listed under a definition that
    /// is gone) before it went.
    ///
    /// `startingRun` is the runner key the scheduler filed its run in
    /// flight under (`ScheduledTaskScheduler.inFlight`). A run fired a
    /// moment ago has no session id yet, so it is not among the task's
    /// runs; left going, its transcript would bring the task straight
    /// back as an orphan. It is stopped with the others, and its files go
    /// with theirs once it has ended.
    func deleteScheduledTaskAndRuns(_ task: ScheduledAgentTask,
                                    startingRun: String? = nil) {
        delete(task.sessions, task: task,
               starting: startingRun.flatMap { runners[$0] })
    }

    /// The one way sessions are deleted.
    ///
    /// The rows leave the lists NOW, and stay off them until the files
    /// are gone (`deletingSessionIds`). A run that is still going is
    /// stopped FIRST and its files removed only once it has ended:
    /// measured on claude 2.1.283, a transcript deleted under a live turn
    /// is written again the moment the stopped process exits — a stray
    /// file of claude's bookkeeping records — while one deleted after
    /// the exit stays gone. A task's definition goes before any of that,
    /// so nothing can fire the task again while its runs are stopping.
    private func delete(_ doomed: [AgentSession], task: ScheduledAgentTask?,
                        starting: AgentRunner? = nil) {
        let ids = Set(doomed.map(\.id))
        deletingSessionIds.formUnion(ids)
        if let task { deletingTaskNames.insert(task.name) }
        sessions.removeAll { ids.contains($0.id) }
        scheduledTasks = Self.leaving(scheduledTasks, sessionIds: ids,
                                      taskNames: task.map { [$0.name] } ?? [])
        liveScheduledRuns = liveScheduledRuns.filter { id, run in
            !ids.contains(id) && run.taskName != task?.name
        }

        var stopping: [AgentRunner] = []
        var handled: [AgentRunner] = []
        for session in doomed {
            if let runner = runners[session.id] {
                if runner.status.isRunning { stopping.append(runner) }
                handled.append(runner)
                runner.cancel()
                runners.removeValue(forKey: session.id)
            }
            // The tailer dies with the runner without firing its false
            // callback, so these would otherwise hold the deleted id
            // until relaunch — a phantom activity dot on any future row
            // that matches it.
            externalInFlightSessions.remove(session.id)
            inFlightSends.removeValue(forKey: session.id)
            // Its Chat only record describes turns that no longer exist.
            config?.clearAgentChatOnlyTurns(for: session.id)
            // And there is nothing left to open.
            config?.clearAgentSessionUnread([session.id])
        }
        // A run with no session id yet: stopped the same way, under
        // whatever keys it is filed. Its id may still arrive — a
        // `system.init` already on the way when the stop landed — and
        // must not re-file the run: `migrateRunner` would put its row,
        // its live entry and its task back on the lists. The runner
        // records the id and the file all the same, for the tail below.
        var unnamed: [AgentRunner] = []
        if let starting, !handled.contains(where: { $0 === starting }) {
            if starting.status.isRunning { stopping.append(starting) }
            starting.onSessionIdDiscovered = nil
            starting.cancel()
            runners = runners.filter { $0.value !== starting }
            unnamed.append(starting)
        }

        // A placeholder row's URL names no file; the remover looks the
        // session up by id then.
        let files = doomed.map {
            SessionFiles(agentKey: $0.agentKey, sessionId: $0.id,
                         fileURL: Self.isUnresolvedPlaceholder($0.fileURL) ? nil : $0.fileURL)
        }
        let definition = task.map { (name: $0.name, directory: $0.directoryURL) }
        Task { [weak self] in
            if let definition {
                await Task.detached(priority: .userInitiated) {
                    ScheduledTaskCreator.deleteTask(named: definition.name,
                                                    directory: definition.directory)
                }.value
            }
            let deadline = Date().addingTimeInterval(Self.deletionStopWait)
            while stopping.contains(where: { $0.status.isRunning }), Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // The unnamed run has ended. Whatever session it became is
            // held and removed like the rest: its id came after the lists
            // were cut, so nothing above knew it, and its live entry
            // (`liveScheduledRuns`) would otherwise file a run whose file
            // is going under the task — as an orphan — for the settle
            // window, with nothing on disk to retire it against. Its
            // file may not have been found before the stop; the remover
            // looks it up by id then.
            var doomedFiles = files
            var lateIds: Set<String> = []
            for runner in unnamed {
                guard let self else { break }
                self.runners = self.runners.filter { $0.value !== runner }
                guard let id = runner.sessionId, !id.isEmpty else { continue }
                lateIds.insert(id)
                self.deletingSessionIds.insert(id)
                self.sessions.removeAll { $0.id == id }
                self.liveScheduledRuns.removeValue(forKey: id)
                self.inFlightSends.removeValue(forKey: id)
                self.externalInFlightSessions.remove(id)
                self.config?.clearAgentChatOnlyTurns(for: id)
                self.config?.clearAgentSessionUnread([id])
                doomedFiles.append(SessionFiles(agentKey: runner.agentKey,
                                                sessionId: id, fileURL: runner.sessionFileURL))
            }
            if let self, !lateIds.isEmpty {
                self.scheduledTasks = Self.leaving(self.scheduledTasks, sessionIds: lateIds,
                                                   taskNames: self.deletingTaskNames)
            }
            let allFiles = doomedFiles
            // Disk work off the MainActor: the codex branch walks the
            // whole rollout store re-reading up to 512 KB per file to
            // find a session's siblings — done synchronously that is a
            // hard main-thread stall on every codex delete.
            await Task.detached(priority: .userInitiated) {
                for file in allFiles { Self.removeFiles(of: file) }
            }.value
            guard let self else { return }
            self.deletingSessionIds.subtract(ids)
            self.deletingSessionIds.subtract(lateIds)
            if let definition { self.deletingTaskNames.remove(definition.name) }
            self.reloadSessions()
        }
    }

    /// `tasks` without the named tasks and without the named runs — and
    /// without an orphan whose last run just went, since an orphan (a
    /// task whose definition is gone) is nothing but its runs.
    private static func leaving(_ tasks: [ScheduledAgentTask],
                                sessionIds: Set<String>,
                                taskNames: Set<String>) -> [ScheduledAgentTask] {
        var kept: [ScheduledAgentTask] = []
        for var task in tasks where !taskNames.contains(task.name) {
            let runs = task.sessions.count
            task.sessions.removeAll { sessionIds.contains($0.id) }
            if task.definition == nil, runs > 0, task.sessions.isEmpty { continue }
            kept.append(task)
        }
        return kept
    }

    /// What deleting a session removes from disk, taken on the MainActor.
    private struct SessionFiles: Sendable {
        let agentKey: String
        let sessionId: String
        /// Nil for a session whose transcript was never found — a run
        /// stopped before its file landed, a placeholder row — which the
        /// remover looks up by id.
        let fileURL: URL?
    }

    /// The stand-in `fileURL` a row carries until its transcript is
    /// found (`migrateRunner`, `preservingLiveSessions`). Removing it
    /// removes nothing, so a delete treats it as no URL at all.
    nonisolated private static let unresolvedPlaceholderPrefix = "_unresolved_"

    nonisolated private static func isUnresolvedPlaceholder(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(unresolvedPlaceholderPrefix)
    }

    nonisolated private static func removeFiles(of session: SessionFiles) {
        let fm = FileManager.default
        let fileURL = session.fileURL
            ?? AgentRunner.locateSessionFile(id: session.sessionId, agentKey: session.agentKey)
        switch session.agentKey {
        case "codex":
            let files = CodexSessionScanner.rolloutFiles(
                forSessionId: session.sessionId)
            for url in files { try? fm.removeItem(at: url) }
            // Belt and braces: the scanned URL always goes even if the
            // meta re-read failed for it.
            if let fileURL { try? fm.removeItem(at: fileURL) }
        case "kimi":
            guard let fileURL else { return }
            // The whole `<sessionId>/` tree, resolved by shape from the
            // wire file the row carries. If that walk fails the wire file
            // alone goes — a half-deleted session still stops listing
            // (its wire is gone, so the scan reads it as an empty shell),
            // which beats deleting nothing.
            if let dir = KimiSessionScanner.sessionDirectory(of: fileURL) {
                try? fm.removeItem(at: dir)
            } else {
                try? fm.removeItem(at: fileURL)
            }
        default:
            if let fileURL { try? fm.removeItem(at: fileURL) }
        }
    }

    // MARK: - Detection

    /// Common directories where CLI tools are installed.
    /// macOS GUI apps have a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin),
    /// so tools installed via npm/Homebrew/nvm won't be found by `which`.
    /// We check these directories directly.
    ///
    /// Latched once because it walks the filesystem (the nvm sweep).
    /// The shell's own PATH is folded in by `searchPaths` instead — it
    /// arrives asynchronously, so it cannot be part of a `let`.
    nonisolated private static let builtInSearchPaths: [String] = {
        var paths = [
            "/usr/local/bin",
            "/usr/bin",
            "/opt/homebrew/bin",
        ]
        // ~/.local/bin
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths.append(home + "/.local/bin")
        // Kimi Code's installer does NOT put its binary in any of the
        // above: it drops a self-contained executable in
        // ~/.kimi-code/bin and appends that directory to ~/.zshrc. A
        // GUI app never reads ~/.zshrc (see `ShellEnvironment`), so
        // without these two entries a freshly installed kimi is
        // invisible to `isInstalled` — the section either never appears
        // in the sidebar or, once a session exists, appears pinned to
        // the read-only tier with no in-app way out. `~/.kimi/bin` is
        // the legacy `kimi-cli` location, kept for a machine that has
        // not run `kimi migrate`.
        paths.append(home + "/.kimi-code/bin")
        paths.append(home + "/.kimi/bin")
        // nvm-installed globals: ~/.nvm/versions/node/*/bin
        let nvmBase = home + "/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmBase) {
            // Sort descending so we check the latest node version first
            for entry in entries.sorted().reversed() {
                paths.append(nvmBase + "/" + entry + "/bin")
            }
        }
        // Volta-installed globals
        paths.append(home + "/.volta/bin")
        return paths
    }()

    /// Everywhere an agent CLI might live: the hardcoded guesses above,
    /// then whatever the user's own login shell puts on PATH.
    ///
    /// The hardcoded list is a guess that goes stale every time an
    /// installer picks a new directory, and each miss reads to the user
    /// as "the app can't see the CLI I just installed". The shell's
    /// PATH is the authoritative answer to that question, and the app
    /// already captures it (`ShellEnvironment`) — folding it in is what
    /// covers whatever directory the NEXT installer picks.
    ///
    /// Order is deliberate: built-ins FIRST, so this can only ever ADD
    /// newly-findable binaries. Letting the shell's PATH win would
    /// change which `claude`/`codex` an already-working install
    /// resolves to, which is not something a detection fix should do.
    ///
    /// Computed per call rather than latched, because the shell capture
    /// is asynchronous — an empty answer during the app's first moments
    /// must be able to become a real one on the next 5 s re-detection
    /// tick. Cheap by construction: the filesystem walk stays in the
    /// latched `let`, and this only splits a string.
    nonisolated static var searchPaths: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for dir in builtInSearchPaths + ShellEnvironment.loginShellPathDirectories()
        where !dir.isEmpty && seen.insert(dir).inserted {
            out.append(dir)
        }
        return out
    }

    private static func isInstalled(_ cmd: String) -> Bool {
        for dir in searchPaths {
            let fullPath = dir + "/" + cmd
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return true
            }
        }
        return false
    }

    /// Resolved absolute path to an agent's binary, if installed.
    /// Public counterpart to the private `isInstalled` helper.
    nonisolated static func binaryPath(for key: String) -> String? {
        guard let agent = registry.first(where: { $0.key == key }) else { return nil }
        for dir in searchPaths {
            let fullPath = dir + "/" + agent.cmd
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }
}
