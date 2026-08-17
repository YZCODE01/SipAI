// ScheduledTaskScheduler.swift
// Fires scheduled tasks from inside the app.
//
// WHY NOT CRON
//
// cron still runs on macOS, but it cannot do this job. `/usr/sbin/cron`
// is not granted Full Disk Access, so a job it spawns gets "Operation
// not permitted" for anything under ~/Desktop, ~/Documents or
// ~/Downloads — which is where projects actually live. The grant is
// manual, system-wide (every cron job on the machine gets it), and
// resets across some OS upgrades, and when it resets the task does not
// fail loudly: it runs and reads nothing. cron also silently skips
// slots the machine slept through, and its one shared crontab file has
// no history, so anything that rewrites it erases every task at once.
// LaunchAgents hit the same TCC wall with a different binary.
//
// The app, by contrast, already holds whatever file access the user
// granted it and already knows how to spawn `claude`. Running the task
// here inherits that access, needs no permission prompts, and the run
// streams into the sidebar as an ordinary live session.
//
// The cost is that the app must be open. `catchUpMissed` is what makes
// that livable: a slot missed while SipAI was closed fires on the next
// launch, so "be open at 9:00 sharp" becomes "open the app sometime
// that day".
//
// THE DUE RULE
//
// One question decides everything: *what is the most recent slot this
// task was supposed to fire in?* (`previousFireDate(onOrBefore: now)`).
// If that slot is newer than the last one we consumed, the task owes a
// run. Live firing and catch-up are then the same code path and can
// never disagree — and because it asks for the most RECENT slot rather
// than enumerating every missed one, a task that was due 40 times while
// the app was closed fires once, not 40 times.

import AppKit
import Combine
import Foundation

/// What happened the last time a task ran. Persisted so the decision
/// survives relaunches — an in-memory-only record would re-fire every
/// task on every launch.
struct ScheduledTaskRunState: Codable, Equatable {
    /// Most recent slot accounted for, fired or deliberately skipped.
    /// The high-water mark the due rule compares against.
    var lastSlot: Date?
    var lastFiredAt: Date?
    var lastSessionId: String?
    /// "running" / "done" / "error" — display only.
    var lastOutcome: String?
    var lastError: String?
    /// A slot that was consumed WITHOUT running: catch-up was off, or
    /// the slot was older than the catch-up window. Surfaced in the
    /// panel so a silently-skipped run is still visible.
    var lastMissedSlot: Date?
}

@MainActor
final class ScheduledTaskScheduler: ObservableObject {

    /// Per-task run records, keyed by task name. Published so the
    /// key-information panel can show the last outcome live.
    @Published private(set) var states: [String: ScheduledTaskRunState] = [:]

    /// Tasks with a run in flight right now, keyed by task name →
    /// runner key. Prevents a second fire while the first is still
    /// going, including across a slot boundary for a long run.
    @Published private(set) var inFlight: [String: String] = [:]

    private weak var agents: AgentManager?
    private weak var appState: AppState?
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    /// Per-run Combine subscriptions, dropped when the run ends.
    private var runObservers: [String: Set<AnyCancellable>] = [:]

    /// How often the due check runs. A scheduled task's finest
    /// granularity is one minute, so 30 s guarantees every slot is seen
    /// while costing a handful of small file reads.
    private static let tickInterval: TimeInterval = 30

    /// A slot this fresh counts as "happening now" and fires regardless
    /// of the catch-up setting — it covers the gap between the slot and
    /// the next tick, plus a launch that lands moments after the slot.
    nonisolated static let liveWindow: TimeInterval = 5 * 60

    /// How stale a missed slot may be and still fire on catch-up.
    /// Beyond a day, running unattended work the user has long stopped
    /// expecting is more surprising than useful, so the slot is
    /// recorded as missed and the panel offers Run now instead.
    nonisolated static let catchUpWindow: TimeInterval = 24 * 60 * 60

    /// `nonisolated` because the background save task reads it — the
    /// path is a pure function of the data directory, so there is no
    /// actor state to protect.
    nonisolated private static var stateFile: URL {
        SipaiPaths.dataDir.appendingPathComponent("scheduled_state.json")
    }

    // MARK: - Lifecycle

