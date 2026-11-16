// The real session page, replayed: SipAI's own updates of the composer's
// chips must never be saved as the user's pick.
//
// Every app source is compiled into this program by run.sh (the app's
// `@main` dropped, and `ConfigManager` unsealed in that copy so the saves
// can be counted below). The session page is hosted offscreen under a
// throwaway home, with a stand-in claude that starts a turn and keeps it
// running. The flow is the one that miscounted: a new session's first
// message sent, its page left before the session was named, and the page
// opened again — where the model refine and the flip's seed reach the
// chips in one go. The user has picked nothing yet, so nothing may be
// saved as a pick: not the agent's starting picks for new sessions, and
// not, beyond the flip carrying the draft's picks over, the session's.
// Then the other direction, the chips pressed as a user presses them
// (through accessibility): Non-stop switched on while the turn runs, and
// an effort picked after a Stop — each saved once as the starting picks
// and once for the session, and Non-stop heard by the turn in flight.
//
//   run by run.sh: ComposerPicks <throwaway home>

import AppKit
import SwiftUI

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    print(cond ? "  ok   \(label)" : "  FAIL \(label) \(detail)")
    if !cond { failures += 1 }
}

/// Every save of a pick, counted on the way to the real store.
final class CountingConfig: ConfigManager {
    var startingPickSaves: [String] = []
    var sessionPickSaves: [String] = []
    override func setAgentLaunchOptions(_ options: AgentLaunchOptions, for agentKey: String) {
        startingPickSaves.append("\(agentKey) \(describe(options))")
        super.setAgentLaunchOptions(options, for: agentKey)
    }
    override func setAgentSessionLaunchOptions(_ options: AgentLaunchOptions,
                                               for sessionId: String) {
        sessionPickSaves.append("\(sessionId.prefix(8)) \(describe(options))")
        super.setAgentSessionLaunchOptions(options, for: sessionId)
    }
}
func describe(_ o: AgentLaunchOptions) -> String {
    "\(o.permissionMode ?? "Default")/\(o.effort ?? "Default")"
}

@MainActor func pump(_ seconds: Double) {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}
@MainActor func pump(upTo seconds: Double, until done: () -> Bool) -> Bool {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until {
        if done() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return done()
}
func editableTextViews(in view: NSView) -> [NSTextView] {
    var out: [NSTextView] = []
    if let tv = view as? NSTextView, tv.isEditable { out.append(tv) }
    for sub in view.subviews { out += editableTextViews(in: sub) }
    return out
}

// The chips, pressed as a user does — through accessibility, the way an
// assistive client presses them (`replay` says one is driving the app).

/// SwiftUI builds a hosting view's accessibility tree when it is first
/// asked for, a run-loop turn later.
@MainActor func warm(_ view: NSView) {
    _ = view.accessibilityChildren()
    pump(0.4)
}
@MainActor func ax(_ o: NSObject, _ key: String) -> String? {
    guard o.responds(to: NSSelectorFromString(key)), let v = o.value(forKey: key) else { return nil }
    let s = "\(v)"
    return s.isEmpty ? nil : s
}
@MainActor func nodes(_ o: NSObject) -> [NSObject] {
    guard o.responds(to: NSSelectorFromString("accessibilityChildren")) else { return [o] }
    let kids = (o.value(forKey: "accessibilityChildren") as? [NSObject]) ?? []
    return [o] + kids.flatMap { nodes($0) }
}
@MainActor func find(in view: NSView, _ match: (NSObject) -> Bool) -> NSObject? {
    warm(view)
    return nodes(view).first(where: match)
}
@MainActor func label(_ text: String) -> (NSObject) -> Bool {
    { ax($0, "accessibilityLabel") == text }
}
@MainActor @discardableResult func press(_ o: NSObject?) -> Bool {
    guard let o, o.responds(to: NSSelectorFromString("accessibilityPerformPress")) else { return false }
    _ = o.perform(NSSelectorFromString("accessibilityPerformPress"))
    return true
}
/// The popover the page has open, if any.
@MainActor func popover(besides window: NSWindow) -> NSWindow? {
    NSApp.windows.first { $0 !== window && $0.isVisible && "\(type(of: $0))".contains("Popover") }
}
/// Escape, as the keyboard sends it: closes a popover the way a user does.
@MainActor func escape(_ w: NSWindow) {
    guard let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: w.windowNumber, context: nil,
                                     characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                     isARepeat: false, keyCode: 53) else { return }
    w.sendEvent(esc)
    pump(0.8)
}

