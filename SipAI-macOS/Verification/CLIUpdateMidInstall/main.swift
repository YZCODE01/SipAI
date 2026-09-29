// A command-line tool must stay on screen while SipAI updates it, and
// the update that lands must be said where the user can see it.
//
// Two failures, reported together and both measured on the reporting
// Mac with an npm-installed Codex:
//
//   * Pressing Update made the tool VANISH — its row in Settings →
//     Updates, and the Cancel on it, and its sidebar section — for as
//     long as the update ran, then come back. npm's reify moves the
//     tool's link aside for the whole download (its log: "reify moves
//     … '/opt/homebrew/bin/codex': '/opt/homebrew/bin/.codex-2dE5FEfu'";
//     the 238 MB platform binary took 215 s), and "installed" meant an
//     executable file where the tool should be. The row came back only
//     at the next re-stat — up to a minute after the update had ended.
//   * "Codex just updated to …" never appeared beside the logo. The
//     monitor DID announce it — the replay below says so. The announcer
//     held it because a sheet was up, and every manual update is run
//     from Settings: a centred sheet some 720 pt wide that, on the
//     reporting 2560 pt window with a 440 pt sidebar, left the logo in
//     plain view the whole time. The line played later, once, wherever
//     the user was looking after closing Settings.
//
// The replay drives the REAL monitor, extracted whole from
// AgentCLIUpdates.swift by run.sh, through an npm-shaped update: a
// "codex" whose `update` hands off to a helper that retires the link,
// "downloads", and links the new binary — the order npm was logged
// doing it. The sheet test measures the REAL `UpdateAnnouncer
// .sheetCovers` on windows that are never ordered in, so nothing is
// drawn; `SIPAI_UPDMID_GUI=1` adds a pass over a real SwiftUI sheet.
//
// Nothing here is part of the app target: this directory sits outside
// SipAI/, so these files are never compiled into the product.
//
//   ./run.sh [source-root]

import AppKit
import Combine
import Foundation
import SwiftUI

var failures = 0
func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    print(cond ? "  ok   \(label)" : "  FAIL \(label) \(detail)")
    if !cond { failures += 1 }
}

let sourceRoot = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

func source(_ relative: String) -> String {
    (try? String(contentsOfFile: sourceRoot + "/" + relative, encoding: .utf8)) ?? ""
}

/// The text of `name`'s body: from its signature to the next line that
/// closes a declaration at its own indentation.
func body(of signature: String, in text: String) -> String {
    guard let start = text.range(of: signature) else { return "" }
    let lineStart = text[..<start.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) }
        ?? text.startIndex
    let indent = String(text[lineStart..<start.lowerBound].prefix { $0 == " " })
    let rest = text[start.lowerBound...]
    guard let end = rest.range(of: "\n" + indent + "}\n") else { return String(rest) }
    return String(rest[..<end.upperBound])
}

// MARK: - 1. The rule

print("countsAsInstalled — the binary, or SipAI's own update of it")

check("binary on disk → installed",
      AgentCLIUpdateRules.countsAsInstalled(binaryFound: true, updating: false))
check("binary missing while SipAI updates it → still installed",
      AgentCLIUpdateRules.countsAsInstalled(binaryFound: false, updating: true))
check("binary missing and no update → not installed (an uninstall is an uninstall)",
      !AgentCLIUpdateRules.countsAsInstalled(binaryFound: false, updating: false))
check("binary on disk mid-update → installed",
      AgentCLIUpdateRules.countsAsInstalled(binaryFound: true, updating: true))

// MARK: - 2. Does a sheet hide the logo?

print("sheetCovers — the lockup's own frame against the sheets on its window")

