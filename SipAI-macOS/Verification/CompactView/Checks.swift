// Checks.swift — Compact view's switches: the REAL toolbar window laid out
// offscreen at every size, the REAL View menu item under SwiftUI's App
// lifecycle, and the wiring around them read off the sources. See run.sh
// for what each section pins; ProbeApp.swift runs them.

import SwiftUI
import AppKit

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

@MainActor
enum Report {
    static var checks = 0
    static var failures = 0
}

@MainActor
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    Report.checks += 1
    if ok {
        print("  ok   \(label)")
    } else {
        Report.failures += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

@MainActor
@discardableResult
func waitUntil(_ timeout: Double, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        spin(0.02)
    }
    return condition()
}

func source(_ path: String) -> String {
    (try? String(contentsOfFile: root + "/" + path, encoding: .utf8)) ?? ""
}

func squeeze(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

/// The body of the first declaration whose text starts with `signature`,
/// braces matched; empty when absent.
func body(_ text: String, _ signature: String) -> String {
    guard let start = text.range(of: signature),
          let open = text[start.upperBound...].firstIndex(of: "{") else { return "" }
    var depth = 0
    var i = open
    while i < text.endIndex {
        if text[i] == "{" { depth += 1 }
        if text[i] == "}" { depth -= 1; if depth == 0 { return String(text[start.lowerBound...i]) } }
        i = text.index(after: i)
    }
    return ""
}

/// The setting as the window sees it: what it was set to, in order.
@MainActor
final class StubSetting: CompactViewSetting {
    @Published var agentCompactView = false
    func setAgentCompactView(_ on: Bool) { agentCompactView = on }
}

// MARK: - §1 The window, laid out at every size

@MainActor
func windowSection() {
    print("§1 the window at every size")
    let setting = StubSetting()
    let renderDir = ProcessInfo.processInfo.environment["COMPACT_VIEW_RENDER"]

    func window(_ tier: FontTier) -> some View {
        TranscriptViewWindow(setting: setting, isPresented: .constant(true))
            .environment(\.sipFontScale, tier.scale)
            .environment(\.sipLineSpacingFactor, tier.lineSpacingFactor)
    }

    var heights: [CGFloat] = []
    for tier in FontTier.allCases {
        let host = NSHostingView(rootView: window(tier))
        let size = host.fittingSize
        let ratio = SipFont.ratio(tier.scale)
        let expectedWidth = min(300 * ratio, 480)
        check("\(tier.rawValue): the window is \(Int(expectedWidth.rounded())) pt wide — 300 at Default, by the size's ratio, capped",
              abs(size.width - expectedWidth) < 0.6, "measured \(size.width)")
        // The line under the switch, alone, at the width the window gives
        // it (its 14-pt insets): the window must be at least that tall
        // plus its title band and the switch row, or the line is clipped.
        let line = Text(verbatim: CompactViewWords.description)
            .sipFont(12)
            .lineSpacing(SipFont.lineSpacing(12, fontScale: tier.scale,
                                             lineSpacingFactor: tier.lineSpacingFactor))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: expectedWidth - 28, alignment: .leading)
            .environment(\.sipFontScale, tier.scale)
        let lineHeight = NSHostingView(rootView: line).fittingSize.height
        check("\(tier.rawValue): the line under the switch is laid out whole (window \(Int(size.height)) pt, line \(Int(lineHeight)) pt)",
              size.height >= lineHeight + 20 + 24 + 14, "")
        heights.append(size.height)

        if let renderDir {
            for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000,
                                                     width: size.width + 40, height: size.height + 40),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
                w.appearance = NSAppearance(named: appearance)
                let padded = NSHostingView(rootView: window(tier).padding(20)
                    .background(Color(nsColor: .windowBackgroundColor)))
                w.contentView = padded
                w.orderFrontRegardless()
                padded.layoutSubtreeIfNeeded()
                if let rep = padded.bitmapImageRepForCachingDisplay(in: padded.bounds) {
                    padded.cacheDisplay(in: padded.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: renderDir)
                            .appendingPathComponent("compact-view-window-\(tier.rawValue)-\(look).png"))
                    }
                }
                w.orderOut(nil)
            }
        }
    }
    check("the window grows with the size — type and the tier's line spacing together",
          zip(heights, heights.dropFirst()).allSatisfy { $0 < $1 }, heights.description)

    // The switch writes the one setting, and the setting is what it shows.
    setting.setAgentCompactView(true)
    check("the switch moves the one setting it reads", setting.agentCompactView)
}

