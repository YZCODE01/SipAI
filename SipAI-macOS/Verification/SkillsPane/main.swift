// SkillsPane harness: renders the REAL Settings → Agent Skills pane, the chip's
// popover in both faces, a skill's detail and the new-skill sheet in an
// offscreen window, over a fixture snapshot — the shapes the manager has
// to draw (a skill two agents have, an agent's own, a common-folder
// skill, a clash, a broken link, plugins and built-ins, not in use, a
// pinned default, an off switch, a skill an agent does not load) — at
// two tiers in both appearances, and checks what can be measured:
// nothing drawn wider than the page's column; the line that stands in for
// an agent's missing skills, on the groups' text column, and only for
// what the page shows (Global's, or the folder's); a row's … button
// under a pointer and a click delivered to the window (its fill, its
// click area, and that nothing else in a row answers); the folder menu on
// a row of its own under the search, opened by a click, listing the
// folders browsed; a subfolder's skills in a group of their own, acted
// on in that subfolder; then reads the pane's source against the Display
// pane's for the type and the gaps.
//
//   ./run.sh                          # checks only
//   SKILLS_PANE_RENDER=<dir> ./run.sh # also write the PNGs

import AppKit
import SwiftUI

var passed = 0
var failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("  PASS \(name)") }
    else { failed += 1; let d = detail(); print("  FAIL \(name)" + (d.isEmpty ? "" : " — \(d)")) }
}

