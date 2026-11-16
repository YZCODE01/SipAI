// Verification harness — the work an agent leaves running in the
// background in a SipAI turn: Claude Code's and Kimi Code's background
// tasks, Codex's background terminals.
//
// THE RULES.
//
//  * A claude that keeps a headless run going until a background task
//    ends, and reports it in a turn of its own, is allowed background
//    tasks (`ClaudePrintMode.allowsBackgroundTasks`): at or above the
//    oldest version measured to do so, unless claude's own cached copy
//    of the setting that wait sits behind says it is off. An older
//    claude, or one whose version is not read yet, keeps
//    `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` — it kills a background
//    task five seconds after the answer and says nothing a reader draws.
//  * A turn is not over at a `result` while claude still owes a report:
//    a background task it lists as running, or a task's notification
//    that no request has carried to the model yet
//    (`ClaudeBackgroundTasks.resultEndsTurn`). A command that merely ran
//    long in the foreground is no background task.
//  * A finished or stopped task is drawn as one notice, in the same words
//    live (claude's `system/task_notification`) and on reopen (the
//    `<task-notification>` record claude saves, as a user record or as a
//    queued-command attachment): a command's notice is Claude's own
//    sentence, an agent's names it by the description of the tool call
//    that started it (`ClaudeTaskNotice`).
//  * A notice drawn while claude still works on its turn goes into that
//    turn — claude hands the model the notification with its next
//    request — and brings no "Sipping…" back under it; one drawn after
//    claude's answer opens the report claude runs on it, and "Sipping…"
//    stands until the report (`ClaudeBackgroundTasks
//    .noticeGoesIntoRunningTurn`, `WaitingRow`).
//  * Kimi waits for a detached task and reports it in a turn of its own
//    on both its routes; its record is what says a task is running while
//    no turn is open (the line, `KimiSessionScanner.BackgroundTasks`) and
//    holds its notification, drawn as its title and first line on every
//    feed (`KimiTaskNotice`) — a headless turn's stdout carries none of it.
//  * Codex leaves a command running in a background terminal when
//    `exec_command` returns before it ends (`CodexBackgroundCommands`). The
//    turn waits on it once the model has answered; `codex exec` stops it
//    when the turn ends, and the turn says so in a notice
//    (`CodexBackgroundNotice`), live and read back off the rollout. The
//    app-server's hold is pinned in CodexAppServerBridge (BT).
//  * The waiting line is one builder for the three (`BackgroundTaskLine`),
//    in codex's own word for codex.
//
// Sections 1–4 are headless. Section 5 reads the installed claude's
// binary. Section 6 runs the installed claude against the ChatOnlyMode
// stand-in endpoint under a throwaway CLAUDE_CONFIG_DIR, and 6b the
// installed kimi and codex under throwaway homes — token-free — holding
// the rules above to what each actually does. Section 7 spends a real
// claude turn and is opt-in: SIPAI_BG_LIVE=1.

import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String, _ why: @autoclosure () -> String = "") {
    if ok { print("  ok    \(name)") }
    else {
        failures += 1
        print("  FAIL  \(name)")
        let w = why(); if !w.isEmpty { print("        \(w)") }
    }
}
func skip(_ name: String, _ why: String) { print("  SKIP  \(name) — \(why)") }

