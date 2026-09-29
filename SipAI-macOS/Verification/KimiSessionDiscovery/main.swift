// Which session did a new kimi turn create? The rule, and the race it
// closes.
//
// Kimi names a new session on stdout only with the turn's FINAL answer
// (`session.resume_hint`), and refuses an id chosen by the caller
// (`--session <new id>` → "not found"), so SipAI reads a draft's id back
// off the store while the turn runs (`KimiSessionScanner.discoverSession`).
// It used to take "the newest new directory in this folder" — and two
// first turns in one folder at the same moment (a scheduled run firing
// while the user starts a session there, a kimi started in a terminal)
// were then BOTH bound to the newest one, so one runner's next send
// continued the other's conversation.
//
// 1. the rule, over a synthetic store in kimi's own record shapes;
// 2. the race, for real: two `kimi --prompt` runs started together in
//    one folder, token-free against `../ChatOnlyMode/fake_server.py`,
//    each held to the id its OWN announcement names — and the same with
//    identical words, where the only honest answer is none;
// 3. the runner's wiring, read off AgentRunner.swift.
//
// Nothing here is part of the app target.

import Foundation

var failures: [String] = []
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("  ok    \(label)") }
    else {
        let extra = detail()
        print("  FAIL  \(label)\(extra.isEmpty ? "" : " — \(extra)")")
        failures.append(label)
    }
}
func note(_ text: String) { print("        \(text)") }
func section(_ t: String) { print("\n\(t)") }

let fm = FileManager.default
let args = CommandLine.arguments
let sourceRoot = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
let fakeServer = args.count > 2 ? args[2] : ""

// Under Caches, never a temp root: kimi records a cwd by its REAL path,
// and /tmp or /var/folders would come back as /private/…, which is not
// the folder the harness asks about.
let root = fm.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/sipai-kimi-discovery-\(UUID().uuidString.prefix(8))")
let home = root.appendingPathComponent("home", isDirectory: true)
try! fm.createDirectory(at: home, withIntermediateDirectories: true)
// Before the scanner's first use: its root is read once.
setenv("KIMI_CODE_HOME", home.path, 1)

func cleanup() { try? fm.removeItem(at: root) }

// MARK: - 1. The rule, over a synthetic store

section("1. discoverSession over a synthetic store")

let project = root.appendingPathComponent("Project A", isDirectory: true)
let elsewhere = root.appendingPathComponent("Project B", isDirectory: true)
try! fm.createDirectory(at: project, withIntermediateDirectories: true)
try! fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)

