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
//
// Two kinds of slot pass unrun without being MISSED, and treating either
// as missed runs the task off its schedule:
//
// * A slot of a schedule that was not in force when it passed. Move a
//   task that ran at 9:00 to 13:00, at two in the afternoon — or resume
//   one paused since the morning — and the new schedule's latest slot
//   is newer than the high-water mark: counted as missed, it fires at
//   once. The run record therefore keeps the schedule its high-water
//   mark belongs to (`scheduleInForce`), and a change counts the new
//   schedule's slots up to the moment it took effect as accounted for:
//   it runs from its next slot, exactly as a newly created task does.
// * A slot that comes while the task's previous run is still going.
//   Held until that run ends and then fired, it starts the next run the
//   moment the last one finishes — and a task whose runs outlast its
//   interval then runs back to back indefinitely, drifting off its
//   schedule. It waits out the live window (a run that ends within it
//   still counts as on time); past that it is passed over, and the
//   panel says why. A one-time task has no next slot, so its moment
//   waits for the run instead.

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
    /// A slot that was consumed WITHOUT running: catch-up was off, the
    /// slot was older than the catch-up window, or the task's previous
    /// run was still going (`lastMissedWhileRunning`). Surfaced in the
    /// panel so a silently-skipped run is still visible.
    var lastMissedSlot: Date?
    /// True when `lastMissedSlot` was passed over because the task's
    /// previous run was still going rather than missed while SipAI was
    /// closed — catch-up never makes that one up, and the panel says so.
    var lastMissedWhileRunning: Bool?
    /// The schedule `lastSlot` belongs to: the definition's
    /// `scheduleInForce` when this record was last written, "" while
    /// nothing was in force (paused, no schedule). Optional because a
    /// record written before it was kept has none — `decide` takes such
    /// a record to be about the schedule in force and stamps it.
    var scheduleInForce: String?
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

    /// How long after `start()` the FIRST due check runs. Not at once: a
    /// copy launched only to be looked at for a few seconds — the release
    /// script's launch check, a harness — runs on the real data folder
    /// (Foundation ignores $HOME for it), and an immediate check consumed
    /// a slot that fell due while SipAI was closed, recorded it as run,
    /// spawned the run and was killed over it. Every slot already
    /// tolerates `tickInterval` of lateness, so this costs nothing a user
    /// can see; `release.sh`'s launch check ends well inside it, and
    /// Verification/SparkleUpdate holds the two apart. A wake from sleep
    /// and a run ending still tick at once — only launch waits.
    private static let firstTickDelay: TimeInterval = 15
    private var firstTickTimer: Timer?

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

        // The first due check waits — see `firstTickDelay`. In the
        // common modes like the repeating timer above, so a menu or an
        // alert open at launch cannot hold it back.
        let first = Timer(timeInterval: Self.firstTickDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(first, forMode: .common)
        firstTickTimer = first
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

    /// A task definition as read off disk, with when its file was last
    /// written — `decide`'s `writtenAt`.
    struct LoadedDefinition {
        let definition: ScheduledTaskDefinition
        let writtenAt: Date?
    }

    /// Read every task definition off the main actor. Cheap — a handful
    /// of small files — but it is disk I/O on a timer, so it never runs
    /// on the main actor.
    nonisolated static func loadDefinitions() -> [LoadedDefinition] {
        let fm = FileManager.default
        let root = ScheduledAgentTaskScanner.taskRoot
        guard let dirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [LoadedDefinition] = []
        for dir in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let skill = dir.appendingPathComponent("SKILL.md")
            if let def = ScheduledTaskDefinition.read(
                name: dir.lastPathComponent, skillFile: skill) {
                // Read uncached: a URL's resource values are cached on the
                // URL object, and a stale date would misdate an edit.
                let written = (try? fm.attributesOfItem(atPath: skill.path))?[.modificationDate] as? Date
                out.append(LoadedDefinition(definition: def, writtenAt: written))
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
        /// The slot came while this task's previous run was still going,
        /// and that run has held it past the live window. Passed over,
        /// never queued behind the run.
        case skipWhileRunning(slot: Date)
        /// The schedule in force is not the one the run record belongs
        /// to — an edit, a pause, a resume, or a record kept before the
        /// schedule was recorded beside it. Record the one in force, and
        /// count its slots up to the moment it took effect (`slot`; nil
        /// when there were none, or none are known) as accounted for,
        /// WITHOUT running them.
        case scheduleChanged(slot: Date?)
    }

    /// The whole due rule, as a pure function of (definition, prior
    /// state, now). `evaluate` only applies whatever this returns,
    /// through `applying`.
    ///
    /// `writtenAt` is when the definition's file was last written — the
    /// latest moment a change to its schedule can have taken effect. It
    /// dates the change rather than the tick that first reads it, so a
    /// schedule saved moments before one of its own slots still owes
    /// that slot, and one changed while SipAI was closed owes the slots
    /// that passed after the change. nil (unreadable) means `now`.
    nonisolated static func decide(_ def: ScheduledTaskDefinition,
                                   state: ScheduledTaskRunState?,
                                   now: Date,
                                   isRunning: Bool,
                                   agentListed: Bool = true,
                                   writtenAt: Date? = nil,
                                   calendar: Calendar = .current) -> Decision {
        // An agent that is not LISTED — signed out, hidden in Settings
        // → Agent Guide, or gone — runs nothing: no slot is consumed,
        // nothing adopted, no missed slot recorded. When it is listed
        // again the ordinary rule sees a slot newer than `lastSlot`
        // and treats it exactly as a task the app was closed for.
        guard agentListed else { return .idle }

        // The schedule in force is not the one the record belongs to.
        // Its slots from before it took effect were never owed: counted
        // as missed, an edit or a resume would start a run on the spot.
        let inForce = def.scheduleInForce
        if let state, state.scheduleInForce != inForce {
            // A record kept before the schedule was recorded beside it
            // is taken to be about the schedule in force — stamped,
            // nothing else. Reading it as a change instead would count a
            // slot missed while SipAI was closed as the new schedule's
            // past and swallow its catch-up run.
            //
            // A one-time moment is never counted as accounted for, for
            // the reason it is never adopted: the pickers only offer
            // moments still ahead, so one already past when the change
            // is read came while SipAI was not looking, and the catch-up
            // rule decides it.
            guard state.scheduleInForce != nil, !inForce.isEmpty,
                  let schedule = def.schedule, !schedule.isOneTime
            else { return .scheduleChanged(slot: nil) }
            let tookEffect = min(writtenAt ?? now, now)
            return .scheduleChanged(slot: schedule.previousFireDate(
                onOrBefore: tookEffect, calendar: calendar))
        }

        guard def.enabled, let schedule = def.schedule else { return .idle }
        guard let slot = schedule.previousFireDate(onOrBefore: now,
                                                   calendar: calendar)
        else { return .idle }

        // First sighting of this task. Adopt the current slot WITHOUT
        // running: a task created at 14:00 with a 09:00 schedule must
        // not immediately fire for this morning, and the first launch
        // that SEES a task must not fire it for slots already in the
        // past.
        //
        // Never for a one-time schedule. Its only slot is the moment the
        // user picked, and the pickers only offer moments still ahead —
        // so before that moment there is no slot to adopt (the check
        // above has already answered idle), and a first sighting AFTER
        // it means the app was not running when it came. Adopting would
        // swallow the task's one run; the catch-up rule below decides it
        // instead, exactly as for a missed slot of a recurring task.
        if state == nil, !schedule.isOneTime { return .adopt(slot: slot) }

        if let last = state?.lastSlot, slot <= last { return .idle }

        let age = now.timeIntervalSince(slot)
        if isRunning {
            // The previous run is still going. Within the live window
            // the slot waits for it: a run that ends in time starts this
            // one a little late but on its slot. Past that it is passed
            // over — held until the run ended, it would start the next
            // run the moment the last one finished, and runs that outlast
            // the interval would follow each other back to back. A
            // one-time moment has no next slot, so it waits regardless.
            if schedule.isOneTime || age <= liveWindow { return .idle }
            return .skipWhileRunning(slot: slot)
        }
        if age <= liveWindow { return .fire(slot: slot) }
        if def.catchUpMissed && age <= catchUpWindow { return .fire(slot: slot) }
        return .skipMissed(slot: slot)
    }

    /// The run record once `decision` is applied — the bookkeeping half
    /// of the rule, pure for the same reason `decide` is. Every record it
    /// writes carries the schedule it belongs to, which is what lets the
    /// next `decide` tell a changed schedule from a missed slot. nil for
    /// `.idle`, which writes nothing.
    nonisolated static func applying(_ decision: Decision,
                                     to state: ScheduledTaskRunState?,
                                     definition def: ScheduledTaskDefinition) -> ScheduledTaskRunState? {
        var next = state ?? ScheduledTaskRunState()
        switch decision {
        case .idle:
            return nil
        case .adopt(let slot):
            next = ScheduledTaskRunState()
            next.lastSlot = slot
        case .scheduleChanged(let slot):
            // Never backwards: a schedule whose last slot before the
            // change is older than the mark leaves the mark where it is.
            if let slot { next.lastSlot = max(next.lastSlot ?? slot, slot) }
        case .fire(let slot):
            next.lastSlot = slot
            next.lastMissedSlot = nil
            next.lastMissedWhileRunning = nil
        case .skipMissed(let slot):
            next.lastSlot = slot
            next.lastMissedSlot = slot
            next.lastMissedWhileRunning = nil
        case .skipWhileRunning(let slot):
            next.lastSlot = slot
            next.lastMissedSlot = slot
            next.lastMissedWhileRunning = true
        }
        next.scheduleInForce = def.scheduleInForce
        return next
    }

    /// Where a one-time run stands, for the words the sidebar and the
    /// panel put beside it.
    enum OneTimeStatus: Equatable {
        /// Its moment is still ahead.
        case upcoming
        /// Its moment has passed and the scheduler has not dealt with it
        /// yet — the next tick, or an agent that is not listed right now.
        case due
        /// Its slot was consumed by a run (scheduled, or Run now after
        /// the moment passed).
        case ran
        /// Its slot passed unrun and will not be made up.
        case missed
    }

    /// Read off the same run record the due rule writes, so the label
    /// can never disagree with what the scheduler did.
    nonisolated static func oneTimeStatus(at moment: Date,
                                          state: ScheduledTaskRunState?,
                                          now: Date) -> OneTimeStatus {
        if moment > now { return .upcoming }
        // A run started at or after the moment settles it, whatever else
        // the record says — including Run now pressed after a miss.
        if let fired = state?.lastFiredAt, fired >= moment { return .ran }
        if let missed = state?.lastMissedSlot, missed >= moment { return .missed }
        guard let last = state?.lastSlot, last >= moment else { return .due }
        // Consumed by a fire that could not start (no prompt, the folder
        // gone): an attempt was made, and the panel names the failure.
        return .ran
    }

    /// `epoch` is the save epoch as it stood when this tick STARTED
    /// reading. A factory reset since then has deleted both the run
    /// records and the task files `defs` was read from, so applying
    /// this verdict would adopt slots for tasks that no longer exist —
    /// and `saveState` would write the file the wipe just removed.
    /// Definitions are re-read every tick, so dropping one costs
    /// nothing: the next tick is 30 s away.
    private func evaluate(_ defs: [LoadedDefinition], now: Date,
                          epoch: Int) {
        guard epoch == saveEpoch else { return }
        var dirty = false
        let listed = Set(agents?.listedAgents.map(\.key) ?? [])
        for loaded in defs {
            let def = loaded.definition
            let decision = Self.decide(def, state: states[def.name], now: now,
                                       isRunning: inFlight[def.name] != nil,
                                       agentListed: listed.contains(def.agent),
                                       writtenAt: loaded.writtenAt)
            guard let next = Self.applying(decision, to: states[def.name],
                                           definition: def) else { continue }
            states[def.name] = next
            if case .fire(let slot) = decision { fire(def, slot: slot, showRun: false) }
            dirty = true
        }
        if dirty { saveState() }
    }

    // MARK: - Firing

    /// Run a task now, outside its schedule. Used by the panel's Run
    /// now button; deliberately does NOT consume a slot, so pressing it
    /// never cancels the next scheduled run.
    ///
    /// `fromTaskPage`: pressed on the task's page, whose run then takes
    /// the page's place (`observe`). Pressed above one of the task's
    /// runs, the pane stays on that run.
    func runNow(_ def: ScheduledTaskDefinition, fromTaskPage: Bool) {
        fire(def, slot: nil, showRun: fromTaskPage)
    }

    /// True while this task has a run in flight.
    func isRunning(_ taskName: String) -> Bool {
        inFlight[taskName] != nil
    }

    private func fire(_ def: ScheduledTaskDefinition, slot: Date?, showRun: Bool) {
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
        // The backstop for the race between `decide` (which idles a
        // task whose agent is not listed) and this fire — an agent
        // unlisted in between. In ordinary operation it is never
        // reached; when it is, the run is recorded as an error that
        // names the reason.
        let taskAgent = def.agent
        let presence = agents.presence(for: taskAgent)
        guard presence == .listed else {
            // The label the user gave the agent, never the registry's
            // default outright — the rule every user-visible sentence
            // follows.
            let name = agents.agentLabel(for: taskAgent)
            state.lastOutcome = "error"
            switch presence {
            case .hiddenByUser:
                state.lastError = String(localized: "\(name) is hidden in SipAI.",
                                         comment: "Scheduled-run failure: the agent is unticked in Settings → Agent Guide")
            case .notInstalled:
                state.lastError = String(localized: "\(name) is not installed on this machine.",
                                         comment: "Scheduled-run failure: agent CLI missing")
            default:
                state.lastError = String(localized: "\(name) is installed but not signed in.",
                                         comment: "Scheduled-run failure: agent CLI lacks auth")
            }
            states[def.name] = state
            saveState()
            return
        }

        // A fresh draft per run: each firing is its own session, never a
        // --resume of the last one, so a task's runs stay independent
        // and its context doesn't grow without bound.
        var draft = ClaudeSessionDraft(cwd: cwd, name: def.description,
                                       agentKey: taskAgent)
        // Listed under its task, by the name the scanners will give it,
        // from the moment the run has a session id — not from the scan
        // that first reads the marker below off disk.
        draft.scheduledRun = ClaudeSessionDraft.ScheduledRunIdentity(
            taskName: def.name,
            title: AgentSessionScanner.title(fromPrompt: prompt) ?? def.description)
        let runner = agents.runner(forDraft: draft)

        // The task's own picks, speed included — never the composer's.
        let options = AgentLaunchOptions.scheduledRun(
            agent: taskAgent, mode: def.mode, model: def.model,
            effort: def.effort, fastMode: def.fastMode,
            serviceTier: def.serviceTier)

        // The marker is what makes the run findable: both scanners read
        // `<scheduled-task name="…">` out of the first user record and
        // file the session under its task. It is a PAIRED, EMPTY tag
        // with the prompt outside it — the display cleaners strip the
        // tag WITH its contents, so a prompt placed inside would vanish
        // from the transcript.
        let marked = "<scheduled-task name=\"\(def.name)\"></scheduled-task>\n\(prompt)"

        guard runner.send(text: marked, options: options) else {
            // `applying` has already advanced the slot; a record left
            // silent here would say nothing about a run that never
            // started.
            agents.releaseDraftRunner(draftId: draft.id)
            state.lastOutcome = "error"
            state.lastError = String(localized: "The run could not be started.",
                                     comment: "Scheduled-run failure: the runner refused to start the turn")
            states[def.name] = state
            saveState()
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
        // Every record carries the schedule it belongs to, as every
        // record `applying` writes does — a Run now before a one-time
        // moment included; a record with none reads as a schedule change
        // on the next tick.
        state.scheduleInForce = def.scheduleInForce
        states[def.name] = state
        saveState()

        observe(runner: runner, draft: draft, taskName: def.name, showRun: showRun)
    }

    /// Watch one run to completion: record the session id when it
    /// surfaces, the outcome when the turn ends, then drop the
    /// subscriptions.
    private func observe(runner: AgentRunner, draft: ClaudeSessionDraft,
                         taskName: String, showRun: Bool) {
        var bag = Set<AnyCancellable>()
        // The key `fire` filed this run under. Compared against the
        // entry, not against `runner.key`: the runner takes the session
        // id as its key once the id arrives, the entry keeps the draft's.
        let fireKey = runner.key

        runner.$sessionId
            .compactMap { $0 }
            .first()
            .sink { [weak self] sessionId in
                Task { @MainActor in
                    guard let self = self else { return }
                    // Still this task's run? A delete (`forget`) or a
                    // factory reset dropped the entry meanwhile, and a
                    // record written back under the dropped name would
                    // read as owed by a task recreated with it.
                    guard self.inFlight[taskName] == fireKey else {
                        self.agents?.releaseDraftRunner(draftId: draft.id)
                        return
                    }
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
                }
            }
            .store(in: &bag)

        // A Run now pressed on the task's page shows the run it started
        // in the page's place — while that page is still what the pane
        // shows. A run the SCHEDULE starts never moves the pane: the page
        // may be mid-edit, and an unsaved edit there goes with it. The run
        // is on the task's row the moment it starts.
        //
        // Woken by the FILE, not the id: a session is opened by its
        // transcript (`AgentSessionView.mode` needs the path), and the id
        // is announced before the transcript is written — routed on the
        // id, the pane stayed on the page while the run's row lit up.
        if showRun {
            runner.$sessionFileURL
                .compactMap { $0 }
                .first()
                .sink { [weak self] url in
                    Task { @MainActor in
                        guard let self = self,
                              self.inFlight[taskName] == fireKey,
                              let sessionId = runner.sessionId,
                              self.appState?.openScheduledTaskName == taskName,
                              self.appState?.openAgentSessionId == nil
                        else { return }
                        self.appState?.openAgentSessionId = sessionId
                        self.appState?.openAgentSessionPath = url
                    }
                }
                .store(in: &bag)
        }

        runner.$status
            .sink { [weak self] status in
                guard case .done(let code, let message) = status else { return }
                Task { @MainActor in
                    guard let self = self else { return }
                    guard self.inFlight[taskName] == fireKey else {
                        self.agents?.releaseDraftRunner(draftId: draft.id)
                        self.agents?.reloadSessions()
                        return
                    }
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
                    // A slot that came during this run was held for it
                    // (`liveWindow`). Judged only at the next 30 s tick
                    // it can be past the window by then and read as
                    // missed although the run ended in time — ask now.
                    self.tick()
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
        // The run in flight, if any, is no longer this task's business:
        // its observers would otherwise write a record back for the
        // deleted name when the turn ends — one with no slot in it,
        // which a task recreated under the same name would read as owed
        // and fire on the spot.
        runObservers.removeValue(forKey: taskName)
        inFlight.removeValue(forKey: taskName)
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
    /// folders under `~/.claude/scheduled-tasks`, which the reset
    /// empties separately. With no state left, `decide` reads each
    /// recurring task as a first sighting and ADOPTS its current slot
    /// instead of firing it. A one-time task is never adopted, so a
    /// definition that outlived its run record would be judged by the
    /// catch-up rule — which is why the definitions go with the reset.
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
