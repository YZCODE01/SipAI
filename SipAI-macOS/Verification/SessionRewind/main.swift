// Headless verification that SipAI reads a session the way its own CLI
// replays it after a rewind. See run.sh.
//
// Not part of the app target — this directory sits outside SipAI/.
//
//   rules                      the readers and writers over synthetic
//                              stores in each CLI's measured shape, and
//                              what an edit in place asks each tool
//   wiring <source root>       the edit in place, read off the sources
//   read <agent> <file> [root] the user messages SipAI draws, as JSON
//   fork-claude <file> <uuid>  SipAI's claude branch cut at a record
//   cut-claude <file> <text> <skip>   the record a live row resolves to
//   handle <agent> <file> <text>      the record handle the newest history
//                              row with those words carries
//   names-flag <binary>        whether the executable names claude's flag
//   anchor-claude <file> <uuid|-> <text> <skip>    the entry an edit resumes at
//   revert-codex <binary> <rollout> <thread> <uuid|-> <text> <skip>
//                              the turn the edit cuts before, and codex's revert
//   revert-codex-at <binary> <thread> <turn>       codex's revert, as asked
//   undo-kimi <wire> <session> <uuid|-> <text> <skip>
//                              the turns kimi's undo takes back, and its route
//   kimi-answer <file>         kimi's answer to the undo, as SipAI reads it
//   claude-stdin <skill> <text>       what a claude turn that loads a chosen
//                              skill writes to claude's stdin

import Foundation

var failures = 0
var checks = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    checks += 1
    print((ok ? "  ok   " : "  FAIL ") + label + (detail.isEmpty ? "" : " — \(detail)"))
    if !ok { failures += 1 }
}

let fm = FileManager.default
let args = Array(CommandLine.arguments.dropFirst())

/// The user's own messages as SipAI draws them, in order — what a rewind
/// has to leave exactly as the CLI replays it.
func said(_ items: [AgentSessionHistoryItem]) -> [String] {
    items.compactMap { item in
        if case .userText(let text) = item.kind, !item.isSystemNotice { return text }
        return nil
    }
}

func json(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "null" }
    return text
}

