// main.swift — Verification/UpdatesPane
//
// Settings → Updates in a copy that may not update itself (built locally:
// `UpdaterAvailability` says `.notDistributionSigned`) must be the page a
// release copy shows — the same rows, the checkbox and Check Now greyed
// out, the reason on hover — and the app menu's Check for Updates… the
// same item, greyed, with the same reason, so whoever builds SipAI sees
// what its users see. A page that swaps the controls for a sentence, or a
// menu that drops the item, is one nobody who builds SipAI ever sees as
// its users do.
//
// Pass 1 (anywhere): the wiring, read out of the shipping sources — the
//   pane's hover is SwiftUI's own tracking, not an NSView tooltip, so it
//   is only reachable here — and the ONE hover sentence (extracted from
//   UpdateController.swift by run.sh) asked for each verdict. A copy with
//   no updater must never write Sparkle's settings, which every copy on
//   the Mac shares.
// Pass 2 (needs a window server): the app menu's REAL update command
//   (extracted from SipAIApp.swift into a menu-only probe app by run.sh)
//   read back off the menu item itself, both ways; then the REAL pane,
//   laid out in an offscreen window as a release copy and as a local
//   one, at Default and at Large text mode. Same size; the checkbox an
//   AppKit button, enabled in one and greyed in the other; nothing in
//   the local copy's SipAI rows takes keyboard focus; and the two
//   renders differ ONLY in the two control rows.
//
//   UPDATES_PANE_RENDER=<dir> writes the renders as PNGs.

import AppKit
import SwiftUI

let root = CommandLine.arguments[1]
let scratch = CommandLine.arguments[2]
let renderDir = ProcessInfo.processInfo.environment["UPDATES_PANE_RENDER"]

var passed = 0
var failed = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        passed += 1
        print("  PASS  \(label)")
    } else {
        failed += 1
        let d = detail()
        print("  FAIL  \(label)" + (d.isEmpty ? "" : "\n        → \(d)"))
    }
}

func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// The text between the first `from` and the next `to` after it.
func segment(_ s: String, from: String, to: String) -> String {
    guard let a = s.range(of: from),
          let b = s.range(of: to, range: a.upperBound..<s.endIndex) else { return "" }
    return String(s[a.lowerBound..<b.lowerBound])
}

// ---------- 1. the wiring ----------
print("1. The wiring, read out of the sources")

let settings = read(root + "/SipAI/Views/Settings/SettingsView.swift")
let pane = read(scratch + "/UpdatesPane.swift")          // as run.sh extracted it
let controller = read(root + "/SipAI/Models/UpdateController.swift")
let sentence = "This copy of SipAI was built locally and is not signed for distribution"

// Positive anchors first: a check that only FORBIDS passes on a file it
// could not read.
check("the pane and the controller were read",
      pane.contains("struct UpdatesPane: View") && controller.contains("final class UpdateController"))

check("the SipAI controls are drawn in every build — no allowsUpdates gate around them",
      !pane.contains("if updates.availability.allowsUpdates") && pane.contains("Check for updates automatically"))

let checkboxPart = segment(pane, from: "\"Check for updates automatically\"", to: "\"SipAI asks updates.sipai.dev")
check("the checkbox is greyed out, with the reason on hover, when the copy may not update itself",
      checkboxPart.contains(".disabled(!selfUpdating)") && checkboxPart.contains(".help(updates.notSelfUpdatingReason)"),
      checkboxPart.isEmpty ? "the checkbox was not found" : "missing .disabled(!selfUpdating) / .help(updates.notSelfUpdatingReason)")

let checkNowPart = segment(pane, from: "\"Check Now\"", to: "lastUpdateCheckDate")
check("Check Now is greyed out, with the reason on hover, when the copy may not update itself",
      checkNowPart.contains(".disabled(!selfUpdating") && checkNowPart.contains(".help(updates.notSelfUpdatingReason)"))

// The sentence lives once, on the controller; the page never draws it.
let reasonPart = segment(controller, from: "var notSelfUpdatingReason: String {", to: "\n    }")
check("the reason is spelled once, on the controller, and never drawn as text on the page",
      reasonPart.contains("String(localized: \"" + sentence)
        && !settings.contains(sentence) && !pane.contains(sentence))

// Asked of the REAL property (extracted onto the stub by run.sh).
MainActor.assumeIsolated {
    let probe = UpdateController()
    probe.availability = .enabled
    let release = probe.notSelfUpdatingReason
    probe.availability = .forcedForTesting
    let harness = probe.notSelfUpdatingReason
    probe.availability = .notDistributionSigned
    let local = probe.notSelfUpdatingReason
    check("a copy that updates itself shows no hover at all (release and harness builds alike)",
          release.isEmpty && harness.isEmpty, "release \"\(release)\", harness \"\(harness)\"")
    check("a copy that may not update itself says why on hover",
          local.hasPrefix(sentence), "got \"\(local)\"")
}

