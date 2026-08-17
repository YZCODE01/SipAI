// SipAIApp.swift
// SipAI macOS — App entry point.

import SwiftUI
import AppKit
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Delegate callbacks arrive on the main thread; the models are
        // @MainActor.
        MainActor.assumeIsolated {
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
        // Make sure the Mac app's data directory exists
        // (~/Library/Application Support/SipAI/).
        SipaiPaths.ensureDataDir()
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 1000])
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
                // sidebar open. Onboarding keeps the roomier floor its fixed
                // 420-pt cards were designed around.
                .frame(
                    minWidth: configManager.models.isEmpty ? 720 : 640,
                    minHeight: configManager.models.isEmpty ? 540 : 480
                )
                .preferredColorScheme(appState.theme.colorScheme)
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
                    // it swaps the bundle out from under one.
                    updateController.agents = agentManager
                    // Capture the login shell's environment early — API
                    // keys exported in ~/.zshrc resolve through it.
                    ShellEnvironment.warmUp()
                    configManager.reload()
                    chatManager.reload()
                    projectManager.reload()
                    agentManager.configure(bridge: mcpBridge)
                    agentManager.reload(config: configManager)
                    agentManager.startDetectionRechecks(config: configManager)
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
                    notificationCoordinator.onApprovalClicked = { sessionId, taskUuid in
                        // Session-id match first.
                        if !sessionId.isEmpty,
                           let session = agentManager.sessions.first(where: { $0.id == sessionId }) {
                            appState.openAgentSessionId = session.id
                            appState.openAgentSessionPath = session.fileURL
                            return
                        }
                        // Task-uuid (draft) match — unusual but supported:
                        // the user clicked a notification for a session that
                        // hasn't been migrated to a session_id yet.
                        if !taskUuid.isEmpty,
                           let draft = appState.pendingClaudeSessionDraft {
                            let runner = agentManager.runner(forDraft: draft)
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
                                    appState.openAgentSessionId = session.id
                                    appState.openAgentSessionPath = session.fileURL
                                }
                            }
                        }
                    }

                    // Install the focus-detection hook the bridge uses
                    // to decide whether to post a notification. Returns
                    // true only when the app is frontmost AND the
                    // visible surface matches the approval's session.
                    mcpBridge.isApprovalFocused = { req in
                        guard NSApp.isActive else { return false }
                        if let sid = req.sessionId, !sid.isEmpty {
                            return appState.openAgentSessionId == sid
                        }
                        if let tu = req.taskUuid, !tu.isEmpty,
                           let draft = appState.pendingClaudeSessionDraft {
                            let runner = agentManager.runner(forDraft: draft)
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
        .defaultSize(width: 720, height: 540)
        .commands {
            // Conventional slot: directly under "About SipAI" in the
            // app menu, which is where every Mac user already looks for
            // it. Hidden entirely — not greyed out — in a build that
            // may not update itself, because "disabled forever" invites
            // clicking to find out why.
            CommandGroup(after: .appInfo) {
                if updateController.availability.allowsUpdates {
                    Button {
                        updateController.checkForUpdates()
                    } label: {
                        Text("Check for Updates…",
                             comment: "App menu item: look for a newer version of SipAI")
                    }
                    .disabled(!updateController.canCheckForUpdates)
                }
            }
            CommandGroup(after: .sidebar) {
                Button(String(localized: "Toggle Sidebar", comment: "Menu: toggle the left sidebar")) {
                    withAnimation { appState.leftSidebarVisible.toggle() }
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }
    }
}
