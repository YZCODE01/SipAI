// KimiAcpTurn.swift
// One kimi turn through kimi's own front end — Default (kimi's own
// configured mode), Ask When Needed, Plan — spoken over `kimi acp` (the
// rules are KimiAcp.swift). The runner owns
// the child and the end of the turn (`AgentRPCTurn`); this owns the
// conversation:
//
//   initialize → session/new or session/resume → session/set_mode (the
//   mode is the session's, and a headless turn leaves it on auto; not
//   for a new session on Default, which kimi has just opened in its own
//   configured mode, nor for Plan on a session already planning —
//   `KimiAcp.statedMode`) → session/set_model when the chip names one →
//   session/prompt — `/skill:name` ahead of the message when the turn
//   loads a chosen skill, kimi's own way to start one.
//
// While the prompt runs, kimi's requests become cards and the session's
// own record becomes the transcript (`KimiAcpWireFollow`). When the
// prompt is answered the record is read to its end; a background task
// still running, and the turn kimi starts on its own when it finishes,
// keep the child up until they are over — the transcript naming the task
// meanwhile — since kimi kills its tasks a few seconds after its stdin
// closes.

import Foundation

@MainActor
final class KimiAcpTurn: AgentRPCTurn {
    let arguments = KimiAcp.arguments
    let environment: [String: String]
    /// Measured: kimi's server writes each line through a pipe as it
    /// would through a terminal.
    let stdoutIsTerminal = false

    private let text: String
    /// The chosen skill this turn loads with the message, nil for none.
    private let skill: String?
    private let modeId: String
    /// The mode the turn was sent in, as the chip spells it (nil: Default).
    private let turnMode: String?
    /// Kimi's own configured default permission mode — what a resumed
    /// session on Default is told, and what a plan approval that continues
    /// in Default switches to, whatever mode the turn itself was sent in.
    private let defaultPermissionMode: String?
    private let model: String?
    private let agentName: String
    private let clientVersion: String

    private var sessionId: String?
    /// The session's record, read from where this turn began.
    private var reader: KimiSessionScanner.RecordReader?
    private var follow = KimiAcpWireFollow()
    /// Each call's input as kimi streamed it, by ACP call id — what a
    /// permission card shows, since kimi asks before it sends the
    /// parsed input.
    private var callArguments: [String: [String: Any]] = [:]
    /// The text kimi streamed for the prompt — the only record of an
    /// answer kimi gave ITSELF (a slash command), which it never writes.
    private var streamedText = ""
    /// How many failed turns have a row already — against the record's own
    /// count (`KimiAcpWireFollow.failureCount`).
    private var failuresShown = 0

    /// How far past kimi's OWN deadline for a background task the child is
    /// still kept up for it: kimi ends an overdue task itself, so past this
    /// its record of the task is not coming.
    private static let lingerMargin: TimeInterval = 120
    /// How long a finished task's turn is waited for once nothing else is
    /// going on. Kimi opens it about ten milliseconds after recording the
    /// task's end (measured); a task that gets no turn at all costs this
    /// long once.
    private static let noticeSettle: TimeInterval = 2
    /// How long kimi takes to stop its background tasks and exit once its
    /// stdin has closed (measured: five seconds), with a margin. A kimi
    /// that is SIGTERMed before then exits at once and leaves those tasks
    /// running with nobody to end them.
    private static let taskWindDown: TimeInterval = 8
    /// A poll of the record while the turn runs.
    private static let pollInterval: UInt64 = 200_000_000
    /// How long the record is given to show what a command kimi answered
    /// itself has started. `/compact` is answered first and begun after —
    /// its record lands about fifteen milliseconds behind the answer
    /// (measured) — and a child let go in between cancels it.
    private static let selfAnswerSettle: TimeInterval = 0.4

