// SkillOps.swift
// The file side of Settings → Agent Skills: give a skill to an agent, take it
// away, move one into SipAI's library, create, import, edit and delete.
//
// Every write is planned first (`SkillSharePlan`, a value the UI can
// describe before anything moves) and then carried out step by step with
// the checks a step needs at that moment. SipAI writes only inside its
// library and the agents' own skills folders; it removes an entry only
// after `lstat` proves it is a link, and it never touches a plugin's,
// the agents' built-in, or an organisation's skills.
//
// Foundation only, so the headless harness compiles it alone.

import Foundation

enum SkillOpError: Error, Equatable {
    case invalidName(String)
    /// Something already sits where the step would write.
    case exists(String)
    case readOnly
    case notALink(String)
    case notASkill(String)
    /// The file changed on disk after it was read for editing.
    case changedOnDisk
    /// The file changed on disk after a share or a fix was worked out.
    case changedSinceChecked
    case unsupportedYAML
    /// A folder a step would write in cannot be written in.
    case notWritable(String)
    case io(String)
}

extension SkillOpError {
    /// The sentence the pane shows for a failed operation.
    var sentence: String {
        switch self {
        case .invalidName(let name):
            return String(localized: "“\(name)” can’t be a skill name. Use lowercase letters, digits and single hyphens.",
                          comment: "Skills: the name rule; placeholder is the refused name")
        case .exists(let path):
            return String(localized: "Something is already at \((path as NSString).abbreviatingWithTildeInPath).",
                          comment: "Skills: a write found its place taken; placeholder is a path")
        case .readOnly:
            return String(localized: "SipAI doesn’t change this skill’s files.",
                          comment: "Skills: a write refused for a skill the agent manages itself")
        case .notALink(let path):
            return String(localized: "\((path as NSString).abbreviatingWithTildeInPath) is not a link, so SipAI left it alone.",
                          comment: "Skills: an unlink refused because the entry is a real folder; placeholder is a path")
        case .notASkill(let path):
            return String(localized: "There is no skill at \((path as NSString).abbreviatingWithTildeInPath).",
                          comment: "Skills: a folder without SKILL.md; placeholder is a path")
        case .changedOnDisk:
            return String(localized: "The skill changed on disk while you were editing it. Close and open it again.",
                          comment: "Skills: an edit refused because the file changed meanwhile")
        case .changedSinceChecked:
            return String(localized: "The skill changed on disk in the meantime, so SipAI left it alone. Try again.",
                          comment: "Skills: a share or a fix refused because the skill's file changed after it was checked")
        case .unsupportedYAML:
            return String(localized: "This skill’s agents/openai.yaml is in a form SipAI doesn’t edit.",
                          comment: "Skills: the codex policy file could not be edited safely")
        case .notWritable(let path):
            return String(localized: "SipAI can’t write in \((path as NSString).abbreviatingWithTildeInPath).",
                          comment: "Skills: a share, delete or new skill refused because a folder it must write in is read-only; placeholder is a path")
        case .io(let message):
            return message
        }
    }
}

// MARK: - Planning

/// One step of a plan.
enum SkillStep: Equatable {
    /// Put a link to `target` at `at`.
    case link(at: String, target: String)
    /// Remove the link at `at`.
    case unlink(at: String)
    /// Point the link at `at` to `target` instead.
    case repoint(at: String, target: String)
    /// Move a real skill folder.
    case move(from: String, to: String)
    /// Move a real skill folder to the Trash.
    case trash(String)
}

/// What giving or taking a skill would do, before it is done.
struct SkillSharePlan: Equatable {
    var steps: [SkillStep] = []
    /// The skill's files move (into the library). A delete says so before
    /// it is confirmed; a share is one click, and Help says it once.
    var movesFiles: Bool {
        steps.contains { if case .move = $0 { return true }; return false }
    }
    /// The last agent is being removed: the caller chooses between
    /// keeping the files in the library and moving them to the Trash.
    var needsKeepOrTrash = false
    /// The agents that read this skill from the very same folder as the
    /// one it is taken from — two agents' skills folders that are one
    /// folder on disk (one linked to the other). Nothing can take the
    /// skill from one of them and leave it with the other, so the plan
    /// holds no steps and the caller says why.
    var blockedBy: [String] = []
    /// Taking a skill away: the agents that still have it once the plan
    /// has run — what the confirmation names.
    var keeps: [String] = []
}

