// AgentSessionsSection.swift
// Sidebar section listing Claude Code sessions discovered under
// ~/.claude/projects, plus scheduled-task definitions discovered under
// ~/.claude/scheduled-tasks and a "+ New session" action row at the top.
// Scheduled tasks expand inline to reveal their run sessions. Tapping a
// run or regular session routes the center column to AgentSessionView via
// AppState.openAgentSessionId.
//
// Grouping: the header carries a Group menu (folder / date / state / the
// user's own named groups — see AgentSessionGrouping). Groups render as
// small collapsible headers above otherwise-unchanged rows, so turning
// grouping on rearranges the list without restyling it. The chosen mode,
// the folded headers and the custom groups persist in this app's
// config.json, never in the agent's session files.
//
// "+ New session" routes the center column straight to a draft
// AgentSessionView — folder, permission mode, model, effort and
// scheduling all live in that view's composer, so there is no modal
// in between.

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct AgentSessionsSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var agents: AgentManager
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var mcpBridge: MCPBridge
    @EnvironmentObject var scheduler: ScheduledTaskScheduler
    @Environment(\.sipFontScale) private var fontScale

    /// Which agent this section lists. Every piece of section state —
    /// group mode, custom groups, collapsed headers, last cwd — is
    /// namespaced under this key, so two sections never share state.
    var agentKey: String = "claude_code"

    /// The agent's label, under whatever name the user gave it in
    /// Settings → Labels. A hardcoded literal would ignore renames —
    /// the section header, the not-installed hint and the read-only
    /// hint would all keep saying "Claude Code" / "Codex".
    private var agentName: String {
        let fallback = AgentManager.registry
            .first { $0.key == agentKey }?.name ?? "Claude Code"
        return config.agentLabel(for: agentKey, defaultName: fallback)
    }

    @Binding var expanded: Bool
    /// What the caps are currently NOT applied to, by `revealKey(_:_:)`:
    /// one entry per revealed group, plus `sectionRevealKey` for the
    /// modes whose button is section-level.
    ///
    /// Every key is MODE-SCOPED, and that is load-bearing in two ways. A
    /// folder path and a custom group name are both plain strings, so an
    /// unscoped key would let revealing `work` in Custom also uncap a
    /// folder called `work`. And an unscoped section-level reveal would
    /// uncap Date and None together — clicking it in one mode would
    /// lift the other's cap as well.
    @State private var revealedKeys: Set<String> = []
    @State private var expandedScheduledTasks: Set<String> = []

    /// The name prompt shared by "New group…" and "Rename group…".
    private enum GroupPrompt: Identifiable {
        /// Creating a group. The item, when present, is filed into it on
        /// save — that's the "Add to group ▸ New group…" path.
        case create(AgentListItem?)
        case rename(String)

        var id: String {
            switch self {
            case .create(let item): return "create:\(item?.id ?? "")"
            case .rename(let name): return "rename:\(name)"
            }
        }
    }

    @State private var groupPrompt: GroupPrompt? = nil
    @State private var groupNameDraft: String = ""
    @State private var deletingGroup: String? = nil

    /// Row being renamed inline (⋮ → Rename swaps its title for a text
    /// field in place — no dialog). One at a time, keyed by id.
    @State private var renamingSessionId: String? = nil
    @State private var sessionNameDraft: String = ""
    @State private var renamingTaskId: String? = nil
    @State private var taskNameDraft: String = ""
    @FocusState private var renameFieldFocused: Bool
    /// A rename that reached SipAI and not the agent. Carries the
    /// agent's label because this view is one section of several and
    /// the sentence has to name which CLI disagreed.
    struct RenameFailure: Identifiable {
        let id = UUID()
        let agent: String
        let reason: String
    }
    @State private var renameFailure: RenameFailure? = nil
    /// Session under the ⋮ Delete confirmation.
    @State private var deletingSession: AgentSession? = nil
    /// Scheduled task under the ⋮ Delete definition confirmation.
    @State private var deletingTask: ScheduledAgentTask? = nil
    /// Scheduled task under the ⋮ Delete all confirmation.
    @State private var deletingTaskAndRuns: ScheduledAgentTask? = nil

    /// Caps only regular sessions, at the sidebar's shared row limit, to
    /// keep the left column scannable. Whether it counts across the whole
    /// section or inside each group is `revealsPerGroup` — see
    /// `listLayout`. Scheduled task parents and all children of an
    /// expanded parent remain available independently of this limit.
    private static let defaultLimit = SidebarRowCap.limit

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// This section exists only for a LISTED agent (`AgentPresence`):
    /// installed, signed in, not hidden. `LeftSidebar` appends it on
    /// that rule, so the body has one shape — the new-session row and
    /// the list — and no read-only, not-signed-in or not-installed
    /// variant; those states live in Settings → Agent Guide.
    private var isReady: Bool {
        agents.isAgentReady(agentKey)
    }

    private var hasAnyRows: Bool {
        !sectionScheduledTasks.isEmpty || !sectionRegularSessions.isEmpty
    }

    private var sectionRegularSessions: [AgentSession] {
        agents.regularSessions(for: agentKey)
    }

    private var sectionScheduledTasks: [ScheduledAgentTask] {
        agents.scheduledTasks(for: agentKey)
    }

    private var sectionTitle: String { agentName }

    private var groupMode: AgentGroupMode {
        config.agentGroupMode(for: agentKey)
    }

    private var customGroups: [String] {
        config.agentCustomGroups(for: agentKey)
    }

    /// Some row in this section is running — what the section header
    /// draws its dot from while the section is collapsed. The same
    /// `isActive` every row and every folded group reads.
    private var sectionLive: Bool {
        sectionRegularSessions.contains { isActive(.regular($0)) }
            || sectionScheduledTasks.contains { isActive(.scheduled($0)) }
    }

    /// Some row in this section finished and has not been opened since —
    /// the collapsed header's steady dot, through the same `isUnread`
    /// every row and every folded group reads.
    private var sectionUnread: Bool {
        sectionRegularSessions.contains { isUnread(.regular($0)) }
            || sectionScheduledTasks.contains { isUnread(.scheduled($0)) }
    }

    var body: some View {
        DisclosureSection(
            title: sectionTitle,
            isExpanded: $expanded,
            live: sectionLive,
            unread: sectionUnread,
            accessory: { groupMenu }
        ) {
            newSessionButton
            sessionList
        }
        .alert(groupPromptTitle, isPresented: groupPromptPresented) {
            TextField(
                String(localized: "Group name",
                       comment: "Placeholder for the custom session group name field"),
                text: $groupNameDraft
            )
            Button {
                commitGroupPrompt()
            } label: {
                Text("Save", comment: "Confirm the group name dialog")
            }
            .keyboardShortcut(.defaultAction)
            Button(role: .cancel) {
                groupPrompt = nil
            } label: {
                Text("Cancel", comment: "Dismiss the group name dialog")
            }
        }
        .alert(
            String(localized: "Delete group?",
                   comment: "Title of the confirmation for deleting a custom session group"),
            isPresented: Binding(
                get: { deletingGroup != nil },
                set: { if !$0 { deletingGroup = nil } }
            ),
            presenting: deletingGroup
        ) { name in
            Button(role: .destructive) {
                config.deleteAgentCustomGroup(name, for: agentKey)
            } label: {
                Text("Delete", comment: "Confirm deleting a custom session group")
            }
            Button(role: .cancel) { } label: {
                Text("Cancel", comment: "Dismiss the delete-group confirmation")
            }
        } message: { name in
            // String(localized:) then the verbatim Text overload: the
            // LocalizedStringKey form markdown-parses, so a name with
            // _underscores_ or `backticks` rendered styled in the
            // dialog. Same localization key either way.
            Text(String(localized: "“\(name)” goes away. Its sessions are kept and move to Ungrouped.",
                        comment: "Explains that deleting a group never deletes sessions"))
        }
        .alert(
            String(localized: "Delete session from this computer?",
                   comment: "Title of the session delete confirmation"),
            isPresented: Binding(
                get: { deletingSession != nil },
                set: { if !$0 { deletingSession = nil } }
            ),
            presenting: deletingSession
        ) { session in
            Button(role: .destructive) {
                deleteSession(session)
            } label: {
                Text("Delete", comment: "Confirm deleting a session")
            }
            Button(role: .cancel) { } label: {
                Text("Cancel", comment: "Dismiss the session delete confirmation")
            }
        } message: { session in
            Text(String(localized: "“\(displayName(for: session, nested: false))” is removed for every app that reads it — SipAI, the CLI, and the desktop app. This cannot be undone.",
                        comment: "Body of the session delete confirmation"))
        }
        .alert(
            String(localized: "Delete this task's definition?",
                   comment: "Title of the confirmation for a scheduled task's Delete definition — its runs are kept"),
            isPresented: Binding(
                get: { deletingTask != nil },
                set: { if !$0 { deletingTask = nil } }
            ),
            presenting: deletingTask
        ) { task in
            Button(role: .destructive) {
                deleteTask(task)
            } label: {
                Text("Delete definition",
                     comment: "Confirm deleting a scheduled task's definition, keeping its runs")
            }
            Button(role: .cancel) { } label: {
                Text("Cancel", comment: "Dismiss the scheduled-task delete confirmation")
            }
        } message: { task in
            Text(String(localized: "“\(task.description)” stops running and its definition is removed. Past run sessions are kept.",
                        comment: "Body of the scheduled-task delete confirmation"))
        }
        // Delete all says what goes with the task, the way a session's
        // Delete does: the runs are sessions like any other, and every
        // app that reads them loses them.
        .alert(
            String(localized: "Delete this task and all its runs?",
                   comment: "Title of the confirmation for a scheduled task's Delete all — the definition and every run session it made"),
            isPresented: Binding(
                get: { deletingTaskAndRuns != nil },
                set: { if !$0 { deletingTaskAndRuns = nil } }
            ),
            presenting: deletingTaskAndRuns
        ) { task in
            Button(role: .destructive) {
                deleteTaskAndRuns(task)
            } label: {
                Text("Delete all",
                     comment: "Confirm deleting a scheduled task's definition and every run session it made")
            }
            Button(role: .cancel) { } label: {
                Text("Cancel", comment: "Dismiss the scheduled-task delete confirmation")
            }
        } message: { task in
            Text(deleteAllMessage(for: task))
        }
        .alert(
            String(localized: "Renamed in SipAI only",
                   comment: "Title of the alert shown when a rename could not be written into the agent's own store"),
            isPresented: Binding(
                get: { renameFailure != nil },
                set: { if !$0 { renameFailure = nil } }
            ),
            presenting: renameFailure
        ) { _ in
            Button(role: .cancel) { } label: {
                Text("OK", comment: "Dismiss the rename-failure alert")
            }
        } message: { failure in
            Text(String(localized: "The new name is saved here, but writing it into \(failure.agent) failed: \(failure.reason)",
                        comment: "Body of the rename-failure alert — agent label, then the underlying reason"))
        }
    }

    // MARK: - Group menu (section header accessory)

    private var groupMenu: some View {
        // Offered to every listed agent, sessions or not, so the
        // choice is already made when the first session lands.
        Menu {
            Picker(selection: groupModeBinding) {
                ForEach(AgentGroupMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                Text("Group by", comment: "Menu section — how to bucket the session list")
            }
            .pickerStyle(.inline)

            if groupMode == .custom {
                Divider()
                Button {
                    promptForGroup(.create(nil))
                } label: {
                    Text("New group…",
                         comment: "Menu item — create an empty custom session group")
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 10, weight: .semibold))
                // Tinted while a grouping is on, so the sidebar shows at
                // a glance that the list isn't in its default order.
                .foregroundStyle(groupMode == .none
                                 ? AnyShapeStyle(.secondary)
                                 : AnyShapeStyle(Color.accentColor))
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(groupMode == .none
              ? String(localized: "Group sessions",
                       comment: "Tooltip for the sidebar grouping menu when grouping is off")
              : String(localized: "Grouped by \(groupMode.label)",
                       comment: "Tooltip for the sidebar grouping menu naming the active mode"))
    }

    private var groupModeBinding: Binding<AgentGroupMode> {
        Binding(
            get: { config.agentGroupMode(for: agentKey) },
            set: { config.setAgentGroupMode($0, for: agentKey) }
        )
    }

    // MARK: - New session action row

    private var newSessionButton: some View {
        Button {
            startNewSession()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("New session",
                     comment: "Sidebar action row — start a new agent session")
                    .font(.system(size: SipFont.sidebarRow(fontScale), weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarRowBackground()
    }

    /// Every ready agent opens as an in-app draft — the composer drives
    /// the whole flow, and the runner picks the CLI off the draft's
    /// `agentKey`.
    private func startNewSession(cwd cwdURL: URL, inGroup group: String? = nil) {
        appState.pendingClaudeSessionDraft = ClaudeSessionDraft(
            cwd: cwdURL,
            name: nil,
            agentKey: agentKey,
            customGroup: group
        )
    }

    /// The "+ New session" row's starting folder, best evidence first:
    ///
    ///  1. the last folder a session was actually spawned in from this app
    ///  2. the folder of the most recent session on record
    ///  3. the home directory
    ///
    /// Step 2 exists to prevent a silent wrong-folder failure.
    /// `agentLastCwd` is only written by `handleSessionIdDiscovered` —
    /// i.e. after a live send completes and reveals a session id — so
    /// it stays UNSET for anyone who has driven their sessions from the
    /// terminal, or who uses this app to create scheduled tasks (which
    /// never spawn a draft). Without step 2 every new draft for such a
    /// user would open in `$HOME`, and a scheduled task created from it
    /// would inherit that cwd and file under the home folder group.
    ///
    /// The app always knows better than `$HOME`: the newest session on
    /// record names a folder the user demonstrably works in.
    private func startNewSession() {
        startNewSession(cwd: defaultNewSessionCwd())
    }

    /// The chain above, as a value — the group + falls back to it when
    /// the group it was clicked on has no folder of its own to offer.
    private func defaultNewSessionCwd() -> URL {
        func usable(_ path: String?) -> String? {
            guard let path = path, !path.isEmpty else { return nil }
            return Self.isOpenableDirectory(path) ? path : nil
        }
        let cwd = usable(config.agentLastCwd(for: agentKey))
            ?? usable(sectionRegularSessions.first?.projectPath?.path)
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: cwd, isDirectory: true)
    }

    /// Whether a path names a directory that can be opened right now.
    /// One spelling, because both + routes ask it and a group's folder
    /// is chosen by it.
    private static func isOpenableDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && isDir.boolValue
    }

    /// The folder-header +. In folder mode the group key IS the
    /// standardized directory path.
    ///
    /// When that path is NOT an openable directory, this asks instead of
    /// guessing. Falling back to `startNewSession()`'s default would
    /// silently start the session in some other folder, and a scheduled
    /// task created from that draft would inherit that cwd. The user
    /// asked for a specific folder; answering with a different one and
    /// no indication is the whole bug.
    ///
    /// This is reachable in normal use, not just for deleted folders: a
    /// session whose transcript carries no `cwd` record falls back to
    /// decoding its `~/.claude/projects` dirname, and that encoding is
    /// lossy ("-" may be "/", a space, or a "."), so it can yield a
    /// plausible path that was never real — one dirname encodes both
    /// `…/a/b-c` and `…/a/b/c`, and the decode can pick the one that
    /// never existed. Such a group renders, and its + points at
    /// nothing.
    private func startNewSession(inFolder path: String) {
        if Self.isOpenableDirectory(path) {
            startNewSession(cwd: URL(fileURLWithPath: path, isDirectory: true))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose",
                              comment: "Folder picker confirm button")
        panel.message = String(
            localized: "“\((path as NSString).abbreviatingWithTildeInPath)” can't be opened. Choose the folder for this session.",
            comment: "Folder picker message when a group's recorded path is not an openable directory")
        // Seeded at the closest ancestor that does exist, so the picker
        // opens near where the user meant rather than at the home folder.
        panel.directoryURL = Self.nearestExistingDirectory(path)
        // Cancel creates nothing. Starting somewhere arbitrary is what
        // this whole branch exists to prevent.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startNewSession(cwd: url)
    }

    /// The custom-group header's +. The group's own most recently used
    /// folder, else the folder any other new session would open in.
    ///
    /// Unlike the folder + this does NOT ask when it cannot resolve a
    /// folder, and the difference is what the user clicked. A folder
    /// header names one directory and nothing else, so answering with a
    /// different one silently is the whole of that button's failure
    /// mode. A group is not a place — its folder is a convenience read
    /// off its rows — so falling back costs nothing that isn't shown:
    /// the draft page prints the folder, the composer chip prints it
    /// again, and it stays editable until the first send.
    ///
    /// A brand-new group has no rows and therefore no folder, and that
    /// is the ordinary case, not an error.
    private func startNewSession(inGroup group: String) {
        let folder = AgentSessionGrouping.latestFolder(
            inGroup: group,
            sortedItems: sortedListItems,
            assignments: config.agentSessionGroupAssignments,
            usable: { Self.isOpenableDirectory($0.path) }
        )
        startNewSession(cwd: folder ?? defaultNewSessionCwd(), inGroup: group)
    }

    /// Closest existing ancestor directory of `path`, or home.
    private static func nearestExistingDirectory(_ path: String) -> URL {
        let fm = FileManager.default
        var url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        while url.path != "/" {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        return fm.homeDirectoryForCurrentUser
    }

    // MARK: - Sessions list

    /// One rendered group, plus what its OWN cap is holding back.
    private struct ListGroup: Identifiable {
        let group: AgentSessionGroup
        /// Regular rows beyond the cap — what this group's button offers,
        /// in EITHER direction, so it is counted whether or not they are
        /// currently shown. 0 draws no button, as does a mode whose
        /// button is section-level.
        let overflow: Int
        /// Whether `overflow` rows are on screen right now.
        let revealed: Bool
        /// Rows the group holds BEFORE the cap. This is what the header
        /// counts: a header reading "10" above a "Show all (24 more)"
        /// contradicts the button directly underneath it.
        let total: Int
        /// Some row in the group — ALL of them, taken before the cap —
        /// is running (`isActive`). A folded header draws the dot for
        /// it, since none of its rows are on screen to draw their own.
        let live: Bool
        /// Some row in the group finished and has not been opened since
        /// (`isUnread`), over the same untrimmed rows: the folded
        /// header's steady dot, drawn beside the pulse when `live` is
        /// true too.
        let unread: Bool

        var id: String { group.key }
    }

    /// What the list renders, plus what a SECTION-level cap is holding.
    private struct ListLayout {
        let groups: [ListGroup]
        /// Non-zero only in the modes that draw one trailing button
        /// (`.none`, `.date`); the grouped modes carry their counts on
        /// the groups themselves.
        let overflow: Int
        let revealed: Bool
    }

    /// Which modes cap PER GROUP and hide the remainder behind a button
    /// inside each one. Folder / State / Custom are places a session
    /// belongs to, and "the 10 newest here" is a question with an answer
    /// per place; Date and None read as one chronological stream, so
    /// there the cap counts across the whole section and one button at
    /// the end opens it. Both halves — where the cap counts and where its
    /// button lands — follow from this one answer, so they cannot drift.
    private static func revealsPerGroup(_ mode: AgentGroupMode) -> Bool {
        switch mode {
        case .none, .date: return false
        case .folder, .state, .custom: return true
        }
    }

    /// Stands in for a group key when the reveal belongs to the whole
    /// section. Cannot collide with a folder path or a user's group name
    /// — same device, and the same reason, as `ungroupedKey`.
    private static let sectionRevealKey = "\u{0}section"

    /// Namespace for `revealedKeys`, mirroring `groupDragPrefix`'s reason
    /// for existing: group keys are only unique WITHIN a mode.
    private func revealKey(_ mode: AgentGroupMode, _ groupKey: String) -> String {
        mode.rawValue + ":" + groupKey
    }

    private func toggleReveal(_ key: String) {
        if revealedKeys.contains(key) {
            revealedKeys.remove(key)
        } else {
            revealedKeys.insert(key)
        }
    }

    /// This section's rows as ONE stream: running first, then finished
    /// and unopened, then the rest (`tier`, `SidebarTier`), newest first
    /// inside each tier.
    ///
    /// Within a tier the order is `AgentListItem.activityDate` — the
    /// last user message for a session, the newest run's prompt for a
    /// task — which is also the value each row prints, so a tier cannot
    /// sort on one clock and show another.
    ///
    /// Read by `listLayout`, which buckets it, and by the custom
    /// group +, which asks it where that group was last worked in. One
    /// property so those two can never disagree about which row is on
    /// top.
    private var sortedListItems: [AgentListItem] {
        var items = sectionScheduledTasks.map(AgentListItem.scheduled)
        items.append(contentsOf: sectionRegularSessions.map(AgentListItem.regular))
        // Once per row: the comparator runs n log n times.
        var tiers: [String: SidebarTier] = [:]
        for item in items { tiers[item.id] = tier(item) }
        items.sort {
            let lhs = tiers[$0.id] ?? .rest
            let rhs = tiers[$1.id] ?? .rest
            if lhs != rhs { return lhs < rhs }
            if $0.sortDate != $1.sortDate {
                return $0.sortDate > $1.sortDate
            }
            return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
        return items
    }

    /// One chronological stream, then bucketed. Every row sorts on
    /// `AgentListItem.activityDate` — the last user message for a
    /// session, the latest run's prompt for a scheduled task — which is
    /// also the value its timestamp prints. Because the whole stream is
    /// sorted BEFORE bucketing and `buckets` preserves insertion order,
    /// a freshly-stamped row lands at the top of whichever group it
    /// belongs to, in every grouping mode.
    ///
    /// The cap is spent one of two ways, and `revealsPerGroup` decides
    /// which — the SAME split as where the reveal button lands, because
    /// they are the same question asked twice.
    ///
    /// * **None and Date** are one chronological stream, so the cap is
    ///   SECTION-WIDE: `defaultLimit` sessions in total, and the date
    ///   headers are drawn over whatever survived. Date is not a place a
    ///   session lives, it is a shelf the same one stream is cut into, so
    ///   10 per bucket would be 10 × however many buckets the machine
    ///   happens to have — not a cap the user asked for. One button at
    ///   the end opens the lot.
    /// * **Folder / State / Custom** are places, so each caps its OWN
    ///   rows at `defaultLimit` and carries its own button. One folder of
    ///   forty sessions must not consume the section's whole allowance
    ///   and make every other folder vanish rather than merely be
    ///   trimmed.
    ///
    /// So `ListLayout.overflow` is the section-level count and is 0
    /// whenever the groups carry their own, and vice versa.
    ///
    /// Overflow is counted whether or not it is currently revealed — the
    /// button is a toggle, and it has to be able to say "Show less" from
    /// a list that is showing everything.
    ///
    /// The section-wide budget is spent in BUCKET ORDER, and that is what
    /// makes it the newest N: `buckets` orders date groups by their most
    /// recent row and preserves the stream's order inside each, so
    /// walking them in order and taking greedily is the same set as
    /// `prefix(N)` over the flat list. A bucket the budget never reached
    /// draws no header at all — an empty date group is noise, which is
    /// why `buckets` drops empty groups too.
    ///
    /// A row with a dot — running, or finished and unopened — is never
    /// behind the button, and does not spend the cap: the cap is for
    /// rows with nothing new to show. The tiers already put dotted rows
    /// first in every group; the exemption is what covers Date's
    /// section-wide budget, spent bucket by bucket, where an unread row
    /// in an older bucket would otherwise fall past the tenth row.
    ///
    /// `folded` is the set of group keys the user has collapsed, and in
    /// the PER-GROUP modes a folded group is NOT trimmed. Its rows are
    /// already hidden — by the user's own choice, and completely — so
    /// counting the cap's drops there makes "Show all (5 more)" promise
    /// rows that clicking it cannot reveal: the reveal puts them back
    /// inside a group that renders nothing, so the button vanishes and
    /// the list looks identical. The section-wide modes need no such
    /// rule — their count is read off the raw session list, not summed
    /// from per-group drops, so folding cannot corrupt it.
    private func listLayout(folded: Set<String>) -> ListLayout {
        let mode = groupMode
        let perGroup = Self.revealsPerGroup(mode)
        let sectionRevealed = revealedKeys.contains(
            revealKey(mode, Self.sectionRevealKey))
        let items = sortedListItems
        // A dotted row is never capped — see above. Read once per row.
        var dotted: Set<String> = []
        for item in items where tier(item) < .rest { dotted.insert(item.id) }

        // Read off the raw list, so it stands whatever is revealed or
        // folded. Only regular sessions without a dot are ever capped
        // (below).
        let sectionOverflow = perGroup
            ? 0
            : max(0, sectionRegularSessions
                .filter { !dotted.contains(AgentListItem.regular($0).id) }
                .count - Self.defaultLimit)
        let sectionCapped = !perGroup && !sectionRevealed
        var budget = Self.defaultLimit

        var groups: [ListGroup] = []
        for group in AgentSessionGrouping.buckets(
            items,
            mode: mode,
            state: groupState(for:),
            tier: tier(_:),
            customGroups: customGroups,
            assignments: config.agentSessionGroupAssignments
        ) {
            let total = group.items.count
            let live = group.items.contains(where: isActive)
            let unread = group.items.contains(where: isUnread)
            // Cap only REGULAR sessions, in both branches. Scheduled
            // task parents must survive the trim (the documented
            // invariant at `defaultLimit`): a never-run task sorts
            // to the group's bottom via .distantPast, so a plain
            // prefix() hid exactly the rows that look deleted when
            // missing.
            if perGroup {
                guard !folded.contains(group.key) else {
                    groups.append(ListGroup(group: group, overflow: 0,
                                            revealed: false, total: total,
                                            live: live, unread: unread))
                    continue
                }
                var kept: [AgentListItem] = []
                var regularKept = 0
                var overflow = 0
                for item in group.items {
                    switch item {
                    case .scheduled:
                        kept.append(item)
                    case .regular where dotted.contains(item.id):
                        kept.append(item)
                    case .regular:
                        if regularKept < Self.defaultLimit {
                            kept.append(item)
                            regularKept += 1
                        } else {
                            overflow += 1
                        }
                    }
                }
                let revealed = revealedKeys.contains(revealKey(mode, group.key))
                groups.append(ListGroup(
                    group: (revealed || overflow == 0) ? group : AgentSessionGroup(
                        key: group.key,
                        label: group.label,
                        detail: group.detail,
                        tooltip: group.tooltip,
                        items: kept,
                        newestActivity: group.newestActivity,
                        tier: group.tier
                    ),
                    overflow: overflow,
                    revealed: revealed,
                    total: total,
                    live: live,
                    unread: unread
                ))
            } else if sectionCapped {
                var kept: [AgentListItem] = []
                for item in group.items {
                    switch item {
                    case .scheduled:
                        kept.append(item)
                    case .regular where dotted.contains(item.id):
                        kept.append(item)
                    case .regular:
                        if budget > 0 {
                            kept.append(item)
                            budget -= 1
                        }
                    }
                }
                guard !kept.isEmpty else { continue }
                groups.append(ListGroup(
                    group: kept.count == total ? group : AgentSessionGroup(
                        key: group.key,
                        label: group.label,
                        detail: group.detail,
                        tooltip: group.tooltip,
                        items: kept,
                        newestActivity: group.newestActivity,
                        tier: group.tier
                    ),
                    overflow: 0,
                    revealed: false,
                    total: total,
                    live: live,
                    unread: unread
                ))
            } else {
                groups.append(ListGroup(group: group, overflow: 0,
                                        revealed: sectionRevealed, total: total,
                                        live: live, unread: unread))
            }
        }
        return ListLayout(groups: groups,
                          overflow: sectionOverflow,
                          revealed: sectionRevealed)
    }

    @ViewBuilder
    private var sessionList: some View {
        // A named group renders while empty, so under Custom the list
        // has something to draw even before the first session exists —
        // otherwise "New group…" on a fresh agent produces a group the
        // empty-state row hides, which is the bug the header + is here
        // to end. `hasAnyRows` itself is left alone: a row means
        // something to READ, and a group the user named is not that.
        //
        // The scan still wins while it runs. `sessions` is empty until
        // the FIRST scan lands, so without that clause a user grouped
        // by Custom watches every group sit at 0 for the length of the
        // launch scan instead of reading "Scanning…". Later rescans
        // keep the old list, so this only ever costs a machine with no
        // sessions at all a brief "Scanning…" on activation.
        let namedGroupsToDraw = groupMode == .custom && !customGroups.isEmpty
        if !hasAnyRows && (agents.isScanning || !namedGroupsToDraw) {
            emptyRow
        } else {
            let mode = groupMode
            // Folded state is an INPUT to the layout, not just a render
            // decision: the per-group cap must not trim rows out of a
            // group that draws none of them.
            let folded = config.agentCollapsedGroups(for: agentKey, mode: mode)
            let layout = listLayout(folded: folded)
            // User-dragged order over the bucketer's own (per mode, per
            // agent), with any group a turn has started in since that
            // drag lifted to the top — see `AgentSessionGrouping
            // .arranged`. Each group renders as ONE block — header plus
            // its rows — so the whole block is a drop target and dragging
            // a header across a tall unfolded group still reorders live.
            // The sub-VStack matches the parent's 2-pt spacing, so the
            // wrapping is invisible.
            let orderedGroups = AgentSessionGrouping.arranged(
                layout.groups,
                mode: mode,
                dragged: config.agentGroupOrder(for: agentKey, mode: mode),
                draggedAt: config.agentGroupOrderDate(for: agentKey, mode: mode),
                id: \.id,
                newest: \.group.newestActivity,
                tier: \.group.tier)
            ForEach(orderedGroups) { entry in
                let group = entry.group
                VStack(alignment: .leading, spacing: 2) {
                    if mode != .none {
                        groupHeaderRow(group,
                                       count: entry.total,
                                       folded: folded.contains(group.key),
                                       live: entry.live,
                                       unread: entry.unread,
                                       mode: mode)
                            // The header is the drag handle; session and
                            // task rows keep their click behaviour.
                            .onDrag {
                                let payload = groupDragPrefix(mode) + group.key
                                #if DEBUG
                                SidebarDropDiagnostics.dumpDestinations(reason: "drag start " + payload)
                                #endif
                                return NSItemProvider(object: payload as NSString)
                            }
                    }
                    if mode == .none || !folded.contains(group.key) {
                        ForEach(group.items) { item in
                            switch item {
                            case .scheduled(let task):
                                scheduledTaskRow(task)
                            case .regular(let session):
                                sessionRow(session)
                            }
                        }
                        // Inside the group block, under its last row, so
                        // it reads as belonging to this group and not to
                        // whatever group renders next.
                        if entry.overflow > 0 {
                            SidebarShowMoreRow(overflow: entry.overflow,
                                               revealed: entry.revealed,
                                               indent: 28) {
                                toggleReveal(revealKey(mode, group.key))
                            }
                        }
                    }
                }
                .onDrop(of: [.plainText],
                        delegate: SidebarReorderDropDelegate(
                            itemId: group.key,
                            payloadPrefix: groupDragPrefix(mode),
                            order: groupOrderBinding(
                                displayed: orderedGroups.map(\.id),
                                mode: mode)))
            }

            // Only `.none` and `.date` ever reach this — everything else
            // spent its count inside the groups above.
            if layout.overflow > 0 {
                SidebarShowMoreRow(overflow: layout.overflow,
                                   revealed: layout.revealed) {
                    toggleReveal(revealKey(mode, Self.sectionRevealKey))
                }
            }
        }
    }

    // MARK: - Group reordering

    /// Payload namespace for group drags — scoped per agent AND mode,
    /// so a drag in the codex section (or in Folder mode) can never
    /// reorder this section's Custom groups.
    private func groupDragPrefix(_ mode: AgentGroupMode) -> String {
        "agentgroup:" + agentKey + "/" + mode.rawValue + ":"
    }

    private func groupOrderBinding(displayed: [String],
                                   mode: AgentGroupMode) -> Binding<[String]> {
        Binding(
            get: { displayed },
            set: { config.setAgentGroupOrder($0, for: agentKey, mode: mode) }
        )
    }

    // MARK: - Group header rows

    /// Same size as a session row title (dimmer + semibold to still read
    /// as a header), and at the same indent: the rows underneath keep the
    /// exact look they have when grouping is off, so switching modes
    /// rearranges without restyling.
    ///
    /// A ready agent's folder and custom-group headers carry a trailing
    /// + — sharing the 18-pt column the session rows' ⋮ sits in — that
    /// starts a new session already belonging to that group; the count
    /// sits directly left of it. The + is OUTSIDE the fold button
    /// (nested SwiftUI buttons both fire), so everything on the row
    /// except the + itself folds the group.
    ///
    /// Both are places a session can be PUT: a folder is where it runs,
    /// a custom group is where the user filed it. Ungrouped is neither
    /// — it is the absence of a filing, and the section's own
    /// "+ New session" row already makes an unfiled session — so it
    /// carries none, and neither do the buckets that merely describe
    /// rows (date, state, "No directory").
    ///
    /// `count` is the group's size BEFORE the cap, never `group.items
    /// .count`: a trimmed group renders fewer rows than it holds, and a
    /// header saying "10" directly above "Show all (24 more)" contradicts
    /// the button it is sitting on top of.
    ///
    /// `live` says a row inside is running. While the group is FOLDED
    /// the header draws the activity dot after its name (see
    /// `AgentGroupHeaderLabel`); unfolded, the running row's own glyph
    /// already says it, so the header draws nothing. `unread` is the
    /// same for a row whose run finished and is unopened — the steady
    /// dot, right after the pulse when a row is running as well.
    @ViewBuilder
    private func groupHeaderRow(_ group: AgentSessionGroup,
                                count: Int,
                                folded: Bool,
                                live: Bool,
                                unread: Bool,
                                mode: AgentGroupMode) -> some View {
        let showsPlus = isReady && {
            switch mode {
            case .folder:
                return group.key != AgentSessionGrouping.noDirectoryKey
            case .custom:
                // Named groups only. `customGroups` is also what tells
                // Ungrouped apart from a group a user happens to have
                // called "Ungrouped", and it is the same test the
                // header's Rename / Delete menu already makes.
                return customGroups.contains(group.key)
            case .none, .date, .state:
                return false
            }
        }()
        let header = HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    config.setAgentGroupCollapsed(!folded,
                                                  group: group.key,
                                                  for: agentKey,
                                                  mode: mode)
                }
            } label: {
                AgentGroupHeaderLabel(label: group.label,
                                      detail: group.detail,
                                      count: count,
                                      folded: folded,
                                      live: live,
                                      unread: unread,
                                      titleSize: SipFont.sidebarRow(fontScale))
                    .padding(.leading, 8)
                    .padding(.trailing, showsPlus ? 2 : 8)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.label)
            // The label above replaces the dots' own, so a folded group
            // says what they say as its value instead: a running row, an
            // unopened finished one, or both.
            .accessibilityValue(folded
                ? GroupActivityDots.accessibilityText(live: live, unread: unread)
                : "")
            .accessibilityHint(folded
                ? String(localized: "Expand group",
                         comment: "Accessibility hint for a folded session group")
                : String(localized: "Collapse group",
                         comment: "Accessibility hint for an expanded session group"))

            if showsPlus {
                RowPlusButton(
                    label: String(localized: "New session in \(group.label)",
                                  comment: "Tooltip and accessibility label for the + on a folder or custom group header"),
                    action: {
                        // In folder mode the group key IS the directory
                        // path; in custom mode it is the group's name.
                        if mode == .custom {
                            startNewSession(inGroup: group.key)
                        } else {
                            startNewSession(inFolder: group.key)
                        }
                    }
                )
                .padding(.trailing, 4)
            }
        }
        .sidebarRowBackground()
        // Folder headers carry the full path here; other modes fall back to
        // the label so a truncated header can still be read on hover, and
        // so no header ever shows an empty tooltip. The + supplies its own
        // help locally, which wins over this one inside its bounds.
        .help(group.tooltip.isEmpty ? group.label : group.tooltip)

        if mode == .custom && customGroups.contains(group.key) {
            header.contextMenu {
                Button {
                    promptForGroup(.rename(group.key))
                } label: {
                    Text("Rename group…",
                         comment: "Context menu item on a custom group header")
                }
                Button(role: .destructive) {
                    deletingGroup = group.key
                } label: {
                    Text("Delete group",
                         comment: "Context menu item on a custom group header")
                }
            }
        } else {
            header
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyRow: some View {
        HStack {
            if agents.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning…",
                     comment: "Claude Code sessions: loading state")
                    .font(.system(size: SipFont.sidebarHint(fontScale)))
                    .foregroundStyle(.secondary)
            } else {
                Text("No sessions yet.",
                     comment: "Claude Code sessions: empty placeholder when no sessions exist")
                    .font(.system(size: SipFont.sidebarHint(fontScale)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Scheduled task rows

    /// Where a run under its task starts: its glyph begins where the
    /// task's own glyph slot ends — the row's 8 pt pad plus the 14 pt
    /// slot. One glyph's indent, because the task row carries ONE glyph
    /// (`ScheduledTaskGlyph` is its icon and shows whether it is open).
    private static let nestedRunLeading: CGFloat = 8 + 14

    private func scheduledTaskRow(_ task: ScheduledAgentTask) -> some View {
        let isExpanded = expandedScheduledTasks.contains(task.id)
        let hasActivity = isActive(.scheduled(task))
        let hasUnread = isUnread(.scheduled(task))
        let hasApproval = task.sessions.contains { isAwaitingApproval($0.id) }

        return VStack(alignment: .leading, spacing: 0) {
            if renamingTaskId == task.id {
                inlineRenameRow(
                    text: $taskNameDraft,
                    leadingPad: 8,
                    onCommit: { commitTaskRename(task) },
                    onCancel: cancelInlineRename
                ) {
                    ScheduledTaskGlyph(expanded: isExpanded)
                }
            } else {
            HStack(spacing: 0) {
                // The whole row is ONE button, and it folds: a click on a
                // folded task shows its runs and opens its page, a click
                // on an open one hides them and leaves the centre pane
                // alone (`toggleTask`). It never opens a run — a run is
                // opened from its own row. The glyph's bars turn with it.
                Button {
                    toggleTask(task)
                } label: {
                    HStack(spacing: 6) {
                        ScheduledTaskGlyph(expanded: isExpanded)
                        Text(task.description)
                            .font(.system(size: SipFont.sidebarRow(fontScale)))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        // What the task's runs are doing, right after its
                        // name as on a folded group — the pulse, the
                        // steady dot, or both — whether the task is folded
                        // or open: the row speaks for its runs in both.
                        // Before the status tag: an orange pulse after
                        // "Active" reads as a light on the tag, which
                        // describes the schedule, not the runs.
                        if hasActivity || hasUnread {
                            GroupActivityDots(live: hasActivity, unread: hasUnread)
                        }
                        if let status = scheduleStatusLabel(task) {
                            Text(verbatim: status)
                                .font(.system(size: SipFont.sidebarHint(fontScale),
                                              weight: .medium))
                                .foregroundColor(.orange)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        if hasApproval {
                            ApprovalBadge()
                        }
                        Spacer(minLength: 4)
                        // Same rule as a session row, and the same
                        // reason: while this task is mid-run the column
                        // would be printing when it last ran, next to a
                        // dot saying it is running now. "Never" goes
                        // with it — a task firing its first run has not
                        // never run.
                        //
                        // The column is the last RUN, while the row sorts
                        // on `lastActive`, which also counts the moment
                        // the task was scheduled. The two differ only for
                        // a task that has never run, and "Never" is not a
                        // time that can read as out of order.
                        if !hasActivity {
                            if let lastRun = task.lastRunAt {
                                Text(Self.relativeFormatter.localizedString(
                                    for: lastRun, relativeTo: Date()))
                                    .font(.system(size: SipFont.sidebarHint(fontScale)))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("Never",
                                     comment: "Scheduled task has never run")
                                    .font(.system(size: SipFont.sidebarHint(fontScale)))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 2)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task.description)
                // The label above replaces what the row draws after the
                // name, so its state and its runs' dots are said as the
                // value, as a folded group's header says its dots.
                .accessibilityValue([scheduleStatusLabel(task),
                                     GroupActivityDots.accessibilityText(live: hasActivity,
                                                                         unread: hasUnread)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
                .accessibilityHint(isExpanded
                    ? String(localized: "Collapse scheduled runs",
                             comment: "Accessibility hint for a scheduled task's row while its runs are showing")
                    : String(localized: "Expand scheduled runs and open the task's page",
                             comment: "Accessibility hint for a scheduled task's row while its runs are folded away — the click also opens the task's page"))
                RowEllipsisMenu { taskMenuItems(for: task) }
                    .padding(.trailing, 4)
            }
            .sidebarRowBackground(selected: appState.openScheduledTaskName == task.name
                                  && appState.openAgentSessionId == nil)
            .contextMenu { taskMenuItems(for: task) }
            }

            if isExpanded {
                if task.sessions.isEmpty {
                    HStack {
                        Text("No runs yet.",
                             comment: "Sidebar placeholder under a scheduled task with no runs")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.leading, Self.nestedRunLeading)
                    .padding(.trailing, 8)
                    .padding(.vertical, 4)
                } else {
                    ForEach(task.sessions) { session in
                        sessionRow(session, nested: true, taskName: task.name)
                    }
                }
            }
        }
    }

    /// Whether this task will fire, in one word beside its name.
    ///
    /// "Active" is claimed ONLY when something can actually fire it — a
    /// task that is enabled but carries no schedule never runs on its
    /// own, and labelling that "Active" would be the one lie this row
    /// can tell. A one-time task whose moment has passed will never fire
    /// again either, so it says how that moment went instead, read off
    /// the same run record the scheduler writes. Nil for an orphan,
    /// whose definition is gone.
    private func scheduleStatusLabel(_ task: ScheduledAgentTask) -> String? {
        guard let def = task.definition else { return nil }
        if !def.enabled {
            return String(localized: "Paused",
                          comment: "Sidebar tag on a scheduled task that will not fire")
        }
        guard let schedule = def.schedule else {
            return String(localized: "No schedule",
                          comment: "Sidebar tag on a scheduled task with no cron expression")
        }
        if case .once(let moment) = schedule {
            switch ScheduledTaskScheduler.oneTimeStatus(
                at: moment, state: scheduler.states[task.name], now: Date()) {
            case .ran:
                return String(localized: "Finished",
                              comment: "Sidebar tag on a one-time scheduled task that has had its run")
            case .missed:
                return String(localized: "Missed",
                              comment: "Sidebar tag on a one-time scheduled task whose moment passed while SipAI was closed, too long ago to catch up")
            case .upcoming, .due:
                break
            }
        }
        return String(localized: "Active",
                      comment: "Sidebar tag on a scheduled task that will fire")
    }

    // MARK: - Session rows

    /// `taskName` is set for a run nested under a scheduled task. It
    /// keeps the task's key-information panel up while the user clicks
    /// between that task's runs — and, being nil for every other row,
    /// is also what takes the panel DOWN when they click away.
    @ViewBuilder
    private func sessionRow(_ session: AgentSession,
                            nested: Bool = false,
                            taskName: String? = nil) -> some View {
        if renamingSessionId == session.id {
            inlineRenameRow(
                icon: sessionIcon(for: session),
                text: $sessionNameDraft,
                leadingPad: nested ? Self.nestedRunLeading : 8,
                onCommit: { commitSessionRename(session) },
                onCancel: cancelInlineRename
            )
        } else {
            let selected = appState.openAgentSessionId == session.id
            let active = isActive(.regular(session))
            let unread = isUnread(.regular(session))
            HStack(spacing: 0) {
                Button {
                    appState.openAgentSessionId = session.id
                    appState.openAgentSessionPath = session.fileURL
                    // Assigned AFTER the session, whose didSet does not
                    // touch this field — the order only matters for
                    // readability, not correctness.
                    appState.openScheduledTaskName = taskName
                } label: {
                    HStack(spacing: 6) {
                        leadingGlyph(icon: sessionIcon(for: session),
                                     size: 10,
                                     active: active,
                                     unread: unread)
                        Text(displayName(for: session, nested: nested))
                            .font(.system(size: SipFont.sidebarRow(fontScale)))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if isAwaitingApproval(session.id) {
                            ApprovalBadge()
                        }
                        Spacer(minLength: 4)
                        // Nothing while the turn is in flight — ours or
                        // another terminal's. This column answers "when
                        // did I last talk to this?", and mid-turn the
                        // honest answer is the one the leading dot is
                        // already giving; a relative time beside a
                        // pulsing dot reads as the turn's own clock,
                        // which lives in the composer and not here. It
                        // returns when the turn ends. Same rule in the
                        // chat list, for the same reason.
                        if !active {
                            // The same value the row is SORTED by
                            // (`AgentListItem.activityDate`) — printing
                            // mtime here while ordering on something else
                            // is how a list ends up looking unsorted.
                            Text(Self.relativeFormatter.localizedString(
                                for: session.activityAt, relativeTo: Date()))
                                .font(.system(size: SipFont.sidebarHint(fontScale)))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.leading, nested ? Self.nestedRunLeading : 8)
                    .padding(.trailing, 2)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Says in words what the two-person glyph says in a
                // picture. The row is deliberately still a row — see
                // `originHint`.
                .help(ifPresent: originHint(for: session))
                // The ⋮ sits outside the open-button so its click never
                // also opens the session (nested SwiftUI buttons both fire).
                RowEllipsisMenu {
                    sessionMenuItems(for: session, nested: nested)
                }
                .padding(.trailing, 4)
            }
            .sidebarRowBackground(selected: selected)
            // Same actions on right-click, so both idioms work.
            .contextMenu { sessionMenuItems(for: session, nested: nested) }
        }
    }

    // MARK: - Inline rename row

    /// The row's title swapped for a text field in place — no dialog.
    /// Only Enter saves; Escape OR clicking anywhere else abandons the
    /// edit and the original name stays.
    private func inlineRenameRow(icon: String,
                                 text: Binding<String>,
                                 leadingPad: CGFloat,
                                 onCommit: @escaping () -> Void,
                                 onCancel: @escaping () -> Void) -> some View {
        inlineRenameRow(text: text, leadingPad: leadingPad,
                        onCommit: onCommit, onCancel: onCancel) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    /// The same, with a glyph of the caller's own — a task keeps its
    /// fold bars while its name is being edited, rather than dropping
    /// to a bare clock for the length of the edit.
    private func inlineRenameRow<Leading: View>(
        text: Binding<String>,
        leadingPad: CGFloat,
        onCommit: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        HStack(spacing: 6) {
            leading()
                .frame(width: 14)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: SipFont.sidebarRow(fontScale)))
                .focused($renameFieldFocused)
                .onSubmit(onCommit)
                .onExitCommand(perform: onCancel)
                .onChange(of: renameFieldFocused) { _, focused in
                    // Click-away = regret. The Enter path clears the
                    // renaming id before focus drops, so this cancel is
                    // a no-op after a real commit.
                    if focused {
                        FocusedFieldSelection.selectAll()
                    } else {
                        onCancel()
                    }
                }
                .onAppear { renameFieldFocused = true }
        }
        .padding(.leading, leadingPad)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.18))
        )
        // Most clicks never move key focus on macOS, so the focus-loss
        // cancel above only fires for clicks into other FIELDS — this
        // catches the rest (rows, buttons, empty space).
        .editFieldClickAway(onCancel)
    }

    private func cancelInlineRename() {
        renamingSessionId = nil
        renamingTaskId = nil
    }

    /// Row glyph by origin: timer for anything a schedule fired,
    /// two-person for spawned subagents, speech bubble for
    /// conversations the user drove.
    private func sessionIcon(for session: AgentSession) -> String {
        switch session.origin {
        case .scheduled: return "timer"
        case .subagent: return "person.2"
        case .user:
            // A session this app branched out of another one. Worth its
            // own glyph rather than a name decoration: a branch starts
            // life holding a copy of its parent's history, so the two
            // rows can otherwise look like the same conversation listed
            // twice. Same instinct as labelling subagent and scheduled
            // rows instead of hiding them.
            if config.agentSessionBranchSource(for: session.id) != nil {
                return "arrow.triangle.branch"
            }
            return "bubble.left.and.text.bubble.right"
        }
    }

    /// What a row's glyph means, in words, for anyone who hovers it.
    ///
    /// Only the surprising origins get one. A subagent row is a session
    /// NOBODY started by hand — codex spawns it as a child thread of
    /// another session — and it lands in the flat list next to its
    /// siblings, all of which replay the same parent prompt. The
    /// two-person glyph already marks it; this is the same statement in
    /// words, because a glyph is only legible to someone who has already
    /// been told what it means.
    ///
    /// A hint, deliberately, and not a name decoration or a hidden row:
    /// the rule for a surprising session is to LABEL it, never to hide
    /// it, and never to spend row width on something most rows don't
    /// have.
    private func originHint(for session: AgentSession) -> String? {
        guard session.origin == .subagent else { return nil }
        return String(localized: "Subagent session",
                      comment: "Tooltip on a sidebar row for a session another session spawned")
    }

    /// The row's leading glyph. While the session is streaming, the
    /// pulsing dot REPLACES the origin icon rather than trailing the
    /// title; when the run finishes, the steady dot takes its place
    /// until the session is opened (`unread`), and then the icon comes
    /// back. All three states share one fixed frame so the title never
    /// shifts when they swap.
    ///
    /// The frame is fixed in BOTH axes and the swap is explicitly
    /// unanimated. The glyphs have very different intrinsic sizes — the
    /// activity dot is 6 pt, `bubble.left.and.text.bubble.right` is
    /// wider than the frame itself — and a width-only frame centres
    /// them, which lands the drawn glyph on a fractional pixel that can
    /// round differently from one render pass to the next. Opening a
    /// session publishes a new runner, so clicking quickly between
    /// sessions re-renders every row in rapid succession, and that
    /// rounding would read as the icon jittering sideways while the
    /// title (pinned to the frame, not the glyph) stays put.
    @ViewBuilder
    private func leadingGlyph(icon: String, size: CGFloat,
                              active: Bool, unread: Bool) -> some View {
        Group {
            if active {
                ActivityDot()
            } else if unread {
                UnreadDot()
            } else {
                Image(systemName: icon)
                    .font(.system(size: size))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 14, height: 14)
        // No enclosing transaction may animate one glyph into the
        // other: this is a state swap, not a movement.
        .animation(nil, value: active)
        .animation(nil, value: unread)
    }

    /// Rename / Add to group / Copy session ID / Delete — the ⋮ and
    /// right-click menu.
    @ViewBuilder
    private func sessionMenuItems(for session: AgentSession,
                                  nested: Bool) -> some View {
        Button {
            sessionNameDraft = displayName(for: session, nested: nested)
            renamingTaskId = nil
            renamingSessionId = session.id
        } label: {
            Text("Rename", comment: "Session row menu item — edits in place")
        }
        groupSubmenu(for: .regular(session))
        // The agent's OWN id for this session — what `claude --resume`,
        // `codex resume` and `kimi --session` take — as plain text. The
        // agent composer draws it on a grey token wherever it is pasted.
        Button {
            SessionIdTokens.copy(session.id)
        } label: {
            Text("Copy session ID",
                 comment: "Session row menu item — copies the agent's own id for this session")
        }
        Divider()
        Button(role: .destructive) {
            deletingSession = session
        } label: {
            Text("Delete", comment: "Session row menu item")
        }
    }

    /// "Add to group" submenu — the assignment half of custom grouping.
    /// Its "New group…" goes through `commitGroupPrompt`'s
    /// create-and-file path (see GroupPrompt.create's comment): a group
    /// created from a row without filing the row into it would be an
    /// invisible empty group, and the row would stay Ungrouped.
    ///
    /// Offered ONLY while the list is grouped by Custom. Under the
    /// automatic modes the filing would have no visible effect where
    /// the user is standing, and an auto-switch to Custom would mean
    /// one menu item silently changing how the whole section is
    /// grouped — filing starts at the section header's Custom mode
    /// instead. Routing: this menu's per-group rows are
    /// `assignToGroup`'s only caller, and the section header's own
    /// "New group…" lands in `commitGroupPrompt` with no row to file;
    /// both filing paths still flip the mode to Custom when it isn't,
    /// so an assignment can never appear to do nothing.
    @ViewBuilder
    private func groupSubmenu(for item: AgentListItem) -> some View {
        if groupMode == .custom {
            Menu {
                let current = config.agentSessionGroup(for: item.groupItemKey)
                ForEach(customGroups, id: \.self) { group in
                    Button {
                        assignToGroup(item, group: group)
                    } label: {
                        if group == current {
                            Label(group, systemImage: "checkmark")
                        } else {
                            Text(group)
                        }
                    }
                }
                if !customGroups.isEmpty { Divider() }
                Button {
                    promptForGroup(.create(item))
                } label: {
                    Text("New group…",
                         comment: "Group submenu item — create a group and file this row into it")
                }
                if current != nil {
                    Divider()
                    Button {
                        config.setAgentSessionGroup(nil, for: item.groupItemKey)
                    } label: {
                        Text("Remove from group",
                             comment: "Group submenu item — un-file this row")
                    }
                }
            } label: {
                Text("Add to group",
                     comment: "Session/task row submenu for custom grouping")
            }
        }
    }

    private func assignToGroup(_ item: AgentListItem, group: String) {
        config.setAgentSessionGroup(group, for: item.groupItemKey)
        // Filing is only visible under Custom — switch over so the
        // action doesn't appear to do nothing (mirrors commitGroupPrompt).
        if config.agentGroupMode(for: agentKey) != .custom {
            withAnimation(.easeInOut(duration: 0.18)) {
                config.setAgentGroupMode(.custom, for: agentKey)
            }
        }
    }

    /// A rename is written TWICE: into `agent_session_names`, which is
    /// what the sidebar draws and what the CLI reads, and — for an agent
    /// that has a custom-title mechanism — into the agent's own store,
    /// so its session picker agrees.
    ///
    /// The config write stays first and stays synchronous. It is what
    /// makes the row change under the cursor; the agent-side write is
    /// disk work on another actor and a rename must not wait on it.
    /// An agent that cannot be written to (`writesThrough` false) keeps
    /// the old behaviour exactly — the name is SipAI's and stays here.
    private func commitSessionRename(_ session: AgentSession) {
        guard renamingSessionId == session.id else { return }
        renamingSessionId = nil
        let typed = sessionNameDraft.trimmingCharacters(in: .whitespaces)
        // Empty (or reverting to the scanner's own title) clears the
        // custom label instead of freezing the automatic name.
        let name: String? =
            (typed.isEmpty || typed == session.title) ? nil : typed
        config.setAgentSessionDisplayName(name, for: session.id)

        guard AgentSessionRename.writesThrough(session.agentKey) else { return }
        let id = session.id
        let fileURL = session.fileURL
        let agentKey = session.agentKey
        let label = agentName
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try AgentSessionRename.apply(name, sessionId: id,
                                                 fileURL: fileURL,
                                                 agentKey: agentKey)
                }.value
            } catch AgentSessionRename.Failure.storeMissing {
                // Nothing on disk to write into — a session whose
                // transcript has not landed yet. SipAI's own name is
                // the whole outcome, which is not a failure to report.
            } catch {
                // The store is there and the write did not happen. Say
                // so: the row already shows the new name, and staying
                // quiet would leave the two sides disagreeing with
                // nothing on screen admitting it. Same rule as
                // `NotesManager.lastSaveFailure`.
                let reason = (error as? AgentSessionRename.Failure)?.message
                    ?? error.localizedDescription
                renameFailure = RenameFailure(agent: label, reason: reason)
            }
        }
    }

    private func deleteSession(_ session: AgentSession) {
        deletingSession = nil
        if appState.openAgentSessionId == session.id {
            appState.openAgentSessionId = nil
            appState.openAgentSessionPath = nil
        }
        agents.deleteSession(session)
    }

    /// Scheduled markers often occupy the entire first user record, leaving
    /// the scanner's title at its neutral fallback. Use a readable child label
    /// in that case while preserving custom names and real extracted titles.
    /// (`title == id` is the codex scanner's fallback shape; Claude marks its
    /// neutral fallbacks with `titleIsFallback` instead.)
    private func displayName(for session: AgentSession, nested: Bool) -> String {
        if let customName = config.agentSessionDisplayName(for: session.id) {
            return customName
        }
        if nested && (session.title == session.id || session.titleIsFallback) {
            return String(localized: "Scheduled run",
                          comment: "Fallback sidebar title for a scheduled run")
        }
        return session.title
    }

    // MARK: - Scheduled task actions (⋮ / right-click)

    /// A click on a task's row. On a FOLDED task it shows the runs and
    /// opens the task's page — its settings, the page a task has before
    /// its first run — whether or not it has run since. On an UNFOLDED
    /// task it hides the runs and does nothing else: the centre pane
    /// stays where it is, so a click meant to fold a task away never
    /// takes the pane somewhere else.
    ///
    /// It never opens a run — a run is opened from its own row — so it
    /// reads nothing: each run's steady dot goes when that run is opened,
    /// and the task's row keeps its dot while any of its runs is
    /// unopened.
    private func toggleTask(_ task: ScheduledAgentTask) {
        let unfolding = !expandedScheduledTasks.contains(task.id)
        withAnimation(.easeInOut(duration: 0.16)) {
            if unfolding {
                expandedScheduledTasks.insert(task.id)
            } else {
                expandedScheduledTasks.remove(task.id)
            }
        }
        if unfolding {
            openTaskPage(task)
        }
    }

    /// The centre pane shows the task's page: its settings, with no run
    /// under them.
    private func openTaskPage(_ task: ScheduledAgentTask) {
        appState.openAgentSessionId = nil
        appState.openAgentSessionPath = nil
        // Clearing the routing fields above does NOT dismiss an unsent
        // draft, an open note or an open chat: their `didSet` hooks bail
        // on nil, so only assigning a NON-nil value pushes the other
        // routes aside, and this field has no `didSet` of its own. A
        // pending draft left in place drew the new-session hero and its
        // composer with the task's banner on top; an open note is drawn
        // ahead of any task (`ContentView.centerPane`), so the page never
        // appeared at all. A chat is drawn BEHIND a task, so the page
        // did appear over one — but the chat stayed open underneath: its
        // sidebar row stayed selected beside the task's, and a reply
        // landing in it left no steady dot, since `ChatManager` never
        // marks the open chat.
        appState.pendingClaudeSessionDraft = nil
        appState.openNoteId = nil
        appState.openChatSlug = nil
        appState.openChatProject = nil
        appState.openScheduledTaskName = task.name
    }

    /// Rename (rewrites the SKILL.md description Claude Desktop and the
    /// CLI both read), Delete definition (the definition and its schedule;
    /// the runs are kept) and Delete all (the definition and every run).
    /// A task whose definition is gone — its runs are all it is — offers
    /// neither of the first two, which would have nothing to act on.
    @ViewBuilder
    private func taskMenuItems(for task: ScheduledAgentTask) -> some View {
        if task.definition != nil {
            Button {
                taskNameDraft = task.description
                renamingSessionId = nil
                renamingTaskId = task.id
            } label: {
                Text("Rename", comment: "Scheduled task row menu item — edits in place")
            }
        }
        groupSubmenu(for: .scheduled(task))
        Divider()
        if task.definition != nil {
            Button(role: .destructive) {
                deletingTask = task
            } label: {
                Text("Delete definition",
                     comment: "Scheduled task row menu item — deletes the task's definition and keeps its runs")
            }
        }
        Button(role: .destructive) {
            deletingTaskAndRuns = task
        } label: {
            Text("Delete all",
                 comment: "Scheduled task row menu item — deletes the task's definition and every run session it made")
        }
    }

    private func commitTaskRename(_ task: ScheduledAgentTask) {
        guard renamingTaskId == task.id else { return }
        renamingTaskId = nil
        let name = taskNameDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != task.description else { return }
        // Off the main actor per ScheduledTaskCreator's contract — the
        // file rewrite (and any crontab round-trip) must not stall the
        // UI. Mirrors AgentComposer's create path.
        Task.detached(priority: .userInitiated) {
            let ok = ScheduledTaskCreator.renameTask(
                skillFile: task.skillFileURL, description: name)
            if ok {
                await MainActor.run { agents.reloadSessions() }
            }
        }
    }

    private func deleteTask(_ task: ScheduledAgentTask) {
        deletingTask = nil
        // Close any run of this task that is open in the center column.
        if let openId = appState.openAgentSessionId,
           task.sessions.contains(where: { $0.id == openId }) {
            appState.openAgentSessionId = nil
            appState.openAgentSessionPath = nil
        }
        if appState.openScheduledTaskName == task.name {
            appState.openScheduledTaskName = nil
        }
        // Drop the scheduler's high-water mark: recreating a task with
        // the same name must not inherit a consumed slot, which would
        // silently swallow its first run.
        scheduler.forget(taskName: task.name)
        // deleteTask runs `crontab -l` + `crontab -` synchronously with
        // waitUntilExit — off-main per the creator's own contract.
        Task.detached(priority: .userInitiated) {
            ScheduledTaskCreator.deleteTask(named: task.name,
                                            directory: task.directoryURL)
            await MainActor.run { agents.reloadSessions() }
        }
    }

    /// What Delete all's confirmation says will go. A task whose
    /// definition is already gone does not "stop running" — only its
    /// runs are left to remove.
    private func deleteAllMessage(for task: ScheduledAgentTask) -> String {
        if task.definition != nil {
            return String(localized: "“\(task.description)” stops running, its definition is removed, and every run it made is removed for every app that reads them — SipAI, the CLI, and the desktop app. This cannot be undone.",
                          comment: "Body of the scheduled-task Delete all confirmation")
        }
        return String(localized: "“\(task.description)” and every run it made are removed for every app that reads them — SipAI, the CLI, and the desktop app. This cannot be undone.",
                      comment: "Body of the Delete all confirmation for a scheduled task whose definition is already gone")
    }

    /// "Delete all": the definition and every run the task made — the
    /// task leaves the sidebar with them.
    private func deleteTaskAndRuns(_ task: ScheduledAgentTask) {
        deletingTaskAndRuns = nil
        // The alert held the task as it stood when the menu opened; a
        // run that started and got its id since is only on the
        // manager's copy, and must go with the rest.
        let task = agents.scheduledTasks.first { $0.id == task.id } ?? task
        // Nothing of the task is left to show: its page, or any run.
        if let openId = appState.openAgentSessionId,
           task.sessions.contains(where: { $0.id == openId }) {
            appState.openAgentSessionId = nil
            appState.openAgentSessionPath = nil
        }
        if appState.openScheduledTaskName == task.name {
            appState.openScheduledTaskName = nil
        }
        // A task made again under this name starts folded.
        expandedScheduledTasks.remove(task.id)
        // Read before `forget` drops it: a run fired a moment ago has no
        // session id yet, so only the scheduler can name it.
        let startingRun = scheduler.inFlight[task.name]
        // The scheduler's record goes, as for Delete definition, and so
        // does its watch on a run in flight — which is stopped below and
        // must not write a record back for a task that is gone.
        scheduler.forget(taskName: task.name)
        agents.deleteScheduledTaskAndRuns(task, startingRun: startingRun)
    }

    // MARK: - Group name prompt

    private var groupPromptPresented: Binding<Bool> {
        Binding(
            get: { groupPrompt != nil },
            set: { if !$0 { groupPrompt = nil } }
        )
    }

    private var groupPromptTitle: String {
        switch groupPrompt {
        case .rename:
            return String(localized: "Rename group",
                          comment: "Title of the rename dialog for a custom session group")
        case .create, .none:
            return String(localized: "New group",
                          comment: "Title of the create dialog for a custom session group")
        }
    }

    private func promptForGroup(_ prompt: GroupPrompt) {
        switch prompt {
        case .rename(let name): groupNameDraft = name
        case .create: groupNameDraft = ""
        }
        groupPrompt = prompt
    }

    private func commitGroupPrompt() {
        let prompt = groupPrompt
        let name = groupNameDraft.trimmingCharacters(in: .whitespaces)
        groupPrompt = nil
        groupNameDraft = ""
        guard !name.isEmpty, let prompt = prompt else { return }
        switch prompt {
        case .create(let item):
            guard let stored = config.addAgentCustomGroup(name, for: agentKey)
            else { return }
            guard let item = item else { return }
            config.setAgentSessionGroup(stored, for: item.groupItemKey)
            // Filing is only visible under Custom, so a group created from
            // a row switches the list over rather than appearing to do
            // nothing. Creating one from the section menu doesn't need to:
            // that item is only offered while Custom is already on.
            if config.agentGroupMode(for: agentKey) != .custom {
                withAnimation(.easeInOut(duration: 0.18)) {
                    config.setAgentGroupMode(.custom, for: agentKey)
                }
            }
        case .rename(let old):
            guard config.renameAgentCustomGroup(old, to: name, for: agentKey)
            else { return }
            // A draft started from this group's + and not yet sent
            // carries the OLD name, and the first send hands that draft
            // to the runner — so left alone, the rename would unfile
            // the very session the group's page is promising to hold.
            // Groups are keyed by name; following the rename here is
            // the only way to keep that promise.
            if appState.pendingClaudeSessionDraft?.customGroup == old,
               appState.pendingClaudeSessionDraft?.agentKey == agentKey {
                appState.pendingClaudeSessionDraft?.customGroup = name
            }
        }
    }

    // MARK: - Live state

    private func isRunning(_ sessionId: String) -> Bool {
        agents.inFlightSends[sessionId] != nil
            || agents.externalInFlightSessions.contains(sessionId)
    }

    /// Whether a row is running right now — the one test behind every
    /// activity dot in this section: a session row's leading glyph, a
    /// task row's dots after its name, a FOLDED group's header, and the
    /// COLLAPSED section's header (`sectionLive`), each answering for the
    /// rows it stands for. One spelling, so a header can never say a
    /// group is idle while a row inside it pulses, or the reverse.
    ///
    /// A task counts while it has a run in flight AND while the
    /// scheduler is firing one: `scheduler.isRunning` covers the window
    /// a scheduled run spends as a fresh draft, with no session id until
    /// claude's first system.init lands, so a per-session check alone
    /// leaves the row inert for the first seconds of every run it fires.
    private func isActive(_ item: AgentListItem) -> Bool {
        switch item {
        case .regular(let session):
            return isRunning(session.id)
        case .scheduled(let task):
            return scheduler.isRunning(task.name)
                || task.sessions.contains { isRunning($0.id) }
        }
    }

    /// Whether a row finished a run nobody has opened since — the one
    /// test behind every STEADY dot in this section: a session row's
    /// glyph, a task row's dots, a folded group's header, the collapsed
    /// section's header. A task counts while any of its runs does. What
    /// is true NOW: it never reads the place an open row is held at
    /// (`tier`).
    private func isUnread(_ item: AgentListItem) -> Bool {
        switch item {
        case .regular(let session):
            return agents.isSessionUnread(session.id)
        case .scheduled(let task):
            return task.sessions.contains { agents.isSessionUnread($0.id) }
        }
    }

    /// Where a row is PLACED — running, unread, or the rest (see
    /// `SidebarTier`), with the open row held at its best tier since it
    /// was opened. Running is `isActive`, the test every pulse reads, so
    /// a row is never placed as running without pulsing — a task while
    /// the scheduler fires it included; otherwise a task stands with its
    /// best run.
    private func tier(_ item: AgentListItem) -> SidebarTier {
        if isActive(item) { return .running }
        switch item {
        case .regular(let session):
            return agents.sidebarTier(forSession: session.id)
        case .scheduled(let task):
            return task.sessions
                .map { agents.sidebarTier(forSession: $0.id) }
                .min() ?? .rest
        }
    }

    private func isAwaitingApproval(_ sessionId: String) -> Bool {
        mcpBridge.pending.contains(where: { $0.sessionId == sessionId })
    }

    /// Which state bucket a row belongs in. Reads the same signals the row
    /// itself renders, so a row with an approval badge lands under "Waiting
    /// for approval" and one with an activity dot under "Working".
    ///
    /// "Unread" asks the PLACED tier, so an unread session opened a moment
    /// ago stays under it until the user moves on, as it does in every
    /// other mode. The running groups ask what is true now: a group
    /// called "Working" makes a claim about the row.
    private func groupState(for item: AgentListItem) -> AgentGroupState {
        switch item {
        case .regular(let session):
            if isAwaitingApproval(session.id) { return .awaitingApproval }
            if agents.inFlightSends[session.id] != nil { return .working }
            if agents.externalInFlightSessions.contains(session.id) {
                return .runningElsewhere
            }
            if agents.sidebarTier(forSession: session.id) == .unread {
                return .unread
            }
            return .idle
        case .scheduled(let task):
            if task.sessions.contains(where: { isAwaitingApproval($0.id) }) {
                return .awaitingApproval
            }
            if task.sessions.contains(where: { isRunning($0.id) }) {
                return .working
            }
            if task.sessions.contains(where: {
                agents.sidebarTier(forSession: $0.id) == .unread
            }) {
                return .unread
            }
            return .scheduled
        }
    }
}

/// A small yellow warning badge indicating a session has one or more
/// unresolved MCP approvals. Distinct from `ActivityDot` (orange,
/// running) — the two can both appear on the same row when a session
/// is mid-send AND waiting on a permission.
private struct ApprovalBadge: View {
    var body: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.yellow)
            .accessibilityLabel(String(
                localized: "Session is waiting for approval",
                comment: "Accessibility label for the sidebar approval badge"))
    }
}

/// The title line of a session-group header: the fold chevron, the
/// group's name, the dim parent folder in Folder mode, the dots while
/// the group is FOLDED over a running or an unopened row, and the row
/// count at the trailing edge.
///
/// The dots are a sibling AFTER the text, never part of it, and the text
/// is the only thing on the line that gives way. Group names run long —
/// a folder's, or whatever the user typed — so the text truncates, and
/// the dots land right after whatever "…" that leaves. They are
/// `fixedSize`, so the stack gives them their width before the text is
/// offered anything; the count is `fixedSize` too, so its digits never
/// wrap or clip to make room. Laid out as part of the text instead, the
/// dots would be the first thing cut off, on exactly the long names that
/// hide the most rows.
///
/// Two things keep the dot ON the "…", both measured:
///
/// * The name and the parent folder are ONE run of text (`title`), so
///   there is one truncation and one "…". As two views, a long name
///   left the parent folder a sliver narrower than its own ellipsis:
///   it drew a stray "…" or half a glyph, or collapsed and left a
///   double gap before the dot.
/// * The run truncates at the TAIL, like every other row in the
///   sidebar. SwiftUI's `.middle` truncation is not stable: text
///   measured at one width is drawn re-truncated, up to a glyph or two
///   narrower (247 pt at its own width, 237 when drawn), and the
///   difference is left as empty space inside the text's frame —
///   between the name and the dot. `.tail` measures the same at its
///   own width every time.
///
/// A type of its own, taking plain values, so the layout can be
/// rendered headless (`Verification/SidebarGroupActivity`).
struct AgentGroupHeaderLabel: View {
    let label: String
    /// The parent folder's name in Folder mode; empty elsewhere.
    let detail: String
    let count: Int
    let folded: Bool
    /// A row in the group is running. Drawn only while folded: an open
    /// group's running row carries its own dot.
    let live: Bool
    /// A row in the group finished and has not been opened since: the
    /// steady dot, while folded — right after the pulse when a row is
    /// running too (`GroupActivityDots`).
    var unread: Bool = false
    let titleSize: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: folded ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 8)
            title
                .lineLimit(1)
                .truncationMode(.tail)
            if folded && (live || unread) {
                GroupActivityDots(live: live, unread: unread)
            }
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .fixedSize()
        }
    }

    /// The name, then — in Folder mode — the parent folder, smaller and
    /// dimmer. The name comes first, so the parent folder is what the
    /// truncation takes first.
    private var title: Text {
        let name = Text(label)
            .font(.system(size: titleSize, weight: .semibold))
            .foregroundStyle(.secondary)
        guard !detail.isEmpty else { return name }
        return name
            + Text(verbatim: " ")
                .font(.system(size: titleSize, weight: .semibold))
            + Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
    }
}

/// A scheduled task's glyph, and its fold state: the task's clock
/// between two short bars. The bars lie above and below the clock while
/// the task is folded, and turn a quarter turn with the fold — to its
/// left and right — while its runs are showing. One glyph says both what
/// the row is and whether it is open; a separate chevron would say the
/// second at the price of a second glyph of indent for every run under
/// the task. The fold itself is the whole row's click.
///
/// It says nothing about the runs: the clock stays the clock while a run
/// goes or sits unopened, and the row draws those dots after the task's
/// name (`GroupActivityDots`), where there is room for both at once — a
/// dot swapped in for the clock could only ever be one of the two.
///
/// Laid out in the row's usual 14 pt slot, so the title keeps every
/// other row's column and the row is no taller than any other. The
/// drawing is 16 pt square about the same centre, which puts the bars
/// just outside the slot and every edge on a whole point in both
/// positions: 1 pt bars, 16 − 8 even. At 1x each bar is one crisp row
/// (or column) of pixels; a thicker or off-grid bar is not a heavier line
/// but a fainter one, and lopsided once turned.
///
/// A type of its own, taking plain values, so it can be rendered
/// headless (`Verification/SidebarGroupActivity`).
struct ScheduledTaskGlyph: View {
    /// The task's runs are showing.
    let expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Image(systemName: "timer")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            bars
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16),
                           value: expanded)
        }
        .frame(width: 16, height: 16)
        .frame(width: 14, height: 14)
    }

    private var bars: some View {
        VStack(spacing: 0) {
            bar
            Spacer(minLength: 0)
            bar
        }
        .frame(width: 16, height: 16)
        .foregroundStyle(.secondary)
    }

    private var bar: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .frame(width: 8, height: 1)
    }
}
