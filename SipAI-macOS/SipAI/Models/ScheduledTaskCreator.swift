// ScheduledTaskCreator.swift
// Creates, edits and deletes scheduled-task definitions under
//   ~/.claude/scheduled-tasks/<name>/SKILL.md
//
// The file format and every field in it live in
// `ScheduledTaskDefinition`; this type is the set of ACTIONS over a task
// directory — make one, rewrite one, rename one, delete one — plus the
// one-time migration off the old crontab-based scheduling.
//
// The schedule is frontmatter (`schedule:`), and `ScheduledTaskScheduler`
// fires tasks from inside the app. See that file's header for why cron
// cannot do the job on macOS.

import Foundation

enum ScheduledTaskCreator {

    struct Request {
        var rawName: String
        var description: String
        /// 5-field cron expression, already validated by the caller's UI.
        /// Empty means "no schedule" — the task exists and can be run by
        /// hand, but nothing fires it.
        var cron: String
        var prompt: String
        var cwd: URL
        /// Permission mode for the unattended run; the popover
        /// defaults it to bypassPermissions, since nobody is there to
        /// answer an approval.
        var mode: String
        var model: String?
        var effort: String?
        /// Which CLI the task runs under. Written to the frontmatter,
        /// and read back by `ScheduledTaskScheduler.fire` — a task
        /// created from a codex session must not fire under claude.
        var agent: String = "claude_code"
    }

    struct Success {
        let name: String
    }

