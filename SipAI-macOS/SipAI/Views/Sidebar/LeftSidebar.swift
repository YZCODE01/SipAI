// LeftSidebar.swift
// Local-files section, root chats, projects, agent sessions, settings.
// Each section is a DisclosureSection (see ChatListView.swift and
// AgentSessionsSection.swift) so the user can collapse what they don't need.
// The New Chat action lives inside the Chats section (RootChatsSection),
// right under its header.
//
// Layout strategy — three bands:
//   1. Brand lockup: logo + "SipAI" wordmark, left-aligned, fixed height
//      at the top. Always drawn: it is where an update is said.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Brand lockup — logo + wordmark, left-aligned, and the one
            // place an update that happened is said (see
            // `SidebarBrandLockup`). Always drawn, and not a setting: were
            // it hidden, the update messages would have nowhere to go.
            // Settings → Display → Show update messages switches those.
            SidebarBrandLockup(showsUpdateMessages: config.display.showUpdateMessages)

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
    /// what `sidebar_section_order` persists — do not rename them.
    private enum SectionId: String {
        case notes
        case files
        case chats
        case chatGroups = "chat_groups"
        case agentClaude = "agent_claude_code"
        case agentCodex = "agent_codex"
        case agentKimi = "agent_kimi"
    }

    /// The sections that exist RIGHT NOW (files needs a dedicated
    /// folder, every agent must be LISTED), in the user's dragged
    /// order. Conditional sections keep their saved slot while hidden
    /// only if the user had dragged them; otherwise they reappear at
    /// their default position.
    private var orderedSectionIds: [SectionId] {
        var present: [SectionId] = [.notes]
        if config.dedicatedFolder != nil { present.append(.files) }
        present.append(contentsOf: [.chats, .chatGroups])
        // ONE rule for all three agents, and a fourth joins it here: a
        // section is earned by being LISTED — installed, signed in and
        // not hidden (`AgentPresence`). An agent that is not lists
        // nothing; Settings → Agent Guide, reached through the ADD row
        // below, is where it is installed, signed in or unhidden.
        //
        // Detection refreshes every few seconds, so installing or
        // signing in from a terminal surfaces the section without a
        // relaunch.
        if agents.presence(for: "claude_code").isListed { present.append(.agentClaude) }
        if agents.presence(for: "codex").isListed { present.append(.agentCodex) }
        if agents.presence(for: "kimi").isListed { present.append(.agentKimi) }
        return SidebarOrdering.apply(present,
                                     order: config.sidebarSectionOrder,
                                     id: \.rawValue)
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
                                  comment: "Sidebar row when no agent CLI is installed and signed in; opens Settings → Agent Guide. Rendered uppercase like the section headers.")
                         : String(localized: "Add more agents",
                                  comment: "Sidebar row when some but not all supported agents are installed and signed in; opens Settings → Agent Guide. Rendered uppercase like the section headers."))
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
            get: { orderedSectionIds.map(\.rawValue) },
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
            NotesSection(expanded: $notesExpanded)
        case .files:
            LocalFilesView(expanded: $localFilesExpanded)
        case .chats:
            RootChatsSection(searchText: "", expanded: $rootChatsExpanded)
        case .chatGroups:
            ProjectsSection(searchText: "",
                            expanded: $projectsExpanded,
                            expandedProjects: $expandedProjects)
        case .agentClaude:
            AgentSessionsSection(expanded: $agentSessionsExpanded)
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

/// The logo and the wordmark — and, for a few seconds at a time, the
/// line saying an update has happened (`UpdateAnnouncer`), in the
/// wordmark's place. Settings → Display → Show update messages turns
/// the lines off; the view checks it too, so turning it off takes a
/// line already on screen away at once.
///
/// The imageset carries separate light/dark renditions, so the catalog
/// swaps them with the effective appearance on its own.
///
/// Leading is 14 — the same line the section headers sit on (8 from the
/// section's own inset + 6 from DisclosureSection's). The rendition is
/// tight-cropped, so the FRAME's inset is the artwork's inset and no
/// compensation is needed; a rendition that reintroduced transparent
/// margin would have to be measured and subtracted here, which is how
/// this drifted off the chevrons before.
///
/// `.lastTextBaseline` puts the wordmark's BASELINE on the image's bottom
/// edge (a non-text view's baseline is its bottom), and the crop puts the
/// GLASS'S BASE on that same edge — so the cup and the S land on one line
/// and only the p's descender reaches below it. Both halves are
/// load-bearing: transparent margin under the cup floats it off the
/// baseline just as surely as swapping this for `.bottom`, which would
/// hang the descender off the glass and lift the cap-height letters
/// clear of it.
///
/// The wordmark's FRAME is laid out always, and drawn by nothing: what
/// shows — the wordmark or a line — is an overlay on that frame, aligned
/// on its last baseline. So a line of one row or three ends where the
/// glass stands, exactly as "SipAI" does, and grows upward; and the
/// header keeps the height the mark gives it, so a message moves nothing
/// below it.
///
/// The wordmark-to-mark ratio here is 28/54 (0.519). Keep the wordmark
/// on that scale if the mark's height changes again.
private struct SidebarBrandLockup: View {
    let showsUpdateMessages: Bool
    @ObservedObject private var announcer = UpdateAnnouncer.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var line: UpdateAnnouncement? {
        showsUpdateMessages ? announcer.current : nil
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            Image("SipAI-Logo-54")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: 54)
                // Decorative: the wordmark beside it already carries the
                // name, and without this VoiceOver reads the asset NAME
                // ("SipAI-Logo-54") and then the text.
                .accessibilityHidden(true)
            Self.wordmark
                .hidden()
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leadingLastTextBaseline) {
                    if let line {
                        Text(verbatim: line.text)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // A new identity per line, so the next one
                            // rolls in over the last rather than
                            // replacing its text in place.
                            .id(line.id)
                            .transition(transition)
                    } else {
                        Self.wordmark
                            .transition(transition)
                    }
                }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.85),
                   value: line?.id)
        // Laid out under the lockup, so the announcer can ask whether a
        // sheet hides it — the lockup's own frame, never a guess about
        // the window (`UpdateAnnouncer.sheetCoversLockup`).
        .background(LockupSheetCheck())
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private static var wordmark: some View {
        Text(verbatim: "SipAI")
            .font(.system(size: 28, weight: .semibold))
            .tracking(-0.4)
            .foregroundStyle(.primary)
    }

    /// In from below, out through the top, softened by a blur — the
    /// header rolls like a departures board, whichever of the two is
    /// replacing which. With Reduce Motion on, a plain cross-fade.
    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: BrandRoll(offset: 14, blur: 3, opacity: 0),
                                 identity: BrandRoll(offset: 0, blur: 0, opacity: 1)),
            removal: .modifier(active: BrandRoll(offset: -14, blur: 3, opacity: 0),
                               identity: BrandRoll(offset: 0, blur: 0, opacity: 1)))
    }
}

/// An empty view the size of the lockup, through which the announcer
/// asks whether a sheet is drawn over it. Weakly held: a lockup that is
/// gone (the sidebar hidden) answers "covered", as it did before
/// anything could be measured.
private struct LockupSheetCheck: NSViewRepresentable {
    /// Measures and nothing else: every click passes through it.
    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        UpdateAnnouncer.shared.sheetCoversLockup = { [weak view] in
            view.map(UpdateAnnouncer.sheetCovers) ?? true
        }
        return view
    }

    func updateNSView(_ nsView: Probe, context: Context) {}
}

private struct BrandRoll: ViewModifier {
    let offset: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .blur(radius: blur)
            .opacity(opacity)
    }
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
