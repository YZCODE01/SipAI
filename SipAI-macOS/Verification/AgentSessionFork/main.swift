// Headless verification for AgentSessionFork. See run.sh.
//
// Not part of the app target — this directory sits outside SipAI/, and
// the Xcode project lists its sources explicitly.
//
// Same discipline as ScheduledTaskScheduler.decide and TranscriptFollow:
// the rule is a pure function of its inputs, so it can be exercised
// without an AgentManager, a subprocess or a window. Stubs.swift stands
// in for the two AgentSessionScanner helpers the fork calls.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "  ok   " : "  FAIL ") + label + (detail.isEmpty ? "" : " — \(detail)"))
    if !ok { failures += 1 }
}

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

// ---------- 4. end-to-end against a real transcript ----------
print("fork() on a real transcript")
let args = CommandLine.arguments
guard args.count > 1 else {
    print("\n\(failures) failure(s)"); exit(failures == 0 ? 0 : 1)
}
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

print("\nBRANCH_ID=\(result.sessionId)")
print("BRANCH_FILE=\(result.fileURL.path)")
print("CUT_TEXT=\(cutText.prefix(60))")
print("\n\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
