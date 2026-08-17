// SettingsView.swift
// Modal settings panel: models, prompt and roles, files and notes,
// display, labels, language, updates, help.

import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var projects: ProjectManager
    @EnvironmentObject var chats: ChatManager
    @EnvironmentObject var notesManager: NotesManager
    @EnvironmentObject var agents: AgentManager
    @EnvironmentObject var scheduler: ScheduledTaskScheduler
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingFactoryReset = false

    /// Data-directory entries a reset could not remove. Non-empty means
    /// the wipe was PARTIAL — reported rather than swallowed, because
    /// the alternative is the user believing their API keys are gone
    /// while the file holding them is still on disk.
    @State private var resetFailures: [String] = []

    enum Tab: String, CaseIterable, Identifiable {
        case models, prompt, files, display, labels, language, updates, help
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .models:    return "Chat models"
            case .prompt:    return "Prompt and Roles"
            case .files:     return "Files & Notes"
            case .display:   return "Display"
            case .labels:    return "Labels"
            case .language:  return "Language"
            case .updates:   return "Updates"
            case .help:      return "Help"
            }
        }
    }

    @State private var tab: Tab = .models
    @State private var closeHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings", comment: "Settings panel title")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(closeHovered ? .primary : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { closeHovered = $0 }
            }
            .padding(16)
            Divider()

            HStack(spacing: 0) {
                // Sidebar
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Tab.allCases) { t in
                        Button {
                            tab = t
                        } label: {
                            HStack {
                                Text(t.title).font(.system(size: 14, weight: .medium))
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .sidebarRowBackground(selected: t == tab)
                    }
                    Spacer()
                    Divider().opacity(0.3)
                    Button {
                        confirmingFactoryReset = true
                    } label: {
                        Text("Factory reset", comment: "Settings: factory reset button")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .sidebarRowBackground()
                }
                .padding(8)
                .frame(width: 180)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))

                Divider().opacity(0.3)

                // Pane
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch tab {
                        case .models:    ModelsPane()
                        case .prompt:    PromptAndRolesPane()
                        case .files:     FilesPane()
                        case .display:   DisplayPane()
                        case .labels:    LabelsPane()
                        case .language:  LanguagePane()
                        case .updates:   UpdatesPane()
                        case .help:      HelpPane()
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .alert(
            String(localized: "Factory reset?",
                   comment: "Title of the factory reset confirmation"),
            isPresented: $confirmingFactoryReset
        ) {
            Button(role: .destructive) {
                performFactoryReset()
            } label: {
                Text("Reset", comment: "Confirm the factory reset")
            }
            Button(role: .cancel) { } label: {
                Text("Cancel", comment: "Dismiss the factory reset confirmation")
            }
        } message: {
            Text("Chats, chat groups, notes, models, API keys, scheduled tasks, and every setting are wiped, and the app returns to first-run setup. Agent turns running right now are stopped. Left alone, because they live outside the app: the agent CLIs' own sessions — including transcripts of scheduled runs that already happened — and anything inside your dedicated folder. This cannot be undone.",
                 comment: "Body of the factory reset confirmation")
        }
        .alert(
            String(localized: "Reset was incomplete",
                   comment: "Title when a factory reset could not remove some files"),
            isPresented: Binding(get: { !resetFailures.isEmpty },
                                 set: { if !$0 { resetFailures = [] } })
        ) {
            Button(role: .cancel) { resetFailures = [] } label: {
                Text("OK", comment: "Dismiss the incomplete-reset alert")
            }
        } message: {
            Text(String(localized: "These items could not be removed and may still hold your data: \(resetFailures.joined(separator: ", ")). Everything else was reset.",
                        comment: "Body when a factory reset could not remove some files"))
        }
    }

    /// The wipe itself lives in `FactoryReset`, so every caller runs
    /// the same sequence; all this does is report a partial failure
    /// and get out of the way.
    private func performFactoryReset() {
        let failed = FactoryReset.perform(config: config,
                                          projects: projects,
                                          chats: chats,
                                          notes: notesManager,
                                          agents: agents,
                                          scheduler: scheduler,
                                          appState: appState)
        guard failed.isEmpty else {
            // STAY OPEN — this alert is presented from this sheet, so
            // dismissing would take the only report of the failure with
            // it. (`FactoryReset` withholds `.sipFactoryReset` on this
            // path for the same reason: it would swap the sheet's whole
            // host view out for onboarding.)
            //
            // Deferred by one turn of the run loop because we are inside
            // the CONFIRMATION alert's button action: raising a second
            // alert while the first is still dismissing is how SwiftUI
            // drops it, and a dropped alert here means the user is told
            // nothing at all.
            DispatchQueue.main.async { resetFailures = failed }
            return
        }
        // Close the sheet. The window underneath is already showing
        // onboarding — `FactoryReset` posts `.sipFactoryReset`, which is
        // what re-arms ContentView's latched gate.
        dismiss()
    }
}

