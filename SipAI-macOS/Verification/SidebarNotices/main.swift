// main.swift — the bubble beside the sidebar's logo (`SidebarNotices`,
// `SidebarBrandLockup`).
//
// The bubble takes the wordmark's place, 10 pt right of the mark and
// ending where the … dots of the rows below end, its middle on the mark's
// middle: one line of the session titles' font is a short stadium, and a
// longer message wraps, the bubble growing from that middle both ways but
// never taller than the mark with its straw — past that the text is cut,
// and said whole on hover. The running turn clock's sky blue, black text.
// Updates on offer stay there with an Update button and a × until one is
// used; what happened — a card waiting on the user (10 s), a chat or
// agent turn that ended (5 s), an update that landed (5 s) — queues, one
// at a time, in the update on offer's place.
//
// Every one of those fails quietly: a bubble a few points off the mark's
// middle, a second line clipped, a notice that never leaves, an
// update closed for good. So the rules run pure, the driver runs on a
// short clock, the REAL lockup is rendered with the REAL logo rendition
// and measured in pixels, and the wiring is read off the sources.
//
// Nothing here is part of the app target: this directory sits outside
// SipAI/, so these files are never compiled into the product.
//
//   ./run.sh [source-root]

import AppKit
import Combine
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

/// The file with its `//` comments removed: a check about what the code
/// DOES must not be satisfied by a comment explaining it.
func codeOnly(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let slashes = line.range(of: "//") else { return line }
        return line[line.startIndex..<slashes.lowerBound]
    }.joined(separator: "\n")
}

// MARK: - 1. The queue

print("1. SidebarNoticeQueue — one at a time, each its full time")

let t0 = Date(timeIntervalSince1970: 1_000_000)
let action = SidebarNotice(kind: .needsAction, line: "A", sentence: "A.", target: .session("s1"))
let done = SidebarNotice(kind: .finished, line: "B", sentence: "B.", target: .session("s2"))
let landed = SidebarNotice.updated(name: "Codex", version: "0.170.0")
check("a card waiting on the user stays 10 s, news 5 s",
      action.duration == 10 && done.duration == 5 && landed.duration == 5)
var q = SidebarNoticeQueue()
check("an empty queue shows nothing", q.current == nil && q.endsAt() == nil)
q.enqueue(action, now: t0)
check("the first notice shows at once, for its own time",
      q.current == action && q.endsAt() == t0.addingTimeInterval(10))
q.enqueue(done, now: t0.addingTimeInterval(1))
q.enqueue(landed, now: t0.addingTimeInterval(2))
check("later ones WAIT, in the order they came", q.current == action && q.waiting == [done, landed])
q.advance(now: t0.addingTimeInterval(9.9))
check("an early wake-up cuts nothing short", q.current == action)
q.advance(now: t0.addingTimeInterval(10))
check("at its end the next takes over directly, with a full turn of its own",
      q.current == done && q.endsAt() == t0.addingTimeInterval(15))
q.advance(now: t0.addingTimeInterval(16))
check("a late wake-up starts the next one's turn when it appears",
      q.current == landed && q.endsAt() == t0.addingTimeInterval(21))
q.advance(now: t0.addingTimeInterval(21))
check("an empty queue gives the place back", q.current == nil && q.waiting.isEmpty)

var q2 = SidebarNoticeQueue()
q2.enqueue(action, now: t0)
q2.enqueue(done, now: t0)
check("two notices about one session's card say one thing, whatever their words",
      q2.holds(key: SidebarNotice(kind: .needsAction, line: "other", sentence: "",
                                  target: .session("s1")).key)
      && !q2.holds(key: SidebarNotice(kind: .needsAction, line: "A", sentence: "",
                                      target: .session("s9")).key))
q2.keep(where: { $0 != done }, now: t0.addingTimeInterval(1))
check("one waiting that stops being true leaves the line", q2.current == action && q2.waiting.isEmpty)
q2.enqueue(done, now: t0.addingTimeInterval(2))
q2.keep(where: { $0 != action }, now: t0.addingTimeInterval(3))
check("the one on screen that stops being true gives its place at once",
      q2.current == done && q2.endsAt() == t0.addingTimeInterval(8))
q2.takeDown(now: t0.addingTimeInterval(4))
check("a click takes the one on screen down", q2.current == nil)
var q3 = SidebarNoticeQueue()
q3.enqueue(action, now: t0)
check("the scale shortens the clock and nothing else", q3.endsAt(scale: 0.1) == t0.addingTimeInterval(1))

// MARK: - 2. The update on offer

print("2. UpdateOfferRules — which update stands beside the logo")

let app = UpdateBadgeItem.app(version: "7", display: "1.0.6")
let held = UpdateBadgeItem.appInstall(version: "1.0.6")
let claude = UpdateBadgeItem.cli(agentKey: "claude_code", version: "2.1.300", name: "Claude Code")
let claudeFailed = UpdateBadgeItem.cli(agentKey: "claude_code", version: "2.1.300",
                                       name: "Claude Code", failed: true)
let claudeTimedOut = UpdateBadgeItem.cli(agentKey: "claude_code", version: "2.1.300",
                                         name: "Claude Code", failed: true,
                                         failure: .claudeDownloadTimedOut)
check("a tool's key and kind, SipAI's two",
      claude.key == "cli:claude_code" && claude.kind == .cli(agentKey: "claude_code")
      && app.kind == .app && held.kind == .appInstall)
check("SipAI's release is keyed on its build and read as its version",
      app.version == "7" && app.shownVersion == "1.0.6" && app.name == "SipAI")
check("nothing on offer → no bubble", UpdateOfferRules.shown([], closed: [:]) == nil)
check("the first on offer stands", UpdateOfferRules.shown([app, claude], closed: [:]) == app)
check("SipAI's release is passed over while its install is held",
      UpdateOfferRules.shown([app, held, claude], closed: [:]) == held)
var closed = UpdateOfferRules.closing(app, in: [:])
check("closed at its version, the next one stands",
      UpdateOfferRules.shown([app, claude], closed: closed) == claude)
check("a newer release of a closed one comes back",
      UpdateOfferRules.shown([.app(version: "8", display: "1.0.7")], closed: closed)?.version == "8")
closed = UpdateOfferRules.closing(claude, in: closed)
check("every one closed → no bubble", UpdateOfferRules.shown([app, claude], closed: closed) == nil)
check("the same release, once its update has failed, is news again",
      UpdateOfferRules.shown([claudeFailed], closed: closed) == claudeFailed)
check("…and closing the failure keeps it closed",
      UpdateOfferRules.shown([claudeFailed],
                             closed: UpdateOfferRules.closing(claudeFailed, in: closed)) == nil)
check("…whatever the failure's cause: a closed failure stays closed when the next attempt fails for another reason",
      UpdateOfferRules.token(claudeTimedOut) == UpdateOfferRules.token(claudeFailed)
      && UpdateOfferRules.shown([claudeTimedOut],
                                closed: UpdateOfferRules.closing(claudeFailed, in: closed)) == nil)

// MARK: - 3. The words

print("3. SidebarNoticeWords — a short line, and the whole sentence")

let a1 = SidebarNoticeWords.needsAction(agent: "Claude Code", group: "SipAI")
check("a card: “Claude Code · SipAI needs you”", a1.line == "Claude Code · SipAI needs you", a1.line)
check("…said whole on hover", a1.sentence == "A session with Claude Code under the “SipAI” group needs your action.", a1.sentence)
let a2 = SidebarNoticeWords.needsAction(agent: "Codex", group: nil)
check("…with no group, none is named",
      a2.line == "Codex needs you" && a2.sentence == "A session with Codex needs your action.")
let f1 = SidebarNoticeWords.agentTurnEnded(agent: "Kimi Code", group: "Reports", failed: false)
check("an agent turn that ended: “Kimi Code · Reports finished”",
      f1.line == "Kimi Code · Reports finished"
      && f1.sentence == "An agent session with Kimi Code under the “Reports” group just finished its response.", f1.sentence)
let f2 = SidebarNoticeWords.agentTurnEnded(agent: "Kimi Code", group: "Reports", failed: true)
check("…one that failed says so, never “finished”",
      f2.line == "Kimi Code · Reports failed" && f2.sentence.hasSuffix("ended with an error."))
let c1 = SidebarNoticeWords.chatTurnEnded(provider: "OpenAI", group: "Research", failed: false)
check("a chat: “OpenAI chat · Research finished”",
      c1.line == "OpenAI chat · Research finished"
      && c1.sentence == "A chat session with OpenAI under the “Research” group just finished its response.", c1.sentence)
let c2 = SidebarNoticeWords.chatTurnEnded(provider: "NVIDIA", group: nil, failed: false)
check("a chat outside a group names none",
      c2.line == "NVIDIA chat finished" && c2.sentence == "A chat session with NVIDIA just finished its response.")
// "A" or "An" before a name is decided by how the name sounds — "an
// NVIDIA chat", "an xAI chat" — which nothing can read off its letters.
let sentences = [a1, a2, f1, f2, c1, c2,
                 SidebarNoticeWords.chatTurnEnded(provider: "xAI", group: "G", failed: true),
                 SidebarNoticeWords.agentTurnEnded(agent: "Opus helper", group: nil, failed: false)]
    .map(\.sentence)
check("no article stands before a name: every sentence opens on a fixed noun",
      sentences.allSatisfy {
          $0.hasPrefix("A session with ") || $0.hasPrefix("An agent session with ")
              || $0.hasPrefix("A chat session with ")
      })
