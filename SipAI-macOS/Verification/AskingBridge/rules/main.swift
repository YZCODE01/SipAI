// AskingBridge, rules half — compiled with the model files the other
// rule harnesses compile (see run.sh). Pure: which front end a send runs
// through, what a scheduled run becomes, what the headless argv carries.
import Foundation

var passed = 0
var failed = 0
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

print("\n3. Which front end a send runs through (AgentTurnDriver.pick, AgentAskingMode)")

func options(_ mode: String?, chatOnly: Bool = false) -> AgentLaunchOptions {
    var o = AgentLaunchOptions()
    o.permissionMode = mode
    o.chatOnly = chatOnly
    return o
}
func pick(_ agent: String, _ mode: String?, chatOnly: Bool = false, new: Bool = false,
          frontEnd: Bool = false) -> AgentTurnDriver {
    AgentTurnDriver.pick(agentKey: agent, options: options(mode, chatOnly: chatOnly), isNewSession: new,
                         frontEndOffered: frontEnd)
}

check("claude: every mode is claude -p, front end or not", [nil, "default", "plan", "bypassPermissions", "manual"]
        .allSatisfy { pick("claude_code", $0) == .claudePrint && pick("claude_code", $0, frontEnd: true) == .claudePrint })
check("codex: Read Only, Workspace Write and Full Access run through the app-server where the installed codex has it, codex exec where not",
      ["workspace-write", "read-only", "full-access"].allSatisfy {
          pick("codex", $0) == .codexExec && pick("codex", $0, frontEnd: true) == .codexAppServer
            && AgentAskingMode.isCodexFixed($0) })
check("…and they still never ask: no Non-stop for them, and nothing else is a fixed mode",
      ["workspace-write", "read-only", "full-access"].allSatisfy {
          !AgentAskingMode.asksQuestions(agentKey: "codex", mode: $0, chatOnly: false, frontEndOffered: true) }
        && ![nil, AgentAskingMode.codexPlan, "plan", "bypassPermissions", ""].contains {
            AgentAskingMode.isCodexFixed($0) })
check("codex: Default runs through the app-server where the installed codex has it, codex exec where not",
      pick("codex", nil, frontEnd: true) == .codexAppServer && pick("codex", nil) == .codexExec)
check("codex: Plan runs through the app-server",
      pick("codex", AgentAskingMode.codexPlan) == .codexAppServer)
check("kimi: Default runs through ACP where the installed kimi has it, kimi --prompt where not",
      pick("kimi", nil, frontEnd: true) == .kimiAcp && pick("kimi", nil) == .kimiPrint)
check("kimi: Never Ask is kimi --prompt; Ask When Needed and Plan run through ACP",
      pick("kimi", AgentAskingMode.kimiNeverAsk, frontEnd: true) == .kimiPrint
        && AgentAskingMode.kimi.allSatisfy { pick("kimi", $0) == .kimiAcp })
check("Chat only never takes an asking driver, whatever mode rode along",
      pick("codex", AgentAskingMode.codexPlan, chatOnly: true, frontEnd: true) == .codexExec
        && pick("codex", nil, chatOnly: true, frontEnd: true) == .codexExec
        && pick("kimi", AgentAskingMode.kimiPlan, chatOnly: true, new: true) == .kimiWeb
        && pick("kimi", nil, chatOnly: true, new: false, frontEnd: true) == .kimiPrint)
check("claude's own manual and plan, restored onto another agent's session, switch nothing on",
      pick("kimi", "manual") == .kimiPrint && pick("kimi", "plan") == .kimiPrint
        && pick("codex", "plan") == .codexExec && pick("codex", "manual") == .codexExec)
check("only the asking drivers speak JSON-RPC",
      AgentTurnDriver.codexAppServer.speaksJSONRPC && AgentTurnDriver.kimiAcp.speaksJSONRPC
        && ![AgentTurnDriver.claudePrint, .codexExec, .kimiPrint, .kimiWeb].contains { $0.speaksJSONRPC })

check("a value for a row no longer offered — codex's Agent, kimi's Always Ask — reads as Default",
      AgentAskingMode.normalized(AgentAskingMode.legacyCodexAgent) == nil
        && AgentAskingMode.normalized(AgentAskingMode.legacyKimiAlwaysAsk) == nil
        && AgentAskingMode.normalized("") == nil
        && AgentAskingMode.normalized(AgentAskingMode.kimiNeverAsk) == AgentAskingMode.kimiNeverAsk
        && AgentAskingMode.normalized("bypassPermissions") == "bypassPermissions")

let everyValue: [String?] = [nil, "default", "plan", "manual", "bypassPermissions", "acceptEdits",
                             "workspace-write", "read-only", "full-access", AgentAskingMode.kimiNeverAsk]
    + AgentAskingMode.codex.map(Optional.some) + AgentAskingMode.kimi.map(Optional.some)
