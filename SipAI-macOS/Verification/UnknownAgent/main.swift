// UnknownAgent — the pure rules, asked about an agent SipAI has no code
// for and about the three it has.
//
// A key no agent has must get a fail-closed answer from every rule that
// dispatches on the agent: no front end, no flags, no speed, no asking
// modes, no Chat only, no skills folder, no rewind, no branch writer, no
// release endpoint, no install route, no rename write-through, no `!`
// route. The three agents' answers are asked too, so a fix that closes the
// door on the fourth cannot quietly move the first three.
import Foundation

var failures = 0
var passes = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    if ok {
        passes += 1
        print("  PASS  \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)" + (detail.isEmpty ? "" : " — \(detail)"))
    }
}

func section(_ title: String) {
    print("\n\(title)")
}

/// A key no agent has.
let unknown = "acme-cli"

func options(mode: String? = nil, chatOnly: Bool = false) -> AgentLaunchOptions {
    var o = AgentLaunchOptions()
    o.permissionMode = mode
    o.chatOnly = chatOnly
    return o
}

func pick(_ agent: String, _ o: AgentLaunchOptions = options(), new: Bool = false,
          frontEnd: Bool = false) -> AgentTurnDriver {
    AgentTurnDriver.pick(agentKey: agent, options: o, isNewSession: new, frontEndOffered: frontEnd)
}

section("1. A turn: its front end, its flags, its speed")

check("an agent with no route gets none, whatever the send",
      pick(unknown) == .unsupported && pick(unknown, new: true, frontEnd: true) == .unsupported
        && pick(unknown, options(mode: "plan"), frontEnd: true) == .unsupported
        && pick(unknown, options(chatOnly: true), new: true) == .unsupported,
      "\(pick(unknown))")
check("…and that route speaks no protocol", !AgentTurnDriver.unsupported.speaksJSONRPC)
check("claude: claude -p, unchanged", pick("claude_code") == .claudePrint
        && pick("claude_code", options(mode: "plan"), new: true, frontEnd: true) == .claudePrint)
check("codex: its front end where offered, codex exec below it, unchanged",
      pick("codex", frontEnd: true) == .codexAppServer && pick("codex") == .codexExec
        && pick("codex", options(chatOnly: true), frontEnd: true) == .codexExec)
check("kimi: kimi acp where offered, headless below it, its server for a new Chat only session, unchanged",
      pick("kimi", frontEnd: true) == .kimiAcp && pick("kimi") == .kimiPrint
        && pick("kimi", options(chatOnly: true), new: true) == .kimiWeb
        && pick("kimi", options(mode: AgentAskingMode.kimiNeverAsk), frontEnd: true) == .kimiPrint)

var everything = AgentLaunchOptions()
everything.permissionMode = "plan"
everything.model = "some-model"
everything.effort = "high"
everything.fastMode = true
check("an agent with no argv gets no flags — never another CLI's",
      everything.flags(for: unknown).isEmpty, "\(everything.flags(for: unknown))")
check("claude's flags, unchanged",
      everything.flags(for: "claude_code") == ["--permission-mode", "plan", "--model", "some-model",
                                               "--effort", "high",
                                               "--settings", AgentLaunchOptions.claudeFastModeSettings],
      "\(everything.flags(for: "claude_code"))")

let unknownRun = AgentLaunchOptions.scheduledRun(agent: unknown, mode: nil, model: "m", effort: "high",
                                                 fastMode: true, serviceTier: "priority")
check("a task of an agent with no speed runs at none",
      !unknownRun.fastMode && unknownRun.serviceTier == nil && unknownRun.codexServiceTierOverride == nil)
check("claude's task keeps its fast mode; codex's its tier, unchanged",
      AgentLaunchOptions.scheduledRun(agent: "claude_code", mode: nil, model: nil, effort: nil,
                                      fastMode: true, serviceTier: nil).fastMode
        && AgentLaunchOptions.scheduledRun(agent: "codex", mode: nil, model: nil, effort: nil,
                                           fastMode: false, serviceTier: "priority").serviceTier == "priority"
        && !AgentLaunchOptions.scheduledRun(agent: "kimi", mode: nil, model: nil, effort: nil,
                                            fastMode: true, serviceTier: nil).fastMode)

section("2. Modes, questions, Chat only, commands")

check("no front end, even where one would be offered",
      !AgentAskingMode.runsThroughFrontEnd(agentKey: unknown, mode: nil, chatOnly: false,
                                           frontEndOffered: true))
