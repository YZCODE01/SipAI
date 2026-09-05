// Headless check of the composer's context chip and the compaction
// rows. See run.sh for scope.
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

let args = CommandLine.arguments
let sourceRoot = args.count > 1 ? args[1] : "."
let fixtures = args.count > 2 ? args[2] : "./fixtures"

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("contextchip-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

func write(_ name: String, _ lines: [String]) -> URL {
    let url = tmp.appendingPathComponent(name)
    try! (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true,
                                                      encoding: .utf8)
    return url
}

func source(_ path: String) -> String {
    (try? String(contentsOfFile: sourceRoot + "/" + path, encoding: .utf8)) ?? ""
}

// MARK: - 1. The numerator: the INPUT side of the newest main-loop call

print("Numerator — input side only, newest main-loop call")

// Claude: output must NOT count, and the model rides out with it.
let claudeUsage = write("claude-usage.jsonl", [
    #"{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":9999},"content":[{"type":"text","text":"a"}]}}"#,
])
let cu = AgentSessionScanner.lastContextTokens(of: claudeUsage)
check("claude: input + cache write + cache read, output excluded",
      cu.tokens == 1110, "got \(cu.tokens)")
check("claude: the winning record's model rides out",
      cu.model == "claude-opus-5", "got \(cu.model ?? "nil")")

// A `[1m]` id is carried verbatim — it names a different window.
let claudeVariant = write("claude-variant.jsonl", [
    #"{"type":"assistant","message":{"model":"claude-opus-5[1m]","usage":{"input_tokens":5,"cache_read_input_tokens":5},"content":[{"type":"text","text":"a"}]}}"#,
])
check("claude: `[1m]` kept on the model",
      AgentSessionScanner.lastContextTokens(of: claudeVariant).model == "claude-opus-5[1m]")

// Newest wins even when it DROPS (a compaction), and subagents are out.
let claudeSeq = write("claude-seq.jsonl", [
    #"{"type":"assistant","message":{"model":"m1","usage":{"input_tokens":900,"cache_read_input_tokens":100},"content":[{"type":"text","text":"a"}]}}"#,
    #"{"type":"assistant","isSidechain":true,"message":{"model":"sub","usage":{"input_tokens":50},"content":[{"type":"text","text":"s"}]}}"#,
    #"{"type":"assistant","message":{"model":"m2","usage":{"input_tokens":200},"content":[{"type":"text","text":"b"}]}}"#,
])
let seq = AgentSessionScanner.lastContextTokens(of: claudeSeq)
check("claude: newest wins even when it drops", seq.tokens == 200, "got \(seq.tokens)")
check("claude: subagent records excluded", seq.model == "m2", "got \(seq.model ?? "nil")")

// Codex: input_tokens (cached prefix already inside), NOT total_tokens.
let codexNew = write("codex-new.jsonl", [
    #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":101033,"cached_input_tokens":96256,"output_tokens":433,"total_tokens":101466},"total_token_usage":{"total_tokens":35362077},"model_context_window":258400}}}"#,
])
let ci = CodexSessionScanner.lastContextInfo(of: codexNew)
check("codex: input_tokens, not total_tokens", ci.tokens == 101033, "got \(ci.tokens)")
check("codex: cumulative block ignored", ci.tokens < 200_000)
check("codex: window rides the winning record", ci.window == 258400, "got \(ci.window)")

// Codex legacy: components 0, total alone — must not read as empty.
let codexOld = write("codex-old.jsonl", [
    #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":0,"output_tokens":0,"total_tokens":54321}}}}"#,
])
check("codex: total-only legacy record falls back to the total",
      CodexSessionScanner.lastContextTokens(of: codexOld) == 54321,
      "got \(CodexSessionScanner.lastContextTokens(of: codexOld))")

// Kimi: three input fields, output excluded, scope must be `turn`.
let kimiWire = write("kimi-wire.jsonl", [
    #"{"type":"usage.record","model":"moonshot-ai/kimi-k3","usageScope":"session","usage":{"inputOther":9,"inputCacheRead":9,"inputCacheCreation":9,"output":9}}"#,
    #"{"type":"usage.record","model":"moonshot-ai/kimi-k3","usageScope":"turn","usage":{"inputOther":2044,"inputCacheRead":18944,"inputCacheCreation":0,"output":38}}"#,
])
let ku = KimiSessionScanner.lastContextUsage(of: kimiWire)
check("kimi: three input fields, output excluded",
      ku.tokens == 2044 + 18944, "got \(ku.tokens)")
check("kimi: the record's model rides out",
      ku.model == "moonshot-ai/kimi-k3", "got \(ku.model ?? "nil")")

// MARK: - 2. The window: three sources, one rule

print("")
print("Window — the claude binary table, and the shared resolver")

let claudeBinary = ProcessInfo.processInfo.environment["SIPAI_CLAUDE_BINARY"] ?? ""
if FileManager.default.fileExists(atPath: claudeBinary) {
    let table = ClaudeModelCatalog.windowTable(at: claudeBinary)
    check("binary table parses", table.count >= 4, "\(table.count) entries")
    func win(_ id: String) -> Int? {
        ClaudeModelCatalog.contextWindow(forModelId: id, binary: claudeBinary)
    }
    // `1e6` is JS source: reading the digits alone answers 1, and a
    // one-token window makes every percentage 100%.
    let millions = table.filter { $0.value.window == 1_000_000 }
    check("`1e6` parses as 1,000,000, never 1",
          !millions.isEmpty && !table.values.contains { $0.window == 1 },
          "\(millions.count) 1M models")
    let hundreds = table.filter { $0.value.window == 200_000 }
    check("the 200k line is read too", !hundreds.isEmpty,
          "\(hundreds.count) 200k models")
    if let base = hundreds.first(where: { $0.value.supports1MSuffix })?.key {
        check("`[1m]` on a 200k base resolves to 1,000,000 via supports_1m_suffix",
              win(base + "[1m]") == 1_000_000, "\(win(base + "[1m]") ?? -1)")
        check("the same id unsuffixed stays 200,000",
              win(base) == 200_000, "\(win(base) ?? -1)")
    }
    check("a model the table does not name answers nil",
          win("claude-not-a-real-model") == nil)
    check("an empty id answers nil", win("") == nil)
} else {
    print("  SKIP binary table — set SIPAI_CLAUDE_BINARY to a claude executable")
}

// The resolver: selection first, then the number's model, then nil.
func resolve(agent: String, alias: String?, fullId: String?, numerator: String?,
             recorded: Int, aliasMap: [String: String] = [:],
             binary: [String: Int] = [:], learned: [String: Int] = [:],
             catalog: [String: Int] = [:], catalogDefault: Int? = nil) -> Int? {
    ContextWindowResolver.resolve(
        agentKey: agent, selectedAlias: alias, selectedFullId: fullId,
        numeratorModel: numerator, recordedWindow: recorded,
        aliasToId: { aliasMap[$0] },
        binaryWindow: { binary[$0] },
        learnedWindow: { learned[$0] },
        catalogWindow: { sel in
            guard let sel, !sel.isEmpty else { return catalogDefault }
            return catalog[sel]
        })
}

check("claude: the SELECTED alias wins over the number's model",
      resolve(agent: "claude_code", alias: "opus", fullId: nil,
              numerator: "claude-haiku-4-5", recorded: 0,
              aliasMap: ["opus": "claude-opus-5"],
              binary: ["claude-opus-5": 1_000_000,
                       "claude-haiku-4-5": 200_000]) == 1_000_000)
check("claude: a concrete full-id pick is itself the model",
      resolve(agent: "claude_code", alias: "opus", fullId: "claude-sonnet-4-6",
              numerator: nil, recorded: 0,
              aliasMap: ["opus": "claude-opus-5"],
              binary: ["claude-opus-5": 1_000_000,
                       "claude-sonnet-4-6": 200_000]) == 200_000)
check("claude: Default resolves through the \"\" alias entry",
      resolve(agent: "claude_code", alias: "", fullId: nil, numerator: nil,
              recorded: 0, aliasMap: ["": "claude-opus-5"],
              binary: ["claude-opus-5": 1_000_000]) == 1_000_000)
check("claude: falls back to the model that produced the number",
      resolve(agent: "claude_code", alias: "mystery", fullId: nil,
              numerator: "claude-opus-5", recorded: 0,
              binary: ["claude-opus-5": 1_000_000]) == 1_000_000)
check("claude: the learned store covers an id the binary does not name",
      resolve(agent: "claude_code", alias: nil, fullId: "gateway-model",
              numerator: nil, recorded: 0,
              learned: ["gateway-model": 123_456]) == 123_456)
check("claude: nothing known answers nil, never a constant",
      resolve(agent: "claude_code", alias: "unknown", fullId: nil,
              numerator: "also-unknown", recorded: 0) == nil)
check("claude: a window RECORDED by another agent is not borrowed",
      resolve(agent: "claude_code", alias: "unknown", fullId: nil,
              numerator: nil, recorded: 258_400) == nil)
check("codex: the catalog answers for the selected slug",
      resolve(agent: "codex", alias: "gpt-5.6-sol", fullId: nil, numerator: nil,
              recorded: 0, catalog: ["gpt-5.6-sol": 258_400]) == 258_400)
check("codex: Default resolves through the catalog's own default",
      resolve(agent: "codex", alias: "", fullId: nil, numerator: nil,
              recorded: 0, catalogDefault: 258_400) == 258_400)
check("codex: an unknown model falls back to the recorded window",
      resolve(agent: "codex", alias: "gpt-未来", fullId: nil, numerator: nil,
              recorded: 272_000) == 272_000)
check("kimi: the catalog answers for the selected slug",
      resolve(agent: "kimi", alias: "moonshot-ai/kimi-k3", fullId: nil,
              numerator: nil, recorded: 0,
              catalog: ["moonshot-ai/kimi-k3": 1_048_576]) == 1_048_576)
check("kimi: nothing known answers nil",
      resolve(agent: "kimi", alias: "unknown", fullId: nil, numerator: nil,
              recorded: 0) == nil)

// The real codex catalog on this machine, if present: the effective
// window must equal what its rollouts record.
let cachePath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex/models_cache.json")
if let data = try? Data(contentsOf: cachePath),
   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
   let models = obj["models"] as? [Any] {
    var effective: [String: Int] = [:]
    for case let m as [String: Any] in models {
        guard let slug = m["slug"] as? String,
              let raw = (m["context_window"] as? NSNumber)?.intValue, raw > 0
        else { continue }
        let pct = (m["effective_context_window_percent"] as? NSNumber)?.doubleValue ?? 100
        effective[slug] = Int((Double(raw) * pct / 100).rounded())
    }
    check("codex catalog states an effective window", !effective.isEmpty,
          "\(effective.count) models")
    if let any = effective.values.first {
        check("effective window is below the raw one (a percentage applies)",
              any < 1_000_000 && any > 0, "\(any)")
    }
} else {
    print("  SKIP codex catalog — no ~/.codex/models_cache.json")
}

// MARK: - 3. Percent and compact formatting

print("")
print("Percent and labels")

func pct(_ used: Int, _ window: Int) -> Int { ContextUsageFormat.percent(used, of: window) }
check("39% of a codex window", pct(101_033, 258_400) == 39, "\(pct(101_033, 258_400))")
check("rounds like claude's own indicator", pct(1_500, 10_000) == 15)
check("a live session is never 0%", pct(1, 1_000_000) == 1)
check("over-window reads as full, never above 100", pct(2_000_000, 1_000_000) == 100)
check("no window means no percentage", pct(500, 0) == 0)
check("compact: 999", ContextUsageFormat.compact(999) == "999")
check("compact: 9.9k", ContextUsageFormat.compact(9_900) == "9.9k")
check("compact: 258k", ContextUsageFormat.compact(258_400) == "258k")
check("compact: 1.0M", ContextUsageFormat.compact(1_000_000) == "1.0M")

// MARK: - 4. Compaction on disk

print("")
print("Compaction — the reload path, all three agents")

let transcript = URL(fileURLWithPath: fixtures)
    .appendingPathComponent("claude-compaction-transcript.jsonl")
if FileManager.default.fileExists(atPath: transcript.path) {
    let items = AgentSessionScanner.readHistory(of: transcript, maxTurns: .max)
    var rows: [(Int?, Int?)] = []
    var notices = 0
    var plainUser = 0
    for item in items {
        if case .compaction(let a, let b) = item.kind { rows.append((a, b)) }
        if case .userText = item.kind {
            if item.isSystemNotice { notices += 1 } else { plainUser += 1 }
        }
    }
    check("claude: both compaction boundaries render", rows.count == 2,
          "\(rows.count) rows")
    check("claude: the row carries before → after figures",
          rows.first.map { $0.0 != nil && $0.1 != nil } ?? false,
          "\(String(describing: rows.first))")
    check("claude: the summary is a system notice, not the user's words",
          notices >= 2, "\(notices) notices")
    check("claude: the user's own prompt is still their own",
          plainUser >= 1, "\(plainUser) user rows")
    // The summary must not re-time the sidebar row: it is a
    // user-role record written mid-turn, and counted as a turn start
    // it drags the row's clock (and the composer's external-turn
    // clock) to the moment the agent summarised itself. Driven on a
    // synthetic file so the assertion is about the RULE, not about
    // whatever stamps the captured fixture happens to carry.
    let dated = write("claude-turn-start.jsonl", [
        #"{"type":"user","uuid":"u1","timestamp":"2026-09-04T01:00:00.000Z","message":{"content":"the real prompt"}}"#,
        #"{"type":"assistant","uuid":"a1","timestamp":"2026-09-04T01:00:05.000Z","message":{"model":"m","usage":{"input_tokens":10},"content":[{"type":"text","text":"x"}]}}"#,
        #"{"type":"system","uuid":"s1","subtype":"compact_boundary","timestamp":"2026-09-04T02:00:00.000Z","compactMetadata":{"preTokens":72724,"postTokens":29281}}"#,
        #"{"type":"user","uuid":"u2","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"timestamp":"2026-09-04T02:00:01.000Z","message":{"content":"This session is being continued from a previous conversation…"}}"#,
    ])
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let expected = iso.date(from: "2026-09-04T01:00:00.000Z")!
    let got = AgentSessionScanner.lastTurnStartDate(of: dated)
    check("claude: a summary record does not count as a turn start",
          got.map { abs($0.timeIntervalSince(expected)) < 1 } ?? false,
          "got \(got.map(iso.string(from:)) ?? "nil")")
} else {
    print("  SKIP claude fixture — \(transcript.path) missing")
}

let codexCompact = write("codex-compacted.jsonl", [
    #"{"type":"session_meta","payload":{"id":"s1"}}"#,
    #"{"type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"first question"}]}}"#,
    #"{"type":"compacted","payload":{"message":"","replacement_history":[{"role":"user","content":[{"type":"input_text","text":"RETAINED ORIGINAL TURN"}]}]}}"#,
    #"{"type":"response_item","payload":{"role":"assistant","content":[{"type":"output_text","text":"after"}]}}"#,
])
let codexItems = CodexSessionScanner.readHistory(of: codexCompact, maxTurns: .max)
var codexRows = 0
for item in codexItems { if case .compaction = item.kind { codexRows += 1 } }
check("codex: the compaction record renders a row", codexRows == 1, "\(codexRows)")
check("codex: replacement_history is NOT replayed",
      !codexItems.contains { if case .userText(let t) = $0.kind {
          return t.contains("RETAINED ORIGINAL TURN") } else { return false } })

let kimiCompact = write("kimi-compacted.jsonl", [
    #"{"type":"context.append_message","message":{"role":"user","content":"a question"}}"#,
    #"{"type":"context.apply_compaction","tokensBefore":72724,"tokensAfter":29281,"summary":"Earlier conversation summary."}"#,
])
let kimiItems = KimiSessionScanner.readHistory(of: kimiCompact, maxTurns: .max)
var kimiFigures: (Int?, Int?)? = nil
var kimiNotice = false
for item in kimiItems {
    if case .compaction(let a, let b) = item.kind { kimiFigures = (a, b) }
    if case .userText(let t) = item.kind, item.isSystemNotice,
       t.contains("Earlier conversation summary") { kimiNotice = true }
}
check("kimi: the compaction record renders with its figures",
      kimiFigures?.0 == 72724 && kimiFigures?.1 == 29281,
      "\(String(describing: kimiFigures))")
check("kimi: the in-record summary renders as a system notice", kimiNotice)

// MARK: - 5. Compaction on the stream

print("")
print("Compaction — the live path")

let streamFixture = URL(fileURLWithPath: fixtures)
    .appendingPathComponent("claude-compaction-stream.jsonl")
if let text = try? String(contentsOf: streamFixture, encoding: .utf8) {
    var boundaries: [(Int?, Int?)] = []
    var windows: [String: Int] = [:]
    var summaryEvents = 0
    var compactingTrue = 0
    var compactingFalse = 0
    for line in text.split(separator: "\n") {
        let s = String(line)
        if let flag = AgentEventParser.compactingSignal(line: s) {
            flag ? (compactingTrue += 1) : (compactingFalse += 1)
        }
        for e in AgentEventParser.parse(line: s,
                                        fallbackCwd: URL(fileURLWithPath: "/tmp")) {
            if case .compaction(let a, let b) = e.kind { boundaries.append((a, b)) }
            if let w = e.modelContextWindows { windows.merge(w) { _, n in n } }
            if case .userMessage(let t) = e.kind,
               t.contains("session is being continued") { summaryEvents += 1 }
        }
    }
    check("claude stream: both boundaries become rows", boundaries.count == 2,
          "\(boundaries.count)")
    check("claude stream: the row carries its figures",
          boundaries.first.map { $0.0 != nil && $0.1 != nil } ?? false)
    check("claude stream: result carries claude's own window per model",
          windows.values.contains { $0 > 0 }, "\(windows)")
    check("claude stream: the summary is not replayed as a user bubble",
          summaryEvents == 0, "\(summaryEvents) summary events")
    check("claude stream: 'compacting' is signalled", compactingTrue >= 1,
          "\(compactingTrue)")
    check("claude stream: the finish is signalled too", compactingFalse >= 1,
          "\(compactingFalse)")
    check("claude stream: an ordinary line signals nothing",
          AgentEventParser.compactingSignal(
            line: #"{"type":"assistant","message":{"content":[]}}"#) == nil)
} else {
    print("  SKIP claude stream fixture — \(streamFixture.path) missing")
}

let codexItemLine = #"{"type":"item.completed","item":{"id":"i1","type":"context_compaction"}}"#
let codexParsed = CodexEventParser.parse(line: codexItemLine,
                                         fallbackCwd: URL(fileURLWithPath: "/tmp"))
var codexStreamRow = false
for e in codexParsed.events { if case .compaction = e.kind { codexStreamRow = true } }
check("codex stream: a compaction item becomes a row", codexStreamRow)
let codexStarted = CodexEventParser.parse(
    line: #"{"type":"item.started","item":{"id":"i1","type":"context_compaction"}}"#,
    fallbackCwd: URL(fileURLWithPath: "/tmp"))
check("codex stream: its `item.started` opens no tool row",
      codexStarted.events.isEmpty, "\(codexStarted.events.count) events")

// MARK: - 6. Structural — the wiring no harness can instantiate

print("")
print("Structural — view, runner and composer wiring")

let composer = source("SipAI/Views/Chat/AgentComposer.swift")
/// The `ContextUsageChip` declaration alone, so a `.help()` elsewhere
/// in the composer cannot mask one inside the chip.
func chipBody(_ text: String) -> String {
    guard let start = text.range(of: "struct ContextUsageChip: View {") else { return "" }
    let rest = text[start.lowerBound...]
    guard let end = rest.range(of: "\n}\n") else { return String(rest) }
    // Code only: a comment explaining why there is no `.help()` must
    // not read as one.
    return rest[..<end.upperBound].split(separator: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}
let view = source("SipAI/Views/Chat/AgentSessionView.swift")
let runner = source("SipAI/Models/AgentRunner.swift")
let settings = source("SipAI/Views/Settings/SettingsView.swift")

check("the 200,000 constant is gone from the composer",
      !composer.contains("claudeWindow") && !composer.contains("200_000"))
check("the chip takes an OPTIONAL window",
      composer.contains("var contextWindowTokens: Int? = nil"))
check("no ticker survives in the chip",
      !composer.contains("private func animate(to target: Int)"))
// The hint is the strip's own instant label, like every neighbour's.
// `.help()` was the previous counter's only hint and it read as NO
// hint: the system tooltip arrives a second late, next to controls
// that answer immediately.
check("the chip's hint rides HoverHighlight, like the clock chip",
      composer.contains("HoverHighlight(hint: ContextUsageChip.hoverText("))
check("the chip itself sets no delayed system tooltip",
      !chipBody(composer).contains(".help("))
// The chip is the LAST control in the strip. A centred hint wider than
// the chip overhangs it on both sides, and on the right there is only
// the window margin to overhang into — its last letters were drawn
// past the window edge. Trailing keeps the hint's right edge on the
// chip's.
check("the chip's hint is aligned trailing, so it cannot run off the window",
      composer.contains("hintAlignment: .trailing) {\n                    ContextUsageChip("))
check("the view hands the chip the RESOLVED window",
      view.contains("contextWindowTokens: resolvedContextWindow"))
check("the resolver is what resolves it",
      view.contains("ContextWindowResolver.resolve("))
check("claude's reported windows are learned into config",
      view.contains("setAgentModelContextWindow"))
check("the observed-window feed guards on its OWN mirror",
      view.contains("windows != observedWindowsMirror"))
check("kimi's chip is refreshed mid-turn like codex's",
      runner.contains("refreshKimiContextTokens(throttled: true)"))
check("the compacting state is never written into events",
      !runner.contains("kind: .compaction") )
check("a compaction does not end the 'Sipping…' wait",
      view.contains("case .systemInit, .compaction: continue"))
check("the settings toggle names context usage",
      settings.contains("\"Show context usage\""))
check("the FAQ no longer calls the chip a total",
      !settings.contains("total token consumption"))

// MARK: - Report

print("")
print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
