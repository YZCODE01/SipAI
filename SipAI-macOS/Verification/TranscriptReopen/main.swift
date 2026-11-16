// main.swift — TranscriptReopen
//
// Send a follow-up in a session, look at something else while it runs —
// a chat, a note, Settings, a new-session draft, a scheduled task's page —
// and come back: the transcript must show every earlier turn above the
// running one, each once. A reload that skips the read whenever nothing
// from disk is on screen and a turn of ours is running draws the page from
// the follow-up down instead, with every earlier turn missing until the
// session is opened once more. That skip is right for one reload only: the
// draft→session flip, whose live buffer holds the whole session.
//
// Reading there is half of it. The live buffer keeps every turn that ended
// while the session stayed on screen; a read that cuts only the RUNNING
// turn out of what it read leaves those turns in both lists, drawn twice —
// on a return mid-turn, and on "Show earlier".
//
// And a read lands after it was taken: one that began while a turn ran
// and lands after it ended can stop short of that turn's end, and landing
// it with no turn running empties the live buffer that drew the end.
//
// The page then draws ONE run of rows over the two lists. Capped
// separately and stacked, the read's window and the live buffer's hid the
// buffer's oldest rows between them whenever a turn outgrew its cap: a
// "Show earlier" in the middle of the page, earlier turns above it, the
// running turn's own question hidden inside it.
//
// Four passes:
//
//  1. The rules (`TranscriptSeam`), case by case.
//  2. The page, replayed step by step for each agent: the REAL reader over
//     a transcript written in that CLI's own shape, and the view's reload
//     and the runner's buffer modelled the way AgentSessionView and
//     AgentRunner apply the rules. The rule before the fix runs beside it
//     as the negative control, and must reproduce the report.
//  3. The window drawn over the two lists — contiguous, held still while
//     the reader is away from the end — with the two stacked windows it
//     replaced as the negative control.
//  4. The wiring, read off AgentSessionView.swift and AgentRunner.swift.
//
//   ./run.sh [source-root]

import Foundation

var checks = 0
var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if ok {
        print("  ok   \(label)")
    } else {
        failures += 1
        let d = detail()
        print("  FAIL \(label)\(d.isEmpty ? "" : "\n         \(d)")")
    }
}
func section(_ title: String) { print("\n\(title)") }

guard CommandLine.arguments.count > 1 else {
    print("usage: reopen <source-root>")
    exit(2)
}
let src = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("transcriptreopen-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

func json(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}
func iso(_ seconds: Int) -> String {
    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(1_790_000_000 + seconds)))
}

// MARK: - The page's rows, spelled so a turn drawn twice reads twice

func label(_ item: AgentSessionHistoryItem) -> String? {
    switch item.kind {
    case .userText(let t):
        return (item.isSystemNotice ? "notice " : item.sentIntoTurn ? "reply " : "you ") + t
    case .assistantText(let t): return "agent " + t
    case .error(let m): return "error " + m
    default: return nil
    }
}
func label(_ event: StreamEvent) -> String? {
    switch event.kind {
    case .userMessage(let t):
        return (event.isSystemNotice ? "notice " : event.sentIntoTurn ? "reply " : "you ") + t
    case .assistantText(let t): return "agent " + t
    case .error(let m): return "error " + m
    default: return nil
    }
}

// MARK: - The three stores
//
// Keys as each CLI writes them — a claude JSONL record, a codex rollout's
// `session_meta` / `event_msg` / `response_item`, a kimi wire's
// `turn.prompt` / `context.append_message` / loop events / `turn.ended`.
// Only the words are made up.

struct Agent {
    let name: String
    /// What a new transcript file opens with.
    let header: [String]
    /// The message as the CLI records it, opening turn `n`.
    let user: (_ wire: String, _ n: Int) -> [String]
    let answer: (_ text: String, _ n: Int) -> [String]
    let end: (_ n: Int) -> [String]
    /// A row in the user column that opens no turn — the CLI's own notice
    /// of a finished background task, or (codex) the user's answer steered
    /// into the running turn — as the file records it, and as the live
    /// buffer draws it.
    let aside: (_ n: Int) -> [String]
    let asideEvent: () -> StreamEvent
    /// The text `AgentRunner.send` draws for the text it sends.
    let display: (_ wire: String) -> String
    let read: (URL) -> [AgentSessionHistoryItem]
}

let claude = Agent(
    name: "Claude Code",
    header: [],
    user: { wire, n in
        [json(["type": "user", "uuid": "u\(n)", "sessionId": "s1", "timestamp": iso(n),
               "message": ["role": "user", "content": wire]])]
    },
    answer: { text, n in
        [json(["type": "assistant", "uuid": "a\(n)-\(UUID().uuidString)", "sessionId": "s1",
               "timestamp": iso(n),
               "message": ["model": "claude-x", "role": "assistant",
                           "content": [["type": "text", "text": text]]]])]
    },
    end: { _ in [] },
    aside: { n in
        [json(["type": "user", "uuid": "n\(n)", "sessionId": "s1", "timestamp": iso(n),
               "message": ["role": "user",
                           "content": "<task-notification>\n<summary>Background task finished</summary>\n</task-notification>"]])]
    },
    asideEvent: { StreamEvent(kind: .userMessage(text: "Background task finished"), isSystemNotice: true) },
    display: { CodexSessionScanner.strippedTaskMarker($0, mentionLine: false) },
    read: { AgentSessionScanner.readHistory(of: $0) }
)

let codex = Agent(
    name: "Codex",
    header: [json(["timestamp": iso(0), "type": "session_meta",
                   "payload": ["id": "019a0000-0000-7000-8000-000000000001", "timestamp": iso(0),
                               "cwd": "/tmp/transcriptreopen", "originator": "codex_exec",
                               "cli_version": "0.0.0", "source": "exec"]])],
    user: { wire, n in
        [json(["timestamp": iso(n), "type": "event_msg",
               "payload": ["type": "task_started", "turn_id": "turn-\(n)"]]),
         json(["timestamp": iso(n), "type": "response_item",
               "payload": ["type": "message", "role": "user",
                           "content": [["type": "input_text", "text": wire]]]])]
    },
    answer: { text, n in
        [json(["timestamp": iso(n), "type": "response_item",
               "payload": ["type": "message", "role": "assistant",
                           "content": [["type": "output_text", "text": text]]]])]
    },
    end: { n in
        [json(["timestamp": iso(n), "type": "event_msg",
               "payload": ["type": "task_complete", "turn_id": "turn-\(n)"]])]
    },
    aside: { n in
        let reply = "<send_user_message_question_reply>\n"
            + "[{\"answer\":\"Blue\",\"question\":\"Which colour?\",\"questionItemId\":\"q-\(n)\"}]\n"
            + "</send_user_message_question_reply>"
        return [json(["timestamp": iso(n), "type": "response_item",
                      "payload": ["type": "message", "role": "user",
                                  "content": [["type": "input_text", "text": reply]]]])]
    },
    asideEvent: { StreamEvent(kind: .userMessage(text: "> Which colour?\n\nBlue"), sentIntoTurn: true) },
    display: { CodexSessionScanner.strippedTaskMarker($0, mentionLine: true) },
    read: { CodexSessionScanner.readHistory(of: $0, root: scratch) }
)