    /// nil unless `options` names a mode that runs through kimi's front
    /// end: Default (in kimi's own configured mode, `defaultPermissionMode`)
    /// or one of the asking modes — or the turn loads a chosen skill
    /// (`options.skillTriggers`), which only this front end can, in any
    /// mode (`KimiAcp.modeId(for:…loadingSkill:)`).
    init?(text: String, options: AgentLaunchOptions, environment: [String: String],
          agentName: String, clientVersion: String, defaultPermissionMode: String? = nil) {
        let skill = options.chatOnly ? nil : options.skillTriggers.first?.name
        guard let mode = KimiAcp.modeId(for: options.permissionMode,
                                        defaultPermissionMode: defaultPermissionMode,
                                        loadingSkill: skill != nil)
        else { return nil }
        self.text = text
        self.skill = skill
        self.modeId = mode
        self.turnMode = options.permissionMode
        self.defaultPermissionMode = defaultPermissionMode
        self.model = options.model.flatMap { $0.isEmpty ? nil : $0 }
        self.environment = environment
        self.agentName = agentName
        self.clientVersion = clientVersion
    }

    // MARK: - The turn

    func run(peer: JSONRPCLinePeer, host: AgentRPCHost) async {
        peer.onNotification = { [weak self] method, params in
            self?.notification(method: method, params: params)
        }
        peer.handle("session/request_permission") { [weak self, weak host, weak peer] inbound in
            guard let self, let host else {
                inbound.reply(KimiAcp.permissionReply(to: .cancelled, options: []))
                return
            }
            self.askPermission(inbound, host: host, peer: peer)
        }
        peer.handle("elicitation/create") { [weak self, weak host] inbound in
            guard let self, let host else {
                inbound.reply(KimiAcp.questionReply(to: .cancelled, form: nil))
                return
            }
            self.askQuestion(inbound, host: host)
        }

        var created: String? = nil
        var prompted = false
        // Kimi refused a step and gave no words for it.
        var refusedWithoutWords = false
        do {
            let hello = try await peer.request(
                "initialize", params: KimiAcp.initializeParams(clientVersion: clientVersion))
                as? [String: Any]
            guard (hello?["protocolVersion"] as? NSNumber)?.intValue == KimiAcp.protocolVersion else {
                endOnFailure(AgentAskingMode.unreadableAnswerMessage(agentName: agentName), host: host)
                return
            }
            let cwd = KimiWebTurn.resolvedPath(host.cwd)
            if let existing = host.sessionId, !existing.isEmpty {
                _ = try await peer.request(
                    "session/resume", params: KimiAcp.resumeParams(sessionId: existing, cwd: cwd))
                sessionId = existing
            } else {
                let answer = try await peer.request(
                    "session/new", params: KimiAcp.newSessionParams(cwd: cwd)) as? [String: Any]
                // A session opened without a name cannot be prompted — and
                // a turn that just stopped here would end without a word.
                guard let id = answer?["sessionId"] as? String, !id.isEmpty else {
                    endOnFailure(AgentAskingMode.unreadableAnswerMessage(agentName: agentName), host: host)
                    return
                }
                sessionId = id
                created = id
            }
            guard let sid = sessionId else { return }
            // The mode, where the turn states one (`KimiAcp.statedMode`).
            // Only a Plan turn's rests on the record.
            let planning = modeId == "plan" ? await sessionIsPlanning(sid) : false
            if let stated = KimiAcp.statedMode(modeId, isDefault: turnMode == nil,
                                               isNewSession: created != nil,
                                               planModeOn: planning) {
                do {
                    _ = try await peer.request("session/set_mode",
                                               params: ["sessionId": sid, "modeId": stated])
                } catch let failure as JSONRPCLinePeer.Failure {
                    // Kimi refuses `plan` for a session already in plan mode,
                    // which is the state the turn asked for — a session kimi
                    // opened in it (`default_plan_mode`), whose record had
                    // not said so yet. Anything else is a refusal.
                    guard case .remote = failure, stated == "plan",
                          await sessionIsPlanning(sid) else { throw failure }
                }
            }
            if let model {
                _ = try await peer.request("session/set_model",
                                           params: ["sessionId": sid, "modelId": model])
            }
            // Where the record is, and how long it is before this turn —
            // read BEFORE the last look at Stop, so nothing waits between
            // that look and the message going out.
            await locateWire(sessionId: sid)
            // Stopped while the session was being opened: nothing has been
            // asked, and a session made for this turn goes with it.
            guard host.turnIsLive else {
                if let created { _ = try? await peer.request("session/delete",
                                                             params: ["sessionId": created]) }
                return
            }
            // Named only now, when the message is about to go: a session
            // that is deleted above was never anybody's.
            if created != nil { host.adoptSession(id: sid) }
            prompted = true
            let poller = Task { @MainActor [weak self, weak host] in
                while !Task.isCancelled {
                    guard let self, let host else { return }
                    await self.readWire(host: host)
                    try? await Task.sleep(nanoseconds: Self.pollInterval)
                }
            }
            defer { poller.cancel() }
            _ = try await peer.request("session/prompt",
                                       params: KimiAcp.promptParams(
                                           sessionId: sid, text: KimiAcp.promptText(text, skill: skill)))
            // A skill kimi does not list: kimi answers the command itself
            // and runs no turn, so the message never reached the model.
            // Said, the row no longer naming a skill that did not load,
            // and the message sent again without it.
            if let skill {
                await readWire(host: host)
                if follow.promptsSeen == 0, KimiAcp.answeredUnknownCommand(streamedText), host.turnIsLive {
                    host.retractSkillLoads(nil)
                    host.emit([StreamEvent(kind: .error(message:
                        SkillLoadWords.notFound(agentName: agentName, skill: skill)))])
                    streamedText = ""
                    _ = try await peer.request("session/prompt",
                                               params: KimiAcp.promptParams(sessionId: sid, text: text))
                }
            }
        } catch let failure as JSONRPCLinePeer.Failure {
            if case .remote(_, let message) = failure {
                // Kimi refused a step, in its own words: the turn ends
                // here. The record's own account of the same failure (a
                // prompt the provider refused is both) is not said a
                // second time. With no words, the record is given the
                // chance to supply them first.
                let words = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if words.isEmpty {
                    refusedWithoutWords = true
                } else {
                    endOnFailure(words, host: host)
                    failuresShown = 1
                }
            }
            // A session made for this turn that never got its message is
            // nobody's: remove it, while kimi can still be asked to.
            if let created, !prompted, !peer.isClosed {
                _ = try? await peer.request("session/delete", params: ["sessionId": created])
            }
            // A closed conversation is the child ending: the runner says
            // whatever that needs.
        } catch {}

        guard prompted else {
            // Refused before the message went, wordlessly: nothing was
            // recorded, and a turn must not end without a row.
            if refusedWithoutWords {
                endOnFailure(AgentAskingMode.wordlessFailureMessage(agentName: agentName), host: host)
            }
            return
        }
        // The record holds the rest of the turn.
        await readWire(host: host)
        if follow.promptsSeen == 0 {
            // Kimi answered the prompt itself — nothing reached the model
            // and nothing was recorded — so its streamed words are the
            // whole answer. A notice, like any answer the harness gives.
            let answer = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty {
                host.emit([StreamEvent(kind: .userMessage(text: answer), isSystemNotice: true)])
            }
            // …and nothing was loaded: a message the user opened on a
            // skill command of their own was drawn as its words with the
            // skill named under them (`AgentRunner.send`), and kimi has
            // just said it knows no such command.
            host.retractSkillLoads(nil)
            // What such a command starts in the background, it starts after
            // answering: the record is given a moment to show it, so the
            // wait below can keep the child up for it.
            let settled = Date().addingTimeInterval(Self.selfAnswerSettle)
            while follow.compactionsBegun == 0, Date() < settled,
                  host.turnIsLive, !peer.isClosed {
                try? await Task.sleep(nanoseconds: 50_000_000)
                await readWire(host: host)
            }
        }
        reportFailure(host: host)
        // The prompt was refused without words and the record holds no
        // failed turn to say why: the sentence that says so.
        if refusedWithoutWords, failuresShown == 0 {
            failuresShown = 1
            endOnFailure(AgentAskingMode.wordlessFailureMessage(agentName: agentName), host: host)
        }

        // A background task the turn started: kimi runs a turn of its own
        // when it finishes, and kills it a few seconds after its stdin
        // closes. So the child stays up — the turn still running, Stop
        // still there — for as long as the record shows work that needs it
        // (`KimiAcpWireFollow.keepsChildUp`): an open turn, a task, a
        // compaction the user asked for.
        //
        // Only while there IS a child to keep up. A kimi that died mid-turn
        // leaves its turn open in the record for good (no `turn.ended` is
        // ever written), and waiting on that would hold a dead turn at
        // "running", with the runner unable to say what happened until
        // this returned.
        while host.turnIsLive, !peer.isClosed,
              follow.keepsChildUp(at: Date(), taskMargin: Self.lingerMargin,
                                  noticeSettle: Self.noticeSettle) {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            await readWire(host: host)
            reportFailure(host: host)
        }
    }

