// CodexAppServer.swift
// The rules a codex turn through codex's own front end runs by — Default
// (codex's own default setting), Plan, and the three fixed modes (Read
// Only, Workspace Write, Full Access). Such a turn goes through
// `codex app-server`,
// the JSON-RPC front end codex's own terminal and desktop app drive,
// because that is where codex ASKS: before a command it would run outside
// its sandbox (`item/commandExecution/requestApproval`), before an edit
// outside the folder (`item/fileChange/requestApproval`), in Plan mode a
// question (`item/tool/requestUserInput`), and — for an MCP server — the
// server's own form or link, or codex's approval before it runs one of its
// tools (`mcpServer/elicitation/request`, drawn by `McpElicitation`).
// `codex exec` refuses every one of those itself. A question codex asks
// WITHOUT stopping (`request_user_input_async`) reaches `codex exec` too,
// but only here can an answer reach the turn that asked it. The fixed
// modes never ask — codex refuses those requests itself under their
// "never" here as it does on `codex exec` — and run here for what only
// this front end does: a speed stated per message, where `codex exec`
// keeps a thread's saved one, and a command left running in a background
// terminal kept alive until it ends, where `codex exec` stops it with the
// turn.
//
// Foundation only, and free of the runner and the views, so the
// harnesses compile it with the readers it leans on.
//
// What this file decides, each rule measured against the real app-server:
//
//  * what a turn states, every time: its permissions — codex's own
//    default for the folder (asked of codex, `Permissions`), or a fixed
//    mode's own (`fixedPermissions`) — the model, the effort,
//    the speed, and the collaboration mode. The approval policy, the
//    model, the effort and the speed are the THREAD's once a turn names
//    them, in later processes too, and `effort: null` does not clear one
//    — so a turn that left any of them out would run on whatever an
//    earlier turn set (`turnStartParams`). A value the chip leaves on
//    Default is codex's own answer for the folder (`Defaults`);
//  * the card a command or an edit becomes, in codex's words — the
//    sentences its terminal shows — and the reply each answer is. The
//    answers are the ones codex lists for the request, less the two a
//    command card leaves out (`commandChoices`); an MCP server's requests
//    are `McpElicitation`'s;
//  * the card a question asked without stopping becomes, and the message
//    its answers are steered into the turn as — codex's own clients'
//    reply, which codex's own terminal reads back (`asyncReplyText`);
//  * what each app-server item is as `codex exec --json` would print it
//    (`execEvents`), so the parser every codex turn already goes through
//    draws it;
//  * that a Plan turn leaves the THREAD in plan mode, and every later
//    turn — `codex exec`'s included — runs under the plan instructions
//    until something sets it back (`collaborationMode(in:)`).

import Foundation

enum CodexAppServer {

    // MARK: - The conversation

    /// The child: codex's app-server on stdio. Each message is one line,
    /// written as it is sent — a request arrives while codex waits on it —
    /// so stdout needs no terminal.
    static let arguments = ["app-server"]

    /// SipAI's own name on the wire. Codex sends it upstream as the
    /// `originator` header and records it on the session; never another
    /// client's name.
    static let clientName = "sipai"

    /// The handshake. `experimentalApi` is what `collaborationMode` — Plan
    /// — and `thread/settings/update` need; nothing else here does.
    static func initializeParams(clientVersion: String) -> [String: Any] {
        [
            "clientInfo": ["name": clientName, "title": "SipAI", "version": clientVersion],
            "capabilities": ["experimentalApi": true],
        ]
    }

    /// The two collaboration modes a turn runs in: codex's Default (the
    /// chip's Default row, and every fixed mode) and Plan.
    enum Mode: Equatable {
        case defaultMode, plan

        /// The collaboration mode's name on the wire.
        var collaborationModeName: String { self == .plan ? "plan" : "default" }
    }

    /// The collaboration mode a turn runs in through the app-server:
    /// Default for the chip's Default (nil) and the fixed modes, Plan for
    /// Plan; nil for every other value, which never comes here.
    static func mode(for permissionMode: String?) -> Mode? {
        switch permissionMode {
        case nil: return .defaultMode
        case AgentAskingMode.codexPlan: return .plan
        case let mode where AgentAskingMode.isCodexFixed(mode): return .defaultMode
        default: return nil
        }
    }

    /// What a turn in a fixed mode states: never asking, and the mode's
    /// own sandbox as the legacy mode name — what `codex exec`'s argv for
    /// the mode enforces (`CodexCapabilities.modePresets`), and over a
    /// permission profile of the user's own, as the chip names the
    /// sandbox. nil for Default and Plan, which state codex's own default
    /// for the folder.
    static func fixedPermissions(for permissionMode: String?) -> Permissions? {
        guard let permissionMode, AgentAskingMode.isCodexFixed(permissionMode),
              let sandbox = CodexCapabilities.sandboxMode(for: permissionMode) else { return nil }
        return Permissions(approvalPolicy: "never", approvalsReviewer: nil, profile: nil,
                           sandbox: sandbox)
    }

