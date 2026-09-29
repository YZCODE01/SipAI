// A turn ANOTHER process runs on a Codex or Kimi Code session — a
// terminal, another app, a turn SipAI orphaned by relaunching — watched
// the way a Claude Code one is: drawn live, its dot lit while it runs
// and put out when it ends, a writer killed mid-turn noticed, a session
// opened mid-turn seen as running.
//
// What this pins, and why each part exists:
//
//  1. The rules, over records in the shapes the CLIs write — taken from
//     a real codex rollout and a real kimi wire, with synthetic text:
//     which records open and close a turn (and which inner records do
//     NOT, or the dot flickers through a turn), the newest turn a file
//     records, and one decoded row as one live event.
//  2. The REAL tailer over a file this harness appends to, with REAL
//     writers standing in: a process holding a codex thread lock, a
//     process named `kimi` running in the session's folder. Markers
//     light the flag and put it out; a writer killed mid-turn puts it
//     out within the sweep; a writer never seen does not; a session
//     opened mid-turn starts lit, and a dead one's residue does not;
//     the check waits out a suspend; codex's lock is only ever TESTED.
//  3. Live, token-free: the REAL codex and kimi, over throwaway homes,
//     against ../ChatOnlyMode/fake_server.py — a turn watched from
//     start to end, and one whose process is killed. SKIP for a CLI
//     that is not installed.
//
//   ./run.sh

import Foundation
import Darwin

var failures = 0
func check(_ label: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    print(cond ? "  PASS  \(label)" : "  FAIL  \(label) \(detail())")
    if !cond { failures += 1 }
}

let fm = FileManager.default
let scratch = URL(fileURLWithPath: "/tmp", isDirectory: true)
    .appendingPathComponent("sipai-xw-\(getpid())", isDirectory: true)
try? fm.removeItem(at: scratch)
try! fm.createDirectory(at: scratch, withIntermediateDirectories: true)
var spawned: [Process] = []
/// Every process this harness started, and its scratch directory, go at
/// the end — called before `exit`, which runs no top-level `defer`.
func cleanUp() {
    for p in spawned where p.isRunning { kill(-p.processIdentifier, SIGKILL) }
    try? fm.removeItem(at: scratch)
}

func json(_ object: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           encoding: .utf8)!
}
func object(_ line: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
}
func realPath(_ url: URL) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    if let resolved = realpath(url.path, &buffer) { return String(cString: resolved) }
    return url.standardizedFileURL.path
}
func append(_ lines: [String], to url: URL) {
    let handle = try! FileHandle(forWritingTo: url)
    handle.seekToEndOfFile()
    handle.write(Data(lines.map { $0 + "\n" }.joined().utf8))
    try? handle.close()
}
func iso(_ seconds: Int) -> String {
    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
}

// MARK: - Fixtures
//
// Keys as a real codex-cli rollout writes them (`event_msg` payloads,
// `response_item` messages) and as a real kimi wire does (`turn.prompt`,
// `context.append_message`, loop events, `turn.ended`,
// `prompt.completed`). Only the text is made up.

enum Codex {
    static func taskStarted(_ turn: String, at start: Int) -> String {
        json(["timestamp": iso(start), "ordinal": 1, "type": "event_msg",
              "payload": ["type": "task_started", "turn_id": turn, "root_turn_id": turn,
                          "started_at": start, "model_context_window": 258400,
                          "collaboration_mode_kind": "default"]])
    }
    static func taskComplete(_ turn: String, started: Int, ms: Int) -> String {
        json(["timestamp": iso(started + ms / 1000), "ordinal": 9, "type": "event_msg",
              "payload": ["type": "task_complete", "turn_id": turn, "last_agent_message": "OK",
                          "started_at": started, "completed_at": started + ms / 1000,
                          "duration_ms": ms, "time_to_first_token_ms": 5]])
    }
    /// The end a turn is given when it is interrupted — the shape the
    /// scanner's `turnEnded` reads.
    static func turnAborted(_ turn: String) -> String {
        json(["timestamp": iso(1_790_000_100), "type": "event_msg",
              "payload": ["type": "turn_aborted", "turn_id": turn, "reason": "interrupted"]])
    }
    static func user(_ text: String) -> String {
        json(["timestamp": iso(1_790_000_001), "ordinal": 6, "type": "response_item",
              "payload": ["type": "message", "id": "msg_user", "role": "user",
                          "content": [["type": "input_text", "text": text]]]])
    }
    static func environment() -> String {
        user("<environment_context>\n  <cwd>/tmp/x</cwd>\n</environment_context>")
    }
    static func assistant(_ text: String) -> String {
        json(["timestamp": iso(1_790_000_006), "ordinal": 9, "type": "response_item",
              "payload": ["type": "message", "id": "msg_fake", "role": "assistant",
                          "content": [["type": "output_text", "text": text]]]])
    }
    static func tokenCount() -> String {
        json(["timestamp": iso(1_790_000_006), "type": "event_msg",
              "payload": ["type": "token_count",
                          "info": ["last_token_usage": ["input_tokens": 10, "output_tokens": 1,
                                                        "total_tokens": 11],
                                   "model_context_window": 258400]]])
    }
}

