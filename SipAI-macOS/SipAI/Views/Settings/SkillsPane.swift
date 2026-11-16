// SkillsPane.swift
// Settings → Agent Skills: each listed agent's skills under that agent — the
// skills of every folder, the chosen folder's own, its plugins' and the
// ones it ships with — and the library skills no agent has.
//
// One real skill folder can belong to several agents. SipAI keeps the
// files of a skill it shares in its own library and links them into each
// agent's skills folder, so the skill is drawn under every agent that has
// it, with the others named beside it, and one edit reaches them all. A
// skill's … menu gives it to another agent (Share With), fixing first
// whatever in its SKILL.md that agent would skip it over
// (`SkillShareCheck`), and takes it from the agent whose section it is
// drawn in alone (Delete).
//
// Type and gaps are the Display pane's: 14 pt section headers and rows,
// 12 pt explanations, 12 pt between blocks, a rule between sections.

import SwiftUI
import AppKit

struct SkillsPane: View {
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var agents: AgentManager
    @EnvironmentObject var appState: AppState
    @ObservedObject private var catalog = SkillCatalog.shared
    @Environment(\.sipFontScale) private var fontScale

    @State private var query = ""
    /// The last write that failed, in words; drawn until dismissed or the
    /// next write.
    @State private var failure: String? = nil
    /// Skills with a write in flight.
    @State private var working: Set<String> = []
    @State private var editor: SkillEditorRequest? = nil
    /// The folder the editor's skill was read in: the page's, or a
    /// subfolder's for a skill drawn under one.
    @State private var editorFolder: URL? = nil
    @State private var importRequest: SkillImportRequest? = nil
    /// The folders the menu lists: the ones browsed here that are on disk,
    /// newest first (`SkillFolderHistory.current`), as they stood when
    /// the page appeared or last changed folder. Held, not asked for as
    /// the page draws: the menu's content is built on every pass, and
    /// "is it on disk" is a file-system call for each folder.
    @State private var browsed: [SkillFolderHistory.Visit] = []
    /// A fix or a delete waiting for the user's yes.
    @State private var confirming: Pending? = nil

    struct Pending: Identifiable {
        enum Action {
            case fix(SkillShareCheck)
            case remove(SkillSharePlan)
            /// A skill no agent has, to the Trash.
            case delete
        }
        let row: SkillRow
        /// The agent fixed for, or taken from.
        let agent: String?
        /// The folder the row was read in — the one the action is for,
        /// whatever the folder menu says by the time it is confirmed.
        let folder: URL?
        let action: Action
        var id: String { row.id + "|" + (agent ?? "") }
    }

    // MARK: Derived

    var listedAgents: [String] {
        SkillAgent.all.filter { agents.presence(for: $0) == .listed }
    }

    private var folder: URL? { appState.skillsFolder }

    private var snapshot: SkillSnapshot? { catalog.snapshot(folder: folder) }

    private var ratio: CGFloat { SipFont.ratio(fontScale) }

    /// One step of indentation: a chevron and the gap after it, so a
    /// group's title sits under its section's, and a skill under its
    /// group's. The two parts scale with it, or the columns part ways
    /// at every tier but Default.
    private var step: CGFloat { chevronWidth + chevronGap }
    private var chevronWidth: CGFloat { 12 * ratio }
    private var chevronGap: CGFloat { 6 * ratio }

    func label(_ agent: String) -> String {
        let fallback = AgentManager.registry.first { $0.key == agent }?.name ?? agent
        return config.agentLabel(for: agent, defaultName: fallback)
    }

    private static var globalWord: String {
        String(localized: "Global", comment: "Skills: the skills every folder has, as a place — the folder menu's choice and title")
    }

    /// What the folder menu shows: the chosen folder's name, or Global.
    private var folderName: String { folder?.lastPathComponent ?? Self.globalWord }

    private var sheetUp: Bool { editor != nil || importRequest != nil }

    /// Whether the chosen folder has a scope of its own for a new skill.
    /// One whose project root is the home folder (a home kept in git)
    /// has none: its `.claude/skills` IS `~/.claude/skills`, so a skill
    /// made "only for this folder" would be a global one.
    private var offersFolderScope: Bool {
        // Not before the folder has been read: its root is not known
        // yet, and "only this folder" in one whose root is the home
        // folder writes a global skill.
        guard folder != nil, let root = snapshot?.projectRoot else { return false }
        return root != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    }

    /// The name of the folder a folder skill, and Claude's switch, are
    /// saved for: the chosen folder's project root — the repository it
    /// sits in — which is not the chosen folder when that is a folder
    /// inside one.
    var scopeName: String? { scopeName(for: folder) }

    /// The same for a skill read in `folder` — a subfolder's.
    func scopeName(for folder: URL?) -> String? {
        guard let folder else { return nil }
        return catalog.snapshot(folder: folder)?.projectRoot.map { ($0 as NSString).lastPathComponent }
            ?? folder.lastPathComponent
    }