let u = SidebarNoticeWords.updated(name: "Claude Code", version: "2.1.300")
check("an update that landed: a short line, and the sentence it always had",
      u.line == "Claude Code updated to 2.1.300" && u.sentence == "Claude Code just updated to 2.1.300")
check("an update on offer: the name and the version, the sentence on hover",
      SidebarNoticeWords.offer(claude).line == "Claude Code 2.1.300"
      && SidebarNoticeWords.offer(claude).sentence == "Claude Code 2.1.300 is available.")
check("…a failed one says it did not update",
      SidebarNoticeWords.offer(claudeFailed).sentence == "Claude Code did not update to 2.1.300.")

// Claude Code's updater gives one download ten minutes and then fails the
// update in these words, on stderr, exiting 1 — what `claude update` prints
// in a throwaway home with the limit shortened through Claude Code's own
// test setting.
let claudeTimedOutOutput = """
    Current version: 2.1.318
    Checking for updates to latest version...
    Updating to 2.1.319...
    Error: Failed to install native update
    TelemetrySafeError: Download timed out: exceeded the total deadline
    Try running "claude doctor" for diagnostics
    """
check("Claude Code's own words for its download limit are read as that cause",
      CLIUpdateFailure.read(agentKey: "claude_code", output: claudeTimedOutOutput) == .claudeDownloadTimedOut)
check("…from Claude Code alone: the same words from another tool are no cause SipAI names",
      CLIUpdateFailure.read(agentKey: "codex", output: claudeTimedOutOutput) == nil
      && CLIUpdateFailure.read(agentKey: "kimi", output: claudeTimedOutOutput) == nil)
check("…and none of Claude Code's other failures is called the time limit: a stalled download, no answer at all",
      CLIUpdateFailure.read(agentKey: "claude_code", output: """
          Updating to 2.1.319...
          Error: Failed to install native update
          StallTimeoutError: Download stalled: no data received for 120 seconds
          Try running "claude doctor" for diagnostics
          """) == nil
      && CLIUpdateFailure.read(agentKey: "claude_code", output: "Failed to check for updates") == nil
      && CLIUpdateFailure.read(agentKey: "claude_code", output: "") == nil)
let timedOut = SidebarNoticeWords.offer(claudeTimedOut)
check("…one Claude Code stopped at its own time limit says that cause on the line: “10-min timeout”",
      timedOut.line == "10-min timeout", timedOut.line)
check("…and whole on hover, the version and whose limit it is",
      timedOut.sentence == "Claude Code did not update to 2.1.300: its download timed out. "
          + "Claude Code stops a download that takes longer than 10 minutes.", timedOut.sentence)
check("…under the label the user gave the tool",
      SidebarNoticeWords.offer(.cli(agentKey: "claude_code", version: "2.1.300", name: "Claude",
                                    failed: true, failure: .claudeDownloadTimedOut)).sentence
          == "Claude did not update to 2.1.300: its download timed out. "
          + "Claude stops a download that takes longer than 10 minutes.")
check("…a cause is always a failure", UpdateBadgeItem.cli(agentKey: "claude_code", version: "2.1.300",
                                                         failure: .claudeDownloadTimedOut).failed)
check("…its button still tries again", SidebarNoticeWords.offerAction(claudeTimedOut) == "Update Claude Code to 2.1.300")
check("…SipAI's held install says it waits for the turn",
      SidebarNoticeWords.offer(held).line == "SipAI 1.0.6"
      && SidebarNoticeWords.offer(held).sentence == "SipAI 1.0.6 will install once the running turn finishes.")
check("…its button names what it does: update, or install now",
      SidebarNoticeWords.offerAction(claude) == "Update Claude Code to 2.1.300"
      && SidebarNoticeWords.offerAction(held).hasPrefix("Install SipAI 1.0.6 now."))

// MARK: - 3b. Claude Code's limit, read off the installed claude

print("3b. The installed Claude Code: its download limit and the words it fails in")

// The bubble states two facts of Claude Code's: the sentence its updater
// fails in when a download runs out of time, and how long it gives one
// download. Both are read off the installed executable, so an upgrade that
// moves either fails here instead of leaving the bubble saying something
// untrue. A launcher or a script (an npm or Homebrew shim) holds neither,
// and is passed over.

