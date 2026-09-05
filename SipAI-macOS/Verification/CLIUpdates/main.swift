// A stale agent CLI must be noticed, and nothing may be claimed about
// one without evidence.
//
// The failure this feature answers is silent by construction: a CLI a
// release behind runs turns perfectly, against whatever models its own
// binary knows about. Claude Code bakes alias→model resolution into the
// binary, so "one release behind" means "one MODEL behind", and the
// field case that motivated this ran weeks that way with its own
// updater disabled AND failing (zero-byte downloads) and nothing
// anywhere on screen saying so.
//
// The opposite failure is the one this harness spends most of its
// checks on: claiming something that has not been measured. A row that
// says "Up to date" without a successful check, a banner raised off a
// stale status, an "updated" verdict read off an exit code — each of
// those is a confident sentence about somebody's tools that nothing
// backs. So the rules are pure functions, and every state they can
// reach is driven here with no subprocess, no timer and no network.
//
// The types under test are EXTRACTED VERBATIM from the shipping
// AgentCLIUpdates.swift by run.sh. A harness holding its own copy of
// the rule passes for the wrong reason.
//
// Nothing here is part of the app target: this directory sits outside
// SipAI/, so these files are never compiled into the product.
//
//   ./run.sh [source-root]
//   SIPAI_CLIUPD_LIVE=1 ./run.sh     # also probes the real endpoints

import Foundation

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

/// The file with its `//` comments removed.
///
/// Every structural check below is about what the code DOES, and this
/// file explains at length what it deliberately does not do — so a
/// naive `contains` finds the hazard spelled out in a comment and
/// reports the thing the comment exists to prevent.
func codeOnly(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let slashes = line.range(of: "//") else { return line }
        return line[line.startIndex..<slashes.lowerBound]
    }.joined(separator: "\n")
}

/// True if any `Text("…")` literal in `text` interpolates a value.
/// That overload runs a markdown pass over its result, so a
/// tool-derived string must reach it as a String expression instead.
func hasInterpolatedTextLiteral(_ text: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: #"Text\("[^"]*\\\("#)
    else { return true }
    return regex.firstMatch(in: text,
                            range: NSRange(text.startIndex..., in: text)) != nil
}

func v(_ s: String) -> CLIVersion { CLIVersion.parse(s)! }

// MARK: - 1. Reading a version out of what a CLI prints

print("CLIVersion — the three measured --version shapes")

check("claude: '2.1.239 (Claude Code)' → 2.1.239",
      CLIVersion.parse("2.1.239 (Claude Code)")?.text == "2.1.239")
check("codex: 'codex-cli 0.147.0' → 0.147.0",
      CLIVersion.parse("codex-cli 0.147.0")?.text == "0.147.0")
check("kimi: '0.38.0' → 0.38.0",
      CLIVersion.parse("0.38.0")?.text == "0.38.0")
// The token is what the row PRINTS, so it must not drag a vendor's
// parenthetical or a package name along with it.
check("the parsed token carries no surrounding words",
      CLIVersion.parse("codex-cli 0.152.1")?.text == "0.152.1")
check("trailing newline (a plain-text endpoint) is tolerated",
      CLIVersion.parse("0.40.1\n")?.text == "0.40.1")
check("a prerelease suffix stays outside the token",
      CLIVersion.parse("1.2.3-beta.4")?.text == "1.2.3")
check("no dotted number at all → nil",
      CLIVersion.parse("kimi") == nil)
// A bare-integer rule would read the "5" out of a model slug.
check("a bare integer is not a version",
      CLIVersion.parse("version 5") == nil)

print("CLIVersion — ordering")

check("2.1.9 < 2.1.258 (numeric, not lexical)", v("2.1.9") < v("2.1.258"))
check("2.1.258 == 2.1.258", v("2.1.258") == v("2.1.258"))
check("depth mismatch pads with zeros: 2.1 == 2.1.0", v("2.1") == v("2.1.0"))
check("2.1 < 2.1.1", v("2.1") < v("2.1.1"))
check("0.147.0 < 0.152.1", v("0.147.0") < v("0.152.1"))
check("0.38.0 < 0.40.1", v("0.38.0") < v("0.40.1"))
check("major outranks minor: 1.99.99 < 2.0.0", v("1.99.99") < v("2.0.0"))
// Equality has to agree with `<`, or a status flips depending on which
// operator the caller reached for.
check("`==` and `<` agree on a depth mismatch",
      v("2.1") == v("2.1.0") && !(v("2.1") < v("2.1.0")) && !(v("2.1.0") < v("2.1")))

// MARK: - 2. Reading the installed version off disk

