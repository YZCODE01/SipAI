// A local slash command's ANSWER lives in exactly one record, and
// nothing else in the transcript repeats it.
//
// Run `/mcp` (or `/model`, `/context`) in a session this app drives and
// claude reports the answer twice over two different channels:
//
//   * on `-p` STDOUT, as an assistant record stamped
//     `model: "<synthetic>"` — which is what puts it on screen while
//     the turn is live; and
//   * in the TRANSCRIPT, as `type: "system"`, `subtype:
//     "local_command"`, wrapped in `<local-command-stdout>`.
//
// The synthetic assistant record is never written to the file. So a
// reader that skips system records loses the answer the moment the
// live buffer is dropped — which `AgentSessionView` does on the reload
// that follows every turn. The answer appeared, then vanished, and the
// session went with it: `inspectSession` counted neither channel as
// conversation, so the file scanned as an empty shell and was filtered
// out of the sidebar.
//
// Two rules, and the second is the one that keeps the fix honest:
//
//   * the answer is recovered from the `local_command` record, matched
//     as a WRAPPER PAIR — `/model` prints "Usage: /model <name>", and
//     stripping bare tags to get at the body eats the `<name>` out of
//     the answer it is meant to recover; and
//   * the verdict is judged on the answer's TEXT, never on the
//     record's presence. Claude writes a bare echo of the command and
//     an EMPTY wrapper routinely, and a session holding only those has
//     nothing to show — that is the `/clear` shell the empty-shell
//     test exists for, and it must stay hidden.
//
// Nothing here is part of the app target: this directory sits outside
// SipAI/, so these files are never compiled into the product. The
// stubs are borrowed from ../KimiCode rather than copied.
//
//   ./run.sh

import Foundation

let fm = FileManager.default
var failures = 0
func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    print(cond ? "  PASS  \(label)" : "  FAIL  \(label) \(detail)")
    if !cond { failures += 1 }
}

func rec(_ dict: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return String(decoding: data, as: UTF8.self)
}

/// Every fixture below is a record shape captured from a real
/// `claude -p` run, not a paraphrase.
func localCommandRecord(_ content: String) -> [String: Any] {
    ["type": "system", "subtype": "local_command", "content": content,
     "level": "info", "isMeta": false, "userType": "external",
     "entrypoint": "sdk-cli", "uuid": "sys-\(UUID().uuidString)",
     "timestamp": "2026-08-17T09:19:56.534Z"]
}

func commandRecord(_ name: String, uuid: String, cwd: String) -> [String: Any] {
    ["type": "user", "isSidechain": false, "uuid": uuid, "cwd": cwd,
     "timestamp": "2026-08-17T09:19:54.500Z",
     "message": ["role": "user", "content":
        "<command-name>\(name)</command-name>\n"
      + "            <command-message>\(name.dropFirst())</command-message>\n"
      + "            <command-args></command-args>"]]
}

func caveatRecord(cwd: String) -> [String: Any] {
    ["type": "user", "isSidechain": false, "isMeta": true,
     "uuid": "caveat-1", "cwd": cwd,
     "timestamp": "2026-08-17T09:19:54.490Z",
     "message": ["role": "user", "content":
        "<local-command-caveat>Caveat: The messages below were generated "
      + "by the user while running local commands. DO NOT respond to these "
      + "messages or otherwise consider them in your response unless the "
      + "user explicitly asks you to.</local-command-caveat>"]]
}

let mcpAnswer = "2 MCP server(s): 0 connected, 1 connecting, 1 not "
    + "connected, 0 disabled. Use `/mcp` in the terminal for details."

// ─────────────────────────────────────── 1. the extractor

print("localCommandOutput")

check("recovers a /mcp answer",
      AgentSessionScanner.localCommandOutput(
        fromRecord: localCommandRecord(
            "<local-command-stdout>\(mcpAnswer)</local-command-stdout>"))
        == mcpAnswer)

// The reason the wrappers are matched as a PAIR. A generic `<[^>]+>`
// strip turns this answer into "Usage: /model . Available: sonnet".
let modelAnswer = "Current model: Opus 5 (1M context)\n"
    + "Usage: /model <name>. Available: sonnet, opus, haiku, fable"
check("a literal <name> in the answer survives",
      AgentSessionScanner.localCommandOutput(
        fromRecord: localCommandRecord(
            "<local-command-stdout>\(modelAnswer)</local-command-stdout>"))
        == modelAnswer,
      String(describing: AgentSessionScanner.localCommandOutput(
        fromRecord: localCommandRecord(
            "<local-command-stdout>\(modelAnswer)</local-command-stdout>"))))