var swapped: [String] = []
var nonStopUnasked: [String] = []
for agent in ["claude_code", "codex", "kimi"] {
    for mode in everyValue {
        let run = AgentLaunchOptions.scheduledRun(agent: agent, mode: mode, model: nil, effort: nil,
                                                  fastMode: false, serviceTier: nil)
        // The one value a FILE spells differently from the chip: a kimi
        // task with no mode is Never Ask (below).
        let expected = (agent == "kimi" && mode == nil) ? AgentAskingMode.kimiNeverAsk : mode
        if run.permissionMode != expected { swapped.append("\(agent)/\(mode ?? "nil")") }
        if run.nonStop { nonStopUnasked.append("\(agent)/\(mode ?? "nil")") }
    }
}
check("a scheduled run runs in its task's mode as picked, every agent × every mode value — nothing swapped",
      swapped.isEmpty, "\(swapped)")
check("a kimi task file with NO mode is Never Ask — what every such file ran as — and its Default is written out",
      AgentAskingMode.taskMode(agentKey: "kimi", fileMode: nil) == AgentAskingMode.kimiNeverAsk
        && AgentAskingMode.taskMode(agentKey: "kimi", fileMode: "") == AgentAskingMode.kimiNeverAsk
        && AgentAskingMode.taskMode(agentKey: "kimi", fileMode: AgentAskingMode.kimiTaskDefault) == nil
        && AgentAskingMode.taskMode(agentKey: "kimi", fileMode: AgentAskingMode.legacyKimiAlwaysAsk) == nil
        && AgentAskingMode.taskMode(agentKey: "kimi", fileMode: AgentAskingMode.kimiPlan) == AgentAskingMode.kimiPlan
        && AgentAskingMode.taskFileMode(agentKey: "kimi", mode: nil) == AgentAskingMode.kimiTaskDefault
        && AgentAskingMode.taskFileMode(agentKey: "kimi", mode: AgentAskingMode.kimiNeverAsk) == AgentAskingMode.kimiNeverAsk
        && AgentAskingMode.taskFileMode(agentKey: "kimi", mode: nil, frontEnd: .unavailable) == AgentAskingMode.kimiNeverAsk
        && AgentAskingMode.normalized(AgentAskingMode.kimiTaskDefault) == nil)
check("…so a kimi task from before modes existed still runs headless, and one written Default runs through ACP",
      { let legacy = AgentLaunchOptions.scheduledRun(agent: "kimi", mode: nil, model: nil, effort: nil,
                                                     fastMode: false, serviceTier: nil)
        let fresh = AgentLaunchOptions.scheduledRun(agent: "kimi", mode: AgentAskingMode.kimiTaskDefault,
                                                    model: nil, effort: nil, fastMode: false, serviceTier: nil)
        return AgentTurnDriver.pick(agentKey: "kimi", options: legacy, isNewSession: true,
                                    frontEndOffered: true) == .kimiPrint
            && fresh.permissionMode == nil
            && AgentTurnDriver.pick(agentKey: "kimi", options: fresh, isNewSession: true,
                                    frontEndOffered: true) == .kimiAcp }())
check("…claude's and codex's task files are read as before: no mode is Default, a legacy row is Default",
      AgentAskingMode.taskMode(agentKey: "claude_code", fileMode: nil) == nil
        && AgentAskingMode.taskMode(agentKey: "codex", fileMode: nil) == nil
        && AgentAskingMode.taskMode(agentKey: "codex", fileMode: AgentAskingMode.legacyCodexAgent) == nil
        && AgentAskingMode.taskMode(agentKey: "claude_code", fileMode: "auto") == "auto"
        && AgentAskingMode.taskFileMode(agentKey: "codex", mode: nil) == nil
        && AgentAskingMode.taskFileMode(agentKey: "claude_code", mode: "auto") == "auto")
