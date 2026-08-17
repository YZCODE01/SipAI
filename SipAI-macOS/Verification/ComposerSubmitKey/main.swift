// Headless check of the Enter key in the app's AppKit text inputs.
//
// Two passes:
//
//   1. Structural, over the REAL view files: every NSViewRepresentable
//      whose Coordinator caches the representable struct must re-point
//      that cache in updateNSView. A coordinator is made once; the
//      struct it was handed is a SNAPSHOT of its host, so a key handler
//      reading it drives whatever the host looked like when the view was
//      built.
//
//   2. Behavioural, driving the REAL GrowingTextField (extracted from
//      AgentComposer.swift by run.sh, never copied) in an offscreen
//      window, with a host that mirrors the composer's shape: a plain
//      `sending` property and an onSubmit closure guarded by `canSend`.
//      Both directions are pinned — a composer born mid-turn must send
//      once the turn ends, and one born idle must NOT send once an
//      external turn starts.
//
// Nothing here is part of the app target: this directory sits outside
// SipAI/, so these files are never compiled into the product.

import SwiftUI
import AppKit

let sourceRoot = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

var failures: [String] = []

func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    if ok {
        print("  ok    \(label)")
    } else {
        let extra = detail()
        print("  FAIL  \(label)\(extra.isEmpty ? "" : " — \(extra)")")
        failures.append(label)
    }
}

// MARK: - Pass 1: every cached coordinator is re-pointed

/// A line with any trailing comment removed. Every structural match
/// below goes through this: the fix being checked for is a single line,
/// and a COMMENTED copy of it reads as present to a plain `contains` —
/// which is a harness that passes over the very bug it exists to catch.
func codeOnly(_ line: String) -> String {
    guard let marker = line.range(of: "//") else { return line }
    return String(line[line.startIndex..<marker.lowerBound])
}

/// The lines of `text` spanning the block that starts at `start`, using
/// brace depth. Comments and string literals are not parsed — the app's
/// sources put no unbalanced brace in either, and a miscount would show
/// up as a loud failure here rather than a silent pass.
func block(of lines: [String], from start: Int) -> [String] {
    var depth = 0
    var out: [String] = []
    for line in lines[start...] {
        out.append(line)
        depth += line.filter { $0 == "{" }.count
        depth -= line.filter { $0 == "}" }.count
        if depth <= 0 && out.count > 1 { break }
    }
    return out
}

func scanRepresentables(in path: String) {
    let url = URL(fileURLWithPath: path)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        check(false, "read \(url.lastPathComponent)")
        return
    }
    let lines = text.components(separatedBy: "\n")
    var found = 0
    for (i, line) in lines.enumerated()
    where codeOnly(line).contains("NSViewRepresentable") && codeOnly(line).contains("struct ") {
        found += 1
        let name = line.components(separatedBy: "struct ").last?
            .components(separatedBy: ":").first?
            .trimmingCharacters(in: .whitespaces) ?? "?"
        let body = block(of: lines, from: i)
        // A coordinator that caches nothing has nothing to go stale.
        guard body.contains(where: { codeOnly($0).contains("var parent") }) else {
            print("  ok    \(name) — coordinator caches no parent")
            continue
        }
        guard let updateAt = body.firstIndex(where: { codeOnly($0).contains("func updateNSView") }) else {
            check(false, "\(name) has updateNSView", "no updateNSView to re-point in")
            continue
        }
        let update = block(of: body, from: updateAt)
        check(update.contains { codeOnly($0).contains("coordinator.parent = self") },
              "\(name) re-points its coordinator",
              "updateNSView must assign context.coordinator.parent = self")
    }
    check(found > 0, "\(url.lastPathComponent) declares a representable")
}

