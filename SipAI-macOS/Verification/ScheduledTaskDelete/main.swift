// Deleting a scheduled task: "Delete definition" keeps its runs, "Delete
// all" takes the task and every run with it — and neither can remove
// anything outside the task's own directory.
//
// What this pins, and why each part exists:
//
//  1. The task's directory, and only it. Compiled from the SHIPPING
//     ScheduledTaskCreator.swift, run against a throwaway root. A task
//     whose definition is gone (an ORPHAN: runs, no SKILL.md) takes its
//     name from the marker in its runs' transcripts, and nothing
//     constrains what a transcript says. The directory used to be
//     `root/<name>` as given, so an orphan filed under `../../Desktop`
//     had its "directory" at ~/Desktop, and ⋮ → Delete removed it —
//     measured on a replica, where `removeItem` resolves the `..`.
//     Every file operation on a task now goes through one test: a name
//     that is a plain path component, and a directory that is the
//     root's direct child of that name.
//
//  2. The menu and the two confirmations, by READING the sidebar:
//     Delete definition (and Rename) only where a definition exists;
//     Delete all always; each behind its own alert, saying what goes.
//
//  3. One delete, in order, by READING AgentManager: the rows leave at
//     once and stay off the lists until the files are gone; the
//     definition goes first, so nothing fires the task while its runs
//     stop; a run still going is stopped and waited for BEFORE its files
//     are removed — measured on claude 2.1.283 (section 5), a transcript
//     deleted under a live turn is written again when the stopped
//     process exits, and one deleted after the exit stays gone; a run
//     whose id arrives after the stop is held and cut like the rest, and
//     a file the stop came before is looked up by id.
//
//  4. The strings: every new sentence translated, the retired ones gone.
//
//  5. LIVE, behind SIPAI_TASKDELETE_LIVE=1, token-free: the real claude
//     against a local endpoint that never answers, both orders, to see
//     whether the reason for 3's order still holds. Run it after a
//     Claude Code upgrade.
//
//   ./run.sh [source-root]

import Foundation

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

/// A line with its `//` comment removed — only a `//` outside a string
/// literal — so a rule quoted in prose cannot satisfy a check the code
/// makes.
func stripComment(_ line: Substring) -> Substring {
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

/// The body of `func name(` up to the next member at the same indent.
func body(of name: String, in text: String) -> Substring {
    guard let start = text.range(of: "func " + name) else { return "" }
    let rest = text[start.upperBound...]
    let ends = ["\n    func ", "\n    private func ", "\n    @discardableResult",
                "\n    @ViewBuilder", "\n    private var ", "\n    var ",
                "\n    private static func ", "\n    static func ",
                "\n    nonisolated private static func ",
                "\n    private struct ", "\n    private enum ", "\n    // MARK:"]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return rest[..<(ends.min() ?? rest.endIndex)]
}

/// `first` occurs, then `second` after it, inside `text`.
func precedes(_ first: String, _ second: String, in text: Substring) -> Bool {
    guard let a = text.range(of: first) else { return false }
    return text.range(of: second, range: a.upperBound..<text.endIndex) != nil
}

func occurrences(_ needle: String, in text: Substring) -> Int {
    text.components(separatedBy: needle).count - 1
}

// MARK: - 1. The task's directory, and only it

print("1. the task's directory, and only it (the shipping ScheduledTaskCreator)")

let fm = FileManager.default
let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sipai-taskdelete-\(UUID().uuidString.prefix(8))", isDirectory: true)
let home = sandbox.appendingPathComponent("home", isDirectory: true)
let root = home.appendingPathComponent(".claude/scheduled-tasks", isDirectory: true)
try? fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: sandbox) }

let plain = ["daily-report", "weekly_summary", "Task 2", "报告", "a.b"]
check("a plain name is the root's own child",
      plain.allSatisfy {
          ScheduledTaskCreator.taskDirectory(named: $0, in: root)?.standardizedFileURL.path
              == root.appendingPathComponent($0).standardizedFileURL.path
      })