let kimi = Agent(
    name: "Kimi Code",
    header: [],
    user: { wire, n in
        [json(["type": "turn.prompt", "agentId": "main", "input": [["type": "text", "text": wire]],
               "origin": ["kind": "user"], "promptId": "p\(n)", "turnId": n, "time": n]),
         json(["type": "context.append_message", "agentId": "main",
               "message": ["role": "user", "content": [["type": "text", "text": wire]],
                           "id": "p\(n)", "toolCalls": [], "origin": ["kind": "user"]],
               "time": n])]
    },
    answer: { text, n in
        [json(["type": "context.append_loop_event", "agentId": "main",
               "event": ["type": "content.part", "uuid": UUID().uuidString, "turnId": "\(n)",
                         "step": 1, "part": ["type": "text", "text": text]],
               "time": n])]
    },
    end: { n in
        [json(["type": "turn.ended", "agentId": "main", "turnId": n, "reason": "completed",
               "durationMs": 1000, "time": n])]
    },
    aside: { n in
        [json(["type": "context.append_message", "agentId": "main",
               "message": ["role": "user",
                           "content": [["type": "text",
                                        "text": "<notification>Title: Background process completed</notification>"]],
                           "id": "t\(n)", "toolCalls": [],
                           "origin": ["kind": "task", "taskId": "task-\(n)"]],
               "time": n])]
    },
    asideEvent: { StreamEvent(kind: .userMessage(text: "Background process completed"), isSystemNotice: true) },
    display: { CodexSessionScanner.strippedTaskMarker($0, mentionLine: false) },
    read: { KimiSessionScanner.readHistory(of: $0) }
)

let agents = [claude, codex, kimi]

// MARK: - One session on the page
//
// Its file, the runner's live buffer and what the view holds — modelled on
// `AgentSessionView.reload()` / `adoptHistory` and `AgentRunner.send` /
// `clearEvents` / `dropTurnsBeforeRunningTurn`, each step driving the REAL
// rule. `.beforeTheFix` is the rule this replaced, kept as the negative
// control; `.readWithoutCutBack` reads on every return but leaves the live
// buffer whole, the half of the fix that is not enough.

final class Session {
    enum Rule { case shipped, beforeTheFix, readWithoutCutBack }

    let agent: Agent
    let rule: Rule
    let url: URL
    // The runner.
    var events: [StreamEvent] = []
    var running = false
    var opening: UUID? = nil
    var sent: String? = nil
    /// `RunStatus.runningSince`: one date per turn, nil while none runs.
    var turnStartedAt: Date? = nil
    // The view.
    var history: [AgentSessionHistoryItem] = []
    var cache: (items: [AgentSessionHistoryItem], size: Int)? = nil
    private var turn = 0

    /// A session whose file already holds `earlier` finished turns.
    init(_ agent: Agent, _ rule: Rule, earlier: [String] = ["question 1", "question 2", "question 3"]) {
        self.agent = agent
        self.rule = rule
        url = scratch.appendingPathComponent("\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        write(agent.header)
        for (i, question) in earlier.enumerated() {
            turn += 1
            write(agent.user(question, turn))
            write(agent.answer("answer \(i + 1)", turn))
            write(agent.end(turn))
        }
    }

    var fileSize: Int { (try? Data(contentsOf: url).count) ?? 0 }
    func write(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let handle = try! FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(lines.map { $0 + "\n" }.joined().utf8))
        try? handle.close()
    }

    // MARK: The CLI and the runner

    func send(_ wire: String) {
        turn += 1
        let shown = agent.display(wire)
        let message = StreamEvent(kind: .userMessage(text: shown))
        events.append(message)
        opening = message.id
        sent = shown
        running = true
        turnStartedAt = Date(timeIntervalSince1970: TimeInterval(turn))
        write(agent.user(wire, turn))
    }
    func say(_ text: String) {
        events.append(StreamEvent(kind: .assistantText(text: text)))
        write(agent.answer(text, turn))
    }
    func aside() {
        events.append(agent.asideEvent())
        write(agent.aside(turn))
    }
    func end() {
        write(agent.end(turn))
        running = false
        turnStartedAt = nil
    }
    /// A turn that ends on an error row only the live buffer holds.
    func fail(_ message: String) {
        events.append(StreamEvent(kind: .error(message: message)))
        running = false
        turnStartedAt = nil
    }
    /// The buffer's front trim (`AgentRunner.trimLiveEventsIfNeeded`).
    func trimFront(_ count: Int) { events.removeFirst(count) }

    func clearEvents() {
        guard !running else { return }
        events.removeAll()
    }
    func dropTurnsBeforeRunningTurn() {
        guard running,
              let start = TranscriptSeam.runningTurnStart(in: events, opening: opening),
              start > 0 else { return }
        events.removeFirst(start)
    }

    // MARK: The view

    /// The cut this replaced (`trimmedForInFlight`), spellings and all.
    private func cutBeforeTheFix(_ read: [AgentSessionHistoryItem]) -> [AgentSessionHistoryItem] {
        guard running, let sent,
              events.contains(where: { event in
                  if case .userMessage(let t) = event.kind { return t == sent }
                  return false
              })
        else { return read }
        let spellings: Set<String> = [sent, AgentSessionScanner.cleanUserText(sent),
                                      CodexSessionScanner.strippedTaskMarker(sent)]
        guard let at = read.lastIndex(where: { item in
            if case .userText(let t) = item.kind { return spellings.contains(t) }
            return false
        }) else { return read }
        return Array(read[..<at])
    }

    func adopt(_ read: [AgentSessionHistoryItem], fromFile: Bool) {
        switch rule {
        case .shipped:
            let holdsStart = running
                && TranscriptSeam.runningTurnStart(in: events, opening: opening) != nil
            let cut = TranscriptSeam.cut(read, runningTurnText: holdsStart ? sent : nil)
            history = cut.items
            switch TranscriptSeam.liveBuffer(turnRunning: running, readFromFile: fromFile,
                                             readHeldRunningTurn: cut.heldRunningTurn) {
            case .nothing: clearEvents()
            case .runningTurn: dropTurnsBeforeRunningTurn()
            case .everything: break
            }
        case .beforeTheFix, .readWithoutCutBack:
            history = cutBeforeTheFix(read)
            clearEvents()
        }
    }

    private func readsTranscript(draftFlip: Bool) -> Bool {
        switch rule {
        case .shipped, .readWithoutCutBack:
            return TranscriptSeam.readsTranscript(draftFlip: draftFlip,
                                                  historyOnScreen: !history.isEmpty,
                                                  turnRunning: running,
                                                  liveRows: events.count)
        case .beforeTheFix:
            return !(history.isEmpty && (running || (draftFlip && !events.isEmpty)))
        }
    }