enum Kimi {
    static func turnPrompt(_ id: String, time: Int) -> String {
        json(["type": "turn.prompt", "agentId": "main",
              "input": [["type": "text", "text": "a question"]],
              "origin": ["kind": "user"], "promptId": id, "turnId": 0, "time": time])
    }
    static func user(_ id: String, _ text: String, time: Int) -> String {
        json(["type": "context.append_message", "agentId": "main",
              "message": ["role": "user", "content": [["type": "text", "text": text]],
                          "id": id, "toolCalls": [], "origin": ["kind": "user"]],
              "time": time])
    }
    static func agentTurnStarted(time: Int) -> String {
        json(["turnId": 0, "queueItemId": "msg_x", "type": "agent.turn.started",
              "time": time, "kind": "event"])
    }
    static func text(_ text: String, time: Int) -> String {
        json(["type": "context.append_loop_event", "agentId": "main",
              "event": ["type": "content.part", "uuid": UUID().uuidString, "turnId": "0",
                        "step": 1, "part": ["type": "text", "text": text]],
              "time": time])
    }
    static func agentTurnEnded(time: Int) -> String {
        json(["turnId": 0, "outcome": "done", "type": "agent.turn.ended",
              "time": time, "kind": "event"])
    }
    static func steer(time: Int) -> String {
        json(["type": "turn.steer", "agentId": "main", "time": time])
    }
    static func turnEnded(ms: Int, time: Int) -> String {
        json(["type": "turn.ended", "agentId": "main", "turnId": 0,
              "reason": "completed", "durationMs": ms, "time": time])
    }
    static func promptCompleted(_ id: String, time: Int) -> String {
        json(["type": "prompt.completed", "agentId": "main", "promptId": id,
              "finishedAt": "2026-01-01T00:00:06.000Z", "reason": "completed", "time": time])
    }
}

// MARK: - 1. The rules

print("1. which records open and close a turn; what a file's newest turn is; rows as events")

let codexFormat = AgentSessionTailer.Format.codex(threadId: "t", sessionRoot: scratch)
let kimiFormat = AgentSessionTailer.Format.kimi(workDir: "/nowhere")
func marker(_ line: String, _ format: AgentSessionTailer.Format) -> Bool? {
    AgentSessionTailer.turnMarker(object(line), format: format)
}
check("codex: task_started opens a turn; task_complete and turn_aborted close it",
      marker(Codex.taskStarted("a", at: 1), codexFormat) == true
        && marker(Codex.taskComplete("a", started: 1, ms: 5), codexFormat) == false
        && marker(Codex.turnAborted("a"), codexFormat) == false)
check("…messages, usage and bookkeeping carry no signal",
      marker(Codex.user("hi"), codexFormat) == nil
        && marker(Codex.assistant("OK"), codexFormat) == nil
        && marker(Codex.tokenCount(), codexFormat) == nil)
check("kimi: turn.prompt opens a turn; turn.ended and prompt.completed close it",
      marker(Kimi.turnPrompt("p", time: 1), kimiFormat) == true
        && marker(Kimi.turnEnded(ms: 5, time: 2), kimiFormat) == false
        && marker(Kimi.promptCompleted("p", time: 3), kimiFormat) == false)
check("…the inner agent.turn records and a mid-turn steer carry NO signal — the dot must not flicker through a turn",
      marker(Kimi.agentTurnStarted(time: 1), kimiFormat) == nil
        && marker(Kimi.agentTurnEnded(time: 1), kimiFormat) == nil
        && marker(Kimi.steer(time: 1), kimiFormat) == nil
        && marker(Kimi.user("p", "hi", time: 1), kimiFormat) == nil
        && marker(Kimi.text("OK", time: 1), kimiFormat) == nil)
check("claude is left to its own rules (`progressState`)",
      marker(Codex.taskStarted("a", at: 1), .claude) == nil)

let codexFile = scratch.appendingPathComponent("rollout-2026-01-01T00-00-00-00000000-0000-0000-0000-000000000001.jsonl")
try! ([Codex.taskStarted("t1", at: 1_790_000_000), Codex.user("one"), Codex.assistant("OK"),
       Codex.taskComplete("t1", started: 1_790_000_000, ms: 6025)]
      .joined(separator: "\n") + "\n").write(to: codexFile, atomically: true, encoding: .utf8)