    enum CreateError: LocalizedError {
        case invalidName
        case alreadyExists(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidName:
                return String(localized: "Task name is empty after removing unsupported characters.",
                              comment: "Scheduled-task error: name reduces to nothing")
            case .alreadyExists(let name):
                return String(localized: "A task named “\(name)” already exists.",
                              comment: "Scheduled-task error: duplicate name")
            case .writeFailed(let detail):
                return String(localized: "Could not create task: \(detail)",
                              comment: "Scheduled-task error: filesystem failure")
            }
        }
    }

    static var taskRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/scheduled-tasks", isDirectory: true)
    }

    /// Slug rule: lowercase, and every run of anything outside
    /// [a-zA-Z0-9_-] becomes a "-".
    static func slugify(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out = ""
        for ch in lowered {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-") {
                out.append(ch)
            } else {
                out.append("-")
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Create

    static func create(_ r: Request) throws -> Success {
        let name = slugify(r.rawName)
        guard !name.isEmpty else { throw CreateError.invalidName }

        let fm = FileManager.default
        let taskDir = taskRoot.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: taskDir.path) {
            throw CreateError.alreadyExists(name)
        }

        let desc = ScheduledTaskDefinition.frontmatterSafe(r.description)
        var def = ScheduledTaskDefinition(name: name,
                                          description: desc.isEmpty ? name : desc)
        def.scheduleExpression = r.cron
        def.workingDirectory = r.cwd
        def.mode = r.mode
        def.model = r.model
        def.effort = r.effort
        def.agent = r.agent
        def.prompt = r.prompt

        do {
            try fm.createDirectory(at: taskDir, withIntermediateDirectories: true)
        } catch {
            throw CreateError.writeFailed(error.localizedDescription)
        }
        guard def.write(to: taskDir.appendingPathComponent("SKILL.md")) else {
            throw CreateError.writeFailed(
                String(localized: "The task file could not be written.",
                       comment: "Scheduled-task error: SKILL.md write failed"))
        }
        return Success(name: name)
    }

    // MARK: - Edit

    /// Persist an edited definition. This is the whole "revise, and it
    /// applies to every upcoming run" contract: the scheduler reads the
    /// definition fresh from disk on each tick, so a saved change is
    /// live for the next fire with nothing to reload or restart.
    ///
    /// The in-flight run, if any, is deliberately untouched — it is
    /// already executing the old prompt in a subprocess, and rewriting
    /// the file underneath it would change nothing about what it does.
    @discardableResult
    static func update(_ def: ScheduledTaskDefinition, skillFile: URL) -> Bool {
        def.write(to: skillFile)
    }

    /// Rewrite the `description:` line only. The description is the
    /// task's display name everywhere it appears, so this IS the
    /// rename — the directory name is the task's identity and never
    /// changes.
    @discardableResult
    static func renameTask(skillFile: URL, description: String) -> Bool {
        let name = skillFile.deletingLastPathComponent().lastPathComponent
        guard var def = ScheduledTaskDefinition.read(name: name, skillFile: skillFile)
        else { return false }
        def.description = ScheduledTaskDefinition.frontmatterSafe(description)
        return def.write(to: skillFile)
    }

    // MARK: - Delete

    /// Remove a task: its definition directory, plus any leftover
    /// crontab entry from before in-app scheduling. Run sessions are
    /// normal files under ~/.claude/projects and deliberately stay.
    static func deleteTask(named name: String, directory: URL) {
        try? FileManager.default.removeItem(at: directory)
        removeCrontabEntry(taskName: name)
    }

    // MARK: - Legacy crontab migration

    private static let cronTagPrefix = "# sipai:task:"
    private static let cronDisabledPrefix = "# sipai:disabled "

    /// One-shot migration off crontab-based scheduling.
    ///
    /// Tagged crontab entries (`# sipai:task:<name>` + a job line) are
    /// read here so the expression is preserved into the task's own
    /// SKILL.md, then REMOVED — leaving them would mean two schedulers
    /// firing the same task, and the cron half would fail anyway (cron
    /// has no Full Disk Access, so it cannot read a project under
    /// ~/Desktop).
    ///
    /// A commented-out entry (`# sipai:disabled …`, how a paused task
    /// is spelled in a crontab) migrates as `enabled: false`, so a
    /// paused task does not come back armed.
    ///
    /// Returns the names of tasks whose schedule was recovered. Safe to
    /// call repeatedly: with no tagged entries left it does nothing.
    @discardableResult
    static func migrateLegacyCrontabSchedules() -> [String] {
        let lines = readCrontab()
        guard lines.contains(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(cronTagPrefix)
        }) else { return [] }

        var kept: [String] = []
        var migrated: [String] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(cronTagPrefix) else {
                kept.append(lines[i])
                i += 1
                continue
            }
            let taskName = String(trimmed.dropFirst(cronTagPrefix.count))
                .trimmingCharacters(in: .whitespaces)
            var job = i + 1 < lines.count
                ? lines[i + 1].trimmingCharacters(in: .whitespaces) : ""
            i += (i + 1 < lines.count) ? 2 : 1

            var enabled = true
            let disabledMarker = cronDisabledPrefix.trimmingCharacters(in: .whitespaces)
            if job.hasPrefix(disabledMarker) {
                enabled = false
                job = String(job.dropFirst(disabledMarker.count))
                    .trimmingCharacters(in: .whitespaces)
            }
            let fields = job.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 5, !taskName.isEmpty else { continue }
            let expression = fields.prefix(5).joined(separator: " ")

            let skill = taskRoot.appendingPathComponent(taskName, isDirectory: true)
                .appendingPathComponent("SKILL.md")
            guard var def = ScheduledTaskDefinition.read(name: taskName,
                                                         skillFile: skill)
            else { continue }
            // Never overwrite a schedule the user has already set in the
            // file — the frontmatter is the newer source of truth.
            guard def.scheduleExpression
                .trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            def.scheduleExpression = expression
            if !enabled { def.enabled = false }
            if def.write(to: skill) { migrated.append(taskName) }
        }
        _ = writeCrontab(kept)
        return migrated
    }

    /// Drop the `# sipai:task:<name>` tag line and the job line after it.
    private static func removeCrontabEntry(taskName: String) {
        let tag = "\(cronTagPrefix)\(taskName)"
        let lines = readCrontab()
        guard lines.contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == tag
        }) else { return }
        var out: [String] = []
        var i = 0
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == tag {
                i += (i + 1 < lines.count) ? 2 : 1
                continue
            }
            out.append(lines[i])
            i += 1
        }
        _ = writeCrontab(out)
    }

    /// Drop EVERY `# sipai:task:<name>` tag line and the job line after
    /// it, whatever the task was called. The factory reset's half of the
    /// crontab cleanup.
    ///
    /// One read and one write for the lot, rather than
    /// `removeCrontabEntry` per task: that would be two subprocesses
    /// each, on the main actor, in the middle of a reset. It also
    /// catches entries whose task directory is ALREADY gone — a stale
    /// tag still firing for a task that no longer exists is exactly the
    /// leftover a reset is supposed to end.
    static func removeAllCrontabEntries() {
        let lines = readCrontab()
        guard lines.contains(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(cronTagPrefix)
        }) else { return }
        var out: [String] = []
        var i = 0
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces)
                .hasPrefix(cronTagPrefix) {
                i += (i + 1 < lines.count) ? 2 : 1
                continue
            }
            out.append(lines[i])
            i += 1
        }
        _ = writeCrontab(out)
    }

    // MARK: - crontab I/O

    private static func readCrontab() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/crontab")
        p.arguments = ["-l"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()  // silence "no crontab for user"
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n")
    }

    @discardableResult
    private static func writeCrontab(_ lines: [String]) -> Bool {
        // An all-blank result means the crontab is now empty. Piping an
        // empty file to `crontab -` is how you say that; `crontab -r`
        // would be the same outcome by a more destructive route.
        var text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/crontab")
        p.arguments = ["-"]
        let inPipe = Pipe()
        p.standardInput = inPipe
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        inPipe.fileHandleForWriting.write(Data(text.utf8))
        try? inPipe.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