    func interrupt(peer: JSONRPCLinePeer) -> TimeInterval {
        // No session yet: it is still being opened, and one made for this
        // turn is removed as soon as it has been — which needs kimi alive.
        guard let sid = sessionId else { return 3 }
        // Kimi answers the prompt `cancelled` at once and records the
        // turn as cancelled; the conversation then ends as any other —
        // unless a background task is running, which kimi stops only as
        // it winds down.
        peer.notify("session/cancel", params: ["sessionId": sid])
        return follow.tasksPending ? Self.taskWindDown : 2
    }

    var exitGrace: TimeInterval {
        follow.tasksPending ? Self.taskWindDown : AgentRPCTurnDefaults.exitGrace
    }

    // MARK: - What kimi says while it works

    private func notification(method: String, params: Any?) {
        guard method == "session/update",
              let params = params as? [String: Any],
              let update = params["update"] as? [String: Any]
        else { return }
        if let call = KimiAcp.toolCallArguments(update: update) {
            callArguments[call.id] = call.arguments
        } else if let chunk = KimiAcp.messageChunk(update: update) {
            streamedText += chunk
        }
    }

    private func askPermission(_ inbound: JSONRPCLinePeer.Inbound, host: AgentRPCHost,
                               peer: JSONRPCLinePeer?) {
        let params = inbound.params as? [String: Any] ?? [:]
        let options = KimiAcp.options(in: params)
        let callId = (params["toolCall"] as? [String: Any])?["toolCallId"] as? String
        let cwd = KimiWebTurn.resolvedPath(host.cwd)
        guard let card = KimiAcp.permissionCard(params: params,
                                                arguments: callId.flatMap { callArguments[$0] },
                                                cwd: cwd, turnMode: turnMode) else {
            inbound.reply(KimiAcp.permissionReply(to: .cancelled, options: options))
            return
        }
        let defaultPermissionMode = self.defaultPermissionMode
        host.present(AgentCardRequest(
            toolName: card.toolName, toolInput: card.toolInput,
            presentation: card.presentation,
            respond: { [weak self, weak peer] resolution in
                inbound.reply(KimiAcp.permissionReply(to: resolution, options: options))
                // A plan approval that names the mode to continue in: the
                // mode is set right after kimi has its answer, so the rest
                // of this turn already runs in it (measured: a command after
                // the approval runs unasked under Ask When Needed and Never
                // Ask, and asks with no switch). The model's next step is a
                // request to the model away; the switch lands well before
                // it. Only a call the model made in the SAME step as its
                // ExitPlanMode is decided before the switch, in the mode the
                // plan was reviewed in: kimi asks about it.
                guard case .chose(let picked) = resolution,
                      let mode = PlanContinue.split(picked).mode,
                      let acpMode = KimiAcp.acpModeId(continuingIn: mode,
                                                      defaultPermissionMode: defaultPermissionMode),
                      let sid = self?.sessionId, let peer, !peer.isClosed
                else { return }
                Task { @MainActor in
                    _ = try? await peer.request("session/set_mode",
                                                params: ["sessionId": sid, "modeId": acpMode])
                }
            }))
    }

