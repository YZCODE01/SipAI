// A sent message's pencil and copy appear only while the pointer is over the message, and
// SwiftUI's own hover hears nothing while macOS reports the cursor hidden: it drops every
// pointer event in that state, and ends a hover that is on at the next layout that moves things
// under the pointer. A Mac with its own screen hides the cursor only while the user types (until
// the mouse moves), and there SwiftUI's answer stands, as it always did. But macOS can also hide
// it from a pointer that has just stopped — under Screen Sharing, about a second after it stops —
// and for that alone the message carries an AppKit tracking area of its own that answers instead.
//
// Every app source is compiled into this program by run.sh (the app's `@main` dropped), and the
// REAL `MessageBubble` is hosted in a scroll view in an offscreen window under a throwaway home.
// run.sh preloads the pointer harnesses' cursor library (../SyntheticHover/cursor_visibility.c),
// which answers `CGCursorIsVisible` — what SwiftUI asks AppKit before it honours a pointer event —
// from $HARNESS_CURSOR_VISIBLE, so each check puts macOS's answer where it needs it.
//
// The pointer is played the way AppKit plays a real one: exited and entered for each tracking
// area it leaves or reaches, moved for each view whose area asked for moves, and the window's
// `mouseLocationOutsideOfEventStream` kept on it. AppKit hands such events to a tracking area only
// for a real pointer, so its own part is not exercised here: its pointer path asks nothing about
// the cursor's visibility, and the check in the app with a real pointer covers the rest.
//
//   run by run.sh: HiddenCursorHover

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
    while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

/// Puts macOS's answer to "is the cursor visible?", as the preloaded library gives it.
func cursorReported(visible: Bool) { setenv("HARNESS_CURSOR_VISIBLE", visible ? "1" : "0", 1) }

/// `CGCursorIsVisible`, looked up as the app looks it up.
func cursorVisibleAnswer() -> Int32 {
    typealias Query = @convention(c) () -> Int32
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible") else { return -1 }
    return unsafeBitCast(symbol, to: Query.self)()
}

/// The window reports where the harness's pointer is, as AppKit reports the real one, and takes
/// no key: a key press made here is for the app's key clock alone.
final class TestWindow: NSWindow {
    var pointer = NSPoint(x: -10_000, y: -10_000)
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown { return }
        super.sendEvent(event)
    }
}

final class Seen {
    nonisolated(unsafe) static var edits = 0
    nonisolated(unsafe) static var bubble: CGRect = .zero
    nonisolated(unsafe) static var control: [Bool] = []
    nonisolated(unsafe) static var controlFrame: CGRect = .zero
}

final class PageModel: ObservableObject {
    @Published var rowsAbove = 0
    @Published var tick = 0
}

let messageId = UUID()

/// The transcript's shape around one sent message: rows above it (to move it by a layout), a row
/// below whose text changes (a layout that moves nothing), and rows enough below to scroll.
struct Page: View {
    @ObservedObject var model: PageModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<model.rowsAbove, id: \.self) { i in
                    Text(verbatim: "a row above \(i)").frame(height: 40)
                }
                MessageBubble(message: ChatMessage(id: messageId, role: "user", content: "an older session"),
                              onEdit: { Seen.edits += 1 })
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { Seen.bubble = $0 }
                Text(verbatim: "tick \(model.tick)")
                ForEach(0..<20, id: \.self) { i in
                    Text(verbatim: "a row below \(i)").frame(height: 40)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// SwiftUI's own hover, bare: the control.
struct Control: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text(verbatim: "a plain view").padding(8)
                .onHover { Seen.control.append($0) }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { Seen.controlFrame = $0 }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The pointer

@MainActor final class Pointer {
    let window: TestWindow
    private var inside: [ObjectIdentifier: (view: NSView, area: NSTrackingArea)] = [:]
    /// The views the last move reached, for a failing check's detail.
    private(set) var reached: [String] = []

    init(window: TestWindow) { self.window = window }

    private func trackingViews() -> [NSView] {
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        return window.contentView.map(all)?.filter { !$0.trackingAreas.isEmpty } ?? []
    }

    private func tag(_ area: NSTrackingArea) -> Int {
        Int(bitPattern: Unmanaged.passUnretained(area).toOpaque())
    }

    /// Moves the pointer to `p` (window coordinates); `telling` picks the views that hear of it.
    func move(to p: NSPoint, telling: (NSView) -> Bool = { _ in true }) {
        window.pointer = p
        let t = ProcessInfo.processInfo.systemUptime
        var now: [ObjectIdentifier: (view: NSView, area: NSTrackingArea)] = [:]
        var movers: [NSView] = []
        for view in trackingViews() where telling(view) {
            let local = view.convert(p, from: nil)
            var asksForMoves = false
            for area in view.trackingAreas {
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                guard rect.contains(local) else { continue }
                now[ObjectIdentifier(area)] = (view, area)
                if area.options.contains(.mouseMoved) { asksForMoves = true }
            }
            if asksForMoves { movers.append(view) }
        }
        for (key, pair) in inside where now[key] == nil {
            if let e = NSEvent.enterExitEvent(with: .mouseExited, location: p, modifierFlags: [], timestamp: t,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              trackingNumber: tag(pair.area), userData: nil) {
                pair.view.mouseExited(with: e)
            }
        }
        for (key, pair) in now where inside[key] == nil {
            if let e = NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [], timestamp: t,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              trackingNumber: tag(pair.area), userData: nil) {
                pair.view.mouseEntered(with: e)
            }
        }
        for view in movers {
            if let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: t,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 0, pressure: 0) {
                view.mouseMoved(with: e)
            }
        }
        inside = now
        reached = movers.map { "\(type(of: $0))" }
        pump(0.5)
    }
}