let closedCodex = CodexSessionScanner.latestTurn(of: codexFile)
check("codex: the newest turn, closed, with codex's own duration_ms",
      closedCodex?.open == false && closedCodex?.seconds == 6.025
        && closedCodex?.startedAt == Date(timeIntervalSince1970: 1_790_000_000),
      "— got \(String(describing: closedCodex))")
append([Codex.taskStarted("t2", at: 1_790_000_100), Codex.user("two")], to: codexFile)
let openCodex = CodexSessionScanner.latestTurn(of: codexFile)
check("…and an open one, started at codex's own started_at",
      openCodex?.open == true && openCodex?.startedAt == Date(timeIntervalSince1970: 1_790_000_100),
      "— got \(String(describing: openCodex))")

let kimiFile = scratch.appendingPathComponent("wire.jsonl")
try! ([Kimi.turnPrompt("p1", time: 1_790_000_000_000), Kimi.user("p1", "one", time: 1_790_000_000_001),
       Kimi.agentTurnStarted(time: 1_790_000_000_002), Kimi.text("OK", time: 1_790_000_006_000),
       Kimi.agentTurnEnded(time: 1_790_000_006_001), Kimi.turnEnded(ms: 6058, time: 1_790_000_006_058),
       Kimi.promptCompleted("p1", time: 1_790_000_006_059)]
      .joined(separator: "\n") + "\n").write(to: kimiFile, atomically: true, encoding: .utf8)
let closedKimi = KimiSessionScanner.latestTurn(of: kimiFile)
check("kimi: the newest turn, closed, with kimi's own durationMs",
      closedKimi?.open == false && closedKimi?.seconds == 6.058,
      "— got \(String(describing: closedKimi))")
append([Kimi.turnPrompt("p2", time: 1_790_000_100_000)], to: kimiFile)
let openKimi = KimiSessionScanner.latestTurn(of: kimiFile)
check("…and an open one, started at the prompt record's time (milliseconds)",
      openKimi?.open == true && openKimi?.startedAt == Date(timeIntervalSince1970: 1_790_000_100),
      "— got \(String(describing: openKimi))")
let emptyFile = scratch.appendingPathComponent("empty.jsonl")
try! (Codex.user("no markers") + "\n").write(to: emptyFile, atomically: true, encoding: .utf8)
check("a file with no turn marker has no newest turn",
      CodexSessionScanner.latestTurn(of: emptyFile) == nil
        && KimiSessionScanner.latestTurn(of: emptyFile) == nil)
// A turn whose output since its start marker outgrows the first window
// the reader looks in: a session opened that far into it must still
// read as running.
let deepCodex = scratch.appendingPathComponent("deep-rollout.jsonl")
let codexFiller = Codex.assistant(String(repeating: "x", count: 4000))
try! ([Codex.taskStarted("deep", at: 1_790_000_600)] + Array(repeating: codexFiller, count: 300))
    .joined(separator: "\n").appending("\n").write(to: deepCodex, atomically: true, encoding: .utf8)
check("codex: a start marker more than 1 MB behind EOF is still found — the window escalates",
      CodexSessionScanner.latestTurn(of: deepCodex)?.open == true,
      "— got \(String(describing: CodexSessionScanner.latestTurn(of: deepCodex)))")
let deepKimi = scratch.appendingPathComponent("deep-wire.jsonl")
let kimiFiller = Kimi.text(String(repeating: "x", count: 4000), time: 1_790_000_600_001)
try! ([Kimi.turnPrompt("deep", time: 1_790_000_600_000)] + Array(repeating: kimiFiller, count: 300))
    .joined(separator: "\n").appending("\n").write(to: deepKimi, atomically: true, encoding: .utf8)
check("kimi likewise", KimiSessionScanner.latestTurn(of: deepKimi)?.open == true,
      "— got \(String(describing: KimiSessionScanner.latestTurn(of: deepKimi)))")

