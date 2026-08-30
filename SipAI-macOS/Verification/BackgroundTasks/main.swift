// Verification harness — background tasks under `claude -p`.
//
// THE RULE. A backgrounded task does not survive `claude -p`. Print
// mode begins winding down the moment stdin is at EOF, and a SipAI
// child is handed /dev/null, so a still-running background task is
// terminated five seconds after the turn's `result` — measured at
// 5.05-5.10 s across every run. Nothing renders the three `system`
// records that report it, the child exits 0 with an empty stderr, and
// the transcript records nothing, so the loss is silent on the live
// feed AND on reopen.
//
// The fix is to switch the feature off at the source, so the agent
// never reaches for it: with CLAUDE_CODE_DISABLE_BACKGROUND_TASKS set,
// claude omits `run_in_background` from the Bash tool's input schema
// and the agent runs the command in the foreground instead.
//
// WHAT THIS PINS, and why each check exists:
//
//  1. The overlay is keyed on the AGENT. Codex has no such parameter
//     to disable and kimi already handles background tasks correctly —
//     setting anything for kimi actively makes it worse. A shared slot
//     would hand one agent another's environment, the same hazard
//     `config.agentLaunchOptions(for:)` exists for.
//  2. The overlay OVERRIDES. A value inherited from the user's shell
//     must lose; the whole failure is silent, so a `…=0` exported in a
//     .zshrc would re-enable it with nothing on screen admitting it.
//  3. `AgentRunner` still applies it, AFTER `buildEnvironment` (which
//     starts from our own process environment — applying it before
//     would let the inherited value win).
//  4. The env var still EXISTS in the installed claude. This is the
//     check that matters over time: the whole fix rests on one
//     undocumented variable read out of a bundled binary, and if a
//     future Claude Code drops or renames it, background tasks come
//     back with no symptom at all.
//
// Section 5 is the behavioural pass. It spends tokens on a real turn,
// so it is opt-in: set SIPAI_BG_LIVE=1.

import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String, _ why: @autoclosure () -> String = "") {
    if ok { print("  ok    \(name)") }
    else {
        failures += 1
        print("  FAIL  \(name)")
        let w = why(); if !w.isEmpty { print("        \(w)") }
    }
}

let sourceRoot = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath
func read(_ rel: String) -> String {
    (try? String(contentsOfFile: sourceRoot + "/" + rel, encoding: .utf8)) ?? ""
}

// ── 1. the overlay is keyed on the agent ─────────────────────────────
print("1. per-agent verdict")

let claudeEnv = ClaudePrintMode.environmentOverlay(agentKey: "claude_code")
check(claudeEnv[ClaudePrintMode.disableBackgroundTasksEnvVar] == "1",
      "claude gets the disable var",
      "got \(claudeEnv) — a claude turn will keep silently discarding "
      + "backgrounded work")
for other in ["codex", "kimi", "", "some_future_agent"] {
    check(ClaudePrintMode.environmentOverlay(agentKey: other).isEmpty,
          "\(other.isEmpty ? "(empty key)" : other) gets nothing",
          "codex has no such parameter to disable, and kimi's print mode "
          + "already reports background work correctly — setting this for "
          + "kimi would make it worse, not better")
}

// ── 2. it overrides, it does not default ─────────────────────────────
print("2. inherited value must lose")

