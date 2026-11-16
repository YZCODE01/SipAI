// The pointing hand over links, from the real DesignSystem.swift; see
// run.sh for what each section pins.
import AppKit
import ObjectiveC
import SwiftUI

setvbuf(stdout, nil, _IONBF, 0)
let root = CommandLine.arguments[1]
var passed = 0
var failed = 0

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        passed += 1
        print("  PASS  \(name)")
    } else {
        failed += 1
        let d = detail()
        print("  FAIL  \(name)\(d.isEmpty ? "" : " — \(d)")")
    }
}

func source(_ relative: String) -> String {
    (try? String(contentsOfFile: "\(root)/\(relative)", encoding: .utf8)) ?? ""
}

let urlA = URL(string: "https://example.com/a")!
let urlB = URL(string: "https://example.com/b")!

/// Text pieces; a piece with a URL is a link. Link pieces are drawn in a
/// colour of their own (blue for A, red for B) so their ink can be found.
func linked(_ parts: [(String, URL?)], boldPieces: Set<Int> = []) -> AttributedString {
    var text = AttributedString()
    for (i, (words, url)) in parts.enumerated() {
        var piece = AttributedString(words)
        if let url {
            piece.link = url
            piece.foregroundColor = url == urlA ? Color(red: 0, green: 0, blue: 1) : Color(red: 1, green: 0, blue: 0)
        }
        if boldPieces.contains(i) { piece.font = .system(size: 13, weight: .bold) }
        text.append(piece)
    }
    return text
}

let asciiText = linked([("Plain words ", nil), ("the link", urlA), (" after.", nil)])
let wideText = linked([("e\u{301}é 😀 👨‍👩‍👧 中文 ", nil), ("链接 link", urlA), (" end", nil)])
let twoText = linked([("See ", nil), ("one", urlA), (" and ", nil), ("two", urlB), (" here.", nil)])
let boldText = linked([("Read ", nil), ("Learn ", urlA), ("more", urlA), (" now.", nil)], boldPieces: [2])
let wrappedText = linked([("Read the ", nil),
                          ("link that is far too long for one line, so it wraps", urlA), (" and ends.", nil)])
let centredText = linked([("Centred text with ", nil), ("Learn more", urlA)])

// MARK: - §1 Where a Text's links are

print("§1 Where a Text's links are (UTF-16 offsets, as SwiftUI's layout reports them)")
#if LINK_HOTSPOTS
check("an ASCII sentence: the link's own characters",
      LinkHotspots.spans(in: asciiText) == [.init(range: 12..<20, url: urlA)])
check("after Chinese, a combining accent and emoji: counted in UTF-16, as the layout counts",
      LinkHotspots.spans(in: wideText) == [.init(range: 19..<26, url: urlA)])
check("two links: two spans, each with its own address",
      LinkHotspots.spans(in: twoText) == [.init(range: 4..<7, url: urlA), .init(range: 12..<15, url: urlB)])
check("bold inside a link: one span",
      LinkHotspots.spans(in: boldText) == [.init(range: 5..<15, url: urlA)])
check("no link: nothing", LinkHotspots.spans(in: AttributedString("No link here.")).isEmpty)
#else
check("LinkHotspots is in DesignSystem.swift", false, "not found — no link inside a text can show the hand")
#endif

// MARK: - Offscreen window plumbing

final class Host<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
final class Win: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}
extension NSApplication {
    // The window is offscreen and the app is never activated (it would
    // take the keyboard from whoever is using the Mac); a click is only
    // handed on by an app that reads itself as active.
    @objc var linkPointersProbe_isActive: Bool { true }
}