// MARK: - Panes

struct ModelsPane: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var config: ConfigManager
    @State private var showingModelSetup = false
    @State private var addHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chat models", comment: "Settings pane header").font(.system(size: 14, weight: .semibold))
            ForEach(config.models) { m in
                ModelSettingsRow(model: m)
            }

            Divider()
            // One button, same workflow as the composer's "Add Model":
            // the provider → API key → pick-models setup sheet.
            HStack {
                Spacer()
                Button {
                    showingModelSetup = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 13))
                            .foregroundColor(SipDesign.blue)
                        Text("Add Model", comment: "Settings: open the model setup window")
                            .font(.system(size: 14, weight: .medium))
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
        .sheet(isPresented: $showingModelSetup) {
            ModelSetupSheet()
                .environmentObject(appState)
                .environmentObject(config)
        }
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
                Text(model.name).font(.system(size: 14, weight: .medium))
                // String expression (verbatim): model ids like
                // meta-llama/Llama-3.1_8B carry markdown-active chars.
                Text(model.providerKey + " · " + model.id)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            if config.defaultModel == model.id {
                Text("Default", comment: "Tag shown next to the default model")
                    .font(.system(size: 12, weight: .semibold))
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
                        .font(.system(size: 13, weight: .medium))
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
                    .font(.system(size: 13))
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
            Text("System Prompt", comment: "Settings: system prompt section header").font(.system(size: 14, weight: .semibold))
            Text("Used as the default instructions when no project- or role-specific prompt is set.",
                 comment: "System prompt help text")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            // 135 is a MINIMUM, not a cap: the editor still grows
            // with the pane, and a long prompt scrolls inside it.
            promptEditor($text, minHeight: 135, monospaced: true)
            HStack {
                Spacer()
                SettingsProminentButton(title: String(localized: "Save", comment: "Save system prompt")) {
                    config.saveGeneralSystemPrompt(text)
                }
            }

            Divider().padding(.vertical, 6)

            Text("Roles", comment: "Settings: roles section header").font(.system(size: 14, weight: .semibold))
            Text("Each role is a reusable system prompt you can switch to in chat.",
                 comment: "Roles help text")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            ForEach($editing) { $role in
                VStack(alignment: .leading, spacing: 4) {
                    TextField("", text: $role.name).font(.system(size: 14, weight: .medium))
                    promptEditor($role.prompt, minHeight: 80, monospaced: false)
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
    private func promptEditor(_ binding: Binding<String>,
                              minHeight: CGFloat,
                              monospaced: Bool) -> some View {
        TextEditor(text: binding)
            .font(.system(size: 14, design: monospaced ? .monospaced : .default))
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
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
            Text("Files & Notes", comment: "Settings pane header").font(.system(size: 14, weight: .semibold))

            HStack {
                Text("Dedicated folder", comment: "Settings: the folder the sidebar's Local Files section browses")
                    .font(.system(size: 14))
                Spacer()
                Text(config.dedicatedFolder ?? String(localized: "Not set", comment: "When dedicated folder is unset"))
                    .font(.system(size: 13))
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
                    .font(.system(size: 14))
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
                .font(.system(size: 14))
            }
            Text("Notes are written by this model. Thinking-heavy models can produce richer notes but may take noticeably longer to finish.",
                 comment: "Settings: hint under the note model picker")
                .font(.system(size: 12))
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
                .font(.system(size: 14, weight: .semibold))
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
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Text("Font Size", comment: "Settings: font size section header")
                .font(.system(size: 14, weight: .semibold))
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
            Text("Applies to the sidebar and chat/agent content. Bigger tiers also widen line spacing; Large text mode doubles it.",
                 comment: "Settings: font size help text")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Text("Sidebar", comment: "Settings: header of the sidebar display toggles")
                .font(.system(size: 14, weight: .semibold))

            toggle("Show logo and app name", value: \.showSidebarBrand)
            Text("The SipAI mark and wordmark at the top of the sidebar. Turn it off to give the section list that room.",
                 comment: "Settings: sidebar brand toggle help text")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Text("Chatbox display", comment: "Settings: header of the chat display toggles")
                .font(.system(size: 14, weight: .semibold))

            // One toggle, not a Chat/Agent pair: chat sessions carry no
            // token counter at all, so a "Chat" sub-toggle would be a
            // switch with nothing behind it.
            toggle("Show token count", value: \.showTokenAgent)

            Text("Show note button", comment: "Settings: note button group label (no toggle of its own)")
                .font(.system(size: 14))
            subToggle("Chat", value: \.showNoteChat)
            subToggle("Agent", value: \.showNoteAgent)
            subToggle("Show note prompt", value: \.showNotePrompt)
            Text("With note prompt on, the note button asks: generate directly, or add instructions first.",
                 comment: "Settings: note prompt help text")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 16)

            toggle("Show chat group name", value: \.showProjectName)
            toggle("Show role line", value: \.showRole)

            Divider().padding(.vertical, 4)

            Text("Typo check", comment: "Settings: spell-checking section header")
                .font(.system(size: 14, weight: .semibold))

            toggle("Check spelling while typing", value: \.spellCheck)
            Text("Underlines words the macOS dictionary doesn't know, in the chat and agent input boxes, the message editor and the note editor. Nothing is ever corrected for you.",
                 comment: "Settings: spell check help text")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func toggle(_ key: LocalizedStringKey, value: WritableKeyPath<DisplaySettings, Bool>) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 14))
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
                .font(.system(size: 13))
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

    /// One label row per agent the sidebar shows (installed CLI or a
    /// session store on disk) — not the whole registry, so users don't
    /// see rows for agents this machine has never had.
    private var labelableAgents: [AgentInfo] { agents.availableAgents }

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
                .font(.system(size: 14, weight: .semibold))

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
                .font(.system(size: 14))
                .lineLimit(1)
            Spacer(minLength: 8)
            if editingField == row.field {
                editingControls(row)
            } else {
                Text(verbatim: row.value)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                SettingsTextButton(title: String(localized: "Edit",
                                                 comment: "Labels pane: start editing one label")) {
                    beginEdit(row)
                }
            }
        }
        .frame(height: 30)
    }

    @ViewBuilder
    private func editingControls(_ row: LabelRow) -> some View {
        TextField(row.fallback, text: $draft)
            .font(.system(size: 14))
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
            .font(.system(size: 11))
            .monospacedDigit()
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
    @State private var expanded: Set<Int> = []

    private struct FAQ: Identifiable {
        let id: Int
        let question: String
        let answer: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Questions?", comment: "Help pane header")
                .font(.system(size: 14, weight: .semibold))
            Text("Click a question to see the answer.",
                 comment: "Help pane help text")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            ForEach(items) { item in
                FAQCard(question: item.question,
                        answer: item.answer,
                        isOpen: expanded.contains(item.id)) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if expanded.contains(item.id) {
                            expanded.remove(item.id)
                        } else {
                            expanded.insert(item.id)
                        }
                    }
                }
            }
        }
    }

    private var items: [FAQ] {
        [
            FAQ(id: 1,
                question: String(localized: "How do I get an API key?",
                                 comment: "FAQ question"),
                answer: String(localized: """
Each provider issues keys from its own dashboard. For examples, OpenAI at platform.openai.com/api-keys, Anthropic at console.anthropic.com, Google (Gemini) at aistudio.google.com, DeepSeek at platform.deepseek.com, Alibaba Qwen in the DashScope console, xAI at console.x.ai. You may need to register for their accounts and create a key there, then in SipAI click Add Model (in the chat composer or Settings → Chat models), pick the provider, and paste the key when asked. Some providers issue region-bound keys (e.g. Qwen, Kimi): pick the region that matches where the key was created.
""", comment: "FAQ answer: getting an API key")),
            FAQ(id: 2,
                question: String(localized: "I added a key but requests fail — what should I check?",
                                 comment: "FAQ question"),
                answer: String(localized: """
Open Add Model and pick the provider again — Continue re-validates the stored key by fetching its model list, and the error it shows names the actual cause. The usual suspects: the key belongs to a different region (Qwen, Kimi — switch region on the key step), the account has no credit, or the model ID no longer exists. If you entered an environment variable name instead of a key, note that apps launched from the Dock don't see shell exports — paste the key itself, or launch SipAI from a terminal.
""", comment: "FAQ answer: debugging failing requests")),
            FAQ(id: 3,
                question: String(localized: "How can I track my token usage and cost?",
                                 comment: "FAQ question"),
                answer: String(localized: """
Each provider has their dashboard to help users track their API credit usage. Please check your account dashboard for more information. SipAI also shows the total token consumption inside each agent session.
""", comment: "FAQ answer: tracking usage")),
            FAQ(id: 4,
                question: String(localized: "Can SipAI show how much of my provider plan is used?",
                                 comment: "FAQ question"),
                answer: String(localized: """
Not yet. For example, Claude's plan percentages come from private endpoints only Anthropic's own apps can use — there is no documented API. To see your limits, you need to check with your provider. If a session or weekly limit is hit mid-run, the CLI says so and SipAI shows that message in the transcript.
""", comment: "FAQ answer: plan consumption")),
            FAQ(id: 5,
                question: String(localized: "What's the difference between a chat and an agent session?",
                                 comment: "FAQ question"),
                answer: String(localized: """
Chats talk directly to a model over your API key — pure conversation, billed per token. Agent sessions run the provider's CLI (e.g. Claude Code, Codex) on your Mac: the agent can read and edit files and run commands, and billing follows the CLI's own login or plan. Chats are stored by this app; agent sessions are the CLIs (or Apps)' own files, which SipAI reads and follows live.
""", comment: "FAQ answer: chats vs agent sessions")),
            FAQ(id: 6,
                question: String(localized: "How do I set up the Claude Code or other AI agent providers?",
                                 comment: "FAQ question"),
                answer: String(localized: """
Install the CLI and sign in once; the sidebar section appears automatically. For examples, Claude Code: npm install -g @anthropic-ai/claude-code, then run claude in a terminal to log in. Codex: npm install -g @openai/codex, then codex login. Either agent runs fully inside SipAI once it is signed in; before that its sessions list read-only.
""", comment: "FAQ answer: agent CLI setup")),
            FAQ(id: 7,
                question: String(localized: "Where is my data stored? Does anything leave my Mac?",
                                 comment: "FAQ question"),
                answer: String(localized: """
SipAI is completely a local tool. Chats, notes, roles, and settings live in ~/Library/Application Support/SipAI, and API keys stay in that folder's config.json on your disk. Messages are sent only to the provider of the model you picked — there is no server in between. Agent sessions are stored by the CLIs themselves, under ~/.claude, ~/.codex and ~/.kimi-code.
""", comment: "FAQ answer: data storage and privacy")),
            FAQ(id: 8,
                question: String(localized: "What do the system prompt and roles do?",
                                 comment: "FAQ question"),
                answer: String(localized: """
The system prompt (Settings → Prompt and Roles) is the standing instruction sent with every chat message. Roles are named prompts you can switch between, so the same chat window can answer as a code reviewer, translator, or tutor. One starter role ships with the app as a worked example — edit it, delete it, or add your own.
""", comment: "FAQ answer: system prompt and roles")),
            FAQ(id: 9,
                question: String(localized: "How do I organize, rename, or export things?",
                                 comment: "FAQ question"),
                answer: String(localized: """
Hover any sidebar row and click ⋮ — chats can be renamed, moved into projects, or deleted; notes can be renamed, downloaded as markdown, or deleted; agent sessions can be renamed too. Settings → Files & Notes also lets you pick a dedicated folder: the sidebar browses it, so chats and notes the SipAI command-line tool saves there appear alongside the app's own.
""", comment: "FAQ answer: organizing and renaming")),
            FAQ(id: 10,
                question: String(localized: "macOS keeps asking to let SipAI use a folder — is that normal?",
                                 comment: "FAQ question"),
                answer: String(localized: """
Being asked once per folder is normal. Agent sessions read and edit files in your working folder, so the first time SipAI opens a project inside Desktop, Documents, Downloads, iCloud Drive, or an external drive, macOS asks permission. Click Allow and the answer is remembered — including after you restart. You can review or change it any time in System Settings → Privacy & Security → Files and Folders. Scheduled tasks run inside SipAI, so they reuse the same permission instead of asking again.
""", comment: "FAQ answer: folder access permission prompts")),
        ]
    }
}