// Never ordered in, so nothing is drawn: the window reports its sheets
// through the overrides, and only the geometry is under test.
final class StandInSheet: NSWindow {
    var shown = true
    override var isVisible: Bool { shown }
}
final class StandInHost: NSWindow {
    var attached: [NSWindow] = []
    override var sheets: [NSWindow] { attached }
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

/// A window of `width` with a lockup where the sidebar draws it, and
/// Settings attached the way AppKit attaches it: centred, 720 pt wide,
/// from under the title bar down.
func host(width: CGFloat, sheet: Bool = true, sheetVisible: Bool = true)
    -> (StandInHost, NSView) {
    let h = StandInHost(contentRect: NSRect(x: 100, y: 100, width: width, height: 700),
                        styleMask: [.titled], backing: .buffered, defer: true)
    h.isReleasedWhenClosed = false
    let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
    h.contentView = content
    // 14 from the leading edge, under the toolbar row: where the
    // sidebar's lockup sits, logo and wordmark.
    let lockup = NSView(frame: NSRect(x: 14, y: 700 - 90, width: 250, height: 60))
    content.addSubview(lockup)
    if sheet {
        let s = StandInSheet(contentRect: .zero, styleMask: [.titled],
                             backing: .buffered, defer: true)
        s.isReleasedWhenClosed = false
        let frame = h.frame
        s.setFrame(NSRect(x: frame.midX - 360, y: frame.maxY - 28 - 540,
                          width: 720, height: 540), display: false)
        s.shown = sheetVisible
        h.attached = [s]
    }
    return (h, lockup)
}

let (wideHost, wideLockup) = host(width: 1400)
let (narrowHost, narrowLockup) = host(width: 900)
let (edgeHost, edgeLockup) = host(width: 1150)
let (bareHost, bareLockup) = host(width: 1400, sheet: false)
let (arrivingHost, arrivingLockup) = host(width: 1400, sheetVisible: false)
check("a wide window: Settings sits clear of the logo → not covered",
      !UpdateAnnouncer.sheetCovers(wideLockup))
check("a narrow window: Settings lies over the logo → covered",
      UpdateAnnouncer.sheetCovers(narrowLockup))
check("a sheet over any part of the line's area → covered",
      UpdateAnnouncer.sheetCovers(edgeLockup))
check("reported up but not attached yet → counts as covered (the old rule, the safe side)",
      UpdateAnnouncer.sheetCovers(bareLockup) && UpdateAnnouncer.sheetCovers(arrivingLockup))
check("a lockup in no window cannot be seen → covered",
      UpdateAnnouncer.sheetCovers(NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))))
_ = (wideHost, narrowHost, edgeHost, bareHost, arrivingHost)

// MARK: - 3. The line, with Settings up

print("UpdateAnnouncer — a sheet holds a line only while it hides the logo")

do {
    let open = UpdateAnnouncer(duration: 0.2)
    open.setAppActive(true)
    open.sheetCoversLockup = { UpdateAnnouncer.sheetCovers(wideLockup) }
    open.setSheetPresented(true)
    open.announce("Codex just updated to 0.157.1")
    check("Settings up, the logo in view: the line shows when the update lands",
          open.current?.text == "Codex just updated to 0.157.1")

    let hidden = UpdateAnnouncer(duration: 0.2)
    hidden.setAppActive(true)
    hidden.sheetCoversLockup = { UpdateAnnouncer.sheetCovers(narrowLockup) }
    hidden.setSheetPresented(true)
    hidden.announce("Codex just updated to 0.157.1")
    check("Settings up over the logo: the line waits", hidden.current == nil)
    hidden.setSheetPresented(false)
    check("…and shows the moment Settings closes",
          hidden.current?.text == "Codex just updated to 0.157.1")

    let unknown = UpdateAnnouncer(duration: 0.2)
    unknown.setAppActive(true)
    unknown.setSheetPresented(true)
    unknown.announce("Codex just updated to 0.157.1")
    check("with no lockup to ask, a sheet still holds the line", unknown.current == nil)
}

// MARK: - 4. The replay

print("an npm-shaped update through the real monitor, Settings up, the logo in view")