// The app menu: ONE item, built before any gate, greyed where the pane
// is, and carrying the pane's hover only where there is one — `.help("")`
// sets an empty tooltip on a menu item (measured), and a release copy's
// menu must not depend on how AppKit draws that.
let app = read(root + "/SipAI/SipAIApp.swift")
let menuPart = segment(app, from: "CommandGroup(after: .appInfo) {", to: "CommandGroup(after: .sidebar)")
let itemAt = menuPart.range(of: "\"Check for Updates…\"")
let gateAt = menuPart.range(of: "if updateController.availability.allowsUpdates")
check("the app menu's Check for Updates… is ONE item, built in every build before any gate",
      menuPart.components(separatedBy: "\"Check for Updates…\"").count == 2
        && itemAt != nil && gateAt != nil && itemAt!.lowerBound < gateAt!.lowerBound)
check("…greyed out where the copy may not update itself, with the reason on hover there and no tooltip otherwise",
      menuPart.contains(".disabled(!updateController.availability.allowsUpdates")
        && menuPart.components(separatedBy: ".help(").count == 2
        && menuPart.contains("item.help(updateController.notSelfUpdatingReason)"))

// A copy with no updater still reads the setting for its greyed-out
// checkbox — before any updater could exist, and only ever reads it.
let initPart = segment(controller, from: "override init() {", to: "restoreAvailableUpdate()")
let readsSetting = initPart.range(of: "UpdaterAvailability.automaticChecksSetting(")
let makesUpdater = initPart.range(of: "SPUStandardUpdaterController(")
check("a copy that may not update itself reads the setting and starts no updater",
      readsSetting != nil && makesUpdater != nil && readsSetting!.lowerBound < makesUpdater!.lowerBound)
// The one write of the setting goes through Sparkle's updater, which such
// a copy does not have; no line of the controller stores the key itself.
let writesKey = controller.split(separator: "\n").contains { line in
    !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        && (line.contains("SUEnableAutomaticChecks") || line.contains("automaticChecksKey"))
        && (line.contains(".set(") || line.contains("setValue(") || line.contains("setBool("))
}
check("…and writes none of Sparkle's settings (they are the installed copy's too)",
      !writesKey && controller.contains("controller?.updater.automaticallyChecksForUpdates = enabled"))

let launchPart = segment(controller, from: "func noteLaunch() {", to: "UpdateAnnouncer.shared.announce(")
check("\"just updated\" is judged against THIS copy's own record, keyed by where it lives",
      launchPart.contains("CopyLaunchRecord.note(") && launchPart.contains("Bundle.main.bundleURL")
        && !controller.contains("lastLaunchedBuildDefaultsKey"))

// ---------- 2. the page, rendered ----------

/// A window no screen shows: borderless, far off every display, never key.
@MainActor
func host<V: View>(_ view: V, width: CGFloat) -> (NSWindow, NSView) {
    let height = NSHostingView(rootView: view).fittingSize.height
    let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
    window.contentView = hosting
    window.orderFrontRegardless()
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    hosting.layoutSubtreeIfNeeded()
    return (window, hosting)
}

func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }

struct Rendered {
    let size: CGSize
    let checkboxes: [NSButton]
    /// SwiftUI's stand-ins in the key-view loop: one per control that can
    /// take keyboard focus.
    let focusable: Int
    let bitmap: NSBitmapImageRep?
}

enum Copy { case release, local, localChoseOff }

@MainActor
func render(_ copy: Copy, tier: FontTier, name: String) -> Rendered {
    let ctrl = UpdateController()
    switch copy {
    case .release:
        ctrl.availability = .enabled
        ctrl.canCheckForUpdates = true
        ctrl.automaticallyChecksForUpdates = true
        ctrl.lastUpdateCheckDate = Date(timeIntervalSince1970: 1_790_000_000)
    case .local, .localChoseOff:
        // What UpdateController.init hands such a copy, through the real
        // rule: the user's choice, else Info.plist's default (SipAI ships
        // it on). An ABSOLUTE-path suite, so nothing lands in
        // ~/Library/Preferences.
        let suite = UserDefaults(suiteName: scratch + "/defaults-\(name)")!
        if copy == .localChoseOff { suite.set(false, forKey: UpdaterAvailability.automaticChecksKey) }
        ctrl.availability = .notDistributionSigned
        ctrl.canCheckForUpdates = false
        ctrl.automaticallyChecksForUpdates = UpdaterAvailability.automaticChecksSetting(
            defaults: suite, infoDictionary: [UpdaterAvailability.automaticChecksKey: true])
    }
    let view = UpdatesPane()
        .environmentObject(ctrl)
        .environmentObject(ConfigManager())
        .environmentObject(AgentManager())
        .environment(\.sipFontScale, tier.scale)
        .environment(\.sipLineSpacingFactor, tier.lineSpacingFactor)
        .controlSize(SipFont.controlSize(tier.scale))
        .padding(16)
        .frame(width: 600, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    let (window, hosting) = host(view, width: 600)
    defer { window.orderOut(nil) }
    let views = all(hosting)
    let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
    if let rep {
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let dir = renderDir, let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir + "/updates-\(name).png"))
        }
    }
    return Rendered(size: hosting.frame.size,
                    checkboxes: views.compactMap { $0 as? NSButton },
                    focusable: views.filter { String(describing: type(of: $0)).contains("KeyViewProxy") }.count,
                    bitmap: rep)
}

