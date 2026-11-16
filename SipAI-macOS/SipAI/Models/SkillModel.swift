// SkillModel.swift
// Agent skills — folders holding a SKILL.md — and the rules every
// surface reads: Settings → Agent Skills, the composer's skill chip,
// scheduled tasks and the three transcript readers.
//
// How a skill belongs to an agent. Each agent reads its OWN skills
// folder (Claude Code `~/.claude/skills`, Codex `~/.codex/skills`, Kimi
// Code `~/.kimi-code/skills`; inside a project the `.claude/skills`,
// `.codex/skills` and `.kimi-code/skills` at its root) plus, for Codex
// and Kimi, the common `.agents/skills`. SipAI keeps the real files of
// the skills it manages in its own library (`~/.sipai/skills`, and
// `.sipai/skills` at a project's root), which no agent reads, and gives
// an agent a skill by putting a LINK to it in that agent's own folder.
// One link: only that agent has it. Several: they share one copy, so an
// edit reaches every agent that has it. All three agents follow a linked
// skill folder in those places.
//
// The library sits at the same depth as the agents' folders, so a skill
// whose files refer to their neighbours with a relative path ("../../x")
// keeps working when it moves in.
//
// Foundation only, so the headless harness compiles it alone.

import Foundation

// MARK: - Agents and scopes

/// The agents that have skills, by registry key.
enum SkillAgent {
    static let claude = "claude_code"
    static let codex = "codex"
    static let kimi = "kimi"
    static let all = [claude, codex, kimi]

    /// Whether one message can carry only ONE skill the user starts.
    /// Kimi's own front end (`kimi acp`) reads one leading `/skill:name`
    /// per message and takes the rest of the message as that skill's
    /// input — a second `/skill:` in it is text (measured). So a Kimi
    /// session's chip, and a Kimi task, hold one skill at a time: two
    /// ticked would load one with the next message and leave the other,
    /// and a scheduled run has no next message. Claude and Codex load
    /// every skill a message names, in one request.
    static func oneSkillPerMessage(_ agent: String) -> Bool {
        agent == kimi
    }

    /// How an agent's user calls a skill by name — the spelling the
    /// detail view prints. An agent whose spelling is not known gets the
    /// bare name, never another agent's spelling.
    static func invocation(of name: String, agent: String) -> String {
        switch agent {
        case claude: return "/" + name
        case codex: return "$" + name
        case kimi:  return "/skill:" + name
        default:    return name
        }
    }
}

/// Global skills reach every folder; a folder's skills reach sessions
/// that run in it.
enum SkillScope: String, Hashable, CaseIterable {
    case global
    case folder
}

/// The folders that decide where skills live, resolved the way each
/// agent resolves them: an agent honours its own home variable, so the
/// scan and every write must too.
struct SkillEnvironment: Equatable {
    var home: URL
    var claudeConfigDir: URL
    var codexHome: URL
    var kimiHome: URL

    static func resolve(_ environment: [String: String], home: URL) -> SkillEnvironment {
        func dir(_ key: String, _ fallback: String) -> URL {
            if let value = environment[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                return URL(fileURLWithPath: (value as NSString).expandingTildeInPath,
                           isDirectory: true)
            }
            return home.appendingPathComponent(fallback, isDirectory: true)
        }
        return SkillEnvironment(home: home,
                                claudeConfigDir: dir("CLAUDE_CONFIG_DIR", ".claude"),
                                codexHome: dir("CODEX_HOME", ".codex"),
                                kimiHome: dir("KIMI_CODE_HOME", ".kimi-code"))
    }
}

// MARK: - Folders

/// What a skills folder is to SipAI.
enum SkillRootKind: Hashable {
    /// An agent's own folder. SipAI writes links here.
    case own
    /// `.agents/skills`, which Codex and Kimi both read. SipAI never
    /// adds anything here; it only moves a skill out when one of the two
    /// should stop having it.
    case common
    /// SipAI's library. No agent reads it.
    case library
    /// A plugin's, the agent's built-in skills, an organisation's — the
    /// agent's to manage. SipAI never writes here.
    case readOnly
}

struct SkillRoot: Hashable {
    let url: URL
    let kind: SkillRootKind
    let scope: SkillScope
    /// The agents that read this folder directly.
    let readers: [String]
    /// What a read-only source is called on screen ("Built-in",
    /// "claude.ai"). Nil for every other kind.
    var sourceLabel: String? = nil
    /// Skills nested one level down (`synced/<bucket>/<skill>`).
    var nested: Bool = false
    /// Whether SipAI writes here. False for a `.claude/skills` or an
    /// `.agents/skills` BETWEEN the project root and the working folder:
    /// an agent reads it, and SipAI moves, edits and bins nothing in it.
    var managed: Bool = true
}

enum SkillRoots {
    /// A folder's project root: the nearest ancestor holding `.git`,
    /// else the folder itself. Project skills are written here, the one
    /// place all three agents look: Claude walks up from the folder to
    /// the repository root, Codex walks down from it, and Kimi reads it
    /// alone.
    static func projectRoot(of folder: URL,
                            fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        let start = pathURL(folder)
        var dir = start
        while true {
            if fileExists(dir.appendingPathComponent(".git").path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || dir.path == "/" { return start }
            dir = parent
        }
    }

    /// `url` remade from its path. A folder URL a directory listing hands
    /// back climbs PAST the top — its parents run "/", "/..", "/../.." —
    /// so a walk up that waits for the parent to stop changing never
    /// ends (measured); one made from a path stops at "/".
    static func pathURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    /// SipAI's library for a scope.
    static func library(scope: SkillScope, env: SkillEnvironment, projectRoot: URL?) -> URL {
        switch scope {
        case .global: return env.home.appendingPathComponent(".sipai/skills", isDirectory: true)
        case .folder: return (projectRoot ?? env.home).appendingPathComponent(".sipai/skills", isDirectory: true)
        }
    }

    /// The folder an agent reads as its own — where SipAI puts its links.
    /// Nil for an agent the skills code does not name: a link made in
    /// another agent's folder would give the skill to that agent instead.
    static func ownFolder(agent: String, scope: SkillScope,
                          env: SkillEnvironment, projectRoot: URL?) -> URL? {
        switch scope {
        case .global:
            switch agent {
            case SkillAgent.claude: return env.claudeConfigDir.appendingPathComponent("skills", isDirectory: true)
            case SkillAgent.codex: return env.codexHome.appendingPathComponent("skills", isDirectory: true)
            case SkillAgent.kimi:  return env.kimiHome.appendingPathComponent("skills", isDirectory: true)
            default:               return nil
            }
        case .folder:
            let root = projectRoot ?? env.home
            switch agent {
            case SkillAgent.claude: return root.appendingPathComponent(".claude/skills", isDirectory: true)
            case SkillAgent.codex: return root.appendingPathComponent(".codex/skills", isDirectory: true)
            case SkillAgent.kimi:  return root.appendingPathComponent(".kimi-code/skills", isDirectory: true)
            default:               return nil
            }
        }
    }

    /// The common folder Codex and Kimi both read.
    static func common(scope: SkillScope, env: SkillEnvironment, projectRoot: URL?) -> URL {
        switch scope {
        case .global: return env.home.appendingPathComponent(".agents/skills", isDirectory: true)
        case .folder: return (projectRoot ?? env.home).appendingPathComponent(".agents/skills", isDirectory: true)
        }
    }

    /// Every folder a scan reads: the global ones, and — given a working
    /// folder — the ones that folder adds.
    static func scanRoots(env: SkillEnvironment, folder: URL?,
                          fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [SkillRoot] {
        var roots: [SkillRoot] = [
            SkillRoot(url: library(scope: .global, env: env, projectRoot: nil),
                      kind: .library, scope: .global, readers: []),
        ]
        // Each agent's own folder, in the order the agents are named.
        roots += SkillAgent.all.compactMap { agent in
            ownFolder(agent: agent, scope: .global, env: env, projectRoot: nil)
                .map { SkillRoot(url: $0, kind: .own, scope: .global, readers: [agent]) }
        }
        roots += [
            SkillRoot(url: common(scope: .global, env: env, projectRoot: nil),
                      kind: .common, scope: .global, readers: [SkillAgent.codex, SkillAgent.kimi]),
            SkillRoot(url: env.codexHome.appendingPathComponent("skills/.system", isDirectory: true),
                      kind: .readOnly, scope: .global, readers: [SkillAgent.codex],
                      sourceLabel: "Built-in"),
            SkillRoot(url: env.claudeConfigDir.appendingPathComponent("skills/synced", isDirectory: true),
                      kind: .readOnly, scope: .global, readers: [SkillAgent.claude],
                      sourceLabel: "claude.ai", nested: true),
        ]
        guard let folder else { return roots }
        let start = pathURL(folder)
        let root = projectRoot(of: start, fileExists: fileExists)
        // A project root that IS the home folder (a home kept in git) adds
        // no folders of its own: `~/.claude/skills` and its like are the
        // global ones already listed. What lies BETWEEN home and the
        // working folder is still read below — claude reads those.
        let rootIsHome = root.path == env.home.standardizedFileURL.path
        if !rootIsHome {
            roots.append(SkillRoot(url: library(scope: .folder, env: env, projectRoot: root),
                                   kind: .library, scope: .folder, readers: []))
            roots += SkillAgent.all.compactMap { agent in
                ownFolder(agent: agent, scope: .folder, env: env, projectRoot: root)
                    .map { SkillRoot(url: $0, kind: .own, scope: .folder, readers: [agent]) }
            }
            roots += [
                SkillRoot(url: common(scope: .folder, env: env, projectRoot: root),
                          kind: .common, scope: .folder,
                          readers: [SkillAgent.codex, SkillAgent.kimi]),
            ]
        }
        // Between the root and the folder (`betweenFolders`).
        var dir = start
        while dir.path != root.path, dir.path != "/", dir.path.hasPrefix(root.path) {
            for level in betweenFolders {
                roots.append(SkillRoot(url: dir.appendingPathComponent(level.name, isDirectory: true),
                                       kind: level.kind, scope: .folder, readers: level.readers, managed: false))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return roots
    }

    /// The skills folders read at each level BETWEEN a repository's root
    /// and the folder a session starts in, and who reads each (measured
    /// on each tool's own listing): Claude reads `.claude/skills` at
    /// every level, walking up from where it starts; Codex reads both
    /// `.codex/skills` and `.agents/skills` at every level, walking down
    /// from the root. Kimi reads the root alone. SipAI writes in none of
    /// them (`SkillRoot.managed`).
    static let betweenFolders: [(name: String, kind: SkillRootKind, readers: [String])] = [
        (".claude/skills", .own, [SkillAgent.claude]),
        (".codex/skills", .own, [SkillAgent.codex]),
        (".agents/skills", .common, [SkillAgent.codex]),
    ]

    /// The skills folders of a folder that is its own project — a
    /// repository's root, or a folder with no repository around it: each
    /// agent's own, the common one and SipAI's library.
    static let levelFolders = [".claude/skills", ".agents/skills", ".codex/skills",
                               ".kimi-code/skills", ".sipai/skills"]

    /// How far below a chosen folder the walk looks, how many folders it
    /// looks in, and how many subfolders it hands back. Each one found is
    /// read whole — the agents' own tools asked in it — so the last bound
    /// is also how much work one page can start.
    static let subfolderDepth = 3
    static let subfolderVisitLimit = 2_000
    static let subfolderLimit = 20

    /// The folders below `folder` that hold skills of their own — a
    /// project inside a workspace, a package in a monorepo. A session
    /// started in `folder` is not started with them (Codex and Kimi never
    /// read below where they start; Claude adds a folder's
    /// `.claude/skills` only once it works on a file in it), so Settings →
    /// Skills reads each as a folder of its own and draws it as a
    /// subfolder.
    ///
    /// Bounded, because a folder can hold anything: `subfolderDepth`
    /// levels down, hidden folders, `node_modules` and packages passed
    /// over, links not followed, `subfolderVisitLimit` folders looked in
    /// — and a folder's FILES cost it nothing (`childFolders`). The home
    /// folder, and any folder above it, is not walked at all
    /// (`walksBelow`). Nearest first, then by name, each spelled the way
    /// the chosen folder is.
    ///
    /// A subfolder counts when a read of it would find a skill at its own
    /// level (`holdsSkills`): the walk and the read agree, or the page
    /// reads a folder — the agents' own tools asked in it — to draw
    /// nothing.
    static func subfolders(of folder: URL, home: URL, fm: FileManager = .default) -> SkillSubfolders {
        let start = pathURL(folder).path
        guard walksBelow(start, home: pathURL(home).path) else { return SkillSubfolders() }
        // Whether a repository reaches the chosen folder: its own `.git`,
        // or one above it.
        let root = projectRoot(of: URL(fileURLWithPath: start, isDirectory: true)).path
        let inRepository = fm.fileExists(atPath: (root as NSString).appendingPathComponent(".git"))
        var queue: [(path: String, depth: Int, inRepository: Bool)] = [(start, 0, inRepository)]
        var next = 0
        var looked = 0
        var out = SkillSubfolders()
        while next < queue.count {
            let (dir, depth, above) = queue[next]
            next += 1
            for name in childFolders(of: dir) {
                let child = (dir as NSString).appendingPathComponent(name)
                looked += 1
                if looked > subfolderVisitLimit {
                    out.stoppedEarly = true
                    return out
                }
                guard isPlainFolder(child) else { continue }
                let isRoot = fm.fileExists(atPath: (child as NSString).appendingPathComponent(".git"))
                if holdsSkills(child, ownProject: isRoot || !above, fm: fm) {
                    if out.found.count == subfolderLimit {
                        out.stoppedEarly = true
                        return out
                    }
                    out.found.append(SkillLevel(path: child))
                }
                if depth + 1 < subfolderDepth { queue.append((child, depth + 1, above || isRoot)) }
            }
        }
        return out
    }

    /// Whether the walk looks below `start` at all: not below the home
    /// folder, nor below a folder above it — that would be every project
    /// in the account. Judged on the real folders, so a link to the home
    /// folder, or its path typed in another case, is the home folder too.
    static func walksBelow(_ start: String, home: String) -> Bool {
        let start = SkillScan.realPath(start) ?? start
        let home = SkillScan.realPath(home) ?? home
        if start == home { return false }
        return !home.hasPrefix(start == "/" ? "/" : start + "/")
    }

    /// The names of the entries of `path` that its listing says are
    /// folders, in name order — dot-named ones and `node_modules` left
    /// out, a link to a folder not among them. Read off the directory's
    /// own entries, which say what each is: a folder holding a hundred
    /// thousand files costs one listing, and nothing per file. (Listed as
    /// URLs with their properties and sorted before the folders were
    /// picked out, one such folder took over a second and half a
    /// gigabyte.) A volume that does not say what an entry is has every
    /// entry here, and `isPlainFolder` to tell them apart.
    static func childFolders(of path: String) -> [String] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let type = Int32(entry.pointee.d_type)
            guard type == DT_DIR || type == DT_UNKNOWN else { continue }
            let name = withUnsafeBytes(of: &entry.pointee.d_name) {
                String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name.hasPrefix(".") || name == "node_modules" { continue }
            names.append(name)
        }
        return names.sorted()
    }

    /// Whether `path` is a folder the walk looks in: a real one — not a
    /// link — that is not flagged hidden and not a package. Asked one
    /// folder at a time as the walk reaches it, so its cost is inside the
    /// walk's bound.
    static func isPlainFolder(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_flags & UInt32(UF_HIDDEN) == 0 else { return false }
        // Only a name with an extension can be a package.
        guard !(path as NSString).pathExtension.isEmpty else { return true }
        let values = try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage != true
    }

    /// Whether a read of `dir` would find a skill at `dir`'s own level —
    /// what `scanRoots` reads there and `SkillScan.read` makes a row of.
    /// A folder that is its own project is read in all its skills folders
    /// (`levelFolders`); one inside a repository only where Claude and
    /// Codex look (`betweenFolders`). An entry is a skill when it holds a
    /// SKILL.md, or is a link to nothing (drawn as a broken link) — a
    /// link in SipAI's library is no library skill, and a link to a
    /// folder with no SKILL.md is no skill at all.
    static func holdsSkills(_ dir: String, ownProject: Bool, fm: FileManager = .default) -> Bool {
        for name in ownProject ? levelFolders : betweenFolders.map(\.name) {
            let skills = (dir as NSString).appendingPathComponent(name)
            guard let entries = try? fm.contentsOfDirectory(atPath: skills) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                let path = (skills as NSString).appendingPathComponent(entry)
                if (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
                    if name == ".sipai/skills" { continue }
                    if SkillScan.realPath(path) == nil { return true }
                }
                if fm.fileExists(atPath: (path as NSString).appendingPathComponent("SKILL.md")) { return true }
            }
        }
        return false
    }

    /// The folder whose skills folder holds `entryPath` — `<it>/.claude/
    /// skills/<name>` and the like — which is where the skill is to the
    /// page: the chosen folder's own, or one of its subfolders'. Nil for
    /// a path with no such folder above it: a skill an agent reported
    /// with no path at all is at no level. By the path's text alone: a
    /// page asks this of every row it draws, on every pass.
    static func level(of entryPath: String) -> String? {
        guard entryPath.hasPrefix("/") else { return nil }
        var path = Substring(entryPath)
        for _ in 0..<3 {
            guard let slash = path.lastIndex(of: "/") else { return nil }
            path = path[..<slash]
        }
        return path.isEmpty ? "/" : String(path)
    }
}

/// A folder as its skills' paths may spell it: the way the page has it,
/// and its real path (`/private` included) — a library row knows only its
/// real path. Made once, where a file-system call may be made: the page
/// then asks `holds` of every row on every pass, by text alone.
struct SkillLevel: Equatable {
    let path: String
    let realPath: String

    init(path: String) {
        let spelled = SkillRoots.pathURL(URL(fileURLWithPath: path, isDirectory: true)).path
        self.path = spelled
        self.realPath = SkillScan.realPath(spelled) ?? spelled
    }

    /// Whether `entryPath` is a skill in one of this folder's own skills
    /// folders.
    func holds(_ entryPath: String) -> Bool {
        guard let level = SkillRoots.level(of: entryPath) else { return false }
        return level == path || level == realPath
    }
}

/// The folders below a chosen folder that hold skills of their own
/// (`SkillRoots.subfolders`).
struct SkillSubfolders: Equatable {
    /// Nearest first, then by name.
    var found: [SkillLevel] = []
    /// The walk stopped before it had looked in every folder below — it
    /// had found as many as it takes, or looked in as many as it looks
    /// in — so there may be subfolders with skills that are not in
    /// `found`. Not "some were left out": a folder of two thousand
    /// subfolders and no skill stops it too.
    var stoppedEarly = false
}

// MARK: - The folders a page has browsed

/// Settings → Agent Skills' folder menu lists the folders browsed there: the
/// newest first, ten at most, none not browsed for a month and none that
/// is not on disk right now. Mac-only UI state, so it lives in
/// UserDefaults, never in the config file the CLI shares — and goes with
/// a factory reset (`FactoryReset.userDefaultsKeys`).
///
/// What the menu LISTS and what is KEPT are two rules. A folder that is
/// not there at the moment — its disk ejected, its share away — is left
/// out of the menu and stays in the history: dropped from it, a folder
/// was forgotten for good by the next folder browsed, and did not come
/// back with its disk.
enum SkillFolderHistory {
    static let defaultsKey = "skillsBrowsedFolders"
    /// How many the menu lists.
    static let limit = 10
    /// How many are kept: more than the menu lists, so the folders that
    /// are away do not push the ones that are there out of it.
    static let storeLimit = 50

    struct Visit: Codable, Equatable {
        var path: String
        var at: Date
    }

    /// Where the history is kept; the harness points it at a scratch file.
    @MainActor static var defaults: UserDefaults = .standard

    /// What is kept of `visits` at `now`: one visit a folder, the newest
    /// first, none older than a month, `storeLimit` at most — there right
    /// now or not.
    static func kept(_ visits: [Visit], now: Date, calendar: Calendar = .current) -> [Visit] {
        let cutoff = calendar.date(byAdding: .month, value: -1, to: now) ?? .distantPast
        var seen = Set<String>()
        return Array(visits
            .filter { $0.at >= cutoff }
            .sorted { $0.at > $1.at }
            .filter { seen.insert($0.path).inserted }
            .prefix(storeLimit))
    }

    /// The visits the menu lists at `now`: of what is kept, the folders
    /// that are there, `limit` at most. `exists` is asked newest first,
    /// and of no more folders than it takes to find them.
    static func current(_ visits: [Visit], now: Date, calendar: Calendar = .current,
                        exists: (String) -> Bool) -> [Visit] {
        var out: [Visit] = []
        for visit in kept(visits, now: now, calendar: calendar) {
            if out.count == limit { break }
            if exists(visit.path) { out.append(visit) }
        }
        return out
    }

    /// `visits` with `path` browsed at `now`: at the front, what has aged
    /// out dropped. A visit stamped later than `now` — the clock was set
    /// back since — is taken to be earlier than this one: left ahead of
    /// it, that folder led the menu, and was the page's default, until
    /// the clock caught up.
    static func recording(_ path: String, at now: Date, in visits: [Visit],
                          calendar: Calendar = .current) -> [Visit] {
        let before = now.addingTimeInterval(-0.001)
        let earlier = visits.filter { $0.path != path }.map { Visit(path: $0.path, at: min($0.at, before)) }
        return kept([Visit(path: path, at: now)] + earlier, now: now, calendar: calendar)
    }

    @MainActor static func load() -> [Visit] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([Visit].self, from: data)) ?? []
    }