let escaping = ["..", ".", "", "../..", "../Desktop", "../../Desktop", "x/../../y",
                "a/b", "/etc", "a\u{0}b"]
check("a name that could reach outside it has no directory at all",
      escaping.allSatisfy { ScheduledTaskCreator.taskDirectory(named: $0, in: root) == nil },
      "— \(escaping.filter { ScheduledTaskCreator.taskDirectory(named: $0, in: root) != nil })")
check("a dot-prefixed name is no task's — the scanner lists none",
      [".hidden-task", ".staging", ".DS_Store"].allSatisfy {
          ScheduledTaskCreator.taskDirectory(named: $0, in: root) == nil
      })

// The victims: a folder beside the task root, and one where `../..`
// from the root lands — the home folder's own contents.
func plant(_ url: URL) {
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    try? "keep".write(to: url.appendingPathComponent("important.txt"), atomically: true, encoding: .utf8)
}
let besideRoot = root.deletingLastPathComponent().appendingPathComponent("victim", isDirectory: true)
let inHome = home.appendingPathComponent("Desktop", isDirectory: true)
plant(besideRoot)
plant(inHome)
plant(root.deletingLastPathComponent())      // `..` from the root: ~/.claude itself
for (name, victim) in [("../victim", besideRoot), ("../../Desktop", inHome), ("..", root.deletingLastPathComponent())] {
    let asScanned = root.appendingPathComponent(name, isDirectory: true)
    let removed = ScheduledTaskCreator.removeTaskDirectory(named: name, directory: asScanned, in: root)
    check("an orphan named \"\(name)\" removes nothing — its runs' marker is not a path",
          !removed && fm.fileExists(atPath: victim.appendingPathComponent("important.txt").path)
            && fm.fileExists(atPath: root.path))
}
let own = root.appendingPathComponent("daily-report", isDirectory: true)
plant(own)
// An orphan whose runs say `Daily-Report` beside a live task
// `daily-report`: on the default (case-insensitive) volume its path IS
// the live task's directory.
let caseVariant = root.appendingPathComponent("Daily-Report", isDirectory: true)
check("an orphan spelled like a live task in another case removes nothing",
      !ScheduledTaskCreator.removeTaskDirectory(named: "Daily-Report", directory: caseVariant, in: root)
        && fm.fileExists(atPath: own.appendingPathComponent("important.txt").path))
check("a directory that is not the name's own is refused",
      !ScheduledTaskCreator.removeTaskDirectory(named: "daily-report", directory: besideRoot, in: root)
        && fm.fileExists(atPath: besideRoot.path) && fm.fileExists(atPath: own.path))
check("the task's own directory goes",
      ScheduledTaskCreator.removeTaskDirectory(named: "daily-report", directory: own, in: root)
        && !fm.fileExists(atPath: own.path) && fm.fileExists(atPath: root.path))

let creator = code("SipAI-macOS/SipAI/Models/ScheduledTaskCreator.swift")
let deleteTaskSrc = body(of: "deleteTask(named", in: creator)
check("deleteTask removes a directory only through that test",
      deleteTaskSrc.contains("removeTaskDirectory(named: name, directory: directory)")
        && !deleteTaskSrc.contains("removeItem"))
check("…and so does a rename, before it reads or writes a SKILL.md",
      precedes("taskDirectory(named: name)", "ScheduledTaskDefinition.read(",
               in: body(of: "renameTask(", in: creator)))
check("…and the old-crontab migration, before it reads a SKILL.md",
      precedes("taskDirectory(named: taskName)", "ScheduledTaskDefinition.read(",
               in: body(of: "migrateLegacyCrontabSchedules(", in: creator)))

// MARK: - 2. The menu and the confirmations

print("2. the ⋮ menu and its two confirmations (read from the sidebar)")

