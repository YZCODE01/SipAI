// A Claude Code turn that claude itself says FAILED ends failed.
//
// Claude ends every `-p` turn on a `result` event, and that event says
// how the turn went: `is_error`. A call the API refused, a connection
// that never opened, a login that failed — each ends on a result whose
// `subtype` is still "success", with `is_error: true` and claude's words
// in `result`; claude writes the same words as a message of its own just
// before it (`model: "<synthetic>"`, drawn as a system notice). A turn
// cut off at a limit ends on an error subtype (`error_max_turns`, …)
// whose words are only in `errors`, with no message before it. Either
// way claude then exits 1.
//
// SipAI ends the VISIBLE turn at `result` (the child may live on), so the
// turn's status is set there — and the scheduler reads nothing else: a
// `.done` with code 0 is recorded "done". Read `is_error` and a failed
// scheduled run was recorded "succeeded" under its own error.
//
// While a call fails, claude retries it by itself — ten times over about
// three minutes when the connection is down — and says nothing but one
// `system`/`api_retry` record per attempt on stdout: the attempt, the
// limit, the wait, the HTTP status and a category, never the error's
// words. Its terminal draws "API error · Retrying in 4s · attempt 3/10";
// SipAI draws the same line without the countdown in the row codex's and
// kimi's retries use, held until real output replaces it.
//
// One failure is not final. When a process starts on a session whose
// instruction files (a CLAUDE.md, a memory file) changed since the
// conversation's last copy, claude attaches each changed file again, whole.
// Its check for the model's limit counts that copy; its compaction before
// sending does not. Near the limit, the message is refused with "Prompt is
// too long" (`terminal_reason: "blocking_limit"`) before anything is sent,
// and no compaction is tried. Sent once more, the message finds the copy
// already in the conversation: claude compacts first, then answers.
// SipAI starts a process for every message, so it meets this after any
// edit to those files; claude's own terminal keeps one process and meets
// it only on a resume.
//
// The rules:
//  * the reader carries claude's verdict on the result event
//    (`StreamEvent.turnFailure`): the words in `result`, else in
//    `errors`; "" for a failure with no words; nil for a turn that went
//    through — a local command that is not available here
//    (`/status`) included, since claude does not call it a failure;
//  * the runner ends such a turn failed, with those words (the
//    agent-neutral sentence where there are none), so a scheduled run
//    records the error — but not a turn the user stopped: Stop is Stop;
//  * the failure is SAID once: claude's own message already carries an
//    API's refusal; a limit's words are on no row until SipAI draws one;
//  * a refusal before sending (`StreamEvent.refusedAsTooLong`) is sent
//    once more, as the same turn, when the session existed before the
//    message, nothing ran and no compaction was tried in the attempt —
//    and the message is drawn a second time, as claude records it;
//  * a reopened session draws a record claude wrote twice (the re-sent
//    message, rewritten with the same uuid when claude compacts right
//    before sending it) once.
//
// Section 4 RUNS the installed claude against the local fake endpoints in
// ../ChatOnlyMode and beside this file, and against a port nothing listens
// on, each under a throwaway home with a junk key: nothing reaches a
// provider and no token is spent.
//
// Nothing here is part of the app target: this directory sits outside
// SipAI/, so these files are never compiled into the product. The stubs
// are borrowed from ../KimiCode rather than copied.
//
//   ./run.sh

import Foundation
import Darwin

let fm = FileManager.default
var checks = 0
var failures = 0
func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    checks += 1
    print(cond ? "  PASS  \(label)" : "  FAIL  \(label) \(detail)")
    if !cond { failures += 1 }
}
func section(_ title: String) { print("\n\(title)") }
func note(_ text: String) { print("  note  \(text)") }

let harnessDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : fm.currentDirectoryPath
let sourceRoot = harnessDir + "/../.."
func read(_ rel: String) -> String {
    (try? String(contentsOfFile: sourceRoot + "/" + rel, encoding: .utf8)) ?? ""
}
func line(_ dict: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: dict), as: UTF8.self)
}

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sipai-claudeturnfailure-\(ProcessInfo.processInfo.processIdentifier)",
                            isDirectory: true)
try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
let cwd = scratch

func parse(_ s: String) -> [StreamEvent] { AgentEventParser.parse(line: s, fallbackCwd: cwd) }
func resultEvent(_ events: [StreamEvent]) -> StreamEvent? {
    events.first { if case .result = $0.kind { return true }; return false }
}
/// The result record claude writes, in the shape measured on 2.1.296.
func result(_ fields: [String: Any]) -> String {
    var base: [String: Any] = [
        "type": "result", "duration_ms": 2100, "duration_api_ms": 0, "num_turns": 1,
        "total_cost_usd": 0, "usage": ["input_tokens": 0, "output_tokens": 0],
        "modelUsage": [:], "permission_denials": [], "session_id": "s-harness",
        "uuid": "u-harness",
    ]
    for (k, v) in fields { base[k] = v }
    return line(base)
}

// ─────────────────────────────────────────────── 1. the reader

section("1. The reader: claude's verdict on the result event")

let refusedWords = "API Error: Connection refused — a firewall or proxy may be blocking it (ECONNREFUSED)"
let good = resultEvent(parse(result(["subtype": "success", "is_error": false, "result": "OK",
                                     "stop_reason": "end_turn", "terminal_reason": "completed"])))
check("a turn that went through: no failure", good != nil && good?.turnFailure == nil,
      "\(String(describing: good?.turnFailure))")

let refused = resultEvent(parse(result(["subtype": "success", "is_error": true,
                                        "result": refusedWords, "api_error_status": NSNull(),
                                        "stop_reason": "stop_sequence",
                                        "terminal_reason": "api_error"])))
check("an API error (subtype \"success\", is_error true): claude's words from `result`",
      refused?.turnFailure == refusedWords, "\(String(describing: refused?.turnFailure))")

let status400 = resultEvent(parse(result(["subtype": "success", "is_error": true,
                                          "result": "API Error: 400 example says 400",
                                          "api_error_status": 400,
                                          "terminal_reason": "api_error"])))