    @MainActor static func save(_ visits: [Visit]) {
        if let data = try? JSONEncoder().encode(visits) { defaults.set(data, forKey: defaultsKey) }
    }

    static func isFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - SKILL.md

/// What SipAI reads out of a SKILL.md's frontmatter. Agents read more;
/// these are the keys that change how a skill is invoked or shown.
struct SkillFrontmatter: Equatable {
    var name: String? = nil
    var description: String = ""
    /// Claude and Kimi: the model never uses it on its own.
    var disableModelInvocation = false
    /// Claude: `user-invocable: false` — only the model can use it.
    var userInvocable = true
    /// Claude: `context: fork` — it runs as its own task, so it cannot
    /// be preloaded into a conversation.
    var runsForked = false
    /// Claude only: tools the skill grants while it runs.
    var allowedTools: String? = nil
    /// Kimi: the skill's `type`, lower-cased; nil when the header names
    /// none. A `reference` skill is one kimi's model may read and the
    /// user cannot start (`kimiUserCanStart`).
    var type: String? = nil
    /// The text below the frontmatter.
    var body: String = ""

    /// Whether kimi lets the USER start the skill (`/skill:name`): no
    /// type, or one kimi runs when asked — never `reference`, which it
    /// leaves out of its commands.
    var kimiUserCanStart: Bool {
        guard let type, !type.isEmpty else { return true }
        return ["prompt", "inline", "flow"].contains(type)
    }
    /// Whether the file has a frontmatter block at all.
    var hasFrontmatter = false