    /// Whether the folder Claude's switch is saved for is the home
    /// folder itself — a folder whose project root is the home folder.
    func scopeIsHome(for folder: URL?) -> Bool {
        Self.scopeIsHome(folder: folder,
                         projectRoot: folder.flatMap { catalog.snapshot(folder: $0)?.projectRoot },
                         home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The rule alone: no folder is Global, whose switch is the home
    /// folder's; a folder's is its project root's, or its own outside
    /// a project.
    static func scopeIsHome(folder: URL?, projectRoot: String?, home: URL) -> Bool {
        guard let folder else { return true }
        let root = projectRoot ?? folder.standardizedFileURL.path
        return SkillRoots.pathURL(URL(fileURLWithPath: root, isDirectory: true)).path
            == SkillRoots.pathURL(home).path
    }

    /// The chosen folder's subfolders with skills of their own, as the
    /// catalog's walk last found them (`SkillCatalog.findSubfolders`).
    private var below: SkillSubfolders? { catalog.subfolders(of: folder) }

    private var subfolders: [URL] {
        (below?.found ?? []).map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Skills", comment: "Settings pane header")
                .sipFont(14, weight: .semibold)

            Text("Each agent uses the skills in its own skills folder. Share With, in a skill’s … menu, gives it to another agent: SipAI keeps one copy in its library and links it into each agent that has it, so one edit changes it for all of them.",
                 comment: "Skills pane: what the pane shows and how sharing works")
                .sipFont(12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            toolbar

            // The folder on a row of its own, under the search: left
            // aligned, nothing beside it.
            HStack(spacing: 0) {
                folderMenu
                Spacer(minLength: 0)
            }

            if let failure {
                failureLine(failure)
            }

            Divider().padding(.vertical, 4)

            content
        }
        .onAppear {
            browsed = listedHistory()
            pickDefaultFolder()
            record(folder)
            catalog.ensureLoaded(folder: folder, maxAge: 5)
            loadSubfolders(walk: true)
        }
        .onChange(of: appState.skillsFolder) { _, next in
            record(next)
            catalog.ensureLoaded(folder: next, maxAge: 5)
            loadSubfolders(walk: true)
        }
        .onChange(of: below?.found) { _, _ in loadSubfolders() }
        // A write anywhere can change what a subfolder's read holds (a
        // global skill moved, a name now taken) and which subfolders
        // hold skills at all, and every write leaves no earlier read
        // trusted (`SkillCatalog.perform`).
        .onChange(of: catalog.revision) { _, _ in loadSubfolders(walk: true) }
        .sheet(item: $editor) { request in
            SkillEditorSheet(request: request, agentLabels: listedAgents.map { ($0, label($0)) },
                             folder: editorFolder, scopeName: scopeName, offersFolderScope: offersFolderScope,
                             onFinish: { editor = nil; failure = $0 })
        }
        .sheet(item: $importRequest) { request in
            SkillImportSheet(request: request, agentLabels: listedAgents.map { ($0, label($0)) },
                             folder: folder, scopeName: scopeName, offersFolderScope: offersFolderScope,
                             onFinish: { importRequest = nil; failure = $0 })
        }
        .onChange(of: sheetUp) { _, up in SidebarNotices.shared.setSheetPresented(up) }
        // Torn down with a sheet up — a notification click closes
        // Settings underneath it — the report goes with the sheet. And
        // the subfolders still waiting to be read are let go: nobody is
        // looking at this page.
        .onDisappear {
            if sheetUp { SidebarNotices.shared.setSheetPresented(false) }
            catalog.ensureLoaded(folders: [])
        }
        .alert(confirmTitle,
               isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { pending in
            Button(confirmButton(pending), role: isDestructive(pending) ? .destructive : nil) {
                carryOut(pending)
            }
            Button(String(localized: "Cancel", comment: "Skills: keep the skill as it is"), role: .cancel) {}
        } message: { pending in
            Text(verbatim: confirmMessage(pending))
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .sipFont(13)
                    .foregroundColor(SipDesign.textSecondary)
                SearchField(text: $query,
                            placeholder: String(localized: "Search skills",
                                                comment: "Placeholder of the skills pane's search field"),
                            fontSize: SipFont.scaled(14, fontScale))
                    .frame(minHeight: 18 * ratio)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 80 * ratio, maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(SipDesign.rowHover))

            // Its subfolders' reads too — the one under way and the ones
            // waiting their turn: theirs land after the folder's own.
            if snapshot != nil, catalog.loading.contains(SkillCatalog.key(folder)) || readingSubfolders {
                ProgressView().controlSize(.small)
            }
            Button {
                Task {
                    await catalog.refresh(folder: folder)
                    loadSubfolders(maxAge: 0, walk: true)
                }
            } label: {
                Image(systemName: "arrow.clockwise").sipFont(13)
            }
            .buttonStyle(.plain)
            .foregroundColor(SipDesign.textSecondary)
            .help(String(localized: "Read the skills again", comment: "Skills: refresh button tooltip"))
            .accessibilityLabel(String(localized: "Read the skills again", comment: "Skills: refresh button tooltip"))

            Menu {
                Button(String(localized: "From a Folder…", comment: "Skills: add a skill from a folder")) {
                    chooseImportFolder()
                }
                Button(String(localized: "From a .zip or .skill File…",
                              comment: "Skills: add a skill from an archive")) {
                    chooseImportArchive()
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Add…", comment: "Skills: menu that adds an existing skill")
                        .sipFont(14)
                    Image(systemName: "chevron.down")
                        .sipFont(10, weight: .semibold)
                }
                .foregroundColor(SipDesign.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(listedAgents.isEmpty)

            SettingsProminentButton(title: String(localized: "New Skill",
                                                  comment: "Skills: create a skill")) {
                editorFolder = folder
                editor = .new
            }
            .fixedSize()
            .disabled(listedAgents.isEmpty)
        }
    }

    private var folderMenu: some View {
        Menu {
            Button(Self.globalWord) {
                appState.skillsFolderChosen = true
                appState.skillsFolder = nil
            }
            let recent = recentFolders
            if !recent.isEmpty {
                Divider()
                ForEach(recent, id: \.path) { url in
                    Button((url.path as NSString).abbreviatingWithTildeInPath) {
                        appState.skillsFolderChosen = true
                        appState.skillsFolder = url
                    }
                }
            }
            Divider()
            Button(String(localized: "Choose Folder…", comment: "Skills: pick a folder for its own skills")) {
                chooseFolder()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder").sipFont(13)
                Text(verbatim: folderName)
                    .sipFont(14)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .sipFont(10, weight: .semibold)
            }
            .foregroundColor(SipDesign.textPrimary)
            // Flush with the page's left edge, where the title and the
            // section headers start; the click area runs on to the right.
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // Not fixed: in a narrow column a long name gives way, cut in
        // the middle, rather than running past the page.
        .fixedSize(horizontal: false, vertical: true)
        .help(folder.map { (($0.path as NSString).abbreviatingWithTildeInPath) }
              ?? String(localized: "The skills every folder has", comment: "Skills: folder menu tooltip with no folder"))
    }

    /// The folders browsed here, newest first: ten at most, none not
    /// browsed for a month, none not on disk (`browsed`).
    private var recentFolders: [URL] {
        browsed.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    /// What the menu lists, out of the history as it is kept.
    private func listedHistory() -> [SkillFolderHistory.Visit] {
        SkillFolderHistory.current(SkillFolderHistory.load(), now: Date(), exists: SkillFolderHistory.isFolder)
    }

    /// A folder the page shows has been browsed. Added to the history as
    /// it is kept, never to this page's copy of it: a copy read earlier
    /// and written back takes whatever was browsed since with it. Nothing
    /// is dropped for not being on disk: the menu leaves such a folder
    /// out, and it is back when its disk is.
    private func record(_ url: URL?) {
        if let url {
            SkillFolderHistory.save(SkillFolderHistory.recording(url.standardizedFileURL.path, at: Date(),
                                                                 in: SkillFolderHistory.load()))
        }
        browsed = listedHistory()
    }

    /// Until the user picks one: the open session's folder, else the
    /// folder browsed last, else the newest session's.
    private func pickDefaultFolder() {
        guard !appState.skillsFolderChosen else { return }
        if let id = appState.openAgentSessionId,
           let path = agents.sessions.first(where: { $0.id == id })?.projectPath {
            appState.skillsFolder = path.standardizedFileURL
        } else if let last = recentFolders.first {
            appState.skillsFolder = last
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            appState.skillsFolder = agents.sessions.sorted(by: { $0.activityAt > $1.activityAt })
                .lazy.compactMap { $0.projectPath?.standardizedFileURL }
                .first { $0.path != home }
        }
    }

    /// Read the chosen folder's subfolders that hold skills, one after
    /// another (`SkillCatalog.ensureLoaded(folders:)`) — and, with
    /// `walk`, look below the folder for them again first
    /// (`findSubfolders`; what it finds comes back through
    /// `.onChange(of: below?.found)`). An empty list is handed over too:
    /// it lets go of what was waiting for the folder shown before.
    private func loadSubfolders(maxAge: TimeInterval = 5, walk: Bool = false) {
        if walk, let folder { catalog.findSubfolders(of: folder) }
        catalog.ensureLoaded(folders: subfolders, maxAge: maxAge)
    }

    /// A subfolder's read is under way, or waiting its turn.
    private var readingSubfolders: Bool {
        subfolders.contains { url in
            let k = SkillCatalog.key(url)
            return catalog.loading.contains(k) || catalog.waiting.contains(k)
        }
    }

    private func failureLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .sipFont(12)
                .foregroundColor(.orange)
            Text(verbatim: text)
                .sipFont(12)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { failure = nil } label: {
                Image(systemName: "xmark").sipFont(11)
            }
            .buttonStyle(.plain)
            .foregroundColor(SipDesign.textSecondary)
            .accessibilityLabel(String(localized: "Dismiss", comment: "Skills: close the failure line"))
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if listedAgents.isEmpty {
            Text("No agent is set up yet. Install and sign in to one in Settings → Agent Initialization.",
                 comment: "Skills pane when no agent is listed")
                .sipFont(12)
                .foregroundStyle(.secondary)
        } else if let snapshot {
            let sections = sections(snapshot)
            if sections.isEmpty {
                Text("No skill matches.", comment: "Skills: the search found nothing")
                    .sipFont(12)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        if index > 0 { Divider().padding(.vertical, 4) }
                        sectionView(section)
                    }
                    if below?.stoppedEarly == true {
                        // True of both ways the walk stops early: it had
                        // found as many subfolders as it shows, or looked
                        // in as many folders as it looks in — with or
                        // without a skill among them.
                        Text("SipAI didn’t look in every subfolder here, so one with skills may be missing. Choose Folder… in the folder menu shows a subfolder’s own skills.",
                             comment: "Skills: the page stopped looking below the chosen folder before it had been through every subfolder")
                            .sipFont(12)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading skills…", comment: "Skills pane on its first read")
                    .sipFont(12)
                    .foregroundStyle(.secondary)
            }
        }
    }

    struct PaneSection: Identifiable {
        let id: String
        let title: String
        /// The agent whose skills these are; nil for Not in use.
        let agent: String?
        let note: String?
        let groups: [PaneGroup]
        var count: Int { groups.reduce(0) { $0 + $1.rows.count } }
    }

    struct PaneGroup: Identifiable {
        let id: String
        let title: String
        let rows: [SkillRow]
        let foldedByDefault: Bool
        /// The folder the rows were read in — what their actions are for:
        /// the page's, or a subfolder's. No default: a group made without
        /// one has every action of its rows made for Global.
        let folder: URL?
        /// What is drawn in the group's place when the agent has no skill
        /// of its own there: "No global skills", "No skills in Atlas".
        var emptyLine: String? = nil
        /// What the header says on hover; nil for nothing.
        var help: String? = nil
    }

    private func sections(_ snapshot: SkillSnapshot) -> [PaneSection] {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let rows = snapshot.rows.filter(matches)
        // Each subfolder as its own read has it, once that read is in —
        // cut down once to what sits at the subfolder's own level, by
        // the level its walk made (no file-system call here: this runs
        // on every pass).
        let reads: [(SkillLevel, [SkillRow])] = (self.below?.found ?? []).compactMap { level in
            catalog.snapshot(folder: URL(fileURLWithPath: level.path, isDirectory: true))
                .map { (level, SkillListing.rows($0.rows, at: level).filter(matches)) }
        }
        var out: [PaneSection] = []
        for agent in listedAgents {
            let mine = SkillListing.rows(of: agent, in: rows)
            let below = reads.compactMap { level, own -> PaneGroup? in
                let found = SkillListing.rows(of: agent, in: own, at: level)
                return found.isEmpty ? nil : subfolderGroup(found, prefix: agent, at: level, agents: true)
            }
            if searching && mine.isEmpty && below.isEmpty { continue }
            // A search that finds nothing in a group says nothing about
            // what the group holds, so only the unfiltered list says
            // "no skills".
            out.append(PaneSection(id: "agent:" + agent, title: label(agent), agent: agent, note: nil,
                                   groups: groups(mine, prefix: agent, saysWhenEmpty: !searching, below: below)))
        }
        let unused = SkillListing.unused(rows, listed: listedAgents)
        let unusedBelow = reads.compactMap { level, own -> PaneGroup? in
            let found = SkillListing.unused(own, listed: listedAgents, at: level)
            return found.isEmpty ? nil : subfolderGroup(found, prefix: "unused", at: level, agents: false)
        }
        if !unused.isEmpty || !unusedBelow.isEmpty {
            out.append(PaneSection(id: "unused",
                                   title: String(localized: "Not in use", comment: "Skills: section of library skills no agent has"),
                                   agent: nil,
                                   note: String(localized: "In SipAI’s library, given to no agent. Share one to use it again.",
                                                comment: "Skills: what the Not in use section holds"),
                                   groups: groups(unused, prefix: "unused", saysWhenEmpty: false, below: unusedBelow)))
        }
        return out
    }

    /// One subfolder's skills under one agent — or, for `agents: false`,
    /// its library skills no agent has: titled with where they are below
    /// the chosen folder, and acted on in that subfolder.
    private func subfolderGroup(_ rows: [SkillRow], prefix: String, at level: SkillLevel, agents: Bool) -> PaneGroup {
        let base = folder?.standardizedFileURL.path ?? ""
        let path = level.path
        let name = !base.isEmpty && path.hasPrefix(base + "/")
            ? String(path.dropFirst(base.count + 1)) : (path as NSString).lastPathComponent
        let place = (path as NSString).abbreviatingWithTildeInPath
        return PaneGroup(id: prefix + "|subfolder:" + path,
                         title: String(localized: "Subfolder · \(name)",
                                       comment: "Skills: group of the skills that live in a folder below the chosen one — an agent's, or library skills no agent has; placeholder is that folder's path from the chosen one, e.g. packages/web"),
                         rows: sortedByName(rows), foldedByDefault: false,
                         folder: URL(fileURLWithPath: path, isDirectory: true),
                         help: agents
                            ? String(localized: "In \(place). Sessions started there have them.",
                                     comment: "Skills: tooltip of a subfolder's group of an agent's skills; placeholder is the subfolder's path")
                            : String(localized: "In \(place)",
                                     comment: "Skills: tooltip of a subfolder's group of library skills no agent has; placeholder is the subfolder's path"))
    }

    private func sortedByName(_ rows: [SkillRow]) -> [SkillRow] {
        rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `saysWhenEmpty`: an agent's own skills are named even when there
    /// are none, with a line in the group's place — the global ones only
    /// when Global is what the page shows, the chosen folder's when a
    /// folder is. Plugins and built-ins are an agent's to have or not,
    /// and are simply left out. `below`: the agent's skills in the chosen
    /// folder's subfolders, a group for each, after the folder's own.
    private func groups(_ rows: [SkillRow], prefix: String, saysWhenEmpty: Bool,
                        below: [PaneGroup] = []) -> [PaneGroup] {
        let global = rows.filter { !$0.isReadOnly && $0.scope == .global }
        let local = rows.filter { !$0.isReadOnly && $0.scope == .folder }
        let plugins = rows.filter { if case .readOnly(let l) = $0.home { return l == "Plugin" }; return false }
        let builtIn = rows.filter { if case .readOnly(let l) = $0.home { return l != "Plugin" }; return false }
        var out: [PaneGroup] = []
        if !global.isEmpty {
            out.append(PaneGroup(id: prefix + "|global", title: Self.skillsTitle(Self.globalWord),
                                 rows: sortedByName(global), foldedByDefault: false, folder: folder))
        } else if saysWhenEmpty, folder == nil {
            out.append(PaneGroup(id: prefix + "|global", title: "", rows: [], foldedByDefault: false, folder: folder,
                                 emptyLine: String(localized: "No global skills",
                                                   comment: "Skills: an agent has no skill of its own for every folder")))
        }
        if !local.isEmpty {
            // Keyed by the folder: folded for one folder, a group of
            // this name opened folded for every other.
            out.append(PaneGroup(id: prefix + "|folder:" + (folder?.path ?? ""),
                                 title: Self.skillsTitle(folder?.lastPathComponent ?? ""),
                                 rows: sortedByName(local), foldedByDefault: false, folder: folder))
        } else if saysWhenEmpty, let name = folder?.lastPathComponent {
            // With skills in its subfolders right below, "no skills in
            // <the folder>" would say it holds none.
            let line = below.isEmpty
                ? String(localized: "No skills in \(name)",
                         comment: "Skills: an agent has no skill of its own in the chosen folder; placeholder is the folder's name")
                : String(localized: "No skills in \(name) itself",
                         comment: "Skills: an agent has no skill in the chosen folder, only in folders below it; placeholder is the folder's name")
            out.append(PaneGroup(id: prefix + "|folder:" + (folder?.path ?? ""), title: "", rows: [], foldedByDefault: false,
                                 folder: folder, emptyLine: line))
        }
        out += below
        if !plugins.isEmpty {
            out.append(PaneGroup(id: prefix + "|plugins",
                                 title: String(localized: "Plugins", comment: "Skills: group of plugin skills"),
                                 rows: sortedByName(plugins), foldedByDefault: true, folder: folder))
        }
        if !builtIn.isEmpty {
            out.append(PaneGroup(id: prefix + "|builtin",
                                 title: String(localized: "Built-in", comment: "Skills: group of skills an agent ships with"),
                                 rows: sortedByName(builtIn), foldedByDefault: true, folder: folder))
        }
        return out
    }

    /// "Skills · Atlas", "Skills · Global".
    private static func skillsTitle(_ place: String) -> String {
        String(localized: "Skills · \(place)",
               comment: "Skills: group of an agent's own skills; placeholder is the folder's name, or Global")
    }

    private func matches(_ row: SkillRow) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return row.name.localizedCaseInsensitiveContains(q)
            || row.description.localizedCaseInsensitiveContains(q)
    }

    /// A search shows what it found: a match inside a folded group — the
    /// plugins and built-ins start folded — was counted on its header and
    /// drawn nowhere.
    private func isFolded(_ id: String, byDefault: Bool) -> Bool {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return byDefault != appState.skillGroupsToggled.contains(id)
    }

    private func toggleFold(_ id: String) {
        if appState.skillGroupsToggled.contains(id) {
            appState.skillGroupsToggled.remove(id)
        } else {
            appState.skillGroupsToggled.insert(id)
        }
    }

    private func sectionView(_ section: PaneSection) -> some View {
        let folded = isFolded(section.id, byDefault: false)
        return VStack(alignment: .leading, spacing: 12) {
            Button { toggleFold(section.id) } label: {
                HStack(spacing: chevronGap) {
                    Image(systemName: folded ? "chevron.right" : "chevron.down")
                        .sipFont(11, weight: .semibold)
                        .foregroundColor(SipDesign.textSecondary)
                        .frame(width: chevronWidth)
                    Text(verbatim: section.title)
                        .sipFont(14, weight: .semibold)
                        .foregroundColor(SipDesign.textPrimary)
                    Text(verbatim: "\(section.count)")
                        .sipFont(12)
                        .foregroundColor(SipDesign.textHint)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !folded {
                if let note = section.note {
                    Text(verbatim: note)
                        .sipFont(12)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, step)
                }
                ForEach(section.groups) { group in
                    groupView(group, agent: section.agent)
                }
            }
        }
    }

    @ViewBuilder
    private func groupView(_ group: PaneGroup, agent: String?) -> some View {
        if let line = group.emptyLine {
            // In the group's place, on the groups' own text column: the
            // words start where "Plugins" and "Built-in" start.
            Text(verbatim: line)
                .sipFont(13)
                .foregroundColor(SipDesign.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2 * step)
        } else {
            let folded = isFolded(group.id, byDefault: group.foldedByDefault)
            let header = Button { toggleFold(group.id) } label: {
                HStack(spacing: chevronGap) {
                    Image(systemName: folded ? "chevron.right" : "chevron.down")
                        .sipFont(10, weight: .semibold)
                        .frame(width: chevronWidth)
                    Text(verbatim: group.title)
                        .sipFont(13, weight: .medium)
                    Text(verbatim: "\(group.rows.count)")
                        .sipFont(12)
                        .foregroundColor(SipDesign.textHint)
                    Spacer()
                }
                .foregroundColor(SipDesign.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, step)
            VStack(alignment: .leading, spacing: 0) {
                // No tooltip at all rather than an empty one: `.help("")`
                // sets an EMPTY tooltip, not none.
                if let help = group.help { header.help(help) } else { header }
                if !folded {
                    ForEach(group.rows) { row in
                        SkillsPaneRow(row: row, agent: agent, folder: group.folder, pane: self,
                                      working: working.contains(row.id), indent: 2 * step)
                    }
                }
            }
        }
    }

    // MARK: Actions (called by the rows)

    /// Give `row` to `agent`: worked out first, refused with words when
    /// the agent could not load it, and otherwise done at once — one
    /// click, at the user's request: what a share moves and changes
    /// (the library and its links, the fixes for the agent's format, the
    /// settings carried over in its words, what it ignores) is told once,
    /// in Help ("What happens when I share a skill with another agent?"),
    /// not on every share. `folder` is
    /// the one the row was read in — the page's, or the subfolder's it is
    /// drawn under — whatever the folder menu says by then.
    func share(_ row: SkillRow, with agent: String, in folder: URL?) {
        failure = nil
        Task {
            guard let review = await catalog.reviewShare(row: row, with: agent, folder: folder) else {
                failure = SkillCatalog.describe(.readOnly)
                return
            }
            if let refusal = review.check.refusal {
                failure = refusalSentence(refusal, row: row, agent: agent)
            } else if let cannot = await catalog.refusal(of: review.plan, folder: folder) {
                failure = cannot
            } else {
                // The one thing a share can change that nobody asked for:
                // "only when I call it", set where the skill came from and
                // not writable where the new agent reads it. The share is
                // still made — and said, once it is: with the confirmation
                // gone, nothing else would.
                let lost = review.check.lostOnlyWhenCalled
                    ? String(localized: "“\(row.name)” is shared with \(label(agent)), but “Only When I Call It” couldn’t be carried over: \(label(agent)) may use it on its own.",
                             comment: "Skills: a share went through, but the skill's only-when-called setting could not be written for the new agent; placeholders are the skill, the agent, and the agent again")
                    : nil
                run(row, in: folder) {
                    await catalog.share(row: row, with: agent, check: review.check, folder: folder) ?? lost
                }
            }
        }
    }

    /// Make `agent` able to load a skill it already has.
    func fix(_ row: SkillRow, for agent: String, in folder: URL?) {
        failure = nil
        Task {
            guard let check = await catalog.reviewFix(row: row, for: agent, folder: folder) else {
                failure = SkillCatalog.describe(.readOnly)
                return
            }
            if let refusal = check.refusal {
                failure = refusalSentence(refusal, row: row, agent: agent)
            } else if check.fixes.isEmpty {
                // Fixed meanwhile, or never this app's to fix: read again.
                await catalog.refresh(folder: folder)
            } else {
                confirming = Pending(row: row, agent: agent, folder: folder, action: .fix(check))
            }
        }
    }

    /// Delete `row` from `agent`'s section: that agent alone loses it.
    /// Without an agent, a skill no agent has goes to the Trash.
    func delete(_ row: SkillRow, from agent: String?, in folder: URL?) {
        failure = nil
        guard let agent else {
            confirming = Pending(row: row, agent: nil, folder: folder, action: .delete)
            return
        }
        Task {
            guard let plan = await catalog.reviewRemove(row: row, from: agent, folder: folder) else {
                failure = SkillCatalog.describe(.readOnly)
                return
            }
            guard plan.blockedBy.isEmpty else {
                let both = ListFormatter.localizedString(byJoining: ([agent] + plan.blockedBy).map(label))
                failure = String(localized: "\(both) read this skill from one and the same folder, so it can’t be taken from one of them alone.",
                                 comment: "Skills: a removal refused because two agents' skills folders are one folder on disk; placeholder lists the agents")
                return
            }
            if let cannot = await catalog.refusal(of: plan, folder: folder) {
                failure = cannot
                return
            }
            confirming = Pending(row: row, agent: agent, folder: folder, action: .remove(plan))
        }
    }

    private func carryOut(_ pending: Pending) {
        let row = pending.row
        let folder = pending.folder
        switch pending.action {
        case .fix(let check):
            run(row, in: folder) { await catalog.fix(row: row, check: check, folder: folder) }
        case .remove:
            guard let agent = pending.agent else { return }
            run(row, in: folder) {
                let failure = await catalog.remove(row: row, from: agent, folder: folder)
                if failure == nil { unpin(row.name, for: [agent], folder: folder) }
                return failure
            }
        case .delete:
            run(row, in: folder) {
                let failure = await catalog.delete(row: row, folder: folder)
                if failure == nil { unpin(row.name, for: SkillAgent.all, folder: folder) }
                return failure
            }
        }
    }

    /// A skill an agent no longer has is not one its new sessions start
    /// with. Left pinned, every new session of that agent opened on a
    /// pick that names nothing — and the switch that set it was on the
    /// row that is gone.
    private func unpin(_ name: String, for agents: [String], folder: URL?) {
        let rows = catalog.snapshot(folder: folder)?.rows ?? []
        for agent in agents where config.agentSkillPreloads(for: agent).contains(name) {
            if !rows.contains(where: { $0.entries[agent]?.name == name }) {
                config.setAgentSkillPreload(name, on: false, for: agent)
            }
        }
    }

    func setState(_ row: SkillRow, agent: String, state: SkillState, in folder: URL?) {
        let name = label(agent)
        run(row, in: folder) { await catalog.setState(row: row, agent: agent, state: state, folder: folder, label: name) }
    }

    func setDefault(_ row: SkillRow, agent: String, on: Bool) {
        config.setAgentSkillPreload(row.name, on: on, for: agent)
    }

    func isDefault(_ row: SkillRow, agent: String) -> Bool {
        config.agentSkillPreloads(for: agent).contains(row.name)
    }

    /// The pin's title. An agent that takes one skill per message starts
    /// a session with one (`SkillAgent.oneSkillPerMessage`), so pinning a
    /// second takes the first's place — said on the item that does it,
    /// naming the one it replaces: unsaid, a skill stopped loading in new
    /// sessions with nothing on screen to show for it.
    func defaultTitle(_ row: SkillRow, agent: String) -> String {
        if SkillAgent.oneSkillPerMessage(agent),
           let current = config.agentSkillPreloads(for: agent).first, current != row.name {
            return String(localized: "Start New Sessions With It (instead of “\(current)”)",
                          comment: "Skills: preload the skill in every new session of an agent that holds one such skill at a time; placeholder is the skill it would replace")
        }
        return String(localized: "Start New Sessions With It",
                      comment: "Skills: preload the skill in every new session of the agent")
    }

    func edit(_ row: SkillRow, in folder: URL?) {
        editorFolder = folder
        editor = .edit(row)
    }

    func copyToLibrary(_ row: SkillRow) {
        guard let real = row.realPath else { return }
        importRequest = SkillImportRequest(source: URL(fileURLWithPath: real, isDirectory: true),
                                           cleanUp: nil)
    }

    /// `acted`: the folder the write was made for. The catalog re-reads
    /// that one; a subfolder's write can land in what the page's own
    /// folder reads too — one repository's root folders — so the page's
    /// is read again after it.
    private func run(_ row: SkillRow, in acted: URL?, _ work: @escaping () async -> String?) {
        failure = nil
        working.insert(row.id)
        let shown = folder
        Task {
            let result = await work()
            working.remove(row.id)
            // Only a failure is news: a write that went through says
            // nothing, least of all over another's failure line.
            if let result { failure = result }
            if SkillCatalog.key(acted) != SkillCatalog.key(shown) {
                await catalog.refresh(folder: shown)
            }
        }
    }

    // MARK: Words

    private func list(_ agents: [String]) -> String {
        ListFormatter.localizedString(byJoining: agents.map(label))
    }

    private var confirmTitle: String {
        guard let pending = confirming else { return "" }
        let name = pending.row.name
        let who = pending.agent.map(label) ?? ""
        switch pending.action {
        case .fix:
            return String(localized: "Fix “\(name)” for \(who)?",
                          comment: "Skills: title of the confirmation before a skill's files are fixed for an agent; placeholders are the skill and the agent")
        case .remove:
            return String(localized: "Delete “\(name)” from \(who)?",
                          comment: "Skills: title of the confirmation before a skill is taken from one agent; placeholders are the skill and the agent")
        case .delete:
            return String(localized: "Delete this skill?", comment: "Skills: title of the delete confirmation")
        }
    }

    private func confirmButton(_ pending: Pending) -> String {
        switch pending.action {
        case .fix:
            return String(localized: "Fix", comment: "Skills: confirm fixing a skill's files for an agent")
        case .remove, .delete:
            return String(localized: "Delete", comment: "Skills: confirm deleting a skill")
        }
    }

    private func isDestructive(_ pending: Pending) -> Bool {
        switch pending.action {
        case .remove, .delete: return true
        case .fix: return false
        }
    }

    private func confirmMessage(_ pending: Pending) -> String {
        let row = pending.row
        switch pending.action {
        case .fix(let check):
            guard let agent = pending.agent else { return "" }
            let lead = String(localized: "So that \(label(agent)) can load it, SipAI changes the skill’s own files:",
                              comment: "Skills: introduces the list of fixes that make a skill load for an agent; placeholder is the agent")
            return ([lead] + check.fixes.map { "• " + fixLine($0, row: row, agent: agent) })
                .joined(separator: "\n")
        case .remove(let plan):
            guard let agent = pending.agent else { return "" }
            // A link to nothing: there is no skill for anyone to keep,
            // and no folder to bin.
            if row.realPath == nil {
                return String(localized: "Only the link is removed: the folder it pointed at is gone.",
                              comment: "Skills: delete confirmation for a broken link")
            }
            var lines: [String] = []
            // The agents the plan leaves it with — not every other agent
            // in the row: a tool that is not on this Mac keeps nothing.
            let keepers = plan.keeps
            if plan.movesFiles, !keepers.isEmpty {
                lines.append(String(localized: "To take it from \(label(agent)) alone, SipAI moves its folder into its own library and links it for \(list(keepers)).",
                                    comment: "Skills: removing a skill from one agent moves its files; placeholders are the agent and the agents that keep it"))
            } else if !keepers.isEmpty {
                lines.append(String(localized: "It stays with \(list(keepers)).",
                                    comment: "Skills: the agents that keep a skill taken from another; placeholder lists them"))
            }
            if let trashed = plan.steps.lazy.compactMap({ step -> String? in
                if case .trash(let path) = step { return path }
                return nil
            }).first {
                lines.append(trashLine(trashed))
            } else if keepers.isEmpty, row.home == .elsewhere, !row.problems.contains(.brokenLink) {
                lines.append(String(localized: "Its folder is outside SipAI’s library, so it stays where it is.",
                                    comment: "Skills: delete confirmation for a linked folder SipAI does not manage"))
            }
            return lines.joined(separator: "\n")
        case .delete:
            return row.realPath.map(trashLine) ?? ""
        }
    }

    private func trashLine(_ path: String) -> String {
        String(localized: "Its folder goes to the Trash: \((path as NSString).abbreviatingWithTildeInPath)",
               comment: "Skills: delete confirmation, the folder that goes; placeholder is a path")
    }

    /// One change a fix makes to a skill's files, in words.
    private func fixLine(_ fix: SkillShareFix, row: SkillRow, agent: String) -> String {
        let who = label(agent)
        switch fix {
        case .removeByteOrderMark:
            return String(localized: "Removes an invisible byte-order mark before its header, which \(who) can’t read past.",
                          comment: "Skills: a fix before sharing; placeholder is the agent")
        case .addHeader(let name, let description):
            return String(localized: "Adds a header with its name, “\(name)”, and a description from its first line, “\(description)”.",
                          comment: "Skills: a fix before sharing; placeholders are the skill's name and the description written")
        case .addName(let name):
            return String(localized: "Adds its name, “\(name)”.",
                          comment: "Skills: a fix before sharing; placeholder is the name written")
        case .addDescription(let description):
            return String(localized: "Adds a description from its first line, “\(description)”.",
                          comment: "Skills: a fix before sharing; placeholder is the description written")
        case .joinDescription(let description):
            return String(localized: "Writes its description, now a list, as one line: “\(description)”.",
                          comment: "Skills: a fix before sharing; a description written as a list of items becomes one sentence; placeholder is the sentence written")
        case .quote(let keys):
            return String(localized: "Puts quotes around the value of \(ListFormatter.localizedString(byJoining: keys)).",
                          comment: "Skills: a fix before sharing; placeholder lists header keys, e.g. description")
        case .straightenHeader:
            return String(localized: "Removes the indentation from its header.",
                          comment: "Skills: a fix before sharing; the header's lines are moved to the left margin")
        case .clearTabLines:
            return String(localized: "Removes a tab that \(who) can’t read past from header lines that hold nothing else.",
                          comment: "Skills: a fix before sharing; placeholder is the agent")
        case .replaceLineSeparators:
            return String(localized: "Replaces an invisible line-break character in its header, which \(who) can’t read past, with a space.",
                          comment: "Skills: a fix before sharing; placeholder is the agent")
        case .onlyWhenCalledForCodex, .onlyWhenCalledInSkill:
            // A share's alone (`SkillShareCheck.make(carrySettings:)`), and
            // a share is one click with no list: never part of a Fix.
            return ""
        }
    }

    private func refusalSentence(_ refusal: SkillShareRefusal, row: SkillRow, agent: String) -> String {
        let who = label(agent)
        switch refusal {
        case .nameTaken:
            return String(localized: "\(who) already has another skill called “\(row.name)”, and would use only one of the two.",
                          comment: "Skills: a share refused over a name clash; placeholders are the agent and the skill")
        case .noSkillFile:
            return SkillCatalog.describe(.notASkill(row.realPath ?? row.name))
        case .cannotFix(let problem):
            return String(localized: "\(who) can’t load “\(row.name)”: \(SkillFormat.clause(problem)). Change that in its SKILL.md first.",
                          comment: "Skills: a share or fix refused over something only the user can change; placeholders are the agent, the skill and why")
        case .notSipAIs(let problem):
            return String(localized: "\(who) can’t load “\(row.name)”: \(SkillFormat.clause(problem)). Its folder is outside SipAI’s library, so change that where it lives first.",
                          comment: "Skills: a share or fix refused because the skill's files are not SipAI's to change; placeholders are the agent, the skill and why")
        case .folderName:
            return String(localized: "\(who) can’t load “\(row.name)”: \(SkillFormat.folderNameClause). Rename its folder first.",
                          comment: "Skills: a share refused because the skill's folder name has a character the agent offers no skill under; placeholders are the agent, the skill and why")
        }
    }

    // MARK: Pickers

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Skills: confirm a folder pick")
        panel.message = String(localized: "Show the skills of this folder",
                               comment: "Skills: folder picker explanation")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.skillsFolderChosen = true
        appState.skillsFolder = url.standardizedFileURL
    }

    private func chooseImportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add", comment: "Skills: confirm adding a skill folder")
        panel.message = String(localized: "Choose a skill’s folder — the one that holds its SKILL.md",
                               comment: "Skills: import folder picker explanation")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) else {
            failure = SkillCatalog.describe(.notASkill(url.path))
            return
        }
        importRequest = SkillImportRequest(source: url, cleanUp: nil)
    }

    private func chooseImportArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .init(filenameExtension: "skill") ?? .data]
        panel.prompt = String(localized: "Add", comment: "Skills: confirm adding a skill archive")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            switch await SkillArchive.unpack(url) {
            case .success(let unpacked):
                // A skill at the archive's top is in the scratch folder
                // itself, whose name is nobody's: the archive's is.
                importRequest = SkillImportRequest(
                    source: unpacked.skill, cleanUp: unpacked.scratch,
                    fallbackName: unpacked.skill == unpacked.scratch ? url.deletingPathExtension().lastPathComponent : nil)
            case .failure(let message):
                failure = message
            }
        }
    }
}

// MARK: - A row

/// One skill under one agent — or, in Not in use, under none.
private struct SkillsPaneRow: View {
    let row: SkillRow
    /// The agent whose section this is.
    let agent: String?
    /// The folder the row was read in — the page's, or a subfolder's —
    /// which every action of its menu is for.
    let folder: URL?
    let pane: SkillsPane
    let working: Bool
    let indent: CGFloat