/// One expandable question card in the Help pane.
private struct FAQCard: View {
    let question: String
    let answer: String
    let isOpen: Bool
    let toggle: () -> Void

    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text(question)
                        .font(.system(size: 13, weight: .medium))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                Text(answer)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 32)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovered ? Color.gray.opacity(0.14) : Color.gray.opacity(0.08))
        )
        .onHover { hovered = $0 }
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
                .font(.system(size: 14, weight: weight))
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
                .font(.system(size: 13, weight: .semibold))
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
                .font(.system(size: 13))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Updates", comment: "Settings pane header")
                .font(.system(size: 14, weight: .semibold))

            // Not a Text("literal \(value)") — that overload runs a
            // markdown pass over the result. Same rule as everywhere
            // else a value reaches a label.
            Text(verbatim: "SipAI \(updates.currentVersion) (\(updates.currentBuild))")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            // Verbatim, and carrying no prose: a personal name and a
            // licence identifier are the same in every language, so this
            // needs no String Catalog entry and cannot come up half
            // translated. The same line is in the About panel, via
            // INFOPLIST_KEY_NSHumanReadableCopyright.
            Text(verbatim: "© 2026 Yizhan Huang · MIT")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            if updates.availability.allowsUpdates {
                Divider().opacity(0.3).padding(.vertical, 2)

                Toggle(isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates },
                    set: { updates.setAutomaticallyChecksForUpdates($0) }
                )) {
                    Text("Check for updates automatically",
                         comment: "Updates pane: toggle the daily update check")
                        .font(.system(size: 13))
                }
                .toggleStyle(.checkbox)

                Text("SipAI asks updates.sipai.dev once a day whether a newer version exists. Nothing is downloaded until you choose to install it, and no usage data, account or system profile is ever sent.",
                     comment: "Updates pane: what the automatic check does")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)

                HStack(spacing: 10) {
                    Button {
                        updates.checkForUpdates()
                    } label: {
                        Text("Check Now",
                             comment: "Updates pane: look for a new version immediately")
                    }
                    .font(.system(size: 13))
                    .disabled(!updates.canCheckForUpdates)

                    if let last = updates.lastUpdateCheckDate {
                        Text(String(localized: "Last checked \(last.formatted(date: .abbreviated, time: .shortened))",
                                    comment: "Updates pane: when the last update check ran; placeholder is a date and time"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)

                if updates.isWaitingForQuietMoment {
                    // Without this the user clicks "Install and
                    // Relaunch", we hold the relaunch back because a
                    // turn is running, and nothing on screen accounts
                    // for the delay.
                    Text("An update is ready and will be installed once the running agent turn finishes.",
                         comment: "Updates pane: the install is waiting for agent turns to end")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420, alignment: .leading)
                }
            } else {
                Divider().opacity(0.3).padding(.vertical, 2)

                Text("This version of SipAI does not update itself. Newly released builds check for updates automatically.",
                     comment: "Updates pane: shown when the running build is not a signed release")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
            }
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
                .font(.system(size: 14, weight: .semibold))

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
            .font(.system(size: 14))
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)

            if needsRestart {
                restartNotice
            }

            Text("Currently, SipAI only supports two languages. We will add more language support later.",
                 comment: "Language pane: only two languages ship today, more are coming")
                .font(.system(size: 13))
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
                .font(.system(size: 13))

            if hasRunningTurn {
                // No count, deliberately: a number here would need a
                // plural rule English has and Chinese does not, for a
                // fact the sidebar already shows precisely.
                Text("Agent turns in progress will be stopped.",
                     comment: "Language pane: warning before restarting while agent turns are in flight")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }

            Button {
                relaunch()
            } label: {
                Text("Restart Now", comment: "Language pane: quit and reopen the app to apply the language")
            }
            .font(.system(size: 13))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.10))
        )
        .frame(maxWidth: 420, alignment: .leading)
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
