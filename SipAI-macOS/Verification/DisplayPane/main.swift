// Settings → Display — see run.sh for the four sections.
//
// Compiled with the REAL `AppTheme` (extracted from AppState.swift), the
// REAL `DisplayPane` and `DisplaySettings`, and MECH_APP or
// MECH_PREFERENCE, whichever the app's root uses; section 1 drives that
// one.

import AppKit
import SwiftUI

var failures = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok {
        print("  ok    \(name)")
    } else {
        failures += 1
        let more = detail()
        print("  FAIL  \(name)\(more.isEmpty ? "" : " — \(more)")")
    }
}

@main
struct DisplayPaneHarness {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let args = CommandLine.arguments
        switch args.count > 1 ? args[1] : "" {
        case "wiring" where args.count > 2:
            exit(wiring(root: args[2]))
        case "window":
            exit(MainActor.assumeIsolated { windowSections() })
        default:
            print("usage: display wiring <SipAI-macOS root> | display window")
            exit(2)
        }
    }
}

// MARK: - 3. The wiring, read off the real files

func source(_ root: String, _ path: String) -> String {
    (try? String(contentsOfFile: root + "/SipAI/" + path, encoding: .utf8)) ?? ""
}

/// The text with every `//` comment taken out, so prose that names a
/// modifier is not read as a use of it. A `//` after a colon (a URL) is
/// left alone.
func codeOnly(_ text: String) -> String {
    text.components(separatedBy: "\n").map { line -> String in
        guard let r = line.range(of: #"(^|\s)//.*$"#, options: .regularExpression) else { return line }
        return String(line[..<r.lowerBound])
    }.joined(separator: "\n")
}

/// The text from `anchor` to the end of its block (the matching brace), or
/// "" when the anchor is not there.
func block(after anchor: String, in text: String) -> String {
    guard let start = text.range(of: anchor) else { return "" }
    var depth = 0
    var opened = false
    var end = text.endIndex
    for i in text[start.upperBound...].indices {
        let c = text[i]
        if c == "{" { depth += 1; opened = true }
        if c == "}" {
            depth -= 1
            if opened && depth == 0 { end = text.index(after: i); break }
        }
    }
    return String(text[start.lowerBound..<end])
}

func wiring(root: String) -> Int32 {
    print("3. the wiring")
    let app = codeOnly(source(root, "SipAIApp.swift"))
    let follow = block(after: ".onChange(of: appState.theme, initial: true)", in: app)
    check(follow.contains("NSApp.appearance = theme.appearance"),
          "the window's root applies the theme to the whole application, on every change and the first",
          follow.isEmpty ? "no .onChange(of: appState.theme, initial: true) in SipAIApp.swift"
                         : "the closure does not set NSApp.appearance from the theme")
    check(app.contains("appState.theme = configManager.appTheme"),
          "the launch puts the saved choice into AppState.theme")

    // Every Swift file of the app, comments aside.
    var offenders: [String] = []
    let base = URL(fileURLWithPath: root + "/SipAI")
    if let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) {
        for case let url as URL in walk where url.pathExtension == "swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if codeOnly(text).contains(".preferredColorScheme(") {
                offenders.append(url.path.replacingOccurrences(of: base.path + "/", with: ""))
            }
        }
    }
    check(offenders.isEmpty,
          "nothing in the app sets SwiftUI's colour-scheme preference "
            + "(a sheet, an alert and a menu take the app's look)",
          offenders.sorted().joined(separator: ", "))

    let settings = codeOnly(source(root, "Views/Settings/SettingsView.swift"))
    let display = block(after: "struct DisplayPane: View {", in: settings)
    check(display.contains("get: { appState.theme }") && display.contains("appState.theme = t")
            && display.contains("config.setTheme(t)"),
          "the Display picker shows and moves AppState.theme, and saves the choice")
    check(codeOnly(source(root, "Models/FactoryReset.swift")).contains("appState.theme = .system"),
          "a factory reset puts AppState.theme back to System")

#if MECH_APP
    check(AppTheme.system.appearance == nil
            && AppTheme.light.appearance?.name == .aqua
            && AppTheme.dark.appearance?.name == .darkAqua,
          "System is no appearance of the app's own, Light is Aqua, Dark is Dark Aqua")
#else
    check(false, "AppTheme names the application's appearance for each choice",
          "AppTheme has no `appearance` — the theme is a SwiftUI preference on one window")
#endif
    print(failures == 0 ? "  wiring: OK" : "  wiring: \(failures) FAILED")
    return failures == 0 ? 0 : 1
}

// MARK: - 1 and 2. The look on screen

enum Look: String { case light, dark }

