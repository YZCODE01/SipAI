// The gate the pointer harnesses share (SyntheticHover.swift), checked
// with its probe's answer given — hover dead, alive, and gone in the
// middle of a run — then the real probe: against a view it must not count,
// and under macOS's answer about the cursor put either way by the library
// run.sh preloads (cursor_visible.sh), which is the answer SwiftUI waits
// for before it honours a pointer event. Then the five harnesses read for
// their wiring. Ends with what the probe answers under macOS's REAL answer
// on this Mac now, as a note: it is a fact about the Mac, not a check.
//
//   run by run.sh: SyntheticHover <verification folder>

import AppKit
import SwiftUI

setvbuf(stdout, nil, _IONBF, 0)

var passed = 0
var failed = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    if ok {
        passed += 1
        print("  ok   \(label)")
    } else {
        failed += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

/// A gate whose probe gives `answers` in turn (then no), and what the
/// gate did: the checks it handed on, the lines it printed, the probes.
@MainActor
final class Run {
    final class Seen {
        var reported: [(label: String, ok: Bool)] = []
        var said: [String] = []
        var probes = 0
    }
    let box: Seen
    let gate: HoverGate
    init(answers: [Bool]) {
        let box = Seen()
        var queue = answers
        gate = HoverGate(report: { label, ok, _ in box.reported.append((label, ok)) },
                         probe: {
                             box.probes += 1
                             return queue.isEmpty ? false : queue.removeFirst()
                         },
                         say: { box.said.append($0) })
        self.box = box
    }
}

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)

    print("1. The gate, with the probe's answer given")
    do {
        let dead = Run(answers: [false])
        dead.gate.check("a check that would pass", true)
        dead.gate.check("a check that would fail", false, "detail")
        check("hover dead: neither check is judged — no pass and no failure",
              dead.box.reported.isEmpty, "\(dead.box.reported)")
        check("…each says SKIP, its label and why, once",
              dead.box.said.count == 2
                && dead.box.said[0] == "  SKIP a check that would pass — \(SyntheticHover.reason)"
                && dead.box.said[1] == "  SKIP a check that would fail — \(SyntheticHover.reason)",
              "\(dead.box.said)")
        check("…and no line it prints reads as a failure",
              !dead.box.said.contains { $0.range(of: #"\bFAIL\b"#, options: .regularExpression) != nil })
        check("…the probe asked once, when the gate was made", dead.box.probes == 1, "\(dead.box.probes)")

        let alive = Run(answers: [true, true])
        alive.gate.check("a passing check", true)
        alive.gate.check("a failing check", false)
        check("hover alive: both checks are judged by the harness's own check, as they came",
              alive.box.reported.map(\.label) == ["a passing check", "a failing check"]
                && alive.box.reported.map(\.ok) == [true, false],
              "\(alive.box.reported)")
        check("…nothing is skipped", alive.box.said.isEmpty, "\(alive.box.said)")
        check("…a failure asks the probe again before it is reported", alive.box.probes == 2, "\(alive.box.probes)")

        let gone = Run(answers: [true, false])
        gone.gate.check("a check before hover stops", true)
        gone.gate.check("a check that fails as hover stops", false)
        gone.gate.check("a check after it that would pass", true)
        check("hover gone mid-run: the failure is a SKIP, not a failure",
              gone.box.reported.map(\.label) == ["a check before hover stops"],
              "\(gone.box.reported)")
        check("…and every later check of that gate skips with it, a pass included",
              gone.box.said.count == 2 && gone.box.said[1].contains("a check after it that would pass"),
              "\(gone.box.said)")
    }

    print("2. The real probe")
    // macOS's real answer first, for the note at the end: the library answers it whenever
    // HARNESS_CURSOR_VISIBLE is unset.
    unsetenv("HARNESS_CURSOR_VISIBLE")
    let reachesForReal = SyntheticHover.reachesSwiftUI()
    setenv("HARNESS_CURSOR_VISIBLE", "0", 1)
    let underHidden = SyntheticHover.reachesSwiftUI(wait: 1)
    setenv("HARNESS_CURSOR_VISIBLE", "1", 1)
    check("macOS reporting the cursor hidden (as under Screen Sharing for a pointer at rest), the probe "
          + "gets no hover: SwiftUI honours no pointer event then", !underHidden)
    let started = Date()
    let reaches = SyntheticHover.reachesSwiftUI()
    let took = Date().timeIntervalSince(started)
    check("…reporting it visible, the probe gets hover: the answer the pointer harnesses run under",
          reaches)
    check("the library leaves the environment once loaded, so nothing the program starts loads it "
          + "(the app's agent CLIs inherit its environment)",
          getenv("DYLD_INSERT_LIBRARIES") == nil && getenv("HARNESS_CURSOR_VISIBLE") != nil)
    check("it answers within its bound (\(String(format: "%.1f", took)) s)", took < 4)
    let beside = SyntheticHover.probe(pointingAt: CGPoint(x: 120, y: 30), wait: 1)
    check("pointed beside its view, it counts no hover", !beside)
    setenv(SyntheticHover.offSwitch, "1", 1)
    let offProbe = SyntheticHover.reachesSwiftUI()
    let off = Run(answers: [offProbe])
    off.gate.check("a check under the switch", true)
    unsetenv(SyntheticHover.offSwitch)
    check("\(SyntheticHover.offSwitch)=1: the probe answers no, and a skip names the switch",
          !offProbe && off.box.said.first?.contains("\(SyntheticHover.offSwitch)=1 is set") == true,
          "probe \(offProbe), said \(off.box.said)")

    print("3. The wiring: each pointer harness compiles the gate and judges its pointer checks through it")
    let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
    func read(_ relative: String) -> String {
        (try? String(contentsOfFile: root + "/" + relative, encoding: .utf8)) ?? ""
    }
    for (harness, main) in [("NewSessionSetup", "Page/main.swift"), ("UsageWindow", "Render/main.swift"),
                            ("SkillsPane", "main.swift"), ("SidebarNotices", "main.swift"),
                            ("LinkPointers", "main.swift")] {
        let script = read("\(harness)/run.sh")
        let source = read("\(harness)/\(main)")
        check("\(harness): run.sh compiles SyntheticHover.swift", script.contains("SyntheticHover/SyntheticHover.swift"))
        check("\(harness): its pointer checks go through a HoverGate",
              source.contains("HoverGate(report:") && source.contains(".check("))
        check("\(harness): run.sh runs its program with the cursor reported visible",
              script.contains("SyntheticHover/cursor_visible.sh") && script.contains("cursor_preload ")
                && (script.contains("cursor_visible_within ") || script.contains("cursor_visible \""))
                && !script.contains("perl -e 'alarm"))
    }
    let helper = read("SyntheticHover/cursor_visible.sh")
    check("the bounded run names the library inside perl: macOS strips DYLD_* from a system binary's "
          + "environment, so a preload set before perl never reaches the program",
          helper.contains("$ENV{DYLD_INSERT_LIBRARIES}") && helper.contains("exec @ARGV"))

    print("\n  NOTE on this Mac now, under macOS's real answer about the cursor, a made-up pointer "
          + "\(reachesForReal ? "reaches" : "does NOT reach") SwiftUI; the pointer harnesses report the cursor "
          + "visible inside their own programs, so their checks are judged either way")
    print("\nSyntheticHover: \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}