    /// Codex's own default permissions for a folder, as codex states them:
    /// the approval policy, who answers approvals, and the sandbox.
    ///
    /// A thread KEEPS the approval policy its last turn ran with, in later
    /// processes too (measured: a thread whose last turn ran Full Access,
    /// resumed with none stated, ran its next turn never asking), so a
    /// turn left to "whatever codex does by default" would never ask after
    /// one that did not. Codex is asked instead, every turn: a
    /// `thread/start` with nothing stated answers with codex's own default
    /// for the folder — its config and the folder's trust decide, codex's
    /// rules and not a copy of them. On a resumed thread the one asked is
    /// a thread of its own: it is given no turn, so it has no rollout, no
    /// row in codex's thread table and no place in `thread/list` — but
    /// while it is loaded codex runs a second set of the user's MCP
    /// servers for it and holds a writer lock, so it is deleted the moment
    /// it has answered (`threadDeleteParams`).
    ///
    /// The sandbox goes back in the terms codex gave it: the permission
    /// profile where one is in force, else the legacy sandbox mode. The
    /// two cannot be combined, and a legacy mode stated over a profile
    /// REPLACES it (measured: a profile that keeps the workspace read-only
    /// came back as plain workspace-write, and the edit it would have
    /// asked about was written unasked).
    struct Permissions {
        /// Codex's `approvalPolicy`, a name or a granular policy object.
        let approvalPolicy: Any
        let approvalsReviewer: String?
        /// The permission profile in force, by its id — a built-in one
        /// (`:workspace`, `:read-only`) or the user's own.
        let profile: String?
        /// The legacy sandbox as a mode name, the spelling `thread/resume`
        /// takes — stated only where no profile is in force.
        let sandbox: String?
    }

    /// The permissions a `thread/start` answer states, or nil when it
    /// states no approval policy (an answer this file was not written
    /// against).
    static func permissions(fromOpened answer: [String: Any]?) -> Permissions? {
        guard let answer, let policy = answer["approvalPolicy"], !(policy is NSNull) else {
            return nil
        }
        let sandboxType = (answer["sandbox"] as? [String: Any])?["type"] as? String
        let profile = (answer["activePermissionProfile"] as? [String: Any])?["id"] as? String
        return Permissions(approvalPolicy: policy,
                           approvalsReviewer: answer["approvalsReviewer"] as? String,
                           profile: nonBlank(profile),
                           sandbox: sandboxType.flatMap(sandboxMode(forType:)))
    }

    /// The app-server's sandbox type as the mode name codex's requests take.
    static func sandboxMode(forType type: String) -> String? {
        switch type {
        case "readOnly": return "read-only"
        case "workspaceWrite": return "workspace-write"
        case "dangerFullAccess": return "danger-full-access"
        default: return nil
        }
    }

    /// A new thread: the folder is the PHYSICAL path
    /// (`CodexConfigRead.physicalPath`), as a turn spawned in it sees its
    /// own working directory. With nothing stated, its answer is codex's
    /// own default for the folder: the permissions
    /// (`permissions(fromOpened:)`) and the model, effort and speed
    /// (`defaults(fromOpened:)`). A fixed mode's thread is started
    /// stating the mode's permissions (`fixedPermissions`); codex then
    /// records the folder as trusted for Workspace Write and Full Access,
    /// as it does for `codex exec`'s first turn in them (measured), and
    /// the answer's model, effort and speed are still the folder's.
    ///
    /// `serviceTier`: the faster speed the turn will ask for, named here
    /// too, because opening the session is where codex checks a speed
    /// against its own list — it answers the speed it will send, and warns
    /// when it drops one (`CodexSpeed.served`). Named on `turn/start` alone,
    /// a speed codex's list lacks is dropped without a word. The answer's
    /// speed is then that verdict and not the folder's, which is read only
    /// for a turn that names no speed. Never on the turnless thread a
    /// resumed turn asks for codex's defaults: its answer is the folder's
    /// own speed.
    static func threadStartParams(cwd: String, stating permissions: Permissions? = nil,
                                  serviceTier: String? = nil) -> [String: Any] {
        var params: [String: Any] = ["cwd": cwd]
        if let permissions {
            params["approvalPolicy"] = permissions.approvalPolicy
            if let sandbox = permissions.sandbox { params["sandbox"] = sandbox }
        }
        if let serviceTier { params["serviceTier"] = serviceTier }
        return params
    }

    /// Lets go of the thread a resumed turn asked for codex's defaults:
    /// codex unloads it — its MCP servers stopped, its writer lock
    /// released — and, since it never had a turn, there is nothing else to
    /// remove. Only ever that thread's own id.
    static func threadDeleteParams(threadId: String) -> [String: Any] {
        ["threadId": threadId]
    }

    /// `excludeTurns`: the transcript is SipAI's to read off the rollout;
    /// the thread's history is not sent back. The permissions — codex's own
    /// default, or a fixed mode's — are stated so the thread does not keep
    /// an earlier turn's: codex's default with its profile where one is in
    /// force, never a legacy mode over it. `serviceTier` as on
    /// `threadStartParams`: the resume is where codex checks it.
    static func threadResumeParams(threadId: String, cwd: String,
                                   permissions: Permissions,
                                   serviceTier: String? = nil) -> [String: Any] {
        var params: [String: Any] = ["threadId": threadId, "cwd": cwd,
                                     "approvalPolicy": permissions.approvalPolicy,
                                     "excludeTurns": true]
        if let reviewer = permissions.approvalsReviewer { params["approvalsReviewer"] = reviewer }
        if let profile = permissions.profile {
            params["permissions"] = profile
        } else if let sandbox = permissions.sandbox {
            params["sandbox"] = sandbox
        }
        if let serviceTier { params["serviceTier"] = serviceTier }
        return params
    }

    /// What a turn runs as, resolved the way the chip states it.
    struct TurnSettings: Equatable {
        /// The model: the pick, else the folder's configured default.
        var model: String?
        /// The effort: the pick, else the folder's configured effort, else
        /// the model's own default.
        var effort: String?
        /// The speed the send pins (`CodexSpeed.override`). A send that
        /// pins none — a scheduled run left on Default speed — runs at the
        /// folder's configured tier, as a headless turn that passes none
        /// does (`settings(_:modelPick:effortPick:defaults:…)`); with none
        /// configured either, the thread's tier is CLEARED.
        var serviceTier: String?
    }