print("installed version — claude's symlink fast path, and the fallback")

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sipai-cliupdates-\(getpid())", isDirectory: true)
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

// A throwaway copy of claude's native layout: a version-named file
// under …/claude/versions/, and a bin symlink pointing at it.
let versions = tmp.appendingPathComponent(".local/share/claude/versions",
                                          isDirectory: true)
let bin = tmp.appendingPathComponent(".local/bin", isDirectory: true)
try? FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
let versioned = versions.appendingPathComponent("2.1.239")
FileManager.default.createFile(atPath: versioned.path, contents: Data("binary".utf8))
let claudeLink = bin.appendingPathComponent("claude")
try? FileManager.default.createSymbolicLink(at: claudeLink,
                                            withDestinationURL: versioned)
AgentManager.binaries["claude_code"] = claudeLink.path

let claudePrint = AgentCLIProbe.fingerprint(agentKey: "claude_code")
check("fingerprint found the binary", claudePrint != nil)
check("the symlink target's filename IS the version",
      claudePrint.flatMap(AgentCLIProbe.versionFromClaudeVersionsSymlink)?.text == "2.1.239")

// Repointing the link is what an update does, and it must be visible to
// a stat — that is the whole cheap path by which a self-updated CLI
// takes its own banner down.
let versioned2 = versions.appendingPathComponent("2.1.258")
FileManager.default.createFile(atPath: versioned2.path, contents: Data("binary".utf8))
try? FileManager.default.removeItem(at: claudeLink)
try? FileManager.default.createSymbolicLink(at: claudeLink,
                                            withDestinationURL: versioned2)
let claudePrint2 = AgentCLIProbe.fingerprint(agentKey: "claude_code")
check("repointing the symlink moves the fingerprint", claudePrint != claudePrint2)
check("and the fast path reads the new version",
      claudePrint2.flatMap(AgentCLIProbe.versionFromClaudeVersionsSymlink)?.text == "2.1.258")

// A link into a versioned node/npm prefix must NOT be read as the
// agent's version — the directory name is what scopes the fast path.
let nodeVersions = tmp.appendingPathComponent("nvm/versions/node", isDirectory: true)
try? FileManager.default.createDirectory(at: nodeVersions, withIntermediateDirectories: true)
let nodeVersioned = nodeVersions.appendingPathComponent("22.9.0")
FileManager.default.createFile(atPath: nodeVersioned.path, contents: Data("x".utf8))
let nodeLink = bin.appendingPathComponent("something")
try? FileManager.default.createSymbolicLink(at: nodeLink, withDestinationURL: nodeVersioned)
AgentManager.binaries["other"] = nodeLink.path
check("a versioned NODE prefix is not mistaken for the agent's version",
      AgentCLIProbe.fingerprint(agentKey: "other")
        .flatMap(AgentCLIProbe.versionFromClaudeVersionsSymlink) == nil)

// Anything that is not that layout has to fall through and ASK the
// binary. This also exercises the spawn: real Process, real pipe, real
// /dev/null stdin.
let plain = tmp.appendingPathComponent("fakecli")
try? "#!/bin/sh\nprintf 'codex-cli 0.152.1\\n'\n".write(to: plain,
                                                        atomically: true,
                                                        encoding: .utf8)
try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                       ofItemAtPath: plain.path)
AgentManager.binaries["codex"] = plain.path
let plainPrint = AgentCLIProbe.fingerprint(agentKey: "codex")
check("a non-symlink binary has no fast path",
      plainPrint.flatMap(AgentCLIProbe.versionFromClaudeVersionsSymlink) == nil)
let spawned = await AgentCLIProbe.installedVersion(agentKey: "codex",
                                                   fingerprint: plainPrint)
check("…so the version comes from spawning it", spawned?.text == "0.152.1",
      "got \(spawned?.text ?? "nil")")

// A CLI that reads stdin must find EOF rather than wait for input the
// user is not typing. Without the null device this hangs until the
// ceiling kills it.
let reader = tmp.appendingPathComponent("stdincli")
try? "#!/bin/sh\ncat > /dev/null\nprintf '1.2.3\\n'\n".write(to: reader,
                                                             atomically: true,
                                                             encoding: .utf8)
try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                       ofItemAtPath: reader.path)
AgentManager.binaries["reads_stdin"] = reader.path
let readerVersion = await AgentCLIProbe.installedVersion(
    agentKey: "reads_stdin",
    fingerprint: AgentCLIProbe.fingerprint(agentKey: "reads_stdin"))
check("a CLI that reads stdin still returns (stdin is /dev/null)",
      readerVersion?.text == "1.2.3", "got \(readerVersion?.text ?? "nil")")