/// Where `needle` first occurs in `data` at or after `from`.
func offset(of needle: String, in data: Data, from: Int = 0) -> Int? {
    let bytes = Array(needle.utf8)
    return data.withUnsafeBytes { raw -> Int? in
        guard let base = raw.baseAddress, from >= 0, from < raw.count else { return nil }
        return bytes.withUnsafeBytes { nb -> Int? in
            guard let hit = memmem(base + from, raw.count - from, nb.baseAddress, nb.count) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }
}

/// The text of `data[range]`, as far as it is UTF-8.
func text(_ data: Data, _ range: Range<Int>) -> String {
    let clamped = max(0, range.lowerBound)..<min(data.count, range.upperBound)
    return String(decoding: data[clamped], as: UTF8.self)
}

/// The milliseconds Claude Code gives one download: the value its own test
/// setting stands in for, `Number(…_FOR_TESTING)||<name>`, as `<name>=<value>`
/// a little before it.
func claudeDownloadLimitMilliseconds(_ data: Data) -> Double? {
    let knob = "CLAUDE_CODE_DOWNLOAD_DEADLINE_MS_FOR_TESTING)||"
    guard let at = offset(of: knob, in: data) else { return nil }
    let after = text(data, (at + knob.utf8.count)..<(at + knob.utf8.count + 64))
    let name = String(after.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" })
    guard !name.isEmpty else { return nil }
    let before = text(data, (at - 4096)..<at)
    let pattern = "[,; ]" + NSRegularExpression.escapedPattern(for: name) + "=([0-9]+(?:\\.[0-9]+)?(?:e[0-9]+)?)[,;]"
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.matches(in: before, range: NSRange(before.startIndex..., in: before)).last,
          let value = Range(match.range(at: 1), in: before) else { return nil }
    return Double(before[value])
}

let claudePath: String? = {
    var candidates = [NSHomeDirectory() + "/.local/bin/claude"]
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        candidates.append(String(dir) + "/claude")
    }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
}()
let claudeSize = claudePath.flatMap {
    (try? FileManager.default.attributesOfItem(atPath: $0))?[.size] as? NSNumber
}?.intValue ?? 0
if let claudePath, claudeSize > 10_000_000, let executable = try? Data(contentsOf: URL(fileURLWithPath: claudePath)) {
    check("the installed Claude Code fails a timed-out download in the words SipAI reads",
          offset(of: CLIUpdateFailure.claudeDownloadTimedOutSentence, in: executable) != nil, claudePath)
    let limit = claudeDownloadLimitMilliseconds(executable)
    check("…and gives one download the \(CLIUpdateFailure.claudeDownloadLimitMinutes) minutes the bubble names",
          limit == Double(CLIUpdateFailure.claudeDownloadLimitMinutes) * 60_000,
          "read \(limit.map { String(format: "%.0f ms", $0) } ?? "nothing") in \(claudePath)")
} else {
    print("  note no Claude Code executable found (only a launcher, or none) — its limit and words not read")
}

// MARK: - 4. The driver

print("4. SidebarNotices — the real driver, on a short clock")

// A suite named by an ABSOLUTE path keeps its plist in that folder and
// never touches ~/Library/Preferences.
let prefsDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("sipai-notices-prefs-\(getpid())", isDirectory: true)
try? FileManager.default.createDirectory(at: prefsDir, withIntermediateDirectories: true)
func suite(_ name: String) -> UserDefaults {
    let path = prefsDir.appendingPathComponent(name).path
    let defaults = UserDefaults(suiteName: path)!
    defaults.removePersistentDomain(forName: path)
    return defaults
}
/// 10 s → 0.3 s, 5 s → 0.15 s.
let scale = 0.03

do {
    let notices = SidebarNotices(defaults: suite("n1"), badge: UpdateBadge(defaults: suite("b1")), scale: scale)
    notices.setAppActive(true)
    var shown: [(Date, String?)] = []
    let watch = notices.$current.dropFirst().sink { shown.append((Date(), $0?.line)) }
    let began = Date()
    notices.post(.needsAction(agent: "Claude Code", group: "SipAI", sessionId: "s1", requestId: "r1"))
    notices.post(.needsAction(agent: "Claude Code", group: "SipAI", sessionId: "s1", requestId: "r2"))
    notices.post(.agentTurnEnded(agent: "Codex", group: "Web", sessionId: "s2", failed: false))
    try? await Task.sleep(nanoseconds: 750_000_000)
    watch.cancel()
    let lines = shown.map(\.1)
    check("queued in the order they came, each said once, then the place given back",
          lines == ["Claude Code · SipAI needs you", "Codex · Web finished", nil], "\(lines)")
    if lines.count == 3 {
        let first = shown[1].0.timeIntervalSince(shown[0].0)
        let second = shown[2].0.timeIntervalSince(shown[1].0)
        check("a card stays twice as long as a finished turn (10 s and 5 s in the app)",
              first >= 0.29 && first < 0.5 && second >= 0.14 && second < 0.32,
              String(format: "%.2f %.2f", first, second))
        check("the first appeared at once", shown[0].0.timeIntervalSince(began) < 0.05)
    }
}

do {
    let notices = SidebarNotices(defaults: suite("n2"), badge: UpdateBadge(defaults: suite("b2")), scale: scale)
    notices.setAppActive(true)
    notices.isEnabled = { false }
    notices.post(.updated(name: "Codex", version: "0.170.0"))
    check("switched off in Settings → Display, nothing is queued", notices.current == nil)
    notices.isEnabled = { true }

    notices.setAppActive(false)
    var stillTrue: Set<String> = ["s1", "s2", "s3"]
    notices.isStillTrue = { notice in
        if case .session(let id)? = notice.target { return stillTrue.contains(id) }
        return true
    }
    for id in ["s1", "s2", "s3"] {
        notices.post(.agentTurnEnded(agent: "Codex", group: "Web", sessionId: id, failed: false))
    }
    check("SipAI behind another app: held, not shown", notices.current == nil)
    // The first of them is opened meanwhile — from the Dock's window list,
    // a notification — and nothing re-asked while they were held.
    stillTrue.remove("s1")
    notices.setAppActive(true)
    check("…started on coming back, without what stopped being true meanwhile",
          notices.current?.target == .session("s2"))
    stillTrue.remove("s2")
    notices.revalidate()
    check("a notice whose session was opened goes at once, and the next takes its place",
          notices.current?.target == .session("s3"))
    var opened: [SidebarNoticeTarget] = []
    notices.open = { opened.append($0) }
    if let current = notices.current { notices.click(current) }
    check("a click opens what the notice names, and takes it down",
          opened == [.session("s3")] && notices.current == nil)
    notices.post(.updated(name: "Codex", version: "0.170.1"))
    if let current = notices.current { notices.click(current) }
    check("…a notice that names nothing opens nothing, and stays",
          opened.count == 1 && notices.current?.kind == .updated)
}

do {
    // Held while SipAI was behind another app, then the switch went off
    // before anyone could see it: shown late, it would be a notice the
    // user turned off.
    let held = SidebarNotices(defaults: suite("n7"), badge: UpdateBadge(defaults: suite("b7")), scale: scale)
    held.setAppActive(false)
    held.post(.updated(name: "Codex", version: "0.170.2"))
    held.isEnabled = { false }
    held.setAppActive(true)
    check("a held notice switched off meanwhile is dropped, not shown late", held.current == nil)
    held.isEnabled = { true }
    held.setAppActive(false)
    held.setAppActive(true)
    check("…and does not come back when the switch is turned on again", held.current == nil)
}

do {
    let away = SidebarNotices(defaults: suite("n6"), badge: UpdateBadge(defaults: suite("b6")), scale: scale)
    away.setAppActive(false)
    let longAgo = Date().addingTimeInterval(-(SidebarNotices.heldTurnLimit + 60))
    var old = SidebarNotice.agentTurnEnded(agent: "Codex", group: "Nightly", sessionId: "run1", failed: false)
    old.postedAt = longAgo
    var oldCard = SidebarNotice.needsAction(agent: "Codex", group: "Nightly", sessionId: "run2", requestId: "r")
    oldCard.postedAt = longAgo
    var oldUpdate = SidebarNotice.updated(name: "Codex", version: "0.171.0")
    oldUpdate.postedAt = longAgo
    away.post(old)
    away.post(oldCard)
    away.post(.agentTurnEnded(agent: "Codex", group: "Nightly", sessionId: "run3", failed: false))
    away.post(oldUpdate)
    away.setAppActive(true)
    var seen: [String] = []
    while let current = away.current {
        seen.append(current.line)
        if current.target != nil { away.click(current) } else { break }
    }
    check("a turn's end held for over two minutes is dropped on coming back; a waiting card, an update and a fresh end are said",
          seen == ["Codex · Nightly needs you", "Codex · Nightly finished", "Codex updated to 0.171.0"], "\(seen)")
    check("…the limit is two minutes", SidebarNotices.heldTurnLimit == 120)
}

do {
    let covered = SidebarNotices(defaults: suite("n3"), badge: UpdateBadge(defaults: suite("b3")), scale: scale)
    covered.setAppActive(true)
    covered.sheetCoversLockup = { true }
    covered.setSheetPresented(true)
    covered.post(.updated(name: "Kimi Code", version: "2.2.0"))
    check("a sheet over the logo holds a notice", covered.current == nil)
    covered.setSheetPresented(false)
    check("…closing it starts it", covered.current?.line == "Kimi Code updated to 2.2.0")
    let beside = SidebarNotices(defaults: suite("n4"), badge: UpdateBadge(defaults: suite("b4")), scale: scale)
    beside.setAppActive(true)
    beside.sheetCoversLockup = { false }
    beside.setSheetPresented(true)
    beside.post(.updated(name: "Kimi Code", version: "2.2.0"))
    check("a sheet that leaves the logo in view holds nothing", beside.current != nil)
}

do {
    let badgeDefaults = suite("b5"), noticeDefaults = suite("n5")
    let badge = UpdateBadge(defaults: badgeDefaults)
    let notices = SidebarNotices(defaults: noticeDefaults, badge: badge, scale: scale)
    check("no update on offer → none stands", notices.offer == nil)
    badge.setAppItems([app])
    badge.setCLIItems([claude])
    check("the badge's items are on offer, SipAI's own first", notices.offer == app)
    notices.close(app)
    check("the × takes it down, and the next stands", notices.offer == claude)
    check("…what was closed is kept, at its version",
          noticeDefaults.dictionary(forKey: SidebarNotices.closedDefaultsKey) as? [String: String] == ["app": "7"])
    var ran: [UpdateBadgeItem] = []
    notices.performOffer = { ran.append($0); return false }
    notices.act(on: claude)
    check("an Update that could not start leaves the offer standing", ran == [claude] && notices.offer == claude)
    notices.performOffer = { ran.append($0); return true }
    notices.act(on: claude)
    check("one that started takes it down", notices.offer == nil)
    badge.setCLIItems([claudeFailed])
    check("the same release's FAILED update comes back", notices.offer == claudeFailed)
    let relaunched = SidebarNotices(defaults: noticeDefaults, badge: badge, scale: scale)
    check("a relaunch keeps what was closed", relaunched.offer == claudeFailed)
    badge.setAppItems([app, held])
    check("an install held for a turn stands, over the release it installs", notices.offer == held)
    notices.close(held)
    check("…closed, the next stands", notices.offer == claudeFailed)
    notices.reopen(key: UpdateBadgeItem.appInstallKey)
    check("a new hold is offered anew, whatever was closed before", notices.offer == held)
    notices.forgetClosed()
    badge.setAppItems([app])
    check("a factory reset forgets what was closed", notices.offer == app)
}
try? FileManager.default.removeItem(at: prefsDir)

// MARK: - 5. The lockup, rendered

print("5. The lockup, rendered — the real view and the real logo, in pixels")

/// An RGBA bitmap, row 0 at the TOP.
struct Bitmap: Equatable {
    let w: Int, h: Int
    let px: [UInt8]
    init(_ cg: CGImage) {
        let width = cg.width, height = cg.height
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        w = width; h = height; px = buf
    }
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * w + x) * 4
        return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
    }
    func near(_ x: Int, _ y: Int, _ c: (Int, Int, Int), _ tol: Int = 10) -> Bool {
        let p = rgb(x, y)
        return abs(p.0 - c.0) <= tol && abs(p.1 - c.1) <= tol && abs(p.2 - c.2) <= tol
    }
    func dark(_ x: Int, _ y: Int) -> Bool {
        let p = rgb(x, y)
        return max(p.0, p.1, p.2) < 90
    }
    /// The same picture: one size, every channel within a few levels — two
    /// renders of the same text differ by a level here and there.
    func matches(_ other: Bitmap) -> Bool {
        guard w == other.w, h == other.h else { return false }
        return zip(px, other.px).allSatisfy { abs(Int($0) - Int($1)) <= 3 }
    }
}

let px: CGFloat = 4
let lightFill = (135, 206, 235), darkFill = (160, 220, 245)
let white = (255, 255, 255), surfaceDark = (44, 44, 46)

let logoURL = URL(fileURLWithPath: sourceRoot
                  + "/SipAI/Resources/Assets.xcassets/SipAI-Logo-54.imageset/light_54@2x.png")
guard let logoImage = NSImage(contentsOf: logoURL) else {
    print("  FAIL the logo rendition is not at \(logoURL.path)")
    exit(1)
}
logoImage.size = NSSize(width: 40, height: 54)
let logo = Image(nsImage: logoImage)

