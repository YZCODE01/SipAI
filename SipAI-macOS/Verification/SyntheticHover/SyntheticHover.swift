// Shared by the harnesses that check what appears under the pointer
// (NewSessionSetup, UsageWindow, SkillsPane, SidebarNotices,
// LinkPointers); run.sh beside it checks the gate itself.
//
// Those harnesses point with made-up events — an entry into a tracking
// area, then a move — handed straight to the views of an offscreen
// window: the real pointer must stay the user's. SwiftUI honours a pointer
// event only while macOS reports the cursor visible, and macOS can report
// it hidden from a pointer at rest (under Screen Sharing, for one): then no
// `onHover` in the process is called, a bare test view's included,
// whichever way the event is handed in, and a check that needs hover fails
// with nothing wrong ("pointing at the message shows the pencil"), or
// passes having tested nothing ("pointing at a row's name fills nothing").
// So each harness runs its test program with macOS reporting the cursor
// visible inside that program alone (cursor_visible.sh and
// cursor_visibility.c, beside this file).
//
// A check that needs hover still goes through a `HoverGate`, for any other
// cause. The gate first points at a plain view of its own — nothing of
// SipAI's in it, so no regression in the app can quiet it — and while that
// view gets no hover, the check prints SKIP and why, and is neither passed
// nor failed. A check that fails asks the probe again before it is
// reported: hover that stopped in the middle of a run makes a SKIP too, and
// every later check of that gate skips with it. Wherever hover reaches
// SwiftUI, every check runs as written.
//
// SIPAI_SYNTHETIC_HOVER_OFF=1 makes the probe answer no, so the skips can
// be seen on a Mac where hover works; each SKIP then names the switch.
//
// Nothing here is part of the app target.

import AppKit
import SwiftUI

@MainActor
enum SyntheticHover {
    /// Set to 1, the probe answers no without pointing.
    static let offSwitch = "SIPAI_SYNTHETIC_HOVER_OFF"
    static var switchedOff: Bool { getenv(offSwitch).map { String(cString: $0) } == "1" }

    /// Why a gated check was skipped.
    static var reason: String {
        switchedOff
            ? "\(offSwitch)=1 is set, so this check is not run"
            : "a made-up pointer reaches no SwiftUI view in this process right now "
                + "(a plain test view got no hover), so this check cannot run"
    }

    /// Whether a made-up pointer reaches SwiftUI's hover now: a plain view
    /// in an offscreen window of its own is pointed at, and its `onHover`
    /// is waited for, up to `wait` seconds.
    static func reachesSwiftUI(wait: TimeInterval = 1.5) -> Bool {
        !switchedOff && probe(pointingAt: CGPoint(x: 40, y: 30), wait: wait)
    }

    /// The probe's window is 160 × 60 points; its hover view fills the
    /// left half. `p` is in points from the window's top-left — a point
    /// on the right half is beside the view, where no hover may land.
    static func probe(pointingAt p: CGPoint, wait: TimeInterval) -> Bool {
        final class Seen { var hover = false }
        let seen = Seen()
        let size = NSSize(width: 160, height: 60)
        let view = HStack(spacing: 0) {
            Color.gray.frame(width: size.width / 2, height: size.height)
                .onHover { inside in if inside { seen.hover = true } }
            Color.clear.frame(width: size.width / 2, height: size.height)
        }
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        defer { window.orderOut(nil) }
        point(at: NSPoint(x: p.x, y: size.height - p.y), in: window)
        let until = Date().addingTimeInterval(wait)
        while !seen.hover && Date() < until {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return seen.hover
    }

    /// The pointer comes to rest at `p` (window coordinates, y up): every
    /// view under it that tracks the mouse is told it entered each of its
    /// tracking areas there, then that it moved — the most any harness
    /// hands SwiftUI, so a probe that gets nothing this way stands for
    /// every way.
    static func point(at p: NSPoint, in window: NSWindow) {
        guard let root = window.contentView else { return }
        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
        let now = ProcessInfo.processInfo.systemUptime
        for view in views(root) where !view.trackingAreas.isEmpty {
            let local = view.convert(p, from: nil)
            guard view.bounds.contains(local) else { continue }
            for area in view.trackingAreas where area.rect.contains(local) || area.options.contains(.inVisibleRect) {
                if let enter = NSEvent.enterExitEvent(
                    with: .mouseEntered, location: p, modifierFlags: [], timestamp: now,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()), userData: nil) {
                    view.mouseEntered(with: enter)
                }
            }
            if let move = NSEvent.mouseEvent(
                with: .mouseMoved, location: p, modifierFlags: [], timestamp: now,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                view.mouseMoved(with: move)
            }
        }
    }
}

/// The checks of one harness section that need a made-up pointer to
/// reach SwiftUI. Made right before them: making it asks the probe.
@MainActor
final class HoverGate {
    typealias Report = @MainActor (_ label: String, _ ok: Bool, _ detail: () -> String) -> Void

    private let report: Report
    private let probe: @MainActor () -> Bool
    private let say: @MainActor (String) -> Void
    /// The probe's latest answer.
    private(set) var reaches: Bool

    /// `report` is the harness's own check, so a judged check prints as
    /// every other check of that harness does.
    init(report: @escaping Report,
         probe: @escaping @MainActor () -> Bool = { SyntheticHover.reachesSwiftUI() },
         say: @escaping @MainActor (String) -> Void = { print($0) }) {
        self.report = report
        self.probe = probe
        self.say = say
        reaches = probe()
    }

    /// A check that needs hover: judged by the harness's own check while
    /// the probe gets hover, a SKIP line while it does not.
    func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if reaches, !ok { reaches = probe() }
        guard reaches else {
            say("  SKIP \(label) — \(SyntheticHover.reason)")
            return
        }
        report(label, ok, detail)
    }
}
