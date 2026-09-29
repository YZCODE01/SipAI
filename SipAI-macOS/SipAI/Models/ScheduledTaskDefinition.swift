// ScheduledTaskDefinition.swift
// The complete, self-contained definition of a scheduled task, plus the
// parsers that decide when it is due: cron for a recurring schedule,
// an ISO 8601 instant for a one-time run (`TaskSchedule`).
//
// WHY THE SCHEDULE LIVES HERE AND NOT IN THE CRONTAB
//
// The crontab is one shared file with no history, and anything that
// rewrites it — another tool, a stray `crontab -r`, a migration —
// silently erases whatever lives only there. A schedule stored only in
// the crontab would go with it, unrecoverably: the task folder would
// hold nothing to recover it from.
//
// So `schedule:` is frontmatter. The task directory is the whole
// truth: prompt, schedule, where it runs, and how. A crontab can be
// wiped without losing anything but the arming itself, and the
// schedule sits in one place the user can also see and edit by hand.
//
// Frontmatter keys this app owns:
//     name, description, schedule, cwd, mode, model, effort, fast_mode,
//     service_tier, agent, enabled, catchup
// Any OTHER key found in an existing file is preserved verbatim on
// rewrite — Claude Desktop writes its own task files into the same
// directory and must not lose fields it cares about just because we
// edited the description.

import Foundation

// MARK: - Cron

/// A parsed 5-field cron expression: `minute hour day-of-month month
/// day-of-week`.
///
/// Supports the shapes a user can reasonably type — `*`, `5`, `1-5`,
/// `*/15`, `0-30/10`, `mon`, `jan`, and comma-joined lists of any of
/// them. Day-of-week accepts both `0` and `7` for Sunday, as cron does.
///
/// Field semantics follow cron exactly, including its one genuinely
/// surprising rule: when BOTH day-of-month and day-of-week are
/// restricted, a day matches if EITHER matches (not both). `0 9 1 * mon`
/// is "the 1st, and every Monday", not "Mondays that fall on the 1st".
struct CronSchedule: Equatable, Hashable {
    /// The expression as written, normalized to single spaces. Kept so
    /// the UI can show exactly what will be saved.
    let expression: String

    let minutes: Set<Int>       // 0–59
    let hours: Set<Int>         // 0–23
    let daysOfMonth: Set<Int>   // 1–31
    let months: Set<Int>        // 1–12
    let daysOfWeek: Set<Int>    // 0–6, Sunday = 0

    /// Whether each day field was narrowed from `*`. Drives the
    /// either-matches rule above; a bare set-comparison can't tell
    /// "every day" from "days 1–31 listed out".
    let dayOfMonthRestricted: Bool
    let dayOfWeekRestricted: Bool

    /// How far the fire-date searches will walk before giving up. Large
    /// enough for the worst legal expression (`0 0 29 2 *` — Feb 29,
    /// up to ~8 years apart under the Gregorian rules), and each step
    /// is a cheap component read.
    private static let searchDayLimit = 3000

    // MARK: Parsing

