// AgentQuestions harness — see run.sh for what it pins and why.
//
// Arguments: <source-root> <work-dir> <harness-dir>
// Environment: QUESTIONS_HARNESS_MCP_DIR (read by Stubs.swift), the
// directory the REAL MCPBridge binds its socket in and finds approver.py.
import Foundation

let sourceRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let work = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let here = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)

var passed = 0
var failed = 0
func section(_ title: String) { print("\n" + title) }
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        passed += 1
        print("  ok    \(name)")
    } else {
        failed += 1
        let d = detail()
        print("  FAIL  \(name)" + (d.isEmpty ? "" : "\n        \(d)"))
    }
}
func note(_ text: String) { print("        \(text)") }

@MainActor
func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
}

func source(_ relative: String) -> String {
    (try? String(contentsOf: sourceRoot.appendingPathComponent(relative), encoding: .utf8)) ?? ""
}

/// The text between `start` and the first `end` after it, or "".
func slice(_ text: String, from start: String, to end: String) -> String {
    guard let a = text.range(of: start),
          let b = text.range(of: end, range: a.upperBound..<text.endIndex) else { return "" }
    return String(text[a.lowerBound..<b.upperBound])
}

func occurrences(_ needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

let draftUuid = "0123456789abcdef0123456789abcdef"
let otherUuid = "fedcba9876543210fedcba9876543210"

// Synthetic, in the shape claude sends (measured): two questions, the
// second multi-select, one option carrying a preview.
let q1 = "Which color should the probe use?"
let q2 = "Which extras should it add?"
let askInput: [String: Any] = ["questions": [
    ["question": q1, "header": "Color", "multiSelect": false,
     "options": [["label": "Red", "description": "Warm"],
                 ["label": "Blue", "description": "Cool", "preview": "[ BLUE ]\n#0000ff"]]],
    ["question": q2, "header": "Extras", "multiSelect": true,
     "options": [["label": "Logs", "description": "Write logs"],
                 ["label": "Tests", "description": "Add tests"],
                 ["label": "Docs", "description": "Add docs"]]],
]]

func input(questions: [[String: Any]]) -> [String: Any] { ["questions": questions] }
func question(_ text: String, options: [[String: Any]], multi: Bool = false,
              extra: [String: Any] = [:]) -> [String: Any] {
    var q: [String: Any] = ["question": text, "header": "H", "options": options, "multiSelect": multi]
    for (key, value) in extra { q[key] = value }
    return q
}
func options(_ labels: String...) -> [[String: Any]] {
    labels.map { ["label": $0, "description": "d"] }
}

// MARK: - 1. The form

section("1. What a question card can draw, and how an answer goes back (AgentQuestionForm)")
guard let form = AgentQuestionForm(toolInput: askInput) else {
    print("  FAIL  claude's own shape does not parse — nothing below can hold")
    exit(1)
}
check("claude's shape parses: two questions, their options, a preview, a multi-select",
      form.questions.count == 2
        && form.questions[0].options.map(\.label) == ["Red", "Blue"]
        && form.questions[0].options[1].preview == "[ BLUE ]\n#0000ff"
        && form.questions[0].options[0].preview == nil
        && !form.questions[0].multiSelect && form.questions[1].multiSelect
        && form.questions[1].header == "Extras")
check("a question's text is kept exactly — it is the key the answer is filed under",
      AgentQuestionForm(toolInput: input(questions: [question("  Spaced?  ", options: options("A", "B"))]))?
        .questions.first?.text == "  Spaced?  ")
check("an option without a description is drawn with none",
      AgentQuestionForm(toolInput: input(questions: [question("Q?", options: [["label": "A"], ["label": "B"]])]))?
        .questions.first?.options.first?.description == "")
check("kind \"choice\" is a choice question",
      AgentQuestionForm(toolInput: input(questions: [question("Q?", options: options("A", "B"),
                                                             extra: ["kind": "choice"])])) != nil)
let unreadable: [(String, [String: Any])] = [
    ("no questions", ["questions": [Any]()]),
    ("no questions key", ["title": "x"]),
    ("a question with one option", input(questions: [question("Q?", options: options("A"))])),
    ("an open-ended (text) question",
     input(questions: [question("Q?", options: [], extra: ["kind": "text"])])),
    ("a number question",
     input(questions: [question("Q?", options: [], extra: ["kind": "number", "min": 1, "max": 5])])),
    ("the same option twice", input(questions: [question("Q?", options: options("A", "A"))])),
    ("the same question twice", input(questions: [question("Q?", options: options("A", "B")),
                                                  question("Q?", options: options("C", "D"))])),
    ("an empty label", input(questions: [question("Q?", options: options("", "B"))])),
    ("a blank question", input(questions: [question("  ", options: options("A", "B"))])),
    ("an option that is not an object", input(questions: [["question": "Q?", "options": ["A", "B"]]])),
    ("nine questions", input(questions: (1...9).map { question("Q\($0)?", options: options("A", "B")) })),
]
for (name, bad) in unreadable {
    check("unreadable, so declined rather than half-drawn: \(name)",
          AgentQuestionForm(toolInput: bad) == nil)
}

let encoded = form.updatedInput(original: askInput, answers: [
    q1: AgentQuestionAnswer(labels: ["Blue"]),
    q2: AgentQuestionAnswer(labels: ["Tests", "Logs"]),   // picked out of order
])
let encodedAnswers = encoded["answers"] as? [String: String] ?? [:]
check("a single choice goes back as its label", encodedAnswers[q1] == "Blue")
check("a multi-select goes back as ONE string, in the options' order, joined with \", \"",
      encodedAnswers[q2] == "Logs, Tests", "got \(encodedAnswers[q2] ?? "nil")")
let encodedNotes = encoded["annotations"] as? [String: [String: String]] ?? [:]
check("the picked option's preview rides along as claude's own annotation",
      encodedNotes[q1]?["preview"] == "[ BLUE ]\n#0000ff" && encodedNotes[q2] == nil)
check("…and the input claude proposed is kept, every key of it",
      (encoded["questions"] as? [[String: Any]])?.count == 2)
let other = form.updatedInput(original: askInput, answers: [
    q1: AgentQuestionAnswer(labels: ["Red"], otherText: "  Green, please ", otherPicked: true),
    q2: AgentQuestionAnswer(labels: ["Docs"], otherText: "Benchmarks", otherPicked: true),
])
let otherAnswers = other["answers"] as? [String: String] ?? [:]
check("the user's own words replace a single choice (trimmed), and carry no preview",
      otherAnswers[q1] == "Green, please" && (other["annotations"] as? [String: Any])?[q1] == nil)
check("…and join a multi-select after its picked labels", otherAnswers[q2] == "Docs, Benchmarks")
let partial = form.updatedInput(original: askInput, answers: [q1: AgentQuestionAnswer(labels: ["Red"])])
check("an unanswered question is left out — claude reads that as unanswered",
      (partial["answers"] as? [String: String]).map { Array($0.keys) } == [q1])
var hostile = askInput
hostile["answers"] = [q1: "Red", q2: "Docs"]
hostile["annotations"] = [q2: ["notes": "written by the agent"]]
let replaced = form.updatedInput(original: hostile, answers: [q1: AgentQuestionAnswer(labels: ["Blue"])])
check("answers the agent wrote into its own call are replaced, never merged",
      (replaced["answers"] as? [String: String]) == [q1: "Blue"]
        && (replaced["annotations"] as? [String: [String: String]])?[q2] == nil)
check("a label the question does not offer is no answer",
      AgentQuestionAnswer(labels: ["Purple"]).value(for: form.questions[0]) == nil)
check("an Other picked with nothing typed is no answer",
      AgentQuestionAnswer(otherPicked: true).value(for: form.questions[0]) == nil)
check("Submit needs one answer at least",
      !form.hasAnyAnswer([:]) && form.hasAnyAnswer([q2: AgentQuestionAnswer(labels: ["Logs"])]))

// MARK: - 1b. The keyboard on the card

section("1b. Where the keyboard stands on a question card (AgentQuestionKeys)")
let firstPage = AgentQuestionKeys.grid(for: form, page: 0)
let secondPage = AgentQuestionKeys.grid(for: form, page: 1)
check("a page is its options, the user's own answer, then the buttons in the order they are drawn",
      firstPage.rows == [[.option(0)], [.option(1)], [.other], [.skip, .chat, .primary]]
        && secondPage.rows.last == [.skip, .chat, .previous, .primary]
        && secondPage.rows.count == 5)
check("↓ walks the options, on to the user's own answer, then to the main button",
      firstPage.moved(from: .option(0), by: .down) == .option(1)
        && firstPage.moved(from: .option(1), by: .down) == .other
        && firstPage.moved(from: .other, by: .down) == .primary
        && firstPage.moved(from: .primary, by: .down) == .primary)
check("↑ comes back the same way, and stops at the first option",
      firstPage.moved(from: .primary, by: .up) == .other && firstPage.moved(from: .skip, by: .up) == .other
        && firstPage.moved(from: .other, by: .up) == .option(1)
        && firstPage.moved(from: .option(0), by: .up) == .option(0))
check("← and → move along the buttons",
      firstPage.moved(from: .primary, by: .left) == .chat && firstPage.moved(from: .chat, by: .left) == .skip
        && firstPage.moved(from: .skip, by: .left) == .skip && firstPage.moved(from: .skip, by: .right) == .chat
        && secondPage.moved(from: .primary, by: .left) == .previous)
check("…and turn the page from an option or the user's own answer, where a row holds one stop",
      AgentQuestionKeys.turnsPage(at: .option(1)) && AgentQuestionKeys.turnsPage(at: .other)
        && !AgentQuestionKeys.turnsPage(at: .primary) && !AgentQuestionKeys.turnsPage(at: .skip)
        && !AgentQuestionKeys.turnsPage(at: .chat) && !AgentQuestionKeys.turnsPage(at: .previous))
check("a page opens on its first option while the question is open",
      AgentQuestionKeys.entry(for: form, page: 0, answers: [:]) == .option(0))
check("…and on the main button once it has its answer, so Return sends the card",
      AgentQuestionKeys.entry(for: form, page: 0, answers: [q1: AgentQuestionAnswer(labels: ["Red"])]) == .primary
        && AgentQuestionKeys.entry(for: form, page: 7, answers: [:]) == .primary)
check("after a single choice the keyboard goes to the next question still open",
      AgentQuestionKeys.nextOpen(after: 0, in: form, answers: [q1: AgentQuestionAnswer(labels: ["Red"])]) == 1
        && AgentQuestionKeys.nextOpen(after: 0, in: form, answers: [
            q1: AgentQuestionAnswer(labels: ["Red"]), q2: AgentQuestionAnswer(labels: ["Docs"])]) == nil
        && AgentQuestionKeys.nextOpen(after: 1, in: form, answers: [:]) == nil)
let chatWords = AgentQuestionReplies.chat(about: form, answers: [q1: AgentQuestionAnswer(labels: ["Blue"])])
check("\"Chat about this\" tells the agent to ask what to clarify — not to guess, and not to ask the card again",
      chatWords.hasPrefix("The user wants to talk these questions over before answering them.")
        && chatWords.contains("Do not retry AskUserQuestion yet")
        && chatWords.contains("end your turn by asking what they would like to clarify"))
check("…and hands it the questions, with what was answered so far",
      chatWords.contains("- \"\(q1)\"\n  Answer so far: Blue")
        && chatWords.contains("- \"\(q2)\"\n  (no answer yet)"))

// MARK: - 1c. An MCP server's form

/// Compact JSON with sorted keys, for comparing what goes back.
func jsonText(_ obj: Any) -> String {
    guard JSONSerialization.isValidJSONObject(obj),
          let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return "\(obj)" }
    return String(decoding: data, as: UTF8.self)
}

