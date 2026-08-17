// A SCHEDULED run must survive the scratch-location filter in EVERY
// scanner, not just the claude one.
//
// The rule (CLAUDE.md → "Scratch sessions are filtered out — by
// LOCATION, not by size"): a session rooted in a system temp directory
// is a probe and never reaches the sidebar — EXCEPT a scheduled run,
// which is kept wherever it happened to run, because automation the
// user set up is theirs to see and a wrapper is free to pick a temp
// cwd.
//
// The claude scanner honoured it. Codex and kimi did not: both bailed
// on the cwd alone, each under a comment claiming parity with claude.
// The cost was silent and total — a codex or kimi task pointed at a
// temp folder ran fine, and then reported ZERO runs, because
// `ScheduledAgentTaskScanner` groups over the very list the session had
// been dropped from. Measured 2026-08-15, fixed the same day.
//
// Kimi's half also pins an ordering rule: the marker lives in the first
// user record, so the scratch verdict cannot be reached before the head
// read. An early bail cannot know whether it is dropping a probe or a
// task's only run.
//
// Nothing here is part of the app target: this directory sits outside
// SipAI/, so these files are never compiled into the product. The stubs
// are borrowed from ../KimiCode rather than copied — a fifth copy would
// be one more thing to keep in step.
//
//   ./run.sh

import Foundation

let fm = FileManager.default
var failures = 0
func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    print(cond ? "  PASS  \(label)" : "  FAIL  \(label) \(detail)")
    if !cond { failures += 1 }
}

// A real (non-scratch) project folder, and a scratch one. The sandbox
// must NOT live under $TMPDIR — that is itself a scratch root, which
// would make every session in here look like a probe.
let sandbox = fm.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/sipai-schedvis-\(UUID().uuidString)")
let projectDir = sandbox.appendingPathComponent("RealProject")
try! fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

// /private/tmp is one of the scratch roots by the string rule.
let scratchDir = URL(fileURLWithPath: "/private/tmp/probe-work")

print("scratch root check")
check("the fake project folder is NOT scratch",
      !AgentSessionScanner.isScratchLocation(projectDir))
check("/private/tmp IS scratch",
      AgentSessionScanner.isScratchLocation(scratchDir))

// ─────────────────────────────────────────── kimi
let kimiHome = sandbox.appendingPathComponent("kimi-home")
setenv("KIMI_CODE_HOME", kimiHome.path, 1)

func writeKimi(bucket: String, id: String, cwd: URL, firstUserText: String) {
    let dir = kimiHome.appendingPathComponent("sessions")
        .appendingPathComponent(bucket).appendingPathComponent(id)
    let agents = dir.appendingPathComponent("agents/main")
    try! fm.createDirectory(at: agents, withIntermediateDirectories: true)
    let state = #"{"cwd":"\#(cwd.path)","createdAt":"2026-08-14T09:00:00.000Z"}"#
    try! state.write(to: dir.appendingPathComponent("state.json"),
                     atomically: true, encoding: .utf8)
    let escaped = firstUserText
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    let wire = [
        #"{"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"\#(escaped)"}],"toolCalls":[]},"time":1786766760914}"#,
        #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"Done."}},"time":1786766761914}"#,
    ].joined(separator: "\n") + "\n"
    try! wire.write(to: agents.appendingPathComponent("wire.jsonl"),
                    atomically: true, encoding: .utf8)
}

let marker = "<scheduled-task name=\"nightly-report\"></scheduled-task>\nSummarise today."
writeKimi(bucket: "wd_real", id: "sess-real", cwd: projectDir,
          firstUserText: "Ordinary work in a real folder")
writeKimi(bucket: "wd_probe", id: "sess-probe", cwd: scratchDir,
          firstUserText: "Throwaway probe run")
writeKimi(bucket: "wd_task", id: "sess-task", cwd: scratchDir,
          firstUserText: marker)