let sec = code("SipAI-macOS/SipAI/Views/Sidebar/AgentSessionsSection.swift")
let menu = body(of: "taskMenuItems(", in: sec)
check("Delete definition and Delete all, both destructive, Delete definition first",
      precedes("Text(\"Delete definition\"", "Text(\"Delete all\"", in: menu)
        && occurrences("Button(role: .destructive)", in: menu) == 2
        && !menu.contains("Text(\"Delete\","),
      "— the menu item that only removes the definition must say so")
check("Delete definition (and Rename) only where there is a definition to act on",
      precedes("if task.definition != nil {", "Text(\"Rename\"", in: menu)
        && precedes("Divider()", "if task.definition != nil {", in: menu)
        && precedes("if task.definition != nil {", "deletingTask = task", in: menu[(menu.range(of: "Divider()")?.upperBound ?? menu.startIndex)...]))
/// Where the `{` at `open` is closed.
func closing(_ text: Substring, _ open: String.Index) -> String.Index? {
    var depth = 0
    var i = open
    while i < text.endIndex {
        if text[i] == "{" { depth += 1 }
        if text[i] == "}" { depth -= 1; if depth == 0 { return i } }
        i = text.index(after: i)
    }
    return nil
}
check("Delete all always — an orphan is only its runs, and they can still go",
      {
          guard let all = menu.range(of: "deletingTaskAndRuns = task") else { return false }
          // Every definition gate in the menu has closed before it.
          var from = menu.startIndex
          while let gate = menu.range(of: "if task.definition != nil {", range: from..<menu.endIndex) {
              guard let open = menu[gate].lastIndex(of: "{"),
                    let end = closing(menu, open) else { return false }
              if gate.lowerBound < all.lowerBound && all.lowerBound < end { return false }
              from = gate.upperBound
          }
          return true
      }())
check("each behind its own confirmation, whose button does what the item says",
      sec.contains("presenting: deletingTask\n") && sec.contains("presenting: deletingTaskAndRuns\n")
        && precedes("presenting: deletingTask\n", "deleteTask(task)", in: sec[...])
        && precedes("presenting: deletingTaskAndRuns\n", "deleteTaskAndRuns(task)", in: sec[...])
        && sec.contains("\"Delete this task's definition?\"")
        && sec.contains("\"Delete this task and all its runs?\""))
// Only the first word of a menu item is capitalised — the user's rule for
// this menu, which also runs through the "Add to group" submenu it shares
// with every session row, the section's own Group menu and a custom
// group's header menu, so one action is never spelled two ways.
let groupSubmenu = body(of: "groupSubmenu(", in: sec)
check("menu items capitalise only their first word: Add to group, New group…, Remove from group",
      groupSubmenu.contains("Text(\"Add to group\"") && groupSubmenu.contains("Text(\"New group…\"")
        && groupSubmenu.contains("Text(\"Remove from group\"")
        && sec.contains("Text(\"Rename group…\"") && sec.contains("Text(\"Delete group\"")
        && code("SipAI-macOS/SipAI/Views/Sidebar/ChatListView.swift").contains("Text(\"New group…\"")
        && [sec, code("SipAI-macOS/SipAI/Views/Sidebar/ChatListView.swift")].allSatisfy { text in
            !["Text(\"Add to Group", "Text(\"New Group…", "Text(\"Remove from Group",
              "Text(\"Rename Group", "Text(\"Delete Group", "Text(\"Delete Definition",
              "Text(\"Delete All"].contains { text.contains($0) }
        },
      "— title case beside \"Delete definition\" / \"Delete all\" in the same menu")
let message = body(of: "deleteAllMessage(", in: sec)
check("Delete all says what goes — and that it cannot be undone — with and without a definition",
      message.contains("stops running, its definition is removed, and every run it made is removed")
        && message.contains("and every run it made are removed")
        && occurrences("This cannot be undone.", in: message) == 2
        && message.contains("if task.definition != nil"))