extension McpElicitation.Request {
    func with(url: String) -> Self {
        var copy = self
        copy.url = url
        return copy
    }
}

section("1c. What an MCP server asks, drawn and answered (McpElicitation)")
/// A form schema the way an MCP server sends one.
let mcpSchema: [String: Any] = [
    "type": "object",
    "properties": [
        "name": ["type": "string", "title": "Your name", "description": "What should the report call you?"],
        "email": ["type": "string", "title": "Email", "format": "email", "maxLength": 40],
        "color": ["type": "string", "title": "Favourite colour",
                  "oneOf": [["const": "red", "title": "Red"], ["const": "blue", "title": "Blue"]],
                  "default": "red"],
        "size": ["type": "string", "title": "Size", "enum": ["s", "m"], "enumNames": ["Small", "Medium"]],
        "subscribe": ["type": "boolean", "title": "Subscribe", "default": true],
        "count": ["type": "integer", "title": "How many", "minimum": 1, "maximum": 9, "default": 2],
        "ratio": ["type": "number", "title": "Ratio", "minimum": 0.5],
        "tags": ["type": "array", "title": "Tags", "minItems": 2, "maxItems": 3,
                 "items": ["type": "string", "enum": ["a", "b", "c", "d"]]],
    ] as [String: Any],
    "required": ["name", "color", "count"],
]
func mcpRequest(_ schema: [String: Any]?, mode: String = "form", message: String = "Tell the report about you",
                order: [String]? = nil, meta: [String: Any]? = nil) -> McpElicitation.Request {
    var hook: [String: Any] = ["hook_event_name": "Elicitation", "mcp_server_name": "reports",
                               "message": message, "mode": mode]
    if let schema { hook["requested_schema"] = schema }
    var request = McpElicitation.Request(claudeHook: hook, fieldOrder: order)!
    request.meta = meta
    return request
}
let ordered = ["name", "email", "color", "size", "subscribe", "count", "ratio", "tags"]
let formCard = McpElicitation.card(for: mcpRequest(mcpSchema, order: ordered))
let mcpForm = formCard?.question
check("a form is a question card naming the server, its words above the fields, one page per field",
      formCard?.presentation == .question && mcpForm?.asker == "reports"
        && mcpForm?.message == "Tell the report about you" && mcpForm?.questions.count == 8)
check("the fields keep the order the server listed them in, where the relay kept it",
      mcpForm?.questions.compactMap(\.id) == ordered)
check("…and without one: the required fields as listed, then the rest by name",
      McpElicitation.card(for: mcpRequest(mcpSchema))?.question?.questions.compactMap(\.id)
        == ["name", "color", "count", "email", "ratio", "size", "subscribe", "tags"])
if let mcpForm, mcpForm.questions.count == 8 {
    let byId = Dictionary(uniqueKeysWithValues: mcpForm.questions.compactMap { q in q.id.map { ($0, q) } })
    let name = byId["name"]!, email = byId["email"]!, color = byId["color"]!, size = byId["size"]!
    let subscribe = byId["subscribe"]!, count = byId["count"]!, ratio = byId["ratio"]!, tags = byId["tags"]!
    check("a text field: the description asked, the title above it, the user's words, required where the form says",
          name.text == "What should the report call you?" && name.header == "Your name"
            && name.options.isEmpty && name.allowsOther && name.required && !email.required)
    check("a choice shows titles — oneOf's, or enumNames' — and takes no words of the user's own",
          color.options.map(\.label) == ["Red", "Blue"] && !color.allowsOther
            && size.options.map(\.label) == ["Small", "Medium"])
    check("yes-or-no is Yes / No; a multiple choice keeps its bounds",
          subscribe.options.map(\.label) == [McpElicitation.Words.yes, McpElicitation.Words.no]
            && tags.multiSelect && tags.minPicks == 2 && tags.maxPicks == 3
            && tags.picksHint == "Choose 2 to 3")
    check("the card starts on the server's defaults",
          mcpForm.initialAnswers[color.text]?.labels == ["Red"]
            && mcpForm.initialAnswers[subscribe.text]?.labels == [McpElicitation.Words.yes]
            && mcpForm.initialAnswers[count.text]?.otherText == "2")
    check("a typed field says what it takes",
          count.words?.hint == "A whole number · From 1 to 9" && ratio.words?.hint == "A number · At least 0.5"
            && email.words?.hint == "An email address · At most 40 characters" && name.words == nil)
    let integer = WordsRule.number(integer: true, minimum: 1, maximum: 9)
    check("a whole number: digits and a sign, within its bounds — never a fraction, a hex float, an infinity",
          integer.accepts("3") && integer.accepts("+9") && !integer.accepts("3.5") && !integer.accepts("10")
            && !integer.accepts("0") && !integer.accepts("0x5") && !integer.accepts("three")
            && !WordsRule.number(integer: false, minimum: nil, maximum: nil).accepts("inf")
            && WordsRule.number(integer: false, minimum: nil, maximum: nil).accepts("1e3")
            && WordsRule.number(integer: false, minimum: nil, maximum: nil).accepts(".5"))
    check("formats: an email, a web address, a date, a date and time",
          WordsRule.text(minLength: nil, maxLength: nil, format: .email).accepts("ada@example.com")
            && !WordsRule.text(minLength: nil, maxLength: nil, format: .email).accepts("ada at example")
            && WordsRule.text(minLength: nil, maxLength: nil, format: .uri).accepts("https://example.com/x")
            && !WordsRule.text(minLength: nil, maxLength: nil, format: .uri).accepts("not a link")
            && WordsRule.text(minLength: nil, maxLength: nil, format: .date).accepts("2026-02-28")
            && !WordsRule.text(minLength: nil, maxLength: nil, format: .date).accepts("2026-02-30")
            && WordsRule.text(minLength: nil, maxLength: nil, format: .dateTime).accepts("2026-02-28T10:00:00Z")
            && !WordsRule.text(minLength: nil, maxLength: nil, format: .dateTime).accepts("tomorrow"))
    check("a length counts characters as JSON Schema does (code points)",
          WordsRule.text(minLength: 2, maxLength: 3, format: nil).accepts("ab")
            && !WordsRule.text(minLength: 2, maxLength: 3, format: nil).accepts("abcd")
            && WordsRule.text(minLength: nil, maxLength: 2, format: nil).accepts("中文"))
    var answers: [String: AgentQuestionAnswer] = mcpForm.initialAnswers
    check("Submit waits for every required field — not just any answer",
          !mcpForm.canSubmit(answers))
    answers[name.text] = AgentQuestionAnswer(otherText: "  Ada  ", otherPicked: true)
    check("…and goes once they have one; an optional field may stay empty", mcpForm.canSubmit(answers))
    answers[email.text] = AgentQuestionAnswer(otherText: "nope", otherPicked: true)
    answers[tags.text] = AgentQuestionAnswer(labels: ["a"])
    check("words a field does not take, or too few picks, are no answer — and hold the card back rather than be dropped",
          email.words.map { !$0.accepts("nope") } == true
            && answers[email.text]?.value(for: email) == nil && answers[email.text]?.isUnfit(for: email) == true
            && answers[tags.text]?.value(for: tags) == nil && answers[tags.text]?.isUnfit(for: tags) == true
            && !mcpForm.canSubmit(answers))
    answers[email.text] = AgentQuestionAnswer(otherText: "ada@example.com", otherPicked: true)
    answers[tags.text] = AgentQuestionAnswer(labels: ["d", "b"])
    answers[ratio.text] = AgentQuestionAnswer(otherText: "0.75", otherPicked: true)
    answers[color.text] = AgentQuestionAnswer(labels: ["Blue"])
    let accepted = formCard.map { McpElicitation.answer(for: .answered(answers), to: $0) }
    check("accepted, each field typed as the schema types it: words trimmed, the choice's value, a number, a boolean, the values picked in the server's order",
          accepted?.action == "accept"
            && jsonText(accepted?.content ?? [:])
                == #"{"color":"blue","count":2,"email":"ada@example.com","name":"Ada","ratio":0.75,"subscribe":true,"tags":["b","d"]}"#,
          jsonText(accepted?.content ?? [:]))
    answers[name.text] = nil
    check("an answer that skips a required field is never sent half-made: declined",
          formCard.map { McpElicitation.answer(for: .answered(answers), to: $0).action } == "decline")
}
if let formCard {
    check("Decline, Non-stop and nobody to answer are decline; Stop and a quit are cancel",
          McpElicitation.answer(for: .skipped, to: formCard).action == "decline"
            && McpElicitation.answer(for: .declined(.nonStop), to: formCard).action == "decline"
            && McpElicitation.answer(for: .declined(.unanswerable), to: formCard).action == "decline"
            && McpElicitation.answer(for: .cancelled, to: formCard).action == "cancel")
}
let confirm = McpElicitation.card(for: mcpRequest(["type": "object", "properties": [String: Any]()],
                                                  message: "Send the report now?"))
if case .permission(let content, let toolApproval)? = confirm {
    check("a form with no fields is a yes-or-no naming the server: Allow, Deny (what Esc takes), Cancel, in one row",
          !toolApproval && content.prompt == McpElicitation.Words.requestsInput("reports")
            && content.preview == .text("Send the report now?")
            && content.choices.map(\.id) == ["accept", "decline", "cancel"]
            && content.rows == nil
            && CardChoiceLayout.cancel(content.choices) == "decline")
    let ok = McpElicitation.answer(for: .chose("accept"), to: confirm!)
    check("…allowed, it is accepted with an empty form",
          ok.action == "accept" && ok.content.map(jsonText) == "{}" && ok.persist == nil)
} else {
    check("a form with no fields is a yes-or-no", false, "\(String(describing: confirm))")
}
// A remembered answer is codex's, for its own approvals; a server's own
// question has none — offered, its note would say codex remembers it.
let confirmWithPersist = McpElicitation.card(for: mcpRequest(["type": "object", "properties": [String: Any]()],
                                                             message: "Send the report now?",
                                                             meta: ["persist": ["session", "always"]]),
                                            sessionNote: "lasts the turn")
if case .permission(let content, _)? = confirmWithPersist {
    check("a server's own yes-or-no offers no answer to remember, whatever its own meta says",
          content.choices.map(\.id) == ["accept", "decline", "cancel"] && content.notes.isEmpty,
          "\(content.choices.map(\.id)) \(content.notes)")
}
let approvalMeta: [String: Any] = ["codex_approval_kind": "mcp_tool_call", "persist": ["session", "always"],
                                   "tool_params_display": [["name": "path", "display_name": "Path", "value": "notes.md"],
                                                           ["name": "lines", "display_name": "Lines", "value": 3]]]
