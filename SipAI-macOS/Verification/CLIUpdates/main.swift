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

import Combine
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
      && !CLIUpdateStatus.unknown.offersUpdate
      && !CLIUpdateStatus.managedElsewhere(installed: v("2.1.274"), manager: "Homebrew").offersUpdate)
// A Homebrew-installed claude or kimi: its own updater declines the
// install (measured on claude 2.1.283 and kimi 2.1.1) and SipAI never
// runs Homebrew, so whatever a check found is not a claim this row may
// make — for claude's `claude-code` cask, which tracks npm's `stable`
// tag, the comparison itself is against the wrong channel.
check("managed elsewhere outranks a newer release: no claim, whoever is behind",
      AgentCLIUpdateRules.decideStatus(installed: v("2.1.274"), latestKnown: v("2.1.283"),
                                       lastCheckSucceeded: now, managedBy: "Homebrew")
        == .managedElsewhere(installed: v("2.1.274"), manager: "Homebrew"))
check("…and with no check at all",
      AgentCLIUpdateRules.decideStatus(installed: v("2.1.274"), latestKnown: nil,
                                       lastCheckSucceeded: nil, managedBy: "Homebrew")
        == .managedElsewhere(installed: v("2.1.274"), manager: "Homebrew"))
check("…but a version not read yet is still unknown",
      AgentCLIUpdateRules.decideStatus(installed: nil, latestKnown: v("2.1.283"),
                                       lastCheckSucceeded: now, managedBy: "Homebrew") == .unknown)
check("a nil manager is the ordinary rule — the default every caller had",
      AgentCLIUpdateRules.decideStatus(installed: v("2.1.274"), latestKnown: v("2.1.283"),
                                       lastCheckSucceeded: now, managedBy: nil)
        == .updateAvailable(installed: v("2.1.274"), latest: v("2.1.283")))

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

// MARK: - 5. The Settings badge and the automatic update

print("badgeVersion — what a tool puts on the Settings badge")

let behind = CLIUpdateStatus.updateAvailable(installed: v("2.1.239"),
                                             latest: v("2.1.258"))
check("behind, updated by hand → on offer at the latest version",
      AgentCLIUpdateRules.badgeVersion(status: behind, latest: v("2.1.258"),
                                       autoUpdate: false) == "2.1.258")
// With automatic updates on there is nothing for the user to do — the
// tool updates itself, and a badge would ask them to look at a job
// that is already being done.
check("behind, updated automatically → nothing on offer",
      AgentCLIUpdateRules.badgeVersion(status: behind, latest: v("2.1.258"),
                                       autoUpdate: true) == nil)
// The badge is the ONLY voice a failed automatic update has.
check("a failed update is on offer even with automatic updates on",
      AgentCLIUpdateRules.badgeVersion(status: .updateFailed(outputTail: "x"),
                                       latest: v("2.1.258"), autoUpdate: true) == "2.1.258")
check("…and with them off",
      AgentCLIUpdateRules.badgeVersion(status: .updateFailed(outputTail: "x"),
                                       latest: v("2.1.258"), autoUpdate: false) == "2.1.258")
// A tool that became current by ANY route — our button, its own
// updater, a terminal — takes its badge down with nothing written.
check("current → nothing on offer",
      AgentCLIUpdateRules.badgeVersion(status: .upToDate(installed: v("2.1.258"), checkedAt: now),
                                       latest: v("2.1.258"), autoUpdate: false) == nil)
check("versionOnly (never checked) → nothing on offer",
      AgentCLIUpdateRules.badgeVersion(status: .versionOnly(installed: v("0.38.0")),
                                       latest: nil, autoUpdate: false) == nil)
check("updating → nothing on offer",
      AgentCLIUpdateRules.badgeVersion(status: .updating, latest: v("2.1.258"),
                                       autoUpdate: false) == nil)
check("managed elsewhere → nothing on offer, whatever a check found, either switch",
      AgentCLIUpdateRules.badgeVersion(status: .managedElsewhere(installed: v("2.1.274"), manager: "Homebrew"),
                                       latest: v("2.1.283"), autoUpdate: false) == nil
      && AgentCLIUpdateRules.badgeVersion(status: .managedElsewhere(installed: v("2.1.274"), manager: "Homebrew"),
                                          latest: v("2.1.283"), autoUpdate: true) == nil)

print("autoUpdateIsDue — one attempt per version, never under a running turn")

func due(_ status: CLIUpdateStatus, latest: CLIVersion? = v("2.1.258"),
         enabled: Bool = true, action: Bool = false, turn: Bool = false,
         tried: String? = nil) -> Bool {
    AgentCLIUpdateRules.autoUpdateIsDue(enabled: enabled, status: status, latest: latest,
                                        actionInFlight: action, turnInFlight: turn,
                                        attemptedVersion: tried)
}
check("behind, switch on, nothing running → due", due(behind))
check("the switch off → never", !due(behind, enabled: false))
// The Update button's own rule: a binary is not replaced under a
// running child. The update waits; the turn ending re-asks.
check("a turn of that tool in flight → waits", !due(behind, turn: true))
check("another action holding the tool → waits", !due(behind, action: true))
check("this version already tried → not again (no retry loop)",
      !due(behind, tried: "2.1.258"))
check("a NEWER release after a tried one → a new attempt",
      due(.updateAvailable(installed: v("2.1.239"), latest: v("2.1.259")),
          latest: v("2.1.259"), tried: "2.1.258"))
check("a failed status at a newer release → a new attempt",
      due(.updateFailed(outputTail: "x"), latest: v("2.1.259"), tried: "2.1.258"))
check("current → nothing to do",
      !due(.upToDate(installed: v("2.1.258"), checkedAt: now)))
check("never checked → nothing to act on", !due(.versionOnly(installed: v("2.1.0")), latest: nil))
check("managed elsewhere never updates by itself", !due(.managedElsewhere(installed: v("2.1.274"), manager: "Homebrew")))
check("no latest known → nothing to act on", !due(behind, latest: nil))
check("already updating → not twice", !due(.updating))

print("UpdateBadgeRules — keyed on (item, VERSION)")

let appItem = UpdateBadgeItem.app(version: "5")
let claudeItem = UpdateBadgeItem.cli(agentKey: "claude_code", version: "2.1.258")
check("the two sources never share a key",
      appItem.key != claudeItem.key && claudeItem.key == "cli:claude_code" && appItem.key == "app")
