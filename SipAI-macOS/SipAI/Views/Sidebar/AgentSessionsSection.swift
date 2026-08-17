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

    /// The name prompt shared by "New Group…" and "Rename Group…".
    private enum GroupPrompt: Identifiable {
        /// Creating a group. The item, when present, is filed into it on
        /// save — that's the "Add to Group ▸ New Group…" path.
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
    /// Session under the ⋮ Delete confirmation.
    @State private var deletingSession: AgentSession? = nil
    /// Scheduled task under the ⋮ Delete confirmation.
    @State private var deletingTask: ScheduledAgentTask? = nil

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

    /// True if this section's agent binary is detected on this machine —
    /// each agent's section answers its own "am I installed?" question.
    private var isInstalled: Bool {
        agents.isAgentInstalled(agentKey)
    }

    /// Installed AND configured (codex: working auth). Only a ready
    /// agent earns the "New session" row — an installed-but-unconfigured
    /// CLI would fail every spawn, so it lists read-only instead.
    private var isReady: Bool {
        agents.isAgentReady(agentKey)
    }

    /// Sessions synced from a desktop app count even without the CLI —
    /// that's the read-only tier: list, read, rename, group; no sends.
    private var hasAnyRows: Bool {
        !sectionScheduledTasks.isEmpty || !sectionRegularSessions.isEmpty
    }

    private var sectionRegularSessions: [AgentSession] {
        agents.regularSessions(for: agentKey)
    }

    private var sectionScheduledTasks: [ScheduledAgentTask] {
        agents.scheduledTasks(for: agentKey)
    }

    private var sectionTitle: String {
        isReady ? agentName
            : agentName + " " + String(
                localized: "(read only)",
                comment: "Sidebar section title suffix when the agent CLI is missing or not configured")
    }

    private var groupMode: AgentGroupMode {
        config.agentGroupMode(for: agentKey)
    }

    private var customGroups: [String] {
        config.agentCustomGroups(for: agentKey)
    }

    var body: some View {
        DisclosureSection(
            title: sectionTitle,
            isExpanded: $expanded,
            accessory: { groupMenu }
        ) {
            if isReady {
                newSessionButton
                sessionList
            } else if hasAnyRows {
                readOnlyHintRow
                sessionList
            } else if isInstalled {
                // Binary present, auth missing, nothing synced yet.
                readOnlyHintRow
            } else {
                notInstalledRow
            }
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
            String(localized: "Delete scheduled task?",
                   comment: "Title of the scheduled-task delete confirmation"),
            isPresented: Binding(
                get: { deletingTask != nil },
                set: { if !$0 { deletingTask = nil } }
            ),
            presenting: deletingTask
        ) { task in
            Button(role: .destructive) {
                deleteTask(task)
            } label: {
                Text("Delete", comment: "Confirm deleting a scheduled task")
            }
            Button(role: .cancel) { } label: {
                Text("Cancel", comment: "Dismiss the scheduled-task delete confirmation")
            }
        } message: { task in
            Text(String(localized: "“\(task.description)” stops running and its definition is removed. Past run sessions are kept.",
                        comment: "Body of the scheduled-task delete confirmation"))
        }
    }

    // MARK: - Group menu (section header accessory)

    @ViewBuilder
    private var groupMenu: some View {
        // Grouping is a read operation — offered for read-only stores too.
        if isInstalled || hasAnyRows {
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
                        Text("New Group…",
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
    private func startNewSession(cwd cwdURL: URL) {
        appState.pendingClaudeSessionDraft = ClaudeSessionDraft(
            cwd: cwdURL,
            name: nil,
            agentKey: agentKey
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
        let fm = FileManager.default
        func usable(_ path: String?) -> String? {
            guard let path = path, !path.isEmpty else { return nil }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            return path
        }
        let cwd = usable(config.agentLastCwd(for: agentKey))
            ?? usable(sectionRegularSessions.first?.projectPath?.path)
            ?? NSHomeDirectory()
        startNewSession(cwd: URL(fileURLWithPath: cwd, isDirectory: true))
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
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
           isDir.boolValue {
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
        var items = sectionScheduledTasks.map(AgentListItem.scheduled)
        items.append(contentsOf: sectionRegularSessions.map(AgentListItem.regular))
        items.sort {
            if $0.sortDate != $1.sortDate {
                return $0.sortDate > $1.sortDate
            }
            return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }

        // Read off the raw list, so it stands whatever is revealed or
        // folded. Only regular sessions are ever capped (below).
        let sectionOverflow = perGroup
            ? 0
            : max(0, sectionRegularSessions.count - Self.defaultLimit)
        let sectionCapped = !perGroup && !sectionRevealed
        var budget = Self.defaultLimit

        var groups: [ListGroup] = []
        for group in AgentSessionGrouping.buckets(
            items,
            mode: mode,
            state: groupState(for:),
            customGroups: customGroups,
            assignments: config.agentSessionGroupAssignments
        ) {
            let total = group.items.count
            // Cap only REGULAR sessions, in both branches. Scheduled
            // task parents must survive the trim (the documented
            // invariant at `defaultLimit`): a never-run task sorts
            // to the group's bottom via .distantPast, so a plain
            // prefix() hid exactly the rows that look deleted when
            // missing.
            if perGroup {
                guard !folded.contains(group.key) else {
                    groups.append(ListGroup(group: group, overflow: 0,
                                            revealed: false, total: total))
                    continue
                }
                var kept: [AgentListItem] = []
                var regularKept = 0
                var overflow = 0
                for item in group.items {
                    switch item {
                    case .scheduled:
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
                        items: kept
                    ),
                    overflow: overflow,
                    revealed: revealed,
                    total: total
                ))
            } else if sectionCapped {
                var kept: [AgentListItem] = []
                for item in group.items {
                    switch item {
                    case .scheduled:
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
                        items: kept
                    ),
                    overflow: 0,
                    revealed: false,
                    total: total
                ))
            } else {
                groups.append(ListGroup(group: group, overflow: 0,
                                        revealed: sectionRevealed, total: total))
            }
        }
        return ListLayout(groups: groups,
                          overflow: sectionOverflow,
                          revealed: sectionRevealed)
    }

    @ViewBuilder
    private var sessionList: some View {
        if !hasAnyRows {
            emptyRow
        } else {
            let mode = groupMode
            // Folded state is an INPUT to the layout, not just a render
            // decision: the per-group cap must not trim rows out of a
            // group that draws none of them.
            let folded = config.agentCollapsedGroups(for: agentKey, mode: mode)
            let layout = listLayout(folded: folded)
            // User-dragged order over the bucketer's own (per mode, per
            // agent). Each group renders as ONE block — header plus its
            // rows — so the whole block is a drop target and dragging a
            // header across a tall unfolded group still reorders live.
            // The sub-VStack matches the parent's 2-pt spacing, so the
            // wrapping is invisible.
            let orderedGroups = SidebarOrdering.apply(
                layout.groups,
                order: config.agentGroupOrder(for: agentKey, mode: mode),
                id: \.id)
            ForEach(orderedGroups) { entry in
                let group = entry.group
                VStack(alignment: .leading, spacing: 2) {
                    if mode != .none {
                        groupHeaderRow(group,
                                       count: entry.total,
                                       folded: folded.contains(group.key),
                                       mode: mode)
                            // The header is the drag handle; session and
                            // task rows keep their click behaviour.
                            .onDrag {
                                NSItemProvider(object:
                                    (groupDragPrefix(mode) + group.key) as NSString)
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
    /// Folder headers of a ready agent carry a trailing + — sharing the
    /// 18-pt column the session rows' ⋮ sits in — that starts a new
    /// session in that folder; the count sits directly left of it. The +
    /// is OUTSIDE the fold button (nested SwiftUI buttons both fire), so
    /// everything on the row except the + itself folds the group.
    ///
    /// `count` is the group's size BEFORE the cap, never `group.items
    /// .count`: a trimmed group renders fewer rows than it holds, and a
    /// header saying "10" directly above "Show all (24 more)" contradicts
    /// the button it is sitting on top of.
    @ViewBuilder
    private func groupHeaderRow(_ group: AgentSessionGroup,
                                count: Int,
                                folded: Bool,
                                mode: AgentGroupMode) -> some View {
        let showsFolderPlus = mode == .folder
            && isReady
            && group.key != AgentSessionGrouping.noDirectoryKey
        let header = HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    config.setAgentGroupCollapsed(!folded,
                                                  group: group.key,
                                                  for: agentKey,
                                                  mode: mode)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: folded ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 8)
                    Text(group.label)
                        .font(.system(size: SipFont.sidebarRow(fontScale), weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !group.detail.isEmpty {
                        Text(group.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(-1)
                    }
                    Spacer(minLength: 4)
                    Text("\(count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .padding(.leading, 8)
                .padding(.trailing, showsFolderPlus ? 2 : 8)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.label)
            .accessibilityHint(folded
                ? String(localized: "Expand group",
                         comment: "Accessibility hint for a folded session group")
                : String(localized: "Collapse group",
                         comment: "Accessibility hint for an expanded session group"))

            if showsFolderPlus {
                RowPlusButton(
                    label: String(localized: "New session in \(group.label)",
                                  comment: "Tooltip and accessibility label for the + on a folder group header"),
                    action: { startNewSession(inFolder: group.key) }
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
                    Text("Rename Group…",
                         comment: "Context menu item on a custom group header")
                }
                Button(role: .destructive) {
                    deletingGroup = group.key
                } label: {
                    Text("Delete Group",
                         comment: "Context menu item on a custom group header")
                }
            }
        } else {
            header
        }
    }

    // MARK: - Empty / not-installed states

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

    private var notInstalledRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("\(agentName) is not installed on this machine. Install it to start a session.",
                 comment: "Sidebar hint when an agent CLI binary is missing")
                .font(.system(size: SipFont.sidebarHint(fontScale)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Shown above a read-only list. Two flavours of read-only: the CLI
    /// is missing entirely, or it is installed but has no working auth
    /// (codex before `codex login` / a real API key) — the fix differs,
    /// so the hint says which one applies.
    private var readOnlyHintRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Group {
                if isInstalled {
                    Text("\(agentName) CLI is installed but not signed in. Sessions sync read-only — configure it (e.g. codex login or an API key) to start new sessions.",
                         comment: "Sidebar hint when an agent CLI exists but has no working auth")
                } else {
                    Text("Sessions sync read-only. Install the \(agentName) CLI to interact.",
                         comment: "Sidebar hint when an agent has sessions but no CLI")
                }
            }
            .font(.system(size: SipFont.sidebarHint(fontScale)))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Scheduled task rows

    private func scheduledTaskRow(_ task: ScheduledAgentTask) -> some View {
        let isExpanded = expandedScheduledTasks.contains(task.id)
        // `scheduler.isRunning` covers the window a scheduled run spends
        // as a fresh draft: it has no session id until claude's first
        // system.init lands, so a per-session check alone leaves the row
        // inert for the first seconds of every run it fires.
        let hasActivity = scheduler.isRunning(task.name)
            || task.sessions.contains { isRunning($0.id) }
        let hasApproval = task.sessions.contains { isAwaitingApproval($0.id) }

        return VStack(alignment: .leading, spacing: 0) {
            if renamingTaskId == task.id {
                inlineRenameRow(
                    icon: "timer",
                    text: $taskNameDraft,
                    leadingPad: 8,
                    onCommit: { commitTaskRename(task) },
                    onCancel: cancelInlineRename
                )
            } else {
            HStack(spacing: 0) {
                // The chevron is its OWN button, separate from the row
                // body: the row now opens the task in the centre pane,
                // and folding a parent open to see its runs must not
                // also navigate away from whatever is on screen.
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if isExpanded {
                            expandedScheduledTasks.remove(task.id)
                        } else {
                            expandedScheduledTasks.insert(task.id)
                        }
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 8)
                        .padding(.leading, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded
                    ? String(localized: "Collapse scheduled runs",
                             comment: "Accessibility label for the expanded task chevron")
                    : String(localized: "Expand scheduled runs",
                             comment: "Accessibility label for the collapsed task chevron"))
                Button {
                    openTask(task)
                } label: {
                    HStack(spacing: 6) {
                        leadingGlyph(icon: "timer", size: 11,
                                     active: hasActivity)
                        Text(task.description)
                            .font(.system(size: SipFont.sidebarRow(fontScale)))
                            .lineLimit(1)
                            .truncationMode(.tail)
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
                        if !hasActivity {
                            if let lastActive = task.lastActive {
                                Text(Self.relativeFormatter.localizedString(
                                    for: lastActive, relativeTo: Date()))
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
                    .padding(.leading, 6)
                    .padding(.trailing, 2)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                RowEllipsisMenu { taskMenuItems(for: task) }
                    .padding(.trailing, 4)
            }
            .sidebarRowBackground(selected: appState.openScheduledTaskName == task.name
                                  && appState.openAgentSessionId == nil)
            .contextMenu { taskMenuItems(for: task) }
            .accessibilityLabel(task.description)
            .accessibilityHint(String(localized: "Open this scheduled task",
                                      comment: "Accessibility hint for a scheduled task row"))
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
                    .padding(.leading, 36)
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
    /// can tell. Nil for an orphan, whose definition is gone.
    private func scheduleStatusLabel(_ task: ScheduledAgentTask) -> String? {
        guard let def = task.definition else { return nil }
        if !def.enabled {
            return String(localized: "Paused",
                          comment: "Sidebar tag on a scheduled task that will not fire")
        }
        guard def.schedule != nil else {
            return String(localized: "No schedule",
                          comment: "Sidebar tag on a scheduled task with no cron expression")
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
                leadingPad: nested ? 36 : 8,
                onCommit: { commitSessionRename(session) },
                onCancel: cancelInlineRename
            )
        } else {
            let selected = appState.openAgentSessionId == session.id
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
                                     active: isRunning(session.id))
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
                        if !isRunning(session.id) {
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
                    .padding(.leading, nested ? 36 : 8)
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
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
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
    /// title; the icon returns the moment the run finishes. Both states
    /// share one fixed frame so the title never shifts when they swap.
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
                              active: Bool) -> some View {
        Group {
            if active {
                ActivityDot()
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
    }

    /// Rename / Delete — the ⋮ and right-click menu. No group filing
    /// here: a session's place is where it ran, not something to move.
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
        Divider()
        Button(role: .destructive) {
            deletingSession = session
        } label: {
            Text("Delete", comment: "Session row menu item")
        }
    }

    /// "Add to Group" submenu — the assignment half of custom grouping.
    /// Its "New Group…" goes through `commitGroupPrompt`'s
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
    /// "New Group…" lands in `commitGroupPrompt` with no row to file;
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
                    Text("New Group…",
                         comment: "Group submenu item — create a group and file this row into it")
                }
                if current != nil {
                    Divider()
                    Button {
                        config.setAgentSessionGroup(nil, for: item.groupItemKey)
                    } label: {
                        Text("Remove from Group",
                             comment: "Group submenu item — un-file this row")
                    }
                }
            } label: {
                Text("Add to Group",
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

    private func commitSessionRename(_ session: AgentSession) {
        guard renamingSessionId == session.id else { return }
        renamingSessionId = nil
        let name = sessionNameDraft.trimmingCharacters(in: .whitespaces)
        // Empty (or reverting to the scanner's own title) clears the
        // custom label instead of freezing the automatic name.
        if name.isEmpty || name == session.title {
            config.setAgentSessionDisplayName(nil, for: session.id)
        } else {
            config.setAgentSessionDisplayName(name, for: session.id)
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

    /// Open a task in the centre pane: its key-information panel, and
    /// beneath it the newest run rendered like any other session. A task
    /// that has never run opens with the panel alone.
    private func openTask(_ task: ScheduledAgentTask) {
        // Did this click change what the centre pane shows? Answered
        // BEFORE the routing fields are written, and used below to decide
        // whether the click also means "fold this away".
        let selectionUnchanged = appState.openScheduledTaskName == task.name
            && appState.openAgentSessionId == task.sessions.first?.id
        if let newest = task.sessions.first {
            appState.openAgentSessionId = newest.id
            appState.openAgentSessionPath = newest.fileURL
        } else {
            appState.openAgentSessionId = nil
            appState.openAgentSessionPath = nil
        }
        // Clearing the routing fields above does NOT dismiss an unsent
        // draft: their `didSet` hooks bail on nil, so only assigning a
        // NON-nil value pushes the other routes aside. Opening a
        // never-run task while a draft was pending therefore left the
        // draft in place, and the centre pane rendered the new-session
        // hero and its composer with the task's banner on top — exactly
        // the "page that looks like a new session" symptom.
        appState.pendingClaudeSessionDraft = nil
        appState.openScheduledTaskName = task.name

        // The row folds on click like every other expandable row in this
        // sidebar — the chevron is a shortcut, not the only way in.
        //
        // It only COLLAPSES on a click that changed nothing, i.e. a
        // second click on what is already showing. A click that brings
        // something new into the centre pane — another task, or this
        // task's newest run while an older run was open — must not
        // answer by hiding the runs the user just asked to see.
        var opened = expandedScheduledTasks
        if opened.contains(task.id) {
            if selectionUnchanged { opened.remove(task.id) }
        } else {
            opened.insert(task.id)
        }
        withAnimation(.easeInOut(duration: 0.16)) {
            expandedScheduledTasks = opened
        }
    }

    /// Rename (rewrites the SKILL.md description Claude Desktop and the
    /// CLI both read) and Delete (definition + schedule; run sessions
    /// are kept).
    @ViewBuilder
    private func taskMenuItems(for task: ScheduledAgentTask) -> some View {
        Button {
            taskNameDraft = task.description
            renamingSessionId = nil
            renamingTaskId = task.id
        } label: {
            Text("Rename", comment: "Scheduled task row menu item — edits in place")
        }
        groupSubmenu(for: .scheduled(task))
        Divider()
        Button(role: .destructive) {
            deletingTask = task
        } label: {
            Text("Delete", comment: "Scheduled task row menu item")
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
            config.renameAgentCustomGroup(old, to: name, for: agentKey)
        }
    }

    // MARK: - Live state

    private func isRunning(_ sessionId: String) -> Bool {
        agents.inFlightSends[sessionId] != nil
            || agents.externalInFlightSessions.contains(sessionId)
    }

    private func isAwaitingApproval(_ sessionId: String) -> Bool {
        mcpBridge.pending.contains(where: { $0.sessionId == sessionId })
    }

    /// Which state bucket a row belongs in. Reads the same signals the row
    /// itself renders, so a row with an approval badge lands under "Waiting
    /// for approval" and one with an activity dot under "Working".
    private func groupState(for item: AgentListItem) -> AgentGroupState {
        switch item {
        case .regular(let session):
            if isAwaitingApproval(session.id) { return .awaitingApproval }
            if agents.inFlightSends[session.id] != nil { return .working }
            if agents.externalInFlightSessions.contains(session.id) {
                return .runningElsewhere
            }
            return .idle
        case .scheduled(let task):
            if task.sessions.contains(where: { isAwaitingApproval($0.id) }) {
                return .awaitingApproval
            }
            if task.sessions.contains(where: { isRunning($0.id) }) {
                return .working
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