check("an API refusal with a status: the same", status400?.turnFailure == "API Error: 400 example says 400")

let maxTurns = resultEvent(parse(result(["subtype": "error_max_turns", "is_error": true,
                                         "errors": ["Reached maximum number of turns (1)"],
                                         "num_turns": 2, "terminal_reason": "max_turns"])))
check("a turn cut off at a limit (an error subtype): the words from `errors`",
      maxTurns?.turnFailure == "Reached maximum number of turns (1)",
      "\(String(describing: maxTurns?.turnFailure))")

let twoErrors = resultEvent(parse(result(["subtype": "error_during_execution", "is_error": true,
                                          "errors": ["first thing", "  ", "second thing"]])))
check("several errors: each on a line of its own, blank ones left out",
      twoErrors?.turnFailure == "first thing\nsecond thing",
      "\(String(describing: twoErrors?.turnFailure))")

let wordless = resultEvent(parse(result(["subtype": "error_during_execution", "is_error": true,
                                         "errors": []])))
check("a failure with no words: \"\" — failed, and the runner says so in its own sentence",
      wordless?.turnFailure == "", "\(String(describing: wordless?.turnFailure))")

let blankResult = resultEvent(parse(result(["subtype": "success", "is_error": true, "result": "  "])))
check("a blank `result` is no words either", blankResult?.turnFailure == "")

let localCommand = resultEvent(parse(result(["subtype": "success", "is_error": false,
                                             "result": "/status isn't available in this environment.",
                                             "num_turns": 0])))
check("a local command that is not available here: not a failure — claude does not call it one",
      localCommand != nil && localCommand?.turnFailure == nil)

let nullFlag = resultEvent(parse(result(["subtype": "success", "is_error": NSNull(),
                                         "result": "OK"])))
check("`is_error: null` reads as absent, never as a failure", nullFlag?.turnFailure == nil)

let assistant = parse(line(["type": "assistant",
                            "message": ["model": "<synthetic>",
                                        "content": [["type": "text", "text": refusedWords]]]]))
check("claude's own message carrying the words is a system notice, and carries no verdict",
      assistant.count == 1 && assistant[0].isSystemNotice && assistant[0].turnFailure == nil)

// ───────────────────────────────────────────── 2. said once

section("2. Said once: a row of SipAI's own only where the newest row does not say the words")

let userRow = StreamEvent(kind: .userMessage(text: "Reply with OK."))
let notice = StreamEvent(kind: .userMessage(text: refusedWords), isSystemNotice: true)
let toolUse = StreamEvent(kind: .toolUse(toolUseId: "t1", name: "Bash", input: [:]))
let toolResult = StreamEvent(kind: .toolResult(toolUseId: "t1", output: "hi", isError: false))
func shown(_ words: String, _ rows: [StreamEvent]) -> Bool {
    AgentEventParser.failureIsShown(words, before: rows[...])
}
check("claude's own message just above says them: already said",
      shown(refusedWords, [userRow, notice]))
check("… white space around either side aside",
      shown(refusedWords + "\n", [userRow, StreamEvent(kind: .userMessage(text: "  " + refusedWords),
                                                       isSystemNotice: true)]))
check("an error row of the same words just above: already said",
      shown("Limit", [userRow, StreamEvent(kind: .error(message: "Limit"))]))
check("a turn cut off after a tool call: nothing says it",
      !shown("Reached maximum number of turns (1)", [userRow, toolUse, toolResult]))
check("a notice in other words: not said",
      !shown(refusedWords, [userRow, StreamEvent(kind: .userMessage(text: "Something else"),
                                                 isSystemNotice: true)]))
check("the user's own message in those words is not the agent saying them",
      !shown("Reply with OK.", [userRow]))
check("the words on an EARLIER row only: not said — the newest row is what is read",
      !shown(refusedWords, [notice, toolUse]))
check("nothing before the result: not said", !shown(refusedWords, []))

// ───────────────────────────────────────────── 2b. the retry line

section("2b. The retry line: claude retrying a call by itself, in its terminal's words without the countdown")

func retryRecord(_ fields: [String: Any]) -> String {
    var base: [String: Any] = ["type": "system", "subtype": "api_retry", "attempt": 2,
                               "max_retries": 10, "retry_delay_ms": 1167,
                               "error_status": NSNull(), "error": "unknown",
                               "session_id": "s-harness", "uuid": "u-harness"]
    for (k, v) in fields { base[k] = v }
    return line(base)
}
check("a refused connection's retry: claude's label and the attempt",
      AgentEventParser.retryNotice(line: retryRecord([:])) == "API error · Retrying · attempt 2/10",
      "\(String(describing: AgentEventParser.retryNotice(line: retryRecord([:]))))")
check("a server error's: the same words — claude's terminal shows no status in them",
      AgentEventParser.retryNotice(line: retryRecord(["attempt": 1, "error_status": 500,
                                                      "error": "server_error"]))
        == "API error · Retrying · attempt 1/10")
check("the record spelled with spaces is read the same",
      AgentEventParser.retryNotice(line: "{\"type\": \"system\", \"subtype\": \"api_retry\", "
                                   + "\"attempt\": 3, \"max_retries\": 10}")
        == "API error · Retrying · attempt 3/10")
check("a retry record without its counters is no line",
      AgentEventParser.retryNotice(line: line(["type": "system", "subtype": "api_retry"])) == nil)
check("no other record is a retry: init, status, a message that names it",
      AgentEventParser.retryNotice(line: line(["type": "system", "subtype": "init",
                                               "session_id": "s", "model": "m"])) == nil
        && AgentEventParser.retryNotice(line: line(["type": "system", "subtype": "status",
                                                    "status": NSNull()])) == nil
        && AgentEventParser.retryNotice(line: line(["type": "assistant", "message": [
            "content": [["type": "text", "text": "\"subtype\":\"api_retry\""]]]])) == nil)
check("the parse turns a retry into no event, so it can never stack rows",
      parse(retryRecord([:])).isEmpty)

// ─────────────────────── 2c. refused as too long, before sending

section("2c. Refused as too long before sending: the reader, and the rule that sends the message once more")

