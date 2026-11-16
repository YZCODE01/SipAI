// The sidebar's ⋮ menus on its section and group headers.
//
// What this pins, and why each part exists:
//
//  * Notes, Chats and Chat groups each carry a ⋮ whose Hide takes the
//    section off the sidebar, and Settings → Display holds the switch
//    that brings it back — the confirmation names that place, so a
//    section hidden by a stray click is never lost.
//
//  * A Folder or Custom group's header carries a ⋮ between its count
//    and its +, and every action on the group is in it — the header has
//    no right-click menu: Mark all as read, Rename for a named group, and
//    a delete that says what it removes. In Folder mode it is "Delete all sessions" — the folder is
//    a directory on disk and is never touched. In Custom mode a group
//    is the user's own thing, so its delete is "Delete the group": the
//    group and its sessions go together, and "Ungroup" is the delete
//    that keeps them. Scheduled tasks are never removed by any of these:
//    they are not sessions, and their own menu has their own deletes.
//
//  * Ungrouped carries a + and a ⋮ like every other custom group. Its +
//    starts a session filed nowhere, in the folder Ungrouped's newest
//    row was worked in. Grouped by Custom, the section's first row makes
//    a GROUP ("+ New group"), so Ungrouped is drawn there even while
//    empty: its + is then the only way to start a session in no group.
//
//  * A custom group's Ungroup, Delete and Rename touch only THIS
//    agent's filings. Filings are one map for every agent, keyed by row
//    and holding a group NAME; two agents may each have a group called
//    "Work", and a delete that cleared every filing naming "Work"
//    emptied the other agent's group too.
//
// The rules are compiled from the SHIPPING AgentSessionGrouping.swift
// and ConfigManager.swift; the wiring is READ off the views. Takes a
// source root so the structural pass can be pointed at another checkout:
//
//   ./run.sh [source-root]

import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    print(cond ? "  PASS  \(label)" : "  FAIL  \(label) \(detail)")
    if !cond { failures += 1 }
}
func section(_ title: String) { print("\n" + title) }

let sourceRoot = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

func source(_ relative: String) -> String {
    (try? String(contentsOfFile: sourceRoot + "/" + relative, encoding: .utf8)) ?? ""
}

/// `//` comments stripped, so a rule quoted in prose cannot satisfy a
/// check the code has to make.
func code(_ relative: String) -> String {
    source(relative)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            guard let slashes = line.range(of: "//") else { return String(line) }
            return String(line[..<slashes.lowerBound])
        }
        .joined(separator: "\n")
}

/// From `start` to the first `end` after it.
func slice(_ text: String, from start: String, to end: String) -> Substring {
    guard let a = text.range(of: start) else { return "" }
    let rest = text[a.lowerBound...]
    return rest[..<(rest.range(of: end)?.upperBound ?? rest.endIndex)]
}

/// A function's body: from `func name` to the next member at the same
/// indentation.
func body(of name: String, in text: String) -> Substring {
    guard let start = text.range(of: "func " + name) else { return "" }
    let rest = text[start.upperBound...]
    let ends = ["\n    func ", "\n    private func ", "\n    @ViewBuilder",
                "\n    private var ", "\n    var ", "\n    // MARK"]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return rest[..<(ends.min() ?? rest.endIndex)]
}

func precedes(_ first: String, _ second: String, in text: Substring) -> Bool {
    guard let a = text.range(of: first), let b = text.range(of: second) else { return false }
    return a.lowerBound < b.lowerBound
}

