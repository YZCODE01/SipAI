// What the user does while an agent's turn runs.
//
// A message sent while a turn of SipAI's runs waits above the message box
// (`HeldMessage`): Steer hands it to the running turn — claude through its
// open stream-json input, codex through `turn/steer` — and it is drawn in
// the transcript where the agent's own record puts it, the moment the
// agent takes it; left alone it is sent when the turn ends; × puts it back
// in the box, its words and files, to be changed.
// One piece of the turn's background work stops on its own: claude's
// `stop_task`, codex's background terminals. Codex's own `/compact` and
// `/review` run as codex's terminal runs them.
//
// 1. The rules: what may go into a turn, claude's input lines and the
//    reading of its echo, codex's commands and their words, the task rule
//    for a task the user stopped, and the waiting row ("Sipping…"), which
//    words sent into a running turn do not bring back.
// 2. The readers: claude's record of a message taken mid-turn and of one
//    it ran as a turn of its own, on reopen and through the tailer.
// 3. The review picker's lists, read with git over a throwaway repository.
// 4. The wiring: the composer, the session page, the runner.
// 5. The installed claude against the stand-in endpoint (token-free): a
//    message written while a tool runs, one written while the answer is
//    on its way, and one task stopped.

import Foundation

var passed = 0, failed = 0, skipped = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("  ok   \(name)") } else {
        failed += 1; print("  FAIL \(name)")
        let d = detail(); if !d.isEmpty { print("       \(d)") }
    }
}
func skip(_ name: String, _ why: String) { skipped += 1; print("  skip \(name) — \(why)") }

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let fakeServer = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
func read(_ rel: String) -> String {
    (try? String(contentsOfFile: root + "/" + rel, encoding: .utf8)) ?? ""
}
/// The body of the declaration that opens with `signature`, braces matched.
func body(_ text: String, _ signature: String) -> String {
    guard let start = text.range(of: signature),
          let open = text[start.upperBound...].firstIndex(of: "{") else { return "" }
    var depth = 0
    var i = open
    while i < text.endIndex {
        if text[i] == "{" { depth += 1 }
        if text[i] == "}" { depth -= 1; if depth == 0 { return String(text[start.lowerBound...i]) } }
        i = text.index(after: i)
    }
    return ""
}
func line(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}
func scratch(_ name: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("midturn-\(name)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// ── 1. the rules ─────────────────────────────────────────────────────
print("1. the rules")

func held(_ text: String, triggers: [SkillTrigger] = [], command: CodexCommandTurn? = nil) -> HeldMessage {
    var options = AgentLaunchOptions()
    options.skillTriggers = triggers
    return HeldMessage(text: text, display: text, attachedFiles: [], images: [], options: options,
                       codexCommand: command)
}
check(held("and also check the tests").canGoIntoTurn, "a message of words may go into the running turn")
check(!held("/mcp").canGoIntoTurn && !held("/compact").canGoIntoTurn,
      "a command waits for the turn's end: the agent reads a command only as a message of its own")
check(held("/Users/me/notes.md look at this").canGoIntoTurn, "a pasted path is words, not a command")
check(!held("use the skill", triggers: [SkillTrigger(name: "review")]).canGoIntoTurn,
      "a message that loads a skill waits: a skill loads only with a message of its own")
check(!held("Review uncommitted changes", command: .review(.uncommittedChanges)).canGoIntoTurn
      && !held("/compact", command: .compact).canGoIntoTurn,
      "codex's own commands wait: each is a turn of codex's own")

// × puts a held message back in the message box to be changed — what the
// box held when it was sent, its words ahead of anything typed since, a
// line between (Claude Code's and Codex's own terminals, a queued message
// taken back to edit) — and its files back beside the box.
let notes = URL(fileURLWithPath: "/tmp/example/notes.md")
let typedBack = HeldMessage(text: "Check the tests\n<sipai-attachment …>", display: "Check the tests",
                            attachedFiles: ["notes.md"], images: [], options: AgentLaunchOptions(),
                            boxText: "Check the tests", boxFiles: [notes])
check(typedBack.boxText(over: "") == "Check the tests" && typedBack.boxFiles == [notes],
      "× on a held message gives back what the box held when it was sent: its words and its files")
check(typedBack.boxText(over: "and the docs") == "Check the tests\nand the docs"
      && typedBack.boxText(over: "  \n") == "Check the tests",
      "…its words ahead of what is typed in the box now, a line between; a box of blank space is an empty box")
let filesOnly = HeldMessage(text: "<sipai-attachment …>", display: "", attachedFiles: ["notes.md"], images: [],
                            options: AgentLaunchOptions(), boxText: "", boxFiles: [notes])
check(filesOnly.boxText(over: "half a thought") == "half a thought" && filesOnly.boxFiles == [notes],
      "…a message of files alone leaves the typed words as they are, and gives its files back")
check(held("/compact", command: .compact).boxText(over: "") == "/compact",
      "…a held command comes back as it was typed")

check(!ClaudeSteer.takesInput(installedClaude: "2.1.309", replayListed: true)
      && ClaudeSteer.takesInput(installedClaude: ClaudeSteer.floor, replayListed: true)
      && ClaudeSteer.takesInput(installedClaude: "2.2.0", replayListed: true),
      "claude takes a message mid-turn from \(ClaudeSteer.floor) on")
check(!ClaudeSteer.takesInput(installedClaude: "2.2.0", replayListed: false)
      && !ClaudeSteer.takesInput(installedClaude: nil, replayListed: true),
      "…only where its --help lists \(ClaudeSteer.replayFlag), and never for a version not read yet")

let userLine = ClaudeSteer.userLine(text: "also say BANANA")
let userObject = (try? JSONSerialization.jsonObject(with: Data(userLine.utf8))) as? [String: Any]
check(userLine.hasSuffix("\n") && userLine.dropLast().contains("\n") == false
      && userObject?["type"] as? String == "user"
      && (userObject?["message"] as? [String: Any])?["role"] as? String == "user"
      && (userObject?["message"] as? [String: Any])?["content"] as? String == "also say BANANA",
      "a message goes to claude as one stream-json user line", userLine)
let stopLine = ClaudeSteer.stopTaskLine(taskId: "b123", requestId: "r1")
let stopObject = (try? JSONSerialization.jsonObject(with: Data(stopLine.utf8))) as? [String: Any]
check(stopObject?["type"] as? String == "control_request" && stopObject?["request_id"] as? String == "r1"
      && (stopObject?["request"] as? [String: Any])?["subtype"] as? String == "stop_task"
      && (stopObject?["request"] as? [String: Any])?["task_id"] as? String == "b123"
      && stopLine.hasSuffix("\n"),
      "one task stops through claude's own control request", stopLine)

// The echo, in the shapes claude prints (measured, 2.1.312).
func echo(_ text: String) -> String {
    line(["type": "user", "message": ["role": "user", "content": text],
          "parent_tool_use_id": NSNull(), "session_id": "s", "uuid": UUID().uuidString])
}
let toolResultEcho = line(["type": "user", "message": ["role": "user", "content": [
    ["type": "tool_result", "tool_use_id": "t1", "content": "also say BANANA"]]], "session_id": "s"])
let result = line(["type": "result", "subtype": "success", "is_error": false, "result": "OK", "session_id": "s"])
var tracker = ClaudeSteerTracker(prompt: "also say BANANA")
tracker.wrote("also say BANANA")
let promptTaken = tracker.read(line: echo("also say BANANA"))
check(promptTaken == nil && tracker.pending,
      "the prompt's own echo is the prompt's, though a message written later has the same words")
check(tracker.read(line: toolResultEcho) == nil && tracker.pending,
      "a tool's result is never a message taken")
let midTurn = tracker.read(line: echo("  also say BANANA \n"))
check(midTurn == ClaudeSteerTracker.Taken(words: "also say BANANA", opensTurn: false) && !tracker.pending,
      "taken while claude works: into the turn", String(describing: midTurn))
var after = ClaudeSteerTracker(prompt: "first")
after.wrote("second")
_ = after.read(line: echo("first"))
_ = after.read(line: result)
_ = after.read(line: line(["type": "system", "subtype": "init", "session_id": "s"]))
let ownTurn = after.read(line: echo("second"))
check(ownTurn == ClaudeSteerTracker.Taken(words: "second", opensTurn: true),
      "taken after claude answered — its init comes first — a turn of its own", String(describing: ownTurn))
var unknown = ClaudeSteerTracker(prompt: "first")
unknown.wrote("written")
check(unknown.read(line: echo("something else")) == nil && unknown.dropUnread() == ["written"]
      && !unknown.pending,
      "an echo of words never written is nobody's; a turn that ends gives up what it never took")
var resultInText = ClaudeSteerTracker(prompt: "p")
resultInText.wrote("a message quoting {\"type\":\"result\"}")
_ = resultInText.read(line: echo("p"))
let quoted = resultInText.read(line: echo("a message quoting {\"type\":\"result\"}"))
check(quoted?.opensTurn == false, "a message whose words hold a result's spelling is no result",
      String(describing: quoted))

check(CodexCommand.parse("/compact") == .compact && CodexCommand.parse("  /Review \n") == .review
      && CodexCommand.parse("/compact now") == nil && CodexCommand.parse("/model") == nil
      && CodexCommand.parse("compact") == nil,
      "codex's /compact and /review are the box's whole text, as its terminal reads them")
func wire(_ target: CodexReviewTarget) -> String { line(target.wire) }
check(wire(.uncommittedChanges) == #"{"type":"uncommittedChanges"}"#
      && wire(.baseBranch("main")) == #"{"branch":"main","type":"baseBranch"}"#
      && wire(.commit(sha: "abc1234", title: nil)) == #"{"sha":"abc1234","title":null,"type":"commit"}"#
      && wire(.commit(sha: "abc1234", title: "Fix it")) == #"{"sha":"abc1234","title":"Fix it","type":"commit"}"#
      && wire(.custom("Look at errors")) == #"{"instructions":"Look at errors","type":"custom"}"#,
      "a review's target in codex's own shape")
check(CodexReviewWords.label(baseBranch: "main").contains("main")
      && CodexReviewWords.label(commit: "abc1234", subject: "Fix it").contains("abc1234")
      && CodexReviewWords.label(commit: "abc1234", subject: "Fix it").contains("Fix it")
      && !CodexReviewWords.label(commit: "abc1234", subject: "").hasSuffix(": ")
      && CodexReviewWords.label(customInstructions: "Look at errors").contains("Look at errors"),
      "a review waiting above the box names what it reviews")

// A task the user stopped: claude reports it stopped, and saves nothing.
func system(_ subtype: String, _ fields: [String: Any]) -> String {
    var o = fields; o["type"] = "system"; o["subtype"] = subtype; o["session_id"] = "s"
    return line(o)
}
let job: [String: Any] = ["task_id": "bjob1", "run_id": "r1", "task_type": "local_bash",
                          "description": "Sleep then write a file"]
var tasks = ClaudeBackgroundTasks()
_ = tasks.read(line: system("background_tasks_changed", ["tasks": [job]]))
_ = tasks.read(line: system("task_started", ["task_id": "bjob1", "is_backgrounded": true,
                                             "task_type": "local_bash", "description": "Sleep then write a file"]))
tasks.noteRequestStarted()
check(!tasks.resultEndsTurn, "a task running at the answer holds the turn")
tasks.noteStoppedByUser(id: "bjob1")
let stoppedNotice = tasks.read(line: system("task_notification", ["task_id": "bjob1", "status": "stopped",
                                                                  "summary": "Sleep then write a file"]))
_ = tasks.read(line: system("background_tasks_changed", ["tasks": []]))
check(stoppedNotice == nil && tasks.resultEndsTurn,
      "stopped by the user: no notice (claude saves none, so a reopen draws none), and nothing more is owed",
      String(describing: stoppedNotice))
var untouched = ClaudeBackgroundTasks()
_ = untouched.read(line: system("background_tasks_changed", ["tasks": [job]]))
check(untouched.read(line: system("task_notification", ["task_id": "bjob1", "status": "stopped",
                                                        "summary": "Sleep then write a file"])) != nil,
      "…a task claude stopped by itself is still said")

check(CodexReviewGit.orderedBranches("feature\nmain\nfix\n", originHead: nil) == ["main", "feature", "fix"]
      && CodexReviewGit.orderedBranches("feature\ntrunk\n", originHead: "origin/trunk\n") == ["trunk", "feature"]
      && CodexReviewGit.orderedBranches("b\na\n", originHead: nil) == ["b", "a"]
      && CodexReviewGit.orderedBranches("", originHead: nil).isEmpty,
      "branches: the repository's default first, the rest as git listed them")
let sha = String(repeating: "a", count: 40)
let commits = CodexReviewGit.parseCommits("\(sha)\u{1F}Fix: the thing\nwarning: not a commit\n\(String(repeating: "b", count: 40))\u{1F}\n")
check(commits == [CodexReviewGit.Commit(sha: sha, subject: "Fix: the thing"),
                  CodexReviewGit.Commit(sha: String(repeating: "b", count: 40), subject: "")]
      && commits.first?.shortSha == "aaaaaaa",
      "commits: the sha and the subject, a line that is no commit left out", "\(commits)")

// Words sent into a running turn — a message steered in, an answer to a
// question codex asked without stopping — open no turn: the waiting row
// ("Sipping…") stays down under them, as it does under the agent's own
// steps. Taken for the turn's message, "Sipping…" came up under the answer
// as though a new message had gone.
let prompt = StreamEvent(kind: .userMessage(text: "FIRST prompt"))
let initEvent = StreamEvent(kind: .systemInit(sessionId: "s", model: "m", cwd: "/tmp"))
let question = StreamEvent(kind: .assistantText(text: "Which database?\n- Postgres\n- SQLite"))
let tool = StreamEvent(kind: .toolUse(toolUseId: "t1", name: "Bash", input: [:]))
func into(_ text: String) -> StreamEvent { StreamEvent(kind: .userMessage(text: text), sentIntoTurn: true) }
func waits(_ events: [StreamEvent]) -> Bool { WaitingRow.awaitsAgent(events, compactionIsOutput: false) }
check(waits([prompt]) && waits([prompt, initEvent]) && !waits([prompt, initEvent, question]),
      "the waiting row is up from the turn's message until the agent's first output")
check(!waits([prompt, question, into("> Which database?\n\nSQLite")]),
      "an answer sent into the running turn brings no waiting row back: the turn goes on")
check(!waits([prompt, tool, into("also check the tests")]),
      "…nor does a message steered in after the agent's first step")
check(waits([prompt, into("also check the tests")]),
      "a message steered in before any output leaves the row up: the turn has still said nothing")
check(!WaitingRow.awaitsAgent([prompt, question, into("> Which database?\n\nSQLite")], compactionIsOutput: true),
      "the stall notice reads the same: a turn that has answered is not silent because of an answer sent into it")
check(waits([prompt, question, StreamEvent(kind: .userMessage(text: "Background command done"), isSystemNotice: true)])
      && waits([prompt, question, StreamEvent(kind: .userMessage(text: "the next message"))]),
      "a notice in the user column, and a message of its own, still put the row up for what answers them")
let compacted = [prompt, StreamEvent(kind: .compaction(preTokens: 9, postTokens: 1))]
check(waits(compacted) && !WaitingRow.awaitsAgent(compacted, compactionIsOutput: true),
      "a compaction row keeps the spinner up but counts as output for the stall notice")

// ── 2. the readers ───────────────────────────────────────────────────
print("2. claude's record of a message taken during a turn")

func transcript(_ records: [[String: Any]]) -> URL {
    let dir = scratch("reader")
    let file = dir.appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl")
    try? (records.map(line).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    return file
}
func rowSignature(_ item: AgentSessionHistoryItem) -> String {
    switch item.kind {
    case .userText(let t): return (item.isSystemNotice ? "notice:" : item.sentIntoTurn ? "into:" : "user:") + t
    case .assistantText(let t): return "assistant:" + t
    case .toolUse(_, let name, _): return "tool:" + name
    case .toolResult: return "output"
    default: return "other"
    }
}
var parent: String? = nil
func record(_ type: String, _ fields: [String: Any]) -> [String: Any] {
    var o = fields
    let id = UUID().uuidString.lowercased()
    o["type"] = type; o["uuid"] = id; o["sessionId"] = "s"; o["cwd"] = "/tmp/x"
    o["timestamp"] = ISO8601DateFormatter().string(from: Date())
    o["parentUuid"] = parent ?? NSNull()
    parent = id
    return o
}
let midTurnRecords: [[String: Any]] = [
    record("user", ["message": ["role": "user", "content": "FIRST prompt"]]),
    record("assistant", ["message": ["id": "m1", "role": "assistant", "model": "x",
        "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "sleep 4"]]]]]),
    record("user", ["message": ["role": "user", "content": [
        ["type": "tool_result", "tool_use_id": "t1", "content": "done"]]], "toolUseResult": ["stdout": "done"]]),
    record("attachment", ["attachment": ["type": "queued_command", "prompt": "STEERED message",
                                         "commandMode": "prompt"]]),
    record("assistant", ["message": ["id": "m2", "role": "assistant", "model": "x",
        "content": [["type": "text", "text": "OK"]]]]),
]
let midRows = AgentSessionScanner.readHistory(of: transcript(midTurnRecords)).map(rowSignature)
check(midRows.firstIndex(of: "into:STEERED message").map { i in
        midRows.firstIndex(of: "tool:Bash").map { $0 < i } == true
            && midRows.lastIndex(of: "assistant:OK").map { i < $0 } == true } == true
      && !midRows.contains("user:STEERED message"),
      "reopened, a message claude took mid-turn sits after the tool and before the answer, into the turn",
      "\(midRows)")
let tailed = midTurnRecords.flatMap {
    AgentEventParser.parse(line: line($0), fallbackCwd: URL(fileURLWithPath: "/tmp"), includeUserMessages: true)
}
let tailedSteer = tailed.first {
    if case .userMessage(let t) = $0.kind { return t == "STEERED message" }
    return false
}
check(tailedSteer?.sentIntoTurn == true && tailedSteer?.isSystemNotice == false,
      "…and the same through the tailer (a turn another process runs)")
let otherAttachment = record("attachment", ["attachment": ["type": "queued_command", "prompt": "/mcp",
                                                             "commandMode": "slash"]])
check(AgentSessionScanner.queuedPrompt(otherAttachment) == nil,
      "a queued command that is no prompt of the user's is not a message")

// ── 3. the review picker's lists ─────────────────────────────────────
print("3. the review picker's lists, read with git")

func git(_ dir: URL, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["git", "-C", dir.path, "-c", "user.name=Harness", "-c", "user.email=harness@example.invalid",
                   "-c", "commit.gpgsign=false"] + args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
}
func await_<T>(_ body: @escaping () async -> T) -> T {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    Task { box.value = await body(); done.signal() }
    done.wait()
    return box.value!
}
final class Box<T>: @unchecked Sendable { var value: T? }
if await_({ await CodexReviewGit.binary() }) != nil {
    let repo = scratch("repo")
    git(repo, ["init", "-q", "-b", "main"])
    try? "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    git(repo, ["add", "."]); git(repo, ["commit", "-q", "-m", "First commit"])
    git(repo, ["checkout", "-q", "-b", "feature"])
    try? "two\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    git(repo, ["commit", "-q", "-am", "Second: on the feature"])
    let branches = await_({ await CodexReviewGit.branches(in: repo) })
    let recent = await_({ await CodexReviewGit.commits(in: repo) })
    check(branches == ["main", "feature"], "the folder's branches, its default first", "\(branches)")
    check(recent.map(\.subject) == ["Second: on the feature", "First commit"]
          && recent.allSatisfy { $0.sha.count == 40 },
          "its commits, newest first, by their subject lines", "\(recent)")
    let plain = scratch("plain")
    check(await_({ await CodexReviewGit.branches(in: plain) }).isEmpty
          && await_({ await CodexReviewGit.commits(in: plain) }).isEmpty,
          "a folder that is no repository lists nothing")
    try? FileManager.default.removeItem(at: repo); try? FileManager.default.removeItem(at: plain)
} else {
    skip("the review picker's lists", "no git this harness can run without asking to install it")
}
let reviewGit = read("SipAI/Models/CodexReviewGit.swift")
check(reviewGit.contains(#"where dir != "/usr/bin""#) && reviewGit.contains(#""/usr/bin/xcode-select""#)
      && !reviewGit.contains(#""/usr/bin/git""#),
      "git is never /usr/bin/git's stand-in, which offers to install the developer tools instead of answering")

// ── 4. the wiring ────────────────────────────────────────────────────
print("4. the wiring")

let composer = read("SipAI/Views/Chat/AgentComposer.swift")
let page = read("SipAI/Views/Chat/AgentSessionView.swift")
let runner = read("SipAI/Models/AgentRunner.swift")
let canSend = body(composer, "private var canSend: Bool")
check(canSend.contains("!externalBusy") && canSend.contains("!(sending && held == nil)"),
      "the box sends while SipAI's own turn runs — the message is held — and never while another process runs one")
let strip = body(composer, "private func trailing(_ message: HeldMessage)")
check(strip.contains("if queue.steerable, message.canGoIntoTurn") && strip.contains("onSteer(message.id)")
      && strip.contains("onSend(message.id)") && strip.contains("onCancel(message.id)")
      && strip.contains(".disabled(externalBusy)"),
      "each held message: Steer while the turn takes one, Send once none runs, × to take it back")
check(composer.contains("HeldMessageStrip(queue: held") && composer.contains("CodexReviewPicker(folder:"),
      "the strip and codex's review picker sit above the box")
check(strip.contains("Put it back in the message box"),
      "the × says it puts the message back in the box", strip)
let takeBack = body(page, "private func takeBackHeld(")
check(page.contains("onCancelHeld: { takeBackHeld($0) }")
      && takeBack.contains("runner.takeBackHeld(id)")
      && takeBack.contains("inputDraft = message.boxText(over: inputDraft)")
      && takeBack.contains("stageAttachments(message.boxFiles)"),
      "× takes the held message back into the box: its words, and its files through the + button's own staging",
      takeBack)
check(body(runner, "func takeBackHeld(").contains("!$0.steered") && !runner.contains("func cancelHeld("),
      "…never one already steered into the turn, which is the agent's now; nothing drops a held message unseen")
let codexHold = body(page, "private func startCodexCommand(")
check(codexHold.contains("codexCommand: command, boxText: typed)") && codexHold.contains("typed = \"/review\""),
      "a held codex command comes back as typed — /review for a review picked after typing it", codexHold)
let handleSend = body(page, "private func handleSend()")
if let hold = handleSend.range(of: "if runner.status.isRunning {"),
   let send = handleSend.range(of: "if runner.send(text: text, options: sending, images: images)") {
    check(hold.upperBound < send.lowerBound
          && handleSend.contains("runner.hold(text: text, options: sending, images: images,\n")
          && handleSend.contains("boxText: typed, boxFiles: attaching.map(\\.url))"),
          "a message sent while the turn runs is held, never sent into a second turn — with what the box held, for ×")
} else {
    check(false, "a message sent while the turn runs is held", "anchors not found")
}
// After Stop, a held message's Send is a message the user sends: like a typed
// one, it retracts a load-time "Interrupted" marker the reopened page derived
// for the stopped turn, or the marker sits between that turn and this one.
check(page.contains("if runner.sendHeldNow(id) { dropInterruptedMarker() }")
      && runner.contains("func sendHeldNow(_ id: UUID) -> Bool"),
      "a held message sent after Stop retracts a load-time Interrupted marker, as a typed message does")
check(handleSend.contains("if let command = typedCodexCommand")
      && body(page, "private var typedCodexCommand: CodexCommand?").contains("stagedAttachments.isEmpty")
      && body(composer, "private var slashCommandHint: String?").contains("attachments.isEmpty"),
      "codex's /compact and /review are read the same way by the send and by the box's hint")
let bgRow = body(page, "private var backgroundTaskRow: some View")
check(bgRow.contains("if runner.canStopBackgroundTasks") && bgRow.contains("runner.stopBackgroundTask(id: task.id)")
      && bgRow.contains("runner.stoppingBackgroundTasks.contains(task.id)"),
      "the background line gives each stoppable task its own Stop")
let finalize = body(runner, "private func finalizeTurn(")
check(finalize.contains("releaseHeldMessage()") && finalize.contains("returnUntakenSteers()")
      && body(runner, "private func releaseHeldMessage()").contains("guard !stopRequested"),
      "a turn that ends sends the next held message — never after Stop — and takes back what was never read")
check(body(runner, "func cancel()").contains("returnUntakenSteers()"),
      "Stop takes back a message steered in and not yet read")
check(runner.contains("if claudeInput != nil, let taken = claudeSteers.read(line: line)")
      && runner.contains("drawSteerTaken(text: taken.words, opensTurn: taken.opensTurn)"),
      "claude's echo of a message is where its row is drawn, as its record keeps it")
check(runner.contains("(claudeInput != nil && claudeSteers.pending)"),
      "an answer with a message still unread is not the turn's end")
check(body(runner, "func stopBackgroundTask(id: String)").contains("backgroundTasks.noteStoppedByUser(id: id)")
      && body(runner, "func stopBackgroundTask(id: String)").contains("ClaudeSteer.stopTaskLine("),
      "stopping one claude task asks claude, and its stop is not said as news")
let waitingRowRule = body(page, "private var awaitingFirstAgentEvent: Bool")
let stallRule = body(runner, "private var awaitingFirstOutput: Bool")
check(waitingRowRule.contains("WaitingRow.awaitsAgent(runner.events, compactionIsOutput: false)")
      && stallRule.contains("WaitingRow.awaitsAgent(events, compactionIsOutput: true)")
      && !waitingRowRule.contains(".reversed()") && !stallRule.contains(".reversed()"),
      "the waiting row and the stall notice ask the one rule, neither walking the buffer by itself",
      "row: \(waitingRowRule)\nstall: \(stallRule)")

// ── 5. the installed claude ──────────────────────────────────────────
print("5. the installed claude against the stand-in endpoint (token-free)")

func claudeBinary() -> String? {
    let home = NSHomeDirectory()
    for c in [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    where FileManager.default.isExecutableFile(atPath: c) {
        return (c as NSString).resolvingSymlinksInPath
    }
    return nil
}
func output(_ path: String, _ arguments: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [String] = []
    func take(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let chunk = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            let text = String(decoding: chunk, as: UTF8.self)
            if !text.isEmpty { lines.append(text) }
        }
    }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
func object(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}
func isType(_ text: String, _ type: String, _ subtype: String? = nil) -> Bool {
    let o = object(text)
    return o["type"] as? String == type && (subtype == nil || o["subtype"] as? String == subtype)
}

struct Session {
    let claude: Process
    let input: FileHandle
    let lines: Lines
    let server: Process
    let dir: URL
    let records: URL
    func write(_ text: String) { input.write(Data(text.utf8)) }
    func wait(_ seconds: TimeInterval, until: ([String]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if until(lines.all) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return until(lines.all)
    }
    /// Close claude's input, as SipAI does once nothing is left to send;
    /// claude then exits. Its exit code, nil if it did not.
    func finish() -> Int32? {
        try? input.close()
        let deadline = Date().addingTimeInterval(20)
        while claude.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if claude.isRunning { claude.terminate(); return nil }
        server.terminate()
        return claude.terminationStatus
    }
    func transcript() -> URL? {
        let projects = dir.appendingPathComponent("cfg/projects")
        return (try? FileManager.default.subpathsOfDirectory(atPath: projects.path))?
            .first { $0.hasSuffix(".jsonl") }
            .map { projects.appendingPathComponent($0) }
    }
    /// The text of every message the model was sent in each request.
    func requests() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: records.path)) ?? []).sorted().map {
            String(decoding: (try? Data(contentsOf: records.appendingPathComponent($0))) ?? Data(), as: UTF8.self)
        }
    }
}

/// Claude with its input open, as SipAI runs a turn it can steer: the
/// stand-in answers with `tool` on its first request, if given, and with
/// text after `delay` seconds.
func startClaude(_ claude: String, tool: [String: Any]?, delay: Double = 0, prompt: String) -> Session? {
    guard FileManager.default.fileExists(atPath: fakeServer) else { return nil }
    let dir = scratch("live")
    let cfg = dir.appendingPathComponent("cfg"), cwd = dir.appendingPathComponent("cwd")
    let rec = dir.appendingPathComponent("rec")
    for u in [cfg, cwd, rec] { try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
    var serverArgs = ["-I", fakeServer, rec.path]
    if let tool {
        let file = dir.appendingPathComponent("tool.json")
        try? JSONSerialization.data(withJSONObject: tool).write(to: file)
        serverArgs += ["--anthropic-script", file.path]
    }
    if delay > 0 { serverArgs += ["--anthropic-delay", String(delay)] }
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = serverArgs
    let serverOut = Pipe(); server.standardOutput = serverOut; server.standardError = FileHandle.nullDevice
    guard (try? server.run()) != nil else { return nil }
    var port = ""
    var pending = Data()
    while port.isEmpty {
        let chunk = serverOut.fileHandleForReading.availableData
        if chunk.isEmpty { server.terminate(); return nil }
        pending.append(chunk)
        let text = String(decoding: pending, as: UTF8.self)
        if let range = text.range(of: #"PORT=(\d+)"#, options: .regularExpression) {
            port = String(text[range].dropFirst(5))
        }
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: claude)
    // SipAI's argv for a claude turn that takes messages while it runs.
    p.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                   ClaudeSteer.replayFlag, "--permission-mode", "bypassPermissions"]
    p.currentDirectoryURL = cwd
    var e = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC") }
    e["CLAUDE_CONFIG_DIR"] = cfg.path
    e["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:\(port)"
    e["ANTHROPIC_API_KEY"] = "sk-ant-harness-junk"
    p.environment = e
    let input = Pipe()
    p.standardInput = input
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    let lines = Lines()
    out.fileHandleForReading.readabilityHandler = { lines.take($0.availableData) }
    guard (try? p.run()) != nil else { server.terminate(); return nil }
    let session = Session(claude: p, input: input.fileHandleForWriting, lines: lines, server: server,
                          dir: dir, records: rec)
    session.write(ClaudeSteer.userLine(text: prompt))
    return session
}
/// Every message claude took, read off its stdout by the REAL tracker.
func taken(_ lines: [String], prompt: String, wrote: [String]) -> [ClaudeSteerTracker.Taken] {
    var t = ClaudeSteerTracker(prompt: prompt)
    for w in wrote { t.wrote(w) }
    return lines.compactMap { t.read(line: $0) }
}

let claude = claudeBinary()
let installed = claude.flatMap { output($0, ["--version"]).split(separator: " ").first.map(String.init) }
let replayListed = claude.map { output($0, ["--help"]).contains(ClaudeSteer.replayFlag) } ?? false
if let claude, !fakeServer.isEmpty, ClaudeSteer.takesInput(installedClaude: installed, replayListed: replayListed) {
    print("     (\(claude), \(installed ?? "?"))")

    // 5a. Written while a tool runs: claude hands it to the model with the
    // step after the tool, in the same turn.
    let steerA = "STEERED while the tool runs"
    if let s = startClaude(claude, tool: ["name": "Bash", "input": ["command": "sleep 4", "description": "Wait a little"]],
                           prompt: "FIRST prompt please") {
        let toolSeen = s.wait(20) { $0.contains { $0.contains("\"tool_use\"") && isType($0, "assistant") } }
        Thread.sleep(forTimeInterval: 0.5)
        s.write(ClaudeSteer.userLine(text: steerA))
        _ = s.wait(30) { $0.contains { isType($0, "result") } }
        Thread.sleep(forTimeInterval: 0.5)
        let code = s.finish()
        let lines = s.lines.all
        let takes = taken(lines, prompt: "FIRST prompt please", wrote: [steerA])
        check(toolSeen && takes == [ClaudeSteerTracker.Taken(words: steerA, opensTurn: false)]
              && lines.filter { isType($0, "result") }.count == 1 && code == 0,
              "a message written while a tool runs is taken into the turn: one turn, one result, and claude exits once its input closes",
              "tool \(toolSeen), taken \(takes), results \(lines.filter { isType($0, "result") }.count), exit \(String(describing: code))")
        check(s.requests().contains { $0.contains(steerA) },
              "…and the model is sent it with the step after the tool")
        if let file = s.transcript() {
            let rows = AgentSessionScanner.readHistory(of: file).map(rowSignature)
            let into = rows.firstIndex(of: "into:" + steerA)
            check(into != nil && rows.firstIndex(of: "tool:Bash").map { $0 < into! } == true
                  && rows.lastIndex { $0.hasPrefix("assistant:") }.map { into! < $0 } == true,
                  "…reopened, it sits where it was drawn live: after the tool, before the answer, into the turn",
                  "\(rows)")
        } else {
            check(false, "the session's transcript is on disk")
        }
        try? FileManager.default.removeItem(at: s.dir)
    } else {
        skip("a message written while a tool runs", "the stand-in endpoint or claude did not start")
    }

    // 5b. Written while the answer is on its way: claude answers, then runs
    // the message as a turn of its own in the same process.
    let steerB = "STEERED while the answer is on its way"
    if let s = startClaude(claude, tool: nil, delay: 4, prompt: "FIRST prompt please") {
        _ = s.wait(20) { $0.contains { isType($0, "system", "init") } }
        Thread.sleep(forTimeInterval: 1)
        s.write(ClaudeSteer.userLine(text: steerB))
        _ = s.wait(40) { $0.filter { isType($0, "result") }.count >= 2 }
        Thread.sleep(forTimeInterval: 0.5)
        let code = s.finish()
        let lines = s.lines.all
        let takes = taken(lines, prompt: "FIRST prompt please", wrote: [steerB])
        let firstResult = lines.firstIndex { isType($0, "result") }
        let echoAt = lines.firstIndex { isType($0, "user") && $0.contains(steerB) }
        check(takes == [ClaudeSteerTracker.Taken(words: steerB, opensTurn: true)]
              && lines.filter { isType($0, "result") }.count == 2
              && firstResult != nil && echoAt != nil && firstResult! < echoAt! && code == 0,
              "a message written while the answer is on its way is run as a turn of its own after it, in the same process",
              "taken \(takes), results \(lines.filter { isType($0, "result") }.count), exit \(String(describing: code))")
        if let file = s.transcript() {
            let rows = AgentSessionScanner.readHistory(of: file).map(rowSignature)
            let own = rows.firstIndex(of: "user:" + steerB)
            check(own != nil && rows.firstIndex { $0.hasPrefix("assistant:") }.map { $0 < own! } == true
                  && !rows.contains("into:" + steerB),
                  "…reopened, a message of its own after the first answer, as it was drawn live", "\(rows)")
        } else {
            check(false, "the session's transcript is on disk")
        }
        try? FileManager.default.removeItem(at: s.dir)
    } else {
        skip("a message written while the answer is on its way", "the stand-in endpoint or claude did not start")
    }

    // 5c. One background task stopped from its line.
    if ClaudePrintMode.allowsBackgroundTasks(installedClaude: installed, cachedShellWait: nil) {
        let marker = scratch("stop").appendingPathComponent("task-done.txt")
        if let s = startClaude(claude, tool: ["name": "Bash", "input": [
            "command": "sleep 30; date > '\(marker.path)'", "description": "Sleep then write a file",
            "run_in_background": true]], prompt: "Start the job in the background.") {
            _ = s.wait(30) { lines in
                lines.contains { isType($0, "system", "task_started") } && lines.contains { isType($0, "result") }
            }
            let taskId = s.lines.all.first { isType($0, "system", "task_started") }
                .flatMap { object($0)["task_id"] as? String }
            let before = s.lines.all.count
            if let taskId { s.write(ClaudeSteer.stopTaskLine(taskId: taskId, requestId: UUID().uuidString)) }
            let gone = s.wait(8) { lines in
                lines.dropFirst(before).contains { isType($0, "system", "task_notification") }
            }
            Thread.sleep(forTimeInterval: 4)
            let lines = s.lines.all
            let afterStop = Array(lines.dropFirst(before))
            // The REAL rule over the REAL stdout, the stop noted where the runner notes it.
            var rule = ClaudeBackgroundTasks()
            var notices: [String] = []
            for (i, text) in lines.enumerated() {
                if i == before, let taskId { rule.noteStoppedByUser(id: taskId) }
                if let notice = rule.read(line: text) { notices.append(notice) }
                for event in AgentEventParser.parse(line: text, fallbackCwd: s.dir) {
                    switch event.kind {
                    case .toolResult, .systemInit: rule.noteRequestStarted()
                    default: break
                    }
                }
            }
            let code = s.finish()
            let survivors = output("/usr/bin/pgrep", ["-f", marker.path])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            check(taskId != nil && gone && !afterStop.contains { isType($0, "result") }
                  && survivors.isEmpty && !FileManager.default.fileExists(atPath: marker.path),
                  "a task stopped from its line stops at once, and claude runs no turn to report it",
                  "task \(String(describing: taskId)), reported \(gone), survivors '\(survivors)'")
            check(notices.isEmpty && rule.resultEndsTurn && code == 0,
                  "…the turn owes nothing more, says nothing of the stop, and claude exits once its input closes",
                  "notices \(notices), ends \(rule.resultEndsTurn), exit \(String(describing: code))")
            if let file = s.transcript() {
                let rows = AgentSessionScanner.readHistory(of: file).map(rowSignature)
                check(!rows.contains { $0.hasPrefix("notice:") },
                      "…reopened, nothing of the stop either", "\(rows)")
            }
            try? FileManager.default.removeItem(at: s.dir)
            try? FileManager.default.removeItem(at: marker.deletingLastPathComponent())
        } else {
            skip("one task stopped", "the stand-in endpoint or claude did not start")
        }
    } else {
        skip("one task stopped", "claude \(installed ?? "?") keeps background tasks off")
    }
} else {
    skip("the installed claude", claude == nil ? "claude not installed"
         : fakeServer.isEmpty ? "no stand-in endpoint given"
         : "claude \(installed ?? "(version unread)") takes no message mid-turn (below \(ClaudeSteer.floor), or no \(ClaudeSteer.replayFlag))")
}

print("\n\(passed) passed, \(failed) failed, \(skipped) skipped")
exit(failed == 0 ? 0 : 1)
