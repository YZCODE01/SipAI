// SkillCatalog.swift
// What each agent's skills are, folder by folder, for Settings → Agent Skills,
// the composer's skill chip and scheduled tasks — read from the files,
// then refined by what each CLI says itself:
//
//  * Claude Code answers two control requests over stream-json input —
//    `initialize` (every skill a user can call, plugins and bundled ones
//    included) and `get_skills_dialog` (each user and project skill's
//    state) — with no model call and no transcript written.
//  * Codex answers `skills/list` on its app-server: every skill it loads
//    for a folder, its canonical path and whether it is switched on.
//  * Kimi Code says nothing headless, so its skills are its folders.
//
// On/off goes through each agent's own writer: Claude's
// `edit-skill-overrides` (saved for one folder), Codex's
// `skills/config/write` (everywhere). Kimi has none.

import Foundation

// MARK: - Claude

enum ClaudeSkillProbe {
    static let ceiling: TimeInterval = 15

    /// The child's environment for a probe or a switch: the agent's own,
    /// minus the marker that makes claude refuse to change a setting from
    /// inside another Claude Code session, and with claude's optional
    /// network traffic off — a listing needs none.
    nonisolated static func environment(_ base: [String: String]) -> [String: String] {
        var env = base
        env.removeValue(forKey: "CLAUDE_CODE_CHILD_SESSION")
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        return env
    }

    /// Ask claude for its skills. Nil when it never answered both
    /// requests inside the ceiling; a request it REFUSED is an answer
    /// (`ClaudeSkillListing.note`), with that half left empty.
    nonisolated static func run(binary: String, cwd: URL,
                                environment: [String: String]) -> ClaudeSkillListing? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-p", "--input-format", "stream-json",
                       "--output-format", "stream-json", "--verbose"]
        p.currentDirectoryURL = cwd
        p.environment = Self.environment(environment)
        let input = Pipe()
        let output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        let inFD = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(inFD, F_SETNOSIGPIPE, 1)
        let requests = [
            #"{"type":"control_request","request_id":"\#(ClaudeSkillListing.commandsRequest)","request":{"subtype":"initialize"}}"#,
            #"{"type":"control_request","request_id":"\#(ClaudeSkillListing.dialogRequest)","request":{"subtype":"get_skills_dialog"}}"#,
        ]
        let payload = Array((requests.joined(separator: "\n") + "\n").utf8)
        var written = 0
        while written < payload.count {
            let n = payload[written...].withUnsafeBufferPointer { Darwin.write(inFD, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            written += n
        }

        let outFD = output.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(ceiling)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var received = Data()
        var report = ClaudeSkillListing()
        while !report.isComplete, Date() < deadline {
            var pfd = pollfd(fd: outFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 250)
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 { if !p.isRunning { break }; continue }
            let (count, err): (Int, Int32) = buffer.withUnsafeMutableBytes { raw in
                let n = Darwin.read(outFD, raw.baseAddress, raw.count)
                return (n, n < 0 ? errno : 0)
            }
            if count < 0 { if err == EINTR || err == EAGAIN { continue }; break }
            if count == 0 { break }
            received.append(contentsOf: buffer[0..<count])
            // Complete lines only; a partial last line waits for more.
            while let nl = received.firstIndex(of: UInt8(ascii: "\n")) {
                let line = received[received.startIndex..<nl]
                received.removeSubrange(received.startIndex...nl)
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                    continue
                }
                report.note(obj)
            }
        }
        // Closing its stdin is what ends it; the escalation is for one
        // that does not go.
        try? input.fileHandleForWriting.close()
        let until = Date().addingTimeInterval(AgentCLIProbe.terminateGrace)
        while p.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.05) }
        AgentCLIProbe.stop(p)
        p.waitUntilExit()
        try? output.fileHandleForReading.close()
        return report.isComplete ? report : nil
    }

    /// Claude's state names, as `edit-skill-overrides` and the dialog
    /// spell them.
    static func stateValue(_ state: SkillState) -> String {
        ClaudeSkillDialog.stateValue(state)
    }

    static func state(from value: String?) -> SkillState? {
        ClaudeSkillDialog.state(from: value)
    }

    /// Whether `edit-skill-overrides --json` reported success: its
    /// answer is one JSON object carrying `ok`.
    nonisolated static func saysOK(_ output: String) -> Bool {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
            return (obj["ok"] as? Bool) == true
        }
        return text.contains("\"ok\":true")
    }

    /// Switch one skill through claude's own writer. It saves to the
    /// `.claude/settings.local.json` of the folder's git root (the folder
    /// itself outside a repository) — what Claude's own `/skills` menu
    /// writes. Nil on success, else claude's own words.
    nonisolated static func write(binary: String, cwd: URL, name: String, state: SkillState,
                                  environment: [String: String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["edit-skill-overrides", "--json"]
        p.currentDirectoryURL = cwd
        p.environment = Self.environment(environment)
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        do { try p.run() } catch { return error.localizedDescription }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let edit: [String: Any] = ["name": name, "state": stateValue(state)]
        if let data = try? JSONSerialization.data(withJSONObject: edit, options: [.sortedKeys]) {
            try? input.fileHandleForWriting.write(contentsOf: data)
        }
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(ceiling)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { AgentCLIProbe.stop(p) }
        p.waitUntilExit()
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if p.terminationStatus == 0, saysOK(out) { return nil }
        let words = err.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? out.trimmingCharacters(in: .whitespacesAndNewlines) : words
    }
}

// MARK: - Codex

enum CodexSkillList {
    struct Listing {
        /// Every skill codex loads for the folder: `name`, `description`,
        /// `path` (canonical, `/private` included), `scope`, `enabled`,
        /// `pluginId`.
        var skills: [[String: Any]]
        /// Each SKILL.md codex found and skipped, by the folder it sits
        /// in (canonical), with codex's own words ("missing field
        /// `description`").
        var skipped: [String: String]
    }

    nonisolated static func run(binary: String, cwd: URL) async -> Listing? {
        let params: [String: Any] = ["cwds": [cwd.path], "forceReload": true]
        guard let request = CodexSkillRPC.request(method: "skills/list", params: params),
              let answer = await CodexAppServerCall.run(binary: binary, request: request),
              let result = answer["result"] as? [String: Any],
              let data = result["data"] as? [[String: Any]]
        else { return nil }
        var skipped: [String: String] = [:]
        for error in data.flatMap({ ($0["errors"] as? [[String: Any]]) ?? [] }) {
            guard let path = error["path"] as? String, let message = error["message"] as? String else { continue }
            skipped[(path as NSString).deletingLastPathComponent] = message
        }
        return Listing(skills: data.flatMap { ($0["skills"] as? [[String: Any]]) ?? [] }, skipped: skipped)
    }

