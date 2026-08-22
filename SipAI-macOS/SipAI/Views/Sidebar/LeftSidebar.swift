// LeftSidebar.swift
// Local-files section, root chats, projects, agent sessions, settings.
// Each section is a DisclosureSection (see ChatListView.swift and
// AgentSessionsSection.swift) so the user can collapse what they don't need.
// The New Chat action lives inside the Chats section (RootChatsSection),
// right under its header.
//
// Layout strategy — three bands:
//   1. Brand lockup: logo + "SipAI" wordmark, left-aligned, fixed height
//      at the top. Optional — Settings → Display → Sidebar hides it,
//      and the middle band takes the room.
//   2. Sections column: flexible middle band that gets whatever vertical
//      room the window has left after bands 1 and 3. Sections render at
//      their natural height inside a `ScrollView` — when the combined
//      section content is shorter than the band, nothing happens; when
//      it's longer (too-short window, or long Claude Code list), the
//      user scrolls here to reach any row that would otherwise be
//      hidden. No per-section scrolling, no squeeze.
//   3. Settings button: fixed height at the bottom, always visible.

import SwiftUI
import UniformTypeIdentifiers

struct LeftSidebar: View {
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var agents: AgentManager
    @Environment(\.sipFontScale) private var fontScale

    @Binding var showingSettings: Bool
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
            // 1. Brand lockup — logo + wordmark, left-aligned. The imageset
            // carries separate light/dark renditions, so the catalog swaps
            // them with the effective appearance on its own.
            //
            // Leading is 14 — the same line the section headers sit on (8
            // from the section's own inset + 6 from DisclosureSection's).
            // The rendition is tight-cropped, so the FRAME's inset is the
            // artwork's inset and no compensation is needed; a rendition that
            // reintroduced transparent margin would have to be measured and
            // subtracted here, which is how this drifted off the chevrons
            // before.
            //
            // `.lastTextBaseline` puts the wordmark's BASELINE on the image's
            // bottom edge (a non-text view's baseline is its bottom), and the
            // crop puts the GLASS'S BASE on that same edge — so the cup and
            // the S land on one line and only the p's descender reaches below
            // it. Both halves are load-bearing: transparent margin under the
            // cup floats it off the baseline just as surely as swapping this
            // for `.bottom`, which would hang the descender off the glass and
            // lift the cap-height letters clear of it.
            //
            // The wordmark-to-mark ratio here is 28/54 (0.519). Keep the
            // wordmark on that scale if the mark's height changes again.
            //
            // Settings → Display → Sidebar can switch the whole lockup
            // off; both halves go together, since a mark with no name or
            // a name with no mark is not the brand.
            if config.display.showSidebarBrand {
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
                    Text(verbatim: "SipAI")
                        .font(.system(size: 28, weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }

            // 2. Sections column — flexible middle band, clip-on-overflow.
            // With the lockup hidden, the column inherits the 10 pt of air
            // the lockup's own top padding would otherwise provide: a
            // section header carries only 4 pt of its own, so without
            // this its hover background touches the window's top divider.
            sectionsColumn
                .padding(.top, config.display.showSidebarBrand ? 0 : 10)

            Divider().opacity(0.3)

            // 3. Settings — fixed height at the bottom, always visible.
            Button {
                showingSettings = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text("Settings", comment: "Sidebar: open settings")
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
        .background(SipDesign.surface)
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
    /// folder, every agent its CLI or session store), in the user's
    /// dragged order. Conditional sections keep their saved slot while
    /// hidden only if the user had dragged them; otherwise they
    /// reappear at their default position.
    private var orderedSectionIds: [SectionId] {
        var present: [SectionId] = [.notes]
        if config.dedicatedFolder != nil { present.append(.files) }
        present.append(contentsOf: [.chats, .chatGroups])
        // ONE rule for all three agents, and a fourth joins it here:
        // a section is earned by a CLI or a session store, and
        // store-only renders read-only. Claude Code used to be exempt —
        // its section rendered on every machine — which put a header
        // naming an agent, and a suffix claiming read-only sessions, on
        // machines that had neither the CLI nor a single session. An
        // agent nothing on this machine can reach is not a section.
        //
        // Detection refreshes every few seconds, so installing any of
        // them surfaces its section without a relaunch.
        if agents.isAgentAvailable("claude_code") { present.append(.agentClaude) }
        if agents.isAgentAvailable("codex") { present.append(.agentCodex) }
        if agents.isAgentAvailable("kimi") { present.append(.agentKimi) }
        return SidebarOrdering.apply(present,
                                     order: config.sidebarSectionOrder,
                                     id: \.rawValue)
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