@MainActor
final class Stage<V: View> {
    let win: Win
    let host: Host<V>
    let size: NSSize
    init(_ view: V, size: NSSize) {
        self.size = size
        win = Win(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                  styleMask: [.borderless], backing: .buffered, defer: false)
        host = Host(rootView: view)
        host.sizingOptions = []
        win.contentView = host
        win.setContentSize(size)
        win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        win.orderFrontRegardless()
        pump(0.5)
    }
    func pump(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                NSApp.sendEvent(e)
            }
        }
    }
    func bitmap() -> NSBitmapImageRep {
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
    /// A point given from the top-left, in points.
    func windowPoint(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: size.height - p.y) }
    func hitViewName(_ p: CGPoint) -> String {
        let local = host.superview!.convert(windowPoint(p), from: nil)
        return host.hitTest(local).map { "\(type(of: $0))" } ?? "nil"
    }
    func click(_ p: CGPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: type, location: windowPoint(p), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: win.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1)!
            NSApp.postEvent(e, atStart: false)
        }
        pump(0.3)
    }
    func close() { win.orderOut(nil) }
}

/// The ink of one colour, one box per line it sits on (top-left points).
func inkBoxes(_ rep: NSBitmapImageRep, scale: CGFloat, matching: (NSColor) -> Bool) -> [CGRect] {
    var rows: [Int: (Int, Int)] = [:]
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), matching(c) else { continue }
            let seen = rows[y] ?? (x, x)
            rows[y] = (min(seen.0, x), max(seen.1, x))
        }
    }
    var boxes: [CGRect] = []
    var band: [Int] = []
    func flush() {
        guard let top = band.first, let bottom = band.last else { return }
        let left = band.compactMap { rows[$0]?.0 }.min()!, right = band.compactMap { rows[$0]?.1 }.max()!
        boxes.append(CGRect(x: CGFloat(left) / scale, y: CGFloat(top) / scale,
                            width: CGFloat(right - left + 1) / scale, height: CGFloat(bottom - top + 1) / scale))
        band = []
    }
    for y in rows.keys.sorted() {
        if let last = band.last, y > last + 2 { flush() }
        band.append(y)
    }
    flush()
    return boxes
}
func isBlue(_ c: NSColor) -> Bool { c.blueComponent > 0.6 && c.redComponent < 0.45 && c.greenComponent < 0.45 }
func isRed(_ c: NSColor) -> Bool { c.redComponent > 0.6 && c.blueComponent < 0.45 && c.greenComponent < 0.45 }

// MARK: - §2 The regions over real layouts

