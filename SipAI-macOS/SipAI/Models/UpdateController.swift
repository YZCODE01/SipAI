// UpdateController.swift
// SipAI macOS — the Sparkle updater, and the one rule it has to respect.
//
// Sparkle owns the mechanics: the daily check against the appcast at
// `SUFeedURL`, the EdDSA signature check on whatever comes back, the
// download, the atomic bundle swap and the relaunch. What this file
// adds is the three decisions that are OURS:
//
//   1. WHETHER this copy may update itself at all
//      (`UpdaterAvailability` — a build someone made from the public
//      repo is theirs, not ours to overwrite).
//   2. That nothing is downloaded until the user says so, that no
//      system profile is ever sent, and that Sparkle's own first-run
//      "check automatically?" modal never fires — it would land on top
//      of onboarding, and Settings → Updates is the honest place to
//      ask.
//   3. That an update NEVER interrupts a running agent turn without
//      the user choosing that — and that the wait it takes instead is
//      VISIBLE and has a way out.
//
// (3) is the one that is specific to this app. Everywhere else SipAI
// goes out of its way not to SIGKILL an agent mid-turn —
// `applicationShouldTerminate` interrupts them deliberately and waits
// for the children to be reaped, `LanguagePane` warns before it
// relaunches. An updater that swapped the bundle and relaunched while
// `claude -p` was eight minutes into a task would undo all of that,
// and would do it at a moment the user did not choose.
//
// The wait is the trap, though, and it is Sparkle's shape that makes it
// one. `shouldPostponeRelaunchForUpdate` is consulted once per install,
// from inside the click on "Install and Relaunch"; answering YES
// returns Sparkle to a state in which it draws NOTHING — the status
// window stays up, its button stays enabled, and its handler is
// already nil. A hold that only this delegate knew about looked, to
// the person who clicked, like a button that does not work. So the
// hold is governed by `UpdateInstallHold` (the pure rule), asked about
// at the click (a sheet on Sparkle's own window), said beside the
// sidebar's logo the moment it starts, marked by the Settings badge
// and the line in Settings → Updates for as long as it lasts, endable
// from there, and ABANDONED on quit so an explicit ⌘Q ends in
// Sparkle's install-on-quit rather than a relaunch nobody asked for.

import AppKit
import Foundation
import Sparkle

@MainActor
final class UpdateController: NSObject, ObservableObject {

    /// Nil when `UpdaterAvailability` says this copy may not update
    /// itself. Everything below no-ops in that case, and the Settings
    /// pane draws the same controls a release copy does, greyed out,
    /// with the reason on hover.
    private var controller: SPUStandardUpdaterController?

    /// Reach into the running turns, wired from `SipAIApp`'s onAppear
    /// the same way `SipAIAppDelegate.agentManager` is — a delegate
    /// built by an adaptor can't see the SwiftUI `@StateObject`s.
    weak var agents: AgentManager?
    /// For the sheet's "Running: …" line — a session's user-set name
    /// outranks its derived title, the sidebar's own rule.
    weak var config: ConfigManager?

    /// Whether Check Now, "Update…" and the app menu's Check for
    /// Updates… may act: Sparkle's own `canCheckForUpdates` AND no
    /// install held for a running turn. Sparkle's flag goes back to YES
    /// the moment an update has been SHOWN (`setUpdateShownHandler`) and
    /// stays YES through the download and a postponed relaunch — but a
    /// check asked for then checks nothing: `SPUUpdater.checkForUpdates`
    /// sees a session already showing an update and calls
    /// `showUpdateInFocus`, which re-shows the "Ready to Install" window
    /// this controller hid for the hold — not closable, its button
    /// already answered. One gate, here, so the three call sites cannot
    /// disagree; `checkForUpdates()` refuses on it too.
    @Published private(set) var canCheckForUpdates = false
    private var sparkleCanCheckForUpdates = false {
        didSet { republishCanCheckForUpdates() }
    }
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published private(set) var automaticallyChecksForUpdates = false

    /// The version of an update whose install is being HELD for a
    /// running turn — the user clicked "Install and Relaunch", was
    /// told a turn was running, and chose to wait. Nil otherwise. The
    /// Settings line and the badge's install item render off this, and
    /// the check controls are disabled while it is set.
    @Published private(set) var heldUpdateVersion: String? {
        didSet { republishCanCheckForUpdates() }
    }

