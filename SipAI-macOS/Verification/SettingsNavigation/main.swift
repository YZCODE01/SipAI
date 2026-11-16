// main.swift — Settings as a mode of the main window.
//
//   1. The column rule (`SettingsPageLayout`, compiled whole) over every
//      pane width from 0 to 2,000 pt at every font tier, and at the
//      window sizes the app actually opens with.
//   2. The page, laid out for real: the Settings page's own `body`
//      (EXTRACTED from SettingsView.swift by run.sh) hosted in an
//      offscreen window around a stand-in pane — the column's width, its
//      centring, its content's left edge, the sideways scroll once the
//      pane is too narrow, and its gaps: the agent session's band under
//      the top bar, the first line where a transcript's first row sits,
//      a paragraph wrapping at the column's edge, and a page scrolled to
//      its end stopping as far above the bottom as it starts below the
//      bar. 2b hosts the REAL system prompt and roles of Chat Settings
//      in that page: its two boxes are fixed heights that never grow
//      with the window.
//   3. The menu over the Settings row and the sidebar's section list
//      — and 3b, the menu's PLACEMENT: ContentView's real overlay block
//      (extracted by run.sh) over a stand-in layout, its fill's pixels
//      read against the row's measured frame.
//      (SettingsNavigation.swift, compiled whole): each section's label
//      measured against the sidebar's narrowest width, the menu's height
//      against the shortest window, and — with SETTINGS_NAV_RENDER=<dir>
//      — PNGs of both, and of the page, to look at.
//   4. The wiring a headless run cannot drive, read off the sources:
//      Settings replaces the centre pane (first branch, no sheet), is a
//      layer over the routes (closed by a search result and a
//      notification click, never by `startNewChat`), keeps the sidebar's
//      ordinary list mounted, and hosts the factory reset's alerts where
//      a partial wipe leaves them standing; the sections' order and
//      names, in both languages, Chat Settings' parts in their order,
//      every in-app link to a section naming one that exists, and the
//      Privacy page's paragraphs — said there once, not again in Help,
//      Chat Settings or Updates; the band shared
//      with the agent session; and no paragraph in a pane capped at a
//      width of its own, narrower than the column.
//
// Passes 2 and 3 need a window server; run.sh bounds them.

import SwiftUI
import AppKit

var failures = 0
func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    print("  \(ok ? "ok   " : "FAIL ")  \(what)\(detail.isEmpty ? "" : " — \(detail)")")
    if !ok { failures += 1 }
}
func note(_ what: String) { print("  note   \(what)") }

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let renderDir = ProcessInfo.processInfo.environment["SETTINGS_NAV_RENDER"]

func source(_ relative: String) -> String {
    (try? String(contentsOfFile: root + "/" + relative, encoding: .utf8)) ?? ""
}

/// Comments stripped, so a check about code cannot be satisfied by a
/// sentence explaining it.
func codeOnly(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let slashes = line.range(of: "//") else { return line }
        return line[line.startIndex..<slashes.lowerBound]
    }.joined(separator: "\n")
}

/// The body of the declaration that starts at `signature`, by brace depth.
func body(of signature: String, in text: String) -> String {
    guard let start = text.range(of: signature) else { return "" }
    var depth = 0
    var opened = false
    var end = text.endIndex
    var i = start.lowerBound
    while i < text.endIndex {
        let c = text[i]
        if c == "{" { depth += 1; opened = true }
        if c == "}" { depth -= 1 }
        if opened && depth == 0 { end = text.index(after: i); break }
        i = text.index(after: i)
    }
    return String(text[start.lowerBound..<end])
}

let tiers = FontTier.allCases
let defaultRatio = SipFont.ratio(FontTier.standard.scale)
/// The sidebar's range and default, and the window's floor and default —
/// ContentView and SipAIApp's numbers. The pane beside the sidebar is the
/// window less the sidebar less the 1 pt divider.
let sidebarNarrowest: CGFloat = 190
let sidebarDefault: CGFloat = 260
let windowNarrowest: CGFloat = 640
let windowDefault: CGFloat = 720
func paneWidth(window: CGFloat, sidebar: CGFloat) -> CGFloat { window - sidebar - 1 }

// MARK: - 1. The column rule

print("1. The column rule (SettingsPageLayout)")

var whole = true, bounded = true, scrollIffNoFit = true, monotonic = true
var widestWithRoom = true, scrollsAtNarrowestOnly = true, centredRemainder = true
var splitWhole = true
var firstFailure = ""
for tier in tiers {
    let ratio = SipFont.ratio(tier.scale)
    let widest = (SettingsPageLayout.widest * ratio).rounded()
    let narrowest = (SettingsPageLayout.narrowest * ratio).rounded()
    var previous: CGFloat = 0
    for v in 0...2000 {
        let viewport = CGFloat(v)
        let l = SettingsPageLayout(viewport: viewport, ratio: ratio)
        func fail(_ flag: inout Bool, _ why: String) {
            flag = false
            if firstFailure.isEmpty { firstFailure = "\(tier.rawValue) @ \(v): \(why) (\(l))" }
        }
        if l.columnWidth != l.columnWidth.rounded() || l.gutter != l.gutter.rounded()
            || l.leading != l.leading.rounded() || l.trailing != l.trailing.rounded() {
            fail(&whole, "fractional")
        }
        if l.scrollsHorizontally {
            if l.leading != SettingsPageLayout.tight || l.trailing != SettingsPageLayout.tight {
                fail(&splitWhole, "a scrolling page pads more than its tight gutters")
            }
        } else if l.leading + l.columnWidth + l.trailing != viewport
                    || l.trailing - l.leading < 0 || l.trailing - l.leading > 1
                    || l.leading < l.gutter {
            fail(&splitWhole, "the padding does not split the pane into whole, centred halves")
        }
        if l.columnWidth < narrowest || l.columnWidth > widest
            || l.gutter < SettingsPageLayout.tight || l.gutter > SettingsPageLayout.roomy {
            fail(&bounded, "out of bounds")
        }
        let fits = l.columnWidth + 2 * l.gutter <= viewport
        if fits == l.scrollsHorizontally { fail(&scrollIffNoFit, "scroll flag disagrees with the fit") }
        if l.scrollsHorizontally != (viewport < narrowest + 2 * SettingsPageLayout.tight) {
            fail(&scrollsAtNarrowestOnly, "scrolls before the gutters have given way")
        }
        if l.scrollsHorizontally && (l.columnWidth != narrowest || l.gutter != SettingsPageLayout.tight) {
            fail(&scrollsAtNarrowestOnly, "a scrolling page is not at its narrowest")
        }
        if l.columnWidth < previous { fail(&monotonic, "narrower on a wider pane") }
        previous = l.columnWidth
        if viewport >= widest + 2 * SettingsPageLayout.roomy && l.columnWidth != widest {
            fail(&widestWithRoom, "not at its widest with room to spare")
        }
        // Whatever the pane has beyond the column and two roomy gutters
        // is centring: the gutter itself never grows past `roomy`.
        if !l.scrollsHorizontally && viewport - l.columnWidth > 2 * SettingsPageLayout.roomy
            && l.gutter != SettingsPageLayout.roomy {
            fail(&centredRemainder, "gutter below roomy with room to spare")
        }
    }
}
check(whole, "every column, gutter and padding is a whole number of points", firstFailure)
check(splitWhole, "the padding centres the column in whole points, the odd point to the right")
check(bounded, "the column stays within its narrowest…widest, the gutter within tight…roomy (per tier)")
check(scrollIffNoFit, "the page scrolls sideways exactly when the column and its gutters do not fit")
check(scrollsAtNarrowestOnly, "…and only once the column is at its narrowest and the gutters at tight")
check(monotonic, "a wider pane never gets a narrower column")
check(widestWithRoom, "with room for it, the column is at its widest and the rest is centring")
check(centredRemainder, "the gutter is roomy whenever the pane has room for it")
check(SettingsPageLayout(viewport: .nan, ratio: .nan) == SettingsPageLayout(viewport: 0, ratio: 1)
      && SettingsPageLayout(viewport: -40, ratio: 0) == SettingsPageLayout(viewport: 0, ratio: 1),
      "a nonsense width or ratio reads as an empty pane at Default, never a crash or NaN")

