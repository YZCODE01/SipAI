// Headless check of CodexSessionScanner.lastContextTokens — the read
// that feeds the composer's token chip on a codex session.
//
// The chip hides itself at 0, so every way this read can return 0 or a
// wrong number is a chip that is missing or lying, with nothing on
// screen to say so. That is exactly how it shipped broken: the value
// was hardcoded 0 and no codex session ever showed a chip.
//
// Nothing here is part of the app target.
import Foundation

var failures = 0
var checks = 0

func check(_ label: String, _ actual: Int, _ expected: Int) {
    checks += 1
    if actual == expected {
        print("  ok   \(label) → \(actual)")
    } else {
        failures += 1
        print("  FAIL \(label) → got \(actual), expected \(expected)")
    }
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("codexctx-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

func write(_ name: String, _ lines: [String]) -> URL {
    let url = tmp.appendingPathComponent(name)
    try! (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true,
                                                      encoding: .utf8)
    return url
}

/// A token_count record as codex writes it. `window: nil` drops the
/// `model_context_window` field the way pre-window rollouts do.
func tokenCount(last: Int, total: Int,
                lastIn: Int? = nil, lastOut: Int? = nil,
                window: Int? = 258400) -> String {
    let i = lastIn ?? last
    let o = lastOut ?? 0
    let windowField = window.map { ",\"model_context_window\":\($0)" } ?? ""
    return """
    {"timestamp":"2026-08-14T13:30:03.316Z","type":"event_msg","payload":\
    {"type":"token_count","info":{"total_token_usage":\
    {"input_tokens":\(total),"cached_input_tokens":0,\
    "cache_write_input_tokens":0,"output_tokens":0,\
    "reasoning_output_tokens":0,"total_tokens":\(total)},\
    "last_token_usage":{"input_tokens":\(i),"cached_input_tokens":0,\
    "cache_write_input_tokens":0,"output_tokens":\(o),\
    "reasoning_output_tokens":0,"total_tokens":\(last)}\(windowField)},\
    "rate_limits":null}}
    """
}

let meta = #"{"timestamp":"2026-08-14T13:29:50.000Z","type":"session_meta","payload":{"id":"01a00076","cwd":"/tmp/x"}}"#
let userMsg = #"{"timestamp":"2026-08-14T13:29:51.000Z","type":"event_msg","payload":{"type":"user_message","message":"hi"}}"#

print("CodexSessionScanner.lastContextTokens")

// The whole point: `total_token_usage` is summed across the SESSION and
// must never be what the chip prints. Measured on a real 5.5 MB rollout:
// last=220251 against total=19741449, i.e. reading the wrong block puts
// "19741k tokens" in the composer.
check("reads last_token_usage, not the cumulative block",
      CodexSessionScanner.lastContextTokens(
        of: write("cumulative.jsonl",
                  [meta, userMsg,
                   tokenCount(last: 19880, total: 19880),
                   tokenCount(last: 220251, total: 19741449)])),
      220251)

// A compaction genuinely drops the footprint; the newest record is the
// honest one even when it is smaller than the record before it.
check("newest record wins even when it DROPS",
      CodexSessionScanner.lastContextTokens(
        of: write("compaction.jsonl",
                  [meta,
                   tokenCount(last: 220251, total: 500000),
                   tokenCount(last: 19547, total: 520000)])),
      19547)

// Older codex (May 2026 on this machine, 60 records) fills in
// `total_tokens` alone and leaves the components 0 — recomputing the
// total as input+output would report those sessions as having no usage.
check("total_tokens READ, not recomputed from input+output",
      CodexSessionScanner.lastContextTokens(
        of: write("oldschema.jsonl",
                  [meta,
                   tokenCount(last: 20298, total: 20298,
                              lastIn: 0, lastOut: 0)])),
      20298)

// A session whose turn never produced an API call has no footprint to
// show, and 0 is the correct answer — the chip stays hidden rather than
// inventing a number. One real rollout on this machine is exactly this.
check("no token_count at all → 0",
      CodexSessionScanner.lastContextTokens(
        of: write("noturn.jsonl", [meta, userMsg])),
      0)

// Robustness: the pre-filter matches the literal "token_count", so
// records that merely mention it must still be rejected by the parse.
check("malformed / decoy records are skipped",
      CodexSessionScanner.lastContextTokens(
        of: write("decoys.jsonl",
                  [meta,
                   #"{"type":"event_msg","payload":{"type":"agent_message","message":"the token_count field"}}"#,
                   #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#,
                   #"{"type":"event_msg","payload":{"type":"token_count"}}"#,
                   "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{",
                   tokenCount(last: 13649, total: 13649)])),
      13649)

// The escalating window. A single oversized tool-output record can push
// the newest token_count past the 256 KB first budget; measured worst
// case over this machine's 193 rollouts is 25 KB, so this is the safety
// net rather than the common path — but it has to actually work.
let filler = String(repeating: "x", count: 400 * 1024)
check("newest record beyond the 256 KB tail is still found",
      CodexSessionScanner.lastContextTokens(
        of: write("deep.jsonl",
                  [meta,
                   tokenCount(last: 42_000, total: 42_000),
                   "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"junk\":\"\(filler)\"}}"])),
      42_000)

// MARK: - The window (model_context_window)

// The occupancy tooltip divides the footprint by the model's real
// window when the rollout records one — reading the constant instead
// overstated every codex session (258,400 recorded vs the 200,000
// claude constant).
print("\nCodexSessionScanner.lastContextInfo — the window")

check("window read off the same record as the footprint",
      CodexSessionScanner.lastContextInfo(
        of: write("window.jsonl",
                  [meta, tokenCount(last: 101_466, total: 900_000)])).window,
      258400)

check("no field on any record → window 0 (fallback constant)",
      CodexSessionScanner.lastContextInfo(
        of: write("nowindow.jsonl",
                  [meta, tokenCount(last: 20_000, total: 20_000,
                                    window: nil)])).window,
      0)

// The window rides the WINNING record: a mid-session model switch
// moves footprint and window together or not at all — a stale window
// against a fresh footprint misstates occupancy exactly the way the
// constant did.
check("window rides the newest usable record (gains one)",
      CodexSessionScanner.lastContextInfo(
        of: write("gainwindow.jsonl",
                  [meta,
                   tokenCount(last: 10_000, total: 10_000, window: nil),
                   tokenCount(last: 50_000, total: 60_000,
                              window: 400_000)])).window,
      400_000)

check("window rides the newest usable record (loses one)",
      CodexSessionScanner.lastContextInfo(
        of: write("losewindow.jsonl",
                  [meta,
                   tokenCount(last: 10_000, total: 10_000, window: 258400),
                   tokenCount(last: 50_000, total: 60_000,
                              window: nil)])).window,
      0)

check("tokens unchanged by the window read",
      CodexSessionScanner.lastContextInfo(
        of: write("windowtokens.jsonl",
                  [meta, tokenCount(last: 101_466, total: 900_000)])).tokens,
      101_466)

// MARK: - Real store

// The synthetic cases pin the RULES; only the real store can say the
// schema still looks like this. Run it after a codex upgrade.
let root = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".codex/sessions", isDirectory: true)
if let walker = FileManager.default.enumerator(
    at: root, includingPropertiesForKeys: [.contentModificationDateKey],
    options: [.skipsHiddenFiles]) {
    var rollouts: [(url: URL, at: Date)] = []
    for case let url as URL in walker {
        let name = url.lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else {
            continue
        }
        let at = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        rollouts.append((url, at))
    }
    rollouts.sort { $0.at > $1.at }
    guard !rollouts.isEmpty else {
        print("\n(no rollouts under ~/.codex/sessions — real-store pass skipped)")
        exit(failures == 0 ? 0 : 1)
    }
    var resolved = 0
    var absurd: [String] = []
    for r in rollouts {
        let v = CodexSessionScanner.lastContextTokens(of: r.url)
        if v > 0 { resolved += 1 }
        // A cumulative read is the failure this guards: nothing on a
        // real machine legitimately holds a multi-million-token context.
        if v > 2_000_000 { absurd.append("\(r.url.lastPathComponent) → \(v)") }
    }
    print("\nreal store: \(resolved)/\(rollouts.count) rollouts resolve to a footprint")
    for r in rollouts.prefix(5) {
        let info = CodexSessionScanner.lastContextInfo(of: r.url)
        let tok = info.tokens == 0 ? "—" : "\(info.tokens) tok"
        let win = info.window == 0 ? "no window" : "of \(info.window)"
        print("  newest: \(tok) \(win)  \(r.url.lastPathComponent.prefix(40))")
    }
    checks += 1
    if absurd.isEmpty {
        print("  ok   no rollout reports an impossible (cumulative-looking) total")
    } else {
        failures += 1
        print("  FAIL cumulative-looking totals: \(absurd.prefix(3).joined(separator: ", "))")
    }
} else {
    print("\n(no ~/.codex/sessions — real-store pass skipped)")
}

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