/// `SIDEBAR_NOTICES_RENDER=<dir>` writes every render there as a PNG, to look at.
let renderDir = ProcessInfo.processInfo.environment["SIDEBAR_NOTICES_RENDER"]
var renderCount = 0
func save(_ image: CGImage, _ name: String) {
    guard let renderDir else { return }
    renderCount += 1
    let url = URL(fileURLWithPath: renderDir).appendingPathComponent(String(format: "%02d-", renderCount) + name + ".png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

/// The tier a font scale belongs to, so the environment is set as the app's
/// root sets it — line spacing included, which the bubble must not follow.
func tier(of fontScale: CGFloat) -> FontTier {
    FontTier.allCases.first { $0.scale == fontScale } ?? .standard
}

@MainActor
func render(width: CGFloat, fontScale: CGFloat = FontTier.standard.scale, dark: Bool = false,
            notice: SidebarNotice?, offer: UpdateBadgeItem?, shows: Bool = true) -> Bitmap? {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    var image: CGImage?
    appearance.performAsCurrentDrawingAppearance {
        let view = SidebarBrandLockup(logo: logo, showsNotices: shows, notice: notice, offer: offer)
            .frame(width: width)
            .background(dark ? Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255) : Color.white)
            .environment(\.sipFontScale, fontScale)
            .environment(\.sipLineSpacingFactor, tier(of: fontScale).lineSpacingFactor)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = px
        image = renderer.cgImage
    }
    if let image {
        save(image, [notice?.kind == nil ? nil : "notice", offer == nil ? nil : "offer",
                     dark ? "dark" : nil, shows ? nil : "off",
                     String(format: "w%.0f-tier%.2f", width, fontScale)].compactMap { $0 }.joined(separator: "-"))
    }
    return image.map(Bitmap.init)
}

/// Where the fill is: its bounding box in pixels, right of the mark.
func bubbleBox(_ b: Bitmap, fill: (Int, Int, Int)) -> (top: Int, bottom: Int, left: Int, right: Int)? {
    var top = Int.max, bottom = -1, left = Int.max, right = -1
    let fromX = Int((SidebarBrandLockup.leadingInset + 40 + 2) * px)
    for y in 0..<b.h {
        for x in fromX..<b.w where b.near(x, y, fill) {
            top = min(top, y); bottom = max(bottom, y)
            left = min(left, x); right = max(right, x)
        }
    }
    return bottom < 0 ? nil : (top, bottom + 1, left, right + 1)
}

/// The mark's ink, inside its own column, on a plain background: from the
/// straw's tip to the glass's base.
func logoBox(_ b: Bitmap, background: (Int, Int, Int)) -> (top: Int, bottom: Int)? {
    let xs = Int(SidebarBrandLockup.leadingInset * px)..<Int((SidebarBrandLockup.leadingInset + 40) * px)
    var top = Int.max, bottom = -1
    for y in 0..<b.h where xs.contains(where: { !b.near($0, y, background, 30) }) {
        top = min(top, y); bottom = max(bottom, y)
    }
    return bottom < 0 ? nil : (top, bottom + 1)
}

/// The bubble's right end and the right end of a row's … dots, in points
/// from the sidebar's left edge: the REAL lockup with a notice, and under
/// it the REAL `RowEllipsisMenu` placed as the sidebar places it (a row's
/// 4 pt trailing, a section's 8 pt each side), drawn together in one
/// borderless window offscreen and read back at 4× — the way a window
/// draws the menu, which an ImageRenderer of its label need not be.
@MainActor
func dotsBesideBubble(width: CGFloat) -> (bubbleRight: CGFloat, dotsRight: CGFloat)? {
    let notice = SidebarNotice.agentTurnEnded(agent: "Claude Code", group: "SipAI", sessionId: "s", failed: false)
    let header: CGFloat = 76, rowHeight: CGFloat = 28
    let content = VStack(spacing: 0) {
        SidebarBrandLockup(logo: logo, showsNotices: true, notice: notice, offer: nil)
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            RowEllipsisMenu { Button("Rename") {} }
                .padding(.trailing, 4)
        }
        .frame(height: rowHeight)
        .padding(.horizontal, 8)
    }
    .frame(width: width)
    .background(Color.white)
    .environment(\.sipFontScale, FontTier.standard.scale)
    _ = NSApplication.shared
    let host = NSHostingView(rootView: content)
    host.frame = NSRect(x: 0, y: 0, width: width, height: header + rowHeight)
    let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: header + rowHeight),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    host.layoutSubtreeIfNeeded()
    let scale: CGFloat = 4
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale),
                                     pixelsHigh: Int((header + rowHeight) * scale), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    rep.size = NSSize(width: width, height: header + rowHeight)
    host.cacheDisplay(in: host.bounds, to: rep)
    if let renderDir, let png = rep.representation(using: .png, properties: [:]) {
        renderCount += 1
        try? png.write(to: URL(fileURLWithPath: renderDir)
            .appendingPathComponent(String(format: "%02d-dots-w%.0f.png", renderCount, width)))
    }
    // A dot's edge is where it covers half a pixel: halfway between its
    // darkest ink and the white. A round dot's last column on a 1× screen
    // is a faint grey a tenth covered, and counting that puts the dots a
    // point further right than anyone sees them end. The bubble's end, a
    // capsule's tip, is solid on its middle row.
    var darkestDot = 255
    for y in Int(header * scale)..<rep.pixelsHigh {
        for x in Int(width * 0.66 * scale)..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            darkestDot = min(darkestDot, Int(max(c.redComponent, c.greenComponent, c.blueComponent) * 255))
        }
    }
    let halfCovered = (darkestDot + 255) / 2
    var bubbleRight = -1, dotsRight = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let r = Int(c.redComponent * 255), g = Int(c.greenComponent * 255), b = Int(c.blueComponent * 255)
            if y < Int(header * scale) {
                // The sky-blue fill, right of the mark.
                if b > 200 && r < 170 && g > 180 { bubbleRight = max(bubbleRight, x) }
            } else if x > Int(width * 0.66 * scale), max(r, g, b) < halfCovered {
                dotsRight = max(dotsRight, x)
            }
        }
    }
    guard bubbleRight >= 0, dotsRight >= 0 else { return nil }
    return (CGFloat(bubbleRight + 1) / scale, CGFloat(dotsRight + 1) / scale)
}

let finished = SidebarNotice.agentTurnEnded(agent: "Claude Code", group: "SipAI", sessionId: "s", failed: false)
let short = SidebarNotice.agentTurnEnded(agent: "Codex", group: nil, sessionId: "s", failed: false)
let width: CGFloat = 260

/// The bubble as the design states it, worked out here on its own: a line
/// of the session titles' font as SwiftUI lays it out — the font's line
/// height rounded up to a whole point, two lines exactly twice one — with
/// 5 pt above and below; between two lines, ONE share of the text's size
/// at every size, so the gap grows evenly with the text — the largest share
/// that lets the largest size hold two lines inside the mark; and as many
/// lines as fit inside the mark, straw included.
struct ExpectedBubble {
    static let share: CGFloat = {
        let largest = SipFont.sidebarRow(FontTier.allCases.map(\.scale).max()!)
        return (SidebarBrandLockup.logoHeight - 2 * 5 - 2 * ceil(SipFont.lineHeight(largest))) / largest
    }()
    let textSize: CGFloat, line: CGFloat, spacing: CGFloat, maxLines: Int
    init(_ tier: FontTier) {
        let size = SipFont.sidebarRow(tier.scale)
        let line = ceil(SipFont.lineHeight(size))
        let spacing = size * Self.share
        var lines = 1
        while CGFloat(lines + 1) * line + CGFloat(lines) * spacing + 2 * 5 <= SidebarBrandLockup.logoHeight + 0.001 {
            lines += 1
        }
        textSize = size; self.line = line; self.spacing = spacing; maxLines = lines
    }
    func height(_ lines: Int) -> CGFloat { CGFloat(lines) * line + CGFloat(lines - 1) * spacing + 2 * 5 }
}

/// The lines of text in a band of the bubble: runs of rows holding dark
/// ink, told apart by at least 1.5 pt of blank rows (between two lines
/// there are 4 pt or more at every size).
func inkLines(_ b: Bitmap, rows: Range<Int>, columns: Range<Int>) -> (count: Int, top: Int, bottom: Int, right: Int) {
    var count = 0, gap = Int.max, top = Int.max, bottom = -1, right = -1
    for y in rows {
        var any = false
        for x in columns where b.dark(x, y) { any = true; right = max(right, x) }
        if any {
            if gap >= Int(1.5 * px) { count += 1 }
            gap = 0; top = min(top, y); bottom = max(bottom, y)
        } else if gap != Int.max {
            gap += 1
        }
    }
    return (count, top, bottom + 1, right + 1)
}

let pt = { (v: Int) in CGFloat(v) / px }

if let plain = render(width: width, notice: nil, offer: nil),
   let withNotice = render(width: width, notice: short, offer: nil),
   let mark = logoBox(withNotice, background: white),
   let box = bubbleBox(withNotice, fill: lightFill) {
    check("a notice moves nothing: the header keeps its size",
          plain.w == withNotice.w && plain.h == withNotice.h, "\(plain.w)x\(plain.h) vs \(withNotice.w)x\(withNotice.h)")
    check("with nothing to say there is no bubble", bubbleBox(plain, fill: lightFill) == nil)
    let e = ExpectedBubble(.standard)
    check("the mark is the logo's height, straw included",
          abs(pt(mark.bottom - mark.top) - SidebarBrandLockup.logoHeight) <= 0.5,
          "\(pt(mark.bottom - mark.top)) pt")
    check("a one-line notice is a short bubble: its line and 5 pt above and below (\(String(format: "%.0f", e.height(1))) pt at Default)",
          abs(pt(box.bottom - box.top) - e.height(1)) <= 0.5, "\(pt(box.bottom - box.top)) pt")
    check("…its middle on the mark's middle",
          abs(pt(box.top + box.bottom - mark.top - mark.bottom) / 2) <= 0.5,
          "\(pt(box.top + box.bottom - mark.top - mark.bottom) / 2) pt off")
    check("…10 pt right of the mark, where the wordmark starts",
          abs(pt(box.left) - (SidebarBrandLockup.leadingInset + 40 + 10)) <= 0.5, "\(pt(box.left)) pt")

    // The … of the rows below is measured as the window draws it, under
    // the real lockup, in an offscreen window (`dotsBesideBubble`): an
    // ImageRenderer of the label is not what a menu draws.
    for sidebar in [width, 350] {
        if let m = dotsBesideBubble(width: sidebar) {
            check("…and ends where the … dots of the rows below end (\(Int(sidebar))-pt sidebar)",
                  abs(m.bubbleRight - m.dotsRight) <= 0.5,
                  "bubble \(m.bubbleRight) pt, dots \(m.dotsRight) pt")
        } else {
            check("the lockup and a row's … draw in an offscreen window", false)
        }
    }

    // The colours: the running clock's sky blue, black on it.
    let midY = (box.top + box.bottom) / 2
    check("the fill is the running turn clock's sky blue (light)",
          withNotice.near(box.left + Int(5 * px), midY, lightFill, 3))
    var darkest = 255
    for y in box.top..<box.bottom { for x in box.left..<box.right {
        let p = withNotice.rgb(x, y); darkest = min(darkest, max(p.0, p.1, p.2))
    } }
    check("…the text and glyph on it are black", darkest < 40, "darkest channel \(darkest)")
} else {
    check("the lockup renders with a notice, and the bubble and the mark are found", false)
}

