// ContentView.swift
// Main layout: hideable left sidebar + center pane.

import SwiftUI

/// The plan-usage coin's leading edge, reported by the coin itself.
private struct UsageCoinLeadingKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

struct ContentView: View {
    static let mainLayoutSpace = "sipMainLayout"

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var chats: ChatManager
    @EnvironmentObject var agents: AgentManager
    @EnvironmentObject var notesManager: NotesManager

    /// The menu of settings sections that rises from the sidebar's
    /// Settings row. Which section Settings shows, once open, is
    /// `AppState.settingsSection`.
    @State private var showingSettingsMenu: Bool = false
    /// A Help question to open on and scroll to, set by
    /// `.openHelpTopic`. It belongs to that one visit: cleared once
    /// Settings shows anything but Help, so a later visit opens Help
    /// plain.
    @State private var settingsHelpTopic: HelpTopic? = nil
    @State private var showingModelSetup: Bool = false
    @State private var leftToggleHovered: Bool = false
    @State private var searchHovered: Bool = false
    @State private var showingSearch: Bool = false
    /// The plan-usage coin and its window. The coin renders only while
    /// some installed agent is on a plan (`UsageMonitor.showsIcon`) —
    /// or while its window is open, so a verdict that flips mid-read
    /// never takes the button out from under the cursor.
    @ObservedObject private var usage = UsageMonitor.shared
    @State private var usageHovered: Bool = false
    @State private var showingUsage: Bool = false
    /// The coin's leading edge in the main layout's own coordinate
    /// space, read off the button itself so its window lands under it
    /// whatever the glyphs before it measure. The fallback is the sum
    /// of the insets before it, for the first pass before geometry
    /// reports.
    @State private var usageCoinLeading: CGFloat = 138
    /// The coin's tooltip AND its accessibility label — one string, so
    /// the two can never say different things. The glyph is a bare
    /// letter, which names nothing on its own.
    private var planUsageTitle: String {
        String(localized: "Plan usage",
               comment: "Tooltip for the toolbar plan-usage button")
    }

    /// User-resizable sidebar width, persisted across launches.
    /// Window-chrome preference, so UserDefaults rather than the
    /// CLI-schema config.json.
    @AppStorage("leftSidebarWidth") private var leftSidebarWidth: Double = 260

    /// Latched onboarding decision. The gate below is evaluated against
    /// live config state, so it MUST be decided once and frozen: the
    /// wizard persists providers/models mid-flow, and re-evaluating the
    /// gate on those writes unmounts the wizard after its first save.
    /// nil = not yet decided (first body evaluation decides).
    ///
    /// The latch is also why a factory reset cannot simply empty config
    /// and expect the window to follow. By the time the user reaches
    /// Settings this reads `false` — decided on launch, when the install
    /// was still configured — and it keeps reading `false` over an
    /// emptied config, leaving the promised "returns to first-run setup"
    /// as a main window with no models in it. `.sipFactoryReset` below
    /// is what re-arms it.
    @State private var showOnboarding: Bool?

    /// The open chat as ONE value, so a change of either half — the slug
    /// or its group — reaches `ChatManager.noteOpenChat` once. Empty
    /// while no chat is open.
    private var openChatKey: String {
        guard let slug = appState.openChatSlug else { return "" }
        return ChatManager.liveKey(slug: slug, project: appState.openChatProject)
    }

    var body: some View {
        // First-time setup: the welcome page, only on a fresh install
        // (`needsOnboarding` — the same gate the window's minimum size
        // reads).
        if showOnboarding ?? config.needsOnboarding {
            OnboardingView(onComplete: { showOnboarding = false })
                .environmentObject(appState)
                .environmentObject(config)
                .background(Color(nsColor: .windowBackgroundColor))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { showOnboarding = true }
        } else {
            mainLayout
                .onAppear { showOnboarding = false }
        }
    }