// MARK: - Reading the page

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

/// The element the corner button labelled `name` offers to accessibility, while it is drawn.
@MainActor func cornerButton(_ name: String, in view: NSView) -> NSObject? {
    _ = view.accessibilityChildren()
    pump(0.3)
    return nodes(view).first { ax($0, "accessibilityRole") == "AXButton" && ax($0, "accessibilityLabel") == name }
}

@MainActor func press(_ o: NSObject?) {
    guard let o, o.responds(to: NSSelectorFromString("accessibilityPerformPress")) else { return }
    _ = o.perform(NSSelectorFromString("accessibilityPerformPress"))
    pump(0.4)
}

/// A view carrying an AppKit tracking area of its own that is neither the hosting view's nor the
/// scroll view's: the message's stand-in for SwiftUI's hover.
@MainActor func standIns(in root: NSView) -> [NSView] {
    func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
    return all(root).filter { view in
        view !== root && !(view is NSScrollView) && !(view is NSClipView) && !(view is NSScroller)
            && view.trackingAreas.contains { area in
                area.owner === view && area.options.contains(.mouseEnteredAndExited)
                    && !area.options.contains(.cursorUpdate)
            }
    }
}

/// A key press as typing delivers it: through the app, where SipAI's key clock notes the time.
/// Nothing takes it after that: the only window is borderless, so the app has no key window to
/// hand it to — no field is typed into, and no text view hides the real cursor. Not a second key
/// monitor that swallows it: AppKit calls local monitors in an order that changes from launch to
/// launch, and one that swallowed the key before the app's own saw it would leave the clock unset.
@MainActor func pressKey(in window: NSWindow) {
    guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: "a",
                                     charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0) else { return }
    NSApp.sendEvent(key)
    pump(0.2)
}

@MainActor func scrollView(in v: NSView) -> NSScrollView? {
    (v as? NSScrollView) ?? v.subviews.lazy.compactMap { scrollView(in: $0) }.first
}

// MARK: - The checks