let deleteAll = body(of: "deleteTaskAndRuns(", in: sec)
check("Delete all closes what the pane shows of the task, drops the scheduler's record, then deletes",
      deleteAll.contains("appState.openAgentSessionId = nil")
        && deleteAll.contains("appState.openScheduledTaskName = nil")
        && precedes("scheduler.forget(taskName: task.name)",
                    "agents.deleteScheduledTaskAndRuns(task, startingRun: startingRun)", in: deleteAll))
check("…naming the run the scheduler has in flight BEFORE forgetting it — a run fired a moment ago has no session id yet",
      precedes("let startingRun = scheduler.inFlight[task.name]",
               "scheduler.forget(taskName: task.name)", in: deleteAll))
check("…on the task as the manager holds it NOW, not as the alert took it — a run that started meanwhile goes too",
      precedes("let task = agents.scheduledTasks.first { $0.id == task.id } ?? task",
               "let startingRun = scheduler.inFlight[task.name]", in: deleteAll))

// MARK: - 3. One delete, in order

print("3. one delete, in order (read from AgentManager)")

let mgr = code("SipAI-macOS/SipAI/Models/AgentManager.swift")
let del = body(of: "delete(", in: mgr)
check("a session's Delete and a task's Delete all are the one delete",
      body(of: "deleteSession(", in: mgr).contains("delete([session], task: nil)")
        && body(of: "deleteScheduledTaskAndRuns(", in: mgr).contains("delete(task.sessions, task: task,")
        && body(of: "deleteScheduledTaskAndRuns(", in: mgr).contains("starting: startingRun.flatMap { runners[$0] })"))
check("a run with no session id yet is stopped with the others, and its session goes with theirs",
      precedes("if let starting, !handled.contains(where: { $0 === starting }) {", "starting.cancel()", in: del)
        && del.contains("runners = runners.filter { $0.value !== starting }")
        && precedes("while stopping.contains(where: { $0.status.isRunning })",
                    "guard let id = runner.sessionId", in: del)
        && precedes("doomedFiles.append(SessionFiles(agentKey: runner.agentKey,",
                    "for file in allFiles { Self.removeFiles(of: file) }", in: del))
check("…an id that arrives after the stop re-files nothing, and the session it names is held and cut like the rest",
      precedes("starting.onSessionIdDiscovered = nil", "starting.cancel()", in: del)
        && precedes("self.deletingSessionIds.insert(id)",
                    "for file in allFiles { Self.removeFiles(of: file) }", in: del)
        && precedes("self.liveScheduledRuns.removeValue(forKey: id)",
                    "for file in allFiles { Self.removeFiles(of: file) }", in: del)
        && precedes("self.deletingSessionIds.subtract(ids)",
                    "self.deletingSessionIds.subtract(lateIds)", in: del)
        && precedes("self.deletingSessionIds.subtract(lateIds)", "self.reloadSessions()", in: del),
      "— a live entry retires only against the disk, which a deleted run never reaches")
check("a transcript the stop came before is looked up by id, and a placeholder row's URL names no file",
      body(of: "removeFiles(", in: mgr)
        .contains("?? AgentRunner.locateSessionFile(id: session.sessionId, agentKey: session.agentKey)")
        && del.contains("fileURL: Self.isUnresolvedPlaceholder($0.fileURL) ? nil : $0.fileURL"))
check("the rows leave the lists at once, and are held off them until the files are gone",
      precedes("deletingSessionIds.formUnion(ids)", "Task {", in: del)
        && precedes("deletingTaskNames.insert(task.name)", "Task {", in: del)
        && precedes("sessions.removeAll { ids.contains($0.id) }", "Task {", in: del)
        && precedes("scheduledTasks = Self.leaving(", "Task {", in: del))
let reload = body(of: "reloadSessions(", in: mgr)
check("…a rescan that lands meanwhile leaves them out",
      reload.contains("let deleting = self.deletingSessionIds")
        && reload.contains("Self.leaving(filed.tasks, sessionIds: deleting,")
        && reload.contains("taskNames: self.deletingTaskNames)"))