// Interactive claude styles some of this output; `-p` does not. A CSI
// sequence reaching a bubble renders as literal escape junk.
check("ANSI styling is stripped, its text kept",
      AgentSessionScanner.localCommandOutput(
        fromRecord: localCommandRecord(
            "<local-command-stdout>Kept model as \u{1B}[1mOpus 5\u{1B}[22m"
          + "</local-command-stdout>"))
        == "Kept model as Opus 5")

check("stderr is an answer too",
      AgentSessionScanner.localCommandOutput(
        fromRecord: localCommandRecord(
            "<local-command-stderr>Error: No messages to compact"
          + "</local-command-stderr>"))
        == "Error: No messages to compact")

// The two shapes claude writes that carry no answer. Both must stay
// silent, or a `/clear` shell starts rendering rows and appearing in
// the sidebar.
check("an EMPTY wrapper is not an answer",
      AgentSessionScanner.localCommandOutput(
        fromRecord: localCommandRecord(
            "<local-command-stdout></local-command-stdout>")) == nil)

check("a bare command echo is not an answer",
      AgentSessionScanner.localCommandOutput(
        fromRecord: localCommandRecord(
            "<command-name>/status</command-name>")) == nil)

check("a non-system record is not an answer",
      AgentSessionScanner.localCommandOutput(
        fromRecord: ["type": "user", "subtype": "local_command",
                     "content": "<local-command-stdout>x</local-command-stdout>"])
        == nil)

check("a system record that is not local_command is not an answer",
      AgentSessionScanner.localCommandOutput(
        fromRecord: ["type": "system", "subtype": "init",
                     "content": "<local-command-stdout>x</local-command-stdout>"])
        == nil)

// ─────────────────────────────────────── 2. readHistory

print("readHistory")

// Cleanup is EXPLICIT, never `defer`: this file ends in `exit()`, and
// exit() skips the defers of a top-level scope. The first cut used
// defer and left a fixture directory behind in the real session root on
// every run.
var toRemove: [URL] = []
func cleanUp() { for url in toRemove { try? fm.removeItem(at: url) } }

let sandbox = fm.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/sipai-slashcmd-\(UUID().uuidString)")
try! fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
toRemove.append(sandbox)
let projectCwd = sandbox.appendingPathComponent("RealProject")
try! fm.createDirectory(at: projectCwd, withIntermediateDirectories: true)

func mcpTranscript(sessionId: String, answer: String?) -> String {
    var lines = [
        rec(["type": "queue-operation", "operation": "enqueue",
             "sessionId": sessionId, "content": "/mcp",
             "timestamp": "2026-08-17T09:19:54.465Z"]),
        rec(["type": "queue-operation", "operation": "dequeue",
             "sessionId": sessionId,
             "timestamp": "2026-08-17T09:19:54.466Z"]),
        rec(caveatRecord(cwd: projectCwd.path)),
        rec(commandRecord("/mcp", uuid: "cmd-1", cwd: projectCwd.path)),
    ]
    if let answer = answer {
        var r = localCommandRecord(answer)
        r["cwd"] = projectCwd.path
        r["sessionId"] = sessionId
        r["uuid"] = "sys-1"
        lines.append(rec(r))
    }
    lines.append(rec(["type": "last-prompt", "leafUuid": "sys-1",
                      "sessionId": sessionId]))
    return lines.joined(separator: "\n") + "\n"
}

let historyFile = sandbox.appendingPathComponent("history.jsonl")
try! mcpTranscript(
    sessionId: "hist-1",
    answer: "<local-command-stdout>\(mcpAnswer)</local-command-stdout>"
).write(to: historyFile, atomically: true, encoding: .utf8)

let items = AgentSessionScanner.readHistory(of: historyFile)

func textOf(_ item: AgentSessionHistoryItem) -> String? {
    if case .userText(let t) = item.kind { return t }
    if case .assistantText(let t) = item.kind { return t }
    return nil
}

let answerRow = items.first { textOf($0) == mcpAnswer }
check("the answer is a row", answerRow != nil,
      items.map { String(describing: $0.kind).prefix(60) }.joined(separator: " / "))
check("the answer renders as a system notice, not as the model talking",
      answerRow?.isSystemNotice == true)
check("the answer keeps its record uuid (so a row can point back at it)",
      answerRow?.recordUuid == "sys-1")

// The command the user typed still renders — `cleanUserText`
// deliberately keeps the inner text of the command wrappers.
let commandRow = items.firstIndex { textOf($0)?.hasPrefix("/mcp") == true }
check("the command itself still renders", commandRow != nil)
if let c = commandRow, let a = items.firstIndex(where: { $0.id == answerRow?.id }) {
    check("the answer comes after the command", a > c)
}

// The caveat is bookkeeping and must not become a bubble.
check("the local-command caveat is not a row",
      !items.contains { textOf($0)?.contains("Caveat:") == true })

