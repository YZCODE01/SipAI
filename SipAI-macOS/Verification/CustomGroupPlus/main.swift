// A custom group's header must be able to START a session in itself,
// and the session must land there.
//
// What this pins, and why each half exists:
//
//  * A group the user NAMED renders while empty. Dropped as an empty
//    bucket — which is right for a folder or a date, since those
//    describe rows — it made "New Group…" look like it had done
//    nothing: the group existed in config and nowhere on screen, so
//    it could not be given a +, renamed or deleted, and stayed
//    unreachable until a row was filed into it by hand. Ungrouped is
//    deliberately NOT in the exception; nobody made it.
//
//  * The + preselects the group's own most recently used folder —
//    the newest row filed there whose folder still opens. "Newest" is
//    the sidebar's own clock (`activityDate`, the last USER message),
//    and a row whose folder cannot be opened is skipped rather than
//    handed back: a session with no recorded cwd falls back to
//    decoding its `~/.claude/projects` dirname, and that encoding is
//    lossy enough to name a path that never existed.
//
//  * The filing is written when the session id arrives, in
//    `AgentManager.migrateRunner`, and BEFORE the placeholder row is
//    inserted. Both halves are structural checks below. In the view's
//    own discovery handler instead, a filing would be lost exactly
//    when the user starts a turn and clicks away — the centre pane is
//    torn down on any detour — and written after the placeholder, the
//    row appears under Ungrouped and jumps a frame later.
//
// The rules under test are compiled from the SHIPPING
// AgentSessionGrouping.swift; a harness holding its own copy of a rule
// passes for the wrong reason. The structural pass READS the views,
// and takes a source root so it can be pointed at another checkout:
//
//   ./run.sh [source-root]

import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    print(cond ? "  PASS  \(label)" : "  FAIL  \(label) \(detail)")
    if !cond { failures += 1 }
}

let sourceRoot = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

func source(_ relative: String) -> String {
    (try? String(contentsOfFile: sourceRoot + "/" + relative, encoding: .utf8)) ?? ""
}

/// Strip `//` comments, so a rule quoted in PROSE cannot satisfy a
/// check that the code makes it — half of what these files say about
/// these rules is said in their comments.
///
/// Line comments only. Every file read here is commented that way, and
/// a block-comment scanner has to be told that `projects/*/*.jsonl` in
/// a sentence is not an unterminated `/*` — which it read as one,
/// swallowing the rest of the file and passing every check that
/// searched it for something ABSENT.
func code(_ relative: String) -> String {
    source(relative)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            guard let slashes = line.range(of: "//") else { return String(line) }
            return String(line[..<slashes.lowerBound])
        }
        .joined(separator: "\n")
}

let day: TimeInterval = 86_400
let now = Date()
func at(_ daysAgo: Double) -> Date { now.addingTimeInterval(-daysAgo * day) }

func session(_ id: String, _ daysAgo: Double, folder: String?) -> AgentSession {
    AgentSession(id: id,
                 title: id,
                 lastUserMessageAt: at(daysAgo),
                 modifiedAt: at(daysAgo),
                 projectPath: folder.map { URL(fileURLWithPath: $0, isDirectory: true) })
}

// MARK: - 1. An empty group the user named renders; nothing else does

print("empty buckets")

let groups = ["Work", "Personal"]
let lone = AgentListItem.regular(session("s-work", 1, folder: "/tmp/work"))

var made = AgentSessionGrouping.buckets(
    [lone], mode: .custom,
    customGroups: groups,
    assignments: ["s-work": "Work"], now: now)

check("a named group with no rows still renders",
      made.contains { $0.key == "Personal" && $0.items.isEmpty },
      "— \"New Group…\" then + is the whole flow; a group nothing can see has no header to carry either")
check("a named group with rows renders them",
      made.first { $0.key == "Work" }?.items.count == 1)
check("empty Ungrouped is still dropped",
      !made.contains { $0.key == AgentSessionGrouping.ungroupedKey },
      "— nobody named it, and an empty one says nothing")
check("the user's own order is kept",
      made.map(\.key) == ["Work", "Personal"])

// An assignment naming a group that is gone reads as unfiled, and
// Ungrouped appears for it — but only because it now holds a row.
made = AgentSessionGrouping.buckets(
    [lone], mode: .custom,
    customGroups: ["Personal"],
    assignments: ["s-work": "Work"], now: now)
check("an assignment to a deleted group falls to Ungrouped",
      made.first { $0.key == AgentSessionGrouping.ungroupedKey }?.items.count == 1)
check("…and does not conjure the deleted group back",
      !made.contains { $0.key == "Work" })

// The exception is scoped to the mode, or every folder that ever held
// a session would keep an empty header forever.
let folderMade = AgentSessionGrouping.buckets(
    [lone], mode: .folder, customGroups: groups,
    assignments: ["s-work": "Work"], now: now)
check("folder mode still drops empty buckets",
      folderMade.count == 1 && folderMade[0].items.count == 1)