    /// A release newer than this copy, as the last check that found one
    /// named it.
    struct AvailableUpdate: Equatable, Codable {
        /// The appcast's `sparkle:version` — the build number, which is
        /// what Sparkle compares against `CFBundleVersion`.
        let version: String
        /// What a person reads: "1.0.5".
        let display: String
    }

    /// The release Settings → Updates offers and the badge counts. Kept
    /// across launches: a relaunch should not forget what the last
    /// check said, and Sparkle's next check may be a day away. It goes
    /// when a check finds nothing newer, when the user skips that
    /// version in Sparkle's window, and when this copy is at or past it.
    @Published private(set) var availableUpdate: AvailableUpdate?

    /// Mac-only state, so UserDefaults — and registered in
    /// `FactoryReset.userDefaultsKeys`: a reset leaves nothing behind
    /// for the badge to answer from.
    static let availableUpdateDefaultsKey = "sipaiAvailableUpdate"

    /// True while an install is held back for a running turn.
    var isWaitingForQuietMoment: Bool { heldUpdateVersion != nil }

    let availability = UpdaterAvailability.current

    /// Why the update controls are greyed out in a copy that may not
    /// update itself — the hover on each, in Settings → Updates and on
    /// the app menu's Check for Updates…, spelled once so the two cannot
    /// differ. It names the CAUSE, not only the consequence: a developer
    /// running their own build otherwise reads the greyed controls as
    /// broken rather than as the gate `UpdaterAvailability` describes.
    /// Empty, so no hover at all, on a copy that updates.
    var notSelfUpdatingReason: String {
        availability.allowsUpdates
            ? ""
            : String(localized: "This copy of SipAI was built locally and is not signed for distribution, so it does not update itself. Copies from the release page check for updates automatically.",
                     comment: "Updates pane and app menu: hover on the greyed-out update controls, in a build that is not a signed release")
    }

    /// Harness only (`SIPAI_UPDATER_SIMULATE_TURN`, read solely under
    /// `.forcedForTesting`): seconds a pretend turn stays "running"
    /// after the first install click, so `end-to-end.sh` can drive the
    /// real Sparkle UI through a real hold with no agent involved.
    static let simulatedTurnEnvironmentVariable = "SIPAI_UPDATER_SIMULATE_TURN"

    private var hold = UpdateInstallHold.State.idle
    private var pendingInstall: (() -> Void)?
    private var pendingVersion: String?
    private var quietMomentTimer: Timer?
    private var simulatedTurnDeadline: Date?
    private var observations: [NSKeyValueObservation] = []