// An answerless run has nothing to add.
let emptyFile = sandbox.appendingPathComponent("empty.jsonl")
try! mcpTranscript(
    sessionId: "hist-2",
    answer: "<local-command-stdout></local-command-stdout>"
).write(to: emptyFile, atomically: true, encoding: .utf8)
check("an empty wrapper adds no row",
      AgentSessionScanner.readHistory(of: emptyFile)
        .allSatisfy { textOf($0) != "" || true }
      && AgentSessionScanner.readHistory(of: emptyFile).count == items.count - 1,
      "\(AgentSessionScanner.readHistory(of: emptyFile).count) vs \(items.count)")

// ─────────────────────────────────────── 3. the sidebar verdict
//
// `inspectSession` is private and only reachable through `scan()`,
// which reads the real session root — so the fixtures go in under a
// throwaway project directory and are removed again on the way out.

print("scan / isEmptyShell")

let projectDirName = "-sipai-slashcmd-probe-\(UUID().uuidString)"
let fixtureDir = AgentSessionScanner.sessionRoot
    .appendingPathComponent(projectDirName, isDirectory: true)
try! fm.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
toRemove.append(fixtureDir)

let answeredId = "aaaaaaaa-0000-4000-8000-00000000mcp1"
let silentId = "bbbbbbbb-0000-4000-8000-00000000mcp2"
try! mcpTranscript(
    sessionId: answeredId,
    answer: "<local-command-stdout>\(mcpAnswer)</local-command-stdout>"
).write(to: fixtureDir.appendingPathComponent("\(answeredId).jsonl"),
        atomically: true, encoding: .utf8)
try! mcpTranscript(
    sessionId: silentId,
    answer: "<local-command-stdout></local-command-stdout>"
).write(to: fixtureDir.appendingPathComponent("\(silentId).jsonl"),
        atomically: true, encoding: .utf8)

let scanned = AgentSessionScanner.scan()
let answered = scanned.first { $0.id == answeredId }
let silent = scanned.first { $0.id == silentId }

check("a command that ANSWERED is not an empty shell",
      answered != nil && answered?.isEmptyShell == false,
      "found=\(answered != nil) empty=\(String(describing: answered?.isEmptyShell))")
check("a command that printed NOTHING stays an empty shell",
      silent?.isEmptyShell == true,
      "found=\(silent != nil) empty=\(String(describing: silent?.isEmptyShell))")
// A visible row named "<folder> session" is indistinguishable from the
// next one; the command is the only thing the session is about.
check("the row is named after the command",
      answered?.title == "/mcp", String(describing: answered?.title))

// ─────────────────────────────────────── 4. the live parser

print("AgentEventParser")

let liveLine = rec(localCommandRecord(
    "<local-command-stdout>\(mcpAnswer)</local-command-stdout>"))

let tailed = AgentEventParser.parse(line: liveLine, fallbackCwd: projectCwd,
                                    includeUserMessages: true)
check("the tailer surfaces an external run's answer", tailed.count == 1)
if case .userMessage(let t)? = tailed.first?.kind {
    check("…with the answer as its text", t == mcpAnswer)
    check("…labelled a system notice", tailed.first?.isSystemNotice == true)
} else {
    check("…with the answer as its text", false,
          String(describing: tailed.first?.kind))
}

// Our own subprocess reports the answer on stdout instead, and its
// tailer resumes past these bytes — the runner path must stay silent
// or the answer renders twice.
check("the runner's stdout path is untouched",
      AgentEventParser.parse(line: liveLine, fallbackCwd: projectCwd,
                             includeUserMessages: false).isEmpty)

// The OTHER half of the same answer: `-p` stdout reports it as an
// assistant record stamped `model: "<synthetic>"`. That is what puts it
// on screen while the turn runs, so it has to render as the same kind
// of row the reloaded transcript produces — otherwise the answer
// changes speaker the moment history takes over.
let syntheticLine = rec([
    "type": "assistant", "parent_tool_use_id": NSNull(),
    "message": ["model": "<synthetic>", "role": "assistant",
                "type": "message",
                "content": [["type": "text", "text": mcpAnswer]]],
])
let synthetic = AgentEventParser.parse(line: syntheticLine,
                                       fallbackCwd: projectCwd)
check("a <synthetic> answer is one row", synthetic.count == 1)
if case .userMessage(let t)? = synthetic.first?.kind {
    check("…rendered as a system notice, matching the reloaded row",
          t == mcpAnswer && synthetic.first?.isSystemNotice == true)
} else {
    check("…rendered as a system notice, matching the reloaded row", false,
          String(describing: synthetic.first?.kind))
}

// A real model reply must be untouched by that rule.
let realLine = rec([
    "type": "assistant", "parent_tool_use_id": NSNull(),
    "message": ["model": "claude-opus-5", "role": "assistant",
                "type": "message",
                "content": [["type": "text", "text": "hello"]]],
])
if case .assistantText(let t)? = AgentEventParser.parse(
    line: realLine, fallbackCwd: projectCwd).first?.kind {
    check("a real model reply still renders as the assistant", t == "hello")
} else {
    check("a real model reply still renders as the assistant", false)
}