print("1. coordinator freshness (real sources)")
for relative in ["SipAI/Views/Chat/AgentComposer.swift",
                 "SipAI/Views/Chat/MessageInput.swift",
                 "SipAI/Views/Chat/TranscriptFind.swift",
                 "SipAI/Views/Notes/NoteView.swift"] {
    scanRepresentables(in: sourceRoot + "/" + relative)
}

// MARK: - Pass 2: the real GrowingTextField, driven by Return

/// Mirrors `AgentComposer`: `sending` is a plain stored property, and
/// the submit closure consults it through `canSend`. This is the
/// SCENARIO, not a copy of the code under test — GrowingTextField
/// itself is extracted from the shipping file.
private struct ProbeComposer: View {
    @ObservedObject var model: ProbeModel
    var sending: Bool

    private var hasText: Bool {
        !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canSend: Bool { hasText && !sending }

    var body: some View {
        GrowingTextField(
            text: $model.text,
            measuredHeight: $model.height,
            onSubmit: { if canSend { model.submits += 1 } },
            spellChecking: false
        )
        .frame(width: 320, height: 60)
    }
}

private struct ProbeRoot: View {
    @ObservedObject var model: ProbeModel
    var body: some View { ProbeComposer(model: model, sending: model.sending) }
}

private final class ProbeModel: ObservableObject {
    @Published var sending: Bool
    @Published var text: String = "hello"
    @Published var height: CGFloat = 30
    var submits = 0
    init(sending: Bool) { self.sending = sending }
}

private func findTextView(in view: NSView) -> NSTextView? {
    if let tv = view as? NSTextView { return tv }
    for sub in view.subviews {
        if let tv = findTextView(in: sub) { return tv }
    }
    return nil
}

/// One scenario: build the composer with `bornSending`, flip to
/// `thenSending`, press Return, and report whether it sent.
private func runScenario(bornSending: Bool, thenSending: Bool) -> Bool? {
    let model = ProbeModel(sending: bornSending)
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: ProbeRoot(model: model))
    window.orderFront(nil)

    // Let SwiftUI build and lay the view out, then let the flip land as
    // its own update pass — that pass is what re-points the coordinator.
    pump(0.5)
    model.sending = thenSending
    pump(0.5)

    guard let content = window.contentView,
          let tv = findTextView(in: content) else { return nil }
    window.makeFirstResponder(tv)
    guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, characters: "\r",
                                      charactersIgnoringModifiers: "\r",
                                      isARepeat: false, keyCode: 36)
    else { return nil }
    window.sendEvent(down)
    pump(0.2)
    window.orderOut(nil)
    return model.submits > 0
}

/// Spin the run loop so SwiftUI's update cycle actually runs; this
/// process never calls NSApplication.run().
private func pump(_ seconds: Double) {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

print("")
print("2. Return through the real GrowingTextField")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Born mid-turn — the state the composer is in whenever the user comes
// back to a running session, since the router rebuilds the view on
// every detour to a chat or a note. Once the turn ends, Return sends.
switch runScenario(bornSending: true, thenSending: false) {
case .some(true):  check(true, "born mid-turn, turn ended → Return sends")
case .some(false): check(false, "born mid-turn, turn ended → Return sends",
                         "Return did nothing while the send button would have worked")
case nil:          check(false, "born mid-turn, turn ended → Return sends", "no text view / no event")
}

// Born idle, then an external turn starts. Sending here would put a
// second writer on one session — the exact thing `externalBusy` gates.
switch runScenario(bornSending: false, thenSending: true) {
case .some(false): check(true, "born idle, external turn started → Return is refused")
case .some(true):  check(false, "born idle, external turn started → Return is refused",
                         "Return sent into a session another writer owns")
case nil:          check(false, "born idle, external turn started → Return is refused", "no text view / no event")
}

print("")
if failures.isEmpty {
    print("PASS — every coordinator is fresh, and Return follows the composer's state")
    exit(0)
} else {
    print("FAILED (\(failures.count)):")
    for f in failures { print("  - \(f)") }
    exit(1)
}
