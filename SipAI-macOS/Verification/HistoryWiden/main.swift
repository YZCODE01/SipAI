// Headless check of the history-widen path. See run.sh for scope.
//
// Nothing here is part of the app target.
import Foundation

var failures = 0
var checks = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    checks += 1
    if ok {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

// MARK: - Fixtures

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("historywiden-\(UUID().uuidString)",
                            isDirectory: true)
try! FileManager.default.createDirectory(at: tmp,
                                         withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

/// One claude-format turn: a user record and an assistant record, the
/// assistant padded to `padBytes` so a fixture can outgrow the byte
/// budget with few turns (the tool-heavy shape the real store shows:
/// 13.4 MB / 11 turns on the machine this was written on).
func turn(_ i: Int, padBytes: Int = 0) -> [String] {
    let pad = padBytes > 0
        ? String(repeating: "x", count: padBytes) : "answer"
    return [
        #"{"type":"user","uuid":"u\#(i)","message":{"content":"TURN-\#(i) question"}}"#,
        #"{"type":"assistant","uuid":"a\#(i)","message":{"model":"claude-t","content":[{"type":"text","text":"\#(pad)"}]}}"#,
    ]
}

func write(_ name: String, _ lines: [String]) -> URL {
    let url = tmp.appendingPathComponent(name)
    try! (lines.joined(separator: "\n") + "\n")
        .write(to: url, atomically: true, encoding: .utf8)
    return url
}

func userTurns(_ items: [AgentSessionHistoryItem]) -> [String] {
    items.compactMap {
        if case .userText(let t) = $0.kind {
            return String(t.split(separator: " ").first ?? "")
        }
        return nil
    }
}

// MARK: - The turn cap (small file, many turns)

print("readHistory — the 50-turn cap, and the widened read past it")

let manyTurns = write("turncap.jsonl",
                      (1...80).flatMap { turn($0) })
let cappedRead = AgentSessionScanner.readHistory(of: manyTurns)
let cappedTurns = userTurns(cappedRead)
check("default read caps at 50 turns",
      cappedTurns.count == 50, "\(cappedTurns.count)")
check("…and the capped window is the NEWEST turns",
      cappedTurns.first == "TURN-31" && cappedTurns.last == "TURN-80",
      "\(cappedTurns.first ?? "—")…\(cappedTurns.last ?? "—")")
check("TURN-1 is unreachable in the default read",
      !cappedTurns.contains("TURN-1"))

// Derived from the shipped base bound rather than naming
// `SearchTextExtractor.searchByteBudget` — compiling GlobalSearch.swift
// here would drag in half the app, and any budget wider than the
// fixture proves the mechanism.
let widenBudget = AgentSessionScanner.historyByteBudget * 8

let widenedTurns = userTurns(AgentSessionScanner.readHistory(
    of: manyTurns, maxTurns: .max, byteBudget: widenBudget))
check("widened read (maxTurns .max) reaches TURN-1",
      widenedTurns.first == "TURN-1" && widenedTurns.count == 80,
      "\(widenedTurns.first ?? "—") ×\(widenedTurns.count)")

// MARK: - The byte budget (big file, few turns)

print("\nreadHistory — the byte budget, and the widened read past it")

// 30 turns × ~600 KB ≈ 18 MB: more than double `historyByteBudget`,
// so the default tail provably loses head turns whatever the JSON
// overhead does. Sized off the shipped constant so a budget change
// re-sizes the fixture with it.
let padPerTurn = (AgentSessionScanner.historyByteBudget * 9 / 4) / 30
let bigFile = write("bytecap.jsonl",
                    (1...30).flatMap { turn($0, padBytes: padPerTurn) })
let bigSize = (try! FileManager.default
    .attributesOfItem(atPath: bigFile.path))[.size] as! UInt64
check("fixture outgrows the byte budget",
      bigSize > UInt64(AgentSessionScanner.historyByteBudget) * 2,
      "\(bigSize) bytes")

let tailTurns = userTurns(AgentSessionScanner.readHistory(of: bigFile))
check("default read loses the head turns to the byte budget",
      !tailTurns.contains("TURN-1") && !tailTurns.isEmpty,
      tailTurns.first ?? "—")

let widenedBig = userTurns(AgentSessionScanner.readHistory(
    of: bigFile, maxTurns: .max, byteBudget: widenBudget))
check("widened read reaches TURN-1 through the same API",
      widenedBig.first == "TURN-1" && widenedBig.count == 30,
      "\(widenedBig.first ?? "—") ×\(widenedBig.count)")

// A budget is a BOUND, not "read it all": handed a budget smaller
// than the file, the read must still answer with the newest slice
// rather than failing or reading whole.
let narrowed = userTurns(AgentSessionScanner.readHistory(
    of: bigFile, maxTurns: .max, byteBudget: 1024 * 1024))
check("a byte budget stays a bound (newest slice, never whole)",
      !narrowed.isEmpty && !narrowed.contains("TURN-1"),
      narrowed.first ?? "—")

// MARK: - Structural (the view wiring no harness can instantiate)

print("\nAgentSessionView.swift — the widen wiring")

guard CommandLine.arguments.count > 1,
      let view = try? String(
        contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
else {
    print("  FAIL cannot read AgentSessionView.swift")
    exit(1)
}

/// The widen function's body, delimited by the next `private func`.
func functionBody(_ name: String) -> String {
    guard let start = view.range(of: "private func \(name)") else {
        return ""
    }
    let rest = view[start.upperBound...]
    if let end = rest.range(of: "\n    private func") {
        return String(rest[..<end.lowerBound])
    }
    return String(rest)
}

let widenBody = functionBody("widenHistory(toBudget")
check("widenHistory exists and takes an escalating budget",
      !widenBody.isEmpty && widenBody.contains("budget > historyLoadedBudget"))
check("widen applies trimmedForInFlight (mid-turn double-render)",
      widenBody.contains("trimmedForInFlight("))
check("widen never writes AgentHistoryCache",
      !widenBody.contains("historyCache.store"))
check("widen re-judges partiality after landing",
      widenBody.contains("updateHistoryScope("))
check("a widened read drops the turn cap",
      widenBody.contains("maxTurns: .max"))

check("the widen ladder exists with the search budget as first rung",
      view.contains("historyWidenLadder")
        && view.contains("SearchTextExtractor.searchByteBudget"))
check("ladder base is the shipped read bound, not a third spelling",
      view.contains("historyLoadedBudget: Int = AgentSessionScanner.historyByteBudget"))
check("the button offers past the loaded rows",
      view.contains("hiddenLoaded > 0 || historyHasMore"))
check("a pure fetch-click routes to the parent's widen",
      view.contains("onLoadEarlier()"))
check("the ceiling states its truncation instead of going silent",
      view.contains("historyTruncationNote = String("))
check("the find bar's widen offer shares the same verdict",
      view.contains("onWiden: historyHasMore ? widenHistoryForSearch : nil"))
check("reload resets the ladder for the incoming session",
      view.contains("historyLoadedBudget = AgentSessionScanner.historyByteBudget\n        historyTurnCapApplies = true"))

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
