// Headless verification for AgentSessionRename. See run.sh.
//
// Not part of the app target — this directory sits outside SipAI/, and
// the Xcode project lists its sources explicitly.
//
// This is the second thing in the app that writes into an agent's own
// store, and like the first (AgentSessionFork) it fails SILENTLY when
// it is wrong: the sidebar shows the new name either way, and the only
// evidence of a bad write is the agent's own picker still showing the
// old one — or, worse, a transcript with a record fused onto a turn.
//
// Everything runs over throwaway directories under $TMPDIR. It never
// touches ~/.claude or ~/.kimi-code.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "  ok   " : "  FAIL ") + label + (detail.isEmpty ? "" : " — \(detail)"))
    if !ok { failures += 1 }
}

let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("sipai-rename-\(UUID().uuidString)", isDirectory: true)
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

func lines(_ url: URL) -> [String] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    return String(decoding: data, as: UTF8.self)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
}
func records(_ url: URL) -> [[String: Any]] {
    lines(url).compactMap {
        guard !$0.isEmpty, let d = $0.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

// ---------- 1. which agents are written through ----------
print("writesThrough()")
check("claude_code writes through", AgentSessionRename.writesThrough("claude_code"))
check("kimi writes through", AgentSessionRename.writesThrough("kimi"))
// Codex rebuilds the thread title from the rollout on every `codex exec`
// — the command every send goes through — so a name written there is
// gone by the next turn. Nothing is written; the rename stays SipAI's.
check("codex does NOT", !AgentSessionRename.writesThrough("codex"))
check("an unmeasured agent does NOT", !AgentSessionRename.writesThrough("gemini_cli"))

// ---------- 2. claude: the appended record ----------
print("\nclaude — the transcript record")
let projectDir = root.appendingPathComponent("projects/-tmp-probe", isDirectory: true)
try! fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
let sessionId = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
let transcript = projectDir.appendingPathComponent("\(sessionId).jsonl")
let original = Data("""
{"type":"user","sessionId":"\(sessionId)","message":{"role":"user","content":"hi"}}
{"type":"ai-title","aiTitle":"Generated name","sessionId":"\(sessionId)"}

""".utf8)
try! original.write(to: transcript)

try! AgentSessionRename.apply("Renamed by SipAI", sessionId: sessionId,
                              fileURL: transcript, agentKey: "claude_code")

let recs = records(transcript)
check("the file grows at the end only",
      (try! Data(contentsOf: transcript)).prefix(original.count) == original)
check("exactly one record is appended", recs.count == 3, "\(recs.count)")
let titleRecord = recs.last
check("it is a custom-title record", titleRecord?["type"] as? String == "custom-title")
check("carrying the typed name",
      titleRecord?["customTitle"] as? String == "Renamed by SipAI")
check("stamped with this session's id",
      titleRecord?["sessionId"] as? String == sessionId)
check("with a uuid", (titleRecord?["uuid"] as? String)?.isEmpty == false)
check("and a timestamp", (titleRecord?["timestamp"] as? String)?.isEmpty == false)

// The rule that fails silently: claude finds this record by testing each
// line for a literal substring BEFORE parsing it. One space after the
// colon and the rename does nothing at all, with no error anywhere.
let appended = lines(transcript).first { $0.contains("custom-title") } ?? ""
check("the line is COMPACT — claude prefilters on \"type\":\"custom-title\"",
      appended.contains("\"type\":\"custom-title\""), appended)
check("and on \"customTitle\":\"", appended.contains("\"customTitle\":\""))
check("the record is one line", lines(transcript).filter { !$0.isEmpty }.count == 3)

// ---------- 3. claude: the sidecar ----------
print("\nclaude — the sidecar")
// Written as well as the record, because the record scrolls out of the
// window claude reads when listing sessions and the sidecar is what
// still answers after that.
let sidecar = projectDir
    .appendingPathComponent(sessionId, isDirectory: true)
    .appendingPathComponent("custom-title.json")
check("written beside the transcript", fm.fileExists(atPath: sidecar.path))
if let d = try? Data(contentsOf: sidecar),
   let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
    check("holding the same name", o["customTitle"] as? String == "Renamed by SipAI")
} else {
    check("holding the same name", false, "unreadable")
}
let mode = (try? fm.attributesOfItem(atPath: sidecar.path))?[.posixPermissions] as? NSNumber
check("owner-only permissions", mode?.intValue == 0o600, String(describing: mode))

// ---------- 4. a name is arbitrary text ----------
print("\nclaude — a name is arbitrary text")
let awkward = "研究笔记 \"quoted\" / slash \\ back"
try! AgentSessionRename.apply(awkward, sessionId: sessionId,
                              fileURL: transcript, agentKey: "claude_code")
check("round-trips through the record",
      records(transcript).last?["customTitle"] as? String == awkward)
if let d = try? Data(contentsOf: sidecar),
   let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
    check("round-trips through the sidecar", o["customTitle"] as? String == awkward)
} else {
    check("round-trips through the sidecar", false, "unreadable")
}
check("and the line is still compact",
      (lines(transcript).last { $0.contains("custom-title") } ?? "")
        .contains("\"type\":\"custom-title\""))

