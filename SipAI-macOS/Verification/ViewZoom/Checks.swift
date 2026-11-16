// The ViewZoom checks — see run.sh for what each section pins. Shared by
// the headless binary (main.swift: sections 1 and 2) and the GUI one
// (ProbeApp.swift: sections 3–5).
//
// Nothing in this directory is part of the app target.

import SwiftUI
import AppKit
import WebKit

// MARK: - Reporting

@MainActor
enum Report {
    static var failures = 0
    static var passes = 0

    static func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if ok {
            passes += 1
            print("  PASS  \(label)")
        } else {
            failures += 1
            let d = detail()
            print("  FAIL  \(label)" + (d.isEmpty ? "" : " — \(d)"))
        }
    }

    static func section(_ title: String) { print("\n== \(title)") }
}

@MainActor
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

/// SipAI-macOS of the checkout under test.
let sourceRoot: String = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// MARK: - 1. The rules

@MainActor
func rulesSection() {
    Report.section("1. The rules: the four sizes, the anchor, the switch of size")

    Report.check(FontTier.allCases == [.small, .standard, .larger, .xlarge],
                 "the sizes run Small, Default, Larger, Large text mode — the steps follow this order")
    Report.check(FontTier.small.zoomedIn == .standard && FontTier.standard.zoomedIn == .larger
                 && FontTier.larger.zoomedIn == .xlarge && FontTier.xlarge.zoomedIn == nil,
                 "Zoom In goes one size up and stops at Large text mode")
    Report.check(FontTier.xlarge.zoomedOut == .larger && FontTier.larger.zoomedOut == .standard
                 && FontTier.standard.zoomedOut == .small && FontTier.small.zoomedOut == nil,
                 "Zoom Out goes one size down and stops at Small")
    Report.check(FontTier.actualSize == .standard, "Actual Size is Default")

    let setting = MenuModel()
    setting.fontTier = .xlarge
    Report.check(!setting.zoom(.zoomIn) && setting.fontTier == .xlarge,
                 "Zoom In at the largest size takes no step (and answers so — the key goes on)")
    Report.check(setting.zoom(.zoomOut) && setting.fontTier == .larger, "Zoom Out steps from the size in force")
    Report.check(setting.zoom(.actualSize) && setting.fontTier == .standard
                 && !setting.zoom(.actualSize), "Actual Size goes to Default, and at Default takes no step")
    setting.fontTier = .small
    Report.check(!setting.zoom(.zoomOut) && setting.zoom(.zoomIn) && setting.fontTier == .standard,
                 "Zoom Out at the smallest takes no step; Zoom In from there goes to Default")

    let a = UUID(), b = UUID(), c = UUID()
    let frames: [UUID: CGRect] = [
        a: CGRect(x: 0, y: 16, width: 500, height: 100),
        b: CGRect(x: 0, y: 128, width: 500, height: 100),
        c: CGRect(x: 0, y: 240, width: 500, height: 100),
    ]
    let inside = ReadingAnchor.at(top: 168, frames: frames)
    Report.check(inside == ReadingAnchor(id: b, share: 0.4, lead: 0),
                 "the top edge inside a row: that row, at its share of the row's height",
                 String(describing: inside))
    let gap = ReadingAnchor.at(top: 120, frames: frames)
    Report.check(gap == ReadingAnchor(id: b, share: 0, lead: 8),
                 "the top edge in the gap above a row: that row and its distance from the edge",
                 String(describing: gap))
    Report.check(ReadingAnchor.at(top: 400, frames: frames) == nil, "the edge below every row: no anchor")
    Report.check(ReadingAnchor.at(top: 0, frames: [:]) == nil, "no rows: no anchor")
    let newB = CGRect(x: 0, y: 150, width: 500, height: 140)
    if let inside {
        let top = inside.top(in: newB)
        Report.check(abs(top - 206) < 0.001,
                     "after the change the edge goes to the same share of the row's new frame", "\(top)")
    }
    if let gap {
        let top = gap.top(in: CGRect(x: 0, y: 160, width: 500, height: 140))
        Report.check(abs(top - 152) < 0.001, "…and from a gap, the row keeps its distance from the edge", "\(top)")
    }

    let s1 = ReadingPlace.Size(fontScale: 1.1, lineSpacing: 0.18)
    let s2 = ReadingPlace.Size(fontScale: 1.25, lineSpacing: 0.40)
    func laidOut() -> ReadingPlace {
        let place = ReadingPlace()
        for (id, frame) in frames { _ = place.noteFrame(id, frame, size: s1) }
        place.noteEdge(.init(top: 168, offset: 168), following: false, size: s1)
        return place
    }
    func near(_ value: CGFloat?, _ expected: CGFloat) -> Bool {
        value.map { abs($0 - expected) < 0.001 } ?? false
    }
    do {
        // The order SwiftUI reports in today: the scroll view reports the new
        // content first, the rows after.
        let place = laidOut()
        place.noteEdge(.init(top: 168, offset: 168), following: false, size: s2)
        let first = place.noteFrame(a, CGRect(x: 0, y: 16, width: 500, height: 120), size: s2)
        let anchor = place.noteFrame(b, newB, size: s2)
        let after = place.noteFrame(c, CGRect(x: 0, y: 302, width: 500, height: 140), size: s2)
        let again = place.noteFrame(b, newB, size: s2)
        Report.check(first == nil && near(anchor, 206) && after == nil && again == nil,
                     "scroll view first, rows after: the row being read answers where to scroll, once",
                     "\(String(describing: first)) \(String(describing: anchor)) \(String(describing: after)) \(String(describing: again))")
    }
    do {
        let place = laidOut()
        _ = place.noteFrame(a, CGRect(x: 0, y: 16, width: 500, height: 300), size: s2)
        Report.check(near(place.noteFrame(b, newB, size: s2), 206),
                     "another row of the new size first: the anchor is still the old layout's")
    }
    do {
        let place = laidOut()
        Report.check(near(place.noteFrame(b, newB, size: s2), 206), "the row being read first: answered at once")
    }
    do {
        let place = laidOut()
        place.noteEdge(.init(top: 168, offset: 168), following: false, size: s2)
        place.readerScrolled()
        Report.check(place.noteFrame(b, newB, size: s2) == nil,
                     "the reader scrolls before the row reports: nothing is moved under them")
    }
    do {
        let place = ReadingPlace()
        for (id, frame) in frames { _ = place.noteFrame(id, frame, size: s1) }
        place.noteEdge(.init(top: 168, offset: 148), following: false, size: s1)
        Report.check(near(place.noteFrame(b, newB, size: s2), 186),
                     "an inset scroll view: the answer is the scroll offset for that top")
    }
    do {
        let place = ReadingPlace()
        Report.check(place.noteFrame(a, frames[a]!, size: s2) == nil, "the first layout of all moves nothing")
    }
    do {
        let place = ReadingPlace()
        for (id, frame) in frames { _ = place.noteFrame(id, frame, size: s1) }
        place.noteEdge(.init(top: 168, offset: 168), following: true, size: s1)
        Report.check(place.noteFrame(b, newB, size: s2) == nil,
                     "a reader following the end carries no place: the follow engine keeps the end")
    }
    do {
        // The page shrank and clamped a reader mid-page to the end, so the
        // follow engine says "following" by the first report of the new
        // size — the old layout's verdict is the one that counts.
        let place = laidOut()
        place.noteEdge(.init(top: 168, offset: 168), following: true, size: s2)
        Report.check(near(place.noteFrame(b, newB, size: s2), 206),
                     "following is judged on the layout before the change, not after it")
    }
    do {
        let place = laidOut()
        place.forget(b)
        place.noteEdge(.init(top: 168, offset: 168), following: false, size: s2)
        Report.check(near(place.noteFrame(c, CGRect(x: 0, y: 302, width: 500, height: 140), size: s2), 230),
                     "a row that left the stack is never the anchor")
    }
}

