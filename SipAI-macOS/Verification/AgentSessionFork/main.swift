// Headless verification for session branching. See run.sh.
//
// Not part of the app target — this directory sits outside SipAI/, and
// the Xcode project lists its sources explicitly.
//
// Same discipline as ScheduledTaskScheduler.decide and TranscriptFollow:
// each writer's rules are pure functions of their inputs, so they are
// exercised without an AgentManager, a subprocess or a window. The
// REAL scanners and writers are compiled (Stubs.swift stands in for the
// app types around them), and the token-free live sections drive the
// REAL codex and kimi over throwaway stores.

import Foundation

var failures = 0
var checks = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    checks += 1
    print((ok ? "  ok   " : "  FAIL ") + label + (detail.isEmpty ? "" : " — \(detail)"))
    if !ok { failures += 1 }
}
func skip(_ label: String, _ why: String) {
    print("  SKIP " + label + " — " + why)
}

let env = ProcessInfo.processInfo.environment
let fixtures = URL(fileURLWithPath: env["SIPAI_FORK_FIXTURES"] ?? "fixtures", isDirectory: true)
let sourceRoot = URL(fileURLWithPath: env["SIPAI_FORK_SRC"] ?? "../..", isDirectory: true)
let liveTurns = env["SIPAI_FORK_LIVE"] == "1"
let fm = FileManager.default

/// A CLI on this machine, looked up the way a shell would plus the
/// places the app's own detection knows.
func binary(_ name: String) -> String? {
    var dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
    let home = fm.homeDirectoryForCurrentUser.path
    dirs += ["\(home)/.local/bin", "\(home)/.kimi-code/bin", "/opt/homebrew/bin",
             "/usr/local/bin", "\(home)/.npm-global/bin"]
    for dir in dirs where fm.isExecutableFile(atPath: dir + "/" + name) {
        return dir + "/" + name
    }
    return nil
}