let approvalCard = McpElicitation.card(for: mcpRequest(["type": "object", "properties": [String: Any]()],
                                                      message: "Allow the reports MCP server to run tool \"save\"?",
                                                      meta: approvalMeta),
                                      sessionNote: "lasts the turn", alwaysNote: "kept in its settings")
if case .permission(let content, let toolApproval)? = approvalCard {
    check("codex's approval of an MCP tool, in codex's words and order: its sentence, what the call passes, Allow / Allow for this session / Always allow / Cancel",
          toolApproval && content.prompt == "Allow the reports MCP server to run tool \"save\"?"
            && content.preview == .text("Path: notes.md\nLines: 3")
            && content.choices.map(\.id) == ["accept", "accept_session", "accept_always", "cancel"]
            && content.choices.map(\.label) == ["Allow", "Allow for this session", "Always allow", "Cancel"]
            && content.notes == ["lasts the turn", "kept in its settings"]
            && content.asker == nil,
          "\(content.choices.map(\.label)) \(content.notes)")
    let session = McpElicitation.answer(for: .chose("accept_session"), to: approvalCard!)
    check("…Allow for this session is accepted with codex's own persist, and no form content",
          session.action == "accept" && session.content == nil && session.persist == "session")
    let always = McpElicitation.answer(for: .chose("accept_always"), to: approvalCard!)
    check("…Always allow is accepted with codex's own persist \"always\" — codex then saves the tool's approval itself",
          always.action == "accept" && always.content == nil && always.persist == "always")
    // Laid out as Claude's permission card: Allow Always above Allow, Deny
    // Always above Deny — here Always allow above Allow, Allow for this
    // session above Cancel.
    check("…in Claude's two rows: the answers that keep it above, Cancel and Allow below",
          content.rows == [["accept_session", "accept_always"], ["cancel", "accept"]],
          "\(String(describing: content.rows))")
    let keys = CardChoiceLayout.grid(content.choices, arranged: content.rows)
    check("…the keys move as on Claude's card: Return starts on Allow, ↑ is Always allow, ← is Cancel, then ↑ Allow for this session",
          CardChoiceLayout.initial(content.choices) == "accept"
            && keys.moved(from: "accept", by: .up) == "accept_always"
            && keys.moved(from: "accept", by: .left) == "cancel"
            && keys.moved(from: "cancel", by: .up) == "accept_session"
            && keys.moved(from: "accept_always", by: .left) == "accept_session"
            && keys.moved(from: "accept_always", by: .down) == "accept"
            && keys.moved(from: "accept", by: .right) == "accept"
            && CardChoiceLayout.cancel(content.choices) == "cancel")
    let column = CardChoiceLayout.grid(content.choices, arranged: content.rows, stacked: true)
    check("…stacked in one column on a card too narrow for two, the keys walk the column as the rows read: ↑ from Allow is Cancel",
          column.moved(from: "accept", by: .up) == "cancel"
            && column.moved(from: "cancel", by: .up) == "accept_always"
            && column.moved(from: "accept_always", by: .up) == "accept_session"
            && column.moved(from: "accept_session", by: .down) == "accept_always")
    let asQuestion = confirm.map {
        MCPApprovalRequest(agentKey: "codex", sessionId: "s", taskUuid: nil, toolName: "reports",
                           presentation: $0.presentation, respond: { _ in }).asksQuestion
    }
    let asPermission = MCPApprovalRequest(agentKey: "codex", sessionId: "s", taskUuid: nil,
                                          toolName: "reports", presentation: approvalCard!.presentation,
                                          respond: { _ in }).asksQuestion
    check("a server's own yes-or-no is a question, which Non-stop declines; codex's approval of a tool is a permission, which waits",
          asQuestion == true && !asPermission,
          "yes-or-no \(String(describing: asQuestion)), approval \(asPermission)")
} else {
    check("codex's approval of an MCP tool is a permission card", false, "\(String(describing: approvalCard))")
}
check("an approval codex says cannot be kept offers neither way of keeping it: Cancel and Allow, one row",
      { if case .permission(let c, _)? = McpElicitation.card(for: mcpRequest(
            ["type": "object", "properties": [String: Any]()], meta: ["codex_approval_kind": "mcp_tool_call"])) {
            return c.choices.map(\.id) == ["accept", "cancel"] && c.notes.isEmpty
                && c.rows == [["cancel", "accept"]] }
        return false }())
check("…and one kept for the session only offers that alone, above Allow",
      { if case .permission(let c, _)? = McpElicitation.card(for: mcpRequest(
            ["type": "object", "properties": [String: Any]()],
            meta: ["codex_approval_kind": "mcp_tool_call", "persist": "session"])) {
            let keys = CardChoiceLayout.grid(c.choices, arranged: c.rows)
            return c.choices.map(\.id) == ["accept", "accept_session", "cancel"]
                && c.rows == [["accept_session"], ["cancel", "accept"]]
                && keys.moved(from: "accept", by: .up) == "accept_session"
                && keys.moved(from: "accept_session", by: .down) == "accept" }
        return false }())
let choices3 = [CardChoice(id: "a", label: "A", role: .accept), CardChoice(id: "b", label: "B", role: .other),
                CardChoice(id: "c", label: "C", role: .decline)]
check("rows that leave an answer out or name one twice are not drawn — one row, in the agent's order; a name the card does not have, or an empty row, is passed over",
      CardChoiceLayout.rows(choices3, arranged: [["a"], ["c"]]).map { $0.map(\.id) } == [["a", "b", "c"]]
        && CardChoiceLayout.rows(choices3, arranged: [["a", "b"], ["b", "c"]]).map { $0.map(\.id) } == [["a", "b", "c"]]
        && CardChoiceLayout.rows(choices3, arranged: [["a", "b"], ["c", "x"]]).map { $0.map(\.id) } == [["a", "b"], ["c"]]
        && CardChoiceLayout.rows(choices3, arranged: [["b", "c"], [], ["a"]]).map { $0.map(\.id) } == [["b", "c"], ["a"]]
        && CardChoiceLayout.rows(choices3).map { $0.map(\.id) } == [["a", "b", "c"]])
let link = McpElicitation.card(for: mcpRequest(nil, mode: "url", message: "Sign in")
    .with(url: "https://example.com/sign-in?step=1"))
check("a link is the link card: the server, its words, the link as it would open",
      link?.presentation == .link(LinkCardContent(asker: "reports", message: "Sign in",
                                                  url: "https://example.com/sign-in?step=1", opens: true)))
check("SipAI opens only an https link with a host, no user name or password, plain ASCII, of a sane length",
      McpElicitation.opensSafely("https://example.com/a?b=c")
        && !McpElicitation.opensSafely("http://example.com/")
        && !McpElicitation.opensSafely("javascript:alert(1)")
        && !McpElicitation.opensSafely("https://user:pw@example.com/")
        && !McpElicitation.opensSafely("https://exаmple.com/")        // a Cyrillic а
        && !McpElicitation.opensSafely("https://example.com/a b")
        && !McpElicitation.opensSafely("https:///nohost")
        && !McpElicitation.opensSafely("https://example.com/" + String(repeating: "x", count: 3000)))
check("what SipAI does not draw is declined unseen: another mode, a field of a type MCP does not define, codex's own app requests, a form past the card's bounds",
      McpElicitation.card(for: mcpRequest(mcpSchema, mode: "openai/form")) == nil
        && McpElicitation.card(for: mcpRequest(["type": "object",
                                                "properties": ["x": ["type": "object"]]])) == nil
        && McpElicitation.card(for: mcpRequest(["type": "object", "properties": [String: Any]()],
                                               meta: ["codex_approval_kind": "tool_suggestion"])) == nil
        && McpElicitation.card(for: mcpRequest(["type": "object", "properties": Dictionary(
            uniqueKeysWithValues: (0..<9).map { ("f\($0)", ["type": "string"] as [String: Any]) })])) == nil)
// The card's two bounds, which Settings → Help states in these numbers:
// a form past either is declined with nothing on screen.
func textFields(_ count: Int) -> McpElicitation.Card? {
    McpElicitation.card(for: mcpRequest(["type": "object", "properties": Dictionary(
        uniqueKeysWithValues: (0..<count).map { ("f\($0)", ["type": "string"] as [String: Any]) })]))
}
func choiceField(_ count: Int) -> McpElicitation.Card? {
    McpElicitation.card(for: mcpRequest(["type": "object", "properties": [
        "pick": ["type": "string", "title": "Pick one",
                 "enum": (1...count).map { "option \($0)" }]] as [String: Any]]))
}
check("a form of \(AgentQuestionForm.maxQuestions) fields is drawn, and one of \(AgentQuestionForm.maxQuestions + 1) is declined unseen",
      textFields(AgentQuestionForm.maxQuestions)?.question?.questions.count == AgentQuestionForm.maxQuestions
        && textFields(AgentQuestionForm.maxQuestions + 1) == nil)
check("a field of \(AgentQuestionForm.maxOptions) choices is drawn, and one of \(AgentQuestionForm.maxOptions + 1) is declined unseen",
      choiceField(AgentQuestionForm.maxOptions)?.question?.questions.first?.options.count == AgentQuestionForm.maxOptions
        && choiceField(AgentQuestionForm.maxOptions + 1) == nil)
let twins = McpElicitation.card(for: mcpRequest(["type": "object", "properties": [
    "a": ["type": "string", "title": "Name"], "b": ["type": "string", "title": "Name"]]]))
check("two fields asked in the same words are told apart by their names, not declined",
      twins?.question?.questions.map(\.text) == ["Name", "Name (b)"])

// MARK: - 2. The clock's pause

section("2. The turn clock leaves the waits out (TurnPause)")
let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
var pause = TurnPause()
check("no question: working time is wall-clock time",
      pause.activeElapsed(startedAt: t0, now: t0 + 10) == 10)
pause.pause(at: t0 + 10)
check("while a question waits, the count holds still",
      pause.isPaused && pause.activeElapsed(startedAt: t0, now: t0 + 25) == 10)
pause.pause(at: t0 + 12)
pause.resume(at: t0 + 30)
check("a second pause does not restart the wait; the answer ends it",
      pause.total == 20 && !pause.isPaused)
check("…and the count goes on from where it stopped",
      pause.activeElapsed(startedAt: t0, now: t0 + 35) == 15)
pause.resume(at: t0 + 40)
check("an answer with no wait open changes nothing", pause.total == 20)
pause.pause(at: t0 + 50)
check("a turn stopped mid-question is stamped without the open wait",
      pause.activeElapsed(startedAt: t0, now: t0 + 60) == 30)

// MARK: - 3. The real bridge and the real approver.py, without claude

let mcpDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUESTIONS_HARNESS_MCP_DIR"]!,
                 isDirectory: true)
