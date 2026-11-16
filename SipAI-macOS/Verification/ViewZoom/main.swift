// Headless half of the ViewZoom checks: sections 1, 1b and 2 (see run.sh).
// Nothing in this directory is part of the app target.
import Foundation

MainActor.assumeIsolated {
    rulesSection()
    emptyRowSection()
    wiringSection()
    print("\nheadless: \(Report.passes) passed, \(Report.failures) failed")
    exit(Report.failures == 0 ? 0 : 1)
}