func write(_ lines: [[String: Any]], to url: URL) {
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let text = lines.map(json).joined(separator: "\n") + "\n"
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

/// A `ForkError` or a refusal by name, for the helpers and the rules.
func errorName(_ error: Error) -> String {
    if let fork = error as? AgentSessionFork.ForkError {
        switch fork {
        case .nothingToBranch: return "nothingToBranch"
        case .cutPointNotFound: return "cutPointNotFound"
        case .agentUnavailable: return "agentUnavailable"
        case .agentNotSupported: return "agentNotSupported"
        case .unreadableSource: return "unreadableSource"
        case .writeFailed(let detail): return "writeFailed: " + detail
        }
    }
    if let rewind = error as? AgentSessionRewind.RewindError, case .refused(let words) = rewind {
        return "refused: " + words
    }
    return "\(error)"
}

/// Wait for async work from top-level code.
func waitFor<T>(_ work: @escaping () async -> T) -> T {
    let group = DispatchGroup()
    group.enter()
    var result: T? = nil
    Task {
        result = await work()
        group.leave()
    }
    group.wait()
    return result!
}

func describe(_ outcome: AgentSessionRewind.CodexOutcome) -> [String: Any] {
    switch outcome {
    case .reverted(let url): return ["reverted": url.path]
    case .refused(let words): return ["refused": words]
    case .unsupported: return ["unsupported": true]
    case .unavailable: return ["unavailable": true]
    }
}

// MARK: - Helper commands for live.py

if args.first == "handle", args.count == 4 {
    let file = URL(fileURLWithPath: args[2])
    let items: [AgentSessionHistoryItem]
    switch args[1] {
    case "codex": items = CodexSessionScanner.readHistory(of: file)
    case "kimi": items = KimiSessionScanner.readHistory(of: file)
    default: items = AgentSessionScanner.readHistory(of: file)
    }
    let row = items.last { item in
        if case .userText(let text) = item.kind, !item.isSystemNotice {
            return text.trimmingCharacters(in: .whitespacesAndNewlines) == args[3]
        }
        return false
    }
    print(json(["handle": row?.recordUuid.map { $0 as Any } ?? NSNull()]))
    exit(0)
}

if args.first == "names-flag", args.count == 2 {
    let named = ClaudeCapabilities.executable(args[1], names: ClaudeCapabilities.resumeSessionAtFlag)
    print(json(["names": named.map { $0 as Any } ?? NSNull()]))
    exit(0)
}

if args.first == "anchor-claude", args.count == 5 {
    do {
        let entry = try AgentSessionRewind.claudeResumeEntry(
            recordUuid: args[2] == "-" ? nil : args[2], in: URL(fileURLWithPath: args[1]),
            originalText: args[3], skippingNewer: Int(args[4]) ?? 0)
        print(json(["entry": entry]))
    } catch {
        print(json(["error": errorName(error)]))
    }
    exit(0)
}

if args.first == "revert-codex", args.count == 7 {
    let rollout = URL(fileURLWithPath: args[2])
    do {
        let turn = try AgentSessionRewind.codexRevertTurn(
            recordUuid: args[4] == "-" ? nil : args[4], in: rollout,
            originalText: args[5], skippingNewer: Int(args[6]) ?? 0)
        let binary = args[1], thread = args[3]
        var answer = describe(waitFor {
            await AgentSessionRewind.revertCodex(threadId: thread, beforeTurnId: turn, binary: binary)
        })
        answer["turn"] = turn
        // The file the reader takes for the thread afterwards.
        answer["current"] = CodexSessionScanner.rolloutFile(namedForId: thread)?.path ?? NSNull()
        print(json(answer))
    } catch {
        print(json(["error": errorName(error)]))
    }
    exit(0)
}

if args.first == "revert-codex-at", args.count == 4 {
    let binary = args[1], thread = args[2], turn = args[3]
    print(json(describe(waitFor {
        await AgentSessionRewind.revertCodex(threadId: thread, beforeTurnId: turn, binary: binary)
    })))
    exit(0)
}

if args.first == "undo-kimi", args.count == 6 {
    do {
        let target = try AgentSessionRewind.kimiUndoTarget(
            recordUuid: args[3] == "-" ? nil : args[3], in: URL(fileURLWithPath: args[1]),
            originalText: args[4], skippingNewer: Int(args[5]) ?? 0)
        print(json(["count": target.count, "message": target.messageId,
                    "path": AgentSessionRewind.kimiUndoPath(sessionId: args[2]).map { $0 as Any } ?? NSNull(),
                    "turns": AgentSessionRewind.kimiTurnsPath(sessionId: args[2]).map { $0 as Any } ?? NSNull()]))
    } catch {
        print(json(["error": errorName(error)]))
    }
    exit(0)
}

if args.first == "kimi-names-turn", args.count == 2 {
    print(json(["namesTurn": AgentSessionRewind.kimiUndoNamesTurn(kimiVersion: args[1])]))
    exit(0)
}

if args.first == "kimi-turn", args.count == 3 {
    let data = (try? Data(contentsOf: URL(fileURLWithPath: args[1]))) ?? Data()
    guard let page = AgentSessionRewind.kimiTurnsPage(from: data, messageId: args[2]) else {
        print(json(["unread": true]))
        exit(0)
    }
    print(json(["turnId": page.turnId.map { $0 as Any } ?? NSNull(), "hasMore": page.hasMore,
                "oldest": page.oldestOrdinal.map { $0 as Any } ?? NSNull()]))
    exit(0)
}

if args.first == "claude-stdin", args.count == 3 {
    print(SkillWire.claudeStdinLines(skills: [args[1]], text: args[2]), terminator: "")
    exit(0)
}

if args.first == "kimi-hand-back", args.count == 2 {
    let wire = URL(fileURLWithPath: args[1])
    let restored = KimiRuntimeBinding.restore(wire: wire)
    let newest = KimiRuntimeBinding.bindings((try? String(contentsOf: wire, encoding: .utf8)) ?? "").last
    print(json(["restored": restored, "bound": (newest?["environmentId"] ?? newest?["runtimeId"]) ?? NSNull()]))
    exit(0)
}

if args.first == "kimi-answer", args.count == 2 {
    let data = (try? Data(contentsOf: URL(fileURLWithPath: args[1]))) ?? Data()
    switch AgentSessionRewind.kimiUndoOutcome(from: data) {
    case .undone: print(json(["undone": true]))
    case .refused(let words): print(json(["refused": words]))
    }
    exit(0)
}

// MARK: - Wiring

if args.first == "wiring", args.count == 2 {
    let src = URL(fileURLWithPath: args[1], isDirectory: true)
    func source(_ rel: String) -> String {
        (try? String(contentsOf: src.appendingPathComponent(rel), encoding: .utf8)) ?? ""
    }
    /// The brace block that opens at the first `head` after `from`.
    func block(_ text: String, _ head: String, after from: String? = nil) -> String {
        var start = text.startIndex
        if let from, let r = text.range(of: from) { start = r.upperBound }
        guard let h = text.range(of: head, range: start..<text.endIndex),
              let open = text[h.lowerBound...].firstIndex(of: "{") else { return "" }
        var depth = 0
        var i = open
        while i < text.endIndex {
            if text[i] == "{" { depth += 1 }
            if text[i] == "}" { depth -= 1; if depth == 0 { return String(text[h.lowerBound...i]) } }
            i = text.index(after: i)
        }
        return ""
    }
    /// The text from the first `from` after `after` to the `to` that ends it.
    func span(_ text: String, from: String, to: String, after: String) -> String {
        guard let a = text.range(of: after),
              let f = text.range(of: from, range: a.upperBound..<text.endIndex),
              let t = text.range(of: to, range: f.upperBound..<text.endIndex) else { return "" }
        return String(text[f.lowerBound..<t.upperBound])
    }
    func ordered(_ text: String, _ parts: [String]) -> Bool {
        var at = text.startIndex
        for part in parts {
            guard let r = text.range(of: part, range: at..<text.endIndex) else { return false }
            at = r.upperBound
        }
        return true
    }
    print("8. Send in place, read off the sources")

    let runner = source("SipAI/Models/AgentRunner.swift")
    let resume = block(runner, "if let id = sessionId, !id.isEmpty {", after: "private func claudeArguments(")
    check("claude's argv: the edit's entry goes beside --resume, and only when the send names one",
          ordered(resume, ["args.append(\"--resume\")", "args.append(id)",
                           "if let entry = options.claudeResumeAt, !entry.isEmpty {",
                           "[ClaudeCapabilities.resumeSessionAtFlag, entry]"]))
    let runOnce = block(runner, "private func runOnce(text: String, options: AgentLaunchOptions,")
    check("a re-send after a too-long refusal does not go back a second time",
          ordered(runOnce, ["if tooLongResendPending {", "var again = options",
                            "again.claudeResumeAt = nil",
                            "await runOnce(text: text, options: again, images: images)"]))
    check("a reverted codex thread's runner moves to the new rollout",
          ordered(block(runner, "func adoptRewoundRollout(_ url: URL)"),
                  ["sessionFileURL = url", "startTailer(at: url"]))

    let options = source("SipAI/Models/AgentLaunchOptions.swift")
    check("the installed claude is read for the flag, beside its other tables",
          ordered(block(options, "func ensureLoaded()", after: "final class ClaudeCapabilities"),
                  ["Self.executable(binary, names: Self.resumeSessionAtFlag)",
                   "self.namesResumeSessionAt = resumeAt"]))
    check("the entry is never saved with a session's picks",
          !source("SipAI/Models/ConfigManager.swift").contains("claudeResumeAt")
          && !options.contains("claude_resume_at"))

    let view = source("SipAI/Views/Chat/AgentSessionView.swift")
    let edit = block(view, "private func editSessionInPlace(")
    check("the session's Send goes through the agent's own call before anything is cut or sent",
          ordered(edit, ["case \"codex\":", "try await revertCodex(", "runner.adoptRewoundRollout(file)",
                         "agents.reloadSessions()", "case \"kimi\":", "try await undoKimi(",
                         "case \"claude_code\":", "resumeAt = try await claudeEntry(",
                         "historyCache.forget(sessionId)", "cutTranscript(at: rowId)",
                         "sending.claudeResumeAt = resumeAt", "runner.send(text: text, options: sending)"]))
    check("…a first message starts a new session, as Create Branch does",
          ordered(edit, ["catch AgentSessionFork.ForkError.nothingToBranch",
                         "startBranchAsNewSession(cwd: cwd, text: text, customGroup: customGroup)"]))
    check("…and only for an installed tool that can, with no turn running",
          edit.contains("rewindSupport == .offered") && edit.contains("canBranch")
          && edit.contains("!sendIsHeld"))
    // The view outlives a switch to another session: read after codex's or
    // kimi's call, the chips would be the session on screen by then.
    let afterCall = edit.range(of: "Task { @MainActor in").map { String(edit[$0.upperBound...]) } ?? ""
    check("…with the chips of the session it was made in, read before the agent's own call",
          ordered(edit, ["sendOptions", "skillTriggers(for: text", "Task { @MainActor in"])
          && !afterCall.isEmpty && !afterCall.contains("sendOptions")
          && !afterCall.contains("skillTriggers("))
    // While the cut is being made, a message from the composer (or the
    // plan card's) would run on the session the cut is being made in.
    check("…and nothing else is sent into the session while the editor's work runs",
          block(view, "private func handleSend() {").contains("if branching { return }")
          && block(view, "private func implementProposedPlan(").contains("!branching"))
    check("…a live row of attached files alone is found by its files, read before the agent's own call",
          ordered(edit, ["let attachedFiles = recordUuid == nil ? editedLiveRowFiles : []",
                         "Task { @MainActor in"])
          && afterCall.components(separatedBy: "attachedFiles: attachedFiles").count == 4
          && !afterCall.contains("editedLiveRowFiles"))
    check("the view asks the model for each agent's cut",
          view.contains("AgentSessionRewind.claudeResumeEntry(")
          && view.contains("AgentSessionRewind.codexRevertTurn(")
          && view.contains("AgentSessionRewind.kimiUndoTarget(")
          && view.contains("AgentSessionRewind.kimiUndoPath(sessionId: sessionId)"))
    let undoKimi = block(view, "private func undoKimi(")
    check("…and kimi's own turn list names the turn its undo takes, on a kimi whose undo names one",
          ordered(undoKimi, ["AgentSessionRewind.kimiUndoNamesTurn(",
                             "var body: [String: Any] = [\"count\": target.count]",
                             "if namesTurn {", "AgentSessionRewind.kimiTurnsPath(sessionId: sessionId,",
                             "server.request(method: \"GET\", path: list)",
                             "AgentSessionRewind.kimiTurnsPage(from: data,",
                             "AgentSessionRewind.kimiWords(in: data)",
                             "body = [\"turn_id\": turnId]",
                             "server.request(method: \"POST\", path: path, body: body)"]))
    // An older kimi reads any undo body as a count — one, when it gives
    // none — so a body naming a turn would take a turn back there. The app
    // reads kimi's turn list before it names a turn (above); the live part's
    // control hands the count to a kimi that names turns, and an older kimi
    // nothing but the count it takes.
    let live = source("Verification/SessionRewind/live.py")
    check("…and the live part never hands an older kimi a body naming a turn",
          !live.contains("else {\"turn_id\"")
          && ordered(live, ["if names_turn:", "status, detail = call(undo_path, {\"count\": 2})",
                            "control: this kimi refuses the count an older kimi's undo takes"]))
    let row = span(view, from: "BranchEditor(", to: "onCancel: onCancelEdit", after: "private func userRow(")
    check("an agent row's editor offers Send, held where the tool cannot go back",
          row.contains("onSend:") && row.contains("sendBlocked: blocked != nil || rewindSupport != .offered"))

    let chat = source("SipAI/Views/Chat/ChatView.swift")
    check("a chat's Send cuts the conversation at the edited message and sends there",
          ordered(block(chat, "private func editChatInPlace(from"), ["sendMessage(", "replacingFrom:"])
          && ordered(block(chat, "private func sendMessage("),
                     ["if let cut, cut <= liveMessages.count {", "liveMessages.removeSubrange(cut...)",
                      "liveMessages.append(userMessage)", "persistCurrentChat()"]))
    check("…and Create Branch leaves the composer's own text and files alone",
          block(chat, "private func createChatBranch(").contains("fromComposer: false")
          && ordered(block(chat, "private func sendMessage("),
                     ["if fromComposer { pendingAttachments = [] }", "if fromComposer {", "draft = \"\""]))
    check("…an edit names the text files it still carries through the one reader of inlined files",
          block(chat, "private func sendMessage(").contains("AttachmentInline.names(in: text)"))

    let bubble = source("SipAI/Views/Chat/MessageBubble.swift")
    let editor = block(bubble, "struct BranchEditor: View {")
    check("the editor: Cancel, Create Branch and Send",
          ordered(editor, ["Button(action: onCancel)", "Button(action: onCreate)", "Button(action: onSend)"]))
    check("…Return takes the filled one: Send, or Create Branch where Send cannot go",
          ordered(editor, ["private var sendLeads: Bool { onSend != nil && !sendBlocked }",
                           "private func submit() {", "if sendLeads {", "if canSend { onSend?() }",
                           "} else if canCreate {"])
          && editor.contains(".filled(!sendLeads)") && editor.contains(".filled(sendLeads)"))

    print("\n\(checks - failures)/\(checks) passed")
    exit(failures == 0 ? 0 : 1)
}

if args.first == "read", args.count >= 3 {
    let file = URL(fileURLWithPath: args[2])
    let items: [AgentSessionHistoryItem]
    switch args[1] {
    case "codex":
        let root = args.count >= 4 ? URL(fileURLWithPath: args[3], isDirectory: true)
                                   : CodexSessionScanner.sessionRoot
        let current = CodexSessionScanner.rolloutFile(namedForId: args.count >= 5 ? args[4] : "", root: root) ?? file
        items = CodexSessionScanner.readHistory(of: current, root: root)
    case "kimi":
        items = KimiSessionScanner.readHistory(of: file)
    default:
        items = AgentSessionScanner.readHistory(of: file)
    }
    print(json(said(items)))
    exit(0)
}

if args.first == "fork-claude", args.count == 3 {
    do {
        let branch = try AgentSessionFork.fork(source: URL(fileURLWithPath: args[1]),
                                               cutAtRecordUuid: args[2])
        print(json(["id": branch.sessionId, "file": branch.fileURL.path]))
    } catch {
        print(json(["error": "\(error)"]))
    }
    exit(0)
}

if args.first == "cut-claude", args.count == 4 {
    let found = AgentSessionFork.resolveCutPoint(matchingUserText: args[2],
                                                 in: URL(fileURLWithPath: args[1]),
                                                 skippingNewest: Int(args[3]) ?? 0)
    print(json(["uuid": found.map { $0 as Any } ?? NSNull()]))
    exit(0)
}

// MARK: - Rules

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("session-rewind-\(UUID().uuidString)", isDirectory: true)
try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)