// MARK: - 1b. A row that draws nothing takes no gap

/// A transcript stack holds rows that draw nothing — a tool result folded
/// into its call's chip, a turn's start and end markers, a thought drawn
/// only inside its line — and every row carries `readingPlaceRow`. Laid out
/// through the REAL modifier: an empty row must take none of the stack's
/// spacing, and a drawn row must lay out exactly as it does without the
/// modifier. Measured with the hosting view's fitting size, no window.
@MainActor
func emptyRowSection() {
    Report.section("1b. A row that draws nothing takes no gap between the messages (the real readingPlaceRow)")
    struct Row: View {
        let draws: Bool
        var body: some View { if draws { Text("A row that draws something") } }
    }
    let spacing: CGFloat = 20
    let place = ReadingPlace()
    let size = ReadingPlace.Size(fontScale: 1, lineSpacing: 0)
    func height<V: View>(_ view: V) -> CGFloat {
        NSHostingView(rootView: view.frame(width: 300).fixedSize(horizontal: false, vertical: true))
            .fittingSize.height
    }
    func stack<V: View>(@ViewBuilder _ middle: () -> V) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text("above")
            middle()
            Text("below")
        }
    }
    let id = UUID()
    let none = height(stack { EmptyView() })
    let empty = height(stack {
        Row(draws: false).id(id).readingPlaceRow(id, place: place, size: size, restore: { _ in })
    })
    Report.check(empty == none,
                 "a row that draws nothing, carrying readingPlaceRow, takes no gap",
                 "the stack is \(empty - none) pt taller than with no row at all")
    let drawnPlain = height(stack { Row(draws: true).id(id) })
    let drawnRow = height(stack {
        Row(draws: true).id(id).readingPlaceRow(id, place: place, size: size, restore: { _ in })
    })
    Report.check(drawnRow == drawnPlain && drawnPlain > none + spacing,
                 "a row that draws something lays out the same with readingPlaceRow as without",
                 "\(drawnRow) pt with it, \(drawnPlain) pt without")
    // Control: the hazard the modifier is written around. Asking for a
    // geometry ON the row makes an empty row a laid-out child of zero size,
    // and the stack gives it its spacing.
    let onRow = height(stack {
        Row(draws: false).id(id)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in }
    })
    Report.check(onRow == none + spacing,
                 "control — a geometry asked for on an empty row itself gives it one gap",
                 "\(onRow - none) pt (SwiftUI may have changed: re-measure the hazard)")
}

