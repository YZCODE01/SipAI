// Headless verification for how a Chat only turn is drawn. See run.sh.
//
// Not part of the app target — this directory sits outside SipAI/, and
// the Xcode project lists its sources explicitly.
//
// Section 1–4 drive the REAL `ChatOnlyActivity` (compiled alone: it is
// pure). Section 5 reads the sources for the wiring the rules depend on.

import Foundation

var failures = 0
var checks = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    checks += 1
    print((ok ? "  ok   " : "  FAIL ") + label + (detail.isEmpty ? "" : " — \(detail)"))
    if !ok { failures += 1 }
}
func section(_ title: String) { print("\n\(title)") }

typealias A = ChatOnlyActivity

// ====================================================================
section("1. What a row says: headlines, hosts, steps")

check("a codex summary's bold title is the headline",
      A.headline(of: "**Weighing the sources**\n\nThe downloads page is the authority.")
          == "Weighing the sources")
check("prose: the first readable line, whitespace collapsed",
      A.headline(of: "  \n\nThe user wants   the latest\trelease.\nSecond line.")
          == "The user wants the latest release.")
check("heading marks and a bullet come off",
      A.headline(of: "## Plan") == "Plan" && A.headline(of: "- check the page") == "check the page")
check("a thought with nothing readable has an empty headline",
      A.headline(of: "  \n \n") == "")
// The line draws its words verbatim: a mark left in is a mark on screen.
// Measured over real transcripts: 433 of 2,379 readable claude thoughts
// name something in backticks in their first line.
check("code and bold marks anywhere in the line come off (the line is drawn verbatim)",
      A.headline(of: "The banner needs the same `ignoresSafeArea` treatment as **the column**.")
          == "The banner needs the same ignoresSafeArea treatment as the column.")
check("a fenced block and a rule are skipped whole",
      A.headline(of: "```swift\nlet x = 1\n```\n---\nThe code sets x.") == "The code sets x.")
check("quote marks and an ordered-list marker come off; a number that opens prose stays",
      A.headline(of: "> 1. First, check the page") == "First, check the page"
      && A.headline(of: "3.14 is the newest release") == "3.14 is the newest release")
// Marks come off only where markdown reads them: a `#` or `>` not
// followed by a space, and an unpaired `**` or backtick, are content.
check("`#include`, `>=` and `2**8` are content, not marks",
      A.headline(of: "#include <stdio.h> comes first") == "#include <stdio.h> comes first"
      && A.headline(of: ">= 3 results came back") == ">= 3 results came back"
      && A.headline(of: "2**8 = 256, so it fits") == "2**8 = 256, so it fits")
check("a lone backtick stays; a pair comes off; a bare heading mark is nothing",
      A.headline(of: "the char ` opens a span") == "the char ` opens a span"
      && A.headline(of: "call `f()` first") == "call f() first"
      && A.headline(of: "###\nreal line") == "real line")

check("a host drops www.", A.host(of: "https://www.python.org/downloads/") == "python.org")
check("a summary cut to length still names its host",
      A.host(of: "https://docs.python.org/3/whatsnew/3.14.html#some-very-long-anch…") == "docs.python.org")
check("a value that is not a URL reads as itself", A.host(of: "not a url") == "not a url")

check("claude WebSearch → a search",
      A.step(forToolNamed: "WebSearch", title: "WebSearch", input: ["query": "python latest"])
          == .search(query: "python latest"))
check("claude WebFetch → a page read",
      A.step(forToolNamed: "WebFetch", title: "WebFetch",
             input: ["url": "https://python.org/", "prompt": "summarise"])
          == .read(url: "https://python.org/"))
check("kimi FetchURL → a page read; kimi WebSearch → a search",
      A.step(forToolNamed: "FetchURL", title: "FetchURL", input: ["url": "https://a.org/x"])
          == .read(url: "https://a.org/x")
      && A.step(forToolNamed: "WebSearch", title: "WebSearch", input: ["query": "q"])
          == .search(query: "q"))