check("the task card's Mode selection: Chat only, the file's mode, one row for claude's manual/default, one for an old kimi's Never Ask",
      AgentAskingMode.taskPickerValue(agentKey: "kimi", fileMode: nil, chatOnly: true,
                                      frontEnd: .offered, listedModes: []) == ChatOnlyMode.rowValue
        && AgentAskingMode.taskPickerValue(agentKey: "kimi", fileMode: nil, chatOnly: false,
                                           frontEnd: .offered, listedModes: []) == AgentAskingMode.kimiNeverAsk
        && AgentAskingMode.taskPickerValue(agentKey: "kimi", fileMode: nil, chatOnly: false,
                                           frontEnd: .unavailable, listedModes: []) == ""
        && AgentAskingMode.taskPickerValue(agentKey: "kimi", fileMode: AgentAskingMode.kimiTaskDefault,
                                           chatOnly: false, frontEnd: .offered, listedModes: []) == ""
        && AgentAskingMode.taskPickerValue(agentKey: "kimi", fileMode: AgentAskingMode.kimiAskWhenNeeded,
                                           chatOnly: false, frontEnd: .unavailable, listedModes: [])
            == AgentAskingMode.kimiAskWhenNeeded
        && AgentAskingMode.taskPickerValue(agentKey: "claude_code", fileMode: "default", chatOnly: false,
                                           frontEnd: .unavailable, listedModes: ["manual", "auto"]) == "manual"
        && AgentAskingMode.taskPickerValue(agentKey: "claude_code", fileMode: "manual", chatOnly: false,
                                           frontEnd: .unavailable, listedModes: ["default", "auto"]) == "default"
        && AgentAskingMode.taskPickerValue(agentKey: "claude_code", fileMode: "default", chatOnly: false,
                                           frontEnd: .unavailable, listedModes: ["default", "manual"]) == "default"
        && AgentAskingMode.taskPickerValue(agentKey: "claude_code", fileMode: nil, chatOnly: false,
                                           frontEnd: .unavailable, listedModes: ["manual"]) == ""
        && AgentAskingMode.taskPickerValue(agentKey: "codex", fileMode: AgentAskingMode.legacyCodexAgent,
                                           chatOnly: false, frontEnd: .offered, listedModes: []) == ""
        && AgentAskingMode.taskPickerValue(agentKey: "codex", fileMode: "workspace-write",
                                           chatOnly: false, frontEnd: .offered, listedModes: []) == "workspace-write")
check("…and is never Non-stop unless its task says so",
      nonStopUnasked.isEmpty
        && AgentLaunchOptions.scheduledRun(agent: "claude_code", mode: "auto", model: nil, effort: nil,
                                           fastMode: false, serviceTier: nil, nonStop: true).nonStop,
      "\(nonStopUnasked)")
check("…a task's asking mode runs through the agent's front end, as from the composer",
      AgentTurnDriver.pick(agentKey: "codex", options: AgentLaunchOptions.scheduledRun(
          agent: "codex", mode: AgentAskingMode.codexPlan, model: nil, effort: nil,
          fastMode: false, serviceTier: nil), isNewSession: true) == .codexAppServer
        && AgentTurnDriver.pick(agentKey: "kimi", options: AgentLaunchOptions.scheduledRun(
          agent: "kimi", mode: AgentAskingMode.kimiAskWhenNeeded, model: nil, effort: nil,
          fastMode: false, serviceTier: nil), isNewSession: true) == .kimiAcp)
check("…a Chat only task runs Chat only, its mode cleared, and a legacy mode runs as Default",
      { let r = AgentLaunchOptions.scheduledRun(agent: "codex", mode: "workspace-write", model: nil,
                                                effort: nil, fastMode: false, serviceTier: nil,
                                                chatOnly: true)
        return r.chatOnly && r.permissionMode == nil }()
        && AgentLaunchOptions.scheduledRun(agent: "codex", mode: AgentAskingMode.legacyCodexAgent,
                                           model: nil, effort: nil, fastMode: false,
                                           serviceTier: nil).permissionMode == nil)

check("an asking value never reaches a headless command line",
      options(AgentAskingMode.codexPlan).flags(for: "codex").isEmpty
        && AgentAskingMode.kimi.allSatisfy { options($0).flags(for: "kimi").isEmpty }
        && options(AgentAskingMode.kimiNeverAsk).flags(for: "kimi").isEmpty)

check("questions are asked: claude in every mode but Chat only; kimi in its asking modes and Default through its front end; codex in Plan, and in Default through its front end, where an MCP server's form stops the turn",
      AgentAskingMode.asksQuestions(agentKey: "claude_code", mode: nil, chatOnly: false)
        && !AgentAskingMode.asksQuestions(agentKey: "claude_code", mode: nil, chatOnly: true)
        && AgentAskingMode.kimi.allSatisfy { AgentAskingMode.asksQuestions(agentKey: "kimi", mode: $0, chatOnly: false) }
        && AgentAskingMode.asksQuestions(agentKey: "kimi", mode: nil, chatOnly: false, frontEndOffered: true)
        && !AgentAskingMode.asksQuestions(agentKey: "kimi", mode: nil, chatOnly: false)
        && !AgentAskingMode.asksQuestions(agentKey: "kimi", mode: AgentAskingMode.kimiNeverAsk, chatOnly: false,
                                          frontEndOffered: true)
        // Default where kimi's own configured default is Never Ask asks nothing.
        && !AgentAskingMode.asksQuestions(agentKey: "kimi", mode: nil, chatOnly: false, frontEndOffered: true,
                                          kimiDefaultPermission: "auto")
        && AgentAskingMode.asksQuestions(agentKey: "kimi", mode: nil, chatOnly: false, frontEndOffered: true,
                                         kimiDefaultPermission: "yolo")
        && AgentAskingMode.asksQuestions(agentKey: "kimi", mode: AgentAskingMode.kimiAskWhenNeeded, chatOnly: false,
                                         kimiDefaultPermission: "auto")
        && AgentAskingMode.asksQuestions(agentKey: "codex", mode: AgentAskingMode.codexPlan, chatOnly: false)
        && AgentAskingMode.asksQuestions(agentKey: "codex", mode: nil, chatOnly: false, frontEndOffered: true)
        && !AgentAskingMode.asksQuestions(agentKey: "codex", mode: nil, chatOnly: false)
        && !AgentAskingMode.asksQuestions(agentKey: "codex", mode: "workspace-write", chatOnly: false,
                                          frontEndOffered: true))