check("it asks no question — the Non-stop switch has nothing to answer",
      !AgentAskingMode.asksQuestions(agentKey: unknown, mode: nil, chatOnly: false, frontEndOffered: true)
        && !AgentAskingMode.asksQuestions(agentKey: unknown, mode: "plan", chatOnly: false))
check("claude asks in every mode but Chat only, unchanged",
      AgentAskingMode.asksQuestions(agentKey: "claude_code", mode: nil, chatOnly: false)
        && AgentAskingMode.asksQuestions(agentKey: "claude_code", mode: "plan", chatOnly: false)
        && !AgentAskingMode.asksQuestions(agentKey: "claude_code", mode: nil, chatOnly: true))
check("codex asks in Plan, and in Default through its front end, unchanged",
      AgentAskingMode.asksQuestions(agentKey: "codex", mode: AgentAskingMode.codexPlan, chatOnly: false)
        && AgentAskingMode.asksQuestions(agentKey: "codex", mode: nil, chatOnly: false, frontEndOffered: true)
        && !AgentAskingMode.asksQuestions(agentKey: "codex", mode: nil, chatOnly: false))
check("no asking modes offered",
      AgentAskingMode.offered(agentKey: unknown, kimiVersion: "99.0.0", codexVersion: "99.0.0",
                              codexModes: ["plan"]) == [])

check("no Chat only, whatever is read",
      !ChatOnlyAvailability.offered(agent: unknown, claudeHelp: nil, codexVersion: "99.0.0",
                                    codexFeatures: ChatOnlyAvailability.codexRequiredFeatures,
                                    kimiVersion: "99.0.0"))
check("…and that is settled: a saved Chat only pick is not held waiting for a read",
      ChatOnlyAvailability.isSettled(agent: unknown, claudeHelp: nil, codexVersion: nil,
                                     codexFeatures: nil, kimiVersion: nil))
check("Chat only for codex and kimi, unchanged",
      ChatOnlyAvailability.offered(agent: "codex", claudeHelp: nil, codexVersion: "99.0.0",
                                   codexFeatures: ChatOnlyAvailability.codexRequiredFeatures,
                                   kimiVersion: nil)
        && ChatOnlyAvailability.offered(agent: "kimi", claudeHelp: nil, codexVersion: nil,
                                        codexFeatures: nil, kimiVersion: "99.0.0"))

check("no claim about its slash commands",
      AgentSlashCommands.resolvesLocally(agentKey: unknown) == nil
        && AgentSlashCommands.resolvesLocally(agentKey: unknown, driver: .unsupported) == nil)
check("the three agents' slash-command answers, unchanged",
      AgentSlashCommands.resolvesLocally(agentKey: "claude_code") == true
        && AgentSlashCommands.resolvesLocally(agentKey: "codex") == false
        && AgentSlashCommands.resolvesLocally(agentKey: "kimi", driver: .kimiAcp) == true)
check("no route for a `!` line",
      ShellCommandSupport.verdict(agentKey: unknown, claudeVersion: "99.0.0", claudeReplayListed: true,
                                  codexVersion: "99.0.0") == nil)
check("the three agents' `!` routes, unchanged",
      ShellCommandSupport.verdict(agentKey: "codex", claudeVersion: nil, claudeReplayListed: nil,
                                  codexVersion: "99.0.0") == .runs
        && ShellCommandSupport.verdict(agentKey: "kimi", claudeVersion: nil, claudeReplayListed: nil,
                                       codexVersion: nil) == .noRoute
        && ShellCommandSupport.verdict(agentKey: "claude_code", claudeVersion: nil, claudeReplayListed: nil,
                                       codexVersion: nil) == .pending)
check("claude's environment is never set on another agent's child",
      ClaudePrintMode.environmentOverlay(agentKey: unknown, installedClaude: "1.0.0",
                                         cachedShellWait: false).isEmpty)
check("…and on claude's, unchanged",
      ClaudePrintMode.environmentOverlay(agentKey: "claude_code", installedClaude: "1.0.0",
                                         cachedShellWait: nil)
        == [ClaudePrintMode.disableBackgroundTasksEnvVar: "1"])

section("3. Its transcript: rewind, branch, rename")

check("no Send in place: SipAI has no rewind for it",
      AgentSessionRewind.support(agentKey: unknown, claudeNamesFlag: true, codexVersion: "99.0.0",
                                 kimiVersion: "99.0.0") == .unsupported)