check("codex live search (`query` = the terms) → a search",
      A.step(forToolNamed: "web_search", title: "Search", input: ["query": "python latest"])
          == .search(query: "python latest"))
check("codex live open_page (`query` = the page) → a page read",
      A.step(forToolNamed: "web_search", title: "Search", input: ["query": "https://python.org/downloads/"])
          == .read(url: "https://python.org/downloads/"))
check("codex live find_in_page (`'pattern' in <url>`) → a find",
      A.step(forToolNamed: "web_search", title: "Search", input: ["query": "'3.14' in https://python.org/downloads/"])
          == .find(pattern: "3.14", url: "https://python.org/downloads/"))
// The query is the model's own text. One whose only `' in ` IS its opening
// quote used to slice from past that quote back to it — a backwards range,
// which traps: the app crashed mid-turn, and on every reopen after.
check("a query whose only ` in ` is its opening quote is a search, and no crash",
      A.step(forToolNamed: "web_search", title: "Search", input: ["query": "' in python"])
          == .search(query: "' in python")
      && A.step(forToolNamed: "web_search_call", title: "Search", input: ["command": "' in X' in "])
          == .search(query: "' in X' in")
      && A.codexWebStep("'") == .search(query: "'")
      && A.codexWebStep("' in ") == .search(query: "' in "))
check("codex on REOPEN (`command`, the same spelling) reads the same",
      A.step(forToolNamed: "web_search_call", title: "Search", input: ["command": "python latest"])
          == .search(query: "python latest")
      && A.step(forToolNamed: "web_search_call", title: "Search", input: ["command": "https://python.org/"])
          == .read(url: "https://python.org/"))
check("any other tool is named by its display title",
      A.step(forToolNamed: "apply_patch", title: "Update", input: ["command": "…"]) == .tool(title: "Update"))
// Code mode also surfaces a PAGE VIEW under the search kind, with an empty
// query and an `other` action; the reader draws no row for it on reopen,
// so the live line must not count it either once it has completed.
check("codex code mode: a web step that COMPLETED with nothing to say is no step, live and on reopen",
      A.step(forToolNamed: "web_search", title: "Search", input: ["query": ""], resultText: "") == nil
      && A.step(forToolNamed: "web_search_call", title: "Search", input: ["command": ""], resultText: "") == nil)
check("codex code mode: a search that starts with NO query takes it from its result",
      A.step(forToolNamed: "web_search", title: "Search", input: ["query": ""], resultText: "python latest")
          == .search(query: "python latest")
      && A.step(forToolNamed: "web_search", title: "Search", input: ["query": ""],
                resultText: "https://python.org/downloads/") == .read(url: "https://python.org/downloads/"))
check("codex code mode: before its result lands it is still a search (\"Searching the web\")",
      A.step(forToolNamed: "web_search", title: "Search", input: ["query": ""], resultText: nil)
          == .search(query: ""))
check("codex code mode: the `exec` script that drives tools is a container, not a step",
      A.step(forToolNamed: "exec", title: "exec",
             input: ["command": "const r = await tools.web__run({search_query:[{q:\"q\"}]}); text(r);"]) == nil)
check("…while an `exec` that drives no tool is an ordinary step",
      A.step(forToolNamed: "exec", title: "exec", input: ["command": "echo hi"]) == .tool(title: "exec"))

// ====================================================================
section("2. Grouping: only a Chat only turn collapses")

func search(_ q: String) -> A.Row {
    .toolUse(name: "WebSearch", title: "WebSearch", input: ["query": q], resultText: nil)
}
func fetch(_ u: String) -> A.Row {
    .toolUse(name: "WebFetch", title: "WebFetch", input: ["url": u], resultText: nil)
}