    /// Switch one skill on or off for codex everywhere, by its path.
    /// Nil on success, else codex's words.
    nonisolated static func write(binary: String, path: String, enabled: Bool,
                                  label: String) async -> String? {
        let params: [String: Any] = ["path": path, "enabled": enabled]
        guard let request = CodexSkillRPC.request(method: "skills/config/write", params: params) else {
            return "unencodable request"
        }
        guard let answer = await CodexAppServerCall.run(binary: binary, request: request) else {
            return SkillCatalog.noAnswer(label)
        }
        if answer["result"] != nil { return nil }
        let error = answer["error"] as? [String: Any]
        return (error?["message"] as? String) ?? SkillCatalog.refused(label)
    }
}

enum CodexSkillRPC {
    static func request(method: String, params: [String: Any]) -> String? {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": CodexAppServerCall.answerId,
                                     "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - The catalog

@MainActor
final class SkillCatalog: ObservableObject {
    static let shared = SkillCatalog()

    /// Snapshots by folder path ("" for the global skills alone).
    @Published private(set) var snapshots: [String: SkillSnapshot] = [:]
    /// Folders being read right now.
    @Published private(set) var loading: Set<String> = []
    /// Bumped after every write, so a view can re-read what it shows.
    @Published private(set) var revision = 0
    /// The subfolders with skills of their own, by the folder they are
    /// below (`findSubfolders`). Kept apart from that folder's snapshot:
    /// only what shows a subfolder's skills asks for them, and a read of
    /// a folder never looks below it.
    @Published private(set) var subfolders: [String: SkillSubfolders] = [:]
    /// The folders `ensureLoaded(folders:)` has yet to read — what a
    /// page's progress mark shows beside `loading`.
    @Published private(set) var waiting: Set<String> = []

    private var readAt: [String: Date] = [:]
    /// When the read of a folder now under way began.
    private var beganAt: [String: Date] = [:]
    /// When a write last landed. A read that began before it holds what
    /// the folders held before it.
    private var lastWrite = Date.distantPast
    /// One read at a time per folder, fresh for every caller (`refresh`).
    private let reads = FreshReads()
    /// One walk below a folder at a time, by the same rule
    /// (`findSubfolders`).
    private let walks = FreshReads()
    /// The folders waiting for `ensureLoaded(folders:)`, in order, each
    /// with when it was asked for; and the one task reading them.
    private var queued: [(folder: URL, asked: Date)] = []
    private var queueReader: Task<Void, Never>? = nil
    /// The walk-and-read a skill chip or a task panel asked for last
    /// (`loadSubfolders`); a newer ask takes its place.
    private var subfolderLoader: Task<Void, Never>? = nil
    private var subfolderLoad = 0
    /// The folder whose subfolders that ask is still finding and reading.
    @Published private(set) var loadingSubfolders: String? = nil
    /// The names of the skills each subfolder holds for an agent, by its
    /// FILES alone (`fileNames`), until the next write — what lets
    /// `choices` leave a name with the nearest subfolder holding it
    /// while that subfolder's own read has not landed.
    private var levelNames: [String: Set<String>] = [:]
    /// When the subfolders below a folder were last searched for a set of
    /// names (`readSubfolders`), so a pick with no skill behind it is not
    /// searched for again at every reload of its session.
    private var searched: [String: Date] = [:]

    private init() {
        SkillDirectory.lookup = { name, agent, folder in
            SkillCatalog.shared.row(named: name, agent: agent, folder: folder)
        }
    }

    static func key(_ folder: URL?) -> String { folder?.standardizedFileURL.path ?? "" }

    func snapshot(folder: URL?) -> SkillSnapshot? { snapshots[Self.key(folder)] }

    /// Read a folder's skills unless a read younger than `maxAge` is in
    /// hand. Cheap to call from a view's appearance.
    func ensureLoaded(folder: URL?, maxAge: TimeInterval = 60) {
        if isFresh(Self.key(folder), maxAge: maxAge) { return }
        Task { await refresh(folder: folder) }
    }

    /// Whether `k` needs no read: one younger than `maxAge` is in hand,
    /// or one is under way that will be. A read under way that began
    /// BEFORE the last write will not: it holds what the folders held
    /// before it, and counted as "being read" it was the one folder a
    /// write never had read again.
    private func isFresh(_ k: String, maxAge: TimeInterval) -> Bool {
        if reads.isRunning(k) {
            // Asked for and not begun yet: it begins after now.
            guard let began = beganAt[k] else { return true }
            return began >= lastWrite || reads.willRunAgain(k)
        }
        if let at = readAt[k] { return Date().timeIntervalSince(at) < maxAge }
        return false
    }

    /// Return once a read of `folder` is IN HAND: one no older than
    /// `maxAge`, or — when one is under way that will be (`isFresh`) —
    /// that one, landed. `isFresh` answers "no read needs starting",
    /// which is true from the moment one starts: asked that and then
    /// looked at, a snapshot that had not landed read as "this folder
    /// has no skills". The second of two scheduled tasks sharing a folder
    /// and a slot was refused over a subfolder's skill the first was
    /// still reading, and a session's picks, every one of them "missing"
    /// for that moment, had all the subfolders read for them.
    func awaitLoaded(folder: URL?, maxAge: TimeInterval = 60) async {
        let k = Self.key(folder)
        if reads.isRunning(k), isFresh(k, maxAge: maxAge) { await reads.join(k) }
        if !reads.isRunning(k), let at = readAt[k], Date().timeIntervalSince(at) < maxAge { return }
        await refresh(folder: folder)
    }

    /// Read each of `folders` unless a fresh read is in hand (`isFresh`)
    /// — ONE AFTER ANOTHER. They are the subfolders of the folder
    /// Settings → Agent Skills shows (`findSubfolders`), and each read asks the
    /// agents' own tools in that folder: a workspace of projects read all
    /// at once started a claude and a codex for every one of them
    /// together.
    ///
    /// The list is what the page shows NOW. Whatever was waiting from an
    /// earlier call and is not in it is dropped — the page moved to
    /// another folder, or went away (an empty list): kept, the new
    /// folder's subfolders waited behind every read still owed to the
    /// old one, a claude and a codex started for each, for a page nobody
    /// was looking at. A folder already waiting keeps its place's claim:
    /// it was asked for and has not been read since.
    func ensureLoaded(folders: [URL], maxAge: TimeInterval = 60) {
        let now = Date()
        let asked = Dictionary(queued.map { (Self.key($0.folder), $0.asked) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        queued = folders.compactMap { folder in
            let k = Self.key(folder)
            guard seen.insert(k).inserted else { return nil }
            if let earlier = asked[k] { return (folder, earlier) }
            return isFresh(k, maxAge: maxAge) ? nil : (folder, now)
        }
        noteWaiting()
        guard queueReader == nil, !queued.isEmpty else { return }
        queueReader = Task { [weak self] in
            while let self, !self.queued.isEmpty {
                let next = self.queued.removeFirst()
                self.noteWaiting()
                // Read since it was asked for, or being read by a read
                // that began since — a write made for it, a page of its
                // own: once is enough.
                let k = Self.key(next.folder)
                if let at = self.readAt[k], at >= next.asked { continue }
                if self.reads.isRunning(k), let began = self.beganAt[k], began >= next.asked { continue }
                await self.refresh(folder: next.folder)
            }
            self?.queueReader = nil
        }
    }

    private func noteWaiting() {
        let keys = Set(queued.map { Self.key($0.folder) })
        if keys != waiting { waiting = keys }
    }

    /// The subfolders of `folder` with skills of their own, as last found.
    func subfolders(of folder: URL?) -> SkillSubfolders? {
        folder.flatMap { subfolders[Self.key($0)] }
    }

    /// Look below `folder` for the subfolders that hold skills of their
    /// own (`SkillRoots.subfolders`), off the main actor, and publish
    /// what is found when it is not what was known. Asked for by what
    /// shows a subfolder's skills — Settings → Agent Skills for the folder it
    /// shows, a session's skill chip and the task panel for theirs, a
    /// scheduled run whose skill is not its folder's own — and never by
    /// a read: started by every read, the walk ran for each subfolder's
    /// own read too, and for every scheduled run, none of which looked at
    /// what it found. One walk at a time a folder, each caller answered
    /// by one that began after it asked (`FreshReads`), so what an older
    /// walk found never lands on top of a newer one's.
    func findSubfolders(of folder: URL) {
        Task { await walkSubfolders(of: folder) }
    }

    /// The same, returning once a walk that began after the call has
    /// landed in `subfolders`.
    func walkSubfolders(of folder: URL) async {
        let k = Self.key(folder)
        await walks.run(k) { [weak self] in
            let home = FileManager.default.homeDirectoryForCurrentUser
            let found = await Task.detached(priority: .utility) {
                SkillRoots.subfolders(of: folder, home: home)
            }.value
            // No write when nothing moved: every write redraws the page.
            guard let self, self.subfolders[k] != found else { return }
            self.subfolders[k] = found
        }
    }

    /// Walk below `folder` and read each subfolder found, ONE AFTER
    /// ANOTHER, nearest first — what a session's skill chip and the task
    /// panel ask for as they open, to offer those skills too (`choices`).
    ///
    /// On a queue of its own. `ensureLoaded(folders:)` is the Skills
    /// page's: its list is what that page shows NOW, so a chip's walk
    /// that landed after the page had appeared put the chip's subfolders
    /// in the page's place — or emptied it. A newer ask (another
    /// session's chip, another task) takes this one's place: what the
    /// first still owed was for a popover that has closed. Each read
    /// asks the agents' own tools in that subfolder, and a subfolder's
    /// skills change far less often than a chip is opened, so one a few
    /// minutes old is not read again (a write through SipAI distrusts
    /// every read at once).
    func loadSubfolders(below folder: URL, maxAge: TimeInterval = 300) {
        subfolderLoader?.cancel()
        subfolderLoad += 1
        let load = subfolderLoad
        let k = Self.key(folder)
        if loadingSubfolders != k { loadingSubfolders = k }
        subfolderLoader = Task { [weak self] in
            guard let self else { return }
            await self.walkSubfolders(of: folder)
            for level in self.subfolders(of: folder)?.found ?? [] {
                if Task.isCancelled { break }
                await self.awaitLoaded(folder: URL(fileURLWithPath: level.path, isDirectory: true),
                                       maxAge: maxAge)
            }
            // Still the newest ask: a newer one has put its own folder here.
            if self.subfolderLoad == load { self.loadingSubfolders = nil }
        }
    }

    /// Whether the subfolders below `folder` are still being found and
    /// read for a chip or a task panel. While they are, a chosen skill
    /// the list does not hold yet is not one known to be missing: a
    /// subfolder's skill is listed only once its subfolder has been read.
    func readingSubfolders(below folder: URL) -> Bool {
        loadingSubfolders == Self.key(folder)
    }

    /// The names of the skills `agent` has at `level`'s own level, by the
    /// FILES alone — what a read of that subfolder lists there before the
    /// agents' own tools are asked. Lower-cased.
    nonisolated static func fileNames(at level: SkillLevel, agent: String,
                                      env: SkillEnvironment) -> Set<String> {
        let roots = SkillRoots.scanRoots(env: env, folder: URL(fileURLWithPath: level.path, isDirectory: true))
            .filter { $0.scope == .folder }
        let entries = SkillScan.entries(from: SkillScan.read(roots: roots))
        return Set(entries.filter { $0.agent == agent && level.holds($0.entryPath) }
            .map { $0.name.lowercased() })
    }

    private static func levelKey(_ level: SkillLevel, _ agent: String) -> String {
        agent + "|" + level.path
    }

    /// Find the subfolders of `folder` that hold `agent`'s skills of
    /// these `names`, and read THOSE — returning once the reads are in.
    /// For a scheduled run, and a session with picks, whose skill is not
    /// one of its folder's own.
    ///
    /// By the files first. Each read of a subfolder asks the agents' own
    /// tools there, and read one after another until every name turned
    /// up, a name that is in none of them — a pinned skill of another
    /// folder, a deleted one, a typo in a task's `skills:` — had every
    /// subfolder read for it: up to twenty times a claude and a codex
    /// started, at each reload of the session, before each run of the
    /// task. Looking at the files costs neither: a name no subfolder
    /// holds starts nothing, and a name one does is read there alone.
    /// What every subfolder holds by its files is kept (`levelNames`), so
    /// `choices` still gives a name to the NEAREST subfolder holding it —
    /// the ones nearer, unread, are known not to.
    func readSubfolders(below folder: URL, wanting names: Set<String>, agent: String) async {
        let wanted = Set(names.map { $0.lowercased() })
        guard !wanted.isEmpty else { return }
        // Searched a moment ago, and nothing written since: the same
        // files would be looked at again for the same answer.
        let memo = Self.key(folder) + "|" + agent + "|" + wanted.sorted().joined(separator: "\u{1F}")
        if let at = searched[memo], at >= lastWrite, Date().timeIntervalSince(at) < 30 { return }
        await walkSubfolders(of: folder)
        let levels = subfolders(of: folder)?.found ?? []
        guard !levels.isEmpty else { return }
        let base = await Self.childEnvironment()
        let env = SkillEnvironment.resolve(base, home: FileManager.default.homeDirectoryForCurrentUser)
        let began = Date()
        let named = await Task.detached(priority: .utility) {
            levels.map { Self.fileNames(at: $0, agent: agent, env: env) }
        }.value
        // A write that landed meanwhile distrusts what the files said.
        guard began >= lastWrite else { return }
        for (level, held) in zip(levels, named) { levelNames[Self.levelKey(level, agent)] = held }
        var left = wanted
        let folderPath = SkillRoots.pathURL(folder).path
        for (level, held) in zip(levels, named) {
            let url = URL(fileURLWithPath: level.path, isDirectory: true)
            // A Claude namesake is asked for as `<subfolder>:<name>`
            // (`choices`), its subfolder spelled below the session's folder.
            let prefix: String? = agent == SkillAgent.claude && level.path.hasPrefix(folderPath + "/")
                ? String(level.path.dropFirst(folderPath.count + 1)).lowercased() : nil
            let names = prefix.map { p in held.union(held.map { ClaudeSkillNames.namesake($0, in: p) }) } ?? held
            // Its read in hand lists a wanted skill its files no longer
            // hold — deleted or moved since, with no write of SipAI's to
            // distrust the read. Read again, or the chip goes on offering
            // a skill that is not there.
            let outdated = snapshot(folder: url).map { read in
                SkillListing.rows(of: agent, in: read.rows, at: level).contains { row in
                    let name = row.entries[agent]?.name.lowercased() ?? ""
                    let wantedHere = wanted.contains(name)
                        || prefix.map { wanted.contains(ClaudeSkillNames.namesake(name, in: $0)) } == true
                    return wantedHere && !held.contains(name)
                }
            } ?? false
            let holds = !left.isDisjoint(with: names)
            if holds { left.subtract(names) }
            if outdated {
                await refresh(folder: url)
            } else if holds {
                await awaitLoaded(folder: url)
            }
        }
        searched[memo] = began
    }

    /// A skill a turn's message was sent with turned out not to be the
    /// agent's (`AgentRunner.retractSkillLoads`): what was read is not
    /// what is there. The folder is read again, and the subfolders
    /// searched afresh for those names — so the chip stops offering a
    /// skill that is gone, and offers one that has only moved from where
    /// it now is.
    func noteLoadFailed(_ names: [String], agent: String, folder: URL) {
        Task {
            await refresh(folder: folder)
            let prefix = Self.key(folder) + "|" + agent + "|"
            searched = searched.filter { !$0.key.hasPrefix(prefix) }
            let own = ownNames(agent: agent, folder: folder)
            await readSubfolders(below: folder, wanting: Set(names.map { $0.lowercased() }).subtracting(own),
                                 agent: agent)
        }
    }

    /// Read what a session's picks need before its next send: its
    /// folder, and — for a pick that is none of the folder's own or the
    /// global skills — the subfolder that holds it (`readSubfolders`).
    /// "Its own" is what the folder's own read lists: a subfolder's skill
    /// already in hand is looked for again, so one deleted or moved since
    /// is found out.
    func ensurePicksReadable(_ picks: [String], agent: String, folder: URL) {
        guard !picks.isEmpty else { return }
        Task {
            await awaitLoaded(folder: folder)
            let own = ownNames(agent: agent, folder: folder)
            await readSubfolders(below: folder, wanting: Set(picks.map { $0.lowercased() }).subtracting(own),
                                 agent: agent)
        }
    }

    /// The names of the skills `agent` has in `folder` itself — its own
    /// and the global ones, none of a subfolder's. Lower-cased.
    func ownNames(agent: String, folder: URL) -> Set<String> {
        Set(choices(agent: agent, folder: folder).filter { $0.subfolder == nil }.map { $0.name.lowercased() })
    }

    /// Read a folder's skills now, and return once a read that BEGAN
    /// after this call is in `snapshots` (`FreshReads`). A scheduled run
    /// reads its skills through this before it starts, and a write
    /// re-reads through it before the pane draws: neither may come back
    /// with a read that was already under way, let alone — before the
    /// first one lands — with no snapshot, which a lookup reads as "this
    /// agent has no such skill".
    func refresh(folder: URL?) async {
        let k = Self.key(folder)
        if !loading.contains(k) { loading.insert(k) }
        await reads.run(k) { [weak self] in
            let began = Date()
            self?.beganAt[k] = began
            let base = await Self.childEnvironment()
            let env = SkillEnvironment.resolve(
                base, home: FileManager.default.homeDirectoryForCurrentUser)
            let snap = await Self.harvest(folder: folder, env: env, childEnv: base)
            guard let self else { return }
            self.snapshots[k] = snap
            // As fresh as its start — the files are scanned first, the
            // CLIs asked after — and not fresh at all when a write landed
            // meanwhile: stamped with its end, a read of another folder
            // that a write overtook was trusted, and its rows were acted
            // on as they had stood before the write.
            self.readAt[k] = began >= self.lastWrite ? began : nil
            self.beganAt[k] = nil
        }
        // Another caller may have started the next read already.
        if !reads.isRunning(k), loading.contains(k) { loading.remove(k) }
    }

    /// The environment an agent child gets — the one every probe and
    /// write here runs in, and the one whose home variables decide where
    /// each agent's folders are.
    nonisolated static func childEnvironment() async -> [String: String] {
        if let provider = await MainActor.run(body: { CLIScrapeEnvironment.provider }) {
            return await provider()
        }
        return ProcessInfo.processInfo.environment
    }

    nonisolated static func harvest(folder: URL?, env: SkillEnvironment,
                                    childEnv: [String: String]) async -> SkillSnapshot {
        let roots = SkillRoots.scanRoots(env: env, folder: folder)
        let found = SkillScan.read(roots: roots)
        let entries = SkillScan.entries(from: found)
        let projectRoot = folder.map { SkillRoots.projectRoot(of: $0) }
        var extra: [SkillRow] = []
        // Claude's own account of each skill's state, "source|name" →
        // state (`ClaudeSkillDialog`).
        var claudeStates: [String: SkillState] = [:]
        var claudeAnswered = false
        var codexOff: Set<String> = []
        var codexAnswered = false
        var codexPaths: [String: String] = [:]
        var codexListed: Set<String> = []
        var codexSkipped: [String: String] = [:]

        if let bin = AgentManager.binaryPath(for: SkillAgent.claude) {
            let cwd = folder ?? env.home
            if let report = await Task.detached(priority: .utility, operation: {
                ClaudeSkillProbe.run(binary: bin, cwd: cwd, environment: childEnv)
            }).value {
                claudeAnswered = report.listed
                claudeStates = ClaudeSkillDialog.states(report.dialog)
                let scanned = Set(entries.filter { $0.agent == SkillAgent.claude }.map { $0.name })
                for command in report.commands {
                    guard (command["builtin"] as? Bool) != true,
                          let name = command["name"] as? String, !name.hasPrefix("_"),
                          !scanned.contains(name) else { continue }
                    let raw = (command["description"] as? String) ?? ""
                    // A user or project skill the scan missed (an `--add-dir`
                    // folder, a managed one) is still the agent's: shown,
                    // never written.
                    if raw.hasSuffix("(user)") || raw.hasSuffix("(project)") { continue }
                    let label = name.contains(":") ? "Plugin" : "Built-in"
                    var fm = SkillFrontmatter()
                    fm.name = name
                    fm.description = raw
                    let entry = SkillEntry(agent: SkillAgent.claude, name: name, description: raw,
                                           scope: .global, rootKind: .readOnly, entryPath: "",
                                           realPath: nil, isLink: false, frontmatter: fm,
                                           sourceLabel: label)
                    extra.append(SkillRow(id: "ro:\(SkillAgent.claude):\(label):\(name)", name: name,
                                          description: raw, scope: .global, home: .readOnly(label),
                                          realPath: nil, entries: [SkillAgent.claude: entry],
                                          frontmatter: fm))
                }
            }
        }

        if let bin = AgentManager.binaryPath(for: SkillAgent.codex),
           let listing = await CodexSkillList.run(binary: bin, cwd: folder ?? env.home) {
            codexAnswered = true
            codexSkipped = listing.skipped
            for skill in listing.skills {
                guard let name = skill["name"] as? String,
                      let path = skill["path"] as? String else { continue }
                let dir = (path as NSString).deletingLastPathComponent
                if codexPaths[name] == nil { codexPaths[name] = path }
                codexListed.insert(path)
                if (skill["enabled"] as? Bool) == false { codexOff.insert(dir) }
                if let plugin = skill["pluginId"] as? String, !plugin.isEmpty {
                    var fm = SkillFrontmatter()
                    fm.name = name
                    fm.description = (skill["description"] as? String) ?? ""
                    let entry = SkillEntry(agent: SkillAgent.codex, name: name,
                                           description: fm.description, scope: .global,
                                           rootKind: .readOnly, entryPath: dir, realPath: dir,
                                           isLink: false, frontmatter: fm, sourceLabel: "Plugin")
                    extra.append(SkillRow(id: "ro:\(SkillAgent.codex):Plugin:\(name)", name: name,
                                          description: fm.description, scope: .global,
                                          home: .readOnly("Plugin"), realPath: dir,
                                          entries: [SkillAgent.codex: entry], frontmatter: fm))
                }
            }
        }

        var rows = SkillGrouping.rows(entries: entries, library: found, roots: roots, extra: extra)
        for i in rows.indices {
            for (agent, entry) in rows[i].entries {
                var state = SkillGrouping.fileState(of: entry)
                if agent == SkillAgent.claude,
                   let said = ClaudeSkillDialog.state(of: entry, in: claudeStates) {
                    state = said
                }
                if agent == SkillAgent.codex, let real = entry.realPath, codexOff.contains(real) {
                    state = .off
                }
                rows[i].states[agent] = state
                // Codex lists what it skipped, in its own words, by where
                // it found the file: the real folder, or the link to it.
                if agent == SkillAgent.codex,
                   let words = entry.realPath.flatMap({ codexSkipped[$0] })
                    ?? codexSkipped[SkillFileOps.canonicalPath(entry.entryPath)] {
                    rows[i].loadErrors[agent] = words
                }
            }
        }
        return SkillSnapshot(folder: folder?.standardizedFileURL.path,
                             projectRoot: projectRoot?.path, rows: rows,
                             claudeAnswered: claudeAnswered, codexAnswered: codexAnswered,
                             codexPaths: codexPaths, codexListed: codexListed)
    }

    /// The skill called `name` that `agent` has in `folder` — for a card
    /// that names a skill by its name alone, in a session running there.
    /// From that folder's own read. With no read of it in hand only a
    /// GLOBAL skill of that name answers, the one every folder has:
    /// another folder's skill of the same name is another skill, with
    /// its own description and its own tools, and the card says what the
    /// skill may use without asking. Answered from whichever read comes
    /// first in the dictionary's order, the card shows another project's
    /// skill of that name — and Settings → Agent Skills reads a folder's
    /// subfolders too, which puts twenty other projects' reads in reach.
    func row(named name: String, agent: String, folder: URL?) -> SkillRow? {
        let key = name.lowercased()
        func named(_ row: SkillRow) -> Bool { row.entries[agent]?.name.lowercased() == key }
        if let snap = snapshot(folder: folder) { return snap.rows.first(where: named) }
        // In a fixed order, the global read ("") first.
        for k in snapshots.keys.sorted() {
            if let row = snapshots[k]?.rows.first(where: { $0.scope == .global && named($0) }) { return row }
        }
        return nil
    }

    // MARK: Choices for a session

    /// The oldest claude measured to load a skill from a message marked
    /// not to start a model call (`SkillWire.claudeStdinLines`). An older
    /// one may read that mark as nothing and answer every skill message
    /// with a billed turn of its own, so SipAI sends it none: its skills
    /// are listed, dimmed, with the reason. A claude whose version has
    /// not been read yet is not held to it — only one KNOWN to be older.
    nonisolated static let claudeBatchFloor = CLIVersion.parse("2.1.283")

    nonisolated static func claudeTakesBatch(installed: CLIVersion?) -> Bool {
        guard let installed, let floor = claudeBatchFloor else { return true }
        return installed >= floor
    }

    /// Why claude's skills cannot be loaded from here, nil when they can.
    static func claudeBatchRefusal() -> String? {
        claudeTakesBatch(installed: AgentManager.installedClaudeVersion()) ? nil : newerAgentNeeded
    }

    /// The installed agent is too old to load a skill from SipAI: claude
    /// below the batch's floor, kimi with no front end of its own.
    static var newerAgentNeeded: String { SkillSubfolderReach.newerAgentNeeded }

    /// Whether the installed claude is KNOWN to be older than the one
    /// `--add-dir` was measured to list a folder's skills on
    /// (`SkillSubfolderReach.claudeFloor`). One whose version has not
    /// been read is not held to it.
    static func claudeTooOldForSubfolders() -> Bool {
        guard let installed = AgentManager.installedClaudeVersion(),
              let floor = CLIVersion.parse(SkillSubfolderReach.claudeFloor) else { return false }
        return installed < floor
    }

    /// Whether the installed claude is KNOWN to offer a subfolder's
    /// namesake as `<subfolder>:<name>` (`ClaudeSkillNames.namesakeFloor`).
    /// One older, or not read yet, leaves it unreachable: not offered.
    static func claudeOffersNamesakes() -> Bool {
        guard let installed = AgentManager.installedClaudeVersion(),
              let floor = CLIVersion.parse(ClaudeSkillNames.namesakeFloor) else { return false }
        return installed >= floor
    }

    /// The skills `agent` can be asked to load in `folder`, the ones it
    /// cannot load here dimmed with the reason — the folder's own and
    /// the global ones, then the skills of each SUBFOLDER that has been
    /// read (`loadSubfolders(below:)`), nearest first, each with whether
    /// this send can reach it (`SkillSubfolderReach`).
    ///
    /// `codexSend`: what this Codex send can do with a subfolder's skill
    /// (`SkillSubfolderReach.CodexSend`) — only its app-server can be
    /// told about one. `kimiCanLoad`: the installed Kimi has the front
    /// end that loads a skill by name (`kimi acp`); not known yet counts
    /// as yes.
    func choices(agent: String, folder: URL?,
                 codexSend: SkillSubfolderReach.CodexSend = .exec,
                 kimiCanLoad: Bool = true) -> [SkillChoice] {
        guard let snap = snapshot(folder: folder) else { return [] }
        var out: [SkillChoice] = []
        var seen = Set<String>()
        let tooOld: String? = {
            switch agent {
            case SkillAgent.claude: return Self.claudeBatchRefusal()
            case SkillAgent.kimi: return kimiCanLoad ? nil : Self.newerAgentNeeded
            default: return nil
            }
        }()
        for row in snap.rows {
            guard let entry = row.entries[agent] else { continue }
            let key = entry.name.lowercased()
            guard seen.insert(key).inserted else { continue }
            let path = agent == SkillAgent.codex ? snap.codexPath(for: entry) : nil
            let label: String?
            if case .readOnly(let l) = row.home { label = l } else { label = nil }
            out.append(SkillChoice(name: entry.name, description: entry.description,
                                   scope: row.isReadOnly ? .global : row.scope,
                                   sourceLabel: label,
                                   unavailable: tooOld ?? Self.reason(row: row, entry: entry, agent: agent),
                                   codexPath: path))
        }
        out.sort {
            if $0.scope != $1.scope { return $0.scope == .folder }
            if ($0.sourceLabel == nil) != ($1.sourceLabel == nil) { return $0.sourceLabel == nil }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        guard let folder, let below = subfolders(of: folder) else { return out }
        // A subfolder's own skills, by the level its walk made. A name the
        // session already has — its folder's, a global one, a nearer
        // subfolder's — is that skill: a pick is a name.
        //
        // So a name goes to the NEAREST subfolder holding it, whichever
        // read landed first. A subfolder not read yet still keeps the
        // names its files show (`levelNames`), and one nothing is known
        // of ends the list for now: offered from whatever had been read,
        // a skill ticked under one project's group loaded another
        // project's skill of that name once the nearer one's read came in.
        let reach = SkillSubfolderReach.refusal(
            agent: agent, codex: codexSend,
            claudeTooOld: agent == SkillAgent.claude && Self.claudeTooOldForSubfolders())
        let base = SkillRoots.pathURL(folder).path
        // Claude offers a subfolder's skill whose name the session already
        // has — its folder's or a global one — as `<subfolder>:<name>`,
        // the subfolder spelled the way `--add-dir` was handed it
        // (`ClaudeSkillNames.namesake`): handed the path below the
        // session's folder, it is offered under the name the picker shows.
        // A name a NEARER subfolder holds stays that skill's: which of two
        // subfolders claude prefixes depends on what else the turn names.
        let own = seen
        let namesakes = agent == SkillAgent.claude && Self.claudeOffersNamesakes()
        for level in below.found {
            guard let sub = snapshot(folder: URL(fileURLWithPath: level.path, isDirectory: true)) else {
                guard let held = levelNames[Self.levelKey(level, agent)] else { break }
                seen.formUnion(held)
                continue
            }
            let relative = level.path.hasPrefix(base + "/")
                ? String(level.path.dropFirst(base.count + 1)) : nil
            let name = relative ?? (level.path as NSString).lastPathComponent
            var here: [SkillChoice] = []
            for row in SkillListing.rows(of: agent, in: sub.rows, at: level) {
                guard let entry = row.entries[agent] else { continue }
                var offered = entry.name
                if !seen.insert(entry.name.lowercased()).inserted {
                    guard namesakes, let relative, own.contains(entry.name.lowercased()) else { continue }
                    offered = ClaudeSkillNames.namesake(entry.name, in: relative)
                    guard seen.insert(offered.lowercased()).inserted else { continue }
                }
                here.append(SkillChoice(
                    name: offered, description: entry.description, scope: .folder,
                    sourceLabel: nil,
                    unavailable: tooOld ?? reach
                        ?? Self.reason(row: row, entry: entry, agent: agent, offered: offered),
                    codexPath: agent == SkillAgent.codex ? sub.codexPath(for: entry) : nil,
                    subfolder: level.path, subfolderName: name,
                    claudeAddDir: relative ?? level.path,
                    skillsFolder: (entry.entryPath as NSString).deletingLastPathComponent))
            }
            out += here.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return out
    }

    /// Why `agent` cannot load `row` in the folder it was read in, nil
    /// when it can.
    private static func reason(row: SkillRow, entry: SkillEntry, agent: String,
                               offered: String? = nil) -> String? {
        if row.problems.contains(.brokenLink) {
            return String(localized: "Its link is broken.",
                          comment: "Skill chip: a skill whose link points at nothing")
        }
        if let why = row.notLoaded(by: agent) {
            // The agent skips it: a mention or a command would load
            // nothing, and say so nowhere.
            return String(localized: "Not loaded: \(SkillFormat.clause(why)).",
                          comment: "Skill chip: the agent skips this skill; placeholder is why, e.g. its SKILL.md has no description")
        }
        if row.states[agent] == .off {
            return String(localized: "Switched off.",
                          comment: "Skill chip: a skill switched off for this agent")
        }
        // Claude's `user-invocable: false`, and a kimi skill of the type
        // kimi leaves out of its commands (`reference`): the model may
        // read it, and nobody can start it.
        if (agent == SkillAgent.claude && !entry.frontmatter.userInvocable)
            || (agent == SkillAgent.kimi && !entry.frontmatter.kimiUserCanStart) {
            return String(localized: "Only the model can use it.",
                          comment: "Skill chip: a skill the user cannot start — Claude's user-invocable: false, or a Kimi Code skill of the reference type")
        }
        // Kimi starts a skill from `/skill:<name> …`, reading the name up
        // to the first space and taking nothing with a slash in it for a
        // command at all (its own parser, read in its bundle): a name it
        // cannot spell that way is one it cannot be asked for.
        if agent == SkillAgent.kimi, entry.name.contains(where: { $0.isWhitespace || $0 == "/" }) {
            return String(localized: "Its name has a space or a slash in it, so it can’t be called by name.",
                          comment: "Skill chip: a Kimi Code skill whose name cannot be written as a /skill: command")
        }
        if agent == SkillAgent.claude, entry.frontmatter.runsForked {
            return String(localized: "Runs on its own — type /\(offered ?? entry.name) instead.",
                          comment: "Skill chip: a Claude skill that runs as its own task; placeholder is the skill name")
        }
        return nil
    }

    // MARK: Writes

    /// Run a file operation off the main actor, then re-read `folder`.
    /// Nil on success, else a sentence for the pane.
    func perform(folder: URL?, _ work: @escaping @Sendable (SkillEnvironment, URL?) throws -> Void) async -> String? {
        let base = await Self.childEnvironment()
        let env = SkillEnvironment.resolve(base, home: FileManager.default.homeDirectoryForCurrentUser)
        let projectRoot = folder.map { SkillRoots.projectRoot(of: $0) }
        let failure: String? = await Task.detached(priority: .userInitiated) {
            do {
                try work(env, projectRoot)
                return nil
            } catch let error as SkillOpError {
                return Self.describe(error)
            } catch {
                return error.localizedDescription
            }
        }.value
        revision &+= 1
        // A write can move a skill every folder sees (a global one into
        // the library), so no folder's earlier read is trusted any more:
        // this one and the global skills are read again now, the rest the
        // next time they are asked for.
        distrustReads()
        await refresh(folder: folder)
        if folder != nil { await refresh(folder: nil) }
        return failure
    }

    private func distrustReads() {
        lastWrite = Date()
        readAt.removeAll()
        levelNames.removeAll()
        searched.removeAll()
    }

    /// Whether `plan` can be carried out as the folders stand — every
    /// step's own check (`SkillFileOps.preflight`) — as the sentence for
    /// why not. Asked BEFORE the user is shown what the plan will do: a
    /// skill in a folder SipAI does not write in had its Trash promised
    /// in a confirmation, and refused after it.
    func refusal(of plan: SkillSharePlan, folder: URL?) async -> String? {
        let base = await Self.childEnvironment()
        let env = SkillEnvironment.resolve(base, home: FileManager.default.homeDirectoryForCurrentUser)
        let projectRoot = folder.map { SkillRoots.projectRoot(of: $0) }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try SkillFileOps(env: env, projectRoot: projectRoot).preflight(plan)
                return nil
            } catch let error as SkillOpError {
                return Self.describe(error)
            } catch {
                return error.localizedDescription
            }
        }.value
    }

    /// Give a skill to `agent`, after making the fixes `check` worked out
    /// — every step's check made first, the fixes next, the links last,
    /// so a share that cannot land changes nothing. `row` is the one the
    /// pane read and the check was made from: a skill that has moved,
    /// gone or been given to someone since is left alone.
    func share(row: SkillRow, with agent: String, check: SkillShareCheck, folder: URL?) async -> String? {
        await perform(folder: folder) { env, projectRoot in
            guard SkillPlanner.isCurrent(row, env: env, folder: folder) else { throw SkillOpError.changedSinceChecked }
            guard let plan = SkillPlanner.plan(row: row, agent: agent, include: true, env: env,
                                               projectRoot: projectRoot),
                  check.refusal == nil
            else { throw SkillOpError.readOnly }
            let ops = SkillFileOps(env: env, projectRoot: projectRoot)
            try ops.preflight(plan)
            if !check.fixes.isEmpty {
                guard let real = row.realPath, let text = check.skillText else { throw SkillOpError.readOnly }
                try ops.conform(realPath: real, expected: text, fixes: check.fixes)
            }
            try ops.run(plan, projectRoot: projectRoot)
        }
    }

    /// Take a skill from `agent` alone. Whoever else has it keeps it; a
    /// skill no agent has any more goes to the Trash with its folder,
    /// unless that folder is not SipAI's (a folder linked in from
    /// elsewhere loses only its link).
    func remove(row: SkillRow, from agent: String, folder: URL?) async -> String? {
        await perform(folder: folder) { env, projectRoot in
            // Planned from a row read before another agent was given the
            // skill, "the last agent" bins the folder that agent now
            // links to.
            guard SkillPlanner.isCurrent(row, env: env, folder: folder) else { throw SkillOpError.changedSinceChecked }
            guard let plan = SkillPlanner.plan(row: row, agent: agent, include: false, env: env,
                                               projectRoot: projectRoot, keepWhenLast: false,
                                               present: Self.agentsPresent()),
                  plan.blockedBy.isEmpty
            else { throw SkillOpError.readOnly }
            try SkillFileOps(env: env, projectRoot: projectRoot).run(plan, projectRoot: projectRoot)
        }
    }

    /// Make an agent able to load a skill it already has: the fixes
    /// `check` worked out, in the skill's own files.
    func fix(row: SkillRow, check: SkillShareCheck, folder: URL?) async -> String? {
        guard let real = row.realPath, let text = check.skillText, check.refusal == nil else {
            return Self.describe(.readOnly)
        }
        return await perform(folder: folder) { env, projectRoot in
            try SkillFileOps(env: env, projectRoot: projectRoot)
                .conform(realPath: real, expected: text, fixes: check.fixes)
        }
    }

    func delete(row: SkillRow, folder: URL?) async -> String? {
        await perform(folder: folder) { env, projectRoot in
            guard SkillPlanner.isCurrent(row, env: env, folder: folder) else { throw SkillOpError.changedSinceChecked }
            guard let plan = SkillPlanner.deletePlan(row: row) else { throw SkillOpError.readOnly }
            try SkillFileOps(env: env, projectRoot: projectRoot).run(plan, projectRoot: projectRoot)
        }
    }

    func create(name: String, description: String, body: String, onlyWhenCalled: Bool,
                scope: SkillScope, agents: [String], folder: URL?) async -> String? {
        await perform(folder: folder) { env, projectRoot in
            _ = try SkillFileOps(env: env, projectRoot: projectRoot)
                .create(name: name, description: description, body: body,
                        onlyWhenCalled: onlyWhenCalled, scope: scope, agents: agents,
                        env: env, projectRoot: projectRoot)
        }
    }

    func importFolder(_ source: URL, name: String, scope: SkillScope, agents: [String],
                      folder: URL?) async -> String? {
        await perform(folder: folder) { env, projectRoot in
            _ = try SkillFileOps(env: env, projectRoot: projectRoot)
                .importFolder(source, name: name, scope: scope, agents: agents,
                              env: env, projectRoot: projectRoot)
        }
    }

    /// `onlyWhenCalled`: nil when the form left it as it found it
    /// (`SkillFileOps.edit`).
    func edit(row: SkillRow, expected: String, description: String, body: String,
              onlyWhenCalled: Bool?, folder: URL?) async -> String? {
        guard let real = row.realPath else { return Self.describe(.readOnly) }
        return await perform(folder: folder) { env, projectRoot in
            try SkillFileOps(env: env, projectRoot: projectRoot)
                .edit(realPath: real, expected: expected, description: description,
                      body: body, onlyWhenCalled: onlyWhenCalled)
        }
    }

    /// Set one agent's state for a skill.
    ///
    /// * "Only when I call it" on a skill SipAI edits goes into the
    ///   skill's OWN files (`disable-model-invocation` for Claude and
    ///   Kimi, codex's `agents/openai.yaml`), so every agent that has it
    ///   reads the same thing; on a skill an agent manages itself only
    ///   Claude's switch can say it.
    /// * Off is the agent's own switch: Claude's, saved for the folder;
    ///   Codex's, everywhere. Kimi has none.
    /// * On clears whichever of the two stands in the way.
    func setState(row: SkillRow, agent: String, state: SkillState, folder: URL?,
                  label: String) async -> String? {
        guard let entry = row.entries[agent] else { return nil }
        let current = row.states[agent] ?? .on
        let fromFile = SkillGrouping.fileState(of: entry)
        var failure: String? = nil
        switch state {
        case .userInvocableOnly where !row.isReadOnly:
            if current == .off || (agent == SkillAgent.claude && current != fromFile) {
                failure = await agentSwitch(entry: entry, agent: agent, state: .on, folder: folder, label: label)
            }
            return await setOnlyWhenCalled(row: row, true, folder: folder) ?? failure
        case .on:
            if !row.isReadOnly, fromFile == .userInvocableOnly {
                failure = await setOnlyWhenCalled(row: row, false, folder: folder)
            }
            // The agent's own switch says something the files do not.
            if current != fromFile {
                failure = await agentSwitch(entry: entry, agent: agent, state: .on, folder: folder, label: label) ?? failure
            }
        default:
            failure = await agentSwitch(entry: entry, agent: agent, state: state, folder: folder, label: label)
        }
        revision &+= 1
        // An agent's own switch reaches past this folder — Codex's is
        // for every folder — so no other folder's read stands either.
        distrustReads()
        await refresh(folder: folder)
        return failure
    }

    /// An agent's own tool that could not be asked, or gave no answer.
    nonisolated static func noAnswer(_ label: String) -> String {
        String(localized: "\(label) did not answer.",
               comment: "Skills: an agent's own tool gave no answer to a switch, or could not be run; placeholder is the agent label")
    }

    /// An agent's own tool that refused a switch and said nothing.
    nonisolated static func refused(_ label: String) -> String {
        String(localized: "\(label) refused the change.",
               comment: "Skills: an agent refused a switch without words; placeholder is the agent label")
    }

    nonisolated static func switchRefusal(row: SkillRow, agent: String, label: String) -> String? {
        SkillSwitchRule.refusal(row: row, agent: agent, label: label)
    }

    private func agentSwitch(entry: SkillEntry, agent: String, state: SkillState,
                             folder: URL?, label: String) async -> String? {
        switch agent {
        case SkillAgent.claude:
            // No tool to ask — it is being updated, or was removed since
            // the pane was drawn — is a switch that did not happen, and
            // nil would say it had.
            guard let bin = AgentManager.binaryPath(for: agent) else { return Self.noAnswer(label) }
            let base = await Self.childEnvironment()
            let cwd = folder.map { SkillRoots.projectRoot(of: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser
            let name = entry.name
            let words = await Task.detached(priority: .userInitiated) {
                ClaudeSkillProbe.write(binary: bin, cwd: cwd, name: name, state: state, environment: base)
            }.value
            // Refused with nothing said is still refused.
            return words.map { $0.isEmpty ? Self.refused(label) : $0 }
        case SkillAgent.codex:
            guard let bin = AgentManager.binaryPath(for: agent) else { return Self.noAnswer(label) }
            // The skill's OWN path, listed by codex or not — never the
            // path codex gave for its NAME: a skill codex skipped, or a
            // link to nothing, would switch whichever other skill of
            // that name codex did list.
            guard let real = entry.realPath else { return Self.describe(.notASkill(entry.entryPath)) }
            let path = (real as NSString).appendingPathComponent("SKILL.md")
            return await CodexSkillList.write(binary: bin, path: path, enabled: state != .off,
                                              label: label)
        default:
            return Self.switchRefusal(row: SkillRow(id: "", name: entry.name, description: "",
                                                    scope: entry.scope, home: .library, realPath: nil,
                                                    entries: [:], frontmatter: entry.frontmatter),
                                      agent: agent, label: label)
        }
    }

    /// What giving a skill to `agent` would do — the steps, and what its
    /// files need first — worked out before anything is written, so a
    /// share that cannot be done is refused with words and one that can
    /// is done at once. Nil for a skill SipAI does not share.
    func reviewShare(row: SkillRow, with agent: String, folder: URL?) async -> SkillShareReview? {
        guard let real = row.realPath else { return nil }
        let base = await Self.childEnvironment()
        let env = SkillEnvironment.resolve(base, home: FileManager.default.homeDirectoryForCurrentUser)
        let projectRoot = folder.map { SkillRoots.projectRoot(of: $0) }
        guard let plan = SkillPlanner.plan(row: row, agent: agent, include: true, env: env,
                                           projectRoot: projectRoot) else { return nil }
        let taken = snapshot(folder: folder)
            .map { SkillListing.nameTaken(by: agent, for: row, in: $0.rows) } ?? false
        let check = await Task.detached(priority: .userInitiated) {
            SkillFileOps(env: env, projectRoot: projectRoot)
                .shareCheck(realPath: real, target: agent, nameTaken: taken)
        }.value
        return SkillShareReview(plan: plan, check: check)
    }

    /// What making `agent` able to load a skill it already has takes.
    func reviewFix(row: SkillRow, for agent: String, folder: URL?) async -> SkillShareCheck? {
        guard let real = row.realPath, !row.isReadOnly else { return nil }
        let base = await Self.childEnvironment()
        let env = SkillEnvironment.resolve(base, home: FileManager.default.homeDirectoryForCurrentUser)
        let projectRoot = folder.map { SkillRoots.projectRoot(of: $0) }
        return await Task.detached(priority: .userInitiated) {
            SkillFileOps(env: env, projectRoot: projectRoot)
                .shareCheck(realPath: real, target: agent, nameTaken: false, carrySettings: false)
        }.value
    }

    /// What taking a skill from `agent` would do, for the pane to describe
    /// before it is done. Nil for a skill SipAI does not change.
    func reviewRemove(row: SkillRow, from agent: String, folder: URL?) async -> SkillSharePlan? {
        let base = await Self.childEnvironment()
        let env = SkillEnvironment.resolve(base, home: FileManager.default.homeDirectoryForCurrentUser)
        let projectRoot = folder.map { SkillRoots.projectRoot(of: $0) }
        return SkillPlanner.plan(row: row, agent: agent, include: false, env: env,
                                 projectRoot: projectRoot, keepWhenLast: false, present: Self.agentsPresent())
    }

    /// The agents whose tool is on this Mac, listed in SipAI or not.
    nonisolated static func agentsPresent() -> Set<String> {
        Set(SkillAgent.all.filter { AgentManager.binaryPath(for: $0) != nil })
    }

    /// "Only when I call it" in the skill's own files — every agent that
    /// has the skill reads it.
    func setOnlyWhenCalled(row: SkillRow, _ on: Bool, folder: URL?) async -> String? {
        guard let real = row.realPath, !row.isReadOnly else { return Self.describe(.readOnly) }
        return await perform(folder: folder) { env, projectRoot in
            try SkillFileOps(env: env, projectRoot: projectRoot).setOnlyWhenCalled(realPath: real, on)
        }
    }

    /// A sentence for a failed file operation.
    nonisolated static func describe(_ error: SkillOpError) -> String {
        error.sentence
    }
}