    private static let monthNames = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]
    private static let dayNames = [
        "sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5,
        "sat": 6,
    ]

    /// Parse a 5-field expression, or nil if it isn't one. Nil is the
    /// honest answer for anything unsupported — the caller shows the
    /// raw text rather than firing on a guess.
    static func parse(_ raw: String) -> CronSchedule? {
        let fields = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { return nil }

        guard let minutes = parseField(fields[0], range: 0...59),
              let hours = parseField(fields[1], range: 0...23),
              let daysOfMonth = parseField(fields[2], range: 1...31),
              let months = parseField(fields[3], range: 1...12, names: monthNames),
              let rawDaysOfWeek = parseField(fields[4], range: 0...7, names: dayNames)
        else { return nil }

        // Cron accepts 7 as a second spelling of Sunday; fold it in so
        // matching never has to know about the duplicate.
        var daysOfWeek = rawDaysOfWeek
        if daysOfWeek.contains(7) {
            daysOfWeek.remove(7)
            daysOfWeek.insert(0)
        }
        guard !minutes.isEmpty, !hours.isEmpty, !daysOfMonth.isEmpty,
              !months.isEmpty, !daysOfWeek.isEmpty else { return nil }

        return CronSchedule(
            expression: fields.joined(separator: " "),
            minutes: minutes,
            hours: hours,
            daysOfMonth: daysOfMonth,
            months: months,
            daysOfWeek: daysOfWeek,
            dayOfMonthRestricted: fields[2] != "*",
            dayOfWeekRestricted: fields[4] != "*"
        )
    }

    /// One comma-separated field. Returns nil (not an empty set) on
    /// anything malformed, so a typo can never silently become "never".
    private static func parseField(_ field: String,
                                   range: ClosedRange<Int>,
                                   names: [String: Int] = [:]) -> Set<Int>? {
        var out = Set<Int>()
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            let piece = part.trimmingCharacters(in: .whitespaces).lowercased()
            guard !piece.isEmpty else { return nil }

            // Optional `/step` suffix.
            var body = piece
            var step = 1
            if let slash = piece.firstIndex(of: "/") {
                body = String(piece[piece.startIndex..<slash])
                    .trimmingCharacters(in: .whitespaces)
                let stepText = String(piece[piece.index(after: slash)...])
                guard let parsed = Int(stepText), parsed > 0 else { return nil }
                step = parsed
            }

            let bounds: ClosedRange<Int>
            if body == "*" {
                bounds = range
            } else if let dash = dashIndex(of: body) {
                let lowText = String(body[body.startIndex..<dash])
                let highText = String(body[body.index(after: dash)...])
                guard let low = value(lowText, names: names),
                      let high = value(highText, names: names),
                      range.contains(low), range.contains(high),
                      low <= high else { return nil }
                bounds = low...high
            } else {
                guard let single = value(body, names: names),
                      range.contains(single) else { return nil }
                // A bare number with a step means "from here to the end
                // of the field", which is how cron reads `5/10`.
                bounds = step == 1 ? single...single : single...range.upperBound
            }

            for v in stride(from: bounds.lowerBound,
                            through: bounds.upperBound, by: step) {
                out.insert(v)
            }
        }
        return out
    }

    /// Index of the range separator, skipping a leading `-` so a
    /// negative-looking token fails the number parse instead of being
    /// read as a range.
    private static func dashIndex(of body: String) -> String.Index? {
        guard !body.isEmpty else { return nil }
        return body[body.index(after: body.startIndex)...].firstIndex(of: "-")
    }

    private static func value(_ token: String, names: [String: Int]) -> Int? {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = Int(t) { return n }
        return names[String(t.prefix(3))]
    }

    // MARK: Matching

    /// Whether the calendar day containing `date` is a day this
    /// schedule can fire on. Time of day is not consulted.
    private func dayMatches(_ date: Date, calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.month, .day, .weekday], from: date)
        guard let month = c.month, let day = c.day, let weekday = c.weekday
        else { return false }
        guard months.contains(month) else { return false }
        // Calendar numbers weekdays 1…7 from Sunday; cron numbers 0…6.
        let dow = weekday - 1
        switch (dayOfMonthRestricted, dayOfWeekRestricted) {
        case (true, true):
            return daysOfMonth.contains(day) || daysOfWeek.contains(dow)
        case (true, false):
            return daysOfMonth.contains(day)
        case (false, true):
            return daysOfWeek.contains(dow)
        case (false, false):
            return true
        }
    }

    /// The first fire time strictly after `date`, or nil if the
    /// expression can never fire (e.g. Feb 30).
    func nextFireDate(after date: Date, calendar: Calendar = .current) -> Date? {
        search(from: date, calendar: calendar, forward: true)
    }

    /// The most recent fire time at or before `date`.
    ///
    /// This is what the scheduler actually runs on: "the slot this task
    /// was last supposed to fire in". Comparing it against the last
    /// recorded run answers live firing and missed-run catch-up with
    /// the same question, so the two can never disagree.
    func previousFireDate(onOrBefore date: Date,
                          calendar: Calendar = .current) -> Date? {
        search(from: date, calendar: calendar, forward: false)
    }

    private func search(from date: Date, calendar: Calendar,
                        forward: Bool) -> Date? {
        let hourList = forward ? hours.sorted() : hours.sorted().reversed().map { $0 }
        let minuteList = forward ? minutes.sorted() : minutes.sorted().reversed().map { $0 }
        guard !hourList.isEmpty, !minuteList.isEmpty else { return nil }

        var day = calendar.startOfDay(for: date)
        for _ in 0..<Self.searchDayLimit {
            if dayMatches(day, calendar: calendar) {
                let ymd = calendar.dateComponents([.year, .month, .day], from: day)
                for hour in hourList {
                    for minute in minuteList {
                        var c = DateComponents()
                        c.year = ymd.year
                        c.month = ymd.month
                        c.day = ymd.day
                        c.hour = hour
                        c.minute = minute
                        c.second = 0
                        guard let candidate = calendar.date(from: c) else { continue }
                        // A wall-clock time inside a DST spring-forward
                        // gap does not exist; Calendar rolls it to the
                        // next real instant. Accept that (fire an hour
                        // late once a year) rather than reject it, which
                        // would skip the day entirely — but only if it
                        // is still the day we were searching.
                        guard calendar.isDate(candidate, inSameDayAs: day)
                        else { continue }
                        if forward ? candidate > date : candidate <= date {
                            return candidate
                        }
                    }
                }
            }
            guard let stepped = calendar.date(byAdding: .day,
                                              value: forward ? 1 : -1,
                                              to: day) else { return nil }
            day = stepped
        }
        return nil
    }

    // MARK: Description

    /// Plain-English rendering, or the raw expression when the shape
    /// isn't one we can phrase faithfully. Returning the expression
    /// unchanged is deliberate — a wrong-but-fluent summary of when
    /// something runs unattended is worse than no summary.
    var localizedDescriptionText: String {
        let fields = expression.split(separator: " ").map(String.init)
        guard fields.count == 5 else { return expression }
        let (minuteField, hourField, domField, monthField, dowField) =
            (fields[0], fields[1], fields[2], fields[3], fields[4])
        guard monthField == "*" else { return expression }

        // "every N minutes"
        if hourField == "*", domField == "*", dowField == "*",
           minuteField.hasPrefix("*/"), let step = Int(minuteField.dropFirst(2)) {
            return String(localized: "every \(step) minutes",
                          comment: "Cron summary: a fixed minute interval")
        }
        guard let minute = Int(minuteField), minutes.count == 1 else {
            return expression
        }
        // "every hour…"
        if hourField == "*", domField == "*", dowField == "*" {
            return minute == 0
                ? String(localized: "every hour, on the hour",
                         comment: "Cron summary: hourly at :00")
                : String(localized: "every hour at :\(twoDigits(minute))",
                         comment: "Cron summary: hourly at a given minute")
        }
        guard let hour = Int(hourField), hours.count == 1 else { return expression }
        let at = Self.clockText(hour: hour, minute: minute)

        if domField == "*" {
            if dowField == "*" {
                return String(localized: "every day at \(at)",
                              comment: "Cron summary: daily at a time")
            }
            if dowField == "1-5" {
                return String(localized: "every weekday at \(at)",
                              comment: "Cron summary: Mon–Fri at a time")
            }
            if daysOfWeek.count == 1, let dow = daysOfWeek.first {
                return String(localized: "every \(Self.weekdayName(dow)) at \(at)",
                              comment: "Cron summary: one weekday at a time")
            }
            return expression
        }
        if dowField == "*", daysOfMonth.count == 1, let day = daysOfMonth.first {
            return String(localized: "on day \(day) of every month at \(at)",
                          comment: "Cron summary: monthly on a day-of-month")
        }
        return expression
    }

    private func twoDigits(_ n: Int) -> String {
        n < 10 ? "0\(n)" : "\(n)"
    }

    /// Locale-aware clock text, so a 24-hour region doesn't read "9:00 AM".
    /// Built from a real date because DateFormatter has no way to format
    /// loose components.
    static func clockText(hour: Int, minute: Int) -> String {
        var c = DateComponents()
        c.year = 2000; c.month = 1; c.day = 1
        c.hour = hour; c.minute = minute
        guard let date = Calendar.current.date(from: c) else {
            return "\(hour):\(minute < 10 ? "0" : "")\(minute)"
        }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    static func weekdayName(_ dow: Int) -> String {
        let symbols = DateFormatter().weekdaySymbols ?? []
        guard dow >= 0, dow < symbols.count else { return "\(dow)" }
        return symbols[dow]
    }
}

