// ScheduleOnce — a scheduled task that runs ONE time, the chips that
// choose when a task runs, where a just-scheduled task sits in the
// sidebar, and the scheduled-task page's reach of the font tier.
//
// What this pins, and why each part exists:
//
//  1. The one-time form, over the REAL ScheduledTaskDefinition.swift:
//     `schedule: once <ISO 8601 instant>` reads back as the same
//     instant from any time zone it was written in, a hand-written
//     local time reads too, a reader that knows only cron sees an
//     unparseable schedule (and so fires nothing), and a definition
//     round-trips the value byte for byte.
//
//  2. The due rule, EXTRACTED from ScheduledTaskScheduler.swift and run
//     over the real `TaskSchedule`: a one-time task is never ADOPTED on
//     first sighting — it has no earlier slot to adopt, so adopting
//     would swallow its one run — and is judged by the catch-up rule
//     instead; it fires once and never again; its status (upcoming /
//     due / ran / missed) is read off the same run record.
//
//  3. The chip editor's model, over the REAL ScheduleTimingEditor.swift:
//     every recurring shape round-trips, an off-grid minute still opens
//     in Custom (cron) with its text intact, Once starts on the first
//     day its time is still ahead, a day whose chosen time has passed
//     moves to the first slot at least a minute ahead, and a moment in
//     the past is refused in words.
//
//  4. The sidebar, over the task type EXTRACTED from AgentSession.swift
//     and the REAL AgentSessionGrouping.swift: a task just scheduled
//     sorts above every older row and lifts its group, even over a
//     dragged order, while its row still prints "Never"; its date is
//     the definition DIRECTORY's birth time, which a save of SKILL.md
//     does not move.
//
//  5. Rendered: the REAL chips at every tier — they grow with the type
//     — and, with SCHEDULE_ONCE_RENDER=<dir>, PNGs of the editor, the
//     calendar and the time grid to look at.
//
//  6. The wiring and the strings, by READING the sources.
//
//  8. A run the scheduler starts is filed under its task at once, over
//     the task type EXTRACTED from AgentSession.swift: `overlaying` puts
//     the run's row among its task's runs and out of the ordinary
//     sessions until a scan reads the marker off the transcript — and a
//     task name THIS APP wrote (a placeholder, an earlier pass) is never
//     mistaken for the disk's, which would drop the run from both lists.
//
//  9. Chip rows never land on what follows: the REAL flow and grid
//     layouts hosted in a window at the display's own scale, swept across
//     widths and tiers. Breaking lines at the PLACED width instead of the
//     proposed one re-wraps a line that fitted by a fraction of a point
//     and draws its last chip over the row below.
//
// 10. The card's line spacing follows the tier, and its gaps grow with
//     the line pitch so a wrapped line never sits farther from its own
//     row than the next row does; a spacing set on an ancestor reaches a
//     TextEditor (measured on a real one).
//
// 11. Nothing starts a run off the schedule, over the due rule AND its
//     bookkeeping (`applying`) EXTRACTED from ScheduledTaskScheduler.swift:
//     an edit, a pause or a resume is a CHANGE of the schedule in force,
//     so the new schedule's slots from before it took effect are not
//     owed (counted as missed, the edit would start a run on the spot);
//     the change is dated by the file, not by the tick that reads it; a
//     slot that comes while the previous run is still going waits out
//     the live window and is then passed over, never queued behind the
//     run (queued, runs that outlast their interval follow each other
//     back to back); and whole days replayed on the scheduler's 30 s
//     tick — an edit after a pause, an edit while active, runs longer
//     than the interval, a pause — start every run on a slot.
//
// 13. A starting run takes the pane only for Run now pressed on the
//     task's page, by READING the scheduler and the panel: a run the
//     schedule starts leaves an open page alone (it may be mid-edit),
//     and the switch Run now makes waits for the transcript FILE — made
//     on the id, which is announced first, it opened nothing.
//
// 14. Run now steps aside while the form on screen holds unsaved edits
//     (it runs the SAVED task), over the REAL definition type: a save
//     that trims the prompt still reads as saved, because "unsaved" is
//     "saving would change the file" — and the panel's wiring, read.
//
// 15. The task's page renames from its title alone, over the "unsaved"
//     rule EXTRACTED from ScheduledTaskPanel.swift and the REAL
//     definition type: the page's form has no Name field and opens on
//     Schedule, so a name it holds that the file does not yet (the
//     pencil's, before the rescan) is not an unsaved edit, while above a
//     run — where the form's Name field is the rename — it is; and, read
//     off the source, a page form kept for its unsaved edits still takes
//     the file's name, or Save would write a sidebar rename back over.

import AppKit
import ImageIO
import SwiftUI

var passed = 0
var failed = 0

func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    if ok {
        passed += 1
        print("  ok    \(label)")
    } else {
        failed += 1
        let extra = detail()
        print("  FAIL  \(label)" + (extra.isEmpty ? "" : "  \(extra)"))
    }
}

func section(_ title: String) { print("\n\(title)") }

let repo = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func source(_ relative: String) -> String {
    (try? String(contentsOfFile: repo + "/" + relative, encoding: .utf8)) ?? ""
}

let calendar = Calendar.current
let now = Date()
/// `hour:minute` on the day `dayOffset` days from `base`'s.
func at(_ dayOffset: Int, _ hour: Int, _ minute: Int, from base: Date = now) -> Date {
    let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: base))!
    return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
}
let english = Locale.current.language.languageCode?.identifier == "en"

// MARK: - 1. The one-time form

section("1. `schedule: once <instant>`")

