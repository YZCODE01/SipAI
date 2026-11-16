// SipAIApp.swift
// SipAI macOS — App entry point.

import SwiftUI
import AppKit
import Combine
import UserNotifications

/// Activation policy + dock icon for the SPM-launched executable, plus
/// the app's QUIT contract:
///
///  * Closing the window PARKS the app — every runner, tailer and
///    scheduled-task timer keeps working, and the Dock icon reopens
///    the window with everything as it was. Quit-on-last-window-close
///    silently killed in-flight agent turns.
///  * An explicit quit INTERRUPTS running turns the way the Stop
///    button does (SIGTERM, SIGKILL if ignored) instead of orphaning
///    the children, and holds termination briefly so the signals and
///    the SIGKILL escalation actually get to run. On relaunch those
///    sessions show the derived "Interrupted" marker.
final class SipAIAppDelegate: NSObject, NSApplicationDelegate {
    /// Wired from `SipAIApp`'s onAppear — the SwiftUI `@StateObject`s
    /// aren't otherwise reachable from an adaptor-created delegate.
    weak var agentManager: AgentManager?
    /// Same wiring, so a quit can land the note the user was typing in.
    weak var notesManager: NotesManager?
    /// Same wiring again: a quit has to drop an update install that is
    /// being held for a running turn BEFORE the turns are cancelled —
    /// see `UpdateController.abandonHoldForQuit`.
    weak var updateController: UpdateController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Delegate callbacks arrive on the main thread; the models are
        // @MainActor.
        MainActor.assumeIsolated {
            // FIRST. The hold's poll runs in the common run-loop modes
            // and would fire inside the deferral below — after the
            // turns were cancelled — and resume the install with a
            // relaunch, on a quit the user asked for. Dropped here, the
            // quit ends in Sparkle's install-on-quit instead. A no-op
            // once the install is already under way, which is what a
            // quit requested BY Sparkle looks like from here.
            updateController?.abandonHoldForQuit()
            // BEFORE the early return below. The note editor autosaves
            // on a debounce, so quitting mid-sentence has up to that
            // long of typing staged and unwritten — and a quit with no
            // agent turn running never reaches any other code here.
            notesManager?.flushPendingEdits()
            guard let agents = agentManager else { return .terminateNow }
            let running = agents.runners.values.filter { $0.status.isRunning }
            guard !running.isEmpty else { return .terminateNow }
            for runner in running { runner.cancel() }
            Task { @MainActor in
                // cancel() SIGTERMs now and SIGKILLs after 3 s if
                // ignored — wait (bounded) for the children to be
                // reaped so that escalation task is still alive to
                // fire, then let the quit proceed.
                let deadline = Date().addingTimeInterval(4.5)
                while Date() < deadline,
                      agents.runners.values.contains(where: { $0.status.isRunning }) {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}

@main
struct SipAIApp: App {
    @NSApplicationDelegateAdaptor(SipAIAppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var configManager = ConfigManager()
    @StateObject private var chatManager = ChatManager()
    @StateObject private var projectManager = ProjectManager()
    @StateObject private var agentManager = AgentManager()
    @StateObject private var notesManager = NotesManager()
    @StateObject private var mcpBridge = MCPBridge()
    @StateObject private var scheduledTaskScheduler = ScheduledTaskScheduler()
    @StateObject private var updateController = UpdateController()
    private let notificationCoordinator = NotificationCoordinator()

    init() {
        // First, before anything opens it: the web cache an earlier
        // SipAI kept provider requests in — keys and chat text included.
        WebCache.removeLeftovers()
        // Make sure the Mac app's data directory exists
        // (~/Library/Application Support/SipAI/).
        SipaiPaths.ensureDataDir()
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 1000])
        // Every CLI scrape (`claude --help`, `codex features list`) runs
        // in the environment an agent child gets — an npm-installed CLI
        // is a `node` script that cannot start on the GUI app's own PATH
        // (see `CLIScrapeEnvironment`). Installed here, before any view
        // exists to trigger a scrape.
        CLIScrapeEnvironment.provider = {
            await ShellEnvironment.prepare()
            return AgentRunner.buildEnvironment()
        }
        // Codex's compressed rollouts (`.jsonl.zst`) are read through the
        // bundled zstd decoder — installed before any session is read.
        SessionFileCompression.decoder = ZstdFileDecoder.open
        SessionFileCompression.statedSize = ZstdFileDecoder.statedSize
        // Codex's speeds come from the list it saved for the account while
        // it is signed in with ChatGPT (`CodexCatalog.preferred`); the
        // sign-in is the usage window's verdict on codex's account.
        CodexCatalog.chatGPTSignIn = { UsageMonitor.shared.accounts["codex"]?.isPlan == true }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(configManager)
                .environmentObject(chatManager)
                .environmentObject(projectManager)
                .environmentObject(agentManager)
                .environmentObject(notesManager)
                .environmentObject(mcpBridge)
                .environmentObject(scheduledTaskScheduler)
                .environmentObject(updateController)
                // Configured app shrinks to 640×480, small enough that two
                // windows tile side by side on a laptop display. Below ~640
                // the agent composer's control strip starts clipping with the
                // sidebar open. The welcome page keeps the roomier floor its
                // column and button are laid out for.
                .frame(
                    minWidth: configManager.needsOnboarding ? FirstWindowSize.floor.width : 640,
                    minHeight: configManager.needsOnboarding ? FirstWindowSize.floor.height : 480
                )
                // Settings → Display → Appearance is the whole app's look:
                // every window, sheet, alert, file panel and menu takes it,
                // and going back to System reaches every view at once (see
                // `AppTheme.appearance` for why it is not SwiftUI's
                // colour-scheme preference).
                .onChange(of: appState.theme, initial: true) { _, theme in
                    NSApp.appearance = theme.appearance
                }
                // NOTE: no `.environment(\.locale, …)`. The UI language
                // is resolved by the bundle at launch from
                // `AppleLanguages` (see `AppLanguage`); overriding the
                // environment locale here would re-split the UI between
                // `Text` and `String(localized:)` and desync it from
                // AppKit's own panels.
                .onAppear {
                    // Give the delegate its quit-time reach into the
                    // agent runners (see applicationShouldTerminate).
                    appDelegate.agentManager = agentManager
                    appDelegate.notesManager = notesManager
                    // Same reason as the line above: the updater has to
                    // be able to see whether a turn is in flight before
                    // it swaps the bundle out from under one — and name
                    // the sessions those turns belong to.
                    updateController.agents = agentManager
                    updateController.config = configManager
                    appDelegate.updateController = updateController
                    // Capture the login shell's environment early — API
                    // keys exported in ~/.zshrc resolve through it.
                    ShellEnvironment.warmUp()
                    // Debug builds: if the main thread ever stops
                    // answering, write every thread's stack to
                    // ~/Library/Logs/SipAI — and touch nothing else.
                    HangCapture.start()
                    // The View menu's zoom keys, ⌘= with them — see
                    // `ZoomKeys`. Installed once; another window's
                    // onAppear finds it in place.
                    ZoomKeys.install { [weak configManager = configManager] step in
                        configManager?.zoom(step) ?? false
                    }
                    configManager.reload()
                    // Before the reload below, which prunes the unread
                    // replies of chats that are gone through it.
                    chatManager.configure(config: configManager)
                    chatManager.reload()
                    projectManager.reload()
                    agentManager.configure(bridge: mcpBridge, config: configManager)
                    // The Agent Guide's actions reach detection and
                    // config through the same weak pair.
                    AgentGuideActions.shared.configure(agents: agentManager, config: configManager)
                    // The claude catalogs write "Other models" through
                    // the config, and the first read of the installed
                    // binary — its help and its baked alias table — is
                    // started here rather than at the first composer
                    // appearance, so the rows already name what the
                    // binary resolves by the time one is drawn.
                    ClaudeCapabilities.shared.configure(config: configManager)
                    ClaudeCapabilities.shared.ensureLoaded()
                    agentManager.reload(config: configManager)
                    // A kimi session a Chat only turn left with its tools
                    // switched off (a crash between the policy write and
                    // its restore) is put right before anything else
                    // touches it.
                    agentManager.healKimiToolPolicies()
                    // And one an ACP turn left bound to ACP's runtime,
                    // which runs without its file and command tools.
                    agentManager.healKimiRuntimeBindings()
                    // Images a codex Chat only turn was handed, left
                    // behind by a crash or a force-quit. A directory
                    // walk, so not on the main thread.
                    Task.detached(priority: .utility) {
                        AgentRunner.sweepStaleCodexImageFiles()
                    }
                    agentManager.startDetectionRechecks(config: configManager)
                    // After detection, because its first pass reads the
                    // versions of whatever CLIs were just found. Asks
                    // each vendor's release endpoint at launch and then
                    // every 8 hours; re-stats the binaries every minute
                    // and when the app comes to the front, which is what
                    // notices a CLI that updated itself. The manager is how an automatic update
                    // knows to wait for a running turn of that tool.
                    AgentCLIUpdateMonitor.shared.start(config: configManager,
                                                       agents: agentManager)
                    // What the notices beside the logo ask of the app —
                    // before `noteLaunch`, which may already have
                    // something to say.
                    wireSidebarNotices()
                    // This launch may be the relaunch an update installed;
                    // if so it is said beside the logo, like a tool's.
                    updateController.noteLaunch()
                    agentManager.reloadSessions()
                    // Learn what each model alias resolves to on this
                    // machine, from what Claude Code has already
                    // recorded for this account. Kicked here as well as
                    // from the session view because a model NAME is
                    // shown in more places than that view — the
                    // scheduled-task panel's "Runs as", the composer's
                    // chip — and a picker opened before any session had
                    // been opened would otherwise read bare family
                    // names. No sessions are passed: the scan above has
                    // barely started, and this pass deliberately leaves
                    // the latch open for the one that has them.
                    ClaudeModelCatalog.refreshObservedNames(
                        config: configManager, sessionURLs: [])
                    notesManager.reload()
                    // Starts the due-check timer, migrates any leftover
                    // crontab entries into the task files, and fires a
                    // schedule missed while the app was closed.
                    scheduledTaskScheduler.start(agents: agentManager,
                                                 appState: appState)
                    appState.theme = configManager.appTheme
                    appState.language = configManager.appLanguage
                    if appState.activeModel == nil {
                        appState.activeModel = configManager.defaultModel
                    }

                    // Install the MCP notification coordinator.
                    UNUserNotificationCenter.current().delegate = notificationCoordinator
                    notificationCoordinator.onApprovalClicked = { [weak bridge = mcpBridge] requestSessionId, taskUuid in
                        // A click asks to see the session waiting on an
                        // answer. Settings is a layer over the routes, so
                        // it closes first — or the route changes under it
                        // and the card stays out of sight.
                        appState.settingsSection = nil
                        // The session the request belongs to: its own id,
                        // or the one its draft's task uuid migrated to — a
                        // session's first turn asks under the uuid for the
                        // whole turn (`MCPBridge.request(sessionId:…)`).
                        let sessionId = !requestSessionId.isEmpty
                            ? requestSessionId
                            : (bridge?.alias[taskUuid] ?? "")
                        // Session-id match first.
                        if !sessionId.isEmpty,
                           let session = agentManager.sessions.first(where: { $0.id == sessionId }) {
                            openSession(session)
                            return
                        }
                        // Task-uuid (draft) match — unusual but supported:
                        // the user clicked a notification for a session that
                        // hasn't been migrated to a session_id yet.
                        // Only a draft that has SENT has a runner, and only
                        // its runner can have asked: an unsent draft gets
                        // none here — creating one would freeze the folder
                        // the user can still change (`cachedRunner`).
                        if !taskUuid.isEmpty,
                           let draft = appState.pendingClaudeSessionDraft,
                           let runner = agentManager.cachedRunner(forDraft: draft) {
                            if runner.taskUuidForBridge == taskUuid {
                                // Already focused on the right draft; no-op.
                                return
                            }
                        }
                        // Couldn't resolve — reload sessions in case the
                        // disk scan hasn't caught up yet, and try again
                        // once. Rare path; best-effort.
                        if !sessionId.isEmpty {
                            agentManager.reloadSessions()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                if let session = agentManager.sessions.first(where: { $0.id == sessionId }) {
                                    openSession(session)
                                }
                            }
                        }
                    }

                    // Install the focus-detection hook the bridge uses
                    // to decide whether to post a notification. Returns
                    // true only when the app is frontmost AND the
                    // visible surface matches the approval's session.
                    mcpBridge.isApprovalFocused = { [weak bridge = mcpBridge] req in
                        guard NSApp.isActive else { return false }
                        // Settings replaces the centre pane: no session is
                        // on screen while it is open, whatever the routing
                        // fields still name, so a card raised meanwhile is
                        // announced like one in any other session.
                        guard appState.settingsSection == nil else { return false }
                        if let sid = bridge?.owningSessionId(of: req),
                           appState.openAgentSessionId == sid {
                            return true
                        }
                        // A first-turn request can resolve to a session id
                        // (the alias is registered on `system.init`) while
                        // the pane still shows the DRAFT: the flip to the
                        // session waits for the transcript file, which
                        // lands a beat later. The draft on screen is that
                        // session, so it is judged by its uuid — or a card
                        // the user is looking at posts a notification.
                        // Never a runner made for the occasion: an unsent
                        // draft has none, and making one would freeze the
                        // folder the user can still change.
                        if let tu = req.taskUuid, !tu.isEmpty,
                           let draft = appState.pendingClaudeSessionDraft,
                           let runner = agentManager.cachedRunner(forDraft: draft) {
                            return runner.taskUuidForBridge == tu
                        }
                        return false
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.willTerminateNotification)
                ) { _ in
                    mcpBridge.shutdown()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.didBecomeActiveNotification)
                ) { _ in
                    // Sessions created outside SipAI (a terminal
                    // `claude`, Claude Desktop) while the app was in
                    // the background have no other trigger — pick them
                    // up the moment the user comes back. The scan runs
                    // detached and generation-guarded, so a focus
                    // switch costs one bounded background pass.
                    agentManager.reloadSessions()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        // Only where macOS has no frame saved for the window — a first
        // launch; afterwards the window opens where it was left.
        .defaultWindowPlacement { _, context in
            WindowPlacement(.center,
                            size: FirstWindowSize.size(visible: context.defaultDisplay.visibleRect.size))
        }
        .commands {
            // Conventional slot: directly under "About SipAI" in the
            // app menu, which is where every Mac user already looks for
            // it. Drawn in every build, like Settings → Updates: a build
            // that may not update itself greys it out and says why on
            // hover — SwiftUI hands `.help` to the menu item's tooltip.
            // Only such a build gets the modifier: `.help("")` leaves an
            // EMPTY tooltip on the item rather than none, and a shipped
            // copy's menu must not depend on how AppKit draws that.
            CommandGroup(after: .appInfo) {
                let item = Button {
                    updateController.checkForUpdates()
                } label: {
                    Text("Check for Updates…",
                         comment: "App menu item: look for a newer version of SipAI")
                }
                .disabled(!updateController.availability.allowsUpdates
                          || !updateController.canCheckForUpdates)
                if updateController.availability.allowsUpdates {
                    item
                } else {
                    item.help(updateController.notSelfUpdatingReason)
                }
            }
            CommandGroup(after: .sidebar) {
                Button(String(localized: "Toggle Sidebar", comment: "Menu: toggle the left sidebar")) {
                    withAnimation { appState.leftSidebarVisible.toggle() }
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                Divider()
                // Settings → Display → Zoom, a size at a time. Their keys
                // are answered by `ZoomKeys`, installed at launch.
                ZoomMenuItems(setting: configManager)
                Divider()
                // Settings → Display → Agent sessions → Compact view, the
                // toolbar window's switch.
                CompactViewMenuItem(setting: configManager)
            }
        }
    }
}

// MARK: - The first window's size

/// The size the window opens at when macOS has none saved for it: about
/// 70 % of the screen's free area, held between the welcome page's floor
/// (720 × 540) and 1200 × 800, never larger than the free area itself. A
/// fixed size reads as a small window on a large display, and the window
/// that shows the welcome page is the main window once Get started is
/// clicked. Whole points: a fractional window width leaves a sub-point
/// residue in the panes' layout.
enum FirstWindowSize {
    static let floor = CGSize(width: 720, height: 540)
    static let ceiling = CGSize(width: 1200, height: 800)
    static let share: CGFloat = 0.7

    static func size(visible: CGSize) -> CGSize {
        CGSize(width: fit(visible.width, floor.width, ceiling.width),
               height: fit(visible.height, floor.height, ceiling.height))
    }

    private static func fit(_ available: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(available.rounded(.down), max(low, min(high, (available * share).rounded())))
    }
}

// MARK: - The notices beside the logo

extension SipAIApp {
    /// A session opened from outside the sidebar — a card's macOS
    /// notification, the bubble beside the logo. A scheduled run opens
    /// under its task's panel, as from its row; any other session takes
    /// down a task page left open, whose panel would otherwise stand above
    /// a transcript that is not its run.
    @MainActor
    fileprivate func openSession(_ session: AgentSession) {
        appState.openAgentSessionId = session.id
        appState.openAgentSessionPath = session.fileURL
        appState.openScheduledTaskName = session.scheduledTaskName
    }

    /// Everything `SidebarNotices` asks of the app: the switch, what keeps
    /// a notice true, what a click opens, what an update's button runs —
    /// and the cards it is told of.
    @MainActor
    fileprivate func wireSidebarNotices() {
        let notices = SidebarNotices.shared
        // Settings → Display → Show notifications beside the logo. Off,
        // nothing is queued or spoken. The logo and name the bubble takes
        // the place of are always drawn.
        notices.isEnabled = { [weak configManager] in
            configManager?.display.showSidebarNotices ?? true
        }
        notices.isStillTrue = { [weak mcpBridge, weak configManager] notice in
            switch notice.kind {
            case .needsAction:
                // A card of that session still waits, and nobody is
                // looking at it.
                guard let bridge = mcpBridge else { return false }
                let cards = bridge.pending.filter { req in
                    if case .session(let id)? = notice.target {
                        return bridge.owningSessionId(of: req) == id
                    }
                    return req.id == notice.requestId
                }
                return cards.contains { !(bridge.isApprovalFocused?($0) ?? false) }
            case .finished, .failed:
                // Not opened since: its steady dot is still on the row.
                switch notice.target {
                case .session(let id)?:
                    return configManager?.agentUnreadSessions.contains(id) ?? true
                case .chat(let slug, let project)?:
                    return configManager?.chatUnreadKeys
                        .contains(ChatManager.liveKey(slug: slug, project: project)) ?? true
                case nil:
                    return true
                }
            case .updated:
                return true
            }
        }
        notices.open = { [weak appState, notificationCoordinator] target in
            switch target {
            case .session(let id):
                // The road a click on a card's macOS notification takes:
                // Settings closes, and a session the scan has not reached
                // yet is looked for again.
                notificationCoordinator.onApprovalClicked?(id, "")
            case .chat(let slug, let project):
                guard let appState else { return }
                appState.openChatSlug = slug
                appState.openChatProject = project
                // Settings is a layer over the routes: left open, it would
                // go on covering the chat just opened.
                appState.settingsSection = nil
            }
        }
        notices.performOffer = { [weak updateController] item in
            switch item.kind {
            case .app:
                // Sparkle's own window: the release notes, and Install.
                guard let updateController, updateController.canCheckForUpdates else { return false }
                updateController.checkForUpdates()
                return true
            case .appInstall:
                updateController?.installNow()
                return true
            case .cli(let key):
                // The Updates pane's road, and the automatic update's.
                return AgentCLIUpdateMonitor.shared.startUpdate(agentKey: key)
            }
        }
        mcpBridge.onRequestShown = { [weak mcpBridge, weak agentManager] req in
            // Not for an agent that is not listed: it has no row to open.
            guard let bridge = mcpBridge, let agents = agentManager,
                  agents.isAgentReady(req.agentKey) else { return }
            // Not for a card the user is looking at: it is right there.
            if bridge.isApprovalFocused?(req) == true { return }
            let sessionId = bridge.owningSessionId(of: req)
            let names = agents.noticeNames(forSession: sessionId, agentKey: req.agentKey)
            SidebarNotices.shared.post(.needsAction(agent: names.agent, group: names.group,
                                                    sessionId: sessionId, requestId: req.id))
        }
        // What can make a notice untrue: a card answered, a session or a
        // chat opened, Settings closed over the session a card is on.
        for signal in [mcpBridge.$pending.map { _ in () }.eraseToAnyPublisher(),
                       configManager.$agentUnreadSessions.map { _ in () }.eraseToAnyPublisher(),
                       configManager.$chatUnreadKeys.map { _ in () }.eraseToAnyPublisher(),
                       appState.$openAgentSessionId.map { _ in () }.eraseToAnyPublisher(),
                       appState.$pendingClaudeSessionDraft.map { _ in () }.eraseToAnyPublisher(),
                       appState.$settingsSection.map { _ in () }.eraseToAnyPublisher()] {
            notices.watch(signal)
        }
    }
}

// The View menu's Zoom In / Zoom Out / Actual Size move this setting
// (`ZoomMenuItems`). Declared beside the menu rather than beside
// ConfigManager: the check scripts compile ConfigManager.swift without it.
extension ConfigManager: ZoomSetting {}

// Compact view's switch — the toolbar window, Settings → Display and the
// View menu (`TranscriptViewWindow.swift`) — moves this one value, for the
// same reason declared here.
extension ConfigManager: CompactViewSetting {
    var agentCompactView: Bool { display.agentCompactView }
    func setAgentCompactView(_ on: Bool) {
        setDisplay { $0.agentCompactView = on }
    }
}
