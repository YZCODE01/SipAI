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

// MARK: - Claude's request records (they are no part of a window)

print("\nthe readers — claude's request records don't count against a window")

// Claude also writes each API request it makes into the transcript: an
// `api-request` line (system prompt, tools, parameters) and its
// `api-request-blob` lines, each opening `{"type":"api-request`, with no
// uuid. A long session's tail is mostly these. The fixture is built in
// those shapes, with synthetic content, and sized so that a window
// counting FILE bytes loses what a window counting conversation keeps.
let requestBytes = 1_200_000

func requestRecords(_ id: String) -> [String] {
    let system = String(repeating: "s", count: requestBytes)
    let blob = String(repeating: "b", count: requestBytes / 8)
    return [
        #"{"type":"api-request","cacheControl":{},"id":"req_\#(id)","keep":true,"params":{"system":"\#(system)","tools":[]},"querySource":"repl_main_thread","requestDigest":"d\#(id)","sessionId":"sess","shapeHash":"h\#(id)","tail":[],"timestamp":"2026-10-01T10:00:00.000Z","version":1}"#,
        #"{"type":"api-request-blob","hash":"blob\#(id)","message":{"role":"user","content":"\#(blob)"},"sessionId":"sess"}"#,
    ]
}

/// One turn the way claude writes it now: the user record that opens it,
/// then per API call the request records and the assistant record that
/// answered, each conversation record hanging off the one before it (the
/// request records hang off nothing). `answered: false` leaves the last
/// call in flight.
func requestTurn(_ i: Int, mode: String, calls: Int, after parent: String?,
                 answered: Bool = true) -> (lines: [String], last: String) {
    let above = parent.map { "\"\($0)\"" } ?? "null"
    var lines = [
        #"{"parentUuid":\#(above),"isSidechain":false,"type":"user","uuid":"ru\#(i)","permissionMode":"\#(mode)","timestamp":"2026-10-01T10:\#(String(format: "%02d", i)):00.000Z","message":{"role":"user","content":"TURN-\#(i) question"}}"#
    ]
    var last = "ru\(i)"
    for call in 1...calls {
        lines += requestRecords("\(i)-\(call)")
        if call < calls || answered {
            lines.append(#"{"parentUuid":"\#(last)","isSidechain":false,"type":"assistant","uuid":"ra\#(i)-\#(call)","effort":"high","message":{"model":"claude-t","role":"assistant","content":[{"type":"text","text":"answer \#(i).\#(call)"}],"usage":{"input_tokens":\#(1000 * i + call),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}"#)
            last = "ra\(i)-\(call)"
        }
    }
    return (lines, last)
}

// Ten answered turns, then an eleventh whose four calls carry more
// request bytes than the widest launch-options window, the last call
// still in flight.
var requestLines: [String] = []
var previous: String? = nil
for i in 1...10 {
    let turn = requestTurn(i, mode: "plan", calls: 3, after: previous)
    requestLines += turn.lines
    previous = turn.last
}
requestLines += requestTurn(11, mode: "acceptEdits", calls: 4, after: previous,
                            answered: false).lines
let requestsFile = write("requests.jsonl", requestLines)
let requestsSize = (try! FileManager.default
    .attributesOfItem(atPath: requestsFile.path))[.size] as! UInt64
check("fixture: request records far outgrow the history window",
      requestsSize > UInt64(AgentSessionScanner.historyByteBudget) * 4,
      "\(requestsSize) bytes")

let requestTurns = userTurns(AgentSessionScanner.readHistory(of: requestsFile))
check("readHistory reads every turn's prompt, the request records skipped",
      requestTurns.count == 11 && requestTurns.first == "TURN-1",
      "\(requestTurns.count): \(requestTurns.first ?? "—")…\(requestTurns.last ?? "—")")

let requestOptions = AgentSessionScanner.lastLaunchOptions(of: requestsFile)
check("lastLaunchOptions finds the newest mode past four calls' requests",
      requestOptions.permissionMode == "acceptEdits",
      String(describing: requestOptions.permissionMode))
check("…and the newest model and effort",
      requestOptions.model == "claude-t" && requestOptions.effort == "high",
      "\(requestOptions.model ?? "—") / \(requestOptions.effort ?? "—")")

let requestStart = AgentSessionScanner.lastTurnStartDate(of: requestsFile)
check("lastTurnStartDate finds the running turn's opening record",
      requestStart == AgentSessionScanner.isoDate("2026-10-01T10:11:00.000Z"),
      String(describing: requestStart))

let requestUsage = AgentSessionScanner.lastContextTokens(of: requestsFile)
check("lastContextTokens reads the newest answered call under an in-flight request",
      requestUsage.tokens == 11_003 && requestUsage.model == "claude-t",
      "\(requestUsage.tokens) \(requestUsage.model ?? "—")")

// Partiality is the walk's verdict now: most of a long file can be
// records no window has to hold.
let whole = AgentSessionScanner.conversationTail(
    of: requestsFile, budget: AgentSessionScanner.historyByteBudget)
check("a conversation that fits reaches the file's start (no \"Show earlier\" that reveals nothing)",
      whole?.reachedStart == true, String(describing: whole?.reachedStart))
check("…and holds no request record",
      whole.map { !$0.text.contains("api-request") } == true)
let cut = AgentSessionScanner.conversationTail(of: bigFile, budget: 1024 * 1024)
check("a conversation bigger than the budget does not reach the start",
      cut?.reachedStart == false && !(cut?.text.isEmpty ?? true),
      String(describing: cut?.reachedStart))
// Sixteen times the budget is the most it reads: past that the walk
// stops short of the start, whatever it found.
let onlyRequests = write("onlyrequests.jsonl",
    (1...20).flatMap { requestRecords("only-\($0)") })
let bounded = AgentSessionScanner.conversationTail(of: onlyRequests, budget: 64 * 1024)
check("the walk is bounded: a file of request records alone is not read to its start",
      bounded?.reachedStart == false && bounded?.text.isEmpty == true,
      String(describing: bounded?.reachedStart))

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
check("widen lands through adoptHistory — the read cut at the running turn, the live buffer cut back (double-render)",
      widenBody.contains("adoptHistory(items, fromFile: true)"))
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
      view.contains("let older = rowsAbove(window)") && view.contains("if older > 0 || historyHasMore {"))
