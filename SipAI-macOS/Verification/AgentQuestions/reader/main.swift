// AgentQuestions harness, section 6 — the REAL transcript reader
// (`AgentSessionScanner.lastTurnDurationSeconds`) over synthetic claude
// transcripts in the measured shape: a wait on the user sits between the
// tool_use record of a call that does nothing but wait — AskUserQuestion,
// ExitPlanMode — and the record carrying its result.
//
// Argument: <work-dir>
import Foundation

let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    .appendingPathComponent("reader", isDirectory: true)
try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

var passed = 0
var failed = 0
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

let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let t0 = Date(timeIntervalSince1970: 1_790_000_000)
func stamp(_ seconds: TimeInterval) -> String { formatter.string(from: t0.addingTimeInterval(seconds)) }

func prompt(at s: TimeInterval) -> [String: Any] {
    ["type": "user", "timestamp": stamp(s),
     "message": ["role": "user", "content": "Build the probe."]]
}
func ask(_ id: String, at s: TimeInterval) -> [String: Any] {
    ["type": "assistant", "timestamp": stamp(s),
     "message": ["role": "assistant", "stop_reason": "tool_use",
                 "content": [["type": "tool_use", "id": id, "name": "AskUserQuestion",
                              "input": ["questions": [["question": "Which color?", "header": "Color",
                                                       "multiSelect": false,
                                                       "options": [["label": "Red", "description": "Warm"],
                                                                   ["label": "Blue", "description": "Cool"]]]]]]]]]
}
func plan(_ id: String, at s: TimeInterval) -> [String: Any] {
    ["type": "assistant", "timestamp": stamp(s),
     "message": ["role": "assistant", "stop_reason": "tool_use",
                 "content": [["type": "tool_use", "id": id, "name": "ExitPlanMode",
                              "input": ["plan": "# Plan\n", "planFilePath": "/tmp/plans/p.md"]]]]]
}
func bash(_ id: String, at s: TimeInterval) -> [String: Any] {
    ["type": "assistant", "timestamp": stamp(s),
     "message": ["role": "assistant", "stop_reason": "tool_use",
                 "content": [["type": "tool_use", "id": id, "name": "Bash",
                              "input": ["command": "ls"]]]]]
}
func result(_ id: String, at s: TimeInterval) -> [String: Any] {
    ["type": "user", "timestamp": stamp(s),
     "message": ["role": "user",
                 "content": [["type": "tool_result", "tool_use_id": id, "content": "done"]]]]
}
func answer(at s: TimeInterval) -> [String: Any] {
    ["type": "assistant", "timestamp": stamp(s),
     "message": ["role": "assistant", "stop_reason": "end_turn",
                 "content": [["type": "text", "text": "Done."]]]]
}

func duration(_ name: String, _ records: [[String: Any]]) -> Double {
    let url = work.appendingPathComponent(name + ".jsonl")
    let lines = records.map {
        String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
    }
    try! (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return AgentSessionScanner.lastTurnDurationSeconds(of: url)
}

print("\n6. A reopened session's last-turn time leaves the waits on the user out (AgentSessionScanner)")
let plain = duration("plain", [prompt(at: 0), bash("t1", at: 2), result("t1", at: 62), answer(at: 70)])
check("control: a turn with no question is timed wall-clock, a slow tool included", plain == 70,
      "got \(plain)")
let one = duration("one-question", [prompt(at: 0), ask("q1", at: 2), result("q1", at: 62), answer(at: 70)])
check("a 60 s wait on the user's answer is left out", one == 10, "got \(one)")
let two = duration("two-questions", [prompt(at: 0), ask("q1", at: 5), result("q1", at: 25),
                                     bash("t1", at: 30), result("t1", at: 40),
                                     ask("q2", at: 45), result("q2", at: 75), answer(at: 100)])
check("every wait of the turn is left out, and nothing else", two == 50, "got \(two)")
let earlier = duration("earlier-turn", [prompt(at: 0), ask("q1", at: 2), result("q1", at: 62), answer(at: 70),
                                        prompt(at: 100), bash("t1", at: 102), result("t1", at: 110),
                                        answer(at: 120)])
check("a question of an EARLIER turn does not shorten the last one", earlier == 20, "got \(earlier)")
let unanswered = duration("never-answered", [prompt(at: 0), ask("q1", at: 2), answer(at: 70)])
check("a question with no result on record subtracts nothing", unanswered == 70, "got \(unanswered)")
let planned = duration("plan-approved", [prompt(at: 0), plan("p1", at: 20), result("p1", at: 320),
                                         bash("t1", at: 325), result("t1", at: 330), answer(at: 340)])
check("a plan waiting five minutes for its approval is left out the same way", planned == 40,
      "got \(planned)")
let revised = duration("plan-revised", [prompt(at: 0), plan("p1", at: 10), result("p1", at: 70),
                                        plan("p2", at: 90), result("p2", at: 150), answer(at: 160)])
check("…each time it is handed over: a plan sent back and approved on its second try",
      revised == 40, "got \(revised)")
// Two cards up at once are one stretch of waiting, as they were on the
// live clock: 10…50 and 30…70 cover 60 s between them, not 80.
let overlapping: [[String: Any]] = [
    prompt(at: 0),
    ["type": "assistant", "timestamp": stamp(10),
     "message": ["role": "assistant", "stop_reason": "tool_use",
                 "content": [["type": "tool_use", "id": "q1", "name": "AskUserQuestion", "input": [String: Any]()]]]],
    ["type": "assistant", "timestamp": stamp(30),
     "message": ["role": "assistant", "stop_reason": "tool_use",
                 "content": [["type": "tool_use", "id": "p1", "name": "ExitPlanMode", "input": [String: Any]()]]]],
    result("q1", at: 50), result("p1", at: 70), answer(at: 100),
]
let overlapped = duration("overlapping", overlapping)
check("two waits that overlap are counted once", overlapped == 40, "got \(overlapped)")
let slowTool = duration("permission-wait", [prompt(at: 0), bash("t1", at: 5), result("t1", at: 65), answer(at: 70)])
check("known limit: a permission card's wait cannot be told from the tool's own run, so it stays in",
      slowTool == 70, "got \(slowTool)")

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
