// ChatListView.swift
// Disclosure-style sidebar sections — split into RootChatsSection and
// ProjectsSection so project-scoped and root-level conversations have
// distinct disclosure affordances in the left sidebar.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Root chats

struct RootChatsSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chats: ChatManager
    @Environment(\.sipFontScale) private var fontScale

    let searchText: String
    @Binding var expanded: Bool

    /// Same cap, and the same reveal row, as an agent section's session
    /// groups — the two lists sit in one sidebar, so a column that stays
    /// scannable in one must stay scannable in the other.
    @State private var revealed = false

    var body: some View {
        DisclosureSection(
            title: String(localized: "Chats",
                          comment: "Sidebar section header for chats not in any project"),
            isExpanded: $expanded
        ) {
            newChatRow
            let visible = filtered(chats.rootChats)
            if visible.isEmpty {
                emptyRow
            } else {
                let overflow = max(0, visible.count - SidebarRowCap.limit)
                ForEach(revealed ? visible : Array(visible.prefix(SidebarRowCap.limit)),
                        id: \.id) { chat in
                    SidebarChatRow(chat: chat)
                }
                if overflow > 0 {
                    SidebarShowMoreRow(overflow: overflow, revealed: revealed) {
                        revealed.toggle()
                    }
                }
            }
        }
    }

    /// First row of the section — same shape as the Claude Code
    /// section's "+ New session" row so the two actions read as one
    /// idiom.
    private var newChatRow: some View {
        Button {
            appState.startNewChat()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("New chat", comment: "Button to start a new conversation")
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

    private var emptyRow: some View {
        HStack {
            Text(searchText.isEmpty
                 ? String(localized: "No chats yet.",
                          comment: "Root Chats section: empty placeholder")
                 : String(localized: "No matching chats.",
                          comment: "Root Chats section: empty after filtering"))
                .font(.system(size: SipFont.sidebarHint(fontScale)))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func filtered(_ list: [StoredChat]) -> [StoredChat] {
        guard !searchText.isEmpty else { return list }
        return list.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }
}

// MARK: - Projects

struct ProjectsSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chats: ChatManager
    @EnvironmentObject var projects: ProjectManager
    @EnvironmentObject var config: ConfigManager
    @Environment(\.sipFontScale) private var fontScale

    let searchText: String
    @Binding var expanded: Bool
    @Binding var expandedProjects: Set<String>

    /// Project being renamed inline (⋮ → Rename, or freshly created via
    /// the header's +). Slug-keyed; one at a time.
    @State private var renamingProject: String? = nil
    @State private var projectNameDraft: String = ""
    @FocusState private var renameFocused: Bool
    /// Project under the ⋮ Delete confirmation.
    @State private var deletingProject: ProjectInfo? = nil
    /// Groups whose own reveal row has been clicked, by slug. Per group,
    /// exactly as in an agent section's Folder / State / Custom modes: a
    /// group is a place, and "the 10 newest in here" is a question with
    /// an answer per place. Slugs are already unique across the sidebar,
    /// so unlike the agent section this needs no further scoping.
    @State private var revealedProjects: Set<String> = []

    var body: some View {
        DisclosureSection(
            title: String(localized: "Chat groups",
                          comment: "Sidebar section header for chat groups"),
            isExpanded: $expanded
        ) {
            newProjectRow
            if projects.projects.isEmpty {
                emptyRow
            } else {
                // User-dragged order over the manager's alphabetical
                // baseline. The header row is the drag handle; the whole
                // block (header + expanded chats) is the drop target.
                ForEach(orderedProjects) { project in
                    projectRows(project)
                        .onDrop(of: [.plainText],
                                delegate: SidebarReorderDropDelegate(
                                    itemId: project.slug,
                                    payloadPrefix: "chatgroup:",
                                    order: projectOrderBinding))
                }
            }
        }
        .alert(
            String(localized: "Delete group?",
                   comment: "Title of the chat-group delete confirmation"),
            isPresented: Binding(
                get: { deletingProject != nil },
                set: { if !$0 { deletingProject = nil } }
            ),
            presenting: deletingProject
        ) { project in
            Button(role: .destructive) {
                deleteProject(project)
            } label: {
                Text("Delete", comment: "Confirm deleting a chat group")
            }
            Button(role: .cancel) { } label: {
                Text("Cancel", comment: "Dismiss the chat-group delete confirmation")
            }
        } message: { project in
            // String(localized:) then verbatim Text — user-typed names
            // must not be markdown-parsed (see AgentSessionsSection).
            Text(String(localized: "“\(project.name)” and all its chats are removed. This cannot be undone.",
                        comment: "Body of the chat-group delete confirmation"))
        }
    }

    // MARK: - Ordering

    private var orderedProjects: [ProjectInfo] {
        SidebarOrdering.apply(projects.projects,
                              order: config.chatGroupOrder,
                              id: \.slug)
    }

    private var projectOrderBinding: Binding<[String]> {
        Binding(
            get: { orderedProjects.map(\.slug) },
            set: { config.setChatGroupOrder($0) }
        )
    }

    // MARK: - Rows

    /// First row of the section — same "+ …" action-row shape as the
    /// Chats and agent sections.
    private var newProjectRow: some View {
        Button(action: createProject) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("New group",
                     comment: "Sidebar action row — create a new chat group")
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

    @ViewBuilder
    private func projectRows(_ project: ProjectInfo) -> some View {
        let projChats = filtered(chats.projectChats[project.slug] ?? [])
        let isProjectExpanded = expandedProjects.contains(project.slug)

        VStack(alignment: .leading, spacing: 2) {
            if renamingProject == project.slug {
                projectRenameRow(project)
            } else {
                projectHeaderRow(project, isExpanded: isProjectExpanded)
                    // Drag handle for reordering groups. On the HEADER
                    // only — a drag started on a chat row inside an
                    // expanded group must not move the whole folder.
                    .onDrag {
                        NSItemProvider(object: ("chatgroup:" + project.slug) as NSString)
                    }
            }

            if isProjectExpanded {
                if projChats.isEmpty {
                    HStack {
                        Text(searchText.isEmpty
                             ? String(localized: "No chats in this group yet.",
                                      comment: "Empty placeholder inside an expanded chat group")
                             : String(localized: "No matching chats.",
                                      comment: "Empty after filtering inside a chat group"))
                            .font(.system(size: SipFont.sidebarHint(fontScale)))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.leading, 12)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                } else {
                    let revealed = revealedProjects.contains(project.slug)
                    let overflow = max(0, projChats.count - SidebarRowCap.limit)
                    ForEach(revealed
                            ? projChats
                            : Array(projChats.prefix(SidebarRowCap.limit)),
                            id: \.id) { chat in
                        SidebarChatRow(chat: chat).padding(.leading, 12)
                    }
                    // Inside the group's own block, under its last chat.
                    // 40 pt = the rows' 12-pt indent + the 28 pt that
                    // lines a label up with a row TITLE (8 pt padding + a
                    // 14-pt glyph + the row's 6-pt spacing).
                    if overflow > 0 {
                        SidebarShowMoreRow(overflow: overflow,
                                           revealed: revealed,
                                           indent: 40) {
                            if revealed {
                                revealedProjects.remove(project.slug)
                            } else {
                                revealedProjects.insert(project.slug)
                            }
                        }
                    }
                }
            }
        }
        .padding(.leading, 4)
    }

    /// The ⋮ sits outside the expand-button so its click never also
    /// toggles the project open (nested SwiftUI buttons both fire).
    private func projectHeaderRow(_ project: ProjectInfo,
                                  isExpanded: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isExpanded {
                        expandedProjects.remove(project.slug)
                    } else {
                        expandedProjects.insert(project.slug)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(project.name)
                        .font(.system(size: SipFont.sidebarRow(fontScale), weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 6)
                .padding(.trailing, 2)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RowEllipsisMenu { projectMenuItems(project) }
                .padding(.trailing, 4)
        }
        .sidebarRowBackground()
        // Same actions on right-click, so both idioms work.
        .contextMenu { projectMenuItems(project) }
    }

    /// The row's title swapped for a text field in place — no dialog.
    /// Enter saves; Escape or clicking anywhere else abandons the edit
    /// (a freshly created project then simply keeps "New Project").
    private func projectRenameRow(_ project: ProjectInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("", text: $projectNameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: SipFont.sidebarRow(fontScale), weight: .medium))
                .focused($renameFocused)
                .onSubmit { commitProjectRename(project) }
                .onExitCommand { renamingProject = nil }
                .onChange(of: renameFocused) { _, focused in
                    // Click-away = regret. The Enter path clears the
                    // renaming slug before focus drops, so this cancel
                    // is a no-op after a real commit.
                    if focused {
                        FocusedFieldSelection.selectAll()
                    } else {
                        renamingProject = nil
                    }
                }
                .onAppear { renameFocused = true }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.18))
        )
        // Clicks that don't move key focus (rows, buttons, empty
        // space) — see EditFieldClickAway.
        .editFieldClickAway { renamingProject = nil }
    }

    // MARK: - Menu (⋮ / right-click)

    @ViewBuilder
    private func projectMenuItems(_ project: ProjectInfo) -> some View {
        Button {
            addChat(to: project)
        } label: {
            Text("Add Chat", comment: "Chat-group row menu item — start a new chat filed in this group")
        }
        Button {
            projectNameDraft = project.name
            renamingProject = project.slug
        } label: {
            Text("Rename", comment: "Chat-group row menu item — edits in place")
        }
        Divider()
        Button(role: .destructive) {
            deletingProject = project
        } label: {
            Text("Delete", comment: "Chat-group row menu item")
        }
    }

    // MARK: - Actions

    /// The "+ New group" row: the group exists immediately (so a
    /// click-away keeps it as "New Group") and its name opens for
    /// editing in place. Slugs are deduped by ProjectManager, so
    /// repeated clicks are safe.
    private func createProject() {
        let project = projects.createProject(
            name: String(localized: "New Group",
                         comment: "Default name for a chat group created from the sidebar +"))
        projectNameDraft = project.name
        renamingProject = project.slug
    }

    private func commitProjectRename(_ project: ProjectInfo) {
        guard renamingProject == project.slug else { return }
        renamingProject = nil
        let name = projectNameDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != project.name else { return }
        projects.renameProject(slug: project.slug, newName: name)
    }

    /// New empty chat targeted at this project — the first message files
    /// it there (ChatView's pending-identity flow).
    private func addChat(to project: ProjectInfo) {
        appState.startNewChat()
        appState.openChatProject = project.slug
        withAnimation(.easeInOut(duration: 0.18)) {
            _ = expandedProjects.insert(project.slug)
        }
    }

    /// The project directory goes away with every chat in it.
    private func deleteProject(_ project: ProjectInfo) {
        deletingProject = nil
        // Close the open chat if it lives here — its file is about to go.
        if appState.openChatProject == project.slug {
            appState.startNewChat()
        }
        projects.deleteProject(slug: project.slug)
        chats.reload()
        expandedProjects.remove(project.slug)
    }

    private var emptyRow: some View {
        HStack {
            Text(String(localized: "No groups yet.",
                        comment: "Chat groups section: empty placeholder"))
                .font(.system(size: SipFont.sidebarHint(fontScale)))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func filtered(_ list: [StoredChat]) -> [StoredChat] {
        guard !searchText.isEmpty else { return list }
        return list.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }
}

// MARK: - Chat row (shared between sections)

struct SidebarChatRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chats: ChatManager
    @EnvironmentObject var projects: ProjectManager
    @Environment(\.sipFontScale) private var fontScale
    let chat: StoredChat

    @State private var editingTitle = false
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool
    @State private var confirmingDelete = false
    @State private var showingNewProject = false
    @State private var newProjectDraft = ""

    private var isSelected: Bool {
        appState.openChatSlug == chat.slug
            && appState.openChatProject == chat.project
    }

    /// Same abbreviated style as the agent session rows
    /// (`AgentSessionsSection.relativeFormatter`) — the two lists sit in
    /// one sidebar, so their time columns must read identically.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        Group {
            if editingTitle {
                renameRow
            } else {
                normalRow
            }
        }
        .alert(String(localized: "Delete chat?",
                      comment: "Title of the chat delete confirmation"),
               isPresented: $confirmingDelete) {
            Button(role: .destructive) {
                deleteChat()
            } label: {
                Text("Delete", comment: "Confirm deleting a chat")
            }
            Button(role: .cancel) { } label: {
                Text("Cancel", comment: "Dismiss the chat delete confirmation")
            }
        } message: {
            Text(String(localized: "“\(chat.title)” and its messages are removed. This cannot be undone.",
                        comment: "Body of the chat delete confirmation"))
        }
        .alert(String(localized: "New group",
                      comment: "Title of the new-group dialog opened from a chat's Move to menu"),
               isPresented: $showingNewProject) {
            TextField(String(localized: "Group name",
                             comment: "Placeholder in the new-group dialog"),
                      text: $newProjectDraft)
            Button {
                commitNewProjectMove()
            } label: {
                Text("Create & Move",
                     comment: "Confirm the new-group dialog — creates it and moves the chat in")
            }
            .keyboardShortcut(.defaultAction)
            Button(role: .cancel) { } label: {
                Text("Cancel", comment: "Dismiss the new-group dialog")
            }
        } message: {
            Text(String(localized: "The group is created and “\(chat.title)” moves into it.",
                        comment: "Body of the new-group dialog"))
        }
    }

    // MARK: Rows

    /// True while this chat is waiting on a reply — including one asked
    /// for and then walked away from, which is the whole reason the flag
    /// lives on the manager (see `ChatManager.inFlightChats`).
    private var isLive: Bool {
        chats.isChatInFlight(slug: chat.slug, project: chat.project)
    }

    private var normalRow: some View {
        HStack(spacing: 0) {
            Button {
                appState.openChatSlug = chat.slug
                appState.openChatProject = chat.project
            } label: {
                HStack(spacing: 6) {
                    // Live rows swap the bubble for the pulsing dot, the
                    // same language the agent rows speak one section
                    // down. Both states share one fixed frame, and the
                    // swap is unanimated, so the title cannot shift
                    // under it — the two glyphs have very different
                    // intrinsic widths, and centring inside a
                    // width-only frame lands them on a fractional pixel
                    // that rounds differently between render passes.
                    Group {
                        if isLive {
                            ActivityDot()
                        } else {
                            Image(systemName: "bubble.left")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 14, height: 14)
                    .animation(nil, value: isLive)
                    Text(chat.title)
                        .font(.system(size: SipFont.sidebarRow(fontScale)))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    // Nothing while the reply is in flight: the column
                    // answers "when did I last talk to this?", and
                    // mid-turn the honest answer is the one the dot is
                    // already giving. It returns when the turn ends.
                    if !isLive {
                        // The value `ChatManager.reload` also SORTS by —
                        // printing mtime while ordering on something else
                        // is how a list ends up looking unsorted.
                        Text(Self.relativeFormatter.localizedString(
                            for: chat.activityAt, relativeTo: Date()))
                            .font(.system(size: SipFont.sidebarHint(fontScale)))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 2)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RowEllipsisMenu { menuItems }
                .padding(.trailing, 4)
        }
        .sidebarRowBackground(selected: isSelected)
        // Same actions on right-click, so both idioms work.
        .contextMenu { menuItems }
    }

    /// The title swapped for a text field in place — no dialog. Only
    /// Enter saves; Escape OR clicking anywhere else abandons the edit
    /// and the original name stays.
    private var renameRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("", text: $renameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: SipFont.sidebarRow(fontScale)))
                .focused($renameFocused)
                .onSubmit { commitRename() }
                .onExitCommand { editingTitle = false }
                .onChange(of: renameFocused) { _, focused in
                    // Click-away = regret; the Enter path has already
                    // ended editing, so this is a no-op after a commit.
                    if focused {
                        FocusedFieldSelection.selectAll()
                    } else {
                        editingTitle = false
                    }
                }
                .onAppear { renameFocused = true }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.18))
        )
        // Clicks that don't move key focus (rows, buttons, empty
        // space) — see EditFieldClickAway.
        .editFieldClickAway { editingTitle = false }
    }

    // MARK: Menu

    @ViewBuilder
    private var menuItems: some View {
        Button {
            renameDraft = chat.title
            editingTitle = true
        } label: {
            Text("Rename", comment: "Chat row menu item — edits in place")
        }
        Menu {
            if chat.project != nil {
                Button {
                    move(to: nil)
                } label: {
                    Text("Chats",
                         comment: "Move-to target for the root (no group) scope")
                }
            }
            ForEach(projects.projects.filter { $0.slug != chat.project }) { project in
                Button {
                    move(to: project.slug)
                } label: {
                    Text(project.name)
                }
            }
            Divider()
            Button {
                newProjectDraft = ""
                showingNewProject = true
            } label: {
                Text("New Group…",
                     comment: "Move-to menu item — create a chat group and move the chat into it")
            }
        } label: {
            Text("Move to", comment: "Chat row submenu for moving between chat groups")
        }
        Divider()
        Button(role: .destructive) {
            confirmingDelete = true
        } label: {
            Text("Delete", comment: "Chat row menu item")
        }
    }

    // MARK: Actions

    private func commitRename() {
        guard editingTitle else { return }
        editingTitle = false
        let name = renameDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != chat.title else { return }
        chats.renameChat(slug: chat.slug, project: chat.project, newTitle: name)
        // Let an open ChatView refresh its stale liveTitle — otherwise its
        // next persist writes the old name back.
        NotificationCenter.default.post(
            name: .sipChatRenamed, object: nil,
            userInfo: ["slug": chat.slug,
                       "project": chat.project ?? "",
                       "title": name])
    }

    private func commitNewProjectMove() {
        let name = newProjectDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let project = projects.createProject(name: name)
        move(to: project.slug)
    }

    private func move(to targetProject: String?) {
        let wasOpen = isSelected
        guard let moved = chats.moveChat(slug: chat.slug,
                                         project: chat.project,
                                         toProject: targetProject)
        else { return }
        // Keep the open chat open at its new address.
        if wasOpen {
            appState.openChatSlug = moved.slug
            appState.openChatProject = moved.project
        }
    }

    private func deleteChat() {
        let wasOpen = isSelected
        chats.deleteChat(slug: chat.slug, project: chat.project)
        if wasOpen {
            appState.openChatSlug = nil
            appState.openChatProject = nil
        }
    }
}

