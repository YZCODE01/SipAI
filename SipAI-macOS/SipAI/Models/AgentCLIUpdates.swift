// AgentCLIUpdates.swift
// SipAI macOS — is the agent CLI we spawn the current one, and can the
// user do anything about it from here?
//
// The failure this exists for is a SILENT one. A stale agent CLI does
// not error: it runs turns happily against whatever models its own
// binary knows about, so a user can spend weeks one model release
// behind with nothing on screen saying so. Claude Code bakes its
// alias→model resolution into the binary, which is what makes a stale
// binary a stale MODEL rather than merely a stale feature set.
//
// Three layers, deliberately separate:
//
//   * LOCAL — what version is installed. Cheap, exact, and the only
//     value ever printed as a fact. Read through the same
//     `AgentManager.binaryPath(for:)` the runner spawns, so the version
//     shown is the version SipAI actually runs.
//   * REMOTE — what version exists. A small periodic GET of each
//     vendor's own release endpoint. Every claim the UI makes about
//     being current or behind rests on a SUCCESSFUL one of these, and
//     on nothing else.
//   * ACTION — the CLI's OWN update command, spawned the way an agent
//     turn is spawned. Never a composed npm/brew/installer line: those
//     need a node/npm context this app has no business guessing at, and
//     a wrong guess damages an install the user did not ask us to
//     touch. Started by the row's Update button or — once the user has
//     switched automatic updates on — by itself, and never while a turn
//     of that tool is running. A turn sent while one runs waits for it.
//
// The rule that shapes all of it: **never claim, never nag, without
// evidence.** A check that failed downgrades nothing and says nothing;
// an agent nobody has measured a release endpoint for shows its version
// and no verdict at all. Absence of a claim is the honest state, and it
// is a different thing from "up to date". A tool that is behind is told
// by the Settings badge (`UpdateBadge`), which asks for nothing until
// the user looks; one that has been updated — by the button, by itself,
// or from a terminal — is told once, beside the sidebar's logo
// (`UpdateAnnouncer`).

import AppKit
import Combine
import Foundation

// MARK: - CLIVersion

/// A dotted numeric version lifted out of a CLI's `--version` line.
///
/// The three shapes this has to read are measured, and no two agree:
/// `2.1.239 (Claude Code)`, `codex-cli 0.147.0`, `0.38.0`. So the parse
/// is "first dotted-numeric token", not a format.
///
/// Comparison pads the shorter side with zeros, which makes `2.1` and
/// `2.1.0` EQUAL — the shape of `ClaudeModelDisplay.isNewer`, widened
/// to arbitrary depth. A non-numeric suffix (`-beta.2`) is outside the
/// token and therefore compares equal to its absence: this ranks
/// releases, it is not a semver implementation, and pretending to order
/// prereleases would be a claim nothing here has measured.
struct CLIVersion: Equatable, Comparable, CustomStringConvertible {

    /// Numeric components, most significant first. Never empty.
    let components: [Int]

    /// Exactly the token that was parsed — "2.1.258", not the whole
    /// `--version` line. This is what the UI prints, so it must not
    /// carry an agent's name or a vendor's parenthetical.
    let text: String

    private init(components: [Int], text: String) {
        self.components = components
        self.text = text
    }

    var description: String { text }

    /// First `\d+(\.\d+)+` token in `output`, or nil.
    ///
    /// At least one dot is REQUIRED. A bare-integer rule would happily
    /// read the "5" out of a model slug or the "2" out of a copyright
    /// line, and every CLI this ships against versions with semver.
    static func parse(_ output: String) -> CLIVersion? {
        guard let regex = try? NSRegularExpression(
            pattern: #"\d+(?:\.\d+)+"#
        ) else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let found = Range(match.range, in: output) else { return nil }
        let token = String(output[found])
        let parts = token.split(separator: ".").compactMap { Int($0) }
        guard parts.count == token.split(separator: ".").count,
              !parts.isEmpty else { return nil }
        return CLIVersion(components: parts, text: token)
    }

    static func compare(_ lhs: CLIVersion, _ rhs: CLIVersion) -> ComparisonResult {
        let depth = max(lhs.components.count, rhs.components.count)
        for i in 0..<depth {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // Equality goes through `compare` rather than through the stored
    // array, or "2.1" and "2.1.0" would be equal to each other under
    // `<` and unequal under `==`. Deliberately not Hashable for the
    // same reason: there is no hash consistent with this equality that
    // is worth the risk of someone adding one that is not.
    static func == (lhs: CLIVersion, rhs: CLIVersion) -> Bool {
        compare(lhs, rhs) == .orderedSame
    }

    static func < (lhs: CLIVersion, rhs: CLIVersion) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }
}

// MARK: - Status

/// What a command-line tool's row is entitled to say about itself.
///
/// `versionOnly` is the one that carries the design: it is what an
/// agent shows when no release check has ever succeeded. It is NOT
/// "up to date" — nothing has been compared — and it is not an error
/// either. The row states the installed version and stops.
enum CLIUpdateStatus: Equatable {
    /// The installed version has not been read yet.
    case unknown
    /// Read, but never compared against a successful release check.
    case versionOnly(installed: CLIVersion)
    /// Installed ≥ latest, as of a check that SUCCEEDED at `checkedAt`.
    case upToDate(installed: CLIVersion, checkedAt: Date)
    case updateAvailable(installed: CLIVersion, latest: CLIVersion)
    /// The CLI's own updater is running.
    case updating
    /// The updater ran and the installed version did not move. The tail
    /// is the command's own output, which is the only thing that can
    /// explain why.
    case updateFailed(outputTail: String)
    /// Installed by a package manager the CLI's own updater leaves the
    /// update to — Homebrew, for claude and kimi (`AgentInstallSource
    /// .managedBy`): `claude update` prints "Claude is managed by
    /// Homebrew." and exits without updating; `kimi upgrade` names
    /// `brew upgrade kimi-code` and stops. SipAI never runs Homebrew, so
    /// the row states the version and who manages it: no claim (the
    /// `claude-code` cask tracks npm's `stable` tag, so a comparison
    /// against `latest` is against the wrong channel), no button (it
    /// could never move the version) and no badge.
    case managedElsewhere(installed: CLIVersion, manager: String)

    /// Whether an Update button belongs on this row at all.
    var offersUpdate: Bool {
        switch self {
        case .updateAvailable, .updateFailed: return true
        case .unknown, .versionOnly, .upToDate, .updating, .managedElsewhere: return false
        }
    }
}

// MARK: - The pure rules

/// Every decision this feature makes, as functions of their arguments.
///
/// Same rule as `ScheduledTaskScheduler.decide`, and for the same
/// reason: the whole race matrix — pressed while already current,
/// updater exits 0 without moving the version, a check that failed
/// after one that succeeded — is drivable from a harness with no
/// subprocess, no timer and no network.
enum AgentCLIUpdateRules {

    /// The row's claim.
    ///
    /// `latestKnown` and `lastCheckSucceeded` describe the last check
    /// that SUCCEEDED, so a failed check is expressed by simply not
    /// changing them: an `upToDate` earned from an old success keeps
    /// standing (with its own timestamp, which is what the tooltip
    /// shows), and a `versionOnly` stays `versionOnly`. There is no
    /// path here that turns a failed network call into a claim.
    ///
    /// `managedBy` names the package manager the CLI's own updater
    /// leaves this install to (`AgentInstallSource.managedBy`); set, it
    /// outranks whatever a check found — the updater would not apply
    /// it here, and for claude's stable cask the comparison itself is
    /// against the wrong channel.
    static func decideStatus(installed: CLIVersion?,
                             latestKnown: CLIVersion?,
                             lastCheckSucceeded: Date?,
                             managedBy: String? = nil) -> CLIUpdateStatus {
        guard let installed else { return .unknown }
        if let managedBy { return .managedElsewhere(installed: installed, manager: managedBy) }
        guard let latestKnown, let lastCheckSucceeded else {
            return .versionOnly(installed: installed)
        }
        if installed < latestKnown {
            return .updateAvailable(installed: installed, latest: latestKnown)
        }
        return .upToDate(installed: installed, checkedAt: lastCheckSucceeded)
    }

    enum RunOrSkip: Equatable {
        case run
        /// Nothing to do — the row flips and no process is spawned.
        case alreadyCurrent(CLIVersion)
    }

    /// What pressing Update should do, judged on a version re-read at
    /// the moment of the press.
    ///
    /// No cached status is ever acted on. Between the check that raised
    /// the button and the click there may have been an hour, a
    /// background self-update, or a terminal `claude update` — and the
    /// cost of acting on the stale answer is a 330 MB download the user
    /// did not need.
    ///
    /// A nil `latestKnown` still RUNS: the button is only reachable
    /// from a state that had one, and if it is somehow missing, the
    /// CLI's own updater does its own check anyway. Refusing there
    /// would be a dead button with nothing on screen explaining it.
    static func updateAction(installedNow: CLIVersion?,
                             latestKnown: CLIVersion?) -> RunOrSkip {
        guard let installedNow, let latestKnown else { return .run }
        return installedNow < latestKnown
            ? .run
            : .alreadyCurrent(installedNow)
    }

    enum UpdateVerdict: Equatable {
        case updated(to: CLIVersion)
        /// Ran, nothing moved, and nothing needed to.
        case alreadyCurrent(CLIVersion)
        /// Ran and the version did not move while a newer one exists.
        /// The row shows the command's output, which is where the
        /// reason lives.
        case didNotUpdate
    }

    /// The success test is the VERSION MOVING, never the exit code.
    ///
    /// Measured, and this is why: `codex update` prints "Update ran
    /// successfully!" and exits 0 when it had nothing to do, and
    /// `kimi upgrade` on a natively-installed kimi exits 0 after
    /// declining to update at all — it detects the install source,
    /// prints the manual command and returns. An exit code cannot tell
    /// those apart from a real update; two version reads can.
    static func updateVerdict(before: CLIVersion?,
                              after: CLIVersion?,
                              latestKnown: CLIVersion?) -> UpdateVerdict {
        // Nothing readable afterwards is not a success. It is also not
        // provably a failure, but a claim of success needs evidence and
        // this has none.
        guard let after else { return .didNotUpdate }
        if let before, after > before { return .updated(to: after) }
        if before == nil, latestKnown == nil { return .alreadyCurrent(after) }
        if let latestKnown, after < latestKnown { return .didNotUpdate }
        if before == nil { return .alreadyCurrent(after) }
        return after == before ? .alreadyCurrent(after) : .didNotUpdate
    }

