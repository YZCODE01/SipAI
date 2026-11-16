// Headless check of the plan-usage window. See run.sh for scope and
// for what regresses silently.
//
// Nothing here is part of the app target.
import CryptoKit
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
/// This harness's own folder (its stand-in servers), which a run against
/// another checkout does not have.
let harnessDir = args.count > 2 ? args[2] : sourceRoot + "/Verification/UsageWindow"

func source(_ path: String) -> String {
    (try? String(contentsOfFile: sourceRoot + "/" + path, encoding: .utf8)) ?? ""
}

/// The file with its `//` comments removed, so a structural check
/// finds what the code DOES rather than what a comment says it must
/// not do.
func codeOnly(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let slashes = line.range(of: "//") else { return line }
        return line[line.startIndex..<slashes.lowerBound]
    }.joined(separator: "\n")
}

func json(_ text: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("usage-window-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

// MARK: - 1. Claude's `/usage` text

print("1. Claude — the /usage text, both shapes")

let claudePlanText = """
You are currently using your subscription to power your Claude Code usage

Current session: 27% used · resets Sep 13 at 12:10am (Europe/London)
Current week (all models): 14% used · resets Sep 18 at 9pm (Europe/London)
Current week (Fable): 25% used · resets Sep 18 at 9pm (Europe/Berlin)

What's contributing to your limits usage?
Approximate, based on local sessions on this machine — does not include other devices or claude.ai. Behaviors are independent characteristics, not a breakdown.

Last 24h · 438 requests · 4 sessions
  94% of your usage was at >150k context
"""
let plan = ClaudeUsageText.parse(claudePlanText, currentZone: "Europe/London")
check("subscription text reads as a plan", plan.kind == .plan)
check("three window rows", plan.rows.count == 3, "\(plan.rows.count)")
check("labels verbatim, family included",
      plan.rows.map { $0.label } == ["Current session", "Current week (all models)", "Current week (Fable)"])
check("percentages", plan.rows.map { $0.percent } == [27, 14, 25])
check("the Mac's own zone is dropped from the reset",
      plan.rows[0].resetText == "Sep 13 at 12:10am")
check("another zone is kept",
      plan.rows[2].resetText == "Sep 18 at 9pm (Europe/Berlin)")
check("the analytics paragraph yields no row",
      !plan.rows.contains { ($0.label ?? "").contains("usage was") })

let claudeAPIText = """
Total cost:            $0.0000
Total duration (API):  0s
Total duration (wall): 2s
Total code changes:    0 lines added, 0 lines removed
Usage:                 0 input, 0 output, 0 cache read, 0 cache write
"""
let api = ClaudeUsageText.parse(claudeAPIText, currentZone: "UTC")
check("the /cost table reads as an API key", api.kind == .apiKey)
check("…with no rows", api.rows.isEmpty)

let odd = ClaudeUsageText.parse("Something else entirely\nno windows here", currentZone: "UTC")
check("an unrecognised answer is unknown, not a verdict", odd.kind == .unknown && odd.rows.isEmpty)

let sonnet = ClaudeUsageText.parse("You are currently using your subscription to power your Claude Code usage\n\nCurrent week (Sonnet only): 3% used · resets Sep 18 at 9pm (UTC)", currentZone: "UTC")
check("another family's label parses", sonnet.rows.first?.label == "Current week (Sonnet only)" && sonnet.rows.first?.percent == 3)
check("a percentage over 100 is refused",
      ClaudeUsageText.parse("Current session: 250% used", currentZone: "UTC").rows.isEmpty)
let reworded = ClaudeUsageText.parse("Your Claude plan is powering this session\n\nCurrent session: 12% used · resets Sep 13 at 1pm (UTC)", currentZone: "UTC")
check("rows decide the kind when the opening sentence is reworded", reworded.kind == .plan && reworded.rows.count == 1)
check("plan tier from organizationType",
      ClaudeUsageText.planName(organizationType: "claude_max") == "Max"
      && ClaudeUsageText.planName(organizationType: "claude_pro") == "Pro"
      && ClaudeUsageText.planName(organizationType: "claude_plus_ultra") == nil)


// MARK: - 1b. Claude's structured report (stream-json)

// `claude -p /usage --output-format stream-json --verbose` answers the
// same text on its `result` record and, on the record that carries the
// answer, a structured `usage_report`: the server's rows as sent — kind,
// percent, a real reset date, the server's own grade of the row and the
// model a scoped row is for. Measured on 2.1.296, token-free. The text
// stays the authority for the labels; the report adds what the text
// cannot carry. A fixture in the measured shape, with synthetic figures.
print("1b. Claude — the structured usage report, read beside the text")

let claudeArgs = ClaudeUsageProbe.arguments(sessionId: "s")
check("the probe asks for stream-json with --verbose (the report rides only there)",
      claudeArgs.contains("stream-json") && claudeArgs.contains("--verbose")
      && !claudeArgs.contains("json") && claudeArgs.contains("--session-id")
      && claudeArgs.contains("--strict-mcp-config"),
      claudeArgs.joined(separator: " "))

let reportLine = #"{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"usage"}]},"usage_report":{"session":{"total_cost_usd":0},"rate_limits":{"limits":[{"kind":"session","group":"session","percent":27,"resets_at":"2026-09-12T23:10:00.021966+00:00","scope":null,"severity":"normal","is_active":false},{"kind":"weekly_all","group":"weekly","percent":14,"resets_at":"2026-09-18T20:00:00.021987+00:00","scope":null,"severity":"warning","is_active":false},{"kind":"weekly_scoped","group":"weekly","percent":25,"resets_at":"2026-09-18T20:00:00+00:00","scope":{"model":{"display_name":"Fable"},"surface":null},"severity":"critical","is_active":true}],"extra_usage":{"is_enabled":false,"monthly_limit":10000,"used_credits":0,"utilization":0,"currency":"USD"}}},"session_id":"s","uuid":"u"}"#
let resultObject: [String: Any] = ["type": "result", "subtype": "success", "is_error": false,
                                   "num_turns": 0, "result": claudePlanText, "session_id": "s"]
let resultLine = String(decoding: try! JSONSerialization.data(withJSONObject: resultObject), as: UTF8.self)
let streamOutput = #"{"type":"system","subtype":"init","cwd":"/tmp/x","session_id":"s","tools":[]}"#
    + "\n⚠ a warning claude prints on a line of its own\n" + reportLine + "\n" + resultLine + "\n"
check("the result text still comes off the stream", ClaudeUsageProbe.extractResult(from: streamOutput).text == claudePlanText)
let report = ClaudeUsageProbe.extractReport(from: streamOutput)
check("the report comes off the record that answered /usage: three limits",
      report?.limits.count == 3, "\(String(describing: report))")
check("…classified on kind, the scoped row named by its model",
      report?.limits.map(\.kind) == ["session", "weekly_all", "weekly_scoped"]
      && report?.limits.last?.scopeName == "Fable")
check("…the server's grades, as sent",
      report?.limits.map(\.severity) == [.normal, .warning, .critical])
check("…reset dates read with and without fractional seconds",
      report?.limits.allSatisfy { $0.resetsAt != nil } == true
      && report?.limits.last?.resetsAt.map { Int($0.timeIntervalSince1970) } == 1789761600)
check("no report on a stream without one (an older claude, or an API key)",
      ClaudeUsageProbe.extractReport(from: resultLine) == nil)
check("a grade claude has not used yet is no grade — the bar falls back to SipAI's own rule",
      ClaudeUsageReport.parse(["rate_limits": ["limits": [["kind": "session", "percent": 3, "severity": "elevated"]]]])?
        .limits.first?.severity == nil)

let merged = ClaudeUsageText.merging(plan.rows, report: report)
check("merged: the text's labels and percents stay",
      merged.map(\.label) == plan.rows.map(\.label) && merged.map(\.percent) == plan.rows.map(\.percent))
check("…each row takes the report's date in place of claude's English text",
      merged.count == 3 && zip(merged, report?.limits ?? []).allSatisfy { $0.resetDate == $1.resetsAt && $0.resetText == nil })
check("…and the server's grade",
      merged.map(\.severity) == [.normal, .warning, .critical])
var skewed = report
skewed?.limits[1].percent = 15
check("a report whose percents disagree with the text adds nothing",
      ClaudeUsageText.merging(plan.rows, report: skewed) == plan.rows)
var shorter = report
shorter?.limits.removeLast()
check("…nor does one with another number of rows", ClaudeUsageText.merging(plan.rows, report: shorter) == plan.rows)
check("…nor no report at all", ClaudeUsageText.merging(plan.rows, report: nil) == plan.rows)
let fromReport = ClaudeUsageText.merging([], report: report)
check("a text with no rows takes the report's, labelled as claude's text labels them",
      fromReport.map(\.label) == ["Current session", "Current week (all models)", "Current week (Fable)"]
      && fromReport.map(\.percent) == [27, 14, 25] && fromReport.allSatisfy { $0.resetDate != nil })

let contributing = ClaudeUsageText.contributing(in: claudePlanText)
check("claude's “What's contributing” block is kept whole, from its heading to the end",
      contributing?.hasPrefix("What's contributing to your limits usage?") == true
      && contributing?.contains("94% of your usage was at >150k context") == true
      && contributing?.contains("Current session:") == false,
      contributing ?? "nil")
check("…found under a curly apostrophe too",
      ClaudeUsageText.contributing(in: "Current session: 1% used\n\nWhat’s contributing to your limits usage?\nLast 24h · 2 requests")?
        .contains("Last 24h") == true)
check("…and absent from an answer without it", ClaudeUsageText.contributing(in: claudeAPIText) == nil)

// MARK: - 1c. Claude's “What's contributing” block, read as a table

// Claude prints the block from one template (read in Claude Code's own
// bundle: the heading, its note, then per period "Last 24h · N requests ·
// M sessions" over two-space-indented lines, each a "N% of your usage …"
// sentence or a "Top <kind>: name N%, …, +K more" list). Settings → Usage
// lays it out as a table, and every word in the table is claude's. A
// fixture in that shape, with made-up figures.
print("1c. Claude — the “What's contributing” block, read as a table")

let contributingBlock = """
What's contributing to your limits usage?
Approximate, based on local sessions on this machine — does not include other devices or claude.ai. Behaviors are independent characteristics, not a breakdown.

Last 24h · 438 requests · 4 sessions
  94% of your usage was at >150k context
  61% of your usage was at max effort
  22% of your usage went to always-on context over 40k tokens

Last 7d · 2210 requests · 19 sessions
  88% of your usage was at >150k context
  57% of your usage came from subagent-heavy sessions
  12% of your usage went to tool results over 10k tokens
  Top skills: /review 18%, /deploy 6%
  Top subagents: general-purpose 29%, Explore 7%, Plan 3%, +2 more
"""
let table = ClaudeContributing.parse(contributingBlock)
check("the heading and claude's note, as claude wrote them",
      table?.heading == "What's contributing to your limits usage?"
      && table?.notes == ["Approximate, based on local sessions on this machine — does not include other devices or claude.ai. Behaviors are independent characteristics, not a breakdown."],
      "\(String(describing: table))")
check("both periods, each with its counts beside its name",
      table?.periods.map(\.title) == ["Last 24h", "Last 7d"]
      && table?.periods.map(\.detail) == ["438 requests · 4 sessions", "2210 requests · 19 sessions"])
check("each sentence split at its percent, the rest of claude's words kept",
      table?.periods.first?.rows == [.share(percent: 94, text: "of your usage was at >150k context"),
                                     .share(percent: 61, text: "of your usage was at max effort"),
                                     .share(percent: 22, text: "of your usage went to always-on context over 40k tokens")])
check("a top list becomes its rows, the count past claude's eight kept as claude wrote it",
      table?.periods.last?.rows.suffix(2) == [
        .top(title: "Top skills", items: [.init(name: "/review", percent: 18), .init(name: "/deploy", percent: 6)], more: nil),
        .top(title: "Top subagents", items: [.init(name: "general-purpose", percent: 29), .init(name: "Explore", percent: 7),
                                             .init(name: "Plan", percent: 3)], more: "+2 more")])
// Put back together, the table is claude's text: nothing is reworded,
// nothing dropped.
func rebuilt(_ block: ClaudeContributing) -> String {
    var lines = [block.heading] + block.notes
    for period in block.periods {
        lines.append("")
        lines.append(period.detail.map { "\(period.title) · \($0)" } ?? period.title)
        for row in period.rows {
            switch row {
            case .share(let percent, let text): lines.append("  \(percent)% \(text)")
            case .top(let title, let items, let more):
                lines.append("  \(title): " + (items.map { "\($0.name) \($0.percent)%" } + (more.map { [$0] } ?? [])).joined(separator: ", "))
            }
        }
    }
    return lines.joined(separator: "\n")
}
check("every word in the table is claude's: put back together it is claude's text",
      table.map(rebuilt) == contributingBlock)
let notAllowed = ClaudeContributing.parse("What's contributing to your limits usage?\nRun /usage in the terminal to see it.")
check("a block that is the heading and claude's reason alone is the heading and the reason",
      notAllowed?.notes == ["Run /usage in the terminal to see it."] && notAllowed?.periods.isEmpty == true)
// A shape claude has not printed is shown as claude's text, whole: a
// reworded line must not drop out of the page.
let heading = "What's contributing to your limits usage?\nApproximate.\n\n"
for (label, odd) in [
    ("a line that is neither a sentence nor a list", heading + "Last 24h · 2 requests · 1 session\n  Something claude added"),
    ("a list item with no percent", heading + "Last 7d · 9 requests · 2 sessions\n  Top subagents: Explore"),
    ("a percent past 100", heading + "Last 7d · 9 requests · 2 sessions\n  140% of your usage was at max effort"),
    ("a period with no lines under it", heading + "Last 24h · 2 requests · 1 session"),
    ("a note after the periods", heading + "Last 24h · 2 requests · 1 session\n  9% of your usage was at max effort\n\nA note at the end"),
    ("a paragraph that opens indented", heading + "  9% of your usage was at max effort"),
] {
    check("…shown as claude wrote it: \(label)", ClaudeContributing.parse(odd) == nil,
          "\(String(describing: ClaudeContributing.parse(odd)))")
}

// MARK: - 2. Claude's structured cache

print("2. Claude — the ~/.claude.json cache and login")

let claudeJSON = """
{"numStartups": 3,
 "oauthAccount": {"accountUuid": "x", "emailAddress": "someone@example.com", "billingType": "stripe_subscription",
                  "organizationType": "claude_max", "organizationRateLimitTier": "default_claude_max_20x", "hasExtraUsageEnabled": true},
 "hasAvailableSubscription": false,
 "cachedUsageUtilization": {"fetchedAtMs": 1789285766280, "accountUuid": "x",
   "utilization": {
     "five_hour": {"utilization": 19, "resets_at": "2026-09-13T12:20:00.077063+00:00", "limit_dollars": null},
     "seven_day": {"utilization": 20, "resets_at": "2026-09-19T04:00:00.077088+00:00"},
     "seven_day_opus": null, "seven_day_sonnet": null, "seven_day_oauth_apps": null,
     "amber_ladder": {"utilization": 0, "resets_at": null}, "tangelo": {"utilization": 5},
     "extra_usage": {"is_enabled": false, "monthly_limit": 10000, "used_credits": 2347, "utilization": 23.47,
                     "currency": "USD", "decimal_places": 2, "disabled_reason": "out_of_credits",
                     "user_disabled": false, "credits_ever_enabled": true},
     "seven_day_breakdown": {"rows": [{"key": "claude_code", "percent": 100}]}
   }}}
"""
let seed = ClaudeUsageCache.read(Data(claudeJSON.utf8))
check("cache seeds two rows (nulls and experiment keys ignored)",
      seed?.rows.count == 2, "\(seed?.rows.count ?? -1)")
check("cache rows carry the text's labels",
      seed?.rows.map { $0.label } == ["Current session", "Current week (all models)"])
check("cache reset is a date, ISO with fractional seconds",
      seed?.rows[0].resetDate.map { Int($0.timeIntervalSince1970) } == 1789302000)
check("fetchedAtMs is the seed's own stamp",
      seed?.fetchedAt.map { Int($0.timeIntervalSince1970) } == 1789285766)
if case .usageCredits(let used, let limit, let exponent, let currency, let enabled, let reason)? = seed?.credits {
    check("credits line: $23.47 of $100.00, off (out of credits)",
          used == 2347 && limit == 10000 && exponent == 2 && currency == "USD" && !enabled && reason == "out_of_credits")
} else {
    check("credits line present", false)
}
let neverCredits = ClaudeUsageCache.credits(in: ["credits_ever_enabled": false, "monthly_limit": 1, "used_credits": 0])
check("credits never enabled → no line", neverCredits == nil)
check("organizationType read", ClaudeUsageCache.organizationType(Data(claudeJSON.utf8)) == "claude_max")
check("a file without the cache seeds nothing", ClaudeUsageCache.read(Data("{\"oauthAccount\":{}}".utf8)) == nil)

// MARK: - 3. Codex answers

print("3. Codex — account/read and account/rateLimits/read")

let codexAccountChatGPT = json(#"{"id":2,"result":{"account":{"type":"chatgpt","email":"x@example.com","planType":"prolite"},"requiresOpenaiAuth":true}}"#)
let codexAccountAPIKey = json(#"{"id":2,"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}}"#)
let codexAccountSignedOut = json(#"{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}"#)
let codexRateLimits = json("""
{"id":3,"result":{"ordinaryUsageAllowed":true,
 "rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":48,"windowDurationMins":10080,"resetsAt":1789820360},"secondary":null,
               "credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"planType":"prolite"},
 "rateLimitsByLimitId":{
   "codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1789298310},"secondary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1789885110},"planType":"prolite"},
   "codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":48,"windowDurationMins":10080,"resetsAt":1789820360},"secondary":null,"planType":"prolite"}},
 "rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"a","status":"available","title":"Full reset"},{"id":"b","status":"available","title":"Full reset"}]},
 "accountId":"x","rateLimitUpsell":null}}
""")
let codexRefused = json(#"{"error":{"code":-32600,"message":"chatgpt authentication required to read rate limits"},"id":3}"#)

check("account.type chatgpt → plan named by planType",
      CodexUsageAnswer.accountKind(codexAccountChatGPT) == .plan(name: "Prolite"))
check("account.type apiKey → API key", CodexUsageAnswer.accountKind(codexAccountAPIKey) == .apiKey)
check("account null → signed out", CodexUsageAnswer.accountKind(codexAccountSignedOut) == .signedOut)
check("no answer → unknown", CodexUsageAnswer.accountKind(nil) == .unknown)

let codexReport = CodexUsageAnswer.parse(account: codexAccountChatGPT, rateLimits: codexRateLimits)
check("codex report is a plan", codexReport.kind == .plan(name: "Prolite"))
check("account window first: weekly at 48 %",
      codexReport.rows.first?.window == PlanWindow(duration: 1, unit: .week)
      && codexReport.rows.first?.percent == 48 && codexReport.rows.first?.label == nil)
check("account reset is epoch seconds",
      codexReport.rows.first?.resetDate.map { Int($0.timeIntervalSince1970) } == 1789820360)
check("per-model rows: 5-hour and weekly, named, account entry not repeated",
      codexReport.rows.count == 3
      && codexReport.rows[1].label == "GPT-5.3-Codex-Spark" && codexReport.rows[1].window == PlanWindow(duration: 5, unit: .hour)
      && codexReport.rows[2].label == "GPT-5.3-Codex-Spark" && codexReport.rows[2].window == PlanWindow(duration: 1, unit: .week),
      "\(codexReport.rows.count) rows")
check("free resets are codex's detail, never a note", codexReport.notes.isEmpty)
let refused = CodexUsageAnswer.parse(account: codexAccountChatGPT, rateLimits: codexRefused)
check("a refusal is codex's own sentence", refused.failure == "chatgpt authentication required to read rate limits" && refused.rows.isEmpty && refused.answered)
let apiReport = CodexUsageAnswer.parse(account: codexAccountAPIKey, rateLimits: codexRefused)
check("an API-key account carries no failure and no rows", apiReport.kind == .apiKey && apiReport.failure == nil && apiReport.rows.isEmpty)
let unanswered = CodexUsageAnswer.parse(account: codexAccountChatGPT, rateLimits: nil)
check("a plan account whose limits never arrived is NOT answered", unanswered.kind.isPlan && !unanswered.answered && unanswered.failure == nil && unanswered.rows.isEmpty)
let shapeless = CodexUsageAnswer.parse(account: codexAccountChatGPT, rateLimits: json(#"{"id":3,"jsonrpc":"2.0"}"#))
check("an answer with neither result nor error is not answered either", !shapeless.answered)
let accountless = CodexUsageAnswer.parse(account: nil, rateLimits: codexRefused)
check("an unreadable account keeps the limits refusal so the card says something", accountless.kind == .unknown && accountless.failure != nil)
check("window folding: 300 → 5 h, 10080 → 1 w, 1440 → 1 d, 90 → 90 min",
      PlanWindow.minutes(300) == PlanWindow(duration: 5, unit: .hour)
      && PlanWindow.minutes(10080) == PlanWindow(duration: 1, unit: .week)
      && PlanWindow.minutes(1440) == PlanWindow(duration: 1, unit: .day)
      && PlanWindow.minutes(90) == PlanWindow(duration: 90, unit: .minute))
check("planType capitalised, never mapped", CodexUsageAnswer.displayPlanType("prolite") == "Prolite")


// MARK: - 3b. Codex — credits, spend cap, a reached limit, resets, history

// The same `account/rateLimits/read` answer carries more than the
// windows: the credits balance, a workspace spend cap, why usage stopped
// and each reset with its id, title and use-by date. Field names from
// `codex app-server generate-ts` on 0.162.1 (`RateLimitSnapshot`,
// `RateLimitResetCreditsSummary`); a fixture in that shape, synthetic.
print("3b. Codex — credits, spend cap, a reached limit, resets, history")

let codexDetailed = json("""
{"id":3,"result":{"ordinaryUsageAllowed":false,
 "rateLimits":{"limitId":"codex","limitName":null,"normalModelSlug":null,
   "primary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1789820360},"secondary":null,
   "credits":{"hasCredits":true,"unlimited":false,"balance":"480.7707625000"},
   "individualLimit":{"limit":"500","used":"125.5","remainingPercent":75,"resetsAt":1790000000},
   "spendControlReached":false,"planType":"pro","rateLimitReachedType":"rate_limit_reached"},
 "rateLimitsByLimitId":null,
 "rateLimitResetCredits":{"availableCount":3,"credits":[
   {"id":"rc_1","resetType":"codexRateLimits","status":"available","grantedAt":1789000000,"expiresAt":1790500000,"title":"Full reset","description":"Resets every limit"},
   {"id":"rc_2","resetType":"codexRateLimits","status":"redeeming","grantedAt":1789000000,"expiresAt":null,"title":null,"description":null},
   {"id":"rc_3","resetType":"unknown","status":"available","grantedAt":1789000000,"expiresAt":null,"title":null,"description":null}]},
 "accountId":"x","rateLimitUpsell":null}}
""")
let detailed = CodexUsageAnswer.parse(account: codexAccountChatGPT, rateLimits: codexDetailed)
let detail = detailed.detail
check("the credits balance, as codex states it", detail?.balance == "480.7707625000" && detail?.unlimited == false,
      "\(String(describing: detail))")
check("the workspace spend cap", detail?.spendCap == CodexSpendCap(limit: "500", used: "125.5", remainingPercent: 75,
                                                                    resetsAt: Date(timeIntervalSince1970: 1790000000)))
check("why usage stopped, as codex's own value", detail?.reached == "rate_limit_reached")
check("the resets codex can use: the available ones, in codex's order, each with its id",
      detail?.resets?.map(\.id) == ["rc_1", "rc_3"] && detail?.resetsAvailable == 3)
check("…a reset's name, words and use-by date are codex's",
      detail?.resets?.first == CodexResetCredit(id: "rc_1", title: "Full reset", description: "Resets every limit",
                                                expiresAt: Date(timeIntervalSince1970: 1790500000)))
check("…one with none of them is still a reset", detail?.resets?.last == CodexResetCredit(id: "rc_3", title: nil, description: nil, expiresAt: nil))
check("the window's count is the available count", codexReport.detail?.resetsAvailable == 2)
check("no credits on the account → no balance", codexReport.detail?.balance == nil && codexReport.detail?.unlimited == false)
let countOnly = CodexUsageAnswer.parse(account: codexAccountChatGPT, rateLimits: json(#"{"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":1789820360},"credits":{"hasCredits":true,"unlimited":true,"balance":null}},"rateLimitResetCredits":{"availableCount":1,"credits":null}}}"#))
check("a count with no list (codex: \"only availableCount is known\") keeps the count and lists nothing",
      countOnly.detail?.resetsAvailable == 1 && countOnly.detail?.resets == nil)
check("unlimited credits", countOnly.detail?.unlimited == true && countOnly.detail?.balance == nil)
check("no spend cap, no reached limit", countOnly.detail?.spendCap == nil && countOnly.detail?.reached == nil)

// Codex's own sentences, read in its binary (0.162.1), one per value of
// `rateLimitReachedType`. A value codex adds later gets none, never a
// guess.
check("a reached limit is said in codex's words",
      CodexUsageAnswer.reachedSentence("rate_limit_reached") == "You've hit your usage limit."
      && CodexUsageAnswer.reachedSentence("workspace_owner_credits_depleted") == "Your workspace is out of credits. Add credits to continue."
      && CodexUsageAnswer.reachedSentence("workspace_member_credits_depleted") == "Your workspace is out of credits. Ask your workspace owner to refill in order to continue."
      && CodexUsageAnswer.reachedSentence("workspace_owner_usage_limit_reached") == "You hit your spend cap set in your workspace. Increase your spend cap to continue."
      && CodexUsageAnswer.reachedSentence("workspace_member_usage_limit_reached") == "You hit your spend cap set by the owner of your workspace. Ask an owner to increase your spend cap to continue.")
check("…and a value codex has not used yet says nothing", CodexUsageAnswer.reachedSentence("something_new") == nil)

// `account/usage/read` (`GetAccountTokenUsageResponse`): a summary and
// one bucket per day codex reports.
let historyAnswer = json(#"{"id":4,"result":{"summary":{"lifetimeTokens":3268580129,"peakDailyTokens":417925784,"longestRunningTurnSec":11969,"currentStreakDays":10,"longestStreakDays":12},"dailyUsageBuckets":[{"startDate":"2026-09-28","tokens":100},{"startDate":"not a date","tokens":5},{"startDate":"2026-10-01","tokens":50},{"startDate":"2026-10-10","tokens":7}],"threadUsage":null}}"#)
let history = CodexUsageHistory.parse(historyAnswer)
check("history: codex's summary, its longest chat included",
      history?.lifetimeTokens == 3268580129 && history?.peakDailyTokens == 417925784
      && history?.longestRunningTurnSec == 11969
      && history?.currentStreakDays == 10 && history?.longestStreakDays == 12, "\(String(describing: history))")

// The year of squares, by codex's own rules (its terminal's
// `activity_chart.rs`): fifty-two weeks ending with this one, a column a
// week, every day graded against the busiest day shown, nothing drawn
// after today, a month named over the column whose first day is among
// its first seven.
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
let lastDay = Date(timeIntervalSince1970: 1791590400) // Saturday 2026-10-10
let year = CodexActivityCalendar.make(history!, today: lastDay, calendar: CodexActivityCalendar.days(utc))
func dayKey(_ date: Date) -> String { CodexUsageHistory.dayFormatter(utc).string(from: date) }
let drawn = year.weeks.flatMap { $0.compactMap { $0 } }
check("fifty-two weeks of seven days", year.weeks.count == 52 && year.weeks.allSatisfy { $0.count == 7 },
      "\(year.weeks.count)")
check("…ending with today's square, in the week's last row for a week that starts on Sunday",
      dayKey(year.weeks[51][6]!.date) == "2026-10-10" && year.weeks[51].allSatisfy { $0 != nil }
      && drawn.allSatisfy { $0.date <= lastDay })
check("…and starting fifty-one weeks before this week's Sunday",
      dayKey(year.weeks[0][0]!.date) == "2025-10-12" && utc.component(.weekday, from: year.weeks[0][0]!.date) == 1)
check("a day's tokens are codex's for that day, a day codex did not report has none",
      drawn.first { dayKey($0.date) == "2026-09-28" }?.tokens == 100
      && drawn.first { dayKey($0.date) == "2026-10-01" }?.tokens == 50
      && drawn.first { dayKey($0.date) == "2026-10-10" }?.tokens == 7
      && drawn.filter { $0.tokens > 0 }.count == 3 && drawn.reduce(0) { $0 + $1.tokens } == 157)
check("…a bucket whose date does not read is left out", !drawn.contains { $0.tokens == 5 })
check("the grades are codex's, against the busiest day shown",
      year.peak == 100
      && drawn.first { dayKey($0.date) == "2026-09-28" }?.level == 4
      && drawn.first { dayKey($0.date) == "2026-10-01" }?.level == 2
      && drawn.first { dayKey($0.date) == "2026-10-10" }?.level == 1
      && drawn.filter { $0.tokens == 0 }.allSatisfy { $0.level == 0 })
check("…past three quarters 4, past half 3, past a quarter 2, else 1, at codex's boundaries",
      [76, 75, 51, 50, 26, 25, 1, 0].map { CodexActivityCalendar.level($0, peak: 100) } == [4, 3, 3, 2, 2, 1, 1, 0])
check("…compared at full width, as codex compares them",
      CodexActivityCalendar.level(Int64.max, peak: Int64.max) == 4
      && CodexActivityCalendar.level(Int64.max / 2, peak: Int64.max) == 2)
check("a month is named over exactly the columns whose first day is one of its first seven",
      !year.monthColumns.isEmpty
      && (0..<52).allSatisfy { column in
          year.monthColumns.contains(column) == (utc.component(.day, from: year.weeks[column][0]!.date) <= 7) })
// Codex's own week start, whatever the Mac's: `days(_:)` starts every
// week on Sunday (codex's `chart_start`: today less the days since
// Sunday), so a Mac whose week starts on Monday draws the same columns,
// today's Saturday in the last row and nothing still to come.
var mondays = utc
mondays.firstWeekday = 2
let mondayDays = CodexActivityCalendar.days(mondays)
let mondayYear = CodexActivityCalendar.make(history!, today: lastDay, calendar: mondayDays)
check("on a Mac whose week starts on Monday, each column still opens on a Sunday, as codex's does",
      mondayDays.firstWeekday == 1
      && mondayYear.weeks.allSatisfy { utc.component(.weekday, from: $0[0]!.date) == 1 })
check("…today's Saturday is the week's last row, with no square still to come, the year as on any Mac",
      mondayYear.weeks[51][6] != nil && dayKey(mondayYear.weeks[51][6]!.date) == "2026-10-10"
      && mondayYear.weeks == year.weeks)
check("…and days() keeps the Mac's own language, in UTC",
      mondayDays.locale == mondays.locale && mondayDays.timeZone.secondsFromGMT() == 0)
let twice = CodexUsageHistory.parse(json(#"{"id":4,"result":{"summary":{},"dailyUsageBuckets":[{"startDate":"2026-10-09","tokens":3},{"startDate":"2026-10-09","tokens":4}]}}"#))!
check("a day codex reports twice counts both",
      CodexActivityCalendar.make(twice, today: lastDay, calendar: utc).weeks[51][5]?.tokens == 7)
let old = CodexUsageHistory.parse(json(#"{"id":4,"result":{"summary":{},"dailyUsageBuckets":[{"startDate":"2024-01-02","tokens":900},{"startDate":"2026-10-11","tokens":800}]}}"#))!
check("a day before the fifty-two weeks or after today is not drawn, and grades nothing",
      CodexActivityCalendar.make(old, today: lastDay, calendar: utc).peak == 0)
// Pointing at a square says the day's tokens exactly — no rounding, no
// "408M" — whatever the Mac's number format.
check("the hover text gives the day's tokens exactly",
      CodexActivityCalendar.tokensText(408_138_620).filter(\.isNumber) == "408138620"
      && CodexActivityCalendar.tokensText(408_138_620).hasSuffix(" tokens")
      && CodexActivityCalendar.tokensText(0).filter(\.isNumber) == "0"
      && CodexActivityCalendar.tokensText(1) == "1 token", CodexActivityCalendar.tokensText(408_138_620))
check("…and names the day in the calendar's own time zone",
      CodexActivityCalendar.dayText(year.weeks[51][6]!.date, calendar: utc).contains("10")
      && CodexActivityCalendar.dayText(year.weeks[51][6]!.date, calendar: utc).contains("2026"))
// Codex writes its days as Gregorian dates. On a Mac whose calendar
// counts its years another way (System Settings → General → Language &
// Region → Calendar), a day key written in the Mac's calendar
// ("2569-10-10" in the Buddhist one) matches none of codex's, and the
// year reads empty.
for id in [Calendar.Identifier.buddhist, .japanese, .persian, .islamicUmmAlQura] {
    var other = Calendar(identifier: id)
    other.timeZone = utc.timeZone
    let otherYear = CodexActivityCalendar.make(history!, today: lastDay, calendar: other)
    let otherTokens = otherYear.weeks.flatMap { $0.compactMap { $0?.tokens } }.reduce(0, +)
    check("a Mac on the \(id) calendar still finds codex's days", otherTokens == 157 && otherYear.peak == 100,
          "\(otherTokens) tokens drawn")
}
// Codex's own terminal ends its year on today's date in UTC
// (`Utc::now().date_naive()` in its analytics view), and its history
// request carries no zone of the Mac's: codex reads a bucket as a day in
// UTC. Laid out in the Mac's own days, the day codex has begun is left
// out for hours west of UTC, and east of it the year ends on a day codex
// has not begun.
let aroundMidnight = CodexUsageHistory.parse(json(#"{"id":4,"result":{"summary":{},"dailyUsageBuckets":[{"startDate":"2026-10-10","tokens":5},{"startDate":"2026-10-11","tokens":9}]}}"#))!
let macZone = NSTimeZone.default
NSTimeZone.default = TimeZone(identifier: "America/New_York")!
// 03:00 on Oct 11 in UTC: 23:00 on Oct 10 in New York.
let westYear = CodexActivityCalendar.make(aroundMidnight, today: Date(timeIntervalSince1970: 1791687600))
NSTimeZone.default = TimeZone(identifier: "Asia/Tokyo")!
// 20:00 on Oct 10 in UTC: 05:00 on Oct 11 in Tokyo.
let eastYear = CodexActivityCalendar.make(aroundMidnight, today: Date(timeIntervalSince1970: 1791662400))
NSTimeZone.default = macZone
let westDays = westYear.weeks.flatMap { $0.compactMap { $0 } }
let eastDays = eastYear.weeks.flatMap { $0.compactMap { $0 } }
check("the year ends on codex's today, the date in UTC: west of UTC the day codex has begun is drawn",
      westDays.last.map { dayKey($0.date) } == "2026-10-11" && westDays.last?.tokens == 9
      && westDays.reduce(0) { $0 + $1.tokens } == 14,
      "\(westDays.last.map { dayKey($0.date) } ?? "none"), \(westDays.reduce(0) { $0 + $1.tokens }) tokens")
check("…and east of it the year does not run past codex's today",
      eastDays.last.map { dayKey($0.date) } == "2026-10-10" && eastDays.last?.tokens == 5,
      "\(eastDays.last.map { dayKey($0.date) } ?? "none"), \(eastDays.last?.tokens ?? 0) tokens")
// Codex adds a day it reports twice and saturates rather than overflow
// (its terminal's own test feeds it Int64.max twice): a sum past what an
// Int64 holds must not stop the app.
let twiceHuge = CodexUsageHistory(lifetimeTokens: nil, peakDailyTokens: nil, longestRunningTurnSec: nil,
                                  currentStreakDays: nil, longestStreakDays: nil,
                                  days: [.init(date: "2026-10-09", tokens: 8_000_000_000_000_000_000),
                                         .init(date: "2026-10-09", tokens: 8_000_000_000_000_000_000)])
check("a day whose two reports pass what an Int64 holds saturates, as codex's does",
      twiceHuge.tokensByDay()["2026-10-09"] == Int64.max)
// Codex's app-server passes the backend's daily buckets through as they
// come, `null` included, and codex's terminal then says "Token activity
// history unavailable" rather than draw a year of empty days.
let noDays = CodexUsageHistory.parse(json(#"{"id":4,"result":{"summary":{"lifetimeTokens":12},"dailyUsageBuckets":null}}"#))
check("a history with no days codex sent says so — never a year in which nothing was used",
      noDays?.reportsDays == false && noDays?.lifetimeTokens == 12 && history?.reportsDays == true
      && CodexUsageHistory.parse(json(#"{"id":4,"result":{"summary":{},"dailyUsageBuckets":[]}}"#))?.reportsDays == true,
      "\(String(describing: noDays))")
check("an error answer is no history", CodexUsageHistory.parse(codexRefused) == nil && CodexUsageHistory.parse(nil) == nil)
// A codex without the request answers it with "Invalid request: unknown
// variant `account/usage/read`, expected one of …" — every method it
// has, one long line (measured on 0.162.1 with a method it lacks). So
// the history is asked only of a codex known to have it, as the reset is.
check("the history is asked only of a codex known to have the request",
      !CodexUsageHistory.offered(installedCodex: nil)
      && !CodexUsageHistory.offered(installedCodex: CLIVersion.parse("0.162.0"))
      && CodexUsageHistory.offered(installedCodex: CLIVersion.parse("0.162.1"))
      && CodexUsageHistory.offered(installedCodex: CLIVersion.parse("0.170.0")))

// MARK: - 3c. Codex — using a reset

// `account/rateLimitResetCredit/consume {idempotencyKey, creditId?}` →
// `{outcome: reset | nothingToReset | noCredit | alreadyRedeemed}` —
// the request codex's own terminal makes from /usage → Redeem reset.
// Codex's schema: "reuse the same value when retrying that attempt".
print("3c. Codex — using a reset: the request, the outcomes, the attempt")

let consumeLine = CodexResetConsume.request(idempotencyKey: "key-1", creditId: #"rc_"quoted"\slash"#)
let consume = json(consumeLine)
let consumeParams = consume?["params"] as? [String: Any]
check("the request is codex's method, as request 2",
      consume?["method"] as? String == "account/rateLimitResetCredit/consume"
      && (consume?["id"] as? NSNumber)?.intValue == CodexAppServerCall.answerId,
      consumeLine)
check("…carrying the attempt's key and the credit's id, JSON-escaped",
      consumeParams?["idempotencyKey"] as? String == "key-1" && consumeParams?["creditId"] as? String == #"rc_"quoted"\slash"#)
check("…and no credit id when codex is to pick the next one (only the count was known)",
      (json(CodexResetConsume.request(idempotencyKey: "k", creditId: nil))?["params"] as? [String: Any])?.keys.sorted() == ["idempotencyKey"])
check("each outcome read from codex's answer",
      CodexResetConsume.outcome(of: json(#"{"id":2,"result":{"outcome":"reset"}}"#)) == .reset
      && CodexResetConsume.outcome(of: json(#"{"id":2,"result":{"outcome":"nothingToReset"}}"#)) == .nothingToReset
      && CodexResetConsume.outcome(of: json(#"{"id":2,"result":{"outcome":"noCredit"}}"#)) == .noCredit
      && CodexResetConsume.outcome(of: json(#"{"id":2,"result":{"outcome":"alreadyRedeemed"}}"#)) == .alreadyRedeemed)
check("a refusal keeps codex's words; no answer is no answer",
      CodexResetConsume.outcome(of: json(#"{"id":2,"error":{"code":-32600,"message":"not now"}}"#)) == .refused("not now")
      && CodexResetConsume.outcome(of: nil) == .noAnswer
      && CodexResetConsume.outcome(of: json(#"{"id":2,"result":{"outcome":"somethingNew"}}"#)) == .refused("somethingNew"))
// Codex's own words for each outcome, read in its binary (0.162.1).
check("each outcome is said in codex's terminal words",
      CodexResetConsume.Outcome.reset.sentence == "Usage reset."
      && CodexResetConsume.Outcome.nothingToReset.sentence == "Your usage does not need a reset right now."
      && CodexResetConsume.Outcome.noCredit.sentence == "No usage limit resets are available."
      && CodexResetConsume.Outcome.alreadyRedeemed.sentence == "That reset is no longer available. Refresh to see your current resets."
      && CodexResetConsume.Outcome.refused("x").sentence == "Couldn't reset usage. Please try again."
      && CodexResetConsume.Outcome.noAnswer.sentence == "Couldn't reset usage. Please try again.")
check("an answer settles the attempt; a refusal or silence leaves it to be retried",
      [CodexResetConsume.Outcome.reset, .nothingToReset, .noCredit, .alreadyRedeemed].allSatisfy(\.settles)
      && !CodexResetConsume.Outcome.refused("x").settles && !CodexResetConsume.Outcome.noAnswer.settles)

var attempts = CodexResetAttempts()
let firstKey = attempts.begin(creditId: "rc_1")
check("an attempt gets a key", firstKey != nil && attempts.running)
check("a second click while one runs sends nothing", attempts.begin(creditId: "rc_1") == nil && attempts.begin(creditId: "rc_3") == nil)
attempts.finish(.noAnswer)
check("a retry of an attempt that got no answer reuses its key", !attempts.running && attempts.begin(creditId: "rc_1") == firstKey)
attempts.finish(.refused("x"))
check("…as does one codex refused", attempts.begin(creditId: "rc_1") == firstKey)
attempts.finish(.reset)
let afterReset = attempts.begin(creditId: "rc_1")
check("an attempt codex answered is over: the next one is a new attempt with a new key", afterReset != nil && afterReset != firstKey)
attempts.finish(.noAnswer)
let otherCredit = attempts.begin(creditId: "rc_3")
check("another reset is another attempt, whatever the last one left", otherCredit != nil && otherCredit != afterReset)
attempts.finish(.reset)

// Through the REAL app-server client, against a stand-in that records
// what it was sent and answers each outcome — no reset is ever spent.
let stubServer = harnessDir + "/codex_appserver_stub.py"
let stubRecord = tmp.appendingPathComponent("consume.jsonl")
func consumeThroughStub(_ outcome: String, key: String, creditId: String?) -> CodexResetConsume.Outcome {
    setenv("STUB_OUTCOME", outcome, 1)
    setenv("STUB_RECORD", stubRecord.path, 1)
    defer { unsetenv("STUB_OUTCOME"); unsetenv("STUB_RECORD") }
    final class Box: @unchecked Sendable { var outcome: CodexResetConsume.Outcome = .noAnswer }
    let box = Box()
    let group = DispatchGroup()
    group.enter()
    Task {
        box.outcome = await CodexResetConsume.run(binary: stubServer, idempotencyKey: key, creditId: creditId)
        group.leave()
    }
    group.wait()
    return box.outcome
}
if FileManager.default.isExecutableFile(atPath: stubServer) {
    let throughStub = ["reset", "nothingToReset", "noCredit", "alreadyRedeemed"].map {
        consumeThroughStub($0, key: "key-\($0)", creditId: "rc_1")
    }
    check("the real client brings each of codex's four outcomes back",
          throughStub == [.reset, .nothingToReset, .noCredit, .alreadyRedeemed], "\(throughStub)")
    check("a refusal comes back with codex's words", consumeThroughStub("error", key: "key-e", creditId: nil) == .refused("stub refusal: try again later"))
    check("a server that answers nothing is no answer", consumeThroughStub("silent", key: "key-s", creditId: "rc_9") == .noAnswer)
    let sent = ((try? String(contentsOf: stubRecord, encoding: .utf8)) ?? "")
        .split(separator: "\n").compactMap { json(String($0)) }
    check("the stand-in was sent each attempt's own key and the credit's id",
          sent.count == 6 && sent.first?["idempotencyKey"] as? String == "key-reset"
          && sent.first?["creditId"] as? String == "rc_1"
          && sent[4]["creditId"] == nil && sent[5]["creditId"] as? String == "rc_9",
          "\(sent)")
} else {
    check("the stand-in app-server is executable", false, stubServer)
}

// The method is in codex 0.162.1's stable protocol (generate-ts); the
// button is offered only for a codex known to be that new or newer.
check("the reset button needs a codex known to have the request",
      !CodexResetConsume.offered(installedCodex: nil)
      && !CodexResetConsume.offered(installedCodex: CLIVersion.parse("0.162.0"))
      && CodexResetConsume.offered(installedCodex: CLIVersion.parse("0.162.1"))
      && CodexResetConsume.offered(installedCodex: CLIVersion.parse("0.163.0")))
// "Update Codex to use a reset here" is a claim about the installed
// codex: made for a version known to be older, never for one not read.
check("the section asks for a newer codex only when the installed one is known to be older",
      !CodexResetConsume.needsNewerCodex(installedCodex: nil)
      && CodexResetConsume.needsNewerCodex(installedCodex: CLIVersion.parse("0.162.0"))
      && !CodexResetConsume.needsNewerCodex(installedCodex: CLIVersion.parse("0.162.1")))

// How the section marks codex's answer: a check for a reset used, a
// note for nothing to do, a warning for a reset that could not be used.
// `settles` is about the attempt's key, not about success: "That reset
// is no longer available" ends the attempt and is no success.
check("each outcome is marked for what it means to the user",
      CodexResetConsume.Outcome.reset.tone == .done
      && CodexResetConsume.Outcome.nothingToReset.tone == .info
      && [CodexResetConsume.Outcome.noCredit, .alreadyRedeemed, .refused("x"), .noAnswer]
        .allSatisfy { $0.tone == .problem })

// MARK: - 3d. Codex — a codex that cannot start

// npm can end an install without Codex's macOS program, and the launcher
// it leaves throws on every start. The card then gets nothing from
// codex's app-server, and what codex prints when asked its version is the
// line to show — never "did not answer" over a tool that said what is
// wrong. The card's three steps, each through the real code, against a
// stand-in launcher that stops in Node's shape.
print("3d. Codex — a codex that cannot start: nothing answered, then its own words")

let codexWithoutProgram = tmp.appendingPathComponent("codex-without-program")
try? """
#!/bin/sh
cat >&2 <<'TRACE'
file:///usr/local/lib/node_modules/@openai/codex/bin/codex.js:108
  throw new Error(
        ^

Error: Missing optional dependency @openai/codex-darwin-arm64. Reinstall Codex: npm install -g @openai/codex@latest
    at findCodexExecutable (file:///usr/local/lib/node_modules/@openai/codex/bin/codex.js:108:9)

Node.js v22.12.0
TRACE
exit 1
""".write(to: codexWithoutProgram, atomically: true, encoding: .utf8)
try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexWithoutProgram.path)
final class CannotStartBox: @unchecked Sendable {
    var available = true
    var read: (version: CLIVersion?, startFailure: String?) = (nil, nil)
}
/// The usage probe, then the version read, of the tool at `path`.
func probeThenVersion(of path: String) -> CannotStartBox {
    let box = CannotStartBox()
    let done = DispatchGroup()
    done.enter()
    Task {
        box.available = await CodexUsageProbe.run(binary: path).available
        box.read = await AgentCLIProbe.installedVersion(
            agentKey: "codex",
            fingerprint: CLIBinaryFingerprint(path: path, linkModified: nil, linkTarget: nil,
                                              targetPath: path, targetModified: nil, targetSize: nil))
        done.leave()
    }
    done.wait()
    return box
}
let cannotStart = probeThenVersion(of: codexWithoutProgram.path)
check("its app-server answers nothing at all", !cannotStart.available)
check("asked its version, it names none — not Node's, out of its trace",
      cannotStart.read.version == nil, "\(String(describing: cannotStart.read.version))")
check("…and the line the card shows is codex's own error, its remedy in it",
      cannotStart.read.startFailure.flatMap(CLIStartFailure.reason(in:))
        == "Error: Missing optional dependency @openai/codex-darwin-arm64. "
            + "Reinstall Codex: npm install -g @openai/codex@latest",
      cannotStart.read.startFailure ?? "nothing said")

// MARK: - 4. Kimi's envelope

print("4. Kimi — the /oauth/usage envelope")

let kimiError = Data(#"{"code":0,"msg":"success","data":{"kind":"error","message":"No token for \"kimi-code\". Run /login to authenticate."},"request_id":"01M2CW16NT"}"#.utf8)
let kimiErr = KimiUsageAnswer.parse(body: kimiError)
check("kimi error branch: kimi's own sentence", kimiErr.kind == .error && kimiErr.failure == "No token for \"kimi-code\". Run /login to authenticate.")
let kimiOK = Data("""
{"code":0,"msg":"success","data":{"kind":"ok",
 "summary":{"used":1234,"limit":5000,"reset_at":"2026-09-18T04:00:00Z"},
 "limits":[{"name":"5-hour window","window":{"duration":5,"unit":"hour"},"used":120,"limit":1000},
           {"window":{"duration":1,"unit":"day"},"used":"7","limit":"10","reset_at":"soon"}],
 "extra_usage":{"balance_cents":1250,"total_cents":2000,"monthly_charge_limit_enabled":false,"monthly_charge_limit_cents":0,"monthly_used_cents":0,"currency":"USD"}}}
""".utf8)
let kimiOk = KimiUsageAnswer.parse(body: kimiOK)
check("kimi ok branch parses", kimiOk.kind == .ok && kimiOk.failure == nil)
check("summary row: weekly by default, counts, ISO reset",
      kimiOk.rows.first?.window == PlanWindow(duration: 1, unit: .week)
      && kimiOk.rows.first?.used == 1234 && kimiOk.rows.first?.limit == 5000
      && kimiOk.rows.first?.resetDate != nil && kimiOk.rows.first?.resetText == nil)
check("limit rows: name + window; a string count still reads; an unparseable reset stays as text",
      kimiOk.rows.count == 3
      && kimiOk.rows[1].label == "5-hour window" && kimiOk.rows[1].window == PlanWindow(duration: 5, unit: .hour)
      && kimiOk.rows[2].used == 7 && kimiOk.rows[2].resetText == "soon" && kimiOk.rows[2].resetDate == nil)
check("wallet note in kimi's terms: used this month, the monthly limit (none here), the balance",
      kimiOk.notes == [.extraUsage(usedCents: 0, limitCents: nil, balanceCents: 1250, currency: "USD")])
check("bar fraction from counts", kimiOk.rows.first?.fraction.map { abs($0 - 0.2468) < 0.001 } == true)
check("a non-zero envelope code is a failure", KimiUsageAnswer.parse(body: Data(#"{"code":40101,"msg":"Unauthorized","data":null}"#.utf8)).failure == "Unauthorized")
check("garbage is malformed, not a verdict", KimiUsageAnswer.parse(body: Data("<html>".utf8)).kind == .malformed)
let huge = KimiUsageAnswer.parse(body: Data(#"{"code":0,"data":{"kind":"ok","summary":{"used":"1e30","limit":5000},"limits":[{"used":3,"limit":1e300}]}}"#.utf8))
check("a count past the integer range is dropped, not trapped on", huge.kind == .ok && huge.rows.isEmpty)

// The route's quota shape: kimi's own parse of the upstream
// (`managedUsageResultSchema`) — `quota.usages.{limit5h, limit7d,
// monthTotal, monthCode}` as ratios, `quota.extraUsage` in cents,
// camelCase, nothing renamed on the way out. Read as the summary/limits
// shape it is an ok answer with no rows: a card with a title and nothing
// under it, and no error.
let kimiQuotaOK = Data("""
{"code":0,"msg":"success","data":{"kind":"ok","quota":{
 "usages":{"limit5h":{"usedRatio":0.42,"resetAt":"2026-10-10T20:00:00Z"},
           "limit7d":{"usedRatio":0.125,"resetAt":"2026-10-14T04:00:00.000Z"},
           "monthTotal":{"usedRatio":0.45,"resetAt":"2026-11-01T00:00:00Z"},
           "monthCode":{"usedRatio":0.15}},
 "extraUsage":{"balanceCents":1250,"totalCents":2000,"monthlyChargeLimitEnabled":true,
               "monthlyChargeLimitCents":5000,"monthlyUsedCents":300,"currency":"USD"}}},
 "request_id":"01HARNESS"}
""".utf8)
let k2 = KimiUsageAnswer.parse(body: kimiQuotaOK)
check("quota shape: kimi's three rows, in kimi's words and order",
      k2.kind == .ok && k2.failure == nil && k2.rows.map(\.label) == ["5h limit", "Weekly limit", "Monthly limit"],
      "\(k2.rows.map(\.label))")
// 0.125 is 12.5 %: kimi rounds half up (Math.round), so 13 — a
// truncation or a round-half-even would say 12.
check("…each row's percent is kimi's own rounding of its ratio",
      k2.rows.map(\.percent) == [42, 13, 45], "\(k2.rows.map(\.percent))")
check("…resets read as dates, with and without fractional seconds",
      k2.rows.count == 3 && k2.rows.allSatisfy { $0.resetDate != nil && $0.resetText == nil })
check("…the bar follows the percent", k2.rows.first?.fraction.map { abs($0 - 0.42) < 0.0001 } == true)
check("…the monthly row carries kimi's split: kimi = month total − code, code = code",
      k2.rows.last?.split == PlanUsageSplit(kimiPercent: 30, codePercent: 15), "\(String(describing: k2.rows.last?.split))")
check("…the 5-hour and weekly rows carry none", k2.rows.dropLast().allSatisfy { $0.split == nil })
check("…Extra Usage as kimi shows it: used this month, the monthly limit, the balance",
      k2.notes == [.extraUsage(usedCents: 300, limitCents: 5000, balanceCents: 1250, currency: "USD")], "\(k2.notes)")

let kimi2Sparse = KimiUsageAnswer.parse(body: Data(#"{"code":0,"data":{"kind":"ok","quota":{"usages":{"limit7d":{"usedRatio":1.7},"limit5h":{"usedRatio":-0.2}},"extraUsage":{"balanceCents":90,"totalCents":100,"monthlyChargeLimitEnabled":false,"monthlyChargeLimitCents":5000,"monthlyUsedCents":10,"currency":"CNY"}}}}"#.utf8))
check("quota shape: a window kimi did not serve is no row; the order is kimi's, not the payload's",
      kimi2Sparse.rows.map(\.label) == ["5h limit", "Weekly limit"])
check("…a ratio past either end is clamped, as kimi clamps it",
      kimi2Sparse.rows.map(\.percent) == [0, 100])
check("…a row with no reset has none", kimi2Sparse.rows.allSatisfy { $0.resetDate == nil && $0.resetText == nil })
check("…a monthly limit that is switched off is no limit, whatever its amount",
      kimi2Sparse.notes == [.extraUsage(usedCents: 10, limitCents: nil, balanceCents: 90, currency: "CNY")])
check("…no split without a monthly row", kimi2Sparse.rows.allSatisfy { $0.split == nil })
let kimi2Empty = KimiUsageAnswer.parse(body: Data(#"{"code":0,"data":{"kind":"ok","quota":{"usages":{},"extraUsage":null}}}"#.utf8))
check("quota shape: a quota with nothing in it says kimi's own sentence, never an empty card",
      kimi2Empty.kind == .ok && kimi2Empty.rows.isEmpty && kimi2Empty.notes == [.noUsageData])
check("the summary/limits shape with nothing in it says the same",
      KimiUsageAnswer.parse(body: Data(#"{"code":0,"data":{"kind":"ok","summary":null,"limits":[],"extra_usage":null}}"#.utf8)).notes == [.noUsageData])
// The next shape kimi moves to must not read as "nothing to show".
check("an ok answer in neither shape is malformed — said, never an empty card",
      KimiUsageAnswer.parse(body: Data(#"{"code":0,"data":{"kind":"ok","report":{"rows":[]}}}"#.utf8)).kind == .malformed)

check("token line parsed", KimiWebServerCall.token(in: "Kimi server: http://127.0.0.1:58631/#token=cFU6abc-DEF_9.x\r\nmore", port: 58631) == "cFU6abc-DEF_9.x")
check("no token line → nil", KimiWebServerCall.token(in: "Server listening", port: 58631) == nil)
// The port is found by bind-0-and-close, so another process can take it
// before kimi binds: a kimi listening elsewhere prints ITS port, and the
// bearer must not go to whatever holds the one asked for.
check("a token line naming another port is refused",
      KimiWebServerCall.token(in: "Kimi server: http://127.0.0.1:58632/#token=cFU6abc\r\n", port: 58631) == nil)
check("…as is one naming another host",
      KimiWebServerCall.token(in: "Kimi server: http://10.0.0.5:58631/#token=cFU6abc\r\n", port: 58631) == nil)
check("a line still arriving yields nothing yet — a bearer cut at a read is never sent",
      KimiWebServerCall.token(in: "Kimi server: http://127.0.0.1:58631/#token=cFU6ab", port: 58631) == nil)
check("the right line is found after a wrong one",
      KimiWebServerCall.token(in: "note http://127.0.0.1:1/#token=zzz\nKimi server: http://127.0.0.1:58631/#token=good\n", port: 58631) == "good")

// MARK: - 4b. The real kimi web, over a stand-in upstream

// What the route REALLY answers, measured rather than read: the
// installed kimi, under a throwaway home with a planted login, its
// managed API pointed at kimi_upstream.py. No account, no token spent,
// nothing of the user's touched (KIMI_CODE_HOME is a temp folder;
// telemetry and kimi's self-update are switched off for the run).
print("4b. Kimi — the real kimi web, over a stand-in upstream (token-free, throwaway home)")

/// The host the planted login belongs to — kimi's default, and pinned
/// in the child's environment below so the slot is the one kimi reads
/// whatever the shell running this exports.
let kimiOAuthHost = "https://auth.kimi.com"

/// The credential slot kimi reads for a managed base URL it does not
/// ship with (kimi's `resolveKimiCodeOAuthKey`): `kimi-code-env-` and
/// the first 16 hex of the SHA-256 of `{"oauthHost":…,"baseUrl":…}`,
/// as JSON.stringify writes it.
func kimiScopedSlot(baseUrl: String) -> String {
    let identity = #"{"oauthHost":"\#(kimiOAuthHost)","baseUrl":"\#(baseUrl)"}"#
    let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    return "kimi-code-env-" + digest.prefix(16)
}

if let kimi = AgentManager.binaryPath(for: "kimi") {
    let upstreamScript = harnessDir + "/kimi_upstream.py"
    let record = tmp.appendingPathComponent("kimi-upstream.jsonl")
    let upstream = Process()
    upstream.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    upstream.arguments = ["python3", "-I", upstreamScript, record.path]
    let portPipe = Pipe()
    upstream.standardOutput = portPipe
    upstream.standardError = FileHandle.nullDevice
    var upstreamPort: Int? = nil
    if (try? upstream.run()) != nil {
        var line = Data()
        while true {
            let byte = portPipe.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty || byte == Data([0x0A]) { break }
            line.append(byte)
        }
        let text = String(decoding: line, as: UTF8.self)
        if text.hasPrefix("PORT=") { upstreamPort = Int(text.dropFirst(5)) }
    }
    if let port = upstreamPort {
        defer { upstream.terminate() }
        let baseUrl = "http://127.0.0.1:\(port)/coding/v1"
        let home = tmp.appendingPathComponent("kimi-home", isDirectory: true)
        let credentials = home.appendingPathComponent("credentials", isDirectory: true)
        try? FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        // expires_at 0 is kimi's "never refresh": the planted bearer is
        // sent as it stands, and no token endpoint is ever asked. The
        // slot's host is pinned as well: kimi reads KIMI_CODE_OAUTH_HOST
        // (or KIMI_OAUTH_HOST) ahead of its default, so a shell that
        // exports either sends kimi to a slot nothing was planted in.
        try? #"{"access_token":"harness-token","refresh_token":"","expires_at":0,"scope":"","token_type":"Bearer","expires_in":0}"#
            .write(to: credentials.appendingPathComponent(kimiScopedSlot(baseUrl: baseUrl) + ".json"),
                   atomically: true, encoding: .utf8)
        let overrides = ["KIMI_CODE_HOME": home.path, "KIMI_CODE_BASE_URL": baseUrl,
                         "KIMI_CODE_OAUTH_HOST": kimiOAuthHost,
                         "KIMI_DISABLE_TELEMETRY": "1", "KIMI_CODE_NO_AUTO_UPDATE": "1",
                         "KIMI_CLI_NO_AUTO_UPDATE": "1"]
        for (key, value) in overrides { setenv(key, value, 1) }
        defer { for key in overrides.keys { unsetenv(key) } }

        final class Answer: @unchecked Sendable { var outcome: KimiWebServerCall.Outcome = .unavailable("not run") }
        let answer = Answer()
        let group = DispatchGroup()
        group.enter()
        Task {
            answer.outcome = await KimiWebServerCall.fetchUsage(binary: kimi, scratchDirectory: home)
            group.leave()
        }
        group.wait()
        switch answer.outcome {
        case .answered(let body, let region, let planName):
            check("…and kimi's own server names the site, in the same visit", region == "mainland-cn" || region == "global",
                  region ?? "nil")
            check("…and the membership, from the account kimi's own server reads — the name its web UI shows",
                  planName == "Allegretto", planName ?? "nil")
            let envelope = json(String(decoding: body, as: UTF8.self))
            let data = envelope?["data"] as? [String: Any]
            print("       kimi web answered: \(String(decoding: body.prefix(400), as: UTF8.self))")
            let records = ((try? String(contentsOf: record, encoding: .utf8)) ?? "")
                .split(separator: "\n").compactMap { json(String($0)) }
            check("kimi asked the stand-in for its usages, with the planted login",
                  records.contains { ($0["path"] as? String)?.hasSuffix("/usages") == true && ($0["bearer"] as? Bool) == true },
                  "\(records)")
            check("…and for the account the membership is named from, with the same login",
                  records.contains { ($0["path"] as? String)?.hasSuffix("/me") == true && ($0["bearer"] as? Bool) == true },
                  "\(records)")
            if (data?["kind"] as? String) == "ok", data?["quota"] != nil {
                let usages = (data?["quota"] as? [String: Any])?["usages"] as? [String: Any]
                check("the route answers the quota shape: quota.usages.limit5h.usedRatio, camelCase",
                      ((usages?["limit5h"] as? [String: Any])?["usedRatio"] as? NSNumber)?.doubleValue == 0.42)
                let report = KimiUsageAnswer.parse(body: body)
                check("SipAI reads what the real route answers: three rows with kimi's figures",
                      report.kind == .ok && report.rows.map(\.label) == ["5h limit", "Weekly limit", "Monthly limit"]
                      && report.rows.map(\.percent) == [42, 13, 45],
                      "\(report.kind) \(report.rows.map(\.label)) \(report.rows.map(\.percent))")
                check("…the split and the wallet come through kimi as the stand-in gave them",
                      report.rows.last?.split == PlanUsageSplit(kimiPercent: 30, codePercent: 15)
                      && report.notes == [.extraUsage(usedCents: 300, limitCents: 5000, balanceCents: 1250, currency: "USD")],
                      "\(String(describing: report.rows.last?.split)) \(report.notes)")
            } else if (data?["kind"] as? String) == "ok", data?["summary"] != nil || data?["limits"] != nil {
                // An older kimi answers the summary/limits shape, which section 4's
                // fixtures cover; this stand-in speaks only the quota upstream.
                print("  note this kimi answers the older summary/limits shape — read by section 4's fixtures")
            } else {
                check("kimi web answered an ok envelope", false,
                      "kind=\(data?["kind"] as? String ?? "nil") message=\(data?["message"] as? String ?? "")")
            }
        case .unavailable(let why):
            check("kimi web answered its usage route", false, why)
        }
    } else {
        check("the stand-in upstream starts", false)
    }
} else {
    print("  skip: kimi is not installed")
}

// MARK: - 4c. Kimi — the site its usage page is on

// Kimi Code runs on one of two sites (kimi.com, kimi.ai), with separate
// accounts; the console a member checks is on the site of the login.
// Kimi's own local server says which (`/api/v1/oauth/region`), asked in
// the same server as the usage.
print("4c. Kimi — the site, as kimi's own server answers it")
check("the site's answer is kimi's region id",
      KimiUsageAnswer.region(body: Data(#"{"code":0,"msg":"success","data":{"region":"global"}}"#.utf8)) == "global"
      && KimiUsageAnswer.region(body: Data(#"{"code":0,"data":{"region":"mainland-cn"}}"#.utf8)) == "mainland-cn")
check("…and nothing for a refusal or garbage",
      KimiUsageAnswer.region(body: Data(#"{"code":40101,"msg":"Unauthorized","data":null}"#.utf8)) == nil
      && KimiUsageAnswer.region(body: Data("<html>".utf8)) == nil)

// MARK: - 4d. Each tool's own usage page

// Where each tool sends its user to look at usage: the page the tool
// itself names (claude: claude.ai/settings/usage for a plan,
// platform.claude.com/settings/billing for a key; codex:
// chatgpt.com/settings/usage; kimi: platform.kimi.com / .ai for a
// Moonshot key, its `OPEN_PLATFORMS.consoleUrl`), or — where the tool
// names none — the page its vendor's help names (Kimi's help: the Kimi
// Code Console at /code/console on each site; OpenAI's help: the API
// usage dashboard at platform.openai.com/usage). One host check covers
// every link the section opens.
print("4d. Each tool's own usage page, and the one host check")
let pages: [(String, URL?, String)] = [
    ("claude plan", PlanUsagePages.page(agentKey: "claude_code", onPlan: true, claudeCloudProvider: nil, kimiRegion: nil, kimiKeyProviderId: nil),
     "https://claude.ai/settings/usage"),
    ("claude key", PlanUsagePages.page(agentKey: "claude_code", onPlan: false, claudeCloudProvider: nil, kimiRegion: nil, kimiKeyProviderId: nil),
     "https://platform.claude.com/settings/billing"),
    ("codex plan", PlanUsagePages.page(agentKey: "codex", onPlan: true, claudeCloudProvider: nil, kimiRegion: nil, kimiKeyProviderId: nil),
     "https://chatgpt.com/settings/usage"),
    ("codex key", PlanUsagePages.page(agentKey: "codex", onPlan: false, claudeCloudProvider: nil, kimiRegion: nil, kimiKeyProviderId: nil),
     "https://platform.openai.com/usage"),
    ("kimi plan, kimi.ai", PlanUsagePages.page(agentKey: "kimi", onPlan: true, claudeCloudProvider: nil, kimiRegion: "global", kimiKeyProviderId: nil),
     "https://www.kimi.ai/code/console"),
    ("kimi plan, kimi.com", PlanUsagePages.page(agentKey: "kimi", onPlan: true, claudeCloudProvider: nil, kimiRegion: "mainland-cn", kimiKeyProviderId: nil),
     "https://www.kimi.com/code/console"),
    ("kimi Moonshot key (.ai)", PlanUsagePages.page(agentKey: "kimi", onPlan: false, claudeCloudProvider: nil, kimiRegion: nil, kimiKeyProviderId: "moonshotai"),
     "https://platform.kimi.ai"),
    ("kimi Moonshot key (.cn)", PlanUsagePages.page(agentKey: "kimi", onPlan: false, claudeCloudProvider: nil, kimiRegion: nil, kimiKeyProviderId: "moonshotai-cn"),
     "https://platform.kimi.com"),
    ("kimi For Coding key, kimi.ai", PlanUsagePages.page(agentKey: "kimi", onPlan: false, claudeCloudProvider: nil, kimiRegion: nil, kimiKeyProviderId: "kimi-code-plan-global"),
     "https://www.kimi.ai/code/console"),
    ("kimi For Coding key, kimi.com", PlanUsagePages.page(agentKey: "kimi", onPlan: false, claudeCloudProvider: nil, kimiRegion: nil, kimiKeyProviderId: "kimi-code-plan-cn"),
     "https://www.kimi.com/code/console"),
]
for (what, url, expected) in pages {
    check("\(what) → \(expected)", url?.absoluteString == expected, url?.absoluteString ?? "nil")
}
check("no page carries a tracking parameter", pages.allSatisfy { $0.1?.query == nil })
check("a claude account through a cloud provider has no Anthropic page to send it to",
      PlanUsagePages.page(agentKey: "claude_code", onPlan: false, claudeCloudProvider: "bedrock", kimiRegion: nil, kimiKeyProviderId: nil) == nil)
// A key claude sends somewhere other than Anthropic's API — a gateway, or
// another vendor's Anthropic-compatible endpoint (`ANTHROPIC_BASE_URL`
// with `ANTHROPIC_AUTH_TOKEN`) — is billed where it was issued, not on
// Anthropic's console.
check("a claude key sent to another host has no Anthropic page",
      PlanUsagePages.page(agentKey: "claude_code", onPlan: false, claudeCloudProvider: nil,
                          claudeBaseURL: "https://api.example.com/anthropic",
                          kimiRegion: nil, kimiKeyProviderId: nil) == nil
      && PlanUsagePages.page(agentKey: "claude_code", onPlan: false, claudeCloudProvider: nil,
                             claudeBaseURL: "not a url", kimiRegion: nil, kimiKeyProviderId: nil) == nil)
check("…while Anthropic's own API, however spelled, keeps Anthropic's console",
      ["https://api.anthropic.com", "https://API.anthropic.com/", "https://api.anthropic.com/v1"].allSatisfy {
          PlanUsagePages.page(agentKey: "claude_code", onPlan: false, claudeCloudProvider: nil,
                              claudeBaseURL: $0, kimiRegion: nil, kimiKeyProviderId: nil)?.absoluteString
              == "https://platform.claude.com/settings/billing"
      })
check("…and a plan's page is claude.ai's whatever the base URL",
      PlanUsagePages.page(agentKey: "claude_code", onPlan: true, claudeCloudProvider: nil,
                          claudeBaseURL: "https://api.example.com/anthropic",
                          kimiRegion: nil, kimiKeyProviderId: nil)?.absoluteString
        == "https://claude.ai/settings/usage")
check("a kimi site kimi did not name is no link — two sites, two accounts, never a guess",
      PlanUsagePages.page(agentKey: "kimi", onPlan: true, claudeCloudProvider: nil, kimiRegion: nil, kimiKeyProviderId: nil) == nil
      && PlanUsagePages.page(agentKey: "kimi", onPlan: true, claudeCloudProvider: nil, kimiRegion: "moon", kimiKeyProviderId: nil) == nil)
check("…nor a key from a provider kimi's catalog does not list",
      PlanUsagePages.page(agentKey: "kimi", onPlan: false, claudeCloudProvider: nil, kimiRegion: nil, kimiKeyProviderId: "custom") == nil
      && PlanUsagePages.page(agentKey: "kimi", onPlan: false, claudeCloudProvider: nil, kimiRegion: nil, kimiKeyProviderId: nil) == nil)
check("an agent SipAI does not know has no page",
      PlanUsagePages.page(agentKey: "other", onPlan: true, claudeCloudProvider: nil, kimiRegion: "global", kimiKeyProviderId: nil) == nil)
let agentOf: [String: String] = ["claude": "claude_code", "codex": "codex", "kimi": "kimi"]
check("every page opens for its own agent",
      pages.allSatisfy { page in
          guard let url = page.1, let agent = agentOf[String(page.0.prefix { $0 != " " })] else { return false }
          return PlanUsagePages.opensSafely(url, agentKey: agent)
      })
check("…and for no other",
      !PlanUsagePages.opensSafely(URL(string: "https://claude.ai/settings/usage")!, agentKey: "codex")
      && !PlanUsagePages.opensSafely(URL(string: "https://chatgpt.com/settings/usage")!, agentKey: "kimi"))
check("the host check refuses http, a look-alike host, credentials, a port and another scheme",
      !PlanUsagePages.opensSafely(URL(string: "http://claude.ai/settings/usage")!, agentKey: "claude_code")
      && !PlanUsagePages.opensSafely(URL(string: "https://claude.ai.example.com/x")!, agentKey: "claude_code")
      && !PlanUsagePages.opensSafely(URL(string: "https://user:pw@claude.ai/settings/usage")!, agentKey: "claude_code")
      && !PlanUsagePages.opensSafely(URL(string: "https://claude.ai:8443/settings/usage")!, agentKey: "claude_code")
      && !PlanUsagePages.opensSafely(URL(string: "sipai://settings/usage")!, agentKey: "claude_code"))

// MARK: - 5. The file layer

print("5. File layer — is this agent on a plan?")

let noEnv: [String: String] = [:]
check("claude: subscription login → plan (Max)",
      PlanAccountDetector.claudeKind(claudeJSON: Data(claudeJSON.utf8), settings: [], environment: noEnv) == .plan(name: "Max"))
check("claude: ANTHROPIC_API_KEY in the environment overrides the login",
      PlanAccountDetector.claudeKind(claudeJSON: Data(claudeJSON.utf8), settings: [], environment: ["ANTHROPIC_API_KEY": "sk-ant-x"]) == .apiKey)
check("claude: CLAUDE_CODE_USE_BEDROCK=1 overrides; =0 does not",
      PlanAccountDetector.claudeKind(claudeJSON: Data(claudeJSON.utf8), settings: [], environment: ["CLAUDE_CODE_USE_BEDROCK": "1"]) == .apiKey
      && PlanAccountDetector.claudeKind(claudeJSON: Data(claudeJSON.utf8), settings: [], environment: ["CLAUDE_CODE_USE_BEDROCK": "0"]) == .plan(name: "Max"))
check("claude: apiKeyHelper in settings.json overrides",
      PlanAccountDetector.claudeKind(claudeJSON: Data(claudeJSON.utf8), settings: [Data(#"{"apiKeyHelper":"/usr/local/bin/key.sh"}"#.utf8)], environment: noEnv) == .apiKey)
check("claude: env.ANTHROPIC_AUTH_TOKEN in settings overrides",
      PlanAccountDetector.claudeKind(claudeJSON: Data(claudeJSON.utf8), settings: [Data(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"tok"}}"#.utf8)], environment: noEnv) == .apiKey)
check("claude: a proxy-only env block does not",
      PlanAccountDetector.claudeKind(claudeJSON: Data(claudeJSON.utf8), settings: [Data(#"{"env":{"HTTPS_PROXY":"http://x"}}"#.utf8)], environment: noEnv) == .plan(name: "Max"))
check("claude: usage_based billing → API key",
      PlanAccountDetector.claudeKind(claudeJSON: Data(#"{"oauthAccount":{"accountUuid":"u","billingType":"usage_based","organizationType":"claude_enterprise"}}"#.utf8), settings: [], environment: noEnv) == .apiKey)
check("claude: no oauthAccount → signed out",
      PlanAccountDetector.claudeKind(claudeJSON: Data(#"{"numStartups":1}"#.utf8), settings: [], environment: noEnv) == .signedOut)
check("claude: an empty oauthAccount is not a login",
      PlanAccountDetector.claudeKind(claudeJSON: Data(#"{"oauthAccount":{}}"#.utf8), settings: [], environment: noEnv) == .signedOut)
check("claude: no file → unknown", PlanAccountDetector.claudeKind(claudeJSON: nil, settings: [], environment: noEnv) == .unknown)
check("claude: CLAUDE_CODE_OAUTH_TOKEN is a subscription login even with no account on file",
      PlanAccountDetector.claudeKind(claudeJSON: Data(#"{"numStartups":1}"#.utf8), settings: [], environment: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-x"]) == .plan(name: nil)
      && PlanAccountDetector.claudeKind(claudeJSON: nil, settings: [], environment: ["CLAUDE_CODE_OAUTH_TOKEN": "x"]) == .plan(name: nil))
check("claude: an API key still outranks the OAuth token",
      PlanAccountDetector.claudeKind(claudeJSON: Data(claudeJSON.utf8), settings: [], environment: ["CLAUDE_CODE_OAUTH_TOKEN": "x", "ANTHROPIC_API_KEY": "y"]) == .apiKey)
check("claude digest moves when the OAuth token appears",
      PlanAccountDetector.claudeFingerprint(claudeJSON: Data(claudeJSON.utf8), settings: [], environment: ["CLAUDE_CODE_OAUTH_TOKEN": "x"])
      != PlanAccountDetector.claudeFingerprint(claudeJSON: Data(claudeJSON.utf8), settings: [], environment: noEnv))

check("codex: chatgpt tokens → plan",
      PlanAccountDetector.codexKind(authJSON: Data(#"{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"access_token":"a","refresh_token":"r","id_token":"i","account_id":"x"},"last_refresh":"t"}"#.utf8), environment: noEnv) == .plan(name: nil))
check("codex: apikey mode → API key",
      PlanAccountDetector.codexKind(authJSON: Data(#"{"OPENAI_API_KEY":"sk-proj-x","auth_mode":"apikey"}"#.utf8), environment: noEnv) == .apiKey)
check("codex: key only, no mode → API key",
      PlanAccountDetector.codexKind(authJSON: Data(#"{"OPENAI_API_KEY":"sk-proj-x"}"#.utf8), environment: noEnv) == .apiKey)
check("codex: no file → signed out; env key → API key",
      PlanAccountDetector.codexKind(authJSON: nil, environment: noEnv) == .signedOut
      && PlanAccountDetector.codexKind(authJSON: nil, environment: ["OPENAI_API_KEY": "sk-x"]) == .apiKey)
check("codex: unreadable file → unknown", PlanAccountDetector.codexKind(authJSON: Data("nope".utf8), environment: noEnv) == .unknown)

let kimiLoginConfig = """
default_model = "kimi-code/k3"

[providers."managed:kimi-code"]
type = "kimi"
base_url = "https://api.kimi.com/coding/v1"
api_key = ""

[providers."managed:kimi-code".oauth]
storage = "file"
key = "oauth/kimi-code"
oauth_host = "https://auth.kimi.com"

[models."kimi-code/k3"]
provider = "managed:kimi-code"
model = "k3"
"""
let kimiInlineConfig = """
[providers."managed:kimi-code"]
type = "kimi"
base_url = "https://api.kimi.com/coding/v1"
api_key = ""
oauth = { storage = "file", key = "oauth/kimi-code-env-abc", oauth_host = "https://auth.kimi.com" }
"""
let kimiMoonshotConfig = """
default_model = "moonshot-ai/kimi-k3"

[providers.moonshot-ai]
base_url = "https://api.moonshot.ai/v1"
type = "kimi"
api_key = "sk-moonshot-secret" # region-bound

[models."moonshot-ai/kimi-k3"]
provider = "moonshot-ai"
"""
let kimiForCodingConfig = """
[providers.kimi-for-coding]
base_url = "https://api.kimi.com/coding/v1"
type = "kimi"
api_key = "sk-kimi-plan-key"
"""
check("kimi: oauth key read from the sub-table", PlanAccountDetector.kimiOAuthKey(configText: kimiLoginConfig) == "oauth/kimi-code")
check("kimi: oauth key read from an inline table", PlanAccountDetector.kimiOAuthKey(configText: kimiInlineConfig) == "oauth/kimi-code-env-abc")
check("kimi: managed provider without an oauth key → the default key",
      PlanAccountDetector.kimiOAuthKey(configText: "[providers.\"managed:kimi-code\"]\ntype = \"kimi\"\n") == "oauth/kimi-code")
check("kimi: no managed provider → nil", PlanAccountDetector.kimiOAuthKey(configText: kimiMoonshotConfig) == nil)
check("kimi: token storage names",
      PlanAccountDetector.kimiTokenStorageName(oauthKey: "oauth/kimi-code") == "kimi-code"
      && PlanAccountDetector.kimiTokenStorageName(oauthKey: "kimi-code") == "kimi-code"
      && PlanAccountDetector.kimiTokenStorageName(oauthKey: "oauth/kimi-code-env-abc") == "kimi-code-env-abc"
      && PlanAccountDetector.kimiTokenStorageName(oauthKey: "bare") == "bare"
      && PlanAccountDetector.kimiTokenStorageName(oauthKey: "../evil") == nil)
check("kimi: managed provider + token file → plan",
      PlanAccountDetector.kimiKind(configText: kimiLoginConfig, tokenFileExists: { $0 == "kimi-code" }) == .plan(name: nil))
check("kimi: managed provider, token file missing → signed out",
      PlanAccountDetector.kimiKind(configText: kimiLoginConfig, tokenFileExists: { _ in false }) == .signedOut)
check("kimi: Moonshot API key → API key",
      PlanAccountDetector.kimiKind(configText: kimiMoonshotConfig, tokenFileExists: { _ in true }) == .apiKey)
check("kimi: kimi-for-coding API key is an API key, not the plan",
      PlanAccountDetector.kimiKind(configText: kimiForCodingConfig, tokenFileExists: { _ in true }) == .apiKey)
check("kimi: empty config → signed out; no config → signed out",
      PlanAccountDetector.kimiKind(configText: "# seeded\n", tokenFileExists: { _ in true }) == .signedOut
      && PlanAccountDetector.kimiKind(configText: nil, tokenFileExists: { _ in true }) == .signedOut)
// `provider remove` of the last provider and the server's logout each
// leave three newlines (measured, 2.1.1): the sign-out a terminal made.
// Read as "being rewritten" it carried the old verdict and the kimi
// stayed listed until relaunch; the mid-rewrite race is the second-
// reading rule's (`UsageMonitor.pendingSignOut`), not this verdict's.
check("kimi: a config holding only newlines is a sign-out, not an unknown — with a digest of its own",
      PlanAccountDetector.kimiKind(configText: "\n\n\n", tokenFileExists: { _ in true }) == .signedOut
      && PlanAccountDetector.kimiKind(configText: "", tokenFileExists: { _ in true }) == .signedOut
      && PlanAccountDetector.kimiFingerprint(configText: "\n\n\n", tokenFileExists: { _ in true })
          != PlanAccountDetector.kimiFingerprint(configText: kimiMoonshotConfig, tokenFileExists: { _ in true }))

// The live wrappers over a throwaway KIMI_CODE_HOME: the token file is
// found where kimi's storage would put it.
let kimiHome = tmp.appendingPathComponent("kimi-home", isDirectory: true)
try! FileManager.default.createDirectory(at: kimiHome.appendingPathComponent("credentials"), withIntermediateDirectories: true)
try! kimiLoginConfig.write(to: kimiHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
setenv("KIMI_CODE_HOME", kimiHome.path, 1)
check("kimi live wrapper: no token file → signed out", PlanAccountDetector.fileVerdict(agentKey: "kimi") == .signedOut)
let fpBefore = PlanAccountDetector.fingerprint(agentKey: "kimi")
try! "{\"access_token\":\"x\"}".write(to: kimiHome.appendingPathComponent("credentials/kimi-code.json"), atomically: true, encoding: .utf8)
check("kimi live wrapper: token file present → plan", PlanAccountDetector.fileVerdict(agentKey: "kimi") == .plan(name: nil))
check("the fingerprint moves when the token file appears", PlanAccountDetector.fingerprint(agentKey: "kimi") != fpBefore)
let fpToken = PlanAccountDetector.fingerprint(agentKey: "kimi")
try! (kimiLoginConfig + "\n# a comment appended\n").write(to: kimiHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
check("…but not when the file changes without the facts changing", PlanAccountDetector.fingerprint(agentKey: "kimi") == fpToken)
unsetenv("KIMI_CODE_HOME")

// The digest is over the account's FACTS, not the file's bytes: claude
// rewrites ~/.claude.json on every probe, and that must not unseat
// the verdict the probe just produced.
let fpA = PlanAccountDetector.claudeFingerprint(claudeJSON: Data(claudeJSON.utf8), settings: [], environment: noEnv)
let rewritten = claudeJSON.replacingOccurrences(of: "\"fetchedAtMs\": 1789285766280", with: "\"fetchedAtMs\": 1789299999999")
    .replacingOccurrences(of: "\"numStartups\": 3", with: "\"numStartups\": 4")
let fpB = PlanAccountDetector.claudeFingerprint(claudeJSON: Data(rewritten.utf8), settings: [], environment: noEnv)
check("claude digest survives a cache rewrite", fpA == fpB)
check("claude digest moves on a logout", PlanAccountDetector.claudeFingerprint(claudeJSON: Data("{\"numStartups\":4}".utf8), settings: [], environment: noEnv) != fpA)
check("claude digest moves on an API source", PlanAccountDetector.claudeFingerprint(claudeJSON: Data(claudeJSON.utf8), settings: [], environment: ["ANTHROPIC_API_KEY": "x"]) != fpA)
check("claude digest carries no e-mail", !fpA.contains("example.com"))
let codexAuth = #"{"auth_mode":"chatgpt","tokens":{"access_token":"a1","refresh_token":"r1","id_token":"i1","account_id":"acct"},"last_refresh":"2026-09-12T04:59:24Z"}"#
let codexRefreshed = #"{"auth_mode":"chatgpt","tokens":{"access_token":"a2","refresh_token":"r2","id_token":"i2","account_id":"acct"},"last_refresh":"2026-09-13T04:59:24Z"}"#
check("codex digest survives a token refresh",
      PlanAccountDetector.codexFingerprint(authJSON: Data(codexAuth.utf8), environment: noEnv)
      == PlanAccountDetector.codexFingerprint(authJSON: Data(codexRefreshed.utf8), environment: noEnv))
check("codex digest moves on a logout",
      PlanAccountDetector.codexFingerprint(authJSON: nil, environment: noEnv)
      != PlanAccountDetector.codexFingerprint(authJSON: Data(codexAuth.utf8), environment: noEnv))

// Effective verdict: the probe wins while the files are unchanged.
let probe = PlanAccountVerdictStore.Entry(kind: .plan(name: "Prolite"), fingerprint: "fp1")
check("probe names the tier over a nameless file verdict",
      PlanAccountDetector.effective(file: .plan(name: nil), probe: probe, fingerprint: "fp1") == .plan(name: "Prolite"))
check("a stale fingerprint hands the verdict back to the file layer",
      PlanAccountDetector.effective(file: .signedOut, probe: probe, fingerprint: "fp2") == .signedOut)
check("a probe that found an API key overrides a file-layer plan over the same files",
      PlanAccountDetector.effective(file: .plan(name: "Max"), probe: PlanAccountVerdictStore.Entry(kind: .apiKey, fingerprint: "fp1"), fingerprint: "fp1") == .apiKey)
check("an unknown probe never overrides",
      PlanAccountDetector.effective(file: .plan(name: "Max"), probe: PlanAccountVerdictStore.Entry(kind: .unknown, fingerprint: "fp1"), fingerprint: "fp1") == .plan(name: "Max"))
let stored = PlanAccountVerdictStore.decode(PlanAccountVerdictStore.encode(["codex": probe, "claude_code": PlanAccountVerdictStore.Entry(kind: .apiKey, fingerprint: "f")]))
check("verdicts round-trip through their storage spelling",
      stored["codex"] == probe && stored["claude_code"]?.kind == .apiKey)
check("storage spellings", PlanAccountKind(storageValue: "plan:Max") == .plan(name: "Max")
      && PlanAccountKind(storageValue: "plan") == .plan(name: nil)
      && PlanAccountKind(storageValue: "plan:") == .plan(name: nil)
      && PlanAccountKind(storageValue: "bogus") == nil)

// MARK: - 6. Wiring

print("6. Wiring — the coin, the scrim, the clock, the rules")

let contentView = codeOnly(source("SipAI/Views/ContentView.swift"))
let popover = codeOnly(source("SipAI/Views/UsagePopover.swift"))
let model = codeOnly(source("SipAI/Models/PlanUsage.swift"))
let manager = codeOnly(source("SipAI/Models/AgentManager.swift"))
let updatesSource = codeOnly(source("SipAI/Models/AgentCLIUpdates.swift"))
let reset = codeOnly(source("SipAI/Models/FactoryReset.swift"))
let settings = source("SipAI/Views/Settings/SettingsView.swift")

check("the coin renders only on a plan account (or while its window is open)",
      contentView.contains("if usage.showsIcon || showingUsage {") && contentView.contains("Image(systemName: \"t.circle\")"))
check("the coin draws a T, for tokens — never a currency sign (its $ reads as an S at toolbar size)",
      contentView.contains("Image(systemName: \"t.circle\")") && !contentView.contains("dollarsign"))
// A bare letter names nothing to VoiceOver, so the button carries an
// explicit label — the tooltip's own string, from one property.
check("the coin's accessibility label is its tooltip, from one string",
      contentView.contains(".help(planUsageTitle)") && contentView.contains(".accessibilityLabel(planUsageTitle)")
      && contentView.contains("private var planUsageTitle: String {")
      && contentView.contains("String(localized: \"Plan usage\","))
check("the window is placed under the MEASURED coin, not a constant",
      contentView.contains("preference(\n                            key: UsageCoinLeadingKey.self")
      && contentView.contains(".padding(.leading, usageCoinLeading)")
      && contentView.contains(".coordinateSpace(name: Self.mainLayoutSpace)"))
check("a card dims its figures only, never its title or its failure line",
      popover.contains("figures.opacity(card.stale ? 0.55 : 1)") && !popover.contains(".opacity(card.stale ? 0.55 : 1)\n    }"))
check("an empty card mid-read shows a spinner", popover.contains("} else if refreshing, card.failure == nil {"))
// The usage read asks kimi's own server for the account in the same visit;
// a name only the Guide's probe knew would be dropped by the next read.
check("a Kimi card names the membership as kimi's own server does, read with the usage and kept by it",
      popover.contains("localized: \"Membership · \\(name)\",")
      && model.contains("verdict = .plan(name: planName ?? accounts[agent.key]?.planName)")
      && model.contains("path: userInfoPath")
      && model.contains("KimiMembership.levelName(userInfoBody: body)"))
check("the window sits under a click-anywhere-else scrim",
      contentView.contains("UsagePopover(isPresented: $showingUsage)")
      && contentView.range(of: #"onTapGesture \{ showingUsage = false \}"#, options: .regularExpression) != nil)
check("one dropdown at a time (the search palette, this window and the agent session view window)",
      contentView.contains("if showingSearch {\n                        showingUsage = false\n                        showingSessionView = false\n                    }")
      && contentView.contains("if showingUsage {\n                            showingSearch = false\n                            showingSessionView = false\n                        }")
      && contentView.contains("if showingSessionView {\n                            showingSearch = false\n                            showingUsage = false\n                        }"))
check("the footer's clock is a leaf TimelineView on the stamp",
      popover.contains("TimelineView(.periodic(from: updatedAt, by: 60))"))
check("no Timer in the window or the model", !popover.contains("Timer") && !model.contains("Timer."))
check("Escape closes the window", popover.contains(".onKeyPress(.escape)"))
check("the API sentence is in the footer", popover.contains("For API usage, check your provider's developer platform."))
check("no keychain, no credentials read, no vendor endpoint in the app",
      !model.contains("SecItem") && !popover.contains("SecItem")
      && !model.contains("api/oauth/usage") && !model.contains("coding/v1/usages")
      && !model.contains("Data(contentsOf: kimiTokenFile"))
check("kimi's server is asked over its own route and told to stop",
      model.contains("/api/v1/oauth/usage?provider=managed:kimi-code") && model.contains("/api/v1/shutdown"))
check("kimi's server stdout is a PTY", model.contains("openpty(&masterFD, &slaveFD"))
check("the loopback request runs with proxies off", model.contains("connectionProxyDictionary = [:]"))
check("the claude probe names its transcript and removes it",
      model.contains("\"--session-id\", sessionId") && model.contains("removeTranscript(sessionId: sessionId)"))
check("the claude probe skips MCP servers but not setting sources",
      model.contains("--strict-mcp-config") && !model.contains("--setting-sources"))
check("the detection tick feeds the file layer", manager.contains("UsageMonitor.shared.refreshAccounts(installed: installed)") && manager.contains("UsageMonitor.shared.readAccountsNow(installed: installed)"))
check("a CLI update drops the probe verdict", updatesSource.contains("UsageMonitor.shared.noteBinaryChanged(agentKey: key)"))
// A codex that answered nothing at all may be one that cannot start —
// npm's install without the tool's program throws on every start. The
// card then says why in codex's own words, read off the --version it
// stops on, never "did not answer" over a tool that said what is wrong.
check("the Codex card asks a codex that answered nothing whether it starts, and shows what it said",
      model.contains("if !outcome.available {")
      && model.contains("await AgentCLIProbe.installedVersion(agentKey: key,")
      && model.contains("card.failure = read.startFailure.flatMap(CLIStartFailure.reason(in:)) ?? Self.didNotAnswer"))
check("Claude's card, when claude gave no result, shows the line it stopped with",
      model.contains("errorText: extracted.text ?? CLIStartFailure.reason(in: result.output)"))
check("the verdict key is wiped by a factory reset",
      reset.contains("UsageMonitor.verdictsDefaultsKey") && reset.contains("UsageMonitor.shared.forgetVerdicts()"))
check("the probe runner takes a working directory", updatesSource.contains("currentDirectory: String? = nil"))
check("FAQ 4 explains the window", settings.contains("Yes — click the T icon beside the search icon in the toolbar."))
check("FAQ 3 points at it", settings.contains("Plan limits (the 5-hour and weekly windows of a subscription) are a different thing"))
check("no sentence in the model names an agent outright",
      !model.contains("localized: \"Codex") && !model.contains("localized: \"Kimi") && !model.contains("localized: \"Claude"))

let catalog = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: sourceRoot + "/SipAI/Resources/Localizable.xcstrings")))) as? [String: Any]
let strings = catalog?["strings"] as? [String: Any] ?? [:]
func chineseValue(_ key: String) -> String? {
    guard let entry = strings[key] as? [String: Any],
          let loc = entry["localizations"] as? [String: Any],
          let zh = loc["zh-Hans"] as? [String: Any],
          let unit = zh["stringUnit"] as? [String: Any] else { return nil }
    return unit["value"] as? String
}
func hasChinese(_ key: String) -> Bool { !(chineseValue(key) ?? "").isEmpty }
let newKeys = ["Plan usage", "For API usage, check your provider's developer platform.", "Updated just now",
               "Updated %@", "Current session", "Current week (all models)", "Current week (%@)", "Weekly",
               "%lld-hour", "%@ plan", "Subscription", "ChatGPT %@", "Membership", "Membership · %@", "%@ of %@", "resets %@",
               "Usage credits: %@ / %@ spent this month", "Usage credits: off", "Usage credits: off — %@",
               "%lld free limit resets available",
               "No agent on this Mac is signed in to a plan.", "The command-line tool did not answer.",
               "5h limit", "Weekly limit", "Monthly limit", "kimi %lld%% · code %lld%%",
               "Extra Usage: used this month %@ · monthly limit %@ · balance %@",
               "Extra Usage: used this month %@ · no monthly limit · balance %@",
               "No usage data available."]
check("every new string carries a zh-Hans value", newKeys.allSatisfy(hasChinese),
      newKeys.filter { !hasChinese($0) }.joined(separator: ", "))
// Kimi's own /usage shows a booster wallet as what was used this month,
// the monthly limit and the balance; "x of y left" was SipAI's sum.
check("the wallet line kimi never shows is gone from the catalog",
      strings["Extra usage: %@ of %@ left"] == nil)
check("kimi's row names reach the window through its one label rule, translated",
      popover.contains("String(localized: \"5h limit\"") && popover.contains("String(localized: \"Weekly limit\"")
      && popover.contains("String(localized: \"Monthly limit\"") && popover.contains("knownLabel(label)"))
check("the monthly split is drawn under its own row, in the row's grid",
      popover.contains("if let split = row.split {") && popover.contains(".gridCellColumns(3)"))
check("an empty kimi answer is drawn as kimi's sentence", popover.contains("case .noUsageData:"))
check("the old 'Not yet' FAQ answer is gone from the catalog",
      !strings.keys.contains { $0.hasPrefix("Not yet. For example, Claude's plan percentages") })
// Spend against a monthly LIMIT printed beside "off" reads as a balance
// with money left on an account whose credits are used up.
check("the credits line that read as a balance is gone from the catalog",
      strings["Usage credits: %@ of %@ · %@"] == nil)
// The answer is one line of a multi-line literal, so that line IS its key.
let faq4Answer = settings.components(separatedBy: "\n").first { $0.hasPrefix("Yes — click the ") } ?? ""
// The answer names the Codex label, so its catalog key spells the
// placeholder where the source interpolates.
let faq4Key = faq4Answer.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "%@", options: .regularExpression)
check("FAQ 4's answer is a catalog key in both languages, naming the T icon and no coin",
      faq4Key.hasPrefix("Yes — click the T icon") && hasChinese(faq4Key)
      && chineseValue(faq4Key)?.contains("旁边的 T 图标") == true
      && !strings.keys.contains { $0.hasPrefix("Yes — click the coin icon") })


// MARK: - 6b. Settings → Usage, and the window's ways into it

print("6b. Settings → Usage — the section, the window's links, the reset")

let pane = codeOnly(source("SipAI/Views/Settings/UsagePane.swift"))
let navigationSource = codeOnly(source("SipAI/Views/Settings/SettingsNavigation.swift"))
let project = source("SipAI.xcodeproj/project.pbxproj")
check("Usage is a section of its own, between Language and Updates (the user's choice)",
      settings.contains("case chat, agents, skills, files, display, labels, language, usage, updates, privacy, help")
      && settings.contains("case .usage:     return \"Usage\"") && settings.contains("case .usage:     UsagePane()"))
check("…drawn with the toolbar's T", navigationSource.contains("case .usage:    return \"t.circle\""))
check("…in a file of its own that the app target builds",
      !pane.isEmpty && project.components(separatedBy: "UsagePane.swift").count - 1 >= 4)
check("the window's header carries Learn more, which closes the window and opens the section",
      popover.contains("Text(\"Plan usage\"") && popover.contains("\"Learn more\"")
      && popover.contains("private func openUsageSection() {")
      && popover.contains("isPresented = false")
      && popover.contains("userInfo: [SettingsView.Tab.userInfoKey: SettingsView.Tab.usage.rawValue]"))
check("…and the reset line's Use it takes the same road",
      popover.contains("\"Use it\"") && popover.contains("onUseResets: openUsageSection"))
check("the section asks again only when the figures are older than a minute — Learn more from a fresh window starts nothing",
      pane.contains("monitor.refreshIfStale()") && model.contains("static let sectionReuse: TimeInterval = 60")
      && model.contains("func refreshIfStale(maxAge: TimeInterval = UsageMonitor.sectionReuse)"))
check("…and reads codex's history for itself, never the window — only of a codex known to have the request",
      pane.contains("monitor.loadCodexHistory(installedCodex: updates.installed[\"codex\"])")
      && !popover.contains("loadCodexHistory")
      && model.contains("CodexUsageHistory.offered(installedCodex: installedCodex)"))
check("every page opens through the one host check",
      pane.contains("PlanUsagePages.opensSafely(") && pane.contains("NSWorkspace.shared.open(")
      && !popover.contains("NSWorkspace.shared.open("))
check("a reset is used only from codex's own confirmation, Yes, use reset",
      pane.contains("Text(\"Use this reset?\"") && pane.contains("Text(\"Yes, use reset\"")
      && pane.contains("Text(\"No, go back\"")
      && pane.components(separatedBy: "monitor.useReset(").count == 2)
check("…the button only for a codex known to have the request",
      pane.contains("CodexResetConsume.offered(installedCodex:"))
check("the monitor keeps the attempt — one at a time, a failed one's key for its retry — and reads the figures again after",
      model.contains("func useReset(creditId: String?)") && model.contains("resetAttempts.begin(creditId: creditId)")
      && model.contains("resetAttempts.finish(outcome)") && model.contains("if outcome.settles { self.refreshAfterReset() }") && model.contains("if self.refreshAgain {"))
check("claude's report and its “What's contributing” reach the card",
      model.contains("ClaudeUsageText.merging(report.rows, report: outcome.report)")
      && model.contains("card.contributing = ClaudeUsageText.contributing(in: text)"))
check("kimi's site reaches the card", model.contains("card.kimiRegion = region"))
check("the codex reset note is codex's detail, not a note", !model.contains("case freeResets"))
check("the section's type and gaps are the Settings pages' own, and the rhythm the tier's",
      pane.contains(".sipFont(14, weight: .semibold)") && pane.contains(".sipFont(12)")
      && pane.contains("Divider().padding(.vertical, 4)")
      && pane.contains(".lineSpacing(SipFont.lineSpacing(12, fontScale: fontScale, lineSpacingFactor: lineSpacingFactor))")
      && pane.contains("SipFont.gapScale(12, fontScale: fontScale, lineSpacingFactor: lineSpacingFactor)"))
// The links are the app's shared link button, whose pointing hand is
// SwiftUI's own link pointer (Verification/LinkPointers pins it).
check("every link and icon button in the section and the window answers the pointer",
      pane.contains("LinkButton(") && popover.contains("LinkButton(title:")
      && !popover.contains("NSCursor.pointingHand") && pane.contains("UsageRefreshButton(")
      && popover.contains("struct UsageRefreshButton: View {"))
check("no clock in the section", !pane.contains("Timer") && !pane.contains("TimelineView"))
check("the section reads where claude sends a key's requests, and the page rule is given it",
      pane.contains("baseURL: env.baseURL") && pane.contains("claudeBaseURL: claude.baseURL"))
check("codex's answer is marked by what it means, never by whether its attempt settled",
      pane.contains("outcome.tone") && !pane.contains("outcome.settles ?"))
check("the newer-codex line is said only for a codex known to be older",
      pane.contains("CodexResetConsume.needsNewerCodex(installedCodex:"))
// Right after a reset is used, the list still holds it until the figures
// are read again; a "Use reset…" clicked then would send a second
// request — for a reset codex only counted, one its backend picks.
check("no reset is offered from a list that is being read again",
      pane.contains(".disabled(isRunning || monitor.refreshing)"))
// Every system button in the section takes the Settings pages' type, as
// the Agent Initialization page's do: the pane steps the control size
// with the tier, but a label left at the system font does not grow with
// the text around it.
do {
    let lines = pane.components(separatedBy: "\n")
    var unsized: [String] = []
    for (i, line) in lines.enumerated() {
        let opening = line.trimmingCharacters(in: .whitespaces)
        guard opening.hasPrefix("Button(") || opening.hasPrefix("Button {") else { continue }
        // The button's own closing brace, then the modifiers chained on it.
        var depth = 0, seen = false, end = i
        for j in i..<lines.count {
            for ch in lines[j] {
                if ch == "{" { depth += 1; seen = true } else if ch == "}" { depth -= 1 }
            }
            if seen && depth <= 0 { end = j; break }
        }
        var modifiers: [String] = []
        var j = end + 1
        while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).hasPrefix(".") {
            modifiers.append(lines[j].trimmingCharacters(in: .whitespaces))
            j += 1
        }
        if !modifiers.contains(where: { $0.hasPrefix(".sipFont(") }) { unsized.append(opening) }
    }
    check("every button in the section takes the tier's type", unsized.isEmpty, unsized.joined(separator: " | "))
}
// The card's rows sit in the page's prose rhythm: the page sets the
// tier's line spacing, which a wrapped label takes, so a fixed gap
// between rows would put a label's own second line farther away than
// the next row at the larger tiers.
check("in Settings the card's gaps follow the tier's line pitch, as the page's own do",
      popover.contains("SipFont.gapScale(textSize, fontScale: fontScale, lineSpacingFactor: lineSpacingFactor)")
      && popover.contains("VStack(alignment: .leading, spacing: vGap(6))")
      && popover.contains("verticalSpacing: vGap(5)"))
check("no sentence in the section names an agent outright",
      !pane.contains("localized: \"Codex") && !pane.contains("localized: \"Kimi") && !pane.contains("localized: \"Claude")
      && !pane.contains("Text(\"Codex") && !pane.contains("Text(\"Kimi") && !pane.contains("Text(\"Claude"))
// FAQ 4's answer is a String(localized:) with the Codex label in it, so
// its catalog key spells the placeholder.
check("FAQ 4 sends the reader to Settings → Usage, in both languages",
      faq4Key.contains("Settings → Usage") && hasChinese(faq4Key) && chineseValue(faq4Key)?.contains("设置 → 用量") == true)
// Moonshot: "New plans with Kimi Code access (Plus and higher) have a rolling
// 5-hour usage limit and no weekly limit. Legacy plans retain both."
check("…and gives Kimi Code's limits as Moonshot sets them: 5-hour and monthly, a weekly one on older plans only",
      faq4Key.contains("the 5-hour and monthly limits for %@, plus a weekly one on older plans")
      && !faq4Key.contains("the 5-hour, weekly and monthly limits for")
      && chineseValue(faq4Key)?.contains("较早的套餐还有每周限额") == true)
// A key billed through a cloud provider, sent to another host, or from a
// provider kimi's catalog does not list has no page to link to.
check("…and promises no page for every API key, only where each is billed",
      !faq4Key.contains("links to each provider's page")
      && faq4Key.contains("Settings → Usage says where each one is billed instead.")
      && chineseValue(faq4Key)?.contains("说明每个智能体在哪里计费") == true)

let sectionKeys = ["Usage", "Learn more", "Use it",
                   "What each agent's plan reports, asked of the agent's own tool on this Mac. No tokens are spent.",
                   "Open usage on %@", "An API key has no plan limits to show here: it is billed per token, and its usage and cost are on the provider's page.",
                   "Billed through your cloud provider. Its console shows the usage and cost.",
                   "An API key has no plan limits to show here: it is billed per token by the platform that issued it.",
                   "Credits: %@", "Credits: unlimited", "Workspace spend cap",
                   "You've hit your usage limit.", "Your workspace is out of credits. Add credits to continue.",
                   "Your workspace is out of credits. Ask your workspace owner to refill in order to continue.",
                   "You hit your spend cap set in your workspace. Increase your spend cap to continue.",
                   "You hit your spend cap set by the owner of your workspace. Ask an owner to increase your spend cap to continue.",
                   "Usage limit resets", "Usage limit reset", "Expires %@", "Use reset…", "Use this reset?", "Yes, use reset",
                   "No, go back", "Resetting your usage...", "Usage reset.", "Your usage does not need a reset right now.",
                   "No usage limit resets are available.",
                   "That reset is no longer available. Refresh to see your current resets.",
                   "Couldn't reset usage. Please try again.", "Update %@ to use a reset here.",
                   "Token activity", "Last 12 months", "Lifetime tokens", "Peak tokens", "Longest chat",
                   "Current streak", "Longest streak", "Less", "More", "%lld tokens", "1 token",
                   "Token activity history unavailable",
                   "%lld days", "1 day",
                   "Chats are billed per token to your API keys. Each provider's dashboard shows their usage and cost."]
check("every new string of the section and the window carries a zh-Hans value", sectionKeys.allSatisfy(hasChinese),
      sectionKeys.filter { !hasChinese($0) }.joined(separator: " | "))
check("the strings the thirty-day chart said are gone with it",
      ["Token activity · last 30 days", "Lifetime tokens: %@", "Current streak: %@", "Longest streak: %@"]
        .allSatisfy { strings[$0] == nil })

// Claude's block is a table of claude's words — no bars, no tips — and
// the limit rows above it keep their bars.
check("claude's block is laid out from what claude printed, its text whole where its shape is not read",
      pane.contains("ClaudeContributingView(text: text)") && pane.contains("ClaudeContributing.parse(text)")
      && pane.contains("Text(verbatim: text)\n                .font(.system(size: SipFont.scaled(11, fontScale), design: .monospaced))"))
check("…a table, with no bar in it",
      pane.contains("private func table(_ periods: [ClaudeContributing.Period])") && !pane.contains("UsageBar("))
check("the limit rows above it keep their bars",
      popover.contains("UsageBar(fraction: row.fraction, severity: row.severity)"))
// Codex's history is codex's overview: its five figures in its order,
// then the year of squares.
do {
    let order = ["\"Lifetime tokens\"", "\"Peak tokens\"", "\"Longest chat\"", "\"Current streak\"", "\"Longest streak\""]
        .map { pane.range(of: $0)?.lowerBound }
    check("codex's five figures, in codex's order, under codex's names",
          order.allSatisfy { $0 != nil } && zip(order, order.dropFirst()).allSatisfy { $0! < $1! })
}
check("…\"—\" for a figure codex does not state, as codex shows it",
      pane.contains("?? \"—\""))
check("the year of squares replaces the thirty days",
      pane.contains("TokenActivityCalendar(model: CodexActivityCalendar.make(history, today: Date()))")
      && !pane.contains("lastDays(") && !model.contains("func lastDays(") && !pane.contains("TokenActivityChart"))
check("…its steps are codex's own, of the app's accent",
      pane.contains("SipDesign.blue.opacity(0.22)") && pane.contains("SipDesign.blue.opacity(0.42)")
      && pane.contains("SipDesign.blue.opacity(0.68)") && pane.contains("colorScheme == .dark ? 0.14 : 0.18"))
check("pointing at a square says its tokens exactly, at once, in the app's own bubble — never a late system tooltip",
      pane.contains(".onContinuousHover(coordinateSpace: .local)")
      && pane.contains("CodexActivityCalendar.tokensText($0.tokens)")
      && pane.contains("CodexActivityCalendar.dayText($0.date, calendar: calendar)")
      && !pane.contains(".help("))
// An overlay placed by its alignment guides inside an `if` is drawn at
// the corner, its guides ignored (measured): the bubble is always there
// and only shown over a square.
check("…the bubble is never inside an if, or it would sit in the corner",
      pane.contains("bubble(day)\n                .opacity(day == nil ? 0 : 1)\n                .alignmentGuide(.leading)"))
check("…drawn in one Canvas, its height taken from its width in one layout pass",
      pane.contains("Canvas { context, size in") && pane.contains("private struct WidthDrivenHeight: Layout {"))
// The squares, the months, the weekdays and the bubble's day all come
// from the calendar the year was laid out in — codex's days, in UTC —
// never a second calendar of the view's own.
check("…its names and days in the calendar the year was laid out in",
      pane.contains("private var calendar: Calendar { model.calendar }")
      && !pane.contains("var calendar: Calendar = .current"))
// Codex's terminal says "Token activity history unavailable" when codex
// sends no days at all; a year of empty squares would say none were used.
check("…and where codex sends no days, codex's sentence instead of a year with none",
      pane.contains("Text(\"Token activity history unavailable\"") && pane.contains("history.reportsDays"))

// MARK: - 7. Live probes

if ProcessInfo.processInfo.environment["SIPAI_USAGE_LIVE"] == "1" {
    print("7. Live — the three real probes (token-free)")
    let scratch = PlanUsageScratch.directory
    let group = DispatchGroup()
    group.enter()
    Task {
        defer { group.leave() }
        if let claude = AgentManager.binaryPath(for: "claude_code") {
            let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            let before = Set((try? FileManager.default.subpathsOfDirectory(atPath: projects.path)) ?? [])
            let outcome = await ClaudeUsageProbe.run(binary: claude, scratchDirectory: scratch)
            let after = Set((try? FileManager.default.subpathsOfDirectory(atPath: projects.path)) ?? [])
            let leftover = after.subtracting(before).filter { $0.hasSuffix(".jsonl") }
            check("claude answered", outcome.text != nil, outcome.errorText ?? "")
            if let text = outcome.text {
                let report = ClaudeUsageText.parse(text)
                check("claude's answer has a shape", report.kind != .unknown, text.prefix(80).description)
                if report.kind == .plan {
                    check("claude's plan rows parsed", !report.rows.isEmpty)
                    // The structured report is undocumented: this is the
                    // tripwire for the day claude stops sending it.
                    check("claude still sends its structured usage report beside the text",
                          !(outcome.report?.limits.isEmpty ?? true))
                    check("…and it is the text's rows, so the dates and grades are laid on",
                          ClaudeUsageText.merging(report.rows, report: outcome.report).contains { $0.resetDate != nil })
                    // The page lays the block out as a table only while it
                    // is in the shape claude prints today; this says when
                    // claude moves it and the page falls back to the text.
                    if let block = ClaudeUsageText.contributing(in: text) {
                        check("claude's “What's contributing” block is still in the shape the table reads",
                              ClaudeContributing.parse(block) != nil, block.prefix(160).description)
                    }
                }
            }
            check("the probe's transcript was removed", leftover.isEmpty, leftover.joined(separator: ", "))
        } else {
            print("  skip claude: not installed")
        }
        if let codex = AgentManager.binaryPath(for: "codex") {
            let outcome = await CodexUsageProbe.run(binary: codex)
            check("codex answered account/read", outcome.available && outcome.account != nil)
            let report = CodexUsageAnswer.parse(account: outcome.account, rateLimits: outcome.rateLimits)
            check("codex account kind decided", report.kind != .unknown, "\(report.kind)")
            if report.kind.isPlan {
                check("codex plan rows parsed", !report.rows.isEmpty || report.failure != nil, report.failure ?? "")
                let history = await CodexAppServerCall.run(binary: codex, request: CodexUsageProbe.historyRequest)
                check("codex answered its history, in the shape read", CodexUsageHistory.parse(history) != nil,
                      String(describing: history).prefix(160).description)
                // A figure codex renamed would read as "—" for good.
                let summary = ((history?["result"] as? [String: Any])?["summary"] as? [String: Any]) ?? [:]
                let figureKeys = ["lifetimeTokens", "peakDailyTokens", "longestRunningTurnSec",
                                  "currentStreakDays", "longestStreakDays"]
                check("…under the five names the page's figures read",
                      figureKeys.allSatisfy { summary.keys.contains($0) },
                      summary.keys.sorted().joined(separator: ", "))
            }
            // Codex's own protocol, generated by the installed binary under
            // a throwaway home: the reset request, its four outcomes and
            // every field the section reads. A rename turns a reset into a
            // request codex refuses, or a figure into nothing, silently.
            // Nothing is sent to codex's backend, and no reset is used.
            let fm = FileManager.default
            let tsDir = fm.temporaryDirectory.appendingPathComponent("sipai-usage-ts-\(UUID().uuidString)")
            let tsHome = fm.temporaryDirectory.appendingPathComponent("sipai-usage-codexhome-\(UUID().uuidString)")
            try? fm.createDirectory(at: tsHome, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tsDir); try? fm.removeItem(at: tsHome) }
            let generate = Process()
            generate.executableURL = URL(fileURLWithPath: codex)
            generate.arguments = ["app-server", "generate-ts", "--out", tsDir.path]
            var env = ProcessInfo.processInfo.environment
            env["CODEX_HOME"] = tsHome.path
            generate.environment = env
            generate.standardInput = FileHandle.nullDevice
            generate.standardOutput = FileHandle.nullDevice
            generate.standardError = FileHandle.nullDevice
            try? generate.run()
            generate.waitUntilExit()
            var protocolText = ""
            if let files = fm.enumerator(atPath: tsDir.path) {
                for case let file as String in files where file.hasSuffix(".ts") {
                    protocolText += (try? String(contentsOfFile: tsDir.appendingPathComponent(file).path, encoding: .utf8)) ?? ""
                }
            }
            let names = ["\"account/rateLimitResetCredit/consume\"", "idempotencyKey", "creditId",
                         "\"reset\" | \"nothingToReset\" | \"noCredit\" | \"alreadyRedeemed\"",
                         "\"account/usage/read\"", "dailyUsageBuckets", "lifetimeTokens", "currentStreakDays",
                         "longestStreakDays", "rateLimitReachedType", "individualLimit", "remainingPercent",
                         "hasCredits", "availableCount", "\"workspace_member_usage_limit_reached\""]
            let missing = names.filter { !protocolText.contains($0) }
            check("codex's generated protocol still names the reset request, its outcomes and every field read",
                  !protocolText.isEmpty && missing.isEmpty, missing.joined(separator: ", "))
        } else {
            print("  skip codex: not installed")
        }
        if let kimi = AgentManager.binaryPath(for: "kimi") {
            let instances = KimiSessionScanner.home.appendingPathComponent("server/instances")
            let before = (try? FileManager.default.contentsOfDirectory(atPath: instances.path))?.count ?? 0
            let start = Date()
            let outcome = await KimiWebServerCall.fetchUsage(binary: kimi, scratchDirectory: scratch)
            let elapsed = Date().timeIntervalSince(start)
            switch outcome {
            case .answered(let body, _, _):
                let report = KimiUsageAnswer.parse(body: body)
                check("kimi web answered its usage route (\(String(format: "%.1f", elapsed)) s)", report.kind != .malformed,
                      String(decoding: body.prefix(120), as: UTF8.self))
                print("       kimi said: \(report.failure ?? "ok, \(report.rows.count) rows")")
            case .unavailable(let why):
                check("kimi web answered its usage route", false, why)
            }
            let after = (try? FileManager.default.contentsOfDirectory(atPath: instances.path))?.count ?? 0
            check("kimi's server shut down cleanly (no instance record left)", after <= before, "\(before) → \(after)")
            check("the kimi round trip stayed under the start ceiling", elapsed < KimiWebServerCall.startCeiling)
        } else {
            print("  skip kimi: not installed")
        }
    }
    group.wait()

    // The monitor itself, end to end: file layer, then the probe
    // layer, on the MainActor the app runs it on. The run loop is
    // pumped by hand so the actor's jobs execute.
    print("8. Live — the monitor end to end")
    MainActor.assumeIsolated {
        // The monitor persists its verdicts; a headless run must not
        // write the real defaults (an unbundled process would land
        // them in ~/Library/Preferences/<binary name>.plist). A suite
        // named by an ABSOLUTE path keeps its plist in that folder: a
        // named suite in ~/Library/Preferences cannot be cleaned up,
        // since cfprefsd writes the emptied domain back seconds after
        // the process exits (measured).
        let prefsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sipai-usage-window-prefs-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: prefsDir, withIntermediateDirectories: true)
        let suite = prefsDir.appendingPathComponent("verdicts").path
        let scratchDefaults = UserDefaults(suiteName: suite)!
        PlanAccountVerdictStore.defaults = scratchDefaults
        defer {
            scratchDefaults.removePersistentDomain(forName: suite)
            PlanAccountVerdictStore.defaults = .standard
            CFPreferencesAppSynchronize(suite as CFString)
            try? FileManager.default.removeItem(at: prefsDir)
        }
        let monitor = UsageMonitor()
        func pump(until seconds: TimeInterval, _ done: () -> Bool) {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        let installed = AgentManager.registry.filter { AgentManager.binaryPath(for: $0.key) != nil }
        monitor.refreshAccounts(installed: installed)
        pump(until: 10) { monitor.accounts.count == installed.count }
        check("file layer decided every installed agent", monitor.accounts.count == installed.count, "\(monitor.accounts)")
        print("       accounts: \(monitor.accounts)")
        let iconBefore = monitor.showsIcon
        check("icon follows the verdicts", iconBefore == monitor.accounts.values.contains { $0.isPlan })
        monitor.refresh()
        check("refresh sets the running state", monitor.refreshing || !iconBefore)
        pump(until: 90) { !monitor.refreshing }
        check("refresh finished inside 90 s", !monitor.refreshing)
        check("the footer stamp is set once the refresh ends", monitor.updatedAt != nil || !iconBefore)
        for card in monitor.cards {
            print("       card \(card.agentKey): plan=\(card.planName ?? "-") rows=\(card.rows.count) notes=\(card.notes.count) failure=\(card.failure ?? "-") stale=\(card.stale)")
            check("card \(card.agentKey) has figures or a reason", card.hasFigures || card.failure != nil)
            check("card \(card.agentKey) is not left stale", !card.stale)
        }
        check("a second refresh while idle runs again", { monitor.refresh(); return monitor.refreshing || monitor.cards.isEmpty }())
        pump(until: 90) { !monitor.refreshing }
        check("verdicts went to the throwaway suite, not the standard defaults",
              scratchDefaults.dictionary(forKey: UsageMonitor.verdictsDefaultsKey) != nil || monitor.cards.isEmpty)
        check("the standard defaults were never written",
              UserDefaults.standard.dictionary(forKey: UsageMonitor.verdictsDefaultsKey) == nil)
    }
} else {
    print("7. Live — skipped (set SIPAI_USAGE_LIVE=1 to run the three real probes)")
}

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
