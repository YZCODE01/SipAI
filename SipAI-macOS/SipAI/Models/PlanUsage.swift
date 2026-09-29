// PlanUsage.swift
// The toolbar's plan-usage window: what each agent CLI's PLAN reports
// (a subscription's rate-limit windows), asked of the CLI itself at the
// click. API usage is deliberately not here — no CLI reports an
// account-level figure for an API key, and the window says so in one
// sentence rather than guessing.
//
// Three rules hold the file together:
//
//  * The CLI answers, SipAI never holds a token. Claude answers its own
//    `/usage` command under `-p`; codex answers two JSON-RPC calls over
//    its app-server; kimi answers over the `/oauth/usage` route of its
//    own local web server. Each runs as the CLI's own process with the
//    CLI's own login. Nothing here reads a keychain item, a
//    `credentials/` file or an auth token, and nothing calls a vendor
//    endpoint directly.
//  * Whether an agent is on a plan at all is decided in two layers.
//    A FILE layer (a few stats and a small read, no spawn) answers at
//    launch, on the 5 s detection tick and after a CLI update, from
//    files SipAI already reads: claude's `~/.claude.json`, codex's
//    `auth.json`, kimi's `config.toml` beside its token file. A PROBE
//    layer answers definitively on every window open and is persisted
//    with a fingerprint of the files it was measured over, so it
//    outranks the file layer exactly until those files change.
//  * The icon renders only when some installed agent is on a plan.
//    Unknown counts as "not on a plan": an icon that opens onto an
//    empty window is worse than no icon.
//
// Every parser is a pure function of the CLI's answer, so
// `Verification/UsageWindow` drives them with captured fixtures.

import Foundation

// MARK: - Account kind

/// Which account an agent CLI runs on, as far as SipAI can tell.
enum PlanAccountKind: Equatable {
    /// Signed in to a subscription. `name` is the plan tier the CLI
    /// states ("Max", codex's `planType`), nil when it states none.
    case plan(name: String?)
    /// Billed per token through an API key or a cloud provider.
    case apiKey
    /// Nothing signed in.
    case signedOut
    /// Could not be read.
    case unknown

    var isPlan: Bool {
        if case .plan = self { return true }
        return false
    }

    /// Signed in, on a plan or on a key — what a sign-out reading moves
    /// away from.
    var isSignedIn: Bool { isPlan || self == .apiKey }

    var planName: String? {
        if case .plan(let name) = self { return name }
        return nil
    }

    /// One-line spelling for UserDefaults.
    var storageValue: String {
        switch self {
        case .plan(let name): return "plan" + (name.map { ":" + $0 } ?? "")
        case .apiKey: return "apiKey"
        case .signedOut: return "signedOut"
        case .unknown: return "unknown"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "apiKey": self = .apiKey
        case "signedOut": self = .signedOut
        case "unknown": self = .unknown
        case "plan": self = .plan(name: nil)
        default:
            guard storageValue.hasPrefix("plan:") else { return nil }
            let name = String(storageValue.dropFirst("plan:".count))
            self = .plan(name: name.isEmpty ? nil : name)
        }
    }
}

// MARK: - Rows

/// A rate-limit window as a CLI states it. Codex states minutes, kimi
/// a duration and a unit; both land here so one display rule names
/// them ("5-hour", "Weekly").
struct PlanWindow: Equatable {
    enum Unit: String, Equatable { case minute, hour, day, week }
    let duration: Int
    let unit: Unit

    /// Codex's `windowDurationMins` / `window_minutes`: 300 is the
    /// 5-hour window, 10080 the weekly one. Whole hours, days and
    /// weeks fold up; anything else stays in minutes.
    static func minutes(_ minutes: Int) -> PlanWindow {
        if minutes > 0, minutes % 10080 == 0 {
            return PlanWindow(duration: minutes / 10080, unit: .week)
        }
        if minutes > 0, minutes % 1440 == 0 {
            return PlanWindow(duration: minutes / 1440, unit: .day)
        }
        if minutes > 0, minutes % 60 == 0 {
            return PlanWindow(duration: minutes / 60, unit: .hour)
        }
        return PlanWindow(duration: minutes, unit: .minute)
    }
}

/// One limit as the window draws it: a label, a fill, and when it
/// resets. Labels are the CLI's own words where it has them (claude's
/// "Current week (Fable)", a codex model name); the window may be the
/// only name a row has.
struct PlanUsageRow: Equatable {
    var label: String?
    var window: PlanWindow?
    /// 0…100 when the CLI states a percentage.
    var percent: Int?
    /// Counts when the CLI states those instead (kimi).
    var used: Int?
    var limit: Int?
    /// The reset as TEXT when the CLI gave prose (claude), else nil.
    var resetText: String?
    /// The reset as a DATE when the CLI gave one (codex, kimi), else nil.
    var resetDate: Date?

    /// How full the bar is, 0…1, or nil when nothing can be drawn.
    var fraction: Double? {
        if let percent { return min(1, max(0, Double(percent) / 100)) }
        if let used, let limit, limit > 0 {
            return min(1, max(0, Double(used) / Double(limit)))
        }
        return nil
    }
}

/// A line under a card's rows: something the plan reports that is not
/// a window.
enum PlanUsageNote: Equatable {
    /// Claude's usage credits — the plan's overflow budget.
    case usageCredits(usedMinor: Int, limitMinor: Int, exponent: Int,
                      currency: String, enabled: Bool, disabledReason: String?)
    /// Codex's free "Full reset" credits.
    case freeResets(count: Int)
    /// Kimi's Extra Usage wallet, in cents.
    case extraUsage(balanceCents: Int, totalCents: Int, currency: String)
}

/// One agent's card.
struct PlanUsageCard: Equatable {
    let agentKey: String
    let defaultName: String
    var planName: String?
    var rows: [PlanUsageRow] = []
    var notes: [PlanUsageNote] = []
    /// The CLI's own sentence when it could not report.
    var failure: String?
    /// Claude's whole answer when none of its lines parsed — still the
    /// answer, shown as text rather than dropped.
    var rawText: String?
    var updatedAt: Date?
    /// Figures from an earlier read, shown dimmed while a refresh runs.
    var stale: Bool = false

    var hasFigures: Bool { !rows.isEmpty || !notes.isEmpty || rawText != nil }
}

// MARK: - Claude: the `/usage` text

/// `claude -p /usage` answers as TEXT, and the text's shape is the
/// account-kind verdict: a subscription opens with "You are currently
/// using your subscription…" and lists `<label>: <n>% used · resets
/// <when>` lines; an API key prints the `/cost` table of the empty
/// probe session ("Total cost: $0.0000 …"), because no account figure
/// exists for an API key. Labels are parsed, never matched — the
/// per-family line is "Current week (Fable)" on one account and
/// "(Opus)" or "(Sonnet only)" on another.
enum ClaudeUsageText {
    enum Kind: Equatable { case plan, apiKey, unknown }

    struct Report: Equatable {
        var kind: Kind
        var rows: [PlanUsageRow]
    }

    static let planSentence = "using your subscription"
    static let apiKeyTable = "Total cost:"

    private static let rowPattern = try! NSRegularExpression(
        pattern: #"^(.+?):\s+(\d{1,3})% used(?:\s*[·•]\s*resets\s+(.+?))?\s*$"#,
        options: [])

    nonisolated static func parse(_ text: String,
                                  currentZone: String = TimeZone.current.identifier) -> Report {
        var kind: Kind = .unknown
        var rows: [PlanUsageRow] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if kind == .unknown {
                if line.localizedCaseInsensitiveContains(planSentence) {
                    kind = .plan
                } else if line.contains(apiKeyTable) {
                    kind = .apiKey
                }
            }
            let range = NSRange(line.startIndex..., in: line)
            guard let m = rowPattern.firstMatch(in: line, range: range),
                  let labelRange = Range(m.range(at: 1), in: line),
                  let percentRange = Range(m.range(at: 2), in: line),
                  let percent = Int(line[percentRange]), percent <= 100
            else { continue }
            var reset: String? = nil
            if let resetRange = Range(m.range(at: 3), in: line) {
                reset = stripZone(String(line[resetRange]), currentZone: currentZone)
            }
            rows.append(PlanUsageRow(label: String(line[labelRange]),
                                     window: nil, percent: percent,
                                     used: nil, limit: nil,
                                     resetText: reset, resetDate: nil))
        }
        // `<n>% used` rows exist for a subscription and nothing else,
        // so they decide the kind when the opening sentence did not —
        // a reworded first line must not turn a parsed answer into
        // "unknown".
        if kind == .unknown, !rows.isEmpty { kind = .plan }
        return Report(kind: kind, rows: rows)
    }

    /// "Sep 13 at 12:10am (Europe/London)" → "Sep 13 at 12:10am"
    /// when the parenthetical names the Mac's own zone. Another zone
    /// stays: it is information.
    nonisolated static func stripZone(_ reset: String, currentZone: String) -> String {
        let trimmed = reset.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"),
              let open = trimmed.lastIndex(of: "(") else { return trimmed }
        let zone = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        guard zone == currentZone else { return trimmed }
        return String(trimmed[trimmed.startIndex..<open])
            .trimmingCharacters(in: .whitespaces)
    }

    /// The plan tier from claude's `organizationType` ("claude_max" →
    /// "Max"). Unknown spellings answer nil and the card says
    /// "Subscription".
    nonisolated static func planName(organizationType: String?) -> String? {
        switch organizationType {
        case "claude_max": return "Max"
        case "claude_pro": return "Pro"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        default: return nil
        }
    }
}