let approverPath = mcpDir.appendingPathComponent("approver.py").path
let socketPath = mcpDir.appendingPathComponent("approver.sock").path
let bridge = MCPBridge()
/// The notification hook is consulted only on the way to posting one —
/// so it counts announcements. It answers "focused", so none is posted.
var announced: [String] = []
bridge.isApprovalFocused = { req in
    announced.append(req.id)
    return true
}
var policy: MCPQuestionPolicy = .ask
bridge.questionPolicy = { _ in policy }
bridge.approverCallTimeoutMs = { 12_345 }
do {
    try bridge.ensureRuntime()
} catch {
    print("FAIL  the real MCPBridge would not start: \(error)")
    exit(1)
}

func approverServerEntry() -> [String: Any] {
    guard let data = try? Data(contentsOf: mcpDir.appendingPathComponent("config.json")),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return ((obj["mcpServers"] as? [String: Any])?["sipai"] as? [String: Any]) ?? [:]
}

/// One approver process and one tools/call, the way claude makes it.
final class ApproverCall {
    let process = Process()
    private let stdout = Pipe()

    init(tool: String, input: [String: Any], session: String) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", approverPath]
        var env = ProcessInfo.processInfo.environment
        env["SIPAI_APPROVER_SOCKET"] = socketPath
        env["SIPAI_SESSION_ID"] = session
        process.environment = env
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let call: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                   "params": ["name": "approve",
                                              "arguments": ["tool_name": tool, "input": input]]]
        stdin.fileHandleForWriting.write(
            Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8) + Data("\n".utf8))
        stdin.fileHandleForWriting.write(
            (try! JSONSerialization.data(withJSONObject: call)) + Data("\n".utf8))
        try? stdin.fileHandleForWriting.close()
    }

    /// What claude would read back: the permission result, decoded.
    @MainActor func result() async -> [String: Any] {
        _ = await waitUntil(15) { !self.process.isRunning }
        if process.isRunning { process.terminate() }
        let text = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["id"] as? Int == 2,
                  let result = obj["result"] as? [String: Any],
                  let content = result["content"] as? [[String: Any]],
                  let inner = content.first?["text"] as? String,
                  let decoded = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any]
            else { continue }
            return decoded
        }
        return [:]
    }
}

@MainActor
func newPending(besides known: Set<String> = [], within seconds: TimeInterval = 10) async -> MCPApprovalRequest? {
    var found: MCPApprovalRequest?
    _ = await waitUntil(seconds) {
        found = bridge.pending.first { !known.contains($0.id) }
        return found != nil
    }
    return found
}

section("3. The bridge's answer as claude receives it (real MCPBridge → real approver.py)")
check("the question tool is claude's own name for it", MCPBridge.questionTool == "AskUserQuestion")
check("the approver's MCP config carries the per-server timeout it is handed",
      approverServerEntry()["timeout"] as? Int == 12_345, "got \(approverServerEntry())")
bridge.approverCallTimeoutMs = { nil }
try? bridge.ensureRuntime()
check("…and none when it is handed none (a claude not known to take the key)",
      approverServerEntry()["timeout"] == nil && approverServerEntry()["command"] != nil)

do {
    // Submit.
    policy = .ask
    let call = try ApproverCall(tool: "AskUserQuestion", input: askInput, session: draftUuid)
    let req = await newPending()
    check("a question reaches the bridge as a QUESTION card",
          req?.isQuestion == true && req?.question?.questions.count == 2)
    if let req {
        check("…drawn for its runner by the one ownership rule (a first turn asks under the draft's uuid)",
              bridge.pending(forSession: "a-session-id", taskUuid: draftUuid).contains { $0.id == req.id })
        check("…and announced like an approval card", announced.contains(req.id))
        bridge.setQuestionDraft(AgentQuestionDraft(answers: [q1: AgentQuestionAnswer(labels: ["Red"])], page: 1),
                                for: req.id)
        check("a half-answered card's state is kept on the bridge while the question waits",
              bridge.questionDrafts[req.id]?.page == 1)
        bridge.answerQuestion(requestId: req.id, answers: [
            q1: AgentQuestionAnswer(labels: ["Blue"]),
            q2: AgentQuestionAnswer(labels: ["Logs", "Tests"]),
        ])
        bridge.answerQuestion(requestId: req.id, answers: [:])   // a second press
        let result = await call.result()
        let updated = result["updatedInput"] as? [String: Any] ?? [:]
        check("Submit: allow, with the answers in the input claude runs the tool with",
              result["behavior"] as? String == "allow"
                && (updated["answers"] as? [String: String]) == [q1: "Blue", q2: "Logs, Tests"]
                && (updated["questions"] as? [[String: Any]])?.count == 2,
              "got \(result)")
        check("…the picked option's preview beside them",
              (updated["annotations"] as? [String: [String: String]])?[q1]?["preview"] == "[ BLUE ]\n#0000ff")
        check("…a second press changed nothing, and the card and its state are gone",
              bridge.pending.isEmpty && bridge.questionDrafts[req.id] == nil)
        bridge.setQuestionDraft(AgentQuestionDraft(page: 1), for: req.id)
        check("a card that is gone keeps no state", bridge.questionDrafts[req.id] == nil)
    }

    // Skip — the same question again, which must be asked again.
    let skipCall = try ApproverCall(tool: "AskUserQuestion", input: askInput, session: draftUuid)
    let skipReq = await newPending()
    check("the same question asked again is shown again — an answer is never remembered",
          skipReq?.isQuestion == true)
    if let skipReq { bridge.skipQuestion(requestId: skipReq.id) }
    let skipped = await skipCall.result()
    check("Skip: deny, telling the agent to choose for itself and carry on",
          skipped["behavior"] as? String == "deny"
            && skipped["message"] as? String == AgentQuestionReplies.skipped,
          "got \(skipped)")

    // Chat about this.
    let chatCall = try ApproverCall(tool: "AskUserQuestion", input: askInput, session: draftUuid)
    let chatReq = await newPending()
    if let chatReq {
        bridge.chatAboutQuestion(requestId: chatReq.id, answers: [q1: AgentQuestionAnswer(labels: ["Blue"])])
    }
    let chatted = await chatCall.result()
    check("Chat about this: deny, handing the agent the questions and telling it to ask what to clarify",
          chatted["behavior"] as? String == "deny"
            && chatted["message"] as? String == AgentQuestionReplies.chat(
                about: form, answers: [q1: AgentQuestionAnswer(labels: ["Blue"])]),
          "got \(chatted)")

    // Non-stop: no card at all.
    policy = .nonStop
    var before = announced.count
    let nonStopCall = try ApproverCall(tool: "AskUserQuestion", input: askInput, session: draftUuid)
    let nonStop = await nonStopCall.result()
    check("Non-stop: declined at once with its own words — no card, no notification",
          nonStop["behavior"] as? String == "deny"
            && nonStop["message"] as? String == AgentQuestionReplies.nonStop
            && bridge.pending.isEmpty && announced.count == before,
          "got \(nonStop)")
    let unreadableInput = input(questions: [question("Q?", options: options("A"))])
    let nonStopBadCall = try ApproverCall(tool: "AskUserQuestion", input: unreadableInput,
                                          session: draftUuid)
    let nonStopBad = await nonStopBadCall.result()
    check("…and its words win over \"could not display\": an unattended run is never told to ask in text",
          nonStopBad["message"] as? String == AgentQuestionReplies.nonStop)

    // A form the card cannot draw.
    policy = .ask
    before = announced.count
    let unreadCall = try ApproverCall(tool: "AskUserQuestion", input: unreadableInput,
                                      session: draftUuid)
    let unread = await unreadCall.result()
    check("a question the card cannot draw is declined at once — no card, no notification",
          unread["behavior"] as? String == "deny"
            && unread["message"] as? String == AgentQuestionReplies.unreadable
            && bridge.pending.isEmpty && announced.count == before,
          "got \(unread)")

    // No turn owns it.
    bridge.questionPolicy = nil
    let orphanCall = try ApproverCall(tool: "AskUserQuestion", input: askInput, session: draftUuid)
    let orphan = await orphanCall.result()
    check("a question no turn of this app owns is declined as unanswerable",
          orphan["message"] as? String == AgentQuestionReplies.unanswerable
            && bridge.pending.isEmpty)
    bridge.questionPolicy = { _ in policy }

    // Non-stop turned on while a question and an approval both wait.
    let write = try ApproverCall(tool: "Write", input: ["file_path": "/tmp/x", "content": "y"],
                                 session: draftUuid)
    let approval = await newPending()
    let asked = try ApproverCall(tool: "AskUserQuestion", input: askInput, session: draftUuid)
    let questionReq = await newPending(besides: Set([approval?.id].compactMap { $0 }))
    check("an approval and a question of one turn can wait side by side",
          approval?.isQuestion == false && questionReq?.isQuestion == true)
    bridge.declineQuestions(sessionId: nil, taskUuid: draftUuid)
    let declined = await asked.result()
    check("Non-stop turned on mid-question: the question is declined with Non-stop's words",
          declined["behavior"] as? String == "deny"
            && declined["message"] as? String == AgentQuestionReplies.nonStop)
    check("…and the turn's approval card is left alone",
          approval.map { a in bridge.pending.contains { $0.id == a.id } } == true)
    if let approval { bridge.resolve(requestId: approval.id, verdict: .allow) }
    let allowed = await write.result()
    check("…and still answers as an approval", allowed["behavior"] as? String == "allow")

    // Stop.
    let stopped = try ApproverCall(tool: "AskUserQuestion", input: askInput, session: otherUuid)
    if let req = await newPending() {
        bridge.setQuestionDraft(AgentQuestionDraft(page: 1), for: req.id)
        bridge.cancelPending(sessionId: nil, taskUuid: otherUuid)
        let result = await stopped.result()
        check("Stop: the question is denied with the rest, and its kept state dropped",
              result["behavior"] as? String == "deny"
                && bridge.pending.isEmpty && bridge.questionDrafts[req.id] == nil)
    } else {
        check("a question reached the bridge to be stopped", false)
    }
} catch {
    check("approver.py could be started", false, "\(error)")
}

// MARK: - 3b. An MCP server's form, through claude's Elicitation hook

/// One Elicitation hook run, as claude runs it: the hook input on stdin
/// (as TEXT — the order of its fields is part of what is checked), the
/// answer, if any, on stdout.
final class ElicitationHook {
    let process = Process()
    private let stdout = Pipe()