/// Giving a skill to an agent, worked out before anything is written:
/// the links and moves (`plan`), and what the skill's files need first
/// (`check`).
struct SkillShareReview: Equatable {
    let plan: SkillSharePlan
    let check: SkillShareCheck
}

enum SkillPlanner {
    /// Whether `row` is still what the folders hold: read again now, the
    /// row of that id has the same home, and the same agents through the
    /// same entries. A plan is made from the row the pane read EARLIER —
    /// before the user read a confirmation, before another write, before
    /// anything done in a terminal — and made from one that has changed
    /// since it bins a folder an agent was given meanwhile, or links to
    /// one that is gone.
    static func isCurrent(_ row: SkillRow, env: SkillEnvironment, folder: URL?) -> Bool {
        let roots = SkillRoots.scanRoots(env: env, folder: folder)
        let found = SkillScan.read(roots: roots)
        let now = SkillGrouping.rows(entries: SkillScan.entries(from: found), library: found, roots: roots)
        guard let fresh = now.first(where: { $0.id == row.id }) else { return false }
        func shape(_ r: SkillRow) -> [String] {
            ["\(r.home)", r.realPath ?? ""] + SkillAgent.all.map { agent in
                r.entries[agent].map { "\(agent)|\($0.entryPath)|\($0.isLink)|\($0.realPath ?? "")" } ?? agent
            }
        }
        return shape(fresh) == shape(row)
    }

    /// The directory name a skill's links and library copy use: the
    /// real folder's own name.
    static func dirName(of row: SkillRow) -> String? {
        guard let real = row.realPath else { return nil }
        return (real as NSString).lastPathComponent
    }