    /// The pointer is on the … button — the one part of a row that
    /// answers it.
    @State private var moreHovered = false
    @State private var showingDetail = false
    @Environment(\.sipFontScale) private var fontScale

    /// The … button's box: what fills under the pointer, and all of it
    /// opens the menu.
    private var moreBox: CGSize {
        let ratio = SipFont.ratio(fontScale)
        return CGSize(width: 28 * ratio, height: 22 * ratio)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Button { showingDetail = true } label: {
                        Text(verbatim: row.name)
                            .sipFont(14)
                            .foregroundColor(SipDesign.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
                        SkillDetailView(row: row, agents: pane.listedAgents, label: pane.label)
                    }
                    .layoutPriority(1)
                    if let hint = sharedHint {
                        Text(verbatim: hint)
                            .italic()
                            .sipFont(12)
                            .foregroundColor(SipDesign.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(hint)
                    }
                    ForEach(tags, id: \.self) { tag in
                        SkillTag(tag: tag)
                    }
                    if pinned {
                        Image(systemName: "pin.fill")
                            .sipFont(11)
                            .foregroundColor(.orange)
                            .help(String(localized: "New sessions start with it",
                                         comment: "Skills: the pin beside a skill"))
                    }
                }
                if !row.description.isEmpty {
                    Text(verbatim: row.description)
                        .sipFont(12)
                        .foregroundColor(SipDesign.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(row.description)
                }
            }
            Spacer(minLength: 8)
            // The box is taller than a line of text; it reaches into the
            // row's own padding rather than making a one-line row taller.
            moreMenu
                .padding(.vertical, -3 * SipFont.ratio(fontScale))
        }
        .padding(.vertical, 6)
        .padding(.leading, indent)
    }