    /// `reload()`'s first frame: the history cache's copy when there is
    /// one. True when a read of the file follows (`landRead`).
    @discardableResult
    func openFromCache(draftFlip: Bool = false) -> Bool {
        guard readsTranscript(draftFlip: draftFlip) else { return false }
        guard let cached = cache else { return true }
        adopt(cached.items, fromFile: false)
        return cached.size != fileSize
    }
    /// The read of the file landing (`startHistoryLoad`), which the
    /// history cache keeps.
    func landRead() {
        let read = agent.read(url)
        cache = (read, fileSize)
        adopt(read, fromFile: true)
    }
    func reload(draftFlip: Bool = false) {
        if openFromCache(draftFlip: draftFlip) { landRead() }
    }
    /// A read of the file that begins now and lands later — what
    /// `startHistoryLoad` reads off the main thread.
    struct PendingRead {
        let items: [AgentSessionHistoryItem]
        let size: Int
        let turnStart: Date?
    }
    func beginRead() -> PendingRead {
        PendingRead(items: agent.read(url), size: fileSize, turnStart: turnStartedAt)
    }
    func land(_ pending: PendingRead) {
        if rule == .shipped,
           TranscriptSeam.readIsStale(turnStartAtRead: pending.turnStart,
                                      turnStartNow: turnStartedAt) {
            landRead()
            return
        }
        cache = (pending.items, pending.size)
        adopt(pending.items, fromFile: true)
    }
    /// "Show earlier": a wider read of the file, never cached.
    func showEarlier() {
        let read = agent.read(url)
        switch rule {
        case .shipped: adopt(read, fromFile: true)
        case .beforeTheFix, .readWithoutCutBack: history = cutBeforeTheFix(read)
        }
    }

    /// A chat, a note or Settings: the session view is built afresh.
    func detour() { history = [] }
    /// A new-session draft or a scheduled task's page, in the same view.
    func emptyPage() { history = [] }
    /// Another session with history, in the same view.
    func otherSession() { history = [AgentSessionHistoryItem(kind: .userText("elsewhere"))] }

    var page: [String] { history.compactMap(label) + events.compactMap(label) }
}

func earlierRows(_ count: Int = 3) -> [String] {
    (1...count).flatMap { ["you question \($0)", "agent answer \($0)"] }
}
func occurrences(_ row: String, _ page: [String]) -> Int { page.filter { $0 == row }.count }
func show(_ page: [String]) -> String {
    page.map { $0.replacingOccurrences(of: "\n", with: "⏎") }.joined(separator: " | ")
}

// MARK: - 1. The rules

section("1. The rules — TranscriptSeam")

check("readsTranscript: a view with nothing on screen and a turn of ours running READS",
      TranscriptSeam.readsTranscript(draftFlip: false, historyOnScreen: false,
                                     turnRunning: true, liveRows: 2))
check("…the draft→session flip mid-first-turn does not",
      !TranscriptSeam.readsTranscript(draftFlip: true, historyOnScreen: false,
                                      turnRunning: true, liveRows: 2))
check("…nor the flip of a first turn already over, whose rows only the buffer holds",
      !TranscriptSeam.readsTranscript(draftFlip: true, historyOnScreen: false,
                                      turnRunning: false, liveRows: 2))
check("…a flip with nothing to keep reads",
      TranscriptSeam.readsTranscript(draftFlip: true, historyOnScreen: false,
                                     turnRunning: false, liveRows: 0))
check("…and so does every reload with history on screen",
      TranscriptSeam.readsTranscript(draftFlip: false, historyOnScreen: true,
                                     turnRunning: true, liveRows: 2)
      && TranscriptSeam.readsTranscript(draftFlip: true, historyOnScreen: true,
                                        turnRunning: true, liveRows: 2))

let a = StreamEvent(kind: .userMessage(text: "one"))
let b = StreamEvent(kind: .assistantText(text: "x"))
let c = StreamEvent(kind: .userMessage(text: "two"))
check("runningTurnStart: the index of the message the running turn opened with",
      TranscriptSeam.runningTurnStart(in: [a, b, c, b], opening: c.id) == 2)
check("…nil without one, and once the front trim has cut it away",
      TranscriptSeam.runningTurnStart(in: [a, b], opening: nil) == nil
      && TranscriptSeam.runningTurnStart(in: [b], opening: c.id) == nil)

func row(_ t: String, notice: Bool = false) -> AgentSessionHistoryItem {
    var item = AgentSessionHistoryItem(kind: .userText(t))
    item.isSystemNotice = notice
    return item
}
let reply = AgentSessionHistoryItem(kind: .assistantText("ok"))
let sampleRead = [row("hello"), reply, row("continue"), reply, row("again"), reply, row("continue"), reply]
let cutNewest = TranscriptSeam.cut(sampleRead, runningTurnText: "continue")
check("cut: at the newest record of the running turn's message, and says it held it",
      cutNewest.heldRunningTurn && cutNewest.items.count == 6)
let noText = TranscriptSeam.cut(sampleRead, runningTurnText: nil)
check("…nothing cut without the running turn's text (no turn, or its start trimmed away)",
      !noText.heldRunningTurn && noText.items.count == sampleRead.count)
let missing = TranscriptSeam.cut(sampleRead, runningTurnText: "not in the read")
check("…nor when the read does not reach that message",
      !missing.heldRunningTurn && missing.items.count == sampleRead.count)
let swept = TranscriptSeam.cut([row("hello"), reply, row("Use Vec here"), reply],
                               runningTurnText: "Use Vec<String> here")
check("…a bare <…> matched as the claude and kimi readers sweep it",
      swept.heldRunningTurn && swept.items.count == 2)
let marked = TranscriptSeam.cut([row("hello"), reply, row("Run the report"), reply],
                                runningTurnText: "<scheduled-task name=\"daily\"></scheduled-task>\nRun the report")
check("…a scheduled run's marker matched as the readers strip it",
      marked.heldRunningTurn && marked.items.count == 2)

check("liveBuffer: no turn running — the read holds everything the buffer streamed",
      TranscriptSeam.liveBuffer(turnRunning: false, readFromFile: true, readHeldRunningTurn: false) == .nothing
      && TranscriptSeam.liveBuffer(turnRunning: false, readFromFile: false, readHeldRunningTurn: false) == .nothing)
check("…a read of the file that held the running turn's start: the buffer keeps that turn alone",
      TranscriptSeam.liveBuffer(turnRunning: true, readFromFile: true, readHeldRunningTurn: true) == .runningTurn)
check("…the history cache's copy, or a read that did not reach the running turn: the buffer keeps everything",
      TranscriptSeam.liveBuffer(turnRunning: true, readFromFile: false, readHeldRunningTurn: true) == .everything
      && TranscriptSeam.liveBuffer(turnRunning: true, readFromFile: true, readHeldRunningTurn: false) == .everything)

let t1 = Date(timeIntervalSince1970: 1)
let t2 = Date(timeIntervalSince1970: 2)
check("readIsStale: a read that began under a turn which has ended since is taken again",
      TranscriptSeam.readIsStale(turnStartAtRead: t1, turnStartNow: nil))
check("…and one whose turn gave way to another",
      TranscriptSeam.readIsStale(turnStartAtRead: t1, turnStartNow: t2))
check("…but not one whose turn still runs, nor one begun with no turn running",
      !TranscriptSeam.readIsStale(turnStartAtRead: t1, turnStartNow: t1)
      && !TranscriptSeam.readIsStale(turnStartAtRead: nil, turnStartNow: nil)
      && !TranscriptSeam.readIsStale(turnStartAtRead: nil, turnStartNow: t2))

// MARK: - 2. The page, replayed

section("2. The page, replayed with each agent's real reader")