func look(_ appearance: NSAppearance) -> Look {
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
}

func look(_ scheme: ColorScheme?) -> Look? {
    switch scheme {
    case .light?: return .light
    case .dark?: return .dark
    default: return nil
    }
}

final class Holder: ObservableObject {
    @Published var theme: AppTheme = .system
}

final class ControlHolder: ObservableObject {
    @Published var scheme: ColorScheme? = nil
}

/// What the probes' views last read as their colour scheme.
final class Seen {
    var app: ColorScheme?
    var control: ColorScheme?
}
let seen = Seen()

/// The window background, which every surface of the app is drawn over,
/// and the colour scheme SwiftUI hands the view.
struct Swatch: View {
    let report: (ColorScheme) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .frame(width: 40, height: 40)
            .onChange(of: scheme, initial: true) { _, now in report(now) }
    }
}

/// What the app's window root does with the theme.
struct AppRoot: View {
    @ObservedObject var holder: Holder

    var body: some View {
#if MECH_APP
        Swatch { seen.app = $0 }
            .onChange(of: holder.theme, initial: true) { _, theme in
                NSApp.appearance = theme.appearance
            }
#else
        Swatch { seen.app = $0 }
            .preferredColorScheme(holder.theme.colorScheme)
#endif
    }
}

struct ControlRoot: View {
    @ObservedObject var holder: ControlHolder

    var body: some View {
        Swatch { seen.control = $0 }
            .preferredColorScheme(holder.scheme)
    }
}

@MainActor
func offscreen<V: View>(_ view: V, size: NSSize = NSSize(width: 40, height: 40)) -> (NSWindow, NSView) {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    window.orderFrontRegardless()
    return (window, host)
}

@MainActor
func pump(_ seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
func drawn(_ host: NSView) -> Look? {
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let c = rep.colorAt(x: Int(host.bounds.midX), y: Int(host.bounds.midY))?
        .usingColorSpace(.sRGB) else { return nil }
    return c.brightnessComponent > 0.5 ? .light : .dark
}

/// Waits up to a second and a half for the view to show `want` — long
/// enough for a busy Mac, and no help to a stale scheme, which no redraw
/// clears: it lasts until something such as the window losing focus makes
/// SwiftUI read the window's look again.
@MainActor
func settle(_ want: Look, scheme: () -> ColorScheme?, host: NSView) -> (scheme: Look?, drawn: Look?) {
    var last: (Look?, Look?) = (nil, nil)
    let deadline = Date().addingTimeInterval(1.5)
    repeat {
        pump(0.05)
        last = (look(scheme()), drawn(host))
        if last.0 == want && last.1 == want { break }
    } while Date() < deadline
    return last
}

func name(_ theme: AppTheme) -> String {
    switch theme {
    case .system: return "System"
    case .light: return "Light"
    case .dark: return "Dark"
    }
}

@MainActor
func windowSections() -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    NSApp.appearance = nil
    let mac = look(NSApp.effectiveAppearance)
    let other: Look = mac == .dark ? .light : .dark

#if MECH_APP
    print("1. the look on screen — the app-wide appearance (this Mac is \(mac.rawValue))")
#else
    print("1. the look on screen — SwiftUI's colour-scheme preference on the root (this Mac is \(mac.rawValue))")
#endif
    let holder = Holder()
    let (window, host) = offscreen(AppRoot(holder: holder))
    // A window of the app's own that nothing gives a look, as an alert run
    // on its own, a file panel and Sparkle's windows are; and a menu.
    let alert = NSAlert()
    let menu = NSMenu()
    pump(0.4)
    let start = settle(mac, scheme: { seen.app }, host: host)
    check(start.scheme == mac && start.drawn == mac, "System at the start draws the Mac's own look",
          "colour scheme \(start.scheme?.rawValue ?? "none"), drawn \(start.drawn?.rawValue ?? "nothing")")

    var from = AppTheme.system
    let steps: [AppTheme] = [.light, .system, .dark, .system, .light, .dark, .light, .system]
    for theme in steps {
        holder.theme = theme
        let want: Look = theme == .light ? .light : theme == .dark ? .dark : mac
        let got = settle(want, scheme: { seen.app }, host: host)
        check(got.scheme == want && got.drawn == want,
              "\(name(from)) → \(name(theme)): the view draws \(want.rawValue)",
              "colour scheme \(got.scheme?.rawValue ?? "none"), drawn \(got.drawn?.rawValue ?? "nothing"), "
              + "while its window is \(look(window.effectiveAppearance).rawValue)")
        if theme != .system {
            // A window that has never been on screen takes the app's look a
            // moment after the view does; one that does not follow never
            // takes it, however long it is given.
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline,
                  look(alert.window.effectiveAppearance) != want || look(menu.effectiveAppearance) != want {
                pump(0.05)
            }
            check(look(alert.window.effectiveAppearance) == want && look(menu.effectiveAppearance) == want,
                  "\(name(from)) → \(name(theme)): an alert window of the app's own "
                    + "and a menu are \(want.rawValue) too",
                  "alert window \(look(alert.window.effectiveAppearance).rawValue), "
                  + "menu \(look(menu.effectiveAppearance).rawValue)")
        }
        from = theme
    }
    window.orderOut(nil)
    holder.theme = .system
    NSApp.appearance = nil
    pump(0.2)

    print("2. the control: SwiftUI's .preferredColorScheme set back to nil")
    let control = ControlHolder()
    let (controlWindow, controlHost) = offscreen(ControlRoot(holder: control))
    pump(0.4)
    control.scheme = other == .light ? .light : .dark
    _ = settle(other, scheme: { seen.control }, host: controlHost)
    control.scheme = nil
    let back = settle(mac, scheme: { seen.control }, host: controlHost)
    if back.scheme != mac || back.drawn != mac {
        print("  ok    the hazard stands: back to nil, the view stays "
              + "\(back.scheme?.rawValue ?? "none") (drawn \(back.drawn?.rawValue ?? "nothing")) "
              + "while its window is \(look(controlWindow.effectiveAppearance).rawValue)")
    } else {
        print("  NOTE  SwiftUI now gives the view the Mac's look back after .preferredColorScheme(nil) —"
              + " the hazard AppTheme's comment names may be gone on this macOS")
    }
    controlWindow.orderOut(nil)

    namesSection()

    print(failures == 0 ? "  window: OK" : "  window: \(failures) FAILED")
    return failures == 0 ? 0 : 1
}