// MARK: - Disclosure helper

/// Lightweight disclosure section header with smooth transitions.
/// Content renders at its natural height — overflow handling is the
/// sidebar container's job (see `LeftSidebar`), not this section's.
///
/// `accessory` is an optional trailing control on the header row — used by
/// the Claude Code section for its Group menu. It sits *outside* the
/// disclosure Button so clicking it doesn't also collapse the section.
/// Sections that don't need one use the `Accessory == EmptyView`
/// initializer below.
struct DisclosureSection<Content: View, Accessory: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content
    @Environment(\.sipFontScale) private var fontScale
    /// When the wrapper set a payload (LeftSidebar does, per section),
    /// the HEADER row doubles as the drag handle for reordering whole
    /// sections — the content keeps its own drag behaviours untouched.
    @Environment(\.sidebarSectionDragPayload) private var sectionDragPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            headerRow
                .padding(.trailing, 6)
                .sidebarRowBackground()
            if isExpanded {
                // The payload is the HEADER's; a nested DisclosureSection
                // in some future section body must not inherit it.
                content()
                    .environment(\.sidebarSectionDragPayload, nil)
            }
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        if let payload = sectionDragPayload {
            headerCore.onDrag { NSItemProvider(object: payload as NSString) }
        } else {
            headerCore
        }
    }

    private var headerCore: some View {
        HStack(spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: SipFont.sidebarHeader(fontScale), weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            accessory()
        }
    }
}

extension DisclosureSection where Accessory == EmptyView {
    init(title: String,
         isExpanded: Binding<Bool>,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title,
                  isExpanded: isExpanded,
                  accessory: { EmptyView() },
                  content: content)
    }
}