    private func askQuestion(_ inbound: JSONRPCLinePeer.Inbound, host: AgentRPCHost) {
        let params = inbound.params as? [String: Any] ?? [:]
        let form = KimiAcp.questionForm(params: params)
        host.present(AgentCardRequest(
            toolName: "AskUserQuestion", toolInput: params,
            presentation: .question, question: form,
            respond: { resolution in
                inbound.reply(KimiAcp.questionReply(to: resolution, form: form))
            }))
    }

    /// A failed turn's row, once per failed turn, in kimi's words — or,
    /// where kimi recorded none, in a sentence that says so.
    private func reportFailure(host: AgentRPCHost) {
        guard follow.failureCount > failuresShown else { return }
        failuresShown = follow.failureCount
        endOnFailure(follow.failure ?? AgentAskingMode.wordlessFailureMessage(agentName: agentName),
                     host: host)
    }

    /// The turn ends on a failure: its row, and the runner told, so the
    /// turn ends as failed — kimi answers a failed prompt as an ordinary
    /// end, and a scheduled run would be recorded "done" under the row.
    private func endOnFailure(_ message: String, host: AgentRPCHost) {
        host.emit([StreamEvent(kind: .error(message: message))])
        host.noteTurnFailed(message)
    }

    // MARK: - The session's record