URLProtocol.registerClass(FakeRegistry.self)
let fm = FileManager.default
let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sipai-updmid-\(getpid())", isDirectory: true)
let bin = scratch.appendingPathComponent("bin", isDirectory: true)
try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
AgentManager.binDir = bin.path
let codexPath = bin.appendingPathComponent("codex").path
let lingerPidFile = scratch.appendingPathComponent("lingering.pid").path

/// What the npm-like helper does with the SIGTERM a Cancel sends to the
/// updater's whole process group (`Process.terminate()` signals the
/// group: measured, a grandchild dies with `terminate()` and survives a
/// pid-only `kill`).
enum OnStop {
    /// npm's own answer (arborist's `signal-handling.js` + `reify.js`,
    /// read in npm 10.9's source): note the signal, let the step in
    /// flight — the download — run to its end, then ROLL BACK, putting
    /// the retired link back. The "download" is a subshell that ignores
    /// TERM, as npm's in-process fetch does.
    case rollback
    /// A helper the signal simply kills: nothing puts the tool back.
    case die
    /// Installs normally, and leaves a process of its group running
    /// afterwards, holding the pipe — as an updater that spawns a
    /// long-lived helper would.
    case linger
}

/// A "codex" at `version`, whose `update` runs a helper the way `codex
/// update` runs `npm install -g`: retire the link, take `gap` seconds,
/// link a binary at `target`, then say so.
func installFakeCodex(version: String, gap: Double, target: String,
                      onStop: OnStop = .rollback) {
    let helper = scratch.appendingPathComponent("npm-helper.sh").path
    try? """
    #!/bin/sh
    case "$1" in
      --version) echo "codex-cli \(version)" ;;
      update) echo "Updating Codex via npm install -g @openai/codex..."
              "\(helper)"; rc=$?
              [ $rc -eq 0 ] && echo "Update ran successfully! Please restart Codex."
              exit $rc ;;
    esac
    """.write(toFile: codexPath, atomically: true, encoding: .utf8)
    let download: String
    switch onStop {
    case .rollback:
        download = """
        terminated=0
        trap 'terminated=1' TERM
        mv "\(codexPath)" "\(bin.path)/.codex-retired"
        ( trap '' TERM; sleep \(gap) )
        if [ $terminated -eq 1 ]; then
          mv "\(bin.path)/.codex-retired" "\(codexPath)"
          exit 143
        fi
        """
    case .die, .linger:
        download = """
        mv "\(codexPath)" "\(bin.path)/.codex-retired"
        sleep \(gap)
        """
    }
    let linger = onStop == .linger
        ? "sleep 30 &\necho $! > \"\(lingerPidFile)\"\n" : ""
    try? """
    #!/bin/sh
    \(download)
    printf '#!/bin/sh\\n[ "$1" = "--version" ] && echo "codex-cli \(target)"\\n' > "\(bin.path)/.codex-new"
    chmod +x "\(bin.path)/.codex-new"
    mv "\(bin.path)/.codex-new" "\(codexPath)"
    rm -f "\(bin.path)/.codex-retired"
    \(linger)echo "changed 1 package"
    """.write(toFile: helper, atomically: true, encoding: .utf8)
    chmod(codexPath, 0o755)
    chmod(helper, 0o755)
}

