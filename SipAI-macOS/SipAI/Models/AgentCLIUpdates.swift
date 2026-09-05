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
//     touch.
//
// The rule that shapes all of it: **never claim, never nag, without
// evidence.** A check that failed downgrades nothing and says nothing;
// an agent nobody has measured a release endpoint for shows its version
// and no verdict at all. Absence of a claim is the honest state, and it
// is a different thing from "up to date".

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

    /// Whether an Update button belongs on this row at all.
    var offersUpdate: Bool {
        switch self {
        case .updateAvailable, .updateFailed: return true
        case .unknown, .versionOnly, .upToDate, .updating: return false
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
    static func decideStatus(installed: CLIVersion?,
                             latestKnown: CLIVersion?,
                             lastCheckSucceeded: Date?) -> CLIUpdateStatus {
        guard let installed else { return .unknown }
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

    /// Whether a banner is owed for this agent, given what the user has
    /// already closed.
    ///
    /// Keyed on the VERSION, not on the agent: closing the banner
    /// suppresses that release and nothing else, so the next one
    /// raises it again. A status that is no longer `updateAvailable`
    /// simply produces no banner — which is how a CLI that updated
    /// itself clears the notice without anything being written down.
    static func bannerIsOwed(status: CLIUpdateStatus,
                             dismissedVersion: String?) -> Bool {
        guard case .updateAvailable(_, let latest) = status else { return false }
        return dismissedVersion != latest.text
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
    /// The vendor's own installer, for an agent whose update command
    /// DECLINES on some install source and names this script as the
    /// manual route instead (kimi on a native install, measured). Run
    /// only when the decline is recognised — see
    /// `declinedToNativeInstaller(in:)`. nil for everyone else.
    var nativeInstaller: URL? = nil

    /// The installer kimi's updater names when it declines a native
    /// install — measured text: "A newer version … is available … /
    /// Detected install source: native installer / To update manually,
    /// run: curl -fsSL https://code.kimi.com/kimi-code/install.sh |
    /// bash". Returns the installer only when the URL in that sentence
    /// is EXACTLY the measured one: kimi's words are trusted to say it
    /// declined, never to name an arbitrary script to run.
    func declinedToNativeInstaller(in output: String) -> URL? {
        guard let installer = nativeInstaller,
              let regex = try? NSRegularExpression(
                pattern: #"To update manually, run:\s*curl\s+-fsSL\s+(\S+)\s*\|\s*bash"#)
        else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              match.numberOfRanges > 1,
              let found = Range(match.range(at: 1), in: output),
              URL(string: String(output[found])) == installer
        else { return nil }
        return installer
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
        nativeInstaller != nil
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
    /// directory, the script — is already known.
    func nativeInstallerAfterFailedCheck(in output: String,
                                         installRecord: Data?) -> URL? {
        guard let installer = nativeInstaller,
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
    /// holds it (`~/.kimi-code/bin/kimi` → `~/.kimi-code`). nil for any
    /// other layout — the installer is never pointed anywhere it did
    /// not put the binary itself.
    static func nativeInstallDirectory(binaryPath: String) -> String? {
        let resolved = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath()
        let bin = resolved.deletingLastPathComponent()
        guard bin.lastPathComponent == "bin" else { return nil }
        return bin.deletingLastPathComponent().path
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
            guard let url = URL(string:
                "https://code.kimi.com/kimi-code/latest"),
                  let installer = URL(string:
                "https://code.kimi.com/kimi-code/install.sh")
            else { return nil }
            return AgentCLIRelease(agentKey: agentKey, latestURL: url,
                                   payload: .plainText,
                                   updateArguments: ["upgrade"],
                                   nativeInstaller: installer)
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
                onSpawn(p)

                let output = drain(pipe.fileHandleForReading, of: p,
                                   ceiling: ceiling, outputCap: outputCap)
                // Never read `terminationStatus` on a live process —
                // Foundation raises. `drain` has waited the child out,
                // but the guard costs nothing and the rule is absolute.
                let code: Int32? = p.isRunning ? nil : p.terminationStatus
                continuation.resume(returning: RunResult(exitCode: code,
                                                         output: output))
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
    /// then SIGKILL. The pid ONLY, never the process group: Foundation
    /// cannot put the child in a group of its own, so its group is
    /// SipAI's, and `kill(-pgid)` would take the app down with it.
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

// MARK: - Codex model list refresh

/// The one token-free way to make codex refetch its model catalog.
///
/// `codex app-server` speaks JSON-RPC over stdio, and `model/list` is
/// what fills the TUI's picker at bootstrap: answered from
/// `models_cache.json` while that is current for the running client,
/// fetched from the server — and written back to that file — when it is
/// not. Three lines in, one answer out, and codex decides whether the
/// network is involved. The answer itself is not what SipAI reads: it
/// names models but carries no context windows, so the cache file stays
/// the source and `CodexCatalog`'s fingerprint over it is what moves
/// the picker.
///
/// stdin must stay OPEN until the answer arrives. The process exits at
/// end-of-file before answering anything still queued (measured), so
/// the request lines are written, the write end is held while the
/// answer is read, and only then closed — which is also what ends the
/// process cleanly. Everything else is the shape of `AgentCLIProbe`:
/// the environment an agent turn gets, a ceiling, the pid alone ever
/// signalled.
enum CodexModelListRefresh {
    static let ceiling: TimeInterval = 30

    /// What codex's own front-end sends: `initialize` with a client
    /// name and version, the `initialized` notification, then the
    /// request. Static text — nothing user-derived reaches it.
    static let requests: [String] = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"sipai","title":"SipAI","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"model/list","params":{}}"#,
    ]

    /// The request id whose answer ends the wait.
    static let answerId = 2

    /// True when `model/list` answered. False for a codex with no
    /// app-server, signed out, or offline — none of which changes
    /// anything on disk.
    nonisolated static func run(binary: String) async -> Bool {
        await ShellEnvironment.prepare()
        let environment = AgentRunner.buildEnvironment()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: drive(binary: binary,
                                                     environment: environment))
            }
        }
    }

    nonisolated private static func drive(binary: String,
                                          environment: [String: String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["app-server"]
        p.environment = environment
        let input = Pipe()
        let output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }

        // A child that exits before reading would make the write
        // SIGPIPE this process; the descriptor is told not to.
        let inFD = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(inFD, F_SETNOSIGPIPE, 1)
        let payload = Array((requests.joined(separator: "\n") + "\n").utf8)
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
        var answered = false
        while !answered, Date() < deadline {
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
            // answer is awaited, and nothing after it is needed.
            answered = containsAnswer(received)
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

    /// Whether a complete line so far is the answer to `answerId` — a
    /// JSON object carrying that id and a result or an error.
    nonisolated static func containsAnswer(_ data: Data) -> Bool {
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line)))
                    as? [String: Any],
                  (obj["id"] as? NSNumber)?.intValue == answerId,
                  obj["result"] != nil || obj["error"] != nil
            else { continue }
            return true
        }
        return false
    }
}

// MARK: - The monitor

/// One banner row: an installed CLI that is behind, and has not been
/// closed at this version.
struct CLIUpdateBannerItem: Identifiable, Equatable {
    let agentKey: String
    /// The registry name, for `config.agentLabel(for:defaultName:)`.
    /// No user-visible sentence in this app names an agent outright.
    let defaultName: String
    let latest: CLIVersion
    var id: String { agentKey }
}

@MainActor
final class AgentCLIUpdateMonitor: ObservableObject {

    static let shared = AgentCLIUpdateMonitor()

    /// Dismissed banners, agent key → the version that was closed.
    /// Mac-only UI state, so UserDefaults rather than config.json —
    /// the CLI shares that file and has no use for this. Registered in
    /// `FactoryReset.userDefaultsKeys`.
    static let dismissalsDefaultsKey = "cliUpdateDismissed"

    /// How often the release endpoints are asked. Deliberately coarse:
    /// nothing here is urgent, and a CLI release is a once-a-day event
    /// at most.
    static let remoteInterval: TimeInterval = 8 * 60 * 60

    /// Opening the update pane re-checks unless a check has succeeded
    /// this recently. Without the floor, clicking between settings tabs
    /// would be a network request per click.
    static let paneOpenFreshness: TimeInterval = 60 * 60

    /// How often the installed binaries are re-STATTED (not spawned).
    /// This is what notices a CLI that updated itself and takes the
    /// banner down without anyone pressing anything.
    static let localInterval: TimeInterval = 10 * 60

    /// Whether the release endpoints are asked at all. Off means this
    /// feature makes NO network request: the rows keep stating the
    /// installed version, which is a local read, and make no claim.
    /// Mac-only UI state, so UserDefaults rather than the config file
    /// the CLI shares — the same home as the dismissals — and absent
    /// means on. Registered in `FactoryReset.userDefaultsKeys`.
    static let remoteChecksDefaultsKey = "cliUpdateChecksEnabled"

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

    /// The row's claim, per agent key.
    @Published private(set) var statuses: [String: CLIUpdateStatus] = [:]

    /// The installed version, per agent key. Separate from `statuses`
    /// on purpose: the row prints the version in EVERY state, including
    /// the ones that make no claim about it.
    @Published private(set) var installed: [String: CLIVersion] = [:]

    /// Outdated CLIs the user has not closed at this version.
    @Published private(set) var bannerItems: [CLIUpdateBannerItem] = []

    /// Agents whose CLI is installed, in registry order. The rows.
    @Published private(set) var installedAgents: [AgentInfo] = []

    /// Agents whose running update the user has asked to stop.
    /// Published so the row can say "Cancelling…" while the child winds
    /// down — the status stays `.updating` for exactly that long.
    @Published private(set) var cancelling: Set<String> = []

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
    private var started = false

    private init() {}

    // MARK: Lifecycle

    /// Called once from `SipAIApp` after `agentManager.reload(config:)`.
    func start(config: ConfigManager) {
        self.config = config
        guard !started else { return }
        started = true
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

    /// The banner appeared. Local only — the version it names may have
    /// been made current by a terminal in the meantime, and that is
    /// answerable without the network.
    func bannerAppeared() {
        Task { await self.refreshLocal() }
    }

    /// Switch the release checks on or off.
    ///
    /// Off also drops every claim the checks earned. A row keeps its
    /// installed version, but "new version available" rests on a
    /// request the user has just declined to make, and a banner raised
    /// by one would keep pointing at it. On asks at once rather than at
    /// the next 8-hour tick, so the toggle answers immediately.
    func setRemoteChecksEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.remoteChecksDefaultsKey)
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

    // MARK: Local layer

    /// `binaryPath(for:) != nil` is the same question
    /// `AgentManager.isInstalled` asks — same `searchPaths`, same
    /// executable test — and this needs the path anyway.
    private func refreshInstalledAgents() {
        let found = AgentManager.registry.filter {
            AgentManager.binaryPath(for: $0.key) != nil
        }
        if installedAgents != found { installedAgents = found }
    }

    /// Re-stat every installed CLI, and re-read the version only where
    /// the fingerprint moved.
    ///
    /// Idempotent by construction, which is what lets the banner's own
    /// appearance drive it: an unchanged fingerprint publishes nothing,
    /// so there is no path from "banner rendered" back to "banner
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
            // Re-checked after the await: two of these can be in flight
            // (timer, pane, banner), and the one that suspended second
            // would otherwise spawn a second `--version`.
            if state[key]?.readingVersion == true { continue }
            guard current != previous || state[key]?.installed == nil else { continue }
            state[key, default: AgentState()].readingVersion = true
            let version = await Task.detached(priority: .utility) {
                await AgentCLIProbe.installedVersion(agentKey: key,
                                                     fingerprint: current)
            }.value
            var s = state[key] ?? AgentState()
            s.readingVersion = false
            s.fingerprint = current
            s.installed = version
            state[key] = s
            publish()
        }
        // An agent whose CLI went away stops having a row, and stops
        // having remembered state to bring back if it returns at a
        // different version.
        let live = Set(installedAgents.map(\.key))
        for key in state.keys where !live.contains(key) {
            if state[key]?.updating == true { continue }
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
    }

    /// Version read that BYPASSES the fingerprint cache. The button's
    /// contract needs the value as of now, not as of the last stat.
    private func readInstalledNow(_ key: String) async -> CLIVersion? {
        let fingerprint = await Task.detached(priority: .utility) {
            AgentCLIProbe.fingerprint(agentKey: key)
        }.value
        let version = await Task.detached(priority: .utility) {
            await AgentCLIProbe.installedVersion(agentKey: key,
                                                 fingerprint: fingerprint)
        }.value
        var s = state[key] ?? AgentState()
        s.fingerprint = fingerprint
        s.installed = version
        state[key] = s
        return version
    }

    // MARK: Remote layer

    /// Ask each measured endpoint what the latest release is.
    ///
    /// A failure is silence. It does not clear `latest`, does not stamp
    /// `checkedAt`, and does not produce a row, a banner or an error —
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
        for agent in installedAgents {
            let key = agent.key
            guard let release = AgentCLIRelease.measured(agentKey: key) else { continue }
            if state[key]?.checking == true { continue }
            if !force, let last = state[key]?.checkedAt,
               Date().timeIntervalSince(last) < Self.paneOpenFreshness { continue }
            state[key, default: AgentState()].checking = true
            state[key]?.attemptedAt = Date()
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
            if let found {
                s.latest = found
                s.checkedAt = Date()
            }
            state[key] = s
            publish()
        }
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

    /// Run the CLI's own updater.
    ///
    /// The race rule, in order: re-read the installed version FIRST and
    /// run nothing if it is already current; spawn; re-read again on
    /// exit and let the two readings decide the verdict.
    func update(agentKey key: String) {
        guard state[key]?.updateInFlight != true else { return }
        guard let release = AgentCLIRelease.measured(agentKey: key) else { return }
        Task { @MainActor in
            var s = state[key] ?? AgentState()
            s.updateInFlight = true
            s.updating = true
            s.failureTail = nil
            s.cancelRequested = false
            state[key] = s
            publish()

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
                    .nativeInstallDirectory(binaryPath: binary) {
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
            arguments: AgentCLIRelease.nativeInstallerArguments(
                script: script.path, version: version.text),
            ceiling: AgentCLIProbe.updateCeiling,
            outputCap: AgentCLIProbe.outputTailCap,
            extraEnvironment: AgentCLIRelease.nativeInstallerEnvironment(
                installDirectory: installDirectory),
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

    /// Stop the updater. The spinner stays until `finishUpdate` confirms
    /// the child is gone — only the row's label changes — because a row
    /// that has gone back to offering Update over a process still
    /// winding down invites the click the re-entrancy guard would then
    /// swallow. If nothing has been spawned yet, the action sees the
    /// flag after its version read and ends without spawning.
    func cancelUpdate(agentKey key: String) {
        guard state[key]?.updateInFlight == true else { return }
        state[key]?.cancelRequested = true
        cancelling.insert(key)
        if let process = state[key]?.updateProcess { Self.stopLater(process) }
    }

    /// SIGTERM now, SIGKILL after the grace if it is ignored — off the
    /// MainActor, which must not sleep through the grace. The pid only,
    /// see `AgentCLIProbe.stop`; `isRunning` on this `Process` object
    /// rules out a recycled pid.
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
        publish()

        if case .updated = verdict { relearnAfterUpdate(agentKey: key) }
    }

    private static func silentUpdaterExplanation(exitCode: Int32?) -> String {
        if let exitCode {
            return String(localized: "The updater printed nothing and exited with code \(Int(exitCode)).",
                          comment: "Updates pane detail: the CLI's updater produced no output and the installed version did not change; placeholder is the exit code")
        }
        return String(localized: "The updater printed nothing and did not exit cleanly.",
                      comment: "Updates pane detail: the CLI's updater produced no output, was stopped or could not be started, and the installed version did not change")
    }

    /// A new binary knows different modes, models and aliases. The
    /// catalogs that read those are latched once per launch, so without
    /// this a successful update leaves every picker describing the
    /// binary that was just replaced until the app is relaunched.
    private func relearnAfterUpdate(agentKey key: String) {
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

    // MARK: Banner dismissal

    private var dismissals: [String: String] {
        UserDefaults.standard
            .dictionary(forKey: Self.dismissalsDefaultsKey) as? [String: String] ?? [:]
    }

    func dismissBanner(agentKey key: String) {
        guard case .updateAvailable(_, let latest)? = statuses[key] else { return }
        var d = dismissals
        d[key] = latest.text
        UserDefaults.standard.set(d, forKey: Self.dismissalsDefaultsKey)
        publish()
    }

    // MARK: Derivation

    /// One place where state becomes what the UI reads, so a status and
    /// the banner beside it can never describe different moments.
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
                    lastCheckSucceeded: s?.checkedAt)
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
        let d = dismissals
        let banners: [CLIUpdateBannerItem] = installedAgents.compactMap { agent in
            guard let status = newStatuses[agent.key],
                  AgentCLIUpdateRules.bannerIsOwed(status: status,
                                                   dismissedVersion: d[agent.key]),
                  case .updateAvailable(_, let latest) = status
            else { return nil }
            return CLIUpdateBannerItem(agentKey: agent.key,
                                       defaultName: agent.name,
                                       latest: latest)
        }
        if statuses != newStatuses { statuses = newStatuses }
        if installed != newInstalled { installed = newInstalled }
        if bannerItems != banners { bannerItems = banners }
    }
}