if let darkRender = render(width: width, dark: true, notice: finished, offer: nil),
   let box = bubbleBox(darkRender, fill: darkFill) {
    check("…and in dark mode, the clock's lighter sky blue",
          darkRender.near(box.left + Int(5 * px), (box.top + box.bottom) / 2, darkFill, 3))
} else {
    check("the bubble renders in dark mode", false)
}

// At every font size: a short message is one line, a bubble that short;
// a long one wraps, growing from the mark's middle both ways, as many
// lines as fit inside the mark and cut there — never taller than the mark.
let long = SidebarNotice.needsAction(agent: "Claude Code",
                                     group: "A group name long enough to need cutting short even after two lines",
                                     sessionId: "s", requestId: "r")
// The raised hand is taller than a line at some sizes: its bubble must be
// no taller for it. A line short enough for one line at every size.
let shortAction = SidebarNotice(kind: .needsAction, line: "Codex", sentence: "A session with Codex needs your action.",
                                target: .session("s"))
for tier in FontTier.allCases {
    let e = ExpectedBubble(tier)
    var oneLineRows: [Range<Int>] = []
    for (notice, lines) in [(short, 1), (shortAction, 1), (long, e.maxLines)] {
        guard let image = render(width: width, fontScale: tier.scale, notice: notice, offer: nil),
              let mark = logoBox(image, background: white),
              let box = bubbleBox(image, fill: lightFill) else {
            check("\(tier.rawValue): the bubble renders", false)
            continue
        }
        if lines == 1 { oneLineRows.append(box.top..<box.bottom) }
        if lines == 1 && oneLineRows.count == 2 {
            check("\(tier.rawValue): the raised hand's one-line bubble covers exactly the rows of any other",
                  oneLineRows[0] == oneLineRows[1], "— \(oneLineRows[1]) against \(oneLineRows[0]) (pixels)")
        }
        // The text's column, right of its glyph: the glyph is the text's
        // size and stands 6 pt before it, 12 pt in from the bubble's end.
        let textFrom = box.left + Int((12 + e.textSize + 6) * px)
        let ink = inkLines(image, rows: box.top..<box.bottom, columns: textFrom..<box.right)
        let height = pt(box.bottom - box.top)
        let off = pt(box.top + box.bottom - mark.top - mark.bottom) / 2
        let what = lines > 1 ? "a long message" : notice.kind == .needsAction ? "a short one with the raised hand" : "a short message"
        check("\(tier.rawValue): \(what) is \(lines) line\(lines == 1 ? "" : "s") (\(ink.count) drawn), the bubble \(String(format: "%.2f", e.height(lines))) pt tall (\(String(format: "%.2f", height)) pt), its middle on the mark's middle (\(String(format: "%.2f", off)) pt off)",
              ink.count == lines && abs(height - e.height(lines)) <= 0.5 && abs(off) <= 0.5)
        if lines > 1 {
            check("\(tier.rawValue): …never taller than the mark, the text cut inside the bubble",
                  height <= SidebarBrandLockup.logoHeight + 0.25 && box.top >= mark.top - 1 && box.bottom <= mark.bottom + 1
                  && ink.right < box.right - Int(6 * px),
                  "— \(String(format: "%.2f", height)) pt, ink ending \(pt(box.right - ink.right)) pt from its end")
            // The glyph's own column — its left part, where no text can
            // reach: its ink stays inside the first line, the one it
            // belongs to.
            let glyph = inkLines(image, rows: box.top..<box.bottom,
                                 columns: (box.left + Int(12 * px))..<(box.left + Int((12 + 0.6 * e.textSize) * px)))
            let firstLine = (box.top + Int(5 * px))..<(box.top + Int((5 + e.line) * px))
            check("\(tier.rawValue): …its glyph beside the first line",
                  glyph.count == 1 && glyph.top >= firstLine.lowerBound - 2 && glyph.bottom <= firstLine.upperBound + 2,
                  "— glyph ink \(pt(glyph.top - box.top))–\(pt(glyph.bottom - box.top)) pt from the top, the first line \(5)–\(5 + e.line)")
        }
    }
}
check("every size holds at least two lines inside the mark", FontTier.allCases.allSatisfy { ExpectedBubble($0).maxLines >= 2 },
      FontTier.allCases.map { "\($0.rawValue) \(ExpectedBubble($0).maxLines)" }.joined(separator: ", "))
// The gap between the lines grows evenly with the text: one share of the
// type's size at every size, so each bigger size has a bigger gap — never
// the sizes' own line spacing, which Large text mode doubles past what two
// lines can take inside the mark.
let bySize = FontTier.allCases.sorted { $0.scale < $1.scale }
    .map { SidebarBubbleMetrics(fontScale: $0.scale) }
let shares = bySize.map { $0.lineSpacing / $0.textSize }
check("the gap between the lines is one share of the text's size at every size, growing with it",
      shares.allSatisfy { abs($0 - shares[0]) < 0.0001 }
      && zip(bySize, bySize.dropFirst()).allSatisfy { $0.lineSpacing < $1.lineSpacing },
      "— " + bySize.map { String(format: "%.2f pt", $0.lineSpacing) }.joined(separator: " / "))
for tier in FontTier.allCases {
    let e = ExpectedBubble(tier)
    let m = SidebarBubbleMetrics(fontScale: tier.scale)
    check("\(tier.rawValue): the bubble's own measures are the design's — \(m.maxLines) lines at most, \(String(format: "%.2f", m.height(lines: m.maxLines))) pt then, \(String(format: "%.2f", m.oneLineHeight)) pt for one",
          m.textSize == e.textSize && m.lineHeight == e.line && abs(m.lineSpacing - e.spacing) < 0.001
          && m.maxLines == e.maxLines && abs(m.height(lines: m.maxLines) - e.height(e.maxLines)) < 0.001
          && m.height(lines: m.maxLines) <= SidebarBrandLockup.logoHeight)
}

// An update on offer: its two buttons at the bubble's right end — the
// Update arrow, then the ×, each a circle 6 pt shorter than a one-line
// bubble, the × 3 pt from the end (its circle's centre on the round end's),
// the arrow 4 pt before it — and the text kept 4 pt or more before them,
// wrapping like a notice's. The buttons stay on the bubble's middle line.
let codex = UpdateBadgeItem.cli(agentKey: "codex", version: "0.170.0", name: "Codex")
let longOffer = UpdateBadgeItem.cli(agentKey: "kimi", version: "10.20.30",
                                    name: "A tool given a long label")
for (item, lines) in [(codex, 1), (longOffer, 2), (claudeTimedOut, 2)] {
    let e = ExpectedBubble(.standard)
    guard let image = render(width: width, notice: nil, offer: item),
          let mark = logoBox(image, background: white),
          let box = bubbleBox(image, fill: lightFill) else {
        check("an update on offer renders", false)
        continue
    }
    let button = e.height(1) - 6, inset: CGFloat = 3
    let closeMid = CGFloat(box.right) / px - inset - button / 2
    let updateMid = closeMid - button - 4
    func ink(around mid: CGFloat, half: CGFloat) -> (count: Int, top: Int, bottom: Int) {
        var count = 0, top = Int.max, bottom = -1
        for y in box.top..<box.bottom {
            for x in Int((mid - half) * px)..<Int((mid + half) * px) where image.dark(x, y) {
                count += 1; top = min(top, y); bottom = max(bottom, y)
            }
        }
        return (count, top, bottom + 1)
    }
    let glyphHalf = SipFont.scaled(11, FontTier.standard.scale) / 2 + 1
    let close = ink(around: closeMid, half: glyphHalf), update = ink(around: updateMid, half: glyphHalf)
    let gap = ink(around: updateMid - button / 2 - 2, half: 2)
    let text = inkLines(image, rows: box.top..<box.bottom,
                        columns: box.left..<Int((updateMid - button / 2 - 4) * px))
    let height = pt(box.bottom - box.top)
    let label = item == claudeTimedOut ? "a Claude Code update its own time limit stopped"
        : lines == 1 ? "a short update on offer" : "a long one"
    check("\(label) is \(lines) line\(lines == 1 ? "" : "s") (\(text.count) drawn), \(String(format: "%.2f", e.height(lines))) pt tall (\(String(format: "%.2f", height)) pt), on the mark's middle",
          text.count == lines && abs(height - e.height(lines)) <= 0.5
          && abs(pt(box.top + box.bottom - mark.top - mark.bottom) / 2) <= 0.5)
    check("…its Update arrow and its × at the bubble's right end, on its middle line",
          close.count > 20 && update.count > 20
          && abs(pt(close.top + close.bottom - box.top - box.bottom) / 2) <= 0.75,
          "update \(update.count) px, close \(close.count) px, × \(pt(close.top + close.bottom - box.top - box.bottom) / 2) pt off the middle")
    check("…with nothing between the text and the buttons", gap.count == 0, "\(gap.count) px")
}
// The timed-out update's line is the longest an offer says: at every size
// it stays inside the mark's height, cut with … past its last line.
for tier in FontTier.allCases {
    let e = ExpectedBubble(tier)
    guard let image = render(width: width, fontScale: tier.scale, notice: nil, offer: claudeTimedOut),
          let box = bubbleBox(image, fill: lightFill) else {
        check("\(tier.rawValue): a timed-out update renders", false)
        continue
    }
    let height = pt(box.bottom - box.top)
    check("\(tier.rawValue): a timed-out update's line keeps the bubble inside the mark — \(String(format: "%.2f", height)) pt, \(e.maxLines) line(s) at most",
          height <= SidebarBrandLockup.logoHeight + 0.5
          && (1...e.maxLines).contains { abs(height - e.height($0)) <= 0.5 })
}