func kindName(_ event: StreamEvent) -> String {
    switch event.kind {
    case .userMessage(let text): return "user:\(text)"
    case .assistantText(let text): return "assistant:\(text)"
    case .thinking: return "thinking"
    case .toolUse(_, let name, _): return "tool:\(name)"
    case .toolResult(_, let output, _): return "result:\(output)"
    case .interrupted: return "interrupted"
    case .compaction: return "compaction"
    default: return "other"
    }
}
let mapped = [
    AgentSessionHistoryItem(kind: .userText("q"), isSystemNotice: true, attachedFiles: ["a.txt"]),
    AgentSessionHistoryItem(kind: .assistantText("a")),
    AgentSessionHistoryItem(kind: .thinking("private")),
    AgentSessionHistoryItem(kind: .toolUse(id: "1", name: "shell", input: [:])),
    AgentSessionHistoryItem(kind: .toolResult(toolUseId: "1", content: "out", isError: false)),
    AgentSessionHistoryItem(kind: .interrupted(message: "Interrupted")),
    AgentSessionHistoryItem(kind: .compaction(preTokens: 9, postTokens: 1)),
].compactMap(AgentSessionTailer.liveEvent(for:))
check("one decoded row, one live event — every kind but a thought",
      mapped.map(kindName) == ["user:q", "assistant:a", "tool:shell", "result:out",
                               "interrupted", "compaction"],
      "— got \(mapped.map(kindName))")
check("…a notice stays a notice, and a user row keeps its attachment names",
      mapped.first?.isSystemNotice == true && mapped.first?.attachedFiles == ["a.txt"])

var rollout = CodexSessionScanner.RolloutDecoder()
let codexRows = [Codex.taskStarted("t", at: 1), Codex.environment(), Codex.user("hello"),
                 Codex.assistant("OK"), Codex.tokenCount(), Codex.taskComplete("t", started: 1, ms: 5)]
    .flatMap { rollout.items(forLine: $0) }.compactMap(AgentSessionTailer.liveEvent(for:))
check("codex lines through the reader the reopened transcript uses: the prompt and the answer, no context",
      codexRows.map(kindName) == ["user:hello", "assistant:OK"], "— got \(codexRows.map(kindName))")
var wire = KimiSessionScanner.WireDecoder()
let kimiRows = [Kimi.turnPrompt("p", time: 1), Kimi.user("p", "hello", time: 2),
                Kimi.agentTurnStarted(time: 3), Kimi.text("OK", time: 4),
                Kimi.turnEnded(ms: 5, time: 6)]
    .flatMap { wire.items(forLine: $0) }.compactMap(AgentSessionTailer.liveEvent(for:))
check("kimi lines likewise", kimiRows.map(kindName) == ["user:hello", "assistant:OK"],
      "— got \(kimiRows.map(kindName))")

// MARK: - 2. The real tailer, real stand-in writers

print("2. the real tailer over a growing file, with real writers standing in")

/// Run the main run loop — where the tailer's MainActor deliveries land —
/// until `condition` holds or `timeout` passes.
@discardableResult
func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
}

final class Watch {
    var events: [String] = []
    var flips: [Bool] = []
    var live: Bool { flips.last ?? false }
    var tailer: AgentSessionTailer!
    init(_ url: URL, _ format: AgentSessionTailer.Format, offset: UInt64? = nil) {
        tailer = AgentSessionTailer(
            fileURL: url, fallbackCwd: scratch, format: format,
            onEvents: { [weak self] batch in self?.events += batch.map(kindName) },
            onExternalInProgressChange: { [weak self] value in self?.flips.append(value) })
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.uint64Value ?? 0
        tailer.start(initialOffset: offset ?? size)
    }
    func stop() { tailer.stop() }
}

/// A process holding an exclusive (or shared) `flock` on `path` until
/// killed — codex's writer lock, as a live codex holds it.
func holdLock(_ path: URL, shared: Bool = false) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = ["-c", """
        import fcntl, os, sys, time
        fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT)
        fcntl.flock(fd, fcntl.LOCK_SH if sys.argv[2] == "1" else fcntl.LOCK_EX)
        print("locked", flush=True)
        time.sleep(600)
        """, path.path, shared ? "1" : "0"]
    let out = Pipe()
    p.standardOutput = out
    try! p.run()
    spawned.append(p)
    _ = out.fileHandleForReading.availableData   // blocks until "locked"
    return p
}

let locks = scratch.appendingPathComponent("thread-writer-locks", isDirectory: true)
try! fm.createDirectory(at: locks, withIntermediateDirectories: true)
let sessionRoot = scratch.appendingPathComponent("sessions", isDirectory: true)
let thread = "00000000-0000-0000-0000-00000000000a"
let lockFile = locks.appendingPathComponent(thread + ".lock")

// The probe.
check("codex probe: no lock file, no writer",
      !ExternalWriterProbe.codexThreadLocked(threadId: thread, sessionRoot: sessionRoot))
var holder = holdLock(lockFile)
check("…an exclusively held lock is a live writer",
      ExternalWriterProbe.codexThreadLocked(threadId: thread, sessionRoot: sessionRoot))
kill(holder.processIdentifier, SIGKILL); holder.waitUntilExit()
check("…the lock file a killed writer leaves behind is NOT",
      fm.fileExists(atPath: lockFile.path)
        && !ExternalWriterProbe.codexThreadLocked(threadId: thread, sessionRoot: sessionRoot))
