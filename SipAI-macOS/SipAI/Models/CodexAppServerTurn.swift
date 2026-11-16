// CodexAppServerTurn.swift
// One codex turn through codex's own front end — Default, Plan, or one of
// the fixed modes (Read Only, Workspace Write, Full Access) — spoken over
// `codex app-server` (the rules are CodexAppServer.swift). The runner
// owns the child and the end of the turn (`AgentRPCTurn`); this owns the
// conversation:
//
//   initialize → skills/extraRoots/set when a chosen skill lives in a
//   subfolder of the session's folder → thread/start (a new thread; its
//   answer is codex's own default for the folder: permissions, model,
//   effort, speed — a fixed mode's thread is started stating its own
//   permissions) or, for a resumed thread, a turnless thread/start to
//   ask for them — deleted as soon as it has answered — and thread/resume
//   stating them, or the fixed mode's → turn/start (the permissions,
//   model, effort, speed and collaboration mode stated every turn) → the
//   turn's items, codex's requests, and `turn/completed`.
//
// Codex's items are drawn through the parser every codex turn goes
// through, in the shape `codex exec --json` prints them, so a turn reads
// the same in either mode. The child's stdin stays open until the turn
// has completed: codex ends a turn whose stdin closes, at once — and
// stops a command still running in a background terminal, so a turn whose
// answer landed with one running is held until it ends (`heldTurn`).

import Foundation

@MainActor
final class CodexAppServerTurn: AgentRPCTurn {
    let arguments = CodexAppServer.arguments
    let environment: [String: String] = [:]
    /// Measured: each message is written as it is sent, through a pipe.
    let stdoutIsTerminal = false

    /// The message as the turn sends it. `var`: a turn that could not hand
    /// codex a subfolder's skills sends it without their mentions.
    private var text: String
    /// One of codex's own commands — its terminal's `/compact` and
    /// `/review` — which takes a turn of its own and no message; nil for a
    /// message's turn.
    private let command: CodexCommandTurn?
    private let mode: CodexAppServer.Mode
    /// A fixed mode's own permissions (`CodexAppServer.fixedPermissions`),
    /// stated in place of codex's default for the folder; nil for Default
    /// and Plan.
    private let fixed: CodexAppServer.Permissions?
    /// The skills folders of the session folder's SUBFOLDERS whose skills
    /// this turn loads: codex lists them, and the mention line loads
    /// one, only once they are added (`SkillSubfolderReach`).
    private let extraSkillRoots: [String]
    /// Those skills' names, and the message without their mentions —
    /// what the turn falls back to when codex will not take the folders:
    /// a mention codex cannot place loads nothing and says nothing, and
    /// left in the message it is read back as a load on reopen.
    private let subfolderSkills: [String]
    private let textWithoutSubfolderSkills: String
    /// How long codex is given to take those folders. It answers in
    /// milliseconds; one that has not by then is not going to.
    var extraRootsTimeout: TimeInterval = 10
    /// What the turn states, resolved once codex has answered for the
    /// folder (`CodexAppServer.turnSettings(… defaults:)`).
    private let settings: (CodexAppServer.Defaults) -> CodexAppServer.TurnSettings
    /// The faster speed the send pins (`codexServiceTierOverride`), named
    /// when the session is opened as well as on `turn/start`: opening is
    /// where codex says whether it can run it (`CodexSpeed.served`). nil
    /// for standard, flex, or no pin.
    private let speedPin: String?
    private let agentName: String
    private let clientVersion: String

    private var threadId: String?
    /// A thread made for this turn that is not the runner's session yet.
    /// It becomes one when codex ACCEPTS the turn (`adoptCreatedThread`):
    /// a thread codex has run no turn on has no rollout, and nothing — not
    /// `thread/resume`, not `codex exec resume` — can open it again, so an
    /// id adopted before a refused `turn/start` would leave the session
    /// failing every later message with "no rollout found".
    private var createdThread: String?
    private var turnId: String?
    private var turnRequested = false
    private var completed = false
    /// Stop was pressed: the turn's end is the runner's to report.
    private var stopped = false
    /// The user answered a request "No, and tell … what to do differently",
    /// which ends the turn.
    private var refusedByAnswer = false
    /// Each file change codex announced, by item id — what its approval
    /// card shows, since the request itself names only the item.
    private var fileChanges: [String: [CardFileChange]] = [:]
    /// The card each open request put up, by its JSON-RPC id — withdrawn
    /// when codex resolves the request itself (a Stop it was told about).
    private var openCards: [JSONRPCLinePeer.ID: String] = [:]
    /// The conversation, for the one message the driver sends of its own
    /// accord once the turn runs: an answer steered into it.
    private var peer: JSONRPCLinePeer?
    /// The messages that asked questions without stopping, each put on a
    /// card once (codex announces an item as it starts and as it ends).
    private var askedAsync: Set<String> = []
    /// Their cards while up, in the order asked — withdrawn when the turn
    /// is over, since codex takes no answer after that. What the user had
    /// started on them comes back for the message box in that order.
    private var asyncCards: [(messageId: String, cardId: String)] = []
    /// A plan codex cut out of the agent's message, drawn after the words
    /// around it.
    private var pendingPlan: String?
    /// The turn's plan, offered to carry out once the turn has completed.
    private var proposedPlan: String?
    /// The thread's running token totals before the turn and as of now.
    private var totalBefore: [String: Any]?
    private var totalNow: [String: Any]?
    /// The turn's commands, and whether the model has answered
    /// (`CodexBackgroundCommands`).
    private var commands = CodexBackgroundCommands()
    /// Codex ended the turn while a command it started still runs in a
    /// background terminal: what it said, held until the command ends.
    /// Codex does that at the answer one run and holds the turn open until
    /// the command ends the next (measured, the same command), and it
    /// stops the command the moment this conversation closes — so the turn
    /// is held here instead, the transcript naming the command, until codex
    /// says it has ended or that no terminal is left.
    private var heldTurn: [String: Any]?
    /// A review this turn runs has entered review mode: its end is said in
    /// codex's words too ("Code review finished"), as a reopen reads it.
    private var reviewEntered = false