// A notice takes the update on offer's place while it shows: nothing of
// the offer is drawn — not through it, and not above or below a notice
// shorter than the offer would be.
for offer in [claude, longOffer] {
    if let both = render(width: width, notice: short, offer: offer),
       let alone = render(width: width, notice: short, offer: nil) {
        check("a notice in front of \(offer.name)'s update on offer: the notice alone is drawn",
              both.matches(alone))
    } else {
        check("a notice over an update on offer renders", false)
    }
}

// The session titles' font: a session row's title (`SipFont.sidebarRow`,
// regular weight) is drawn as wide as the bubble's text — a heavier
// weight draws the same words 2–3 pt wider at every size.
@MainActor
func inkWidth(_ text: String, fontScale: CGFloat) -> CGFloat? {
    let view = Text(verbatim: text)
        .font(.system(size: SipFont.sidebarRow(fontScale)))
        .foregroundStyle(Color.black)
        .padding(6)
        .background(Color.white)
    let renderer = ImageRenderer(content: view)
    renderer.scale = px
    guard let cg = renderer.cgImage else { return nil }
    let b = Bitmap(cg)
    var minX = Int.max, maxX = -1
    for y in 0..<b.h { for x in 0..<b.w where b.dark(x, y) { minX = min(minX, x); maxX = max(maxX, x) } }
    return maxX < 0 ? nil : pt(maxX - minX + 1)
}
// Words that stay on one line at every size, so the widths compare.
let kimi = UpdateBadgeItem.cli(agentKey: "kimi", version: "2.3.0", name: "Kimi")
for tier in FontTier.allCases {
    guard let image = render(width: width, fontScale: tier.scale, notice: nil, offer: kimi),
          let box = bubbleBox(image, fill: lightFill),
          let reference = inkWidth(kimi.name + " " + kimi.shownVersion, fontScale: tier.scale) else {
        check("\(tier.rawValue): the offer and a session title render", false)
        continue
    }
    // The text alone: from the bubble's start to before the Update arrow.
    let button = ExpectedBubble(tier).height(1) - 6
    let textEnd = box.right - Int((3 + 2 * button + 4) * px)
    var minX = Int.max, maxX = -1
    for y in box.top..<box.bottom { for x in box.left..<textEnd where image.dark(x, y) {
        minX = min(minX, x); maxX = max(maxX, x)
    } }
    let drawn = pt(maxX - minX + 1)
    check("\(tier.rawValue): the text is a session title's font — “\(kimi.name) \(kimi.shownVersion)” \(String(format: "%.2f", drawn)) pt wide, a session title \(String(format: "%.2f", reference)) pt",
          maxX >= 0 && abs(drawn - reference) <= 0.75)
}

// The whole bubble answers a click — its top too, which a two-line bubble
// lifts well above the wordmark's frame that the bubble is laid over.
@MainActor
func clickOpens(_ notice: SidebarNotice, atTopInset inset: CGFloat) -> (opened: Int, aboveWordmark: CGFloat)? {
    final class Count { var opened = 0 }
    let count = Count()
    let content = SidebarBrandLockup(logo: logo, showsNotices: true, notice: notice, offer: nil,
                                     onOpen: { _ in count.opened += 1 })
        .frame(width: width)
        .background(Color.white)
        .environment(\.sipFontScale, FontTier.standard.scale)
        .environment(\.sipLineSpacingFactor, FontTier.standard.lineSpacingFactor)
    _ = NSApplication.shared
    let host = NSHostingView(rootView: content)
    let size = host.fittingSize
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let cg = rep.cgImage else { return nil }
    let image = Bitmap(cg)
    let scale = CGFloat(image.w) / size.width
    var top = Int.max, bottom = -1, left = Int.max, right = -1
    for y in 0..<image.h { for x in Int(64 * scale)..<image.w where image.near(x, y, lightFill) {
        top = min(top, y); bottom = max(bottom, y); left = min(left, x); right = max(right, x)
    } }
    var markBottom = -1
    for y in 0..<image.h {
        for x in Int(SidebarBrandLockup.leadingInset * scale)..<Int((SidebarBrandLockup.leadingInset + 40) * scale)
        where !image.near(x, y, white, 30) { markBottom = y; break }
    }
    guard bottom >= 0, markBottom >= 0 else { return nil }
    let at = CGPoint(x: CGFloat(left + right) / 2 / scale, y: CGFloat(top) / scale + inset)
    // The wordmark's frame: 28 pt type whose baseline is the mark's base.
    let wordmarkTop = CGFloat(markBottom + 1) / scale - NSFont.systemFont(ofSize: 28, weight: .semibold).ascender
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: at.x, y: size.height - at.y),
                                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 1, pressure: 1) {
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
    return (count.opened, wordmarkTop - at.y)
}
let tall = SidebarNotice.needsAction(agent: "Claude Code", group: "A group name long enough to wrap",
                                     sessionId: "s", requestId: "r")
if let click = clickOpens(tall, atTopInset: 3) {
    check("a click 3 pt inside a two-line bubble's top edge — 12 pt or more above the wordmark's frame — opens it",
          click.opened == 1 && click.aboveWordmark >= 12,
          "— opened \(click.opened) time(s), \(String(format: "%.1f", click.aboveWordmark)) pt above the wordmark's frame")
} else {
    check("the lockup with a two-line notice draws in an offscreen window", false)
}

// Switched off: the wordmark, whatever is waiting.
if let off = render(width: width, notice: finished, offer: claude, shows: false),
   let plain = render(width: width, notice: nil, offer: nil) {
    check("switched off, the wordmark stays — nothing else is drawn", off.matches(plain))
} else {
    check("the lockup renders switched off", false)
}

// MARK: - 5b. The rows' …

print("5b. The rows' … — dots side by side, a fill under the pointer, the whole box a click")

/// The REAL `RowEllipsisMenu` as a row places it (4 pt from the row's
/// end) — or as a group header places it, the REAL `RowPlusButton` after
/// it — alone in an offscreen window, pointed at and clicked through
/// AppKit: what the label shows is only what the menu style lets SwiftUI
/// draw of it.
@MainActor
final class EllipsisProbe {
    static let width: CGFloat = 60, height: CGFloat = 28
    let host: NSView
    let window: NSWindow
    var menusOpened = 0
    private var entered = false
    private var watch: NSObjectProtocol?

    init(withPlus: Bool = false) {
        let content = HStack(spacing: 0) {
            Spacer(minLength: 0)
            RowEllipsisMenu { Button("Rename") {} }
                .padding(.trailing, withPlus ? 2 : 4)
            if withPlus {
                RowPlusButton(label: "New session", action: {})
                    .padding(.trailing, 4)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .background(Color.white)
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.height)
        host = hosting
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: Self.width, height: Self.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        hosting.layoutSubtreeIfNeeded()
        // A menu that opens is counted, and closed from inside its own
        // tracking loop — the click does not come back until it is.
        watch = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                       object: nil, queue: nil) { [weak self] note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated { self?.menusOpened += 1 }
            let close = Timer(timeInterval: 0.05, repeats: true) { _ in menu.cancelTrackingWithoutAnimation() }
            RunLoop.main.add(close, forMode: .common)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { close.invalidate() }
        }
    }

    func finish() {
        if let watch { NotificationCenter.default.removeObserver(watch) }
        window.orderOut(nil)
    }

    private static let scale: CGFloat = 4