// The pipe's write end is inherited by whatever the CLI spawns. A
// helper it leaves running holds end-of-file open long after the CLI
// itself has exited — `codex update` does exactly this with npm — and a
// read-to-EOF would sit on it for the helper's whole life, with the row
// saying "Updating…" the entire time. The drain has to notice the CHILD
// is gone and stop waiting on the pipe.
let orphaning = tmp.appendingPathComponent("orphancli")
try? "#!/bin/sh\n(sleep 20) &\nprintf '4.5.6\\n'\n".write(to: orphaning,
                                                           atomically: true,
                                                           encoding: .utf8)
try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                       ofItemAtPath: orphaning.path)
AgentManager.binaries["orphans"] = orphaning.path
let orphanStart = Date()
let orphanVersion = await AgentCLIProbe.installedVersion(
    agentKey: "orphans",
    fingerprint: AgentCLIProbe.fingerprint(agentKey: "orphans"))
let orphanElapsed = Date().timeIntervalSince(orphanStart)
check("a CLI that leaves a helper holding the pipe still returns its version",
      orphanVersion?.text == "4.5.6", "got \(orphanVersion?.text ?? "nil")")
check("…without waiting for the helper", orphanElapsed < 8,
      String(format: "took %.1f s", orphanElapsed))

// The ceiling is a ceiling: a child that never finishes is stopped by
// pid and the run RETURNS, rather than the row spinning for the life of
// the launch. What it printed before the stop is kept.
let hanging = tmp.appendingPathComponent("hangcli")
try? "#!/bin/sh\nprintf 'starting\\n'\nsleep 30\n".write(to: hanging,
                                                          atomically: true,
                                                          encoding: .utf8)
try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                       ofItemAtPath: hanging.path)
let hangStart = Date()
let hung = await AgentCLIProbe.run(binary: hanging.path, arguments: [],
                                   ceiling: 1, outputCap: 4096,
                                   onSpawn: { _ in })
let hangElapsed = Date().timeIntervalSince(hangStart)
check("a child that outlives the ceiling is stopped and the run returns",
      hangElapsed < 8, String(format: "took %.1f s", hangElapsed))
check("…and its exit is not reported as clean", hung.exitCode != 0)
check("…while what it printed before the stop is kept",
      hung.output.contains("starting"), "output: \(hung.output.prefix(120))")

// MARK: - 3. What a row may say

print("decideStatus — never claim without evidence")

let now = Date()
check("nothing read yet → unknown",
      AgentCLIUpdateRules.decideStatus(installed: nil, latestKnown: nil,
                                       lastCheckSucceeded: nil) == .unknown)
// The one that matters: no check has ever come back, so the row states
// the version and makes no claim at all.
check("read, never checked → versionOnly (NOT 'up to date')",
      AgentCLIUpdateRules.decideStatus(installed: v("2.1.258"), latestKnown: nil,
                                       lastCheckSucceeded: nil)
        == .versionOnly(installed: v("2.1.258")))
check("a latest with no success timestamp is still versionOnly",
      AgentCLIUpdateRules.decideStatus(installed: v("2.1.258"),
                                       latestKnown: v("2.1.258"),
                                       lastCheckSucceeded: nil)
        == .versionOnly(installed: v("2.1.258")))
check("installed == latest → upToDate, stamped with the check",
      AgentCLIUpdateRules.decideStatus(installed: v("2.1.258"),
                                       latestKnown: v("2.1.258"),
                                       lastCheckSucceeded: now)
        == .upToDate(installed: v("2.1.258"), checkedAt: now))
check("installed AHEAD of latest is still upToDate (a prerelease is not stale)",
      AgentCLIUpdateRules.decideStatus(installed: v("2.2.0"),
                                       latestKnown: v("2.1.258"),
                                       lastCheckSucceeded: now)
        == .upToDate(installed: v("2.2.0"), checkedAt: now))
check("installed behind → updateAvailable",
      AgentCLIUpdateRules.decideStatus(installed: v("2.1.239"),
                                       latestKnown: v("2.1.258"),
                                       lastCheckSucceeded: now)
        == .updateAvailable(installed: v("2.1.239"), latest: v("2.1.258")))

// A failed check is expressed by leaving the last SUCCESS alone, so it
// can only ever be the absence of news — never a downgrade, never a
// retraction, never an error the user has to dismiss.
let earlier = now.addingTimeInterval(-8 * 3600)
check("a failed check downgrades nothing: upToDate survives with its own stamp",
      AgentCLIUpdateRules.decideStatus(installed: v("2.1.258"),
                                       latestKnown: v("2.1.258"),
                                       lastCheckSucceeded: earlier)
        == .upToDate(installed: v("2.1.258"), checkedAt: earlier))