@MainActor
func waitFor(_ seconds: Double, _ done: @MainActor () -> Bool) async -> Bool {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until {
        if done() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return done()
}

let monitor = AgentCLIUpdateMonitor.shared
let announcer = UpdateAnnouncer.shared
announcer.setAppActive(true)
announcer.sheetCoversLockup = { UpdateAnnouncer.sheetCovers(wideLockup) }
announcer.setSheetPresented(true)
var lines: [String] = []
let lineWatch = announcer.$current.sink { if let line = $0 { lines.append(line.text) } }

@MainActor
func hasRow(_ key: String) -> Bool { monitor.installedAgents.contains { $0.key == key } }

@MainActor
func isBehind(_ key: String) -> Bool {
    if case .updateAvailable = monitor.statuses[key] { return true }
    return false
}

installFakeCodex(version: "0.150.0", gap: 2, target: "0.157.1")
monitor.start(config: ConfigManager(), agents: AgentManager())
let behindSeen = await waitFor(5) { isBehind("codex") }
check("before: the row offers the update", behindSeen,
      "\(String(describing: monitor.statuses["codex"]))")
let reloadsBefore = CodexCatalog.shared.reloads

monitor.startUpdate(agentKey: "codex")
check("pressed: the row is updating", monitor.statuses["codex"] == .updating)
let retired = await waitFor(3) { AgentManager.binaryPath(for: "codex") == nil }
check("mid-update the binary really is missing (the hazard is live)", retired)
// The re-stat that runs every minute, on app activation and when the
// Updates pane appears — any of them can land in the download.
await monitor.refreshLocal()
check("a re-stat mid-download keeps the row", hasRow("codex"))
check("…still updating, so its Cancel stays reachable",
      monitor.statuses["codex"] == .updating)
check("…with the version it had, not a blank",
      monitor.installed["codex"]?.text == "0.150.0")
check("…and no catalog relearned from a binary that is not there",
      CodexCatalog.shared.reloads == reloadsBefore)
check("the tool counts as installed for the sidebar too",
      AgentCLIUpdateRules.countsAsInstalled(
        binaryFound: AgentManager.binaryPath(for: "codex") != nil,
        updating: monitor.isUpdating("codex")))

let finished = await waitFor(20) { !monitor.isUpdating("codex") }
check("the update finishes", finished)
check("finished: the row is there at once — no re-stat needed", hasRow("codex"))
if case .upToDate(let installed, _) = monitor.statuses["codex"] {
    check("…saying up to date at the new version", installed.text == "0.157.1")
} else {
    check("…saying up to date at the new version", false,
          "\(String(describing: monitor.statuses["codex"]))")
}
check("the catalogs relearned once, for the binary that landed",
      CodexCatalog.shared.reloads == reloadsBefore + 1)
check("the line beside the logo showed while Settings was up",
      lines == ["Codex just updated to 0.157.1"], "\(lines)")
await monitor.refreshLocal()
check("the next re-stat changes nothing: no second relearn, no second line",
      CodexCatalog.shared.reloads == reloadsBefore + 1
        && lines == ["Codex just updated to 0.157.1"], "\(lines)")

// MARK: - 4b. Claude Code's own updater, from Settings

print("a Claude-shaped update — a new versions file, the link swapped in one step")

// Claude's native layout: the command is a link into …/claude/versions/,
// whose file NAME is the version (the monitor reads it without a spawn).
// `claude update` writes the new version beside the old and repoints the
// link with one rename — so, unlike npm, the command is never missing.
let versions = scratch.appendingPathComponent("share/claude/versions", isDirectory: true)
try? fm.createDirectory(at: versions, withIntermediateDirectories: true)
let claudeOld = versions.appendingPathComponent("2.1.281").path
let claudeNew = versions.appendingPathComponent("2.1.283").path
let claudeLink = bin.appendingPathComponent("claude").path
try? """
#!/bin/sh
case "$1" in
  --version) echo "2.1.281 (Claude Code)" ;;
  update) echo "Current version: 2.1.281"
          echo "Checking for updates to latest version..."
          sleep 2
          printf '#!/bin/sh\\n[ "$1" = "--version" ] && echo "2.1.283 (Claude Code)"\\n' > "\(claudeNew).part"
          chmod +x "\(claudeNew).part"
          mv "\(claudeNew).part" "\(claudeNew)"
          ln -s "\(claudeNew)" "\(bin.path)/.claude-next"
          mv -f "\(bin.path)/.claude-next" "\(claudeLink)"
          echo "Successfully updated from 2.1.281 to version 2.1.283" ;;
esac
""".write(toFile: claudeOld, atomically: true, encoding: .utf8)
chmod(claudeOld, 0o755)
try? fm.createSymbolicLink(atPath: claudeLink, withDestinationPath: claudeOld)

await monitor.refreshLocal()
let claudeBehind = await waitFor(5) { isBehind("claude_code") }
check("before: Claude Code's row offers 2.1.283 over 2.1.281", claudeBehind
        && monitor.installed["claude_code"]?.text == "2.1.281",
      "\(String(describing: monitor.statuses["claude_code"]))")
let claudeReloadsBefore = ClaudeCapabilities.shared.reloads
let linesBeforeClaude = lines.count

monitor.startUpdate(agentKey: "claude_code")
try? await Task.sleep(nanoseconds: 1_000_000_000)
await monitor.refreshLocal()
check("mid-update its command is never missing, and its row stays",
      AgentManager.binaryPath(for: "claude_code") != nil && hasRow("claude_code")
        && monitor.statuses["claude_code"] == .updating)
let claudeDone = await waitFor(15) { !monitor.isUpdating("claude_code") }
check("the update finishes", claudeDone)
if case .upToDate(let installed, _) = monitor.statuses["claude_code"] {
    check("…up to date at the new version, read off the link",
          installed.text == "2.1.283")
} else {
    check("…up to date at the new version, read off the link", false,
          "\(String(describing: monitor.statuses["claude_code"]))")
}
check("claude's catalogs relearned once", ClaudeCapabilities.shared.reloads == claudeReloadsBefore + 1)
let claudeLineShown = await waitFor(8) { lines.count > linesBeforeClaude }
check("\"Claude Code just updated to 2.1.283\" showed while Settings was up",
      claudeLineShown && lines.last == "Claude Code just updated to 2.1.283", "\(lines)")

// MARK: - 5. An update stopped half way

print("Cancel during npm's download: the update ends when the tool is back")

// Behind again, by a downgrade the re-stat notices (a move downward is
// relearned but not announced).
installFakeCodex(version: "0.150.0", gap: 8, target: "0.157.1", onStop: .rollback)
await monitor.refreshLocal()
let behindAgain = await waitFor(5) { isBehind("codex") }
check("behind again", behindAgain, "\(String(describing: monitor.statuses["codex"]))")
let linesBeforeCancel = lines.count
try? await Task.sleep(nanoseconds: 100_000_000)
check("…and a version going DOWN is not announced", lines.count == linesBeforeCancel, "\(lines)")

monitor.startUpdate(agentKey: "codex")
_ = await waitFor(3) { AgentManager.binaryPath(for: "codex") == nil }
try? await Task.sleep(nanoseconds: 300_000_000)
monitor.cancelUpdate(agentKey: "codex")
// The updater dies at once; the helper, like npm, finishes its download
// before rolling back. Past the drain's orphan grace (2 s) the updater
// is long gone — and the update must still be open.
var rowEverMissing = false
let sampleUntil = Date().addingTimeInterval(4.5)
while Date() < sampleUntil {
    if !hasRow("codex") { rowEverMissing = true }
    try? await Task.sleep(nanoseconds: 100_000_000)
}
check("4.5 s after Cancel, with npm still downloading, the update is still open",
      monitor.isUpdating("codex") && AgentManager.binaryPath(for: "codex") == nil,
      "updating: \(monitor.isUpdating("codex"))")
check("…the row says Cancelling…, with its spinner",
      monitor.statuses["codex"] == .updating && monitor.cancelling.contains("codex"))
check("…and the tool stays installed for the sidebar",
      AgentCLIUpdateRules.countsAsInstalled(
        binaryFound: AgentManager.binaryPath(for: "codex") != nil,
        updating: monitor.isUpdating("codex")))
let rolledBack = await waitFor(15) {
    if !hasRow("codex") { rowEverMissing = true }
    return !monitor.isUpdating("codex")
}
check("the update ends once npm has put the old tool back",
      rolledBack && AgentManager.binaryPath(for: "codex") != nil)
check("…and the row never went away, from the press to the end", !rowEverMissing)
check("…back on the old version, still offering the update, Cancelling… cleared",
      monitor.installed["codex"]?.text == "0.150.0" && isBehind("codex")
        && !monitor.cancelling.contains("codex"),
      "\(String(describing: monitor.statuses["codex"]))")
check("…and a rollback is not an update: nothing announced",
      lines.count == linesBeforeCancel, "\(lines)")

print("an updater whose whole group dies without restoring: the tool is gone")

installFakeCodex(version: "0.150.0", gap: 8, target: "0.157.1", onStop: .die)
await monitor.refreshLocal()
_ = await waitFor(5) { isBehind("codex") }
monitor.startUpdate(agentKey: "codex")
_ = await waitFor(3) { AgentManager.binaryPath(for: "codex") == nil }
try? await Task.sleep(nanoseconds: 300_000_000)
let diedAt = Date()
monitor.cancelUpdate(agentKey: "codex")
let diedEnded = await waitFor(12) { !monitor.isUpdating("codex") }
let diedTook = Date().timeIntervalSince(diedAt)
check("with nothing left to restore it, the update ends at once",
      diedEnded && diedTook < 6, String(format: "took %.1f s", diedTook))
check("…the tool is really gone, and so is its row — no phantom",
      AgentManager.binaryPath(for: "codex") == nil && !hasRow("codex"))
check("…and nothing is announced", lines.count == linesBeforeCancel, "\(lines)")
installFakeCodex(version: "0.150.0", gap: 1, target: "0.157.1")
await monitor.refreshLocal()
check("a reinstall brings the row back", hasRow("codex") && isBehind("codex"))

print("an updater that leaves a helper running: the tool back ends the wait")

installFakeCodex(version: "0.150.0", gap: 1, target: "0.157.1", onStop: .linger)
await monitor.refreshLocal()
let lingerStart = Date()
monitor.startUpdate(agentKey: "codex")
let lingerEnded = await waitFor(15) { !monitor.isUpdating("codex") }
let lingerTook = Date().timeIntervalSince(lingerStart)
check("a present binary ends the update though a helper of its group lives on",
      lingerEnded && lingerTook < 8, String(format: "took %.1f s", lingerTook))
if case .upToDate(let installed, _) = monitor.statuses["codex"] {
    check("…and the update is reported as landed", installed.text == "0.157.1")
} else {
    check("…and the update is reported as landed", false,
          "\(String(describing: monitor.statuses["codex"]))")
}
if let pidText = try? String(contentsOfFile: lingerPidFile, encoding: .utf8),
   let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) {
    kill(pid, SIGKILL)
}
lineWatch.cancel()

