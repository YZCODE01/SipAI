// SettingsView.swift
// Settings, one section at a time in the centre pane: chat models, the
// chat prompt and roles, the agent guide, files and notes, display,
// labels, language, updates, help. The way in (the menu over the
// sidebar's Settings row) and the list of sections the sidebar shows
// meanwhile are in SettingsNavigation.swift.

import SwiftUI
import AppKit

/// The Settings page: the section `AppState.settingsSection` names, in a
/// column centred in the centre pane with its content left-aligned
/// (`SettingsPageLayout`). ContentView's router puts it in place of the
/// chat, session or note — it replaces the pane rather than covering
/// it, see `ContentView.centerPane`.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    /// The sections in the order the menu and the sidebar list them —
    /// `allCases` IS that order. The chat's two sections come first: the
    /// system prompt and roles reach chat turns alone, never an agent
    /// session (Chat only included, which carries its own persona).
    enum Tab: String, CaseIterable, Identifiable {
        case models, prompt, agents, files, display, labels, language, updates, help
        var id: String { rawValue }

        /// `userInfo` key of `.openSettingsTab`, carrying a raw value.
        static let userInfoKey = "tab"

        var title: LocalizedStringKey {
            switch self {
            case .models:    return "Chat models"
            case .agents:    return "Agent Guide"
            case .prompt:    return "Chat Prompt and Roles"
            case .files:     return "Files & Notes"
            case .display:   return "Display"
            case .labels:    return "Labels"
            case .language:  return "Language"
            case .updates:   return "Updates"
            case .help:      return "Help"
            }
        }
    }

    /// The section on screen.
    let section: Tab
    /// A Help question to open on and scroll to — the composer's
    /// context-chip "?" is what passes one. Read once, when Help's pane
    /// is made.
    private let initialHelpTopic: HelpTopic?
    @Environment(\.sipFontScale) private var fontScale

    init(section: Tab, initialHelpTopic: HelpTopic? = nil) {
        self.section = section
        self.initialHelpTopic = initialHelpTopic
    }

    var body: some View {
        VStack(spacing: 0) {
            // The agent session's band under the top bar, so a section's
            // first line sits where a transcript's first row does, and
            // scrolled content leaves at the same line.
            Spacer().frame(height: SipDesign.pageTopBand)
            GeometryReader { geo in
                let layout = SettingsPageLayout(viewport: geo.size.width,
                                                ratio: SipFont.ratio(fontScale))
                // The reader exists for the Help deep link alone: a question
                // opened from elsewhere in the app is scrolled into view by
                // its card id. Safe here because the column is a plain
                // `VStack` — the offset an id resolves to is exact, not a
                // lazy stack's estimate.
                ScrollViewReader { proxy in
                    // Sideways only when the column cannot fit the pane at its
                    // narrowest; everywhere else a vertical page, like every
                    // other page in the window.
                    ScrollView(layout.scrollsHorizontally ? [.vertical, .horizontal] : .vertical) {
                        VStack(alignment: .leading, spacing: 16) {
                            pane(proxy)
                        }
                        // The column: a fixed width, its content on the left,
                        // centred by padding the rule splits into whole points.
                        .frame(width: layout.columnWidth, alignment: .leading)
                        .padding(.leading, layout.leading)
                        .padding(.trailing, layout.trailing)
                        // The transcript's inset above the first line, inside
                        // the band; below the last line, band and inset both,
                        // so a page scrolled to its end stops as far above the
                        // window's bottom edge as it starts below the bar.
                        .padding(.top, SipDesign.pageContentInset)
                        .padding(.bottom, SipDesign.pageTopBand + SipDesign.pageContentInset)
                        // Pinned to the top-left of the pane. A scroll view
                        // that scrolls both ways CENTRES content smaller than
                        // itself, so without the minimum height a short
                        // section on a narrow window would float halfway
                        // down the page.
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height,
                               alignment: .topLeading)
                        // System controls take no arbitrary point size, so
                        // beside the scaled labels they STEP — once, here, for
                        // every pane (`SipFont.controlSize`).
                        .controlSize(SipFont.controlSize(fontScale))
                    }
                }
            }
        }
        // Each section opens at its top, not at the offset the previous
        // one was scrolled to.
        .id(section)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func pane(_ proxy: ScrollViewProxy) -> some View {
        switch section {
        case .models:    ModelsPane(switchTab: { appState.settingsSection = $0 })
        case .agents:    AgentGuidePane()
        case .prompt:    PromptAndRolesPane()
        case .files:     FilesPane()
        case .display:   DisplayPane()
        case .labels:    LabelsPane()
        case .language:  LanguagePane()
        case .updates:   UpdatesPane()
        case .help:
            HelpPane(initialTopic: initialHelpTopic) { id in
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
        }
    }
}

// MARK: - Panes

struct ModelsPane: View {
    @EnvironmentObject var config: ConfigManager
    @State private var addHovered = false
    /// The "Agent Guide" link in the explanation switches Settings to
    /// that section; the page hands the setter in.
    var switchTab: (SettingsView.Tab) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            aboutChats

            Text("Chat models", comment: "Settings pane header").sipFont(14, weight: .semibold)
            ForEach(config.models) { m in
                ModelSettingsRow(model: m)
            }

            Divider()
            // One button, same workflow as the composer's "Add Model":
            // the provider → API key → pick-models setup sheet — and the
            // SAME sheet, ContentView's, reached the way the composer
            // reaches it. A sheet of this pane's own would hang off the
            // main window too, unreported to the update announcer and
            // untinted by the app's theme; ContentView's is both.
            HStack {
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .openModelSetup, object: nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .sipFont(13)
                            .foregroundColor(SipDesign.blue)
                        Text("Add Model", comment: "Settings: open the model setup window")
                            .sipFont(14, weight: .medium)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(addHovered ? Color.gray.opacity(0.2) : Color.gray.opacity(0.08))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { addHovered = $0 }
            }
        }
    }

    /// What a chat is, above the list — the page the chat page's "Learn
    /// more" opens. Two literals with no interpolation (no agent label
    /// in either), the second carrying the link to the Agent Guide.
    private var aboutChats: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About chats", comment: "Settings → Chat models: header of the explanation above the model list")
                .sipFont(14, weight: .semibold)
            Text("A chat sends your message straight to the model provider's API and shows the reply — no server in between, no SipAI account. Each provider bills its own API key per token.",
                 comment: "Settings → Chat models: explanation, first paragraph")
                .sipFont(12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.subscriptionParagraph)
                .sipFont(12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "sipai" else { return .systemAction }
                    if url.host == "settings",
                       let tab = SettingsView.Tab(rawValue: url.lastPathComponent) {
                        switchTab(tab)
                    }
                    return .handled
                })
            Divider().opacity(0.3).padding(.vertical, 2)
        }
    }

    /// The way out for someone who has a subscription and no API key,
    /// with its link styled as a link: blue, underlined. The link is
    /// handled above, in-app — it switches Settings to the Agent Guide
    /// rather than leaving for a browser.
    private static var subscriptionParagraph: AttributedString {
        var text = AttributedString(localized: "If you would rather use a subscription plan for your conversations, use the **Chat only** mode of a SipAI agent session instead. See [Agent Guide](sipai://settings/agents) for the details.",
                                    comment: "Settings → Chat models: explanation, second paragraph. Keep the [Agent Guide](sipai://settings/agents) link and the **Chat only** mode name (the mode chip's row).")
        for run in text.runs where run.link != nil {
            text[run.range].underlineStyle = .single
            text[run.range].foregroundColor = SipDesign.blue
        }
        return text
    }
}