check("a failed check cannot promote versionOnly to a claim",
      AgentCLIUpdateRules.decideStatus(installed: v("0.38.0"), latestKnown: nil,
                                       lastCheckSucceeded: nil)
        == .versionOnly(installed: v("0.38.0")))
check("only updateAvailable and updateFailed offer a button",
      CLIUpdateStatus.updateAvailable(installed: v("1.0"), latest: v("1.1")).offersUpdate
      && CLIUpdateStatus.updateFailed(outputTail: "x").offersUpdate
      && !CLIUpdateStatus.versionOnly(installed: v("1.0")).offersUpdate
      && !CLIUpdateStatus.upToDate(installed: v("1.0"), checkedAt: now).offersUpdate
      && !CLIUpdateStatus.updating.offersUpdate
      && !CLIUpdateStatus.unknown.offersUpdate)

// MARK: - 4. The button, and the race it must not lose

print("updateAction — no cached status is ever acted on")

check("pressed while already current runs NOTHING",
      AgentCLIUpdateRules.updateAction(installedNow: v("2.1.258"),
                                       latestKnown: v("2.1.258"))
        == .alreadyCurrent(v("2.1.258")))
check("pressed while ahead of latest also runs nothing",
      AgentCLIUpdateRules.updateAction(installedNow: v("2.2.0"),
                                       latestKnown: v("2.1.258"))
        == .alreadyCurrent(v("2.2.0")))
check("pressed while genuinely stale runs",
      AgentCLIUpdateRules.updateAction(installedNow: v("2.1.239"),
                                       latestKnown: v("2.1.258")) == .run)
check("no latest known → still runs (the CLI does its own check)",
      AgentCLIUpdateRules.updateAction(installedNow: v("2.1.239"),
                                       latestKnown: nil) == .run)

print("updateVerdict — the version moving is the success test")

check("version moved → updated",
      AgentCLIUpdateRules.updateVerdict(before: v("2.1.239"), after: v("2.1.258"),
                                        latestKnown: v("2.1.258"))
        == .updated(to: v("2.1.258")))
// Measured: `codex update` prints "Update ran successfully!" and exits
// 0 having done nothing, and `kimi upgrade` on a native install exits 0
// after declining outright. An exit code cannot tell those from a real
// update.
check("exit 0, version unchanged, newer exists → didNotUpdate",
      AgentCLIUpdateRules.updateVerdict(before: v("0.38.0"), after: v("0.38.0"),
                                        latestKnown: v("0.40.1"))
        == .didNotUpdate)
check("version unchanged and nothing newer → alreadyCurrent, not a failure",
      AgentCLIUpdateRules.updateVerdict(before: v("0.152.1"), after: v("0.152.1"),
                                        latestKnown: v("0.152.1"))
        == .alreadyCurrent(v("0.152.1")))
check("unreadable afterwards is not a success",
      AgentCLIUpdateRules.updateVerdict(before: v("2.1.239"), after: nil,
                                        latestKnown: v("2.1.258"))
        == .didNotUpdate)
check("a DOWNGRADE is not a success",
      AgentCLIUpdateRules.updateVerdict(before: v("2.1.258"), after: v("2.1.239"),
                                        latestKnown: v("2.1.258"))
        == .didNotUpdate)

// MARK: - 5. Banner keying

print("bannerIsOwed — dismissal is keyed on the VERSION")

let stale = CLIUpdateStatus.updateAvailable(installed: v("2.1.239"),
                                            latest: v("2.1.258"))
check("outdated and never dismissed → owed",
      AgentCLIUpdateRules.bannerIsOwed(status: stale, dismissedVersion: nil))
check("dismissed at this version → not owed",
      !AgentCLIUpdateRules.bannerIsOwed(status: stale, dismissedVersion: "2.1.258"))
check("a LATER release re-raises it",
      AgentCLIUpdateRules.bannerIsOwed(
        status: .updateAvailable(installed: v("2.1.239"), latest: v("2.1.259")),
        dismissedVersion: "2.1.258"))
// A CLI that updated itself takes its own notice down, and nothing is
// written to make that happen.
check("becoming current clears it with no dismissal recorded",
      !AgentCLIUpdateRules.bannerIsOwed(
        status: .upToDate(installed: v("2.1.258"), checkedAt: now),
        dismissedVersion: nil))
check("versionOnly never raises a banner",
      !AgentCLIUpdateRules.bannerIsOwed(status: .versionOnly(installed: v("0.38.0")),
                                        dismissedVersion: nil))