check("the three agents' rewind answers, unchanged",
      AgentSessionRewind.support(agentKey: "claude_code", claudeNamesFlag: true, codexVersion: nil,
                                 kimiVersion: nil) == .offered
        && AgentSessionRewind.support(agentKey: "claude_code", claudeNamesFlag: nil, codexVersion: nil,
                                      kimiVersion: nil) == .pending
        && AgentSessionRewind.support(agentKey: "codex", claudeNamesFlag: nil, codexVersion: "0.0.1",
                                      kimiVersion: nil) == .needsNewer
        && AgentSessionRewind.support(agentKey: "kimi", claudeNamesFlag: nil, codexVersion: nil,
                                      kimiVersion: "99.0.0") == .offered)
check("no branch writer for it",
      !AgentSessionFork.hasWriter(agentKey: unknown) && !AgentSessionFork.hasWriter(agentKey: ""))
check("a writer for each of the three",
      ["claude_code", "codex", "kimi"].allSatisfy { AgentSessionFork.hasWriter(agentKey: $0) })
check("a branch of it is refused with words",
      AgentSessionFork.ForkError.agentNotSupported.errorDescription?.isEmpty == false)
check("no rename written into its store",
      !AgentSessionRename.writesThrough(unknown) && AgentSessionRename.writesThrough("claude_code")
        && AgentSessionRename.writesThrough("kimi") && !AgentSessionRename.writesThrough("codex"))

section("4. Skills")

let home = URL(fileURLWithPath: "/h", isDirectory: true)
let env = SkillEnvironment.resolve([:], home: home)
let project = URL(fileURLWithPath: "/p/proj", isDirectory: true)
check("no skills folder for an agent the skills code does not name — never claude's",
      SkillRoots.ownFolder(agent: unknown, scope: .global, env: env, projectRoot: nil) == nil
        && SkillRoots.ownFolder(agent: unknown, scope: .folder, env: env, projectRoot: project) == nil)
check("the three agents' folders, unchanged",
      SkillRoots.ownFolder(agent: SkillAgent.claude, scope: .global, env: env, projectRoot: nil)?.path
        == "/h/.claude/skills"
        && SkillRoots.ownFolder(agent: SkillAgent.codex, scope: .folder, env: env, projectRoot: project)?.path
        == "/p/proj/.codex/skills"
        && SkillRoots.ownFolder(agent: SkillAgent.kimi, scope: .folder, env: env, projectRoot: project)?.path
        == "/p/proj/.kimi-code/skills")
check("the scan reads the three agents' folders in their order, unchanged",
      SkillRoots.scanRoots(env: env, folder: nil, fileExists: { _ in false })
        .filter { $0.kind == .own }.map(\.url.path)
        == ["/h/.claude/skills", "/h/.codex/skills", "/h/.kimi-code/skills"])
check("its skill is named bare, never in claude's spelling",
      SkillAgent.invocation(of: "review", agent: unknown) == "review")
check("the three agents' spellings, unchanged",
      SkillAgent.invocation(of: "review", agent: SkillAgent.claude) == "/review"
        && SkillAgent.invocation(of: "review", agent: SkillAgent.codex) == "$review"
        && SkillAgent.invocation(of: "review", agent: SkillAgent.kimi) == "/skill:review")
check("a subfolder's skill is refused for it",
      SkillSubfolderReach.refusal(agent: unknown) != nil)
check("…and kept for kimi as before, offered to claude and codex where they reach it",
      SkillSubfolderReach.refusal(agent: SkillAgent.kimi)
        == "Loads only in a session started in its subfolder."
        && SkillSubfolderReach.refusal(agent: SkillAgent.claude) == nil
        && SkillSubfolderReach.refusal(agent: SkillAgent.codex, codex: .appServer) == nil)
let row = SkillRow(id: "x", name: "x", description: "", scope: .global, home: .library, realPath: nil,
                   entries: [:], frontmatter: SkillFrontmatter())
check("its on/off switch is refused with words",
      SkillSwitchRule.refusal(row: row, agent: unknown, label: "Acme")?.isEmpty == false)
check("the three agents' switches, unchanged",
      SkillSwitchRule.refusal(row: row, agent: SkillAgent.claude, label: "C") == nil
        && SkillSwitchRule.refusal(row: row, agent: SkillAgent.codex, label: "X") == nil
        && SkillSwitchRule.refusal(row: row, agent: SkillAgent.kimi, label: "K") != nil)

section("5. Settings: updates and install")

check("no release endpoint", AgentCLIRelease.measured(agentKey: unknown) == nil)
check("…the three agents keep theirs",
      ["claude_code", "codex", "kimi"].allSatisfy { AgentCLIRelease.measured(agentKey: $0) != nil })
check("no install route", AgentInstallRoute.route(agentKey: unknown) == nil)
check("…the three agents keep theirs",
      ["claude_code", "codex", "kimi"].allSatisfy { AgentInstallRoute.route(agentKey: $0) != nil })

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