    /// "shared with Codex and Kimi Code" — the other listed agents that
    /// have it — and where its files are when that is the common folder:
    /// "shared with Kimi Code in the common folder".
    private var sharedHint: String? {
        guard let agent,
              let hint = SkillListing.hint(row, under: agent, listed: pane.listedAgents) else { return nil }
        guard !hint.sharedWith.isEmpty else {
            return String(localized: "in the common folder",
                          comment: "Skills: hint beside a skill whose files are in .agents/skills and that no other listed agent has")
        }
        let others = ListFormatter.localizedString(byJoining: hint.sharedWith.map(pane.label))
        if hint.inCommonFolder {
            return String(localized: "shared with \(others) in the common folder",
                          comment: "Skills: hint beside a skill in .agents/skills that other agents have too; placeholder lists the agents")
        }
        return String(localized: "shared with \(others)",
                      comment: "Skills: hint beside a skill other agents have too; placeholder lists the agents")
    }

    private var pinned: Bool {
        guard let agent, Self.chipAgent(agent) else { return false }
        return pane.isDefault(row, agent: agent)
    }

    /// Every agent has the chip now — Kimi's holds one skill at a time
    /// (`SkillAgent.oneSkillPerMessage`), and so does its default.
    static func chipAgent(_ agent: String) -> Bool {
        SkillAgent.all.contains(agent)
    }