func occurrences(_ needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
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

// MARK: - 1. Which custom bucket a row is filed in — one spelling

section("1. A row's custom bucket")

let groups = ["Work", "Personal"]
let filed = AgentListItem.regular(session("s-work", 1, folder: "/tmp/work"))
let unfiled = AgentListItem.regular(session("s-loose", 2, folder: "/tmp/loose"))
let stale = AgentListItem.regular(session("s-stale", 3, folder: "/tmp/stale"))
let assignments = ["s-work": "Work", "s-stale": "Gone"]

check("a row filed in a group it names is in that group",
      AgentSessionGrouping.customGroupKey(of: filed, customGroups: groups,
                                          assignments: assignments) == "Work")
check("a row filed nowhere is Ungrouped",
      AgentSessionGrouping.customGroupKey(of: unfiled, customGroups: groups,
                                          assignments: assignments)
        == AgentSessionGrouping.ungroupedKey)
check("a row filed in a group that is gone is Ungrouped",
      AgentSessionGrouping.customGroupKey(of: stale, customGroups: groups,
                                          assignments: assignments)
        == AgentSessionGrouping.ungroupedKey,
      "— a hand-edited config must not conjure a group back")
let made = AgentSessionGrouping.buckets([filed, unfiled, stale], mode: .custom,
                                        customGroups: groups,
                                        assignments: assignments, now: now)
check("the bucketer files every row where the rule says",
      made.allSatisfy { group in
          group.items.allSatisfy {
              AgentSessionGrouping.customGroupKey(of: $0, customGroups: groups,
                                                  assignments: assignments) == group.key
          }
      } && made.first { $0.key == AgentSessionGrouping.ungroupedKey }?.items.count == 2,
      "— the + and the ⋮ act on Ungrouped's rows; a second spelling of membership is how they come to act on others")
let allFiled = AgentSessionGrouping.buckets([filed], mode: .custom, customGroups: groups,
                                            assignments: assignments, now: now)
check("grouped by Custom, Ungrouped is drawn while empty, with nothing in it",
      allFiled.first { $0.key == AgentSessionGrouping.ungroupedKey }?.items.isEmpty == true,
      "— the first row makes a group there, so Ungrouped's + is the only way to start a session in no group")
check("…last, after every named group",
      allFiled.map(\.key) == ["Work", "Personal", AgentSessionGrouping.ungroupedKey],
      "— got \(allFiled.map(\.key))")
check("…and on a fresh agent with no groups, it is all there is",
      AgentSessionGrouping.buckets([], mode: .custom, now: now).map(\.key)
        == [AgentSessionGrouping.ungroupedKey])
check("no other mode keeps an empty bucket",
      [AgentGroupMode.folder, .date, .state, .none].allSatisfy {
          AgentSessionGrouping.buckets([], mode: $0, customGroups: groups, now: now).isEmpty
      })

// MARK: - 2. Ungrouped's + — the folder it starts in

section("2. Ungrouped's +")

let stream: [AgentListItem] = [
    .regular(session("newest-filed", 0, folder: "/tmp/work-b")),
    .regular(session("newest-loose", 1, folder: "/tmp/loose-b")),
    .regular(session("older-loose", 4, folder: "/tmp/loose-a")),
    .regular(session("stale-filing", 6, folder: "/tmp/stale")),
]
let filings = ["newest-filed": "Work", "stale-filing": "Gone"]
let allOpen: (URL) -> Bool = { _ in true }

check("the newest row filed in no group decides",
      AgentSessionGrouping.latestUngroupedFolder(
        sortedItems: stream, customGroups: groups, assignments: filings,
        usable: allOpen)?.path == "/tmp/loose-b")
check("a newer row filed in a group never counts",
      AgentSessionGrouping.latestUngroupedFolder(
        sortedItems: stream, customGroups: groups, assignments: filings,
        usable: allOpen)?.path != "/tmp/work-b")
check("a folder that cannot be opened is skipped for the next row",
      AgentSessionGrouping.latestUngroupedFolder(
        sortedItems: stream, customGroups: groups, assignments: filings,
        usable: { $0.path != "/tmp/loose-b" })?.path == "/tmp/loose-a")
check("a row filed in a group that is gone counts as Ungrouped",
      AgentSessionGrouping.latestUngroupedFolder(
        sortedItems: stream, customGroups: groups, assignments: filings,
        usable: { $0.path == "/tmp/stale" })?.path == "/tmp/stale")
check("nothing usable answers nil, for the caller's own default",
      AgentSessionGrouping.latestUngroupedFolder(
        sortedItems: stream, customGroups: groups, assignments: filings,
        usable: { _ in false }) == nil)
check("a named group's own + still reads its own rows",
      AgentSessionGrouping.latestFolder(inGroup: "Work", sortedItems: stream,
                                        assignments: filings,
                                        usable: allOpen)?.path == "/tmp/work-b")

// MARK: - 3. What a header carries beside its count

section("3. A header's ⋮ and +")

typealias Actions = AgentSessionGrouping.HeaderActions
func actions(_ mode: AgentGroupMode, _ key: String) -> Actions {
    AgentSessionGrouping.headerActions(mode: mode, key: key, customGroups: groups)
}
check("a folder: ⋮ (Delete all sessions) and +",
      actions(.folder, "/tmp/work") == Actions(menu: .folder, plus: true))
check("No directory: ⋮, and no + — there is no folder to start in",
      actions(.folder, AgentSessionGrouping.noDirectoryKey)
        == Actions(menu: .noDirectory, plus: false))
check("a named custom group: ⋮ (Delete the group) and +",
      actions(.custom, "Work") == Actions(menu: .namedGroup, plus: true))
check("Ungrouped: ⋮ (Delete all sessions) and +, like every other custom group",
      actions(.custom, AgentSessionGrouping.ungroupedKey)
        == Actions(menu: .ungrouped, plus: true))
check("a group a user CALLED \"Ungrouped\" is still a named group",
      AgentSessionGrouping.headerActions(mode: .custom, key: "Ungrouped",
                                         customGroups: ["Ungrouped"])
        == Actions(menu: .namedGroup, plus: true))
check("Date and State headers carry neither",
      [AgentGroupMode.date, .state, .none].allSatisfy {
          actions($0, "today") == Actions(menu: nil, plus: false)
      })

// MARK: - 4. What Mark all as read clears and what a delete removes

section("4. Mark all as read, and the deletes")

let run1 = session("run-1", 1, folder: "/tmp/task")
let run2 = session("run-2", 2, folder: "/tmp/task")
let task = ScheduledAgentTask(name: "nightly", sessions: [run1, run2])
let members: [AgentListItem] = [
    .regular(session("a", 0, folder: "/tmp/work")),
    .scheduled(task),
    .regular(session("b", 3, folder: "/tmp/work")),
]
check("a session stands for itself",
      AgentListItem.regular(session("a", 0, folder: nil)).sessionIds == ["a"])
check("a scheduled task stands for its runs",
      AgentListItem.scheduled(task).sessionIds == ["run-1", "run-2"],
      "— a task row's steady dot is its runs'; Mark all as read must clear them or the dot stays")
check("a group's Mark all as read covers its tasks' runs",
      Set(members.flatMap(\.sessionIds)) == ["a", "b", "run-1", "run-2"])
check("a delete removes the group's sessions…",
      AgentSessionGrouping.sessionsDeleted(from: members).map(\.id) == ["a", "b"])
check("…and never a scheduled task or its runs",
      !AgentSessionGrouping.sessionsDeleted(from: members).contains { $0.id.hasPrefix("run-") },
      "— a task is not a session; deleting it stops its schedule, which its own menu asks about")
check("a group of tasks alone has nothing to delete",
      AgentSessionGrouping.sessionsDeleted(from: [.scheduled(task)]).isEmpty)

// MARK: - 5. The three section switches

section("5. Settings → Display: the sections' switches")

let harnessDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sipai-sidebar-menus-\(ProcessInfo.processInfo.processIdentifier)")
SipaiPaths.dataDir = harnessDir
try? FileManager.default.removeItem(at: harnessDir)
SipaiPaths.ensureDataDir()

/// Plant a raw config.json and hand back a manager that has read it.
func plant(_ json: [String: Any]) -> ConfigManager {
    let data = try! JSONSerialization.data(withJSONObject: json)
    try? data.write(to: SipaiPaths.configFile, options: .atomic)
    return MainActor.assumeIsolated { ConfigManager() }
}

/// What is on disk, not what the object in memory believes.
func stored() -> [String: Any] {
    guard let data = try? Data(contentsOf: SipaiPaths.configFile),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return [:] }
    return obj
}