holder = holdLock(lockFile, shared: true)
check("…a SHARED lock counts too — the test asks about a write lock",
      ExternalWriterProbe.codexThreadLocked(threadId: thread, sessionRoot: sessionRoot))
kill(holder.processIdentifier, SIGKILL); holder.waitUntilExit()
check("…and an id that is not a file name is refused",
      !ExternalWriterProbe.codexThreadLocked(threadId: "../" + thread, sessionRoot: sessionRoot)
        && !ExternalWriterProbe.codexThreadLocked(threadId: "", sessionRoot: sessionRoot))

// The lock is only ever TESTED: a process taking it non-blockingly, over
// and over, while the probe runs flat out, never finds it busy.
let contender = Process()
contender.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
contender.arguments = ["-c", """
    import fcntl, os, sys, time
    fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT)
    busy = 0
    end = time.time() + 2.0
    n = 0
    while time.time() < end:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            busy += 1
        n += 1
    print(busy, n, flush=True)
    """, lockFile.path]
let contenderOut = Pipe()
contender.standardOutput = contenderOut
try! contender.run()
var probes = 0
let probeEnd = Date().addingTimeInterval(1.8)
while Date() < probeEnd {
    _ = ExternalWriterProbe.codexThreadLocked(threadId: thread, sessionRoot: sessionRoot)
    probes += 1
}
contender.waitUntilExit()
let contended = String(data: contenderOut.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
    .split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? []
check("codex's lock is only ever TESTED: \(probes) probes never made it busy for a writer taking it",
      contended.count == 2 && contended[0] == 0 && contended[1] > 1000,
      "— busy \(contended.first ?? -1) of \(contended.last ?? -1) attempts; a writer that finds it busy fails")
let tailerSource = (try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)) ?? ""
check("…and the source asks F_GETLK, and never locks, sets a lock or waits on one",
      tailerSource.contains("F_GETLK") && !tailerSource.contains("F_SETLK")
        && !tailerSource.contains("LOCK_EX") && !tailerSource.contains("LOCK_SH"))

// A turn watched from start to end.
try! fm.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
let rolloutFile = sessionRoot.appendingPathComponent("rollout-2026-01-01T00-00-00-\(thread).jsonl")
try! ([Codex.taskStarted("h", at: 1_790_000_000), Codex.user("history"), Codex.assistant("OK"),
       Codex.taskComplete("h", started: 1_790_000_000, ms: 1000)]
      .joined(separator: "\n") + "\n").write(to: rolloutFile, atomically: true, encoding: .utf8)
let codexWatchFormat = AgentSessionTailer.Format.codex(threadId: thread, sessionRoot: sessionRoot)
var watch = Watch(rolloutFile, codexWatchFormat)
holder = holdLock(lockFile)
waitUntil(0.5) { false }
append([Codex.taskStarted("w", at: 1_790_000_200), Codex.environment(),
        Codex.user("watched from elsewhere"), Codex.assistant("working on it")], to: rolloutFile)
check("codex: a turn another process starts lights the flag",
      waitUntil(3) { watch.live }, "— flips \(watch.flips)")
check("…and is drawn live, through the reader the reopened transcript uses",
      waitUntil(3) { watch.events == ["user:watched from elsewhere", "assistant:working on it"] },
      "— got \(watch.events)")
check("…the history before it is not replayed", !watch.events.contains("user:history"))
append([Codex.tokenCount(), Codex.taskComplete("w", started: 1_790_000_200, ms: 4000)], to: rolloutFile)
check("…task_complete puts it out", waitUntil(3) { !watch.live }, "— flips \(watch.flips)")
check("…once each way", watch.flips == [true, false], "— flips \(watch.flips)")

// A writer killed mid-turn: no end marker will ever come.
append([Codex.taskStarted("k", at: 1_790_000_300), Codex.user("about to be killed")], to: rolloutFile)
check("codex: the next turn lights it again", waitUntil(3) { watch.live })
kill(holder.processIdentifier, SIGKILL); holder.waitUntilExit()
check("…the writer killed mid-turn puts it out within the sweep, with no end marker in the file",
      waitUntil(9) { !watch.live } && CodexSessionScanner.latestTurn(of: rolloutFile)?.open == true,
      "— flips \(watch.flips)")
watch.stop()

// A turn whose writer is never seen: not ended on a guess.
watch = Watch(rolloutFile, codexWatchFormat)
waitUntil(0.5) { false }
append([Codex.taskStarted("n", at: 1_790_000_400)], to: rolloutFile)
check("codex: a turn whose writer is never seen is live on its marker",
      waitUntil(3) { watch.live })