// MARK: - Claude: the structured cache

/// Claude keeps the same figures, structured, in `~/.claude.json` →
/// `cachedUsageUtilization`, and the `/usage` probe refreshes them
/// (measured: `fetchedAtMs` moves on every probe). Read for two things
/// only: the instant last-known rows at launch, stamped with the
/// cache's own time, and the usage-credits line. The keys are
/// undocumented, so the text stays the authority for the rows.
enum ClaudeUsageCache {
    struct Seed: Equatable {
        var rows: [PlanUsageRow]
        var fetchedAt: Date?
        var credits: PlanUsageNote?
    }

    /// Window keys claude writes, with the labels its `/usage` text
    /// gives the same windows — so a cached row and a probed row for
    /// one window carry one label.
    static let windows: [(key: String, label: String)] = [
        ("five_hour", "Current session"),
        ("seven_day", "Current week (all models)"),
        ("seven_day_opus", "Current week (Opus)"),
        ("seven_day_sonnet", "Current week (Sonnet)"),
    ]

    nonisolated static func read(_ data: Data) -> Seed? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cache["utilization"] as? [String: Any]
        else { return nil }
        var rows: [PlanUsageRow] = []
        for window in windows {
            guard let block = utilization[window.key] as? [String: Any],
                  let percent = (block["utilization"] as? NSNumber)?.intValue
            else { continue }
            let reset = (block["resets_at"] as? String).flatMap(isoDate)
            rows.append(PlanUsageRow(label: window.label, window: nil,
                                     percent: min(100, max(0, percent)),
                                     used: nil, limit: nil,
                                     resetText: nil, resetDate: reset))
        }
        var fetchedAt: Date? = nil
        if let ms = (cache["fetchedAtMs"] as? NSNumber)?.doubleValue, ms > 0 {
            fetchedAt = Date(timeIntervalSince1970: ms / 1000)
        }
        return Seed(rows: rows, fetchedAt: fetchedAt,
                    credits: credits(in: utilization["extra_usage"] as? [String: Any]))
    }

    /// The overflow budget, only once it has ever been switched on —
    /// an account that never had credits has no line to show.
    nonisolated static func credits(in block: [String: Any]?) -> PlanUsageNote? {
        guard let block,
              (block["credits_ever_enabled"] as? Bool) == true,
              let limit = (block["monthly_limit"] as? NSNumber)?.intValue,
              let used = (block["used_credits"] as? NSNumber)?.intValue
        else { return nil }
        let exponent = (block["decimal_places"] as? NSNumber)?.intValue ?? 2
        let currency = (block["currency"] as? String) ?? "USD"
        let enabled = (block["is_enabled"] as? Bool) ?? false
        let reason = (block["disabled_reason"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        return .usageCredits(usedMinor: used, limitMinor: limit,
                             exponent: exponent, currency: currency,
                             enabled: enabled, disabledReason: reason)
    }

    /// `oauthAccount.organizationType` from the same file.
    nonisolated static func organizationType(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any]
        else { return nil }
        return account["organizationType"] as? String
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Both spellings claude and kimi write: with and without
    /// fractional seconds.
    nonisolated static func isoDate(_ text: String) -> Date? {
        isoFractional.date(from: text) ?? isoPlain.date(from: text)
    }
}

// MARK: - Codex: `account/read` + `account/rateLimits/read`

/// Codex's app-server states the account kind outright
/// (`account.type`: chatgpt / apiKey / null) and, for a ChatGPT
/// account, every limit as numbers: the account's primary and
/// secondary windows, per-model limits under `rateLimitsByLimitId`,
/// and free reset credits. Both data calls are refused with
/// `-32600` under an API key and when signed out — the refusal text
/// is codex's own and is shown as such.
enum CodexUsageAnswer {
    struct Report: Equatable {
        var kind: PlanAccountKind
        var rows: [PlanUsageRow]
        var notes: [PlanUsageNote]
        /// Codex's own sentence when it declined.
        var failure: String?
        /// False when the limits call produced neither a result nor an
        /// error — nothing arrived inside the ceiling, or the answer
        /// was in a shape this does not read. A plan card with no rows
        /// and no reason is the silent failure this flag exists for.
        var answered: Bool
    }

    nonisolated static func parse(account: [String: Any]?,
                                  rateLimits: [String: Any]?) -> Report {
        let kind = accountKind(account)
        // The limits answer is read whatever the account kind: a
        // refusal under an API key is expected and dropped below, one
        // under an account that could not be read is worth showing.
        var failure: String? = nil
        var result: [String: Any]? = nil
        if let rateLimits {
            if let error = rateLimits["error"] as? [String: Any] {
                failure = (error["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "error"
            } else {
                result = rateLimits["result"] as? [String: Any]
            }
        }
        let answered = failure != nil || result != nil
        switch kind {
        case .apiKey, .signedOut:
            return Report(kind: kind, rows: [], notes: [], failure: nil, answered: answered)
        case .unknown:
            return Report(kind: kind, rows: [], notes: [], failure: failure, answered: answered)
        case .plan:
            break
        }
        guard let result else {
            return Report(kind: kind, rows: [], notes: [], failure: failure, answered: answered)
        }
        var rows: [PlanUsageRow] = []
        var planName = kind.planName
        let primaryLimitId: String?
        if let limits = result["rateLimits"] as? [String: Any] {
            primaryLimitId = limits["limitId"] as? String
            rows.append(contentsOf: windowRows(of: limits, label: nil))
            if planName == nil, let plan = limits["planType"] as? String {
                planName = displayPlanType(plan)
            }
        } else {
            primaryLimitId = nil
        }
        // Per-model limits, in a stable order — the dictionary's is
        // not one. The account's own entry is the block above.
        if let byId = result["rateLimitsByLimitId"] as? [String: [String: Any]] {
            for key in byId.keys.sorted() {
                guard key != primaryLimitId, let entry = byId[key],
                      let name = entry["limitName"] as? String, !name.isEmpty
                else { continue }
                rows.append(contentsOf: windowRows(of: entry, label: name))
            }
        }
        var notes: [PlanUsageNote] = []
        if let credits = result["rateLimitResetCredits"] as? [String: Any],
           let count = (credits["availableCount"] as? NSNumber)?.intValue, count > 0 {
            notes.append(.freeResets(count: count))
        }
        return Report(kind: .plan(name: planName), rows: rows, notes: notes,
                      failure: nil, answered: true)
    }

    /// `{"account":{"type":"chatgpt","planType":"prolite"}}` → plan;
    /// `{"account":{"type":"apiKey"}}` → API key; `{"account":null}` →
    /// signed out; anything else → unknown (a moved schema must not
    /// read as a verdict).
    nonisolated static func accountKind(_ answer: [String: Any]?) -> PlanAccountKind {
        guard let answer else { return .unknown }
        guard let result = answer["result"] as? [String: Any] else { return .unknown }
        // A missing key and a JSON null read differently: the key is
        // present, the value is NSNull.
        guard let raw = result["account"] else { return .unknown }
        if raw is NSNull { return .signedOut }
        guard let account = raw as? [String: Any],
              let type = account["type"] as? String else { return .unknown }
        switch type {
        case "chatgpt":
            return .plan(name: (account["planType"] as? String).map(displayPlanType))
        case "apiKey", "apikey":
            return .apiKey
        default:
            return .unknown
        }
    }

    /// `primary` / `secondary` of one limit block, as rows.
    nonisolated private static func windowRows(of block: [String: Any],
                                               label: String?) -> [PlanUsageRow] {
        var rows: [PlanUsageRow] = []
        for key in ["primary", "secondary"] {
            guard let window = block[key] as? [String: Any],
                  let percent = (window["usedPercent"] as? NSNumber)?.intValue,
                  let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue
            else { continue }
            var reset: Date? = nil
            if let at = (window["resetsAt"] as? NSNumber)?.doubleValue, at > 0 {
                reset = Date(timeIntervalSince1970: at)
            }
            rows.append(PlanUsageRow(label: label,
                                     window: PlanWindow.minutes(minutes),
                                     percent: min(100, max(0, percent)),
                                     used: nil, limit: nil,
                                     resetText: nil, resetDate: reset))
        }
        return rows
    }

    /// `prolite` → "Prolite". A raw slug capitalised, never mapped
    /// through a table that would be wrong the week a plan is renamed.
    nonisolated static func displayPlanType(_ slug: String) -> String {
        let trimmed = slug.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return trimmed }
        return first.uppercased() + trimmed.dropFirst()
    }
}

// MARK: - Kimi: the web server's `/oauth/usage` envelope

/// `GET /api/v1/oauth/usage` on `kimi web` answers
/// `{"code":0,"msg":"success","data":<result>}`, where the result is
/// kimi's own `toWireUsage`: `{kind: "ok", summary, limits, extra_usage}`
/// or `{kind: "error", message, status?}`. A row is `{name?, window?
/// {duration, unit}, used, limit, reset_at?}`; the wallet is in cents.
/// The error branch is the measured one (a kimi on an API key, no
/// membership login); the ok branch's shape is kimi's zod schema.
enum KimiUsageAnswer {
    enum Kind: Equatable { case ok, error, malformed }

    struct Report: Equatable {
        var kind: Kind
        var rows: [PlanUsageRow]
        var notes: [PlanUsageNote]
        var failure: String?
    }

    nonisolated static func parse(body: Data) -> Report {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else { return Report(kind: .malformed, rows: [], notes: [], failure: nil) }
        if let code = (root["code"] as? NSNumber)?.intValue, code != 0 {
            let msg = (root["msg"] as? String) ?? "code \(code)"
            return Report(kind: .error, rows: [], notes: [], failure: msg)
        }
        guard let data = root["data"] as? [String: Any],
              let kind = data["kind"] as? String
        else { return Report(kind: .malformed, rows: [], notes: [], failure: nil) }
        if kind == "error" {
            let message = (data["message"] as? String) ?? "error"
            return Report(kind: .error, rows: [], notes: [], failure: message)
        }
        guard kind == "ok" else {
            return Report(kind: .malformed, rows: [], notes: [], failure: nil)
        }
        var rows: [PlanUsageRow] = []
        if let summary = data["summary"] as? [String: Any],
           let row = row(summary, defaultWindow: PlanWindow(duration: 1, unit: .week)) {
            rows.append(row)
        }
        if let limits = data["limits"] as? [[String: Any]] {
            for limit in limits {
                if let row = row(limit, defaultWindow: nil) { rows.append(row) }
            }
        }
        var notes: [PlanUsageNote] = []
        if let wallet = data["extra_usage"] as? [String: Any],
           let total = (wallet["total_cents"] as? NSNumber)?.intValue, total > 0 {
            let balance = (wallet["balance_cents"] as? NSNumber)?.intValue ?? 0
            let currency = (wallet["currency"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "USD"
            notes.append(.extraUsage(balanceCents: balance, totalCents: total,
                                     currency: currency))
        }
        return Report(kind: .ok, rows: rows, notes: notes, failure: nil)
    }

    nonisolated private static func row(_ raw: [String: Any],
                                        defaultWindow: PlanWindow?) -> PlanUsageRow? {
        guard let used = int(raw["used"]), let limit = int(raw["limit"]) else { return nil }
        var window = defaultWindow
        if let w = raw["window"] as? [String: Any],
           let duration = int(w["duration"]),
           let unit = (w["unit"] as? String).flatMap(PlanWindow.Unit.init(rawValue:)) {
            window = PlanWindow(duration: duration, unit: unit)
        }
        let name = (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let resetRaw = (raw["reset_at"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let resetDate = resetRaw.flatMap(ClaudeUsageCache.isoDate)
        return PlanUsageRow(label: name, window: window, percent: nil,
                            used: max(0, used), limit: max(0, limit),
                            resetText: resetDate == nil ? resetRaw : nil,
                            resetDate: resetDate)
    }

    /// A count as a number or as a numeric string — kimi's own reader
    /// (`toInt`) takes both from the upstream API, so this one does too.
    nonisolated private static func int(_ value: Any?) -> Int? {
        let number: Double
        if let boxed = value as? NSNumber {
            number = boxed.doubleValue
        } else if let text = value as? String,
                  let parsed = Double(text.trimmingCharacters(in: .whitespaces)) {
            number = parsed
        } else {
            return nil
        }
        // `Int(Double)` traps past the integer range; a count that far
        // out is not a count.
        guard number.isFinite, abs(number) < 1e15 else { return nil }
        return Int(number)
    }
}

// MARK: - File layer: is this agent on a plan?

/// Reads the CLIs' own files for the account kind. Pure functions of
/// file contents, plus the live wrappers that locate the files.
enum PlanAccountDetector {

    /// Every way an API source overrides claude's login, spelled the
    /// way claude spells them. Any of these in the CHILD's environment
    /// — `ProcessInfo`'s, which is what `AgentRunner.buildEnvironment`
    /// starts from — or in `settings.json`'s `env` block means a SipAI
    /// session bills an API key, whatever the login says.
    static let claudeAPISourceNames = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
    ]

    /// A long-lived subscription login carried in the environment
    /// (`claude setup-token`). Claude prefers it to the keychain login,
    /// and the file may not name the account it belongs to.
    static let claudeOAuthTokenName = "CLAUDE_CODE_OAUTH_TOKEN"

    /// Claude: `oauthAccount` in `~/.claude.json` is the login;
    /// `billingType` tells a subscription (`stripe_subscription`) from
    /// a Console account billed per token (`usage_based` — claude's own
    /// spelling of the case its rate-limit features switch off for).
    /// An API source in force wins over either.
    nonisolated static func claudeKind(claudeJSON: Data?,
                                       settings: [Data],
                                       environment: [String: String]) -> PlanAccountKind {
        if apiSourceInForce(settings: settings, environment: environment) {
            return .apiKey
        }
        let tokenInEnvironment = isSet(environment[claudeOAuthTokenName])
        guard let claudeJSON,
              let root = (try? JSONSerialization.jsonObject(with: claudeJSON)) as? [String: Any]
        else { return tokenInEnvironment ? .plan(name: nil) : .unknown }
        guard let account = claudeAccount(in: root) else {
            return tokenInEnvironment ? .plan(name: nil) : .signedOut
        }
        if let billing = account["billingType"] as? String, billing == "usage_based" {
            return .apiKey
        }
        return .plan(name: ClaudeUsageText.planName(
            organizationType: account["organizationType"] as? String))
    }

    /// `oauthAccount` when it names someone — a `{}` left behind is
    /// not a login.
    nonisolated static func claudeAccount(in root: [String: Any]) -> [String: Any]? {
        guard let account = root["oauthAccount"] as? [String: Any] else { return nil }
        for key in ["accountUuid", "emailAddress", "organizationUuid"] {
            if let value = account[key] as? String, !value.isEmpty { return account }
        }
        return nil
    }

    nonisolated static func apiSourceInForce(settings: [Data],
                                             environment: [String: String]) -> Bool {
        for name in claudeAPISourceNames where isSet(environment[name]) {
            return true
        }
        for data in settings {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            if let helper = obj["apiKeyHelper"] as? String,
               !helper.trimmingCharacters(in: .whitespaces).isEmpty {
                return true
            }
            if let env = obj["env"] as? [String: Any] {
                for name in claudeAPISourceNames {
                    if let value = env[name] as? String, isSet(value) { return true }
                    if let flag = env[name] as? Bool, flag { return true }
                }
            }
        }
        return false
    }

    /// Non-empty and not one of the spellings of "off".
    nonisolated private static func isSet(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else { return false }
        return !["0", "false", "no", "off"].contains(value.lowercased())
    }

    /// Codex: `auth.json`'s `auth_mode` — `chatgpt` is a plan, `apikey`
    /// an API key; a file holding only `OPENAI_API_KEY` is an API key
    /// too; no file is signed out. An `OPENAI_API_KEY` in the
    /// environment with no ChatGPT tokens on disk is an API key.
    nonisolated static func codexKind(authJSON: Data?,
                                      environment: [String: String]) -> PlanAccountKind {
        guard let authJSON else {
            return isSet(environment["OPENAI_API_KEY"]) ? .apiKey : .signedOut
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: authJSON)) as? [String: Any]
        else { return .unknown }
        let tokens = obj["tokens"] as? [String: Any]
        let hasTokens = !(tokens?.isEmpty ?? true)
        if let mode = obj["auth_mode"] as? String {
            switch mode.lowercased() {
            case "chatgpt": return hasTokens ? .plan(name: nil) : .signedOut
            case "apikey": return .apiKey
            default: break
            }
        }
        if hasTokens { return .plan(name: nil) }
        if let key = obj["OPENAI_API_KEY"] as? String, isSet(key) { return .apiKey }
        return isSet(environment["OPENAI_API_KEY"]) ? .apiKey : .signedOut
    }

    /// Kimi: `kimi login` writes `[providers."managed:kimi-code"]` with
    /// an `oauth` key naming the token file under `credentials/`. Both
    /// present → plan. A provider with an API key (Moonshot, or
    /// `kimi-for-coding`, the plan-backed key kimi's own usage route
    /// answers "No token" for) → API key. No provider → signed out — a
    /// file holding nothing included: kimi's own `provider remove` of the
    /// last provider and its server's logout each leave three newlines
    /// (measured, 2.1.1), and that IS the sign-out a terminal made. Read
    /// as "being rewritten" (`.unknown`) it carried the old verdict, and
    /// a kimi signed out in Terminal stayed listed until relaunch. A file
    /// caught mid-rewrite reads the same for one pass, which is why a
    /// sign-out off the files is taken on the SECOND consecutive reading
    /// (`UsageMonitor.pendingSignOut`), never the first.
    nonisolated static func kimiKind(configText: String?,
                                     tokenFileExists: (String) -> Bool) -> PlanAccountKind {
        guard let configText else { return .signedOut }
        if let oauthKey = kimiOAuthKey(configText: configText),
           let storage = kimiTokenStorageName(oauthKey: oauthKey),
           tokenFileExists(storage) {
            return .plan(name: nil)
        }
        return kimiHasAPIKeyProvider(configText: configText) ? .apiKey : .signedOut
    }

    static let kimiManagedProvider = "managed:kimi-code"
    static let kimiDefaultOAuthKey = "oauth/kimi-code"

    /// The `oauth.key` of the managed provider, or its default when the
    /// table is present without one; nil when there is no managed
    /// provider at all. Kimi writes the key either as a sub-table
    /// (`[providers."managed:kimi-code".oauth]`) or inline
    /// (`oauth = { key = "…" }`); both are read.
    nonisolated static func kimiOAuthKey(configText: String) -> String? {
        var inManaged = false
        var inManagedOAuth = false
        var found = false
        var key: String? = nil
        for rawLine in configText.components(separatedBy: .newlines) {
            let line = stripComment(rawLine.trimmingCharacters(in: .whitespaces))
            if line.hasPrefix("[") {
                let header = line.replacingOccurrences(of: " ", with: "")
                inManaged = header == "[providers.\"\(kimiManagedProvider)\"]"
                    || header == "[providers.'\(kimiManagedProvider)']"
                inManagedOAuth = header == "[providers.\"\(kimiManagedProvider)\".oauth]"
                    || header == "[providers.'\(kimiManagedProvider)'.oauth]"
                if inManaged || inManagedOAuth { found = true }
                continue
            }
            if inManagedOAuth, let value = TomlScalar.string(line, key: "key") {
                key = value
            } else if inManaged, line.hasPrefix("oauth"),
                      let brace = line.firstIndex(of: "{") {
                // Inline table: find `key = "…"` inside the braces.
                let inner = line[line.index(after: brace)...]
                for part in inner.split(separator: ",") {
                    let piece = part.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "}", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if let value = TomlScalar.string(piece, key: "key") { key = value }
                }
            }
        }
        guard found else { return nil }
        return key ?? kimiDefaultOAuthKey
    }

    /// Kimi's `resolveKimiTokenStorageName`: "oauth/kimi-code" and
    /// "kimi-code" → "kimi-code"; "oauth/<x>" → x; a bare name → itself;
    /// anything else is not a name kimi would write.
    nonisolated static func kimiTokenStorageName(oauthKey: String) -> String? {
        if oauthKey == "kimi-code" || oauthKey == kimiDefaultOAuthKey { return "kimi-code" }
        if oauthKey.hasPrefix("oauth/") {
            let rest = String(oauthKey.dropFirst("oauth/".count))
            return rest.isEmpty ? nil : rest
        }
        if !oauthKey.contains("/") && !oauthKey.hasPrefix(".") { return oauthKey }
        return nil
    }

    /// Any `[providers.*]` table carrying a non-empty `api_key`.
    nonisolated static func kimiHasAPIKeyProvider(configText: String) -> Bool {
        var inProvider = false
        for rawLine in configText.components(separatedBy: .newlines) {
            let line = stripComment(rawLine.trimmingCharacters(in: .whitespaces))
            if line.hasPrefix("[") {
                inProvider = line.hasPrefix("[providers.")
                continue
            }
            if inProvider, let key = TomlScalar.string(line, key: "api_key"),
               !key.trimmingCharacters(in: .whitespaces).isEmpty {
                return true
            }
        }
        return false
    }

    nonisolated private static func stripComment(_ line: String) -> String {
        guard let hash = line.firstIndex(of: "#"),
              line[line.startIndex..<hash].filter({ $0 == "\"" }).count % 2 == 0
        else { return line }
        return String(line[line.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Live wrappers

    nonisolated static var claudeConfigFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }
    nonisolated static var claudeSettingsFiles: [URL] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        return [dir.appendingPathComponent("settings.json"),
                dir.appendingPathComponent("settings.local.json")]
    }
    /// `~/.codex` — `CODEX_HOME` is not honoured on any read side of
    /// this app, and this one keeps that spelling rather than starting
    /// a second convention.
    nonisolated static var codexAuthFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }
    nonisolated static func kimiTokenFile(storageName: String) -> URL {
        KimiSessionScanner.home
            .appendingPathComponent("credentials", isDirectory: true)
            .appendingPathComponent(storageName + ".json")
    }

    /// One read of the agent's files: the verdict, and a digest of the
    /// FACTS it was decided on. The digest is what the probe layer's
    /// verdict is keyed to, and it is deliberately not the files'
    /// (size, mtime): claude rewrites `~/.claude.json` on every probe
    /// (the usage cache) and on every turn (model usage), codex rewrites
    /// `auth.json` on every token refresh — bytes that move without the
    /// account changing. Only a login, a logout or an API source in
    /// force moves this digest.
    struct Reading: Equatable {
        var verdict: PlanAccountKind
        var fingerprint: String
    }

    nonisolated static func read(agentKey: String) -> Reading {
        let env = ProcessInfo.processInfo.environment
        switch agentKey {
        case "claude_code":
            let claudeJSON = try? Data(contentsOf: claudeConfigFile)
            let settings = claudeSettingsFiles.compactMap { try? Data(contentsOf: $0) }
            let verdict = claudeKind(claudeJSON: claudeJSON, settings: settings, environment: env)
            return Reading(verdict: verdict,
                           fingerprint: claudeFingerprint(claudeJSON: claudeJSON, settings: settings,
                                                          environment: env))
        case "codex":
            let authJSON = try? Data(contentsOf: codexAuthFile)
            return Reading(verdict: codexKind(authJSON: authJSON, environment: env),
                           fingerprint: codexFingerprint(authJSON: authJSON, environment: env))
        case "kimi":
            let text = try? String(contentsOf: KimiSessionScanner.configFile, encoding: .utf8)
            let exists: (String) -> Bool = { storage in
                FileManager.default.fileExists(atPath: kimiTokenFile(storageName: storage).path)
            }
            return Reading(verdict: kimiKind(configText: text, tokenFileExists: exists),
                           fingerprint: kimiFingerprint(configText: text, tokenFileExists: exists))
        default:
            return Reading(verdict: .unknown, fingerprint: "")
        }
    }

    nonisolated static func fileVerdict(agentKey: String) -> PlanAccountKind {
        read(agentKey: agentKey).verdict
    }

    nonisolated static func fingerprint(agentKey: String) -> String {
        read(agentKey: agentKey).fingerprint
    }

    /// The account's identity and billing fields — never the e-mail,
    /// which has no business in UserDefaults — plus the API-source
    /// facts. `profileFetchedAt` and the caches beside them move on
    /// their own and are left out on purpose.
    nonisolated static func claudeFingerprint(claudeJSON: Data?, settings: [Data],
                                              environment: [String: String]) -> String {
        var parts: [String] = []
        if let claudeJSON,
           let root = (try? JSONSerialization.jsonObject(with: claudeJSON)) as? [String: Any] {
            if let account = claudeAccount(in: root) {
                for key in ["accountUuid", "organizationUuid", "billingType",
                            "organizationType", "organizationRateLimitTier", "seatTier"] {
                    parts.append(key + "=" + String(describing: account[key] ?? "nil"))
                }
            } else {
                parts.append("account=none")
            }
        } else {
            parts.append("account=unreadable")
        }
        parts.append("api=" + (apiSourceInForce(settings: settings, environment: environment) ? "1" : "0"))
        parts.append("token=" + (isSet(environment[claudeOAuthTokenName]) ? "1" : "0"))
        return parts.joined(separator: ";")
    }

    nonisolated static func codexFingerprint(authJSON: Data?,
                                             environment: [String: String]) -> String {
        guard let authJSON else {
            return "auth=none;env=" + (isSet(environment["OPENAI_API_KEY"]) ? "1" : "0")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: authJSON)) as? [String: Any] else {
            return "auth=unreadable"
        }
        let tokens = obj["tokens"] as? [String: Any]
        let mode = (obj["auth_mode"] as? String) ?? "nil"
        let account = (tokens?["account_id"] as? String) ?? "nil"
        return "mode=\(mode);tokens=\(!(tokens?.isEmpty ?? true));account=\(account);"
            + "key=\(isSet(obj["OPENAI_API_KEY"] as? String));env=\(isSet(environment["OPENAI_API_KEY"]))"
    }

    nonisolated static func kimiFingerprint(configText: String?,
                                            tokenFileExists: (String) -> Bool) -> String {
        guard let configText else { return "config=none" }
        let key = kimiOAuthKey(configText: configText)
        let storage = key.flatMap(kimiTokenStorageName(oauthKey:))
        let token = storage.map(tokenFileExists) ?? false
        return "oauth=\(key ?? "nil");token=\(token);apiKey=\(kimiHasAPIKeyProvider(configText: configText))"
    }

    /// The verdict in force: the probe's, while the files it was
    /// measured over are unchanged; the file layer's otherwise. Where
    /// both say plan, the probe names the tier better.
    nonisolated static func effective(file: PlanAccountKind,
                                      probe: PlanAccountVerdictStore.Entry?,
                                      fingerprint: String) -> PlanAccountKind {
        guard let probe, probe.fingerprint == fingerprint else { return file }
        switch (file, probe.kind) {
        case (.plan(let fileName), .plan(let probeName)):
            return .plan(name: probeName ?? fileName)
        case (_, .unknown):
            return file
        default:
            return probe.kind
        }
    }
}

// MARK: - Persisted probe verdicts

/// The probe layer's last verdict per agent, with the file fingerprint
/// it was measured over, so the icon is right at the next launch
/// before anything runs. UserDefaults: Mac-only UI state, not the
/// config file the CLI shares.
enum PlanAccountVerdictStore {
    static let defaultsKey = "planAccountVerdicts"
    /// Where the verdicts live. A harness points this at a throwaway
    /// suite so a headless run never writes the real defaults.
    static var defaults: UserDefaults = .standard

    struct Entry: Equatable {
        var kind: PlanAccountKind
        var fingerprint: String
    }

    nonisolated static func load() -> [String: Entry] {
        guard let raw = defaults.dictionary(forKey: defaultsKey) as? [String: [String: String]]
        else { return [:] }
        return decode(raw)
    }

    nonisolated static func decode(_ raw: [String: [String: String]]) -> [String: Entry] {
        var out: [String: Entry] = [:]
        for (agent, entry) in raw {
            guard let kindText = entry["kind"],
                  let kind = PlanAccountKind(storageValue: kindText),
                  let fingerprint = entry["fingerprint"] else { continue }
            out[agent] = Entry(kind: kind, fingerprint: fingerprint)
        }
        return out
    }

    nonisolated static func encode(_ entries: [String: Entry]) -> [String: [String: String]] {
        var raw: [String: [String: String]] = [:]
        for (agent, entry) in entries {
            raw[agent] = ["kind": entry.kind.storageValue, "fingerprint": entry.fingerprint]
        }
        return raw
    }

    nonisolated static func save(_ entries: [String: Entry]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(encode(entries), forKey: defaultsKey)
        }
    }
}

// MARK: - Probes

/// Where the probes run. A cwd under the system temp root is scratch
/// to both session scanners (`isScratchLocation`), so the transcript
/// claude writes per probe — and removes below — can never list even
/// in the window before it is removed.
enum PlanUsageScratch {
    nonisolated static var directory: URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sipai-plan-usage", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// `claude -p /usage`, and the cleanup it needs.
enum ClaudeUsageProbe {
    static let ceiling: TimeInterval = 30

    struct Outcome: Equatable {
        /// The answer text, when the child produced a result.
        var text: String?
        /// What the child said when it produced none.
        var errorText: String?
    }

    /// `--session-id` names the transcript the probe writes so it can
    /// be removed; the MCP flags stop the user's servers being started
    /// to answer a usage question (measured: a second saved). Setting
    /// sources are NOT dropped — an `apiKeyHelper` there decides which
    /// account answers.
    nonisolated static func arguments(sessionId: String) -> [String] {
        ["-p", "/usage", "--output-format", "json",
         "--session-id", sessionId,
         "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
    }

    nonisolated static func run(binary: String, scratchDirectory: URL) async -> Outcome {
        let sessionId = UUID().uuidString.lowercased()
        let result = await AgentCLIProbe.run(binary: binary,
                                             arguments: arguments(sessionId: sessionId),
                                             ceiling: ceiling,
                                             outputCap: 256 * 1024,
                                             currentDirectory: scratchDirectory.path,
                                             onSpawn: { _ in })
        removeTranscript(sessionId: sessionId)
        let extracted = extractResult(from: result.output)
        if let text = extracted.text, !extracted.isError {
            return Outcome(text: text, errorText: nil)
        }
        let tail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = tail.split(separator: "\n").last.map(String.init) ?? ""
        return Outcome(text: nil, errorText: extracted.text ?? (last.isEmpty ? nil : last))
    }

    /// The `result` of the one JSON object in the output. stdout and
    /// stderr share the pipe, so claude's own warnings ("⚠ claude.ai
    /// connectors are disabled…") sit on lines of their own around it.
    nonisolated static func extractResult(from output: String) -> (text: String?, isError: Bool) {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)))
                    as? [String: Any],
                  (obj["type"] as? String) == "result"
            else { continue }
            let text = obj["result"] as? String
            let isError = (obj["is_error"] as? Bool) ?? false
            return (text, isError)
        }
        return (nil, false)
    }

    /// The probe's transcript, wherever claude filed it: its directory
    /// is claude's munge of the cwd, which is lossy, so the file is
    /// found by name one level under every project directory rather
    /// than by re-implementing the munge.
    nonisolated static func removeTranscript(sessionId: String) {
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let dirs = try? fm.contentsOfDirectory(at: projects,
                                                     includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])
        else { return }
        for dir in dirs {
            let file = dir.appendingPathComponent(sessionId + ".jsonl")
            if fm.fileExists(atPath: file.path) {
                try? fm.removeItem(at: file)
            }
        }
    }
}

