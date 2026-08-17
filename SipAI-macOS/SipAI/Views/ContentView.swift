// ContentView.swift
// Main layout: hideable left sidebar + center pane.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var chats: ChatManager
    @EnvironmentObject var projects: ProjectManager
    @EnvironmentObject var agents: AgentManager
    @EnvironmentObject var notesManager: NotesManager
    /// Only needed so the Settings sheet can be handed it — a factory
    /// reset has to be able to drop the scheduler's run records.
    @EnvironmentObject var scheduler: ScheduledTaskScheduler

    @State private var showingSettings: Bool = false
    @State private var showingModelSetup: Bool = false
    @State private var leftToggleHovered: Bool = false
    @State private var searchHovered: Bool = false
    @State private var showingSearch: Bool = false

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

    var body: some View {
        // First-time setup: show onboarding only on a truly fresh install.
        if showOnboarding ?? (config.models.isEmpty && !config.hasCompletedSetup) {
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
                    LeftSidebar(showingSettings: $showingSettings)
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

                Spacer()
            }
            .padding(.leading, 84)
            .padding(.trailing, 14)
            .padding(.top, 8)
            .ignoresSafeArea(edges: .top)
        }
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
        .onAppear {
            if appState.activeModel == nil {
                appState.activeModel = config.defaultModel
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(config)
                .environmentObject(projects)
                .environmentObject(agents)
                .environmentObject(chats)
                .environmentObject(notesManager)
                .environmentObject(scheduler)
                .frame(minWidth: 720, minHeight: 540)
                // Sheets are separate NSWindows and do not reliably
                // inherit the main window's forced appearance.
                .preferredColorScheme(appState.theme.colorScheme)
        }
        .sheet(isPresented: $showingModelSetup) {
            ModelSetupSheet()
                .environmentObject(appState)
                .environmentObject(config)
                .preferredColorScheme(appState.theme.colorScheme)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openModelSetup)) { _ in
            showingModelSetup = true
        }
        // Re-arm the latched gate above. Forced to `true` rather than
        // back to `nil` on purpose: a reset promises first-run setup
        // outright, and re-deriving would hand that promise to whatever
        // config happens to say a moment later — the same 5 s agent
        // re-detection tick and model harvest that run on every launch
        // are writing to it. Swapping this view out also takes the
        // Settings sheet with it, which is the intended exit.
        .onReceive(NotificationCenter.default.publisher(for: .sipFactoryReset)) { _ in
            showOnboarding = true
        }
        .animation(.easeInOut(duration: 0.2), value: appState.leftSidebarVisible)
        // Font-size tier (Settings → Display) — outermost so sheets
        // presented from here inherit the same scale.
        .environment(\.sipFontScale, config.fontTier.scale)
        .environment(\.sipLineSpacingFactor, config.fontTier.lineSpacingFactor)
    }

    /// Center column — the chat / note / agent-session router. Exactly
    /// one of the four routing fields on `AppState` decides what shows;
    /// they are mutually exclusive by construction (see their `didSet`s).
    @ViewBuilder
    private var centerPane: some View {
        if appState.openNoteId != nil {
            NoteView()
        } else if appState.openAgentSessionId != nil
                  || appState.pendingClaudeSessionDraft != nil
                  // A scheduled task that has never run opens with no
                  // session at all — the panel is the whole page.
                  || appState.openScheduledTaskName != nil {
            AgentSessionView()
        } else {
            ChatView()
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