    private var tags: [SkillTag.Model] {
        var out: [SkillTag.Model] = []
        if let agent, row.entries[agent] != nil {
            switch row.states[agent] ?? .on {
            case .userInvocableOnly:
                out.append(.init(text: Self.shortWord(.userInvocableOnly), warning: false,
                                 help: String(localized: "Only When I Call It", comment: "Skills state: only the user can start the skill")))
            case .off:
                out.append(.init(text: Self.shortWord(.off), warning: false, help: nil))
            case .on, .nameOnly:
                break
            }
            if let why = row.notLoaded(by: agent) {
                out.append(.init(text: String(localized: "Not loaded", comment: "Skills tag: the agent skips this skill"),
                                 warning: true, help: SkillFormat.notLoadedSentence(pane.label(agent), why)))
            }
        }
        switch row.home {
        // (A folder an agent reads itself between the project's root and
        // the chosen folder is elsewhere to SipAI too, and no link.)
        case .elsewhere where row.entries.values.contains(where: \.isLink) && !row.problems.contains(.brokenLink):
            out.append(.init(text: String(localized: "Linked folder", comment: "Skills tag: a skill whose folder is outside the library"),
                             warning: false, help: nil))
        case .readOnly(let label) where label != "Plugin" && label != "Built-in":
            // Inside its group a plugin's or a shipped skill says so
            // already; a claude.ai one is told apart from the built-ins.
            out.append(.init(text: SkillLabels.source(label), warning: false, help: nil))
        default:
            break
        }
        if row.problems.contains(.clash) {
            out.append(.init(text: String(localized: "Clash", comment: "Skills tag: two skills share a name"),
                             warning: true, help: nil))
        }
        if row.problems.contains(.brokenLink) {
            out.append(.init(text: String(localized: "Broken link", comment: "Skills tag: a link to nothing"),
                             warning: true, help: nil))
        }
        return out
    }