let moment = at(2, 17, 0)
let expression = TaskSchedule.onceExpression(for: moment)
check(expression.hasPrefix("once "), "a one-time value is spelled `once <instant>`", expression)
check(TaskSchedule.parse(expression) == .once(moment), "…and reads back as the same instant")
check(expression.range(of: #"([+-]\d\d:\d\d|Z)$"#, options: .regularExpression) != nil,
      "…written with its offset, so the file names an instant", expression)
let tokyo = TaskSchedule.onceExpression(for: moment, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
check(TaskSchedule.parse(tokyo) == .once(moment),
      "written in another time zone, the same instant reads back", tokyo)
let local = at(3, 3, 4)
let localText = { () -> String in
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm"
    return f.string(from: local)
}()
check(TaskSchedule.parse("once \(localText)") == .once(local),
      "a hand-written local time with no offset reads in the local zone")
check(TaskSchedule.parse("once " + localText.replacingOccurrences(of: "T", with: " ")) == .once(local),
      "…with a space instead of the T as well")
check(TaskSchedule.parse("once soon") == nil && TaskSchedule.parse("once") == nil,
      "a word that is not a time is no schedule at all")
if case .cron? = TaskSchedule.parse("0 9 * * 1-5") {
    check(true, "a cron expression is still cron")
} else {
    check(false, "a cron expression is still cron")
}
check(CronSchedule.parse(expression) == nil,
      "a reader that knows only cron cannot read it — it shows as unparseable and fires nothing")
check(TaskSchedule.once(moment).nextFireDate(after: moment.addingTimeInterval(-60)) == moment,
      "next fire is the moment while it is ahead")
check(TaskSchedule.once(moment).nextFireDate(after: moment) == nil,
      "…and nothing once it has come")
check(TaskSchedule.once(moment).previousFireDate(onOrBefore: moment.addingTimeInterval(-1)) == nil,
      "no slot before the moment — nothing for a first sighting to adopt")
check(TaskSchedule.once(moment).previousFireDate(onOrBefore: moment.addingTimeInterval(3600)) == moment,
      "the moment is the slot once it has passed")

let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("schedule-once-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

let skill = scratch.appendingPathComponent("SKILL.md")
try? "---\nname: once-task\ndescription: Once task\nschedule: \(expression)\ncwd: /tmp\n---\n\nDo the thing.\n"
    .write(to: skill, atomically: true, encoding: .utf8)
if let read = ScheduledTaskDefinition.read(name: "once-task", skillFile: skill) {
    check(read.schedule == .once(moment), "a SKILL.md carrying it reads as a one-time schedule")
    check(!read.hasUnparseableSchedule, "…and is not reported as unrecognized")
    _ = read.write(to: skill)
    let again = ScheduledTaskDefinition.read(name: "once-task", skillFile: skill)
    check(again?.scheduleExpression == expression, "a rewrite keeps the value byte for byte",
          again?.scheduleExpression ?? "nil")
} else {
    check(false, "a SKILL.md carrying it reads at all")
}

if english {
    check(TaskSchedule.once(at(1, 9, 0)).localizedDescriptionText.hasPrefix("once, tomorrow at"),
          "described as a sentence: once, tomorrow at …",
          TaskSchedule.once(at(1, 9, 0)).localizedDescriptionText)
    let farOff = at(400, 17, 0)
    let year = String(calendar.component(.year, from: farOff))
    check(TaskSchedule.momentText(farOff).contains(year),
          "a moment in another year names the year", TaskSchedule.momentText(farOff))
    let soonish = at(5, 17, 0)
    if calendar.isDate(soonish, equalTo: now, toGranularity: .year) {
        check(!TaskSchedule.momentText(soonish).contains(String(calendar.component(.year, from: now))),
              "…and one this year does not", TaskSchedule.momentText(soonish))
    }
}

// MARK: - 2. The due rule

section("2. The due rule for a one-time task")

func definition(_ schedule: String, catchUp: Bool = true,
                enabled: Bool = true) -> ScheduledTaskDefinition {
    var def = ScheduledTaskDefinition(name: "t", description: "t")
    def.scheduleExpression = schedule
    def.catchUpMissed = catchUp
    def.enabled = enabled
    return def
}
func decide(_ def: ScheduledTaskDefinition, _ state: ScheduledTaskRunState?,
            running: Bool = false, listed: Bool = true) -> ScheduledTaskScheduler.Decision {
    ScheduledTaskScheduler.decide(def, state: state, now: now, isRunning: running,
                                  agentListed: listed)
}
func once(_ date: Date) -> String { TaskSchedule.onceExpression(for: date) }

// Whole seconds, as every stored instant is — the chips set seconds to
// zero, and the written form carries none. A fractional test instant
// would read back as a different slot.
let wholeNow = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
let ahead = wholeNow.addingTimeInterval(600)
check(decide(definition(once(ahead)), nil) == .idle,
      "ahead of its moment: idle, and nothing is recorded")
let justNow = wholeNow.addingTimeInterval(-40)
check(decide(definition(once(justNow)), nil) == .fire(slot: justNow),
      "first seen just after its moment: FIRES",
      "— adopting it, as a recurring task's first sighting does, would swallow its one run")
let twoHours = wholeNow.addingTimeInterval(-7200)
check(decide(definition(once(twoHours)), nil) == .fire(slot: twoHours),
      "first seen two hours late with catch-up on: fires")
check(decide(definition(once(twoHours), catchUp: false), nil) == .skipMissed(slot: twoHours),
      "…with catch-up off: recorded as missed")
let twoDays = wholeNow.addingTimeInterval(-2 * 86400)
check(decide(definition(once(twoDays)), nil) == .skipMissed(slot: twoDays),
      "first seen two days late: missed, beyond the catch-up window")
// A record written by this build carries the schedule it belongs to
// (section 11 pins what a record without one does).
var fired = ScheduledTaskRunState()
fired.lastSlot = justNow
fired.scheduleInForce = definition(once(justNow)).scheduleInForce
check(decide(definition(once(justNow)), fired) == .idle, "once fired, never again")
check(decide(definition(once(justNow)), nil, running: true) == .idle,
      "a run still in flight holds it — a one-time moment has no next slot to wait for")
var earlier = ScheduledTaskRunState()
earlier.lastSlot = now.addingTimeInterval(-86400)
earlier.scheduleInForce = definition(once(now.addingTimeInterval(-86400))).scheduleInForce
let moved = definition(once(justNow))
let movedFirst = decide(moved, earlier)
check(movedFirst == .scheduleChanged(slot: nil),
      "moved to a new moment after an earlier run: the change is recorded, the moment NOT consumed",
      "\(movedFirst)")
let movedState = ScheduledTaskScheduler.applying(movedFirst, to: earlier, definition: moved)
check(decide(moved, movedState) == .fire(slot: justNow), "…and it fires at the new moment")
check(decide(definition(once(justNow)), nil, listed: false) == .idle,
      "an agent that is not listed runs nothing, one-time or not")
check(decide(definition(once(justNow), enabled: false), nil) == .idle, "paused runs nothing")
if let slot = CronSchedule.parse("0 9 * * *")?.previousFireDate(onOrBefore: now) {
    check(decide(definition("0 9 * * *"), nil) == .adopt(slot: slot),
          "a RECURRING task's first sighting still adopts without running")
}

typealias Status = ScheduledTaskScheduler.OneTimeStatus
func status(_ state: ScheduledTaskRunState?, _ at: Date) -> Status {
    ScheduledTaskScheduler.oneTimeStatus(at: at, state: state, now: now)
}
check(status(nil, ahead) == .upcoming, "status: upcoming while ahead")
check(status(nil, justNow) == .due, "status: due once passed and not yet dealt with")
var ran = ScheduledTaskRunState()
ran.lastSlot = justNow
ran.lastFiredAt = now
check(status(ran, justNow) == .ran, "status: ran once fired")
var missed = ScheduledTaskRunState()
missed.lastSlot = twoDays
missed.lastMissedSlot = twoDays
check(status(missed, twoDays) == .missed, "status: missed when skipped")
var runNowAfterMiss = missed
runNowAfterMiss.lastFiredAt = now
check(status(runNowAfterMiss, twoDays) == .ran, "status: Run now after a miss counts as ran")
var consumedOnly = ScheduledTaskRunState()
consumedOnly.lastSlot = justNow
check(status(consumedOnly, justNow) == .ran,
      "status: consumed by a fire that could not start is still its attempt")

// MARK: - 3. The chip editor's model

section("3. ScheduleTiming")

for shape in ["0 9 * * *", "30 14 * * 1-5", "0 9 * * 3", "15 8 12 * *", "5 * * * *"] {
    check(ScheduleTiming(schedule: shape).expression == shape, "\"\(shape)\" round-trips through the chips")
}
check(ScheduleTiming(schedule: "").frequency == .manual && ScheduleTiming(schedule: "").expression == "",
      "no schedule is Only when I run it")
let offGrid = ScheduleTiming(schedule: "7 9 * * *")
check(offGrid.frequency == .custom && offGrid.custom == "7 9 * * *",
      "an off-grid minute opens in Custom (cron), text intact")
check(ScheduleTiming(schedule: "*/15 9-17 * * 1-5").frequency == .custom,
      "a shape no chip spells opens in Custom (cron)")
let readOnce = ScheduleTiming(schedule: expression)
check(readOnce.frequency == .once && readOnce.onceDate() == moment,
      "a one-time value opens on Once, at its moment")
check(readOnce.expression == expression, "…and is written back unchanged if nothing is picked")
check(readOnce.custom.isEmpty, "…with nothing that is not cron handed to Custom")
let oddMoment = at(2, 17, 3)
let oddOnce = ScheduleTiming(schedule: TaskSchedule.onceExpression(for: oddMoment))
check(oddOnce.frequency == .once && oddOnce.onceDate() == oddMoment,
      "a hand-set minute off the grid is kept, not rounded")

let tenAM = at(0, 10, 0)
var nineOClock = ScheduleTiming()
nineOClock.hour = 9
nineOClock.minute = 0
nineOClock.select(.once, now: tenAM)
check(nineOClock.onceDay == calendar.startOfDay(for: at(1, 0, 0)),
      "Once at 10:00 with 9:00 chosen starts TOMORROW — never on a moment already past")
var fivePM = ScheduleTiming()
fivePM.hour = 17
fivePM.minute = 0
fivePM.select(.once, now: tenAM)
check(fivePM.onceDay == calendar.startOfDay(for: tenAM), "…with 17:00 chosen, today")
check(fivePM.problem(now: tenAM) == nil, "a moment ahead is accepted")
check(fivePM.problem(now: at(0, 17, 30)) != nil, "a moment the clock has passed is refused, in words")

var daily = ScheduleTiming()
daily.select(.custom)
check(daily.custom == "0 9 * * *", "entering Custom hands over the expression the chips described")
var fromOnce = ScheduleTiming()
fromOnce.select(.once, now: tenAM)
fromOnce.select(.custom)
check(fromOnce.custom.isEmpty, "…but never a one-time value, which is not cron")

let tenTwelve = at(0, 10, 12).addingTimeInterval(30)
var bump = ScheduleTiming()
bump.hour = 9
bump.minute = 0
bump.selectOnceDay(tenTwelve, now: tenTwelve)
check(bump.hour == 10 && bump.minute == 15,
      "picking today after the chosen time moves it to the first slot ahead",
      "\(bump.hour):\(bump.minute)")
check((bump.onceDate(calendar: calendar)?.timeIntervalSince(tenTwelve) ?? 0)
        >= ScheduleTiming.minimumLead, "…at least a minute ahead")
var keep = ScheduleTiming()
keep.hour = 9
keep.minute = 30
keep.selectOnceDay(at(1, 0, 0), now: tenTwelve)
check(keep.hour == 9 && keep.minute == 30, "picking tomorrow keeps the chosen time")
let tenFourteen = at(0, 10, 14).addingTimeInterval(30)
check(ScheduleTiming.firstSlot(on: tenFourteen, after: tenFourteen).map { "\($0.hour):\($0.minute)" } == "10:20",
      "a slot 30 seconds away is too close; the next one is offered")
check(ScheduleTiming.firstSlot(on: at(0, 23, 58), after: at(0, 23, 58)) == nil,
      "a day with no slot left offers none — its chip is disabled")

var badCron = ScheduleTiming()
badCron.select(.custom)
badCron.custom = "0 9 * *"
check(badCron.expression == nil && badCron.problem() != nil, "an unfinished cron is refused, in words")

check(ScheduleTiming.Frequency.custom.label == "Custom (cron)", "the cron escape hatch says what it is",
      ScheduleTiming.Frequency.custom.label)
check(ScheduleTiming.Frequency.once.label == "Once", "…and the one-time option is Once")
check(ScheduleTiming.Frequency.allCases.prefix(3) == [.manual, .once, .hourly],
      "Once sits first among the automatic options")
check(ScheduleTiming.Frequency.allCases.last == .custom, "…and cron last, for the few who want it")

// MARK: - 4. The sidebar

section("4. A task just scheduled sits at the top of its group")

let taskDirectory = scratch.appendingPathComponent("nightly", isDirectory: true)
try? FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
let taskSkill = taskDirectory.appendingPathComponent("SKILL.md")
try? "---\nname: nightly\ndescription: Nightly\nschedule: 0 2 * * *\n---\n\nRun it.\n"
    .write(to: taskSkill, atomically: true, encoding: .utf8)
/// A new URL object for the same path: NSURL caches resource values on
/// the object, so asking one URL twice answers the first reading again
/// — the scanner gets fresh URLs from every directory listing.
func fresh(_ url: URL) -> URL {
    URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
}
let born = ScheduledAgentTaskScanner.definition(in: fresh(taskDirectory))
check(born?.createdAt.map { abs($0.timeIntervalSinceNow) < 30 } == true,
      "the scanner dates a task by its directory's birth time")
let skillBornBefore = (try? fresh(taskSkill).resourceValues(forKeys: [.creationDateKey]))?.creationDate
Thread.sleep(forTimeInterval: 1.2)
// Saved the way the app saves a definition — atomically.
var renamed = ScheduledTaskDefinition(name: "nightly", description: "Renamed")
renamed.scheduleExpression = "0 2 * * *"
renamed.prompt = "Run it."
_ = renamed.write(to: taskSkill)
let afterSave = ScheduledAgentTaskScanner.definition(in: fresh(taskDirectory))
let skillBornAfter = (try? fresh(taskSkill).resourceValues(forKeys: [.creationDateKey]))?.creationDate
check(afterSave?.createdAt == born?.createdAt, "a save of SKILL.md does not move the task's date")
check(skillBornBefore != nil && skillBornAfter != nil && skillBornBefore != skillBornAfter,
      "…while SKILL.md's own birth time does move — which is why the directory is read")
check(ScheduledAgentTaskScanner.definition(in: taskSkill) == nil, "a file is not a task")

let justCreated = ScheduledAgentTask(
    name: "nightly", description: "Nightly",
    directoryURL: taskDirectory, skillFileURL: taskSkill,
    workingDirectory: nil, sessions: [], createdAt: now)
check(justCreated.lastRunAt == nil, "a task that has not run has no run to print — the row says Never")
check(justCreated.lastActive == now, "…but it is dated by the moment it was scheduled")

let hourOld = AgentSession(id: "s-old", lastUserMessageAt: now.addingTimeInterval(-3600))
let stream = [AgentListItem.regular(hourOld), .scheduled(justCreated)]
    .sorted { $0.sortDate > $1.sortDate }
check(stream.first?.id == AgentListItem.scheduled(justCreated).id,
      "it sorts above a session last used an hour ago")
let groups = AgentSessionGrouping.buckets(
    stream, mode: .custom, customGroups: ["Home", "Work"],
    assignments: ["s-old": "Home",
                  AgentListItem.groupItemKey(forScheduledTaskName: "nightly"): "Work"],
    now: now)
check(groups.first?.key == "Work", "…and lifts its group above the others",
      groups.map(\.key).description)
let dragged = AgentSessionGrouping.arranged(
    groups, mode: .custom, dragged: ["Home", "Work"],
    draggedAt: now.addingTimeInterval(-600),
    id: \.key, newest: \.newestActivity)
check(dragged.first?.key == "Work", "…even over an order dragged before it was scheduled",
      dragged.map(\.key).description)

let run = AgentSession(id: "run-1", lastUserMessageAt: now.addingTimeInterval(-7200),
                       scheduledTaskName: "nightly")
let hasRun = ScheduledAgentTask(
    name: "nightly", description: "Nightly",
    directoryURL: taskDirectory, skillFileURL: taskSkill,
    workingDirectory: nil, sessions: [run],
    createdAt: now.addingTimeInterval(-3 * 86400))
check(hasRun.lastActive == run.activityAt && hasRun.lastRunAt == run.activityAt,
      "once it has run, its newest run is both its date and what its row prints")
let recreated = ScheduledAgentTask(
    name: "nightly", description: "Nightly",
    directoryURL: taskDirectory, skillFileURL: taskSkill,
    workingDirectory: nil, sessions: [run], createdAt: now)
check(recreated.lastActive == now,
      "a task re-created under an old name is as new as its directory")

// MARK: - 5. Rendered

section("5. The chips at every tier")

@MainActor
func renderedSize<V: View>(_ view: V, tier: FontTier, width: CGFloat? = nil) -> CGSize? {
    let content = view
        .environment(\.sipFontScale, tier.scale)
        .environment(\.sipLineSpacingFactor, tier.lineSpacingFactor)
        .fixedSize(horizontal: width == nil, vertical: true)
        .frame(width: width, alignment: .topLeading)
        .padding(8)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.cgImage else { return nil }
    return CGSize(width: CGFloat(image.width) / 2 - 16, height: CGFloat(image.height) / 2 - 16)
}

@MainActor
func save<V: View>(_ view: V, tier: FontTier, width: CGFloat, name: String, into dir: String) {
    let content = view
        .environment(\.sipFontScale, tier.scale)
        .environment(\.sipLineSpacingFactor, tier.lineSpacingFactor)
        .frame(width: width * SipFont.ratio(tier.scale), alignment: .topLeading)
        .padding(14)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let dest = CGImageDestinationCreateWithURL(
              URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(tier.rawValue).png") as CFURL,
              "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

/// A binding over a value held by the harness, for a view that edits
/// one.
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
    var binding: Binding<T> { Binding(get: { self.value }, set: { self.value = $0 }) }
}

MainActor.assumeIsolated {
    let chip = ScheduleChoiceChip(title: "Every day", selected: false) {}
    if let base = renderedSize(chip, tier: .standard),
       let large = renderedSize(chip, tier: .xlarge),
       let small = renderedSize(chip, tier: .small) {
        let expected = SipFont.ratio(FontTier.xlarge.scale)
        let grew = large.height / base.height
        check(abs(grew - expected) < 0.15,
              "a chip at Large text mode is the type's ratio taller (\(String(format: "%.2f", expected)))",
              String(format: "%.2f × — %.0f → %.0f pt", grew, base.height, large.height))
        check(large.width > base.width * 1.15, "…and wider",
              String(format: "%.0f → %.0f pt", base.width, large.width))
        check(small.height < base.height, "…and smaller at Small",
              String(format: "%.0f → %.0f pt", base.height, small.height))
    } else {
        check(false, "the chip renders")
    }

    let flowWidth: CGFloat = 272
    var onceTiming = ScheduleTiming()
    onceTiming.select(.once, now: Date())
    let box = Box(onceTiming)
    let editor = ScheduleTimingEditor(timing: box.binding, offersManual: true)
    if let base = renderedSize(editor, tier: .standard, width: flowWidth),
       let large = renderedSize(editor, tier: .xlarge, width: flowWidth * SipFont.ratio(FontTier.xlarge.scale)) {
        check(large.height > base.height * 1.15,
              "the whole editor grows with the tier",
              String(format: "%.0f → %.0f pt", base.height, large.height))
    } else {
        check(false, "the editor renders")
    }

    let grid = TimeChipGrid(hour: 10, minute: 15, showsHours: true,
                            isAvailable: { hour, minute in hour * 60 + minute >= 10 * 60 + 15 },
                            onPickHour: { _ in }, onPickMinute: { _ in })
    if let size = renderedSize(grid, tier: .standard, width: flowWidth) {
        check(size.width <= flowWidth + 0.5, "the time grid fits the popover's width",
              String(format: "%.0f pt", size.width))
    }
    if let size = renderedSize(grid, tier: .xlarge, width: flowWidth * SipFont.ratio(FontTier.xlarge.scale)) {
        check(size.width <= flowWidth * SipFont.ratio(FontTier.xlarge.scale) + 0.5,
              "…at Large text mode too", String(format: "%.0f pt", size.width))
    }

    if let dir = ProcessInfo.processInfo.environment["SCHEDULE_ONCE_RENDER"] {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for tier in [FontTier.standard, .xlarge] {
            for frequency in [ScheduleTiming.Frequency.once, .weekly, .monthly, .custom] {
                var timing = ScheduleTiming()
                timing.select(frequency, now: Date())
                let held = Box(timing)
                save(ScheduleTimingEditor(timing: held.binding, offersManual: true),
                     tier: tier, width: flowWidth, name: "editor-\(frequency.rawValue)", into: dir)
            }
            save(grid, tier: tier, width: flowWidth, name: "time-grid", into: dir)
            save(OnceCalendar(selected: calendar.startOfDay(for: Date()),
                              isAvailable: { _ in true }, onPick: { _ in }),
                 tier: tier, width: flowWidth, name: "calendar", into: dir)
            save(DayOfMonthGrid(selected: 31, onPick: { _ in }),
                 tier: tier, width: flowWidth, name: "day-of-month", into: dir)
        }
        print("  (PNGs written to \(dir))")
    }
}

// MARK: - 6. Wiring and strings

section("6. Wiring, read off the sources")

let composer = source("SipAI-macOS/SipAI/Views/Chat/AgentComposer.swift")
check(composer.contains("if let problem = scheduleDraft.timing.problem()"),
      "the composer refuses a past moment or a bad cron with the editor's own words")
check(composer.contains("onScheduleCreated(success.name)"),
      "…and hands the created task's name up")
check(!composer.contains("CronSchedule.parse("),
      "the composer describes schedules through TaskSchedule, not cron alone")
let sessionView = source("SipAI-macOS/SipAI/Views/Chat/AgentSessionView.swift")
check(sessionView.contains("agents.noteScheduledTaskCreated(named: name)"),
      "the session view lists the new task at once")
let manager = source("SipAI-macOS/SipAI/Models/AgentManager.swift")
check(manager.contains("func noteScheduledTaskCreated(named name: String)")
        && manager.contains("ScheduledAgentTaskScanner.newTask(named: name)"),
      "the manager reads the new task from its directory, then rescans")
let sidebar = source("SipAI-macOS/SipAI/Views/Sidebar/AgentSessionsSection.swift")
check(sidebar.contains("if let lastRun = task.lastRunAt"),
      "the task row prints its last RUN (\"Never\" until the first), not the sort date")
check(sidebar.contains("ScheduledTaskScheduler.oneTimeStatus("),
      "the row's tag says how a one-time task's moment went")
let panel = source("SipAI-macOS/SipAI/Views/Chat/ScheduledTaskPanel.swift")
for label in ["Text(\"Change\",", "Text(\"Choose…\","] {
    if let at = panel.range(of: label) {
        let after = panel[at.upperBound...].prefix(400)
        check(after.contains(".buttonStyle(PanelActionButtonStyle())"),
              "\(label.dropFirst(6).dropLast(2)) has the panel's hover style")
    } else {
        check(false, "\(label) found in the panel")
    }
}
check(panel.contains("&& !pastMomentChosen"),
      "the panel refuses to SAVE a newly chosen moment in the past")
check(panel.contains("ScheduledTaskScheduler.oneTimeStatus(at: moment"),
      "the panel's status line says how a one-time task's moment went")
let scheduler = source("SipAI-macOS/SipAI/Models/ScheduledTaskScheduler.swift")
check(scheduler.contains("if state == nil, !schedule.isOneTime { return .adopt(slot: slot) }"),
      "the shipping rule is the one exercised above")

section("7. Strings")

let catalog = source("SipAI-macOS/SipAI/Resources/Localizable.xcstrings")
if let data = catalog.data(using: .utf8),
   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let strings = json["strings"] as? [String: Any] {
    for key in ["Once", "Custom (cron)", "Date", "Today", "Tomorrow", "Pick a date",
                "Hour", "Minute", "Previous month", "Next month", "once, %@",
                "Runs %@ — %@", "That time has already passed. Pick a later one.",
                "incomplete cron expression", "Finished", "Missed", "Due %@",
                "Ran once %@", "Missed its one run %@",
                "Runs one time, at the date and time you pick",
                "For advanced users: write the schedule as a 5-field cron expression (minute hour day month weekday)"] {
        let entry = strings[key] as? [String: Any]
        let zh = ((entry?["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any]
        check((zh?["value"] as? String).map { !$0.isEmpty } == true, "“\(key)” is translated")
    }
    for stale in ["Custom cron", "custom cron", "Repeats",
                  "Not a valid 5-field cron expression (minute hour day month weekday)."] {
        check(strings[stale] == nil, "stale key “\(stale)” is gone")
    }
} else {
    check(false, "the String Catalog parses")
}

// MARK: - 8. A scheduled run is filed under its task at once

section("8. A run is listed under its task from its first moment")

typealias Live = ScheduledAgentTaskScanner.LiveScheduledRun
let liveRun = Live(taskName: "nightly", title: "Run it.", startedAt: now.addingTimeInterval(-5))
let emptyTask = ScheduledAgentTask(
    name: "nightly", description: "Nightly",
    directoryURL: taskDirectory, skillFileURL: taskSkill,
    workingDirectory: nil, sessions: [], createdAt: now.addingTimeInterval(-86400))
func regular(_ list: [AgentSession]) -> [AgentSession] { list.filter { $0.scheduledTaskName == nil } }

// What a scan hands back while the transcript holds no marker yet.
let unmarked = AgentSession(id: "run-1", title: "Run it.")
var filed = ScheduledAgentTaskScanner.overlaying(
    ["run-1": liveRun], sessions: [unmarked, hourOld], tasks: [emptyTask],
    diskFiled: [], running: ["run-1"], now: now)
check(regular(filed.sessions).map(\.id) == ["s-old"], "the run leaves the ordinary sessions",
      regular(filed.sessions).map(\.id).description)
check(filed.tasks.first?.sessions.map(\.id) == ["run-1"], "…and is among its task's runs")
check(filed.sessions.first { $0.id == "run-1" }?.origin == .scheduled, "…marked as a scheduled run")
check(filed.runs["run-1"] != nil, "…and held until the disk says so")

// The placeholder the app itself makes already carries the task name.
let placeholderRun = AgentSession(id: "run-1", title: "Run it.", scheduledTaskName: "nightly")
filed = ScheduledAgentTaskScanner.overlaying(
    ["run-1": liveRun], sessions: [placeholderRun], tasks: [emptyTask],
    diskFiled: [], running: ["run-1"], now: now)
check(filed.tasks.first?.sessions.map(\.id) == ["run-1"],
      "a task name the APP wrote is not taken for the disk's — the run is still nested",
      "— retiring on it dropped the run from both lists until the next scan")
check(filed.runs["run-1"] != nil, "…and still held")

let twice = ScheduledAgentTaskScanner.overlaying(
    filed.runs, sessions: filed.sessions, tasks: filed.tasks,
    diskFiled: [], running: ["run-1"], now: now)
check(twice.tasks.first?.sessions.count == 1, "applying it again nests nothing twice")

// The scan read the marker: the scanner's own grouping holds the run.
let diskRun = AgentSession(id: "run-1", title: "Run it.", scheduledTaskName: "nightly")
var scannedTask = emptyTask
scannedTask.sessions = [diskRun]
let retired = ScheduledAgentTaskScanner.overlaying(
    ["run-1": liveRun], sessions: [diskRun], tasks: [scannedTask],
    diskFiled: ["run-1"], running: ["run-1"], now: now)
check(retired.runs.isEmpty, "once a scan reads the marker the run is retired")
check(retired.tasks.first?.sessions.count == 1, "…without being listed twice")

let stale = Live(taskName: "nightly", title: "Run it.", startedAt: now.addingTimeInterval(-600))
let finished = ScheduledAgentTaskScanner.overlaying(
    ["run-1": stale], sessions: [unmarked], tasks: [emptyTask],
    diskFiled: [], running: [], now: now)
check(finished.runs.isEmpty && regular(finished.sessions).count == 1,
      "a run over and settled with no marker is left to the disk")
let notYetListed = ScheduledAgentTaskScanner.overlaying(
    ["run-1": liveRun], sessions: [hourOld], tasks: [emptyTask],
    diskFiled: [], running: ["run-1"], now: now)
check(notYetListed.runs["run-1"] != nil, "a live run no list names yet is held for the next")

// MARK: - 9. Chip rows never land on what follows

section("9. Chip rows never overlap the row below (a window at the display's own scale)")

final class Frames { static var all: [String: CGRect] = [:] }
struct ReportFrame: ViewModifier {
    let name: String
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("probe")) },
                                 action: { Frames.all[name] = $0 })
    }
}
struct FlowProbe: View {
    let labels: [String]
    let width: CGFloat
    let tier: FontTier
    let grid: Bool
    var body: some View {
        let ratio = SipFont.ratio(tier.scale)
        VStack(alignment: .leading, spacing: 8 * ratio) {
            Group {
                if grid {
                    ScheduleChipGrid(columnChoices: [12, 8, 6, 4], spacing: 4 * ratio) {
                        ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                            ScheduleChoiceChip(title: label, selected: false, fillsCell: true) {}
                                .modifier(ReportFrame(name: "chip\(i)"))
                        }
                    }
                } else {
                    ScheduleChipFlow(spacing: 5 * ratio) {
                        ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                            ScheduleChoiceChip(title: label, selected: false) {}
                                .modifier(ReportFrame(name: "chip\(i)"))
                        }
                    }
                }
            }
            .modifier(ReportFrame(name: "layout"))
            Color.red.frame(height: 10).modifier(ReportFrame(name: "below"))
        }
        .frame(width: width, alignment: .topLeading)
        .coordinateSpace(name: "probe")
        .environment(\.sipFontScale, tier.scale)
        .environment(\.sipLineSpacingFactor, tier.lineSpacingFactor)
    }
}
func pump(_ seconds: Double) {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 500),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.orderFront(nil)
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    window.contentView = host
    let frequencies = ScheduleTiming.Frequency.allCases.map(\.label)   // the card's row
    let hours = (0..<24).map { String(format: "%02d", $0) + (($0 % 2 == 0) ? " AM" : "") }
    for (name, labels, grid) in [("frequency row", frequencies, false), ("hour grid", hours, true)] {
        var laid = 0, overlapping = 0
        var first = ""
        for tier in [FontTier.small, .standard, .larger, .xlarge] {
            var width: CGFloat = 240
            while width <= 620 {
                Frames.all = [:]
                host.rootView = AnyView(FlowProbe(labels: labels, width: width, tier: tier, grid: grid))
                pump(0.012)
                if let layout = Frames.all["layout"], let below = Frames.all["below"] {
                    laid += 1
                    let lowest = (0..<labels.count).compactMap { Frames.all["chip\($0)"]?.maxY }.max() ?? 0
                    if lowest > layout.maxY + 0.25 || below.minY < lowest - 0.25 {
                        overlapping += 1
                        if first.isEmpty {
                            first = String(format: "%@ at %.0f pt: chips reach %.1f, the row below starts at %.1f",
                                           tier.rawValue, width, lowest, below.minY)
                        }
                    }
                }
                width += 1
            }
        }
        check(laid > 1000 && overlapping == 0,
              "\(name): no chip below its own layout, or on the row after it (\(laid) layouts at scale \(Int(window.backingScaleFactor)))",
              first)
    }
    window.orderOut(nil)
}