/// One configured-model row in the Models pane. Extracted so each row
/// carries its own hover state for the Set Default / delete buttons.
private struct ModelSettingsRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var config: ConfigManager
    let model: ModelConfig

    @State private var setDefaultHovered = false
    @State private var deleteHovered = false
    @State private var confirmingDelete = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).sipFont(14, weight: .medium)
                // String expression (verbatim): model ids like
                // meta-llama/Llama-3.1_8B carry markdown-active chars.
                Text(model.providerKey + " · " + model.id)
                    .sipFont(13).foregroundStyle(.secondary)
            }
            Spacer()
            if config.defaultModel == model.id {
                Text("Default", comment: "Tag shown next to the default model")
                    .sipFont(12, weight: .semibold)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(4)
            } else {
                Button {
                    let previousDefault = config.defaultModel
                    config.setDefaultModel(model.id)
                    // Same bookkeeping as ModelRowActionsMenu: the composer
                    // label follows the default unless the user explicitly
                    // switched to another model.
                    if appState.activeModel == nil || appState.activeModel == previousDefault {
                        appState.activeModel = model.id
                    }
                } label: {
                    Text("Set Default", comment: "Set this model as the default")
                        .sipFont(13, weight: .medium)
                        .foregroundColor(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(setDefaultHovered ? Color.gray.opacity(0.2) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { setDefaultHovered = $0 }
            }
            Button {
                confirmingDelete = true
            } label: {
                Image(systemName: "trash")
                    .sipFont(13)
                    .foregroundColor(deleteHovered ? .red : .secondary)
                    .padding(5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(deleteHovered ? Color.red.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { deleteHovered = $0 }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
        .alert(
            String(localized: "Delete \(model.name)?",
                   comment: "Title of the model delete confirmation, names the model"),
            isPresented: $confirmingDelete
        ) {
            Button(role: .destructive) {
                config.removeModel(id: model.id)
                if appState.activeModel == model.id {
                    appState.activeModel = config.defaultModel
                }
            } label: {
                Text("Delete", comment: "Confirm deleting the model")
            }
            Button(role: .cancel) { } label: {
                Text("Cancel", comment: "Dismiss the model delete confirmation")
            }
        }
    }
}

struct PromptAndRolesPane: View {
    @EnvironmentObject var config: ConfigManager
    @Environment(\.sipFontScale) private var fontScale
    @State private var text: String = ""
    @State private var editing: [EditableRole] = []

    /// Draft row with its own stable identity. Index-keyed iteration
    /// (`ForEach(editing.indices, id: \.self)`) would crash on deleting
    /// an unsaved row: the text-field bindings of every later row still
    /// point at the old indices. RoleConfig's own id is its name, which
    /// is no better (two fresh "New Role" rows would collide), hence
    /// the UUID.
    struct EditableRole: Identifiable {
        let id = UUID()
        var name: String
        var prompt: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("System Prompt", comment: "Settings: system prompt section header").sipFont(14, weight: .semibold)
            Text("Used as the default instructions when no project- or role-specific prompt is set.",
                 comment: "System prompt help text")
                .sipFont(13).foregroundStyle(.secondary)
            // About ten lines; a longer prompt scrolls inside the box.
            promptEditor($text, height: 176, monospaced: true)
            HStack {
                Spacer()
                SettingsProminentButton(title: String(localized: "Save", comment: "Save system prompt")) {
                    config.saveGeneralSystemPrompt(text)
                }
            }

            Divider().padding(.vertical, 6)

            Text("Roles", comment: "Settings: roles section header").sipFont(14, weight: .semibold)
            Text("Each role is a reusable system prompt you can switch to in chat.",
                 comment: "Roles help text")
                .sipFont(13).foregroundStyle(.secondary)
            ForEach($editing) { $role in
                VStack(alignment: .leading, spacing: 4) {
                    TextField("", text: $role.name).sipFont(14, weight: .medium)
                    promptEditor($role.prompt, height: 80, monospaced: false)
                    HStack {
                        Spacer()
                        SettingsTrashButton {
                            editing.removeAll { $0.id == role.id }
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.05)))
            }
            HStack {
                SettingsTextButton(title: String(localized: "Add Role", comment: "Add a new role button")) {
                    editing.append(EditableRole(name: String(localized: "New Role", comment: "Default name for a freshly added role"), prompt: ""))
                }
                Spacer()
                SettingsProminentButton(title: String(localized: "Save", comment: "Save roles")) {
                    config.setRoles(committedRoles())
                }
            }
        }
        .onAppear {
            text = config.loadGeneralSystemPrompt()
            editing = config.roles.map { EditableRole(name: $0.name, prompt: $0.prompt) }
        }
    }

    /// Drafts → the roles actually saved. `RoleConfig.id` IS the name, so
    /// the committed list must contain no blanks and no duplicates (they
    /// become duplicate ForEach ids downstream): names are trimmed, rows
    /// whose trimmed name is empty are dropped, and duplicates get a
    /// " 2", " 3", … suffix. Applied only at commit time — the UUID-keyed
    /// drafts stay exactly as typed.
    private func committedRoles() -> [RoleConfig] {
        var seen = Set<String>()
        var result: [RoleConfig] = []
        for role in editing {
            let trimmed = role.name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            var name = trimmed
            var counter = 2
            while seen.contains(name) {
                name = "\(trimmed) \(counter)"
                counter += 1
            }
            seen.insert(name)
            result.append(RoleConfig(name: name, prompt: role.prompt))
        }
        return result
    }

    /// TextEditor with a normal text-field look. `scrollContentBackground`
    /// hides the NSTextView's own opaque background (near-black in dark
    /// mode) so the standard surface + hairline border show instead.
    ///
    /// `height` is the editor's height at the Default tier, and it is a
    /// fixed height, never a minimum: a flexible editor takes a share of
    /// whatever height the page has left over, which on a tall window is
    /// a box hundreds of points tall around an empty prompt. Scaled with
    /// the tier, like every frame that bounds design-size text, so the box
    /// holds the same number of lines at every font size.
    private func promptEditor(_ binding: Binding<String>,
                              height: CGFloat,
                              monospaced: Bool) -> some View {
        TextEditor(text: binding)
            .sipFont(14, design: monospaced ? .monospaced : .default)
            .scrollContentBackground(.hidden)
            .frame(height: (height * SipFont.ratio(fontScale)).rounded())
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(SipDesign.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(SipDesign.borderLight, lineWidth: 1)
            )
    }
}

struct FilesPane: View {
    @EnvironmentObject var config: ConfigManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files & Notes", comment: "Settings pane header").sipFont(14, weight: .semibold)

            HStack {
                Text("Dedicated folder", comment: "Settings: the folder the sidebar's Local Files section browses")
                    .sipFont(14)
                Spacer()
                Text(config.dedicatedFolder ?? String(localized: "Not set", comment: "When dedicated folder is unset"))
                    .sipFont(13)
                    .foregroundStyle(.secondary)
                SettingsTextButton(title: String(localized: "Choose…", comment: "Pick a dedicated folder")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        config.setDedicatedFolder(url.path)
                    }
                }
            }

            HStack {
                Text("Note generating model", comment: "Settings: model used to summarize chats/sessions into notes")
                    .sipFont(14)
                Spacer()
                Picker("", selection: Binding(
                    get: { config.noteGeneratingModel ?? "" },
                    set: { config.setNoteModel($0.isEmpty ? nil : $0) }
                )) {
                    if config.models.isEmpty {
                        Text("No models configured",
                             comment: "Note model picker when nothing is configured")
                            .tag("")
                    }
                    ForEach(config.models) { m in
                        Text(m.name).tag(m.id)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                .sipFont(14)
            }
            Text("Notes are written by this model. Thinking-heavy models can produce richer notes but may take noticeably longer to finish.",
                 comment: "Settings: hint under the note model picker")
                .sipFont(12)
                .foregroundStyle(.secondary)
        }
    }
}

struct DisplayPane: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var config: ConfigManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance", comment: "Settings: appearance section header")
                .sipFont(14, weight: .semibold)
            Picker("", selection: Binding(
                get: { appState.theme },
                set: { t in
                    // AppState drives `.preferredColorScheme` live; the
                    // config write makes the choice survive relaunch
                    // (seeded back in SipAIApp.onAppear).
                    appState.theme = t
                    config.setTheme(t)
                }
            )) {
                ForEach(AppTheme.allCases) { t in
                    Text(t.localizedName).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420, alignment: .leading)
            Text("System follows the macOS appearance; Light and Dark lock the app to one look.",
                 comment: "Settings: appearance help text")
                .sipFont(12)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Text("Font Size", comment: "Settings: font size section header")
                .sipFont(14, weight: .semibold)
            Picker("", selection: Binding(
                get: { config.fontTier },
                set: { t in config.setDisplay { $0.fontTier = t.rawValue } }
            )) {
                ForEach(FontTier.allCases) { t in
                    Text(t.localizedName).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420, alignment: .leading)
            Text("Applies to the sidebar, the conversation, the text box and its controls, notes, and Settings. Bigger tiers also widen line spacing; Large text mode doubles it.",
                 comment: "Settings: font size help text")
                .sipFont(12)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Text("Sidebar", comment: "Settings: header of the sidebar display toggles")
                .sipFont(14, weight: .semibold)

            // A row of its own: a switch with a sentence under it, not one
            // of a group's per-surface switches, so it takes neither their
            // indent nor their smaller, dimmer label. The logo and app name
            // it takes the place of are always there — hiding them is not
            // offered, or the messages would have nowhere to show.
            toggle("Show update messages", value: \.showUpdateMessages)
            Text("When SipAI or an agent tool is updated, a short message takes the app name's place for five seconds.",
                 comment: "Settings: help text under the update-messages toggle")
                .sipFont(12)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Text("Chatbox display", comment: "Settings: header of the chat display toggles")
                .sipFont(14, weight: .semibold)

            // One toggle, not a Chat/Agent pair: chat sessions carry no
            // context chip at all, so a "Chat" sub-toggle would be a
            // switch with nothing behind it. The config key stays
            // `token_agent` — the CLI reads the same file, and renaming
            // a shared key to match a label would switch the feature
            // off on that side.
            toggle("Show context usage", value: \.showTokenAgent)

            Text("Show note button", comment: "Settings: note button group label (no toggle of its own)")
                .sipFont(14)
            subToggle("Chat", value: \.showNoteChat)
            subToggle("Agent", value: \.showNoteAgent)
            subToggle("Show note prompt", value: \.showNotePrompt)
            Text("With note prompt on, the note button asks: generate directly, or add instructions first.",
                 comment: "Settings: note prompt help text")
                .sipFont(12)
                .foregroundStyle(.secondary)
                .padding(.leading, 16)

            toggle("Show chat group name", value: \.showProjectName)
            toggle("Show role line", value: \.showRole)

            Divider().padding(.vertical, 4)

            Text("Typo check", comment: "Settings: spell-checking section header")
                .sipFont(14, weight: .semibold)

            toggle("Check spelling while typing", value: \.spellCheck)
            Text("Underlines words the macOS dictionary doesn't know, in the chat and agent input boxes, the message editor and the note editor. Nothing is ever corrected for you.",
                 comment: "Settings: spell check help text")
                .sipFont(12)
                .foregroundStyle(.secondary)
        }
    }

    private func toggle(_ key: LocalizedStringKey, value: WritableKeyPath<DisplaySettings, Bool>) -> some View {
        HStack {
            Text(key)
                .sipFont(14)
            Spacer()
            Toggle("", isOn: Binding(
                get: { config.display[keyPath: value] },
                set: { v in config.setDisplay { $0[keyPath: value] = v } }
            ))
            .labelsHidden()
        }
    }

    /// Indented child row under a group label — the per-surface switches.
    private func subToggle(_ key: LocalizedStringKey, value: WritableKeyPath<DisplaySettings, Bool>) -> some View {
        HStack {
            Text(key)
                .sipFont(13)
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("", isOn: Binding(
                get: { config.display[keyPath: value] },
                set: { v in config.setDisplay { $0[keyPath: value] = v } }
            ))
            .labelsHidden()
        }
        .padding(.leading, 16)
    }
}

/// "Labels" settings pane — renames the user/AI labels and the label of
/// every available agent. Contract in CLAUDE.md, "Editing a label".
struct LabelsPane: View {
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var agents: AgentManager
    @Environment(\.sipFontScale) private var fontScale

    private enum LabelField: Hashable {
        case user
        case ai
        case agent(String)
    }

    private struct LabelRow: Identifiable {
        let field: LabelField
        let title: String
        let value: String
        let fallback: String
        var id: LabelField { field }
    }

    @State private var editingField: LabelField? = nil
    @State private var draft: String = ""
    @State private var storedValue: String = ""
    @State private var saveHovered = false
    @FocusState private var focusedField: LabelField?

    /// One label row per agent this Mac has (an installed CLI, hidden
    /// or not) — not the whole registry, so users don't see rows for
    /// agents this machine has never had.
    private var labelableAgents: [AgentInfo] { agents.installedAgents }

    private var hasChanges: Bool { draft != storedValue }

    private var rows: [LabelRow] {
        var result: [LabelRow] = [
            LabelRow(field: .user,
                     title: String(localized: "User label",
                                   comment: "Settings: user message label"),
                     value: config.display.userLabel,
                     fallback: DisplaySettings.defaultUserLabel),
            LabelRow(field: .ai,
                     title: String(localized: "AI label",
                                   comment: "Settings: AI message label"),
                     value: config.display.aiLabel,
                     fallback: DisplaySettings.defaultAILabel)
        ]
        for agent in labelableAgents {
            result.append(
                LabelRow(field: .agent(agent.key),
                         title: String(localized: "\(agent.name) label",
                                       comment: "Settings: label shown above an agent's messages, e.g. 'Claude Code label'"),
                         value: config.agentLabel(for: agent.key, defaultName: agent.name),
                         fallback: agent.name))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Labels", comment: "Settings pane header for label customisation")
                .sipFont(14, weight: .semibold)

            ForEach(rows) { row in
                labelRow(row)
            }

            HStack {
                Spacer()
                SettingsTextButton(title: String(localized: "Reset to defaults",
                                                 comment: "Labels pane reset button")) {
                    resetAll()
                }
            }
        }
        .onChange(of: focusedField) { previous, current in
            guard current == nil, previous != nil,
                  previous == editingField, !saveHovered else { return }
            cancelEdit()
        }
        .onDisappear(perform: cancelEdit)
    }

    @ViewBuilder
    private func labelRow(_ row: LabelRow) -> some View {
        HStack(spacing: 8) {
            Text(row.title)
                .sipFont(14)
                .lineLimit(1)
            Spacer(minLength: 8)
            if editingField == row.field {
                editingControls(row)
            } else {
                Text(verbatim: row.value)
                    .sipFont(14)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                SettingsTextButton(title: String(localized: "Edit",
                                                 comment: "Labels pane: start editing one label")) {
                    beginEdit(row)
                }
            }
        }
        // Fixed WITHIN a tier — entering or leaving edit mode reflows
        // nothing — and scaled BETWEEN tiers, or a larger tier clips
        // the field.
        .frame(height: 30 * SipFont.ratio(fontScale))
    }

    @ViewBuilder
    private func editingControls(_ row: LabelRow) -> some View {
        TextField(row.fallback, text: $draft)
            .sipFont(14)
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)
            .focused($focusedField, equals: row.field)
            .onSubmit { save(row) }
            .onExitCommand(perform: cancelEdit)
            .onAppear { focusedField = row.field }
            .onChange(of: focusedField) { _, current in
                if current == row.field { FocusedFieldSelection.selectAll() }
            }
            .onChange(of: draft) { _, new in
                if new.count > DisplaySettings.labelCharLimit {
                    draft = String(new.prefix(DisplaySettings.labelCharLimit))
                }
            }
            .editFieldClickAway {
                guard !saveHovered else { return }
                cancelEdit()
            }

        Text(verbatim: "\(draft.count)/\(DisplaySettings.labelCharLimit)")
            .monospacedDigit()
            .sipFont(11)
            .foregroundColor(SipDesign.textHint)

        SettingsProminentButton(title: String(localized: "Save",
                                              comment: "Generic save button")) {
            save(row)
        }
        .opacity(hasChanges ? 1 : 0)
        .allowsHitTesting(hasChanges)
        .accessibilityHidden(!hasChanges)
        .onHover { saveHovered = hasChanges && $0 }
        .animation(.easeInOut(duration: 0.12), value: hasChanges)
    }

    private func beginEdit(_ row: LabelRow) {
        saveHovered = false
        storedValue = row.value
        draft = String(row.value.prefix(DisplaySettings.labelCharLimit))
        editingField = row.field
    }

    private func cancelEdit() {
        guard editingField != nil else { return }
        editingField = nil
        focusedField = nil
        saveHovered = false
        draft = ""
        storedValue = ""
    }

    private func save(_ row: LabelRow) {
        guard editingField == row.field else { return }
        guard hasChanges else { cancelEdit(); return }
        let text = String(draft.prefix(DisplaySettings.labelCharLimit))
            .trimmingCharacters(in: .whitespaces)
        switch row.field {
        case .user:
            config.setDisplay { $0.userLabel = text.isEmpty ? row.fallback : text }
        case .ai:
            config.setDisplay { $0.aiLabel = text.isEmpty ? row.fallback : text }
        case .agent(let key):
            config.setAgentLabel(text, for: key)
        }
        cancelEdit()
    }

    private func resetAll() {
        cancelEdit()
        config.setDisplay { s in
            s.userLabel = DisplaySettings.defaultUserLabel
            s.aiLabel = DisplaySettings.defaultAILabel
        }
        for agent in labelableAgents {
            config.setAgentLabel("", for: agent.key)
        }
    }
}