/// `account/read` and `account/rateLimits/read` over codex's app-server,
/// in one process.
enum CodexUsageProbe {
    static let accountId = 2
    static let rateLimitsId = 3
    static let accountRequest =
        #"{"jsonrpc":"2.0","id":2,"method":"account/read","params":{}}"#
    static let rateLimitsRequest =
        #"{"jsonrpc":"2.0","id":3,"method":"account/rateLimits/read","params":{}}"#

    struct Outcome {
        var account: [String: Any]?
        var rateLimits: [String: Any]?
        /// False when codex answered nothing at all.
        var available: Bool
    }

    nonisolated static func run(binary: String) async -> Outcome {
        let answers = await CodexAppServerCall.run(
            binary: binary,
            requests: [accountRequest, rateLimitsRequest],
            awaiting: [accountId, rateLimitsId])
        return Outcome(account: answers[accountId],
                       rateLimits: answers[rateLimitsId],
                       available: !answers.isEmpty)
    }
}

/// One request to kimi's own local server: spawn `kimi web` on a free
/// loopback port, read the bearer it prints, call the route, ask it to
/// shut down. Kimi does the OAuth (refresh included) with its own
/// login; the bearer lives in a local variable and dies with the
/// process. Measured: the token line at 0.5 s, the answer at once, a
/// clean exit under a second, nothing touched but kimi's own log.
enum KimiWebServerCall {
    static let startCeiling: TimeInterval = 12
    static let requestCeiling: TimeInterval = 15
    /// The shutdown answers in milliseconds; a server that does not is
    /// stopped by pid a moment later, so this need not be generous.
    static let shutdownCeiling: TimeInterval = 4
    static let usagePath = "/api/v1/oauth/usage?provider=managed:kimi-code"
    static let shutdownPath = "/api/v1/shutdown"