    /// The version a tool puts on the Settings badge, or nil for none.
    ///
    /// A tool that is behind is on offer — unless it is updated
    /// automatically, in which case there is nothing for the user to do
    /// and nothing to announce until an attempt fails. A FAILED update
    /// is on offer either way: with automatic updates on, the badge is
    /// then the only thing that says the update did not land. A status
    /// that is no longer behind produces nothing, which is how a tool
    /// that became current — by any route — takes its badge down with
    /// nothing written anywhere.
    static func badgeVersion(status: CLIUpdateStatus,
                             latest: CLIVersion?,
                             autoUpdate: Bool) -> String? {
        switch status {
        case .updateAvailable(_, let latest):
            return autoUpdate ? nil : latest.text
        case .updateFailed:
            return latest?.text
        case .unknown, .versionOnly, .upToDate, .updating, .managedElsewhere:
            return nil
        }
    }

    /// Whether the tool's own update should start by itself, now.
    ///
    /// Never while a turn of that tool is in flight — the same rule the
    /// Update button follows, since replacing a binary under a running
    /// child is not something to do quietly — and never while another
    /// action holds the tool (an update, an install, a delete). ONE
    /// attempt per version: `attemptedVersion` is the version already
    /// tried, and an attempt that failed is reported through the badge
    /// rather than retried in a loop. A newer release is a new attempt.
    static func autoUpdateIsDue(enabled: Bool,
                                status: CLIUpdateStatus,
                                latest: CLIVersion?,
                                actionInFlight: Bool,
                                turnInFlight: Bool,
                                attemptedVersion: String?) -> Bool {
        guard enabled, !actionInFlight, !turnInFlight,
              status.offersUpdate, let latest else { return false }
        return attemptedVersion != latest.text
    }

    /// Whether a tool counts as installed — for its Updates row, and
    /// for everything presence gates: the sidebar section, an open
    /// page, the scheduler.
    ///
    /// The binary being on disk, OR SipAI's own update of it being in
    /// progress. An npm update moves the tool's link aside for the whole
    /// download: `npm install -g @openai/codex` retired
    /// `/opt/homebrew/bin/codex` to `.codex-<random>` at the start and
    /// linked the new one 3 min 35 s later (measured; the platform
    /// binary is 238 MB). Judged on the binary alone, the tool vanished
    /// for exactly as long as it was being updated, taking with it the
    /// row that showed the update and its Cancel. A missing binary
    /// mid-update is not an uninstall, and nothing spawns it meanwhile:
    /// a turn sent then waits for the update (`waitForUpdate`).
    static func countsAsInstalled(binaryFound: Bool, updating: Bool) -> Bool {
        binaryFound || updating
    }
}

// MARK: - Measured per-agent facts

/// Where an agent publishes its latest version, and what its own
/// updater is called.
///
/// Every entry here is MEASURED, and an agent with no entry gets a
/// version-only row and no button — never a guessed endpoint and never
/// a composed package-manager command. That gate is the whole point of
/// the type: a fourth agent added to `AgentManager.registry` is
/// version-only by construction until somebody probes it.
struct AgentCLIRelease {

    /// How the endpoint spells its answer.
    enum Payload {
        /// npm registry `/latest`: a JSON packument document whose
        /// `version` field is the released version.
        case npmLatestJSON
        /// The version on its own, as text.
        case plainText
    }

    let agentKey: String
    let latestURL: URL
    let payload: Payload
    /// The CLI's own update subcommand. Argv only — nothing is ever
    /// routed through a shell.
    let updateArguments: [String]
    /// The vendor's own installers, for an agent whose update command
    /// DECLINES on some install source and names one of these scripts as
    /// the manual route instead (kimi on a native install, measured). Run
    /// only when the decline is recognised — see
    /// `declinedToNativeInstaller(in:)`. Empty for everyone else.
    ///
    /// Kimi has TWO, one per site — `code.kimi.com` for mainland China,
    /// `code.kimi.ai` for everywhere else — and kimi's updater names the
    /// one of the region it is on: a login's saved host, else the
    /// marker its installer wrote (read out of kimi's own
    /// `kimiCodeInstallShUrl`). The first entry is the fallback of
    /// `nativeInstallerAfterFailedCheck`.
    var nativeInstallers: [URL] = []