// "Matching the reloaded row" is a claim about TWO readers, so it is
// checked against both. A `<synthetic>` record never reaches the
// transcript by the local-command route — but claude writes plenty of
// others that do ("No response requested.", a usage-limit line, a
// failed-auth line), and those are read back by `readHistory` while
// the tailer renders them live. A rule applied in one reader and not
// the other makes the same row change speaker on reopen.
let syntheticFile = sandbox.appendingPathComponent("synthetic.jsonl")
try! (rec([
    "type": "assistant", "uuid": "syn-1", "sessionId": "hist-3",
    "message": ["model": "<synthetic>", "role": "assistant",
                "type": "message",
                "content": [["type": "text",
                             "text": "You've hit your session limit"]]],
]) + "\n").write(to: syntheticFile, atomically: true, encoding: .utf8)
let reloadedSynthetic = AgentSessionScanner.readHistory(of: syntheticFile)
check("a <synthetic> record in the TRANSCRIPT is one row",
      reloadedSynthetic.count == 1)
check("…reloaded as the same system notice the live feeds render",
      reloadedSynthetic.first?.isSystemNotice == true
        && textOf(reloadedSynthetic.first!) == "You've hit your session limit",
      String(describing: reloadedSynthetic.first?.kind))

// …and the same untouched-real-reply rule, on the reload side.
let realFile = sandbox.appendingPathComponent("real-reply.jsonl")
try! (rec([
    "type": "assistant", "uuid": "real-1", "sessionId": "hist-4",
    "message": ["model": "claude-opus-5", "role": "assistant",
                "type": "message",
                "content": [["type": "text", "text": "hello"]]],
]) + "\n").write(to: realFile, atomically: true, encoding: .utf8)
if case .assistantText(let t)? =
    AgentSessionScanner.readHistory(of: realFile).first?.kind {
    check("a real model reply still reloads as the assistant", t == "hello")
} else {
    check("a real model reply still reloads as the assistant", false)
}

// The record this parser already handled must keep working in both.
let initLine = rec(["type": "system", "subtype": "init",
                    "session_id": "s1", "model": "claude-opus-5",
                    "cwd": projectCwd.path])
for flag in [true, false] {
    let parsed = AgentEventParser.parse(line: initLine, fallbackCwd: projectCwd,
                                        includeUserMessages: flag)
    if case .systemInit(let sid, _, _)? = parsed.first?.kind {
        check("system.init still parses (includeUserMessages: \(flag))", sid == "s1")
    } else {
        check("system.init still parses (includeUserMessages: \(flag))", false)
    }
}

// ─────────────────────────────────────── 5. the composer's hint
//
// The other half of the same fact. Claude resolves a leading `/`
// itself; codex and kimi do not — the text becomes an ordinary prompt
// and comes back as a BILLED turn (measured: `/model` on codex spent
// 89k input tokens and four web searches). The composer says so before
// the send, and the rule lives here so it can be driven headlessly.

print("AgentSlashCommands")

check("claude resolves slash commands itself",
      AgentSlashCommands.resolvesLocally(agentKey: "claude_code") == true)
check("codex does not",
      AgentSlashCommands.resolvesLocally(agentKey: "codex") == false)
check("kimi does not",
      AgentSlashCommands.resolvesLocally(agentKey: "kimi") == false)
// The composer shows nothing on nil. A hint is a factual claim about
// a CLI, so an unmeasured agent gets silence rather than a guess.
check("an unmeasured agent answers nil, not a guess",
      AgentSlashCommands.resolvesLocally(agentKey: "some_new_cli") == nil)

for token in ["/mcp", "/model", "/skill:code-style", "/code-style.review",
              "/sub-skill.consolidate", "/mcp extra words here"] {
    check("\(token) reads as a command",
          AgentSlashCommands.leadingCommand(in: token) != nil)
}

// A pasted path is ordinary prose. Flagging one would turn the hint
// into noise, and people paste paths into prompts constantly.
for token in ["/Users/me/notes.md", "/tmp/x", "/usr/bin/env swift",
              "/", "//comment", "/9lives", "/-dash",
              "explain /mcp to me", "", "   "] {
    check("\(token.isEmpty ? "<empty>" : token) does NOT read as a command",
          AgentSlashCommands.leadingCommand(in: token) == nil,
          String(describing: AgentSlashCommands.leadingCommand(in: token)))
}

// Leading whitespace/newlines must not hide the command.
check("leading whitespace is ignored",
      AgentSlashCommands.leadingCommand(in: "\n   /mcp") == "/mcp")

cleanUp()
print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