check("a failed update does not become a banner",
      !AgentCLIUpdateRules.bannerIsOwed(status: .updateFailed(outputTail: "x"),
                                        dismissedVersion: nil))

// MARK: - 6. The measured-agent gate

print("AgentCLIRelease — measured agents only")

for key in ["claude_code", "codex", "kimi"] {
    check("\(key) has a measured release endpoint",
          AgentCLIRelease.measured(agentKey: key) != nil)
}
// The gate: a fourth agent is version-only until somebody probes it.
// Never a guessed endpoint, never a composed package-manager command.
check("an unmeasured agent has none — version-only, no button",
      AgentCLIRelease.measured(agentKey: "some_new_agent") == nil)
check("npm's /latest document is read for its version field",
      AgentCLIRelease.measured(agentKey: "claude_code")?
        .version(from: Data(#"{"name":"x","version":"2.1.258"}"#.utf8))?.text == "2.1.258")
check("a plain-text endpoint is read as text",
      AgentCLIRelease.measured(agentKey: "kimi")?
        .version(from: Data("0.40.1\n".utf8))?.text == "0.40.1")
check("a garbage payload yields nothing, not a wrong version",
      AgentCLIRelease.measured(agentKey: "codex")?
        .version(from: Data("<html>502</html>".utf8)) == nil)
// Argv only, and only the CLI's own subcommand.
for (key, expected) in [("claude_code", ["update"]), ("codex", ["update"]),
                        ("kimi", ["upgrade"])] {
    check("\(key) updates via its own `\(expected.joined(separator: " "))`",
          AgentCLIRelease.measured(agentKey: key)?.updateArguments == expected)
}

// MARK: - 6b. The native-installer fallback (kimi)

print("native installer — only on the measured decline, only into its own directory")

let kimiRelease = AgentCLIRelease.measured(agentKey: "kimi")!
let decline = """
A newer version of @moonshot-ai/kimi-code is available (0.38.0 -> 0.40.1).
Detected install source: native installer
To update manually, run: curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash
"""
check("kimi's measured decline names its installer",
      kimiRelease.declinedToNativeInstaller(in: decline)?.absoluteString
        == "https://code.kimi.com/kimi-code/install.sh")
check("a decline naming a DIFFERENT script is not followed",
      kimiRelease.declinedToNativeInstaller(
        in: decline.replacingOccurrences(of: "code.kimi.com/kimi-code", with: "example.com/x")) == nil)
check("an updater that did not decline triggers nothing",
      kimiRelease.declinedToNativeInstaller(in: "Update ran successfully!") == nil)
check("agents without a measured installer never get one",
      AgentCLIRelease.measured(agentKey: "claude_code")!.nativeInstaller == nil
      && AgentCLIRelease.measured(agentKey: "codex")!.nativeInstaller == nil)
check("the install directory is the one whose bin/ holds the binary",
      AgentCLIRelease.nativeInstallDirectory(binaryPath: "/Users/x/.kimi-code/bin/kimi")
        == "/Users/x/.kimi-code")
check("…and any other layout is refused",
      AgentCLIRelease.nativeInstallDirectory(binaryPath: "/opt/homebrew/lib/node_modules/k/kimi") == nil)
let env = AgentCLIRelease.nativeInstallerEnvironment(installDirectory: "/Users/x/.kimi-code")
check("the installer is pointed at that directory and told not to edit shell files",
      env["KIMI_INSTALL_DIR"] == "/Users/x/.kimi-code" && env["KIMI_NO_MODIFY_PATH"] == "1")
check("the installer is pinned to the version the row named",
      AgentCLIRelease.nativeInstallerArguments(script: "/tmp/i.sh", version: "0.40.1")
        == ["/tmp/i.sh", "--version", "0.40.1"])

// The other route to the same installer: kimi's live check FAILED
// (its fetch stalled on a route this app's own fetch did not take),
// so it never named its install source — but its install record does.
// Measured: four presses of Update, four
// "manual upgrade check failed" lines thirty seconds apart in kimi's
// log, while the app already knew 0.41.0 was available.
let checkFailed = "error: failed to check for updates: fetch failed\n"
let nativeRecord = Data(#"{"active":{"version":"0.38.0","source":"native","startedAt":"2026-08-23T08:16:39.998Z"},"lastFailure":null,"lastSuccess":null}"#.utf8)
let npmRecord = Data(#"{"active":{"version":"0.38.0","source":"npm"}}"#.utf8)
check("kimi's failed check is recognised by its own sentence",
      kimiRelease.updaterCheckFailed(in: checkFailed))
check("a successful decline is not a failed check",
      !kimiRelease.updaterCheckFailed(in: decline))
check("agents without a measured installer never report a failed check",
      !AgentCLIRelease.measured(agentKey: "claude_code")!.updaterCheckFailed(in: checkFailed))
check("the install record's source is read from active.source",
      AgentCLIRelease.installSource(fromRecord: nativeRecord) == "native"
      && AgentCLIRelease.installSource(fromRecord: npmRecord) == "npm")
check("a record naming no source answers nil",
      AgentCLIRelease.installSource(fromRecord: Data(#"{"active":{"version":"1"}}"#.utf8)) == nil)
check("failed check + native record → the measured installer",
      kimiRelease.nativeInstallerAfterFailedCheck(in: checkFailed, installRecord: nativeRecord)?
        .absoluteString == "https://code.kimi.com/kimi-code/install.sh")
check("failed check + npm record → nothing (npm's updater is kimi's own)",
      kimiRelease.nativeInstallerAfterFailedCheck(in: checkFailed, installRecord: npmRecord) == nil)
check("failed check + NO record → nothing (a missing record is not native)",
      kimiRelease.nativeInstallerAfterFailedCheck(in: checkFailed, installRecord: nil) == nil)
check("a decline that DID name the source needs no record",
      kimiRelease.nativeInstallerAfterFailedCheck(in: decline, installRecord: nativeRecord) == nil
      && kimiRelease.declinedToNativeInstaller(in: decline) != nil)
check("the record lives under kimi's HOME, in updates/",
      AgentCLIRelease.nativeInstallRecordURL(home: URL(fileURLWithPath: "/Users/x/.kimi-code")).path
        == "/Users/x/.kimi-code/updates/install.json")

// MARK: - 7. Structural — the wiring a harness cannot run

print("structural")

let model = source("SipAI/Models/AgentCLIUpdates.swift")
let runner = source("SipAI/Models/AgentRunner.swift")
let reset = source("SipAI/Models/FactoryReset.swift")
let content = source("SipAI/Views/ContentView.swift")
check("AgentCLIUpdates.swift is where it is expected", !model.isEmpty)

// One environment, not a second spelling of it. Everything the spawn
// needs — the DYLD strip that keeps a Node SEA from aborting, the
// shared searchPaths PATH, the proxy overlay — arrives through the
// runner's own builder or not at all.
check("the spawn uses AgentRunner's own child environment",
      model.contains("AgentRunner.buildEnvironment()"))
check("…which strips DYLD_*", runner.contains("stripDynamicLinkerVars(from: &env)"))
check("…and overlays the proxy vars", runner.contains("overlayProxyVars(into: &env)"))
check("no second copy of either helper lives in the new file",
      !model.contains("func stripDynamicLinkerVars")
      && !model.contains("func overlayProxyVars"))
check("stdin is /dev/null", model.contains("FileHandle.nullDevice"))

// Foundation cannot put the child in a group of its own, so its group
// is SipAI's: kill(-pgid) would take the app down with it.
check("nothing signals a process GROUP", !codeOnly(model).contains("kill(-"))
check("the ceiling terminates by pid", model.contains("p.terminate()"))
check("a child that ignores SIGTERM is SIGKILLed, by pid",
      model.contains("kill(p.processIdentifier, SIGKILL)"))
check("the drain is bounded in time, not only in bytes",
      model.contains("orphanGrace") && model.contains("poll(&pfd"))
check("the spawn awaits the shell capture before building the environment",
      model.contains("await ShellEnvironment.prepare()\n        var environment = AgentRunner.buildEnvironment()"))
check("the row disables Update while a previous press is still winding down",
      settings.contains("cliUpdates.updateInFlight(agent.key)"))
check("a silent updater still gets an explanation",
      model.contains("silentUpdaterExplanation(exitCode:"))
check("the installer runs only after the CLI's own updater declined",
      model.contains("release.declinedToNativeInstaller(in: result.output)"))
check("update() also takes the installer route after a failed check",
      model.contains("?? release.nativeInstallerAfterFailedCheck(in: result.output,"))
check("the install record is read off the rule, not inside it",
      model.contains("AgentCLIRelease.nativeInstallRecordURL(home: KimiSessionScanner.home)"))
check("the installer is spawned through the same bounded runner, with its env on top",
      model.contains("extraEnvironment: AgentCLIRelease.nativeInstallerEnvironment("))
check("the installer's verdict is the version moving, like any other update",
      model.contains("before: before, after: installed, latestKnown:"))
if let from = content.range(of: "ForEach(cliUpdates.bannerItems)"),
   let to = content.range(of: "cliUpdates.bannerAppeared()"),
   from.lowerBound < to.lowerBound {
    check("the banner is drawn in the toolbar strip every centre view reserves",
          content[from.lowerBound..<to.lowerBound].contains(".ignoresSafeArea(edges: .top)"))
} else {
    check("the banner overlay is where it is expected", false)
}
// Foundation raises when terminationStatus is read on a live process.
check("terminationStatus is read guarded", model.contains("p.isRunning ? nil : p.terminationStatus"))

// A key that is not registered outlives a reset that promised to clear
// every setting.
check("the dismissals key is registered for factory reset",
      reset.contains("AgentCLIUpdateMonitor.dismissalsDefaultsKey"))
check("and the key's literal value is what the monitor declares",
      model.contains(#"dismissalsDefaultsKey = "cliUpdateDismissed""#))

// Dismissals are Mac-only UI state. config.json is shared with the CLI,
// which has no use for this.
check("dismissals live in UserDefaults, not config.json",
      model.contains("UserDefaults.standard")
      && !model.contains("config.setDisplay"))

// No user-visible sentence in this app names an agent outright.
check("the banner names the agent through agentLabel",
      content.contains("config.agentLabel(for: item.agentKey"))
let settings = source("SipAI/Views/Settings/SettingsView.swift")
check("the row names the agent through agentLabel",
      settings.contains("config.agentLabel(for: agent.key"))
// The interpolating Text overload markdown-parses its result.
check("no interpolated Text literal reaches the new rows",
      !hasInterpolatedTextLiteral(codeOnly(settings))
      && !hasInterpolatedTextLiteral(codeOnly(content)))
check("versions are printed verbatim",
      settings.contains("Text(verbatim: cliUpdates.installed[agent.key]?.text"))

// The banner is visible on every screen of the app; a clock in it would
// re-render the window once a second forever.
check("the banner carries no clock",
      !content.contains("TimelineView") || !content.contains("CLIUpdateBanner"))

// Cadence: nothing here polls.
check("release checks are 8-hourly, not per-minute",
      model.contains("remoteInterval: TimeInterval = 8 * 60 * 60"))
check("the local re-stat is 10-minutely", model.contains("localInterval: TimeInterval = 10 * 60"))
check("opening the pane does not re-check within the hour",
      model.contains("paneOpenFreshness: TimeInterval = 60 * 60"))

// Every new string is in the catalog, in both languages.
if let data = FileManager.default.contents(atPath: sourceRoot + "/SipAI/Resources/Localizable.xcstrings"),
   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let strings = root["strings"] as? [String: Any] {
    for key in ["Command-line tools", "Up to date", "New version %@", "Updating…",
                "Cancelling…",
                "Update did not complete", "Details", "Update",
                "Finish the running turn before updating this tool.",
                "The updater printed nothing and exited with code %lld.",
                "The updater printed nothing and did not exit cleanly.",
                "The installer could not be downloaded from %@.",
                "The installer could not be staged on disk.",
                "%@ has a new version available (%@). Update it in Settings → Updates."] {
        let entry = strings[key] as? [String: Any]
        let zh = ((entry?["localizations"] as? [String: Any])?["zh-Hans"]
                    as? [String: Any])?["stringUnit"] as? [String: Any]
        check("\"\(key)\" is translated", zh?["value"] is String)
    }
} else {
    check("Localizable.xcstrings is readable", false)
}

// MARK: - 7b. Structural — codex's model list is refreshed THROUGH codex

print("codex model list refresh")

let launch = source("SipAI/Models/AgentLaunchOptions.swift")
check("CodexCatalog re-reads on a fingerprint, not a one-shot latch",
      launch.contains("nonisolated private static func sourcesFingerprint()")
      && !launch.contains("private var loadStarted"))
check("…over both the cache and config.toml",
      launch.contains("[\".codex/models_cache.json\", \".codex/config.toml\"]"))
check("a codex update asks the NEW binary for its list before re-reading",
      launch.contains("loadedFingerprint = nil\n        refreshFromCodex(force: true)\n        ensureLoaded()"))
check("the refresh is what CodexModelListRefresh runs",
      launch.contains("await CodexModelListRefresh.run(binary: binary)"))
check("the codex window honours model_context_window, clamped to max_context_window",
      launch.contains("TomlScalar.integer(line, key: \"model_context_window\")")
      && launch.contains("base = cap > 0 ? min(override, cap) : override"))
check("the refresh speaks app-server's model/list",
      model.contains("\"method\":\"model/list\"")
      && model.contains("p.arguments = [\"app-server\"]"))
// stdin is what keeps app-server alive: closing it before the answer
// has been read ends the process before it answers (measured).
let refreshCode = codeOnly(model)
let answerAt = refreshCode.range(of: "answered = containsAnswer(received)")?.lowerBound
let closeAt = refreshCode.range(of: "try? input.fileHandleForWriting.close()")?.lowerBound
check("stdin is held open until the answer is read, then closed",
      answerAt != nil && closeAt != nil && answerAt! < closeAt!)
check("the refresh child is stopped by pid through AgentCLIProbe.stop",
      model.contains("AgentCLIProbe.stop(p)\n        p.waitUntilExit()"))
check("containsAnswer: the id-2 result ends the wait",
      CodexModelListRefresh.containsAnswer(
        Data((#"{"id":2,"jsonrpc":"2.0","result":{"data":[]}}"# + "\n").utf8)))
check("containsAnswer: an error answer ends it too",
      CodexModelListRefresh.containsAnswer(
        Data((#"{"id":2,"jsonrpc":"2.0","error":{"code":1,"message":"x"}}"# + "\n").utf8)))
check("containsAnswer: a notification does not",
      !CodexModelListRefresh.containsAnswer(
        Data((#"{"jsonrpc":"2.0","method":"remoteControl/status/changed","params":null}"# + "\n").utf8)))
check("containsAnswer: the initialize answer (id 1) does not",
      !CodexModelListRefresh.containsAnswer(
        Data(#"{"id":1,"jsonrpc":"2.0","result":{}}"#.utf8)))
check("containsAnswer: a half-written line does not",
      !CodexModelListRefresh.containsAnswer(
        Data(#"{"id":2,"jsonrpc":"2.0","result":{"da"#.utf8)))
// A binary that is not codex answers false promptly rather than
// waiting out the ceiling: /usr/bin/true exits at once, and the read
// loop must notice the exit and leave.
check("a non-codex binary answers false",
      await CodexModelListRefresh.run(binary: "/usr/bin/true") == false)

// MARK: - 8. Live (opt in)

if ProcessInfo.processInfo.environment["SIPAI_CLIUPD_LIVE"] == "1" {
    print("live — real endpoints against real binaries")
    // The real refresh, against the codex on PATH. Codex answers from
    // its cache when that is fresh and from the server otherwise;
    // either way the answer arrives well inside the ceiling.
    let whichCodex = Process()
    whichCodex.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    whichCodex.arguments = ["which", "codex"]
    let codexPipe = Pipe()
    whichCodex.standardOutput = codexPipe
    try? whichCodex.run()
    whichCodex.waitUntilExit()
    let codexPath = String(decoding: codexPipe.fileHandleForReading.readDataToEndOfFile(),
                           as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if !codexPath.isEmpty {
        let began = Date()
        let answered = await CodexModelListRefresh.run(binary: codexPath)
        check("codex app-server answers model/list", answered,
              String(format: "(%.1f s)", Date().timeIntervalSince(began)))
    } else {
        print("  skip codex app-server — no codex on PATH")
    }
    for agent in ["claude_code": "claude", "codex": "codex", "kimi": "kimi"] {
        guard let release = AgentCLIRelease.measured(agentKey: agent.key) else { continue }
        // Find the CLI the ordinary way, without the app's search paths.
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", agent.value]
        let outPipe = Pipe()
        which.standardOutput = outPipe
        which.standardError = FileHandle.nullDevice
        try? which.run()
        let path = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        which.waitUntilExit()
        guard !path.isEmpty else {
            print("  skip \(agent.key) — not installed")
            continue
        }
        AgentManager.binaries[agent.key] = path
        let installed = await AgentCLIProbe.installedVersion(
            agentKey: agent.key,
            fingerprint: AgentCLIProbe.fingerprint(agentKey: agent.key))
        check("\(agent.key): --version parses", installed != nil)

        var request = URLRequest(url: release.latestURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.httpMethod = "GET"
        if let (data, response) = try? await URLSession.shared.data(for: request),
           let http = response as? HTTPURLResponse, http.statusCode == 200 {
            let latest = release.version(from: data)
            check("\(agent.key): the endpoint answers with a version", latest != nil)
            if let installed, let latest {
                let status = AgentCLIUpdateRules.decideStatus(
                    installed: installed, latestKnown: latest, lastCheckSucceeded: Date())
                print("       installed \(installed.text), latest \(latest.text) → \(status)")
            }
        } else {
            print("  skip \(agent.key) — endpoint unreachable (a failed check says nothing)")
        }
    }
}

print("")
if failures == 0 {
    print("All checks passed.")
} else {
    print("\(failures) check(s) failed.")
    exit(1)
}