    /// Whether SipAI can make the section's agent load this skill: the
    /// agent skips it over something SipAI fixes, in files SipAI writes.
    private func offersFix(for agent: String) -> Bool {
        guard row.isManaged, row.notLoaded(by: agent) != nil else { return false }
        let problems = row.formatProblems.filter { SkillFormat.skips($0, agent: agent) }
        return !problems.isEmpty && problems.allSatisfy(SkillFormat.fixable)
    }

    /// Whether there is anything of this skill SipAI can take away: its
    /// files where SipAI manages them, or the agent's link to them. A
    /// folder the agent reads itself somewhere SipAI does not write —
    /// between the project's root and the chosen folder — is neither.
    private var canDelete: Bool {
        guard !row.isReadOnly else { return false }
        guard let agent else { return true }
        return row.isManaged || row.entries[agent]?.isLink == true
    }

    @ViewBuilder
    private var moreMenu: some View {
        if working {
            ProgressView().controlSize(.small)
                .frame(width: moreBox.width, height: moreBox.height)
        } else {
            Menu {
                // A link to nothing has no state to keep and no file to
                // open: its menu is the way to remove it.
                if let agent, row.entries[agent] != nil, !row.problems.contains(.brokenLink) {
                    Section(pane.label(agent)) {
                        stateItems(agent)
                    }
                    if Self.chipAgent(agent) {
                        Toggle(pane.defaultTitle(row, agent: agent),
                               isOn: Binding(get: { pane.isDefault(row, agent: agent) },
                                             set: { pane.setDefault(row, agent: agent, on: $0) }))
                    }
                    Divider()
                }
                let targets = SkillListing.shareTargets(row, from: agent, listed: pane.listedAgents)
                if !targets.isEmpty {
                    Menu(String(localized: "Share With", comment: "Skills: submenu that gives a skill to another agent")) {
                        ForEach(targets) { target in
                            if target.has {
                                // Already there: ticked, nothing to do.
                                Toggle(pane.label(target.agent), isOn: .constant(true))
                                    .disabled(true)
                            } else {
                                Button(pane.label(target.agent)) { pane.share(row, with: target.agent, in: folder) }
                            }
                        }
                    }
                }
                if let agent, offersFix(for: agent) {
                    Button(String(localized: "Fix for \(pane.label(agent))…",
                                  comment: "Skills: change a skill's files so the agent loads it; placeholder is the agent")) {
                        pane.fix(row, for: agent, in: folder)
                    }
                }
                if row.isManaged, row.realPath != nil {
                    Button(String(localized: "Edit…", comment: "Skills: edit a skill")) { pane.edit(row, in: folder) }
                }
                if row.isReadOnly, row.realPath != nil {
                    Button(String(localized: "Copy to My Skills…",
                                  comment: "Skills: make an editable copy of a skill an agent manages")) {
                        pane.copyToLibrary(row)
                    }
                }
                if let path = row.realPath ?? row.entries.values.first?.entryPath, !path.isEmpty {
                    Button(String(localized: "Show in Finder", comment: "Skills: reveal a skill's folder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    if row.realPath != nil {
                        Button(String(localized: "Open SKILL.md", comment: "Skills: open a skill's file")) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path).appendingPathComponent("SKILL.md"))
                        }
                    }
                }
                if canDelete {
                    Divider()
                    Button(String(localized: "Delete…", comment: "Skills: delete a skill"), role: .destructive) {
                        pane.delete(row, from: agent, in: folder)
                    }
                }
            } label: {
                // The box is the LABEL's, shape included: a plain menu
                // button answers a click only inside its label, and a
                // bare glyph is a strip a few points tall. The fill and
                // the click area are then one rectangle.
                Image(systemName: "ellipsis")
                    .sipFont(13)
                    .foregroundColor(moreHovered ? SipDesign.textPrimary : SipDesign.textSecondary)
                    .frame(width: moreBox.width, height: moreBox.height)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(moreHovered ? SipDesign.rowHover : Color.clear))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { moreHovered = $0 }
            .accessibilityLabel(String(localized: "Row actions",
                                       comment: "Accessibility label for the per-row … actions menu"))
        }
    }

    // MARK: The agent's state

    @ViewBuilder
    private func stateItems(_ agent: String) -> some View {
        stateItem(.on, agent: agent, title: Self.onWord)
        stateItem(.userInvocableOnly, agent: agent,
                  title: String(localized: "Only When I Call It", comment: "Skills state: only the user can start the skill"))
        stateItem(.off, agent: agent, title: offTitle(agent))
    }

    @ViewBuilder
    private func stateItem(_ value: SkillState, agent: String, title: String) -> some View {
        let state = row.states[agent] ?? .on
        let refusal = refusal(for: value, agent: agent)
        Toggle(title, isOn: Binding(get: { state == value || (value == .on && state == .nameOnly) },
                                    set: { if $0 { pane.setState(row, agent: agent, state: value, in: folder) } }))
            .disabled(refusal != nil && state != value)
        if let refusal, state != value {
            Text(verbatim: refusal)
        }
    }

    /// Why a state cannot be chosen here, nil when it can.
    private func refusal(for value: SkillState, agent: String) -> String? {
        switch value {
        case .off:
            return SkillCatalog.switchRefusal(row: row, agent: agent, label: pane.label(agent))
        case .userInvocableOnly where row.isReadOnly:
            return SkillCatalog.switchRefusal(row: row, agent: agent, label: pane.label(agent))
                ?? (agent == SkillAgent.codex
                    ? String(localized: "\(pane.label(agent)) can’t be told this for a skill it manages itself.",
                             comment: "Skills: why only-when-called is disabled for a codex plugin skill; placeholder is the agent label")
                    : nil)
        case .userInvocableOnly where !row.isManaged:
            // Written into the skill's own files, which sit in a folder
            // SipAI does not write to.
            return SkillCatalog.describe(.readOnly)
        case .on where !row.isManaged && row.entries[agent].map(SkillGrouping.fileState) == .userInvocableOnly:
            // And taken back out of them: the same files.
            return SkillCatalog.describe(.readOnly)
        default:
            return nil
        }
    }

    /// The Off item, with where the agent's own switch applies beside
    /// it: Claude saves it for one folder — the project folder of the
    /// one browsed, the home folder on Global — Codex everywhere. Kimi
    /// has no switch (its reason sits under the disabled item).
    private func offTitle(_ agent: String) -> String {
        switch agent {
        case SkillAgent.claude:
            // A project whose root IS the home folder (a home kept in
            // git) saves the switch where Global's is saved: named by the
            // account's folder it read "Off (applies to <user name>)".
            if let name = pane.scopeName(for: folder), !pane.scopeIsHome(for: folder) {
                return String(localized: "Off (applies to \(name))",
                              comment: "Skills state: Off for Claude, saved for one folder; placeholder is the folder")
            }
            return String(localized: "Off (applies to your home folder)",
                          comment: "Skills state: Off for Claude with no folder chosen, saved for the home folder")
        case SkillAgent.codex:
            return String(localized: "Off (applies to every folder)",
                          comment: "Skills state: Off for Codex, which applies everywhere")
        default:
            return String(localized: "Off", comment: "Skills state: the agent ignores the skill")
        }
    }

    /// A key of its own: the catalog's "On" is the schedule editor's
    /// weekday label, which reads differently in other languages.
    static let onWord = String(localized: "skills.state.on", defaultValue: "On",
                               comment: "Skills state and column word: the agent uses the skill freely")

    static func shortWord(_ state: SkillState) -> String {
        switch state {
        case .on, .nameOnly:
            return onWord
        case .userInvocableOnly:
            return String(localized: "When called", comment: "Skills column: only when the user calls it")
        case .off:
            return String(localized: "Off", comment: "Skills column: switched off")
        }
    }
}

private struct SkillTag: View {
    struct Model: Hashable {
        let text: String
        let warning: Bool
        /// What the tag means, on hover; nil for none.
        let help: String?
    }

    let tag: Model

    var body: some View {
        let chip = Text(verbatim: tag.text)
            .sipFont(11, weight: .medium)
            .foregroundColor(tag.warning ? .orange : SipDesign.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(tag.warning ? Color.orange.opacity(0.14) : SipDesign.chipBg))
            .lineLimit(1)
            .fixedSize()
        // No tooltip at all rather than an empty one: `.help("")` sets
        // an EMPTY tooltip, not none.
        if let help = tag.help {
            chip.help(help)
        } else {
            chip
        }
    }
}