// The window sizes the app opens with.
let atDefault = SettingsPageLayout(viewport: paneWidth(window: windowDefault, sidebar: sidebarDefault),
                                   ratio: defaultRatio)
check(!atDefault.scrollsHorizontally,
      "the default window (720) with the default sidebar (260) needs no sideways scroll at Default",
      "\(atDefault)")
let atFloor = SettingsPageLayout(viewport: paneWidth(window: windowNarrowest, sidebar: sidebarNarrowest),
                                 ratio: defaultRatio)
check(!atFloor.scrollsHorizontally,
      "the narrowest window (640) with the narrowest sidebar (190) needs none either",
      "\(atFloor)")
check(SettingsPageLayout(viewport: 1200, ratio: defaultRatio).columnWidth == SettingsPageLayout.widest,
      "a wide pane holds a \(Int(SettingsPageLayout.widest)) pt column at Default")
for tier in tiers {
    let ratio = SipFont.ratio(tier.scale)
    let start = (SettingsPageLayout.narrowest * ratio).rounded() + 2 * SettingsPageLayout.tight
    let full = (SettingsPageLayout.widest * ratio).rounded() + 2 * SettingsPageLayout.roomy
    note("\(tier.rawValue): scrolls sideways below a \(Int(start)) pt pane; full width from \(Int(full)) pt")
}

// MARK: - 2. The page, laid out for real

print("2. The page, laid out (the real body, offscreen)")

/// Frames the stand-in pane reports, in the page's own space.
@MainActor enum Measure {
    static var column: CGRect = .zero
    static var fixedRow: CGRect = .zero
    static var paragraph: CGRect = .zero
    static var last: CGRect = .zero
}

/// Stands in for a section: a flexible bar that spans the column, a
/// fixed-width row and a paragraph — the shape every real pane mixes —
/// then a last line. Help stands in for a section taller than the
/// window, so the page has an end to scroll to. Chat Settings is its
/// REAL system prompt and roles (extracted by run.sh) — the part of the
/// section that holds the text boxes — for pass 2b.
struct HarnessPane: View {
    let section: SettingsView.Tab
    var body: some View {
        if section == .chat {
            PromptAndRolesPane()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Color.blue.frame(height: 6)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("page")) } action: { Measure.column = $0 }
                Color.red.frame(width: 120, height: 14)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("page")) } action: { Measure.fixedRow = $0 }
                Text(verbatim: "A paragraph of the kind every pane has, wrapping at the column's edge rather than the window's, so a wide window reads as a page and not as a banner. It runs long enough to wrap even in the widest column the rule allows, at every tier.")
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("page")) } action: { Measure.paragraph = $0 }
                if section == .help {
                    Color.gray.opacity(0.2).frame(height: 1400)
                }
                Color.green.frame(height: 2)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("page")) } action: { Measure.last = $0 }
            }
        }
    }
}

/// A window no screen shows: borderless, far off every display, never key.
@MainActor
func host<V: View>(_ view: V, size: CGSize) -> (NSWindow, NSView) {
    let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: size)
    window.contentView = hosting
    window.orderFrontRegardless()
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    hosting.layoutSubtreeIfNeeded()
    return (window, hosting)
}

func scrollViews(in view: NSView) -> [NSScrollView] {
    var found: [NSScrollView] = []
    if let s = view as? NSScrollView { found.append(s) }
    for sub in view.subviews { found += scrollViews(in: sub) }
    return found
}

/// How far below the host's top edge a view's frame starts, whichever
/// way the host's coordinates run.
@MainActor
func distanceFromTop(_ view: NSView, in host: NSView) -> CGFloat {
    let rect = view.convert(view.bounds, to: host)
    return host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
}

/// The text boxes a view holds (a TextEditor is an NSTextView in a
/// scroll view of its own), top to bottom, by their scroll views' heights.
@MainActor
func textBoxHeights(in host: NSView) -> [CGFloat] {
    func textViews(in view: NSView) -> [NSTextView] {
        var found: [NSTextView] = []
        if let t = view as? NSTextView { found.append(t) }
        for sub in view.subviews { found += textViews(in: sub) }
        return found
    }
    return textViews(in: host)
        .compactMap { tv -> NSScrollView? in
            guard let scroll = tv.enclosingScrollView, scroll.documentView === tv else { return nil }
            return scroll
        }
        .sorted { distanceFromTop($0, in: host) < distanceFromTop($1, in: host) }
        .map { $0.frame.height }
}

