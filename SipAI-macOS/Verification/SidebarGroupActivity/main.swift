// Which group an agent section draws first, and what a FOLDED group —
// or a COLLAPSED section — says about the rows it is hiding.
//
// What this pins, and why each part exists:
//
//  1. The order rules, compiled from the SHIPPING
//     AgentSessionGrouping.swift and `SidebarOrdering` (DesignSystem
//     .swift) — never restated here:
//     * Folder, Date and Custom draw the group a turn has just started
//       in first. Custom used to keep the order its groups were
//       created in, so a group with a running session sat wherever it
//       had been made.
//     * A group with no dated row sorts after every group that has
//       one; custom groups among those keep their creation order,
//       Ungrouped last. State groups keep urgency order.
//     * An order the user DRAGGED the headers into holds until a turn
//       starts somewhere, and then that group goes to the top. A
//       dragged order is written whole, so on its own it pinned every
//       group that existed at the drag: the folder a new session ran
//       in stayed where it had been dropped, and a folder new since
//       then landed BELOW all of them.
//     * A drag lands exactly where it was dropped, lifted groups
//       included.
//     * "Is a chat in this group waiting on its reply?" answers for
//       exactly one group (or the root Chats list) — ChatManager's own
//       members, extracted.
//     * The TIERS (1c): running, then a finished run nobody has opened,
//       then the rest — the groups of Folder and Custom, over a dragged
//       order too, and the rows inside every group; the open row held
//       at its best tier until the user moves on; State's Unread group;
//       the cap never hiding a dotted row. The reported case is pinned:
//       a group whose session started earlier and still runs sat below
//       one whose later session had finished.
//
//  2. The wiring, by READING the sources: only the drag's writer
//     stamps the time; a rename carries the group's dragged position
//     without stamping; the section orders through the rule and keeps
//     each group's newest date through the cap; one test of "running"
//     feeds every activity dot in an agent section; each header's dots
//     are gated on FOLDED (or COLLAPSED) and fed by its own scope.
//     2b: one writer marks a finished run unread and never for the open
//     session, a stopped run or a draft; opening reads it, its tier held
//     first; chats the same through ChatManager; every surface asks one
//     unread test; the steady dot is the mode chip's blue; a folded
//     header draws BOTH dots, pulse first, when a row inside runs and
//     another finished unopened — one view for all three header kinds.
//     2c: a scheduled task's row carries ONE glyph — its clock between
//     two bars — as its icon and its fold state, no chevron; the whole
//     row is one button: a click on a FOLDED task unfolds it and opens
//     its page (every task, runs or none — the page closing an open
//     chat, note or draft on its way in), a click on an OPEN task folds
//     it and touches nothing else; it opens no run and reads none; its
//     runs sit one glyph in; what its runs are doing is the pair of dots
//     right after its name, folded or open, never a dot in the glyph.
//     2d: the pulse is the same circle as the steady dot, its beat a
//     pure function of the clock (never an animation started on
//     appear), and the pair's gap is 8 pt.
//
//  3. Rendered (SKIP without a window server): the REAL agent-group and
//     chat-group title lines and the REAL section header, extracted,
//     drawn at sidebar widths with names long enough to truncate (or,
//     for a section title, to wrap). The dot must show at every width,
//     right after the text, clear of the count or the header's menu —
//     and must not move a single column of either. The STEADY dot is
//     drawn in exactly the pulse's columns, in blue, folded only; with
//     both, the pulse keeps its columns and the steady dot follows it,
//     8 pt on and at the same height.
//     3b: the REAL task glyph at 1x and 2x — the bars above and below
//     while folded, beside while open, each one crisp pixel thick, the
//     clock between them and no colour, all in the row's 14 pt slot.
//     3c: the REAL folded header in a window, frame by frame for two
//     beats, at the display's own scale — folded while running, so the
//     dots appear inside the fold's animation: the pulse beats, and in
//     every frame it sits at the steady dot's height, 14 pt left of it,
//     and does not move.
//
//   ./run.sh [source-root]

import SwiftUI
import AppKit

var failures = 0
func check(_ label: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    print(cond ? "  PASS  \(label)" : "  FAIL  \(label) \(detail())")
    if !cond { failures += 1 }
}

let sourceRoot = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

func source(_ relative: String) -> String {
    (try? String(contentsOfFile: sourceRoot + "/" + relative, encoding: .utf8)) ?? ""
}

/// A line with its `//` comment removed — but only a `//` OUTSIDE a
/// string literal, so a literal holding `://` survives whole. Half of
/// what these files say about these rules is said in comments, and a
/// rule quoted in prose must not satisfy a check the code makes.
func stripComment(_ line: Substring) -> Substring {
    var inString = false
    var escaped = false
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
            return line[..<line.index(before: index)]
        }
        previous = inString ? nil : c
        index = line.index(after: index)
    }
    return line
}

func code(_ relative: String) -> String {
    source(relative)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { String(stripComment($0)) }
        .joined(separator: "\n")
}

/// The body of `func name(` up to the NEAREST next member at the same
/// indentation — enough to ask what a function does, and in what
/// order, which a whole-file search cannot.
func body(of name: String, in text: String) -> Substring {
    guard let start = text.range(of: "func " + name) else { return "" }
    let rest = text[start.upperBound...]
    let ends = ["\n    func ", "\n    private func ", "\n    @discardableResult",
                "\n    @ViewBuilder", "\n    private var ", "\n    var ",
                "\n    private static func ", "\n    static func ",
                "\n    private struct ", "\n    private enum "]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return rest[..<(ends.min() ?? rest.endIndex)]
}

/// `first` occurs, then `second` after it, inside `text`.
func precedes(_ first: String, _ second: String, in text: Substring) -> Bool {
    guard let a = text.range(of: first),
          let b = text.range(of: second, range: a.upperBound..<text.endIndex)
    else { return false }
    return a.upperBound <= b.lowerBound
}