let agentTurn: [A.Row] = [.turnStart(chatOnly: false), .invisible, search("x"), .toolResult, .boundary]
check("an AGENT turn draws its rows as it always did — no group, even for a web lookup",
      A.plan(agentTurn, turnRunning: false).groups.isEmpty)
check("a stray thought outside a Chat only turn forms nothing",
      A.plan([.turnStart(chatOnly: false), .thought("x"), .boundary], turnRunning: false).groups.isEmpty)

let chatTurn: [A.Row] = [.turnStart(chatOnly: true), .invisible, .thought("Checking python.org"),
                         search("python latest"), .toolResult, .thought("The page says 3.14"),
                         .boundary, .invisible]
let chatPlan = A.plan(chatTurn, turnRunning: false)
check("a Chat only turn's thoughts and lookups are ONE group",
      chatPlan.groups.count == 1 && chatPlan.groups[0].members == [2, 3, 4, 5],
      "\(chatPlan.groups.map(\.members))")
check("its steps, in order: thought, search, thought (a result adds none)",
      chatPlan.groups.first?.steps == [.thought(headline: "Checking python.org"),
                                       .search(query: "python latest"),
                                       .thought(headline: "The page says 3.14")])
check("the member → group map covers every member",
      [2, 3, 4, 5].allSatisfy { chatPlan.groupOfRow[$0] == 0 } && chatPlan.groupOfRow[6] == nil)
check("followed by the agent's words it is SETTLED, not live",
      !chatPlan.lastGroupIsLive)

let running: [A.Row] = [.turnStart(chatOnly: true), .invisible, .thought("Checking"), search("q"), .toolResult]
let runningPlan = A.plan(running, turnRunning: true)
check("the newest thing of a running turn is LIVE",
      runningPlan.lastGroupIsLive && runningPlan.isLive(runningPlan.groups[0]))
check("…and not live once the turn has ended",
      !A.plan(running, turnRunning: false).lastGroupIsLive)

let narrated: [A.Row] = [.turnStart(chatOnly: true), .thought("t"), search("a"), .toolResult,
                         .boundary /* "Let me check the page." */, fetch("https://a.org"), .toolResult,
                         .boundary /* the answer */]
let narratedPlan = A.plan(narrated, turnRunning: true)
check("words said between lookups stay where they were: TWO lines around them",
      narratedPlan.groups.map(\.members) == [[1, 2, 3], [5, 6]], "\(narratedPlan.groups.map(\.members))")
check("…and with the answer after both, neither is live", !narratedPlan.lastGroupIsLive)

check("a run holding only a result (its call outside the rows) is not a group",
      A.plan([.turnStart(chatOnly: true), .toolResult, .boundary], turnRunning: false).groups.isEmpty)

let twoTurns: [A.Row] = [.turnStart(chatOnly: false), search("agent"), .toolResult, .boundary,
                         .turnStart(chatOnly: true), search("chat"), .toolResult, .boundary]
let twoPlan = A.plan(twoTurns, turnRunning: false)
check("per TURN: the agent turn's lookup stays a chip, the Chat only turn's collapses",
      twoPlan.groups.map(\.members) == [[5, 6]], "\(twoPlan.groups.map(\.members))")

let interleaved: [A.Row] = [.turnStart(chatOnly: true), .thought("a"), .invisible, search("b"), .toolResult]
check("an invisible row between two members neither splits nor joins the group",
      A.plan(interleaved, turnRunning: true).groups.map(\.members) == [[1, 3, 4]])
check("a notice in the user column ends a group but opens no turn",
      A.plan([.turnStart(chatOnly: true), search("a"), .boundary, search("b")], turnRunning: true)
          .groups.map(\.members) == [[1], [3]])