    /// Read the frontmatter of SKILL.md text. A plain `key: value`
    /// subset — enough for the keys above, including a folded
    /// (`>` / `|`) description.
    static func parse(_ text: String) -> SkillFrontmatter {
        var out = SkillFrontmatter()
        // A byte-order mark ahead of the opening fence is not text.
        let normalized = (text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let written = normalized.components(separatedBy: "\n")
        // The header the checks and the edits see (`SkillFormat.headerEnd`):
        // read by another test, a fence with a space after it was a header
        // to them and none here, and an edit wrote a second one above it.
        guard let close = SkillFormat.headerEnd(written) else {
            out.body = normalized
            return out
        }
        out.hasFrontmatter = true
        out.body = written[(close + 1)...].joined(separator: "\n")
        let lines = SkillFormat.headerLines(written, close: close)
        var i = 1
        while i < close {
            guard let entry = SkillFormat.keyLine(lines[i]) else { i += 1; continue }
            let end = valueEnd(lines, key: i, limit: close)
            let key = entry.key.lowercased()
            // The words as written, even where YAML would refuse them:
            // this is what the pane shows, and the checks say the rest.
            let value: String
            switch SkillFormat.read(entry.rest, more: Array(lines[(i + 1)..<end]),
                                    isText: key == "name" || key == "description") {
            case .text(let words), .unreadable(let words), .structure(let words): value = words
            case .empty, .invalid: value = ""
            }
            i = end
            switch key {
            case "name": out.name = value.isEmpty ? nil : value
            case "description": out.description = value
            case _ where isOnlyWhenCalledKey(key):
                out.disableModelInvocation = isTrue(value)
            case "user-invocable": out.userInvocable = !isFalse(value)
            case "context": out.runsForked = value.lowercased() == "fork"
            case "allowed-tools": out.allowedTools = value.isEmpty ? nil : value
            case "type":
                let type = value.trimmingCharacters(in: .whitespaces).lowercased()
                out.type = type.isEmpty ? nil : type
            default: break
            }
        }
        return out
    }

    /// The spellings of "only when I call it" a header is read with, lower
    /// case: the one SipAI writes, and the camel-case one. An edit that
    /// clears the setting must find every spelling the reader takes, or
    /// the switch cannot be turned off.
    static func isOnlyWhenCalledKey(_ key: String) -> Bool {
        key == "disable-model-invocation" || key == "disablemodelinvocation"
    }

    /// Where the value of the key on line `key` ends — the index after
    /// its last line. Past its indented lines (`scalarEnd`), and further
    /// in the three shapes YAML continues on a line that is NOT indented:
    /// a quoted value to its closing quote, a `[`…`]` or `{`…`}` to its
    /// closing bracket, and a list written at the key's own indent
    /// (`description:` / `- a` / `- b`). An edit that replaced only the
    /// indented span left the rest of such a value behind, under the new
    /// one, and the file was no longer YAML.
    static func valueEnd(_ lines: [String], key: Int, limit: Int) -> Int {
        var end = scalarEnd(lines, from: key + 1, limit: limit)
        guard let entry = SkillFormat.keyLine(lines[key]) else { return end }
        var rest = Substring(entry.rest)
        var j = key + 1
        if rest.isEmpty || rest.hasPrefix("#") {
            // The first line with anything on it, comments aside.
            while j < limit, SkillFormat.isBlankOrComment(lines[j]) { j += 1 }
            guard j < limit else { return end }
            if lines[j] == "-" || lines[j].hasPrefix("- ") {
                var last = j
                while j < limit {
                    let line = lines[j]
                    if line == "-" || line.hasPrefix("- ") || line.first == " " || line.first == "\t" {
                        if !line.trimmingCharacters(in: .whitespaces).isEmpty { last = j }
                    } else if !SkillFormat.isBlankOrComment(line) {
                        break
                    }
                    j += 1
                }
                return max(end, last + 1)
            }
            // A value that opens on the line below its key — a comment at
            // the margin between the two is no end to it. Under a key
            // that holds a nested block, one is none further down either:
            // a comment says nothing wherever it stands, and a block cut
            // at one left its remaining keys as lines that belong to
            // nothing.
            guard let lead = lines[j].first, lead == " " || lead == "\t" else { return end }
            rest = Substring(lines[j]).drop { $0 == " " || $0 == "\t" }
            let nested = rest == "-" || rest.hasPrefix("- ") || SkillFormat.keyLine(String(rest)) != nil
            end = max(j + 1, scalarEnd(lines, from: j + 1, limit: limit, pastComments: nested))
            j += 1
        }
        /// Whether a value that closes on line `at` ends there cleanly —
        /// nothing after it but a comment. One that closes in the middle
        /// of a later line never meant to reach it: a quote left open,
        /// and another key's quote that happens to close it.
        func clean(_ tail: Substring) -> Bool {
            let after = tail.trimmingCharacters(in: .whitespaces)
            return after.isEmpty || after.hasPrefix("#")
        }
        if let quote = rest.first, quote == "\"" || quote == "'" {
            let scan = SkillFormat.QuoteScan(quote: quote)
            if scan.closes(in: rest.dropFirst()) { return end }
            while j < limit {
                let line = Substring(lines[j])
                if let close = scan.end(in: line) { return clean(line[close...]) ? max(end, j + 1) : end }
                j += 1
            }
            return end
        }
        if let open = rest.first, open == "[" || open == "{" {
            var scan = SkillFormat.FlowScan()
            if scan.closes(in: rest) { return end }
            while j < limit {
                if scan.closes(in: Substring(lines[j])) {
                    return clean(scan.tail ?? "") ? max(end, j + 1) : end
                }
                j += 1
            }
        }
        return end
    }

    /// Where the value that starts on the line above `start` ends: past
    /// its indented lines, and past a blank line only when an indented
    /// one follows it (a block scalar's paragraph break). Stopping at the
    /// first blank line leaves the rest of such a value behind when the
    /// key is rewritten — orphaned lines that are no longer valid YAML.
    /// `pastComments`: a comment at the margin is passed over too, as a
    /// blank line is (a nested block's own; text ends at one).
    static func scalarEnd(_ lines: [String], from start: Int, limit: Int, pastComments: Bool = false) -> Int {
        var end = start
        var j = start
        while j < limit {
            let line = lines[j]
            if let f = line.first, f == " " || f == "\t" {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { end = j + 1 }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty, !(pastComments && line.hasPrefix("#")) {
                break
            }
            j += 1
        }
        return end
    }

    /// A quoted scalar's value, its escapes undone — the reverse of
    /// `SkillFileEdit.yamlScalar`. Read with the quotes off and the
    /// escapes left in, a description holding a quote comes back with a
    /// backslash before it, and the next save escapes that backslash
    /// too: the text grows a little with every edit.
    static func unquoted(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.hasPrefix("\""), value.hasSuffix("\"") {
            return SkillFormat.unescaped(String(value.dropFirst().dropLast())).text
        }
        if value.hasPrefix("'"), value.hasSuffix("'") {
            // A single-quoted scalar's one escape is a doubled quote.
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    fileprivate static func isTrue(_ v: String) -> Bool {
        ["true", "yes", "on", "1"].contains(v.lowercased())
    }
    private static func isFalse(_ v: String) -> Bool {
        ["false", "no", "off", "0"].contains(v.lowercased())
    }
}

/// Codex's per-skill file beside SKILL.md, `agents/openai.yaml`: the one
/// key SipAI reads, whether the model may use the skill on its own.
enum SkillCodexPolicy {
    static let relativePath = "agents/openai.yaml"

    /// False when the file says the model must not use the skill on its
    /// own; true otherwise, the file missing included.
    static func allowsImplicitInvocation(yaml: String?) -> Bool {
        guard let yaml else { return true }
        var inPolicy = false
        for raw in yaml.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            // A comment at the margin sits inside the block it is in.
            if line.hasPrefix("#") { continue }
            if let f = line.first, f != " ", f != "\t" {
                inPolicy = line.trimmingCharacters(in: .whitespaces).hasPrefix("policy:")
                continue
            }
            guard inPolicy else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("allow_implicit_invocation:") {
                let v = SkillFormat.withoutComment(String(t.dropFirst("allow_implicit_invocation:".count)))
                    .trimmingCharacters(in: .whitespaces).lowercased()
                return !(v == "false" || v == "no" || v == "off")
            }
        }
        return true
    }
}

// MARK: - What each agent needs of a SKILL.md

/// Something in a SKILL.md that keeps an agent from loading the skill.
///
/// Each CLI handed one fault at a time (`Verification/Skills` hands them
/// to the installed ones): Claude loads every one of them. Codex and Kimi skip the skill — Codex says so
/// in its skill listing, Kimi nowhere — so a skill written for Claude
/// can be shared with either and never load.
enum SkillFormatProblem: Hashable {
    /// No `---` header at the top. Codex and Kimi skip the skill.
    case noHeader
    /// A byte-order mark before the header. Codex skips the skill.
    case byteOrderMark
    /// No `name:`. Kimi skips the skill; the others call it by its
    /// folder's name.
    case noName
    /// No `description:` that is text. Codex and Kimi skip the skill.
    case noDescription
    /// A value YAML cannot read as written: a `: ` inside it, one opening
    /// with `@`, `` ` ``, `*`, `{`, `[`, `- `, an unclosed quote. Kimi
    /// reads the header as strict YAML and skips the skill over any of
    /// them; Codex over most.
    case needsQuotes(String)
    /// A key given twice. Codex and Kimi skip the skill.
    case repeatedKey(String)
    /// A name longer than Codex takes.
    case nameTooLong
    /// A `name:` or `description:` that is a list or a map. It is there,
    /// and it is not text: nothing is added in its place.
    case notText(String)
    /// A description written as a flat list of text (`- one` / `- two`,
    /// or `[one, two]`), with the one sentence its items make. Codex and
    /// Kimi skip the skill as they do over any list; this one SipAI can
    /// write as the line it means, every word the user's own.
    case listDescription(String)
    /// The header opens and never closes: no second `---` line.
    case unclosedHeader
    /// A line of the header that is no key and no part of a value —
    /// words at the margin under a value (`description: First line` /
    /// `second line`), `name:x` with no space, a tab used to indent a
    /// nested block, a nested value YAML refuses. Quotes around one
    /// value do not mend it; the line is the user's to change.
    case unreadableLine(String)
    /// A nested line only a strict reader refuses: a value under a key
    /// with a `: ` inside it (`short-description: Use when: asked`), a
    /// key given twice in one nested map. Kimi skips the skill; Codex
    /// was measured to load it.
    case strictLine(String)
    /// A `type:` Kimi does not run as a skill: anything but `prompt`,
    /// `inline`, `flow` or `reference`.
    case unsupportedType
    /// The header's keys are set in from the margin. All by the same
    /// amount, they are one YAML block to a reader handed the header
    /// whole — Codex loads it — while Kimi trims the header's first line
    /// before it reads, and skips the skill (`kimi`). The first key alone
    /// set in, or a tab doing the indenting, Codex's reader stops at
    /// (`codex`).
    case indentedHeader(kimi: Bool, codex: Bool)
    /// A line that opens with a tab and holds nothing, or only a comment
    /// — or, in a block of text, a blank line with a tab where the
    /// block's indent would be. Kimi and Claude Code read past it; Codex
    /// skips the skill.
    case tabLine
    /// A line-separator character (U+2028, U+2029, U+0085) outside quotes
    /// with words after it. Codex's reader ends the line there and skips
    /// the skill; the others take it for part of the text.
    case lineSeparator
}

enum SkillFormat {
    /// The longest name Codex loads.
    static let maxNameLength = 64

    /// The values of `type:` Kimi runs as a skill.
    static let kimiTypes: Set<String> = ["prompt", "inline", "flow", "reference"]

    /// Whether `agent` skips a skill over `problem` — the measured table.
    /// Claude skips none of them.
    static func skips(_ problem: SkillFormatProblem, agent: String) -> Bool {
        switch agent {
        case SkillAgent.codex:
            switch problem {
            case .noName, .unsupportedType, .strictLine: return false
            case .indentedHeader(_, let codex): return codex
            default: return true
            }
        case SkillAgent.kimi:
            switch problem {
            case .byteOrderMark, .nameTooLong, .tabLine, .lineSeparator: return false
            case .indentedHeader(let kimi, _): return kimi
            default: return true
            }
        default:
            return false
        }
    }

    /// Whether SipAI can fix `problem` in the skill's own files. A name
    /// is how the user calls the skill; of a key given twice there is no
    /// telling which was meant; a list where text belongs, a line YAML
    /// cannot read and a header left open are the user's own words to
    /// put right.
    static func fixable(_ problem: SkillFormatProblem) -> Bool {
        switch problem {
        case .noHeader, .byteOrderMark, .noName, .noDescription, .needsQuotes,
             .indentedHeader, .tabLine, .lineSeparator, .listDescription:
            return true
        case .repeatedKey, .nameTooLong, .notText, .unclosedHeader, .unreadableLine, .strictLine, .unsupportedType:
            return false
        }
    }

    /// Everything in `text` some agent would skip the skill over — what
    /// is CERTAIN, and no more. A skill named here is tagged Not loaded,
    /// dimmed in the chip and refused to a scheduled run, and a fix made
    /// for it rewrites the user's file: a shape this reader does not
    /// know is let through, never called a fault.
    static func problems(in text: String) -> [SkillFormatProblem] {
        var out: [SkillFormatProblem] = []
        var t = text
        if t.hasPrefix("\u{FEFF}") {
            out.append(.byteOrderMark)
            t.removeFirst()
        }
        let written = t.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let close = headerEnd(written) else {
            return out + [isFence(written.first) ? .unclosedHeader : .noHeader]
        }
        let straight = straightened(written, close: close)
        let lines = straight.lines
        if let set = straight.problem { out.append(set) }
        let named = anchors(in: lines[1..<close])
        /// What a key that must be text holds.
        enum Field { case missing, text(String), other }
        var seen = Set<String>()
        var name = Field.missing
        var description = Field.missing
        // The first line YAML reads no further than — and whether only a
        // strict reader stops there. One is enough to say.
        var stray: (line: String, strict: Bool)? = nil
        var i = 1
        while i < close {
            guard let line = keyLine(lines[i]) else {
                // No key, and under no key's value. (A `? key` and its
                // `: value` are a key written the long way.)
                if stray == nil, !isBlankOrComment(lines[i]), !endsDocument(lines, at: i, limit: close),
                   !["? ", ": "].contains(String(lines[i].prefix(2))), lines[i] != "?", lines[i] != ":" {
                    stray = (shown(lines[i]), false)
                }
                i += 1
                continue
            }
            let key = line.key
            let end = SkillFrontmatter.valueEnd(lines, key: i, limit: close)
            let more = Array(lines[(i + 1)..<end])
            let isText = key == "name" || key == "description"
            let value = read(line.rest, more: more, isText: isText, anchors: named)
            i = end
            if key != "<<", !seen.insert(key).inserted {
                if !out.contains(.repeatedKey(key)) { out.append(.repeatedKey(key)) }
                continue
            }
            switch value {
            case .unreadable: out.append(.needsQuotes(key))
            case .invalid(let bad, let strict): if stray == nil { stray = (bad, strict) }
            case .structure where isText:
                // A list of plain sentences where the description goes is
                // one SipAI can write as a sentence; a map, a list in a
                // list, a list for the NAME are the user's to put right.
                if key == "description", let sentence = listSentence(rest: line.rest, more: more) {
                    out.append(.listDescription(sentence))
                } else {
                    out.append(.notText(key))
                }
            default: break
            }
            if isText {
                let field: Field
                switch value {
                case .text(let words), .unreadable(let words): field = .text(words)
                case .empty: field = .missing
                case .structure, .invalid: field = .other
                }
                if key == "name" { name = field } else { description = field }
            }
            // Kimi runs four types as a skill and refuses every other,
            // a `type:` left empty included.
            if key == "type" {
                var runs = false
                if case .text(let type) = read(line.rest, more: more, isText: true, anchors: named) {
                    runs = kimiTypes.contains(type)
                }
                if !runs { out.append(.unsupportedType) }
            }
        }
        if let stray { out.append(stray.strict ? .strictLine(stray.line) : .unreadableLine(stray.line)) }
        switch name {
        case .missing: out.append(.noName)
        case .text(let words) where words.count > maxNameLength: out.append(.nameTooLong)
        default: break
        }
        if case .missing = description { out.append(.noDescription) }
        // What only Codex's reader stops at.
        if !tabLines(lines, close: close).isEmpty { out.append(.tabLine) }
        if !separatorLines(lines, close: close).isEmpty { out.append(.lineSeparator) }
        return out
    }

    static func isFence(_ line: String?) -> Bool {
        line?.trimmingCharacters(in: .whitespaces) == "---"
    }

    /// The index of the header's closing `---`; nil when the text does
    /// not open with a header, or opens one and never closes it.
    static func headerEnd(_ lines: [String]) -> Int? {
        guard isFence(lines.first) else { return nil }
        return (1..<max(1, lines.count)).first { isFence(lines[$0]) }
    }

    /// The keys of a SKILL.md's header, in order.
    static func headerKeys(in text: String) -> [String] {
        let bare = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let written = bare.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let close = headerEnd(written) else { return [] }
        return entries(headerLines(written, close: close), close: close).map(\.key)
    }

    /// A top-level `key: value` line: its key, and the text after the
    /// colon. A colon is a key's only when a space or the line's end
    /// follows it, and a key in quotes is the key inside them — read
    /// with the quotes on, `"name": x` was a skill with no name, and the
    /// one added beside it made two.
    static func keyLine(_ line: String) -> (key: String, rest: String)? {
        guard let first = line.first, first != " ", first != "\t", first != "#" else { return nil }
        // A list's item — `-` alone, or `- ` and its text — is no key.
        if first == "-", line.count == 1 || line.dropFirst().first == " " { return nil }
        if first == "\"" || first == "'" {
            // The whole quoted word, then the colon: `"Use when: asked"`
            // is a value that holds a colon, not a key called `"Use when`.
            let inside = line.dropFirst()
            guard let close = QuoteScan(quote: first).end(in: inside) else { return nil }
            let after = inside[close...].drop { $0 == " " || $0 == "\t" }
            guard after.first == ":" else { return nil }
            let rest = after.dropFirst()
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            let key = String(inside[..<inside.index(before: close)])
            guard !key.isEmpty else { return nil }
            return (key, rest.trimmingCharacters(in: .whitespaces))
        }
        var index = line.startIndex
        while let colon = line[index...].firstIndex(of: ":") {
            let after = line.index(after: colon)
            if after == line.endIndex || line[after] == " " || line[after] == "\t" {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return nil }
                return (key, String(line[after...]).trimmingCharacters(in: .whitespaces))
            }
            index = after
        }
        return nil
    }

    /// A header's lines with its keys at the margin, where every rule
    /// here looks for them (`straightened`).
    static func headerLines(_ lines: [String], close: Int) -> [String] {
        straightened(lines, close: close).lines
    }

    /// A header's lines with the indentation of its keys taken out, and
    /// what that indentation costs — the same number of lines, so an
    /// index into one is an index into the other.
    ///
    /// Kimi trims the header before it reads it, so its first line with
    /// anything on it starts at the margin whatever its indent; Codex
    /// hands the header to YAML as it stands. So keys all set in by the
    /// same amount load in Codex (one block) and not in Kimi (the first
    /// key at the margin, the rest under it) — unless a comment comes
    /// first, which is then what Kimi trims, and both load. The first key
    /// alone set in loads in Kimi and not in Codex. A tab doing the
    /// indenting is refused by both, except by Kimi on a first line it
    /// trims. Read with only the first line straightened, a header set in
    /// whole was "a name that needs quotes" — the keys below it taken for
    /// its words — and the quotes made a name of the whole header.
    static func straightened(_ lines: [String], close: Int) -> (lines: [String], problem: SkillFormatProblem?) {
        func lead(_ line: String) -> Substring { line.prefix { $0 == " " || $0 == "\t" } }
        guard let firstText = (1..<close).first(where: { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty })
        else { return (lines, nil) }
        guard let firstKey = (firstText..<close).first(where: { !isBlankOrComment(lines[$0]) }) else {
            return (lines, nil)
        }
        // A comment's own indent changes nothing, and is left as it is.
        var trimmed = lines
        if firstKey == firstText {
            trimmed[firstText] = String(lines[firstText].dropFirst(lead(lines[firstText]).count))
        }
        let indent = String(lead(lines[firstKey]))
        guard !indent.isEmpty else { return (trimmed, nil) }
        if ((firstKey + 1)..<close).allSatisfy({ isBlankOrComment(lines[$0]) || lines[$0].hasPrefix(indent) }) {
            // (A blank line or a comment set in less keeps what it has:
            // it says nothing wherever it stands.)
            var flat = lines
            for i in 1..<close where lines[i].hasPrefix(indent) {
                flat[i] = String(lines[i].dropFirst(indent.count))
            }
            // Two keys at that indent, or it is one key and its value.
            if entries(flat, close: close).count >= 2 {
                let tabbed = indent.contains("\t")
                let kimi = tabbed || firstKey == firstText
                return (flat, kimi ? .indentedHeader(kimi: true, codex: tabbed) : nil)
            }
        }
        // A comment first: that is the line Kimi trims, and the keys are
        // read where they stand.
        guard firstKey == firstText else { return (trimmed, nil) }
        let codex = indent.contains("\t") || entries(trimmed, close: close).count >= 2
        return (trimmed, codex ? .indentedHeader(kimi: false, codex: true) : nil)
    }

    /// The names a header gives values with `&name`, for telling a `*name`
    /// that stands for one of them from one that stands for nothing.
    private static func anchors(in lines: ArraySlice<String>) -> Set<String> {
        var out = Set<String>()
        for line in lines {
            var rest = Substring(line)
            while let at = rest.firstIndex(of: "&") {
                let name = rest[rest.index(after: at)...].prefix { !" \t,[]{}".contains($0) }
                if !name.isEmpty { out.insert(String(name)) }
                rest = rest[rest.index(after: at)...]
            }
        }
        return out
    }

    /// The header's keys in order, each with the lines its value takes —
    /// walked the way a reader walks them, so a `name:` inside another
    /// key's quoted or block value is that value's text and no key. An
    /// edit that looked for its key on every line found that one, and
    /// rewrote the middle of someone's description.
    static func entries(_ lines: [String], close: Int) -> [(at: Int, key: String, rest: String, end: Int)] {
        var out: [(at: Int, key: String, rest: String, end: Int)] = []
        var i = 1
        while i < close {
            guard let line = keyLine(lines[i]) else { i += 1; continue }
            let end = max(i + 1, SkillFrontmatter.valueEnd(lines, key: i, limit: close))
            out.append((i, line.key, line.rest, end))
            i = end
        }
        return out
    }

    /// A line with nothing on it, or nothing but a comment.
    static func isBlankOrComment(_ line: String) -> Bool {
        let words = line.trimmingCharacters(in: .whitespaces)
        return words.isEmpty || words.hasPrefix("#")
    }

    /// A `...` that ends the header's YAML with nothing after it.
    private static func endsDocument(_ lines: [String], at index: Int, limit: Int) -> Bool {
        lines[index] == "..." && lines[(index + 1)..<limit].allSatisfy(isBlankOrComment)
    }

    /// A header line as a sentence can quote it: trimmed, and cut short.
    private static func shown(_ line: String) -> String {
        let words = line.trimmingCharacters(in: .whitespaces)
        return words.count > 48 ? String(words.prefix(47)) + "…" : words
    }

    // MARK: What only Codex's reader stops at
    //
    // Codex hands the header to a YAML 1.1 reader: a tab may not stand
    // where an indent could, and U+2028, U+2029 and U+0085 end a line.
    // Kimi's reader takes the first for white space and the second for
    // text. Each rule below was measured on both CLIs, and names only
    // what is certain: text in quotes or brackets holds either freely,
    // and a nested value left open on its line ends the looking.

    /// One key's value, as far as a tab or a line separator in it is
    /// YAML's to judge.
    private struct Reach {
        /// The lines between the key and a value that opens below it.
        var before: Range<Int>
        /// The line the value opens on: the key's own, or one below it.
        var opening: Int
        /// The value opens in quotes or brackets.
        var quoted: Bool
        /// The lines past the opening one — past the close of a value in
        /// quotes or brackets.
        var after: Range<Int>
        /// A nested block: keys or items under the key.
        var nested: Bool
        /// A block of text (`|`, `>`), and the indent it states, if any.
        var isBlock: Bool
        var blockIndent: Int?
    }

    /// Nil for a value in quotes or brackets that never closes.
    private static func reach(_ lines: [String], key: Int, end: Int, rest: String) -> Reach? {
        var opening = Substring(withoutComment(rest))
        var at = key
        var j = key + 1
        var nested = false
        if opening.isEmpty {
            while j < end, isBlankOrComment(lines[j]) { j += 1 }
            guard j < end else {
                return Reach(before: (key + 1)..<end, opening: key, quoted: false, after: end..<end,
                             nested: false, isBlock: false, blockIndent: nil)
            }
            opening = Substring(lines[j]).drop { $0 == " " || $0 == "\t" }
            nested = opening == "-" || opening.hasPrefix("- ") || keyLine(String(opening)) != nil
            at = j
            j += 1
        }
        let quoted = opening.first.map { "\"'[{".contains($0) } ?? false
        var past = j
        if quoted, !nested {
            guard let closed = pastQuoted(lines, opening: opening, from: j, to: end) else { return nil }
            past = closed
        }
        let block = nested ? nil : blockHeader(withoutComment(String(opening)))
        return Reach(before: (key + 1)..<(at == key ? key + 1 : at), opening: at, quoted: quoted && !nested,
                     after: past..<end, nested: nested, isBlock: block != nil, blockIndent: block?.indent)
    }

    /// The first line past a value's text in quotes or brackets: `from`
    /// when it closes where it opens; nil when it never closes.
    private static func pastQuoted(_ lines: [String], opening: Substring, from: Int, to: Int) -> Int? {
        guard let first = opening.first else { return from }
        if first == "\"" || first == "'" {
            let scan = QuoteScan(quote: first)
            if scan.closes(in: opening.dropFirst()) { return from }
            return (from..<to).first { scan.closes(in: Substring(lines[$0])) }.map { $0 + 1 }
        }
        var scan = FlowScan()
        if scan.closes(in: opening) { return from }
        var j = from
        while j < to {
            if scan.closes(in: Substring(lines[j])) { return j + 1 }
            j += 1
        }
        return nil
    }

    /// Whether a nested line opens text in quotes or brackets and does
    /// not close it there: what the lines below it are is that text's to
    /// say.
    private static func runsOn(_ line: String) -> Bool {
        var item = Substring(line.trimmingCharacters(in: .whitespaces))
        while item == "-" || item.hasPrefix("- ") { item = item.dropFirst().drop { $0 == " " } }
        let value = keyLine(String(item)).map { Substring($0.rest) } ?? item
        guard let first = value.first else { return false }
        if first == "\"" || first == "'" { return !QuoteScan(quote: first).closes(in: value.dropFirst()) }
        if first == "[" || first == "{" {
            var scan = FlowScan()
            return !scan.closes(in: value)
        }
        return false
    }

    /// The header lines Codex stops at over a tab and the others read
    /// past: a line that holds nothing, or only a comment, and has a tab
    /// in its indent where YAML allows none — opening the line, anywhere;
    /// after spaces, wherever a key could start (the top of the header,
    /// under a key with nothing beside it, after a value in quotes or
    /// brackets) and, in a block of text, short of the block's own
    /// indent. After plain words the same line is read; under a nested
    /// key it is not judged.
    static func tabLines(_ lines: [String], close: Int) -> [Int] {
        let named = anchors(in: lines[1..<close])
        /// What stands above a line: nothing a tab may follow (`strict`),
        /// plain words (`loose`), or a block of text of that indent.
        enum Above { case strict, loose, block(Int?) }
        func stops(_ index: Int, under above: Above) -> Bool {
            let line = lines[index]
            guard isBlankOrComment(line) else { return false }
            if line.hasPrefix("\t") { return true }
            let spaces = line.prefix { $0 == " " }.count
            guard line.dropFirst(spaces).first == "\t" else { return false }
            switch above {
            case .strict: return true
            case .loose: return false
            case .block(let depth): return spaces < (depth ?? Int.max)
            }
        }
        var out: [Int] = []
        var above = Above.strict
        var i = 1
        while i < close {
            guard let line = keyLine(lines[i]) else {
                if stops(i, under: above) { out.append(i) }
                i += 1
                continue
            }
            let key = i
            let end = max(key + 1, SkillFrontmatter.valueEnd(lines, key: key, limit: close))
            i = end
            let isText = line.key == "name" || line.key == "description"
            if case .unreadable = read(line.rest, more: Array(lines[(key + 1)..<end]), isText: isText, anchors: named) {
                // The quotes fix makes one quoted line of it.
                above = .strict
                continue
            }
            guard let span = reach(lines, key: key, end: end, rest: line.rest) else {
                above = .loose
                continue
            }
            out += span.before.filter { stops($0, under: .strict) }
            if span.nested {
                above = .loose
                for j in [span.opening] + Array(span.after) {
                    if isBlankOrComment(lines[j]) {
                        if stops(j, under: .loose) { out.append(j) }
                    } else if runsOn(lines[j]) {
                        break
                    }
                }
            } else if span.isBlock {
                var depth = span.blockIndent
                for j in span.after {
                    if isBlankOrComment(lines[j]) {
                        if stops(j, under: .block(depth)) { out.append(j) }
                    } else if depth == nil, !lines[j].hasPrefix("\t") {
                        depth = lines[j].prefix { $0 == " " }.count
                    }
                }
                above = .block(depth)
            } else {
                // In quotes or brackets, or nothing at all: a key could
                // start on the next line. Plain words run on.
                let opening = span.opening == key ? Substring(withoutComment(line.rest))
                    : Substring(lines[span.opening]).drop { $0 == " " || $0 == "\t" }
                above = span.quoted || opening.isEmpty ? .strict : .loose
                out += span.after.filter { stops($0, under: above) }
            }
        }
        return out
    }

    /// The characters a YAML 1.1 reader ends a line at, besides the line
    /// break itself.
    static let lineSeparators: Set<Character> = ["\u{85}", "\u{2028}", "\u{2029}"]

    /// The header lines that hold a line separator Codex's reader ends
    /// the line at, each as it reads with a space in its place.
    static func separatorLines(_ lines: [String], close: Int) -> [Int: String] {
        guard lines[1..<close].contains(where: { $0.contains(where: lineSeparators.contains) }) else { return [:] }
        let named = anchors(in: lines[1..<close])
        var out: [Int: String] = [:]
        func look(_ index: Int, from: String.Index? = nil, quotesAreText: Bool = true) {
            if let fixed = withoutSeparators(lines[index], from: from ?? lines[index].startIndex,
                                             quotesAreText: quotesAreText) {
                out[index] = fixed
            }
        }
        var i = 1
        while i < close {
            guard let line = keyLine(lines[i]) else {
                if isBlankOrComment(lines[i]) { look(i) }
                i += 1
                continue
            }
            let key = i
            let end = max(key + 1, SkillFrontmatter.valueEnd(lines, key: key, limit: close))
            i = end
            let isText = line.key == "name" || line.key == "description"
            if case .unreadable = read(line.rest, more: Array(lines[(key + 1)..<end]), isText: isText, anchors: named) {
                continue
            }
            guard let span = reach(lines, key: key, end: end, rest: line.rest) else { continue }
            // The key's own line, past its colon: the value's first
            // words, or a comment.
            if !(span.quoted && span.opening == key), !line.rest.isEmpty,
               let start = lines[key].range(of: line.rest, options: .backwards)?.lowerBound {
                look(key, from: start)
            }
            span.before.forEach { look($0) }
            if span.nested {
                for j in [span.opening] + Array(span.after) {
                    if isBlankOrComment(lines[j]) {
                        look(j)
                    } else {
                        look(j, quotesAreText: false)
                        if runsOn(lines[j]) { break }
                    }
                }
            } else {
                if span.opening != key, !span.quoted { look(span.opening) }
                span.after.forEach { look($0) }
            }
        }
        return out
    }

    /// `line` with each line separator Codex's reader would end it at
    /// made a space — one with words after it that are no comment, no
    /// key and no more of an indented value, which it reads. Nil when the
    /// line holds none such. `quotesAreText`: false under a nested key,
    /// where a quote before the separator may be holding it.
    private static func withoutSeparators(_ line: String, from: String.Index, quotesAreText: Bool) -> String? {
        var chars = Array(line)
        var changed = false
        for k in line.distance(from: line.startIndex, to: from)..<chars.count where lineSeparators.contains(chars[k]) {
            if !quotesAreText, chars[..<k].contains(where: { $0 == "\"" || $0 == "'" }) { break }
            let after = chars[(k + 1)...]
            guard let next = after.first, next != " ", next != "\t", next != "#", !lineSeparators.contains(next),
                  keyLine(String(after)) == nil else { continue }
            // After a colon, a dash or a question mark, a space would
            // make a key or an item of the words.
            if k > 0, ":-?".contains(chars[k - 1]) { continue }
            chars[k] = " "
            changed = true
        }
        return changed ? String(chars) : nil
    }

    fileprivate enum Value {
        case empty
        case text(String)
        /// A list, a map, a typed value: valid, and not text. With the
        /// words of one written on the key's own line (`[Read, Grep]`),
        /// for showing; a nested block's are not carried.
        case structure(String)
        /// What YAML refuses where quotes mend it — as written, for the
        /// quotes that fix it.
        case unreadable(String)
        /// What YAML refuses inside a nested block, where quotes around
        /// the key's whole value would turn the block into a sentence:
        /// the line, and whether only a strict reader refuses it.
        case invalid(String, strict: Bool)
    }

    /// A value as YAML reads it. `rest` is the key line's text after the
    /// colon, `more` the lines of its value below. `isText`: a name or a
    /// description, which must READ as text — `123` or `true` does not.
    /// `anchors`: the names the header gives values (`&name`), by which a
    /// `*name` is one of them or nothing.
    fileprivate static func read(_ rest: String, more: [String], isText: Bool,
                                 anchors: Set<String> = []) -> Value {
        if let quote = rest.first, quote == "\"" || quote == "'" {
            return quoted(([rest] + more).joined(separator: "\n"), quote: quote)
        }
        let head = withoutComment(rest)
        if let block = blockHeader(head) {
            let parts = more.map { $0.trimmingCharacters(in: .whitespaces) }
            let flat = parts.filter { !$0.isEmpty }.joined(separator: " ")
            // No text under it: a name or a description that is not
            // there; for another key, an opening YAML cannot read stays
            // one to put quotes on.
            if flat.isEmpty { return block.valid || isText ? .empty : .unreadable("") }
            // YAML takes no opening it cannot read (`|0`, `|++`), no tab
            // to indent the block, and no line of it shallower than its
            // first — the block ends there, and the line is nothing.
            var depth = block.indent
            var ended = false
            var broken = !block.valid
            var text: [String] = []
            for (line, words) in zip(more, parts) {
                let indent = line.prefix { $0 == " " }.count
                if words.isEmpty {
                    // Nothing on the line — unless a tab stands where the
                    // block's indent would: no empty line to YAML, and
                    // the block ends at it (for Kimi; Codex refuses the
                    // file — `tabLines`).
                    if line.count > indent, indent < (depth ?? 1) {
                        ended = true
                    } else if !ended {
                        text.append("")
                    }
                    continue
                }
                if line.hasPrefix("\t") {
                    // A tab is no indent: the block is over. A comment
                    // may follow it; words may not.
                    if words.hasPrefix("#") { ended = true } else { broken = true }
                    continue
                }
                if depth == nil { depth = indent }
                if ended || indent < (depth ?? 0) {
                    // Shallower than the block: it has ended. A comment
                    // may follow it; words may not.
                    if words.hasPrefix("#") { ended = true } else { broken = true }
                } else {
                    text.append(words)
                }
            }
            if broken { return .unreadable(flat) }
            let words = block.folded ? text.filter { !$0.isEmpty }.joined(separator: " ")
                : text.joined(separator: "\n").trimmingCharacters(in: .newlines)
            return words.isEmpty ? .empty : .text(words)
        }
        // Below the key's line a comment says nothing — and is no part
        // of the value: read as one, a comment over a nested block made
        // the block "words that need quotes", and the quotes a sentence
        // of it.
        let content = more.filter { !isBlankOrComment($0) }
        if head.isEmpty {
            guard let first = content.first, let at = more.firstIndex(of: first) else { return .empty }
            let opening = first.trimmingCharacters(in: .whitespaces)
            if opening == "-" || opening.hasPrefix("- ") || keyLine(opening) != nil {
                return nestedFault(more).map { .invalid($0.line, strict: $0.strict) } ?? .structure("")
            }
            // A value that starts on the line below its key.
            if first.hasPrefix("\t") {
                return .unreadable(content.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
            }
            return read(opening, more: Array(more[(at + 1)...]), isText: isText, anchors: anchors)
        }
        let asWritten = ([head] + content.map { withoutComment($0.trimmingCharacters(in: .whitespaces)) })
            .joined(separator: " ")
        if head.hasPrefix("[") || head.hasPrefix("{") {
            if isFlowCollection(asWritten) { return .structure(asWritten) }
            // Words that open with a bracket, on one line: quotes make
            // them the text they are (`[pr-number] [priority]`). A list
            // run over several lines and broken is a list to mend, not
            // a sentence to make of it.
            return content.isEmpty ? .unreadable(asWritten) : .invalid(shown(head), strict: false)
        }
        if head.hasPrefix("!") {
            // `!!str` says what the value is anyway; another `!!` type
            // makes it something other than text; a tag of the file's
            // own YAML does not know.
            if head == "!!str" || head.hasPrefix("!!str ") {
                return read(String(head.dropFirst(5)).trimmingCharacters(in: .whitespaces), more: more,
                            isText: isText, anchors: anchors)
            }
            return head.hasPrefix("!!") ? .structure(asWritten) : .unreadable(asWritten)
        }
        if head.hasPrefix("*") {
            // One word, and a name the header gives a value: that value,
            // whatever it is. Words after it, or a name it gives
            // nothing: YAML reads neither.
            let stands = !head.contains(" ") && content.isEmpty && anchors.contains(String(head.dropFirst()))
            return stands ? .text(head) : .unreadable(asWritten)
        }
        if let first = head.first, "@`,%|>]}".contains(first) { return .unreadable(asWritten) }
        if head == "-" || head.hasPrefix("- ") || head == "?" || head.hasPrefix("? ") {
            return .unreadable(asWritten)
        }
        if head.hasPrefix("&") {
            // A name for the value: the value is what follows it. A bare
            // `&` names nothing.
            let label = head.dropFirst().prefix { $0 != " " }
            guard !label.isEmpty else { return .unreadable(asWritten) }
            return read(head.drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces),
                        more: more, isText: isText, anchors: anchors)
        }
        return plain(head: head, commented: head != rest, more: more, isText: isText)
    }

    /// Plain words, on the key's line (`head`, its comment off — and
    /// whether it had one) and the lines below it.
    private static func plain(head: String, commented: Bool, more: [String], isText: Bool) -> Value {
        var parts = [head]
        // A comment ends plain words, and so does a line indented with a
        // tab: what follows either is no more of the value to YAML.
        var ended = commented
        var broken = false
        for line in more {
            let words = line.trimmingCharacters(in: .whitespaces)
            if words.isEmpty { continue }
            if words.hasPrefix("#") { ended = true; continue }
            if ended || line.hasPrefix("\t") { broken = true }
            let said = withoutComment(words)
            if said != words { ended = true }
            parts.append(said)
        }
        let value = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if broken || parts.contains(where: { $0.contains(": ") || $0.hasSuffix(":") }) { return .unreadable(value) }
        if value.isEmpty || isNull(value) { return .empty }
        if isText, readsAsNonText(value) { return .unreadable(value) }
        return .text(value)
    }

    /// A line without its comment: ` #` starts one, and so does a `#`
    /// that opens the line.
    static func withoutComment(_ line: String) -> String {
        if line.hasPrefix("#") { return "" }
        guard let range = line.range(of: " #") else { return line }
        return String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// A block of text's opening — `|` or `>`, with a `+` or `-` and an
    /// indent digit in either order — and whether YAML takes it: `|0`,
    /// `|++` and `>12` open nothing. Nil for words that merely start
    /// with the sign.
    private static func blockHeader(_ head: String) -> (folded: Bool, valid: Bool, indent: Int?)? {
        guard let first = head.first, first == "|" || first == ">" else { return nil }
        let marks = head.dropFirst()
        guard marks.count <= 3, marks.allSatisfy({ "+-0123456789".contains($0) }) else { return nil }
        let chomps = marks.filter { $0 == "+" || $0 == "-" }.count
        let digits = marks.filter { $0 != "+" && $0 != "-" }
        return (first == ">", chomps <= 1 && digits.count <= 1 && digits != "0", Int(digits))
    }

    /// The first line under a key that YAML refuses and quotes around the
    /// key's value would not mend: a tab used to indent, a key or an item
    /// set back to a column no block is open at, a key given twice in one
    /// map, or a nested value, whole on its line, refused where it
    /// stands. Only what is certain — a nested value that runs past its
    /// own line ends the looking.
    private static func nestedFault(_ more: [String]) -> (line: String, strict: Bool)? {
        // Inside a nested block of text: the indent of the line that
        // opened it. Lines deeper than that are its text.
        var block: Int? = nil
        // The nested blocks open at this line, outermost first: the
        // column each sits at, and the keys a map among them holds.
        var open: [(column: Int, keys: Set<String>)] = []
        enum Standing { case stands, setBack, twice }
        /// Whether a key or an item may stand at `column`: in a block
        /// open there, or opening one deeper than all of them. Set back
        /// past blocks to a column where none was open, it stands
        /// nowhere; and a map takes a key once.
        func standing(at column: Int, key: String?) -> Standing {
            var closed = false
            while let last = open.last, last.column > column {
                open.removeLast()
                closed = true
            }
            if let last = open.last, last.column == column {
                // (`<<` merges another map in, as often as it is written.)
                guard let key, key != "<<" else { return .stands }
                return open[open.count - 1].keys.insert(key).inserted ? .stands : .twice
            }
            if closed { return .setBack }
            open.append((column, key.map { [$0] } ?? []))
            return .stands
        }
        // A line holding only a tab stood inside that block of text: no
        // empty line to YAML — the block ended at it, and more of its
        // text below is text under nothing.
        var cut = false
        for line in more {
            let words = line.trimmingCharacters(in: .whitespaces)
            if words.isEmpty {
                if block != nil, line.hasPrefix("\t") { cut = true }
                continue
            }
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            let indent = lead.prefix { $0 == " " }.count
            if let opened = block {
                if indent > opened {
                    if cut, !words.hasPrefix("#") { return (shown(line), false) }
                    continue
                }
                block = nil
                cut = false
            }
            if words.hasPrefix("#") { continue }
            if lead.contains("\t") { return (shown(line), false) }
            var item = Substring(words)
            var column = indent
            var listed = false
            while item == "-" || item.hasPrefix("- ") {
                guard standing(at: column, key: nil) == .stands else { return (shown(line), false) }
                let text = item.dropFirst().drop { $0 == " " }
                column += item.count - text.count
                item = text
                listed = true
            }
            let value: String
            if let pair = keyLine(String(item)) {
                switch standing(at: column, key: pair.key) {
                case .stands: break
                case .setBack: return (shown(line), false)
                case .twice: return (shown(line), true)
                }
                value = pair.rest
            } else if listed {
                value = String(item)
            } else {
                continue
            }
            guard let first = value.first else { continue }
            if first == "\"" || first == "'" {
                let inside = value.dropFirst()
                guard let close = QuoteScan(quote: first).end(in: inside) else { return nil }
                let after = inside[close...].trimmingCharacters(in: .whitespaces)
                // Closed, with words after it and no colon between.
                if !after.isEmpty, !after.hasPrefix("#"), !after.hasPrefix(":") { return (shown(line), false) }
                continue
            }
            if first == "[" || first == "{" {
                var scan = FlowScan()
                guard scan.closes(in: Substring(value)) else { return nil }
                let after = (scan.tail ?? "").trimmingCharacters(in: .whitespaces)
                if !scan.valid || !(after.isEmpty || after.hasPrefix("#")) { return (shown(line), false) }
                continue
            }
            // A name, a reference to one, a type: what they stand for is
            // written elsewhere.
            if first == "*" || first == "&" || first == "!" { continue }
            if blockHeader(withoutComment(value)) != nil {
                block = indent
                continue
            }
            if case .unreadable = read(value, more: [], isText: false) {
                // Plain words with a colon among them are what a lenient
                // reader still takes; a value that opens with a sign
                // YAML keeps for itself, none does.
                let colon = !"@`,%|>]}-?".contains(first)
                return (shown(line), colon)
            }
        }
        return nil
    }

    /// Finds the quote that closes a quoted value, a line at a time.
    struct QuoteScan {
        let quote: Character

        /// Whether the closing quote is on `line` — the text after the
        /// opening quote, or a later line of the value.
        func closes(in line: Substring) -> Bool {
            end(in: line) != nil
        }

        /// The index just past the closing quote on `line`.
        func end(in line: Substring) -> Substring.Index? {
            var i = line.startIndex
            while i < line.endIndex {
                let c = line[i]
                let next = line.index(after: i)
                if quote == "\"" {
                    // Whatever follows a backslash is not the close; at
                    // a line's end it takes the line break.
                    if c == "\\" {
                        i = next < line.endIndex ? line.index(after: next) : next
                        continue
                    }
                    if c == "\"" { return next }
                } else if c == "'" {
                    // Two together are one apostrophe.
                    if next < line.endIndex, line[next] == "'" {
                        i = line.index(after: next)
                        continue
                    }
                    return next
                }
                i = next
            }
            return nil
        }
    }

    /// Finds where a `[`…`]` or a `{`…`}` closes, a line at a time. A
    /// quote opens a quoted entry only where an entry starts — after a
    /// bracket, a comma or a colon — so the apostrophe in `[user's name]`
    /// is a letter: taken for a quote, it never closed, and the list was
    /// "words that need quotes".
    struct FlowScan {
        private var depth = 0
        private var quote: Character? = nil
        private var entryStarts = true
        /// A quoted entry has just closed: a comma, a colon or a bracket
        /// comes next, or the list does not hold together.
        private var quoteClosed = false
        /// False once words follow a quoted entry with no comma between.
        private(set) var valid = true
        /// What follows the closing bracket on its line.
        private(set) var tail: Substring? = nil

        mutating func closes(in line: Substring) -> Bool {
            var i = line.startIndex
            while i < line.endIndex {
                let c = line[i]
                let next = line.index(after: i)
                if let open = quote {
                    if open == "\"", c == "\\" {
                        i = next < line.endIndex ? line.index(after: next) : next
                        continue
                    }
                    if c == open {
                        if open == "'", next < line.endIndex, line[next] == "'" {
                            i = line.index(after: next)
                            continue
                        }
                        quote = nil
                        quoteClosed = true
                    }
                    i = next
                    continue
                }
                if quoteClosed, !" \t,:]}#".contains(c) { valid = false }
                if c != " ", c != "\t" { quoteClosed = false }
                switch c {
                case "\"", "'":
                    if entryStarts { quote = c }
                    entryStarts = false
                case "[", "{":
                    depth += 1
                    entryStarts = true
                case "]", "}":
                    depth -= 1
                    entryStarts = false
                    if depth <= 0 {
                        tail = line[next...]
                        return true
                    }
                case ",", ":":
                    entryStarts = true
                case " ", "\t":
                    break
                case "#":
                    // A comment, after a space or at the line's start.
                    if i == line.startIndex || line[line.index(before: i)] == " " { return false }
                    entryStarts = false
                default:
                    entryStarts = false
                }
                i = next
            }
            return false
        }
    }

    // MARK: A description written as a list

    /// A description that is a flat list of text, as the one sentence its
    /// items make — each item as YAML reads it, in the order written.
    /// `rest` is the key line's text after the colon, `more` the lines of
    /// the value below it. Nil for anything that is not certainly that:
    /// a map, a list inside a list, an item that is a key and its value,
    /// a number or a yes/no, an empty item, a tab in an indent, a blank
    /// line inside an item. What comes back is written over the list, so
    /// a shape this does not know stays a list for the user to change.
    static func listSentence(rest: String, more: [String]) -> String? {
        let items: [String]
        if rest.hasPrefix("[") {
            guard let flow = flowListItems(rest, more: more) else { return nil }
            items = flow
        } else {
            guard withoutComment(rest).isEmpty, let block = blockListItems(more) else { return nil }
            items = block
        }
        guard !items.isEmpty else { return nil }
        let sentence = joined(items)
        return sentence.isEmpty ? nil : sentence
    }

    /// The items of `- one` / `- two`, every item at one column; a line
    /// set in further than its dash carries the item on.
    private static func blockListItems(_ more: [String]) -> [String]? {
        var column: Int? = nil
        // Each item: its first line's text after the dash, and the lines
        // that follow it down to the next item.
        var raw: [(first: String, rest: [String])] = []
        for line in more {
            let words = line.trimmingCharacters(in: .whitespaces)
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            if words.isEmpty || words.hasPrefix("#") {
                if !raw.isEmpty { raw[raw.count - 1].rest.append(line) }
                continue
            }
            guard !lead.contains("\t") else { return nil }
            let isItem = words == "-" || words.hasPrefix("- ")
            if isItem, column == nil || lead.count == column {
                column = lead.count
                raw.append((String(words.dropFirst()).trimmingCharacters(in: .whitespaces), []))
            } else if let column, lead.count > column, !raw.isEmpty {
                raw[raw.count - 1].rest.append(line)
            } else {
                return nil
            }
        }
        var items: [String] = []
        for entry in raw {
            // Blank lines and comments after an item's last line are
            // between items; a blank line INSIDE an item is a line break
            // YAML keeps, which one sentence would lose.
            var rest = entry.rest
            while let last = rest.last, isBlankOrComment(last) { rest.removeLast() }
            guard !rest.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }),
                  let text = itemText(entry.first, more: rest) else { return nil }
            items.append(text)
        }
        return items
    }

    /// The items of `[one, two]`, whole on the key's line.
    private static func flowListItems(_ rest: String, more: [String]) -> [String]? {
        guard more.allSatisfy(isBlankOrComment) else { return nil }
        var scan = FlowScan()
        guard scan.closes(in: Substring(rest)), scan.valid, let tail = scan.tail else { return nil }
        let after = tail.trimmingCharacters(in: .whitespaces)
        guard after.isEmpty || after.hasPrefix("#") else { return nil }
        let inside = rest[rest.index(after: rest.startIndex)..<rest.index(before: tail.startIndex)]
        // Split at the commas outside quotes. A bracket or a brace inside
        // is a list or a map in the list.
        var pieces: [String] = []
        var piece = ""
        var quote: Character? = nil
        var atStart = true
        let chars = Array(inside)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let open = quote {
                piece.append(c)
                if open == "\"", c == "\\", i + 1 < chars.count {
                    piece.append(chars[i + 1])
                    i += 2
                    continue
                }
                if c == open {
                    if open == "'", i + 1 < chars.count, chars[i + 1] == "'" {
                        piece.append("'")
                        i += 2
                        continue
                    }
                    quote = nil
                }
                i += 1
                continue
            }
            switch c {
            case "[", "]", "{", "}":
                return nil
            case ",":
                pieces.append(piece)
                piece = ""
                atStart = true
            case "\"", "'":
                if atStart { quote = c }
                piece.append(c)
                atStart = false
            case " ", "\t":
                piece.append(c)
            default:
                piece.append(c)
                atStart = false
            }
            i += 1
        }
        guard quote == nil else { return nil }
        // One comma may close the list (`[a, b,]`).
        if !piece.trimmingCharacters(in: .whitespaces).isEmpty || pieces.isEmpty { pieces.append(piece) }
        var items: [String] = []
        for raw in pieces {
            guard let text = itemText(raw.trimmingCharacters(in: .whitespaces), more: []) else { return nil }
            items.append(text)
        }
        return items
    }

