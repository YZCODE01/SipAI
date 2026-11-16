// KimiAcp.swift
// The rules a kimi turn in an asking mode runs by. Such a turn goes
// through `kimi acp` — kimi's own Agent Client Protocol server on the
// child's stdin and stdout — because that is the front end through which
// kimi ASKS: a permission (`session/request_permission`), a plan to
// review (the same request, with plan answers), a question
// (`elicitation/create`). `kimi --prompt` approves everything itself and
// can ask nothing.
//
// Foundation only, and free of the runner and the views, so the
// harnesses compile it with the readers it leans on.
//
// What this file decides, each rule read out of kimi's own ACP server
// (bundled in its binary) and measured against it:
//
//  * which ACP mode each asking mode is (`modeId(for:)`);
//  * the card a request becomes, in kimi's words (`permissionCard`,
//    `questionForm`) — and the reply each answer is (`permissionReply`,
//    `questionReply`). An answer is never an error reply: kimi reads a
//    failed request as a reason to ask AGAIN another way;
//  * what the session's own record says while the turn runs
//    (`KimiAcpWireFollow`) — the transcript is drawn from it, through the
//    reader a reopened session uses, so a live turn and the same turn
//    reopened read alike;
//  * that an ACP turn's session is handed back to kimi's local runtime
//    when the turn is over — the rule itself is `KimiRuntimeBinding`
//    (KimiSessions.swift), beside the reader, because a branch of the
//    session needs it too. An ACP turn binds the session to ITS runtime,
//    and kimi replays the last binding whenever the session is opened
//    again — under that binding kimi's own terminal, and SipAI's next
//    headless turn, run it without Bash, Write, Edit, Glob, Grep or Agent.
//    Kimi still lists them to the model, and answers `Tool "Bash" not
//    found` only when one is called.

import Foundation

enum KimiAcp {

    // MARK: - The conversation

    /// The ACP version kimi speaks. `initialize` answers with it; another
    /// number is a protocol this file was not written against.
    static let protocolVersion = 1

    /// The child: kimi's ACP server on stdio. Its stdout carries one JSON
    /// value per line and is flushed per line through a pipe (measured
    /// against a terminal: the same arrival times), so it needs no
    /// terminal of its own.
    static let arguments = ["acp"]

