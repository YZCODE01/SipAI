// ScheduleTimingEditor.swift
// One way to say "when should this run", shared by the two places that
// ask: the composer's schedule popover (creating a task) and the
// scheduled-task card's editor (revising one).
//
// Both screens drive the same `ScheduleTiming`, which round-trips
// through a cron expression: the file format is unchanged (`schedule:`
// frontmatter, 5-field cron), and an expression this editor can't
// express structurally simply opens in Custom with its text intact.

import SwiftUI

// MARK: - Model

/// A schedule as a set of choices rather than a cron string, plus the
/// round trip to and from the expression that actually gets stored.
///
/// `.custom` is the escape hatch AND the honest fallback: cron can say
/// things these pickers cannot ("every 15 minutes on weekdays"), and a
/// task already carrying such an expression must keep it. Nothing here
/// ever rewrites an expression it doesn't understand.
struct ScheduleTiming: Equatable {

    enum Frequency: String, CaseIterable, Identifiable {
        /// No schedule at all — the task exists and can be run by hand.
        case manual
        case hourly
        case daily
        case weekdays
        case weekly
        case monthly
        case custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .manual:
                return String(localized: "Only when I run it",
                              comment: "Schedule frequency option — no automatic runs")
            case .hourly:
                return String(localized: "Every hour", comment: "Schedule frequency option")
            case .daily:
                return String(localized: "Every day", comment: "Schedule frequency option")
            case .weekdays:
                return String(localized: "Every weekday", comment: "Schedule frequency option — Mon–Fri")
            case .weekly:
                return String(localized: "Every week", comment: "Schedule frequency option")
            case .monthly:
                return String(localized: "Every month", comment: "Schedule frequency option")
            case .custom:
                return String(localized: "Custom cron", comment: "Schedule frequency option")
            }
        }
    }

    var frequency: Frequency = .daily
    var minute: Int = 0
    var hour: Int = 9
    /// Cron numbering: 0 = Sunday.
    var weekday: Int = 1
    var dayOfMonth: Int = 1
    /// The raw expression behind `.custom`. Also holds whatever a task
    /// was carrying when it was read, so switching to Custom shows the
    /// real thing rather than an empty box.
    var custom: String = ""

    /// The only minutes the pickers offer: :00, :05 … :55. Anything
    /// else is not representable by this form — see `init(cron:)`.
    static let minuteChoices: [Int] = Array(stride(from: 0, to: 60, by: 5))

    static let weekdayNames: [(Int, String)] = [
        (1, String(localized: "Monday", comment: "Weekday name")),
        (2, String(localized: "Tuesday", comment: "Weekday name")),
        (3, String(localized: "Wednesday", comment: "Weekday name")),
        (4, String(localized: "Thursday", comment: "Weekday name")),
        (5, String(localized: "Friday", comment: "Weekday name")),
        (6, String(localized: "Saturday", comment: "Weekday name")),
        (0, String(localized: "Sunday", comment: "Weekday name")),
    ]

    init() {}

    /// Read an existing `schedule:` expression back into pickers.
    ///
    /// Deliberately strict: every field has to be a shape one of the
    /// frequencies means EXACTLY, or this falls through to `.custom`.
    /// Guessing would silently rewrite a schedule the user tuned by
    /// hand the next time they saved anything else on the card.
    init(cron raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        custom = trimmed
        if trimmed.isEmpty {
            frequency = .manual
            return
        }
        let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5,
              CronSchedule.parse(trimmed) != nil,
              // Anything narrower than "every month" has no picker here.
              fields[3] == "*",
              let parsedMinute = Int(fields[0]),
              // The minute picker offers the five-minute grid only, so
              // an off-grid minute is one of the shapes this form
              // cannot mean EXACTLY. Custom keeps the expression whole
              // and visible; letting it through would leave the picker
              // bound to a value it does not list, which renders as a
              // blank selection and rewrites the minute on the next
              // save of anything else on the card.
              Self.minuteChoices.contains(parsedMinute)
        else {
            frequency = .custom
            return
        }
        minute = parsedMinute
        let hourField = fields[1], domField = fields[2], dowField = fields[4]

        if hourField == "*" {
            if domField == "*", dowField == "*" {
                frequency = .hourly
            } else {
                frequency = .custom
            }
            return
        }
        guard let parsedHour = Int(hourField), (0...23).contains(parsedHour) else {
            frequency = .custom
            return
        }
        hour = parsedHour

        if domField == "*" {
            if dowField == "*" {
                frequency = .daily
            } else if dowField == "1-5" {
                frequency = .weekdays
            } else if let dow = Int(dowField), (0...7).contains(dow) {
                frequency = .weekly
                // Cron spells Sunday both 0 and 7.
                weekday = dow == 7 ? 0 : dow
            } else {
                frequency = .custom
            }
            return
        }
        if dowField == "*", let day = Int(domField), (1...31).contains(day) {
            frequency = .monthly
            dayOfMonth = day
            return
        }
        frequency = .custom
    }

    /// The expression to store: empty for "no schedule", nil when the
    /// custom text isn't a schedule at all (the caller refuses to save).
    var cronExpression: String? {
        switch frequency {
        case .manual:   return ""
        case .hourly:   return "\(minute) * * * *"
        case .daily:    return "\(minute) \(hour) * * *"
        case .weekdays: return "\(minute) \(hour) * * 1-5"
        case .weekly:   return "\(minute) \(hour) * * \(weekday)"
        case .monthly:  return "\(minute) \(hour) \(dayOfMonth) * *"
        case .custom:
            let trimmed = custom.trimmingCharacters(in: .whitespaces)
            return CronSchedule.parse(trimmed) == nil ? nil : trimmed
        }
    }

    var isValid: Bool { cronExpression != nil }

    /// Short human phrasing for chips and banners. Routed through the
    /// same parser the scheduler fires on, so a summary can never
    /// describe a different schedule from the one that will run.
    var summary: String {
        guard let expression = cronExpression else {
            return String(localized: "custom cron",
                          comment: "Schedule summary placeholder for an unfinished custom expression")
        }
        if expression.isEmpty {
            return String(localized: "no schedule",
                          comment: "Schedule summary when the task only runs on demand")
        }
        return CronSchedule.parse(expression)?.localizedDescriptionText ?? expression
    }
}