/// Bands of consecutive pixel rows where two same-sized renders differ.
func differingBands(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> [ClosedRange<Int>] {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return [0...0] }
    var bands: [ClosedRange<Int>] = []
    var start: Int?
    for y in 0..<a.pixelsHigh {
        var differs = false
        for x in 0..<a.pixelsWide where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) {
            differs = true
            break
        }
        if differs, start == nil { start = y }
        if !differs, let s = start { bands.append(s...(y - 1)); start = nil }
    }
    if let s = start { bands.append(s...(a.pixelsHigh - 1)) }
    return bands
}

/// What the menu probe (run.sh) read back off the real menu item. The
/// tooltip is nil when the item has none, "" when it has an empty one.
func menuState(_ variant: String) -> (enabled: Bool?, tooltip: String?, raw: String) {
    let raw = read(scratch + "/menu-\(variant).txt")
    var enabled: Bool?
    var tooltip: String?
    for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("enabled=") { enabled = line.dropFirst("enabled=".count) == "true" }
        if line.hasPrefix("tooltip=") {
            let value = String(line.dropFirst("tooltip=".count))
            if value == "nil" {
                tooltip = nil
            } else if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                tooltip = String(value.dropFirst().dropLast())
            } else {
                tooltip = value
            }
        }
    }
    return (enabled, tooltip, raw)
}

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)

    print("2. The app menu's Check for Updates…, read off the menu item itself")
    let menuBuildFailure = read(scratch + "/menu-build-failed.txt")
    if !menuBuildFailure.isEmpty {
        check("the app menu's update command compiles in the probe", false,
              String(menuBuildFailure.prefix(600)))
    } else {
        let localMenu = menuState("local")
        let releaseMenu = menuState("release")
        if localMenu.raw.isEmpty && releaseMenu.raw.isEmpty {
            print("  NOTE  the menu probe printed nothing (no window server?) — pass 1 pins the menu's wiring")
        } else {
            check("the item is in the menu in both builds",
                  localMenu.enabled != nil && releaseMenu.enabled != nil,
                  "local: \(localMenu.raw.debugDescription), release: \(releaseMenu.raw.debugDescription)")
            check("a release copy's item is enabled, with NO tooltip — not even an empty one",
                  releaseMenu.enabled == true && releaseMenu.tooltip == nil,
                  "release: \(releaseMenu.raw.debugDescription)")
            check("a local build's item is greyed out, with the reason as its tooltip",
                  localMenu.enabled == false && (localMenu.tooltip ?? "").hasPrefix(sentence),
                  "local: \(localMenu.raw.debugDescription)")
        }
    }

    print("3. The page, rendered as a release copy and as a local build")

    for (tierName, tier) in [("default", FontTier.standard), ("large-text", FontTier.xlarge)] {
        let release = render(.release, tier: tier, name: "release-\(tierName)")
        let local = render(.local, tier: tier, name: "local-\(tierName)")

        check("[\(tierName)] the local build's page is the release page's size — the same rows",
              release.size == local.size && release.size.height > 0,
              "release \(release.size), local \(local.size)")

        let r = release.checkboxes, l = local.checkboxes
        check("[\(tierName)] the checkbox is there in both, enabled only in the release copy",
              r.count == 1 && l.count == 1 && r[0].isEnabled && !l[0].isEnabled,
              "release: \(r.map { "enabled=\($0.isEnabled)" }), local: \(l.map { "enabled=\($0.isEnabled)" })")
        check("[\(tierName)] it shows the setting a release copy on this Mac would (on, by default)",
              l.first?.state == .on && r.first?.state == .on)

        if release.focusable == 0 {
            print("  NOTE  [\(tierName)] SwiftUI put nothing in the key-view loop here — focusability not measurable on this macOS")
        } else {
            check("[\(tierName)] nothing in the local build's SipAI rows can be used (release: \(release.focusable) controls take focus)",
                  local.focusable == 0, "local: \(local.focusable)")
        }

        if let a = release.bitmap, let b = local.bitmap {
            let bands = differingBands(a, b)
            check("[\(tierName)] the two renders differ only in the two control rows (checkbox, Check Now)",
                  bands.count == 2, "differing pixel-row bands: \(bands)")
        } else {
            check("[\(tierName)] both renders captured", false)
        }
    }

    let off = render(.localChoseOff, tier: .standard, name: "local-chose-off")
    check("a user's OFF in the installed copy shows as unchecked in the local build",
          off.checkboxes.first?.state == .off && off.checkboxes.first?.isEnabled == false)

    print("")
    print(failed == 0 ? "All \(passed) checks passed." : "\(failed) of \(passed + failed) checks FAILED.")
    exit(failed == 0 ? 0 : 1)
}