// The overlay is a plain dictionary applied over the child environment,
// so "overrides" means the runner ASSIGNS rather than filling a gap.
// Simulate both spellings against a hostile inherited environment.
var env = ["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "0", "PATH": "/usr/bin"]
for (k, v) in ClaudePrintMode.environmentOverlay(agentKey: "claude_code") {
    env[k] = v
}
check(env["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] == "1",
      "a shell-exported =0 is overridden",
      "the user's shell would re-enable a mechanism that cannot work "
      + "here, and nothing anywhere would say so")
check(env["PATH"] == "/usr/bin", "nothing else in the environment moves")

// ── 3. the runner still applies it, in the right place ───────────────
print("3. AgentRunner wiring")

let runner = read("SipAI/Models/AgentRunner.swift")
check(!runner.isEmpty, "AgentRunner.swift is readable at \(sourceRoot)")
check(runner.contains("ClaudePrintMode.environmentOverlay(agentKey: agentKey)"),
      "runOnce applies the overlay",
      "without this the whole fix is dead code")

if let overlayAt = runner.range(of: "ClaudePrintMode.environmentOverlay(agentKey: agentKey)"),
   let buildAt = runner.range(of: "var env = Self.buildEnvironment()") {
    check(buildAt.lowerBound < overlayAt.lowerBound,
          "applied AFTER buildEnvironment",
          "buildEnvironment starts from our own process environment; "
          + "applying the overlay before it lets the inherited value win")
} else {
    check(false, "applied AFTER buildEnvironment", "anchors not found")
}

// The composer must not offer this as a choice: it is a constraint of
// the harness, not a decision. A chip for it would promise a mode that
// does not exist.
let composer = read("SipAI/Views/Chat/AgentComposer.swift")
check(!composer.isEmpty && !composer.contains("DISABLE_BACKGROUND_TASKS"),
      "the composer offers no switch for it",
      composer.isEmpty
        ? "AgentComposer.swift unreadable — the check would otherwise pass "
          + "on an empty string, which is how a harness lies"
        : "this is a fact about `claude -p`, not a per-send choice")

// ── 4. claude still has the switch ───────────────────────────────────
print("4. the switch still exists in the installed claude")

func claudeBinary() -> String? {
    let home = NSHomeDirectory()
    let versions = home + "/.local/share/claude/versions"
    let fm = FileManager.default
    if let names = try? fm.contentsOfDirectory(atPath: versions) {
        let real = names.filter {
            let a = try? fm.attributesOfItem(atPath: versions + "/" + $0)
            return ((a?[.size] as? Int) ?? 0) > 1_000_000
        }.sorted()
        if let newest = real.last { return versions + "/" + newest }
    }
    for c in [home + "/.local/bin/claude", "/opt/homebrew/bin/claude",
              "/usr/local/bin/claude"] where fm.isExecutableFile(atPath: c) {
        return c
    }
    return nil
}

if let bin = claudeBinary() {
    print("     (\(bin))")
    // `strings` over a 300 MB binary, filtered — cheaper than reading it in.
    func binaryContains(_ needle: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["sh", "-c",
                       "strings -a '\(bin)' 2>/dev/null | grep -c -- '\(needle)' || true"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? "0"
        return (Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }
    check(binaryContains(ClaudePrintMode.disableBackgroundTasksEnvVar),
          "\(ClaudePrintMode.disableBackgroundTasksEnvVar) is still read by claude",
          "the variable is gone or renamed — background tasks are BACK, "
          + "and they fail silently. Re-derive the switch before shipping.")
    check(binaryContains("run_in_background"),
          "claude still has the parameter being disabled",
          "if this is gone the feature was removed upstream and the "
          + "overlay is now a no-op that can be retired")
} else {
    print("  SKIP  claude not installed — cannot check the switch")
}

// ── 5. behavioural (opt-in; spends tokens) ───────────────────────────
print("5. live turn")
if ProcessInfo.processInfo.environment["SIPAI_BG_LIVE"] == "1",
   let bin = claudeBinary() {
    let dir = NSTemporaryDirectory() + "sipai-bgverify-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: dir,
                                             withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = ["-p",
        "Use the Bash tool with run_in_background=true to run: sleep 2; "
        + "touch bg.txt . Then say in one sentence whether the Bash tool "
        + "offered you a run_in_background parameter.",
        "--output-format", "stream-json", "--verbose",
        "--permission-mode", "bypassPermissions"]
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    var e = ProcessInfo.processInfo.environment
    for (k, v) in ClaudePrintMode.environmentOverlay(agentKey: "claude_code") {
        e[k] = v
    }
    p.environment = e
    p.standardInput = FileHandle.nullDevice
    let pipe = Pipe(); p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    // The parameter must not appear in any tool_use input claude emitted.
    check(!text.contains("\"run_in_background\""),
          "no tool call carried run_in_background",
          "the switch no longer removes the parameter — a backgrounded "
          + "task will be killed 5 s after the answer, silently")
    check(FileManager.default.fileExists(atPath: dir + "/bg.txt"),
          "the command actually ran (foreground) and completed",
          "the work did not land — the point of the fix is that it does")
    try? FileManager.default.removeItem(atPath: dir)
} else {
    print("  SKIP  set SIPAI_BG_LIVE=1 to run a real turn (spends tokens)")
}

print("")
if failures == 0 { print("All background-task checks passed.") }
else { print("\(failures) check(s) FAILED."); exit(1) }