// MARK: - Schedule

/// What a task's `schedule:` value says: a recurring 5-field cron
/// expression, or ONE moment.
///
/// Both forms live in the same key, so the task directory stays the
/// whole truth. Cron has no year field — no 5-field expression can say
/// "this date, once" — so the one-time form is its own spelling:
/// `once 2026-09-30T17:00:00-07:00`, an ISO 8601 instant written in
/// the local time zone so a person reading the file sees their own
/// clock. The leading word is one no cron field can start with, so the
/// two forms can never read as each other, and a reader that does not
/// know the form sees an unparseable schedule and fires nothing.
enum TaskSchedule: Equatable {
    case cron(CronSchedule)
    case once(Date)

    static let oncePrefix = "once"

    static func parse(_ raw: String) -> TaskSchedule? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let date = onceDate(in: trimmed) { return .once(date) }
        return CronSchedule.parse(trimmed).map(TaskSchedule.cron)
    }

    /// The `schedule:` value for a single run at `date`.
    static func onceExpression(for date: Date,
                               timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return "\(oncePrefix) \(formatter.string(from: date))"
    }

    /// The instant a one-time value names, or nil for anything else.
    /// Takes what `onceExpression` writes, plus the two shapes a hand
    /// edit is likely to produce — `2026-09-30T17:00` and
    /// `2026-09-30 17:00`, read in the local time zone.
    static func onceDate(in raw: String) -> Date? {
        let parts = raw.trimmingCharacters(in: .whitespaces)
            .split(maxSplits: 1, whereSeparator: \.isWhitespace)
            .map(String.init)
        guard parts.count == 2, parts[0].lowercased() == oncePrefix else { return nil }
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm",
                       "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            local.dateFormat = format
            if let date = local.date(from: value) { return date }
        }
        return nil
    }

    var isOneTime: Bool {
        if case .once = self { return true }
        return false
    }

    /// One spelling per schedule, for telling whether the schedule in
    /// force has CHANGED — spelled from what the schedule fires on, not
    /// from how it was written. A cron expression is its five parsed
    /// sets and the two day-restriction flags, so `*/15` and
    /// `0,15,30,45`, `1-5` and `1,2,3,4,5`, `mon` and `1` are one
    /// schedule (the fire-date search reads nothing else). A one-time
    /// moment is its instant in UTC, so one moment written from two
    /// time zones, or by hand, is one schedule too. A respelling that
    /// read as a change would count the schedule's newest slot as
    /// already accounted for — and swallow a slot owed under it.
    var canonicalText: String {
        switch self {
        case .cron(let cron):
            func list(_ set: Set<Int>) -> String {
                set.sorted().map(String.init).joined(separator: ",")
            }
            return "cron m=\(list(cron.minutes)) h=\(list(cron.hours))"
                + " dom=\(list(cron.daysOfMonth))\(cron.dayOfMonthRestricted ? "!" : "")"
                + " mon=\(list(cron.months))"
                + " dow=\(list(cron.daysOfWeek))\(cron.dayOfWeekRestricted ? "!" : "")"
        case .once(let at):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            formatter.timeZone = TimeZone(identifier: "UTC")
            return "\(Self.oncePrefix) \(formatter.string(from: at))"
        }
    }

    /// The first fire time strictly after `date`; nil once a one-time
    /// run's moment has passed.
    func nextFireDate(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .cron(let cron):
            return cron.nextFireDate(after: date, calendar: calendar)
        case .once(let at):
            return at > date ? at : nil
        }
    }

    /// The most recent fire time at or before `date` — the scheduler's
    /// one question (see `ScheduledTaskScheduler.decide`). A one-time
    /// schedule has a slot only once its moment has come.
    func previousFireDate(onOrBefore date: Date,
                          calendar: Calendar = .current) -> Date? {
        switch self {
        case .cron(let cron):
            return cron.previousFireDate(onOrBefore: date, calendar: calendar)
        case .once(let at):
            return at <= date ? at : nil
        }
    }

    /// Plain-language rendering, same voice as a cron summary
    /// ("every day at 9:00 AM" / "once, tomorrow at 9:00 AM").
    var localizedDescriptionText: String {
        switch self {
        case .cron(let cron):
            return cron.localizedDescriptionText
        case .once(let at):
            return String(localized: "once, \(Self.momentText(at))",
                          comment: "Schedule summary for a task that runs a single time; placeholder is a date and time such as “tomorrow at 9:00 AM”")
        }
    }

    /// A one-time run's moment as the middle of a sentence: "today at
    /// 5:00 PM", "tomorrow at 9:00 AM", "Mon, Oct 5 at 5:00 PM", with
    /// the year only when it is not this one. Locale-aware throughout —
    /// the system formatter supplies the words and their order.
    static func momentText(_ date: Date, now: Date = Date(),
                           calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) || calendar.isDateInTomorrow(date)
            || calendar.isDateInYesterday(date) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            formatter.doesRelativeDateFormatting = true
            formatter.formattingContext = .middleOfSentence
            return formatter.string(from: date)
        }
        var style = Date.FormatStyle.dateTime
            .weekday(.abbreviated).month(.abbreviated).day()
            .hour().minute()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) {
            style = style.year()
        }
        return date.formatted(style)
    }
}

