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
//   3. That an update NEVER interrupts a running agent turn.
//
// (3) is the one that is specific to this app. Everywhere else SipAI
// goes out of its way not to SIGKILL an agent mid-turn —
// `applicationShouldTerminate` interrupts them deliberately and waits
// for the children to be reaped, `LanguagePane` warns before it
// relaunches. An updater that swapped the bundle and relaunched while
// `claude -p` was eight minutes into a task would undo all of that,
// and would do it at a moment the user did not choose.

import Foundation
import Sparkle

@MainActor
final class UpdateController: NSObject, ObservableObject {

    /// Nil when `UpdaterAvailability` says this copy may not update
    /// itself. Everything below no-ops in that case, and the Settings
    /// pane explains why rather than showing dead controls.
    private var controller: SPUStandardUpdaterController?

    /// Reach into the running turns, wired from `SipAIApp`'s onAppear
    /// the same way `SipAIAppDelegate.agentManager` is — a delegate
    /// built by an adaptor can't see the SwiftUI `@StateObject`s.
    weak var agents: AgentManager?

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published private(set) var automaticallyChecksForUpdates = false

    /// True between the user accepting an install and the relaunch
    /// actually happening, i.e. while we are holding it back because a
    /// turn is in flight. The Settings pane says so — otherwise
    /// "Install and Relaunch" looks like it did nothing.
    @Published private(set) var isWaitingForQuietMoment = false

    let availability = UpdaterAvailability.current

    private var pendingInstall: (() -> Void)?
    private var quietMomentTimer: Timer?
    private var observations: [NSKeyValueObservation] = []

    override init() {
        super.init()
        guard availability.allowsUpdates else { return }

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
        // …) is never sent.
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        updater.updateCheckInterval = 60 * 60 * 24

        // Mirror Sparkle's own state instead of keeping a second copy
        // of it: the updater is the source of truth, and it changes
        // underneath us (a check completing, a skipped version).
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] u, _ in
                Task { @MainActor in self?.canCheckForUpdates = u.canCheckForUpdates }
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
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
        // The observation above republishes; setting it here too keeps
        // the toggle from visibly lagging its own click.
        automaticallyChecksForUpdates = enabled
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

    // MARK: - Holding an install back until no turn is running

    private var hasRunningTurn: Bool {
        agents?.runners.values.contains { $0.status.isRunning } ?? false
    }

    /// Poll rather than observe: this timer only exists while an
    /// install is actually being held back, it stops the moment it
    /// fires, and the alternative is subscribing to every runner's
    /// status for the whole life of the app to serve a case that
    /// arises once per update.
    private func waitForQuietMoment() {
        quietMomentTimer?.invalidate()
        quietMomentTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.hasRunningTurn else { return }
                self.quietMomentTimer?.invalidate()
                self.quietMomentTimer = nil
                self.isWaitingForQuietMoment = false
                let install = self.pendingInstall
                self.pendingInstall = nil
                install?()
            }
        }
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
    /// build reads `.enabled`, returns nil here, and uses the
    /// `SUFeedURL` compiled into its Info.plist no matter what is in
    /// its environment — so this cannot be used to redirect a real
    /// install at a hostile feed. (Even in the forced case it could not
    /// achieve much: the EdDSA signature is checked against the public
    /// key in Info.plist either way, so a feed we don't sign for has
    /// nothing installable in it.)
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated {
            guard availability == .forcedForTesting else { return nil }
            return ProcessInfo.processInfo
                .environment[UpdaterAvailability.feedOverrideEnvironmentVariable]
        }
    }

    /// The rule this file exists for. Returning true hands us the
    /// relaunch; we own `installHandler` from that moment and the
    /// update does not land until we invoke it.
    nonisolated func updater(_ updater: SPUUpdater,
                             shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            guard hasRunningTurn else { return false }
            pendingInstall = installHandler
            isWaitingForQuietMoment = true
            waitForQuietMoment()
            return true
        }
    }
}
