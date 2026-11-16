// The real new-session page, replayed: a new session is remembered by the
// + it was started from — each group's +, and "+ New session" for no group —
// and what was set up on it (the message, the schedule, the chips, the
// skills) is still there when the user comes back to that +, as its text
// is. When nothing waits there, a group's + starts its chips like the
// group's newest session and "+ New session" from the agent's latest
// choices. Skills and a schedule belong to the one new session they were
// set on: a new session never starts with another session's skills, or the
// skills of a task made from the one before it — only with the agent's
// pinned skills — and never with a schedule.
//
// Every app source is compiled into this program by run.sh (the app's
// `@main` dropped). The page is hosted offscreen under a throwaway home,
// with a stand-in claude and two skills of the home's own. The project
// folders sit outside the temp folders, which the app files as scratch and
// lists nowhere. The controls are worked as a user works them, through what
// the page offers to accessibility: the schedule switch and its name field,
// the skill picker and its Done. What the sidebar's + buttons do is done as
// they do it — a draft carrying the +'s place — and the ways away are the
// app's own:
//
//  * Settings — the page is torn down and built again; the new session
//    stays where it was (Settings is a layer over the routes).
//  * a chat — the page is torn down AND the new session is dropped
//    (opening anything else drops it); back through the same +.
//  * another session — the page stays and switches to it; back through
//    the same +.
//
// What the page shows is read back the same way: the armed schedule's
// banner (which names the task and the skills its runs load), the chip's
// list of chosen skills, the mode and effort chips, the Non-stop switch,
// the message box.
//
// Once its first message has gone, a new session's chips are its own: a
// page built again before the session is named (Settings keeps the new
// session, and the switch to the session waits for the page), or a first
// message that ends unnamed, must not put back what its place starts with.
// The same holds for the new session an edit of a session's FIRST message
// starts (Edit this message, Create Branch): it goes on with the chips that
// message went out with — the session's own — not the agent's latest.
// And for a new session the page has moved on from before it is named
// (the group's + clicked again at once, to start the next): its chips are
// its own when it is named, the + it was started from starts the next one
// like it from the moment its message went, and reopened it shows them.
//
//   run by run.sh: NewSessionSetup <throwaway home> <project> <second project>

import AppKit
import SwiftUI

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    print(cond ? "  ok   \(label)" : "  FAIL \(label) \(detail)")
    if !cond { failures += 1 }
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

