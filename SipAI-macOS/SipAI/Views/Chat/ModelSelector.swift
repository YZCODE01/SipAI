// ModelSelector.swift
// Inline model selector for the unified input card. Shows current model with a
// chevron; popover lists all configured models + an "Add Model" entry.

import SwiftUI

struct ModelSelector: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var config: ConfigManager
    @State private var showingPopover = false
    @State private var isHovered: Bool = false
    // ↑ / ↓ / Return navigation inside the popover (see ListKeyMonitor).
    @State private var keyMonitor = ListKeyMonitor()
    @State private var popoverHighlight: Int = 0

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(currentModelDisplayName())
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SipDesign.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(SipDesign.textHint)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.gray.opacity(0.2) : Color.clear)
            )
            .onHover { hovering in
                isHovered = hovering
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                if config.models.isEmpty {
                    Text("No models configured.", comment: "Model selector empty state")
                        .font(.system(size: 13))
                        .foregroundColor(SipDesign.textSecondary)
                        .padding(12)
                } else {
                    ForEach(Array(config.models.enumerated()), id: \.element.id) { idx, model in
                        HStack(spacing: 0) {
                            Button {
                                appState.activeModel = model.id
                                showingPopover = false
                            } label: {
                                HStack {
                                    Text(model.name)
                                        .font(.system(size: 13))
                                        .foregroundColor(SipDesign.textPrimary)
                                    if model.id == config.defaultModel {
                                        Text("default", comment: "Chip marking the default model")
                                            .font(.system(size: 10))
                                            .foregroundColor(SipDesign.blue)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(SipDesign.chipBg)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    Spacer()
                                    if appState.activeModel == model.id {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(SipDesign.blue)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(minWidth: 220, alignment: .leading)
                                .background(
                                    appState.activeModel == model.id
                                        ? SipDesign.cardSelectedBg
                                        : (popoverHighlight == idx
                                            ? Color.gray.opacity(0.12)
                                            : Color.clear)
                                )
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            // ⋯ sits outside the pick-button so its click
                            // never also switches the active model.
                            ModelRowActionsMenu(model: model)
                                .padding(.trailing, 8)
                        }
                    }
                }
                Rectangle()
                    .fill(SipDesign.borderLight)
                    .frame(height: 1)
                    .padding(.vertical, 4)
                Button {
                    showingPopover = false
                    NotificationCenter.default.post(name: .openModelSetup, object: nil)
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                            .foregroundColor(SipDesign.blue)
                        Text("Add Model", comment: "Model picker: open the model setup window")
                            .font(.system(size: 13))
                            .foregroundColor(SipDesign.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        popoverHighlight == config.models.count
                            ? Color.gray.opacity(0.12)
                            : Color.clear
                    )
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
            .onAppear {
                let current = appState.activeModel ?? config.defaultModel
                popoverHighlight = config.models.firstIndex(
                    where: { $0.id == current }) ?? 0
                keyMonitor.install(handlePopoverKey)
            }
            .onDisappear { keyMonitor.remove() }
        }
    }

    /// Arrows move the highlight over the model rows plus the trailing
    /// "Add Model" row; Return activates it. Consumed even while the
    /// composer's text field has focus — with the popover open, Return
    /// must pick a model, not send the draft.
    private func handlePopoverKey(_ key: ListKeyMonitor.Key,
                                  whileEditing: Bool) -> Bool {
        guard showingPopover else { return false }
        let rowCount = config.models.count + 1
        switch key {
        case .down:
            popoverHighlight = min(popoverHighlight + 1, rowCount - 1)
            return true
        case .up:
            popoverHighlight = max(popoverHighlight - 1, 0)
            return true
        case .ret:
            if popoverHighlight < config.models.count {
                appState.activeModel = config.models[popoverHighlight].id
                showingPopover = false
            } else {
                showingPopover = false
                NotificationCenter.default.post(name: .openModelSetup, object: nil)
            }
            return true
        }
    }

    private func currentModelDisplayName() -> String {
        if let id = appState.activeModel ?? config.defaultModel,
           let model = config.model(for: id) {
            return model.name
        }
        return String(localized: "No model", comment: "Model selector when nothing is configured")
    }
}

// MARK: - Project / role chips

/// Shared chip look for the project & role selectors — same text +
/// chevron + hover treatment as the model chip above.
private struct SelectorChip: View {
    let title: String
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SipDesign.textPrimary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(SipDesign.textHint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovered ? Color.gray.opacity(0.2) : Color.clear)
        )
        .onHover { hovered = $0 }
    }
}

/// One row of the project/role/note popovers: checkmark on the current
/// value, grey wash on mouse hover — the model list's row look.
/// Internal: NoteOptionsPopover (ChatView.swift) builds on it too.
struct SelectorPopoverRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(SipDesign.textPrimary)
                    .lineLimit(1)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(SipDesign.blue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minWidth: 220, alignment: .leading)
            .background(selected
                        ? SipDesign.cardSelectedBg
                        : (hovered ? Color.gray.opacity(0.12) : Color.clear))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Project chip for the unified input card: shows which project the open
/// chat lives in and moves it (nil = root "Chats") straight from the
/// chatbox. Hidden when Settings → Display turns project display off.
/// The move itself runs in ChatView (`onSelect`) — it owns the
/// loaded-identity bookkeeping the persistence invariant depends on.
struct ProjectSelector: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var projects: ProjectManager
    /// Called with the destination project slug; nil = root "Chats".
    var onSelect: (String?) -> Void

    @State private var showingPopover = false

    var body: some View {
        if config.display.showProjectName {
            Button {
                showingPopover.toggle()
            } label: {
                SelectorChip(title: projects.name(for: appState.openChatProject)
                             ?? String(localized: "No Group",
                                       comment: "Chat-group chip label when the chat is in no group"))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Change the group for this chat",
                         comment: "Tooltip for the chat-group chip"))
            .popover(isPresented: $showingPopover, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    SelectorPopoverRow(
                        title: String(localized: "Chats",
                                      comment: "Move-to target for the root (no group) scope"),
                        selected: appState.openChatProject == nil
                    ) {
                        showingPopover = false
                        onSelect(nil)
                    }
                    if !projects.projects.isEmpty {
                        Divider().padding(.vertical, 4)
                        ForEach(projects.projects) { project in
                            SelectorPopoverRow(
                                title: project.name,
                                selected: appState.openChatProject == project.slug
                            ) {
                                showingPopover = false
                                onSelect(project.slug)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// Role chip: shows the active role and switches it, or clears back to
/// the default system prompt. App-wide (`AppState.activeRole`), applied
/// to the next send.
/// Hidden when Settings → Display turns role display off.
struct RoleSelector: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var config: ConfigManager

    @State private var showingPopover = false

    var body: some View {
        if config.display.showRole {
            Button {
                showingPopover.toggle()
            } label: {
                SelectorChip(title: appState.activeRole?.name
                             ?? String(localized: "No Role",
                                       comment: "Role chip label when no role is active"))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Change the role for this chat",
                         comment: "Tooltip for the role chip"))
            .popover(isPresented: $showingPopover, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    SelectorPopoverRow(
                        title: String(localized: "No Role",
                                      comment: "Role chip label when no role is active"),
                        selected: appState.activeRole == nil
                    ) {
                        showingPopover = false
                        appState.activeRole = nil
                    }
                    if !config.roles.isEmpty {
                        Divider().padding(.vertical, 4)
                        ForEach(config.roles) { role in
                            SelectorPopoverRow(
                                title: role.name,
                                selected: appState.activeRole?.name == role.name
                            ) {
                                showingPopover = false
                                appState.activeRole = role
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

extension Notification.Name {
    /// Opens the dedicated model setup window (ModelSetupSheet) — the
    /// composer's "Add Model" path. NOT the Settings sheet.
    static let openModelSetup = Notification.Name("openModelSetup")
}