    func start(agents: AgentManager, appState: AppState) {
        self.agents = agents
        self.appState = appState
        loadState()
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: Self.tickInterval,
                                     repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // The run loop drops repeating timers while a menu or a live
        // resize tracks the mouse; scheduled work must not stall
        // because a menu is open.
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Waking from sleep is exactly when a missed slot is most
        // likely, and the timer may not have fired across the gap.
        // Workspace notifications post to NSWorkspace's OWN centre, not
        // the default one — subscribing to the default centre here
        // yields a publisher that never fires.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification, object: nil)
            .sink { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            .store(in: &cancellables)

        tick()
    }

    // MARK: - Due check

    /// Runs before the first due check. Recovers schedules from any
    /// pre-existing crontab entries and removes them, so the app is the
    /// only thing firing these tasks.
    private var migrated = false

    private func tick() {
        let now = Date()
        let needsMigration = !migrated
        migrated = true
        let epoch = saveEpoch
        Task.detached(priority: .utility) {
            if needsMigration {
                let recovered = ScheduledTaskCreator.migrateLegacyCrontabSchedules()
                if !recovered.isEmpty {
                    await MainActor.run { self.agents?.reloadSessions() }
                }
            }
            let defs = ScheduledTaskScheduler.loadDefinitions()
            await MainActor.run { self.evaluate(defs, now: now, epoch: epoch) }
        }
    }

    /// Read every task definition off the main actor. Cheap — a handful
    /// of small files — but it is disk I/O on a timer, so it never runs
    /// on the main actor.
    nonisolated static func loadDefinitions() -> [ScheduledTaskDefinition] {
        let fm = FileManager.default
        let root = ScheduledAgentTaskScanner.taskRoot
        guard let dirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [ScheduledTaskDefinition] = []
        for dir in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let skill = dir.appendingPathComponent("SKILL.md")
            if let def = ScheduledTaskDefinition.read(
                name: dir.lastPathComponent, skillFile: skill) {
                out.append(def)
            }
        }
        return out
    }

    /// What a tick decides to do about one task. Pure data so the rule
    /// can be tested without an AgentManager, a timer or a subprocess.
    enum Decision: Equatable {
        /// Nothing owed — not scheduled, paused, already consumed, or
        /// a run is still going.
        case idle
        /// First sighting: record the current slot WITHOUT running.
        case adopt(slot: Date)
        /// Owed a run for this slot.
        case fire(slot: Date)
        /// The slot passed unrun and will not be made up: catch-up is
        /// off, or the slot is older than the catch-up window.
        case skipMissed(slot: Date)
    }

    /// The whole due rule, as a pure function of (definition, prior
    /// state, now). `evaluate` only applies whatever this returns.
    nonisolated static func decide(_ def: ScheduledTaskDefinition,
                                   state: ScheduledTaskRunState?,
                                   now: Date,
                                   isRunning: Bool,
                                   calendar: Calendar = .current) -> Decision {
        guard def.enabled, let schedule = def.schedule else { return .idle }
        guard let slot = schedule.previousFireDate(onOrBefore: now,
                                                   calendar: calendar)
        else { return .idle }

        // First sighting of this task. Adopt the current slot WITHOUT
        // running: a task created at 14:00 with a 09:00 schedule must
        // not immediately fire for this morning, and the first launch
        // that SEES a task must not fire it for slots already in the
        // past.
        guard let state = state else { return .adopt(slot: slot) }

        if let last = state.lastSlot, slot <= last { return .idle }
        if isRunning { return .idle }

        let age = now.timeIntervalSince(slot)
        if age <= liveWindow { return .fire(slot: slot) }
        if def.catchUpMissed && age <= catchUpWindow { return .fire(slot: slot) }
        return .skipMissed(slot: slot)
    }

    /// `epoch` is the save epoch as it stood when this tick STARTED
    /// reading. A factory reset since then has deleted both the run
    /// records and the task files `defs` was read from, so applying
    /// this verdict would adopt slots for tasks that no longer exist —
    /// and `saveState` would write the file the wipe just removed.
    /// Definitions are re-read every tick, so dropping one costs
    /// nothing: the next tick is 30 s away.
    private func evaluate(_ defs: [ScheduledTaskDefinition], now: Date,
                          epoch: Int) {
        guard epoch == saveEpoch else { return }
        var dirty = false
        for def in defs {
            switch Self.decide(def, state: states[def.name], now: now,
                               isRunning: inFlight[def.name] != nil) {
            case .idle:
                continue
            case .adopt(let slot):
                var fresh = ScheduledTaskRunState()
                fresh.lastSlot = slot
                states[def.name] = fresh
            case .fire(let slot):
                var state = states[def.name] ?? ScheduledTaskRunState()
                state.lastSlot = slot
                state.lastMissedSlot = nil
                states[def.name] = state
                fire(def, slot: slot)
            case .skipMissed(let slot):
                var state = states[def.name] ?? ScheduledTaskRunState()
                state.lastSlot = slot
                state.lastMissedSlot = slot
                states[def.name] = state
            }
            dirty = true
        }
        if dirty { saveState() }
    }