MainActor.assumeIsolated {
    let fresh = plant([:])
    check("every section shows on a fresh install",
          fresh.display.showNotesSection && fresh.display.showChatsSection
            && fresh.display.showChatGroupsSection)

    let hidden = plant(["display": ["sidebar_notes": false,
                                    "sidebar_chat_groups": false,
                                    "a_key_this_app_does_not_model": 7]])
    check("a stored switch is read",
          !hidden.display.showNotesSection && hidden.display.showChatsSection
            && !hidden.display.showChatGroupsSection)
    hidden.setDisplay { $0.showChatsSection = false }
    let display = stored()["display"] as? [String: Any] ?? [:]
    check("a write keeps the others and writes the one",
          display["sidebar_notes"] as? Bool == false
            && display["sidebar_chats"] as? Bool == false
            && display["sidebar_chat_groups"] as? Bool == false)
    check("…and carries a key it does not model",
          display["a_key_this_app_does_not_model"] as? Int == 7)
    hidden.setDisplay { $0.showNotesSection = true }
    check("turned back on, it is on",
          plant(stored()).display.showNotesSection)
}

// MARK: - 5b. A hidden section keeps its place in the dragged order

section("5b. A hidden section keeps its place in the order a drag saves")

// The section ids as `sidebar_section_order` stores them, read off the
// sidebar's own enum (declaration order is the default order).
let sidebarSource = code("SipAI-macOS/SipAI/Views/Sidebar/LeftSidebar.swift")
var sectionIds: [String] = []
for line in slice(sidebarSource, from: "private enum SectionId", to: "\n    }\n").split(separator: "\n") {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.hasPrefix("case ") else { continue }
    if let raw = t.range(of: "= \"") {
        sectionIds.append(String(t[raw.upperBound...].dropLast()))
    } else {
        sectionIds.append(String(t.dropFirst("case ".count)))
    }
}
check("the sidebar's seven sections are read",
      sectionIds == ["notes", "files", "chats", "chat_groups",
                     "agent_claude_code", "agent_codex", "agent_kimi"],
      "— got \(sectionIds)")