    /// One item as the text YAML reads: plain words or a quoted value.
    /// Nil for an empty one, a key and its value, a list, a number, a
    /// yes/no — anything that is not text.
    private static func itemText(_ first: String, more: [String]) -> String? {
        guard !first.isEmpty, first != "-", !first.hasPrefix("- "), keyLine(first) == nil else { return nil }
        guard case .text(let words) = read(first, more: more, isText: true) else { return nil }
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        // Words on one line: a line break kept inside quotes is no part
        // of a sentence.
        return text.isEmpty || text.contains("\n") ? nil : text
    }

    /// Items as one sentence: a full stop after an item that ends on a
    /// letter or a digit, nothing after one that ends on punctuation of
    /// its own, and a space between — none after full-width punctuation,
    /// which carries its own.
    static func joined(_ items: [String]) -> String {
        let closing: Set<Character> = [".", "!", "?", ";", ":", ",", "…", "。", "！", "？", "；", "：", "，", "、"]
        let fullWidth: Set<Character> = ["。", "！", "？", "；", "：", "，", "、"]
        var out = ""
        for (index, item) in items.enumerated() {
            var piece = item
            if index < items.count - 1 {
                // Past a closing quote or bracket, what the item ends on.
                let last = piece.last { !"\"'”’)]）】」』".contains($0) }
                if let last, !closing.contains(last) {
                    piece += isCJK(last) ? "。" : "."
                }
                if let end = piece.last, !fullWidth.contains(end) { piece += " " }
            }
            out += piece
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { s in
            (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
                || (0x3040...0x30FF).contains(s.value) || (0xAC00...0xD7AF).contains(s.value)
                || (0xF900...0xFAFF).contains(s.value)
        }
    }

    /// A quoted value, possibly over several lines: text when its quote
    /// closes with nothing but a comment after it, and — inside double
    /// quotes — every backslash starts an escape YAML defines.
    private static func quoted(_ all: String, quote: Character) -> Value {
        let flat = all.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        let inside = all.dropFirst()
        guard let close = QuoteScan(quote: quote).end(in: inside) else { return .unreadable(flat) }
        // After the close: a comment, on its line and on any below.
        guard inside[close...].components(separatedBy: "\n").allSatisfy(isBlankOrComment) else {
            return .unreadable(flat)
        }
        let inner = String(inside[..<inside.index(before: close)])
        let words: String
        if quote == "\"" {
            let read = unescaped(inner)
            // `\d` is no escape: the words as written, for quotes that
            // say them.
            guard read.valid else { return .unreadable(read.text.trimmingCharacters(in: .whitespaces)) }
            words = read.text
        } else {
            words = inner.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ").replacingOccurrences(of: "''", with: "'")
        }
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .empty : .text(trimmed)
    }

    /// The inside of a double-quoted value with its escapes undone, a
    /// line break folded to a space. `valid` is false when a backslash
    /// starts no escape YAML defines; that backslash and its letter stay
    /// as written. Read with only `\n` and `\t` known, `"发…"` — how
    /// a Python tool writes anything that is not ASCII — came back as
    /// `u53D1…`, the edit sheet opened on that, and a save kept it.
    static func unescaped(_ inner: String) -> (text: String, valid: Bool) {
        let chars = Array(inner)
        var out = ""
        var valid = true
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" {
                while let last = out.last, last == " " || last == "\t" { out.removeLast() }
                i += 1
                while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
                out.append(" ")
                continue
            }
            guard c == "\\" else {
                out.append(c)
                i += 1
                continue
            }
            guard i + 1 < chars.count else {
                out.append("\\")
                valid = false
                break
            }
            let e = chars[i + 1]
            i += 2
            switch e {
            case "0": out.append("\0")
            case "a": out.append("\u{07}")
            case "b": out.append("\u{08}")
            case "t", "\t": out.append("\t")
            case "n": out.append("\n")
            case "v": out.append("\u{0B}")
            case "f": out.append("\u{0C}")
            case "r": out.append("\r")
            case "e": out.append("\u{1B}")
            case " ": out.append(" ")
            case "\"": out.append("\"")
            case "/": out.append("/")
            case "\\": out.append("\\")
            case "N": out.append("\u{85}")
            case "_": out.append("\u{A0}")
            case "L": out.append("\u{2028}")
            case "P": out.append("\u{2029}")
            case "x", "u", "U":
                let width = e == "x" ? 2 : (e == "u" ? 4 : 8)
                let digits = String(chars[i..<min(i + width, chars.count)])
                if digits.count == width, digits.allSatisfy(\.isHexDigit),
                   let code = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(code) {
                    out.unicodeScalars.append(scalar)
                    i += width
                } else {
                    out.append("\\")
                    out.append(e)
                    valid = false
                }
            case "\n":
                // An escaped line break joins two lines with nothing
                // between them.
                while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
            default:
                out.append("\\")
                out.append(e)
                valid = false
            }
        }
        return (out, valid)
    }

    /// Whether text opening with `[` or `{` is one whole flow collection
    /// (`[Read, Grep]`) rather than words that start with a bracket.
    private static func isFlowCollection(_ text: String) -> Bool {
        var scan = FlowScan()
        guard scan.closes(in: Substring(text)), scan.valid, let tail = scan.tail else { return false }
        let rest = tail.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || rest.hasPrefix("#")
    }

    /// YAML's "nothing", as a plain value.
    private static func isNull(_ value: String) -> Bool {
        ["~", "null", "Null", "NULL"].contains(value)
    }