for agent in agents {
    let n = agent.name
    print("  — \(n)")

    func page(_ rule: Session.Rule, earlier: [String] = ["question 1", "question 2", "question 3"],
              _ steps: (Session) -> Void) -> [String] {
        let s = Session(agent, rule, earlier: earlier)
        steps(s)
        return s.page
    }

    // The report.
    let followUp = earlierRows() + ["you follow-up", "agent working on it"]
    let detourMidTurn: (Session) -> Void = { s in
        s.reload()                 // the session open
        s.send("follow-up")
        s.say("working on it")
        s.detour()                 // a chat, a note, Settings
        s.reload()                 // back, the turn still running
    }
    let got = page(.shipped, detourMidTurn)
    check("\(n): back from a detour while the follow-up runs — every earlier turn above it, each once",
          got == followUp, show(got))
    let before = page(.beforeTheFix, detourMidTurn)
    check("\(n): (control) the rule before the fix shows the follow-up and nothing above it",
          before == ["you follow-up", "agent working on it"], show(before))
    let endsLater = page(.shipped) { s in
        detourMidTurn(s)
        s.say("done")
        s.end()
    }
    check("\(n): …and the page stays whole when the turn then ends",
          endsLater == followUp + ["agent done"], show(endsLater))
    let endsLaterBefore = page(.beforeTheFix) { s in
        detourMidTurn(s)
        s.say("done")
        s.end()
    }
    check("\(n): (control) before the fix it stays missing until the session is opened again",
          endsLaterBefore == ["you follow-up", "agent working on it", "agent done"],
          show(endsLaterBefore))

    let emptyPage: (Session) -> Void = { s in
        s.reload()
        s.send("follow-up")
        s.say("working on it")
        s.emptyPage()              // a new-session draft, a task's page
        s.reload()
    }
    let fromEmpty = page(.shipped, emptyPage)
    check("\(n): back from a draft or a task page — the same", fromEmpty == followUp, show(fromEmpty))
    check("\(n): (control) before the fix, the same report",
          page(.beforeTheFix, emptyPage) == ["you follow-up", "agent working on it"])

    let otherSession: (Session) -> Void = { s in
        s.reload()
        s.send("follow-up")
        s.say("working on it")
        s.otherSession()
        s.reload()
    }
    check("\(n): back from another session's page — whole, with the fix and without (the report needs an empty page)",
          page(.shipped, otherSession) == followUp && page(.beforeTheFix, otherSession) == followUp)

    // Turns that ended while the session stayed on screen.
    let twoFollowUps: (Session) -> Void = { s in
        s.reload()
        s.send("first follow-up")
        s.say("first answer")
        s.end()
        s.send("second follow-up")
        s.say("second, under way")
        s.detour()
        s.reload()
    }
    let both = earlierRows() + ["you first follow-up", "agent first answer",
                                "you second follow-up", "agent second, under way"]
    let gotBoth = page(.shipped, twoFollowUps)
    check("\(n): two follow-ups sent before leaving — every turn once", gotBoth == both, show(gotBoth))
    let halfFix = page(.readWithoutCutBack, twoFollowUps)
    check("\(n): (control) reading without cutting the buffer back draws the first follow-up twice",
          occurrences("you first follow-up", halfFix) == 2, show(halfFix))
    check("\(n): (control) before the fix, both follow-ups and nothing above them",
          page(.beforeTheFix, twoFollowUps) == Array(both.dropFirst(6)))

    // A new session, born as a draft on this page.
    let firstTurn: (Session) -> Void = { s in
        s.send("hello")
        s.say("partial")
        s.detour()
        s.reload()
    }
    let gotFirst = page(.shipped, earlier: [], firstTurn)
    check("\(n): a new session's first turn, opened again while it runs — drawn once",
          gotFirst == ["you hello", "agent partial"], show(gotFirst))
    let threeTurns: (Session) -> Void = { s in
        s.send("one"); s.say("a1"); s.end()
        s.send("two"); s.say("a2"); s.end()
        s.send("three"); s.say("a3 under way")
        s.detour()
        s.reload()
    }
    let three = ["you one", "agent a1", "you two", "agent a2", "you three", "agent a3 under way"]
    let gotThree = page(.shipped, earlier: [], threeTurns)
    check("\(n): a new session with three turns sent from its page, opened again during the third — each once",
          gotThree == three, show(gotThree))
    check("\(n): (control) reading without cutting the buffer back draws its first two turns twice",
          occurrences("you one", page(.readWithoutCutBack, earlier: [], threeTurns)) == 2)

    // The draft→session flip reads nothing.
    let flip = Session(agent, .shipped, earlier: [])
    flip.send("first")
    flip.say("partial")
    flip.reload(draftFlip: true)
    check("\(n): the draft→session flip mid-first-turn reads nothing and draws the turn once",
          flip.cache == nil && flip.page == ["you first", "agent partial"], show(flip.page))
    let failed = Session(agent, .shipped, earlier: [])
    failed.send("first")
    failed.fail("No connection")
    failed.reload(draftFlip: true)
    check("\(n): …nor for a first turn that already failed: its error row stays",
          failed.cache == nil && failed.page == ["you first", "error No connection"], show(failed.page))

    // A turn that ended before the return.
    let ended = page(.shipped) { s in
        s.reload(); s.send("follow-up"); s.say("done"); s.end()
        s.detour(); s.reload()
    }
    check("\(n): the turn ended before coming back — whole, once",
          ended == earlierRows() + ["you follow-up", "agent done"], show(ended))

    // "Show earlier".
    let earlierAfterTurn: (Session) -> Void = { s in
        s.reload(); s.send("follow-up"); s.say("done"); s.end()
        s.showEarlier()
    }
    let shownEarlier = page(.shipped, earlierAfterTurn)
    check("\(n): \"Show earlier\" after a turn sent from the page — each turn once",
          shownEarlier == earlierRows() + ["you follow-up", "agent done"], show(shownEarlier))
    check("\(n): (control) before the fix that turn was drawn twice",
          occurrences("you follow-up", page(.beforeTheFix, earlierAfterTurn)) == 2)
    let earlierMidTurn: (Session) -> Void = { s in
        s.reload()
        s.send("first follow-up"); s.say("first answer"); s.end()
        s.send("second follow-up"); s.say("second, under way")
        s.showEarlier()
    }
    let shownMidTurn = page(.shipped, earlierMidTurn)
    check("\(n): \"Show earlier\" while a later turn runs — each turn once",
          shownMidTurn == both, show(shownMidTurn))
    check("\(n): (control) before the fix the finished turn was drawn twice",
          occurrences("you first follow-up", page(.beforeTheFix, earlierMidTurn)) == 2)

    // The cache's copy first, the file after.
    let cached = Session(agent, .shipped)
    cached.reload()
    cached.send("first follow-up"); cached.say("first answer"); cached.end()
    cached.send("second follow-up"); cached.say("second, under way")
    cached.detour()
    let follows = cached.openFromCache()
    check("\(n): the history cache's copy, which predates both follow-ups, meets the buffer exactly",
          follows && cached.page == both, show(cached.page))
    cached.landRead()
    check("\(n): …and so does the read of the file that follows it",
          cached.page == both, show(cached.page))

    // A row in the user column that opens no turn, inside the running turn.
    let aside = page(.shipped) { s in
        s.reload()
        s.send("follow-up"); s.say("step one"); s.aside(); s.say("step two")
        s.detour(); s.reload()
    }
    let asideRow = label(agent.asideEvent())!
    check("\(n): a notice or a steered answer inside the running turn does not move the cut",
          aside == earlierRows() + ["you follow-up", "agent step one", asideRow, "agent step two"],
          show(aside))

    // The readers' spellings.
    let tagged = page(.shipped) { s in
        s.reload(); s.send("Use Vec<String> here"); s.say("on it")
        s.detour(); s.reload()
    }
    check("\(n): a message with a bare <…> is found in the reader's spelling",
          tagged.prefix(6) == ArraySlice(earlierRows()) && tagged.count == 8, show(tagged))
    let scheduled = page(.shipped) { s in
        s.reload(); s.send("<scheduled-task name=\"daily\"></scheduled-task>\nRun the report"); s.say("on it")
        s.detour(); s.reload()
    }
    check("\(n): a scheduled run's message is found without its marker",
          scheduled == earlierRows() + ["you Run the report", "agent on it"], show(scheduled))

    // The same words as the turn before.
    let repeated = page(.shipped, earlier: ["question 1", "question 2", "continue"]) { s in
        s.reload(); s.send("continue"); s.say("partial")
        s.detour(); s.reload()
    }
    check("\(n): a message repeating the one before it — settled once the file is read",
          repeated == ["you question 1", "agent answer 1", "you question 2", "agent answer 2",
                       "you continue", "agent answer 3", "you continue", "agent partial"],
          show(repeated))

    // A read that lands after the turn it began under has ended.
    let race: (Session) -> Void = { s in
        s.reload()
        s.send("follow-up"); s.say("working on it")
        s.otherSession()           // a route that reads, with the fix and without
        s.openFromCache()          // the cache's copy, at once
        let pending = s.beginRead()
        s.say("final answer"); s.end()
        s.land(pending)
    }
    let raced = page(.shipped, race)
    check("\(n): a read that began during the turn and lands after it ended is taken again — the turn's end stays",
          raced == followUp + ["agent final answer"], show(raced))
    let racedBefore = page(.beforeTheFix, race)
    check("\(n): (control) landed as it was, the read drops the turn's end with the live buffer",
          !racedBefore.contains("agent final answer") && racedBefore.prefix(6) == ArraySlice(earlierRows()),
          show(racedBefore))

    // The front trim cut the running turn's message away.
    let trimmed = Session(agent, .shipped)
    trimmed.reload()
    trimmed.send("follow-up"); trimmed.say("step one"); trimmed.say("step two")
    trimmed.trimFront(2)
    trimmed.detour()
    trimmed.reload()
    let wanted = earlierRows() + ["you follow-up", "agent step one", "agent step two"]
    check("\(n): a running turn whose start the buffer lost is drawn from the read — nothing lost, part of it twice rather than its middle missing",
          wanted.allSatisfy { trimmed.page.contains($0) } && trimmed.page.prefix(6) == ArraySlice(earlierRows()),
          show(trimmed.page))
}