// MARK: - Editor

/// The pickers themselves. Both call sites render the same controls in
/// the same order; only the trimmings differ.
struct ScheduleTimingEditor: View {
    @Binding var timing: ScheduleTiming

    /// Whether "Only when I run it" is on offer. The card shows it (a
    /// saved task is allowed to have no schedule); the composer's
    /// popover doesn't, because its own toggle already means that.
    var offersManual: Bool = false

    /// The line under the fields naming what was chosen and when it next
    /// fires. The composer popover has its own caption block and turns
    /// this off.
    var showsHint: Bool = true

    var font: CGFloat = 12

    /// Exactly the five-minute grid — :00, :05 … :55, nothing else.
    ///
    /// `ScheduleTiming.init(cron:)` routes an off-grid minute to
    /// Custom, which shows the real expression and preserves it
    /// verbatim — so nothing is demoted silently and no schedule is
    /// rewritten.
    private var minuteChoices: [Int] { ScheduleTiming.minuteChoices }

    private var frequencies: [ScheduleTiming.Frequency] {
        ScheduleTiming.Frequency.allCases.filter {
            offersManual || $0 != .manual
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(String(localized: "Repeats",
                          comment: "Schedule editor frequency picker label"),
                   selection: frequencyBinding) {
                ForEach(frequencies) { option in
                    Text(verbatim: option.label).tag(option)
                }
            }

            if timing.frequency == .weekly {
                Picker(String(localized: "On",
                              comment: "Schedule editor weekday picker label"),
                       selection: $timing.weekday) {
                    ForEach(ScheduleTiming.weekdayNames, id: \.0) { value, label in
                        Text(verbatim: label).tag(value)
                    }
                }
            }

            if timing.frequency == .monthly {
                Picker(String(localized: "On day",
                              comment: "Schedule editor day-of-month picker label"),
                       selection: $timing.dayOfMonth) {
                    ForEach(1...31, id: \.self) { day in
                        Text(verbatim: "\(day)").tag(day)
                    }
                }
                // Cron simply skips a day the month doesn't have, so 31
                // means "the months that have one" — say so rather than
                // letting the user infer a monthly run that isn't.
                if timing.dayOfMonth > 28 {
                    Text("Months without this day are skipped.",
                         comment: "Schedule editor note under a day-of-month above 28")
                        .font(.system(size: font - 1))
                        .foregroundColor(SipDesign.textHint)
                }
            }

            switch timing.frequency {
            case .manual:
                EmptyView()
            case .custom:
                TextField(
                    String(localized: "5-field cron, e.g. 0 9 * * 1-5",
                           comment: "Schedule editor custom cron placeholder"),
                    text: $timing.custom
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: font, design: .monospaced))
            case .hourly:
                Picker(String(localized: "At minute",
                              comment: "Schedule editor minute picker label for hourly runs"),
                       selection: $timing.minute) {
                    minuteRows
                }
            case .daily, .weekdays, .weekly, .monthly:
                HStack(spacing: 4) {
                    Picker(String(localized: "At",
                                  comment: "Schedule editor time picker label"),
                           selection: $timing.hour) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(verbatim: String(format: "%02d", hour)).tag(hour)
                        }
                    }
                    .fixedSize()
                    Text(verbatim: ":")
                        .foregroundColor(SipDesign.textSecondary)
                    Picker("", selection: $timing.minute) { minuteRows }
                        .labelsHidden()
                        .fixedSize()
                    Spacer(minLength: 0)
                }
            }

            if showsHint {
                Text(verbatim: hint)
                    .font(.system(size: font - 1))
                    .foregroundColor(timing.isValid ? SipDesign.textSecondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: font))
    }

    private var minuteRows: some View {
        ForEach(minuteChoices, id: \.self) { minute in
            Text(verbatim: String(format: "%02d", minute)).tag(minute)
        }
    }

    /// Switching INTO Custom hands over the expression the pickers were
    /// describing, so the mode change is a starting point rather than a
    /// blank box. Switching out leaves `custom` alone — flipping back
    /// finds the text still there.
    private var frequencyBinding: Binding<ScheduleTiming.Frequency> {
        Binding(
            get: { timing.frequency },
            set: { chosen in
                if chosen == .custom, timing.frequency != .custom,
                   let current = timing.cronExpression, !current.isEmpty {
                    timing.custom = current
                }
                timing.frequency = chosen
            }
        )
    }

    private var hint: String {
        guard let expression = timing.cronExpression else {
            return String(localized: "Not a valid 5-field cron expression (minute hour day month weekday).",
                          comment: "Schedule editor hint: parse failure")
        }
        if expression.isEmpty {
            return String(localized: "Nothing fires this task — use Run now when you want it.",
                          comment: "Schedule editor hint: no schedule")
        }
        guard let schedule = CronSchedule.parse(expression) else { return expression }
        let described = schedule.localizedDescriptionText
        guard let next = schedule.nextFireDate(after: Date()) else { return described }
        return String(localized: "Runs \(described) — next \(Self.absolute(next))",
                      comment: "Schedule editor hint: description plus next fire time")
    }

    private static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }
}