check("nothing on offer → no badge", !UpdateBadgeRules.isOwed([], seen: [:]))
check("an item never seen → badge", UpdateBadgeRules.isOwed([claudeItem], seen: [:]))
let afterLooking = UpdateBadgeRules.seen(afterViewing: [appItem, claudeItem], previously: [:])
check("looking at the pane sees every item on it",
      !UpdateBadgeRules.isOwed([appItem, claudeItem], seen: afterLooking))
// The user's rule: the icon comes back when a new update comes out
// after it disappeared.
check("a NEWER release of a seen item raises it again",
      UpdateBadgeRules.isOwed([.cli(agentKey: "claude_code", version: "2.1.259")], seen: afterLooking))
check("a new item beside seen ones raises it",
      UpdateBadgeRules.isOwed([appItem, claudeItem, .cli(agentKey: "codex", version: "0.157.0")],
                              seen: afterLooking))
check("seeing again keeps what was seen before",
      UpdateBadgeRules.seen(afterViewing: [], previously: afterLooking) == afterLooking)

print("UpdateBadge — the state both views draw from")

// A suite named by an ABSOLUTE path keeps its plist in that folder and
// never touches ~/Library/Preferences. A named suite there cannot be
// cleaned up: cfprefsd writes the emptied domain back seconds after the
// process exits, whatever was removed and synchronized first (measured —
// one empty plist per run).
let badgePrefs = FileManager.default.temporaryDirectory
    .appendingPathComponent("sipai-cliupdates-prefs-\(getpid())", isDirectory: true)
try? FileManager.default.createDirectory(at: badgePrefs, withIntermediateDirectories: true)
let suiteName = badgePrefs.appendingPathComponent("badge").path
let suite = UserDefaults(suiteName: suiteName)!
suite.removePersistentDomain(forName: suiteName)
let badge = UpdateBadge(defaults: suite)
check("starts with nothing on offer", !badge.isOwed && badge.items.isEmpty)
badge.setCLIItems([claudeItem])
check("a tool behind raises it", badge.isOwed)
badge.setAppItems([appItem])
check("SipAI's own update is listed first", badge.items == [appItem, claudeItem])
badge.markSeen()
check("the Updates pane on screen clears it", !badge.isOwed)
check("…and what was seen is persisted",
      (suite.dictionary(forKey: UpdateBadge.seenDefaultsKey) as? [String: String])
        == ["app": "5", "cli:claude_code": "2.1.258"])
// A second launch reads the same answer back.
let relaunched = UpdateBadge(defaults: suite)
relaunched.setAppItems([appItem])
relaunched.setCLIItems([claudeItem])
check("a relaunch does not raise what was already seen", !relaunched.isOwed)
// An install held for a running turn is news even where its release was
// seen: the badge points at Install Now.
relaunched.setAppItems([appItem, .appInstall(version: "5")])
check("a held SipAI install raises it again, under its own key", relaunched.isOwed)
check("…distinct from the release it installs",
      UpdateBadgeItem.appInstall(version: "5").key != appItem.key)
relaunched.markSeen()
check("…and viewing Updates clears it like anything else", !relaunched.isOwed)
badge.setCLIItems([.cli(agentKey: "claude_code", version: "2.1.259")])
check("a newer release after the badge went → it comes back", badge.isOwed)
badge.setCLIItems([])
badge.setAppItems([])
check("nothing on offer → gone, with nothing marked", !badge.isOwed && badge.items.isEmpty)
badge.setCLIItems([claudeItem])
badge.forgetSeen()
check("a factory reset forgets what was seen", badge.isOwed)
suite.removePersistentDomain(forName: suiteName)
CFPreferencesAppSynchronize(suiteName as CFString)
try? FileManager.default.removeItem(at: badgePrefs)

// MARK: - 5b. The header's queue

print("UpdateAnnouncementQueue — wait your turn, no wordmark in between")

let t0 = Date(timeIntervalSince1970: 1_000_000)
let lineA = UpdateAnnouncement(text: "A")
let lineB = UpdateAnnouncement(text: "B")
let lineC = UpdateAnnouncement(text: "C")
var q = UpdateAnnouncementQueue()
check("an empty queue shows the wordmark", q.current == nil && q.endsAt(duration: 5) == nil)
q.enqueue(lineA, now: t0)
check("the first line shows at once", q.current == lineA && q.endsAt(duration: 5) == t0.addingTimeInterval(5))
q.enqueue(lineB, now: t0.addingTimeInterval(1))
check("a line arriving meanwhile WAITS", q.current == lineA && q.waiting == [lineB])
q.advance(now: t0.addingTimeInterval(4.9), duration: 5)
check("an early wake-up cuts nothing short", q.current == lineA)
q.enqueue(lineC, now: t0.addingTimeInterval(4.95))
q.advance(now: t0.addingTimeInterval(5), duration: 5)
check("at five seconds the next line takes over DIRECTLY", q.current == lineB && q.waiting == [lineC])
check("…with a full turn of its own", q.endsAt(duration: 5) == t0.addingTimeInterval(10))
q.advance(now: t0.addingTimeInterval(12), duration: 5)
check("a late wake-up still starts the next line's turn when it appears",
      q.current == lineC && q.endsAt(duration: 5) == t0.addingTimeInterval(17))
q.advance(now: t0.addingTimeInterval(17), duration: 5)
check("an empty queue brings the wordmark back", q.current == nil && q.waiting.isEmpty)

print("UpdateAnnouncer — the real driver, on the real clock")

do {
    let announcer = UpdateAnnouncer(duration: 0.3)
    var shown: [(Date, String?)] = []
    let watch = announcer.$current.dropFirst().sink { shown.append((Date(), $0?.text)) }
    let began = Date()
    announcer.announce("A")
    announcer.announce("B")
    try? await Task.sleep(nanoseconds: 120_000_000)
    announcer.announce("C")
    check("the first line is on screen while the others wait", announcer.current?.text == "A")
    try? await Task.sleep(nanoseconds: 1_400_000_000)
    watch.cancel()
    let texts = shown.map(\.1)
    check("A, B, C, then the wordmark — never the wordmark in between",
          texts == ["A", "B", "C", nil], "\(texts)")
    if texts == ["A", "B", "C", nil] {
        let gaps = zip(shown.dropFirst(), shown).map { next, prev in next.0.timeIntervalSince(prev.0) }
        check("each line stays its full time (0.3 s here, 5 s in the app)",
              gaps.allSatisfy { $0 >= 0.29 && $0 < 0.6 },
              gaps.map { String(format: "%.2f", $0) }.joined(separator: " "))
        check("the first line appeared at once",
              shown[0].0.timeIntervalSince(began) < 0.05)
    }
    check("the app's lines stay five seconds", UpdateAnnouncer.defaultDuration == 5)
}