// MARK: - 3. The window drawn

section("3. The window drawn over the read and the live buffer")

/// The page the window draws, by place: "▲" for a "Show earlier" row, `hN`
/// for the read's row N, `bN` for the live buffer's.
func page(h: Int, b: Int, _ w: TranscriptSeam.Window) -> [String] {
    (w.top > 0 ? ["▲"] : [])
        + (max(0, h - w.historyShown)..<h).map { "h\($0)" }
        + (max(0, b - w.liveShown)..<b).map { "b\($0)" }
}
/// The two windows this replaced: the read's newest 40 rows, then the live
/// buffer's newest 150, each with its own "Show earlier" above it.
func pageBeforeTheFix(h: Int, b: Int) -> [String] {
    (h > 40 ? ["▲"] : []) + (max(0, h - 40)..<h).map { "h\($0)" }
        + (b > 150 ? ["▲"] : []) + (max(0, b - 150)..<b).map { "b\($0)" }
}
/// Every row drawn is one run back from the newest, and "Show earlier" can
/// only stand above it.
func contiguous(_ rows: [String], h: Int, b: Int) -> Bool {
    let drawn = rows.filter { $0 != "▲" }
    let all = (0..<h).map { "h\($0)" } + (0..<b).map { "b\($0)" }
    return Array(all.suffix(drawn.count)) == drawn
        && !rows.dropFirst().contains("▲")
}

let longTurn = pageBeforeTheFix(h: 120, b: 220)
check("(control) the two stacked windows: a long turn puts \"Show earlier\" in the middle, earlier turns above it",
      longTurn.firstIndex(of: "h119").map { longTurn[$0 + 1] == "▲" } == true
      && !contiguous(longTurn, h: 120, b: 220))

var everyShapeContiguous = true
for h in [0, 10, 40, 120, 600] {
    for b in [0, 1, 100, 150, 151, 190, 400, 1000] {
        for earlier in [40, 240, 440] {
            for held: Int? in [nil, 0, 50, h + b / 2, h + b] {
                let w = TranscriptSeam.window(historyCount: h, liveCount: b,
                                              earlierRows: earlier, heldTop: held)
                if !contiguous(page(h: h, b: b, w), h: h, b: b)
                    || w.historyShown + w.liveShown != h + b - w.top {
                    everyShapeContiguous = false
                }
            }
        }
    }
}
check("window: one run of rows back from the newest, \"Show earlier\" only above it — every shape tried",
      everyShapeContiguous)

let atOpen = TranscriptSeam.window(historyCount: 120, liveCount: 0, earlierRows: 40, heldTop: nil)
let shortTurn = TranscriptSeam.window(historyCount: 120, liveCount: 150, earlierRows: 40, heldTop: nil)
check("…unchanged until a turn outgrows the live cap: the read's newest 40 at open, every live row of a turn up to 150 below them",
      atOpen.historyShown == 40 && atOpen.liveShown == 0
      && shortTurn.historyShown == 40 && shortTurn.liveShown == 150)
let long = TranscriptSeam.window(historyCount: 120, liveCount: 220, earlierRows: 40, heldTop: nil)
check("…a longer turn: the newest 190 rows, its oldest rows and the earlier turns above them behind \"Show earlier\"",
      long.liveShown == 190 && long.historyShown == 0 && long.top == 150)

// A reader away from the end while the turn streams.
var streaming = 220
let capture = TranscriptSeam.window(historyCount: 120, liveCount: streaming,
                                    earlierRows: 40, heldTop: nil).top
var heldStill = true
for _ in 0..<TranscriptSeam.heldGrowth {
    streaming += 1
    let w = TranscriptSeam.window(historyCount: 120, liveCount: streaming, earlierRows: 40, heldTop: capture)
    if w.top != capture { heldStill = false }
}
check("held: the first row drawn stays put while \(TranscriptSeam.heldGrowth) more rows stream in below — nothing moves under the reader",
      heldStill)
streaming += 1
let past = TranscriptSeam.window(historyCount: 120, liveCount: streaming, earlierRows: 40, heldTop: capture)
check("…and past that the window slides again, \(TranscriptSeam.heldGrowth) rows larger than at the end and no more",
      past.top == capture + 1 && past.liveShown == 190 + TranscriptSeam.heldGrowth)