waitUntil(7) { !watch.live }
check("…and stays live past the 3 s rule — left to the staleness guard, not ended on a guess",
      watch.live, "— flips \(watch.flips)")
append([Codex.turnAborted("n")], to: rolloutFile)
check("…turn_aborted ends it", waitUntil(3) { !watch.live })
watch.stop()

// A session opened mid-turn.
append([Codex.taskStarted("m", at: 1_790_000_500), Codex.user("already running")], to: rolloutFile)
holder = holdLock(lockFile)
watch = Watch(rolloutFile, codexWatchFormat)
check("codex: a session opened while another process's turn runs starts lit (first sweep)",
      waitUntil(6) { watch.live }, "— flips \(watch.flips)")
check("…without replaying the turn's earlier records", watch.events.isEmpty, "— got \(watch.events)")
watch.stop()
kill(holder.processIdentifier, SIGKILL); holder.waitUntilExit()
watch = Watch(rolloutFile, codexWatchFormat)
waitUntil(5) { watch.live }
check("…but an open turn whose writer is DEAD is residue, and stays dark",
      !watch.live, "— flips \(watch.flips)")
watch.stop()

// Our own turn: the check waits out a suspend.
holder = holdLock(lockFile)
watch = Watch(rolloutFile, codexWatchFormat)
watch.tailer.suspend()
waitUntil(5) { watch.live }
check("codex: while suspended (a turn of OUR OWN on the file) the open-turn check does not fire",
      !watch.live, "— flips \(watch.flips)")
let size = (try? fm.attributesOfItem(atPath: rolloutFile.path)[.size] as? NSNumber)??.uint64Value ?? 0
watch.tailer.resume(atOffset: size)
check("…and runs once resumed", waitUntil(5) { watch.live }, "— flips \(watch.flips)")
watch.stop()
kill(holder.processIdentifier, SIGKILL); holder.waitUntilExit()

// Kimi: the writer is a `kimi` process running in the session's folder.
let kimiBin = scratch.appendingPathComponent("bin", isDirectory: true)
try! fm.createDirectory(at: kimiBin, withIntermediateDirectories: true)
// A real executable named `kimi` that only waits — built by run.sh. (A
// renamed copy of a system binary is killed at launch on macOS.)
let fakeKimi = kimiBin.appendingPathComponent("kimi")
try! fm.copyItem(at: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SIPAI_EXTWATCH_STANDIN"]!),
                 to: fakeKimi)
let folder = scratch.appendingPathComponent("project", isDirectory: true)
try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
func runKimiStandIn(in directory: URL) -> Process {
    let p = Process()
    p.executableURL = fakeKimi
    p.arguments = []
    p.currentDirectoryURL = directory
    try! p.run()
    spawned.append(p)
    waitUntil(0.3) { false }
    return p
}
let workDir = realPath(folder)
check("kimi probe: no kimi process in the folder, no writer",
      !ExternalWriterProbe.kimiRunning(inDirectory: workDir))
var kimiProcess = runKimiStandIn(in: folder)
check("…a process named kimi running in it is a live writer",
      ExternalWriterProbe.kimiRunning(inDirectory: workDir))
check("…in the REAL path — the way kimi records a session's folder",
      workDir.hasPrefix("/private/tmp/")
        && !ExternalWriterProbe.kimiRunning(inDirectory: folder.path))
check("…and not for another folder",
      !ExternalWriterProbe.kimiRunning(inDirectory: realPath(scratch)))

let kimiWire = scratch.appendingPathComponent("kimi-wire.jsonl")
try! ([Kimi.turnPrompt("h", time: 1_790_000_000_000), Kimi.user("h", "history", time: 1_790_000_000_001),
       Kimi.text("OK", time: 1_790_000_001_000), Kimi.turnEnded(ms: 1000, time: 1_790_000_001_001),
       Kimi.promptCompleted("h", time: 1_790_000_001_002)]
      .joined(separator: "\n") + "\n").write(to: kimiWire, atomically: true, encoding: .utf8)
let kimiWatchFormat = AgentSessionTailer.Format.kimi(workDir: workDir)
watch = Watch(kimiWire, kimiWatchFormat)
waitUntil(0.5) { false }
append([Kimi.turnPrompt("w", time: 1_790_000_200_000), Kimi.user("w", "watched from elsewhere", time: 1_790_000_200_001),
        Kimi.agentTurnStarted(time: 1_790_000_200_002), Kimi.text("working on it", time: 1_790_000_201_000),
        Kimi.agentTurnEnded(time: 1_790_000_201_001)], to: kimiWire)