let tooLong = resultEvent(parse(result(["subtype": "success", "is_error": true,
                                        "result": "Prompt is too long",
                                        "stop_reason": "stop_sequence",
                                        "terminal_reason": "blocking_limit"])))
check("claude's own refusal before sending (`terminal_reason: \"blocking_limit\"`): read as one",
      tooLong?.refusedAsTooLong == true)
check("… and still a failure in claude's words, for when it is not sent again",
      tooLong?.turnFailure == "Prompt is too long")
let apiTooLong = resultEvent(parse(result(["subtype": "success", "is_error": true,
                                           "result": "Prompt is too long",
                                           "terminal_reason": "api_error"])))
check("the API's own prompt-too-long refusal is not one — claude compacts by itself after that",
      apiTooLong != nil && apiTooLong?.refusedAsTooLong == false)
check("a turn that went through is not one", good?.refusedAsTooLong == false)
check("the reason on a turn claude does not call failed is not one",
      resultEvent(parse(result(["subtype": "success", "is_error": false, "result": "OK",
                                "terminal_reason": "blocking_limit"])))?.refusedAsTooLong == false)

let initEvent = StreamEvent(kind: .systemInit(sessionId: "s-harness", model: "m", cwd: "/"))
let tooLongNotice = StreamEvent(kind: .userMessage(text: "Prompt is too long"), isSystemNotice: true)
func resends(_ attempt: [StreamEvent], result: StreamEvent? = tooLong, resumed: Bool = true,
             compactionTried: Bool = false, alreadyResent: Bool = false,
             stopped: Bool = false) -> Bool {
    guard let result else { return false }
    return AgentEventParser.resendsTooLongRefusal(result, attempt: attempt[...],
                                                  resumedSession: resumed,
                                                  compactionTried: compactionTried,
                                                  alreadyResent: alreadyResent,
                                                  stopped: stopped)
}
check("refused before anything ran, in a session that already existed: sent once more",
      resends([initEvent, tooLongNotice]))
check("… a row of SipAI's own in the attempt (a skill it could not load) changes nothing",
      resends([initEvent, StreamEvent(kind: .error(message: "A skill could not be loaded.")), tooLongNotice]))
check("a new session's own message: not sent again — compacting cannot make it smaller",
      !resends([initEvent, tooLongNotice], resumed: false))
check("claude tried to compact in the attempt: not sent again — it would be refused the same way",
      !resends([initEvent, tooLongNotice], compactionTried: true))
check("a compaction row in the attempt: not sent again",
      !resends([initEvent, StreamEvent(kind: .compaction(preTokens: 900_000, postTokens: 9_000)),
                tooLongNotice]))
check("a tool call ran: never sent again — a re-send would repeat its work",
      !resends([initEvent, toolUse, toolResult, tooLongNotice]))
check("the model said something: never sent again",
      !resends([initEvent, StreamEvent(kind: .assistantText(text: "Working on it.")), tooLongNotice]))
check("once per message", !resends([initEvent, tooLongNotice], alreadyResent: true))
check("never after Stop", !resends([initEvent, tooLongNotice], stopped: true))
check("any other failure: not sent again", !resends([initEvent, notice], result: refused))
check("the API's own prompt-too-long refusal: not sent again",
      !resends([initEvent, tooLongNotice], result: apiTooLong))

// ─────────────────────────────────────── 3. the runner and the scheduler

section("3. The runner ends the turn failed; the scheduler records it")

let runner = read("SipAI/Models/AgentRunner.swift")
let scheduler = read("SipAI/Models/ScheduledTaskScheduler.swift")
check("the sources are read", !runner.isEmpty && !scheduler.isEmpty)
func body(of signature: String, in source: String) -> String {
    guard let start = source.range(of: signature) else { return "" }
    let rest = source[start.lowerBound...]
    guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
    return String(rest[..<end.upperBound])
}
let endSegment = body(of: "private func endTurnSegment(", in: runner)
check("the visible turn's end takes the failure",
      endSegment.contains("private func endTurnSegment(failure: String? = nil)"))
check("… and ends a failed turn on a failing code, with its words",
      endSegment.contains("setStatus(.done(exitCode: failure == nil ? 0 : -1, errorMessage: failure))"))

let apply = body(of: "private func apply(_ parsed: [StreamEvent])", in: runner)
check("the result's verdict reaches the turn's end — not after Stop",
      apply.contains("let failure = stopRequested ? nil : event.turnFailure.map {")
      && apply.contains("endTurnSegment(failure: failure)"))
check("a failure with no words is said in the agent-neutral sentence",
      apply.contains("AgentAskingMode.wordlessFailureMessage(agentName: agentDisplayName)"))
check("the failure is drawn only where nothing above already says it",
      apply.contains("AgentEventParser.failureIsShown(failure, before: events.dropLast())")
      && apply.contains("events.append(StreamEvent(kind: .error(message: failure)))"))
if let skip = apply.range(of: "pendingSkillLoadResults -= 1"),
   let verdict = apply.range(of: "event.turnFailure") {
    check("a skill load's own empty result is passed over before any verdict is read",
          skip.lowerBound < verdict.lowerBound)
} else {
    check("a skill load's own empty result is passed over before any verdict is read", false)
}
let claudeBranch: String = {
    guard let start = runner.range(of: "private func handleStdoutLine("),
          let branch = runner.range(of: "\n        case \"claude_code\":\n", range: start.upperBound..<runner.endIndex),
          let end = runner.range(of: "\n        default:\n", range: branch.upperBound..<runner.endIndex)
    else { return "" }
    return String(runner[branch.lowerBound..<end.lowerBound])
}()
check("claude's stdout sets the retry line from each retry record, after the parse",
      claudeBranch.contains("if let notice = AgentEventParser.retryNotice(line: line) {\n                retryNotice = notice")
        && (claudeBranch.range(of: "parsed = AgentEventParser.parse(")?.lowerBound ?? claudeBranch.endIndex)
            < (claudeBranch.range(of: "AgentEventParser.retryNotice(line: line)")?.lowerBound ?? claudeBranch.startIndex))
check("… and any real output takes it down, as codex's and kimi's",
      claudeBranch.contains("} else if !parsed.isEmpty {\n                retryNotice = \"\""))