print("1. Claude Code — the line claude resumes, not every record in the file")

let sid = "11111111-2222-4333-8444-555555555555"
func claudeUser(_ uuid: String, _ parent: String?, _ text: String) -> [String: Any] {
    ["type": "user", "uuid": uuid, "parentUuid": parent ?? NSNull(), "sessionId": sid,
     "isSidechain": false, "timestamp": "2026-01-02T03:04:05.000Z",
     "message": ["role": "user", "content": text]]
}
func claudeReply(_ uuid: String, _ parent: String, _ text: String) -> [String: Any] {
    ["type": "assistant", "uuid": uuid, "parentUuid": parent, "sessionId": sid,
     "isSidechain": false, "timestamp": "2026-01-02T03:04:06.000Z",
     "message": ["id": "msg_\(uuid)", "role": "assistant", "model": "claude-test",
                 "content": [["type": "text", "text": text]]]]
}
func claudeLeaf(_ leaf: String, rewound: Bool = false) -> [String: Any] {
    var record: [String: Any] = ["type": "last-prompt", "lastPrompt": "x", "leafUuid": leaf, "sessionId": sid]
    if rewound { record["rewound"] = true; record["explicit"] = true }
    return record
}

// A then B; B edited in place: C is parented at the entry above B.
let rewound = scratch.appendingPathComponent("claude/rewound.jsonl")
write([claudeUser("u1", nil, "ALPHA"), claudeReply("a1", "u1", "reply one"),
       claudeLeaf("a1"),
       claudeUser("u2", "a1", "BRAVO"), claudeReply("a2", "u2", "reply two"),
       claudeLeaf("a2"),
       claudeUser("u3", "a1", "CHARLIE"), claudeReply("a3", "u3", "reply three"),
       claudeLeaf("a3"),
       claudeUser("u4", "a3", "DELTA"), claudeReply("a4", "u4", "reply four")], to: rewound)
check("a turn a rewind dropped is not drawn",
      said(AgentSessionScanner.readHistory(of: rewound)) == ["ALPHA", "CHARLIE", "DELTA"],
      "\(said(AgentSessionScanner.readHistory(of: rewound)))")
check("…and neither is its reply",
      !AgentSessionScanner.readHistory(of: rewound).contains {
          if case .assistantText(let t) = $0.kind { return t == "reply two" }
          return false
      })