// MARK: - 6. A real SwiftUI sheet (opt in: two windows flash on screen)

/// SwiftUI presents the sheet from the run loop, which top-level async
/// code does not turn; a synchronous turn of it, in steps.
@MainActor
func pumpRunLoop(_ seconds: Double) {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}

if ProcessInfo.processInfo.environment["SIPAI_UPDMID_GUI"] == "1" {
    print("live — SwiftUI's .sheet lands in NSWindow.sheets, where sheetCovers looks")
    final class Marker: NSView {}
    struct Probe: NSViewRepresentable {
        let found: (NSView) -> Void
        func makeNSView(context: Context) -> Marker { let v = Marker(); found(v); return v }
        func updateNSView(_ nsView: Marker, context: Context) {}
    }
    /// A 250 × 60 stand-in for the lockup at `alignment` in a window of
    /// `width` × 700, and Settings presented over it at 720 × 540.
    struct Page: View {
        let width: CGFloat
        let alignment: Alignment
        let found: (NSView) -> Void
        @State private var settings = false
        var body: some View {
            Text(verbatim: "SipAI")
                .frame(width: 250, height: 60, alignment: .leading)
                .background(Probe(found: found))
                .frame(width: width, height: 700, alignment: alignment)
                .sheet(isPresented: $settings) {
                    Text(verbatim: "Settings").frame(minWidth: 720, minHeight: 540)
                }
                .onAppear { settings = true }
        }
    }
    NSApp.setActivationPolicy(.accessory)
    NSApp.finishLaunching()
    /// Presents the page and answers the sheet's frame and the verdict.
    func present(width: CGFloat, alignment: Alignment) -> (NSRect?, Bool?) {
        var marker: NSView?
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Page(width: width, alignment: alignment,
                                                          found: { marker = $0 }))
        window.orderFrontRegardless()
        pumpRunLoop(1.5)
        let sheet = window.sheets.first { $0.isVisible }?.frame
        let verdict = marker.map(UpdateAnnouncer.sheetCovers)
        for s in window.sheets { window.endSheet(s) }
        window.orderOut(nil)
        return (sheet, verdict)
    }
    // Placed at the window's vertical middle, the stand-in is under the
    // sheet wherever the OS attaches it — at the top, or centred as
    // macOS 26 does — so the verdicts hold on either.
    let (wideSheet, wideVerdict) = present(width: 1400, alignment: .leading)
    check("a real SwiftUI sheet is in window.sheets", wideSheet != nil)
    check("wide window: the sheet leaves the left edge clear → not covered", wideVerdict == false)
    let (narrowSheet, narrowVerdict) = present(width: 900, alignment: .leading)
    check("narrow window: the sheet lies over the left edge → covered",
          narrowSheet != nil && narrowVerdict == true,
          "sheet \(narrowSheet.map { "\($0)" } ?? "none")")
    // Where the sidebar really puts the logo — the top-left corner. For
    // the record only: whether a sheet reaches it depends on where the
    // OS hangs sheets (measured on macOS 26: centred in the window, so
    // the logo stays clear on a window taller than the sheet).
    let (topSheet, topVerdict) = present(width: 900, alignment: .topLeading)
    print("  info narrow window, lockup top-left (as in the sidebar): sheet \(topSheet.map { "\($0)" } ?? "none"), covered \(topVerdict.map { "\($0)" } ?? "?") — \(ProcessInfo.processInfo.operatingSystemVersionString)")
}

