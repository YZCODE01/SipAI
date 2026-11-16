// PlanUsage.swift
// What each agent CLI's PLAN reports (a subscription's rate-limit
// windows), asked of the CLI itself — for the toolbar's plan-usage
// window and for Settings → Usage, which shows the same figures with
// what else each tool says about its account, each tool's own usage
// page, and codex's own way to use a limit reset. API usage has no
// figures here: no CLI reports an account-level figure for an API key,
// so an agent on a key is sent to its provider's page instead.
//
// Three rules hold the file together:
//
//  * The CLI answers, SipAI never holds a token. Claude answers its own
//    `/usage` command under `-p`; codex answers JSON-RPC calls over its
//    app-server; kimi answers over the `/oauth/usage` and `/oauth/region`
//    routes of its own local web server. Each runs as the CLI's own
//    process with the CLI's own login. Nothing here reads a keychain
//    item, a `credentials/` file or an auth token, and nothing calls a
//    vendor endpoint directly.
//  * Whether an agent is on a plan at all is decided in two layers.
//    A FILE layer (a few stats and a small read, no spawn) answers at
//    launch, on the 5 s detection tick and after a CLI update, from
//    files SipAI already reads: claude's `~/.claude.json`, codex's
//    `auth.json`, kimi's `config.toml` beside its token file. A PROBE
//    layer answers definitively on every window open (and on a visit to
//    Settings → Usage, once the figures are a minute old) and is
//    persisted with a fingerprint of the files it was measured over, so
//    it outranks the file layer exactly until those files change.
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
    /// Kimi's monthly limit only: how much of it Kimi and Kimi Code each
    /// used, drawn on a line under the row as kimi's own `/usage` draws it.
    var split: PlanUsageSplit? = nil
    /// The CLI's own grade of the row, where it states one (claude's
    /// server sends a `severity` per row and says a client never grades
    /// a row itself). nil leaves the bar to SipAI's own rule.
    var severity: PlanUsageSeverity? = nil

    /// How full the bar is, 0…1, or nil when nothing can be drawn.
    var fraction: Double? {
        if let percent { return min(1, max(0, Double(percent) / 100)) }
        if let used, let limit, limit > 0 {
            return min(1, max(0, Double(used) / Double(limit)))
        }
        return nil
    }
}

/// A row's grade, in claude's server's words: what colours the bar.
enum PlanUsageSeverity: String, Equatable {
    case normal, warning, critical
}

/// Kimi's monthly limit, split the way kimi's own `/usage` splits it:
/// "kimi 30% · code 15%".
struct PlanUsageSplit: Equatable {
    var kimiPercent: Int
    var codePercent: Int
}

/// A line under a card's rows: something the plan reports that is not
/// a window.
enum PlanUsageNote: Equatable {
    /// Claude's usage credits — the plan's overflow budget.
    case usageCredits(usedMinor: Int, limitMinor: Int, exponent: Int,
                      currency: String, enabled: Bool, disabledReason: String?)
    /// Kimi's Extra Usage wallet, in cents, in the three figures kimi's
    /// own `/usage` shows: used this month, the monthly limit (nil when
    /// none is set), the balance.
    case extraUsage(usedCents: Int, limitCents: Int?, balanceCents: Int, currency: String)
    /// Kimi answered and its answer holds nothing to draw — said in
    /// kimi's words rather than left as an empty card.
    case noUsageData
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
    /// Claude Code's own "What's contributing to your limits usage?"
    /// block, whole — its words about the sessions on the Mac it runs on.
    /// Settings → Usage lays it out (`ClaudeContributing`) and never
    /// rewords it.
    var contributing: String? = nil
    /// What codex's answer says about the account beyond its windows.
    var codex: CodexAccountDetail? = nil
    /// Kimi's site, as kimi's own local server names it (`/oauth/region`):
    /// which of its two sites the membership's console is on.
    var kimiRegion: String? = nil

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

    /// The text's rows with what the structured report adds: each row's
    /// reset as a date — so it reads in the Mac's own language — and the
    /// server's grade. The text stays the authority for the labels and
    /// the percents; the report is laid on only when it is the same rows
    /// in the same order (the text is printed from that list), else it
    /// adds nothing. A text with no rows takes the report's, labelled as
    /// claude's text labels the same kinds.
    nonisolated static func merging(_ rows: [PlanUsageRow],
                                    report: ClaudeUsageReport?) -> [PlanUsageRow] {
        guard let report, !report.limits.isEmpty else { return rows }
        if rows.isEmpty {
            return report.limits.map { limit in
                PlanUsageRow(label: label(for: limit), window: nil,
                             percent: min(100, max(0, limit.percent)),
                             used: nil, limit: nil, resetText: nil,
                             resetDate: limit.resetsAt, severity: limit.severity)
            }
        }
        guard rows.count == report.limits.count,
              zip(rows, report.limits).allSatisfy({ $0.percent == $1.percent })
        else { return rows }
        return zip(rows, report.limits).map { row, limit in
            var next = row
            if let date = limit.resetsAt {
                next.resetDate = date
                next.resetText = nil
            }
            next.severity = limit.severity
            return next
        }
    }

    /// The label claude's own text gives a kind of row. A kind it does
    /// not print answers its scope's name, else the kind itself.
    nonisolated private static func label(for limit: ClaudeUsageReport.Limit) -> String {
        switch limit.kind {
        case "session": return "Current session"
        case "weekly_all": return "Current week (all models)"
        case "weekly_scoped":
            if let name = limit.scopeName { return "Current week (\(name))" }
            return limit.kind
        default:
            return limit.scopeName ?? limit.kind
        }
    }

    /// Claude Code's "What's contributing to your limits usage?" block,
    /// from its heading to the end of the answer — claude's words about
    /// the sessions on the Mac it runs on, kept whole. nil when the answer has
    /// none (an API key, an older claude).
    nonisolated static func contributing(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            let line = $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\u{2019}", with: "'")
            return line.hasPrefix("What's contributing")
        }) else { return nil }
        let block = lines[start...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return block.isEmpty ? nil : block
    }
}

/// Claude Code's "What's contributing to your limits usage?" block, read
/// for its layout alone — every word in it stays claude's. Claude prints
/// it from one template: the heading, its note, then a paragraph per
/// period, "Last 24h · 438 requests · 4 sessions" over indented lines
/// that are either "94% of your usage was at >150k context" or "Top
/// subagents: Explore 36%, Plan 4%, +2 more". A block in any other shape
/// answers nil, and the page shows claude's text as it came — a reworded
/// line must never be dropped from the page.
struct ClaudeContributing: Equatable {
    struct Period: Equatable {
        var title: String
        /// What follows the title on its line: "438 requests · 4 sessions".
        var detail: String?
        var rows: [Row]
    }

