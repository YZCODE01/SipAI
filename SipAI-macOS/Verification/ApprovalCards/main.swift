// ApprovalCards harness — see run.sh for what it pins and why.
//
// Arguments: <source-root> <work-dir>
// Environment: APPROVAL_HARNESS_MCP_DIR (read by Stubs.swift), the
// directory the REAL MCPBridge binds its socket in and finds approver.py.
import Foundation

let sourceRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let work = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let here = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)

var passed = 0
var failed = 0
func section(_ title: String) { print("\n" + title) }
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
func note(_ text: String) { print("        \(text)") }

@MainActor
func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
}

func source(_ relative: String) -> String {
    (try? String(contentsOf: sourceRoot.appendingPathComponent(relative), encoding: .utf8)) ?? ""
}

/// The text of one declaration, from its FULL signature to the next
/// member at the same indentation — never a prefix of another name.
func body(of signature: String, in text: String) -> String {
    guard let start = text.range(of: signature) else { return "" }
    let rest = text[start.upperBound...]
    let ends = ["\n    private func ", "\n    func ", "\n    @ViewBuilder",
                "\n    // MARK:", "\n    nonisolated static func ", "\n    static func ",
                "\n    private var ", "\n    var "]
    var end = rest.endIndex
    for marker in ends {
        if let r = rest.range(of: marker), r.lowerBound < end { end = r.lowerBound }
    }
    return String(text[start.lowerBound..<end])
}

// The session-id-only filter — once a runner knows its session id, match
// on that alone — is the shape that hides a first turn's cards. Kept here
// only as the negative control the real requests are held against.
func preFixFilter(_ req: MCPApprovalRequest, sessionId: String?, taskUuid: String?) -> Bool {
    if let sid = sessionId, !sid.isEmpty { return req.sessionId == sid }
    if let key = taskUuid { return req.taskUuid == key }
    return false
}

let draftUuid = "0123456789abcdef0123456789abcdef"
let otherUuid = "fedcba9876543210fedcba9876543210"
let sessionA = "3b236623-0372-45c9-8dfa-c982fe37f75d"

// MARK: - 1. The ownership rule

section("1. Which session a pending request belongs to (MCPBridge.request)")
func owns(_ requestSession: String?, _ requestUuid: String?,
          _ session: String?, _ uuid: String?, _ alias: [String: String] = [:]) -> Bool {
    MCPBridge.request(sessionId: requestSession, taskUuid: requestUuid,
                      belongsToSession: session, taskUuid: uuid, alias: alias)
}
check("a resumed turn's request (tagged with the session id) is its session's",
      owns(sessionA, nil, sessionA, draftUuid))
check("a FIRST turn's request (tagged with the draft's uuid) is its runner's once the session id is known",
      owns(nil, draftUuid, sessionA, draftUuid))
check("…and while the runner is still a draft",
      owns(nil, draftUuid, nil, draftUuid))
check("…and a caller that knows only the session finds it through the alias",
      owns(nil, draftUuid, sessionA, nil, [draftUuid: sessionA]))
check("another session's request is not ours", !owns("other-session", nil, sessionA, draftUuid))
check("another draft's uuid is not ours", !owns(nil, otherUuid, sessionA, draftUuid))
check("a uuid aliased to ANOTHER session is not ours",
      !owns(nil, otherUuid, sessionA, nil, [otherUuid: "other-session"]))
check("a runner with neither id owns nothing", !owns(nil, draftUuid, nil, nil) && !owns(sessionA, nil, "", ""))

// MARK: - 2. The modes a plan approval leaves plan mode into

section("2. The modes a plan approval leaves plan mode into (PlanApprovalModes)")
let modes283 = ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"]
check("accept edits is claude's acceptEdits", PlanApprovalModes.acceptEdits(in: modes283) == "acceptEdits")
check("ask-before-edits is the mode a newer claude lists as manual",
      PlanApprovalModes.askBeforeEdits(in: modes283) == "manual")
check("…or an older claude's default", PlanApprovalModes.askBeforeEdits(in: ["default", "plan"]) == "default")
check("no acceptEdits listed: one plain approval", PlanApprovalModes.acceptEdits(in: ["default", "plan"]) == nil)
check("neither spelling listed: the chip is left alone", PlanApprovalModes.askBeforeEdits(in: ["plan"]) == nil)