/// "Help" settings pane — an expandable FAQ. Click a question to unfold
/// its answer. Content covers what SipAI users actually run into: API
/// keys, failing requests, usage tracking, agent CLIs, storage, and
/// customization. `UsageLog` keeps recording quietly.
struct HelpPane: View {
    @EnvironmentObject var config: ConfigManager
    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.sipLineSpacingFactor) private var lineSpacingFactor
    @State private var expanded: Set<Int>
    /// The question a deep link asked for, scrolled to once the cards
    /// have laid out. nil for an ordinary visit.
    private let initialTopic: HelpTopic?
    /// Hands a card id to the enclosing `ScrollViewReader`.
    private let scrollTo: (Int) -> Void

    /// A deep-linked question opens EXPANDED from the first pass — the
    /// scroll that follows needs the card at its opened height, and
    /// animating the fold on arrival would move the target under the
    /// reader.
    init(initialTopic: HelpTopic? = nil, scrollTo: @escaping (Int) -> Void = { _ in }) {
        self.initialTopic = initialTopic
        self.scrollTo = scrollTo
        _expanded = State(initialValue: initialTopic.map { [$0.faqId] } ?? [])
    }

    private struct FAQ: Identifiable {
        let id: Int
        let question: String
        let body: FAQBody
    }

    /// What a question unfolds into: a paragraph, or one of the few
    /// cards that carry controls of their own.
    private enum FAQBody {
        case text(String)
        case codexContextWindow
    }

    var body: some View {
        VStack(alignment: .leading,
               spacing: 12 * HelpRhythm.vertical(fontScale, lineSpacingFactor)) {
            Text("Questions?", comment: "Help pane header")
                .sipFont(14, weight: .semibold)
            Text("Click a question to see the answer.",
                 comment: "Help pane help text")
                .sipFont(13)
                .foregroundStyle(.secondary)

            ForEach(items) { item in
                FAQCard(question: item.question,
                        isOpen: expanded.contains(item.id),
                        toggle: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if expanded.contains(item.id) {
                            expanded.remove(item.id)
                        } else {
                            expanded.insert(item.id)
                        }
                    }
                }) {
                    switch item.body {
                    case .text(let answer):
                        FAQAnswer(text: answer)
                    case .codexContextWindow:
                        CodexContextWindowCard()
                    }
                }
                .id(item.id)
            }
        }
        // The tier's line spacing, once, for every wrapped line in the
        // section — an answer, a question that wraps, the Codex card.
        .lineSpacing(HelpRhythm.lineSpacing(fontScale, lineSpacingFactor))
        .onAppear {
            guard let topic = initialTopic else { return }
            // One run-loop turn later: the cards have to exist in the
            // scroll view before an id can be scrolled to. And once
            // more after the page has settled — a scroll issued while
            // the window is still laying the page out (the sidebar
            // sliding back in, say) can land on the geometry before
            // it. Repeating a scroll to the same anchor moves nothing
            // when the first one held.
            DispatchQueue.main.async { scrollTo(topic.faqId) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { scrollTo(topic.faqId) }
        }
    }

    /// The agent name the way Settings → Labels spells it — no
    /// user-visible sentence names an agent outright.
    private var codexLabel: String { agentLabel("codex") }
    private var claudeLabel: String { agentLabel("claude_code") }
    private var kimiLabel: String { agentLabel("kimi") }

    private func agentLabel(_ key: String) -> String {
        config.agentLabel(for: key,
                          defaultName: AgentManager.registry
                              .first { $0.key == key }?.name ?? key)
    }

    private var items: [FAQ] {
        [
            FAQ(id: 1,
                question: String(localized: "How do I get an API key?",
                                 comment: "FAQ question"),
                body: .text(String(localized: """
Each provider issues keys from its own dashboard. For examples, OpenAI at platform.openai.com/api-keys, Anthropic at console.anthropic.com, Google (Gemini) at aistudio.google.com, DeepSeek at platform.deepseek.com, Alibaba Qwen in the DashScope console, xAI at console.x.ai. You may need to register for their accounts and create a key there, then in SipAI click Add Model (in the chat composer or Settings → Chat models), pick the provider, and paste the key when asked. Some providers issue region-bound keys (e.g. Qwen, Kimi): pick the region that matches where the key was created.
""", comment: "FAQ answer: getting an API key"))),
            FAQ(id: 2,
                question: String(localized: "I added a key but requests fail — what should I check?",
                                 comment: "FAQ question"),
                body: .text(String(localized: """
Open Add Model and pick the provider again — Continue re-validates the stored key by fetching its model list, and the error it shows names the actual cause. The usual suspects: the key belongs to a different region (Qwen, Kimi — switch region on the key step), the account has no credit, or the model ID no longer exists. If you entered an environment variable name instead of a key, note that apps launched from the Dock don't see shell exports — paste the key itself, or launch SipAI from a terminal.
""", comment: "FAQ answer: debugging failing requests"))),
            FAQ(id: 3,
                question: String(localized: "How can I track my token usage and cost?",
                                 comment: "FAQ question"),
                body: .text(String(localized: """
Each provider has their dashboard to help users track their API credit usage. Please check your account dashboard for more information. SipAI also shows how full each agent session's context window is, in the chip under the composer. Plan limits (the 5-hour and weekly windows of a subscription) are a different thing — see the next question.
""", comment: "FAQ answer: tracking usage"))),
            // Placed with the usage questions; its id is
            // `HelpTopic.codexContextWindow.faqId`, the one number the
            // composer's "?" deep-links to.
            FAQ(id: HelpTopic.codexContextWindow.faqId,
                question: String(localized: "Why does \(codexLabel) show a 258k context window, and how do I get the larger one?",
                                 comment: "FAQ question; placeholder is the Codex label"),
                body: .codexContextWindow),
            FAQ(id: 4,
                question: String(localized: "Can SipAI show how much of my provider plan is used?",
                                 comment: "FAQ question"),
                body: .text(String(localized: """
Yes — click the T icon beside the search icon in the toolbar. It appears when at least one of your agent tools is signed in to a plan (a Claude subscription, a ChatGPT plan for Codex, or a Kimi Code membership), and it shows what each plan reports: the current 5-hour session and weekly windows for Claude Code, the weekly and per-model limits for Codex, and the weekly quota and 5-hour window for Kimi Code. The numbers are fetched when you open the window and are as fresh as the time shown at the bottom; click the refresh arrow for a new reading. Each figure comes from the tool's own account query, run on your Mac by the tool itself: Claude Code answers its /usage command, Codex answers over its app server, and Kimi Code answers over its local server. No tokens are spent, SipAI never sees a login token, and nothing is stored or sent anywhere. If every agent runs on an API key there is nothing to show and the icon stays hidden; API usage and cost live on each provider's developer platform.
""", comment: "FAQ answer: plan consumption"))),
            // Its id is `HelpTopic.chatOnly.faqId`, the one number a
            // deep link to this card would use.
            FAQ(id: HelpTopic.chatOnly.faqId,
                question: String(localized: "What is Chat only?",
                                 comment: "FAQ question about the composer's Chat only mode row"),
                body: .text(String(localized: """
Chat only is a row in an agent session's mode chip. A turn sent under it carries none of the agent's file or command tools and no MCP servers — except that \(codexLabel) keeps any you added to its own config — so the agent can't read, search or change files or run commands, but, like a chat app, it can still look things up on the web when a question needs current information. It answers in the same session, and the next turn in any other row continues the conversation with the tools back. It draws on whatever the tool is signed in to: \(claudeLabel) uses your Claude plan, \(codexLabel) uses your Codex limits (a ChatGPT plan's Codex allowance, not its chat allowance), \(kimiLabel) uses your Kimi Code membership — and a tool signed in with an API key bills that key. A short exchange costs far less than a full agent turn, and switching rows re-caches the conversation once. To share a file, attach it with the + or drop it on the box: text files and PDF text travel inside the message, and an image goes to the model as an image (on \(kimiLabel), only in a new session's first message). On a new \(kimiLabel) session the first Chat only message arrives all at once; later ones stream. \(kimiLabel) searches the web only when it has a search provider, which a Kimi Code membership login provides; with an API key alone it can open a page but not search.
""", comment: "FAQ answer: the Chat only mode; placeholders are the three agent labels"))),
            FAQ(id: 5,
                question: String(localized: "What's the difference between a chat and an agent session?",
                                 comment: "FAQ question"),
                body: .text(String(localized: """
Chats talk directly to a model over your API key — pure conversation, billed per token. Agent sessions run the provider's CLI (e.g. Claude Code, Codex) on your Mac: the agent can read and edit files and run commands, and billing follows the CLI's own login or plan. Chats are stored by this app; agent sessions are the CLIs (or Apps)' own files, which SipAI reads and follows live.
""", comment: "FAQ answer: chats vs agent sessions"))),
            FAQ(id: 6,
                question: String(localized: "How do I set up the Claude Code or other AI agent providers?",
                                 comment: "FAQ question"),
                body: .text(String(localized: """
Open Settings → Agent Guide. Install runs the provider's own installer, Sign In opens the provider's sign-in page (a subscription) or takes an API key, and the provider appears in the sidebar once both are done. Installing or signing in from Terminal works the same way; SipAI notices within a few seconds. Only providers that are installed and signed in are listed — the sidebar's ADD AGENTS row opens the same page.
""", comment: "FAQ answer: agent CLI setup"))),
            FAQ(id: 7,
                question: String(localized: "Where is my data stored? Does anything leave my Mac?",
                                 comment: "FAQ question"),
                body: .text(String(localized: """
SipAI is completely a local tool. Chats, notes, roles, and settings live in ~/Library/Application Support/SipAI, and API keys stay in that folder's config.json on your disk. Messages are sent only to the provider of the model you picked — there is no server in between. Agent sessions are stored by the CLIs themselves, under ~/.claude, ~/.codex and ~/.kimi-code. Besides that, SipAI only checks for updates — for itself once a day, and for the agent tools every eight hours — sending nothing about you, and both checks can be turned off in Settings → Updates.
""", comment: "FAQ answer: data storage and privacy"))),
            FAQ(id: 8,
                question: String(localized: "What do the system prompt and roles do?",
                                 comment: "FAQ question"),
                body: .text(String(localized: """
The system prompt (Settings → Chat Prompt and Roles) is the standing instruction sent with every chat message. Roles are named prompts you can switch between, so the same chat window can answer as a code reviewer, translator, or tutor. One starter role ships with the app as a worked example — edit it, delete it, or add your own.
""", comment: "FAQ answer: system prompt and roles"))),
            FAQ(id: 9,
                question: String(localized: "How do I organize, rename, or export things?",
                                 comment: "FAQ question"),
                body: .text(String(localized: """
Hover any sidebar row and click ⋮ — chats can be renamed, moved into projects, or deleted; notes can be renamed, downloaded as markdown, or deleted; agent sessions can be renamed too. Settings → Files & Notes also lets you pick a dedicated folder: the sidebar browses it, so chats and notes the SipAI command-line tool saves there appear alongside the app's own.
""", comment: "FAQ answer: organizing and renaming"))),
            FAQ(id: 10,
                question: String(localized: "macOS keeps asking to let SipAI use a folder — is that normal?",
                                 comment: "FAQ question"),
                body: .text(String(localized: """
Being asked once per folder is normal. Agent sessions read and edit files in your working folder, so the first time SipAI opens a project inside Desktop, Documents, Downloads, iCloud Drive, or an external drive, macOS asks permission. Click Allow and the answer is remembered — including after you restart. You can review or change it any time in System Settings → Privacy & Security → Files and Folders. Scheduled tasks run inside SipAI, so they reuse the same permission instead of asking again.
""", comment: "FAQ answer: folder access permission prompts"))),
        ]
    }
}