@MainActor func run() {
    NSApplication.shared.setActivationPolicy(.accessory)
    // SwiftUI builds a page's accessibility tree only for an app an assistive client is driving;
    // this says one is.
    NSApplication.shared.setValue(true, forKey: "accessibilityEnhancedUserInterface")

    print("0. The state the checks put")
    cursorReported(visible: true)
    let visibleAnswer = cursorVisibleAnswer()
    cursorReported(visible: false)
    let hiddenAnswer = cursorVisibleAnswer()
    check("the preloaded library puts macOS's answer either way (CGCursorIsVisible 1, then 0)",
          visibleAnswer == 1 && hiddenAnswer == 0, "got \(visibleAnswer), \(hiddenAnswer)")

    // SwiftUI's own hover over a plain view, the cursor reported visible, then hidden.
    var controlSeen: [Bool: [Bool]] = [:]
    for visible in [true, false] {
        cursorReported(visible: visible)
        Seen.control = []
        let window = TestWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 300, height: 120),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Control())
        window.contentView = host
        window.orderFrontRegardless()
        pump(0.8)
        Pointer(window: window).move(to: NSPoint(x: Seen.controlFrame.midX,
                                                 y: host.bounds.height - Seen.controlFrame.midY))
        controlSeen[visible] = Seen.control
        window.orderOut(nil)
    }
    check("SwiftUI's own hover reaches a plain view while the cursor reads visible",
          controlSeen[true]?.contains(true) == true, "\(controlSeen[true] ?? [])")
    if controlSeen[false]?.contains(true) == true {
        print("  note SwiftUI's own hover now reaches a view while the cursor reads hidden: the stand-in "
              + "is no longer needed on this macOS (the checks below still hold)")
    } else {
        print("  ok   …and none while it reads hidden: the state the stand-in exists for")
    }

    let config = ConfigManager()
    let model = PageModel()
    let window = TestWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 600, height: 400),
                            styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: Page(model: model).environmentObject(config))
    window.contentView = host
    window.orderFrontRegardless()
    pump(1.2)

    /// Inside the message's grey block (window coordinates), and well below it.
    func onMessage() -> NSPoint { NSPoint(x: Seen.bubble.minX + 30, y: host.bounds.height - Seen.bubble.midY) }
    func belowMessage() -> NSPoint { NSPoint(x: Seen.bubble.minX + 30, y: host.bounds.height - Seen.bubble.maxY - 180) }
    func buttons() -> [String] {
        _ = host.accessibilityChildren()
        pump(0.3)
        return nodes(host).compactMap { ax($0, "accessibilityRole") == "AXButton" ? (ax($0, "accessibilityLabel") ?? "?") : nil }
    }
    func detail() -> String {
        "point \(window.pointer) message \(Seen.bubble) host \(host.bounds.size) reached \(pointer.reached) buttons \(buttons())"
    }
    func shown() -> (pencil: Bool, copy: Bool) {
        (cornerButton("Edit this message", in: host) != nil, cornerButton("Copy this message", in: host) != nil)
    }
    let pointer = Pointer(window: window)
    let top = scrollView(in: host)?.contentView.bounds.origin ?? .zero
    /// Scrolls the transcript by `dy` points under a pointer that does not move.
    func scroll(by dy: CGFloat) {
        guard let scroll = scrollView(in: host) else { return }
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + dy))
        scroll.reflectScrolledClipView(clip)
        pump(0.8)
    }
    /// Back at the top, the cursor reported visible and the pointer away from the message:
    /// SwiftUI hears it leave, so a section starts with nothing pointed at.
    func startClean() {
        if let scroll = scrollView(in: host) {
            scroll.contentView.scroll(to: top)
            scroll.reflectScrolledClipView(scroll.contentView)
            pump(0.6)
        }
        cursorReported(visible: true)
        pointer.move(to: belowMessage())
    }

    print("1. The cursor reported visible: SwiftUI's own hover, as on any Mac")
    cursorReported(visible: true)
    pointer.move(to: onMessage())
    var now = shown()
    check("pointing at the message shows the pencil and the copy button", now.pencil && now.copy, "\(now) \(detail())")
    pointer.move(to: belowMessage())
    now = shown()
    check("…and pointing away takes both away", !now.pencil && !now.copy, "\(now)")
    // The message's own tracking area alone told — not the hosting view's: what reaches the
    // message when a view drawn over it takes the pointer (a window's click-catching overlay).
    let ownOnly: (NSView) -> Bool = { view in
        view !== host && !(view is NSScrollView) && !(view is NSClipView) && !(view is NSScroller)
    }
    let quiet = Pointer(window: window)
    quiet.move(to: onMessage(), telling: ownOnly)
    now = shown()
    check("the message's own tracking area alone lights nothing while SwiftUI hears the pointer "
          + "(a view drawn over the message keeps it unlit, as before)", !now.pencil && !now.copy, "\(now)")
    quiet.move(to: belowMessage(), telling: ownOnly)

    print("2. The cursor reported hidden: SwiftUI hears nothing, the stand-in answers")
    cursorReported(visible: false)
    pointer.move(to: onMessage())
    now = shown()
    check("pointing at the message shows the pencil and the copy button", now.pencil && now.copy, "\(now) \(detail())")
    press(cornerButton("Edit this message", in: host))
    check("…and the pencil opens the edit", Seen.edits == 1, "edits: \(Seen.edits)")
    pointer.move(to: belowMessage())
    now = shown()
    check("pointing away takes both away", !now.pencil && !now.copy, "\(now)")
    // A layout that brings the message under a pointer that has not moved.
    model.rowsAbove = 2
    pump(0.6)
    let lowered = Seen.bubble
    model.rowsAbove = 0
    pump(0.6)
    let raised = Seen.bubble
    let arriving = NSPoint(x: lowered.minX + 30, y: host.bounds.height - lowered.midY)
    let movedApart = abs(lowered.midY - raised.midY) > raised.height / 2 + 4
    pointer.move(to: arriving)
    model.rowsAbove = 2
    pump(0.8)
    now = shown()
    check("a layout that moves the message under a resting pointer shows nothing (not pointed at "
          + "until the pointer moves, SwiftUI's own rule while the cursor is hidden)",
          movedApart && !now.pencil && !now.copy, "moved apart: \(movedApart) \(now)")
    model.rowsAbove = 0
    pump(0.6)
    pointer.move(to: belowMessage())

    print("3. The cursor turning hidden under a pointer resting on the message")
    startClean()
    pointer.move(to: onMessage())
    let beforeTyping = shown()
    pressKey(in: window)
    cursorReported(visible: false)
    // The transcript moves a little under the resting pointer, as it does while a turn streams:
    // a layout SwiftUI answers by ending its own hover once the cursor reads hidden.
    scroll(by: 4)
    now = shown()
    check("hidden by typing, as on any Mac: the pencil and the copy button go at the next layout, "
          + "as they always did", beforeTyping.pencil && beforeTyping.copy && !now.pencil && !now.copy,
          "before typing: \(beforeTyping) after: \(now)")
    startClean()
    pointer.move(to: onMessage())
    let before = shown()
    cursorReported(visible: false)
    scroll(by: 4)
    now = shown()
    check("hidden from a still pointer with no typing (Screen Sharing's way): they stay while the "
          + "transcript moves a little under it", before.pencil && before.copy && now.pencil && now.copy,
          "before: \(before) after: \(now)")
    pointer.move(to: belowMessage())
    now = shown()
    check("…and go once the pointer leaves (SwiftUI's own hover hears no leaving then)",
          !now.pencil && !now.copy, "\(now)")
    startClean()
    pointer.move(to: onMessage())
    let shownFirst = shown()
    cursorReported(visible: false)
    pointer.move(to: belowMessage())
    now = shown()
    check("pointed at while the cursor read visible, the message lets the pencil and the copy button go "
          + "when the pointer leaves after the cursor turned hidden, with no layout between (SwiftUI's own "
          + "hover stays on)", shownFirst.pencil && shownFirst.copy && !now.pencil && !now.copy,
          "first: \(shownFirst) after leaving: \(now)")

    print("4. The stand-in")
    startClean()
    let found = standIns(in: host)
    check("the message carries an AppKit tracking area of its own", found.count == 1,
          "found \(found.count): \(found.map { "\(type(of: $0))" })")
    if let view = found.first, let area = view.trackingAreas.first(where: { $0.owner === view }) {
        let inWindow = view.convert(area.rect, to: nil)
        let bubble = NSRect(x: Seen.bubble.minX, y: host.bounds.height - Seen.bubble.maxY,
                            width: Seen.bubble.width, height: Seen.bubble.height)
        check("it covers the message alone — not the scroll view's whole visible area",
              !area.options.contains(.inVisibleRect) && !inWindow.isEmpty
                && bubble.insetBy(dx: -1, dy: -1).contains(inWindow),
              "area \(inWindow) message \(bubble) options \(area.options.rawValue)")
        let point = onMessage()
        check("it takes no click: the message's text, links and buttons keep theirs",
              view.superview.map { view.hitTest($0.convert(point, from: nil)) == nil } ?? false)
    } else {
        check("it covers the message alone — not the scroll view's whole visible area", false, "no stand-in")
        check("it takes no click: the message's text, links and buttons keep theirs", false, "no stand-in")
    }
    cursorReported(visible: false)
    pointer.move(to: onMessage())
    let pointed = shown()
    let startFrame = Seen.bubble
    scroll(by: 150)
    now = shown()
    let scrolled = abs(Seen.bubble.minY - startFrame.minY) > 100
    check("scrolled out from under a pointer that has not moved, the message gives up the pencil and "
          + "the copy button", pointed.pencil && pointed.copy && scrolled && !now.pencil && !now.copy,
          "pointed: \(pointed) scrolled: \(scrolled) after: \(now)")

    cursorReported(visible: true)
    window.orderOut(nil)
    print(failures == 0 ? "PASS — every check held" : "FAIL — \(failures) check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

MainActor.assumeIsolated { run() }