// MARK: - 10. The card's line spacing

section("10. The card's line spacing and gaps follow the tier")

let tiers = [FontTier.small, .standard, .larger, .xlarge]
check(abs(SipFont.gapScale(12, fontScale: FontTier.standard.scale,
                           lineSpacingFactor: FontTier.standard.lineSpacingFactor) - 1) < 1e-9,
      "at Default the card's gaps are exactly what they were")
let xlGap = SipFont.gapScale(12, fontScale: FontTier.xlarge.scale,
                             lineSpacingFactor: FontTier.xlarge.lineSpacingFactor)
let xlTranscript = SipFont.transcriptGapScale(fontScale: SipFont.contentScale(FontTier.xlarge.scale),
                                             lineSpacingFactor: FontTier.xlarge.lineSpacingFactor)
check(abs(xlGap - xlTranscript) < 0.1,
      "at Large text mode they grow with the line pitch, as the transcript's do",
      String(format: "card %.2f, transcript %.2f", xlGap, xlTranscript))
for tier in tiers {
    let spacing = SipFont.lineSpacing(12, fontScale: tier.scale, lineSpacingFactor: tier.lineSpacingFactor)
    let gap = SipFont.gapScale(12, fontScale: tier.scale, lineSpacingFactor: tier.lineSpacingFactor)
    check(10 * gap >= spacing && max(6 * gap, spacing) >= spacing,
          "\(tier.rawValue): a field, and a details row, sit at least one wrapped line apart",
          String(format: "line spacing %.1f, field gap %.1f", spacing, 10 * gap))
}
check(abs(SipFont.lineSpacing(12, fontScale: FontTier.xlarge.scale,
                              lineSpacingFactor: FontTier.xlarge.lineSpacingFactor)
          - SipFont.scaled(12, FontTier.xlarge.scale) * FontTier.xlarge.lineSpacingFactor) < 1e-9,
      "the spacing is the tier's factor over the scaled size — the composers' rule")