    /// A plain value YAML reads as something other than text — by the
    /// rules of the parser Kimi reads a header with, spelling for
    /// spelling: nothing, true or false, a whole number (decimal, or
    /// `0x`, `0o`, `0b`), a decimal one, infinity, a date, a time. A
    /// name or a description written that way is not one to Kimi.
    static func readsAsNonText(_ value: String) -> Bool {
        if isNull(value) || ["true", "True", "TRUE", "false", "False", "FALSE"].contains(value) { return true }
        func matches(_ pattern: String) -> Bool {
            value.range(of: pattern, options: .regularExpression) != nil
        }
        if !value.hasSuffix("_"),
           matches(#"^[-+]?(0b[01_]*[01][01_]*|0x[0-9a-fA-F_]*[0-9a-fA-F][0-9a-fA-F_]*|0o[0-7_]*[0-7][0-7_]*|[0-9][0-9_]*)$"#)
            || matches(#"^([-+]?[0-9][0-9_]*(\.[0-9_]*)?([eE][-+]?[0-9]+)?|\.[0-9_]+([eE][-+]?[0-9]+)?|[-+]?\.(inf|Inf|INF)|\.(nan|NaN|NAN))$"#) {
            return true
        }
        return matches(#"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#)
            || matches(#"^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}([Tt]|[ \t]+)[0-9]{1,2}:[0-9]{2}:[0-9]{2}(\.[0-9]*)?([ \t]*(Z|[-+][0-9]{1,2}(:[0-9]{2})?))?$"#)
    }

    /// A problem as the end of a sentence — "Kimi Code doesn’t load it:
    /// its SKILL.md has no name."
    static func clause(_ problem: SkillFormatProblem) -> String {
        switch problem {
        case .noHeader:
            return String(localized: "its SKILL.md has no header (the block between --- lines at the top)",
                          comment: "Skills: why an agent skips a skill; ends a sentence")
        case .byteOrderMark:
            return String(localized: "its SKILL.md starts with an invisible byte-order mark",
                          comment: "Skills: why an agent skips a skill; ends a sentence")
        case .noName:
            return String(localized: "its SKILL.md has no name",
                          comment: "Skills: why an agent skips a skill; ends a sentence")
        case .noDescription:
            return String(localized: "its SKILL.md has no description",
                          comment: "Skills: why an agent skips a skill; ends a sentence")
        case .needsQuotes(let key):
            return String(localized: "the value of \(key) in its SKILL.md needs quotes",
                          comment: "Skills: why an agent skips a skill; ends a sentence; placeholder is a header key such as description")
        case .repeatedKey(let key):
            return String(localized: "its SKILL.md gives \(key) twice",
                          comment: "Skills: why an agent skips a skill; ends a sentence; placeholder is a header key such as description")
        case .nameTooLong:
            return String(localized: "its name is longer than 64 characters",
                          comment: "Skills: why Codex skips a skill; ends a sentence")
        case .listDescription:
            return clause(.notText("description"))
        case .notText(let key):
            return String(localized: "the \(key) in its SKILL.md is not text",
                          comment: "Skills: why an agent skips a skill; ends a sentence; placeholder is a header key, name or description")
        case .unclosedHeader:
            return String(localized: "the header of its SKILL.md is never closed (it has no second --- line)",
                          comment: "Skills: why an agent skips a skill; ends a sentence")
        case .unreadableLine(let line), .strictLine(let line):
            return String(localized: "a line in its SKILL.md’s header is not valid YAML: “\(line)”",
                          comment: "Skills: why an agent skips a skill; ends a sentence; placeholder is the line, as written")
        case .unsupportedType:
            return String(localized: "the type in its SKILL.md is not one it runs as a skill",
                          comment: "Skills: why Kimi skips a skill whose header has a type: it does not know; ends a sentence")
        case .indentedHeader:
            return String(localized: "the header of its SKILL.md is indented",
                          comment: "Skills: why an agent skips a skill whose header lines do not start at the margin; ends a sentence")
        case .tabLine:
            return String(localized: "a line in its SKILL.md’s header starts with a tab",
                          comment: "Skills: why Codex skips a skill; ends a sentence")
        case .lineSeparator:
            return String(localized: "its SKILL.md’s header holds an invisible line-break character",
                          comment: "Skills: why Codex skips a skill whose header has a U+2028 line separator or the like in it; ends a sentence")
        }
    }

    /// Why an agent does not load a skill, as the end of a sentence: the
    /// agent's own words where it gave some.
    /// The end of "… doesn’t load it: …" for a folder name Claude offers
    /// no skill under.
    static var folderNameClause: String {
        String(localized: "its folder’s name holds a hidden or direction-changing character, a space at either end or two in a row, a blank other than a space, a stray accent mark, or < or >",
               comment: "Skills: why Claude Code skips a skill, the end of a sentence — its folder's name has a character Claude does not offer a skill under")
    }

    static func clause(_ why: SkillNotLoaded) -> String {
        switch why {
        case .agentSaid(let words): return words
        case .format(let problem): return clause(problem)
        case .folderName: return folderNameClause
        }
    }

    /// "Kimi Code doesn’t load it: its SKILL.md has no name."
    static func notLoadedSentence(_ label: String, _ why: SkillNotLoaded) -> String {
        String(localized: "\(label) doesn’t load it: \(clause(why)).",
               comment: "Skills: an agent skips a skill; placeholders are the agent label and why")
    }

    /// A description read off a skill's body, the way the agents read
    /// one for a skill that states none: its first line of text, a
    /// heading's `#` marks aside, at most 240 characters (Kimi's own
    /// rule). Nil for a body with no text.
    static func description(fromBody body: String) -> String? {
        for raw in body.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            // A rule (`---`, `***`) or a code fence is no sentence.
            guard !line.isEmpty, line.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            return line.count > 240 ? String(line.prefix(239)) + "…" : line
        }
        return nil
    }

    /// `text` with `fixes` made and every other byte kept — each line the
    /// fixes leave alone with the line end it had.
    static func applying(_ fixes: [SkillShareFix], to text: String) -> String {
        var t = text
        let bom = t.hasPrefix("\u{FEFF}")
        if bom { t.removeFirst() }
        var lines = t.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for fix in fixes {
            switch fix {
            case .addHeader(let name, let description):
                lines = ["---", "name: \(SkillFileEdit.yamlScalar(name))",
                         "description: \(SkillFileEdit.yamlScalar(description))", "---", ""] + lines
            case .quote(let keys):
                for key in keys { quoteValue(of: key, in: &lines) }
            case .addName(let name):
                setValue(of: "name", to: SkillFileEdit.yamlScalar(name), in: &lines, first: true)
            case .addDescription(let description), .joinDescription(let description):
                setValue(of: "description", to: SkillFileEdit.yamlScalar(description), in: &lines, first: false)
            case .straightenHeader:
                if let close = headerEnd(lines) { lines = headerLines(lines, close: close) }
            case .clearTabLines:
                if let close = headerEnd(lines) {
                    for index in tabLines(lines, close: close) {
                        lines[index] = String(lines[index].drop { $0 == " " || $0 == "\t" })
                    }
                }
            case .replaceLineSeparators:
                if let close = headerEnd(lines) {
                    for (index, fixed) in separatorLines(lines, close: close) { lines[index] = fixed }
                }
            case .removeByteOrderMark, .onlyWhenCalledForCodex, .onlyWhenCalledInSkill:
                break
            }
        }
        var out = lines.joined(separator: "\n")
        if fixes.contains(.onlyWhenCalledInSkill) {
            out = SkillFileEdit.updated(out, description: nil, body: nil, onlyWhenCalled: true)
        }
        return (bom && !fixes.contains(.removeByteOrderMark) ? "\u{FEFF}" : "")
            + SkillFileEdit.withLineEnds(of: t, out)
    }

    /// A key's value rewritten as one quoted line — the text YAML could
    /// not read, as written.
    private static func quoteValue(of key: String, in lines: inout [String]) {
        guard let close = headerEnd(lines),
              let entry = entries(lines, close: close).first(where: { $0.key == key }) else { return }
        guard case .unreadable(let asWritten) = read(entry.rest, more: Array(lines[(entry.at + 1)..<entry.end]),
                                                     isText: key == "name" || key == "description")
        else { return }
        lines.replaceSubrange(entry.at..<entry.end, with: ["\(key): \(SkillFileEdit.yamlScalar(asWritten))"])
    }

    /// Set a key the header lacks, or holds with no value: in place of
    /// the key's own line when it is there (a comment under it stays),
    /// else at the top (`first`) or the bottom of the header.
    private static func setValue(of key: String, to scalar: String, in lines: inout [String], first: Bool) {
        guard let close = headerEnd(lines) else { return }
        let line = "\(key): \(scalar)"
        if let entry = entries(lines, close: close).first(where: { $0.key == key }) {
            // An empty value can still span lines — `""` closed on the
            // next one, a block of blank lines: those go with it.
            let spans = lines[(entry.at + 1)..<entry.end].contains { !isBlankOrComment($0) }
            lines.replaceSubrange(entry.at..<(spans ? entry.end : entry.at + 1), with: [line])
        } else {
            lines.insert(line, at: first ? 1 : close)
        }
    }

    /// What in a skill `agent` does not read: the header keys only Claude
    /// Code acts on (the list Kimi Code's own importer warns about),
    /// Claude Code's `!`…`` commands, Kimi Code's own keys, and Codex's
    /// own file. Nothing a share is refused over — a share is one click,
    /// and Help says what each agent leaves unread.
    static func ignored(by agent: String, keys: [String], body: String, codexYaml: String?) -> [String] {
        var out: [String] = []
        if agent != SkillAgent.claude {
            let claudeOnly = ["allowed-tools", "disallowed-tools", "context", "agent", "hooks", "paths"]
            out += claudeOnly.filter(keys.contains)
            if body.range(of: "!`[^`\n]+`", options: .regularExpression) != nil { out.append("!`…`") }
        }
        if agent != SkillAgent.kimi {
            out += ["type", "has-sub-skill"].filter(keys.contains)
        }
        if agent != SkillAgent.codex, let yaml = codexYaml {
            let own = yaml.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
                .compactMap { keyLine($0)?.key }
            if own.contains(where: { $0 != "policy" }) { out.append(SkillCodexPolicy.relativePath) }
        }
        return out
    }
}

/// A change SipAI makes to a skill's own files before sharing it, so the
/// agent it goes to loads it as the others do.
enum SkillShareFix: Hashable {
    /// Take away the byte-order mark before the header (Codex).
    case removeByteOrderMark
    /// Add a header naming the skill after its folder and describing it
    /// by its first line — what Claude Code already calls and shows it.
    case addHeader(name: String, description: String)
    /// Add `name:`, the folder's name the others already call it by.
    case addName(String)
    /// Add `description:`, read off the body as the others read it.
    case addDescription(String)
    /// Write a description that is a list as the one sentence its items
    /// make.
    case joinDescription(String)
    /// Put quotes around these keys' values.
    case quote([String])
    /// Move the header's keys to the margin: the first one, or all of
    /// them where all are set in alike. Made before any fix that looks
    /// for a key, which looks at the margin.
    case straightenHeader
    /// Take the tab off header lines that hold nothing else, or only a
    /// comment (Codex).
    case clearTabLines
    /// Put a space where the header holds a line-separator character
    /// (Codex).
    case replaceLineSeparators
    /// Write Codex's `agents/openai.yaml`: the skill's
    /// `disable-model-invocation: true`, in Codex's own words.
    case onlyWhenCalledForCodex
    /// Add `disable-model-invocation: true` — Codex's "only when I call
    /// it", in the words Claude Code and Kimi Code read.
    case onlyWhenCalledInSkill
}

/// Why a skill cannot be shared with an agent.
enum SkillShareRefusal: Equatable {
    /// The agent has another skill of this name, and would use one.
    case nameTaken
    /// There is no SKILL.md to read.
    case noSkillFile
    /// The agent skips it, and the fix is not SipAI's to make.
    case cannotFix(SkillFormatProblem)
    /// The fixes it needs are in files SipAI does not change.
    case notSipAIs(SkillFormatProblem)
    /// Its folder's name is one the agent offers no skill under, and the
    /// link SipAI makes for it takes that name (Claude: `ClaudeSkillNames`).
    case folderName
}

/// What sharing a skill with an agent takes, worked out before anything
/// is written: the fixes its files need, what in it the agent does not
/// read, or why it cannot go to that agent at all.
struct SkillShareCheck: Equatable {
    var fixes: [SkillShareFix] = []
    /// What in it the agent does not read (`SkillFormat.ignored`).
    var ignored: [String] = []
    var refusal: SkillShareRefusal? = nil
    /// The SKILL.md the check read. The fixes are made only to that
    /// text: a file that changed since is left alone.
    var skillText: String? = nil
    /// "Only when I call it" is set where the skill came from and could
    /// not be written where the new agent reads it — the files are not
    /// SipAI's to change, or Codex's own file is in a form SipAI does not
    /// edit. The share still goes through, and the new agent may then use
    /// the skill on its own: the one thing a share changes that the user
    /// did not ask for, so the page says it once the share is done.
    var lostOnlyWhenCalled = false

    /// `writable`: the files are where SipAI writes. `carrySettings`:
    /// "only when I call it" goes over in the agent's own words — a
    /// share, not a repair of what is already there.
    static func make(skillText: String?, codexYaml: String?, folderName: String, target: String,
                     writable: Bool, nameTaken: Bool, carrySettings: Bool = true) -> SkillShareCheck {
        var check = SkillShareCheck(skillText: skillText)
        if nameTaken {
            check.refusal = .nameTaken
            return check
        }
        if target == SkillAgent.claude, ClaudeSkillNames.refusesFolderName(folderName) {
            check.refusal = .folderName
            return check
        }
        guard let text = skillText else {
            check.refusal = .noSkillFile
            return check
        }
        let problems = SkillFormat.problems(in: text).filter { SkillFormat.skips($0, agent: target) }
        if let unfixable = problems.first(where: { !SkillFormat.fixable($0) }) {
            check.refusal = .cannotFix(unfixable)
            return check
        }
        let bare = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let lines = bare.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let body = (SkillFormat.headerEnd(lines).map { lines[($0 + 1)...] } ?? lines[...]).joined(separator: "\n")
        var fixes: [SkillShareFix] = []
        if problems.contains(.byteOrderMark) { fixes.append(.removeByteOrderMark) }
        let indented = problems.contains { if case .indentedHeader = $0 { return true } else { return false } }
        if problems.contains(.noHeader) {
            guard let description = SkillFormat.description(fromBody: body) else {
                check.refusal = .cannotFix(.noDescription)
                return check
            }
            fixes.append(.addHeader(name: folderName, description: description))
        } else {
            let quoted = problems.compactMap { p -> String? in
                if case .needsQuotes(let key) = p { return key }
                return nil
            }
            if !quoted.isEmpty { fixes.append(.quote(quoted)) }
            let listed = problems.lazy.compactMap { p -> String? in
                if case .listDescription(let sentence) = p { return sentence }
                return nil
            }.first
            if let listed { fixes.append(.joinDescription(listed)) }
            if problems.contains(.noName) { fixes.append(.addName(folderName)) }
            if problems.contains(.noDescription) {
                guard let description = SkillFormat.description(fromBody: body) else {
                    check.refusal = .cannotFix(.noDescription)
                    return check
                }
                fixes.append(.addDescription(description))
            }
            // A fix finds its key at the margin: a header set in is
            // straightened first, whichever agent it is for.
            if let close = SkillFormat.headerEnd(lines),
               indented || (!quoted.isEmpty || listed != nil || problems.contains(.noName)
                            || problems.contains(.noDescription))
                && SkillFormat.headerLines(lines, close: close) != lines {
                fixes.insert(.straightenHeader, at: problems.contains(.byteOrderMark) ? 1 : 0)
            }
            if problems.contains(.tabLine) { fixes.append(.clearTabLines) }
            if problems.contains(.lineSeparator) { fixes.append(.replaceLineSeparators) }
        }
        if !fixes.isEmpty, !writable, let first = problems.first {
            check.refusal = .notSipAIs(first)
            return check
        }
        let keys = SkillFormat.headerKeys(in: text)
        check.ignored = SkillFormat.ignored(by: target, keys: keys, body: body, codexYaml: codexYaml)
        if carrySettings {
            let skillSays = SkillFrontmatter.parse(text).disableModelInvocation
            let codexSays = !SkillCodexPolicy.allowsImplicitInvocation(yaml: codexYaml)
            if target == SkillAgent.codex, skillSays, !codexSays {
                // Codex reads its own file; one SipAI cannot edit safely
                // leaves the setting behind (`lostOnlyWhenCalled`).
                if writable, (try? SkillFileEdit.codexPolicy(codexYaml, onlyWhenCalled: true)) != nil {
                    fixes.append(.onlyWhenCalledForCodex)
                } else {
                    check.ignored.append("disable-model-invocation")
                    check.lostOnlyWhenCalled = true
                }
            } else if target != SkillAgent.codex, codexSays, !skillSays {
                if writable {
                    fixes.append(.onlyWhenCalledInSkill)
                } else {
                    if !check.ignored.contains(SkillCodexPolicy.relativePath) {
                        check.ignored.append(SkillCodexPolicy.relativePath)
                    }
                    check.lostOnlyWhenCalled = true
                }
            }
        }
        check.fixes = fixes
        return check
    }
}

// MARK: - Scan

/// One agent's view of one skill: where it sees it, and what it is.
struct SkillEntry: Equatable {
    let agent: String
    /// The name the agent calls it by.
    let name: String
    let description: String
    let scope: SkillScope
    let rootKind: SkillRootKind
    /// The entry in the folder the agent reads: a skill folder, or a link.
    let entryPath: String
    /// The real folder after links, nil for a broken link.
    let realPath: String?
    let isLink: Bool
    var frontmatter: SkillFrontmatter
    /// Codex's own file says the model must not use it on its own.
    var codexImplicitOff = false
    var sourceLabel: String? = nil
    /// What in its SKILL.md keeps some agent from loading it
    /// (`SkillFormat.problems`).
    var formatProblems: [SkillFormatProblem] = []
}

/// A skills folder's entries, read without following anything an agent
/// would not follow: dot-prefixed entries (staging, `.system` read on its
/// own) are skipped, and an entry counts only with a SKILL.md inside.
enum SkillScan {
    /// The canonical path of an existing file or folder, `/private`
    /// included — the spelling Codex matches a skill's path by.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    struct Found: Equatable {
        let root: SkillRoot
        let dirName: String
        let entryPath: String
        let realPath: String?
        let isLink: Bool
        let skillText: String?
        let codexYaml: String?
    }

    /// Read every skill under `roots`. `fm` is injected for the harness.
    static func read(roots: [SkillRoot], fm: FileManager = .default) -> [Found] {
        var out: [Found] = []
        for root in roots {
            let dirs: [(URL, String)]
            if root.nested {
                let buckets = (try? fm.contentsOfDirectory(atPath: root.url.path)) ?? []
                dirs = buckets.filter { !$0.hasPrefix(".") }.flatMap { bucket -> [(URL, String)] in
                    let b = root.url.appendingPathComponent(bucket, isDirectory: true)
                    return ((try? fm.contentsOfDirectory(atPath: b.path)) ?? [])
                        .filter { !$0.hasPrefix(".") }
                        .map { (b.appendingPathComponent($0, isDirectory: true), $0) }
                }
            } else {
                dirs = ((try? fm.contentsOfDirectory(atPath: root.url.path)) ?? [])
                    .filter { !$0.hasPrefix(".") }
                    .map { (root.url.appendingPathComponent($0, isDirectory: true), $0) }
            }
            for (url, name) in dirs.sorted(by: { $0.1 < $1.1 }) {
                var isLink = false
                if let attrs = try? fm.attributesOfItem(atPath: url.path),
                   (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                    isLink = true
                }
                let real = realPath(url.path)
                if isLink && real == nil {
                    out.append(Found(root: root, dirName: name, entryPath: url.path,
                                     realPath: nil, isLink: true, skillText: nil, codexYaml: nil))
                    continue
                }
                let skill = url.appendingPathComponent("SKILL.md")
                guard fm.fileExists(atPath: skill.path) else { continue }
                let text = readPrefix(skill, limit: 256 * 1024)
                let yaml = readPrefix(url.appendingPathComponent(SkillCodexPolicy.relativePath),
                                      limit: 64 * 1024)
                out.append(Found(root: root, dirName: name, entryPath: url.path, realPath: real,
                                 isLink: isLink, skillText: text, codexYaml: yaml))
            }
        }
        return out
    }

    static func readPrefix(_ url: URL, limit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// One `SkillEntry` per agent that reads each found skill.
    static func entries(from found: [Found]) -> [SkillEntry] {
        var out: [SkillEntry] = []
        for f in found {
            let fm = SkillFrontmatter.parse(f.skillText ?? "")
            let name = fm.name ?? f.dirName
            let problems = f.skillText.map(SkillFormat.problems(in:)) ?? []
            for agent in f.root.readers {
                out.append(SkillEntry(
                    agent: agent,
                    name: agent == SkillAgent.claude
                        ? ClaudeSkillNames.offered(frontmatterName: fm.name, folder: f.dirName) : name,
                    description: fm.description,
                    scope: f.root.scope, rootKind: f.root.kind,
                    entryPath: f.entryPath, realPath: f.realPath, isLink: f.isLink,
                    frontmatter: fm,
                    codexImplicitOff: !SkillCodexPolicy.allowsImplicitInvocation(yaml: f.codexYaml),
                    sourceLabel: f.root.sourceLabel,
                    formatProblems: problems))
            }
        }
        return out
    }
}

// MARK: - The manager's rows

/// The state an agent keeps a skill in.
enum SkillState: String, Hashable {
    case on
    /// "Only when I call it": the model never uses it on its own.
    case userInvocableOnly
    /// Claude: listed to the model by name only.
    case nameOnly
    case off
}

/// Where a row's real files live.
enum SkillHome: Hashable {
    case library
    case agentFolder(String)
    case common
    /// A folder no agent and not the library: a link's target elsewhere.
    case elsewhere
    case readOnly(String)
}

enum SkillProblem: Hashable {
    /// Another skill with the same name reaches the same agent.
    case clash
    /// A link whose target is gone.
    case brokenLink
}

/// One skill in the manager: one real folder, and every agent that has it.
struct SkillRow: Identifiable, Equatable {
    /// The real folder, or `ro:<agent>:<source>:<name>` for a skill only
    /// its agent manages.
    let id: String
    let name: String
    let description: String
    let scope: SkillScope
    let home: SkillHome
    /// Nil for a read-only skill an agent reported without a path.
    let realPath: String?
    var entries: [String: SkillEntry]
    var states: [String: SkillState] = [:]
    var problems: Set<SkillProblem> = []
    var frontmatter: SkillFrontmatter
    /// What in its SKILL.md keeps some agent from loading it.
    var formatProblems: [SkillFormatProblem] = []
    /// An agent's own words for why it did not load the skill — Codex's
    /// skill listing reports each file it skipped.
    var loadErrors: [String: String] = [:]

    var agents: [String] { SkillAgent.all.filter { entries[$0] != nil } }
    var isReadOnly: Bool { if case .readOnly = home { return true }; return false }
    /// Whether the skill's files sit where SipAI writes: its library, an
    /// agent's own folder, the common folder. A folder linked in from
    /// anywhere else is the user's to edit, and an agent's own skills
    /// are the agent's.
    var isManaged: Bool {
        switch home {
        case .library, .agentFolder, .common: return true
        case .elsewhere, .readOnly: return false
        }
    }

    /// Why `agent` does not load this skill, nil when nothing says it
    /// does not. Codex's own report where it gave one; for Kimi, which
    /// has no listing to ask, the measured rules (`SkillFormat`); Claude
    /// loads every SKILL.md shape, and offers no skill under a folder name
    /// it refuses (`ClaudeSkillNames`) — the name of the entry in the
    /// folder it reads, a link's own name included.
    func notLoaded(by agent: String) -> SkillNotLoaded? {
        guard let entry = entries[agent] else { return nil }
        if let words = loadErrors[agent] { return .agentSaid(words) }
        if agent == SkillAgent.claude,
           ClaudeSkillNames.refusesFolderName((entry.entryPath as NSString).lastPathComponent) {
            return .folderName
        }
        guard agent == SkillAgent.kimi,
              let first = formatProblems.first(where: { SkillFormat.skips($0, agent: agent) })
        else { return nil }
        return .format(first)
    }
}

/// One agent in a skill's Share With menu.
struct SkillShareTarget: Identifiable, Equatable {
    let agent: String
    /// It has the skill already.
    let has: Bool
    var id: String { agent }
}

/// The hint beside a skill's name: "shared with Codex", "shared with
/// Kimi Code in the common folder", "in the common folder".
struct SkillShareHint: Equatable {
    /// The other listed agents that have the skill.
    let sharedWith: [String]
    /// Its files sit in `.agents/skills`, which Codex and Kimi Code both
    /// read with no link of their own — said in the hint, since nothing
    /// else on the row tells such a skill from one SipAI links.
    let inCommonFolder: Bool
}

/// Why an agent does not load a skill.
enum SkillNotLoaded: Equatable {
    /// The agent said so, in these words.
    case agentSaid(String)
    /// Its SKILL.md is not in the agent's shape.
    case format(SkillFormatProblem)
    /// Its folder's name is one the agent offers no skill under
    /// (Claude: `ClaudeSkillNames`).
    case folderName
}

/// Settings → Agent Skills lists each agent's skills under that agent. A skill
/// several agents have is one real folder, drawn under each of them with
/// the others named beside it.
enum SkillListing {
    /// The rows `agent` has.
    static func rows(of agent: String, in rows: [SkillRow]) -> [SkillRow] {
        rows.filter { $0.entries[agent] != nil }
    }

    /// The rows `agent` reaches through a skills folder of `level` itself
    /// — a subfolder's own skills, out of a read of that subfolder that
    /// also holds the global ones and the rest of its project's.
    static func rows(of agent: String, in rows: [SkillRow], at level: SkillLevel) -> [SkillRow] {
        rows.filter { row in row.entries[agent].map { level.holds($0.entryPath) } ?? false }
    }

    /// Library skills no listed agent has, kept in `level`'s own library.
    static func unused(_ rows: [SkillRow], listed: [String], at level: SkillLevel) -> [SkillRow] {
        unused(rows, listed: listed).filter { row in row.realPath.map(level.holds) ?? false }
    }

    /// The rows with anything at `level` itself — an agent's entry in one
    /// of its skills folders, or their own files in its library: a
    /// subfolder's read cut down to that subfolder's own, once, before
    /// each agent's are picked out of it.
    static func rows(_ rows: [SkillRow], at level: SkillLevel) -> [SkillRow] {
        rows.filter { row in
            row.entries.values.contains { level.holds($0.entryPath) } || (row.realPath.map(level.holds) ?? false)
        }
    }

    /// The same for a caller with only the folder's path in hand. Each
    /// call makes the level — a file-system call — so a page, which asks
    /// on every pass, keeps the `SkillLevel` its walk made.
    static func rows(of agent: String, in rows: [SkillRow], at level: String) -> [SkillRow] {
        self.rows(of: agent, in: rows, at: SkillLevel(path: level))
    }

    static func unused(_ rows: [SkillRow], listed: [String], at level: String) -> [SkillRow] {
        unused(rows, listed: listed, at: SkillLevel(path: level))
    }

    /// The other listed agents that have `row` — the names its
    /// "shared with" hint gives under `agent`.
    static func sharedWith(_ row: SkillRow, besides agent: String, listed: [String]) -> [String] {
        row.agents.filter { $0 != agent && listed.contains($0) }
    }

    /// What the hint beside `row`'s name says under `agent`, nil when it
    /// has nothing to say: the skill is that agent's alone, in a folder
    /// of its own.
    static func hint(_ row: SkillRow, under agent: String, listed: [String]) -> SkillShareHint? {
        let others = sharedWith(row, besides: agent, listed: listed)
        let common = row.home == .common
        guard !others.isEmpty || common else { return nil }
        return SkillShareHint(sharedWith: others, inCommonFolder: common)
    }

    /// Skills in SipAI's library that no LISTED agent has. One only an
    /// agent that is not listed has — a skill taken from Codex out of
    /// the folder Codex and Kimi both read is linked for Kimi, installed
    /// or not — is drawn under no agent: left out of here too it sat in
    /// the library where nothing showed it, to share or to delete.
    static func unused(_ rows: [SkillRow], listed: [String]) -> [SkillRow] {
        rows.filter { row in row.home == .library && !row.agents.contains(where: listed.contains) }
    }

    /// The agents `row` can be shared with from `agent`'s section: every
    /// other listed agent, each with whether it already has the skill.
    /// A skill an agent manages itself is shared with nobody, and a link
    /// to nothing with nobody either.
    static func shareTargets(_ row: SkillRow, from agent: String?,
                             listed: [String]) -> [SkillShareTarget] {
        guard !row.isReadOnly, row.realPath != nil else { return [] }
        return listed.filter { $0 != agent }.map { SkillShareTarget(agent: $0, has: row.entries[$0] != nil) }
    }

    /// Whether `agent` already has ANOTHER skill called `row`'s name —
    /// sharing would give it two of one name, and it would use one.
    static func nameTaken(by agent: String, for row: SkillRow, in rows: [SkillRow]) -> Bool {
        let key = row.name.lowercased()
        return rows.contains { other in
            other.id != row.id && (other.entries[agent]?.name.lowercased() ?? "") == key
        }
    }
}

enum SkillGrouping {
    /// Group a scan's entries into rows, plus rows for library skills no
    /// agent has, and rows for read-only skills an agent reported.
    static func rows(entries: [SkillEntry], library: [SkillScan.Found],
                     roots: [SkillRoot], extra: [SkillRow] = []) -> [SkillRow] {
        var byId: [String: SkillRow] = [:]
        var order: [String] = []
        // The folder a real path sits in is the DEEPEST one that holds
        // it: an agent's built-in skills live inside its own skills
        // folder (`skills/.system`), and read as that outer folder's they
        // would be drawn, and edited, as the user's own.
        let bases = roots.map { ($0, SkillScan.realPath($0.url.path) ?? $0.url.path) }
        func home(for real: String) -> SkillHome {
            var best: (root: SkillRoot, base: String)? = nil
            for (root, base) in bases where real.hasPrefix(base + "/") {
                if best == nil || base.count > best!.base.count { best = (root, base) }
            }
            guard let (root, base) = best else { return .elsewhere }
            if root.kind == .readOnly { return .readOnly(root.sourceLabel ?? "") }
            // SipAI's to manage only where it writes: a folder that is a
            // direct child of the library, an agent's own folder or the
            // common one — the test every write makes. One nested deeper
            // (`skills/pack/inner`), or in a folder between the project
            // root and the working one, is somewhere else to it: called
            // managed, its Delete promised the Trash and was refused.
            guard root.managed, (real as NSString).deletingLastPathComponent == base else { return .elsewhere }
            switch root.kind {
            case .library: return .library
            case .common: return .common
            case .own, .readOnly: return .agentFolder(root.readers.first ?? "")
            }
        }
        for e in entries {
            let id: String
            let rowHome: SkillHome
            if e.rootKind == .readOnly {
                id = "ro:\(e.agent):\(e.sourceLabel ?? ""):\(e.name)"
                rowHome = .readOnly(e.sourceLabel ?? "")
            } else if let real = e.realPath {
                id = real
                rowHome = home(for: real)
            } else {
                id = "broken:" + e.entryPath
                rowHome = .elsewhere
            }
            if var row = byId[id] {
                if row.entries[e.agent] == nil { row.entries[e.agent] = e }
                byId[id] = row
            } else {
                var row = SkillRow(id: id, name: e.name, description: e.description,
                                   scope: e.scope, home: rowHome, realPath: e.realPath,
                                   entries: [e.agent: e], frontmatter: e.frontmatter,
                                   formatProblems: e.formatProblems)
                if e.realPath == nil { row.problems.insert(.brokenLink) }
                byId[id] = row
                order.append(id)
            }
        }
        // Library skills nobody links to yet. (A LINK someone put in the
        // library is not a skill SipAI keeps there: its folder is
        // elsewhere, and nothing here is SipAI's to bin.)
        for f in library where f.root.kind == .library && !f.isLink {
            guard let real = f.realPath, byId[real] == nil else { continue }
            let fm = SkillFrontmatter.parse(f.skillText ?? "")
            byId[real] = SkillRow(id: real, name: fm.name ?? f.dirName,
                                  description: fm.description, scope: f.root.scope,
                                  home: .library, realPath: real, entries: [:],
                                  frontmatter: fm,
                                  formatProblems: f.skillText.map(SkillFormat.problems(in:)) ?? [])
            order.append(real)
        }
        for row in extra where byId[row.id] == nil {
            byId[row.id] = row
            order.append(row.id)
        }
        var rows = order.compactMap { byId[$0] }
        // A clash: two rows of one name reaching one agent.
        for agent in SkillAgent.all {
            var seen: [String: [Int]] = [:]
            for (i, row) in rows.enumerated() where row.entries[agent] != nil {
                seen[row.name.lowercased(), default: []].append(i)
            }
            for (_, idx) in seen where idx.count > 1 {
                for i in idx { rows[i].problems.insert(.clash) }
            }
        }
        return rows
    }

    /// The state an agent keeps a skill in, from what the skill's own
    /// files say — the base the CLIs' own reports refine.
    static func fileState(of entry: SkillEntry) -> SkillState {
        switch entry.agent {
        case SkillAgent.codex:
            return entry.codexImplicitOff ? .userInvocableOnly : .on
        case SkillAgent.claude, SkillAgent.kimi:
            return entry.frontmatter.disableModelInvocation ? .userInvocableOnly : .on
        default:
            // No agent the skills code names reads the skill there.
            return .off
        }
    }
}

/// What claude answered to the two listing requests SipAI sends it over
/// stream-json input (`ClaudeSkillProbe`): `initialize`, for every skill
/// a user can call, and `get_skills_dialog`, for each one's state.
struct ClaudeSkillListing {
    static let commandsRequest = "sipai-skills-commands"
    static let dialogRequest = "sipai-skills-dialog"

    var commands: [[String: Any]] = []
    var dialog: [[String: Any]] = []
    /// Whether each request was answered with what was asked.
    var listed = false
    var statesKnown = false
    private var answered: Set<String> = []

    /// Both requests have been answered — a refusal is an answer.
    var isComplete: Bool { answered.count == 2 }

    /// One line of claude's stdout. A claude that does not know a request
    /// refuses it at once — `subtype: "error"`, "Unsupported control
    /// request subtype", and no `response` — and that ends the wait for
    /// it: read as no answer, the listing would sit out its whole
    /// ceiling on a claude that will never say more, on every read, and
    /// throw away the half that did answer.
    mutating func note(_ obj: [String: Any]) {
        guard (obj["type"] as? String) == "control_response",
              let response = obj["response"] as? [String: Any],
              let id = response["request_id"] as? String else { return }
        let inner = response["response"] as? [String: Any]
        switch id {
        case Self.commandsRequest:
            commands = (inner?["commands"] as? [[String: Any]]) ?? []
            listed = inner != nil
            answered.insert(id)
        case Self.dialogRequest:
            dialog = (inner?["skills"] as? [[String: Any]]) ?? []
            statesKnown = inner != nil
            answered.insert(id)
        default:
            break
        }
    }
}

/// Claude's own account of each skill's state — what its skills menu
/// shows, answered by the `get_skills_dialog` control request — matched
/// to the rows a scan made.
enum ClaudeSkillDialog {
    /// Claude's state names, as the dialog and its own writer spell them.
    static func state(from value: String?) -> SkillState? {
        switch value {
        case "on": return .on
        case "off": return .off
        case "name-only": return .nameOnly
        case "user-invocable-only": return .userInvocableOnly
        default: return nil
        }
    }

    static func stateValue(_ state: SkillState) -> String {
        switch state {
        case .on: return "on"
        case .off: return "off"
        case .nameOnly: return "name-only"
        case .userInvocableOnly: return "user-invocable-only"
        }
    }

    /// "source|name" → state, for every row of the dialog's answer.
    ///
    /// Claude files a skill under where it came from (`user`, `project`,
    /// `plugin`, `claude.ai sync`). A claude.ai skill is NAMED with a
    /// namespace there (`anthropic-skills:docs`) and shown bare
    /// (`display_name`), which is the name its folder and its command
    /// carry — so a row is kept under both spellings.
    static func states(_ rows: [[String: Any]]) -> [String: SkillState] {
        var out: [String: SkillState] = [:]
        for row in rows {
            guard let name = row["name"] as? String,
                  let state = state(from: row["state"] as? String) else { continue }
            let source = (row["source"] as? String) ?? ""
            out["\(source)|\(name)"] = state
            if let shown = row["display_name"] as? String, !shown.isEmpty, shown != name {
                out["\(source)|\(shown)"] = state
            }
        }
        return out
    }

    /// The source claude files an entry's skill under.
    static func source(of entry: SkillEntry) -> String {
        if entry.rootKind == .readOnly {
            switch entry.sourceLabel {
            case "claude.ai": return "claude.ai sync"
            case "Plugin": return "plugin"
            default: return ""
            }
        }
        return entry.scope == .global ? "user" : "project"
    }

    /// What claude says an entry's state is, nil when it said nothing
    /// about it — the files' own account then stands.
    static func state(of entry: SkillEntry, in states: [String: SkillState]) -> SkillState? {
        states["\(source(of: entry))|\(entry.name)"]
    }
}

// MARK: - Names

enum SkillName {
    static let maxLength = 64

    /// The one name rule every agent accepts: lowercase letters, digits
    /// and single hyphens, at most 64 characters.
    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxLength else { return false }
        return name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil
    }

    /// A folder's or a file's name made into one that passes `isValid`:
    /// lower-cased, every run of other characters a single hyphen.
    static func suggestion(_ raw: String) -> String {
        var out = ""
        for ch in raw.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if !out.isEmpty, !out.hasSuffix("-") {
                out.append("-")
            }
        }
        var capped = String(out.prefix(maxLength))
        while capped.hasSuffix("-") { capped.removeLast() }
        return capped
    }

}

/// The names Claude Code offers a skill under — its own name test, read
/// out of its bundle and measured against it: a skill whose FOLDER name
/// fails it is not offered at all, and a `name:` that fails it is ignored,
/// the skill offered under its folder's name. Listing such a skill as
/// Claude's would offer a load that never happens. SipAI's own names never
/// fail it (`SkillName.isValid`); a skill made elsewhere can.
///
/// Refused: an empty name or one over 256 UTF-16 units; `<` or `>`; a
/// space at either end or two in a row; every control, format,
/// private-use, surrogate, unassigned, line- and paragraph-separator
/// character; every default-ignorable one (joiners, selectors, fillers);
/// every blank but a plain space, the braille blank and the
/// object-replacement, null-notehead, hieroglyph and Khitan fillers; a
/// keycap mark with no keycap; a combining mark at the start or after
/// anything but a letter, a number or a mark, nine marks in a row, a
/// soft-dotted letter with a combining dot above, a dotless i or j with a
/// mark. Claude reads an emoji sequence as one symbol first, so a
/// text-style selector, a joiner, a keycap mark, a skin tone or a tag
/// inside one is fine — a selector before a skin tone, or a joiner with
/// no emoji after it, is not — and it takes a joiner or non-joiner out of
/// an Indic or Arabic word before looking. A plain space inside, an
/// accent, CJK, a colon inside or at the end are offered. Not told apart
/// here, so such a skill is listed as Claude's and its load fails: a
/// script-specific mark on a Latin letter, which Claude also refuses.
enum ClaudeSkillNames {
    /// Blanks and fillers Claude refuses beside those a category names:
    /// the braille blank, the object replacement mark, the musical null
    /// notehead, the Egyptian hieroglyph fillers and the Khitan filler.
    private static let fillers: Set<UInt32> = [0x2800, 0xFFFC, 0x1D159, 0x13441, 0x13442, 0x16FE4]

