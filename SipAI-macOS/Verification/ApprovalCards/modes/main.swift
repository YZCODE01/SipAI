// ApprovalCards harness, the mode reader — the REAL
// `AgentEventParser.permissionMode(line:)` over the stdout the real claude
// wrote in section 4 (one directory per scenario), and over a few lines in
// the measured shape for what a run here cannot produce on demand.
//
// Argument: <work-dir>
import Foundation

let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

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
func note(_ text: String) { print("        \(text)") }

/// The modes claude named over one turn, in order, as the runner reads
/// them; nil when the scenario did not run.
func modes(of scenario: String) -> [String]? {
    let url = work.appendingPathComponent(scenario).appendingPathComponent("stdout.jsonl")
    guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return nil }
    return text.split(separator: "\n").compactMap { AgentEventParser.permissionMode(line: String($0)) }
}

/// What the runner keeps: the newest mode that is not Plan.
func modeBeforePlan(_ modes: [String]) -> String? { modes.last { $0 != "plan" } }

print("\n7. The mode a turn is in, read from claude's own records (AgentEventParser.permissionMode)")
func line(_ fields: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
}
check("a turn's init record names its mode",
      AgentEventParser.permissionMode(line: line(["type": "system", "subtype": "init",
                                                  "permissionMode": "acceptEdits"])) == "acceptEdits")
check("…and a status record names each change",
      AgentEventParser.permissionMode(line: line(["type": "system", "subtype": "status",
                                                  "permissionMode": "plan"])) == "plan")
check("a main-loop record says `parent_tool_use_id: null`, and still counts",
      AgentEventParser.permissionMode(line: line(["type": "system", "subtype": "status",
                                                  "permissionMode": "auto",
                                                  "parent_tool_use_id": NSNull()])) == "auto")
check("a subagent's record is its own context's, not the session's",
      AgentEventParser.permissionMode(line: line(["type": "system", "subtype": "status",
                                                  "permissionMode": "plan",
                                                  "parent_tool_use_id": "toolu_1"])) == nil)
check("no other record names a mode",
      AgentEventParser.permissionMode(line: line(["type": "assistant", "permissionMode": "plan"])) == nil
        && AgentEventParser.permissionMode(line: line(["type": "system", "subtype": "compact_boundary",
                                                       "permissionMode": "plan"])) == nil
        && AgentEventParser.permissionMode(line: "not json \"permissionMode\"") == nil
        && AgentEventParser.permissionMode(line: line(["type": "system", "subtype": "init",
                                                       "permissionMode": ""])) == nil)
check("a line the terminal ended with a carriage return still reads",
      AgentEventParser.permissionMode(line: line(["type": "system", "subtype": "init",
                                                  "permissionMode": "default"]) + "\r") == "default")

if let first = modes(of: "first") {
    check("the real claude, launched on Default: its first record says so",
          first.first == "default" && modeBeforePlan(first) == "default", "got \(first)")
} else {
    note("SKIP  no claude run to read (section 4 was skipped)")
}
if let approved = modes(of: "plan-approve") {
    check("launched on Plan, approved with auto-accept edits: claude reports plan, then acceptEdits",
          approved.first == "plan" && approved.last == "acceptEdits", "got \(approved)")
}
if let kept = modes(of: "plan-keep") {
    check("a plan kept stays in plan mode — and leaves no mode to go back to",
          Set(kept) == ["plan"] && modeBeforePlan(kept) == nil, "got \(kept)")
}
if let auto = modes(of: "plan-auto") {
    if auto.last == "auto" {
        check("approved with \"Yes, and use auto mode\": claude reports auto", true)
    } else {
        note("this claude did not enter auto mode on approval (it reported \(auto)); "
             + "auto mode is the account's and the model's to offer")
    }
}
if let edits = modes(of: "accept-edits") {
    check("launched on Accept Edits: that is the mode a later plan would go back to",
          modeBeforePlan(edits) == "acceptEdits", "got \(edits)")
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