final class EditorText: ObservableObject { @Published var text = "one\ntwo\nthree" }
struct SpacedEditor: View {
    @ObservedObject var model: EditorText
    var body: some View {
        VStack { Text("caption"); TextEditor(text: $model.text).frame(width: 260, height: 160) }
            .lineSpacing(19)
    }
}
func findTextView(_ view: NSView) -> NSTextView? {
    if let tv = view as? NSTextView { return tv }
    for sub in view.subviews { if let tv = findTextView(sub) { return tv } }
    return nil
}
MainActor.assumeIsolated {
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 220),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: SpacedEditor(model: EditorText()))
    window.orderFront(nil)
    pump(0.4)
    let style = window.contentView.flatMap(findTextView)?.textStorage?
        .attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    check(style?.lineSpacing == 19, "a line spacing set on an ANCESTOR reaches a TextEditor's text",
          "\(style?.lineSpacing ?? -1)")
    window.orderOut(nil)
}
let panelLines = panel.components(separatedBy: "\n")
check(panel.contains(".lineSpacing(bodyLineSpacing)"),
      "the card sets the tier's line spacing once, over everything it draws")
check(panel.contains("spacing: max(6 * rhythm, bodyLineSpacing)"),
      "the details rows are floored at one wrapped line")
let verticalByFont = panelLines.filter {
    $0.contains("* ratio") && ($0.contains(".padding(.top") || $0.contains(".padding(.bottom")
                               || $0.contains("VStack(alignment: .leading, spacing:"))
}
check(verticalByFont.isEmpty, "no vertical gap on the card scales with the type alone",
      verticalByFont.first?.trimmingCharacters(in: .whitespaces) ?? "")