@MainActor
func png(_ view: NSView, _ name: String) {
    guard let dir = renderDir,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
    }
}

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)

    /// Where a transcript's first row sits below the top bar, at its top.
    let topGap = SipDesign.pageTopBand + SipDesign.pageContentInset
    var measured = 0
    for tier in [FontTier.standard, .xlarge] {
        for width in [371, 459, 520, 760, 1180] as [CGFloat] {
            Measure.column = .zero
            Measure.fixedRow = .zero
            Measure.paragraph = .zero
            let page = SettingsView(section: .display)
                .coordinateSpace(.named("page"))
                .environment(\.sipFontScale, tier.scale)
                .environment(\.colorScheme, .light)
            let (window, hosting) = host(page, size: CGSize(width: width, height: 420))
            defer { window.orderOut(nil); window.close() }
            let rule = SettingsPageLayout(viewport: width, ratio: SipFont.ratio(tier.scale))
            let column = Measure.column, row = Measure.fixedRow
            let label = "\(tier.rawValue) @ \(Int(width)) pt"
            guard column != .zero, row != .zero else {
                check(false, "\(label): the page laid its pane out", "no geometry reported")
                continue
            }
            measured += 1
            check(abs(column.width - rule.columnWidth) < 0.5,
                  "\(label): the column is the rule's width", "\(column.width) vs \(rule.columnWidth)")
            check(abs(row.minX - column.minX) < 0.5,
                  "\(label): a fixed-width row starts at the column's left edge", "\(row.minX) vs \(column.minX)")
            check(abs(column.minY - topGap) < 0.5,
                  "\(label): the first line sits \(Int(topGap)) pt below the top bar, where a transcript's first row does",
                  "\(column.minY)")
            if let scroller = scrollViews(in: hosting).first {
                let band = distanceFromTop(scroller, in: hosting)
                check(abs(band - SipDesign.pageTopBand) < 0.5,
                      "\(label): …scrolled content leaves at the band's edge, \(Int(SipDesign.pageTopBand)) pt below the bar",
                      "the scroll view starts \(band) pt down")
            } else {
                check(false, "\(label): the page is a scroll view")
            }
            let paragraph = Measure.paragraph
            check(abs(paragraph.minX - column.minX) < 0.5
                  && paragraph.maxX <= column.maxX + 0.5 && paragraph.maxX > column.maxX - 60,
                  "\(label): a paragraph wraps at the column's edge",
                  "paragraph \(paragraph.minX)…\(paragraph.maxX), column \(column.minX)…\(column.maxX)")
            let docWidths = scrollViews(in: hosting).compactMap { $0.documentView?.frame.width }
            let clipWidths = scrollViews(in: hosting).map { $0.contentView.bounds.width }
            if rule.scrollsHorizontally {
                check(column.minX == rule.leading && rule.leading == rule.gutter,
                      "\(label): too narrow — the column keeps its narrowest width behind a tight gutter",
                      "minX \(column.minX)")
                let scrolls = zip(docWidths, clipWidths).contains { $0 > $1 + 0.5 }
                check(scrolls, "\(label): …and the page scrolls sideways to reach the rest",
                      "document \(docWidths) in clip \(clipWidths)")
            } else {
                let left = column.minX, right = width - column.maxX
                check(abs(left - right) <= 1 && left == rule.leading && right == rule.trailing
                      && left == left.rounded(),
                      "\(label): the column is centred, its left edge on a whole point",
                      "left \(left), right \(right)")
                let scrolls = zip(docWidths, clipWidths).contains { $0 > $1 + 0.5 }
                check(!scrolls, "\(label): …and nothing scrolls sideways",
                      "document \(docWidths) in clip \(clipWidths)")
            }
            if tier == .standard && (width == 459 || width == 1180) {
                png(hosting, "page-\(tier.rawValue)-\(Int(width))")
            }
        }
    }
    if measured == 0 { note("no window server answered: pass 2 measured nothing") }

    // A section taller than the window: scrolled to its end, the last
    // line stops as far above the window's bottom edge as the first line
    // starts below the bar. The scroll view runs from the band to the
    // bottom edge, so at the end the document's last point is on that
    // edge, and the gap is what the document holds below the last line.
    for tier in [FontTier.standard, .xlarge] {
        Measure.last = .zero
        let (window, hosting) = host(SettingsView(section: .help)
                                        .coordinateSpace(.named("page"))
                                        .environment(\.sipFontScale, tier.scale)
                                        .environment(\.colorScheme, .light),
                                     size: CGSize(width: 760, height: 420))
        defer { window.orderOut(nil); window.close() }
        let label = "\(tier.rawValue), a section taller than the window"
        guard let scroller = scrollViews(in: hosting).first,
              let document = scroller.documentView, Measure.last != .zero else {
            check(false, "\(label): the page laid out and scrolls", "no geometry reported")
            continue
        }
        let band = distanceFromTop(scroller, in: hosting)
        let lastInDocument = Measure.last.maxY - band
        let bottomGap = document.frame.height - lastInDocument
        check(document.frame.height > scroller.contentView.bounds.height,
              "\(label): …scrolls", "document \(document.frame.height) in \(scroller.contentView.bounds.height)")
        check(abs(bottomGap - topGap) < 0.5,
              "\(label): …and at its end the last line sits \(Int(topGap)) pt above the bottom edge, the first line's gap",
              "\(bottomGap)")
    }

    // MARK: - 2b. The chat prompt pane's boxes

    print("2b. The chat prompt pane's boxes (the real pane, in the real page)")

    // Fixed heights stated at Default and scaled with the tier: the same
    // in a short window as in a tall one. A box that only has a MINIMUM
    // takes a share of the height the page has left over, and in a tall
    // window stands hundreds of points tall around an empty prompt.
    for tier in [FontTier.standard, .xlarge] {
        let ratio = SipFont.ratio(tier.scale)
        let expected = [(176 * ratio).rounded(), (80 * ratio).rounded()]
        var seen: [[CGFloat]] = []
        for size in [CGSize(width: 459, height: 420), CGSize(width: 1400, height: 1280)] {
            let (window, hosting) = host(SettingsView(section: .chat)
                                            .environmentObject(ConfigManager())
                                            .environment(\.sipFontScale, tier.scale)
                                            .environment(\.colorScheme, .light),
                                         size: size)
            let boxes = textBoxHeights(in: hosting)
            seen.append(boxes)
            check(boxes == expected,
                  "\(tier.rawValue) @ \(Int(size.width)) × \(Int(size.height)): the system prompt's box is \(Int(expected[0])) pt and a role's \(Int(expected[1])) pt",
                  "\(boxes)")
            if tier == .standard && size.height > 1000 { png(hosting, "prompt-\(tier.rawValue)-\(Int(size.width))") }
            window.orderOut(nil)
            window.close()
        }
        check(seen.count == 2 && seen[0] == seen[1],
              "\(tier.rawValue): …the same in a short window as in a tall one", "\(seen)")
    }

    // MARK: - 3. The menu and the sidebar list

    print("3. The menu over the Settings row, and the sidebar's section list")

    // Every name on one line. A row of the sidebar's list is the sidebar
    // less the list's 8 pt insets and the row's 6 pt padding either side;
    // a row of the menu, the sidebar less the menu's 8 pt insets, its
    // 6 pt padding and the row's 6 pt padding either side.
    func listRoom(_ sidebar: CGFloat) -> CGFloat { sidebar - 16 - 12 }
    func menuRoom(_ sidebar: CGFloat) -> CGFloat { sidebar - 16 - 12 - 12 }
    for tier in tiers {
        var widestLabel: (SettingsView.Tab, CGFloat) = (.chat, 0)
        var cutInNarrowest: [SettingsView.Tab] = []
        for tab in SettingsView.Tab.allCases {
            let fitting = NSHostingView(rootView: SettingsSectionLabel(tab: tab)
                .fixedSize()
                .environment(\.sipFontScale, tier.scale)).fittingSize.width
            if fitting > widestLabel.1 { widestLabel = (tab, fitting) }
            if fitting > listRoom(sidebarNarrowest) { cutInNarrowest.append(tab) }
        }
        let widest = "widest \(widestLabel.0.rawValue) at \(Int(widestLabel.1.rounded())) pt"
        check(widestLabel.1 <= menuRoom(sidebarDefault),
              "\(tier.rawValue): every section name fits the default \(Int(sidebarDefault)) pt sidebar on one line, in the list and in the menu",
              "\(widest) of \(Int(menuRoom(sidebarDefault)))")
        let cut = cutInNarrowest.map(\.rawValue).joined(separator: ", ")
        switch tier {
        case .small:
            check(cutInNarrowest.isEmpty,
                  "small: …and in the narrowest \(Int(sidebarNarrowest)) pt sidebar's list", "cut: \(cut)")
        case .standard:
            check(cutInNarrowest.isEmpty,
                  "default: …and in the narrowest \(Int(sidebarNarrowest)) pt sidebar's list",
                  "cut: \(cut.isEmpty ? "none" : cut) (\(widest) of \(Int(listRoom(sidebarNarrowest))))")
        default:
            // The larger tiers widen the sidebar's rows too; a name cut at
            // the tail in the narrowest sidebar is the same trade every
            // other sidebar row makes there. Stated, not failed.
            note("\(tier.rawValue): in the narrowest \(Int(sidebarNarrowest)) pt sidebar's list, cut at the tail: \(cut.isEmpty ? "none" : cut) (\(widest) of \(Int(listRoom(sidebarNarrowest))))")
        }
    }

    // The menu rises from the Settings row and must fit the shortest
    // window above it: 480 tall, less the title bar (28), the divider
    // under it (1), the Settings row itself and the 6 pt gap.
    for tier in tiers {
        let menu = NSHostingView(rootView: SettingsLauncherMenu(isPresented: .constant(true))
            .environmentObject(AppState())
            .frame(width: sidebarDefault - 16)
            .environment(\.sipFontScale, tier.scale)).fittingSize
        let settingsRow = 20 + SipFont.lineHeight(SipFont.sidebarRow(tier.scale)).rounded(.up)
        let room = 480 - 28 - 1 - settingsRow - 6
        check(menu.height <= room,
              "\(tier.rawValue): the menu (\(Int(menu.height.rounded())) pt tall) fits above the Settings row in the shortest window (\(Int(room)) pt)")
    }

    UpdateBadge.shared.isOwed = true
    for tier in [FontTier.standard, .xlarge] {
        let appState = AppState()
        let (menuWindow, menuHost) = host(
            SettingsLauncherMenu(isPresented: .constant(true))
                .environmentObject(appState)
                .frame(width: sidebarDefault - 16)
                .padding(24)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.sipFontScale, tier.scale)
                .environment(\.colorScheme, .light),
            size: CGSize(width: sidebarDefault + 32, height: 520))
        png(menuHost, "menu-\(tier.rawValue)")
        menuWindow.orderOut(nil)
        menuWindow.close()

        appState.settingsSection = .display
        let (listWindow, listHost) = host(
            SettingsSidebarList()
                .environmentObject(appState)
                .environmentObject(ConfigManager())
                .environmentObject(ProjectManager())
                .environmentObject(ChatManager())
                .environmentObject(NotesManager())
                .environmentObject(AgentManager())
                .environmentObject(ScheduledTaskScheduler())
                .frame(width: sidebarDefault)
                .background(SipDesign.surface)
                .environment(\.sipFontScale, tier.scale)
                .environment(\.colorScheme, .light),
            size: CGSize(width: sidebarDefault, height: 520))
        png(listHost, "sidebar-list-\(tier.rawValue)")
        listWindow.orderOut(nil)
        listWindow.close()
    }
    UpdateBadge.shared.isOwed = false

    // `openSettings` — extracted from AppState — puts the sidebar back.
    let state = AppState()
    state.leftSidebarVisible = false
    state.openSettings(.help)
    check(state.settingsSection == .help && state.leftSidebarVisible,
          "opening Settings shows the section and brings the sidebar back")

    // MARK: - 3b. The menu's placement

    print("3b. The menu's placement (ContentView's real overlay, offscreen)")

    // The menu's fill is `SipDesign.surface` — pure white in light mode
    // — over a red probe background; nothing else in the render is white,
    // so the white pixels' box is the menu's fill, inside its 1 pt border.
    for tier in [FontTier.standard, .xlarge] {
        for sidebar in [sidebarNarrowest, sidebarDefault, 440] as [CGFloat] {
            MenuMeasure.row = .zero
            let (window, hosting) = host(
                MenuOverlayProbe(sidebarWidth: sidebar)
                    .environmentObject(AppState())
                    .background(Color(red: 1, green: 0, blue: 0))
                    .environment(\.sipFontScale, tier.scale)
                    .environment(\.colorScheme, .light),
                size: CGSize(width: 720, height: 540))
            defer { window.orderOut(nil); window.close() }
            let label = "\(tier.rawValue), sidebar \(Int(sidebar))"
            let row = MenuMeasure.row
            guard row != .zero, let box = whiteBox(in: hosting) else {
                check(false, "\(label): the overlay drew the menu over the row", "row \(row)")
                continue
            }
            check(abs(box.minX - (row.minX + 8 + 1)) <= 1.5,
                  "\(label): the menu starts 8 pt in from the row's left edge", "fill minX \(box.minX), row minX \(row.minX)")
            check(abs(box.width - (row.width - 16 - 2)) <= 2,
                  "\(label): …and is the row's width less 8 pt a side", "fill width \(box.width), row width \(row.width)")
            check(abs(box.maxY - (row.minY - 6 - 1)) <= 1.5,
                  "\(label): …its bottom 6 pt above the row", "fill maxY \(box.maxY), row minY \(row.minY)")
            check(box.minY > 0 && box.height > 100,
                  "\(label): …and it stands whole inside the window", "fill \(box)")
            if tier == .standard && sidebar == sidebarDefault { png(hosting, "overlay-\(tier.rawValue)-\(Int(sidebar))") }
        }
    }
}