let released = TranscriptSeam.window(historyCount: 120, liveCount: streaming, earlierRows: 40, heldTop: nil)
check("…back at the end it is the sliding window again",
      released.liveShown == 190 && released.top == 120 + streaming - 190)
let deeper = TranscriptSeam.window(historyCount: 120, liveCount: 300, earlierRows: 40, heldTop: 280)
check("…a hold never draws fewer rows than following the end would",
      deeper.top == 120 + 300 - 190)

// "Show earlier" pressed while held: the view holds the window at the new top.
let beforeClick = TranscriptSeam.window(historyCount: 120, liveCount: 400, earlierRows: 40, heldTop: 330)
let afterClick = TranscriptSeam.window(historyCount: 120, liveCount: 400, earlierRows: 240, heldTop: nil).top
var clickHeld = afterClick == beforeClick.top - 200
for more in 1...150 {
    let w = TranscriptSeam.window(historyCount: 120, liveCount: 400 + more, earlierRows: 240, heldTop: afterClick)
    if w.top != afterClick { clickHeld = false }
}
check("\"Show earlier\" while held reveals 200 rows above and holds there while the turn streams",
      clickHeld)

check("holdChange: a reader who leaves the end holds the window",
      TranscriptSeam.holdChange(following: false, distanceFromEnd: 400, heldRowOnPage: false) == .hold)
check("…and with nothing held yet; a held row stays held (the view keeps its place across a read: heldIndex)",
      TranscriptSeam.holdChange(following: false, distanceFromEnd: 400, heldRowOnPage: false) == .hold
      && TranscriptSeam.holdChange(following: false, distanceFromEnd: 400, heldRowOnPage: true) == .none)
check("…lets it go only AT the end, not on the way down nor inside the follow slack",
      TranscriptSeam.holdChange(following: true, distanceFromEnd: 0, heldRowOnPage: true) == .letGo
      && TranscriptSeam.holdChange(following: true, distanceFromEnd: 80, heldRowOnPage: true) == .none
      && TranscriptSeam.holdChange(following: true, distanceFromEnd: 0, heldRowOnPage: false) == .none)

// A read landing while the window is held: every history row's id is minted
// per parse, so afterwards the held row's id names nothing. Its distance from
// the newest row still names it — a read changes the rows ABOVE it.
check("heldIndex: the held row by its id while that names a row",
      TranscriptSeam.heldIndex(resolved: 7, fromEnd: 3, rowCount: 100) == 7)
check("…else by its distance from the newest row, bounded to the rows there are; nothing held, nothing",
      TranscriptSeam.heldIndex(resolved: nil, fromEnd: 40, rowCount: 100) == 60
      && TranscriptSeam.heldIndex(resolved: nil, fromEnd: 500, rowCount: 100) == 0
      && TranscriptSeam.heldIndex(resolved: nil, fromEnd: nil, rowCount: 100) == nil)
// Held at row 130 of 120 + 300 while the turn streams; a wider read lands 250
// rows above, every history id new.
let heldAt = 130
let heldBefore = TranscriptSeam.window(historyCount: 120, liveCount: 300, earlierRows: 40, heldTop: heldAt)
let keptPlace = TranscriptSeam.heldIndex(resolved: nil, fromEnd: 420 - heldAt, rowCount: 670)
let heldAfter = TranscriptSeam.window(historyCount: 370, liveCount: 300, earlierRows: 40, heldTop: keptPlace)
check("a read landing while held — the window stays on the held row, the rows above the reader with it",
      heldBefore.top == heldAt && heldAfter.top == heldAt + 250)
let heldLost = TranscriptSeam.window(historyCount: 370, liveCount: 300, earlierRows: 40, heldTop: nil)
check("(control) the hold lost with the id, the window slides down and takes them",
      heldLost.top > heldAt + 250)

// "Show earlier" on a held window that has grown — 200 rows streamed since the
// hold, 50 rows hidden above it — counts its 200 from the first row drawn.
check("earlierRows after \"Show earlier\": 200 more where the window slides, and where everything is drawn",
      TranscriptSeam.earlierRowsAfterShowEarlier(top: 230, earlierRows: 40, historyCount: 120, liveCount: 300) == 240
      && TranscriptSeam.earlierRowsAfterShowEarlier(top: 0, earlierRows: 240, historyCount: 100, liveCount: 50) == 440)
var rebaseIsOldCount = true
for h in [0, 10, 40, 120, 600] {
    for b in [0, 1, 100, 150, 151, 190, 400, 1000] {
        for earlier in [40, 240, 440] {
            let w = TranscriptSeam.window(historyCount: h, liveCount: b, earlierRows: earlier, heldTop: nil)
            if TranscriptSeam.earlierRowsAfterShowEarlier(top: w.top, earlierRows: earlier,
                                                          historyCount: h, liveCount: b) != earlier + 200 {
                rebaseIsOldCount = false
            }
        }
    }
}
check("…and exactly the old count plus 200 wherever the window slides or everything is drawn — every shape tried",
      rebaseIsOldCount)
let grown = TranscriptSeam.window(historyCount: 120, liveCount: 320, earlierRows: 40, heldTop: 50)
let rebased = TranscriptSeam.earlierRowsAfterShowEarlier(top: grown.top, earlierRows: 40,
                                                         historyCount: 120, liveCount: 320)
// The click holds at row 0 (50 above the top is nothing loaded): 440 rows from
// the end. A wider read then lands 300 rows above, every history id new.
let heldAtZero = TranscriptSeam.heldIndex(resolved: nil, fromEnd: 440, rowCount: 740)
let landed = TranscriptSeam.window(historyCount: 420, liveCount: 320, earlierRows: rebased, heldTop: heldAtZero)
check("…on a held window that has grown it reveals 200 above the first row drawn once the wider read lands",
      grown.top == 50 && landed.top == 300 + 50 - 200)
let addedToCount = TranscriptSeam.window(historyCount: 420, liveCount: 320, earlierRows: 240, heldTop: heldAtZero)
check("(control) 200 added to the old count: the growth eats the reveal, the rows the read landed stay hidden",
      addedToCount.top == 300)
let undone = TranscriptSeam.window(historyCount: 420, liveCount: 320, earlierRows: 240, heldTop: nil)
check("(control) …and with the hold lost to the read, its landing takes back what the click revealed",
      undone.top == 300 + 50)

// Compact view: the window counts DRAWN rows. A folded answer is its
// message, ONE line holding every step (its first member drawn, the rest
// not), and its last words.
func foldedTranscript(answers: Int, steps: Int) -> [Bool] {
    (0..<answers).flatMap { _ in [true, true] + Array(repeating: false, count: steps - 1) + [true] }
}
let folded = foldedTranscript(answers: 100, steps: 20)
let foldedOpen = TranscriptSeam.window(historyCount: folded.count, liveCount: 0, earlierRows: 40,
                                       heldTop: nil, draws: { folded[$0] })
let foldedShown = TranscriptSeam.drawnCount(foldedOpen.top..<folded.count) { folded[$0] }
check("compact view: at open the window draws 40 DRAWN rows — thirteen answers and more, each its message, its line and its last words",
      foldedShown == 40 && folded.count - foldedOpen.top >= 13 * 22,
      "\(foldedShown) drawn in \(folded.count - foldedOpen.top) rows")
