// LeftSidebar.swift
// Local-files section, root chats, projects, agent sessions, settings.
// Each section is a DisclosureSection (see ChatListView.swift and
// AgentSessionsSection.swift) so the user can collapse what they don't need;
// Notes, Chats and Chat groups can also be hidden — their header's ⋮, and
// the switches in Settings → Display that bring them back.
// The New Chat action lives inside the Chats section (RootChatsSection),
// right under its header.
//
// Layout strategy — three bands:
//   1. Brand lockup: logo + "SipAI" wordmark, left-aligned, fixed height
//      at the top. Always drawn: the notices beside the logo take the
//      wordmark's place.
//   2. Sections column: flexible middle band that gets whatever vertical
//      room the window has left after bands 1 and 3. Sections render at
//      their natural height inside a `ScrollView` — when the combined
//      section content is shorter than the band, nothing happens; when
//      it's longer (too-short window, or long Claude Code list), the
//      user scrolls here to reach any row that would otherwise be
//      hidden. No per-section scrolling, no squeeze.
//   3. Settings button: fixed height at the bottom, always visible. It
//      opens the menu of settings sections (drawn by ContentView).
//
// While Settings is open (`AppState.settingsSection`) band 2 lists the
// settings sections instead, and band 3 is the way back.

import SwiftUI
import UniformTypeIdentifiers