    /// How long codex is given to end a turn once told to stop.
    private static let interruptGrace: TimeInterval = 3
    private static let pollInterval: UInt64 = 100_000_000
    /// How often codex is asked which terminals still run while a turn is
    /// held for one — beside its own word when a command ends.
    private static let terminalCheckInterval: UInt64 = 5_000_000_000

    /// nil unless `options` names a mode that runs through codex's front
    /// end: Default, Plan, or a fixed mode. A compaction runs in any mode
    /// — it touches no file — and in Chat only too, as codex's Default.
    init?(text: String, options: AgentLaunchOptions, command: CodexCommandTurn? = nil,
          extraSkillRoots: [String] = [],
          subfolderSkills: [String] = [], textWithoutSubfolderSkills: String? = nil,
          settings: @escaping (CodexAppServer.Defaults) -> CodexAppServer.TurnSettings,
          agentName: String, clientVersion: String) {
        // A compaction touches no file, and a shell command runs outside
        // the sandbox whatever the mode: both run in any mode, Chat only too.
        let anyMode: Bool = {
            switch command {
            case .compact?, .shell?: return true
            default: return false
            }
        }()
        guard let mode = CodexAppServer.mode(for: options.permissionMode)
                ?? (anyMode ? .defaultMode : nil) else { return nil }
        self.text = text
        self.command = command
        self.mode = mode
        self.fixed = CodexAppServer.fixedPermissions(for: options.permissionMode)
        self.extraSkillRoots = extraSkillRoots
        self.subfolderSkills = subfolderSkills
        self.textWithoutSubfolderSkills = textWithoutSubfolderSkills ?? text
        self.settings = settings
        self.speedPin = CodexSpeed.isFaster(options.codexServiceTierOverride)
            ? options.codexServiceTierOverride : nil
        self.agentName = agentName
        self.clientVersion = clientVersion
    }

    // MARK: - The turn

