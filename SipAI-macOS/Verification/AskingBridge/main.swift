// AskingBridge harness — see run.sh for what it pins and why.
//
// Arguments: <source-root> <harness-dir>
// Environment: ASKING_HARNESS_MCP_DIR (read by Stubs.swift).
//
// Synchronous on purpose: the peer delivers to the main queue, and a
// top level that awaits runs inside a main-queue block, where pumping the
// run loop cannot drain that queue. Async work runs in Tasks, and the
// run loop is pumped until it lands.
import Foundation
import Darwin

setvbuf(stdout, nil, _IONBF, 0)
let sourceRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let here = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

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

func pump(_ seconds: TimeInterval) {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

@discardableResult
func pumpUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return condition()
}

final class Box<T> { var value: T? }

/// A pipe whose read end is non-blocking: what the peer writes is read
/// back from it.
func makePipe() -> (read: Int32, write: Int32) {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { fatalError("pipe failed") }
    _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL, 0) | O_NONBLOCK)
    return (fds[0], fds[1])
}

/// Every JSON object written to `fd` so far.
func written(_ fd: Int32, settle: TimeInterval = 0.15) -> [[String: Any]] {
    pump(settle)
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        data.append(buf, count: n)
    }
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
}

func source(_ relative: String) -> String {
    (try? String(contentsOf: sourceRoot.appendingPathComponent(relative), encoding: .utf8)) ?? ""
}