// MARK: - 7. Structural — the wiring a harness cannot run

print("structural")

let model = source("SipAI/Models/AgentCLIUpdates.swift")
let manager = source("SipAI/Models/AgentManager.swift")
let notices = source("SipAI/Models/UpdateNotices.swift")
let sidebar = source("SipAI/Views/Sidebar/LeftSidebar.swift")
let content = source("SipAI/Views/ContentView.swift")
check("the sources are where they are expected",
      !model.isEmpty && !manager.isEmpty && !notices.isEmpty && !sidebar.isEmpty && !content.isEmpty)

// ONE rule for the row and the section, or they disagree mid-update.
let reload = body(of: "func reload(config: ConfigManager) {", in: manager)
check("the sidebar's detection counts a tool SipAI is updating as installed",
      reload.contains("AgentCLIUpdateRules.countsAsInstalled(")
      && reload.contains("binaryFound: Self.isInstalled(agent.cmd)")
      && reload.contains("updating: updates.isUpdating(agent.key)"))
let rows = body(of: "private func refreshInstalledAgents() {", in: model)
check("the Updates rows use the same rule",
      rows.contains("AgentCLIUpdateRules.countsAsInstalled(")
      && rows.contains("updating: isUpdating($0.key))"))
let restat = body(of: "func refreshLocal() async {", in: model)
check("the re-stat leaves a tool alone while its binary is missing mid-update",
      restat.contains("if current == nil, isUpdating(key) { continue }"))