    /// Whether the session's record leaves it IN plan mode right now
    /// (`KimiAcp.planModeLeftOn`). Off the main actor: the record is read.
    private func sessionIsPlanning(_ sessionId: String) async -> Bool {
        await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let dir = KimiSessionScanner.sessionDirectory(forId: sessionId) else { return false }
            return KimiAcp.planModeLeftOn(wire: KimiSessionScanner.wireFile(inSessionDir: dir))
        }.value
    }

    private func locateWire(sessionId: String) async {
        let found = await Task.detached(priority: .utility) { () -> (URL, UInt64)? in
            guard let dir = KimiSessionScanner.sessionDirectory(forId: sessionId) else { return nil }
            let url = KimiSessionScanner.wireFile(inSessionDir: dir)
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                        as? NSNumber)?.uint64Value ?? 0
            return (url, size)
        }.value
        guard let found else { return }
        let url = found.0
        // From here on everything in the record is this turn's.
        reader = KimiSessionScanner.RecordReader(offset: found.1) { from in
            await Task.detached(priority: .userInitiated) {
                KimiSessionScanner.RecordTail.read(url, from: from)
            }.value
        }
    }

    /// Read what kimi has added to the record since the last read, and
    /// put it on screen.
    private func readWire(host: AgentRPCHost) async {
        guard let reader else { return }
        let lines = await reader.newLines()
        guard !lines.isEmpty else { return }
        var events: [StreamEvent] = []
        for line in lines {
            events += follow.feed(line: line)
        }
        host.setNotice(follow.retryNotice)
        if let tokens = follow.contextTokens { host.noteContextUsage(tokens: tokens, window: nil) }
        if !events.isEmpty { host.emit(events) }
        // After the events: a task's notice and the turn it opens land
        // before the line naming it goes.
        host.setAwaitedBackgroundTasks(follow.awaitedTasks)
    }

    // MARK: - Leaving plan mode for a headless turn

    /// Ask kimi to take `sessionId` out of plan mode, over a fresh `kimi
    /// acp` behind `peer`: the handshake, the session resumed, its mode set
    /// to `default` — the request every Ask turn opens with, and no prompt.
    /// For a headless turn about to run on a session an ACP Plan turn left
    /// in plan mode (`KimiAcp.planModeLeftOn`). The conversation binds the
    /// session to ACP's runtime like any other, so the caller hands the
    /// binding back after the child is gone. False when kimi refused a
    /// step or the conversation ended first.
    static func leavePlanMode(peer: JSONRPCLinePeer, sessionId: String, cwd: String,
                              clientVersion: String) async -> Bool {
        do {
            let hello = try await peer.request(
                "initialize", params: KimiAcp.initializeParams(clientVersion: clientVersion),
                timeout: 15) as? [String: Any]
            guard (hello?["protocolVersion"] as? NSNumber)?.intValue == KimiAcp.protocolVersion
            else { return false }
            _ = try await peer.request("session/resume",
                                       params: KimiAcp.resumeParams(sessionId: sessionId, cwd: cwd),
                                       timeout: 15)
            _ = try await peer.request("session/set_mode",
                                       params: ["sessionId": sessionId, "modeId": "default"],
                                       timeout: 15)
            return true
        } catch {
            return false
        }
    }
}