check("a pure fetch-click routes to the parent's widen",
      view.contains("onLoadEarlier()"))
check("the ceiling states its truncation instead of going silent",
      view.contains("historyTruncationNote = String("))
check("the find bar's widen offer shares the same verdict",
      view.contains("onWiden: historyHasMore ? widenHistoryForSearch : nil"))
check("reload resets the ladder for the incoming session",
      view.contains("historyLoadedBudget = AgentSessionScanner.historyByteBudget\n        historyTurnCapApplies = true"))
// A claude read's window counts conversation, so the file's size says
// nothing about what is left unread: the verdict is the walk's own.
check("partiality takes the read's own reach where the reader gives one",
      view.contains("historyReadReachedStart.map { !$0 } ?? (ownSize > budget)"))
check("the claude open and the widen both read through readHistoryReaching",
      view.components(separatedBy: "AgentSessionScanner.readHistoryReaching(").count == 3)
check("the reach rides the cache, both ways",
      view.contains("readReachedStart: loaded.reachedStart")
        && view.contains("historyReadReachedStart = cached.readReachedStart"))
check("the widen lands its reach before judging",
      widenBody.contains("historyReadReachedStart = reachedStart"))
check("reload forgets the outgoing session's reach",
      view.contains("inheritedHistoryBytes = 0\n        historyReadReachedStart = nil"))

// The walk's byte scans are Foundation's own. A generic collection walk
// over `Data` (`lastIndex(of:)`, a `joined` sequence read byte by byte)
// goes through the type's representation per byte, and in a build without
// optimisation it cost the sidebar's whole-store scan nine times its old
// length.
print("\nAgentSession.swift — the walk's byte scans")
let scannerPath = URL(fileURLWithPath: CommandLine.arguments[1])
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Models/AgentSession.swift").path
guard let scanner = try? String(contentsOfFile: scannerPath, encoding: .utf8) else {
    print("  FAIL cannot read AgentSession.swift")
    exit(1)
}
let walkBody: String = {
    guard let start = scanner.range(of: "static func conversationTail(") else { return "" }
    let rest = scanner[start.upperBound...]
    if let end = rest.range(of: "\n    static func ") { return String(rest[..<end.lowerBound]) }
    return String(rest)
}()
check("the walk finds newlines through Foundation, never a per-byte collection walk",
      !walkBody.isEmpty && walkBody.contains("options: .backwards")
        && !walkBody.contains("lastIndex(of:"))
check("…and joins what it kept by appending, never through a byte sequence",
      !walkBody.isEmpty && walkBody.contains("text.append(") && !walkBody.contains("joined(separator:"))

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