// MARK: - Definition

/// Everything a scheduled task is configured to do — the parsed form of
/// one `~/.claude/scheduled-tasks/<name>/SKILL.md`.
struct ScheduledTaskDefinition: Equatable {
    /// Directory name. This is the task's identity and never changes;
    /// renaming edits `description` only, exactly as before.
    var name: String
    var description: String
    /// Raw `schedule:` text — a 5-field cron expression, or a one-time
    /// `once <instant>` (see `TaskSchedule`). Empty means the task has
    /// no schedule and only ever runs when the user presses Run now.
    var scheduleExpression: String = ""
    var workingDirectory: URL?
    var mode: String?
    var model: String?
    var effort: String?
    /// Claude Code's fast mode for the unattended run, written
    /// `fast_mode: true` and only when on. Codex and kimi runs ignore it.
    var fastMode: Bool = false
    /// Codex's speed for the unattended run: nil follows what `codex
    /// exec` resolves by itself (the config's tier in the task's folder,
    /// never a model's catalog default), `default` is codex's explicit
    /// standard, and anything else a tier id the model advertises
    /// ("priority" is the one codex names Fast). Written `service_tier:`;
    /// claude and kimi runs ignore it. See
    /// `AgentLaunchOptions.scheduledRun`.
    var serviceTier: String?
    var agent: String = "claude_code"
    /// `enabled: false` pauses firing without losing the schedule.
    var enabled: Bool = true
    /// Whether a slot missed while SipAI was closed should fire on the
    /// next launch. The one setting that decides whether "keep the app
    /// open" means 9:00 sharp or merely sometime that day.
    var catchUpMissed: Bool = true
    var prompt: String = ""