    enum Outcome: Equatable {
        case answered(Data)
        case unavailable(String)
    }

    /// ONE `kimi web` at a time, app-wide. Every start writes
    /// `<home>/server.token` (one file) and an instance record under
    /// `<home>/server/instances/`, and whether a running server keeps
    /// honouring its own token after a second start rewrote the file
    /// is not measured — so the usage read and the Agent Guide's
    /// sign-in, sign-out and probe never overlap. A short caller that
    /// finds the server busy waits `occupancyWait` and then answers
    /// "busy" rather than parking a thread for the length of a login.
    nonisolated private static let occupancy = DispatchSemaphore(value: 1)
    static let occupancyWait: TimeInterval = 20

    nonisolated static func fetchUsage(binary: String, scratchDirectory: URL) async -> Outcome {
        await ShellEnvironment.prepare()
        let environment = AgentRunner.buildEnvironment()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard occupancy.wait(timeout: .now() + occupancyWait) == .success else {
                    continuation.resume(returning: .unavailable(Self.busySentence))
                    return
                }
                defer { occupancy.signal() }
                continuation.resume(returning: drive(binary: binary,
                                                     scratchDirectory: scratchDirectory,
                                                     environment: environment))
            }
        }
    }

    nonisolated private static var busySentence: String {
        String(localized: "The tool's local server is busy with a sign-in. Try again in a moment.",
               comment: "Plan-usage card: kimi's local server is held by the Agent Guide's sign-in flow")
    }

    /// The same server, held open across several requests — the Agent
    /// Guide's device-code sign-in polls it for minutes. Holds the
    /// app-wide occupancy from `start` to `shutdown`; a caller that
    /// cannot get it inside `occupancyWait` gets the busy sentence.
    /// Every request takes the same loopback route as `fetchUsage`,
    /// proxies off.
    final class Session: @unchecked Sendable {
        let port: UInt16
        private let bearer: String
        private let process: Process
        private let masterFD: Int32
        private var finished = false
        private let lock = NSLock()

        fileprivate init(port: UInt16, bearer: String, process: Process, masterFD: Int32) {
            self.port = port
            self.bearer = bearer
            self.process = process
            self.masterFD = masterFD
        }

        /// `drive` runs on the queue that already holds the occupancy,
        /// so it finishes synchronously and leaves the release to its
        /// own `defer`.
        fileprivate var bearerForDrive: String { bearer }

        fileprivate func finishSynchronously() {
            lock.lock()
            let already = finished
            finished = true
            lock.unlock()
            guard !already else { return }
            KimiWebServerCall.finish(process, masterFD: masterFD, bearer: bearer, port: port)
            close(masterFD)
        }

        enum StartOutcome {
            case started(Session)
            /// The server's own words, the busy sentence, or why the
            /// spawn failed.
            case failed(String)
        }

        /// Spawn and read the bearer.
        nonisolated static func start(binary: String, scratchDirectory: URL) async -> StartOutcome {
            await ShellEnvironment.prepare()
            let environment = AgentRunner.buildEnvironment()
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    guard occupancy.wait(timeout: .now() + occupancyWait) == .success else {
                        continuation.resume(returning: .failed(busySentence))
                        return
                    }
                    switch spawn(binary: binary, scratchDirectory: scratchDirectory,
                                 environment: environment) {
                    case .started(let session):
                        session.holdsOccupancy = true
                        continuation.resume(returning: .started(session))
                    case .failed(let why):
                        occupancy.signal()
                        continuation.resume(returning: .failed(why))
                    }
                }
            }
        }

        /// Set once the session owns the app-wide occupancy; `drive`'s
        /// one-shot session never does (its queue holds it).
        fileprivate var holdsOccupancy = false

        /// One request; `body` nil sends no content-type header at all
        /// (kimi refuses a JSON content-type with an empty body).
        nonisolated func request(method: String, path: String,
                                 body: [String: Any]? = nil,
                                 ceiling: TimeInterval = KimiWebServerCall.requestCeiling) async -> Result<Data, Error> {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    // Keep the PTY drained between requests: a server
                    // that fills its terminal buffer blocks in write()
                    // and stops answering, and a login polls for
                    // minutes.
                    var sink = Data()
                    _ = KimiWebServerCall.drain(self.masterFD, into: &sink, wait: 0)
                    continuation.resume(returning: KimiWebServerCall.request(
                        port: self.port, path: path, method: method, bearer: self.bearer,
                        body: body, ceiling: ceiling))
                }
            }
        }

        /// Ask the server to stop, reap it, release the occupancy.
        /// Idempotent.
        nonisolated func shutdown() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    self.finishAndRelease()
                    continuation.resume()
                }
            }
        }

        private func finishAndRelease() {
            lock.lock()
            let already = finished
            finished = true
            let release = holdsOccupancy
            lock.unlock()
            guard !already else { return }
            KimiWebServerCall.finish(process, masterFD: masterFD, bearer: bearer, port: port)
            close(masterFD)
            if release { KimiWebServerCall.occupancy.signal() }
        }

        deinit {
            // A session dropped without `shutdown` must not strand the
            // occupancy or the process.
            finishAndRelease()
        }
    }

    /// The measured start: a free loopback port, a PTY for stdout (a
    /// pipe block-buffers the token line past the ceiling — measured,
    /// the line never arrived within 30 s), the bearer read off the
    /// `#token=` line. Shared by `drive` and `Session`.
    nonisolated private static func spawn(binary: String, scratchDirectory: URL,
                                          environment: [String: String]) -> Session.StartOutcome {
        guard let port = freePort() else { return .failed("no free port") }
        var masterFD: Int32 = 0
        var slaveFD: Int32 = 0
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            return .failed("openpty failed")
        }
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["web", "--no-open", "--port", String(port)]
        p.environment = environment
        p.currentDirectoryURL = scratchDirectory
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = slave
        p.standardError = slave
        do {
            try p.run()
        } catch {
            close(slaveFD)
            close(masterFD)
            return .failed(error.localizedDescription)
        }
        close(slaveFD)

        var received = Data()
        var bearer: String? = nil
        let startDeadline = Date().addingTimeInterval(startCeiling)
        while bearer == nil, Date() < startDeadline {
            guard drain(masterFD, into: &received, wait: 250) else { break }
            if let found = token(in: String(decoding: received, as: UTF8.self), port: port) {
                bearer = found
            }
            if !p.isRunning && bearer == nil { break }
        }
        guard let bearer else {
            let said = String(decoding: received, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            finish(p, masterFD: masterFD, bearer: nil, port: port)
            close(masterFD)
            return .failed(said.isEmpty ? "kimi web printed no token" : said)
        }
        return .started(Session(port: port, bearer: bearer, process: p, masterFD: masterFD))
    }

    /// `Kimi server: http://127.0.0.1:N/#token=<bearer>` — the bearer,
    /// taken only from a line naming the port SipAI asked for, and only
    /// once that line is complete.
    ///
    /// The port is found by binding 0 and closing (`freePort`), so
    /// another process can take it before kimi binds. A kimi that then
    /// listened elsewhere would print its own port — and the bearer,
    /// which drives the user's kimi, must not go to whatever holds the
    /// one asked for. A bearer is also read only up to the end of its
    /// line: output arrives in pieces, and one cut at a read boundary
    /// would be sent short.
    nonisolated static func token(in text: String, port: UInt16) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        var cursor = text.startIndex
        while let range = text.range(of: "#token=", range: cursor..<text.endIndex) {
            cursor = range.upperBound
            let lineStart = text[..<range.lowerBound].lastIndex(where: \.isNewline)
                .map { text.index(after: $0) } ?? text.startIndex
            let address = text[lineStart..<range.lowerBound]
            guard address.hasSuffix("//127.0.0.1:\(port)/")
                    || address.hasSuffix("//localhost:\(port)/") else { continue }
            var token = ""
            var ended = false
            for scalar in text[range.upperBound...].unicodeScalars {
                guard allowed.contains(scalar) else { ended = true; break }
                token.unicodeScalars.append(scalar)
            }
            return ended && !token.isEmpty ? token : nil
        }
        return nil
    }

    /// A port the kernel says is free right now: bind 0, read back,
    /// close. A loser of the race between this and kimi's own bind
    /// shows as no token line for this port (`token(in:port:)`), and the
    /// call answers `.unavailable`.
    nonisolated static func freePort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &out) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        guard named == 0 else { return nil }
        let port = UInt16(bigEndian: out.sin_port)
        return port > 0 ? port : nil
    }

    nonisolated private static func drive(binary: String, scratchDirectory: URL,
                                          environment: [String: String]) -> Outcome {
        // The spawn is shared with `Session` (same PTY, same token
        // read); this one-shot path asks its single question and ends
        // the server on the queue that already holds the occupancy.
        let session: Session
        switch spawn(binary: binary, scratchDirectory: scratchDirectory,
                     environment: environment) {
        case .failed(let why): return .unavailable(why)
        case .started(let started): session = started
        }
        let answer = request(port: session.port, path: usagePath, method: "GET",
                             bearer: session.bearerForDrive)
        session.finishSynchronously()
        switch answer {
        case .success(let data): return .answered(data)
        case .failure(let error): return .unavailable(error.localizedDescription)
        }
    }

    /// Ask the server to stop, wait for it, escalate only at the
    /// ceiling. A clean shutdown is what removes kimi's own instance
    /// record; a kill leaves it behind.
    nonisolated fileprivate static func finish(_ p: Process, masterFD: Int32,
                                           bearer: String?, port: UInt16) {
        if let bearer, p.isRunning {
            _ = request(port: port, path: shutdownPath, method: "POST", bearer: bearer,
                        ceiling: shutdownCeiling)
        }
        var sink = Data()
        let until = Date().addingTimeInterval(AgentCLIProbe.terminateGrace)
        while p.isRunning && Date() < until {
            _ = drain(masterFD, into: &sink, wait: 100)
            if sink.count > 64 * 1024 { sink.removeAll(keepingCapacity: true) }
        }
        AgentCLIProbe.stop(p)
        p.waitUntilExit()
    }

    /// One poll + read on the PTY master. False on end-of-file or an
    /// error that is not a retry; true otherwise (including a timeout
    /// with nothing to read).
    nonisolated fileprivate static func drain(_ fd: Int32, into data: inout Data,
                                              wait: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, wait)
        if ready < 0 { return errno == EINTR }
        if ready == 0 { return true }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let (count, err): (Int, Int32) = buffer.withUnsafeMutableBytes { raw in
            let n = read(fd, raw.baseAddress, raw.count)
            return (n, n < 0 ? errno : 0)
        }
        if count < 0 { return err == EINTR || err == EAGAIN }
        if count == 0 { return false }
        data.append(contentsOf: buffer[0..<count])
        if data.count > 256 * 1024 { data.removeFirst(data.count - 64 * 1024) }
        return true
    }

    /// One loopback request, proxies OFF: the system proxy — SOCKS on
    /// some machines — is applied by CFNetwork to every URLSession
    /// otherwise, and a server on 127.0.0.1 is the one thing it must
    /// never see.
    nonisolated fileprivate static func request(port: UInt16, path: String,
                                                method: String, bearer: String,
                                                body: [String: Any]? = nil,
                                                ceiling: TimeInterval = requestCeiling)
    -> Result<Data, Error> {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            return .failure(URLError(.badURL))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = ceiling
        configuration.timeoutIntervalForResource = ceiling
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // A body sends JSON; no body sends NO content-type — kimi
        // refuses a JSON content-type on an empty body (measured on
        // its DELETE /oauth/login).
        if let body, let encoded = try? JSONSerialization.data(withJSONObject: body) {
            req.httpBody = encoded
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<Data, Error> = .failure(URLError(.timedOut))
        let task = session.dataTask(with: req) { data, response, error in
            if let error {
                outcome = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                // Kimi answers a refusal as `{"code":…,"msg":…}` on a
                // 4xx, and the sentence is the whole diagnosis ("Cannot
                // set session disabled tools: agent profile is not
                // bound"). Carried on the error so a caller can show
                // kimi's words rather than the status code alone.
                var text = "HTTP \(http.statusCode)"
                if let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let msg = obj["msg"] as? String, !msg.isEmpty {
                    text += ": " + msg
                }
                outcome = .failure(URLError(.badServerResponse,
                                            userInfo: [NSLocalizedDescriptionKey: text]))
            } else {
                outcome = .success(data ?? Data())
            }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + ceiling + 1) == .timedOut {
            task.cancel()
        }
        return outcome
    }
}