    /// The installer kimi's updater names when it declines a native
    /// install — measured text: "A newer version … is available … /
    /// Detected install source: native installer / To update manually,
    /// run: curl -fsSL https://code.kimi.com/kimi-code/install.sh |
    /// bash" (and `code.kimi.ai` on a kimi on the global region).
    /// Returns the installer only when the URL in that sentence is
    /// EXACTLY one of the measured ones: kimi's words are trusted to say
    /// it declined and on which site, never to name an arbitrary script
    /// to run. Matching the mainland URL alone would fail every update of
    /// a kimi on the global site.
    func declinedToNativeInstaller(in output: String) -> URL? {
        guard !nativeInstallers.isEmpty,
              let regex = try? NSRegularExpression(
                pattern: #"To update manually, run:\s*curl\s+-fsSL\s+(\S+)\s*\|\s*bash"#)
        else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              match.numberOfRanges > 1,
              let found = Range(match.range(at: 1), in: output),
              let named = URL(string: String(output[found]))
        else { return nil }
        return nativeInstallers.first { $0 == named }
    }

    /// kimi's updater could not reach its update endpoint. Measured
    /// from the binary: `handleUpgrade` refreshes its update cache
    /// FIRST and, when that fetch fails, writes `error: failed to check
    /// for updates: <reason>` and exits 1 — before it has said a word
    /// about the install source, so `declinedToNativeInstaller` finds
    /// nothing and the update dies on a network stall that this app
    /// did not share (its own fetch of the same endpoint had just
    /// succeeded, which is why the button was offered at all).
    func updaterCheckFailed(in output: String) -> Bool {
        !nativeInstallers.isEmpty
            && output.contains("failed to check for updates")
    }

    /// The vendor's installer, when the updater's CHECK failed but
    /// kimi's own install record says the install is native.
    ///
    /// The same route `declinedToNativeInstaller` takes, reached from
    /// kimi's other statement of the same fact: `updates/install.json`
    /// under its home carries `active.source` ("native" — measured on
    /// the record kimi's own background updater wrote). Both signals
    /// are kimi's words; neither is a guess about the install source,
    /// and the installer URL is still the measured constant, never
    /// parsed from anywhere. Without this, a transient stall on the
    /// route kimi's fetch takes leaves the row on an error sentence
    /// while everything the installer needs — the version, the
    /// directory, the script — is already known. Kimi named no site
    /// here, so it is the first (mainland) channel: both serve the same
    /// checksummed binaries, and the installer never rewrites the site
    /// marker of an existing install.
    func nativeInstallerAfterFailedCheck(in output: String,
                                         installRecord: Data?) -> URL? {
        guard let installer = nativeInstallers.first,
              updaterCheckFailed(in: output),
              let record = installRecord,
              Self.installSource(fromRecord: record) == "native"
        else { return nil }
        return installer
    }

    /// `active.source` of kimi's install record —
    /// `{"active":{"version":…,"source":"native",…},…}`. nil for
    /// anything else, including a record that names no source.
    static func installSource(fromRecord data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              let active = obj["active"] as? [String: Any],
              let source = active["source"] as? String,
              !source.isEmpty
        else { return nil }
        return source
    }

    /// Where kimi keeps that record: `updates/install.json` under its
    /// HOME (`KIMI_CODE_HOME`, default `~/.kimi-code`) — not under the
    /// install directory, which is the same folder by default but is
    /// the installer's choice, not kimi's.
    static func nativeInstallRecordURL(home: URL) -> URL {
        home.appendingPathComponent("updates", isDirectory: true)
            .appendingPathComponent("install.json")
    }

    /// Where a native install lives, from the binary SipAI spawns: the
    /// installer's `KIMI_INSTALL_DIR` is the directory whose `bin/`
    /// holds it (`~/.kimi-code/bin/kimi` → `~/.kimi-code`), and ONLY
    /// kimi's own home (`kimiHome`: `~/.kimi-code`, or `KIMI_CODE_HOME`).
    /// nil for any other layout — the installer is never pointed
    /// anywhere it did not put the binary itself: a copy of the binary
    /// in a shared `bin` (`/usr/local/bin`) would otherwise send it to
    /// `/usr/local`, where it writes its own `fd` and `rg` over the
    /// user's.
    static func nativeInstallDirectory(binaryPath: String, kimiHome: String) -> String? {
        let resolved = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath()
        let bin = resolved.deletingLastPathComponent()
        guard bin.lastPathComponent == "bin" else { return nil }
        let directory = bin.deletingLastPathComponent().standardizedFileURL.path
        guard directory == URL(fileURLWithPath: kimiHome).standardizedFileURL.path
        else { return nil }
        return directory
    }

    /// The installer's documented non-interactive interface (its own
    /// header names all three): the exact version the row named —
    /// never "whatever is newest now" — the directory the binary
    /// already lives in, and NO edit to the user's shell files. PATH
    /// already reaches this install, and rewriting `.zshrc` is not
    /// something an Update button gets to do.
    static func nativeInstallerArguments(script: String, version: String) -> [String] {
        [script, "--version", version]
    }

    static func nativeInstallerEnvironment(installDirectory: String) -> [String: String] {
        ["KIMI_INSTALL_DIR": installDirectory, "KIMI_NO_MODIFY_PATH": "1"]
    }

    func version(from data: Data) -> CLIVersion? {
        switch payload {
        case .plainText:
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return CLIVersion.parse(text)
        case .npmLatestJSON:
            guard let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  let raw = obj["version"] as? String else { return nil }
            return CLIVersion.parse(raw)
        }
    }

    /// Claude's release channel, as `claude update` follows it on a
    /// native install: `autoUpdatesChannel` in its settings files, a
    /// later file winning (the user's `settings.json`, then
    /// `settings.local.json` — `PlanAccountDetector.claudeSettingsFiles`;
    /// a project's file is not in hand for a row about the binary), and
    /// `latest` when unset. Claude's own settings schema allows
    /// `latest`, `stable` and `rc`, and each is an npm dist-tag of its
    /// package — `stable` stood at 2.1.274 while `latest` was 2.1.283
    /// (2026-09-28). Checked against `latest`, a stable-channel install
    /// read as behind, and its `claude update` answered "up to date" for
    /// as long as the two tags differed. Anything else reads as claude's
    /// default. Homebrew installs choose their channel by CASK NAME and
    /// are never claimed against (`AgentInstallSource.managedBy`).
    static func claudeChannel(settings: [Data]) -> String {
        var channel = "latest"
        for data in settings {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let value = obj["autoUpdatesChannel"] as? String else { continue }
            channel = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return ["latest", "stable", "rc"].contains(channel) ? channel : "latest"
    }

    /// The same release read against another npm dist-tag: the registry
    /// answers `/<package>/<tag>` for every tag the way it answers
    /// `/latest`, with the same document. Only an npm-backed release has
    /// a channel, and `latest` is the measured URL itself.
    func onChannel(_ tag: String) -> AgentCLIRelease {
        guard payload == .npmLatestJSON, tag != "latest" else { return self }
        return AgentCLIRelease(agentKey: agentKey,
                               latestURL: latestURL.deletingLastPathComponent()
                                   .appendingPathComponent(tag),
                               payload: payload,
                               updateArguments: updateArguments,
                               nativeInstallers: nativeInstallers)
    }

    /// The measured table. Anything not named here is version-only.
    ///
    /// * claude_code — npm is the vendor's own channel and it matched
    ///   the newest version claude's private updater had attempted
    ///   locally, exactly. `claude update` applies the update and
    ///   repoints the version symlink.
    /// * codex — npm likewise. `codex update` shells out to
    ///   `npm install -g @openai/codex` itself, which is precisely why
    ///   SipAI must not: the CLI knows which npm installed it, and this
    ///   app does not.
    /// * kimi — `code.kimi.com/kimi-code/latest` is the endpoint kimi's
    ///   OWN installer resolves "latest" from. `kimi upgrade` is
    ///   install-source-aware, and on a native install it declines and
    ///   prints the manual command instead of updating; the button
    ///   still runs it, and that refusal — kimi's own words, including
    ///   the exact command — is what routes to the installer. When the
    ///   updater cannot even check (its fetch stalls on a route this
    ///   app's own fetch did not take), kimi's install record is the
    ///   other statement of the same fact — see
    ///   `nativeInstallerAfterFailedCheck`. Guessing which install
    ///   source a machine has would be a worse answer than asking
    ///   kimi, and neither route guesses.
    static func measured(agentKey: String) -> AgentCLIRelease? {
        switch agentKey {
        case "claude_code":
            guard let url = URL(string:
                "https://registry.npmjs.org/@anthropic-ai/claude-code/latest")
            else { return nil }
            return AgentCLIRelease(agentKey: agentKey, latestURL: url,
                                   payload: .npmLatestJSON,
                                   updateArguments: ["update"])
        case "codex":
            guard let url = URL(string:
                "https://registry.npmjs.org/@openai/codex/latest")
            else { return nil }
            return AgentCLIRelease(agentKey: agentKey, latestURL: url,
                                   payload: .npmLatestJSON,
                                   updateArguments: ["update"])
        case "kimi":
            // The release check reads the mainland channel: the global
            // one is a sync of it, answering the same version. The
            // installers are both sites' — `KimiSite.installer` spells
            // the same two, and the Agent Guide harness holds them equal.
            guard let url = URL(string:
                "https://code.kimi.com/kimi-code/latest"),
                  let mainland = URL(string:
                "https://code.kimi.com/kimi-code/install.sh"),
                  let global = URL(string:
                "https://code.kimi.ai/kimi-code/install.sh")
            else { return nil }
            return AgentCLIRelease(agentKey: agentKey, latestURL: url,
                                   payload: .plainText,
                                   updateArguments: ["upgrade"],
                                   nativeInstallers: [mainland, global])
        default:
            return nil
        }
    }
}

// MARK: - Local probe

/// What a `stat` can see of an installed CLI.
///
/// Both halves are load-bearing. The LINK's own attributes catch
/// claude's native layout, where an update repoints
/// `~/.local/bin/claude` at a new file under `…/claude/versions/`. The
/// RESOLVED target's catch an installer that rewrites the file in
/// place and leaves the link alone. Measured after real updates of all
/// three: npm recreates codex's symlink and rewrites its target, the
/// claude updater repoints its link, and kimi's installer replaces its
/// binary outright — the pair covers every one of them, where either
/// half alone is a guess about somebody else's installer.
struct CLIBinaryFingerprint: Equatable {
    let path: String
    let linkModified: Date?
    let linkTarget: String?
    let targetPath: String
    let targetModified: Date?
    let targetSize: Int?
}

/// Reads the filesystem and spawns processes — never call from the
/// MainActor.
enum AgentCLIProbe {

    /// A `--version` spawn may not outlive this. A wedged probe must
    /// not strand the monitor's state on "unknown" for the life of the
    /// launch.
    static let versionCeiling: TimeInterval = 10

    /// Claude's download is ~330 MB and npm's is a full dependency
    /// resolve; this is a backstop against a hung child, not a
    /// prediction. Measured runs: 35 s, 23 s, 4 s.
    static let updateCeiling: TimeInterval = 15 * 60

    /// What of an updater's output is kept for the failure display.
    static let outputTailCap = 64 * 1024

    nonisolated static func fingerprint(agentKey: String) -> CLIBinaryFingerprint? {
        guard let path = AgentManager.binaryPath(for: agentKey) else { return nil }
        let fm = FileManager.default
        // `attributesOfItem` does not traverse a symlink, so this is
        // the LINK's own mtime — which is the thing that moves when an
        // updater repoints it.
        let linkAttrs = try? fm.attributesOfItem(atPath: path)
        let target = try? fm.destinationOfSymbolicLink(atPath: path)
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let targetAttrs = try? fm.attributesOfItem(atPath: resolved)
        return CLIBinaryFingerprint(
            path: path,
            linkModified: linkAttrs?[.modificationDate] as? Date,
            linkTarget: target,
            targetPath: resolved,
            targetModified: targetAttrs?[.modificationDate] as? Date,
            targetSize: (targetAttrs?[.size] as? NSNumber)?.intValue
        )
    }

    /// The installed version, preferring the spawn-free route.
    ///
    /// Claude's native install names its versions: `~/.local/bin/claude`
    /// is a symlink into `…/claude/versions/`, and the target's
    /// filename IS the version — measured against `claude --version`
    /// both before and after a real update. That saves a process spawn
    /// on the agent whose row is refreshed most often. Anything else
    /// (a shim, a Node SEA, a Rust binary) falls through to asking the
    /// binary itself, which is the answer that cannot be wrong.
    nonisolated static func installedVersion(
        agentKey: String,
        fingerprint: CLIBinaryFingerprint?
    ) async -> CLIVersion? {
        guard let fingerprint else { return nil }
        if let fast = versionFromClaudeVersionsSymlink(fingerprint) { return fast }
        await ShellEnvironment.prepare()
        let result = await run(binary: fingerprint.path,
                               arguments: ["--version"],
                               ceiling: versionCeiling,
                               outputCap: 4096,
                               onSpawn: { _ in })
        return CLIVersion.parse(result.output)
    }

    /// `…/claude/versions/2.1.258` → 2.1.258.
    ///
    /// Scoped to that directory name rather than to "any symlink whose
    /// last component parses as a version": a link into a versioned
    /// node/npm prefix would otherwise report the NODE version as the
    /// agent's.
    nonisolated static func versionFromClaudeVersionsSymlink(
        _ fingerprint: CLIBinaryFingerprint
    ) -> CLIVersion? {
        guard fingerprint.linkTarget != nil else { return nil }
        let resolved = fingerprint.targetPath
        guard resolved.contains("/claude/versions/") else { return nil }
        let name = (resolved as NSString).lastPathComponent
        guard let parsed = CLIVersion.parse(name), parsed.text == name else {
            return nil
        }
        return parsed
    }

    struct RunResult {
        /// nil when the child was killed at the ceiling or never ran.
        let exitCode: Int32?
        /// stdout and stderr interleaved, tail-bounded.
        let output: String
        /// The process group the child led. `Process` makes the child the
        /// leader of a group of its own, and whatever the child starts
        /// stays in it — npm under `codex update` — so this is what still
        /// answers after the child is gone (`groupIsAlive`). nil when the
        /// child never ran, or its group could not be read, or it is
        /// SipAI's own, which always has a member.
        var processGroup: pid_t? = nil
    }

    /// Whether any process of `group` is still alive. A group outlives
    /// its leader for as long as one member does, and its id is not
    /// reused while it does.
    nonisolated static func groupIsAlive(_ group: pid_t) -> Bool {
        killpg(group, 0) == 0
    }

    /// Spawn a CLI and capture what it says, the way an agent turn is
    /// spawned.
    ///
    /// The environment is `AgentRunner.buildEnvironment()` — the SAME
    /// one every agent child gets, not a second spelling of it. That
    /// carries three things this needs and none of which are optional:
    /// `stripDynamicLinkerVars` (kimi is a Node SEA that aborts on an
    /// inherited `DYLD_INSERT_LIBRARIES` before running a line), the
    /// shared `searchPaths` PATH (codex's binary is a Node shim that
    /// has to find `node`, and its updater has to find `npm`), and
    /// `overlayProxyVars` (which fills in ONLY names the process
    /// environment lacks, from what the login shell exports — so on a
    /// machine with no proxy it adds nothing at all).
    ///
    /// stdin is `/dev/null`: an updater that decides to prompt must
    /// find EOF and give up rather than wait forever on a pipe nobody
    /// is typing into.
    ///
    /// The builder consults the login shell's capture for those proxy
    /// names, and `ShellEnvironment.resolve` BLOCKS on a cold cache —
    /// so the capture is awaited first, exactly as `AgentRunner.runOnce`
    /// does before it builds a child's environment. Normally a no-op
    /// (`warmUp()` at launch), never a stalled thread when it is not.
    nonisolated static func run(binary: String,
                                arguments: [String],
                                ceiling: TimeInterval,
                                outputCap: Int,
                                extraEnvironment: [String: String] = [:],
                                currentDirectory: String? = nil,
                                onSpawn: @escaping (Process) -> Void) async -> RunResult {
        await ShellEnvironment.prepare()
        var environment = AgentRunner.buildEnvironment()
        // On top of, never instead of: the installer still needs the
        // PATH (curl, shasum) and the proxy names the builder supplies.
        for (name, value) in extraEnvironment { environment[name] = value }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: binary)
                p.arguments = arguments
                p.environment = environment
                // Where the child runs matters to a CLI that files
                // work by cwd — the plan-usage probe runs claude in a
                // scratch folder so its transcript is scratch too.
                if let currentDirectory {
                    p.currentDirectoryURL = URL(fileURLWithPath: currentDirectory,
                                                isDirectory: true)
                }
                p.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do {
                    try p.run()
                } catch {
                    continuation.resume(returning: RunResult(
                        exitCode: nil,
                        output: "\(error.localizedDescription)"))
                    return
                }
                // Read while the child is surely there: once it has
                // exited and been reaped, its group can no longer be
                // asked for.
                let group = getpgid(p.processIdentifier)
                onSpawn(p)

                let output = drain(pipe.fileHandleForReading, of: p,
                                   ceiling: ceiling, outputCap: outputCap)
                // Never read `terminationStatus` on a live process —
                // Foundation raises. `drain` has waited the child out,
                // but the guard costs nothing and the rule is absolute.
                let code: Int32? = p.isRunning ? nil : p.terminationStatus
                continuation.resume(returning: RunResult(
                    exitCode: code,
                    output: output,
                    processGroup: group > 1 && group != getpgrp() ? group : nil))
            }
        }
    }

    /// How long a child that has EXITED may leave the pipe silent
    /// before the drain stops waiting on whoever still holds its write
    /// end.
    static let orphanGrace: TimeInterval = 2

    /// How long a child gets to honour SIGTERM before it is SIGKILLed.
    /// Same escalation as `AgentRunner.killChild`.
    static let terminateGrace: TimeInterval = 3