// MARK: - 3. The real bridge and the real approver.py, without claude

let mcpDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["APPROVAL_HARNESS_MCP_DIR"]!,
                 isDirectory: true)
let approverPath = mcpDir.appendingPathComponent("approver.py").path
let bridge = MCPBridge()
bridge.isApprovalFocused = { _ in true }   // never post a notification from a harness
do {
    try bridge.ensureRuntime()
} catch {
    print("FAIL  the real MCPBridge would not start: \(error)")
    exit(1)
}
let socketPath = mcpDir.appendingPathComponent("approver.sock").path

section("3. The bridge's answer as claude receives it (real MCPBridge → real approver.py)")
do {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", approverPath]
    var env = ProcessInfo.processInfo.environment
    env["SIPAI_APPROVER_SOCKET"] = socketPath
    env["SIPAI_SESSION_ID"] = draftUuid
    p.environment = env
    let stdin = Pipe(), stdout = Pipe()
    p.standardInput = stdin
    p.standardOutput = stdout
    p.standardError = FileHandle.nullDevice
    try p.run()
    func call(_ id: Int, _ tool: String, _ input: [String: Any]) -> Data {
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call",
                                  "params": ["name": "approve",
                                             "arguments": ["tool_name": tool, "input": input]]]
        return (try! JSONSerialization.data(withJSONObject: msg)) + Data("\n".utf8)
    }
    let planInput: [String: Any] = ["plan": "# Harness plan\n\n1. Do it.\n",
                                    "planFilePath": "/tmp/plans/harness.md"]
    stdin.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8) + Data("\n".utf8))
    stdin.fileHandleForWriting.write(call(2, "ExitPlanMode", planInput))
    stdin.fileHandleForWriting.write(call(3, "ExitPlanMode", planInput))
    stdin.fileHandleForWriting.write(call(4, "Write", ["file_path": "/tmp/x", "content": "y"]))
    try? stdin.fileHandleForWriting.close()
    // Answer the three the way the plan card and the permission card do.
    let answers: [(MCPVerdict, String?, String?)] = [
        (.allow, nil, "acceptEdits"),                       // Approve and accept edits
        (.deny, MCPBridge.keepPlanningMessage, nil),        // Keep planning
        (.allow, nil, nil),                                 // a plain Allow
    ]
    var seen: [MCPApprovalRequest] = []
    for (verdict, message, mode) in answers {
        let arrived = await waitUntil(10) { !bridge.pending.isEmpty }
        guard arrived, let req = bridge.pending.first else {
            check("request \(seen.count + 1) reached the bridge", false)
            break
        }
        seen.append(req)
        bridge.resolve(requestId: req.id, verdict: verdict, message: message, setMode: mode)
    }
    _ = await waitUntil(10) { !p.isRunning }
    if p.isRunning { p.terminate() }
    let text = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    var results: [Int: [String: Any]] = [:]
    for line in text.split(separator: "\n") {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = obj["id"] as? Int,
              let result = obj["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let inner = content.first?["text"] as? String,
              let decoded = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any]
        else { continue }
        results[id] = decoded
    }
    check("a request carries the child's SIPAI_SESSION_ID as it was spawned (the draft's uuid)",
          seen.first?.taskUuid == draftUuid && seen.first?.sessionId == nil,
          "got session \(seen.first?.sessionId ?? "nil"), uuid \(seen.first?.taskUuid ?? "nil")")
    check("the plan arrives whole in the request (plan + planFilePath)",
          (seen.first?.toolInput["plan"] as? String)?.hasPrefix("# Harness plan") == true
            && seen.first?.toolInput["planFilePath"] as? String == "/tmp/plans/harness.md")
    let approve = results[2] ?? [:]
    let perms = approve["updatedPermissions"] as? [[String: Any]]
    check("Approve and accept edits: allow, with claude's setMode acceptEdits for the session",
          approve["behavior"] as? String == "allow"
            && perms?.count == 1
            && perms?.first?["type"] as? String == "setMode"
            && perms?.first?["mode"] as? String == "acceptEdits"
            && perms?.first?["destination"] as? String == "session",
          "got \(approve)")
    check("…and the input unchanged (claude refuses an allow without updatedInput)",
          (approve["updatedInput"] as? [String: Any])?["plan"] as? String == "# Harness plan\n\n1. Do it.\n")
    let keep = results[3] ?? [:]
    check("Keep planning: deny, carrying the words the model reads",
          keep["behavior"] as? String == "deny" && keep["message"] as? String == MCPBridge.keepPlanningMessage,
          "got \(keep)")
    let plain = results[4] ?? [:]
    check("a plain Allow carries no permission change",
          plain["behavior"] as? String == "allow" && plain["updatedPermissions"] == nil,
          "got \(plain)")
} catch {
    check("approver.py could be started", false, "\(error)")
}

