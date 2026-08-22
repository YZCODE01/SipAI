// Behavioural check of DRAGGING a file onto the chat composer.
//
// The bug it pins: dragging a file onto the chatbox typed the file's
// PATH into it and staged nothing, while the + button worked. The cause
// is that NSTextView answers a file drop by inserting the path, and it
// cannot be filtered out of the way — a fresh text view is registered
// for no dragged types at all, and AppKit registers the whole set
// (NSFilenamesPboardType included) when the view enters a window and
// takes first responder. So any filter applied while the view is being
// built is already undone by the time a drop can land, and the text
// view is then the deepest registered view under the pointer: it wins
// the drag outright and no ancestor drop target ever sees the file.
//
// The cure is interception, and this drives it for real: the SHIPPING
// MultilineTextField is hosted in an offscreen window, the actual
// NSTextView subclass it installs is found by walking the view tree,
// and a file drag carrying a real file URL is delivered to it.
//
// Pass 1 re-measures the hazard itself against a stock NSTextView, so
// the harness fails if a future macOS stops re-registering and someone
// is tempted to go back to the cheap filter.
//
// Needs a logged-in GUI session for the window server; run.sh reports
// SKIP rather than a failure it cannot judge.
//
// Nothing here is part of the app target: this directory sits outside
// SipAI/, so these files are never compiled into the product.

import SwiftUI
import AppKit

var failures: [String] = []
func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    if ok { print("  ok    \(label)") }
    else {
        let extra = detail()
        print("  FAIL  \(label)\(extra.isEmpty ? "" : " — \(extra)")")
        failures.append(label)
    }
}
func section(_ t: String) { print("\n\(t)") }

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// A real file to drag, and a pasteboard carrying it the way Finder does.
let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("SipAIChatFileDrop-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let dropped = dir.appendingPathComponent("quarterly notes.txt")
try! "hello".write(to: dropped, atomically: true, encoding: .utf8)

func pasteboard(named: String, _ fill: (NSPasteboard) -> Void) -> NSPasteboard {
    let pb = NSPasteboard(name: NSPasteboard.Name(named))
    pb.clearContents()
    fill(pb)
    return pb
}
let filePB = pasteboard(named: "SipAIDropFile") { $0.writeObjects([dropped as NSURL]) }
let textPB = pasteboard(named: "SipAIDropText") { $0.setString("typed text", forType: .string) }
let webPB  = pasteboard(named: "SipAIDropWeb")  { $0.writeObjects([URL(string: "https://example.com")! as NSURL]) }

/// NSDraggingInfo is a protocol, so a drag can be delivered without a
/// drag source, a mouse or a second process.
final class FakeDrag: NSObject, NSDraggingInfo {
    let pb: NSPasteboard
    init(_ pb: NSPasteboard) { self.pb = pb }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic, .link] }
    var draggingLocation: NSPoint { NSPoint(x: 20, y: 20) }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pb }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var animatesToDestination: Bool { get { false } set {} }
    var numberOfValidItemsForDrop: Int { get { 1 } set {} }
    var draggingFormation: NSDraggingFormation { get { .default } set {} }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

/// Deliver a drag the way AppKit does: enter, update, prepare, perform.
@discardableResult
func deliver(_ pb: NSPasteboard, to view: NSView) -> (entered: NSDragOperation, performed: Bool) {
    let drag = FakeDrag(pb)
    let entered = view.draggingEntered(drag)
    _ = view.draggingUpdated(drag)
    guard view.prepareForDragOperation(drag) else { return (entered, false) }
    let done = view.performDragOperation(drag)
    view.concludeDragOperation(drag)
    return (entered, done)
}

func settle(_ seconds: TimeInterval = 0.3) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

func window(_ content: NSView) -> NSWindow {
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
    win.contentView = content
    content.frame = win.contentView!.bounds
    win.makeKeyAndOrderFront(nil)
    return win
}

func firstTextView<T: NSView>(_ root: NSView, of type: T.Type) -> T? {
    if let hit = root as? T { return hit }
    for sub in root.subviews {
        if let hit = firstTextView(sub, of: type) { return hit }
    }
    return nil
}

// MARK: - 1. The hazard: a stock NSTextView cannot be filtered out of the way

section("1. Why a dragged-type filter cannot work (stock NSTextView)")

let stockScroll = NSTextView.scrollableTextView()
let stockTV = stockScroll.documentView as! NSTextView
stockTV.isRichText = false
check(stockTV.registeredDraggedTypes.isEmpty,
      "a freshly built NSTextView is registered for NO dragged types",
      "so unregisterDraggedTypes() at build time is a no-op")

// The filter the app used to apply, at the moment it used to apply it.
stockTV.unregisterDraggedTypes()
stockTV.registerForDraggedTypes([.string])

let stockWin = window(NSView())
stockWin.contentView!.addSubview(stockScroll)
stockScroll.frame = stockWin.contentView!.bounds
stockWin.makeFirstResponder(stockTV)
app.activate(ignoringOtherApps: true)
settle(0.8)

