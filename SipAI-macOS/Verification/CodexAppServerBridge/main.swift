// Codex's asking modes over `codex app-server` — see run.sh for what is
// pinned and why. Section 1 is pure, section 3 reads the sources, and
// section 2 (last, asynchronous) drives the real codex, token-free.

import Foundation

var passed = 0, failed = 0, skipped = 0

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        passed += 1
        print("  ok   \(name)")
    } else {
        failed += 1
        let d = detail()
        print("  FAIL \(name)" + (d.isEmpty ? "" : " — \(d)"))
    }
}

func skip(_ name: String, _ why: String) {
    skipped += 1
    print("  SKIP \(name) — \(why)")
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

func jsonText(_ obj: Any) -> String {
    guard JSONSerialization.isValidJSONObject(obj),
          let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    else { return "\(obj)" }
    return String(decoding: data, as: UTF8.self)
}

func signature(_ e: StreamEvent) -> String {
    switch e.kind {
    case .assistantText(let t): return "assistant:" + t.trimmingCharacters(in: .whitespacesAndNewlines)
    case .toolUse(_, let name, let input): return "tool:\(name):\((input["command"] as? String) ?? "")"
    case .toolResult(_, let output, let isError):
        return "output:\(isError ? "error:" : "")" + output.trimmingCharacters(in: .whitespacesAndNewlines)
    case .result: return "turn-result"
    case .error(let m): return "error:" + m
    case .interrupted(let m): return "interrupted:" + m
    case .userMessage(let t): return "user:" + t
    case .systemInit: return "init"
    case .thinking(let t): return "thinking:" + t
    case .compaction: return "compaction"
    case .shellOutput(let o): return "shell:" + o.text
    }
}

let agent = "Codex"

// MARK: - 1. The rules

print("1. The rules")

check("Default and Plan run in codex's own collaboration modes, and the three fixed modes in its Default one; nothing else runs here",
      CodexAppServer.mode(for: nil) == .defaultMode
        && CodexAppServer.mode(for: AgentAskingMode.codexPlan) == .plan
        && ["read-only", "workspace-write", "full-access"].allSatisfy {
            CodexAppServer.mode(for: $0) == .defaultMode }
        && CodexAppServer.mode(for: "plan") == nil
        && CodexAppServer.mode(for: "bypassPermissions") == nil
        && CodexAppServer.mode(for: AgentAskingMode.legacyCodexAgent) == nil)
// FX. Codex's three fixed modes state what `codex exec` enforces for each:
// never asking, and the mode's own sandbox — never codex's default for the
// folder, and never a profile (the chip names the sandbox).
let fixed = ["read-only", "workspace-write", "full-access"].map { CodexAppServer.fixedPermissions(for: $0) }
check("FX. each fixed mode states never asking and its own sandbox, as codex exec's argv for it does",
      fixed.map { $0?.approvalPolicy as? String } == ["never", "never", "never"]
        && fixed.map { $0?.sandbox } == ["read-only", "workspace-write", "danger-full-access"]
        && fixed.allSatisfy { $0?.profile == nil && $0?.approvalsReviewer == nil },
      "\(fixed.map { "\(String(describing: $0?.approvalPolicy))/\(String(describing: $0?.sandbox))" })")
check("FX. …and Default, Plan and anything else state codex's own default instead",
      CodexAppServer.fixedPermissions(for: nil) == nil
        && CodexAppServer.fixedPermissions(for: AgentAskingMode.codexPlan) == nil
        && CodexAppServer.fixedPermissions(for: "bypassPermissions") == nil)
check("FX. the sandbox each states is the one codex exec's argv for the mode names",
      ["read-only", "workspace-write"].allSatisfy { mode in
          CodexCapabilities.sandboxArgv(for: mode)?.contains("sandbox_mode=\(mode)") == true
            && CodexAppServer.fixedPermissions(for: mode)?.sandbox == mode }
        && CodexCapabilities.sandboxArgv(for: "full-access") == ["--dangerously-bypass-approvals-and-sandbox"]
        && CodexAppServer.fixedPermissions(for: "full-access")?.sandbox == "danger-full-access")
if let fixedWW = CodexAppServer.fixedPermissions(for: "workspace-write") {
    let startWW = CodexAppServer.threadStartParams(cwd: "/w", stating: fixedWW)
    check("FX. a new thread in a fixed mode is started stating it",
          startWW.keys.sorted() == ["approvalPolicy", "cwd", "sandbox"]
            && startWW["approvalPolicy"] as? String == "never" && startWW["sandbox"] as? String == "workspace-write",
          "\(startWW)")
    let resumeWW = CodexAppServer.threadResumeParams(threadId: "t1", cwd: "/w", permissions: fixedWW)
    check("FX. a resumed thread in a fixed mode states it, over whatever its last turn ran with",
          resumeWW["approvalPolicy"] as? String == "never" && resumeWW["sandbox"] as? String == "workspace-write"
            && resumeWW["permissions"] == nil && resumeWW["approvalsReviewer"] == nil,
          "\(resumeWW)")
    let turnWW = CodexAppServer.turnStartParams(
        threadId: "t1", text: "hi", cwd: "/w", mode: .defaultMode,
        settings: CodexAppServer.TurnSettings(model: "gpt-a", effort: nil, serviceTier: "priority"),
        permissions: fixedWW, threadModel: nil)
    check("FX. …and its turn states never asking, the speed it was sent with, and codex's Default collaboration mode",
          turnWW["approvalPolicy"] as? String == "never" && turnWW["serviceTier"] as? String == "priority"
            && (turnWW["collaborationMode"] as? [String: Any])?["mode"] as? String == "default",
          "\(turnWW)")
}
let hello = CodexAppServer.initializeParams(clientVersion: "9.9")
check("the handshake names SipAI and declares the experimental methods",
      ((hello["clientInfo"] as? [String: Any])?["name"] as? String) == "sipai"
        && ((hello["capabilities"] as? [String: Any])?["experimentalApi"] as? Bool) == true)
let started = CodexAppServer.threadStartParams(cwd: "/w")
check("a thread is started stating nothing — its answer is codex's own default for the folder",
      started.keys.sorted() == ["cwd"] && started["cwd"] as? String == "/w")
let askedDefault = CodexAppServer.permissions(fromOpened: json(
    #"{"approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":{"type":"readOnly","networkAccess":false}}"#))
check("codex's own default is read off that answer: the policy, who answers, the sandbox as a mode name",
      askedDefault?.approvalPolicy as? String == "on-request" && askedDefault?.approvalsReviewer == "user"
        && askedDefault?.sandbox == "read-only"
        && CodexAppServer.sandboxMode(forType: "workspaceWrite") == "workspace-write"
        && CodexAppServer.sandboxMode(forType: "dangerFullAccess") == "danger-full-access"
        && CodexAppServer.sandboxMode(forType: "somethingNew") == nil
        && CodexAppServer.permissions(fromOpened: json(#"{"sandbox":{"type":"readOnly"}}"#)) == nil
        && CodexAppServer.permissions(fromOpened: nil) == nil)
let granular = CodexAppServer.permissions(fromOpened: json(
    #"{"approvalPolicy":{"granular":{"sandbox_approval":true}},"sandbox":{"type":"workspaceWrite"}}"#))
check("…a policy codex states as an object is handed back as the object",
      (granular?.approvalPolicy as? [String: Any])?["granular"] != nil && granular?.approvalsReviewer == nil)
let resumed = CodexAppServer.threadResumeParams(threadId: "t1", cwd: "/w", permissions: askedDefault!)
check("a resumed thread states codex's own default, so it never runs on its last turn's permissions",
      resumed["threadId"] as? String == "t1" && resumed["excludeTurns"] as? Bool == true
        && resumed["approvalPolicy"] as? String == "on-request"
        && resumed["approvalsReviewer"] as? String == "user"
        && resumed["sandbox"] as? String == "read-only")
let profiled = CodexAppServer.permissions(fromOpened: json(
    #"{"approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":{"type":"workspaceWrite"},"activePermissionProfile":{"id":"mine","extends":null}}"#))
let profiledResume = CodexAppServer.threadResumeParams(threadId: "t1", cwd: "/w", permissions: profiled!)
check("…a permission profile in force is stated back as the profile, never as a legacy sandbox over it",
      profiled?.profile == "mine" && profiledResume["permissions"] as? String == "mine"
        && profiledResume["sandbox"] == nil && profiledResume["approvalPolicy"] as? String == "on-request"
        && askedDefault?.profile == nil && resumed["permissions"] == nil
        && CodexAppServer.permissions(fromOpened: json(
            #"{"approvalPolicy":"on-request","sandbox":{"type":"readOnly"},"activePermissionProfile":null}"#))?.profile == nil)
check("the thread asked for codex's defaults is deleted by its own id",
      CodexAppServer.threadDeleteParams(threadId: "t-ask").keys.sorted() == ["threadId"]
        && CodexAppServer.threadDeleteParams(threadId: "t-ask")["threadId"] as? String == "t-ask")
let plain = CodexAppServer.plainResumeParams(threadId: "t1", cwd: "/w")
check("…but the plan-mode hand-back resumes stating nothing of it",
      plain["approvalPolicy"] == nil && plain["sandbox"] == nil && plain["threadId"] as? String == "t1")

let settings = CodexAppServer.turnSettings(model: nil, effort: nil, folderModel: "gpt-a",
                                           folderEffort: nil,
                                           modelDefaultEffort: { $0 == "gpt-a" ? "medium" : nil },
                                           serviceTier: "default")
check("a Default chip is stated as codex resolves it: the folder's model, then the model's own effort",
      settings == CodexAppServer.TurnSettings(model: "gpt-a", effort: "medium", serviceTier: "default"))
check("…a pick wins, the folder's effort before the model's, and a blank pick is no pick",
      CodexAppServer.turnSettings(model: "gpt-b", effort: "high", folderModel: "gpt-a",
                                  folderEffort: "low", modelDefaultEffort: { _ in "medium" },
                                  serviceTier: nil)
        == CodexAppServer.TurnSettings(model: "gpt-b", effort: "high", serviceTier: nil)
        && CodexAppServer.turnSettings(model: " ", effort: "", folderModel: "gpt-a",
                                       folderEffort: "low", modelDefaultEffort: { _ in "medium" },
                                       serviceTier: nil).effort == "low")
// Codex's own answer for the folder — what it starts a thread with there —
// outranks SipAI's reading of the config for every value left on Default.
let answered = CodexAppServer.defaults(fromOpened: json(
    #"{"model":"gpt-proj","reasoningEffort":"high","serviceTier":"priority"}"#))
let answeredBare = CodexAppServer.defaults(fromOpened: json(#"{"model":"gpt-proj","reasoningEffort":null}"#))
check("codex's own defaults are read off its thread/start answer: model, effort (stated or not), speed",
      answered == CodexAppServer.Defaults(model: "gpt-proj", effort: "high", effortStated: true,
                                          serviceTier: "priority")
        && answeredBare == CodexAppServer.Defaults(model: "gpt-proj", effort: nil, effortStated: true)
        && CodexAppServer.defaults(fromOpened: json(#"{"model":"gpt-proj"}"#)).effortStated == false
        && CodexAppServer.defaults(fromOpened: nil) == CodexAppServer.Defaults())
func resolve(model: String? = nil, effort: String? = nil, tier: String? = nil,
             folderEffort: String? = "low", _ defaults: CodexAppServer.Defaults) -> CodexAppServer.TurnSettings {
    CodexAppServer.turnSettings(model: model, effort: effort, folderModel: "gpt-user",
                                folderEffort: folderEffort,
                                modelDefaultEffort: { $0 == "gpt-proj" ? "medium" : "minimal" },
                                serviceTier: tier, defaults: defaults)
}
check("a value left on Default is codex's answer, over SipAI's own reading: the project's model, the configured effort, the configured speed",
      resolve(answered) == CodexAppServer.TurnSettings(model: "gpt-proj", effort: "high", serviceTier: "priority"))
check("…a pick stands over it: the model, the effort, and a pinned speed — `default` included",
      resolve(model: "gpt-pick", effort: "xhigh", tier: "default", answered)
        == CodexAppServer.TurnSettings(model: "gpt-pick", effort: "xhigh", serviceTier: "default"))
check("…no effort configured (codex says so) is the resolved model's own default, not SipAI's stale reading",
      resolve(answeredBare).effort == "medium" && resolve(answeredBare).serviceTier == nil)
check("…and an answer that says nothing of the effort leaves SipAI's reading of the config in place",
      resolve(CodexAppServer.Defaults(model: "gpt-proj")).effort == "low"
        && resolve(CodexAppServer.Defaults()) == CodexAppServer.TurnSettings(model: "gpt-user", effort: "low",
                                                                                 serviceTier: nil))

// Codex's OWN default, out of its model/list answer (the shape 0.159.3
// gives): what a Default chip states when no config layer names a model.
let listAnswer = json(#"{"id":2,"result":{"data":[{"id":"gpt-h","model":"gpt-h","isDefault":true,"hidden":true,"defaultReasoningEffort":"low"},{"id":"gpt-d","model":"gpt-d","isDefault":true,"hidden":false,"defaultReasoningEffort":"low"},{"id":"gpt-e","model":"gpt-e","isDefault":false,"defaultReasoningEffort":"medium"}]}}"#)
let ownDefault = CodexCatalog.listedDefaults(fromAnswer: listAnswer)
check("codex's own default model and each model's default effort are read off its model/list answer",
      ownDefault.model == "gpt-d"
        && ownDefault.efforts == ["gpt-h": "low", "gpt-d": "low", "gpt-e": "medium"]
        && CodexCatalog.listedDefaults(fromAnswer: nil) == CodexListedDefaults()
        && CodexCatalog.listedDefaults(fromAnswer: json(#"{"id":2,"error":{"code":-32601,"message":"no"}}"#))
            == CodexListedDefaults())
check("…so a Default chip in a folder whose config names no model still states one, with its effort",
      CodexAppServer.turnSettings(model: nil, effort: nil, folderModel: ownDefault.model, folderEffort: nil,
                                  modelDefaultEffort: { ownDefault.efforts[$0] }, serviceTier: nil)
        == CodexAppServer.TurnSettings(model: "gpt-d", effort: "low", serviceTier: nil))
let agentTurn = CodexAppServer.turnStartParams(threadId: "t1", text: "hi", cwd: "/w", mode: .defaultMode,
                                               settings: settings, permissions: askedDefault!,
                                               threadModel: "gpt-z")
let agentMode = agentTurn["collaborationMode"] as? [String: Any]
check("a Default turn states default collaboration mode, its model, effort, speed and codex's own permissions",
      agentMode?["mode"] as? String == "default"
        && (agentMode?["settings"] as? [String: Any])?["model"] as? String == "gpt-a"
        && agentTurn["model"] as? String == "gpt-a" && agentTurn["effort"] as? String == "medium"
        && agentTurn["serviceTier"] as? String == "default"
        && agentTurn["approvalPolicy"] as? String == "on-request"
        && agentTurn["approvalsReviewer"] as? String == "user")
let planTurn = CodexAppServer.turnStartParams(threadId: "t1", text: "hi", cwd: "/w", mode: .plan,
                                              settings: CodexAppServer.TurnSettings(),
                                              permissions: askedDefault!,
                                              threadModel: "gpt-z")
check("a Plan turn states plan mode, on the thread's model when nothing names one, and CLEARS the tier",
      (planTurn["collaborationMode"] as? [String: Any])?["mode"] as? String == "plan"
        && ((planTurn["collaborationMode"] as? [String: Any])?["settings"] as? [String: Any])?["model"] as? String == "gpt-z"
        && planTurn["model"] == nil && planTurn["serviceTier"] is NSNull)

// Command approvals.
let listed: [Any] = ["accept", ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["touch"]]], "cancel"]
let commandChoices = CodexAppServer.commandChoices(available: listed, networkHost: false, agentName: agent)
check("a command card offers what codex listed, less the rule written for every session on the Mac",
      commandChoices.map(\.id) == ["accept", "cancel"]
        && commandChoices.map(\.label) == ["Yes, proceed", "No, and tell Codex what to do differently"])
check("…Return starts on Yes, and Esc takes codex's own refusal (which ends the turn)",
      CardChoiceLayout.initial(commandChoices) == "accept" && CardChoiceLayout.cancel(commandChoices) == "cancel")
let wider = CodexAppServer.commandChoices(
    available: ["accept", "acceptForSession", ["applyNetworkPolicyAmendment": ["network_policy_amendment": ["host": "x", "action": "allow"]]], "decline", "cancel"],
    networkHost: true, agentName: agent)
check("a network request uses codex's network words; a host rule for later is not offered",
      wider.map(\.label) == ["Yes, just this once", "Yes, and allow this host for this conversation",
                             "No, continue without running it", "No, and tell Codex what to do differently"]
        && CardChoiceLayout.cancel(wider) == "cancel")
let commandRequest: [String: Any] = [
    "kind": "command", "itemId": "call_1", "reason": "Make the probe file?",
    "command": "/bin/zsh -lc 'touch /tmp/x'", "cwd": "/w",
    "commandActions": [["type": "unknown", "command": "touch /tmp/x"]],
    "availableDecisions": listed,
]
let commandCard = CodexAppServer.commandCard(params: commandRequest, agentName: agent)
if case .permission(let content)? = commandCard?.presentation {
    check("the card asks in codex's words and shows the command as written, its folder and the model's reason",
          content.prompt == "Would you like to run the following command?"
            && content.preview == .command("touch /tmp/x", cwd: "/w", reason: "Make the probe file?")
            && content.notes.isEmpty)
} else {
    check("the card asks in codex's words and shows the command as written, its folder and the model's reason", false)
}
check("a command with no parsed action loses only codex's login-shell wrapper",
      CodexAppServer.displayCommand(#"/bin/zsh -lc 'echo '\''hi'\'' && ls'"#, actions: [])
        == "echo 'hi' && ls"
        && CodexAppServer.displayCommand("ls -la", actions: nil) == "ls -la")
// Codex's own answers for compound commands (0.159.3): ONE action, naming
// only the part that reads. The card is what "Yes, proceed" will run.
let teeActions: [Any] = [["type": "read", "command": "cat a.txt", "name": "a.txt", "path": "/w/a.txt"]]
let cdActions: [Any] = [["type": "read", "command": "cat notes.txt", "name": "notes.txt", "path": "/elsewhere/notes.txt"]]
check("a compound command is shown WHOLE — never the one part codex's summary of it names",
      CodexAppServer.displayCommand("/bin/zsh -lc 'cat a.txt | tee /elsewhere/b.txt'", actions: teeActions)
        == "cat a.txt | tee /elsewhere/b.txt"
        && CodexAppServer.displayCommand("/bin/zsh -lc 'cd /elsewhere && cat notes.txt'", actions: cdActions)
        == "cd /elsewhere && cat notes.txt")
if case .permission(let content)? = CodexAppServer.commandCard(
    params: commandRequest.merging(["command": "/bin/zsh -lc 'cat a.txt | tee /elsewhere/b.txt'",
                                    "commandActions": teeActions]) { $1 },
    agentName: agent)?.presentation {
    check("…on the card, and in what the bridge files the request under",
          content.preview == .command("cat a.txt | tee /elsewhere/b.txt", cwd: "/w", reason: "Make the probe file?"))
} else {
    check("…on the card, and in what the bridge files the request under", false)
}
check("…a wrapper in double quotes comes off only when nothing inside is escaped; otherwise the string stays as codex sent it",
      CodexAppServer.displayCommand(#"/bin/zsh -lc "bash -lc 'cd /elsewhere && touch nested.txt'""#, actions: nil)
        == "bash -lc 'cd /elsewhere && touch nested.txt'"
        && CodexAppServer.displayCommand(#"/bin/zsh -lc "echo \"it's\" > \$HOME/x""#, actions: nil)
        == #"/bin/zsh -lc "echo \"it's\" > \$HOME/x""#)
check("…and with no command named at all, every action codex lists is shown",
      CodexAppServer.displayCommand("", actions: [["type": "read", "command": "cat a"], ["type": "unknown", "command": "rm b"]])
        == "cat a\nrm b"
        && CodexAppServer.displayCommand("", actions: nil) == "")
if case .permission(let content)? = CodexAppServer.commandCard(
    params: commandRequest.merging(["kind": "writeStdin", "availableDecisions": ["accept", "acceptForSession", "cancel"]]) { $1 },
    agentName: agent)?.presentation {
    check("typing into a running command asks codex's own question, and a session answer says how long it lasts",
          content.prompt == "Would you like to send input to the existing terminal?"
            && content.notes.count == 1)
} else {
    check("typing into a running command asks codex's own question", false)
}
check("a request with nothing left to answer draws no card",
      CodexAppServer.commandCard(params: commandRequest.merging(["availableDecisions": [listed[1]]]) { $1 },
                                 agentName: agent) == nil)

// File changes.
let changeItem: [String: Any] = ["type": "fileChange", "id": "call_3", "changes": [
    ["path": "/o/new.txt", "kind": ["type": "add"], "diff": "hello\nworld\n"],
    ["path": "/o/a.txt", "kind": ["type": "update", "move_path": NSNull()], "diff": "@@ -1 +1 @@\n-one\n+two\n"],
    ["path": "/o/b.txt", "kind": ["type": "update", "move_path": "/o/c.txt"], "diff": ""],
    ["path": "/o/gone.txt", "kind": ["type": "delete"], "diff": "bye\n"],
]]
let changes = CodexAppServer.fileChanges(fromItem: changeItem)
check("a file change shows codex's edits: an added file's lines added, an update's diff, a move, a removal",
      changes.map(\.diff) == ["+hello\n+world", "@@ -1 +1 @@\n-one\n+two\n", "", "-bye"]
        && changes.map(\.path) == ["/o/new.txt", "/o/a.txt", "/o/b.txt → /o/c.txt", "/o/gone.txt"]
        && changes.map(\.kind) == ["add", "update", "update", "delete"])
let changeCard = CodexAppServer.fileChangeCard(params: ["itemId": "call_3", "reason": NSNull()],
                                               changes: changes, agentName: agent)
if case .permission(let content) = changeCard.presentation {
    check("…asked in codex's words with its three answers, and the note on how long \"these files\" lasts",
          content.prompt == "Would you like to make the following edits?"
            && content.choices.map(\.id) == ["accept", "acceptForSession", "cancel"]
            && content.choices[1].label == "Yes, and don't ask again for these files"
            && content.notes.count == 1 && content.preview == .fileChanges(changes, reason: nil))
} else {
    check("…asked in codex's words with its three answers", false)
}
check("only an answer codex was offered goes back as chosen; anything else ends the turn as codex's Esc does",
      jsonText(CodexAppServer.decisionReply(to: .chose("accept"), choices: commandChoices)) == #"{"decision":"accept"}"#
        && jsonText(CodexAppServer.decisionReply(to: .chose("acceptForSession"), choices: commandChoices)) == #"{"decision":"cancel"}"#
        && jsonText(CodexAppServer.decisionReply(to: .cancelled, choices: commandChoices)) == #"{"decision":"cancel"}"#
        && jsonText(CodexAppServer.decisionReply(to: .declined(.unreadable), choices: commandChoices)) == #"{"decision":"cancel"}"#)

// Questions.
let questionParams: [String: Any] = ["itemId": "call_9", "isBlocking": true, "questions": [
    ["id": "db", "header": "Database", "question": "Which database?", "isOther": true, "isSecret": false,
     "options": [["label": "Postgres (Recommended)", "description": "Server."], ["label": "SQLite", "description": "File."]]],
    ["id": "token", "header": "Token", "question": "Paste the token", "isOther": false, "isSecret": true,
     "options": NSNull()],
]]
let form = CodexAppServer.questionForm(params: questionParams)
check("a question set is read whole: ids, headers, codex's own Other, a secret free answer, no Skip-less form",
      form?.questions.map(\.id) == ["db", "token"]
        && form?.questions[0].allowsOther == true && form?.questions[0].options.count == 2
        && form?.questions[1].allowsOther == true && form?.questions[1].isSecret == true
        && form?.questions[1].options.isEmpty == true
        && form?.offersSkip == true && form?.offersChat == false)
check("a form the card cannot draw is not drawn (a question without an id, an option without a label)",
      CodexAppServer.questionForm(params: ["questions": [["question": "q", "options": []]]]) == nil
        && CodexAppServer.questionForm(params: ["questions": [["id": "a", "question": "q", "options": [["description": "x"]]]]]) == nil)
if let form {
    var other = AgentQuestionAnswer()
    other.otherPicked = true
    other.otherText = "s3cret"
    let reply = CodexAppServer.questionReply(
        to: .answered(["Which database?": AgentQuestionAnswer(labels: ["Postgres (Recommended)"]),
                       "Paste the token": other]), form: form)
    check("answers go back as codex's terminal spells them, filed by id",
          jsonText(reply) == #"{"answers":{"db":{"answers":["Postgres (Recommended)"]},"token":{"answers":["user_note: s3cret"]}}}"#,
          jsonText(reply))
    var ownWords = AgentQuestionAnswer()
    ownWords.otherPicked = true
    ownWords.otherText = "MySQL"
    let ownReply = CodexAppServer.questionReply(to: .answered(["Which database?": ownWords]), form: form)
    check("…the user's own words with codex's free-form label; a question left open is an empty list",
          jsonText(ownReply) == #"{"answers":{"db":{"answers":["None of the above","user_note: MySQL"]},"token":{"answers":[]}}}"#,
          jsonText(ownReply))
    var unticked = AgentQuestionAnswer()
    unticked.otherText = "s3cret"
    let untickedReply = CodexAppServer.questionReply(
        to: .answered(["Which database?": AgentQuestionAnswer(labels: ["SQLite"]),
                       "Paste the token": unticked]), form: form)
    check("…words typed and then un-ticked are not an answer, on a question with options or without",
          jsonText(untickedReply) == #"{"answers":{"db":{"answers":["SQLite"]},"token":{"answers":[]}}}"#
            && unticked.value(for: form.questions[1]) == nil,
          jsonText(untickedReply))
    check("Skip, Non-stop, an undrawable form and Stop answer nothing at all",
          [CardResolution.skipped, .declined(.nonStop), .declined(.unreadable), .cancelled].allSatisfy {
              jsonText(CodexAppServer.questionReply(to: $0, form: form)) == #"{"answers":{}}"#
          })
}

// Items as exec prints them, through exec's own parser.
let fallback = URL(fileURLWithPath: "/w")
func viaParser(_ method: String, _ item: [String: Any]) -> [String] {
    CodexAppServer.execEvents(method: method, params: ["item": item]).flatMap {
        CodexEventParser.parse(object: $0, fallbackCwd: fallback).events.map(signature)
    }
}
let commandItem: [String: Any] = ["type": "commandExecution", "id": "call_14",
                                  "command": "/bin/zsh -lc 'echo hello'", "cwd": "/w",
                                  "status": "completed", "aggregatedOutput": "hello\n", "exitCode": 0,
                                  "commandActions": []]
check("a command item is drawn as exec's: its row on start, the command without its login shell, then its output",
      viaParser("item/started", commandItem.merging(["status": "inProgress", "aggregatedOutput": NSNull(), "exitCode": NSNull()]) { $1 })
        == ["tool:command_execution:echo hello"]
        && viaParser("item/completed", commandItem) == ["output:hello"])
check("…a failed one as a failure",
      viaParser("item/completed", commandItem.merging(["status": "failed", "exitCode": 1, "aggregatedOutput": "nope\n"]) { $1 })
        == ["output:error:nope"])
check("an agent message is the agent's text; the user's own message echoed back is not drawn again",
      viaParser("item/completed", ["type": "agentMessage", "id": "m", "text": "Done."]) == ["assistant:Done."]
        && viaParser("item/completed", ["type": "userMessage", "id": "u", "content": []]).isEmpty
        && viaParser("item/started", ["type": "agentMessage", "id": "m", "text": ""]).isEmpty)
check("a file change, a web search and a compaction read as exec's do; a plan item is the driver's — a file change's files say what it did, with no \"completed\" under them",
      viaParser("item/completed", changeItem.merging(["status": "completed"]) { $1 }) == ["output:"]
        && viaParser("item/completed", ["type": "webSearch", "id": "w", "query": "swift actors"]) == ["output:swift actors"]
        && viaParser("item/completed", ["type": "contextCompaction", "id": "c"]) == ["compaction"]
        && viaParser("item/completed", ["type": "plan", "id": "p", "text": "x"]).isEmpty
        && CodexAppServer.planText(of: ["type": "plan", "id": "p", "text": "# P\n"]) == "# P\n")
// Compact view keeps a reasoning summary as a thought (the driver asks while
// it is on): the app-server's summary parts joined, through exec's parser.
func thoughts(_ item: [String: Any], asked: Bool) -> [String] {
    CodexAppServer.execEvents(method: "item/completed", params: ["item": item]).flatMap {
        CodexEventParser.parse(object: $0, fallbackCwd: fallback, includeThinking: asked).events
    }.compactMap { event -> String? in
        if case .thinking(let text) = event.kind { return text }
        return nil
    }
}
let reasoningItem: [String: Any] = ["type": "reasoning", "id": "r",
                                    "summary": ["**Weighing it**", "Then the next part."], "content": []]
check("a reasoning summary is a thought when asked, its parts joined; not asked, nothing; with no summary, nothing",
      thoughts(reasoningItem, asked: true) == ["**Weighing it**\n\nThen the next part."]
        && thoughts(reasoningItem, asked: false).isEmpty
        && viaParser("item/completed", reasoningItem).isEmpty
        && thoughts(["type": "reasoning", "id": "r", "summary": [], "content": []], asked: true).isEmpty)
// A command left running in a background terminal, in the app-server's
// shapes (0.164, measured): what the turn waits on once the model answers.
var terminals = CodexBackgroundCommands()
func feed(_ method: String, _ item: [String: Any]) {
    for object in CodexAppServer.execEvents(method: method, params: ["item": item]) {
        terminals.read(object: object)
    }
}
feed("item/started", ["type": "commandExecution", "id": "call_1", "status": "inProgress",
                      "source": "unifiedExecStartup", "processId": "86007",
                      "command": "/bin/zsh -lc 'sleep 20; date > done.txt'"])
feed("item/completed", ["type": "agentMessage", "id": "msg_1", "text": "Building…", "phase": "commentary"])
let beforeAnswer = terminals.awaited
feed("item/completed", ["type": "agentMessage", "id": "msg_2", "text": "Started it.", "phase": "final_answer"])
let afterAnswer = terminals.awaited.map(\.description)
feed("item/completed", ["type": "commandExecution", "id": "call_1", "status": "completed", "exitCode": 0,
                        "command": "/bin/zsh -lc 'sleep 20; date > done.txt'"])
check("a command running at the answer is what the turn waits on — named without codex's wrapper; words between steps are no answer",
      beforeAnswer.isEmpty && afterAnswer == ["sleep 20; date > done.txt"]
        && terminals.running.isEmpty && terminals.awaited.isEmpty,
      "before \(beforeAnswer), after \(afterAnswer), left \(terminals.running)")
check("an agent message keeps the phase codex gave it, for that rule",
      CodexAppServer.execItem(["type": "agentMessage", "id": "m", "text": "x", "phase": "final_answer"])?["phase"]
        as? String == "final_answer"
        && CodexAppServer.execItem(["type": "agentMessage", "id": "m", "text": "x"])?["phase"] == nil)
let retry = CodexAppServer.execEvents(method: "error", params: ["error": ["message": "Reconnecting... 2/5"], "willRetry": true])
    .map { CodexEventParser.parse(object: $0, fallbackCwd: fallback) }
check("codex's retries are a notice, never a row",
      retry.count == 1 && retry[0].events.isEmpty && retry[0].notice == "Reconnecting... 2/5")
check("a turn's tokens are the thread's total after it less the total before",
      CodexAppServer.turnUsage(totalBefore: ["inputTokens": 100, "outputTokens": 10],
                               totalAfter: ["inputTokens": 160, "outputTokens": 25]) == (60, 15)
        && CodexAppServer.turnUsage(totalBefore: nil, totalAfter: ["inputTokens": 7, "outputTokens": 1]) == (7, 1))

// A plan in the agent's message.
let message = "Here is the plan.\n\n<proposed_plan>\n# Ship it\n\n1. Build.\n</proposed_plan>\nThat's all."
let split = CodexSessionScanner.proposedPlanSplit(message)
check("a reopened plan is split as the live turn draws it: the words around it, then the plan, no tags",
      split?.outside == "Here is the plan.\n\nThat's all." && split?.plan == "# Ship it\n\n1. Build."
        && CodexSessionScanner.proposedPlanSplit("no plan here") == nil
        && CodexSessionScanner.proposedPlanSplit("<proposed_plan> unfinished") == nil)
let followUp = CodexAppServer.planFollowUpChoices(modeBeforePlan: nil)
check("\"Implement this plan?\" names the mode on each answer, as Claude Code's plan dialog does: Default, Workspace Write, staying is the refusal",
      followUp.map(\.label) == ["Yes, implement in Default", "Yes, implement in Workspace Write",
                                "No, stay in Plan mode"]
        && followUp.map(\.adoptsMode) == [AgentAskingMode.adoptDefault, "workspace-write", nil]
        && followUp.map { PlanContinue.split($0.id).answer } == [CodexAppServer.implementAnswer,
                                                                 CodexAppServer.implementAnswer, "stay"]
        && CardChoiceLayout.initial(followUp) == PlanContinue.id(answer: CodexAppServer.implementAnswer,
                                                                 mode: AgentAskingMode.adoptDefault)
        && CardChoiceLayout.cancel(followUp) == "stay"
        && CodexAppServer.implementPlanMessage == "Implement the plan.")
check("…and Full Access only for a session that was in it before it planned — Claude Code's rule for Bypass",
      CodexAppServer.planFollowUpChoices(modeBeforePlan: "full-access").map(\.adoptsMode)
            == [AgentAskingMode.adoptDefault, "workspace-write", "full-access", nil]
        && CodexAppServer.planFollowUpChoices(modeBeforePlan: "workspace-write").count == 3
        && !CodexAppServer.planFollowUpChoices(modeBeforePlan: nil).contains { $0.adoptsMode == "read-only" })

// A question codex asks WITHOUT stopping (`request_user_input_async`, the
// question tool codex hands its GPT-6 models in every mode): an agent
// message carrying the questions, and no request to answer — the answer
// is a message steered into the turn. The item's shape is the real
// app-server's (measured); the reply is codex's own clients'.
let asyncItem: [String: Any] = [
    "type": "agentMessage", "id": "call_q",
    "text": "Which database should the app use?\n- Postgres (Recommended)\n- SQLite\n\nAnything else I should know?",
    "phase": "final_answer", "memoryCitation": NSNull(), "delivery": "async",
    "questions": [["title": "Which database should the app use?", "options": ["Postgres (Recommended)", "SQLite"]],
                  ["title": "Anything else I should know?", "options": NSNull()]]]
let asyncForm = CodexAppServer.asyncQuestionForm(item: asyncItem)
check("a question codex asks without stopping is a card: each title, its options, the user's own words always, filed by codex's own question ids",
      asyncForm?.questions.map(\.text) == ["Which database should the app use?", "Anything else I should know?"]
        && asyncForm?.questions.map(\.id) == [#"["request_user_input_async","call_q",0]"#,
                                               #"["request_user_input_async","call_q",1]"#]
        && asyncForm?.questions[0].options.map(\.label) == ["Postgres (Recommended)", "SQLite"]
        && asyncForm?.questions[1].options.isEmpty == true
        && asyncForm?.questions.allSatisfy { $0.allowsOther && !$0.multiSelect && !$0.isSecret } == true
        && asyncForm?.offersSkip == true && asyncForm?.offersChat == false,
      "\(String(describing: asyncForm?.questions))")
check("…a message that asks nothing, or asks what the card cannot draw, is no card",
      CodexAppServer.asyncQuestionForm(item: ["type": "agentMessage", "id": "m", "text": "Done.",
                                              "delivery": NSNull(), "questions": NSNull()]) == nil
        && CodexAppServer.asyncQuestionForm(item: asyncItem.merging(["questions": [Any]()]) { $1 }) == nil
        && CodexAppServer.asyncQuestionForm(item: asyncItem.merging(["id": ""]) { $1 }) == nil
        && CodexAppServer.asyncQuestionForm(item: asyncItem.merging(["type": "userMessage"]) { $1 }) == nil
        && CodexAppServer.asyncQuestionForm(item: asyncItem.merging(["questions": [["title": "  "]]]) { $1 }) == nil
        && CodexAppServer.asyncQuestionForm(
            item: asyncItem.merging(["questions": [["title": "Q?", "options": ["A", "A"]]]]) { $1 }) == nil)
if let asyncForm {
    var own = AgentQuestionAnswer()
    own.otherPicked = true
    own.otherText = "Use \"WAL\" mode/both"
    let reply = CodexAppServer.asyncReplyText(form: asyncForm, answers: [
        "Which database should the app use?": AgentQuestionAnswer(labels: ["SQLite"]),
        "Anything else I should know?": own])
    let expected = "<send_user_message_question_reply>\n"
        + #"[{"answer":"SQLite","question":"Which database should the app use?","questionItemId":"[\"request_user_input_async\",\"call_q\",0]"},"#
        + #"{"answer":"Use \"WAL\" mode/both","question":"Anything else I should know?","questionItemId":"[\"request_user_input_async\",\"call_q\",1]"}]"#
        + "\n</send_user_message_question_reply>"
    check("the answers go back as ONE reply in codex's own envelope, each filed by its question's id, byte for byte",
          reply == expected, reply ?? "nil")
    check("…a question left open is left out; with nothing answered nothing is sent",
          CodexAppServer.asyncReplyText(form: asyncForm, answers: [
              "Which database should the app use?": AgentQuestionAnswer(labels: ["SQLite"])])
              == "<send_user_message_question_reply>\n"
                + #"[{"answer":"SQLite","question":"Which database should the app use?","questionItemId":"[\"request_user_input_async\",\"call_q\",0]"}]"#
                + "\n</send_user_message_question_reply>"
            && CodexAppServer.asyncReplyText(form: asyncForm, answers: [:]) == nil
            && CodexAppServer.asyncReplyText(form: asyncForm, answers: [
                "Anything else I should know?": AgentQuestionAnswer(otherText: "unticked")]) == nil)
    let long = String(repeating: "é", count: 300) + "\nsecond line"
    if let longForm = CodexAppServer.asyncQuestionForm(
        item: asyncItem.merging(["questions": [["title": long, "options": ["A", "B"]]]]) { $1 }),
       let longReply = CodexAppServer.asyncReplyText(form: longForm, answers: [long: AgentQuestionAnswer(labels: ["B"])]),
       let parsed = CodexSessionScanner.questionReplies(in: longReply) {
        check("…the question it repeats is codex's own bound: one line, at most 512 bytes, never a split character",
              parsed.first?.question == String(repeating: "é", count: 256) && parsed.first?.answer == "B",
              parsed.first?.question.count.description ?? "nil")
    } else {
        check("…the question it repeats is codex's own bound", false)
    }
}
let steer = CodexAppServer.steerParams(threadId: "t1", turnId: "u1", text: "R")
check("the answer is steered into the turn that asked, by its id — codex refuses it once that turn is over",
      steer["threadId"] as? String == "t1" && steer["expectedTurnId"] as? String == "u1"
        && jsonText(steer["input"] ?? NSNull()) == #"[{"text":"R","text_elements":[],"type":"text"}]"#)

let tuiReply = "<send_user_message_question_reply>\n"
    + #"[{"answer":"Customers","question":"Who should receive the launch update?","questionItemId":"[\"request_user_input_async\",\"audience-question\",0]"}]"#
    + "\n</send_user_message_question_reply>"
check("a reply is read as codex's own terminal reads it — a list or one bare object, an IDE context prefix allowed",
      CodexSessionScanner.questionReplies(in: tuiReply)?.map(\.answer) == ["Customers"]
        && CodexSessionScanner.questionReplies(
            in: " \n<send_user_message_question_reply>\n{\"questionItemId\":\"x\",\"question\":\"Which environment?\",\"answer\":\"Staging\",\"extra\":true}\n</send_user_message_question_reply>\n ")?
            .map(\.question) == ["Which environment?"]
        && CodexSessionScanner.questionReplies(
            in: "# Context from my IDE setup:\n\n## Open tabs:\n- a.swift\n\n## My request for Codex:\n" + tuiReply)?.count == 1)
check("…and nothing else is: a quote, an empty or broken list, text before or after it",
      ["> Which environment?\n\nStaging",
       "<send_user_message_question_reply>[]</send_user_message_question_reply>",
       "<send_user_message_question_reply>[{\"questionItemId\":\"one\",\"question\":\"First?\",\"answer\":\"Yes\"},null]</send_user_message_question_reply>",
       "Quoted: " + tuiReply, tuiReply + " trailing text", "plain words"]
        .allSatisfy { CodexSessionScanner.questionReplies(in: $0) == nil })
check("a reply is drawn as codex's terminal draws it: each question quoted on one line, its answer under it",
      CodexSessionScanner.questionReplyDisplay(of: tuiReply) == "> Who should receive the launch update?\n\nCustomers"
        && CodexSessionScanner.questionReplyDisplay(
            of: "<send_user_message_question_reply>[{\"questionItemId\":\"one\",\"question\":\"First?\\nmore\",\"answer\":\"Yes\"},{\"questionItemId\":\"two\",\"question\":\"Second?\",\"answer\":\"No\"}]</send_user_message_question_reply>")
            == "> First? more\n\nYes\n\n> Second?\n\nNo"
        && CodexSessionScanner.questionReplyDisplay(of: "plain words") == nil)

// Reopened: the rollout records the question only as an `item_completed`
// agent message (its call has nothing to summarise), and the answer as a
// user message holding the envelope — both shapes as written by the real
// codex.
let asyncRolloutLines: [Any] = [
    ["type": "event_msg", "payload": ["type": "task_started", "turn_id": "turn-1"]],
    ["type": "response_item", "payload": ["type": "message", "role": "user",
                                          "content": [["type": "input_text", "text": "SIPAI go"]]]],
    ["type": "event_msg", "payload": ["type": "item_completed", "turn_id": "turn-1",
                                      "item": ["type": "UserMessage", "id": "u0",
                                               "content": [["type": "text", "text": "SIPAI go"]]]]],
    ["type": "response_item", "payload": ["type": "function_call", "name": "request_user_input_async",
                                          "call_id": "call_q",
                                          "arguments": #"{"questions": [{"title": "Which database should the app use?", "options": ["Postgres (Recommended)", "SQLite"]}]}"#]],
    ["type": "event_msg", "payload": ["type": "item_completed", "turn_id": "turn-1",
                                      "item": ["type": "AgentMessage", "id": "call_q",
                                               "content": [["type": "Text", "text": "Which database should the app use?\n- Postgres (Recommended)\n- SQLite"]],
                                               "phase": "final_answer", "delivery": "async",
                                               "questions": [["title": "Which database should the app use?",
                                                              "options": ["Postgres (Recommended)", "SQLite"]]]]]],
    ["type": "response_item", "payload": ["type": "function_call_output", "call_id": "call_q",
                                          "output": #"{"accepted":true}"#]],
    ["type": "response_item", "payload": ["type": "message", "role": "user",
                                          "content": [["type": "input_text", "text": tuiReply]]]],
    ["type": "event_msg", "payload": ["type": "item_completed", "turn_id": "turn-1",
                                      "item": ["type": "UserMessage", "id": "u1",
                                               "content": [["type": "text", "text": tuiReply]]]]],
    ["type": "event_msg", "payload": ["type": "item_completed", "turn_id": "turn-1",
                                      "item": ["type": "AgentMessage", "id": "msg_2",
                                               "content": [["type": "Text", "text": "GOT THE REPLY"]]]]],
    ["type": "response_item", "payload": ["type": "message", "role": "assistant",
                                          "content": [["type": "output_text", "text": "GOT THE REPLY"]]]],
    ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "turn-1"]],
]
let asyncRolloutURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("cxas-asyncq-\(UUID().uuidString).jsonl")
try? asyncRolloutLines.map(jsonText).joined(separator: "\n").appending("\n")
    .write(to: asyncRolloutURL, atomically: true, encoding: .utf8)
let reopenedAsync = CodexSessionScanner.readHistory(of: asyncRolloutURL)
func historySignature(_ item: AgentSessionHistoryItem) -> String {
    switch item.kind {
    case .userText(let t): return (item.sentIntoTurn ? "reply:" : "user:") + t
    case .assistantText(let t): return "assistant:" + t
    case .toolUse(_, let name, _): return "tool:" + name
    default: return "other"
    }
}
check("reopened, the question reads as it did live, and the answer as the user's reply — never the envelope",
      reopenedAsync.map(historySignature) == [
          "user:SIPAI go",
          "assistant:Which database should the app use?\n- Postgres (Recommended)\n- SQLite",
          "reply:> Who should receive the launch update?\n\nCustomers",
          "assistant:GOT THE REPLY"],
      "\(reopenedAsync.map(historySignature))")
check("…the reply belongs to the turn that asked, and a turn another process runs is drawn the same, flag and all",
      reopenedAsync.first { $0.sentIntoTurn }?.recordUuid == "turn-1"
        && reopenedAsync.compactMap(AgentSessionTailer.liveEvent(for:)).map(signature).count == 4
        && reopenedAsync.compactMap(AgentSessionTailer.liveEvent(for:)).filter(\.sentIntoTurn).count == 1)
try? FileManager.default.removeItem(at: asyncRolloutURL)

// Plan mode is the thread's.
let planContext = ##"{"timestamp":"t","type":"turn_context","payload":{"cwd":"/w","collaboration_mode":{"mode":"plan","settings":{"model":"gpt-a","reasoning_effort":null,"developer_instructions":"# Plan Mode"}}}}"##
let defaultApplied = #"{"timestamp":"t","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-a","collaboration_mode":{"mode":"default","settings":{"model":"gpt-a"}}}}}"#
check("the newest record that states the thread's mode decides it, either kind, with its model",
      CodexAppServer.collaborationMode(in: planContext).map { "\($0.mode)/\($0.model ?? "")" } == "plan/gpt-a"
        && CodexAppServer.collaborationMode(in: planContext + "\n" + defaultApplied)?.mode == "default"
        && CodexAppServer.collaborationMode(in: defaultApplied + "\n" + planContext)?.mode == "plan"
        && CodexAppServer.collaborationMode(in: #"{"type":"event_msg","payload":{"type":"task_started"}}"#) == nil)
check("…and a turn record from a codex with no modes is default, so an old session is not read further back",
      CodexAppServer.collaborationMode(in: planContext + "\n" + #"{"type":"turn_context","payload":{"cwd":"/w","model":"gpt-old"}}"#)
        .map { "\($0.mode)/\($0.model ?? "")" } == "default/gpt-old")
let leave = CodexAppServer.leavePlanModeParams(threadId: "t1", model: "gpt-a")
check("leaving plan mode is codex's own settings update to Default, on the thread's model",
      leave["threadId"] as? String == "t1"
        && (leave["collaborationMode"] as? [String: Any])?["mode"] as? String == "default"
        && (((leave["collaborationMode"] as? [String: Any])?["settings"] as? [String: Any])?["model"] as? String) == "gpt-a")

// The gate.
check("codex's front end is held until its version is read, refused below the floor",
      AgentAskingMode.frontEndAvailability(agentKey: "codex", kimiVersion: nil) == .pending
        && AgentAskingMode.frontEndAvailability(agentKey: "codex", kimiVersion: nil,
                                                codexVersion: "0.159.2") == .unavailable
        && AgentAskingMode.frontEndAvailability(agentKey: "codex", kimiVersion: nil,
                                                codexVersion: AgentAskingMode.codexVersionFloor) == .offered)
check("…and Plan also waits for codex's own list, offered only where it names a plan mode",
      AgentAskingMode.availability(of: AgentAskingMode.codexPlan, agentKey: "codex", kimiVersion: nil,
                                   codexVersion: "0.160.0") == .pending
        && AgentAskingMode.availability(of: AgentAskingMode.codexPlan, agentKey: "codex", kimiVersion: nil,
                                        codexVersion: "0.160.0", codexModes: ["plan", "default"]) == .offered
        && AgentAskingMode.availability(of: AgentAskingMode.codexPlan, agentKey: "codex", kimiVersion: nil,
                                        codexVersion: "0.160.0", codexModes: ["default"]) == .unavailable)
check("the asking rows offered: Plan once codex lists it — codex's Default preset is the Default row; nil only when nothing is read",
      AgentAskingMode.offered(agentKey: "codex", kimiVersion: nil) == nil
        && AgentAskingMode.offered(agentKey: "codex", kimiVersion: nil, codexVersion: "0.160.0") == nil
        && AgentAskingMode.offered(agentKey: "codex", kimiVersion: nil, codexVersion: "0.160.0",
                                   codexModes: ["plan"]) == AgentAskingMode.codex
        && AgentAskingMode.codex == [AgentAskingMode.codexPlan]
        && AgentAskingMode.offered(agentKey: "kimi", kimiVersion: "2.1.1") == AgentAskingMode.kimi)
check("a scheduled run runs in its task's mode: a codex Plan task stays Plan, a Default task Default",
      AgentLaunchOptions.scheduledRun(agent: "codex", mode: AgentAskingMode.codexPlan, model: nil, effort: nil,
                                      fastMode: false, serviceTier: nil).permissionMode == AgentAskingMode.codexPlan
        && AgentLaunchOptions.scheduledRun(agent: "codex", mode: nil, model: nil, effort: nil,
                                           fastMode: false, serviceTier: nil).permissionMode == nil)

// MARK: - 3. The wiring, read off the sources (section 2 runs last)

print("\n3. The wiring")

func read(_ rel: String) -> String {
    (try? String(contentsOfFile: srcRoot + "/" + rel, encoding: .utf8)) ?? ""
}
func body(_ source: String, from start: String) -> String {
    guard let r = source.range(of: start) else { return "" }
    var depth = 0, seenOpen = false
    var end = source.endIndex
    for i in source[r.lowerBound...].indices {
        let c = source[i]
        if c == "{" { depth += 1; seenOpen = true }
        if c == "}" { depth -= 1 }
        if seenOpen && depth == 0 { end = source.index(after: i); break }
    }
    return String(source[r.lowerBound..<end])
}
let runnerSource = read("SipAI/Models/AgentRunner.swift")
let viewSource = read("SipAI/Views/Chat/AgentSessionView.swift")
let composerSource = read("SipAI/Views/Chat/AgentComposer.swift")
let cardsSource = read("SipAI/Views/Chat/AskingCards.swift")
let updatesSource = read("SipAI/Models/AgentCLIUpdates.swift")
let optionsSource = read("SipAI/Models/AgentLaunchOptions.swift")
let parserSource = read("SipAI/Models/CodexEventParsing.swift")
let sessionsSource = read("SipAI/Models/CodexSessions.swift")
let catalogSource = read("SipAI/Resources/Localizable.xcstrings")

let makeTurn = body(runnerSource, from: "private func makeRPCTurn(")
check("an asking codex send is driven by CodexAppServerTurn, stating the resolved model, effort and the send's speed — resolved against codex's own answer for the folder",
      makeTurn.contains("case .codexAppServer:") && makeTurn.contains("CodexAppServerTurn(")
        && makeTurn.contains("CodexAppServer.turnSettings(")
        && makeTurn.contains("let tier = options.codexServiceTierOverride")
        && makeTurn.contains("serviceTier: tier, defaults: defaults)")
        && read("SipAI/Models/CodexAppServerTurn.swift")
            .contains("let settings = self.settings(CodexAppServer.defaults(fromOpened: folderAnswer))"))
let runOnceWait = body(runnerSource, from: "private func runOnce(")
check("FX. a send in a fixed codex mode waits, bounded, for codex's version as Default does — and one still unread runs on codex exec, which enforces the same mode, never the Default error",
      runOnceWait.contains(#"let fixedCodexMode = agentKey == "codex" && AgentAskingMode.isCodexFixed(options.permissionMode)"#)
        && runOnceWait.contains("guard verdict != .pending || fixedCodexMode else {"))
check("FX. a turn's Non-stop is the chip's only where the turn can ask: a question codex asks without stopping in a fixed mode is shown, whatever pick the greyed switch keeps",
      body(runnerSource, from: "    private func startTurn(")
        .contains("nonStop = options.nonStop && AgentAskingMode.asksQuestions("))
check("FX. the driver states a fixed mode's own permissions, on a new thread and a resumed one, and asks codex only for the folder's defaults",
      read("SipAI/Models/CodexAppServerTurn.swift").contains("CodexAppServer.threadStartParams(cwd: cwd, stating: fixed,")
        && read("SipAI/Models/CodexAppServerTurn.swift")
            .contains("permissions = fixed ?? CodexAppServer.permissions(fromOpened: asked)"))
// The user's pick on the chip, where the page saves it (`saveUserPick`).
let saveUserPick = body(read("SipAI/Views/Chat/AgentSessionView.swift"),
                        from: "private func saveUserPick(")
check("\"Implement this plan?\" offers Full Access by the mode the CHIP left for Plan, not only by the last send's",
      runnerSource.contains("func noteCodexChipLeftForPlan(previous: String?)")
        && saveUserPick.contains("currentRunner?.noteCodexChipLeftForPlan(")
        && saveUserPick.contains("previous: old.chatOnly ? nil : old.permissionMode)"))
let runOnceSource = body(runnerSource, from: "private func runOnce(")
if let pick = runOnceSource.range(of: "let driver = AgentTurnDriver.pick("),
   let leaveCall = runOnceSource.range(of: "await leaveCodexPlanModeIfLeftOn(sessionId: id, binary: binary)"),
   let web = runOnceSource.range(of: "if driver == .kimiWeb {") {
    check("a headless codex turn on a thread left in plan mode puts it back first",
          pick.upperBound <= leaveCall.lowerBound && leaveCall.upperBound <= web.lowerBound
            && runOnceSource.contains(#"if agentKey == "codex", driver == .codexExec"#))
} else {
    check("a headless codex turn on a thread left in plan mode puts it back first", false)
}
let leaveSource = body(runnerSource, from: "private func leaveCodexPlanModeIfLeftOn(")
let sideSource = body(runnerSource, from: "private func runSideConversation(")
check("…through codex's own settings update, read off the rollout, drained by the one loop",
      leaveSource.contains("CodexAppServer.planModeLeftOn(") && leaveSource.contains("CodexAppServerTurn.leavePlanMode(")
        && leaveSource.contains("runSideConversation(") && sideSource.contains("Self.makeDrainingLineSource("))
let driverSource = read("SipAI/Models/CodexAppServerTurn.swift")
let runBody = body(driverSource, from: "    func run(peer: JSONRPCLinePeer, host: AgentRPCHost) async")
if let request = runBody.range(of: "\"turn/start\""),
   let adopt = runBody.range(of: "adoptCreatedThread(host: host)") {
    check("a new thread is adopted only AFTER turn/start is answered — and on turn/started, whichever is first",
          request.upperBound <= adopt.lowerBound && !runBody.contains("host.adoptSession(")
            && body(driverSource, from: "    private func notification(").contains("adoptCreatedThread(host: host)"))
} else {
    check("a new thread is adopted only after turn/start is answered", false)
}
let rpcTurnSource = body(runnerSource, from: "private func runRPCTurn(")
check("the runner counts a turn's protocol as done only while the conversation is open — a child gone under it is reported",
      rpcTurnSource.contains("if !peer.isClosed { self?.noteRPCTurnCompleted(token: token) }")
        && !rpcTurnSource.contains("if exitCode == 0 { return nil }"))
check("codex's driver tells the runner each time it ends a turn on a failure row — a failed turn in its row's own words, a refusal, an answer it cannot read",
      body(driverSource, from: "private func endOnFailure(").contains("host.noteTurnFailed(message)")
        && body(driverSource, from: "private func turnCompleted(").contains("host.noteTurnFailed(words)")
        && driverSource.components(separatedBy: "endOnFailure(AgentAskingMode.unreadableAnswerMessage").count - 1 == 3
        && rpcTurnSource.contains("driverFailure: rpcTurnFailure"))
check("the host offers a finished plan; any send takes the offer down",
      runnerSource.contains("func offerPlanFollowUp(_ plan: String)")
        && body(runnerSource, from: "    private func startTurn(").contains("dismissPlanFollowUp()"))
check("the transcript draws \"Implement this plan?\" after the cards a turn waits on, on the shared keyboard",
      viewSource.contains("CodexPlanFollowUpCard(") && viewSource.contains(".onChange(of: activeCardId, initial: true)")
        && viewSource.contains("cardKeys.setActiveCard(newest)")
        && body(viewSource, from: "private var showsPlanFollowUp: Bool").contains("approvalsForRunner.isEmpty"))
let implement = body(viewSource, from: "private func implementProposedPlan(mode spelling: String)")
if let adopt = implement.range(of: "ChatOnlyMode.select(target, into: &next)"),
   let apply = implement.range(of: "applySeededOptions(next)"),
   let send = implement.range(of: "runner.send(text: CodexAppServer.implementPlanMessage") {
    check("…and carrying it out moves the chip to the mode the answer names, for this session — from Chat only too — before codex's words are sent",
          adopt.upperBound <= apply.lowerBound && apply.upperBound <= send.lowerBound
            && implement.contains("spelling == AgentAskingMode.adoptDefault ? nil : spelling")
            && cardsSource.contains("struct CodexPlanFollowUpCard: View")
            && viewSource.contains("modeBeforePlan: runner.codexModeBeforePlan)"))
} else {
    check("…and carrying it out moves the chip to the mode named before codex's words are sent", false)
}
check("…the offer is taken down only by a message that went: nothing dismisses it ahead of the guards, and the named mode's own hold is asked",
      !implement.contains("dismissPlanFollowUp()")
        && implement.contains("AskingModeGate.hold(agentKey: sessionAgentKey, mode: target"))
check("…the runner remembers the mode a codex session was sent in before it planned",
      body(runnerSource, from: "    private func startTurn(").contains("codexModeBeforePlan = options.permissionMode ?? AgentAskingMode.adoptDefault"))
check("a turn on Default or Plan asks codex for its own default permissions and states them — a resumed thread never runs on its last turn's",
      runBody.contains("permissions = fixed ?? CodexAppServer.permissions(fromOpened: asked)")
        && runBody.contains("CodexAppServer.threadResumeParams(threadId: existing, cwd: cwd,")
        && runBody.contains("permissions: permissions, threadModel: threadModel)"))
check("…another process mid-turn on the thread holds the answer, hides the card, and takes a stale offer down",
      implement.contains("!runner.externalInProgress")
        && body(viewSource, from: "private var showsPlanFollowUp: Bool").contains("!runner.externalInProgress")
        && body(runnerSource, from: "private func handleExternalProgressFlip(").contains("dismissPlanFollowUp()"))
check("…and only a Plan turn's plan is offered",
      body(driverSource, from: "private func turnCompleted(").contains("if mode == .plan, (turn[\"status\"] as? String) == \"completed\", let plan = proposedPlan"))
check("a Default chip's model falls back to codex's own default for the TURN alone — the chip's own reading is the config's",
      runnerSource.contains("folderModel: catalog.turnDefaultModel(forFolder: folder)")
        && optionsSource.contains("defaultModel(forFolder: folder) ?? listedDefaults.model")
        && optionsSource.contains("listed: listedDefaults.efforts[slug],")
        && body(optionsSource, from: "func refreshFromCodex(force: Bool)").contains("Self.listedDefaults(fromAnswer: answer)")
        && optionsSource.contains("listedTiers = [:]\n        listedDefaults = CodexListedDefaults()"))
check("a file change's edits are kept whichever thread announced it — a subagent's approval names only the item",
      { () -> Bool in
          let n = body(driverSource, from: "private func notification(method: String")
          guard let keep = n.range(of: "fileChanges[id] = CodexAppServer.fileChanges(fromItem: item)"),
                let filter = n.range(of: "named != threadId { return }") else { return false }
          return keep.upperBound <= filter.lowerBound
      }())
check("a step codex refuses with no words still ends the turn on a row",
      body(driverSource, from: "    func run(peer: JSONRPCLinePeer, host: AgentRPCHost) async")
        .contains("AgentAskingMode.wordlessFailureMessage(agentName: agentName) : words"))
check("the stall notice does not fire over a turn that has asked the user something",
      body(runnerSource, from: "private func armStallNotice()").contains("self.userWait == TurnPause(),"))
check("the composer offers codex's modes from its version and its own list, and asks for the list",
      composerSource.contains(#"codexVersion: AgentCLIUpdateMonitor.shared.installed["codex"]?.text"#)
        && composerSource.contains("codexModes: CodexCatalog.shared.collaborationModes")
        && composerSource.contains("codexCaps.ensureCollaborationModesLoaded()")
        && composerSource.contains("func ensureCollaborationModesLoaded()"))
check("codex's list is asked with the experimental handshake, and nowhere else is",
      updatesSource.contains(#""method":"collaborationMode/list""#)
        && updatesSource.contains(#""capabilities":{"experimentalApi":true}"#)
        && body(updatesSource, from: "enum CodexCollaborationModes").contains("experimental: true"))
check("…a refusal of the list is an answer — no Plan mode, said so — where no answer leaves it unknown; only a list is kept as the binary's",
      body(updatesSource, from: "enum CodexCollaborationModes").contains("return refused(answer) ? [] : nil")
        && body(updatesSource, from: "enum CodexCollaborationModes").contains(#"answer?["error"] is [String: Any]"#)
        && body(composerSource, from: "func ensureCollaborationModesLoaded()").contains("if !answer.listed { self.collaborationModesKey = nil }")
        && AgentAskingMode.availability(of: AgentAskingMode.codexPlan, agentKey: "codex", kimiVersion: nil,
                                        codexVersion: AgentAskingMode.codexVersionFloor, codexModes: []) == .unavailable
        && AgentAskingMode.availability(of: AgentAskingMode.codexPlan, agentKey: "codex", kimiVersion: nil,
                                        codexVersion: AgentAskingMode.codexVersionFloor, codexModes: nil) == .pending)
check("exec's parser takes an already-decoded event, and its line path goes through it",
      parserSource.contains("static func parse(object obj: [String: Any]")
        && body(parserSource, from: "static func parse(line: String").contains("return parse(object: obj"))
check("a reopened rollout splits a proposed plan out of the agent's message",
      body(sessionsSource, from: "struct RolloutDecoder").contains("CodexSessionScanner.proposedPlanSplit(joined)"))
let notificationSource = body(driverSource, from: "    private func notification(")
check("a question codex asks without stopping goes on a card from its agent message — this turn's only, once each",
      notificationSource.contains("CodexAppServer.asyncQuestionForm(item: item)")
        && notificationSource.contains("askedAsync.insert(")
        && body(driverSource, from: "private func askWithoutStopping(").contains("turnWaits: false"))
check("…its answer is steered into the turn that asked, and its card goes when that turn is over",
      body(driverSource, from: "private func askWithoutStopping(").contains("\"turn/steer\"")
        && body(driverSource, from: "private func turnCompleted(").contains("withdrawAsyncCards(host: host)"))
check("…the reply codex echoes is drawn as the user's reply, the prompt's own echo is not",
      notificationSource.contains("CodexSessionScanner.questionReplyDisplay(of:")
        && notificationSource.contains("sentIntoTurn: true"))
let bridgeSource = read("SipAI/Models/MCPBridge.swift")
check("a card the turn does not wait on never pauses the turn clock",
      body(runnerSource, from: "    func syncUserWait()").contains("$0.turnWaits && bridge.belongs(")
        && body(runnerSource, from: "        func present(_ card: AgentCardRequest) -> String?").contains("turnWaits: card.turnWaits")
        && bridgeSource.contains("let turnWaits: Bool"))
// `userRow`'s signature holds a closure default, so it is read up to the
// function after it rather than by its braces.
let userRowSource: String = {
    guard let start = viewSource.range(of: "    private func userRow(rowId: UUID"),
          let end = viewSource.range(of: "private func newerIdenticalLiveRows(",
                                     range: start.upperBound..<viewSource.endIndex)
    else { return "" }
    return String(viewSource[start.lowerBound..<end.lowerBound])
}()
check("a reply has no branch pencil, opens no turn, and carries no skill load",
      userRowSource.contains("!isSystemNotice && !sentIntoTurn")
        && viewSource.contains("sentIntoTurn: item.sentIntoTurn,")
        && viewSource.contains("sentIntoTurn: event.sentIntoTurn,")
        && body(runnerSource, from: "    private static func opensTurn(").contains("!event.sentIntoTurn")
        && body(runnerSource, from: "    private func retractSkillLoads(").contains("Self.isMessageRow")
        && body(runnerSource, from: "    private static func isMessageRow(").contains("!event.sentIntoTurn"))
check("…the tailer hands the flag through, and the reader sets it on the envelope alone",
      body(read("SipAI/Models/AgentSessionTailer.swift"), from: "static func liveEvent(for item:")
            .contains("sentIntoTurn: item.sentIntoTurn")
        && body(sessionsSource, from: "struct RolloutDecoder").contains("CodexSessionScanner.questionReplyDisplay(of: joined)"))
check("the card says the turn goes on while it waits",
      body(read("SipAI/Views/Chat/AgentQuestionCard.swift"), from: "    private var header: some View")
        .contains("!request.turnWaits"))
// Settings → Help says it, since nothing on screen does: the same question
// is a card wherever codex runs through its app-server and plain text in
// Chat only.
let helpSource = read("SipAI/Views/Settings/SettingsView.swift")
let helpQuestionKey = "Why does %@ sometimes ask a question as plain text instead of on a card?"
let helpAnswerKey = "Some of %@'s models ask questions without stopping: %@ keeps working while the question waits, and if no answer comes it decides by itself — it carries on with an assumption it tells you about, or ends its turn with the question still open. The question appears on a card. Answer while %@ is still working and it reads your answer in the same turn; the timer keeps running, because %@ hasn't stopped. When the turn ends, the card goes away, as it does in %@'s own app; whatever you had started to answer moves into the message box under its question, ready to send as your next message. In Chat only, SipAI runs %@ as a one-shot command that can't receive anything until it finishes, so the question appears as %@'s own message, its options as a list, and you answer in your next message. %@'s questions, and the questions %@ asks in Plan that pause the turn, are different: they wait until you answer. With Non-stop on, no card is shown."
if let chatOnly = helpSource.range(of: "FAQ(id: HelpTopic.chatOnly.faqId,"),
   let entry = helpSource.range(of: "FAQ(id: 15,"),
   let next = helpSource.range(of: "FAQ(id: 5,") {
    check("Help answers it, in its own entry after Chat only, naming each agent by its label",
          chatOnly.upperBound <= entry.lowerBound && entry.upperBound <= next.lowerBound
            && helpSource.contains("Why does \\(codexLabel) sometimes ask a question as plain text instead of on a card?")
            && helpSource.contains("\\(claudeLabel)'s questions, and the questions \\(codexLabel) asks in Plan that pause the turn"))
} else {
    check("Help answers it, in its own entry after Chat only", false)
}
for key in ["Would you like to run the following command?",
            "Would you like to send input to the existing terminal?",
            "Would you like to make the following edits?",
            "Yes, proceed", "Yes, just this once",
            "Yes, and allow this host for this conversation",
            "Yes, and don't ask again for this command in this session",
            "Yes, and don't ask again for these files",
            "No, continue without running it",
            "No, and tell %@ what to do differently",
            "SipAI starts %@ afresh for each message, so a “this session” or “these files” answer lasts until this message’s turn ends.",
            "Implement this plan?", "Yes, implement in %@", "No, stay in Plan mode",
            "Stopped at your answer — tell %@ what to do differently in your next message.",
            "Interrupted — this turn was stopped before it finished.",
            "The installed %@ answered in a protocol version SipAI doesn’t speak. Pick another mode to send.",
            "%@ reported an error but gave no detail.",
            "%@’s own default setting",
            "Explores and asks you questions, then proposes a plan; it’s told to change nothing until you choose to implement it",
            "Let %@ choose what it judges best, and keep the run going to the end even when it has questions.",
            "%@ keeps working while you answer.",
            "Couldn’t send your answer to %@: %@",
            helpQuestionKey, helpAnswerKey] {
    let quoted = "\"" + key + "\" : {"
    let entry = catalogSource.range(of: quoted).map { String(catalogSource[$0.upperBound...].prefix(700)) } ?? ""
    check("catalog: \(key.prefix(52))… has zh-Hans", entry.contains("\"zh-Hans\""))
}

// MARK: - 2. The real codex

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
    var cards: [AgentCardRequest] = []
    var withdrawn: [String] = []
    var followUps: [String] = []
    var onCard: ((AgentCardRequest) -> Void)?
    /// What reached the screen, in order: each notice as it was set or
    /// cleared ("notice:-"), each event by its signature.
    var screen: [String] = []

    init(cwd: URL, sessionId: String? = nil) {
        self.cwd = cwd
        self.sessionId = sessionId
    }

    func adoptSession(id: String) {
        adopted.append(id)
        sessionId = id
    }
    func emit(_ e: [StreamEvent]) {
        events += e
        screen += e.map(signature)
    }
    func setNotice(_ t: String?) {
        if let t { notices.append(t) }
        screen.append("notice:" + (t ?? "-"))
    }
    func noteContextUsage(tokens: Int, window: Int?) {}
    @discardableResult
    func present(_ card: AgentCardRequest) -> String? {
        if adoptedBeforeFirstCard == nil { adoptedBeforeFirstCard = sessionId != nil }
        cards.append(card)
        let id = "card-\(cards.count)"
        onCard?(card)
        return id
    }
    func withdraw(cardId: String) { withdrawn.append(cardId) }
    func offerPlanFollowUp(_ plan: String) { followUps.append(plan) }
    /// Each time the driver took a claimed skill load back off the
    /// message's row: the names, or "*" for every one it names.
    var retracted: [[String]] = []
    func retractSkillLoads(_ names: [String]?) { retracted.append(names ?? ["*"]) }
    /// Each time the driver ended the turn on a failure it had put on the
    /// transcript: the words of that row.
    var failures: [String] = []
    func noteTurnFailed(_ message: String) { failures.append(message) }
    /// Each change of what the turn says it waits on: the commands named.
    var awaited: [[String]] = []
    /// What it waits on now, ids included.
    var awaitedEntries: [BackgroundTaskEntry] = []
    func setAwaitedBackgroundTasks(_ tasks: [BackgroundTaskEntry]) {
        awaitedEntries = tasks
        let names = tasks.map(\.description)
        if awaited.last != names { awaited.append(names) }
    }
    /// Whether the turn takes a message steered into it, as the driver last
    /// said; and each message it said codex took, in order.
    var steerable = false
    var taken: [String] = []
    func setSteerable(_ on: Bool) { steerable = on }
    func steerTaken(text: String) { taken.append(text) }
    /// Each change of "summarising the conversation".
    var compacting: [Bool] = []
    func setCompacting(_ on: Bool) { if compacting.last != on { compacting.append(on) } }
    /// What the driver said about each turn's pinned speed, as "tier:served".
    var speeds: [String] = []
    func noteSpeed(asked: String, served: Bool) { speeds.append("\(asked):\(served)") }
    var signatures: [String] { events.map(signature) }
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

    /// Every Responses request carrying `marker` in its newest user message.
    func bodies(marked marker: String) -> [[String: Any]] {
        requests().compactMap { $0["body"] as? [String: Any] }.filter { body in
            let input = body["input"] as? [[String: Any]] ?? []
            guard let lastUser = input.last(where: { $0["type"] as? String == "message" && $0["role"] as? String == "user" })
            else { return false }
            return jsonText(lastUser).contains(marker)
        }
    }

    /// The tool outputs codex sent back upstream on the turn `marker` opened
    /// — after its message, never the earlier turns' history.
    func outputs(marked marker: String) -> [String] {
        var seen: [String] = []
        for body in bodies(marked: marker) {
            let input = body["input"] as? [[String: Any]] ?? []
            guard let opened = input.lastIndex(where: {
                $0["type"] as? String == "message" && $0["role"] as? String == "user"
                    && jsonText($0).contains(marker)
            }) else { continue }
            for item in input[(opened + 1)...] {
                guard ["function_call_output", "custom_tool_call_output"].contains(item["type"] as? String ?? ""),
                      let output = item["output"] as? String, !seen.contains(output) else { continue }
                seen.append(output)
            }
        }
        return seen
    }

    /// Every tool output on the turn `marker` opened, an MCP tool's
    /// included — codex sends that one as a list of text parts, joined
    /// here.
    func partOutputs(marked marker: String) -> [String] {
        var seen: [String] = []
        for body in bodies(marked: marker) {
            let input = body["input"] as? [[String: Any]] ?? []
            guard let opened = input.lastIndex(where: {
                $0["type"] as? String == "message" && $0["role"] as? String == "user"
                    && jsonText($0).contains(marker)
            }) else { continue }
            for item in input[(opened + 1)...] where (item["type"] as? String ?? "").hasSuffix("_output") {
                let text: String
                if let s = item["output"] as? String {
                    text = s
                } else if let parts = item["output"] as? [[String: Any]] {
                    text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                } else {
                    continue
                }
                if !seen.contains(text) { seen.append(text) }
            }
        }
        return seen
    }

    /// The same, each output re-serialised with sorted keys: codex writes
    /// an object's keys in an order of its own.
    func sortedOutputs(marked marker: String) -> [String] {
        outputs(marked: marker).map { output in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(output.utf8)) else { return output }
            return jsonText(obj)
        }
    }
}

func startFake(script: [[String: Any]]) -> Fake? {
    let records = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cxas-rec-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
    let scriptFile = records.deletingLastPathComponent()
        .appendingPathComponent(records.lastPathComponent + "-script.json")
    guard let data = try? JSONSerialization.data(withJSONObject: script),
          (try? data.write(to: scriptFile)) != nil else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", fakeServerPath, records.path, "--responses-script", scriptFile.path]
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

/// `model: nil` leaves the config naming none — codex then runs its own
/// default, which is what most installs do.
func makeHome(port: Int, model: String? = "gpt-5.5", extraTop: String = "",
              extraTail: String = "") -> URL {
    let home = URL(fileURLWithPath: "/tmp").appendingPathComponent("cxas-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let config = """
    model_provider = "fake"
    \(model.map { "model = \"\($0)\"" } ?? "")
    \(extraTop)

    [model_providers.fake]
    name = "fake"
    base_url = "http://127.0.0.1:\(port)"
    wire_api = "responses"

    \(extraTail)

    """
    try? config.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    return home
}

func makeFolder() -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cxas-cwd-\(UUID().uuidString)")
    let dir = base.appendingPathComponent("w")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["init", "-q", dir.path]
    try? p.run()
    p.waitUntilExit()
    return URL(fileURLWithPath: CodexConfigRead.physicalPath(dir.path))
}

/// Mark `folder` trusted in `home`'s config, as codex's own app does when
/// the user trusts it: codex's own default there is its Default preset
/// (on-request, workspace-write). Untrusted, it is read-only.
func trust(_ folder: URL, in home: URL) {
    let config = home.appendingPathComponent("config.toml")
    let text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
    try? (text + "\n[projects.\"\(folder.path)\"]\ntrust_level = \"trusted\"\n")
        .write(to: config, atomically: true, encoding: .utf8)
}

func findCodex() -> String? {
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let candidate = "\(dir)/codex"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

func codexVersion(_ binary: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    p.arguments = ["--version"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return text.split(separator: " ").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
}

func options(_ mode: String?) -> AgentLaunchOptions {
    var o = AgentLaunchOptions()
    o.permissionMode = mode
    return o
}

/// One conversation with a fresh `codex app-server`, run the way the
/// runner runs one: stdin a pipe kept open, stdout read line by line into
/// the peer on a thread of its own, the protocol spoken on the main actor,
/// stdin closed once `body` is done, the child waited for.
///
/// `closedUnderBody` is what the runner asks when a driver returns: was the
/// conversation still open (the protocol is done with the turn), or did it
/// end under the driver (the child gone — the runner reports its exit).
/// `bodySeconds` is how long the driver took.
@MainActor
func converse(binary: String, arguments: [String] = CodexAppServer.arguments,
              cwd: URL, home: URL,
              onSpawn: ((Process) -> Void)? = nil,
              _ body: (JSONRPCLinePeer) async -> Void) async
-> (exit: Int32, seconds: Double, stderr: String, closedUnderBody: Bool, bodySeconds: Double) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    p.arguments = arguments
    p.currentDirectoryURL = cwd
    var env = ProcessInfo.processInfo.environment
    env["CODEX_HOME"] = home.path
    p.environment = env
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    p.standardInput = stdin
    p.standardOutput = stdout
    p.standardError = stderr
    do { try p.run() } catch { return (-1, 0, "spawn failed: \(error)", false, 0) }
    onSpawn?(p)
    let writeFD = dup(stdin.fileHandleForWriting.fileDescriptor)
    try? stdin.fileHandleForWriting.close()
    let peer = JSONRPCLinePeer(label: "harness.codex", writing: writeFD,
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
    let bodyStarted = Date()
    await body(peer)
    let closedUnderBody = peer.isClosed
    let closedAt = Date()
    peer.finishWriting()
    let deadline = Date().addingTimeInterval(15)
    while p.isRunning, Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    if p.isRunning { p.terminate() }
    peer.close(reason: "the harness conversation ended")
    let code = p.isRunning ? -1 : p.terminationStatus
    let exitedAfter = Date().timeIntervalSince(closedAt)
    // What the child said on its way out is read to its end.
    let drained = Date().addingTimeInterval(2)
    while !errors.isComplete, Date() < drained {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return (code, exitedAfter, errors.value, closedUnderBody,
            closedAt.timeIntervalSince(bodyStarted))
}

@MainActor
func runTurn(_ driver: CodexAppServerTurn, host: HarnessHost, binary: String, home: URL)
async -> (exit: Int32, seconds: Double, stderr: String, closedUnderBody: Bool, bodySeconds: Double) {
    await converse(binary: binary, cwd: host.cwd, home: home) { peer in
        await driver.run(peer: peer, host: host)
    }
}

/// One turn against the stand-in server (`stub_server.py <mode>`), which
/// gives the answers the real app-server cannot be made to give.
@MainActor
func runStubTurn(_ driver: CodexAppServerTurn, host: HarnessHost, mode: String, home: URL,
                 log: URL? = nil)
async -> (exit: Int32, seconds: Double, stderr: String, closedUnderBody: Bool, bodySeconds: Double) {
    await converse(binary: "/usr/bin/env",
                   arguments: ["python3", stubServerPath, mode] + (log.map { [$0.path] } ?? []),
                   cwd: host.cwd, home: home) { peer in
        await driver.run(peer: peer, host: host)
    }
}

/// What the stand-in server was sent, in order: each request's method and
/// params.
func stubLog(_ url: URL) -> [(method: String, params: [String: Any])] {
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap { line in
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let method = message["method"] as? String, message["id"] != nil else { return nil }
        return (method, message["params"] as? [String: Any] ?? [:])
    }
}

/// The thread writer locks codex holds in `home` right now.
func writerLocks(home: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(
        atPath: home.appendingPathComponent("thread-writer-locks").path)) ?? [])
        .filter { !$0.hasPrefix(".") }.sorted()
}

/// The newest `turn_context` of a thread's rollout: the profile in force
/// and its sandbox policy.
func lastTurnProfile(home: URL, id: String) -> (profile: String?, sandbox: String) {
    guard let url = rollout(home: home, id: id),
          let text = try? String(contentsOf: url, encoding: .utf8) else { return (nil, "-") }
    var out: (String?, String) = (nil, "-")
    for line in text.split(separator: "\n") {
        guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              record["type"] as? String == "turn_context",
              let payload = record["payload"] as? [String: Any] else { continue }
        out = ((payload["active_permission_profile"] as? [String: Any])?["id"] as? String,
               jsonText(payload["sandbox_policy"] ?? [String: Any]()))
    }
    return out
}

func rollout(home: URL, id: String) -> URL? {
    let root = home.appendingPathComponent("sessions")
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
    for case let url as URL in walker where url.lastPathComponent.contains(id) && url.pathExtension == "jsonl" {
        return url
    }
    return nil
}

/// The permissions each turn of a thread ran with, in order, off its
/// rollout's `turn_context` records: "policy/sandbox".
func turnPermissions(home: URL, id: String) -> [String] {
    guard let url = rollout(home: home, id: id),
          let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line -> String? in
        guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              record["type"] as? String == "turn_context",
              let payload = record["payload"] as? [String: Any] else { return nil }
        let policy = payload["approval_policy"] as? String ?? "?"
        let sandbox = (payload["sandbox_policy"] as? [String: Any])?["type"] as? String ?? "?"
        return "\(policy)/\(sandbox)"
    }
}

/// `codex exec [resume <id>] <prompt>` — the headless turn SipAI's other
/// codex rows run.
func execTurn(binary: String, cwd: URL, home: URL, resume: String?, prompt: String,
              permissions: [String] = ["-c", #"sandbox_mode="workspace-write""#]) -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    var args = ["exec", "--json", "--skip-git-repo-check"] + permissions
    if let resume { args += ["resume", resume] }
    args.append(prompt)
    p.arguments = args
    p.currentDirectoryURL = cwd
    var env = ProcessInfo.processInfo.environment
    env["CODEX_HOME"] = home.path
    p.environment = env
    p.standardInput = FileHandle.nullDevice
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [] }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
}

@MainActor
func live() async {
    print("\n2. The real codex app-server (token-free, a throwaway CODEX_HOME)")
    guard let binary = findCodex() else {
        skip("the real codex", "codex is not on PATH")
        return
    }
    guard let version = codexVersion(binary),
          ChatOnlyAvailability.versionAtLeast(version, AgentAskingMode.codexVersionFloor) else {
        skip("the real codex", "codex is older than \(AgentAskingMode.codexVersionFloor)")
        return
    }
    let outside = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/sipai-codexbridge-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }

    let questions: [String: Any] = ["questions": [
        ["id": "db", "header": "Database", "question": "Which database should the app use?",
         "options": [["label": "Postgres (Recommended)", "description": "Server database."],
                     ["label": "SQLite", "description": "A local file."]]],
        ["id": "ui", "header": "UI", "question": "Which UI toolkit?",
         "options": [["label": "SwiftUI (Recommended)", "description": "Native."],
                     ["label": "AppKit", "description": "Older."]]],
    ]]
    func escalated(_ path: String) -> [String: Any] {
        ["function_call": ["name": "exec_command", "arguments": [
            "cmd": "touch \(path)", "sandbox_permissions": "require_escalated",
            "justification": "Make the probe file?"]]]
    }
    let script: [[String: Any]] = [
        ["marker": "SIPAI-A", "steps": [escalated(outside.path + "/a.txt"), ["text": "DONE A"]]],
        ["marker": "SIPAI-B", "steps": [
            ["custom_tool_call": ["name": "apply_patch",
                                  "input": "*** Begin Patch\n*** Add File: \(outside.path)/b.txt\n+hello\n*** End Patch\n"]],
            ["text": "DONE B"]]],
        ["marker": "SIPAI-C", "steps": [escalated(outside.path + "/c.txt"), ["text": "DONE C"]]],
        ["marker": "SIPAI-TEE", "steps": [
            ["function_call": ["name": "exec_command", "arguments": [
                "cmd": "cat seed.txt | tee \(outside.path)/tee.txt", "sandbox_permissions": "require_escalated",
                "justification": "Copy the seed out?"]]],
            ["text": "DONE TEE"]]],
        ["marker": "SIPAI-PLAN", "steps": [
            ["function_call": ["name": "request_user_input", "arguments": questions]],
            ["text": "Here is the plan.\n\n<proposed_plan>\n# Ship it\n\n1. Build the thing.\n</proposed_plan>\n"]]],
        ["marker": "SIPAI-NONSTOP", "steps": [
            ["function_call": ["name": "request_user_input", "arguments": questions]], ["text": "DONE NONSTOP"]]],
        ["marker": "SIPAI-F", "steps": [escalated(outside.path + "/f.txt"), ["text": "DONE F"]]],
        ["marker": "SIPAI-EXECQ", "steps": [
            ["function_call": ["name": "request_user_input", "arguments": questions]], ["text": "DONE EXECQ"]]],
        ["marker": "SIPAI-WIRE", "steps": [["text": "DONE WIRE"]]],
        ["marker": "SIPAI-E400", "steps": [["error": ["status": 400, "body": ["error": [
            "message": "Invalid request: scripted 400", "type": "invalid_request_error"]]]]]],
        ["marker": "SIPAI-PAIR", "steps": [
            ["function_call": ["name": "exec_command", "arguments": ["cmd": "echo hello; echo world"]]],
            ["function_call": ["name": "exec_command", "arguments": ["cmd": "ls /nonexistent-sipai-probe"]]],
            ["custom_tool_call": ["name": "apply_patch",
                                  "input": "*** Begin Patch\n*** Add File: made.txt\n+hello\n*** End Patch\n"]],
            ["text": "DONE PAIR"]]],
        // A question asked without stopping; the turn goes on (the delay
        // keeps it running while the card is up). A reply carrying the
        // REPLY marker is answered on its own.
        ["marker": "SIPAI-ASYNCQ-REPLY", "steps": [["text": "GOT THE REPLY"]]],
        ["marker": "SIPAI-ASYNCQ", "steps": [
            ["function_call": ["name": "request_user_input_async", "call_id": "call_asyncq", "arguments": [
                "questions": [["title": "Which database should the app use?",
                               "options": ["Postgres (Recommended)", "SQLite"]],
                              ["title": "Anything else I should know?"]]]]],
            ["delay": 3, "text": "DONE ASYNCQ"]]],
    ]
    guard let fake = startFake(script: script) else {
        check("the fake endpoint starts", false)
        return
    }
    defer { fake.process.terminate() }
    let home = makeHome(port: fake.port)
    defer { try? FileManager.default.removeItem(at: home) }
    // Every scenario's folder is one the config trusts, so a Default turn
    // runs codex's own Default preset there — what its own app runs once a
    // folder is trusted. An untrusted folder's default is its own check (V).
    func trusted(_ folder: URL) -> URL {
        trust(folder, in: home)
        return folder
    }
    // The driver as the runner builds it: `settings` are the chips' PICKS,
    // `folderModel` SipAI's own reading of the config, and whatever is left
    // on Default is resolved once codex has answered for the folder.
    func driver(_ text: String, _ mode: String?,
                settings: CodexAppServer.TurnSettings = CodexAppServer.TurnSettings(),
                folderModel: String? = nil,
                modelDefaultEffort: @escaping (String) -> String? = { _ in nil }) -> CodexAppServerTurn {
        CodexAppServerTurn(
            text: text, options: options(mode),
            settings: { defaults in
                CodexAppServer.turnSettings(model: settings.model, effort: settings.effort,
                                            folderModel: folderModel, folderEffort: nil,
                                            modelDefaultEffort: modelDefaultEffort,
                                            serviceTier: settings.serviceTier, defaults: defaults)
            },
            agentName: agent, clientVersion: "harness")!
    }

    // A. Agent, a new thread: an escalated command asks; the answer runs it.
    let folderA = trusted(makeFolder())
    let hostA = HarnessHost(cwd: folderA)
    hostA.onCard = { $0.respond(.chose("accept")) }
    let runA = await runTurn(driver("SIPAI-A go", nil), host: hostA, binary: binary, home: home)
    let threadA = hostA.adopted.first ?? ""
    if case .permission(let content)? = hostA.cards.first?.presentation {
        check("A. an escalated command is a card in codex's words: the command as written, the model's reason, codex's answers",
              content.prompt == "Would you like to run the following command?"
                && content.preview == .command("touch \(outside.path)/a.txt", cwd: folderA.path, reason: "Make the probe file?")
                && content.choices.map(\.id) == ["accept", "cancel"],
              "\(content)")
    } else {
        check("A. an escalated command is a card in codex's words", false, "\(hostA.cards.count) cards")
    }
    check("A. the answer runs it; the turn is drawn as exec's would be, and ends with codex's result",
          FileManager.default.fileExists(atPath: outside.path + "/a.txt")
            && hostA.signatures.contains("tool:command_execution:touch \(outside.path)/a.txt")
            && hostA.signatures.contains("assistant:DONE A") && hostA.signatures.last == "turn-result",
          "\(hostA.signatures)")
    check("A. the new thread is named once codex has accepted its turn — before anything is asked — and its record is on disk",
          hostA.adopted.count == 1 && !threadA.isEmpty && hostA.adoptedBeforeFirstCard == true
            && rollout(home: home, id: threadA) != nil,
          "adopted \(hostA.adopted), before the first card \(String(describing: hostA.adoptedBeforeFirstCard))")
    check("A. the driver returned with the conversation still open: the protocol was done with the turn",
          !runA.closedUnderBody)
    check("A. stdin closes once the turn has completed, and the child is gone at once",
          runA.exit == 0 && runA.seconds < 3, "exit \(runA.exit), \(runA.seconds) s")
    if let url = rollout(home: home, id: threadA) {
        let reopened = CodexSessionScanner.readHistory(of: url, root: home.appendingPathComponent("sessions"))
        let texts = reopened.compactMap { item -> String? in
            if case .assistantText(let t) = item.kind { return t.trimmingCharacters(in: .whitespacesAndNewlines) }
            return nil
        }
        check("A. reopened, the session reads the same words", texts == ["DONE A"], "\(texts)")
    }

    // B. A patch outside the folder: the edits from codex's item, codex's three answers.
    let hostB = HarnessHost(cwd: folderA, sessionId: threadA)
    hostB.onCard = { $0.respond(.chose("acceptForSession")) }
    _ = await runTurn(driver("SIPAI-B go", nil), host: hostB, binary: binary, home: home)
    if case .permission(let content)? = hostB.cards.first?.presentation {
        check("B. an edit outside the folder shows codex's own diff, its three answers and how long \"these files\" lasts",
              content.prompt == "Would you like to make the following edits?"
                && content.preview == .fileChanges([CardFileChange(path: outside.path + "/b.txt", kind: "add", diff: "+hello")], reason: nil)
                && content.choices.map(\.id) == ["accept", "acceptForSession", "cancel"]
                && content.notes.count == 1,
              "\(content)")
    } else {
        check("B. an edit outside the folder shows codex's own diff", false, "\(hostB.cards.count) cards")
    }
    check("B. a resumed thread is not named again, and the answer applies the edit",
          hostB.adopted.isEmpty && FileManager.default.fileExists(atPath: outside.path + "/b.txt"))

    // C. "No, and tell Codex what to do differently": the turn ends, and says why.
    let hostC = HarnessHost(cwd: folderA, sessionId: threadA)
    hostC.onCard = { $0.respond(.chose("cancel")) }
    _ = await runTurn(driver("SIPAI-C go", nil), host: hostC, binary: binary, home: home)
    check("C. refusing ends the turn without running it, with a row saying what to do next",
          !FileManager.default.fileExists(atPath: outside.path + "/c.txt")
            && hostC.signatures.contains { $0.hasPrefix("interrupted:Stopped at your answer") }
            && !hostC.signatures.contains("turn-result"),
          "\(hostC.signatures)")

    // D. Plan: questions answered on the card, the plan drawn and offered.
    let folderD = trusted(makeFolder())
    let hostD = HarnessHost(cwd: folderD)
    hostD.onCard = { card in
        var own = AgentQuestionAnswer()
        own.otherPicked = true
        own.otherText = "MyKit"
        card.respond(.answered(["Which database should the app use?": AgentQuestionAnswer(labels: ["Postgres (Recommended)"]),
                                "Which UI toolkit?": own]))
    }
    _ = await runTurn(driver("SIPAI-PLAN go", AgentAskingMode.codexPlan), host: hostD, binary: binary, home: home)
    let threadD = hostD.adopted.first ?? ""
    let formD = hostD.cards.first?.question
    check("D. a Plan question is a question card: codex's ids, headers and its own Other",
          formD?.questions.map(\.id) == ["db", "ui"] && formD?.questions.allSatisfy(\.allowsOther) == true,
          "\(String(describing: formD?.questions))")
    check("D. the answers reach the model as codex's terminal sends them",
          fake.sortedOutputs(marked: "SIPAI-PLAN go") == [#"{"answers":{"db":{"answers":["Postgres (Recommended)"]},"ui":{"answers":["None of the above","user_note: MyKit"]}}}"#],
          "\(fake.outputs(marked: "SIPAI-PLAN go"))")
    check("D. the plan is drawn after the words around it, and offered to carry out once the turn is over",
          hostD.signatures.suffix(3) == ["assistant:Here is the plan.", "assistant:# Ship it\n\n1. Build the thing.", "turn-result"]
            && hostD.followUps == ["# Ship it\n\n1. Build the thing.\n"],
          "\(hostD.signatures), \(hostD.followUps)")
    if let url = rollout(home: home, id: threadD) {
        let reopened = CodexSessionScanner.readHistory(of: url, root: home.appendingPathComponent("sessions"))
        let texts = reopened.compactMap { item -> String? in
            if case .assistantText(let t) = item.kind { return t }
            return nil
        }
        check("D. reopened, the plan reads the same: the words, then the plan, no tags",
              texts == ["Here is the plan.", "# Ship it\n\n1. Build the thing."], "\(texts)")
        check("D. the thread is left in plan mode by codex", CodexAppServer.planModeLeftOn(rollout: url).on)
    } else {
        check("D. the plan thread's record is on disk", false)
    }

    // E. Non-stop: the question goes unanswered, and the model is told nothing.
    let hostE = HarnessHost(cwd: folderD, sessionId: threadD)
    hostE.onCard = { $0.respond(.declined(.nonStop)) }
    _ = await runTurn(driver("SIPAI-NONSTOP go", AgentAskingMode.codexPlan), host: hostE, binary: binary, home: home)
    check("E. under Non-stop the model gets no answers and goes on",
          fake.outputs(marked: "SIPAI-NONSTOP") == [#"{"answers":{}}"#] && hostE.signatures.contains("assistant:DONE NONSTOP"),
          "\(fake.outputs(marked: "SIPAI-NONSTOP"))")

    // F. Stop with a card up: codex is told, ends the turn, and withdraws its request.
    let folderF = trusted(makeFolder())
    let hostF = HarnessHost(cwd: folderF)
    let driverF = driver("SIPAI-F go", nil)
    var stoppedAt: Date? = nil
    let runF = await converse(binary: binary, cwd: folderF, home: home) { peer in
        hostF.onCard = { _ in
            hostF.live = false
            stoppedAt = Date()
            _ = driverF.interrupt(peer: peer)
        }
        await driverF.run(peer: peer, host: hostF)
    }
    check("F. Stop with a card up: the turn ends at once, codex withdraws its question, nothing runs, no refusal row",
          stoppedAt.map { Date().timeIntervalSince($0) < 10 } == true && runF.exit == 0
            && hostF.withdrawn == ["card-1"]
            && !FileManager.default.fileExists(atPath: outside.path + "/f.txt")
            && !hostF.signatures.contains { $0.hasPrefix("interrupted:") },
          "withdrawn \(hostF.withdrawn), \(hostF.signatures)")

    // G. Plan mode is the thread's — a headless turn after a Plan turn plans, until it is put back.
    let folderG = trusted(makeFolder())
    let hostG = HarnessHost(cwd: folderG)
    hostG.onCard = { $0.respond(.declined(.nonStop)) }
    _ = await runTurn(driver("SIPAI-PLAN again", AgentAskingMode.codexPlan), host: hostG, binary: binary, home: home)
    let threadG = hostG.adopted.first ?? ""
    _ = execTurn(binary: binary, cwd: folderG, home: home, resume: threadG, prompt: "SIPAI-EXECQ control")
    check("G. the negative control: a codex exec turn after a Plan turn still runs in plan mode",
          fake.outputs(marked: "SIPAI-EXECQ control") == [#"{"answers":{}}"#],
          "\(fake.outputs(marked: "SIPAI-EXECQ control"))")
    let folderH = trusted(makeFolder())
    let hostH = HarnessHost(cwd: folderH)
    hostH.onCard = { $0.respond(.declined(.nonStop)) }
    _ = await runTurn(driver("SIPAI-PLAN third", AgentAskingMode.codexPlan), host: hostH, binary: binary, home: home)
    let threadH = hostH.adopted.first ?? ""
    let planRecord = rollout(home: home, id: threadH).map { CodexAppServer.planModeLeftOn(rollout: $0) }
    let requestsBefore = fake.requests().count
    var left = false
    if let model = planRecord?.model {
        _ = await converse(binary: binary, cwd: folderH, home: home) { peer in
            left = await CodexAppServerTurn.leavePlanMode(peer: peer, threadId: threadH, cwd: folderH.path,
                                                          model: model, clientVersion: "harness")
        }
    }
    check("G. codex's own settings update puts the thread back, with no model request",
          planRecord?.on == true && left && fake.requests().count == requestsBefore
            && rollout(home: home, id: threadH).map { CodexAppServer.planModeLeftOn(rollout: $0).on } == false)
    _ = execTurn(binary: binary, cwd: folderH, home: home, resume: threadH, prompt: "SIPAI-EXECQ after")
    check("G. …and the next codex exec turn runs in Default mode",
          fake.outputs(marked: "SIPAI-EXECQ after") == ["request_user_input is unavailable in Default mode"],
          "\(fake.outputs(marked: "SIPAI-EXECQ after"))")

    // H. What a turn states is what codex runs, whatever an earlier turn named.
    let folderW = trusted(makeFolder())
    let hostW = HarnessHost(cwd: folderW)
    _ = await runTurn(driver("SIPAI-WIRE one", nil,
                             settings: CodexAppServer.TurnSettings(model: "gpt-5.5", effort: "high", serviceTier: "priority")),
                      host: hostW, binary: binary, home: home)
    let wireOne = fake.bodies(marked: "SIPAI-WIRE one").last
    let hostW2 = HarnessHost(cwd: folderW, sessionId: hostW.adopted.first)
    _ = await runTurn(driver("SIPAI-WIRE two", nil,
                             settings: CodexAppServer.TurnSettings(model: "gpt-5.5", effort: "low", serviceTier: nil)),
                      host: hostW2, binary: binary, home: home)
    let wireTwo = fake.bodies(marked: "SIPAI-WIRE two").last
    check("H. the model, effort and speed a turn states reach the request, and the next turn's replace them",
          wireOne?["model"] as? String == "gpt-5.5"
            && (wireOne?["reasoning"] as? [String: Any])?["effort"] as? String == "high"
            && wireOne?["service_tier"] as? String == "priority"
            && (wireTwo?["reasoning"] as? [String: Any])?["effort"] as? String == "low"
            && wireTwo?["service_tier"] == nil,
          "one \(String(describing: wireOne?["reasoning"])) \(String(describing: wireOne?["service_tier"])), two \(String(describing: wireTwo?["reasoning"])) \(String(describing: wireTwo?["service_tier"]))")
    check("H. the request comes from SipAI by name",
          (fake.requests().last?["headers"] as? [String: Any])?["originator"] as? String == "sipai")
    // H. A turn's thinking is codex's own setting: the request asks for
    //    reasoning summaries only where the user's config sets
    //    `model_reasoning_summary` (Help's Compact view answer says so),
    //    and the driver states nothing about them.
    let summaryHome = makeHome(port: fake.port, extraTop: "model_reasoning_summary = \"detailed\"")
    defer { try? FileManager.default.removeItem(at: summaryHome) }
    let folderSummary = makeFolder()
    trust(folderSummary, in: summaryHome)
    _ = await runTurn(driver("SIPAI-WIRE summary", nil), host: HarnessHost(cwd: folderSummary),
                      binary: binary, home: summaryHome)
    let summaryAsked = (fake.bodies(marked: "SIPAI-WIRE summary").last?["reasoning"] as? [String: Any])?["summary"]
    check("H. codex asks for thinking summaries where the user's config sets model_reasoning_summary, and only there",
          summaryAsked as? String == "detailed"
            && wireOne.map { ($0["reasoning"] as? [String: Any])?["summary"] == nil } == true
            && wireTwo.map { ($0["reasoning"] as? [String: Any])?["summary"] == nil } == true,
          "asked \(String(describing: summaryAsked)), one \(String(describing: wireOne?["reasoning"]))")

    // H. …Ultrafast as well, on the route a Default chip runs. An account
    //    offered it gets a catalog listing it beside Fast — handed to codex
    //    here through `model_catalog_json`, built from codex's own bundled
    //    entry. What SipAI says, over codex's own answers for the folder
    //    (`config/read`, `configRequirements/read`, `model/list`), is what
    //    the request carries, with either speed's switch turned off.
    let twoSpeed = "sipai-two-speed"
    let twoSpeedHome = makeHome(port: fake.port)
    defer { try? FileManager.default.removeItem(at: twoSpeedHome) }
    var twoSpeedLine: String? = nil
    let bundledDump = Process()
    bundledDump.executableURL = URL(fileURLWithPath: binary)
    bundledDump.arguments = ["debug", "models", "--bundled"]
    var dumpEnvironment = ProcessInfo.processInfo.environment
    dumpEnvironment["CODEX_HOME"] = twoSpeedHome.path
    bundledDump.environment = dumpEnvironment
    bundledDump.standardInput = FileHandle.nullDevice
    bundledDump.standardError = FileHandle.nullDevice
    let dumpOut = Pipe()
    bundledDump.standardOutput = dumpOut
    if (try? bundledDump.run()) != nil {
        let data = dumpOut.fileHandleForReading.readDataToEndOfFile()
        bundledDump.waitUntilExit()
        if bundledDump.terminationStatus == 0,
           var bundled = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var entry = (bundled["models"] as? [[String: Any]])?.first(where: { entry in
               entry["visibility"] as? String == "list"
                   && ((entry["service_tiers"] as? [[String: Any]]) ?? []).contains { $0["id"] as? String == "priority" }
           }) {
            entry["slug"] = twoSpeed
            entry["display_name"] = "SipAI Two Speed"
            entry["service_tiers"] = [
                ["id": "priority", "name": "Fast", "description": "2x speed, increased usage"],
                ["id": "ultrafast", "name": "Ultrafast",
                 "description": "The fastest available responses for latency-sensitive work."],
            ]
            entry["additional_speed_tiers"] = ["fast", "ultrafast"]
            entry.removeValue(forKey: "default_service_tier")
            bundled["models"] = [entry]
            let file = twoSpeedHome.appendingPathComponent("two-speed-catalog.json")
            if let encoded = try? JSONSerialization.data(withJSONObject: bundled),
               (try? encoded.write(to: file)) != nil {
                twoSpeedLine = "model_catalog_json = \"\(file.path)\""
            }
        }
    }
    /// One Default turn on the two-speed model under `extraTop`: the speed
    /// SipAI states for `pick` — the composer's rule over codex's answers
    /// for the folder — and the tier the request then carried.
    func ultrafastTurn(_ label: String, pick: String?, extraTop: String) async
    -> (listed: [String], stated: String?, wire: String?, independent: Bool) {
        let homeU = makeHome(port: fake.port, model: twoSpeed,
                             extraTop: (twoSpeedLine ?? "") + "\n" + extraTop)
        defer { try? FileManager.default.removeItem(at: homeU) }
        let folderU = makeFolder()
        trust(folderU, in: homeU)
        var config: Any? = nil
        var requirements: Any? = nil
        var list: Any? = nil
        _ = await converse(binary: binary, cwd: folderU, home: homeU) { peer in
            _ = try? await peer.request("initialize",
                                        params: CodexAppServer.initializeParams(clientVersion: "harness"), timeout: 15)
            peer.notify("initialized")
            config = try? await peer.request("config/read",
                                             params: ["cwd": CodexConfigRead.physicalPath(folderU.path)],
                                             timeout: 30)
            requirements = try? await peer.request("configRequirements/read", timeout: 30)
            list = try? await peer.request("model/list", params: [String: Any](), timeout: 30)
        }
        let settings = CodexConfigRead.config(fromAnswer: config.map { ["result": $0] })
            .map { CodexSpeed.settings(fromEffectiveConfig: $0,
                                       requirements: CodexConfigRead.requirements(
                                           fromAnswer: requirements.map { ["result": $0] })) }
            ?? CodexSpeed.Settings()
        let tiers = CodexCatalog.listedTiers(fromAnswer: list.map { ["result": $0] })[twoSpeed]
        let stated = CodexSpeed.effective(pick: pick, configured: settings.configured,
                                          model: tiers, gates: settings.gates)
        let pin = CodexSpeed.override(pick: pick, effective: stated, model: tiers, gates: settings.gates)
        let marker = "SIPAI-WIRE ultrafast \(label)"
        _ = await runTurn(driver(marker, nil,
                                 settings: CodexAppServer.TurnSettings(model: twoSpeed, effort: nil,
                                                                       serviceTier: pin)),
                          host: HarnessHost(cwd: folderU), binary: binary, home: homeU)
        return (tiers?.tiers.map(\.id) ?? [], stated,
                fake.bodies(marked: marker).last?["service_tier"] as? String, settings.gates.independent)
    }
    if twoSpeedLine != nil {
        let picked = await ultrafastTurn("picked", pick: "ultrafast", extraTop: "")
        let fastOff = await ultrafastTurn("configured-fast-off", pick: nil,
                                          extraTop: "service_tier = \"ultrafast\"\nfeatures.fast_mode = false")
        let ultraOff = await ultrafastTurn("picked-ultra-off", pick: "ultrafast",
                                           extraTop: "features.ultrafast_mode = false")
        func says(_ r: (listed: [String], stated: String?, wire: String?, independent: Bool)) -> String {
            "listed \(r.listed), says \(r.stated ?? "standard"), carries \(r.wire ?? "none")"
        }
        check("H. Ultrafast picked on a Default turn: model/list passes it through, and what SipAI says is what the request carries",
              picked.listed == ["priority", "ultrafast"] && picked.stated == "ultrafast" && picked.wire == "ultrafast",
              says(picked))
        check("H. …Default under a config asking for Ultrafast, Fast's switch off: said and sent alike — Ultrafast where codex gates the two apart",
              fastOff.stated == fastOff.wire && fastOff.stated == (fastOff.independent ? "ultrafast" : nil),
              says(fastOff))
        check("H. …Ultrafast picked with its own switch off: standard, said and sent",
              ultraOff.stated == nil && ultraOff.wire == nil, says(ultraOff))
    } else {
        skip("H. Ultrafast on a Default turn", "codex debug models --bundled gave no catalog")
    }

    // HS. The speed a message pins is named when the session is opened, where
    //     codex checks it, and codex's answer reaches the runner: on a model
    //     codex's list gives Fast alone — its built-in list, as when its
    //     download does not finish — it answers none and the message runs at
    //     standard speed; on a model whose list has it, the speed runs. Named
    //     on `turn/start` alone, the drop says nothing at all.
    func pinnedDriver(_ text: String, model: String, pin: String?) -> CodexAppServerTurn {
        var pinned = options(nil)
        pinned.codexServiceTierOverride = pin
        return CodexAppServerTurn(
            text: text, options: pinned,
            settings: { defaults in
                CodexAppServer.turnSettings(model: model, effort: nil, folderModel: nil, folderEffort: nil,
                                            modelDefaultEffort: { _ in nil }, serviceTier: pin,
                                            defaults: defaults)
            },
            agentName: agent, clientVersion: "harness")!
    }
    let homeHS = makeHome(port: fake.port, model: "gpt-5.5")
    defer { try? FileManager.default.removeItem(at: homeHS) }
    let folderHS = makeFolder()
    let hostHS = HarnessHost(cwd: folderHS)
    _ = await runTurn(pinnedDriver("SIPAI-HS one", model: "gpt-5.5", pin: "ultrafast"),
                      host: hostHS, binary: binary, home: homeHS)
    check("HS. Ultrafast pinned on a model codex's list gives Fast alone: codex says, opening the new session, it will not run it",
          hostHS.speeds == ["ultrafast:false"], "\(hostHS.speeds)")
    check("HS. …and the message goes at standard speed",
          fake.bodies(marked: "SIPAI-HS one").last.map { $0["service_tier"] == nil } == true,
          "\(fake.bodies(marked: "SIPAI-HS one").last?["service_tier"] ?? "no request")")
    _ = await runTurn(pinnedDriver("SIPAI-HS one again", model: "gpt-5.5", pin: "ultrafast"),
                      host: hostHS, binary: binary, home: homeHS)
    check("HS. …the same on the session resumed for the next message",
          hostHS.speeds == ["ultrafast:false", "ultrafast:false"], "\(hostHS.speeds)")
    _ = await runTurn(pinnedDriver("SIPAI-HS one standard", model: "gpt-5.5", pin: CodexSpeed.standard),
                      host: hostHS, binary: binary, home: homeHS)
    check("HS. …a message at standard speed asks nothing and is told nothing",
          hostHS.speeds.count == 2, "\(hostHS.speeds)")
    if let line = twoSpeedLine {
        let homeHT = makeHome(port: fake.port, model: twoSpeed, extraTop: line)
        defer { try? FileManager.default.removeItem(at: homeHT) }
        let hostHT = HarnessHost(cwd: makeFolder())
        _ = await runTurn(pinnedDriver("SIPAI-HS two", model: twoSpeed, pin: "ultrafast"),
                          host: hostHT, binary: binary, home: homeHT)
        _ = await runTurn(pinnedDriver("SIPAI-HS two again", model: twoSpeed, pin: "ultrafast"),
                          host: hostHT, binary: binary, home: homeHT)
        check("HS. Ultrafast pinned on a model whose list has it: codex says it runs it, new and resumed, and it does",
              hostHT.speeds == ["ultrafast:true", "ultrafast:true"]
                && fake.bodies(marked: "SIPAI-HS two").last?["service_tier"] as? String == "ultrafast"
                && fake.bodies(marked: "SIPAI-HS two again").last?["service_tier"] as? String == "ultrafast",
              "\(hostHT.speeds)")
    } else {
        skip("HS. Ultrafast on a model whose list has it", "codex debug models --bundled gave no catalog")
    }

    // U. A compound command: codex's summary of it names one part (the
    // read); the card is what "Yes, proceed" will run.
    let folderU = trusted(makeFolder())
    try? "seed\n".write(to: folderU.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
    let hostU = HarnessHost(cwd: folderU)
    hostU.onCard = { $0.respond(.chose("accept")) }
    _ = await runTurn(driver("SIPAI-TEE go", nil), host: hostU, binary: binary, home: home)
    if case .permission(let content)? = hostU.cards.first?.presentation {
        check("U. a compound command is a card showing ALL of it — codex's own summary of it names only the read",
              content.preview == .command("cat seed.txt | tee \(outside.path)/tee.txt", cwd: folderU.path,
                                          reason: "Copy the seed out?")
                && FileManager.default.fileExists(atPath: outside.path + "/tee.txt"),
              "\(content.preview)")
    } else {
        check("U. a compound command is a card showing all of it", false, "\(hostU.cards.count) cards")
    }

    // T. A config that names NO model: a chip on Default must still state
    // one — codex's own default, read off its model/list answer — or the
    // thread keeps running the model an earlier turn picked.
    let bareHome = makeHome(port: fake.port, model: nil)
    defer { try? FileManager.default.removeItem(at: bareHome) }
    var listAnswer: [String: Any]? = nil
    _ = await converse(binary: binary, cwd: makeFolder(), home: bareHome) { peer in
        _ = try? await peer.request("initialize",
                                    params: CodexAppServer.initializeParams(clientVersion: "harness"), timeout: 15)
        peer.notify("initialized")
        if let result = try? await peer.request("model/list", params: [String: Any](), timeout: 30) {
            listAnswer = ["result": result]
        }
    }
    let ownDefaults = CodexCatalog.listedDefaults(fromAnswer: listAnswer)
    func wired(_ marker: String) -> String {
        let body = fake.bodies(marked: marker).last
        return "\(body?["model"] as? String ?? "-")/\((body?["reasoning"] as? [String: Any])?["effort"] as? String ?? "-")"
    }
    if let ownModel = ownDefaults.model, ownModel != "gpt-5.5" {
        let ownEffort = ownDefaults.efforts[ownModel]
        let picked = CodexAppServer.TurnSettings(model: "gpt-5.5", effort: "high", serviceTier: nil)
        let folderT = makeFolder()
        let hostT = HarnessHost(cwd: folderT)
        _ = await runTurn(driver("SIPAI-WIRE picked", nil, settings: picked),
                          host: hostT, binary: binary, home: bareHome)
        let threadT = hostT.adopted.first
        // The chips back on Default, and SipAI's own reading of the config
        // WRONG (it names the model just picked): codex's answer for the
        // folder is what the turn states.
        _ = await runTurn(driver("SIPAI-WIRE default", nil, folderModel: "gpt-5.5",
                                 modelDefaultEffort: { ownDefaults.efforts[$0] }),
                          host: HarnessHost(cwd: folderT, sessionId: threadT), binary: binary, home: bareHome)
        check("T. with no model configured, a Default chip states codex's own default and its effort — and that is what runs",
              wired("SIPAI-WIRE picked") == "gpt-5.5/high"
                && wired("SIPAI-WIRE default") == "\(ownModel)/\(ownEffort ?? "-")",
              "picked \(wired("SIPAI-WIRE picked")), default \(wired("SIPAI-WIRE default")), codex's own \(ownModel)/\(ownEffort ?? "-")")
        // The control: the picked turn again, then a turn that states no
        // model at all — spoken by hand, since the driver always states one.
        _ = await runTurn(driver("SIPAI-WIRE again", nil, settings: picked),
                          host: HarnessHost(cwd: folderT, sessionId: threadT), binary: binary, home: bareHome)
        _ = await converse(binary: binary, cwd: folderT, home: bareHome) { peer in
            _ = try? await peer.request("initialize",
                                        params: CodexAppServer.initializeParams(clientVersion: "harness"), timeout: 15)
            peer.notify("initialized")
            var done = false
            peer.onNotification = { method, _ in if method == "turn/completed" { done = true } }
            guard let threadT,
                  (try? await peer.request("thread/resume",
                                           params: CodexAppServer.plainResumeParams(threadId: threadT, cwd: folderT.path),
                                           timeout: 30)) != nil else { return }
            _ = try? await peer.request("turn/start", params: [
                "threadId": threadT, "input": [["type": "text", "text": "SIPAI-WIRE unstated"]]] as [String: Any],
                                        timeout: 30)
            let deadline = Date().addingTimeInterval(60)
            while !done, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        check("T. …the control: left unstated, the turn runs the model the turn before it picked",
              wired("SIPAI-WIRE unstated").hasPrefix("gpt-5.5/"), wired("SIPAI-WIRE unstated"))
        _ = execTurn(binary: binary, cwd: folderT, home: bareHome, resume: threadT, prompt: "SIPAI-WIRE headless")
        check("T. …and codex's own default is what a headless turn runs there, so the two rows agree",
              wired("SIPAI-WIRE headless") == "\(ownModel)/\(ownEffort ?? "-")", wired("SIPAI-WIRE headless"))
    } else {
        skip("T. a Default chip with no model configured",
             "codex's model/list named no default of its own here (\(ownDefaults.model ?? "none"))")
    }

    // S. A skill of a SUBFOLDER of the session's folder: codex lists it, and
    // the mention line loads it, only once the turn hands codex that
    // subfolder's skills folder (`skills/extraRoots/set`). The control is
    // the same mention without it.
    let folderS = trusted(makeFolder())
    let skillS = folderS.appendingPathComponent("pkg/.agents/skills/sipai-subskill")
    try? FileManager.default.createDirectory(at: skillS, withIntermediateDirectories: true)
    try? "---\nname: sipai-subskill\ndescription: A subfolder's skill.\n---\n\nSIPAI-SUBSKILL-BODY-3\n"
        .write(to: skillS.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let realSkill = SkillScan.realPath(skillS.appendingPathComponent("SKILL.md").path) ?? ""
    let realRoot = (realSkill as NSString).deletingLastPathComponent.isEmpty ? ""
        : ((realSkill as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    func subfolderTurn(_ marker: String, roots: [String]) -> CodexAppServerTurn {
        CodexAppServerTurn(
            text: "[$sipai-subskill](\(realSkill))\n\n\(marker) go", options: options(nil),
            extraSkillRoots: roots,
            settings: { defaults in
                CodexAppServer.turnSettings(model: nil, effort: nil, folderModel: nil, folderEffort: nil,
                                            modelDefaultEffort: { _ in nil }, serviceTier: nil, defaults: defaults)
            },
            agentName: agent, clientVersion: "harness")!
    }
    // Every request a turn made — codex puts the skill it injects AFTER the
    // user's words, so the newest user message is the skill, not the marker.
    func requestsText(since from: Int) -> [String] {
        fake.requests().dropFirst(from).compactMap { $0["body"] }.map(jsonText)
    }
    let hostSub = HarnessHost(cwd: folderS)
    var sentBefore = fake.requests().count
    _ = await runTurn(subfolderTurn("SIPAI-WIRE subfolder-on", roots: [realRoot]), host: hostSub,
                      binary: binary, home: home)
    let withRoots = requestsText(since: sentBefore).filter { $0.contains("subfolder-on go") }
    sentBefore = fake.requests().count
    _ = await runTurn(subfolderTurn("SIPAI-WIRE subfolder-off", roots: []), host: HarnessHost(cwd: folderS),
                      binary: binary, home: home)
    let withoutRoots = requestsText(since: sentBefore).filter { $0.contains("subfolder-off go") }
    check("S. a subfolder's skill loads through the app-server once its skills folder is handed over",
          !realSkill.isEmpty && withRoots.contains { $0.contains("SIPAI-SUBSKILL-BODY-3") },
          "\(withRoots.count) requests, root \(realRoot); events \(hostSub.events.map(signature))")
    check("S. …and the same mention without it loads nothing (the control)",
          !withoutRoots.isEmpty && !withoutRoots.contains { $0.contains("SIPAI-SUBSKILL-BODY-3") },
          "\(withoutRoots.count) requests")

    // I. A provider that refuses: codex's words, once, as the turn's end.
    let hostI = HarnessHost(cwd: trusted(makeFolder()))
    _ = await runTurn(driver("SIPAI-E400 go", nil), host: hostI, binary: binary, home: home)
    check("I. a refused request is one error row in codex's words",
          hostI.signatures.filter { $0.hasPrefix("error:") }.count == 1
            && hostI.signatures.contains { $0.hasPrefix("error:") && $0.contains("scripted 400") },
          "\(hostI.signatures)")

    // J. Stopped before the turn: nothing is named, nothing is asked, nothing is left on disk.
    let hostJ = HarnessHost(cwd: trusted(makeFolder()))
    hostJ.live = false
    let before = fake.requests().count
    _ = await runTurn(driver("SIPAI-WIRE never", nil), host: hostJ, binary: binary, home: home)
    check("J. a turn stopped before it starts leaves no session behind",
          hostJ.adopted.isEmpty && fake.requests().count == before)

    // K. The same turn through codex exec and through the app-server reads the same.
    let folderK = trusted(makeFolder())
    let execLines = execTurn(binary: binary, cwd: folderK, home: home, resume: nil, prompt: "SIPAI-PAIR exec")
    let execSignatures = execLines.flatMap {
        CodexEventParser.parse(line: $0, fallbackCwd: folderK).events.map(signature)
    }.filter { $0 != "init" }
    try? FileManager.default.removeItem(at: folderK.appendingPathComponent("made.txt"))
    let hostK = HarnessHost(cwd: folderK)
    _ = await runTurn(driver("SIPAI-PAIR app", nil), host: hostK, binary: binary, home: home)
    check("K. a turn's rows through the app-server are the rows codex exec's own output gives",
          !execSignatures.isEmpty && hostK.signatures == execSignatures,
          "exec \(execSignatures)\n       app  \(hostK.signatures)")

    // V. Default is codex's OWN default for the folder, asked of codex every
    //    turn: read-only in a folder the config does not trust…
    let hostL = HarnessHost(cwd: makeFolder())
    _ = await runTurn(driver("SIPAI-WIRE untrusted", nil), host: hostL, binary: binary, home: home)
    check("V. a Default turn in an untrusted folder runs codex's own default there: on-request, read-only",
          turnPermissions(home: home, id: hostL.adopted.first ?? "-") == ["on-request/read-only"],
          "\(turnPermissions(home: home, id: hostL.adopted.first ?? "-"))")
    //    …and a thread whose last turn ran Full Access does not keep it: the
    //    control is the thread's own memory, which a turn stating nothing
    //    would inherit (measured: `never`).
    let folderL2 = trusted(makeFolder())
    let fullLines = execTurn(binary: binary, cwd: folderL2, home: home, resume: nil,
                             prompt: "SIPAI-WIRE full", permissions: ["--dangerously-bypass-approvals-and-sandbox"])
    let threadL2 = fullLines.compactMap { line -> String? in
        guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              event["type"] as? String == "thread.started" else { return nil }
        return event["thread_id"] as? String
    }.first
    if let threadL2 {
        _ = await runTurn(driver("SIPAI-WIRE after full", nil),
                          host: HarnessHost(cwd: folderL2, sessionId: threadL2), binary: binary, home: home)
        let ran = turnPermissions(home: home, id: threadL2)
        check("V. after a Full Access turn, a Default turn on the same thread runs codex's own default, not the thread's last",
              ran == ["never/danger-full-access", "on-request/workspace-write"], "\(ran)")
    } else {
        check("V. the Full Access turn ran and named its thread", false, "\(fullLines.prefix(3))")
    }

    // W. What a turn leaves on Default is codex's OWN answer for the folder,
    //    not SipAI's reading of the config — the run a scheduled task on
    //    Default makes in a folder SipAI never asked codex about. The speed
    //    and the effort the config names…
    let listedModels = (listAnswer?["result"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
    let tierModel = listedModels.first { entry in
        (entry["serviceTiers"] as? [Any] ?? []).contains {
            (($0 as? [String: Any])?["id"] as? String ?? $0 as? String) == "priority"
        }
    }.flatMap { ($0["model"] as? String) ?? ($0["id"] as? String) }
    func wiredTier(_ marker: String) -> String {
        let body = fake.bodies(marked: marker).last
        return "\(body?["service_tier"] as? String ?? "-")/\((body?["reasoning"] as? [String: Any])?["effort"] as? String ?? "-")"
    }
    if let tierModel {
        let homeW = makeHome(port: fake.port, model: tierModel,
                             extraTop: "service_tier = \"priority\"\nmodel_reasoning_effort = \"high\"")
        defer { try? FileManager.default.removeItem(at: homeW) }
        let folderW = makeFolder()
        trust(folderW, in: homeW)
        let hostW = HarnessHost(cwd: folderW)
        _ = await runTurn(driver("SIPAI-WIRE tier-new", nil), host: hostW, binary: binary, home: homeW)
        let threadW = hostW.adopted.first
        check("W. a turn that pins no speed and picks no effort runs the config's own, as codex exec does — a new thread",
              wiredTier("SIPAI-WIRE tier-new") == "priority/high", wiredTier("SIPAI-WIRE tier-new"))
        _ = await runTurn(driver("SIPAI-WIRE tier-pinned", nil,
                                 settings: CodexAppServer.TurnSettings(effort: "low", serviceTier: "default")),
                          host: HarnessHost(cwd: folderW, sessionId: threadW), binary: binary, home: homeW)
        _ = await runTurn(driver("SIPAI-WIRE tier-resumed", nil),
                          host: HarnessHost(cwd: folderW, sessionId: threadW), binary: binary, home: homeW)
        check("W. …a pinned Standard and a picked effort stand, and the turn after them is back on the config's — a resumed thread",
              !wiredTier("SIPAI-WIRE tier-pinned").hasPrefix("priority/")
                && wiredTier("SIPAI-WIRE tier-pinned").hasSuffix("/low")
                && wiredTier("SIPAI-WIRE tier-resumed") == "priority/high",
              "pinned \(wiredTier("SIPAI-WIRE tier-pinned")), resumed \(wiredTier("SIPAI-WIRE tier-resumed"))")
        _ = execTurn(binary: binary, cwd: folderW, home: homeW, resume: nil, prompt: "SIPAI-WIRE tier-exec")
        check("W. …which is what a headless turn stating nothing runs there, so the two agree",
              wiredTier("SIPAI-WIRE tier-exec") == "priority/high", wiredTier("SIPAI-WIRE tier-exec"))
    } else {
        skip("W. a Default turn under a configured speed", "codex's model/list named no model with a priority tier")
    }
    //    …and a trusted project's own model, over the user file's.
    if let projectModel = ownDefaults.model, projectModel != "gpt-5.5" {
        let folderX = trusted(makeFolder())
        try? FileManager.default.createDirectory(at: folderX.appendingPathComponent(".codex"),
                                                 withIntermediateDirectories: true)
        try? "model = \"\(projectModel)\"\n".write(to: folderX.appendingPathComponent(".codex/config.toml"),
                                                   atomically: true, encoding: .utf8)
        _ = await runTurn(driver("SIPAI-WIRE project", nil, folderModel: "gpt-5.5"),
                          host: HarnessHost(cwd: folderX), binary: binary, home: home)
        check("W. a trusted project's own model is what a Default chip runs, though SipAI's reading names the user file's",
              wired("SIPAI-WIRE project").hasPrefix("\(projectModel)/"), wired("SIPAI-WIRE project"))
    } else {
        skip("W. a trusted project's own model", "no second model to name")
    }

    // X. A permission profile of the user's own stays in force on a resumed
    //    Default turn: stated back as the profile, where a legacy sandbox
    //    mode stated over it would replace it with plain workspace-write.
    let extraX = outside.appendingPathComponent("profile-root")
    try? FileManager.default.createDirectory(at: extraX, withIntermediateDirectories: true)
    let homeX = makeHome(port: fake.port, extraTop: "default_permissions = \"mine\"", extraTail: """
    [permissions.mine.filesystem]
    ":root" = "read"
    "\(extraX.path)" = "write"
    """)
    defer { try? FileManager.default.removeItem(at: homeX) }
    let folderX2 = makeFolder()
    trust(folderX2, in: homeX)
    let hostX = HarnessHost(cwd: folderX2)
    _ = await runTurn(driver("SIPAI-WIRE profile-new", nil), host: hostX, binary: binary, home: homeX)
    if let threadX = hostX.adopted.first {
        let first = lastTurnProfile(home: homeX, id: threadX)
        _ = execTurn(binary: binary, cwd: folderX2, home: homeX, resume: threadX, prompt: "SIPAI-WIRE profile-full",
                     permissions: ["--dangerously-bypass-approvals-and-sandbox"])
        _ = await runTurn(driver("SIPAI-WIRE profile-resumed", nil),
                          host: HarnessHost(cwd: folderX2, sessionId: threadX), binary: binary, home: homeX)
        let resumedProfile = lastTurnProfile(home: homeX, id: threadX)
        check("X. the user's own permission profile is in force on a new thread and still on a resumed one, after a Full Access turn",
              first.profile == "mine" && resumedProfile.profile == "mine" && resumedProfile.sandbox == first.sandbox
                && turnPermissions(home: homeX, id: threadX).last?.hasPrefix("on-request/") == true,
              "new \(first), resumed \(resumedProfile), turns \(turnPermissions(home: homeX, id: threadX))")
    } else {
        check("X. a Default turn under a permission profile ran", false, "\(hostX.signatures)")
    }

    // Y. The thread a resumed turn asks for codex's defaults is gone before
    //    the turn: while a card is up, the session's own writer lock is the
    //    only one held (left loaded, the asking thread holds a second, and
    //    a second set of the user's MCP servers with it).
    let folderY = trusted(makeFolder())
    let hostY1 = HarnessHost(cwd: folderY)
    _ = await runTurn(driver("SIPAI-WIRE lock-new", nil), host: hostY1, binary: binary, home: home)
    if let threadY = hostY1.adopted.first {
        let hostY = HarnessHost(cwd: folderY, sessionId: threadY)
        var locksAtCard: [String]? = nil
        hostY.onCard = { card in
            locksAtCard = writerLocks(home: home)
            card.respond(.chose("accept"))
        }
        _ = await runTurn(driver("SIPAI-C lock-resumed", nil), host: hostY, binary: binary, home: home)
        check("Y. a resumed turn holds ONE thread open — the session's — once it has asked codex for its defaults",
              locksAtCard == ["\(threadY).lock"] && hostY.signatures.contains("turn-result"),
              "locks at the card \(String(describing: locksAtCard)), \(hostY.signatures)")
    } else {
        check("Y. the session to resume was made", false, "\(hostY1.signatures)")
    }

    // AQ. A question codex asks WITHOUT stopping — the question tool codex
    //     hands its GPT-6 models in every mode (`request_user_input_async`):
    //     a card while the turn runs, which the turn's clock does not wait
    //     on; the answer steered into the SAME turn in codex's own reply,
    //     drawn as the user's reply; the card gone once the turn is over,
    //     when codex can no longer take it.
    let astra = CodexAppServer.TurnSettings(model: "gpt-6-astra", effort: nil, serviceTier: nil)
    func newestUserText(_ body: [String: Any]?) -> String? {
        let input = body?["input"] as? [[String: Any]] ?? []
        guard let user = input.last(where: { $0["type"] as? String == "message" && $0["role"] as? String == "user" })
        else { return nil }
        return (user["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }
    func taskStarts(_ id: String) -> Int {
        guard let url = rollout(home: home, id: id),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return -1 }
        return text.components(separatedBy: "\"task_started\"").count - 1
    }
    func historyRows(_ items: [AgentSessionHistoryItem]) -> [String] {
        items.compactMap { item in
            switch item.kind {
            case .userText(let t): return (item.sentIntoTurn ? "reply:" : "user:") + t
            case .assistantText(let t): return "assistant:" + t.trimmingCharacters(in: .whitespacesAndNewlines)
            default: return nil
            }
        }
    }
    func liveRows(_ events: [StreamEvent]) -> [String] {
        events.compactMap { event in
            switch event.kind {
            case .userMessage(let t): return (event.sentIntoTurn ? "reply:" : "user:") + t
            case .assistantText(let t): return "assistant:" + t.trimmingCharacters(in: .whitespacesAndNewlines)
            default: return nil
            }
        }
    }
    let questionRow = "assistant:Which database should the app use?\n- Postgres (Recommended)\n- SQLite\n\nAnything else I should know?"
    let replyRow = "reply:> Which database should the app use?\n\nSQLite\n\n> Anything else I should know?\n\nSIPAI-ASYNCQ-REPLY please"
    let envelopesBefore = fake.bodies(marked: "<send_user_message_question_reply>").count

    let folderAQ = trusted(makeFolder())
    let hostAQ = HarnessHost(cwd: folderAQ)
    hostAQ.onCard = { card in
        var own = AgentQuestionAnswer()
        own.otherPicked = true
        own.otherText = "SIPAI-ASYNCQ-REPLY please"
        card.respond(.answered(["Which database should the app use?": AgentQuestionAnswer(labels: ["SQLite"]),
                                "Anything else I should know?": own]))
    }
    _ = await runTurn(driver("SIPAI-ASYNCQ go", nil, settings: astra), host: hostAQ, binary: binary, home: home)
    let threadAQ = hostAQ.adopted.first ?? ""
    let cardAQ = hostAQ.cards.first
    check("AQ1. the question is a card the turn does not wait on, filed by codex's own question ids",
          hostAQ.cards.count == 1 && cardAQ?.presentation == .question && cardAQ?.turnWaits == false
            && cardAQ?.toolName == "request_user_input_async"
            && cardAQ?.question?.questions.map(\.id) == [#"["request_user_input_async","call_asyncq",0]"#,
                                                         #"["request_user_input_async","call_asyncq",1]"#],
          "\(hostAQ.cards.count) cards, \(String(describing: cardAQ?.question?.questions.map(\.id)))")
    let replyAQ = "<send_user_message_question_reply>\n"
        + #"[{"answer":"SQLite","question":"Which database should the app use?","questionItemId":"[\"request_user_input_async\",\"call_asyncq\",0]"},"#
        + #"{"answer":"SIPAI-ASYNCQ-REPLY please","question":"Anything else I should know?","questionItemId":"[\"request_user_input_async\",\"call_asyncq\",1]"}]"#
        + "\n</send_user_message_question_reply>"
    check("AQ2. the answer reached the model in the SAME turn, as codex's own reply, byte for byte",
          newestUserText(fake.bodies(marked: "SIPAI-ASYNCQ-REPLY").first) == replyAQ
            && taskStarts(threadAQ) == 1
            && hostAQ.signatures.contains("assistant:GOT THE REPLY") && hostAQ.signatures.last == "turn-result",
          "\(String(describing: newestUserText(fake.bodies(marked: "SIPAI-ASYNCQ-REPLY").first))), turns \(taskStarts(threadAQ)), \(hostAQ.signatures)")
    let rowsAQ = liveRows(hostAQ.events)
    if let q = rowsAQ.firstIndex(of: questionRow), let r = rowsAQ.firstIndex(of: replyRow),
       let a = rowsAQ.firstIndex(of: "assistant:GOT THE REPLY") {
        check("AQ3. drawn as it happened: the question, the user's reply under it, then the answer to the reply",
              q < r && r < a && hostAQ.events.filter(\.sentIntoTurn).count == 1, "\(rowsAQ)")
    } else {
        check("AQ3. drawn as it happened: the question, the user's reply, then the answer to it", false, "\(rowsAQ)")
    }
    // The runner's buffer the moment codex's echo of the answer lands: the
    // prompt's row (the runner draws it at the send), then the driver's.
    // The turn goes on, so no waiting row comes back under the answer —
    // where a walk that stops at any user row (the control) put "Sipping…"
    // under it, as though a new message had been sent.
    if let reply = hostAQ.events.firstIndex(where: \.sentIntoTurn) {
        let buffer = [StreamEvent(kind: .userMessage(text: "SIPAI-ASYNCQ go"))] + hostAQ.events[...reply]
        let walkStoppingAtAnyUserRow: Bool = {
            for event in buffer.reversed() {
                switch event.kind {
                case .userMessage: return true
                case .systemInit, .compaction: continue
                default: return false
                }
            }
            return true
        }()
        check("AQ3b. no waiting row under the answer: the turn goes on (a walk stopping at any user row puts one there)",
              !WaitingRow.awaitsAgent(buffer, compactionIsOutput: false)
                && !WaitingRow.awaitsAgent(buffer, compactionIsOutput: true)
                && WaitingRow.awaitsAgent(Array(buffer.prefix(1)), compactionIsOutput: false)
                && walkStoppingAtAnyUserRow,
              "\(liveRows(Array(buffer)))")
    } else {
        check("AQ3b. the answer is in the live rows", false, "\(rowsAQ)")
    }
    if let url = rollout(home: home, id: threadAQ) {
        let reopened = historyRows(CodexSessionScanner.readHistory(of: url, root: home.appendingPathComponent("sessions")))
        check("AQ4. reopened, the session reads exactly as it was drawn live — the question, the reply, the answer",
              reopened.first == "user:SIPAI-ASYNCQ go" && Array(reopened.dropFirst()) == rowsAQ,
              "reopened \(reopened)\n       live     \(rowsAQ)")
    } else {
        check("AQ4. the session's record is on disk", false)
    }

    let hostAR = HarnessHost(cwd: trusted(makeFolder()))
    _ = await runTurn(driver("SIPAI-ASYNCQ left", nil, settings: astra), host: hostAR, binary: binary, home: home)
    check("AQ5. a card left open goes when the turn is over — codex can no longer take its answer",
          hostAR.cards.count == 1 && hostAR.withdrawn == ["card-1"]
            && hostAR.signatures.contains("assistant:DONE ASYNCQ") && hostAR.signatures.last == "turn-result",
          "withdrawn \(hostAR.withdrawn), \(hostAR.signatures)")
    // What the user had started on it comes back for the message box (the
    // bridge hands it to the runner when the card is withdrawn; see
    // Verification/AskingBridge), in the shape Codex's own terminal hands
    // an unsent answer back: here on the card the REAL codex asked.
    var startedAR = AgentQuestionAnswer()
    startedAR.otherPicked = true
    startedAR.otherText = "  no rush  "
    let backAR = hostAR.cards.first?.question?.unsentAnswersText(AgentQuestionDraft(answers: [
        "Which database should the app use?": AgentQuestionAnswer(labels: ["SQLite"]),
        "Anything else I should know?": startedAR]))
    check("AQ5. …and the answers started on it come back in Codex's own terminal's shape: each question quoted, then the answer",
          backAR == "> Which database should the app use?\n\nSQLite\n\n> Anything else I should know?\n\nno rush",
          "\(String(describing: backAR))")

    let hostAS = HarnessHost(cwd: trusted(makeFolder()))
    hostAS.onCard = { $0.respond(.skipped) }
    _ = await runTurn(driver("SIPAI-ASYNCQ skip", nil, settings: astra), host: hostAS, binary: binary, home: home)
    let hostAT = HarnessHost(cwd: trusted(makeFolder()))
    hostAT.onCard = { $0.respond(.cancelled) }
    _ = await runTurn(driver("SIPAI-ASYNCQ cancel", nil, settings: astra), host: hostAT, binary: binary, home: home)
    check("AQ6. Skip and a cancelled card send nothing; the turn goes on to its end without a row of SipAI's",
          fake.bodies(marked: "<send_user_message_question_reply>").count == envelopesBefore + 1
            && [hostAS, hostAT].allSatisfy { host in
                host.signatures.contains("assistant:DONE ASYNCQ") && host.signatures.last == "turn-result"
                    && !host.signatures.contains { $0.hasPrefix("error:") || $0.hasPrefix("user:") }
            },
          "\(hostAS.signatures) / \(hostAT.signatures)")
    check("AQ6. …and a card answered the moment it was put up is not up: nothing is withdrawn at the turn's end",
          hostAS.withdrawn.isEmpty && hostAT.withdrawn.isEmpty,
          "\(hostAS.withdrawn) / \(hostAT.withdrawn)")

    // A headless turn cannot be steered: codex exec prints the question as
    // its text (no questions field), and the reopened record must read the
    // same — it holds the question only as an `item_completed` message.
    let folderAE = trusted(makeFolder())
    let execAQ = execTurn(binary: binary, cwd: folderAE, home: home, resume: nil, prompt: "SIPAI-ASYNCQ exec",
                          permissions: ["-c", #"sandbox_mode="workspace-write""#, "-c", #"model="gpt-6-astra""#])
    let execRowsAQ = liveRows(execAQ.flatMap { CodexEventParser.parse(line: $0, fallbackCwd: folderAE).events })
    let execThread = execAQ.first.flatMap { json($0)["thread_id"] as? String } ?? ""
    let reopenedExec = rollout(home: home, id: execThread).map {
        historyRows(CodexSessionScanner.readHistory(of: $0, root: home.appendingPathComponent("sessions")))
    } ?? []
    check("AQ7. a headless turn draws the question as codex exec prints it, and reopened it reads the same",
          execRowsAQ == [questionRow, "assistant:DONE ASYNCQ"]
            && reopenedExec == ["user:SIPAI-ASYNCQ exec"] + execRowsAQ,
          "exec \(execRowsAQ)\n       reopened \(reopenedExec)")

    // M. The child gone mid-turn, a card up: the driver returns at once and
    //    leaves the conversation CLOSED — which is what tells the runner the
    //    protocol was not done with the turn, and to report the child's exit.
    //    The whole GROUP is killed: an npm-installed codex is a node script
    //    that starts the real binary, and that binary holds the pipes — the
    //    group is also what the runner's own terminate() signals.
    let hostM = HarnessHost(cwd: trusted(makeFolder()))
    var childM: Process?
    hostM.onCard = { _ in if let pid = childM?.processIdentifier { kill(-pid, SIGKILL) } }
    let driverM = driver("SIPAI-F killed", nil)
    let runM = await converse(binary: binary, cwd: hostM.cwd, home: home, onSpawn: { child in
        childM = child
        // Whatever this scenario finds, it ends: a driver that never
        // returned would otherwise hold the whole harness.
        let pid = child.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { kill(-pid, SIGKILL) }
    }) { peer in
        await driverM.run(peer: peer, host: hostM)
    }
    check("M. codex killed with a card up: the driver returns at once, the conversation closed under it",
          hostM.cards.count == 1 && runM.closedUnderBody && runM.bodySeconds < 10
            && !hostM.signatures.contains("turn-result"),
          "cards \(hostM.cards.count), closed \(runM.closedUnderBody), \(runM.bodySeconds) s, \(hostM.signatures)")

    // N–R. The answers the real app-server cannot be made to give, from the
    //      stand-in (stub_server.py).
    let hostN = HarnessHost(cwd: trusted(makeFolder()))
    let runN = await runStubTurn(driver("refuse me", nil), host: hostN,
                                 mode: "refuse-turn", home: home)
    check("N. a refused turn/start: codex's words as the row, and the thread is NOT adopted — it has no rollout to open again",
          hostN.adopted.isEmpty && hostN.sessionId == nil
            && hostN.signatures == ["error:Invalid request: scripted refusal"] && !runN.closedUnderBody,
          "adopted \(hostN.adopted), \(hostN.signatures)")
    let hostMute = HarnessHost(cwd: trusted(makeFolder()))
    _ = await runStubTurn(driver("refuse me quietly", nil), host: hostMute,
                          mode: "mute-turn", home: home)
    check("N. …refused with NO words: still one row, saying so, and still nothing adopted",
          hostMute.adopted.isEmpty && hostMute.signatures == ["error:\(agent) reported an error but gave no detail."],
          "adopted \(hostMute.adopted), \(hostMute.signatures)")
    // A codex that will not take a subfolder's skills folders — one that
    // does not know the call (refused), one that never answers it. The
    // mention would then load nothing and say nothing: so it is SAID, the
    // row stops naming the skill, the message goes without the mention,
    // and the turn itself runs. (An unanswered call used to end the turn
    // with no row at all.)
    func rootsTurn(timeout: TimeInterval) -> CodexAppServerTurn {
        let turn = CodexAppServerTurn(
            text: "[$sub-skill](/w/pkg/.agents/skills/sub-skill/SKILL.md)\n\nload it and go",
            options: options(nil), extraSkillRoots: ["/w/pkg/.agents/skills"],
            subfolderSkills: ["sub-skill"], textWithoutSubfolderSkills: "load it and go",
            settings: { defaults in
                CodexAppServer.turnSettings(model: nil, effort: nil, folderModel: nil, folderEffort: nil,
                                            modelDefaultEffort: { _ in nil }, serviceTier: nil, defaults: defaults)
            },
            agentName: agent, clientVersion: "harness")!
        turn.extraRootsTimeout = timeout
        return turn
    }
    func sentText(_ log: URL) -> String {
        stubLog(log).last { $0.method == "turn/start" }.map { jsonText($0.params["input"] ?? "") } ?? ""
    }
    let logRefused = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cxas-roots-\(UUID().uuidString).log")
    let hostRefused = HarnessHost(cwd: trusted(makeFolder()))
    _ = await runStubTurn(rootsTurn(timeout: 10), host: hostRefused, mode: "ok", home: home, log: logRefused)
    check("Z. a codex that refuses the subfolder's skills folders: said in its words, the row's claim taken back, the turn run",
          hostRefused.signatures.first == "error:\(agent) couldn’t be given the subfolder’s skills: Method not found: skills/extraRoots/set"
            && hostRefused.signatures.last == "turn-result"
            && hostRefused.retracted == [["sub-skill"]],
          "\(hostRefused.signatures) retracted \(hostRefused.retracted)")
    check("Z. …and the message goes without the mention that would have loaded nothing",
          sentText(logRefused).contains("load it and go") && !sentText(logRefused).contains("$sub-skill"),
          sentText(logRefused))
    let logMute = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cxas-roots-\(UUID().uuidString).log")
    let hostMuteRoots = HarnessHost(cwd: trusted(makeFolder()))
    _ = await runStubTurn(rootsTurn(timeout: 1), host: hostMuteRoots, mode: "mute-roots", home: home, log: logMute)
    check("Z. a codex that never answers the call: still said, still taken back, and the turn still run — never ended with no row",
          hostMuteRoots.signatures.first == "error:\(agent) couldn’t be given the subfolder’s skills, so your message was sent without them."
            && hostMuteRoots.signatures.last == "turn-result"
            && hostMuteRoots.retracted == [["sub-skill"]]
            && !sentText(logMute).contains("$sub-skill"),
          "\(hostMuteRoots.signatures) retracted \(hostMuteRoots.retracted) sent \(sentText(logMute))")
    try? FileManager.default.removeItem(at: logRefused)
    try? FileManager.default.removeItem(at: logMute)
    let hostO = HarnessHost(cwd: trusted(makeFolder()))
    _ = await runStubTurn(driver("accept me", nil), host: hostO, mode: "ok", home: home)
    check("N. control: an accepted turn adopts the thread, once, and completes",
          hostO.adopted == ["stub-thread-1"] && hostO.signatures == ["turn-result"], "\(hostO.adopted) \(hostO.signatures)")
    let hostP = HarnessHost(cwd: trusted(makeFolder()))
    _ = await runStubTurn(driver("no id", nil), host: hostP, mode: "no-thread-id", home: home)
    check("O. a thread opened without an id: one row saying so, nothing adopted, no turn started",
          hostP.adopted.isEmpty && hostP.signatures.count == 1
            && hostP.signatures.first?.hasPrefix("error:The installed Codex answered") == true,
          "\(hostP.signatures)")
    let hostP2 = HarnessHost(cwd: trusted(makeFolder()))
    _ = await runStubTurn(driver("no permissions", nil), host: hostP2, mode: "no-permissions", home: home)
    check("O. codex's own default permissions not stated: one row saying so, nothing adopted — never a turn on the thread's own",
          hostP2.adopted.isEmpty && hostP2.signatures.count == 1
            && hostP2.signatures.first?.hasPrefix("error:The installed Codex answered") == true,
          "\(hostP2.signatures)")
    // The resumed path, against the stand-in: what is asked, in what order,
    // and of which thread.
    func stubLogFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cxas-stub-\(UUID().uuidString).log")
    }
    let logR = stubLogFile()
    let hostR1 = HarnessHost(cwd: trusted(makeFolder()), sessionId: "sess-9")
    _ = await runStubTurn(driver("resume me", nil), host: hostR1, mode: "ok", home: home, log: logR)
    let askedR = stubLog(logR)
    check("O. a resumed turn asks codex for its defaults on a thread of its own, deletes THAT thread, then resumes and runs the session's",
          askedR.map(\.method) == ["initialize", "thread/start", "thread/delete", "thread/resume", "turn/start"]
            && askedR[2].params["threadId"] as? String == "stub-thread-1"
            && askedR[3].params["threadId"] as? String == "sess-9"
            && askedR[4].params["threadId"] as? String == "sess-9"
            && hostR1.adopted.isEmpty && hostR1.signatures == ["turn-result"],
          "\(askedR.map { "\($0.method) \($0.params["threadId"] as? String ?? "")" }), \(hostR1.signatures)")
    let logOld = stubLogFile()
    let hostOld = HarnessHost(cwd: trusted(makeFolder()), sessionId: "sess-9")
    _ = await runStubTurn(driver("resume me", nil), host: hostOld, mode: "old-server", home: home, log: logOld)
    check("O. …a codex that does not know the delete refuses it, and the turn runs all the same",
          stubLog(logOld).map(\.method).suffix(3) == ["thread/delete", "thread/resume", "turn/start"]
            && hostOld.signatures == ["turn-result"], "\(stubLog(logOld).map(\.method)), \(hostOld.signatures)")
    let logSame = stubLogFile()
    let hostSame = HarnessHost(cwd: trusted(makeFolder()), sessionId: "stub-thread-1")
    _ = await runStubTurn(driver("resume me", nil), host: hostSame, mode: "ok", home: home, log: logSame)
    check("O. …and the session's own thread is never the one deleted",
          !stubLog(logSame).contains { $0.method == "thread/delete" } && hostSame.signatures == ["turn-result"],
          "\(stubLog(logSame).map(\.method))")
    let logProfile = stubLogFile()
    let hostProfile = HarnessHost(cwd: trusted(makeFolder()), sessionId: "sess-9")
    _ = await runStubTurn(driver("resume me", nil, folderModel: "gpt-reading"), host: hostProfile,
                          mode: "profile", home: home, log: logProfile)
    let askedProfile = stubLog(logProfile)
    let resumeProfile = askedProfile.first { $0.method == "thread/resume" }?.params ?? [:]
    let turnProfile = askedProfile.first { $0.method == "turn/start" }?.params ?? [:]
    check("O. a profile in force goes back as the profile; the model, effort and speed stated are codex's answer for the folder, not the resumed thread's",
          resumeProfile["permissions"] as? String == "mine" && resumeProfile["sandbox"] == nil
            && turnProfile["model"] as? String == "gpt-stub" && turnProfile["effort"] as? String == "high"
            && turnProfile["serviceTier"] as? String == "priority",
          "resume \(jsonText(resumeProfile)), turn model \(turnProfile["model"] ?? "-") effort \(turnProfile["effort"] ?? "-") tier \(turnProfile["serviceTier"] ?? "-")")
    let logNoPerm = stubLogFile()
    let hostNoPerm = HarnessHost(cwd: trusted(makeFolder()), sessionId: "sess-9")
    _ = await runStubTurn(driver("resume me", nil), host: hostNoPerm, mode: "no-permissions", home: home, log: logNoPerm)
    check("O. a resumed turn whose defaults cannot be read: one row saying so, and the session's thread is never opened or given a turn",
          hostNoPerm.signatures.count == 1
            && hostNoPerm.signatures.first?.hasPrefix("error:The installed Codex answered") == true
            && !stubLog(logNoPerm).contains { $0.method == "thread/resume" || $0.method == "turn/start" },
          "\(hostNoPerm.signatures), \(stubLog(logNoPerm).map(\.method))")
    let hostQ = HarnessHost(cwd: trusted(makeFolder()))
    _ = await runStubTurn(driver("plan it", AgentAskingMode.codexPlan), host: hostQ, mode: "no-model", home: home)
    check("P. no model to state the mode with: the turn is not sent — Plan never runs as an editing turn",
          hostQ.adopted.isEmpty && hostQ.signatures.count == 1
            && hostQ.signatures.first?.hasPrefix("error:The installed Codex answered") == true,
          "\(hostQ.signatures)")
    let hostQ2 = HarnessHost(cwd: trusted(makeFolder()))
    _ = await runStubTurn(driver("plan it", AgentAskingMode.codexPlan,
                                 settings: CodexAppServer.TurnSettings(model: "gpt-pick")),
                          host: hostQ2, mode: "no-model", home: home)
    check("P. control: with the chip's own model the same turn goes",
          hostQ2.adopted == ["stub-thread-1"] && hostQ2.signatures == ["turn-result"], "\(hostQ2.signatures)")
    let hostR = HarnessHost(cwd: trusted(makeFolder()))
    _ = await runStubTurn(driver("ask me", nil), host: hostR, mode: "undrawable", home: home)
    check("Q. a request with no answer SipAI offers is never a card; answered cancel, the turn's end still has a row",
          hostR.cards.isEmpty
            && hostR.signatures == ["interrupted:Interrupted — this turn was stopped before it finished."],
          "cards \(hostR.cards.count), \(hostR.signatures)")
    let hostS = HarnessHost(cwd: trusted(makeFolder()))
    let runS = await runStubTurn(driver("die on me", nil), host: hostS, mode: "die", home: home)
    check("R. a server that exits mid-turn: the driver returns at once, the conversation closed, its exit and words the runner's to report",
          runS.closedUnderBody && runS.bodySeconds < 5 && runS.exit == 3
            && runS.stderr.contains("scripted crash") && hostS.adopted == ["stub-thread-1"],
          "closed \(runS.closedUnderBody), \(runS.bodySeconds) s, exit \(runS.exit), \(runS.stderr)")

    // AA. A turn that fails ENDS failed: the driver tells the runner, in the
    //     words its row already says, so a scheduled run is recorded as an
    //     error rather than "done" — and the runner draws no second row.
    check("AA. a turn codex failed is reported failed, once, in its row's own words",
          hostI.failures.count == 1 && hostI.failures.first?.contains("scripted 400") == true
            && hostI.signatures.filter { $0.hasPrefix("error:") } == hostI.failures.map { "error:" + $0 },
          "\(hostI.failures) \(hostI.signatures)")
    check("AA. …and so is a turn codex refused before it ran — in its words, with none, or in an answer that cannot be read",
          hostN.failures == ["Invalid request: scripted refusal"]
            && hostMute.failures == ["\(agent) reported an error but gave no detail."]
            && [hostP, hostP2, hostQ].allSatisfy {
                $0.failures.count == 1 && $0.failures.first?.hasPrefix("The installed Codex answered") == true
            },
          "\(hostN.failures) \(hostMute.failures) \(hostP.failures) \(hostP2.failures) \(hostQ.failures)")
    check("AA. …and no failure for a turn that completed, one ended at a request SipAI cannot draw, or one whose server died (the runner says that one)",
          hostO.failures.isEmpty && hostQ2.failures.isEmpty && hostR.failures.isEmpty && hostS.failures.isEmpty,
          "\(hostO.failures) \(hostQ2.failures) \(hostR.failures) \(hostS.failures)")

    let hostT = HarnessHost(cwd: trusted(makeFolder()))
    _ = await runStubTurn(driver("retry me", nil), host: hostT, mode: "retry", home: home)
    if let said = hostT.screen.firstIndex(of: "notice:Reconnecting... 1/5"),
       let answer = hostT.screen.firstIndex(of: "assistant:got through") {
        check("S. a retry notice is the state of the connection: real output takes it down, as on a headless turn — not the turn's end",
              said < answer && hostT.screen[said..<answer].contains("notice:-"), "\(hostT.screen)")
    } else {
        check("S. a retry is a notice, and the answer after it a row", false, "\(hostT.screen)")
    }

    await mcpForms(binary: binary)
    await backgroundTerminals(binary: binary)
    await midTurn(binary: binary)
    await fixedModes(binary: binary)

    // L. What offers the rows: codex's version, and Plan in codex's own list.
    var listed: [String]? = nil
    _ = await converse(binary: binary, cwd: folderK, home: home) { peer in
        _ = try? await peer.request("initialize", params: CodexAppServer.initializeParams(clientVersion: "harness"), timeout: 15)
        peer.notify("initialized")
        let answer = try? await peer.request("collaborationMode/list", params: [String: Any](), timeout: 15) as? [String: Any]
        listed = (answer?["data"] as? [[String: Any]])?.compactMap { $0["mode"] as? String }
    }
    check("L. the installed codex lists Plan, so its Plan row is offered",
          AgentAskingMode.offered(agentKey: "codex", kimiVersion: nil, codexVersion: version, codexModes: listed)
            == AgentAskingMode.codex,
          "version \(version), modes \(String(describing: listed))")
}

/// MF. What an MCP server asks, mid-call — codex relays each as
/// `mcpServer/elicitation/request`: its own approval of a tool that may
/// change something, a form, a form with no fields, a link to open. Each
/// is a card, and the answer reaches the server as the server's schema
/// types it. None of the answers ends the turn.
@MainActor
func mcpForms(binary: String) async {
    guard FileManager.default.fileExists(atPath: formServerPath) else {
        skip("MF. an MCP server's asks", "no stand-in MCP server at \(formServerPath)")
        return
    }
    func call(_ tool: String, id: String) -> [String: Any] {
        ["function_call": ["namespace": "mcp__forms", "name": tool, "arguments": [String: Any](),
                           "call_id": id]]
    }
    let script: [[String: Any]] = [
        ["marker": "SIPAI-MF-WRITE", "steps": [call("write_note", id: "call_mf_write"), ["text": "DONE WRITE"]]],
        ["marker": "SIPAI-MF-CANCEL", "steps": [call("write_note", id: "call_mf_cancel"), ["text": "DONE CANCEL"]]],
        ["marker": "SIPAI-MF-SESSION", "steps": [call("write_note", id: "call_mf_s1"),
                                                 call("write_note", id: "call_mf_s2"),
                                                 ["text": "DONE SESSION"]]],
        ["marker": "SIPAI-MF-SESS1", "steps": [call("write_note", id: "call_mf_sess1"), ["text": "DONE SESS1"]]],
        ["marker": "SIPAI-MF-SESS2", "steps": [call("write_note", id: "call_mf_sess2"), ["text": "DONE SESS2"]]],
        ["marker": "SIPAI-MF-ALWAYS", "steps": [call("write_note", id: "call_mf_always"), ["text": "DONE ALWAYS"]]],
        ["marker": "SIPAI-MF-AGAIN", "steps": [call("write_note", id: "call_mf_again"), ["text": "DONE AGAIN"]]],
        ["marker": "SIPAI-MF-FORM", "steps": [call("ask_form", id: "call_mf_form"), ["text": "DONE FORM"]]],
        ["marker": "SIPAI-MF-DECLINE", "steps": [call("ask_form", id: "call_mf_decline"), ["text": "DONE DECLINE"]]],
        ["marker": "SIPAI-MF-STOPPED", "steps": [call("ask_form", id: "call_mf_stopped"), ["text": "DONE STOPPED"]]],
        ["marker": "SIPAI-MF-CONFIRM", "steps": [call("ask_confirm", id: "call_mf_confirm"), ["text": "DONE CONFIRM"]]],
        ["marker": "SIPAI-MF-URL", "steps": [call("ask_url", id: "call_mf_url"), ["text": "DONE URL"]]],
    ]
    guard let fake = startFake(script: script) else {
        check("MF. the fake endpoint starts", false)
        return
    }
    defer { fake.process.terminate() }
    let serverLog = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cxas-mcpforms-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: serverLog) }
    // A model codex has no catalog entry for: it offers an MCP server's
    // tools straight to the model, where a catalogued one defers them
    // behind its tool search.
    let home = makeHome(port: fake.port, model: "sipai-forms-model", extraTail: """
    [mcp_servers.forms]
    command = "/usr/bin/env"
    args = ["python3", "\(formServerPath)", "\(serverLog.path)"]
    """)
    defer { try? FileManager.default.removeItem(at: home) }
    let folder = makeFolder()
    trust(folder, in: home)
    func driver(_ text: String) -> CodexAppServerTurn {
        CodexAppServerTurn(
            text: text, options: options(nil),
            settings: { defaults in
                CodexAppServer.turnSettings(model: nil, effort: nil, folderModel: nil, folderEffort: nil,
                                            modelDefaultEffort: { _ in nil }, serviceTier: nil,
                                            defaults: defaults)
            },
            agentName: agent, clientVersion: "harness")!
    }
    /// What the server got back, as its tool reported it.
    func elicited(_ marker: String) -> [String: Any] {
        guard let text = fake.partOutputs(marked: marker).first(where: { $0.contains("ELICITED ") }),
              let range = text.range(of: "ELICITED ") else { return [:] }
        let rest = String(text[range.upperBound...]).components(separatedBy: "\n").first ?? ""
        return json(rest)
    }
    func ranTo(_ host: HarnessHost, _ done: String) -> Bool {
        host.signatures.contains("assistant:" + done) && host.signatures.last == "turn-result"
    }

    // MF1. A tool with no read-only hint: codex asks before running it, in
    // its words and with its four answers, as its own terminal does — laid
    // out as Claude's permission card lays out its four.
    let hostW = HarnessHost(cwd: folder)
    hostW.onCard = { $0.respond(.chose("accept")) }
    _ = await runTurn(driver("SIPAI-MF-WRITE go"), host: hostW, binary: binary, home: home)
    if case .permission(let content)? = hostW.cards.first?.presentation {
        check("MF1. codex's approval of an MCP tool is a permission card in codex's words: its sentence, Allow, Allow for this session, Always allow, Cancel",
              hostW.cards.count == 1
                && content.prompt == "Allow the forms MCP server to run tool \"write_note\"?"
                && content.choices.map(\.id) == ["accept", "accept_session", "accept_always", "cancel"]
                && content.choices.map(\.label) == ["Allow", "Allow for this session", "Always allow", "Cancel"]
                && hostW.cards.first?.toolName == "forms",
              "\(content), badge \(String(describing: hostW.cards.first?.toolName))")
        check("MF1. …in Claude's two rows: the answers that keep it above, Cancel and Allow below",
              content.rows == [["accept_session", "accept_always"], ["cancel", "accept"]],
              "\(String(describing: content.rows))")
        check("MF1. …each keeping answer said under it, as Claude's card says what Allow Always keeps",
              content.notes == [CodexAppServer.Words.toolSessionLine,
                                CodexAppServer.Words.toolAlwaysLine(agent)]
                && content.notes.first?.hasPrefix(McpElicitation.Words.allowForSession + ":") == true
                && content.notes.last?.hasPrefix(McpElicitation.Words.alwaysAllow + ":") == true,
              "\(content.notes)")
    } else {
        check("MF1. codex's approval of an MCP tool is a permission card, not refused unseen", false,
              "\(hostW.cards.count) cards")
    }
    check("MF1. allowed, the tool runs and the turn goes on to its end",
          fake.partOutputs(marked: "SIPAI-MF-WRITE go").contains { $0.contains("WROTE") }
            && ranTo(hostW, "DONE WRITE"),
          "\(fake.partOutputs(marked: "SIPAI-MF-WRITE go")), \(hostW.signatures)")

    // MF1b. Cancel: the call is not made, and the turn is not ended by it.
    let hostC = HarnessHost(cwd: folder)
    hostC.onCard = { $0.respond(.chose("cancel")) }
    _ = await runTurn(driver("SIPAI-MF-CANCEL go"), host: hostC, binary: binary, home: home)
    check("MF1b. Cancel: codex tells the model the call was cancelled, and the turn goes on to its end — no \"stopped at your answer\" row",
          fake.partOutputs(marked: "SIPAI-MF-CANCEL go").contains { $0.contains("user cancelled MCP tool call") }
            && ranTo(hostC, "DONE CANCEL")
            && !hostC.signatures.contains { $0.hasPrefix("interrupted:") },
          "\(fake.partOutputs(marked: "SIPAI-MF-CANCEL go")), \(hostC.signatures)")

    // MF1c. Allow for this session: codex keeps it — the same tool again in
    // the turn is not asked about.
    let hostS = HarnessHost(cwd: folder)
    hostS.onCard = { $0.respond(.chose("accept_session")) }
    _ = await runTurn(driver("SIPAI-MF-SESSION go"), host: hostS, binary: binary, home: home)
    check("MF1c. Allow for this session: one card for two calls of the tool in the turn, and both run",
          hostS.cards.count == 1
            && fake.partOutputs(marked: "SIPAI-MF-SESSION go").filter { $0.contains("WROTE") }.count == 2
            && ranTo(hostS, "DONE SESSION"),
          "\(hostS.cards.count) cards, \(fake.partOutputs(marked: "SIPAI-MF-SESSION go"))")

    // MF1d. "Allow for this session" lasts this message alone: the next one
    // is a codex process of its own, and asks again. (Before MF1e: an
    // "Always allow" there would answer it.)
    let hostS1 = HarnessHost(cwd: folder)
    hostS1.onCard = { $0.respond(.chose("accept_session")) }
    _ = await runTurn(driver("SIPAI-MF-SESS1 go"), host: hostS1, binary: binary, home: home)
    let hostS2 = HarnessHost(cwd: folder, sessionId: hostS1.adopted.first)
    hostS2.onCard = { $0.respond(.chose("accept")) }
    _ = await runTurn(driver("SIPAI-MF-SESS2 go"), host: hostS2, binary: binary, home: home)
    check("MF1d. Allow for this session holds for this message alone: the next message, a codex of its own, asks again",
          hostS1.cards.count == 1 && hostS2.cards.count == 1 && hostS1.adopted.count == 1
            && fake.partOutputs(marked: "SIPAI-MF-SESS2 go").contains { $0.contains("WROTE") },
          "\(hostS1.cards.count) then \(hostS2.cards.count) cards")

    // MF1e. "Always allow": codex itself saves the tool's approval in its own
    // config, and the next message — a codex process of its own — runs the
    // tool without asking.
    let configFile = home.appendingPathComponent("config.toml")
    let configBefore = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
    let hostA1 = HarnessHost(cwd: folder)
    hostA1.onCard = { $0.respond(.chose("accept_always")) }
    _ = await runTurn(driver("SIPAI-MF-ALWAYS go"), host: hostA1, binary: binary, home: home)
    let configAfter = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
    // Codex files the new table under the server's own, not at the end: every
    // line that was there is still there, in order, and the two it adds are
    // all that is new.
    let linesBefore = configBefore.components(separatedBy: "\n").filter { !$0.isEmpty }
    let linesAfter = configAfter.components(separatedBy: "\n").filter { !$0.isEmpty }
    var kept = linesBefore[...]
    var added: [String] = []
    for line in linesAfter {
        if let next = kept.first, next == line { kept = kept.dropFirst() } else { added.append(line) }
    }
    check("MF1e. Always allow: the tool runs, and codex writes its approval into its own config — and nothing else",
          fake.partOutputs(marked: "SIPAI-MF-ALWAYS go").contains { $0.contains("WROTE") }
            && kept.isEmpty
            && added == ["[mcp_servers.forms.tools.write_note]", "approval_mode = \"approve\""],
          "added \(added), lost \(Array(kept))")
    let hostA2 = HarnessHost(cwd: folder, sessionId: hostA1.adopted.first)
    hostA2.onCard = { $0.respond(.chose("cancel")) }
    _ = await runTurn(driver("SIPAI-MF-AGAIN go"), host: hostA2, binary: binary, home: home)
    check("MF1e. …the next message runs the tool without a card",
          hostA2.cards.isEmpty && fake.partOutputs(marked: "SIPAI-MF-AGAIN go").contains { $0.contains("WROTE") }
            && ranTo(hostA2, "DONE AGAIN"),
          "\(hostA2.cards.count) cards, \(fake.partOutputs(marked: "SIPAI-MF-AGAIN go"))")

    // MF2. A form: one page per field, required first in the server's own
    // order (codex sorts the rest by name), each typed as the schema says.
    let hostF = HarnessHost(cwd: folder)
    var formSeen: AgentQuestionForm? = nil
    hostF.onCard = { card in
        formSeen = card.question
        guard let form = card.question else { card.respond(.cancelled); return }
        var answers: [String: AgentQuestionAnswer] = form.initialAnswers
        for q in form.questions {
            switch q.id {
            case "name": answers[q.text] = AgentQuestionAnswer(otherText: "Ada", otherPicked: true)
            case "color": answers[q.text] = AgentQuestionAnswer(labels: ["Blue"])
            case "count": answers[q.text] = AgentQuestionAnswer(otherText: "3", otherPicked: true)
            case "subscribe": answers[q.text] = AgentQuestionAnswer(labels: [McpElicitation.Words.yes])
            case "tags": answers[q.text] = AgentQuestionAnswer(labels: ["Gamma", "Alpha"])
            default: break
            }
        }
        card.respond(.answered(answers))
    }
    _ = await runTurn(driver("SIPAI-MF-FORM go"), host: hostF, binary: binary, home: home)
    let ids = formSeen?.questions.compactMap(\.id) ?? []
    check("MF2. an MCP server's form is a question card naming the server, its message above the fields",
          hostF.cards.count == 1 && hostF.cards.first?.presentation == .question
            && formSeen?.asker == "forms" && formSeen?.message == "Tell the report about you",
          "\(hostF.cards.count) cards, \(String(describing: formSeen?.asker))")
    check("MF2. one page per field: the required ones first, as the server lists them, the rest by name",
          ids == ["name", "color", "count", "size", "subscribe", "tags"], "\(ids)")
    if let form = formSeen, form.questions.count == 6 {
        let q = form.questions
        check("MF2. a text field asks its description under its title, takes the user's words, and is required",
              q[0].text == "What should the report call you?" && q[0].header == "Your name"
                && q[0].options.isEmpty && q[0].allowsOther && q[0].required && q[0].words == nil)
        check("MF2. a titled choice shows its titles; a legacy enum its enumNames; yes-or-no is Yes / No, starting on its default",
              q[1].options.map(\.label) == ["Red", "Blue"] && !q[1].allowsOther && q[1].required
                && q[3].options.map(\.label) == ["Small", "Medium", "Large"] && !q[3].required
                && q[4].options.map(\.label) == [McpElicitation.Words.yes, McpElicitation.Words.no]
                && form.initialAnswers[q[4].text]?.labels == [McpElicitation.Words.no])
        check("MF2. an integer field is typed, and says what it takes",
              q[2].words == .number(integer: true, minimum: 1, maximum: 9)
                && q[2].words?.hint == "A whole number · From 1 to 9")
        check("MF2. a multiple choice keeps the server's bounds",
              q[5].multiSelect && q[5].options.map(\.label) == ["Alpha", "Beta", "Gamma"] && q[5].maxPicks == 2)
    }
    let formAnswer = elicited("SIPAI-MF-FORM go")
    check("MF2. the answer reaches the server typed: text, the choice's value (not its title), a number, a boolean, the values picked in the server's order — and the field left empty is left out",
          formAnswer["action"] as? String == "accept"
            && jsonText(formAnswer["content"] ?? [:]) == #"{"color":"blue","count":3,"name":"Ada","subscribe":true,"tags":["a","c"]}"#,
          "\(formAnswer)")
    check("MF2. the turn goes on to its end", ranTo(hostF, "DONE FORM"), "\(hostF.signatures)")

    // MF2b. Decline.
    let hostD = HarnessHost(cwd: folder)
    hostD.onCard = { $0.respond(.skipped) }
    _ = await runTurn(driver("SIPAI-MF-DECLINE go"), host: hostD, binary: binary, home: home)
    check("MF2b. Decline: the server is told decline, nothing else, and the turn goes on",
          jsonText(elicited("SIPAI-MF-DECLINE go")) == #"{"action":"decline"}"# && ranTo(hostD, "DONE DECLINE"),
          "\(elicited("SIPAI-MF-DECLINE go"))")

    // MF2c. Stop (or the turn ending) under the card.
    let hostX = HarnessHost(cwd: folder)
    hostX.onCard = { $0.respond(.cancelled) }
    _ = await runTurn(driver("SIPAI-MF-STOPPED go"), host: hostX, binary: binary, home: home)
    check("MF2c. a card cancelled under the user (Stop, a quit) tells the server cancel",
          jsonText(elicited("SIPAI-MF-STOPPED go")) == #"{"action":"cancel"}"#,
          "\(elicited("SIPAI-MF-STOPPED go"))")

    // MF3. A form with no fields: a yes-or-no naming the server.
    let hostY = HarnessHost(cwd: folder)
    hostY.onCard = { $0.respond(.chose("accept")) }
    _ = await runTurn(driver("SIPAI-MF-CONFIRM go"), host: hostY, binary: binary, home: home)
    if case .permission(let content)? = hostY.cards.first?.presentation {
        check("MF3. a form with no fields is a yes-or-no naming the server, in its words: Allow, Deny, Cancel",
              content.prompt == McpElicitation.Words.requestsInput("forms")
                && content.preview == .text("Send the report now?")
                && content.choices.map(\.id) == ["accept", "decline", "cancel"],
              "\(content)")
    } else {
        check("MF3. a form with no fields is a card", false, "\(hostY.cards.count) cards")
    }
    check("MF3. allowed, the server is told accept",
          elicited("SIPAI-MF-CONFIRM go")["action"] as? String == "accept", "\(elicited("SIPAI-MF-CONFIRM go"))")

    // MF4. A link to open.
    let hostU = HarnessHost(cwd: folder)
    hostU.onCard = { $0.respond(.chose(LinkCardContent.acceptId)) }
    _ = await runTurn(driver("SIPAI-MF-URL go"), host: hostU, binary: binary, home: home)
    check("MF4. a link is a link card: the server, its words, the link exactly as it would open",
          hostU.cards.count == 1
            && hostU.cards.first?.presentation == .link(LinkCardContent(
                asker: "forms", message: "Sign in to the report service",
                url: "https://example.com/sign-in?step=1", opens: true)),
          "\(String(describing: hostU.cards.first?.presentation))")
    check("MF4. done in the browser, the server is told accept",
          elicited("SIPAI-MF-URL go")["action"] as? String == "accept" && ranTo(hostU, "DONE URL"),
          "\(elicited("SIPAI-MF-URL go"))")

    // Codex declares both kinds to its servers — which is what lets them ask.
    let logText = (try? String(contentsOf: serverLog, encoding: .utf8)) ?? ""
    check("MF. codex tells its MCP servers it takes forms and links",
          logText.contains(#""elicitation": {"form": {}, "url": {}}"#), String(logText.prefix(300)))
}

/// BT. A command codex leaves running in a background terminal when its
/// answer lands (`exec_command` returns while the command runs). Codex ends
/// the turn at the answer one run and holds it open until the command ends
/// the next, and stops the command the moment the conversation closes — so
/// the driver holds the turn until the command has ended, the line naming
/// it meanwhile. With codex's own wait for a terminal set short
/// (`background_terminal_max_timeout`), codex ends the turn at the answer
/// every time (measured): that run fails on a driver that does not hold it.
@MainActor
func backgroundTerminals(binary: String) async {
    let folder = makeFolder()
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
    let done = folder.appendingPathComponent("bg-done.txt")
    let longDone = folder.appendingPathComponent("bg-long.txt")
    let quick = "sleep 6; date > \(done.path)"
    let long = "sleep 40; date > \(longDone.path)"
    let script: [[String: Any]] = [
        ["marker": "SIPAI-BGTERM-LONG", "steps": [
            ["function_call": ["name": "exec_command", "arguments": ["cmd": long, "yield_time_ms": 1000]]],
            ["text": "STARTED LONG"]]],
        ["marker": "SIPAI-BGTERM", "steps": [
            ["function_call": ["name": "exec_command", "arguments": ["cmd": quick, "yield_time_ms": 1000]]],
            ["text": "STARTED BG"]]],
    ]
    guard let fake = startFake(script: script) else {
        check("BT. the fake endpoint starts", false)
        return
    }
    defer { fake.process.terminate() }
    func driver(_ text: String) -> CodexAppServerTurn {
        CodexAppServerTurn(
            text: text, options: options(nil),
            settings: { defaults in
                CodexAppServer.turnSettings(model: nil, effort: nil, folderModel: nil, folderEffort: nil,
                                            modelDefaultEffort: { _ in nil }, serviceTier: nil,
                                            defaults: defaults)
            },
            agentName: agent, clientVersion: "harness")!
    }
    for (label, extra) in [("codex's own wait for a terminal set to 4 s", "background_terminal_max_timeout = 4000"),
                           ("codex's own default wait", "")] {
        try? FileManager.default.removeItem(at: done)
        let home = makeHome(port: fake.port, extraTop: extra)
        defer { try? FileManager.default.removeItem(at: home) }
        trust(folder, in: home)
        let host = HarnessHost(cwd: folder)
        let run = await runTurn(driver("SIPAI-BGTERM go"), host: host, binary: binary, home: home)
        let output = host.signatures.firstIndex { $0.hasPrefix("output:") }
        let result = host.signatures.firstIndex(of: "turn-result")
        check("BT. \(label): the turn ends only once the command it left running has — and the command ran to its end",
              FileManager.default.fileExists(atPath: done.path) && run.bodySeconds >= 5
                && output != nil && result != nil && output! < result!,
              "file \(FileManager.default.fileExists(atPath: done.path)), "
                + "\(String(format: "%.1f", run.bodySeconds)) s, \(host.signatures)")
        check("BT. \(label): meanwhile the transcript names the command, codex's wrapper left off, and at the end nothing",
              host.awaited.contains([quick]) && host.awaited.last == [], "\(host.awaited)")
    }

    // Stop while the turn waits on a long command: the driver lets the
    // turn go at once, and the command goes with the conversation.
    let home = makeHome(port: fake.port, extraTop: "background_terminal_max_timeout = 4000")
    defer { try? FileManager.default.removeItem(at: home) }
    trust(folder, in: home)
    let host = HarnessHost(cwd: folder)
    let stopping = driver("SIPAI-BGTERM-LONG go")
    var named = false
    let run = await converse(binary: binary, cwd: folder, home: home) { peer in
        let turn = Task { @MainActor in await stopping.run(peer: peer, host: host) }
        let deadline = Date().addingTimeInterval(20)
        while !(host.awaited.last ?? []).contains(long), Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        named = (host.awaited.last ?? []).contains(long)
        host.live = false
        _ = stopping.interrupt(peer: peer)
        await turn.value
    }
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", longDone.path]
    let found = Pipe()
    pgrep.standardOutput = found
    try? pgrep.run()
    let survivors = String(decoding: found.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    pgrep.waitUntilExit()
    check("BT. Stop while it waits: the turn is let go at once, and the command goes with the conversation",
          named && run.bodySeconds < 10 && survivors.isEmpty
            && !FileManager.default.fileExists(atPath: longDone.path),
          "named \(named), \(String(format: "%.1f", run.bodySeconds)) s, survivors '\(survivors)'")
    for pid in survivors.split(separator: "\n").compactMap({ pid_t($0) }) where pid > 1 {
        kill(pid, SIGKILL)
    }
}

/// MT. While a turn runs, and codex's own commands: a message steered into
/// the running turn (`turn/steer`) reaches the model at its next step and
/// is drawn where the rollout puts it, as a reopen draws it; one sent once
/// the turn is over is kept for the next; a background terminal stopped on
/// its own lets a turn held only for it end, and the command goes;
/// `/compact` summarises the thread as a turn of codex's own; `/review`
/// runs codex's review, its notices the same live and on reopen.
@MainActor
func midTurn(binary: String) async {
    let folder = makeFolder()
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
    let longDone = folder.appendingPathComponent("mt-long.txt")
    let long = "sleep 40; date > \(longDone.path)"
    let script: [[String: Any]] = [
        ["marker": "SIPAI-MT-STEER", "steps": [
            ["function_call": ["name": "exec_command", "arguments": ["cmd": "sleep 3", "yield_time_ms": 10000]]],
            ["text": "ANSWERED AFTER THE STEER"]]],
        ["marker": "SIPAI-MT-BG", "steps": [
            ["function_call": ["name": "exec_command", "arguments": ["cmd": long, "yield_time_ms": 1000]]],
            ["text": "STARTED LONG"]]],
    ]
    guard let fake = startFake(script: script) else {
        check("MT. the fake endpoint starts", false)
        return
    }
    defer { fake.process.terminate() }
    func driver(_ text: String, command: CodexCommandTurn? = nil) -> CodexAppServerTurn {
        CodexAppServerTurn(
            text: text, options: options(nil), command: command,
            settings: { defaults in
                CodexAppServer.turnSettings(model: nil, effort: nil, folderModel: nil, folderEffort: nil,
                                            modelDefaultEffort: { _ in nil }, serviceTier: nil,
                                            defaults: defaults)
            },
            agentName: agent, clientVersion: "harness")!
    }
    let home = makeHome(port: fake.port)
    defer { try? FileManager.default.removeItem(at: home) }
    trust(folder, in: home)
    let sessions = home.appendingPathComponent("sessions")

    // MT1. A message steered in while a command runs.
    let host = HarnessHost(cwd: folder)
    let turn = driver("SIPAI-MT-STEER go")
    // Never a script marker's substring, or the stand-in starts the script again.
    let steered = "SIPAI-INTO-TURN and also say BANANA"
    var answer: String?? = .none
    var late: String? = nil
    _ = await converse(binary: binary, cwd: folder, home: home) { peer in
        let running = Task { @MainActor in await turn.run(peer: peer, host: host) }
        let deadline = Date().addingTimeInterval(20)
        while !(host.steerable && host.signatures.contains { $0.hasPrefix("tool:") }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        answer = .some(await turn.steer(text: steered, peer: peer))
        await running.value
        late = await turn.steer(text: "SIPAI-AFTER-TURN", peer: peer)
    }
    check("MT1. codex takes a message steered in while a command runs, says so at the step that carries it, and the model is sent it there",
          answer == .some(nil) && host.taken == [steered]
            && !fake.bodies(marked: "SIPAI-INTO-TURN").isEmpty
            && host.signatures.contains("assistant:ANSWERED AFTER THE STEER"),
          "answer \(String(describing: answer)), taken \(host.taken), \(host.signatures)")
    check("MT1. …the turn takes none once it is over: kept for the next, never sent into a later turn",
          late == "" && !host.steerable, "late \(String(describing: late)), steerable \(host.steerable)")
    let threadId = host.adopted.first ?? ""
    if let url = rollout(home: home, id: threadId) {
        let rows = CodexSessionScanner.readHistory(of: url, root: sessions).map(historySignature)
        let prompt = rows.firstIndex(of: "user:SIPAI-MT-STEER go")
        let reply = rows.firstIndex(of: "reply:" + steered)
        let tool = rows.firstIndex { $0.hasPrefix("tool:") }
        let final = rows.firstIndex(of: "assistant:ANSWERED AFTER THE STEER")
        check("MT1. reopened, the steered message sits after the command and before the answer, sent into the turn (no turn of its own)",
              prompt != nil && tool != nil && reply != nil && final != nil
                && prompt! < tool! && tool! < reply! && reply! < final!
                && rows.filter { $0.hasPrefix("tool:") }.count == 1
                && !rows.contains("user:" + steered),
              "\(rows)")
    } else {
        check("MT1. the steered turn's rollout is on disk", false, "thread \(threadId)")
    }

    // MT2. One background terminal stopped from its line.
    let hostB = HarnessHost(cwd: folder)
    let bg = driver("SIPAI-MT-BG go")
    var stopped = false
    var heldSteer: String? = nil
    var heldSteerable = true
    let runB = await converse(binary: binary, cwd: folder, home: home) { peer in
        let running = Task { @MainActor in await bg.run(peer: peer, host: hostB) }
        let deadline = Date().addingTimeInterval(20)
        while !hostB.awaitedEntries.contains(where: { $0.description.contains("sleep 40") }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        heldSteerable = hostB.steerable
        heldSteer = await bg.steer(text: "SIPAI-WHILE-HELD", peer: peer)
        if let entry = hostB.awaitedEntries.first(where: { $0.description.contains("sleep 40") }) {
            stopped = await bg.stopBackgroundTask(id: entry.id, peer: peer)
        }
        await running.value
    }
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", longDone.path]
    let found = Pipe()
    pgrep.standardOutput = found
    try? pgrep.run()
    let survivors = String(decoding: found.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    pgrep.waitUntilExit()
    check("MT2. a turn held for a background terminal takes no steered message (codex: no active turn to steer)",
          !heldSteerable && heldSteer == "", "steerable \(heldSteerable), steer \(String(describing: heldSteer))")
    check("MT2. the terminal stopped from its line goes, and the turn held only for it ends at once",
          stopped && runB.bodySeconds < 20 && survivors.isEmpty
            && !FileManager.default.fileExists(atPath: longDone.path) && hostB.awaited.last == [],
          "stopped \(stopped), \(String(format: "%.1f", runB.bodySeconds)) s, survivors '\(survivors)', \(hostB.awaited)")
    for pid in survivors.split(separator: "\n").compactMap({ pid_t($0) }) where pid > 1 {
        kill(pid, SIGKILL)
    }

    // MT3. `/compact` on the steered thread: a turn of codex's own.
    let hostC = HarnessHost(cwd: folder, sessionId: threadId)
    let compact = driver("", command: .compact)
    var compactSteer: String? = nil
    _ = await converse(binary: binary, cwd: folder, home: home) { peer in
        let running = Task { @MainActor in await compact.run(peer: peer, host: hostC) }
        compactSteer = await compact.steer(text: "SIPAI-INTO-COMPACT", peer: peer)
        await running.value
    }
    let compactedOnDisk = rollout(home: home, id: threadId).map {
        ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains("\"type\":\"compacted\"")
    } ?? false
    let reopenedCompaction = rollout(home: home, id: threadId).map {
        CodexSessionScanner.readHistory(of: $0, root: sessions).contains {
            if case .compaction = $0.kind { return true }
            return false
        }
    } ?? false
    check("MT3. /compact summarises the thread in a turn of codex's own: summarising shown, then gone, one compaction row live and on reopen, no message of the user's",
          hostC.compacting == [true, false] && hostC.signatures.contains("compaction")
            && !hostC.signatures.contains { $0.hasPrefix("user:") }
            && compactedOnDisk && reopenedCompaction && compactSteer == "",
          "compacting \(hostC.compacting), \(hostC.signatures), on disk \(compactedOnDisk), reopened \(reopenedCompaction), steer \(String(describing: compactSteer))")

    // MT4. `/review` in a new session: uncommitted changes.
    try? "a change to review\n".write(to: folder.appendingPathComponent("review-me.txt"),
                                       atomically: true, encoding: .utf8)
    let hostR = HarnessHost(cwd: folder)
    let review = driver("", command: .review(.uncommittedChanges))
    _ = await runTurn(review, host: hostR, binary: binary, home: home)
    let startedLive = hostR.signatures.first { $0.hasPrefix("user:" + CodexReviewWords.started("")) }
    let finishedLive = hostR.signatures.lastIndex(of: "user:" + CodexReviewWords.finished)
    let startedAt = startedLive.flatMap { hostR.signatures.firstIndex(of: $0) }
    let reviewText = startedAt.flatMap { s in finishedLive.map { hostR.signatures[(s + 1)..<$0] } }?
        .contains { $0.hasPrefix("assistant:") } ?? false
    check("MT4. /review in a new session: the thread is adopted, and codex's review sits between its own two notices",
          hostR.adopted.count == 1 && startedLive != nil && finishedLive != nil && reviewText
            && hostR.failures.isEmpty,
          "adopted \(hostR.adopted), failures \(hostR.failures), \(hostR.signatures)")
    if let id = hostR.adopted.first, let url = rollout(home: home, id: id) {
        let rows = CodexSessionScanner.readHistory(of: url, root: sessions)
        let notices = rows.filter(\.isSystemNotice).map(historySignature)
        let users = rows.filter { !$0.isSystemNotice }.map(historySignature).filter { $0.hasPrefix("user:") }
        check("MT4. reopened, the same two notices in the same words, and codex's own instruction to its reviewer never drawn",
              notices == [startedLive, "user:" + CodexReviewWords.finished].compactMap { $0 }
                && users.isEmpty && !rows.map(historySignature).contains { $0.contains("<user_action>") },
              "notices \(notices), user rows \(users)")
    } else {
        check("MT4. the review's rollout is on disk", false, "adopted \(hostR.adopted)")
    }

    // SH. A `!` command — the user's own shell command — as a new session's
    // first message: codex runs it as a turn of its own with no model
    // request, the driver draws its output (the runner draws the command's
    // row), the thread is adopted, and a command that fails is the
    // command's failure, never the turn's.
    func shellOutputs(_ host: HarnessHost) -> [ShellCommandOutput] {
        host.events.compactMap { event in
            if case .shellOutput(let output) = event.kind { return output }
            return nil
        }
    }
    let requestsBeforeShell = fake.requests().count
    let hostS = HarnessHost(cwd: folder)
    _ = await runTurn(driver("", command: .shell("echo SIPAI-SHELL-OUT; exit 3")),
                      host: hostS, binary: binary, home: home)
    let shellOut = shellOutputs(hostS)
    check("SH. a ! command in a new session: codex runs it with no model request, its output drawn once, the thread adopted, the turn not failed",
          hostS.adopted.count == 1 && shellOut.count == 1
            && shellOut.first?.stdout.contains("SIPAI-SHELL-OUT") == true && shellOut.first?.exitCode == 3
            && fake.requests().count == requestsBeforeShell && hostS.failures.isEmpty
            && !hostS.signatures.contains {
                $0.hasPrefix("user:") || $0.hasPrefix("assistant:") || $0.hasPrefix("error:") || $0.hasPrefix("tool:") },
          "adopted \(hostS.adopted), failures \(hostS.failures), \(hostS.signatures), "
            + "requests \(fake.requests().count - requestsBeforeShell)")
    if let id = hostS.adopted.first, let url = rollout(home: home, id: id) {
        let shape = CodexSessionScanner.readHistory(of: url, root: sessions).map { item -> String in
            switch item.kind {
            case .userText(let text): return (item.shellCommand ? "command:" : "user:") + text
            case .shellOutput(let output): return "output:\(output.exitCode.map(String.init) ?? "-")"
            default: return historySignature(item)
            }
        }
        check("SH. reopened, the command and its output, as drawn live",
              shape == ["command:!echo SIPAI-SHELL-OUT; exit 3", "output:3"], "\(shape)")
    } else {
        check("SH. the ! command's rollout is on disk", false, "adopted \(hostS.adopted)")
    }

    // SH. Stop during a long one: codex ends the turn at once, and the
    // output reads as stopped — no error row, no failure.
    let hostT = HarnessHost(cwd: folder, sessionId: hostS.adopted.first)
    let longShell = driver("", command: .shell("sleep 29.7; echo SIPAI-NEVER"))
    var shellStoppedAt: Date? = nil
    let runT = await converse(binary: binary, cwd: folder, home: home) { peer in
        let running = Task { @MainActor in await longShell.run(peer: peer, host: hostT) }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        hostT.live = false
        shellStoppedAt = Date()
        _ = longShell.interrupt(peer: peer)
        await running.value
    }
    let stoppedOut = shellOutputs(hostT)
    check("SH. Stop during a long ! command: the turn ends at once, its output reads as stopped, nothing else said",
          shellStoppedAt.map { Date().timeIntervalSince($0) < 15 } == true && runT.bodySeconds < 12
            && stoppedOut.count == 1 && stoppedOut.first?.interrupted == true
            && stoppedOut.first?.text.contains("SIPAI-NEVER") == false
            && hostT.failures.isEmpty
            && !hostT.signatures.contains { $0.hasPrefix("error:") || $0.hasPrefix("interrupted:") },
          "\(String(format: "%.1f", runT.bodySeconds)) s, \(stoppedOut), failures \(hostT.failures), \(hostT.signatures)")
    // Codex stops the command's own process; a process it started may
    // outlive it (codex's terminal does the same). Nothing of the harness's
    // is left behind.
    let reap = Process()
    reap.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    reap.arguments = ["-f", "sleep 29.7"]
    try? reap.run()
    reap.waitUntilExit()
}

/// FX. Codex's three fixed modes — Read Only, Workspace Write, Full Access —
/// through the app-server: a turn there states never asking and the mode's
/// own sandbox, so it does exactly what `codex exec` does in the mode (the
/// files a command may write, the folder trust codex records, no request to
/// the user — an MCP server's ask declined by codex itself), with what only
/// the app-server gives: a speed per message, and a command left running
/// in a background terminal holding the turn until it ends.
@MainActor
func fixedModes(binary: String) async {
    let outside = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/sipai-codexfixed-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    let modes: [(value: String, inside: Bool, outside: Bool)] = [
        ("read-only", false, false), ("workspace-write", true, false), ("full-access", true, true)]
    func writes(_ marker: String) -> [[String: Any]] {
        [["function_call": ["name": "exec_command", "arguments": ["cmd": "echo hi > \(marker)-in.txt"]]],
         ["function_call": ["name": "exec_command", "arguments": [
            "cmd": "echo hi > \(outside.path)/\(marker)-out.txt"]]],
         ["text": "DONE \(marker)"]]
    }
    func escalatedOutside(_ marker: String) -> [[String: Any]] {
        [["function_call": ["name": "exec_command", "arguments": [
            "cmd": "touch \(outside.path)/\(marker).txt", "sandbox_permissions": "require_escalated",
            "justification": "Make the probe file?"]]],
         ["text": "DONE \(marker)"]]
    }
    func mcpCall(_ tool: String) -> [[String: Any]] {
        [["function_call": ["namespace": "mcp__forms", "name": tool, "arguments": [String: Any](),
                            "call_id": "call_fx_\(tool)"]],
         ["text": "DONE \(tool)"]]
    }
    var script: [[String: Any]] = []
    for mode in modes {
        script.append(["marker": "SIPAI-FX-AS-\(mode.value)", "steps": writes("as-\(mode.value)")])
        script.append(["marker": "SIPAI-FX-EX-\(mode.value)", "steps": writes("ex-\(mode.value)")])
    }
    script += [
        ["marker": "SIPAI-FX-DEFAULT-ONE", "steps": escalatedOutside("default-one")],
        ["marker": "SIPAI-FX-FIXED", "steps": escalatedOutside("fixed")],
        ["marker": "SIPAI-FX-DEFAULT-TWO", "steps": escalatedOutside("default-two")],
        ["marker": "SIPAI-FX-SPEED", "steps": [["text": "DONE SPEED"]]],
        ["marker": "SIPAI-FX-EXSPEED", "steps": [["text": "DONE EXSPEED"]]],
        ["marker": "SIPAI-FX-BG", "steps": [
            ["function_call": ["name": "exec_command", "arguments": [
                "cmd": "sleep 6; date > bg-fixed.txt", "yield_time_ms": 1000]]],
            ["text": "STARTED FX"]]],
        ["marker": "SIPAI-FX-MCPW", "steps": mcpCall("write_note")],
        ["marker": "SIPAI-FX-MCPF", "steps": mcpCall("ask_form")],
    ]
    guard let fake = startFake(script: script) else {
        check("FX. the fake endpoint starts", false)
        return
    }
    defer { fake.process.terminate() }
    func driver(_ text: String, _ mode: String?, tier: String? = nil) -> CodexAppServerTurn? {
        CodexAppServerTurn(
            text: text, options: options(mode),
            settings: { defaults in
                CodexAppServer.turnSettings(model: nil, effort: nil, folderModel: nil, folderEffort: nil,
                                            modelDefaultEffort: { _ in nil }, serviceTier: tier,
                                            defaults: defaults)
            },
            agentName: agent, clientVersion: "harness")
    }
    func trusted(_ home: URL, _ folder: URL) -> Bool {
        ((try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)) ?? "")
            .contains(folder.path)
    }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // Each mode, a new thread in a folder codex does not trust: the app-server
    // turn beside a `codex exec` turn with the argv SipAI gives it.
    for mode in modes {
        let folderAS = makeFolder(), homeAS = makeHome(port: fake.port)
        let folderEX = makeFolder(), homeEX = makeHome(port: fake.port)
        defer {
            try? FileManager.default.removeItem(at: homeAS)
            try? FileManager.default.removeItem(at: homeEX)
        }
        guard let turn = driver("SIPAI-FX-AS-\(mode.value) go", mode.value) else {
            check("FX. \(mode.value) runs through the app-server's driver", false, "no driver for the mode")
            continue
        }
        let host = HarnessHost(cwd: folderAS)
        _ = await runTurn(turn, host: host, binary: binary, home: homeAS)
        let thread = host.adopted.first ?? ""
        let execLines = execTurn(binary: binary, cwd: folderEX, home: homeEX, resume: nil,
                                 prompt: "SIPAI-FX-EX-\(mode.value) go",
                                 permissions: CodexCapabilities.sandboxArgv(for: mode.value) ?? [])
        let execThread = execLines.compactMap { line -> String? in
            let o = json(line)
            return o["type"] as? String == "thread.started" ? o["thread_id"] as? String : nil
        }.first ?? ""
        let asIn = exists(folderAS.appendingPathComponent("as-\(mode.value)-in.txt"))
        let asOut = exists(outside.appendingPathComponent("as-\(mode.value)-out.txt"))
        let exIn = exists(folderEX.appendingPathComponent("ex-\(mode.value)-in.txt"))
        let exOut = exists(outside.appendingPathComponent("ex-\(mode.value)-out.txt"))
        let asPermissions = turnPermissions(home: homeAS, id: thread)
        let exPermissions = turnPermissions(home: homeEX, id: execThread)
        check("FX. \(mode.value): a command writes what the mode allows — no more — and nothing is asked",
              asIn == mode.inside && asOut == mode.outside && host.cards.isEmpty
                && host.signatures.contains("assistant:DONE as-\(mode.value)"),
              "inside \(asIn), outside \(asOut), \(host.cards.count) cards, \(host.signatures)")
        check("FX. \(mode.value): exactly what codex exec does in the mode — the files, the permissions it records, the folder's trust",
              asIn == exIn && asOut == exOut && !asPermissions.isEmpty && asPermissions == exPermissions
                && trusted(homeAS, folderAS) == trusted(homeEX, folderEX)
                && trusted(homeAS, folderAS) == (mode.value != "read-only"),
              "files \(asIn)/\(asOut) vs \(exIn)/\(exOut), \(asPermissions) vs \(exPermissions), "
                + "trust \(trusted(homeAS, folderAS)) vs \(trusted(homeEX, folderEX))")
        try? FileManager.default.removeItem(at: folderAS.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: folderEX.deletingLastPathComponent())
    }

    // A thread that ran a Default turn, then a fixed mode, then Default again:
    // each turn runs as its own chip says — the fixed one never asks, and the
    // thread does not keep its "never" for the next Default turn.
    let homeR = makeHome(port: fake.port)
    defer { try? FileManager.default.removeItem(at: homeR) }
    let folderR = makeFolder()
    trust(folderR, in: homeR)
    let hostR1 = HarnessHost(cwd: folderR)
    hostR1.onCard = { $0.respond(.chose("accept")) }
    if let one = driver("SIPAI-FX-DEFAULT-ONE go", nil) {
        _ = await runTurn(one, host: hostR1, binary: binary, home: homeR)
    }
    let threadR = hostR1.adopted.first ?? ""
    let hostR2 = HarnessHost(cwd: folderR, sessionId: threadR)
    hostR2.onCard = { $0.respond(.chose("accept")) }
    if let fixedTurn = driver("SIPAI-FX-FIXED go", "workspace-write") {
        _ = await runTurn(fixedTurn, host: hostR2, binary: binary, home: homeR)
    }
    let hostR3 = HarnessHost(cwd: folderR, sessionId: threadR)
    hostR3.onCard = { $0.respond(.chose("accept")) }
    if let two = driver("SIPAI-FX-DEFAULT-TWO go", nil) {
        _ = await runTurn(two, host: hostR3, binary: binary, home: homeR)
    }
    let permissionsR = turnPermissions(home: homeR, id: threadR)
    check("FX. after a Default turn that asked, a Workspace Write turn on the thread asks nothing, and the command it was refused stays undone",
          hostR1.cards.count == 1 && hostR2.cards.isEmpty
            && !exists(outside.appendingPathComponent("fixed.txt"))
            && hostR2.signatures.contains("assistant:DONE fixed"),
          "\(hostR1.cards.count) / \(hostR2.cards.count) cards, \(hostR2.signatures)")
    check("FX. …and the Default turn after it asks again: the thread keeps no \"never\" from the fixed mode",
          hostR3.cards.count == 1 && permissionsR.count == 3
            && permissionsR[1].hasPrefix("never/") && !permissionsR[2].hasPrefix("never/"),
          "\(hostR3.cards.count) cards, \(permissionsR)")

    // A speed per message: what each fixed-mode turn states is what its
    // request carries. On codex exec, which keeps a thread's saved speed, the
    // same two messages run at the first one's speed (the control).
    let homeS = makeHome(port: fake.port)
    defer { try? FileManager.default.removeItem(at: homeS) }
    let folderS = makeFolder()
    let hostS1 = HarnessHost(cwd: folderS)
    if let fast = driver("SIPAI-FX-SPEED one", "workspace-write", tier: "priority") {
        _ = await runTurn(fast, host: hostS1, binary: binary, home: homeS)
    }
    let speedOne = fake.bodies(marked: "SIPAI-FX-SPEED one").last
    let hostS2 = HarnessHost(cwd: folderS, sessionId: hostS1.adopted.first)
    if let standard = driver("SIPAI-FX-SPEED two", "workspace-write", tier: "default") {
        _ = await runTurn(standard, host: hostS2, binary: binary, home: homeS)
    }
    let speedTwo = fake.bodies(marked: "SIPAI-FX-SPEED two").last
    check("FX. a fixed mode's speed is the message's own: Fast, then standard, on one thread",
          speedOne?["service_tier"] as? String == "priority" && speedTwo != nil
            && (speedTwo?["service_tier"] as? String).map({ $0 == "default" }) ?? true,
          "one \(String(describing: speedOne?["service_tier"])), two \(String(describing: speedTwo?["service_tier"]))")
    if let version = codexVersion(binary), CodexKeptSpeed.keeps(codexVersion: version) {
        let folderX = makeFolder()
        let first = execTurn(binary: binary, cwd: folderX, home: homeS, resume: nil, prompt: "SIPAI-FX-EXSPEED one",
                             permissions: (CodexCapabilities.sandboxArgv(for: "workspace-write") ?? [])
                                + ["-c", "service_tier=priority"])
        let execThread = first.compactMap { line -> String? in
            let o = json(line)
            return o["type"] as? String == "thread.started" ? o["thread_id"] as? String : nil
        }.first
        _ = execTurn(binary: binary, cwd: folderX, home: homeS, resume: execThread, prompt: "SIPAI-FX-EXSPEED two",
                     permissions: (CodexCapabilities.sandboxArgv(for: "workspace-write") ?? [])
                        + ["-c", "service_tier=default"])
        let execTwo = fake.bodies(marked: "SIPAI-FX-EXSPEED two").last
        check("FX. the control: codex exec runs the second message at the first one's speed, whatever it is sent with",
              execTwo?["service_tier"] as? String == "priority",
              "\(String(describing: execTwo?["service_tier"]))")
    }

    // A command left running in a background terminal at the answer holds
    // a Workspace Write turn until it ends, as it holds a Default one.
    let homeB = makeHome(port: fake.port, extraTop: "background_terminal_max_timeout = 4000")
    defer { try? FileManager.default.removeItem(at: homeB) }
    let folderB = makeFolder()
    let hostB = HarnessHost(cwd: folderB)
    var bgSeconds = 0.0
    if let bg = driver("SIPAI-FX-BG go", "workspace-write") {
        bgSeconds = await runTurn(bg, host: hostB, binary: binary, home: homeB).bodySeconds
    }
    let bgOutput = hostB.signatures.firstIndex { $0.hasPrefix("output:") }
    let bgResult = hostB.signatures.firstIndex(of: "turn-result")
    check("FX. a Workspace Write turn ends only once the command it left running has, and the command ran to its end",
          exists(folderB.appendingPathComponent("bg-fixed.txt")) && bgSeconds >= 5
            && bgOutput != nil && bgResult != nil && bgOutput! < bgResult!
            && hostB.awaited.contains(["sleep 6; date > bg-fixed.txt"]),
          "\(String(format: "%.1f", bgSeconds)) s, \(hostB.awaited), \(hostB.signatures)")

    // An MCP server's asks: codex answers them itself under "never", as it
    // does on codex exec — no card.
    if FileManager.default.fileExists(atPath: formServerPath) {
        let serverLog = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cxfx-mcpforms-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: serverLog) }
        let homeM = makeHome(port: fake.port, model: "sipai-forms-model", extraTail: """
        [mcp_servers.forms]
        command = "/usr/bin/env"
        args = ["python3", "\(formServerPath)", "\(serverLog.path)"]
        """)
        defer { try? FileManager.default.removeItem(at: homeM) }
        let folderM = makeFolder()
        let hostM = HarnessHost(cwd: folderM)
        hostM.onCard = { $0.respond(.chose("accept")) }
        if let w = driver("SIPAI-FX-MCPW go", "workspace-write") {
            _ = await runTurn(w, host: hostM, binary: binary, home: homeM)
        }
        if let f = driver("SIPAI-FX-MCPF go", "workspace-write") {
            _ = await runTurn(f, host: hostM, binary: binary, home: homeM)
        }
        let toldW = fake.partOutputs(marked: "SIPAI-FX-MCPW").joined(separator: " | ")
        let toldF = fake.partOutputs(marked: "SIPAI-FX-MCPF").joined(separator: " | ")
        check("FX. an MCP server's tool that needs approval, and its form, reach no card in Workspace Write: codex refuses and declines them itself",
              hostM.cards.isEmpty && toldW.contains("approval policy is never")
                && toldF.contains(#"ELICITED {"action": "decline"}"#),
              "\(hostM.cards.count) cards; write_note: \(toldW); ask_form: \(toldF)")
    } else {
        skip("FX. an MCP server's asks in a fixed mode", "no stand-in MCP server at \(formServerPath)")
    }
}

Task { @MainActor in
    await live()
    print("\n\(passed) passed, \(failed) failed, \(skipped) skipped")
    exit(failed == 0 ? 0 : 1)
}
dispatchMain()