func occurrences(_ needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

let now = Date()
func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

func session(_ id: String, _ minutesAgo: Double, folder: String? = nil) -> AgentSession {
    AgentSession(id: id,
                 title: id,
                 lastUserMessageAt: ago(minutesAgo),
                 modifiedAt: ago(minutesAgo),
                 projectPath: folder.map { URL(fileURLWithPath: $0, isDirectory: true) })
}

/// The sidebar's stream: newest first on `sortDate`, as
/// `AgentSessionsSection.sortedListItems` builds it — the input
/// `buckets` expects, not a rule under test.
func stream(_ items: [AgentListItem]) -> [AgentListItem] {
    items.sorted {
        $0.sortDate != $1.sortDate ? $0.sortDate > $1.sortDate : $0.id < $1.id
    }
}

// MARK: - 1. The order a section draws its groups in

print("1. group order")

let custom = ["Alpha", "Beta", "Gamma", "Delta"]
let neverRun = ScheduledAgentTask(name: "nightly")
let filed: [String: String] = [
    "s-alpha": "Alpha",
    "s-beta": "Beta",
    AgentListItem.groupItemKey(forScheduledTaskName: "nightly"): "Gamma",
]
func customKeys(looseMinutesAgo: Double = 10) -> [AgentSessionGroup] {
    AgentSessionGrouping.buckets(
        stream([.regular(session("s-alpha", 30)),
                .regular(session("s-beta", 5)),
                .regular(session("s-loose", looseMinutesAgo)),
                .scheduled(neverRun)]),
        mode: .custom, customGroups: custom, assignments: filed, now: now)
}
let ungrouped = AgentSessionGrouping.ungroupedKey
let customOrder = customKeys().map(\.key)

check("Custom: the group holding the newest turn is drawn first",
      customOrder.first == "Beta",
      "— got \(customOrder); it used to be the order the groups were created in")
// Ungrouped, because by creation order it is LAST: a group that is
// first either way would pass this for the wrong reason.
check("Custom: a turn starting in a group moves it to the top",
      customKeys(looseMinutesAgo: 0).map(\.key).first == ungrouped,
      "— got \(customKeys(looseMinutesAgo: 0).map(\.key)); the stamp at turn start moves the row, and the group has to follow it")
check("Custom: Ungrouped is ordered by its newest row, like any group",
      customOrder.count > 1 && customOrder[1] == ungrouped,
      "— got \(customOrder)")
check("Custom: groups with no dated row follow every group that has one, in creation order",
      Array(customOrder.suffix(2)) == ["Gamma", "Delta"],
      "— got \(customOrder); Gamma holds only a never-run task, Delta nothing")
let beta = customKeys().first { $0.key == "Beta" }
check("a group carries its newest row's date",
      beta?.newestActivity == ago(5))
check("…and nil when no row has one",
      customKeys().first { $0.key == "Gamma" }?.newestActivity == nil
        && customKeys().first { $0.key == "Delta" }?.newestActivity == nil)

let folderOrder = AgentSessionGrouping.buckets(
    stream([.regular(session("f-one", 20, folder: "/tmp/one")),
            .regular(session("f-two", 3, folder: "/tmp/two")),
            .regular(session("f-none", 50))]),
    mode: .folder, now: now).map(\.key)
check("Folder: the folder holding the newest turn is drawn first",
      folderOrder == ["/tmp/two", "/tmp/one", AgentSessionGrouping.noDirectoryKey],
      "— got \(folderOrder)")

let stateOf: [String: AgentGroupState] = [
    "st-idle": .idle, "st-work": .working, "st-ask": .awaitingApproval,
]
let stateOrder = AgentSessionGrouping.buckets(
    stream([.regular(session("st-idle", 1)),
            .regular(session("st-work", 60)),
            .regular(session("st-ask", 90))]),
    mode: .state,
    state: { item in
        if case .regular(let s) = item { return stateOf[s.id] ?? .idle }
        return .idle
    },
    now: now).map(\.key)
check("State: urgency order, whatever the recency",
      stateOrder == ["awaitingApproval", "working", "idle"],
      "— got \(stateOrder)")

let dateOrder = AgentSessionGrouping.buckets(
    stream([.regular(session("d-old", 60 * 24 * 3)),
            .regular(session("d-now", 0))]),
    mode: .date, now: now).map(\.key)
check("Date: Today is drawn first", dateOrder.first == "today",
      "— got \(dateOrder)")

// The rule over a dragged order, on plain values.
struct G { let id: String; let newest: Date? }
func arranged(_ groups: [G], _ mode: AgentGroupMode = .custom,
              dragged: [String], at: Date?) -> [String] {
    AgentSessionGrouping.arranged(groups, mode: mode, dragged: dragged,
                                  draggedAt: at, id: \.id,
                                  newest: \.newest).map(\.id)
}
let dragTime = ago(5)
// As `buckets` hands them over: newest first, undated last.
let natural = [G(id: "A", newest: ago(1)), G(id: "B", newest: ago(10)),
               G(id: "C", newest: ago(20)), G(id: "D", newest: nil)]

check("no dragged order: the section's own order",
      arranged(natural, dragged: [], at: nil) == ["A", "B", "C", "D"])
check("a drag holds while no turn has started since",
      arranged(natural, dragged: ["C", "A", "D", "B"], at: now)
        == ["C", "A", "D", "B"])
check("a turn after the drag moves that group to the top; the rest stay as dragged",
      arranged(natural, dragged: ["C", "D", "B", "A"], at: dragTime)
        == ["A", "C", "D", "B"],
      "— got \(arranged(natural, dragged: ["C", "D", "B", "A"], at: dragTime))")
let two = [G(id: "A", newest: ago(1)), G(id: "E", newest: ago(3))] + natural.dropFirst()
check("two turns since the drag: newest on top, then the other, then the dragged order",
      arranged(two, dragged: ["C", "D", "B", "A", "E"], at: dragTime)
        == ["A", "E", "C", "D", "B"])
let fresh = [G(id: "N", newest: ago(2)), G(id: "B", newest: ago(10)),
             G(id: "C", newest: ago(20))]
check("a group new since the drag, with a turn, goes to the TOP",
      arranged(fresh, dragged: ["C", "B"], at: dragTime) == ["N", "C", "B"])
check("…where the dragged order alone put it LAST (the reported folder)",
      SidebarOrdering.apply(fresh, order: ["C", "B"], id: \.id).map(\.id)
        == ["C", "B", "N"],
      "— the mechanism the rule exists to override")
let quiet = [G(id: "B", newest: ago(10)), G(id: "C", newest: ago(20)),
             G(id: "M", newest: nil)]
check("a group new since the drag with no turn since appends after the dragged ones",
      arranged(quiet, dragged: ["C", "B"], at: dragTime) == ["C", "B", "M"])
let legacy = natural + [G(id: "E", newest: nil)]
check("an order dragged before the time was recorded: every dated group by recency, the rest as dragged",
      arranged(legacy, dragged: ["E", "C", "D", "B", "A"], at: nil)
        == ["A", "B", "C", "E", "D"],
      "— got \(arranged(legacy, dragged: ["E", "C", "D", "B", "A"], at: nil))")
check("State mode keeps the dragged order after a turn",
      arranged([G(id: "W", newest: ago(1)), G(id: "S", newest: ago(10))],
               .state, dragged: ["S", "W"], at: dragTime) == ["S", "W"],
      "— urgency is what State shows; recency must not reshuffle it")
check("a turn at the very moment of the drag does not lift",
      arranged([G(id: "B", newest: dragTime), G(id: "C", newest: ago(20))],
               dragged: ["C", "B"], at: dragTime) == ["C", "B"])

// Drag while a group is lifted: what the delegate persists is the
// order on screen with one header moved, stamped now.
let onScreen = arranged(natural, dragged: ["C", "D", "B", "A"], at: dragTime)
var dropped = onScreen
dropped.remove(at: dropped.firstIndex(of: "B")!)
dropped.insert("B", at: 0)
check("a drag lands exactly where it was dropped, lifted groups included",
      arranged(natural, dragged: dropped, at: now) == dropped,
      "— got \(arranged(natural, dragged: dropped, at: now)) for \(dropped)")

check("the modes that lift are exactly Folder, Date and Custom",
      AgentGroupMode.allCases.filter(AgentSessionGrouping.liftsActiveGroups)
        == [.folder, .date, .custom])

// End to end: the real buckets, then the rule, keyed the way the
// section keys them.
let e2e = AgentSessionGrouping.arranged(
    customKeys(), mode: .custom,
    dragged: ["Alpha", "Gamma", "Delta", ungrouped, "Beta"],
    draggedAt: ago(7), id: \.key, newest: \.newestActivity).map(\.key)
check("end to end, Custom: the group with a turn since the drag first, the rest as dragged",
      e2e == ["Beta", "Alpha", "Gamma", "Delta", ungrouped],
      "— got \(e2e)")
let folders = ["/tmp/bot", "/tmp/app", "/tmp/writing"]
func folderGroups(_ extra: [AgentListItem]) -> [String] {
    AgentSessionGrouping.arranged(
        AgentSessionGrouping.buckets(
            stream([.regular(session("b", 300, folder: "/tmp/bot")),
                    .regular(session("a", 200, folder: "/tmp/app")),
                    .regular(session("w", 100, folder: "/tmp/writing"))] + extra),
            mode: .folder, now: now),
        mode: .folder, dragged: folders, draggedAt: ago(60),
        id: \.key, newest: \.newestActivity).map(\.key)
}
check("end to end, Folder: a dragged order holds with no turn since",
      folderGroups([]) == folders)
check("…a new session in a dragged folder lifts it to the top",
      folderGroups([.regular(session("a2", 0, folder: "/tmp/app"))])
        == ["/tmp/app", "/tmp/bot", "/tmp/writing"])
check("…and a session in a brand-new folder lands on top, not at the bottom",
      folderGroups([.regular(session("n", 0, folder: "/tmp/new"))]).first == "/tmp/new")

// Which chats a folded chat group, or a collapsed Chats / Chat groups
// section, answers for — ChatManager's own two members, extracted.
print("1b. chat scope")

let live = ChatLiveSet()
live.liveTurns[ChatLiveSet.liveKey(slug: "loose", project: nil)] = true
live.liveTurns[ChatLiveSet.liveKey(slug: "draft", project: "grant")] = true
check("a waiting root chat lights the root Chats list",
      live.hasChatInFlight(inProject: nil))
check("a waiting chat lights its own group",
      live.hasChatInFlight(inProject: "grant"))
check("…and no other group — not even one whose name is a prefix of it",
      !live.hasChatInFlight(inProject: "gran") && !live.hasChatInFlight(inProject: "other"),
      "— the scope must end at the separator, or \"gran\" answers for \"grant\"")
live.liveTurns.removeValue(forKey: ChatLiveSet.liveKey(slug: "loose", project: nil))
check("a group's chat does not light the root Chats list",
      !live.hasChatInFlight(inProject: nil))
live.liveTurns[ChatLiveSet.liveKey(slug: "x", project: "grant2")] = true
live.liveTurns.removeValue(forKey: ChatLiveSet.liveKey(slug: "draft", project: "grant"))
check("a chat in \"grant2\" does not light \"grant\"",
      !live.hasChatInFlight(inProject: "grant") && live.hasChatInFlight(inProject: "grant2"))

// Running first, then a finished run nobody has opened, then the rest —
// the GROUPS of Folder and Custom, and the rows inside every group.
print("1c. tiers: running, then unread, then the rest")

check("the three tiers, in order",
      SidebarTier.running < .unread && SidebarTier.unread < .rest)
check("a row's tier: running outranks unread, unread outranks nothing",
      SidebarTier.of(running: true, unread: true) == .running
        && SidebarTier.of(running: false, unread: true) == .unread
        && SidebarTier.of(running: false, unread: false) == .rest)
check("the OPEN row keeps its place: opening an unread one does not drop it",
      SidebarTier.placed(.rest, heldSinceOpened: .unread) == .unread)
check("…nor does its run finishing while it is open",
      SidebarTier.placed(.rest, heldSinceOpened: .running) == .running)
check("…but it can still rise",
      SidebarTier.placed(.running, heldSinceOpened: .unread) == .running)
check("…and a row that is not open is placed at its real tier",
      SidebarTier.placed(.unread, heldSinceOpened: nil) == .unread)

let tierOf: [String: SidebarTier] = [
    "run-early": .running, "done-late": .rest, "unread-old": .unread,
    "x-run": .running, "x-idle": .rest, "y-run": .running,
]
func tierOfItem(_ item: AgentListItem) -> SidebarTier {
    if case .regular(let s) = item { return tierOf[s.id] ?? .rest }
    return .rest
}
/// The stream as `sortedListItems` builds it: tier first, then newest.
func tieredStream(_ items: [AgentListItem]) -> [AgentListItem] {
    items.sorted {
        let lhs = tierOfItem($0), rhs = tierOfItem($1)
        if lhs != rhs { return lhs < rhs }
        return $0.sortDate != $1.sortDate ? $0.sortDate > $1.sortDate : $0.id < $1.id
    }
}

// The reported case: a session started EARLIER and still running, and
// one started LATER that has already finished.
let reported = AgentSessionGrouping.buckets(
    tieredStream([.regular(session("run-early", 30, folder: "/tmp/running")),
                  .regular(session("done-late", 2, folder: "/tmp/finished"))]),
    mode: .folder, tier: tierOfItem, now: now).map(\.key)
check("Folder: a group whose session started earlier and still runs is drawn above one whose later session has finished",
      reported == ["/tmp/running", "/tmp/finished"],
      "— got \(reported); by recency alone the finished group came first")
let three = AgentSessionGrouping.buckets(
    tieredStream([.regular(session("run-early", 30, folder: "/tmp/running")),
                  .regular(session("done-late", 2, folder: "/tmp/finished")),
                  .regular(session("unread-old", 90, folder: "/tmp/unread"))]),
    mode: .folder, tier: tierOfItem, now: now).map(\.key)
check("…then a group holding an unopened finished run, however old, then the rest",
      three == ["/tmp/running", "/tmp/unread", "/tmp/finished"], "— got \(three)")
let customTiered = AgentSessionGrouping.buckets(
    tieredStream([.regular(session("run-early", 30)),
                  .regular(session("done-late", 2)),
                  .regular(session("unread-old", 90))]),
    mode: .custom, tier: tierOfItem,
    customGroups: ["Alpha", "Beta", "Gamma", "Empty"],
    assignments: ["run-early": "Gamma", "done-late": "Alpha", "unread-old": "Beta"],
    now: now)
check("Custom: running, then unread, then the rest — a named group with nothing dated last",
      customTiered.map(\.key) == ["Gamma", "Beta", "Alpha", "Empty"],
      "— got \(customTiered.map(\.key))")
check("a group carries its best tier, taken over every row",
      customTiered.map(\.tier) == [.running, .unread, .rest, .rest])
let twoRunning = AgentSessionGrouping.buckets(
    tieredStream([.regular(session("x-run", 50, folder: "/tmp/x")),
                  .regular(session("x-idle", 1, folder: "/tmp/x")),
                  .regular(session("y-run", 10, folder: "/tmp/y"))]),
    mode: .folder, tier: tierOfItem, now: now)
check("two running groups: the one whose RUNNING row is newer first — not the one with the newest row of any kind",
      twoRunning.map(\.key) == ["/tmp/y", "/tmp/x"], "— got \(twoRunning.map(\.key))")
check("inside a group, the rows keep the stream's tier order",
      twoRunning.last?.items.map(\.id) == ["session:x-run", "session:x-idle"],
      "— got \(twoRunning.last?.items.map(\.id) ?? [])")
let dateTiered = AgentSessionGrouping.buckets(
    tieredStream([.regular(session("run-early", 60 * 24 * 3)),
                  .regular(session("done-late", 0))]),
    mode: .date, tier: tierOfItem, now: now).map(\.key)
check("Date keeps date order — Today first, whatever an older day holds",
      dateTiered.first == "today", "— got \(dateTiered)")
check("the modes whose groups follow the tiers are exactly Folder and Custom",
      AgentGroupMode.allCases.filter(AgentSessionGrouping.tiersOrderGroups) == [.folder, .custom])
check("State: Unread sits after the running groups and before Scheduled and Sessions",
      AgentGroupState.runningElsewhere.order < AgentGroupState.unread.order
        && AgentGroupState.unread.order < AgentGroupState.scheduled.order
        && AgentGroupState.scheduled.order < AgentGroupState.idle.order)
let stateTiered = AgentSessionGrouping.buckets(
    stream([.regular(session("s-done", 1)), .regular(session("s-unread", 60)),
            .regular(session("s-work", 90))]),
    mode: .state,
    state: { item in
        guard case .regular(let s) = item else { return .idle }
        return ["s-unread": .unread, "s-work": .working][s.id] ?? .idle
    },
    now: now).map(\.key)
check("State: an unread session is filed under Unread, between Working and Sessions",
      stateTiered == ["working", "unread", "idle"], "— got \(stateTiered)")

struct TG { let id: String; let newest: Date?; let tier: SidebarTier }
func arrangedT(_ groups: [TG], _ mode: AgentGroupMode = .custom,
               dragged: [String], at: Date?) -> [String] {
    AgentSessionGrouping.arranged(groups, mode: mode, dragged: dragged,
                                  draggedAt: at, id: \.id, newest: \.newest,
                                  tier: \.tier).map(\.id)
}
// As `buckets` hands them over: tier order, then newest first.
let tg = [TG(id: "R", newest: ago(40), tier: .running),
          TG(id: "U", newest: ago(50), tier: .unread),
          TG(id: "A", newest: ago(1), tier: .rest),
          TG(id: "B", newest: ago(10), tier: .rest),
          TG(id: "C", newest: ago(20), tier: .rest)]
check("a running or unread group is drawn above a dragged order — always",
      arrangedT(tg, dragged: ["C", "B", "A", "U", "R"], at: now) == ["R", "U", "C", "B", "A"],
      "— got \(arrangedT(tg, dragged: ["C", "B", "A", "U", "R"], at: now))")
check("…the rest keep the drag, with a group used since it lifted above them",
      arrangedT(tg, dragged: ["C", "B", "A", "U", "R"], at: ago(5)) == ["R", "U", "A", "C", "B"],
      "— got \(arrangedT(tg, dragged: ["C", "B", "A", "U", "R"], at: ago(5)))")
check("Folder follows the same rule",
      arrangedT(tg, .folder, dragged: ["C", "B", "A", "U", "R"], at: now) == ["R", "U", "C", "B", "A"])
check("State keeps a dragged order whole — its order is urgency, and Unread is one of its groups",
      arrangedT(tg, .state, dragged: ["C", "B", "A", "U", "R"], at: now) == ["C", "B", "A", "U", "R"])
check("Date keeps the recency-only lift",
      arrangedT(tg, .date, dragged: ["C", "B", "A", "U", "R"], at: now) == ["C", "B", "A", "U", "R"])
check("a group with nothing running or unread is arranged exactly as before",
      arrangedT(tg.map { TG(id: $0.id, newest: $0.newest, tier: .rest) },
                dragged: ["C", "B", "A", "U", "R"], at: ago(5)) == ["A", "C", "B", "U", "R"])

// The sidebar's cap, applied to rows with and without a dot.
let capRows = (0..<14).map { "r\($0)" }
let dottedRows: Set<String> = ["r12", "r13"]
let capped = SidebarRowCap.visible(capRows, revealed: false) { dottedRows.contains($0) }
check("the cap holds back only rows without a dot — a dotted row never hides behind Show all",
      capped.rows == Array(capRows.prefix(10)) + ["r12", "r13"] && capped.overflow == 2,
      "— got \(capped)")
let uncapped = SidebarRowCap.visible(capRows, revealed: true) { dottedRows.contains($0) }
check("…revealed, every row shows, in order, and the count stays for Show less",
      uncapped.rows == capRows && uncapped.overflow == 2)
let allDotted = SidebarRowCap.visible(capRows, revealed: false) { _ in true }
check("…and dotted rows do not spend the cap",
      allDotted.rows == capRows && allDotted.overflow == 0)

// MARK: - 2. Wiring the rules cannot run on their own

print("2. wiring")

let cfg = code("SipAI-macOS/SipAI/Models/ConfigManager.swift")
let sec = code("SipAI-macOS/SipAI/Views/Sidebar/AgentSessionsSection.swift")
let ds = code("SipAI-macOS/SipAI/Utilities/DesignSystem.swift")

let setter = body(of: "setAgentGroupOrder(", in: cfg)
check("the drag's writer stamps the time",
      setter.contains("raw[\"agent_group_order_at\"] = stamps")
        && setter.contains("Date().timeIntervalSince1970"),
      "— without it every dragged order reads as dragged before the stamp existed")
check("…and nothing else writes the stamp",
      occurrences("raw[\"agent_group_order_at\"] =", in: cfg) == 1,
      "— a second writer would stop groups being lifted for something that was not a drag")
check("the stamp is read back per agent and mode",
      body(of: "agentGroupOrderDate(", in: cfg).contains("raw[\"agent_group_order_at\"]"))
let rename = body(of: "renameAgentCustomGroup(", in: cfg)
check("a rename carries the group's dragged position",
      rename.contains("raw[\"agent_group_order\"] = orders"),
      "— groups are keyed by name; left behind, a renamed group drops below every dragged one")
check("…without stamping it as a drag",
      !rename.contains("setAgentGroupOrder(") && !rename.contains("agent_group_order_at"))

check("the section orders its groups through the rule",
      sec.contains("AgentSessionGrouping.arranged(")
        && sec.contains("draggedAt: config.agentGroupOrderDate(for: agentKey, mode: mode)"),
      "— the dragged order on its own pins every group")
check("…and no longer through the dragged order alone",
      !sec.contains("SidebarOrdering.apply("))
check("…judging each group by its newest row, taken before the cap",
      sec.contains("newest: \\.group.newestActivity")
        && occurrences("newestActivity: group.newestActivity", in: sec) == 2,
      "— a trimmed copy of a group must carry the date, not recompute it from the rows it kept")

let layout = body(of: "listLayout(", in: sec)
check("\"running\" is judged over the WHOLE group, before any trim",
      precedes("let live = group.items.contains(where: isActive)", "if perGroup {", in: layout))
check("the header is told",
      sec.contains("live: entry.live,"))
check("one test of \"running\" behind every dot: the task row…",
      body(of: "scheduledTaskRow(", in: sec).contains("isActive(.scheduled(task))"))
check("…the session row…",
      body(of: "sessionRow(", in: sec).contains("isActive(.regular(session))"))
check("…and the scheduler's firing window is read in that one place",
      occurrences("scheduler.isRunning(task.name)", in: sec) == 1,
      "— a second spelling is how a header and a row come to disagree")

let header = body(of: "groupHeaderRow(", in: sec)
check("the header draws the real title line",
      header.contains("AgentGroupHeaderLabel(label: group.label"))
check("VoiceOver hears the dots on a folded group",
      header.contains(".accessibilityValue(folded")
        && header.contains("GroupActivityDots.accessibilityText(live: live, unread: unread)"),
      "— the header's own label replaces the dots'")
/// `GroupActivityDots`, whole — the pair every folded header draws.
let foldedDots = slice(ds, from: "struct GroupActivityDots: View {", to: "\n}\n")
let foldedSpoken = slice(ds, from: "static func accessibilityText(live: Bool, unread: Bool)",
                         to: "\n    }\n")
check("…both sentences when both are true, the pulse's first",
      precedes("if live { parts.append(ActivityDot.accessibilityText) }",
               "if unread { parts.append(UnreadDot.accessibilityText) }", in: foldedSpoken)
        && !foldedSpoken.contains("else"))
check("…in the dots' own words, spelled once",
      ds.contains("static var accessibilityText: String")
        && occurrences("\"Session is running\"", in: ds) == 1
        && !sec.contains("\"Session is running\""))

let titleLine: Substring = {
    guard let start = sec.range(of: "struct AgentGroupHeaderLabel: View {") else { return "" }
    let rest = sec[start.lowerBound...]
    return rest[..<(rest.range(of: "\n}\n")?.upperBound ?? rest.endIndex)]
}()
/// The HStack (`body`) and the text run it draws (`title`), apart.
let lineBody: Substring = {
    guard let start = titleLine.range(of: "var body: some View {") else { return "" }
    let rest = titleLine[start.lowerBound...]
    return rest[..<(rest.range(of: "private var title: Text {")?.lowerBound ?? rest.endIndex)]
}()
let titleRun: Substring = {
    guard let start = titleLine.range(of: "private var title: Text {") else { return "" }
    return titleLine[start.lowerBound...]
}()
check("the title line exists as its own view",
      !titleLine.isEmpty && !lineBody.isEmpty && !titleRun.isEmpty)
check("the dots are drawn only while the group is folded",
      lineBody.contains("if folded && (live || unread) {"))
check("name and parent folder are ONE run of text, name first",
      precedes("Text(label)", "+ Text(detail)", in: titleRun)
        && !lineBody.contains("Text(detail)") && !lineBody.contains("Text(label)"),
      "— as two views, a long name squeezed the parent folder into a stray \"…\" or half a glyph before the dot")
check("…truncated at the TAIL, once",
      precedes("title", ".truncationMode(.tail)", in: lineBody)
        && !titleLine.contains(".truncationMode(.middle)"),
      "— `.middle` is drawn narrower than it measures, leaving a gap before the dot")
check("the dots come AFTER the text…",
      precedes(".truncationMode(.tail)", "GroupActivityDots(", in: lineBody))
check("…BEFORE the spacer and the count",
      precedes("GroupActivityDots(", "Spacer(minLength: 4)", in: lineBody)
        && precedes("Spacer(minLength: 4)", "Text(\"\\(count)\")", in: lineBody))
check("the count cannot be squeezed",
      precedes("Text(\"\\(count)\")", ".fixedSize()", in: lineBody))

/// `text` from `start` to the first `end` after it.
func slice(_ text: String, from start: String, to end: String) -> Substring {
    guard let a = text.range(of: start) else { return "" }
    let rest = text[a.lowerBound...]
    return rest[..<(rest.range(of: end)?.upperBound ?? rest.endIndex)]
}

let chatList = code("SipAI-macOS/SipAI/Views/Sidebar/ChatListView.swift")
let chatManager = code("SipAI-macOS/SipAI/Models/ChatManager.swift")

let sectionLive = slice(sec, from: "private var sectionLive: Bool {", to: "\n    }\n")
check("an agent section is lit through the same isActive as its rows",
      sec.contains("live: sectionLive,")
        && sectionLive.contains("isActive(.regular(")
        && sectionLive.contains("isActive(.scheduled("),
      "— sessions AND scheduled tasks, or a collapsed section hides a run the task row would show")
check("the Chats section is lit by the root scope",
      chatList.contains("live: chats.hasChatInFlight(inProject: nil)"))
check("the Chat groups section by any of its groups",
      chatList.contains("live: projects.projects.contains { chats.hasChatInFlight(inProject: $0.slug) }"))
check("a chat group's header by its own group, through its own title line",
      chatList.contains("live: chats.hasChatInFlight(inProject: project.slug),")
        && chatList.contains("unread: chats.hasChatUnread(inProject: project.slug))")
        && chatList.contains("ChatGroupHeaderLabel(name: project.name,"))
check("the chat scope is spelled through the live key",
      body(of: "hasChatInFlight(", in: chatManager)
        .contains("Self.liveKey(slug: \"\", project: project)"),
      "— a second spelling of the key is how a header and a row come to disagree")

let disclosure = slice(chatList, from: "struct DisclosureSection<", to: "\n}\n")
check("a section header draws the dots only while collapsed",
      disclosure.contains("if !isExpanded && (live || unread) {"))
check("…after its title and before the spacer",
      precedes("Text(title)", "GroupActivityDots(", in: disclosure)
        && precedes("GroupActivityDots(", "Spacer(minLength: 0)", in: disclosure))
check("…inside the fold button, so the header's menu stays where it was",
      precedes("GroupActivityDots(", "accessory()", in: disclosure))
check("a section title is ONE line, cut at the tail",
      precedes("Text(title)", ".lineLimit(1)", in: disclosure)
        && precedes(".lineLimit(1)", ".truncationMode(.tail)", in: disclosure)
        && precedes(".truncationMode(.tail)", "GroupActivityDots(", in: disclosure),
      "— left to wrap inside the plain Button it came out as one cut line in a two-line row, drawn over the dot")

let chatTitle = slice(chatList, from: "struct ChatGroupHeaderLabel: View {", to: "\n}\n")
check("a chat group's header draws the dots only while folded",
      chatTitle.contains("if !expanded && (live || unread) {"))
check("…after the name, which truncates at the tail, and before the spacer",
      precedes("Text(name)", ".truncationMode(.tail)", in: chatTitle)
        && precedes(".truncationMode(.tail)", "GroupActivityDots(", in: chatTitle)
        && precedes("GroupActivityDots(", "Spacer(minLength: 4)", in: chatTitle))

// The steady dot: who marks a finished run unread, who clears it, and
// that every surface asks the same two tests.
print("2b. the steady dot's wiring")

let mgr = code("SipAI-macOS/SipAI/Models/AgentManager.swift")
let runnerSrc = code("SipAI-macOS/SipAI/Models/AgentRunner.swift")
let contentView = code("SipAI-macOS/SipAI/Views/ContentView.swift")

let ended = body(of: "noteRunEnded(", in: mgr)
check("a finished run is marked unread in ONE place",
      ended.contains("config?.markAgentSessionUnread(id)")
        && occurrences("markAgentSessionUnread(", in: mgr) == 1)
check("…never for the open session, a run the user stopped, or a run that never got a session id",
      ended.contains("id != openSessionId") && ended.contains("!stoppedByUser")
        && ended.contains("hasPrefix(\"draft:\")"))
check("…nor for the session the OPEN DRAFT's first turn became — the pane flips to its id only when the transcript lands",
      ended.contains("!isOpenDraftsSession(id)")
        && body(of: "isOpenDraftsSession(", in: mgr).contains("runner.key == id")
        && contentView.contains(".onChange(of: appState.pendingClaudeSessionDraft?.id, initial: true)")
        && contentView.contains("agents.noteOpenDraft("))
check("…from BOTH ends a run has: a turn of ours, and one another process ran",
      occurrences("noteRunEnded(sessionId:", in: mgr) == 2)
check("…with the user's Stop — and a quit — read off the runner",
      mgr.contains("stoppedByUser: runner?.turnWasStoppedByUser")
        && runnerSrc.contains("var turnWasStoppedByUser: Bool { stopRequested }"))
check("…and the composer's Stop on a turn another process ran likewise",
      mgr.contains("stoppedByUser: runner?.externalTurnWasStoppedByUser")
        && body(of: "stopExternalTurn(", in: runnerSrc).contains("externalTurnWasStoppedByUser = true"))
let openedSrc = body(of: "noteOpenSession(", in: mgr)
check("opening a session reads it — its tier is taken BEFORE the mark is cleared",
      precedes("openSessionHeldTier = actualTier(forSession: id)",
               "config?.clearAgentSessionUnread([id])", in: openedSrc),
      "— cleared first, an unread session would be held at the tier it has only because it was opened")
check("a run of the open session raises its hold, from both starts a run has",
      body(of: "noteRunStarted(", in: mgr).contains("openSessionHeldTier = .running")
        && occurrences("noteRunStarted(sessionId:", in: mgr) == 2)
check("the placed tier asks the hold for the open session only",
      body(of: "sidebarTier(forSession", in: mgr)
        .contains("id == openSessionId ? openSessionHeldTier : nil"))
check("deleting a session clears its mark — a session's Delete and a task's Delete all alike, through the one delete",
      body(of: "deleteSession(", in: mgr).contains("delete([session], task: nil)")
        && body(of: "deleteScheduledTaskAndRuns(", in: mgr).contains("delete(task.sessions, task: task,")
        && body(of: "delete(", in: mgr).contains("config?.clearAgentSessionUnread([session.id])"))
check("ContentView tells both managers what is open, from launch on",
      contentView.contains(".onChange(of: appState.openAgentSessionId, initial: true)")
        && contentView.contains("agents.noteOpenSession(id)")
        && contentView.contains(".onChange(of: openChatKey, initial: true)")
        && contentView.contains("chats.noteOpenChat("))

let endTurnSrc = body(of: "endTurn(", in: chatManager)
check("a chat reply is marked unread only when a live turn really ended here",
      precedes("guard liveTurns.removeValue(forKey: key) != nil else { return }",
               "config?.markChatUnread(key: key)", in: endTurnSrc),
      "— a deleted or moved chat's turn is torn down first, and must leave nothing behind")
check("…not when the chat is open, and not when the user stopped it",
      endTurnSrc.contains("key != openChatKey")
        && endTurnSrc.contains("turnOutcomes[key] != .interrupted"))
check("opening a chat reads it, its tier taken first",
      precedes("openChatHeldTier = actualTier(key: key)", "config?.clearChatUnread(key: key)",
               in: body(of: "noteOpenChat(", in: chatManager)))
check("…a reply asked for in the open chat raises its hold",
      body(of: "beginTurn(", in: chatManager).contains("if key == openChatKey { openChatHeldTier = .running }"))
check("a deleted chat takes its mark with it; a moved one carries it",
      body(of: "deleteChat(", in: chatManager).contains("config?.clearChatUnread(key:")
        && body(of: "moveChat(", in: chatManager).contains("config?.moveChatUnread(from:"))
check("marks of chats no longer listed are pruned — after the lists are read, never on a failed read",
      precedes("self.projectChats = perProject", "config?.pruneChatUnread(keeping: existing)",
               in: body(of: "reload(", in: chatManager)))
check("the marks are bounded, and rebuilt whenever the config is",
      cfg.contains("static let unreadCap = 500")
        && body(of: "rebuildDerived(", in: cfg).contains("rebuildUnread()"))

let streamSrc = slice(sec, from: "private var sortedListItems", to: "\n    }\n")
check("the section's stream is sorted by tier first, then newest",
      precedes("if lhs != rhs { return lhs < rhs }", "return $0.sortDate > $1.sortDate", in: streamSrc))
check("the bucketer and the order rule are handed the tiers",
      layout.contains("tier: tier(_:),") && sec.contains("tier: \\.group.tier)"))
check("…and a trimmed group carries its tier over",
      occurrences("tier: group.tier", in: sec) == 2)
check("a dotted row is never capped, in either cap",
      layout.contains("for item in items where tier(item) < .rest { dotted.insert(item.id) }")
        && occurrences("case .regular where dotted.contains(item.id):", in: String(layout)) == 2)
check("placement's \"running\" is the pulse's own test",
      body(of: "tier(", in: sec).contains("if isActive(item) { return .running }"),
      "— a row placed as running without pulsing is a row that seems out of order")
let unreadTest = body(of: "isUnread(", in: sec)
check("ONE test behind every steady dot in a section",
      unreadTest.contains("agents.isSessionUnread(session.id)")
        && unreadTest.contains("task.sessions.contains { agents.isSessionUnread($0.id) }"))
check("…asked by the rows, the folded groups and the collapsed section alike",
      body(of: "sessionRow(", in: sec).contains("isUnread(.regular(session))")
        && body(of: "scheduledTaskRow(", in: sec).contains("isUnread(.scheduled(task))")
        && layout.contains("group.items.contains(where: isUnread)")
        && sec.contains("unread: sectionUnread,"))
let glyphSrc = body(of: "leadingGlyph(", in: sec)
check("a row's glyph: the pulse while running, else the steady dot, else the icon",
      precedes("if active {", "ActivityDot()", in: glyphSrc)
        && precedes("ActivityDot()", "} else if unread {", in: glyphSrc)
        && precedes("} else if unread {", "UnreadDot()", in: glyphSrc))
// A task's row opens no run, so it reads none: each run's dot goes when
// that run is opened, and the task's row keeps its dot while any run is
// unopened. (It used to open the newest run and mark every run read.)
let toggleSrc = body(of: "toggleTask(", in: sec)
check("a task's row opens no run and reads none",
      !toggleSrc.isEmpty && !toggleSrc.contains("markRead")
        && !toggleSrc.contains("openAgentSessionId =")
        && !sec.contains("agents.markRead(")
        && !code("SipAI-macOS/SipAI/Models/AgentManager.swift").contains("func markRead"),
      "— a click meant to fold a task must not also read, or open, its runs")
check("State files an unread row under Unread through the PLACED tier",
      body(of: "groupState(", in: sec).contains("agents.sidebarTier(forSession: session.id) == .unread"))
check("a folded header draws the pulse, then the steady dot BESIDE it — never one instead of the other",
      precedes("if live {", "ActivityDot()", in: foldedDots)
        && precedes("ActivityDot()", "if unread {", in: foldedDots)
        && precedes("if unread {", "UnreadDot()", in: foldedDots)
        && !foldedDots.contains("else"),
      "— a group holding a running session and an unopened finished one showed the pulse alone")
check("…one view for all three header kinds, none drawing a dot of its own",
      [lineBody, disclosure, chatTitle].allSatisfy {
          $0.contains("GroupActivityDots(live: live, unread: unread)")
            && !$0.contains("ActivityDot()") && !$0.contains("UnreadDot()")
      },
      "— a header with its own spelling is how the three come to disagree")
let unreadDotSrc = slice(ds, from: "struct UnreadDot: View {", to: "\n}\n")
let modeChipSrc = slice(code("SipAI-macOS/SipAI/Views/Chat/AgentComposer.swift"),
                        from: "private var modeChip: some View {", to: "\n    }\n")
check("the steady dot is the mode chip's blue, never the pulse's orange",
      unreadDotSrc.contains(".fill(SipDesign.blue)") && !unreadDotSrc.contains("orange")
        && modeChipSrc.contains("SipDesign.blue"),
      "— at the top of every beat an orange pulse IS a steady orange dot")

check("chats: both lists ordered by tier, then capped with dotted chats exempt",
      chatList.contains("let visible = chats.sidebarOrdered(filtered(chats.rootChats))")
        && chatList.contains("chats.sidebarOrdered(filtered(chats.projectChats[project.slug] ?? []))")
        && occurrences("chats.sidebarTier(slug: $0.slug, project: $0.project) < .rest", in: chatList) == 2)
check("…the collapsed Chats and Chat groups sections and a chat row carry the steady dot",
      chatList.contains("unread: chats.hasChatUnread(inProject: nil)")
        && chatList.contains("unread: projects.projects.contains { chats.hasChatUnread(inProject: $0.slug) }")
        && precedes("} else if isUnread {", "UnreadDot()",
                    in: slice(chatList, from: "private var normalRow", to: "RowEllipsisMenu")))
check("the steady dot has its own spoken words, spelled once",
      occurrences("\"Finished, not opened yet\"", in: ds) == 1
        && !sec.contains("\"Finished, not opened yet\"")
        && !chatList.contains("\"Finished, not opened yet\""))

// A scheduled task's row: one glyph is its icon and its fold control.
print("2c. the scheduled task's row")

/// `text` strictly between the first `a` and the first `b` after it.
func between(_ text: Substring, _ a: String, _ b: String) -> Substring {
    guard let x = text.range(of: a),
          let y = text.range(of: b, range: x.upperBound..<text.endIndex)
    else { return "" }
    return text[x.upperBound..<y.lowerBound]
}

let taskRow = body(of: "scheduledTaskRow(", in: sec)
check("the task row carries no chevron",
      !taskRow.contains("\"chevron.") && !taskRow.contains("leadingGlyph("),
      "— one glyph is the icon and the fold control; a second costs the runs an indent")
// The whole row is ONE button, and a click on it folds or unfolds the
// task — both ways, wherever the centre pane is. It used to open the
// task's newest run and fold only on a click that changed nothing, so a
// task unfolded while another session was open could not be folded from
// its row.
let taskBody = between(taskRow, "toggleTask(task)", "RowEllipsisMenu")
check("the whole task row is ONE button, and its click is the fold",
      occurrences("Button {", in: String(between(taskRow, "} else {", "RowEllipsisMenu"))) == 1
        && taskRow.contains("toggleTask(task)") && !sec.contains("openTask("),
      "— two buttons (glyph folds, name opens) is the shape the user asked to be rid of")
check("…folding BOTH ways on every click — no \"only when nothing changed\" rule",
      toggleSrc.contains("expandedScheduledTasks.remove(task.id)")
        && toggleSrc.contains("expandedScheduledTasks.insert(task.id)")
        && !toggleSrc.contains("selectionUnchanged") && !toggleSrc.contains("if selection"),
      "— a task unfolded from elsewhere must fold on its row's click")
// Unfolding opens the task's page — for EVERY task, whatever it has run.
// It used to open the page only for a task with no runs, so a task that
// had run had no way to its page from its row.
let afterUnfoldTest = toggleSrc.range(of: "if unfolding {", options: .backwards)
    .map { toggleSrc[$0.upperBound...] } ?? ""
check("…a click on a FOLDED task opens its page as well — every task, runs or none",
      toggleSrc.contains("let unfolding = !expandedScheduledTasks.contains(task.id)")
        && afterUnfoldTest.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("openTaskPage(task)")
        && occurrences("openTaskPage(task)", in: String(toggleSrc)) == 1
        && !toggleSrc.contains("task.sessions"),
      "— the page is what a folded task's click shows, not only a never-run task's")
check("…and a click on an OPEN task folds it and leaves the centre pane where it is",
      occurrences("if unfolding {", in: String(toggleSrc)) == 2
        && !toggleSrc.contains("appState."),
      "— folding a task away must never take the pane somewhere else")
let pageSrc = body(of: "openTaskPage(", in: sec)
check("…the page pushes a pending draft, an open note AND an open chat aside",
      pageSrc.contains("appState.pendingClaudeSessionDraft = nil")
        && pageSrc.contains("appState.openNoteId = nil")
        && pageSrc.contains("appState.openChatSlug = nil")
        && pageSrc.contains("appState.openChatProject = nil")
        && precedes("appState.openNoteId = nil", "appState.openScheduledTaskName = task.name", in: pageSrc)
        && precedes("appState.openChatSlug = nil", "appState.openScheduledTaskName = task.name", in: pageSrc),
      "— a note is drawn ahead of a task, so it hid the page; a chat is drawn behind one, so it stayed open underneath: its row selected beside the task's, and its reply given no steady dot")
check("its label: the glyph, then the name, in the column every row's title is in: 8 + 14 + 6",
      precedes("ScheduledTaskGlyph(expanded: isExpanded)", "Text(task.description)", in: taskBody)
        && precedes("HStack(spacing: 6) {", "ScheduledTaskGlyph(expanded: isExpanded)", in: taskBody)
        && taskBody.contains(".padding(.leading, 8)")
        && !taskBody.contains(".padding(.leading, 3)")
        && body(of: "sessionRow(", in: sec).contains("HStack(spacing: 6) {"))
check("…and says what its click does as the hint, its state and its runs' dots as the value",
      taskRow.contains(".accessibilityLabel(task.description)")
        && taskRow.contains("GroupActivityDots.accessibilityText(live: hasActivity,")
        && taskRow.contains("\"Collapse scheduled runs\"")
        && taskRow.contains("\"Expand scheduled runs and open the task's page\"")
        && !sec.contains("\"Expand scheduled runs\"")
        && !sec.contains("Open this scheduled task"),
      "— folded, the click opens the task's page too, and a hint that says only \"expand\" hides that")
let catalogData = source("SipAI-macOS/SipAI/Resources/Localizable.xcstrings").data(using: .utf8) ?? Data()
let catalog = ((try? JSONSerialization.jsonObject(with: catalogData)) as? [String: Any])?["strings"]
    as? [String: Any] ?? [:]
func zhHans(_ key: String) -> String? {
    ((((catalog[key] as? [String: Any])?["localizations"] as? [String: Any])?["zh-Hans"]
        as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
}
check("…both hints are in the catalog, translated, and the retired one is gone",
      zhHans("Collapse scheduled runs") != nil
        && zhHans("Expand scheduled runs and open the task's page") != nil
        && catalog["Expand scheduled runs"] == nil)
check("its runs' dots come right after its name — the pair when both — and before its status tag",
      precedes("Text(task.description)", ".truncationMode(.tail)", in: taskBody)
        && precedes(".truncationMode(.tail)", "if hasActivity || hasUnread {", in: taskBody)
        && precedes("if hasActivity || hasUnread {",
                    "GroupActivityDots(live: hasActivity, unread: hasUnread)", in: taskBody)
        && precedes("GroupActivityDots(live: hasActivity, unread: hasUnread)",
                    "scheduleStatusLabel(task)", in: taskBody),
      "— a pulse after \"Active\" reads as a light on the tag, which describes the schedule")
let dotsGate = between(taskBody, ".truncationMode(.tail)", "scheduleStatusLabel(task)")
check("…gated on nothing but the two tests: folded or open, the row speaks for its runs",
      !dotsGate.contains("isExpanded") && !dotsGate.contains("expandedScheduledTasks"),
      "— the row always said a run was going; gated on the fold, a firing task's first seconds would show nothing")
check("a task being renamed keeps its glyph",
      between(taskRow, "if renamingTaskId == task.id {", "} else {")
        .contains("ScheduledTaskGlyph(expanded: isExpanded)"))
check("its runs sit ONE glyph in — where the task's own glyph slot ends",
      sec.contains("private static let nestedRunLeading: CGFloat = 8 + 14")
        && occurrences("Self.nestedRunLeading", in: sec) == 3
        && !sec.contains("nested ? 36") && !sec.contains(".padding(.leading, 36)"),
      "— the rows, the rename row and \"No runs yet.\" all through the one constant")
let taskGlyph = slice(sec, from: "struct ScheduledTaskGlyph: View {", to: "\n}\n")
check("the glyph is the clock between the bars, whatever the runs are doing",
      precedes("Image(systemName: \"timer\")", "bars", in: taskGlyph)
        && !taskGlyph.contains("ActivityDot") && !taskGlyph.contains("UnreadDot"),
      "— a dot swapped in for the clock could only ever be one of the two")
check("…the bars turn with the fold, and hold still under Reduce Motion",
      taskGlyph.contains(".rotationEffect(.degrees(expanded ? 90 : 0))")
        && taskGlyph.contains(".animation(reduceMotion ? nil : .easeInOut(duration: 0.16),"))

print("2d. the pulse and the pair")
let activityDotSrc = slice(ds, from: "struct ActivityDot: View {", to: "\n}\n")
let unreadDotBody = slice(ds, from: "struct UnreadDot: View {", to: "\n}\n")
check("the pulse is the steady dot's circle — a 6 pt frame and a fill — its beat in the fill's alpha",
      activityDotSrc.contains(".fill(Color.orange.opacity(Self.alpha(at: context.date)))")
        && activityDotSrc.contains(".frame(width: 6, height: 6)")
        && unreadDotBody.contains(".frame(width: 6, height: 6)")
        && !activityDotSrc.contains(".opacity(pulse"),
      "— two dots drawn two ways can land at two heights")
check("…read off the clock, never an animation started as the dot appears",
      activityDotSrc.contains("TimelineView(") && !activityDotSrc.contains("onAppear")
        && !activityDotSrc.contains("repeatForever") && !activityDotSrc.contains("withAnimation")
        && !activityDotSrc.contains("@State"),
      "— a repeating animation started on appear carries the other changes of that update with it")
// The beat, run: the old animation's 0.8 s ease each way between full
// and 40 %.
let beatTop = Date(timeIntervalSinceReferenceDate: 1_000 * 2 * ActivityDot.halfBeat)
let beat = (0...40).map {
    ActivityDot.alpha(at: beatTop.addingTimeInterval(Double($0) * ActivityDot.halfBeat / 20))
}
check("the beat: full at the top, 40 % at the foot, full again a beat later",
      abs(beat[0] - 1) < 1e-9 && abs(beat[20] - 0.4) < 1e-9 && abs(beat[40] - 1) < 1e-9,
      "— \(beat[0]), \(beat[20]), \(beat[40])")
check("…down and back up, never outside 40 %…100 %",
      zip(beat[0..<20], beat[1...20]).allSatisfy { $0 > $1 }
        && zip(beat[20..<40], beat[21...40]).allSatisfy { $0 < $1 }
        && beat.allSatisfy { $0 >= 0.4 - 1e-9 && $0 <= 1 + 1e-9 })
check("…eased: slow at the top and the foot, fastest between",
      beat[0] - beat[1] < beat[9] - beat[10] && beat[19] - beat[20] < beat[9] - beat[10])
check("…one clock: the same alpha a whole beat later, from any instant — every pulse beats together",
      (0..<50).allSatisfy { i in
          let t = Date(timeIntervalSinceReferenceDate: 812_345.678 + Double(i) * 0.137)
          return abs(ActivityDot.alpha(at: t)
                     - ActivityDot.alpha(at: t.addingTimeInterval(2 * ActivityDot.halfBeat))) < 1e-6
      })
check("the pair's gap is 8 pt, spelled once, and the stack uses it",
      GroupActivityDots.spacing == 8 && foldedDots.contains("HStack(spacing: Self.spacing)"),
      "— \(GroupActivityDots.spacing)")

// MARK: - 3. Rendered

print("3. the headers, rendered (real views, offscreen)")

/// Column sets of one render: orange (the pulse, at any point of its
/// beat), blue (the steady dot) and grey or black ink (chevrons, glyphs,
/// names, the count, the header's menu).
struct Columns {
    let orange: [Int]
    let blue: [Int]
    let ink: [Int]
    let gapLimit: Int
    /// Where the orange and the blue sit vertically: the centroid of the
    /// warm and of the cool pixels, each weighted by its chroma, so an
    /// antialiased edge counts for what it shows. Nil when none is drawn.
    let orangeY: Double?
    let blueY: Double?
    /// The rightmost cluster of ink columns — the count on an agent
    /// group's header, the Group menu's glyph on a section's.
    var trailing: ClosedRange<Int>? {
        guard var lo = ink.last else { return nil }
        let hi = lo
        for x in ink.reversed().dropFirst() {
            if lo - x <= gapLimit { lo = x } else { break }
        }
        return lo...hi
    }
}

let scale: CGFloat = 2

@MainActor
func columns<V: View>(_ view: V, width: CGFloat) -> Columns? {
    let renderer = ImageRenderer(content: view
        .frame(width: width)
        .background(Color.white)
        .environment(\.colorScheme, .light))
    renderer.scale = scale
    guard let image = renderer.cgImage else { return nil }
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard drawn else { return nil }
    var orange = Set<Int>(), blue = Set<Int>(), ink = Set<Int>()
    var warmY = 0.0, warm = 0.0, coolY = 0.0, cool = 0.0
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255
            if r - b > 0.06 && r >= g && g >= b {
                warmY += (r - b) * (Double(y) + 0.5); warm += r - b
            } else if b - r > 0.06 && b >= g && g >= r {
                coolY += (b - r) * (Double(y) + 0.5); cool += b - r
            }
            if r >= 0.85 && r - b >= 0.25 && g <= 0.92 {
                orange.insert(x)
            } else if b >= 0.8 && b - r >= 0.3 && b - g >= 0.15 {
                blue.insert(x)
            } else if max(r, g, b) < 0.9 && abs(r - b) < 0.12 && abs(r - g) < 0.12 {
                ink.insert(x)
            }
        }
    }
    // Digits in the count, and the strokes of a glyph, sit closer than
    // this; the spacer in front of either is at least 4 pt.
    return Columns(orange: orange.sorted(), blue: blue.sorted(), ink: ink.sorted(),
                   gapLimit: Int(3 * scale),
                   orangeY: warm > 0 ? warmY / warm : nil,
                   blueY: cool > 0 ? coolY / cool : nil)
}

/// One header shape at one width and tier, drawn three ways: folded
/// (or collapsed) over something running, folded over nothing
/// running, and open over something running.
struct Probe: CustomStringConvertible {
    let kind: String
    let name: String
    let shortName: Bool
    let width: CGFloat
    let tier: FontTier
    /// The stack spacing in front of the dot.
    let spacing: CGFloat
    /// A count or a menu sits at the trailing edge.
    let hasTrailing: Bool
    let live: AnyView
    let idle: AnyView
    let open: AnyView
    /// Folded (or collapsed) over a finished run nobody has opened, with
    /// nothing running — the steady dot — and open over the same.
    let unread: AnyView
    let openUnread: AnyView
    /// Folded (or collapsed) over a running row AND an unopened one.
    let both: AnyView
    var description: String { "\(name), \(Int(width)) pt, \(tier.rawValue)" }
}

let tiers: [FontTier] = [.standard, .xlarge]
var probes: [Probe] = []

// Agent group headers. The title line gets the sidebar (190…440 pt)
// less the sections' 8 pt insets, its own 8 + 2 pt padding and the
// header's 18 pt + with its 4 pt margin: 142 pt at the narrowest.
let agentNames: [(String, String, String)] = [
    ("short name", "Work", ""),
    ("long custom name", "Every question that came up while writing the release notes, and every follow-up after it", ""),
    ("folder with a long parent", "app", "A Workspace Folder With A Long Name Of Its Own"),
    ("long folder and parent", "A folder name that runs well past the sidebar", "Projects"),
]
for (name, label, detail) in agentNames {
    for width: CGFloat in [142, 170, 200, 260, 392] {
        for count in [3, 128] {
            for tier in tiers {
                func line(_ folded: Bool, _ live: Bool, _ unread: Bool = false) -> AnyView {
                    AnyView(AgentGroupHeaderLabel(label: label, detail: detail, count: count,
                                                  folded: folded, live: live, unread: unread,
                                                  titleSize: SipFont.sidebarRow(tier.scale)))
                }
                probes.append(Probe(kind: "agent group", name: "\(name), count \(count)",
                                    shortName: label == "Work", width: width, tier: tier,
                                    spacing: 4, hasTrailing: true,
                                    live: line(true, true), idle: line(true, false),
                                    open: line(false, true),
                                    unread: line(true, false, true),
                                    openUnread: line(false, false, true),
                                    both: line(true, true, true)))
            }
        }
    }
}

// Chat group headers: the section less the group's 4 pt indent, the
// line's own 6 + 2 pt padding and the ⋮ with its margin — 140 pt at
// the narrowest sidebar.
let chatNames: [(String, String)] = [
    ("short name", "Work"),
    ("long name", "Research notes for the grant application and every follow-up after it"),
]
for (name, label) in chatNames {
    for width: CGFloat in [140, 170, 200, 260, 390] {
        for tier in tiers {
            func line(_ expanded: Bool, _ live: Bool, _ unread: Bool = false) -> AnyView {
                AnyView(ChatGroupHeaderLabel(name: label, expanded: expanded, live: live,
                                             unread: unread,
                                             titleSize: SipFont.sidebarRow(tier.scale)))
            }
            probes.append(Probe(kind: "chat group", name: name,
                                shortName: label == "Work", width: width, tier: tier,
                                spacing: 6, hasTrailing: false,
                                live: line(false, true), idle: line(false, false),
                                open: line(true, true),
                                unread: line(false, false, true),
                                openUnread: line(true, false, true),
                                both: line(false, true, true)))
        }
    }
}

// Section headers, drawn whole, with the Group menu's glyph as the
// accessory an agent section passes: the sidebar less the 8 pt insets.
// A 25-character label (Settings → Labels' cap) is cut at the narrow
// end — before the title was held to one line it came out as one cut
// line pinned to the top of a two-line row, drawn over the dot.
let sectionNames: [(String, String)] = [
    ("short title", "Codex"),
    ("default title", "Claude Code"),
    ("longest label", "A Coding Agent Named Long"),
]
func sectionHeader(_ title: String, expanded: Bool, live: Bool,
                   unread: Bool = false, tier: FontTier) -> AnyView {
    AnyView(DisclosureSection(
        title: title,
        isExpanded: .constant(expanded),
        live: live,
        unread: unread,
        accessory: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 16)
        },
        content: { EmptyView() })
        .environment(\.sipFontScale, tier.scale))
}
for (name, title) in sectionNames {
    for width: CGFloat in [174, 200, 260, 424] {
        for tier in tiers {
            probes.append(Probe(kind: "section", name: name,
                                shortName: title == "Codex", width: width, tier: tier,
                                spacing: 4, hasTrailing: true,
                                live: sectionHeader(title, expanded: false, live: true, tier: tier),
                                idle: sectionHeader(title, expanded: false, live: false, tier: tier),
                                open: sectionHeader(title, expanded: true, live: true, tier: tier),
                                unread: sectionHeader(title, expanded: false, live: false,
                                                      unread: true, tier: tier),
                                openUnread: sectionHeader(title, expanded: true, live: false,
                                                          unread: true, tier: tier),
                                both: sectionHeader(title, expanded: false, live: true,
                                                    unread: true, tier: tier)))
        }
    }
}