    /// What codex itself starts a thread with in a folder: its merged
    /// config's model, effort and speed — a trusted project's own
    /// `.codex/config.toml` included — read off the same `thread/start`
    /// answer the permissions come from. The speed is the CONFIG's alone:
    /// a model's catalog default is not applied there (measured), which is
    /// `codex exec`'s rule.
    struct Defaults: Equatable {
        var model: String? = nil
        /// The configured effort; nil with `effortStated` is "none
        /// configured", which runs the model's own default.
        var effort: String? = nil
        /// Whether the answer carried an effort field at all — an answer
        /// without one says nothing about the config.
        var effortStated = false
        var serviceTier: String? = nil
    }

    static func defaults(fromOpened answer: [String: Any]?) -> Defaults {
        Defaults(model: nonBlank(answer?["model"] as? String),
                 effort: nonBlank(answer?["reasoningEffort"] as? String),
                 effortStated: answer?["reasoningEffort"] != nil,
                 serviceTier: nonBlank(answer?["serviceTier"] as? String))
    }

    /// The settings a turn states. Each value the chip leaves on Default is
    /// resolved here rather than left out: the thread keeps whatever a
    /// previous turn named, so an omitted value is not a default.
    ///
    /// A pick stands. A value left on Default is codex's own answer for
    /// the folder (`defaults`) — what a headless turn that states nothing
    /// runs — and SipAI's reading of the config (`folderModel`,
    /// `folderEffort`) only where codex stated none. Resolved from SipAI's
    /// reading alone, a run in a folder SipAI has not asked codex about (a
    /// scheduled run, the first instant of a session) stated the user
    /// file's model over a trusted project's own, ran the model's default
    /// effort over the configured one, and cleared the configured speed.
    static func turnSettings(model pick: String?, effort effortPick: String?,
                             folderModel: String?, folderEffort: String?,
                             modelDefaultEffort: (String) -> String?,
                             serviceTier: String?,
                             defaults: Defaults = Defaults()) -> TurnSettings {
        let model = nonBlank(pick) ?? defaults.model ?? nonBlank(folderModel)
        let configuredEffort = defaults.effortStated ? defaults.effort : nonBlank(folderEffort)
        let effort = nonBlank(effortPick) ?? configuredEffort
            ?? model.flatMap { nonBlank(modelDefaultEffort($0)) }
        return TurnSettings(model: model, effort: effort,
                            serviceTier: nonBlank(serviceTier) ?? defaults.serviceTier)
    }

    /// `turn/start`. The collaboration mode is stated on every turn — a
    /// Default turn says `default` — because plan mode is the thread's once a
    /// Plan turn names it. It needs a model: the turn's, else the one the
    /// thread runs (`threadModel`, from `thread/start` / `thread/resume`).
    static func turnStartParams(threadId: String, text: String, cwd: String,
                                mode: Mode, settings: TurnSettings,
                                permissions: Permissions,
                                threadModel: String?) -> [String: Any] {
        var params: [String: Any] = [
            "threadId": threadId,
            "input": [["type": "text", "text": text]],
            "cwd": cwd,
            "approvalPolicy": permissions.approvalPolicy,
            "serviceTier": settings.serviceTier.map { $0 as Any } ?? NSNull(),
        ]
        if let reviewer = permissions.approvalsReviewer { params["approvalsReviewer"] = reviewer }
        if let model = settings.model { params["model"] = model }
        if let effort = settings.effort { params["effort"] = effort }
        if let model = settings.model ?? threadModel {
            params["collaborationMode"] = collaborationMode(mode, model: model,
                                                            effort: settings.effort)
        }
        return params
    }

    /// A collaboration mode with codex's own instructions for it
    /// (`developer_instructions: null` is "the built-in ones").
    static func collaborationMode(_ mode: Mode, model: String, effort: String?) -> [String: Any] {
        [
            "mode": mode.collaborationModeName,
            "settings": [
                "model": model,
                "reasoning_effort": effort.map { $0 as Any } ?? NSNull(),
                "developer_instructions": NSNull(),
            ] as [String: Any],
        ]
    }

    // MARK: - Codex's words