    override init() {
        super.init()
        guard availability.allowsUpdates else {
            // No updater, but the checkbox is still drawn (greyed out) —
            // with the setting a release copy on this Mac would show.
            automaticallyChecksForUpdates = UpdaterAvailability.automaticChecksSetting(
                defaults: .standard, infoDictionary: Bundle.main.infoDictionary)
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.controller = controller

        let updater = controller.updater
        // Deliberate, and stated in the README's privacy section:
        // nothing downloads until the user agrees, and Sparkle's
        // optional system profile (OS version, CPU, model, language,
        // …) is never sent. Info.plist's `SUAllowsAutomaticUpdates = NO`
        // is the other half: without it Sparkle's update window offers
        // "Automatically download and install updates in the future",
        // a box whose tick this line undid at the next launch.
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        updater.updateCheckInterval = 60 * 60 * 24

        restoreAvailableUpdate()

        // Mirror Sparkle's own state instead of keeping a second copy
        // of it: the updater is the source of truth, and it changes
        // underneath us (a check completing, a skipped version).
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] u, _ in
                Task { @MainActor in self?.sparkleCanCheckForUpdates = u.canCheckForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] u, _ in
                Task { @MainActor in self?.lastUpdateCheckDate = u.lastUpdateCheckDate }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] u, _ in
                Task { @MainActor in
                    self?.automaticallyChecksForUpdates = u.automaticallyChecksForUpdates
                }
            },
        ]
    }

    // MARK: - What the UI calls

    func checkForUpdates() {
        // The gate the controls draw from, applied to the action too: a
        // shortcut or a menu item drawn before the hold began must not
        // reach Sparkle during it (see `canCheckForUpdates`).
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    private func republishCanCheckForUpdates() {
        let value = sparkleCanCheckForUpdates && heldUpdateVersion == nil
        if value != canCheckForUpdates { canCheckForUpdates = value }
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
        // The observation above republishes; setting it here too keeps
        // the toggle from visibly lagging its own click.
        automaticallyChecksForUpdates = enabled
    }

    /// Settings → Updates' "Install Now": end the hold and let Sparkle
    /// proceed. Sparkle then asks the app to quit, and
    /// `applicationShouldTerminate` interrupts the running turns the
    /// way it does for any quit. A no-op unless a hold is in place.
    func installNow() {
        apply(.installNow)
    }

    /// Called FIRST in `applicationShouldTerminate`. A hold that is
    /// still in place is dropped, block and all, so the quit ends in
    /// Sparkle's ordinary install-on-quit (no relaunch) — the poll runs
    /// in the common run-loop modes and WOULD otherwise fire inside the
    /// quit's own deferral, after the turns had been cancelled, and
    /// resume the install with a relaunch nobody asked for. Once the
    /// block has been invoked this does nothing: Sparkle's own quit
    /// request passes through here too.
    func abandonHoldForQuit() {
        apply(.quitRequested)
    }

    /// The version string shown in Settings. Read from the bundle, not
    /// a constant — a constant is one more thing to forget to bump, and
    /// this is the number a user quotes in a bug report.
    var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "—"
    }

    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    // MARK: - The release on offer

    /// What the last launch knew, if this copy is still behind it — a
    /// copy that has since been updated reads its own newer build and
    /// drops the record.
    private func restoreAvailableUpdate() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.availableUpdateDefaultsKey) else { return }
        guard let stored = try? JSONDecoder().decode(AvailableUpdate.self, from: data),
              isNewerThanThisCopy(stored.version) else {
            defaults.removeObject(forKey: Self.availableUpdateDefaultsKey)
            return
        }
        setAvailableUpdate(stored)
    }

    /// Sparkle's own comparator, over the build numbers it compares.
    private func isNewerThanThisCopy(_ version: String) -> Bool {
        SUStandardVersionComparator.default
            .compareVersion(version, toVersion: currentBuild) == .orderedDescending
    }

    private func setAvailableUpdate(_ update: AvailableUpdate?) {
        if update != availableUpdate { availableUpdate = update }
        let defaults = UserDefaults.standard
        if let update, let data = try? JSONEncoder().encode(update) {
            defaults.set(data, forKey: Self.availableUpdateDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.availableUpdateDefaultsKey)
        }
        publishBadge()
    }

    /// SipAI's items on the badge: the release on offer, and an install
    /// held for a running turn — the latter under its own key, so it is
    /// news even where the release was already seen.
    private func publishBadge() {
        var items: [UpdateBadgeItem] = []
        if let availableUpdate { items.append(.app(version: availableUpdate.version)) }
        if let heldUpdateVersion { items.append(.appInstall(version: heldUpdateVersion)) }
        UpdateBadge.shared.setAppItems(items)
    }

    // MARK: - Said beside the logo

    /// Called once the window is up: if this launch is the relaunch an
    /// update installed, say so, the way a command-line tool's update
    /// is said. Judged on the build number with Sparkle's comparator,
    /// against the build THIS copy last launched as (`CopyLaunchRecord`,
    /// keyed by where the copy lives — every copy on a Mac shares these
    /// defaults) — so a first launch and a downgrade say nothing, and a
    /// copy that does not update itself still says it when a newer build
    /// replaces it.
    func noteLaunch() {
        let defaults = UserDefaults.standard
        let stored = (defaults.dictionary(forKey: CopyLaunchRecord.defaultsKey) ?? [:])
            .compactMapValues { $0 as? String }
        let outcome = CopyLaunchRecord.note(
            records: stored,
            copy: Bundle.main.bundleURL.standardizedFileURL.path,
            build: currentBuild,
            isNewer: { build, than in
                SUStandardVersionComparator.default
                    .compareVersion(build, toVersion: than) == .orderedDescending
            },
            exists: { FileManager.default.fileExists(atPath: $0) })
        defaults.set(outcome.records, forKey: CopyLaunchRecord.defaultsKey)
        guard outcome.updated else { return }
        // The same sentence a tool's update uses, so one translation
        // serves both. The name is not translated anywhere.
        let name = "SipAI"
        UpdateAnnouncer.shared.announce(
            String(localized: "\(name) just updated to \(currentVersion)",
                   comment: "Sidebar, in place of the SipAI wordmark for a few seconds: a command-line tool (or SipAI itself) has just been updated; placeholders are the tool's label and the new version number"))
    }

    // MARK: - The hold, driven by the rule

    @discardableResult
    private func apply(_ event: UpdateInstallHold.Event) -> UpdateInstallHold.Effect {
        let (next, effect) = UpdateInstallHold.reduce(hold, event)
        hold = next
        switch effect {
        case .proceed, .ask, .none:
            // Decided at the call site: `ask` needs the block and the
            // item, `proceed` is a return value.
            break
        case .beginHold:
            beginHold()
        case .invokeInstall:
            invokeInstall()
        case .abandon:
            abandonHold()
        }
        return effect
    }

    private func runningRunners() -> [AgentRunner] {
        agents?.runners.values.filter { $0.status.isRunning } ?? []
    }

    /// Real turns, plus the harness's pretend one while its deadline
    /// stands.
    private func runningTurnCount() -> Int {
        var count = runningRunners().count
        if let deadline = simulatedTurnDeadline, deadline > Date() {
            count += 1
        }
        return count
    }

    /// What the sheet names, by the sidebar's own rule: a user-set name,
    /// else the scanned title. A runner whose session has no id yet is
    /// a draft's first turn, and a title that is merely the id (the
    /// codex scanner's fallback shape) names nothing — both read as a
    /// new session. `titleIsFallback` is NOT consulted: kimi's derived
    /// titles carry it too, and the sidebar shows them.
    private func runningSessionNames() -> [String] {
        let unnamed = String(localized: "a new session",
                             comment: "Update-hold sheet: a running turn whose session has no name yet")
        return runningRunners().map { runner in
            guard let id = runner.sessionId else { return unnamed }
            if let custom = config?.agentSessionDisplayName(for: id) {
                return custom
            }
            if let session = agents?.sessions.first(where: { $0.id == id }),
               session.title != session.id, !session.title.isEmpty {
                return session.title
            }
            return unnamed
        }
    }

    private func beginHold() {
        heldUpdateVersion = pendingVersion
        publishBadge()
        // Said where it can be seen, once: Sparkle's window goes quiet
        // from here on (see the file header), and a click that changed
        // nothing on screen reads as a button that did nothing. The
        // badge then marks where Install Now is.
        if let version = pendingVersion {
            UpdateAnnouncer.shared.announce(
                String(localized: "SipAI \(version) will install once the running turn finishes.",
                       comment: "Sidebar, in place of the SipAI wordmark for a few seconds: the user chose to wait for a running agent turn before an update installs; placeholder is the new version"))
        }
        startQuietMomentPoll()
        // Sparkle's "Ready to Install" window is inert from the click
        // on — see `sparkleStatusWindow()`. It is hidden one run-loop
        // turn later: the sheet that asked hangs from that window and
        // AppKit detaches it on the turn the completion ran in.
        let version = pendingVersion ?? "?"
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hold == .holding else { return }
            let hidden = self.hideSparkleStatusWindow()
            self.harnessLog("hold began for \(version); hid Sparkle's status window: \(hidden)")
        }
    }

    private func invokeInstall() {
        stopQuietMomentPoll()
        heldUpdateVersion = nil
        publishBadge()
        let install = pendingInstall
        pendingInstall = nil
        pendingVersion = nil
        harnessLog("hold ended — invoking install")
        install?()
    }

    private func abandonHold() {
        stopQuietMomentPoll()
        let hadHold = pendingInstall != nil || heldUpdateVersion != nil
        pendingInstall = nil
        pendingVersion = nil
        if heldUpdateVersion != nil {
            heldUpdateVersion = nil
            publishBadge()
        }
        if hadHold { harnessLog("hold abandoned") }
    }

    /// Poll rather than observe: this timer only exists while an
    /// install is actually being held back, it stops the moment it
    /// fires, and the alternative is subscribing to every runner's
    /// status for the whole life of the app to serve a case that
    /// arises once per update.
    ///
    /// In the COMMON modes, not the default one: a file picker
    /// (`panel.runModal()`), one of Sparkle's own alerts and a quit's
    /// `.terminateLater` deferral all run the loop in
    /// `NSModalPanelRunLoopMode`, where a default-mode timer never
    /// fires — a hold could then not end while a folder picker was
    /// open. The quit case is the one that cuts the other way, and
    /// `abandonHoldForQuit` is what covers it.
    private func startQuietMomentPoll() {
        stopQuietMomentPoll()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.runningTurnCount() == 0 else { return }
                self.apply(.quietMoment)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        quietMomentTimer = timer
    }

    private func stopQuietMomentPoll() {
        quietMomentTimer?.invalidate()
        quietMomentTimer = nil
    }

    // MARK: - The sheet

    /// Asked at the click, on Sparkle's own window, before Sparkle is
    /// left waiting. Two buttons and no third: the archive is already
    /// extracted, and Sparkle installs it on quit whatever is chosen
    /// here, so "cancel" would promise something it cannot deliver.
    private func presentChoice(runningTurns: Int) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        if runningTurns == 1 {
            alert.messageText = String(localized: "An agent turn is still running",
                                       comment: "Update-hold sheet title: one turn is in flight")
        } else {
            alert.messageText = String(localized: "\(runningTurns) agent turns are still running",
                                       comment: "Update-hold sheet title: several turns are in flight; placeholder is a count")
        }

        var body = String(localized: "SipAI will install the update and relaunch once the work finishes. Interrupting stops that work now, the same as quitting, and installs right away. If you quit SipAI before then, the update is installed on the way out and SipAI stays closed.",
                          comment: "Update-hold sheet body: the choice between waiting for the running turn and interrupting it")
        let names = runningSessionNames()
        if !names.isEmpty {
            let shown = names.prefix(2).map { "“\($0)”" }.joined(separator: ", ")
            let list: String
            if names.count > 2 {
                list = String(localized: "\(shown) and \(names.count - 2) more",
                              comment: "Update-hold sheet: the named sessions plus a count of the rest; placeholders are a list and a number")
            } else {
                list = shown
            }
            body += "\n\n" + String(localized: "Running: \(list)",
                                    comment: "Update-hold sheet: which sessions are mid-turn; placeholder is a list of names")
        }
        alert.informativeText = body

        alert.addButton(withTitle: String(localized: "Wait for the Turn",
                                          comment: "Update-hold sheet: install once the running turn finishes"))
        alert.addButton(withTitle: String(localized: "Interrupt and Install Now",
                                          comment: "Update-hold sheet: stop the running turn and install the update immediately"))

        if let host = sparkleStatusWindow() ?? NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: host) { [weak self] response in
                Task { @MainActor in self?.answerChoice(response) }
            }
        } else {
            answerChoice(alert.runModal())
        }
    }

    private func answerChoice(_ response: NSApplication.ModalResponse) {
        // Anything but the second button is the wait: a sheet torn down
        // by its window going away has chosen nothing, and the hold —
        // visible, endable — is the safe reading of nothing.
        apply(response == .alertSecondButtonReturn ? .choseInterrupt : .choseWait)
    }

    /// Sparkle's status window ("Ready to Install", progress bar full,
    /// "Install and Relaunch"), found by its controller's class. Best
    /// effort and nil-tolerant: the class is private to the framework
    /// and `Verification/SparkleUpdate/run.sh` checks the shipped
    /// binary still names it; when it does not, the window is simply
    /// left alone — the state before this existed.
    private func sparkleStatusWindow() -> NSWindow? {
        guard let statusClass = NSClassFromString("SUStatusController") else { return nil }
        return NSApp.windows.first { window in
            guard window.isVisible, let controller = window.windowController else { return false }
            return controller.isKind(of: statusClass)
        }
    }

    /// Ordered out, never closed. The window is Sparkle's — loaded
    /// from its nib, owned by its controller, and whether it is
    /// released when closed is Sparkle's to decide; a close from
    /// outside could be the release that leaves Sparkle's own later
    /// `close` on a freed window. Hiding carries no such semantics,
    /// Sparkle's later close of a hidden window is an ordinary close,
    /// and `showWindow:` brings the same window back wherever Sparkle
    /// wants it again. A window still carrying a sheet is left alone:
    /// hiding the parent would strand the sheet.
    private func hideSparkleStatusWindow() -> Bool {
        guard let window = sparkleStatusWindow(), window.attachedSheet == nil else { return false }
        window.orderOut(nil)
        return true
    }

    /// One stderr line per hold transition, ONLY under the harness
    /// override — `end-to-end.sh` reads them out of the app's log to
    /// time the hold, since it cannot see the click or the sheet.
    private func harnessLog(_ message: String) {
        guard availability == .forcedForTesting else { return }
        FileHandle.standardError.write(Data("SIPAI_UPDATER: \(message)\n".utf8))
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateController: SPUUpdaterDelegate {

    /// Sparkle's own first-run modal asks whether it may check
    /// automatically. On a first launch it would appear on top of
    /// onboarding, which is both the worst possible moment and a
    /// question the user has no context for yet. Automatic checks are
    /// instead on by default via `SUEnableAutomaticChecks` in
    /// Info.plist — that key is load-bearing: with the prompt
    /// suppressed here and no key, Sparkle would never schedule a
    /// check at all — and Settings → Updates turns them off. That is
    /// the same bargain, asked somewhere it can be understood.
    nonisolated func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    /// Point the updater at a different appcast — a local one served by
    /// the end-to-end harness, which has to drive a real download and a
    /// real bundle swap without publishing anything.
    ///
    /// Honoured ONLY when the updater is running under the harness
    /// override (`.forcedForTesting`). A shipped, Developer-ID-signed
    /// build reads `.enabled` and answers with the `SUFeedURL` compiled
    /// into its Info.plist, whatever is in its environment — so this
    /// cannot be used to redirect a real install at a hostile feed.
    /// Answered HERE rather than left to Sparkle: given no answer,
    /// Sparkle prefers a feed URL stored in the app's user defaults
    /// over Info.plist, and any process running as the user can write
    /// one there. (A redirected feed could not install anything — the
    /// EdDSA signature is checked against the public key in Info.plist
    /// either way — but it could hold every real update back and put
    /// its own words in the update window.)
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated {
            if availability == .forcedForTesting {
                return ProcessInfo.processInfo
                    .environment[UpdaterAvailability.feedOverrideEnvironmentVariable]
            }
            return Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        }
    }

    /// The rule this file exists for. Returning true hands us the
    /// relaunch; we own `installHandler` from that moment and the
    /// update does not land until we invoke it — or, if the user quits
    /// first, until Sparkle installs it on the way out.
    ///
    /// Never true without the sheet: Sparkle draws nothing once this
    /// returns, so a YES that nobody was asked about is a dead button.
    nonisolated func updater(_ updater: SPUUpdater,
                             shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            if availability == .forcedForTesting, simulatedTurnDeadline == nil,
               let raw = ProcessInfo.processInfo.environment[Self.simulatedTurnEnvironmentVariable],
               let seconds = TimeInterval(raw), seconds > 0 {
                simulatedTurnDeadline = Date().addingTimeInterval(seconds)
            }
            let running = runningTurnCount()
            let (next, effect) = UpdateInstallHold.reduce(hold, .installRequested(runningTurns: running))
            hold = next
            // A new install is the reset for whatever the last session
            // left behind — a poll, a held version on the badge — before
            // this one's block is stored or Sparkle is told to proceed.
            abandonHold()
            guard effect == .ask else { return false }
            pendingInstall = installHandler
            pendingVersion = item.displayVersionString
            harnessLog("asking — \(running) turn(s) running")
            presentChoice(runningTurns: running)
            return true
        }
    }

    /// The cycle is over — a relaunch on the way, Sparkle's own error
    /// alert acknowledged, or the session dismissed. Whatever the hold
    /// still holds is dropped, so a failed install cannot leave the
    /// next session unable to start one.
    nonisolated func updater(_ updater: SPUUpdater,
                             didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: (any Error)?) {
        MainActor.assumeIsolated {
            _ = apply(.sessionEnded)
        }
    }

    /// A check — the daily one or Check Now — found a release newer than
    /// this copy. It is on offer until one of the three calls below
    /// takes it away.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated {
            setAvailableUpdate(AvailableUpdate(version: item.versionString,
                                               display: item.displayVersionString))
        }
    }

    /// A check found nothing newer: this copy is current, or the release
    /// on offer was skipped, or needs a newer macOS. Nothing is on offer.
    /// A check that FAILED is not this call, and leaves the record alone.
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            setAvailableUpdate(nil)
        }
    }

    /// "Skip This Version" in Sparkle's window is the user's answer for
    /// that release: nothing more is offered for it, badge included.
    /// "Remind Me Later" and "Install" leave it on offer.
    nonisolated func updater(_ updater: SPUUpdater,
                             userDidMake choice: SPUUserUpdateChoice,
                             forUpdate updateItem: SUAppcastItem,
                             state: SPUUserUpdateState) {
        guard choice == .skip else { return }
        MainActor.assumeIsolated {
            setAvailableUpdate(nil)
        }
    }
}