    /// Whether Claude refuses `name` as a skill's `name:`.
    static func refuses(_ name: String) -> Bool {
        if name.isEmpty || name.utf16.count > 256 { return true }
        if name.hasPrefix(" ") || name.hasSuffix(" ") || name.contains("  ") { return true }
        let scalars = Array(name.unicodeScalars)
        for (i, s) in scalars.enumerated() {
            if s == "<" || s == ">" { return true }
            if s.value == 0xFE0F, i + 1 < scalars.count, (0x1F3FB...0x1F3FF).contains(scalars[i + 1].value) {
                return true
            }
        }
        var previous: Unicode.Scalar? = nil
        var base: Unicode.Scalar? = nil
        var marksInRow = 0
        var at = 0
        for cluster in name {
            let cs = Array(cluster.unicodeScalars)
            defer { at += cs.count }
            if isEmojiCluster(cs) {
                if refusesEmojiCluster(cs) { return true }
                previous = cs.last
                base = cs.last
                marksInRow = 0
                continue
            }
            for (j, s) in cs.enumerated() {
                let next: Unicode.Scalar? = at + j + 1 < scalars.count ? scalars[at + j + 1] : nil
                if isMarkLike(s) {
                    guard let p = previous, isLetter(p) || isNumber(p) || isMarkLike(p) else { return true }
                    marksInRow += 1
                    if marksInRow >= 9 { return true }
                    if s.value == 0x0307, let b = base, b.properties.isSoftDotted { return true }
                    if let b = base, b.value == 0x0131 || b.value == 0x0237, previous == b, isMark(s) { return true }
                } else {
                    marksInRow = 0
                }
                if refusesScalar(s, after: base, before: next) { return true }
                previous = s
                if !isMarkLike(s) { base = s }
            }
        }
        return false
    }

    /// Whether Claude refuses `name` as a skill's folder name: the `name:`
    /// test, and no colon at the start.
    static func refusesFolderName(_ name: String) -> Bool {
        name.hasPrefix(":") || refuses(name)
    }

    /// The name Claude offers a skill under: its `name:`, unless Claude
    /// ignores that one, then its folder's.
    static func offered(frontmatterName: String?, folder: String) -> String {
        guard let name = frontmatterName, !refuses(name) else { return folder }
        return name
    }

    /// One character outside an emoji sequence. `base` is the nearest
    /// earlier character that is not a mark, `next` the one after.
    private static func refusesScalar(_ s: Unicode.Scalar, after base: Unicode.Scalar?,
                                      before next: Unicode.Scalar?) -> Bool {
        switch s.properties.generalCategory {
        case .control, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
            return true
        case .format:
            // A joiner or non-joiner inside an Indic word — or a non-joiner
            // inside an Arabic one — is taken out before Claude looks.
            if s.value == 0x200C || s.value == 0x200D, let base, let next,
               isLetter(base), isLetter(next),
               (isIndic(base) && isIndic(next)) || (s.value == 0x200C && isArabic(base) && isArabic(next)) {
                return false
            }
            return true
        case .spaceSeparator:
            return s != " "
        default:
            return s.properties.isDefaultIgnorableCodePoint || fillers.contains(s.value) || s.value == 0x20E3
        }
    }

    /// A grapheme cluster Claude reads as one emoji: an emoji character
    /// (not an ASCII one) and whatever joins it, or a digit, `#` or `*`
    /// made a keycap.
    private static func isEmojiCluster(_ cs: [Unicode.Scalar]) -> Bool {
        guard let first = cs.first else { return false }
        if first.isASCII {
            return cs.count == 3 && cs[1].value == 0xFE0F && cs[2].value == 0x20E3 && first.properties.isEmoji
        }
        return first.properties.isEmoji
    }

    /// What Claude refuses inside an emoji sequence: a text-style selector
    /// anywhere but after a text-default emoji, a keycap mark not closing
    /// a keycap, a joiner with no emoji after it, a tag on anything but
    /// the black flag, and any other mark or format character.
    private static func refusesEmojiCluster(_ cs: [Unicode.Scalar]) -> Bool {
        let tagged = cs[0].value == 0x1F3F4
        for (i, s) in cs.enumerated() where i > 0 {
            let p = cs[i - 1]
            switch s.value {
            case 0xFE0F:
                if !(p.properties.isEmoji && !p.properties.isEmojiPresentation) { return true }
            case 0x20E3:
                if !(p.value == 0xFE0F && cs[0].isASCII) { return true }
            case 0x200D:
                if i + 1 >= cs.count || !cs[i + 1].properties.isEmoji { return true }
            case 0xE0020...0xE007F:
                if !tagged { return true }
            case 0x1F3FB...0x1F3FF, 0x1F1E6...0x1F1FF:
                break
            default:
                if isMark(s) || s.properties.generalCategory == .format { return true }
            }
        }
        return false
    }