    /// What SipAI declares. No file system and no terminal — kimi then
    /// reads, writes and runs commands itself, as its headless run does —
    /// and forms, which is what lets kimi ask a whole question set at
    /// once (without them it asks the first question alone).
    static func initializeParams(clientVersion: String) -> [String: Any] {
        [
            "protocolVersion": protocolVersion,
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false,
                "elicitation": ["form": [String: Any]()],
            ] as [String: Any],
            "clientInfo": ["name": "SipAI", "version": clientVersion],
        ]
    }

    /// The ACP mode a turn runs in — kimi's own table (`acpModeToToggles`):
    /// `default` is Always Ask (`manual`), `yolo` is Ask When Needed, `auto`
    /// is Never Ask, `plan` is plan mode with Always Ask's permissions.
    /// Default (nil) is kimi's own configured default permission mode
    /// (`KimiCatalog.readDefaultPermissionMode`), else Always Ask. nil for
    /// a mode that never runs through ACP.
    ///
    /// Kimi applies its config to a session it CREATES — the permission
    /// mode and `default_plan_mode` both (measured; the mode its ACP server
    /// reports is `default` whatever was applied) — and a session keeps the
    /// mode its last turn set. So a new session on Default is left as kimi
    /// opened it, and only a resumed one is told the config's mode
    /// (`statedMode`). `default_plan_mode` is never stated: it is a mode
    /// kimi starts a session in, and stated on every turn it would never
    /// let a session leave planning.
    ///
    /// `loadingSkill`: the turn loads a skill, which only this front end
    /// can (`AgentTurnDriver.pick`) — so a mode that otherwise runs
    /// headless (Never Ask, and any value a kimi chip reads as it) runs
    /// here in kimi's own Never Ask, `auto`.
    static func modeId(for mode: String?, defaultPermissionMode: String? = nil,
                       loadingSkill: Bool = false) -> String? {
        switch mode {
        case nil: return acpModeId(forPermission: defaultPermissionMode)
        case AgentAskingMode.kimiAskWhenNeeded: return "yolo"
        case AgentAskingMode.kimiPlan: return "plan"
        default: return loadingSkill ? "auto" : nil
        }
    }

    /// The prompt that loads `skill` with the user's message: kimi's own
    /// `/skill:name text`, which its front end reads as ONE leading
    /// command — the skill, with the message as its input, in one model
    /// request (measured). The text alone when nothing loads.
    static func promptText(_ text: String, skill: String?) -> String {
        guard let skill, !skill.isEmpty else { return text }
        return "/skill:" + skill + " " + text
    }

    /// A prompt as kimi's front end reads it for a command — its own
    /// parser, read in its bundle (`parseSlashInput`): it opens with "/",
    /// the name runs to the FIRST SPACE — a space, not any white space —
    /// and the rest, trimmed, is the command's input; a name with a slash
    /// in it is a path and no command. Nil for anything else.
    ///
    /// Spelled as kimi spells it because the two must agree on what a
    /// message IS. Split at any white space, `/skill:alpha` followed by a
    /// line break and the words read here as skill alpha with those words
    /// — and to kimi as one long command name it does not know: the row
    /// named a skill and showed the words as sent, and kimi had answered
    /// "Unknown ACP command" with nothing sent at all.
    static func slashCommand(_ text: String) -> (name: String, args: String)? {
        guard text.hasPrefix("/") else { return nil }
        let trimmed = text.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let name: Substring
        let args: String
        if let space = trimmed.firstIndex(of: " ") {
            name = trimmed[..<space]
            args = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            name = trimmed[...]
            args = ""
        }
        guard !name.contains("/") else { return nil }
        return (String(name), args)
    }

    /// A message kimi's front end starts a skill from, with words after
    /// the command — how such an activation is DRAWN, live and reopened
    /// alike: the words, with the skill named under them (the reader's
    /// `KimiSessionScanner.skillActivation`). Nil for anything else, and
    /// for a command with nothing after it, which is drawn as typed.
    ///
    /// Kimi takes a skill by `/skill:name` and by its bare name alike
    /// (the name is looked up in its skill list as given, then with the
    /// prefix): `isSkill` answers whether a bare name is one of this
    /// session's skills, so `/alpha words` reads as what it does.
    static func typedSkill(_ text: String,
                           isSkill: (String) -> Bool = { _ in false }) -> (name: String, message: String)? {
        // A name kimi read across a line break or a tab is no skill's: it
        // answers such a command itself, as one it does not know.
        guard let command = slashCommand(text), !command.args.isEmpty,
              !command.name.contains(where: \.isWhitespace) else { return nil }
        if command.name.hasPrefix("skill:") {
            let name = String(command.name.dropFirst("skill:".count))
            return name.isEmpty ? nil : (name, command.args)
        }
        return isSkill(command.name) ? (command.name, command.args) : nil
    }

    /// Whether kimi answered the prompt ITSELF as a command it does not
    /// know — what a `/skill:` for a skill kimi does not list gets, with
    /// no turn run: the message never reached the model.
    static func answeredUnknownCommand(_ streamed: String) -> Bool {
        streamed.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Unknown ACP command:")
    }

    /// The mode a turn states with `session/set_mode`, or nil when it
    /// states none.
    ///
    /// * A NEW session on Default: none. Kimi has just applied its own
    ///   config to it; a mode stated over that cancels the plan mode a
    ///   `default_plan_mode` config opened it in, and puts SipAI's reading
    ///   of the config in place of kimi's.
    /// * Plan, on a session already in plan mode: none. Kimi refuses a
    ///   second `plan` ("Already in plan mode", an Internal error), and a
    ///   session is still in plan mode after Revise, after a review that
    ///   was stopped, and after a Plan turn the model answered in words —
    ///   the turn that follows each of those is the one that carries on.
    /// * Otherwise the turn's own: the mode is the session's, a headless
    ///   turn leaves it on `auto`, and any mode but `plan` takes the
    ///   session out of plan mode.
    static func statedMode(_ modeId: String, isDefault: Bool, isNewSession: Bool,
                           planModeOn: Bool) -> String? {
        if isDefault && isNewSession { return nil }
        if modeId == "plan" && planModeOn { return nil }
        return modeId
    }

    /// Kimi's permission names (`manual`, `yolo`, `auto`) as ACP mode ids.
    static func acpModeId(forPermission permission: String?) -> String {
        switch permission {
        case "yolo": return "yolo"
        case "auto": return "auto"
        default: return "default"
        }
    }

    /// The ACP mode a plan approval continues in, by the mode it names
    /// (`PlanContinue`): Default is kimi's own default, Ask When Needed
    /// `yolo`, Never Ask kimi's `auto` — its own Never Ask, for the rest of
    /// this turn; the turns after it run headless, which never asks either.
    static func acpModeId(continuingIn mode: String, defaultPermissionMode: String?) -> String? {
        switch mode {
        case AgentAskingMode.adoptDefault: return acpModeId(forPermission: defaultPermissionMode)
        case AgentAskingMode.kimiAskWhenNeeded: return "yolo"
        case AgentAskingMode.kimiNeverAsk: return "auto"
        default: return nil
        }
    }

    /// The modes a plan approval can continue in, in the chip's order. The
    /// one Return starts on (`.accept`) is the mode the turn was sent in:
    /// kimi reviews a plan in any mode — its model may enter plan mode on
    /// its own — and approving one drawn up under Ask When Needed must not
    /// move the session to Default at a keystroke. Nor one drawn up in a
    /// turn that runs here only to load a skill, under Never Ask (or any
    /// value a kimi chip reads as it — `modeId(for:…loadingSkill:)`). A
    /// Plan turn has no mode to go back to, and starts on Default.
    static func planContinueModes(turnMode: String? = nil) -> [CardChoice] {
        let current: String
        switch turnMode {
        case AgentAskingMode.kimiAskWhenNeeded: current = AgentAskingMode.kimiAskWhenNeeded
        case nil, AgentAskingMode.kimiPlan: current = AgentAskingMode.adoptDefault
        default: current = AgentAskingMode.kimiNeverAsk
        }
        func role(_ mode: String) -> CardChoiceRole { mode == current ? .accept : .other }
        return [
            CardChoice(id: AgentAskingMode.adoptDefault,
                       label: String(localized: "Default",
                                     comment: "Plan card: the mode an approved plan continues in — the agent's own default setting"),
                       role: role(AgentAskingMode.adoptDefault),
                       adoptsMode: AgentAskingMode.adoptDefault),
            CardChoice(id: AgentAskingMode.kimiAskWhenNeeded,
                       label: AgentAskingMode.title(for: AgentAskingMode.kimiAskWhenNeeded),
                       role: role(AgentAskingMode.kimiAskWhenNeeded),
                       adoptsMode: AgentAskingMode.kimiAskWhenNeeded),
            CardChoice(id: AgentAskingMode.kimiNeverAsk,
                       label: KimiCapabilities.neverAskTitle,
                       role: role(AgentAskingMode.kimiNeverAsk),
                       adoptsMode: AgentAskingMode.kimiNeverAsk),
        ]
    }

    /// The folder kimi is told the session runs in: the PHYSICAL path,
    /// `/private` included, because kimi files the session under a bucket
    /// computed from it and a later headless turn computes it from its
    /// own `process.cwd()` — which is always the physical path.
    static func newSessionParams(cwd: String) -> [String: Any] {
        ["cwd": cwd, "mcpServers": [Any]()]
    }

    static func resumeParams(sessionId: String, cwd: String) -> [String: Any] {
        ["sessionId": sessionId, "cwd": cwd, "mcpServers": [Any]()]
    }

    static func promptParams(sessionId: String, text: String) -> [String: Any] {
        ["sessionId": sessionId, "prompt": [["type": "text", "text": text]]]
    }

    // MARK: - Permission requests

    /// One of kimi's answers to a request, exactly as it offered it.
    struct Option: Equatable {
        let id: String
        let name: String
        /// ACP's `allow_once` / `allow_always` / `reject_once` /
        /// `reject_always`.
        let kind: String
    }

    static func options(in params: [String: Any]) -> [Option] {
        guard let raw = params["options"] as? [Any] else { return [] }
        return raw.compactMap { item in
            guard let o = item as? [String: Any],
                  let id = o["optionId"] as? String, !id.isEmpty,
                  let name = o["name"] as? String
            else { return nil }
            return Option(id: id, name: name, kind: (o["kind"] as? String) ?? "")
        }
    }

    /// The answers of a PLAN review (`approvalRequestToPermissionOptions`
    /// for a `plan_review` display): one approval per approach the plan
    /// offered, or one Approve, then Revise and Reject and Exit.
    static func isPlanReview(_ options: [Option]) -> Bool {
        options.contains { isPlanOption($0.id) }
    }

    private static func isPlanOption(_ id: String) -> Bool {
        id == "plan_approve" || id == "plan_revise" || id == "plan_reject_and_exit"
            || id.hasPrefix("plan_opt_")
    }

    /// What a card shows, read from a request: the tool's name for the
    /// badge, the call's input for the bridge's bookkeeping, and the card.
    struct Card {
        var toolName: String
        var toolInput: [String: Any]
        var presentation: CardPresentation
    }

    /// The card for a `session/request_permission`, or nil when kimi
    /// offered nothing to answer with.
    ///
    /// - Parameters:
    ///   - arguments: the call's input as kimi streamed it before asking
    ///     (`toolCallArguments`). Kimi asks BEFORE it sends the call's
    ///     parsed input, so the input on screen is read from the streamed
    ///     text; nil when nothing was streamed.
    ///   - cwd: where a relative path and a command without a folder of
    ///     their own resolve.
    ///   - turnMode: the mode the turn was sent in, as the chip spells it
    ///     (nil: Default) — where a plan review's approval starts.
    static func permissionCard(params: [String: Any], arguments: [String: Any]?,
                               cwd: String, turnMode: String? = nil) -> Card? {
        let options = options(in: params)
        guard !options.isEmpty else { return nil }
        let call = params["toolCall"] as? [String: Any] ?? [:]
        // The request's title IS the tool's name (kimi builds it from the
        // request, never from a description).
        let toolName = (call["title"] as? String) ?? ""
        let content = call["content"] as? [Any] ?? []
        let texts: [String] = content.compactMap { item in
            guard let entry = item as? [String: Any],
                  (entry["type"] as? String) == "content",
                  let inner = entry["content"] as? [String: Any],
                  (inner["type"] as? String) == "text"
            else { return nil }
            return inner["text"] as? String
        }

        if isPlanReview(options) {
            // The plan is the text that is not kimi's "Requesting
            // approval to …" line.
            let planText = texts.first { !$0.hasPrefix(actionPrefix) } ?? ""
            let parsed = planContent(from: planText)
            return Card(toolName: toolName, toolInput: arguments ?? [:],
                        presentation: .plan(PlanCardContent(plan: parsed.plan,
                                                            filePath: parsed.filePath,
                                                            choices: planChoices(for: options),
                                                            continueModes: planContinueModes(
                                                                turnMode: turnMode))))
        }

        let preview = permissionPreview(content: content, texts: texts,
                                        arguments: arguments, toolName: toolName, cwd: cwd)
        return Card(toolName: toolName, toolInput: arguments ?? [:],
                    presentation: .permission(PermissionCardContent(
                        prompt: nil, preview: preview, choices: choices(for: options))))
    }

    /// Kimi's own sentence under every request (`buildPermissionToolCall
    /// Update`): "Requesting approval to Running: ls -la".
    static let actionPrefix = "Requesting approval to "

    /// A plan review's text: "Plan saved to: <path>" and a blank line in
    /// front of the plan when kimi saved it to a file (`composePlanContent`),
    /// the plan alone otherwise.
    static func planContent(from text: String) -> (plan: String, filePath: String?) {
        let marker = "Plan saved to: "
        guard text.hasPrefix(marker) else { return (text, nil) }
        let rest = text.dropFirst(marker.count)
        if let range = rest.range(of: "\n\n") {
            let path = String(rest[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            return (String(rest[range.upperBound...]), path.isEmpty ? nil : path)
        }
        // A path and no plan after it.
        let path = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        return ("", path.isEmpty ? nil : path)
    }

    /// What a permission card shows of the call: the edit kimi sent as a
    /// diff, a file write's new contents, a command with its folder and
    /// the reason the model gave, or kimi's own sentence.
    private static func permissionPreview(content: [Any], texts: [String],
                                          arguments: [String: Any]?, toolName: String,
                                          cwd: String) -> CardPreview {
        let reason = (arguments?["description"] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        // An edit: kimi sends the diff itself.
        let diffs: [CardFileChange] = content.compactMap { item in
            guard let entry = item as? [String: Any],
                  (entry["type"] as? String) == "diff",
                  let path = entry["path"] as? String
            else { return nil }
            return CardFileChange(path: path, kind: "",
                                  diff: lineDiff(old: entry["oldText"] as? String ?? "",
                                                 new: entry["newText"] as? String ?? ""))
        }
        if !diffs.isEmpty { return .fileChanges(diffs, reason: reason) }
        // A write: the new contents, every line added.
        if let path = arguments?["path"] as? String,
           let contents = arguments?["content"] as? String {
            return .fileChanges([CardFileChange(path: resolved(path, in: cwd), kind: "",
                                                diff: lineDiff(old: "", new: contents))],
                                reason: reason)
        }
        // A command.
        if let command = arguments?["command"] as? String,
           !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let folder = (arguments?["cwd"] as? String).map { resolved($0, in: cwd) } ?? cwd
            return .command(command, cwd: folder, reason: reason)
        }
        // Anything else: kimi's own sentence about it.
        if let sentence = texts.last(where: { !$0.isEmpty }) {
            return .text(sentence)
        }
        return .nothing
    }

    private static func resolved(_ path: String, in cwd: String) -> String {
        if path.hasPrefix("/") || cwd.isEmpty { return path }
        return (cwd as NSString).appendingPathComponent(path)
    }

    /// The old text's lines removed and the new text's added — what an
    /// edit kimi sends as two snippets IS. A trailing newline is not an
    /// empty last line.
    static func lineDiff(old: String, new: String) -> String {
        func lines(_ s: String) -> [String] {
            guard !s.isEmpty else { return [] }
            var parts = s.components(separatedBy: "\n")
            if parts.last == "" { parts.removeLast() }
            return parts
        }
        return (lines(old).map { "-" + $0 } + lines(new).map { "+" + $0 })
            .joined(separator: "\n")
    }

    /// A tool request's answers, in kimi's order and words. The kind is
    /// kimi's own statement of what an answer does.
    static func choices(for options: [Option]) -> [CardChoice] {
        options.map { option in
            let role: CardChoiceRole
            switch option.kind {
            case "allow_once": role = .accept
            case "allow_always": role = .acceptForSession
            case "reject_once": role = .decline
            case "reject_always": role = .declineForSession
            default: role = .other
            }
            return CardChoice(id: option.id, label: option.name, role: role)
        }
    }

    /// A plan review's answers, in kimi's words. Every approval leaves plan
    /// mode (kimi writes `plan_mode.exit` and the turn carries on with every
    /// tool), and the card names the mode each one continues in
    /// (`planContinueModes`, `PlanContinue`) — the mode is set the moment
    /// the approval has gone back, so the rest of the turn runs in it.
    /// Reject and Exit ends the planning too: it moves a chip that is on
    /// Plan to Default, or the next send would put the session back into
    /// planning, and leaves a chip on another mode where it is
    /// (`AgentAskingMode.adoption`) — kimi reviews a plan the model drew up
    /// on its own there too. Revise keeps planning: it is the refusal Esc
    /// takes, the session stays in plan mode, and the chip moves to Plan
    /// with it — the user's next message says what to change, and sent
    /// under any other mode it would take the session out of plan mode
    /// (`statedMode`) and the changes would be carried out unreviewed.
    static func planChoices(for options: [Option]) -> [CardChoice] {
        options.map { option in
            switch option.id {
            case "plan_revise":
                return CardChoice(id: option.id, label: option.name, role: .decline,
                                  adoptsMode: AgentAskingMode.kimiPlan)
            case "plan_reject_and_exit":
                return CardChoice(id: option.id, label: option.name, role: .other,
                                  adoptsMode: AgentAskingMode.adoptLeavingPlan)
            default:
                return CardChoice(id: option.id, label: option.name,
                                  role: option.kind == "allow_once" ? .accept : .other)
            }
        }
    }

    /// The reply to a permission request. Only an answer kimi offered is
    /// sent as chosen (kimi reads any other id as a refusal); everything
    /// else — Stop, a quit, a card that could not be drawn — is
    /// `cancelled`, which kimi tells the model as "the approval request
    /// was cancelled" (a plan review: "Plan approval dismissed. Plan mode
    /// remains active.").
    static func permissionReply(to resolution: CardResolution,
                                options: [Option]) -> [String: Any] {
        // A plan approval that names a mode is kimi's own answer for it.
        if case .chose(let picked) = resolution {
            let id = PlanContinue.split(picked).answer
            if options.contains(where: { $0.id == id }) {
                return ["outcome": ["outcome": "selected", "optionId": id]]
            }
        }
        return ["outcome": ["outcome": "cancelled"]]
    }

    // MARK: - Questions

    /// The form for an `elicitation/create` — kimi's AskUserQuestion,
    /// every question at once (`questionRequestToElicitationParams`): the
    /// questions' texts joined by newlines in `message`, one property per
    /// question (`q0`, `q1`, … in `required`'s order) titled by its header
    /// or, without one, by the question itself; a single choice is a
    /// `string` with `oneOf`, a multiple one an `array` with
    /// `items.anyOf`. Nil when the form cannot be drawn faithfully — and
    /// the driver then declines it, which kimi tells the model as "User
    /// dismissed the question without answering."
    ///
    /// No answer in the user's own words: kimi's form has no field for
    /// one. Skip is offered (it is kimi's dismissal); "Chat about this"
    /// is not — kimi's reply carries no words.
    static func questionForm(params: [String: Any]) -> AgentQuestionForm? {
        guard (params["mode"] as? String ?? "form") == "form",
              let schema = params["requestedSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any],
              !properties.isEmpty
        else { return nil }
        let keys: [String] = {
            if let required = schema["required"] as? [String],
               Set(required) == Set(properties.keys) {
                return required
            }
            // `qN`, in N's order.
            return properties.keys.sorted { a, b in
                (Int(a.dropFirst()) ?? Int.max, a) < (Int(b.dropFirst()) ?? Int.max, b)
            }
        }()
        let message = params["message"] as? String ?? ""
        let lines = message.components(separatedBy: "\n")
        var questions: [AgentQuestionForm.Question] = []
        for (index, key) in keys.enumerated() {
            guard let property = properties[key] as? [String: Any] else { return nil }
            let title = (property["title"] as? String) ?? ""
            // The question's own words: its line of the message when the
            // message splits into one line per question, else the whole
            // message for a single question, else its title.
            let asked: String = {
                if lines.count == keys.count { return lines[index] }
                if keys.count == 1, !message.isEmpty { return message }
                return title
            }()
            let body = (property["description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = body.isEmpty ? asked : asked + "\n\n" + body
            let multi = (property["type"] as? String) == "array"
            let rawOptions: [Any] = multi
                ? ((property["items"] as? [String: Any])?["anyOf"] as? [Any] ?? [])
                : (property["oneOf"] as? [Any] ?? [])
            var options: [AgentQuestionForm.Option] = []
            for raw in rawOptions {
                guard let option = raw as? [String: Any],
                      let label = option["const"] as? String
                else { return nil }
                options.append(AgentQuestionForm.Option(
                    label: label,
                    description: (option["description"] as? String) ?? "",
                    preview: nil))
            }
            // A header that only repeats the question is no header.
            let header = title == asked ? "" : title
            questions.append(AgentQuestionForm.Question(
                text: text, header: header, options: options, multiSelect: multi,
                id: key, allowsOther: false, isSecret: false))
        }
        return AgentQuestionForm(questions: questions, offersSkip: true, offersChat: false)
    }

    /// The reply to an elicitation. Answers go back by each question's
    /// property: one label, or the labels picked in the order kimi listed
    /// them (kimi joins those with ", " for the model). A form answered
    /// nowhere is a dismissal, and so is Skip, Non-stop and every reason
    /// a card could not be drawn; Stop and a quit are `cancel`.
    static func questionReply(to resolution: CardResolution,
                              form: AgentQuestionForm?) -> [String: Any] {
        switch resolution {
        case .answered(let answers):
            guard let form else { return ["action": "decline"] }
            var content: [String: Any] = [:]
            for question in form.questions {
                guard let id = question.id, let answer = answers[question.text] else { continue }
                let picked = question.options.map(\.label).filter { answer.labels.contains($0) }
                if question.multiSelect {
                    if !picked.isEmpty { content[id] = picked }
                } else if let label = picked.first {
                    content[id] = label
                }
            }
            if content.isEmpty { return ["action": "decline"] }
            return ["action": "accept", "content": content]
        case .cancelled:
            return ["action": "cancel"]
        default:
            return ["action": "decline"]
        }
    }

    // MARK: - What kimi streams before it asks

    /// A call's input as kimi has streamed it, from a `tool_call` or
    /// `tool_call_update` notification: its `rawInput` once kimi has
    /// parsed it, else the arguments text it streamed (kimi replaces the
    /// text with the whole of it on every update). Kimi asks for
    /// permission BEFORE it sends `rawInput`, so the text is what a card
    /// is drawn from. Nil for anything that is not a call update or whose
    /// text is not yet a whole JSON object.
    static func toolCallArguments(update: [String: Any]) -> (id: String, arguments: [String: Any])? {
        let kind = update["sessionUpdate"] as? String
        guard kind == "tool_call" || kind == "tool_call_update",
              let id = update["toolCallId"] as? String, !id.isEmpty
        else { return nil }
        if let raw = update["rawInput"] as? [String: Any] { return (id, raw) }
        for item in update["content"] as? [Any] ?? [] {
            guard let entry = item as? [String: Any],
                  (entry["type"] as? String) == "content",
                  let inner = entry["content"] as? [String: Any],
                  let text = inner["text"] as? String,
                  let data = text.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            return (id, object)
        }
        return nil
    }

    /// The text of an `agent_message_chunk`, or nil for any other update.
    /// Kept for one case only: a prompt kimi answers ITSELF (a slash
    /// command — `/status`, `/usage`, `/help`, an unknown one) writes
    /// nothing to the session, so its answer exists only in these chunks.
    static func messageChunk(update: [String: Any]) -> String? {
        guard (update["sessionUpdate"] as? String) == "agent_message_chunk",
              let content = update["content"] as? [String: Any],
              (content["type"] as? String) == "text"
        else { return nil }
        return content["text"] as? String
    }

    // MARK: - Plan mode, left on

    /// Whether the newest plan-mode record in `text` that no undo took back
    /// (below) leaves the session IN plan mode: `plan_mode.enter` after the
    /// last `plan_mode.exit` (an approved plan, Reject and Exit) or
    /// `plan_mode.cancel` (any other mode set). nil when the text holds
    /// none of them.
    ///
    /// Plan mode is the session's, and kimi replays it whenever the session
    /// is opened again: a headless turn after an ACP Plan turn runs IN plan
    /// mode and refuses every edit ("Plan mode is active. You may only
    /// write to …", measured) under a chip that says Never Ask.
    ///
    /// An undo takes back, with the turns it takes, the plan-mode records
    /// they hold: kimi replays the session from what the undo kept
    /// (`KimiSessionScanner.UndoFold`), so a session taken out of plan mode
    /// inside an undone turn is in plan mode again — read as the newest
    /// record, its next Plan turn would state `plan` and be refused, and a
    /// Never Ask turn would run in plan mode. `windowIsWhole` is the fold's:
    /// whether `text` is the whole record.
    static func planModeOn(in text: String, windowIsWhole: Bool = true) -> Bool? {
        // A verdict per plan-mode record and an empty slot per message the
        // user sent, in order — an undo cuts the list at a message.
        var entries: [Bool?] = []
        var undo = KimiSessionScanner.UndoFold()
        text.enumerateLines { line, _ in
            guard line.contains("\"plan_mode.") || line.contains("\"context.append_message\"")
                    || line.contains("\"context.undo\"") || line.contains("\"context.apply_compaction\"")
                    || line.contains("\"context.clear\""),
                  let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return }
            let signal = KimiSessionScanner.UndoFold.signal(of: obj)
            if let cut = undo.apply(signal, at: entries.count, windowIsWhole: windowIsWhole) {
                entries.removeSubrange(cut...)
            }
            switch obj["type"] as? String {
            case "plan_mode.enter": entries.append(true)
            case "plan_mode.exit", "plan_mode.cancel": entries.append(false)
            default: if signal == .anchor { entries.append(nil) }
            }
        }
        return entries.compactMap { $0 }.last
    }

    /// `planModeOn` over the session's record, widening until a plan-mode
    /// record is in view: a session that was never in plan mode has none,
    /// and one entered long ago can sit far from the end.
    static func planModeLeftOn(wire: URL) -> Bool {
        let size = ((try? FileManager.default.attributesOfItem(atPath: wire.path))?[.size]
                    as? NSNumber)?.intValue ?? 0
        for budget in [256 * 1024, 4 * 1024 * 1024, 32 * 1024 * 1024] {
            guard let tail = AgentSessionScanner.boundedTail(of: wire, budget: budget) else { return false }
            if let on = planModeOn(in: tail, windowIsWhole: size <= budget) { return on }
            if size <= budget { break }
        }
        return false
    }
}

// MARK: - Reading the turn off the session's own record

/// What an ACP turn's session record says while the turn runs, one line
/// at a time.
///
/// The transcript is drawn from here rather than from ACP's stream: the
/// record is what a reopened session is read from (`KimiSessionScanner
/// .WireDecoder`), so the rows are the same rows either way — tool names
/// and inputs included, which ACP sends only as a title that may be a
/// description. It also holds what ACP never streams: a turn kimi starts
/// on its own when a background task finishes, a provider's failure (ACP
/// ends such a turn as if it had succeeded), and each retry of a failed
/// request. Kimi writes a step's text when the step ends, the same moment
/// a headless turn prints it.
struct KimiAcpWireFollow {
    private var decoder = KimiSessionScanner.WireDecoder()
    /// The turns and the background tasks the record shows
    /// (`KimiSessionScanner.BackgroundTasks`). Kimi starts a turn on a
    /// finished task's notification a moment AFTER it records the task's
    /// end (measured: the two land about ten milliseconds apart), or once
    /// the turn it is in the middle of is over.
    private var tasks = KimiSessionScanner.BackgroundTasks()
    /// `turn.prompt` records read: the turn this driver sent, then any
    /// kimi starts on its own.
    var promptsSeen: Int { tasks.promptsSeen }
    var turnsEnded: Int { tasks.turnsEnded }
    /// The tasks the turn waits on once its answer has landed — the
    /// transcript's line naming them.
    var awaitedTasks: [BackgroundTaskEntry] { tasks.awaited }
    /// The newest failed turn's message, in kimi's words; nil when kimi
    /// gave it none.
    private(set) var failure: String?
    /// How many turns have been read to fail — one driver may see two:
    /// the turn it sent, then one kimi starts on its own.
    private(set) var failureCount = 0
    private var retry = KimiSessionScanner.RetryWatch()
    /// The newest retry, in the words kimi's terminal shows it with.
    var retryNotice: String? { retry.notice }
    /// The context footprint of the newest call (`usage.record`, the
    /// input side, as the context chip counts it everywhere).
    private(set) var contextTokens: Int?
    /// Since when a compaction kimi began has been running. `/compact` is
    /// answered at once ("Context compaction started — it runs in the
    /// background") and the compaction itself — a request to the model —
    /// follows; kimi cancels it the moment its stdin closes.
    private(set) var compactionOpenSince: Date?
    /// How many compactions this follow has seen begin.
    private(set) var compactionsBegun = 0
    /// The user row of the prompt this driver sent is already on screen.
    private var ownPromptRowSkipped = false

    init() {}

    var turnOpen: Bool { tasks.turnOpen }
    var tasksPending: Bool { !tasks.open.isEmpty }

    /// The latest moment a pending task can still be running — kimi's
    /// own deadline for it.
    var taskDeadline: Date? { tasks.open.map(\.deadline).max() }

    /// Since when a finished task's turn has been due and nothing else is
    /// going on: the later of the newest such task's end and the newest
    /// turn's end (kimi holds a notification until the turn it is in has
    /// ended). nil when no finished task is still owed its turn.
    var noticeOwedSince: Date? {
        guard let ended = tasks.noticesOwed.values.max() else { return nil }
        return max(ended, tasks.lastTurnEndedAt ?? ended)
    }

    /// Whether the record shows work at `now` that the child must be kept
    /// up for once the prompt has been answered — kimi stops its
    /// background tasks a few seconds after its stdin closes, and the turn
    /// it runs when one finishes reaches nobody then. Three things do:
    ///
    ///  * a turn that is open. It is kimi's to end, as the prompt's own
    ///    turn was: no clock runs on it, however long after the prompt its
    ///    task finished and however long it then works;
    ///  * a task still running, until kimi's own deadline for it and
    ///    `taskMargin` (kimi ends an overdue task itself, so past that its
    ///    record of the task is not coming);
    ///  * a task that has just ended, for the `noticeSettle` kimi may take
    ///    to open the turn it runs on it — the two records land apart, and
    ///    a read between them finds no task and no turn.
    ///
    /// And a compaction that is under way, for as long as one request to
    /// the model may reasonably take (`compactionCeiling`): closed under
    /// it, kimi records the compaction cancelled — the user asked for
    /// `/compact`, was told it had started, and nothing was compacted.
    func keepsChildUp(at now: Date, taskMargin: TimeInterval, noticeSettle: TimeInterval,
                      compactionCeiling: TimeInterval = 600) -> Bool {
        if turnOpen { return true }
        if let since = compactionOpenSince {
            return now.timeIntervalSince(since) < compactionCeiling
        }
        if let deadline = taskDeadline {
            return now < deadline.addingTimeInterval(taskMargin)
        }
        if let since = noticeOwedSince {
            return now.timeIntervalSince(since) < noticeSettle
        }
        return false
    }

    /// - Parameter now: when the line was read — the clock the waits
    ///   above run on.
    mutating func feed(line: String, now: Date = Date()) -> [StreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        retry.feed(record: obj)
        // The notification itself is drawn by the decoder below, in the
        // same words.
        _ = tasks.feed(record: obj, now: now)
        let type = obj["type"] as? String ?? ""
        switch type {
        case "turn.ended":
            if let reason = KimiSessionScanner.failedTurnReason(obj) {
                failure = reason.isEmpty ? nil : reason
                failureCount += 1
            }
        case "usage.record":
            if (obj["usageScope"] as? String) == "turn",
               let usage = obj["usage"] as? [String: Any] {
                let total = ["inputOther", "inputCacheRead", "inputCacheCreation"]
                    .reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
                if total > 0 { contextTokens = total }
            }
        case "full_compaction.begin":
            compactionOpenSince = now
            compactionsBegun += 1
        default:
            if type.hasPrefix("full_compaction.") {
                // Complete, cancelled, or however else kimi ends one.
                compactionOpenSince = nil
            }
        }
        var events: [StreamEvent] = []
        // A thought is kept while compact view can draw it — never in a
        // Chat only turn here: that turn never runs through `kimi acp`.
        decoder.includeThinking = CompactTranscript.isOn
        for item in decoder.items(forLine: trimmed) {
            if case .userText = item.kind, !item.isSystemNotice,
               promptsSeen > 0, !ownPromptRowSkipped {
                ownPromptRowSkipped = true
                continue
            }
            // A failed turn's row is the driver's to say (`failure`,
            // `failureCount`): once, and not again after kimi refused the
            // same prompt in words over ACP — drawn here too, it would be
            // said twice.
            if case .error = item.kind { continue }
            if let event = AgentSessionTailer.liveEvent(for: item) { events.append(event) }
        }
        return events
    }
}

// MARK: - Handing a session back

extension KimiRuntimeBinding {
    /// Hand every agent of the session in `dir` back (`restore(wire:)`). Each
    /// agent keeps its binding in a wire of its own, and a subagent is born on
    /// the binding of the agent that started it: one started in an ACP turn
    /// holds nothing else, and a later headless turn that resumes it would run
    /// it without its file and command tools. True when no agent is left bound.
    static func restore(sessionDir dir: URL) -> Bool {
        let agents = dir.appendingPathComponent("agents", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: agents.path)) ?? []
        return names.map { restore(wire: agents.appendingPathComponent("\($0)/wire.jsonl")) }.allSatisfy { $0 }
    }
}
