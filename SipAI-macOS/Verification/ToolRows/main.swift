// What a tool row says, live and reopened — see run.sh for what is pinned
// and why. Sections 1–4 are pure, section 5 reads the sources, and
// section 6 (last) drives the real codex and kimi, token-free.

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

// MARK: - 7. Titles in SipAI's language
//
// A pass of its own: run.sh runs the harness again with `titles` and
// `-AppleLanguages (zh-Hans)`, the catalog compiled beside it, so each
// title resolves as the app resolves it.

if CommandLine.arguments.count > 3, CommandLine.arguments[3] == "titles" {
    print("7. Titles in SipAI's language (zh-Hans)")
    let catalogURL = URL(fileURLWithPath: srcRoot + "/SipAI/Resources/Localizable.xcstrings")
    let catalog = (try? Data(contentsOf: catalogURL))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["strings"] as? [String: Any] ?? [:]
    func chinese(_ key: String) -> String? {
        let entry = catalog[key] as? [String: Any]
        let zh = (entry?["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any]
        return (zh?["stringUnit"] as? [String: Any])?["value"] as? String
    }
    check("7·. the pass runs in Chinese (control: a chip title the app already translated)",
          String(localized: "Output", comment: "Chip title for a tool result without its call in view")
            == chinese("Output") && chinese("Output") != "Output")
    // The rows whose title is SipAI's own word for them, by the catalog key
    // it reads: Codex's events carry only a machine label, and Claude's Edit
    // and question tool are shown under a word of SipAI's.
    let chosen: [(names: [String], key: String, english: String)] = [
        (["command_execution"], "tool.title.shell", "Shell"),
        (["file_change", "patch_apply", "Edit", "MultiEdit"], "tool.title.update", "Update"),
        (["web_search", "web_search_call"], "tool.title.search", "Search"),
        (["image_view", "view_image"], "tool.title.viewed-image", "Viewed image"),
        (["todo_list"], "tool.title.todo", "Todo"),
        (["AskUserQuestion"], "tool.title.question", "Question"),
    ]
    for title in chosen {
        let shown = title.names.map(AgentRendering.displayToolName)
        let wanted = chinese(title.key)
        check("7a. \(title.english) — a title SipAI chooses — is in SipAI's language for \(title.names.joined(separator: ", "))",
              wanted != nil && wanted != title.english && shown.allSatisfy { $0 == wanted },
              "shown \(shown), catalog \(wanted ?? "no entry")")
    }
    let named = ["Read", "Bash", "Write", "Grep", "ReadMediaFile", "exec_command", "apply_patch", "mcp__notes__find"]
    check("7b. a tool shown by its own name keeps it in every language",
          named.allSatisfy { AgentRendering.displayToolName($0) == $0 },
          "\(named.map(AgentRendering.displayToolName))")
    check("7c. an MCP call's title is the protocol's name, the same in every language",
          AgentRendering.displayToolName("mcp_tool_call") == "MCP")
    print("")
    print("passed \(passed), failed \(failed), skipped \(skipped)")
    exit(failed == 0 ? 0 : 1)
}

func json(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

func line(_ obj: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

// MARK: - A row as the chip draws it

struct Chip: Equatable {
    var title: String
    var summary: String
    var body: [String]
    var result: [String]
}

/// One tool call as `AgentSessionView.toolActivityChip` draws it: the
/// title, the summary beside it, the body rows and the result rows.
func chip(name: String, input: [String: Any], output: String?) -> Chip {
    Chip(title: AgentRendering.displayToolName(name),
         summary: AgentRendering.toolSummary(name: name, input: input, resultOutput: output),
         body: AgentRendering.fullToolBody(name: name, input: input).map(\.text),
         result: output.map { AgentRendering.toolResultRows(name: name, output: $0).map(\.text) } ?? [])
}

/// A transcript as signatures: a tool row by what its chip says, the rest
/// by kind and words.
func chips(_ items: [AgentSessionHistoryItem]) -> [String] {
    var results: [String: (String, Bool)] = [:]
    for item in items {
        if case .toolResult(let id, let content, let isError) = item.kind { results[id] = (content, isError) }
    }
    var out: [String] = []
    for item in items {
        switch item.kind {
        case .toolUse(let id, let name, let input):
            let result = results[id]
            let c = chip(name: name, input: input, output: result?.0)
            out.append("\(c.title)|\(c.summary)|\(c.body.joined(separator: "⏎"))|\(result?.1 == true ? "⚠" : "")\(c.result.joined(separator: "⏎"))")
        case .userText(let text):
            out.append("user:\(text)")
        case .assistantText(let text):
            out.append("say:\(text)")
        case .shellOutput(let output):
            out.append("shell:\(output.text)")
        default:
            break
        }
    }
    return out
}

/// Live events in the same signatures.
func chips(_ events: [StreamEvent]) -> [String] {
    var results: [String: (String, Bool)] = [:]
    for event in events {
        if case .toolResult(let id, let output, let isError) = event.kind { results[id] = (output, isError) }
    }
    var out: [String] = []
    for event in events {
        if case .toolUse(let id, let name, let input) = event.kind {
            let result = results[id]
            let c = chip(name: name, input: input, output: result?.0)
            out.append("\(c.title)|\(c.summary)|\(c.body.joined(separator: "⏎"))|\(result?.1 == true ? "⚠" : "")\(c.result.joined(separator: "⏎"))")
        }
    }
    return out
}

func toolChips(_ signatures: [String]) -> [String] {
    signatures.filter { !$0.hasPrefix("user:") && !$0.hasPrefix("say:") && !$0.hasPrefix("shell:") }
}

// MARK: - 1. The renderer

print("1. What a row says")

do {
    let none = chip(name: "CronList", input: [:], output: nil)
    check("1a. a tool called with no arguments draws no body — never `{ }`",
          none.body.isEmpty, "\(none.body)")
    let mcp = chip(name: "mcp__notes__list", input: [:], output: "a\nb")
    check("…nor does an MCP tool with none (any agent's), its result still drawn",
          mcp.body.isEmpty && mcp.result == ["a", "b"], "\(mcp)")
    let some = chip(name: "mcp__notes__find", input: ["q": "x"], output: nil)
    check("…while one with arguments still shows them", some.body.joined().contains("\"q\""), "\(some.body)")
}

do {
    let read = chip(name: "Read", input: ["path": "/w/notes.txt"], output: nil)
    check("1b. a Kimi Read row names its file (Kimi says `path`)", read.summary == "/w/notes.txt", "\(read)")
    let range = chip(name: "Read", input: ["path": "/w/notes.txt", "line_offset": 5, "n_lines": 10], output: nil)
    check("…and the lines it read (Kimi's `line_offset` / `n_lines`)",
          range.summary == "/w/notes.txt, lines 5-15", range.summary)
    let edit = chip(name: "Edit", input: ["path": "/w/a.swift", "old_string": "x", "new_string": "y"], output: nil)
    check("…a Kimi Edit row names its file", edit.title == "Update" && edit.summary == "/w/a.swift", "\(edit)")
    let write = chip(name: "Write", input: ["path": "/w/b.txt", "content": "hi\n"], output: nil)
    check("…a Kimi Write row names its file", write.summary == "/w/b.txt", "\(write)")
    let claudeRead = chip(name: "Read", input: ["file_path": "/w/c.txt", "offset": 3, "limit": 4], output: nil)
    let claudeEdit = chip(name: "Edit", input: ["file_path": "/w/d.swift", "old_string": "a", "new_string": "b"],
                          output: nil)
    check("…and Claude's, which say `file_path`, read as before",
          claudeRead.summary == "/w/c.txt, lines 3-7" && claudeEdit.summary == "/w/d.swift",
          "\(claudeRead.summary) / \(claudeEdit.summary)")
}

do {
    let command = chip(name: "command_execution", input: ["command": "echo hello"], output: "hello\n")
    check("1c. a Codex command row reads as a shell command, never a JSON body",
          command.title == "Shell" && command.summary == "echo hello" && command.body == ["$ echo hello"]
            && command.result == ["hello"], "\(command)")
    let search = chip(name: "web_search", input: ["query": "swift 6 release"], output: "swift 6 release")
    check("1d. a Codex search row names its terms, with no body and no echo of the terms below",
          search.title == "Search" && search.summary == "swift 6 release" && search.body.isEmpty
            && search.result.isEmpty, "\(search)")
    let reopened = chip(name: "web_search_call", input: ["command": "swift 6 release"], output: nil)
    check("…and reopened, the same", reopened.title == "Search" && reopened.summary == "swift 6 release"
            && reopened.body.isEmpty, "\(reopened)")
    let codeMode = chip(name: "web_search", input: [:], output: "swift 6 release")
    check("…a code-mode search, which starts with no terms, names them once it has ended",
          codeMode.summary == "swift 6 release" && codeMode.body.isEmpty && codeMode.result.isEmpty, "\(codeMode)")
}

do {
    let changes: [[String: Any]] = [
        ["path": "/w/made.txt", "kind": "add", "diff": "hello\n"],
        ["path": "/w/seed.txt", "kind": "update", "diff": "@@ -1 +1 @@\n-old\n+new\n"],
        ["path": "/w/gone.txt", "kind": "delete", "diff": "bye\n"],
        ["path": "/w/a.txt", "kind": "update", "move_path": "/w/b.txt", "diff": ""],
    ]
    let change = chip(name: "file_change", input: ["changes": changes], output: "")
    check("1e. a Codex file change names its files",
          change.title == "Update" && change.summary.contains("made.txt") && change.summary.contains("seed.txt"),
          "\(change.summary)")
    check("…each file with what happened to it, and its diff in the diff's colours",
          change.body.contains(where: { $0.contains("/w/made.txt") })
            && change.body.contains("+hello")
            && change.body.contains("-old") && change.body.contains("+new")
            && change.body.contains(where: { $0.contains("/w/gone.txt") }) && change.body.contains("-bye")
            && change.body.contains(where: { $0.contains("/w/b.txt") }),
          "\(change.body)")
    check("…and no \"completed\" below it", change.result.isEmpty, "\(change.result)")
    let styles = AgentRendering.fullToolBody(name: "file_change", input: ["changes": changes])
    check("…added lines green, removed lines red",
          styles.first(where: { $0.text == "+new" })?.style == .diffAdd
            && styles.first(where: { $0.text == "-old" })?.style == .diffRemove,
          "\(styles.map { "\($0.text):\($0.style)" })")
    let one = chip(name: "file_change", input: ["changes": [["path": "/w/only.swift", "kind": "update", "diff": ""]]],
                   output: "")
    check("…one file by its path, as Claude's Edit row", one.summary == "/w/only.swift", one.summary)
    let failed = chip(name: "file_change", input: ["changes": [["path": "/w/x.txt", "kind": "update"]]],
                      output: "")
    check("…a change codex says nothing about draws no empty output line", failed.result.isEmpty, "\(failed)")
    let exec = chip(name: "file_change", input: ["changes": [["path": "/w/y.txt", "kind": "update"]]], output: nil)
    check("…and exec's item, which has no diff, still names the file",
          exec.body.contains(where: { $0.contains("/w/y.txt") }), "\(exec.body)")
}

do {
    let image = chip(name: "image_view", input: ["path": "/w/shot.png"], output: "")
    check("1f. an image Codex viewed reads \"Viewed image\" and its file, with nothing to open",
          image.title == "Viewed image" && image.summary == "/w/shot.png" && image.body.isEmpty && image.result.isEmpty,
          "\(image)")
    check("…counted as a file read, as an image read is for the other agents",
          ChatOnlyActivity.agentStep(forToolNamed: "image_view", input: ["path": "/w/shot.png"])
            == ChatOnlyActivity.agentStep(forToolNamed: "ReadMediaFile", input: ["path": "/w/shot.png"]))
}

do {
    // The icons, by the one renderer that names a row.
    let icons: [(String, String)] = [
        ("command_execution", "terminal"), ("file_change", "pencil"), ("patch_apply", "pencil"),
        ("web_search", "globe"), ("web_search_call", "globe"), ("mcp_tool_call", "puzzlepiece.extension"),
        ("image_view", "photo"), ("view_image", "photo"), ("todo_list", "checklist"),
        ("Edit", "pencil"), ("Bash", "terminal"), ("Read", "doc.text"), ("AskUserQuestion", "questionmark.bubble"),
        ("mcp__notes__find", "puzzlepiece.extension"), ("exec_command", "wrench.and.screwdriver"),
    ]
    let wrong = icons.filter { AgentRendering.toolSymbol($0.0) != $0.1 }.map { "\($0.0): \(AgentRendering.toolSymbol($0.0))" }
    check("1g. each row keeps its icon", wrong.isEmpty, "\(wrong)")
}

// MARK: - 2. Codex's live parser

print("2. Codex live")

let fallback = URL(fileURLWithPath: "/w")
func viaAppServer(_ method: String, _ item: [String: Any]) -> [StreamEvent] {
    CodexAppServer.execEvents(method: method, params: ["item": item]).flatMap {
        CodexEventParser.parse(object: $0, fallbackCwd: fallback).events
    }
}

do {
    // The app-server's fileChange item, as codex 0.166 sends it.
    let item: [String: Any] = [
        "type": "fileChange", "id": "call_3", "status": "completed",
        "changes": [
            ["path": "/w/made2.txt", "kind": ["type": "add"], "diff": "hello\n"],
            ["path": "/w/seed2.txt", "kind": ["type": "update", "move_path": NSNull()],
             "diff": "@@ -1 +1 @@\n-old\n+new\n"],
        ],
    ]
    let started = viaAppServer("item/started", item.merging(["status": "inProgress"]) { $1 })
    let completed = viaAppServer("item/completed", item)
    let live = chips(started + completed)
    check("2a. an app-server file change keeps its files, their kinds and their diffs",
          live.count == 1 && live[0].contains("made2.txt") && live[0].contains("seed2.txt")
            && live[0].contains("+new") && live[0].contains("-old"),
          "\(live)")
    check("…and its result says nothing — no \"completed\"",
          completed.contains { if case .toolResult(_, let o, false) = $0.kind { return o.isEmpty } else { return false } },
          "\(completed.map(\.kind))")
    let failed = viaAppServer("item/completed", item.merging(["status": "failed"]) { $1 })
    check("…a failed one is a failure",
          failed.contains { if case .toolResult(_, _, true) = $0.kind { return true } else { return false } })
}

do {
    // `codex exec --json`'s file_change item, as 0.166 prints it: paths and
    // kinds, no diff.
    let started = CodexEventParser.parse(line: #"{"type":"item.started","item":{"id":"item_0","type":"file_change","changes":[{"path":"/w/made.txt","kind":"add"},{"path":"/w/seed.txt","kind":"update"}],"status":"in_progress"}}"#,
                                         fallbackCwd: fallback).events
    let live = chips(started)
    check("2b. exec's file change names its files", live.count == 1 && live[0].contains("made.txt")
            && live[0].contains("seed.txt"), "\(live)")
}

do {
    let item: [String: Any] = ["type": "commandExecution", "id": "exec-1", "command": "/bin/zsh -lc 'echo hello'",
                               "cwd": "/w", "status": "completed", "aggregatedOutput": "hello\n", "exitCode": 0,
                               "source": "unifiedExecStartup", "commandActions": []]
    let live = chips(viaAppServer("item/started", item.merging(["status": "inProgress"]) { $1 })
                     + viaAppServer("item/completed", item))
    check("2c. a command row shows the command codex ran, its login-shell wrapper off",
          live == ["Shell|echo hello|$ echo hello|hello"], "\(live)")
}

do {
    // The app-server's imageView item, as codex 0.166 sends it: started and
    // completed, the file as a plain path. `codex exec` prints none.
    let item: [String: Any] = ["type": "imageView", "id": "call_1", "path": "/w/shot.png",
                               "startedAtMs": 1, "completedAtMs": 2]
    let live = chips(viaAppServer("item/started", item.merging(["completedAtMs": NSNull()]) { $1 })
                     + viaAppServer("item/completed", item))
    check("2d. an image codex views is a row live, as it reopens", live == ["Viewed image|/w/shot.png||"], "\(live)")
}

// MARK: - 3. Codex reopened

print("3. Codex reopened")

func ev(_ payload: [String: Any]) -> String { line(["type": "event_msg", "payload": payload]) }
func item(_ payload: [String: Any]) -> String { line(["type": "response_item", "payload": payload]) }
func turnStart(_ id: String) -> String {
    ev(["type": "task_started", "turn_id": id, "turn_attribution": ["turn_trigger": "user"]])
}
func turnEnd(_ id: String) -> String { ev(["type": "task_complete", "turn_id": id]) }
func userMessage(_ text: String) -> String {
    item(["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]])
}
func agentMessage(_ text: String) -> String {
    item(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]])
}
func script(_ id: String, _ text: String) -> String {
    item(["type": "custom_tool_call", "name": "exec", "call_id": id, "status": "completed", "input": text])
}
func customCall(_ id: String, _ name: String, _ input: String) -> String {
    item(["type": "custom_tool_call", "name": name, "call_id": id, "status": "completed", "input": input])
}
func customOutput(_ id: String, _ text: String) -> String {
    item(["type": "custom_tool_call_output", "call_id": id, "output": text])
}
func call(_ id: String, _ name: String, _ args: [String: Any], namespace: String? = nil) -> String {
    var payload: [String: Any] = ["type": "function_call", "name": name, "call_id": id,
                                  "arguments": line(args)]
    if let namespace { payload["namespace"] = namespace }
    return item(payload)
}
func callOutput(_ id: String, _ text: String) -> String {
    item(["type": "function_call_output", "call_id": id, "output": text])
}
/// Codex's record of a command, in its own shape.
func commandRecord(_ id: String, _ command: String, output: String, exit: Int = 0,
                   source: String = "unified_exec_startup") -> String {
    ev(["type": "item_completed", "thread_id": "th", "turn_id": "t",
        "item": ["type": "CommandExecution", "id": id, "process_id": "4242",
                 "command": ["/bin/zsh", "-lc", command], "cwd": "/w",
                 "parsed_cmd": [["type": "unknown", "cmd": command]], "source": source,
                 "status": exit == 0 ? "completed" : "failed", "aggregated_output": output,
                 "exit_code": exit, "duration": ["secs": 0, "nanos": 8291]],
        "started_at_ms": 1, "completed_at_ms": 2])
}
/// Codex's record of a file change: a map from path to what happened to it.
func fileRecord(_ id: String, _ changes: [String: [String: Any]], status: String = "completed",
                stderr: String = "") -> String {
    ev(["type": "item_completed", "thread_id": "th", "turn_id": "t",
        "item": ["type": "FileChange", "id": id, "changes": changes, "status": status,
                 "stdout": "Success. Updated the following files:\n", "stderr": stderr],
        "started_at_ms": 1, "completed_at_ms": 2])
}

func reopen(_ lines: [String]) -> [String] {
    let file = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("toolrows-\(UUID().uuidString).jsonl")
    try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    return chips(CodexSessionScanner.readHistory(of: file, maxTurns: 50))
}

do {
    // Code mode: the model's only call is a script; what the script ran is
    // in codex's records.
    let rows = reopen([
        turnStart("t1"), userMessage("tidy up"),
        script("call_a", "const r = await tools.exec_command({cmd:\"echo hello\"}); text(r);"),
        commandRecord("exec-1", "echo hello", output: "hello\n"),
        customOutput("call_a", "hello\n"),
        script("call_b", "text(await tools.apply_patch(\"*** Begin Patch\\n*** Add File: made.txt\\n+hello\\n*** End Patch\\n\"))"),
        fileRecord("exec-2", ["/w/made.txt": ["type": "add", "content": "hello\n"],
                              "/w/seed.txt": ["type": "update", "unified_diff": "@@ -1 +1 @@\n-old\n+new\n",
                                              "move_path": NSNull()]]),
        customOutput("call_b", "Success."),
        call("call_c", "wait", ["cell_id": "3", "yield_time_ms": 1000]),
        callOutput("call_c", "done"),
        call("call_d", "sleep", ["seconds": 1], namespace: "clock"),
        callOutput("call_d", "slept"),
        agentMessage("DONE"), turnEnd("t1"),
    ])
    check("3a. code mode reopens as the commands and edits codex recorded — no script, no wait, no sleep",
          rows == ["user:tidy up",
                   "Shell|echo hello|$ echo hello|hello",
                   chips([AgentSessionHistoryItem(kind: .toolUse(id: "x", name: "file_change", input: [
                       "changes": [["path": "/w/made.txt", "kind": "add", "diff": "hello\n"],
                                   ["path": "/w/seed.txt", "kind": "update", "diff": "@@ -1 +1 @@\n-old\n+new\n"]],
                   ])), AgentSessionHistoryItem(kind: .toolResult(toolUseId: "x", content: "", isError: false))])[0],
                   "say:DONE"],
          "\(rows)")
}

do {
    let rows = reopen([
        turnStart("t1"), userMessage("go"),
        call("call_x", "exec_command", ["cmd": "echo hi"]),
        commandRecord("call_x", "echo hi", output: "hi\n"),
        callOutput("call_x", "Process exited with code 0\nOutput:\nhi\n"),
        customCall("call_y", "apply_patch", "*** Begin Patch\n*** Update File: seed.txt\n@@\n-old\n+new\n*** End Patch\n"),
        fileRecord("call_y", ["/w/seed.txt": ["type": "update", "unified_diff": "@@ -1 +1 @@\n-old\n+new\n",
                                              "move_path": NSNull()]]),
        customOutput("call_y", "Success."),
        call("call_z", "exec_command", ["cmd": "sleep 30"]),
        callOutput("call_z", "Process running with session ID 123"),
        call("call_w", "write_stdin", ["session_id": 123, "chars": ""]),
        callOutput("call_w", "Process exited with code 0"),
        commandRecord("call_z", "sleep 30", output: ""),
        agentMessage("OK"), turnEnd("t1"),
    ])
    check("3b. a direct call is drawn as the record codex keeps of it — before its output or after",
          toolChips(rows).count == 3
            && rows.contains("Shell|echo hi|$ echo hi|hi")
            && rows.contains(where: { $0.hasPrefix("Update|/w/seed.txt|") })
            && rows.contains(where: { $0.hasPrefix("Shell|sleep 30|$ sleep 30|") }),
          "\(rows)")
    check("…never as the call too, and never the polls of a running command",
          !rows.contains { $0.hasPrefix("exec_command|") || $0.hasPrefix("apply_patch|") || $0.hasPrefix("write_stdin|") },
          "\(rows)")
}

do {
    let rows = reopen([
        turnStart("t1"), userMessage("!ls"),
        commandRecord("call_s", "ls", output: "a\n", source: "user_shell"),
        turnEnd("t1"),
    ])
    check("3c. the user's own `!` command is no tool row", toolChips(rows).isEmpty, "\(rows)")
}

do {
    let rows = reopen([
        turnStart("t1"), userMessage("wait for it"),
        script("call_a", "const r = await tools.exec_command({cmd:\"make\", yield_time_ms: 10}); text(r);"),
        customOutput("call_a", "Script running with cell ID 3"),
        call("call_b", "wait", ["cell_id": "3"]),
        commandRecord("exec-9", "make", output: "built\n"),
        callOutput("call_b", "built\n"),
        turnEnd("t1"),
    ])
    check("3d. a script still running at its output is not drawn: its command's record is",
          toolChips(rows) == ["Shell|make|$ make|built"], "\(rows)")
}

do {
    // An older codex (0.144–0.147) ran code mode before it recorded
    // commands: the script is all there is.
    let rows = reopen([
        turnStart("t1"), userMessage("old"),
        script("call_a", "const r = await tools.exec_command({cmd:\"pwd\"}); text(r);"),
        customOutput("call_a", "/w\n"),
        call("call_b", "exec_command", ["cmd": "ls"]),
        callOutput("call_b", "a\n"),
        agentMessage("OLD"), turnEnd("t1"),
    ])
    check("3e. a script codex recorded nothing for stays, and so does a call with no record",
          toolChips(rows).count == 2 && toolChips(rows)[0].hasPrefix("exec|")
            && toolChips(rows)[1].hasPrefix("exec_command|"),
          "\(rows)")
    check("…in the place it ran", rows.firstIndex(where: { $0.hasPrefix("exec|") }).map { $0 < rows.firstIndex(of: "say:OLD")! } == true,
          "\(rows)")
}

do {
    let rows = reopen([
        turnStart("t1"), userMessage("long"),
        call("call_z", "exec_command", ["cmd": "npm run dev"]),
        callOutput("call_z", "Process running with session ID 77"),
        agentMessage("started"), turnEnd("t1"),
    ])
    check("3f. a call whose record never comes is drawn when its turn ends — never lost",
          toolChips(rows).count == 1 && toolChips(rows)[0].hasPrefix("exec_command|"), "\(rows)")
}

do {
    let rows = reopen([
        turnStart("t1"), userMessage("pure"),
        script("call_a", "const x = 1 + 2; text(String(x));"),
        customOutput("call_a", "3"),
        agentMessage("3"), turnEnd("t1"),
    ])
    check("3g. a script that calls no tool is not drawn — the live feed sends nothing for it",
          toolChips(rows).isEmpty, "\(rows)")
}

do {
    let rows = reopen([
        turnStart("t1"), userMessage("bad patch"),
        customCall("call_y", "apply_patch", "*** Begin Patch\n*** Update File: nope.txt\n*** End Patch\n"),
        fileRecord("call_y", ["/w/nope.txt": ["type": "update", "unified_diff": "", "move_path": NSNull()]],
                   status: "failed", stderr: "Failed to find expected lines in /w/nope.txt"),
        customOutput("call_y", "apply_patch verification failed"),
        turnEnd("t1"),
    ])
    check("3h. a file change codex failed is a failure, with codex's words",
          toolChips(rows).count == 1 && toolChips(rows)[0].contains("⚠Failed to find expected lines"),
          "\(rows)")
}

do {
    // The watcher of a turn run elsewhere starts where the reading of the
    // file ended, so a command running when the session was opened was
    // drawn by that reading — the call, codex's record still to come.
    let opened = reopen([turnStart("t1"), userMessage("go"), call("call_x", "exec_command", ["cmd": "make"])])
    let after = [
        commandRecord("call_x", "make", output: "built\n"),
        callOutput("call_x", "Process exited with code 0\nOutput:\nbuilt\n"),
        agentMessage("BUILT"), turnEnd("t1"),
        turnStart("t2"), userMessage("again"),
        call("call_y", "exec_command", ["cmd": "make test"]),
        commandRecord("call_y", "make test", output: "ok\n"),
        callOutput("call_y", "Process exited with code 0\nOutput:\nok\n"),
        turnEnd("t2"),
    ]
    var watcher = CodexSessionScanner.RolloutDecoder()
    watcher.recordedTools.joinedMidTurn = true
    let watched = toolChips(chips(after.flatMap { watcher.items(forLine: $0) }))
    check("3i. a session opened mid-command shows the command once — as the reading of the file drew it",
          toolChips(opened).count == 1 && watched == ["Shell|make test|$ make test|ok"],
          "opened \(toolChips(opened)), watched \(watched)")
    var reader = CodexSessionScanner.RolloutDecoder()
    let unjoined = toolChips(chips(after.flatMap { reader.items(forLine: $0) }))
    check("…where a reader of the whole file draws a record whose call it never saw",
          unjoined.count == 2 && unjoined[0] == "Shell|make|$ make|built", "\(unjoined)")
}

do {
    // A script that ran an MCP tool: codex records it as a kind no row is
    // drawn from, which leaves the script — dropped there, it would vanish.
    let rows = reopen([
        turnStart("t1"), userMessage("ask the notes"),
        script("call_a", "text(JSON.stringify(await tools.mcp__notes__find({q: \"x\"})));"),
        ev(["type": "item_completed", "thread_id": "th", "turn_id": "t",
            "item": ["type": "McpToolCall", "id": "exec-9", "server": "notes", "tool": "find",
                     "arguments": ["q": "x"], "status": "completed",
                     "result": ["content": [["type": "text", "text": "a"]], "isError": false],
                     "duration": ["secs": 0, "nanos": 1000]]]),
        customOutput("call_a", "a"),
        agentMessage("FOUND"), turnEnd("t1"),
    ])
    check("3j. a script whose work codex recorded as nothing a row is drawn from stays, where it ran",
          toolChips(rows).count == 1 && toolChips(rows)[0].hasPrefix("exec|")
            && rows.firstIndex(where: { $0.hasPrefix("exec|") }).map { $0 < (rows.firstIndex(of: "say:FOUND") ?? 0) }
              == true,
          "\(rows)")
    let searched = reopen([
        turnStart("t1"), userMessage("find"),
        script("call_a", "text(await tools.web__run({open: \"https://www.python.org/downloads/\"}));"),
        ev(["type": "item_completed",
            "item": ["type": "Extension", "kind": "web.search", "id": "exec-1",
                     "query": "https://www.python.org/downloads/",
                     "action": ["type": "openPage", "url": "https://www.python.org/downloads/"]]]),
        customOutput("call_a", "page"),
        turnEnd("t1"),
    ])
    check("…while a search's record takes the place of the script that ran it",
          toolChips(searched) == ["Search|https://www.python.org/downloads/||"], "\(searched)")
}

do {
    // An image codex viewed: its record names the file as a `file://` URL.
    let fromScript = reopen([
        turnStart("t1"), userMessage("look"),
        script("call_a", "text(JSON.stringify(await tools.view_image({path: \"/w/my shot.png\"})));"),
        ev(["type": "item_completed", "thread_id": "th", "turn_id": "t",
            "item": ["type": "ImageView", "id": "exec-7", "path": "file:///w/my%20shot.png"]]),
        customOutput("call_a", "ok"),
        agentMessage("SEEN"), turnEnd("t1"),
    ])
    check("3k. an image viewed from a script reopens as \"Viewed image\" and its file, in place of the script",
          toolChips(fromScript) == ["Viewed image|/w/my shot.png||"], "\(fromScript)")
    let direct = reopen([
        turnStart("t1"), userMessage("look"),
        call("call_v", "view_image", ["path": "/w/shot.png"]),
        ev(["type": "item_completed", "thread_id": "th", "turn_id": "t",
            "item": ["type": "ImageView", "id": "call_v", "path": "file:///w/shot.png"]]),
        callOutput("call_v", "image"),
        turnEnd("t1"),
    ])
    check("…and so does a direct call, its record taking the call's place", toolChips(direct) == ["Viewed image|/w/shot.png||"],
          "\(direct)")
    let older = reopen([
        turnStart("t1"), userMessage("look"),
        call("call_v", "view_image", ["path": "/w/shot.png"]),
        callOutput("call_v", "image"),
        agentMessage("OLD"), turnEnd("t1"),
    ])
    check("…while a call codex kept no record of reads the same from its call",
          toolChips(older) == ["Viewed image|/w/shot.png||"], "\(older)")
}

// MARK: - 4. Kimi

print("4. Kimi")

func kimiWire(_ records: [[String: Any]]) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("toolrows-kimi-\(UUID().uuidString)/agents/main", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let wire = dir.appendingPathComponent("wire.jsonl")
    try? (records.map(line).joined(separator: "\n") + "\n").write(to: wire, atomically: true, encoding: .utf8)
    return wire
}
func loop(_ event: [String: Any]) -> [String: Any] {
    ["type": "context.append_loop_event", "time": 1_793_000_000, "event": event]
}

// Kimi 2.4.1's records of an image read, as its wire keeps them.
let imageBlocks: [[String: Any]] = [
    ["type": "text", "text": "<image path=\"/w/dot.png\">"],
    ["type": "image_url", "imageUrl": ["url": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQ"]],
    ["type": "text", "text": "</image>"],
]
let kimiRecords: [[String: Any]] = [
    ["type": "context.append_message", "time": 1_793_000_000,
     "message": ["role": "user", "id": "m1", "content": [["type": "text", "text": "look"]], "origin": ["kind": "user"]]],
    loop(["type": "tool.call", "toolCallId": "x1", "name": "Bash", "args": ["command": "echo partial; exit 3"]]),
    loop(["type": "tool.result", "toolCallId": "x1",
          "result": ["output": "partial\nCommand failed with exit code: 3.", "isError": true, "durationMs": 7]]),
    loop(["type": "tool.call", "toolCallId": "x2", "name": "Read",
          "args": ["path": "/w/notes.txt", "line_offset": 1, "n_lines": 2]]),
    loop(["type": "tool.result", "toolCallId": "x2", "result": ["output": "1\talpha\n2\tbeta", "durationMs": 1]]),
    loop(["type": "tool.call", "toolCallId": "x3", "name": "ReadMediaFile", "args": ["path": "dot.png"]]),
    loop(["type": "tool.result", "toolCallId": "x3",
          "result": ["output": imageBlocks,
                     "note": "<system>Read image file. Mime type: image/png. Size: 73 bytes.</system>",
                     "durationMs": 1]]),
]

do {
    let rows = chips(KimiSessionScanner.readHistory(of: kimiWire(kimiRecords), maxTurns: 50))
    check("4a. a reopened Kimi image read shows its text, never the image's data",
          rows.contains { $0.hasPrefix("ReadMediaFile|") && $0.contains("<image path=\"/w/dot.png\">") }
            && !rows.contains { $0.contains("base64") },
          "\(rows)")
    check("…and a failed command is a failure", rows.contains { $0.hasPrefix("Bash|") && $0.contains("|⚠partial") },
          "\(rows)")
}

// The same calls as kimi's headless stdout prints them (`kimi --prompt
// --output-format stream-json`, 2.4.1): a tool message carries no failure
// flag, and an image read prints its content blocks as one JSON string.
func kimiCallLine(_ id: String, _ name: String, _ args: [String: Any]) -> String {
    line(["role": "assistant", "content": "",
          "tool_calls": [["type": "function", "id": id, "function": ["name": name, "arguments": line(args)]]]])
}
func kimiToolLine(_ id: String, _ content: String) -> String {
    line(["role": "tool", "tool_call_id": id, "content": content])
}
let kimiStdout = [
    kimiCallLine("x1", "Bash", ["command": "echo partial; exit 3"]),
    kimiToolLine("x1", "partial\nCommand failed with exit code: 3."),
    kimiCallLine("x2", "Read", ["path": "/w/notes.txt", "line_offset": 1, "n_lines": 2]),
    kimiToolLine("x2", "1\talpha\n2\tbeta"),
    kimiCallLine("x3", "ReadMediaFile", ["path": "dot.png"]),
    kimiToolLine("x3", String(decoding: (try? JSONSerialization.data(withJSONObject: imageBlocks)) ?? Data(),
                              as: UTF8.self)),
]

func isResult(_ id: String) -> (StreamEvent) -> Bool {
    { if case .toolResult(let resultId, _, _) = $0.kind { return resultId == id } else { return false } }
}
/// A headless turn's live rows as the runner keeps them: stdout's, each
/// tool's result set to how the record says it ended — read after the row
/// was printed (`readKimiTasks`), or before it (`apply`).
func kimiLive(_ stdout: [String], records: [[String: Any]], recordFirst: Bool) -> [StreamEvent] {
    let endings = records.compactMap(KimiEventParser.toolEnding(record:))
    var events: [StreamEvent] = []
    if recordFirst {
        var pending = Dictionary(endings.map { ($0.toolCallId, $0) }, uniquingKeysWith: { $1 })
        for event in stdout.flatMap({ KimiEventParser.parse(line: $0, fallbackCwd: fallback) }) {
            if case .toolResult(let id, _, _) = event.kind, let ending = pending.removeValue(forKey: id),
               let kind = ending.correcting(event.kind) {
                events.append(StreamEvent(kind: kind))
            } else {
                events.append(event)
            }
        }
    } else {
        events = stdout.flatMap { KimiEventParser.parse(line: $0, fallbackCwd: fallback) }
        for ending in endings {
            if let index = events.lastIndex(where: isResult(ending.toolCallId)),
               let kind = ending.correcting(events[index].kind) {
                events[index] = StreamEvent(kind: kind)
            }
        }
    }
    return events
}

do {
    let reopened = toolChips(chips(KimiSessionScanner.readHistory(of: kimiWire(kimiRecords), maxTurns: 50)))
    let printed = chips(kimiStdout.flatMap { KimiEventParser.parse(line: $0, fallbackCwd: fallback) })
    let after = chips(kimiLive(kimiStdout, records: kimiRecords, recordFirst: false))
    let before = chips(kimiLive(kimiStdout, records: kimiRecords, recordFirst: true))
    check("4b. a live Kimi row ends as the record says — the reopened row, failure and image text alike",
          after == reopened, "live \(after)\nreopened \(reopened)")
    check("…whether the record is read after the row is printed or before", before == reopened, "\(before)")
    check("…where stdout alone draws neither (the reason the record is read)",
          printed != reopened && printed.contains { $0.contains("base64") }
            && !printed.contains { $0.hasPrefix("Bash|") && $0.contains("|⚠") },
          "\(printed)")
    let readEnding = kimiRecords.compactMap(KimiEventParser.toolEnding(record:)).first { $0.toolCallId == "x2" }
    let readRow = kimiStdout.flatMap { KimiEventParser.parse(line: $0, fallbackCwd: fallback) }.first(where: isResult("x2"))
    check("…and a row the record agrees with is left as it is",
          readEnding != nil && readRow.map { readEnding?.correcting($0.kind) == nil } == true)
    check("…the Read row names its file, live and reopened",
          after.contains { $0.hasPrefix("Read|/w/notes.txt, lines 1-3|") }, "\(after)")
}

// MARK: - 5. The wiring

print("5. The wiring")

func source(_ path: String) -> String {
    (try? String(contentsOfFile: srcRoot + "/SipAI/" + path, encoding: .utf8)) ?? ""
}

/// The declaration whose first line holds `signature`, down to the brace
/// that closes it at its own indentation.
func declaration(_ signature: String, in text: String) -> String {
    let lines = text.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0.contains(signature) }) else { return "" }
    let indent = String(lines[start].prefix { $0 == " " })
    var out: [String] = []
    for line in lines[start...] {
        out.append(line)
        if line == indent + "}" { break }
    }
    return out.joined(separator: "\n")
}

do {
    let view = source("Views/Chat/AgentSessionView.swift")
    let chipView = declaration("private func toolActivityChip(", in: view)
    let texts = declaration("private func chipTexts(", in: view)
    let shell = declaration("private func chipShell<", in: view)
    check("5a. the chip draws what the renderer says, and find counts the same pieces",
          chipView.contains("AgentRendering.toolSummary(") && chipView.contains("AgentRendering.toolResultRows(")
            && texts.contains("AgentRendering.toolSummary(") && texts.contains("AgentRendering.toolResultRows(")
            && !chipView.contains("summarizeToolInput(") && !texts.contains("fullToolResultBody("),
          "toolActivityChip / chipTexts")
    check("…and a chip that has ended with nothing inside does not open",
          chipView.contains("opens: result == nil || !rows.isEmpty || !resultRows.isEmpty")
            && shell.contains("guard opens else { return }")
            && shell.contains("let expanded = opens && expandedToolResults.contains(chipId)"),
          "chipShell")
}

do {
    let runner = source("Models/AgentRunner.swift")
    let read = declaration("private func readKimiTasks(", in: runner)
    let apply = declaration("private func apply(_ parsed:", in: runner)
    let stop = declaration("private func stopKimiTaskWatch(", in: runner)
    check("5b. a headless Kimi turn's rows end as its record says — read after the row is printed, or before",
          read.contains("KimiEventParser.toolEnding(record:")
            && read.contains("events[index] = StreamEvent(copying: events[index], kind: kind)")
            && read.contains("kimiToolEndings[ending.toolCallId] = ending")
            && apply.contains("kimiToolEndings.removeValue(forKey:")
            && apply.contains("events.append(StreamEvent(copying: event, kind: kind))")
            && stop.contains("kimiToolEndings = [:]"),
          "readKimiTasks / apply / stopKimiTaskWatch")
    let watches = runner.components(separatedBy: "\n").first { $0.contains("let watchesKimiTasks =") } ?? ""
    check("…in every headless Kimi turn, Chat only's too",
          watches.trimmingCharacters(in: .whitespaces) == "let watchesKimiTasks = isKimi && driver == .kimiPrint",
          watches)
}

do {
    let sessions = source("Models/CodexSessions.swift")
    check("5c. a reading of a Codex session draws what its last turn still held",
          declaration("static func readHistory(of url: URL", in: sessions).contains("decoder.finish()"))
    let tailer = source("Models/AgentSessionTailer.swift")
    check("…and the watcher of a turn run elsewhere says where it joined the file",
          declaration("func start(initialOffset:", in: tailer).contains("joinedMidTurn = initialOffset > 0")
            && declaration("func resume(atOffset newOffset:", in: tailer).contains("joinedMidTurn = newOffset > 0"))
    check("5d. the question tool this harness names is the bridge's",
          source("Models/MCPBridge.swift").contains("static let questionTool = \"AskUserQuestion\""))
}

// MARK: - 6. The real codex and kimi

print("6. The real codex and kimi (stand-in endpoint, token-free)")

/// A row by its title and summary alone: `codex exec`'s file change names
/// its files without their diffs, where the record keeps both.
func heads(_ rows: [String]) -> [String] {
    rows.map { $0.split(separator: "|", omittingEmptySubsequences: false).prefix(2).joined(separator: "|") }
}

// A 1×1 PNG, for an image read.
let onePixelPNG = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==") ?? Data()

let patch = """
*** Begin Patch
*** Add File: made.txt
+hello
*** Update File: seed.txt
@@
-old
+new
*** Delete File: gone.txt
*** End Patch

"""

/// One codex turn that edits three files, runs a command and views an image — directly or
/// from code-mode scripts — through `codex exec --json` or `codex
/// app-server`: its live rows and the rows its rollout reopens as.
func runCodex(_ codex: String, codeMode: Bool, appServer: Bool) -> (live: [String], reopened: [String])? {
    let dir = scratchFolder("codex")
    defer { try? FileManager.default.removeItem(at: dir) }
    let home = dir.appendingPathComponent("home"), cwd = dir.appendingPathComponent("cwd")
    for folder in [home, cwd] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    try? "old\n".write(to: cwd.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
    try? "bye\n".write(to: cwd.appendingPathComponent("gone.txt"), atomically: true, encoding: .utf8)
    let image = cwd.appendingPathComponent("dot.png")
    try? onePixelPNG.write(to: image)
    let imageLiteral = String(decoding: (try? JSONSerialization.data(withJSONObject: [image.path])) ?? Data(),
                              as: UTF8.self).dropFirst().dropLast()
    let patchLiteral = String(decoding: (try? JSONSerialization.data(withJSONObject: [patch])) ?? Data(),
                              as: UTF8.self).dropFirst().dropLast()
    let steps: [[String: Any]] = codeMode
        ? [["custom_tool_call": ["name": "exec", "input": "text(await tools.apply_patch(\(patchLiteral)));"]],
           ["custom_tool_call": ["name": "exec",
                                 "input": "text(JSON.stringify(await tools.exec_command({cmd: \"echo hello\"})));"]],
           ["custom_tool_call": ["name": "exec",
                                 "input": "text(JSON.stringify(await tools.view_image({path: \(imageLiteral)})));"]],
           ["text": "DONE"]]
        : [["custom_tool_call": ["name": "apply_patch", "input": patch]],
           ["function_call": ["name": "exec_command", "arguments": ["cmd": "echo hello"]]],
           ["function_call": ["name": "view_image", "arguments": ["path": image.path]]],
           ["text": "DONE"]]
    guard let (server, port) = startStandIn(fakeServerPath, flag: "--responses-script",
                                            script: [["marker": "TOOLPROBE", "steps": steps]], in: dir)
    else { return nil }
    defer { server.terminate() }
    try? """
    model_provider = "fake"
    model = "gpt-5.5"

    [model_providers.fake]
    name = "fake"
    base_url = "http://127.0.0.1:\(port)"
    wire_api = "responses"
    \(codeMode ? "\n[features]\ncode_mode = true\n" : "")
    """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    var env = isolatedEnvironment
    env["CODEX_HOME"] = home.path
    var events: [StreamEvent] = []
    if appServer {
        guard let conversation = AppServerConversation(codex: codex, cwd: cwd, env: env) else { return nil }
        defer { conversation.close() }
        _ = conversation.request("initialize", CodexAppServer.initializeParams(clientVersion: "1.0"))
        conversation.notify("initialized")
        let permissions = CodexAppServer.Permissions(approvalPolicy: "never", approvalsReviewer: nil,
                                                     profile: nil, sandbox: "workspace-write")
        let started = conversation.request("thread/start",
                                           CodexAppServer.threadStartParams(cwd: cwd.path, stating: permissions))
        guard let thread = ((started?["result"] as? [String: Any])?["thread"] as? [String: Any])?["id"] as? String
        else { return nil }
        _ = conversation.request("turn/start", ["threadId": thread, "cwd": cwd.path, "approvalPolicy": "never",
                                                "input": [["type": "text", "text": "TOOLPROBE go"]]])
        _ = conversation.wait(limit: 60) { ($0["method"] as? String) == "turn/completed" }
        for message in conversation.received {
            guard let method = message["method"] as? String, let params = message["params"] as? [String: Any]
            else { continue }
            for object in CodexAppServer.execEvents(method: method, params: params) {
                events += CodexEventParser.parse(object: object, fallbackCwd: cwd).events
            }
        }
    } else {
        let lines = runToEnd(codex, ["exec", "--json", "--skip-git-repo-check",
                                     "-c", "sandbox_mode=\"workspace-write\"", "-c", "approval_policy=\"never\"",
                                     "TOOLPROBE go"], cwd: cwd, env: env, limit: 60)
        events = lines.flatMap { CodexEventParser.parse(line: $0, fallbackCwd: cwd).events }
    }
    guard let rollout = files(startingWith: "rollout-", under: home.appendingPathComponent("sessions")).first
    else { return (toolChips(chips(events)), []) }
    return (toolChips(chips(events)), toolChips(chips(CodexSessionScanner.readHistory(of: rollout, maxTurns: 50))))
}

let codexBinary = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
    .map { "\($0)/codex" }.first { FileManager.default.isExecutableFile(atPath: $0) }
if let codexBinary, FileManager.default.fileExists(atPath: fakeServerPath) {
    for codeMode in [false, true] {
        let mode = codeMode ? "code mode" : "direct calls"
        if let run = runCodex(codexBinary, codeMode: codeMode, appServer: true) {
            let files = run.live.first { $0.hasPrefix("Update|") } ?? ""
            check("6a. codex app-server, \(mode): the file change names its three files with their diffs",
                  ["made.txt", "seed.txt", "gone.txt", "+hello", "-old", "+new", "-bye"].allSatisfy(files.contains),
                  "\(run.live)")
            check("…the command reads as one, its output below it", run.live.contains("Shell|echo hello|$ echo hello|hello"),
                  "\(run.live)")
            check("…the image it viewed reads \"Viewed image\" and its file",
                  run.live.contains { $0.hasPrefix("Viewed image|") && $0.contains("dot.png") }, "\(run.live)")
            check("…and reopened, every row is the row the turn drew", run.live == run.reopened,
                  "live \(run.live)\nreopened \(run.reopened)")
        } else {
            skip("6a. codex app-server, \(mode)", "the stand-in or codex did not start")
        }
        if let run = runCodex(codexBinary, codeMode: codeMode, appServer: false) {
            // `codex exec` prints no item for an image view; its record is
            // all there is of it.
            let viewed = run.reopened.filter { $0.hasPrefix("Viewed image|") }
            check("6b. codex exec, \(mode): reopened, the same rows in the same places — the record adds the diffs",
                  !run.live.isEmpty && heads(run.live) == heads(run.reopened.filter { !viewed.contains($0) })
                    && run.reopened.contains("Shell|echo hello|$ echo hello|hello"),
                  "live \(run.live)\nreopened \(run.reopened)")
            check("…and the image it viewed, which exec prints nothing for, reopens from its record",
                  viewed.count == 1 && viewed[0].contains("dot.png") && !run.live.contains { $0.contains("dot.png") },
                  "live \(run.live)\nreopened \(run.reopened)")
        } else {
            skip("6b. codex exec, \(mode)", "the stand-in or codex did not start")
        }
    }
} else {
    skip("6a–6b. the installed codex", codexBinary == nil ? "codex is not on PATH" : "no stand-in endpoint")
}

let kimiBinary = (("~/.kimi-code/bin/kimi" as NSString).expandingTildeInPath as NSString).resolvingSymlinksInPath
if FileManager.default.isExecutableFile(atPath: kimiBinary), FileManager.default.fileExists(atPath: fakeServerPath) {
    let dir = scratchFolder("kimi")
    let home = dir.appendingPathComponent("home"), cwd = dir.appendingPathComponent("cwd")
    for folder in [home, cwd] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    try? "alpha\nbeta\n".write(to: cwd.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try? onePixelPNG.write(to: cwd.appendingPathComponent("dot.png"))
    let script: [[String: Any]] = [["marker": "TOOLPROBE", "steps": [
        ["tool_calls": [["id": "k1", "name": "Bash", "arguments": ["command": "echo partial; exit 3"]]]],
        ["tool_calls": [["id": "k2", "name": "Read",
                         "arguments": ["path": cwd.appendingPathComponent("notes.txt").path]]]],
        ["tool_calls": [["id": "k3", "name": "ReadMediaFile",
                         "arguments": ["path": cwd.appendingPathComponent("dot.png").path]]]],
        ["text": "DONE"]]]]
    if let (server, port) = startStandIn(fakeServerPath, flag: "--chat-script", script: script, in: dir) {
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
        var env = isolatedEnvironment
        env["KIMI_CODE_HOME"] = home.path
        let stdout = runToEnd(kimiBinary, ["--prompt", "TOOLPROBE go", "--output-format", "stream-json"],
                              cwd: cwd, env: env, limit: 90)
        server.terminate()
        let wire = files(startingWith: "wire.jsonl", under: home.appendingPathComponent("sessions"))
            .first { $0.deletingLastPathComponent().lastPathComponent == "main" }
        let records = ((wire.flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? "")
            .split(separator: "\n").compactMap { jsonObject(String($0)) }
        let reopened = wire.map { toolChips(chips(KimiSessionScanner.readHistory(of: $0, maxTurns: 50))) } ?? []
        let printed = chips(stdout.flatMap { KimiEventParser.parse(line: $0, fallbackCwd: cwd) })
        let live = chips(kimiLive(stdout, records: records, recordFirst: false))
        check("6c. kimi: a failed command, a file read and an image read, live as the record ends them, are the reopened rows",
              reopened.count == 3 && live == reopened && chips(kimiLive(stdout, records: records, recordFirst: true)) == reopened,
              "live \(live)\nreopened \(reopened)")
        check("…the failure flagged, the file named, the image as its text and never its data",
              live.contains { $0.hasPrefix("Bash|") && $0.contains("|⚠") }
                && live.contains { $0.hasPrefix("Read|\(cwd.appendingPathComponent("notes.txt").path)") }
                && live.contains { $0.hasPrefix("ReadMediaFile|") && $0.contains("<image") }
                && !live.contains { $0.contains("base64") },
              "\(live)")
        if printed == reopened {
            print("  note kimi's stdout now says what its record says — reading the record is no longer needed")
        }
    } else {
        skip("6c. the installed kimi", "the stand-in endpoint did not start")
    }
    try? FileManager.default.removeItem(at: dir)
} else {
    skip("6c. the installed kimi", "kimi is not installed at ~/.kimi-code/bin/kimi")
}

print("")
print("passed \(passed), failed \(failed), skipped \(skipped)")
exit(failed == 0 ? 0 : 1)