    private static func isMark(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// A mark, or a Hangul vowel or final consonant letter, which Claude
    /// counts with the marks.
    private static func isMarkLike(_ s: Unicode.Scalar) -> Bool {
        isMark(s) || (0x1160...0x11FF).contains(s.value) || (0xD7B0...0xD7FF).contains(s.value)
    }

    private static func isLetter(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    private static func isNumber(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// Devanagari through Sinhala.
    private static func isIndic(_ s: Unicode.Scalar) -> Bool { (0x0900...0x0DFF).contains(s.value) }

    private static func isArabic(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0600...0x06FF, 0x0750...0x077F, 0x0870...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return true
        default: return false
        }
    }

    /// The oldest claude that offers an `--add-dir` folder's namesake — a
    /// skill whose name another skill already holds — as `<folder>:<name>`;
    /// an older one leaves it unreachable.
    static let namesakeFloor = "2.1.309"

    /// That name, `<folder>:<name>`, with the folder as `--add-dir` was
    /// handed it: `packages/web` handed relative is `packages/web:review`,
    /// while an absolute path is shortened to its last folders and loads
    /// by that shortened name only — so the picker's name holds only when
    /// claude is handed the path below the session's folder.
    static func namesake(_ name: String, in folder: String) -> String {
        folder + ":" + name
    }
}

/// Whether a new or added skill may take a name.
enum SkillNameCheck {
    /// Taken: the library has a skill of that name in that scope already,
    /// or an agent it is going to has one — its own, a plugin's or a
    /// built-in, in either scope. An agent offered two skills of one name
    /// uses one, so a copy of Codex's `imagegen` left with that name, or
    /// a folder skill named after a global one, arrived tagged Clash.
    static func isTaken(_ name: String, scope: SkillScope, agents: Set<String>, in rows: [SkillRow]) -> Bool {
        let key = name.lowercased()
        return rows.contains { row in
            guard row.name.lowercased() == key else { return false }
            return (row.scope == scope && row.home == .library) || row.agents.contains(where: agents.contains)
        }
    }
}

// MARK: - Editing a skill's files

/// Byte-preserving edits to a skill's own files. Every line SipAI does
/// not own is kept exactly as it was.
enum SkillFileEdit {
    enum Failure: Error, Equatable {
        /// The YAML is in a form SipAI does not edit (flow style, tabs).
        case unsupportedYAML
    }

    /// A new SKILL.md.
    static func newSkill(name: String, description: String, body: String,
                         onlyWhenCalled: Bool) -> String {
        var lines = ["---", "name: \(yamlScalar(name))", "description: \(yamlScalar(description))"]
        if onlyWhenCalled { lines.append("disable-model-invocation: true") }
        lines.append("---")
        let trimmedBody = body.trimmingCharacters(in: .newlines)
        return lines.joined(separator: "\n") + "\n\n" + trimmedBody + "\n"
    }

    /// SKILL.md with its description and body replaced and
    /// `disable-model-invocation` set or cleared; every other
    /// frontmatter line is kept as it was.
    static func updated(_ text: String, description: String?, body: String?,
                        onlyWhenCalled: Bool?) -> String {
        // A byte-order mark is kept where it was, and read past: seen as
        // text it hides the opening fence, and a second frontmatter would
        // be written above the first.
        let bom = text.hasPrefix("\u{FEFF}")
        if bom {
            return "\u{FEFF}" + updated(String(text.dropFirst()), description: description,
                                        body: body, onlyWhenCalled: onlyWhenCalled)
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        // The new body as lines of its own, whatever it was typed or
        // pasted with.
        let body = body?.replacingOccurrences(of: "\r\n", with: "\n")
        guard var end = SkillFormat.headerEnd(lines) else {
            // No frontmatter, and nothing asked that one would hold: the
            // file gains none — an edit that changes nothing leaves every
            // byte, and a new body is the whole of the new text.
            if description == nil, onlyWhenCalled != true {
                guard let body else { return text }
                return withLineEnds(of: text, body.trimmingCharacters(in: .newlines) + "\n")
            }
            // One is added holding only what was asked, above the text
            // that was there — every line of that as it was.
            var head = ["---"]
            if let description { head.append("description: \(yamlScalar(description))") }
            if onlyWhenCalled == true { head.append("disable-model-invocation: true") }
            head.append("---")
            let rest = body.map { $0.trimmingCharacters(in: .newlines) + "\n" } ?? normalized
            return withLineEnds(of: text, head.joined(separator: "\n") + "\n\n" + rest)
        }
        // A header whose keys are set in from the margin is straightened
        // before a key is looked for — at the margin, where a new one
        // would be written beside the keys that were not found. Only
        // once something changes: an edit that changes nothing leaves
        // every byte.
        let written = lines
        lines = SkillFormat.headerLines(lines, close: end)
        let straight = lines
        // A key as the reader takes it (`SkillFormat.keyLine`): spelled
        // exactly first, then in any case.
        func keyIndex(_ matches: (String) -> Bool) -> Int? {
            let keys = SkillFormat.entries(lines, close: end)
            return (keys.first { matches($0.key) } ?? keys.first { matches($0.key.lowercased()) })?.at
        }
        if let description {
            let line = "description: \(yamlScalar(description))"
            if let i = keyIndex({ $0 == "description" }) {
                // The whole value goes: every line a folded or block
                // description spans, a blank line between two of its
                // paragraphs included — and a quoted one's lines down to
                // its closing quote.
                let j = SkillFrontmatter.valueEnd(lines, key: i, limit: end)
                lines.replaceSubrange(i..<j, with: [line])
                end -= (j - i - 1)
            } else {
                lines.insert(line, at: end)
                end += 1
            }
        }
        if let onlyWhenCalled {
            let line = "disable-model-invocation: true"
            if let i = keyIndex(SkillFrontmatter.isOnlyWhenCalledKey) {
                let j = SkillFrontmatter.valueEnd(lines, key: i, limit: end)
                var says = false
                if let entry = SkillFormat.keyLine(lines[i]),
                   case .text(let value) = SkillFormat.read(entry.rest, more: Array(lines[(i + 1)..<j]), isText: false) {
                    says = SkillFrontmatter.isTrue(value)
                }
                if !onlyWhenCalled {
                    lines.removeSubrange(i..<j)
                    end -= (j - i)
                } else if !says {
                    // Said already, in whatever spelling, the line stays
                    // as it is.
                    lines.replaceSubrange(i..<j, with: [line])
                    end -= (j - i - 1)
                }
            } else if onlyWhenCalled {
                lines.insert(line, at: end)
                end += 1
            }
        }
        if lines == straight { lines = written }
        let out: String
        if let body {
            out = lines[0...end].joined(separator: "\n") + "\n\n"
                + body.trimmingCharacters(in: .newlines) + "\n"
        } else {
            out = lines.joined(separator: "\n")
        }
        return withLineEnds(of: text, out)
    }

    /// `edited` — text with `\n` line ends, made from `original` — with
    /// the line ends `original` had: every line the edit left alone
    /// keeps its own, and the lines it wrote take the one of the line
    /// above them. One choice for the whole file rewrote every line end
    /// of a file that mixes the two, on a save that changed one word.
    static func withLineEnds(of original: String, _ edited: String) -> String {
        guard original.contains("\r\n") else { return edited }
        let was = original.components(separatedBy: "\n")
        let now = edited.components(separatedBy: "\n")
        /// A line's text without the CR of its line end. The last piece
        /// has no line end.
        func bare(_ index: Int) -> Substring {
            let line = was[index]
            return index < was.count - 1 && line.hasSuffix("\r") ? line.dropLast() : Substring(line)
        }
        var head = 0
        while head < was.count, head < now.count, bare(head) == now[head] { head += 1 }
        var tail = 0
        while tail < was.count - head, tail < now.count - head,
              bare(was.count - 1 - tail) == now[now.count - 1 - tail] { tail += 1 }
        let crlf = head > 0 ? was[head - 1].hasSuffix("\r") : was[0].hasSuffix("\r")
        var out = Array(was[..<head])
        for i in head..<(now.count - tail) {
            out.append(now[i] + (crlf && i < now.count - 1 ? "\r" : ""))
        }
        out += was[(was.count - tail)...]
        return out.joined(separator: "\n")
    }

    /// SKILL.md with its `name:` set to `name` — for a skill copied in
    /// under a name of the user's choosing. Agents call a skill by this
    /// line when it is there, so a copy left with its source's name is
    /// still that skill to them (and clashes with it). A file with no
    /// frontmatter is named by its folder, and is left as it is.
    static func renamed(_ text: String, to name: String) -> String {
        let bom = text.hasPrefix("\u{FEFF}")
        let bare = bom ? String(text.dropFirst()) : text
        var lines = bare.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let close = SkillFormat.headerEnd(lines) else { return text }
        // Keys set in from the margin are found — and a name written —
        // only once they are at it.
        lines = SkillFormat.headerLines(lines, close: close)
        let line = "name: \(yamlScalar(name))"
        let keys = SkillFormat.entries(lines, close: close)
        if let entry = keys.first(where: { $0.key == "name" }) ?? keys.first(where: { $0.key.lowercased() == "name" }) {
            let i = entry.at
            let j = entry.end
            guard Array(lines[i..<j]) != [line] else { return text }
            lines.replaceSubrange(i..<j, with: [line])
        } else {
            lines.insert(line, at: 1)
        }
        return (bom ? "\u{FEFF}" : "") + withLineEnds(of: bare, lines.joined(separator: "\n"))
    }

    /// `agents/openai.yaml` with `policy.allow_implicit_invocation` set to
    /// false (`onlyWhenCalled`) or removed; nil when the file should not
    /// exist (nothing left in it that SipAI wrote).
    static func codexPolicy(_ yaml: String?, onlyWhenCalled: Bool) throws -> String? {
        guard let yaml, !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return onlyWhenCalled ? "policy:\n  allow_implicit_invocation: false\n" : nil
        }
        if yaml.contains("\t") || yaml.contains("{") { throw Failure.unsupportedYAML }
        var lines = yaml.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let policyIndex = lines.firstIndex { $0.hasPrefix("policy:") }
        if let p = policyIndex {
            let rest = SkillFormat.withoutComment(String(lines[p].dropFirst("policy:".count)))
                .trimmingCharacters(in: .whitespaces)
            guard rest.isEmpty else { throw Failure.unsupportedYAML }
            // The block: the indented lines below `policy:`, a comment at
            // the margin among them. Its own keys sit at the indent of
            // its FIRST line — a list or a map under one of them sits
            // deeper, and a key written at that depth would land inside
            // it.
            var end = p + 1
            while end < lines.count, lines[end].isEmpty || lines[end].first == " " || lines[end].hasPrefix("#") {
                end += 1
            }
            let children = (p + 1..<end).filter { !SkillFormat.isBlankOrComment(lines[$0]) }
            let indent = children.first.map { String(lines[$0].prefix { $0 == " " }) } ?? "  "
            let keyLine = children.first { lines[$0].hasPrefix(indent + "allow_implicit_invocation:") }
            if onlyWhenCalled {
                if let k = keyLine {
                    lines[k] = indent + "allow_implicit_invocation: false"
                } else {
                    lines.insert(indent + "allow_implicit_invocation: false", at: p + 1)
                }
            } else if let k = keyLine {
                lines.remove(at: k)
                // `policy:` goes with its key only when that was all it
                // held; anything else under it keeps its parent.
                if children.count == 1 { lines.remove(at: p) }
            }
        } else if onlyWhenCalled {
            if let last = lines.last, last.isEmpty { lines.removeLast() }
            lines += ["policy:", "  allow_implicit_invocation: false", ""]
        }
        let out = lines.joined(separator: "\n")
        return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : withLineEnds(of: yaml, out)
    }

    /// A YAML scalar for one line: plain when it is safe, quoted when it
    /// is not — and when a YAML reader would take it for anything but
    /// text, so a skill named `2024` or `2024-01-15` is named, not
    /// numbered or dated. A character no YAML file may hold as it is
    /// goes in as its escape.
    static func yamlScalar(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        func isControl(_ scalar: Unicode.Scalar) -> Bool {
            (scalar.value < 0x20 && scalar != "\t") || (0x7F...0x9F).contains(scalar.value)
                || scalar == "\u{2028}" || scalar == "\u{2029}"
        }
        let special = ":#{}[],&*!|>'\"%@`"
        // What some YAML reader takes for a yes or a no, whatever its
        // case — older ones than Kimi's count `yes`, `on` and `n` too.
        let loose = ["true", "false", "null", "yes", "no", "on", "off", "y", "n"].contains(flat.lowercased())
        guard flat.isEmpty || loose || flat.contains(where: { special.contains($0) })
                || flat.unicodeScalars.contains(where: isControl)
                || flat.hasPrefix("-") || flat.hasPrefix("?") || SkillFormat.readsAsNonText(flat) else {
            return flat
        }
        var escaped = ""
        for scalar in flat.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\u{2028}": escaped += "\\L"
            case "\u{2029}": escaped += "\\P"
            case _ where isControl(scalar): escaped += String(format: "\\x%02X", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }
}

// MARK: - Preloading: what loads now

/// What a conversation shows about the skills in it, in order.
enum SkillEvidence: Equatable {
    /// Skills loaded at this point (a load SipAI sent, one the user
    /// typed, one the model made).
    case loaded([String])
    /// The agent summarised the conversation: what it held before is
    /// gone. SipAI runs each turn as a new process, and neither Claude
    /// nor Codex carries a skill loaded in an earlier process across a
    /// summary. Kimi keeps the messages the user sent — the skills they
    /// started among them — while they fit its budget for them, and says
    /// in its own record when they did not: what survived such a summary
    /// is listed again right after this (`SkillEvidenceReader.evidence`).
    case compaction
}

enum SkillPreload {
    /// The chosen skills the next message must load: every pick the
    /// conversation does not hold since its newest compaction, in the
    /// order they were chosen.
    static func toLoad(picks: [String], evidence: [SkillEvidence]) -> [String] {
        var held = Set<String>()
        for item in evidence {
            switch item {
            case .loaded(let names): names.forEach { held.insert($0.lowercased()) }
            case .compaction: held.removeAll()
            }
        }
        var seen = Set<String>()
        return picks.filter { pick in
            let key = pick.lowercased()
            guard !held.contains(key), seen.insert(key).inserted else { return false }
            return true
        }
    }

    /// Which picks the conversation holds right now.
    static func held(picks: [String], evidence: [SkillEvidence]) -> Set<String> {
        let pending = Set(toLoad(picks: picks, evidence: evidence).map { $0.lowercased() })
        return Set(picks.map { $0.lowercased() }).subtracting(pending)
    }
}

/// One skill a session's chip can load.
struct SkillChoice: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let description: String
    let scope: SkillScope
    /// "Plugin", "Built-in" — a skill the agent manages itself.
    let sourceLabel: String?
    /// Why it cannot be loaded here, nil when it can.
    let unavailable: String?
    /// Codex: the canonical path a mention must carry.
    let codexPath: String?
    /// A skill of a SUBFOLDER of the session's folder: that subfolder,
    /// as the walk spells it (`SkillRoots.subfolders`). A session is not
    /// started with a subfolder's skills, so loading one takes the turn
    /// naming the place (`SkillSubfolderReach`). Nil for the session
    /// folder's own skills and the global ones.
    var subfolder: String? = nil
    /// Its path below the session's folder ("web", "packages/web") — the
    /// picker's group title.
    var subfolderName: String? = nil
    /// What Claude is handed with `--add-dir` for it: the subfolder's
    /// path below the session's folder, which is also what Claude prefixes
    /// a namesake with (`ClaudeSkillNames.namesake`); the whole path when
    /// the subfolder is spelled from elsewhere.
    var claudeAddDir: String? = nil
    /// The agent's skills folder in that subfolder that holds it — what
    /// Codex is handed as an extra place to read skills from.
    var skillsFolder: String? = nil
}

/// How a session reaches a skill that lives in a subfolder of its folder
/// — one it is not STARTED with: Codex and Kimi never read below where a
/// session starts, and Claude adds a subfolder's skills only once it
/// works on a file there. Measured on the installed tools, token-free:
///
/// * Claude: `--add-dir <subfolder>` lists that folder's skills as the
///   project's, and the quiet `/name` loads one. Nothing else of it
///   comes along (its CLAUDE.md is not read), and the folder is inside
///   the session's, so no file access is added.
/// * Codex through its app-server (every mode but Chat only, on a codex
///   that has it): `skills/extraRoots/set` with the subfolder's skills
///   folders lists them, and the mention loads one. `codex exec` — Chat
///   only, and every mode on a codex without the app-server — has no way:
///   a mention by the skill's path, `--add-dir` and `-c skills.config`
///   all load nothing.
/// * Kimi: no way from a session started above — its front end's extra
///   session folders add no skills.
///
/// Each is offered only on a tool at least as new as the one it was
/// measured on (`claudeFloor`, `codexFloor`): an older one may take the
/// flag or the call and list nothing, and the load would then go as
/// plain text, with nothing said.
enum SkillSubfolderReach {
    /// The oldest claude measured to list a folder's skills under
    /// `--add-dir`, and the oldest codex measured to take
    /// `skills/extraRoots/set`.
    static let claudeFloor = "2.1.287"
    static let codexFloor = "0.160.0"

    /// What a Codex send can do with a subfolder's skill.
    enum CodexSend: Equatable {
        /// It runs through Codex's app-server, told of the subfolder first.
        case appServer
        /// It runs `codex exec`, which has no way to load one.
        case exec
        /// Its mode runs through the app-server, and the installed Codex
        /// has none — or one older than the call was measured on.
        case needsNewer
    }

    /// The Codex send for a turn: `usesFrontEnd` — its mode is one that
    /// runs through the app-server where there is one (every mode but Chat
    /// only);
    /// `frontEndMissing` — the installed Codex is known to have none;
    /// `measured` — it is not known to be older than `codexFloor`. A
    /// Codex whose version has not been read yet is held to neither: the
    /// turn itself waits for the version, and one that then runs through
    /// `codex exec` is sent no subfolder skill (`AgentRunner.runOnce`).
    static func codexSend(usesFrontEnd: Bool, frontEndMissing: Bool, measured: Bool) -> CodexSend {
        guard usesFrontEnd else { return .exec }
        return frontEndMissing || !measured ? .needsNewer : .appServer
    }

    /// Why `agent` cannot load a subfolder's skill in this send, nil when
    /// it can. `claudeTooOld`: the installed Claude is known to be older
    /// than `claudeFloor`.
    static func refusal(agent: String, codex: CodexSend = .exec, claudeTooOld: Bool = false) -> String? {
        switch agent {
        case SkillAgent.claude:
            return claudeTooOld ? newerAgentNeeded : nil
        case SkillAgent.codex:
            switch codex {
            case .appServer:
                return nil
            case .needsNewer:
                return newerAgentNeeded
            case .exec:
                return String(localized: "Loads from a subfolder in any mode but Chat only, or in a session started in the subfolder.",
                              comment: "Skill chip: a Codex skill in a subfolder of the session's folder cannot be loaded in the chosen mode (Chat only)")
            }
        case SkillAgent.kimi:
            return String(localized: "Loads only in a session started in its subfolder.",
                          comment: "Skill chip: a skill in a subfolder of the session's folder that this agent cannot load from the session")
        default:
            return String(localized: "SipAI doesn’t support this for this agent yet.",
                          comment: "Refusal for an agent SipAI has no code for")
        }
    }

    /// The installed agent is too old to load a skill from SipAI this way.
    static var newerAgentNeeded: String {
        String(localized: "Needs a newer version of this agent. Update it in Settings → Updates.",
               comment: "Skill chip and scheduled-run reason: the installed agent CLI is too old to load a skill by name from SipAI")
    }
}

/// What one refresh of one folder found.
struct SkillSnapshot: Equatable {
    /// The working folder the rows were read for; nil reads the global
    /// skills alone.
    let folder: String?
    let projectRoot: String?
    var rows: [SkillRow]
    /// Whether each CLI answered. A missing answer leaves the files' own
    /// account standing.
    var claudeAnswered = false
    var codexAnswered = false
    /// Codex: the SKILL.md path codex itself reported for each skill
    /// name — the only spelling a linked mention matches.
    var codexPaths: [String: String] = [:]
    /// Every path codex reported. Two skills can share a name, and the
    /// name then finds only the first: a skill whose own SKILL.md codex
    /// listed is addressed by that path, never by its namesake's.
    var codexListed: Set<String> = []

    /// The path codex knows `entry`'s skill by: its own when codex listed
    /// it, else the one codex gave for the name, else its own unlisted.
    func codexPath(for entry: SkillEntry) -> String? {
        let own = entry.realPath.map { ($0 as NSString).appendingPathComponent("SKILL.md") }
        if let own, codexListed.contains(own) { return own }
        return codexPaths[entry.name] ?? own
    }
}

enum SkillSwitchRule {
    /// Whether `agent` has a switch of its own for this skill, and if not
    /// why — the pane draws the reason beside the disabled choice.
    static func refusal(row: SkillRow, agent: String, label: String) -> String? {
        switch agent {
        case SkillAgent.kimi:
            return String(localized: "\(label) has no switch for a skill. Delete it from \(label) to take it away.",
                          comment: "Skills: why Kimi's off switch is disabled; placeholders are the agent label, twice")
        case SkillAgent.claude where row.isReadOnly:
            return String(localized: "\(label) doesn’t switch this skill one by one.",
                          comment: "Skills: why Claude's switch is disabled for a plugin or bundled skill; placeholder is the agent label")
        case SkillAgent.claude, SkillAgent.codex:
            return nil
        default:
            return String(localized: "SipAI doesn’t support this for this agent yet.",
                          comment: "Refusal for an agent SipAI has no code for")
        }
    }
}

/// Reads whose answer must be FRESH for whoever asks: one at a time per
/// key, and a caller that arrives while one is under way waits for a
/// read that BEGAN after it asked.
///
/// Returning at once to a late caller hands it whatever is in hand — the
/// answer of a read that started before the change the caller just made,
/// or, before the first read lands, nothing at all, which a skill lookup
/// reads as "this agent has no such skill". Two scheduled tasks sharing
/// a folder and a slot are exactly that pair of callers.
@MainActor
final class FreshReads {
    private var running: [String: Task<Void, Never>] = [:]
    private var again: Set<String> = []

    func isRunning(_ key: String) -> Bool { running[key] != nil }

    /// Whether the read of `key` under way will be followed by another:
    /// someone has already asked for one that begins after now.
    func willRunAgain(_ key: String) -> Bool { again.contains(key) }

    /// Return once the read of `key` under way — and any already asked
    /// to follow it — has finished, asking for none. For a caller that
    /// needs a read IN HAND rather than one that began after it asked:
    /// "a read is under way" is not a snapshot.
    func join(_ key: String) async {
        if let task = running[key] { await task.value }
    }

    /// Run `read` for `key`, returning once a run of it that began after
    /// this call has finished. A caller that joins a read under way asks
    /// for one more and waits for that one; its own `read` is not run —
    /// one key is one read, whoever asks for it.
    func run(_ key: String, _ read: @escaping @MainActor () async -> Void) async {
        if let task = running[key] {
            again.insert(key)
            await task.value
            return
        }
        let task = Task { @MainActor in
            repeat {
                self.again.remove(key)
                await read()
            } while self.again.contains(key)
            // No suspension between the last check and here: a caller
            // either joined this run or starts the next.
            self.running[key] = nil
        }
        running[key] = task
        await task.value
    }
}

/// The skills the manager last read, for a view that names a skill by
/// its name alone (the Skill approval card): the skill of that name
/// `agent` has in `folder` — the session's own. `SkillCatalog` installs
/// the lookup (`row(named:agent:folder:)`); until it has, nothing is
/// known.
enum SkillDirectory {
    @MainActor static var lookup: (_ name: String, _ agent: String, _ folder: URL?) -> SkillRow? = { _, _, _ in nil }
}

/// One row of a conversation, as far as skills are concerned.
enum SkillTranscriptMark {
    /// A message from the user: what SipAI loaded with it, and its text
    /// (a skill the user typed is read off it).
    case user(text: String, loadedSkills: [String])
    /// A tool call — the model's own Skill call is a load.
    case tool(name: String, input: [String: Any])
    /// The agent said or did something: whatever was sent before this
    /// reached it. Only a LIVE row needs it (`delivered`) — a row read
    /// off the transcript is there because the agent recorded it.
    case answered
    /// The agent summarised the conversation. `keepsUserLoads`: its own
    /// record of the summary says every message the user sent before it
    /// is still in the conversation, whole — Kimi's, when it did not have
    /// to trim them (`KimiSessionScanner.compactionKeepsUserMessages`).
    /// Never true of Claude or Codex.
    case compaction(keepsUserLoads: Bool)
}

enum SkillEvidenceReader {
    /// The conversation's skill history, oldest first.
    ///
    /// A summary is the agent's own to describe. Claude re-attaches only
    /// what its own process loaded and Codex drops an injected skill
    /// (both measured), so theirs empties the conversation of skills and
    /// a pick goes again with the next message. Kimi's keeps every
    /// message the USER sent — a skill they started is one, its whole
    /// text — within a budget of its own (20,000 tokens; past it the
    /// oldest is cut to 2,000 and the middle dropped, measured: a long
    /// skill loaded first came back without its end), and drops a skill
    /// the MODEL loaded itself. Its record says which happened
    /// (`keepsUserLoads`): kept whole, the user's loads are still held —
    /// sent again there would be two copies, and one more at every later
    /// summary — and trimmed, they go again like anyone's.
    static func evidence(_ marks: [SkillTranscriptMark], agent: String) -> [SkillEvidence] {
        var out: [SkillEvidence] = []
        // What the user's own messages loaded since the last summary that
        // did not keep them.
        var userLoads: [String] = []
        for mark in marks {
            switch mark {
            case .user(let text, let loaded):
                let names = loaded + typedSkills(in: text, agent: agent)
                if !names.isEmpty {
                    out.append(.loaded(names))
                    userLoads += names
                }
            case .tool(let name, let input):
                if let skill = SkillRecords.skillToolName(name: name, input: input) {
                    out.append(.loaded([skill]))
                }
            case .answered:
                break
            case .compaction(let keepsUserLoads):
                out.append(.compaction)
                if keepsUserLoads {
                    if !userLoads.isEmpty { out.append(.loaded(userLoads)) }
                } else {
                    userLoads = []
                }
            }
        }
        return out
    }

    /// The marks of a turn's LIVE rows, less every message the agent
    /// never answered. A live row is drawn the moment Send is pressed —
    /// before the agent has been started, let alone read anything — so a
    /// send that never ran (the tool missing, a failed start, a Stop in
    /// the first instant) would otherwise count as a load: the chosen
    /// skill is then never sent again, and the chip says "Loaded", until
    /// the session is reopened. `turnInFlight` keeps the newest message
    /// while its turn is still running: it is being delivered now.
    static func delivered(_ marks: [SkillTranscriptMark], turnInFlight: Bool) -> [SkillTranscriptMark] {
        var out: [SkillTranscriptMark] = []
        var unanswered: Int? = nil
        for mark in marks {
            switch mark {
            case .user:
                if let index = unanswered { out.remove(at: index) }
                unanswered = out.count
                out.append(mark)
            case .tool, .answered:
                unanswered = nil
                out.append(mark)
            case .compaction:
                out.append(mark)
            }
        }
        if let index = unanswered, !turnInFlight { out.remove(at: index) }
        return out
    }

    private static let codexTyped = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_$])"# + SkillWire.bareMention)