check("a drop moving down lands after its target, an id not on screen left where it is",
      SidebarOrdering.moving(["a", "h", "b", "c"], dragged: "a", onto: "b") == ["h", "b", "a", "c"])
check("…and one moving up lands before it",
      SidebarOrdering.moving(["a", "h", "b", "c"], dragged: "c", onto: "b") == ["a", "h", "c", "b"])
check("…and a drop on itself, or naming an id the order lacks, moves nothing",
      SidebarOrdering.moving(["a", "b"], dragged: "a", onto: "a") == nil
        && SidebarOrdering.moving(["a", "b"], dragged: "x", onto: "b") == nil
        && SidebarOrdering.moving(["a", "b"], dragged: "a", onto: "x") == nil)

/// What the sidebar draws: the sections on screen in the saved order.
func drawn(_ saved: [String], present: [String]) -> [String] {
    SidebarOrdering.apply(sectionIds, order: saved, id: { $0 }).filter(present.contains)
}
/// A drag of `dragged` across `rows`, top to bottom of its path: each
/// row crossed is one `dropEntered`, which saves what `moving` hands
/// back over the order the drag works on. `everySection` is that order's
/// shape: every section (the sidebar's), or the ones on screen alone.
func drag(_ dragged: String, across rows: [String], from saved: [String],
          present: [String], everySection: Bool) -> [String] {
    var saved = saved
    for row in rows {
        let order = SidebarOrdering.apply(everySection ? sectionIds : present,
                                          order: saved, id: { $0 })
        if let moved = SidebarOrdering.moving(order, dragged: dragged, onto: row) {
            saved = moved
        }
    }
    return saved
}

