// SettingsNavigation.swift
// How Settings is reached and moved through: the menu that rises from
// the sidebar's Settings row, and the list of sections the sidebar shows
// while Settings is open. The section itself is drawn in the centre pane
// by `SettingsView`; `AppState.settingsSection` says which one.

import SwiftUI

// MARK: - The Settings row's anchor

/// The sidebar's Settings row, for the menu that rises from it. An anchor
/// rather than a measured number: the menu follows the row through a
/// sidebar resize, a font-size change and the brand lockup coming and
/// going, with nothing stored to go stale.
struct SettingsMenuAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

// MARK: - A section's glyph

extension SettingsView.Tab {
    /// The glyph beside the section's name, in the menu and in the
    /// sidebar list alike.
    var symbol: String {
        switch self {
        case .models:   return "bubble.left.and.bubble.right"
        case .agents:   return "terminal"
        case .prompt:   return "text.quote"
        case .files:    return "folder"
        case .display:  return "display"
        case .labels:   return "tag"
        case .language: return "globe"
        case .updates:  return "arrow.triangle.2.circlepath"
        case .help:     return "questionmark.circle"
        }
    }
}

// MARK: - One section's label

/// A section's glyph and name — and, beside Updates, the download badge
/// (Settings → Updates being on screen is what clears it). One label for
/// the menu and the sidebar list, so the two cannot disagree about what a
/// section is called or where the badge sits.
struct SettingsSectionLabel: View {
    let tab: SettingsView.Tab
    var selected: Bool = false
    @Environment(\.sipFontScale) private var fontScale

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.symbol)
                .font(.system(size: SipFont.sidebarRow(fontScale)))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                // One column for every glyph, so the names line up
                // whatever each symbol's own width — a whole number of
                // points, so a glyph centred in it lands on a pixel.
                .frame(width: (18 * SipFont.ratio(fontScale)).rounded())
            Text(tab.title)
                .font(.system(size: SipFont.sidebarRow(fontScale)))
                .lineLimit(1)
                .truncationMode(.tail)
            if tab == .updates {
                UpdateBadgeGlyph()
                    .font(.system(size: SipFont.sidebarRow(fontScale), weight: .medium))
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - The menu over the Settings row

/// What the sidebar's Settings row opens: every section, in a column as
/// wide as the sidebar, rising from the row. Picking one opens Settings
/// there (`AppState.openSettings`). ContentView draws it as an overlay
/// over a click-anywhere-else scrim, the shape of the search palette and
/// the plan-usage window, so it can reach past the sidebar's own bounds.
///
/// Escape closes it; the arrow keys and Return drive it. The pointer and
/// the keys move ONE highlight, so the two can never light two rows.
struct SettingsLauncherMenu: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @FocusState private var focused: Bool
    @State private var highlighted: SettingsView.Tab? = nil

    private let sections = SettingsView.Tab.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(sections) { tab in
                Button {
                    open(tab)
                } label: {
                    // The sidebar list's own row inset, so the longest
                    // name — Chat Prompt and Roles — fits a menu over the
                    // default-width sidebar at every font size.
                    SettingsSectionLabel(tab: tab)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(highlighted == tab ? Color.gray.opacity(0.2) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        highlighted = tab
                    } else if highlighted == tab {
                        highlighted = nil
                    }
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(SipDesign.surface)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(SipDesign.borderLight, lineWidth: 1)
        )
        // Focus is what lets the keys reach a view with no text field in
        // it; the ring it would draw is not wanted on a menu.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onKeyPress(.downArrow) {
            move(1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            move(-1)
            return .handled
        }
        // Handled whether or not a row is lit. Left to climb, Return
        // reaches the window, where the newest approval card of the
        // session behind the scrim owns it as the default action — and
        // would allow a tool call from a menu about settings.
        .onKeyPress(.return) {
            if let tab = highlighted { open(tab) }
            return .handled
        }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Settings",
                                 comment: "Accessibility label of the menu of settings sections that rises from the sidebar's Settings row"))
    }

    private func move(_ delta: Int) {
        guard !sections.isEmpty else { return }
        let next: Int
        if let current = highlighted.flatMap({ sections.firstIndex(of: $0) }) {
            next = (current + delta + sections.count) % sections.count
        } else {
            next = delta > 0 ? 0 : sections.count - 1
        }
        highlighted = sections[next]
    }

    private func open(_ tab: SettingsView.Tab) {
        isPresented = false
        appState.openSettings(tab)
    }
}