// MARK: - §2 The View menu item, under SwiftUI's App lifecycle

/// What the probe app's menu item moves.
@MainActor
final class MenuSetting: CompactViewSetting {
    static let shared = MenuSetting()
    @Published var agentCompactView = false
    func setAgentCompactView(_ on: Bool) { agentCompactView = on }
}

@MainActor
func menuSection() {
    print("§2 View → Agent Session Compact View")
    guard waitUntil(3, { NSApp.mainMenu?.items.contains { $0.title == "View" } == true }),
          let view = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu else {
        check("SwiftUI built a View menu", false)
        return
    }
    // The item's name says what it is — a way of viewing — and what it
    // applies to. One that opens on "Compact" reads as an action on a
    // session: to the agents, to compact is to summarise (`/compact`).
    check("the item is named Agent Session Compact View — a view, never an action on a session",
          CompactViewWords.menuItem == "Agent Session Compact View"
            && !CompactViewWords.menuItem.hasPrefix("Compact"))
    let item = view.items.first { $0.title == CompactViewWords.menuItem }
    check("the item is in the View menu, showing ⌃⌘O",
          item?.keyEquivalent == "o" && item?.keyEquivalentModifierMask == [.command, .control],
          "\(String(describing: item?.keyEquivalent)) \(String(describing: item?.keyEquivalentModifierMask))")
    func press(_ flags: NSEvent.ModifierFlags) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                     context: nil, characters: "o", charactersIgnoringModifiers: "o",
                                     isARepeat: false, keyCode: 31)!
        _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
        spin(0.2)
    }
    let model = MenuSetting.shared
    model.agentCompactView = false
    spin(0.3)
    press([.command, .control])
    check("⌃⌘O turns compact view on", model.agentCompactView)
    press([.command, .control])
    check("…and off again", !model.agentCompactView)
    // Switched on elsewhere (the toolbar window, Settings) a moment before,
    // a press turns it off. Here SwiftUI redraws the item in time; an item
    // still drawn stale cannot be made on demand, so the rule that covers
    // it — the press flips the value in force — is read off the source (§3).
    model.agentCompactView = true
    press([.command, .control])
    check("switched on elsewhere a moment before, a press turns it off", !model.agentCompactView)
    press(.command)
    press(.control)
    check("⌘O and ⌃O alone are not it", !model.agentCompactView)
}

// MARK: - §3 The wiring, read off the sources