let scheduler2 = source("SipAI-macOS/SipAI/Models/ScheduledTaskScheduler.swift")
check(scheduler2.contains("draft.scheduledRun = ClaudeSessionDraft.ScheduledRunIdentity("),
      "the scheduler says which task its run belongs to")
let manager2 = source("SipAI-macOS/SipAI/Models/AgentManager.swift")
check(manager2.contains("liveScheduledRuns[newSessionId] = ScheduledAgentTaskScanner.LiveScheduledRun(")
        && manager2.contains("scheduledTaskName: draft?.scheduledRun?.taskName"),
      "the run's first row is its task's, named as the scan will name it")
if let scan = manager2.range(of: "let diskFiled = Set(result.sessions"),
   let preserve = manager2.range(of: "sessions: self.preservingLiveSessions(") {
    check(scan.lowerBound < preserve.lowerBound,
          "what the disk filed is read BEFORE any placeholder joins the list")
} else {
    check(false, "the scan reads what the disk filed")
}
check(manager2.contains("scheduledTaskName: run?.taskName"),
      "a live run re-listed after a scan keeps its task")

// MARK: - 11. Nothing starts a run off the schedule

section("11. An edit, a pause or a long run never starts a run off the schedule")

// A fixed zone and a day with no clock change, so every slot below is
// the wall-clock time it names.
var pacific = Calendar(identifier: .gregorian)
pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
func pt(_ hour: Int, _ minute: Int, _ second: Int = 0, day: Int = 23) -> Date {
    pacific.date(from: DateComponents(year: 2026, month: 9, day: day,
                                      hour: hour, minute: minute, second: second))!
}
func task(_ schedule: String, enabled: Bool = true, catchUp: Bool = true) -> ScheduledTaskDefinition {
    var def = ScheduledTaskDefinition(name: "research", description: "research")
    def.scheduleExpression = schedule
    def.enabled = enabled
    def.catchUpMissed = catchUp
    return def
}
/// A record as this build writes it: a mark, and the schedule it belongs to.
func record(_ schedule: String, lastSlot: Date?, enabled: Bool = true) -> ScheduledTaskRunState {
    var state = ScheduledTaskRunState()
    state.lastSlot = lastSlot
    state.scheduleInForce = task(schedule, enabled: enabled).scheduleInForce
    return state
}
func rule(_ def: ScheduledTaskDefinition, _ state: ScheduledTaskRunState?, at clock: Date,
          running: Bool = false, listed: Bool = true,
          writtenAt: Date? = nil) -> ScheduledTaskScheduler.Decision {
    ScheduledTaskScheduler.decide(def, state: state, now: clock, isRunning: running,
                                  agentListed: listed, writtenAt: writtenAt, calendar: pacific)
}
func apply(_ decision: ScheduledTaskScheduler.Decision, _ state: ScheduledTaskRunState?,
           _ def: ScheduledTaskDefinition) -> ScheduledTaskRunState? {
    ScheduledTaskScheduler.applying(decision, to: state, definition: def) ?? state
}
func clock(_ date: Date?) -> String {
    guard let date else { return "nil" }
    let f = DateFormatter()
    f.timeZone = pacific.timeZone
    f.dateFormat = "d HH:mm:ss"
    return f.string(from: date)
}

// The schedule in force, one spelling per schedule — spelled from what it
// fires on, so a respelling is not a change.
let quarterPast = task("15 * * * *").scheduleInForce
check(!quarterPast.isEmpty && quarterPast == task("15  *  * * *").scheduleInForce,
      "the schedule in force is one spelling per schedule: spacing is not a change", quarterPast)
check(task("0 9 * * MON").scheduleInForce == task("0 9 * * mon").scheduleInForce
        && task("0 9 * * mon").scheduleInForce == task("0 9 * * 1").scheduleInForce,
      "…nor case, nor a name for a number")
check(task("*/15 * * * *").scheduleInForce == task("0,15,30,45 * * * *").scheduleInForce
        && task("0 9 * * 1-5").scheduleInForce == task("0 9 * * 1,2,3,4,5").scheduleInForce
        && task("0 9 * * 7").scheduleInForce == task("0 9 * * 0").scheduleInForce,
      "…nor a step for a list, a range for a list, or 7 for Sunday: the same slots are the same schedule")
check(task("0 9 * * 1").scheduleInForce != task("0 9 * * 2").scheduleInForce
        && task("0 * * * *").scheduleInForce != task("15 * * * *").scheduleInForce
        && task("0 9 * * *").scheduleInForce != task("0 9 1-31 * *").scheduleInForce,
      "…while different slots are — and so is a day field restricted to every day, which cron reads differently beside a weekday")
let listedMinutes = record("0,15,30,45 * * * *", lastSlot: pt(9, 15))
check(rule(task("*/15 * * * *"), listedMinutes, at: pt(10, 20, 10), writtenAt: pt(10, 20)) == .fire(slot: pt(10, 15)),
      "respelled `*/15` for `0,15,30,45` while SipAI was closed: not a change, so the 10:15 it missed is still owed")
check(task("15 * * * *", enabled: false).scheduleInForce == ""
        && task("").scheduleInForce == "" && task("not cron").scheduleInForce == "",
      "a paused task, one with no schedule and one that does not parse have none in force")
let sameMoment = pt(17, 0, day: 30)
check(task(TaskSchedule.onceExpression(for: sameMoment, timeZone: TimeZone(identifier: "Asia/Tokyo")!)).scheduleInForce
        == task(TaskSchedule.onceExpression(for: sameMoment)).scheduleInForce,
      "one moment written from two time zones is one schedule")