check("every asking value carries its agent's prefix",
      AgentAskingMode.codex.allSatisfy { $0.hasPrefix("codex-") }
        && AgentAskingMode.kimi.allSatisfy { $0.hasPrefix("kimi-") }
        && AgentAskingMode.kimiNeverAsk.hasPrefix("kimi-"))

check("an answer that NAMES a mode moves the chip wherever it was; one that only ends the planning moves a chip on Plan, to Default",
      AgentAskingMode.adoption(of: AgentAskingMode.kimiAskWhenNeeded, from: nil) == .set(AgentAskingMode.kimiAskWhenNeeded)
        && AgentAskingMode.adoption(of: AgentAskingMode.adoptDefault, from: AgentAskingMode.kimiPlan) == .set(nil)
        && AgentAskingMode.adoption(of: AgentAskingMode.adoptLeavingPlan, from: AgentAskingMode.kimiPlan) == .set(nil)
        && AgentAskingMode.adoption(of: AgentAskingMode.adoptLeavingPlan, from: AgentAskingMode.codexPlan) == .set(nil)
        && AgentAskingMode.adoption(of: AgentAskingMode.adoptLeavingPlan,
                                    from: AgentAskingMode.kimiAskWhenNeeded) == .keep
        && AgentAskingMode.adoption(of: "acceptEdits", from: "plan") == .set("acceptEdits"))

check("the front end's own gate: kimi and codex at their floors, pending until read, nothing for claude",
      AgentAskingMode.frontEndAvailability(agentKey: "kimi", kimiVersion: nil) == .pending
        && AgentAskingMode.frontEndAvailability(agentKey: "kimi", kimiVersion: AgentAskingMode.kimiVersionFloor) == .offered
        && AgentAskingMode.frontEndAvailability(agentKey: "kimi", kimiVersion: "2.0.9") == .unavailable
        && AgentAskingMode.frontEndAvailability(agentKey: "codex", kimiVersion: nil,
                                                codexVersion: AgentAskingMode.codexVersionFloor) == .offered
        && AgentAskingMode.frontEndAvailability(agentKey: "codex", kimiVersion: nil, codexVersion: "0.150.0") == .unavailable
        && AgentAskingMode.frontEndAvailability(agentKey: "claude_code", kimiVersion: "9", codexVersion: "9") == .unavailable)

print("\n3b. An answer handed back unsent goes into the message box (UnsentAnswers.boxText)")

let back = "> Which way?\n\nLeft"
check("an empty box takes the answer as it is; a box of blank space counts as empty",
      UnsentAnswers.boxText(back, over: "") == back && UnsentAnswers.boxText(back, over: " \n ") == back)
check("after what is typed there, a blank line between — Codex's own terminal appends it so",
      UnsentAnswers.boxText(back, over: "also check the logs") == "also check the logs\n\n" + back)
check("a box holding a ! command or a /command gets the answer FIRST: appended, it would be sent as part of the command (Codex escapes the command instead)",
      UnsentAnswers.boxText(back, over: "!echo partial") == back + "\n\n!echo partial"
        && UnsentAnswers.boxText(back, over: "  !git status") == back + "\n\n  !git status"
        && UnsentAnswers.boxText(back, over: "/compact keep the plan") == back + "\n\n/compact keep the plan"
        && ShellCommandInput.command(in: UnsentAnswers.boxText(back, over: "!echo partial")) == nil
        && AgentSlashCommands.leadingCommand(in: UnsentAnswers.boxText(back, over: "/compact")) == nil)
check("…while a pasted path is prose, and the answer goes after it",
      UnsentAnswers.boxText(back, over: "/Users/me/notes.md") == "/Users/me/notes.md\n\n" + back)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