    /// The skills a message the user typed asks the agent to load, in
    /// that agent's own spelling: claude's leading `/name`, codex's
    /// `$name` anywhere, kimi's `/skill:name` standing alone.
    ///
    /// Kimi: only its own front end starts a skill from a message, and a
    /// message it started one from is drawn as its WORDS with the skill
    /// named under them (`loadedSkills`) — live and reopened alike. So a
    /// row that still reads `/skill:name words` went through kimi's
    /// headless run, which hands the line to the model as text: counted
    /// as a load, the chip said "Loaded" for good over a skill that was
    /// never sent. A bare `/skill:name` is drawn as typed either way,
    /// and counts.
    static func typedSkills(in text: String, agent: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch agent {
        case SkillAgent.claude:
            guard t.hasPrefix("/") else { return [] }
            let name = t.dropFirst().prefix(while: { !$0.isWhitespace })
            return name.isEmpty || name.contains("/") ? [] : [String(name)]
        case SkillAgent.codex:
            let ns = t as NSString
            return codexTyped.matches(in: t, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range(at: 1)) }
        case SkillAgent.kimi:
            guard t.hasPrefix("/skill:") else { return [] }
            let name = t.dropFirst("/skill:".count)
            return name.isEmpty || name.contains(where: \.isWhitespace) ? [] : [String(name)]
        default:
            return []
        }
    }
}

/// What the chip's summary says about one chosen skill.
enum SkillPickStatus: Equatable {
    /// In the conversation now.
    case loaded
    /// Goes with the next message.
    case nextMessage
    /// Cannot be loaded here, and why.
    case unavailable(String)
}

enum SkillPickReport {
    /// Each pick's status. `choices` nil means the folder's skills have
    /// not been read yet, which is not a reason to call anything
    /// unavailable — and neither is a name the list does not hold while
    /// the folder's subfolders are still being read (`stillReading`): a
    /// subfolder's skill is listed only once its subfolder has been.
    static func statuses(picks: [String], choices: [SkillChoice]?,
                         held: Set<String>, missing: String,
                         stillReading: Bool = false) -> [String: SkillPickStatus] {
        var out: [String: SkillPickStatus] = [:]
        for pick in picks {
            let key = pick.lowercased()
            if let choices {
                guard let choice = choices.first(where: { $0.name.lowercased() == key }) else {
                    out[pick] = stillReading ? (held.contains(key) ? .loaded : .nextMessage)
                        : .unavailable(missing)
                    continue
                }
                if let reason = choice.unavailable { out[pick] = .unavailable(reason); continue }
            }
            out[pick] = held.contains(key) ? .loaded : .nextMessage
        }
        return out
    }

    /// The picks a send can load: chosen, not yet held, and loadable
    /// here, in the order they were chosen.
    ///
    /// `choices` nil — the folder's skills not read yet — sends the
    /// names as chosen only where `sendsUnread` says the agent takes a
    /// bare name (claude's `/name`). Codex is named by PATH: a mention
    /// without one is the fallback spelling, which the reader takes back
    /// only for a lower-case name, so a pick waits for the read instead.
    ///
    /// `onePerMessage` (Kimi): one message carries one skill, the first
    /// that is due (`SkillAgent.oneSkillPerMessage`).
    static func triggers(picks: [String], choices: [SkillChoice]?,
                         evidence: [SkillEvidence], sendsUnread: Bool,
                         onePerMessage: Bool = false) -> [SkillTrigger] {
        if choices == nil, !sendsUnread { return [] }
        let due = SkillPreload.toLoad(picks: picks, evidence: evidence).compactMap { name -> SkillTrigger? in
            guard let choices else { return SkillTrigger(name: name) }
            guard let choice = choices.first(where: { $0.name.lowercased() == name.lowercased() }),
                  choice.unavailable == nil else { return nil }
            return SkillTrigger(name: choice.name, path: choice.codexPath,
                                subfolder: choice.subfolder, claudeAddDir: choice.claudeAddDir,
                                skillsFolder: choice.skillsFolder)
        }
        return onePerMessage ? Array(due.prefix(1)) : due
    }
}

/// One skill a send triggers: its name, and for Codex the exact path
/// Codex itself reported for it (a mention by path matches only its
/// canonical spelling).
struct SkillTrigger: Hashable {
    let name: String
    var path: String? = nil
    /// A skill of a subfolder of the session's folder: that subfolder.
    var subfolder: String? = nil
    /// …as Claude is handed it with `--add-dir` (`SkillSubfolderReach`,
    /// `SkillChoice.claudeAddDir`).
    var claudeAddDir: String? = nil
    /// …and the agent's skills folder in it that holds the skill — what
    /// Codex's app-server is handed as an extra place to read skills.
    var skillsFolder: String? = nil

    /// The folders a Claude turn names with `--add-dir` so its quiet
    /// loads find the subfolders' skills, each once, in order — below the
    /// session's folder, where claude is started, so a namesake's
    /// `<folder>:<name>` is the one the pick carries.
    static func claudeAddDirs(_ triggers: [SkillTrigger]) -> [String] {
        var seen = Set<String>()
        return triggers.compactMap { $0.claudeAddDir ?? $0.subfolder }.filter { seen.insert($0).inserted }
    }

    /// The skills folders a Codex app-server turn adds before the
    /// mention line is read, each once, in order.
    static func codexExtraRoots(_ triggers: [SkillTrigger]) -> [String] {
        var seen = Set<String>()
        return triggers.compactMap(\.skillsFolder).filter { seen.insert($0).inserted }
    }
}

// MARK: - Composing the message

enum SkillWire {
    /// Claude: the stream-json lines that load each skill and then send
    /// the message — one user message per skill marked not to start a
    /// model call, then the text as an ordinary message. Claude expands
    /// every skill and makes ONE model request carrying all of them and
    /// the text. Newline-terminated; written to stdin, then EOF.
    static func claudeStdinLines(skills: [String], text: String) -> String {
        var lines: [String] = []
        for name in skills {
            lines.append(json([
                "type": "user",
                "message": ["role": "user", "content": "/" + name],
                "parent_tool_use_id": NSNull(),
                "session_id": "",
                "shouldQuery": false,
            ]))
        }
        lines.append(json([
            "type": "user",
            "message": ["role": "user", "content": text],
            "parent_tool_use_id": NSNull(),
            "session_id": "",
        ]))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Codex: a first line of mentions, then a blank line, then the text.
    /// A mention carries the skill's path when there is one that Codex's
    /// linked form can hold; a bare `$name` otherwise.
    static func codexText(skills: [SkillTrigger], text: String) -> String {
        let mentions = skills.compactMap { codexMention($0) }
        guard !mentions.isEmpty else { return text }
        return mentions.joined(separator: " ") + "\n\n" + text
    }

    /// One skill's mention, or nil for one that cannot be spelled in a
    /// way the reader takes back (`splittingCodexMentionLine`) — sent
    /// anyway, its line would stay in the message as the user's words.
    /// Linked, with the path Codex reported, wherever a link can hold
    /// it; a bare `$name` for the path it cannot (a `)` ends the link).
    static func codexMention(_ trigger: SkillTrigger) -> String? {
        if let path = trigger.path, path.hasPrefix("/"), path.hasSuffix("SKILL.md"),
           !path.contains(")"), !path.contains("\n"),
           !trigger.name.isEmpty, !trigger.name.contains("]"), !trigger.name.contains("\n") {
            return "[$\(trigger.name)](\(path))"
        }
        let whole = NSRange(location: 0, length: (trigger.name as NSString).length)
        guard let m = bareName.firstMatch(in: trigger.name, range: whole), m.range == whole else {
            return nil
        }
        return "$" + trigger.name
    }

    /// The skills of `triggers` a codex message really carries, in order.
    static func codexLoads(_ triggers: [SkillTrigger]) -> [SkillTrigger] {
        triggers.filter { codexMention($0) != nil }
    }

    /// A trigger whose SKILL.md is no longer at the path Codex listed —
    /// the skill moved since the folder was read — goes by NAME: a link
    /// to a path Codex does not have loads nothing, and says nothing.
    static func codexTriggers(_ triggers: [SkillTrigger],
                              exists: (String) -> Bool) -> [SkillTrigger] {
        triggers.map { trigger in
            guard let path = trigger.path, !exists(path) else { return trigger }
            return SkillTrigger(name: trigger.name)
        }
    }

    // The two spellings, as the reader takes them back. A LINK is SipAI's
    // only when it holds a SKILL.md path — `[$100](https://…)` at the top
    // of a message is the user's own. A bare `$name` is the fallback for
    // a path a link cannot hold, and it is lower-case with no closing
    // full stop: a line of shell variables (`$HOME`) is not a load, and
    // neither is the `$name.` that ends a sentence.
    static let linkedMention = #"\[\$([^\]\n]+)\]\(/[^)\n]*SKILL\.md\)"#
    static let bareMention = #"\$([a-z0-9][a-z0-9_:-]*(?:\.[a-z0-9_:-]+)*)"#
    private static let bareName = try! NSRegularExpression(
        pattern: #"[a-z0-9][a-z0-9_:-]*(?:\.[a-z0-9_:-]+)*"#)
    private static let codexMentionToken = try! NSRegularExpression(
        pattern: "(?:" + linkedMention + "|" + bareMention + ")")
    private static let codexMentionLine = try! NSRegularExpression(
        pattern: #"\A"# + "(?:" + linkedMention + "|" + bareMention + ")"
            + "(?:[ ]+(?:" + linkedMention + "|" + bareMention + "))*" + #"\n\n"#)

    /// The skills a SipAI-composed codex message loaded and the user's
    /// own text, or nil when the text does not open with that line.
    static func splittingCodexMentionLine(_ text: String) -> (names: [String], rest: String)? {
        let ns = text as NSString
        guard let m = codexMentionLine.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let line = ns.substring(with: m.range)
        var names: [String] = []
        for t in codexMentionToken.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
            for g in [1, 2] where t.range(at: g).location != NSNotFound {
                names.append((line as NSString).substring(with: t.range(at: g)))
            }
        }
        let rest = ns.substring(from: m.range.location + m.range.length)
        return (names, rest)
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Whether a load happened

/// What a turn says about a skill that was to load with its message.
enum SkillLoadWords {
    /// The agent turned out not to have the skill — one deleted or moved
    /// since its folder was read, or one the agent does not list. The
    /// message itself went.
    static func notFound(agentName: String, skill: String) -> String {
        String(localized: "\(agentName) didn’t find the skill “\(skill)”, so your message was sent without it.",
               comment: "Runner notice: the agent did not know the chosen skill, and the message went on its own; placeholders are the agent label and the skill")
    }
}

/// Claude: what a turn's own stream says about a skill SipAI loaded ahead
/// of the message (`SkillWire.claudeStdinLines`). Each such message is
/// answered with a `system.init` and an empty `result` (`num_turns` 0).
/// What the stream carries (`Verification/Skills` checks it against the
/// installed claude):
///
///  * the `init` lists the session's commands (`slash_commands`) — a
///    folder's skills, a command file, the skills claude ships;
///  * the `result` of a message that RAN one carries `local_command`
///    ("custom" for a skill or a command file, the name for a shipped
///    skill). For a name claude does not know there is no such key: the
///    text went into the conversation as the words "/name", and nothing
///    else says so — no error, exit 0, the turn's answer as usual.
///
/// A load is called failed only when BOTH say so: the name is in no list
/// claude gave, and no command ran for its message. One alone is not
/// enough — a claude that names a skill another way in its list still
/// ran it, and one that sends no such key still listed it. That is how a
/// skill deleted since the folder was read, or one of a subfolder sent
/// before its folder was read, stops being drawn — and counted — as
/// loaded.
enum ClaudeSkillLoadCheck {
    /// The commands claude says the session has, or nil for any line that
    /// is not a `system.init` carrying the list.
    static func slashCommands(initLine line: String) -> Set<String>? {
        guard line.contains("\"slash_commands\""), let obj = object(line),
              (obj["type"] as? String) == "system", (obj["subtype"] as? String) == "init",
              let names = obj["slash_commands"] as? [String] else { return nil }
        return Set(names)
    }

    /// Whether a command ran for the message a `result` answers, or nil
    /// for any line that is not the result of a message that started no
    /// model call.
    static func ranCommand(resultLine line: String) -> Bool? {
        guard line.contains("\"num_turns\""), let obj = object(line),
              (obj["type"] as? String) == "result",
              (obj["num_turns"] as? NSNumber)?.intValue == 0 else { return nil }
        return (obj["local_command"] as? String).map { !$0.isEmpty } ?? false
    }

    /// Whether the load of `name` certainly did not happen.
    static func failed(name: String, slashCommands: Set<String>?, ranCommand: Bool) -> Bool {
        guard !ranCommand, let slashCommands else { return false }
        return !slashCommands.contains(name)
    }

    private static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Reading a load back

/// How each agent records a skill load, read back by the transcript
/// readers so a reopened conversation shows the user's own words with
/// the skills named under them — as the live send does.
enum SkillRecords {
    private static let commandName = try! NSRegularExpression(
        pattern: #"<command-name>/?([^<]+)</command-name>"#)
    private static let commandArgs = try! NSRegularExpression(
        pattern: #"<command-args>([\s\S]*?)</command-args>"#)
    private static let wrappers = try! NSRegularExpression(
        pattern: #"<command-message>[\s\S]*?</command-message>|<command-name>[\s\S]*?</command-name>|<command-args>[\s\S]*?</command-args>"#)

    /// Claude: a user record that IS a prompt command — its wrappers and
    /// nothing else — read as the command's name and its arguments.
    static func claudeCommand(in rawText: String) -> (name: String, args: String)? {
        let ns = rawText as NSString
        let all = NSRange(location: 0, length: ns.length)
        guard let n = commandName.firstMatch(in: rawText, range: all) else { return nil }
        let leftover = wrappers.stringByReplacingMatches(in: rawText, range: all, withTemplate: "")
        guard leftover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let name = ns.substring(with: n.range(at: 1)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var args = ""
        if let a = commandArgs.firstMatch(in: rawText, range: all) {
            args = ns.substring(with: a.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (name, args)
    }

    /// Claude: the text a skill that has a FOLDER expands into opens
    /// with this line. A skill claude ships itself (`/simplify`), or a
    /// command file (`.claude/commands`), expands into its text alone —
    /// so this is one sign of an expansion, never the test for one
    /// (`isClaudeExpansion`).
    static func isClaudeSkillBody(_ rawText: String) -> Bool {
        rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("Base directory for this skill:")
    }

    /// Claude: whether a user record holds the text a command or a Skill
    /// call EXPANDED into — written by claude, never the user's words,
    /// and often pages long. Read by what the record IS, not by how its
    /// text begins:
    ///
    ///  * after the model's own Skill call it names the call
    ///    (`sourceToolUseID`);
    ///  * after a command the user sent it carries that command's
    ///    `promptId` — `afterCommandPrompt` is the id of the command
    ///    record directly above, when there is one.
    ///
    /// Both are `isMeta`. So are records that are neither (a note about
    /// a resized image, a "your response was cut off" prompt), which is
    /// why `isMeta` alone decides nothing.
    static func isClaudeExpansion(_ record: [String: Any], text: String,
                                  afterCommandPrompt: String?) -> Bool {
        guard (record["isMeta"] as? Bool) == true else { return false }
        if isClaudeSkillBody(text) { return true }
        if let source = record["sourceToolUseID"] as? String, !source.isEmpty { return true }
        if let after = afterCommandPrompt, !after.isEmpty,
           (record["promptId"] as? String) == after { return true }
        return false
    }

    /// Codex: an injected skill's name, for a `<skill>` fragment.
    static func codexSkillFragmentName(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("<skill>"),
              let open = t.range(of: "<name>"),
              let close = t.range(of: "</name>", range: open.upperBound..<t.endIndex)
        else { return nil }
        let name = t[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The skill a model-invoked `Skill` tool call loads (Claude, Kimi).
    static func skillToolName(name: String, input: [String: Any]) -> String? {
        guard name == "Skill" else { return nil }
        let skill = (input["skill"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let bare = skill.hasPrefix("/") ? String(skill.dropFirst()) : skill
        return bare.isEmpty ? nil : bare
    }
}