let dateMade = AgentSessionGrouping.buckets(
    [lone], mode: .date, customGroups: groups,
    assignments: ["s-work": "Work"], now: now)
check("date mode still drops empty buckets",
      dateMade.count == 1)
check("a section with no rows at all still shows its named groups",
      AgentSessionGrouping.buckets([], mode: .custom, customGroups: groups,
                                   assignments: [:], now: now).count == 2,
      "— \"New Group…\" on a fresh agent has to produce something to click")

// MARK: - 2. Which folder the + preselects

print("the group's folder")

// Sorted newest-first, the way the sidebar builds its stream.
let stream: [AgentListItem] = [
    .regular(session("newest-elsewhere", 0, folder: "/tmp/other")),
    .regular(session("newest-in-work", 1, folder: "/tmp/work-b")),
    .regular(session("older-in-work", 5, folder: "/tmp/work-a")),
]
let filed = ["newest-in-work": "Work", "older-in-work": "Work",
             "newest-elsewhere": "Personal"]
let allOpen: (URL) -> Bool = { _ in true }

check("the newest row filed in the group wins",
      AgentSessionGrouping.latestFolder(inGroup: "Work", sortedItems: stream,
                                        assignments: filed, usable: allOpen)?.path
        == "/tmp/work-b")
check("a newer row filed ELSEWHERE never counts",
      AgentSessionGrouping.latestFolder(inGroup: "Work", sortedItems: stream,
                                        assignments: filed, usable: allOpen)?.path
        != "/tmp/other",
      "— the + was clicked on a group, not on the list")
check("a folder that cannot be opened is skipped for the next row",
      AgentSessionGrouping.latestFolder(
        inGroup: "Work", sortedItems: stream, assignments: filed,
        usable: { $0.path != "/tmp/work-b" })?.path == "/tmp/work-a",
      "— a lossy dirname decode can name a plausible path that never existed")
check("a row with no folder at all is skipped, not returned as nil",
      AgentSessionGrouping.latestFolder(
        inGroup: "Work",
        sortedItems: [.regular(session("no-folder", 0, folder: nil)),
                      .regular(session("older-in-work", 5, folder: "/tmp/work-a"))],
        assignments: ["no-folder": "Work", "older-in-work": "Work"],
        usable: allOpen)?.path == "/tmp/work-a")
check("an empty group answers nil",
      AgentSessionGrouping.latestFolder(inGroup: "Personal",
                                        sortedItems: [], assignments: [:],
                                        usable: allOpen) == nil,
      "— the caller falls back to its own default rather than inventing one")
check("every row unopenable answers nil",
      AgentSessionGrouping.latestFolder(inGroup: "Work", sortedItems: stream,
                                        assignments: filed,
                                        usable: { _ in false }) == nil)

// A task answers with its own cwd, so a group holding only scheduled
// tasks still preselects a folder.
let task = ScheduledAgentTask(
    name: "nightly",
    workingDirectory: URL(fileURLWithPath: "/tmp/task-cwd", isDirectory: true),
    sessions: [session("run-1", 2, folder: "/tmp/ran-here")])
check("a scheduled task's own cwd counts",
      AgentSessionGrouping.latestFolder(
        inGroup: "Work", sortedItems: [.scheduled(task)],
        assignments: [AgentListItem.groupItemKey(forScheduledTaskName: "nightly"): "Work"],
        usable: allOpen)?.path == "/tmp/task-cwd")

// MARK: - 3. One spelling of the assignment key

print("the assignment key")

check("the static key matches the row's own",
      AgentListItem.groupItemKey(forScheduledTaskName: task.name)
        == AgentListItem.scheduled(task).groupItemKey,
      "— the composer files a task the scanner has not seen yet; two spellings would file it where nothing looks")
check("a session keys off its id",
      AgentListItem.regular(session("abc", 0, folder: nil)).groupItemKey == "abc")
check("the two id spaces cannot collide",
      AgentListItem.groupItemKey(forScheduledTaskName: "abc") != "abc")

let groupingSource = code("SipAI-macOS/SipAI/Models/AgentSessionGrouping.swift")
var schedSpellings = 0
for file in ["SipAI-macOS/SipAI/Models/AgentSessionGrouping.swift",
             "SipAI-macOS/SipAI/Models/AgentManager.swift",
             "SipAI-macOS/SipAI/Models/ConfigManager.swift",
             "SipAI-macOS/SipAI/Views/Chat/AgentComposer.swift",
             "SipAI-macOS/SipAI/Views/Chat/AgentSessionView.swift",
             "SipAI-macOS/SipAI/Views/Sidebar/AgentSessionsSection.swift"] {
    schedSpellings += code(file).components(separatedBy: "\"sched:").count - 1
}
check("the \"sched:\" prefix is written in exactly one place",
      schedSpellings == 1,
      "— found \(schedSpellings); a second spelling is how two callers file one task two ways")

// MARK: - 4. The wiring the harness cannot run

print("wiring")