print("§2 The regions over real Text layouts")
#if LINK_HOTSPOTS
MainActor.assumeIsolated {
    method_exchangeImplementations(
        class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive))!,
        class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.linkPointersProbe_isActive))!)
    NSApplication.shared.setActivationPolicy(.accessory)

    var opened: [URL] = []
    struct Case {
        let name: String
        let text: AttributedString
        var selectable = false
        var centred = false
        var width: CGFloat = 300
        var lines = 1
    }
    let cases = [
        Case(name: "plain", text: asciiText),
        Case(name: "selectable", text: asciiText, selectable: true),
        Case(name: "centred", text: centredText, centred: true),
        Case(name: "wrapped over lines", text: wrappedText, width: 220, lines: 2),
        Case(name: "after Chinese and emoji", text: wideText),
        Case(name: "bold inside the link", text: boldText),
        Case(name: "selectable, wrapped", text: wrappedText, selectable: true, width: 220, lines: 2),
    ]
    for c in cases {
        @ViewBuilder func paragraph() -> some View {
            if c.selectable {
                Text(c.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .linkPointers(c.text)
            } else {
                Text(c.text).font(.system(size: 13)).multilineTextAlignment(c.centred ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .linkPointers(c.text)
            }
        }
        let size = NSSize(width: c.width, height: 80)
        let view = paragraph()
            .environment(\.openURL, OpenURLAction { url in opened.append(url); return .handled })
            .frame(width: size.width, alignment: c.centred ? .center : .leading)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.white)
        let stage = Stage(view, size: size)
        let rep = stage.bitmap()
        let scale = CGFloat(rep.pixelsWide) / size.width
        let boxes = inkBoxes(rep, scale: scale, matching: isBlue)
        check("\(c.name): the link's ink is on \(c.lines == 1 ? "one line" : "more than one line")",
              c.lines == 1 ? boxes.count == 1 : boxes.count >= c.lines, "\(boxes)")
        for (i, box) in boxes.enumerated() {
            let before = opened.count
            stage.click(CGPoint(x: box.midX, y: box.midY))
            check("\(c.name): a click on the link\(boxes.count > 1 ? " (line \(i + 1))" : "") opens it",
                  opened.count == before + 1 && opened.last == urlA, "\(opened.count - before) opened")
            if c.selectable {
                check("\(c.name): over the link\(boxes.count > 1 ? " (line \(i + 1))" : ""), SwiftUI's own view takes the pointer",
                      stage.hitViewName(CGPoint(x: box.midX, y: box.midY)).hasPrefix("Host<"),
                      stage.hitViewName(CGPoint(x: box.midX, y: box.midY)))
            }
        }
        if let first = boxes.first, first.minX > 6 {
            let beside = CGPoint(x: first.minX - 4, y: first.midY)
            if c.selectable {
                // Read before the click: a click there puts the field's
                // own editor over it, the same selection machinery.
                check("\(c.name): beside the link the selection field keeps the pointer (its I-beam, its selection)",
                      stage.hitViewName(beside) == "SelectionTextField", stage.hitViewName(beside))
            }
            let before = opened.count
            stage.click(beside)
            check("\(c.name): a click beside the link opens nothing", opened.count == before)
        }
        stage.close()
    }

    // Two links side by side: each region opens its own address.
    let two = Text(twoText).font(.system(size: 13)).linkPointers(twoText)
        .environment(\.openURL, OpenURLAction { url in opened.append(url); return .handled })
        .frame(width: 300, height: 40, alignment: .topLeading).background(Color.white)
    let stage = Stage(two, size: NSSize(width: 300, height: 40))
    let rep = stage.bitmap()
    let scale = CGFloat(rep.pixelsWide) / 300
    if let a = inkBoxes(rep, scale: scale, matching: isBlue).first, let b = inkBoxes(rep, scale: scale, matching: isRed).first {
        stage.click(CGPoint(x: a.midX, y: a.midY))
        let first = opened.last
        stage.click(CGPoint(x: b.midX, y: b.midY))
        check("two links side by side: each opens its own address", first == urlA && opened.last == urlB,
              "\(String(describing: first)), \(String(describing: opened.last))")
    } else {
        check("two links side by side: both inks found", false)
    }
    stage.close()

    // No link: nothing is laid over the text.
    let plain = Text("No link here at all.").font(.system(size: 13)).linkPointers(AttributedString("No link here at all."))
        .frame(width: 300, height: 40, alignment: .topLeading)
    let plainStage = Stage(plain, size: NSSize(width: 300, height: 40))
    check("a text without links gets no regions",
          LinkHotspots.spans(in: AttributedString("No link here at all.")).isEmpty
              && plainStage.hitViewName(CGPoint(x: 20, y: 8)).hasPrefix("Host<"))
    plainStage.close()

    #if LINK_HOTSPOT_BEHAVIOR
    // A link the view says is not followed (a reply's link to a file that
    // is not there): its region still takes the click, so neither it nor
    // the selectable Text under it opens anything. One that is followed
    // and carries hover text still opens.
    for (follows, selectable) in [(false, false), (false, true), (true, true)] {
        let words = selectable ? "selectable" : "plain"
        let base = Text(asciiText).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        let drawn = Group {
            if selectable { base.textSelection(.enabled).linkPointers(asciiText) } else { base.linkPointers(asciiText) }
        }
        let view = drawn
            .environment(\.linkHotspotBehavior, { _ in LinkHotspotBehavior(follows: follows, help: "Hover words") })
            .environment(\.openURL, OpenURLAction { url in opened.append(url); return .handled })
            .frame(width: 300, height: 40, alignment: .topLeading).background(Color.white)
        let stage = Stage(view, size: NSSize(width: 300, height: 40))
        let rep = stage.bitmap()
        let scale = CGFloat(rep.pixelsWide) / 300
        if let box = inkBoxes(rep, scale: scale, matching: isBlue).first {
            let before = opened.count
            stage.click(CGPoint(x: box.midX, y: box.midY))
            if follows {
                check("a followed link with hover text (\(words)) still opens", opened.count == before + 1)
            } else {
                check("a link that is not followed (\(words)) opens nothing on a click", opened.count == before,
                      "\(opened.count - before) opened")
                check("its region still lies over it (\(words))",
                      stage.hitViewName(CGPoint(x: box.midX, y: box.midY)).hasPrefix("Host<"),
                      stage.hitViewName(CGPoint(x: box.midX, y: box.midY)))
            }
        } else {
            check("the link's ink is found (\(words))", false)
        }
        stage.close()
    }
    #else
    check("links can say whether they are followed", false, "LinkHotspotBehavior not found")
    #endif
}
#else
check("the link regions exist", false, "LinkHotspots not found")
#endif