@MainActor
func wiringSection() {
print("§3 the wiring")

let content = source("SipAI/Views/ContentView.swift")
let windowSource = source("SipAI/Views/TranscriptViewWindow.swift")
let app = source("SipAI/SipAIApp.swift")
let settings = source("SipAI/Views/Settings/SettingsView.swift")
let config = source("SipAI/Models/ConfigManager.swift")

let magnifier = content.range(of: "Image(systemName: \"magnifyingglass\")")
let button = content.range(of: "Image(systemName: \"rectangle.compress.vertical\")")
let coin = content.range(of: "Image(systemName: \"t.circle\")")
check("the button sits between the magnifier and the plan-usage T",
      magnifier != nil && button != nil && coin != nil
      && magnifier!.lowerBound < button!.lowerBound && button!.lowerBound < coin!.lowerBound)
check("…drawn whenever an agent is listed — plan or API key — and kept while its window is open",
      content.contains("if !agents.listedAgents.isEmpty || showingSessionView {"))
check("…with the toolbar's hover: secondary, primary under the pointer or while open",
      content.contains(".foregroundStyle(sessionViewHovered || showingSessionView\n                                             ? .primary : .secondary)")
      && content.contains(".onHover { hovering in sessionViewHovered = hovering }"))
check("…its tooltip and VoiceOver name one string",
      content.contains(".help(CompactViewWords.title)")
      && content.contains(".accessibilityLabel(CompactViewWords.title)"))
check("the window hangs under the MEASURED button, over a click-anywhere-else scrim",
      content.contains("key: SessionViewButtonLeadingKey.self")
      && content.contains(".padding(.leading, sessionViewLeading)")
      && content.contains("TranscriptViewWindow(setting: config, isPresented: $showingSessionView)")
      && content.contains(".onTapGesture { showingSessionView = false }"))
check("one dropdown at a time: opening it closes the search palette and the plan-usage window, and both close it",
      squeeze(content).contains("showingSessionView.toggle() if showingSessionView { showingSearch = false showingUsage = false }")
      && squeeze(content).contains("if showingSearch { showingUsage = false showingSessionView = false }")
      && squeeze(content).contains("if showingUsage { showingSearch = false showingSessionView = false }"))
let exclusivity = body(content, "private struct SettingsMenuExclusivity: ViewModifier {")
check("…and the settings menu and the window never show together",
      exclusivity.contains("sessionView = false")
      && squeeze(exclusivity).contains(".onChange(of: sessionView) { _, open in if open { menu = false } }")
      && content.contains("sessionView: $showingSessionView,"))
check("while it is up the cards a turn waits on stand down (AppState.overlayHoldsKeys)",
      squeeze(content).contains(".onChange(of: showingSettingsMenu || showingSearch || showingUsage || showingSessionView, initial: true) { _, up in appState.overlayHoldsKeys = up }"))
check("Escape closes the window, which takes focus as it appears",
      windowSource.contains(".onKeyPress(.escape) {") && windowSource.contains("isPresented = false")
      && windowSource.contains(".onAppear { focused = true }"))
check("its switch steps with the size and its type follows it",
      windowSource.contains(".controlSize(SipFont.controlSize(fontScale))")
      && windowSource.contains(".frame(width: min(300 * SipFont.ratio(fontScale), 480))")
      && !windowSource.contains(".font(.system("))

let menu = body(app, "CommandGroup(after: .sidebar)")
check("View → Agent Session Compact View sits with the Zoom items",
      menu.contains("ZoomMenuItems(setting: configManager)")
      && menu.contains("CompactViewMenuItem(setting: configManager)")
      && menu.range(of: "ZoomMenuItems")!.lowerBound < menu.range(of: "CompactViewMenuItem")!.lowerBound)
let item = body(windowSource, "struct CompactViewMenuItem<")
check("…with ⌃⌘O, and a press flips the value in force whatever the item last drew",
      item.contains(".keyboardShortcut(\"o\", modifiers: [.command, .control])")
      && item.contains("set: { _ in setting.setAgentCompactView(!setting.agentCompactView) }"))
var shortcutUses = 0
if let files = FileManager.default.enumerator(atPath: root + "/SipAI") {
    for case let file as String in files where file.hasSuffix(".swift") {
        shortcutUses += source("SipAI/" + file)
            .components(separatedBy: "keyboardShortcut(\"o\", modifiers: [.command, .control])").count - 1
    }
}
check("…and nothing else in the app takes ⌃⌘O", shortcutUses == 1, "\(shortcutUses) uses")
// The item was first built as "Compact Agent Sessions" and renamed at the
// user's choice; a comment or a sentence still spelling the old name points
// at a menu item that is not there.
var retiredName = 0
if let files = FileManager.default.enumerator(atPath: root + "/SipAI") {
    for case let file as String in files where file.hasSuffix(".swift") {
        retiredName += source("SipAI/" + file).components(separatedBy: "Compact Agent").count - 1
    }
}
check("…and the retired name \"Compact Agent Sessions\" is nowhere in the sources, comments included, nor in the README",
      retiredName == 0 && !source("../README.md").contains("Compact Agent"), "\(retiredName) uses")
check("the app's ConfigManager is the setting all three move",
      squeeze(app).contains("extension ConfigManager: CompactViewSetting { var agentCompactView: Bool { display.agentCompactView } func setAgentCompactView(_ on: Bool) { setDisplay { $0.agentCompactView = on } } }"))
check("Settings → Display has the switch, under Agent sessions",
      settings.contains("Text(\"Agent sessions\", comment:")
      && settings.contains("set: { v in config.setDisplay { $0.agentCompactView = v } }")
      && settings.contains("Text(verbatim: CompactViewWords.switchLabel)"))
check("the setting is `display.agent_compact_view`, off unless set",
      config.contains("var agentCompactView: Bool = false")
      && config.contains("s.agentCompactView = d[\"agent_compact_view\"] as? Bool ?? false")
      && config.contains("d[\"agent_compact_view\"] = s.agentCompactView"))
check("Help answers what it changes",
      settings.contains("FAQ(id: 23,")
      && settings.contains("String(localized: \"What does Compact view change in agent sessions?\""))
let ids = settings.components(separatedBy: "FAQ(id: ").dropFirst()
    .map { String($0.prefix { $0 != "," }) }
check("…and every Help question keeps its own id", Set(ids).count == ids.count, ids.description)

}