// Notes hidden; Kimi dragged to the top of what is shown; Notes shown
// again. No dedicated folder, so Files is not on screen either.
let shownA = ["chats", "chat_groups", "agent_claude_code", "agent_codex", "agent_kimi"]
let pathA = ["agent_codex", "agent_claude_code", "chat_groups", "chats"]
let expectedA = ["notes", "agent_kimi", "chats", "chat_groups", "agent_claude_code", "agent_codex"]
let staleA = drawn(drag("agent_kimi", across: pathA, from: [], present: shownA, everySection: false),
                   present: ["notes"] + shownA)
check("(control) saving only the sections on screen loses a hidden one's place: Notes comes back last",
      staleA.last == "notes" && staleA != expectedA, "— got \(staleA)")
let savedA = drag("agent_kimi", across: pathA, from: [], present: shownA, everySection: true)
check("Notes hidden, Kimi dragged to the top: Notes comes back at the top, above Kimi",
      drawn(savedA, present: ["notes"] + shownA) == expectedA,
      "— got \(drawn(savedA, present: ["notes"] + shownA))")
check("…and while Notes is hidden the others read as dragged",
      drawn(savedA, present: shownA) == Array(expectedA.dropFirst()))

// Chats hidden from an order a drag has saved; Codex dragged up to
// just under Notes; Chats shown again.
let fullB = sectionIds
let shownB = ["notes", "chat_groups", "agent_claude_code", "agent_codex", "agent_kimi"]
let savedB = drag("agent_codex", across: ["agent_claude_code", "chat_groups"],
                  from: fullB, present: shownB, everySection: true)
check("Chats hidden between Notes and Chat groups comes back under Notes",
      drawn(savedB, present: ["notes", "chats"] + shownB.dropFirst())
        == ["notes", "chats", "agent_codex", "chat_groups", "agent_claude_code", "agent_kimi"],
      "— got \(drawn(savedB, present: ["notes", "chats"] + shownB.dropFirst()))")

// An agent that is not listed for now (signed out, hidden) is the same
// case: Kimi dragged to the top, then signed out; Codex dragged above
// Claude Code; Kimi signs in again.
let kimiOnTop = ["agent_kimi"] + sectionIds.filter { $0 != "agent_kimi" }
let shownC = ["notes", "chats", "chat_groups", "agent_claude_code", "agent_codex"]
let savedC = drag("agent_codex", across: ["agent_claude_code"], from: kimiOnTop,
                  present: shownC, everySection: true)
check("an agent not listed for a while comes back where it was dragged to",
      drawn(savedC, present: shownC + ["agent_kimi"])
        == ["agent_kimi", "notes", "chats", "chat_groups", "agent_codex", "agent_claude_code"],
      "— got \(drawn(savedC, present: shownC + ["agent_kimi"]))")

// MARK: - 6. A custom group's Ungroup, Delete and Rename touch only this agent

section("6. One agent's group, and another's of the same name")

