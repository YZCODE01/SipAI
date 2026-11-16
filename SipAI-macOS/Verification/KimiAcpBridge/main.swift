// KimiAcpBridge — see run.sh for what this pins and why.
import Foundation

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0
nonisolated(unsafe) var skipped = 0

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        passed += 1
        print("  ok    \(name)")
    } else {
        failed += 1
        let d = detail()
        print("  FAIL  \(name)" + (d.isEmpty ? "" : "\n        \(d)"))
    }
}

func skip(_ name: String, _ why: String) {
    skipped += 1
    print("  SKIP  \(name) — \(why)")
}

let srcRoot = CommandLine.arguments[1]
let fakeServerPath = CommandLine.arguments[2]
let stubServerPath = CommandLine.arguments[3]
/// A stand-in MCP server whose tools ask the user for input
/// (../AgentQuestions/mcp_form_server.py).
let formServerPath = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : ""

func json(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

// MARK: - 1. The rules

print("\n1. The rules (KimiAcp, AgentAskingMode, AgentSlashCommands)")

check("the modes are kimi's own ACP modes: Ask When Needed = yolo, Plan = plan; Default = kimi's own configured mode, else Always Ask",
      KimiAcp.modeId(for: AgentAskingMode.kimiAskWhenNeeded) == "yolo"
        && KimiAcp.modeId(for: AgentAskingMode.kimiPlan) == "plan"
        && KimiAcp.modeId(for: nil) == "default"
        && KimiAcp.modeId(for: nil, defaultPermissionMode: "yolo") == "yolo"
        && KimiAcp.modeId(for: nil, defaultPermissionMode: "auto") == "auto"
        && KimiAcp.modeId(for: nil, defaultPermissionMode: "manual") == "default")
check("…and nothing else runs through ACP — Never Ask is kimi's headless run, never claude's own values",
      [AgentAskingMode.kimiNeverAsk, "auto", "manual", "plan", "yolo", "default", "codex-plan"]
        .allSatisfy { KimiAcp.modeId(for: $0) == nil })
check("…unless the turn loads a chosen skill, which only ACP can: then Never Ask runs as kimi's own auto, and the asking modes stay theirs",
      KimiAcp.modeId(for: AgentAskingMode.kimiNeverAsk, loadingSkill: true) == "auto"
        && KimiAcp.modeId(for: "auto", loadingSkill: true) == "auto"
        && KimiAcp.modeId(for: AgentAskingMode.kimiAskWhenNeeded, loadingSkill: true) == "yolo"
        && KimiAcp.modeId(for: nil, defaultPermissionMode: "yolo", loadingSkill: true) == "yolo")
check("a chosen skill rides ahead of the message as kimi's own /skill:name; with none the message is sent as typed",
      KimiAcp.promptText("do X\nnow", skill: "alpha") == "/skill:alpha do X\nnow"
        && KimiAcp.promptText("do X", skill: nil) == "do X")
check("a message that opens on /skill:name and words is drawn as the words with the skill; a bare one, a path or plain text is not",
      KimiAcp.typedSkill("/skill:alpha  do X\nnow").map { $0.name == "alpha" && $0.message == "do X\nnow" } == true
        && KimiAcp.typedSkill("/skill:alpha") == nil
        && KimiAcp.typedSkill("/Users/me/notes.md") == nil
        && KimiAcp.typedSkill("plain words") == nil)
// The message is read for a command as KIMI reads it — its own parser,
// read in its bundle: the name runs to the first SPACE, the rest trimmed
// is the input, and a name with a slash in it is a path. Split at any
// white space, a command followed by a line break read here as a skill
// with words — and to kimi as one long name it does not know.
check("a prompt is read for a command by kimi's own rule: the name to the first space, a path is none",
      KimiAcp.slashCommand("/skill:alpha do X now").map { $0.name == "skill:alpha" && $0.args == "do X now" } == true
        && KimiAcp.slashCommand("/skill:alpha\ndo X now").map { $0.name == "skill:alpha\ndo" && $0.args == "X now" } == true
        && KimiAcp.slashCommand("/compact").map { $0.name == "compact" && $0.args.isEmpty } == true
        && KimiAcp.slashCommand("/Users/me/notes.md read this") == nil
        && KimiAcp.slashCommand("plain") == nil && KimiAcp.slashCommand("/") == nil)
check("…so a command kimi reads across a line break or a tab is no skill's, and is drawn as typed",
      KimiAcp.typedSkill("/skill:alpha\ndo X now") == nil
        && KimiAcp.typedSkill("/skill:alpha\tdo X now") == nil
        && KimiAcp.typedSkill("/skill:alpha do X\nnow").map { $0.name == "alpha" && $0.message == "do X\nnow" } == true)
check("…a skill's bare name is a command to kimi too, where the session has that skill — and only there",
      KimiAcp.typedSkill("/alpha do X", isSkill: { $0 == "alpha" }).map { $0.name == "alpha" && $0.message == "do X" } == true
        && KimiAcp.typedSkill("/alpha do X") == nil
        && KimiAcp.typedSkill("/help me out", isSkill: { $0 == "alpha" }) == nil
        && KimiAcp.typedSkill("/alpha", isSkill: { _ in true }) == nil)
check("kimi's own answer to a command it does not know is recognised",
      KimiAcp.answeredUnknownCommand("Unknown ACP command: /skill:x. Use /help to see available commands.")
        && !KimiAcp.answeredUnknownCommand("Compaction completed."))
var skillTurn = AgentLaunchOptions()
skillTurn.permissionMode = AgentAskingMode.kimiNeverAsk
skillTurn.skillTriggers = [SkillTrigger(name: "alpha")]
check("a kimi turn that loads a skill goes through ACP in Never Ask too; without one, or with no front end, it stays headless",
      AgentTurnDriver.pick(agentKey: "kimi", options: skillTurn, isNewSession: false, frontEndOffered: true) == .kimiAcp
        && AgentTurnDriver.pick(agentKey: "kimi", options: options(AgentAskingMode.kimiNeverAsk),
                                isNewSession: false, frontEndOffered: true) == .kimiPrint
        && AgentTurnDriver.pick(agentKey: "kimi", options: skillTurn, isNewSession: false, frontEndOffered: false) == .kimiPrint)
check("kimi's own default permission mode is read off config.toml's top level, the key bare or quoted — and NOT the legacy default_yolo, which kimi itself ignores when it runs",
      KimiCatalog.parseDefaultPermissionMode("default_permission_mode = \"yolo\"\n") == "yolo"
        && KimiCatalog.parseDefaultPermissionMode("default_permission_mode = \"auto\" # me\n") == "auto"
        && KimiCatalog.parseDefaultPermissionMode("\"default_permission_mode\" = \"yolo\"\n") == "yolo"
        && KimiCatalog.parseDefaultPermissionMode("'default_permission_mode' = 'auto'\n") == "auto"
        && KimiCatalog.parseDefaultPermissionMode("default_yolo = true\n") == nil
        && KimiCatalog.parseDefaultPermissionMode("default_yolo = true\ndefault_permission_mode = \"manual\"\n") == "manual"
        && KimiCatalog.parseDefaultPermissionMode("default_permission_mode = \"bogus\"\n") == nil
        && KimiCatalog.parseDefaultPermissionMode("[providers.x]\ndefault_permission_mode = \"yolo\"\n") == nil
        && KimiCatalog.parseDefaultPermissionMode("") == nil)
check("a mode is stated only where the session needs telling: not to a new session on Default, which kimi has just opened in its own configured mode; not `plan` to a session already planning, which kimi refuses",
      KimiAcp.statedMode("default", isDefault: true, isNewSession: true, planModeOn: false) == nil
        && KimiAcp.statedMode("yolo", isDefault: true, isNewSession: true, planModeOn: true) == nil
        && KimiAcp.statedMode("yolo", isDefault: true, isNewSession: false, planModeOn: false) == "yolo"
        && KimiAcp.statedMode("default", isDefault: true, isNewSession: false, planModeOn: true) == "default"
        && KimiAcp.statedMode("yolo", isDefault: false, isNewSession: true, planModeOn: false) == "yolo"
        && KimiAcp.statedMode("plan", isDefault: false, isNewSession: true, planModeOn: false) == "plan"
        && KimiAcp.statedMode("plan", isDefault: false, isNewSession: false, planModeOn: true) == nil
        && KimiAcp.statedMode("plan", isDefault: false, isNewSession: true, planModeOn: true) == nil
        && KimiAcp.statedMode("yolo", isDefault: false, isNewSession: false, planModeOn: true) == "yolo")
check("offered: unread → nil (the send waits), below 2.1.1 → none, 2.1.1 and up → all three",
      AgentAskingMode.offered(agentKey: "kimi", kimiVersion: nil) == nil
        && AgentAskingMode.offered(agentKey: "kimi", kimiVersion: "2.1.0") == []
        && AgentAskingMode.offered(agentKey: "kimi", kimiVersion: "garbled") == []
        && AgentAskingMode.offered(agentKey: "kimi", kimiVersion: "2.1.1") == AgentAskingMode.kimi
        && AgentAskingMode.offered(agentKey: "kimi", kimiVersion: "2.3.0") == AgentAskingMode.kimi)
check("…and no other agent is offered kimi's modes (codex is offered its own)",
      AgentAskingMode.offered(agentKey: "claude_code", kimiVersion: "9.9.9") == []
        && AgentAskingMode.offered(agentKey: "codex", kimiVersion: "9.9.9", codexVersion: "9.9.9",
                                   codexModes: ["plan", "default"]) == AgentAskingMode.codex)
check("slash commands: kimi's ACP server answers its own; the headless kimi sends them to the model",
      AgentSlashCommands.resolvesLocally(agentKey: "kimi", driver: .kimiAcp) == true
        && AgentSlashCommands.resolvesLocally(agentKey: "kimi", driver: .kimiPrint) == false
        && AgentSlashCommands.resolvesLocally(agentKey: "kimi") == false
        && AgentSlashCommands.resolvesLocally(agentKey: "claude_code", driver: .claudePrint) == true
        && AgentSlashCommands.resolvesLocally(agentKey: "codex", driver: .codexExec) == false)
check("the handshake declares forms and neither files nor a terminal",
      { () -> Bool in
          let p = KimiAcp.initializeParams(clientVersion: "1.0.5")
          let caps = p["clientCapabilities"] as? [String: Any]
          let fs = caps?["fs"] as? [String: Any]
          return (p["protocolVersion"] as? Int) == 1
              && (caps?["terminal"] as? Bool) == false
              && (fs?["readTextFile"] as? Bool) == false && (fs?["writeTextFile"] as? Bool) == false
              && (caps?["elicitation"] as? [String: Any])?["form"] != nil
      }())

// Requests in the shape `kimi acp` sends them (captured from kimi 2.1.1).
let canonicalOptions: [[String: Any]] = [
    ["optionId": "approve_once", "name": "Approve once", "kind": "allow_once"],
    ["optionId": "approve_always", "name": "Approve for this session", "kind": "allow_always"],
    ["optionId": "reject", "name": "Reject", "kind": "reject_once"],
]
func request(title: String, content: [[String: Any]], options: [[String: Any]] = canonicalOptions) -> [String: Any] {
    ["sessionId": "session_x", "options": options,
     "toolCall": ["toolCallId": "0:c1", "title": title, "content": content]]
}
func textItem(_ s: String) -> [String: Any] {
    ["type": "content", "content": ["type": "text", "text": s]]
}

let bash = KimiAcp.permissionCard(
    params: request(title: "Bash", content: [textItem("Requesting approval to Running: ls -la")]),
    arguments: ["command": "ls -la", "description": "List the folder"], cwd: "/private/tmp/w")
if case .permission(let content)? = bash?.presentation {
    check("a command: kimi's options verbatim, in kimi's order",
          content.choices.map(\.id) == ["approve_once", "approve_always", "reject"]
            && content.choices.map(\.label) == ["Approve once", "Approve for this session", "Reject"])
    check("…their kinds as roles: once = accept, for the session = the lighter accept, reject = the refusal",
          content.choices.map(\.role) == [.accept, .acceptForSession, .decline])
    check("…Return starts on Approve once, Esc takes Reject",
          CardChoiceLayout.initial(content.choices) == "approve_once"
            && CardChoiceLayout.cancel(content.choices) == "reject")
    check("…the command with its folder and the model's reason; the badge is the tool",
          content.preview == .command("ls -la", cwd: "/private/tmp/w", reason: "List the folder")
            && bash?.toolName == "Bash", "\(content.preview)")
} else {
    check("a command request becomes a permission card", false, "\(String(describing: bash?.presentation))")
}

let edit = KimiAcp.permissionCard(
    params: request(title: "Edit", content: [
        ["type": "diff", "path": "/w/seed.txt", "oldText": "two", "newText": "TWO\nthree"],
        textItem("Requesting approval to Editing seed.txt")]),
    arguments: ["path": "seed.txt", "old_string": "two", "new_string": "TWO\nthree"], cwd: "/w")
check("an edit: the diff kimi sent, its old lines removed and its new ones added",
      edit?.presentation == .permission(PermissionCardContent(
          prompt: nil,
          preview: .fileChanges([CardFileChange(path: "/w/seed.txt", kind: "", diff: "-two\n+TWO\n+three")], reason: nil),
          choices: KimiAcp.choices(for: KimiAcp.options(in: ["options": canonicalOptions])))),
      "\(String(describing: edit?.presentation))")

let writeCard = KimiAcp.permissionCard(
    params: request(title: "Write", content: [textItem("Requesting approval to Writing probe.txt")]),
    arguments: ["path": "probe.txt", "content": "alpha\nbeta\n"], cwd: "/private/tmp/w")
if case .permission(let content)? = writeCard?.presentation {
    check("a write: every line of the new file added, its path resolved in the session's folder",
          content.preview == .fileChanges([CardFileChange(path: "/private/tmp/w/probe.txt", kind: "",
                                                          diff: "+alpha\n+beta")], reason: nil),
          "\(content.preview)")
} else {
    check("a write request becomes a permission card", false)
}

let other = KimiAcp.permissionCard(
    params: request(title: "Agent", content: [textItem("Requesting approval to Starting a subagent")]),
    arguments: ["prompt": "x"], cwd: "/w")
if case .permission(let content)? = other?.presentation {
    check("anything else: kimi's own sentence about it", content.preview == .text("Requesting approval to Starting a subagent"))
} else {
    check("an unknown tool's request becomes a permission card", false)
}
check("a request with no options to answer with is no card (the driver answers it cancelled)",
      KimiAcp.permissionCard(params: request(title: "Bash", content: [], options: []),
                             arguments: nil, cwd: "/w") == nil)

let planOptions: [[String: Any]] = [
    ["optionId": "plan_approve", "name": "Approve", "kind": "allow_once"],
    ["optionId": "plan_revise", "name": "Revise", "kind": "reject_once"],
    ["optionId": "plan_reject_and_exit", "name": "Reject and Exit", "kind": "reject_once"],
]
let plan = KimiAcp.permissionCard(
    params: request(title: "ExitPlanMode", content: [
        textItem("Plan saved to: /h/sessions/b/s/agents/main/plans/p.md\n\n# Plan\n\n1. Step one"),
        textItem("Requesting approval to Exit plan mode")], options: planOptions),
    arguments: [:], cwd: "/w")
if case .plan(let content)? = plan?.presentation {
    check("a plan review is a PLAN card: the plan, and the file kimi saved it to",
          content.plan == "# Plan\n\n1. Step one" && content.filePath == "/h/sessions/b/s/agents/main/plans/p.md")
    check("…kimi's answers: Approve, Revise (Esc), Reject and Exit — and the modes an approval continues in",
          content.choices.map(\.label) == ["Approve", "Revise", "Reject and Exit"]
            && CardChoiceLayout.cancel(content.choices) == "plan_revise"
            && content.continueModes.map(\.id) == [AgentAskingMode.adoptDefault, AgentAskingMode.kimiAskWhenNeeded,
                                                    AgentAskingMode.kimiNeverAsk])
    let drawn = PlanContinue.first(content)
    check("…drawn as Claude Code's plan dialog draws them: the one approval once per mode, Return on Default",
          drawn.map(\.label) == ["Approve, then Default", "Approve, then Ask When Needed",
                                 "Approve, then Never Ask", "Revise", "Reject and Exit"]
            && drawn.prefix(3).map { PlanContinue.split($0.id).answer } == ["plan_approve", "plan_approve", "plan_approve"]
            && drawn.prefix(3).map(\.adoptsMode) == [AgentAskingMode.adoptDefault, AgentAskingMode.kimiAskWhenNeeded,
                                                     AgentAskingMode.kimiNeverAsk]
            && CardChoiceLayout.initial(drawn) == PlanContinue.id(answer: "plan_approve",
                                                                  mode: AgentAskingMode.adoptDefault))
    check("…each goes back to kimi as kimi's own answer, the mode set after it",
          (KimiAcp.permissionReply(to: .chose(drawn[1].id), options: KimiAcp.options(in: request(
              title: "ExitPlanMode", content: [], options: planOptions)))["outcome"] as? [String: Any])?["optionId"]
            as? String == "plan_approve"
            && KimiAcp.acpModeId(continuingIn: AgentAskingMode.kimiAskWhenNeeded, defaultPermissionMode: nil) == "yolo"
            && KimiAcp.acpModeId(continuingIn: AgentAskingMode.kimiNeverAsk, defaultPermissionMode: nil) == "auto"
            && KimiAcp.acpModeId(continuingIn: AgentAskingMode.adoptDefault, defaultPermissionMode: "yolo") == "yolo"
            && KimiAcp.acpModeId(continuingIn: AgentAskingMode.adoptDefault, defaultPermissionMode: nil) == "default")
    check("…Reject and Exit only ends the planning: a chip ON Plan goes to Default, a chip on another mode stays; Revise keeps planning, and the chip goes to Plan with the session",
          content.choices.map(\.adoptsMode) == [nil, AgentAskingMode.kimiPlan, AgentAskingMode.adoptLeavingPlan]
            && AgentAskingMode.adoption(of: AgentAskingMode.adoptLeavingPlan, from: AgentAskingMode.kimiPlan) == .set(nil)
            && AgentAskingMode.adoption(of: AgentAskingMode.adoptLeavingPlan,
                                        from: AgentAskingMode.kimiAskWhenNeeded) == .keep
            && AgentAskingMode.adoption(of: AgentAskingMode.kimiPlan,
                                        from: AgentAskingMode.kimiAskWhenNeeded) == .set(AgentAskingMode.kimiPlan))
    // Return starts on the mode the turn was sent in.
    func startsOn(_ turnMode: String?) -> String? {
        guard case .plan(let content)? = KimiAcp.permissionCard(
            params: request(title: "ExitPlanMode", content: [textItem("# Plan")], options: planOptions),
            arguments: [:], cwd: "/w", turnMode: turnMode)?.presentation else { return nil }
        return CardChoiceLayout.initial(PlanContinue.first(content)).map { PlanContinue.split($0).mode ?? "?" }
    }
    check("…Return starts on the mode the turn was sent in: Ask When Needed for a plan drawn up under it, Default for a Default or a Plan turn",
          startsOn(AgentAskingMode.kimiAskWhenNeeded) == AgentAskingMode.kimiAskWhenNeeded
            && startsOn(nil) == AgentAskingMode.adoptDefault
            && startsOn(AgentAskingMode.kimiPlan) == AgentAskingMode.adoptDefault,
          "\(String(describing: startsOn(AgentAskingMode.kimiAskWhenNeeded))) \(String(describing: startsOn(nil)))")
    // A Never Ask turn runs here only to load a skill: a plan reviewed in
    // it must not move the chip to Default at a keystroke either.
    check("…and Never Ask for a turn that ran here under it to load a skill",
          startsOn(AgentAskingMode.kimiNeverAsk) == AgentAskingMode.kimiNeverAsk,
          "\(String(describing: startsOn(AgentAskingMode.kimiNeverAsk)))")
} else {
    check("a plan review becomes a plan card", false, "\(String(describing: plan?.presentation))")
}
let planWithApproaches = KimiAcp.permissionCard(
    params: request(title: "ExitPlanMode", content: [textItem("A or B")], options: [
        ["optionId": "plan_opt_0", "name": "Approach A (Recommended)", "kind": "allow_once"],
        ["optionId": "plan_opt_1", "name": "Approach B", "kind": "allow_once"],
        ["optionId": "plan_revise", "name": "Revise", "kind": "reject_once"],
        ["optionId": "plan_reject_and_exit", "name": "Reject and Exit", "kind": "reject_once"]]),
    arguments: nil, cwd: "/w")
if case .plan(let content)? = planWithApproaches?.presentation {
    check("a plan offering approaches: one approval per approach, each in the plan's own words, drawn as kimi sends them",
          PlanContinue.first(content).prefix(2).map(\.label) == ["Approach A (Recommended)", "Approach B"]
            && content.choices.prefix(2).allSatisfy { $0.role == .accept && $0.adoptsMode == nil }
            && content.filePath == nil && content.plan == "A or B")
    let approachB = content.choices[1]
    let second = PlanContinue.second(after: approachB, in: content)
    check("…an approach picked asks for the mode next: that approach once per mode, and Back (Esc)",
          PlanContinue.asksForMode(approachB, in: content)
            && second.map(\.label) == ["Approach B, then Default", "Approach B, then Ask When Needed",
                                       "Approach B, then Never Ask", "Back"]
            && second.prefix(3).allSatisfy { PlanContinue.split($0.id).answer == "plan_opt_1" }
            && CardChoiceLayout.cancel(second) == PlanContinue.backId
            && !PlanContinue.asksForMode(second[0], in: content))
} else {
    check("a plan with approaches becomes a plan card", false)
}
check("a plan text with a path and nothing after it",
      KimiAcp.planContent(from: "Plan saved to: /x/p.md").plan == ""
        && KimiAcp.planContent(from: "Plan saved to: /x/p.md").filePath == "/x/p.md")

let opts = KimiAcp.options(in: ["options": canonicalOptions])
func outcome(_ reply: [String: Any]) -> String {
    let o = reply["outcome"] as? [String: Any] ?? [:]
    return "\(o["outcome"] as? String ?? "?")/\(o["optionId"] as? String ?? "-")"
}
check("the reply: the answer chosen, by kimi's own id",
      outcome(KimiAcp.permissionReply(to: .chose("approve_always"), options: opts)) == "selected/approve_always")
check("…an id kimi did not offer is never sent (kimi would read it as a refusal) — cancelled instead",
      outcome(KimiAcp.permissionReply(to: .chose("nonsense"), options: opts)) == "cancelled/-")
check("…Stop, a quit and a card that could not be drawn are cancelled, never an error",
      [CardResolution.cancelled, .declined(.unreadable), .declined(.unanswerable), .skipped]
        .allSatisfy { outcome(KimiAcp.permissionReply(to: $0, options: opts)) == "cancelled/-" })

// Questions, as `elicitation/create` carries them.
let elicitation: [String: Any] = [
    "sessionId": "session_x", "toolCallId": "0:c1", "mode": "form",
    "message": "Which database should we use?\nWhich extras do you want?",
    "requestedSchema": [
        "type": "object",
        "properties": [
            "q0": ["type": "string", "title": "DB",
                   "oneOf": [["const": "Postgres", "title": "Postgres", "description": "robust"],
                             ["const": "SQLite", "title": "SQLite", "description": "simple"]]],
            "q1": ["type": "array", "title": "", "minItems": 1,
                   "items": ["anyOf": [["const": "Lint", "title": "Lint", "description": "l"],
                                       ["const": "Tests", "title": "Tests", "description": "t"],
                                       ["const": "Docs", "title": "Docs", "description": "d"]]]],
        ],
        "required": ["q0", "q1"],
    ],
]
let form = KimiAcp.questionForm(params: elicitation)
check("a question form: every question, its own words from the message, its header, its options",
      form?.questions.map(\.text) == ["Which database should we use?", "Which extras do you want?"]
        && form?.questions.map(\.header) == ["DB", ""]
        && form?.questions[0].options.map(\.label) == ["Postgres", "SQLite"]
        && form?.questions[0].options.map(\.description) == ["robust", "simple"]
        && form?.questions.map(\.multiSelect) == [false, true]
        && form?.questions.map(\.id) == ["q0", "q1"],
      "\(String(describing: form))")
check("…no answer in the user's own words (kimi's form has no field for one); Skip yes, Chat no",
      form?.questions.allSatisfy { !$0.allowsOther } == true
        && form?.offersSkip == true && form?.offersChat == false)
if let form {
    let grid = AgentQuestionKeys.grid(for: form, page: 0)
    check("…so the keyboard has no stop for an own answer or for Chat",
          !grid.rows.joined().contains(.other) && !grid.rows.joined().contains(.chat)
            && grid.rows.joined().contains(.skip))
}
check("a header that only repeats the question is no header (kimi falls back to the question)",
      KimiAcp.questionForm(params: ["mode": "form", "message": "Pick one?",
                                    "requestedSchema": ["properties": ["q0": [
                                        "type": "string", "title": "Pick one?",
                                        "oneOf": [["const": "A"], ["const": "B"]]]],
                                                        "required": ["q0"]]])?
        .questions.first?.header == "")
check("a message that does not split one line per question: each question is its title",
      KimiAcp.questionForm(params: ["mode": "form", "message": "only one line",
                                    "requestedSchema": ["properties": [
                                        "q0": ["type": "string", "title": "First?", "oneOf": [["const": "A"], ["const": "B"]]],
                                        "q1": ["type": "string", "title": "Second?", "oneOf": [["const": "C"], ["const": "D"]]]],
                                                        "required": ["q0", "q1"]]])?
        .questions.map(\.text) == ["First?", "Second?"])
check("a form kimi did not order is read in its questions' order",
      KimiAcp.questionForm(params: ["mode": "form", "message": "a\nb\nc",
                                    "requestedSchema": ["properties": [
                                        "q10": ["type": "string", "title": "x", "oneOf": [["const": "1"], ["const": "2"]]],
                                        "q2": ["type": "string", "title": "y", "oneOf": [["const": "3"], ["const": "4"]]],
                                        "q0": ["type": "string", "title": "z", "oneOf": [["const": "5"], ["const": "6"]]]]]])?
        .questions.map(\.id) == ["q0", "q2", "q10"])
check("a form that cannot be drawn faithfully is no form (declined, never half-drawn)",
      KimiAcp.questionForm(params: ["mode": "url", "message": "x", "requestedSchema": ["properties": ["q0": [:]]]]) == nil
        && KimiAcp.questionForm(params: ["mode": "form", "message": "x",
                                         "requestedSchema": ["properties": ["q0": ["type": "string", "oneOf": [["const": 1]]]]]]) == nil
        && KimiAcp.questionForm(params: ["mode": "form", "message": "x", "requestedSchema": ["properties": [:]]]) == nil)

if let form {
    var answers: [String: AgentQuestionAnswer] = [:]
    answers["Which database should we use?"] = AgentQuestionAnswer(labels: ["SQLite"])
    answers["Which extras do you want?"] = AgentQuestionAnswer(labels: ["Docs", "Lint", "Nope"])
    let reply = KimiAcp.questionReply(to: .answered(answers), form: form)
    let content = reply["content"] as? [String: Any] ?? [:]
    check("the answer: accepted, one label per single question, the labels picked in kimi's order per multiple one",
          reply["action"] as? String == "accept" && content["q0"] as? String == "SQLite"
            && content["q1"] as? [String] == ["Lint", "Docs"], "\(reply)")
    check("…a form answered nowhere is a dismissal, not an empty accept",
          KimiAcp.questionReply(to: .answered([:]), form: form)["action"] as? String == "decline")
    check("…Skip, Non-stop and a card nobody can answer dismiss; Stop and a quit cancel",
          [CardResolution.skipped, .declined(.nonStop), .declined(.unanswerable), .declined(.unreadable)]
            .allSatisfy { KimiAcp.questionReply(to: $0, form: form)["action"] as? String == "decline" }
            && KimiAcp.questionReply(to: .cancelled, form: form)["action"] as? String == "cancel")
}

// What kimi streams before it asks.
check("a call's input: the parsed input once kimi sends it",
      KimiAcp.toolCallArguments(update: ["sessionUpdate": "tool_call_update", "toolCallId": "0:c1",
                                         "rawInput": ["command": "ls"]])?.arguments["command"] as? String == "ls")
check("…before that, the arguments text kimi streamed (what a card is drawn from — kimi asks first)",
      KimiAcp.toolCallArguments(update: ["sessionUpdate": "tool_call", "toolCallId": "0:c1",
                                         "content": [textItem("{\"command\": \"ls -la\"}")]])?
        .arguments["command"] as? String == "ls -la")
check("…a text not yet whole, or an update that is no call, is nothing",
      KimiAcp.toolCallArguments(update: ["sessionUpdate": "tool_call", "toolCallId": "0:c1",
                                         "content": [textItem("{\"command\": \"l")]]) == nil
        && KimiAcp.toolCallArguments(update: ["sessionUpdate": "agent_message_chunk"]) == nil)
check("a streamed chunk's text — kept only for a prompt kimi answers itself",
      KimiAcp.messageChunk(update: ["sessionUpdate": "agent_message_chunk",
                                    "content": ["type": "text", "text": "Session: s"]]) == "Session: s"
        && KimiAcp.messageChunk(update: ["sessionUpdate": "agent_thought_chunk",
                                         "content": ["type": "text", "text": "x"]]) == nil)

// The binding an ACP turn leaves behind — records in kimi's own shape.
let envLocal = #"{"type":"environment.set_binding","environmentId":"local","agentId":"main","time":1}"#
let envAcp = #"{"type":"environment.set_binding","environmentId":"acp:session_db45","cwd":"/w/x","agentId":"main","time":2}"#
let now = Date(timeIntervalSince1970: 1_790_833_314.853)
check("a session left bound to ACP is handed back to the binding it had, in kimi's own key order",
      KimiRuntimeBinding.restoreLine(head: envLocal, tail: envLocal + "\n" + envAcp, now: now)
        == #"{"type":"environment.set_binding","environmentId":"local","agentId":"main","time":1790833314853}"#,
      String(describing: KimiRuntimeBinding.restoreLine(head: envLocal, tail: envLocal + "\n" + envAcp, now: now)))
check("…the earlier binding found at the head when the tail holds only the ACP one",
      KimiRuntimeBinding.restoreLine(head: envLocal, tail: envAcp, now: now)?.contains(#""environmentId":"local""#) == true)
check("…a session already on its own environment owes nothing; one never bound owes nothing",
      KimiRuntimeBinding.restoreLine(head: envLocal, tail: envAcp + "\n" + envLocal, now: now) == nil
        && KimiRuntimeBinding.restoreLine(head: "", tail: #"{"type":"turn.prompt"}"#, now: now) == nil)
let envRemote = #"{"type":"environment.set_binding","environmentId":"ssh:tower","cwd":"/srv/x","agentId":"main","time":1}"#
check("…an environment of the user's own goes back with its folder, in kimi's own key order",
      KimiRuntimeBinding.restoreLine(head: "", tail: envRemote + "\n" + envAcp, now: now)
        == #"{"type":"environment.set_binding","environmentId":"ssh:tower","cwd":"/srv/x","agentId":"main","time":1790833314853}"#,
      String(describing: KimiRuntimeBinding.restoreLine(head: "", tail: envRemote + "\n" + envAcp, now: now)))
check("…a folder is the record's it rode on: `local` before ACP had none, and the ACP turn's stays out of it",
      KimiRuntimeBinding.restoreLine(head: envLocal, tail: envAcp, now: now)?.contains("cwd") == false)
check("…with no earlier binding at all: `local`, in the folder the ACP turn ran in",
      KimiRuntimeBinding.restoreLine(head: "", tail: envAcp, now: now)
        == #"{"type":"environment.set_binding","environmentId":"local","cwd":"/w/x","agentId":"main","time":1790833314853}"#,
      String(describing: KimiRuntimeBinding.restoreLine(head: "", tail: envAcp, now: now)))
check("…a path keeps its slashes and quotes as JSON writes them",
      KimiRuntimeBinding.restoreLine(head: "", tail: envAcp.replacingOccurrences(of: "/w/x", with: #"/w/a \"b\""#), now: now)?
        .contains(#""cwd":"/w/a \"b\"""#) == true)

// The older spelling, which a kimi that writes it still replays: the record
// handed back is the one the wire's newest binding used.
let local = #"{"type":"runtime.set_binding","workspaceId":"wd_w_f63a0effe972","runtimeId":"local","agentId":"main","time":1}"#
let acp = #"{"type":"runtime.set_binding","workspaceId":"wd_w_f63a0effe972","runtimeId":"acp:session_db45","agentId":"main","time":2}"#
check("the older record: handed back in its own shape and key order",
      KimiRuntimeBinding.restoreLine(head: local, tail: local + "\n" + acp, now: now)
        == #"{"type":"runtime.set_binding","workspaceId":"wd_w_f63a0effe972","runtimeId":"local","agentId":"main","time":1790833314853}"#,
      String(describing: KimiRuntimeBinding.restoreLine(head: local, tail: local + "\n" + acp, now: now)))
check("…the earlier binding found at the head when the tail holds only the ACP one",
      KimiRuntimeBinding.restoreLine(head: local, tail: acp, now: now)?.contains(#""runtimeId":"local""#) == true)
check("…a session already on its own runtime owes nothing; one never bound owes nothing",
      KimiRuntimeBinding.restoreLine(head: local, tail: acp + "\n" + local, now: now) == nil
        && KimiRuntimeBinding.restoreLine(head: "", tail: #"{"type":"turn.prompt"}"#, now: now) == nil)
check("…a runtime of the user's own is what goes back, not an assumed `local`",
      KimiRuntimeBinding.restoreLine(head: "", tail: local.replacingOccurrences(of: "\"local\"", with: "\"tower:1\"") + "\n" + acp,
                                 now: now)?.contains(#""runtimeId":"tower:1""#) == true)

// A session kimi has run under both spellings. Only the newest record counts,
// and what goes back is found among records of its own spelling: the older
// spelling's id means nothing to a kimi that writes the newer one.
check("a wire with both records: an older ACP binding below a newer own one owes nothing",
      KimiRuntimeBinding.restoreLine(head: local, tail: acp + "\n" + envLocal, now: now) == nil)
check("…a newer ACP binding is handed back in the newer shape, whatever the older one said",
      KimiRuntimeBinding.restoreLine(head: "", tail: local.replacingOccurrences(of: "\"local\"", with: "\"tower:1\"")
                                        + "\n" + envLocal + "\n" + envAcp, now: now)
        == #"{"type":"environment.set_binding","environmentId":"local","agentId":"main","time":1790833314853}"#)
check("…and a binding in the other spelling is never the one that goes back",
      KimiRuntimeBinding.restoreLine(head: local, tail: envAcp, now: now)
        == #"{"type":"environment.set_binding","environmentId":"local","cwd":"/w/x","agentId":"main","time":1790833314853}"#,
      String(describing: KimiRuntimeBinding.restoreLine(head: local, tail: envAcp, now: now)))

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kimiacp-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let wireFile = tmp.appendingPathComponent("wire.jsonl")
try? (envLocal + "\n" + envAcp).write(to: wireFile, atomically: true, encoding: .utf8)  // no trailing newline
let restored = KimiRuntimeBinding.restore(wire: wireFile, now: now)
let afterRestore = (try? String(contentsOf: wireFile, encoding: .utf8)) ?? ""
check("handing back appends ONE line, after a newline when the file was cut off mid-record",
      restored && afterRestore.components(separatedBy: "\n").count == 4
        && afterRestore.hasSuffix(#""time":1790833314853}"# + "\n")
        && afterRestore.contains(envAcp + "\n{"), afterRestore)
check("…and a second hand-back writes nothing",
      KimiRuntimeBinding.restore(wire: wireFile, now: now)
        && ((try? String(contentsOf: wireFile, encoding: .utf8)) ?? "") == afterRestore)
check("…a session whose record is gone owes nothing",
      KimiRuntimeBinding.restore(wire: tmp.appendingPathComponent("absent.jsonl")))
// The ACP binding far from the end (a long turn), and a tool call near the
// end that merely NAMES the record — a search for it. The name is not a
// binding: the read must widen to the record itself.
let farWire = tmp.appendingPathComponent("far.jsonl")
let filler = #"{"type":"context.append_loop_event","agentId":"main","event":{"type":"content.part","part":{"type":"text","text":""# + String(repeating: "x", count: 4000) + #""}},"time":1}"#
let mention = #"{"type":"context.append_loop_event","agentId":"main","event":{"type":"tool.call","toolCallId":"c9","name":"Grep","args":{"pattern":"runtime.set_binding"}},"time":2}"#
let envMention = mention.replacingOccurrences(of: "runtime.set_binding", with: "environment.set_binding")
for (own, bound, name, ending) in [
    (local, acp, mention, #""runtimeId":"local","agentId":"main","time":1790833314853}"#),
    (envLocal, envAcp, envMention, #""environmentId":"local","agentId":"main","time":1790833314853}"#),
] {
    let farText = ([own, bound] + Array(repeating: filler, count: 90) + [name]).joined(separator: "\n") + "\n"
    try? farText.write(to: farWire, atomically: true, encoding: .utf8)
    let farRestored = KimiRuntimeBinding.restore(wire: farWire, now: now)
    let farAfter = (try? String(contentsOf: farWire, encoding: .utf8)) ?? ""
    check("handing back reads binding RECORDS, never the name: a window that only mentions it is widened past",
          farText.utf8.count > 300_000 && farRestored && farAfter.count > farText.count
            && farAfter.hasSuffix(ending + "\n")
            && KimiRuntimeBinding.bindings(name).isEmpty && KimiRuntimeBinding.bindings(bound).count == 1,
          "restored \(farRestored), grew by \(farAfter.count - farText.count)")
}

// Read before every turn, for every agent, over windows of tens of megabytes whose
// binding may be the first line of all. Judged against a per-line `String.contains`
// run beside it, which a loaded Mac slows alike: a fixed time would fail under load.
let longWindow = String(repeating: filler + "\n", count: 400)
let scanStart = Date()
_ = KimiRuntimeBinding.bindings(longWindow)
let scanCost = Date().timeIntervalSince(scanStart)
let askedStart = Date()
longWindow.enumerateLines { line, _ in _ = line.contains("runtime.set_binding") }
let askedCost = Date().timeIntervalSince(askedStart)
check("the binding read searches bytes: a window costs a fraction of asking each line",
      scanCost * 3 < askedCost, "\(scanCost) s against \(askedCost) s over \(longWindow.utf8.count) bytes")

// Every agent of a session keeps a record of its own, and a subagent's opens on
// the binding of the agent that started it: it has no earlier one to go back to.
let sessionFolder = tmp.appendingPathComponent("session")
let mainWire = sessionFolder.appendingPathComponent("agents/main/wire.jsonl")
let subWire = sessionFolder.appendingPathComponent("agents/agent-0/wire.jsonl")
let subAcp = envAcp.replacingOccurrences(of: #""agentId":"main""#, with: #""agentId":"agent-0""#)
for wire in [mainWire, subWire] {
    try? FileManager.default.createDirectory(at: wire.deletingLastPathComponent(), withIntermediateDirectories: true)
}
try? (envLocal + "\n" + envAcp + "\n").write(to: mainWire, atomically: true, encoding: .utf8)
try? (subAcp + "\n").write(to: subWire, atomically: true, encoding: .utf8)
let handedAll = KimiRuntimeBinding.restore(sessionDir: sessionFolder)
let mainAfter = (try? String(contentsOf: mainWire, encoding: .utf8)) ?? ""
let subAfter = (try? String(contentsOf: subWire, encoding: .utf8)) ?? ""
check("every agent of a session is handed back, each in its own record",
      handedAll && KimiRuntimeBinding.bindings(mainAfter).last?["environmentId"] as? String == "local"
        && KimiRuntimeBinding.bindings(subAfter).last?["environmentId"] as? String == "local"
        && KimiRuntimeBinding.bindings(subAfter).last?["agentId"] as? String == "agent-0"
        && KimiRuntimeBinding.bindings(subAfter).last?["cwd"] as? String == "/w/x",
      subAfter)
check("…and a session with no agents, or no such folder, owes nothing",
      KimiRuntimeBinding.restore(sessionDir: tmp.appendingPathComponent("absent")))

// Reading the turn off the record — kimi's own record shapes.
var follow = KimiAcpWireFollow()
var followed: [StreamEvent] = []
let recorded = [
    #"{"type":"turn.prompt","agentId":"main","input":[{"type":"text","text":"SIPAI-BASH please"}],"origin":{"kind":"user"},"promptId":"msg_A","turnId":0,"time":1790833025420}"#,
    #"{"type":"context.append_message","agentId":"main","message":{"role":"user","content":[{"type":"text","text":"SIPAI-BASH please"}],"id":"msg_A","toolCalls":[],"origin":{"kind":"user"}},"time":1790833025420}"#,
    #"{"type":"context.append_message","agentId":"main","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>\nToday's date is 2026-09-30.\n</system-reminder>"}],"toolCalls":[],"origin":{"kind":"injection"}},"time":1790833025421}"#,
    #"{"type":"turn.step.retrying","agentId":"main","turnId":0,"step":1,"failedAttempt":1,"nextAttempt":2,"maxAttempts":10,"delayMs":584.8,"errorName":"APIStatusError","errorMessage":"500 upstream exploded","statusCode":500,"time":1790833059133}"#,
    #"{"type":"context.append_loop_event","agentId":"main","event":{"type":"tool.call","toolCallId":"c1","name":"Bash","args":{"command":"sleep 6","run_in_background":true}},"time":1790833025430}"#,
    #"{"type":"usage.record","usageScope":"turn","usage":{"inputOther":10,"output":1,"inputCacheRead":5,"inputCacheCreation":2},"model":"fake/fake-model","time":1790833025431}"#,
    #"{"type":"task.started","agentId":"main","info":{"taskId":"bash-1","description":"bg","status":"running","detached":true,"startedAt":1790833025440,"endedAt":null,"timeoutMs":600000,"kind":"process"},"time":1790833025440}"#,
    #"{"type":"context.append_loop_event","agentId":"main","event":{"type":"tool.result","toolCallId":"c1","result":{"output":"task_id: bash-1"}},"time":1790833025441}"#,
    #"{"type":"context.append_loop_event","agentId":"main","event":{"type":"content.part","part":{"type":"text","text":"started it"}},"time":1790833025450}"#,
    #"{"type":"turn.ended","agentId":"main","turnId":0,"reason":"completed","durationMs":79,"time":1790833025460}"#,
]
var retrySeen: String? = nil
var pendingMidway = false
for (i, line) in recorded.enumerated() {
    // Read at the moment the turn ran, as the waits below count from.
    followed += follow.feed(line: line, now: Date(timeIntervalSince1970: 1_790_833_025.5))
    if i == 3 { retrySeen = follow.retryNotice }
    if i == 6 { pendingMidway = follow.tasksPending }
}
func signature(_ e: StreamEvent) -> String {
    switch e.kind {
    case .userMessage(let t): return (e.isSystemNotice ? "notice:" : "user:") + t
    case .assistantText(let t): return "assistant:" + t
    case .toolUse(let id, let name, _): return "tool_use:\(id):\(name)"
    case .toolResult(let id, let out, let err): return "tool_result:\(id):\(err):\(out.prefix(40))"
    case .error(let m): return "error:" + m
    case .interrupted(let m): return "interrupted:" + m
    case .compaction: return "compaction"
    default: return "other"
    }
}
check("the turn off the record: the prompt's own row is not drawn twice, kimi's reminder not at all",
      followed.map(signature) == ["tool_use:c1:Bash", "tool_result:c1:false:task_id: bash-1", "assistant:started it"],
      "\(followed.map(signature))")
check("…a retry in kimi's terminal's words, and gone once a step lands",
      retrySeen == "Retrying (2/10) · APIStatusError · 500 · 500 upstream exploded" && follow.retryNotice == nil,
      "\(String(describing: retrySeen)) / \(String(describing: follow.retryNotice))")
check("…the context footprint as the chip counts it (input side only)", follow.contextTokens == 17)
check("…a background task is pending until kimi records its end, with kimi's own deadline",
      pendingMidway && follow.tasksPending && follow.taskDeadline == Date(timeIntervalSince1970: 1_790_833_025.44 + 600))
check("…and once the turn has ended on its answer, the transcript's line names it by its description",
      follow.awaitedTasks.map(\.description) == ["bg"], "\(follow.awaitedTasks)")
// A compaction the user asked for: kimi answers `/compact` first and begins
// it after, and cancels it if its stdin closes meanwhile.
var compacting = KimiAcpWireFollow()
let compactAt = Date(timeIntervalSince1970: 1_790_833_100)
_ = compacting.feed(line: #"{"type":"full_compaction.begin","agentId":"main","time":1790833100000}"#, now: compactAt)
let keptWhileCompacting = compacting.keepsChildUp(at: compactAt.addingTimeInterval(30), taskMargin: 120, noticeSettle: 2)
    && !compacting.keepsChildUp(at: compactAt.addingTimeInterval(601), taskMargin: 120, noticeSettle: 2)
_ = compacting.feed(line: #"{"type":"context.apply_compaction","agentId":"main","summary":"s","tokensBefore":9,"tokensAfter":3}"#, now: compactAt)
_ = compacting.feed(line: #"{"type":"full_compaction.complete","agentId":"main","time":1790833101000}"#, now: compactAt)
var cancelled = KimiAcpWireFollow()
_ = cancelled.feed(line: #"{"type":"full_compaction.begin","agentId":"main"}"#, now: compactAt)
_ = cancelled.feed(line: #"{"type":"full_compaction.cancel","agentId":"main"}"#, now: compactAt)
check("…a compaction under way keeps the child up — bounded — and one that has ended, either way, lets it go",
      keptWhileCompacting && compacting.compactionsBegun == 1
        && !compacting.keepsChildUp(at: compactAt.addingTimeInterval(2), taskMargin: 120, noticeSettle: 2)
        && !cancelled.keepsChildUp(at: compactAt.addingTimeInterval(2), taskMargin: 120, noticeSettle: 2))
// A background task ends, and kimi runs a turn of its own on it — the
// records as kimi 2.1.1 writes them: the task's end, then (about ten
// milliseconds later in the file) the turn's prompt, named for the task,
// and the notification as a user-role message of kimi's own.
let ended = Date(timeIntervalSince1970: 1_790_833_031)
func keeps(_ f: KimiAcpWireFollow, _ at: Date) -> Bool {
    f.keepsChildUp(at: at, taskMargin: 120, noticeSettle: 2)
}
check("…while it runs the child is kept up, to kimi's own deadline for it and a margin, not past",
      keeps(follow, ended) && keeps(follow, Date(timeIntervalSince1970: 1_790_833_025.44 + 600 + 119))
        && !keeps(follow, Date(timeIntervalSince1970: 1_790_833_025.44 + 600 + 121)))
_ = follow.feed(line: #"{"type":"task.terminated","agentId":"main","info":{"taskId":"bash-1","status":"completed","detached":true},"time":1790833031000}"#, now: ended)
check("…a task that has just ended is owed a turn: no task and no turn in the record, and the child is still kept — for the moment kimi takes to open it, not for good",
      !follow.tasksPending && !follow.turnOpen && follow.noticeOwedSince == ended
        && keeps(follow, ended.addingTimeInterval(1)) && !keeps(follow, ended.addingTimeInterval(2.5)))
let taskNotice = #"<notification id=\"task:bash-1:completed\" category=\"task\" type=\"task.completed\" source_kind=\"background_task\" source_id=\"bash-1\">\nTitle: Background process completed\nSeverity: info\nWall time: 3.009 seconds\nbg sleep completed.\n</notification>"#
let taskOrigin = #"{"kind":"task","taskId":"bash-1","status":"completed","notificationId":"task:bash-1:completed"}"#
let steer = follow.feed(line: #"{"type":"turn.prompt","agentId":"main","input":[{"type":"text","text":""# + taskNotice + #""}],"origin":"# + taskOrigin + #","promptId":"msg_B","turnId":1,"time":1790833031010}"#,
                        now: ended.addingTimeInterval(0.011))
check("…and the turn kimi starts on it keeps the child up until KIMI ends it — however long after the prompt its task finished, however long it then works",
      !follow.tasksPending && follow.turnOpen && follow.noticeOwedSince == nil && steer.isEmpty
        && keeps(follow, ended.addingTimeInterval(100_000)))
let steerNote = follow.feed(line: #"{"type":"context.append_message","agentId":"main","message":{"role":"user","content":[{"type":"text","text":""# + taskNotice + #""}],"id":"msg_B","toolCalls":[],"origin":"# + taskOrigin + #"},"time":1790833031010}"#)
check("…kimi's notification is drawn under a system label, never as the user's own message — in kimi's own short words",
      steerNote.count == 1 && steerNote.first?.isSystemNotice == true
        && steerNote.map(signature).first == "notice:Background process completed · bg sleep completed.",
      "\(steerNote.map(signature))")
let failedAt = ended.addingTimeInterval(5)
_ = follow.feed(line: #"{"type":"turn.ended","agentId":"main","turnId":1,"reason":"failed","error":{"code":"provider.api_error","message":"400 Invalid request: scripted 400"},"time":1790833031020}"#,
                now: failedAt)
check("a failed turn's own words (ACP answers such a turn as if it had succeeded), counted per turn",
      !follow.turnOpen && follow.failure == "400 Invalid request: scripted 400" && follow.failureCount == 1
        && !keeps(follow, failedAt.addingTimeInterval(0.1)))
var silent = KimiAcpWireFollow()
_ = silent.feed(line: #"{"type":"turn.prompt","agentId":"main","promptId":"p","turnId":0,"time":1}"#)
_ = silent.feed(line: #"{"type":"turn.ended","agentId":"main","turnId":0,"reason":"failed","time":2}"#)
check("…a turn that failed with no words is still counted, for the row that says so",
      silent.failure == nil && silent.failureCount == 1)
// A turn kimi recorded as FAILED, in the shape kimi 2.1.1 writes when the
// model cannot be reached: each retry recorded, then the step interrupted,
// kimi's own `agent.turn.ended` event (whose `errorMessage` is the string
// "[object Object]"), and `turn.ended reason: failed` carrying kimi's words.
func failedTurnWire(error: String?) -> URL {
    let lines = [
        #"{"type":"metadata","protocol_version":"1.5","created_at":1790000000000}"#,
        #"{"type":"turn.prompt","agentId":"main","input":[{"type":"text","text":"How do backups work?"}],"origin":{"kind":"user"},"promptId":"msg_F1","turnId":0,"time":1790000000100}"#,
        #"{"type":"context.append_message","agentId":"main","message":{"role":"user","content":[{"type":"text","text":"How do backups work?"}],"id":"msg_F1","toolCalls":[],"origin":{"kind":"user"}},"time":1790000000100}"#,
        #"{"type":"context.append_loop_event","agentId":"main","event":{"type":"step.begin","uuid":"s1","turnId":"0","step":1},"time":1790000000200}"#,
        #"{"type":"context.append_loop_event","agentId":"main","event":{"type":"step.end","uuid":"s1","turnId":"0","step":1,"finishReason":"error"},"time":1790000005200}"#,
        #"{"type":"turn.step.retrying","agentId":"main","turnId":0,"step":1,"stepId":"s1","failedAttempt":1,"nextAttempt":2,"maxAttempts":2,"delayMs":502.1,"errorName":"APIConnectionError","errorMessage":"Connection error.","time":1790000005200}"#,
        #"{"type":"context.append_loop_event","agentId":"main","event":{"type":"step.begin","uuid":"s2","turnId":"0","step":2},"time":1790000005700}"#,
        #"{"type":"context.append_loop_event","agentId":"main","event":{"type":"step.end","uuid":"s2","turnId":"0","step":2,"finishReason":"error"},"time":1790000010700}"#,
        #"{"type":"turn.step.interrupted","agentId":"main","turnId":0,"step":2,"reason":"error","message":"[provider.connection_error] Connection error.","time":1790000010700}"#,
        #"{"turnId":0,"outcome":"failed","errorMessage":"[object Object]","type":"agent.turn.ended","time":1790000010700,"kind":"event"}"#,
        error.map { #"{"type":"turn.ended","agentId":"main","turnId":0,"reason":"failed","error":{"code":"provider.connection_error","message":""# + $0 + #"","name":"APIConnectionError","retryable":true},"durationMs":10600,"time":1790000010701}"# }
            ?? #"{"type":"turn.ended","agentId":"main","turnId":0,"reason":"failed","durationMs":10600,"time":1790000010701}"#,
        #"{"type":"prompt.completed","agentId":"main","promptId":"msg_F1","finishedAt":"2026-09-21T00:00:10.702Z","reason":"failed","time":1790000010702}"#,
    ]
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("failed-\(UUID().uuidString).jsonl")
    try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
}
let reopenedFailure = KimiSessionScanner.readHistory(of: failedTurnWire(error: "Connection error."))
    .compactMap(AgentSessionTailer.liveEvent(for:))
check("a failed turn reopens with kimi's words under the question, once — off `turn.ended`, never off kimi's own `[object Object]` event",
      reopenedFailure.map(signature) == ["user:How do backups work?", "error:Connection error."],
      "\(reopenedFailure.map(signature))")
let wordless = "Kimi Code reported an error but gave no detail."
let reopenedWordless = KimiSessionScanner.readHistory(of: failedTurnWire(error: nil), wordlessFailure: wordless)
    .compactMap(AgentSessionTailer.liveEvent(for:)).map(signature)
check("…one kimi gave no words for: the sentence that says so, which the caller names — and no row from a caller with none to give",
      reopenedWordless == ["user:How do backups work?", "error:" + wordless]
        && KimiSessionScanner.readHistory(of: failedTurnWire(error: nil)).count == 1,
      "\(reopenedWordless)")
// The same record followed live over ACP, line by line.
var followFailed = KimiAcpWireFollow()
var followFailedRows: [StreamEvent] = []
var noticesAlong: [String?] = []
let failedLines = ((try? String(contentsOf: failedTurnWire(error: "Connection error."), encoding: .utf8)) ?? "")
    .split(separator: "\n").map(String.init)
for line in failedLines {
    followFailedRows += followFailed.feed(line: line)
    noticesAlong.append(followFailed.retryNotice)
}
check("…followed live over ACP: no row off the reader — the driver says a failure, once — and the failure counted in kimi's words",
      followFailedRows.isEmpty && followFailed.failure == "Connection error." && followFailed.failureCount == 1,
      "\(followFailedRows.map(signature))")
// Lines 5–10 run from the retry to kimi's own turn-ended event: the next
// attempt's `step.begin`, its failed `step.end`, the interrupted step.
let retryLine = "Retrying (2/2) · APIConnectionError · Connection error."
check("…the retry line is kept up through the attempt that follows it, as kimi's terminal keeps it, and gone with the turn",
      noticesAlong.count == 12 && noticesAlong[4] == nil
        && noticesAlong[5...9].allSatisfy { $0 == retryLine } && noticesAlong[10] == nil,
      "\(noticesAlong)")
let wireRetry = json(#"{"type":"turn.step.retrying","agentId":"main","turnId":0,"step":1,"failedAttempt":1,"nextAttempt":2,"maxAttempts":10,"delayMs":538.9,"errorName":"APIStatusError","errorMessage":"500 upstream exploded","statusCode":500,"time":1}"#)
let stdoutRetry = #"{"role":"meta","type":"turn.step.retrying","failed_attempt":1,"next_attempt":2,"max_attempts":10,"delay_ms":538.9,"error_name":"APIStatusError","error_message":"500 upstream exploded","status_code":500}"#
check("kimi's retry line reads the same off the session's record and off a headless run's stdout — two spellings, one line",
      KimiSessionScanner.retryNotice(wireRetry) == "Retrying (2/10) · APIStatusError · 500 · 500 upstream exploded"
        && KimiEventParser.retryNotice(line: stdoutRetry) == KimiSessionScanner.retryNotice(wireRetry),
      "\(String(describing: KimiEventParser.retryNotice(line: stdoutRetry)))")
check("…and nothing else on stdout is one: the version banner, the session's name, an answer",
      KimiEventParser.retryNotice(line: #"{"role":"meta","type":"system.version","version":"2.1.1"}"#) == nil
        && KimiEventParser.retryNotice(line: #"{"role":"meta","type":"session.resume_hint","session_id":"session_x"}"#) == nil
        && KimiEventParser.retryNotice(line: #"{"role":"assistant","content":"hi"}"#) == nil)
var splitTail = KimiSessionScanner.RecordTail(offset: 7)
let firstRead = splitTail.lines(adding: Data("{\"a\":1}\n{\"b\":".utf8))
let secondRead = splitTail.lines(adding: Data("2}\n".utf8))
check("a record read while kimi appends to it: each line handed over once and whole, however the reads split it",
      firstRead == ["{\"a\":1}"] && secondRead == ["{\"b\":2}"] && splitTail.offset == 23,
      "\(firstRead) \(secondRead) \(splitTail.offset)")
// Two tasks: the second ends while the first one's turn is running. Kimi
// holds its notification until that turn is over.
var two = KimiAcpWireFollow()
func started(_ id: String) -> String {
    #"{"type":"task.started","agentId":"main","info":{"taskId":""# + id + #"","detached":true,"startedAt":1790833025440,"timeoutMs":600000},"time":1790833025440}"#
}
func terminated(_ id: String) -> String {
    #"{"type":"task.terminated","agentId":"main","info":{"taskId":""# + id + #"","status":"completed","detached":true},"time":1790833031000}"#
}
func taskPrompt(_ id: String, turn: Int) -> String {
    #"{"type":"turn.prompt","agentId":"main","origin":{"kind":"task","taskId":""# + id + #""},"promptId":"m\#(turn)","turnId":\#(turn),"time":1790833031010}"#
}
func turnEnded(_ turn: Int) -> String {
    #"{"type":"turn.ended","agentId":"main","turnId":\#(turn),"reason":"completed","time":1790833031020}"#
}
_ = two.feed(line: started("a")); _ = two.feed(line: started("b"))
_ = two.feed(line: terminated("a"), now: ended)
_ = two.feed(line: taskPrompt("a", turn: 1), now: ended.addingTimeInterval(0.01))
_ = two.feed(line: terminated("b"), now: ended.addingTimeInterval(1))
_ = two.feed(line: turnEnded(1), now: ended.addingTimeInterval(60))
check("a task that ends during another task's turn is owed its turn from when THAT turn ends",
      !two.turnOpen && !two.tasksPending && two.noticeOwedSince == ended.addingTimeInterval(60)
        && keeps(two, ended.addingTimeInterval(61)) && !keeps(two, ended.addingTimeInterval(63)))
_ = two.feed(line: taskPrompt("b", turn: 2), now: ended.addingTimeInterval(60.01))
_ = two.feed(line: turnEnded(2), now: ended.addingTimeInterval(70))
check("…and with every task's turn over, nothing keeps the child",
      two.noticeOwedSince == nil && !keeps(two, ended.addingTimeInterval(70.1)))
var stranger = KimiAcpWireFollow()
_ = stranger.feed(line: terminated("z"), now: ended)
check("a task this turn never saw start is owed nothing here",
      stranger.noticeOwedSince == nil && !keeps(stranger, ended))

// Plan mode, in kimi's own records.
let enter = #"{"type":"plan_mode.enter","agentId":"main","time":1}"#
let cancel = #"{"type":"plan_mode.cancel","agentId":"main","time":2}"#
let exitPlan = #"{"type":"plan_mode.exit","agentId":"main","time":3}"#
let manual = #"{"type":"permission.set_mode","agentId":"main","mode":"manual","time":4}"#
check("plan mode is left on when the newest plan-mode record enters it",
      KimiAcp.planModeOn(in: [cancel, enter, manual].joined(separator: "\n")) == true)
check("…and off once a later record leaves it (an approved plan, Reject and Exit, any other mode)",
      KimiAcp.planModeOn(in: [enter, exitPlan].joined(separator: "\n")) == false
        && KimiAcp.planModeOn(in: [enter, cancel, manual].joined(separator: "\n")) == false)
check("…and unknown in a record that never names it",
      KimiAcp.planModeOn(in: [manual, local].joined(separator: "\n")) == nil)
// An undo takes back, with its turns, the plan-mode records they hold:
// kimi replays the session from what the undo kept, so a session taken out
// of plan mode inside the undone turns is IN plan mode again — and refuses
// a `plan` as "Already in plan mode".
func sent(_ text: String) -> String {
    #"{"type":"context.append_message","agentId":"main","message":{"role":"user","content":[{"type":"text","text":"\#(text)"}],"origin":{"kind":"user"}}}"#
}
let undoTwo = [#"{"type":"agent.switched","agentId":"main","branch":"b1","reason":"undo","base":{"branch":"main","line":3},"turns":2}"#,
               #"{"type":"context.undo","agentId":"main","count":2}"#,
               #"{"type":"context.undone","agentId":"main","turns":2,"fromTurnId":1}"#]
check("an undo that takes back the turn plan mode was left in leaves it on again",
      KimiAcp.planModeOn(in: ([sent("A"), enter, sent("B"), cancel, sent("C")] + undoTwo)
                            .joined(separator: "\n")) == true)
check("…and one that takes back the turn that entered it leaves it off",
      KimiAcp.planModeOn(in: ([cancel, sent("A"), sent("B"), enter, sent("C")] + undoTwo)
                            .joined(separator: "\n")) == false)
check("…a record left above the cut stands",
      KimiAcp.planModeOn(in: ([sent("A"), enter, sent("B"), sent("C"), cancel] + undoTwo)
                            .joined(separator: "\n")) == true)
check("…and in a window that begins after the undone turns' start, nothing in it is a verdict",
      KimiAcp.planModeOn(in: ([enter, sent("C")] + undoTwo).joined(separator: "\n"),
                         windowIsWhole: false) == nil)

// Two reads of the record overlap on an ACP turn — the poll, and the read
// a decision makes the moment the prompt is answered (a skill kimi does not
// know, an answer kimi gave itself) — and the one that lands second may
// have found more than the first. Driven here in a fixed order: each read
// takes the record as it stood when it was made, and is delivered when the
// harness says.
@MainActor
final class ScriptedRecord {
    var bytes = Data()
    var waiting: [(snapshot: Data, deliver: CheckedContinuation<Data, Never>)] = []
    func read(from offset: UInt64) async -> Data {
        let start = Int(offset)
        let snapshot = start < bytes.count ? bytes.subdata(in: start..<bytes.count) : Data()
        return await withCheckedContinuation { waiting.append((snapshot, $0)) }
    }
    func deliver() {
        let read = waiting.removeFirst()
        read.deliver.resume(returning: read.snapshot)
    }
}
@MainActor
func settle(_ done: () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if done() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return done()
}
/// Run from the harness's async tail (the top level stays synchronous: it
/// ends in `dispatchMain()`).
@MainActor
func overlappingReads() async {
    print("\n1b. Two reads of the record that overlap (KimiSessionScanner.RecordReader)")
    let scripted = ScriptedRecord()
    let recordReader = KimiSessionScanner.RecordReader(offset: 0) { await scripted.read(from: $0) }
    scripted.bytes = Data("one\n".utf8)
    final class Landed { var lines: [String]? = nil }
    let polled = Landed(), decided = Landed()
    Task { @MainActor in polled.lines = await recordReader.newLines() }
    _ = await settle { scripted.waiting.count == 1 }
    scripted.bytes += Data("two\n".utf8)
    Task { @MainActor in decided.lines = await recordReader.newLines() }
    _ = await settle { scripted.waiting.count == 2 }
    scripted.deliver()                          // the poll's read lands first, with less
    _ = await settle { polled.lines != nil }
    scripted.deliver()                          // then the decision's, with more
    // Read through, the decision reads once more from where the poll stopped.
    if await settle({ scripted.waiting.count == 1 || decided.lines != nil }), !scripted.waiting.isEmpty {
        scripted.deliver()
}
_ = await settle { decided.lines != nil }
check("two reads of the record that overlap: the first to land takes its lines",
      polled.lines == ["one"], "\(String(describing: polled.lines))")
check("…and the one it overtook returns only once the record is read through — with the line it found beyond the other's",
      decided.lines == ["two"],
      "\(String(describing: decided.lines)) — a decision after it judged a record not read through")
check("…each line handed out once, the reader at the record's end",
      recordReader.tail.offset == UInt64(scripted.bytes.count), "offset \(recordReader.tail.offset)")
}

// MARK: - 3. The wiring, read off the sources (section 2 runs last)

print("\n3. The wiring, read off the sources")
func read(_ rel: String) -> String {
    (try? String(contentsOfFile: srcRoot + "/" + rel, encoding: .utf8)) ?? ""
}
let runnerSource = read("SipAI/Models/AgentRunner.swift")
let managerSource = read("SipAI/Models/AgentManager.swift")
let appSource = read("SipAI/SipAIApp.swift")
let viewSource = read("SipAI/Views/Chat/AgentSessionView.swift")
let composerSource = read("SipAI/Views/Chat/AgentComposer.swift")
let catalogSource = read("SipAI/Resources/Localizable.xcstrings")
let configSource = read("SipAI/Models/ConfigManager.swift")
func body(_ source: String, from start: String) -> String {
    guard let r = source.range(of: start) else { return "" }
    var depth = 0
    var seenOpen = false
    var end = r.lowerBound
    for i in source[r.lowerBound...].indices {
        let c = source[i]
        if c == "{" { depth += 1; seenOpen = true }
        if c == "}" { depth -= 1 }
        if seenOpen && depth == 0 { end = source.index(after: i); break }
    }
    return String(source[r.lowerBound..<end])
}
let makeTurn = body(runnerSource, from: "private func makeRPCTurn(")
check("an asking kimi send is driven by KimiAcpTurn, its effort riding the environment",
      makeTurn.contains("case .kimiAcp:") && makeTurn.contains("KimiAcpTurn(")
        && makeTurn.contains("KimiCapabilities.environmentOverlay"))
let rpcTurn = body(runnerSource, from: "private func runRPCTurn(")
// The end of a turn over JSON-RPC, by its one rule.
var childAsked = 0
let endedWell = AgentRPCTurnEnd.outcome(protocolDone: true, stopped: false, driverFailure: nil) {
    childAsked += 1; return "exited with code 3"
}
check("a turn over JSON-RPC ends by one rule: a failure its driver said ends it failed in those words (the row already drawn); Stop is Stop; a child gone mid-protocol is said in its own words",
      endedWell == .ended && childAsked == 0
        && AgentRPCTurnEnd.outcome(protocolDone: true, stopped: false, driverFailure: "Connection error.") { "c" }
            == .failedAsSaid("Connection error.")
        && AgentRPCTurnEnd.outcome(protocolDone: true, stopped: true, driverFailure: "Connection error.") { "c" } == .ended
        && AgentRPCTurnEnd.outcome(protocolDone: false, stopped: true, driverFailure: nil) { "c" } == .ended
        && AgentRPCTurnEnd.outcome(protocolDone: false, stopped: false, driverFailure: "x") { "exited with code 3" }
            == .cutShort("exited with code 3"))
check("…the runner ends every RPC turn through it, and a failure ends with the driver's row alone — never a second",
      rpcTurn.contains("AgentRPCTurnEnd.outcome(") && rpcTurn.contains("driverFailure: rpcTurnFailure")
        && rpcTurn.contains("errorRowShown: errorRowShown")
        && body(runnerSource, from: "private func finalizeTurn(").contains("if let errText = errorMessage, !errorRowShown {")
        && body(runnerSource, from: "func noteTurnFailed(_ message: String)").contains("runner.rpcTurnFailure = message")
        && runnerSource.contains("rpcTurnCompleted = false\n        rpcTurnFailure = nil"))
check("…and a turn that ended on an error row ends on a failing exit code whatever the child's — the one thing a scheduled run reads — a child gone quietly mid-protocol included",
      rpcTurn.contains("if errText != nil, exitCode == 0 { exitCode = -1 }")
        && body(runnerSource, from: "private func finalizeTurn(").contains("setStatus(.done(exitCode: exitCode, errorMessage: errorMessage))")
        && read("SipAI/Models/ScheduledTaskScheduler.swift").contains("state.lastOutcome = code == 0 ? \"done\" : \"error\""))
if let join = rpcTurn.range(of: "await group.waitForAll()"),
   let restore = rpcTurn.range(of: "await restoreKimiBinding(sessionId: id)"),
   let finalize = rpcTurn.range(of: "finalizeTurn(token: token, exitCode: exitCode") {
    check("the binding is handed back once the child is gone and before the turn is over",
          join.upperBound <= restore.lowerBound && restore.upperBound <= finalize.lowerBound)
} else {
    check("the binding is handed back once the child is gone and before the turn is over", false)
}
check("…journalled before the child can bind it (existing session) and when kimi names a new one",
      rpcTurn.contains("onKimiBindingJournal?(id, true)")
        && body(runnerSource, from: "private func adoptRPCSession(").contains("onKimiBindingJournal?(id, true)"))
let runOnceSource = body(runnerSource, from: "private func runOnce(")
if let pick = runOnceSource.range(of: "let driver = AgentTurnDriver.pick("),
   let restore = runOnceSource.range(of: "await restoreKimiBinding(sessionId: id)"),
   let web = runOnceSource.range(of: "if driver == .kimiWeb {") {
    check("every kimi turn hands a session still bound back before it runs (a child still exiting, a crash)",
          pick.upperBound <= restore.lowerBound && restore.upperBound <= web.lowerBound)
} else {
    check("every kimi turn hands a session still bound back before it runs", false)
}
if let restore = runOnceSource.range(of: "await restoreKimiBinding(sessionId: id)"),
   let leave = runOnceSource.range(of: "await leaveKimiPlanModeIfLeftOn(sessionId: id, binary: binary)"),
   let web = runOnceSource.range(of: "if driver == .kimiWeb {") {
    check("a headless kimi turn leaves the plan mode an Ask turn left on, before it runs",
          restore.upperBound <= leave.lowerBound && leave.upperBound <= web.lowerBound
            && runOnceSource.contains("if driver == .kimiPrint {"))
} else {
    check("a headless kimi turn leaves the plan mode an Ask turn left on, before it runs", false)
}
let leaveSource = body(runnerSource, from: "private func leaveKimiPlanModeIfLeftOn(")
// The short conversation is the runner's one helper for it, shared with
// codex's plan-mode hand-back.
let sideSource = body(runnerSource, from: "private func runSideConversation(")
check("…through kimi's own request, drained by the one loop, journalled, and the binding handed back after",
      leaveSource.contains("KimiAcpTurn.leavePlanMode(") && leaveSource.contains("runSideConversation(")
        && sideSource.contains("Self.makeDrainingLineSource(")
        && leaveSource.contains("onKimiBindingJournal?(id, true)")
        && leaveSource.contains("await restoreKimiBinding(sessionId: id)")
        && leaveSource.contains("KimiAcp.planModeLeftOn("))
let driverSource = read("SipAI/Models/KimiAcpTurn.swift")
let driverRun = body(driverSource, from: "    func run(peer: JSONRPCLinePeer, host: AgentRPCHost) async")
check("every read of the turn's record goes through the one reader, which reads it through (1b)",
      body(driverSource, from: "private func readWire(").contains("await reader.newLines()")
        && !driverSource.contains("RecordTail.read(wire")
        && driverSource.components(separatedBy: "RecordTail.read(").count == 2)
check("the driver waits on kimi's background work only while there is a child to keep up, and by the record's own rule",
      driverRun.contains("while host.turnIsLive, !peer.isClosed,\n              follow.keepsChildUp(at: Date(), taskMargin: Self.lingerMargin,")
        && !driverRun.contains("?? started"))
check("a kimi with background tasks to stop is given its own wind-down, on Stop and at the turn's end — a SIGTERM leaves them running",
      driverSource.contains("return follow.tasksPending ? Self.taskWindDown : 2")
        && driverSource.contains("follow.tasksPending ? Self.taskWindDown : AgentRPCTurnDefaults.exitGrace")
        && body(runnerSource, from: "private func runRPCTurn(").contains("self?.boundRPCChildExit(token: token, grace: turn.exitGrace)")
        && read("SipAI/Models/AgentRPCTurn.swift").contains("var exitGrace: TimeInterval { get }"))
check("kimi's driver tells the runner each time it ends a turn on a failure row, and only then — never for a skill kimi did not know",
      body(driverSource, from: "private func endOnFailure(").contains("host.noteTurnFailed(message)")
        && body(driverSource, from: "private func reportFailure(").contains("endOnFailure(")
        && driverSource.components(separatedBy: "endOnFailure(AgentAskingMode.unreadableAnswerMessage").count - 1 == 2
        && driverSource.components(separatedBy: "host.noteTurnFailed(").count - 1 == 1)
check("a failed turn gets its row once per failed turn, in kimi's words or — with none — in a sentence that says so",
      body(driverSource, from: "private func reportFailure(").contains("guard follow.failureCount > failuresShown else { return }")
        && body(driverSource, from: "private func reportFailure(").contains("AgentAskingMode.wordlessFailureMessage(agentName: agentName)")
        && driverRun.contains("refusedWithoutWords = true")
        && driverRun.contains("if refusedWithoutWords, failuresShown == 0 {"))
let kimiStdout = runnerSource.range(of: "parsed = KimiEventParser.parse(line: line, fallbackCwd: cwd)")
    .map { String(runnerSource[$0.lowerBound...].prefix(700)) } ?? ""
check("a headless kimi turn's retry line comes off its stdout and is held as codex's is: replaced by the next, cleared by output",
      kimiStdout.contains("if let notice = KimiEventParser.retryNotice(line: line) {")
        && kimiStdout.contains("retryNotice = notice") && kimiStdout.contains("} else if !parsed.isEmpty {"))
let webTurn = body(runnerSource, from: "private func runKimiWebTurn(")
let failedEnd = webTurn.range(of: "if let failure {\n            fail(failure)")
let answeredEnd = webTurn.range(of: "} else if idle != nil {\n            finalizeTurn(token: token, exitCode: 0, errorMessage: nil)")
check("a Chat only turn through kimi's server shows kimi's retries while it waits, and ends a turn kimi failed AS failed, in kimi's words — idle is not answered",
      webTurn.contains("let retries = watchKimiRetries(sessionId: sid, token: token)")
        && webTurn.contains("retries.cancel()")
        && webTurn.contains("KimiWebTurn.failure(in: items, lastTurnReason: idle.lastTurnReason")
        && webTurn.contains("wordlessFailure: wordless")
        && failedEnd != nil && answeredEnd != nil
        && failedEnd!.lowerBound < answeredEnd!.lowerBound
        && body(runnerSource, from: "private func watchKimiRetries(").contains("KimiSessionScanner.RetryWatch()"))
check("a reopened failure is drawn as the live error row, and each history load names the agent for a failure kimi gave no words for",
      body(viewSource, from: "private func renderHistoricalItem(").contains("case .error(let message):\n            errorRow(message: message")
        && viewSource.components(separatedBy: "wordlessFailure: wordlessFailure").count - 1 == 2
        && viewSource.components(separatedBy: "AgentAskingMode.wordlessFailureMessage(agentName: sessionAgentName)").count - 1 == 2)
check("…and so is a turn watched as it runs elsewhere: its tailer is given the same sentence",
      body(runnerSource, from: "let t = AgentSessionTailer(")
        .contains("wordlessFailure: AgentAskingMode.wordlessFailureMessage(agentName: agentDisplayName)"))
check("a card's mode switch asks the adoption rule before the chip moves",
      body(viewSource, from: "private func adoptSessionMode(_ target: String)")
        .contains("AgentAskingMode.adoption(of: target,"))
check("a plan approval that names a mode sets it the moment kimi has its answer, in kimi's own ACP id",
      body(driverSource, from: "private func askPermission(").contains("PlanContinue.split(picked).mode")
        && body(driverSource, from: "private func askPermission(").contains("\"session/set_mode\"")
        && body(driverSource, from: "private func askPermission(").contains("KimiAcp.acpModeId(continuingIn: mode,"))
check("every ACP turn is given kimi's own configured mode, read as the file says it at the turn — a plan approved \"then Default\" continues in it whatever mode the turn was sent in",
      read("SipAI/Models/AgentRunner.swift").contains("defaultPermissionMode: KimiCatalog.readDefaultPermissionMode())")
        && !read("SipAI/Models/AgentRunner.swift").contains("? KimiCatalog.readDefaultPermissionMode() : nil)"))
check("the turn states its mode through the one rule, and a `plan` kimi refuses for a session already planning is no failure",
      driverRun.contains("if let stated = KimiAcp.statedMode(modeId, isDefault: turnMode == nil,")
        && driverRun.contains("guard case .remote = failure, stated == \"plan\",")
        && driverRun.contains("while follow.compactionsBegun == 0, Date() < settled,"))
check("every send this session makes asks the one hold — the composer's, a branch's, the branch editor's button",
      viewSource.contains("private var sendIsHeld: Bool")
        && body(viewSource, from: "private func handleSend()").contains("if sendIsHeld { return }")
        && viewSource.contains("guard !text.isEmpty, !branching, !sendIsHeld,")
        && viewSource.contains("branching: branching || sendIsHeld,")
        && viewSource.contains("stillOpen == sourceId, !sendIsHeld else {"))
check("a held kimi send keeps its mode picker: the readout stands only where kimi has no front end and nothing holds the send",
      composerSource.contains("if isKimi && frontEnd == .unavailable && !chatOnlyOffered\n                && askingHold == nil && !chatOnlyPending {"))
check("the Non-stop switch reads off in a mode that cannot ask",
      composerSource.contains("isOn: Binding(get: { options.nonStop && modeAsksQuestions },"))
check("a kimi session born in a headless turn is watched like any other: its transcript is taken up with a tailer",
      { () -> Bool in
          let adopt = body(runnerSource, from: "private func adoptDiscoveredSession(")
          return adopt.contains("adoptSessionFile(fileURL, id: id)")
              && body(runnerSource, from: "private func adoptSessionFile(").contains("startTailer(at: url, initialOffset: Self.currentSize(of: url))")
      }())
check("a side conversation's reader keeps its descriptor open until it has seen the end of the stream",
      sideSource.contains("let readHandle = stdoutPipe.fileHandleForReading")
        && sideSource.contains("withExtendedLifetime(readHandle) {}"))
if let locate = driverRun.range(of: "await locateWire(sessionId: sid)"),
   let liveCheck = driverRun.range(of: "guard host.turnIsLive else {"),
   let prompt = driverRun.range(of: "\"session/prompt\"") {
    check("nothing waits between the last look at Stop and the message going out",
          locate.upperBound <= liveCheck.lowerBound && liveCheck.upperBound <= prompt.lowerBound
            && !String(driverRun[liveCheck.upperBound..<prompt.lowerBound]).contains("await locateWire"))
} else {
    check("nothing waits between the last look at Stop and the message going out", false)
}
check("the runner counts a turn's protocol as done only while the conversation is open — a child gone under it is reported",
      rpcTurn.contains("if !peer.isClosed { self?.noteRPCTurnCompleted(token: token) }")
        && !rpcTurn.contains("if exitCode == 0 { return nil }"))
check("a new session found on disk is taken up whole: its file watcher started and held while the child writes",
      body(runnerSource, from: "private func adoptRPCSession(").contains("adoptSessionFile(url, id: id)"))
check("the journal heals at launch and on opening the session, beside the tool-policy heal",
      appSource.contains("agentManager.healKimiRuntimeBindings()")
        && viewSource.contains("agents.healKimiRuntimeBindings(sessionId: id)")
        && managerSource.contains("runner.onKimiBindingJournal")
        && configSource.contains("kimi_runtime_binding_restores"))
check("the runner and the heal hand back every agent of the session, never the main record alone",
      runnerSource.contains("KimiRuntimeBinding.restore(sessionDir: dir)")
        && managerSource.contains("KimiRuntimeBinding.restore(sessionDir: dir)")
        && !runnerSource.contains("KimiRuntimeBinding.restore(wire:")
        && !managerSource.contains("KimiRuntimeBinding.restore(wire:"))
check("the composer offers kimi's modes from the installed version, and the slash hint asks the front end",
      composerSource.contains("AgentAskingMode.offered(agentKey: agentKey,")
        && composerSource.contains("resolvesLocally(agentKey: agentKey, driver: driver)"))
for key in ["Never interrupts you; everything runs and is decided automatically",
            "Routine edits and commands run automatically; risky actions, questions, and plans still ask",
            "Plans first, and makes no edits until you approve the plan; commands ask",
            "Let %@ choose what it judges best, and keep the run going to the end even when it has questions.",
            "The installed %@ answered in a protocol version SipAI doesn’t speak. Pick another mode to send.",
            "%@ reported an error but gave no detail."] {
    let quoted = "\"" + key + "\" : {"
    let entry = catalogSource.range(of: quoted).map { String(catalogSource[$0.upperBound...].prefix(600)) } ?? ""
    check("catalog: \(key.prefix(48))… has zh-Hans", entry.contains("\"zh-Hans\""))
}

// MARK: - 2. The real kimi

final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var ended = false
    func append(_ s: String) { lock.withLock { text += s } }
    func end() { lock.withLock { ended = true } }
    var value: String { lock.withLock { text } }
    /// The stream it was filled from has reached its end.
    var isComplete: Bool { lock.withLock { ended } }
}

@MainActor
final class HarnessHost: AgentRPCHost {
    let cwd: URL
    var sessionId: String?
    var live = true
    var turnIsLive: Bool { live }
    var adopted: [String] = []
    var adoptedBeforeFirstCard: Bool? = nil
    var events: [StreamEvent] = []
    var notices: [String] = []
    var tokens: [Int] = []
    var cards: [AgentCardRequest] = []
    var onCard: ((AgentCardRequest) -> Void)?
    /// Each time the driver took a claimed skill load back off the
    /// message's row: the names, or "*" for every one it names.
    var retracted: [[String]] = []
    /// Each time the driver ended the turn on a failure it had put on the
    /// transcript: the words of that row.
    var failures: [String] = []

    init(cwd: URL, sessionId: String? = nil) {
        self.cwd = cwd
        self.sessionId = sessionId
    }

    func adoptSession(id: String) {
        adopted.append(id)
        sessionId = id
    }
    func emit(_ e: [StreamEvent]) { events += e }
    func setNotice(_ t: String?) { if let t { notices.append(t) } }
    func noteContextUsage(tokens: Int, window: Int?) { self.tokens.append(tokens) }
    @discardableResult
    func present(_ card: AgentCardRequest) -> String? {
        if adoptedBeforeFirstCard == nil { adoptedBeforeFirstCard = sessionId != nil }
        cards.append(card)
        onCard?(card)
        return "card-\(cards.count)"
    }
    func withdraw(cardId: String) {}
    func retractSkillLoads(_ names: [String]?) { retracted.append(names ?? ["*"]) }
    func noteTurnFailed(_ message: String) { failures.append(message) }
    /// Each change of what the turn says it waits on: the tasks named.
    var awaited: [[String]] = []
    func setAwaitedBackgroundTasks(_ tasks: [BackgroundTaskEntry]) {
        let names = tasks.map(\.description)
        if awaited.last != names { awaited.append(names) }
    }
}

struct Fake {
    let process: Process
    let port: Int
    let records: URL

    func requests() -> [[String: Any]] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: records.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        return names.compactMap { name in
            guard let data = FileManager.default.contents(atPath: records.appendingPathComponent(name).path)
            else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    /// The tool messages of every request after the first `from`.
    func toolMessages(after from: Int) -> [String] {
        requests().dropFirst(from).flatMap { request -> [String] in
            let messages = (request["body"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []
            return messages.filter { $0["role"] as? String == "tool" }.map { message in
                if let s = message["content"] as? String { return s }
                let data = (try? JSONSerialization.data(withJSONObject: message["content"] ?? "")) ?? Data()
                return String(decoding: data, as: UTF8.self)
            }
        }
    }
}

func startFake(script: [[String: Any]]) -> Fake? {
    let records = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kimiacp-rec-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
    let scriptFile = records.deletingLastPathComponent()
        .appendingPathComponent(records.lastPathComponent + "-script.json")
    guard let data = try? JSONSerialization.data(withJSONObject: script),
          (try? data.write(to: scriptFile)) != nil else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", fakeServerPath, records.path, "--chat-script", scriptFile.path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    var line = Data()
    while true {
        let byte = out.fileHandleForReading.readData(ofLength: 1)
        if byte.isEmpty || byte == Data([0x0A]) { break }
        line.append(byte)
    }
    let text = String(decoding: line, as: UTF8.self)
    guard text.hasPrefix("PORT="), let port = Int(text.dropFirst(5)) else { return nil }
    return Fake(process: p, port: port, records: records)
}

func makeFolder(git: Bool = false) -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kimiacp-cwd-\(UUID().uuidString)")
    let dir = base.appendingPathComponent("w")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if git {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["init", "-q", dir.path]
        try? p.run()
        p.waitUntilExit()
    }
    return URL(fileURLWithPath: KimiWebTurn.resolvedPath(dir))
}

func options(_ mode: String?, model: String? = nil) -> AgentLaunchOptions {
    var o = AgentLaunchOptions()
    o.permissionMode = mode
    o.model = model
    return o
}

/// One conversation with a fresh `kimi acp`, run the way the runner runs
/// one: the child spawned with its stdin a pipe kept open, its stdout read
/// line by line into the peer on a thread of its own, the protocol spoken
/// on the main actor; its stdin closed once `body` is done; the child
/// waited for.
///
/// `closedUnderBody` is what the runner asks when a driver returns: was the
/// conversation still open (the protocol is done with the turn), or did it
/// end under the driver (the child gone — the runner reports its exit).
/// `bodySeconds` is how long the driver took.
@MainActor
func converse(binary: String, arguments: [String] = KimiAcp.arguments,
              cwd: URL, environment: [String: String] = [:],
              setUp: ((JSONRPCLinePeer) -> Void)? = nil,
              onSpawn: ((Process) -> Void)? = nil,
              _ body: (JSONRPCLinePeer) async -> Void) async
-> (exit: Int32, seconds: Double, stderr: String, closedUnderBody: Bool, bodySeconds: Double) {
    let started = Date()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    p.arguments = arguments
    p.currentDirectoryURL = cwd
    var env = ProcessInfo.processInfo.environment
    for (k, v) in environment { env[k] = v }
    p.environment = env
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    p.standardInput = stdin
    p.standardOutput = stdout
    p.standardError = stderr
    do { try p.run() } catch { return (-1, 0, "spawn failed: \(error)", false, 0) }
    onSpawn?(p)
    let writeFD = dup(stdin.fileHandleForWriting.fileDescriptor)
    try? stdin.fileHandleForWriting.close()
    let peer = JSONRPCLinePeer(label: "harness.kimiacp", writing: writeFD,
                               deliver: JSONRPCLinePeer.deliverOnMainQueue)
    let readFD = stdout.fileHandleForReading.fileDescriptor
    Thread.detachNewThread {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(readFD, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                peer.receive(line: line)
            }
        }
        peer.receiveEOF()
    }
    let errors = LineBuffer()
    let errFD = stderr.fileHandleForReading.fileDescriptor
    Thread.detachNewThread {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(errFD, &chunk, chunk.count)
            if n <= 0 { break }
            errors.append(String(decoding: chunk[0..<n], as: UTF8.self))
        }
        errors.end()
    }
    setUp?(peer)
    let bodyStarted = Date()
    await body(peer)
    let closedUnderBody = peer.isClosed
    let bodySeconds = Date().timeIntervalSince(bodyStarted)
    peer.finishWriting()
    let deadline = Date().addingTimeInterval(15)
    while p.isRunning, Date() < deadline {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    if p.isRunning { p.terminate() }
    peer.close(reason: "the harness conversation ended")
    let code = p.isRunning ? -1 : p.terminationStatus
    let seconds = Date().timeIntervalSince(started)
    // What the child said on its way out is read to its end.
    let drained = Date().addingTimeInterval(2)
    while !errors.isComplete, Date() < drained {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return (code, seconds, errors.value, closedUnderBody, bodySeconds)
}

/// One turn, through `converse`.
@MainActor
func runTurn(_ driver: KimiAcpTurn, host: HarnessHost, binary: String,
             setUp: ((JSONRPCLinePeer) -> Void)? = nil,
             onSpawn: ((Process) -> Void)? = nil) async
-> (exit: Int32, seconds: Double, stderr: String, closedUnderBody: Bool, bodySeconds: Double) {
    await converse(binary: binary, cwd: host.cwd, environment: driver.environment,
                   setUp: setUp, onSpawn: onSpawn) { peer in
        await driver.run(peer: peer, host: host)
    }
}

/// One turn against the stand-in server (`stub_server.py <mode>`), which
/// gives the answers the real `kimi acp` cannot be made to give. Returns
/// the methods the stand-in received, in order, beside the run.
@MainActor
func runStubTurn(_ driver: KimiAcpTurn, host: HarnessHost, mode: String) async
-> (run: (exit: Int32, seconds: Double, stderr: String, closedUnderBody: Bool, bodySeconds: Double),
    methods: [String]) {
    let log = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kimiacp-stub-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: log) }
    let run = await converse(binary: "/usr/bin/env", arguments: ["python3", stubServerPath, mode, log.path],
                             cwd: host.cwd) { peer in
        await driver.run(peer: peer, host: host)
    }
    let methods = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init)
    return (run, methods)
}

func kimiVersion(_ binary: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    p.arguments = ["--version"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A headless kimi turn on a session (`kimi --prompt … --session`) — the
/// next turn after an ACP one, as SipAI or the user's terminal runs it.
func printTurn(binary: String, cwd: URL, sessionId: String, text: String) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    p.arguments = ["--prompt", text, "--output-format", "stream-json", "--session", sessionId]
    p.currentDirectoryURL = cwd
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// A NEW session's headless turn (`kimi --prompt`), what it printed and
/// how it exited — with kimi's own retry count set, so a model it cannot
/// reach costs seconds rather than minutes.
func headlessTurn(binary: String, cwd: URL, text: String, model: String,
                  attempts: Int) -> (exit: Int32, stdout: String, stderr: String) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("kimiacp-headless-\(UUID().uuidString)")
    let outURL = base.appendingPathExtension("out"), errURL = base.appendingPathExtension("err")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    defer {
        try? FileManager.default.removeItem(at: outURL)
        try? FileManager.default.removeItem(at: errURL)
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    p.arguments = ["--prompt", text, "--output-format", "stream-json", "--model", model]
    p.currentDirectoryURL = cwd
    var env = ProcessInfo.processInfo.environment
    env["KIMI_LOOP_MAX_ATTEMPTS_PER_STEP"] = String(attempts)
    p.environment = env
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = try? FileHandle(forWritingTo: outURL)
    p.standardError = try? FileHandle(forWritingTo: errURL)
    guard (try? p.run()) != nil else { return (-1, "", "spawn failed") }
    p.waitUntilExit()
    return (p.terminationStatus,
            (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
            (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
}

/// A local port nothing listens on: bound, read back, closed — a model
/// kimi cannot reach, the way it meets no internet.
func closedPort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
    }
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return Int(UInt16(bigEndian: address.sin_port))
}

func sessionIds() -> Set<String> {
    let root = KimiSessionScanner.sessionRoot
    let buckets = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    var ids = Set<String>()
    for bucket in buckets where !bucket.hasPrefix(".") {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(bucket).path)) ?? []
        ids.formUnion(names.filter { !$0.hasPrefix(".") })
    }
    return ids
}

func wireRecords(sessionId: String) -> [[String: Any]] {
    guard let dir = KimiSessionScanner.sessionDirectory(forId: sessionId),
          let text = try? String(contentsOf: KimiSessionScanner.wireFile(inSessionDir: dir), encoding: .utf8)
    else { return [] }
    return text.split(separator: "\n").compactMap { json(String($0)) }.filter { !$0.isEmpty }
}

/// The session's bindings, oldest first, in either of kimi's spellings.
func bindings(sessionId: String) -> [String] {
    wireRecords(sessionId: sessionId).compactMap { record in
        switch record["type"] as? String {
        case "environment.set_binding": return record["environmentId"] as? String
        case "runtime.set_binding": return record["runtimeId"] as? String
        default: return nil
        }
    }
}

func sessionCount() -> Int {
    let root = KimiSessionScanner.sessionRoot
    let buckets = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return buckets.filter { !$0.hasPrefix(".") }.reduce(0) { total, bucket in
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(bucket).path)) ?? []
        return total + ids.filter { !$0.hasPrefix(".") }.count
    }
}

let script: [[String: Any]] = [
    ["marker": "SIPAI-BASH", "steps": [
        ["tool_calls": [["id": "c1", "name": "Bash", "arguments": ["command": "echo hi-from-bash"]]]],
        ["text": "done after bash"]]],
    ["marker": "SIPAI-WRITE", "steps": [
        ["tool_calls": [["id": "c1", "name": "Write", "arguments": ["path": "probe.txt", "content": "hello\n"]]]],
        ["text": "done after write"]]],
    ["marker": "SIPAI-SPAWN", "steps": [
        ["tool_calls": [["id": "c1", "name": "Agent", "arguments": ["description": "probe", "prompt": "SIPAI-SUBFIRST please"]]]],
        ["text": "done after the subagent"]]],
    ["marker": "SIPAI-SUBFIRST", "steps": [
        ["tool_calls": [["id": "c1", "name": "Bash", "arguments": ["command": "echo hi-from-subagent"]]]],
        ["text": "done in the subagent"]]],
    ["marker": "SIPAI-RESUME", "steps": [
        ["tool_calls": [["id": "c1", "name": "Agent", "arguments": ["description": "again", "prompt": "SIPAI-SUBAGAIN please", "resume": "agent-0"]]]],
        ["text": "done after resuming"]]],
    ["marker": "SIPAI-SUBAGAIN", "steps": [
        ["tool_calls": [["id": "c1", "name": "Bash", "arguments": ["command": "echo hi-again-from-subagent"]]]],
        ["text": "done in the subagent again"]]],
    ["marker": "SIPAI-RM", "steps": [
        ["tool_calls": [["id": "c1", "name": "Bash", "arguments": ["command": "rm -rf ./junkdir"]]]],
        ["text": "done after rm"]]],
    ["marker": "SIPAI-ASK1", "steps": [
        ["tool_calls": [["id": "c1", "name": "AskUserQuestion", "arguments": ["questions": [
            ["question": "Which database should we use?", "header": "DB",
             "options": [["label": "Postgres", "description": "robust"],
                         ["label": "SQLite", "description": "simple"]]]]]]]],
        ["text": "done after ask"]]],
    ["marker": "SIPAI-ASK2", "steps": [
        ["tool_calls": [["id": "c1", "name": "AskUserQuestion", "arguments": ["questions": [
            ["question": "Which database should we use?", "header": "DB",
             "options": [["label": "Postgres", "description": ""], ["label": "SQLite", "description": ""]]],
            ["question": "Which extras do you want?", "header": "", "multi_select": true,
             "options": [["label": "Lint", "description": "l"], ["label": "Tests", "description": "t"],
                         ["label": "Docs", "description": "d"]]]]]]]],
        ["text": "done after ask2"]]],
    ["marker": "SIPAI-ASKBG", "steps": [
        ["tool_calls": [["id": "c1", "name": "AskUserQuestion", "arguments": ["background": true, "questions": [
            ["question": "Which database should we use?", "header": "DB",
             "options": [["label": "Postgres", "description": "robust"],
                         ["label": "SQLite", "description": "simple"]]]]]]]],
        ["text": "kept working while the question waits"]]],
    ["marker": "SIPAI-PLAN", "steps": [
        ["tool_calls": [["id": "c1", "name": "Write",
                         "arguments": ["path": "{PLAN_FILE}", "content": "# Plan\n\n1. Step one\n2. Step two\n"]]]],
        ["tool_calls": [["id": "c2", "name": "ExitPlanMode", "arguments": [String: Any]()]]],
        ["text": "done after plan"]]],
    ["marker": "SIPAI-PLANX", "steps": [
        ["tool_calls": [["id": "c1", "name": "Write",
                         "arguments": ["path": "{PLAN_FILE}", "content": "# Plan\n\n1. Echo\n"]]]],
        ["tool_calls": [["id": "c2", "name": "ExitPlanMode", "arguments": [String: Any]()]]],
        ["tool_calls": [["id": "c3", "name": "Bash", "arguments": ["command": "echo after-plan"]]]],
        ["text": "done after planx"]]],
    ["marker": "SIPAI-E400", "steps": [
        ["error": ["status": 400, "body": ["error": ["message": "Invalid request: scripted 400",
                                                     "type": "invalid_request_error"]]]]]],
    ["marker": "SIPAI-BG", "steps": [
        ["tool_calls": [["id": "c1", "name": "Bash",
                         "arguments": ["command": "sleep 4; echo bg-finished > bg.txt",
                                       "run_in_background": true, "description": "bg sleep"]]]],
        ["text": "started it in the background"]]],
    ["marker": "SIPAI-BGLONG", "steps": [
        ["tool_calls": [["id": "c1", "name": "Bash",
                         "arguments": ["command": "sleep 300", "run_in_background": true,
                                       "description": "bg long sleep"]]]],
        ["text": "started the long one"]]],
    ["marker": "task.completed", "steps": [["text": "the background task finished"]]],
    ["marker": "SIPAI-MCPFORM", "steps": [
        ["tool_calls": [["id": "c1", "name": "mcp__forms__ask_form", "arguments": [String: Any]()]]],
        ["text": "done after mcp form"]]],
]

@MainActor
func live() async {
    print("\n2. The real kimi (`kimi acp`, a throwaway home, a fake model endpoint — token-free)")
    let link = (("~/.kimi-code/bin/kimi" as NSString).expandingTildeInPath as String)
    let binary = URL(fileURLWithPath: link).resolvingSymlinksInPath().path
    guard FileManager.default.isExecutableFile(atPath: binary) else {
        skip("the live section", "kimi is not installed at ~/.kimi-code/bin/kimi")
        return
    }
    guard let version = kimiVersion(binary),
          ChatOnlyAvailability.versionAtLeast(version, AgentAskingMode.kimiVersionFloor) else {
        skip("the live section", "the installed kimi is below \(AgentAskingMode.kimiVersionFloor)")
        return
    }
    guard let fake = startFake(script: script) else {
        check("the fake model endpoint starts", false)
        return
    }
    defer { fake.process.terminate() }
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kimiacp-home-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try? """
    default_model = "fake/fake-model"

    [providers.fake]
    base_url = "http://127.0.0.1:\(fake.port)/v1"
    type = "openai"
    api_key = "junk"

    [models."fake/fake-model"]
    provider = "fake"
    model = "fake-model"
    max_context_size = 262144
    capabilities = [ "tool_use", "image_in" ]

    """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    setenv("KIMI_CODE_HOME", home.path, 1)
    defer { try? FileManager.default.removeItem(at: home) }
    print("  (kimi \(version))")

    // As the runner builds it: every turn is given kimi's own configured
    // mode as the file says it right now.
    func driver(_ text: String, _ mode: String?) -> KimiAcpTurn {
        KimiAcpTurn(text: text, options: options(mode), environment: [:],
                    agentName: "Kimi Code", clientVersion: "harness",
                    defaultPermissionMode: KimiCatalog.readDefaultPermissionMode())!
    }
    /// Run `body` with `line` at the top of kimi's config, as a user's own
    /// default would stand there, and take it out again.
    func withConfig(_ line: String, _ body: () async -> Void) async {
        let file = home.appendingPathComponent("config.toml")
        let original = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? (line + "\n" + original).write(to: file, atomically: true, encoding: .utf8)
        await body()
        try? original.write(to: file, atomically: true, encoding: .utf8)
    }
    func wireTypes(_ sessionId: String) -> [String] {
        wireRecords(sessionId: sessionId).compactMap { record in
            guard let type = record["type"] as? String else { return nil }
            return type == "permission.set_mode" ? "\(type)=\(record["mode"] as? String ?? "?")" : type
        }
    }
    func answer(_ card: AgentCardRequest, with resolution: CardResolution) {
        // A beat later, as a user's click would come.
        Task { @MainActor in card.respond(resolution) }
    }

    // A. A new session in Always Ask: a command asks; the answer runs it.
    let folderA = makeFolder()
    let hostA = HarnessHost(cwd: folderA)
    hostA.onCard = { answer($0, with: .chose("approve_once")) }
    var requestsBefore = fake.requests().count
    let runA = await runTurn(driver("SIPAI-BASH please", nil), host: hostA, binary: binary)
    let sidA = hostA.sessionId ?? ""
    check("A. a new session: kimi names it, once, and it is adopted before anything is asked",
          hostA.adopted.count == 1 && hostA.adopted.first?.hasPrefix("session_") == true
            && hostA.adoptedBeforeFirstCard == true, "\(hostA.adopted) \(String(describing: hostA.adoptedBeforeFirstCard))")
    if case .permission(let content)? = hostA.cards.first?.presentation {
        check("A. Always Ask asks before a command: kimi's options, the command and the folder it runs in",
              hostA.cards.count == 1 && content.choices.map(\.id) == ["approve_once", "approve_always", "reject"]
                && content.preview == .command("echo hi-from-bash", cwd: folderA.path, reason: nil),
              "\(content.preview)")
    } else {
        check("A. Always Ask asks before a command", false, "\(hostA.cards.map(\.presentation))")
    }
    let sigA = hostA.events.map(signature)
    check("A. the answer reaches kimi: the command ran and the turn went on — drawn from the session's record",
          sigA.contains("tool_use:c1:Bash") && sigA.contains { $0.hasPrefix("tool_result:c1:false:hi-from-bash") }
            && sigA.last == "assistant:done after bash", "\(sigA)")
    check("A. the prompt's own row is not drawn a second time", !sigA.contains { $0.hasPrefix("user:") })
    check("A. the child ends on its own once its stdin closes", runA.exit == 0 && runA.seconds < 15,
          "exit \(runA.exit) after \(runA.seconds) s; \(runA.stderr.suffix(300))")
    check("A. the driver returned with the conversation still open: the protocol was done with the turn",
          !runA.closedUnderBody)
    if let dir = KimiSessionScanner.sessionDirectory(forId: sidA) {
        let history = KimiSessionScanner.readHistory(of: KimiSessionScanner.wireFile(inSessionDir: dir))
            .compactMap(AgentSessionTailer.liveEvent(for:)).map(signature)
        check("A. live and reopened read alike: the reopened transcript is the prompt, then exactly what was drawn",
              history.first == "user:SIPAI-BASH please" && Array(history.dropFirst()) == sigA, "\(history) vs \(sigA)")
    } else {
        check("A. the session's record is where kimi files it", false)
    }
    check("A. the context chip is fed from the record", hostA.tokens.last.map { $0 > 0 } == true)

    // The binding, and a headless turn after it.
    check("A. an ACP turn leaves the session bound to ACP's runtime (the hazard)",
          bindings(sessionId: sidA).last?.hasPrefix("acp:") == true, "\(bindings(sessionId: sidA))")
    let restoredA = KimiSessionScanner.sessionDirectory(forId: sidA)
        .map { KimiRuntimeBinding.restore(wire: KimiSessionScanner.wireFile(inSessionDir: $0)) } ?? false
    check("A. handed back: the session's newest binding is its own runtime again",
          restoredA && bindings(sessionId: sidA).last == "local", "\(bindings(sessionId: sidA))")
    // Judged by a tool that RAN: kimi can offer a tool in the request and then
    // answer `Tool "Bash" not found` when the model calls it. And by the turn's
    // own answer, the newest: a request carries the earlier turns' answers too.
    requestsBefore = fake.requests().count
    _ = printTurn(binary: binary, cwd: folderA, sessionId: sidA, text: "SIPAI-BASH again")
    check("A. the next headless turn runs its commands again",
          fake.toolMessages(after: requestsBefore).last?.contains("hi-from-bash") == true,
          "\(fake.toolMessages(after: requestsBefore).suffix(1))")
    requestsBefore = fake.requests().count
    _ = printTurn(binary: binary, cwd: folderA, sessionId: sidA, text: "SIPAI-WRITE now")
    check("A. …and writes its files",
          FileManager.default.fileExists(atPath: folderA.path + "/probe.txt")
            && fake.toolMessages(after: requestsBefore).last?.contains("Wrote") == true,
          "\(fake.toolMessages(after: requestsBefore).suffix(1))")
    try? FileManager.default.removeItem(atPath: folderA.path + "/probe.txt")

    // B. The negative control: the same, never handed back.
    let folderB = makeFolder()
    let hostB = HarnessHost(cwd: folderB)
    hostB.onCard = { answer($0, with: .chose("approve_once")) }
    _ = await runTurn(driver("SIPAI-BASH please", nil), host: hostB, binary: binary)
    requestsBefore = fake.requests().count
    _ = printTurn(binary: binary, cwd: folderB, sessionId: hostB.sessionId ?? "", text: "SIPAI-BASH again")
    let boundAnswer = fake.toolMessages(after: requestsBefore).last ?? ""
    check("B. control: NOT handed back, the next headless turn runs no command",
          boundAnswer.contains(#"Tool "Bash" not found"#), boundAnswer)

    // B2. A subagent an ACP turn started keeps ACP's runtime in a wire of its
    //     own, so a headless turn that resumes it finds no Bash inside it, even
    //     with the session's main record handed back.
    let folderB2 = makeFolder()
    let hostB2 = HarnessHost(cwd: folderB2)
    hostB2.onCard = { answer($0, with: .chose("approve_once")) }
    _ = await runTurn(driver("SIPAI-SPAWN please", nil), host: hostB2, binary: binary)
    let sidB2 = hostB2.sessionId ?? ""
    let dirB2 = KimiSessionScanner.sessionDirectory(forId: sidB2)
    let subRecord = dirB2.flatMap { try? String(contentsOf: $0.appendingPathComponent("agents/agent-0/wire.jsonl"), encoding: .utf8) } ?? ""
    let subBound = KimiRuntimeBinding.bindings(subRecord).last.flatMap { ($0["environmentId"] ?? $0["runtimeId"]) as? String }
    check("B2. a subagent an ACP turn started is bound to ACP's runtime in its own record (the hazard)",
          subBound?.hasPrefix("acp:") == true, String(describing: subBound))
    _ = dirB2.map { KimiRuntimeBinding.restore(wire: KimiSessionScanner.wireFile(inSessionDir: $0)) }
    requestsBefore = fake.requests().count
    _ = printTurn(binary: binary, cwd: folderB2, sessionId: sidB2, text: "SIPAI-RESUME please")
    let resumedBound = fake.toolMessages(after: requestsBefore)
    check("B2. control: only the main record handed back, the resumed subagent runs no command",
          resumedBound.contains { $0.contains(#"Tool "Bash" not found"#) }
            && !resumedBound.contains { $0.contains("hi-again-from-subagent") },
          "\(resumedBound.suffix(2))")
    let restoredB2 = dirB2.map { KimiRuntimeBinding.restore(sessionDir: $0) } ?? false
    requestsBefore = fake.requests().count
    _ = printTurn(binary: binary, cwd: folderB2, sessionId: sidB2, text: "SIPAI-RESUME again")
    check("B2. every agent handed back, the resumed subagent runs its command",
          restoredB2 && fake.toolMessages(after: requestsBefore).contains { $0.contains("hi-again-from-subagent") },
          "\(fake.toolMessages(after: requestsBefore).suffix(2))")

    // C. Ask When Needed: a routine command runs; a risky one asks.
    let hostC = HarnessHost(cwd: makeFolder())
    hostC.onCard = { answer($0, with: .chose("reject")) }
    _ = await runTurn(driver("SIPAI-BASH please", AgentAskingMode.kimiAskWhenNeeded), host: hostC, binary: binary)
    check("C. Ask When Needed runs a routine command without asking",
          hostC.cards.isEmpty && hostC.events.map(signature).contains { $0.hasPrefix("tool_result:c1:false:hi-from-bash") })
    let hostC2 = HarnessHost(cwd: makeFolder())
    hostC2.onCard = { answer($0, with: .chose("reject")) }
    requestsBefore = fake.requests().count
    _ = await runTurn(driver("SIPAI-RM please", AgentAskingMode.kimiAskWhenNeeded), host: hostC2, binary: binary)
    check("C. …and asks before a risky one; Reject reaches the model as kimi's refusal",
          hostC2.cards.count == 1
            && fake.toolMessages(after: requestsBefore).contains { $0.contains("rejected") },
          "\(fake.toolMessages(after: requestsBefore))")

    // D. Plan: the plan review is a plan card, and approving it leaves plan mode.
    let hostD = HarnessHost(cwd: makeFolder())
    hostD.onCard = { answer($0, with: .chose("plan_approve")) }
    requestsBefore = fake.requests().count
    _ = await runTurn(driver("SIPAI-PLAN please", AgentAskingMode.kimiPlan), host: hostD, binary: binary)
    if case .plan(let content)? = hostD.cards.first?.presentation {
        check("D. the plan review: the plan, the file kimi saved it to, kimi's answers",
              content.plan.contains("# Plan") && (content.filePath ?? "").hasSuffix(".md")
                && content.choices.map(\.id) == ["plan_approve", "plan_revise", "plan_reject_and_exit"]
                && content.continueModes.map(\.id) == [AgentAskingMode.adoptDefault,
                                                        AgentAskingMode.kimiAskWhenNeeded,
                                                        AgentAskingMode.kimiNeverAsk],
              "\(content)")
    } else {
        check("D. the plan review is a plan card", false, "\(hostD.cards.map(\.presentation))")
    }
    check("D. approved, kimi leaves plan mode and carries on in the same turn",
          fake.toolMessages(after: requestsBefore).contains { $0.contains("Exited plan mode") }
            && hostD.events.map(signature).last == "assistant:done after plan",
          "\(hostD.events.map(signature))")

    // D2. An approval that names the mode: the rest of the SAME turn runs in
    //     it — a command after it runs unasked under Ask When Needed —
    //     with Default (kimi's own default, Always Ask here) as the control.
    func planThen(_ mode: String) async -> HarnessHost {
        let host = HarnessHost(cwd: makeFolder())
        host.onCard = { card in
            if case .plan = card.presentation {
                answer(card, with: .chose(PlanContinue.id(answer: "plan_approve", mode: mode)))
            } else {
                answer(card, with: .chose("approve_once"))
            }
        }
        _ = await runTurn(driver("SIPAI-PLANX please", AgentAskingMode.kimiPlan), host: host, binary: binary)
        return host
    }
    let hostD2 = await planThen(AgentAskingMode.kimiAskWhenNeeded)
    let hostD3 = await planThen(AgentAskingMode.adoptDefault)
    check("D2. approved \"then Ask When Needed\", the command after the plan runs without a card; \"then Default\" asks",
          hostD2.cards.count == 1 && hostD2.events.map(signature).last == "assistant:done after planx"
            && hostD3.cards.count == 2 && hostD3.events.map(signature).last == "assistant:done after planx",
          "AWN cards \(hostD2.cards.count) \(hostD2.events.map(signature).suffix(2)), Default cards \(hostD3.cards.count)")

    // D3. Revise keeps the session planning, and the message after it is a
    //     Plan turn on a session ALREADY in plan mode: kimi refuses a second
    //     `plan` ("Already in plan mode", an Internal error), so none is
    //     stated — the turn runs, and the plan comes back for review.
    let folderD3 = makeFolder()
    let hostD3a = HarnessHost(cwd: folderD3)
    hostD3a.onCard = { card in
        if case .plan = card.presentation { answer(card, with: .chose("plan_revise")) }
        else { answer(card, with: .chose("approve_once")) }
    }
    _ = await runTurn(driver("SIPAI-PLAN please", AgentAskingMode.kimiPlan), host: hostD3a, binary: binary)
    if let sidD3 = hostD3a.sessionId {
        let stillPlanning = KimiAcp.planModeOn(in: wireRecords(sessionId: sidD3)
            .compactMap { record in (try? JSONSerialization.data(withJSONObject: record)).map { String(decoding: $0, as: UTF8.self) } }
            .joined(separator: "\n"))
        let hostD3b = HarnessHost(cwd: folderD3, sessionId: sidD3)
        hostD3b.onCard = { card in
            if case .plan = card.presentation {
                answer(card, with: .chose(PlanContinue.id(answer: "plan_approve", mode: AgentAskingMode.adoptDefault)))
            } else { answer(card, with: .chose("approve_once")) }
        }
        _ = await runTurn(driver("SIPAI-PLAN please, revised", AgentAskingMode.kimiPlan), host: hostD3b, binary: binary)
        let planCards = hostD3b.cards.filter { if case .plan = $0.presentation { return true } else { return false } }
        check("D3. after Revise the session is still planning, and the next Plan turn runs — the plan is reviewed again, no error row",
              stillPlanning == true && planCards.count == 1
                && !hostD3b.events.map(signature).contains { $0.hasPrefix("error:") }
                && hostD3b.events.map(signature).last == "assistant:done after plan",
              "planning \(String(describing: stillPlanning)), cards \(hostD3b.cards.count), \(hostD3b.events.map(signature))")
    } else {
        check("D3. the Plan turn answered Revise named its session", false, "\(hostD3a.events.map(signature))")
    }

    // D4. Kimi's own configured default. A NEW session on Default is left
    //     as kimi opened it — no mode is stated over kimi's own (a stated
    //     one records `plan_mode.cancel`); a RESUMED one is told the
    //     config's mode; and a plan approved "then Default" continues in it
    //     from a Plan turn too.
    await withConfig("default_permission_mode = \"yolo\"") {
        let folder = makeFolder()
        let hostNew = HarnessHost(cwd: folder)
        hostNew.onCard = { answer($0, with: .chose("approve_once")) }
        _ = await runTurn(driver("SIPAI-BASH please", nil), host: hostNew, binary: binary)
        let sid = hostNew.sessionId ?? ""
        let afterNew = wireTypes(sid)
        check("D4. config default Ask When Needed: a new Default session runs a command unasked, and SipAI stated no mode over kimi's own",
              hostNew.cards.isEmpty && afterNew.contains("permission.set_mode=yolo")
                && !afterNew.contains("plan_mode.cancel")
                && hostNew.events.map(signature).last == "assistant:done after bash",
              "cards \(hostNew.cards.count), \(afterNew.filter { $0.hasPrefix("permission.") || $0.hasPrefix("plan_mode.") })")
        // An Always-Ask-like state in between: the session's mode set to
        // manual by a Plan turn, then Default again.
        let hostPlan = HarnessHost(cwd: folder, sessionId: sid)
        hostPlan.onCard = { card in
            if case .plan = card.presentation {
                answer(card, with: .chose(PlanContinue.id(answer: "plan_approve", mode: AgentAskingMode.adoptDefault)))
            } else { answer(card, with: .chose("approve_once")) }
        }
        _ = await runTurn(driver("SIPAI-PLANX please", AgentAskingMode.kimiPlan), host: hostPlan, binary: binary)
        check("D4. …a plan approved \"then Default\" from a PLAN turn continues in the config's mode: the command after it runs unasked",
              hostPlan.cards.count == 1 && hostPlan.events.map(signature).last == "assistant:done after planx",
              "cards \(hostPlan.cards.count), \(hostPlan.events.map(signature).suffix(2))")
        let hostAgain = HarnessHost(cwd: folder, sessionId: sid)
        hostAgain.onCard = { answer($0, with: .chose("approve_once")) }
        _ = await runTurn(driver("SIPAI-BASH again", nil), host: hostAgain, binary: binary)
        check("D4. …and a resumed Default turn is told the config's mode: still unasked",
              hostAgain.cards.isEmpty && hostAgain.events.map(signature).last == "assistant:done after bash",
              "cards \(hostAgain.cards.count)")
    }
    //     …and with none configured, a resumed Default turn after an Ask
    //     When Needed one asks again (kimi's own default, Always Ask).
    let folderD5 = makeFolder()
    let hostD5a = HarnessHost(cwd: folderD5)
    hostD5a.onCard = { answer($0, with: .chose("approve_once")) }
    _ = await runTurn(driver("SIPAI-BASH please", AgentAskingMode.kimiAskWhenNeeded), host: hostD5a, binary: binary)
    let hostD5b = HarnessHost(cwd: folderD5, sessionId: hostD5a.sessionId)
    hostD5b.onCard = { answer($0, with: .chose("approve_once")) }
    _ = await runTurn(driver("SIPAI-BASH again", nil), host: hostD5b, binary: binary)
    check("D4. the control: with no default configured, a Default turn after an Ask When Needed one asks again",
          hostD5a.cards.isEmpty && hostD5b.cards.count == 1, "AWN \(hostD5a.cards.count), Default \(hostD5b.cards.count)")
    //     A session kimi OPENS in plan mode (`default_plan_mode`): Default
    //     leaves it planning — a write is refused — and a Plan turn there
    //     is not refused for being "already" in it.
    await withConfig("default_plan_mode = true") {
        let hostDefault = HarnessHost(cwd: makeFolder())
        hostDefault.onCard = { answer($0, with: .chose("approve_once")) }
        let before = fake.requests().count
        _ = await runTurn(driver("SIPAI-WRITE please", nil), host: hostDefault, binary: binary)
        let typesDefault = wireTypes(hostDefault.sessionId ?? "")
        let hostPlanned = HarnessHost(cwd: makeFolder())
        hostPlanned.onCard = { card in
            if case .plan = card.presentation {
                answer(card, with: .chose(PlanContinue.id(answer: "plan_approve", mode: AgentAskingMode.adoptDefault)))
            } else { answer(card, with: .chose("approve_once")) }
        }
        _ = await runTurn(driver("SIPAI-PLAN please", AgentAskingMode.kimiPlan), host: hostPlanned, binary: binary)
        check("D4. a session kimi opens in plan mode: Default leaves it planning (the write is refused), and a Plan turn there runs",
              typesDefault.contains("plan_mode.enter") && !typesDefault.contains("plan_mode.cancel")
                && fake.toolMessages(after: before).contains { $0.contains("Plan mode is active") }
                && !hostPlanned.events.map(signature).contains { $0.hasPrefix("error:") }
                && hostPlanned.events.map(signature).last == "assistant:done after plan",
              "default \(typesDefault.filter { $0.hasPrefix("plan_mode.") }), plan turn \(hostPlanned.events.map(signature).suffix(2))")
    }

    // D5. `/compact`: kimi answers it at once and begins the compaction
    //     AFTER — let go of at the answer, it is cancelled. The child is
    //     kept up until the record shows it done.
    let hostD6 = HarnessHost(cwd: folderD5, sessionId: hostD5a.sessionId)
    _ = await runTurn(driver("/compact", nil), host: hostD6, binary: binary)
    let compactTypes = wireTypes(hostD5a.sessionId ?? "").filter { $0.contains("compact") }
    check("D5. /compact runs to its end: kimi's own words as a notice, the compaction drawn, and nothing cancelled",
          compactTypes.contains("full_compaction.complete") && !compactTypes.contains("full_compaction.cancel")
            && hostD6.events.map(signature).contains { $0.hasPrefix("notice:Context compaction started") }
            && hostD6.events.map(signature).contains("compaction"),
          "\(compactTypes) \(hostD6.events.map(signature))")

    // E. Questions: the whole form at once, answered by label.
    let hostE = HarnessHost(cwd: makeFolder())
    hostE.onCard = { card in
        var answers: [String: AgentQuestionAnswer] = [:]
        answers["Which database should we use?"] = AgentQuestionAnswer(labels: ["SQLite"])
        answers["Which extras do you want?"] = AgentQuestionAnswer(labels: ["Docs", "Lint"])
        answer(card, with: .answered(answers))
    }
    requestsBefore = fake.requests().count
    _ = await runTurn(driver("SIPAI-ASK2 please", nil), host: hostE, binary: binary)
    let formE = hostE.cards.first?.question
    check("E. a question set arrives whole: both questions, the second a multiple choice",
          hostE.cards.count == 1 && hostE.cards.first?.presentation == .question
            && formE?.questions.count == 2 && formE?.questions.last?.multiSelect == true,
          "\(String(describing: formE))")
    let answeredE = fake.toolMessages(after: requestsBefore)
    check("E. the answers reach the model, the picks joined in kimi's order",
          answeredE.contains { $0.contains("SQLite") && $0.contains("Lint, Docs") }, "\(answeredE)")

    // F. Non-stop: the question is dismissed, and kimi says so to the model.
    let hostF = HarnessHost(cwd: makeFolder())
    hostF.onCard = { answer($0, with: .declined(.nonStop)) }
    requestsBefore = fake.requests().count
    _ = await runTurn(driver("SIPAI-ASK1 please", AgentAskingMode.kimiAskWhenNeeded), host: hostF, binary: binary)
    check("F. Non-stop: the model is told the user did not answer, and the turn goes on",
          fake.toolMessages(after: requestsBefore).contains { $0.contains("dismissed") }
            && hostF.events.map(signature).last == "assistant:done after ask",
          "\(fake.toolMessages(after: requestsBefore))")

    // BQ. A question kimi asks in the background (`AskUserQuestion` with
    // `background: true`, kimi 2.4+): kimi goes on while it waits and ends
    // its turn with it open — kimi's own design, "the answer arrives
    // automatically in a later turn". It reaches SipAI as an ordinary
    // question; kimi keeps it as a background task, so the turn stays up
    // for it, and an answer given after kimi's turn ended still reaches
    // kimi, which runs a turn on it. Answered here 3 s after it is asked.
    if ChatOnlyAvailability.versionAtLeast(version, "2.4.0") {
        let hostQ = HarnessHost(cwd: makeFolder())
        var rowsAtAnswer: [String] = []
        var requestsAtAnswer = 0
        let requestsBeforeQ = fake.requests().count
        hostQ.onCard = { card in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                rowsAtAnswer = hostQ.events.map(signature)
                requestsAtAnswer = fake.requests().count - requestsBeforeQ
                card.respond(.answered(["Which database should we use?": AgentQuestionAnswer(labels: ["Postgres"])]))
            }
        }
        let runQ = await runTurn(driver("SIPAI-ASKBG please", AgentAskingMode.kimiAskWhenNeeded),
                                 host: hostQ, binary: binary)
        let rowsQ = hostQ.events.map(signature)
        check("BQ. kimi's background question reaches SipAI as an ordinary question card",
              hostQ.cards.count == 1 && hostQ.cards.first?.presentation == .question
                && hostQ.cards.first?.question?.questions.first?.text == "Which database should we use?",
              "\(hostQ.cards.count) cards")
        check("BQ. …kimi goes on while it waits: its next words were drawn, and asked of the model, before the answer",
              rowsAtAnswer.contains("assistant:kept working while the question waits") && requestsAtAnswer >= 2,
              "\(rowsAtAnswer), \(requestsAtAnswer) requests")
        check("BQ. …kimi ends its turn with the question open, and the turn stays up while kimi keeps the question, named on the waiting line",
              runQ.seconds >= 3 && hostQ.awaited.contains(["Which database should we use?"]),
              "\(runQ.seconds) s, \(hostQ.awaited)")
        // Kimi hands the model the answer inside its notification of the
        // finished question: `<answer>{"answers":{question: label}}</answer>`.
        let answerReachedModel = fake.requests().dropFirst(requestsBeforeQ).contains { request in
            let messages = (request["body"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []
            return messages.contains { message in
                guard message["role"] as? String == "user" else { return false }
                let text: String
                if let s = message["content"] as? String { text = s } else {
                    text = (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
                }
                return text.contains("Background question answered")
                    && text.contains(#""Which database should we use?":"Postgres""#)
            }
        }
        check("BQ. …an answer given after kimi's turn ended still reaches kimi, which runs a turn on it — drawn after kimi's notice",
              answerReachedModel
                && rowsQ.contains { $0.hasPrefix("notice:Background question answered") }
                && rowsQ.last == "assistant:the background task finished",
              "\(answerReachedModel), \(rowsQ)")
    } else {
        skip("BQ. a background question", "the installed kimi is below 2.4.0, which has none")
    }

    // G. Stop with a card up: the card answered cancelled, then kimi's own cancel.
    let hostG = HarnessHost(cwd: makeFolder())
    let driverG = driver("SIPAI-BASH please", nil)
    var peerG: JSONRPCLinePeer?
    hostG.onCard = { card in
        // What the runner's Stop does: the card answered cancelled first,
        // the turn no longer live, then the agent's own interrupt.
        Task { @MainActor in
            card.respond(.cancelled)
            hostG.live = false
            if let peerG { _ = driverG.interrupt(peer: peerG) }
        }
    }
    let runG = await runTurn(driverG, host: hostG, binary: binary, setUp: { peerG = $0 })
    let endedG = wireRecords(sessionId: hostG.sessionId ?? "").filter { $0["type"] as? String == "turn.ended" }
    check("G. Stop with a card up: kimi ends the turn as cancelled and the child is gone at once",
          endedG.last?["reason"] as? String == "cancelled" && runG.seconds < 8 && runG.exit == 0,
          "\(endedG) after \(runG.seconds) s")

    // H. A provider that refuses: the record says why, and so does the transcript.
    let hostH = HarnessHost(cwd: makeFolder())
    _ = await runTurn(driver("SIPAI-E400 please", nil), host: hostH, binary: binary)
    check("H. a refused request is an error row in kimi's words (ACP answers it as a clean end)",
          hostH.events.map(signature).contains { $0.hasPrefix("error:") && $0.contains("scripted 400") },
          "\(hostH.events.map(signature))")
    check("H. …said once: the record's row is the driver's to draw, never the reader's as well",
          hostH.events.map(signature).filter { $0.hasPrefix("error:") }.count == 1,
          "\(hostH.events.map(signature))")

    // U. No internet: kimi retries a request it gets no connection for,
    // then ends the turn as failed — and says so only in its record (ACP)
    // and on stderr (headless). A provider at a port nothing listens on,
    // and three attempts rather than kimi's ten.
    let offlineConfig = home.appendingPathComponent("config.toml")
    let configBeforeOffline = (try? String(contentsOf: offlineConfig, encoding: .utf8)) ?? ""
    try? (configBeforeOffline + """

    [providers.dead]
    base_url = "http://127.0.0.1:\(closedPort())/v1"
    type = "openai"
    api_key = "junk"

    [models."dead/dead-model"]
    provider = "dead"
    model = "dead-model"
    max_context_size = 262144
    capabilities = [ "tool_use" ]

    """).write(to: offlineConfig, atomically: true, encoding: .utf8)
    let hostOffline = HarnessHost(cwd: makeFolder())
    let driverOffline = KimiAcpTurn(text: "are you there?", options: options(nil, model: "dead/dead-model"),
                              environment: ["KIMI_LOOP_MAX_ATTEMPTS_PER_STEP": "3"],
                              agentName: "Kimi Code", clientVersion: "harness",
                              defaultPermissionMode: KimiCatalog.readDefaultPermissionMode())!
    _ = await runTurn(driverOffline, host: hostOffline, binary: binary)
    check("U. no internet, over ACP: the turn ends on ONE row, in kimi's words",
          hostOffline.events.map(signature).filter { $0.hasPrefix("error:") } == ["error:Connection error."],
          "\(hostOffline.events.map(signature))")
    check("U. …with kimi's retry line while it retried",
          hostOffline.notices.contains("Retrying (2/3) · APIConnectionError · Connection error.")
            || hostOffline.notices.contains("Retrying (3/3) · APIConnectionError · Connection error."),
          "\(hostOffline.notices)")
    let sessionsBeforeOffline = sessionIds()
    let runOffline = headlessTurn(binary: binary, cwd: makeFolder(), text: "are you there?",
                            model: "dead/dead-model", attempts: 3)
    let offlineNotices = runOffline.stdout.split(separator: "\n").compactMap { KimiEventParser.retryNotice(line: String($0)) }
    check("U. no internet, headless: kimi's retry line comes off stdout, in the words the ACP turn shows",
          offlineNotices == ["Retrying (2/3) · APIConnectionError · Connection error.",
                       "Retrying (3/3) · APIConnectionError · Connection error."],
          "\(offlineNotices) — stdout: \(runOffline.stdout)")
    check("U. …and kimi exits 1, saying why on stderr (the turn's row while it runs)",
          runOffline.exit == 1 && runOffline.stderr.contains("Connection error."), "exit \(runOffline.exit): \(runOffline.stderr)")
    let offlineSessions = sessionIds().subtracting(sessionsBeforeOffline)
    let offlineRows = offlineSessions.first.flatMap { KimiSessionScanner.sessionDirectory(forId: $0) }.map {
        KimiSessionScanner.readHistory(of: KimiSessionScanner.wireFile(inSessionDir: $0))
            .compactMap(AgentSessionTailer.liveEvent(for:)).map(signature)
    } ?? []
    check("U. …and reopened, the question and then kimi's words",
          offlineSessions.count == 1 && offlineRows == ["user:are you there?", "error:Connection error."],
          "\(offlineSessions) \(offlineRows)")
    try? configBeforeOffline.write(to: offlineConfig, atomically: true, encoding: .utf8)

    // I. A command kimi answers itself: no model call, the answer a notice.
    let hostI = HarnessHost(cwd: makeFolder())
    requestsBefore = fake.requests().count
    _ = await runTurn(driver("/status", nil), host: hostI, binary: binary)
    check("I. /status is answered by kimi itself: no model request, its answer a notice",
          fake.requests().count == requestsBefore
            && hostI.events.map(signature).contains { $0.hasPrefix("notice:") && $0.contains("Session:") },
          "\(hostI.events.map(signature))")

    // J. Stopped before the message went: the session made for it goes.
    let countBefore = sessionCount()
    let hostJ = HarnessHost(cwd: makeFolder())
    hostJ.live = false
    requestsBefore = fake.requests().count
    _ = await runTurn(driver("SIPAI-BASH please", nil), host: hostJ, binary: binary)
    check("J. stopped before the message went: nothing adopted, nothing sent, no session left behind",
          hostJ.adopted.isEmpty && fake.requests().count == requestsBefore && sessionCount() == countBefore,
          "adopted \(hostJ.adopted), sessions \(countBefore) → \(sessionCount())")

    // K. A resumed session: an edit outside a git repository asks, with the file.
    let hostK = HarnessHost(cwd: folderA, sessionId: sidA)
    hostK.onCard = { answer($0, with: .chose("reject")) }
    requestsBefore = fake.requests().count
    _ = await runTurn(driver("SIPAI-WRITE please", nil), host: hostK, binary: binary)
    if case .permission(let content)? = hostK.cards.first?.presentation {
        check("K. resumed: a write asks, showing the file at its full path and its new lines",
              hostK.adopted.isEmpty
                && content.preview == .fileChanges([CardFileChange(path: folderA.path + "/probe.txt", kind: "",
                                                                   diff: "+hello")], reason: nil),
              "\(content.preview)")
    } else {
        check("K. resumed: a write asks", false, "\(hostK.cards.map(\.presentation))")
    }
    check("K. Reject reaches the model, and nothing is written",
          fake.toolMessages(after: requestsBefore).contains { $0.contains("rejected") }
            && !FileManager.default.fileExists(atPath: folderA.path + "/probe.txt"))

    // M. The plan mode an Ask turn leaves on: a headless turn cannot edit in
    //    it, so kimi is asked to leave it first — the runner's preflight.
    let folderM = makeFolder()
    let hostM = HarnessHost(cwd: folderM)
    _ = await runTurn(driver("plan it, no tools", AgentAskingMode.kimiPlan), host: hostM, binary: binary)
    let sidM = hostM.sessionId ?? ""
    let wireM = KimiSessionScanner.sessionDirectory(forId: sidM).map { KimiSessionScanner.wireFile(inSessionDir: $0) }
    _ = wireM.map { KimiRuntimeBinding.restore(wire: $0) }   // what the runner does at the turn's end
    check("M. an Ask turn in Plan leaves its session in plan mode (the hazard)",
          wireM.map { KimiAcp.planModeLeftOn(wire: $0) } == true)
    requestsBefore = fake.requests().count
    _ = printTurn(binary: binary, cwd: folderM, sessionId: sidM, text: "SIPAI-WRITE please")
    check("M. control: left so, the next headless turn refuses the edit",
          fake.toolMessages(after: requestsBefore).contains { $0.contains("Plan mode is active") }
            && !FileManager.default.fileExists(atPath: folderM.path + "/probe.txt"),
          "\(fake.toolMessages(after: requestsBefore))")
    var leftPlan = false
    requestsBefore = fake.requests().count
    _ = await converse(binary: binary, cwd: folderM) { peer in
        leftPlan = await KimiAcpTurn.leavePlanMode(peer: peer, sessionId: sidM, cwd: folderM.path,
                                                   clientVersion: "harness")
    }
    let restoredM = wireM.map { KimiRuntimeBinding.restore(wire: $0) } ?? false
    check("M. asked, kimi takes the session out of plan mode — no message sent, the binding handed back",
          leftPlan && restoredM && wireM.map { KimiAcp.planModeLeftOn(wire: $0) } == false
            && fake.requests().count == requestsBefore && bindings(sessionId: sidM).last == "local",
          "left \(leftPlan), bindings \(bindings(sessionId: sidM))")
    requestsBefore = fake.requests().count
    _ = printTurn(binary: binary, cwd: folderM, sessionId: sidM, text: "SIPAI-WRITE please")
    check("M. the headless turn then makes its edit",
          FileManager.default.fileExists(atPath: folderM.path + "/probe.txt")
            && fake.toolMessages(after: requestsBefore).contains { $0.contains("Wrote") },
          "\(fake.toolMessages(after: requestsBefore))")

    // N. Kimi gone mid-turn, a card up. The record then holds the turn's
    //    start and never its end, and a driver that waited on that would
    //    keep a dead turn "running": it returns at once, the conversation
    //    closed — which is what tells the runner to report the child's exit.
    let hostN = HarnessHost(cwd: makeFolder())
    var childN: Process?
    hostN.onCard = { _ in if let pid = childN?.processIdentifier { kill(pid, SIGKILL) } }
    let runN = await runTurn(driver("SIPAI-BASH please", nil), host: hostN,
                             binary: binary, onSpawn: { childN = $0 })
    let recordN = wireRecords(sessionId: hostN.sessionId ?? "").compactMap { $0["type"] as? String }
    check("N. kimi killed with a card up: the record keeps the turn open for good (the hazard)",
          hostN.cards.count == 1 && recordN.contains("turn.prompt") && !recordN.contains("turn.ended"),
          "cards \(hostN.cards.count), \(recordN.filter { $0.hasPrefix("turn.") })")
    check("N. …and the driver returns at once all the same, the conversation closed under it",
          runN.closedUnderBody && runN.bodySeconds < 10,
          "closed \(runN.closedUnderBody), \(runN.bodySeconds) s")
    check("N. the session it left bound is handed back like any other",
          KimiSessionScanner.sessionDirectory(forId: hostN.sessionId ?? "")
            .map { KimiRuntimeBinding.restore(wire: KimiSessionScanner.wireFile(inSessionDir: $0)) } == true
            && bindings(sessionId: hostN.sessionId ?? "").last == "local",
          "\(bindings(sessionId: hostN.sessionId ?? ""))")

    // O–Q. The answers the real server cannot be made to give, from the
    //      stand-in (stub_server.py).
    let hostO = HarnessHost(cwd: makeFolder())
    let stubO = await runStubTurn(driver("hello", nil), host: hostO, mode: "wrong-version")
    check("O. another protocol version: one row saying so, and nothing more is asked of the server",
          hostO.adopted.isEmpty && stubO.methods == ["initialize"]
            && hostO.events.map(signature).count == 1
            && hostO.events.map(signature).first?.hasPrefix("error:The installed Kimi Code answered") == true,
          "\(stubO.methods) \(hostO.events.map(signature))")
    let hostP = HarnessHost(cwd: makeFolder())
    let stubP = await runStubTurn(driver("hello", nil), host: hostP, mode: "no-session-id")
    check("P. a session opened without an id: one row saying so, nothing adopted, no message sent",
          hostP.adopted.isEmpty && !stubP.methods.contains("session/prompt")
            && hostP.events.map(signature).count == 1
            && hostP.events.map(signature).first?.hasPrefix("error:The installed Kimi Code answered") == true,
          "\(stubP.methods) \(hostP.events.map(signature))")
    let hostQ = HarnessHost(cwd: makeFolder())
    let stubQ = await runStubTurn(driver("hello", nil), host: hostQ, mode: "die")
    check("Q. a server that exits as the message arrives: the driver returns at once, the conversation closed, its exit and words the runner's to report",
          stubQ.run.closedUnderBody && stubQ.run.bodySeconds < 5 && stubQ.run.exit == 3
            && stubQ.run.stderr.contains("scripted crash") && hostQ.adopted == ["session_stub"]
            && stubQ.methods.last == "session/prompt",
          "closed \(stubQ.run.closedUnderBody), \(stubQ.run.bodySeconds) s, exit \(stubQ.run.exit), \(stubQ.methods)")

    // R. A step refused with NO words: the turn still ends on a row, and
    // a session made for it is asked to be removed.
    let hostR = HarnessHost(cwd: makeFolder())
    // Ask When Needed: a mode the turn states (a new session on Default
    // states none).
    let stubR = await runStubTurn(driver("hello", AgentAskingMode.kimiAskWhenNeeded), host: hostR,
                                  mode: "mute-mode")
    check("R. a step refused with no words, before the message went: one row that says so, nothing adopted, the session it made asked to go",
          hostR.events.map(signature) == ["error:Kimi Code reported an error but gave no detail."]
            && hostR.adopted.isEmpty && stubR.methods.last == "session/delete"
            && !stubR.methods.contains("session/prompt"),
          "\(stubR.methods) \(hostR.events.map(signature))")
    let hostR2 = HarnessHost(cwd: makeFolder())
    let stubR2 = await runStubTurn(driver("hello", nil), host: hostR2, mode: "mute-prompt")
    check("R. …the message itself refused with no words, and no record of a failed turn to say why: the same one row",
          hostR2.events.map(signature) == ["error:Kimi Code reported an error but gave no detail."]
            && hostR2.adopted == ["session_stub"] && stubR2.methods.last == "session/prompt",
          "\(stubR2.methods) \(hostR2.events.map(signature))")

    // V. A turn that fails ENDS failed: the driver tells the runner, in the
    //    words its row already says, so a scheduled run is recorded as an
    //    error rather than "done" — and the runner draws no second row.
    let hostV = HarnessHost(cwd: makeFolder())
    _ = await runTurn(driver("SIPAI-E400 once more", nil), host: hostV, binary: binary)
    let rowsV = hostV.events.map(signature).filter { $0.hasPrefix("error:") }
    check("V. a turn kimi failed is reported failed, once, in its row's own words",
          hostV.failures.count == 1 && hostV.failures.first?.contains("scripted 400") == true
            && rowsV == hostV.failures.map { "error:" + $0 },
          "\(hostV.failures) \(rowsV)")
    check("V. …and so is a turn kimi refused before it ran — with no words, in another protocol, a session with no id",
          hostR.failures == ["Kimi Code reported an error but gave no detail."]
            && hostR2.failures == ["Kimi Code reported an error but gave no detail."]
            && hostO.failures.count == 1
            && hostO.failures.first?.hasPrefix("The installed Kimi Code answered") == true
            && hostP.failures.count == 1
            && hostP.failures.first?.hasPrefix("The installed Kimi Code answered") == true,
          "\(hostR.failures) \(hostR2.failures) \(hostO.failures) \(hostP.failures)")
    check("V. …and a turn that went well, one kimi answered itself, or one whose server died (the runner says that one), is no failure",
          hostA.failures.isEmpty && hostI.failures.isEmpty && hostQ.failures.isEmpty,
          "\(hostA.failures) \(hostI.failures) \(hostQ.failures)")

    // T. A chosen skill: kimi's own `/skill:name` ahead of the message, in
    // any mode — Never Ask too, in kimi's own `auto` — ONE request holding
    // the skill and the words, drawn as the words with the skill named.
    func bodies(since from: Int) -> [String] {
        fake.requests().dropFirst(from).map { request in
            let data = (try? JSONSerialization.data(withJSONObject: request["body"] ?? [String: Any]())) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }
    let folderT = makeFolder()
    let skillDirT = folderT.appendingPathComponent(".kimi-code/skills/sipai-marker")
    try? FileManager.default.createDirectory(at: skillDirT, withIntermediateDirectories: true)
    try? "---\nname: sipai-marker\ndescription: A marker skill for the harness.\n---\n\nSIPAI-SKILL-BODY-7\n"
        .write(to: skillDirT.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    var withSkill = options(AgentAskingMode.kimiNeverAsk)
    withSkill.skillTriggers = [SkillTrigger(name: "sipai-marker")]
    let hostT = HarnessHost(cwd: folderT)
    requestsBefore = fake.requests().count
    if let turnT = KimiAcpTurn(text: "do the marked thing", options: withSkill, environment: [:],
                               agentName: "Kimi Code", clientVersion: "harness",
                               defaultPermissionMode: KimiCatalog.readDefaultPermissionMode()) {
        _ = await runTurn(turnT, host: hostT, binary: binary)
        let sidT = hostT.sessionId ?? ""
        check("T. Never Ask loads a chosen skill through kimi's front end: one request holds the skill and the words",
              bodies(since: requestsBefore).contains { $0.contains("SIPAI-SKILL-BODY-7") && $0.contains("do the marked thing") },
              "\(bodies(since: requestsBefore).map { String($0.prefix(160)) })")
        check("T. …in kimi's own Never Ask, auto, stated to the session",
              wireTypes(sidT).contains("permission.set_mode=auto"), "\(wireTypes(sidT))")
        check("T. the message's own row is not drawn a second time",
              !hostT.events.map(signature).contains { $0.hasPrefix("user:") }, "\(hostT.events.map(signature))")
        if let dir = KimiSessionScanner.sessionDirectory(forId: sidT) {
            let first = KimiSessionScanner.readHistory(of: KimiSessionScanner.wireFile(inSessionDir: dir)).first
            let reopened: (String, [String])? = first.flatMap { item in
                if case .userText(let t) = item.kind { return (t, item.loadedSkills) }; return nil
            }
            check("T. reopened, the message reads as its words with the skill named under them — as the live row does",
                  reopened.map { $0.0 == "do the marked thing" && $0.1 == ["sipai-marker"] } == true, "\(String(describing: reopened))")
            _ = KimiRuntimeBinding.restore(wire: KimiSessionScanner.wireFile(inSessionDir: dir))
        } else {
            check("T. the session's record is where kimi files it", false)
        }
    } else {
        check("T. a Never Ask turn that loads a skill has a driver", false)
    }
    // A skill kimi does not list: kimi answers the command itself and runs
    // no turn. Said, and the words sent on their own.
    var unknownSkill = options(AgentAskingMode.kimiNeverAsk)
    unknownSkill.skillTriggers = [SkillTrigger(name: "sipai-no-such-skill")]
    let hostU = HarnessHost(cwd: makeFolder())
    requestsBefore = fake.requests().count
    if let turnU = KimiAcpTurn(text: "words that must still go", options: unknownSkill, environment: [:],
                               agentName: "Kimi Code", clientVersion: "harness",
                               defaultPermissionMode: KimiCatalog.readDefaultPermissionMode()) {
        _ = await runTurn(turnU, host: hostU, binary: binary)
        let sigU = hostU.events.map(signature)
        check("T. a skill kimi does not list: said so, and the words still reach the model",
              sigU.contains { $0.hasPrefix("error:") && $0.contains("sipai-no-such-skill") }
                && bodies(since: requestsBefore).contains { $0.contains("words that must still go") },
              "\(sigU)")
        // The row was drawn naming the skill, and a live row's skill is
        // what the chip takes for "in the conversation": left standing, it
        // read as loaded and was never sent again.
        check("T. …and the row is told to stop naming the skill that did not load",
              hostU.retracted == [["*"]], "\(hostU.retracted)")
        if let dir = KimiSessionScanner.sessionDirectory(forId: hostU.sessionId ?? "") {
            _ = KimiRuntimeBinding.restore(wire: KimiSessionScanner.wireFile(inSessionDir: dir))
        }
    }

    // A command the user typed that kimi does not know (a skill it does
    // not list): kimi answers it itself, nothing reaches the model — and
    // a row drawn as that skill's words stops naming it.
    let hostTyped = HarnessHost(cwd: makeFolder())
    requestsBefore = fake.requests().count
    _ = await runTurn(driver("/skill:sipai-no-such-skill typed words", nil), host: hostTyped, binary: binary)
    check("T. a typed command kimi does not know: its own answer as a notice, no model request, the row's claim taken back",
          hostTyped.events.map(signature).contains { $0.contains("Unknown ACP command") }
            && !bodies(since: requestsBefore).contains { $0.contains("typed words") }
            && hostTyped.retracted == [["*"]],
          "\(hostTyped.events.map(signature)) retracted \(hostTyped.retracted)")
    if let dir = KimiSessionScanner.sessionDirectory(forId: hostTyped.sessionId ?? "") {
        _ = KimiRuntimeBinding.restore(wire: KimiSessionScanner.wireFile(inSessionDir: dir))
    }
    // …and one it does know, spelled by the skill's bare name: kimi starts
    // the skill for it as it does for `/skill:name`, and records the same.
    let hostAlias = HarnessHost(cwd: folderT)
    requestsBefore = fake.requests().count
    _ = await runTurn(driver("/sipai-marker alias words", nil), host: hostAlias, binary: binary)
    let aliasRow: (String, [String])? = KimiSessionScanner.sessionDirectory(forId: hostAlias.sessionId ?? "").flatMap { dir in
        KimiSessionScanner.readHistory(of: KimiSessionScanner.wireFile(inSessionDir: dir)).first.flatMap { item in
            if case .userText(let t) = item.kind { return (t, item.loadedSkills) }; return nil
        }
    }
    check("T. a skill's bare name is a command to kimi: the skill and the words in one request, recorded as the words with the skill",
          bodies(since: requestsBefore).contains { $0.contains("SIPAI-SKILL-BODY-7") && $0.contains("alias words") }
            && aliasRow.map { $0.0 == "alias words" && $0.1 == ["sipai-marker"] } == true
            && hostAlias.retracted.isEmpty,
          "\(String(describing: aliasRow)) retracted \(hostAlias.retracted)")
    if let dir = KimiSessionScanner.sessionDirectory(forId: hostAlias.sessionId ?? "") {
        _ = KimiRuntimeBinding.restore(wire: KimiSessionScanner.wireFile(inSessionDir: dir))
    }

    // MF. An MCP server's own request for input. Kimi's MCP client tells its
    // servers it takes none, and answers one that asks anyway itself, so
    // nothing reaches ACP: the tool's own approval is the only card. A
    // tripwire — the day kimi takes forms, what it relays must be drawn.
    if FileManager.default.fileExists(atPath: formServerPath) {
        let serverLog = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kimiacp-forms-\(UUID().uuidString).log")
        let mcpFile = home.appendingPathComponent("mcp.json")
        let config: [String: Any] = ["mcpServers": ["forms": [
            "command": "/usr/bin/env", "args": ["python3", formServerPath, serverLog.path]]]]
        try? JSONSerialization.data(withJSONObject: config).write(to: mcpFile)
        let hostMF = HarnessHost(cwd: makeFolder())
        hostMF.onCard = { answer($0, with: .chose("approve_once")) }
        _ = await runTurn(driver("SIPAI-MCPFORM please", nil), host: hostMF, binary: binary)
        try? FileManager.default.removeItem(at: mcpFile)
        let logText = (try? String(contentsOf: serverLog, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: serverLog)
        if case .permission(let content)? = hostMF.cards.first?.presentation {
            check("MF. an MCP tool asks on kimi's own permission card, as its other tools do",
                  hostMF.cards.count == 1 && hostMF.cards.first?.toolName == "mcp__forms__ask_form"
                    && content.choices.map(\.id) == ["approve_once", "approve_always", "reject"],
                  "\(hostMF.cards.count) cards")
        } else {
            check("MF. an MCP tool asks on kimi's own permission card", false, "\(hostMF.cards.map(\.presentation))")
        }
        check("MF. tripwire: kimi's MCP client takes no forms or links (it declares no elicitation), and answers a server that asks anyway itself — no card reaches SipAI",
              logText.contains(#""capabilities": {}"#) && logText.contains("Method not found")
                && hostMF.events.contains { event in
                    if case .toolResult(_, let output, _) = event.kind { return output.contains("Method not found") }
                    return false
                },
              String(logText.prefix(400)))
    } else {
        skip("MF. an MCP server's request for input", "no stand-in MCP server at \(formServerPath)")
    }

    // L. A background task: the child stays up for the turn kimi runs when it finishes.
    if ProcessInfo.processInfo.environment["SIPAI_KIMIACP_SLOW"] == "1" {
        let folderL = makeFolder()
        let hostL = HarnessHost(cwd: folderL)
        let runL = await runTurn(driver("SIPAI-BG please", AgentAskingMode.kimiAskWhenNeeded), host: hostL, binary: binary)
        let rowsL = hostL.events.map(signature)
        check("L. a background task: the turn lasts until kimi's own follow-up turn is over, and both are drawn",
              runL.seconds >= 4 && FileManager.default.fileExists(atPath: folderL.path + "/bg.txt")
                && rowsL.contains("assistant:the background task finished"),
              "\(runL.seconds) s, \(rowsL)")
        check("L. …kimi's notification of the finished task is a system notice in kimi's own short words, and nothing is drawn as the user's",
              rowsL.contains("notice:Background process completed · bg sleep completed.")
                && !rowsL.contains { $0.hasPrefix("user:") },
              "\(rowsL)")
        check("L. …while kimi waits on it, the transcript names the task by its description, and at the end nothing",
              hostL.awaited.contains(["bg sleep"]) && hostL.awaited.last == [], "\(hostL.awaited)")
        let reopenedL = KimiSessionScanner.sessionDirectory(forId: hostL.sessionId ?? "").map {
            KimiSessionScanner.readHistory(of: KimiSessionScanner.wireFile(inSessionDir: $0))
        } ?? []
        check("L. …reopened, the same: the user's one message, then the notice — which is not a message of theirs",
              reopenedL.filter { if case .userText = $0.kind { return !$0.isSystemNotice }; return false }.count == 1
                && reopenedL.filter { $0.isSystemNotice }.count == 1,
              "\(reopenedL.count) rows")

        // S. Stop while a background task is running. Kimi stops its tasks
        // as it winds down after its stdin closes — about five seconds —
        // and only then: the driver asks for that long, on Stop and at the
        // turn's end.
        func taskPid(_ sessionId: String?) -> Int32? {
            wireRecords(sessionId: sessionId ?? "").compactMap { record -> Int32? in
                guard record["type"] as? String == "task.started" else { return nil }
                return ((record["info"] as? [String: Any])?["pid"] as? NSNumber)?.int32Value
            }.last
        }
        func waitForTask(_ host: HarnessHost) async {
            for _ in 0..<200 {
                if host.events.map(signature).contains("assistant:started the long one") { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        let hostS = HarnessHost(cwd: makeFolder())
        let driverS = driver("SIPAI-BGLONG please", AgentAskingMode.kimiAskWhenNeeded)
        var peerS: JSONRPCLinePeer?
        var graceS: TimeInterval = 0
        let stopS = Task { @MainActor in
            await waitForTask(hostS)
            hostS.live = false
            if let peerS { graceS = driverS.interrupt(peer: peerS) }
        }
        let runS = await runTurn(driverS, host: hostS, binary: binary, setUp: { peerS = $0 })
        await stopS.value
        let pidS = taskPid(hostS.sessionId)
        check("S. Stop with a background task running: kimi is given its own wind-down, and stops the task in it",
              graceS >= 6 && driverS.exitGrace >= 6 && runS.exit == 0
                && pidS != nil && kill(pidS ?? 0, 0) != 0,
              "grace \(graceS), exit grace \(driverS.exitGrace), exit \(runS.exit) after \(runS.seconds) s, task pid \(String(describing: pidS)) alive \(pidS.map { kill($0, 0) == 0 } ?? false)")
        // The control: the same turn, kimi stopped the way a child with
        // nothing to clean up is. It exits at once and the task is left.
        let hostT = HarnessHost(cwd: makeFolder())
        let driverT = driver("SIPAI-BGLONG please", AgentAskingMode.kimiAskWhenNeeded)
        var childT: Process?
        let stopT = Task { @MainActor in
            await waitForTask(hostT)
            childT?.terminate()
        }
        _ = await runTurn(driverT, host: hostT, binary: binary, onSpawn: { childT = $0 })
        await stopT.value
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let pidT = taskPid(hostT.sessionId)
        let orphaned = pidT.map { kill($0, 0) == 0 } ?? false
        if let pidT, orphaned { kill(pidT, SIGKILL) }
        check("S. …the control: a kimi that is SIGTERMed instead exits at once and leaves that task running",
              orphaned, "task pid \(String(describing: pidT))")
    } else {
        skip("L. the background-task linger, and S. Stop with a task running", "set SIPAI_KIMIACP_SLOW=1 (~25 s)")
    }
}

/// Another kimi has the session open (kimi's own session lock,
/// `KimiSessionLock`): the rule kimi judges a holder by, SipAI's read of the
/// real lock a real `kimi acp` takes, kimi's own two answers to a second
/// writer — a headless one refused, one over ACP let through, which is why
/// SipAI checks itself — and the runner asking before a turn starts.
@MainActor
func sessionLock() async {
    print("\n2K. Another kimi has the session open (kimi's session lock)")
    let boot = Date(timeIntervalSince1970: 1_000_000)
    let here = KimiSessionLock.Holder(pid: 42, hostname: "this-mac", startedAt: 2_000_000_000, clientName: "Kimi Code CLI")
    check("Lock. a holder on another host is taken as alive; on this host only while its process runs and was started since boot",
          KimiSessionLock.isAlive(KimiSessionLock.Holder(pid: 42, hostname: "other-mac", startedAt: 0, clientName: nil),
                                  hostname: "this-mac", bootTime: boot, processAlive: { _ in false })
          && KimiSessionLock.isAlive(here, hostname: "this-mac", bootTime: boot, processAlive: { _ in true })
          && !KimiSessionLock.isAlive(here, hostname: "this-mac", bootTime: boot, processAlive: { _ in false })
          && !KimiSessionLock.isAlive(KimiSessionLock.Holder(pid: 42, hostname: "this-mac", startedAt: 1, clientName: nil),
                                      hostname: "this-mac", bootTime: boot, processAlive: { _ in true }))
    check("Lock. the words name the holder, else the agent",
          KimiSessionLock.occupiedMessage(here, agentName: "Kimi Code").contains("Kimi Code CLI")
          && KimiSessionLock.occupiedMessage(KimiSessionLock.Holder(pid: 1, hostname: "", startedAt: 0, clientName: nil),
                                             agentName: "Kimi Code").contains("another Kimi Code"))
    let early = body(runnerSource, from: "private func runOnce(")
    let asks = early.range(of: "KimiSessionLock.heldElsewhere(sessionId: sid)")
    let picks = early.range(of: "let driver = AgentTurnDriver.pick(")
    check("Lock. a kimi turn asks the lock before its front end is picked, and ends with the words when it is held",
          asks != nil && picks != nil && asks!.lowerBound < picks!.lowerBound
          && early.contains("KimiSessionLock.occupiedMessage(holder, agentName: agentDisplayName)"))

    let link = (("~/.kimi-code/bin/kimi" as NSString).expandingTildeInPath as String)
    let binary = URL(fileURLWithPath: link).resolvingSymlinksInPath().path
    guard FileManager.default.isExecutableFile(atPath: binary), let version = kimiVersion(binary) else {
        skip("Lock. the real lock", "kimi is not installed at ~/.kimi-code/bin/kimi"); return
    }
    guard ChatOnlyAvailability.versionAtLeast(version, "2.3.1") else {
        skip("Lock. the real lock", "kimi \(version) is older than the one its session lock was measured on"); return
    }
    guard let fake = startFake(script: []) else { check("Lock. the fake model endpoint starts", false); return }
    defer { fake.process.terminate() }
    let lockHome = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kimiacp-lock-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: lockHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: lockHome) }
    try? """
    default_model = "fake/fake-model"

    [providers.fake]
    base_url = "http://127.0.0.1:\(fake.port)/v1"
    type = "openai"
    api_key = "junk"

    [models."fake/fake-model"]
    provider = "fake"
    model = "fake-model"
    max_context_size = 262144
    capabilities = [ "tool_use" ]

    """.write(to: lockHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    var env = ProcessInfo.processInfo.environment
    env["KIMI_CODE_HOME"] = lockHome.path
    let cwd = makeFolder()
    func headless(_ args: [String]) -> (exit: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    let first = headless(["--prompt", "first", "--output-format", "stream-json"])
    let sid = first.out.split(separator: "\n").compactMap { line -> String? in
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              o["type"] as? String == "session.resume_hint" else { return nil }
        return o["session_id"] as? String
    }.first
    guard let sid else { check("Lock. a session to hold is made", false, String(first.out.prefix(200))); return }
    func recorded(_ text: String) -> Bool {
        let sessions = lockHome.appendingPathComponent("sessions")
        let walker = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if url.lastPathComponent == "wire.jsonl", url.path.contains(sid),
               let t = try? String(contentsOf: url, encoding: .utf8), t.contains(text) { return true }
        }
        return false
    }
    // The holder: an idle `kimi acp` that has the session open.
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: binary)
    holder.arguments = ["acp"]
    holder.currentDirectoryURL = cwd
    holder.environment = env
    let holderIn = Pipe()
    holder.standardInput = holderIn
    holder.standardOutput = FileHandle.nullDevice
    holder.standardError = FileHandle.nullDevice
    guard (try? holder.run()) != nil else { check("Lock. a holder starts", false); return }
    for line in [#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}"#,
                 #"{"jsonrpc":"2.0","id":2,"method":"session/resume","params":{"sessionId":"\#(sid)","cwd":"\#(cwd.path)","mcpServers":[]}}"#] {
        holderIn.fileHandleForWriting.write(Data((line + "\n").utf8))
    }
    let lockFile = KimiSessionLock.file(sessionId: sid, home: lockHome)
    for _ in 0..<150 where !FileManager.default.fileExists(atPath: lockFile.path) {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    let read = KimiSessionLock.holder(sessionId: sid, home: lockHome)
    check("Lock. a kimi with the session open holds kimi's lock, and SipAI reads who holds it",
          read?.pid == holder.processIdentifier && read?.clientName == "Kimi Code CLI"
          && KimiSessionLock.heldElsewhere(sessionId: sid, home: lockHome) != nil,
          String(describing: read))
    let refused = headless(["--prompt", "while held", "--output-format", "stream-json", "--session", sid])
    check("Lock. kimi refuses a headless turn on it before running anything (session.occupied, exit 4, nothing recorded)",
          refused.exit == 4 && refused.out.contains("\"code\":\"session.occupied\"") && !recorded("while held"),
          "exit \(refused.exit): " + String(refused.out.suffix(200)))
    // A turn over kimi's front end is let through and written beside the
    // holder: the reason SipAI asks the lock itself.
    let second = HarnessHost(cwd: cwd, sessionId: sid)
    let previous = getenv("KIMI_CODE_HOME").map { String(cString: $0) }
    setenv("KIMI_CODE_HOME", lockHome.path, 1)
    _ = await runTurn(KimiAcpTurn(text: "beside the holder", options: options(nil), environment: [:],
                                  agentName: "Kimi Code", clientVersion: "harness",
                                  defaultPermissionMode: nil)!,
                      host: second, binary: binary)
    if let previous { setenv("KIMI_CODE_HOME", previous, 1) } else { unsetenv("KIMI_CODE_HOME") }
    check("Lock. kimi lets a second client's turn over its front end through, and records it beside the holder",
          recorded("beside the holder"))
    try? holderIn.fileHandleForWriting.close()
    for _ in 0..<100 where holder.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
    check("Lock. the holder gone, the lock goes with it and nothing holds the session",
          !holder.isRunning && KimiSessionLock.heldElsewhere(sessionId: sid, home: lockHome) == nil
          && !FileManager.default.fileExists(atPath: lockFile.path))
    // A lock left behind by a kimi that was killed names a process that is
    // gone: kimi takes such a lock over, and so nothing holds the session.
    try? FileManager.default.createDirectory(at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    var name = [CChar](repeating: 0, count: 256)
    _ = gethostname(&name, 255)
    let stale = #"{"version":1,"token":"1:x","pid":\#(holder.processIdentifier),"hostname":"\#(String(cString: name))","startedAt":\#(Int(Date().timeIntervalSince1970 * 1000)),"clientIdentity":"kimi_code_cli","clientDisplayName":"Kimi Code CLI"}"#
    try? Data(stale.utf8).write(to: lockFile)
    check("Lock. a lock a killed kimi left behind holds nothing", KimiSessionLock.heldElsewhere(sessionId: sid, home: lockHome) == nil)
    try? FileManager.default.removeItem(at: lockFile)
}

Task { @MainActor in
    await overlappingReads()
    await live()
    await sessionLock()
    print("\n\(passed) passed, \(failed) failed, \(skipped) skipped")
    exit(failed == 0 ? 0 : 1)
}
dispatchMain()