let renderDir = ProcessInfo.processInfo.environment["SKILLS_PANE_RENDER"]
let folder = URL(fileURLWithPath: "/Users/someone/Projects/Atlas", isDirectory: true)
// The folders browsed, kept where nothing else reads them: a file path
// suite, never the harness's own domain.
let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("skillspane-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

func entry(_ agent: String, _ name: String, _ description: String, scope: SkillScope = .global,
           kind: SkillRootKind = .own, link: Bool = false, real: String? = nil,
           label: String? = nil, fm: SkillFrontmatter = SkillFrontmatter()) -> SkillEntry {
    var f = fm
    f.name = name
    f.description = description
    return SkillEntry(agent: agent, name: name, description: description, scope: scope, rootKind: kind,
                      entryPath: "/x/\(agent)/\(name)", realPath: real ?? "/lib/\(name)", isLink: link,
                      frontmatter: f, sourceLabel: label)
}

func row(_ name: String, _ description: String, _ agents: [String], scope: SkillScope = .global,
         home: SkillHome = .library, states: [String: SkillState] = [:],
         problems: Set<SkillProblem> = [], real: String?? = nil, kind: SkillRootKind = .own,
         label: String? = nil, fm: SkillFrontmatter = SkillFrontmatter(), id: String? = nil,
         format: [SkillFormatProblem] = [], loadErrors: [String: String] = [:]) -> SkillRow {
    let realPath: String? = real ?? "/lib/\(name)"
    var entries: [String: SkillEntry] = [:]
    for a in agents {
        entries[a] = entry(a, name, description, scope: scope, kind: kind, link: home == .library,
                           real: realPath, label: label, fm: fm)
    }
    var f = fm
    f.name = name
    f.description = description
    var r = SkillRow(id: id ?? (realPath ?? "x:\(name)"), name: name, description: description, scope: scope,
                     home: home, realPath: realPath, entries: entries, frontmatter: f)
    for a in agents { r.states[a] = states[a] ?? .on }
    r.problems = problems
    r.formatProblems = format
    r.loadErrors = loadErrors
    return r
}

let C = SkillAgent.claude, X = SkillAgent.codex, K = SkillAgent.kimi
var granting = SkillFrontmatter()
granting.allowedTools = "Bash(git *), Read"
granting.disableModelInvocation = true
let rows: [SkillRow] = [
    row("review-pr", "Review a pull request against the repository's own rules, then list what blocks a merge.", [C, X]),
    row("release-notes", "Draft the release notes from the merged pull requests.",
        [X, K], scope: .folder, home: .common, kind: .common, id: "common-rs"),
    row("release-notes", "Claude Code's own copy, with its tool notes.", [C], scope: .folder,
        home: .agentFolder(C), id: "claude-rs"),
    row("commit-msg", "Write a commit message from the staged diff.", [C], home: .agentFolder(C),
        states: [C: .userInvocableOnly], fm: granting),
    row("lint-fix", "Fix what the linter reports, one file at a time.", [X], home: .agentFolder(X),
        states: [X: .off]),
    row("dupe", "The first of two skills with one name.", [X], home: .agentFolder(X),
        problems: [.clash], id: "dupe-1"),
    row("dupe", "The second of two skills with one name.", [X], scope: .folder, home: .agentFolder(X),
        problems: [.clash], id: "dupe-2"),
    row("gone", "", [K], home: .elsewhere, problems: [.brokenLink], real: .some(nil), id: "broken:gone"),
    row("spare", "In the library, given to nobody.", [], id: "/lib/spare"),
    row("figma:figma-use", "Use the Figma plugin's tools.", [C], home: .readOnly("Plugin"),
        real: .some(nil), kind: .readOnly, label: "Plugin", id: "ro:c:fig"),
    row("vercel:deploy", "Deploy with Vercel.", [C], home: .readOnly("Plugin"), real: .some(nil),
        kind: .readOnly, label: "Plugin", id: "ro:c:ver"),
    row("imagegen", "Generate an image.", [X], home: .readOnly("Built-in"), kind: .readOnly,
        label: "Built-in", id: "ro:x:img"),
    row("hand-made", "Written for Claude Code; Kimi Code skips it.", [K], home: .agentFolder(K),
        id: "/x/kimi/hand-made", format: [.noName]),
    row("terse", "", [X], home: .agentFolder(X), id: "/x/codex/terse",
        loadErrors: [X: "missing field `description`"]),
]

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    SkillFolderHistory.defaults = UserDefaults(suiteName: scratch.appendingPathComponent("prefs").path)!
    let config = ConfigManager()
    config.preloads[C] = ["commit-msg"]
    let agents = AgentManager()
    let appState = AppState()
    appState.skillsFolder = folder
    appState.skillsFolderChosen = true
    let catalog = SkillCatalog.shared
    catalog.snapshots[SkillCatalog.key(folder)] = SkillSnapshot(folder: folder.path, projectRoot: folder.path,
                                                                rows: rows, claudeAnswered: true, codexAnswered: true)

    struct Host<Content: View>: View {
        let tier: FontTier
        let content: Content
        var body: some View {
            content
                .environment(\.sipFontScale, tier.scale)
                .environment(\.sipLineSpacingFactor, tier.lineSpacingFactor)
        }
    }

    /// Lay a view out offscreen at `width`, as tall as it wants, and
    /// leave it standing in its window.
    func stand<V: View>(_ view: V, width: CGFloat, dark: Bool) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let root = AnyView(view
            .environmentObject(config)
            .environmentObject(agents)
            .environmentObject(appState)
            .padding(16)
            .frame(width: width, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        let host = NSHostingView(rootView: root)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = appearance
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let size = host.fittingSize
        window.setContentSize(NSSize(width: width, height: max(size.height, 40)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: max(size.height, 40))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return (host, window)
    }

    func writePNG(_ host: NSHostingView<AnyView>, name: String) {
        if let dir = renderDir, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
        }
    }

    /// Lay a view out offscreen; return the host for measuring, after
    /// writing a PNG when asked.
    @discardableResult
    func render<V: View>(_ view: V, width: CGFloat, dark: Bool, name: String) -> NSHostingView<AnyView> {
        let (host, window) = stand(view, width: width, dark: dark)
        writePNG(host, name: name)
        window.orderOut(nil)
        return host
    }

    /// A host's pixels, for the checks that have to be made on what is
    /// drawn. Points are the host's own, y down from its top.
    struct Shot {
        let rep: NSBitmapImageRep
        let scale: CGFloat
        let size: CGSize
        init?(_ host: NSHostingView<AnyView>) {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            self.rep = rep
            self.scale = CGFloat(rep.pixelsWide) / host.bounds.width
            self.size = host.bounds.size
        }
        /// Brightness, 0…1, of the pixel at a pixel position.
        func light(_ x: Int, _ y: Int) -> CGFloat {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 1 }
            return (c.redComponent + c.greenComponent + c.blueComponent) / 3
        }
        func light(at p: CGPoint) -> CGFloat { light(Int(p.x * scale), Int(p.y * scale)) }
        /// The page's own colour, read where nothing is drawn.
        var paper: CGFloat { light(2, 2) }
        /// Text and glyphs: far from the paper. A hover fill is a tint,
        /// well short of this.
        func isInk(_ x: Int, _ y: Int) -> Bool { abs(light(x, y) - paper) > 0.12 }
        /// The lines of ink in a band of columns (points), top to
        /// bottom, as pixel-row ranges.
        func lines(from x0: CGFloat, to x1: CGFloat) -> [ClosedRange<Int>] {
            var out: [ClosedRange<Int>] = []
            var start: Int? = nil
            let xs = Int(x0 * scale)..<min(rep.pixelsWide, Int(x1 * scale))
            for y in 0..<rep.pixelsHigh {
                let any = xs.contains { isInk($0, y) }
                if any, start == nil { start = y }
                if !any, let s = start { out.append(s...(y - 1)); start = nil }
            }
            if let s = start { out.append(s...(rep.pixelsHigh - 1)) }
            return out
        }
        /// Where each run of ink starts in a line, in points from the
        /// left: runs are parted by a gap of `gap` points or more.
        func runStarts(in line: ClosedRange<Int>, gap: CGFloat) -> [CGFloat] {
            var out: [CGFloat] = []
            var blank = Int.max / 2
            for x in 0..<rep.pixelsWide {
                if line.contains(where: { isInk(x, $0) }) {
                    if CGFloat(blank) >= gap * scale { out.append(CGFloat(x) / scale) }
                    blank = 0
                } else {
                    blank += 1
                }
            }
            return out
        }
    }

    print("\n1. The pane")
    for tier in [FontTier.standard, .xlarge] {
        let ratio = SipFont.ratio(tier.scale)
        let width = (640 * ratio).rounded()
        for dark in [false, true] {
            let host = render(Host(tier: tier, content: SkillsPane()), width: width + 32, dark: dark,
                              name: "pane-\(tier.rawValue)-\(dark ? "dark" : "light")")
            check("pane lays out at \(tier.rawValue) \(dark ? "dark" : "light")",
                  host.fittingSize.height > 200, "height \(host.fittingSize.height)")
            check("pane fits its column at \(tier.rawValue)",
                  host.fittingSize.width <= width + 32 + 0.5, "width \(host.fittingSize.width)")
        }
    }

    print("\n1b. The narrowest column, a long folder name")
    // Settings' column is never narrower than 420 pt × the tier's ratio
    // (`SettingsPageLayout`); the toolbar must fit it whatever the
    // folder is called.
    let longFolder = URL(fileURLWithPath: "/Users/someone/Projects/A rather long project folder name, version two",
                         isDirectory: true)
    catalog.snapshots[SkillCatalog.key(longFolder)] = SkillSnapshot(folder: longFolder.path, projectRoot: longFolder.path,
                                                                    rows: rows, claudeAnswered: true, codexAnswered: true)
    appState.skillsFolder = longFolder
    /// The rightmost column, in points, of the New Skill button's blue in
    /// the toolbar's band — measured in pixels: the host's frame is
    /// pinned to the column, so its size cannot show a row that runs
    /// past it.
    func blueRightEdge(_ host: NSHostingView<AnyView>, band: CGFloat) -> CGFloat? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        var right: Int? = nil
        for y in 0..<min(rep.pixelsHigh, Int(band * scale)) {
            for x in stride(from: rep.pixelsWide - 1, through: 0, by: -1) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.blueComponent > 0.8, c.redComponent < 0.35, c.greenComponent < 0.6 {
                    right = max(right ?? 0, x)
                    break
                }
            }
        }
        return right.map { CGFloat($0 + 1) / scale }
    }
    for tier in [FontTier.standard, .xlarge] {
        let width = (420 * SipFont.ratio(tier.scale)).rounded()
        let host = render(Host(tier: tier, content: SkillsPane()), width: width + 32, dark: false,
                          name: "pane-narrow-\(tier.rawValue)")
        let edge = blueRightEdge(host, band: 200 * SipFont.ratio(tier.scale))
        check("the toolbar fits the narrowest column at \(tier.rawValue), a long folder name included",
              edge.map { $0 <= width + 16 + 0.5 } == true,
              "New Skill ends at \(edge.map { "\($0)" } ?? "nowhere") for a column ending at \(width + 16)")
    }
    appState.skillsFolder = folder

    print("\n1c. No skills of its own: a line in the group's place")
    // What an agent lacks is said, not left out — for what the page
    // shows: "No skills in <the folder>" when a folder is on it, "No
    // global skills" on Global, never the global line under a folder.
    // Each where the group would be, on the groups' own text column:
    // where "Plugins" starts.
    let fig = row("figma:figma-use", "Use the Figma plugin's tools.", [C], home: .readOnly("Plugin"),
                  real: .some(nil), kind: .readOnly, label: "Plugin", id: "ro:c:fig")
    let common = row("release-notes", "Draft the release notes from the merged pull requests.",
                     [X, K], scope: .folder, home: .common, kind: .common, id: "common-rs")
    /// A folder's read, and — as the catalog's walk would have found
    /// them — the subfolders below it that hold skills.
    @MainActor func snapshot(_ rows: [SkillRow], at url: URL?, subfolders: [String] = [], stoppedEarly: Bool = false) {
        catalog.snapshots[SkillCatalog.key(url)] = SkillSnapshot(folder: url?.path, projectRoot: url?.path,
                                                                 rows: rows, claudeAnswered: true, codexAnswered: true)
        if let url {
            catalog.subfolders[SkillCatalog.key(url)] = SkillSubfolders(found: subfolders.map(SkillLevel.init(path:)),
                                                                        stoppedEarly: stoppedEarly)
        }
    }
    /// Let the pages standing from earlier sections answer a change, so
    /// that what is checked next is the page made next.
    @MainActor func settlePages() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
    // To look at: one agent short of folder skills, two short of global
    // ones — then the same page on Global, where only global ones count.
    snapshot([rows[3], fig, common, rows[11]], at: folder)
    render(Host(tier: .standard, content: SkillsPane()), width: 640 + 32, dark: false, name: "pane-empty-default-light")
    render(Host(tier: .xlarge, content: SkillsPane()),
           width: (640 * SipFont.ratio(FontTier.xlarge.scale)).rounded() + 32, dark: true, name: "pane-empty-xlarge-dark")
    snapshot([rows[3], fig, rows[11]], at: nil)
    appState.skillsFolder = nil
    render(Host(tier: .standard, content: SkillsPane()), width: 640 + 32, dark: false, name: "pane-empty-global-light")
    // To measure: one agent with plugins and nothing of its own, so the
    // page ends on three known lines — the agent's header, ONE sentence,
    // then Plugins.
    snapshot([fig], at: folder)
    snapshot([fig], at: nil)
    agents.listed = [C]
    for (mode, place) in [("under a folder", Optional(folder)), ("on Global", nil)] {
        appState.skillsFolder = place
        for tier in [FontTier.standard, .xlarge] {
            let ratio = SipFont.ratio(tier.scale)
            let host = render(Host(tier: tier, content: SkillsPane()), width: (640 * ratio).rounded() + 32, dark: false,
                              name: "pane-none-\(place == nil ? "global" : "folder")-\(tier.rawValue)")
            guard let shot = Shot(host) else { check("the page could be read back at \(tier.rawValue)", false); continue }
            let lines = shot.lines(from: 16, to: 16 + 200 * ratio)
            guard lines.count >= 4 else { check("the page ends on its three lines (\(mode), \(tier.rawValue))", false, "\(lines.count) lines"); continue }
            let plugins = shot.runStarts(in: lines[lines.count - 1], gap: 5 * ratio)
            let sentence = shot.runStarts(in: lines[lines.count - 2], gap: 5 * ratio)
            let header = shot.runStarts(in: lines[lines.count - 3], gap: 5 * ratio)
            // Plugins' line opens with its chevron; its word is the next run.
            let word = plugins.count > 1 ? plugins[1] : -1
            let detail = "header at \(header.first ?? -1), sentence at \(sentence.first ?? -1), "
                + "Plugins' chevron at \(plugins.first ?? -1) and word at \(word)"
            check("\(mode), an agent with no skills of its own says so above its plugins, starting where the word Plugins starts (\(tier.rawValue))",
                  plugins.count > 1 && abs((sentence.first ?? 0) - word) <= 1.5 && word - plugins[0] > 8 * ratio, detail)
            check("…in ONE sentence: above it is the agent's header, not a second line (\(mode), \(tier.rawValue))",
                  (header.first ?? .infinity) < word - 8 * ratio, detail)
        }
    }
    agents.listed = [C, X, K]
    appState.skillsFolder = folder
    snapshot(rows, at: folder)

    /// A pointer and clicks delivered to a standing window, and the menus
    /// a click opens — read, then closed from inside their own tracking
    /// loop. SwiftUI reads hover off one of its hosting view's tracking
    /// areas, which is not always the first (a tooltip's can come
    /// before it), so the first move is announced as an entry into each.
    @MainActor final class Pointer {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        var entered = false
        var menus: [NSMenu] = []
        var watch: NSObjectProtocol? = nil
        init(_ host: NSHostingView<AnyView>, _ window: NSWindow) {
            self.host = host
            self.window = window
            watch = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                           object: nil, queue: nil) { [weak self] note in
                guard let menu = note.object as? NSMenu else { return }
                MainActor.assumeIsolated { self?.menus.append(menu) }
                let timer = Timer(timeInterval: 0.05, repeats: true) { _ in menu.cancelTrackingWithoutAnimation() }
                RunLoop.main.add(timer, forMode: .common)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { timer.invalidate() }
            }
        }
        func stop() { if let watch { NotificationCenter.default.removeObserver(watch) } }
        /// A point of the host (y down) as the window names it (y up).
        func inWindow(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: host.bounds.height - p.y) }
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: inWindow(p), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        func point(_ p: CGPoint) -> Bool {
            guard !host.trackingAreas.isEmpty else { return false }
            if !entered {
                for area in host.trackingAreas {
                    guard let enter = NSEvent.enterExitEvent(
                        with: .mouseEntered, location: inWindow(p), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0,
                        trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()),
                        userData: nil), enter.trackingArea === area else { return false }
                    host.mouseEntered(with: enter)
                }
                entered = true
            }
            guard let move = mouse(.mouseMoved, p) else { return false }
            host.mouseMoved(with: move)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            return true
        }
        /// The menus a click at `p` opened.
        func click(_ p: CGPoint) -> [NSMenu] {
            menus = []
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = mouse(type, p) { window.sendEvent(event) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            }
            return menus
        }
        func titles(_ p: CGPoint) -> [[String]] { click(p).map { $0.items.map(\.title) } }
    }

    // The first row's dots: ink in the column's last 28 pt with none
    // just left of it — a rule, and the New Skill button, run on.
    func firstDots(_ shot: Shot, right: CGFloat) -> CGPoint? {
        let box = Int((right - 28) * shot.scale)..<Int(right * shot.scale)
        let beside = Int((right - 60) * shot.scale)..<Int((right - 32) * shot.scale)
        var rowsWithDots: [Int] = []
        for y in 0..<shot.rep.pixelsHigh where box.contains(where: { shot.isInk($0, y) })
            && !beside.contains(where: { shot.isInk($0, y) }) {
            if let last = rowsWithDots.last, y - last > 1 { break }
            rowsWithDots.append(y)
        }
        guard let top = rowsWithDots.first, let bottom = rowsWithDots.last else { return nil }
        let xs = box.filter { x in (top...bottom).contains { shot.isInk(x, $0) } }
        guard let l = xs.first, let r = xs.last else { return nil }
        return CGPoint(x: CGFloat(l + r + 1) / 2 / shot.scale, y: CGFloat(top + bottom + 1) / 2 / shot.scale)
    }

    print("\n1d. A row's … button answers the pointer; nothing else in the row does")
    // The pointer and the click are delivered to the standing window:
    // what fills, and what a click opens, are the app's own answers.
    do {
        let width: CGFloat = 640 + 32
        let (host, window) = stand(Host(tier: .standard, content: SkillsPane()), width: width, dark: false)
        defer { window.orderOut(nil) }
        let pointer = Pointer(host, window)
        defer { pointer.stop() }
        /// The largest change of brightness between two shots over a
        /// rectangle of points.
        func change(_ a: Shot, _ b: Shot, in r: CGRect) -> CGFloat {
            var most: CGFloat = 0
            for y in Int(r.minY * a.scale)..<Int(r.maxY * a.scale) {
                for x in Int(r.minX * a.scale)..<Int(r.maxX * a.scale) {
                    most = max(most, abs(a.light(x, y) - b.light(x, y)))
                }
            }
            return most
        }

        let right = width - 16
        // A pointer SwiftUI never answers would fill nothing anywhere: the
        // box's fill fails, and every "fills nothing" passes untested.
        let hover = HoverGate(report: { check($0, $1, $2()) })
        if let rest = Shot(host), let dots = firstDots(rest, right: right) {
            // The box the pane gives the button: 28 × 22, the dots at its centre.
            let box = CGRect(x: dots.x - 14, y: dots.y - 11, width: 28, height: 22)
            let corner = CGPoint(x: box.minX + 3, y: box.minY + 3)          // in the box, far from the dots
            let far = CGPoint(x: box.maxX - 3, y: box.maxY - 3)             // its opposite corner
            let onName = CGPoint(x: 16 + 36 + 12, y: dots.y - 8)            // on the skill's name
            let beside = CGPoint(x: box.minX - 8, y: dots.y)                // in the row, just left of the box
            let rowBand = CGRect(x: 16, y: box.minY - 10, width: box.minX - 2 - 16, height: 42)
            check("the first row's … sits at the column's right edge",
                  abs(box.maxX - right) <= 1.5, "box ends at \(box.maxX), column at \(right)")
            if pointer.point(onName), let overName = Shot(host) {
                hover.check("the pointer on a row's name fills nothing: the row has no hover of its own",
                            change(rest, overName, in: rowBand) < 0.02 && change(rest, overName, in: box) < 0.02,
                            "row changed by \(change(rest, overName, in: rowBand)), "
                                + "box by \(change(rest, overName, in: box))")
                _ = pointer.point(corner)
                if let overBox = Shot(host) {
                    let fill = rest.light(at: far) - overBox.light(at: far)
                    hover.check("the pointer in the box's corner fills the whole box",
                                fill > 0.03 && fill < 0.3 && rest.light(at: corner) - overBox.light(at: corner) > 0.03,
                                "the far corner darkened by \(fill)")
                    hover.check("…and nothing left of the box",
                                change(rest, overBox, in: rowBand) < 0.02,
                                "row changed by \(change(rest, overBox, in: rowBand))")
                    let menus = pointer.titles(corner)
                    check("a click there — fill up, away from the dots — opens the skill's menu",
                          menus.count == 1 && menus[0].contains("Delete…") && menus[0].contains("Share With"),
                          "\(menus)")
                    let items = menus.first ?? []
                    let offItems = items.filter { $0.hasPrefix("Off") }
                    check("…its Off says where it applies in the item itself, and no line of its own says it again",
                          offItems.count == 1 && offItems[0].hasPrefix("Off (applies to ")
                          && !items.contains { $0.hasPrefix("Off is saved") || $0.hasPrefix("Off applies in") },
                          "\(items)")
                    let none = pointer.titles(beside)
                    check("…and a click just left of the box opens nothing", none.isEmpty, "\(none)")
                    _ = pointer.point(onName)
                    if let after = Shot(host) {
                        hover.check("the fill goes when the pointer leaves the box",
                                    change(rest, after, in: box) < 0.02,
                                    "box still differs by \(change(rest, after, in: box))")
                    }
                }
            } else {
                // No way in: this macOS hands SwiftUI its hover another way.
                print("  SKIP the pointer could not be delivered to the page (no tracking area to enter)")
            }
        } else {
            check("the first row's … was found on the page", false)
        }
    }

    print("\n1e. The search starts the toolbar; the folder menu has a row of its own, listing the folders browsed")
    // Fourteen real folders browsed over the last weeks, one of them since
    // deleted and one browsed six weeks ago — twelve left, two more than
    // the menu lists; the page opens on one browsed five days ago, which
    // makes it the newest.
    do {
        let now = Date()
        var history: [SkillFolderHistory.Visit] = []
        var made: [URL] = []
        for i in 0..<14 {
            let dir = scratch.appendingPathComponent("browsed-\(i)", isDirectory: true)
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            made.append(URL(fileURLWithPath: dir.standardizedFileURL.path, isDirectory: true))
            history.append(.init(path: made[i].path, at: now.addingTimeInterval(-Double(i + 1) * 86_400)))
        }
        history[13].at = now.addingTimeInterval(-42 * 86_400)                 // six weeks: retired
        try! FileManager.default.removeItem(at: made[3])                      // gone from disk
        let opened = made[4]
        snapshot(rows, at: opened)
        appState.skillsFolder = opened
        // The pages still standing from the sections above record the
        // folder too; the history is put back after them, so that what
        // is read below is what the page made NOW wrote as it appeared.
        settlePages()
        SkillFolderHistory.save(history)
        let width: CGFloat = 640 + 32
        let (host, window) = stand(Host(tier: .standard, content: SkillsPane()), width: width, dark: false)
        writePNG(host, name: "pane-folder-row-light")
        let pointer = Pointer(host, window)
        if let shot = Shot(host) {
            // The toolbar is where New Skill's blue is; the folder row is
            // the first line of ink under it.
            var blue: [Int] = []
            for y in 0..<shot.rep.pixelsHigh {
                for x in stride(from: shot.rep.pixelsWide - 1, through: shot.rep.pixelsWide / 2, by: -1) {
                    guard let c = shot.rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if c.blueComponent > 0.8, c.redComponent < 0.35, c.greenComponent < 0.6 { blue.append(y); break }
                }
            }
            let lines = shot.lines(from: 16, to: width - 16)
            if let toolbarBottom = blue.max(),
               let toolbar = lines.first(where: { $0.contains(toolbarBottom) }),
               let row = lines.first(where: { $0.lowerBound > toolbarBottom }) {
                let toolbarRuns = shot.runStarts(in: toolbar, gap: 6)
                let runs = shot.runStarts(in: row, gap: 6)
                var lastInk: CGFloat = 0
                for x in 0..<shot.rep.pixelsWide where row.contains(where: { shot.isInk(x, $0) }) { lastInk = CGFloat(x) / shot.scale }
                let detail = "toolbar starts at \(toolbarRuns.first ?? -1), folder row at \(runs.first ?? -1) to \(lastInk)"
                check("the toolbar starts with the search box, its glyph inside the box's left edge",
                      (toolbarRuns.first ?? 0) >= 16 + 5 && (toolbarRuns.first ?? 99) <= 16 + 12, detail)
                check("the folder menu sits on the line under it, flush with the page's left edge",
                      (runs.first ?? 0) >= 15 && (runs.first ?? 99) <= 18.5, detail)
                check("…alone on its row: nothing past its label", lastInk < 16 + (width - 32) * 0.5, detail)
                let rowMid = CGFloat(row.lowerBound + row.upperBound) / 2 / shot.scale
                let menus = pointer.titles(CGPoint(x: 16 + 6, y: rowMid))
                let titles = menus.first ?? []
                let listedNow = titles.filter { $0.hasPrefix("/") }
                let surviving = made.enumerated().filter { ![3, 4, 13].contains($0.offset) }.map { $0.element.path }
                let expected = [opened.path] + surviving
                check("a click on it opens the folder menu: Global first, Choose Folder… last",
                      titles.first == "Global" && titles.last == "Choose Folder…", "\(titles)")
                check("…listing the folders browsed, the newest first — none gone from disk, none older than a month",
                      listedNow == Array(expected.prefix(10)), "\(listedNow.map { ($0 as NSString).lastPathComponent })")
                check("…ten at most: twelve could be listed", expected.count == 12 && listedNow.count == 10, "\(listedNow.count) of \(expected.count)")
                let kept = SkillFolderHistory.load().map(\.path)
                check("the page's own folder is recorded as browsed as it appears",
                      kept.first == opened.path, "\(kept.prefix(2).map { ($0 as NSString).lastPathComponent })")
                check("…the folder gone from disk left out of the menu and kept in the history; the one six weeks old dropped from both",
                      kept.contains(made[3].path) && !listedNow.contains(made[3].path) && !kept.contains(made[13].path),
                      "\(kept.map { ($0 as NSString).lastPathComponent })")
            } else {
                check("the toolbar and the row under it were found", false, "blue rows \(blue.count), lines \(lines.count)")
            }
        }
        pointer.stop()
        window.orderOut(nil)

        // With nothing chosen and no session open, the page opens on the
        // folder browsed last — the newest that is still on disk.
        appState.skillsFolder = nil
        settlePages()
        var again = history
        again[0].at = now                                                     // browsed-0: the newest…
        try! FileManager.default.removeItem(at: made[0])                      // …and gone from disk
        again[1].at = now.addingTimeInterval(-60)                             // browsed-1: the newest still there
        SkillFolderHistory.save(again)
        snapshot(rows, at: made[1])
        appState.skillsFolderChosen = false
        _ = render(Host(tier: .standard, content: SkillsPane()), width: width, dark: false, name: "pane-default-folder")
        check("nothing chosen, no session open: the page opens on the folder browsed last that is still on disk",
              appState.skillsFolder?.path == made[1].path, "\(appState.skillsFolder?.lastPathComponent ?? "Global")")
        appState.skillsFolderChosen = true
        appState.skillsFolder = folder
        settlePages()
    }

    print("\n1f. A subfolder's skills: a group of their own, acted on in that subfolder")
    // The page on a folder whose agent has nothing of its own there, and
    // two skills in a subfolder — read as a folder of its own.
    do {
        let sub = folder.appendingPathComponent("Engine", isDirectory: true)
        func subRow(_ name: String) -> SkillRow {
            let path = sub.path + "/.agents/skills/" + name
            var fmatter = SkillFrontmatter()
            fmatter.name = name
            fmatter.description = "Lives in the subfolder."
            var r = SkillRow(id: path, name: name, description: "Lives in the subfolder.", scope: .folder,
                             home: .common, realPath: path, entries: [:], frontmatter: fmatter)
            for a in [X, K] {
                r.entries[a] = SkillEntry(agent: a, name: name, description: "Lives in the subfolder.", scope: .folder,
                                          rootKind: .common, entryPath: path, realPath: path, isLink: false,
                                          frontmatter: fmatter)
                r.states[a] = .on
            }
            return r
        }
        agents.listed = [X]
        let width: CGFloat = 640 + 32
        // Lines of the text column alone: a row's … sits between its
        // name and its description, and would count as a line of its own.
        func page(_ name: String) -> (Shot?, [ClosedRange<Int>]) {
            let host = render(Host(tier: .standard, content: SkillsPane()), width: width, dark: false, name: name)
            let shot = Shot(host)
            return (shot, shot?.lines(from: 16, to: width - 16 - 40) ?? [])
        }
        // Before the subfolder's own read is in: the folder's line alone.
        snapshot([], at: folder, subfolders: [sub.path])
        catalog.snapshots[SkillCatalog.key(sub)] = nil
        // The pages standing from above answer the change first; what is
        // recorded after this is what the page made NOW asks as it appears.
        settlePages()
        catalog.subfoldersAsked = []
        catalog.walksAsked = []
        let (beforeShot, before) = page("pane-subfolder-unread-light")
        check("as it appears, the page asks for the folder to be looked below, and for its subfolders to be read",
              catalog.walksAsked == [folder.path] && catalog.subfoldersAsked.contains { $0 == [sub.path] },
              "walks \(catalog.walksAsked), reads \(catalog.subfoldersAsked)")
        // With it: the folder's line, then the subfolder's group.
        snapshot([subRow("draft-notes"), subRow("lint-pr"), rows[0]], at: sub)
        let (afterShot, after) = page("pane-subfolder-light")
        if let beforeShot, let afterShot, before.count >= 2, after.count >= 7 {
            let lastLine = before[before.count - 1]
            var shortEnd: CGFloat = 0, longEnd: CGFloat = 0
            let sentence = after[after.count - 6]
            for x in 0..<beforeShot.rep.pixelsWide where lastLine.contains(where: { beforeShot.isInk(x, $0) }) { shortEnd = CGFloat(x) / beforeShot.scale }
            for x in 0..<afterShot.rep.pixelsWide where sentence.contains(where: { afterShot.isInk(x, $0) }) { longEnd = CGFloat(x) / afterShot.scale }
            let groupHeader = afterShot.runStarts(in: after[after.count - 5], gap: 5)
            let firstName = afterShot.runStarts(in: after[after.count - 4], gap: 5)
            let sentenceStart = afterShot.runStarts(in: sentence, gap: 5)
            let detail = "sentence \(sentenceStart.first ?? -1)…\(longEnd) (alone: …\(shortEnd)), group \(groupHeader.first ?? -1), name \(firstName.first ?? -1)"
            check("unread, the agent's folder line ends the page; read, the subfolder's two skills follow in a group",
                  after.count == before.count + 5, "\(before.count) lines, then \(after.count); " + detail)
            check("…the folder's line says the folder ITSELF has none — it is longer by that word",
                  longEnd > shortEnd + 20, detail)
            check("…the group's header one step in, its skills on the text column, with the folder's line",
                  abs((sentenceStart.first ?? 0) - (firstName.first ?? 99)) <= 1.5
                  && (groupHeader.first ?? 0) > 16 + 12 && (groupHeader.first ?? 99) < (firstName.first ?? 0) - 8, detail)
            // A delete from that group is asked for the subfolder.
            let (host, window) = stand(Host(tier: .standard, content: SkillsPane()), width: width, dark: false)
            let pointer = Pointer(host, window)
            if let shot = Shot(host), let dots = firstDots(shot, right: width - 16) {
                let menus = pointer.click(dots)
                if let menu = menus.first, let index = menu.items.firstIndex(where: { $0.title == "Delete…" }) {
                    catalog.calls = []
                    menu.performActionForItem(at: index)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                    check("Delete on a subfolder's skill is asked for that subfolder, not the page's folder",
                          catalog.calls.contains("review remove draft-notes codex in Engine"), "\(catalog.calls)")
                } else {
                    check("the subfolder skill's menu opened, with Delete…", false, "\(menus.map { $0.items.map(\.title) })")
                }
            } else {
                check("the subfolder skill's … was found", false)
            }
            pointer.stop()
            window.orderOut(nil)
        } else {
            check("the two pages were read back", false, "\(before.count) and \(after.count) lines")
        }
        // To look at: the same at Large text mode, dark.
        render(Host(tier: .xlarge, content: SkillsPane()),
               width: (640 * SipFont.ratio(FontTier.xlarge.scale)).rounded() + 32, dark: true, name: "pane-subfolder-xlarge-dark")

        // The walk stopped early: the page says so, in words that hold
        // whether or not a skill was left out.
        let (_, whole) = page("pane-subfolder-whole")
        snapshot([], at: folder, subfolders: [sub.path], stoppedEarly: true)
        let (_, short) = page("pane-subfolder-stopped-early")
        check("a walk that stopped early is said under the list; one that did not says nothing",
              short.count > whole.count && short.count <= whole.count + 3, "\(whole.count) lines, then \(short.count)")

        // Leaving for Global lets go of the subfolders still to be read.
        snapshot([], at: folder, subfolders: [sub.path])
        settlePages()
        catalog.subfoldersAsked = []
        appState.skillsFolder = nil
        settlePages()
        check("the folder menu moved to Global: the subfolders waiting to be read are let go",
              catalog.subfoldersAsked.contains { $0.isEmpty }, "\(catalog.subfoldersAsked)")
        appState.skillsFolder = folder
        agents.listed = [C, X, K]
        snapshot(rows, at: folder)
        settlePages()

        // A row of the page's own folder acts for the page's folder.
        let (host, window) = stand(Host(tier: .standard, content: SkillsPane()), width: width, dark: false)
        let pointer = Pointer(host, window)
        if let shot = Shot(host), let dots = firstDots(shot, right: width - 16),
           let menu = pointer.click(dots).first, let index = menu.items.firstIndex(where: { $0.title == "Delete…" }) {
            catalog.calls = []
            menu.performActionForItem(at: index)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            check("Delete on a skill of the page's own folder is asked for that folder",
                  catalog.calls.contains { $0.hasPrefix("review remove ") && $0.hasSuffix(" in Atlas") }, "\(catalog.calls)")
        } else {
            check("the first row's menu opened, with Delete…", false)
        }
        pointer.stop()
        window.orderOut(nil)
    }

    print("\n2. The chip's popover")
    let choices = [
        SkillChoice(name: "review-pr", description: "Review a pull request.", scope: .global,
                    sourceLabel: nil, unavailable: nil, codexPath: nil),
        SkillChoice(name: "figma:figma-use", description: "Figma.", scope: .global,
                    sourceLabel: "Plugin", unavailable: nil, codexPath: nil),
        SkillChoice(name: "deploy", description: "Deploys.", scope: .global, sourceLabel: nil,
                    unavailable: "Switched off.", codexPath: nil),
        SkillChoice(name: "release-notes", description: "Research.", scope: .folder,
                    sourceLabel: nil, unavailable: nil, codexPath: nil),
        SkillChoice(name: "fork-task", description: "Runs on its own.", scope: .folder, sourceLabel: nil,
                    unavailable: "Runs on its own — type /fork-task instead.", codexPath: nil),
    ]
    for tier in [FontTier.standard, .xlarge] {
        for dark in [false, true] {
            let suffix = "\(tier.rawValue)-\(dark ? "dark" : "light")"
            let picker = render(Host(tier: tier, content: SkillChipPopover(
                agentLabel: "Claude Code", folderName: "Atlas", choices: choices, picks: [],
                statuses: [:], held: [], onDone: { _ in }, onClose: {})),
                width: 360 * SipFont.ratio(tier.scale) + 32, dark: dark, name: "picker-\(suffix)")
            check("picker lays out (\(suffix))", picker.fittingSize.height > 120)
            let summary = render(Host(tier: tier, content: SkillChipPopover(
                agentLabel: "Claude Code", folderName: "Atlas", choices: choices,
                picks: ["review-pr", "release-notes", "deploy"],
                statuses: SkillPickReport.statuses(picks: ["review-pr", "release-notes", "deploy"],
                                                   choices: choices, held: ["review-pr"],
                                                   missing: "Not available in this folder"),
                held: ["review-pr"], onDone: { _ in }, onClose: {})),
                width: 360 * SipFont.ratio(tier.scale) + 32, dark: dark, name: "summary-\(suffix)")
            check("summary lays out (\(suffix))", summary.fittingSize.height > 80)
        }
    }

    // A session folder with subfolders: their skills in a group each,
    // the one the send cannot reach dimmed with the reason; and Kimi's
    // picker, which says it takes one skill.
    let withSubfolders = choices + [
        SkillChoice(name: "ship-web", description: "A subfolder's skill.", scope: .folder,
                    sourceLabel: nil, unavailable: nil, codexPath: nil,
                    subfolder: "/w/Atlas/packages/web", subfolderName: "packages/web",
                    skillsFolder: "/w/Atlas/packages/web/.claude/skills"),
        SkillChoice(name: "lint-web", description: "Another.", scope: .folder, sourceLabel: nil,
                    unavailable: SkillSubfolderReach.refusal(agent: SkillAgent.codex, codex: .exec),
                    codexPath: nil, subfolder: "/w/Atlas/packages/web", subfolderName: "packages/web",
                    skillsFolder: "/w/Atlas/packages/web/.agents/skills"),
    ]
    let plain = render(Host(tier: .standard, content: SkillPickerList(
        agentLabel: "Claude Code", folderName: "Atlas", choices: choices, ticked: .constant([]))),
        width: 360 + 32, dark: false, name: "picker-plain-light").fittingSize.height
    let grouped = render(Host(tier: .standard, content: SkillPickerList(
        agentLabel: "Claude Code", folderName: "Atlas", choices: withSubfolders, ticked: .constant([]))),
        width: 360 + 32, dark: false, name: "picker-subfolder-light").fittingSize.height
    check("a subfolder's skills get a group of their own under This folder", grouped > plain + 40,
          "\(grouped) vs \(plain)")
    let kimiPicker = render(Host(tier: .standard, content: SkillPickerList(
        agentLabel: "Kimi Code", oneAtATime: true, folderName: "Atlas", choices: choices, ticked: .constant([]))),
        width: 360 + 32, dark: true, name: "picker-kimi-dark").fittingSize.height
    check("Kimi's picker carries its one-skill note", kimiPicker > plain + 10, "\(kimiPicker) vs \(plain)")
    _ = render(Host(tier: .xlarge, content: SkillPickerList(
        agentLabel: "Kimi Code", oneAtATime: true, folderName: "Atlas", choices: withSubfolders,
        ticked: .constant(["ship-web"]))),
        width: 360 * SipFont.ratio(FontTier.xlarge.scale) + 32, dark: false, name: "picker-kimi-subfolder-xlarge-light")
    // The edit sheet of a skill two agents use says so before the Save.
    let sharedRow = rows.first { $0.entries.count > 1 } ?? rows[0]
    let editShared = render(Host(tier: .standard, content: SkillEditorSheet(
        request: .edit(sharedRow), agentLabels: [(C, "Claude Code"), (X, "Codex"), (K, "Kimi Code")],
        folder: folder, scopeName: "Atlas", offersFolderScope: true, onFinish: { _ in })),
        width: 600, dark: false, name: "edit-shared-light")
    check("the edit sheet of a shared skill lays out", editShared.fittingSize.height > 300)

    print("\n3. Detail and the new-skill sheet")
    func agentName(_ key: String) -> String {
        AgentManager.registry.first(where: { $0.key == key })?.name ?? key
    }
    render(Host(tier: .standard, content: SkillDetailView(row: rows[3], agents: [C, X, K], label: agentName)),
           width: 440, dark: true, name: "detail-dark")
    let sheet = render(Host(tier: .standard, content: SkillEditorSheet(
        request: .new, agentLabels: [(C, "Claude Code"), (X, "Codex"), (K, "Kimi Code")],
        folder: folder, scopeName: "Atlas", offersFolderScope: true, onFinish: { _ in })), width: 600, dark: false, name: "new-skill-light")
    check("new-skill sheet lays out", sheet.fittingSize.height > 300)
    // A folder with no scope of its own (its project root is the home
    // folder) offers no "only this folder": one row less.
    let unscoped = render(Host(tier: .standard, content: SkillEditorSheet(
        request: .new, agentLabels: [(C, "Claude Code"), (X, "Codex"), (K, "Kimi Code")],
        folder: folder, scopeName: nil, offersFolderScope: false, onFinish: { _ in })), width: 600, dark: false,
        name: "new-skill-unscoped-light")
    check("…and offers no folder scope where the folder has none",
          unscoped.fittingSize.height < sheet.fittingSize.height - 10,
          "\(unscoped.fittingSize.height) vs \(sheet.fittingSize.height)")

    print("\n4. A chosen skill that is gone can still be unticked")
    // The picker over the same choices, once with every tick among them
    // and once with one that names no skill here: that one must be drawn,
    // or nothing in the chip could ever remove it.
    func pickerHeight(_ ticked: [String], _ name: String) -> CGFloat {
        render(Host(tier: .standard, content: SkillPickerList(
            agentLabel: "Claude Code", folderName: "Atlas", choices: choices, ticked: .constant(ticked))),
            width: 360 + 32, dark: false, name: name).fittingSize.height
    }
    let known = pickerHeight(["review-pr"], "picker-ticked-light")
    let orphaned = pickerHeight(["review-pr", "deleted-skill"], "picker-orphan-light")
    check("a ticked name with no skill behind it gets a row of its own",
          orphaned > known + 12, "\(orphaned) vs \(known)")
    let onlyOrphans = render(Host(tier: .standard, content: SkillPickerList(
        agentLabel: "Claude Code", folderName: "Atlas", choices: [], ticked: .constant(["deleted-skill"]))),
        width: 360 + 32, dark: false, name: "picker-only-orphan-light").fittingSize.height
    let empty = render(Host(tier: .standard, content: SkillPickerList(
        agentLabel: "Claude Code", folderName: "Atlas", choices: [], ticked: .constant([]))),
        width: 360 + 32, dark: false, name: "picker-empty-light").fittingSize.height
    check("…even when the agent has no skills here at all", onlyOrphans > 40 && abs(onlyOrphans - empty) > 1,
          "\(onlyOrphans) vs \(empty)")

    print("\n5. The pane's type and gaps are the Display pane's")
    // Read off the sources: the Display pane is what Settings' other
    // pages are held to, and a size or a gap changed on one side only
    // fails here.
    let appDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
    let paneSource = (try? String(contentsOfFile: appDir + "/Views/Settings/SkillsPane.swift", encoding: .utf8)) ?? ""
    let sheetsSource = (try? String(contentsOfFile: appDir + "/Views/Settings/SkillSheets.swift", encoding: .utf8)) ?? ""
    let settingsSource = (try? String(contentsOfFile: appDir + "/Views/Settings/SettingsView.swift", encoding: .utf8)) ?? ""
    /// The text of the declaration that opens with `marker`, to its
    /// closing brace.
    func body(of marker: String, in text: String) -> String {
        guard let start = text.range(of: marker) else { return "" }
        var depth = 0
        var opened = false
        var index = start.lowerBound
        while index < text.endIndex {
            let c = text[index]
            if c == "{" { depth += 1; opened = true }
            if c == "}" { depth -= 1 }
            index = text.index(after: index)
            if opened && depth == 0 { break }
        }
        return String(text[start.lowerBound..<index])
    }
    func has(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
    let display = body(of: "struct DisplayPane: View {", in: settingsSource)
    let paneBody = body(of: "var body: some View {", in: body(of: "struct SkillsPane: View {", in: paneSource))
    let sectionHeader = body(of: "private func sectionView(", in: paneSource)
    let groupHeader = body(of: "private func groupView(", in: paneSource)
    let skillRow = body(of: "private struct SkillsPaneRow: View {", in: paneSource)
    let toolbar = body(of: "private var toolbar: some View {", in: paneSource)
    check("the sources were found", !display.isEmpty && !paneBody.isEmpty && !skillRow.isEmpty && !toolbar.isEmpty)
    check("both pages stack their blocks 12 pt apart",
          display.contains("VStack(alignment: .leading, spacing: 12)")
          && paneBody.contains("VStack(alignment: .leading, spacing: 12)")
          && sectionHeader.contains("VStack(alignment: .leading, spacing: 12)"))
    check("…with the same rule between sections",
          display.contains("Divider().padding(.vertical, 4)") && paneSource.contains("Divider().padding(.vertical, 4)"))
    check("a section is headed as Display's are: 14 pt semibold, as written, not in capitals",
          has(display, #"\.sipFont\(14, weight: \.semibold\)"#)
          && has(sectionHeader, #"\.sipFont\(14, weight: \.semibold\)"#)
          && !sectionHeader.contains("uppercased()"))
    check("a group under it is one step down, 13 pt — Display's sub-rows' size",
          has(display, #"\.sipFont\(13\)"#) && has(groupHeader, #"\.sipFont\(13, weight: \.medium\)"#))
    check("a skill's name is a Display row's 14 pt, its description Display's 12 pt help text",
          has(display, #"Text\(key\)\s*\.sipFont\(14\)"#)
          && has(skillRow, #"Text\(verbatim: row\.name\)\s*\.sipFont\(14\)"#)
          && has(display, #"\.sipFont\(12\)\s*\.foregroundStyle\(\.secondary\)"#)
          && has(skillRow, #"Text\(verbatim: row\.description\)\s*\.sipFont\(12\)"#)
          && has(paneBody, #"\.sipFont\(12\)\s*\.foregroundStyle\(\.secondary\)"#))
    check("rows sit 12 pt apart, text to text", skillRow.contains(".padding(.vertical, 6)"))
    check("no size below Display's smallest is left on the words a reader reads",
          !has(skillRow, #"Text\(verbatim: row\.(name|description)\)\s*\.sipFont\((10|11)\b"#)
          && !has(sectionHeader, #"Text\(verbatim: section\.title\)\s*\.sipFont\((10|11|12|13)\b"#)
          && !has(groupHeader, #"Text\(verbatim: group\.title\)\s*\.sipFont\((10|11|12)\b"#))

    print("\n6. What the pane shows")
    check("no column of checkboxes: an agent's skills are drawn under that agent",
          !paneSource.contains("checkmark.square") && !paneSource.contains("columnWidth")
          && !paneSource.contains("SkillAgentCell") && paneSource.contains("SkillListing.rows(of: agent"))
    check("no Shared section",
          !paneSource.contains("\"Shared\"") && !paneSource.contains("section(listed:"))
    check("a skill other agents have is hinted, in italics, beside its name",
          skillRow.contains("SkillListing.hint(row, under: agent")
          && has(skillRow, #"Text\(verbatim: hint\)\s*\.italic\(\)"#)
          && skillRow.contains("\"shared with \\(others)\""))
    check("…the hint says so when its files are in the common folder, and no tag does",
          skillRow.contains("\"shared with \\(others) in the common folder\"")
          && skillRow.contains("\"in the common folder\"")
          && !paneSource.contains("\"Common folder\""))
    check("a row has one hover, the … button's, whose box is the menu label's own — frame, fill and shape",
          skillRow.components(separatedBy: ".onHover").count == 2
          && skillRow.contains(".onHover { moreHovered = $0 }")
          && has(skillRow, #"\.frame\(width: moreBox\.width, height: moreBox\.height\)\s*\.background\(RoundedRectangle\(cornerRadius: 6\)\s*\.fill\(moreHovered \? SipDesign\.rowHover : Color\.clear\)\)\s*\.contentShape\(Rectangle\(\)\)"#))
    check("an agent's missing skills are said in the group's place, on the groups' text column",
          paneSource.contains("\"No global skills\"") && paneSource.contains("\"No skills in \\(name)\"")
          && has(groupHeader, #"if let line = group\.emptyLine \{[^}]*\.padding\(\.leading, 2 \* step\)"#)
          && paneSource.contains("private var step: CGFloat { chevronWidth + chevronGap }")
          && !paneSource.contains("No skills yet."))
    check("…the global line only when Global is what the page shows; the folder's says \"itself\" when subfolders follow",
          paneSource.contains("} else if saysWhenEmpty, folder == nil {")
          && paneSource.contains("\"No skills in \\(name) itself\"") && paneSource.contains("let line = below.isEmpty"))
    check("a skill's … menu shares it with the other listed agents",
          skillRow.contains("SkillListing.shareTargets(row, from: agent, listed: pane.listedAgents)")
          && skillRow.contains("Menu(String(localized: \"Share With\"")
          && skillRow.contains("pane.share(row, with: target.agent, in: folder)"))
    check("…and deletes it from that agent alone",
          skillRow.contains("pane.delete(row, from: agent, in: folder)")
          && body(of: "func delete(_ row: SkillRow, from agent: String?, in folder: URL?)", in: paneSource)
            .contains("catalog.reviewRemove(row: row, from: agent")
          && paneSource.contains("catalog.remove(row: row, from: agent, folder: folder)"))
    check("a search opens every group: what it found is drawn, a group folded by default included",
          has(paneSource, #"private func isFolded\(_ id: String, byDefault: Bool\) -> Bool \{\s*if !query\.trimmingCharacters\(in: \.whitespaces\)\.isEmpty \{ return false \}"#))
    check("a folder group's fold is that folder's own",
          paneSource.components(separatedBy: #"prefix + "|folder:" + (folder?.path ?? "")"#).count - 1 == 2)
    let deleteBody = body(of: "func delete(_ row: SkillRow, from agent: String?, in folder: URL?)", in: paneSource)
    let shareBody = body(of: "func share(_ row: SkillRow, with agent: String, in folder: URL?)", in: paneSource)
    check("an action is for the folder its row was read in, and what cannot be done is said before the confirmation",
          paneSource.contains("let folder: URL?\n        let action: Action")
          && !shareBody.isEmpty && !deleteBody.isEmpty
          && shareBody.contains("catalog.reviewShare(row: row, with: agent, folder: folder)")
          && shareBody.contains("await catalog.refusal(of: review.plan, folder: folder)")
          && deleteBody.contains("await catalog.refusal(of: plan, folder: folder)")
          && body(of: "private func carryOut(_ pending: Pending)", in: paneSource).contains("let folder = pending.folder"))
    check("…every action of a row's menu is for the row's own folder — a subfolder's for a skill drawn under one",
          skillRow.contains("let folder: URL?")
          && ["pane.fix(row, for: agent, in: folder)", "pane.edit(row, in: folder)",
              "pane.setState(row, agent: agent, state: value, in: folder)", "pane.scopeName(for: folder)"]
            .allSatisfy(skillRow.contains)
          && groupHeader.contains("SkillsPaneRow(row: row, agent: agent, folder: group.folder")
          && body(of: "private func subfolderGroup(", in: paneSource).contains("folder: URL(fileURLWithPath: path, isDirectory: true)"))
    check("…a group cannot be made without the folder its rows act for",
          paneSource.contains("        let folder: URL?\n        /// What is drawn in the group's place")
          && !paneSource.contains("var folder: URL? = nil"))
    check("…and a subfolder's write reads the page's own folder again after it",
          body(of: "private func run(_ row: SkillRow", in: paneSource)
            .contains("if SkillCatalog.key(acted) != SkillCatalog.key(shown) {"))
    check("a failure line is not erased by another write that went through",
          body(of: "private func run(_ row: SkillRow", in: paneSource).contains("if let result { failure = result }"))
    check("a skill taken from an agent is no longer one its new sessions start with",
          body(of: "private func carryOut(_ pending: Pending)", in: paneSource)
            .components(separatedBy: "if failure == nil { unpin(row.name").count - 1 == 2)
    check("a link to nothing: its confirmation says only the link goes, and its menu offers no state and no file to open",
          paneSource.contains("\"Only the link is removed: the folder it pointed at is gone.\"")
          && skillRow.contains("if let agent, row.entries[agent] != nil, !row.problems.contains(.brokenLink) {")
          && has(skillRow, #"if row\.realPath != nil \{\s*Button\(String\(localized: "Open SKILL\.md""#))
    check("Share With is one click: refused with words when it cannot be done, never asked about",
          shareBody.contains("await catalog.share(row: row, with: agent, check: review.check, folder: folder) ?? lost")
          && !shareBody.contains("confirming = ")
          && !paneSource.contains("case share(SkillShareReview)")
          && !paneSource.contains("SipAI first moves its folder into its own library"))
    check("the Off item carries its scope: Claude's folder, Codex's every folder; the separate note is gone",
          paneSource.contains("stateItem(.off, agent: agent, title: offTitle(agent))")
          && paneSource.contains("\"Off (applies to \\(name))\"")
          && paneSource.contains("\"Off (applies to every folder)\"")
          && !paneSource.contains("scopeNote("))
    // A project whose root is the home folder saves Claude's switch where
    // Global's is saved; named by the folder, the item read "Off (applies
    // to <the account's name>)".
    check("…and a project rooted at the home folder is named \"your home folder\", never by the account's folder",
          paneSource.contains("if let name = pane.scopeName(for: folder), !pane.scopeIsHome(for: folder) {")
          && paneSource.contains("home: FileManager.default.homeDirectoryForCurrentUser)"))
    let someHome = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    let work = someHome.appendingPathComponent("work", isDirectory: true)
    check("…the rule: Global, the home folder itself and a folder whose project root is the home folder are the home scope",
          SkillsPane.scopeIsHome(folder: nil, projectRoot: nil, home: someHome)
          && SkillsPane.scopeIsHome(folder: someHome, projectRoot: nil, home: someHome)
          && SkillsPane.scopeIsHome(folder: work, projectRoot: someHome.path, home: someHome)
          && SkillsPane.scopeIsHome(folder: work, projectRoot: someHome.path + "/", home: someHome))
    check("…and a folder of its own, or one in a repository below the home folder, is not",
          !SkillsPane.scopeIsHome(folder: work, projectRoot: nil, home: someHome)
          && !SkillsPane.scopeIsHome(folder: work.appendingPathComponent("pkg"), projectRoot: work.path, home: someHome))
    check("an edit of a skill several agents use says, before the Save, that it changes it for all of them",
          sheetsSource.contains("if let sharedWith = sharedLine {")
          && sheetsSource.contains("use this skill. Saving changes it for each of them.")
          && sheetsSource.contains("let users = agentLabels.filter { row.entries[$0.0] != nil }.map(\\.1)"))
    // The one thing a share can change that nobody asked for: the skill's
    // "only when I call it", where SipAI cannot write it for the new agent.
    // With the confirmation gone, the page says it once the share is done.
    check("a share that could not carry Only When I Call It says so on the page, once it is done",
          shareBody.contains("let lost = review.check.lostOnlyWhenCalled")
          && shareBody.contains("“Only When I Call It” couldn’t be carried over"))
    check("the two only-when-called fixes are a share's alone: a Fix lists neither, and their sentences are gone",
          paneSource.contains("case .onlyWhenCalledForCodex, .onlyWhenCalledInSkill:")
          && !paneSource.contains("too uses it only when you call it")
          && !paneSource.contains("reads that line as well"))
    check("an agent that starts a session with ONE skill says which one a new pin replaces",
          skillRow.contains("Toggle(pane.defaultTitle(row, agent: agent),")
          && paneSource.contains("\"Start New Sessions With It (instead of “\\(current)”)\"")
          && body(of: "func defaultTitle(_ row: SkillRow, agent: String) -> String", in: paneSource)
            .contains("if SkillAgent.oneSkillPerMessage(agent),"))
    check("the confirmation names the agents the plan leaves the skill with",
          body(of: "private func confirmMessage(_ pending: Pending)", in: paneSource).contains("let keepers = plan.keeps"))
    check("Delete is offered only where there is something SipAI can take away",
          skillRow.contains("return row.isManaged || row.entries[agent]?.isLink == true") && skillRow.contains("if canDelete {"))
    check("the detail speaks for the agents the page lists",
          skillRow.contains("SkillDetailView(row: row, agents: pane.listedAgents, label: pane.label)"))
    check("the toolbar starts with the search box; the folder menu has a row of its own under it, flush left",
          !toolbar.contains("folderMenu") && toolbar.contains("SearchField(")
          && has(paneBody, #"toolbar\s*(//[^\n]*\s*)*HStack\(spacing: 0\) \{\s*folderMenu\s*Spacer\(minLength: 0\)\s*\}"#)
          && body(of: "private var folderMenu: some View {", in: paneSource).contains(".padding(.trailing, 8)"))
    check("the folder menu lists the folders browsed — Global first, Choose Folder… last — and every folder shown is one browsed",
          paneSource.contains("SkillFolderHistory.current(SkillFolderHistory.load(), now: Date(), exists: SkillFolderHistory.isFolder)")
          && paneSource.contains(".onAppear {\n            browsed = listedHistory()")
          && has(paneSource, #"\.onChange\(of: appState\.skillsFolder\) \{ _, next in\s*record\(next\)"#)
          && !paneSource.contains("out.count == 8"))
    check("…the menu's list is held: whether a folder is on disk is not asked as the page draws",
          { let menu = body(of: "private var recentFolders: [URL] {", in: paneSource)
            return !menu.isEmpty && !menu.contains("isFolder") && !menu.contains("SkillFolderHistory") }()
          && !body(of: "private var folderMenu: some View {", in: paneSource).contains("SkillFolderHistory"))
    check("a subfolder's skills are a group of their own, titled with where they are — by the level its walk made, no file-system call as the page draws",
          paneSource.contains("\"Subfolder · \\(name)\"")
          && paneSource.contains(".map { (level, SkillListing.rows($0.rows, at: level).filter(matches)) }")
          && paneSource.contains("SkillListing.rows(of: agent, in: own, at: level)")
          && paneSource.contains("SkillListing.unused(own, listed: listedAgents, at: level)")
          && !body(of: "private func sections(_ snapshot: SkillSnapshot) -> [PaneSection] {", in: paneSource).contains("SkillLevel(path:"))
    check("the page's subfolders are looked for again after a write and on Refresh, and their reads let go when it disappears",
          paneSource.contains(".onChange(of: catalog.revision) { _, _ in loadSubfolders(walk: true) }")
          && paneSource.contains("loadSubfolders(maxAge: 0, walk: true)")
          && body(of: ".onDisappear {", in: paneSource).contains("catalog.ensureLoaded(folders: [])"))
    check("the progress mark shows a subfolder's read waiting its turn as well as the one under way",
          body(of: "private var readingSubfolders: Bool {", in: paneSource).contains("catalog.waiting.contains(k)"))
    check("a walk that stopped early is said in words that hold with or without a skill left out",
          paneSource.contains("if below?.stoppedEarly == true {")
          && paneSource.contains("so one with skills may be missing")
          && !paneSource.contains("Not every subfolder with skills is shown"))
    check("an agent's own skills are titled Skills · the folder, Skills · Global with no folder",
          paneSource.contains("\"Skills · \\(place)\"")
          && paneSource.contains("Self.skillsTitle(Self.globalWord)")
          && paneSource.contains("Self.skillsTitle(folder?.lastPathComponent")
          && paneSource.contains("folder?.lastPathComponent ?? Self.globalWord")
          && !paneSource.contains("This folder ·") && !paneSource.contains("Global only"))

    try? FileManager.default.removeItem(at: scratch)
    print("\n\(passed)/\(passed + failed) checks passed")
    exit(failed == 0 ? 0 : 1)
}