MainActor.assumeIsolated {
    // Claude and Codex each have a "Work" group; each files one row in
    // it. The filings share one map, keyed by row.
    let both: [String: Any] = [
        "agent_custom_groups": ["claude_code": ["Work", "Home"], "codex": ["Work"]],
        "agent_session_groups": ["claude-1": "Work", "claude-2": "Home",
                                 "codex-1": "Work", "deleted-codex": "Work"],
        "agent_group_collapsed": ["codex": ["custom": ["Work"]]],
        "agent_group_order": ["codex": ["custom": ["Work"]]],
    ]

    var config = plant(both)
    config.deleteAgentCustomGroup("Work", for: "codex", keeping: ["claude-1", "claude-2"])
    var filingsNow = config.agentSessionGroupAssignments
    check("deleting Codex's \"Work\" unfiles Codex's rows",
          filingsNow["codex-1"] == nil && filingsNow["deleted-codex"] == nil)
    check("…and leaves Claude Code's \"Work\" as it was",
          filingsNow["claude-1"] == "Work" && filingsNow["claude-2"] == "Home",
          "— filings are one map; clearing every one naming \"Work\" emptied the other agent's group")
    check("…and Claude Code's groups",
          config.agentCustomGroups(for: "claude_code") == ["Work", "Home"]
            && config.agentCustomGroups(for: "codex").isEmpty)
    check("a group made again under that name starts unfolded and undragged",
          config.agentCollapsedGroups(for: "codex", mode: .custom).isEmpty
            && config.agentGroupOrder(for: "codex", mode: .custom).isEmpty,
          "— its fold state and dragged slot belonged to the group that was deleted")

    config = plant(both)
    _ = config.renameAgentCustomGroup("Work", to: "Job", for: "codex",
                                      keeping: ["claude-1", "claude-2"])
    filingsNow = config.agentSessionGroupAssignments
    check("renaming Codex's \"Work\" moves Codex's rows",
          filingsNow["codex-1"] == "Job")
    check("…and leaves Claude Code's rows in its own \"Work\"",
          filingsNow["claude-1"] == "Work",
          "— moved to \"Job\", a group Claude Code does not have, they fell to Ungrouped")
}

// MARK: - 7. Wiring the rules cannot run on their own

section("7. Wiring, read off the sources")

let sidebar = code("SipAI-macOS/SipAI/Views/Sidebar/LeftSidebar.swift")
let notes = code("SipAI-macOS/SipAI/Views/Sidebar/NotesSection.swift")
let chatList = code("SipAI-macOS/SipAI/Views/Sidebar/ChatListView.swift")
let sec = code("SipAI-macOS/SipAI/Views/Sidebar/AgentSessionsSection.swift")
let manager = code("SipAI-macOS/SipAI/Models/AgentManager.swift")
let settings = code("SipAI-macOS/SipAI/Views/Settings/SettingsView.swift")
let configSource = code("SipAI-macOS/SipAI/Models/ConfigManager.swift")
check("the sources are where they are expected",
      !sidebar.isEmpty && !notes.isEmpty && !chatList.isEmpty && !sec.isEmpty
        && !manager.isEmpty && !settings.isEmpty && !configSource.isEmpty)

// The sections.
let ordered = slice(sidebar, from: "private var orderedSectionIds: [SectionId] {", to: "\n    }\n")
check("a hidden section is left out of the sidebar",
      ordered.contains("if config.display.showNotesSection { present.append(.notes) }")
        && ordered.contains("if config.display.showChatsSection { present.append(.chats) }")
        && ordered.contains("if config.display.showChatGroupsSection { present.append(.chatGroups) }"))
let dragOrder = slice(sidebar, from: "private var sectionOrderBinding: Binding<[String]> {", to: "\n    }\n")
check("the order a drag works on holds every section, the ones not on screen included",
      dragOrder.contains("get: { sectionOrder.map(\\.rawValue) }")
        && sidebar.contains("SidebarOrdering.apply(SectionId.allCases,"),
      "— a drag that saves only the sections on screen loses a hidden one's place")
check("…and the sidebar draws that same order, filtered to what is on screen",
      ordered.contains("return sectionOrder.filter(present.contains)"),
      "— two resolutions of one order could disagree, and a drag would move the wrong row")
let dropDelegate = slice(code("SipAI-macOS/SipAI/Utilities/DesignSystem.swift"),
                         from: "struct SidebarReorderDropDelegate", to: "\n}\n")