    enum Row: Equatable {
        /// "94% of your usage was at >150k context": the percent, and the
        /// rest of claude's sentence.
        case share(percent: Int, text: String)
        /// "Top subagents: Explore 36%, Plan 4%, +2 more".
        case top(title: String, items: [Item], more: String?)
    }

    struct Item: Equatable {
        var name: String
        var percent: Int
    }

    var heading: String
    /// The lines under the heading: claude's note, or why it shows nothing.
    var notes: [String]
    var periods: [Period]

    nonisolated static func parse(_ block: String) -> ClaudeContributing? {
        let lines = block.components(separatedBy: .newlines)
        guard let heading = lines.first?.trimmingCharacters(in: .whitespaces), !heading.isEmpty
        else { return nil }
        func indented(_ line: String) -> Bool { line.hasPrefix(" ") || line.hasPrefix("\t") }
        func blank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

        // The note is what follows the heading before the first blank line.
        var rest = lines.dropFirst()
        var notes: [String] = []
        while let line = rest.first, !blank(line) {
            guard !indented(line) else { return nil }
            notes.append(line.trimmingCharacters(in: .whitespaces))
            rest = rest.dropFirst()
        }
        var paragraphs: [[String]] = []
        var paragraph: [String] = []
        for line in rest {
            if blank(line) {
                if !paragraph.isEmpty { paragraphs.append(paragraph) }
                paragraph = []
            } else {
                paragraph.append(line)
            }
        }
        if !paragraph.isEmpty { paragraphs.append(paragraph) }

        // Every paragraph after it is a period: its line, then its rows.
        var periods: [Period] = []
        for lines in paragraphs {
            guard !indented(lines[0]), lines.count > 1, lines.dropFirst().allSatisfy(indented) else { return nil }
            var rows: [Row] = []
            for line in lines.dropFirst() {
                guard let row = row(line.trimmingCharacters(in: .whitespaces)) else { return nil }
                rows.append(row)
            }
            let header = lines[0].trimmingCharacters(in: .whitespaces)
            if let dot = header.range(of: " · ") {
                periods.append(Period(title: String(header[..<dot.lowerBound]),
                                      detail: String(header[dot.upperBound...]), rows: rows))
            } else {
                periods.append(Period(title: header, detail: nil, rows: rows))
            }
        }
        return ClaudeContributing(heading: heading, notes: notes, periods: periods)
    }

    nonisolated private static func row(_ line: String) -> Row? {
        if let (percent, rest) = leadingPercent(line) {
            return .share(percent: percent, text: rest)
        }
        guard let colon = line.range(of: ": ") else { return nil }
        let title = String(line[..<colon.lowerBound])
        guard !title.isEmpty, !title.contains("%") else { return nil }
        var items: [Item] = []
        var more: String?
        let parts = line[colon.upperBound...].components(separatedBy: ", ")
        for (index, part) in parts.enumerated() {
            if index == parts.count - 1, index > 0, isMore(part) {
                more = part
            } else if let (name, percent) = trailingPercent(part) {
                items.append(Item(name: name, percent: percent))
            } else {
                return nil
            }
        }
        return items.isEmpty ? nil : .top(title: title, items: items, more: more)
    }

    /// "94% of …" → (94, "of …").
    nonisolated private static func leadingPercent(_ line: String) -> (Int, String)? {
        guard let percentSign = line.firstIndex(of: "%") else { return nil }
        let digits = line[..<percentSign]
        guard (1...3).contains(digits.count), digits.allSatisfy(\.isASCIIDigit),
              let value = Int(digits), value <= 100 else { return nil }
        let rest = line[line.index(after: percentSign)...]
        guard rest.hasPrefix(" ") else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (value, text)
    }

    /// "Explore 36%" → ("Explore", 36).
    nonisolated private static func trailingPercent(_ part: String) -> (String, Int)? {
        guard part.hasSuffix("%"), let space = part.lastIndex(of: " ") else { return nil }
        let name = String(part[..<space])
        let digits = part[part.index(after: space)..<part.index(before: part.endIndex)]
        guard !name.isEmpty, (1...3).contains(digits.count), digits.allSatisfy(\.isASCIIDigit),
              let value = Int(digits), value <= 100 else { return nil }
        return (name, value)
    }

