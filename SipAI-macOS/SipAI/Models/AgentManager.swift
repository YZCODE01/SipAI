// AgentManager.swift
// Detects installed agent CLIs and tracks seen/unseen state.

import Foundation

struct AgentInfo: Identifiable, Hashable {
    let key: String
    let name: String
    let cmd: String
    /// Session store location relative to the home directory. A store
    /// without the CLI still lists read-only.
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
        /// Seconds the transcript's newest finished turn took — the
        /// cold seed for the composer's turn clock, 0 when unknown.
        let turnDuration: Double
        let commands: [String]
        let fileSize: UInt64
        let fileMtime: Date
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
            turnDuration: existing.turnDuration,
            commands: existing.commands,
            fileSize: existing.fileSize,
            fileMtime: existing.fileMtime
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

    /// Agents worth showing at all: runnable CLI *or* a session store on
    /// disk (a desktop app writes sessions without putting a CLI on
    /// PATH). Availability drives the sidebar; `installedAgents` gates
    /// interaction — the difference renders as the read-only tier.
    @Published private(set) var availableAgents: [AgentInfo] = []

    /// Agents not yet in the seen_agents list (for first-time hints).
    @Published private(set) var unseenAgents: [AgentInfo] = []

    /// True if at least one agent CLI is installed on this machine.
    /// Independent of the seen/unseen distinction — callers just want to know
    /// whether agent-only mode is viable.
    var hasInstalledAgent: Bool {
        !installedAgents.isEmpty
    }

    /// Installed AND actually usable. For codex, "installed" only means
    /// the binary exists — without working auth every spawn would fail,
    /// so the app treats an unconfigured codex as the read-only tier:
    /// sessions list and open, but no new sessions and no Terminal
    /// hand-offs until `codex login` (or a real API key) is set up.
    func isAgentReady(_ key: String) -> Bool {
        guard isAgentInstalled(key) else { return false }
        if key == "codex" { return Self.codexAuthConfigured() }
        // Kimi deliberately gets no auth probe. The codex one reads a
        // file whose shape is known (`~/.codex/auth.json`); Kimi
        // Code's credential store is not documented, and guessing a
        // filename wrong here does not degrade gracefully — it pins an
        // installed, signed-in CLI to the read-only tier, with no
        // in-app way out. The fail direction is chosen on purpose:
        // "installed" means ready, and an unauthenticated spawn
        // surfaces kimi's own `/login` message in the transcript, which
        // says more than a guessed banner could.
        return true
    }