do {
    let announcer = UpdateAnnouncer(duration: 0.2)
    announcer.isEnabled = { false }
    announcer.announce("Off")
    check("with Show update messages off, nothing is queued", announcer.current == nil)
    announcer.isEnabled = { true }
    var shown: [String?] = []
    let watch = announcer.$current.dropFirst().sink { shown.append($0?.text) }
    announcer.announce("Claude Code just updated to 2.1.290")
    announcer.announce("Claude Code just updated to 2.1.290")
    try? await Task.sleep(nanoseconds: 50_000_000)
    announcer.announce("Claude Code just updated to 2.1.290")
    try? await Task.sleep(nanoseconds: 450_000_000)
    watch.cancel()
    // One update, seen by two routes at once (the button's own finish
    // and the re-stat), is said once.
    check("the same sentence showing or waiting is not queued twice",
          shown == ["Claude Code just updated to 2.1.290", nil], "\(shown)")
}

print("UpdateAnnouncer — a line starts only while someone can see the logo")

do {
    // An update noticed while Terminal is in front, or one that lands
    // while a sheet lies over the logo, would otherwise spend its five
    // seconds where nobody is looking.
    let away = UpdateAnnouncer(duration: 0.2)
    away.setAppActive(false)
    away.announce("Claude Code just updated to 2.1.290")
    check("SipAI behind another app: the line is held, not shown", away.current == nil)
    away.announce("Claude Code just updated to 2.1.290")
    away.setAppActive(true)
    check("…and starts when SipAI comes to the front", away.current?.text == "Claude Code just updated to 2.1.290")
    try? await Task.sleep(nanoseconds: 350_000_000)
    check("…said once, however often it was announced while held", away.current == nil)

    let covered = UpdateAnnouncer(duration: 0.2)
    covered.setAppActive(true)
    covered.sheetCoversLockup = { true }
    covered.setSheetPresented(true)
    covered.announce("Codex just updated to 0.157.0")
    covered.announce("Kimi Code just updated to 2.1.2")
    check("a sheet over the logo holds the lines", covered.current == nil)
    covered.setSheetPresented(false)
    check("…closing it starts them, in the order they came",
          covered.current?.text == "Codex just updated to 0.157.0")
    try? await Task.sleep(nanoseconds: 250_000_000)
    check("…the next taking over directly", covered.current?.text == "Kimi Code just updated to 2.1.2")

    // Every manual update is run from Settings, and on most windows the
    // sheet leaves the sidebar — logo and all — in plain view. Held
    // there, a manual update was never said when it landed.
    let beside = UpdateAnnouncer(duration: 0.2)
    beside.setAppActive(true)
    beside.sheetCoversLockup = { false }
    beside.setSheetPresented(true)
    beside.announce("Codex just updated to 0.157.1")
    check("a sheet that leaves the logo in view does not hold the line",
          beside.current?.text == "Codex just updated to 0.157.1")

    let unmeasured = UpdateAnnouncer(duration: 0.2)
    unmeasured.setAppActive(true)
    unmeasured.setSheetPresented(true)
    unmeasured.announce("Codex just updated to 0.157.1")
    check("with no lockup to measure, a sheet counts as covering it", unmeasured.current == nil)

    let switchedOff = UpdateAnnouncer(duration: 0.2)
    switchedOff.setAppActive(false)
    switchedOff.announce("Codex just updated to 0.157.0")
    switchedOff.isEnabled = { false }
    switchedOff.setAppActive(true)
    check("a held line switched off meanwhile is dropped, not shown late", switchedOff.current == nil)
}

print("UpdateWaitList — a turn sent during an update waits for it")