/// A question in the Help pane that other parts of the app can open
/// directly. The composer's context-chip "?" is the one caller today.
/// `faqId` is the card's id in `HelpPane.items` — kept here so the
/// deep link and the card cannot disagree about which question it is.
enum HelpTopic: String {
    case codexContextWindow
    /// The composer's Chat only row — what it is, which pool each
    /// agent draws on, attachments, the switch, kimi's first turn.
    case chatOnly

    var faqId: Int {
        switch self {
        case .codexContextWindow: return 11
        case .chatOnly: return 12
        }
    }

    /// The `userInfo` key `.openHelpTopic` carries the raw value under.
    static let userInfoKey = "topic"

    /// Ask ContentView to open Settings → Help on this question.
    func open() {
        NotificationCenter.default.post(name: .openHelpTopic, object: nil,
                                        userInfo: [Self.userInfoKey: rawValue])
    }
}

extension Notification.Name {
    /// Opens Settings on Help with one question expanded and scrolled
    /// to. `userInfo[HelpTopic.userInfoKey]` names it. Posted by
    /// `HelpTopic.open()`, received by ContentView, which holds the
    /// question until the Help page is made.
    static let openHelpTopic = Notification.Name("openHelpTopic")
    /// Opens Settings on a section. `userInfo[SettingsView.Tab
    /// .userInfoKey]` carries the section's raw value. Posted by the chat
    /// page's "Learn more" and the sidebar's ADD AGENTS row.
    static let openSettingsTab = Notification.Name("openSettingsTab")
}