// MARK: - The sidebar while Settings is open

/// The sidebar's middle band while Settings is open: the sections under
/// the logo, the one on screen selected, and Factory reset at the end,
/// set apart from them. The way back is the row where Settings was
/// (`LeftSidebar`), so the button that opens Settings and the one that
/// leaves it are in one place.
///
/// Factory reset's two alerts live HERE, on a view that stays up through
/// a partial wipe: `FactoryReset.perform` withholds `.sipFactoryReset` on
/// that path and Settings stays open, so the second alert — the only
/// report of what survived — has something to be presented from. On the
/// success path the notification takes the whole main layout down for
/// onboarding, and this view with it.
struct SettingsSidebarList: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var projects: ProjectManager
    @EnvironmentObject var chats: ChatManager
    @EnvironmentObject var notesManager: NotesManager
    @EnvironmentObject var agents: AgentManager
    @EnvironmentObject var scheduler: ScheduledTaskScheduler
    @Environment(\.sipFontScale) private var fontScale

    @State private var confirmingFactoryReset = false

    /// Data-directory entries a reset could not remove. Non-empty means
    /// the wipe was PARTIAL — reported rather than swallowed, because
    /// the alternative is the user believing their API keys are gone
    /// while the file holding them is still on disk.
    @State private var resetFailures: [String] = []

    var body: some View {
        // Scrolls like the section list it stands in for, so a short
        // window never hides a section.
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 2) {
                header
                ForEach(SettingsView.Tab.allCases) { tab in
                    row(tab)
                }
                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 8)
                factoryResetRow
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 15)
        }
        .frame(maxHeight: .infinity)
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

    /// Styled like the sidebar's section headers — the same uppercase
    /// tier — with no chevron: this list does not fold.
    private var header: some View {
        Text("Settings",
             comment: "Sidebar, while Settings is open: the header above its sections. Rendered uppercase like the other section headers.")
            .font(.system(size: SipFont.sidebarHeader(fontScale), weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .lineLimit(1)
            .padding(.leading, 6)
            .padding(.vertical, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ tab: SettingsView.Tab) -> some View {
        let selected = appState.settingsSection == tab
        return Button {
            appState.settingsSection = tab
        } label: {
            SettingsSectionLabel(tab: tab, selected: selected)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarRowBackground(selected: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var factoryResetRow: some View {
        Button {
            confirmingFactoryReset = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: SipFont.sidebarRow(fontScale)))
                    .foregroundStyle(.secondary)
                    .frame(width: (18 * SipFont.ratio(fontScale)).rounded())
                Text("Factory reset", comment: "Settings: factory reset button")
                    .font(.system(size: SipFont.sidebarRow(fontScale), weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarRowBackground()
    }

    /// The wipe itself lives in `FactoryReset`, so every caller runs the
    /// same sequence; all this does is report a partial failure.
    private func performFactoryReset() {
        let failed = FactoryReset.perform(config: config,
                                          projects: projects,
                                          chats: chats,
                                          notes: notesManager,
                                          agents: agents,
                                          scheduler: scheduler,
                                          appState: appState)
        // Nothing to close on success: `FactoryReset` posts
        // `.sipFactoryReset`, which re-arms ContentView's latched
        // onboarding gate and closes Settings with the main layout.
        guard !failed.isEmpty else { return }
        // Settings stays open on this path — `FactoryReset` withholds
        // the notification, which would take this view and its alert
        // down with the main layout.
        //
        // Deferred by one turn of the run loop because we are inside the
        // CONFIRMATION alert's button action: raising a second alert
        // while the first is still dismissing is how SwiftUI drops it,
        // and a dropped alert here means the user is told nothing at all.
        DispatchQueue.main.async { resetFailures = failed }
    }
}