    func run(peer: JSONRPCLinePeer, host: AgentRPCHost) async {
        self.peer = peer
        peer.onNotification = { [weak self, weak host] method, params in
            guard let self, let host else { return }
            self.notification(method: method, params: params as? [String: Any] ?? [:], host: host)
        }
        peer.handle("item/commandExecution/requestApproval") { [weak self, weak host] inbound in
            guard let self, let host else {
                inbound.reply(CodexAppServer.decisionReply(to: .cancelled, choices: []))
                return
            }
            self.askCommand(inbound, host: host)
        }
        peer.handle("item/fileChange/requestApproval") { [weak self, weak host] inbound in
            guard let self, let host else {
                inbound.reply(CodexAppServer.decisionReply(to: .cancelled, choices: []))
                return
            }
            self.askFileChange(inbound, host: host)
        }
        peer.handle("item/tool/requestUserInput") { [weak self, weak host] inbound in
            guard let self, let host else {
                inbound.reply(CodexAppServer.questionReply(to: .cancelled, form: nil))
                return
            }
            self.askQuestion(inbound, host: host)
        }
        peer.handle("mcpServer/elicitation/request") { [weak self, weak host] inbound in
            guard let self, let host else {
                inbound.reply(CodexAppServer.elicitationReply(.cancel))
                return
            }
            self.askForServer(inbound, host: host)
        }
        // Answered as codex's own clients answer what they do not draw.
        peer.handle("item/permissions/requestApproval") { inbound in
            inbound.reply(CodexAppServer.permissionsDeclined)
        }
        // Anything else codex asks is answered "no such method" by the peer.

        do {
            _ = try await peer.request(
                "initialize", params: CodexAppServer.initializeParams(clientVersion: clientVersion))
            peer.notify("initialized")
            // A chosen skill in a subfolder: codex is told where it is
            // before the message names it — for this process, the one
            // this turn runs in. Refused or unanswered, the mention would
            // load nothing and say nothing: said, the row no longer naming
            // a skill that did not load, and the message sent without the
            // mention — the turn itself goes on. (Thrown on, an unanswered
            // call ended the turn with no row at all: the conversation was
            // still open, so the runner took the turn for finished.)
            if !extraSkillRoots.isEmpty {
                do {
                    _ = try await peer.request("skills/extraRoots/set",
                                               params: ["extraRoots": extraSkillRoots],
                                               timeout: extraRootsTimeout)
                } catch let failure as JSONRPCLinePeer.Failure {
                    let words: String
                    switch failure {
                    case .remote(_, let message):
                        words = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    case .timedOut:
                        words = ""
                    case .closed, .cancelled:
                        throw failure
                    }
                    host.retractSkillLoads(subfolderSkills)
                    host.emit([StreamEvent(kind: .error(message: words.isEmpty
                        ? String(localized: "\(agentName) couldn’t be given the subfolder’s skills, so your message was sent without them.",
                                 comment: "Runner error: Codex did not answer when handed the extra skill folders of a subfolder skill; placeholder is the agent label")
                        : String(localized: "\(agentName) couldn’t be given the subfolder’s skills: \(words)",
                                 comment: "Runner error: Codex refused the extra skill folders of a subfolder skill; placeholders are the agent label and Codex's words")))])
                    text = textWithoutSubfolderSkills
                }
            }
            let cwd = CodexConfigRead.physicalPath(host.cwd.path)
            let opened: [String: Any]?
            // Codex's own answer for the folder: what it starts a thread
            // with there.
            let folderAnswer: [String: Any]?
            let permissions: CodexAppServer.Permissions?
            var created = false
            if let existing = host.sessionId, !existing.isEmpty {
                // Codex's own default for the folder, from a thread that is
                // given no turn — stated on the resume, or the thread runs
                // on its last turn's approval policy. A fixed mode states
                // its own permissions and takes only the model, effort and
                // speed from the answer. The thread asked states nothing: a
                // resume records no folder trust, as `codex exec resume`
                // records none.
                let asked = try await peer.request(
                    "thread/start", params: CodexAppServer.threadStartParams(cwd: cwd))
                    as? [String: Any]
                // It has answered, and is let go at once: loaded, it keeps
                // a second set of the user's MCP servers running beside the
                // session's own for the whole turn. Never the session's own
                // thread; a codex that does not know the request refuses
                // it, and the thread then goes with the process.
                if let asking = (asked?["thread"] as? [String: Any])?["id"] as? String,
                   !asking.isEmpty, asking != existing {
                    _ = try? await peer.request(
                        "thread/delete",
                        params: CodexAppServer.threadDeleteParams(threadId: asking), timeout: 5)
                }
                folderAnswer = asked
                permissions = fixed ?? CodexAppServer.permissions(fromOpened: asked)
                if let permissions {
                    opened = try await peer.request(
                        "thread/resume",
                        params: CodexAppServer.threadResumeParams(threadId: existing, cwd: cwd,
                                                                  permissions: permissions,
                                                                  serviceTier: speedPin))
                        as? [String: Any]
                } else {
                    opened = nil
                }
                threadId = existing
            } else {
                opened = try await peer.request(
                    "thread/start", params: CodexAppServer.threadStartParams(cwd: cwd, stating: fixed,
                                                                             serviceTier: speedPin))
                    as? [String: Any]
                folderAnswer = opened
                permissions = fixed ?? CodexAppServer.permissions(fromOpened: opened)
                threadId = (opened?["thread"] as? [String: Any])?["id"] as? String
                created = true
            }
            // Permissions codex did not state cannot be stated back — and a
            // turn left to the thread's own would run on whatever ran last.
            guard let permissions else {
                endOnFailure(AgentAskingMode.unreadableAnswerMessage(agentName: agentName), host: host)
                return
            }
            // A thread opened without a name cannot be given a turn — and a
            // turn that just stopped here would end without a word.
            guard let tid = threadId, !tid.isEmpty else {
                endOnFailure(AgentAskingMode.unreadableAnswerMessage(agentName: agentName), host: host)
                return
            }
            // Whether codex will run the speed the message asks for, as it
            // said opening the session: the chip's bolt says so when it
            // will not.
            if command == nil, let pin = speedPin,
               let served = CodexSpeed.served(asked: pin, openAnswer: opened) {
                host.noteSpeed(asked: pin, served: served)
            }
            // What the chip leaves on Default is codex's own answer for
            // the folder, not the thread's: a resumed thread keeps the
            // model, effort and speed an earlier turn named.
            let settings = self.settings(CodexAppServer.defaults(fromOpened: folderAnswer))
            // The mode is stated with a model: the turn's, else the one
            // codex says the thread runs. With neither, the turn would run
            // in whatever mode the thread was left in — Plan as an editing
            // turn, Default as a planning one — so it is not sent at all.
            let threadModel = opened?["model"] as? String
            guard settings.model != nil || !(threadModel ?? "").isEmpty else {
                endOnFailure(AgentAskingMode.unreadableAnswerMessage(agentName: agentName), host: host)
                return
            }
            // Stopped while the thread was being opened: nothing has been
            // asked, and a thread codex has run no turn on leaves nothing
            // on disk.
            guard host.turnIsLive else { return }
            if created { createdThread = tid }
            turnRequested = true
            let answer: [String: Any]?
            switch command {
            case nil:
                answer = try await peer.request(
                    "turn/start",
                    params: CodexAppServer.turnStartParams(
                        threadId: tid, text: text, cwd: cwd, mode: mode, settings: settings,
                        permissions: permissions, threadModel: threadModel)) as? [String: Any]
            case .compact?:
                // Codex's `/compact`: a turn of its own, one compaction item,
                // no message. Its id arrives with `turn/started`.
                host.setCompacting(true)
                answer = try await peer.request(
                    "thread/compact/start",
                    params: CodexAppServer.compactStartParams(threadId: tid)) as? [String: Any]
            case .review(let target)?:
                answer = try await peer.request(
                    "review/start",
                    params: CodexAppServer.reviewStartParams(threadId: tid, target: target))
                    as? [String: Any]
            case .shell(let line)?:
                // Codex's `!`: the command runs outside the sandbox as a turn
                // of its own, with no model request, and the model reads it
                // with the next message (`CodexShellCommand`). Its id arrives
                // with `turn/started`.
                answer = try await peer.request(
                    "thread/shellCommand",
                    params: CodexShellCommand.params(threadId: tid, command: line)) as? [String: Any]
            }
            // Accepted: the thread has a turn, and with it a rollout.
            adoptCreatedThread(host: host)
            if turnId == nil {
                turnId = (answer?["turn"] as? [String: Any])?["id"] as? String
            }
            noteSteerable(host: host)
            // Stopped while the turn was being started: told now that its
            // id is known.
            if stopped { sendInterrupt(peer: peer) }
        } catch let failure as JSONRPCLinePeer.Failure {
            if case .remote(_, let message) = failure {
                // Codex refused a step, in its own words — or, with none,
                // in a sentence that says so: the turn ends here, and never
                // without a row.
                let words = message.trimmingCharacters(in: .whitespacesAndNewlines)
                endOnFailure(words.isEmpty
                    ? AgentAskingMode.wordlessFailureMessage(agentName: agentName) : words, host: host)
            }
            // A closed conversation is the child ending: the runner says
            // whatever that needs.
            return
        } catch {
            return
        }

        // The turn runs until codex says it is over, or the conversation
        // ends under it (the child gone, or killed after a Stop).
        while !completed, !peer.isClosed, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
    }