// MARK: - 4. The real claude, end to end, token-free

func findClaude() -> String? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = path.split(separator: ":").map { String($0) + "/claude" }
        + [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

struct Scenario {
    let dir: URL
    let claude: Process
    let server: Process
    let stdoutFile: URL
    var sessionId: String? {
        guard let text = try? String(contentsOf: stdoutFile, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               obj["type"] as? String == "system", obj["subtype"] as? String == "init",
               let sid = obj["session_id"] as? String { return sid }
        }
        return nil
    }
    var recordedToolResults: [String] {
        let rec = dir.appendingPathComponent("rec")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: rec.path))?.sorted() ?? []
        var out: [String] = []
        for f in files {
            guard let data = try? Data(contentsOf: rec.appendingPathComponent(f)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = obj["body"] as? [String: Any],
                  let messages = body["messages"] as? [[String: Any]] else { continue }
            for m in messages {
                guard let blocks = m["content"] as? [[String: Any]] else { continue }
                for b in blocks where b["type"] as? String == "tool_result" {
                    if let s = b["content"] as? String { out.append(s) }
                    if let parts = b["content"] as? [[String: Any]] {
                        out.append(parts.compactMap { $0["text"] as? String }.joined())
                    }
                }
            }
        }
        return out
    }
    func stop() {
        if claude.isRunning { claude.terminate() }
        if server.isRunning { server.terminate() }
    }
}

/// One claude turn over the fake endpoint, under a throwaway config
/// directory, wired to the REAL bridge exactly as AgentRunner wires it:
/// `argsForClaude()` + `environmentOverlay(sessionIdOrTaskUuid:)`.
@MainActor
func startTurn(_ name: String, claudePath: String, mode: String, identity: String,
               steps: [[String: Any]], config: URL? = nil, resume: String? = nil,
               cwd: URL? = nil) throws -> Scenario {
    let dir = work.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("rec"),
                                            withIntermediateDirectories: true)
    let runDir = cwd ?? dir.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    let cfg = config ?? dir.appendingPathComponent("cfg", isDirectory: true)
    try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
    let stepsFile = dir.appendingPathComponent("steps.json")
    try JSONSerialization.data(withJSONObject: steps).write(to: stepsFile)

    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    server.arguments = ["python3", here.appendingPathComponent("plan_server.py").path,
                        dir.appendingPathComponent("rec").path, stepsFile.path]
    let serverOut = Pipe()
    server.standardOutput = serverOut
    server.standardError = FileHandle.nullDevice
    try server.run()
    var portLine = Data()
    while !portLine.contains(0x0A) {
        let chunk = serverOut.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        portLine.append(chunk)
    }
    let port = String(decoding: portLine, as: UTF8.self)
        .replacingOccurrences(of: "PORT=", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

    let stdoutFile = dir.appendingPathComponent("stdout.jsonl")
    FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
    let claude = Process()
    claude.executableURL = URL(fileURLWithPath: claudePath)
    var args = ["-p", "Plan or do the harness task.", "--output-format", "stream-json", "--verbose",
                "--model", "claude-sonnet-4-5", "--permission-mode", mode]
    args += bridge.argsForClaude()
    if let resume { args += ["--resume", resume] }
    claude.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["CLAUDE_CONFIG_DIR"] = cfg.path
    env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:\(port)"
    env["ANTHROPIC_API_KEY"] = "sk-ant-harness-junk"
    for (k, v) in bridge.environmentOverlay(sessionIdOrTaskUuid: identity) { env[k] = v }
    claude.environment = env
    claude.currentDirectoryURL = runDir
    claude.standardInput = FileHandle.nullDevice
    claude.standardOutput = try FileHandle(forWritingTo: stdoutFile)
    claude.standardError = FileHandle.nullDevice
    try claude.run()
    return Scenario(dir: dir, claude: claude, server: server, stdoutFile: stdoutFile)
}