    /// Frontmatter keys written by someone else (Claude Desktop, a hand
    /// edit), preserved in order across our rewrites.
    var passthroughFields: [(key: String, value: String)] = []

    var schedule: TaskSchedule? {
        TaskSchedule.parse(scheduleExpression)
    }

    /// The schedule this task actually fires on, as one comparable
    /// string — "" when nothing fires it (paused, no schedule, or one
    /// that does not parse). The scheduler keeps it beside its record of
    /// the last slot, so an edit, a pause or a resume reads as the
    /// schedule CHANGING, never as slots the task missed.
    var scheduleInForce: String {
        guard enabled, let schedule else { return "" }
        return schedule.canonicalText
    }

    /// True when a schedule is set but unparseable — the UI says so
    /// rather than showing a task as "never runs".
    var hasUnparseableSchedule: Bool {
        !scheduleExpression.trimmingCharacters(in: .whitespaces).isEmpty
            && schedule == nil
    }

    static func == (lhs: ScheduledTaskDefinition, rhs: ScheduledTaskDefinition) -> Bool {
        lhs.name == rhs.name
            && lhs.description == rhs.description
            && lhs.scheduleExpression == rhs.scheduleExpression
            && lhs.workingDirectory == rhs.workingDirectory
            && lhs.mode == rhs.mode
            && lhs.model == rhs.model
            && lhs.effort == rhs.effort
            && lhs.fastMode == rhs.fastMode
            && lhs.serviceTier == rhs.serviceTier
            && lhs.agent == rhs.agent
            && lhs.enabled == rhs.enabled
            && lhs.catchUpMissed == rhs.catchUpMissed
            && lhs.prompt == rhs.prompt
            && lhs.passthroughFields.map(\.key) == rhs.passthroughFields.map(\.key)
            && lhs.passthroughFields.map(\.value) == rhs.passthroughFields.map(\.value)
    }

    // MARK: Read

    /// Keys this app understands. Everything else round-trips through
    /// `passthroughFields`.
    private static let ownedKeys: Set<String> = [
        "name", "description", "schedule", "cwd", "mode", "model",
        "effort", "fast_mode", "service_tier", "agent", "enabled", "catchup",
    ]