// MARK: - The page's accessibility, read and pressed

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
@MainActor func texts(in view: NSView) -> [String] {
    warm(view)
    return nodes(view).compactMap { ax($0, "accessibilityRole") == "AXStaticText" ? ax($0, "accessibilityValue") : nil }
}
@MainActor func buttonLabels(in view: NSView) -> [String] {
    warm(view)
    return nodes(view).compactMap { ax($0, "accessibilityRole") == "AXButton" ? ax($0, "accessibilityLabel") : nil }
}
@MainActor @discardableResult func press(_ o: NSObject?) -> Bool {
    guard let o, o.responds(to: NSSelectorFromString("accessibilityPerformPress")) else { return false }
    _ = o.perform(NSSelectorFromString("accessibilityPerformPress"))
    return true
}
/// An element's own named actions — what VoiceOver lists in its actions
/// menu for it.
@MainActor func actions(of o: NSObject?) -> [NSAccessibilityCustomAction] {
    guard let o, o.responds(to: NSSelectorFromString("accessibilityCustomActions")) else { return [] }
    return (o.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? []
}
/// Runs one of them by name, as VoiceOver does from that menu.
@MainActor @discardableResult func perform(_ name: String, on o: NSObject?) -> Bool {
    guard let action = actions(of: o).first(where: { $0.name == name }), let run = action.handler else { return false }
    return run()
}
@MainActor func label(_ text: String) -> (NSObject) -> Bool {
    { ax($0, "accessibilityLabel") == text }
}
@MainActor func editable<T: NSView>(_ kind: T.Type, in view: NSView) -> [T] {
    var out: [T] = []
    if let v = view as? T {
        if let t = v as? NSTextView, t.isEditable { out.append(v) }
        if let f = v as? NSTextField, f.isEditable { out.append(v) }
    }
    for sub in view.subviews { out += editable(kind, in: sub) }
    return out
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
@MainActor func typeText(_ text: String, into view: NSView, in window: NSWindow, replacing: Bool = true) {
    window.makeFirstResponder(view)
    pump(0.2)
    guard let editor = (view as? NSTextView) ?? (window.firstResponder as? NSTextView) else { return }
    if replacing { editor.selectAll(nil) } else {
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }
    editor.insertText(text, replacementRange: editor.selectedRange())
    pump(0.3)
}

/// Point at an element of the page as the pointer does — entered, then
/// moved over its middle — through the tracking areas SwiftUI's hover
/// reads: every view under the point that tracks the mouse (the hosting
/// view, and a scroll view's own inside it) is told. Its place comes from
/// the element's accessibility frame (screen coordinates), turned into the
/// window's.
@MainActor func pointAt(_ element: NSObject?, in window: NSWindow) -> Bool {
    guard let element, let root = window.contentView,
          let frame = (element.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else { return false }
    let at = NSPoint(x: frame.midX - window.frame.minX, y: frame.midY - window.frame.minY)
    func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
    var told = false
    for view in views(root) where !view.trackingAreas.isEmpty {
        let local = view.convert(at, from: nil)
        guard view.bounds.contains(local) else { continue }
        for area in view.trackingAreas where area.rect.contains(local) || area.options.contains(.inVisibleRect) {
            guard let enter = NSEvent.enterExitEvent(
                    with: .mouseEntered, location: at, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()),
                    userData: nil) else { continue }
            view.mouseEntered(with: enter)
            told = true
        }
        if let move = NSEvent.mouseEvent(
            with: .mouseMoved, location: at, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            view.mouseMoved(with: move)
        }
    }
    pump(0.8)
    return told
}

// MARK: - The rules, pure

@MainActor func pureRules() {
    print("0. The rules")
    check("a place is per agent: the same group's key differs between agents",
          NewSessionPlace.custom("Work").draftKey(agentKey: "claude_code")
            != NewSessionPlace.custom("Work").draftKey(agentKey: "codex"))
    check("…and no two places of one agent share a key",
          Set([NewSessionPlace.none, .ungrouped, .folder("/a"), .custom("a")]
                .map { $0.draftKey(agentKey: "kimi") }).count == 4)
    check("a + naming no place: its custom group, else Ungrouped while grouped by Custom, else no group",
          NewSessionPlace.of(customGroup: "Work", groupedByCustom: false) == .custom("Work")
          && NewSessionPlace.of(customGroup: nil, groupedByCustom: true) == .ungrouped
          && NewSessionPlace.of(customGroup: nil, groupedByCustom: false) == NewSessionPlace.none)

    func session(_ id: String, folder: String, hoursAgo: Double,
                 origin: AgentSessionOrigin = .user) -> AgentSession {
        var s = AgentSession(id: id, fileURL: URL(fileURLWithPath: "/x/\(id).jsonl"), title: id,
                             modifiedAt: Date(), projectPath: URL(fileURLWithPath: folder))
        s.lastUserMessageAt = Date().addingTimeInterval(-hoursAgo * 3600)
        s.origin = origin
        return s
    }
    let rows = [
        session("old", folder: "/p", hoursAgo: 3),
        session("new", folder: "/p", hoursAgo: 2),
        session("terminal", folder: "/p", hoursAgo: 1),
        session("child", folder: "/p", hoursAgo: 0.5, origin: .subagent),
        session("loose", folder: "/q", hoursAgo: 0.2),
        session("lost", folder: "/q", hoursAgo: 0.1),
    ]
    let assignments = ["old": "Work", "new": "Work", "terminal": "Work", "child": "Work",
                       "lost": "Gone"]
    let driven: (String) -> Bool = { $0 != "terminal" }
    func newest(_ place: NewSessionPlace) -> String? {
        place.newestSession(among: rows, customGroups: ["Work"],
                            assignments: assignments, hasSetup: driven)?.id
    }
    check("a group's + starts like its newest session SipAI drove — not one run in a terminal, not a subagent",
          newest(.custom("Work")) == "new")
    check("…a folder's by its path",
          newest(.folder("/p")) == "new" && newest(.folder("/q")) == "lost")
    check("…Ungrouped's: no group, or a group that is gone",
          newest(.ungrouped) == "lost")
    check("…and no group has no newest session (the agent's latest answers)",
          newest(.none) == nil && newest(.custom("Missing")) == nil)

    // A new session whose first message has gone, with no session id yet.
    var sentChips = AgentLaunchOptions()
    sentChips.permissionMode = "plan"
    sentChips.effort = "medium"
    func unnamed(group: String?, folder: String, minutesAgo: Double) -> UnnamedNewSession {
        var draft = ClaudeSessionDraft(cwd: URL(fileURLWithPath: folder), agentKey: "claude_code",
                                       customGroup: group,
                                       place: group.map { NewSessionPlace.custom($0) } ?? .ungrouped)
        draft.sentOptions = sentChips
        return UnnamedNewSession(draft: draft, sentAt: Date().addingTimeInterval(-minutesAgo * 60))
    }
    var savedChips = AgentLaunchOptions()
    savedChips.permissionMode = "auto"
    func start(_ place: NewSessionPlace, _ waiting: [UnnamedNewSession])
    -> (options: AgentLaunchOptions, session: AgentSession?)? {
        place.startingSetup(among: rows, unnamed: waiting, customGroups: ["Work"],
                            assignments: assignments,
                            setup: { driven($0) ? savedChips : nil })
    }
    let fresh = unnamed(group: "Work", folder: "/p", minutesAgo: 1)
    check("a new session sent from a group's + is the group's newest from the moment its message went, before it is named",
          start(.custom("Work"), [fresh])?.options == sentChips && start(.custom("Work"), [fresh])?.session == nil)
    check("…its folder's too, and it is no other group's",
          start(.folder("/p"), [fresh])?.options == sentChips
          && start(.ungrouped, [fresh])?.session?.id == "lost")
    check("…and only while it is the newest: a session written to since answers",
          start(.custom("Work"), [unnamed(group: "Work", folder: "/p", minutesAgo: 300)])?.session?.id == "new")
    check("…with nothing waiting, the group's newest session SipAI drove, as before",
          start(.custom("Work"), [])?.session?.id == "new" && start(.custom("Work"), [])?.options == savedChips)
    check("…one sent with no group is Ungrouped's",
          start(.ungrouped, [unnamed(group: nil, folder: "/q", minutesAgo: 0.01)])?.options == sentChips)

    // Codex keeps a session's speed in some modes; that session's chips
    // show the speed it keeps.
    check("a codex session's kept speed is the speed a new session takes from it",
          CodexKeptSpeed.startingTier(pick: "ultrafast", saved: .tier("priority")) == "priority")
    check("…standard kept is standard, spelled for codex",
          CodexKeptSpeed.startingTier(pick: "priority", saved: .tier(nil)) == "default")
    check("…and with nothing kept on record, the session's own pick",
          CodexKeptSpeed.startingTier(pick: "priority", saved: .unknown) == "priority"
          && CodexKeptSpeed.startingTier(pick: nil, saved: .unknown) == nil)

    // What is changed on an unsent new session is kept chip by chip.
    var groupStart = AgentLaunchOptions()
    groupStart.permissionMode = "plan"
    groupStart.model = "opus"
    groupStart.effort = "max"
    var edits = NewSessionChipEdits()
    var lowered = groupStart
    lowered.effort = "low"
    edits.note(from: groupStart, to: lowered)
    var later = groupStart
    later.permissionMode = "auto"
    later.model = "sonnet"
    let knowsNothing: (String?) -> ModelOffer = { _ in ModelOffer() }
    let laid = edits.applied(to: later, offer: knowsNothing)
    check("a chip changed on a new session is kept, and the chips left alone follow a newer start",
          laid.effort == "low" && laid.permissionMode == "auto" && laid.model == "sonnet",
          "\(laid)")
    check("…a start with nothing changed stands as it was",
          NewSessionChipEdits().applied(to: later, offer: { _ in ModelOffer(efforts: []) }) == later)
    var offTheStart = edits
    var plainAgain = lowered
    plainAgain.effort = "max"
    offTheStart.note(from: lowered, to: plainAgain)
    var laterHigh = later
    laterHigh.effort = "high"
    check("…a chip changed and changed back is still the user's (Max kept over a newer start's High)",
          offTheStart.applied(to: laterHigh, offer: knowsNothing).effort == "max")

    // Where the kept chips and the start mix, the result is fitted to the
    // model it lands on.
    let sonnetLevels: (String?) -> ModelOffer = { model in
        model == "sonnet" ? ModelOffer(efforts: ["low", "medium", "high"]) : ModelOffer()
    }
    var keptModel = NewSessionChipEdits()
    var toSonnet = groupStart
    toSonnet.model = "sonnet"
    keptModel.note(from: groupStart, to: toSonnet)
    check("a model kept over a start whose effort it does not offer: that effort goes back to Default",
          keptModel.applied(to: groupStart, offer: sonnetLevels).effort == nil
          && keptModel.applied(to: groupStart, offer: sonnetLevels).model == "sonnet")
    var startHigh = groupStart
    startHigh.effort = "high"
    check("…and one it offers follows the start",
          keptModel.applied(to: startHigh, offer: sonnetLevels).effort == "high")
    var keptMax = NewSessionChipEdits()
    keptMax.note(from: startHigh, to: groupStart)
    var startSonnet = startHigh
    startSonnet.model = "sonnet"
    check("an effort kept over a start whose model does not offer it goes back to Default",
          keptMax.applied(to: startSonnet, offer: sonnetLevels).effort == nil)
    check("…and nothing is dropped on what is not known (a catalog still loading)",
          keptMax.applied(to: startSonnet, offer: knowsNothing).effort == "max")
    var mixedSpeed = NewSessionChipEdits()
    var fast = groupStart
    fast.serviceTier = "ultrafast"
    mixedSpeed.note(from: groupStart, to: fast)
    let lists: (String?) -> ModelOffer = { _ in ModelOffer(tiers: ["priority"]) }
    check("a codex speed the model does not list goes back to Default; one it lists stays",
          mixedSpeed.applied(to: groupStart, offer: lists).serviceTier == nil
          && mixedSpeed.applied(to: groupStart, offer: { _ in ModelOffer(tiers: ["priority", "ultrafast"]) })
              .serviceTier == "ultrafast")

    // The rule a model pick and a laid-over start share.
    var all = AgentLaunchOptions()
    all.effort = "max"
    all.fastMode = true
    all.serviceTier = "fast"
    let none = all.fitted(to: ModelOffer(efforts: ["low"], fastMode: false, tiers: ["flex"]))
    check("fitted drops an effort, fast mode and a speed the model does not offer",
          none.effort == nil && !none.fastMode && none.serviceTier == nil, "\(none)")
    var standard = all
    standard.serviceTier = CodexSpeed.standard
    check("…keeps codex's \"fast\" where the model lists its tier (priority), and Standard always",
          all.fitted(to: ModelOffer(tiers: ["priority"])).serviceTier == "fast"
          && standard.fitted(to: ModelOffer(tiers: [])).serviceTier == CodexSpeed.standard)
    check("…and drops nothing it is not told about", all.fitted(to: ModelOffer()) == all)
}

// MARK: - The replay

@MainActor func replay(home: String, project: String, project2: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // SwiftUI builds a page's accessibility tree only for an app an
    // assistive client is driving; this says one is.
    app.setValue(true, forKey: "accessibilityEnhancedUserInterface")

    // Three sessions in the group "Work", in `project`: an older one and a
    // newer one SipAI drove (their setups on record), and the newest, run
    // only in a terminal (none on record). Written before the first scan.
    let claudeDir = home + "/.claude/projects/" + project.replacingOccurrences(
        of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
    try? FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
    func writeSession(_ id: String, hoursAgo: Double, text: String) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-hoursAgo * 3600))
        let records = [
            #"{"type":"user","uuid":"\#(UUID().uuidString.lowercased())","parentUuid":null,"isSidechain":false,"sessionId":"\#(id)","cwd":"\#(project)","timestamp":"\#(stamp)","message":{"role":"user","content":"\#(text)"}}"#,
            #"{"type":"assistant","uuid":"\#(UUID().uuidString.lowercased())","parentUuid":null,"isSidechain":false,"sessionId":"\#(id)","cwd":"\#(project)","timestamp":"\#(stamp)","message":{"id":"msg_\#(id.prefix(8))","type":"message","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"Done."}],"usage":{"input_tokens":10,"output_tokens":5}}}"#,
        ]
        let url = URL(fileURLWithPath: claudeDir + "/\(id).jsonl")
        try? (records.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    let olderId = UUID().uuidString.lowercased()
    let newerId = UUID().uuidString.lowercased()
    let terminalId = UUID().uuidString.lowercased()
    let olderURL = writeSession(olderId, hoursAgo: 3, text: "an older session")
    _ = writeSession(newerId, hoursAgo: 2, text: "a newer session")
    _ = writeSession(terminalId, hoursAgo: 1, text: "a session run in a terminal")

    let appState = AppState()
    let config = ConfigManager()
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

    // A turn must reach the stand-in and nothing else: on a Mac whose
    // own claude sits earlier on the search path, a message sent here
    // would be a real, billed turn.
    let claude = AgentManager.binaryPath(for: "claude_code") ?? "none"
    check("the claude this run would start is the stand-in", claude == home + "/.local/bin/claude", claude)
    guard claude == home + "/.local/bin/claude" else { return }
    let listed = pump(upTo: 20) { agents.isAgentReady("claude_code") }
    check("the stand-in claude is found and signed in", listed)
    guard listed else { return }

    let agent = "claude_code"
    _ = config.addAgentCustomGroup("Work", for: agent)
    for id in [olderId, newerId, terminalId] { config.setAgentSessionGroup("Work", for: id) }
    var olderSetup = AgentLaunchOptions()
    olderSetup.permissionMode = "auto"
    olderSetup.effort = "low"
    config.setAgentSessionLaunchOptions(olderSetup, for: olderId)
    var newerSetup = AgentLaunchOptions()
    newerSetup.permissionMode = "plan"
    newerSetup.effort = "high"
    config.setAgentSessionLaunchOptions(newerSetup, for: newerId)
    config.setAgentSessionSkillPicks(["extra"], for: newerId)
    agents.reloadSessions()
    let scanned = pump(upTo: 20) {
        agents.regularSessions(for: agent).contains { $0.id == newerId }
    }
    check("the group's sessions are listed", scanned)

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
    var host: NSView { window.contentView! }

    func open() {
        window.contentView = NSHostingView(rootView: page)
        window.orderFrontRegardless()
        pump(2.5)
    }
    func leave() {
        window.contentView = NSView()
        pump(0.4)
    }
    /// What a + does: a new session carrying the +'s place.
    func newSession(at place: NewSessionPlace, in folder: String, group: String? = nil) {
        appState.pendingClaudeSessionDraft = ClaudeSessionDraft(
            cwd: URL(fileURLWithPath: folder, isDirectory: true), agentKey: agent,
            customGroup: group, place: place)
    }
    func newSession() { newSession(at: .none, in: project) }
    func awayToSettingsAndBack() {
        leave()
        open()
    }
    func awayToChat() {
        appState.openChatSlug = "a-chat"
        leave()
    }
    func awayToChatAndBack(to place: NewSessionPlace = .none, in folder: String? = nil,
                           group: String? = nil) {
        awayToChat()
        newSession(at: place, in: folder ?? project, group: group)
        open()
    }
    /// Answers whether the other session showed an armed schedule.
    func awayToSessionAndBack() -> Bool {
        appState.openAgentSessionId = olderId
        appState.openAgentSessionPath = olderURL
        pump(2.5)
        let armedThere = banner() != nil
        newSession()
        pump(2.5)
        return armedThere
    }

    func box() -> NSTextView? { editable(NSTextView.self, in: host).first }
    func message() -> String { box()?.string ?? "<no box>" }
    func write(_ text: String, appending: Bool = false) {
        guard let box = box() else { return }
        typeText(text, into: box, in: window, replacing: !appending)
    }
    func send() {
        guard let box = box() else { return }
        window.makeFirstResponder(box)
        box.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        pump(0.5)
    }
    /// The armed schedule's banner: it names the task, the folder, the
    /// timing and the skills each run loads.
    func banner() -> String? {
        find(in: host, { ax($0, "accessibilityHelp") == "Open schedule options" })
            .flatMap { ax($0, "accessibilityLabel") }
    }
    func armSchedule(named name: String) {
        let control = find(in: host, { ax($0, "accessibilityIdentifier") == "calendar.badge.clock" })
            ?? find(in: host, { ax($0, "accessibilityHelp") == "Open schedule options" })
        press(control)
        pump(1.2)
        guard let pop = popover(besides: window), let content = pop.contentView else { return }
        if let toggle = find(in: content, { ax($0, "accessibilityRole") == "AXCheckBox" }),
           ax(toggle, "accessibilityValue") == "0" {
            press(toggle)
            pump(0.8)
        }
        if let field = editable(NSTextField.self, in: content).first {
            typeText(name, into: field, in: pop)
        }
        escape(pop)
    }
    func skillChip() -> NSObject? { find(in: host, label("Skills")) }
    /// The skills the chip lists as chosen: it opens on that list when
    /// some are, and on the picker when none are.
    func chosenSkills() -> [String]? {
        press(skillChip())
        pump(1.2)
        guard let pop = popover(besides: window), let content = pop.contentView else { return nil }
        let shown = texts(in: content)
        escape(pop)
        guard shown.contains("Chosen skills") else { return [] }
        return ["demo", "extra"].filter(shown.contains)
    }
    /// Pick an effort through its chip, as a user does: the chip that
    /// reads `from` opens its rows, and the row reading `to` is pressed.
    func pickEffort(from: String, to: String) {
        press(find(in: host, label(from)))
        pump(1.2)
        guard let pop = popover(besides: window), let content = pop.contentView else { return }
        press(find(in: content, { ax($0, "accessibilityLabel")?.hasPrefix(to) == true }))
        pump(0.8)
        if let still = popover(besides: window) { escape(still) }
    }
    /// Pick a mode through its chip, the way `pickEffort` picks an effort.
    func pickMode(from: String, to: String) {
        press(find(in: host, label(from)))
        pump(1.2)
        guard let pop = popover(besides: window), let content = pop.contentView else { return }
        press(find(in: content, { ax($0, "accessibilityLabel")?.hasPrefix(to) == true }))
        pump(0.8)
        if let still = popover(besides: window) { escape(still) }
    }
    /// Tick or untick a skill and press Done.
    func toggleSkill(_ name: String) {
        press(skillChip())
        pump(1.2)
        guard let pop = popover(besides: window), let content = pop.contentView else { return }
        if texts(in: content).contains("Chosen skills") {
            press(find(in: content, label("Edit")))
            pump(1.0)
        }
        press(find(in: content, label(name)))
        pump(0.6)
        press(find(in: content, label("Done")))
        pump(1.0)
        if let still = popover(besides: window) { escape(still) }
    }
    /// The Non-stop switch, as the mode chip's menu shows it.
    func nonStopShown(modeChip: String) -> Bool? {
        press(find(in: host, label(modeChip)))
        pump(1.2)
        guard let pop = popover(besides: window), let content = pop.contentView else { return nil }
        let value = find(in: content, { ax($0, "accessibilityRole") == "AXCheckBox" })
            .flatMap { ax($0, "accessibilityValue") }
        escape(pop)
        if let still = popover(besides: window) { escape(still) }
        return value.map { $0 == "1" }
    }

    print("1. A new session set up under + New session: a message, a schedule, a skill")
    newSession()
    open()
    write("check the build")
    armSchedule(named: "daily-check")
    toggleSkill("demo")
    let setUp = banner() ?? ""
    check("the banner names the task and the skill its runs load",
          setUp.contains("daily-check") && setUp.contains("each run loads demo"), setUp)
    check("the chip lists the skill as chosen", chosenSkills() == ["demo"])

    print("2. Away to Settings and back (the page is built again; the new session stays)")
    awayToSettingsAndBack()
    check("the message is still in the box", message() == "check the build", message())
    check("the schedule is still set up, as it was", banner() == setUp, banner() ?? "no banner")
    check("the skill is still chosen", chosenSkills() == ["demo"])

    print("3. Away to a chat and back through + New session (the new session is dropped)")
    awayToChatAndBack()
    check("the message is still in the box", message() == "check the build", message())
    check("the schedule is still set up, as it was", banner() == setUp, banner() ?? "no banner")
    check("the skill is still chosen", chosenSkills() == ["demo"])

    print("4. Away to another session and back through + New session (the page stays)")
    let armedThere = awayToSessionAndBack()
    check("the other session shows no schedule — a session that exists cannot become a task", !armedThere)
    check("back on the new session, the message is still in the box", message() == "check the build", message())
    check("the schedule is still set up, as it was", banner() == setUp, banner() ?? "no banner")
    check("the skill is still chosen", chosenSkills() == ["demo"])

    print("5. Each + keeps its own: another folder's + holds none of it, and this one's is still there")
    awayToChatAndBack(to: .folder(project2), in: project2)
    check("the other folder's new session has an empty box and no schedule",
          message().isEmpty && banner() == nil, "\(message()) / \(banner() ?? "no banner")")
    check("…and no skill — the skill chosen on + New session's is that new session's alone",
          chosenSkills() == [])
    write("work in the other folder")
    awayToChatAndBack()
    check("+ New session still holds its own message and schedule",
          message() == "check the build" && banner() == setUp, "\(message()) / \(banner() ?? "no banner")")
    awayToChatAndBack(to: .folder(project2), in: project2)
    check("…and the other folder's + its own", message() == "work in the other folder", message())

    print("6. Send creates the task as it was set up, and uses the setup up")
    awayToChatAndBack()
    if banner() == setUp {
        send()
        let taskFile = home + "/.claude/scheduled-tasks/daily-check/SKILL.md"
        let created = pump(upTo: 10) { FileManager.default.fileExists(atPath: taskFile) }
        let file = (try? String(contentsOfFile: taskFile, encoding: .utf8)) ?? ""
        check("the task is created", created)
        check("…with the message as its prompt and the skill its runs load",
              file.contains("check the build") && file.range(of: #"(?m)^skills:.*demo"#, options: .regularExpression) != nil,
              file)
        let argv = (try? String(contentsOfFile: home + "/claude-argv.log", encoding: .utf8)) ?? ""
        check("…and no turn is started", argv.isEmpty, argv)
        pump(1)
        check("the banner and the message are gone", banner() == nil && message().isEmpty,
              "\(banner() ?? "no banner") / \(message())")
        check("…and the skill: the task took it along", chosenSkills() == [])
        awayToChatAndBack()
        check("…and do not come back after a trip away", banner() == nil && message().isEmpty,
              "\(banner() ?? "no banner") / \(message())")
        check("…the skill neither", chosenSkills() == [])
    } else {
        check("(the rest of 6 needs the schedule set up — not reached)", false)
    }

    print("7. A message sent takes the skill along; the next + New session starts without it")
    if chosenSkills() != ["demo"] { toggleSkill("demo") }
    write("hello")
    send()
    let sentWithSkill = pump(upTo: 15) {
        let stdin = (try? String(contentsOfFile: home + "/claude-stdin.log", encoding: .utf8)) ?? ""
        return stdin.split(separator: "\n").contains { $0.contains("\"shouldQuery\":false") && $0.contains("demo") }
    }
    check("the message went out with the skill", sentWithSkill)
    _ = pump(upTo: 10) { appState.openAgentSessionId != nil }
    awayToChatAndBack()
    check("the next + New session starts with no skill — the one just sent took its own", chosenSkills() == [])
    check("…no schedule and no message", banner() == nil && message().isEmpty,
          "\(banner() ?? "no banner") / \(message())")

    print("8. A group's + starts its chips like the group's newest session, and nothing else")
    awayToChatAndBack(to: .custom("Work"), group: "Work")
    let chips = buttonLabels(in: host)
    check("its mode and effort — the newest session SipAI drove, not the one run in a terminal",
          chips.contains("Plan") && chips.contains("High"), "\(chips)")
    check("…but not its skills", chosenSkills() == [])
    check("…and no schedule, no message", banner() == nil && message().isEmpty,
          "\(banner() ?? "no banner") / \(message())")
    var newestNow = newerSetup
    newestNow.effort = "max"
    config.setAgentSessionLaunchOptions(newestNow, for: newerId)
    awayToChatAndBack(to: .custom("Work"), group: "Work")
    check("left untouched, the group's + follows a change made since in its newest session",
          buttonLabels(in: host).contains("Max"), "\(buttonLabels(in: host))")
    config.setAgentSkillPreload("demo", on: true, for: agent)
    awayToChatAndBack(to: .custom("Work"), group: "Work")
    check("a pinned skill is what a new session starts with", chosenSkills() == ["demo"])

    print("9. What was set on a group's new session stays with that group")
    toggleSkill("extra")
    pickEffort(from: "Max", to: "Low")
    check("the effort picked on it shows", buttonLabels(in: host).contains("Low"), "\(buttonLabels(in: host))")
    write("work message")
    awayToChatAndBack(to: .custom("Work"), group: "Work")
    check("the group's + brings back its message", message() == "work message", message())
    check("…the skills set on it", chosenSkills() == ["demo", "extra"])
    check("…and the effort picked on it, over its newest session's",
          buttonLabels(in: host).contains("Low") && !buttonLabels(in: host).contains("Max"),
          "\(buttonLabels(in: host))")

    print("9b. Only the chips changed on it are kept: the others follow the group's newest session as it moves on")
    var movedOn = newestNow
    movedOn.permissionMode = "auto"
    config.setAgentSessionLaunchOptions(movedOn, for: newerId)
    awayToChatAndBack(to: .custom("Work"), group: "Work")
    let followed = buttonLabels(in: host)
    check("the effort picked on it stays (Low), and the mode it never touched follows the group's newest session (Auto, not Plan)",
          followed.contains("Low") && followed.contains("Auto") && !followed.contains("Plan"), "\(followed)")
    config.setAgentSessionLaunchOptions(newestNow, for: newerId)
    awayToChatAndBack()
    check("+ New session holds none of it", message().isEmpty, message())

    print("10. A renamed group's waiting new session goes with the name")
    awayToChatAndBack(to: .custom("Work"), group: "Work")
    // What the sidebar's rename does: the group under its new name, the
    // new session on screen re-filed, what waits for it moved.
    _ = config.addAgentCustomGroup("Team", for: agent)
    appState.pendingClaudeSessionDraft?.customGroup = "Team"
    appState.renameNewSessionGroup("Work", to: "Team", agentKey: agent)
    pump(0.8)
    write(" more", appending: true)
    awayToChatAndBack(to: .custom("Team"), group: "Team")
    check("the renamed group's + brings it all back, what was typed after the rename included",
          message() == "work message more", message())
    awayToChatAndBack(to: .custom("Work"), group: "Work")
    check("…and nothing stays under the old name", message().isEmpty, message())

    print("11. A deleted group's waiting new session goes with it")
    _ = config.addAgentCustomGroup("Old", for: agent)
    awayToChatAndBack(to: .custom("Old"), group: "Old")
    write("old text")
    awayToChat()
    appState.dropNewSessions(ofGroupsNotIn: ["Work", "Team"], agentKey: agent)
    newSession(at: .custom("Old"), in: project, group: "Old")
    open()
    check("a group made again under the name starts empty", message().isEmpty, message())

    print("12. A group's new session sent and left before it is named, then opened again: the chips it went out with stay, and are the session's")
    awayToChatAndBack(to: .custom("Work"), group: "Work")
    check("the group's + starts like its newest session: Plan, Max",
          buttonLabels(in: host).contains("Plan") && buttonLabels(in: host).contains("Max"),
          "\(buttonLabels(in: host))")
    pickEffort(from: "Max", to: "Low")
    write("named while away")
    guard let sentDraft = appState.pendingClaudeSessionDraft, let sendBox = box() else {
        check("(the rest of 12 needs the new session on screen — not reached)", false)
        return
    }
    window.makeFirstResponder(sendBox)
    sendBox.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    // Away to Settings at once: the page goes, the new session stays, and
    // the switch to the session it becomes waits for the page.
    leave()
    let named = pump(upTo: 15) { agents.cachedRunner(forDraft: sentDraft)?.sessionFileURL != nil }
    check("the message names its session while the page is away", named)
    check("…and the page has not switched to it yet",
          appState.pendingClaudeSessionDraft?.id == sentDraft.id)
    let lastTurn = ((try? String(contentsOfFile: home + "/claude-argv.log", encoding: .utf8)) ?? "")
        .split(separator: "\n").last.map(String.init) ?? ""
    check("…it went out on Low", lastTurn.contains("--effort low"), lastTurn)
    open()
    let switched = pump(upTo: 10) { appState.openAgentSessionId != nil }
    pump(1)
    check("opened again, the page switches to the session", switched)
    let namedId = appState.openAgentSessionId ?? ""
    let afterSwitch = buttonLabels(in: host)
    check("…its chips say Low, as the message went out — not the group's Max",
          afterSwitch.contains("Low") && !afterSwitch.contains("Max"), "\(afterSwitch)")
    check("…and the session keeps Low as its own pick",
          config.agentSessionLaunchOptions(for: namedId)?.effort == "low",
          config.agentSessionLaunchOptions(for: namedId)?.effort ?? "nothing saved")

    print("13. A new session's first message that ends before it is named: the new session keeps the Non-stop it went out with")
    // Every Work session SipAI drove runs Non-stop; the agent's latest
    // choice does not.
    for id in [olderId, newerId, namedId] {
        guard var setup = config.agentSessionLaunchOptions(for: id) else { continue }
        setup.nonStop = true
        config.setAgentSessionLaunchOptions(setup, for: id)
    }
    var latestChoice = config.agentLaunchOptions(for: agent)
    latestChoice.nonStop = false
    config.setAgentLaunchOptions(latestChoice, for: agent)
    awayToChatAndBack(to: .custom("Work"), group: "Work")
    check("the group's + starts Non-stop, like its newest session",
          nonStopShown(modeChip: "Plan") == true)
    guard let unnamedDraft = appState.pendingClaudeSessionDraft else {
        check("(the rest of 13 needs the new session on screen — not reached)", false)
        return
    }
    write("never named")
    send()
    let ended = pump(upTo: 15) {
        if case .done = agents.cachedRunner(forDraft: unnamedDraft)?.status { return true }
        return false
    }
    pump(1)
    check("the message ends, and its session is never named",
          ended && appState.pendingClaudeSessionDraft?.id == unnamedDraft.id
            && appState.openAgentSessionId == nil)
    check("…the new session still shows Non-stop on", nonStopShown(modeChip: "Plan") == true)
    let retryRunner = agents.cachedRunner(forDraft: unnamedDraft)
    write("again")
    send()
    let retried = pump(upTo: 15) { appState.openAgentSessionId != nil }
    pump(1)
    check("sent again, it is named", retried)
    check("…and runs Non-stop, as its chips said", retryRunner?.nonStop == true)
    check("…which the session keeps as its own pick",
          appState.openAgentSessionId.flatMap { config.agentSessionLaunchOptions(for: $0) }?.nonStop == true)

    print("14. A session's first message edited into a new session: the chips its message went out with stay, and are the new session's")
    // The agent's latest choices differ from the session's own picks.
    var latest = config.agentLaunchOptions(for: agent)
    latest.permissionMode = "plan"
    latest.effort = "max"
    latest.nonStop = false
    config.setAgentLaunchOptions(latest, for: agent)
    awayToChat()
    appState.openAgentSessionId = olderId
    appState.openAgentSessionPath = olderURL
    open()
    let parentChips = buttonLabels(in: host)
    check("the session opens on its own picks: Auto, Low",
          parentChips.contains("Auto") && parentChips.contains("Low"), "\(parentChips)")
    func message(_ words: String) -> NSObject? {
        find(in: host, { ax($0, "accessibilityValue") == words || ax($0, "accessibilityLabel") == words })
    }
    let firstMessage = message("an older session")
    // The pencil shows only under the pointer, so whether it shows is a
    // check of a made-up pointer, through the gate.
    let hover = HoverGate(report: { check($0, $1, $2()) })
    let pointed = pointAt(firstMessage, in: window)
    let pencil = find(in: host, { ax($0, "accessibilityLabel") == "Edit this message"
                                  || ax($0, "accessibilityHelp") == "Edit this message" })
    hover.check("pointing at its first message shows the pencil", pointed && pencil != nil,
          "pointed: \(pointed) pencil: \(pencil != nil) element: \(firstMessage.map { ax($0, "accessibilityRole") ?? "?" } ?? "none") "
            + "frame: \(firstMessage.flatMap { ($0.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue }.map { "\($0)" } ?? "none") "
            + "window: \(window.frame) buttons: \(buttonLabels(in: host).filter { $0.contains("message") || $0.contains("Copy") })")
    // The editor is opened the way VoiceOver opens it — the message's own
    // action, which needs no pointer — so the edit and the branch below
    // run whether or not a made-up pointer reaches SwiftUI.
    let offered = actions(of: message("an older session")).map(\.name)
    check("its first message offers Edit this message and Copy this message as its own actions",
          offered.contains("Edit this message") && offered.contains("Copy this message"), "\(offered)")
    let replyOffers = actions(of: message("Done.")).map(\.name)
    check("…the agent's reply offers neither", message("Done.") != nil
            && !replyOffers.contains("Edit this message") && !replyOffers.contains("Copy this message"),
          "\(replyOffers)")
    let edited = perform("Edit this message", on: message("an older session"))
    pump(1.0)
    check("…and its Edit this message opens the editor", edited && find(in: host, label("Create Branch")) != nil,
          "ran: \(edited)")
    // The editor opens on the message's words; Create Branch takes them as
    // they are — an edit of a session's first message starts a new session.
    let turnsBefore = ((try? String(contentsOfFile: home + "/claude-argv.log", encoding: .utf8)) ?? "")
        .split(separator: "\n").count
    press(find(in: host, label("Create Branch")))
    let went = pump(upTo: 15) {
        ((try? String(contentsOfFile: home + "/claude-argv.log", encoding: .utf8)) ?? "")
            .split(separator: "\n").count > turnsBefore
    }
    let branchTurn = ((try? String(contentsOfFile: home + "/claude-argv.log", encoding: .utf8)) ?? "")
        .split(separator: "\n").last.map(String.init) ?? ""
    let argvLines = ((try? String(contentsOfFile: home + "/claude-argv.log", encoding: .utf8)) ?? "")
        .split(separator: "\n")
    check("the edited message starts a new session, and goes out on the session's Auto and Low",
          went && branchTurn.contains("--effort low") && branchTurn.contains("--permission-mode auto")
            && !branchTurn.contains("--resume"),
          "went: \(went) lines \(turnsBefore)→\(argvLines.count) draft: \(String(describing: appState.pendingClaudeSessionDraft?.place)) "
            + "runner: \(appState.pendingClaudeSessionDraft.flatMap { agents.cachedRunner(forDraft: $0) }.map { "\($0.status) rows \($0.events.count) stderr \($0.stderrTail.prefix(200))" } ?? "none") "
            + "last: \(branchTurn.prefix(160))")
    let branchNamed = pump(upTo: 15) {
        if let id = appState.openAgentSessionId { return id != olderId }
        return false
    }
    pump(1)
    let branchId = appState.openAgentSessionId ?? ""
    check("…the page switches to the new session once it is named", branchNamed)
    let branchChips = buttonLabels(in: host)
    check("…its chips say Auto and Low, as its message went out — not the agent's latest Plan and Max",
          branchChips.contains("Auto") && branchChips.contains("Low")
            && !branchChips.contains("Plan") && !branchChips.contains("Max"), "\(branchChips)")
    let kept = config.agentSessionLaunchOptions(for: branchId)
    check("…and the new session keeps them as its own picks",
          kept?.effort == "low" && kept?.permissionMode == "auto",
          "\(kept?.permissionMode ?? "nothing saved") / \(kept?.effort ?? "nothing saved")")

    print("15. A group's new session sent, and the group's + clicked again at once: the next starts like it, and it keeps its chips though the page never switched to it")
    // The stand-in names a "slow start" session three seconds after its
    // message went, as a claude loading its plugins does: the second + is
    // clicked before the first new session has a session id, and the page
    // has moved on to the second when it gets one.
    awayToChatAndBack(to: .custom("Work"), group: "Work")
    let groupStart = buttonLabels(in: host)
    let modes = ["Plan": "plan", "Auto": "auto"]
    let efforts = ["Low", "Medium", "High", "XHigh", "Max"]
    let fromMode = ["Plan", "Auto", "Manual", "Accept Edits"].first(where: groupStart.contains) ?? ""
    let toMode = fromMode == "Plan" ? "Auto" : "Plan"
    let fromEffort = efforts.first(where: groupStart.contains) ?? ""
    check("the group's + shows a mode and an effort to move off", !fromMode.isEmpty && !fromEffort.isEmpty,
          "\(groupStart)")
    let toEffort = fromEffort == "Medium" ? "High" : "Medium"
    let laterEffort = efforts.first { $0 != fromEffort && $0 != toEffort } ?? "Low"
    pickMode(from: fromMode, to: toMode)
    pickEffort(from: fromEffort, to: toEffort)
    let firstChips = buttonLabels(in: host)
    check("the first new session's chips are moved off the group's (\(fromMode), \(fromEffort)) to \(toMode), \(toEffort)",
          firstChips.contains(toMode) && firstChips.contains(toEffort), "\(firstChips)")
    guard let first = appState.pendingClaudeSessionDraft else {
        check("(the rest of 15 needs the new session on screen — not reached)", false)
        return
    }
    write("slow start, the first of two")
    send()
    newSession(at: .custom("Work"), in: project, group: "Work")
    pump(1.0)
    check("the second new session is on screen, and the first has no session id yet",
          appState.pendingClaudeSessionDraft?.id != first.id
            && agents.cachedRunner(forDraft: first)?.sessionId == nil
            && agents.cachedRunner(forDraft: first)?.status.isRunning == true)
    let secondChips = buttonLabels(in: host)
    check("…the second starts like the first — the group's newest from the moment its message went",
          secondChips.contains(toMode) && secondChips.contains(toEffort), "\(secondChips)")
    // A pick on the second moves the agent's latest choice somewhere the
    // first never was.
    pickEffort(from: efforts.first(where: secondChips.contains) ?? "", to: laterEffort)
    check("…and a pick there shows", buttonLabels(in: host).contains(laterEffort), "\(buttonLabels(in: host))")
    let firstNamed = pump(upTo: 15) {
        agents.cachedRunner(forDraft: first)?.sessionId != nil
            && agents.cachedRunner(forDraft: first)?.sessionFileURL != nil
    }
    pump(1)
    let firstId = agents.cachedRunner(forDraft: first)?.sessionId ?? ""
    let firstURL = agents.cachedRunner(forDraft: first)?.sessionFileURL
    check("the first is named while the page shows the second",
          firstNamed && appState.pendingClaudeSessionDraft?.id != first.id)
    let firstKept = config.agentSessionLaunchOptions(for: firstId)
    check("…and keeps the chips its message went out with as its own picks",
          firstKept?.permissionMode == modes[toMode] && firstKept?.effort == toEffort.lowercased(),
          "\(firstKept?.permissionMode ?? "nothing saved") / \(firstKept?.effort ?? "nothing saved")")
    awayToChatAndBack(to: .folder(project), in: project)
    let folderChips = buttonLabels(in: host)
    check("a + of another group it is in — its folder's — starts like it: it is that group's newest",
          folderChips.contains(toMode) && folderChips.contains(toEffort), "\(folderChips)")
    awayToChat()
    appState.openAgentSessionId = firstId
    appState.openAgentSessionPath = firstURL
    open()
    let reopened = buttonLabels(in: host)
    check("opened again, it shows its own chips (\(toMode), \(toEffort)) — not the agent's latest (\(laterEffort))",
          reopened.contains(toMode) && reopened.contains(toEffort) && !reopened.contains(laterEffort),
          "\(reopened)")

    print("16. A sent message's own actions, in the bubble a chat draws too: a code block in it keeps its own")
    // The bubble alone, in a window of its own, handed what each host
    // hands it: the actions of every element that has some.
    func bubbleOffers(_ message: ChatMessage, onEdit: (() -> Void)?) -> [[String]] {
        let bubble = NSHostingView(rootView: MessageBubble(message: message, onEdit: onEdit)
            .environmentObject(config).frame(width: 600))
        let bubbleWindow = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 600, height: 300),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        bubbleWindow.isReleasedWhenClosed = false
        bubbleWindow.contentView = bubble
        bubbleWindow.orderFrontRegardless()
        pump(0.5)
        defer { bubbleWindow.orderOut(nil) }
        warm(bubble)
        return nodes(bubble).map { actions(of: $0).map(\.name) }.filter { !$0.isEmpty }
    }
    let messageActions: Set = ["Edit this message", "Copy this message"]
    let withCode = bubbleOffers(ChatMessage(role: "user", content: "Run this:\n\n```sh\necho hi\n```\n"),
                                onEdit: {})
    check("a sent message's words offer Edit this message and Copy this message",
          withCode.contains { Set($0) == messageActions }, "\(withCode)")
    check("…a code block in it keeps Copy code and Save as a file…, the message's two beside them",
          withCode.contains { Set($0) == messageActions.union(["Copy code", "Save as a file…"]) }, "\(withCode)")
    let noPencil = bubbleOffers(ChatMessage(role: "user", content: "a message with no pencil"), onEdit: nil)
    check("…where no pencil is offered (a turn running), Copy this message alone",
          !noPencil.isEmpty && noPencil.allSatisfy { $0 == ["Copy this message"] }, "\(noPencil)")
    let reply = bubbleOffers(ChatMessage(role: "assistant", content: "a reply", model: "a-model"), onEdit: {})
        .joined()
    check("…and a reply offers neither, though handed an edit",
          !reply.contains("Edit this message") && !reply.contains("Copy this message"), "\(reply)")
}

let args = CommandLine.arguments
guard args.count > 3 else {
    print("usage: NewSessionSetup <throwaway home> <project> <second project>")
    exit(2)
}
MainActor.assumeIsolated { pureRules() }
MainActor.assumeIsolated { replay(home: args[1], project: args[2], project2: args[3]) }
print(failures == 0 ? "Page: OK" : "Page: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