section("4. The real claude over a fake endpoint, through the real bridge (no tokens)")
if let claudePath = findClaude() {
    note("claude: \(claudePath)")
    // 4a. A FIRST turn (the child is spawned with the draft's uuid).
    let firstFile = work.appendingPathComponent("first/work/first.txt")
    do {
        let s = try startTurn("first", claudePath: claudePath, mode: "default", identity: draftUuid,
                              steps: [["name": "Write",
                                       "input": ["file_path": firstFile.path, "content": "first\n"]]])
        defer { s.stop() }
        let asked = await waitUntil(90) { !bridge.pending.isEmpty || !s.claude.isRunning }
        let req = bridge.pending.first
        check("4a. a first-turn edit reaches the bridge", asked && req != nil)
        if let req {
            let sid = s.sessionId
            check("4a. …after claude has already announced its session id", sid != nil && sid != "")
            check("4a. …tagged with the draft's uuid only — never the session id (the child's env is fixed)",
                  req.taskUuid == draftUuid && req.sessionId == nil,
                  "got session \(req.sessionId ?? "nil"), uuid \(req.taskUuid ?? "nil")")
            check("4a. the transcript's filter now draws its card for the runner (session id + uuid)",
                  bridge.pending(forSession: sid, taskUuid: draftUuid).contains { $0.id == req.id })
            check("4a. negative control: the pre-fix filter would draw NOTHING (the reported hang)",
                  !preFixFilter(req, sessionId: sid, taskUuid: draftUuid))
            bridge.resolve(requestId: req.id, verdict: .allow)
            _ = await waitUntil(60) { !s.claude.isRunning }
            check("4a. allowed, the edit lands",
                  (try? String(contentsOf: firstFile, encoding: .utf8)) == "first\n")
            // 4b. The same session RESUMED: now the child carries the session id.
            if let sid {
                let secondFile = work.appendingPathComponent("first/work/second.txt")
                let r = try startTurn("resumed", claudePath: claudePath, mode: "default", identity: sid,
                                      steps: [["name": "Write",
                                               "input": ["file_path": secondFile.path, "content": "second\n"]]],
                                      config: s.dir.appendingPathComponent("cfg"),
                                      resume: sid, cwd: s.dir.appendingPathComponent("work"))
                defer { r.stop() }
                _ = await waitUntil(90) { !bridge.pending.isEmpty || !r.claude.isRunning }
                if let req2 = bridge.pending.first {
                    check("4b. a resumed turn's request is tagged with the session id",
                          req2.sessionId == sid && req2.taskUuid == nil)
                    check("4b. …and is drawn for the session",
                          bridge.pending(forSession: sid, taskUuid: draftUuid).contains { $0.id == req2.id })
                    bridge.resolve(requestId: req2.id, verdict: .allow)
                    _ = await waitUntil(60) { !r.claude.isRunning }
                } else {
                    check("4b. a resumed turn's edit reaches the bridge", false)
                }
            }
        }
    } catch {
        check("4a. the first turn could be started", false, "\(error)")
    }

    // 4c. Plan mode, approved with accept edits.
    let implFile = work.appendingPathComponent("plan-approve/work/impl.txt")
    do {
        let s = try startTurn("plan-approve", claudePath: claudePath, mode: "plan", identity: otherUuid,
                              steps: [["name": "Write", "input": ["file_path": "{PLAN_FILE}",
                                                                  "content": "# Harness plan\n\n1. Write impl.txt.\n"]],
                                      ["name": "ExitPlanMode", "input": [String: Any]()],
                                      ["name": "Write", "input": ["file_path": implFile.path, "content": "done\n"]]])
        defer { s.stop() }
        _ = await waitUntil(90) { !bridge.pending.isEmpty || !s.claude.isRunning }
        if let req = bridge.pending.first {
            check("4c. the planning turn's approval is ExitPlanMode, and the plan-file write never asked",
                  req.toolName == MCPBridge.planApprovalTool)
            check("4c. …carrying the plan claude read back from its plan file",
                  (req.toolInput["plan"] as? String)?.contains("Write impl.txt") == true
                    && ((req.toolInput["planFilePath"] as? String) ?? "").hasSuffix(".md"))
            check("4c. …and it is drawn for its (first-turn) runner",
                  bridge.pending(forSession: s.sessionId, taskUuid: otherUuid).contains { $0.id == req.id })
            bridge.resolve(requestId: req.id, verdict: .allow, setMode: "acceptEdits")
            var askedAgain = false
            _ = await waitUntil(60) {
                if !bridge.pending.isEmpty { askedAgain = true }
                return askedAgain || !s.claude.isRunning
            }
            if askedAgain, let extra = bridge.pending.first {
                bridge.resolve(requestId: extra.id, verdict: .deny)
            }
            check("4c. approved with accept edits, claude's next edit does NOT ask", !askedAgain)
            _ = await waitUntil(30) { !s.claude.isRunning }
            check("4c. …and lands", (try? String(contentsOf: implFile, encoding: .utf8)) == "done\n")
            check("4c. …with claude told the plan is approved",
                  s.recordedToolResults.contains { $0.hasPrefix("User has approved your plan") })
        } else {
            check("4c. the planning turn's ExitPlanMode reaches the bridge", false)
        }
    } catch {
        check("4c. the planning turn could be started", false, "\(error)")
    }

    // 4d. Plan mode, keep planning.
    do {
        let s = try startTurn("plan-keep", claudePath: claudePath, mode: "plan", identity: draftUuid,
                              steps: [["name": "Write", "input": ["file_path": "{PLAN_FILE}",
                                                                  "content": "# Harness plan\n"]],
                                      ["name": "ExitPlanMode", "input": [String: Any]()]])
        defer { s.stop() }
        _ = await waitUntil(90) { !bridge.pending.isEmpty || !s.claude.isRunning }
        if let req = bridge.pending.first {
            bridge.resolve(requestId: req.id, verdict: .deny, message: MCPBridge.keepPlanningMessage)
            _ = await waitUntil(60) { !s.claude.isRunning }
            check("4d. Keep planning: the model reads the card's words verbatim as the tool's result",
                  s.recordedToolResults.contains(MCPBridge.keepPlanningMessage))
        } else {
            check("4d. the planning turn's ExitPlanMode reaches the bridge", false)
        }
    } catch {
        check("4d. the planning turn could be started", false, "\(error)")
    }
} else {
    print("  SKIP  claude is not installed")
}