// MARK: - §3 The shared link button

print("§3 The shared link button")
#if LINK_BUTTON
MainActor.assumeIsolated {
    for enabled in [true, false] {
        let view = LinkButton(title: "Learn more", size: 12) {}
            .disabled(!enabled)
            .padding(6)
            .frame(width: 140, height: 30, alignment: .leading)
            .background(Color.white)
        let stage = Stage(view, size: NSSize(width: 140, height: 30))
        let rep = stage.bitmap()
        let scale = CGFloat(rep.pixelsWide) / 140
        let blue = inkBoxes(rep, scale: scale) { c in
            c.blueComponent > 0.7 && c.redComponent < 0.4 && c.greenComponent > 0.25 && c.greenComponent < 0.6
        }
        if enabled {
            check("enabled: drawn in SipAI's blue", !blue.isEmpty)
            // The underline: a run of blue as wide as the words, under them.
            check("enabled: underlined", blue.contains { $0.width > 40 })
        } else {
            check("disabled: grey, not blue", blue.isEmpty)
        }
        stage.close()
    }
}
#else
check("LinkButton is in DesignSystem.swift", false, "not found")
#endif

// MARK: - §4 The pointer and the wiring

print("§4 The pointer and the wiring")
let design = source("SipAI/Utilities/DesignSystem.swift")
check("a link region carries SwiftUI's link pointer (none for a link it does not follow) and opens through the environment's openURL",
      design.contains(".pointerStyle(does.follows ? .link : nil)") && design.contains("openURL(spot.url)"))
check("the link button carries the link pointer, and none while disabled",
      design.contains(".pointerStyle(isEnabled ? .link : nil)"))
let viewsDir = "\(root)/SipAI/Views"
var pushers: [String] = []
if let walker = FileManager.default.enumerator(atPath: viewsDir) {
    for case let file as String in walker where file.hasSuffix(".swift") {
        if source("SipAI/Views/\(file)").contains("NSCursor.pointingHand") { pushers.append(file) }
    }
}
check("no view pushes the pointing hand by hand", pushers.isEmpty, pushers.joined(separator: ", "))
let composer = source("SipAI/Views/Chat/AgentComposer.swift")
check("the context chip's ? keeps the hand, through the link pointer",
      composer.contains("struct HintHelpGlyph: View") && composer.contains(".pointerStyle(.link)")
          && !composer.contains("cursorPushed"))