let foldedRaw = TranscriptSeam.window(historyCount: folded.count, liveCount: 0, earlierRows: 40, heldTop: nil)
check("(control) counted as rows, the same window holds under two answers, and a line straddles its top",
      folded.count - foldedRaw.top == 40 && !folded[foldedRaw.top])
var topIsDrawn = true
var allDrawnIsRaw = true
for h in [0, 10, 40, 120, 600] {
    for b in [0, 1, 100, 150, 151, 190, 400] {
        let marks = foldedTranscript(answers: (h + b) / 22 + 1, steps: 20).prefix(h + b).map { $0 }
        for earlier in [0, 40, 240] {
            for held: Int? in [nil, 0, 50, h + b / 2] {
                let w = TranscriptSeam.window(historyCount: h, liveCount: b, earlierRows: earlier,
                                              heldTop: held, draws: { marks[$0] })
                if w.top < h + b, held == nil, !marks[w.top] { topIsDrawn = false }
                let raw = TranscriptSeam.window(historyCount: h, liveCount: b, earlierRows: earlier, heldTop: held)
                let every = TranscriptSeam.window(historyCount: h, liveCount: b, earlierRows: earlier,
                                                  heldTop: held, draws: { _ in true })
                if raw != every { allDrawnIsRaw = false }
            }
        }
    }
}
check("…the first row a sliding compact window draws is always a drawn row: a line is never cut in two",
      topIsDrawn)
check("…and where every row is drawn, counting drawn rows IS counting rows — every shape tried",
      allDrawnIsRaw)
var compactStream = folded.count
let compactCapture = TranscriptSeam.window(historyCount: folded.count, liveCount: 0, earlierRows: 40,
                                           heldTop: nil, draws: { folded[$0] }).top
// Three drawn rows an answer: enough answers to stream past the hold's growth.
let streamMarks = folded + foldedTranscript(answers: TranscriptSeam.heldGrowth, steps: 20)
var compactHeld = true
var drawnSince = 0
while drawnSince < TranscriptSeam.heldGrowth {
    if streamMarks[compactStream] { drawnSince += 1 }
    compactStream += 1
    let w = TranscriptSeam.window(historyCount: folded.count, liveCount: compactStream - folded.count,
                                  earlierRows: 40, heldTop: compactCapture, draws: { streamMarks[$0] })
    if w.top != compactCapture { compactHeld = false }
}
check("held in compact view: the first row drawn stays put while \(TranscriptSeam.heldGrowth) more drawn rows stream in",
      compactHeld)
check("the start of a run holding N drawn rows: none asked → the end, more asked than drawn → the first row",
      TranscriptSeam.start(holding: 0, before: 10, { _ in true }) == 10
      && TranscriptSeam.start(holding: 5, before: 10, { $0 % 2 == 0 }) == 0
      && TranscriptSeam.start(holding: 2, before: 10, { $0 % 2 == 0 }) == 6)

// A find jump into a folded line just above the window. The view grows the
// window through the line's FIRST member (`revealRows`): a line is drawn at
// that member, and not at all once every member is above the window. The
// window's first row is a drawn row, which can be an answer's last words —
// its line then sits wholly above the window — and grown to a matched
// member of that line alone, with nothing drawn between it and the top,
// the window does not move: the jump would land on nothing.
let jumpMarks = foldedTranscript(answers: 60, steps: 20)
let jumpOpen = TranscriptSeam.window(historyCount: jumpMarks.count, liveCount: 0, earlierRows: 40,
                                     heldTop: nil, draws: { jumpMarks[$0] })
// Forty drawn rows are thirteen answers and one more's last words: the top
// is that answer's last words; its message, its line's first member and
// nineteen folded members sit above the window.
let lineStart = jumpOpen.top - 20
let matched = lineStart + 10
check("compact view: the window opens on an answer's last words, its folded line wholly above the window",
      jumpMarks[jumpOpen.top] && jumpMarks[lineStart - 1] && jumpMarks[lineStart] && !jumpMarks[matched]
      && (lineStart..<jumpOpen.top).allSatisfy { !jumpMarks[$0] || $0 == lineStart })
func grown(through: Int) -> Int {
    let newTop = max(0, through - 5)
    let more = TranscriptSeam.drawnCount(newTop..<jumpOpen.top) { jumpMarks[$0] }
    return TranscriptSeam.window(historyCount: jumpMarks.count, liveCount: 0, earlierRows: 40 + more,
                                 heldTop: nil, draws: { jumpMarks[$0] }).top
}
check("(control) grown through the matched member alone, the window does not move: nothing drawn lies between",
      grown(through: matched) == jumpOpen.top)
check("…grown through the line's first member, the whole answer is inside the window",
      grown(through: lineStart) <= lineStart - 1)

// MARK: - 4. The wiring

section("4. The wiring, read off the sources")