// MARK: - 5. The wiring, read from the sources

section("5. The wiring (read from the shipping sources)")
let view = source("SipAI/Views/Chat/AgentSessionView.swift")
let bridgeSource = source("SipAI/Models/MCPBridge.swift")
let app = source("SipAI/SipAIApp.swift")
let rendering = source("SipAI/Utilities/AgentRendering.swift")
let approver = source("SipAI/Resources/approver.py")
check("anchor: the sources were read", !view.isEmpty && !bridgeSource.isEmpty && !app.isEmpty)

let filter = body(of: "private var approvalsForRunner: [MCPApprovalRequest] {", in: view)
check("the card filter asks the bridge's one rule, with the runner's uuid beside its session id",
      filter.contains("mcpBridge.pending(forSession: runner.sessionId,")
        && filter.contains("taskUuid: runner.taskUuidForBridge)"))
check("…and no longer matches the session id alone", !filter.contains("return req.sessionId == sid"))
check("Stop's cleanup uses the same rule",
      body(of: "func cancelPending(sessionId: String?, taskUuid: String?) {", in: bridgeSource)
        .contains("belongs(req, toSession: sessionId, taskUuid: taskUuid)"))
let focusHook = body(of: "mcpBridge.isApprovalFocused = { [weak bridge = mcpBridge] req in", in: app)
check("the notification hook resolves a first-turn request to its session",
      focusHook.contains("bridge?.owningSessionId(of: req)"))
// The alias is registered on system.init, but the pane flips from the
// draft to the session only once the transcript file lands: in between,
// a request resolves to a session id the pane does not show yet, and
// only the draft's uuid says the user is looking at it.
check("…and still judges the DRAFT on screen by its uuid when the session id is not the open one",
      focusHook.contains("appState.openAgentSessionId == sid {\n                            return true")
        && focusHook.contains("return runner.taskUuidForBridge == tu"))
check("…and so does the notification click", app.contains("bridge?.alias[taskUuid]"))

let dispatch = body(of: "private func approvalCard(_ req: MCPApprovalRequest,", in: view)
check("ExitPlanMode gets the plan card, everything else the permission card",
      dispatch.contains("req.toolName == MCPBridge.planApprovalTool")
        && dispatch.contains("planApprovalCard(") && dispatch.contains("toolApprovalCard("))
