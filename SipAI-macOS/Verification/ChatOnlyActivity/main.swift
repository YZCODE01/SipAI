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
      A.step(forToolNamed: "mcp__notes__search", title: "mcp__notes__search", input: ["query": "…"])
          == .tool(title: "mcp__notes__search"))
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
section("2. Grouping: a Chat only turn always collapses; an agent turn only in compact view")

func search(_ q: String) -> A.Row {
    .toolUse(name: "WebSearch", title: "WebSearch", input: ["query": q], resultText: nil)
}
func fetch(_ u: String) -> A.Row {
    .toolUse(name: "WebFetch", title: "WebFetch", input: ["url": u], resultText: nil)
}

let agentTurn: [A.Row] = [.turnStart(chatOnly: false), .invisible, search("x"), .toolResult, .words("x is y")]
check("an AGENT turn draws its rows as it always did — no group, even for a web lookup",
      A.plan(agentTurn, turnRunning: false).groups.isEmpty)
check("a stray thought outside a Chat only turn forms nothing",
      A.plan([.turnStart(chatOnly: false), .thought("x"), .words("y")], turnRunning: false).groups.isEmpty)

let chatTurn: [A.Row] = [.turnStart(chatOnly: true), .invisible, .thought("Checking python.org"),
                         search("python latest"), .toolResult, .thought("The page says 3.14"),
                         .words("3.14 is the latest."), .invisible]
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
                         .words("Let me check the page."), fetch("https://a.org"), .toolResult,
                         .words("The answer.")]
// With compact view off too, a Chat only turn draws by the answer rule: the
// words said between its lookups are inside the one line, and only its final
// message is under it (the user's decision, 2026-11-02).
let narratedPlan = A.plan(narrated, turnRunning: true)
check("compact view off: while a Chat only turn runs, everything it did — its words between lookups too — is ONE live line",
      narratedPlan.groups.map(\.members) == [[1, 2, 3, 4, 5, 6, 7]] && narratedPlan.lastGroupIsLive,
      "\(narratedPlan.groups.map(\.members))")
check("…and once it is done, only its final message comes out from under the line",
      A.plan(narrated, turnRunning: false).groups.map(\.members) == [[1, 2, 3, 4, 5, 6]]
      && !A.plan(narrated, turnRunning: false).lastGroupIsLive)

check("a run holding only a result (its call outside the rows) is not a group",
      A.plan([.turnStart(chatOnly: true), .toolResult, .words("a")], turnRunning: false).groups.isEmpty)

let twoTurns: [A.Row] = [.turnStart(chatOnly: false), search("agent"), .toolResult, .words("a"),
                         .turnStart(chatOnly: true), search("chat"), .toolResult, .words("b")]
let twoPlan = A.plan(twoTurns, turnRunning: false)
check("per TURN: the agent turn's lookup stays a chip, the Chat only turn's collapses",
      twoPlan.groups.map(\.members) == [[5, 6]], "\(twoPlan.groups.map(\.members))")

let interleaved: [A.Row] = [.turnStart(chatOnly: true), .thought("a"), .invisible, search("b"), .toolResult]
check("an invisible row between two members neither splits nor joins the group",
      A.plan(interleaved, turnRunning: true).groups.map(\.members) == [[1, 3, 4]])
check("a notice in the user column ends a group but opens no turn",
      A.plan([.turnStart(chatOnly: true), search("a"), .answerStart, search("b")], turnRunning: true)
          .groups.map(\.members) == [[1], [3]])
check("…the user's own words sent into the turn split the line; a notice and an error it went on after are inside",
      A.plan([.turnStart(chatOnly: true), search("a"), .split, search("b"), .notice("n"), search("c"),
              .outcome("e"), search("d")], turnRunning: true).groups.map(\.members) == [[1], [3, 4, 5, 6, 7]])

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
      A.plan([.turnStart(chatOnly: true), script(cutShort), reopenedSearch("q"), .words("a")],
             turnRunning: false).groups.first?.steps == [.search(query: "q")])
check("…while a script followed by no lookup stays a step of its own",
      A.plan([.turnStart(chatOnly: true), script("Math.sqrt(2)"), .words("a")],
             turnRunning: false).groups.first?.steps == [.tool(title: "exec")])
check("…and only the script RIGHT before the lookup is its container",
      A.plan([.turnStart(chatOnly: true), script("2 + 2"), script("await tools.web__run({})"),
              reopenedSearch("q"), .words("a")], turnRunning: false).groups.first?.steps
          == [.tool(title: "exec"), .search(query: "q")])
check("…and a claude or kimi lookup after a script does not make it one",
      A.plan([.turnStart(chatOnly: true), script("Math.sqrt(2)"), search("q"), .words("a")],
             turnRunning: false).groups.first?.steps == [.tool(title: "exec"), .search(query: "q")])