// Codex's code mode, reopened. A script's summary is its first 80
// characters, and a leading `// @exec: {…}` pragma can fill them before
// `tools.` appears — measured: 9 of 227 web-driving scripts in real
// rollouts. Codex records the search right after the script that ran it.
func script(_ command: String) -> A.Row {
    .toolUse(name: "exec", title: "exec", input: ["command": command], resultText: nil)
}
func reopenedSearch(_ q: String) -> A.Row {
    .toolUse(name: "web_search_call", title: "Search", input: ["command": q], resultText: nil)
}
let cutShort = "// @exec: {\"max_output_tokens\": 8000} const results=await Promise.allSettled([ …"
check("a script cut short of `tools.` is still its search's container — no \"Used 1 tool\"",
      A.plan([.turnStart(chatOnly: true), script(cutShort), reopenedSearch("q"), .boundary],
             turnRunning: false).groups.first?.steps == [.search(query: "q")])
check("…while a script followed by no lookup stays a step of its own",
      A.plan([.turnStart(chatOnly: true), script("Math.sqrt(2)"), .boundary],
             turnRunning: false).groups.first?.steps == [.tool(title: "exec")])
check("…and only the script RIGHT before the lookup is its container",
      A.plan([.turnStart(chatOnly: true), script("2 + 2"), script("await tools.web__run({})"),
              reopenedSearch("q"), .boundary], turnRunning: false).groups.first?.steps
          == [.tool(title: "exec"), .search(query: "q")])
check("…and a claude or kimi lookup after a script does not make it one",
      A.plan([.turnStart(chatOnly: true), script("Math.sqrt(2)"), search("q"), .boundary],
             turnRunning: false).groups.first?.steps == [.tool(title: "exec"), .search(query: "q")])

// The seam between loaded history and the live buffer.
let seamRows: [A.Row] = [.turnStart(chatOnly: false), .boundary,             // history
                         .thought("t"), search("q"), .toolResult, .boundary] // live, its message trimmed
check("a live buffer cut inside a Chat only turn keeps that turn on its line",
      A.plan(seamRows, turnRunning: false, liveStart: A.LiveStart(row: 2, chatOnly: true))
          .groups.map(\.members) == [[2, 3, 4]])
check("…and inside an agent turn draws its rows as they were",
      A.plan(seamRows, turnRunning: false, liveStart: A.LiveStart(row: 2, chatOnly: false))
          .groups.isEmpty)
check("history and the live buffer never share a group",
      A.plan([.turnStart(chatOnly: true), search("a"), search("b")], turnRunning: false,
             liveStart: A.LiveStart(row: 2, chatOnly: true)).groups.map(\.members) == [[1], [2]])
check("a buffer that opens at a message says what its turn is itself",
      A.plan([.turnStart(chatOnly: false), search("q"), .boundary], turnRunning: false,
             liveStart: A.LiveStart(row: 0, chatOnly: true)).groups.isEmpty)

// ====================================================================
section("3. Windows: a line is drawn at its first visible member")

let g = A.Group(members: [5, 6, 7], steps: [.search(query: "x")])
check("window below the group start → its first member", g.anchor(windowStart: 0) == 5)
check("window starting inside it → the first member inside the window (drawn whole there)",
      g.anchor(windowStart: 6) == 6)
check("window past the whole group → not drawn", g.anchor(windowStart: 8) == nil)
check("a gap at the window's edge (an invisible row) lands on the next MEMBER",
      A.Group(members: [1, 3], steps: [.search(query: "x")]).anchor(windowStart: 2) == 3)

// ====================================================================
section("4. What the line says — live, and settled (ONE rule for every agent)")

check("live search", A.livePhrase(for: .search(query: "python latest"))
      == "Searching the web for “python latest”")
check("live search with no terms", A.livePhrase(for: .search(query: "")) == "Searching the web")
check("live page read names the site", A.livePhrase(for: .read(url: "https://www.python.org/downloads/"))
      == "Reading python.org")
check("live find names the text and the site",
      A.livePhrase(for: .find(pattern: "3.14", url: "https://python.org/x"))
          == "Looking for “3.14” on python.org")