    /// The sentences codex's own terminal puts on these requests, spelled
    /// once. The agent's name is the label the user gave it.
    enum Words {
        static var runCommand: String {
            String(localized: "Would you like to run the following command?",
                   comment: "Codex approval card title for a command, in codex's own words")
        }
        static var sendInput: String {
            String(localized: "Would you like to send input to the existing terminal?",
                   comment: "Codex approval card title for typing into a running command, in codex's own words")
        }
        static var makeEdits: String {
            String(localized: "Would you like to make the following edits?",
                   comment: "Codex approval card title for file edits, in codex's own words")
        }
        static var proceed: String {
            String(localized: "Yes, proceed",
                   comment: "Codex approval card answer: allow this once, in codex's own words")
        }
        static var justOnce: String {
            String(localized: "Yes, just this once",
                   comment: "Codex approval card answer for a network request: allow it once, in codex's own words")
        }
        static var hostForConversation: String {
            String(localized: "Yes, and allow this host for this conversation",
                   comment: "Codex approval card answer for a network request: allow the host until the turn ends, in codex's own words")
        }
        static var commandForSession: String {
            String(localized: "Yes, and don't ask again for this command in this session",
                   comment: "Codex approval card answer: allow this command until the turn ends, in codex's own words")
        }
        static var filesForSession: String {
            String(localized: "Yes, and don't ask again for these files",
                   comment: "Codex approval card answer: allow edits to these files until the turn ends, in codex's own words")
        }
        static var continueWithout: String {
            String(localized: "No, continue without running it",
                   comment: "Codex approval card answer: refuse and let the turn go on, in codex's own words")
        }
        static func tellDifferently(_ agentName: String) -> String {
            String(localized: "No, and tell \(agentName) what to do differently",
                   comment: "Codex approval card answer: refuse and end the turn so the user can say what to do instead, in codex's own words; placeholder is the agent label")
        }
        static var implementPlanTitle: String {
            String(localized: "Implement this plan?",
                   comment: "Card after a codex Plan turn ends on a plan, in codex's own words")
        }
        /// "Yes, implement in Default": codex's own answer, with the mode the
        /// plan is carried out in named as Claude Code's plan dialog names
        /// it.
        static func implementIn(_ mode: String) -> String {
            String(localized: "Yes, implement in \(mode)",
                   comment: "Answer on the card after a codex Plan turn: leave Plan mode and carry the plan out in the mode named (placeholder: the mode chip's name for it)")
        }
        static var stayInPlan: String {
            String(localized: "No, stay in Plan mode",
                   comment: "Answer on the card after a codex Plan turn: keep planning, in codex's own words")
        }
        /// The line under codex's card before it runs an MCP tool, when it
        /// offers "Allow for this session" — said the way Claude's card says
        /// what its "Allow Always" keeps. Codex keeps that answer in the
        /// running process, and SipAI starts a process per message.
        static var toolSessionLine: String {
            String(localized: "Allow for this session: don’t ask again for this tool until this message’s turn ends",
                   comment: "Line under Codex's card before it runs an MCP tool, saying what its Allow for this session button keeps; it opens with that button's own label")
        }
        /// …and when it offers "Always allow": codex writes that answer into
        /// its own settings, so it outlasts SipAI's process per message and
        /// holds wherever codex runs.
        static func toolAlwaysLine(_ agentName: String) -> String {
            String(localized: "Always allow: don’t ask again for this tool, in SipAI or in \(agentName)’s own apps",
                   comment: "Line under Codex's card before it runs an MCP tool, saying what its Always allow button keeps: Codex saves the approval in its own settings; it opens with that button's own label; placeholder is the agent label")
        }
        /// Under a card offering an answer "for this session": codex keeps
        /// such a grant in the process, and every message is a process of
        /// its own.
        static func sessionLastsOneTurn(_ agentName: String) -> String {
            String(localized: "SipAI starts \(agentName) afresh for each message, so a “this session” or “these files” answer lasts until this message’s turn ends.",
                   comment: "Note under a codex approval card that offers an answer for the session; placeholder is the agent label")
        }
    }

    /// What codex's terminal sends for "Yes, implement this plan", once
    /// the thread is back in Default mode. The model reads it; never shown
    /// as SipAI's words.
    static let implementPlanMessage = "Implement the plan."

    /// The answer id that carries the plan out (`PlanContinue` adds the mode).
    static let implementAnswer = "implement"

    /// The answers on "Implement this plan?": codex's own, with the mode
    /// the plan is carried out in named on each, as Claude Code's plan
    /// dialog names it — Default (codex's own default setting) and
    /// Workspace Write; Full Access only for a session that was in it
    /// before it planned (`modeBeforePlan`), the rule Claude Code keeps for
    /// Bypass. Read Only is no mode to carry a plan out in.
    static func planFollowUpChoices(modeBeforePlan: String?) -> [CardChoice] {
        var modes: [(spelling: String, title: String)] = [
            (AgentAskingMode.adoptDefault,
             String(localized: "Default",
                    comment: "Plan card: the mode an approved plan continues in — the agent's own default setting")),
            ("workspace-write", CodexCapabilities.title(for: "workspace-write")),
        ]
        if modeBeforePlan == "full-access" {
            modes.append(("full-access", CodexCapabilities.title(for: "full-access")))
        }
        let implement = modes.enumerated().map { index, mode in
            CardChoice(id: PlanContinue.id(answer: implementAnswer, mode: mode.spelling),
                       label: Words.implementIn(mode.title),
                       role: index == 0 ? .accept : .other,
                       adoptsMode: mode.spelling)
        }
        return implement + [CardChoice(id: "stay", label: Words.stayInPlan, role: .decline)]
    }

    // MARK: - Approval requests

    /// What a card shows, read from a request: the badge's tool name, the
    /// call's input for the bridge's bookkeeping, and the card.
    struct Card {
        var toolName: String
        var toolInput: [String: Any]
        var presentation: CardPresentation
    }

    /// One answer codex lists for a request (`availableDecisions`), as its
    /// wire value. An object answer is echoed back verbatim.
    static func decisionId(_ raw: Any) -> String? {
        if let text = raw as? String { return text }
        if let obj = raw as? [String: Any], obj.count == 1 { return obj.keys.first }
        return nil
    }

    /// A command approval's answers, in codex's order and words — the
    /// listed ones, less the two that write a rule for every codex session
    /// on the Mac (`acceptWithExecpolicyAmendment` adds a prefix rule to
    /// codex's own rules file, `applyNetworkPolicyAmendment` a host rule).
    /// "No, and tell … what to do differently" (`cancel`) is the refusal
    /// Esc takes, as it is in codex's terminal; it ends the turn.
    static func commandChoices(available: [Any]?, networkHost: Bool,
                               agentName: String) -> [CardChoice] {
        let listed: [Any] = available ?? ["accept", "cancel"]
        var out: [CardChoice] = []
        for raw in listed {
            switch decisionId(raw) {
            case "accept":
                out.append(CardChoice(id: "accept",
                                      label: networkHost ? Words.justOnce : Words.proceed,
                                      role: .accept))
            case "acceptForSession":
                out.append(CardChoice(id: "acceptForSession",
                                      label: networkHost ? Words.hostForConversation
                                                         : Words.commandForSession,
                                      role: .acceptForSession))
            case "decline":
                out.append(CardChoice(id: "decline", label: Words.continueWithout, role: .other))
            case "cancel":
                out.append(CardChoice(id: "cancel", label: Words.tellDifferently(agentName),
                                      role: .decline))
            default:
                continue
            }
        }
        return out
    }