    /// Read the child's output to the end, keeping the tail — bounded
    /// in TIME as well as in bytes.
    ///
    /// The pipe's write end is inherited by everything the child
    /// spawns, and `codex update` spawns `npm install -g`, so
    /// end-of-file arrives only when the LAST holder closes it — which
    /// can be an orphaned grandchild long after the child itself has
    /// exited or been terminated at the ceiling. A plain read-to-EOF
    /// therefore parks this thread, the update, and the row's
    /// "Updating…" on a process nobody can see, and a ceiling that
    /// terminates the CHILD frees none of it.
    ///
    /// So the read is polled. Once the child has exited, a pipe that
    /// stays silent for `orphanGrace` is abandoned; at the ceiling the
    /// child is stopped by PID and the drain ends whatever the pipe is
    /// doing. Closing our read end on the way out is what frees an
    /// orphan blocked in `write()`: its next write fails instead of
    /// waiting on a reader that has gone. Draining continuously is
    /// still what keeps a talkative child from blocking in `write()`
    /// while it is alive.
    nonisolated private static func drain(_ handle: FileHandle,
                                          of p: Process,
                                          ceiling: TimeInterval,
                                          outputCap: Int) -> String {
        let deadline = Date().addingTimeInterval(ceiling)
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var tail = Data()
        var quietSinceExit: Date? = nil
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 500)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready > 0 {
                // A raw read(2), NOT `FileHandle.readData(ofLength:)`:
                // on a pipe that call loops until it has the whole
                // length or end-of-file — measured returning 6 bytes
                // six seconds late, when a helper finally let go of
                // the pipe — which would put this loop straight back
                // to sleep on the writer it exists to outlive. After
                // poll(), one read returns whatever is there at once,
                // and 0 is end-of-file. errno is captured INSIDE the
                // closure that made the call — same rule as the
                // agent stdout reader.
                let (count, err): (Int, Int32) = buffer.withUnsafeMutableBytes { raw in
                    let n = read(fd, raw.baseAddress, raw.count)
                    return (n, n < 0 ? errno : 0)
                }
                if count < 0 {
                    if err == EINTR || err == EAGAIN { continue }
                    break
                }
                if count == 0 { break }
                tail.append(contentsOf: buffer[0..<count])
                if tail.count > outputCap {
                    tail.removeFirst(tail.count - outputCap)
                }
                quietSinceExit = nil
                continue
            }
            if Date() >= deadline {
                stop(p)
                break
            }
            if !p.isRunning {
                if let since = quietSinceExit {
                    if Date().timeIntervalSince(since) >= orphanGrace { break }
                } else {
                    quietSinceExit = Date()
                }
            }
        }
        // End-of-file from a child that is still running (it closed
        // its own stdio) is not a reason to kill it: give it the rest
        // of the ceiling to exit on its own, and only then stop it.
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        stop(p)
        p.waitUntilExit()
        try? handle.close()
        return String(data: tail, encoding: .utf8)
            ?? String(decoding: tail, as: UTF8.self)
    }

    /// Stop a child that is still running: SIGTERM, a grace period,
    /// then SIGKILL.
    ///
    /// The SIGTERM reaches the child's whole process GROUP: `Process`
    /// makes the child the leader of a group of its own, and
    /// `terminate()` signals that group — so an updater's own children
    /// get it too. `codex update`'s npm does, and on SIGTERM npm lets
    /// the step in flight (a download of minutes) finish before it rolls
    /// the install back, so a stopped update leaves the tool missing
    /// until then — which the monitor waits out (`awaitRestore`). The
    /// SIGKILL escalation goes to the pid alone.
    /// `isRunning` answers for this `Process` object's own unreaped
    /// child, so a recycled pid can never be signalled.
    nonisolated static func stop(_ p: Process) {
        guard p.isRunning else { return }
        p.terminate()
        let until = Date().addingTimeInterval(terminateGrace)
        while p.isRunning && Date() < until {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
}

// MARK: - Codex app-server calls

/// One request to `codex app-server`, and its answer.
///
/// `codex app-server` speaks JSON-RPC over stdio — the same door
/// codex's own desktop front-end goes through. The handshake is what
/// that front-end sends: `initialize` with a client name and version,
/// then the `initialized` notification; the request follows as a third
/// line, and the wait ends at the answer carrying its id. No model is
/// called and nothing is billed by anything sent this way.
///
/// stdin must stay OPEN until the answer arrives. The process exits at
/// end-of-file before answering anything still queued (measured), so
/// the request lines are written, the write end is held while the
/// answer is read, and only then closed — which is also what ends the
/// process cleanly. Everything else is the shape of `AgentCLIProbe`:
/// the environment an agent turn gets, a ceiling, the pid alone ever
/// signalled.
enum CodexAppServerCall {
    static let ceiling: TimeInterval = 30

    /// Static text — nothing user-derived reaches it.
    static let handshake: [String] = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"sipai","title":"SipAI","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#,
    ]

    /// The request id whose answer ends the wait. Every request handed
    /// to `run` carries it.
    static let answerId = 2

    /// The answer object — `result` or `error` under `answerId` — or
    /// nil for a codex with no app-server, one that exited first, or
    /// one that never answered inside the ceiling.
    nonisolated static func run(binary: String, request: String) async -> [String: Any]? {
        await run(binary: binary, requests: [request], awaiting: [answerId])[answerId]
    }

    /// Several requests down one process, answered by id. The wait
    /// ends when every awaited id has answered or at the ceiling;
    /// whatever answered by then is returned. Empty for a codex with
    /// no app-server or one that exited first.
    nonisolated static func run(binary: String, requests: [String],
                                awaiting: Set<Int>) async -> [Int: [String: Any]] {
        await ShellEnvironment.prepare()
        let environment = AgentRunner.buildEnvironment()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: drive(binary: binary,
                                                     requests: requests,
                                                     awaiting: awaiting,
                                                     environment: environment))
            }
        }
    }

    nonisolated private static func drive(binary: String, requests: [String],
                                          awaiting: Set<Int>,
                                          environment: [String: String]) -> [Int: [String: Any]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["app-server"]
        p.environment = environment
        let input = Pipe()
        let output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }

        // A child that exits before reading would make the write
        // SIGPIPE this process; the descriptor is told not to.
        let inFD = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(inFD, F_SETNOSIGPIPE, 1)
        let payload = Array(((handshake + requests).joined(separator: "\n") + "\n").utf8)
        var written = 0
        while written < payload.count {
            let n = payload[written...].withUnsafeBufferPointer { buf in
                write(inFD, buf.baseAddress, buf.count)
            }
            if n <= 0 { break }
            written += n
        }

        let outFD = output.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(ceiling)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var received = Data()
        var answered: [Int: [String: Any]] = [:]
        while !awaiting.isSubset(of: answered.keys), Date() < deadline {
            var pfd = pollfd(fd: outFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 250)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                if !p.isRunning { break }
                continue
            }
            // errno captured inside the closure that made the call —
            // the same rule as every other raw reader here.
            let (count, err): (Int, Int32) = buffer.withUnsafeMutableBytes { raw in
                let n = read(outFD, raw.baseAddress, raw.count)
                return (n, n < 0 ? errno : 0)
            }
            if count < 0 {
                if err == EINTR || err == EAGAIN { continue }
                break
            }
            if count == 0 { break }
            received.append(contentsOf: buffer[0..<count])
            // Notifications stream on the same channel; only the
            // answers are awaited, and nothing after them is needed.
            answered = answers(in: received, ids: awaiting)
            if received.count > 4 * 1024 * 1024 {
                received.removeFirst(received.count - 1024 * 1024)
            }
        }

        // Closing our end of its stdin is what ends a healthy
        // app-server; the escalation is for one that does not go.
        try? input.fileHandleForWriting.close()
        let until = Date().addingTimeInterval(AgentCLIProbe.terminateGrace)
        while p.isRunning && Date() < until {
            Thread.sleep(forTimeInterval: 0.05)
        }
        AgentCLIProbe.stop(p)
        p.waitUntilExit()
        try? output.fileHandleForReading.close()
        return answered
    }

    /// The first complete line so far that is the answer to `answerId`
    /// — a JSON object carrying that id and a result or an error.
    nonisolated static func answer(in data: Data) -> [String: Any]? {
        answers(in: data, ids: [answerId])[answerId]
    }

    /// The answers so far to each of `ids`, first complete line wins.
    nonisolated static func answers(in data: Data, ids: Set<Int>) -> [Int: [String: Any]] {
        var out: [Int: [String: Any]] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line)))
                    as? [String: Any],
                  let id = (obj["id"] as? NSNumber)?.intValue,
                  ids.contains(id), out[id] == nil,
                  obj["result"] != nil || obj["error"] != nil
            else { continue }
            out[id] = obj
        }
        return out
    }

    nonisolated static func containsAnswer(_ data: Data) -> Bool {
        answer(in: data) != nil
    }
}

// MARK: - Codex model list refresh

/// The one token-free way to make codex refetch its model catalog.
///
/// `model/list` is what fills the TUI's picker at bootstrap: answered
/// from `models_cache.json` while that is current for the running
/// client, fetched from the server — and written back to that file —
/// when it is not. One request in, one answer out, and codex decides
/// whether the network is involved. The answer names models but
/// carries no context windows, so the cache file stays the source for
/// those, and `CodexCatalog`'s fingerprint over it is what moves the
/// picker. What the answer IS read for is each model's service tiers
/// and their default (`CodexCatalog.listedTiers(fromAnswer:)`): it is
/// the installed binary's own view, where the cache may be another
/// codex client's.
enum CodexModelListRefresh {
    static let request =
        #"{"jsonrpc":"2.0","id":2,"method":"model/list","params":{}}"#

    /// True when `model/list` answered. False for a codex with no
    /// app-server, signed out, or offline — none of which changes
    /// anything on disk.
    nonisolated static func run(binary: String) async -> Bool {
        await answer(binary: binary) != nil
    }

    /// The answer object itself, or nil when there was none.
    nonisolated static func answer(binary: String) async -> [String: Any]? {
        await CodexAppServerCall.run(binary: binary, request: request)
    }
}

// MARK: - Codex config write

/// One key of the user's `~/.codex/config.toml`, written BY CODEX.
///
/// `config/value/write` is how codex's own front-end edits that file:
/// codex parses the file, sets or removes the key, validates the value
/// against its schema, and writes the rest back byte for byte. That is
/// the whole reason this app never edits the file itself — it is a
/// file three other clients read, in a format only codex has a parser
/// for. A JSON `null` value REMOVES the key (measured: the file came
/// back byte-identical to what it was before the key was added), which
/// is what makes "Back to default" a real absence rather than a second
/// number of ours.
///
/// `keyPath` is always a literal from the caller; the value is an
/// integer or nil. Nothing typed by a user is ever serialised into the
/// request.
enum CodexConfigWrite {
    enum Outcome: Equatable {
        /// Written. `overriddenBy` names a higher layer (a managed or
        /// project config) when codex reports the value will not take
        /// effect despite landing in the file.
        case written(version: String?, filePath: String?, overriddenBy: String?)
        /// Codex answered and declined, in its own words.
        case refused(code: String?, message: String)
        /// No codex, no app-server, or no answer inside the ceiling.
        case unavailable
    }

