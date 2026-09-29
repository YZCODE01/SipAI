import Foundation
import Darwin

// Drives the REAL HangCapture (compiled from Utilities/HangCapture.swift
// with DEBUG on) — the verdict table headless, then the watchdog itself
// against a genuinely blocked main thread, with a fast threshold and a
// throwaway HOME handed in by run.sh.

var failures = 0
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("  \(ok ? "PASS" : "FAIL")  \(label)")
    if !detail.isEmpty { print("        \(detail)") }
    if !ok { failures += 1 }
}

// MARK: 1. The verdict, as a pure function

print("1. HangCapture.decide")
typealias A = HangCapture.Action
let th = 12.0
check(HangCapture.decide(beatMoved: true, overshoot: false, idleFor: 99, threshold: th, captured: true, count: 0) == .resetEpisode,
      "a beat resets the episode, whatever else is true")
check(HangCapture.decide(beatMoved: false, overshoot: true, idleFor: 99, threshold: th, captured: false, count: 0) == .resetEpisode,
      "a poll that overshot (debugger pause, sleep) resets without capturing")
check(HangCapture.decide(beatMoved: false, overshoot: false, idleFor: 11.9, threshold: th, captured: false, count: 0) == .none,
      "idle under the threshold is not a hang")
check(HangCapture.decide(beatMoved: false, overshoot: false, idleFor: 12, threshold: th, captured: false, count: 0) == .capture,
      "idle at the threshold captures")
check(HangCapture.decide(beatMoved: false, overshoot: false, idleFor: 400, threshold: th, captured: true, count: 1) == .none,
      "one capture per episode — a longer hang does not capture again")
check(HangCapture.decide(beatMoved: false, overshoot: false, idleFor: 400, threshold: th, captured: false, count: HangCapture.capturesPerLaunch) == .none,
      "the per-launch budget holds")

// MARK: 2. The watchdog against a real blocked main thread

print("2. the watchdog, a real block, a real sample")
let home = ProcessInfo.processInfo.environment["HOME"] ?? "/nonexistent"
let dir = home + "/Library/Logs/SipAI"
func captures() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasPrefix("hang-") && $0.hasSuffix(".txt") }.sorted()
}
func spinMain(seconds: Double) {
    // Beats: BeforeTimers/BeforeWaiting fire as the loop cycles.
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { CFRunLoopRunInMode(.defaultMode, 0.05, true) }
}
func waitForCaptureCount(_ n: Int, within seconds: Double) -> Bool {
    // The main thread stays BLOCKED here on purpose: sleep, not a run
    // loop. Polling the directory is the only thing it does.
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if captures().count >= n { return true }
        sleep(1)
    }
    return captures().count >= n
}

HangCapture.start()
check(FileManager.default.fileExists(atPath: dir), "start() creates the log directory", dir)
spinMain(seconds: 1.5)
check(captures().isEmpty, "a cycling main thread is not captured")
// The trap the app-level run found: a main thread that is merely IDLE
// — waiting for events, nothing scheduled — does not cycle its loop.
// The watchdog's ping must be what wakes it, or quiet reads as hung.
// Wait here for sources only (no timers), for twice the threshold.
_ = CFRunLoopRunInMode(.defaultMode, 7, false)
check(captures().isEmpty, "an idle main thread is not captured — the ping wakes it", "\(captures())")

// Block the main thread. With SIPAI_HANG_THRESHOLD=3 and the 2 s poll,
// the capture starts ~4 s in; `sample` runs 5 s, then symbolicates.
let t0 = Date()
let first = waitForCaptureCount(1, within: 25)
let firstAt = Date().timeIntervalSince(t0)
check(first, "a blocked main thread is captured once",
      first ? "file after \(Int(firstAt)) s: \(captures())" : "no capture within 25 s in \(dir)")
if first, let name = captures().first,
   let text = try? String(contentsOfFile: dir + "/" + name, encoding: .utf8) {
    check(text.contains("Call graph:") && text.contains("Thread_"),
          "the capture is a real sample: call graph with threads",
          "\(text.count) bytes")
    // Judge the MAIN thread's own block, not the whole file: the
    // watchdog's usleep and every other thread are in there too, so a
    // file-wide "sleep" proves nothing.
    let mainBlock: String = {
        guard let start = text.range(of: "com.apple.main-thread") else { return "" }
        let rest = text[start.lowerBound...]
        let end = rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }()
    check(!mainBlock.isEmpty && (mainBlock.contains("nanosleep") || mainBlock.contains("__semwait_signal")),
          "…and the MAIN thread's stack shows the block (nanosleep / __semwait_signal)",
          mainBlock.isEmpty ? "no main-thread block found in the sample" : "\(mainBlock.count) bytes of main-thread stack")
    check(text.contains("SipAI.HangCapture"),
          "…and the watchdog thread is named, so a reader can skip it")
}
// Still idle, same episode: no second capture.
sleep(6)
check(captures().count == 1, "the same episode is not captured twice", "\(captures())")

// The main thread comes back, then hangs again: a new episode, a new file.
spinMain(seconds: 3)
let second = waitForCaptureCount(2, within: 25)
check(second, "a second hang after recovery is a second capture", "\(captures())")

print(failures == 0 ? "\nAll HangCapture checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