    /// The window as it draws, at 4×.
    private func capture() -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(Self.width * Self.scale),
                                         pixelsHigh: Int(Self.height * Self.scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: Self.width, height: Self.height)
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// How far down `rect` (points from the top-left) its ink sits: the
    /// middle of its rows, each pixel weighted by how dark it is on the
    /// white behind it — so two glyphs' anti-aliasing counts alike.
    func inkMidY(in rect: CGRect) -> CGFloat? {
        guard let rep = capture() else { return nil }
        let scale = Self.scale
        var weight: CGFloat = 0, sum: CGFloat = 0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let w = 1 - max(c.redComponent, c.greenComponent, c.blueComponent)
                guard w > 0.05 else { continue }
                weight += w
                sum += w * (CGFloat(y) + 0.5)
            }
        }
        return weight > 0 ? sum / weight / scale : nil
    }

    /// The box, in points from the top-left, of every pixel darker than
    /// `below` (the largest of the three channels, 0–255).
    func ink(below: Int) -> CGRect? {
        let scale = Self.scale
        guard let rep = capture() else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let m = max(Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
                if m < below { minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y) }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    private func mouse(_ type: NSEvent.EventType, at p: CGPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: Self.height - p.y),
                           modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)
    }

    /// The pointer comes to rest at `p` (points from the top-left): an
    /// entered event for each of the hosting view's own tracking areas
    /// (it keeps more than one, and hover rides one of them), then a move.
    func point(at p: CGPoint) {
        let location = NSPoint(x: p.x, y: Self.height - p.y)
        if !entered {
            for area in host.trackingAreas {
                if let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: location,
                                                      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                      trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()),
                                                      userData: nil) {
                    host.mouseEntered(with: enter)
                }
            }
            entered = true
        }
        if let move = mouse(.mouseMoved, at: p) { host.mouseMoved(with: move) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    /// How many menus a click at `p` opened.
    func click(at p: CGPoint) -> Int {
        menusOpened = 0
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = mouse(type, at: p) { window.sendEvent(event) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        return menusOpened
    }
}

do {
    let probe = EllipsisProbe()
    // The 18-pt box the label states, 4 pt from the row's end.
    let box = CGRect(x: EllipsisProbe.width - 4 - 18, y: (EllipsisProbe.height - 18) / 2, width: 18, height: 18)
    if let dots = probe.ink(below: 200) {
        check("the dots lie side by side (…), not one above another (⋮)",
              dots.width >= 2 * dots.height,
              String(format: "— the dots are %.2f × %.2f pt", dots.width, dots.height))
        check("…centred across its 18-pt box",
              abs(dots.midX - box.midX) <= 0.5,
              String(format: "— centred at %.2f; the box's centre is %.2f", dots.midX, box.midX))
    } else {
        check("the … draws", false)
    }
    // With no hover to answer it, the box would never fill.
    let hover = HoverGate(report: { check($0, $1, $2()) })
    probe.point(at: CGPoint(x: box.midX, y: box.midY))
    if let fill = probe.ink(below: 250) {
        hover.check("under the pointer its whole 18-pt box fills, like the + beside it",
                    abs(fill.width - 18) <= 1 && abs(fill.height - 18) <= 1 && abs(fill.maxX - box.maxX) <= 1,
                    String(format: "— the tinted box is %.2f × %.2f pt, ending %.2f pt from the row's end",
                           fill.width, fill.height, EllipsisProbe.width - fill.maxX))
    } else {
        check("the … draws under the pointer", false)
    }
    // A corner of the box is off the dots whichever way they lie.
    check("a click in the box, off the dots, opens the menu",
          probe.click(at: CGPoint(x: box.minX + 3, y: box.minY + 3)) == 1)
    check("…and a click 6 pt to its left opens nothing",
          probe.click(at: CGPoint(x: box.minX - 6, y: box.midY)) == 0,
          "— the click target is wider than the box that answers the pointer")
    probe.finish()
}

do {
    // On a group header the … stands just before the +, and the two read
    // as one line: the dots sit level with the +'s bar, wherever SF
    // Symbols puts each glyph inside its 18-pt box.
    let header = EllipsisProbe(withPlus: true)
    let plusColumn = CGRect(x: EllipsisProbe.width - 4 - 18, y: 0, width: 18, height: EllipsisProbe.height)
    let dotsColumn = CGRect(x: plusColumn.minX - 2 - 18, y: 0, width: 18, height: EllipsisProbe.height)
    if let dotsY = header.inkMidY(in: dotsColumn), let plusY = header.inkMidY(in: plusColumn) {
        check("…level with the + beside it on a group header",
              abs(dotsY - plusY) <= 0.5,
              String(format: "— the dots' middle %.2f pt down, the +'s %.2f pt", dotsY, plusY))
    } else {
        check("a group header's … and + draw", false)
    }
    header.finish()
}

// MARK: - 6. The wiring

print("6. The wiring, read off the sources")

let notices = codeOnly(source("SipAI/Models/SidebarNotices.swift"))
let lockup = codeOnly(source("SipAI/Views/Sidebar/SidebarBrandLockup.swift"))
let sidebar = codeOnly(source("SipAI/Views/Sidebar/LeftSidebar.swift"))
let app_ = codeOnly(source("SipAI/SipAIApp.swift"))
let manager = codeOnly(source("SipAI/Models/AgentManager.swift"))
let chats = codeOnly(source("SipAI/Models/ChatManager.swift"))
let chatView = codeOnly(source("SipAI/Views/Chat/ChatView.swift"))
let bridge = codeOnly(source("SipAI/Models/MCPBridge.swift"))
let monitor = codeOnly(source("SipAI/Models/AgentCLIUpdates.swift"))
let sparkle = codeOnly(source("SipAI/Models/UpdateController.swift"))
let config = codeOnly(source("SipAI/Models/ConfigManager.swift"))
let settings = codeOnly(source("SipAI/Views/Settings/SettingsView.swift"))
let reset = codeOnly(source("SipAI/Models/FactoryReset.swift"))
let design = source("SipAI/Utilities/DesignSystem.swift")

// The geometry rests on these: the measured … is placed as the rows place
// it, so if the menu, its row or its section change, the numbers above
// stop describing the sidebar.
let rowEllipsis = design.components(separatedBy: "struct RowEllipsisMenu").dropFirst().first?
    .components(separatedBy: "\n}\n").first ?? ""
check("the … is still the rows' ellipsis menu, its label drawn by SwiftUI and not turned, 4 pt from a row's end, in a section 8 pt in",
      rowEllipsis.contains("Image(systemName: \"ellipsis\")\n                .font(.system(size: 11, weight: .semibold))")
      && !codeOnly(rowEllipsis).contains("rotationEffect")
      && rowEllipsis.contains(".menuStyle(.button)\n        .buttonStyle(.plain)\n        .menuIndicator(.hidden)")
      && !rowEllipsis.contains(".borderlessButton")
      && sidebar.contains(".padding(.horizontal, 8)")
      && source("SipAI/Views/Sidebar/NotesSection.swift").contains("RowEllipsisMenu { menuItems }\n                .padding(.trailing, 4)"))

// What the user reads names the menu as it is drawn: every key and
// Chinese value in the catalog (the Help answers among them), and the
// README. The translators' comments may name it either way.
var catalogTexts: [String] = []
if let data = source("SipAI/Resources/Localizable.xcstrings").data(using: .utf8),
   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let strings = root["strings"] as? [String: Any] {
    for (key, entry) in strings {
        catalogTexts.append(key)
        if let entry = entry as? [String: Any],
           let localizations = entry["localizations"] as? [String: Any],
           let zh = localizations["zh-Hans"] as? [String: Any],
           let unit = zh["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String {
            catalogTexts.append(value)
        }
    }
}
let readme = (try? String(contentsOfFile: sourceRoot + "/../README.md", encoding: .utf8)) ?? ""
let namedVertical = catalogTexts.filter { $0.contains("⋮") }.map { String($0.prefix(60)) }
check("Help (English and Chinese) and the README call the rows' menu “…”, as drawn — never “⋮”",
      catalogTexts.count > 100 && !readme.isEmpty && namedVertical.isEmpty && !readme.contains("⋮"),
      "— still “⋮”: \(namedVertical)\(readme.contains("⋮") ? " and the README" : "")")
check("the bubble is as tall as its lines, its middle on the mark's middle, no taller than the mark: no frame of a fixed height",
      lockup.contains("$0[VerticalAlignment.center] + SidebarBrandLockup.logoHeight / 2")
      && lockup.contains(".fixedSize(horizontal: false, vertical: true)")
      && lockup.contains("static var maxHeight: CGFloat { SidebarBrandLockup.logoHeight }")
      && !lockup.contains("cupHeight") && !lockup.contains("maxHeight: .infinity"))
check("…as many lines as fit, cut at the tail, the whole sentence on hover and for VoiceOver",
      lockup.contains("Text(verbatim: notice.line)")
      && lockup.components(separatedBy: ".lineLimit(metrics.maxLines)").count == 3
      && !lockup.contains(".lineLimit(1)")
      && lockup.contains(".truncationMode(.tail)") && lockup.contains(".help(notice.sentence)")
      && lockup.contains(".accessibilityLabel(notice.sentence)"))
// A session row's title is `.font(.system(size: SipFont.sidebarRow(fontScale)))`,
// no weight: the bubble's words and glyph are the same, and wrapped lines
// are one share of the type's size apart at every size (`lineSpacingShare`)
// — never the sizes' own spacing, which reads the tier's line-spacing factor.
check("…in the session titles' font, following Settings → Display, its lines one share of the type apart",
      lockup.contains("let size = SipFont.sidebarRow(fontScale)")
      && lockup.contains("@Environment(\\.sipFontScale)")
      && lockup.contains("static let lineSpacingShare: CGFloat")
      && lockup.contains("let spacing = size * Self.lineSpacingShare")
      && !lockup.contains("sipLineSpacingFactor")
      && lockup.components(separatedBy: ".font(.system(size: metrics.textSize))").count == 5
      && !lockup.contains("metrics.textSize, weight:")
      && lockup.components(separatedBy: ".lineSpacing(metrics.lineSpacing)").count == 3
      && source("SipAI/Views/Sidebar/AgentSessionsSection.swift")
          .contains("Text(displayName(for: session, nested: nested))\n                            .font(.system(size: SipFont.sidebarRow(fontScale)))"))
check("…the running clock's colour, referenced, with black on it",
      lockup.contains("ChatMarkdownStyle.inlineCode") && lockup.contains(".foregroundStyle(Color.black)")
      && source("SipAI/Views/Chat/AgentComposer.swift").contains("? ChatMarkdownStyle.inlineCode"))
check("…a stadium for one line, whose round ends stay the corners of a taller one, with no outline",
      lockup.contains("var cornerRadius: CGFloat { oneLineHeight / 2 }")
      && lockup.contains("RoundedRectangle(cornerRadius: metrics.cornerRadius)")
      && !lockup.contains("Capsule()")
      && !lockup.contains(".stroke(") && !lockup.contains("strokeBorder"))
check("…the raised hand on a card waiting on the user", lockup.contains("case .needsAction: return \"hand.raised.fill\""))
check("every clickable in it lifts under the pointer",
      lockup.contains(".onHover { hovered = $0 }")
      && lockup.contains("Color.black.opacity(clickable && hovered ? 0.1 : 0)")
      && lockup.contains("Color.black.opacity(enabled && hovered ? 0.14 : 0)"))
check("a notice takes the offer's place while it shows: the offer is not drawn under it",
      lockup.contains("if let notice {\n                                SidebarNoticeBubble(")
      && lockup.contains("} else if let offer {\n                                UpdateOfferBubble(")
      && !lockup.contains(".allowsHitTesting(notice == nil)"))
check("no interpolated Text literal in the bubble",
      lockup.range(of: #"Text\("[^"]*\\\("#, options: .regularExpression) == nil)

check("the sidebar draws the lockup fed by the notices, with the sheet test under it",
      sidebar.contains("SidebarHeader(showsNotices: config.display.showSidebarNotices)")
      && sidebar.contains("@ObservedObject private var notices = SidebarNotices.shared")
      && sidebar.contains(".background(LockupSheetCheck())")
      && sidebar.contains("SidebarNotices.shared.sheetCoversLockup = { [weak view] in"))
check("…an offer's Update is held back by the Updates pane's own rule",
      sidebar.contains("agents.hasTurnInFlight(agentKey: key)") && sidebar.contains("cliUpdates.updateInFlight(key)"))

check("an agent turn that ends unread is said, failed or not",
      manager.contains("SidebarNotices.shared.post(.agentTurnEnded(")
      && manager.contains("if case .done(let code, _) = status, code != 0 { failed = true }")
      && manager.components(separatedBy: "self.noteRunEnded(").count == 3)
check("…only where the steady dot is set — never for the session on screen or a turn the user stopped",
      manager.contains("guard !id.isEmpty, !id.hasPrefix(\"draft:\"), !stoppedByUser,\n              id != openSessionId, !isOpenDraftsSession(id) else { return }\n        config?.markAgentSessionUnread(id)"))
check("…named by the group its row is drawn under",
      manager.contains("func noticeNames(forSession id: String?, agentKey: String) -> (agent: String, group: String?)")
      && manager.contains("config.agentGroupMode(for: agentKey) == .custom"))
// An agent that is not listed — hidden in Settings, signed out — has no
// section, no row and no page: a notice naming one of its sessions would
// be the one place the app still shows it, and its click opens nothing.
// The steady dot is set either way (it is drawn only on a listed row).
if let from = manager.range(of: "private func noteRunEnded("),
   let to = manager.range(of: "func noticeNames(", range: from.upperBound..<manager.endIndex) {
    let body = manager[from.lowerBound..<to.lowerBound]
    let guardAt = body.range(of: "guard isAgentReady(agentKey) else { return }")
    let markAt = body.range(of: "config?.markAgentSessionUnread(id)")
    let postAt = body.range(of: "SidebarNotices.shared.post(.agentTurnEnded(")
    check("a turn's end is said only for a listed agent, after its dot is set",
          guardAt != nil && markAt != nil && postAt != nil
            && markAt!.lowerBound < guardAt!.lowerBound && guardAt!.lowerBound < postAt!.lowerBound)
} else {
    check("noteRunEnded is where it is expected", false)
}
check("…and a card only for a listed agent",
      app_.contains("guard let bridge = mcpBridge, let agents = agentManager,\n                  agents.isAgentReady(req.agentKey) else { return }"))
check("a chat reply that lands unread is said, with the provider and the chat group",
      chats.contains("SidebarNotices.shared.post(.chatTurnEnded(")
      && chats.contains("guard key != openChatKey, turnOutcomes[key] != .interrupted else { return }\n        config?.markChatUnread(key: key)")
      && chatView.contains("provider: providerName(forModel: modelId),"))
check("a card is said the moment it is shown, unless the user is looking at it",
      bridge.contains("maybePostNotification(for: req)\n        onRequestShown?(req)")
      && app_.contains("if bridge.isApprovalFocused?(req) == true { return }")
      && app_.contains("SidebarNotices.shared.post(.needsAction("))
check("…and goes once it is answered, or its session opened",
      app_.contains("return cards.contains { !(bridge.isApprovalFocused?($0) ?? false) }")
      && app_.contains("mcpBridge.$pending.map { _ in () }")
      && app_.contains("appState.$openAgentSessionId.map { _ in () }")
      && notices.contains(".receive(on: DispatchQueue.main)"))
check("a finished turn's notice goes once its session or chat is opened",
      app_.contains("configManager?.agentUnreadSessions.contains(id)")
      && app_.contains("configManager?.chatUnreadKeys"))
check("a click opens the session by the notification click's road, a chat by its address",
      app_.contains("notificationCoordinator.onApprovalClicked?(id, \"\")")
      && app_.contains("appState.openChatSlug = slug"))
check("…a run under its own task's panel, any other session with no task page left above it",
      app_.contains("appState.openScheduledTaskName = session.scheduledTaskName")
      && app_.components(separatedBy: "openSession(session)").count == 3)
check("an offer's button: Sparkle's window, Install Now, or the tool's own update",
      app_.contains("updateController.checkForUpdates()") && app_.contains("updateController?.installNow()")
      && app_.contains("return AgentCLIUpdateMonitor.shared.startUpdate(agentKey: key)"))
check("an update that landed is said through the notices, for a tool and for SipAI",
      monitor.contains("SidebarNotices.shared.post(.updated(name: label(for: key), version: version.text))")
      && sparkle.contains("SidebarNotices.shared.post(.updated(name: \"SipAI\", version: currentVersion))"))
check("a tool on offer is named by its label, a failed update marked, and its cause read off the updater's own words",
      monitor.contains("if case .updateFailed(let tail) = status {\n                failed = true\n"
                       + "                failure = CLIUpdateFailure.read(agentKey: agent.key, output: tail)")
      && monitor.contains("return .cli(agentKey: agent.key, version: version,\n                        name: label(for: agent.key), failed: failed, failure: failure)"))
check("a hold stands with Install Now from the moment it begins, offered anew",
      sparkle.contains("SidebarNotices.shared.reopen(key: UpdateBadgeItem.appInstallKey)\n        publishBadge()"))
check("nothing is left of the old announcer",
      !FileManager.default.subpaths(atPath: sourceRoot + "/SipAI")!.filter { $0.hasSuffix(".swift") }
        .contains { (try? String(contentsOfFile: sourceRoot + "/SipAI/" + $0, encoding: .utf8))?
            .contains("UpdateAnnouncer") ?? false })

check("Settings → Display: one switch for all of it, on by default, under its old key",
      settings.contains("toggle(\"Show notifications beside the logo\", value: \\.showSidebarNotices)")
      && config.contains("s.showSidebarNotices = d[\"update_messages\"] as? Bool ?? true")
      && config.contains("d[\"update_messages\"] = s.showSidebarNotices")
      && app_.contains("configManager?.display.showSidebarNotices ?? true"))
check("a factory reset forgets the closed offers, on disk and in memory",
      reset.contains("SidebarNotices.closedDefaultsKey") && reset.contains("SidebarNotices.shared.forgetClosed()")
      && notices.contains("static let closedDefaultsKey = \"sidebarNoticeClosed\""))

if let data = FileManager.default.contents(atPath: sourceRoot + "/SipAI/Resources/Localizable.xcstrings"),
   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let strings = root["strings"] as? [String: Any] {
    let keys = ["%@ needs you", "%@ · %@ needs you", "A session with %@ needs your action.",
                "A session with %@ under the “%@” group needs your action.",
                "%@ finished", "%@ · %@ finished", "%@ failed", "%@ · %@ failed",
                "An agent session with %@ just finished its response.",
                "An agent session with %@ under the “%@” group just finished its response.",
                "An agent session with %@ ended with an error.",
                "An agent session with %@ under the “%@” group ended with an error.",
                "%@ chat finished", "%@ chat · %@ finished", "%@ chat failed", "%@ chat · %@ failed",
                "A chat session with %@ just finished its response.",
                "A chat session with %@ under the “%@” group just finished its response.",
                "A chat session with %@ ended with an error.",
                "A chat session with %@ under the “%@” group ended with an error.",
                "%@ updated to %@", "%@ just updated to %@", "%@ %@ is available.",
                "%@ did not update to %@.", "SipAI %@ will install once the running turn finishes.",
                "Update %@ to %@", "Install SipAI %@ now. The running turn is stopped first.", "Close",
                "The last update of this tool is still finishing.",
                "Show notifications beside the logo"]
    for key in keys {
        let zh = (((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?["zh-Hans"]
                    as? [String: Any])?["stringUnit"] as? [String: Any]
        check("\"\(key)\" is translated", zh?["value"] is String)
    }
    check("the update-messages switch's words left with it",
          strings["Show update messages"] == nil
          && strings["When SipAI or an agent tool is updated, a short message takes the app name's place for five seconds."] == nil)
} else {
    check("Localizable.xcstrings is readable", false)
}

print("")
print(failures == 0 ? "SidebarNotices: OK" : "SidebarNotices: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