check("a run still going is stopped, and every runner dropped",
      precedes("if runner.status.isRunning { stopping.append(runner) }", "runner.cancel()", in: del)
        && del.contains("runners.removeValue(forKey: session.id)"))
check("the definition goes first — nothing can fire the task while its runs stop",
      precedes("ScheduledTaskCreator.deleteTask(named: definition.name,",
               "while stopping.contains(where: { $0.status.isRunning })", in: del))
check("a stopped run's files go only once it has ended (bounded wait)",
      precedes("while stopping.contains(where: { $0.status.isRunning }), Date() < deadline",
               "for file in allFiles { Self.removeFiles(of: file) }", in: del)
        && mgr.contains("private static let deletionStopWait: TimeInterval = 6"))
check("the hold is released only after the files are gone, and one rescan follows",
      precedes("for file in allFiles { Self.removeFiles(of: file) }",
               "self.deletingSessionIds.subtract(ids)", in: del)
        && precedes("self.deletingSessionIds.subtract(ids)", "self.reloadSessions()", in: del)
        && occurrences("reloadSessions()", in: del) == 1)
let leaving = body(of: "leaving(", in: mgr)
check("an orphan whose last run went goes with it; a task with a definition stays",
      leaving.contains("if task.definition == nil, runs > 0, task.sessions.isEmpty { continue }"))

// MARK: - 4. The strings

print("4. the strings")

let catalogData = source("SipAI-macOS/SipAI/Resources/Localizable.xcstrings").data(using: .utf8) ?? Data()
let strings = ((try? JSONSerialization.jsonObject(with: catalogData)) as? [String: Any])?["strings"]
    as? [String: Any] ?? [:]
for key in ["Delete definition", "Delete all", "Add to group", "New group…", "Remove from group",
            "Rename group…", "Delete group",
            "Delete this task's definition?", "Delete this task and all its runs?",
            "“%@” stops running, its definition is removed, and every run it made is removed for every app that reads them — SipAI, the CLI, and the desktop app. This cannot be undone.",
            "“%@” and every run it made are removed for every app that reads them — SipAI, the CLI, and the desktop app. This cannot be undone."] {
    let zh = (((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?["zh-Hans"]
        as? [String: Any])?["stringUnit"] as? [String: Any]
    check("\"\(key.prefix(48))\" is in the catalog, translated", zh?["value"] is String)
}
check("the retired sentences left the catalog with their code",
      strings["Delete scheduled task?"] == nil && strings["Open this scheduled task"] == nil
        && ["Add to Group", "New Group…", "Remove from Group", "Rename Group…", "Delete Group"]
            .allSatisfy { strings[$0] == nil })

// MARK: - 5. Live

print("5. live — the real claude, token-free (SIPAI_TASKDELETE_LIVE=1)")
if ProcessInfo.processInfo.environment["SIPAI_TASKDELETE_LIVE"] == "1" {
    let candidates = [NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude",
                      "/usr/local/bin/claude"]
    if let claude = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [sourceRoot + "/SipAI-macOS/Verification/ScheduledTaskDelete/resurrect.py", claude]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        let lines = out.split(separator: "\n").map(String.init)
        for line in lines { print("        \(line)") }
        let after = lines.first { $0.hasPrefix("stop-then-delete:") } ?? ""
        let under = lines.first { $0.hasPrefix("delete-then-stop:") } ?? ""
        check("stopped first and deleted after it ended, the transcript stays gone",
              after.contains("file back: False"), "— \(after)")
        if under.contains("file back: True") {
            print("  NOTE  deleted under a live turn, it comes back when the process exits —")
            print("        the reason the delete waits for a stopped run to end")
        } else {
            print("  NOTE  deleted under a live turn, it no longer comes back (\(under)) —")
            print("        the wait is now only a precaution")
        }
    } else {
        print("  SKIP  no claude installed")
    }
} else {
    print("  SKIP  set SIPAI_TASKDELETE_LIVE=1 to run it")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