/// The bounding box, in points, of every pure-white pixel of the view's
/// rendering — nil when there are none.
@MainActor
func whiteBox(in view: NSView) -> CGRect? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if c.redComponent >= 0.99 && c.greenComponent >= 0.99 && c.blueComponent >= 0.99 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    guard maxX >= 0 else { return nil }
    return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                  width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
}

// MARK: - 4. The wiring

print("4. The wiring, read off the sources")

let contentSource = source("SipAI/Views/ContentView.swift")
let content = codeOnly(contentSource)
let sidebar = codeOnly(source("SipAI/Views/Sidebar/LeftSidebar.swift"))
let navigation = codeOnly(source("SipAI/Views/Settings/SettingsNavigation.swift"))
let settings = codeOnly(source("SipAI/Views/Settings/SettingsView.swift"))
let appStateSource = codeOnly(source("SipAI/Models/AppState.swift"))
let palette = codeOnly(source("SipAI/Views/GlobalSearchPalette.swift"))
let app = codeOnly(source("SipAI/SipAIApp.swift"))
let guidePane = codeOnly(source("SipAI/Views/Settings/AgentGuidePane.swift"))
let layoutSource = source("SipAI/Utilities/SettingsPageLayout.swift")
check(!content.isEmpty && !sidebar.isEmpty && !navigation.isEmpty && !settings.isEmpty
      && !appStateSource.isEmpty && !layoutSource.isEmpty,
      "the sources are where they are expected")