check("live other tool", A.livePhrase(for: .tool(title: "Update")) == "Using Update")
check("a thought's live words are its headline", A.livePhrase(for: .thought(headline: "Weighing it"))
      == "Weighing it")
check("a thought with nothing readable says nothing — the line keeps \"Sipping…\"",
      A.livePhrase(for: .thought(headline: "")) == nil)
check("a live group names its NEWEST step",
      A.livePhrase(of: A.Group(members: [1, 2], steps: [.thought(headline: "a"), .search(query: "b")]))
          == "Searching the web for “b”")

func settled(_ steps: [A.Step]) -> String { A.summaryText(A.summary(of: steps)) }
check("thought only", settled([.thought(headline: "a"), .thought(headline: "b")]) == "Thought")
check("one search", settled([.search(query: "a")]) == "Searched the web")
check("searches counted, pages DISTINCT (a page fetched twice was read once)",
      settled([.search(query: "a"), .search(query: "b"), .read(url: "u1"), .read(url: "u1"), .read(url: "u2")])
          == "Searched the web 2 times · Read 2 pages")
check("parts in a FIXED order whatever order the steps came in",
      settled([.read(url: "u"), .search(query: "a"), .thought(headline: "t")])
          == "Thought · Searched the web · Read 1 page")
check("a find inside a page already read adds no page",
      settled([.read(url: "u"), .find(pattern: "p", url: "u")]) == "Read 1 page")
check("a find with no page opened still read one", settled([.find(pattern: "p", url: "u")]) == "Read 1 page")
check("other tools counted", settled([.tool(title: "a"), .tool(title: "b")]) == "Used 2 tools"
      && settled([.tool(title: "a")]) == "Used 1 tool")
check("a line that looked anything up leads with a globe; one that only thought, a bulb",
      A.symbol(for: A.summary(of: [.thought(headline: "t"), .search(query: "q")])) == "globe"
      && A.symbol(for: A.summary(of: [.thought(headline: "t")])) == "lightbulb")

// The same turn, as each agent spells it, settles into the same words.
func steps(_ rows: [A.Row]) -> [A.Step] {
    A.plan([.turnStart(chatOnly: true)] + rows + [.boundary], turnRunning: false).groups.first?.steps ?? []
}
let claudeSteps = steps([search("q"), .toolResult, fetch("https://python.org/"), .toolResult])
let kimiSteps = steps([.toolUse(name: "WebSearch", title: "WebSearch", input: ["query": "q"], resultText: nil), .toolResult,
                       .toolUse(name: "FetchURL", title: "FetchURL", input: ["url": "https://python.org/"], resultText: nil), .toolResult])
let codexSteps = steps([.toolUse(name: "web_search", title: "Search", input: ["query": "q"], resultText: nil),
                        .toolUse(name: "web_search", title: "Search", input: ["query": "https://python.org/"], resultText: nil)])
// Codex's code mode: the search starts with an EMPTY query and names it
// in its result; the `exec` script that ran it is a container.
let codeModeSteps = steps([
    .toolUse(name: "exec", title: "exec",
             input: ["command": "const r = await tools.web__run({search_query:[{q:\"q\"}]})"], resultText: nil),
    .toolUse(name: "web_search", title: "Search", input: ["query": ""], resultText: "q"), .toolResult,
    .toolUse(name: "web_search", title: "Search", input: ["query": ""], resultText: "https://python.org/"), .toolResult])
check("claude, kimi and codex doing the same lookups settle into the SAME line",
      Set([settled(claudeSteps), settled(kimiSteps), settled(codexSteps), settled(codeModeSteps)])
          == ["Searched the web · Read 1 page"],
      "\(settled(claudeSteps)) / \(settled(kimiSteps)) / \(settled(codexSteps)) / \(settled(codeModeSteps))")

// ====================================================================
section("5. The wiring, read from the sources")