print("\nkimi scanner")
let kimiSessions = KimiSessionScanner.scan()
let kimiIds = Set(kimiSessions.map(\.id))
check("an ordinary session in a real folder is listed",
      kimiIds.contains("sess-real"))
check("an ordinary session in a temp folder is dropped",
      !kimiIds.contains("sess-probe"))
check("a SCHEDULED run in a temp folder is KEPT",
      kimiIds.contains("sess-task"),
      "— got \(kimiIds.sorted())")
if let task = kimiSessions.first(where: { $0.id == "sess-task" }) {
    check("…and carries its task name",
          task.scheduledTaskName == "nightly-report",
          "— got \(String(describing: task.scheduledTaskName))")
    check("…and is tagged as a scheduled run", task.origin == .scheduled)
    check("…and its title is the prompt, not the marker",
          !task.title.contains("scheduled-task"), "— got \(task.title)")
}

// ─────────────────────────────────────────── codex
// CodexSessionScanner.sessionRoot derives from NSHomeDirectory(), which
// honours CFFIXED_USER_HOME. Set before first access (it is a lazy let).
let codexHome = sandbox.appendingPathComponent("codex-home")
try! fm.createDirectory(at: codexHome, withIntermediateDirectories: true)
setenv("CFFIXED_USER_HOME", codexHome.path, 1)

func writeCodex(id: String, cwd: URL, firstUserText: String) {
    let day = codexHome.appendingPathComponent(".codex/sessions/2026/08/14")
    try! fm.createDirectory(at: day, withIntermediateDirectories: true)
    let file = day.appendingPathComponent("rollout-2026-08-14T09-00-00-\(id).jsonl")
    let escaped = firstUserText
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    let lines = [
        #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd.path)"}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(escaped)"}]}}"#,
    ].joined(separator: "\n") + "\n"
    try! lines.write(to: file, atomically: true, encoding: .utf8)
}

let realId = "01a00000-0000-4000-8000-00000000real".replacingOccurrences(of: "real", with: "0001")
let probeId = "01a00000-0000-4000-8000-000000000002"
let taskId = "01a00000-0000-4000-8000-000000000003"
writeCodex(id: realId, cwd: projectDir, firstUserText: "Ordinary codex work")
writeCodex(id: probeId, cwd: scratchDir, firstUserText: "Throwaway probe run")
writeCodex(id: taskId, cwd: scratchDir, firstUserText: marker)

print("\ncodex scanner  (root: \(CodexSessionScanner.sessionRoot.path))")
if CodexSessionScanner.sessionRoot.path.hasPrefix(codexHome.path) {
    let codexSessions = CodexSessionScanner.scan()
    let codexIds = Set(codexSessions.map(\.id))
    check("an ordinary rollout in a real folder is listed",
          codexIds.contains(realId))
    check("an ordinary rollout in a temp folder is dropped",
          !codexIds.contains(probeId))
    check("a SCHEDULED run in a temp folder is KEPT",
          codexIds.contains(taskId), "— got \(codexIds.sorted())")
    if let task = codexSessions.first(where: { $0.id == taskId }) {
        check("…and carries its task name",
              task.scheduledTaskName == "nightly-report",
              "— got \(String(describing: task.scheduledTaskName))")
        check("…and is tagged as a scheduled run", task.origin == .scheduled)
    }
} else {
    print("  SKIP  could not redirect the codex root (CFFIXED_USER_HOME ignored)")
}

// ─────────────────────────────────────────── grouping
print("\ngrouping (what the task panel counts as a run)")
let all = KimiSessionScanner.scan() + (
    CodexSessionScanner.sessionRoot.path.hasPrefix(codexHome.path)
        ? CodexSessionScanner.scan() : [])
let runs = all.filter { $0.scheduledTaskName == "nightly-report" }
check("both agents' scheduled runs group under the task",
      runs.count == (CodexSessionScanner.sessionRoot.path.hasPrefix(codexHome.path) ? 2 : 1),
      "— got \(runs.count): \(runs.map(\.agentKey))")

try? fm.removeItem(at: sandbox)
print("\n\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