/// Paths compared by what they resolve to: NSTemporaryDirectory() is
/// `/var/folders/…` and a CLI reports `/private/var/folders/…`.
func real(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

/// Kimi's workspace bucket for a working directory — `wd_<lowercased
/// leaf>_<first 12 hex of sha256(real path)>` — measured against three
/// buckets on this machine. The throwaway store has to spell it kimi's
/// way for `kimi fork` to find the session by its cwd.
func kimiBucket(for cwd: URL) -> String {
    let path = real(cwd)
    let digest = sha256Hex(path)
    return "wd_" + cwd.lastPathComponent.lowercased() + "_" + String(digest.prefix(12))
}
func sha256Hex(_ s: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    p.arguments = ["-a", "256"]
    let i = Pipe(), o = Pipe()
    p.standardInput = i; p.standardOutput = o
    try! p.run()
    i.fileHandleForWriting.write(Data(s.utf8))
    try? i.fileHandleForWriting.close()
    let out = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return String(out.prefix(64))
}

func lines(of url: URL) -> [String] {
    (try! String(contentsOf: url, encoding: .utf8))
        .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

func object(_ line: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
}

func userTexts(_ items: [AgentSessionHistoryItem]) -> [String] {
    items.compactMap { if case .userText(let t) = $0.kind { return t }; return nil }
}
func assistantTexts(_ items: [AgentSessionHistoryItem]) -> [String] {
    items.compactMap { if case .assistantText(let t) = $0.kind { return t }; return nil }
}

/// Run a CLI to completion with a bounded wait; returns stdout.
func run(_ path: String, _ args: [String], cwd: URL? = nil,
         environment: [String: String] = [:], timeout: TimeInterval = 240) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    var e = ProcessInfo.processInfo.environment
    for (k, v) in environment { e[k] = v }
    p.environment = e
    if let cwd { p.currentDirectoryURL = cwd }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    var data = Data()
    let reader = DispatchQueue(label: "harness.read")
    let done = DispatchSemaphore(value: 0)
    reader.async {
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
    if p.isRunning { p.terminate() }
    p.waitUntilExit()
    _ = done.wait(timeout: .now() + 5)
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

// ====================================================================
print("CLAUDE — AgentSessionFork")
// ---------- 1. the per-line rule ----------
print("verdict()")
let cut = "CUT-UUID"
let newId = "NEW-SESSION"

check("stops at the cut record",
      AgentSessionFork.verdict(forLine: #"{"uuid":"CUT-UUID","type":"user","sessionId":"old"}"#,
                               cutAtRecordUuid: cut, newSessionId: newId) == .stop)

check("drops the parent's ai-title",
      AgentSessionFork.verdict(forLine: #"{"type":"ai-title","aiTitle":"Parent name","sessionId":"old"}"#,
                               cutAtRecordUuid: cut, newSessionId: newId) == .drop)

// The name a rename writes, in either app. It OUTRANKS the generated
// ai-title, so a branch that inherited one would sit under its parent's
// name for good — past anything claude later generates for it.
check("drops the parent's custom-title",
      AgentSessionFork.verdict(forLine: #"{"type":"custom-title","customTitle":"Parent name","sessionId":"old"}"#,
                               cutAtRecordUuid: cut, newSessionId: newId) == .drop)

check("drops unparseable lines",
      AgentSessionFork.verdict(forLine: #"{"type":"user","sessionId":"#,
                               cutAtRecordUuid: cut, newSessionId: newId) == .drop)

check("drops blank lines",
      AgentSessionFork.verdict(forLine: "   ", cutAtRecordUuid: cut, newSessionId: newId) == .drop)

if case .keep(let rewritten) = AgentSessionFork.verdict(
    forLine: #"{"uuid":"a","parentUuid":"b","type":"assistant","sessionId":"old-id","cwd":"/x/y"}"#,
    cutAtRecordUuid: cut, newSessionId: newId) {
    let obj = try! JSONSerialization.jsonObject(with: rewritten.data(using: .utf8)!) as! [String: Any]
    check("rewrites sessionId", obj["sessionId"] as? String == newId)
    check("keeps uuid", obj["uuid"] as? String == "a")
    check("keeps parentUuid (chain intact)", obj["parentUuid"] as? String == "b")
    check("keeps unrelated fields", obj["cwd"] as? String == "/x/y")
    check("does not escape slashes", rewritten.contains("/x/y"), rewritten)
} else {
    check("rewrites a normal record", false)
}

// ---------- 1b. scheduled-run marker ----------
print("scheduled-task marker")
func keptObject(_ line: String) -> [String: Any]? {
    guard case .keep(let out) = AgentSessionFork.verdict(
        forLine: line, cutAtRecordUuid: cut, newSessionId: newId),
        let d = out.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}
func contentString(_ o: [String: Any]?) -> String {
    guard let m = o?["message"] as? [String: Any] else { return "<no message>" }
    if let s = m["content"] as? String { return s }
    if let a = m["content"] as? [Any] {
        return a.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined(separator: "|")
    }
    return "<none>"
}

check("strips the marker from string content",
      contentString(keptObject(#"{"uuid":"z","type":"user","sessionId":"o","message":{"role":"user","content":"<scheduled-task name=\"daily\"></scheduled-task>Check the logs"}}"#))
        == "Check the logs")

check("strips the marker from block content",
      contentString(keptObject(#"{"uuid":"z","type":"user","sessionId":"o","message":{"role":"user","content":[{"type":"text","text":"<scheduled-task name=\"daily\"></scheduled-task>Check the logs"}]}}"#))
        == "Check the logs")

check("leaves the record alone when the marker is all there is",
      contentString(keptObject(#"{"uuid":"z","type":"user","sessionId":"o","message":{"role":"user","content":"<scheduled-task name=\"daily\"></scheduled-task>"}}"#))
        == #"<scheduled-task name="daily"></scheduled-task>"#)

check("leaves ordinary user records untouched",
      contentString(keptObject(#"{"uuid":"z","type":"user","sessionId":"o","message":{"role":"user","content":"just a message"}}"#))
        == "just a message")

check("does not touch assistant records that mention the tag",
      contentString(keptObject(#"{"uuid":"z","type":"assistant","sessionId":"o","message":{"role":"assistant","content":"<scheduled-task name=\"x\"></scheduled-task>quoted"}}"#))
        == #"<scheduled-task name="x"></scheduled-task>quoted"#)

// ---------- 2. prefix validation ----------
print("prefixHoldsConversation()")
check("rejects bookkeeping only", !AgentSessionFork.prefixHoldsConversation([
    #"{"type":"queue-operation"}"#, #"{"type":"mode"}"#]))
check("rejects a lone user record", !AgentSessionFork.prefixHoldsConversation([
    #"{"type":"user","message":{"role":"user","content":"hi"}}"#]))
check("rejects synthetic-only assistants", !AgentSessionFork.prefixHoldsConversation([
    #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
    #"{"type":"assistant","message":{"model":"<synthetic>"}}"#]))
check("rejects a tool_result masquerading as a user turn",
      !AgentSessionFork.prefixHoldsConversation([
        #"{"type":"user","toolUseResult":{"x":1}}"#,
        #"{"type":"assistant","message":{"model":"claude-opus-5"}}"#]))
check("accepts a real exchange", AgentSessionFork.prefixHoldsConversation([
    #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
    #"{"type":"assistant","message":{"model":"claude-opus-5"}}"#]))

// ---------- 3. naming ----------
print("branchTitle()")
check("collapses whitespace",
      AgentSessionFork.branchTitle(from: "fix   the\n\nparser  bug") == "fix the parser bug")
check("caps at 50 with an ellipsis",
      AgentSessionFork.branchTitle(from: String(repeating: "x", count: 80)).count == 50)
check("strips wrappers",
      AgentSessionFork.branchTitle(from: "<system-reminder>noise</system-reminder>real text") == "real text")
check("falls back when nothing is left",
      !AgentSessionFork.branchTitle(from: "<system-reminder>x</system-reminder>").isEmpty)


// ====================================================================
print("")
print("CODEX — CodexSessionFork, pure rules")
let codexFixture = fixtures.appendingPathComponent("codex-two-turns.jsonl")
let codexLines = lines(of: codexFixture)
let codexParentId = "01a03c71-38e6-7421-9d7e-5b56062e1f11"
let turn1 = "01a03c71-391d-76b3-8bcb-8910867572e4"
let turn2 = "01a03c71-9d50-7140-83cd-25d8b7fa9c28"

print("turn markers")
let seq = CodexSessionFork.turnSequence(lines: codexLines)
check("turnSequence yields both turns in order", seq == [turn1, turn2], "\(seq)")
check("turnEnded reads task_complete",
      codexLines.contains { CodexSessionScanner.turnEnded(object($0)) == turn2 })
check("turnEnded reads turn_aborted",
      CodexSessionScanner.turnEnded(object(
        #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"T","reason":"interrupted"}}"#)) == "T")
check("previousTurn: turn 2 forks through turn 1",
      CodexSessionFork.previousTurn(before: turn2, in: seq) == turn1)
check("previousTurn: the first turn has nothing above it",
      CodexSessionFork.previousTurn(before: turn1, in: seq) == nil)
check("previousTurn: an unknown turn answers nil",
      CodexSessionFork.previousTurn(before: "nope", in: seq) == nil)

print("history rows carry the turn id")
var decoder = CodexSessionScanner.RolloutDecoder()
var rows: [AgentSessionHistoryItem] = []
for l in codexLines { rows.append(contentsOf: decoder.items(forLine: l)) }
let userRows = rows.filter { if case .userText = $0.kind { return true }; return false }
check("two user rows", userRows.count == 2, "\(userRows.count)")
check("first user row is turn 1", userRows.first?.recordUuid == turn1)
check("second user row is turn 2", userRows.last?.recordUuid == turn2)
check("context records are not rows",
      userTexts(rows) == ["Reply with exactly: ONE", "Reply with exactly: TWO"], "\(userTexts(rows))")
check("assistant rows", assistantTexts(rows) == ["ONE", "TWO"], "\(assistantTexts(rows))")

print("the request and the answer")
let req = CodexSessionFork.request(threadId: "T", lastTurnId: "L")!
let reqObj = object(req)
check("request carries the shared answer id", (reqObj["id"] as? Int) == CodexAppServerCall.answerId)
check("request method is thread/fork", reqObj["method"] as? String == "thread/fork")
let params = reqObj["params"] as? [String: Any] ?? [:]
check("request names threadId + lastTurnId, excludes turns",
      params["threadId"] as? String == "T" && params["lastTurnId"] as? String == "L"
        && params["excludeTurns"] as? Bool == true, "\(params)")
check("request is one line", !req.contains("\n"))
check("request never uses the experimental beforeTurnId", !req.contains("beforeTurnId"))
let success = object(#"{"id":2,"result":{"thread":{"id":"NEW","forkedFromId":"OLD","path":"/tmp/x/rollout-x-NEW.jsonl"}}}"#)
check("outcome reads the new thread and its path",
      CodexSessionFork.outcome(from: success)
        == .forked(.init(threadId: "NEW", rolloutURL: URL(fileURLWithPath: "/tmp/x/rollout-x-NEW.jsonl"))))
let refusal = object(#"{"error":{"code":-32600,"message":"thread/fork.beforeTurnId requires experimentalApi capability"},"id":2}"#)
check("outcome carries codex's own refusal",
      CodexSessionFork.outcome(from: refusal) == .refused("thread/fork.beforeTurnId requires experimentalApi capability"))
check("no answer is unavailable", CodexSessionFork.outcome(from: nil) == .unavailable)

print("the fork reference")
check("a plain rollout has no origin", CodexSessionScanner.forkOrigin(ofHeadLine: codexLines[0]) == nil)
let forkHead = #"{"timestamp":"2026-09-12T16:13:39.611Z","ordinal":14,"type":"session_meta","payload":{"session_id":"A","id":"A","forked_from_id":"P","forked_from_ordinal_exclusive":14,"cwd":"/tmp/x","source":"vscode"}}"#
check("a fork head names parent + exclusive ordinal",
      CodexSessionScanner.forkOrigin(ofHeadLine: forkHead) == .init(parentId: "P", exclusiveOrdinal: 14))
let subagentHead = #"{"timestamp":"x","ordinal":0,"type":"session_meta","payload":{"id":"S","forked_from_id":"P","subagent_history_start_ordinal":40,"source":{"subagent":{"thread_spawn":{"parent_thread_id":"P"}}}}}"#
check("a subagent head (forked_from_id, no exclusive ordinal) is NOT a fork origin",
      CodexSessionScanner.forkOrigin(ofHeadLine: subagentHead) == nil)
check("ordinal read off the line head", CodexSessionScanner.ordinal(ofLine: Substring(codexLines[15]), index: 99) == 15)
check("ordinal falls back to the index without one",
      CodexSessionScanner.ordinal(ofLine: #"{"type":"x"}"#, index: 7) == 7)

// A throwaway store to splice in: the fixture as the parent, then a
// fork A referencing it, then a fork B of A — codex's shape, synthetic
// turns, and the same filename convention the lookup relies on.
let store = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sipai-fork-splice-\(UUID().uuidString)", isDirectory: true)
let storeSessions = store.appendingPathComponent("sessions/2026/09/12", isDirectory: true)
try! fm.createDirectory(at: storeSessions, withIntermediateDirectories: true)
let parentURL = storeSessions.appendingPathComponent("rollout-2026-08-25T22-00-48-\(codexParentId).jsonl")
try! Data(codexLines.joined(separator: "\n").utf8 + [0x0A]).write(to: parentURL)

func syntheticTurn(ordinal: Int, turnId: String, ask: String, answer: String) -> [String] {
    [
        #"{"timestamp":"t","ordinal":\#(ordinal),"type":"event_msg","payload":{"type":"task_started","turn_id":"\#(turnId)"}}"#,
        #"{"timestamp":"t","ordinal":\#(ordinal + 1),"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(ask)"}]}}"#,
        #"{"timestamp":"t","ordinal":\#(ordinal + 2),"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(answer)"}]}}"#,
        #"{"timestamp":"t","ordinal":\#(ordinal + 3),"type":"event_msg","payload":{"type":"task_complete","turn_id":"\#(turnId)"}}"#,
    ]
}
func writeFork(id: String, parent: String, exclusive: Int, turns: [String]) -> URL {
    let url = storeSessions.appendingPathComponent("rollout-2026-09-12T00-00-00-\(id).jsonl")
    var body = [#"{"timestamp":"t","ordinal":\#(exclusive),"type":"session_meta","payload":{"session_id":"\#(id)","id":"\#(id)","forked_from_id":"\#(parent)","forked_from_ordinal_exclusive":\#(exclusive),"cwd":"/tmp/x","source":"vscode"}}"#,
               #"{"timestamp":"t","ordinal":\#(exclusive + 1),"type":"event_msg","payload":{"type":"thread_settings_applied"}}"#]
    body += turns
    try! Data(body.joined(separator: "\n").utf8 + [0x0A]).write(to: url)
    return url
}
let forkAId = "01a09665-5972-79f1-aeb7-5f2661d987ce"
let forkA = writeFork(id: forkAId, parent: codexParentId, exclusive: 14,
                      turns: syntheticTurn(ordinal: 16, turnId: "T3", ask: "Reply with exactly: THREE", answer: "THREE"))
let forkBId = "01a09666-e252-7670-a789-84d42da88142"
let forkB = writeFork(id: forkBId, parent: forkAId, exclusive: 20,
                      turns: syntheticTurn(ordinal: 22, turnId: "T4", ask: "Reply with exactly: FOUR", answer: "FOUR"))
let sessionsRoot = store.appendingPathComponent("sessions", isDirectory: true)

print("the splice")
check("parent resolves by filename",
      CodexSessionScanner.rolloutFile(namedForId: codexParentId, root: sessionsRoot).map(real) == real(parentURL))
let historyA = CodexSessionScanner.readHistory(of: forkA, root: sessionsRoot)
check("fork A renders turn 1 then its own turn 3, never turn 2",
      userTexts(historyA) == ["Reply with exactly: ONE", "Reply with exactly: THREE"], "\(userTexts(historyA))")
check("fork A's assistant rows follow", assistantTexts(historyA) == ["ONE", "THREE"], "\(assistantTexts(historyA))")
check("inherited user row keeps the parent's turn id",
      historyA.first { if case .userText = $0.kind { return true }; return false }?.recordUuid == turn1)
let historyB = CodexSessionScanner.readHistory(of: forkB, root: sessionsRoot)
check("fork of a fork resolves up the chain: ONE, THREE, FOUR",
      userTexts(historyB) == ["Reply with exactly: ONE", "Reply with exactly: THREE", "Reply with exactly: FOUR"], "\(userTexts(historyB))")
let seqB = CodexSessionFork.turnSequence(of: forkB, root: sessionsRoot)
check("turnSequence of a fork includes inherited turns", seqB == [turn1, "T3", "T4"], "\(seqB)")
check("cut at the fork's own first turn forks through the inherited one",
      CodexSessionFork.previousTurn(before: "T3", in: CodexSessionFork.turnSequence(of: forkA, root: sessionsRoot)) == turn1)
let extentA = CodexSessionScanner.historyExtent(of: forkA, root: sessionsRoot)
let ownA = (try! fm.attributesOfItem(atPath: forkA.path))[.size] as! UInt64
check("historyExtent counts the inherited prefix", extentA > ownA, "extent \(extentA), own \(ownA)")
let bounded = CodexSessionScanner.inheritedPrefix(of: parentURL, belowOrdinal: 14, budget: 400)
check("a bounded prefix keeps the NEWEST lines under budget",
      bounded.bytes <= 400 && bounded.lines.last.map { CodexSessionScanner.ordinal(ofLine: Substring($0), index: -1) } == 13,
      "\(bounded.bytes) bytes, last ordinal \(bounded.lines.last.map { CodexSessionScanner.ordinal(ofLine: Substring($0), index: -1) } ?? -1)")
let chainBudget = CodexSessionScanner.inheritedLines(for: .init(parentId: forkAId, exclusiveOrdinal: 20), budget: 700, root: sessionsRoot)
check("the chain shares ONE budget and keeps its NEWEST lines",
      chainBudget.reduce(0) { $0 + $1.utf8.count + 1 } <= 700
        && (chainBudget.last.map { $0.contains("\"turn_id\":\"T3\"") } ?? false)
        && !chainBudget.contains { $0.contains("Reply with exactly: ONE") },
      "\(chainBudget.count) lines, last: \(chainBudget.last?.prefix(80) ?? "")")
check("turnIds streams the same sequence the line rule reads",
      CodexSessionScanner.turnIds(of: parentURL) == seq
        && CodexSessionScanner.turnIds(of: parentURL, belowOrdinal: 14) == [turn1])
check("inheritedTurnIds walks the chain: fork B inherits turn 1 then T3",
      CodexSessionScanner.inheritedTurnIds(for: .init(parentId: forkAId, exclusiveOrdinal: 20), root: sessionsRoot) == [turn1, "T3"])
check("live-row cut resolution on a fork reaches an INHERITED row's turn",
      CodexSessionFork.resolveCutPoint(matchingUserText: "Reply with exactly: ONE", in: forkA, root: sessionsRoot) == turn1)
check("live-row cut resolution on a fork prefers the fork's own newer row",
      CodexSessionFork.resolveCutPoint(matchingUserText: "Reply with exactly: THREE", in: forkA, root: sessionsRoot) == "T3")
let orphan = writeFork(id: "01a0aaaa-0000-7000-8000-000000000001", parent: "01a0bbbb-0000-7000-8000-000000000002", exclusive: 14,
                       turns: syntheticTurn(ordinal: 16, turnId: "T9", ask: "own", answer: "own answer"))
check("a missing parent yields the branch's own rows alone",
      userTexts(CodexSessionScanner.readHistory(of: orphan, root: sessionsRoot)) == ["own"])
let selfId = "01a0cccc-0000-7000-8000-000000000003"
let cyclic = writeFork(id: selfId, parent: selfId, exclusive: 20, turns: syntheticTurn(ordinal: 22, turnId: "T5", ask: "loop", answer: "loop answer"))
check("a self-referencing fork terminates at the depth cap",
      userTexts(CodexSessionScanner.readHistory(of: cyclic, root: sessionsRoot)).last == "loop")
let subURL = storeSessions.appendingPathComponent("rollout-2026-09-12T00-00-00-01a0dddd-0000-7000-8000-000000000004.jsonl")
try! Data(([subagentHead] + syntheticTurn(ordinal: 1, turnId: "S1", ask: "sub task", answer: "sub answer")).joined(separator: "\n").utf8 + [0x0A]).write(to: subURL)
check("a subagent rollout is never spliced",
      userTexts(CodexSessionScanner.readHistory(of: subURL, root: sessionsRoot)) == ["sub task"])
check("live-row cut resolution finds the newest match's turn",
      CodexSessionFork.resolveCutPoint(matchingUserText: "Reply with exactly: TWO", in: parentURL) == turn2)
check("live-row cut resolution: no match is nil",
      CodexSessionFork.resolveCutPoint(matchingUserText: "never sent", in: parentURL) == nil)

// ====================================================================
print("")
print("CODEX — the real client against the real codex (token-free)")
var codexBranchForLive: (id: String, url: URL, home: URL)? = nil
if let codex = binary("codex") {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sipai-fork-codexhome-\(UUID().uuidString)", isDirectory: true)
    let day = home.appendingPathComponent("sessions/2026/08/25", isDirectory: true)
    try! fm.createDirectory(at: day, withIntermediateDirectories: true)
    let liveParent = day.appendingPathComponent("rollout-2026-08-25T22-00-48-\(codexParentId).jsonl")
    try! fm.copyItem(at: parentURL, to: liveParent)
    // The fixture's recorded cwd; codex resolves the fork's cwd from
    // the parent, and a folder that is not there is a refusal about
    // the harness, not about the fork.
    let recordedCwd = (object(codexLines[0])["payload"] as? [String: Any])?["cwd"] as? String ?? "/tmp"
    let cwdExisted = fm.fileExists(atPath: recordedCwd)
    if !cwdExisted { try? fm.createDirectory(atPath: recordedCwd, withIntermediateDirectories: true) }
    AgentRunner.extraEnvironment["CODEX_HOME"] = home.path
    let liveRoot = home.appendingPathComponent("sessions", isDirectory: true)

    let group = DispatchGroup()
    group.enter()
    var forkResult: Result<CodexSessionFork.Result, Error>? = nil
    Task {
        do {
            forkResult = .success(try await CodexSessionFork.fork(
                rollout: liveParent, threadId: codexParentId, cutAtTurnId: turn2,
                binary: codex, root: liveRoot))
        } catch { forkResult = .failure(error) }
        group.leave()
    }
    group.wait()
    switch forkResult {
    case .success(let r)?:
        check("codex forked: a new thread with a rollout on disk",
              r.threadId != codexParentId && fm.fileExists(atPath: r.rolloutURL.path), r.rolloutURL.path)
        check("the new rollout lives under the throwaway home", real(r.rolloutURL).hasPrefix(real(home)))
        let origin = CodexSessionScanner.forkOrigin(of: r.rolloutURL)
        check("its head names the parent and an exclusive ordinal below turn 2",
              origin?.parentId == codexParentId && (origin.map { $0.exclusiveOrdinal <= 15 && $0.exclusiveOrdinal >= 14 } ?? false),
              "\(String(describing: origin))")
        let h = CodexSessionScanner.readHistory(of: r.rolloutURL, root: liveRoot)
        check("the branch reads as ONE alone — never TWO",
              userTexts(h) == ["Reply with exactly: ONE"] && assistantTexts(h) == ["ONE"], "\(userTexts(h)) / \(assistantTexts(h))")
        check("the parent's file is unchanged", (try! Data(contentsOf: liveParent)) == (try! Data(contentsOf: parentURL)))
        check("the fork's own rollout copies no prefix", lines(of: r.rolloutURL).count <= 3, "\(lines(of: r.rolloutURL).count) records")
        // Forking the fork at its inherited first turn is the
        // degenerate branch — nothing above it.
        group.enter()
        var second: Error? = nil
        Task {
            do { _ = try await CodexSessionFork.fork(rollout: r.rolloutURL, threadId: r.threadId, cutAtTurnId: turn1, binary: codex, root: liveRoot) }
            catch { second = error }
            group.leave()
        }
        group.wait()
        if case AgentSessionFork.ForkError.nothingToBranch? = second {
            check("forking the fork at its first turn is nothingToBranch", true)
        } else {
            check("forking the fork at its first turn is nothingToBranch", false, "\(String(describing: second))")
        }
        // Codex must accept a cut expressed as a turn the fork INHERITED
        // — the request the app sends when a branch is branched at its
        // own first turn. Measured through the real client and codex.
        group.enter()
        var through: [String: Any]? = nil
        Task {
            through = await CodexAppServerCall.run(binary: codex, request: CodexSessionFork.request(threadId: r.threadId, lastTurnId: turn1)!)
            group.leave()
        }
        group.wait()
        if case .forked(let bb) = CodexSessionFork.outcome(from: through) {
            let bOrigin = CodexSessionScanner.forkOrigin(of: bb.rolloutURL)
            check("codex forks a fork through its inherited turn; the reader still reads ONE alone",
                  bOrigin?.parentId == r.threadId
                    && userTexts(CodexSessionScanner.readHistory(of: bb.rolloutURL, root: liveRoot)) == ["Reply with exactly: ONE"],
                  "\(String(describing: bOrigin))")
        } else {
            check("codex forks a fork through its inherited turn", false, "\(String(describing: through))")
        }
        // And names a turn outside the history plainly — the sentence
        // the branch alert would show.
        group.enter()
        var outside: [String: Any]? = nil
        Task {
            outside = await CodexAppServerCall.run(binary: codex, request: CodexSessionFork.request(threadId: r.threadId, lastTurnId: turn2)!)
            group.leave()
        }
        group.wait()
        if case .refused(let msg) = CodexSessionFork.outcome(from: outside) {
            check("a turn the fork never had is refused in codex's words", msg.contains("turn not found"), msg)
        } else {
            check("a turn the fork never had is refused in codex's words", false, "\(String(describing: outside))")
        }
        codexBranchForLive = (r.threadId, r.rolloutURL, home)
    case .failure(let e)?:
        check("codex forked", false, "\(e)")
    case nil:
        check("codex forked", false, "no result")
    }
    if !cwdExisted { try? fm.removeItem(atPath: recordedCwd) }
    if !liveTurns { try? fm.removeItem(at: home) }
} else {
    skip("codex thread/fork through the real client", "no codex on PATH")
}

// ====================================================================
print("")
print("KIMI — KimiSessionFork, pure rules")
let kimiFixture = fixtures.appendingPathComponent("kimi-two-turns.jsonl")
let kimiLines = lines(of: kimiFixture)
let probeId = "msg_01M1PCYWJ6XP81SFA3MF2S88Y4"
let againId = "msg_01M1PCZ3G2GK0CQRCXN91R2WZ4"

print("turn markers")
check("turn.prompt yields the prompt id",
      kimiLines.compactMap { KimiSessionScanner.turnPromptId(object($0)) } == [probeId, againId])
check("prompt.completed yields the prompt id",
      kimiLines.compactMap { KimiSessionScanner.promptCompletedId(object($0)) } == [probeId, againId])
check("turn.ended is recognised", kimiLines.filter { KimiSessionScanner.turnEnded(object($0)) }.count == 2)
check("userMessage reads id + cleaned text, and refuses the injected reminders",
      kimiLines.compactMap { KimiSessionScanner.userMessage(object($0)) }.map { ($0.id ?? "-") + "|" + $0.text }
        == ["\(probeId)|Reply with the single word: PROBE", "\(againId)|Reply with the single word: AGAIN"])

print("history rows carry the message id")
var kdec = KimiSessionScanner.WireDecoder()
var krows: [AgentSessionHistoryItem] = []
for l in kimiLines { krows.append(contentsOf: kdec.items(forLine: l)) }
let kusers = krows.filter { if case .userText = $0.kind { return true }; return false }
check("two user rows with their ids", kusers.map { $0.recordUuid ?? "-" } == [probeId, againId], "\(kusers.map { $0.recordUuid ?? "-" })")
check("assistant rows", assistantTexts(krows) == ["PROBE", "AGAIN"], "\(assistantTexts(krows))")

print("the cut")
let cutAgain = KimiSessionFork.cutIndex(lines: kimiLines, promptId: againId)
check("cut lands on AGAIN's turn.prompt",
      cutAgain.map { KimiSessionScanner.turnPromptId(object(kimiLines[$0])) == againId } ?? false, "\(String(describing: cutAgain))")
let prefix = Array(kimiLines[0..<(cutAgain ?? 0)])
check("the prefix ends on PROBE's prompt.completed",
      KimiSessionScanner.promptCompletedId(object(prefix.last ?? "")) == probeId)
check("the prefix is a conversation", KimiSessionFork.prefixHoldsConversation(prefix))
check("bookkeeping alone is not", !KimiSessionFork.prefixHoldsConversation(Array(kimiLines[0..<4])))
let cutProbe = KimiSessionFork.cutIndex(lines: kimiLines, promptId: probeId)!
check("cutting at the first message leaves no conversation",
      !KimiSessionFork.prefixHoldsConversation(Array(kimiLines[0..<cutProbe])))
check("a user record without turn.prompt still cuts",
      KimiSessionFork.cutIndex(lines: kimiLines.filter { KimiSessionScanner.turnPromptId(object($0)) == nil }, promptId: againId)
        .map { KimiSessionScanner.userMessage(object(kimiLines.filter { KimiSessionScanner.turnPromptId(object($0)) == nil }[$0]))?.id == againId } ?? false)
check("an unknown prompt id is nil", KimiSessionFork.cutIndex(lines: kimiLines, promptId: "msg_nope") == nil)

print("the records the branch writes")
let forkedLine = KimiSessionFork.forkedRecord(now: Date(timeIntervalSince1970: 1789229496.681))
check("forked record in kimi's spelling", forkedLine == #"{"type":"forked","agentId":"main","time":1789229496681}"#, forkedLine)
let fixtureState = object(lines(of: fixtures.appendingPathComponent("kimi-two-turns.state.json")).joined())
let srcDir = URL(fileURLWithPath: "/store/sessions/wd_x/session_old", isDirectory: true)
let newDir = URL(fileURLWithPath: "/store/sessions/wd_x/session_new", isDirectory: true)
var srcState = fixtureState
srcState["agents"] = ["main": ["homedir": "/store/sessions/wd_x/session_old/agents/main", "type": "main"]]
let rewritten = KimiSessionFork.rewrittenState(source: srcState, sourceId: "session_old", sourceDir: srcDir,
                                               newId: "session_new", newDir: newDir, title: "my branch",
                                               now: Date(timeIntervalSince1970: 1789229496.689))
check("state: id / title / titleKind / forkedFrom / createdAt changed",
      rewritten["id"] as? String == "session_new" && rewritten["title"] as? String == "my branch"
        && rewritten["titleKind"] as? String == "replaceable" && rewritten["forkedFrom"] as? String == "session_old"
        && rewritten["createdAt"] as? Int == 1789229496689 && rewritten["isCustomTitle"] as? Bool == false)
check("state: homedir re-pointed into the new directory",
      ((rewritten["agents"] as? [String: Any])?["main"] as? [String: Any])?["homedir"] as? String == "/store/sessions/wd_x/session_new/agents/main")
var withSub = srcState
withSub["agents"] = ["main": ["homedir": "/store/sessions/wd_x/session_old/agents/main", "type": "main"],
                     "agent-1": ["homedir": "/store/sessions/wd_x/session_old/agents/agent-1", "type": "subagent"]]
let subRewritten = KimiSessionFork.rewrittenState(source: withSub, sourceId: "session_old", sourceDir: srcDir,
                                                  newId: "session_new", newDir: newDir, title: "t", now: Date())
check("state: a subagent the branch does not copy is not listed",
      (subRewritten["agents"] as? [String: Any])?.keys.sorted() == ["main"])
let carried = ["cwd", "archived", "custom", "lastTurnReason", "updatedAt", "version"]
check("state: every other key carried through",
      carried.allSatisfy { key in
          let a = rewritten[key].map { "\($0)" } ?? "nil"; let b = srcState[key].map { "\($0)" } ?? "nil"; return a == b
      } && Set(rewritten.keys).subtracting(srcState.keys) == ["title", "titleKind", "forkedFrom"],
      "\(Set(rewritten.keys).subtracting(srcState.keys))")
let idx = KimiSessionFork.indexLine(sessionId: "session_new", dir: newDir, cwd: URL(fileURLWithPath: "/w d/x"))!
check("index line in kimi's key order",
      idx == #"{"sessionId":"session_new","sessionDir":"/store/sessions/wd_x/session_new","workDir":"/w d/x"}"#, idx)
let marked = #"{"type":"context.append_message","agentId":"main","message":{"role":"user","content":[{"type":"text","text":"<scheduled-task name=\"daily\"></scheduled-task>Check the logs"}],"id":"msg_1"},"time":1}"#
let stripped = KimiSessionFork.strippingScheduledTaskMarker(fromUserLine: marked)
check("scheduled-task marker stripped from a user record",
      !stripped.contains("<scheduled-task") && KimiSessionScanner.userMessage(object(stripped))?.text == "Check the logs", stripped)
check("a record without the marker is returned as it was",
      KimiSessionFork.strippingScheduledTaskMarker(fromUserLine: kimiLines[5]) == kimiLines[5])
// A branch of a scheduled run: the marker on the first user record
// goes; the same tag quoted in a LATER message is the user's own text.
do {
    let taskHome = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sipai-fork-kimitask-\(UUID().uuidString)", isDirectory: true)
    let tdir = taskHome.appendingPathComponent("sessions/wd_t_000000000000/session_task", isDirectory: true)
    try! fm.createDirectory(at: tdir.appendingPathComponent("agents/main"), withIntermediateDirectories: true)
    var taskLines = kimiLines
    for (i, l) in taskLines.enumerated() {
        var o = object(l)
        guard let user = KimiSessionScanner.userMessage(o), var msg = o["message"] as? [String: Any],
              var content = msg["content"] as? [[String: Any]], !content.isEmpty else { continue }
        content[0]["text"] = "<scheduled-task name=\"daily\"></scheduled-task>" + (user.id == probeId ? "Check the logs" : "quoting <scheduled-task name=\"x\"></scheduled-task> here")
        msg["content"] = content; o["message"] = msg
        taskLines[i] = String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]), as: UTF8.self)
    }
    let twire = KimiSessionScanner.wireFile(inSessionDir: tdir)
    try! Data(taskLines.joined(separator: "\n").utf8 + [0x0A]).write(to: twire)
    try! JSONSerialization.data(withJSONObject: fixtureState).write(to: tdir.appendingPathComponent("state.json"))
    setenv("KIMI_CODE_HOME", taskHome.path, 1)
    // Cut at a THIRD turn that does not exist? No — cut at AGAIN keeps
    // only the first record; so append the second record's text into
    // the prefix by cutting nowhere: use the whole wire as the prefix
    // through a synthetic third prompt id.
    let extra = #"{"type":"turn.prompt","agentId":"main","input":[{"type":"text","text":"third"}],"origin":{"kind":"user"},"promptId":"msg_third","time":1}"#
    try! Data((taskLines + [extra]).joined(separator: "\n").utf8 + [0x0A]).write(to: twire)
    let tr = try! KimiSessionFork.fork(sourceWire: twire, cutAtPromptId: "msg_third", title: "t", cwd: nil)
    let tbranch = lines(of: tr.wireURL)
    let firstUser = tbranch.first { KimiSessionScanner.userMessage(object($0)) != nil }.map { KimiSessionScanner.userMessage(object($0))!.text } ?? ""
    // The RAW later record, not its cleaned text — the cleaner strips
    // the tag for display, which is exactly what must not be mistaken
    // for the writer having left it alone.
    let laterRaw = tbranch.filter { KimiSessionScanner.userMessage(object($0)) != nil }.dropFirst().first ?? ""
    check("branch of a scheduled run: the first user record loses the marker",
          !firstUser.contains("<scheduled-task") && firstUser == "Check the logs", firstUser)
    check("…and a later message that quotes the tag keeps it, byte for byte",
          laterRaw.contains(#"<scheduled-task name=\"x\"></scheduled-task>"#) && laterRaw.contains("quoting"),
          String(laterRaw.prefix(160)))
    try? fm.removeItem(at: taskHome)
}

print("fork() over a throwaway store")
let kimiHome = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sipai-fork-kimihome-\(UUID().uuidString)", isDirectory: true)
// The working directory sits OUTSIDE the scratch roots the scanner
// filters (/tmp, /var/folders, …), or the branch could never be seen
// to scan; it is removed at the end.
let kimiCwd = fm.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/sipai-fork-harness-\(UUID().uuidString)/work", isDirectory: true)
try! fm.createDirectory(at: kimiCwd, withIntermediateDirectories: true)
let bucket = kimiHome.appendingPathComponent("sessions/\(kimiBucket(for: kimiCwd))", isDirectory: true)
let kimiSourceId = "session_bea09b4a-d30f-4b35-ba66-4077f8708fa7"
let kimiSourceDir = bucket.appendingPathComponent(kimiSourceId, isDirectory: true)
try! fm.createDirectory(at: kimiSourceDir.appendingPathComponent("agents/main"), withIntermediateDirectories: true)
let kimiSourceWire = KimiSessionScanner.wireFile(inSessionDir: kimiSourceDir)
// The wire's `runtime.set_binding` names the workspace bucket the
// session was recorded under, and kimi refuses to touch a session whose
// binding and bucket disagree ("runtime binding workspace … does not
// match session workspace …", measured). The fixture is re-bound to the
// bucket built here; a SipAI branch never needs this because it stays
// in its source's bucket.
try! Data(kimiLines.map { line -> String in
    var o = object(line)
    guard o["type"] as? String == "runtime.set_binding" else { return line }
    o["workspaceId"] = kimiBucket(for: kimiCwd)
    return String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]), as: UTF8.self)
}.joined(separator: "\n").utf8 + [0x0A]).write(to: kimiSourceWire)
let boundLines = lines(of: kimiSourceWire)
var kimiSourceState = fixtureState
kimiSourceState["cwd"] = real(kimiCwd)
kimiSourceState["agents"] = ["main": ["homedir": kimiSourceDir.appendingPathComponent("agents/main").path, "type": "main"]]
try! JSONSerialization.data(withJSONObject: kimiSourceState).write(to: kimiSourceDir.appendingPathComponent("state.json"))
let kimiIndex = kimiHome.appendingPathComponent("session_index.jsonl")
try! Data((KimiSessionFork.indexLine(sessionId: kimiSourceId, dir: kimiSourceDir, cwd: kimiCwd)! + "\n").utf8).write(to: kimiIndex)
setenv("KIMI_CODE_HOME", kimiHome.path, 1)
check("scanner honours KIMI_CODE_HOME", KimiSessionScanner.sessionRoot == kimiHome.appendingPathComponent("sessions", isDirectory: true))

let kimiBefore = try! Data(contentsOf: kimiSourceWire)
let kresult = try! KimiSessionFork.fork(sourceWire: kimiSourceWire, cutAtPromptId: againId, title: "probe branch", cwd: kimiCwd)
let kdir = kresult.wireURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
check("branch is a session_<uuid> directory beside its source",
      kdir.deletingLastPathComponent().path == bucket.path && kdir.lastPathComponent == kresult.sessionId && kresult.sessionId.hasPrefix("session_"))
check("source wire untouched", (try! Data(contentsOf: kimiSourceWire)) == kimiBefore)
check("no staging directory left behind",
      !(try! fm.contentsOfDirectory(atPath: bucket.path)).contains { $0.hasPrefix(".sipai-branch-") })
let branchLines = lines(of: kresult.wireURL)
let boundPrefix = Array(boundLines[0..<(cutAgain ?? 0)])
check("branch wire = prefix + forked record",
      Array(branchLines.dropLast()) == boundPrefix && (branchLines.last?.hasPrefix(#"{"type":"forked","agentId":"main","time":"#) ?? false),
      "\(branchLines.count) records")
let branchState = object(lines(of: kdir.appendingPathComponent("state.json")).joined())
check("branch state.json: new id, our title, forkedFrom, cwd carried",
      branchState["id"] as? String == kresult.sessionId && branchState["title"] as? String == "probe branch"
        && branchState["forkedFrom"] as? String == kimiSourceId && branchState["cwd"] as? String == real(kimiCwd))
check("branch notify/state.json", lines(of: kdir.appendingPathComponent("notify/state.json")) == [#"{"enabled":false}"#])
let indexLines = lines(of: kimiIndex)
check("index gained exactly one line naming the branch",
      indexLines.count == 2 && (object(indexLines[1])["sessionId"] as? String) == kresult.sessionId
        && (object(indexLines[1])["sessionDir"] as? String) == kdir.path)
check("the branch scans as a kimi session with our title",
      KimiSessionScanner.scan().first { $0.id == kresult.sessionId }.map { $0.title == "probe branch" && !$0.isEmptyShell } ?? false)
check("the branch's history is PROBE alone",
      userTexts(KimiSessionScanner.readHistory(of: kresult.wireURL)) == ["Reply with the single word: PROBE"])
check("live-row cut resolution finds AGAIN's prompt id",
      KimiSessionFork.resolveCutPoint(matchingUserText: "Reply with the single word: AGAIN", in: kimiSourceWire) == againId)
do {
    _ = try KimiSessionFork.fork(sourceWire: kimiSourceWire, cutAtPromptId: probeId, title: "x", cwd: kimiCwd)
    check("cutting at the first message throws nothingToBranch", false, "no throw")
} catch AgentSessionFork.ForkError.nothingToBranch {
    check("cutting at the first message throws nothingToBranch", true)
} catch {
    check("cutting at the first message throws nothingToBranch", false, "\(error)")
}
do {
    _ = try KimiSessionFork.fork(sourceWire: kimiSourceWire, cutAtPromptId: "msg_nope", title: "x", cwd: kimiCwd)
    check("an unknown cut throws cutPointNotFound", false, "no throw")
} catch AgentSessionFork.ForkError.cutPointNotFound {
    check("an unknown cut throws cutPointNotFound", true)
} catch {
    check("an unknown cut throws cutPointNotFound", false, "\(error)")
}

// ====================================================================
print("")
print("KIMI — our branch beside kimi's own fork (token-free)")
if let kimi = binary("kimi") {
    // No config.toml and no credentials are needed: a fork calls no
    // model. Kimi finds the session through the bucket its cwd hashes
    // to, which is why the store above spells the bucket kimi's way.
    let r = run(kimi, ["fork", kimiSourceId, "-y"], cwd: kimiCwd, environment: ["KIMI_CODE_HOME": kimiHome.path], timeout: 60)
    let forkedId = r.out.split(separator: " ").map(String.init).first { $0.hasPrefix("session_") }
    if let forkedId {
        let theirs = bucket.appendingPathComponent(forkedId, isDirectory: true)
        func fileSet(_ dir: URL) -> Set<String> {
            var out = Set<String>()
            let base = real(dir)
            if let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    let rel = String(real(u).dropFirst(base.count + 1))
                    if !rel.hasPrefix("logs/") { out.insert(rel) }
                }
            }
            return out
        }
        check("kimi's fork and ours write the same file set",
              fileSet(theirs) == fileSet(kdir), "theirs \(fileSet(theirs).sorted()) ours \(fileSet(kdir).sorted())")
        let theirState = object(lines(of: theirs.appendingPathComponent("state.json")).joined())
        check("the same state.json keys", Set(theirState.keys) == Set(branchState.keys),
              "theirs \(theirState.keys.sorted()) ours \(branchState.keys.sorted())")
        check("kimi's fork carries titleKind replaceable + forkedFrom, as ours does",
              theirState["titleKind"] as? String == "replaceable" && theirState["forkedFrom"] as? String == kimiSourceId)
        let theirLines = lines(of: KimiSessionScanner.wireFile(inSessionDir: theirs))
        check("kimi's wire = the whole source + a forked record",
              Array(theirLines.dropLast()) == boundLines && (theirLines.last?.hasPrefix(#"{"type":"forked","agentId":"main","time":"#) ?? false))
        check("ours is a strict prefix of theirs, plus the same closing record",
              branchLines.count < theirLines.count && Array(theirLines.prefix(branchLines.count - 1)) == Array(branchLines.dropLast()))
    } else {
        check("kimi fork ran", false, "exit \(r.status): \(r.out.prefix(200))")
    }
} else {
    skip("kimi fork beside ours", "no kimi on PATH")
}
try? fm.removeItem(at: kimiHome)
try? fm.removeItem(at: kimiCwd.deletingLastPathComponent())
try? fm.removeItem(at: store)

// ====================================================================
print("")
print("LIVE — two real turns (SIPAI_FORK_LIVE=1)")
if !liveTurns {
    skip("codex exec resume on an app-server fork; kimi answering from a prefix", "set SIPAI_FORK_LIVE=1")
} else {
    // (a) codex: resume the branch made above — the exact command every
    // SipAI send runs — under the throwaway home with the real
    // credentials copied in.
    if let codex = binary("codex"), let branch = codexBranchForLive {
        let realHome = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        for name in ["auth.json", "config.toml"] {
            try? fm.copyItem(at: realHome.appendingPathComponent(name), to: branch.home.appendingPathComponent(name))
        }
        let recordedCwd = (object(codexLines[0])["payload"] as? [String: Any])?["cwd"] as? String ?? "/tmp"
        try? fm.createDirectory(atPath: recordedCwd, withIntermediateDirectories: true)
        // The runner's own spelling of the policy (`AgentLaunchOptions`).
        let r = run(codex, ["exec", "resume", "--json", "--skip-git-repo-check", "-c", "sandbox_mode=read-only",
                            "-c", "approval_policy=never", branch.id, "Reply with exactly: THREE"],
                    cwd: URL(fileURLWithPath: recordedCwd), environment: ["CODEX_HOME": branch.home.path], timeout: 300)
        check("codex exec resume on the branch completed", r.out.contains("turn.completed"), "exit \(r.status): \(r.out.suffix(300))")
        let liveRoot = branch.home.appendingPathComponent("sessions", isDirectory: true)
        let newest = CodexSessionScanner.rolloutFile(namedForId: branch.id, root: liveRoot) ?? branch.url
        let h = CodexSessionScanner.readHistory(of: newest, root: liveRoot)
        check("the branch now reads ONE, THREE — and never TWO",
              userTexts(h) == ["Reply with exactly: ONE", "Reply with exactly: THREE"] && !assistantTexts(h).contains("TWO"),
              "\(userTexts(h)) / \(assistantTexts(h))")
        try? fm.removeItem(at: branch.home)
    } else {
        skip("codex exec resume on the branch", "no codex, or the token-free fork above failed")
    }

    // (b) kimi: in the REAL store, branch the harness's own probe
    // session before AGAIN and ask which word was requested.
    unsetenv("KIMI_CODE_HOME")
    if let kimi = binary("kimi"),
       let realDir = KimiSessionScanner.sessionDirectory(forId: kimiSourceId) {
        let realWire = KimiSessionScanner.wireFile(inSessionDir: realDir)
        let realState = object(lines(of: realDir.appendingPathComponent("state.json")).joined())
        let cwd = URL(fileURLWithPath: realState["cwd"] as? String ?? NSTemporaryDirectory(), isDirectory: true)
        try? fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        do {
            let b = try KimiSessionFork.fork(sourceWire: realWire, cutAtPromptId: againId, title: "SipAI fork probe", cwd: cwd)
            let r = run(kimi, ["--prompt", "Which single word did I ask you to reply with? Answer with that word only.",
                               "--output-format", "stream-json", "--session", b.sessionId],
                        cwd: cwd, environment: [:], timeout: 300)
            let answer = r.out.uppercased()
            check("kimi answered from the hand-written prefix: PROBE, not AGAIN",
                  answer.contains("PROBE") && !answer.contains("AGAIN"), "exit \(r.status): \(r.out.suffix(300))")
            print("  KIMI_BRANCH_ID=\(b.sessionId)  (a scratch session; delete it when done)")
        } catch {
            check("kimi branch of the real probe session", false, "\(error)")
        }
    } else {
        skip("kimi answering from a prefix", "no kimi, or the probe session \(kimiSourceId) is not in the real store")
    }
}

// ====================================================================
print("")
print("STRUCTURAL — the view and the manager, by reading them")
let viewText = (try? String(contentsOf: sourceRoot.appendingPathComponent("SipAI/Views/Chat/AgentSessionView.swift"), encoding: .utf8)) ?? ""
let managerText = (try? String(contentsOf: sourceRoot.appendingPathComponent("SipAI/Models/AgentManager.swift"), encoding: .utf8)) ?? ""
let runnerText = (try? String(contentsOf: sourceRoot.appendingPathComponent("SipAI/Models/AgentRunner.swift"), encoding: .utf8)) ?? ""
func body(of name: String, in text: String) -> String {
    guard let r = text.range(of: name) else { return "" }
    let after = text[r.upperBound...]
    guard let close = after.range(of: "\n    }\n") else { return String(after.prefix(2000)) }
    return String(after[..<close.lowerBound])
}
let canBranch = body(of: "private var canBranch: Bool {", in: viewText)
check("canBranch names no agent", !canBranch.isEmpty && !canBranch.contains("claude_code") && !canBranch.contains("\"codex\"") && !canBranch.contains("\"kimi\""))
check("createSessionBranch dispatches on the session's agent",
      viewText.contains("case \"codex\":") && viewText.contains("forkCodex(") && viewText.contains("forkKimi(") && viewText.contains("forkClaude("))
check("the first-message branch keeps the session's agent",
      body(of: "private func startBranchAsNewSession(", in: viewText).contains("agentKey: sessionAgentKey"))
check("registerBranchedSession is called with the agent",
      viewText.contains("agents.registerBranchedSession(") && body(of: "agents.registerBranchedSession(", in: viewText).contains("agentKey: agentKey"))
check("registerBranchedSession takes the agent and files the row under it",
      managerText.contains("func registerBranchedSession(id: String, fileURL: URL, cwd: URL,\n                                 title: String, agentKey: String")
        && body(of: "func registerBranchedSession(", in: managerText).contains("agentKey: agentKey"))
check("the runner's private rollout lookup is gone; one spelling in the scanner",
      !runnerText.contains("locateCodexRollout") && runnerText.contains("CodexSessionScanner.rolloutFile(namedForId:"))
check("an unavailable agent is worded with its label",
      viewText.contains("ForkError.agentUnavailable") && viewText.contains("\\(sessionAgentName) did not answer"))
let userRowBody = body(of: "private func userRow(rowId: UUID", in: viewText)
check("no pencil on a system notice in the user column", userRowBody.contains("!isSystemNotice"))
let createBody = body(of: "private func createSessionBranch(recordUuid:", in: viewText)
let lineageAt = createBody.range(of: "config.setAgentSessionBranch(")?.lowerBound
let guardAt = createBody.range(of: "stillOpen == sourceId")?.lowerBound
check("lineage, name and row are written BEFORE the moved-on guard",
      lineageAt != nil && guardAt != nil && lineageAt! < guardAt!)
let scopeBody = body(of: "private func updateHistoryScope(", in: viewText)
check("partiality judges the inherited prefix and the own file each against the budget",
      scopeBody.contains("ownSize > budget || inheritedHistoryBytes > budget") && !scopeBody.contains("fileSize > UInt64(historyLoadedBudget)"))

// ====================================================================
print("")
print("CLAUDE — fork() on a real transcript")
let args = CommandLine.arguments
if args.count > 1 {
    let source = URL(fileURLWithPath: args[1])

    // Cut at the LAST turn-opening user record, so the branch is the whole
    // session minus its final turn — the realistic "edit my last message".
    var cutUuid: String? = nil
    var cutText = ""
    for line in (try! String(contentsOf: source, encoding: .utf8)).split(separator: "\n") {
        guard let d = line.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              o["type"] as? String == "user",
              (o["isSidechain"] as? Bool) != true,
              o["toolUseResult"] == nil || o["toolUseResult"] is NSNull,
              let u = o["uuid"] as? String else { continue }
        let msg = o["message"] as? [String: Any] ?? [:]
        let body = AgentSessionScanner.cleanUserText(
            AgentSessionScanner.extractText(fromContent: msg["content"] ?? ""))
        if body.isEmpty || body.hasPrefix("[Request interrupted") { continue }
        cutUuid = u; cutText = body
    }
    guard let cutUuid else { check("found a cut point", false); exit(1) }

    let before = try! Data(contentsOf: source)
    let result = try! AgentSessionFork.fork(source: source, cutAtRecordUuid: cutUuid)
    check("source is untouched", (try! Data(contentsOf: source)) == before)
    check("branch is named <uuid>.jsonl",
          result.fileURL.lastPathComponent == result.sessionId + ".jsonl")
    check("branch lives beside its source",
          result.fileURL.deletingLastPathComponent() == source.deletingLastPathComponent())
    check("no staging file left behind",
          !(try! FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path))
            .contains { $0.hasPrefix(".sipai-branch-") })

    let forked = try! String(contentsOf: result.fileURL, encoding: .utf8)
    let forkedLines = forked.split(separator: "\n").map(String.init)
    check("branch is non-empty", !forkedLines.isEmpty, "\(forkedLines.count) records")
    check("cut record is absent", !forked.contains(cutUuid))
    var oldSessionIds = Set<String>()
    var aiTitles = 0
    var badChain = 0
    var seenUuids = Set<String>()
    for l in forkedLines {
        guard let d = l.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            badChain += 1; continue
        }
        if let s = o["sessionId"] as? String, s != result.sessionId { oldSessionIds.insert(s) }
        if o["type"] as? String == "ai-title" { aiTitles += 1 }
        if let u = o["uuid"] as? String { seenUuids.insert(u) }
    }
    check("every sessionId re-pointed", oldSessionIds.isEmpty, "stragglers: \(oldSessionIds)")
    check("no inherited ai-title", aiTitles == 0)
    check("every line is valid JSON", badChain == 0)
    // Chain integrity: every non-null parentUuid must name a record we kept.
    var orphans = 0
    for l in forkedLines {
        guard let d = l.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let p = o["parentUuid"] as? String else { continue }
        if !seenUuids.contains(p) { orphans += 1 }
    }
    check("parent chain is closed", orphans == 0, "\(orphans) orphaned parentUuid")

    print("  BRANCH_ID=\(result.sessionId)")
    print("  BRANCH_FILE=\(result.fileURL.path)")
    print("  CUT_TEXT=\(cutText.prefix(60))")
} else {
    skip("fork a real claude transcript", "pass a COPY of a session .jsonl as the first argument")
}

print("")
print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
