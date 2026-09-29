// Headless check of the plan-usage window. See run.sh for scope and
// for what regresses silently.
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
check("free resets note", codexReport.notes == [.freeResets(count: 2)])
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
check("wallet note in cents", kimiOk.notes == [.extraUsage(balanceCents: 1250, totalCents: 2000, currency: "USD")])
check("bar fraction from counts", kimiOk.rows.first?.fraction.map { abs($0 - 0.2468) < 0.001 } == true)
check("a non-zero envelope code is a failure", KimiUsageAnswer.parse(body: Data(#"{"code":40101,"msg":"Unauthorized","data":null}"#.utf8)).failure == "Unauthorized")
check("garbage is malformed, not a verdict", KimiUsageAnswer.parse(body: Data("<html>".utf8)).kind == .malformed)
let huge = KimiUsageAnswer.parse(body: Data(#"{"code":0,"data":{"kind":"ok","summary":{"used":"1e30","limit":5000},"limits":[{"used":3,"limit":1e300}]}}"#.utf8))
check("a count past the integer range is dropped, not trapped on", huge.kind == .ok && huge.rows.isEmpty)
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
check("the window sits under a click-anywhere-else scrim",
      contentView.contains("UsagePopover(isPresented: $showingUsage)")
      && contentView.range(of: #"onTapGesture \{ showingUsage = false \}"#, options: .regularExpression) != nil)
check("one dropdown at a time",
      contentView.contains("if showingSearch { showingUsage = false }") && contentView.contains("if showingUsage { showingSearch = false }"))
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
               "%lld-hour", "%@ plan", "Subscription", "ChatGPT %@", "Membership", "%@ of %@", "resets %@",
               "Usage credits: %@ / %@ spent this month", "Usage credits: off", "Usage credits: off — %@",
               "%lld free limit resets available", "Extra usage: %@ of %@ left",
               "No agent on this Mac is signed in to a plan.", "The command-line tool did not answer."]
check("every new string carries a zh-Hans value", newKeys.allSatisfy(hasChinese),
      newKeys.filter { !hasChinese($0) }.joined(separator: ", "))
check("the old 'Not yet' FAQ answer is gone from the catalog",
      !strings.keys.contains { $0.hasPrefix("Not yet. For example, Claude's plan percentages") })
// Spend against a monthly LIMIT printed beside "off" reads as a balance
// with money left on an account whose credits are used up.
check("the credits line that read as a balance is gone from the catalog",
      strings["Usage credits: %@ of %@ · %@"] == nil)
// The answer is one line of a multi-line literal, so that line IS its key.
let faq4Answer = settings.components(separatedBy: "\n").first { $0.hasPrefix("Yes — click the ") } ?? ""
check("FAQ 4's answer is a catalog key in both languages, naming the T icon and no coin",
      faq4Answer.hasPrefix("Yes — click the T icon") && hasChinese(faq4Answer)
      && chineseValue(faq4Answer)?.contains("旁边的 T 图标") == true
      && !strings.keys.contains { $0.hasPrefix("Yes — click the coin icon") })

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
                if report.kind == .plan { check("claude's plan rows parsed", !report.rows.isEmpty) }
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
            }
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
            case .answered(let body):
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