let popover = source("SipAI/Views/UsagePopover.swift")
let usagePane = source("SipAI/Views/Settings/UsagePane.swift")
check("the usage window's Learn more and Use it, and Settings → Usage's pages, are the shared link button",
      popover.contains("LinkButton(title: String(localized: \"Learn more\"") && popover.contains("LinkButton(title: String(localized: \"Use it\"")
          && usagePane.contains("LinkButton(") && !popover.contains("struct UsageLinkButton"))
let guide = source("SipAI/Views/Settings/AgentGuidePane.swift")
check("Agent Initialization's Sign out is the shared link button",
      guide.contains("LinkButton(title: String(localized: \"Sign out\"") && !guide.contains(".underline()"))
let picker = source("SipAI/Views/Chat/SkillPicker.swift")
check("the skill picker's way to Settings is the shared link button, not AppKit's",
      picker.contains("LinkButton(title: String(localized: \"Open Settings → Agent Skills\"") && !picker.contains(".buttonStyle(.link)"))
let renderer = source("SipAI/Utilities/MarkdownRenderer.swift")
check("a reply's paragraphs, list items, headings and table cells carry the link regions",
      renderer.components(separatedBy: ".linkPointers(").count - 1 >= 3)
func precedes(_ text: String, _ first: String, _ then: String) -> Bool {
    guard let a = text.range(of: first), let b = text.range(of: then, range: a.upperBound..<text.endIndex) else { return false }
    return a.upperBound <= b.lowerBound
}
// The regions open through the environment's openURL, so they must sit
// inside the paragraph's own action (sipai:// links switch Settings).
check("the empty chat page's Learn more carries a region inside its own link action",
      precedes(source("SipAI/Views/Chat/ChatView.swift"), ".linkPointers(Self.noModelIntroduction)", ".environment(\\.openURL"))
check("About chats' Agent Initialization link carries a region inside its own link action",
      precedes(source("SipAI/Views/Settings/SettingsView.swift"), ".linkPointers(Self.subscriptionParagraph)", ".environment(\\.openURL"))

// The tripwire: what a hand pushed on hover meets.
MainActor.assumeIsolated {
    struct Pusher: View {
        @State private var pushed = false
        var body: some View {
            Color.green.frame(width: 100, height: 40)
                .onHover { inside in
                    if inside, !pushed { NSCursor.pointingHand.push(); pushed = true }
                }
        }
    }
    // A hover that never comes would leave no hand to be put back.
    let hover = HoverGate(report: { check($0, $1, $2()) })
    let stage = Stage(Pusher(), size: NSSize(width: 100, height: 40))
    let p = stage.windowPoint(CGPoint(x: 50, y: 20))
    let t = ProcessInfo.processInfo.systemUptime
    for area in stage.host.trackingAreas {
        if let e = NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [], timestamp: t,
                                          windowNumber: stage.win.windowNumber, context: nil, eventNumber: 0,
                                          trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()),
                                          userData: nil) {
            stage.host.mouseEntered(with: e)
        }
    }
    if let m = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: t,
                                  windowNumber: stage.win.windowNumber, context: nil, eventNumber: 0,
                                  clickCount: 0, pressure: 0) {
        stage.host.mouseMoved(with: m)
    }
    stage.pump(0.3)
    let pushedHand = NSCursor.current === NSCursor.pointingHand
    if let e = NSEvent.enterExitEvent(with: .cursorUpdate, location: p, modifierFlags: [], timestamp: t,
                                      windowNumber: stage.win.windowNumber, context: nil, eventNumber: 0,
                                      trackingNumber: 0, userData: nil) {
        stage.host.cursorUpdate(with: e)
    }
    hover.check("tripwire: SwiftUI's hosting view puts the arrow back over a hand pushed on hover "
          + "(why links use .pointerStyle)",
          pushedHand && NSCursor.current === NSCursor.arrow,
          "pushed \(pushedHand), after the cursor update \(NSCursor.current === NSCursor.arrow ? "arrow" : "not the arrow")")
    stage.close()
}

print("\nLinkPointers: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