/// 3c's model and host: the REAL folded header over a running and an
/// unopened session, in a window, folded with the header's own animation
/// so the dots appear inside it.
final class PairFold: ObservableObject { @Published var folded = false }
struct PairHost: View {
    @ObservedObject var model: PairFold
    let tier: FontTier
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            AgentGroupHeaderLabel(label: "Work", detail: "", count: 3,
                                  folded: model.folded, live: true, unread: true,
                                  titleSize: SipFont.sidebarRow(tier.scale))
                .padding(.leading, 8)
                .padding(.trailing, 8)
                .padding(.top, 4)
                .padding(.bottom, 2)
            if !model.folded {
                ForEach(0..<3, id: \.self) { i in
                    Text(verbatim: "Session \(i)")
                        .font(.system(size: SipFont.sidebarRow(tier.scale)))
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(8)
        .frame(width: 280, height: 170, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .environment(\.sipFontScale, tier.scale)
    }
}

let rendered: Bool = MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    guard columns(Text(verbatim: "probe"), width: 60) != nil else { return false }

    /// Two column runs covering the same span, give or take one column
    /// at either end: the classifiers count an antialiased edge column
    /// at different coverages for orange and for blue.
    func sameSpan(_ a: [Int], _ b: [Int]) -> Bool {
        guard let a0 = a.first, let a1 = a.last, let b0 = b.first, let b1 = b.last
        else { return false }
        return abs(a0 - b0) <= 1 && abs(a1 - b1) <= 1
    }

    for kind in ["agent group", "chat group", "section"] {
        let mine = probes.filter { $0.kind == kind }
        var missing: [String] = [], stray: [String] = [], overlap: [String] = []
        var detached: [String] = [], moved: [String] = [], pinned: [String] = []
        var behind: [String] = []
        var steadyMisplaced: [String] = [], steadyStray: [String] = []
        var pairMissing: [String] = [], pairSpacing: [String] = []
        var pairDetached: [String] = [], pairBehind: [String] = []
        var pairTrailing: [String] = [], pairShifted: [String] = []
        var pairLevel: [String] = []
        for p in mine {
            guard let live = columns(p.live, width: p.width),
                  let idle = columns(p.idle, width: p.width),
                  let open = columns(p.open, width: p.width)
            else { missing.append("\(p): no render"); continue }

            if !idle.orange.isEmpty || !open.orange.isEmpty
                || !idle.blue.isEmpty || !open.blue.isEmpty || !live.blue.isEmpty {
                stray.append("\(p)")
            }
            // The steady dot: blue, exactly where the pulse is, and only
            // folded.
            if let unread = columns(p.unread, width: p.width),
               let openUnread = columns(p.openUnread, width: p.width) {
                if !unread.orange.isEmpty || !sameSpan(unread.blue, live.orange) {
                    steadyMisplaced.append("\(p): blue \(unread.blue.first ?? -1)...\(unread.blue.last ?? -1) vs pulse \(live.orange.first ?? -1)...\(live.orange.last ?? -1), orange \(unread.orange.count) col")
                }
                if !openUnread.blue.isEmpty || !openUnread.orange.isEmpty {
                    steadyStray.append("\(p)")
                }
            } else {
                steadyMisplaced.append("\(p): no render")
            }
            // Both: the pulse right after the text, the steady dot 8 pt
            // after the pulse and level with it, nothing of the text after
            // the pair, and the count or menu neither touched nor moved.
            if let both = columns(p.both, width: p.width) {
                if let pulseLo = both.orange.first, let pulseHi = both.orange.last,
                   let steadyLo = both.blue.first, let steadyHi = both.blue.last {
                    // Edge to edge: the 8 pt gap, i.e. first − last = 8 pt + 1 px.
                    let apart = steadyLo - pulseHi
                    if abs(apart - (Int(8 * scale) + 1)) > 1 {
                        pairSpacing.append("\(p): steady dot \(apart) px after the pulse's last column")
                    }
                    // One height: the two centroids within a quarter pixel.
                    if let oy = both.orangeY, let by = both.blueY, abs(oy - by) > 0.25 {
                        pairLevel.append("\(p): pulse centre y \(oy), steady \(by)")
                    } else if both.orangeY == nil || both.blueY == nil {
                        pairLevel.append("\(p): no centroid")
                    }
                    if let textEnd = both.ink.last(where: { $0 < pulseLo }),
                       pulseLo - textEnd > Int((p.spacing + 3) * scale) {
                        pairDetached.append("\(p): \(pulseLo - textEnd) px after the text")
                    }
                    let pairEdge = p.hasTrailing ? (both.trailing?.lowerBound ?? Int.max) : Int.max
                    if let after = both.ink.first(where: { $0 > pulseHi && $0 < pairEdge }) {
                        pairBehind.append("\(p): ink at \(after), pair \(pulseLo)...\(steadyHi)")
                    }
                    if p.hasTrailing {
                        if let trail = both.trailing, let idleTrail = idle.trailing {
                            if steadyHi + Int(2 * scale) > trail.lowerBound || trail != idleTrail {
                                pairTrailing.append("\(p): pair ends \(steadyHi), trailing \(trail) (alone \(idleTrail))")
                            }
                        } else {
                            pairTrailing.append("\(p): nothing found at the trailing edge")
                        }
                    }
                    // A name that is not cut: the pulse stays exactly where it
                    // is drawn alone — the steady dot is added, nothing moves.
                    if p.shortName && both.orange != live.orange {
                        pairShifted.append("\(p): pulse \(pulseLo)...\(pulseHi) vs alone \(live.orange.first ?? -1)...\(live.orange.last ?? -1)")
                    }
                } else {
                    pairMissing.append("\(p): orange \(both.orange.count) col, blue \(both.blue.count) col")
                }
            } else {
                pairMissing.append("\(p): no render")
            }
            guard let dotLo = live.orange.first, let dotHi = live.orange.last else {
                missing.append("\(p)"); continue
            }
            // Nothing of the text is drawn AFTER the dot — between it and
            // the count or menu, or to the edge where there is neither.
            let edge = p.hasTrailing ? (live.trailing?.lowerBound ?? Int.max) : Int.max
            if let after = live.ink.first(where: { $0 > dotHi && $0 < edge }) {
                behind.append("\(p): ink at \(after), dot ends at \(dotHi)")
            }
            // Right after the text: the stack's spacing, plus side bearing.
            if let textEnd = live.ink.last(where: { $0 < dotLo }),
               dotLo - textEnd > Int((p.spacing + 3) * scale) {
                detached.append("\(p): \(dotLo - textEnd) px after the text")
            }
            if p.hasTrailing {
                guard let trail = live.trailing, let idleTrail = idle.trailing else {
                    overlap.append("\(p): nothing found at the trailing edge"); continue
                }
                // Clear of the count / the menu by at least 2 pt…
                if dotHi + Int(2 * scale) > trail.lowerBound {
                    overlap.append("\(p): dot \(dotLo)...\(dotHi), trailing \(trail)")
                }
                // …and not one column of it moves because the dot is there.
                if trail != idleTrail {
                    moved.append("\(p): \(trail) with the dot, \(idleTrail) without")
                }
                // A short name: the dot follows the NAME, it is not
                // parked at the trailing edge.
                if p.shortName, p.width >= 200, trail.lowerBound - dotHi < Int(40 * scale) {
                    pinned.append("\(p): \(trail.lowerBound - dotHi) px from the trailing edge")
                }
            } else if p.shortName, p.width >= 200, CGFloat(dotHi) > p.width * scale / 2 {
                pinned.append("\(p): dot ends at \(dotHi) of \(Int(p.width * scale)) px")
            }
        }
        func report(_ label: String, _ bad: [String]) {
            check("\(kind): \(label)", bad.isEmpty,
                  "— \(bad.count) of \(mine.count): \(bad.prefix(3).joined(separator: "; "))")
        }
        report("the dot shows when folded over something running, at every width, name and tier", missing)
        report("…and only then — not folded over nothing, not open", stray)
        report("the STEADY dot shows folded over an unopened finished run, in blue, in exactly the pulse's place", steadyMisplaced)
        report("…and not when open", steadyStray)
        report("with both, BOTH dots show — the pulse and the steady dot", pairMissing)
        report("…the steady dot 8 pt after the pulse", pairSpacing)
        report("…and at the pulse's height, to a quarter pixel", pairLevel)
        report("…the pulse right after the text, after the \"…\" when the name is cut", pairDetached)
        report("…nothing of the text drawn after the pair", pairBehind)
        if kind != "chat group" {
            report("…the pair never touches or moves the \(kind == "section" ? "menu" : "count")", pairTrailing)
        }
        report("…and a name that is not cut keeps the pulse exactly where it is alone", pairShifted)
        report("it sits right after the text — after the \"…\" when the name is cut", detached)
        report("nothing of the text is drawn after it — the dot is never on top of it", behind)
        if kind != "chat group" {
            report("it never touches the \(kind == "section" ? "menu" : "count")", overlap)
            report("it does not move a single column of the \(kind == "section" ? "menu" : "count")", moved)
        }
        report("with a short name it follows the name, not the trailing edge", pinned)
    }

    // 3b. The scheduled task's glyph, drawn at 1x — the scale a
    // non-Retina display draws it at, where a bar off the pixel grid is
    // a faint two-pixel smear — and at 2x.
    print("3b. the task glyph, rendered (real view, offscreen)")
    struct Raster {
        let w: Int, h: Int
        let px: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let i = (y * w + x) * 4
            return (Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255)
        }
        /// Grey ink, and how dark: 0 black … 1 white; nil for colour.
        func grey(_ x: Int, _ y: Int) -> Double? {
            let (r, g, b) = rgb(x, y)
            guard abs(r - g) < 0.08 && abs(r - b) < 0.08 else { return nil }
            return (r + g + b) / 3
        }
        func clear(_ x: Int, _ y: Int) -> Bool { (grey(x, y) ?? 0) >= 0.95 }
        func isOrange(_ x: Int, _ y: Int) -> Bool {
            let (r, g, b) = rgb(x, y); return r >= 0.85 && r - b >= 0.25 && g <= 0.92
        }
        func isBlue(_ x: Int, _ y: Int) -> Bool {
            let (r, g, b) = rgb(x, y); return b >= 0.8 && b - r >= 0.3 && b - g >= 0.15
        }
    }
    @MainActor
    func raster<V: View>(_ view: V, scale s: CGFloat) -> Raster? {
        let renderer = ImageRenderer(content: view
            .background(Color.white)
            .environment(\.colorScheme, .light))
        renderer.scale = s
        guard let image = renderer.cgImage else { return nil }
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? Raster(w: w, h: h, px: px) : nil
    }

