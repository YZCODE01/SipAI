// The welcome page and the first window's size, from the real sources.
// run.sh cuts `WelcomePage` and `FirstWindowSize` out of the app and
// compiles them with this file; see run.sh for what each section pins.
import AppKit
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

/// The text between a declaration's first line and the next top-level
/// closing brace — what run.sh cuts out, read here for the source checks.
func declaration(_ text: String, startingWith head: String) -> String {
    guard let start = text.range(of: head) else { return "" }
    let rest = text[start.lowerBound...]
    guard let end = rest.range(of: "\n}\n") else { return String(rest) }
    return String(rest[..<end.upperBound])
}

// MARK: - §1 The first window's size

print("§1 The first window's size")
#if FIRST_WINDOW_SIZE
do {
    func size(_ w: CGFloat, _ h: CGFloat) -> CGSize { FirstWindowSize.size(visible: CGSize(width: w, height: h)) }
    // Free areas as macOS reports them: the screen less the menu bar and
    // a Dock at the bottom.
    let air = size(1470, 919)
    check("a 13-inch MacBook Air's screen: about 70 % of it", air == CGSize(width: 1029, height: 643), "\(air)")
    let pro = size(1512, 945)
    check("a 14-inch MacBook Pro's screen: about 70 % of it", pro == CGSize(width: 1058, height: 662), "\(pro)")
    let large = size(2560, 1415)
    check("a 27-inch 2560 × 1440 display: held at 1200 × 800", large == CGSize(width: 1200, height: 800), "\(large)")
    let small = size(1024, 640)
    check("a small screen: never under the welcome page's 720 × 540", small == CGSize(width: 720, height: 540), "\(small)")
    let tiny = size(700, 500)
    check("a screen smaller than that: never larger than the free area", tiny == CGSize(width: 700, height: 500), "\(tiny)")
    var whole = true
    var inside = true
    for w in stride(from: 640.0, through: 3000.0, by: 37.3) {
        for h in stride(from: 480.0, through: 1800.0, by: 29.7) {
            let s = size(w, h)
            if s.width != s.width.rounded() || s.height != s.height.rounded() { whole = false }
            if s.width > w || s.height > h { inside = false }
        }
    }
    check("always whole points", whole)
    check("never larger than the free area", inside)
}
#else
check("FirstWindowSize is in SipAIApp.swift", false, "not found — the first window opens at a fixed size")
#endif

// MARK: - §2 The page, laid out and drawn

final class Win: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    @objc func hasKeyAppearance() -> Bool { true }
    @objc func hasMainAppearance() -> Bool { true }
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveControls() -> Bool { true }
}