struct LeftSidebar: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var agents: AgentManager
    @Environment(\.sipFontScale) private var fontScale

    /// The menu of settings sections over the Settings row. ContentView
    /// draws it; the row opens and closes it.
    @Binding var showingSettingsMenu: Bool
    @State private var rootChatsExpanded: Bool = true
    @State private var projectsExpanded: Bool = true
    @State private var agentSessionsExpanded: Bool = false
    @State private var codexSessionsExpanded: Bool = false
    @State private var kimiSessionsExpanded: Bool = false
    @State private var localFilesExpanded: Bool = false
    @State private var notesExpanded: Bool = true
    @State private var expandedProjects: Set<String> = []
    /// The section whose ⋮ → Hide is waiting on its confirmation.
    @State private var sectionToHide: SectionId? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Brand lockup — logo + wordmark, left-aligned, and the place
            // the bubble beside the cup takes the wordmark's (see
            // `SidebarNotices`). Always drawn, and not a setting: were it
            // hidden, the notices would have nowhere to go. Settings →
            // Display → Show notifications beside the logo switches those.
            SidebarHeader(showsNotices: config.display.showSidebarNotices)

            // 2. Sections column — flexible middle band, clip-on-overflow.
            //
            // While Settings is open the settings sections take the band.
            // The ordinary column stays MOUNTED under them, only hidden:
            // its "Show all" reveals, its unfolded task rows and its
            // scroll offset are view state, and leaving Settings must
            // find them as they were. Hidden by opacity, hit testing and
            // accessibility — never by `.disabled`, which would reach the
            // alerts those sections present (a rename that fails while
            // Settings is open is still reported) and grey out their
            // buttons.
            ZStack(alignment: .topLeading) {
                sectionsColumn
                    .opacity(inSettings ? 0 : 1)
                    .allowsHitTesting(!inSettings)
                    .accessibilityHidden(inSettings)
                if inSettings {
                    SettingsSidebarList()
                }
            }

            Divider().opacity(0.3)

            // 3. Settings — fixed height at the bottom, always visible;
            // the way back while Settings is open.
            if inSettings {
                backToAppButton
            } else {
                settingsButton
            }
        }
        .background(SipDesign.surface)
        // Here, not on the section: the section leaves the sidebar the
        // moment the switch is written, and an alert hung on it would
        // go with it.
        .alert(hideTitle,
               isPresented: Binding(get: { sectionToHide != nil },
                                    set: { if !$0 { sectionToHide = nil } }),
               presenting: sectionToHide) { id in
            Button {
                hideSection(id)
            } label: {
                Text("Hide",
                     comment: "Menu item on the Notes, Chats and Chat groups section headers, and the button confirming it: takes the section off the sidebar")
            }
            Button(role: .cancel) { } label: {
                Text("Cancel", comment: "Dismiss the hide-section confirmation")
            }
        } message: { _ in
            Text("Nothing is deleted. To show it again, turn it on in Settings → Display.",
                 comment: "Body of the confirmation for a sidebar section's Hide")
        }
    }

    /// "Hide “Notes” from the sidebar?" — the section named the way its
    /// header names it.
    private var hideTitle: String {
        guard let id = sectionToHide else { return "" }
        let name: String
        switch id {
        case .notes:
            name = String(localized: "Notes",
                          comment: "Sidebar section header for AI-generated notes")
        case .chats:
            name = String(localized: "Chats",
                          comment: "Sidebar section header for chats not in any project")
        case .chatGroups:
            name = String(localized: "Chat groups",
                          comment: "Sidebar section header for chat groups")
        case .files, .agentClaude, .agentCodex, .agentKimi:
            return ""
        }
        return String(localized: "Hide “\(name)” from the sidebar?",
                      comment: "Title of the confirmation for a sidebar section's Hide; placeholder is the section's name: Notes, Chats or Chat groups")
    }

    /// Hide writes the same switch Settings → Display shows, so the two
    /// can never disagree about whether a section is on.
    private func hideSection(_ id: SectionId) {
        withAnimation(.easeInOut(duration: 0.18)) {
            config.setDisplay {
                switch id {
                case .notes: $0.showNotesSection = false
                case .chats: $0.showChatsSection = false
                case .chatGroups: $0.showChatGroupsSection = false
                case .files, .agentClaude, .agentCodex, .agentKimi: break
                }
            }
        }
    }

    private var inSettings: Bool { appState.settingsSection != nil }

    /// Opens the menu of settings sections, which rises from this row
    /// (ContentView places it by the row's anchor). The download badge
    /// beside the word is how an update on offer is announced: it asks
    /// for nothing until the user looks.
    private var settingsButton: some View {
        Button {
            showingSettingsMenu.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                Text("Settings", comment: "Sidebar: open settings")
                    .font(.system(size: SipFont.sidebarRow(fontScale)))
                UpdateBadgeGlyph()
                    .font(.system(size: SipFont.sidebarRow(fontScale), weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Tinted while its menu is up, so the row reads as what opened it.
        .sidebarRowBackground(selected: showingSettingsMenu, cornerRadius: 8)
        .anchorPreference(key: SettingsMenuAnchorKey.self, value: .bounds) { $0 }
    }

    /// While Settings is open the Settings row is the way back, so the
    /// button that opens Settings and the one that leaves it are in one
    /// place. Leaving lands on whatever the centre pane showed before:
    /// Settings is a layer over the routes, not one of them
    /// (`AppState.settingsSection`).
    private var backToAppButton: some View {
        Button {
            appState.settingsSection = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                Text("Back to app",
                     comment: "Sidebar, while Settings is open: the row where Settings was. Leaves Settings and returns to whatever was open before.")
                    .font(.system(size: SipFont.sidebarRow(fontScale)))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarRowBackground(cornerRadius: 8)
    }

    /// Gap between major sections — half a sidebar row of air, so
    /// NOTES / CHATS / CHAT GROUPS / each agent group read as distinct
    /// blocks.
    private static let sectionGap: CGFloat = 15

    /// Stable ids for the reorderable top-level sections. Raw values are
    /// what `sidebar_section_order` persists — do not rename them. The
    /// declaration order is the default order.
    private enum SectionId: String, CaseIterable {
        case notes
        case files
        case chats
        case chatGroups = "chat_groups"
        case agentClaude = "agent_claude_code"
        case agentCodex = "agent_codex"
        case agentKimi = "agent_kimi"
    }

    /// Every section in the user's dragged order, the ones not on screen
    /// included — what a drag reorders (`sectionOrderBinding`), so a
    /// section hidden in Settings → Display, or an agent not listed for
    /// now, keeps its place and comes back to it. Saved for only the
    /// sections on screen, a hidden one lost its place at the next drag
    /// and came back below every other section.
    private var sectionOrder: [SectionId] {
        SidebarOrdering.apply(SectionId.allCases,
                              order: config.sidebarSectionOrder,
                              id: \.rawValue)
    }

    /// The sections that exist RIGHT NOW (Notes, Chats and Chat groups
    /// unless hidden in Settings → Display, files needs a dedicated
    /// folder, every agent must be LISTED), in that order. Filtered out
    /// of the one order rather than resolved again: a drag computes its
    /// move on `sectionOrder`, and the rows it crosses must stand in the
    /// same order there.
    private var orderedSectionIds: [SectionId] {
        var present: [SectionId] = []
        if config.display.showNotesSection { present.append(.notes) }
        if config.dedicatedFolder != nil { present.append(.files) }
        if config.display.showChatsSection { present.append(.chats) }
        if config.display.showChatGroupsSection { present.append(.chatGroups) }
        // ONE rule for all three agents, and a fourth joins it here: a
        // section is earned by being LISTED — installed, signed in and
        // not hidden (`AgentPresence`). An agent that is not lists
        // nothing; Settings → Agent Initialization, reached through the
        // ADD row below, is where it is installed, signed in or unhidden.
        //
        // Detection refreshes every few seconds, so installing or
        // signing in from a terminal surfaces the section without a
        // relaunch.
        if agents.presence(for: "claude_code").isListed { present.append(.agentClaude) }
        if agents.presence(for: "codex").isListed { present.append(.agentCodex) }
        if agents.presence(for: "kimi").isListed { present.append(.agentKimi) }
        return sectionOrder.filter(present.contains)
    }

    /// "ADD AGENTS" / "ADD MORE AGENTS" — owed while any supported
    /// agent is missing or signed out (`AgentAddRow.label`); nil when
    /// every agent is listed or hidden, or any is still pending.
    private var addRowLabel: AgentAddRow.Label? {
        AgentAddRow.label(presences: AgentManager.registry.map { agents.presence(for: $0.key) })
    }

    /// Always the LAST row of the column — the sections above it are
    /// user-reorderable, so "where the agent sections sit" names no
    /// fixed place. Styled like a section header (the same uppercase
    /// tier, a plus glyph where the chevron would be), so it reads as
    /// the next section the user could have. Not draggable, no slot in
    /// `sidebar_section_order`.
    @ViewBuilder
    private var addAgentsRow: some View {
        if let label = addRowLabel {
            Button {
                NotificationCenter.default.post(
                    name: .openSettingsTab,
                    object: nil,
                    userInfo: [SettingsView.Tab.userInfoKey: SettingsView.Tab.agents.rawValue])
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(label == .addAgents
                         ? String(localized: "Add agents",
                                  comment: "Sidebar row when no agent CLI is installed and signed in; opens Settings → Agent Initialization. Rendered uppercase like the section headers.")
                         : String(localized: "Add more agents",
                                  comment: "Sidebar row when some but not all supported agents are installed and signed in; opens Settings → Agent Initialization. Rendered uppercase like the section headers."))
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
            .sidebarRowBackground()
            .padding(.horizontal, 8)
            .padding(.bottom, Self.sectionGap)
            .help(String(localized: "Install or sign in to \(agentNamesJoined)",
                         comment: "Tooltip on the sidebar's add-agents row; placeholder is the joined list of agent names"))
        }
    }

    /// "Claude Code, Codex and Kimi Code" through the labels and the
    /// existing list joiner, so a renamed agent is renamed here too.
    private var agentNamesJoined: String {
        let names = AgentManager.registry.map {
            config.agentLabel(for: $0.key, defaultName: $0.name)
        }
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return String(localized: "\(names.dropLast().joined(separator: ", ")) and \(last)",
                      comment: "Joins the last agent name onto the list of the others: “A, B and C”")
    }

    private var sectionOrderBinding: Binding<[String]> {
        Binding(
            get: { sectionOrder.map(\.rawValue) },
            set: { config.setSidebarSectionOrder($0) }
        )
    }

    /// Middle band that holds every disclosure section — between the
    /// brand lockup above and the Settings row below.
    ///
    /// Sections render at their natural height; the wrapping
    /// `ScrollView` flexes to whatever vertical room the window has
    /// after the lockup and the Settings row are laid out. When the
    /// sections collectively fit, there's nothing to scroll; when they
    /// don't, the user scrolls here to reach rows pushed past the
    /// visible edge — so even a short window never hides a section
    /// completely.
    private var sectionsColumn: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                // Reorderable: each section's HEADER is its drag handle
                // (via the environment payload — see DisclosureSection),
                // and each whole section is a drop target, so crossing a
                // tall expanded section still reorders live.
                ForEach(orderedSectionIds, id: \.rawValue) { id in
                    sectionView(id)
                        .padding(.horizontal, 8)
                        .padding(.bottom, Self.sectionGap)
                        .environment(\.sidebarSectionDragPayload,
                                     "section:" + id.rawValue)
                        .onDrop(of: [.plainText],
                                delegate: SidebarReorderDropDelegate(
                                    itemId: id.rawValue,
                                    payloadPrefix: "section:",
                                    order: sectionOrderBinding))
                }
                addAgentsRow
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func sectionView(_ id: SectionId) -> some View {
        switch id {
        case .notes:
            NotesSection(expanded: $notesExpanded,
                         hide: { sectionToHide = .notes })
        case .files:
            LocalFilesView(expanded: $localFilesExpanded)
        case .chats:
            RootChatsSection(expanded: $rootChatsExpanded,
                             hide: { sectionToHide = .chats })
        case .chatGroups:
            ProjectsSection(expanded: $projectsExpanded,
                            expandedProjects: $expandedProjects,
                            hide: { sectionToHide = .chatGroups })
        case .agentClaude:
            AgentSessionsSection(agentKey: "claude_code",
                                 expanded: $agentSessionsExpanded)
        case .agentCodex:
            AgentSessionsSection(agentKey: "codex",
                                 expanded: $codexSessionsExpanded)
        case .agentKimi:
            AgentSessionsSection(agentKey: "kimi",
                                 expanded: $kimiSessionsExpanded)
        }
    }
}

// MARK: - The brand lockup

/// The lockup (`SidebarBrandLockup`), fed: the notice on screen and the
/// update on offer from `SidebarNotices`, and whether that update's button
/// can be used now. Observes the notices alone, plus what the button's
/// state reads — a turn starting or ending, an update winding down.
private struct SidebarHeader: View {
    let showsNotices: Bool
    @ObservedObject private var notices = SidebarNotices.shared
    @ObservedObject private var cliUpdates = AgentCLIUpdateMonitor.shared
    @EnvironmentObject private var agents: AgentManager

    var body: some View {
        SidebarBrandLockup(showsNotices: showsNotices,
                           notice: notices.current,
                           offer: notices.offer,
                           offerBlockedReason: notices.offer.flatMap(blockedReason),
                           onOpen: { notices.click($0) },
                           onOfferAction: { notices.act(on: $0) },
                           onOfferClose: { notices.close($0) })
            // Laid out under the lockup, so the driver can ask whether a
            // sheet hides it — the lockup's own frame, never a guess about
            // the window (`SidebarNotices.sheetCoversLockup`).
            .background(LockupSheetCheck())
    }

    /// The Updates pane's own rule for its Update button: never under a
    /// running turn of that tool, nor while a previous update of it is
    /// still winding down. SipAI's own button opens Sparkle's window, which
    /// is never refused here.
    private func blockedReason(_ item: UpdateBadgeItem) -> String? {
        switch item.kind {
        case .cli(let key):
            if agents.hasTurnInFlight(agentKey: key) {
                return cliUpdates.updatesAutomaticallyWhenIdle(key)
                    ? String(localized: "This tool updates by itself once the running turn finishes.",
                             comment: "Updates pane: why the Update button is disabled, when automatic updates are on")
                    : String(localized: "Finish the running turn before updating this tool.",
                             comment: "Updates pane: why the Update button is disabled")
            }
            if cliUpdates.updateInFlight(key) {
                return String(localized: "The last update of this tool is still finishing.",
                              comment: "Sidebar notice beside the logo: why its Update button is disabled while a cancelled or ending update of that tool winds down")
            }
            return nil
        case .app, .appInstall:
            return nil
        }
    }
}

/// An empty view the size of the lockup, through which the driver asks
/// whether a sheet is drawn over it. Weakly held: a lockup that is gone
/// (the sidebar hidden) answers "covered", as it did before anything could
/// be measured.
private struct LockupSheetCheck: NSViewRepresentable {
    /// Measures and nothing else: every click passes through it.
    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        SidebarNotices.shared.sheetCoversLockup = { [weak view] in
            view.map(SidebarNotices.sheetCovers) ?? true
        }
        return view
    }

    func updateNSView(_ nsView: Probe, context: Context) {}
}

// MARK: - The update badge

/// The download badge: an update on offer that the user has not looked
/// at yet, at its version (`UpdateBadge`). Drawn beside "Settings" here
/// and beside "Updates" inside Settings; Settings → Updates being on
/// screen is what clears it.
///
/// The glyph takes the font of the label it sits beside, from outside.
/// Blue — the mode chip's `SipDesign.blue` — rather than the orange of
/// a warning: an update is news, not a fault.
struct UpdateBadgeGlyph: View {
    @ObservedObject private var badge = UpdateBadge.shared

    var body: some View {
        if badge.isOwed {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(SipDesign.blue)
                .help(Self.title)
                .accessibilityLabel(Self.title)
        }
    }

    /// The tooltip AND the accessibility label — one string, so the two
    /// can never say different things.
    private static var title: String {
        String(localized: "An update is available",
               comment: "Tooltip and accessibility label on the download badge beside Settings and beside its Updates row")
    }
}
