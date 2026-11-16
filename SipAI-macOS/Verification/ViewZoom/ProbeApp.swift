// GUI half of the ViewZoom checks: sections 3–5 (see run.sh). One app
// process, because SwiftUI builds the View menu only under its App
// lifecycle; the two offscreen sections share it. Its window is never
// opened (`.suppressed`), and the app never activates.
//
// Nothing in this directory is part of the app target.
import SwiftUI
import AppKit

@main
struct ViewZoomProbe: App {
    @NSApplicationDelegateAdaptor(ProbeDelegate.self) private var delegate
    @StateObject private var model = MenuModel.shared

    var body: some Scene {
        WindowGroup { Color.clear.frame(width: 10, height: 10) }
            .defaultLaunchBehavior(.suppressed)
            .commands {
                CommandGroup(after: .sidebar) {
                    ZoomMenuItems(setting: model)
                }
            }
    }
}

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ZoomKeys.install { step in MenuModel.shared.zoom(step) }
        // From a run-loop timer, never a main-queue block: the checks spin
        // the run loop while they wait, and a block on the main queue holds
        // it — nothing else queued there (a web page's load, its script
        // replies) would run until the checks gave up.
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated {
                menuSection()
                placeSection()
                noteSection()
                print("\nwindow: \(Report.passes) passed, \(Report.failures) failed")
                exit(Report.failures == 0 ? 0 : 1)
            }
        }
    }
}