/// The Help section's rhythm at the font tier. Its prose is 13 pt at
/// Default, so every wrapped line takes that size's tier line spacing
/// and every VERTICAL gap follows its line pitch — the scheduled-task
/// page's rule, and for its reason: a gap that grows only with the type
/// falls behind the line spacing, which grows faster, until a wrapped
/// line sits farther from its own paragraph than the next card does.
/// Horizontal gaps and frames follow the type (`SipFont.ratio`).
private enum HelpRhythm {
    static let bodySize: CGFloat = 13

    static func lineSpacing(_ fontScale: CGFloat, _ lineSpacingFactor: CGFloat) -> CGFloat {
        SipFont.lineSpacing(bodySize, fontScale: fontScale, lineSpacingFactor: lineSpacingFactor)
    }

    static func vertical(_ fontScale: CGFloat, _ lineSpacingFactor: CGFloat) -> CGFloat {
        SipFont.gapScale(bodySize, fontScale: fontScale, lineSpacingFactor: lineSpacingFactor)
    }
}

/// One paragraph of an answer. It sets no line spacing of its own: the
/// pane sets the tier's once, at its root, and a number set here would
/// override it.
private struct FAQAnswer: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .sipFont(HelpRhythm.bodySize)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// One expandable question card in the Help pane. The answer is
/// whatever the caller builds — a paragraph for most questions, a card
/// with controls for the few that have something to DO.
private struct FAQCard<Answer: View>: View {
    let question: String
    let isOpen: Bool
    let toggle: () -> Void
    @ViewBuilder let answer: () -> Answer

    @State private var hovered = false
    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.sipLineSpacingFactor) private var lineSpacingFactor
    private var ratio: CGFloat { SipFont.ratio(fontScale) }
    private var rhythm: CGFloat { HelpRhythm.vertical(fontScale, lineSpacingFactor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8 * ratio) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .sipFont(10, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 12 * ratio)
                    Text(question)
                        .sipFont(13, weight: .medium)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12 * ratio)
                .padding(.vertical, 10 * rhythm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                // Under the question's text: the row's pad, the chevron's
                // column and the gap after it.
                answer()
                    .padding(.leading, (12 + 12 + 8) * ratio)
                    .padding(.trailing, 12 * ratio)
                    .padding(.bottom, 12 * rhythm)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8 * ratio)
                .fill(hovered ? Color.gray.opacity(0.14) : Color.gray.opacity(0.08))
        )
        .onHover { hovered = $0 }
    }
}