check("a drop saves what SidebarOrdering.moving hands back",
      dropDelegate.contains("SidebarOrdering.moving(order, dragged: dragged, onto: itemId)")
        && dropDelegate.contains("order = moved"))
check("each of the three carries the ⋮ with Hide",
      notes.contains("accessory: { SectionHideMenu(hide: hide) }")
        && occurrences("accessory: { SectionHideMenu(hide: hide) }", in: chatList) == 2)
check("…and the sidebar hands each its own",
      sidebar.contains("NotesSection(expanded: $notesExpanded,\n                         hide: { sectionToHide = .notes })")
        && sidebar.contains("hide: { sectionToHide = .chats })")
        && sidebar.contains("hide: { sectionToHide = .chatGroups })"))
check("Hide asks first, saying where the switch is, and only then hides",
      sidebar.contains("Text(\"Nothing is deleted. To show it again, turn it on in Settings → Display.\"")
        && body(of: "hideSection(", in: sidebar).contains("config.setDisplay"),
      "— a section hidden by a stray click must not be lost")
check("…from the sidebar itself, which outlives the section it hides",
      sidebar.contains(".alert(hideTitle,"),
      "— an alert hung on the section would go with it")
let display = slice(settings, from: "Text(\"Sidebar\", comment:", to: "Divider().padding(.vertical, 4)")
check("Settings → Display has the three switches",
      display.contains("subToggle(\"Notes\", value: \\.showNotesSection)")
        && display.contains("subToggle(\"Chats\", value: \\.showChatsSection)")
        && display.contains("subToggle(\"Chat groups\", value: \\.showChatGroupsSection)"))
check("the switches are written to the shared display keys",
      configSource.contains("d[\"sidebar_notes\"] = s.showNotesSection")
        && configSource.contains("d[\"sidebar_chats\"] = s.showChatsSection")
        && configSource.contains("d[\"sidebar_chat_groups\"] = s.showChatGroupsSection"))

// The group headers.
let header = body(of: "groupHeaderRow(", in: sec)
check("the header asks the one rule what it carries",
      header.contains("AgentSessionGrouping.headerActions(mode: mode,"))
check("the ⋮ sits between the count and the +",
      precedes("AgentGroupHeaderLabel(label: group.label", "RowEllipsisMenu", in: header)
        && precedes("RowEllipsisMenu", "RowPlusButton(", in: header),
      "— the count is the title line's last element")
check("…and the header has no right-click menu: every action is in the ⋮",
      !header.contains(".contextMenu") && !sec.contains("header.contextMenu"),
      "— one place to look; Rename moved into the ⋮ with the rest")
check("the + still needs a drivable agent",
      header.contains("isReady && actions.plus"))
check("Ungrouped's + reads the shared rule over the sidebar's own order",
      sec.contains("AgentSessionGrouping.latestUngroupedFolder(")
        && sec.contains("sortedItems: sortedListItems"))
check("…and starts a session filed nowhere",
      body(of: "startNewSessionInUngrouped(", in: sec).contains("startNewSession(cwd:")
        && !body(of: "startNewSessionInUngrouped(", in: sec).contains("inGroup:"))
let firstRow = slice(sec, from: "private var firstRow: some View {", to: "\n    }\n")
check("grouped by Custom, the section's first row makes a group…",
      precedes("if groupMode == .custom {", "Text(\"New group\"", in: firstRow)
        && precedes("Text(\"New group\"", "promptForGroup(.create(nil))", in: firstRow))
check("…and every other mode keeps New session",
      precedes("} else {", "Text(\"New session\"", in: firstRow)
        && firstRow.contains("startNewSession()"))
check("an agent with no sessions, grouped by Custom, still draws its groups — Scanning… while the first scan runs",
      sec.contains("if !hasAnyRows && (agents.isScanning || groupMode != .custom) {"),
      "— an empty-state row in their place would leave no + to start a session from")