@MainActor func replay(home: String) {
    let project = home + "/proj"
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let appState = AppState()
    let counting = CountingConfig()
    let config: ConfigManager = counting
    let chats = ChatManager()
    let projects = ProjectManager()
    let agents = AgentManager()
    let notes = NotesManager()
    let bridge = MCPBridge()
    let scheduler = ScheduledTaskScheduler()
    // The app's launch wiring, as SipAIApp does it, minus the timers that
    // reach the network (the CLI release checks) or fire tasks.
    CLIScrapeEnvironment.provider = {
        await ShellEnvironment.prepare()
        return AgentRunner.buildEnvironment()
    }
    ShellEnvironment.warmUp()
    config.reload()
    chats.configure(config: config)
    chats.reload()
    projects.reload()
    agents.configure(bridge: bridge, config: config)
    AgentGuideActions.shared.configure(agents: agents, config: config)
    ClaudeCapabilities.shared.configure(config: config)
    ClaudeCapabilities.shared.ensureLoaded()
    agents.reload(config: config)
    agents.reloadSessions()

    // The user's own starting picks for new claude sessions.
    var autoMax = AgentLaunchOptions()
    autoMax.permissionMode = "auto"
    autoMax.effort = "max"
    config.setAgentLaunchOptions(autoMax, for: "claude_code")

    let listed = pump(upTo: 20) { agents.isAgentReady("claude_code") }
    check("the stand-in claude is found and signed in", listed)
    guard listed else { return }

    appState.pendingClaudeSessionDraft = ClaudeSessionDraft(
        cwd: URL(fileURLWithPath: project, isDirectory: true), agentKey: "claude_code")

    let page = AgentSessionView()
        .environmentObject(appState)
        .environmentObject(config)
        .environmentObject(chats)
        .environmentObject(projects)
        .environmentObject(agents)
        .environmentObject(notes)
        .environmentObject(bridge)
        .environmentObject(scheduler)
    let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1200, height: 800),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    func open() {
        window.contentView = NSHostingView(rootView: page)
        window.orderFrontRegardless()
        pump(2)
    }
    /// A detour — Settings, a chat — tears the page down.
    func leave() {
        window.contentView = NSView()
        pump(0.3)
    }

    print("a new session's first message, its page left before the session is named, then opened again")
    open()
    guard let box = editableTextViews(in: window.contentView!).first else {
        check("the composer's message box is on the page", false)
        return
    }
    window.makeFirstResponder(box)
    box.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))
    pump(0.3)
    box.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    leave()

    let named = pump(upTo: 15) {
        agents.runners.values.contains { $0.sessionId != nil && $0.sessionFileURL != nil }
    }
    check("the first turn names its session while the page is away", named)
    check("…and the page has not switched to it yet (the switch is the page's to make)",
          appState.pendingClaudeSessionDraft != nil)
    let argv = (try? String(contentsOfFile: home + "/claude-argv.log", encoding: .utf8)) ?? ""
    check("the first message went out as the chips said: Auto, Max",
          argv.contains("--permission-mode auto") && argv.contains("--effort max"), argv)

    counting.startingPickSaves = []
    counting.sessionPickSaves = []
    open()
    let switched = pump(upTo: 10) { appState.openAgentSessionId != nil }
    pump(2)
    check("opened again, the page switches to the session", switched)
    let id = appState.openAgentSessionId ?? ""
    check("no pick saved as the agent's starting picks — none was made",
          counting.startingPickSaves.isEmpty, "\(counting.startingPickSaves)")
    check("the session keeps the picks its first message went out with, saved once by the switch",
          counting.sessionPickSaves == ["\(id.prefix(8)) auto/max"], "\(counting.sessionPickSaves)")
    let saved = config.agentSessionLaunchOptions(for: id).map(describe) ?? "none"
    check("…which read back as Auto, Max", saved == "auto/max", saved)

    // The other direction: a pick the user makes is saved where it is made.
    // SwiftUI builds a page's accessibility tree only for an app an assistive
    // client is driving; this says one is, so the chips can be pressed.
    app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
    var host: NSView { window.contentView! }

    print("Non-stop switched on in the mode menu while the turn runs")
    counting.startingPickSaves = []
    counting.sessionPickSaves = []
    let running = agents.runners.values.first { $0.status.isRunning }
    var nonStopPressed = false
    press(find(in: host, label("Auto")))
    pump(1.2)
    if let pop = popover(besides: window), let content = pop.contentView {
        if let toggle = find(in: content, { ax($0, "accessibilityRole") == "AXCheckBox" }),
           ax(toggle, "accessibilityValue") == "0" {
            nonStopPressed = press(toggle)
            pump(0.8)
        }
        if let still = popover(besides: window) { escape(still) }
    }
    check("the mode menu's Non-stop switch is pressed", nonStopPressed)
    check("…the turn in flight hears it", running?.nonStop == true)
    check("…and it is the user's pick: saved once as the starting picks and once for the session",
          counting.startingPickSaves.count == 1 && counting.sessionPickSaves.count == 1
            && config.agentLaunchOptions(for: "claude_code").nonStop
            && config.agentSessionLaunchOptions(for: id)?.nonStop == true,
          "\(counting.startingPickSaves) \(counting.sessionPickSaves)")

    print("Stop, then the page left and opened again")
    counting.startingPickSaves = []
    counting.sessionPickSaves = []
    agents.runners.values.first { $0.status.isRunning }?.cancel()
    let stopped = pump(upTo: 10) { !agents.runners.values.contains { $0.status.isRunning } }
    check("the turn stops", stopped)
    pump(1)
    leave()
    open()
    check("nothing is saved as a pick by the stop or the return",
          counting.startingPickSaves.isEmpty && counting.sessionPickSaves.isEmpty,
          "\(counting.startingPickSaves) \(counting.sessionPickSaves)")
    let starting = describe(config.agentLaunchOptions(for: "claude_code"))
    let session = config.agentSessionLaunchOptions(for: id).map(describe) ?? "none"
    check("the starting picks and the session's still read Auto, Max",
          starting == "auto/max" && session == "auto/max", "\(starting) \(session)")

    print("an effort picked on its chip")
    counting.startingPickSaves = []
    counting.sessionPickSaves = []
    var lowPressed = false
    press(find(in: host, label("Max")))
    pump(1.2)
    if let pop = popover(besides: window), let content = pop.contentView {
        lowPressed = press(find(in: content, { ax($0, "accessibilityLabel")?.hasPrefix("Low") == true }))
        pump(0.8)
        if let still = popover(besides: window) { escape(still) }
    }
    check("the effort chip's Low row is pressed", lowPressed)
    check("the pick is saved as the agent's starting picks, once",
          counting.startingPickSaves == ["claude_code auto/low"], "\(counting.startingPickSaves)")
    check("…and for the session, once",
          counting.sessionPickSaves == ["\(id.prefix(8)) auto/low"], "\(counting.sessionPickSaves)")
    check("…and the chip reads it", find(in: host, label("Low")) != nil)
}

let home = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : ProcessInfo.processInfo.environment["HOME"] ?? ""
MainActor.assumeIsolated { replay(home: home) }
print(failures == 0 ? "Page: OK" : "Page: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