    func interrupt(peer: JSONRPCLinePeer) -> TimeInterval {
        stopped = true
        // Codex's own turn is over already; the conversation closing stops
        // the command it was held for.
        if heldTurn != nil {
            heldTurn = nil
            completed = true
            return Self.interruptGrace
        }
        sendInterrupt(peer: peer)
        return Self.interruptGrace
    }

    // MARK: - A message sent while the turn runs

    /// Whether codex takes a message steered into this turn now: a
    /// message's turn whose id is known, still codex's own — not held for
    /// a command it left in a background terminal, when codex answers "no
    /// active turn to steer" — and not stopped. A review or a compaction
    /// refuses one ("cannot steer a review turn").
    private var steerable: Bool {
        command == nil && turnId != nil && !completed && heldTurn == nil && !stopped
    }
    /// What the runner was last told (`AgentRPCHost.setSteerable`).
    private var steerableShown = false
    /// Messages steered into the turn that codex has not put into it yet,
    /// by their words: codex echoes each as a user message item at the step
    /// that takes it.
    private var steersInFlight: [String] = []

    private func noteSteerable(host: AgentRPCHost) {
        let now = steerable
        guard now != steerableShown else { return }
        steerableShown = now
        host.setSteerable(now)
    }

    /// `turn/steer` into this turn, named so it can never land in a later
    /// one: codex hands it to the model at its next step — after a command
    /// that is running finishes — and answers it in the same turn
    /// (measured). Its echo of the message is not drawn: the runner drew
    /// the row when the message went.
    func steer(text: String, peer: JSONRPCLinePeer) async -> String? {
        guard steerable, let threadId, let turnId, !peer.isClosed else { return "" }
        let key = ClaudeSteerTracker.key(text)
        steersInFlight.append(key)
        do {
            _ = try await peer.request(
                "turn/steer",
                params: CodexAppServer.steerParams(threadId: threadId, turnId: turnId, text: text),
                timeout: 10)
            return nil
        } catch {
            if let index = steersInFlight.firstIndex(of: key) { steersInFlight.remove(at: index) }
            if case JSONRPCLinePeer.Failure.remote(_, let message) = error {
                return message.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return ""
        }
    }

    /// Stop one command codex runs in a background terminal: codex lists
    /// it by the item that started it, and stops it by its process id. Its
    /// item then completes, failed, and a turn held only for it ends.
    func stopBackgroundTask(id: String, peer: JSONRPCLinePeer) async -> Bool {
        guard let threadId, !peer.isClosed,
              let listed = try? await peer.request(
                "thread/backgroundTerminals/list", params: ["threadId": threadId], timeout: 5)
                as? [String: Any],
              let processId = CodexAppServer.backgroundProcessId(itemId: id, inListAnswer: listed)
        else { return false }
        let answer = try? await peer.request(
            "thread/backgroundTerminals/terminate",
            params: CodexAppServer.terminateParams(threadId: threadId, processId: processId),
            timeout: 5) as? [String: Any]
        return (answer?["terminated"] as? Bool) == true
    }

    /// The thread made for this turn becomes the runner's session — once,
    /// at the first sign codex took the turn: `turn/started`, or the answer
    /// to `turn/start`, whichever is handled first. Both come before any
    /// item or request of the turn, so every card it asks for is filed
    /// under the session.
    private func adoptCreatedThread(host: AgentRPCHost) {
        guard let id = createdThread else { return }
        createdThread = nil
        host.adoptSession(id: id)
    }

    /// `turn/interrupt` once the turn has an id; until then the turn's
    /// start is still on its way, and the interrupt follows its answer.
    /// Codex completes the turn `interrupted` and withdraws what it asked.
    private func sendInterrupt(peer: JSONRPCLinePeer) {
        guard let threadId, let turnId, !completed else { return }
        let params: [String: Any] = ["threadId": threadId, "turnId": turnId]
        Task { _ = try? await peer.request("turn/interrupt", params: params, timeout: 5) }
    }

    // MARK: - What codex says while it works

    private func notification(method: String, params: [String: Any], host: AgentRPCHost) {
        // A file change's edits are kept whichever thread announced it: the
        // approval that follows names only the item, and one a subagent
        // asks for arrives here like any other — its card must show what
        // would be written.
        if method == "item/started" || method == "item/completed",
           let item = params["item"] as? [String: Any],
           (item["type"] as? String) == "fileChange", let id = item["id"] as? String {
            fileChanges[id] = CodexAppServer.fileChanges(fromItem: item)
        }
        // Codex's subagents run threads of their own on the same
        // connection; their items and usage are not this turn's.
        if let named = params["threadId"] as? String, let threadId, named != threadId { return }
        switch method {
        case "turn/started":
            adoptCreatedThread(host: host)
            if turnId == nil {
                turnId = (params["turn"] as? [String: Any])?["id"] as? String
            }
            noteSteerable(host: host)
        case "item/started", "item/completed":
            guard isThisTurn(params), let item = params["item"] as? [String: Any] else { return }
            if method == "item/completed", let plan = CodexAppServer.planText(of: item) {
                pendingPlan = plan
                proposedPlan = plan
                return
            }
            // The user's own shell command: drawn as its output under the
            // row the runner drew for it, never as a command of the model's.
            if case .shell? = command, CodexShellCommand.isUserShell(item) {
                if method == "item/completed" {
                    host.emit([StreamEvent(kind: .shellOutput(
                        CodexShellCommand.output(fromItem: item, stopped: stopped)))])
                }
                return
            }
            switch item["type"] as? String {
            case "contextCompaction":
                // The summarising is under way until its item completes;
                // the row is the parser's, below.
                host.setCompacting(method == "item/started")
            case "enteredReviewMode" where method == "item/completed":
                // Codex's ">> Code review started: <what> <<" — the review
                // itself runs in a sub-thread of its own, whose items are
                // not this turn's; what reaches this one is codex's message
                // with the review.
                reviewEntered = true
                let what = (item["review"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                host.emit([StreamEvent(kind: .userMessage(text: CodexReviewWords.started(what)),
                                       isSystemNotice: true)])
                return
            default:
                break
            }
            // Codex echoes every user message of the turn. The prompt's own
            // echo is never drawn — the runner drew it as it was sent — but
            // an answer steered into the turn is the user's reply, drawn as
            // codex's terminal draws it.
            if (item["type"] as? String) == "userMessage" {
                let text = CodexSessionScanner.userText(fromContent: item["content"] as? [Any] ?? [])
                if method == "item/completed",
                   let reply = CodexSessionScanner.questionReplyDisplay(of: text) {
                    host.emit([StreamEvent(kind: .userMessage(text: reply), sentIntoTurn: true,
                                           belongsToAnswer: true)])
                } else if method == "item/completed",
                          let index = steersInFlight.firstIndex(of: ClaudeSteerTracker.key(text)) {
                    // A message steered into the turn, put in at this step:
                    // its row goes here, as the rollout places it.
                    steersInFlight.remove(at: index)
                    host.steerTaken(text: text)
                }
                return
            }
            let exec = CodexAppServer.execEvents(method: method, params: params)
            for object in exec { commands.read(object: object) }
            var events = parsed(exec, host: host).events
            // The plan follows the words codex cut it out of.
            if method == "item/completed", (item["type"] as? String) == "agentMessage",
               let plan = pendingPlan {
                pendingPlan = nil
                events.append(StreamEvent(kind: .assistantText(text: plan)))
            }
            // Real output: whatever codex was retrying, it got through. The
            // notice is the state of the connection, not a log of it — the
            // same rule a headless turn's stdout follows.
            if !events.isEmpty { host.setNotice(nil) }
            host.emit(events)
            // The commands the answer waits on, after the rows: a command's
            // output lands before the line naming it goes. The last one
            // ending lets a held turn end.
            if let held = heldTurn, commands.running.isEmpty {
                heldTurn = nil
                host.setAwaitedBackgroundTasks([])
                turnCompleted(held, host: host)
            } else {
                host.setAwaitedBackgroundTasks(heldTurn != nil ? commands.running : commands.awaited)
            }
            // A question asked without stopping: its text is drawn above,
            // and it goes on a card — once, though codex announces the
            // message as it starts and as it ends.
            if method == "item/completed",
               let form = CodexAppServer.asyncQuestionForm(item: item),
               let id = item["id"] as? String, askedAsync.insert(id).inserted {
                askWithoutStopping(form: form, item: item, messageId: id, host: host)
            }
        case "error":
            guard isThisTurn(params) else { return }
            let notice = parsed(CodexAppServer.execEvents(method: method, params: params),
                                host: host).notice
            if let notice { host.setNotice(notice) }
        case "thread/tokenUsage/updated":
            let total = (params["tokenUsage"] as? [String: Any])?["total"] as? [String: Any]
            if turnRequested { totalNow = total } else { totalBefore = total }
        case "serverRequest/resolved":
            if let id = JSONRPCLinePeer.ID(params["requestId"]),
               let card = openCards.removeValue(forKey: id) {
                host.withdraw(cardId: card)
            }
        case "turn/completed":
            guard isThisTurn(params) else { return }
            codexEndedTurn(params["turn"] as? [String: Any] ?? [:], host: host)
        default:
            break
        }
    }

    /// Whether a notification is about this turn. Before codex has named
    /// the turn everything is; a notification naming another turn is not.
    private func isThisTurn(_ params: [String: Any]) -> Bool {
        guard let turnId else { return true }
        if let named = params["turnId"] as? String { return named == turnId }
        if let turn = params["turn"] as? [String: Any], let named = turn["id"] as? String {
            return named == turnId
        }
        return true
    }

    /// Codex says the turn is over. Ended at the answer with a command still
    /// running, it is held until the command ends (`heldTurn`); a turn that
    /// failed or was stopped is not — its command goes with the
    /// conversation.
    private func codexEndedTurn(_ turn: [String: Any], host: AgentRPCHost) {
        guard !completed, heldTurn == nil else { return }
        if (turn["status"] as? String) == "completed", !stopped, !commands.running.isEmpty {
            heldTurn = turn
            // Codex takes no answer once its turn is over, held or not —
            // and no message steered into it.
            withdrawAsyncCards(host: host)
            noteSteerable(host: host)
            host.setNotice(nil)
            host.setAwaitedBackgroundTasks(commands.running)
            watchTerminals(host: host)
            return
        }
        turnCompleted(turn, host: host)
    }

    /// While a turn is held for a command: codex is asked now and then
    /// which terminals still run, so a command that ended without codex
    /// saying so does not hold the turn for good. A codex that does not
    /// know the request is left to say when the command ends.
    private func watchTerminals(host: AgentRPCHost) {
        guard let peer, let threadId else { return }
        Task { @MainActor [weak self, weak host] in
            while true {
                try? await Task.sleep(nanoseconds: Self.terminalCheckInterval)
                guard let self, let host, self.heldTurn != nil, !peer.isClosed else { return }
                guard let answer = try? await peer.request(
                        "thread/backgroundTerminals/list", params: ["threadId": threadId], timeout: 5)
                        as? [String: Any],
                      let listed = answer["data"] as? [[String: Any]]
                else { return }
                let still = Set(listed.compactMap { $0["itemId"] as? String })
                guard let held = self.heldTurn,
                      !self.commands.running.contains(where: { still.contains($0.id) })
                else { continue }
                self.heldTurn = nil
                host.setAwaitedBackgroundTasks([])
                self.turnCompleted(held, host: host)
                return
            }
        }
    }

    private func turnCompleted(_ turn: [String: Any], host: AgentRPCHost) {
        guard !completed else { return }
        completed = true
        withdrawAsyncCards(host: host)
        noteSteerable(host: host)
        host.setCompacting(false)
        var events: [StreamEvent] = []
        if let plan = pendingPlan {
            pendingPlan = nil
            events.append(StreamEvent(kind: .assistantText(text: plan)))
        }
        // Codex's "<< Code review finished >>", after the review it wrote.
        if reviewEntered, (turn["status"] as? String) == "completed" {
            events.append(StreamEvent(kind: .userMessage(text: CodexReviewWords.finished),
                                      isSystemNotice: true))
        }
        host.setNotice(nil)
        switch turn["status"] as? String {
        case "failed":
            let message = ((turn["error"] as? [String: Any])?["message"] as? String) ?? ""
            let failure = parsed([["type": "turn.failed", "error": ["message": message]]],
                                 host: host).events
            events += failure
            // Said by its row, in exactly those words: the runner ends the
            // turn as failed on them.
            for case .error(let words) in failure.map(\.kind) {
                host.noteTurnFailed(words)
            }
        case "interrupted":
            // Stop has its own row; a refusal that ended the turn says so.
            // And when nobody stopped it and nobody refused it — a request
            // that could not be put on a card was answered `cancel`, which
            // ends the turn — it still must not end without a row.
            if !stopped {
                events.append(StreamEvent(kind: .interrupted(message: refusedByAnswer
                    ? String(localized: "Stopped at your answer — tell \(agentName) what to do differently in your next message.",
                             comment: "Transcript row after the user answered a codex approval with “No, and tell … what to do differently”, which ends the turn; placeholder is the agent label")
                    : String(localized: "Interrupted — this turn was stopped before it finished.",
                             comment: "Transcript row after the user stops a running turn"))))
            }
        default:
            let usage = CodexAppServer.turnUsage(totalBefore: totalBefore, totalAfter: totalNow)
            events += parsed([["type": "turn.completed",
                               "usage": ["input_tokens": usage.input,
                                         "output_tokens": usage.output]]],
                             host: host).events
        }
        host.emit(events)
        // A finished Plan turn's plan: codex's terminal asks whether to
        // carry it out, and so does SipAI. A Plan turn's alone — the answer
        // is "leave Plan mode", which no other turn is in.
        if mode == .plan, (turn["status"] as? String) == "completed", let plan = proposedPlan {
            host.offerPlanFollowUp(plan)
        }
    }

    /// The turn ends on a failure: its row, and the runner told, so the
    /// turn ends as failed — codex's protocol answers such a turn as an
    /// ordinary end, and a scheduled run would be recorded "done" under the
    /// row.
    private func endOnFailure(_ message: String, host: AgentRPCHost) {
        host.emit([StreamEvent(kind: .error(message: message))])
        host.noteTurnFailed(message)
    }

    private func parsed(_ objects: [[String: Any]], host: AgentRPCHost)
    -> CodexEventParser.Parsed {
        var out = CodexEventParser.Parsed()
        for object in objects {
            // A reasoning summary is kept while compact view can draw it
            // (codex writes one only where its own config asks for them).
            let one = CodexEventParser.parse(object: object, fallbackCwd: host.cwd,
                                             includeThinking: CompactTranscript.isOn)
            out.events += one.events
            if let notice = one.notice { out.notice = notice }
        }
        return out
    }

    // MARK: - Codex's requests

    private func askCommand(_ inbound: JSONRPCLinePeer.Inbound, host: AgentRPCHost) {
        let params = inbound.params as? [String: Any] ?? [:]
        guard let card = CodexAppServer.commandCard(params: params, agentName: agentName),
              case .permission(let content) = card.presentation else {
            inbound.reply(CodexAppServer.decisionReply(to: .cancelled, choices: []))
            return
        }
        present(card, inbound: inbound, host: host) { resolution in
            CodexAppServer.decisionReply(to: resolution, choices: content.choices)
        }
    }

    private func askFileChange(_ inbound: JSONRPCLinePeer.Inbound, host: AgentRPCHost) {
        let params = inbound.params as? [String: Any] ?? [:]
        let changes = (params["itemId"] as? String).flatMap { fileChanges[$0] }
        let card = CodexAppServer.fileChangeCard(params: params, changes: changes,
                                                 agentName: agentName)
        let choices = CodexAppServer.fileChangeChoices(agentName: agentName)
        present(card, inbound: inbound, host: host) { resolution in
            CodexAppServer.decisionReply(to: resolution, choices: choices)
        }
    }

    private func askQuestion(_ inbound: JSONRPCLinePeer.Inbound, host: AgentRPCHost) {
        let params = inbound.params as? [String: Any] ?? [:]
        let form = CodexAppServer.questionForm(params: params)
        let id = inbound.id
        let cardId = host.present(AgentCardRequest(
            toolName: "request_user_input", toolInput: params,
            presentation: .question, question: form,
            respond: { [weak self] resolution in
                self?.openCards.removeValue(forKey: id)
                inbound.reply(CodexAppServer.questionReply(to: resolution, form: form))
            }))
        if let cardId, !inbound.isAnswered { openCards[id] = cardId }
    }

    /// What an MCP server asks mid-call — its form, a link to open — or
    /// codex's own approval before it runs one of the server's tools: a
    /// card (`McpElicitation`), its answer the server's reply. A request
    /// SipAI does not draw is declined, as codex's own terminal declines
    /// what it cannot draw. None of these answers ends the turn: codex
    /// tells the model the tool was refused or cancelled, and goes on.
    private func askForServer(_ inbound: JSONRPCLinePeer.Inbound, host: AgentRPCHost) {
        let params = inbound.params as? [String: Any] ?? [:]
        guard let request = McpElicitation.Request(codexParams: params),
              let card = McpElicitation.card(
                for: request, sessionNote: CodexAppServer.Words.toolSessionLine,
                alwaysNote: CodexAppServer.Words.toolAlwaysLine(agentName))
        else {
            inbound.reply(CodexAppServer.elicitationReply(.decline))
            return
        }
        let id = inbound.id
        let cardId = host.present(AgentCardRequest(
            toolName: request.serverName, toolInput: params,
            presentation: card.presentation, question: card.question,
            respond: { [weak self] resolution in
                self?.openCards.removeValue(forKey: id)
                inbound.reply(CodexAppServer.elicitationReply(
                    McpElicitation.answer(for: resolution, to: card)))
            }))
        if let cardId, !inbound.isAnswered { openCards[id] = cardId }
    }

    /// A question codex asked without stopping, on a card the turn does not
    /// wait on: codex works on while it is up. An answer is steered into
    /// THIS turn as codex's own clients' reply; Skip, Non-stop and Stop send
    /// nothing, and codex goes on with its own judgment, as its
    /// instructions tell it to.
    private func askWithoutStopping(form: AgentQuestionForm, item: [String: Any],
                                    messageId: String, host: AgentRPCHost) {
        guard let threadId, let turnId else { return }
        let name = agentName
        var answeredAtOnce = false
        let cardId = host.present(AgentCardRequest(
            toolName: CodexAppServer.asyncQuestionTool, toolInput: item,
            presentation: .question, question: form, turnWaits: false,
            respond: { [weak self, weak host] resolution in
                answeredAtOnce = true
                guard let self else { return }
                self.asyncCards.removeAll { $0.messageId == messageId }
                guard case .answered(let answers) = resolution,
                      let text = CodexAppServer.asyncReplyText(form: form, answers: answers),
                      let peer = self.peer, !peer.isClosed else { return }
                let params = CodexAppServer.steerParams(threadId: threadId, turnId: turnId, text: text)
                Task { @MainActor [weak host] in
                    do {
                        _ = try await peer.request("turn/steer", params: params)
                    } catch JSONRPCLinePeer.Failure.remote(_, let message) {
                        // Refused — the turn ended as the answer went —
                        // in codex's own words.
                        let words = message.trimmingCharacters(in: .whitespacesAndNewlines)
                        host?.emit([StreamEvent(kind: .error(message: words.isEmpty
                            ? AgentAskingMode.wordlessFailureMessage(agentName: name)
                            : String(localized: "Couldn’t send your answer to \(name): \(words)",
                                     comment: "Transcript row when Codex refuses the user's answer to a question it asked without stopping; placeholders are the agent label and Codex's words")))])
                    } catch {
                        // The conversation is over: the runner says
                        // whatever the turn's end needs.
                    }
                }
            }))
        // A card answered at once — declined under Non-stop, or a turn no
        // longer live — is not up.
        if let cardId, !answeredAtOnce { asyncCards.append((messageId, cardId)) }
    }

    /// The turn is over: codex takes no answer now, so the cards its
    /// questions put up go unanswered. A question stays the agent's text
    /// in the transcript, to answer in the next message — and what the
    /// user had started on its card comes back for the message box, as
    /// Codex's own terminal hands it back (the bridge, on the withdrawal).
    private func withdrawAsyncCards(host: AgentRPCHost) {
        let cards = asyncCards.map(\.cardId)
        asyncCards.removeAll()
        for card in cards { host.withdraw(cardId: card) }
    }

    private func present(_ card: CodexAppServer.Card, inbound: JSONRPCLinePeer.Inbound,
                         host: AgentRPCHost,
                         reply: @escaping @MainActor (CardResolution) -> [String: Any]) {
        let id = inbound.id
        let cardId = host.present(AgentCardRequest(
            toolName: card.toolName, toolInput: card.toolInput,
            presentation: card.presentation,
            respond: { [weak self] resolution in
                self?.openCards.removeValue(forKey: id)
                if case .chose("cancel") = resolution { self?.refusedByAnswer = true }
                inbound.reply(reply(resolution))
            }))
        // A card answered at once (Stop already pressed, a card that could
        // not be drawn) is not open.
        if let cardId, !inbound.isAnswered { openCards[id] = cardId }
    }

    // MARK: - Leaving plan mode for a headless turn

    /// Put `threadId` back in the Default collaboration mode over a fresh
    /// `codex app-server` behind `peer`: the handshake, the thread resumed,
    /// its settings updated — no turn, no model request. For a `codex exec`
    /// turn about to run on a thread a Plan turn left in plan mode
    /// (`CodexAppServer.planModeLeftOn`), which would otherwise run under
    /// the plan instructions. False when codex refused a step or the
    /// conversation ended first.
    static func leavePlanMode(peer: JSONRPCLinePeer, threadId: String, cwd: String,
                              model: String, clientVersion: String) async -> Bool {
        do {
            _ = try await peer.request(
                "initialize", params: CodexAppServer.initializeParams(clientVersion: clientVersion),
                timeout: 15)
            peer.notify("initialized")
            _ = try await peer.request(
                "thread/resume",
                params: CodexAppServer.plainResumeParams(threadId: threadId, cwd: cwd),
                timeout: 15)
            _ = try await peer.request(
                "thread/settings/update",
                params: CodexAppServer.leavePlanModeParams(threadId: threadId, model: model),
                timeout: 15)
            return true
        } catch {
            return false
        }
    }
}