let menu = body(of: "groupMenuItems(", in: sec)
check("Mark all as read clears every session the rows stand for",
      body(of: "markAllRead(", in: sec)
        .contains("config.clearAgentSessionUnread(members.flatMap(\\.sessionIds))"))
check("…offered only while something there is unread",
      menu.contains(".disabled(!unread)"))
check("Folder and Ungrouped say \"Delete all sessions\"; a named group, \"Delete the group\"",
      menu.contains("Text(\"Delete all sessions\"") && menu.contains("Text(\"Delete the group\""))
check("a named group keeps Rename and the delete that keeps its sessions, as Ungroup",
      menu.contains("promptForGroup(.rename(") && menu.contains("Text(\"Ungroup\""))
let renameEntry = source("SipAI-macOS/SipAI/Resources/Localizable.xcstrings")
    .components(separatedBy: "\"Rename group…\" : {").dropFirst().first?.prefix(200) ?? ""
check("…and no item in it is described to translators as a right-click item",
      !menu.contains("Context menu item") && !renameEntry.isEmpty
        && !renameEntry.contains("Context menu item"),
      "— the header has no right-click menu; the comment is what a translator reads")
let perform = body(of: "deleteGroupSessions(", in: sec)
check("the deletes go through the manager's one delete",
      perform.contains("agents.deleteSessions(")
        && body(of: "deleteSessions(", in: manager).contains("delete(sessions, task: nil)"),
      "— one path stops a running turn first and holds the rows off every rescan")
check("…closing a session that was open",
      perform.contains("appState.openAgentSessionId = nil"))
check("…and Delete the group removes the group with them",
      perform.contains("config.deleteAgentCustomGroup("))
check("Ungroup and Delete keep another agent's same-named group",
      occurrences("keeping: otherAgentsItemKeys", in: sec) == 3,
      "— Ungroup, Delete the group and Rename group each pass it")
check("…and the config cannot be asked without saying so",
      configSource.contains("func deleteAgentCustomGroup(_ name: String,\n                                for agentKey: String,\n                                keeping otherAgentsItems: Set<String>)")
        && configSource.contains("keeping otherAgentsItems: Set<String>) -> Bool"))

// The scheduled task.
check("a scheduled task's menu has Mark all as read, for its runs",
      body(of: "taskMenuItems(", in: sec).contains("markAllRead([.scheduled(task)])")
        && body(of: "taskMenuItems(", in: sec).contains(".disabled(!isUnread(.scheduled(task)))"))

check("Settings → Help answers it, naming where a hidden section comes back",
      slice(settings, from: "FAQ(id: 18,", to: "FAQ(id: 10,")
        .contains("turn it back on in Settings → Display, under Show sections"))

// MARK: - 8. Strings

section("8. Strings")

let catalog = source("SipAI-macOS/SipAI/Resources/Localizable.xcstrings")
let keys = [
    "Hide",
    "Hide “%@” from the sidebar?",
    "Nothing is deleted. To show it again, turn it on in Settings → Display.",
    "Show sections",
    "Agent sections are shown and hidden in Settings → Agent Initialization.",
    "Mark all as read",
    "Delete all sessions",
    "Delete the group",
    "Ungroup",
    "Ungroup “%@”?",
    "Delete all sessions in “%@”?",
    "Delete the group “%@”?",
    "How do I hide a sidebar section, or mark or delete a whole group?",
]
for key in keys {
    let quoted = "\"\(key)\" : {"
    guard let start = catalog.range(of: quoted) else {
        check("catalog holds \(key)", false)
        continue
    }
    let tail = catalog[start.upperBound...].prefix(900)
    check("\(key) — with a zh-Hans value", tail.contains("\"zh-Hans\""),
          "— half the UI comes up English otherwise")
}

// A top-level `defer` does not run on `exit`, so the throwaway config
// goes here.
try? FileManager.default.removeItem(at: harnessDir)

print(failures == 0
      ? "\nAll checks passed."
      : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