func source(_ path: String) -> String {
    (try? String(contentsOf: src.appendingPathComponent(path), encoding: .utf8)) ?? ""
}
/// The body of the first declaration whose text starts with `signature`,
/// braces matched. Empty when absent — every check below also asserts a
/// positive anchor, so a missing file cannot pass by being empty.
func body(_ text: String, _ signature: String) -> String {
    guard let start = text.range(of: signature),
          let open = text[start.upperBound...].firstIndex(of: "{") else { return "" }
    var depth = 0
    var i = open
    while i < text.endIndex {
        if text[i] == "{" { depth += 1 }
        if text[i] == "}" { depth -= 1; if depth == 0 { return String(text[start.lowerBound...i]) } }
        i = text.index(after: i)
    }
    return ""
}
func squeeze(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

let view = source("SipAI/Views/Chat/AgentSessionView.swift")
let runner = source("SipAI/Models/AgentRunner.swift")
let reloadBody = squeeze(body(view, "private func reload(migratedFromDraft: Bool = false)"))
let loadBody = squeeze(body(view, "private func startHistoryLoad(url: URL"))
let widenBody = squeeze(body(view, "private func widenHistory(toBudget"))
let adoptBody = squeeze(body(view, "private func adoptHistory("))

check("reload asks the rule whether to read — only the draft→session flip may skip it",
      reloadBody.contains("TranscriptSeam.readsTranscript(draftFlip: migratedFromDraft,"))
check("…and no longer skips because nothing from disk is on screen yet",
      !reloadBody.isEmpty && !reloadBody.contains("historicalItems.isEmpty, runner.status.isRunning"))
// The cache's copy as compact view now draws it: a read kept with it on
// loses its agent turns' thoughts when it is off since.
check("the history cache's copy lands through adoptHistory, as a copy that may predate the buffer",
      reloadBody.contains("adoptHistory(items, fromFile: false)")
        && reloadBody.contains(": cached.items"))
check("a read of the file lands through adoptHistory",
      loadBody.contains("adoptHistory(loaded.items, fromFile: true)"))
check("\"Show earlier\" lands through adoptHistory too",
      widenBody.contains("adoptHistory(items, fromFile: true)"))
check("adoptHistory applies the rule: the cut where the buffer still begins the running turn, then the buffer's verdict",
      adoptBody.contains("TranscriptSeam.cut(")
      && adoptBody.contains("runningTurnStart != nil")
      && adoptBody.contains("TranscriptSeam.liveBuffer(")
      && adoptBody.contains("clearEvents()")
      && adoptBody.contains("dropTurnsBeforeRunningTurn()"))
let rawLoad = body(view, "private func startHistoryLoad(url: URL")
if let stale = rawLoad.range(of: "TranscriptSeam.readIsStale(turnStartAtRead: turnAtRead,"),
   let store = rawLoad.range(of: "historyCache.store(") {
    check("a read of the file whose turn ended while it read is taken again, before it is cached",
          stale.lowerBound < store.lowerBound
          && loadBody.contains("let turnAtRead = currentRunner?.status.runningSince")
          && loadBody.contains("startHistoryLoad(url: url, viaSpinner: viaSpinner)"))
} else {
    check("a read of the file whose turn ended while it read is taken again, before it is cached", false)
}
check("…and so is \"Show earlier\"'s",
      widenBody.contains("let turnAtRead = currentRunner?.status.runningSince")
      && widenBody.contains("TranscriptSeam.readIsStale(turnStartAtRead: turnAtRead,")
      && widenBody.contains("widenHistory(toBudget: budget)"))
check("RunStatus says when the running turn began",
      squeeze(body(runner, "var runningSince: Date?")).contains("case .running(let startedAt) = self"))
check("no read empties the live buffer on its own, outside adoptHistory",
      !reloadBody.contains("clearEvents()") && !loadBody.contains("clearEvents()")
      && !widenBody.contains("clearEvents()"))
let assignments = view.components(separatedBy: "\n")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { $0.hasPrefix("historicalItems = ") }
check("a read is put on the page only through adoptHistory (else the page is emptied)",
      !assignments.isEmpty
      && assignments.allSatisfy { $0 == "historicalItems = []" || $0 == "historicalItems = cut.items" },
      assignments.joined(separator: " · "))
check("the cut it replaced is gone", !view.isEmpty && !view.contains("trimmedForInFlight"))

// `send` starts its turn through `startTurn`, which codex's own commands share.
let sendBody = runner.contains("startTurn(text: text, options: options, images: images, command: nil)")
    ? squeeze(body(runner, "private func startTurn(")) : ""
check("send remembers the message the running turn opened with, beside its text",
      sendBody.contains("runningTurnOpening = opening.id")
      && sendBody.contains("inFlightUserText = display"))
let startBody = squeeze(body(runner, "var runningTurnStart: Int?"))
check("runningTurnStart answers only while a turn of ours runs, by the rule",
      startBody.contains("status.isRunning")
      && startBody.contains("TranscriptSeam.runningTurnStart(in: events, opening: runningTurnOpening)"))
let dropBody = squeeze(body(runner, "func dropTurnsBeforeRunningTurn()"))
check("dropTurnsBeforeRunningTurn cuts the buffer back to the running turn, which then opens it",
      dropBody.contains("runningTurnStart")
      && dropBody.contains("events.removeFirst(")
      && dropBody.contains("trimmedHeadChatOnly = false"))
let stack = squeeze(body(view, "private var transcriptStack: some View"))
check("the live buffer's own \"Show earlier\" in the middle of the page is gone",
      !stack.isEmpty && !view.contains("older rows in this turn")
      && !view.contains("liveDisplayCap"))
check("the one \"Show earlier\" counts every row above the window, read and live — drawn rows in compact view",
      stack.contains("let window = transcriptWindow")
      && stack.contains("let older = rowsAbove(window)")
      && stack.contains("if older > 0 || historyHasMore {")
      && stack.contains("Show earlier — \\(older) older rows")
      && squeeze(body(view, "private func rowsAbove(")).contains("guard let draws = drawnRows else { return window.top }"))
check("both lists draw what the window says",
      squeeze(body(view, "private var displayedHistory:")).contains("historicalItems.suffix(transcriptWindow.historyShown)")
      && squeeze(body(view, "private var displayedEvents:")).contains("runner.events.suffix(transcriptWindow.liveShown)")
      && stack.contains("ForEach(displayedHistory)") && stack.contains("ForEach(displayedEvents)"))
/// The text strictly between the first `a` and the next `b` after it.
func between(_ text: String, _ a: String, _ b: String) -> String {
    guard let start = text.range(of: a),
          let end = text.range(of: b, range: start.upperBound..<text.endIndex) else { return "" }
    return String(text[start.upperBound..<end.lowerBound])
}
// One sample feeds the follow engine and the reading place
// (`ScrollSample`); the follow engine's calls inside it are the ones read.
let geometryHandler = between(view, ".onScrollGeometryChange(for: ScrollSample.self)",
                              ".onScrollPhaseChange {")
let phaseHandler = between(view, ".onScrollPhaseChange {", ".onAppear {")
let hold = squeeze(body(view, "private func syncWindowHold(_ geometry: TranscriptGeometry)"))
check("the window is held and let go by the rule, after every sample the follow engine takes",
      geometryHandler.contains("follow.geometryChanged(from: old.geometry, to: new.geometry)")
      && geometryHandler.contains("syncWindowHold(new.geometry)")
      && phaseHandler.contains("follow.phaseChanged(to: phase, geometry: geometry)")
      && phaseHandler.contains("syncWindowHold(geometry)")
      && hold.contains("TranscriptSeam.holdChange(following: follow.isNearBottom,")
      && hold.contains("case .hold: holdWindow(at: transcriptWindow.top)")
      && hold.contains("case .letGo: releaseHold()"))
check("the window takes the held row's place through heldIndex — its id, else its kept distance from the newest row",
      squeeze(body(view, "private var transcriptWindow: TranscriptSeam.Window")).contains("heldTop: heldIndex, draws: drawnRows)")
      && squeeze(body(view, "private var heldIndex: Int?"))
          .contains("TranscriptSeam.heldIndex(resolved: rowIndex(of: id), fromEnd: heldAnchor.fromEnd, rowCount: rowCount)"))
check("the hold keeps that distance beside the id — on every sample and every streamed row — and gives a row its id back after a read",
      hold.contains("case .none: if let held { holdWindow(at: held) }")
      && squeeze(body(view, "private func holdWindow(at index: Int)")).contains("heldAnchor.fromEnd = rowCount - index")
      && squeeze(between(view, ".onChange(of: runner.events.count) {", ".onChange(of: approvalsForRunner.count)"))
          .contains("heldAnchor.fromEnd = rowCount - i"))
check("\"Show earlier\" counts its 200 from the first row drawn, and it and a find's jump grow the window through the hold",
      stack.contains("showEarlierRows()")
      && squeeze(body(view, "private func showEarlierRows()")).contains("TranscriptSeam.earlierRowsAfterShowEarlier(top: top,")
      && squeeze(body(view, "private func showEarlierRows()")).contains("holdWindow(at: max(0, top - 200))")
      && squeeze(body(view, "private func revealRows(through index: Int)")).contains("holdWindow(at: newTop)")
      && squeeze(body(view, "private func jumpToActiveMatch(")).contains("revealRows(through: index)"))
let catalog = source("SipAI/Resources/Localizable.xcstrings")
check("the live window's string has left the catalog",
      !catalog.isEmpty && !catalog.contains("older rows in this turn"))
check("TranscriptSeam.swift is in the app target",
      source("SipAI.xcodeproj/project.pbxproj").contains("TranscriptSeam.swift in Sources"))

try? FileManager.default.removeItem(at: scratch)
print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