    /// A file change's answers — codex lists none for it; these are the
    /// three its terminal offers.
    static func fileChangeChoices(agentName: String) -> [CardChoice] {
        [
            CardChoice(id: "accept", label: Words.proceed, role: .accept),
            CardChoice(id: "acceptForSession", label: Words.filesForSession,
                       role: .acceptForSession),
            CardChoice(id: "cancel", label: Words.tellDifferently(agentName), role: .decline),
        ]
    }

    /// The card for a command approval, or nil when no answer is left to
    /// offer.
    static func commandCard(params: [String: Any], agentName: String) -> Card? {
        let network = params["networkApprovalContext"] as? [String: Any]
        let host = (network?["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let choices = commandChoices(available: params["availableDecisions"] as? [Any],
                                     networkHost: host != nil, agentName: agentName)
        guard CardChoiceLayout.isDrawable(choices) else { return nil }
        let command = displayCommand(params["command"] as? String ?? "",
                                     actions: params["commandActions"] as? [Any])
        let reason = nonBlank(params["reason"] as? String)
        let cwd = nonBlank(params["cwd"] as? String)
        let prompt = (params["kind"] as? String) == "writeStdin" ? Words.sendInput : Words.runCommand
        let preview: CardPreview
        if !command.isEmpty {
            preview = .command(command, cwd: cwd, reason: reason ?? host)
        } else if let host {
            preview = .text(host)
        } else {
            preview = reason.map { .text($0) } ?? .nothing
        }
        var notes: [String] = []
        if choices.contains(where: { $0.role == .acceptForSession }) {
            notes.append(Words.sessionLastsOneTurn(agentName))
        }
        return Card(toolName: "exec_command",
                    toolInput: command.isEmpty ? [:] : ["command": command],
                    presentation: .permission(PermissionCardContent(
                        prompt: prompt, preview: preview, notes: notes, choices: choices)))
    }

    /// The card for a file-change approval. The edits themselves are on the
    /// `fileChange` item codex announced just before asking; nil when that
    /// item never arrived, in which case codex's own reason (or nothing) is
    /// shown.
    static func fileChangeCard(params: [String: Any], changes: [CardFileChange]?,
                               agentName: String) -> Card {
        let reason = nonBlank(params["reason"] as? String)
        let preview: CardPreview
        if let changes, !changes.isEmpty {
            preview = .fileChanges(changes, reason: reason)
        } else {
            preview = reason.map { .text($0) } ?? .nothing
        }
        let input: [String: Any] = changes.map { ["paths": $0.map(\.path)] } ?? [:]
        return Card(toolName: "apply_patch", toolInput: input,
                    presentation: .permission(PermissionCardContent(
                        prompt: Words.makeEdits, preview: preview,
                        notes: [Words.sessionLastsOneTurn(agentName)],
                        choices: fileChangeChoices(agentName: agentName))))
    }

    /// A `fileChange` item's edits as a card draws them: an added file's
    /// contents as added lines, a removed one's as removed lines, an
    /// update's unified diff as codex wrote it.
    static func fileChanges(fromItem item: [String: Any]) -> [CardFileChange] {
        (item["changes"] as? [Any] ?? []).compactMap { raw in
            guard let change = raw as? [String: Any],
                  let path = change["path"] as? String, !path.isEmpty else { return nil }
            let kindObject = change["kind"] as? [String: Any]
            let kind = (kindObject?["type"] as? String) ?? (change["kind"] as? String) ?? ""
            let diff = change["diff"] as? String ?? ""
            let moved = nonBlank(kindObject?["move_path"] as? String)
            let shownPath = moved.map { "\(path) → \($0)" } ?? path
            switch kind {
            case "add":
                return CardFileChange(path: shownPath, kind: kind, diff: prefixed(diff, "+"))
            case "delete":
                return CardFileChange(path: shownPath, kind: kind, diff: prefixed(diff, "-"))
            default:
                return CardFileChange(path: shownPath, kind: kind, diff: diff)
            }
        }
    }

    private static func prefixed(_ text: String, _ mark: String) -> String {
        guard !text.isEmpty else { return "" }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { mark + $0 }.joined(separator: "\n")
    }

    /// The command an approval is for, WHOLE: `command` as codex will run
    /// it, less the login-shell wrapper it runs it in (`/bin/zsh -lc '…'`).
    ///
    /// Never `commandActions`. Those are codex's summary of what a command
    /// reads or searches, and they leave parts of it out — measured:
    /// `cat a.txt | tee /elsewhere/b.txt` comes with the single action
    /// `cat a.txt`, `cd /elsewhere && cat notes.txt` with `cat notes.txt` —
    /// so a card drawn from them shows a read where "Yes, proceed" runs a
    /// write. An action is read only when codex names no command at all,
    /// and then every one of them is shown.
    static func displayCommand(_ raw: String, actions: [Any]?) -> String {
        if nonBlank(raw) != nil { return CodexEventParser.unwrappedShell(raw) }
        return (actions ?? [])
            .compactMap { nonBlank(($0 as? [String: Any])?["command"] as? String) }
            .joined(separator: "\n")
    }

    /// The reply to an approval. Only an answer codex was offered is sent
    /// as chosen; everything else — Stop, a quit, a card that could not be
    /// drawn — is `cancel`, which ends the turn as codex's own Esc does.
    static func decisionReply(to resolution: CardResolution,
                              choices: [CardChoice]) -> [String: Any] {
        if case .chose(let id) = resolution, choices.contains(where: { $0.id == id }) {
            return ["decision": id]
        }
        return ["decision": "cancel"]
    }

    /// The reply to a permission-grant request: nothing granted, for this
    /// turn — codex's own "No, continue without permissions".
    static let permissionsDeclined: [String: Any] = ["permissions": [String: Any](), "scope": "turn"]

    /// The reply to an MCP server's request (`mcpServer/elicitation/request`)
    /// — its form, its link, or codex's approval of one of its tools
    /// (`McpElicitation`): the action, an accepted form's content, and
    /// codex's own `_meta` keeping an approval for the session. All three
    /// keys always: codex's schema makes the nullable two required.
    static func elicitationReply(_ answer: McpElicitation.Answer) -> [String: Any] {
        [
            "action": answer.action,
            "content": answer.content.map { $0 as Any } ?? NSNull(),
            "_meta": answer.persist.map { ["persist": $0] as Any } ?? NSNull(),
        ]
    }

    // MARK: - Questions

    /// The free-form answer's label in codex's terminal — what it sends
    /// beside the user's own words.
    static let otherOptionLabel = "None of the above"
    /// What codex's terminal puts in front of the user's own words.
    static let notePrefix = "user_note: "

    /// The form for an `item/tool/requestUserInput` (Plan mode's question
    /// tool): each question's text, header and options as codex sent them,
    /// filed by its id; the user's own words where codex offers them
    /// (`isOther`, which codex sets itself) or where a question has no
    /// options at all; a secret answer typed into a field that does not
    /// show it. Nil when the form cannot be drawn — the driver then answers
    /// with no answers, and codex's own instructions are to go on with the
    /// recommended option.
    static func questionForm(params: [String: Any]) -> AgentQuestionForm? {
        guard let raw = params["questions"] as? [Any], !raw.isEmpty else { return nil }
        var questions: [AgentQuestionForm.Question] = []
        for item in raw {
            guard let q = item as? [String: Any],
                  let id = nonBlank(q["id"] as? String),
                  let text = q["question"] as? String
            else { return nil }
            var options: [AgentQuestionForm.Option] = []
            for rawOption in (q["options"] as? [Any] ?? []) {
                guard let o = rawOption as? [String: Any],
                      let label = o["label"] as? String
                else { return nil }
                options.append(AgentQuestionForm.Option(
                    label: label, description: (o["description"] as? String) ?? "",
                    preview: nil))
            }
            questions.append(AgentQuestionForm.Question(
                text: text, header: (q["header"] as? String) ?? "",
                options: options, multiSelect: false, id: id,
                allowsOther: ((q["isOther"] as? Bool) ?? false) || options.isEmpty,
                isSecret: (q["isSecret"] as? Bool) ?? false))
        }
        return AgentQuestionForm(questions: questions, offersSkip: true, offersChat: false)
    }

    /// The reply to a question set, as codex's terminal spells it: per
    /// question id, the label picked, or — for the user's own words —
    /// codex's free-form label and the words after its note prefix. A
    /// question left unanswered has an empty list. Skip, Non-stop, a form
    /// that could not be drawn and Stop all answer nothing at all.
    static func questionReply(to resolution: CardResolution,
                              form: AgentQuestionForm?) -> [String: Any] {
        guard case .answered(let answers) = resolution, let form else {
            return ["answers": [String: Any]()]
        }
        var out: [String: Any] = [:]
        for question in form.questions {
            guard let id = question.id else { continue }
            var list: [String] = []
            if let answer = answers[question.text] {
                let own = answer.otherText.trimmingCharacters(in: .whitespacesAndNewlines)
                // The user's own words go only while their answer is the
                // one ticked — as the card counts it: words typed and then
                // un-ticked are not an answer.
                if answer.otherPicked {
                    if !own.isEmpty {
                        if !question.options.isEmpty { list.append(otherOptionLabel) }
                        list.append(notePrefix + own)
                    }
                } else if let label = question.options.map(\.label)
                            .first(where: { answer.labels.contains($0) }) {
                    list.append(label)
                }
            }
            out[id] = ["answers": list]
        }
        return ["answers": out]
    }

    // MARK: - Questions asked without stopping

    /// The tool codex hands its newer models (those whose catalog entry
    /// lists it) in every mode, `codex exec` included: the questions go out
    /// as an agent message and the tool answers `{"accepted":true}` at once,
    /// so the turn goes on. Nothing waits for an answer — it reaches the
    /// model only as a message STEERED into the turn that asked
    /// (`steerParams`), and once that turn is over codex refuses one ("no
    /// active turn to steer").
    static let asyncQuestionTool = "request_user_input_async"

    /// The card for an agent message that asks questions (`questions`, each
    /// a `title` and optional `options`): each title, its options, and the
    /// user's own words always — codex says its UI always takes them — filed
    /// under the id codex's own clients give the question,
    /// `["request_user_input_async","<message id>",<index>]`. Nil for a
    /// message that asks nothing, or a form the card cannot draw: the
    /// question then stays the agent's text, as it is in the transcript.
    static func asyncQuestionForm(item: [String: Any]) -> AgentQuestionForm? {
        guard (item["type"] as? String) == "agentMessage",
              let messageId = nonBlank(item["id"] as? String),
              let raw = item["questions"] as? [Any], !raw.isEmpty else { return nil }
        var questions: [AgentQuestionForm.Question] = []
        for (index, entry) in raw.enumerated() {
            guard let q = entry as? [String: Any], let title = q["title"] as? String else { return nil }
            var options: [AgentQuestionForm.Option] = []
            for rawOption in (q["options"] as? [Any] ?? []) {
                guard let label = rawOption as? String else { return nil }
                options.append(AgentQuestionForm.Option(label: label, description: "", preview: nil))
            }
            questions.append(AgentQuestionForm.Question(
                text: title, header: "", options: options, multiSelect: false,
                id: asyncQuestionItemId(messageId: messageId, index: index),
                allowsOther: true))
        }
        return AgentQuestionForm(questions: questions, offersSkip: true, offersChat: false)
    }

    /// A question's id, spelled as codex's own clients spell it: the JSON
    /// of the tool's name, the asking message's id and the question's index.
    static func asyncQuestionItemId(messageId: String, index: Int) -> String {
        jsonLine([asyncQuestionTool, messageId, index]) ?? ""
    }

    /// The reply the answers become — ONE user message, as codex's desktop
    /// app sends a set it was given together: codex's envelope
    /// (`CodexSessionScanner.questionReplyOpen` / `Close`) around a list of
    /// `{answer, question, questionItemId}`, the question repeated within
    /// codex's own bound (one line, at most 512 bytes). Only questions with
    /// an answer are in it; nil when none has one, and nothing is sent.
    static func asyncReplyText(form: AgentQuestionForm,
                               answers: [String: AgentQuestionAnswer]) -> String? {
        var replies: [[String: Any]] = []
        for question in form.questions {
            guard let id = question.id,
                  let value = answers[question.text]?.value(for: question) else { continue }
            replies.append(["answer": value, "question": boundedQuestion(question.text),
                            "questionItemId": id])
        }
        guard !replies.isEmpty, let list = jsonLine(replies) else { return nil }
        return CodexSessionScanner.questionReplyOpen + "\n" + list + "\n"
            + CodexSessionScanner.questionReplyClose
    }

    /// The question as codex's own reply repeats it: every line break a
    /// space, cut at 512 bytes on a character boundary — the model already
    /// has it whole.
    static func boundedQuestion(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var bytes = 0
        for scalar in text.unicodeScalars {
            let size = String(scalar).utf8.count
            if bytes + size > 512 { break }
            out.append(scalar == "\n" || scalar == "\r" ? " " : scalar)
            bytes += size
        }
        return String(out)
    }

    /// `turn/steer`: the answer, as a user message, into the turn that
    /// asked — named, so it can never land in a later one.
    static func steerParams(threadId: String, turnId: String, text: String) -> [String: Any] {
        ["threadId": threadId, "expectedTurnId": turnId,
         "input": [["type": "text", "text": text, "text_elements": [Any]()] as [String: Any]]]
    }

    /// Compact JSON with sorted keys and unescaped slashes — the spelling
    /// codex's own reply is written in.
    private static func jsonLine(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Items as `codex exec --json` prints them

    /// The `codex exec --json` events an app-server notification is, so the
    /// parser every codex turn goes through (`CodexEventParser.parse(object:)`)
    /// draws them. Each app-server item has a twin on exec's stdout — the
    /// same command, output, exit code, status and paths, in snake case;
    /// what has none (the user's message echoed back, the plan, items exec
    /// does not print) is left out here. The plan is the driver's.
    static func execEvents(method: String, params: [String: Any]) -> [[String: Any]] {
        switch method {
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any],
                  let exec = execItem(item) else { return [] }
            return [["type": method == "item/started" ? "item.started" : "item.completed",
                     "item": exec]]
        case "error":
            // Retry progress, and the failure said once more before the turn
            // completes `failed` — both a notice, never a row.
            let error = params["error"] as? [String: Any]
            guard let message = nonBlank(error?["message"] as? String) else { return [] }
            return [["type": "error", "message": message]]
        default:
            return []
        }
    }

    /// One app-server item as exec prints it, or nil for one exec does not.
    static func execItem(_ item: [String: Any]) -> [String: Any]? {
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return nil }
        switch type {
        case "agentMessage":
            // The phase rides along for `CodexBackgroundCommands`: an answer
            // is a message that is not commentary between steps. The parser
            // reads the text alone.
            var message: [String: Any] = ["id": id, "type": "agent_message",
                                          "text": item["text"] as? String ?? ""]
            if let phase = item["phase"] as? String { message["phase"] = phase }
            return message
        case "reasoning":
            let summary = (item["summary"] as? [Any] ?? []).compactMap { $0 as? String }
            return ["id": id, "type": "reasoning", "text": summary.joined(separator: "\n\n")]
        case "commandExecution":
            return [
                "id": id, "type": "command_execution",
                "command": item["command"] as? String ?? "",
                "aggregated_output": item["aggregatedOutput"] as? String ?? "",
                "exit_code": item["exitCode"] ?? NSNull(),
                "status": snakeStatus(item["status"]),
            ]
        case "fileChange":
            // Exec's `{path, kind}`, with what exec's item leaves out: each
            // file's diff (an added file's content, an edited one's unified
            // diff) and where a file moved — what the row shows of a change
            // (`CodexToolInput.fileChange(fromItemChanges:)`).
            let changes: [[String: Any]] = (item["changes"] as? [Any] ?? []).compactMap { raw in
                guard let change = raw as? [String: Any],
                      let path = change["path"] as? String else { return nil }
                let kindObject = change["kind"] as? [String: Any]
                let kind = (kindObject?["type"] as? String)
                    ?? (change["kind"] as? String) ?? "update"
                var out: [String: Any] = ["path": path, "kind": kind]
                if let moved = kindObject?["move_path"] as? String { out["move_path"] = moved }
                if let diff = change["diff"] as? String { out["diff"] = diff }
                return out
            }
            return ["id": id, "type": "file_change", "changes": changes,
                    "status": snakeStatus(item["status"])]
        case "webSearch":
            var out: [String: Any] = ["id": id, "type": "web_search",
                                      "query": item["query"] as? String ?? ""]
            if let action = item["action"] { out["action"] = action }
            return out
        case "mcpToolCall":
            return [
                "id": id, "type": "mcp_tool_call",
                "server": item["server"] as? String ?? "",
                "tool": item["tool"] as? String ?? "",
                "arguments": item["arguments"] ?? [String: Any](),
                "result": item["result"] ?? NSNull(),
                "error": item["error"] ?? NSNull(),
                "status": snakeStatus(item["status"]),
            ]
        case "imageView":
            // An image codex viewed. Exec prints no item for one; the row is
            // the one the session file's record reopens as.
            return ["id": id, "type": CodexToolInput.imageViewName, "path": item["path"] as? String ?? ""]
        case "contextCompaction":
            return ["id": id, "type": "context_compaction"]
        default:
            return nil
        }
    }