check("the scheduler records a run by the code and words the turn ended on",
      scheduler.contains("state.lastOutcome = code == 0 ? \"done\" : \"error\"")
      && scheduler.contains("state.lastError = code == 0 ? nil"))

// ───────────── 3b. a refusal before sending, sent once more by the runner

section("3b. The runner sends a message refused as too long once more, as the same turn")

/// Where `needle` sits in `source`, or nil.
func position(_ needle: String, in source: String) -> String.Index? {
    source.range(of: needle)?.lowerBound
}
let resultBranch: String = {
    guard let start = apply.range(of: "if case .result = event.kind {") else { return "" }
    return String(apply[start.lowerBound...])
}()
check("at a result, the rule is asked with the attempt's facts",
      resultBranch.contains("AgentEventParser.resendsTooLongRefusal(")
      && resultBranch.contains("resumedSession: turnResumedSession")
      && resultBranch.contains("compactionTried: attemptTriedCompaction")
      && resultBranch.contains("alreadyResent: tooLongResendUsed")
      && resultBranch.contains("stopped: stopRequested"))
if let ask = position("AgentEventParser.resendsTooLongRefusal(", in: resultBranch),
   let stamp = position("stampTurnDuration()", in: resultBranch),
   let end = position("endTurnSegment(failure: failure)", in: resultBranch),
   let pending = position("tooLongResendPending = true", in: resultBranch) {
    check("… before the clock is stamped and the turn ended: a refused attempt does neither",
          ask < stamp && ask < end && pending < stamp)
} else {
    check("… before the clock is stamped and the turn ended: a refused attempt does neither", false)
}
let runOnceBody = body(of: "private func runOnce(text: String, options: AgentLaunchOptions,", in: runner)
if let resend = position("if tooLongResendPending {", in: runOnceBody),
   let join = position("await group.waitForAll()", in: runOnceBody),
   let finalize = position("finalizeTurn(token: token, exitCode: exitCode, errorMessage: errText)", in: runOnceBody) {
    check("the message goes again once the refused child has gone — after the join, before the turn's finalize",
          join < resend && resend < finalize)
} else {
    check("the message goes again once the refused child has gone — after the join, before the turn's finalize", false)
}
check("… through the same turn's next attempt",
      runOnceBody.contains("beginTooLongResend()")
      && runOnceBody.contains("await runOnce(text: text, options: again, images: images)"))
if let copy = position("var again = options", in: runOnceBody),
   let cleared = position("again.claudeResumeAt = nil", in: runOnceBody),
   let rerun = position("await runOnce(text: text, options: again, images: images)", in: runOnceBody) {
    check("… which does not go back to an edited message's entry a second time (4f)",
          copy < cleared && cleared < rerun)
} else {
    check("… which does not go back to an edited message's entry a second time (4f)", false)
}
let resendBody = body(of: "private func beginTooLongResend()", in: runner)
check("the second attempt is the message's last: once per message",
      resendBody.contains("tooLongResendUsed = true"))
check("… on a new run token, the refused attempt's bounds disarmed",
      resendBody.contains("runToken &+= 1") && resendBody.contains("disarmTurnEndWatchdog()"))
check("… with the message drawn a second time, as claude records it",
      resendBody.contains("events.append(StreamEvent(kind: row.kind"))
// `send` starts its turn through `startTurn`, which codex's own commands share.
let sendBody = runner.contains("startTurn(text: text, options: options, images: images, command: nil)")
    ? body(of: "private func startTurn(", in: runner) : ""
check("a new message: its own re-send, for a session that already existed",
      sendBody.contains("turnResumedSession = !(sessionId?.isEmpty ?? true)")
      && sendBody.contains("tooLongResendUsed = false")
      && sendBody.contains("tooLongResendPending = false"))
check("claude saying it is compacting marks the attempt",
      claudeBranch.contains("if flag { attemptTriedCompaction = true }"))
check("a refused child that lingers is reaped, as the next send would reap it",
      runner.contains("self.killChild(reason: \"a turn refused as too long, before its re-send\")"))

// ─────────────── 3c. a record claude wrote twice, read back once

section("3c. A reopened session draws the re-sent message once, though claude wrote its record twice")

/// The records of a session refused as too long and sent again, in the
/// shapes claude writes (measured on 2.1.296): the re-sent message's
/// user record is written a second time, with the same uuid, when claude
/// compacts right before sending it.
func readBack(_ records: [[String: Any]]) -> [AgentSessionHistoryItem] {
    let file = scratch.appendingPathComponent("transcript-\(UUID().uuidString.prefix(8)).jsonl")
    try? (records.map(line).joined(separator: "\n") + "\n")
        .write(to: file, atomically: true, encoding: .utf8)
    defer { try? fm.removeItem(at: file) }
    return AgentSessionScanner.readHistory(of: file)
}
func userMessage(_ uuid: String, _ text: String, extra: [String: Any] = [:]) -> [String: Any] {
    var record: [String: Any] = ["type": "user", "uuid": uuid, "sessionId": "s-harness",
                                 "message": ["role": "user", "content": text]]
    for (k, v) in extra { record[k] = v }
    return record
}
func assistantMessage(_ uuid: String, _ text: String, model: String = "claude-harness",
                      extra: [String: Any] = [:]) -> [String: Any] {
    var record: [String: Any] = ["type": "assistant", "uuid": uuid, "sessionId": "s-harness",
                                 "message": ["model": model, "role": "assistant",
                                             "content": [["type": "text", "text": text]]]]
    for (k, v) in extra { record[k] = v }
    return record
}
let asked = "Summarise the notes."
let sentAgain: [[String: Any]] = [
    userMessage("u-1", "First question"),
    assistantMessage("a-1", "First answer"),
    userMessage("u-2", asked),
    ["type": "attachment", "uuid": "t-1", "sessionId": "s-harness",
     "attachment": ["type": "instructions", "files": [], "changed": true, "reason": "session_start"]],
    assistantMessage("a-2", "Prompt is too long", model: "<synthetic>",
                     extra: ["isApiErrorMessage": true, "error": "invalid_request"]),
    userMessage("u-3", asked),
    userMessage("u-3", asked, extra: ["slug": "harness-slug"]),
    ["type": "system", "subtype": "compact_boundary", "uuid": "b-1", "sessionId": "s-harness",
     "content": "Conversation compacted",
     "compactMetadata": ["trigger": "auto", "preTokens": 999_245, "postTokens": 923]],
    userMessage("s-1", "This session is being continued from a previous conversation that ran out of context.",
                extra: ["isCompactSummary": true, "isVisibleInTranscriptOnly": true]),
    assistantMessage("a-3", "Here is the summary."),
]
/// One word per row, in order: what the user sees.
func rows(_ items: [AgentSessionHistoryItem]) -> [String] {
    items.map { item in
        switch item.kind {
        case .userText(let text): return item.isSystemNotice ? "notice: \(text.prefix(18))" : "you: \(text)"
        case .assistantText(let text): return "agent: \(text)"
        case .compaction: return "compacted"
        default: return "other"
        }
    }
}
let readRows = rows(readBack(sentAgain))
check("the message twice — the refused attempt and the re-send — never three times",
      readRows.filter { $0 == "you: \(asked)" }.count == 2, "\(readRows)")