    private var mainLayout: some View {
        VStack(spacing: 0) {
            // Full-width divider right below the toolbar row
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 1)

            // Main content columns: left sidebar + center pane.
            HStack(spacing: 0) {
                if appState.leftSidebarVisible {
                    LeftSidebar(showingSettingsMenu: $showingSettingsMenu)
                        // ROUNDED, always. A drag writes a continuous
                        // translation, so this persists fractional, and
                        // that fraction becomes a sub-point residue in
                        // the HStack's space distribution. The residue
                        // resolves differently as the center pane's
                        // content changes, visibly nudging every glyph
                        // in the sidebar — too small to see on a filled
                        // circle, plainly visible on the crisp stems of
                        // an SF Symbol or a chevron.
                        // Rounding here (not only at the drag site) also
                        // repairs an already-persisted fractional width.
                        .frame(width: leftSidebarWidth.rounded())
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    // Inside the same `if`: with the sidebar hidden, an
                    // invisible drag strip at the window's left edge
                    // would still show a resize cursor and resize the
                    // hidden sidebar.
                    SidebarResizeHandle(width: $leftSidebarWidth,
                                        range: 190...440,
                                        sidebarEdge: .leading)
                }
                centerPane
                    // `minWidth: 0` says the pane may be proposed any
                    // width, so its CONTENT can never press back on the
                    // stack. Without it a transcript whose intrinsic
                    // minimum overshoots its share by a fraction of a
                    // point pushes the overflow outward into the
                    // sidebar's position.
                    .frame(minWidth: 0, maxWidth: .infinity,
                           maxHeight: .infinity)
            }
        }
        .background(SipDesign.surface)
        // Overlay that ignores the top safe area so it can draw
        // inside the title-bar region, right next to the traffic lights.
        .overlay(alignment: .top) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.leftSidebarVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(leftToggleHovered ? .primary : .secondary)
                        .onHover { hovering in leftToggleHovered = hovering }
                }
                .buttonStyle(.plain)
                .help(String(localized: "Toggle left sidebar", comment: "Tooltip"))

                Button {
                    showingSearch.toggle()
                    // One dropdown at a time.
                    if showingSearch { showingUsage = false }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(searchHovered || showingSearch
                                         ? .primary : .secondary)
                        .onHover { hovering in searchHovered = hovering }
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
                .help(String(localized: "Search everything",
                             comment: "Tooltip for the global search button"))
                .keyboardShortcut("f", modifiers: [.command, .shift])

                if usage.showsIcon || showingUsage {
                    Button {
                        showingUsage.toggle()
                        if showingUsage { showingSearch = false }
                    } label: {
                        // A "T", for tokens. Not a currency sign: at
                        // this size a dollar sign's strokes thin to
                        // nothing and it reads as an "S".
                        Image(systemName: "t.circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(usageHovered || showingUsage
                                             ? .primary : .secondary)
                            .onHover { hovering in usageHovered = hovering }
                    }
                    .buttonStyle(.plain)
                    // Measured BEFORE the padding, so the window aligns
                    // with the glyph and not with the gap in front of it.
                    .background(GeometryReader { geo in
                        Color.clear.preference(
                            key: UsageCoinLeadingKey.self,
                            value: geo.frame(in: .named(Self.mainLayoutSpace)).minX)
                    })
                    .padding(.leading, 4)
                    .help(planUsageTitle)
                    .accessibilityLabel(planUsageTitle)
                }

                Spacer()
            }
            .padding(.leading, 84)
            .padding(.trailing, 14)
            .padding(.top, 8)
            .ignoresSafeArea(edges: .top)
        }
        // Nothing about updates is drawn over the window. An update on
        // offer — or a SipAI install waiting for a running turn — puts
        // the download badge on Settings and on its Updates row
        // (`UpdateBadge`); an update that happened, or an install that
        // will, is said for a few seconds in place of the sidebar's
        // wordmark (`UpdateAnnouncer`).
        // Anchored under its own button rather than presented as a
        // sheet: the conversation the reader came from stays visible
        // behind it, which is usually the thing they are searching
        // relative to. `.popover` would steal focus into a separate
        // window and take the arrow keys with it.
        .overlay(alignment: .topLeading) {
            if showingSearch {
                ZStack(alignment: .topLeading) {
                    // Click-anywhere-else dismissal, the way every
                    // dropdown on this platform behaves. Deliberately
                    // untinted: a scrim would hide the conversation
                    // this palette exists to stay in front of.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showingSearch = false }
                    GlobalSearchPalette(isPresented: $showingSearch)
                        .environmentObject(appState)
                        .environmentObject(config)
                        .environmentObject(chats)
                        .environmentObject(agents)
                        .environmentObject(notesManager)
                        // Under the button it belongs to: the toolbar
                        // row draws INTO the title bar (it ignores the
                        // top safe area), while this overlay starts
                        // below it, so 8 pt lands just under the glyph.
                        .padding(.leading, 84)
                        .padding(.top, 8)
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.12), value: showingSearch)
        // The plan-usage window, the same shape as the search palette:
        // an overlay under its button over a click-anywhere-else scrim.
        .overlay(alignment: .topLeading) {
            if showingUsage {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showingUsage = false }
                    UsagePopover(isPresented: $showingUsage)
                        .environmentObject(config)
                        // Under the coin, wherever the toolbar put it.
                        .padding(.leading, usageCoinLeading)
                        .padding(.top, 8)
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.12), value: showingUsage)
        // The menu of settings sections, the same shape again: an
        // overlay over a click-anywhere-else scrim, as wide as the
        // sidebar and rising from its Settings row — placed by the row's
        // own anchor, so it follows the row through a sidebar resize.
        .overlayPreferenceValue(SettingsMenuAnchorKey.self) { anchor in
            if showingSettingsMenu, let anchor {
                GeometryReader { geo in
                    let row = geo[anchor]
                    ZStack(alignment: .bottomLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { showingSettingsMenu = false }
                        SettingsLauncherMenu(isPresented: $showingSettingsMenu)
                            .frame(width: max(0, row.width - 16))
                            .padding(.leading, row.minX + 8)
                            .padding(.bottom, max(0, geo.size.height - row.minY + 6))
                    }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.12), value: showingSettingsMenu)
        .modifier(SettingsMenuExclusivity(menu: $showingSettingsMenu,
                                          search: $showingSearch,
                                          usage: $showingUsage,
                                          sidebarVisible: appState.leftSidebarVisible))
        // The space the coin's position is measured in: the main
        // layout itself, which every overlay above shares.
        .coordinateSpace(name: Self.mainLayoutSpace)
        .onPreferenceChange(UsageCoinLeadingKey.self) { leading in
            // Only a real measurement moves it, and only by a whole
            // point — the same reason the sidebar width is rounded.
            guard leading > 0 else { return }
            let rounded = leading.rounded()
            if rounded != usageCoinLeading { usageCoinLeading = rounded }
        }
        .onAppear {
            if appState.activeModel == nil {
                appState.activeModel = config.defaultModel
            }
        }
        .sheet(isPresented: $showingModelSetup) {
            ModelSetupSheet()
                .environmentObject(appState)
                .environmentObject(config)
                .preferredColorScheme(appState.theme.colorScheme)
        }
        // What the centre pane shows, told to the two managers that own
        // the sidebar's steady dot: opening a session or a chat is what
        // reads it, and whatever is open when its run ends gets no dot.
        // Here, on the one view that is always up, because the panes
        // themselves are replaced on every detour.
        .onChange(of: appState.openAgentSessionId, initial: true) { _, id in
            agents.noteOpenSession(id)
        }
        .onChange(of: openChatKey, initial: true) { _, _ in
            chats.noteOpenChat(slug: appState.openChatSlug,
                               project: appState.openChatProject)
        }
        // And the draft: its first turn's session is the user's until
        // the pane flips to it (`AgentManager.noteOpenDraft`).
        .onChange(of: appState.pendingClaudeSessionDraft?.id, initial: true) { _, id in
            agents.noteOpenDraft(id)
        }
        // A line beside the logo that lands while Add Model is up shows at
        // once if the sheet leaves the logo in view, and waits for it to
        // close if it covers it (`UpdateAnnouncer.sheetCoversLockup`).
        // Settings is no sheet: it keeps the logo in view at the top of
        // the sidebar, so an update run from Settings → Updates is said
        // the moment it lands.
        .onChange(of: showingModelSetup) { _, showing in
            UpdateAnnouncer.shared.setSheetPresented(showing)
        }
        .onChange(of: appState.settingsSection) { _, section in
            if section != .help { settingsHelpTopic = nil }
            showingSettingsMenu = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .openModelSetup)) { _ in
            showingModelSetup = true
        }
        // A Help question opened from deep inside a view — the
        // composer's context-chip "?" — travels the same way
        // `.openModelSetup` does: the question is this view's to hold
        // until the Help page is made, and the composer is several
        // routers away from it.
        .onReceive(NotificationCenter.default.publisher(for: .openHelpTopic)) { note in
            guard let raw = note.userInfo?[HelpTopic.userInfoKey] as? String,
                  let topic = HelpTopic(rawValue: raw) else { return }
            settingsHelpTopic = topic
            appState.openSettings(.help)
        }
        // A Settings section opened from deep inside a view — the chat
        // page's "Learn more", the sidebar's ADD AGENTS row — takes the
        // same road as the Help deep link.
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsTab)) { note in
            guard let raw = note.userInfo?[SettingsView.Tab.userInfoKey] as? String,
                  let tab = SettingsView.Tab(rawValue: raw) else { return }
            settingsHelpTopic = nil
            appState.openSettings(tab)
        }
        // An agent that stops being LISTED — signed out in a terminal,
        // hidden or deleted in the Guide — takes its open page with it:
        // nothing renders a session of an unlisted agent, so the pane
        // routes back to the chat page, as it does for a deleted
        // session. Turns in flight are not killed; the transcript is
        // simply no longer shown.
        .onChange(of: agents.listedAgents) { _, listed in
            let keys = Set(listed.map(\.key))
            let openAgent: String? = {
                if let id = appState.openAgentSessionId {
                    return agents.sessions.first { $0.id == id }?.agentKey
                }
                if let draft = appState.pendingClaudeSessionDraft { return draft.agentKey }
                if let task = appState.openScheduledTaskName {
                    return agents.scheduledTasks.first { $0.name == task }?.agent
                }
                return nil
            }()
            guard let openAgent, !keys.contains(openAgent) else { return }
            appState.openAgentSessionId = nil
            appState.openAgentSessionPath = nil
            appState.pendingClaudeSessionDraft = nil
            appState.openScheduledTaskName = nil
        }
        // Re-arm the latched gate above. Forced to `true` rather than
        // back to `nil` on purpose: a reset promises first-run setup
        // outright, and re-deriving would hand that promise to whatever
        // config happens to say a moment later — the same 5 s agent
        // re-detection tick and model harvest that run on every launch
        // are writing to it. Swapping this view out also takes Settings
        // with it, which is the intended exit — and Settings is closed
        // HERE, on the success path alone (`FactoryReset` posts this
        // only when nothing survived), so the window comes back from
        // onboarding on the ordinary sidebar and centre pane. A partial
        // wipe leaves Settings open: its report is an alert on the
        // settings list.
        .onReceive(NotificationCenter.default.publisher(for: .sipFactoryReset)) { _ in
            showOnboarding = true
            appState.settingsSection = nil
            showingSettingsMenu = false
        }
        .animation(.easeInOut(duration: 0.2), value: appState.leftSidebarVisible)
        // Font-size tier (Settings → Display) — outermost so sheets
        // presented from here inherit the same scale.
        .environment(\.sipFontScale, config.fontTier.scale)
        .environment(\.sipLineSpacingFactor, config.fontTier.lineSpacingFactor)
    }

    /// Center column — the Settings / chat / note / agent-session router.
    /// While Settings is open it shows the settings section; otherwise
    /// exactly one of the four routing fields on `AppState` decides what
    /// shows, and they are mutually exclusive by construction (see their
    /// `didSet`s). Settings leaves those fields alone, so closing it
    /// lands back on whatever they name.
    @ViewBuilder
    private var centerPane: some View {
        if let section = appState.settingsSection {
            // REPLACES the pane rather than covering it. A pane left
            // standing under Settings keeps its keyboard shortcuts live —
            // an approval card's Return among them, and the transcript's
            // ⌘F — and a composer that was first responder keeps taking
            // keystrokes, all of it invisibly. Torn down here, the pane
            // comes back the way it does from any other detour: drafts
            // from `AppState`, notes flushed, turns owned by the managers.
            SettingsView(section: section, initialHelpTopic: settingsHelpTopic)
        } else if appState.openNoteId != nil {
            NoteView()
        } else if appState.openAgentSessionId != nil
                  || appState.pendingClaudeSessionDraft != nil
                  // A scheduled task's page — what its row opens — has
                  // no session at all: the panel is the whole page.
                  || appState.openScheduledTaskName != nil {
            AgentSessionView()
        } else {
            ChatView()
        }
    }
}