let reRegistered = stockTV.registeredDraggedTypes.map(\.rawValue)
check(reRegistered.contains("NSFilenamesPboardType"),
      "AppKit re-registers file drag types once the view is in a window",
      "registered: \(reRegistered.count) types")
check(reRegistered.count > 1,
      "the build-time filter is gone by the time a drop can land",
      "\(reRegistered.count) types registered, filter left 1")

deliver(filePB, to: stockTV)
check(stockTV.string.contains("quarterly notes.txt"),
      "an unmodified NSTextView types the dropped file's PATH",
      "text: \"\(stockTV.string)\"")

// MARK: - 2. The shipping composer, hosted and dropped on for real

section("2. The real MultilineTextField takes a dropped file")

var staged: [URL] = []
var targeting: [Bool] = []
let composer = MultilineTextField(text: .constant(""),
                                  onSubmit: {},
                                  spellChecking: true,
                                  onDropFiles: { staged.append(contentsOf: $0) },
                                  onDropTargeted: { targeting.append($0) })
let host = NSHostingView(rootView: composer)
let win = window(host)
settle(0.8)

guard let field = firstTextView(host, of: DropForwardingTextView.self) else {
    print("  FAIL  the composer installs DropForwardingTextView")
    print("\n0 checks passed — the representable no longer installs the subclass")
    exit(1)
}
check(true, "the composer installs DropForwardingTextView")
win.makeFirstResponder(field)
settle(0.4)

check(field.onDropFiles != nil,
      "its drop closure is wired through the representable")

let registered = field.registeredDraggedTypes.map(\.rawValue)
check(registered.contains("NSFilenamesPboardType"),
      "it is still the view AppKit hands file drags to",
      "which is exactly why it has to forward them")

let fileResult = deliver(filePB, to: field)
check(fileResult.entered == .copy, "a file drag is accepted (.copy)")
check(fileResult.performed, "the drop is performed")
check(staged == [dropped],
      "the dropped file is handed to the host's staging path",
      "staged: \(staged.map(\.lastPathComponent))")
check(field.string.isEmpty,
      "and its path is NOT typed into the composer",
      "text: \"\(field.string)\"")
check(targeting.first == true && targeting.last == false,
      "the card's drop highlight is turned on and back off",
      "\(targeting)")

// MARK: - 3. What must still behave like a stock text view

section("3. Non-file drags are untouched")

staged.removeAll()
field.string = ""
deliver(textPB, to: field)
check(staged.isEmpty, "a TEXT drag stages nothing")
check(field.string.contains("typed text"),
      "a TEXT drag still inserts its text",
      "text: \"\(field.string)\"")

staged.removeAll()
field.string = ""
deliver(webPB, to: field)
check(staged.isEmpty,
      "a web URL dragged from a browser is not staged as a file",
      "staged: \(staged)")

section("4. An inline editor (no drop closure) keeps typing the path")

let plain = MultilineTextField(text: .constant(""), onSubmit: {}, spellChecking: true)
let plainHost = NSHostingView(rootView: plain)
let plainWin = window(plainHost)
settle(0.6)
if let editor = firstTextView(plainHost, of: DropForwardingTextView.self) {
    plainWin.makeFirstResponder(editor)
    settle(0.3)
    check(editor.onDropFiles == nil, "it has no drop closure")
    deliver(filePB, to: editor)
    check(editor.string.contains("quarterly notes.txt"),
          "so a dragged path is still typed in, as it was before",
          "text: \"\(editor.string)\"")
} else {
    check(false, "the inline editor's text view was found")
}

// MARK: - 5. The subclass swap did not reshape the composer

section("5. The swapped-in subclass inherits the stock configuration")

let reference = NSTextView.scrollableTextView()
let ref = reference.documentView as! NSTextView
check(field.isVerticallyResizable == ref.isVerticallyResizable
        && field.isHorizontallyResizable == ref.isHorizontallyResizable,
      "resizability matches a stock scrollableTextView()")
// Only the HEIGHT ceiling is comparable: a vertically resizable text
// view rewrites the width halves of min/max as it lays out, and this
// one has been in a window. The height ceiling is also the value a
// hand-rolled replication gets wrong — building the stack by hand
// yields CGFloat.greatestFiniteMagnitude where AppKit uses 1e7.
check(field.maxSize.height == ref.maxSize.height,
      "the vertical growth ceiling matches a stock scrollableTextView()",
      "mine \(field.maxSize.height) vs stock \(ref.maxSize.height)")
check(field.autoresizingMask == ref.autoresizingMask,
      "autoresizing mask matches",
      "\(field.autoresizingMask.rawValue) vs \(ref.autoresizingMask.rawValue)")
check(field.textContainer?.widthTracksTextView == ref.textContainer?.widthTracksTextView,
      "the text container still tracks the view's width")
check((field.textLayoutManager != nil) == (ref.textLayoutManager != nil),
      "it is the same TextKit generation as stock")

print("\n\(failures.isEmpty ? "PASS" : "FAIL") — \(failures.count) failing check(s)")
exit(failures.isEmpty ? 0 : 1)