    init(inputText: String, session: String, socket: String = socketPath) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", approverPath, "--elicitation"]
        var env = ProcessInfo.processInfo.environment
        env["SIPAI_APPROVER_SOCKET"] = socket
        env["SIPAI_SESSION_ID"] = session
        process.environment = env
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(inputText.utf8))
        try? stdin.fileHandleForWriting.close()
    }

    /// The hook's output, decoded; nil when it printed nothing.
    @MainActor func output() async -> [String: Any]? {
        _ = await waitUntil(15) { !self.process.isRunning }
        if process.isRunning { process.terminate() }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

section("3b. An MCP server's form through claude's Elicitation hook (real approver.py --elicitation → real MCPBridge)")
let hookForm = #"""
{"session_id":"s","hook_event_name":"Elicitation","mcp_server_name":"reports","message":"Tell the report about you","mode":"form","requested_schema":{"type":"object","properties":{"name":{"type":"string","title":"Your name"},"subscribe":{"type":"boolean","title":"Subscribe","default":false},"color":{"type":"string","title":"Colour","oneOf":[{"const":"red","title":"Red"},{"const":"blue","title":"Blue"}]}},"required":["name","color"]}}
"""#
let hookLink = #"""
{"hook_event_name":"Elicitation","mcp_server_name":"reports","message":"Sign in","mode":"url","url":"https://example.com/sign-in","elicitation_id":"e-1"}
"""#
do {
    policy = .ask
    let before = announced.count
    let hook = try ElicitationHook(inputText: hookForm, session: draftUuid)
    let req = await newPending()
    let form = req?.question
    check("the hook's form reaches the bridge as an MCP form card, filed under the turn (the draft's uuid)",
          req?.agentKey == "claude_code" && form?.asker == "reports" && req?.taskUuid == draftUuid
            && bridge.pending(forSession: "a-session-id", taskUuid: draftUuid).contains { $0.id == req?.id }
            && announced.count == before + 1)
    check("…its fields in the order the server listed them — the approver keeps it beside the request",
          form?.questions.compactMap(\.id) == ["name", "subscribe", "color"])
    check("…and the notification names the server, in its words",
          req.map { MCPBridge.notificationText(for: $0, agent: "Claude Code").title }
            == McpElicitation.Words.requestsInput("reports"))
    if let req, let form {
        var answers = form.initialAnswers
        answers[form.questions[0].text] = AgentQuestionAnswer(otherText: "Ada", otherPicked: true)
        answers[form.questions[2].text] = AgentQuestionAnswer(labels: ["Blue"])
        bridge.answerQuestion(requestId: req.id, answers: answers)
    }
    let out = await hook.output()
    let specific = out?["hookSpecificOutput"] as? [String: Any]
    check("answered: the hook hands claude accept with the form, typed — the boolean's default included",
          specific?["hookEventName"] as? String == "Elicitation" && specific?["action"] as? String == "accept"
            && jsonText(specific?["content"] ?? [:]) == #"{"color":"blue","name":"Ada","subscribe":false}"#,
          "\(String(describing: out))")

    let declineHook = try ElicitationHook(inputText: hookForm, session: draftUuid)
    if let req = await newPending() { bridge.skipQuestion(requestId: req.id) }
    let declined = (await declineHook.output())?["hookSpecificOutput"] as? [String: Any]
    check("Decline: the hook hands claude decline, with no form",
          declined?["action"] as? String == "decline" && declined?["content"] == nil, "\(String(describing: declined))")

    let linkHook = try ElicitationHook(inputText: hookLink, session: draftUuid)
    let linkReq = await newPending()
    check("a link is a link card, and Non-stop's policy decides it like a question",
          linkReq?.linkContent == LinkCardContent(asker: "reports", message: "Sign in",
                                                  url: "https://example.com/sign-in", opens: true)
            && linkReq?.asksQuestion == true)
    if let linkReq { bridge.choose(requestId: linkReq.id, optionId: LinkCardContent.acceptId) }
    let opened = (await linkHook.output())?["hookSpecificOutput"] as? [String: Any]
    check("…done in the browser, the hook hands claude accept", opened?["action"] as? String == "accept",
          "\(String(describing: opened))")

    policy = .nonStop
    let quiet = announced.count
    let nonStopHook = try ElicitationHook(inputText: hookForm, session: draftUuid)
    let nonStopOut = (await nonStopHook.output())?["hookSpecificOutput"] as? [String: Any]
    check("Non-stop: no card, no notification — the server is declined",
          nonStopOut?["action"] as? String == "decline" && bridge.pending.isEmpty && announced.count == quiet,
          "\(String(describing: nonStopOut))")
    let nonStopLink = try ElicitationHook(inputText: hookLink, session: draftUuid)
    let nonStopLinkOut = (await nonStopLink.output())?["hookSpecificOutput"] as? [String: Any]
    check("…a link too", nonStopLinkOut?["action"] as? String == "decline" && bridge.pending.isEmpty)
    policy = .ask

    // A server's yes-or-no: shown, and named in its notification, as the
    // server's question; declined under Non-stop like its other questions.
    let hookConfirm = #"{"hook_event_name":"Elicitation","mcp_server_name":"reports","message":"Send the report now?","mode":"form","requested_schema":{"type":"object","properties":{}}}"#
    let confirmHook = try ElicitationHook(inputText: hookConfirm, session: draftUuid)
    let confirmReq = await newPending()
    let confirmBanner = confirmReq.map { MCPBridge.notificationText(for: $0, agent: "Claude Code") }
    check("a server's yes-or-no reaches the bridge as a card, its notification naming the server in its words",
          confirmReq?.permissionContent != nil
            && confirmBanner?.title == McpElicitation.Words.requestsInput("reports")
            && confirmBanner?.body == "Send the report now?",
          "\(String(describing: confirmBanner))")
    if let confirmReq { bridge.choose(requestId: confirmReq.id, optionId: "accept") }
    let confirmed = (await confirmHook.output())?["hookSpecificOutput"] as? [String: Any]
    check("…allowed, the hook hands claude accept with an empty form",
          confirmed?["action"] as? String == "accept" && jsonText(confirmed?["content"] ?? [:]) == "{}",
          "\(String(describing: confirmed))")
    policy = .nonStop
    let quietConfirm = announced.count
    let nonStopConfirm = try ElicitationHook(inputText: hookConfirm, session: draftUuid)
    let nonStopConfirmOut = (await nonStopConfirm.output())?["hookSpecificOutput"] as? [String: Any]
    check("Non-stop: a server's yes-or-no is declined like its other questions — no card, no notification",
          nonStopConfirmOut?["action"] as? String == "decline" && bridge.pending.isEmpty
            && announced.count == quietConfirm,
          "\(String(describing: nonStopConfirmOut)), \(bridge.pending.count) card(s) up")
    // Whatever a build that still waits on it left up.
    bridge.cancelPending(sessionId: nil, taskUuid: draftUuid)
    _ = await nonStopConfirm.output()
    policy = .ask

    let odd = #"{"hook_event_name":"Elicitation","mcp_server_name":"reports","message":"x","mode":"form","requested_schema":{"type":"object","properties":{"x":{"type":"object"}}}}"#
    let oddHook = try ElicitationHook(inputText: odd, session: draftUuid)
    let oddOut = (await oddHook.output())?["hookSpecificOutput"] as? [String: Any]
    check("a form SipAI does not draw is declined at once — no card",
          oddOut?["action"] as? String == "decline" && bridge.pending.isEmpty, "\(String(describing: oddOut))")

    let stopHook = try ElicitationHook(inputText: hookForm, session: otherUuid)
    if await newPending() != nil { bridge.cancelPending(sessionId: nil, taskUuid: otherUuid) }
    let stopOut = (await stopHook.output())?["hookSpecificOutput"] as? [String: Any]
    check("Stop: the form is cancelled with the rest of the turn's cards",
          stopOut?["action"] as? String == "cancel" && bridge.pending.isEmpty, "\(String(describing: stopOut))")

    let lost = try ElicitationHook(inputText: hookForm, session: draftUuid,
                                   socket: mcpDir.appendingPathComponent("nobody.sock").path)
    let lostOut = await lost.output()
    check("SipAI not there: the hook prints nothing, and claude answers the server as it would without it",
          lostOut == nil && lost.process.terminationStatus == 0)
} catch {
    check("approver.py --elicitation could be started", false, "\(error)")
}

check("the Elicitation hook rides a turn's settings only for a claude measured to run it, with a wait that outlasts the user and stays within a timer's reach",
      { () -> Bool in
          bridge.bridgesMcpForms = { false }
          let off = bridge.launchSettings(sessionId: nil, taskUuid: draftUuid)
          bridge.bridgesMcpForms = { true }
          let on = bridge.launchSettings(sessionId: nil, taskUuid: draftUuid)
          let entry = ((on["hooks"] as? [String: Any])?["Elicitation"] as? [[String: Any]])?.first
          let hook = (entry?["hooks"] as? [[String: Any]])?.first
          let seconds = hook?["timeout"] as? Int ?? 0
          return (off["hooks"] as? [String: Any])?["Elicitation"] == nil
              && (hook?["command"] as? String)?.hasSuffix("--elicitation") == true
              && seconds >= 3600 && Double(seconds) * 1000 < Double(Int32.max)
      }())

// MARK: - 4. The real claude, end to end, token-free

func findClaude() -> String? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = path.split(separator: ":").map { String($0) + "/claude" }
        + [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

struct Turn {
    let dir: URL
    let claude: Process
    let server: Process

    /// Every tool result claude sent the endpoint, with its error flag.
    /// Claude appends its own reminder blocks to a result's text, so a
    /// check matches a prefix, never the whole of it.
    var toolResults: [(text: String, isError: Bool)] {
        let rec = dir.appendingPathComponent("rec")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: rec.path))?.sorted() ?? []
        var out: [(text: String, isError: Bool)] = []
        for file in files {
            guard let data = try? Data(contentsOf: rec.appendingPathComponent(file)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = obj["body"] as? [String: Any],
                  let messages = body["messages"] as? [[String: Any]] else { continue }
            for message in messages {
                guard let blocks = message["content"] as? [[String: Any]] else { continue }
                for block in blocks where block["type"] as? String == "tool_result" {
                    var text = ""
                    if let s = block["content"] as? String { text = s }
                    if let parts = block["content"] as? [[String: Any]] {
                        text = parts.compactMap { $0["text"] as? String }.joined()
                    }
                    let isError = block["is_error"] as? Bool ?? false
                    if !out.contains(where: { $0.text == text && $0.isError == isError }) {
                        out.append((text, isError))
                    }
                }
            }
        }
        return out
    }

    func stop() {
        if claude.isRunning { claude.terminate() }
        if server.isRunning { server.terminate() }
    }
}

/// One claude turn over the fake endpoint, under a throwaway config
/// directory, wired to the REAL bridge exactly as AgentRunner wires it:
/// `argsForClaude()` + `environmentOverlay(sessionIdOrTaskUuid:)`.
@MainActor
func startTurn(_ name: String, claudePath: String, mode: String, identity: String,
               steps: [[String: Any]], extraEnvironment: [String: String] = [:],
               extraMcpConfig: String? = nil, settings: [String: Any] = [:],
               cwd: URL? = nil) throws -> Turn {
    let dir = work.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("rec"),
                                            withIntermediateDirectories: true)
    let runDir = cwd ?? dir.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    let cfg = dir.appendingPathComponent("cfg", isDirectory: true)
    try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
    let stepsFile = dir.appendingPathComponent("steps.json")
    try JSONSerialization.data(withJSONObject: steps).write(to: stepsFile)

    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    server.arguments = ["python3",
                        here.appendingPathComponent("../ApprovalCards/plan_server.py").standardized.path,
                        dir.appendingPathComponent("rec").path, stepsFile.path]
    let serverOut = Pipe()
    server.standardOutput = serverOut
    server.standardError = FileHandle.nullDevice
    try server.run()
    var portLine = Data()
    while !portLine.contains(0x0A) {
        let chunk = serverOut.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        portLine.append(chunk)
    }
    let port = String(decoding: portLine, as: UTF8.self)
        .replacingOccurrences(of: "PORT=", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

    let claude = Process()
    claude.executableURL = URL(fileURLWithPath: claudePath)
    var arguments = ["-p", "Ask the harness question.", "--output-format", "stream-json", "--verbose",
                     "--model", "claude-sonnet-4-5", "--permission-mode", mode]
    // A server of the user's own rides the same variadic `--mcp-config`
    // as the approver's, right after it.
    for argument in bridge.argsForClaude() {
        arguments.append(argument)
        if let extraMcpConfig, argument.hasSuffix("config.json") { arguments.append(extraMcpConfig) }
    }
    claude.arguments = ClaudeSettingsArgv.merging(settings, into: arguments)
    var env = ProcessInfo.processInfo.environment
    env["CLAUDE_CONFIG_DIR"] = cfg.path
    env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:\(port)"
    env["ANTHROPIC_API_KEY"] = "sk-ant-harness-junk"
    for (key, value) in bridge.environmentOverlay(sessionIdOrTaskUuid: identity) { env[key] = value }
    for (key, value) in extraEnvironment { env[key] = value }
    claude.environment = env
    claude.currentDirectoryURL = runDir
    claude.standardInput = FileHandle.nullDevice
    claude.standardOutput = FileHandle.nullDevice
    claude.standardError = FileHandle.nullDevice
    try claude.run()
    return Turn(dir: dir, claude: claude, server: server)
}

section("4. The real claude over a fake endpoint, through the real bridge (no tokens)")
if let claudePath = findClaude() {
    note("claude: \(claudePath)")
    let askStep: [String: Any] = ["name": "AskUserQuestion", "input": askInput]
    let oldDoor = "has no interface to collect an answer"
    policy = .ask
    do {
        // 4a. Answered, in the default mode.
        let a = try startTurn("answered", claudePath: claudePath, mode: "default",
                              identity: draftUuid, steps: [askStep])
        let reqA = await newPending(within: 90)
        check("4a. the real claude's question reaches the bridge as a question card",
              reqA?.isQuestion == true)
        if let reqA {
            bridge.answerQuestion(requestId: reqA.id, answers: [
                q1: AgentQuestionAnswer(labels: ["Blue"]),
                q2: AgentQuestionAnswer(labels: ["Logs", "Tests"]),
            ])
        }
        _ = await waitUntil(60) { !a.claude.isRunning }
        let answered = a.toolResults
        check("4a. answered: claude tells the model the user's choices, as picked labels",
              answered.contains {
                  $0.text.hasPrefix("Your questions have been answered: ")
                      && $0.text.contains("\"\(q1)\"=\"Blue\"")
                      && $0.text.contains("\"\(q2)\"=\"Logs, Tests\"") && !$0.isError
              },
              "got \(answered.map(\.text))")
        check("4a. …with the picked option's preview",
              answered.contains { $0.text.contains("selected preview:") })
        a.stop()

        // 4a. Claude's question STOPS the turn: its question tool always
        // asks through the permission prompt, which the approver holds
        // until the card is answered, and claude cannot go on to the model
        // without the tool's result. (Codex can ask without stopping — its
        // card says it keeps working; see CodexAppServerBridge AQ.)
        let held = try startTurn("held", claudePath: claudePath, mode: "default",
                                 identity: draftUuid, steps: [askStep])
        let reqHeld = await newPending(within: 90)
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        let resultsWhileUp = held.toolResults
        check("4a. while the card is up claude waits: 4 s on it is still running and has sent the model nothing of the question",
              reqHeld?.isQuestion == true && held.claude.isRunning && resultsWhileUp.isEmpty,
              "card \(reqHeld != nil), running \(held.claude.isRunning), results \(resultsWhileUp.map(\.text))")
        if let reqHeld {
            bridge.answerQuestion(requestId: reqHeld.id, answers: [q1: AgentQuestionAnswer(labels: ["Red"])])
        }
        _ = await waitUntil(60) { !held.claude.isRunning }
        check("4a. …and the answer is what lets it go on",
              held.toolResults.contains { $0.text.hasPrefix("Your questions have been answered: ") },
              "got \(held.toolResults.map(\.text))")
        held.stop()

        // 4b. Bypass still asks — and the user's own words.
        let b = try startTurn("bypass-own-words", claudePath: claudePath, mode: "bypassPermissions",
                              identity: draftUuid, steps: [askStep])
        let reqB = await newPending(within: 90)
        check("4b. Bypass still stops for a question — it reaches the bridge", reqB?.isQuestion == true)
        if let reqB {
            bridge.answerQuestion(requestId: reqB.id, answers: [
                q1: AgentQuestionAnswer(otherText: "Green, please", otherPicked: true),
            ])
        }
        _ = await waitUntil(60) { !b.claude.isRunning }
        check("4b. the user's own words: claude asks the model to read them carefully",
              b.toolResults.contains {
                  $0.text.hasPrefix("The user answered: ") && $0.text.contains("\"\(q1)\"=\"Green, please\"")
              },
              "got \(b.toolResults.map(\.text))")
        b.stop()

        // 4c. Skip, in plan mode (where questions come most).
        let c = try startTurn("plan-skip", claudePath: claudePath, mode: "plan",
                              identity: draftUuid, steps: [askStep])
        let reqC = await newPending(within: 90)
        check("4c. Plan mode's question reaches the bridge", reqC?.isQuestion == true)
        if let reqC { bridge.skipQuestion(requestId: reqC.id) }
        _ = await waitUntil(60) { !c.claude.isRunning }
        check("4c. Skip: the model reads the card's words verbatim, as an error result",
              c.toolResults.contains { $0.text.hasPrefix(AgentQuestionReplies.skipped) && $0.isError },
              "got \(c.toolResults.map(\.text))")
        c.stop()

        // 4c2. Chat about this.
        let c2 = try startTurn("chat-about", claudePath: claudePath, mode: "default",
                               identity: draftUuid, steps: [askStep])
        let reqC2 = await newPending(within: 90)
        if let reqC2 { bridge.chatAboutQuestion(requestId: reqC2.id, answers: [:]) }
        _ = await waitUntil(60) { !c2.claude.isRunning }
        check("4c. Chat about this: the model reads the card's words verbatim, as an error result",
              c2.toolResults.contains {
                  $0.text.hasPrefix("The user wants to talk these questions over before answering them.")
                      && $0.text.contains("\"\(q1)\"") && $0.isError
              },
              "got \(c2.toolResults.map(\.text))")
        c2.stop()

        // 4d. Non-stop: no card.
        policy = .nonStop
        let announcedBefore = announced.count
        let d = try startTurn("non-stop", claudePath: claudePath, mode: "default",
                              identity: draftUuid, steps: [askStep])
        _ = await waitUntil(90) { !d.claude.isRunning }
        check("4d. Non-stop: no card, and the model reads Non-stop's words",
              announced.count == announcedBefore && bridge.pending.isEmpty
                && d.toolResults.contains { $0.text.hasPrefix(AgentQuestionReplies.nonStop) },
              "got \(d.toolResults.map(\.text))")
        d.stop()
        policy = .ask

        // 4e. dontAsk: claude refuses by itself.
        let e = try startTurn("dont-ask", claudePath: claudePath, mode: "dontAsk",
                              identity: draftUuid, steps: [askStep])
        _ = await waitUntil(90) { !e.claude.isRunning }
        check("4e. dontAsk: claude refuses the question itself — nothing reaches SipAI",
              announced.count == announcedBefore && bridge.pending.isEmpty
                && e.toolResults.contains { $0.text.contains("don't ask mode") },
              "got \(e.toolResults.map(\.text))")
        e.stop()

        let everything = [a, b, c, d, e].flatMap(\.toolResults)
        check("negative control: the old door's words never reach the model",
              !everything.contains { $0.text.contains(oldDoor) })

        // 4g. An MCP server's form, through the Elicitation hook the bridge
        // adds to a turn's settings. The tool's own permission comes first.
        let formServer = here.appendingPathComponent("mcp_form_server.py").path
        let formLog = work.appendingPathComponent("form-server.log")
        let formConfig = jsonText(["mcpServers": ["forms": [
            "type": "stdio", "command": "/usr/bin/env", "args": ["python3", formServer, formLog.path]]]])
        let formStep: [String: Any] = ["name": "mcp__forms__ask_form", "input": [String: Any]()]
        /// The next card of `turn` that is not the tool's own permission —
        /// which is allowed on the way, as the user would — or nil once
        /// the turn is over without one.
        func nextServerCard(of turn: Turn, within seconds: TimeInterval) async -> MCPApprovalRequest? {
            var found: MCPApprovalRequest?
            _ = await waitUntil(seconds) {
                for req in bridge.pending {
                    if req.isFromApprover && !req.isQuestion {
                        bridge.resolve(requestId: req.id, verdict: .allow)
                    } else {
                        found = req
                        return true
                    }
                }
                return !turn.claude.isRunning
            }
            return found
        }
        bridge.bridgesMcpForms = { true }
        let g = try startTurn("mcp-form", claudePath: claudePath, mode: "default", identity: draftUuid,
                              steps: [formStep], extraMcpConfig: formConfig,
                              settings: bridge.launchSettings(sessionId: nil, taskUuid: draftUuid))
        let formReq = await nextServerCard(of: g, within: 90)
        check("4g. the real claude's MCP form reaches the bridge as a form card naming the server",
              formReq?.question?.asker == "forms" && formReq?.agentKey == "claude_code",
              "got \(String(describing: formReq?.toolName))")
        if let formReq, let form = formReq.question {
            var answers = form.initialAnswers
            for q in form.questions {
                switch q.id {
                case "name": answers[q.text] = AgentQuestionAnswer(otherText: "Ada", otherPicked: true)
                case "color": answers[q.text] = AgentQuestionAnswer(labels: ["Blue"])
                case "count": answers[q.text] = AgentQuestionAnswer(otherText: "3", otherPicked: true)
                default: break
                }
            }
            bridge.answerQuestion(requestId: formReq.id, answers: answers)
        }
        _ = await waitUntil(60) { !g.claude.isRunning }
        check("4g. …and the server gets the answer, typed as its schema types it",
              g.toolResults.contains {
                  $0.text.contains(#"ELICITED {"action": "accept", "content": {"color": "blue", "count": 3, "name": "Ada", "subscribe": false}}"#)
              },
              "got \(g.toolResults.map(\.text))")
        g.stop()

        // 4h. The control: launched without the hook — what a claude below
        // the floor gets — claude cancels the form itself, unseen.
        bridge.bridgesMcpForms = { false }
        let h = try startTurn("mcp-form-no-hook", claudePath: claudePath, mode: "default", identity: draftUuid,
                              steps: [formStep], extraMcpConfig: formConfig,
                              settings: bridge.launchSettings(sessionId: nil, taskUuid: draftUuid))
        let stray = await nextServerCard(of: h, within: 90)
        _ = await waitUntil(60) { !h.claude.isRunning }
        check("4h. negative control: without the hook, claude cancels the server's form — no card",
              stray == nil && h.toolResults.contains { $0.text.contains(#"ELICITED {"action": "cancel"}"#) },
              "card \(String(describing: stray?.id)), got \(h.toolResults.map(\.text))")
        h.stop()

        // 4i. "Allow Always" on a server's tool, as a launch carries it:
        // claude's own rule for the tool, reported by its PermissionRequest
        // hook and handed back, which claude saves to the folder — so the
        // same tool runs unasked for the rest of the turn and in a later
        // session there.
        bridge.reportsPermissionSuggestions = { true }
        let alwaysLog = work.appendingPathComponent("always-server.log")
        let alwaysConfig = jsonText(["mcpServers": ["forms": [
            "type": "stdio", "command": "/usr/bin/env", "args": ["python3", formServer, alwaysLog.path]]]])
        let writeStep: [String: Any] = ["name": "mcp__forms__write_note", "input": [String: Any]()]
        /// How many times the server was asked to run `write_note`.
        func writeCalls() -> Int {
            let text = (try? String(contentsOf: alwaysLog, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").filter {
                $0.contains(#""method": "tools/call""#) && $0.contains(#""name": "write_note""#)
            }.count
        }
        // The control first: answered with a plain Allow, the second call
        // asks again — which is what makes "runs without asking" below
        // Allow Always's doing.
        let onceConfig = jsonText(["mcpServers": ["forms": [
            "type": "stdio", "command": "/usr/bin/env",
            "args": ["python3", formServer, work.appendingPathComponent("once-server.log").path]]]])
        let once = try startTurn("mcp-allow-once", claudePath: claudePath, mode: "default",
                                 identity: otherUuid, steps: [writeStep, writeStep],
                                 extraMcpConfig: onceConfig,
                                 settings: bridge.launchSettings(sessionId: nil, taskUuid: otherUuid))
        var onceCards = 0
        _ = await waitUntil(90) {
            for req in bridge.pending {
                onceCards += 1
                bridge.resolve(requestId: req.id, verdict: onceCards == 1 ? .allow : .deny)
            }
            return onceCards >= 2 || !once.claude.isRunning
        }
        _ = await waitUntil(30) { !once.claude.isRunning }
        check("4i. negative control: answered with a plain Allow, the tool's second call asks again",
              onceCards == 2, "cards: \(onceCards)")
        once.stop()
        let i = try startTurn("mcp-always", claudePath: claudePath, mode: "default", identity: otherUuid,
                              steps: [writeStep, writeStep], extraMcpConfig: alwaysConfig,
                              settings: bridge.launchSettings(sessionId: nil, taskUuid: otherUuid))
        let toolReq = await newPending(within: 90)
        check("4i. the server's tool asks on claude's permission card",
              toolReq?.toolName == "mcp__forms__write_note" && toolReq?.isFromApprover == true
                && toolReq?.isQuestion == false,
              "got \(String(describing: toolReq?.toolName))")
        if let toolReq {
            // The hook runs beside the approve call; its report lands a
            // moment after the card.
            _ = await waitUntil(10) { !toolReq.alwaysOffer.isEmpty }
            let offer = toolReq.alwaysOffer
            var offered: [String] = []
            if case .rules(let rules)? = offer.first?.change {
                offered = rules.map { ClaudePermissionSuggestions.ruleString($0) }
            }
            check("4i. …and claude's own rule for it is on the card: the tool, saved to the folder",
                  offer.count == 1 && offer.first?.destination == "localSettings"
                    && offered == ["mcp__forms__write_note"],
                  "offer \(offer)")
            bridge.resolve(requestId: toolReq.id, verdict: .allowAlways)
            var askedAgain = false
            _ = await waitUntil(60) {
                if !bridge.pending.isEmpty { askedAgain = true }
                return askedAgain || !i.claude.isRunning
            }
            if askedAgain, let extra = bridge.pending.first { bridge.resolve(requestId: extra.id, verdict: .deny) }
            _ = await waitUntil(30) { !i.claude.isRunning }
            check("4i. after Allow Always the tool's second call runs WITHOUT asking",
                  !askedAgain && writeCalls() == 2, "asked again: \(askedAgain), calls: \(writeCalls())")
            let local = i.dir.appendingPathComponent("work/.claude/settings.local.json")
            let saved = (try? String(contentsOf: local, encoding: .utf8)) ?? ""
            check("4i. …because claude saved its own rule to the folder's settings",
                  saved.contains("mcp__forms__write_note"), "settings.local.json: \(saved)")
            check("4i. …and SipAI's own memory holds nothing for it",
                  (bridge.cache[otherUuid] ?? [:]).isEmpty)
            // A later session in that folder — a new process, a new id.
            let later = try startTurn("mcp-always-later", claudePath: claudePath, mode: "default",
                                      identity: draftUuid, steps: [writeStep], extraMcpConfig: alwaysConfig,
                                      cwd: i.dir.appendingPathComponent("work"))
            var laterAsked = false
            _ = await waitUntil(90) {
                if !bridge.pending.isEmpty { laterAsked = true }
                return laterAsked || !later.claude.isRunning
            }
            if laterAsked, let extra = bridge.pending.first { bridge.resolve(requestId: extra.id, verdict: .deny) }
            _ = await waitUntil(30) { !later.claude.isRunning }
            check("4i. a later session in that folder runs the tool without asking either",
                  !laterAsked && writeCalls() == 3, "asked: \(laterAsked), calls: \(writeCalls())")
            later.stop()
        }
        i.stop()
        bridge.reportsPermissionSuggestions = nil

        // 4f. The idle limit — slow, so on request.
        if ProcessInfo.processInfo.environment["SIPAI_QUESTIONS_SLOW"] == "1" {
            let idle = ["CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT": "3000"]   // floored at 30 s by claude
            bridge.approverCallTimeoutMs = { nil }
            try bridge.ensureRuntime()
            let f1 = try startTurn("idle-no-key", claudePath: claudePath, mode: "default",
                                   identity: draftUuid, steps: [askStep], extraEnvironment: idle)
            let held1 = await newPending(within: 90)
            _ = await waitUntil(90) { !f1.claude.isRunning }
            check("4f. without the key, claude abandons a question left silent past its idle limit",
                  f1.toolResults.contains { $0.text.contains("sent no response or progress") },
                  "got \(f1.toolResults.map(\.text))")
            if let held1 { bridge.skipQuestion(requestId: held1.id) }
            f1.stop()

            bridge.approverCallTimeoutMs = { 60_000 }
            try bridge.ensureRuntime()
            let f2 = try startTurn("idle-with-key", claudePath: claudePath, mode: "default",
                                   identity: draftUuid, steps: [askStep], extraEnvironment: idle)
            let held2 = await newPending(within: 90)
            try? await Task.sleep(nanoseconds: 40_000_000_000)
            if let held2 {
                bridge.answerQuestion(requestId: held2.id, answers: [q1: AgentQuestionAnswer(labels: ["Red"])])
            }
            _ = await waitUntil(60) { !f2.claude.isRunning }
            check("4f. with the approver's per-server timeout, the same 40 s wait is answered",
                  f2.toolResults.contains { $0.text.hasPrefix("Your questions have been answered: ") },
                  "got \(f2.toolResults.map(\.text))")
            f2.stop()
            bridge.approverCallTimeoutMs = { nil }
        } else {
            note("4f. the idle-limit check is slow (about 80 s); SIPAI_QUESTIONS_SLOW=1 runs it")
        }
    } catch {
        check("a claude turn could be started", false, "\(error)")
    }
} else {
    print("  SKIP  claude is not installed")
}

// MARK: - 5. The wiring, read from the sources

section("5. The wiring (read from the shipping sources)")
let bridgeSource = source("SipAI/Models/MCPBridge.swift")
let view = source("SipAI/Views/Chat/AgentSessionView.swift")
let card = source("SipAI/Views/Chat/AgentQuestionCard.swift")
let composer = source("SipAI/Views/Chat/AgentComposer.swift")
let runner = source("SipAI/Models/AgentRunner.swift")
let manager = source("SipAI/Models/AgentManager.swift")
let launchOptions = source("SipAI/Models/AgentLaunchOptions.swift")
let config = source("SipAI/Models/ConfigManager.swift")
let sidebar = source("SipAI/Views/Sidebar/AgentSessionsSection.swift")
let reader = source("SipAI/Models/AgentSession.swift")
let project = source("SipAI.xcodeproj/project.pbxproj")
check("anchor: the sources were read", !bridgeSource.isEmpty && !view.isEmpty && !card.isEmpty
        && !composer.isEmpty && !runner.isEmpty && !manager.isEmpty)

let door = slice(bridgeSource, from: "let isQuestion = toolName == Self.questionTool",
                 to: "req.semaphore.wait()")
check("bridge: the old door that declined every question is gone",
      !bridgeSource.contains("nonInteractiveTools"))
// The step is `enqueue`'s, one for every front end that asks — the
// approver's socket door and codex's and kimi's own protocols alike.
let enqueueBody = slice(bridgeSource, from: "func enqueue(_ req: MCPApprovalRequest) {", to: "\n    }\n")
check("bridge: a question's fate is decided in the same MainActor step that would append it, and only an appended request is announced",
      occurrences("DispatchQueue.main.async", in: door) == 1
        && door.contains("self.enqueue(req)")
        && enqueueBody.contains("questionRefusal(for: req)")
        && enqueueBody.contains("pending.append(req)\n")
        && enqueueBody.contains("maybePostNotification(for: req)")
        && !enqueueBody.contains("DispatchQueue") && !enqueueBody.contains("Task {")
        && !enqueueBody.contains("await "))
check("bridge: an answered question runs with the answered input",
      bridgeSource.contains("? (req.inputOnAllow ?? toolInput) : nil"))
check("bridge: a question is never answered from the always-cache",
      door.contains("if !isQuestion {") && door.contains("lookupCache(req)"))
check("view: a question gets the question card; the plan and permission cards keep theirs",
      view.contains("} else if let form = req.question {")
        && view.contains("AgentQuestionCard(request: req, form: form, agentName: agentName,")
        && view.contains("savedDraft: mcpBridge.questionDrafts[req.id])")
        && view.contains("PlanApprovalCard(request: req,") && view.contains("ToolApprovalCard(request: req,"))
check("card: everything the agent wrote is drawn verbatim",
      card.contains("Text(verbatim: question.text)") && card.contains("Text(verbatim: option.label)")
        && card.contains("Text(verbatim: option.description)")
        && !card.contains("Text(question.") && !card.contains("Text(option."))
check("card: no button is a default or a cancel action — Return comes from the key monitor under its rules, and Esc is not bound",
      !card.contains(".defaultAction") && !card.contains(".cancelAction")
        && !card.contains(".keyboardShortcut("))
check("card: it hears the monitor by its own request id, and only the card that owns the keys shows where they are",
      card.contains(".onReceive(keys.pressed)") && card.contains("guard press.card == request.id else { return }")
        && card.contains("ownsKeys && stop == candidate"))
check("card: it never takes the keyboard from the message box by itself",
      !card.contains("makeFirstResponder"))
check("card: a click on an option of a multi-select leaves Return on the main button",
      card.contains("stop = question.multiSelect ? .primary : .option(index)"))
check("card: \"Chat about this\" goes through the bridge with the answers so far",
      card.contains("mcpBridge.chatAboutQuestion(requestId: request.id, answers: draft.answers)"))
check("card: its state is written to the bridge on every change, never on the way out",
      card.contains(".onChange(of: draft)") && card.contains("mcpBridge.setQuestionDraft(new, for: request.id)")
        && !card.contains("onDisappear"))
let footer = slice(composer, from: "private var nonStopFooter: some View {", to: "\n    }\n")
// The switch is drawn for any agent that can ask a question in some mode
// on offer — claude always, codex and kimi once one of their asking modes
// is — and is live only in a mode that can ask.
check("composer: the Non-stop switch sits under the mode rows, wherever a mode on offer can ask",
      composer.contains("}, footer: { nonStopFooter })") && footer.contains("if nonStopOffered {")
        && footer.contains("enabled: modeAsksQuestions"))
check("composer: the clock holds still while a question waits",
      composer.contains("pausedAt: turnPausedAt,")
        && composer.contains("if let startedAt, let pausedAt {"))
check("runner: the frozen total is working time, with an open wait left out",
      runner.contains("lastTurnDuration = userWait.activeElapsed(startedAt: startedAt, now: Date())"))
check("runner: every status change re-derives the pause; a send takes the turn's Non-stop",
      slice(runner, from: "private func setStatus(_ new: RunStatus) {", to: "\n    }\n")
        .contains("syncUserWait()")
        && runner.contains("nonStop = options.nonStop"))
let syncBody = slice(runner, from: "func syncUserWait() {", to: "\n    }\n")
check("runner: the clock pauses while ANY card of its turn is up — a question, a plan, a permission",
      syncBody.contains("status.isRunning && bridge.pending.contains {")
        && syncBody.contains("bridge.belongs($0, toSession: sessionId, taskUuid: taskUuid)")
        && !syncBody.contains("isQuestion"))
let policyBody = slice(manager, from: "private func questionPolicy(for req: MCPApprovalRequest)",
                       to: "\n    }\n")
check("manager: a question is shown only to a live child the user has not stopped",
      policyBody.contains("runner.hasLiveChild, !runner.turnWasStoppedByUser")
        && policyBody.contains("return runner.nonStop ? .nonStop : .ask"))
check("manager: the per-server timeout is written only for a claude measured to take it",
      manager.contains("approverCallTimeoutFloor = CLIVersion.parse(\"2.1.281\")")
        && manager.contains("installed >= floor"))
check("manager: one subscription keeps every runner's pause in step with the bridge",
      manager.contains("pendingSink = bridge.$pending"))
check("options: a scheduled run is Non-stop only when its task says so — never turned on by SipAI",
      slice(launchOptions, from: "static func scheduledRun(", to: "return options")
        .contains("options.nonStop = nonStop")
        && !slice(launchOptions, from: "static func scheduledRun(", to: "return options")
            .contains("options.nonStop = true"))
check("config: non_stop in both prefs maps, read and written",
      occurrences("nonStop: prefs[\"non_stop\"] == \"1\"", in: config) == 2
        && occurrences("if options.nonStop { prefs[\"non_stop\"] = \"1\" }", in: config) == 2)
// A pick on the chips is saved where it is made — the composer's
// binding — never inferred later from a change of `launchOptions`.
let saveUserPickBody = slice(view, from: "private func saveUserPick(_ new: AgentLaunchOptions, replacing old: AgentLaunchOptions) {", to: "\n    }\n")
check("view: a flip of the switch reaches the turn in flight",
      view.contains("options: userPicks,")
        && saveUserPickBody.contains("currentRunner?.setNonStop(new.nonStop)"))
let seedBody = slice(view, from: "private func applySeededOptions(_ options: AgentLaunchOptions) {", to: "\n    }\n")
check("view: a running turn's own Non-stop is what its chip shows — only while it runs",
      seedBody.contains("if let runner = currentRunner, runner.status.isRunning {")
        && seedBody.contains("options.nonStop = runner.nonStop"))
let restoreBody = slice(view, from: "private func restoreNonStopPick() {", to: "\n    }\n")
let savedPickBody = slice(view, from: "private func savedNonStopPick() -> Bool {", to: "\n    }\n")
check("view: when the turn ends the switch goes back to the user's own pick, and nothing is written",
      view.contains(".onChange(of: currentRunner?.status.isRunning ?? false)")
        && savedPickBody.contains("config.agentSessionLaunchOptions(for: id)")
        && restoreBody.contains("next.nonStop = savedNonStopPick()")
        && restoreBody.contains("applySeededOptions(next)")
        && !restoreBody.contains("setAgent"))
// The switch's overlay is not the user's pick. An edit of another chip,
// or a card's mode switch, made while a scheduled run is watched used to
// save the run's Non-stop as the session's pick AND the agent's sticky
// one — every later new session then started Non-stop.
let ownPickBody = slice(view, from: "private func ownPick(_ options: AgentLaunchOptions,", to: "\n    }\n")
check("view: an edit made while a turn runs saves the user's OWN Non-stop pick, unless the edit flipped the switch",
      saveUserPickBody.contains("let picked = ownPick(new, nonStopFlipped: old.nonStop != new.nonStop)")
        && saveUserPickBody.contains("config.setAgentLaunchOptions(picked, for: sessionAgentKey)")
        && saveUserPickBody.contains("config.setAgentSessionLaunchOptions(picked, for: id)")
        && !saveUserPickBody.contains("setAgentLaunchOptions(new,")
        && ownPickBody.contains("guard !nonStopFlipped, currentRunner?.status.isRunning == true else { return options }")
        && ownPickBody.contains("picked.nonStop = savedNonStopPick()"))
check("view: a card's mode switch, always mid-turn, saves the same way",
      slice(view, from: "private func adoptSessionMode(_ target: String) {", to: "\n    }\n")
        .contains("config.setAgentSessionLaunchOptions(ownPick(next), for: id)"))
check("sidebar: a first turn's question gets its badge (the ownership rule, not the session id alone)",
      sidebar.contains("mcpBridge.owningSessionId(of: $0) == sessionId"))
check("reader: a reopened session's last-turn time leaves out the waits the transcript shows",
      reader.contains("for id in userWaitToolUseIds(in: obj)")
        && reader.contains("userWaitTools: Set<String> = [\"AskUserQuestion\", \"ExitPlanMode\"]")
        && reader.contains("unionLength(of: waits)"))
check("manager: the timeout key is decided from the installed claude even before the update monitor has read it",
      manager.contains("static func installedClaudeVersion()")
        && manager.contains("AgentCLIProbe.versionFromClaudeVersionsSymlink("))
check("approver: its comments no longer claim claude never gives up on a prompt",
      !source("SipAI/Resources/approver.py").contains("doesn't time out permission prompts"))
check("project: both new files are built into the app",
      occurrences("AgentQuestions.swift in Sources", in: project) == 2
        && occurrences("AgentQuestionCard.swift in Sources", in: project) == 2)

// Settings → Help is the one place that says why a server's form never
// appeared: past the card's bounds it is declined with nothing on screen.
// The sentence names the card's own numbers, so a bound moved without
// the Help moving with it fails here.
let settingsView = source("SipAI/Views/Settings/SettingsView.swift")
let help16 = slice(settingsView, from: "FAQ(id: 16,", to: "FAQ(id: 5,")
check("Help 16 says what a form card can show, in the card's own numbers",
      help16.contains("A card can show up to \(AgentQuestionForm.maxQuestions) fields, and up to \(AgentQuestionForm.maxOptions) choices in each.")
        && help16.contains("A field can be text, a number, yes or no, or one or several choices."))
check("…and that a form past them is declined for the user, with no card",
      help16.contains("SipAI can't show a form that goes beyond this, so it declines it for you, as if you'd chosen Decline, and no card appears."))
// The README's form bullet states the same bounds. It is wrapped at the
// margin, so its lines are joined before the sentence is looked for.
let readmeFormBullet = source("../README.md").replacingOccurrences(of: "\n  ", with: " ")
check("README: the form bullet states the same bounds, and that such a form is declined with no card",
      readmeFormBullet.contains("A card shows up to \(AgentQuestionForm.maxQuestions) fields, and up to \(AgentQuestionForm.maxOptions) choices in each; SipAI declines a form beyond that, or one with a field of another kind, for you — as if you had chosen **Decline** — and no card appears."))

let catalogText = source("SipAI/Resources/Localizable.xcstrings")
if let data = catalogText.data(using: .utf8),
   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let strings = root["strings"] as? [String: Any] {
    for key in ["%@ has a question", "%@ has %lld questions", "Question %lld",
                "Choose any that apply", "Or type your own answer", "Skip", "Previous", "Next",
                "Submit", "%@ chooses for itself and carries on", "Non-stop",
                "Mode · Non-stop is on", "Chat only turns never stop to ask.",
                "Let %@ choose what it judges best, and keep the run going to the end even when it has questions.",
                "Paused while %@ waits for you — %@ so far", "Paused at %@",
                "Session is waiting for your answer", "Waiting for you", "Chat about this",
                "%@ asks what you’d like to clarify before you answer"] {
        let entry = strings[key] as? [String: Any]
        let zh = ((entry?["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any]
        check("catalog: \"\(key)\" has a zh-Hans value", (zh?["value"] as? String)?.isEmpty == false)
    }
    // Help 16's answer is one key; the paragraph on the card's bounds is
    // inside it, in Chinese too, with the same numbers.
    let help16Keys = strings.keys.filter { $0.hasPrefix("An MCP server you've added to an agent can pause one of its tools") }
    let help16Zh = help16Keys.first.flatMap { key -> String? in
        let entry = strings[key] as? [String: Any]
        let zh = ((entry?["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any]
        return zh?["value"] as? String
    } ?? ""
    check("catalog: Help 16's answer is ONE key, the one with the card's bounds — the old answer is gone",
          help16Keys.count == 1
            && help16Keys[0].contains("A card can show up to \(AgentQuestionForm.maxQuestions) fields, and up to \(AgentQuestionForm.maxOptions) choices in each."),
          "\(help16Keys.count) key(s)")
    check("catalog: its zh-Hans value says the same bounds",
          help16Zh.contains("最多显示 \(AgentQuestionForm.maxQuestions) 个字段")
            && help16Zh.contains("最多 \(AgentQuestionForm.maxOptions) 个选项")
            && help16Zh.contains("不会出现卡片"))
    check("catalog: the old bucket name is gone with its string", strings["Waiting for approval"] == nil)
    check("catalog: the clock's hint no longer says it waits for an ANSWER — a plan and a permission pause it too",
          strings["Paused while %@ waits for your answer — %@ so far"] == nil)
} else {
    check("catalog: Localizable.xcstrings parses", false)
}

bridge.shutdown()
print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