    /// Parse a task directory's SKILL.md. Returns nil when the file is
    /// unreadable; a file with no frontmatter fences is treated as an
    /// all-prompt file, which is what Claude Desktop's simplest tasks
    /// look like.
    static func read(name: String, skillFile: URL) -> ScheduledTaskDefinition? {
        guard let text = try? String(contentsOf: skillFile, encoding: .utf8)
        else { return nil }
        var def = ScheduledTaskDefinition(name: name, description: name)

        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else {
            def.prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return def
        }

        for line in lines[1..<close] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
            let value = unquoted(String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces))
            guard !key.isEmpty else { continue }
            switch key.lowercased() {
            case "name":        break  // identity is the directory name
            case "description": if !value.isEmpty { def.description = value }
            case "schedule":    def.scheduleExpression = value
            case "cwd":         def.workingDirectory = expandedDirectory(value)
            case "mode":        def.mode = value.isEmpty ? nil : value
            case "model":       def.model = value.isEmpty ? nil : value
            case "effort":      def.effort = value.isEmpty ? nil : value
            // On only when the file says so — the opposite default to
            // `enabled`, since fast mode spends usage credits.
            case "fast_mode":   def.fastMode = isTrue(value)
            case "service_tier": def.serviceTier = value.isEmpty ? nil : value
            case "agent":       if !value.isEmpty { def.agent = value }
            case "enabled":     def.enabled = !isFalse(value)
            case "catchup":     def.catchUpMissed = !isFalse(value)
            default:
                if !Self.ownedKeys.contains(key.lowercased()) {
                    def.passthroughFields.append((key: key, value: value))
                }
            }
        }
        lines.removeFirst(close + 1)
        def.prompt = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return def
    }

    private static func isFalse(_ value: String) -> Bool {
        ["false", "no", "0", "off"].contains(value.lowercased())
    }

    private static func isTrue(_ value: String) -> Bool {
        ["true", "yes", "1", "on"].contains(value.lowercased())
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let f = value.first, let l = value.last,
              (f == "\"" && l == "\"") || (f == "'" && l == "'")
        else { return value }
        return String(value.dropFirst().dropLast())
    }

    static func expandedDirectory(_ path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    // MARK: Write

    /// Frontmatter values live one per line between the `---` fences, so
    /// a value carrying a newline would break the block and a value
    /// starting with `---` would close it early. Same sanitation the
    /// creator has always applied — kept here so every writer shares it.
    static func frontmatterSafe(_ value: String) -> String {
        var v = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        while v.hasPrefix("---") {
            v = String(v.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        return v
    }

    /// The full SKILL.md text for this definition.
    func fileContents() -> String {
        // A blank description — empty, or whitespace `frontmatterSafe`
        // trims to nothing — is written as the name, which is what
        // `read` hands back for an empty `description:` line. So a form
        // whose name was cleared writes the same file it reads, and the
        // panel's "unsaved" test (`writesSameFile`) settles after a save.
        let description = Self.frontmatterSafe(description)
        var fields: [String] = [
            "name: \(Self.frontmatterSafe(name))",
            "description: \(description.isEmpty ? Self.frontmatterSafe(name) : description)",
        ]
        let schedule = Self.frontmatterSafe(scheduleExpression)
        if !schedule.isEmpty { fields.append("schedule: \(schedule)") }
        if let cwd = workingDirectory {
            fields.append("cwd: \(Self.frontmatterSafe(cwd.path))")
        }
        if let mode = mode.map(Self.frontmatterSafe), !mode.isEmpty {
            fields.append("mode: \(mode)")
        }
        if let model = model.map(Self.frontmatterSafe), !model.isEmpty {
            fields.append("model: \(model)")
        }
        if let effort = effort.map(Self.frontmatterSafe), !effort.isEmpty {
            fields.append("effort: \(effort)")
        }
        if fastMode { fields.append("fast_mode: true") }
        if let tier = serviceTier.map(Self.frontmatterSafe), !tier.isEmpty {
            fields.append("service_tier: \(tier)")
        }
        if agent != "claude_code" {
            fields.append("agent: \(Self.frontmatterSafe(agent))")
        }
        // Only written when they differ from the default, so a file the
        // user never paused stays short.
        if !enabled { fields.append("enabled: false") }
        if !catchUpMissed { fields.append("catchup: false") }
        for extra in passthroughFields {
            fields.append("\(extra.key): \(Self.frontmatterSafe(extra.value))")
        }
        return "---\n" + fields.joined(separator: "\n") + "\n---\n\n"
            + prompt.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Persist to the task's SKILL.md. Writes atomically so a crash
    /// mid-write can't leave a task with half a prompt — an unattended
    /// run would happily execute the truncated half.
    @discardableResult
    func write(to skillFile: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: skillFile.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try fileContents().write(to: skillFile, atomically: true,
                                     encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