// MARK: - 2. The wiring

@MainActor
func wiringSection() {
    Report.section("2. The wiring, read off the sources")
    func read(_ relative: String) -> String {
        (try? String(contentsOfFile: sourceRoot + "/" + relative, encoding: .utf8)) ?? ""
    }
    func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    let app = read("SipAI/SipAIApp.swift")
    let sidebarGroup = app.range(of: "CommandGroup(after: .sidebar) {").map { String(app[$0.lowerBound...].prefix(900)) } ?? ""
    Report.check(sidebarGroup.contains("ZoomMenuItems(setting: configManager)")
                 && app.contains("extension ConfigManager: ZoomSetting {}"),
                 "the View menu draws the three items, observing the one setting")
    Report.check(app.contains("ZoomKeys.install { [weak configManager = configManager] step in")
                 && app.contains("configManager?.zoom(step) ?? false"),
                 "the zoom keys are answered at launch from the size in force (ZoomKeys)")
    let items = read("SipAI/Views/ZoomCommands.swift")
    Report.check(["setting.zoom(.zoomIn)", "setting.zoom(.zoomOut)", "setting.zoom(.actualSize)"].allSatisfy(items.contains)
                 && items.contains("@ObservedObject var setting: Setting"),
                 "each item steps from the size in force, the items observing the setting")
    Report.check(["ZoomStep.zoomIn.target(from: tier) == nil", "ZoomStep.zoomOut.target(from: tier) == nil",
                  "ZoomStep.actualSize.target(from: tier) == nil"].allSatisfy(items.contains),
                 "an item is greyed exactly where its step has nowhere to go")

    let settings = read("SipAI/Views/Settings/SettingsView.swift")
    Report.check(settings.contains("Text(\"Zoom\", comment:") && !settings.contains("Text(\"Font Size\""),
                 "Settings → Display names the row Zoom, as the menu does")
    Report.check(settings.contains("set: { config.setFontTier($0) }"), "the picker writes through setFontTier")
    Report.check(settings.contains("View → Zoom In (⌘+), Zoom Out (⌘−) and Actual Size (⌘0)"),
                 "the row's help line names the menu items and their keys")

    // One writer of the size.
    let swiftRoot = sourceRoot + "/SipAI"
    var writers: [String] = []
    if let walker = FileManager.default.enumerator(atPath: swiftRoot) {
        for case let path as String in walker where path.hasSuffix(".swift") {
            let text = read("SipAI/" + path)
            if text.contains(".fontTier = "), !path.hasSuffix("Models/ConfigManager.swift") { writers.append(path) }
        }
    }
    Report.check(writers.isEmpty, "only ConfigManager writes the size", writers.joined(separator: ", "))

    for (file, rows) in [("SipAI/Views/Chat/AgentSessionView.swift", 4), ("SipAI/Views/Chat/ChatView.swift", 1)] {
        let text = read(file)
        let name = (file as NSString).lastPathComponent
        Report.check(count(".readingPlaceRow(", in: text) == rows, "\(name): every row reports its frame (\(rows))",
                     "\(count(".readingPlaceRow(", in: text))")
        Report.check(text.contains(".coordinateSpace(.named(ReadingPlace.space))")
                     && text.contains(".onScrollGeometryChange(for: ScrollSample.self)")
                     && !text.contains(".onScrollGeometryChange(for: TranscriptGeometry.self)"),
                     "\(name): the frames and the edge are in the content's coordinates, one sample for both readers")
        Report.check(text.contains("if follow.readerIsScrolling { readingPlace.readerScrolled() }"),
                     "\(name): the reader's own scroll drops a carried place")
        Report.check(text.contains(".onChange(of: readingSize) { _, _ in follow.noteInput() }"),
                     "\(name): a size change is real input for the follow engine")
        Report.check(text.contains("readingPlace.noteEdge(new.edge, following: follow.isNearBottom, size: readingSize)"),
                     "\(name): whether the reader follows the end rides with the edge, judged before the change")
        Report.check(!text.contains("guard !follow.isNearBottom else { return }\n        scrollPosition.scrollTo(y:")
                     && !text.contains("guard !follow.isNearBottom else { return }\n        chatScrollPosition.scrollTo(y:"),
                     "\(name): the restore is not judged after the change (a shrunk page clamps a reader to the end)")
    }

    let note = read("SipAI/Views/Notes/NoteWebView.swift")
    Report.check(note.contains("NoteHTML.resizeScript(bodyPointSize: bodyPointSize)")
                 && note.contains("loaded == document(bodyPointSize: coordinator.loadedSize)"),
                 "the note preview compares the note at its loaded size and changes the size in place")

    // The strings, with their Chinese.
    let catalogPath = sourceRoot + "/SipAI/Resources/Localizable.xcstrings"
    let catalog = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: catalogPath)))) as? [String: Any]
    let strings = catalog?["strings"] as? [String: Any] ?? [:]
    let help = "Applies to the sidebar, the conversation, the text box and its controls, notes, and Settings. Bigger sizes also widen line spacing; Large text mode doubles it. Change it from anywhere with View → Zoom In (⌘+), Zoom Out (⌘−) and Actual Size (⌘0)."
    for key in ["Zoom", "Zoom In", "Zoom Out", "Actual Size", help] {
        let entry = strings[key] as? [String: Any]
        let zh = ((entry?["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any]
        let value = zh?["value"] as? String ?? ""
        Report.check(zh?["state"] as? String == "translated" && !value.isEmpty,
                     "zh-Hans for “\(key.count > 40 ? String(key.prefix(40)) + "…" : key)”")
    }
    Report.check(strings["Font Size"] == nil, "the old “Font Size” key is gone from the catalog")

    let readme = read("../README.md")
    Report.check(readme.contains("Zoom In (⌘+)"), "the README's Display row names the shortcuts")
}

// MARK: - 3. The View menu

@MainActor
final class MenuModel: ObservableObject, ZoomSetting {
    static let shared = MenuModel()
    @Published var fontTier: FontTier = .standard
    func setFontTier(_ tier: FontTier) { fontTier = tier }
}

@MainActor
func menuSection() {
    Report.section("3. The View menu: three items, and their keys answered from the size in force")
    func event(_ chars: String, _ flags: NSEvent.ModifierFlags, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }
    let keys: [(String, NSEvent.ModifierFlags, UInt16, ZoomStep?, String)] = [
        ("=", .command, 24, .zoomIn, "⌘= (+ without Shift)"),
        ("+", [.command, .shift], 24, .zoomIn, "⌘⇧= (+)"),
        ("+", .command, 30, .zoomIn, "⌘+ where + has a key of its own"),
        ("+", [.command, .numericPad], 69, .zoomIn, "the keypad's ⌘+"),
        ("=", [.command, .numericPad], 81, .zoomIn, "the keypad's ⌘="),
        ("=", [.command, .capsLock], 24, .zoomIn, "⌘= with Caps Lock on"),
        ("-", .command, 27, .zoomOut, "⌘−"),
        ("-", [.command, .numericPad], 78, .zoomOut, "the keypad's ⌘−"),
        ("0", .command, 29, .actualSize, "⌘0"),
        ("=", [.command, .shift], 29, nil, "⌘⇧ with = (a keyboard where = takes Shift)"),
        ("_", [.command, .shift], 27, nil, "⌘⇧−"),
        ("=", [.command, .option], 24, nil, "⌥⌘="),
        ("=", [.command, .control], 24, nil, "⌃⌘="),
        ("0", [.command, .shift], 29, nil, "⌘⇧0"),
        ("=", [], 24, nil, "= alone (typing)"),
        ("0", [], 29, nil, "0 alone (typing)"),
    ]
    for (chars, flags, code, expected, label) in keys {
        Report.check(ZoomKeys.step(for: event(chars, flags, code: code)) == expected,
                     "\(label): \(expected.map { "\($0)" } ?? "not a zoom key")")
    }

    guard waitUntil(3, { NSApp.mainMenu?.items.contains { $0.title == "View" } == true }),
          let view = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu else {
        Report.check(false, "SwiftUI built a View menu")
        return
    }
    func item(_ title: String) -> NSMenuItem? { view.items.first { $0.title == title } }
    let zoomIn = item("Zoom In"), zoomOut = item("Zoom Out"), actual = item("Actual Size")
    Report.check(zoomIn?.keyEquivalent == "+" && zoomIn?.keyEquivalentModifierMask == .command, "Zoom In shows ⌘+")
    Report.check(zoomOut?.keyEquivalent == "-" && zoomOut?.keyEquivalentModifierMask == .command, "Zoom Out shows ⌘−")
    Report.check(actual?.keyEquivalent == "0" && actual?.keyEquivalentModifierMask == .command, "Actual Size shows ⌘0")

    // Key-downs through NSApplication, as typed.
    let model = MenuModel.shared
    func press(_ chars: String, _ flags: NSEvent.ModifierFlags, code: UInt16) {
        NSApp.sendEvent(event(chars, flags, code: code))
        spin(0.15)
    }
    model.fontTier = .standard
    spin(0.3)
    let presses: [(String, NSEvent.ModifierFlags, UInt16, FontTier, String)] = [
        ("=", .command, 24, .larger, "⌘= zooms in"),
        ("+", [.command, .shift], 24, .xlarge, "⌘⇧= zooms in"),
        ("=", .command, 24, .xlarge, "⌘= at the largest size changes nothing"),
        ("-", .command, 27, .larger, "⌘− zooms out"),
        ("0", .command, 29, .standard, "⌘0 goes back to Default"),
        ("-", .command, 27, .small, "⌘− to Small"),
        ("-", .command, 27, .small, "⌘− at the smallest size changes nothing"),
        ("+", [.command, .numericPad], 69, .standard, "the keypad's + zooms in"),
        ("+", [.command, .shift], 24, .larger, "⌘⇧= once more"),
        ("-", .command, 27, .standard, "⌘− at once after: a quick reversal is never swallowed"),
        ("0", .command, 29, .standard, "⌘0 at Default changes nothing"),
    ]
    for (chars, flags, code, expected, label) in presses {
        press(chars, flags, code: code)
        Report.check(model.fontTier == expected, label, "\(model.fontTier)")
    }

    // Clicks are not driven: SwiftUI routes one only to an item it last drew
    // enabled, and a background app's items are not redrawn as the size
    // moves. What an action does is checked in section 1 (`zoom` from the
    // size in force) and section 2 (each item's action is that call); the
    // greyed look is the GUI pass's.
}

// MARK: - 4. The transcript keeps the line being read

/// The agent transcript's and the chat list's shape, through the REAL
/// `ReadingPlace`, `readingPlaceRow` and `TranscriptFollow`: eager rows
/// with ids in a padded stack, the coordinate space on the content, the
/// edge sampled beside the follow engine. The views themselves need the
/// whole app; section 2 reads them for the same wiring.
@MainActor
final class PlaceModel: ObservableObject {
    @Published var fontTier: FontTier = .standard
    @Published var position = ScrollPosition(edge: .bottom)
    var restores = true
    var frames: [UUID: CGRect] = [:]
    var edge = ReadingPlace.Edge(top: 0, offset: 0)
    var geometry = TranscriptGeometry(contentHeight: 0, distanceFromEnd: 0)
    let rows: [(id: UUID, text: String)] = (0..<80).map { i in
        (UUID(), "Row \(i). " + String(repeating: "A sentence long enough to wrap at some sizes and not at others. ",
                                       count: (i * 7) % 9 + 1))
    }
}

struct PlaceProbeView: View {
    @ObservedObject var model: PlaceModel
    @State private var follow = TranscriptFollow(label: "probe")
    @State private var place = ReadingPlace()

    private var readingSize: ReadingPlace.Size {
        ReadingPlace.Size(fontScale: model.fontTier.scale, lineSpacing: model.fontTier.lineSpacingFactor)
    }

    var body: some View {
        let scale = SipFont.contentScale(model.fontTier.scale)
        let spacing = model.fontTier.lineSpacingFactor
        ScrollView {
            VStack(alignment: .leading,
                   spacing: 12 * SipFont.transcriptGapScale(fontScale: scale, lineSpacingFactor: spacing)) {
                ForEach(model.rows, id: \.id) { row in
                    Text(row.text)
                        .font(.system(size: 14 * scale))
                        .lineSpacing(14 * scale * spacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(row.id)
                        .readingPlaceRow(row.id, place: place, size: readingSize, restore: restore)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named(ReadingPlace.space))
                        } action: { frame in
                            model.frames[row.id] = frame
                        }
                }
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 16)
            .coordinateSpace(.named(ReadingPlace.space))
        }
        .scrollPosition($model.position)
        .onScrollGeometryChange(for: ScrollSample.self) { geo in
            ScrollSample(geo)
        } action: { [readingSize] old, new in
            if new.geometry != old.geometry,
               follow.geometryChanged(from: old.geometry, to: new.geometry) == .snapToEnd {
                model.position.scrollTo(edge: .bottom)
            }
            place.noteEdge(new.edge, following: follow.isNearBottom, size: readingSize)
            model.geometry = new.geometry
            model.edge = new.edge
        }
        .onChange(of: readingSize) { _, _ in follow.noteInput() }
    }

    private func restore(_ offset: CGFloat) {
        guard model.restores else { return }
        model.position.scrollTo(y: offset)
    }
}

@MainActor
func placeSection() {
    Report.section("4. A size change keeps the line being read in a transcript")
    let model = PlaceModel()
    let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 700, height: 520),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: PlaceProbeView(model: model))
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    guard waitUntil(4, { model.frames.count == model.rows.count && model.geometry.contentHeight > 0 }) else {
        Report.check(false, "the probe transcript laid out")
        return
    }
    spin(0.3)

    /// The row under the top edge, and the edge's place in it.
    func underEdge() -> (id: UUID, share: CGFloat)? {
        let top = model.edge.top
        for (id, frame) in model.frames where frame.minY <= top && top < frame.maxY {
            return (id, (top - frame.minY) / frame.height)
        }
        return nil
    }
    func offBy(_ anchor: (id: UUID, share: CGFloat)) -> CGFloat {
        guard let frame = model.frames[anchor.id] else { return .infinity }
        return abs((model.edge.top - frame.minY) - anchor.share * frame.height)
    }
    /// Waits until the layout has settled: the edge and the content's
    /// height the same over two reads a beat apart, so a busy Mac is given
    /// the time it takes rather than a fixed pause.
    func settle() {
        spin(0.25)
        var last = (model.edge.top, model.geometry.contentHeight)
        _ = waitUntil(4) {
            spin(0.15)
            let now = (model.edge.top, model.geometry.contentHeight)
            defer { last = now }
            return now == last
        }
    }
    func change(to tier: FontTier) {
        model.fontTier = tier
        settle()
    }
    func points(_ value: CGFloat) -> String { String(format: "%.1f pt", value) }

    model.position.scrollTo(y: model.geometry.contentHeight * 0.45)
    settle()
    for tier in [FontTier.larger, .xlarge, .small, .standard] {
        guard let before = underEdge() else {
            Report.check(false, "a row under the top edge before the change to \(tier.rawValue)")
            continue
        }
        change(to: tier)
        let error = offBy(before)
        Report.check(error <= 1.5, "to \(tier.rawValue): the row under the top edge keeps its line (off by \(points(error)))")
    }

    // The edge in the gap between two rows: the next row keeps its distance.
    let ordered = model.frames.sorted { $0.value.minY < $1.value.minY }
    let middle = ordered.count / 2
    let upper = ordered[middle].value, lower = ordered[middle + 1]
    model.position.scrollTo(y: (upper.maxY + lower.value.minY) / 2)
    settle()
    let lead = lower.value.minY - model.edge.top
    change(to: .larger)
    if let frame = model.frames[lower.key] {
        let error = abs((frame.minY - model.edge.top) - lead)
        Report.check(lead > 0 && error <= 1.5,
                     "the edge between two rows: the next row keeps its distance from it (off by \(points(error)))")
    }

    // Control: the same change with the place not kept — what a size change
    // does without this, and what the checks above would catch.
    model.restores = false
    if let before = underEdge() {
        change(to: .xlarge)
        let error = offBy(before)
        Report.check(error > 40, "control — with the place not kept, a change moves the line being read (off by \(points(error)))")
    }
    model.restores = true

    // At the end the follow engine keeps the end, both ways.
    change(to: .standard)
    model.position.scrollTo(edge: .bottom)
    settle()
    for tier in [FontTier.xlarge, .small, .larger] {
        change(to: tier)
        let distance = model.geometry.distanceFromEnd
        Report.check(abs(distance) <= 2, "at the end, a change to \(tier.rawValue) stays at the end (\(points(distance)) from it)")
    }
}