// MARK: - One dropdown at a time

/// The settings menu and the two toolbar dropdowns never show together:
/// opening the menu closes the search palette and the plan-usage window,
/// and either of those — a toolbar click or ⌘⇧F, which the menu's scrim
/// does not cover — closes the menu. A hidden sidebar takes the menu
/// with it, since the row it rises from is gone.
private struct SettingsMenuExclusivity: ViewModifier {
    @Binding var menu: Bool
    @Binding var search: Bool
    @Binding var usage: Bool
    let sidebarVisible: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: menu) { _, open in
                if open {
                    search = false
                    usage = false
                }
            }
            .onChange(of: search) { _, open in
                if open { menu = false }
            }
            .onChange(of: usage) { _, open in
                if open { menu = false }
            }
            .onChange(of: sidebarVisible) { _, visible in
                if !visible { menu = false }
            }
    }
}

// MARK: - Sidebar resize handle

/// The draggable boundary between a sidebar and the center pane. Renders
/// as the usual hairline divider, but carries an invisible 9-pt hit strip
/// that shows the horizontal-resize cursor and drags the bound width.
///
/// `sidebarEdge` says which side of the window the sidebar sits on:
/// dragging right grows a `.leading` sidebar but shrinks a `.trailing`
/// one.
private struct SidebarResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let sidebarEdge: HorizontalEdge

    enum HorizontalEdge { case leading, trailing }

    /// Width at drag start; nil while idle. Translation-based (rather
    /// than incremental deltas) so the handle never drifts when the
    /// clamp engages.
    @State private var dragStartWidth: Double? = nil
    @State private var hovering: Bool = false
    /// Guarantees at most one outstanding NSCursor push — hover events
    /// firing mid-drag would otherwise unbalance the cursor stack and
    /// leave the resize cursor stuck app-wide.
    @State private var cursorPushed: Bool = false

    var body: some View {
        Divider()
            .opacity(0.4)
            .overlay(
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside {
                            setResizeCursor(true)
                        } else if dragStartWidth == nil {
                            setResizeCursor(false)
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1,
                                    coordinateSpace: .global)
                            .onChanged { value in
                                if dragStartWidth == nil {
                                    dragStartWidth = width
                                }
                                let delta = sidebarEdge == .leading
                                    ? value.translation.width
                                    : -value.translation.width
                                let proposed = (dragStartWidth ?? width) + delta
                                // Whole points only: a fractional pane
                                // width leaves a sub-point residue in the
                                // window's horizontal layout that shifts
                                // every glyph in the sidebar whenever the
                                // other pane's content changes.
                                width = min(max(proposed, range.lowerBound),
                                            range.upperBound).rounded()
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                                if !hovering { setResizeCursor(false) }
                            }
                    )
            )
    }

    private func setResizeCursor(_ active: Bool) {
        if active, !cursorPushed {
            NSCursor.resizeLeftRight.push()
            cursorPushed = true
        } else if !active, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}