    // The glyph with 4 pt around it: the 14 pt slot at 4…18, the 16 pt
    // drawing at 3…19, the centre at 11. Folded, the bars are the rows
    // 3…4 and 18…19 across 7…15; open, the same spans transposed.
    let pad: CGFloat = 4
    var glyphFaults: [String: [String]] = [:]
    func fault(_ rule: String, _ detail: String) { glyphFaults[rule, default: []].append(detail) }
    let barRule = "the bars: above and below while folded, beside while open, each one pixel row (or column) per point, crisp, 8 pt long, centred"
    let clockRule = "the clock sits between the bars, centred, and does not move when the bars turn; no colour anywhere in the glyph"
    let boxRule = "nothing is drawn outside the glyph's 16 pt square"
    for s: CGFloat in [1, 2] {
        let S = Int(s)
        /// The bar spans, in pixels, for one fold state: (rows, cols) each.
        func bars(_ expanded: Bool) -> [(rows: Range<Int>, cols: Range<Int>)] {
            let near = (3 * S)..<(4 * S), far = (18 * S)..<(19 * S), along = (7 * S)..<(15 * S)
            return expanded ? [(along, near), (along, far)] : [(near, along), (far, along)]
        }
        /// Every bar pixel solid and alike; the pixel line just outside
        /// and just inside each bar clear; nothing past its two ends.
        func checkBars(_ r: Raster, expanded: Bool, _ label: String) {
            for bar in bars(expanded) {
                let horizontal = bar.rows.count == S
                let span = horizontal ? bar.cols : bar.rows
                // The first and last pixel along a bar carry its rounded
                // ends, so they are only held to being inked; the pixels
                // between them are held to one shade.
                var inner: [Double] = [], ends: [Double] = []
                for y in bar.rows {
                    for x in bar.cols {
                        let along = horizontal ? x : y
                        let shade = r.grey(x, y) ?? 1
                        if along == span.lowerBound || along == span.upperBound - 1 {
                            ends.append(shade)
                        } else {
                            inner.append(shade)
                        }
                    }
                }
                guard let darkest = inner.min(), let lightest = inner.max(),
                      darkest <= 0.75, lightest - darkest <= 0.06,
                      let endMax = ends.max(), endMax <= 0.85 else {
                    fault(barRule, "\(label) @\(S)x: bar \(bar) shades \(inner.min() ?? -1)…\(inner.max() ?? -1), ends ≤ \(ends.max() ?? -1)")
                    continue
                }
                let beside: [(Int, Int)] = horizontal
                    ? bar.cols.flatMap { x in [(x, bar.rows.lowerBound - 1), (x, bar.rows.upperBound)] }
                    : bar.rows.flatMap { y in [(bar.cols.lowerBound - 1, y), (bar.cols.upperBound, y)] }
                let beyond: [(Int, Int)] = horizontal
                    ? bar.rows.flatMap { y in [(bar.cols.lowerBound - 1, y), (bar.cols.upperBound, y)] }
                    : bar.cols.flatMap { x in [(x, bar.rows.lowerBound - 1), (x, bar.rows.upperBound)] }
                if let smear = (beside + beyond).first(where: { !r.clear($0.0, $0.1) }) {
                    fault(barRule, "\(label) @\(S)x: ink at \(smear) beside bar \(bar)")
                }
            }
        }
        /// The bounding box of what `match` picks inside the bars.
        func box(_ r: Raster, _ match: (Int, Int) -> Bool) -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
            var xs: [Int] = [], ys: [Int] = []
            for y in (5 * S)..<(17 * S) { for x in (5 * S)..<(17 * S) where match(x, y) { xs.append(x); ys.append(y) } }
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
            return (x0...x1, y0...y1)
        }
        func centred(_ b: (x: ClosedRange<Int>, y: ClosedRange<Int>)) -> Bool {
            // Centre 11 pt: in pixels, the box's two edges mirror about 11·S.
            abs((b.x.lowerBound + b.x.upperBound + 1) - 22 * S) <= 2
                && abs((b.y.lowerBound + b.y.upperBound + 1) - 22 * S) <= 2
        }
        var clockBoxes: [String] = []
        for expanded in [false, true] {
            let label = expanded ? "open" : "folded"
            guard let r = raster(ScheduledTaskGlyph(expanded: expanded).padding(pad), scale: s),
                  r.w == 22 * S, r.h == 22 * S
            else { fault(boxRule, "\(label) @\(S)x: no render at 22 pt"); continue }
            checkBars(r, expanded: expanded, label)
            // Outside the 16 pt square: the outermost point all round.
            for i in 0..<(22 * S) {
                for (x, y) in [(i, 3 * S - 1), (i, 19 * S), (3 * S - 1, i), (19 * S, i)]
                where !r.clear(x, y) {
                    fault(boxRule, "\(label) @\(S)x: ink at (\(x), \(y))"); break
                }
            }
            let grey = box(r) { r.grey($0, $1).map { $0 < 0.9 } ?? false }
            let orange = box(r, r.isOrange), blue = box(r, r.isBlue)
            guard let g = grey, orange == nil, blue == nil, centred(g) else {
                fault(clockRule, "\(label) @\(S)x: clock \(String(describing: grey)), orange \(String(describing: orange)), blue \(String(describing: blue))")
                continue
            }
            clockBoxes.append("\(g.x)×\(g.y)")
        }
        if clockBoxes.count == 2 && clockBoxes[0] != clockBoxes[1] {
            fault(clockRule, "@\(S)x: folded \(clockBoxes[0]), open \(clockBoxes[1])")
        }
    }
    for rule in [barRule, clockRule, boxRule] {
        check("task glyph: \(rule)", glyphFaults[rule] == nil,
              "— \((glyphFaults[rule] ?? []).prefix(3).joined(separator: "; "))")
    }
    let slot = NSHostingView(rootView: ScheduledTaskGlyph(expanded: false))
        .fittingSize
    check("task glyph: laid out in the row's 14 pt slot, so the title keeps every row's column",
          slot == CGSize(width: 14, height: 14), "— \(slot)")

    // 3c. The pair over time, in a window at the display's own scale —
    // the one place the pulse's beat is on screen rather than frozen.
    print("3c. the pair over time (real header, in a window)")
    struct Frame { let warmX, warmY, warm, coolX, coolY: Double }
    func frame(of view: NSView) -> Frame? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var wx = 0.0, wy = 0.0, wm = 0.0, cx = 0.0, cy = 0.0, cm = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
                if r - b > 0.06 && r >= g && g >= b {
                    wx += (r - b) * (Double(x) + 0.5); wy += (r - b) * (Double(y) + 0.5); wm += r - b
                } else if b - r > 0.06 && b >= g && g >= r {
                    cx += (b - r) * (Double(x) + 0.5); cy += (b - r) * (Double(y) + 0.5); cm += b - r
                }
            }
        }
        guard wm > 0, cm > 0 else { return nil }
        return Frame(warmX: wx / wm, warmY: wy / wm, warm: wm, coolX: cx / cm, coolY: cy / cm)
    }
    for tier in tiers {
        let model = PairFold()
        let host = NSHostingView(rootView: PairHost(model: model, tier: tier))
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 170)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 280, height: 170),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        let px = window.backingScaleFactor
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        withAnimation(.easeInOut(duration: 0.16)) { model.folded = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var frames: [Frame] = []
        for _ in 0..<48 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.035))
            if let f = frame(of: host) { frames.append(f) }
        }
        window.orderOut(nil)
        let label = "\(tier.rawValue) @\(Int(px))x"
        guard frames.count == 48 else {
            check("3c \(label): every frame shows both dots", false, "— \(frames.count) of 48")
            continue
        }
        let masses = frames.map(\.warm)
        check("3c \(label): the pulse beats (its colour swings by well over half)",
              masses.max()! / masses.min()! > 1.8, "— \(masses.min()!)…\(masses.max()!)")
        let level = frames.map { abs($0.warmY - $0.coolY) }.max()!
        check("3c \(label): in every frame the pulse sits at the steady dot's height",
              level <= 0.25, "— off by up to \(level) px")
        let xs = frames.map(\.warmX), ys = frames.map(\.warmY)
        check("3c \(label): and the pulse never moves",
              xs.max()! - xs.min()! <= 0.25 && ys.max()! - ys.min()! <= 0.25,
              "— x \(xs.min()!)…\(xs.max()!), y \(ys.min()!)…\(ys.max()!)")
        let apart = frames.map { $0.coolX - $0.warmX }
        check("3c \(label): the steady dot's centre is 14 pt on — 6 pt of dot and the 8 pt gap",
              apart.allSatisfy { abs($0 - 14 * Double(px)) <= 0.5 },
              "— \(apart.min()!)…\(apart.max()!) px")
    }

    // The fixtures must actually be long, or the checks above prove
    // nothing about long names.
    let agentFont = NSFont.systemFont(ofSize: SipFont.sidebarRow(FontTier.standard.scale),
                                      weight: .semibold)
    let agentLong = (agentNames[1].1 as NSString).size(withAttributes: [.font: agentFont]).width
    check("fixture: the long agent group name is wider than every header it is drawn in",
          agentLong > 392, "— \(Int(agentLong)) pt")
    let chatFont = NSFont.systemFont(ofSize: SipFont.sidebarRow(FontTier.standard.scale),
                                     weight: .medium)
    let chatLong = (chatNames[1].1 as NSString).size(withAttributes: [.font: chatFont]).width
    check("fixture: the long chat group name is wider than every header it is drawn in",
          chatLong > 390, "— \(Int(chatLong)) pt")
    let sectionFont = NSFont.systemFont(ofSize: SipFont.sidebarHeader(FontTier.standard.scale),
                                        weight: .semibold)
    let sectionLong = (sectionNames[2].1.uppercased() as NSString)
        .size(withAttributes: [.font: sectionFont]).width
    // What the title is offered at the narrowest section: the row's
    // 6 pt trailing pad, the 2 pt before the 18 pt menu, the label's 6 pt
    // leading pad, the ~7 pt chevron and the 4 pt beside it.
    let titleRoomAtNarrowest: CGFloat = 174 - 6 - 2 - 18 - 6 - 7 - 4
    check("fixture: the longest label is cut at the narrowest sidebar",
          sectionLong > titleRoomAtNarrowest,
          "— \(Int(sectionLong)) pt in \(Int(titleRoomAtNarrowest)) pt")
    return true
}
if !rendered {
    print("  SKIP  could not render offscreen (no window server?)")
}

print(failures == 0
      ? "\nAll checks passed."
      : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
