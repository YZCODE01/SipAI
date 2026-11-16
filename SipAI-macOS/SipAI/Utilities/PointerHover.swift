// PointerHover.swift
// `onHover` that keeps answering while macOS hides the cursor from a still
// pointer.
//
// SwiftUI's own hover asks AppKit whether the cursor is hidden before it honours
// a pointer event, and while the answer is yes it hears nothing: a pointer
// arriving starts no hover, one leaving ends none, and the next layout that
// moves things under the pointer ends a hover that is on. That suits the one way
// a Mac with its own screen hides the cursor — while the user types, until the
// mouse moves. But macOS can also hide it from a pointer that has simply stopped
// — under Screen Sharing, for one, about a second after it stops — and then
// whatever is drawn only under the pointer goes as soon as the pointer rests on
// it, or never comes.

import AppKit
import SwiftUI

extension View {
    /// `onHover`, still answering while macOS hides the cursor from a pointer
    /// that has stopped.
    ///
    /// SwiftUI's hover is the answer whenever the cursor reads visible, and
    /// whenever a key was pressed since the pointer last moved over the view
    /// (the cursor hidden by typing): exactly as with `onHover`, so a view
    /// covered by another that takes the pointer stays unpointed, and a hover
    /// SwiftUI holds goes once the user types. Only for a cursor hidden without
    /// typing does an AppKit tracking area of the view's own answer instead —
    /// AppKit hands it the pointer whatever the cursor reports. The answer is
    /// settled when either source speaks, so a hover the tracking area is
    /// already keeping (the cursor hidden from a still pointer before the first
    /// key) stays through typing, until the pointer next moves. A layout that
    /// brings the view under a pointer that has not moved never points at it (no
    /// arrival is heard), which is SwiftUI's own rule for a hidden cursor.
    func onPointerHover(perform action: @escaping (Bool) -> Void) -> some View {
        modifier(PointerHoverModifier(action: action))
    }
}

/// macOS's answer to whether the cursor is visible: the question SwiftUI's hover
/// asks AppKit before it honours a pointer event.
enum CursorVisibility {
    private typealias Query = @convention(c) () -> Int32

    /// `CGCursorIsVisible` is deprecated with no replacement, so it is looked up
    /// rather than linked — a direct call is a build warning. Missing, the cursor
    /// counts as visible, which leaves SwiftUI's own hover as the only answer.
    private static let query: Query? = {
        // RTLD_DEFAULT: every image loaded in the process.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible") else {
            return nil
        }
        return unsafeBitCast(symbol, to: Query.self)
    }()

    static var reportedHidden: Bool { query.map { $0() == 0 } ?? false }
}

/// When SipAI last received a key press. A cursor hidden since then was hidden
/// by typing — AppKit hides it until the mouse moves — and there SwiftUI's own
/// hover is the right answer.
private enum KeyPressClock {
    private static var monitor: Any?
    private(set) static var lastPress: TimeInterval = 0

    /// Installed once, for the life of the app. It only notes the time: every
    /// key goes on as it came.
    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            lastPress = event.timestamp
            return event
        }
    }
}

private struct PointerHoverModifier: ViewModifier {
    let action: (Bool) -> Void
    /// Bookkeeping, never drawn: a plain object, so writing it re-renders nothing.
    @State private var hover = PointerHoverState()

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hover.swiftUI = inside
                report()
            }
            .background(
                PointerTrackingReader { inside, heardAt in
                    hover.tracked = inside
                    hover.trackedAt = heardAt
                    report()
                }
                .accessibilityHidden(true)
            )
    }

    private func report() {
        if let pointed = hover.settle() { action(pointed) }
    }
}

private final class PointerHoverState {
    /// What SwiftUI's `onHover` last said.
    var swiftUI = false
    /// What the view's own tracking area last said, and when it last heard the
    /// pointer (an event's timestamp).
    var tracked = false
    var trackedAt: TimeInterval = 0
    private var reported = false