/// One session directory in kimi's shape: state.json, and a wire that
/// opens the way kimi 2.1.1 writes one — metadata, the turn's prompt,
/// the user record, then kimi's own reminder AS THE USER.
func writeSession(bucket: String, id: String, cwd: URL, text: String?,
                  born: Date? = nil) {
    let dir = home.appendingPathComponent("sessions/\(bucket)/\(id)", isDirectory: true)
    let agents = dir.appendingPathComponent("agents/main", isDirectory: true)
    try! fm.createDirectory(at: agents, withIntermediateDirectories: true)
    try! #"{"id":"\#(id)","cwd":"\#(cwd.path)","createdAt":"2026-09-27T10:00:00.000Z"}"#
        .write(to: dir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
    var lines = [#"{"type":"metadata","protocol_version":"1.5","created_at":1790526950212}"#]
    if let text {
        let quoted = String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!
            .dropFirst().dropLast()
        lines.append(#"{"type":"turn.prompt","agentId":"main","input":[{"type":"text","text":\#(quoted)}],"promptId":"msg_1","turnId":0}"#)
        lines.append(#"{"type":"context.append_message","agentId":"main","message":{"role":"user","content":[{"type":"text","text":\#(quoted)}],"id":"msg_1"}}"#)
        lines.append(#"{"type":"context.append_message","agentId":"main","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>\nAuto permission mode is active.\n</system-reminder>"}]}}"#)
    }
    try! (lines.joined(separator: "\n") + "\n")
        .write(to: agents.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)
    if let born {
        try! fm.setAttributes([.creationDate: born, .modificationDate: born], ofItemAtPath: dir.path)
    }
}

let hour = Date().addingTimeInterval(-3600)
writeSession(bucket: "wd_a", id: "session_old", cwd: project, text: "alpha")
let known = KimiSessionScanner.sessionIds()
let since = Date()
writeSession(bucket: "wd_a", id: "session_a", cwd: project, text: "alpha")
writeSession(bucket: "wd_a", id: "session_b", cwd: project, text: "bravo")
writeSession(bucket: "wd_b", id: "session_other", cwd: elsewhere, text: "words from elsewhere")
writeSession(bucket: "wd_a", id: "session_stale", cwd: project, text: "stale words", born: hour)
let marker = #"<scheduled-task name="nightly-audit"></scheduled-task>run the audit"#
writeSession(bucket: "wd_a", id: "session_task", cwd: project, text: marker)

func discover(_ prompt: String, excluding: Set<String> = known) -> String? {
    KimiSessionScanner.discoverSession(cwd: project, excluding: excluding,
                                       since: since, prompt: prompt)?.id
}

check("the session holding the words sent is the one found",
      discover("alpha") == "session_a", discover("alpha") ?? "nil")
check("another new session in the same folder is found by ITS words",
      discover("bravo") == "session_b", discover("bravo") ?? "nil")
check("the words are compared trimmed, as kimi records them",
      discover("  alpha \n") == "session_a", discover("  alpha \n") ?? "nil")
check("words no new session holds find nothing — no fallback to the newest",
      discover("charlie") == nil, discover("charlie") ?? "nil")
check("a scheduled run's marker is part of the words it is found by",
      discover(marker) == "session_task", discover(marker) ?? "nil")
check("a session in another folder is never taken, even holding the words sent",
      discover("words from elsewhere") == nil, discover("words from elsewhere") ?? "nil")
check("…while from its own folder the same words find it",
      KimiSessionScanner.discoverSession(cwd: elsewhere, excluding: known, since: since,
                                         prompt: "words from elsewhere")?.id == "session_other")
check("a directory older than the send is never taken",
      discover("stale words") == nil, discover("stale words") ?? "nil")
check("a session that existed before the spawn is never taken",
      discover("alpha", excluding: known.union(["session_a"])) == nil)
check("an empty prompt finds nothing", discover("   ") == nil)
// A new directory whose first message has not landed: UNDECIDED, and it
// holds every answer in the folder — including one another directory
// already gives — because its words may turn out to be the same.
writeSession(bucket: "wd_a", id: "session_pending", cwd: project, text: nil)
check("a new directory with no first message yet is no candidate",
      discover("delta") == nil, discover("delta") ?? "nil")
check("…and while it exists, nothing in the folder is answered — not even a match",
      discover("alpha") == nil, discover("alpha") ?? "nil")
check("…a directory in another folder is not held by it",
      KimiSessionScanner.discoverSession(cwd: elsewhere, excluding: known, since: since,
                                         prompt: "words from elsewhere")?.id == "session_other")
writeSession(bucket: "wd_a", id: "session_pending", cwd: project, text: "delta")
check("once its message lands it is found by its words",
      discover("delta") == "session_pending", discover("delta") ?? "nil")
check("…and the folder's other answers are back",
      discover("alpha") == "session_a", discover("alpha") ?? "nil")
writeSession(bucket: "wd_a", id: "session_a2", cwd: project, text: "alpha")
check("two new sessions holding the same words: no guess",
      discover("alpha") == nil, discover("alpha") ?? "nil")
check("…and with one of them accounted for, the other is found",
      discover("alpha", excluding: known.union(["session_a"])) == "session_a2")

// MARK: - 2. The race, with two real kimi runs

section("2. two real kimi turns started together in one folder (token-free)")

func findKimi() -> String? {
    var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    dirs.append(fm.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code/bin").path)
    for d in dirs {
        let p = (d as NSString).appendingPathComponent("kimi")
        if fm.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

final class Fake {
    let process = Process()
    var port = 0
    init?(script: String, record: URL) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script, record.path, "--chat-delay", "3"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(10)
        var buffer = ""
        while Date() < deadline, port == 0 {
            let data = out.fileHandleForReading.availableData
            if data.isEmpty { break }
            buffer += String(decoding: data, as: UTF8.self)
            if let range = buffer.range(of: #"PORT=(\d+)"#, options: .regularExpression) {
                port = Int(buffer[range].dropFirst(5)) ?? 0
            }
        }
        if port == 0 { process.terminate(); return nil }
    }
    func stop() { process.terminate(); process.waitUntilExit() }
}

final class Turn {
    let process = Process()
    let out = Pipe()
    var stdout = Data()
    init(kimi: String, prompt: String, cwd: URL) {
        process.executableURL = URL(fileURLWithPath: kimi)
        process.arguments = ["--prompt", prompt, "--output-format", "stream-json"]
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["KIMI_CODE_HOME"] = home.path
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if !d.isEmpty { DispatchQueue.main.async { self?.stdout.append(d) } }
        }
    }
    /// The id kimi itself names, from its last stdout line.
    var announced: String? {
        for line in String(decoding: stdout, as: UTF8.self).split(separator: "\n")
        where line.contains("session.resume_hint") {
            if let data = String(line).data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = obj["session_id"] as? String { return id }
        }
        return nil
    }
}

func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

/// The rule this replaced, spelled here ONLY to show the race is real in
/// this very run: the newest entry new since the snapshot, walked the way
/// the scanner walks the store — hidden entries skipped at both levels
/// (kimi keeps marker files in `sessions/.index-dirty/`). Every session
/// in this run is in one folder, so the folder test would pass them all.
func newestNew(excluding: Set<String>) -> String? {
    let sessions = home.appendingPathComponent("sessions")
    var best: (String, Date)? = nil
    for bucket in (try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles])) ?? [] {
        for dir in (try? fm.contentsOfDirectory(at: bucket, includingPropertiesForKeys: [.creationDateKey],
                                                options: [.skipsHiddenFiles])) ?? []
        where !excluding.contains(dir.lastPathComponent) {
            let born = (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if best == nil || born > best!.1 { best = (dir.lastPathComponent, born) }
        }
    }
    return best?.0
}

if let kimi = findKimi(), !fakeServer.isEmpty, fm.fileExists(atPath: fakeServer),
   let server = Fake(script: fakeServer, record: root.appendingPathComponent("requests")) {
    // A fresh home per phase keeps the two phases' sessions apart.
    try? fm.removeItem(at: home.appendingPathComponent("sessions"))
    try! """
    default_model = "fake/fake-model"

    [providers.fake]
    base_url = "http://127.0.0.1:\(server.port)/v1"
    type = "openai"
    api_key = "junk"

    [models."fake/fake-model"]
    provider = "fake"
    model = "fake-model"
    max_context_size = 262144
    capabilities = [ "tool_use" ]

    """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    let folder = root.appendingPathComponent("Shared Folder", isDirectory: true)
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)

    // (a) Different words — a scheduled run and the user, say.
    let snapshot = KimiSessionScanner.sessionIds()
    let one = Turn(kimi: kimi, prompt: "Reply OK. RUN-ALPHA", cwd: folder)
    let two = Turn(kimi: kimi, prompt: "Reply OK. RUN-BRAVO", cwd: folder)
    try! one.process.run()
    try! two.process.run()
    let spawned = Date()
    var foundOne: String? = nil, foundTwo: String? = nil
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline, foundOne == nil || foundTwo == nil {
        foundOne = foundOne ?? KimiSessionScanner.discoverSession(
            cwd: folder, excluding: snapshot, since: spawned, prompt: "Reply OK. RUN-ALPHA")?.id
        foundTwo = foundTwo ?? KimiSessionScanner.discoverSession(
            cwd: folder, excluding: snapshot, since: spawned, prompt: "Reply OK. RUN-BRAVO")?.id
        pump(0.1)
    }
    let foundAt = Date().timeIntervalSince(spawned)
    let oldRule = newestNew(excluding: snapshot)
    one.process.waitUntilExit(); two.process.waitUntilExit()
    pump(0.3)
    note("found after \(String(format: "%.1f", foundAt)) s, while both turns were still waiting on the model")
    check("run 1's session is found, and it is the one kimi names for run 1",
          foundOne != nil && foundOne == one.announced,
          "found \(foundOne ?? "nil"), kimi named \(one.announced ?? "nil")")
    check("run 2's session is found, and it is the one kimi names for run 2",
          foundTwo != nil && foundTwo == two.announced,
          "found \(foundTwo ?? "nil"), kimi named \(two.announced ?? "nil")")
    check("the two runs are bound to two different sessions",
          foundOne != nil && foundOne != foundTwo)
    // The hazard, measured in this run: the old rule answers both
    // runners with one id.
    note("the replaced rule (newest new directory) would have answered BOTH runs with \(oldRule ?? "nil")")
    check("the race is real in this run (the old rule gives one run the other's session)",
          oldRule != nil && (oldRule == one.announced || oldRule == two.announced)
            && one.announced != two.announced)

    // (b) The SAME words, twice at once — two copies of one task.
    let snapshotB = KimiSessionScanner.sessionIds()
    let three = Turn(kimi: kimi, prompt: "Reply OK. SAME-WORDS", cwd: folder)
    let four = Turn(kimi: kimi, prompt: "Reply OK. SAME-WORDS", cwd: folder)
    try! three.process.run()
    try! four.process.run()
    let spawnedB = Date()
    // Poll from the spawn, as the runner does but far more often, and
    // record every answer: the window between one directory's words
    // landing and the other's is tens of milliseconds, and an answer in
    // it would bind both runs to one session.
    var landed = 0
    var answers: [(TimeInterval, String)] = []
    var partial = 0
    let deadlineB = Date().addingTimeInterval(15)
    while Date() < deadlineB, landed < 2 {
        if let hit = KimiSessionScanner.discoverSession(
            cwd: folder, excluding: snapshotB, since: spawnedB, prompt: "Reply OK. SAME-WORDS") {
            answers.append((Date().timeIntervalSince(spawnedB), hit.id))
        }
        landed = 0
        let sessions = home.appendingPathComponent("sessions")
        for bucket in (try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles])) ?? [] {
            for dir in (try? fm.contentsOfDirectory(at: bucket, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])) ?? []
            where !snapshotB.contains(dir.lastPathComponent) {
                let wire = dir.appendingPathComponent("agents/main/wire.jsonl")
                if let text = try? String(contentsOf: wire, encoding: .utf8), text.contains("SAME-WORDS") { landed += 1 }
            }
        }
        if landed == 1 { partial += 1 }
        pump(0.01)
    }
    let ambiguous = KimiSessionScanner.discoverSession(
        cwd: folder, excluding: snapshotB, since: spawnedB, prompt: "Reply OK. SAME-WORDS")
    three.process.waitUntilExit(); four.process.waitUntilExit()
    pump(0.3)
    check("both runs' directories came to hold the same words", landed == 2, "\(landed)")
    note("\(partial) polls fell in the window where only one directory held the words")
    check("no poll from the spawn on answered — the window between the two landings included",
          answers.isEmpty, answers.map { "\($0.1) at \(String(format: "%.2f", $0.0)) s" }.joined(separator: ", "))
    check("two sessions holding the same words: discovery makes no guess",
          ambiguous == nil, ambiguous?.id ?? "nil")
    check("…and kimi's own announcements tell them apart at the end",
          three.announced != nil && four.announced != nil && three.announced != four.announced)
    server.stop()
} else {
    print("  SKIP  kimi, python3 or the fake server is not available here")
}

// MARK: - 3. The runner's wiring

section("3. AgentRunner wiring (read off the source)")

func source(_ rel: String) -> String {
    (try? String(contentsOf: sourceRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
let runner = source("SipAI/Models/AgentRunner.swift")
check("the send's own text is handed to discovery",
      runner.contains("startKimiSessionDiscovery(excluding: kimiKnownIds, since: Date(),\n                                      prompt: text)"))
check("discovery asks the scanner with that text",
      runner.contains("since: since,\n                        prompt: prompt)"))
check("an announcement naming a different session is said in the log",
      runner.contains("adopted != announced") && runner.contains("had adopted"))
check("no comment still claims kimi's stdout carries no id",
      !runner.contains("Kimi announces no session id on stdout")
        && !runner.contains("immediate, and cannot pick"))
let scanner = source("SipAI/Models/KimiSessions.swift")
check("the scanner answers only when ONE directory passes and none is undecided",
      scanner.contains("guard !undecided, matches.count == 1"))
check("the scanner no longer keeps a newest-wins candidate",
      !scanner.contains("born > best!.at"))

cleanup()
print("")
if failures.isEmpty {
    print("PASS")
} else {
    print("FAILED (\(failures.count)):")
    for f in failures { print("  - \(f)") }
    exit(1)
}