// MARK: - 5. The note preview keeps its place

@MainActor
final class NoteModel: ObservableObject {
    @Published var size: CGFloat = 14
    @Published var markdown: String = {
        var text = "# A long note\n\n"
        for i in 0..<40 {
            text += "## Part \(i)\n\n"
            text += "Paragraph \(i). " + String(repeating: "Words that wrap across the width of the page at any size. ", count: 6) + "\n\n"
            text += "- Item \(i).1 " + String(repeating: "list words ", count: 14) + "\n- Item \(i).2\n\n"
        }
        return text
    }()
}

struct NoteProbeView: View {
    @ObservedObject var model: NoteModel
    var body: some View {
        NoteWebView(markdown: model.markdown,
                    metadata: NoteHTML.Metadata(title: "A long note", model: nil, date: nil),
                    dark: false,
                    bodyPointSize: model.size)
    }
}

@MainActor
func noteSection() {
    Report.section("5. A size change keeps the reader's place in a note's preview (the real NoteWebView)")
    let model = NoteModel()
    let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 640, height: 520),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: NoteProbeView(model: model))
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }

    func findWeb(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews { if let web = findWeb(sub) { return web } }
        return nil
    }
    func js(_ web: WKWebView, _ script: String) -> Any? {
        var result: Any?
        var done = false
        web.evaluateJavaScript(script) { value, _ in result = value; done = true }
        waitUntil(5) { done }
        return result
    }
    guard waitUntil(4, { findWeb(host) != nil }), let web = findWeb(host) else {
        Report.check(false, "the preview made its web view")
        return
    }
    func loaded() -> Bool {
        !web.isLoading
            && (js(web, "document.readyState") as? String) == "complete"
            && ((js(web, "document.querySelectorAll('#sipai-note > *').length") as? Int) ?? 0) > 40
    }
    guard waitUntil(8, loaded) else {
        Report.check(false, "the preview loaded the note")
        return
    }

    /// Puts the top of the window at a known point of a known block —
    /// `offset` px into it, or `-offset` px above it — and marks it. Set up
    /// by the page's own geometry, not by the resize script's rule.
    func setUp(_ selector: String, index: Int, offset: Int) -> Bool {
        let script = """
        (function () {
          document.querySelectorAll('[data-probe]').forEach(function (e) { e.removeAttribute('data-probe'); });
          var el = document.querySelectorAll('\(selector)')[\(index)];
          if (!el) { return false; }
          el.setAttribute('data-probe', '1');
          window.scrollTo(0, Math.round(el.getBoundingClientRect().top + window.scrollY + (\(offset))));
          return true;
        })();
        """
        return js(web, script) as? Bool == true
    }
    /// The marked block's top and height, the page's scroll and body size.
    let measureScript = """
    (function () {
      var el = document.querySelector('[data-probe]');
      if (!el) { return null; }
      var r = el.getBoundingClientRect();
      return [r.top, r.height, window.scrollY, parseFloat(getComputedStyle(document.body).fontSize)];
    })();
    """
    func measure() -> [Double]? {
        guard let m = js(web, measureScript) as? [Double], m.count == 4 else { return nil }
        return m
    }

    let cases: [(what: String, selector: String, index: Int, offset: Int, size: CGFloat)] = [
        ("inside a paragraph", "#sipai-note > p", 20, 37, 18),
        ("inside a list item", "#sipai-note li", 31, 9, 12),
        ("in the gap above a heading", "#sipai-note > h2", 25, -8, 16),
    ]
    for c in cases {
        guard setUp(c.selector, index: c.index, offset: c.offset) else {
            Report.check(false, "\(c.what): the block to set up exists")
            continue
        }
        spin(0.2)
        guard let before = measure() else { continue }
        model.size = c.size
        _ = waitUntil(4) { (measure()?[3]).map { abs($0 - Double(c.size)) < 0.01 } ?? true }
        spin(0.3)
        guard let after = measure() else {
            Report.check(false, "\(c.what), to \(Int(c.size)) px: the page was changed in place, not loaded again (the marked block is gone)")
            continue
        }
        Report.check(abs(after[3] - Double(c.size)) < 0.01,
                     "\(c.what), to \(Int(c.size)) px: the body is set to the new size", "\(after[3])")
        // Inside a block: the top of the window at the same share of it.
        // Above one: the block the same distance below the top.
        let error = c.offset > 0
            ? abs(-after[0] / after[1] - (-before[0] / before[1])) * after[1]
            : abs(after[0] - before[0])
        Report.check(error <= 1.5, "\(c.what), to \(Int(c.size)) px: the top of the window stays on the same line (off by \(String(format: "%.1f", error)) px)")
    }

    // Control: a load of the page puts the reader back at the top — what a
    // size change did when it reloaded the page.
    _ = setUp("#sipai-note > p", index: 20, offset: 37)
    model.markdown += "\nOne more line.\n"
    spin(0.3)
    _ = waitUntil(8, loaded)
    let scrollY = js(web, "window.scrollY") as? Double ?? -1
    Report.check(measure() == nil && scrollY < 1, "control — a reload loses the marked block and the place (scrollY \(Int(scrollY)))")
}