print("§2 The page, laid out and drawn at the floor size")
#if WELCOME_PAGE
MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)
    let width: CGFloat = 720, height: CGFloat = 540
    let render = ProcessInfo.processInfo.environment["WELCOME_PAGE_RENDER"]
    for dark in [false, true] {
        let win = Win(contentRect: NSRect(x: -30000, y: -30000, width: width, height: height),
                      styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let page = WelcomePage(agentNames: "Claude Code, Codex and Kimi Code", onGetStarted: {})
        let host = NSHostingView(rootView: page.frame(width: width, height: height))
        host.sizingOptions = []
        win.contentView = host
        win.setContentSize(NSSize(width: width, height: height))
        win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        win.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            check("the page draws (\(dark ? "dark" : "light"))", false); continue
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = render {
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(dir)/welcome-\(dark ? "dark" : "light").png"))
        }
        let scale = CGFloat(rep.pixelsWide) / width
        // The background is the window colour, read off a corner.
        guard let bg = rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB) else { continue }
        func differs(_ c: NSColor) -> Bool {
            abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent)
                + abs(c.blueComponent - bg.blueComponent) > 0.12
        }
        func isSipBlue(_ c: NSColor) -> Bool {
            c.blueComponent > 0.75 && c.redComponent < 0.35 && c.greenComponent > 0.25 && c.greenComponent < 0.55
        }
        // The glass's water, in either appearance's rendition.
        func isWater(_ c: NSColor) -> Bool {
            c.redComponent > 0.45 && c.redComponent < 0.75 && c.greenComponent > 0.72 && c.blueComponent > 0.82
        }
        var water = 0
        var top = Int.max, bottom = -1
        var blueRows: [Int: (Int, Int)] = [:]   // row → (leftmost, rightmost) blue pixel
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), differs(c) else { continue }
                top = min(top, y); bottom = max(bottom, y)
                if isWater(c) { water += 1 }
                if isSipBlue(c) {
                    let seen = blueRows[y] ?? (x, x)
                    blueRows[y] = (min(seen.0, x), max(seen.1, x))
                }
            }
        }
        let mode = dark ? "dark" : "light"
        // Without the logo the room above would be measured from the title.
        check("\(mode): the logo is drawn (the catalog compiled beside the harness was found)", water > 50,
              "\(water) water pixels")
        let above = CGFloat(top) / scale, below = height - CGFloat(bottom + 1) / scale
        check("\(mode): everything fits with room above and below (≥ 24 pt)",
              top != Int.max && above >= 24 && below >= 24, "above \(above), below \(below)")
        // Three symbols and the button: SipAI's blue in at least four
        // separate bands down the page; the last band is the button.
        var bands: [[Int]] = []
        for y in blueRows.keys.sorted() {
            if let lastRow = bands.last?.last, y == lastRow + 1 { bands[bands.count - 1].append(y) } else { bands.append([y]) }
        }
        check("\(mode): the symbols and the button are drawn in SipAI's blue", bands.count >= 4, "\(bands.count) bands")
        if let button = bands.last {
            let left = button.compactMap { blueRows[$0]?.0 }.min() ?? 0
            let right = button.compactMap { blueRows[$0]?.1 }.max() ?? 0
            let centre = CGFloat(left + right + 1) / 2 / scale
            check("\(mode): the button sits on the page's centre line", abs(centre - width / 2) <= 1,
                  "centre \(centre)")
            let buttonWidth = CGFloat(right - left + 1) / scale
            check("\(mode): the button is wide enough to read as the page's one action (≥ 180 pt)",
                  buttonWidth >= 180, "\(buttonWidth) pt")
        }
        win.orderOut(nil)
    }
}
#else
check("WelcomePage is in OnboardingView.swift", false, "not found — the page cannot be drawn on its own")
#endif

// MARK: - §3 What the sources say

print("§3 What the sources say")
let onboarding = source("SipAI/Views/OnboardingView.swift")
let page = declaration(onboarding, startingWith: "struct WelcomePage: View")
check("the page uses macOS's own text styles",
      page.contains(".font(.largeTitle") && page.contains(".font(.title3)")
          && page.contains(".font(.headline)") && page.contains(".font(.body)"))
check("no size between macOS's text sizes, no added line spacing, no tightened title",
      !page.isEmpty && !page.contains("12.5") && !page.contains(".lineSpacing(") && !page.contains(".tracking("))
check("the symbols stand alone, without circles behind them", !page.isEmpty && !page.contains("Circle()"))
check("the circles' colour went with them (SipDesign.iconCircleBg has no user left)",
      !source("SipAI/Utilities/DesignSystem.swift").contains("iconCircleBg"))
check("Get Started is the system's large prominent button in SipAI's blue, darker under the pointer",
      page.contains(".buttonStyle(.borderedProminent)") && page.contains(".controlSize(.large)")
          && page.contains("SipDesign.blueHover") && page.contains(".keyboardShortcut(.defaultAction)"))
check("the button reads Get Started, in the title case macOS buttons use (the user's decision), with its Chinese",
      page.contains("Text(\"Get Started\")") && !page.contains("Text(\"Get started\")")
          && source("SipAI/Resources/Localizable.xcstrings").contains("\"Get Started\" : {")
          && !source("SipAI/Resources/Localizable.xcstrings").contains("\"Get started\" : {"))
check("OnboardingView draws the page and still completes onboarding on Get Started",
      onboarding.contains("WelcomePage(") && onboarding.contains("completeOnboarding(installedAgents:"))
let app = source("SipAI/SipAIApp.swift")
check("the first window is placed by the rule, centred on the screen",
      app.contains(".defaultWindowPlacement") && app.contains("FirstWindowSize.size(visible:")
          && app.contains("WindowPlacement(.center"))
check("no fixed first-window size beside it", !app.contains(".defaultSize(width: 720, height: 540)"))
check("the welcome page's minimum is the rule's floor",
      app.contains("FirstWindowSize.floor.width") && app.contains("FirstWindowSize.floor.height"))

print("\nWelcomePage: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