// MARK: - §4 Strings

@MainActor
func stringsSection() {
print("§4 strings")

let catalogPath = root + "/SipAI/Resources/Localizable.xcstrings"
let catalogData = (try? Data(contentsOf: URL(fileURLWithPath: catalogPath))) ?? Data()
let catalog = ((try? JSONSerialization.jsonObject(with: catalogData)) as? [String: Any])?["strings"] as? [String: Any] ?? [:]
func zh(_ key: String) -> String? {
    guard let entry = catalog[key] as? [String: Any],
          let zh = (entry["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any],
          let unit = zh["stringUnit"] as? [String: Any],
          unit["state"] as? String == "translated" else { return nil }
    return unit["value"] as? String
}
let keys = [
    "Agent session view", "Compact view", "Agent Session Compact View", "Agent sessions",
    "Shows each answer’s thinking, tool calls and messages as one line, with its final message under it. Click a line to see its steps.",
    "What does Compact view change in agent sessions?", "Thinking",
    "Edited 1 file", "Edited %lld files", "Ran 1 command", "Ran %lld commands",
    "Read 1 file", "Read %lld files", "Searched for 1 pattern", "Searched for %lld patterns",
    "Ran 1 agent", "Ran %lld agents", "%lld failed",
    "Reading a file", "Editing %@", "Editing files", "Running %@", "Running a command",
    "Searching the files", "Searching for “%@”", "Running an agent", "Running an agent: %@",
    "Updating the to-do list",
]
for key in keys {
    let value = zh(key)
    check("zh-Hans: \(key.prefix(60))", value.map { !$0.isEmpty } ?? false)
    if let value {
        check("…keeps its placeholders", value.components(separatedBy: "%@").count == key.components(separatedBy: "%@").count
              && value.components(separatedBy: "%lld").count == key.components(separatedBy: "%lld").count)
    }
}
// The menu item's Chinese is the user's word (2026-10-31), and every
// sentence that names the item names it the way the menu draws it, in
// both languages.
check("zh-Hans: the menu item reads 智能体会话简洁版",
      zh(CompactViewWords.menuItem) == "智能体会话简洁版", zh(CompactViewWords.menuItem) ?? "none")
let naming = catalog.keys.filter { $0.contains("View → " + CompactViewWords.menuItem) }
check("…and each sentence that names the menu item (the Display line, Help 23) names it so, in both languages",
      naming.count == 2 && naming.allSatisfy { key in
          zh(key).map { $0.contains("“" + (zh(CompactViewWords.menuItem) ?? "-") + "”") } ?? false
      }, naming.map { String($0.prefix(40)) }.description)
let longKeys = catalog.keys.filter {
    $0.hasPrefix("Compact view — the switch in the toolbar's agent session window")
    || ($0.hasPrefix("Shows each answer’s thinking, tool calls and messages") && $0.contains("The same switch"))
}
check("zh-Hans: the Help answer and the Display line", longKeys.count == 2
      && longKeys.allSatisfy { zh($0).map { !$0.isEmpty } ?? false }, longKeys.description)
// One word for one thing in Chinese (the user's decision, 2026-10-31): the switch
// reads the menu item's own word, and Help 23's question and answer open on it.
let switchWord = zh(CompactViewWords.switchLabel) ?? ""
check("zh-Hans: the switch's word is the menu item's own (智能体会话简洁版 ends with it)",
      !switchWord.isEmpty && (zh(CompactViewWords.menuItem) ?? "").hasSuffix(switchWord), switchWord)
let helpQuestion = zh("What does Compact view change in agent sessions?") ?? ""
let helpAnswer = longKeys.first { $0.hasPrefix("Compact view — the switch") }.flatMap(zh) ?? ""
check("…and Help 23's question and answer open on that word",
      !switchWord.isEmpty && helpQuestion.hasPrefix(switchWord) && helpAnswer.hasPrefix(switchWord),
      "\(helpQuestion.prefix(6)) / \(helpAnswer.prefix(6))")

}