let src = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SIPAI_ACTIVITY_SRC"] ?? "../..",
              isDirectory: true)
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
let parser = source("SipAI/Models/AgentEventParsing.swift")
let codexParser = source("SipAI/Models/CodexEventParsing.swift")
let session = source("SipAI/Models/AgentSession.swift")
let codex = source("SipAI/Models/CodexSessions.swift")
let kimi = source("SipAI/Models/KimiSessions.swift")
let launch = source("SipAI/Models/AgentLaunchOptions.swift")
let tailer = source("SipAI/Models/AgentSessionTailer.swift")

// Agent turns unchanged: thoughts only when asked, and only a Chat only turn asks.
check("claude's parser keeps no thought unless asked (default false)",
      squeeze(parser).contains("includeThinking: Bool = false) -> [StreamEvent]"))
check("codex's parser keeps no thought unless asked (default false)",
      squeeze(codexParser).contains("includeThinking: Bool = false) -> Parsed"))
check("all three readers keep no thought unless asked (default false)",
      squeeze(body(session, "static func readHistory(of url: URL")).isEmpty == false
      && squeeze(session).contains("includeThinking: Bool = false) -> [AgentSessionHistoryItem]")
      && squeeze(codex).contains("root: URL = sessionRoot, includeThinking: Bool = false)")
      && squeeze(kimi).contains("byteBudget: Int? = nil, includeThinking: Bool = false)"))
let stdoutHandler = body(runner, "private func handleStdoutLine")
check("the runner asks per TURN — the turn's own Chat only flag, for claude and codex",
      stdoutHandler.contains("includeThinking: turnChatOnly")
      && stdoutHandler.components(separatedBy: "includeThinking: turnChatOnly").count == 3)
check("the flag is the options the turn RAN with, stamped on its user message",
      squeeze(body(runner, "func send(text: String")).contains("chatOnlyTurn: options.chatOnly")
      && squeeze(body(runner, "func send(text: String")).contains("turnChatOnly = options.chatOnly"))
check("the tailer (another process's turns) never asks for thoughts",
      !tailer.isEmpty && tailer.contains("AgentEventParser.parse(") && !tailer.contains("includeThinking"))
// Full signatures: `widenHistoryForSearch()` is declared first and
// shares the prefix.
check("a reopened session keeps thoughts only inside its recorded Chat only turns",
      body(view, "private func startHistoryLoad(url: URL").contains("keepingChatOnlyThoughts")
      && body(view, "private func widenHistory(toBudget").contains("keepingChatOnlyThoughts"))

// Claude's readable-thinking flag: Chat only turns alone, behind the probe.
let claudeArgv = body(launch, "static func claude(options: AgentLaunchOptions")
check("--thinking-display summarized rides a Chat only turn alone, behind the probe's verdict",
      claudeArgv.contains("if options.chatOnly")
      && body(claudeArgv, "if options.chatOnly").contains("if thinkingDisplayAccepted")
      && launch.contains("static let claudeThinkingSummaries = [\"--thinking-display\", \"summarized\"]"))
check("the runner hands the probe's verdict, and only a positive one",
      runner.contains("thinkingDisplayAccepted: ClaudeCapabilities.shared.acceptsThinkingSummaries == true"))

// The line is the waiting row's successor.
let waiting = squeeze(body(view, "private var waitingRow: some View"))
let line = squeeze(body(view, "private func activityLine("))
check("the line exists", !line.isEmpty)
for token in ["HStack(spacing: 8)", "ProgressView().controlSize(.small)",
              ".font(.system(size: 13 * SipFont.contentRatio(fontScale)))",
              ".foregroundColor(ChatDesign.textSecondary)",
              ".padding(.horizontal, 8)", ".padding(.vertical, 6)"] {
    check("the line shares the waiting row's \(token)", waiting.contains(token) && line.contains(token))
}
check("no agent label over the line (the label belongs to the answer)",
      !line.isEmpty && !line.contains("agentLabelHeader"))
