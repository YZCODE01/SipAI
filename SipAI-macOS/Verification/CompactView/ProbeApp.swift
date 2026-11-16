// The process the CompactView checks run in. One app, because SwiftUI
// builds the View menu only under its App lifecycle; the window section
// shares it. Its window is never opened (`.suppressed`), and the app never
// activates.
//
// Nothing in this directory is part of the app target.
import SwiftUI
import AppKit

@main
struct CompactViewProbe: App {
    @NSApplicationDelegateAdaptor(ProbeDelegate.self) private var delegate
    @StateObject private var model = MenuSetting.shared

    var body: some Scene {
        WindowGroup { Color.clear.frame(width: 10, height: 10) }
            .defaultLaunchBehavior(.suppressed)
            .commands {
                CommandGroup(after: .sidebar) {
                    CompactViewMenuItem(setting: model)
                }
            }
    }
}

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // From a run-loop timer, never a main-queue block: the checks spin
        // the run loop while they wait.
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated {
                windowSection()
                menuSection()
                wiringSection()
                stringsSection()
                print("\n\(Report.checks - Report.failures)/\(Report.checks) passed")
                exit(Report.failures == 0 ? 0 : 1)
            }
        }
    }
}