// An 18:00 run under "every hour, on the hour"; at 19:06 the task is
// saved as "every hour at :15".
let quarter = task("15 * * * *")
let onTheHour = record("0 * * * *", lastSlot: pt(18, 0))
let edited = rule(quarter, onTheHour, at: pt(19, 6, 20), writtenAt: pt(19, 6))
check(edited == .scheduleChanged(slot: pt(18, 15)),
      "an edit is a CHANGE: the new schedule's 18:15 is its past, not a missed run", "\(edited)")
let afterEdit = apply(edited, onTheHour, quarter)
check(afterEdit?.lastSlot == pt(18, 15) && afterEdit?.scheduleInForce == quarter.scheduleInForce,
      "…recorded, and the mark moved up to it", clock(afterEdit?.lastSlot))
check(rule(quarter, afterEdit, at: pt(19, 6, 50)) == .idle,
      "…so nothing starts at the edit — counted as missed, 18:15 would start a run on the spot")
check(rule(quarter, afterEdit, at: pt(19, 15, 20)) == .fire(slot: pt(19, 15)),
      "…and the first run is the new schedule's next slot, 19:15")

let ranAtQuarter = record("15 * * * *", lastSlot: pt(19, 15))
let backToHourly = task("0 * * * *")
let back = rule(backToHourly, ranAtQuarter, at: pt(19, 20, 10), writtenAt: pt(19, 20))
check(back == .scheduleChanged(slot: pt(19, 0)), "a change whose last slot is older than the mark…", "\(back)")
check(apply(back, ranAtQuarter, backToHourly)?.lastSlot == pt(19, 15),
      "…leaves the mark where it is: never backwards")

// The change is dated by the file, not by the tick that reads it.
let atTen = record("0 * * * *", lastSlot: pt(10, 0))
let savedJustBefore = rule(quarter, atTen, at: pt(10, 15, 10), writtenAt: pt(10, 14, 45))
check(savedJustBefore == .scheduleChanged(slot: pt(9, 15)),
      "saved at 10:14:45, first read at 10:15:10…", "\(savedJustBefore)")
check(rule(quarter, apply(savedJustBefore, atTen, quarter), at: pt(10, 15, 40)) == .fire(slot: pt(10, 15)),
      "…the 10:15 slot is still owed, and runs on the next tick")
check(rule(quarter, atTen, at: pt(10, 15, 10)) == .scheduleChanged(slot: pt(10, 15)),
      "(with no file date the tick dates it, and that slot would count as the schedule's past)")
check(rule(quarter, atTen, at: pt(10, 15, 10), writtenAt: pt(11, 0)) == .scheduleChanged(slot: pt(10, 15)),
      "a file date in the future is clamped to now")

let daily9 = record("0 9 * * *", lastSlot: pt(9, 0, day: 22))
let early = task("30 7 * * *")
let whileClosed = rule(early, daily9, at: pt(12, 0), writtenAt: pt(6, 0))
check(whileClosed == .scheduleChanged(slot: pt(7, 30, day: 22)),
      "changed at 06:00 while SipAI was closed, first read at noon…", "\(whileClosed)")
let whileClosedState = apply(whileClosed, daily9, early)
check(whileClosedState?.lastSlot == pt(9, 0, day: 22), "…(the mark stays at yesterday's 9:00)")
check(rule(early, whileClosedState, at: pt(12, 0, 30)) == .fire(slot: pt(7, 30)),
      "…owes the 7:30 that came AFTER the change: caught up like any missed slot")

// Pause and resume.
let paused = task("0 * * * *", enabled: false)
let pausing = rule(paused, atTen, at: pt(10, 30))
check(pausing == .scheduleChanged(slot: nil), "pausing is recorded…", "\(pausing)")
let pausedState = apply(pausing, atTen, paused)
check(pausedState?.scheduleInForce == "" && pausedState?.lastSlot == pt(10, 0),
      "…as nothing in force, the mark untouched")
check(rule(paused, pausedState, at: pt(12, 0, 30)) == .idle, "…and a paused task runs nothing")
let resumed = task("0 * * * *")
let resuming = rule(resumed, pausedState, at: pt(14, 20, 10), writtenAt: pt(14, 20))
check(resuming == .scheduleChanged(slot: pt(14, 0)),
      "resuming at 14:20 is a change too: 11:00–14:00 passed while it was paused…", "\(resuming)")
let resumedState = apply(resuming, pausedState, resumed)
check(rule(resumed, resumedState, at: pt(14, 20, 40)) == .idle, "…so nothing starts at the resume")
check(rule(resumed, resumedState, at: pt(15, 0, 20)) == .fire(slot: pt(15, 0)), "…the next run is the next slot")

// A record written before the schedule was recorded beside it.
var legacy = ScheduledTaskRunState()
legacy.lastSlot = pt(9, 0, day: 22)
let dailyTask = task("0 9 * * *")
let stamp = rule(dailyTask, legacy, at: pt(9, 0, 20), writtenAt: pt(8, 0))
check(stamp == .scheduleChanged(slot: nil),
      "a record with no schedule beside it is taken to be about the one in force: stamped…", "\(stamp)")
let stamped = apply(stamp, legacy, dailyTask)
check(stamped?.lastSlot == legacy.lastSlot && stamped?.scheduleInForce == dailyTask.scheduleInForce,
      "…the mark untouched")
check(rule(dailyTask, stamped, at: pt(9, 0, 50)) == .fire(slot: pt(9, 0)),
      "…a slot due then runs on the next tick")
check(rule(dailyTask, stamped, at: pt(12, 0)) == .fire(slot: pt(9, 0)),
      "…and a slot missed while SipAI was closed is still caught up, not read as a change")

let passedMoment = task(TaskSchedule.onceExpression(for: pt(19, 0)))
let toOnce = rule(passedMoment, onTheHour, at: pt(19, 10), writtenAt: pt(19, 5))
check(toOnce == .scheduleChanged(slot: nil),
      "a change to a one-time moment never consumes it, even one already past when read", "\(toOnce)")
check(rule(passedMoment, apply(toOnce, onTheHour, passedMoment), at: pt(19, 10, 30)) == .fire(slot: pt(19, 0)),
      "…the catch-up rule decides it, as on a first sighting")

// A slot that comes while the previous run is still going.
let hold = record("15 * * * *", lastSlot: pt(10, 15))
check(rule(quarter, hold, at: pt(11, 15, 20), running: true) == .idle
        && rule(quarter, hold, at: pt(11, 19, 50), running: true) == .idle,
      "the previous run still going: the slot waits out the live window")
check(rule(quarter, hold, at: pt(11, 18)) == .fire(slot: pt(11, 15)),
      "…and a run that ends inside it starts this one then — late, but on its slot")
let passOver = rule(quarter, hold, at: pt(11, 20, 20), running: true)
check(passOver == .skipWhileRunning(slot: pt(11, 15)),
      "past the window it is passed over, never queued behind the run", "\(passOver)")
let passedState = apply(passOver, hold, quarter)
check(passedState?.lastMissedSlot == pt(11, 15) && passedState?.lastMissedWhileRunning == true,
      "…recorded, with the reason the panel gives")
check(rule(quarter, passedState, at: pt(11, 25, 30)) == .idle,
      "…so the run ending does not start the next one")
let nextSlot = rule(quarter, passedState, at: pt(12, 15, 20))
check(nextSlot == .fire(slot: pt(12, 15)), "…which starts at the next slot")
let cleared = apply(nextSlot, passedState, quarter)
check(cleared?.lastMissedSlot == nil && cleared?.lastMissedWhileRunning == nil,
      "…and that run clears the note")
let onceHeld = task(TaskSchedule.onceExpression(for: pt(11, 15)))
let onceRecord = record(onceHeld.scheduleExpression, lastSlot: nil)
check(rule(onceHeld, onceRecord, at: pt(11, 40), running: true) == .idle
        && rule(onceHeld, onceRecord, at: pt(11, 45)) == .fire(slot: pt(11, 15)),
      "a one-time moment that comes during a run waits for it — it has no next slot")
check(rule(quarter, hold, at: pt(14, 5)) == .fire(slot: pt(13, 15)),
      "unchanged: a slot missed while SipAI was closed is caught up")
let offMissed = rule(task("15 * * * *", catchUp: false), hold, at: pt(14, 5))
check(offMissed == .skipMissed(slot: pt(13, 15))
        && apply(offMissed, hold, task("15 * * * *", catchUp: false))?.lastMissedWhileRunning == nil,
      "…or, with catch-up off, recorded as missed — not as passed over")
check(rule(quarter, hold, at: pt(14, 5), listed: false) == .idle
        && rule(backToHourly, hold, at: pt(14, 5), listed: false) == .idle,
      "unchanged: an agent that is not listed runs and records nothing, schedule changed or not")

// A whole day on the scheduler's own 30 s tick: runs take `runLength`,
// edits land at their times, and the file date is the edit's.
struct Edit { let at: Date; let schedule: String; let enabled: Bool }
struct Fired { let at: Date; let slot: Date }
func day(_ initial: String, runLength: TimeInterval, edits: [Edit] = [],
         from start: Date = pt(9, 32, 15), until end: Date = pt(22, 0)) -> [Fired] {
    var def = task(initial)
    var writtenAt = start
    var state: ScheduledTaskRunState? = nil
    var runningUntil: Date? = nil
    var fired: [Fired] = []
    var pending = edits
    var now = start.addingTimeInterval(11)
    while now < end {
        while let edit = pending.first, edit.at <= now {
            def = task(edit.schedule, enabled: edit.enabled)
            writtenAt = edit.at
            pending.removeFirst()
        }
        if let until = runningUntil, now >= until { runningUntil = nil }
        let decision = rule(def, state, at: now, running: runningUntil != nil, writtenAt: writtenAt)
        state = apply(decision, state, def)
        if case .fire(let slot) = decision {
            fired.append(Fired(at: now, slot: slot))
            runningUntil = now.addingTimeInterval(runLength)
        }
        now.addTimeInterval(30)
    }
    return fired
}
func slots(_ runs: [Fired]) -> [Date] { runs.map(\.slot) }
func onTime(_ runs: [Fired], within late: TimeInterval = 30) -> Bool {
    runs.allSatisfy { $0.at >= $0.slot && $0.at.timeIntervalSince($0.slot) <= late }
}
func show(_ runs: [Fired]) -> String {
    runs.map { "\(clock($0.at))→\(clock($0.slot))" }.joined(separator: ", ")
}
let hourlyRuns = (10...18).map { pt($0, 0) }

