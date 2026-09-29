// ScheduleTimingEditor.swift
// One way to say "when should this run", shared by the two places that
// ask: the composer's schedule popover (creating a task) and the
// scheduled-task card's editor (revising one).
//
// Both screens drive the same `ScheduleTiming`, which round-trips
// through the stored `schedule:` value — a 5-field cron expression for
// a recurring schedule, `once <instant>` for a single run (see
// `TaskSchedule`). An expression the chips can't express structurally
// simply opens in Custom (cron) with its text intact.
//
// Every choice is a chip. The frequency and the weekday are chips in a
// row; the time, the day of the month and a one-time run's date are a
// chip naming the current value, which opens a grid of chips below its
// row. Inline rather than in popovers, so the composer's copy — itself
// inside a popover — never stacks one popover on another.

import AppKit
import SwiftUI

// MARK: - Model

/// A schedule as a set of choices rather than a stored string, plus the
/// round trip to and from the value that actually gets stored.
///
/// `.custom` is the escape hatch AND the honest fallback: cron can say
/// things these chips cannot ("every 15 minutes on weekdays"), and a
/// task already carrying such an expression must keep it. Nothing here
/// ever rewrites an expression it doesn't understand.
struct ScheduleTiming: Equatable {

    enum Frequency: String, CaseIterable, Identifiable {
        /// No schedule at all — the task exists and can be run by hand.
        case manual
        /// A single run at a date and time in the future.
        case once
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
            case .once:
                return String(localized: "Once",
                              comment: "Schedule frequency option — a single run at a chosen date and time")
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
                return String(localized: "Custom (cron)",
                              comment: "Schedule frequency option — a hand-written cron expression, for advanced users")
            }
        }

        /// Hover text for the options whose label cannot say it all.
        var help: String? {
            switch self {
            case .once:
                return String(localized: "Runs one time, at the date and time you pick",
                              comment: "Hover text on the Once schedule option")
            case .custom:
                return String(localized: "For advanced users: write the schedule as a 5-field cron expression (minute hour day month weekday)",
                              comment: "Hover text on the Custom (cron) schedule option")
            default:
                return nil
            }
        }

        /// The frequencies a 5-field cron expression spells — the ones
        /// whose value can be handed to Custom as a starting point.
        var isCronShaped: Bool {
            switch self {
            case .hourly, .daily, .weekdays, .weekly, .monthly, .custom: return true
            case .manual, .once: return false
            }
        }
    }

    var frequency: Frequency = .daily
    var minute: Int = 0
    var hour: Int = 9
    /// Cron numbering: 0 = Sunday.
    var weekday: Int = 1
    var dayOfMonth: Int = 1
    /// Start of the day a one-time run falls on. Its time of day is
    /// `hour` / `minute`, which every frequency shares, so switching
    /// between them keeps the time the user picked.
    var onceDay: Date = Calendar.current.startOfDay(for: Date())
    /// The raw expression behind `.custom`. Also holds whatever a task
    /// was carrying when it was read, so switching to Custom shows the
    /// real thing rather than an empty box.
    var custom: String = ""

    /// The only minutes the chips offer: :00, :05 … :55. Anything
    /// else is not representable by this form — see `init(schedule:)`.
    static let minuteChoices: [Int] = Array(stride(from: 0, to: 60, by: 5))

    /// How far ahead a one-time run must be when it is picked. The
    /// scheduler looks every 30 seconds, and a moment that has already
    /// gone by the time the task is written would be refused anyway.
    static let minimumLead: TimeInterval = 60

    /// Full weekday names, cron-numbered — the weekday chips' spoken
    /// labels (the chips themselves show the calendar's short names).
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

    /// Read an existing `schedule:` value back into chips.
    ///
    /// Deliberately strict: every field has to be a shape one of the
    /// frequencies means EXACTLY, or this falls through to `.custom`.
    /// Guessing would silently rewrite a schedule the user tuned by
    /// hand the next time they saved anything else on the card.
    init(schedule raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        custom = trimmed
        if trimmed.isEmpty {
            frequency = .manual
            return
        }
        if let moment = TaskSchedule.onceDate(in: trimmed) {
            // The moment is kept to the minute it names, on or off the
            // five-minute grid: nothing is rewritten unless the user
            // picks a new time. Custom starts empty rather than holding
            // a value that is not cron.
            let calendar = Calendar.current
            let parts = calendar.dateComponents([.hour, .minute], from: moment)
            frequency = .once
            hour = parts.hour ?? hour
            minute = parts.minute ?? minute
            onceDay = calendar.startOfDay(for: moment)
            custom = ""
            return
        }
        let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5,
              CronSchedule.parse(trimmed) != nil,
              // Anything narrower than "every month" has no chip here.
              fields[3] == "*",
              let parsedMinute = Int(fields[0]),
              // The minute chips offer the five-minute grid only, so an
              // off-grid minute is one of the shapes this form cannot
              // mean EXACTLY. Custom keeps the expression whole and
              // visible; letting it through would leave a chip naming a
              // value no grid cell holds, and rewrite the minute on the
              // next pick of anything else.
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

    /// The moment a `.once` selection names.
    func onceDate(calendar: Calendar = .current) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: onceDay)
    }

    /// The value to store: empty for "no schedule", nil when the custom
    /// text isn't a schedule at all (the caller refuses to save).
    var expression: String? {
        switch frequency {
        case .manual:   return ""
        case .once:     return onceDate().map { TaskSchedule.onceExpression(for: $0) }
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

    var isValid: Bool { expression != nil }

    /// Why this selection cannot be written as a schedule right now, in
    /// the words the form shows — nil when it can. A one-time moment
    /// that has already gone is refused here rather than by the chips
    /// alone: the form can sit open while the clock passes it.
    func problem(now: Date = Date()) -> String? {
        guard expression != nil else {
            return String(localized: "That isn't a valid 5-field cron expression (minute hour day month weekday).",
                          comment: "Schedule validation: bad cron")
        }
        if frequency == .once, let moment = onceDate(), moment <= now {
            return String(localized: "That time has already passed. Pick a later one.",
                          comment: "Schedule validation: a one-time run was set for a moment in the past")
        }
        return nil
    }

    /// Short human phrasing for chips and banners. Routed through the
    /// same parser the scheduler fires on, so a summary can never
    /// describe a different schedule from the one that will run.
    var summary: String {
        guard let expression = expression else {
            return String(localized: "incomplete cron expression",
                          comment: "Schedule summary placeholder while the Custom (cron) field does not hold a valid expression")
        }
        if expression.isEmpty {
            return String(localized: "no schedule",
                          comment: "Schedule summary when the task only runs on demand")
        }
        return TaskSchedule.parse(expression)?.localizedDescriptionText ?? expression
    }

    // MARK: Choosing

    /// Switch frequency. Entering Custom hands over the expression the
    /// chips were describing, so the mode change is a starting point
    /// rather than a blank box; switching out leaves `custom` alone, so
    /// flipping back finds the text still there. Entering Once lands on
    /// the first day the chosen time is still ahead — today, or else
    /// tomorrow — so the first thing it shows is never in the past.
    mutating func select(_ chosen: Frequency, now: Date = Date(),
                         calendar: Calendar = .current) {
        guard chosen != frequency else { return }
        if chosen == .custom, frequency.isCronShaped,
           let current = expression, !current.isEmpty {
            custom = current
        }
        if chosen == .once {
            let today = calendar.startOfDay(for: now)
            onceDay = Self.isAhead(hour: hour, minute: minute, on: today,
                                   now: now, calendar: calendar)
                ? today
                : calendar.date(byAdding: .day, value: 1, to: today) ?? today
        }
        frequency = chosen
    }

    /// Pick the day of a one-time run. When the time already chosen has
    /// passed on that day — only ever today — it moves to the first
    /// slot still ahead, rather than leaving a moment in the past.
    mutating func selectOnceDay(_ day: Date, now: Date = Date(),
                                calendar: Calendar = .current) {
        onceDay = calendar.startOfDay(for: day)
        if !Self.isAhead(hour: hour, minute: minute, on: onceDay,
                         now: now, calendar: calendar),
           let slot = Self.firstSlot(on: onceDay, after: now, calendar: calendar) {
            hour = slot.hour
            minute = slot.minute
        }
    }

    /// Whether `hour:minute` on `day` is at least `minimumLead` ahead.
    static func isAhead(hour: Int, minute: Int, on day: Date, now: Date,
                        calendar: Calendar = .current) -> Bool {
        guard let moment = calendar.date(bySettingHour: hour, minute: minute,
                                         second: 0, of: day)
        else { return false }
        return moment.timeIntervalSince(now) >= minimumLead
    }

    /// The first time on the five-minute grid that is still ahead on
    /// `day`, or nil when the day has none left.
    static func firstSlot(on day: Date, after now: Date,
                          calendar: Calendar = .current) -> (hour: Int, minute: Int)? {
        for hour in 0..<24 {
            for minute in minuteChoices
            where isAhead(hour: hour, minute: minute, on: day, now: now, calendar: calendar) {
                return (hour, minute)
            }
        }
        return nil
    }
}

// MARK: - Editor

/// The chips themselves. Both call sites render the same controls in
/// the same order; only the trimmings differ.
///
/// Sizes are the design-size convention (`.sipFont`, `SipFont.ratio`):
/// both hosts — the composer's popover and the task panel — sit outside
/// any transcript re-scope.
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

    @Environment(\.sipFontScale) private var fontScale

    /// The grid open under its row, if any — one at a time.
    @State private var open: Chooser? = nil

    private enum Chooser { case time, onceDay, dayOfMonth }

    private var ratio: CGFloat { SipFont.ratio(fontScale) }

    private var frequencies: [ScheduleTiming.Frequency] {
        ScheduleTiming.Frequency.allCases.filter {
            offersManual || $0 != .manual
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * ratio) {
            ScheduleChipFlow(spacing: 5 * ratio) {
                ForEach(frequencies) { option in
                    ScheduleChoiceChip(title: option.label,
                                       selected: timing.frequency == option) {
                        timing.select(option)
                        open = nil
                    }
                    .help(ifPresent: option.help)
                }
            }

            fields

            if showsHint {
                Text(verbatim: hint)
                    .sipFont(11)
                    .foregroundColor(timing.problem() == nil
                                     ? SipDesign.textSecondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The frequency and the grids animate open and shut together, so
        // the host's height changes in one motion.
        .animation(.easeInOut(duration: 0.15), value: open)
        .animation(.easeInOut(duration: 0.15), value: timing.frequency)
    }

    // MARK: Rows

    @ViewBuilder
    private var fields: some View {
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
            .sipFont(12, design: .monospaced)
        case .once:
            rows {
                row(String(localized: "Date",
                           comment: "Schedule editor label before the day chips of a one-time run")) {
                    onceDayChips
                }
                if open == .onceDay {
                    OnceCalendar(selected: timing.onceDay,
                                 isAvailable: dayHasSlot) { day in
                        timing.selectOnceDay(day)
                        open = nil
                    }
                }
                timeRow
            }
        case .hourly:
            rows {
                row(String(localized: "At minute",
                           comment: "Schedule editor minute picker label for hourly runs")) {
                    ScheduleMenuChip(title: String(format: ":%02d", timing.minute),
                                     isOpen: open == .time) { toggle(.time) }
                }
                if open == .time { timeGrid(showsHours: false) }
            }
        case .daily, .weekdays:
            rows { timeRow }
        case .weekly:
            rows {
                row(String(localized: "On",
                           comment: "Schedule editor weekday picker label")) {
                    weekdayChips
                }
                timeRow
            }
        case .monthly:
            rows {
                row(String(localized: "On day",
                           comment: "Schedule editor day-of-month picker label")) {
                    ScheduleMenuChip(title: "\(timing.dayOfMonth)",
                                     isOpen: open == .dayOfMonth) { toggle(.dayOfMonth) }
                }
                if open == .dayOfMonth {
                    DayOfMonthGrid(selected: timing.dayOfMonth) { day in
                        timing.dayOfMonth = day
                        open = nil
                    }
                }
                // Cron simply skips a day the month doesn't have, so 31
                // means "the months that have one" — say so rather than
                // letting the user infer a monthly run that isn't.
                if timing.dayOfMonth > 28 {
                    Text("Months without this day are skipped.",
                         comment: "Schedule editor note under a day-of-month above 28")
                        .sipFont(11)
                        .foregroundColor(SipDesign.textHint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                timeRow
            }
        }
    }

    /// A label column shared by every row, sized to the widest label in
    /// whichever language is on screen. A view placed in the grid
    /// outside a `GridRow` — an open chooser, a note — spans the whole
    /// width under its row.
    private func rows<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Grid(alignment: .leadingFirstTextBaseline,
             horizontalSpacing: 8 * ratio, verticalSpacing: 7 * ratio) {
            content()
        }
    }

    private func row<Content: View>(_ label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(verbatim: label)
                .sipFont(12)
                .foregroundColor(SipDesign.textSecondary)
                .gridColumnAlignment(.leading)
            content()
        }
    }

    @ViewBuilder
    private var timeRow: some View {
        row(String(localized: "At", comment: "Schedule editor time picker label")) {
            ScheduleMenuChip(title: CronSchedule.clockText(hour: timing.hour,
                                                           minute: timing.minute),
                             systemImage: "clock",
                             isOpen: open == .time) { toggle(.time) }
        }
        if open == .time { timeGrid(showsHours: true) }
    }

    private func timeGrid(showsHours: Bool) -> some View {
        TimeChipGrid(hour: timing.hour,
                     minute: timing.minute,
                     showsHours: showsHours,
                     isAvailable: timeIsAvailable,
                     onPickHour: { hour in
                         timing.hour = hour
                         // Keep the minute if it still stands on this
                         // hour; otherwise the first one that does.
                         if !timeIsAvailable(hour, timing.minute),
                            let first = ScheduleTiming.minuteChoices
                                .first(where: { timeIsAvailable(hour, $0) }) {
                             timing.minute = first
                         }
                     },
                     onPickMinute: { minute in
                         timing.minute = minute
                         open = nil
                     })
    }

    // MARK: One-time run

    private var onceDayChips: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let onToday = calendar.isDate(timing.onceDay, inSameDayAs: today)
        let onTomorrow = calendar.isDate(timing.onceDay, inSameDayAs: tomorrow)
        let onOther = !onToday && !onTomorrow
        return ScheduleChipFlow(spacing: 5 * ratio) {
            ScheduleChoiceChip(title: String(localized: "Today",
                                             comment: "Schedule editor chip: run the one-time task today"),
                               selected: onToday,
                               enabled: dayHasSlot(today)) {
                timing.selectOnceDay(today)
                open = nil
            }
            ScheduleChoiceChip(title: String(localized: "Tomorrow",
                                             comment: "Schedule editor chip: run the one-time task tomorrow"),
                               selected: onTomorrow) {
                timing.selectOnceDay(tomorrow)
                open = nil
            }
            ScheduleMenuChip(title: onOther
                                ? Self.dayText(timing.onceDay)
                                : String(localized: "Pick a date",
                                         comment: "Schedule editor chip that opens a calendar for a one-time run"),
                             systemImage: "calendar",
                             isOpen: open == .onceDay,
                             selected: onOther) { toggle(.onceDay) }
        }
    }

    /// Whether any time is still ahead on `day`. Only today can say no.
    private func dayHasSlot(_ day: Date) -> Bool {
        ScheduleTiming.firstSlot(on: day, after: Date()) != nil
    }

    /// A one-time run's grid greys out every time already behind the
    /// clock on the chosen day; the recurring frequencies can pick any.
    private func timeIsAvailable(_ hour: Int, _ minute: Int) -> Bool {
        guard timing.frequency == .once else { return true }
        return ScheduleTiming.isAhead(hour: hour, minute: minute,
                                      on: timing.onceDay, now: Date())
    }

    // MARK: Weekly

    private var weekdayChips: some View {
        let calendar = Calendar.current
        let symbols = calendar.shortStandaloneWeekdaySymbols
        // Cron numbers Sunday 0; Calendar numbers it 1. Start the row on
        // the locale's own first day of the week.
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }
        return ScheduleChipFlow(spacing: 5 * ratio) {
            ForEach(order, id: \.self) { dow in
                ScheduleChoiceChip(title: dow < symbols.count ? symbols[dow] : "\(dow)",
                                   selected: timing.weekday == dow) {
                    timing.weekday = dow
                }
                .accessibilityLabel(ScheduleTiming.weekdayNames
                    .first { $0.0 == dow }?.1 ?? "\(dow)")
            }
        }
    }

    // MARK: Text

    private func toggle(_ chooser: Chooser) {
        open = open == chooser ? nil : chooser
    }

    /// A day as a chip names it: weekday, month and day, with the year
    /// only when it is not this one.
    static func dayText(_ day: Date, now: Date = Date(),
                        calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle.dateTime
            .weekday(.abbreviated).month(.abbreviated).day()
        if !calendar.isDate(day, equalTo: now, toGranularity: .year) {
            style = style.year()
        }
        return day.formatted(style)
    }

    private var hint: String {
        if let problem = timing.problem() { return problem }
        guard let expression = timing.expression else { return "" }
        if expression.isEmpty {
            return String(localized: "Nothing fires this task — use Run now when you want it.",
                          comment: "Schedule editor hint: no schedule")
        }
        guard let schedule = TaskSchedule.parse(expression) else { return expression }
        let described = schedule.localizedDescriptionText
        guard let next = schedule.nextFireDate(after: Date()) else { return described }
        if schedule.isOneTime {
            return String(localized: "Runs \(described) — \(Self.relative(next))",
                          comment: "Schedule editor hint for a one-time run: its date and time, then how far away it is (“in 3 hours”)")
        }
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

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Choosers

/// Hours and minutes as chips. Hours read the way the Mac's own clock
/// does ("9 AM" or "09"); a time the caller says is unavailable — behind
/// the clock, for a one-time run today — is shown but cannot be picked.
private struct TimeChipGrid: View {
    let hour: Int
    let minute: Int
    let showsHours: Bool
    let isAvailable: (Int, Int) -> Bool
    let onPickHour: (Int) -> Void
    let onPickMinute: (Int) -> Void

    @Environment(\.sipFontScale) private var fontScale

    /// The locale's hour on its own — "h a" in a 12-hour region, "HH"
    /// in a 24-hour one.
    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j")
        return formatter
    }()

    private static func hourText(_ hour: Int) -> String {
        guard let date = Calendar.current.date(bySettingHour: hour, minute: 0,
                                               second: 0, of: Date())
        else { return String(format: "%02d", hour) }
        return hourFormatter.string(from: date)
    }

    var body: some View {
        let ratio = SipFont.ratio(fontScale)
        VStack(alignment: .leading, spacing: 5 * ratio) {
            if showsHours {
                caption(String(localized: "Hour",
                               comment: "Caption over the hour chips in the schedule editor"))
                // 24 hours in rows of 12, 8, 6 or 4 — whichever is the
                // most that fits — so the rows split the day evenly.
                ScheduleChipGrid(columnChoices: [12, 8, 6, 4], spacing: 4 * ratio) {
                    ForEach(0..<24, id: \.self) { h in
                        ScheduleChoiceChip(
                            title: Self.hourText(h),
                            selected: h == hour,
                            enabled: ScheduleTiming.minuteChoices.contains { isAvailable(h, $0) },
                            fillsCell: true
                        ) { onPickHour(h) }
                    }
                }
            }
            caption(String(localized: "Minute",
                           comment: "Caption over the minute chips in the schedule editor"))
            ScheduleChipGrid(columnChoices: [12, 6, 4], spacing: 4 * ratio) {
                ForEach(ScheduleTiming.minuteChoices, id: \.self) { m in
                    ScheduleChoiceChip(
                        title: String(format: ":%02d", m),
                        selected: m == minute,
                        enabled: isAvailable(hour, m),
                        fillsCell: true
                    ) { onPickMinute(m) }
                }
            }
        }
        .modifier(ChooserTray())
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .sipFont(10, weight: .semibold)
            .foregroundColor(SipDesign.textSecondary)
    }
}

/// A month of day chips for a one-time run. Days before today are
/// shown but cannot be picked, and the months only go forward from this
/// one — so the calendar cannot name a past date, and reaches any date
/// in the future.
private struct OnceCalendar: View {
    let selected: Date
    /// Whether a day can still be picked — a past day never, and today
    /// only while some time is left in it.
    let isAvailable: (Date) -> Bool
    let onPick: (Date) -> Void

    @Environment(\.sipFontScale) private var fontScale
    /// First day of the month on screen.
    @State private var month: Date

    init(selected: Date, isAvailable: @escaping (Date) -> Bool,
         onPick: @escaping (Date) -> Void) {
        self.selected = selected
        self.isAvailable = isAvailable
        self.onPick = onPick
        _month = State(initialValue: Self.firstOfMonth(selected))
    }

    private static func firstOfMonth(_ date: Date) -> Date {
        let calendar = Calendar.current
        return calendar.date(from: calendar.dateComponents([.year, .month], from: date))
            ?? calendar.startOfDay(for: date)
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMy")
        return formatter
    }()

    var body: some View {
        let ratio = SipFont.ratio(fontScale)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let canGoBack = month > Self.firstOfMonth(today)
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }
        let firstWeekday = calendar.component(.weekday, from: month)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let days: [Date] = (0..<dayCount).compactMap {
            calendar.date(byAdding: .day, value: $0, to: month)
        }

        VStack(alignment: .leading, spacing: 6 * ratio) {
            HStack(spacing: 4 * ratio) {
                stepButton("chevron.left",
                           label: String(localized: "Previous month",
                                         comment: "Accessibility label of the calendar's back arrow in the schedule editor"),
                           enabled: canGoBack) { step(-1) }
                Spacer(minLength: 0)
                Text(verbatim: Self.monthFormatter.string(from: month))
                    .sipFont(12, weight: .semibold)
                    .foregroundColor(SipDesign.textPrimary)
                Spacer(minLength: 0)
                stepButton("chevron.right",
                           label: String(localized: "Next month",
                                         comment: "Accessibility label of the calendar's forward arrow in the schedule editor"),
                           enabled: true) { step(1) }
            }
            ScheduleChipGrid(columnChoices: [7], spacing: 3 * ratio, fillsWidth: true) {
                ForEach(order, id: \.self) { dow in
                    Text(verbatim: dow < symbols.count ? symbols[dow] : "")
                        .sipFont(10, weight: .semibold)
                        .foregroundColor(SipDesign.textHint)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
                ForEach(0..<leading, id: \.self) { _ in
                    Color.clear.frame(width: 1, height: 1)
                }
                ForEach(days, id: \.self) { day in
                    ScheduleChoiceChip(
                        title: "\(calendar.component(.day, from: day))",
                        selected: calendar.isDate(day, inSameDayAs: selected),
                        enabled: day >= today && isAvailable(day),
                        outlined: calendar.isDate(day, inSameDayAs: today),
                        fillsCell: true
                    ) { onPick(day) }
                    .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                }
            }
        }
        .frame(maxWidth: 250 * ratio)
        .modifier(ChooserTray())
    }

    private func step(_ months: Int) {
        if let moved = Calendar.current.date(byAdding: .month, value: months, to: month) {
            month = moved
        }
    }

    private func stepButton(_ symbol: String, label: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .sipFont(11, weight: .semibold)
                .foregroundColor(enabled ? SipDesign.textSecondary : SipDesign.textHint.opacity(0.5))
                .padding(4 * SipFont.ratio(fontScale))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// 1 … 31 as chips, a week to a row.
private struct DayOfMonthGrid: View {
    let selected: Int
    let onPick: (Int) -> Void
    @Environment(\.sipFontScale) private var fontScale

    var body: some View {
        let ratio = SipFont.ratio(fontScale)
        ScheduleChipGrid(columnChoices: [7], spacing: 3 * ratio, fillsWidth: true) {
            ForEach(1...31, id: \.self) { day in
                ScheduleChoiceChip(title: "\(day)", selected: day == selected,
                                   fillsCell: true) { onPick(day) }
            }
        }
        .frame(maxWidth: 250 * ratio)
        .modifier(ChooserTray())
    }
}

/// The faint panel an open chooser sits in, so it reads as belonging to
/// the chip above it rather than as more of the form.
private struct ChooserTray: ViewModifier {
    @Environment(\.sipFontScale) private var fontScale

    func body(content: Content) -> some View {
        let ratio = SipFont.ratio(fontScale)
        content
            .padding(7 * ratio)
            .background(
                RoundedRectangle(cornerRadius: 8 * ratio)
                    .fill(Color.gray.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8 * ratio)
                    .stroke(SipDesign.borderLight, lineWidth: 1)
            )
    }
}

// MARK: - Chips

/// One option of a set — a frequency, a weekday, a day, an hour. Picked
/// reads as the accent fill, the same blue as every picked value in the
/// app; the rest are a quiet grey that deepens under the pointer.
struct ScheduleChoiceChip: View {
    let title: String
    let selected: Bool
    var enabled: Bool = true
    /// Today, in the calendar: a ring, so it stays findable when it is
    /// not the day picked.
    var outlined: Bool = false
    /// In a grid every chip takes its cell's width, so a column of them
    /// lines up instead of hugging each label.
    var fillsCell: Bool = false
    let action: () -> Void

    @Environment(\.sipFontScale) private var fontScale
    @State private var hovered = false

    var body: some View {
        let ratio = SipFont.ratio(fontScale)
        let shape = RoundedRectangle(cornerRadius: 6 * ratio)
        Button(action: action) {
            Text(verbatim: title)
                .sipFont(12)
                .foregroundColor(foreground)
                .lineLimit(1)
                .padding(.horizontal, (fillsCell ? 5 : 9) * ratio)
                .padding(.vertical, 4 * ratio)
                .frame(maxWidth: fillsCell ? .infinity : nil)
                .background(shape.fill(fill))
                .overlay(shape.stroke(outlined && !selected ? SipDesign.blue.opacity(0.6) : .clear,
                                      lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering in
            // Never leave a disabled chip looking live.
            hovered = hovering && enabled
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fill: Color {
        if selected { return SipDesign.blue }
        guard enabled else { return Color.gray.opacity(0.04) }
        return hovered ? Color.gray.opacity(0.22) : Color.gray.opacity(0.1)
    }

    private var foreground: Color {
        if selected { return .white }
        return enabled ? SipDesign.textPrimary : SipDesign.textHint.opacity(0.6)
    }
}

/// A chip that names the value in force and opens its chooser below the
/// row — the time, a day of the month, a one-time run's date.
struct ScheduleMenuChip: View {
    let title: String
    var systemImage: String? = nil
    let isOpen: Bool
    /// Drawn as the picked option of its row — the date chip, when the
    /// date it names is the one in force.
    var selected: Bool = false
    let action: () -> Void

    @Environment(\.sipFontScale) private var fontScale
    @State private var hovered = false

    var body: some View {
        let ratio = SipFont.ratio(fontScale)
        let shape = RoundedRectangle(cornerRadius: 6 * ratio)
        Button(action: action) {
            // On the text's baseline, not centred: the row's label is
            // aligned to this chip's first baseline, and a centred stack
            // reports its small chevron's — which sits above the text
            // and lifts the label off the line.
            HStack(alignment: .firstTextBaseline, spacing: 4 * ratio) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .sipFont(11)
                }
                Text(verbatim: title)
                    .sipFont(12)
                    .lineLimit(1)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .sipFont(8, weight: .semibold)
                    .opacity(0.7)
            }
            .foregroundColor(selected ? .white : SipDesign.textPrimary)
            .padding(.horizontal, 9 * ratio)
            .padding(.vertical, 4 * ratio)
            .background(shape.fill(fill))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fill: Color {
        if selected { return SipDesign.blue }
        if isOpen { return SipDesign.blue.opacity(hovered ? 0.24 : 0.16) }
        return hovered ? Color.gray.opacity(0.22) : Color.gray.opacity(0.1)
    }
}

// MARK: - Layouts

/// Chips left to right, wrapping onto a new line when the next one does
/// not fit — so a row of options survives a narrow popover and the
/// largest type size alike. Not lazy: every chip is laid out up front,
/// which a few dozen chips can afford.
///
/// Lines are broken at the width the container was PROPOSED, in both
/// passes, never at the width it was placed in. The two differ by the
/// rounding of the frame to whole pixels, and a line that exactly fit
/// the measured width then no longer fits the placed one: its last chip
/// drops to a line the reported height never counted, on top of
/// whatever sits below.
struct ScheduleChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let placed = arrange(width: proposal.width, subviews: subviews)
        return placed.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let placed = arrange(width: proposal.width ?? bounds.width, subviews: subviews)
        for (index, frame) in placed.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews)
    -> (frames: [CGRect], size: CGSize) {
        let limit = width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            // A chip wider than the whole line gets the line, and its
            // label truncates, rather than running out of the host.
            if size.width > limit { size.width = limit }
            if x > 0, x + size.width > limit {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (frames, CGSize(width: widest, height: y + lineHeight))
    }
}

/// Chips of one width in even rows: the widest chip sets the cell, and
/// the row holds the most of `columnChoices` that fits. A day grid asks
/// for exactly 7; the hours ask for a count that divides the day. Not
/// lazy, for the same reason as `ScheduleChipFlow`.
///
/// `fillsWidth` spreads the cells across the width offered — a month
/// under its own header, whose arrows sit at the edges. Columns are
/// counted at the PROPOSED width in both passes, for the reason
/// `ScheduleChipFlow` gives.
struct ScheduleChipGrid: Layout {
    var columnChoices: [Int]
    var spacing: CGFloat
    var fillsWidth: Bool = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        var cell = cellSize(subviews)
        let columns = columnCount(width: proposal.width, cell: cell.width)
        cell.width = spread(cell.width, columns: columns, width: proposal.width)
        let rows = (subviews.count + columns - 1) / columns
        return CGSize(width: CGFloat(columns) * cell.width + CGFloat(columns - 1) * spacing,
                      height: CGFloat(rows) * cell.height + CGFloat(rows - 1) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        var cell = cellSize(subviews)
        let width = proposal.width ?? bounds.width
        let columns = columnCount(width: width, cell: cell.width)
        cell.width = spread(cell.width, columns: columns, width: width)
        for (index, subview) in subviews.enumerated() {
            let column = index % columns, row = index / columns
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(column) * (cell.width + spacing),
                            y: bounds.minY + CGFloat(row) * (cell.height + spacing)),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: cell.width, height: cell.height))
        }
    }

    /// The cell width once spread over `width`, never narrower than the
    /// widest chip needs.
    private func spread(_ cell: CGFloat, columns: Int, width: CGFloat?) -> CGFloat {
        guard fillsWidth, let width, width.isFinite else { return cell }
        return max(cell, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
    }

    private func cellSize(_ subviews: Subviews) -> CGSize {
        subviews.reduce(CGSize.zero) { widest, subview in
            let size = subview.sizeThatFits(.unspecified)
            return CGSize(width: max(widest.width, size.width),
                          height: max(widest.height, size.height))
        }
    }

    private func columnCount(width: CGFloat?, cell: CGFloat) -> Int {
        let choices = columnChoices.filter { $0 > 0 }.sorted(by: >)
        guard let width, width.isFinite else { return choices.first ?? 1 }
        for count in choices
        where CGFloat(count) * cell + CGFloat(count - 1) * spacing <= width + 0.5 {
            return count
        }
        return choices.last ?? 1
    }
}