check("nothing in the line is time-based",
      !line.isEmpty && !line.contains("TimelineView") && !line.contains("Timer") && !line.contains("Date()"))
check("a live line with nothing readable reads \"Sipping…\"",
      line.contains("String(localized: \"Sipping…\""))
check("its open state is its OWN set — a line opening with a chip must not open that chip",
      view.contains("@State private var expandedActivityLines: Set<UUID> = []")
      && line.contains("expandedActivityLines.insert(line.key)")
      && !line.contains("expandedToolResults"))

// Find: a thought counts while closed, and a jump opens its line.
let rows = body(view, "private func searchableRows()")
check("find counts a thought (history and live)",
      rows.components(separatedBy: "case .thinking(let text):").count == 3)
check("…but only a thought that HAS a line: a match nothing draws is not counted",
      squeeze(rows).contains("let inLine = activityLayout(pairing: pairing).lineOfMember")
      && rows.components(separatedBy: "guard inLine[").count == 3)
check("a jump to a match inside a closed line opens the line",
      squeeze(body(view, "private func jumpToActiveMatch")).contains("expandedActivityLines.insert(line)"))
check("a thought draws only inside its line — never as a row of its own",
      body(view, "private func renderHistoricalItem(").contains("case .thinking:")
      && body(view, "private func renderEvent(").contains("case .thinking:"))

// The record that keeps a turn's look after a reopen.
check("a finished Chat only turn records its handle, resolved like a branch's live row",
      body(runner, "private func recordChatOnlyTurnIfNeeded").contains("resolveCutPoint(matchingUserText")
      && body(runner, "private func finalizeTurn").contains("recordChatOnlyTurnIfNeeded()"))
check("a branch carries its parent's Chat only turns",
      body(view, "private func createSessionBranch").contains("copyAgentChatOnlyTurns(from: sourceId, to: newId)"))
// A send that supersedes a child still winding down after `result` moves
// the run token, and the finalize of the turn before it then no-ops.
/// The text strictly between the first `a` and the next `b` after it.
func between(_ text: String, _ a: String, _ b: String) -> String {
    guard let start = text.range(of: a),
          let end = text.range(of: b, range: start.upperBound..<text.endIndex) else { return "" }
    return String(text[start.upperBound..<end.lowerBound])
}
check("…and at the turn's `result` too, so a quick next send cannot skip it",
      between(stdoutHandler, "endTurnSegment()", "applySubprocessSideEffects(for: event)")
          .contains("recordChatOnlyTurnIfNeeded()"))
let manager = source("SipAI/Models/AgentManager.swift")
check("the history cache remembers which Chat only turns its read kept thoughts for",
      manager.contains("let chatOnlyTurns: Set<String>")
      && body(view, "private func startHistoryLoad(url: URL").contains("chatOnlyTurns: chatOnlyTurns"))
check("…and an unchanged file is re-read when that set has moved",
      squeeze(body(view, "private func reload()")).contains("cached.chatOnlyTurns == chatOnlyTurnHandles"))

// The live buffer's front trim can cut a turn's message away.
let trim = squeeze(body(runner, "private func trimLiveEventsIfNeeded"))
check("the trim remembers what the turn it cut into ran as",
      trim.contains("trimmedHeadChatOnly = opener.chatOnlyTurn")
      && squeeze(body(runner, "func clearEvents()")).contains("trimmedHeadChatOnly = false"))
let layout = squeeze(body(view, "private func activityLayout(pairing: Pairing)"))
check("…and the transcript hands it to the plan at the seam",
      layout.contains("liveStart: ChatOnlyActivity.LiveStart(row: h, chatOnly: runner.trimmedHeadChatOnly)")
      && layout.contains("|| runner.trimmedHeadChatOnly"))

print("\n\(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