// Half-hour runs on the hour; paused at 18:53, then saved at 19:06 as
// "every hour at :15" and active again.
let reported = day("0 * * * *", runLength: 33 * 60, edits: [
    Edit(at: pt(18, 53), schedule: "0 * * * *", enabled: false),
    Edit(at: pt(19, 6), schedule: "15 * * * *", enabled: true),
])
check(slots(reported) == hourlyRuns + [pt(19, 15), pt(20, 15), pt(21, 15)] && onTime(reported),
      "on the hour until the edit, then at :15 — no run at the edit, none as a run ends",
      show(reported))
let editedLive = day("0 * * * *", runLength: 33 * 60, edits: [
    Edit(at: pt(18, 40), schedule: "15 * * * *", enabled: true),
])
check(slots(editedLive) == hourlyRuns + [pt(19, 15), pt(20, 15), pt(21, 15)] && onTime(editedLive),
      "edited while active, straight from :00 to :15: next run 19:15", show(editedLive))
let longRuns = day("15 * * * *", runLength: 70 * 60, until: pt(18, 0))
check(slots(longRuns) == [pt(10, 15), pt(12, 15), pt(14, 15), pt(16, 15)] && onTime(longRuns),
      "runs longer than the interval start only on slots — every other one, never back to back",
      show(longRuns))
let nearlyHour = day("15 * * * *", runLength: 62 * 60, until: pt(18, 0))
check(onTime(nearlyHour, within: ScheduledTaskScheduler.liveWindow + 30)
        && slots(nearlyHour).contains(pt(11, 15)) && !slots(nearlyHour).contains(pt(13, 15)),
      "runs a little over the interval: a slot runs late only inside the live window, then one is passed over",
      show(nearlyHour))
let pausedDay = day("0 * * * *", runLength: 20 * 60, edits: [
    Edit(at: pt(10, 30), schedule: "0 * * * *", enabled: false),
    Edit(at: pt(14, 20), schedule: "0 * * * *", enabled: true),
], until: pt(17, 0))
check(slots(pausedDay) == [pt(10, 0), pt(15, 0), pt(16, 0)] && onTime(pausedDay),
      "paused 10:30–14:20: nothing at the resume, next run 15:00", show(pausedDay))

// The wiring and the words.
let schedulerSource = source("SipAI-macOS/SipAI/Models/ScheduledTaskScheduler.swift")
check(schedulerSource.contains("writtenAt: loaded.writtenAt)")
        && schedulerSource.contains("guard let next = Self.applying(decision, to: states[def.name],"),
      "every tick decides with the file's date and records through `applying`")
check(schedulerSource.contains("[.modificationDate] as? Date"),
      "the file's date is read afresh each tick, not from a cached URL")
check(panel.contains("state.lastMissedWhileRunning == true"),
      "the panel says why a slot passed over during a run did not run")
