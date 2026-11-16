// Settings → Usage's two laid-out reports, DRAWN: the real views,
// extracted from UsagePane.swift by run.sh, in an offscreen window no
// screen shows. Checks what only a drawing can — every week's column of
// codex's year is on screen at the narrowest and widest Settings column
// at every font tier, and a square pointed at answers at once with its
// bubble — and, with USAGE_RENDER=<dir>, writes PNGs of claude's table
// and codex's overview in light and dark to look at.
//
// Nothing here is part of the app target.
import SwiftUI
import AppKit

var failures = 0
var checks = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    checks += 1
    if ok {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

let renderDir = ProcessInfo.processInfo.environment["USAGE_RENDER"]

// Claude's block in the shape claude prints it, with made-up figures.
let claudeBlock = """
What's contributing to your limits usage?
Approximate, based on local sessions on this machine — does not include other devices or claude.ai. Behaviors are independent characteristics, not a breakdown.

Last 24h · 438 requests · 4 sessions
  94% of your usage was at >150k context
  61% of your usage was at max effort
  22% of your usage went to always-on context over 40k tokens

Last 7d · 2210 requests · 19 sessions
  100% of your usage was at max effort
  88% of your usage was at >150k context
  57% of your usage came from subagent-heavy sessions
  12% of your usage went to tool results over 10k tokens
  Top skills: /review 18%, /deploy 6%
  Top subagents: general-purpose 29%, Explore 7%, Plan 3%, +2 more
"""

// Each line reaches run.sh as it is printed: stopped by the clock after
// a page was drawn, the run is a view that hung, not a missing window
// server — and a line still in the buffer would not say which.
setvbuf(stdout, nil, _IOLBF, 0)

// Five months of made-up codex days, every seventh one skipped.
let today = Date()
let codexDays = CodexActivityCalendar.days()
let dayKey = CodexUsageHistory.dayFormatter(codexDays)
var days: [CodexUsageHistory.Day] = []
for back in 0..<150 where back % 7 != 3 {
    let date = codexDays.date(byAdding: .day, value: -back, to: today)!
    let tokens = Int64((sin(Double(back) / 9) + 1.2) * 150_000_000) + Int64(back) * 1_234_567
    days.append(.init(date: dayKey.string(from: date), tokens: tokens))
}
let history = CodexUsageHistory(lifetimeTokens: 5_143_008_862,
                                peakDailyTokens: days.map(\.tokens).max(),
                                longestRunningTurnSec: 30_756, currentStreakDays: 2, longestStreakDays: 16,
                                days: days)
let year = CodexActivityCalendar.make(history, today: today)

@MainActor
func host<V: View>(_ view: V, size: CGSize, dark: Bool) -> (NSWindow, NSHostingView<AnyView>) {
    let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let hosting = NSHostingView(rootView: AnyView(view))
    hosting.frame = NSRect(origin: .zero, size: size)
    window.contentView = hosting
    window.orderFrontRegardless()
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    hosting.layoutSubtreeIfNeeded()
    return (window, hosting)
}

@MainActor
func shot(_ view: NSView) -> NSBitmapImageRep? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

@MainActor
func png(_ rep: NSBitmapImageRep?, _ name: String) {
    guard let dir = renderDir, let rep, let data = rep.representation(using: .png, properties: [:]) else { return }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? data.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
}

/// A pixel of a snapshot by the view's own points (y down).
func pixel(_ rep: NSBitmapImageRep, _ view: NSView, _ p: CGPoint) -> NSColor? {
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    let x = Int(p.x * scale), y = Int(p.y * scale)
    guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
    return rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
}

func differs(_ a: NSColor?, _ b: NSColor?) -> Bool {
    guard let a, let b else { return false }
    return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
        + abs(a.blueComponent - b.blueComponent) > 0.04
}

/// A pointer delivered to a standing window: SwiftUI reads hover off its
/// hosting view's tracking area, so the first move is announced as an
/// entry into that area.
@MainActor
func point(at p: CGPoint, in host: NSHostingView<AnyView>, _ window: NSWindow) -> Bool {
    func inWindow(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: host.bounds.height - p.y) }
    guard let area = host.trackingAreas.first,
          let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: inWindow(p), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()),
                                             userData: nil),
          enter.trackingArea === area,
          let move = NSEvent.mouseEvent(with: .mouseMoved, location: inWindow(p), modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                        clickCount: 1, pressure: 1)
    else { return false }
    host.mouseEntered(with: enter)
    host.mouseMoved(with: move)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    host.layoutSubtreeIfNeeded()
    return true
}

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)
    let page = Color(nsColor: .windowBackgroundColor)
    let inset = CGPoint(x: 20, y: 48)
    // A bubble only a hover raises: with no made-up pointer reaching
    // SwiftUI, the bubble checks say SKIP.
    let hover = HoverGate(report: { check($0, $1, $2()) })

    for tier in [FontTier.standard, .xlarge] {
        let ratio = SipFont.ratio(tier.scale)
        let gapScale = SipFont.gapScale(12, fontScale: tier.scale, lineSpacingFactor: tier.lineSpacingFactor)
        for column in [420, 640] as [CGFloat] {
            let width = (column * ratio).rounded()
            for dark in [false, true] {
                let look = "\(tier.rawValue)-\(Int(column))-\(dark ? "dark" : "light")"

                // Claude's table, as the page sets its rhythm.
                let claude = ClaudeContributingView(text: claudeBlock)
                    .lineSpacing(SipFont.lineSpacing(12, fontScale: tier.scale, lineSpacingFactor: tier.lineSpacingFactor))
                    .frame(width: width, alignment: .leading)
                    .padding(20)
                    .background(page)
                    .environment(\.sipFontScale, tier.scale)
                    .environment(\.sipLineSpacingFactor, tier.lineSpacingFactor)
                    .fixedSize()
                let claudeSize = NSHostingView(rootView: claude).fittingSize
                let (claudeWindow, claudeHost) = host(claude, size: claudeSize, dark: dark)
                png(shot(claudeHost), "claude-\(look)")
                check("claude's table fits its column at \(look)", claudeSize.width <= width + 40 + 0.5,
                      "\(claudeSize.width)")
                claudeWindow.close()

                // Codex's overview, composed as the page composes it.
                let codex = VStack(alignment: .leading, spacing: 12 * gapScale) {
                    CodexHistoryFigures(history: history)
                    VStack(alignment: .leading, spacing: 6 * gapScale) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "Token activity").sipFont(12, weight: .semibold)
                            Text(verbatim: "·").sipFont(12).foregroundColor(SipDesign.textHint)
                            Text(verbatim: "Last 12 months").sipFont(12).foregroundColor(SipDesign.textSecondary)
                        }
                        TokenActivityCalendar(model: year)
                    }
                }
                    .frame(width: width, alignment: .leading)
                    .padding(20)
                    .background(page)
                    .environment(\.sipFontScale, tier.scale)
                    .environment(\.sipLineSpacingFactor, tier.lineSpacingFactor)
                    .fixedSize()
                let codexSize = NSHostingView(rootView: codex).fittingSize
                let (codexWindow, codexHost) = host(codex, size: codexSize, dark: dark)
                png(shot(codexHost), "codex-\(look)")
                codexWindow.close()

                // The calendar alone, at a known place, to find its squares.
                let m = TokenActivityCalendar.metrics(width: width, fontScale: tier.scale, calendar: year.calendar)
                check("every week's column fits the Settings column at \(look)", m.shown == CodexActivityCalendar.weekCount,
                      "\(m.shown) of \(CodexActivityCalendar.weekCount), pitch \(m.pitch)")
                let calendarView = TokenActivityCalendar(model: year)
                    .frame(width: width)
                    .padding(.leading, inset.x).padding(.top, inset.y).padding(.trailing, 20).padding(.bottom, 20)
                    .background(page)
                    .environment(\.sipFontScale, tier.scale)
                    .environment(\.sipLineSpacingFactor, tier.lineSpacingFactor)
                let size = CGSize(width: width + inset.x + 20, height: inset.y + m.height + 20)
                let (window, calendarHost) = host(calendarView, size: size, dark: dark)
                guard let before = shot(calendarHost) else { check("the calendar draws at \(look)", false); continue }
                let background = pixel(before, calendarHost, CGPoint(x: 4, y: 4))
                var drawnColumns = 0
                for c in 0..<m.shown {
                    let r = m.rect(column: c, row: 0)
                    if differs(pixel(before, calendarHost, CGPoint(x: inset.x + r.midX, y: inset.y + r.midY)), background) {
                        drawnColumns += 1
                    }
                }
                check("…and each one draws its square at \(look)", drawnColumns == m.shown, "\(drawnColumns) of \(m.shown)")

                // Point at the busiest day shown: a bubble rises over it.
                let busiest = year.weeks.indices.flatMap { c in (0..<7).map { (c, $0) } }
                    .max { (year.weeks[$0.0][$0.1]?.tokens ?? -1) < (year.weeks[$1.0][$1.1]?.tokens ?? -1) }!
                let target = m.rect(column: busiest.0 - (year.weeks.count - m.shown), row: busiest.1)
                let center = CGPoint(x: inset.x + target.midX, y: inset.y + target.midY)
                let delivered = point(at: center, in: calendarHost, window)
                let after = shot(calendarHost)
                if delivered, let after {
                    // The bubble's ink: what changed in a band just above the
                    // square, centred on it, against what was there before.
                    var changed = 0
                    var elsewhere = 0
                    for dx in stride(from: -60 * ratio, through: 60 * ratio, by: 1) {
                        for dy in stride(from: 6 * ratio, through: 16 * ratio, by: 1) {
                            let above = CGPoint(x: center.x + dx, y: inset.y + target.minY - dy)
                            if differs(pixel(after, calendarHost, above), pixel(before, calendarHost, above)) { changed += 1 }
                        }
                        let corner = CGPoint(x: inset.x + 4 + 60 * ratio + dx, y: inset.y + 4)
                        if differs(pixel(after, calendarHost, corner), pixel(before, calendarHost, corner)) { elsewhere += 1 }
                    }
                    hover.check("pointing at a square raises its bubble at once, above it, at \(look)",
                                changed > 40 && elsewhere == 0,
                                "\(changed) pixels changed above it, \(elsewhere) at the corner")
                } else {
                    print("  SKIP the pointer could not be delivered (no tracking area to enter) at \(look)")
                }
                png(after, "calendar-hover-\(look)")
                window.close()
            }
        }
    }

    // A block in a shape claude has not printed is claude's text, whole.
    let odd = ClaudeContributingView(text: "What's contributing to your limits usage?\nApproximate.\n\nLast 24h · 2 requests\n  Something claude added")
        .frame(width: 420, alignment: .leading).padding(20).background(page)
        .environment(\.sipFontScale, FontTier.standard.scale)
        .environment(\.sipLineSpacingFactor, FontTier.standard.lineSpacingFactor)
        .fixedSize()
    let (oddWindow, oddHost) = host(odd, size: NSHostingView(rootView: odd).fittingSize, dark: false)
    png(shot(oddHost), "claude-unread-shape")
    oddWindow.close()

    print("  \(checks - failures)/\(checks) render checks passed")
    if renderDir != nil { print("  PNGs in \(renderDir!)") }
    exit(failures == 0 ? 0 : 1)
}