    /// Whether ~/.codex/auth.json holds credentials codex could
    /// actually use: a ChatGPT-login token set, or an API key that is
    /// at least shaped like a real one (≥ 40 characters — real OpenAI
    /// keys are longer than that, and a shorter string is a placeholder
    /// someone typed to get past a prompt). Treating a placeholder as
    /// configured would offer "New session" flows that immediately
    /// fail.
    nonisolated static func codexAuthConfigured() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] else {
            return false
        }
        if let tokens = obj["tokens"] as? [String: Any], !tokens.isEmpty {
            return true
        }
        if let key = obj["OPENAI_API_KEY"] as? String {
            return key.count >= 40
        }
        return false
    }

    func isAgentInstalled(_ key: String) -> Bool {
        installedAgents.contains(where: { $0.key == key })
    }

    func isAgentAvailable(_ key: String) -> Bool {
        availableAgents.contains(where: { $0.key == key })
    }

    /// Agent sessions discovered under `~/.claude/projects`, sorted newest-first.
    /// Empty until `reloadSessions` completes at least once.
    @Published private(set) var sessions: [AgentSession] = []

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
            } else if self.inFlightSends.removeValue(forKey: key) != nil {
                // A turn just ENDED (there was an in-flight token to
                // clear — a plain `.idle` assignment is not a turn).
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
        runner.onExternalInProgressChange = { [weak self] sessionId, inProgress in
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
            } else {
                self.externalInFlightSessions.remove(sessionId)
            }
        }
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
        // Here rather than in the view's own discovery handler, for two
        // reasons. The centre pane is torn down by any detour to a chat
        // or a note, so a filing addressed to the view is lost exactly
        // when the user starts a turn and looks at something else; this
        // runs from the runner's callback with the draft captured,
        // whether or not a view is alive. And it must land BEFORE the
        // placeholder below, which re-renders the sidebar at once —
        // written after, the row appears under Ungrouped and jumps.
        //
        // A group deleted (or renamed, which is the same thing: groups
        // are keyed by name) between the click and the first event
        // fails the membership test, and the session is simply
        // unfiled. Writing the assignment anyway would leave config
        // pointing at a group that no longer exists.
        if let group = draft?.customGroup,
           let config = self.config,
           config.agentCustomGroups(for: runner.agentKey).contains(group) {
            config.setAgentSessionGroup(group, for: newSessionId)
        }

        // Inject a placeholder session so the view can resolve it
        // synchronously; the async reloadSessions() below will
        // replace the placeholder with the real parsed row.
        if !sessions.contains(where: { $0.id == newSessionId }) {
            let placeholderTitle = draft?.name ?? String(
                localized: "New session",
                comment: "Placeholder title for a just-migrated session before JSONL parse")
            let placeholder = AgentSession(
                id: newSessionId,
                fileURL: fileURL ?? SipaiPaths.dataDir
                    .appendingPathComponent("_unresolved_\(newSessionId).jsonl"),
                title: placeholderTitle,
                modifiedAt: Date(),
                projectPath: runner.cwd,
                scheduledTaskName: nil,
                // Without this a codex draft's placeholder row files
                // itself under the Claude section until the next scan
                // corrects it — the row visibly jumps sections.
                agentKey: runner.agentKey
            )
            sessions.insert(placeholder, at: 0)
        }
        // The send that revealed this id happened under the DRAFT key,
        // so the stamp `onStatusChange` recorded is filed under a name
        // no session will ever have. Re-file it now that the session
        // has one, and the first turn orders like every later one.
        stampUserMessage(sessionId: newSessionId)

        reloadSessions()
    }

    // MARK: - Branches

    /// Adopt a session file this app just wrote (`AgentSessionFork`) and
    /// hand back its runner, ready to send.
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
    @discardableResult
    func registerBranchedSession(id: String, fileURL: URL, cwd: URL,
                                 title: String) -> AgentRunner {
        if !sessions.contains(where: { $0.id == id }) {
            var placeholder = AgentSession(
                id: id,
                fileURL: fileURL,
                title: title,
                modifiedAt: Date(),
                projectPath: cwd,
                scheduledTaskName: nil
            )
            // A branch is born at the top of the list: the user just
            // sent into it. Without this the row sorts on `modifiedAt`
            // of a file whose newest record was copied from the parent's
            // history, and it would land wherever that turn happened.
            placeholder.lastUserMessageAt = Date()
            sessions.insert(placeholder, at: 0)
        }
        stampUserMessage(sessionId: id)
        let runner = runner(forSessionId: id, fileURL: fileURL, cwd: cwd)
        reloadSessions()
        return runner
    }

    /// Refresh detection. Call on app launch and when returning to main view.
    func reload(config: ConfigManager) {
        let seen = config.seenAgents
        var installed: [AgentInfo] = []
        var available: [AgentInfo] = []
        for agent in Self.registry {
            let hasCli = Self.isInstalled(agent.cmd)
            if hasCli {
                installed.append(agent)
            }
            if hasCli || Self.storeExists(agent) {
                available.append(agent)
            }
        }
        // Assign only on change — this also runs from the 5 s
        // re-detection tick, and identical reassignment would trigger a
        // needless sidebar re-render every cycle.
        if installedAgents != installed { installedAgents = installed }
        if availableAgents != available { availableAgents = available }
        let unseen = available.filter { !seen.contains($0.key) }
        if unseenAgents != unseen { unseenAgents = unseen }
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

    nonisolated private static func storeExists(_ agent: AgentInfo) -> Bool {
        // Kimi's store is relocatable (`KIMI_CODE_HOME`), so the
        // registry's home-relative default is not authoritative for it.
        if agent.key == "kimi" { return KimiSessionScanner.storeExists }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(agent.storeDir, isDirectory: true).path
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && isDir.boolValue
    }

    /// Mark agents as seen so hints don't repeat.
    func markSeen(_ keys: [String], config: ConfigManager) {
        config.addSeenAgents(keys)
        let seen = config.seenAgents
        // Same universe as reload(): available = CLI installed OR a
        // desktop store exists. Filtering `installedAgents` here would
        // make store-only agents (codex Desktop without the CLI)
        // vanish from the unseen list the moment anything else is
        // marked, then flicker back on the next reload tick.
        unseenAgents = availableAgents.filter { !seen.contains($0.key) }
    }

    /// Mark all installed agents as seen + save to config.
    func markAllInstalledSeen(config: ConfigManager) {
        let keys = installedAgents.map(\.key)
        markSeen(keys, config: config)
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
            self.sessions = self.preservingLiveSessions(
                self.applyingPendingStamps(result.sessions))
            self.scheduledTasks =
                self.applyingPendingStamps(tasks: result.scheduledTasks)
            self.isScanning = false
        }
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
                let placeholder = AgentSession(
                    id: id,
                    fileURL: runner.sessionFileURL ?? SipaiPaths.dataDir
                        .appendingPathComponent("_unresolved_\(id).jsonl"),
                    title: runner.initialName ?? String(
                        localized: "New session",
                        comment: "Placeholder title for a just-migrated session before JSONL parse"),
                    modifiedAt: Date(),
                    projectPath: runner.cwd,
                    scheduledTaskName: nil,
                    agentKey: runner.agentKey
                )
                out.insert(placeholder, at: 0)
            }
        }
        return out
    }

    /// Delete a session's on-disk transcript(s) and forget its runner.
    /// Claude sessions are one JSONL; codex sessions can own several
    /// rollout files (one per resume) and all of them must go, or the
    /// session resurrects from an older rollout on the next scan; a
    /// kimi session is a whole DIRECTORY (state + one wire file per
    /// agent), so removing the file the row points at would leave the
    /// session listed and unreadable.
    func deleteSession(_ session: AgentSession) {
        if let runner = runners[session.id] {
            runner.cancel()
            runners.removeValue(forKey: session.id)
        }
        // The tailer dies with the runner without firing its false
        // callback, so these would otherwise hold the deleted id until
        // relaunch — a phantom activity dot on any future row that
        // matches it.
        externalInFlightSessions.remove(session.id)
        inFlightSends.removeValue(forKey: session.id)
        // Disk work off the MainActor: the codex branch walks the
        // whole rollout store re-reading up to 512 KB per file to find
        // a session's siblings — done synchronously that is a hard
        // main-thread stall on every codex delete.
        let agentKey = session.agentKey
        let sessionId = session.id
        let fileURL = session.fileURL
        Task { [weak self] in
            await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                switch agentKey {
                case "codex":
                    let files = CodexSessionScanner.rolloutFiles(
                        forSessionId: sessionId)
                    for url in files { try? fm.removeItem(at: url) }
                    // Belt and braces: the scanned URL always goes even
                    // if the meta re-read failed for it.
                    try? fm.removeItem(at: fileURL)
                case "kimi":
                    // The whole `<sessionId>/` tree, resolved by shape
                    // from the wire file the row carries. If that walk
                    // fails the wire file alone goes — a half-deleted
                    // session still stops listing (its wire is gone, so
                    // the scan reads it as an empty shell), which beats
                    // deleting nothing.
                    if let dir = KimiSessionScanner.sessionDirectory(of: fileURL) {
                        try? fm.removeItem(at: dir)
                    } else {
                        try? fm.removeItem(at: fileURL)
                    }
                default:
                    try? fm.removeItem(at: fileURL)
                }
            }.value
            self?.reloadSessions()
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