let finish = body(of: "private func finishUpdate(key: String,", in: model)
if let refresh = finish.range(of: "refreshInstalledAgents()"),
   let publish = finish.range(of: "publish()") {
    check("the update's end puts the rows back on the binary, before publishing",
          refresh.lowerBound < publish.lowerBound)
} else {
    check("the update's end puts the rows back on the binary, before publishing", false)
}

// A Cancel: the update stays open while npm puts the tool back.
let update = body(of: "func update(agentKey key: String) -> Bool {", in: model)
if let spawn = update.range(of: "await AgentCLIProbe.run("),
   let wait = update.range(of: "await awaitRestore(of: key, byGroup: result.processGroup,"),
   let reread = update.range(of: "let after = await readInstalledNow(key)") {
    check("after the updater exits, the update waits out its group, then reads the version",
          spawn.lowerBound < wait.lowerBound && wait.lowerBound < reread.lowerBound)
} else {
    check("after the updater exits, the update waits out its group, then reads the version", false)
}
check("…bounded by the update's own ceiling, counted from the spawn",
      update.contains("until: startedAt.addingTimeInterval(AgentCLIProbe.updateCeiling))"))
let restore = body(of: "private func awaitRestore(of key: String, byGroup group: pid_t?,", in: model)
check("the wait ends on a present binary or on a group with nobody left in it",
      restore.contains("if present || !AgentCLIProbe.groupIsAlive(group) { return }")
      && restore.contains("guard let group else { return }"))