    /// Give `agent` the skill (`include`) or take it away.
    ///
    /// Giving: a link in the agent's own folder. A skill whose real
    /// files sit in another agent's folder or in the common folder moves
    /// into the library first, leaving a link where it was, so whoever
    /// had it keeps it.
    ///
    /// Taking away: an agent that has the skill through a link loses the
    /// link. An agent that holds the real files hands them to the
    /// library when anyone else still has the skill. When nobody does —
    /// the agent held the files, or held the last link to a skill in
    /// the library — `needsKeepOrTrash` asks the caller. A skill in the
    /// common folder is moved out of it so the other of Codex and Kimi
    /// can keep it.
    ///
    /// `present`: the agents that are on this Mac. The other reader of
    /// the common folder is given a link of its own only when it is one
    /// of them: for a tool that is not installed SipAI makes no folder
    /// and no link, and the agent the skill is taken from is its last.
    static func plan(row: SkillRow, agent: String, include: Bool,
                     env: SkillEnvironment, projectRoot: URL?,
                     keepWhenLast: Bool = true,
                     present: Set<String> = Set(SkillAgent.all)) -> SkillSharePlan? {
        // A broken link can only be taken away.
        if !row.isReadOnly, row.realPath == nil {
            guard !include, let entry = row.entries[agent], entry.isLink else { return nil }
            return SkillSharePlan(steps: [.unlink(at: entry.entryPath)])
        }
        guard !row.isReadOnly, let real = row.realPath, let dir = dirName(of: row) else {
            return nil
        }
        let scope = row.scope
        func ownLink(_ a: String) -> String? {
            SkillRoots.ownFolder(agent: a, scope: scope, env: env, projectRoot: projectRoot)?
                .appendingPathComponent(dir).path
        }
        let libraryDest = SkillRoots.library(scope: scope, env: env, projectRoot: projectRoot)
            .appendingPathComponent(dir).path
        var plan = SkillSharePlan()

        if include {
            guard row.entries[agent] == nil else { return plan }
            // No plan gives a skill to an agent with no folder of its own.
            guard let newLink = ownLink(agent) else { return nil }
            switch row.home {
            case .library, .elsewhere:
                plan.steps.append(.link(at: newLink, target: real))
            case .agentFolder, .common:
                // Into the library, a link left behind, every other link
                // pointed at the new place, then the new agent's link.
                plan.steps.append(.move(from: real, to: libraryDest))
                plan.steps.append(.link(at: real, target: libraryDest))
                for (other, entry) in row.entries where other != agent && entry.isLink {
                    if !plan.steps.contains(.repoint(at: entry.entryPath, target: libraryDest)) {
                        plan.steps.append(.repoint(at: entry.entryPath, target: libraryDest))
                    }
                }
                plan.steps.append(.link(at: newLink, target: libraryDest))
            case .readOnly:
                return nil
            }
            return plan
        }

        guard let entry = row.entries[agent] else { return plan }
        // Who else has it, and through what.
        let commonReaders = [SkillAgent.codex, SkillAgent.kimi]
        let viaCommon = entry.rootKind == .common
        // Whoever reads this very entry with it: the other of the two
        // the common folder serves. It keeps the skill through a link of
        // its own — if it is on this Mac.
        let sharers = viaCommon ? commonReaders.filter { $0 != agent && row.entries[$0]?.entryPath == entry.entryPath } : []
        let coReaders = sharers.filter(present.contains)
        let others = row.agents.filter { $0 != agent && !sharers.contains($0) }
        plan.keeps = others + coReaders
        // An agent that reaches this SAME entry by another path — its
        // skills folder is this one, linked. The common folder's two
        // readers can each be given a folder of their own; these cannot:
        // their own folder is the one the skill would be taken out of.
        // Unlinked or moved, the skill would leave both, under a
        // sentence saying the other keeps it.
        let here = SkillFileOps.canonicalPath(entry.entryPath)
        let twins = others.filter { other in
            row.entries[other].map { SkillFileOps.canonicalPath($0.entryPath) == here } == true
        }
        if !twins.isEmpty {
            plan.blockedBy = twins
            return plan
        }

        if entry.isLink {
            // Another agent's link whose own text points at THIS link has
            // the skill through it — SipAI leaves such a link behind when
            // it moves a skill out of an agent's folder. Pointed at the
            // real folder first, or it is left pointing at nothing under
            // a sentence saying its agent keeps the skill.
            for other in others {
                guard let through = row.entries[other], through.isLink,
                      SkillFileOps.canonicalPath(through.entryPath) != here,
                      SkillFileOps.linkTarget(of: through.entryPath).map(SkillFileOps.canonicalPath) == here,
                      !plan.steps.contains(.repoint(at: through.entryPath, target: real)) else { continue }
                plan.steps.append(.repoint(at: through.entryPath, target: real))
            }
            plan.steps.append(.unlink(at: entry.entryPath))
            // A link in the common folder served both Codex and Kimi.
            for co in coReaders {
                if let link = ownLink(co) { plan.steps.append(.link(at: link, target: real)) }
            }
            // The last link to a skill in the library: no agent has it
            // any more, and whether its files stay there unused is the
            // caller's to ask. A link to a folder SipAI does not manage
            // asks nothing — that folder is never SipAI's to bin.
            if others.isEmpty, coReaders.isEmpty, row.home == .library {
                plan.needsKeepOrTrash = true
                if !keepWhenLast { plan.steps.append(.trash(real)) }
            }
            return plan
        }

        // The agent holds the real files — in a folder SipAI manages, or
        // they are not SipAI's to move or bin.
        guard row.isManaged else { return nil }
        let keepers = others + coReaders
        if keepers.isEmpty {
            plan.needsKeepOrTrash = true
            plan.steps.append(keepWhenLast ? .move(from: real, to: libraryDest) : .trash(real))
            return plan
        }
        plan.steps.append(.move(from: real, to: libraryDest))
        for other in others {
            guard let e = row.entries[other], e.isLink else { continue }
            if !plan.steps.contains(.repoint(at: e.entryPath, target: libraryDest)) {
                plan.steps.append(.repoint(at: e.entryPath, target: libraryDest))
            }
        }
        for co in coReaders {
            if let link = ownLink(co) { plan.steps.append(.link(at: link, target: libraryDest)) }
        }
        return plan
    }

    /// Delete: the real files to the Trash, and every link to them gone.
    /// A skill whose real folder sits outside the library and the
    /// agents' folders keeps that folder — it is the user's, kept
    /// somewhere SipAI does not manage — and loses only its links.
    static func deletePlan(row: SkillRow) -> SkillSharePlan? {
        guard !row.isReadOnly else { return nil }
        var plan = SkillSharePlan()
        var seen = Set<String>()
        guard let real = row.realPath else {
            // A broken link: no files left, only the links to them.
            for entry in row.entries.values where entry.isLink {
                if seen.insert(entry.entryPath).inserted {
                    plan.steps.append(.unlink(at: entry.entryPath))
                }
            }
            return plan.steps.isEmpty ? nil : plan
        }
        for entry in row.entries.values where entry.isLink && entry.realPath == real {
            if seen.insert(entry.entryPath).inserted {
                plan.steps.append(.unlink(at: entry.entryPath))
            }
        }
        if row.home != .elsewhere { plan.steps.append(.trash(real)) }
        // Nothing to unlink and nothing SipAI may bin: there is no
        // delete to offer, rather than one that does nothing.
        return plan.steps.isEmpty ? nil : plan
    }
}