if let adopted = schedulerSource.range(of: "state.lastSlot = max(state.lastSlot ?? .distantPast, current)") {
    check(schedulerSource[adopted.upperBound...].prefix(500).contains("state.scheduleInForce = def.scheduleInForce"),
          "Run now's adopted slot is stamped with its schedule — every record written carries one")
} else {
    check(false, "Run now adopts the current slot")
}
if let pause = panel.range(of: "private func togglePaused(") {
    check(panel[pause.upperBound...].prefix(700).contains("draft.enabled = updated.enabled"),
          "Pause / Resume moves the open form's Active checkbox with it, so a later Save cannot write the old value back")
} else {
    check(false, "togglePaused found in the panel")
}
if let data = catalog.data(using: .utf8),
   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let strings = json["strings"] as? [String: Any] {
    let key = "skipped a run %@ — the previous run was still going"
    let entry = strings[key] as? [String: Any]
    let zh = ((entry?["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any]
    check((zh?["value"] as? String).map { !$0.isEmpty && $0.contains("%@") } == true,
          "“\(key)” is translated")
}

// MARK: - 12. A task's own speed

section("12. A task's speed is its own, in its file")

// Claude's fast mode and codex's speed ride the task file beside its
// model and effort — owned keys, so a rewrite neither drops them nor
// files them among the keys kept for other writers.
let speedSkill = scratch.appendingPathComponent("speed/SKILL.md")
try? FileManager.default.createDirectory(at: speedSkill.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
try? "---\nname: speed\ndescription: Speed\nschedule: 0 9 * * *\nmodel: gpt-6-astra\nfast_mode: true\nservice_tier: priority\nagent: codex\nx-other: kept\n---\n\nGo.\n"
    .write(to: speedSkill, atomically: true, encoding: .utf8)
if let read = ScheduledTaskDefinition.read(name: "speed", skillFile: speedSkill) {
    check(read.fastMode && read.serviceTier == "priority", "fast_mode and service_tier are read")
    check(read.passthroughFields.map(\.key) == ["x-other"],
          "…as keys this app owns, never among another writer's",
          read.passthroughFields.map(\.key).joined(separator: ","))
    _ = read.write(to: speedSkill)
    let again = ScheduledTaskDefinition.read(name: "speed", skillFile: speedSkill)
    check(again == read, "a rewrite keeps both, and the other writer's key")
    var off = read
    off.fastMode = false
    off.serviceTier = nil
    check(off != read, "a speed edit is an edit — the card's Save lights up for it")
    let text = off.fileContents()
    check(!text.contains("fast_mode") && !text.contains("service_tier"),
          "off and Default write nothing, so a task that never chose a speed keeps a short file")
} else {
    check(false, "a SKILL.md carrying a speed reads at all")
}
for (value, on) in [("yes", true), ("on", true), ("1", true), ("false", false), ("banana", false)] {
    try? "---\nname: s\nfast_mode: \(value)\n---\n\nGo.\n".write(to: speedSkill, atomically: true, encoding: .utf8)
    check(ScheduledTaskDefinition.read(name: "s", skillFile: speedSkill)?.fastMode == on,
          "fast_mode: \(value) reads as \(on ? "on" : "off") — only a clear yes turns it on")
}

// MARK: - 13. What a starting run does to the pane

section("13. A starting run takes the pane only for Run now pressed on the task's page")

// A task's page is what its folded row opens, whether or not it has run.
// A run the SCHEDULE starts must leave that page alone — it may be
// mid-edit, and an unsaved edit goes with the page — while Run now
// pressed ON the page shows the run it started in the page's place.
// That switch is woken by the transcript FILE: the id is announced
// before the file is written, and a session is opened by its path, so a
// switch made on the id left the page up with the run's row selected.
// Read with comments stripped, so a rule quoted in prose cannot pass for
// the code.

/// `text` with every `//` comment removed — but only a `//` outside a
/// string literal, so a literal holding `://` survives.
func codeOnly(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        var inString = false, escaped = false
        var previous: Character? = nil
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "/", previous == "/" {
                return String(line[..<line.index(before: index)])
            }
            previous = inString ? nil : c
            index = line.index(after: index)
        }
        return String(line)
    }.joined(separator: "\n")
}

/// `text` from the first `start` up to the first `end` after it.
func span(_ text: String, from start: String, to end: String) -> Substring {
    guard let a = text.range(of: start),
          let b = text.range(of: end, range: a.upperBound..<text.endIndex)
    else { return "" }
    return text[a.lowerBound..<b.lowerBound]
}

let paneScheduler = codeOnly(source("SipAI-macOS/SipAI/Models/ScheduledTaskScheduler.swift"))
let panePanel = codeOnly(source("SipAI-macOS/SipAI/Views/Chat/ScheduledTaskPanel.swift"))
let runNowSrc = span(paneScheduler, from: "func runNow(", to: "func isRunning(")
check(runNowSrc.contains("func runNow(_ def: ScheduledTaskDefinition, fromTaskPage: Bool)")
        && runNowSrc.contains("fire(def, slot: nil, showRun: fromTaskPage)"),
      "Run now says where it was pressed, and only that can show its run")
check(paneScheduler.contains("if case .fire(let slot) = decision { fire(def, slot: slot, showRun: false) }"),
      "a run the schedule starts never shows itself in the pane")
let observeSrc = span(paneScheduler, from: "private func observe(", to: "runObservers[taskName] = bag")
let idSink = span(String(observeSrc), from: "runner.$sessionId", to: ".store(in: &bag)")
check(!idSink.isEmpty && !idSink.contains("openAgentSessionId = "),
      "the session id's arrival routes nothing — an id with no file opens no session",
      "— the old jump, made on the id for every run, left the page up with the run's row selected")
let fileSink = span(String(observeSrc), from: "runner.$sessionFileURL", to: ".store(in: &bag)")
check(observeSrc.contains("if showRun {\n            runner.$sessionFileURL")
        && fileSink.contains("self.appState?.openAgentSessionId = sessionId")
        && fileSink.contains("self.appState?.openAgentSessionPath = url"),
      "the switch is made when the transcript FILE is known, and only for a run asked to show itself")
check(fileSink.contains("self.appState?.openScheduledTaskName == taskName")
        && fileSink.contains("self.appState?.openAgentSessionId == nil")
        && fileSink.contains("self.inFlight[taskName] == fireKey"),
      "…only while that task's page is still what the pane shows, and the run is still this task's")
// "= " with its space: `== nil` is a question, not a route.
check(paneScheduler.components(separatedBy: "openAgentSessionId = ").count - 1 == 1,
      "the scheduler routes the pane in exactly one place")
check(panePanel.contains("scheduler.runNow(def, fromTaskPage: presentation == .page)")
        && panePanel.components(separatedBy: "runNow(").count - 1 == 1,
      "the panel's one Run now says whether it is the page's")

// MARK: - 14. Run now steps aside while the form holds unsaved edits

section("14. Run now steps aside while the form on screen holds unsaved edits")

// Run now runs the SAVED task. Pressed with unsaved edits in the form it
// would run the old version — and on the task's page the switch to the
// run would drop the edits — so it is hidden until they are saved or
// reverted. "Unsaved" means "saving would change the file": a save trims
// the prompt and tidies the header, so compared field by field the form
// still differed from the file after its own save, and Run now would
// never have come back. Over the REAL definition type.
let roundTripSkill = scratch.appendingPathComponent("roundtrip/SKILL.md")
try? FileManager.default.createDirectory(at: roundTripSkill.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
var typedForm = ScheduledTaskDefinition(name: "roundtrip", description: "  Daily report ")
typedForm.prompt = "Summarise the day.\n\n"
typedForm.scheduleExpression = "0 9 * * * "
typedForm.model = ""
_ = typedForm.write(to: roundTripSkill)
if let saved = ScheduledTaskDefinition.read(name: "roundtrip", skillFile: roundTripSkill) {
    check(saved != typedForm,
          "after a save, the form still differs from the file field by field (the old test)")
    check(saved.fileContents() == typedForm.fileContents(),
          "…and writes the same file, so it reads as saved and Run now comes back")
} else {
    check(false, "the round-trip SKILL.md reads back")
}
var editedForm = typedForm
editedForm.prompt = "Summarise the week."
check(editedForm.fileContents() != typedForm.fileContents(), "a real edit still reads as unsaved")

// A name cleared to spaces: the reader hands an empty `description:`
// back as the directory name, so the writer must put the name there
// too — or the form reads as unsaved after its own save, for good.
let blankNameSkill = scratch.appendingPathComponent("blankname/SKILL.md")
try? FileManager.default.createDirectory(at: blankNameSkill.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
var blankName = ScheduledTaskDefinition(name: "blankname", description: "   ")
blankName.prompt = "Summarise the day."
_ = blankName.write(to: blankNameSkill)
if let saved = ScheduledTaskDefinition.read(name: "blankname", skillFile: blankNameSkill) {
    check(saved.description == "blankname",
          "a blank name reads back as the directory name")
    check(saved.fileContents() == blankName.fileContents(),
          "…and the form with the blank name writes that same file, so it reads as saved")
} else {
    check(false, "the blank-name SKILL.md reads back")
}

let dirtySrc = span(panePanel, from: "private var isDirty: Bool {", to: "private func writesSameFile(")
let comparesFiles = try! NSRegularExpression(pattern: #"\b\w+\.fileContents\(\) == \w+\.fileContents\(\)"#)
check(dirtySrc.contains("return !writesSameFile(draft, def)")
        && comparesFiles.firstMatch(in: panePanel, range: NSRange(panePanel.startIndex..., in: panePanel)) != nil,
      "the panel's unsaved test is \"saving would change the file\"")
check(panePanel.contains("if previous.map({ writesSameFile(draft, $0) }) ?? true {"),
      "…and the form adopts a changed file by the same test")
let onScreen = span(panePanel, from: "private var hasUnsavedEditsOnScreen: Bool {", to: "private func field<")
check(onScreen.contains("guard isDirty else { return false }")
        && onScreen.contains("return presentation == .page || (expanded && editing)"),
      "unsaved edits count where the form is on screen: always on the page, above a run only while its editor is open")
let runNowButton = span(panePanel, from: "scheduler.runNow(def, fromTaskPage:", to: "private var statusLine")
check([".opacity(hasUnsavedEditsOnScreen ? 0 : 1)", ".allowsHitTesting(!hasUnsavedEditsOnScreen)",
       ".disabled(hasUnsavedEditsOnScreen)", ".accessibilityHidden(hasUnsavedEditsOnScreen)"]
        .allSatisfy { runNowButton.contains($0) },
      "Run now is hidden in place while they are there — no click, no focus, no VoiceOver")

// MARK: - 15. The task's page renames from its title alone

section("15. The task's page renames from its title alone — its form opens on Schedule")

// The pencil beside the page's title renames the task, and writes the
// name the moment it is made; a Name field in the form right under it
// would be a second control for the same value. So the page's form has
// none, and on the page the name is not the form's: a name the form
// holds that the file does not yet (the pencil's, before the rescan
// brings it back) is no unsaved edit — counted as one, it would light
// Save and hide Run now over a form showing nothing changed. Above a
// run the banner has no pencil, its form keeps the field, and there a
// changed name IS the edit. Over the extracted rule and the REAL type.
var fileNamed = ScheduledTaskDefinition(name: "renamed", description: "Old name")
fileNamed.prompt = "Summarise the day."
fileNamed.scheduleExpression = "0 9 * * *"
var formRenamed = fileNamed
formRenamed.description = "New name"
var formEdited = fileNamed
formEdited.prompt = "Summarise the week."
if ScheduledTaskPanel.extracted {
    check(ScheduledTaskPanel.writesSameFile(formRenamed, fileNamed, formHasNameField: false),
          "on the page, a name the file does not hold yet is not an unsaved edit")
    check(!ScheduledTaskPanel.writesSameFile(formRenamed, fileNamed, formHasNameField: true),
          "…above a run, where the form's Name field is the rename, it is")
    check(!ScheduledTaskPanel.writesSameFile(formEdited, fileNamed, formHasNameField: false)
            && !ScheduledTaskPanel.writesSameFile(formEdited, fileNamed, formHasNameField: true),
          "a real edit reads as unsaved either way")
    if let saved = ScheduledTaskDefinition.read(name: "roundtrip", skillFile: roundTripSkill) {
        check([false, true].allSatisfy {
                  ScheduledTaskPanel.writesSameFile(typedForm, saved, formHasNameField: $0) },
              "a form that a save tidies still reads as saved, on the page and above a run")
    } else {
        check(false, "the round-trip SKILL.md reads back")
    }
} else {
    check(false, "the panel's unsaved rule extracts as a pure static",
          "— no `static func writesSameFile(_ form:, _ file:, formHasNameField:)` in ScheduledTaskPanel.swift")
}

/// Whether `first` occurs in `text`, and before `second`.
func occurs(_ first: String, before second: String, in text: Substring) -> Bool {
    guard let a = text.range(of: first), let b = text.range(of: second) else { return false }
    return a.lowerBound < b.lowerBound
}
let nameLabel = "field(String(localized: \"Name\""
let editorTop = span(panePanel, from: "private var editor: some View {",
                     to: "field(String(localized: \"Schedule\"")
check(panePanel.contains("private var formHasNameField: Bool { presentation == .banner }"),
      "the form edits the name only above a run")
check(occurs("if formHasNameField {", before: nameLabel, in: editorTop)
        && panePanel.components(separatedBy: nameLabel).count - 1 == 1,
      "the Name field is drawn only there, so the page's form opens on Schedule")
let pageHeaderSrc = span(panePanel, from: "private var pageHeader: some View {",
                         to: "private var orphanNotice: some View {")
let bannerHeaderSrc = span(panePanel, from: "private var header: some View {",
                           to: "private var renameButton: some View {")
check(pageHeaderSrc.contains("renameButton") && !bannerHeaderSrc.isEmpty
        && !bannerHeaderSrc.contains("renameButton"),
      "the page renames from the pencil beside its title; the banner has no pencil, so its form keeps the field")
// Comment lines come out of `codeOnly` blank; dropped, the branch's
// first statement follows its condition directly.
let adoptSrc = span(panePanel, from: ".onChange(of: definition) { previous, current in",
                    to: ".onReceive(Self.minuteTick)")
    .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    .joined(separator: "\n")
check(adoptSrc.contains("} else if !formHasNameField {\n                draft.description = current.description"),
      "a page form kept for its unsaved edits still takes the file's name",
      "— Save writes the whole form, so a rename made in the sidebar would go back over, unseen")
check(panePanel.contains("Self.writesSameFile(form, file, formHasNameField: formHasNameField)"),
      "the panel's unsaved test and its adoption both go through the extracted rule")
let commitSrc = span(panePanel, from: "private func commitNameEdit() {", to: "private func seedDraft() {")
check(commitSrc.contains("draft.description = name") && commitSrc.contains("persist(updated)"),
      "the pencil writes the rename at once and carries it into the form, so a Save before the rescan keeps it")

try? FileManager.default.removeItem(at: scratch)
print("\n\(passed)/\(passed + failed) checks passed")
exit(failed == 0 ? 0 : 1)