check("kimi: a turn another process starts lights the flag",
      waitUntil(3) { watch.live }, "— flips \(watch.flips)")
check("…is drawn live", waitUntil(3) {
    watch.events == ["user:watched from elsewhere", "assistant:working on it"]
}, "— got \(watch.events)")
check("…and the inner agent.turn.ended does NOT put it out", watch.live)
append([Kimi.turnEnded(ms: 1000, time: 1_790_000_202_000), Kimi.promptCompleted("w", time: 1_790_000_202_001)],
       to: kimiWire)
check("…turn.ended does", waitUntil(3) { !watch.live })
check("…once each way", watch.flips == [true, false], "— flips \(watch.flips)")
append([Kimi.turnPrompt("k", time: 1_790_000_300_000)], to: kimiWire)
check("kimi: the next turn lights it again", waitUntil(3) { watch.live })
kill(kimiProcess.processIdentifier, SIGKILL); kimiProcess.waitUntilExit()
check("…the kimi process killed mid-turn puts it out within the sweep",
      waitUntil(9) { !watch.live }, "— flips \(watch.flips)")
watch.stop()
kimiProcess = runKimiStandIn(in: folder)
watch = Watch(kimiWire, kimiWatchFormat)
check("kimi: a session opened mid-turn with its process alive starts lit",
      waitUntil(6) { watch.live }, "— flips \(watch.flips)")
watch.stop()
kill(kimiProcess.processIdentifier, SIGKILL); kimiProcess.waitUntilExit()

// MARK: - 3. Live, token-free

print("3. the real codex and kimi, over throwaway homes, against a fake endpoint")

func which(_ name: String) -> String? {
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        + ["/opt/homebrew/bin", "/usr/local/bin",
           NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.kimi-code/bin"] {
        let path = "\(dir)/\(name)"
        if fm.isExecutableFile(atPath: path) { return path }
    }
    return nil
}

final class FakeServer {
    let process = Process()
    let port: Int
    init?(delay: String) {
        guard let script = ProcessInfo.processInfo.environment["SIPAI_EXTWATCH_SERVER"] else { return nil }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script, scratch.appendingPathComponent("server-\(UUID().uuidString.prefix(6))").path,
                             "--responses-delay", delay, "--chat-delay", delay]
        let out = Pipe()
        process.standardOutput = out
        guard (try? process.run()) != nil else { return nil }
        spawned.append(process)
        var buffer = Data()
        while !buffer.contains(0x0A) {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
        guard let line = String(data: buffer, encoding: .utf8),
              let value = line.split(separator: "=").last.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        else { return nil }
        port = value
    }
    func stop() { process.terminate() }
}

/// Start a CLI turn in the background: its own process group (so a kill
/// reaches the native codex behind its node launcher too), stdin at EOF.
func launch(_ binary: String, _ args: [String], cwd: URL, env: [String: String]) -> (Process, Pipe) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    p.arguments = args
    p.currentDirectoryURL = cwd
    p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
    p.standardInput = FileHandle.nullDevice
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try! p.run()
    spawned.append(p)
    return (p, out)
}
func finish(_ p: Process, _ out: Pipe) -> String {
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}
func firstFile(named suffix: String, under root: URL) -> URL? {
    guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
    for case let url as URL in walker where url.path.hasSuffix(suffix) { return url }
    return nil
}