let args = CommandLine.arguments
let sourceRoot = args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath
let fakeServer = args.count > 2 ? args[2] : ""
func read(_ rel: String) -> String {
    (try? String(contentsOfFile: sourceRoot + "/" + rel, encoding: .utf8)) ?? ""
}
let scratchRoot = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
func scratch(_ tag: String) -> URL {
    let url = URL(fileURLWithPath: scratchRoot)
        .appendingPathComponent("sipai-bgtasks-\(tag)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
func line(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

// ── 1. the gate ──────────────────────────────────────────────────────
print("1. which claude may start background tasks")

let floor = ClaudePrintMode.backgroundTasksFloor
check(ClaudePrintMode.allowsBackgroundTasks(installedClaude: floor, cachedShellWait: nil),
      "claude \(floor) with nothing cached: allowed")
check(ClaudePrintMode.allowsBackgroundTasks(installedClaude: "2.1.400", cachedShellWait: true),
      "a newer claude with the wait cached on: allowed")
check(!ClaudePrintMode.allowsBackgroundTasks(installedClaude: "2.1.308", cachedShellWait: nil),
      "claude 2.1.308: not allowed",
      "below the oldest claude measured to wait for a task and report it")
check(!ClaudePrintMode.allowsBackgroundTasks(installedClaude: nil, cachedShellWait: nil),
      "a claude whose version is not read yet: not allowed",
      "an unread version is an unmeasured CLI")
check(!ClaudePrintMode.allowsBackgroundTasks(installedClaude: "2.1.400", cachedShellWait: false),
      "claude's cached setting turns the wait off: not allowed",
      "claude would kill the task five seconds after the answer")

let allowedEnv = ClaudePrintMode.environmentOverlay(agentKey: "claude_code",
                                                     installedClaude: "2.1.311", cachedShellWait: nil)
check(allowedEnv.isEmpty, "allowed: the switch is not set",
      "got \(allowedEnv) — the agent would still run every command in the foreground")
for (version, cached) in [("2.1.239", nil), (nil, nil), ("2.1.311", false)] as [(String?, Bool?)] {
    let env = ClaudePrintMode.environmentOverlay(agentKey: "claude_code",
                                                 installedClaude: version, cachedShellWait: cached)
    check(env[ClaudePrintMode.disableBackgroundTasksEnvVar] == "1",
          "not allowed (\(version ?? "unread"), cached \(cached.map(String.init) ?? "nothing")): the switch is set",
          "got \(env)")
}
for other in ["codex", "kimi", "", "some_future_agent"] {
    check(ClaudePrintMode.environmentOverlay(agentKey: other, installedClaude: "2.1.239",
                                             cachedShellWait: false).isEmpty,
          "\(other.isEmpty ? "(empty key)" : other) gets nothing",
          "codex has no such switch, and kimi's own handling of its tasks must be left alone")
}
// The switch overrides: a value inherited from the environment loses.
var env = ["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "0", "PATH": "/usr/bin"]
for (k, v) in ClaudePrintMode.environmentOverlay(agentKey: "claude_code", installedClaude: nil,
                                                 cachedShellWait: nil) { env[k] = v }
check(env["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] == "1" && env["PATH"] == "/usr/bin",
      "where it is set, an inherited =0 is overridden and nothing else moves")

func cache(_ value: Any?) -> Data {
    var root: [String: Any] = ["userID": "example"]
    if let value { root["cachedGrowthBookFeatures"] = ["another_setting": true,
                                                        ClaudePrintMode.shellWaitSetting: value] }
    return try! JSONSerialization.data(withJSONObject: root)
}
check(ClaudePrintMode.cachedShellWait(claudeJSON: cache(false)) == false, "a cached false reads false")
check(ClaudePrintMode.cachedShellWait(claudeJSON: cache(true)) == true, "a cached true reads true")
check(ClaudePrintMode.cachedShellWait(claudeJSON: cache(nil)) == nil, "nothing cached reads nil")
check(ClaudePrintMode.cachedShellWait(claudeJSON: cache("on")) == nil,
      "a value of another shape reads nil, never false")
check(ClaudePrintMode.cachedShellWait(claudeJSON: Data("not json".utf8)) == nil
      && ClaudePrintMode.cachedShellWait(claudeJSON: nil) == nil,
      "an unreadable or missing file reads nil")

// ── 2. the turn rule, over claude's stdout shapes ────────────────────
print("2. when a turn with background tasks is over")

func system(_ subtype: String, _ fields: [String: Any]) -> String {
    var o = fields; o["type"] = "system"; o["subtype"] = subtype; o["session_id"] = "s-example"
    return line(o)
}
func list(_ jobs: [[String: Any]]) -> String { system("background_tasks_changed", ["tasks": jobs]) }
let bashJob: [String: Any] = ["task_id": "bjob1", "run_id": "r1", "task_type": "local_bash",
                              "description": "Run the tests"]
let started = system("task_started", ["task_id": "bjob1", "run_id": "r1", "tool_use_id": "toolu_bg_1",
                                      "description": "Run the tests", "is_backgrounded": true,
                                      "task_type": "local_bash"])
let finished = system("task_notification", ["task_id": "bjob1", "run_id": "r1", "tool_use_id": "toolu_bg_1",
                                            "status": "completed", "output_file": "/tmp/claude-example/tasks/bjob1.output",
                                            "summary": "Background command \"Run the tests\" completed (exit code 0)"])

// (a) a command still running at the answer: the turn waits for its report.
var a = ClaudeBackgroundTasks()
_ = a.read(line: list([bashJob]))
_ = a.read(line: started)
a.noteRequestStarted()                         // the "running in background" tool result
check(!a.resultEndsTurn && a.running.map(\.description) == ["Run the tests"],
      "a task running at the answer: the answer is not the turn's end",
      "running \(a.running)")
let noticeA = a.read(line: finished)
check(noticeA == "Background command \"Run the tests\" completed (exit code 0)",
      "the finished command draws Claude's own sentence", String(describing: noticeA))
_ = a.read(line: list([]))
check(!a.resultEndsTurn, "notified but not yet reported: still not over")
a.noteRequestStarted()                         // the report turn's system/init
check(a.resultEndsTurn, "the report's result ends the turn")

// (b) an agent that finished just before the answer: claude still owes a turn.
var b = ClaudeBackgroundTasks()
let agentJob: [String: Any] = ["task_id": "ajob1", "run_id": "r2", "task_type": "local_agent",
                               "subagent_type": "general-purpose", "description": "Look around"]
_ = b.read(line: list([agentJob]))
b.noteRequestStarted()
let noticeB = b.read(line: system("task_notification", ["task_id": "ajob1", "tool_use_id": "toolu_ag_1",
                                                        "status": "completed", "summary": "OK"]))
_ = b.read(line: list([]))
check(noticeB == ClaudeTaskNotice.text(status: "completed", summary: "OK", kind: "local_agent",
                                      description: "Look around")
      && noticeB?.contains("Look around") == true && noticeB != "OK",
      "an agent's notice names it by its description, not by its answer", String(describing: noticeB))
check(!b.resultEndsTurn, "a notification after the last request: the answer is not the turn's end")
b.noteRequestStarted()
check(b.resultEndsTurn, "…and the extra turn's result is")

// (c) a task that ends while claude is still working: delivered in-turn.
var c = ClaudeBackgroundTasks()
_ = c.read(line: list([bashJob])); _ = c.read(line: started); c.noteRequestStarted()
_ = c.read(line: finished); _ = c.read(line: list([]))
c.noteRequestStarted()                         // the next tool result carries the notification
check(c.resultEndsTurn, "a notification a later request carried: the answer ends the turn")

// (d) a foreground command that ran long is no background task.
var d = ClaudeBackgroundTasks()
_ = d.read(line: system("task_started", ["task_id": "fg1", "tool_use_id": "toolu_fg_1", "description": "Build",
                                         "is_backgrounded": false, "task_type": "local_bash"]))
let noticeD = d.read(line: system("task_notification", ["task_id": "fg1", "status": "completed",
                                                        "summary": "Build"]))
check(noticeD == nil && d.resultEndsTurn && !d.sawTask,
      "a long foreground command: no notice, no wait", String(describing: noticeD))

// (e) what claude keeps for itself is not waited on.
var e = ClaudeBackgroundTasks()
_ = e.read(line: list([["task_id": "m1", "task_type": "monitor_ws", "description": "x", "ambient": true],
                       ["task_id": "g1", "task_type": "local_agent", "description": "y", "awaited": true]]))
check(e.running.isEmpty && e.resultEndsTurn, "ambient and awaited entries are not background tasks")

// (f) stopped at its own limit, and a bare summary.
var f = ClaudeBackgroundTasks()
_ = f.read(line: list([bashJob]))
let noticeF = f.read(line: system("task_notification", ["task_id": "bjob1", "status": "stopped",
    "summary": "Background command \"Run the tests\" was stopped after reaching its background time limit"]))
check(noticeF == "Background command \"Run the tests\" was stopped after reaching its background time limit",
      "stopped at its limit: Claude's sentence", String(describing: noticeF))
check(ClaudeTaskNotice.text(status: "stopped", summary: "Run the tests", kind: "local_bash",
                           description: "Run the tests")
      == ClaudeTaskNotice.text(status: "killed", summary: nil, kind: "local_bash", description: "Run the tests")
      && ClaudeTaskNotice.text(status: "stopped", summary: "Run the tests", kind: "local_bash",
                              description: "Run the tests").contains("Run the tests")
      && ClaudeTaskNotice.text(status: "stopped", summary: "Run the tests", kind: "local_bash",
                              description: "Run the tests") != "Run the tests",
      "a summary that is only the description is put in a sentence")
check(ClaudeTaskNotice.text(status: "failed", summary: nil, kind: nil, description: nil).isEmpty == false
      && ClaudeTaskNotice.text(status: "completed", summary: nil, kind: nil, description: nil)
         != ClaudeTaskNotice.text(status: "failed", summary: nil, kind: nil, description: nil),
      "with no name at all the notice still says what happened")

// (g) Where the notice stands for the waiting row ("Sipping…"). Drawn while
// claude still works on its turn, it goes into that turn — claude hands the
// model the notification with its next request — and brings no "Sipping…"
// back; drawn after claude's answer, it opens the report claude runs on it.
let message = StreamEvent(kind: .userMessage(text: "Start the job"))
let initEvent = StreamEvent(kind: .systemInit(sessionId: "s-example", model: "m", cwd: "/tmp"))
let bgCall = StreamEvent(kind: .toolUse(toolUseId: "toolu_bg_1", name: "Bash", input: [:]))
let bgStarted = StreamEvent(kind: .toolResult(toolUseId: "toolu_bg_1", output: "running in background", isError: false))
let answer = StreamEvent(kind: .assistantText(text: "Started it."))
let resultEvent = StreamEvent(kind: .result(durationMs: 1, totalCostUSD: nil, numTurns: 1,
                                            inputTokens: 1, outputTokens: 1))
func drawn(_ text: String, after events: [StreamEvent]) -> StreamEvent {
    StreamEvent(kind: .userMessage(text: text), isSystemNotice: true,
                sentIntoTurn: ClaudeBackgroundTasks.noticeGoesIntoRunningTurn(after: events))
}
func waits(_ events: [StreamEvent]) -> Bool { WaitingRow.awaitsAgent(events, compactionIsOutput: false) }
let working = [message, initEvent, bgCall, bgStarted]
let midTurn = drawn("Background command \"Run the tests\" completed (exit code 0)", after: working)
check(ClaudeBackgroundTasks.noticeGoesIntoRunningTurn(after: working) && !waits(working + [midTurn]),
      "a task that ends while claude still works: its notice goes into the turn, and no \"Sipping…\" comes back under it")
check(!WaitingRow.awaitsAgent(working + [midTurn], compactionIsOutput: true),
      "…and the stall notice does not read the turn as silent")
let answered = working + [answer, resultEvent]
let report = drawn("Background command \"Run the tests\" completed (exit code 0)", after: answered)
check(!ClaudeBackgroundTasks.noticeGoesIntoRunningTurn(after: answered) && waits(answered + [report])
      && waits(answered + [report, initEvent])
      && !waits(answered + [report, initEvent, StreamEvent(kind: .assistantText(text: "The tests passed."))]),
      "a task that ends after claude's answer: its notice opens the report, and \"Sipping…\" stands until the report's first words")
let reporting = answered + [report, initEvent]
check(ClaudeBackgroundTasks.noticeGoesIntoRunningTurn(after: reporting),
      "a second task ending while claude writes the report goes into the report")

// ── 3. the readers ───────────────────────────────────────────────────
print("3. the notice on reopen and in the tailer")

let root = scratch("readers")
let transcript = root.appendingPathComponent("s-example.jsonl")
func record(_ type: String, _ uuid: String, _ parent: String?, _ extra: [String: Any]) -> String {
    var o = extra
    o["type"] = type; o["uuid"] = uuid; o["sessionId"] = "s-example"
    o["parentUuid"] = parent ?? NSNull(); o["timestamp"] = "2026-01-02T03:04:05.000Z"
    o["cwd"] = "/tmp/example"
    return line(o)
}
let commandNote = "<task-notification>\n<task-id>bjob1</task-id>\n<tool-use-id>toolu_bg_1</tool-use-id>\n"
    + "<output-file>/tmp/claude-example/tasks/bjob1.output</output-file>\n<status>completed</status>\n"
    + "<summary>Background command \"Run the tests\" completed (exit code 0)</summary>\n</task-notification>"
let agentNote = "<task-notification>\n<task-id>ajob1</task-id>\n<tool-use-id>toolu_ag_1</tool-use-id>\n"
    + "<output-file>/tmp/claude-example/tasks/ajob1.output</output-file>\n<status>completed</status>\n"
    + "<summary>Agent \"Look around\" finished</summary>\n<note>The user can resume it.</note>\n"
    + "<result>OK</result>\n<usage><subagent_tokens>11</subagent_tokens></usage>\n</task-notification>"
let inTurnNote = commandNote.replacingOccurrences(of: "bjob1", with: "bjob2")
    .replacingOccurrences(of: "toolu_bg_1", with: "toolu_bg_2")
    .replacingOccurrences(of: "Run the tests", with: "Lint")
let lines = [
    record("user", "u1", nil, ["message": ["role": "user", "content": "Start the tests and look around."]]),
    record("assistant", "a1", "u1", ["message": ["role": "assistant", "model": "claude-example",
        "content": [["type": "tool_use", "id": "toolu_bg_1", "name": "Bash",
                     "input": ["command": "npm test", "description": "Run the tests", "run_in_background": true]],
                    ["type": "tool_use", "id": "toolu_ag_1", "name": "Agent",
                     "input": ["description": "Look around", "prompt": "Look around.", "run_in_background": true]]]]]),
    record("user", "u2", "a1", ["message": ["role": "user", "content": [
        ["type": "tool_result", "tool_use_id": "toolu_bg_1", "content": "Command running in background with ID: bjob1."],
        ["type": "tool_result", "tool_use_id": "toolu_ag_1", "content": "Async agent launched successfully."]]],
        "toolUseResult": ["backgroundTaskId": "bjob1"]]),
    record("assistant", "a2", "u2", ["message": ["role": "assistant", "model": "claude-example",
        "content": [["type": "tool_use", "id": "toolu_bg_2", "name": "Bash",
                     "input": ["command": "npm run lint", "description": "Lint", "run_in_background": true]]]]]),
    record("user", "u3", "a2", ["message": ["role": "user", "content": [
        ["type": "tool_result", "tool_use_id": "toolu_bg_2", "content": "Command running in background with ID: bjob2."]]],
        "toolUseResult": ["backgroundTaskId": "bjob2"]]),
    record("attachment", "t1", "u3", ["attachment": ["type": "queued_command", "prompt": inTurnNote,
                                                     "commandMode": "task-notification"]]),
    record("assistant", "a3", "t1", ["message": ["role": "assistant", "model": "claude-example",
        "content": [["type": "text", "text": "Started both."]]]]),
    record("user", "n1", "a3", ["message": ["role": "user", "content": commandNote],
                                "origin": ["kind": "task-notification", "producer": "session-task"]]),
    record("assistant", "a4", "n1", ["message": ["role": "assistant", "model": "claude-example",
        "content": [["type": "text", "text": "The tests passed."]]]]),
    record("user", "n2", "a4", ["message": ["role": "user", "content": agentNote],
                                "origin": ["kind": "task-notification", "producer": "session-task"]]),
    record("assistant", "a5", "n2", ["message": ["role": "assistant", "model": "claude-example",
        "content": [["type": "text", "text": "The agent is done."]]]]),
]
try! (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
let items = AgentSessionScanner.readHistory(of: transcript)
let notices: [String] = items.compactMap { item in
    guard item.isSystemNotice, case .userText(let text) = item.kind else { return nil }
    return text
}
let expectedAgent = ClaudeTaskNotice.text(status: "completed", summary: "OK", kind: "local_agent",
                                         description: "Look around")
check(notices == ["Background command \"Lint\" completed (exit code 0)",
                  "Background command \"Run the tests\" completed (exit code 0)",
                  expectedAgent],
      "reopen: one notice per task, in the live words, the in-turn one included", "got \(notices)")
check(!notices.contains { $0.contains("bjob") || $0.contains("/tmp/") || $0.contains("toolu_") },
      "reopen: no task id, tool id or output path in a notice")
let userRows = items.filter { if case .userText = $0.kind { return !$0.isSystemNotice } else { return false } }
check(userRows.count == 1, "reopen: the notices are not the user's messages", "\(userRows.count) user rows")

let tailed = AgentEventParser.parse(line: lines[7], fallbackCwd: root, includeUserMessages: true)
if case .userMessage(let text)? = tailed.first?.kind {
    check(tailed.first?.isSystemNotice == true
          && text == "Background command \"Run the tests\" completed (exit code 0)",
          "tailer: the saved notification reads as the same notice", text)
} else { check(false, "tailer: the saved notification reads as a notice", "\(tailed.map(\.kind))") }
let tailedAttachment = AgentEventParser.parse(line: lines[5], fallbackCwd: root, includeUserMessages: true)
if case .userMessage(let text)? = tailedAttachment.first?.kind {
    check(tailedAttachment.first?.isSystemNotice == true
          && text == "Background command \"Lint\" completed (exit code 0)",
          "tailer: an in-turn notification reads as the same notice", text)
} else { check(false, "tailer: an in-turn notification reads as a notice", "\(tailedAttachment.map(\.kind))") }
check(AgentEventParser.parse(line: lines[5], fallbackCwd: root).isEmpty,
      "our own stdout never draws a saved record (the live notice comes from task_notification)")
// Compact view draws everything between the user's message and the final
// message in one line: a task's notice belongs to the agent's answer. And a
// notification claude handed the model mid-turn goes into that turn on
// reopen and in the tailer, as it does live.
let noticeItems = items.filter(\.isSystemNotice)
let inTurnItem = noticeItems.first { item in
    if case .userText(let text) = item.kind { return text.contains("\"Lint\"") }
    return false
}
check(noticeItems.count == 3 && noticeItems.allSatisfy(\.belongsToAnswer),
      "reopen: every task notice belongs to the agent's answer",
      "\(noticeItems.map(\.belongsToAnswer))")
check(inTurnItem?.sentIntoTurn == true
      && noticeItems.filter(\.sentIntoTurn).count == 1,
      "reopen: the notification claude handed the model mid-turn goes into that turn, as it does live")
check(userRows.allSatisfy { !$0.belongsToAnswer && !$0.sentIntoTurn },
      "reopen: the user's own message belongs to nobody's answer")
check(tailed.first?.belongsToAnswer == true && tailed.first?.sentIntoTurn == false
      && tailedAttachment.first?.belongsToAnswer == true && tailedAttachment.first?.sentIntoTurn == true,
      "tailer: the same — the report belongs to the answer, the mid-turn one goes into its turn")
// A Monitor event (claude's Monitor tool): no status and no tool id, the
// watched command's lines in `<event>`.
let monitorNote = "<task-notification>\n<task-id>bwatch1</task-id>\n"
    + "<summary>Monitor event: \"sweep results\"</summary>\n<event>Build exit=0 12s</event>\n</task-notification>"
let monitorLine = record("user", "n3", "a5", ["message": ["role": "user", "content": monitorNote],
                                              "origin": ["kind": "task-notification", "producer": "session-task"]])
let tailedMonitor = AgentEventParser.parse(line: monitorLine, fallbackCwd: root, includeUserMessages: true)
check(tailedMonitor.count == 1 && tailedMonitor.first?.isSystemNotice == true
      && tailedMonitor.first?.belongsToAnswer == true,
      "a Monitor event is a notice that belongs to the agent's answer", "\(tailedMonitor.map(\.kind))")
// What it says: claude's own terminal draws a Monitor event as its first
// line, then the watch's description (read in the 2.1.316 bundle) — never
// the description alone, which is the same sentence for every event.
let monitorWords = ClaudeTaskNotice.saved(monitorNote, description: { _ in nil })
check(monitorWords == "Monitor event: Build exit=0 12s · sweep results",
      "a Monitor event reads as claude's terminal draws it: the event's first line, then the watch",
      String(describing: monitorWords))
if case .userMessage(let text)? = tailedMonitor.first?.kind {
    check(text == "Monitor event: Build exit=0 12s · sweep results", "tailer: the same words", text)
} else { check(false, "tailer: the Monitor event reads as a notice", "\(tailedMonitor.map(\.kind))") }
// Claude escapes `&`, `<` and `>` in both parts; the event is the command's
// own output, colours and all.
let messyMonitor = "<task-notification>\n<task-id>bwatch2</task-id>\n"
    + "<summary>Monitor event: \"logs &amp; tests\"</summary>\n"
    + "<event>\u{1B}[2K\n\u{1B}[32mPASS\u{1B}[0m   a &lt;b&gt;\tc\nsecond line</event>\n</task-notification>"
let messyWords = ClaudeTaskNotice.saved(messyMonitor, description: { _ in nil })
check(messyWords == "Monitor event: PASS a <b> c · logs & tests",
      "…its escapes undone, colours and runs of white space taken out, the first line that says something",
      String(describing: messyWords))
let watchEnded = "<task-notification>\n<task-id>bwatch1</task-id>\n<tool-use-id>toolu_w1</tool-use-id>\n"
    + "<status>completed</status>\n<summary>Monitor \"sweep results\" stream ended</summary>\n"
    + "<event>Lint exit=0 4s\nDONE</event>\n</task-notification>"
check(ClaudeTaskNotice.saved(watchEnded, description: { _ in "sweep results" })
          == "Monitor \"sweep results\" stream ended",
      "the watch's end keeps claude's own sentence")
let malformed = monitorNote.replacingOccurrences(of: "Build exit=0 12s", with: "<b>raw</b>")
check(ClaudeTaskNotice.saved(malformed, description: { _ in nil }) == "Monitor event: \"sweep results\"",
      "an event that is not escaped as claude escapes it is not read: claude's summary stands")
try? FileManager.default.removeItem(at: root)

// ── 3b. kimi ─────────────────────────────────────────────────────────
print("3b. kimi: the line, the notice, live and on reopen")

// Kimi's notification of a finished task, in the shapes kimi 2.3 writes.
func kimiNote(_ status: String, title: String, body: String, child: String? = nil) -> String {
    var lines = ["<notification id=\"task:bash-k1:\(status)\" category=\"task\" type=\"task.\(status)\" "
                 + "source_kind=\"background_task\" source_id=\"bash-k1\">",
                 "Title: \(title)", "Severity: \(status == "completed" ? "info" : "warning")",
                 "Wall time: 15.012 seconds", body]
    if let child { lines.append(child) }
    lines.append("</notification>")
    return lines.joined(separator: "\n")
}
let outputFile = "<output-file path=\"/tmp/kimi-example/sessions/wd_x/session_x/agents/main/tasks/bash-k1/output.log\" "
    + "bytes=\"18\">\nRead the output file to retrieve the result: /tmp/kimi-example/output.log\n</output-file>"
let kimiShapes: [(String, String, String)] = [
    (kimiNote("completed", title: "Background process completed", body: "Sleep then write a file completed."),
     "Background process completed · Sleep then write a file completed.", "completed"),
    (kimiNote("failed", title: "Background process failed", body: "Run the tests failed.", child: outputFile),
     "Background process failed · Run the tests failed.", "failed, with its output file"),
    (kimiNote("timed_out", title: "Background process timed_out", body: "Run the tests timed out."),
     "Background process timed out · Run the tests timed out.", "timed out (kimi spells the status as an id)"),
    (kimiNote("completed", title: "Background process completed", body: "Build completed.", child: outputFile),
     "Background process completed · Build completed.", "completed, with its output file"),
]
for (raw, expected, name) in kimiShapes {
    let got = KimiTaskNotice.text(fromNotification: raw)
    check(got == expected, "kimi's notice, \(name): its title and its first line", String(describing: got))
}
check(KimiTaskNotice.text(fromNotification: "Title: x\nnot a notification") == nil,
      "anything else is no notification")

// A headless turn's record, in kimi's own record shapes (2.3.3, measured):
// the task starts, the turn ends on its answer, the task ends, kimi opens a
// turn on its notification and reports.
func kimiRecord(_ type: String, _ time: Int, _ fields: [String: Any]) -> String {
    var o = fields; o["type"] = type; o["time"] = time
    return line(o)
}
let kimiTaskInfo: [String: Any] = ["taskId": "bash-k1", "description": "Sleep then write a file",
                                   "status": "running", "detached": true, "startedAt": 1_790_000_000_100,
                                   "timeoutMs": 600_000, "kind": "process", "command": "sleep 15; date > done.txt"]
var endedInfo = kimiTaskInfo; endedInfo["status"] = "completed"; endedInfo["endedAt"] = 1_790_000_015_100
let kimiWire = [
    kimiRecord("turn.prompt", 1_790_000_000_000, ["agentId": "main", "promptId": "msg_A", "turnId": 0,
                                                  "origin": ["kind": "user"],
                                                  "input": [["type": "text", "text": "Start it in the background."]]]),
    kimiRecord("context.append_message", 1_790_000_000_001, ["agentId": "main", "message": [
        "role": "user", "id": "msg_A", "origin": ["kind": "user"], "toolCalls": [],
        "content": [["type": "text", "text": "Start it in the background."]]]]),
    kimiRecord("context.append_loop_event", 1_790_000_000_050, ["agentId": "main", "event": [
        "type": "tool.call", "toolCallId": "c1", "name": "Bash",
        "args": ["command": "sleep 15; date > done.txt", "run_in_background": true,
                 "description": "Sleep then write a file"]]]),
    kimiRecord("task.started", 1_790_000_000_100, ["agentId": "main", "info": kimiTaskInfo]),
    kimiRecord("context.append_loop_event", 1_790_000_000_101, ["agentId": "main", "event": [
        "type": "tool.result", "toolCallId": "c1", "result": ["output": "task_id: bash-k1\nstatus: running"]]]),
    kimiRecord("context.append_loop_event", 1_790_000_000_200, ["agentId": "main", "event": [
        "type": "content.part", "part": ["type": "text", "text": "Started it."]]]),
    kimiRecord("turn.ended", 1_790_000_000_300, ["agentId": "main", "turnId": 0, "reason": "completed"]),
    kimiRecord("task.terminated", 1_790_000_015_110, ["agentId": "main", "info": endedInfo]),
    kimiRecord("turn.prompt", 1_790_000_015_113, ["agentId": "main", "promptId": "msg_B", "turnId": 1,
        "origin": ["kind": "task", "taskId": "bash-k1", "status": "completed",
                   "notificationId": "task:bash-k1:completed"]]),
    kimiRecord("context.append_message", 1_790_000_015_113, ["agentId": "main", "message": [
        "role": "user", "id": "msg_B", "toolCalls": [],
        "origin": ["kind": "task", "taskId": "bash-k1", "status": "completed"],
        "content": [["type": "text", "text": kimiShapes[0].0]]]]),
    kimiRecord("context.append_loop_event", 1_790_000_015_500, ["agentId": "main", "event": [
        "type": "content.part", "part": ["type": "text", "text": "It finished."]]]),
    kimiRecord("turn.ended", 1_790_000_015_600, ["agentId": "main", "turnId": 1, "reason": "completed"]),
]
var kimiTasks = KimiSessionScanner.BackgroundTasks()
var kimiAwaited: [[String]] = []
var kimiNotices: [(text: String, time: Date?)] = []
for raw in kimiWire {
    let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    if let notice = kimiTasks.feed(record: object, now: Date()) { kimiNotices.append(notice) }
    kimiAwaited.append(kimiTasks.awaited.map(\.description))
}
check(kimiAwaited[3] == [] && kimiAwaited[5] == [],
      "kimi: no line while the turn that started the task is still working", "\(kimiAwaited)")
check(kimiAwaited[6] == ["Sleep then write a file"],
      "kimi: the answer has landed and the task runs: the line names it", "\(kimiAwaited)")
check(kimiAwaited[7...].allSatisfy(\.isEmpty), "kimi: the task over, then its report turn open: no line",
      "\(kimiAwaited)")
check(kimiNotices.map(\.text) == ["Background process completed · Sleep then write a file completed."]
      && kimiNotices.first?.time == Date(timeIntervalSince1970: 1_790_000_015.113),
      "kimi: the notification read live is the short notice, with the time kimi wrote it",
      "\(kimiNotices)")
var foreground = KimiSessionScanner.BackgroundTasks()
var fgInfo = kimiTaskInfo; fgInfo["detached"] = false
_ = foreground.feed(record: ["type": "task.started", "info": fgInfo], now: Date())
_ = foreground.feed(record: ["type": "turn.ended"], now: Date())
check(foreground.awaited.isEmpty, "kimi: a task that is not detached is nobody's wait")

let kimiRoot = scratch("kimi")
let kimiWireFile = kimiRoot.appendingPathComponent("wire.jsonl")
try! (kimiWire.joined(separator: "\n") + "\n").write(to: kimiWireFile, atomically: true, encoding: .utf8)
let kimiReopened = KimiSessionScanner.readHistory(of: kimiWireFile).compactMap { item -> String? in
    guard item.isSystemNotice, case .userText(let text) = item.kind else { return nil }
    return text
}
check(kimiReopened == kimiNotices.map(\.text), "kimi: reopened, the same notice", "\(kimiReopened)")
check(!kimiReopened.contains { $0.contains("Wall time") || $0.contains("/tmp/") || $0.contains("bash-k1") },
      "kimi: no wall time, task id or path in the notice")
let kimiNoticeItems = KimiSessionScanner.readHistory(of: kimiWireFile).filter(\.isSystemNotice)
check(kimiNoticeItems.count == 1 && kimiNoticeItems.allSatisfy(\.belongsToAnswer)
      && KimiSessionScanner.readHistory(of: kimiWireFile).filter { !$0.isSystemNotice }.allSatisfy { !$0.belongsToAnswer },
      "kimi: reopened, the notice belongs to the agent's answer, the user's message does not")
check(kimiNoticeItems.compactMap(AgentSessionTailer.liveEvent(for:)).allSatisfy(\.belongsToAnswer),
      "kimi: watched live (the tailer, the ACP turn's follower), the same")
try? FileManager.default.removeItem(at: kimiRoot)

// ── 3c. codex ────────────────────────────────────────────────────────
print("3c. codex: the line, the commands a turn leaves running, and the notice")

let longCommand = "python3 - <<'EOF'\n" + String(repeating: "x", count: 200) + "\nEOF"
check(BackgroundTaskLine.text([BackgroundTaskEntry(id: "c", kind: "command", description: "npm run dev")],
                              terminals: true) == "Waiting for a background terminal: npm run dev",
      "codex's line names a background terminal, codex's own word")
check(BackgroundTaskLine.text([BackgroundTaskEntry(id: "t", kind: "local_bash", description: "Run the tests")],
                              terminals: false) == "Waiting for a background task: Run the tests",
      "claude's and kimi's line names a background task")
check(BackgroundTaskLine.shown(longCommand) == "python3 - <<'EOF'"
      && BackgroundTaskLine.shown(String(repeating: "y", count: 300)).count == BackgroundTaskLine.nameLimit + 1,
      "a long command is named by its first line, cut short")

// `codex exec --json`'s stdout, in codex 0.164's shapes (measured).
let execLines = [
    #"{"type":"thread.started","thread_id":"01a1-example"}"#,
    #"{"type":"turn.started"}"#,
    #"{"type":"item.started","item":{"id":"item_0","type":"command_execution","command":"/bin/zsh -lc 'sleep 15; date > done.txt'","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#,
    #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'ls'","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#,
    #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'ls'","aggregated_output":"done.txt\n","exit_code":0,"status":"completed"}}"#,
    #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Started it."}}"#,
    #"{"type":"turn.completed","usage":{"input_tokens":20,"output_tokens":2}}"#,
]
var execCommands = CodexBackgroundCommands()
for raw in execLines { execCommands.read(line: raw) }
check(execCommands.running.map(\.description) == ["sleep 15; date > done.txt"],
      "codex: a command started and not completed at the answer is still running, named without its shell",
      "\(execCommands.running)")
check(execCommands.awaited.map(\.description) == ["sleep 15; date > done.txt"],
      "codex: the answer has landed — the line names it")
var commentary = CodexBackgroundCommands()
commentary.read(object: ["type": "item.started", "item": ["id": "c1", "type": "command_execution", "command": "make"]])
commentary.read(object: ["type": "item.completed", "item": ["id": "m1", "type": "agent_message", "text": "Building…",
                                                            "phase": "commentary"]])
check(commentary.awaited.isEmpty && commentary.running.count == 1,
      "codex: words between steps are no answer — no line yet")
commentary.read(object: ["type": "item.completed", "item": ["id": "m2", "type": "agent_message", "text": "Done.",
                                                            "phase": "final_answer"]])
commentary.read(object: ["type": "item.completed", "item": ["id": "c1", "type": "command_execution",
                                                            "command": "make", "status": "completed"]])
check(commentary.answered && commentary.running.isEmpty && commentary.awaited.isEmpty,
      "codex: the command finishing after the answer leaves the answer the answer, and nothing waited on")
check(CodexBackgroundNotice.stopped(command: "sleep 15; date > done.txt")
      == "Background command stopped when the turn ended: sleep 15; date > done.txt",
      "codex: the notice names the command it stopped")

// The rollout, in codex 0.164's shapes (measured): an exec turn whose
// command outlives its answer — codex stops it as the turn ends.
func rollout(_ type: String, _ payload: [String: Any]) -> String {
    line(["timestamp": "2026-01-02T03:04:05.000Z", "type": type, "payload": payload])
}
func codexTurn(_ turn: String, trigger: String?, outputs: [String], extra: [String] = []) -> [String] {
    var attribution: [String: Any] = ["turn_id": turn]
    attribution["turn_trigger"] = trigger ?? NSNull()
    return [
        rollout("event_msg", ["type": "task_started", "turn_id": turn, "turn_attribution": attribution]),
        rollout("response_item", ["type": "message", "role": "user",
                                  "content": [["type": "input_text", "text": "Start it in the background."]]]),
        rollout("response_item", ["type": "function_call", "name": "exec_command", "call_id": "call_1",
                                  "arguments": #"{"cmd": "sleep 15; date > done.txt", "yield_time_ms": 1000}"#]),
        rollout("response_item", ["type": "function_call_output", "call_id": "call_1", "output": outputs[0]]),
    ] + extra + [
        rollout("response_item", ["type": "message", "role": "assistant",
                                  "content": [["type": "output_text", "text": "Started it."]]]),
        rollout("event_msg", ["type": "task_complete", "turn_id": turn, "last_agent_message": "Started it."]),
    ]
}
let runningOutput = "Chunk ID: 1a2b3c\nWall time: 1.0020 seconds\nProcess running with session ID 27679\n"
    + "Original token count: 0\nOutput:\n"
let lateKill = rollout("event_msg", ["type": "item_completed", "turn_id": "t1", "item": [
    "type": "CommandExecution", "id": "call_1", "process_id": "27679", "status": "failed", "exit_code": -1,
    "command": ["/bin/zsh", "-lc", "sleep 15; date > done.txt"], "source": "unified_exec_startup"]])
func reopenedNotices(_ lines: [String]) -> [String] {
    var decoder = CodexSessionScanner.RolloutDecoder()
    return lines.flatMap { decoder.items(forLine: $0) }.compactMap { item in
        guard item.isSystemNotice, case .userText(let text) = item.kind else { return nil }
        return text
    }
}
let stopped = CodexBackgroundNotice.stopped(command: "sleep 15; date > done.txt")
check(reopenedNotices(codexTurn("t1", trigger: "exec", outputs: [runningOutput])) == [stopped],
      "codex reopened: an exec turn's command still running at its end reads as the notice")
check(reopenedNotices(codexTurn("t1", trigger: "exec", outputs: [runningOutput]) + [lateKill]) == [stopped],
      "codex reopened: codex's own record of the stop, where it wrote one, adds no second notice")
check(reopenedNotices(codexTurn("t1", trigger: nil, outputs: [runningOutput])).isEmpty,
      "codex reopened: a turn codex's own clients ran — which keep the command running — gets none")
let exitedPoll = [
    rollout("response_item", ["type": "function_call", "name": "write_stdin", "call_id": "call_2",
                              "arguments": #"{"session_id": 27679, "chars": "", "yield_time_ms": 30000}"#]),
    rollout("response_item", ["type": "function_call_output", "call_id": "call_2",
                              "output": "Chunk ID: 4d5e6f\nWall time: 14.0 seconds\nProcess exited with code 0\nOutput:\n"]),
]
check(reopenedNotices(codexTurn("t1", trigger: "exec", outputs: [runningOutput], extra: exitedPoll)).isEmpty,
      "codex reopened: a command the model waited on until it ended gets none")
let doneOutput = "Chunk ID: 1a2b3c\nWall time: 0.2 seconds\nProcess exited with code 0\nOutput:\nok\n"
check(reopenedNotices(codexTurn("t1", trigger: "exec", outputs: [doneOutput])).isEmpty,
      "codex reopened: a command that ended in the foreground gets none")
let inTurnEnd = [rollout("event_msg", ["type": "item_completed", "turn_id": "t1", "item": [
    "type": "CommandExecution", "id": "call_1", "process_id": "27679", "status": "completed", "exit_code": 0]])]
check(reopenedNotices(codexTurn("t1", trigger: "exec", outputs: [runningOutput], extra: inTurnEnd)).isEmpty,
      "codex reopened: a command codex recorded ending within the turn gets none")
// Compact view draws everything between the user's message and the final
// message in one line. The user's reply on a question's card belongs to the
// agent's answer; codex's stopped-command notice comes after the final
// message, and is no report.
var replyDecoder = CodexSessionScanner.RolloutDecoder()
let replyText = CodexSessionScanner.questionReplyOpen + "\n"
    + #"[{"answer":"Blue","question":"Which colour?","questionItemId":"q-1"}]"# + "\n"
    + CodexSessionScanner.questionReplyClose
let replyItems = replyDecoder.items(forLine: rollout("response_item", [
    "type": "message", "role": "user", "content": [["type": "input_text", "text": replyText]]]))
check(replyItems.count == 1 && replyItems.first?.sentIntoTurn == true && replyItems.first?.belongsToAnswer == true,
      "codex: the reply given on a question's card goes into the turn and belongs to the answer",
      "\(replyItems.map(\.kind))")
check(replyItems.compactMap(AgentSessionTailer.liveEvent(for:)).allSatisfy(\.belongsToAnswer),
      "codex: watched live (the tailer), the same")
var stoppedDecoder = CodexSessionScanner.RolloutDecoder()
check(codexTurn("t1", trigger: "exec", outputs: [runningOutput]).flatMap { stoppedDecoder.items(forLine: $0) }
          .filter(\.isSystemNotice).allSatisfy { !$0.belongsToAnswer },
      "codex: the stopped-command notice is no report: it stays after the final message")

// ── 4. wiring ────────────────────────────────────────────────────────
print("4. the runner and the transcript use the rules")

let runner = read("SipAI/Models/AgentRunner.swift")
let view = read("SipAI/Views/Chat/AgentSessionView.swift")
check(!runner.isEmpty && !view.isEmpty, "the sources are readable at \(sourceRoot)")
check(runner.contains("ClaudePrintMode.environmentOverlay(agentKey: agentKey,"),
      "runOnce applies the gate with the installed version")
if let overlayAt = runner.range(of: "ClaudePrintMode.environmentOverlay(agentKey: agentKey,"),
   let buildAt = runner.range(of: "var env = Self.buildEnvironment()") {
    check(buildAt.lowerBound < overlayAt.lowerBound, "applied AFTER buildEnvironment",
          "applying it before lets an inherited value win")
} else { check(false, "applied AFTER buildEnvironment", "anchors not found") }
check(runner.contains("backgroundTasks.read(line: line)"), "every claude stdout line feeds the rule")
check(runner.contains("backgroundTasks.resultEndsTurn"), "a result asks the rule before ending the turn")
check(runner.contains("backgroundTasks.noteRequestStarted()"), "a request start is noted")
check(runner.contains("heldTurnFailure"), "a held result's verdict reaches the turn's end")
check(runner.contains("sentIntoTurn: ClaudeBackgroundTasks.noticeGoesIntoRunningTurn(after: events)"),
      "a claude task's notice is drawn as going into the running turn when claude still works on it")
check(view.contains("runner.awaitedBackgroundTasks"), "the transcript draws the line naming the task")
check(view.contains("let tasks = runner.awaitedBackgroundTasks")
      && view.contains("BackgroundTaskLine.text(tasks, terminals: terminals)")
      && view.contains("BackgroundTaskLine.text([task], terminals: terminals)")
      && view.contains("let terminals = runner.agentKey == \"codex\""),
      "the line is the shared one, in codex's own word for codex — one per task where each can be stopped")
check(runner.contains("codexCommands.read(line: line)")
      && runner.contains("CodexBackgroundNotice.stopped(command:"),
      "an exec turn's stdout feeds the codex rule, and its end draws the notice")
check(runner.contains("watchKimiTasks(from: kimiRecordStart, token: token)")
      && runner.contains("finishKimiTaskWatch(token: token)")
      && runner.contains("placeKimiTaskNotice(notice.text, writtenAt: notice.time)"),
      "a headless kimi turn reads its record for its tasks while it runs, and once more at its end")
let kimiDriver = read("SipAI/Models/KimiAcpTurn.swift")
check(kimiDriver.contains("host.setAwaitedBackgroundTasks(follow.awaitedTasks)"),
      "a kimi ACP turn names the tasks it waits on")
let codexDriver = read("SipAI/Models/CodexAppServerTurn.swift")
check(codexDriver.contains("heldTurn = turn") && codexDriver.contains("turnCompleted(held, host: host)")
      && codexDriver.contains("\"thread/backgroundTerminals/list\""),
      "a codex app-server turn that ends with a command running is held until the command ends")
let composer = read("SipAI/Views/Chat/AgentComposer.swift")
check(!composer.isEmpty && !composer.contains("DISABLE_BACKGROUND_TASKS"),
      "the composer offers no switch for it")

// ── 5. the installed claude ──────────────────────────────────────────
print("5. the installed claude")

func claudeBinary() -> String? {
    let home = NSHomeDirectory()
    let fm = FileManager.default
    for c in [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    where fm.isExecutableFile(atPath: c) {
        return (try? fm.destinationOfSymbolicLink(atPath: c)).map {
            $0.hasPrefix("/") ? $0 : (c as NSString).deletingLastPathComponent + "/" + $0
        } ?? c
    }
    return nil
}
func output(_ path: String, _ arguments: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}
let claude = claudeBinary()
var installed: String? = nil
if let claude {
    installed = output(claude, ["--version"]).split(separator: " ").first.map(String.init)
    print("     (\(claude), \(installed ?? "version unread"))")
    func binaryContains(_ needle: String) -> Bool {
        let n = output("/bin/sh", ["-c", "LC_ALL=C /usr/bin/grep -a -c -- '\(needle)' '\(claude)' || true"])
        return (Int(n.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }
    check(binaryContains(ClaudePrintMode.disableBackgroundTasksEnvVar),
          "\(ClaudePrintMode.disableBackgroundTasksEnvVar) is still read by claude",
          "an older or unread claude would start background tasks it then kills, silently")
    check(binaryContains("run_in_background"), "claude still has background tasks")
    check(binaryContains(ClaudePrintMode.shellWaitSetting),
          "the setting the wait sits behind is still named \(ClaudePrintMode.shellWaitSetting)",
          "renamed — a cached 'off' would no longer be read; look up the new name")
} else {
    skip("the installed claude", "claude not installed")
}

// ── 6. the installed claude against the stand-in endpoint ────────────
print("6. what the installed claude does (stand-in endpoint, token-free)")

final class Stream: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var lines: [(at: TimeInterval, text: String)] = []
    let start = Date()
    func take(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let chunk = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
                lines.append((Date().timeIntervalSince(start), text))
            }
        }
    }
    func snapshot() -> [(at: TimeInterval, text: String)] { lock.lock(); defer { lock.unlock() }; return lines }
}
func isResult(_ text: String) -> Bool { text.contains("\"type\":\"result\"") }

struct Run { let lines: [(at: TimeInterval, text: String)]; let seconds: TimeInterval; let dir: URL; let done: URL }
/// The installed claude starting `sleep N; date > <file>` in the background.
/// With `foreground`, the model's next step is a foreground `sleep` of that
/// many seconds, so the task ends while claude still works on the turn.
func runClaude(_ claude: String, sleep: Int, stopAfterResult: Bool, foreground: Int? = nil) -> Run? {
    guard FileManager.default.fileExists(atPath: fakeServer) else { return nil }
    let dir = scratch("live")
    let cfg = dir.appendingPathComponent("cfg"), cwd = dir.appendingPathComponent("cwd")
    let rec = dir.appendingPathComponent("rec")
    for u in [cfg, cwd, rec] { try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
    let done = cwd.appendingPathComponent("task-done.txt")
    let tool: [String: Any] = ["name": "Bash", "input": [
        "command": "sleep \(sleep); date > '\(done.path)'", "description": "Sleep then write a file",
        "run_in_background": true]]
    let toolFile = dir.appendingPathComponent("tool.json")
    let script: Any
    if let foreground {
        let wait: [String: Any] = ["name": "Bash", "input": ["command": "sleep \(foreground)",
                                                             "description": "Wait in the foreground"]]
        script = [tool, wait]
    } else {
        script = tool
    }
    try? JSONSerialization.data(withJSONObject: script).write(to: toolFile)
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-I", fakeServer, rec.path, "--anthropic-script", toolFile.path]
    let serverOut = Pipe(); server.standardOutput = serverOut; server.standardError = FileHandle.nullDevice
    guard (try? server.run()) != nil else { return nil }
    defer { server.terminate() }
    var port = ""
    let handle = serverOut.fileHandleForReading
    var pending = Data()
    while port.isEmpty {
        let chunk = handle.availableData
        if chunk.isEmpty { return nil }
        pending.append(chunk)
        if let text = String(data: pending, encoding: .utf8),
           let range = text.range(of: #"PORT=(\d+)"#, options: .regularExpression) {
            port = String(text[range].dropFirst(5))
        }
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: claude)
    // SipAI's own argv for a claude turn, with stdin at EOF as SipAI hands it.
    p.arguments = ["-p", "Start the job in the background.", "--output-format", "stream-json",
                   "--verbose", "--permission-mode", "bypassPermissions"]
    p.currentDirectoryURL = cwd
    var e = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC") }
    e["CLAUDE_CONFIG_DIR"] = cfg.path
    e["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:\(port)"
    e["ANTHROPIC_API_KEY"] = "sk-ant-harness-junk"
    p.environment = e
    p.standardInput = FileHandle.nullDevice
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    let stream = Stream()
    out.fileHandleForReading.readabilityHandler = { stream.take($0.availableData) }
    guard (try? p.run()) != nil else { return nil }
    let deadline = Date().addingTimeInterval(TimeInterval(sleep) + 60)
    var stopped = false
    while p.isRunning, Date() < deadline {
        if stopAfterResult, !stopped, stream.snapshot().contains(where: { isResult($0.text) }) {
            Thread.sleep(forTimeInterval: 1)
            p.terminate()          // what SipAI's Stop does: SIGTERM to claude's process group
            stopped = true
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    if p.isRunning { p.interrupt(); Thread.sleep(forTimeInterval: 2) }
    let seconds = Date().timeIntervalSince(stream.start)
    Thread.sleep(forTimeInterval: 0.3)
    out.fileHandleForReading.readabilityHandler = nil
    stream.take(out.fileHandleForReading.readDataToEndOfFile())
    return Run(lines: stream.snapshot(), seconds: seconds, dir: dir, done: done)
}

/// The runner's live buffer over a run's real stdout — the message the
/// runner draws at the send, then each line's events — with every task
/// notice drawn where and as the runner draws it. For each notice: whether
/// it went into the turn claude was working on, and whether the waiting
/// row ("Sipping…") stood under it — as drawn now, and drawn as a notice
/// that opens a turn whatever claude was doing (the control).
func noticesAsDrawn(_ run: Run) -> [(intoTurn: Bool, waits: Bool, waitsAsOpener: Bool)] {
    var rule = ClaudeBackgroundTasks()
    var buffer = [StreamEvent(kind: .userMessage(text: "Start the job in the background."))]
    var notices: [(intoTurn: Bool, waits: Bool, waitsAsOpener: Bool)] = []
    for (_, text) in run.lines {
        let notice = rule.read(line: text)
        let intoTurn = ClaudeBackgroundTasks.noticeGoesIntoRunningTurn(after: buffer)
        for event in AgentEventParser.parse(line: text, fallbackCwd: run.dir) {
            switch event.kind {
            case .toolResult, .systemInit: rule.noteRequestStarted()
            default: break
            }
            buffer.append(event)
        }
        if let notice {
            let asDrawn = StreamEvent(kind: .userMessage(text: notice), isSystemNotice: true,
                                      sentIntoTurn: intoTurn)
            let asOpener = StreamEvent(kind: .userMessage(text: notice), isSystemNotice: true)
            notices.append((intoTurn: intoTurn,
                            waits: WaitingRow.awaitsAgent(buffer + [asDrawn], compactionIsOutput: false),
                            waitsAsOpener: WaitingRow.awaitsAgent(buffer + [asOpener], compactionIsOutput: false)))
            buffer.append(asDrawn)
        }
    }
    return notices
}

if let claude, !fakeServer.isEmpty,
   ClaudePrintMode.allowsBackgroundTasks(installedClaude: installed, cachedShellWait: nil) {
    if let run = runClaude(claude, sleep: 10, stopAfterResult: false) {
        let results = run.lines.filter { isResult($0.text) }
        let firstResult = results.first?.at ?? 0
        check(results.count >= 2 && FileManager.default.fileExists(atPath: run.done.path)
              && run.seconds >= 10,
              "the task outlives the answer by more than five seconds, finishes, and is reported in a turn of its own",
              "\(results.count) result(s), task file \(FileManager.default.fileExists(atPath: run.done.path)), "
              + "\(Int(run.seconds)) s, first result at \(Int(firstResult)) s — claude kills it again: "
              + "keep background tasks off for this version")
        // The real stdout through the real rule.
        var rule = ClaudeBackgroundTasks()
        var verdicts: [Bool] = []
        var liveNotices: [String] = []
        for (_, text) in run.lines {
            if let notice = rule.read(line: text) { liveNotices.append(notice) }
            for event in AgentEventParser.parse(line: text, fallbackCwd: run.dir) {
                switch event.kind {
                case .toolResult, .systemInit: rule.noteRequestStarted()
                case .result: verdicts.append(rule.resultEndsTurn)
                default: break
                }
            }
        }
        check(verdicts.count >= 2 && verdicts.first == false && verdicts.last == true,
              "the rule holds the answer and ends the turn at the report", "verdicts \(verdicts)")
        // The same notice on reopen as live.
        let saved = (try? FileManager.default.subpathsOfDirectory(atPath: run.dir.appendingPathComponent("cfg/projects").path))?
            .first { $0.hasSuffix(".jsonl") }
            .map { run.dir.appendingPathComponent("cfg/projects").appendingPathComponent($0) }
        let reopened = saved.map { AgentSessionScanner.readHistory(of: $0) }?.compactMap { item -> String? in
            guard item.isSystemNotice, case .userText(let text) = item.kind else { return nil }
            return text
        } ?? []
        check(liveNotices.count == 1 && reopened == liveNotices,
              "one notice, in the same words live and on reopen", "live \(liveNotices), reopened \(reopened)")
        let drawnLive = noticesAsDrawn(run)
        check(drawnLive.count == 1 && drawnLive.first?.intoTurn == false && drawnLive.first?.waits == true,
              "a task that ends after the answer: its notice opens the report, and \"Sipping…\" stands under it until the report",
              "\(drawnLive)")
        try? FileManager.default.removeItem(at: run.dir)
    } else {
        skip("the held turn", "the stand-in endpoint or claude did not start")
    }
    // A task that ends while claude still works on the turn (a foreground
    // command running): claude hands the model its notification with the
    // next request, in the same turn, and the notice opens nothing.
    if let run = runClaude(claude, sleep: 1, stopAfterResult: false, foreground: 5) {
        let results = run.lines.filter { isResult($0.text) }
        let saved = (try? FileManager.default.subpathsOfDirectory(atPath: run.dir.appendingPathComponent("cfg/projects").path))?
            .first { $0.hasSuffix(".jsonl") }
            .map { run.dir.appendingPathComponent("cfg/projects").appendingPathComponent($0) }
        let record = saved.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let carried = record.split(separator: "\n").contains {
            $0.contains("\"queued_command\"") && $0.contains("\"commandMode\":\"task-notification\"")
        }
        check(results.count == 1 && FileManager.default.fileExists(atPath: run.done.path) && carried,
              "a task that ends while claude still works: one turn, one result, its notification carried by claude's next request",
              "\(results.count) result(s), task file \(FileManager.default.fileExists(atPath: run.done.path)), carried \(carried)")
        let drawnLive = noticesAsDrawn(run)
        check(drawnLive.count == 1 && drawnLive.first?.intoTurn == true && drawnLive.first?.waits == false,
              "…its notice goes into the turn, and no \"Sipping…\" comes back under it", "\(drawnLive)")
        check(drawnLive.first?.waitsAsOpener == true,
              "…where a notice drawn as opening a turn put \"Sipping…\" under it (the control)", "\(drawnLive)")
        try? FileManager.default.removeItem(at: run.dir)
    } else {
        skip("a task that ends mid-turn", "the stand-in endpoint or claude did not start")
    }
    if let run = runClaude(claude, sleep: 8, stopAfterResult: true) {
        Thread.sleep(forTimeInterval: 9)
        let survivor = output("/usr/bin/pgrep", ["-f", run.done.path])
        check(!FileManager.default.fileExists(atPath: run.done.path)
              && survivor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              "Stop during the wait stops the task too, and leaves nothing running",
              "task file \(FileManager.default.fileExists(atPath: run.done.path)), survivors \(survivor)")
        try? FileManager.default.removeItem(at: run.dir)
    } else {
        skip("Stop during the wait", "the stand-in endpoint or claude did not start")
    }
} else {
    skip("the installed claude against the stand-in", claude == nil ? "claude not installed"
         : fakeServer.isEmpty ? "no stand-in endpoint given"
         : "claude \(installed ?? "(version unread)") is below \(floor): background tasks stay off")
}

// ── 6b. the installed kimi and codex against the stand-in ────────────
print("6b. what the installed kimi and codex do (stand-in endpoint, token-free)")

/// The ChatOnlyMode stand-in, answering `flag`'s scripted route; its port.
func startStandIn(_ flag: String, script: [[String: Any]], in dir: URL) -> (Process, String)? {
    guard FileManager.default.fileExists(atPath: fakeServer) else { return nil }
    let rec = dir.appendingPathComponent("rec"), scriptFile = dir.appendingPathComponent("script.json")
    try? FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
    guard let data = try? JSONSerialization.data(withJSONObject: script),
          (try? data.write(to: scriptFile)) != nil else { return nil }
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-I", fakeServer, rec.path, flag, scriptFile.path]
    let out = Pipe(); server.standardOutput = out; server.standardError = FileHandle.nullDevice
    guard (try? server.run()) != nil else { return nil }
    var pending = Data()
    while true {
        let chunk = out.fileHandleForReading.availableData
        if chunk.isEmpty { server.terminate(); return nil }
        pending.append(chunk)
        if let text = String(data: pending, encoding: .utf8),
           let range = text.range(of: #"PORT=(\d+)"#, options: .regularExpression) {
            return (server, String(text[range].dropFirst(5)))
        }
    }
}
/// Run `binary` to its end (bounded), stdin at EOF as SipAI hands it; its stdout lines.
func runToEnd(_ binary: String, _ arguments: [String], cwd: URL, env: [String: String],
              limit: TimeInterval) -> [(at: TimeInterval, text: String)] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    p.arguments = arguments
    p.currentDirectoryURL = cwd
    p.environment = env
    p.standardInput = FileHandle.nullDevice
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    let stream = Stream()
    out.fileHandleForReading.readabilityHandler = { stream.take($0.availableData) }
    guard (try? p.run()) != nil else { return [] }
    let deadline = Date().addingTimeInterval(limit)
    while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    if p.isRunning { p.terminate(); Thread.sleep(forTimeInterval: 1) }
    Thread.sleep(forTimeInterval: 0.3)
    out.fileHandleForReading.readabilityHandler = nil
    stream.take(out.fileHandleForReading.readDataToEndOfFile())
    return stream.snapshot()
}
func systemNotices(_ items: [AgentSessionHistoryItem]) -> [String] {
    items.compactMap { item in
        guard item.isSystemNotice, case .userText(let text) = item.kind else { return nil }
        return text
    }
}
func files(named name: String, under root: URL) -> [URL] {
    (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.lastPathComponent == name || $0.lastPathComponent.hasPrefix(name) }
}
let cleanEnv = ProcessInfo.processInfo.environment.filter {
    !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("KIMI") && !$0.key.hasPrefix("CODEX")
}

// Kimi, Never Ask (`kimi --prompt`): the task outlives the answer, kimi
// reports it in a turn of its own, and only its record says so.
let kimiBinary = (("~/.kimi-code/bin/kimi" as NSString).expandingTildeInPath as NSString).resolvingSymlinksInPath
if FileManager.default.isExecutableFile(atPath: kimiBinary), !fakeServer.isEmpty {
    let dir = scratch("kimi-live")
    let home = dir.appendingPathComponent("home"), cwd = dir.appendingPathComponent("cwd")
    for u in [home, cwd] { try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
    let marker = cwd.appendingPathComponent("task-done.txt")
    let script: [[String: Any]] = [
        ["marker": "BGPROBE", "steps": [
            ["tool_calls": [["id": "c1", "name": "Bash", "arguments": [
                "command": "sleep 3; date > '\(marker.path)'", "run_in_background": true,
                "description": "Sleep then write a file"]]]],
            ["text": "STARTED"]]],
        ["marker": "task.", "steps": [["text": "REPORTED"]]],
    ]
    if let (server, port) = startStandIn("--chat-script", script: script, in: dir) {
        try? """
        default_model = "fake/fake-model"

        [providers.fake]
        base_url = "http://127.0.0.1:\(port)/v1"
        type = "openai"
        api_key = "junk"

        [models."fake/fake-model"]
        provider = "fake"
        model = "fake-model"
        max_context_size = 262144
        capabilities = [ "tool_use", "image_in" ]

        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        var env = cleanEnv; env["KIMI_CODE_HOME"] = home.path
        let out = runToEnd(kimiBinary, ["--prompt", "BGPROBE start it", "--output-format", "stream-json"],
                           cwd: cwd, env: env, limit: 60)
        server.terminate()
        let wire = files(named: "wire.jsonl", under: home.appendingPathComponent("sessions"))
            .first { $0.deletingLastPathComponent().lastPathComponent == "main" }
        var tracker = KimiSessionScanner.BackgroundTasks()
        var namedWhileWaiting = false
        var liveNotices: [String] = []
        let records = (wire.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
            .split(separator: "\n").map(String.init)
        for record in records {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(record.utf8))) as? [String: Any]
            else { continue }
            if let notice = tracker.feed(record: object, now: Date()) { liveNotices.append(notice.text) }
            if tracker.awaited.map(\.description) == ["Sleep then write a file"] { namedWhileWaiting = true }
        }
        let reported = out.contains { $0.text.contains("REPORTED") }
        check(FileManager.default.fileExists(atPath: marker.path) && reported,
              "kimi: the task outlives the answer, finishes, and is reported in a turn of its own",
              "task file \(FileManager.default.fileExists(atPath: marker.path)), reported \(reported)")
        check(namedWhileWaiting && liveNotices == ["Background process completed · Sleep then write a file completed."],
              "kimi's record, read as a headless turn reads it: the task named while kimi waits, then kimi's short notice",
              "named \(namedWhileWaiting), notices \(liveNotices)")
        check(!out.contains { $0.text.contains("<notification") },
              "kimi's stdout carries no notification — the record is the only source of the live notice")
        let reopened = wire.map { systemNotices(KimiSessionScanner.readHistory(of: $0)) } ?? []
        check(!liveNotices.isEmpty && reopened == liveNotices, "kimi: reopened, the same notice",
              "live \(liveNotices), reopened \(reopened)")
    } else {
        skip("the installed kimi against the stand-in", "the stand-in endpoint did not start")
    }
    try? FileManager.default.removeItem(at: dir)
} else {
    skip("the installed kimi against the stand-in", "kimi is not installed at ~/.kimi-code/bin/kimi")
}

// Codex, a mode `codex exec` runs: the command is stopped when the turn
// ends, nothing on stdout says so, and the reopened rollout says the same
// notice the live turn drew.
let codexBinary = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
    .map { "\($0)/codex" }.first { FileManager.default.isExecutableFile(atPath: $0) }
if let codexBinary, !fakeServer.isEmpty {
    let dir = scratch("codex-live")
    let home = dir.appendingPathComponent("home"), cwd = dir.appendingPathComponent("cwd")
    for u in [home, cwd] { try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
    let marker = cwd.appendingPathComponent("task-done.txt")
    let command = "sleep 8; date > '\(marker.path)'"
    let script: [[String: Any]] = [["marker": "BGPROBE", "steps": [
        ["function_call": ["name": "exec_command", "arguments": ["cmd": command, "yield_time_ms": 1000]]],
        ["text": "STARTED"]]]]
    if let (server, port) = startStandIn("--responses-script", script: script, in: dir) {
        try? """
        model_provider = "fake"
        model = "gpt-5.5"

        [model_providers.fake]
        name = "fake"
        base_url = "http://127.0.0.1:\(port)"
        wire_api = "responses"

        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        var env = cleanEnv; env["CODEX_HOME"] = home.path
        let out = runToEnd(codexBinary, ["exec", "--json", "--skip-git-repo-check",
                                         "-c", "sandbox_mode=\"workspace-write\"", "-c", "approval_policy=\"never\"",
                                         "BGPROBE start it"], cwd: cwd, env: env, limit: 60)
        server.terminate()
        var tracker = CodexBackgroundCommands()
        var atTurnEnd: [String]? = nil
        for (_, text) in out {
            tracker.read(line: text)
            if text.contains("\"turn.completed\""), atTurnEnd == nil { atTurnEnd = tracker.running.map(\.description) }
        }
        Thread.sleep(forTimeInterval: 9)
        check(atTurnEnd == [command] && !FileManager.default.fileExists(atPath: marker.path),
              "codex exec: the command left running at the answer is still running when the turn completes, and is stopped with it",
              "running at the turn's end \(String(describing: atTurnEnd)), task file \(FileManager.default.fileExists(atPath: marker.path))")
        let live = (atTurnEnd ?? []).map { CodexBackgroundNotice.stopped(command: $0) }
        let rolloutFile = files(named: "rollout-", under: home.appendingPathComponent("sessions")).first
        var decoder = CodexSessionScanner.RolloutDecoder()
        let reopened = systemNotices(((rolloutFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? "")
            .split(separator: "\n").flatMap { decoder.items(forLine: String($0)) })
        check(!live.isEmpty && reopened == live,
              "codex: reopened, the rollout reads as the same notice — its words for a command still running are still codex's",
              "live \(live), reopened \(reopened)")
    } else {
        skip("the installed codex against the stand-in", "the stand-in endpoint did not start")
    }
    try? FileManager.default.removeItem(at: dir)
} else {
    skip("the installed codex against the stand-in", "codex is not on PATH")
}

// ── 7. a real turn (opt-in; spends tokens) ───────────────────────────
print("7. a real turn")
if ProcessInfo.processInfo.environment["SIPAI_BG_LIVE"] == "1", let claude,
   ClaudePrintMode.allowsBackgroundTasks(installedClaude: installed, cachedShellWait: nil) {
    let dir = scratch("real")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: claude)
    p.arguments = ["-p",
        "Use the Bash tool with run_in_background=true to run: sleep 8; touch bg.txt . "
        + "Then answer in one sentence. When it finishes, say in one sentence that it did.",
        "--output-format", "stream-json", "--verbose", "--permission-mode", "bypassPermissions"]
    p.currentDirectoryURL = dir
    p.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE_CODE_DISABLE") }
    p.standardInput = FileHandle.nullDevice
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    let results = text.split(separator: "\n").filter { isResult(String($0)) }.count
    check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bg.txt").path) && results >= 2,
          "a real model's background task finished and was reported in a turn of its own",
          "\(results) result(s)")
    try? FileManager.default.removeItem(at: dir)
} else {
    skip("a real turn", "set SIPAI_BG_LIVE=1 to spend one (Claude Code \(floor) or newer)")
}

print("")
if failures == 0 { print("All background-task checks passed.") }
else { print("\(failures) check(s) FAILED."); exit(1) }