// Settings replaces the centre pane — the router's FIRST branch — and is
// no sheet at all.
let router = body(of: "private var centerPane: some View {", in: content)
if let settingsBranch = router.range(of: "if let section = appState.settingsSection {"),
   let noteBranch = router.range(of: "appState.openNoteId != nil") {
    check(settingsBranch.lowerBound < noteBranch.lowerBound
          && router.contains("SettingsView(section: section, initialHelpTopic: settingsHelpTopic)"),
          "the router shows Settings first, in place of the chat, session or note")
} else {
    check(false, "the router shows Settings first, in place of the chat, session or note")
}
check(!content.contains("SettingsView(initialTab:")
      && content.range(of: #"showingSettings\b"#, options: .regularExpression) == nil
      && content.components(separatedBy: "SettingsView(").count == 2,
      "Settings is no sheet, and the router is the one place that makes the page")
check(!settings.contains("@Environment(\\.dismiss)") && !settings.contains("dismiss()"),
      "the page has nothing to dismiss")

// A layer over the routes: nothing in them clears it; the two ways in
// from outside close it themselves; the reset closes it on success only.
let startNewChat = body(of: "func startNewChat() {", in: appStateSource)
check(!startNewChat.isEmpty && !startNewChat.contains("settingsSection"),
      "startNewChat leaves Settings alone (the reset runs it on its partial-failure path too)")
for field in ["openChatSlug", "openAgentSessionId", "pendingClaudeSessionDraft", "openNoteId"] {
    let declaration = body(of: "@Published var \(field):", in: appStateSource)
    check(!declaration.isEmpty && !declaration.contains("settingsSection"),
          "\(field)'s didSet leaves Settings alone")
}
check(body(of: "func openSettings(_ section: SettingsView.Tab) {", in: appStateSource)
        .contains("leftSidebarVisible = true"),
      "openSettings brings the sidebar back — the sections and the way out live there")
check(body(of: "private func open(_ result: GlobalSearchResult) {", in: palette)
        .contains("appState.settingsSection = nil"),
      "a search result closes Settings")
check(body(of: "notificationCoordinator.onApprovalClicked = {", in: app)
        .contains("appState.settingsSection = nil"),
      "a notification click closes Settings")
check(body(of: "mcpBridge.isApprovalFocused = {", in: app)
        .contains("guard appState.settingsSection == nil else { return false }"),
      "no session counts as on screen while Settings covers the pane (its approvals notify)")
let resetReceiver = body(of: "publisher(for: .sipFactoryReset)) { _ in", in: content)
check(resetReceiver.contains("showOnboarding = true") && resetReceiver.contains("appState.settingsSection = nil"),
      "a successful factory reset closes Settings with the main layout")
check(body(of: "publisher(for: .openHelpTopic)) { note in", in: content)
        .contains("settingsHelpTopic = topic\n            appState.openSettings(.help)")
      && body(of: "publisher(for: .openSettingsTab)) { note in", in: content)
        .contains("appState.openSettings(tab)"),
      "both deep links open Settings through openSettings")
check(body(of: ".onChange(of: appState.settingsSection) { _, section in", in: content)
        .contains("if section != .help { settingsHelpTopic = nil }"),
      "a deep-linked Help question belongs to that one visit")

// The sidebar: the ordinary list stays mounted under the settings list,
// hidden without `.disabled`; the bottom row swaps; the row anchors the
// menu.
let bandTwo = body(of: "ZStack(alignment: .topLeading) {", in: sidebar)
check(bandTwo.contains("sectionsColumn\n                    .opacity(inSettings ? 0 : 1)")
      && bandTwo.contains(".allowsHitTesting(!inSettings)")
      && bandTwo.contains(".accessibilityHidden(inSettings)")
      && bandTwo.contains("if inSettings {\n                    SettingsSidebarList()"),
      "while Settings is open the ordinary list stays mounted, hidden, under the settings list")
check(!sidebar.contains(".disabled(inSettings)") && !sidebar.contains(".disabled(appState.settingsSection"),
      "…and is never disabled (its alerts must stay answerable)")
check(sidebar.contains("if inSettings {\n                backToAppButton\n            } else {\n                settingsButton\n            }"),
      "the bottom row is the way back while Settings is open")
let settingsButton = body(of: "private var settingsButton: some View {", in: sidebar)
check(settingsButton.contains("showingSettingsMenu.toggle()")
      && settingsButton.contains(".anchorPreference(key: SettingsMenuAnchorKey.self, value: .bounds) { $0 }"),
      "the Settings row opens the menu and anchors it")
check(body(of: "private var backToAppButton: some View {", in: sidebar)
        .contains("appState.settingsSection = nil"),
      "Back to app closes Settings and nothing else")

// The menu: an overlay over a scrim, as wide as the sidebar, rising from
// the row; one dropdown at a time.
let menuOverlay = body(of: ".overlayPreferenceValue(SettingsMenuAnchorKey.self) { anchor in", in: content)
check(menuOverlay.contains("SettingsLauncherMenu(isPresented: $showingSettingsMenu)")
      && menuOverlay.contains(".onTapGesture { showingSettingsMenu = false }")
      && menuOverlay.contains(".frame(width: max(0, row.width - 16))")
      && menuOverlay.contains(".padding(.leading, row.minX + 8)")
      && menuOverlay.contains(".padding(.bottom, max(0, geo.size.height - row.minY + 6))"),
      "the menu rises from the Settings row, the sidebar's width less its insets, over a scrim")
let exclusivity = body(of: "private struct SettingsMenuExclusivity: ViewModifier {", in: content)
check(exclusivity.contains("search = false") && exclusivity.contains("usage = false")
      && exclusivity.contains("sessionView = false")
      && exclusivity.components(separatedBy: "menu = false").count == 5
      && content.contains(".modifier(SettingsMenuExclusivity("),
      "one dropdown at a time: the menu, the search palette, the plan-usage window and the agent session view window")
let menuView = body(of: "struct SettingsLauncherMenu: View {", in: navigation)
check(menuView.contains(".onKeyPress(.escape)") && menuView.contains(".onKeyPress(.downArrow)")
      && menuView.contains(".onKeyPress(.upArrow)") && menuView.contains(".onKeyPress(.return)")
      && menuView.contains("appState.openSettings(tab)"),
      "the menu answers Escape, the arrows and Return, and opens through openSettings")
// An approval card behind the scrim owns Return as the window's default
// action; a Return the menu let go of would allow its tool call.
let returnHandler = body(of: ".onKeyPress(.return) {", in: menuView)
check(!returnHandler.isEmpty && !returnHandler.contains(".ignored")
      && !menuView.contains("return .ignored"),
      "the menu keeps every Return, lit row or not")

// The factory reset: its alerts on the settings list, the failure one
// deferred a run-loop turn; none of it left on the page.
let list = body(of: "struct SettingsSidebarList: View {", in: navigation)
check(list.contains("\"Factory reset?\"") && list.contains("\"Reset was incomplete\"")
      && list.contains("DispatchQueue.main.async { resetFailures = failed }")
      && list.contains("FactoryReset.perform("),
      "the factory reset and both its alerts live on the settings list")
check(!settings.contains("Factory reset") && !settings.contains("FactoryReset.perform("),
      "…and not on the page")

// Every section opens its own pane.
let pane = body(of: "private func pane(_ proxy: ScrollViewProxy) -> some View {", in: settings)
let panes = ["case .chat:      ChatSettingsPane(", "case .agents:    AgentGuidePane()",
             "case .skills:    SkillsPane()", "case .files:     FilesPane()",
             "case .display:   DisplayPane()", "case .labels:    LabelsPane()",
             "case .language:  LanguagePane()", "case .usage:     UsagePane()",
             "case .updates:   UpdatesPane()",
             "case .privacy:   PrivacyPane()",
             "HelpPane(initialTopic: initialHelpTopic)"]
check(panes.allSatisfy { pane.contains($0) } && SettingsView.Tab.allCases.count == 11,
      "each of the eleven sections opens its own pane")
check(settings.contains("ChatSettingsPane(switchTab: { appState.settingsSection = $0 })"),
      "the Agent Initialization link in About chats moves Settings to that section")

// Chat Settings is one page in the order a chat needs it: what a chat
// is, the models, then the system prompt and the roles.
let chatPane = codeOnly(body(of: "struct ChatSettingsPane: View {", in: settings))
let modelsPart = codeOnly(body(of: "struct ModelsPane: View {", in: settings))
let promptPart = codeOnly(body(of: "struct PromptAndRolesPane: View {", in: settings))
func inOrder(_ text: String, _ marks: [String]) -> Bool {
    var from = text.startIndex
    for mark in marks {
        guard let r = text.range(of: mark, range: from..<text.endIndex) else { return false }
        from = r.upperBound
    }
    return true
}
check(inOrder(chatPane, ["ModelsPane(switchTab: switchTab)", "Divider()", "PromptAndRolesPane()"]),
      "Chat Settings draws the models' part, then the system prompt and roles")
check(inOrder(modelsPart, ["aboutChats", "Text(\"Chat models\""]),
      "…opening on About chats, then the Chat models list")
check(inOrder(promptPart, ["Text(\"System Prompt\"", "Text(\"Roles\""]),
      "…then System Prompt, then Roles")
check(settings.contains(".id(section)"), "each section opens at its top")
/// Whitespace removed, so a check about a modifier chain does not hang on
/// its indentation.
func squashed(_ text: String) -> String { text.filter { !$0.isWhitespace } }
check(settings.contains("SettingsPageLayout(viewport: geo.size.width,")
      && settings.contains(".frame(width: layout.columnWidth, alignment: .leading)")
      && settings.contains(".padding(.leading, layout.leading)")
      && settings.contains(".padding(.trailing, layout.trailing)")
      && squashed(settings).contains(squashed(".frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)")),
      "the page lays its column out by the rule: fixed width, content left, centred, pinned to the top")
check(settings.contains("ScrollView(layout.scrollsHorizontally ? [.vertical, .horizontal] : .vertical)"),
      "…and scrolls sideways only when the rule says so")

// The page's gaps are the agent session's, spelled once: the band under
// the top bar and the transcript's inset above the first line — and the
// two together below the last line, so the page ends as it begins.
let sessionView = codeOnly(source("SipAI/Views/Chat/AgentSessionView.swift"))
check(settings.contains("Spacer().frame(height: SipDesign.pageTopBand)")
      && settings.contains(".padding(.top, SipDesign.pageContentInset)")
      && settings.contains(".padding(.bottom, SipDesign.pageTopBand + SipDesign.pageContentInset)"),
      "the page keeps the band under the top bar, the inset above its first line, and both below its last")
check(sessionView.contains("Spacer().frame(height: SipDesign.pageTopBand)")
      && sessionView.contains(".padding(.vertical, SipDesign.pageContentInset)"),
      "…the same two values the agent session's band and transcript inset are spelled with")

// The sections' order: Chat Settings first — its system prompt and
// roles reach chat turns alone — then the agents' two, Agent
// Initialization and Agent Skills; Usage between Language and Updates,
// Privacy between Updates and Help (the user's two choices).
// The menu and the sidebar list both draw `allCases`, so the enum's
// order is theirs.
let order = SettingsView.Tab.allCases.map(\.rawValue)
check(order == ["chat", "agents", "skills", "files", "display", "labels", "language", "usage", "updates", "privacy", "help"],
      "the sections run Chat Settings, Agent Initialization, Agent Skills, Files & Notes, Display, Labels, Language, Usage, Updates, Privacy, Help",
      order.joined(separator: ", "))
check(menuView.contains("private let sections = SettingsView.Tab.allCases")
      && list.contains("ForEach(SettingsView.Tab.allCases) { tab in"),
      "…and the menu and the sidebar list both take that order from the enum")
// The insets pass 3's one-line fit is worked out from.
check(squashed(menuView).contains(squashed("SettingsSectionLabel(tab: tab) .padding(.horizontal, 6) .padding(.vertical, 6)"))
      && menuView.contains(".padding(6)")
      && squashed(list).contains(squashed("SettingsSectionLabel(tab: tab, selected: selected) .padding(.horizontal, 6)"))
      && squashed(list).contains(squashed("factoryResetRow } .padding(.horizontal, 8)")),
      "the menu's and the list's row insets are the ones pass 3 measured the names against")
check(settings.contains("case .chat:      return \"Chat Settings\"")
      && settings.contains("case .agents:    return \"Agent Initialization\"")
      && settings.contains("case .skills:    return \"Agent Skills\"")
      && settings.contains("case .privacy:   return \"Privacy\"")
      && settings.contains("case .usage:     return \"Usage\""),
      "the sections are called Chat Settings, Agent Initialization, Agent Skills, Usage and Privacy")
check(navigation.contains("case .privacy:  return \"hand.raised\""),
      "Privacy's glyph is the raised hand")
check(navigation.contains("case .usage:    return \"t.circle\""),
      "Usage's glyph is the toolbar coin's T")

// The Privacy page: three paragraphs in Help's prose rhythm — the
// tier's line spacing once at its root, its gaps by line pitch.
let privacyPane = codeOnly(body(of: "struct PrivacyPane: View {", in: settings))
let privacyParagraphs = ["SipAI collects no data.",
                         "What you send to an AI model goes straight from your Mac to its provider",
                         "Apart from your AI providers, SipAI goes online only for updates."]
check(inOrder(privacyPane, ["Text(\"Privacy\""] + privacyParagraphs.map { "Text(\"" + $0 }),
      "the Privacy page: its header, then what SipAI collects, what reaches a provider, and the update checks")
check(privacyPane.contains(".lineSpacing(HelpRhythm.lineSpacing(fontScale, lineSpacingFactor))")
      && privacyPane.contains("HelpRhythm.vertical(fontScale, lineSpacingFactor)")
      && privacyPane.contains(".sipFont(HelpRhythm.bodySize)"),
      "…in Help's prose rhythm: the tier's line spacing, gaps by line pitch, Help's body size")
check(!privacyPane.contains("http") && !privacyPane.contains("](sipai://"),
      "…naming no provider's page: the reader looks up their own provider's policy")
check(source("SipAI/Views/Settings/AgentGuidePane.swift").contains("Text(\"Agent Initialization\", comment: \"Settings pane header\")")
      && source("SipAI/Views/Settings/SkillsPane.swift").contains("Text(\"Agent Skills\", comment: \"Settings pane header\")"),
      "…and their pages' headers say the same")

// Every place that names a section names it as it is now. The source
// is read whole — a translator comment saying where a string appears is
// as stale as the string when it names a section that is gone.
let oldNames = ["Settings → Chat models", "Settings → Chat Prompt and Roles", "Settings → Agent Guide",
                "Settings → Skills", "[Agent Guide](", "\"Chat Prompt and Roles\"", "\"Agent Guide\""]
let oldChinese = ["设置 → 对话模型", "对话提示词与角色", "智能体指南", "设置 → 技能"]
func swiftFiles(under rel: String) -> [String] {
    let path = root + "/" + rel
    return (FileManager.default.enumerator(atPath: path)?.allObjects as? [String] ?? [])
        .filter { $0.hasSuffix(".swift") }.map { rel + "/" + $0 }
}
let appSources = swiftFiles(under: "SipAI")
let stale = appSources.flatMap { file -> [String] in
    let text = codeOnly(source(file))
    return oldNames.filter { text.contains($0) }.map { "\(file.replacingOccurrences(of: "SipAI/", with: "")): \($0)" }
}
check(!appSources.isEmpty && stale.isEmpty,
      "no string in the app names a section by its old name", stale.joined(separator: "; "))

// …and nowhere a section's OLD path survives the line it wraps on: a
// README sentence or a source comment broken across lines — a comment
// marker between any two of its words — is what a single-line grep for
// "Settings → Agent Guide" walks past. "Chat Settings → Chat models"
// names the section's own part, not the old section.
let oldPath = try! NSRegularExpression(
    pattern: #"(?<!Chat\s)Settings(?:\s|//)*→(?:\s|//)*(?:Agent(?:\s|//)+Guide|Chat(?:\s|//)+models|Chat(?:\s|//)+Prompt(?:\s|//)+and(?:\s|//)+Roles|Skills\b)"#)
func oldPaths(in text: String, named name: String) -> [String] {
    oldPath.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
        let line = text[..<Range(match.range, in: text)!.lowerBound].filter { $0 == "\n" }.count + 1
        return "\(name):\(line)"
    }
}
let readme = (try? String(contentsOfFile: root + "/../README.md", encoding: .utf8)) ?? ""
let stalePaths = oldPaths(in: readme, named: "README.md") + appSources.flatMap { oldPaths(in: source($0), named: $0) }
check(!readme.isEmpty && stalePaths.isEmpty,
      "no README sentence or source comment names a section by its old path, however the line wraps",
      stalePaths.joined(separator: "; "))

// Every in-app link to a section names one that exists.
let linkPattern = try! NSRegularExpression(pattern: #"sipai://settings/([a-z]+)"#)
func linkedSections(_ text: String) -> [String] {
    linkPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
        Range($0.range(at: 1), in: text).map { String(text[$0]) }
    }
}

// The names and the Help answers that quote them, in both languages.
if let catalog = try? JSONSerialization.jsonObject(
        with: Data(source("SipAI/Resources/Localizable.xcstrings").utf8)) as? [String: Any],
   let strings = catalog["strings"] as? [String: Any] {
    func chinese(_ key: String) -> String {
        let entry = strings[key] as? [String: Any]
        let zh = (entry?["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any]
        return ((zh?["stringUnit"] as? [String: Any])?["value"] as? String) ?? ""
    }
    func comment(_ key: String) -> String { ((strings[key] as? [String: Any])?["comment"] as? String) ?? "" }
    check(chinese("Chat Settings") == "对话设置" && chinese("Agent Initialization") == "智能体初始化"
          && chinese("Agent Skills") == "智能体技能" && chinese("Privacy") == "隐私",
          "the catalog carries the four names with their Chinese",
          "\(chinese("Chat Settings")) · \(chinese("Agent Initialization")) · \(chinese("Agent Skills")) · \(chinese("Privacy"))")
    for prefix in privacyParagraphs {
        let key = strings.keys.first { $0.hasPrefix(prefix) }
        check(key.map { !chinese($0).isEmpty } == true,
              "the Privacy paragraph \"\(prefix.prefix(40))…\" is in the catalog with its Chinese")
    }
    // Said once, on the Privacy page (and on the welcome page, for a
    // first launch) — not again in Help, Chat Settings or Updates.
    let repeated = ["Does anything leave my Mac?", "SipAI is completely a local tool", "never sees a login token",
                    "nothing is stored or sent anywhere", "no server in between",
                    "no usage data, account or system profile is ever sent", "Nothing about you or your machine is sent"]
    let stillSaid = strings.keys.filter { key in repeated.contains { key.contains($0) } }
    check(stillSaid.isEmpty && !repeated.contains { settings.contains($0) },
          "the privacy claims are not repeated in Help, Chat Settings or Updates",
          stillSaid.map { String($0.prefix(50)) }.joined(separator: " | "))
    let whereStored = strings.keys.first { $0.hasPrefix("Chats, notes, roles, API keys and settings are in ~/Library/Application Support/SipAI.") }
    check(strings["Where is my data stored?"] != nil
          && whereStored.map { $0.contains("Settings → Privacy") && chinese($0).contains("设置 → 隐私") } == true,
          "Help keeps \"Where is my data stored?\" — the folders — and sends the rest to Settings → Privacy, in both languages")
    check(strings.keys.contains { $0.hasPrefix("No sign-up required, no data collection, no tracking from the app.") }
          && source("SipAI/Views/OnboardingView.swift").contains("No sign-up required, no data collection, no tracking from the app."),
          "the welcome page keeps its line for a first launch")
    check(strings["Chat Prompt and Roles"] == nil && strings["Agent Guide"] == nil
          && !comment("Skills").contains("Settings pane header") && !chinese("Skills").isEmpty,
          "…and not the old ones — Skills stays, for the skill chip and the task panel")
    let staleKeys = strings.keys.filter { key in oldNames.contains { key.contains($0) } }
    let staleChinese = strings.keys.filter { key in oldChinese.contains { chinese(key).contains($0) } }
    let staleComments = strings.keys.filter { key in oldNames.contains { comment(key).contains($0) } }
    check(staleKeys.isEmpty && staleChinese.isEmpty && staleComments.isEmpty,
          "no catalog key, Chinese value or translator comment names a section by its old name",
          (staleKeys + staleChinese + staleComments).map { String($0.prefix(50)) }.joined(separator: " | "))
    // The answers, whatever quotation marks surround a name in Chinese.
    let answers: [(prefix: String, english: String, chinese: String)] = [
        ("Each provider issues keys from its own dashboard.", "Settings → Chat Settings", "设置 → 对话设置"),
        ("Open Settings → Agent Initialization.", "Settings → Agent Initialization", "设置 → 智能体初始化"),
        ("The system prompt (Settings → Chat Settings)", "Settings → Chat Settings", "设置 → 对话设置"),
        ("Share With, in a skill's … menu in Settings → Agent Skills", "Settings → Agent Skills", "设置 → 智能体技能"),
    ]
    for answer in answers {
        let key = strings.keys.first { $0.hasPrefix(answer.prefix) }
        check(key.map { $0.contains(answer.english) && chinese($0).contains(answer.chinese) } == true
              && settings.contains(answer.english),
              "Help names \(answer.english) in both languages", String(answer.prefix.prefix(40)))
    }
    let links = Set(strings.keys.flatMap(linkedSections) + strings.keys.flatMap { linkedSections(chinese($0)) }
                    // Raw source: `codeOnly` would cut a line at the
                    // link's own "//".
                    + appSources.flatMap { linkedSections(source($0)) })
    let unknown = links.filter { SettingsView.Tab(rawValue: $0) == nil }
    check(links.contains("chat") && links.contains("agents") && unknown.isEmpty,
          "every sipai://settings/ link names a section that exists — the chat page's Learn more opens Chat Settings",
          "linked: \(links.sorted().joined(separator: ", ")); unknown: \(unknown.sorted().joined(separator: ", "))")
} else {
    check(false, "the String Catalog parses")
}

// The prompt boxes are fixed heights, never minimums — pass 2b measures
// what that means on screen.
let promptPane = body(of: "struct PromptAndRolesPane: View {", in: settings)
check(promptPane.contains("promptEditor($text, height: 176, monospaced: true)")
      && promptPane.contains("promptEditor($role.prompt, height: 80, monospaced: false)")
      && promptPane.contains(".frame(height: (height * SipFont.ratio(fontScale)).rounded())")
      && !promptPane.contains("minHeight"),
      "the prompt boxes are fixed heights scaled with the tier, not minimums that grow with the window")

// A paragraph capped at a width of its own is a second, narrower column
// inside the page's: its lines stop short of the rows and rules beside
// it. The literal caps left are on controls alone — the segmented
// pickers, the language list, the sign-in sheet's fields.
for file in ["SipAI/Views/Settings/SettingsView.swift", "SipAI/Views/Settings/AgentGuidePane.swift",
             "SipAI/Views/Settings/UsagePane.swift"] {
    let lines = codeOnly(source(file)).components(separatedBy: "\n")
    var capped: [Int] = []
    for (i, line) in lines.enumerated()
    where line.range(of: #"\.frame\(maxWidth:\s*[0-9]"#, options: .regularExpression) != nil {
        let chain = lines[max(0, i - 4)..<i].joined(separator: "\n")
        let control = chain.contains(".labelsHidden()") || chain.contains(".pickerStyle(")
            || chain.contains(".textFieldStyle(")
        if !control { capped.append(i + 1) }
    }
    check(!lines.isEmpty && capped.isEmpty,
          "\(file): no paragraph or box is capped narrower than the column",
          "capped at line \(capped.map(String.init).joined(separator: ", "))")
}

// The sheets the panes present hang off the main window now: each takes
// the app's look — the application's appearance, so no colour scheme of
// its own (`Verification/DisplayPane`) — and is reported to the
// notices beside the logo, which hold one back while a sheet covers it.
// Chat models' Add Model rides ContentView's one Add Model sheet, which
// already does both.
check(!guidePane.contains(".preferredColorScheme(")
      && guidePane.contains(".onChange(of: sheetUp) { _, up in SidebarNotices.shared.setSheetPresented(up) }")
      && guidePane.contains(".onDisappear { if sheetUp { SidebarNotices.shared.setSheetPresented(false) } }")
      && body(of: "private var sheetUp: Bool {", in: guidePane)
        .contains("showingSignIn || showingInstall || actions.browserStep?.agentKey == key"),
      "the Guide's three sheets take the app's theme and are reported to the notices beside the logo, torn down included")
check(!settings.contains(".sheet(") && !settings.contains("showingModelSetup")
      && settings.contains("NotificationCenter.default.post(name: .openModelSetup, object: nil)"),
      "Chat models' Add Model opens ContentView's one Add Model sheet — no sheet of the page's own")

// The rule stays pure, so pass 1 can run anywhere.
check(!layoutSource.contains("import SwiftUI") && !layoutSource.contains("import AppKit"),
      "SettingsPageLayout imports neither SwiftUI nor AppKit")

print(failures == 0 ? "SettingsNavigation: OK" : "SettingsNavigation: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