check("… in the order the live transcript drew it: the message, claude's notice, the message, the compaction, the answer",
      readRows == ["you: First question", "agent: First answer", "you: \(asked)",
                   "notice: Prompt is too long", "you: \(asked)", "compacted",
                   "notice: This session is be", "agent: Here is the summary."],
      "\(readRows)")
check("two records with different ids and the same words stay two rows",
      rows(readBack([userMessage("u-1", "Again"), userMessage("u-2", "Again")])) == ["you: Again", "you: Again"])

// ───────────────────────────── 4. the installed claude, failing for real

section("4. The installed claude: a refused connection (retried twice), a limit, a good turn, a local command, a message refused as too long and sent again (token-free)")

let realHome = NSHomeDirectory()
let realClaude = [realHome + "/.local/bin/claude", "/opt/homebrew/bin/claude",
                  "/usr/local/bin/claude"]
    .first { fm.isExecutableFile(atPath: $0) }
let fakeServerScript = harnessDir + "/../ChatOnlyMode/fake_server.py"

func startFakeServer(recordDir: URL, extra: [String] = [],
                     script: String = fakeServerScript) -> (process: Process, port: Int)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [script, recordDir.path] + extra
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    var text = ""
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline, !text.contains("\n") {
        let chunk = out.fileHandleForReading.availableData
        if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.05); continue }
        text += String(decoding: chunk, as: UTF8.self)
    }
    guard let r = text.range(of: "PORT="),
          let port = Int(text[r.upperBound...].prefix { $0.isNumber }) else {
        p.terminate()
        return nil
    }
    return (p, port)
}

/// A loopback port nothing listens on: bound, read, closed.
func closedPort() -> Int? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
    }
    guard bound == 0 else { return nil }
    let named = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
    }
    guard named == 0 else { return nil }
    return Int(UInt16(bigEndian: addr.sin_port))
}

/// Run a child to completion (bounded), stdout captured through a file
/// so a chatty child cannot fill a pipe and stall.
func run(_ exe: String, _ args: [String], environment: [String: String], cwd: URL,
         timeout: TimeInterval = 90) -> (status: Int32, out: String) {
    let outFile = scratch.appendingPathComponent("out-\(UUID().uuidString.prefix(8))")
    fm.createFile(atPath: outFile.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: outFile) else { return (-1, "") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.environment = environment
    p.currentDirectoryURL = cwd
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = handle
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    if p.isRunning { p.terminate() }
    p.waitUntilExit()
    try? handle.close()
    let text = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
    try? fm.removeItem(at: outFile)
    return (p.terminationStatus, text)
}

struct ClaudeTurn {
    var status: Int32
    var events: [StreamEvent]
    /// The raw result record, for claude's own fields.
    var rawResult: [String: Any]?
    /// Every retry line the turn's stdout set, in order, and the line
    /// standing when it ended.
    var notices: [String]
    var finalNotice: String
    /// Every stdout line, for what the runner reads beside the parse.
    var lines: [String]
}

func claudeTurn(_ claude: String, prompt: String, port: Int, home: URL,
                extraArgs: [String] = [], retries: Int = 0) -> ClaudeTurn {
    let cfg = home.appendingPathComponent("cfg", isDirectory: true)
    let work = home.appendingPathComponent("work", isDirectory: true)
    try? fm.createDirectory(at: cfg, withIntermediateDirectories: true)
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)
    let linkDir = URL(fileURLWithPath: claude).deletingLastPathComponent().path
    let args = ["-p", prompt, "--output-format", "stream-json", "--verbose",
                "--model", "haiku"] + extraArgs
    let r = run(claude, args, environment: [
        "PATH": "\(linkDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "HOME": home.path,
        "CLAUDE_CONFIG_DIR": cfg.path,
        "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)",
        "ANTHROPIC_API_KEY": "sk-ant-harness-junk",
        // Claude retries a refused call ten times by default, with a
        // growing wait, before it gives up the same way; a turn here
        // asks for as many as it needs to see.
        "CLAUDE_CODE_MAX_RETRIES": String(retries),
        "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1",
    ], cwd: work)
    var events: [StreamEvent] = []
    var raw: [String: Any]?
    var notices: [String] = []
    var notice = ""
    let outLines = r.out.split(separator: "\n").map(String.init)
    for l in outLines {
        let parsed = parse(l)
        events += parsed
        // The runner's rule for the retry line, over the real stdout.
        if let n = AgentEventParser.retryNotice(line: l) {
            notice = n
            notices.append(n)
        } else if !parsed.isEmpty {
            notice = ""
        }
        if let data = l.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           (obj["type"] as? String) == "result" {
            raw = obj
        }
    }
    return ClaudeTurn(status: r.status, events: events, rawResult: raw,
                      notices: notices, finalNotice: notice, lines: outLines)
}