// MARK: - Carrying a plan out

struct SkillFileOps {
    var fm: FileManager = .default
    /// Folders a step may write inside: the library and the agents' own
    /// folders, plus the common folder for moving a skill OUT of it.
    var writableRoots: [String]

    init(env: SkillEnvironment, projectRoot: URL?, fm: FileManager = .default) {
        self.fm = fm
        var roots: [URL] = [SkillRoots.library(scope: .global, env: env, projectRoot: nil),
                            SkillRoots.common(scope: .global, env: env, projectRoot: nil)]
        roots += SkillAgent.all.compactMap {
            SkillRoots.ownFolder(agent: $0, scope: .global, env: env, projectRoot: nil)
        }
        if let projectRoot {
            roots.append(SkillRoots.library(scope: .folder, env: env, projectRoot: projectRoot))
            roots.append(SkillRoots.common(scope: .folder, env: env, projectRoot: projectRoot))
            roots += SkillAgent.all.compactMap {
                SkillRoots.ownFolder(agent: $0, scope: .folder, env: env, projectRoot: projectRoot)
            }
        }
        self.writableRoots = roots.map { Self.canonicalDir($0.path) }
    }

    /// A folder's canonical spelling, resolving the parts that exist.
    static func canonicalDir(_ path: String) -> String {
        if let r = SkillScan.realPath(path) { return r }
        // Resolve the deepest existing ancestor and append the rest.
        var head = path
        var tail: [String] = []
        while !head.isEmpty, head != "/" {
            if let r = SkillScan.realPath(head) {
                return ([r] + tail.reversed()).joined(separator: "/")
            }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
        return path
    }

    /// Whether `path` is a direct child of a writable root — the only
    /// place a step may create or remove an entry.
    func isWritable(_ path: String) -> Bool {
        let parent = Self.canonicalDir((path as NSString).deletingLastPathComponent)
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, !name.hasPrefix("."), name != "..", !name.contains("/") else { return false }
        return writableRoots.contains(parent)
    }

    func lstatIsLink(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// Where a link's own text points, one step — a relative one read
    /// from the folder it is in. Nil for anything that is not a link.
    static func linkTarget(of path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(path, &buffer, Int(PATH_MAX))
        guard n > 0 else { return nil }
        let text = String(cString: buffer)
        if text.hasPrefix("/") { return (text as NSString).standardizingPath }
        let parent = (path as NSString).deletingLastPathComponent
        return ((parent as NSString).appendingPathComponent(text) as NSString).standardizingPath
    }

    /// The folder a step would write in is one it CAN write in: its
    /// deepest part that exists is a folder, and writable. Checked for
    /// every step before the first runs — a share whose last link could
    /// not be made had already moved the skill and changed its file.
    private func checkWritable(_ folder: String) throws {
        var dir = folder
        while !dir.isEmpty, dir != "/", !exists(dir) { dir = (dir as NSString).deletingLastPathComponent }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue, access(dir, W_OK) == 0 else {
            throw SkillOpError.notWritable(folder)
        }
    }

    /// A link's text: relative when both ends sit under one project root
    /// (so a project that moves, or is cloned, keeps working), absolute
    /// otherwise.
    static func linkText(at link: String, target: String, projectRoot: String?) -> String {
        guard let root = projectRoot,
              link.hasPrefix(root + "/"), target.hasPrefix(root + "/") else { return target }
        let from = ((link as NSString).deletingLastPathComponent as NSString).pathComponents
        let to = (target as NSString).pathComponents
        var common = 0
        while common < from.count, common < to.count, from[common] == to[common] { common += 1 }
        let ups = Array(repeating: "..", count: from.count - common)
        return (ups + to[common...]).joined(separator: "/")
    }

    /// Every check a plan's steps will make, made for ALL of them before
    /// the first one runs. A plan is several steps and nothing undoes
    /// one: checked only as it is reached, a link whose place is taken
    /// refuses a share whose move has already been made — the skill's
    /// files in the library, the agent that asked for it without it.
    func preflight(_ plan: SkillSharePlan) throws {
        // What the steps before this one will have emptied and filled.
        var vacated = Set<String>()
        var taken = Set<String>()
        func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
        for step in plan.steps {
            switch step {
            case .link(let at, _):
                guard isWritable(at) else { throw SkillOpError.readOnly }
                guard !taken.contains(at), !exists(at) || vacated.contains(at) else {
                    throw SkillOpError.exists(at)
                }
                try checkWritable(parent(at))
                taken.insert(at)
            case .unlink(let at):
                guard lstatIsLink(at) else { throw SkillOpError.notALink(at) }
                guard isWritable(at) else { throw SkillOpError.readOnly }
                try checkWritable(parent(at))
                vacated.insert(at)
            case .repoint(let at, _):
                guard lstatIsLink(at) else { throw SkillOpError.notALink(at) }
                guard isWritable(at) else { throw SkillOpError.readOnly }
                try checkWritable(parent(at))
            case .move(let from, let to):
                guard isWritable(to), isWritable(from) else { throw SkillOpError.readOnly }
                guard !taken.contains(to), !exists(to) || vacated.contains(to) else {
                    throw SkillOpError.exists(to)
                }
                guard !lstatIsLink(from), exists(from) else { throw SkillOpError.notASkill(from) }
                try checkWritable(parent(from))
                try checkWritable(parent(to))
                vacated.insert(from)
                taken.insert(to)
            case .trash(let path):
                guard isWritable(path) else { throw SkillOpError.readOnly }
                guard !lstatIsLink(path), exists(path) else { throw SkillOpError.notASkill(path) }
                try checkWritable(parent(path))
                vacated.insert(path)
            }
        }
    }

    func run(_ plan: SkillSharePlan, projectRoot: URL?) throws {
        try preflight(plan)
        let root = projectRoot.map { Self.canonicalDir($0.path) }
        for step in plan.steps {
            switch step {
            case .link(let at, let target):
                guard isWritable(at) else { throw SkillOpError.readOnly }
                guard !exists(at) else { throw SkillOpError.exists(at) }
                try createParent(of: at)
                let text = Self.linkText(at: Self.canonicalPath(at),
                                         target: Self.canonicalPath(target), projectRoot: root)
                guard symlink(text, at) == 0 else { throw SkillOpError.io(String(cString: strerror(errno))) }
            case .unlink(let at):
                guard lstatIsLink(at) else { throw SkillOpError.notALink(at) }
                guard isWritable(at) else { throw SkillOpError.readOnly }
                guard unlink(at) == 0 else { throw SkillOpError.io(String(cString: strerror(errno))) }
            case .repoint(let at, let target):
                guard lstatIsLink(at) else { throw SkillOpError.notALink(at) }
                guard isWritable(at) else { throw SkillOpError.readOnly }
                let dir = (at as NSString).deletingLastPathComponent
                let tmp = (dir as NSString).appendingPathComponent(
                    ".\((at as NSString).lastPathComponent).sipai-link-\(UUID().uuidString.prefix(8))")
                let text = Self.linkText(at: Self.canonicalPath(at),
                                         target: Self.canonicalPath(target), projectRoot: root)
                guard symlink(text, tmp) == 0 else { throw SkillOpError.io(String(cString: strerror(errno))) }
                guard rename(tmp, at) == 0 else {
                    let e = errno
                    _ = unlink(tmp)
                    throw SkillOpError.io(String(cString: strerror(e)))
                }
            case .move(let from, let to):
                guard isWritable(to), isWritable(from) else { throw SkillOpError.readOnly }
                guard !exists(to) else { throw SkillOpError.exists(to) }
                guard !lstatIsLink(from), exists(from) else { throw SkillOpError.notASkill(from) }
                try createParent(of: to)
                do { try fm.moveItem(atPath: from, toPath: to) }
                catch { throw SkillOpError.io(error.localizedDescription) }
            case .trash(let path):
                guard isWritable(path) else { throw SkillOpError.readOnly }
                guard !lstatIsLink(path), exists(path) else { throw SkillOpError.notASkill(path) }
                do { try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
                catch { throw SkillOpError.io(error.localizedDescription) }
            }
        }
    }

    /// A link location spelled through its canonical parent.
    static func canonicalPath(_ path: String) -> String {
        let parent = canonicalDir((path as NSString).deletingLastPathComponent)
        return (parent as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    private func createParent(of path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        do { try fm.createDirectory(atPath: parent, withIntermediateDirectories: true) }
        catch { throw SkillOpError.io(error.localizedDescription) }
    }

    // MARK: Create, import, edit

    /// Write a new skill into the library and link it into `agents`.
    /// Built in a dot-prefixed staging folder (which no agent and no
    /// scan reads) and renamed into place only when complete.
    func create(name: String, description: String, body: String, onlyWhenCalled: Bool,
                scope: SkillScope, agents: [String], env: SkillEnvironment,
                projectRoot: URL?) throws -> String {
        guard SkillName.isValid(name) else { throw SkillOpError.invalidName(name) }
        let library = SkillRoots.library(scope: scope, env: env, projectRoot: projectRoot)
        let dest = library.appendingPathComponent(name).path
        try checkFree(name: name, dest: dest, scope: scope, agents: agents, env: env, projectRoot: projectRoot)
        let staging = library.appendingPathComponent(".\(name).sipai-new-\(UUID().uuidString.prefix(8))")
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let text = SkillFileEdit.newSkill(name: name, description: description, body: body,
                                              onlyWhenCalled: onlyWhenCalled)
            try Data(text.utf8).write(to: staging.appendingPathComponent("SKILL.md"))
            if onlyWhenCalled, let yaml = try SkillFileEdit.codexPolicy(nil, onlyWhenCalled: true) {
                let agentsDir = staging.appendingPathComponent("agents", isDirectory: true)
                try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
                try Data(yaml.utf8).write(to: agentsDir.appendingPathComponent("openai.yaml"))
            }
            try fm.moveItem(at: staging, to: URL(fileURLWithPath: dest))
        } catch let error as SkillOpError {
            try? fm.removeItem(at: staging)
            throw error
        } catch {
            try? fm.removeItem(at: staging)
            throw SkillOpError.io(error.localizedDescription)
        }
        try linkAll(dest: dest, dir: name, scope: scope, agents: agents, env: env, projectRoot: projectRoot)
        return dest
    }

    /// Copy a skill folder into the library and link it into `agents`.
    /// `source` is a folder holding SKILL.md. The copy keeps links inside
    /// the folder as links, never following one out of it.
    func importFolder(_ source: URL, name: String, scope: SkillScope, agents: [String],
                      env: SkillEnvironment, projectRoot: URL?) throws -> String {
        guard SkillName.isValid(name) else { throw SkillOpError.invalidName(name) }
        // The folder itself, never a link to it: a link is copied as a
        // link, and the library would then hold a pointer at the folder
        // the user chose instead of a copy of it.
        let source = source.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else {
            throw SkillOpError.notASkill(source.path)
        }
        let library = SkillRoots.library(scope: scope, env: env, projectRoot: projectRoot)
        let dest = library.appendingPathComponent(name).path
        try checkFree(name: name, dest: dest, scope: scope, agents: agents, env: env, projectRoot: projectRoot)
        let staging = library.appendingPathComponent(".\(name).sipai-new-\(UUID().uuidString.prefix(8))")
        do {
            try fm.createDirectory(at: library, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: staging)
            // The copy is called what the user called it: agents name a
            // skill by its SKILL.md, so one left with its source's name
            // is that skill again to them, under two folders.
            let file = staging.appendingPathComponent("SKILL.md")
            if !lstatIsLink(file.path), let text = Self.readText(file.path) {
                let named = SkillFileEdit.renamed(text, to: name)
                if named != text { try Data(named.utf8).write(to: file, options: .atomic) }
            }
            try fm.moveItem(at: staging, to: URL(fileURLWithPath: dest))
        } catch {
            try? fm.removeItem(at: staging)
            throw SkillOpError.io(error.localizedDescription)
        }
        try linkAll(dest: dest, dir: name, scope: scope, agents: agents, env: env, projectRoot: projectRoot)
        return dest
    }

    private func checkFree(name: String, dest: String, scope: SkillScope, agents: [String],
                           env: SkillEnvironment, projectRoot: URL?) throws {
        guard !exists(dest) else { throw SkillOpError.exists(dest) }
        for agent in agents {
            // An agent with no folder of its own here is given no link
            // (`linkAll`), so nothing of its can be in the way.
            let own = SkillRoots.ownFolder(agent: agent, scope: scope, env: env, projectRoot: projectRoot)
            guard let own else { continue }
            let at = own.appendingPathComponent(name).path
            guard !exists(at) else { throw SkillOpError.exists(at) }
        }
    }

    private func linkAll(dest: String, dir: String, scope: SkillScope, agents: [String],
                         env: SkillEnvironment, projectRoot: URL?) throws {
        var plan = SkillSharePlan()
        // Two agents whose skills folders are one folder on disk take
        // one link between them: the second would find its place taken,
        // and the agents after it would get none.
        var places = Set<String>()
        for agent in agents {
            // No link for an agent with no folder of its own: in another
            // agent's folder it would give the skill to that agent.
            let own = SkillRoots.ownFolder(agent: agent, scope: scope, env: env, projectRoot: projectRoot)
            guard let own else { continue }
            let at = own.appendingPathComponent(dir).path
            guard places.insert(Self.canonicalPath(at)).inserted else { continue }
            plan.steps.append(.link(at: at, target: SkillScan.realPath(dest) ?? dest))
        }
        try run(plan, projectRoot: projectRoot)
    }

    /// The links under `folder` that point out of it — for an unpacked
    /// archive, whose `SKILL.md` can be a link to any file on the Mac: an
    /// agent would read that file as the skill's instructions.
    static func linksLeaving(_ folder: URL, fm: FileManager = .default) -> [String] {
        let root = canonicalDir(folder.path)
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: root, isDirectory: true),
                                         includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
        var out: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            let inside = { (path: String) in path == root || path.hasPrefix(root + "/") }
            // Where its text points, and where that ends up.
            guard let hop = linkTarget(of: url.path), inside(canonicalPath(hop)),
                  SkillScan.realPath(url.path).map(inside) ?? true else {
                out.append(url.path)
                continue
            }
        }
        return out
    }

    /// A file's text exactly as it is on disk, or nil when it is not
    /// UTF-8. Foundation's UTF-8 reads (`String(contentsOfFile:encoding:)`,
    /// `String(data:encoding:)`) drop a byte-order mark — measured — so a
    /// file read through them and written back loses it, and a check made
    /// on that text never sees the mark Codex skips a skill over.
    static func readText(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              String(data: data, encoding: .utf8) != nil else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Rewrite a skill's SKILL.md (description, body, "only when I call
    /// it") and Codex's policy file beside it. `expected` is the text
    /// the edit was made against (`readText`): a file that changed since
    /// is left alone.
    ///
    /// `onlyWhenCalled` is nil when the form left the box as it found it:
    /// the box shows "SKILL.md says so OR Codex's file says so", and
    /// written back unasked it copied the one into the other — a save
    /// that changed a word made Claude's and Kimi's skill only-when-
    /// called because Codex's was.
    func edit(realPath: String, expected: String, description: String, body: String,
              onlyWhenCalled: Bool?) throws {
        let skill = try editableSkillFile(realPath)
        guard let current = Self.readText(skill) else {
            throw SkillOpError.notASkill(realPath)
        }
        guard current == expected else { throw SkillOpError.changedOnDisk }
        // Only what the form changed is rewritten. A part left as the
        // file has it keeps its own spelling — a folded description, the
        // spacing around the body — so a save that changes nothing
        // writes nothing.
        let was = SkillFrontmatter.parse(current)
        let sameBody = body.trimmingCharacters(in: .newlines)
            == was.body.trimmingCharacters(in: .newlines)
        let updated = SkillFileEdit.updated(
            current,
            description: description == was.description ? nil : description,
            body: sameBody ? nil : body,
            onlyWhenCalled: onlyWhenCalled == was.disableModelInvocation ? nil : onlyWhenCalled)
        if let onlyWhenCalled { try writePolicy(realPath: realPath, onlyWhenCalled: onlyWhenCalled) }
        if updated != current {
            do { try Data(updated.utf8).write(to: URL(fileURLWithPath: skill), options: .atomic) }
            catch { throw SkillOpError.io(error.localizedDescription) }
        }
    }

    /// The SKILL.md of a skill SipAI may rewrite: its folder a direct
    /// child of the library, an agent's own folder or the common one —
    /// the same test every other write passes. A skill reached through a
    /// link into an agent's built-in folder, or into a folder of the
    /// user's kept anywhere else, is read here and edited there. And the
    /// file itself, never a link: an atomic write would replace the link
    /// with a copy.
    private func editableSkillFile(_ realPath: String) throws -> String {
        // (A folder that has become a link since it was read leads
        // somewhere SipAI does not write.)
        guard isWritable(realPath), !lstatIsLink(realPath) else { throw SkillOpError.readOnly }
        let skill = (realPath as NSString).appendingPathComponent("SKILL.md")
        guard !lstatIsLink(skill) else { throw SkillOpError.readOnly }
        return skill
    }

    /// Whether SipAI may rewrite this skill's SKILL.md.
    func canEdit(realPath: String) -> Bool {
        (try? editableSkillFile(realPath)) != nil
    }

    /// What giving a skill to `target` takes (`SkillShareCheck`), read off
    /// its files now. `nameTaken`: the agent already has another skill of
    /// this name. `carrySettings` false checks only what keeps the agent
    /// from loading it — a repair of a skill the agent already has.
    func shareCheck(realPath: String, target: String, nameTaken: Bool,
                    carrySettings: Bool = true) -> SkillShareCheck {
        let text = Self.readText((realPath as NSString).appendingPathComponent("SKILL.md"))
        let yaml = Self.readText((realPath as NSString).appendingPathComponent(SkillCodexPolicy.relativePath))
        return SkillShareCheck.make(skillText: text, codexYaml: yaml,
                                    folderName: (realPath as NSString).lastPathComponent,
                                    target: target, writable: canEdit(realPath: realPath),
                                    nameTaken: nameTaken, carrySettings: carrySettings)
    }

    /// Make a share check's fixes in the skill's own files. `expected` is
    /// the SKILL.md the check read: a file that changed since is left
    /// alone, so what is written is what the user was shown.
    func conform(realPath: String, expected: String, fixes: [SkillShareFix]) throws {
        let skill = try editableSkillFile(realPath)
        guard let current = Self.readText(skill) else { throw SkillOpError.notASkill(realPath) }
        guard current == expected else { throw SkillOpError.changedSinceChecked }
        if fixes.contains(.onlyWhenCalledForCodex) {
            try writePolicy(realPath: realPath, onlyWhenCalled: true)
        }
        let next = SkillFormat.applying(fixes, to: current)
        guard next != current else { return }
        do { try Data(next.utf8).write(to: URL(fileURLWithPath: skill), options: .atomic) }
        catch { throw SkillOpError.io(error.localizedDescription) }
    }

    /// Set or clear "only when I call it" in a skill's own files alone.
    func setOnlyWhenCalled(realPath: String, _ on: Bool) throws {
        let skill = try editableSkillFile(realPath)
        guard let current = Self.readText(skill) else {
            throw SkillOpError.notASkill(realPath)
        }
        let updated = SkillFileEdit.updated(current, description: nil, body: nil, onlyWhenCalled: on)
        try writePolicy(realPath: realPath, onlyWhenCalled: on)
        if updated != current {
            do { try Data(updated.utf8).write(to: URL(fileURLWithPath: skill), options: .atomic) }
            catch { throw SkillOpError.io(error.localizedDescription) }
        }
    }

    private func writePolicy(realPath: String, onlyWhenCalled: Bool) throws {
        let yamlURL = URL(fileURLWithPath: realPath).appendingPathComponent(SkillCodexPolicy.relativePath)
        let current = Self.readText(yamlURL.path)
        // There, and not text SipAI can read: never taken for absent,
        // which would write a new file over it.
        if current == nil, exists(yamlURL.path) { throw SkillOpError.unsupportedYAML }
        // Already says what is asked: nothing to write. Without this a
        // file in a form SipAI does not edit would refuse every change
        // to the skill, the ones that never touch it included.
        if SkillCodexPolicy.allowsImplicitInvocation(yaml: current) == !onlyWhenCalled { return }
        let next: String?
        do { next = try SkillFileEdit.codexPolicy(current, onlyWhenCalled: onlyWhenCalled) }
        catch { throw SkillOpError.unsupportedYAML }
        guard next != current else { return }
        // The file itself, in the skill's own folder: written through a
        // link — the file's, or its `agents` folder's — it would replace
        // the link with a copy, or land in a folder that is not the
        // skill's.
        if lstatIsLink(yamlURL.path) || lstatIsLink(yamlURL.deletingLastPathComponent().path) {
            throw SkillOpError.unsupportedYAML
        }
        do {
            if let next {
                try fm.createDirectory(at: yamlURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(next.utf8).write(to: yamlURL, options: .atomic)
            } else if fm.fileExists(atPath: yamlURL.path) {
                try fm.removeItem(at: yamlURL)
            }
        } catch {
            throw SkillOpError.io(error.localizedDescription)
        }
    }

    /// How many files of a skill folder are scripts an agent might run —
    /// for the import sheet's warning.
    static func scriptCount(in folder: URL, fm: FileManager = .default) -> Int {
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return 0 }
        let scripts: Set<String> = ["sh", "bash", "zsh", "py", "js", "mjs", "ts", "rb", "pl", "command"]
        var n = 0
        for case let url as URL in walker where scripts.contains(url.pathExtension.lowercased()) {
            n += 1
        }
        return n
    }
}