let section = code("SipAI-macOS/SipAI/Views/Sidebar/AgentSessionsSection.swift")
let manager = code("SipAI-macOS/SipAI/Models/AgentManager.swift")
let sessionModel = code("SipAI-macOS/SipAI/Models/AgentSession.swift")
let app = code("SipAI-macOS/SipAI/SipAIApp.swift")
let composer = code("SipAI-macOS/SipAI/Views/Chat/AgentComposer.swift")
let sessionView = code("SipAI-macOS/SipAI/Views/Chat/AgentSessionView.swift")

check("the draft carries the group it was started from",
      sessionModel.contains("var customGroup: String?"),
      "— without it there is nothing to file when the session id arrives")
check("the header + is offered on custom groups",
      section.contains("startNewSession(inGroup:"),
      "— the reported gap: only folder headers had one")
check("…gated on the group being one the user NAMED",
      section.contains("customGroups.contains(group.key)"),
      "— Ungrouped must not offer one; the section's own row already makes an unfiled session")
check("…and on the agent being drivable",
      section.contains("let showsPlus = isReady"),
      "— a read-only section cannot spawn anything")
check("the group's folder is read through the shared rule",
      section.contains("AgentSessionGrouping.latestFolder("),
      "— not a second walk of the list with its own idea of newest")
check("…falling back to the ordinary new-session folder",
      section.contains("defaultNewSessionCwd()"),
      "— a group with no rows is the ordinary case, not an error")
check("the + and the list read ONE ordering",
      section.contains("sortedItems: sortedListItems"),
      "— two sorts is two answers to \"which row is newest\"")

check("the filing happens where the session id is born",
      manager.contains("setAgentSessionGroup("),
      "— a draft has no key to file under, and the send happens under one no session will ever have")
if let filing = manager.range(of: "setAgentSessionGroup("),
   let placeholder = manager.range(of: "sessions.insert(placeholder") {
    check("…BEFORE the placeholder row is inserted",
          filing.lowerBound < placeholder.lowerBound,
          "— the insert re-renders the sidebar; filed after, the row shows under Ungrouped and jumps")
} else {
    check("…BEFORE the placeholder row is inserted", false, "— one of the two calls is missing")
}
check("a group deleted mid-draft is not resurrected",
      manager.contains("agentCustomGroups(for: runner.agentKey).contains(group)"),
      "— per AGENT, and membership-tested, so config never points at a group that is gone")
check("the manager is given the config it writes through",
      manager.contains("func configure(bridge: MCPBridge, config: ConfigManager)")
        && app.contains("configure(bridge: mcpBridge, config: configManager)"))
check("the filing is NOT left to the view",
      !sessionView.contains("setAgentSessionGroup("),
      "— the centre pane is torn down by any detour, so a filing addressed to it is lost mid-turn")

// The three findings of the implementation audit, each of which the
// first cut got wrong and none of which a compile can catch.
check("the launch scan still reads \"Scanning…\" under Custom",
      section.contains("(agents.isScanning || !namedGroupsToDraw)"),
      "— `sessions` is empty until the first scan lands; without this every group sits at 0 for the length of it")
check("a rename follows into the pending draft",
      section.contains("appState.pendingClaudeSessionDraft?.customGroup = name"),
      "— the first send hands the DRAFT to the runner, so a draft holding the old name would be unfiled by the rename")
check("the draft page re-reads membership, so a deleted group is never claimed",
      sessionView.contains("config.agentCustomGroups(for: d.agentKey).contains(group)"),
      "— the filing guard says no; the page must not keep saying yes")

check("the draft page names the group",
      sessionView.contains("draftCustomGroup"),
      "— the filing is otherwise invisible until the session exists")
check("…through the verbatim Text overload",
      sessionView.contains("Text(String(localized: \"It will appear in the"),
      "— a group name is user text, and the interpolated-literal overload markdown-parses it")
check("a task created from a group's draft is filed there too",
      composer.contains("setAgentSessionGroup(")
        && composer.contains("forScheduledTaskName:"),
      "— it already inherits the draft's folder; landing in Ungrouped reads as a bug")
check("…membership-tested the same way",
      composer.contains("agentCustomGroups(for: agentKey).contains(group)"))

// MARK: - 5. Strings

print("strings")

let catalog = source("SipAI-macOS/SipAI/Resources/Localizable.xcstrings")
for key in ["It will appear in the “%@” group.", "New session in %@"] {
    let quoted = "\"\(key)\" : {"
    check("catalog holds \(key)", catalog.contains(quoted))
    if let start = catalog.range(of: quoted) {
        let tail = catalog[start.upperBound...].prefix(600)
        check("…with a zh-Hans value", tail.contains("\"zh-Hans\""),
              "— half the UI comes up English otherwise")
    }
}
check("the + reuses the existing key rather than minting a near-duplicate",
      catalog.components(separatedBy: "New session in %@").count - 1 == 1)

print(failures == 0
      ? "\nAll checks passed."
      : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