let skipLive = ProcessInfo.processInfo.environment["SIPAI_EXTWATCH_SKIP_LIVE"] == "1"
if skipLive {
    print("  SKIP  live pass (SIPAI_EXTWATCH_SKIP_LIVE=1)")
} else if let codex = which("codex"), let server = FakeServer(delay: "5") {
    // Short: a codex home's control socket path must fit in sun_path.
    let home = URL(fileURLWithPath: "/tmp/sxw-cx-\(getpid())", isDirectory: true)
    try? fm.removeItem(at: home)
    let cwd = home.appendingPathComponent("cwd", isDirectory: true)
    try! fm.createDirectory(at: cwd, withIntermediateDirectories: true)
    try! """
        model_provider = "fake"
        model = "gpt-5.5"

        [model_providers.fake]
        name = "fake"
        base_url = "http://127.0.0.1:\(server.port)"
        wire_api = "responses"

        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    let env = ["CODEX_HOME": home.path]
    let base = ["exec", "--json", "--skip-git-repo-check"]
    let (first, firstOut) = launch(codex, base + ["the first turn"], cwd: cwd, env: env)
    let firstText = finish(first, firstOut)
    let threadId = firstText.split(separator: "\n")
        .first { $0.contains("thread.started") }
        .flatMap { line in line.firstIndex(of: "{").map { object(String(line[$0...]))["thread_id"] as? String } }
        ?? nil
    let codexRollout = threadId.flatMap { firstFile(named: "\($0).jsonl", under: home.appendingPathComponent("sessions")) }
    check("codex: a session to watch (exit \(first.terminationStatus))", threadId != nil && codexRollout != nil)
    if let threadId, let codexRollout {
        let format = AgentSessionTailer.Format.codex(
            threadId: threadId, sessionRoot: home.appendingPathComponent("sessions"))
        let live = Watch(codexRollout, format)
        waitUntil(0.5) { false }
        let (turn, turnOut) = launch(codex, base + ["resume", threadId, "a turn run elsewhere"],
                                     cwd: cwd, env: env)
        check("codex live: `codex exec resume` from elsewhere lights the flag while its turn runs",
              waitUntil(8) { live.live }, "— flips \(live.flips)")
        check("…draws its prompt live", waitUntil(3) { live.events.contains("user:a turn run elsewhere") },
              "— got \(live.events)")
        _ = finish(turn, turnOut)
        check("…and puts it out when the turn ends", waitUntil(6) { !live.live }, "— flips \(live.flips)")
        check("…with the answer drawn", live.events.contains("assistant:OK"), "— got \(live.events)")
        let (killed, _) = launch(codex, base + ["resume", threadId, "a turn that is killed"],
                                 cwd: cwd, env: env)
        check("codex live: the next turn lights it", waitUntil(8) { live.live }, "— flips \(live.flips)")
        kill(-killed.processIdentifier, SIGKILL)
        killed.waitUntilExit()
        check("…the process killed mid-turn puts it out within the sweep",
              waitUntil(9) { !live.live }, "— flips \(live.flips)")
        check("…though the rollout still reads as an open turn — killed, not finished",
              CodexSessionScanner.latestTurn(of: codexRollout)?.open == true)
        live.stop()
    }
    server.stop()
    try? fm.removeItem(at: home)
} else {
    print("  SKIP  codex live pass (no codex, or no fake server)")
}

if !skipLive, let kimi = which("kimi"), let server = FakeServer(delay: "5") {
    let home = scratch.appendingPathComponent("kimi-home", isDirectory: true)
    let cwd = home.appendingPathComponent("cwd", isDirectory: true)
    try! fm.createDirectory(at: cwd, withIntermediateDirectories: true)
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
    let env = ["KIMI_CODE_HOME": home.path]
    let stream = ["--output-format", "stream-json"]
    let (first, firstOut) = launch(kimi, ["--prompt", "the first turn"] + stream, cwd: cwd, env: env)
    let firstText = finish(first, firstOut)
    let sessionId = firstText.split(separator: "\n")
        .first { $0.contains("session.resume_hint") }
        .flatMap { line in line.firstIndex(of: "{").map { object(String(line[$0...]))["session_id"] as? String } }
        ?? nil
    let wireFile = sessionId.flatMap {
        firstFile(named: "\($0)/agents/main/wire.jsonl", under: home.appendingPathComponent("sessions"))
    }
    check("kimi: a session to watch (exit \(first.terminationStatus))", sessionId != nil && wireFile != nil)
    if let sessionId, let wireFile {
        let live = Watch(wireFile, .kimi(workDir: realPath(cwd)))
        waitUntil(0.5) { false }
        let (turn, turnOut) = launch(kimi, ["--prompt", "a turn run elsewhere", "--session", sessionId] + stream,
                                     cwd: cwd, env: env)
        check("kimi live: `kimi --session` from elsewhere lights the flag while its turn runs",
              waitUntil(8) { live.live }, "— flips \(live.flips)")
        check("…draws its prompt live", waitUntil(3) { live.events.contains("user:a turn run elsewhere") },
              "— got \(live.events)")
        _ = finish(turn, turnOut)
        check("…and puts it out when the turn ends", waitUntil(6) { !live.live }, "— flips \(live.flips)")
        check("…with the answer drawn", live.events.contains("assistant:OK"), "— got \(live.events)")
        let (killed, _) = launch(kimi, ["--prompt", "a turn that is killed", "--session", sessionId] + stream,
                                 cwd: cwd, env: env)
        check("kimi live: the next turn lights it", waitUntil(8) { live.live }, "— flips \(live.flips)")
        kill(-killed.processIdentifier, SIGKILL)
        killed.waitUntilExit()
        check("…the process killed mid-turn puts it out within the sweep",
              waitUntil(9) { !live.live }, "— flips \(live.flips)")
        live.stop()
    }
    server.stop()
} else if !skipLive {
    print("  SKIP  kimi live pass (no kimi, or no fake server)")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
cleanUp()
exit(failures == 0 ? 0 : 1)