    /// `inProgress` → `in_progress`; the rest are spelled alike.
    private static func snakeStatus(_ raw: Any?) -> String {
        guard let status = raw as? String else { return "" }
        return status == "inProgress" ? "in_progress" : status
    }

    /// The text of a `plan` item — a `<proposed_plan>` block codex cut out
    /// of the agent's message.
    static func planText(of item: [String: Any]) -> String? {
        guard (item["type"] as? String) == "plan" else { return nil }
        return nonBlank(item["text"] as? String)
    }

    /// The turn's input and output tokens: the thread's running total at
    /// the turn's end less the total before it.
    static func turnUsage(totalBefore: [String: Any]?, totalAfter: [String: Any]?)
    -> (input: Int, output: Int) {
        func int(_ obj: [String: Any]?, _ key: String) -> Int {
            (obj?[key] as? NSNumber)?.intValue ?? 0
        }
        return (max(0, int(totalAfter, "inputTokens") - int(totalBefore, "inputTokens")),
                max(0, int(totalAfter, "outputTokens") - int(totalBefore, "outputTokens")))
    }

    // MARK: - Plan mode is the thread's

    /// The thread's collaboration mode as the newest record in `text`
    /// states it, with the model that record names; nil when no record in
    /// `text` is one that would. Two records carry it: each turn's
    /// `turn_context`, and a `thread_settings_applied` written whenever the
    /// thread's settings are set — by a turn, a resume, or
    /// `thread/settings/update`. Such a record WITHOUT a mode is a turn of
    /// a codex that had none: default.
    static func collaborationMode(in text: String) -> (mode: String, model: String?)? {
        var found: (mode: String, model: String?)? = nil
        text.enumerateLines { line, _ in
            guard line.contains("\"turn_context\"") || line.contains("\"thread_settings_applied\""),
                  let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any]
            else { return }
            let settings: [String: Any]
            switch obj["type"] as? String {
            case "turn_context":
                settings = payload
            case "event_msg" where (payload["type"] as? String) == "thread_settings_applied":
                settings = payload["thread_settings"] as? [String: Any] ?? [:]
            default:
                return
            }
            let mode = settings["collaboration_mode"] as? [String: Any]
            let model = ((mode?["settings"] as? [String: Any])?["model"] as? String)
                ?? (settings["model"] as? String)
            found = ((mode?["mode"] as? String) ?? "default", model)
        }
        return found
    }

    /// Whether the rollout leaves its thread in plan mode, widening until a
    /// record that states the mode is in view (a big turn's records push
    /// the last one far from the end). The model is the one that record
    /// names — what putting it back to default is stated with.
    static func planModeLeftOn(rollout: URL) -> (on: Bool, model: String?) {
        let size = Int(clamping: AgentSessionScanner.contentSize(of: rollout) ?? 0)
        for budget in [256 * 1024, 4 * 1024 * 1024, 32 * 1024 * 1024] {
            guard let tail = AgentSessionScanner.boundedTail(of: rollout, budget: budget)
            else { return (false, nil) }
            if let stated = collaborationMode(in: tail) {
                return (stated.mode == "plan", stated.model)
            }
            if size <= budget { break }
        }
        return (false, nil)
    }

    /// The thread resumed with no permissions stated: putting it back in
    /// Default mode changes that and nothing else.
    static func plainResumeParams(threadId: String, cwd: String) -> [String: Any] {
        ["threadId": threadId, "cwd": cwd, "excludeTurns": true]
    }

    /// `thread/settings/update` putting a thread back to the Default
    /// collaboration mode — what a headless turn needs after a Plan turn.
    static func leavePlanModeParams(threadId: String, model: String) -> [String: Any] {
        ["threadId": threadId,
         "collaborationMode": collaborationMode(.defaultMode, model: model, effort: nil)]
    }

    // MARK: - Codex's own commands: /compact and /review

    /// `thread/compact/start`: codex summarises the thread on request, in a
    /// turn of its own (one `contextCompaction` item), as its terminal's
    /// `/compact` does.
    static func compactStartParams(threadId: String) -> [String: Any] {
        ["threadId": threadId]
    }

    /// `review/start`, inline: codex reviews in a sub-thread of its own and
    /// writes the review into this one — "entered review mode", the review
    /// as codex's message, "exited review mode".
    static func reviewStartParams(threadId: String, target: CodexReviewTarget) -> [String: Any] {
        ["threadId": threadId, "target": target.wire, "delivery": "inline"]
    }

    /// `thread/backgroundTerminals/terminate`: stops one command codex runs
    /// in a background terminal, by the process id codex lists it under.
    static func terminateParams(threadId: String, processId: String) -> [String: Any] {
        ["threadId": threadId, "processId": processId]
    }

    /// The process id codex lists a background terminal under, by the item
    /// that started it, out of a `thread/backgroundTerminals/list` answer.
    static func backgroundProcessId(itemId: String, inListAnswer answer: [String: Any]?) -> String? {
        let listed = answer?["data"] as? [[String: Any]] ?? []
        return listed.first { $0["itemId"] as? String == itemId }?["processId"] as? String
    }

    private static func nonBlank(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