// MARK: - The monitor

/// What the toolbar icon and the window read. `refreshAccounts` is the
/// file layer (cheap, on the detection tick); `refresh` is the probe
/// layer (three CLI processes, on open).
@MainActor
final class UsageMonitor: ObservableObject {
    static let shared = UsageMonitor()

    static let verdictsDefaultsKey = PlanAccountVerdictStore.defaultsKey

    /// The verdict in force per INSTALLED agent.
    @Published private(set) var accounts: [String: PlanAccountKind] = [:]
    /// True when some installed agent is on a plan — the icon.
    @Published private(set) var showsIcon = false
    /// One card per agent on a plan, in registry order.
    @Published private(set) var cards: [PlanUsageCard] = []
    @Published private(set) var refreshing = false
    /// When the last refresh finished, or the age of the oldest seed
    /// shown before one has.
    @Published private(set) var updatedAt: Date?

    private var installed: [AgentInfo] = []
    /// The agents the icon and the cards may DESCRIBE — the listed
    /// ones. Distinct from `installed`, which every VERDICT read still
    /// covers: the file-layer read is what decides whether an agent is
    /// signed in, so skipping it for an agent that is not shown would
    /// mean a signed-out or hidden agent could never come back. nil
    /// until the manager says otherwise, meaning every installed agent;
    /// written by `setShown` alone.
    private var shown: Set<String>? = nil
    private var fileFingerprints: [String: String] = [:]
    private var fileVerdicts: [String: PlanAccountKind] = [:]
    /// A sign-out reading held for one more pass, by the fingerprint it
    /// was read under — see `refreshAccounts`.
    private var pendingSignOut: [String: String] = [:]
    private var probeVerdicts: [String: PlanAccountVerdictStore.Entry]
    private var figures: [String: PlanUsageCard] = [:]
    private var accountsPass: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init() {
        probeVerdicts = PlanAccountVerdictStore.load()
    }