let card = body(of: "private func planApprovalCard(_ req: MCPApprovalRequest,", in: view)
check("the plan card draws the plan from the request", card.contains("req.toolInput[\"plan\"]")
        && card.contains("MarkdownRenderer.render(plan)"))
check("Keep planning denies with the words the model reads",
      card.contains("verdict: .deny") && card.contains("message: MCPBridge.keepPlanningMessage"))
check("the plan card offers no Always buttons", !card.contains("allowAlways") && !card.contains("denyAlways"))
let approve = body(of: "private func approvePlan(_ req: MCPApprovalRequest, acceptEdits: Bool) {", in: view)
check("an approval passes claude's accept-edits switch and moves the chip",
      approve.contains("setMode: switchTo") && approve.contains("onPlanApproved("))
let leave = body(of: "private func leavePlanMode(to target: String?) {", in: view)
check("the chip moves only off Plan, for this session alone — never the sticky pick",
      leave.contains("launchOptions.permissionMode == \"plan\"")
        && leave.contains("applySeededOptions(next)")
        && leave.contains("setAgentSessionLaunchOptions(next, for: id)")
        && !leave.contains("setAgentLaunchOptions("))
check("the transcript's ExitPlanMode row shows the plan, not a clipped JSON dump",
      rendering.contains("case \"ExitPlanMode\":\n            rows = renderPlanInput(input)"))
check("approver.py passes SipAI's mode switch to claude as updatedPermissions",
      approver.contains("body[\"updatedPermissions\"] = updated_permissions"))

let catalog = source("SipAI/Resources/Localizable.xcstrings")
if let data = catalog.data(using: .utf8),
   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let strings = root["strings"] as? [String: Any] {
    for key in ["Plan ready for review", "Keep planning", "Approve, ask before edits",
                "Approve and accept edits", "Approve plan", "Saved as %@",
                "A plan is ready for your review"] {
        let entry = strings[key] as? [String: Any]
        let zh = ((entry?["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any]
        check("catalog: \"\(key)\" has a zh-Hans value", (zh?["value"] as? String)?.isEmpty == false)
    }
} else {
    check("catalog: Localizable.xcstrings parses", false)
}

// MARK: - 6. Two copies of SipAI share mcp/

/// Whether a client can reach a listener at the socket path right now.
func connectable(_ path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count <= capacity else { return false }
    withUnsafeMutablePointer(to: &addr.sun_path) { p in
        p.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
            bytes.withUnsafeBufferPointer { src in _ = memcpy(dst, src.baseAddress, bytes.count) }
        }
    }
    return withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
}

// Every copy of SipAI on a Mac — the installed one, a build run from
// Xcode, `end-to-end.sh`'s staged copy — binds the same mcp/approver.sock.
// A quit that deletes the path whoever holds it lets a copy that never
// ran a turn (the staged copy Sparkle relaunches) cut the running copy's
// approval cards off until that copy is relaunched. Two bridges in one
// process stand in for the two copies.
section("6. Two copies share mcp/ — a quit removes only the socket that copy bound")
do {
    let original = SocketFileIdentity(path: socketPath)
    check("the running bridge's socket is at the path, and answers",
          original != nil && connectable(socketPath))

    let idle = MCPBridge()
    idle.shutdown()
    check("a copy that bound nothing quits: the running copy's socket stays, and answers",
          SocketFileIdentity(path: socketPath) == original && connectable(socketPath))

    // A second copy's first agent turn takes the path over — the half
    // that is still open: the first copy's own cards stop from then on.
    let taker = MCPBridge()
    taker.isApprovalFocused = { _ in true }
    try taker.ensureRuntime()
    let taken = SocketFileIdentity(path: socketPath)
    check("a second copy's first turn binds a socket of its own at the path",
          taken != nil && taken != original)

    bridge.shutdown()
    check("then the FIRST copy quits: the second copy's socket stays, and answers",
          SocketFileIdentity(path: socketPath) == taken && connectable(socketPath))

    taker.shutdown()
    check("the copy that bound the socket still removes it when it quits",
          SocketFileIdentity(path: socketPath) == nil)
} catch {
    check("section 6 ran", false, "\(error)")
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