/// The events before the result, as the runner holds them when it reads
/// the verdict.
func before(_ turn: ClaudeTurn) -> [StreamEvent] {
    guard let i = turn.events.firstIndex(where: { if case .result = $0.kind { return true }; return false })
    else { return turn.events }
    return Array(turn.events[..<i])
}
func noticeText(_ e: StreamEvent?) -> String? {
    guard let e, e.isSystemNotice, case .userMessage(let t) = e.kind else { return nil }
    return t
}

if let claude = realClaude, fm.fileExists(atPath: fakeServerScript) {
    // (a) A refused connection — what a Mac with no network gets.
    if let port = closedPort() {
        let home = scratch.appendingPathComponent("homeA", isDirectory: true)
        let turn = claudeTurn(claude, prompt: "Reply with OK.", port: port, home: home, retries: 2)
        let words = (turn.rawResult?["result"] as? String) ?? ""
        note("claude said: \(words)")
        check("(a) claude calls the turn failed (`is_error`) and exits non-zero",
              (turn.rawResult?["is_error"] as? Bool) == true && turn.status != 0,
              "exit \(turn.status)")
        check("(a) the reader carries claude's words", resultEvent(turn.events)?.turnFailure == words
              && !words.isEmpty, "\(String(describing: resultEvent(turn.events)?.turnFailure))")
        check("(a) claude's own message just above already says them — drawn as a notice",
              noticeText(before(turn).last) == words, "\(String(describing: noticeText(before(turn).last)))")
        check("(a) so the runner's rule draws no second row",
              AgentEventParser.failureIsShown(words, before: before(turn)[...]))
        check("(a) each retry sets the line, attempt by attempt",
              turn.notices == ["API error · Retrying · attempt 1/2", "API error · Retrying · attempt 2/2"],
              "\(turn.notices)")
        check("(a) and claude's message when it gives up takes the line down",
              turn.finalNotice.isEmpty, turn.finalNotice)
    } else {
        check("(a) a loopback port to leave closed", false)
    }

    // (b) A turn cut off at a limit: one tool call, then --max-turns 1.
    let recB = scratch.appendingPathComponent("recB", isDirectory: true)
    try? fm.createDirectory(at: recB, withIntermediateDirectories: true)
    let script = scratch.appendingPathComponent("tool.json")
    try? line(["name": "Bash", "input": ["command": "echo hi", "description": "Say hi"]])
        .write(to: script, atomically: true, encoding: .utf8)
    if let server = startFakeServer(recordDir: recB, extra: ["--anthropic-script", script.path]) {
        let home = scratch.appendingPathComponent("homeB", isDirectory: true)
        let turn = claudeTurn(claude, prompt: "Run echo hi.", port: server.port, home: home,
                              extraArgs: ["--max-turns", "1", "--allowedTools", "Bash"])
        server.process.terminate()
        let errors = ((turn.rawResult?["errors"] as? [Any]) ?? []).compactMap { $0 as? String }
        note("claude said: \(errors.joined(separator: " | "))")
        check("(b) claude calls it failed, with its words in `errors` alone",
              (turn.rawResult?["is_error"] as? Bool) == true && !errors.isEmpty
              && turn.rawResult?["result"] == nil,
              "\(String(describing: turn.rawResult))")
        check("(b) the reader carries those words", resultEvent(turn.events)?.turnFailure == errors.joined(separator: "\n"),
              "\(String(describing: resultEvent(turn.events)?.turnFailure))")
        check("(b) and no row above says them: the runner's rule draws one",
              noticeText(before(turn).last) == nil
              && !AgentEventParser.failureIsShown(errors.joined(separator: "\n"), before: before(turn)[...]))
    } else {
        check("(b) the fake endpoint starts", false)
    }

    // (c) A turn that went through, and (d) a local command claude
    // answers itself that is not available here.
    let recC = scratch.appendingPathComponent("recC", isDirectory: true)
    try? fm.createDirectory(at: recC, withIntermediateDirectories: true)
    if let server = startFakeServer(recordDir: recC) {
        let homeC = scratch.appendingPathComponent("homeC", isDirectory: true)
        let ok = claudeTurn(claude, prompt: "Reply with OK.", port: server.port, home: homeC)
        check("(c) a turn that went through: exit 0, no failure, no retry line",
              ok.status == 0 && resultEvent(ok.events) != nil && resultEvent(ok.events)?.turnFailure == nil
                && ok.notices.isEmpty,
              "exit \(ok.status)")
        let homeD = scratch.appendingPathComponent("homeD", isDirectory: true)
        let local = claudeTurn(claude, prompt: "/status", port: server.port, home: homeD)
        check("(d) /status, which claude says is not available here: not a failure",
              resultEvent(local.events) != nil && resultEvent(local.events)?.turnFailure == nil,
              "\(String(describing: local.rawResult))")
        server.process.terminate()
    } else {
        check("(c) the fake endpoint starts", false)
    }

    // (e) A message claude refuses as too long before sending it, then the
    // same message sent once more — the runner's two attempts, by hand.
    let recE = scratch.appendingPathComponent("recE", isDirectory: true)
    try? fm.createDirectory(at: recE, withIntermediateDirectories: true)
    if let server = startFakeServer(recordDir: recE, script: harnessDir + "/too_long_server.py") {
        let home = scratch.appendingPathComponent("homeE", isDirectory: true)
        let work = home.appendingPathComponent("work", isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let notes = work.appendingPathComponent("CLAUDE.md")
        try? "# Notes\n\nVersion one.\n".write(to: notes, atomically: true, encoding: .utf8)
        // SipAI passes this on every claude turn where `--help` lists it.
        let linkDir = URL(fileURLWithPath: claude).deletingLastPathComponent().path
        let help = run(claude, ["--help"], environment: ["PATH": "\(linkDir):/usr/bin:/bin", "HOME": home.path],
                       cwd: work, timeout: 30).out
        let flags = help.contains("--system-prompt-snapshot") ? ["--system-prompt-snapshot", "off"] : []
        let requests = recE.appendingPathComponent("requests.jsonl")
        func kinds() -> [String] {
            ((try? String(contentsOf: requests, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                ((try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any])?["kind"] as? String
            }
        }
        func inOrder(_ rows: [String], _ wanted: [String]) -> Bool {
            var from = rows.startIndex
            for w in wanted {
                guard let at = rows[from...].firstIndex(of: w) else { return false }
                from = at + 1
            }
            return true
        }
        // The window claude divides by for this model, from its own result:
        // the conversation is then reported just under where claude compacts.
        let sizing = claudeTurn(claude, prompt: "Reply with OK.", port: server.port, home: home, extraArgs: flags)
        let window = ((sizing.rawResult?["modelUsage"] as? [String: Any]) ?? [:]).values
            .compactMap { (($0 as? [String: Any])?["contextWindow"] as? NSNumber)?.intValue }.max() ?? 0
        note("the model's window, as claude states it: \(window)")
        if window > 100_000 {
            try? String(window - 60_000).write(to: recE.appendingPathComponent("reported"),
                                               atomically: true, encoding: .utf8)
            let session = UUID().uuidString.lowercased()
            let opened = claudeTurn(claude, prompt: "HARNESS-OLD-CONVERSATION "
                                        + String(repeating: "earlier work ", count: 400),
                                    port: server.port, home: home,
                                    extraArgs: flags + ["--session-id", session])
            check("(e) a session near the limit: its turn goes through",
                  opened.status == 0 && resultEvent(opened.events)?.turnFailure == nil, "exit \(opened.status)")
            // The project notes change between two messages; the next
            // process attaches them again, whole.
            let pad = String(repeating: "This line pads the project notes so that the file is large.\n",
                             count: 7_000)
            try? ("# Notes\n\nVersion two HARNESS-INSTRUCTIONS-V2.\n\n" + pad)
                .write(to: notes, atomically: true, encoding: .utf8)
            let requestsSoFar = kinds().count
            let message = "Summarise the notes."
            let refusedTurn = claudeTurn(claude, prompt: message, port: server.port, home: home,
                                         extraArgs: flags + ["--resume", session])
            let refusedResult = resultEvent(refusedTurn.events)
            let triedCompaction = refusedTurn.lines.contains { AgentEventParser.compactingSignal(line: $0) == true }
            note("claude said: \((refusedTurn.rawResult?["result"] as? String) ?? "nothing") · "
                 + "\((refusedTurn.rawResult?["terminal_reason"] as? String) ?? "no reason")")
            check("(e) claude refuses the next message as too long, before sending it, and exits non-zero",
                  refusedResult?.turnFailure == "Prompt is too long" && refusedTurn.status != 0
                  && (refusedTurn.rawResult?["terminal_reason"] as? String) == "blocking_limit",
                  "\(String(describing: refusedTurn.rawResult))")
            check("(e) … nothing reached the endpoint, and no compaction was tried",
                  kinds().count == requestsSoFar && !triedCompaction, "\(kinds())")
            check("(e) the reader reads it as refused before sending", refusedResult?.refusedAsTooLong == true)
            check("(e) the runner's rule sends it once more",
                  refusedResult.map {
                      AgentEventParser.resendsTooLongRefusal($0, attempt: before(refusedTurn)[...],
                                                             resumedSession: true,
                                                             compactionTried: triedCompaction,
                                                             alreadyResent: false, stopped: false)
                  } == true)
            let resent = claudeTurn(claude, prompt: message, port: server.port, home: home,
                                    extraArgs: flags + ["--resume", session])
            let compactedFirst = resent.lines.contains { AgentEventParser.compactingSignal(line: $0) == true }
            let compactionRow = resent.events.contains { if case .compaction = $0.kind { return true }; return false }
            let answered = resent.events.contains {
                if case .assistantText(let text) = $0.kind { return text == "OK" }
                return false
            }
            check("(e) sent once more, claude compacts first and answers",
                  resent.status == 0 && compactedFirst && compactionRow && answered
                  && resultEvent(resent.events)?.turnFailure == nil
                  && resultEvent(resent.events)?.refusedAsTooLong == false,
                  "exit \(resent.status)")
            let seen = Array(kinds().dropFirst(requestsSoFar))
            check("(e) … the endpoint saw the compaction, then the answer, and refused nothing",
                  seen.first == "compact" && seen.contains("ok") && !seen.contains("refused"), "\(seen)")
            let projects = home.appendingPathComponent("cfg/projects", isDirectory: true)
            let transcript = (fm.enumerator(at: projects, includingPropertiesForKeys: nil)?
                .allObjects as? [URL] ?? []).first { $0.lastPathComponent == "\(session).jsonl" }
            if let transcript {
                let reopened = rows(AgentSessionScanner.readHistory(of: transcript))
                check("(e) reopened: the message twice — the refused attempt and the re-send — never three times",
                      reopened.filter { $0 == "you: \(message)" }.count == 2, "\(reopened)")
                check("(e) … with claude's notice between them, the compaction after the second, the answer last",
                      inOrder(reopened, ["you: \(message)", "notice: Prompt is too long", "you: \(message)",
                                         "compacted"])
                      && reopened.last == "agent: OK", "\(reopened)")
            } else {
                check("(e) the session's transcript is on disk", false)
            }
        } else {
            check("(e) claude states the model's window on its result", false,
                  "\(String(describing: sizing.rawResult?["modelUsage"]))")
        }
        server.process.terminate()
    } else {
        check("(e) the stand-in endpoint starts", false)
    }

    // (f) The same refusal for a message edited IN PLACE — sent at the
    // entry above it with `--resume-session-at`. The refused attempt
    // already hangs the edit off that entry, with the instruction files
    // claude attached for it; the runner's second attempt goes without
    // the flag. With it, the cut is made again, the copy is off the line
    // again, and claude refuses again (the control).
    let recF = scratch.appendingPathComponent("recF", isDirectory: true)
    try? fm.createDirectory(at: recF, withIntermediateDirectories: true)
    if let server = startFakeServer(recordDir: recF, script: harnessDir + "/too_long_server.py") {
        let home = scratch.appendingPathComponent("homeF", isDirectory: true)
        let work = home.appendingPathComponent("work", isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let notes = work.appendingPathComponent("CLAUDE.md")
        let linkDir = URL(fileURLWithPath: claude).deletingLastPathComponent().path
        let help = run(claude, ["--help"], environment: ["PATH": "\(linkDir):/usr/bin:/bin", "HOME": home.path],
                       cwd: work, timeout: 30).out
        let flags = help.contains("--system-prompt-snapshot") ? ["--system-prompt-snapshot", "off"] : []
        let resumeAt = "--resume-session-at"
        let requests = recF.appendingPathComponent("requests.jsonl")
        func recorded() -> [[String: Any]] {
            ((try? String(contentsOf: requests, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }
        let projects = home.appendingPathComponent("cfg/projects", isDirectory: true)
        func transcript(_ session: String) -> URL? {
            (fm.enumerator(at: projects, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .first { $0.lastPathComponent == "\(session).jsonl" }
        }
        try? "# Notes\n\nVersion one.\n".write(to: notes, atomically: true, encoding: .utf8)
        let sizing = claudeTurn(claude, prompt: "Reply with OK.", port: server.port, home: home, extraArgs: flags)
        let window = ((sizing.rawResult?["modelUsage"] as? [String: Any]) ?? [:]).values
            .compactMap { (($0 as? [String: Any])?["contextWindow"] as? NSNumber)?.intValue }.max() ?? 0
        // The flag is not in `--help`; claude's executable names it.
        let namesFlag = (try? Data(contentsOf: URL(fileURLWithPath: claude), options: .alwaysMapped))?
            .range(of: Data(resumeAt.utf8)) != nil
        if window > 100_000 && namesFlag {
            try? String(window - 60_000).write(to: recF.appendingPathComponent("reported"),
                                               atomically: true, encoding: .utf8)
            /// A session near the limit, two messages long, then the notes
            /// changed: the second message is the one edited. Answers the
            /// session and the entry above that message.
            func prepared() -> (session: String, entry: String)? {
                try? "# Notes\n\nVersion one.\n".write(to: notes, atomically: true, encoding: .utf8)
                let session = UUID().uuidString.lowercased()
                let opened = claudeTurn(claude, prompt: "HARNESS-OLD-CONVERSATION "
                                            + String(repeating: "earlier work ", count: 400),
                                        port: server.port, home: home,
                                        extraArgs: flags + ["--session-id", session])
                let second = claudeTurn(claude, prompt: "HARNESS-SECOND-MESSAGE", port: server.port,
                                        home: home, extraArgs: flags + ["--resume", session])
                guard opened.status == 0, second.status == 0, let file = transcript(session),
                      let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                let entry = text.split(separator: "\n").compactMap { line -> String? in
                    guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                          obj["type"] as? String == "user",
                          "\(obj["message"] ?? "")".contains("HARNESS-SECOND-MESSAGE") else { return nil }
                    return obj["parentUuid"] as? String
                }.last
                guard let entry else { return nil }
                let pad = String(repeating: "This line pads the project notes so that the file is large.\n",
                                 count: 7_000)
                try? ("# Notes\n\nVersion two HARNESS-INSTRUCTIONS-V2.\n\n" + pad)
                    .write(to: notes, atomically: true, encoding: .utf8)
                return (session, entry)
            }
            let edit = "HARNESS-EDITED"
            if let control = prepared() {
                let refused = claudeTurn(claude, prompt: edit, port: server.port, home: home,
                                         extraArgs: flags + ["--resume", control.session, resumeAt, control.entry])
                check("(f) an edit sent in place near the limit is refused as too long, before sending",
                      resultEvent(refused.events)?.refusedAsTooLong == true,
                      "\(String(describing: refused.rawResult?["terminal_reason"]))")
                let again = claudeTurn(claude, prompt: edit, port: server.port, home: home,
                                       extraArgs: flags + ["--resume", control.session, resumeAt, control.entry])
                check("(f) sent again at the same entry, it is refused again: the cut drops the copy claude counts",
                      resultEvent(again.events)?.refusedAsTooLong == true,
                      "exit \(again.status) \(String(describing: again.rawResult?["terminal_reason"]))")
            } else {
                check("(f) the control session is prepared", false)
            }
            if let fixed = prepared() {
                let refused = claudeTurn(claude, prompt: edit, port: server.port, home: home,
                                         extraArgs: flags + ["--resume", fixed.session, resumeAt, fixed.entry])
                let before = recorded().count
                let again = claudeTurn(claude, prompt: edit, port: server.port, home: home,
                                       extraArgs: flags + ["--resume", fixed.session])
                let compactedFirst = again.lines.contains { AgentEventParser.compactingSignal(line: $0) == true }
                let answered = again.events.contains {
                    if case .assistantText(let text) = $0.kind { return text == "OK" }
                    return false
                }
                check("(f) sent again from where the refused attempt left it, claude compacts first and answers",
                      resultEvent(refused.events)?.refusedAsTooLong == true
                      && again.status == 0 && compactedFirst && answered,
                      "exit \(again.status)")
                let seen = Array(recorded().dropFirst(before))
                let summarized = seen.first { $0["kind"] as? String == "compact" }
                let marks = (summarized?["marks"] as? [String]) ?? []
                check("(f) … what claude summarized holds the edit, not the message it replaced",
                      marks.contains(edit) && !marks.contains("HARNESS-SECOND-MESSAGE"), "\(seen)")
                if let file = transcript(fixed.session) {
                    let drawn = rows(AgentSessionScanner.readHistory(of: file))
                    check("(f) reopened, the edit is drawn and the message it replaced is not",
                          drawn.contains("you: \(edit)") && !drawn.contains("you: HARNESS-SECOND-MESSAGE")
                          && drawn.last == "agent: OK", "\(drawn.map { String($0.prefix(40)) })")
                } else {
                    check("(f) the edited session's transcript is on disk", false)
                }
            } else {
                check("(f) the edited session is prepared", false)
            }
        } else {
            note("(f) SKIP — claude states no window, or does not name \(resumeAt)")
        }
        server.process.terminate()
    } else {
        check("(f) the stand-in endpoint starts", false)
    }
} else {
    note("SKIP — no installed claude, or no fake endpoint")
}

// ─────────────────────────────────────────────────────────── summary

try? fm.removeItem(at: scratch)
print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