/// The Help card behind the composer's context-chip "?" on a codex
/// session: why the chip divides by 258k on a model OpenAI advertises
/// at 1.05M, which models allow more, and a switch that changes it.
///
/// Every number is read from codex's own catalog and config through
/// `CodexCatalog` — the same source the model picker and the chip
/// read — so the table here, the picker, and the percentage in the
/// composer cannot disagree. The advertised 1,050,000 is the one figure
/// that is not codex's: it is OpenAI's model page, quoted as such.
///
/// The switch writes THROUGH codex (`CodexCatalog.setContextWindow` →
/// `config/value/write`); this card never touches the file. A refusal
/// is shown in codex's own words, with the snippet and a Copy button
/// still offered — the user's own editor is the fallback, not a guess
/// of ours.
private struct CodexContextWindowCard: View {
    @EnvironmentObject var config: ConfigManager
    @ObservedObject private var catalog = CodexCatalog.shared
    @State private var busy = false
    @State private var failure: String? = nil
    @State private var copied = false
    /// The Help section's rhythm — the pane sets the line spacing; the
    /// gaps here follow the same tier (`HelpRhythm`).
    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.sipLineSpacingFactor) private var lineSpacingFactor
    private var ratio: CGFloat { SipFont.ratio(fontScale) }
    private var rhythm: CGFloat { HelpRhythm.vertical(fontScale, lineSpacingFactor) }

    /// No user-visible sentence names an agent outright.
    private var label: String {
        config.agentLabel(for: "codex",
                          defaultName: AgentManager.registry
                              .first { $0.key == "codex" }?.name ?? "Codex")
    }

    /// The model the numbers in the prose describe: the configured
    /// default when the catalog lists it, else the first listed model.
    private var exemplar: CodexModel? {
        if let slug = catalog.defaultModel,
           let model = catalog.models.first(where: { $0.slug == slug }),
           model.defaultContextWindow != nil {
            return model
        }
        return catalog.models.first { $0.defaultContextWindow != nil }
    }

    /// Models the catalog lists with a window — observed-only models
    /// (no cache entry) carry none and are left out of the table.
    private var listed: [CodexModel] {
        catalog.models.filter { $0.defaultContextWindow != nil }
    }

    private static func grouped(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * rhythm) {
            paragraph(whyText)
            paragraph(howText)
            if !listed.isEmpty {
                table
                stamp
            }
            if catalog.maxContextWindowSetting != nil {
                paragraph(String(localized: "Click a button below to switch between the default and the maximum context window for these models.",
                                 comment: "Help card: sentence above the two buttons"))
            }
            controls
            // A refusal is shown in codex's own words, and the line the
            // user can paste by hand appears WITH it — the snippet is
            // the fallback for a write that did not land, not a fixture
            // of the card.
            if let failure {
                Text(verbatim: failure)
                    .sipFont(12)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let value = snippetValue {
                    snippet(value)
                }
            }
            paragraph(nowText)
            if let limit = catalog.configuredAutoCompactLimit {
                paragraph(String(localized: "config.toml also sets model_auto_compact_token_limit = \(Self.grouped(limit)), which is where \(label) compacts the conversation whatever the window says.",
                                 comment: "Help card: a user-set compaction limit is in force; placeholders are a number and the Codex label"))
            }
            paragraph(costText)
        }
        .onAppear { catalog.ensureLoaded() }
    }

    private func paragraph(_ text: String) -> some View {
        FAQAnswer(text: text)
    }

    // MARK: Prose

    /// Each figure is attributed to its source and none is compared
    /// with another: the 1,050,000 is OpenAI's model page; the default,
    /// the maximum and the percentage are codex's own model catalog,
    /// read live (the literals are only the fallback before a cache has
    /// been read).
    private var whyText: String {
        let raw = exemplar?.defaultContextWindowSetting ?? 272_000
        let percent = exemplar?.usablePercent ?? 95
        let usable = exemplar?.defaultContextWindow ?? 258_400
        var text = String(localized: "OpenAI's model pages list a 1,050,000-token context window for GPT-6-Astra, GPT-5.6-Sol, and other recent models. \(label)'s own model catalog runs these models with a default context window of \(Self.grouped(raw)) tokens and keeps \(percent)% of it effective — \(Self.grouped(usable)) tokens, the \(ContextUsageFormat.compact(usable)) in the chip.",
                                comment: "Help card, paragraph 1; placeholders are the Codex label, a grouped token count, a percentage, a grouped token count and a compact token count")
        if let ceiling = catalog.maxContextWindowSetting,
           let usableMax = catalog.models.compactMap(\.maxContextWindow).max() {
            text += " "
            text += String(localized: "The same catalog allows the window to be raised to \(Self.grouped(ceiling)) tokens, of which \(Self.grouped(usableMax)) are effective; that is the figure the chip shows once the setting is changed.",
                           comment: "Help card, paragraph 1 continued; placeholders are two grouped token counts")
        }
        return text
    }

    private var howText: String {
        String(localized: "\(label) has no switch for this in its own interface. The setting is one line in ~/.codex/config.toml, model_context_window — a single value that \(label) clamps to each model's own maximum:",
               comment: "Help card, paragraph 2; placeholders are the Codex label")
    }

    private var nowText: String {
        guard let set = catalog.configuredContextWindow else {
            return String(localized: "Right now: the default. Nothing is set in config.toml, so every model runs at its default window.",
                          comment: "Help card: no model_context_window in config")
        }
        if let ceiling = catalog.maxContextWindowSetting, set >= ceiling {
            return String(localized: "Right now: config.toml sets model_context_window = \(Self.grouped(set)), so every model runs at its maximum.",
                          comment: "Help card: config raises the window to the ceiling; placeholder is a grouped number")
        }
        let percent = exemplar?.usablePercent ?? 95
        let usable = Int((Double(set) * Double(percent) / 100).rounded())
        return String(localized: "Right now: config.toml sets model_context_window = \(Self.grouped(set)). A model whose maximum is lower runs at its maximum; the others use \(Self.grouped(usable)) (\(percent)% of the setting).",
                      comment: "Help card: config sets a custom window; placeholders are two grouped numbers and a percentage")
    }

    private var costText: String {
        String(localized: "The change applies to the next turn of every \(label) session, here and in your terminal, and shows in the chip at once. A larger request draws on your plan's limits or API usage faster.",
               comment: "Help card, closing paragraph; placeholder is the Codex label")
    }

    // MARK: Table

    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: 18 * ratio, verticalSpacing: 4 * rhythm) {
            GridRow {
                header(String(localized: "Model", comment: "Help card table header"))
                header(String(localized: "Default", comment: "Help card table header: the default context window"))
                header(String(localized: "Maximum", comment: "Help card table header: the largest context window config may set"))
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(listed) { model in
                GridRow {
                    cell(model.displayName)
                    cell(Self.grouped(model.defaultContextWindow ?? 0))
                    if let max = model.maxContextWindow {
                        cell(Self.grouped(max))
                    } else {
                        Text("no larger window", comment: "Help card table: the model's maximum equals its default")
                            .sipFont(12)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 2 * rhythm)
    }

    private func header(_ text: String) -> some View {
        Text(verbatim: text)
            .sipFont(12, weight: .semibold)
            .foregroundStyle(.secondary)
    }

    private func cell(_ text: String) -> some View {
        Text(verbatim: text)
            .monospacedDigit()
            .sipFont(12)
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var stamp: some View {
        if let stampInfo = catalog.catalogStamp,
           let version = stampInfo.clientVersion, let at = stampInfo.fetchedAt {
            Text(String(localized: "As listed by \(label) \(version) on \(at.formatted(date: .abbreviated, time: .omitted)). \(label) refreshes this list itself; SipAI re-reads it after every \(label) update.",
                        comment: "Help card: where the table came from; placeholders are the Codex label, a version and a date"))
                .sipFont(11)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Controls

    private var atMaximum: Bool {
        guard let ceiling = catalog.maxContextWindowSetting else { return true }
        return (catalog.configuredContextWindow ?? 0) >= ceiling
    }

    private var controls: some View {
        HStack(spacing: 10 * ratio) {
            Button {
                write(catalog.maxContextWindowSetting)
            } label: {
                Text("Use the maximum", comment: "Help card button: write the largest window to config.toml")
            }
            .sipFont(12)
            .disabled(busy || atMaximum)
            Button {
                write(nil)
            } label: {
                Text("Back to default", comment: "Help card button: remove model_context_window from config.toml")
            }
            .sipFont(12)
            .disabled(busy || catalog.configuredContextWindow == nil)
            if busy {
                ProgressView().controlSize(.small)
                Text("Writing…", comment: "Help card: the config write is in flight")
                    .sipFont(12)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func write(_ value: Int?) {
        guard !busy else { return }
        busy = true
        failure = nil
        Task { @MainActor in
            let outcome = await catalog.setContextWindow(value)
            busy = false
            switch outcome {
            case .written(_, _, let overriddenBy):
                // Landed, but a higher config layer keeps its own
                // value — codex says so, and so must this card.
                if let overriddenBy {
                    failure = String(localized: "Written, but \(label) reports it will not take effect: \(overriddenBy)",
                                     comment: "Help card: the write landed but a higher config layer overrides it; placeholders are the Codex label and Codex's own message")
                }
            case .refused(_, let message):
                failure = String(localized: "\(label) declined the change: \(message)",
                                 comment: "Help card: codex refused the config write; placeholders are the Codex label and Codex's own message")
            case .unavailable:
                failure = String(localized: "\(label) could not be asked to change its config. Add the line below to ~/.codex/config.toml yourself, above any [section] header.",
                                 comment: "Help card: no codex app-server answered; placeholder is the Codex label")
            }
        }
    }

    // MARK: Snippet

    /// The line the maximum button writes, spelled the way codex spells
    /// it — what a user with no working app-server pastes by hand.
    ///
    /// The number is the catalog's ceiling, else whatever the user
    /// already set; with neither known there is NO snippet — a window
    /// is never guessed, and a line inventing one would be the only
    /// number on the card that is nobody's.
    private var snippetValue: Int? {
        catalog.maxContextWindowSetting ?? catalog.configuredContextWindow
    }

    private func snippet(_ value: Int) -> some View {
        let line = "model_context_window = \(value)"
        return HStack(alignment: .center, spacing: 8 * ratio) {
            Text(verbatim: line)
                .sipFont(12, design: .monospaced)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                let board = NSPasteboard.general
                board.clearContents()
                board.setString(line, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                if copied {
                    Text("Copied", comment: "Help card: the snippet was copied to the clipboard")
                } else {
                    Text("Copy", comment: "Help card: copy the config snippet")
                }
            }
            .sipFont(12)
        }
        .padding(.horizontal, 10 * ratio)
        .padding(.vertical, 6 * rhythm)
        .background(
            RoundedRectangle(cornerRadius: 6 * ratio)
                .fill(Color.gray.opacity(0.12))
        )
    }
}

// MARK: - Shared hover buttons (settings only)

/// Plain text button with the standard gray hover pill — the settings
/// counterpart of `sidebarRowBackground`, kept local so every settings
/// button hovers the same way.
struct SettingsTextButton: View {
    let title: String
    var weight: Font.Weight = .regular
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .sipFont(14, weight: weight)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovered ? Color.gray.opacity(0.2) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Blue primary-action button (Save) with a hover shade.
struct SettingsProminentButton: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .sipFont(13, weight: .semibold)
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovered ? SipDesign.blue.opacity(0.82) : SipDesign.blue)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Trash icon button that tints red on hover (matches `ModelSettingsRow`).
struct SettingsTrashButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .sipFont(13)
                .foregroundColor(hovered ? .red : .secondary)
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovered ? Color.red.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Settings → Updates.
///
/// Also the only place in the app that states its own version, which is
/// the number a user quotes in a bug report.
struct UpdatesPane: View {
    @EnvironmentObject var updates: UpdateController
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var agents: AgentManager
    @ObservedObject private var cliUpdates = AgentCLIUpdateMonitor.shared
    @ObservedObject private var badge = UpdateBadge.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Updates", comment: "Settings pane header")
                .sipFont(14, weight: .semibold)

            // Not a Text("literal \(value)") — that overload runs a
            // markdown pass over the result. Same rule as everywhere
            // else a value reaches a label.
            Text(verbatim: "SipAI \(updates.currentVersion) (\(updates.currentBuild))")
                .sipFont(13)
                .foregroundStyle(.secondary)

            // Verbatim, and carrying no prose: a personal name and a
            // licence identifier are the same in every language, so this
            // needs no String Catalog entry and cannot come up half
            // translated. The same line is in the About panel, via
            // INFOPLIST_KEY_NSHumanReadableCopyright.
            Text(verbatim: "© 2026 Yizhan Huang · MIT")
                .sipFont(12)
                .foregroundStyle(.tertiary)

            Divider().opacity(0.3).padding(.vertical, 2)

            // The same rows in every build. A copy that may not update
            // itself (`UpdaterAvailability`: built locally, or by someone
            // else) runs no updater and draws them greyed out, with the
            // reason on hover — so whoever builds SipAI sees the page its
            // users see, and a control that is missing reads as a
            // regression where a disabled one reads as a reason.
            Toggle(isOn: Binding(
                get: { updates.automaticallyChecksForUpdates },
                set: { updates.setAutomaticallyChecksForUpdates($0) }
            )) {
                Text("Check for updates automatically",
                     comment: "Updates pane: toggle the daily update check")
                    .sipFont(13)
            }
            .toggleStyle(.checkbox)
            .disabled(!selfUpdating)
            .help(updates.notSelfUpdatingReason)

            Text("SipAI asks updates.sipai.dev once a day whether a newer version exists. Nothing is downloaded until you choose to install it, and no usage data, account or system profile is ever sent.",
                 comment: "Updates pane: what the automatic check does")
                .sipFont(12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    updates.checkForUpdates()
                } label: {
                    Text("Check Now",
                         comment: "Updates pane: look for a new version immediately")
                }
                .sipFont(13)
                .disabled(!selfUpdating || !updates.canCheckForUpdates)
                .help(updates.notSelfUpdatingReason)

                if let last = updates.lastUpdateCheckDate {
                    Text(String(localized: "Last checked \(last.formatted(date: .abbreviated, time: .shortened))",
                                comment: "Updates pane: when the last update check ran; placeholder is a date and time"))
                        .sipFont(12)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)

            // What the badge counted for SipAI itself. The button opens
            // Sparkle's own window — the release notes, then Install —
            // the same one the daily check shows.
            if let available = updates.availableUpdate, !updates.isWaitingForQuietMoment {
                HStack(spacing: 10) {
                    Text(String(localized: "New version \(available.display)",
                                comment: "Updates pane: a newer release exists, of SipAI or of a command-line tool; placeholder is a version number"))
                        .sipFont(12)
                        .foregroundStyle(.orange)
                    Button {
                        updates.checkForUpdates()
                    } label: {
                        Text("Update…",
                             comment: "Updates pane: open the SipAI update window, with the release notes and Install")
                    }
                    .sipFont(13)
                    .disabled(!updates.canCheckForUpdates)
                }
            }

            if updates.isWaitingForQuietMoment {
                // The user clicked "Install and Relaunch", was told a
                // turn was running and chose to wait. The line beside the
                // sidebar's logo said so once, and the badge points here;
                // this line is for the person who came to find out why
                // nothing has relaunched yet — and the button is the same
                // way out the sheet offered.
                HStack(spacing: 10) {
                    Text("An update is ready and will be installed once the running agent turn finishes.",
                         comment: "Updates pane: the install is waiting for agent turns to end")
                        .sipFont(12)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        updates.installNow()
                    } label: {
                        Text("Install Now",
                             comment: "Updates pane: stop the running agent turn and install the waiting SipAI update immediately")
                    }
                    .sipFont(13)
                }
            }

            commandLineTools
        }
        // Re-reads the installed versions, and asks the release
        // endpoints only if the last successful answer is stale.
        //
        // And this pane on screen is what clears the download badge:
        // everything it lists has now been seen at its version. A
        // release found WHILE it is on screen is one the user is looking
        // at too, so the badge never draws beside "Updates" over the
        // Updates pane itself.
        .onAppear {
            cliUpdates.paneAppeared()
            badge.markSeen()
        }
        .onChange(of: badge.items) { _, _ in badge.markSeen() }
    }

    /// False on a copy that may not update itself: its updater never
    /// starts, so the controls above are drawn but cannot act, and
    /// `UpdateController.notSelfUpdatingReason` is their hover.
    private var selfUpdating: Bool { updates.availability.allowsUpdates }

    /// One row per INSTALLED agent CLI. Nothing is listed for an agent
    /// this machine does not have — a row about a tool that is not here
    /// is an advertisement, not a status. Installing, signing in and
    /// deleting are Settings → Agent Guide's; this is the difference
    /// between the version on disk and the newest one released.
    /// Installed, and not hidden in Settings → Agent Guide. A hidden
    /// tool is asked nothing — no release check, no badge — so a row
    /// for it could only print its version under a claim nobody made.
    private var toolRows: [AgentInfo] {
        cliUpdates.installedAgents.filter { !cliUpdates.hiddenAgents.contains($0.key) }
    }

    @ViewBuilder
    private var commandLineTools: some View {
        if !toolRows.isEmpty {
            Divider().opacity(0.3).padding(.vertical, 2)

            Text("Command-line tools", comment: "Updates pane: header for the agent CLI version rows")
                .sipFont(13, weight: .semibold)

            // The same bargain as the app's own check above, asked the
            // same way: the request is periodic and leaves the machine,
            // so it has a switch of its own, and the sentence under it
            // says where the request goes.
            Toggle(isOn: Binding(
                get: { cliUpdates.remoteChecksEnabled },
                set: { cliUpdates.setRemoteChecksEnabled($0) }
            )) {
                Text("Check these tools for new versions automatically",
                     comment: "Updates pane: toggle the periodic agent CLI release check")
                    .sipFont(13)
            }
            .toggleStyle(.checkbox)

            Text("SipAI asks each tool's own release endpoint — the npm registry, or the vendor's version file — every few hours whether a newer version exists. Nothing about you or your machine is sent. A tool is updated only by running its own update command, or, where that command declines and names the vendor's installer instead, by running that installer pinned to the version shown.",
                 comment: "Updates pane: what the CLI version check does")
                .sipFont(12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Rests on the check above: with no check there is nothing
            // to act on, so the switch waits for it — disabled with the
            // reason on hover, not hidden. Its own value is kept either
            // way.
            Toggle(isOn: Binding(
                get: { cliUpdates.autoUpdateEnabled },
                set: { cliUpdates.setAutoUpdateEnabled($0) }
            )) {
                Text("Update these tools automatically",
                     comment: "Updates pane: toggle automatic agent CLI updates")
                    .sipFont(13)
            }
            .toggleStyle(.checkbox)
            .disabled(!cliUpdates.remoteChecksEnabled)
            .help(cliUpdates.remoteChecksEnabled
                  ? ""
                  : String(localized: "Turn on the check above first.",
                           comment: "Updates pane: why the automatic-update switch is disabled"))

            Text("When a newer version is found, SipAI updates the tool by itself, waiting for any running turn of that tool to finish first, and says so next to the logo in the sidebar.",
                 comment: "Updates pane: what the automatic CLI update does")
                .sipFont(12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(toolRows) { agent in
                    CLIUpdateRow(agent: agent)
                        .environmentObject(config)
                        .environmentObject(agents)
                }
            }
            .padding(.top, 2)
        }
    }
}

/// One command-line tool: what is installed, what the last successful
/// check found, and whatever can be done about the difference.
private struct CLIUpdateRow: View {
    @Environment(\.sipFontScale) private var fontScale
    let agent: AgentInfo
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var agents: AgentManager
    @ObservedObject private var cliUpdates = AgentCLIUpdateMonitor.shared
    @State private var showingDetail = false

    /// No user-visible sentence in this app names an agent outright.
    private var label: String {
        config.agentLabel(for: agent.key, defaultName: agent.name)
    }

    private var status: CLIUpdateStatus {
        cliUpdates.statuses[agent.key] ?? .unknown
    }

    /// A turn in flight for this agent, ours or another terminal's —
    /// the same rule an automatic update waits on. Replacing the binary
    /// under a running child is not something to do quietly, so the
    /// button is DISABLED with a hover hint rather than hidden — a
    /// control that vanishes reads as a bug where a disabled one reads
    /// as a reason.
    private var hasRunningTurn: Bool {
        agents.hasTurnInFlight(agentKey: agent.key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                // The two columns bound tier-scaled text, so they
                // widen with it or truncate a name that fit at Default.
                Text(verbatim: label)
                    .sipFont(13)
                    .frame(width: 130 * SipFont.ratio(fontScale), alignment: .leading)

                // Tool-derived text: never an interpolated Text
                // literal, which markdown-parses its result.
                Text(verbatim: cliUpdates.installed[agent.key]?.text ?? "")
                    .monospacedDigit()
                    .sipFont(13)
                    .foregroundStyle(.secondary)
                    .frame(width: 78 * SipFont.ratio(fontScale), alignment: .leading)

                claim

                Spacer(minLength: 8)

                action
            }

            if showingDetail, case .updateFailed(let tail) = status, !tail.isEmpty {
                Text(verbatim: tail)
                    .sipFont(11, design: .monospaced)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.10))
                    )
            }
        }
    }

    /// What the row is entitled to say. `versionOnly` and `unknown`
    /// say NOTHING — no check has succeeded, so there is no claim to
    /// make, and "up to date" without evidence is the one thing this
    /// feature exists to avoid.
    @ViewBuilder
    private var claim: some View {
        switch status {
        case .unknown, .versionOnly:
            EmptyView()
        case .upToDate(_, let checkedAt):
            Text("Up to date", comment: "Updates pane: the installed CLI matches the latest release")
                .sipFont(12)
                .foregroundStyle(.secondary)
                .help(String(localized: "Last checked \(checkedAt.formatted(date: .abbreviated, time: .shortened))",
                             comment: "Updates pane: when the last update check ran; placeholder is a date and time"))
        case .updateAvailable(_, let latest):
            Text(String(localized: "New version \(latest.text)",
                        comment: "Updates pane: a newer release exists, of SipAI or of a command-line tool; placeholder is a version number"))
                .sipFont(12)
                .foregroundStyle(.orange)
        case .updating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                // The status stays `.updating` until the child is
                // confirmed gone, Cancel included; the label is what
                // says which of the two is happening.
                if cliUpdates.cancelling.contains(agent.key) {
                    Text("Cancelling…", comment: "Updates pane: the CLI's updater has been asked to stop and is winding down")
                        .sipFont(12)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Updating…", comment: "Updates pane: the CLI's own updater is running")
                        .sipFont(12)
                        .foregroundStyle(.secondary)
                }
            }
        case .updateFailed:
            Text("Update did not complete", comment: "Updates pane: the updater ran and the installed version did not change")
                .sipFont(12)
                .foregroundStyle(.orange)
        case .managedElsewhere(_, let manager):
            // Homebrew's claude and kimi: their own updaters leave the
            // install to Homebrew, which SipAI never runs. The row says
            // who does — no claim, no button, no badge.
            Text(String(localized: "Managed by \(manager)",
                        comment: "Updates pane: a package manager the tool's own updater leaves updates to installed this copy; placeholder is its name, e.g. Homebrew"))
                .sipFont(12)
                .foregroundStyle(.secondary)
                .help(String(localized: "The tool's own updater leaves this copy to \(manager), which SipAI does not run. Update it there, in Terminal.",
                             comment: "Updates pane: hover on a tool a package manager updates; placeholder is the package manager's name, e.g. Homebrew"))
        }
    }

    @ViewBuilder
    private var action: some View {
        switch status {
        case .updating:
            Button {
                cliUpdates.cancelUpdate(agentKey: agent.key)
            } label: {
                Text("Cancel", comment: "Updates pane: stop the running CLI updater")
            }
            .sipFont(12)
            .disabled(cliUpdates.cancelling.contains(agent.key))
        case .updateAvailable, .updateFailed:
            HStack(spacing: 8) {
                if case .updateFailed(let tail) = status, !tail.isEmpty {
                    Button {
                        showingDetail.toggle()
                    } label: {
                        Text("Details", comment: "Updates pane: show the updater's own output")
                    }
                    .sipFont(12)
                }
                Button {
                    // The automatic update's road too — including the
                    // codex SipAI installed, which SipAI updates itself.
                    cliUpdates.startUpdate(agentKey: agent.key)
                } label: {
                    Text("Update", comment: "Updates pane: run the CLI's own update command")
                }
                .sipFont(12)
                // Also disabled while a previous press is still winding
                // down (a Cancel, or an updater exiting): the monitor
                // refuses a second updater on one tool, and a refusal
                // with nothing on screen reads as a dead button.
                .disabled(hasRunningTurn || cliUpdates.updateInFlight(agent.key))
                .help(hasRunningTurn
                      ? (cliUpdates.updatesAutomaticallyWhenIdle(agent.key)
                         ? String(localized: "This tool updates by itself once the running turn finishes.",
                                  comment: "Updates pane: why the Update button is disabled, when automatic updates are on")
                         : String(localized: "Finish the running turn before updating this tool.",
                                  comment: "Updates pane: why the Update button is disabled"))
                      : "")
            }
        case .unknown, .versionOnly, .upToDate, .managedElsewhere:
            EmptyView()
        }
    }
}

struct LanguagePane: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var agents: AgentManager

    /// True once the picker has been moved away from what the bundle is
    /// actually rendering. Derived, never latched: switching back to the
    /// running language makes the restart notice go away by itself,
    /// because there is then nothing left to apply.
    private var needsRestart: Bool {
        appState.language != AppLanguage.effective
    }

    private var hasRunningTurn: Bool {
        agents.runners.values.contains { $0.status.isRunning }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Language", comment: "Settings pane header")
                .sipFont(14, weight: .semibold)

            Picker("", selection: Binding(
                get: { appState.language },
                set: { l in
                    appState.language = l
                    // Persists the choice AND writes `AppleLanguages`
                    // for the next launch. Nothing on screen changes
                    // now — see the restart notice below.
                    config.setLanguage(l)
                }
            )) {
                ForEach(AppLanguage.allCases) { l in
                    // `endonym`, not a catalog string: a language's own
                    // name has to be legible to someone who cannot yet
                    // read the language the app is currently in.
                    Text(verbatim: l.endonym).tag(l)
                }
            }
            .pickerStyle(.inline)
            .sipFont(14)
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)

            if needsRestart {
                restartNotice
            }

            Text("Currently, SipAI only supports two languages. We will add more language support later.",
                 comment: "Language pane: only two languages ship today, more are coming")
                .sipFont(13)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// macOS resolves an app's localizations once, at launch, so a
    /// language change cannot take effect in place. Saying so — and
    /// offering the restart — is the whole reason this row exists.
    @ViewBuilder
    private var restartNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Interpolated through String(localized:) rather than a
            // Text literal — the interpolating Text overload runs a
            // markdown pass over the result.
            Text(String(localized: "Restart SipAI to switch to \(appState.language.endonym).",
                        comment: "Language pane: the choice applies on next launch; placeholder is the language's own name"))
                .sipFont(13)

            if hasRunningTurn {
                // No count, deliberately: a number here would need a
                // plural rule English has and Chinese does not, for a
                // fact the sidebar already shows precisely.
                Text("Agent turns in progress will be stopped.",
                     comment: "Language pane: warning before restarting while agent turns are in flight")
                    .sipFont(12)
                    .foregroundStyle(.orange)
            }

            Button {
                relaunch()
            } label: {
                Text("Restart Now", comment: "Language pane: quit and reopen the app to apply the language")
            }
            .sipFont(13)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    /// Open a SECOND instance of our own bundle, then quit this one.
    ///
    /// The new instance is launched BEFORE terminating, and termination
    /// is left to `applicationShouldTerminate` — which is what
    /// interrupts running turns and waits for the children to be reaped.
    /// Quitting first and relying on something to reopen us would drop
    /// that guarantee, and a `SIGKILL`ed turn is exactly what the app
    /// goes out of its way to avoid everywhere else.
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