    /// "+2 more" — the count past the eight claude names.
    nonisolated private static func isMore(_ part: String) -> Bool {
        guard part.hasPrefix("+"), part.hasSuffix(" more") else { return false }
        let count = part.dropFirst().dropLast(" more".count)
        return !count.isEmpty && count.allSatisfy(\.isASCIIDigit)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: - Claude: the structured report

/// `usage_report` on the record that answers `/usage` under
/// `--output-format stream-json --verbose`: the server's rows as sent —
/// claude's own description: "which meters apply, their scope, labels,
/// severity and order are the server's, so a client renders them
/// verbatim". Read beside the text, never instead of it: it is
/// undocumented, and an older claude sends none.
struct ClaudeUsageReport: Equatable {
    struct Limit: Equatable {
        /// `session`, `weekly_all`, `weekly_scoped` — what a row IS.
        var kind: String
        var percent: Int
        var resetsAt: Date?
        var severity: PlanUsageSeverity?
        /// The model (or surface) a scoped row is for, by the server's
        /// display name.
        var scopeName: String?
    }

    var limits: [Limit]

    nonisolated static func parse(_ report: [String: Any]) -> ClaudeUsageReport? {
        guard let rateLimits = report["rate_limits"] as? [String: Any],
              let rows = rateLimits["limits"] as? [[String: Any]] else { return nil }
        let limits = rows.compactMap { row -> Limit? in
            guard let kind = row["kind"] as? String,
                  let percent = (row["percent"] as? NSNumber)?.doubleValue,
                  percent.isFinite else { return nil }
            let scope = row["scope"] as? [String: Any]
            let name = ((scope?["model"] as? [String: Any])?["display_name"] as? String)
                ?? ((scope?["surface"] as? [String: Any])?["display_name"] as? String)
            return Limit(kind: kind,
                         percent: Int(percent.rounded()),
                         resetsAt: (row["resets_at"] as? String).flatMap(ClaudeUsageCache.isoDate),
                         severity: (row["severity"] as? String).flatMap(PlanUsageSeverity.init(rawValue:)),
                         scopeName: name.flatMap { $0.isEmpty ? nil : $0 })
        }
        return ClaudeUsageReport(limits: limits)
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
        /// The account's credits, spend cap, reached limit and resets.
        var detail: CodexAccountDetail? = nil
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
        return Report(kind: .plan(name: planName), rows: rows, notes: [],
                      failure: nil, answered: true,
                      detail: detail(of: result))
    }

    /// The account block (`rateLimits`) and the resets
    /// (`rateLimitResetCredits`) beyond the windows.
    nonisolated private static func detail(of result: [String: Any]) -> CodexAccountDetail {
        var detail = CodexAccountDetail()
        let limits = result["rateLimits"] as? [String: Any]
        if let credits = limits?["credits"] as? [String: Any] {
            detail.unlimited = (credits["unlimited"] as? Bool) ?? false
            if (credits["hasCredits"] as? Bool) == true, !detail.unlimited,
               let balance = credits["balance"] as? String, !balance.isEmpty {
                detail.balance = balance
            }
        }
        if let cap = limits?["individualLimit"] as? [String: Any],
           let limit = cap["limit"] as? String, let used = cap["used"] as? String {
            let remaining = (cap["remainingPercent"] as? NSNumber)?.doubleValue ?? 0
            let resets = (cap["resetsAt"] as? NSNumber)?.doubleValue
            detail.spendCap = CodexSpendCap(
                limit: limit, used: used,
                remainingPercent: remaining.isFinite ? Int(min(100, max(0, remaining)).rounded()) : 0,
                resetsAt: resets.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
        }
        if let reached = limits?["rateLimitReachedType"] as? String, !reached.isEmpty {
            detail.reached = reached
        }
        if let summary = result["rateLimitResetCredits"] as? [String: Any] {
            detail.resetsAvailable = max(0, (summary["availableCount"] as? NSNumber)?.intValue ?? 0)
            if let list = summary["credits"] as? [[String: Any]] {
                detail.resets = list.compactMap { credit in
                    guard let id = credit["id"] as? String, !id.isEmpty,
                          (credit["status"] as? String) == "available" else { return nil }
                    let expires = (credit["expiresAt"] as? NSNumber)?.doubleValue
                    return CodexResetCredit(
                        id: id,
                        title: (credit["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                        description: (credit["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                        expiresAt: expires.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
                }
            }
        }
        return detail
    }

    /// Why usage stopped, in codex's own words for each value of
    /// `rateLimitReachedType` (its terminal's sentences). A value codex
    /// has not used yet answers nil: the rows already show the limit,
    /// and a guessed reason would be worse than none.
    nonisolated static func reachedSentence(_ type: String) -> String? {
        switch type {
        case "rate_limit_reached":
            return String(localized: "You've hit your usage limit.",
                          comment: "Settings → Usage: Codex's own sentence when a usage limit is reached")
        case "workspace_owner_credits_depleted":
            return String(localized: "Your workspace is out of credits. Add credits to continue.",
                          comment: "Settings → Usage: Codex's own sentence when the workspace owner's credits are used up")
        case "workspace_member_credits_depleted":
            return String(localized: "Your workspace is out of credits. Ask your workspace owner to refill in order to continue.",
                          comment: "Settings → Usage: Codex's own sentence when a workspace member's credits are used up")
        case "workspace_owner_usage_limit_reached":
            return String(localized: "You hit your spend cap set in your workspace. Increase your spend cap to continue.",
                          comment: "Settings → Usage: Codex's own sentence when the workspace owner hit the spend cap")
        case "workspace_member_usage_limit_reached":
            return String(localized: "You hit your spend cap set by the owner of your workspace. Ask an owner to increase your spend cap to continue.",
                          comment: "Settings → Usage: Codex's own sentence when a workspace member hit the cap its owner set")
        default:
            return nil
        }
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

/// What codex's `account/rateLimits/read` says about the account beyond
/// its windows (`RateLimitSnapshot.credits`, `.individualLimit`,
/// `.rateLimitReachedType`; `rateLimitResetCredits`).
struct CodexAccountDetail: Equatable {
    /// The credits balance as codex states it ("480.7707625000"); nil
    /// when the account has none, or has unlimited credits.
    var balance: String?
    var unlimited = false
    /// A spend cap set in the workspace.
    var spendCap: CodexSpendCap?
    /// Why usage stopped — codex's own value, said through
    /// `CodexUsageAnswer.reachedSentence`.
    var reached: String?
    /// How many limit resets the account can use.
    var resetsAvailable = 0
    /// The resets codex lists, available ones only. nil when codex knows
    /// the count alone ("`null` means only `availableCount` is known");
    /// codex may also list fewer than the count.
    var resets: [CodexResetCredit]?
}

/// `individualLimit`: a spend cap a workspace sets on its member.
struct CodexSpendCap: Equatable {
    /// Both as codex states them (strings of a decimal number).
    var limit: String
    var used: String
    var remainingPercent: Int
    var resetsAt: Date?
}

/// One limit reset codex can use — its id (what the request names),
/// and its name, words and use-by date as codex's backend gives them.
struct CodexResetCredit: Equatable, Identifiable {
    var id: String
    var title: String?
    var description: String?
    var expiresAt: Date?
}

/// `account/usage/read` (`GetAccountTokenUsageResponse`): codex's own
/// account history — the figures its terminal's usage overview shows as
/// "Lifetime tokens", "Peak tokens", "Longest chat", "Current streak",
/// "Longest streak" and "Token activity".
struct CodexUsageHistory: Equatable {
    struct Day: Equatable {
        /// `startDate` as codex writes it, `yyyy-MM-dd`.
        var date: String
        var tokens: Int64
    }

    var lifetimeTokens: Int64?
    var peakDailyTokens: Int64?
    /// The longest single turn, in seconds — codex's "Longest chat".
    var longestRunningTurnSec: Int64?
    var currentStreakDays: Int?
    var longestStreakDays: Int?
    var days: [Day]
    /// False when codex sent no days at all (`dailyUsageBuckets: null`):
    /// its terminal then says "Token activity history unavailable", where
    /// a year of empty squares would say no tokens were used.
    var reportsDays = true

    /// The oldest codex measured to have `account/usage/read`, in its
    /// stable protocol. A codex without it answers with "unknown variant
    /// …, expected one of" and every method it has — a line no page
    /// should show — so an older or unread codex is not asked.
    nonisolated static let floor = CLIVersion.parse("0.162.1")

    nonisolated static func offered(installedCodex: CLIVersion?) -> Bool {
        guard let installed = installedCodex, let floor else { return false }
        return installed >= floor
    }

    nonisolated static func parse(_ answer: [String: Any]?) -> CodexUsageHistory? {
        guard let result = answer?["result"] as? [String: Any],
              let summary = result["summary"] as? [String: Any] else { return nil }
        func number(_ value: Any?) -> Int64? {
            guard let n = (value as? NSNumber)?.doubleValue, n.isFinite, n >= 0, n < 9e18 else { return nil }
            return Int64(n)
        }
        let buckets = result["dailyUsageBuckets"] as? [[String: Any]] ?? []
        let days = buckets.compactMap { bucket -> Day? in
            guard let date = bucket["startDate"] as? String, dayDate(date) != nil,
                  let tokens = number(bucket["tokens"]) else { return nil }
            return Day(date: date, tokens: tokens)
        }
        return CodexUsageHistory(lifetimeTokens: number(summary["lifetimeTokens"]),
                                 peakDailyTokens: number(summary["peakDailyTokens"]),
                                 longestRunningTurnSec: number(summary["longestRunningTurnSec"]),
                                 currentStreakDays: number(summary["currentStreakDays"]).map(Int.init),
                                 longestStreakDays: number(summary["longestStreakDays"]).map(Int.init),
                                 days: days,
                                 reportsDays: result["dailyUsageBuckets"] is [Any])
    }

    /// Each day's tokens, keyed by codex's `yyyy-MM-dd`; a date codex
    /// reports twice counts both, held at what an Int64 holds as codex
    /// holds it — a plain sum past that would stop the app.
    func tokensByDay() -> [String: Int64] {
        var byDay: [String: Int64] = [:]
        for day in days {
            let (sum, overflow) = byDay[day.date, default: 0].addingReportingOverflow(day.tokens)
            byDay[day.date] = overflow ? .max : sum
        }
        return byDay
    }

    nonisolated private static func dayDate(_ text: String) -> Date? {
        dayFormatter(Calendar(identifier: .gregorian)).date(from: text)
    }

    /// Codex's day key — a Gregorian date, as codex writes it — for a day
    /// in `calendar`'s time zone. Written in a calendar that counts its
    /// years another way (the Buddhist one's "2569-10-10"), it would match
    /// none of codex's days.
    nonisolated static func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

/// Codex's token history laid out the way codex's own terminal draws it
/// in its usage overview: fifty-two weeks ending with this one, a column
/// a week and a row a weekday, every day graded against the busiest day
/// shown, and no square for a day after today. Its days and its weeks
/// are codex's own (`days(_:)`): every week starts on Sunday, as codex's
/// terminal starts it, whatever the Mac's own first weekday.
struct CodexActivityCalendar: Equatable {
    nonisolated static let weekCount = 52

    /// The days codex's own terminal draws its history in: the Mac's
    /// calendar — its language, its weekday names — with every week
    /// starting on Sunday and its days in UTC. Codex's terminal starts a
    /// week on Sunday (its chart starts on today less the days since
    /// Sunday), ends its year on today's date in UTC, and its history
    /// request carries no zone of the Mac's. Laid out in the Mac's own
    /// zone, the year would leave out, for hours west of UTC, the day
    /// codex already counts as today, and end east of it on a day codex
    /// has not begun; laid out from the Mac's own first weekday, a Mac
    /// set to Monday would cut the same days into other columns than
    /// codex draws.
    nonisolated static func days(_ base: Calendar = .current) -> Calendar {
        var calendar = base
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? base.timeZone
        calendar.firstWeekday = 1
        return calendar
    }

    struct Cell: Equatable {
        /// The day's start, in the calendar the layout was made with.
        var date: Date
        var tokens: Int64
        /// 0 for a day with no tokens, else 1…4 (`level(_:peak:)`).
        var level: Int
    }

    /// `weekCount` columns, oldest first, seven slots each in the
    /// calendar's weekday order; nil for a day after today.
    var weeks: [[Cell?]]
    /// The columns a month's name goes over: those whose first day is one
    /// of the month's first seven, as codex places them.
    var monthColumns: [Int]
    /// The busiest day shown, which the grades are measured against.
    var peak: Int64
    /// The calendar the year was laid out in: what names its months,
    /// its weekdays and each square's day.
    var calendar: Calendar

    /// Codex's own grades: past three quarters of the peak 4, past half
    /// 3, past a quarter 2, any other day with tokens 1, none 0. Compared
    /// at full width, as codex compares them — a day's count times four
    /// can pass what an Int64 holds.
    nonisolated static func level(_ tokens: Int64, peak: Int64) -> Int {
        guard tokens > 0, peak > 0 else { return 0 }
        func exceeds(_ value: Int64, times a: Int64, _ top: Int64, times b: Int64) -> Bool {
            let left = value.multipliedFullWidth(by: a)
            let right = top.multipliedFullWidth(by: b)
            return left.high != right.high ? left.high > right.high : left.low > right.low
        }
        if exceeds(tokens, times: 4, peak, times: 3) { return 4 }
        if exceeds(tokens, times: 2, peak, times: 1) { return 3 }
        if exceeds(tokens, times: 4, peak, times: 1) { return 2 }
        return 1
    }

    nonisolated static func make(_ history: CodexUsageHistory, today: Date,
                                 calendar: Calendar = days()) -> CodexActivityCalendar {
        let byDay = history.tokensByDay()
        let key = CodexUsageHistory.dayFormatter(calendar)
        let last = calendar.startOfDay(for: today)
        let intoWeek = (calendar.component(.weekday, from: last) - calendar.firstWeekday + 7) % 7
        guard let thisWeek = calendar.date(byAdding: .day, value: -intoWeek, to: last),
              let start = calendar.date(byAdding: .day, value: -7 * (weekCount - 1), to: thisWeek)
        else { return CodexActivityCalendar(weeks: [], monthColumns: [], peak: 0, calendar: calendar) }
        var days: [[(date: Date, tokens: Int64)?]] = []
        var monthColumns: [Int] = []
        var peak: Int64 = 0
        for column in 0..<weekCount {
            var week: [(date: Date, tokens: Int64)?] = []
            for row in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: column * 7 + row, to: start),
                      day <= last else {
                    week.append(nil)
                    continue
                }
                let tokens = byDay[key.string(from: day)] ?? 0
                peak = max(peak, tokens)
                week.append((day, tokens))
            }
            if let first = week.first ?? nil, calendar.component(.day, from: first.date) <= 7 {
                monthColumns.append(column)
            }
            days.append(week)
        }
        let weeks = days.map { week in
            week.map { slot in
                slot.map { Cell(date: $0.date, tokens: $0.tokens, level: level($0.tokens, peak: peak)) }
            }
        }
        return CodexActivityCalendar(weeks: weeks, monthColumns: monthColumns, peak: peak, calendar: calendar)
    }

    /// What pointing at a square says first: the day's tokens, exactly.
    nonisolated static func tokensText(_ tokens: Int64) -> String {
        if tokens == 1 {
            return String(localized: "1 token", comment: "Settings → Usage: a day of Codex's token activity with one token, shown when pointing at its square")
        }
        return String(localized: "\(tokens) tokens",
                      comment: "Settings → Usage: a day's exact Codex token count, shown when pointing at its square; placeholder is the count")
    }

    /// …and then the day, in the Mac's language and in the calendar the
    /// year was laid out in — read in another zone, a day's start can
    /// fall on the day before.
    nonisolated static func dayText(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}

/// Codex's way to use a limit reset: `account/rateLimitResetCredit/
/// consume` over its own app-server, the request its terminal's `/usage`
/// → "Redeem reset" makes. Using a reset cannot be undone, so the request
/// is only ever sent from codex's own confirmation, and every outcome is
/// said in codex's words.
enum CodexResetConsume {
    static let method = "account/rateLimitResetCredit/consume"

    /// The oldest codex measured to have the request, in its stable
    /// protocol. An older or unread codex is offered no button.
    nonisolated static let floor = CLIVersion.parse("0.162.1")

    nonisolated static func offered(installedCodex: CLIVersion?) -> Bool {
        guard let installed = installedCodex, let floor else { return false }
        return installed >= floor
    }

    /// The installed codex is KNOWN to be older than the request: the one
    /// case the section may say an update is what stands in the way. A
    /// version not read yet says nothing.
    nonisolated static func needsNewerCodex(installedCodex: CLIVersion?) -> Bool {
        guard let installed = installedCodex, let floor else { return false }
        return installed < floor
    }

    enum Outcome: Equatable {
        case reset, nothingToReset, noCredit, alreadyRedeemed
        /// Codex refused the request, in its own words.
        case refused(String)
        /// Nothing came back inside the ceiling.
        case noAnswer

        /// Codex answered, so the attempt is over — its key is never
        /// sent again. A refusal or silence leaves the attempt open, to
        /// be retried with the same key: if the first try did reach
        /// codex's backend, the retry cannot use a second reset.
        var settles: Bool {
            switch self {
            case .reset, .nothingToReset, .noCredit, .alreadyRedeemed: return true
            case .refused, .noAnswer: return false
            }
        }

        /// What the outcome means to the user, which is how the section
        /// marks it — not `settles`: "That reset is no longer available"
        /// ends the attempt and is no success.
        enum Tone: Equatable { case done, info, problem }

        var tone: Tone {
            switch self {
            case .reset: return .done
            case .nothingToReset: return .info
            case .noCredit, .alreadyRedeemed, .refused, .noAnswer: return .problem
            }
        }

        /// Codex's terminal's sentence for the outcome.
        var sentence: String {
            switch self {
            case .reset:
                return String(localized: "Usage reset.",
                              comment: "Settings → Usage: Codex's own words after a usage-limit reset was used")
            case .nothingToReset:
                return String(localized: "Your usage does not need a reset right now.",
                              comment: "Settings → Usage: Codex's own words when no limit is reached, so nothing was used")
            case .noCredit:
                return String(localized: "No usage limit resets are available.",
                              comment: "Settings → Usage: Codex's own words when there is no reset to use")
            case .alreadyRedeemed:
                return String(localized: "That reset is no longer available. Refresh to see your current resets.",
                              comment: "Settings → Usage: Codex's own words when the chosen reset was already used")
            case .refused, .noAnswer:
                return String(localized: "Couldn't reset usage. Please try again.",
                              comment: "Settings → Usage: Codex's own words when using a reset failed")
            }
        }
    }

    /// The request, as request `CodexAppServerCall.answerId`. JSON-encoded
    /// whole: the credit id is codex's own string and is never spliced in.
    nonisolated static func request(idempotencyKey: String, creditId: String?) -> String {
        var params: [String: Any] = ["idempotencyKey": idempotencyKey]
        if let creditId { params["creditId"] = creditId }
        let object: [String: Any] = ["jsonrpc": "2.0", "id": CodexAppServerCall.answerId,
                                     "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func outcome(of answer: [String: Any]?) -> Outcome {
        guard let answer else { return .noAnswer }
        if let error = answer["error"] as? [String: Any] {
            return .refused((error["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "error")
        }
        guard let result = answer["result"] as? [String: Any],
              let value = result["outcome"] as? String else { return .noAnswer }
        switch value {
        case "reset": return .reset
        case "nothingToReset": return .nothingToReset
        case "noCredit": return .noCredit
        case "alreadyRedeemed": return .alreadyRedeemed
        default: return .refused(value)
        }
    }

    nonisolated static func run(binary: String, idempotencyKey: String,
                                creditId: String?) async -> Outcome {
        let line = request(idempotencyKey: idempotencyKey, creditId: creditId)
        guard !line.isEmpty else { return .noAnswer }
        return outcome(of: await CodexAppServerCall.run(binary: binary, request: line))
    }
}

/// The attempts to use a reset: one at a time, and an attempt that got
/// no answer keeps its key for its retry (codex's schema: "reuse the same
/// value when retrying that attempt").
struct CodexResetAttempts {
    private(set) var running = false
    /// The open attempt: the reset it was for and the key it was sent with.
    private var open: (creditId: String?, key: String)?

    /// The key to send, or nil while an attempt is running — a second
    /// click sends nothing.
    mutating func begin(creditId: String?) -> String? {
        guard !running else { return nil }
        running = true
        if let open, open.creditId == creditId { return open.key }
        let key = UUID().uuidString.lowercased()
        open = (creditId, key)
        return key
    }

    mutating func finish(_ outcome: CodexResetConsume.Outcome) {
        running = false
        if outcome.settles { open = nil }
    }
}

/// Where using a codex reset stands, as the section draws it. Each step
/// names the reset it is about (nil: the next one, when codex listed only
/// a count), so a card for another reset does not take its words.
enum CodexResetStep: Equatable {
    case idle
    /// Codex's confirmation is up.
    case confirming(creditId: String?)
    case running(creditId: String?)
    case finished(creditId: String?, outcome: CodexResetConsume.Outcome)
}

// MARK: - Kimi: the web server's `/oauth/usage` envelope

/// `GET /api/v1/oauth/usage` on `kimi web` answers
/// `{"code":0,"msg":"success","data":<result>}`, the result in one of two
/// shapes, told apart by their keys:
///
///  * `quota` — kimi's own parse of the upstream, camelCase:
///    `{kind: "ok", quota: {usages: {limit5h?, limit7d?, monthTotal?,
///    monthCode?} each {usedRatio, resetAt?}, extraUsage: {balanceCents,
///    totalCents, monthlyChargeLimitEnabled, monthlyChargeLimitCents,
///    monthlyUsedCents, currency} | null}}`. Rows are drawn as kimi's own
///    `/usage` draws them: "5h limit", "Weekly limit", "Monthly limit" in
///    that order, the percent rounded as kimi rounds it, the monthly row
///    split into its Kimi and Kimi Code parts.
///  * `summary` / `limits` / `extra_usage` — what an older kimi answers:
///    rows `{name?, window? {duration, unit}, used, limit, reset_at?}`,
///    the wallet in snake_case cents.
///
/// An ok answer in neither shape is `.malformed`, never an ok answer with
/// nothing in it: read as "nothing to show", a shape kimi moved to draws a
/// card with a title and nothing under it, and says nothing about why.
/// An answer that holds nothing is kimi's own "No usage data available."
/// The error branch, `{kind: "error", message, status?}`, is kimi's
/// sentence as it stands.
enum KimiUsageAnswer {
    enum Kind: Equatable { case ok, error, malformed }

    struct Report: Equatable {
        var kind: Kind
        var rows: [PlanUsageRow]
        var notes: [PlanUsageNote]
        var failure: String?
    }

    /// Kimi's own row for each window it serves, in the order its
    /// `/usage` lists them (`quotaUsageRows`), whatever the payload's.
    static let quotaWindows: [(key: String, label: String)] = [
        ("limit5h", "5h limit"),
        ("limit7d", "Weekly limit"),
        ("monthTotal", "Monthly limit"),
    ]

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
        var notes: [PlanUsageNote] = []
        if let quota = data["quota"] as? [String: Any] {
            let usages = quota["usages"] as? [String: Any] ?? [:]
            for window in quotaWindows {
                guard let entry = usages[window.key] as? [String: Any],
                      let ratio = double(entry["usedRatio"]) else { continue }
                var row = ratioRow(label: window.label, ratio: ratio, resetAt: entry["resetAt"])
                if window.key == "monthTotal" {
                    row.split = monthlySplit(total: ratio,
                                             code: double((usages["monthCode"] as? [String: Any])?["usedRatio"]))
                }
                rows.append(row)
            }
            if let wallet = quota["extraUsage"] as? [String: Any] {
                notes.append(extraUsage(used: int(wallet["monthlyUsedCents"]),
                                        limitEnabled: wallet["monthlyChargeLimitEnabled"],
                                        limit: int(wallet["monthlyChargeLimitCents"]),
                                        balance: int(wallet["balanceCents"]),
                                        currency: wallet["currency"]))
            }
        } else if data.keys.contains(where: { ["summary", "limits", "extra_usage"].contains($0) }) {
            if let summary = data["summary"] as? [String: Any],
               let row = row(summary, defaultWindow: PlanWindow(duration: 1, unit: .week)) {
                rows.append(row)
            }
            if let limits = data["limits"] as? [[String: Any]] {
                for limit in limits {
                    if let row = row(limit, defaultWindow: nil) { rows.append(row) }
                }
            }
            if let wallet = data["extra_usage"] as? [String: Any],
               let total = int(wallet["total_cents"]), total > 0 {
                notes.append(extraUsage(used: int(wallet["monthly_used_cents"]),
                                        limitEnabled: wallet["monthly_charge_limit_enabled"],
                                        limit: int(wallet["monthly_charge_limit_cents"]),
                                        balance: int(wallet["balance_cents"]),
                                        currency: wallet["currency"]))
            }
        } else {
            return Report(kind: .malformed, rows: [], notes: [], failure: nil)
        }
        if rows.isEmpty, notes.isEmpty { notes = [.noUsageData] }
        return Report(kind: .ok, rows: rows, notes: notes, failure: nil)
    }

    /// The site kimi's own local server names (`/api/v1/oauth/region`,
    /// `{"code":0,"data":{"region":…}}`): "mainland-cn" (kimi.com) or
    /// "global" (kimi.ai). nil for a refusal or anything else.
    nonisolated static func region(body: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              (root["code"] as? NSNumber)?.intValue == 0,
              let data = root["data"] as? [String: Any],
              let region = data["region"] as? String, !region.isEmpty else { return nil }
        return region
    }

    /// A quota window as kimi's `/usage` draws it: the ratio clamped to
    /// 0…1 (`safeUsageRatio`) and rounded half up to a whole percent
    /// (`Math.round`, which `rounded()` matches for any ratio in range).
    nonisolated private static func ratioRow(label: String, ratio: Double, resetAt: Any?) -> PlanUsageRow {
        let resetRaw = (resetAt as? String).flatMap { $0.isEmpty ? nil : $0 }
        let resetDate = resetRaw.flatMap(ClaudeUsageCache.isoDate)
        return PlanUsageRow(label: label, window: nil, percent: percent(ratio),
                            used: nil, limit: nil,
                            resetText: resetDate == nil ? resetRaw : nil,
                            resetDate: resetDate)
    }

    /// Kimi's `monthlyBreakdown`: Kimi Code's share is `monthCode`, Kimi's
    /// is the month's total less it, taken to six places before rounding.
    nonisolated private static func monthlySplit(total: Double, code: Double?) -> PlanUsageSplit {
        let codeRatio = clamped(code ?? 0)
        let kimiRatio = clamped(((total - codeRatio) * 1e6).rounded() / 1e6)
        return PlanUsageSplit(kimiPercent: percent(kimiRatio), codePercent: percent(codeRatio))
    }

    /// The wallet in kimi's three figures. A monthly limit counts only
    /// while it is switched on and above zero, as kimi's own `/usage`
    /// counts it; otherwise there is none.
    nonisolated private static func extraUsage(used: Int?, limitEnabled: Any?, limit: Int?,
                                               balance: Int?, currency: Any?) -> PlanUsageNote {
        let hasLimit = (limitEnabled as? Bool) == true && (limit ?? 0) > 0
        let code = (currency as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "USD"
        return .extraUsage(usedCents: max(0, used ?? 0), limitCents: hasLimit ? limit : nil,
                           balanceCents: max(0, balance ?? 0), currency: code)
    }

    nonisolated private static func clamped(_ ratio: Double) -> Double {
        ratio.isFinite ? min(1, max(0, ratio)) : 0
    }

    nonisolated private static func percent(_ ratio: Double) -> Int {
        Int((clamped(ratio) * 100).rounded())
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

    /// A number, or a numeric string — kimi's own readers (`toInt`,
    /// `ratioValue`) take both from the upstream API, so these do too.
    nonisolated private static func double(_ value: Any?) -> Double? {
        let number: Double
        if let boxed = value as? NSNumber {
            number = boxed.doubleValue
        } else if let text = value as? String,
                  let parsed = Double(text.trimmingCharacters(in: .whitespaces)) {
            number = parsed
        } else {
            return nil
        }
        return number.isFinite ? number : nil
    }

    nonisolated private static func int(_ value: Any?) -> Int? {
        // `Int(Double)` traps past the integer range; a count that far
        // out is not a count.
        guard let number = double(value), abs(number) < 1e15 else { return nil }
        return Int(number)
    }
}

// MARK: - Each tool's own usage page

/// Where each agent's usage is shown outside SipAI: the page the tool
/// itself names, or — where it names none — the page its vendor's help
/// names. Settings → Usage links to it; nothing here is opened without
/// `opensSafely`.
///
///  * Claude Code names claude.ai/settings/usage for a plan and
///    platform.claude.com/settings/billing for an API key. Through a
///    cloud provider (Bedrock, Vertex, Foundry) the cloud bills it, and
///    there is no Anthropic page to send anyone to — nor for a key claude
///    sends to another host (`ANTHROPIC_BASE_URL`: a gateway, or another
///    vendor's Anthropic-compatible endpoint), which is billed where it
///    was issued.
///  * Codex names chatgpt.com/settings/usage ("for up-to-date
///    information on rate limits and credits"). For an API key it names
///    no usage page; OpenAI's help names platform.openai.com/usage.
///  * Kimi Code runs on one of two sites, kimi.com and kimi.ai, with
///    separate accounts. A membership's console is on the site kimi's own
///    server names (Kimi's help: "Log in to the Kimi Code Console at any
///    time to check remaining quota and rate-limit status", at /code/console
///    on each site) — never a guessed site. A key is shown where its
///    platform shows it: a Moonshot key on the console kimi itself names
///    for it (`OPEN_PLATFORMS.consoleUrl`, platform.kimi.com /
///    platform.kimi.ai), a Kimi For Coding key on the Kimi Code Console of
///    its site. Keyed by kimi's own provider ids (`AgentSignIn
///    .kimiKeyProviders`); a provider kimi's catalog does not list has no
///    page.
///
/// No page carries a tracking parameter, and none is a purchase page:
/// the vendor's own usage page offers that.
enum PlanUsagePages {
    /// Every host a usage link may open, per agent.
    nonisolated static let hosts: [String: Set<String>] = [
        "claude_code": ["claude.ai", "platform.claude.com"],
        "codex": ["chatgpt.com", "platform.openai.com"],
        "kimi": ["www.kimi.com", "www.kimi.ai", "platform.kimi.com", "platform.kimi.ai"],
    ]

    nonisolated static func page(agentKey: String, onPlan: Bool,
                                 claudeCloudProvider: String?,
                                 claudeBaseURL: String? = nil,
                                 kimiRegion: String?,
                                 kimiKeyProviderId: String?) -> URL? {
        let address: String?
        switch agentKey {
        case "claude_code":
            if onPlan {
                address = "https://claude.ai/settings/usage"
            } else if claudeCloudProvider == nil, sendsToAnthropic(baseURL: claudeBaseURL) {
                address = "https://platform.claude.com/settings/billing"
            } else {
                address = nil
            }
        case "codex":
            address = onPlan ? "https://chatgpt.com/settings/usage" : "https://platform.openai.com/usage"
        case "kimi":
            if onPlan {
                switch kimiRegion {
                case "mainland-cn": address = "https://www.kimi.com/code/console"
                case "global": address = "https://www.kimi.ai/code/console"
                default: address = nil
                }
            } else {
                switch kimiKeyProviderId {
                case "moonshotai-cn": address = "https://platform.kimi.com"
                case "moonshotai": address = "https://platform.kimi.ai"
                case "kimi-code-plan-cn": address = "https://www.kimi.com/code/console"
                case "kimi-code-plan-global": address = "https://www.kimi.ai/code/console"
                default: address = nil
                }
            }
        default:
            address = nil
        }
        return address.flatMap(URL.init(string:))
    }

    /// Claude's requests go to Anthropic's own API: no base URL, or one on
    /// api.anthropic.com. Any other host — or one that does not read as a
    /// URL — is not Anthropic's to bill.
    nonisolated static func sendsToAnthropic(baseURL: String?) -> Bool {
        guard let baseURL else { return true }
        return URL(string: baseURL)?.host?.lowercased() == "api.anthropic.com"
    }

    /// https, one of the agent's own hosts, no credentials, no port.
    nonisolated static func opensSafely(_ url: URL, agentKey: String) -> Bool {
        guard url.scheme == "https", let host = url.host,
              hosts[agentKey]?.contains(host) == true,
              url.user == nil, url.password == nil, url.port == nil
        else { return false }
        return true
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
        /// The structured report beside the text, when this claude
        /// sends one.
        var report: ClaudeUsageReport? = nil
    }

    /// `--session-id` names the transcript the probe writes so it can
    /// be removed; the MCP flags stop the user's servers being started
    /// to answer a usage question (measured: a second saved). Setting
    /// sources are NOT dropped — an `apiKeyHelper` there decides which
    /// account answers. `stream-json` (which needs `--verbose` under
    /// `-p`) is what carries the structured report; the `result` text
    /// is the same in both formats.
    nonisolated static func arguments(sessionId: String) -> [String] {
        ["-p", "/usage", "--output-format", "stream-json", "--verbose",
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
            return Outcome(text: text, errorText: nil, report: extractReport(from: result.output))
        }
        // With no result, the line claude stopped with — an error it
        // printed, else its last line (`CLIStartFailure`).
        return Outcome(text: nil, errorText: extracted.text ?? CLIStartFailure.reason(in: result.output))
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

    /// The `usage_report` of the record that answered `/usage`, when
    /// the stream carries one.
    nonisolated static func extractReport(from output: String) -> ClaudeUsageReport? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), trimmed.contains("\"usage_report\""),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)))
                    as? [String: Any],
                  let report = obj["usage_report"] as? [String: Any]
            else { continue }
            return ClaudeUsageReport.parse(report)
        }
        return nil
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
    /// Codex's account history, asked on its own by Settings → Usage — the
    /// window never waits on it.
    static let historyRequest =
        #"{"jsonrpc":"2.0","id":2,"method":"account/usage/read","params":{}}"#

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
    static let regionPath = "/api/v1/oauth/region"
    static let userInfoPath = "/api/v1/oauth/userinfo"
    static let shutdownPath = "/api/v1/shutdown"

    enum Outcome: Equatable {
        /// The usage answer, and what kimi named in the same visit: the
        /// site, and the membership's name (`KimiMembership`) — nil when
        /// it named none.
        case answered(Data, region: String?, planName: String?)
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
        String(localized: "The tool's local server is busy right now. Try again in a moment.",
               comment: "Kimi's one local server is held by something else — a sign-in, a usage read, a Chat only turn's first message — and did not come free in time")
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
        // The site the membership's console is on, and the membership's
        // name, asked while the server is up: a few milliseconds each,
        // and no second start.
        var region: String? = nil
        var planName: String? = nil
        if case .success = answer {
            if case .success(let body) = request(port: session.port, path: regionPath, method: "GET",
                                                 bearer: session.bearerForDrive) {
                region = KimiUsageAnswer.region(body: body)
            }
            if case .success(let body) = request(port: session.port, path: userInfoPath, method: "GET",
                                                 bearer: session.bearerForDrive) {
                planName = KimiMembership.levelName(userInfoBody: body)
            }
        }
        session.finishSynchronously()
        switch answer {
        case .success(let data): return .answered(data, region: region, planName: planName)
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
        AgentCLIProbe.awaitExit(p)
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
    /// Codex's account history, for Settings → Usage alone.
    @Published private(set) var codexHistory: CodexUsageHistory?
    @Published private(set) var codexHistoryLoading = false
    /// Codex's words when it would not give the history, else SipAI's.
    @Published private(set) var codexHistoryFailure: String?
    /// Where using a codex reset stands. Kept here, not in the section:
    /// the router replaces the page on every detour, and an attempt
    /// outlives the page it was started from.
    @Published private(set) var resetStep: CodexResetStep = .idle

    /// How fresh the figures must be for Settings → Usage to show them
    /// without asking again: "Learn more" from a window that has just
    /// read them starts nothing.
    nonisolated static let sectionReuse: TimeInterval = 60

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
    /// A refresh asked for while one runs (after a reset was used): run
    /// once more when the current one ends, so the figures show the reset.
    private var refreshAgain = false
    private var codexHistoryAt: Date?
    private var resetAttempts = CodexResetAttempts()

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
        codexHistory = nil
        codexHistoryAt = nil
        codexHistoryFailure = nil
        if !resetAttempts.running { resetStep = .idle }
        recompute()
    }

    /// The figures held for an agent, whatever its verdict — a read that
    /// failed before the account kind was known still has its reason.
    func card(for key: String) -> PlanUsageCard? { figures[key] }

    // MARK: Probe layer

    /// Settings → Usage on appear: ask again unless a read finished less
    /// than `maxAge` ago, or one is running.
    func refreshIfStale(maxAge: TimeInterval = UsageMonitor.sectionReuse) {
        guard !refreshing else { return }
        if let updatedAt, Date().timeIntervalSince(updatedAt) < maxAge { return }
        refresh()
    }

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
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh()
            }
        }
    }

    // MARK: Codex's history and resets (Settings → Usage)

    /// Codex's account history, in a codex process of its own — never on
    /// the window's path. Asked when the section appears, at most once a
    /// minute, of a codex known to have the request; a failed read is
    /// asked again next time.
    func loadCodexHistory(installedCodex: CLIVersion?) {
        guard !codexHistoryLoading, isShown("codex"), accounts["codex"]?.isPlan == true,
              CodexUsageHistory.offered(installedCodex: installedCodex) else { return }
        if let at = codexHistoryAt, Date().timeIntervalSince(at) < Self.sectionReuse { return }
        guard let binary = AgentManager.binaryPath(for: "codex") else { return }
        codexHistoryLoading = true
        Task { [weak self] in
            let answer = await CodexAppServerCall.run(binary: binary, request: CodexUsageProbe.historyRequest)
            guard let self else { return }
            self.codexHistoryLoading = false
            if let history = CodexUsageHistory.parse(answer) {
                self.codexHistory = history
                self.codexHistoryFailure = nil
                self.codexHistoryAt = Date()
            } else {
                self.codexHistoryFailure = ((answer?["error"] as? [String: Any])?["message"] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 } ?? Self.didNotAnswer
            }
        }
    }

    /// "Use reset…": codex's own confirmation comes up for that reset
    /// (nil: codex picks the next one, when it listed only a count).
    func askToUseReset(creditId: String?) {
        guard !resetAttempts.running else { return }
        resetStep = .confirming(creditId: creditId)
    }

    /// "No, go back" — and the section going away, so a confirmation or
    /// an outcome is not left up for the next visit. An attempt under
    /// way is left to finish.
    func cancelReset() {
        guard !resetAttempts.running else { return }
        resetStep = .idle
    }

    /// "Yes, use reset": the request, through codex's own process, for the
    /// reset the confirmation named and no other. One attempt at a time;
    /// an attempt that got no answer is retried with its own key. The
    /// figures are read again once codex has answered.
    func useReset(creditId: String?) {
        guard case .confirming(let confirmed) = resetStep, confirmed == creditId,
              let key = resetAttempts.begin(creditId: creditId) else { return }
        resetStep = .running(creditId: creditId)
        Task { [weak self] in
            let outcome: CodexResetConsume.Outcome
            if let binary = AgentManager.binaryPath(for: "codex") {
                outcome = await CodexResetConsume.run(binary: binary, idempotencyKey: key,
                                                      creditId: creditId)
            } else {
                outcome = .noAnswer
            }
            guard let self else { return }
            self.resetAttempts.finish(outcome)
            self.resetStep = .finished(creditId: creditId, outcome: outcome)
            if outcome.settles { self.refreshAfterReset() }
        }
    }

    /// A refresh the reset's outcome asked for, even when one is running.
    private func refreshAfterReset() {
        if refreshTask != nil { refreshAgain = true } else { refresh() }
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
                card.rows = ClaudeUsageText.merging(report.rows, report: outcome.report)
                card.contributing = ClaudeUsageText.contributing(in: text)
                if card.rows.isEmpty, report.kind != .apiKey { card.rawText = text }
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
            card.codex = report.detail
            if let failure = report.failure {
                card.failure = failure
            } else if !report.answered, report.kind.isPlan || report.kind == .unknown {
                // A plan account with no limits and no refusal: nothing
                // arrived inside the ceiling. Silence would draw a card
                // with a title and nothing under it. A codex that answered
                // nothing at all may be one that cannot start — npm's
                // install without its program throws on every start — and
                // then it says why, in its own words.
                var read: (version: CLIVersion?, startFailure: String?) = (nil, nil)
                if !outcome.available {
                    let key = agent.key
                    read = await Task.detached(priority: .utility) {
                        let fingerprint = AgentCLIProbe.fingerprint(agentKey: key)
                        return await AgentCLIProbe.installedVersion(agentKey: key, fingerprint: fingerprint)
                    }.value
                }
                card.failure = read.startFailure.flatMap(CLIStartFailure.reason(in:)) ?? Self.didNotAnswer
            }
            if card.failure != nil { card = keepingFigures(card) }
        case "kimi":
            let outcome = await KimiWebServerCall.fetchUsage(binary: binary,
                                                             scratchDirectory: scratch)
            switch outcome {
            case .answered(let body, let region, let planName):
                let report = KimiUsageAnswer.parse(body: body)
                switch report.kind {
                case .ok:
                    // A name kimi did not give this time is the one it
                    // gave before: an account read that failed must not
                    // take the card's name away.
                    verdict = .plan(name: planName ?? accounts[agent.key]?.planName)
                    card.rows = report.rows
                    card.notes = report.notes
                    card.kimiRegion = region
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