    // MARK: - Firing

    /// Run a task now, outside its schedule. Used by the panel's Run
    /// now button; deliberately does NOT consume a slot, so pressing it
    /// never cancels the next scheduled run.
    func runNow(_ def: ScheduledTaskDefinition) {
        fire(def, slot: nil)
    }

    /// True while this task has a run in flight.
    func isRunning(_ taskName: String) -> Bool {
        inFlight[taskName] != nil
    }

    private func fire(_ def: ScheduledTaskDefinition, slot: Date?) {
        guard inFlight[def.name] == nil else { return }
        guard let agents = agents else { return }

        var state = states[def.name] ?? ScheduledTaskRunState()

        let prompt = def.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            state.lastOutcome = "error"
            state.lastError = String(
                localized: "The task has no prompt to run.",
                comment: "Scheduled-run failure: SKILL.md body is empty")
            states[def.name] = state
            saveState()
            return
        }

        var isDir: ObjCBool = false
        let cwd = def.workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir),
              isDir.boolValue else {
            state.lastOutcome = "error"
            state.lastError = String(
                localized: "The task's folder no longer exists: \(cwd.path)",
                comment: "Scheduled-run failure: cwd is gone")
            states[def.name] = state
            saveState()
            return
        }

        // The task's OWN agent, not a hardcoded one: a hardcoded agent
        // would run a task declaring `agent: codex` under Claude Code,
        // with its codex sandbox mode handed to claude as a
        // `--permission-mode`.
        let taskAgent = def.agent
        guard agents.isAgentReady(taskAgent) else {
            let name = AgentManager.registry
                .first { $0.key == taskAgent }?.name ?? taskAgent
            state.lastOutcome = "error"
            state.lastError = agents.isAgentInstalled(taskAgent)
                ? String(localized: "\(name) is installed but not signed in.",
                         comment: "Scheduled-run failure: agent CLI lacks auth")
                : String(localized: "\(name) is not installed on this machine.",
                         comment: "Scheduled-run failure: agent CLI missing")
            states[def.name] = state
            saveState()
            return
        }

        // A fresh draft per run: each firing is its own session, never a
        // --resume of the last one, so a task's runs stay independent
        // and its context doesn't grow without bound.
        let draft = ClaudeSessionDraft(cwd: cwd, name: def.description,
                                       agentKey: taskAgent)
        let runner = agents.runner(forDraft: draft)

        var options = AgentLaunchOptions()
        options.permissionMode = def.mode
        options.model = def.model
        options.effort = def.effort

        // The marker is what makes the run findable: both scanners read
        // `<scheduled-task name="…">` out of the first user record and
        // file the session under its task. It is a PAIRED, EMPTY tag
        // with the prompt outside it — the display cleaners strip the
        // tag WITH its contents, so a prompt placed inside would vanish
        // from the transcript.
        let marked = "<scheduled-task name=\"\(def.name)\"></scheduled-task>\n\(prompt)"

        guard runner.send(text: marked, options: options) else {
            agents.releaseDraftRunner(draftId: draft.id)
            return
        }

        let firedAt = Date()
        inFlight[def.name] = runner.key
        state.lastFiredAt = firedAt
        state.lastOutcome = "running"
        state.lastError = nil
        state.lastSessionId = nil
        if let slot = slot {
            state.lastSlot = slot
        } else if let current = def.schedule?
            .previousFireDate(onOrBefore: firedAt) {
            // A MANUAL run (Run now) adopts the current slot if the task
            // hasn't already passed it. Without this, pressing Run now on
            // a task the scheduler has never seen leaves `lastSlot` nil,
            // and the very next tick reads today's already-passed slot as
            // owed — firing a second, unasked-for run seconds later.
            //
            // It cannot cancel a scheduled run: the next slot is strictly
            // after `firedAt`, hence still after this high-water mark.
            state.lastSlot = max(state.lastSlot ?? .distantPast, current)
        }
        states[def.name] = state
        saveState()

        observe(runner: runner, draft: draft, taskName: def.name)
    }

    /// Watch one run to completion: record the session id when it
    /// surfaces, the outcome when the turn ends, then drop the
    /// subscriptions.
    private func observe(runner: AgentRunner, draft: ClaudeSessionDraft,
                         taskName: String) {
        var bag = Set<AnyCancellable>()

        runner.$sessionId
            .compactMap { $0 }
            .first()
            .sink { [weak self] sessionId in
                Task { @MainActor in
                    guard let self = self else { return }
                    var state = self.states[taskName] ?? ScheduledTaskRunState()
                    state.lastSessionId = sessionId
                    self.states[taskName] = state
                    self.saveState()
                    // AgentManager keeps the draft key as an alias to the
                    // same runner so an open draft view isn't stranded
                    // mid-migration. Nobody is viewing this one, so drop
                    // it here — otherwise every scheduled run leaks a
                    // dictionary entry for the life of the app.
                    self.agents?.releaseDraftRunner(draftId: draft.id)
                    // If the user is looking at this task, show the run
                    // it just started.
                    if self.appState?.openScheduledTaskName == taskName,
                       self.appState?.openAgentSessionId == nil {
                        self.appState?.openAgentSessionId = sessionId
                        self.appState?.openAgentSessionPath = runner.sessionFileURL
                    }
                }
            }
            .store(in: &bag)

        runner.$status
            .sink { [weak self] status in
                guard case .done(let code, let message) = status else { return }
                Task { @MainActor in
                    guard let self = self else { return }
                    var state = self.states[taskName] ?? ScheduledTaskRunState()
                    state.lastOutcome = code == 0 ? "done" : "error"
                    state.lastError = code == 0 ? nil
                        : (message ?? String(
                            localized: "The run exited with code \(code).",
                            comment: "Scheduled-run failure: nonzero exit"))
                    // Claude and codex announce their session id in the
                    // FIRST event of a turn, so the sink above has long
                    // since fired by now. Kimi announces it in the LAST
                    // stdout line, and the store-diff fallback can be
                    // later still — so for a kimi run this teardown can
                    // reach the id before that sink does. Take it here
                    // too, or the whole `.done` path drops it and the
                    // draft alias below is never released.
                    if state.lastSessionId == nil {
                        state.lastSessionId = runner.sessionId
                    }
                    self.states[taskName] = state
                    self.inFlight.removeValue(forKey: taskName)
                    self.runObservers.removeValue(forKey: taskName)
                    // No-op unless the runner actually migrated off its
                    // draft key (`releaseDraftRunner` checks), so this
                    // cannot strand a runner that never got an id.
                    self.agents?.releaseDraftRunner(draftId: draft.id)
                    self.saveState()
                    self.agents?.reloadSessions()
                }
            }
            .store(in: &bag)

        runObservers[taskName] = bag
    }

    // MARK: - Persistence

    /// Drop a task's record — called after a delete so a recreated task
    /// of the same name starts clean rather than inheriting a stale
    /// high-water mark that would suppress its first run.
    func forget(taskName: String) {
        guard states.removeValue(forKey: taskName) != nil else { return }
        saveState()
    }

    /// Drop EVERY run record and stop watching whatever is in flight.
    /// The factory reset calls this first, before the data directory is
    /// wiped, and it has to do three things in this order to be safe:
    ///
    /// * **Bump the save epoch.** `saveState` writes from a detached
    ///   task, so a save queued moments before the wipe would otherwise
    ///   land after it and put `scheduled_state.json` back with
    ///   pre-reset contents — a "wipe" that un-wipes itself a heartbeat
    ///   later. The epoch makes those in-flight writes no-ops.
    /// * **Drop the run observers.** The factory reset stops running
    ///   turns immediately afterwards; each stop would otherwise reach a
    ///   `$status` sink that answers by writing a fresh run record.
    /// * **Clear the records themselves,** and write nothing back — the
    ///   file goes with the rest of the directory.
    ///
    /// The task DEFINITIONS are not touched here: they are ordinary
    /// folders under `~/.claude/scheduled-tasks`. With no state left,
    /// `decide` reads each task as a first sighting and ADOPTS its
    /// current slot instead of firing it, so a reset can never touch off
    /// a catch-up run for a slot that passed before it.
    func forgetAllRuns() {
        saveEpoch &+= 1
        runObservers.removeAll()
        inFlight.removeAll()
        states.removeAll()
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: Self.stateFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(
            [String: ScheduledTaskRunState].self, from: data) else { return }
        states = decoded
    }

    /// Bumped by `forgetAllRuns()`. A save queued before that call
    /// carries the old epoch and is dropped rather than recreating the
    /// state file the factory reset just removed.
    private var saveEpoch: Int = 0

    private func saveState() {
        let snapshot = states
        let epoch = saveEpoch
        Task.detached(priority: .utility) { [weak self] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            // Re-checked HERE, after the encode and immediately before
            // the write, because that is the window a factory reset can
            // open underneath us. A nil self (scheduler gone) fails the
            // comparison too, which is the right way to fail: there is
            // no one left whose state this would be.
            guard await self?.saveEpoch == epoch else { return }
            SipaiPaths.ensureDataDir()
            try? data.write(to: ScheduledTaskScheduler.stateFile, options: .atomic)
        }
    }
}