    // MARK: File layer

    /// Re-read the account kind of every installed agent. Runs from
    /// `AgentManager.reload(config:)` — launch and the 5 s tick — so a
    /// `login` or `logout` in a terminal flips the icon within seconds.
    /// The reads run off the MainActor; only a changed digest publishes.
    func refreshAccounts(installed: [AgentInfo]) {
        // An agent that came or went changes the verdict set with no
        // file changing under it — recompute for that at once. (The
        // shown set has its own writer, `setShown`.)
        let installedChanged = installed.map(\.key) != self.installed.map(\.key)
        self.installed = installed
        if installedChanged { recompute() }
        let keys = installed.map(\.key)
        let known = fileFingerprints
        accountsPass?.cancel()
        accountsPass = Task.detached(priority: .utility) { [weak self] in
            var fresh: [String: (fingerprint: String, verdict: PlanAccountKind)] = [:]
            for key in keys {
                let reading = PlanAccountDetector.read(agentKey: key)
                if known[key] == reading.fingerprint { continue }
                fresh[key] = (reading.fingerprint, reading.verdict)
            }
            // Nothing moved: no hop, no publish — this runs every 5 s.
            guard !fresh.isEmpty, !Task.isCancelled else { return }
            let update = fresh
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (key, value) in update {
                    // A sign-out read off the files is taken on the
                    // SECOND consecutive reading, never the first. A CLI
                    // rewriting its auth file can be caught between the
                    // truncate and the write, and one such reading would
                    // unlist the agent — close its open page mid-turn,
                    // idle its tasks — for a tick. The held fingerprint
                    // is not recorded, so the next pass reads the file
                    // again: the same reading confirms, any other
                    // replaces. A real sign-out costs one tick.
                    if value.verdict == .signedOut,
                       let previous = self.fileVerdicts[key], previous.isSignedIn,
                       self.pendingSignOut[key] != value.fingerprint {
                        self.pendingSignOut[key] = value.fingerprint
                        continue
                    }
                    self.pendingSignOut[key] = nil
                    self.fileFingerprints[key] = value.fingerprint
                    self.fileVerdicts[key] = value.verdict
                }
                self.recompute()
            }
        }
    }

    /// Only the shown set moved (a hide, a sign-out): the icon and the
    /// cards follow, nothing is re-read.
    func setShown(_ keys: Set<String>) {
        guard shown != keys else { return }
        shown = keys
        recompute()
    }

    /// The same read as `refreshAccounts`, done NOW on the caller's
    /// thread — for the first pass at launch, so the first frame the
    /// sidebar draws already knows who is signed in rather than showing
    /// no agent for the length of a detached read. Small files
    /// (`~/.claude.json` is tens of KB; the other two are a few KB), a
    /// handful of milliseconds, once.
    func readAccountsNow(installed: [AgentInfo]) {
        self.installed = installed
        for agent in installed {
            let reading = PlanAccountDetector.read(agentKey: agent.key)
            fileFingerprints[agent.key] = reading.fingerprint
            fileVerdicts[agent.key] = reading.verdict
        }
        recompute()
    }

    /// The Agent Guide's structured probe answered (`claude auth
    /// status --json`, codex `account/read`, kimi `/oauth/userinfo`).
    /// Recorded exactly the way the usage probes record theirs — under
    /// the file fingerprint it was measured over, persisted, and in
    /// force while those files stand — so presence follows it at once
    /// and survives a relaunch. `.unknown` records nothing.
    func noteProbeVerdict(agentKey: String, kind: PlanAccountKind, fingerprint: String) {
        guard kind != .unknown else { return }
        probeVerdicts[agentKey] = PlanAccountVerdictStore.Entry(kind: kind,
                                                                fingerprint: fingerprint)
        PlanAccountVerdictStore.save(probeVerdicts)
        if kind == .apiKey || kind == .signedOut { figures[agentKey] = nil }
        // The file layer may not have read since the sign-in landed;
        // its digest is what the probe verdict is keyed to.
        let reading = PlanAccountDetector.read(agentKey: agentKey)
        fileFingerprints[agentKey] = reading.fingerprint
        fileVerdicts[agentKey] = reading.verdict
        recompute()
    }

    /// Combine the layers and publish.
    private func recompute() {
        var next: [String: PlanAccountKind] = [:]
        for agent in installed {
            guard let fingerprint = fileFingerprints[agent.key],
                  let file = fileVerdicts[agent.key] else { continue }
            next[agent.key] = PlanAccountDetector.effective(
                file: file, probe: probeVerdicts[agent.key], fingerprint: fingerprint)
        }
        if next != accounts { accounts = next }
        // The icon and the cards describe shown agents only.
        let icon = next.contains { key, kind in kind.isPlan && isShown(key) }
        if icon != showsIcon { showsIcon = icon }
        rebuildCards()
    }

    private func isShown(_ key: String) -> Bool {
        shown?.contains(key) ?? true
    }

    private func rebuildCards() {
        var next: [PlanUsageCard] = []
        for agent in installed where isShown(agent.key) {
            guard let kind = accounts[agent.key], kind.isPlan else { continue }
            var card = figures[agent.key]
                ?? PlanUsageCard(agentKey: agent.key, defaultName: agent.name)
            card.planName = kind.planName
            next.append(card)
        }
        if next != cards { cards = next }
    }

    /// The update monitor saw a new binary: its old answer describes
    /// the binary that was replaced. The file layer answers until the
    /// next open re-probes.
    func noteBinaryChanged(agentKey: String) {
        probeVerdicts[agentKey] = nil
        PlanAccountVerdictStore.save(probeVerdicts)
        figures[agentKey] = nil
        recompute()
    }

    /// Factory reset: UserDefaults is wiped by the caller; drop the
    /// in-memory copy too.
    func forgetVerdicts() {
        probeVerdicts = [:]
        figures = [:]
        recompute()
    }

    // MARK: Probe layer

    /// Ask every plan (or unknown) agent, concurrently. Single-
    /// occupancy: a click during a refresh does nothing.
    func refresh() {
        guard refreshTask == nil else { return }
        refreshing = true
        // Previous figures dim for the length of the read, and a
        // failure from the last read no longer describes this one.
        figures = figures.mapValues { card in
            var next = card
            next.failure = nil
            if next.hasFigures { next.stale = true }
            return next
        }
        rebuildCards()
        let targets = installed.filter { agent in
            guard isShown(agent.key), let kind = accounts[agent.key] else { return false }
            return kind.isPlan || kind == .unknown
        }
        refreshTask = Task { [weak self] in
            let scratch = await Task.detached(priority: .utility) {
                PlanUsageScratch.directory
            }.value
            // A tool whose binary is away for the moment (SipAI is
            // replacing it) is not asked — and a pass that asked nobody
            // is not a reading: nothing is stamped and nothing un-dims.
            let probed = targets.compactMap { agent -> (agent: AgentInfo, binary: String)? in
                AgentManager.binaryPath(for: agent.key).map { (agent: agent, binary: $0) }
            }
            await withTaskGroup(of: Void.self) { group in
                for (agent, binary) in probed {
                    group.addTask { [weak self] in
                        await self?.probe(agent: agent, binary: binary, scratch: scratch)
                    }
                }
            }
            guard let self else { return }
            self.refreshing = false
            if !probed.isEmpty {
                self.updatedAt = Date()
                // Figures a failed read kept stay dimmed under its
                // message; everything that answered is current.
                self.figures = self.figures.mapValues { card in
                    var next = card
                    next.stale = next.failure != nil && next.hasFigures
                    return next
                }
            }
            self.rebuildCards()
            self.refreshTask = nil
        }
    }

    private func probe(agent: AgentInfo, binary: String, scratch: URL) async {
        // Claude's last-known figures land first, from the cache the
        // probe is about to refresh — dimmed, with their own stamp.
        if agent.key == "claude_code", !(figures[agent.key]?.hasFigures ?? false) {
            let file = PlanAccountDetector.claudeConfigFile
            let seed = await Task.detached(priority: .utility) {
                (try? Data(contentsOf: file)).flatMap(ClaudeUsageCache.read)
            }.value
            if let seed, !seed.rows.isEmpty, !Task.isCancelled {
                var card = PlanUsageCard(agentKey: agent.key, defaultName: agent.name)
                card.rows = seed.rows
                card.notes = seed.credits.map { [$0] } ?? []
                card.updatedAt = seed.fetchedAt
                card.stale = true
                land(card, verdict: nil, fingerprint: nil)
            }
        }
        var card = PlanUsageCard(agentKey: agent.key, defaultName: agent.name)
        var verdict: PlanAccountKind = .unknown
        switch agent.key {
        case "claude_code":
            let outcome = await ClaudeUsageProbe.run(binary: binary, scratchDirectory: scratch)
            if let text = outcome.text {
                let report = ClaudeUsageText.parse(text)
                switch report.kind {
                case .plan: verdict = .plan(name: fileVerdicts[agent.key]?.planName)
                case .apiKey: verdict = .apiKey
                case .unknown: verdict = .unknown
                }
                card.rows = report.rows
                if report.rows.isEmpty, report.kind != .apiKey { card.rawText = text }
                // The credits line rides the cache the probe just
                // refreshed; the text has no line for it.
                let file = PlanAccountDetector.claudeConfigFile
                let seed = await Task.detached(priority: .utility) {
                    (try? Data(contentsOf: file)).flatMap(ClaudeUsageCache.read)
                }.value
                if let credits = seed?.credits { card.notes = [credits] }
            } else {
                card.failure = outcome.errorText
                card = keepingFigures(card)
            }
        case "codex":
            let outcome = await CodexUsageProbe.run(binary: binary)
            let report = CodexUsageAnswer.parse(account: outcome.account,
                                                rateLimits: outcome.rateLimits)
            verdict = report.kind
            card.rows = report.rows
            card.notes = report.notes
            if let failure = report.failure {
                card.failure = failure
            } else if !report.answered, report.kind.isPlan || report.kind == .unknown {
                // A plan account with no limits and no refusal: nothing
                // arrived inside the ceiling. Silence would draw a card
                // with a title and nothing under it.
                card.failure = Self.didNotAnswer
            }
            if card.failure != nil { card = keepingFigures(card) }
        case "kimi":
            let outcome = await KimiWebServerCall.fetchUsage(binary: binary,
                                                             scratchDirectory: scratch)
            switch outcome {
            case .answered(let body):
                let report = KimiUsageAnswer.parse(body: body)
                switch report.kind {
                case .ok:
                    verdict = .plan(name: nil)
                    card.rows = report.rows
                    card.notes = report.notes
                case .error:
                    card.failure = report.failure
                    card = keepingFigures(card)
                case .malformed:
                    card.failure = String(localized: "The answer was in a shape SipAI does not read.",
                                          comment: "Plan-usage card: the agent's usage answer did not parse")
                    card = keepingFigures(card)
                }
            case .unavailable(let why):
                card.failure = why
                card = keepingFigures(card)
            }
        default:
            return
        }
        // Fresh figures are stamped now; figures a failure kept carry
        // the stamp of the read that produced them, and stay dimmed.
        if card.failure == nil {
            card.updatedAt = Date()
            card.stale = false
        }
        // The digest of the files as they stand once the CLI has
        // answered — the probe itself may have rewritten them.
        let key = agent.key
        let fingerprint = await Task.detached(priority: .utility) {
            PlanAccountDetector.fingerprint(agentKey: key)
        }.value
        land(card, verdict: verdict, fingerprint: fingerprint)
    }

    private static var didNotAnswer: String {
        String(localized: "The command-line tool did not answer.",
               comment: "Plan-usage card: the agent's own process produced no answer")
    }

    /// A failed read keeps the previous figures under its message —
    /// dimmed, and stamped with the read that produced them.
    private func keepingFigures(_ card: PlanUsageCard) -> PlanUsageCard {
        guard let previous = figures[card.agentKey], previous.hasFigures else { return card }
        var kept = previous
        kept.failure = card.failure
        kept.stale = true
        return kept
    }

    private func land(_ card: PlanUsageCard, verdict: PlanAccountKind?, fingerprint: String?) {
        // An agent the probe found off a plan keeps no figures: its
        // card leaves `cards` in `recompute`, and a later login must
        // not resurrect an empty shell of it.
        if let verdict, verdict == .apiKey || verdict == .signedOut {
            figures[card.agentKey] = nil
        } else {
            figures[card.agentKey] = card
        }
        if let verdict, let fingerprint, verdict != .unknown {
            probeVerdicts[card.agentKey] = PlanAccountVerdictStore.Entry(
                kind: verdict, fingerprint: fingerprint)
            PlanAccountVerdictStore.save(probeVerdicts)
        }
        // `recompute` rebuilds `cards` from `figures`, so the landing
        // publishes exactly once.
        recompute()
    }
}