// The seam between loaded history and the live buffer.
let seamRows: [A.Row] = [.turnStart(chatOnly: false), .words("a"),          // history
                         .thought("t"), search("q"), .toolResult, .words("b")] // live, its message trimmed
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
      A.plan([.turnStart(chatOnly: false), search("q"), .words("a")], turnRunning: false,
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
    A.plan([.turnStart(chatOnly: true)] + rows + [.words("the answer")], turnRunning: false).groups.first?.steps ?? []
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
section("4b. Compact view: an agent turn's steps, in each agent's spelling")

// Field names as each agent records them: claude `file_path`, kimi `path`;
// codex names a live row after its item type, a reopened one after its call.
check("claude Read and kimi Read are a file read, by name",
      A.step(forToolNamed: "Read", title: "Read", input: ["file_path": "/p/Sources/App.swift"])
          == .readFile(path: "/p/Sources/App.swift")
      && A.step(forToolNamed: "Read", title: "Read", input: ["path": "notes.md", "n_lines": 40])
          == .readFile(path: "notes.md"))
check("claude Edit / Write and kimi Edit / Write are an edit of that file",
      A.step(forToolNamed: "Edit", title: "Update", input: ["file_path": "/p/a.swift"]) == .edit(paths: ["/p/a.swift"])
      && A.step(forToolNamed: "Write", title: "Write", input: ["path": "b.md"]) == .edit(paths: ["b.md"]))
check("codex's live file change is an edit that names no file",
      A.step(forToolNamed: "file_change", title: "Update", input: [:]) == .edit(paths: []))
check("codex's patch names its files, each once",
      A.step(forToolNamed: "apply_patch", title: "apply_patch",
             input: ["command": "*** Begin Patch *** Update File: src/a.rs @@ x *** Add File: src/b.rs *** Update File: src/a.rs"])
          == .edit(paths: ["src/b.rs", "src/a.rs"]))
check("Bash (claude, kimi) and codex's command are a command",
      A.step(forToolNamed: "Bash", title: "Bash", input: ["command": "swift build", "description": "Build"])
          == .command("swift build")
      && A.step(forToolNamed: "command_execution", title: "Shell", input: ["command": "/bin/zsh -lc 'ls -la'"])
          == .command("/bin/zsh -lc 'ls -la'"))
check("Grep and Glob are a search of the files",
      A.step(forToolNamed: "Grep", title: "Grep", input: ["pattern": "finalizeTurn", "path": "."])
          == .findInFiles(pattern: "finalizeTurn")
      && A.step(forToolNamed: "Glob", title: "Glob", input: ["pattern": "**/*.swift"]) == .findInFiles(pattern: "**/*.swift"))
check("a subagent (claude / kimi Agent, codex spawn_agent) by its task",
      A.step(forToolNamed: "Agent", title: "Agent", input: ["description": "Find the parser"])
          == .agent(description: "Find the parser")
      && A.step(forToolNamed: "spawn_agent", title: "spawn_agent", input: ["command": "Review the diff"])
          == .agent(description: "Review the diff"))
check("the to-do list, whoever keeps it",
      A.step(forToolNamed: "TodoWrite", title: "TodoWrite", input: [:]) == .todo
      && A.step(forToolNamed: "TodoList", title: "TodoList", input: [:]) == .todo
      && A.step(forToolNamed: "todo_list", title: "Todo", input: [:]) == .todo)

check("a command's live words drop codex's shell wrapper and keep the first line",
      A.commandLine("/bin/zsh -lc 'git status --short'") == "git status --short"
      && A.commandLine("swift build\n  && swift test") == "swift build")
check("live words per kind",
      A.livePhrase(for: .readFile(path: "/p/Sources/AgentRunner.swift")) == "Reading AgentRunner.swift"
      && A.livePhrase(for: .edit(paths: ["/p/ContentView.swift"])) == "Editing ContentView.swift"
      && A.livePhrase(for: .edit(paths: [])) == "Editing files"
      && A.livePhrase(for: .command("/bin/zsh -lc 'swift build'")) == "Running swift build"
      && A.livePhrase(for: .findInFiles(pattern: "TODO")) == "Searching for “TODO”"
      && A.livePhrase(for: .agent(description: "Find the parser")) == "Running an agent: Find the parser"
      && A.livePhrase(for: .todo) == "Updating the to-do list")

func tool(_ name: String, _ input: [String: Any], failed: Bool = false) -> A.Row {
    .toolUse(name: name, title: name, input: input, resultText: nil, failed: failed)
}
check("compact OFF: an agent turn still draws its chips (nothing changes)",
      A.plan([.turnStart(chatOnly: false), tool("Bash", ["command": "ls"]), .toolResult, .words("a")],
             turnRunning: false).groups.isEmpty)
let agentRun: [A.Row] = [.turnStart(chatOnly: false), .thought("Looking for the build error"),
                         tool("Bash", ["command": "swift build"]), .toolResult,
                         tool("Read", ["file_path": "/p/a.swift"]), .toolResult,
                         .words("Found it."),
                         tool("Edit", ["file_path": "/p/a.swift"]), .toolResult,
                         tool("Bash", ["command": "swift build"], failed: true), .toolResult,
                         .words("The build is fixed.")]
let agentPlan = A.plan(agentRun, turnRunning: false, compact: true)
check("compact ON: an agent turn's thoughts, tool calls AND the words between them fold into ONE line",
      agentPlan.groups.map(\.members) == [[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]],
      "\(agentPlan.groups.map(\.members))")
check("…marked as an agent turn's, the failure and the message counted, the last words outside it",
      agentPlan.groups.map(\.agentTurn) == [true] && agentPlan.groups.map(\.failures) == [1]
      && agentPlan.groups.map(\.messages) == [1] && agentPlan.groupOfRow[11] == nil)
check("compact ON: a Chat only turn folds by the same answer rule, with a Chat only turn's glyph",
      A.plan(chatTurn, turnRunning: false, compact: true).groups.map(\.agentTurn) == [false]
      && A.plan(chatTurn, turnRunning: false, compact: true).groups.map(\.members) == chatPlan.groups.map(\.members))
check("compact ON: a trimmed live head inside an agent turn folds too",
      A.plan([.turnStart(chatOnly: false), .words("a"), tool("Bash", ["command": "ls"]), .toolResult],
             turnRunning: true, liveStart: A.LiveStart(row: 2, chatOnly: false), compact: true)
          .groups.map(\.members) == [[2, 3]])

// Codex's code mode in an agent turn. A reopened codex turn is made of
// little but `exec` scripts — the commands and patches they ran are not
// rows of their own there — so a script is a step; live, the rows a
// script drives follow it, and then it is their container.
let driving = "const r = await tools.exec_command({cmd: \"ls\"}); text(r.output)"
check("compact, reopened codex: each script that drives tools is a step — the turn still folds",
      A.plan([.turnStart(chatOnly: false), tool("exec", ["command": driving]), .toolResult,
              tool("exec", ["command": driving]), .toolResult, .words("a")],
             turnRunning: false, compact: true).groups.first?.steps
          == [.tool(title: "exec"), .tool(title: "exec")])
check("compact, live codex: a script followed by the command it drove is that command's container",
      A.plan([.turnStart(chatOnly: false), tool("exec", ["command": driving]),
              tool("command_execution", ["command": "ls"]), .toolResult, .words("a")],
             turnRunning: false, compact: true).groups.first?.steps == [.command("ls")])
check("…and in a CHAT ONLY turn a tools-driving script stays no step at all, as before",
      A.plan([.turnStart(chatOnly: true), tool("exec", ["command": driving]), .words("a")],
             turnRunning: false, compact: true).groups.isEmpty)

check("settled: ONE fixed order for every part, failures last",
      A.summaryText(A.summary(of: [.thought(headline: "t"), .agent(description: "a"), .tool(title: "x"),
                                   .read(url: "u"), .search(query: "q"), .findInFiles(pattern: "p"),
                                   .readFile(path: "f1"), .readFile(path: "f2"), .readFile(path: "f1"),
                                   .command("c1"), .command("c2"), .edit(paths: ["e1"]), .edit(paths: ["e1", "e2"])],
                              failures: 1))
          == "Thought · Edited 2 files · Ran 2 commands · Read 2 files · Searched for 1 pattern · Searched the web · Read 1 page · Ran 1 agent · Used 1 tool · 1 failed")
check("files are DISTINCT; a change that names no file counts as one",
      A.summary(of: [.edit(paths: []), .edit(paths: []), .edit(paths: ["a"]), .edit(paths: ["a"])]).edits == 3
      && A.summary(of: [.readFile(path: "a"), .readFile(path: "a")]).filesRead == 1)
check("singular words", A.summaryText(A.summary(of: [.edit(paths: ["a"]), .command("c"), .readFile(path: "r"),
                                                      .agent(description: "d")]))
      == "Edited 1 file · Ran 1 command · Read 1 file · Ran 1 agent")
check("a to-do update counts as a tool", A.summaryText(A.summary(of: [.todo])) == "Used 1 tool")
check("glyph: an agent turn's work is the wrench; web only stays the globe; thinking alone the bulb",
      A.symbol(for: A.summary(of: [.command("c")]), agentTurn: true) == "wrench.and.screwdriver"
      && A.symbol(for: A.summary(of: [.tool(title: "mcp")]), agentTurn: true) == "wrench.and.screwdriver"
      && A.symbol(for: A.summary(of: [.search(query: "q")]), agentTurn: true) == "globe"
      && A.symbol(for: A.summary(of: [.thought(headline: "t")]), agentTurn: true) == "lightbulb"
      && A.symbol(for: A.summary(of: [.tool(title: "mcp")])) == "globe")

// The same agent turn, as each agent records it, settles into the same words.
let claudeWork = A.plan([.turnStart(chatOnly: false),
                         tool("Read", ["file_path": "/p/a.swift"]), .toolResult,
                         tool("Edit", ["file_path": "/p/a.swift"]), .toolResult,
                         tool("Bash", ["command": "swift build"]), .toolResult, .words("a")],
                        turnRunning: false, compact: true)
let kimiWork = A.plan([.turnStart(chatOnly: false),
                       tool("Read", ["path": "/p/a.swift"]), .toolResult,
                       tool("Edit", ["path": "/p/a.swift"]), .toolResult,
                       tool("Bash", ["command": "swift build"]), .toolResult, .words("a")],
                      turnRunning: false, compact: true)
func line(_ p: A.Plan) -> String {
    p.groups.first.map { A.summaryText(A.summary(of: $0.steps, failures: $0.failures)) } ?? ""
}
check("claude and kimi doing the same work settle into the SAME line",
      line(claudeWork) == "Edited 1 file · Ran 1 command · Read 1 file" && line(kimiWork) == line(claudeWork),
      "\(line(claudeWork)) / \(line(kimiWork))")

// ====================================================================
section("4d. Compact view: ONE line per answer, its last words under it")

let bash = tool("Bash", ["command": "swift test"])
// A running answer: every message is in the line, and the line names the newest thing.
let runningAnswer: [A.Row] = [.turnStart(chatOnly: false), .thought("Where is the bug?"),
                              tool("Read", ["file_path": "/p/a.swift"]), .toolResult,
                              .words("The date is parsed in UTC."), bash, .toolResult,
                              .words("**All tests pass.**")]
let runningPlan1 = A.plan(runningAnswer, turnRunning: true, compact: true)
check("while the answer runs, everything it did — its words too — is ONE live line",
      runningPlan1.groups.map(\.members) == [[1, 2, 3, 4, 5, 6, 7]] && runningPlan1.lastGroupIsLive,
      "\(runningPlan1.groups.map(\.members))")
check("…its words roll in the line: the newest message's first line, marks off",
      runningPlan1.groups.first.flatMap(A.livePhrase(of:)) == "All tests pass.")
check("…and the newest step's words once a step follows a message",
      A.plan(Array(runningAnswer.prefix(7)), turnRunning: true, compact: true).groups.first
          .flatMap(A.livePhrase(of:)) == "Running swift test")
let doneAnswer = A.plan(runningAnswer, turnRunning: false, compact: true)
check("once the answer is done its last words come out from under the line",
      doneAnswer.groups.map(\.members) == [[1, 2, 3, 4, 5, 6]] && doneAnswer.groupOfRow[7] == nil
      && !doneAnswer.lastGroupIsLive)
check("…and the line counts the message it holds",
      doneAnswer.groups.first.map { A.summaryText(A.summary(of: $0.steps, failures: $0.failures,
                                                             messages: $0.messages)) }
          == "Thought · Ran 1 command · Read 1 file · 1 message")
check("a turn still running whose answer has landed (it waits on a background task) is done too",
      A.plan(runningAnswer, turnRunning: true, compact: true, answerSettled: true).groups.map(\.members)
          == [[1, 2, 3, 4, 5, 6]]
      && !A.plan(runningAnswer, turnRunning: true, compact: true, answerSettled: true).lastGroupIsLive)
check("the last words are every message after the last step — two in a row are both outside",
      A.plan([.turnStart(chatOnly: false), bash, .toolResult, .words("Done."), .invisible, .words("Next: release.")],
             turnRunning: false, compact: true).groups.map(\.members) == [[1, 2]])
check("an answer that ended on an error or Interrupted draws them with its last words",
      A.plan([.turnStart(chatOnly: false), bash, .toolResult, .words("Almost."), .outcome("Interrupted")],
             turnRunning: false, compact: true).groups.map(\.members) == [[1, 2]]
      && A.plan([.turnStart(chatOnly: false), bash, .toolResult, .outcome("API error")],
                turnRunning: false, compact: true).groups.map(\.members) == [[1, 2]])
let wentOn = A.plan([.turnStart(chatOnly: false), bash, .toolResult, .outcome("The skill review did not load"),
                     bash, .toolResult, .words("Done.")], turnRunning: false, compact: true)
check("an error the answer went on after is inside the line, counted as failed",
      wentOn.groups.map(\.members) == [[1, 2, 3, 4, 5]] && wentOn.groups.map(\.failures) == [1])
check("an answer of words alone, done, draws no line — just the words",
      A.plan([.turnStart(chatOnly: false), .words("Hello."), .words("How can I help?")],
             turnRunning: false, compact: true).groups.isEmpty)
let onlyWords = A.plan([.turnStart(chatOnly: false), .words("Thinking about it…")], turnRunning: true, compact: true)
check("…while it runs, its words roll in a live line, as every message does",
      onlyWords.groups.map(\.members) == [[1]] && onlyWords.lastGroupIsLive
      && onlyWords.groups.first.flatMap(A.livePhrase(of:)) == "Thinking about it…")
check("a line holding only messages leads with a speech bubble",
      A.symbol(for: A.summary(of: [], messages: 2), agentTurn: true) == "text.bubble"
      && A.summaryText(A.summary(of: [], messages: 2)) == "2 messages")

// The user's own words sent into the running turn stay where they happened and cut the line in two.
let asked = A.plan([.turnStart(chatOnly: false), bash, .toolResult, .words("One moment."),
                    .split /* the user's own words, steered into the turn */,
                    tool("Edit", ["file_path": "/p/a.swift"]), .toolResult, .words("Done.")],
                   turnRunning: false, compact: true)
check("the user's own words sent into the turn: a split",
      asked.groups.map(\.members) == [[1, 2, 3], [5, 6]] && asked.groupOfRow[4] == nil && asked.groupOfRow[7] == nil,
      "\(asked.groups.map(\.members))")
let split = A.plan([.turnStart(chatOnly: false), bash, .toolResult, .split],
                   turnRunning: true, compact: true)
check("…and the line before a split waiting at the end is settled, not live (the split is newest)",
      split.groups.map(\.members) == [[1, 2]] && !split.lastGroupIsLive)

// Notices drawn among the steps go into the line; a row that opens an answer of its own does not.
let compacted = A.plan([.turnStart(chatOnly: false), bash, .toolResult,
                        .notice("Context compacted"), .notice("This session is being continued…"),
                        bash, .toolResult, .words("Done.")], turnRunning: false, compact: true)
check("a mid-turn compaction and its summary are inside the line, and the line goes on after them",
      compacted.groups.map(\.members) == [[1, 2, 3, 4, 5, 6]] && compacted.groups.map(\.failures) == [0])
check("…a notice says its words while the line is live",
      A.plan([.turnStart(chatOnly: false), bash, .toolResult, .notice("Background command “build” completed")],
             turnRunning: true, compact: true).groups.first.flatMap(A.livePhrase(of:))
          == "Background command “build” completed")
let report = A.plan([.turnStart(chatOnly: false), bash, .toolResult, .words("Started; I'll report back."),
                     .answerStart /* a `!` command's output, or a notice that is no background report */,
                     bash, .toolResult, .words("It passed.")],
                    turnRunning: false, compact: true)
check("a row that opens an answer of its own ends the one above: two answers, two lines, two last words",
      report.groups.map(\.members) == [[1, 2], [5, 6]]
      && report.groupOfRow[3] == nil && report.groupOfRow[4] == nil && report.groupOfRow[7] == nil)
check("a turn's message always opens an answer, whatever came before it",
      A.plan([.turnStart(chatOnly: false), bash, .toolResult, .words("a"),
              .turnStart(chatOnly: false), bash, .toolResult, .words("b")],
             turnRunning: false, compact: true).groups.map(\.members) == [[1, 2], [5, 6]])
check("rows above the first message read (an answer that opened above the history) fold too",
      A.plan([bash, .toolResult, .words("a"), .turnStart(chatOnly: false), .words("b")],
             turnRunning: false, compact: true).groups.map(\.members) == [[0, 1]])
check("history and the live buffer still never share a line: the read's part of a running answer ends at the seam",
      A.plan([.turnStart(chatOnly: false), bash, .toolResult, .words("so far"), bash, .toolResult],
             turnRunning: true, liveStart: A.LiveStart(row: 4, chatOnly: false), compact: true)
          .groups.map(\.members) == [[1, 2], [4, 5]])
check("a Chat only turn with compact view ON folds its words too (one rule for every turn)",
      A.plan(narrated, turnRunning: false, compact: true).groups.map(\.members) == [[1, 2, 3, 4, 5, 6]]
      && A.plan(narrated, turnRunning: false, compact: true).groups.map(\.agentTurn) == [false])
check("…and with compact view OFF it draws exactly the same (Chat only has one look)",
      A.plan(narrated, turnRunning: false).groups == A.plan(narrated, turnRunning: false, compact: true).groups
      && A.plan(narrated, turnRunning: true).groups == A.plan(narrated, turnRunning: true, compact: true).groups)
check("compact view OFF: an agent turn's words, notices and splits change nothing — still no line",
      A.plan([.turnStart(chatOnly: false), bash, .toolResult, .words("a"), .notice("n"), .split, .words("b")],
             turnRunning: true).groups.isEmpty)

// A settled line says what it holds — steps, messages, failures — and a
// notice is none of those. An answer made of notices alone (a `/compact`:
// the compaction row and the summary after it) would settle into a line
// with nothing on it; its notices stay rows of their own instead.
let noticesAlone: [A.Row] = [.turnStart(chatOnly: false), .notice("Conversation compacted"),
                            .notice("This session is being continued…")]
check("an answer of notices alone — a /compact's compaction and its summary — makes no line, running or done",
      A.plan(noticesAlone, turnRunning: false, compact: true).groups.isEmpty
      && A.plan(noticesAlone, turnRunning: true, compact: true).groups.isEmpty
      && A.summaryText(A.summary(of: [])) == "")

// ====================================================================
section("4e. Compact view: everything between the user's message and the final message is in the line")

// A watch made with claude's Monitor tool, as the transcript keeps it: each
// line the watched command prints is a task notification claude starts a
// turn of its own for, and the agent replies. The notice belongs to the
// agent's answer (the view hands it over as a notice), so nothing of it
// opens an answer of its own.
let watchReopened: [A.Row] = [.turnStart(chatOnly: false), bash, .toolResult, .words("I'm waiting for the sweep."),
                              .notice("Monitor event: Build exit=0 12s"), .words("Noted; 1 of 3."),
                              .notice("Monitor event: Lint exit=0 4s"), .words("Noted; 2 of 3."),
                              .notice("Monitor \"sweep\" stream ended"), bash, .toolResult,
                              .words("All three passed, and the tree is landed.")]
let watchDone = A.plan(watchReopened, turnRunning: false, compact: true)
check("reopened: a watch's events, the replies to them and the work after them are ONE line, the final message under it",
      watchDone.groups.map(\.members) == [Array(1...10)] && watchDone.groupOfRow[11] == nil,
      "\(watchDone.groups.map(\.members))")
check("…the replies counted as messages, the notices not",
      watchDone.groups.first?.messages == 3)

// Live, claude prints nothing for a Monitor event: each one is a turn of its
// own — `system/init`, the reply, `result` — with no row in the user column
// between them (measured on claude 2.1.316).
let watchLive: [A.Row] = [.turnStart(chatOnly: false), .turnBoundary, bash, .toolResult,
                          .words("I'm waiting for the sweep."), .invisible,
                          .turnBoundary, .words("Noted; 1 of 3."), .invisible,
                          .turnBoundary, .words("Noted; 2 of 3."), .invisible]
let watchWaiting = A.plan(watchLive, turnRunning: true, compact: true, answerSettled: true)
check("live, while the watch runs: only the newest turn's words are under the line, the earlier replies inside it",
      watchWaiting.groups.map(\.members) == [[2, 3, 4, 7]] && watchWaiting.groupOfRow[10] == nil
      && !watchWaiting.lastGroupIsLive, "\(watchWaiting.groups.map(\.members))")
check("…and once the next event's turn has begun, with nothing said in it yet, the newest words stay under the line",
      A.plan(watchLive + [.turnBoundary], turnRunning: true, compact: true, answerSettled: true)
          .groups.map(\.members) == [[2, 3, 4, 7]])
check("…while that turn is being written, everything is in the live line",
      A.plan(watchLive + [.turnBoundary], turnRunning: true, compact: true).groups.map(\.members)
          == [[2, 3, 4, 7, 10]]
      && A.plan(watchLive + [.turnBoundary], turnRunning: true, compact: true).lastGroupIsLive)
check("a turn's start is no step and no member: a plain answer draws as before",
      A.plan([.turnStart(chatOnly: false), .turnBoundary, bash, .toolResult, .words("Done."), .invisible],
             turnRunning: false, compact: true).groups.map(\.members) == [[2, 3]]
      && A.plan([.turnStart(chatOnly: false), .turnBoundary, .words("Hello."), .invisible],
                turnRunning: false, compact: true).groups.isEmpty)
check("compact view OFF: a turn's start changes nothing in an agent turn",
      A.plan(watchLive, turnRunning: false).groups.isEmpty)

// One background job: the report claude runs on it joins the line.
let jobReport: [A.Row] = [.turnStart(chatOnly: false), bash, .toolResult,
                          .words("Started the tests; here is what I changed."), .invisible,
                          .notice("Background command \"npm test\" completed (exit code 0)"), .turnBoundary,
                          bash, .toolResult, .words("All 42 tests pass."), .invisible]
check("a background task's report joins the line: the earlier answer inside it, the report's words the final message",
      A.plan(jobReport, turnRunning: false, compact: true).groups.map(\.members) == [[1, 2, 3, 5, 7, 8]])
let reportStarting = A.plan(Array(jobReport.prefix(6)), turnRunning: true, compact: true)
check("…and while the report begins, the line is live and says the notice",
      reportStarting.lastGroupIsLive
      && reportStarting.groups.first.flatMap(A.livePhrase(of:))
          == "Background command \"npm test\" completed (exit code 0)")
check("a notice after the final message, with nothing said after it, is drawn after it — not folded with it",
      A.plan([.turnStart(chatOnly: false), bash, .toolResult, .words("Done."),
              .notice("Background command \"watch\" was stopped")], turnRunning: false, compact: true)
          .groups.map(\.members) == [[1, 2]])

// The agent's question with its answer and a plan once reviewed: their cards
// pop up while they wait, and their chips are steps of the line.
let askedInLine = A.plan([.turnStart(chatOnly: false), bash, .toolResult,
                          tool("AskUserQuestion", ["questions": [["question": "Which colour?"]]]), .toolResult,
                          tool("ExitPlanMode", ["plan": "1. Edit a.swift"]), .toolResult,
                          tool("Edit", ["file_path": "/p/a.swift"]), .toolResult, .words("Done.")],
                         turnRunning: false, compact: true)
check("the agent's question with its answer and a reviewed plan are inside the line",
      askedInLine.groups.map(\.members) == [Array(1...8)], "\(askedInLine.groups.map(\.members))")
check("…as a question and a plan, by every agent's name for them",
      A.step(forToolNamed: "AskUserQuestion", title: "Question", input: [:]) == .question
      && A.step(forToolNamed: "request_user_input", title: "request_user_input", input: [:]) == .question
      && A.step(forToolNamed: "ExitPlanMode", title: "ExitPlanMode", input: [:]) == .plan)
check("…said as the agent asking while the card waits",
      A.livePhrase(for: .question) == "Asking you a question"
      && A.livePhrase(for: .plan) == "Asking you to review a plan")
check("…and counted, settled, after the tools and before the messages",
      askedInLine.groups.first.map { A.summaryText(A.summary(of: $0.steps, failures: $0.failures,
                                                               messages: $0.messages)) }
          == "Edited 1 file · Ran 1 command · 1 question · 1 plan"
      && A.summaryText(A.summary(of: [.tool(title: "x"), .question, .question, .plan, .plan], messages: 2))
          == "Used 1 tool · 2 questions · 2 plans · 2 messages")
check("…and a line of a question and messages alone leads with the speech bubble",
      A.symbol(for: A.summary(of: [.question], messages: 1), agentTurn: true) == "text.bubble")
// Codex: a question asked without stopping is the agent's words, and the
// user's reply on its card a row sent into the turn that belongs to the
// answer (the view hands it over as a notice).
check("codex: the reply given on a question's card is inside the line, the work after it too",
      A.plan([.turnStart(chatOnly: false), .words("Which colour?"), .notice("> Which colour?\n\nBlue"),
              bash, .toolResult, .words("Painted it blue.")], turnRunning: false, compact: true)
          .groups.map(\.members) == [[1, 2, 3, 4]])

// ====================================================================
section("4c. The agent's name: once per answer where an answer is drawn compact")

typealias N = A.NameRow
let agentAnswer: [N] = [.turnStart(chatOnly: false), .line, .words, .line, .words]
let off = A.names(agentAnswer, compact: false)
check("compact OFF, an agent turn: every bubble keeps its header, a line-less chip rule as before",
      off.quiet.isEmpty && off.named.contains(1))
let on = A.names(agentAnswer, compact: true)
check("compact ON: the name over the answer's FIRST row (its line), no header on its later words",
      on.named == [1] && on.quiet == [2, 4], "named \(on.named.sorted()) quiet \(on.quiet.sorted())")
check("a Chat only turn draws the name once even with compact OFF (the user's fix)",
      A.names([.turnStart(chatOnly: true), .line, .words, .line, .words], compact: false).quiet == [2, 4])
check("an agent turn's chips keep the old rule: only the chip that opens the answer is named, every bubble keeps its header",
      A.names([.turnStart(chatOnly: false), .chip, .chip, .words, .chip], compact: false).named == [1]
      && A.names([.turnStart(chatOnly: false), .chip, .chip, .words, .chip], compact: false).quiet.isEmpty)
check("a new message opens a new answer: the name again",
      A.names([.turnStart(chatOnly: false), .words, .words, .turnStart(chatOnly: false), .line, .words],
              compact: true).named == [1, 4])
check("so does a reply in the user column (a steered message, a notice, a `!` output)",
      A.names([.turnStart(chatOnly: false), .words, .userColumn, .words], compact: true).named == [1, 3])
check("a note neither takes the name nor ends the answer",
      A.names([.turnStart(chatOnly: false), .note, .words, .words], compact: true).named == [2]
      && A.names([.turnStart(chatOnly: false), .note, .words, .words], compact: true).quiet == [3])
check("nothing drawn yet in a compact answer: the name is owed over \"Sipping…\"",
      A.names([.turnStart(chatOnly: false)], compact: true).waitingNamed
      && A.names([.turnStart(chatOnly: false), .silent], compact: true).waitingNamed
      && !A.names([.turnStart(chatOnly: false), .line], compact: true).waitingNamed
      && !A.names([.turnStart(chatOnly: false)], compact: false).waitingNamed
      && A.names([.turnStart(chatOnly: true)], compact: false).waitingNamed)
check("a live buffer cut mid-answer starts an answer of its own at the seam",
      A.names([.turnStart(chatOnly: false), .words, .words, .words], compact: true,
              liveStart: A.LiveStart(row: 2, chatOnly: false)).named == [1, 2])
// The display window starts mid-answer: rows above it draw nothing.
let cut: [N] = [.turnStart(chatOnly: false), .chip, .chip, .words]
let cutScreen = [true, false, true, true]
let fullCut = A.names(cut, compact: false, onScreen: cutScreen)
check("drawn in full, the window does not move the name: a chip whose answer opened above it stays unnamed (the old rule)",
      fullCut.named == [1] && fullCut.quiet.isEmpty,
      "named \(fullCut.named.sorted()) quiet \(fullCut.quiet.sorted())")
let compactCut = A.names(cut, compact: true, onScreen: cutScreen)
check("drawn compact, the name goes to the answer's first row on screen",
      compactCut.named == [2] && compactCut.quiet == [3],
      "named \(compactCut.named.sorted()) quiet \(compactCut.quiet.sorted())")
check("…and a message above the window still opens its answer, drawn or not",
      A.names([.turnStart(chatOnly: false), .words, .turnStart(chatOnly: false), .words],
              compact: true, onScreen: [false, false, true, true]).named == [3])

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
let rules = source("SipAI/Utilities/ChatOnlyActivity.swift")

// Thoughts only when asked: a Chat only turn asks, and with compact view on
// every reader asks; with it off an agent turn keeps none.
check("claude's parser keeps no thought unless asked (default false)",
      squeeze(parser).contains("includeThinking: Bool = false) -> [StreamEvent]"))
check("codex's parser keeps no thought unless asked (default false)",
      squeeze(codexParser).contains("includeThinking: Bool = false) -> Parsed"))
check("all three readers keep no thought unless asked (default false)",
      squeeze(body(session, "static func readHistory(of url: URL")).isEmpty == false
      && squeeze(session).contains("includeThinking: Bool = false) -> [AgentSessionHistoryItem]")
      && squeeze(codex).contains("root: URL = sessionRoot, includeThinking: Bool = false)")
      && squeeze(kimi).contains("byteBudget: Int? = nil, includeThinking: Bool = false, wordlessFailure: String? = nil)"))
let stdoutHandler = body(runner, "private func handleStdoutLine")
check("the runner asks per TURN — the turn's own Chat only flag, or compact view — for claude and codex",
      stdoutHandler.components(separatedBy: "includeThinking: keepsThoughts").count == 3
      && squeeze(runner).contains("private var keepsThoughts: Bool { turnChatOnly || CompactTranscript.isOn }"))
check("…and kimi's headless turn reads its thoughts back off the wire for either, its ACP turn through the follower",
      squeeze(body(runner, "private func syncKimiThoughts"))
          .contains("guard isKimi, turnChatOnly || (turnIsKimiHeadless && CompactTranscript.isOn) else { return }")
      && source("SipAI/Models/KimiAcp.swift").contains("decoder.includeThinking = CompactTranscript.isOn"))
check("codex's app-server turn asks while compact view is on (no Chat only turn runs there)",
      source("SipAI/Models/CodexAppServerTurn.swift").contains("includeThinking: CompactTranscript.isOn)"))
check("the flag is the options the turn RAN with, stamped on its user message",
      runner.contains("startTurn(text: text, options: options, images: images, command: nil)")
      && squeeze(body(runner, "private func startTurn(")).contains("chatOnlyTurn: options.chatOnly")
      && squeeze(body(runner, "private func startTurn(")).contains("turnChatOnly = options.chatOnly"))
check("the tailer (another process's turns) asks for thoughts only while compact view is on",
      !tailer.isEmpty
      && tailer.components(separatedBy: "includeThinking: CompactTranscript.isOn").count == 3
      && tailer.contains("rollout.includeThinking = CompactTranscript.isOn")
      && tailer.contains("wire.includeThinking = CompactTranscript.isOn")
      && !tailer.contains("includeThinking: true"))
check("the flag is one lock-guarded value, set by the manager from the setting",
      squeeze(session).contains("enum CompactTranscript {")
      && source("SipAI/Models/AgentManager.swift").contains("CompactTranscript.set(on)"))
check("turned off, every runner drops the thoughts its live buffer kept for agent turns",
      squeeze(body(source("SipAI/Models/AgentManager.swift"), "private func followCompactView"))
          .contains("for runner in self.runners.values { runner.dropAgentTurnThoughts() }")
      && !body(runner, "func dropAgentTurnThoughts()").isEmpty)
// Full signatures: `widenHistoryForSearch()` is declared first and
// shares the prefix.
check("a reopened session keeps thoughts inside its recorded Chat only turns — every one while compact view is on",
      body(view, "private func startHistoryLoad(url: URL").contains("all: allThoughts, in: chatOnlyTurns")
      && body(view, "private func widenHistory(toBudget").contains("all: allThoughts, in: chatOnlyTurns")
      && body(view, "private func startHistoryLoad(url: URL").contains("let allThoughts = config.display.agentCompactView")
      && body(view, "private func widenHistory(toBudget").contains("let allThoughts = config.display.agentCompactView"))
check("switched with a session open, the transcript is read again in place",
      squeeze(view).contains(".onChange(of: config.display.agentCompactView) { _, _ in if case .existing(_, let url, _, _) = mode { startHistoryLoad(url: url, viaSpinner: false) } }"))

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
check("the agent's name over the line only where the name pass puts it (the line opens the answer)",
      line.contains("if named {") && line.contains("agentLabelHeader")
      && view.components(separatedBy: "activityLine(line, pairing: pairing, named: names.named.contains(").count == 3)
check("…a bubble inside a named answer leaves its name out",
      view.components(separatedBy: "showsHeader: !names.quiet.contains(").count == 3
      && squeeze(source("SipAI/Views/Chat/MessageBubble.swift")).contains("if showsHeader { header }"))
check("…and a chip that opens the answer takes it from the same pass",
      view.components(separatedBy: "showsLabel: names.named.contains(").count == 3
      && !view.contains("pairing.labelled") && !view.contains("labelled: Set<UUID>"))
check("…and while the agent has not answered yet, the name stands over \"Sipping…\"",
      squeeze(view).contains("if names.waitingNamed { VStack(alignment: .leading, spacing: 4 * gapScale) { agentLabelHeader waitingRow } } else { waitingRow }"))
check("the name pass hands the rule which rows the display window draws",
      squeeze(body(view, "private func transcriptNames(")).contains("ChatOnlyActivity.names(")
      && body(view, "private func transcriptNames(").contains("onScreen.append(i >= historyStart)")
      && body(view, "private func transcriptNames(").contains("onScreen.append(j >= liveFrom)")
      && body(view, "private func transcriptNames(").contains("onScreen: onScreen)"))
check("the line marks a failed step with the chip's orange triangle",
      line.contains("if summary.failures > 0 {")
      && line.contains("Image(systemName: \"exclamationmark.triangle.fill\")")
      && line.contains("failures: line.group.failures"))
check("the line has the app's hover fill (it has no frame of its own)",
      line.contains(".hoverFill(cornerRadius: 6)"))
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
check("find counts a thought (history and live), in the pieces its row draws",
      rows.components(separatedBy: "case .thinking(let text):").count == 3
      && rows.components(separatedBy: "thoughtTexts(text).joined(separator: \"\\n\")").count == 3)
check("a thought inside an opened line is a row in the chip's shape, opened through the chips' set — so a jump to it opens it",
      squeeze(body(view, "private func thoughtRow(")).contains("chipShell(chipId: id,")
      && squeeze(body(view, "private func jumpToActiveMatch")).contains("expandedToolResults.insert(match.rowId)"))
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
// A message of attached files alone has no words to find its record by:
// handed only its words (""), every writer resolves nothing, no record is
// kept, and the reopened turn reads as an agent turn. Its files are what
// tell it apart, as they do for Create Branch on such a row.
let recordBody = body(runner, "private func recordChatOnlyTurnIfNeeded")
check("…a turn whose message is attached files alone is found by its files: each writer is handed the turn's own",
      recordBody.components(separatedBy: "attachedFiles: files").count == 4
        && recordBody.contains("let files = inFlightUserFiles")
        && runner.contains("inFlightUserFiles = opening.attachedFiles"))
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
// Every front end's events land through one path (`apply`): a parsed
// stdout line, and a JSON-RPC driver's events.
let eventPath = body(runner, "private func apply(_ parsed: [StreamEvent])")
check("…and at the turn's `result` too, so a quick next send cannot skip it",
      between(eventPath, "endTurnSegment(failure: failure)", "applySubprocessSideEffects(for: event)")
          .contains("recordChatOnlyTurnIfNeeded()")
      && stdoutHandler.contains("apply(parsed)"))
let manager = source("SipAI/Models/AgentManager.swift")
check("the history cache remembers which Chat only turns its read kept thoughts for",
      manager.contains("let chatOnlyTurns: Set<String>")
      && body(view, "private func startHistoryLoad(url: URL").contains("chatOnlyTurns: chatOnlyTurns"))
check("…and an unchanged file is re-read when that set has moved",
      squeeze(body(view, "private func reload(migratedFromDraft: Bool = false)")).contains("cached.chatOnlyTurns == chatOnlyTurnHandles"))
check("…or when compact view was switched since the read",
      squeeze(body(view, "private func reload(migratedFromDraft: Bool = false)")).contains("cached.allThoughts == config.display.agentCompactView")
      && body(view, "private func startHistoryLoad(url: URL").contains("allThoughts: allThoughts")
      && manager.contains("let allThoughts: Bool"))

// The live buffer's front trim can cut a turn's message away.
let trim = squeeze(body(runner, "private func trimLiveEventsIfNeeded"))
check("the trim remembers what the turn it cut into ran as",
      trim.contains("trimmedHeadChatOnly = opener.chatOnlyTurn")
      && squeeze(body(runner, "func clearEvents()")).contains("trimmedHeadChatOnly = false"))
let layout = squeeze(body(view, "private func activityLayout(pairing: Pairing)"))
let planFn = squeeze(body(view, "private func activityPlan(pairing given: Pairing? = nil)"))
let rowMap = squeeze(body(view, "private func activityRows(pairing: Pairing)"))
check("compact view reaches the plan, and with it off nothing is worked out for a session with no Chat only turn",
      squeeze(body(view, "private var anythingFolds: Bool")).contains("compact || !chatOnlyTurns.isEmpty || runner.trimmedHeadChatOnly")
      && planFn.contains("guard anythingFolds else { return .none }")
      && planFn.contains("compact: compact, answerSettled: answerSettled")
      && layout.contains("let plan = activityPlan(pairing: pairing).plan")
      && view.contains("compact: config.display.agentCompactView,"))
check("the agent's question and a reviewed plan are ordinary steps: nothing keeps their chips out of the line",
      !view.contains("staysOutsideLines")
      && rowMap.contains("return .toolUse(name: name, title: AgentRendering.displayToolName(name),"))
check("Chat only has ONE look: the plan folds every answer by one rule, compact view only widening which",
      !rules.contains("chatOnlyRuns")
      && squeeze(body(rules, "static func plan(_ rows: [Row]")).contains("foldAll: compact"))
check("…and the transcript hands it to the plan at the seam",
      planFn.contains("liveStart: ChatOnlyActivity.LiveStart(row: h, chatOnly: runner.trimmedHeadChatOnly)")
      && squeeze(body(view, "private var anythingFolds: Bool")).contains("|| runner.trimmedHeadChatOnly"))

// The rows the one-line-per-answer rule reads, mapped from the transcript's own.
check("the agent's words are words; an error or Interrupted an outcome — history and live alike",
      rowMap.components(separatedBy: "add(.words(text))").count == 3
      && rowMap.contains("case .interrupted(let message), .error(let message): add(.outcome(message))")
      && rowMap.contains("case .error(let message), .interrupted(let message): add(.outcome(message))"))
check("a compaction is a notice, worded as its row, and the summary right after it is one too",
      rowMap.components(separatedBy: "add(.notice(Self.compactionMessage(preTokens: pre, postTokens: post)), compaction: true)").count == 3
      && rowMap.contains("if notice { return afterCompaction ? .notice(text) : .answerStart }")
      && squeeze(body(view, "private func compactionRow(")).contains("let message = Self.compactionMessage(preTokens: preTokens, postTokens: postTokens)"))
check("the user's words sent into the turn split the line; a notice the turn took in is inside it",
      rowMap.contains("if sentIntoTurn { return notice ? .notice(text) : .split }"))
check("a row that belongs to the agent's answer — a task reporting back, a reply on a question's card — is inside it",
      rowMap.contains("if belongsToAnswer { return .notice(text) }")
      && rowMap.components(separatedBy: "belongsToAnswer: item.belongsToAnswer").count == 2
      && rowMap.components(separatedBy: "belongsToAnswer: event.belongsToAnswer").count == 2)
check("a turn the agent starts on its own is a turn boundary: the final message is its newest turn's",
      rowMap.contains("case .systemInit: add(.turnBoundary)") && rowMap.contains("case .result: add(.invisible)"))
check("no second spinner: while a line is live it IS the waiting row",
      squeeze(view).contains("if awaitingFirstAgentEvent && approvalsForRunner.isEmpty && !activity.hasLiveLine {"))
check("a notice that opens an answer of its own, and a `!` command's output, open the next answer",
      rowMap.components(separatedBy: "case .shellOutput: add(.answerStart)").count == 3)
check("the plan knows another process's turn runs, and an answer that landed while the turn waits is done",
      planFn.contains("let turnRunning = runner.status.isRunning || runner.externalInProgress")
      && planFn.contains("let answerSettled = !runner.awaitedBackgroundTasks.isEmpty"))
check("the plan is worked out once per state of the rows, not per question asked of it",
      planFn.contains("if planCache.key == key { return planCache }")
      && view.contains("@State private var planCache = ActivityPlanCache()"))
let member = squeeze(body(view, "private func activityMemberContent("))
check("an opened line draws the agent's words without the name, with find's highlight, history and live",
      member.components(separatedBy: "memberWords(id:").count == 3
      && squeeze(body(view, "private func memberWords(")).contains("showsHeader: false")
      && squeeze(body(view, "private func memberWords(")).contains(".environment(\\.sipSearchSlot, find.slot(forRow: id))"))
check("…and its notices and errors as the full transcript draws them",
      member.contains("default: renderHistoricalItem(item, pairing: pairing, names: NameLayout())")
      && member.contains("default: renderEvent(event, pairing: pairing, names: NameLayout())"))
check("the line counts the messages it holds",
      line.contains("messages: line.group.messages"))
let names2 = squeeze(body(view, "private func transcriptNames("))
check("a notice or an error inside a line neither takes the name nor opens an answer",
      names2.components(separatedBy: "? drawn(item.id, .userColumn)").count == 2
      && names2.components(separatedBy: "? drawn(event.id, .userColumn)").count == 2
      && names2.contains("case .interrupted, .compaction, .error: row = drawn(item.id, .note)")
      && names2.contains("case .interrupted, .compaction, .error: row = drawn(event.id, .note)"))
// The display window: a folded transcript is mostly rows that draw nothing on their own.
let window = squeeze(body(view, "private var transcriptWindow: TranscriptSeam.Window"))
check("in compact view the window counts DRAWN rows (a line once), drawn in full it counts rows",
      window.contains("draws: drawnRows")
      && squeeze(body(view, "private var drawnRows: ((Int) -> Bool)?")).contains("guard compact else { return nil }"))
check("…and \"Show earlier\", its reveals and a find's jump count what the window counts",
      squeeze(view).contains("let older = rowsAbove(window) if older > 0 || historyHasMore {")
      && view.contains("Show earlier — \\(older) older rows")
      && squeeze(body(view, "private func showEarlierRows()")).contains("if let draws = drawnRows {")
      && squeeze(body(view, "private func revealRows(through index: Int)")).contains("drawnRows.map { TranscriptSeam.drawnCount(newTop..<top, $0) } ?? top - newTop"))
check("the drawn rows leave out what draws nothing — a result in its chip, plumbing — and count a line at its first member",
      planFn.contains("case .toolResult: drawn[i] = !pairing.consumed.contains(item.id)")
      && planFn.contains("case .thinking, .systemInit, .result: drawn[h + j] = false")
      && planFn.contains("for member in group.members.dropFirst() { drawn[member] = false }"))
// A line is drawn at its first member, and not at all once every member
// sits above the window — so a find jump into a folded line just above
// the window must grow the window to the line's FIRST member. Grown to
// the matched member alone, the only drawn row in between can be the
// answer's last words, and the line stays undrawn: a jump to nothing.
check("a find jump into a folded line reveals the line's first member, not the matched member alone",
      squeeze(body(view, "private func revealRows(through index: Int)"))
          .contains(": activityPlan().plan.group(containing: index)?.members.first ?? index"))

print("\n\(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