// Parallel tool calls: the first call's result is parented at that call,
// beside the second call — a side branch with no prompt, which claude keeps.
let parallel = scratch.appendingPathComponent("claude/parallel.jsonl")
func toolCall(_ uuid: String, _ parent: String, _ id: String) -> [String: Any] {
    ["type": "assistant", "uuid": uuid, "parentUuid": parent, "sessionId": sid, "isSidechain": false,
     "message": ["id": "msg_tools", "role": "assistant", "model": "claude-test",
                 "content": [["type": "tool_use", "id": id, "name": "Bash", "input": ["command": "true"]]]]]
}
func toolResult(_ uuid: String, _ parent: String, _ id: String) -> [String: Any] {
    ["type": "user", "uuid": uuid, "parentUuid": parent, "sessionId": sid, "isSidechain": false,
     "toolUseResult": ["stdout": "done"],
     "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "done"]]]]
}
write([claudeUser("u1", nil, "ALPHA"),
       toolCall("t1", "u1", "toolu_1"), toolCall("t2", "t1", "toolu_2"),
       toolResult("r1", "t1", "toolu_1"), toolResult("r2", "t2", "toolu_2"),
       claudeReply("a1", "r2", "both ran"),
       claudeUser("u2", "a1", "BRAVO"), claudeReply("a2", "u2", "ok")], to: parallel)
let parallelItems = AgentSessionScanner.readHistory(of: parallel)
let results = parallelItems.filter { if case .toolResult = $0.kind { return true }; return false }
check("a parallel call's result off the line is kept", results.count == 2, "\(results.count) results")
check("…with every message", said(parallelItems) == ["ALPHA", "BRAVO"], "\(said(parallelItems))")

// Rewound in claude's terminal, nothing sent since: the marker names the leaf.
let marked = scratch.appendingPathComponent("claude/marked.jsonl")
write([claudeUser("u1", nil, "ALPHA"), claudeReply("a1", "u1", "reply one"),
       claudeUser("u2", "a1", "BRAVO"), claudeReply("a2", "u2", "reply two"),
       claudeLeaf("a2"), claudeLeaf("a1", rewound: true)], to: marked)
check("a rewind not yet followed by a message ends the line where it says",
      said(AgentSessionScanner.readHistory(of: marked)) == ["ALPHA"],
      "\(said(AgentSessionScanner.readHistory(of: marked)))")

// A compaction: the line crosses it through `logicalParentUuid`.
let compacted = scratch.appendingPathComponent("claude/compacted.jsonl")
var summary = claudeUser("s1", "b1", "This session is being continued from a previous conversation.")
summary["isCompactSummary"] = true
write([claudeUser("u1", nil, "ALPHA"), claudeReply("a1", "u1", "reply one"),
       ["type": "system", "subtype": "compact_boundary", "uuid": "b1", "parentUuid": NSNull(),
        "logicalParentUuid": "a1", "sessionId": sid, "compactMetadata": ["trigger": "auto", "preTokens": 9000]],
       summary,
       claudeUser("u2", "s1", "BRAVO"), claudeReply("a2", "u2", "reply two")], to: compacted)
check("a compaction keeps the history above it",
      said(AgentSessionScanner.readHistory(of: compacted)) == ["ALPHA", "BRAVO"],
      "\(said(AgentSessionScanner.readHistory(of: compacted)))")

// A message written twice under one uuid (compacted right before sending):
// its last copy's parent counts, and nothing is dropped.
let resent = scratch.appendingPathComponent("claude/resent.jsonl")
var resentSummary = claudeUser("s1", "b1", "Summary.")
resentSummary["isCompactSummary"] = true
write([claudeUser("u1", nil, "ALPHA"), claudeReply("a1", "u1", "reply one"),
       claudeUser("u2", "a1", "BRAVO"),
       ["type": "system", "subtype": "compact_boundary", "uuid": "b1", "parentUuid": NSNull(),
        "logicalParentUuid": "a1", "sessionId": sid],
       resentSummary, claudeUser("u2", "s1", "BRAVO"),
       claudeReply("a2", "u2", "reply two")], to: resent)
check("a message written twice is not taken for a rewind",
      said(AgentSessionScanner.readHistory(of: resent)) == ["ALPHA", "BRAVO"],
      "\(said(AgentSessionScanner.readHistory(of: resent)))")

// A rewind to before the first message: a second root.
let restarted = scratch.appendingPathComponent("claude/restarted.jsonl")
write([claudeUser("u1", nil, "ALPHA"), claudeReply("a1", "u1", "reply one"),
       claudeUser("u2", nil, "AGAIN"), claudeReply("a2", "u2", "reply two")], to: restarted)
check("a rewind to the very start drops the first beginning",
      said(AgentSessionScanner.readHistory(of: restarted)) == ["AGAIN"],
      "\(said(AgentSessionScanner.readHistory(of: restarted)))")

// A plain transcript is untouched.
let plain = scratch.appendingPathComponent("claude/plain.jsonl")
write([claudeUser("u1", nil, "ALPHA"), claudeReply("a1", "u1", "reply one"),
       claudeUser("u2", "a1", "BRAVO"), claudeReply("a2", "u2", "reply two")], to: plain)
check("a transcript with no rewind reads whole",
      said(AgentSessionScanner.readHistory(of: plain)) == ["ALPHA", "BRAVO"])
// A writer that chains nothing (no `parentUuid` anywhere) has a root per
// record; none of them is a beginning a rewind left behind.
let unchained = scratch.appendingPathComponent("claude/unchained.jsonl")
write([["type": "user", "uuid": "u1", "sessionId": sid, "message": ["role": "user", "content": "ALPHA"]],
       ["type": "assistant", "uuid": "a1", "sessionId": sid,
        "message": ["role": "assistant", "model": "claude-test", "content": [["type": "text", "text": "one"]]]],
       ["type": "user", "uuid": "u2", "sessionId": sid, "message": ["role": "user", "content": "BRAVO"]],
       ["type": "assistant", "uuid": "a2", "sessionId": sid,
        "message": ["role": "assistant", "model": "claude-test", "content": [["type": "text", "text": "two"]]]]],
      to: unchained)
check("a transcript with no links at all reads whole",
      said(AgentSessionScanner.readHistory(of: unchained)) == ["ALPHA", "BRAVO"],
      "\(said(AgentSessionScanner.readHistory(of: unchained)))")

// A live row matched by its words skips a dropped turn with the same words.
let repeated = scratch.appendingPathComponent("claude/repeated.jsonl")
write([claudeUser("u1", nil, "go"), claudeReply("a1", "u1", "reply one"),
       claudeUser("u2", "a1", "again"), claudeReply("a2", "u2", "reply two"),
       claudeUser("u3", "a2", "go"), claudeReply("a3", "u3", "dropped"),
       claudeUser("u4", "a2", "next"), claudeReply("a4", "u4", "kept")], to: repeated)
check("the newest kept match is found",
      AgentSessionFork.resolveCutPoint(matchingUserText: "go", in: repeated) == "u1",
      AgentSessionFork.resolveCutPoint(matchingUserText: "go", in: repeated) ?? "nil")

// Create Branch from a rewound session.
let source = scratch.appendingPathComponent("claude/project/\(sid).jsonl")
try? fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
try? fm.copyItem(at: rewound, to: source)
func branchRecords(cutAt uuid: String) -> [String]? {
    guard let branch = try? AgentSessionFork.fork(source: source, cutAtRecordUuid: uuid),
          let text = try? String(contentsOf: branch.fileURL, encoding: .utf8) else { return nil }
    return text.split(separator: "\n").compactMap { line in
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        else { return nil }
        return (obj["uuid"] as? String) ?? (obj["leafUuid"] as? String).map { "leaf:" + $0 }
    }
}
let atEdit = branchRecords(cutAt: "u3") ?? []
check("a branch at the edited message carries only the line above it",
      atEdit.filter { !$0.hasPrefix("leaf:") } == ["u1", "a1"], "\(atEdit)")
check("…and no marker naming the dropped turn", !atEdit.contains("leaf:a2"), "\(atEdit)")
let later = branchRecords(cutAt: "u4") ?? []
check("a branch below the edit carries the line, without the dropped turn",
      later.filter { !$0.hasPrefix("leaf:") } == ["u1", "a1", "u3", "a3"], "\(later)")
let restartedSource = scratch.appendingPathComponent("claude/project/22222222-2222-4333-8444-555555555555.jsonl")
try? fm.copyItem(at: restarted, to: restartedSource)
var restartedBranch = "branched"
do {
    _ = try AgentSessionFork.fork(source: restartedSource, cutAtRecordUuid: "u2")
} catch AgentSessionFork.ForkError.nothingToBranch {
    restartedBranch = "nothing to branch"
} catch {
    restartedBranch = "\(error)"
}
check("the first message after a rewind to the start has nothing above it",
      restartedBranch == "nothing to branch", restartedBranch)

print("\n2. Codex — a revert's segment, read through its history_base")

let codexRoot = scratch.appendingPathComponent("codex/sessions", isDirectory: true)
let day = codexRoot.appendingPathComponent("2026/01/02", isDirectory: true)
let thread = "01a00000-0000-7000-8000-000000000001"
let seg1 = "01a00000-0000-7000-8000-0000000000a1"
let seg2 = "01a00000-0000-7000-8000-0000000000a2"
let forkId = "01a00000-0000-7000-8000-0000000000f1"
let oldForkId = "01a00000-0000-7000-8000-0000000000f2"
let subagentId = "01a00000-0000-7000-8000-0000000000c1"
let cwd = "/Users/example-user/Projects/demo"
func meta(_ id: String, ordinal: Int = 0, base: (String, Int)? = nil,
          fork: (String, Int)? = nil, subagent: Int? = nil) -> [String: Any] {
    var payload: [String: Any] = ["id": id, "session_id": id, "cwd": cwd, "source": "exec",
                                  "originator": "codex_exec", "history_mode": "paginated"]
    if let base { payload["history_base"] = ["thread_id": base.0, "end_ordinal_exclusive": base.1,
                                             "end_byte_offset": 1] }
    if let fork { payload["forked_from_id"] = fork.0; payload["forked_from_ordinal_exclusive"] = fork.1 }
    if let subagent { payload["forked_from_id"] = thread; payload["subagent_history_start_ordinal"] = subagent }
    return ["timestamp": "2026-01-02T03:04:05.000Z", "ordinal": ordinal, "type": "session_meta",
            "payload": payload]
}
/// One turn at `ordinal`: four records, as codex's own turns open and close.
func turn(_ text: String, at ordinal: Int) -> [[String: Any]] {
    let turnId = "turn-\(text)"
    return [
        ["timestamp": "2026-01-02T03:04:05.000Z", "ordinal": ordinal, "type": "event_msg",
         "payload": ["type": "task_started", "turn_id": turnId]],
        ["timestamp": "2026-01-02T03:04:05.000Z", "ordinal": ordinal + 1, "type": "response_item",
         "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]],
        ["timestamp": "2026-01-02T03:04:06.000Z", "ordinal": ordinal + 2, "type": "response_item",
         "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "OK"]]]],
        ["timestamp": "2026-01-02T03:04:06.000Z", "ordinal": ordinal + 3, "type": "event_msg",
         "payload": ["type": "task_complete", "turn_id": turnId]],
    ]
}
let first = day.appendingPathComponent("rollout-2026-01-02T03-04-05-\(thread).jsonl")
write([meta(thread)] + turn("<scheduled-task name=\"nightly\"></scheduled-task>ALPHA", at: 1)
      + turn("BRAVO", at: 5) + turn("CHARLIE", at: 9) + turn("DELTA", at: 13), to: first)
// Reverted before BRAVO, then ECHO and FOX; reverted again before FOX, then GOLF.
let firstSegment = day.appendingPathComponent("rollout-2026-01-02T03-05-00-\(thread)_\(seg1).jsonl")
write([meta(thread, ordinal: 5, base: (thread, 5))] + turn("ECHO", at: 6) + turn("FOX", at: 10),
      to: firstSegment)
let secondSegment = day.appendingPathComponent("rollout-2026-01-02T03-06-00-\(thread)_\(seg2).jsonl")
write([meta(thread, ordinal: 10, base: (seg1, 10))] + turn("GOLF", at: 11), to: secondSegment)
// A fork made from DELTA before the reverts, both shapes, and a subagent.
let fork = day.appendingPathComponent("rollout-2026-01-02T03-04-30-\(forkId).jsonl")
write([meta(forkId, ordinal: 17, base: (thread, 17), fork: (thread, 17))] + turn("HOTEL", at: 18), to: fork)
let oldFork = day.appendingPathComponent("rollout-2026-01-02T03-04-31-\(oldForkId).jsonl")
write([meta(oldForkId, ordinal: 9, fork: (thread, 9))] + turn("INDIA", at: 10), to: oldFork)
let subagent = day.appendingPathComponent("rollout-2026-01-02T03-04-32-\(subagentId).jsonl")
write([meta(subagentId, ordinal: 0, base: (thread, 9), subagent: 0)] + turn("JULIET", at: 1), to: subagent)

let alpha = "ALPHA"
func codexSaid(_ url: URL) -> [String] {
    said(CodexSessionScanner.readHistory(of: url, root: codexRoot)).map {
        $0.replacingOccurrences(of: "<scheduled-task name=\"nightly\"></scheduled-task>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
check("a revert's segment of the thread is its current file",
      CodexSessionScanner.rolloutFile(namedForId: thread, root: codexRoot)?.lastPathComponent
        == secondSegment.lastPathComponent,
      CodexSessionScanner.rolloutFile(namedForId: thread, root: codexRoot)?.lastPathComponent ?? "nil")
check("the current file reads as codex replays it",
      codexSaid(secondSegment) == [alpha, "ECHO", "GOLF"], "\(codexSaid(secondSegment))")
check("…and the first revert's file as it stood",
      codexSaid(firstSegment) == [alpha, "ECHO", "FOX"], "\(codexSaid(firstSegment))")
check("a fork made before the reverts keeps what it inherited",
      codexSaid(fork) == [alpha, "BRAVO", "CHARLIE", "DELTA", "HOTEL"], "\(codexSaid(fork))")
check("…and so does a fork that names its parent the older way",
      codexSaid(oldFork) == [alpha, "BRAVO", "INDIA"], "\(codexSaid(oldFork))")
check("a subagent is never spliced, whatever its head carries",
      codexSaid(subagent) == ["JULIET"], "\(codexSaid(subagent))")
check("a segment's name belongs to its thread",
      CodexSessionScanner.rolloutName(secondSegment.lastPathComponent, isFor: thread))
check("…and not to the segment id or another thread",
      !CodexSessionScanner.rolloutName(secondSegment.lastPathComponent, isFor: seg2)
        && !CodexSessionScanner.rolloutName(secondSegment.lastPathComponent, isFor: forkId))
check("a name that is not codex's is no segment",
      !CodexSessionScanner.rolloutName("rollout-2026-01-02T03-04-05-x_\(seg1).jsonl", isFor: seg1)
        && !CodexSessionScanner.rolloutName("rollout-2026-01-02T03-04-05-\(thread)_notauuid.jsonl",
                                             isFor: thread))
check("a cut on an inherited message finds its turn",
      CodexSessionFork.resolveCutPoint(matchingUserText: "ECHO", in: secondSegment, root: codexRoot) == "turn-ECHO",
      CodexSessionFork.resolveCutPoint(matchingUserText: "ECHO", in: secondSegment, root: codexRoot) ?? "nil")
check("…and a reverted message is not found",
      CodexSessionFork.resolveCutPoint(matchingUserText: "BRAVO", in: secondSegment, root: codexRoot) == nil)
check("the turns the current file stands on are the kept ones",
      CodexSessionFork.turnSequence(of: secondSegment, root: codexRoot)
        == ["turn-<scheduled-task name=\"nightly\"></scheduled-task>ALPHA", "turn-ECHO", "turn-GOLF"],
      "\(CodexSessionFork.turnSequence(of: secondSegment, root: codexRoot))")

// The listing, through the real `scan` (run.sh points the home at a
// throwaway, so `sessionRoot` is this store's copy).
let listedRoot = CodexSessionScanner.sessionRoot
if listedRoot.path.hasPrefix(fm.homeDirectoryForCurrentUser.path),
   fm.homeDirectoryForCurrentUser.path.contains("session-rewind-home") {
    try? fm.createDirectory(at: listedRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.removeItem(at: listedRoot)
    try? fm.copyItem(at: codexRoot, to: listedRoot)
    let listed = CodexSessionScanner.scan().filter { $0.id == thread }
    check("the sidebar lists the thread once", listed.count == 1, "\(listed.count)")
    check("…from its current file", listed.first?.fileURL.lastPathComponent == secondSegment.lastPathComponent,
          listed.first?.fileURL.lastPathComponent ?? "nil")
    check("…still filed under its scheduled task", listed.first?.scheduledTaskName == "nightly",
          listed.first?.scheduledTaskName ?? "nil")
    check("…and titled by the message it began with", listed.first?.title == "ALPHA",
          listed.first?.title ?? "nil")
    check("deleting it finds every file it has",
          Set(CodexSessionScanner.rolloutFiles(forSessionId: thread).map(\.lastPathComponent))
            == Set([first, firstSegment, secondSegment].map(\.lastPathComponent)))
} else {
    print("  SKIP the listing — run through run.sh, which points the home at a throwaway")
}

print("\n3. Kimi Code — an undo folded as kimi folds it")

let kimiHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KIMI_CODE_HOME"] ?? "")
var kimiWire: URL? = nil
if !kimiHome.path.isEmpty, kimiHome.path.contains("session-rewind-home") {
    let sessionDir = KimiSessionScanner.sessionRoot
        .appendingPathComponent("wd_demo_000000000000/session_00000000-0000-4000-8000-000000000001", isDirectory: true)
    kimiWire = KimiSessionScanner.wireFile(inSessionDir: sessionDir)
}
let wire = kimiWire ?? scratch.appendingPathComponent("kimi/wire.jsonl")
func kimiTurn(_ text: String, id: String, origin: [String: Any]? = ["kind": "user"]) -> [[String: Any]] {
    var message: [String: Any] = ["role": "user", "content": [["type": "text", "text": text]], "id": id, "toolCalls": []]
    if let origin { message["origin"] = origin }
    return [
        ["type": "turn.prompt", "agentId": "main", "promptId": id, "input": [["type": "text", "text": text]]],
        ["type": "context.append_message", "agentId": "main", "message": message],
        ["type": "context.append_loop_event", "agentId": "main",
         "event": ["type": "content.part", "part": ["type": "text", "text": "reply to \(text)"]]],
        ["type": "turn.ended", "agentId": "main", "reason": "completed"],
        ["type": "prompt.completed", "agentId": "main", "promptId": id],
    ]
}
func undo(_ count: Int) -> [[String: Any]] {
    [["type": "agent.switched", "agentId": "main", "branch": "b1", "reason": "undo",
      "base": ["branch": "main", "line": 1], "turns": count],
     ["type": "context.undo", "agentId": "main", "count": count],
     ["type": "context.undone", "agentId": "main", "turns": count, "fromTurnId": 1]]
}
let reminder: [[String: Any]] = [["type": "context.append_message", "agentId": "main",
    "message": ["role": "user", "content": [["type": "text", "text": "<system-reminder>\nmode\n</system-reminder>"]],
                "origin": ["kind": "injection", "variant": "permission_mode"]]]]
let notice: [[String: Any]] = [["type": "context.append_message", "agentId": "main",
    "message": ["role": "user", "content": [["type": "text", "text": "<notification>done</notification>"]],
                "origin": ["kind": "task", "taskId": "bash-1"]]]]
write([["type": "metadata", "protocol_version": "1.5"]]
      + kimiTurn("ALPHA", id: "p1") + reminder + kimiTurn("BRAVO", id: "p2") + notice
      + kimiTurn("CHARLIE", id: "p3") + undo(2) + kimiTurn("DELTA", id: "p4"), to: wire)
check("the turns an undo took are not drawn",
      said(KimiSessionScanner.readHistory(of: wire)) == ["ALPHA", "DELTA"],
      "\(said(KimiSessionScanner.readHistory(of: wire)))")

let twice = scratch.appendingPathComponent("kimi/twice.jsonl")
write(kimiTurn("ALPHA", id: "p1") + kimiTurn("BRAVO", id: "p2") + undo(1)
      + kimiTurn("CHARLIE", id: "p3") + undo(1) + kimiTurn("DELTA", id: "p4"), to: twice)
check("a second undo counts from what the first one left",
      said(KimiSessionScanner.readHistory(of: twice)) == ["ALPHA", "DELTA"],
      "\(said(KimiSessionScanner.readHistory(of: twice)))")

let skill = scratch.appendingPathComponent("kimi/skill.jsonl")
write(kimiTurn("ALPHA", id: "p1")
      + kimiTurn("BRAVO", id: "p2", origin: ["kind": "skill_activation", "trigger": "user-slash", "skillName": "demo"])
      + kimiTurn("STEERED", id: "p3", origin: ["kind": "user", "inTurn": true])
      + undo(1) + kimiTurn("CHARLIE", id: "p4"), to: skill)
check("a skill the user typed is a turn an undo counts; a steered message is not",
      said(KimiSessionScanner.readHistory(of: skill)) == ["ALPHA", "CHARLIE"],
      "\(said(KimiSessionScanner.readHistory(of: skill)))")

let summarized = scratch.appendingPathComponent("kimi/summarized.jsonl")
write(kimiTurn("ALPHA", id: "p1")
      + [["type": "context.apply_compaction", "agentId": "main", "summary": "", "tokensBefore": 900, "tokensAfter": 90]]
      + kimiTurn("BRAVO", id: "p2") + undo(2) + kimiTurn("CHARLIE", id: "p3"), to: summarized)
check("an undo kimi would refuse across a summary removes nothing",
      said(KimiSessionScanner.readHistory(of: summarized)) == ["ALPHA", "BRAVO", "CHARLIE"],
      "\(said(KimiSessionScanner.readHistory(of: summarized)))")

let long = scratch.appendingPathComponent("kimi/long.jsonl")
var longLines: [[String: Any]] = []
for i in 1...5 { longLines += kimiTurn("T\(i)", id: "p\(i)") }
longLines += undo(4) + kimiTurn("T6", id: "p6")
write(longLines, to: long)
check("whole, the undo leaves the first turn",
      said(KimiSessionScanner.readHistory(of: long)) == ["T1", "T6"],
      "\(said(KimiSessionScanner.readHistory(of: long)))")
let tailBytes = (try? String(contentsOf: long, encoding: .utf8))
    .map { text -> Int in
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(5 * 3 + 3 + 5 + 1).joined(separator: "\n").utf8.count
    } ?? 0
check("in a window that begins mid-conversation, every turn it holds above the undo goes",
      said(KimiSessionScanner.readHistory(of: long, byteBudget: tailBytes)) == ["T6"],
      "\(said(KimiSessionScanner.readHistory(of: long, byteBudget: tailBytes)))")

let goAgain = scratch.appendingPathComponent("kimi/go.jsonl")
write(kimiTurn("go", id: "p1") + kimiTurn("go", id: "p2") + undo(1) + kimiTurn("next", id: "p3"), to: goAgain)
check("a live row matched by its words skips an undone turn",
      KimiSessionFork.resolveCutPoint(matchingUserText: "go", in: goAgain) == "p1"
        && KimiSessionFork.resolveCutPoint(matchingUserText: "go", in: goAgain, skippingNewest: 1) == nil,
      "\(KimiSessionFork.resolveCutPoint(matchingUserText: "go", in: goAgain) ?? "nil")")
let undoneOnly = (kimiTurn("ALPHA", id: "p1") + undo(1)).map(json)
check("a prefix whose only exchange an undo took holds no conversation",
      !KimiSessionFork.prefixHoldsConversation(undoneOnly)
        && KimiSessionFork.prefixHoldsConversation(kimiTurn("ALPHA", id: "p1").map(json)))

if kimiWire != nil {
    if let branch = try? KimiSessionFork.fork(sourceWire: wire, cutAtPromptId: "p4",
                                             title: "Branch", cwd: URL(fileURLWithPath: cwd)) {
        check("a branch above a message after an undo reads as kimi replays it",
              said(KimiSessionScanner.readHistory(of: branch.wireURL)) == ["ALPHA"],
              "\(said(KimiSessionScanner.readHistory(of: branch.wireURL)))")
    } else {
        check("a branch above a message after an undo is written", false)
    }
} else {
    print("  SKIP the kimi branch — run through run.sh, which points KIMI_CODE_HOME at a throwaway")
}

print("\n7. Send in place — what SipAI asks each tool for")

func resumeEntry(_ url: URL, record: String?, text: String = "", skip: Int = 0) -> String {
    do {
        return try AgentSessionRewind.claudeResumeEntry(recordUuid: record, in: url,
                                                        originalText: text, skippingNewer: skip)
    } catch {
        return errorName(error)
    }
}
check("claude: an edit of the second message resumes at the reply above it",
      resumeEntry(plain, record: "u2") == "a1", resumeEntry(plain, record: "u2"))
check("…found by its words too, the way a live row is found",
      resumeEntry(plain, record: nil, text: "BRAVO") == "a1", resumeEntry(plain, record: nil, text: "BRAVO"))
check("…the first message has nothing to go back to",
      resumeEntry(plain, record: "u1") == "nothingToBranch", resumeEntry(plain, record: "u1"))
check("…a message claude wrote twice resumes above its last copy",
      resumeEntry(resent, record: "u2") == "s1", resumeEntry(resent, record: "u2"))
check("…a message a rewind dropped is not there to edit",
      resumeEntry(rewound, record: nil, text: "BRAVO") == "cutPointNotFound",
      resumeEntry(rewound, record: nil, text: "BRAVO"))
check("…the message the edit put in its place resumes above it, and the next at its own reply",
      resumeEntry(rewound, record: "u3") == "a1" && resumeEntry(rewound, record: "u4") == "a3",
      resumeEntry(rewound, record: "u3") + " " + resumeEntry(rewound, record: "u4"))
check("…a record the file does not hold is not found",
      resumeEntry(plain, record: "nope") == "cutPointNotFound")
let commandFirst = scratch.appendingPathComponent("claude/command-first.jsonl")
write([claudeUser("c1", nil, "<command-name>/mcp</command-name>"),
       ["type": "system", "subtype": "local_command", "uuid": "c2", "parentUuid": "c1", "sessionId": sid,
        "content": "<local-command-stdout>No MCP servers configured.</local-command-stdout>"],
       claudeUser("u1", "c2", "ALPHA"), claudeReply("a1", "u1", "reply one"),
       claudeUser("u2", "a1", "BRAVO"), claudeReply("a2", "u2", "reply two")], to: commandFirst)
check("…a message under nothing but a slash command's answer is a first message",
      resumeEntry(commandFirst, record: "u1") == "nothingToBranch", resumeEntry(commandFirst, record: "u1"))
check("…and the one after it resumes as usual",
      resumeEntry(commandFirst, record: "u2") == "a1", resumeEntry(commandFirst, record: "u2"))
let longReply = scratch.appendingPathComponent("claude/long-reply.jsonl")
write([claudeUser("u1", nil, "ALPHA"),
       claudeReply("a1", "u1", String(repeating: "a long answer ", count: 30_000)),
       claudeUser("u2", "a1", "BRAVO"), claudeReply("a2", "u2", "reply two")], to: longReply)
check("…an entry above a reply longer than the first window is found by a wider one",
      resumeEntry(longReply, record: "u2") == "a1" && resumeEntry(longReply, record: "u1") == "nothingToBranch",
      resumeEntry(longReply, record: "u2") + " " + resumeEntry(longReply, record: "u1"))

let flagFile = scratch.appendingPathComponent("flag/binary")
try? fm.createDirectory(at: flagFile.deletingLastPathComponent(), withIntermediateDirectories: true)
var straddling = Data(repeating: 0x2E, count: 8 * 1024 * 1024 - 6)
straddling.append(Data(ClaudeCapabilities.resumeSessionAtFlag.utf8))
straddling.append(Data(repeating: 0x2E, count: 1024))
try? straddling.write(to: flagFile)
let plainFile = scratch.appendingPathComponent("flag/other")
try? Data(repeating: 0x2E, count: 9 * 1024 * 1024).write(to: plainFile)
check("claude's executable is read for the flag, across a chunk boundary",
      ClaudeCapabilities.executable(flagFile.path, names: ClaudeCapabilities.resumeSessionAtFlag) == true)
check("…one without it says no, and a missing file says nothing",
      ClaudeCapabilities.executable(plainFile.path, names: ClaudeCapabilities.resumeSessionAtFlag) == false
      && ClaudeCapabilities.executable(scratch.appendingPathComponent("flag/none").path,
                                       names: ClaudeCapabilities.resumeSessionAtFlag) == nil)
try? fm.removeItem(at: flagFile.deletingLastPathComponent())

let requests = (AgentSessionRewind.codexRevertRequests(threadId: thread, beforeTurnId: "turn-ECHO") ?? [])
    .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
let resumeParams = requests.first?["params"] as? [String: Any]
let revertParams = requests.last?["params"] as? [String: Any]
check("codex: the thread is loaded, then reverted before the edited message's turn",
      requests.count == 2
      && requests[0]["id"] as? Int == 2 && requests[0]["method"] as? String == "thread/resume"
      && resumeParams?["threadId"] as? String == thread
      && requests[1]["id"] as? Int == 3 && requests[1]["method"] as? String == "thread/revert"
      && revertParams?["threadId"] as? String == thread
      && revertParams?["beforeTurnId"] as? String == "turn-ECHO", "\(requests)")
func revertOutcome(_ answers: [Int: [String: Any]]) -> String {
    json(describe(AgentSessionRewind.codexRevertOutcome(from: answers)))
}
check("…its answer names the thread's new file",
      revertOutcome([2: ["result": [:]],
                     3: ["result": ["thread": ["id": thread, "path": "/x/rollout.jsonl"]]]])
        == json(["reverted": "/x/rollout.jsonl"]))
check("…a codex without the call says so, and a refusal is codex's own words",
      revertOutcome([3: ["error": ["code": -32601, "message": "Method not found"]]]) == json(["unsupported": true])
      && revertOutcome([3: ["error": ["code": -32600, "message": "turn not found: t"]]])
        == json(["refused": "turn not found: t"]))
check("…a thread codex would not load is refused in its words, and no answer is none",
      revertOutcome([2: ["error": ["code": -32600, "message": "no rollout found for thread id x"]]])
        == json(["refused": "no rollout found for thread id x"])
      && revertOutcome([:]) == json(["unavailable": true]))
check("…the load's words win over what the revert said without it",
      revertOutcome([2: ["error": ["code": -32600, "message": "thread x already has an active writer"]],
                     3: ["error": ["code": -32600, "message": "thread not found: x"]]])
        == json(["refused": "thread x already has an active writer"]))
if listedRoot.path.contains("session-rewind-home") {
    let current = listedRoot.appendingPathComponent("2026/01/02/" + secondSegment.lastPathComponent)
    func revertTurn(_ record: String?, _ text: String = "") -> String {
        do {
            return try AgentSessionRewind.codexRevertTurn(recordUuid: record, in: current,
                                                          originalText: text, skippingNewer: 0)
        } catch {
            return errorName(error)
        }
    }
    check("…an inherited message is cut before its own turn",
          revertTurn(nil, "ECHO") == "turn-ECHO" && revertTurn("turn-GOLF") == "turn-GOLF",
          revertTurn(nil, "ECHO") + " " + revertTurn("turn-GOLF"))
    check("…the first message has nothing to go back to",
          revertTurn(nil, "ALPHA") == "nothingToBranch", revertTurn(nil, "ALPHA"))
    check("…and a reverted turn is not there to edit",
          revertTurn(nil, "BRAVO") == "cutPointNotFound" && revertTurn("turn-BRAVO") == "cutPointNotFound",
          revertTurn(nil, "BRAVO") + " " + revertTurn("turn-BRAVO"))
} else {
    print("  SKIP codex's cut — run through run.sh, which points the home at a throwaway")
}

func undoTurns(_ url: URL, record: String?, text: String = "") -> String {
    do {
        return String(try AgentSessionRewind.kimiUndoTarget(recordUuid: record, in: url,
                                                            originalText: text, skippingNewer: 0).count)
    } catch {
        return errorName(error)
    }
}
let counted = scratch.appendingPathComponent("kimi/counted.jsonl")
write(kimiTurn("ALPHA", id: "p1") + kimiTurn("BRAVO", id: "p2") + reminder + notice
      + kimiTurn("CHARLIE", id: "p3", origin: ["kind": "skill_activation", "trigger": "user-slash",
                                                "skillName": "demo"])
      + kimiTurn("STEERED", id: "p4", origin: ["kind": "user", "inTurn": true])
      + kimiTurn("DELTA", id: "p5"), to: counted)
check("kimi: an edit takes back its turn and every turn after it",
      undoTurns(counted, record: "p2") == "3" && undoTurns(counted, record: "p5") == "1",
      undoTurns(counted, record: "p2") + " " + undoTurns(counted, record: "p5"))
check("…not counting a reminder, a task's notice or a steered message; a typed skill counts",
      undoTurns(counted, record: "p3") == "2", undoTurns(counted, record: "p3"))
check("…found by its words too",
      undoTurns(counted, record: nil, text: "BRAVO") == "3", undoTurns(counted, record: nil, text: "BRAVO"))
check("…after an undo, counted from what it left",
      undoTurns(wire, record: "p4") == "1" && undoTurns(wire, record: "p2") == "cutPointNotFound",
      undoTurns(wire, record: "p4") + " " + undoTurns(wire, record: "p2"))
check("…the first message has nothing to go back to",
      undoTurns(counted, record: "p1") == "nothingToBranch", undoTurns(counted, record: "p1"))
check("…the route is kimi's own, the session id kept to it",
      AgentSessionRewind.kimiUndoPath(sessionId: "session_00000000-0000-4000-8000-000000000001")
        == "/api/v1/sessions/session_00000000-0000-4000-8000-000000000001:undo"
      && AgentSessionRewind.kimiUndoPath(sessionId: "a/../b?c") == "/api/v1/sessions/a%2F%2E%2E%2Fb%3Fc:undo"
      && AgentSessionRewind.kimiUndoPath(sessionId: "é") == "/api/v1/sessions/%C3%A9:undo"
      && AgentSessionRewind.kimiUndoPath(sessionId: "") == nil)
func undoAnswer(_ text: String) -> String {
    switch AgentSessionRewind.kimiUndoOutcome(from: Data(text.utf8)) {
    case .undone: return "undone"
    case .refused(let words): return "refused: " + words
    }
}
check("…kimi's answer 0 is done; any other is a refusal in kimi's words",
      undoAnswer(#"{"code":0,"msg":"success","data":null}"#) == "undone"
      && undoAnswer(#"{"code":40001,"msg":"Nothing to undo"}"#) == "refused: Nothing to undo"
      && undoAnswer("<html>") == "refused: <html>"
      && undoAnswer(#"{"code":0,"msg":"success","data":{"removed_turn_ids":["t_0123456789ab"]}}"#) == "undone")

// A newer kimi's undo names a turn of kimi's own list, by an id SipAI
// cannot compute, and refuses a count; an older kimi takes the count —
// one, when the body gives none — so the installed version decides.
check("a kimi from \(AgentSessionRewind.kimiTurnUndoFloor) names the turn, an older or unread one takes the count",
      AgentSessionRewind.kimiUndoNamesTurn(kimiVersion: "2.6.1")
      && AgentSessionRewind.kimiUndoNamesTurn(kimiVersion: "2.7.0")
      && !AgentSessionRewind.kimiUndoNamesTurn(kimiVersion: "2.5.2")
      && !AgentSessionRewind.kimiUndoNamesTurn(kimiVersion: nil))
check("…its turn list is the session's main agent's, newest page first, then the turns below an ordinal",
      AgentSessionRewind.kimiTurnsPath(sessionId: "session_00000000-0000-4000-8000-000000000001")
        == "/api/v1/sessions/session_00000000-0000-4000-8000-000000000001/agents/main/turns?page_size=200"
      && AgentSessionRewind.kimiTurnsPath(sessionId: "a/b", beforeOrdinal: 7)
        == "/api/v1/sessions/a%2Fb/agents/main/turns?page_size=200&before_ordinal=7"
      && AgentSessionRewind.kimiTurnsPath(sessionId: "") == nil)
// A page in the shape kimi's server answers (synthetic content): a
// turn opened by the user's message, a notification turn with no opener,
// and the edited message's turn.
let turnsPage = #"""
{"code":0,"msg":"success","data":{"has_more":true,"turns":[
 {"turn_id":"t_aaaaaaaaaaaa","ordinal":4,"kind":"agent","items":[
   {"type":"user_message","item_id":"msg_EARLIER","placement":"opener","prompt_ids":["msg_EARLIER"]},
   {"type":"assistant_message","item_id":"a1"}]},
 {"turn_id":"t_bbbbbbbbbbbb","ordinal":5,"kind":"agent","items":[
   {"type":"task_notification","item_id":"n1"}]},
 {"turn_id":"t_cccccccccccc","ordinal":6,"kind":"agent","items":[
   {"type":"user_message","item_id":"msg_EDITED","placement":"opener","prompt_ids":["msg_EDITED"]},
   {"type":"user_message","item_id":"msg_STEER","placement":"steer"}]}]}}
"""#
let foundPage = AgentSessionRewind.kimiTurnsPage(from: Data(turnsPage.utf8), messageId: "msg_EDITED")
check("…a turn is named by the message that opens it, never by a message steered into it",
      foundPage == .init(turnId: "t_cccccccccccc", oldestOrdinal: 4, hasMore: true)
      && AgentSessionRewind.kimiTurnsPage(from: Data(turnsPage.utf8), messageId: "msg_STEER")?.turnId == nil
      && AgentSessionRewind.kimiTurnsPage(from: Data(turnsPage.utf8), messageId: "msg_GONE")
        == .init(turnId: nil, oldestOrdinal: 4, hasMore: true),
      "\(String(describing: foundPage))")
check("…and an answer of another shape is no page, said in kimi's words or as it came",
      AgentSessionRewind.kimiTurnsPage(from: Data(#"{"code":40400,"msg":"session not found"}"#.utf8),
                                       messageId: "msg_EDITED") == nil
      && AgentSessionRewind.kimiTurnsPage(from: Data("<html>".utf8), messageId: "msg_EDITED") == nil
      && AgentSessionRewind.kimiWords(in: Data(#"{"code":40400,"msg":"session not found"}"#.utf8))
        == "session not found"
      && AgentSessionRewind.kimiWords(in: Data(#"{"code":0,"data":{}}"#.utf8)) == #"{"code":0,"data":{}}"#)

// A live message of attached files alone has no words: its record is the
// one with no words whose markers name the row's files, and the rows to
// skip are the newer ones naming the same files. Sent without them, Send
// on such a row finds nothing and answers "compacted away".
let notesOnly = AttachmentInline.appendingReferences(
    [.init(name: "notes.md", path: "/tmp/example-project/notes.md", isFolder: false)], to: "")
let planOnly = AttachmentInline.appendingReferences(
    [.init(name: "plan.md", path: "/tmp/example-project/plan.md", isFolder: false)], to: "")
let claudeFiles = scratch.appendingPathComponent("claude/files-alone.jsonl")
write([claudeUser("u1", nil, "ALPHA"), claudeReply("a1", "u1", "reply one"),
       claudeUser("f2", "a1", notesOnly), claudeReply("fa2", "f2", "read it"),
       claudeUser("f3", "fa2", planOnly), claudeReply("fa3", "f3", "read that"),
       claudeUser("f4", "fa3", notesOnly), claudeReply("fa4", "f4", "read it again")], to: claudeFiles)
func filesEntry(_ files: [String], skip: Int = 0) -> String {
    do {
        return try AgentSessionRewind.claudeResumeEntry(recordUuid: nil, in: claudeFiles, originalText: "",
                                                        attachedFiles: files, skippingNewer: skip)
    } catch {
        return errorName(error)
    }
}
check("Send on a live message of files alone — claude: resumes above the record naming ITS files",
      filesEntry(["plan.md"]) == "fa2" && filesEntry(["notes.md"]) == "fa3"
        && filesEntry(["notes.md"], skip: 1) == "a1",
      [filesEntry(["plan.md"]), filesEntry(["notes.md"]), filesEntry(["notes.md"], skip: 1)].joined(separator: " "))
let codexFiles = scratch.appendingPathComponent("codex-files/rollout-2026-01-02T03-04-05-\(thread).jsonl")
func filesTurn(_ marker: String, id: String, at ordinal: Int) -> [[String: Any]] {
    [["timestamp": "2026-01-02T03:04:05.000Z", "ordinal": ordinal, "type": "event_msg",
      "payload": ["type": "task_started", "turn_id": id]],
     ["timestamp": "2026-01-02T03:04:05.000Z", "ordinal": ordinal + 1, "type": "response_item",
      "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": marker]]]],
     ["timestamp": "2026-01-02T03:04:06.000Z", "ordinal": ordinal + 2, "type": "response_item",
      "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "OK"]]]],
     ["timestamp": "2026-01-02T03:04:06.000Z", "ordinal": ordinal + 3, "type": "event_msg",
      "payload": ["type": "task_complete", "turn_id": id]]]
}
write([meta(thread)] + turn("ALPHA", at: 1) + filesTurn(notesOnly, id: "F2", at: 5)
      + filesTurn(planOnly, id: "F3", at: 9) + filesTurn(notesOnly, id: "F4", at: 13), to: codexFiles)
func filesTurnId(_ files: [String], skip: Int = 0) -> String {
    do {
        return try AgentSessionRewind.codexRevertTurn(recordUuid: nil, in: codexFiles, originalText: "",
                                                      attachedFiles: files, skippingNewer: skip)
    } catch {
        return errorName(error)
    }
}
check("…codex: reverts before the turn of the record naming ITS files",
      filesTurnId(["plan.md"]) == "F3" && filesTurnId(["notes.md"]) == "F4"
        && filesTurnId(["notes.md"], skip: 1) == "F2",
      [filesTurnId(["plan.md"]), filesTurnId(["notes.md"]), filesTurnId(["notes.md"], skip: 1)].joined(separator: " "))
let kimiFiles = scratch.appendingPathComponent("kimi/files-alone.jsonl")
write(kimiTurn("ALPHA", id: "p1") + kimiTurn(notesOnly, id: "p2") + kimiTurn(planOnly, id: "p3")
      + kimiTurn(notesOnly, id: "p4"), to: kimiFiles)
func filesCount(_ wire: URL, _ files: [String], skip: Int = 0) -> String {
    do {
        return String(try AgentSessionRewind.kimiUndoTarget(recordUuid: nil, in: wire, originalText: "",
                                                            attachedFiles: files, skippingNewer: skip).count)
    } catch {
        return errorName(error)
    }
}
check("…kimi: takes back the turn of the record naming ITS files, and every turn after it",
      filesCount(kimiFiles, ["plan.md"]) == "2" && filesCount(kimiFiles, ["notes.md"]) == "1"
        && filesCount(kimiFiles, ["notes.md"], skip: 1) == "3",
      [filesCount(kimiFiles, ["plan.md"]), filesCount(kimiFiles, ["notes.md"]),
       filesCount(kimiFiles, ["notes.md"], skip: 1)].joined(separator: " "))
// After an undo, a turn of files alone that kimi took back is still in the
// wire: matched unfolded, it takes the cut meant for the older one on screen.
let kimiFilesUndone = scratch.appendingPathComponent("kimi/files-undone.jsonl")
write(kimiTurn("ALPHA", id: "p1") + kimiTurn(notesOnly, id: "p2") + kimiTurn(notesOnly, id: "p3")
      + undo(1) + kimiTurn("DELTA", id: "p4"), to: kimiFilesUndone)
check("…a files-alone turn an undo took is not the one matched",
      KimiSessionFork.resolveCutPoint(matchingUserText: "", attachedFiles: ["notes.md"], in: kimiFilesUndone) == "p2"
        && KimiSessionFork.resolveCutPoint(matchingUserText: "", attachedFiles: ["notes.md"], in: kimiFilesUndone,
                                           skippingNewest: 1) == nil,
      KimiSessionFork.resolveCutPoint(matchingUserText: "", attachedFiles: ["notes.md"], in: kimiFilesUndone) ?? "nil")

typealias Support = AgentSessionRewind.Support
func support(_ agent: String, claude: Bool? = nil, codex: String? = nil, kimi: String? = nil) -> Support {
    AgentSessionRewind.support(agentKey: agent, claudeNamesFlag: claude, codexVersion: codex, kimiVersion: kimi)
}
check("Send waits until the installed tool has been read",
      support("claude_code") == .pending && support("codex") == .pending && support("kimi") == .pending)
check("…claude offers it when its executable names the flag",
      support("claude_code", claude: true) == .offered && support("claude_code", claude: false) == .needsNewer)
check("…codex and kimi from the version the call was measured on",
      support("codex", codex: AgentSessionRewind.codexVersionFloor) == .offered
      && support("codex", codex: "0.200.0") == .offered && support("codex", codex: "0.162.0") == .needsNewer
      && support("kimi", kimi: AgentSessionRewind.kimiVersionFloor) == .offered
      && support("kimi", kimi: "2.10.0") == .offered && support("kimi", kimi: "2.1.1") == .needsNewer)

try? fm.removeItem(at: scratch)
print("\n\(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