// ---------- 5. clearing ----------
print("\nclaude — clearing")
// Clearing is an APPENDED record carrying an empty title, never a
// rewrite of the file to remove the old one. Transcripts belong to
// claude; we only ever add a line.
let beforeClear = records(transcript).count
try! AgentSessionRename.apply(nil, sessionId: sessionId,
                              fileURL: transcript, agentKey: "claude_code")
check("appends rather than rewrites", records(transcript).count == beforeClear + 1)
check("the newest record carries an EMPTY title",
      records(transcript).last?["customTitle"] as? String == "")
check("the sidecar is removed", !fm.fileExists(atPath: sidecar.path))
check("the earlier records still stand",
      records(transcript).contains { $0["type"] as? String == "ai-title" })

// ---------- 6. a transcript cut off mid-line ----------
print("\nclaude — a torn last line")
// A live writer can leave the file without its final newline. Appending
// straight onto that fragment would fuse our record to a half-written
// one and cost both.
let torn = projectDir.appendingPathComponent("torn.jsonl")
try! Data("{\"type\":\"user\",\"sessionId\":\"x\"}\n{\"type\":\"assis".utf8).write(to: torn)
try! AgentSessionRename.apply("After a torn line", sessionId: "x",
                              fileURL: torn, agentKey: "claude_code")
let tornLines = lines(torn)
check("the fragment is left alone", tornLines.contains("{\"type\":\"assis"))
check("the record lands on its own line",
      tornLines.contains { $0.hasPrefix("{") && $0.contains("\"type\":\"custom-title\"") })
check("nothing is fused",
      !tornLines.contains { $0.hasPrefix("{\"type\":\"assis") && $0.contains("custom-title") })

// ---------- 7. nothing on disk to write into ----------
print("\nclaude — no store")
do {
    try AgentSessionRename.apply(
        "x", sessionId: "y",
        fileURL: projectDir.appendingPathComponent("absent.jsonl"),
        agentKey: "claude_code")
    check("a missing transcript reports storeMissing", false, "did not throw")
} catch AgentSessionRename.Failure.storeMissing {
    check("a missing transcript reports storeMissing", true)
} catch {
    check("a missing transcript reports storeMissing", false, "\(error)")
}

// ---------- 8. kimi: read, change two keys, keep the rest ----------
print("\nkimi — state.json")
let kimiHome = root.appendingPathComponent("kimi-home", isDirectory: true)
setenv("KIMI_CODE_HOME", kimiHome.path, 1)
let kimiSession = kimiHome
    .appendingPathComponent("sessions/wd_probe_abc/session_1234", isDirectory: true)