// MARK: - 4. The names the Display page's controls give VoiceOver

struct AXEntry {
    let role: String
    let label: String
    let value: String
}

/// The page's accessibility tree, in reading order.
@MainActor
func axEntries(_ root: NSView) -> [AXEntry] {
    var entries: [AXEntry] = []
    func walk(_ element: Any) {
        guard let node = element as? NSObject else { return }
        entries.append(AXEntry(role: (node.value(forKey: "accessibilityRole") as? String) ?? "",
                               label: (node.value(forKey: "accessibilityLabel") as? String) ?? "",
                               value: (node.value(forKey: "accessibilityValue") as? String) ?? ""))
        for child in (node.value(forKey: "accessibilityChildren") as? [Any]) ?? [] { walk(child) }
    }
    for child in root.accessibilityChildren() ?? [] { walk(child) }
    return entries
}

@MainActor
func namesSection() {
    print("4. the names the Display page's controls give VoiceOver")
    // A hosting view lists its controls only once an assistive client is
    // driving it.
    NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")
    let page = DisplayPane()
        .environmentObject(AppState())
        .environmentObject(ConfigManager())
    let (window, host) = offscreen(page, size: NSSize(width: 640, height: 1400))
    _ = host.accessibilityChildren()
    pump(0.6)
    var entries = axEntries(host)
    if !entries.contains(where: { $0.role == "AXCheckBox" }) {
        pump(1.0)
        entries = axEntries(host)
    }

    // Each control against the words drawn just before it: a switch's own
    // row, a picker's header.
    var drawn = ""
    var switches: [(drawn: String, name: String)] = []
    var pickers: [(drawn: String, name: String)] = []
    for entry in entries {
        switch entry.role {
        case "AXStaticText": drawn = entry.value
        case "AXCheckBox": switches.append((drawn, entry.label))
        case "AXRadioGroup": pickers.append((drawn, entry.label))
        default: break
        }
    }
    func describe(_ rows: [(drawn: String, name: String)]) -> String {
        rows.map { "“\($0.drawn)” → \($0.name.isEmpty ? "no name" : "“\($0.name)”")" }
            .joined(separator: "; ")
    }
    let unnamed = switches.filter { $0.name.isEmpty || $0.name != $0.drawn }
    check(switches.count >= 10, "the page's switches are in the accessibility tree", "\(switches.count) found")
    check(unnamed.isEmpty,
          "every switch is named with the words beside it (\(switches.count - unnamed.count) of \(switches.count))",
          describe(unnamed))
    check(pickers.count == 2 && pickers.allSatisfy { !$0.name.isEmpty && $0.name == $0.drawn },
          "both pickers, Appearance and Zoom, are named with the header above them",
          describe(pickers))
    window.orderOut(nil)
}