    /// The answer, when it changed since the last one handed out — judged at the
    /// moment either source speaks. A cursor hidden without typing since the
    /// pointer last moved here leaves SwiftUI's last word stale (a hover it ended
    /// though the pointer stayed, a start it dropped, an end it never heard), so
    /// the tracking area answers; any other time SwiftUI does.
    func settle() -> Bool? {
        let standIn = CursorVisibility.reportedHidden && trackedAt > KeyPressClock.lastPress
        let pointed = standIn ? tracked : swiftUI
        guard pointed != reported else { return nil }
        reported = pointed
        return pointed
    }
}

private struct PointerTrackingReader: NSViewRepresentable {
    /// Whether the pointer is over the view, and when the view last heard it.
    let heard: (Bool, TimeInterval) -> Void

    func makeNSView(context: Context) -> PointerTrackingView {
        KeyPressClock.start()
        let view = PointerTrackingView()
        view.onPointer = heard
        return view
    }

    func updateNSView(_ view: PointerTrackingView, context: Context) {
        // The view outlives this struct: hand it the current closure every pass.
        view.onPointer = heard
        // A pass is also what follows a layout that moved the view.
        view.recheck()
    }
}

/// An AppKit tracking area over the view, following the pointer whatever the
/// cursor reports.
private final class PointerTrackingView: NSView {
    var onPointer: ((Bool, TimeInterval) -> Void)?
    private var inside = false
    private var heardAt: TimeInterval = 0
    private var area: NSTrackingArea?
    private var scrollObserver: NSObjectProtocol?

    // Never the target of a click: whatever is drawn over this view takes those.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        placeTrackingArea()
        if window == nil { update(inside: false) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        placeTrackingArea()
        recheck()
    }

    /// One area over the whole view, put in place by the view itself: AppKit
    /// asks for `updateTrackingAreas` only of a window on a screen. The area
    /// moves with the view when it scrolls; which part of the view is on screen
    /// is judged when the pointer speaks.
    private func placeTrackingArea() {
        let wanted = window != nil && !bounds.isEmpty
        // SwiftUI sets the frame on every layout pass: an area already in place
        // stays.
        if wanted, let area, area.rect == bounds { return }
        if let area { removeTrackingArea(area) }
        area = nil
        guard wanted else { return }
        let placed = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                    owner: self)
        addTrackingArea(placed)
        area = placed
    }

    /// The part of the view on screen. A view SwiftUI hosts inside a scroll view
    /// reports a `visibleRect` reaching past its own bounds (the clip view's whole
    /// area), so the visible rect alone would answer for the pointer anywhere in
    /// the scroll view.
    private var shownRect: NSRect { bounds.intersection(visibleRect) }

    /// Moved under the pointer by a scroll or a layout: a pointer the view left is
    /// no longer over it. One it arrived under is not over it until the pointer
    /// moves — AppKit sends no arrival for an area around a resting pointer, and
    /// the next move tells.
    func recheck() {
        if inside, !pointerIsOver { update(inside: false) }
    }

    // Not passed on: the next responder up is the hosting view, which would take
    // these for its own tracking area's.
    override func mouseEntered(with event: NSEvent) { judge(event) }
    override func mouseMoved(with event: NSEvent) { judge(event) }
    override func mouseExited(with event: NSEvent) {
        heardAt = event.timestamp
        update(inside: false, always: true)
    }

    private var pointerIsOver: Bool {
        guard let window else { return false }
        return shownRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func judge(_ event: NSEvent) {
        heardAt = event.timestamp
        update(inside: shownRect.contains(convert(event.locationInWindow, from: nil)), always: true)
    }

    /// Tells the host. Every pointer event is told (`always`), not only a
    /// change: when the pointer was last heard decides whether this view's answer
    /// counts.
    private func update(inside now: Bool, always: Bool = false) {
        let changed = now != inside
        if changed {
            inside = now
            watchScrolling(now)
        }
        if changed || always { onPointer?(inside, heardAt) }
    }

    /// While the pointer is over the view, a scroll that carries the view away
    /// lets it go at once rather than at the pointer's next move.
    private func watchScrolling(_ on: Bool) {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        guard on, let clip = enclosingScrollView?.contentView else { return }
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck() }
        }
    }
}