func occurrences(_ needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

/// The text of a declaration from `start` to its closing brace.
func body(_ text: String, _ start: String) -> String {
    guard let a = text.range(of: start),
          let open = text[a.lowerBound...].firstIndex(of: "{") else { return "" }
    var depth = 0
    var i = open
    while i < text.endIndex {
        if text[i] == "{" { depth += 1 }
        if text[i] == "}" { depth -= 1; if depth == 0 { return String(text[a.lowerBound...i]) } }
        i = text.index(after: i)
    }
    return ""
}

// MARK: - 1. The peer, pure

section("1. The JSON-RPC peer (JSONRPCLinePeer) — pure")

check("a line a terminal mangled still decodes: control bytes in front, a carriage return behind",
      (JSONRPCLinePeer.decode("\u{4}\u{8}\u{8}{\"a\":1}\r") as? [String: Any])?["a"] as? Int == 1)
check("…and a line that is not JSON decodes to nothing",
      JSONRPCLinePeer.decode("Loading model…") == nil)

do {
    let out = makePipe()
    let peer = JSONRPCLinePeer(label: "h1", writing: out.write, deliver: { $0() })
    var unparsed: [String] = []
    var notes: [(String, Any?)] = []
    peer.onUnparsed = { unparsed.append($0) }
    peer.onNotification = { notes.append(($0, $1)) }

    peer.receive(line: "warming up\r")
    check("a line that is not JSON is handed on as text and never answered",
          unparsed == ["warming up"] && written(out.read).isEmpty)

    peer.receive(line: #"{"jsonrpc":"2.0","id":7,"method":"nosuch","params":{}}"#)
    peer.receive(line: #"{"jsonrpc":"2.0","id":"x-9","method":"alsonot"}"#)
    let refusals = written(out.read)
    check("a request nobody handles is refused -32601 at once, echoing a NUMBER id as a number",
          refusals.first.map { ($0["id"] as? Int) == 7
            && (($0["error"] as? [String: Any])?["code"] as? Int) == -32601 } == true)
    check("…and a STRING id as a string",
          refusals.dropFirst().first.map { ($0["id"] as? String) == "x-9"
            && (($0["error"] as? [String: Any])?["code"] as? Int) == -32601 } == true)

    var asked: [JSONRPCLinePeer.Inbound] = []
    peer.handle("ask") { asked.append($0) }
    peer.receive(line: #"{"jsonrpc":"2.0","id":3,"method":"ask","params":{"q":"may I?"}}"#)
    check("a request with a handler reaches it, params and all",
          asked.count == 1 && (asked.first?.params as? [String: Any])?["q"] as? String == "may I?")
    asked.first?.reply(["ok": true])
    asked.first?.reply(["ok": false])
    asked.first?.fail(code: 1, message: "late")
    let replies = written(out.read)
    check("an inbound request is answered exactly once — a second reply and a late failure write nothing",
          replies.count == 1 && (replies.first?["id"] as? Int) == 3
            && ((replies.first?["result"] as? [String: Any])?["ok"] as? Bool) == true)

    peer.receive(line: #"[{"jsonrpc":"2.0","method":"tick","params":{"n":1}},{"jsonrpc":"2.0","method":"tick","params":{"n":2}}]"#)
    check("a batch line delivers each message, in order",
          notes.map(\.0) == ["tick", "tick"]
            && notes.compactMap { ($0.1 as? [String: Any])?["n"] as? Int } == [1, 2])

    // Requests of ours, answered out of order, with an error, and with a
    // lenient server's string id.
    let a = Box<Any>(), b = Box<Any>(), c = Box<Error>(), d = Box<Bool>()
    Task { a.value = try? await peer.request("first", params: ["x": 1]) }
    Task { b.value = try? await peer.request("second") }
    Task {
        do { _ = try await peer.request("third") } catch { c.value = error }
    }
    Task {
        do { _ = try await peer.request("fourth"); d.value = true } catch { d.value = false }
    }
    pump(0.2)
    let sent = written(out.read)
    let ids = Dictionary(uniqueKeysWithValues: sent.compactMap { m -> (String, Int)? in
        guard let method = m["method"] as? String, let id = m["id"] as? Int else { return nil }
        return (method, id)
    })
    check("our requests go out with an id each, params defaulting to an object",
          ids.count == 4 && sent.contains { ($0["method"] as? String) == "second" && $0["params"] is [String: Any] })
    if let i1 = ids["first"], let i2 = ids["second"], let i3 = ids["third"], let i4 = ids["fourth"] {
        peer.receive(line: #"{"jsonrpc":"2.0","id":\#(i2),"result":"two"}"#)
        peer.receive(line: #"{"jsonrpc":"2.0","id":\#(i1),"result":{"one":1}}"#)
        peer.receive(line: #"{"jsonrpc":"2.0","id":\#(i3),"error":{"code":-32600,"message":"turn not found"}}"#)
        peer.receive(line: #"{"jsonrpc":"2.0","id":"\#(i4)","result":null}"#)
        pumpUntil(2) { a.value != nil && b.value != nil && c.value != nil && d.value != nil }
        check("answers out of order reach their own requests",
              (a.value as? [String: Any])?["one"] as? Int == 1 && b.value as? String == "two")
        check("an error answer throws the server's code and words",
              (c.value as? JSONRPCLinePeer.Failure) == .remote(code: -32600, message: "turn not found"))
        check("a server that echoes our number as a string still answers it (a null result is nil)",
              d.value == true)
    } else {
        check("the four requests were written", false, "\(sent)")
    }

    let timedOut = Box<Error>()
    Task {
        do { _ = try await peer.request("slow", timeout: 0.2) } catch { timedOut.value = error }
    }
    pumpUntil(2) { timedOut.value != nil }
    check("a request with a timeout fails with .timedOut when nothing answers",
          (timedOut.value as? JSONRPCLinePeer.Failure) == .timedOut)

    let cancelled = Box<Error>()
    let task = Task {
        do { _ = try await peer.request("abandoned") } catch { cancelled.value = error }
    }
    pump(0.1)
    task.cancel()
    pumpUntil(2) { cancelled.value != nil }
    check("a cancelled task stops waiting with .cancelled",
          (cancelled.value as? JSONRPCLinePeer.Failure) == .cancelled)

    let pending = Box<Error>()
    Task {
        do { _ = try await peer.request("never") } catch { pending.value = error }
    }
    pump(0.1)
    _ = written(out.read)
    peer.receiveEOF()
    pumpUntil(2) { pending.value != nil }
    check("the child's output ending fails what still waits — .closed",
          { if case .closed? = pending.value as? JSONRPCLinePeer.Failure { return true }; return false }())
    let after = Box<Error>()
    Task {
        do { _ = try await peer.request("too late") } catch { after.value = error }
    }
    pumpUntil(2) { after.value != nil }
    check("…a request after that fails at once, and is never written",
          { if case .closed? = after.value as? JSONRPCLinePeer.Failure { return true }; return false }()
            && written(out.read).isEmpty)
    peer.receive(line: #"{"jsonrpc":"2.0","id":11,"method":"ask","params":{}}"#)
    check("…and a request arriving after the end reaches no handler",
          asked.count == 1)
    close(out.read)
}

// Ordering through the main queue: a notification that arrived before
// the answer that ends a turn is handled before that answer is awaited.
do {
    let out = makePipe()
    let peer = JSONRPCLinePeer(label: "h1b", writing: out.write,
                               deliver: JSONRPCLinePeer.deliverOnMainQueue)
    var log: [String] = []
    peer.onNotification = { method, _ in log.append(method) }
    let done = Box<Bool>()
    Task {
        _ = try? await peer.request("prompt")
        log.append("answered")
        done.value = true
    }
    pump(0.1)
    let id = written(out.read).first?["id"] as? Int ?? -1
    peer.receive(line: #"{"jsonrpc":"2.0","method":"chunk","params":{}}"#)
    peer.receive(line: #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
    pumpUntil(2) { done.value == true }
    check("delivered through the main queue, the turn's last chunk lands before the answer that ends it",
          log == ["chunk", "answered"], "\(log)")
    peer.close(reason: "done")
    close(out.read)
}

// MARK: - 2. The peer over a real child

section("2. The peer over a real child, read by the REAL drain loop")

/// One conversation with rpc_child.py: stdout through a PTY (`crlf`) or
/// a pipe, stdin a pipe.
func converse(crlf: Bool) {
    let label = crlf ? "PTY" : "pipe"
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    child.arguments = ["python3", here.appendingPathComponent("rpc_child.py").path] + (crlf ? ["--crlf"] : [])
    let stdinPipe = Pipe()
    child.standardInput = stdinPipe
    var readFD: Int32 = -1
    var slaveFD: Int32 = -1
    var outPipe: Pipe? = nil
    if crlf {
        var master: Int32 = 0, slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            check("openpty", false); return
        }
        // A terminal echoes and translates; only the output side is a tty here.
        child.standardOutput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        readFD = master
        slaveFD = slave
    } else {
        let p = Pipe()
        outPipe = p
        child.standardOutput = p
        readFD = p.fileHandleForReading.fileDescriptor
    }
    child.standardError = FileHandle.nullDevice
    do { try child.run() } catch { check("\(label): rpc_child.py started", false, "\(error)"); return }
    if slaveFD >= 0 { close(slaveFD) }
    let writeFD = dup(stdinPipe.fileHandleForWriting.fileDescriptor)
    try? stdinPipe.fileHandleForWriting.close()
    _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL, 0) | O_NONBLOCK)

    let peer = JSONRPCLinePeer(label: "h2", writing: writeFD,
                               deliver: JSONRPCLinePeer.deliverOnMainQueue)
    var answered: [String: Any]? = nil
    peer.onNotification = { method, params in
        if method == "answered" { answered = params as? [String: Any] }
    }
    peer.handle("ask") { $0.reply(["granted": true]) }
    let ended = Box<Bool>()
    let source = Extracted.makeDrainingLineSource(
        fd: readFD, label: "h2.read", owner: nil,
        onLine: { peer.receive(line: $0) },
        onEnd: { _ in
            peer.receiveEOF()
            DispatchQueue.main.async { ended.value = true }
        })
    source.resume()

    pumpUntil(5) { answered != nil }
    check("\(label): the child's request reached our handler, and our reply reached the child",
          answered?["granted"] as? Bool == true)
    let pong = Box<Any>()
    Task { pong.value = try? await peer.request("ping", params: ["n": 42]) }
    pumpUntil(5) { pong.value != nil }
    check("\(label): our request reached the child, and its answer came back to the request",
          ((pong.value as? [String: Any])?["pong"] as? [String: Any])?["n"] as? Int == 42)

    let late = Box<Error>()
    Task {
        do { _ = try await peer.request("unanswered") } catch { late.value = error }
    }
    pump(0.2)
    peer.finishWriting()
    pumpUntil(5) { ended.value == true && !child.isRunning }
    check("\(label): closing the child's stdin ends it — exit 0 — and its output reaches EOF",
          ended.value == true && !child.isRunning && child.terminationStatus == 0)
    pumpUntil(2) { late.value != nil }
    check("\(label): what still waited when the output ended failed",
          { if case .closed? = late.value as? JSONRPCLinePeer.Failure { return true }; return false }())
    _ = outPipe
}
converse(crlf: false)
converse(crlf: true)

// A reply to a child that has gone: EPIPE, never SIGPIPE.
do {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    let stdinPipe = Pipe()
    child.standardInput = stdinPipe
    child.standardOutput = FileHandle.nullDevice
    try? child.run()
    child.waitUntilExit()
    let writeFD = dup(stdinPipe.fileHandleForWriting.fileDescriptor)
    try? stdinPipe.fileHandleForWriting.close()
    let peer = JSONRPCLinePeer(label: "h2b", writing: writeFD,
                               deliver: JSONRPCLinePeer.deliverOnMainQueue)
    let big = String(repeating: "x", count: 1_000_000)
    peer.notify("flood", params: ["data": big])
    pumpUntil(3) { peer.isClosed }
    check("a write to a child that has gone fails with EPIPE and closes the conversation — this process lives",
          peer.isClosed)
}

// MARK: - 4. The bridge with requests from an agent's own protocol

section("4. The real MCPBridge, with requests from codex's and kimi's own protocols")

let sessionA = "019a0000-0000-7000-8000-00000000000a"
let sessionB = "session_b"
let draftUuid = "0123456789abcdef0123456789abcdef"

let bridge = MainActor.assumeIsolated { MCPBridge() }
var policy: MCPQuestionPolicy = .ask
MainActor.assumeIsolated {
    bridge.isApprovalFocused = { _ in true }   // never post a notification from a harness
    bridge.questionPolicy = { _ in policy }
}

let commandChoices = [
    CardChoice(id: "accept", label: "Yes, proceed", role: .accept),
    CardChoice(id: "acceptForSession", label: "Yes, and don't ask again for this command in this session",
               role: .acceptForSession),
    CardChoice(id: "decline", label: "No, continue without running it", role: .decline),
]

@MainActor
func permission(_ agent: String, session: String?, uuid: String?,
                choices: [CardChoice] = commandChoices,
                respond: @escaping @MainActor (CardResolution) -> Void) -> MCPApprovalRequest {
    MCPApprovalRequest(
        agentKey: agent, sessionId: session, taskUuid: uuid, toolName: "Shell",
        presentation: .permission(PermissionCardContent(
            prompt: "Would you like to run the following command?",
            preview: .command("git push", cwd: "/tmp/x", reason: "publish"),
            choices: choices)),
        respond: respond)
}

let form = AgentQuestionForm(questions: [
    .init(text: "Which database?", header: "DB",
          options: [.init(label: "Postgres", description: "", preview: nil),
                    .init(label: "SQLite", description: "", preview: nil)],
          multiSelect: false, id: "q1", allowsOther: true),
], offersSkip: true, offersChat: false)

@MainActor
func question(_ agent: String, session: String?, form: AgentQuestionForm?,
              respond: @escaping @MainActor (CardResolution) -> Void) -> MCPApprovalRequest {
    MCPApprovalRequest(agentKey: agent, sessionId: session, taskUuid: nil,
                       toolName: "request_user_input", presentation: .question,
                       question: form, respond: respond)
}

MainActor.assumeIsolated {
    var got: [CardResolution] = []
    let p = permission("codex", session: sessionA, uuid: draftUuid) { got.append($0) }
    bridge.enqueue(p)
    check("an agent's permission request becomes a card",
          bridge.pending.contains { $0 === p } && !p.isFromApprover && p.permissionContent != nil)
    check("…owned under the one rule: by its session id, by its draft uuid",
          bridge.belongs(p, toSession: sessionA, taskUuid: nil)
            && bridge.belongs(p, toSession: nil, taskUuid: draftUuid)
            && bridge.owningSessionId(of: p) == sessionA)
    check("…with an id of the bridge's own, never the protocol's",
          p.id.hasPrefix("codex:") && p.id.count > 30)
    bridge.choose(requestId: p.id, optionId: "acceptForSession")
    check("a choice reaches the agent's driver: the agent's own answer id",
          got == [.chose("acceptForSession")] && !bridge.pending.contains { $0 === p })
    bridge.choose(requestId: p.id, optionId: "accept")
    bridge.cancelPending(sessionId: sessionA, taskUuid: draftUuid)
    check("…exactly once: a second choice and a later Stop say nothing more", got.count == 1)
    check("…and an agent's \"for this session\" is the agent's to remember — nothing in SipAI's exact-call cache",
          bridge.cache.isEmpty)

    var claudeWay: [CardResolution] = []
    let q = permission("kimi", session: sessionB, uuid: nil) { claudeWay.append($0) }
    bridge.enqueue(q)
    bridge.resolve(requestId: q.id, verdict: .allow)
    check("claude's resolve() never answers another agent's card", claudeWay.isEmpty && bridge.pending.contains { $0 === q })
    bridge.withdraw(requestId: q.id)
    bridge.cancelPending(sessionId: sessionB, taskUuid: nil)
    check("a card the agent resolved itself is withdrawn without an answer, and Stop finds nothing",
          claudeWay.isEmpty && !bridge.pending.contains { $0 === q })

    var undrawable: [CardResolution] = []
    bridge.enqueue(permission("codex", session: sessionA, uuid: nil, choices: []) { undrawable.append($0) })
    check("a card with no answers to draw is declined at once — it never holds a turn",
          undrawable == [.declined(.unreadable)] && bridge.pending.isEmpty)

    // Questions: the policy, Non-stop first.
    for (p, expect) in [(MCPQuestionPolicy.nonStop, CardResolution.declined(.nonStop)),
                        (.unanswerable, .declined(.unanswerable))] {
        policy = p
        var said: [CardResolution] = []
        bridge.enqueue(question("codex", session: sessionA, form: form) { said.append($0) })
        check("a question under \(p) is answered \(expect) with no card", said == [expect] && bridge.pending.isEmpty)
    }
    policy = .nonStop
    var nonStopUnreadable: [CardResolution] = []
    bridge.enqueue(question("kimi", session: sessionB, form: nil) { nonStopUnreadable.append($0) })
    check("Non-stop's answer wins over an unreadable form", nonStopUnreadable == [.declined(.nonStop)])
    policy = .ask
    var unreadable: [CardResolution] = []
    bridge.enqueue(question("kimi", session: sessionB, form: nil) { unreadable.append($0) })
    check("a form the card cannot draw is declined as unreadable", unreadable == [.declined(.unreadable)])

    var answers: [CardResolution] = []
    let asked = question("codex", session: sessionA, form: form) { answers.append($0) }
    bridge.enqueue(asked)
    let perm = permission("codex", session: sessionA, uuid: nil) { _ in }
    bridge.enqueue(perm)
    check("a question is drawn as a question card", bridge.pending.contains { $0 === asked } && asked.isQuestion)
    bridge.chatAboutQuestion(requestId: asked.id, answers: [:])
    check("\"Chat about this\" is claude's alone — another agent's question stays", answers.isEmpty)
    bridge.declineQuestions(sessionId: sessionA, taskUuid: nil)
    check("Non-stop turned on declines the question on screen, and leaves the permission card",
          answers == [.declined(.nonStop)] && bridge.pending.contains { $0 === perm })

    var answered: [CardResolution] = []
    let again = question("codex", session: sessionA, form: form) { answered.append($0) }
    bridge.enqueue(again)
    let pick = AgentQuestionAnswer(labels: ["SQLite"])
    bridge.answerQuestion(requestId: again.id, answers: ["Which database?": pick])
    check("an answer reaches the driver keyed by question text", answered == [.answered(["Which database?": pick])])
    var skipped: [CardResolution] = []
    let third = question("codex", session: sessionA, form: form) { skipped.append($0) }
    bridge.enqueue(third)
    bridge.skipQuestion(requestId: third.id)
    check("Skip reaches the driver as .skipped", skipped == [.skipped])

    // A question the agent asked WITHOUT stopping (codex's
    // request_user_input_async): its card goes when the turn that asked
    // ends — withdrawn — or at Stop — cancelled — and what the user had
    // started on it comes back for the session's message box, as Codex's
    // own terminal moves an unsent answer into its composer. A card the
    // turn waits on hands nothing back: its turn cannot end around it.
    func asyncQuestion(_ session: String,
                       respond: @escaping @MainActor (CardResolution) -> Void) -> MCPApprovalRequest {
        MCPApprovalRequest(agentKey: "codex", sessionId: session, taskUuid: nil,
                           toolName: "request_user_input_async", presentation: .question,
                           question: form, turnWaits: false, respond: respond)
    }
    var typed = AgentQuestionAnswer()
    typed.otherPicked = true
    typed.otherText = "Postgres, with the read replica"
    var leftSaid: [CardResolution] = []
    let left = asyncQuestion(sessionA) { leftSaid.append($0) }
    bridge.enqueue(left)
    bridge.setQuestionDraft(AgentQuestionDraft(answers: ["Which database?": typed]), for: left.id)
    let handedBack = bridge.withdraw(requestId: left.id)
    check("a card the turn did not wait on, withdrawn at the turn's end, hands back the answer started on it — its question quoted above it",
          handedBack == "> Which database?\n\nPostgres, with the read replica"
            && leftSaid.isEmpty && !bridge.pending.contains { $0 === left },
          "\(String(describing: handedBack)) \(leftSaid)")
    let untouched = asyncQuestion(sessionA) { _ in }
    bridge.enqueue(untouched)
    check("…and nothing when nothing was put on it",
          bridge.withdraw(requestId: untouched.id) == nil)
    let waited = question("codex", session: sessionA, form: form) { _ in }
    bridge.enqueue(waited)
    bridge.setQuestionDraft(AgentQuestionDraft(answers: ["Which database?": typed]), for: waited.id)
    check("…and nothing for a card the turn waits on, which the agent resolved itself",
          bridge.withdraw(requestId: waited.id) == nil)
    var stoppedSaid: [CardResolution] = []
    let stopped = asyncQuestion(sessionA) { stoppedSaid.append($0) }
    bridge.enqueue(stopped)
    bridge.setQuestionDraft(AgentQuestionDraft(answers: ["Which database?": AgentQuestionAnswer(labels: ["SQLite"])]),
                            for: stopped.id)
    var permSaid: [CardResolution] = []
    bridge.enqueue(permission("codex", session: sessionA, uuid: nil) { permSaid.append($0) })
    let atStop = bridge.cancelPending(sessionId: sessionA, taskUuid: nil)
    check("Stop hands back the option picked on such a card, and answers every card .cancelled, once",
          atStop == ["> Which database?\n\nSQLite"] && stoppedSaid == [.cancelled] && permSaid == [.cancelled],
          "\(atStop) \(stoppedSaid) \(permSaid)")
    let nonStopped = asyncQuestion(sessionA) { _ in }
    bridge.enqueue(nonStopped)
    bridge.setQuestionDraft(AgentQuestionDraft(answers: ["Which database?": typed]), for: nonStopped.id)
    bridge.declineQuestions(sessionId: sessionA, taskUuid: nil)
    check("…and Non-stop turned on keeps nothing: the user chose not to answer",
          bridge.cancelPending(sessionId: sessionA, taskUuid: nil).isEmpty
            && !bridge.pending.contains { $0 === nonStopped })

    // Stop: only the runner's own cards.
    var aSaid: [CardResolution] = [], bSaid: [CardResolution] = []
    bridge.enqueue(permission("codex", session: sessionA, uuid: nil) { aSaid.append($0) })
    bridge.enqueue(permission("kimi", session: sessionB, uuid: nil) { bSaid.append($0) })
    bridge.cancelPending(sessionId: sessionA, taskUuid: nil)
    check("Stop answers its own runner's cards .cancelled, and only those",
          aSaid.contains(.cancelled) && bSaid.isEmpty && bridge.pending.contains { $0.sessionId == sessionB })

    // A responder that asks again from inside its answer.
    var second: MCPApprovalRequest? = nil
    let first = permission("kimi", session: sessionB, uuid: nil) { _ in
        let follow = permission("kimi", session: sessionB, uuid: nil) { _ in }
        second = follow
        bridge.enqueue(follow)
    }
    bridge.enqueue(first)
    bridge.choose(requestId: first.id, optionId: "accept")
    check("a driver that enqueues from inside its responder keeps its new card",
          second.map { s in bridge.pending.contains { $0 === s } } == true)

    // Claude's own requests through the same door are untouched.
    let claude = MCPApprovalRequest(id: "r-claude", sessionId: sessionA, taskUuid: nil,
                                    toolName: "Bash", toolInput: ["command": "ls"])
    check("a claude approver request is still claude's: no presentation, its own question rule",
          claude.isFromApprover && claude.agentKey == "claude_code" && !claude.asksQuestion)

    // Words.
    let t = MCPBridge.notificationText(for: permission("codex", session: sessionA, uuid: nil) { _ in },
                                       agent: "Codex")
    check("a notification names the agent under its label — never a name spelled in the bridge",
          t.title == "Codex permission needed" && t.body.contains("git push"))
    check("…and claude's title still reads as it did under its default label",
          MCPBridge.notificationText(for: claude, agent: "Claude Code").title == "Claude Code permission needed")
    let plan = MCPApprovalRequest(agentKey: "kimi", sessionId: sessionB, taskUuid: nil, toolName: "ExitPlanMode",
                                  presentation: .plan(PlanCardContent(plan: "# Plan", filePath: nil, choices: commandChoices)),
                                  respond: { _ in })
    check("a kimi plan review is a plan card — and a notification says a plan is ready",
          plan.isPlanCard && MCPBridge.notificationText(for: plan, agent: "Kimi Code").body == "A plan is ready for your review")

    // Quit.
    var atQuit: [CardResolution] = []
    bridge.enqueue(permission("codex", session: sessionA, uuid: nil) { atQuit.append($0) })
    bridge.shutdown()
    var afterQuit: [CardResolution] = []
    bridge.enqueue(permission("codex", session: sessionA, uuid: nil) { afterQuit.append($0) })
    check("a quit answers every card .cancelled, and a card asked for after it is cancelled at once",
          atQuit.contains(.cancelled) && afterQuit == [.cancelled] && bridge.pending.isEmpty)
}

// MARK: - 5. Forms from another agent

section("5. Forms from another agent (AgentQuestionForm)")

func q(_ text: String, _ labels: [String], other: Bool = true, multi: Bool = false) -> AgentQuestionForm.Question {
    .init(text: text, header: "", options: labels.map { .init(label: $0, description: "", preview: nil) },
          multiSelect: multi, allowsOther: other)
}
check("no questions → nil", AgentQuestionForm(questions: [], offersSkip: true, offersChat: false) == nil)
check("two questions with one text → nil",
      AgentQuestionForm(questions: [q("A?", ["x", "y"]), q("A?", ["z"])], offersSkip: true, offersChat: false) == nil)
check("a question with no options and no free answer → nil",
      AgentQuestionForm(questions: [q("Name?", [], other: false)], offersSkip: true, offersChat: false) == nil)
check("a duplicated label → nil",
      AgentQuestionForm(questions: [q("A?", ["x", "x"])], offersSkip: true, offersChat: false) == nil)
let freeOnly = AgentQuestionForm(questions: [q("Name your branch", [])], offersSkip: true, offersChat: false)
check("a free-answer question is a form", freeOnly != nil)
if let freeOnly {
    check("…its keyboard starts on the user's own answer",
          AgentQuestionKeys.entry(for: freeOnly, page: 0, answers: [:]) == .other
            && AgentQuestionKeys.firstStop(for: freeOnly, page: 0) == .other)
    check("…and the grid offers no Chat about this when the form does not",
          AgentQuestionKeys.grid(for: freeOnly, page: 0).rows == [[.other], [.skip, .primary]])
}
let noOther = AgentQuestionForm(questions: [q("Pick", ["a", "b"], other: false)], offersSkip: false, offersChat: false)
check("a question that takes no words of the user's has no such row, and no Skip when not offered",
      noOther.map { AgentQuestionKeys.grid(for: $0, page: 0).rows } == [[.option(0)], [.option(1)], [.primary]])
let claudeForm = AgentQuestionForm(toolInput: ["questions": [[
    "question": "Which?", "header": "H", "multiSelect": false,
    "options": [["label": "a", "description": ""], ["label": "b", "description": ""]]]]])
check("claude's forms are unchanged: Other, Skip and Chat about this, every time",
      claudeForm.map { $0.offersSkip && $0.offersChat
        && AgentQuestionKeys.grid(for: $0, page: 0).rows == [[.option(0)], [.option(1)], [.other], [.skip, .chat, .primary]] } == true)
check("the words for a decline are claude's own constants",
      AgentQuestionReplies.words(for: .nonStop) == AgentQuestionReplies.nonStop
        && AgentQuestionReplies.words(for: .unreadable) == AgentQuestionReplies.unreadable
        && AgentQuestionReplies.words(for: .unanswerable) == AgentQuestionReplies.unanswerable)
check("an agent's answers are drawable only from 1 to 12 choices with unique ids",
      CardChoiceLayout.isDrawable(commandChoices) && !CardChoiceLayout.isDrawable([])
        && !CardChoiceLayout.isDrawable(commandChoices + [commandChoices[0]]))
check("Return starts on the first acceptance; Esc takes the first plain refusal",
      CardChoiceLayout.initial(commandChoices) == "accept" && CardChoiceLayout.cancel(commandChoices) == "decline")

// What a card hands back unsent, in the shape Codex's own terminal recovers
// an unsent answer into its composer (its TUI's `recovered_draft`): the
// question quoted line by line, a blank line, the answer trimmed; several
// questions a blank line apart, in the card's order.
let twoAsked = AgentQuestionForm(questions: [q("Which way?", ["Left", "Right"]), q("What budget?", [])],
                                 offersSkip: true, offersChat: false)!
func answered(_ pairs: [String: AgentQuestionAnswer]) -> AgentQuestionDraft {
    AgentQuestionDraft(answers: pairs)
}
func words(_ text: String, picked: Bool = true) -> AgentQuestionAnswer {
    var answer = AgentQuestionAnswer()
    answer.otherPicked = picked
    answer.otherText = text
    return answer
}
check("an unsent answer: the question quoted, a blank line, the answer trimmed",
      twoAsked.unsentAnswersText(answered(["What budget?": words("  Under 250  ")]))
        == "> What budget?\n\nUnder 250")
check("…a picked option is the user's answer too, and the questions go in the card's order",
      twoAsked.unsentAnswersText(answered(["What budget?": words("Under 250"),
                                           "Which way?": AgentQuestionAnswer(labels: ["Right"])]))
        == "> Which way?\n\nRight\n\n> What budget?\n\nUnder 250")
check("…words typed while no answer is chosen still come back: they were the user's",
      twoAsked.unsentAnswersText(answered(["What budget?": words("Maybe 300", picked: false)]))
        == "> What budget?\n\nMaybe 300")
check("…and where an option is chosen over typed words, the option: it is what the card would send",
      twoAsked.unsentAnswersText(answered(["Which way?": {
          var answer = words("left-ish", picked: false)
          answer.labels = ["Left"]
          return answer
      }()])) == "> Which way?\n\nLeft")
check("…and nothing at all when nothing was put in, or only blank space",
      twoAsked.unsentAnswersText(AgentQuestionDraft()) == nil
        && twoAsked.unsentAnswersText(answered(["What budget?": words("   ")])) == nil)
let multiline = AgentQuestionForm(questions: [q("First line\r\n\r\n\u{1B}[31mLast\r line?\u{1B}[0m\u{07}", [])],
                                  offersSkip: true, offersChat: false)!
check("a question of several lines: each quoted, a blank one by \">\" alone, a terminal's escapes and control characters left out (Codex's own case)",
      multiline.unsentAnswersText(answered([multiline.questions[0].text:
                                            words("  First answer line\n\nLast answer line  ")]))
        == "> First line\n>\n> Last line?\n\nFirst answer line\n\nLast answer line")
let long = String(repeating: "é", count: 300) + "?"
let longForm = AgentQuestionForm(questions: [q(long, [])], offersSkip: true, offersChat: false)!
check("a question past 512 bytes is cut on a character boundary, with \"…\" after the cut",
      longForm.unsentAnswersText(answered([long: words("yes")]))
        == "> " + String(repeating: "é", count: 256) + "…\n\nyes")

// MARK: - 6. The wiring

section("6. The wiring (read from the shipping sources)")
let runner = source("SipAI/Models/AgentRunner.swift")
let bridgeSource = source("SipAI/Models/MCPBridge.swift")
let app = source("SipAI/SipAIApp.swift")
let view = source("SipAI/Views/Chat/AgentSessionView.swift")
let composer = source("SipAI/Views/Chat/AgentComposer.swift")
let peerSource = source("SipAI/Models/JSONRPCLinePeer.swift")
let project = source("SipAI.xcodeproj/project.pbxproj")
check("anchor: the sources were read", !runner.isEmpty && !bridgeSource.isEmpty && !app.isEmpty && !peerSource.isEmpty)

check("runner: every runner holds the bridge; the approver's runtime and environment stay claude's",
      runner.contains("self.bridge = bridge\n") && !runner.contains("agentKey == \"claude_code\" ? bridge : nil")
        && occurrences("if isClaude, let bridge = bridge {", in: runner) == 2)
check("runner: a session found off the store registers its alias, as system.init does",
      body(runner, "private func adoptDiscoveredSession(").contains("bridge?.registerAlias(taskUuid: tu, sessionId: id)"))
let rpcRead = body(runner, "private func readRPCStdout(")
check("runner: a JSON-RPC child's stdout is the shared drain loop, each line handed to the peer on the reader's queue",
      rpcRead.contains("makeDrainingLineSource(") && rpcRead.contains("peer.receive(line: line)")
        && !rpcRead.contains("Task {") && rpcRead.contains("peer.receiveEOF()"))
// From the running path on: an idle runner's guard cancels its task first,
// and has no turn to interrupt.
let cancelBody = body(runner, "func cancel() {")
let runningPath = cancelBody.range(of: "if !stopRequested {").map { String(cancelBody[$0.lowerBound...]) } ?? ""
if let interrupt = runningPath.range(of: "rpc.driver.interrupt(peer: rpc.peer)"),
   let firstCancel = runningPath.range(of: "runTask?.cancel()") {
    check("runner: Stop answers the cards, then tells the agent in its own protocol, BEFORE the task is cancelled",
          runningPath.contains("cancelPendingApprovals()") && interrupt.lowerBound < firstCancel.lowerBound)
} else {
    check("runner: Stop tells the agent in its own protocol", false)
}
check("runner: a turn's end closes its conversation, whichever caller ends it",
      body(runner, "private func finalizeTurn(").contains("rpc.peer.close(reason: \"the turn ended\")"))
// A driver returns when its protocol is done with the turn — and also when
// the conversation ends under it, which it leaves to the runner to say.
// Counting both as "done" ends a turn whose child died with no row at all.
let rpcTurnBody = body(runner, "private func runRPCTurn(")
check("runner: a turn's protocol counts as done only while its conversation is open — a child gone under it is reported, whatever its exit code",
      rpcTurnBody.contains("if !peer.isClosed { self?.noteRPCTurnCompleted(token: token) }")
        && !rpcTurnBody.contains("if exitCode == 0 { return nil }"))
check("runner: a draft's turn files its cards under a uuid of its own, as a headless first turn does",
      rpcTurnBody.contains("if sessionId?.isEmpty ?? true, taskUuid == nil {"))
check("runner: a send that supersedes a turn over JSON-RPC closes its conversation",
      runner.contains("startTurn(text: text, options: options, images: images, command: nil)")
        && body(runner, "    private func startTurn(").contains("rpc.peer.close(reason: \"superseded by a new send\")"))
// Stop cancels the task a side conversation runs in, and `Task.sleep`
// returns at once in a cancelled task: a wait built on it spins.
let sideBody = body(runner, "private func runSideConversation(")
check("runner: a side conversation waits for its child with a pause that holds in a cancelled task",
      sideBody.contains("await Self.pause(") && !sideBody.contains("Task.sleep"))
check("runner: a side conversation's reader holds its descriptor open until it has seen the end of the stream",
      sideBody.contains("let readHandle = stdoutPipe.fileHandleForReading")
        && sideBody.contains("withExtendedLifetime(readHandle) {}"))
check("runner: a child is given the time its DRIVER says it needs to exit once its stdin has closed",
      rpcTurnBody.contains("self?.boundRPCChildExit(token: token, grace: turn.exitGrace)")
        && source("SipAI/Models/AgentRPCTurn.swift").contains("var exitGrace: TimeInterval { get }"))
check("runner: a turn that has asked the user something has been heard from — no stall notice over a card",
      body(runner, "private func armStallNotice()").contains("self.userWait == TurnPause(),"))
check("runner: a transcript found with a session's id is taken up with its tailer, whichever agent wrote it",
      body(runner, "private func adoptDiscoveredSession(").contains("adoptSessionFile(fileURL, id: id)"))
check("runner: the peer is handed the main queue, in order",
      runner.contains("deliver: JSONRPCLinePeer.deliverOnMainQueue"))
check("peer: Foundation alone, and a gone child is EPIPE, never SIGPIPE",
      peerSource.contains("import Foundation") && !peerSource.contains("import SwiftUI")
        && !peerSource.contains("import AppKit") && peerSource.contains("F_SETNOSIGPIPE"))

check("bridge: the one responder call is deliver's",
      occurrences("req.respond?(", in: bridgeSource) == 1
        && body(bridgeSource, "private func deliver(").contains("req.respond?(resolution)"))
check("bridge: the exact-call cache is written for claude's approver alone",
      body(bridgeSource, "private func finish(").contains("if req.isFromApprover,"))
check("app: the focus hook and the notification click never make a runner for an unsent draft",
      occurrences("agentManager.cachedRunner(forDraft: draft)", in: app) == 2
        && !app.contains("agentManager.runner(forDraft:"))
let dispatch = body(view, "private func approvalCard(")
if let mine = dispatch.range(of: "req.permissionContent"),
   let claudes = dispatch.range(of: "req.toolName == MCPBridge.planApprovalTool") {
    check("view: an agent's own cards are dispatched FIRST — a kimi ExitPlanMode never reaches claude's plan card",
          mine.lowerBound < claudes.lowerBound && dispatch.contains("AgentPermissionCard(")
            && dispatch.contains("AgentPlanReviewCard("))
} else {
    check("view: the dispatch draws an agent's own cards", false)
}
check("view: a send in an asking mode the CLI cannot run is held — the backstop, for every send the view makes",
      body(view, "private var sendIsHeld: Bool").contains("AskingModeGate.hold(agentKey: sessionAgentKey")
        && body(view, "private func handleSend()").contains("if sendIsHeld { return }")
        && body(view, "private func createSessionBranch(").contains("guard !text.isEmpty, !branching, !sendIsHeld,")
        && view.contains("branching: branching || sendIsHeld,"))
check("view: the draft→session flip never reads the transcript over the live rows — a first turn already over keeps its error row and its unrecorded answer",
      view.contains("reload(migratedFromDraft: true)")
        && body(view, "private func reload(migratedFromDraft: Bool = false)")
            .contains("!TranscriptSeam.readsTranscript(draftFlip: migratedFromDraft,")
        && source("SipAI/Utilities/TranscriptSeam.swift")
            .contains("!(draftFlip && !historyOnScreen && (turnRunning || liveRows > 0))"))
check("view: a card's mode switch asks the adoption rule — an answer that only ends the planning leaves a chip off Plan alone",
      body(view, "private func adoptSessionMode(_ target: String)")
        .contains("AgentAskingMode.adoption(of: target,")
        && source("SipAI/Models/AgentLaunchOptions.swift")
            .contains("return (current == codexPlan || current == kimiPlan) ? .set(nil) : .keep"))
check("composer: Send waits on a held asking pick; the switch follows the mode; a schedule carries the chip's own mode and Non-stop",
      composer.contains("&& !chatOnlyPending && askingHold == nil")
        && composer.contains("if nonStopOffered {")
        && body(composer, "private var effectiveScheduleMode: String?")
            .contains("AgentAskingMode.taskFileMode(agentKey: agentKey, mode: options.permissionMode,")
        && !composer.contains("neverAsking(")
        && composer.contains("nonStop: scheduleNonStop,"))
check("composer: a task scheduled over attached files is refused with words — its prompt cannot hold them",
      body(composer, "private func createScheduledTask()").contains("if chatOnlyActive, !attachments.isEmpty {"))
check("task card: the Mode picker reads and writes the task FILE's mode through the one rule a run reads it by",
      { let panel = source("SipAI/Views/Chat/ScheduledTaskPanel.swift")
        return panel.contains("AgentAskingMode.taskPickerValue(")
            && panel.contains("AgentAskingMode.taskFileMode(agentKey: taskAgentKey,")
            && panel.contains("let mode = AgentAskingMode.taskMode(agentKey: def.agent, fileMode: def.mode)")
            && !panel.contains("AgentAskingMode.normalized(") }())
check("scheduler: the mode gate is asked before anything is spawned, and a task's mode is read as its file spells it",
      { let scheduler = source("SipAI/Models/ScheduledTaskScheduler.swift")
        let fire = body(scheduler, "private func fire(_ def: ScheduledTaskDefinition, slot: Date?, showRun: Bool,")
        guard let gate = fire.range(of: "switch Self.modeVerdict("),
              let spawn = fire.range(of: "agents.runner(forDraft: draft)") else { return false }
        return gate.lowerBound < spawn.lowerBound
            && body(scheduler, "static func modeVerdict(_ def: ScheduledTaskDefinition, agent: String,")
                .contains("AgentAskingMode.taskMode(agentKey: agent, fileMode: def.mode)")
            && fire.contains("self.fire(def, slot: slot, showRun: showRun, skills: resolved, modeWaited: true)") }())
check("runner: a Default turn whose CLI version cannot be read ends with words, never headless on a guess — only a fixed codex mode, which codex exec enforces the same, runs headless then",
      { let runner = source("SipAI/Models/AgentRunner.swift")
        return runner.contains("guard verdict != .pending || fixedCodexMode else {")
            && runner.contains("AgentAskingMode.unreadVersionMessage(agentName: agentDisplayName)")
            && runner.contains("Task { await AgentCLIUpdateMonitor.shared.refreshLocal() }") }())
for file in ["AskingCards.swift", "JSONRPCLinePeer.swift", "AgentRPCTurn.swift", "UnsentAnswers.swift"] {
    check("project: \(file) is built into the app", occurrences("\(file) in Sources", in: project) == 2)
}

// What the user had started on a card the turn did not wait on comes back
// when the card goes — kept by the runner, put in the box by the page that
// shows the session: at once when it is on screen, and when the page comes
// back to the session (the router tears the page down on every detour).
let hostWithdraw = body(runner, "        func withdraw(cardId: String) {")
check("runner: a card the driver withdraws hands the runner back what the user had started on it",
      hostWithdraw.contains("bridge?.withdraw(requestId: cardId)") && hostWithdraw.contains("keepUnsentAnswers("))
check("runner: Stop and a child gone hand back what was started on such cards, through the one cancel",
      body(runner, "private func cancelPendingApprovals()").contains("keepUnsentAnswers("))
check("page: the session's box takes the answers handed back — live, and when the page comes back to the session",
      body(view, "private func takeUnsentAnswersIntoBox()").contains("UnsentAnswers.boxText(")
        && view.contains(".onReceive(unsentAnswersPublisher)")
        && body(view, "private func restoreComposerDraft()").contains("takeUnsentAnswersIntoBox()")
        && body(view, "private func stashAndRestoreComposerDraft()").contains("takeUnsentAnswersIntoBox()"))

let catalogText = source("SipAI/Resources/Localizable.xcstrings")
if let data = catalogText.data(using: .utf8),
   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let strings = root["strings"] as? [String: Any] {
    for key in ["%@ permission needed", "Never Ask", "Ask When Needed", "Type your answer",
                "… %lld more lines", "%@ never stops to ask questions in this mode.",
                "Checking whether %@ offers %@. Send waits for the answer — pick another mode to send now.",
                "%@ isn’t available in the installed %@. Pick another mode to send.",
                "This mode isn’t available in the installed %@. Pick another mode and send again."] {
        let entry = strings[key] as? [String: Any]
        let zh = ((entry?["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any]
        check("catalog: \"\(key)\" has a zh-Hans value", (zh?["value"] as? String)?.isEmpty == false)
    }
    check("catalog: the title that named claude outright is gone", strings["Claude Code permission needed"] == nil)
} else {
    check("catalog: Localizable.xcstrings parses", false)
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