    /// The request line, built through `JSONSerialization` so the value
    /// is a JSON number or `null` and never text.
    nonisolated static func request(keyPath: String, value: Int?) -> String? {
        let params: [String: Any] = [
            "keyPath": keyPath,
            "value": value.map { NSNumber(value: $0) } ?? NSNull(),
            "mergeStrategy": "replace",
        ]
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": CodexAppServerCall.answerId,
            "method": "config/value/write",
            "params": params,
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func run(binary: String, keyPath: String, value: Int?) async -> Outcome {
        guard let line = request(keyPath: keyPath, value: value) else { return .unavailable }
        return outcome(from: await CodexAppServerCall.run(binary: binary, request: line))
    }

    /// The answer, read the way the protocol spells it: a `result` with
    /// `status`, `version`, `filePath` and an optional
    /// `overriddenMetadata`, or an `error` whose `data` carries
    /// `config_write_error_code` beside the message.
    nonisolated static func outcome(from answer: [String: Any]?) -> Outcome {
        guard let answer else { return .unavailable }
        if let result = answer["result"] as? [String: Any] {
            let overridden = (result["overriddenMetadata"] as? [String: Any])
                .flatMap { $0["message"] as? String }
            return .written(version: result["version"] as? String,
                            filePath: result["filePath"] as? String,
                            overriddenBy: overridden)
        }
        if let error = answer["error"] as? [String: Any] {
            let code = (error["data"] as? [String: Any])?["config_write_error_code"] as? String
            let message = (error["message"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 } ?? "config/value/write failed"
            return .refused(code: code, message: message)
        }
        return .unavailable
    }
}

// MARK: - Codex config read

extension CodexConfigRead {
    /// Codex's merged config for a turn in `cwd`, or nil for a codex
    /// with no app-server, one that refused, or no answer inside the
    /// ceiling.
    nonisolated static func run(binary: String, cwd: String) async -> [String: Any]? {
        guard let line = request(cwd: cwd, id: CodexAppServerCall.answerId) else { return nil }
        return config(fromAnswer: await CodexAppServerCall.run(binary: binary, request: line))
    }
}

// MARK: - The monitor

@MainActor
final class AgentCLIUpdateMonitor: ObservableObject {

    static let shared = AgentCLIUpdateMonitor()

    /// How often the release endpoints are asked. Deliberately coarse:
    /// nothing here is urgent, and a CLI release is a once-a-day event
    /// at most.
    static let remoteInterval: TimeInterval = 8 * 60 * 60

    /// Opening the update pane re-checks unless a check has succeeded
    /// this recently. Without the floor, clicking between settings tabs
    /// would be a network request per click.
    static let paneOpenFreshness: TimeInterval = 60 * 60

    /// How often the installed binaries are re-STATTED (not spawned —
    /// four stats per tool). This is what notices a CLI that updated
    /// itself, takes its badge down, and says "just updated" while that
    /// is still true; SipAI coming to the front re-stats too, which is
    /// what catches a `claude update` typed in a terminal at the moment
    /// the user comes back.
    static let localInterval: TimeInterval = 60

    /// Whether the release endpoints are asked at all. Off means this
    /// feature makes NO network request: the rows keep stating the
    /// installed version, which is a local read, and make no claim.
    /// Mac-only UI state, so UserDefaults rather than the config file
    /// the CLI shares, and absent means on. Registered in
    /// `FactoryReset.userDefaultsKeys`.
    static let remoteChecksDefaultsKey = "cliUpdateChecksEnabled"

    /// Whether a tool that is behind is updated without asking. Absent
    /// means OFF: running an updater changes a tool the user's own
    /// terminal runs too, so it happens only once they have said so.
    /// Same home and same registration as the switch above.
    static let autoUpdateDefaultsKey = "cliAutoUpdateEnabled"

    /// A `/latest` packument is tens of kilobytes and a plain-text
    /// version is a few bytes. Anything larger is not a version, and is
    /// not parsed.
    static let releasePayloadCap = 1024 * 1024

    /// The vendor's installer is a shell script of a few hundred lines.
    /// A body past this is not the script, whatever answered at the
    /// URL, and never reaches bash.
    static let installerScriptCap = 4 * 1024 * 1024

    /// The switch, for the pane's toggle.
    @Published private(set) var remoteChecksEnabled: Bool =
        (UserDefaults.standard.object(forKey: AgentCLIUpdateMonitor.remoteChecksDefaultsKey)
            as? Bool) ?? true

    /// The automatic-update switch, for the pane's toggle.
    @Published private(set) var autoUpdateEnabled: Bool =
        (UserDefaults.standard.object(forKey: AgentCLIUpdateMonitor.autoUpdateDefaultsKey)
            as? Bool) ?? false

    /// The row's claim, per agent key.
    @Published private(set) var statuses: [String: CLIUpdateStatus] = [:]

    /// The installed version, per agent key. Separate from `statuses`
    /// on purpose: the row prints the version in EVERY state, including
    /// the ones that make no claim about it.
    @Published private(set) var installed: [String: CLIVersion] = [:]

    /// Agents whose CLI is installed, in registry order. The rows.
    @Published private(set) var installedAgents: [AgentInfo] = []

    /// Agents whose running update the user has asked to stop.
    /// Published so the row can say "Cancelling…" while the child winds
    /// down — the status stays `.updating` for exactly that long.
    @Published private(set) var cancelling: Set<String> = []

    /// Agents the user unticked in Settings → Agent Guide. Nothing
    /// about a hidden tool is shown, asked or run: no badge, no release
    /// check, no automatic update. The installed VERSION is still read
    /// (a stat), because the Guide's dimmed row names it. Fed by
    /// `AgentManager` whenever presence is recomputed — the monitor
    /// never reads config itself.
    @Published private(set) var hiddenAgents: Set<String> = []

    func setHiddenAgents(_ keys: Set<String>) {
        guard keys != hiddenAgents else { return }
        hiddenAgents = keys
        // A tool just hidden drops its claim and badge at once; one
        // just unhidden is asked again if its last answer is stale.
        for key in keys { state[key]?.latest = nil; state[key]?.checkedAt = nil }
        publish()
        Task { await self.refreshRemote(force: false) }
    }

    private struct AgentState {
        var fingerprint: CLIBinaryFingerprint?
        var installed: CLIVersion?
        var latest: CLIVersion?
        var checkedAt: Date?
        /// What the ROW shows: the spinner. Stays up from the press
        /// until the child is confirmed gone — Cancel included, since a
        /// row that says "available" over a process still winding down
        /// is a lie the next click would act on.
        var updating = false
        /// Whether an updater is still winding down. Cleared only when
        /// the whole action finishes, which is what stops a Cancel
        /// followed immediately by Update from putting two updaters on
        /// one tool — the same hazard as two `claude -p` children
        /// driving one session.
        var updateInFlight = false
        var failureTail: String?
        /// The user pressed Cancel. A stopped update is not a failed
        /// one — the row goes back to what it said before rather than
        /// accusing the CLI of something the user did.
        var cancelRequested = false
        /// Held so Cancel can SIGTERM it, and so `isRunning` can rule
        /// out a recycled pid before the signal goes out.
        var updateProcess: Process?
        var checking = false
        /// Who has to update this install when the CLI's own updater
        /// declines to (`AgentInstallSource.managedBy`), read beside
        /// the version; nil for the ordinary case.
        var managedBy: String?
        /// Cancel for work that is no child process — the Guide's codex
        /// package download — handed in through
        /// `adoptExternalCancellation`, run by `cancelUpdate`.
        var cancelHook: (() -> Void)?
        /// The last time the endpoint was ASKED, success or not. Only
        /// the first-ever attempt is keyed on it: a CLI that detection
        /// finds late (kimi lives on the login shell's PATH, which is
        /// empty at launch) gets its first check when it appears rather
        /// than at the next 8-hour tick.
        var attemptedAt: Date?
        var readingVersion = false
    }

    private var state: [String: AgentState] = [:]
    private var remoteTimer: Timer?
    private var localTimer: Timer?
    private weak var config: ConfigManager?
    /// Whose turns are in flight — what an automatic update waits for.
    private weak var agents: AgentManager?
    private var turnWatch: AnyCancellable?
    private var activationWatch: AnyCancellable?
    /// Turns sent while their tool was being updated, resumed when that
    /// update ends (`waitForUpdate`).
    private let updateWaiters = UpdateWaitList()
    /// The version each tool's automatic update last tried, this launch.
    private var autoAttempted: [String: String] = [:]
    private var started = false

    private init() {}

    // MARK: Lifecycle

    /// Called once from `SipAIApp` after `agentManager.reload(config:)`.
    func start(config: ConfigManager, agents: AgentManager) {
        self.config = config
        self.agents = agents
        guard !started else { return }
        started = true
        // A turn ending is what an automatic update that is waiting
        // waits for. ASYNCHRONOUS on purpose: `@Published` emits from
        // `willSet`, so a synchronous sink would read the set before
        // the change it is being told about.
        turnWatch = agents.$inFlightSends.map { _ in () }
            .merge(with: agents.$externalInFlightSessions.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.autoUpdateIfDue() }
        // Coming back to SipAI is the moment a terminal `claude update`
        // is worth noticing: the user is looking, and "just updated" is
        // still true.
        activationWatch = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshLocal() }
            }
        refreshInstalledAgents()
        Task { await self.refreshLocal() }
        Task { await self.refreshRemote(force: true) }
        remoteTimer = Timer.scheduledTimer(
            withTimeInterval: Self.remoteInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshRemote(force: true)
            }
        }
        localTimer = Timer.scheduledTimer(
            withTimeInterval: Self.localInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshLocal()
            }
        }
    }

    /// Settings → Updates appeared. Re-reads the local versions always,
    /// and asks the network only if the last success is stale.
    func paneAppeared() {
        refreshInstalledAgents()
        Task { await self.refreshLocal() }
        Task { await self.refreshRemote(force: false) }
    }

    /// Settings → Agent Guide appeared. Local only, and deliberately:
    /// that pane prints the installed version and offers Install, Sign
    /// In, Sign out and Delete — no sentence on it rests on a release
    /// endpoint, so opening it must not send a request the user
    /// declined next door.
    func guideAppeared() {
        Task { await self.refreshLocal() }
    }

    /// Switch the release checks on or off.
    ///
    /// Off also drops every claim the checks earned. A row keeps its
    /// installed version, but "new version available" rests on a
    /// request the user has just declined to make, and a badge raised
    /// by one would keep pointing at it. On asks at once rather than at
    /// the next 8-hour tick, so the toggle answers immediately.
    func setRemoteChecksEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.remoteChecksDefaultsKey)
        applyRemoteChecks(enabled)
    }

    private func applyRemoteChecks(_ enabled: Bool) {
        guard enabled != remoteChecksEnabled else { return }
        remoteChecksEnabled = enabled
        if enabled {
            Task { await self.refreshRemote(force: true) }
        } else {
            for key in state.keys {
                state[key]?.latest = nil
                state[key]?.checkedAt = nil
            }
            publish()
        }
    }

    /// Switch automatic updates on or off.
    ///
    /// On acts at once on anything already known to be behind, rather
    /// than at the next check. Either way the badge is recomputed: a
    /// tool that updates itself is not something the user has to look
    /// at, and one that no longer does is.
    func setAutoUpdateEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.autoUpdateDefaultsKey)
        applyAutoUpdate(enabled)
    }

    private func applyAutoUpdate(_ enabled: Bool) {
        guard enabled != autoUpdateEnabled else { return }
        autoUpdateEnabled = enabled
        publish()
        autoUpdateIfDue()
    }

    /// A factory reset removed both switches' keys. The copies in memory
    /// follow — without writing the keys back — or the pane would keep
    /// showing the erased choices, and an automatic update would keep
    /// running on one, until a relaunch.
    func forgetSwitches() {
        applyRemoteChecks((UserDefaults.standard.object(forKey: Self.remoteChecksDefaultsKey)
                            as? Bool) ?? true)
        applyAutoUpdate((UserDefaults.standard.object(forKey: Self.autoUpdateDefaultsKey)
                          as? Bool) ?? false)
    }

    // MARK: Local layer

    /// `binaryPath(for:) != nil` is the same question
    /// `AgentManager.isInstalled` asks — same `searchPaths`, same
    /// executable test — and this needs the path anyway. A tool this
    /// monitor is updating keeps its row while its binary is briefly
    /// missing (`AgentCLIUpdateRules.countsAsInstalled`), the same rule
    /// `AgentManager.reload` applies to its section.
    private func refreshInstalledAgents() {
        let found = AgentManager.registry.filter {
            AgentCLIUpdateRules.countsAsInstalled(
                binaryFound: AgentManager.binaryPath(for: $0.key) != nil,
                updating: isUpdating($0.key))
        }
        if installedAgents != found { installedAgents = found }
    }

    /// Re-stat every installed CLI, and re-read the version only where
    /// the fingerprint moved.
    ///
    /// Idempotent by construction, which is what lets a pane's own
    /// appearance drive it: an unchanged fingerprint publishes nothing,
    /// so there is no path from "pane rendered" back to "pane
    /// re-rendered".
    func refreshLocal() async {
        refreshInstalledAgents()
        for agent in installedAgents {
            let key = agent.key
            if state[key]?.readingVersion == true { continue }
            let previous = state[key]?.fingerprint
            let current = await Task.detached(priority: .utility) {
                AgentCLIProbe.fingerprint(agentKey: key)
            }.value
            // A tool SipAI is updating, caught while npm has its link
            // moved aside: there is nothing to read, and a binary that is
            // missing for now has not moved. Read here, its version would
            // blank the row and its "move" would relearn every catalog
            // from a file that is not there; the update reads the new
            // binary itself when it ends.
            if current == nil, isUpdating(key) { continue }
            // Re-checked after the await: two of these can be in flight
            // (timer, pane, Guide), and the one that suspended second
            // would otherwise spawn a second `--version`.
            if state[key]?.readingVersion == true { continue }
            guard current != previous || state[key]?.installed == nil else { continue }
            state[key, default: AgentState()].readingVersion = true
            let (version, managedBy) = await Task.detached(priority: .utility) {
                let version = await AgentCLIProbe.installedVersion(agentKey: key,
                                                                   fingerprint: current)
                return (version, Self.managedBy(key))
            }.value
            var s = state[key] ?? AgentState()
            let versionBefore = s.installed
            s.readingVersion = false
            s.fingerprint = current
            s.installed = version
            s.managedBy = managedBy
            state[key] = s
            publish()
            // The binary MOVED under a running app — a terminal
            // `claude update`, the CLI's own auto-updater — and every
            // catalog latched on the old one is describing a file that
            // is gone. The same relearn the Update button runs, so
            // nothing can be forgotten here that it remembers there.
            // Gated on a previous sighting: the first stat of a launch
            // is not a move, and the launch already scrapes.
            if previous != nil, current != previous {
                relearnAfterUpdate(agentKey: key)
                // And said, the way SipAI's own update is — only for a
                // version that went UP (a reinstall or a touch moves the
                // fingerprint too), for a tool that is shown, and never
                // for an update SipAI is running itself: its finish
                // announces it, once.
                if let before = versionBefore, let after = version, after > before,
                   !hiddenAgents.contains(key), state[key]?.updateInFlight != true {
                    announceUpdate(agentKey: key, version: after)
                }
            }
        }
        // An agent whose CLI went away stops having a row, and stops
        // having remembered state to bring back if it returns at a
        // different version.
        // — but never while an action holds the slot. A tool the Guide
        // is INSTALLING has no binary yet, so it is not "live" here, and
        // pruning its state would take its Cancel with it: the download
        // would run to the end with nothing able to reach the child.
        let live = Set(installedAgents.map(\.key))
        for key in state.keys where !live.contains(key) {
            if state[key]?.updating == true || state[key]?.updateInFlight == true { continue }
            state.removeValue(forKey: key)
        }
        publish()
        // A CLI that appeared after launch has a row now and no verdict:
        // ask its endpoint once, now, rather than leaving it version-only
        // until the next 8-hour tick. `force: false` still skips every
        // agent with a fresh success, so this costs one request per
        // newly found tool and nothing per tick.
        let unasked = installedAgents.contains { agent in
            AgentCLIRelease.measured(agentKey: agent.key) != nil
                && state[agent.key]?.attemptedAt == nil
                && state[agent.key]?.checking != true
        }
        if unasked { Task { await self.refreshRemote(force: false) } }
        autoUpdateIfDue()
    }

    /// Version read that BYPASSES the fingerprint cache. The button's
    /// contract needs the value as of now, not as of the last stat.
    private func readInstalledNow(_ key: String) async -> CLIVersion? {
        let fingerprint = await Task.detached(priority: .utility) {
            AgentCLIProbe.fingerprint(agentKey: key)
        }.value
        let (version, managedBy) = await Task.detached(priority: .utility) {
            let version = await AgentCLIProbe.installedVersion(agentKey: key,
                                                               fingerprint: fingerprint)
            return (version, Self.managedBy(key))
        }.value
        var s = state[key] ?? AgentState()
        s.fingerprint = fingerprint
        s.installed = version
        s.managedBy = managedBy
        state[key] = s
        return version
    }

    /// Who has to update this install when the CLI's own updater
    /// declines to (`AgentInstallSource.managedBy`) — read beside the
    /// version, off the MainActor: it stats the link and its target and
    /// reads kimi's install record.
    nonisolated private static func managedBy(_ key: String) -> String? {
        AgentInstallSource.current(agentKey: key)?.managedBy(agentKey: key)
    }

    // MARK: Remote layer

    /// Ask each measured endpoint what the latest release is.
    ///
    /// A failure is silence. It does not clear `latest`, does not stamp
    /// `checkedAt`, and does not produce a row, a badge or an error —
    /// a machine that is merely offline must not be told anything about
    /// its tools, and must not be nagged about the network by an app
    /// whose job is elsewhere.
    ///
    /// `URLSession` applies the system proxy when one is configured and
    /// goes direct when none is. Nothing proxy-related is required,
    /// invented or configured here.
    func refreshRemote(force: Bool) async {
        // The one gate on every request this feature makes. The timers
        // keep firing; they find this and go back to sleep.
        guard remoteChecksEnabled else { return }
        for agent in installedAgents where !hiddenAgents.contains(agent.key) {
            let key = agent.key
            guard var release = AgentCLIRelease.measured(agentKey: key) else { continue }
            if state[key]?.checking == true { continue }
            if !force, let last = state[key]?.checkedAt,
               Date().timeIntervalSince(last) < Self.paneOpenFreshness { continue }
            state[key, default: AgentState()].checking = true
            state[key]?.attemptedAt = Date()
            // Claude's native updater follows the channel its settings
            // name; the check reads the same tag, or a stable-channel
            // install reads as behind for as long as the tags differ.
            if key == "claude_code" {
                let settings = await Task.detached(priority: .utility) {
                    PlanAccountDetector.claudeSettingsFiles.compactMap { try? Data(contentsOf: $0) }
                }.value
                release = release.onChannel(AgentCLIRelease.claudeChannel(settings: settings))
            }
            var request = URLRequest(url: release.latestURL,
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 15)
            request.httpMethod = "GET"
            let found: CLIVersion? = await {
                guard let (data, response) = try? await URLSession.shared
                        .data(for: request) else { return nil }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      data.count <= Self.releasePayloadCap else { return nil }
                return release.version(from: data)
            }()
            var s = state[key] ?? AgentState()
            s.checking = false
            // The switch can have gone off while the request was in
            // flight; an answer landing then would show the claim and
            // the badge the switch says are not made.
            if let found, remoteChecksEnabled {
                s.latest = found
                s.checkedAt = Date()
            }
            state[key] = s
            publish()
        }
        autoUpdateIfDue()
    }

    // MARK: Action layer

    /// Whether an update action is still in progress for this agent —
    /// from the press until the child is confirmed gone, a Cancel
    /// included. The row disables its Update button on this, so a click
    /// during the wind-down is refused visibly rather than swallowed by
    /// the re-entrancy guard in `update(agentKey:)`.
    func updateInFlight(_ key: String) -> Bool {
        state[key]?.updateInFlight ?? false
    }

    /// Update a tool — the one road for the row's Update button and the
    /// automatic update alike. A codex SipAI installed is updated by
    /// SipAI, since `codex update` declines that layout (measured);
    /// every other tool runs its own updater. Keyed on the latest
    /// release KNOWN, not on the row's status: a retry after a failed
    /// update would otherwise send an owned codex to `codex update`.
    /// True when an update actually started — false when the slot was
    /// already held (an update, or the Guide's probe, install, sign-in
    /// or delete on that tool).
    @discardableResult
    func startUpdate(agentKey key: String) -> Bool {
        if key == "codex",
           AgentInstallSource.current(agentKey: key)?.isOwnedBySipAI == true,
           let latest = state[key]?.latest {
            return AgentGuideActions.shared.updateOwnedCodex(latest: latest)
        } else {
            return update(agentKey: key)
        }
    }

    /// Start the automatic update of every tool that is behind, if the
    /// user asked for that — called after every check, every re-stat,
    /// every turn that starts or ends, and the switch itself. Each call
    /// is cheap and decides nothing twice: a tool with an action in
    /// flight, a turn in flight, or this version already tried is left
    /// alone (`AgentCLIUpdateRules.autoUpdateIsDue`).
    private func autoUpdateIfDue() {
        guard autoUpdateEnabled, remoteChecksEnabled else { return }
        for agent in installedAgents where !hiddenAgents.contains(agent.key) {
            let key = agent.key
            guard AgentCLIRelease.measured(agentKey: key) != nil,
                  let latest = state[key]?.latest else { continue }
            let due = AgentCLIUpdateRules.autoUpdateIsDue(
                enabled: true,
                status: statuses[key] ?? .unknown,
                latest: latest,
                actionInFlight: state[key]?.updateInFlight == true,
                // Unknowable without the manager, and never guessed:
                // an update that cannot see the turns does not start.
                turnInFlight: agents?.hasTurnInFlight(agentKey: key) ?? true,
                attemptedVersion: autoAttempted[key])
            guard due else { continue }
            // The one attempt per version is spent only once an update
            // has actually started: a start refused — the Guide holds
            // the tool for a probe or a sign-in at that moment — leaves
            // the version to be tried at the next call, rather than
            // forfeited with nothing on the badge to say so.
            if startUpdate(agentKey: key) { autoAttempted[key] = latest.text }
        }
    }

    /// Whether this tool's update starts by itself once no turn of it is
    /// running — what the row's disabled Update button says on hover.
    /// The same rule as `autoUpdateIfDue`, with the turn left out.
    func updatesAutomaticallyWhenIdle(_ key: String) -> Bool {
        guard autoUpdateEnabled, remoteChecksEnabled,
              !hiddenAgents.contains(key),
              AgentCLIRelease.measured(agentKey: key) != nil else { return false }
        return AgentCLIUpdateRules.autoUpdateIsDue(
            enabled: true,
            status: statuses[key] ?? .unknown,
            latest: state[key]?.latest,
            actionInFlight: state[key]?.updateInFlight == true,
            turnInFlight: false,
            attemptedVersion: autoAttempted[key])
    }

    /// Run the CLI's own updater.
    ///
    /// The race rule, in order: re-read the installed version FIRST and
    /// run nothing if it is already current; spawn; re-read again on
    /// exit and let the two readings decide the verdict.
    ///
    /// The slot is claimed HERE, before anything suspends, so a press
    /// and an automatic start in the same moment cannot both pass the
    /// guard and put two updaters on one tool — and so a turn sent from
    /// this moment on already sees the update and waits for it.
    @discardableResult
    func update(agentKey key: String) -> Bool {
        guard state[key]?.updateInFlight != true else { return false }
        guard let release = AgentCLIRelease.measured(agentKey: key) else { return false }
        var claim = state[key] ?? AgentState()
        claim.updateInFlight = true
        claim.updating = true
        claim.failureTail = nil
        claim.cancelRequested = false
        state[key] = claim
        publish()
        Task { @MainActor in
            let before = await readInstalledNow(key)
            // Cancel may have landed during that read. Nothing has been
            // spawned, so there is nothing to stop — the action simply
            // ends, and a stopped update is not a failed one.
            if state[key]?.cancelRequested == true {
                finishUpdate(key: key, verdict: .didNotUpdate, tail: "",
                             exitCode: nil)
                return
            }
            let latest = state[key]?.latest
            switch AgentCLIUpdateRules.updateAction(installedNow: before,
                                                    latestKnown: latest) {
            case .alreadyCurrent(let current):
                finishUpdate(key: key, verdict: .alreadyCurrent(current),
                             tail: "", exitCode: nil)
                return
            case .run:
                break
            }

            guard let binary = AgentManager.binaryPath(for: key) else {
                finishUpdate(key: key, verdict: .didNotUpdate, tail: "",
                             exitCode: nil)
                return
            }
            let startedAt = Date()
            let result = await AgentCLIProbe.run(
                binary: binary,
                arguments: release.updateArguments,
                ceiling: AgentCLIProbe.updateCeiling,
                outputCap: AgentCLIProbe.outputTailCap,
                onSpawn: { [weak self] process in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // The user may have cancelled between the
                        // decision to spawn and the spawn landing.
                        guard self.state[key]?.cancelRequested != true else {
                            Self.stopLater(process)
                            return
                        }
                        self.state[key]?.updateProcess = process
                    }
                })
            state[key]?.updateProcess = nil
            await awaitRestore(of: key, byGroup: result.processGroup,
                               until: startedAt.addingTimeInterval(AgentCLIProbe.updateCeiling))
            let after = await readInstalledNow(key)
            let verdict = AgentCLIUpdateRules.updateVerdict(
                before: before, after: after, latestKnown: state[key]?.latest)

            // The CLI's own updater declined and named the vendor's
            // installer as the manual route — or could not even check,
            // on a machine whose install record says native. Do that
            // step for the user: the ONE case in which anything other
            // than the CLI's update command runs, and only under every
            // condition below at once. The record is read HERE, off the
            // rule, so the rule stays a pure function of what it is
            // handed.
            let installRecord = try? Data(contentsOf:
                AgentCLIRelease.nativeInstallRecordURL(home: KimiSessionScanner.home))
            let installerRoute = release.declinedToNativeInstaller(in: result.output)
                ?? release.nativeInstallerAfterFailedCheck(in: result.output,
                                                           installRecord: installRecord)
            if case .didNotUpdate = verdict,
               state[key]?.cancelRequested != true,
               let latest = state[key]?.latest,
               let installer = installerRoute,
               let installDirectory = AgentCLIRelease
                    .nativeInstallDirectory(binaryPath: binary,
                                            kimiHome: KimiSessionScanner.home.path) {
                let installerOutput = await runNativeInstaller(
                    installer, installDirectory: installDirectory,
                    version: latest, key: key)
                state[key]?.updateProcess = nil
                let installed = await readInstalledNow(key)
                let secondVerdict = AgentCLIUpdateRules.updateVerdict(
                    before: before, after: installed, latestKnown: state[key]?.latest)
                finishUpdate(key: key, verdict: secondVerdict,
                             tail: result.output + "\n\n" + installerOutput,
                             exitCode: nil)
                return
            }
            finishUpdate(key: key, verdict: verdict, tail: result.output,
                         exitCode: result.exitCode)
        }
        return true
    }

    /// The updater has exited; wait while what it started is still putting
    /// the tool back.
    ///
    /// Stopping an update SIGTERMs the updater's whole process group
    /// (`AgentCLIProbe.stop`), npm under `codex update` with it, and npm
    /// answers SIGTERM by letting the step in flight — a download of
    /// minutes — run to its end, then rolling the install back. The
    /// updater itself is gone within a second, and until npm is done the
    /// tool's binary is missing. So the update is not over while the
    /// binary is missing and anything of that group is still alive: the
    /// row keeps its spinner ("Cancelling…"), the tool stays listed, and
    /// a send keeps waiting. It ends when the binary is back, when
    /// nothing of the group is left to bring it back, or at the update's
    /// own ceiling. A binary that is present ends it at once, so a
    /// long-lived helper the updater leaves behind never holds the row.
    private func awaitRestore(of key: String, byGroup group: pid_t?,
                              until deadline: Date) async {
        guard let group else { return }
        while Date() < deadline {
            let present = await Task.detached(priority: .utility) {
                AgentManager.binaryPath(for: key) != nil
            }.value
            if present || !AgentCLIProbe.groupIsAlive(group) { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Download the vendor's installer over SipAI's own connection and
    /// run it through its documented non-interactive interface. Returns
    /// the installer's output tail, or a sentence saying why it never
    /// ran. The script is exactly what the CLI told the user to pipe
    /// into bash; fetching it here means it goes through the system
    /// proxy where the CLI's own fetch may not, and staging it in a
    /// private temp directory means it is the bytes that were
    /// downloaded that run, not a second fetch. The script verifies the
    /// binary it downloads against the vendor's manifest checksum
    /// itself.
    private func runNativeInstaller(_ installer: URL,
                                    installDirectory: String,
                                    version: CLIVersion,
                                    key: String) async -> String {
        await runInstallerScript(
            installer,
            arguments: { script in
                AgentCLIRelease.nativeInstallerArguments(script: script, version: version.text)
            },
            environment: AgentCLIRelease.nativeInstallerEnvironment(installDirectory: installDirectory),
            key: key)
    }

    /// The vendor's installer script, fetched over SipAI's own
    /// connection and run non-interactively — the route kimi's native
    /// UPDATE takes, and the route a fresh INSTALL of claude or kimi
    /// takes from the Agent Guide (`AgentGuideActions`), which is why
    /// it is not private. `arguments` is handed the staged script's
    /// path; `environment` rides on top of the agent-turn environment.
    /// Returns the script's output tail, or a sentence saying why it
    /// never ran. Cancel goes through `state[key].updateProcess`, the
    /// same handle the update route uses.
    func runInstallerScript(_ installer: URL,
                            arguments: (String) -> [String],
                            environment: [String: String],
                            key: String) async -> String {
        let request = URLRequest(url: installer,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              // What is about to run must have arrived over TLS end to
              // end — the URL is https, and this refuses a redirect off
              // it — and be the size of a script rather than of
              // whatever else answered there.
              http.url?.scheme?.lowercased() == "https",
              data.count <= Self.installerScriptCap,
              !data.isEmpty
        else {
            return String(localized: "The installer could not be downloaded from \(installer.absoluteString).",
                          comment: "Updates pane detail: the vendor's installer script did not download; placeholder is its URL")
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("sipai-installer-\(UUID().uuidString)",
                                    isDirectory: true)
        let script = dir.appendingPathComponent("install.sh")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])) != nil,
              (try? data.write(to: script, options: .atomic)) != nil
        else {
            return String(localized: "The installer could not be staged on disk.",
                          comment: "Updates pane detail: the downloaded installer script could not be written to a temporary folder")
        }
        defer { try? fm.removeItem(at: dir) }
        let result = await AgentCLIProbe.run(
            binary: "/bin/bash",
            arguments: arguments(script.path),
            ceiling: AgentCLIProbe.updateCeiling,
            outputCap: AgentCLIProbe.outputTailCap,
            extraEnvironment: environment,
            onSpawn: { [weak self] process in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.state[key]?.cancelRequested != true else {
                        Self.stopLater(process)
                        return
                    }
                    self.state[key]?.updateProcess = process
                }
            })
        return result.output
    }

    /// The Agent Guide's install and delete run their children through
    /// this monitor's process slot so their Cancel is the same
    /// SIGTERM-then-SIGKILL the update route has. `begin` claims the
    /// slot (false if an update or another action already holds it);
    /// `end` releases it.
    func beginExternalAction(agentKey key: String) -> Bool {
        guard state[key]?.updateInFlight != true else { return false }
        var s = state[key] ?? AgentState()
        s.updateInFlight = true
        s.cancelRequested = false
        s.updateProcess = nil
        state[key] = s
        return true
    }

    func endExternalAction(agentKey key: String) {
        state[key]?.updateInFlight = false
        state[key]?.updateProcess = nil
        state[key]?.cancelHook = nil
        state[key]?.cancelRequested = false
        cancelling.remove(key)
        publish()
    }

    /// The Guide's owned-codex route is an UPDATE — the row's Update
    /// button is what starts it — so it holds the slot as one: the
    /// spinner goes up where the button was, Cancel reaches it through
    /// `cancelUpdate`, and its verdict lands through `finishUpdate`,
    /// where the row reads. `beginExternalAction` alone claims the slot
    /// SILENTLY, which is right for an install or a delete (the Guide
    /// draws those) and wrong here: nothing is published, so the row
    /// keeps offering a button the slot then refuses, and the outcome
    /// lands in a pane the click did not happen in — or nowhere.
    func beginExternalUpdate(agentKey key: String) -> Bool {
        guard beginExternalAction(agentKey: key) else { return false }
        state[key]?.updating = true
        state[key]?.failureTail = nil
        publish()
        return true
    }

    /// The end of an external update: the same rule the CLI's own
    /// updater is judged by — the version MOVING, never an exit code —
    /// and the same finish, so a stop is not a failure and a failure is
    /// reported where the button is.
    func finishExternalUpdate(agentKey key: String,
                              before: CLIVersion?,
                              after: CLIVersion?,
                              tail: String) {
        let verdict = AgentCLIUpdateRules.updateVerdict(
            before: before, after: after, latestKnown: state[key]?.latest)
        finishUpdate(key: key, verdict: verdict, tail: tail, exitCode: nil)
    }

    /// Whether Cancel was pressed during an external action.
    func externalActionCancelled(agentKey key: String) -> Bool {
        state[key]?.cancelRequested == true
    }

    /// Hand a spawned child to the slot so Cancel can reach it; a
    /// Cancel that already landed stops it at once.
    func adoptExternalProcess(_ process: Process, agentKey key: String) {
        guard state[key]?.cancelRequested != true else {
            Self.stopLater(process)
            return
        }
        state[key]?.updateProcess = process
    }

    /// Hand the slot a way to stop work that is no child process — the
    /// Guide's codex package download, a `URLSession` task — so Cancel
    /// reaches it the way `adoptExternalProcess` lets it reach a child.
    /// A Cancel that already landed runs it at once. One hook per slot:
    /// the route hands in the transfer in flight, and a stale hook on a
    /// finished task is a no-op.
    func adoptExternalCancellation(agentKey key: String, _ cancel: @escaping () -> Void) {
        guard state[key]?.cancelRequested != true else {
            cancel()
            return
        }
        state[key]?.cancelHook = cancel
    }

    /// The monitor's own state for an agent whose binary the Guide
    /// removed: nothing about it is known any more.
    func forgetAgent(agentKey key: String) {
        state[key] = nil
        refreshInstalledAgents()
        publish()
        resumeUpdateWaiters(key)
    }

    /// Stop the updater. The spinner stays until `finishUpdate` confirms
    /// the child is gone, and whatever it started has put the tool back
    /// (`awaitRestore`) — only the row's label changes — because a row
    /// that has gone back to offering Update over a process still
    /// winding down invites the click the re-entrancy guard would then
    /// swallow. If nothing has been spawned yet, the action sees the
    /// flag after its version read and ends without spawning.
    func cancelUpdate(agentKey key: String) {
        guard state[key]?.updateInFlight == true else { return }
        state[key]?.cancelRequested = true
        cancelling.insert(key)
        if let process = state[key]?.updateProcess { Self.stopLater(process) }
        if let hook = state[key]?.cancelHook {
            state[key]?.cancelHook = nil
            hook()
        }
    }

    /// SIGTERM now, SIGKILL after the grace if it is ignored — off the
    /// MainActor, which must not sleep through the grace. What each
    /// signal reaches is `AgentCLIProbe.stop`'s rule; `isRunning` on this
    /// `Process` object rules out a recycled pid.
    private static func stopLater(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + AgentCLIProbe.terminateGrace
        ) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func finishUpdate(key: String,
                              verdict: AgentCLIUpdateRules.UpdateVerdict,
                              tail: String,
                              exitCode: Int32?) {
        var s = state[key] ?? AgentState()
        s.updating = false
        s.updateInFlight = false
        s.updateProcess = nil
        s.cancelHook = nil
        let cancelled = s.cancelRequested
        s.cancelRequested = false
        cancelling.remove(key)
        switch verdict {
        case .updated, .alreadyCurrent:
            s.failureTail = nil
        case .didNotUpdate where cancelled:
            // Stopped on request. The row returns to naming the update
            // that is still available; nothing failed.
            s.failureTail = nil
        case .didNotUpdate:
            // Reported, never swallowed. An update that quietly did
            // nothing, on a row that goes back to offering the same
            // button, is the shape of a bug the user cannot diagnose —
            // and for at least one agent the output IS the answer.
            let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            // An updater that said nothing still gets a sentence. An
            // empty tail is filtered out by `publish`, which would put
            // the row straight back on the same Update button as if
            // nothing had happened — the exact silence this row exists
            // to end.
            s.failureTail = trimmed.isEmpty
                ? Self.silentUpdaterExplanation(exitCode: exitCode)
                : trimmed
        }
        state[key] = s
        // The rows follow the binary again now that the update no longer
        // holds them — at once, rather than at the next re-stat: the new
        // version shows the moment it landed, and a tool whose binary is
        // still missing (an updater stopped half way) goes.
        refreshInstalledAgents()
        publish()
        // The binary is settled, whatever the verdict: a turn sent
        // during the update runs now, on whichever version is there.
        resumeUpdateWaiters(key)

        if case .updated(let version) = verdict {
            relearnAfterUpdate(agentKey: key)
            // Said for every update that landed — pressed or automatic
            // alike. A failure is not announced: the row says why, and
            // the badge carries it.
            announceUpdate(agentKey: key, version: version)
        }
    }

    // MARK: A turn sent during an update

    /// Whether SipAI is updating this tool right now — from the claim
    /// until the finish, the stretch in which a turn must not start: an
    /// npm install removes and rewrites the package in place, and a
    /// spawn in the middle finds half a tool.
    func isUpdating(_ key: String) -> Bool {
        state[key]?.updating == true
    }

    /// Returns once SipAI's update of this tool has finished — at once
    /// when none is running. A Stop meanwhile is the caller's to notice
    /// when this returns.
    func waitForUpdate(agentKey key: String) async {
        await updateWaiters.wait(for: key) { self.isUpdating(key) }
    }

    private func resumeUpdateWaiters(_ key: String) {
        updateWaiters.release(key)
    }

    /// "Claude Code just updated to 2.1.290", beside the sidebar's logo.
    /// Through the label, like every sentence that names an agent.
    private func announceUpdate(agentKey key: String, version: CLIVersion) {
        let name = AgentManager.registry.first { $0.key == key }?.name ?? key
        let label = config?.agentLabel(for: key, defaultName: name) ?? name
        UpdateAnnouncer.shared.announce(
            String(localized: "\(label) just updated to \(version.text)",
                   comment: "Sidebar, in place of the SipAI wordmark for a few seconds: a command-line tool (or SipAI itself) has just been updated; placeholders are the tool's label and the new version number"))
    }

    private static func silentUpdaterExplanation(exitCode: Int32?) -> String {
        if let exitCode {
            return String(localized: "The updater printed nothing and exited with code \(Int(exitCode)).",
                          comment: "Updates pane detail: the CLI's updater produced no output and the installed version did not change; placeholder is the exit code")
        }
        return String(localized: "The updater printed nothing and did not exit cleanly.",
                      comment: "Updates pane detail: the CLI's updater produced no output, was stopped or could not be started, and the installed version did not change")
    }

    /// A new binary knows different modes, models and aliases — and
    /// resolves each alias to a different model. The catalogs that
    /// read those are latched on the binary they read, so without this
    /// an update leaves every picker describing the binary that was
    /// just replaced until something re-reads it. Called for the
    /// button's own update and for any fingerprint move the passive
    /// tick notices.
    /// Internal: the Agent Guide's install and its owned-codex update
    /// relearn the same way.
    func relearnAfterUpdate(agentKey key: String) {
        // The plan-usage verdict was measured against the old binary;
        // the file layer answers until the window next opens.
        UsageMonitor.shared.noteBinaryChanged(agentKey: key)
        switch key {
        case "claude_code":
            ClaudeCapabilities.shared.reloadAfterBinaryChange()
            ClaudeModelCatalog.forgetHarvest()
            if let config {
                ClaudeModelCatalog.refreshObservedNames(config: config,
                                                        sessionURLs: [])
            }
        case "codex":
            CodexCatalog.shared.reloadAfterBinaryChange()
        default:
            // Kimi's catalog fingerprints its own config file and
            // re-reads on change, so it needs no prompting.
            break
        }
    }

    // MARK: Derivation

    /// One place where state becomes what the UI reads, so a status and
    /// the badge it raises can never describe different moments.
    /// Assign-only-on-change: this runs from two timers and every
    /// probe, and identical reassignment would re-render the window for
    /// nothing.
    private func publish() {
        var newStatuses: [String: CLIUpdateStatus] = [:]
        var newInstalled: [String: CLIVersion] = [:]
        for agent in installedAgents {
            let s = state[agent.key]
            if let v = s?.installed { newInstalled[agent.key] = v }
            // No measured endpoint: the row may state the version and
            // nothing else, whatever else happens to be known.
            let base: CLIUpdateStatus
            if AgentCLIRelease.measured(agentKey: agent.key) == nil {
                base = s?.installed.map { CLIUpdateStatus.versionOnly(installed: $0) }
                    ?? .unknown
            } else {
                base = AgentCLIUpdateRules.decideStatus(
                    installed: s?.installed,
                    latestKnown: s?.latest,
                    lastCheckSucceeded: s?.checkedAt,
                    managedBy: s?.managedBy)
            }
            if s?.updating == true {
                newStatuses[agent.key] = .updating
            } else if let tail = s?.failureTail, !tail.isEmpty,
                      case .updateAvailable = base {
                // A failure is only interesting while the tool is still
                // behind. Once it is current — by our button, its own
                // updater or a terminal — the row says so and the tail
                // goes with the problem it described.
                newStatuses[agent.key] = .updateFailed(outputTail: tail)
            } else {
                newStatuses[agent.key] = base
            }
        }
        // What the Settings badge counts: a hidden tool is on offer to
        // nobody, and a tool that updates itself only once its update
        // has failed.
        let badge: [UpdateBadgeItem] = installedAgents.compactMap { agent in
            guard !hiddenAgents.contains(agent.key),
                  let status = newStatuses[agent.key],
                  let version = AgentCLIUpdateRules.badgeVersion(
                    status: status, latest: state[agent.key]?.latest,
                    autoUpdate: autoUpdateEnabled)
            else { return nil }
            return .cli(agentKey: agent.key, version: version)
        }
        if statuses != newStatuses { statuses = newStatuses }
        if installed != newInstalled { installed = newInstalled }
        UpdateBadge.shared.setCLIItems(badge)
    }
}