// Flags and short sleeps, never an await on a task's value: a wait list
// that fails to release must FAIL these checks, not hang the harness.
do {
    let list = UpdateWaitList()
    var busy = true
    var order: [String] = []
    Task { @MainActor in
        await list.wait(for: "codex") { busy }
        order.append("first")
    }
    Task { @MainActor in
        await list.wait(for: "codex") { busy }
        order.append("second")
    }
    Task { @MainActor in
        await list.wait(for: "claude_code") { true }
        order.append("other")
    }
    try? await Task.sleep(nanoseconds: 100_000_000)
    check("turns sent during the update wait", order.isEmpty && list.count(for: "codex") == 2)
    busy = false
    list.release("codex")
    try? await Task.sleep(nanoseconds: 100_000_000)
    check("the update's end releases every turn waiting on that tool",
          Set(order) == ["first", "second"] && list.count(for: "codex") == 0, "\(order)")
    check("…and no turn waiting on another tool",
          !order.contains("other") && list.count(for: "claude_code") == 1)
    list.release("claude_code")
    var quickDone = false
    Task { @MainActor in
        await list.wait(for: "kimi") { false }
        quickDone = true
    }
    try? await Task.sleep(nanoseconds: 100_000_000)
    check("with no update running a turn does not wait at all",
          quickDone && list.count(for: "kimi") == 0)
    list.release("nobody")
    check("releasing a tool nothing waits on is harmless", list.count(for: "nobody") == 0)
}

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
// Claude's channel: `autoUpdatesChannel` in its settings (later file
// wins), `latest` when unset, `latest` / `stable` / `rc` its own schema.
// The check reads that npm dist-tag: `stable` stood at 2.1.274 while
// `latest` was 2.1.283 (2026-09-28), and a stable-channel install
// checked against `latest` read as behind while `claude update`
// answered "up to date".
let stableSettings = Data(#"{"autoUpdatesChannel":"stable","model":"opus"}"#.utf8)
let latestSettings = Data(#"{"autoUpdatesChannel":"latest"}"#.utf8)
check("no channel in the settings → latest",
      AgentCLIRelease.claudeChannel(settings: []) == "latest"
      && AgentCLIRelease.claudeChannel(settings: [Data(#"{"model":"opus"}"#.utf8)]) == "latest")
check("stable in the user's settings → stable", AgentCLIRelease.claudeChannel(settings: [stableSettings]) == "stable")
check("a later settings file wins",
      AgentCLIRelease.claudeChannel(settings: [stableSettings, latestSettings]) == "latest"
      && AgentCLIRelease.claudeChannel(settings: [latestSettings, stableSettings]) == "stable")
check("rc is claude's third channel; anything else is its default; case and space forgiven",
      AgentCLIRelease.claudeChannel(settings: [Data(#"{"autoUpdatesChannel":"rc"}"#.utf8)]) == "rc"
      && AgentCLIRelease.claudeChannel(settings: [Data(#"{"autoUpdatesChannel":"nightly"}"#.utf8)]) == "latest"
      && AgentCLIRelease.claudeChannel(settings: [Data(#"{"autoUpdatesChannel":" Stable "}"#.utf8)]) == "stable"
      && AgentCLIRelease.claudeChannel(settings: [Data("not json".utf8)]) == "latest")
let claudeRelease = AgentCLIRelease.measured(agentKey: "claude_code")!
check("the stable channel reads npm's stable dist-tag document, everything else unchanged",
      claudeRelease.onChannel("stable").latestURL.absoluteString
        == "https://registry.npmjs.org/@anthropic-ai/claude-code/stable"
      && claudeRelease.onChannel("stable").updateArguments == ["update"]
      && claudeRelease.onChannel("stable").agentKey == "claude_code")
check("latest is the measured URL itself", claudeRelease.onChannel("latest").latestURL == claudeRelease.latestURL)
check("a plain-text endpoint has no channel",
      AgentCLIRelease.measured(agentKey: "kimi")!.onChannel("stable").latestURL.absoluteString
        == "https://code.kimi.com/kimi-code/latest")
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
// Kimi has two sites, and its updater names the installer of the region
// it is on (`kimiCodeInstallShUrl` = the region profile's cdnBase): a
// kimi signed in on kimi.ai, or installed from code.kimi.ai, declines
// with the GLOBAL channel's script. Accepting the mainland URL alone
// would fail every update of such a kimi.
let globalDecline = decline.replacingOccurrences(of: "code.kimi.com", with: "code.kimi.ai")
check("a kimi on the global site names the global installer — and it is followed",
      kimiRelease.declinedToNativeInstaller(in: globalDecline)?.absoluteString
        == "https://code.kimi.ai/kimi-code/install.sh")
check("the two official installers are the only ones (mainland first: the failed-check fallback)",
      kimiRelease.nativeInstallers.map(\.absoluteString)
        == ["https://code.kimi.com/kimi-code/install.sh", "https://code.kimi.ai/kimi-code/install.sh"])
for lookalike in ["http://code.kimi.ai/kimi-code/install.sh",
                  "https://code.kimi.ai.example.com/kimi-code/install.sh",
                  "https://code.kimi.ai/kimi-code/install.sh?x=1",
                  "https://code.kimi.ai/other/install.sh"] {
    check("a look-alike installer URL is refused: \(lookalike)",
          kimiRelease.declinedToNativeInstaller(
            in: decline.replacingOccurrences(of: "https://code.kimi.com/kimi-code/install.sh",
                                             with: lookalike)) == nil)
}
check("agents without a measured installer never get one",
      AgentCLIRelease.measured(agentKey: "claude_code")!.nativeInstallers.isEmpty
      && AgentCLIRelease.measured(agentKey: "codex")!.nativeInstallers.isEmpty)
check("the install directory is the one whose bin/ holds the binary",
      AgentCLIRelease.nativeInstallDirectory(binaryPath: "/Users/x/.kimi-code/bin/kimi",
                                             kimiHome: "/Users/x/.kimi-code")
        == "/Users/x/.kimi-code")
check("…and any other layout is refused",
      AgentCLIRelease.nativeInstallDirectory(binaryPath: "/opt/homebrew/lib/node_modules/k/kimi",
                                             kimiHome: "/Users/x/.kimi-code") == nil)
// A copy of the binary in a shared bin must not send the installer to
// that bin's parent: it would write kimi's own `fd` and `rg` over the
// user's in `/usr/local/bin`.
check("…and a bin/ that is not kimi's own home is refused too",
      AgentCLIRelease.nativeInstallDirectory(binaryPath: "/usr/local/bin/kimi",
                                             kimiHome: "/Users/x/.kimi-code") == nil)
check("a moved home (KIMI_CODE_HOME) is honoured",
      AgentCLIRelease.nativeInstallDirectory(binaryPath: "/Volumes/Work/kimi/bin/kimi",
                                             kimiHome: "/Volumes/Work/kimi/") == "/Volumes/Work/kimi")
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
let notices = source("SipAI/Models/UpdateNotices.swift")
let runner = source("SipAI/Models/AgentRunner.swift")
let reset = source("SipAI/Models/FactoryReset.swift")
let content = source("SipAI/Views/ContentView.swift")
let settings = source("SipAI/Views/Settings/SettingsView.swift")
let sidebar = source("SipAI/Views/Sidebar/LeftSidebar.swift")
let navigation = source("SipAI/Views/Settings/SettingsNavigation.swift")
let manager = source("SipAI/Models/AgentManager.swift")
let sparkle = source("SipAI/Models/UpdateController.swift")
let guideModel = source("SipAI/Models/AgentGuide.swift")
let app = source("SipAI/SipAIApp.swift")
check("AgentCLIUpdates.swift is where it is expected", !model.isEmpty)
check("UpdateNotices.swift is where it is expected", !notices.isEmpty)

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

// `Process` makes the child the leader of a group of its own and
// `terminate()` already signals that group; a hand-rolled kill(-pgid)
// adds nothing, and read wrong it would name SipAI's own group.
check("nothing signals a process GROUP by hand", !codeOnly(model).contains("kill(-"))
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
// The route is shared with the Agent Guide's fresh install now
// (`runInstallerScript`); the update path hands the kimi environment
// in and the runner lays it on top of the agent-turn environment.
check("the installer is spawned through the same bounded runner, with its env on top",
      model.contains("environment: AgentCLIRelease.nativeInstallerEnvironment(installDirectory: installDirectory)")
      && model.contains("extraEnvironment: environment,"))
check("the installer's verdict is the version moving, like any other update",
      model.contains("before: before, after: installed, latestKnown:"))
check("claude's check reads the channel its settings name, off the MainActor",
      model.contains("release = release.onChannel(AgentCLIRelease.claudeChannel(settings: settings))")
      && model.contains("PlanAccountDetector.claudeSettingsFiles.compactMap { try? Data(contentsOf: $0) }"))
check("who manages an install is read beside its version and reaches the status rule",
      model.contains("return (version, Self.managedBy(key))")
      && model.contains("managedBy: s?.managedBy)")
      && model.contains("AgentInstallSource.current(agentKey: key)?.managedBy(agentKey: key)"))
check("the row says who manages a tool SipAI cannot update, and offers nothing",
      source("SipAI/Views/Settings/SettingsView.swift").contains("case .managedElsewhere(_, let manager):")
      && source("SipAI/Views/Settings/SettingsView.swift").contains("case .unknown, .versionOnly, .upToDate, .managedElsewhere:\n            EmptyView()"))
// Foundation raises when terminationStatus is read on a live process.
check("terminationStatus is read guarded", model.contains("p.isRunning ? nil : p.terminationStatus"))

print("structural — no banner; the badge instead")

// Nothing about updates is drawn over the window — not an update on
// offer, and not SipAI's install waiting for a turn: the badge carries
// both, and the line beside the logo says what happened.
check("no update banner is drawn over the window",
      !content.contains("CLIUpdateBanner") && !content.contains("bannerItems")
      && !content.contains("UpdateHoldBanner") && !content.contains("heldUpdateVersion")
      && !model.contains("bannerItems") && !model.contains("func dismissBanner"))
check("…and nothing routes an update notice to the Agent Guide",
      !content.contains("settingsTab = .agents"))
// Add Model is the window's one sheet; Settings is a mode of the main
// window that keeps the logo in view, so nothing about it holds a line.
check("the window says when a sheet is up, and the lockup whether it is covered",
      content.contains(".onChange(of: showingModelSetup) { _, showing in\n            UpdateAnnouncer.shared.setSheetPresented(showing)\n        }")
      && content.components(separatedBy: "setSheetPresented(").count == 2
      && content.range(of: #"showingSettings\b"#, options: .regularExpression) == nil
      && sidebar.contains(".background(LockupSheetCheck())")
      && notices.contains("appActive && !(sheetPresented && sheetCoversLockup())"))
check("the announcer follows SipAI in and out of the front",
      notices.contains("NSApplication.didBecomeActiveNotification")
      && notices.contains("NSApplication.didResignActiveNotification"))
// Beside "Settings" in the sidebar and beside "Updates" in Settings.
if let from = sidebar.range(of: "Text(\"Settings\", comment: \"Sidebar: open settings\")") {
    let after = sidebar[from.upperBound...].prefix(400)
    check("the badge sits beside Settings in the sidebar",
          after.contains("UpdateBadgeGlyph()") && after.contains("Spacer()"))
} else {
    check("the sidebar's Settings row is where it is expected", false)
}
// One label draws a section for the menu over the Settings row AND for
// the sidebar's list while Settings is open, so the badge is spelled
// once — and both of them use that label.
check("the badge sits beside Updates in the settings sections, in the menu and the sidebar list alike",
      navigation.contains("if tab == .updates {\n                UpdateBadgeGlyph()")
      && navigation.components(separatedBy: "UpdateBadgeGlyph()").count == 2
      && navigation.components(separatedBy: "SettingsSectionLabel(tab: tab").count == 3)
// The shape the banner had, in the mode chip's blue.
if let from = sidebar.range(of: "struct UpdateBadgeGlyph: View") {
    let glyph = sidebar[from.upperBound...].prefix(900)
    check("the badge is the banner's arrow-in-a-circle, in the mode chip's blue",
          glyph.contains("Image(systemName: \"arrow.down.circle\")")
          && glyph.contains(".foregroundStyle(SipDesign.blue)")
          && glyph.contains("if badge.isOwed"))
} else {
    check("UpdateBadgeGlyph is where it is expected", false)
}
check("the mode chip's blue is that same token",
      source("SipAI/Views/Chat/AgentComposer.swift").contains("? SipDesign.textSecondary : SipDesign.blue)"))
// Looking at the pane is the ONE thing that clears it — and a release
// found while the pane is up is one the user is looking at.
check("the Updates pane clears the badge on appearing, and while it is on screen",
      settings.contains("cliUpdates.paneAppeared()\n            badge.markSeen()")
      && settings.contains(".onChange(of: badge.items) { _, _ in badge.markSeen() }"))
check("nothing else clears it",
      [model, content, sidebar, navigation, sparkle, guideModel, app]
        .allSatisfy { !$0.contains("markSeen()") }
      && settings.components(separatedBy: "markSeen()").count == 3)
check("the monitor feeds the badge from the one derivation",
      model.contains("UpdateBadge.shared.setCLIItems(badge)")
      && model.contains("AgentCLIUpdateRules.badgeVersion("))
check("a hidden tool puts nothing on the badge",
      model.contains("guard !hiddenAgents.contains(agent.key),\n                  let status = newStatuses[agent.key],\n                  let version = AgentCLIUpdateRules.badgeVersion("))
// SipAI's own update: found, not found, skipped.
check("SipAI's own update feeds the badge from Sparkle's three answers",
      sparkle.contains("didFindValidUpdate item: SUAppcastItem")
      && sparkle.contains("func updaterDidNotFindUpdate(_ updater: SPUUpdater)")
      && sparkle.contains("userDidMake choice: SPUUserUpdateChoice")
      && sparkle.contains("guard choice == .skip else { return }")
      && sparkle.contains("if let availableUpdate { items.append(.app(version: availableUpdate.version)) }")
      && sparkle.contains("UpdateBadge.shared.setAppItems(items)"))
// SipAI's held install: said once beside the logo, marked on the badge,
// endable from Settings → Updates.
if let from = sparkle.range(of: "private func beginHold() {") {
    let body = sparkle[from.upperBound...].prefix(1200)
    check("a held SipAI install is said beside the logo and raises the badge",
          body.contains("publishBadge()")
          && body.contains("UpdateAnnouncer.shared.announce(")
          && body.contains("will install once the running turn finishes."))
} else {
    check("beginHold is where it is expected", false)
}
check("…the held item leaves the badge when the hold ends",
      sparkle.contains("if let heldUpdateVersion { items.append(.appInstall(version: heldUpdateVersion)) }")
      && sparkle.contains("heldUpdateVersion = nil\n        publishBadge()"))
check("…and Install Now stays in Settings → Updates", settings.contains("updates.installNow()"))
// A relaunch into a newer build says so, like a tool's update.
// Judged against the build THIS copy last launched as (`CopyLaunchRecord`,
// pinned in Verification/SparkleUpdate §1): every copy on a Mac shares
// the defaults, and one record lets an Xcode build silence the installed
// copy's update.
check("the relaunch an update installed says \"SipAI just updated to …\"",
      sparkle.contains("func noteLaunch()")
      && sparkle.contains("CopyLaunchRecord.note(")
      && sparkle.contains(".compareVersion(build, toVersion: than) == .orderedDescending")
      && sparkle.contains("String(localized: \"\\(name) just updated to \\(currentVersion)\"")
      && app.contains("updateController.noteLaunch()"))
check("…is compared by Sparkle's own comparator, on the build number",
      sparkle.contains("SUStandardVersionComparator.default\n            .compareVersion(version, toVersion: currentBuild) == .orderedDescending"))
check("…and the Updates pane names it with a way to Sparkle's window",
      settings.contains("if let available = updates.availableUpdate, !updates.isWaitingForQuietMoment {")
      && settings.contains("updates.checkForUpdates()\n                    } label: {\n                        Text(\"Update…\","))

print("structural — the automatic update")

// Both readings of the key — launch, and after a factory reset — must
// agree that absent means OFF.
check("the switch is off unless the user turns it on",
      model.contains("@Published private(set) var autoUpdateEnabled: Bool =\n        (UserDefaults.standard.object(forKey: AgentCLIUpdateMonitor.autoUpdateDefaultsKey)\n            as? Bool) ?? false")
      && model.contains("applyAutoUpdate((UserDefaults.standard.object(forKey: Self.autoUpdateDefaultsKey)\n                          as? Bool) ?? false)")
      && model.contains(#"autoUpdateDefaultsKey = "cliAutoUpdateEnabled""#))
check("the pane offers it, and only with the check it rests on",
      settings.contains("Text(\"Update these tools automatically\",")
      && settings.contains(".disabled(!cliUpdates.remoteChecksEnabled)"))
// ONE road for the button and the automatic update, owned codex included.
check("the row's button and the automatic update take one road",
      settings.contains("cliUpdates.startUpdate(agentKey: agent.key)")
      && !settings.contains("AgentGuideActions.shared.updateOwnedCodex")
      && model.contains("AgentGuideActions.shared.updateOwnedCodex(latest: latest)")
      // The attempt is spent only on an update that STARTED: a start the
      // Guide's slot refused leaves the version to try at the next call.
      && model.contains("if startUpdate(agentKey: key) { autoAttempted[key] = latest.text }")
      && model.contains("func startUpdate(agentKey key: String) -> Bool")
      && model.contains("func update(agentKey key: String) -> Bool"))
check("an owned codex is routed on the latest KNOWN, so a retry after a failure is routed too",
      model.contains("AgentInstallSource.current(agentKey: key)?.isOwnedBySipAI == true,\n           let latest = state[key]?.latest {"))
// The Update button's rule: never replace a binary under a running
// child. One spelling of "a turn of this agent is in flight".
check("it waits for a running turn by the Update button's own rule",
      model.contains("turnInFlight: agents?.hasTurnInFlight(agentKey: key) ?? true")
      && settings.contains("agents.hasTurnInFlight(agentKey: agent.key)")
      && manager.contains("func hasTurnInFlight(agentKey: String) -> Bool"))
check("a turn ending re-asks, asynchronously (Published fires in willSet)",
      model.contains("agents.$inFlightSends.map { _ in () }\n            .merge(with: agents.$externalInFlightSessions.map { _ in () })\n            .receive(on: DispatchQueue.main)"))
check("the monitor is handed the manager at launch",
      app.contains("AgentCLIUpdateMonitor.shared.start(config: configManager,\n                                                       agents: agentManager)"))
check("every check and every re-stat re-asks", model.components(separatedBy: "autoUpdateIfDue()").count >= 6)
// The slot is claimed before anything suspends — which is also what
// makes a turn sent from that moment on see the update and wait.
if let claim = model.range(of: "claim.updating = true"),
   let task = model.range(of: "Task { @MainActor in\n            let before = await readInstalledNow(key)") {
    check("update() claims the slot before it suspends", claim.lowerBound < task.lowerBound)
} else {
    check("update() claims the slot before it suspends", false)
}

print("structural — every update that landed is said")

check("every success is announced, pressed or automatic; a failure is not",
      model.contains("relearnAfterUpdate(agentKey: key)\n            // Said for every update that landed")
      && model.contains("            announceUpdate(agentKey: key, version: version)\n        }")
      && !model.contains("startedAutomatically") && !model.contains("if automatic"))
check("an update made outside SipAI is said when the re-stat sees it",
      model.contains("if let before = versionBefore, let after = version, after > before,")
      && model.contains("!hiddenAgents.contains(key), state[key]?.updateInFlight != true {\n                    announceUpdate(agentKey: key, version: after)"))
check("…only on a version that went UP, never on the first stat of a launch",
      model.contains("if previous != nil, current != previous {\n                relearnAfterUpdate(agentKey: key)"))
check("the re-stat runs every minute, and when SipAI comes to the front",
      model.contains("localInterval: TimeInterval = 60")
      && model.contains(".publisher(for: NSApplication.didBecomeActiveNotification)")
      && model.contains("Task { @MainActor [weak self] in await self?.refreshLocal() }"))

print("structural — a turn sent during an update waits for it")

check("the monitor answers whether it is updating a tool, and releases the waiters at the end",
      model.contains("func isUpdating(_ key: String) -> Bool {\n        state[key]?.updating == true")
      && model.contains("await updateWaiters.wait(for: key) { self.isUpdating(key) }")
      && model.contains("resumeUpdateWaiters(key)\n\n        if case .updated(let version) = verdict {"))
check("…including when the tool itself goes away",
      model.contains("publish()\n        resumeUpdateWaiters(key)\n    }"))
let agentRunner = source("SipAI/Models/AgentRunner.swift")
if let wait = agentRunner.range(of: "if AgentCLIUpdateMonitor.shared.isUpdating(agentKey) {"),
   let binary = agentRunner.range(of: "guard let binary = AgentManager.binaryPath(for: agentKey) else {"),
   let runOnce = agentRunner.range(of: "private func runOnce(text: String, options: AgentLaunchOptions,") {
    check("the runner waits BEFORE it reads the binary's path", runOnce.lowerBound < wait.lowerBound && wait.lowerBound < binary.lowerBound)
    let block = agentRunner[wait.lowerBound..<binary.lowerBound]
    check("…with the stall notice held until the spawn",
          block.contains("disarmStallNotice()") && block.contains("armStallNotice()"))
    // The same test guards every later await of `runOnce` (the kimi
    // policy write, the shell-environment read): a Stop inside one used
    // to spawn a ghost turn under the interrupted row.
    check("…and runs nothing for a turn stopped or replaced while it waited",
          block.contains("guard turnStillOurs() else { return }")
          && agentRunner.contains("token == runToken && !stopRequested && status.isRunning && !Task.isCancelled")
          && agentRunner.components(separatedBy: "guard turnStillOurs() else {").count >= 4)
} else {
    check("the runner's wait is where it is expected", false)
}
check("the wait's flag is cleared when the turn ends",
      agentRunner.contains("compacting = false\n            waitingForToolUpdate = false"))
check("the waiting row says the message will be sent after the update",
      source("SipAI/Views/Chat/AgentSessionView.swift").contains("if runner.waitingForToolUpdate {")
      && source("SipAI/Views/Chat/AgentSessionView.swift").contains("is updating. Your message will be sent when the update finishes."))

print("structural — the header's line")

// No user-visible sentence in this app names an agent outright.
check("the line names the agent through agentLabel",
      model.contains("config?.agentLabel(for: key, defaultName: name)")
      && model.contains("String(localized: \"\\(label) just updated to \\(version.text)\""))
check("the line takes the wordmark's place, on the cup's baseline, moving nothing",
      sidebar.contains("HStack(alignment: .lastTextBaseline, spacing: 10)")
      && sidebar.contains("Self.wordmark\n                .hidden()")
      && sidebar.contains(".overlay(alignment: .leadingLastTextBaseline)"))
check("each line is a new identity, so the next one rolls in over the last",
      sidebar.contains(".id(line.id)") && sidebar.contains("value: line?.id)"))
check("Settings → Display → Show update messages governs the lines, on by default",
      sidebar.contains("showsUpdateMessages ? announcer.current : nil")
      && sidebar.contains("SidebarBrandLockup(showsUpdateMessages: config.display.showUpdateMessages)")
      && app.contains("return display.showUpdateMessages\n")
      && source("SipAI/Models/ConfigManager.swift").contains("s.showUpdateMessages = d[\"update_messages\"] as? Bool ?? true")
      && source("SipAI/Models/ConfigManager.swift").contains("d[\"update_messages\"] = s.showUpdateMessages")
      && settings.contains("toggle(\"Show update messages\", value: \\.showUpdateMessages)\n"))
// The logo and app name are always drawn: the update lines take the
// name's place, and a switch that hid them left the lines nowhere to go.
// So there is no such switch, nothing reads one, and the update switch
// depends on nothing.
let displayPane: Substring = {
    guard let a = settings.range(of: "struct DisplayPane: View {"),
          let b = settings.range(of: "\n}\n", range: a.upperBound..<settings.endIndex)
    else { return "" }
    return settings[a.lowerBound..<b.upperBound]
}()
let messagesRow: Substring = {
    guard let a = displayPane.range(of: "toggle(\"Show update messages\""),
          let b = displayPane.range(of: "Divider()", range: a.upperBound..<displayPane.endIndex)
    else { return "" }
    return displayPane[a.lowerBound..<b.lowerBound]
}()
check("the logo and app name cannot be hidden: no switch, no setting, drawn unconditionally",
      !displayPane.contains("Show logo and app name")
        && !source("SipAI/Models/ConfigManager.swift").contains("showSidebarBrand")
        && source("SipAI/Models/ConfigManager.swift").contains("d.removeValue(forKey: \"sidebar_brand\")")
        && !app.contains("showSidebarBrand") && !sidebar.contains("showSidebarBrand")
        && !sidebar.contains("if config.display.showSidebarBrand"),
      "— with the logo off, the update messages had nowhere to show")
check("Show update messages is a row of its own — the plain toggle, no indent, never disabled",
      !displayPane.contains("subToggle(\"Show update messages\"")
        && !messagesRow.isEmpty && !messagesRow.contains(".padding(.leading")
        && !messagesRow.contains(".disabled("),
      "— its row and its sentence were indented, smaller and dimmer, as if it were one of a group's switches")
check("Reduce Motion gets a cross-fade", sidebar.contains("guard !reduceMotion else { return .opacity }"))
// Visible on every screen; a clock in it would re-render the window
// once a second forever.
check("the header and the badge carry no clock",
      !sidebar.contains("TimelineView") && !notices.contains("Timer.scheduledTimer"))

// A key that is not registered outlives a reset that promised to clear
// every setting — and the copy in memory has to follow the key.
check("the new keys are registered for factory reset",
      reset.contains("UpdateBadge.seenDefaultsKey") && reset.contains("AgentCLIUpdateMonitor.autoUpdateDefaultsKey")
      && reset.contains("UpdateController.availableUpdateDefaultsKey")
      && reset.contains("AgentCLIUpdateMonitor.remoteChecksDefaultsKey"))
check("…the retired banner key too, for installs that carry it", reset.contains("\"cliUpdateDismissed\""))
check("…and the reset drops the copies in memory",
      reset.contains("AgentCLIUpdateMonitor.shared.forgetSwitches()") && reset.contains("UpdateBadge.shared.forgetSeen()"))
check("the keys' literal values are the ones the harness stubs spell",
      notices.contains(#"seenDefaultsKey = "updateBadgeSeen""#)
      && sparkle.contains(#"availableUpdateDefaultsKey = "sipaiAvailableUpdate""#)
      && model.contains(#"remoteChecksDefaultsKey = "cliUpdateChecksEnabled""#))
// Mac-only UI state. config.json is shared with the CLI, which has no
// use for any of this.
check("the switches and the seen versions live in UserDefaults, not config.json",
      model.contains("UserDefaults.standard") && !model.contains("config.setDisplay")
      && notices.contains("defaults.set(seen, forKey: Self.seenDefaultsKey)"))

// The rows sit beside the app's own update controls, under Settings →
// Updates. Installing, signing in and deleting a tool are the Agent
// Guide's; the difference between the version on disk and the newest
// one released is this pane's.
check("the row names the agent through agentLabel",
      settings.contains("config.agentLabel(for: agent.key"))
check("the Updates pane lists one row per installed tool, under its own header",
      settings.contains("CLIUpdateRow(agent:") && settings.contains("ForEach(toolRows)")
      && settings.contains("Text(\"Command-line tools\", comment:"))
// Presence gates every surface: a tool the user unticked is asked
// nothing, so it cannot carry a row that claims anything.
check("a hidden tool gets no update row",
      settings.contains("cliUpdates.installedAgents.filter { !cliUpdates.hiddenAgents.contains($0.key) }"))
check("the Agent Guide hosts no update row of its own",
      !source("SipAI/Views/Settings/AgentGuidePane.swift").contains("CLIUpdateRow"))
// The interpolating Text overload markdown-parses its result.
check("no interpolated Text literal reaches the rows, the badge or the header",
      !hasInterpolatedTextLiteral(codeOnly(settings))
      && !hasInterpolatedTextLiteral(codeOnly(content))
      && !hasInterpolatedTextLiteral(codeOnly(sidebar)))
check("versions are printed verbatim",
      settings.contains("Text(verbatim: cliUpdates.installed[agent.key]?.text"))
check("the header's line is drawn verbatim", sidebar.contains("Text(verbatim: line.text)"))

// Cadence: nothing here polls.
check("release checks are 8-hourly, not per-minute",
      model.contains("remoteInterval: TimeInterval = 8 * 60 * 60"))
check("the local re-stat is a minute apart, and spawns nothing unless the binary moved",
      model.contains("localInterval: TimeInterval = 60")
      && model.contains("guard current != previous || state[key]?.installed == nil else { continue }"))
check("opening the pane does not re-check within the hour",
      model.contains("paneOpenFreshness: TimeInterval = 60 * 60"))

// Every new string is in the catalog, in both languages — and the
// banner's sentence is gone with the banner.
if let data = FileManager.default.contents(atPath: sourceRoot + "/SipAI/Resources/Localizable.xcstrings"),
   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let strings = root["strings"] as? [String: Any] {
    for key in ["Agent Guide", "Command-line tools", "Up to date", "New version %@", "Updating…",
                "Cancelling…",
                "Update did not complete", "Details", "Update",
                "Finish the running turn before updating this tool.",
                "The updater printed nothing and exited with code %lld.",
                "The updater printed nothing and did not exit cleanly.",
                "The installer could not be downloaded from %@.",
                "The installer could not be staged on disk.",
                "%@ just updated to %@", "An update is available", "Update…",
                "Update these tools automatically", "Turn on the check above first.",
                "When a newer version is found, SipAI updates the tool by itself, waiting for any running turn of that tool to finish first, and says so next to the logo in the sidebar.",
                "This tool updates by itself once the running turn finishes.",
                "%@ is updating. Your message will be sent when the update finishes.",
                "SipAI %@ will install once the running turn finishes.",
                "Show update messages",
                "When SipAI or an agent tool is updated, a short message takes the app name's place for five seconds.",
                "Managed by %@",
                "The tool's own updater leaves this copy to %@, which SipAI does not run. Update it there, in Terminal."] {
        let entry = strings[key] as? [String: Any]
        let zh = ((entry?["localizations"] as? [String: Any])?["zh-Hans"]
                    as? [String: Any])?["stringUnit"] as? [String: Any]
        check("\"\(key)\" is translated", zh?["value"] is String)
    }
    check("the banners' sentences left the catalog with the banners",
          strings["%@ has a new version available (%@). Update it in Settings → Updates."] == nil
          && strings["SipAI %@ is ready to install. It will relaunch once the running agent turn finishes."] == nil)
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
check("the refresh is what CodexModelListRefresh runs, and its answer feeds the tiers",
      launch.contains("await CodexModelListRefresh.answer(binary: binary)")
      && launch.contains("Self.listedTiers(fromAnswer: answer)"))
check("the codex window honours model_context_window, clamped to max_context_window",
      launch.contains("TomlScalar.integer(line, key: \"model_context_window\")")
      && launch.contains("base = cap > 0 ? min(override, cap) : override"))
check("the refresh speaks app-server's model/list",
      model.contains("\"method\":\"model/list\"")
      && model.contains("p.arguments = [\"app-server\"]"))
// stdin is what keeps app-server alive: closing it before the answer
// has been read ends the process before it answers (measured).
let refreshCode = codeOnly(model)
// The multi-request form reads every awaited id from the same buffer;
// either spelling is the read that must precede the close.
let answerAt = (refreshCode.range(of: "answered = answers(in: received, ids: awaiting)")
                ?? refreshCode.range(of: "answered = answer(in: received)"))?.lowerBound
let closeAt = refreshCode.range(of: "try? input.fileHandleForWriting.close()")?.lowerBound
check("stdin is held open until the answer is read, then closed",
      answerAt != nil && closeAt != nil && answerAt! < closeAt!)
check("the refresh child is stopped by pid through AgentCLIProbe.stop",
      model.contains("AgentCLIProbe.stop(p)\n        p.waitUntilExit()"))
check("containsAnswer: the id-2 result ends the wait",
      CodexAppServerCall.containsAnswer(
        Data((#"{"id":2,"jsonrpc":"2.0","result":{"data":[]}}"# + "\n").utf8)))
check("containsAnswer: an error answer ends it too",
      CodexAppServerCall.containsAnswer(
        Data((#"{"id":2,"jsonrpc":"2.0","error":{"code":1,"message":"x"}}"# + "\n").utf8)))
check("containsAnswer: a notification does not",
      !CodexAppServerCall.containsAnswer(
        Data((#"{"jsonrpc":"2.0","method":"remoteControl/status/changed","params":null}"# + "\n").utf8)))
check("containsAnswer: the initialize answer (id 1) does not",
      !CodexAppServerCall.containsAnswer(
        Data(#"{"id":1,"jsonrpc":"2.0","result":{}}"#.utf8)))
check("containsAnswer: a half-written line does not",
      !CodexAppServerCall.containsAnswer(
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