check("…and never stats the binary on the MainActor",
      restore.contains("await Task.detached(priority: .utility) {"))
let probeRun = body(of: "nonisolated static func run(binary: String,", in: model)
if let spawned = probeRun.range(of: "try p.run()"),
   let group = probeRun.range(of: "let group = getpgid(p.processIdentifier)"),
   let handed = probeRun.range(of: "onSpawn(p)") {
    check("the group is read right after the spawn, before anyone can stop the child",
          spawned.lowerBound < group.lowerBound && group.lowerBound < handed.lowerBound)
} else {
    check("the group is read right after the spawn, before anyone can stop the child", false)
}
check("…and never SipAI's own group, which always has a member",
      probeRun.contains("processGroup: group > 1 && group != getpgrp() ? group : nil"))
check("a member test that signals nothing",
      model.contains("killpg(group, 0) == 0"))

// The line: held only by a sheet over the logo.
check("a sheet holds a line only while it covers the lockup",
      notices.contains("appActive && !(sheetPresented && sheetCoversLockup())"))
// Add Model is the window's one sheet. Settings is not a sheet: it is a
// mode of the main window that keeps the logo in view at the top of the
// sidebar, so nothing about it may hold a line.
check("the window says when a sheet is up",
      content.contains(".onChange(of: showingModelSetup) { _, showing in\n            UpdateAnnouncer.shared.setSheetPresented(showing)\n        }")
      && content.components(separatedBy: "setSheetPresented(").count == 2
      && content.range(of: #"showingSettings\b"#, options: .regularExpression) == nil)
check("…and no longer calls a sheet a covered window",
      !content.contains("setMainWindowCovered") && !notices.contains("setMainWindowCovered"))
check("the lockup installs the test over its own frame",
      sidebar.contains(".background(LockupSheetCheck())")
      && sidebar.contains("UpdateAnnouncer.shared.sheetCoversLockup = { [weak view] in")
      && sidebar.contains("view.map(UpdateAnnouncer.sheetCovers) ?? true"))
check("…through a view every click passes through",
      sidebar.contains("override func hitTest(_ point: NSPoint) -> NSView? { nil }"))
check("the test reads the window's own sheets",
      notices.contains("let sheets = window.sheets.filter(\\.isVisible)"))

// `exit` skips top-level `defer`s, so the scratch folder goes here.
try? fm.removeItem(at: scratch)
print(failures == 0 ? "CLIUpdateMidInstall: OK" : "CLIUpdateMidInstall: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