let wire = kimiSession.appendingPathComponent("agents/main/wire.jsonl")
try! fm.createDirectory(at: wire.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
try! Data().write(to: wire)
let statePath = kimiSession.appendingPathComponent("state.json")
let seedState: [String: Any] = [
    "id": "session_1234",
    "version": 2,
    "cwd": "/Users/someone/Desktop/work",
    "archived": false,
    "agents": ["main": ["type": "main"]],
    "custom": [String: Any](),
    "lastTurnReason": "completed",
    "createdAt": 1786960911439,
    "updatedAt": 1786960925852,
    "isCustomTitle": false,
]
try! JSONSerialization.data(withJSONObject: seedState, options: [.prettyPrinted])
    .write(to: statePath)

try! AgentSessionRename.apply("Kimi renamed", sessionId: "session_1234",
                              fileURL: wire, agentKey: "kimi")
func readState() -> [String: Any] {
    guard let d = try? Data(contentsOf: statePath),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    else { return [:] }
    return o
}
var after = readState()
check("title is set", after["title"] as? String == "Kimi renamed")
// Kimi reads the two together — a title without the flag is a different
// thing to kimi, so both move or neither does.
check("isCustomTitle rides with it", after["isCustomTitle"] as? Bool == true)
// Everything else has to survive: kimi rewrites this file itself, and
// `cwd` is in here — a kimi session with no recorded cwd resumes in the
// home folder.
check("cwd survives", after["cwd"] as? String == "/Users/someone/Desktop/work")
check("createdAt survives as an integer",
      (after["createdAt"] as? NSNumber)?.int64Value == 1786960911439)
check("version survives", (after["version"] as? NSNumber)?.intValue == 2)
check("archived survives as a bool", after["archived"] as? Bool == false)
check("nested agents survive", (after["agents"] as? [String: Any])?["main"] != nil)
check("no key is lost", Set(after.keys).isSuperset(of: Set(seedState.keys)))

// ---------- 9. kimi: clearing drops the key ----------
print("\nkimi — clearing")
try! AgentSessionRename.apply("", sessionId: "session_1234",
                              fileURL: wire, agentKey: "kimi")
after = readState()
// Kimi reads a PRESENT `title` of any value as the session's name, so
// clearing has to remove the key rather than store "".
check("title is removed, not emptied", after["title"] == nil)
check("isCustomTitle goes back to false", after["isCustomTitle"] as? Bool == false)
check("cwd still survives", after["cwd"] as? String == "/Users/someone/Desktop/work")

// ---------- 10. kimi: a session that cannot be resolved ----------
print("\nkimi — no store")
do {
    try AgentSessionRename.apply(
        "x", sessionId: "z",
        fileURL: root.appendingPathComponent("nowhere/wire.jsonl"),
        agentKey: "kimi")
    check("an unresolvable session reports storeMissing", false, "did not throw")
} catch AgentSessionRename.Failure.storeMissing {
    check("an unresolvable session reports storeMissing", true)
} catch {
    check("an unresolvable session reports storeMissing", false, "\(error)")
}

// ---------- 11. an agent with no mechanism is never written to ----------
print("\ncodex")
let rollout = projectDir.appendingPathComponent("rollout.jsonl")
try! Data("{\"type\":\"session_meta\"}\n".utf8).write(to: rollout)
let rolloutBefore = try! Data(contentsOf: rollout)
do {
    try AgentSessionRename.apply("Should not land", sessionId: "cx",
                                 fileURL: rollout, agentKey: "codex")
    check("codex refuses the write", false, "did not throw")
} catch AgentSessionRename.Failure.storeMissing {
    check("codex refuses the write", true)
} catch {
    check("codex refuses the write", false, "\(error)")
}
check("and the rollout is byte-identical",
      (try? Data(contentsOf: rollout)) == rolloutBefore)

print("")
if failures == 0 {
    print("All checks passed.")
} else {
    print("\(failures) check(s) FAILED.")
    exit(1)
}
