// ChatOnlyActivity.swift
// How a turn's work is drawn as ONE line that opens into its steps.
//
// With compact view on, every answer — everything between the user's
// message and the agent's final message — is one line: its thoughts, its
// tool calls, the words it says along the way, the agent's question with
// the user's answer and a plan once reviewed (their cards stand apart while
// they wait), a background task reporting back and the agent's reply to it.
// While the answer runs, the line names the newest of those; once it is
// done, the line settles into a one-line summary and the final message is
// drawn under it. Only the user's own words sent into the running turn stay
// where they happened and cut the line in two.
//
// A Chat only turn draws the same way with compact view on or off. With it
// off, an agent turn draws every row as it always has. The agent's name is
// drawn once per answer wherever an answer is folded.
//
// Pure — no SwiftUI, no runner, no view state — so the rules compile
// headless against a driver (`Verification/ChatOnlyActivity`), the same
// reason `ScheduledTaskScheduler.decide` is pure. The view reduces its
// rows to `Row`s, asks for a `Plan`, and draws what the plan says.

import Foundation

enum ChatOnlyActivity {

    // MARK: - Rows

    /// One transcript row, reduced to what the grouping reads.
    enum Row {
        /// A message the user sent, or a `!` command they ran. It opens a
        /// turn, and `chatOnly` says whether that turn ran in Chat only —
        /// which, with compact view off, is what decides whether its steps
        /// fold at all: every other turn then draws its rows exactly as it
        /// always has.
        case turnStart(chatOnly: Bool)
        /// Another row in the user column after which the agent answers
        /// on its own: a `!` command's output, a notice that is no report
        /// of the agent's own work (a local command's answer, a notice the
        /// agent's harness wrote). It ends the answer above it and opens
        /// the next, in the same turn.
        case answerStart
        /// The user's own words sent into the running answer (a message
        /// steered in). Drawn where it happened; in a folded answer it
        /// cuts the line in two.
        case split
        /// The agent's own words. In a folded answer, the words before the
        /// final message are part of its line; the final message is drawn
        /// under the line once the answer is done.
        case words(String)
        /// A row drawn among the agent's steps: a compaction and the
        /// summary that follows it, and a row in the user column that
        /// belongs to the answer — a background task reporting back, the
        /// user's reply on a question's card. Never an answer's last words:
        /// one that comes after the final message is drawn after it.
        case notice(String)
        /// How an answer went wrong: an error, or Interrupted. At an
        /// answer's end it is drawn with its last words; inside, a step of
        /// the line that failed.
        case outcome(String)
        /// A readable thought.
        case thought(String)
        /// A tool call. `title` is the renderer's display name, which
        /// names a tool the line has no words of its own for;
        /// `resultText` is its paired result's text, when it has landed,
        /// and `failed` says that result is an error — a closed line
        /// still says a step failed.
        case toolUse(name: String, title: String, input: [String: Any],
                     resultText: String?, failed: Bool = false)
        /// A tool's result. Drawn inside its call's chip (or as an
        /// orphan chip), so it joins the group its call is in.
        case toolResult
        /// Draws nothing — session plumbing, the turn's totals. It
        /// neither starts nor ends a group.
        case invisible
        /// Draws nothing: the agent starting a turn (claude's
        /// `system/init`). Inside an answer it is a turn the agent runs on
        /// its own — claude prints nothing else for an event of its
        /// Monitor tool, only the turn and the reply — so the final
        /// message is the newest such turn's words, and the replies before
        /// it are in the line.
        case turnBoundary
    }

    // MARK: - Steps

    /// What one member of a group did, in the words the line uses.
    enum Step: Equatable {
        /// A thought. `headline` is its first readable line with the
        /// markdown marks taken off; empty when it opens with nothing
        /// readable.
        case thought(headline: String)
        case search(query: String)
        /// A page opened: claude's WebFetch, kimi's FetchURL, codex's
        /// open_page.
        case read(url: String)
        /// Codex looking for text inside a page it opened.
        case find(pattern: String, url: String)
        /// Any other tool, under the renderer's display name.
        case tool(title: String)
        /// A file the agent opened: claude's and kimi's Read.
        case readFile(path: String)
        /// Files the agent wrote or changed. Empty where the call does
        /// not name them in the row (codex's file change).
        case edit(paths: [String])
        /// A shell command, as the agent wrote it.
        case command(String)
        /// A search through the files for a pattern: Grep, Glob.
        case findInFiles(pattern: String)
        /// A subagent, by the task it was handed.
        case agent(description: String)
        /// The agent's to-do list.
        case todo
        /// The agent asked the user on a card: claude's and kimi's
        /// AskUserQuestion, codex's blocking question in Plan mode.
        case question
        /// The agent put a plan to the user for review (ExitPlanMode).
        case plan
    }

    /// The step a tool call describes, or nil for a call that is only a
    /// container for steps counted on their own rows.
    ///
    /// Codex spells all three of its web actions under ONE name, with the
    /// action carried by the spelling of the value: the search terms, the
    /// page opened, or `'pattern' in <url>` — the same spelling on the
    /// live feed and on reopen, which is what lets the line read the same
    /// either way. A search run through codex's code mode starts with no
    /// query at all and names it only when it completes, so an empty
    /// value falls back to the result's text (`resultText`).
    ///
    /// Code mode itself is a container: an `exec` call whose script calls
    /// `tools.…` does its lookups through calls that have rows of their
    /// own, so counting it too would add "Used 1 tool" to every one. A
    /// script whose text is cut short of `tools.` is recognised by the
    /// lookup that follows it (`plan`).
    static func step(forToolNamed name: String, title: String,
                     input: [String: Any], resultText: String? = nil) -> Step? {
        func value(_ key: String) -> String {
            ((input[key] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch name {
        case "WebSearch":
            return .search(query: value("query"))
        case "WebFetch", "FetchURL":
            return .read(url: value("url"))
        case "web_search", "web_search_call":
            var text = value("query").isEmpty ? value("command") : value("query")
            if text.isEmpty {
                text = (resultText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // Completed with nothing to say: code mode surfaces a
                // page view under the search kind with an empty query
                // and an `other` action, and the reader draws no row for
                // it on reopen. No step here either, so the live line
                // and the reopened one count the same lookups.
                if text.isEmpty, resultText != nil { return nil }
            }
            return codexWebStep(text)
        case "exec" where value("command").contains("tools."):
            return nil
        default:
            return agentStep(forToolNamed: name, input: input) ?? .tool(title: title)
        }
    }

    /// The step one of the agent's own tools describes — reading, changing
    /// or searching the files, a command, a subagent, the to-do list — or
    /// nil for a tool the line counts as "a tool". Each agent spells them
    /// its own way (claude `file_path`, kimi `path`; codex names a row
    /// after its item's type — live, and reopened from codex's record of
    /// it — and after its call where an older codex recorded nothing), and
    /// the three spellings settle into the same words.
    static func agentStep(forToolNamed name: String, input: [String: Any]) -> Step? {
        func value(_ keys: String...) -> String {
            for key in keys {
                if let text = (input[key] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    return text
                }
            }
            return ""
        }
        switch name {
        case "Read", "ReadMediaFile", "NotebookRead":
            return .readFile(path: value("file_path", "path", "notebook_path"))
        case "image_view", "view_image":
            // Codex viewing an image; a reopened call codex kept no record
            // of names the file as `command`.
            return .readFile(path: value("path", "command"))
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = value("file_path", "path", "notebook_path")
            return .edit(paths: path.isEmpty ? [] : [path])
        case "file_change", "patch_apply":
            let paths = (input["changes"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["path"] as? String }
            return .edit(paths: paths)
        case "apply_patch":
            return .edit(paths: patchPaths(value("command", "input", "patch")))
        case "Bash", "command_execution", "shell", "local_shell_call", "exec_command",
             "shell_command":
            return .command(value("command", "cmd"))
        case "Grep", "Glob":
            return .findInFiles(pattern: value("pattern"))
        case "Task", "Agent", "AgentSwarm", "spawn_agent":
            return .agent(description: value("description", "prompt", "message", "command"))
        case "TodoWrite", "TodoList", "todo_list", "update_plan":
            return .todo
        case "AskUserQuestion", "request_user_input":
            return .question
        case "ExitPlanMode":
            return .plan
        default:
            return nil
        }
    }

    /// The files a codex patch names (`*** Update File: <path>`, and the
    /// Add, Delete and Move to lines), in order, each once. A reopened
    /// patch is a summary cut to length, so it may name fewer than it
    /// changed, or none.
    static func patchPaths(_ patch: String) -> [String] {
        var paths: [String] = []
        for marker in ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "] {
            var rest = patch[...]
            while let found = rest.range(of: marker) {
                let tail = rest[found.upperBound...]
                let path = tail.prefix { !$0.isWhitespace && $0 != "*" }
                if !path.isEmpty, !paths.contains(String(path)) { paths.append(String(path)) }
                rest = tail
            }
        }
        return paths
    }

    /// A command's first line, with a shell's `-lc '…'` wrapper taken off
    /// — codex hands a command over as `/bin/zsh -lc 'ls'` — and its white
    /// space collapsed. What the live line says while it runs.
    static func commandLine(_ command: String) -> String {
        var text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for shell in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc ", "/bin/sh -c "] {
            guard text.hasPrefix(shell) else { continue }
            var inner = text.dropFirst(shell.count)
            if inner.count >= 2, let quote = inner.first, quote == "'" || quote == "\"",
               inner.last == quote {
                inner = inner.dropFirst().dropLast()
            }
            text = String(inner)
            break
        }
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A path's last part, for "Reading AgentRunner.swift".
    static func fileName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    static func codexWebStep(_ text: String) -> Step {
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            return .read(url: text)
        }
        // The `' in ` found may be the opening quote itself (`' in x`);
        // slicing from past that quote to it would run backwards and trap,
        // and the text is the model's own query, so it can say anything.
        if text.hasPrefix("'"),
           let cut = text.range(of: "' in ", options: .backwards),
           cut.lowerBound >= text.index(after: text.startIndex) {
            let pattern = String(text[text.index(after: text.startIndex)..<cut.lowerBound])
            let url = String(text[cut.upperBound...])
            if !pattern.isEmpty, !url.isEmpty {
                return .find(pattern: pattern, url: url)
            }
        }
        return .search(query: text)
    }

    /// A thought's first readable line, with its markdown marks taken off
    /// and its whitespace collapsed. Codex opens a reasoning summary with
    /// a bold title (`**Weighing the sources**`), which is exactly the
    /// line's worth.
    ///
    /// The line is drawn verbatim, so every mark a renderer would have
    /// consumed has to come off here: heading and quote marks, one list
    /// marker, bold and code marks anywhere in the line (claude's
    /// thoughts name identifiers in backticks). A fenced block and a
    /// rule are not lines of text and are skipped.
    static func headline(of thought: String) -> String {
        var inFence = false
        // Line by line from the top, never split whole: the first readable
        // line is near the top, and a long message or thought would
        // otherwise cost its whole length on every fold.
        var rest = thought[...]
        while !rest.isEmpty {
            let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
            let raw = rest[..<end]
            rest = end < rest.endIndex ? rest[rest.index(after: end)...] : rest[end...]
            if raw.isEmpty { continue }
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            // Heading and quote marks only where markdown reads them:
            // a run of `#` or `>` followed by a space, or alone.
            // `#include <stdio.h>` and `>= 3 results` are content.
            while let mark = line.first, mark == "#" || mark == ">" {
                let run = line.prefix { $0 == mark }
                let rest = line[run.endIndex...]
                guard rest.isEmpty || rest.first == " " else { break }
                line = rest.trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                line = String(line.dropFirst(2))
            } else if let end = line.firstIndex(where: { !("0"..."9").contains($0) }),
                      end > line.startIndex,
                      line[end...].hasPrefix(". ") || line[end...].hasPrefix(") ") {
                line = String(line[line.index(end, offsetBy: 2)...])
            }
            if !line.isEmpty, line.allSatisfy({ "-*_= ".contains($0) }) { continue }
            // Bold and code marks come off in PAIRS only: `2**8` and a
            // lone backtick are content, not marks.
            if line.components(separatedBy: "**").count >= 3 {
                line = line.replacingOccurrences(of: "**", with: "")
            }
            if line.filter({ $0 == "`" }).count >= 2 {
                line = line.replacingOccurrences(of: "`", with: "")
            }
            let collapsed = line
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            if !collapsed.isEmpty { return collapsed }
        }
        return ""
    }

    /// A URL's host without a leading `www.`, for "Reading python.org".
    /// A value that is not a URL reads as itself. A trailing `…` (a
    /// summary cut to length) is ignored.
    static func host(of url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("…") { text.removeLast() }
        guard let host = URL(string: text)?.host, !host.isEmpty else { return text }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - Groups

    struct Group: Equatable {
        /// Row indices, in order. The first is the group's identity.
        let members: [Int]
        /// The steps the members describe, in order — one per thought
        /// and per tool call; results describe none of their own.
        let steps: [Step]
        /// How many of those steps ended in an error, with every error
        /// row inside the line.
        var failures = 0
        /// The group folds an AGENT turn (compact view), not a Chat only
        /// one: its glyph says tools, not the web, once it ran any.
        var agentTurn = false
        /// How many of the agent's messages the line holds.
        var messages = 0
        /// The newest member's own words when it is a message, a notice
        /// or an error — what a live line says — and nil when it is a step
        /// (the step says its own, `livePhrase(for:)`).
        var words: String? = nil

        /// The row the group is drawn at: its first member inside the
        /// display window, or nil when the whole group is above it. A
        /// group straddling the window's top edge is drawn whole, at its
        /// first visible member, rather than cut — a line that lost its
        /// opening steps would summarise a different turn. A member, not
        /// the window's first row: invisible rows can sit between two
        /// members, and one of those draws nothing.
        func anchor(windowStart: Int) -> Int? {
            members.first { $0 >= windowStart }
        }
    }

    struct Plan: Equatable {
        let groups: [Group]
        /// Row index → index into `groups`, for every member.
        let groupOfRow: [Int: Int]
        /// The last group is still being written: nothing drawn comes
        /// after it, and its answer is running.
        let lastGroupIsLive: Bool

        static let empty = Plan(groups: [], groupOfRow: [:], lastGroupIsLive: false)

        func group(containing row: Int) -> Group? {
            groupOfRow[row].map { groups[$0] }
        }

        /// Whether `group` is the one still being written.
        func isLive(_ group: Group) -> Bool {
            lastGroupIsLive && groups.last == group
        }
    }

    /// Where the transcript's live rows begin: its rows are the loaded
    /// history followed by the runner's live buffer, and the two never
    /// share a group. The buffer is cut from the front once it grows
    /// long, and the cut can land inside a turn — its message gone, its
    /// steps still there — so `chatOnly` says what THAT turn ran as
    /// (`AgentRunner.trimmedHeadChatOnly`), and the rest of it keeps its
    /// look. A buffer that opens at a message says so itself.
    struct LiveStart: Equatable {
        let row: Int
        let chatOnly: Bool
    }

    /// Codex's lookups, each of which can be run from inside a code-mode
    /// script (see `plan`).
    private static let codexWebToolNames: Set<String> = ["web_search", "web_search_call"]

    /// Every codex item a code-mode script can drive and the live feed
    /// draws as a row of its own: in an agent turn the script before one
    /// is its container, as it is a lookup's in a Chat only turn.
    private static let codexDrivenToolNames: Set<String> = codexWebToolNames.union(
        ["command_execution", "file_change", "patch_apply", "mcp_tool_call", "todo_list"])

    /// Folds what the agent did into lines: ONE line per answer
    /// (`answerLines`) — every answer with `compact` on, a Chat only
    /// turn's whether it is on or off.
    ///
    /// - turnRunning: a turn is running — this app's or another
    ///   process's — so the newest answer may still be written.
    /// - answerSettled: that running turn's answer has landed and the turn
    ///   only waits (a background task the agent started): the answer is
    ///   done, and its final message is drawn under its line.
    ///
    /// An answer that does not fold draws as it always has: a tool row
    /// stays the chip it always was, and a thought is not drawn at all
    /// (the readers keep none outside a folded answer, and this treats a
    /// stray one as invisible). A line with nothing to say — nothing but a
    /// result whose call fell outside the rows — is not a line.
    ///
    /// A code-mode script immediately followed by a codex lookup is that
    /// lookup's container, whatever its text shows: codex records the
    /// search right after the script that ran it, and a reopened script
    /// is summarised to its first 80 characters, which a leading
    /// `// @exec: {…}` pragma can fill before `tools.` appears. In an
    /// agent turn a script is a step of its own — a reopened codex turn
    /// is made of little else — unless a row it drove follows it.
    static func plan(_ rows: [Row], turnRunning: Bool,
                     liveStart: LiveStart? = nil, compact: Bool = false,
                     answerSettled: Bool = false) -> Plan {
        var builder = Builder()
        let running = turnRunning && !answerSettled
        builder.answerLines(rows, liveStart: liveStart, newestIsRunning: running, foldAll: compact)
        let live: Bool = {
            guard turnRunning, !answerSettled,
                  let tail = builder.groups.last?.members.last else { return false }
            return tail > builder.lastDrawnOutside
        }()
        return Plan(groups: builder.groups, groupOfRow: builder.groupOfRow, lastGroupIsLive: live)
    }

    /// The fold's working state: the line being gathered, and the lines
    /// gathered so far.
    private struct Builder {
        var groups: [Group] = []
        var groupOfRow: [Int: Int] = [:]
        /// The newest row drawn OUTSIDE a line. A line after it is the
        /// newest thing on screen.
        var lastDrawnOutside = -1
        /// The line being gathered folds an agent turn's answer.
        var agentTurn = false
        private var members: [Int] = []
        private var steps: [Step] = []
        /// One per step: whether its call ended in an error.
        private var failed: [Bool] = []
        private var errors = 0
        private var messages = 0
        /// The newest member's own text when it said something (a message,
        /// a notice, an error); its first line is read once, at `close`.
        private var words: String? = nil
        /// The newest member was a script counted as a step of its own.
        private var scriptStepLast = false

        /// Ends the line being gathered. A line needs something to say
        /// once it settles — a step, the agent's words, an error: a run of
        /// results alone, or of notices alone (a `/compact`'s compaction
        /// and its summary opening an answer), would settle into a line
        /// with nothing on it, so its rows stay rows and count as drawn
        /// outside.
        mutating func close() {
            defer {
                members = []; steps = []; failed = []
                errors = 0; messages = 0; words = nil; scriptStepLast = false
            }
            guard !members.isEmpty else { return }
            guard !steps.isEmpty || messages > 0 || errors > 0 else {
                lastDrawnOutside = max(lastDrawnOutside, members.last ?? -1)
                return
            }
            let index = groups.count
            for member in members { groupOfRow[member] = index }
            groups.append(Group(members: members, steps: steps,
                                failures: failed.filter { $0 }.count + errors,
                                agentTurn: agentTurn, messages: messages,
                                words: words.map(headline(of:))))
        }

        mutating func drawnOutside(_ i: Int) {
            close()
            lastDrawnOutside = max(lastDrawnOutside, i)
        }

        mutating func thought(_ i: Int, _ text: String) {
            members.append(i)
            scriptStepLast = false
            words = nil
            steps.append(.thought(headline: headline(of: text)))
            failed.append(false)
        }

        mutating func tool(_ i: Int, name: String, title: String, input: [String: Any],
                           resultText: String?, failed didFail: Bool) {
            let driven = agentTurn ? codexDrivenToolNames : codexWebToolNames
            if scriptStepLast, driven.contains(name) {
                steps.removeLast()
                failed.removeLast()
            }
            scriptStepLast = false
            members.append(i)
            var found = step(forToolNamed: name, title: title, input: input,
                             resultText: resultText)
            if found == nil, agentTurn, name == "exec" { found = .tool(title: title) }
            if let step = found {
                steps.append(step)
                failed.append(didFail)
                words = nil
                if name == "exec", case .tool = step { scriptStepLast = true }
            }
        }

        mutating func result(_ i: Int) {
            members.append(i)
            scriptStepLast = false
        }

        /// The agent's words, a notice or an error, inside a line.
        mutating func said(_ i: Int, _ text: String, message: Bool = false, error: Bool = false) {
            members.append(i)
            scriptStepLast = false
            words = text
            if message { messages += 1 }
            if error { errors += 1 }
        }

        /// ONE line per answer — everything the agent did after a row in
        /// the user column, up to the next one — wherever the answer is
        /// folded: every answer with `foldAll` (compact view), a Chat only
        /// turn's always.
        ///
        /// A done answer's final message — the agent's words, and an error
        /// or Interrupted, after its last step in the newest turn it ran —
        /// is drawn under the line, and so are the user's own words sent
        /// into the turn (`split`), which cut the line in two. While the
        /// newest answer is still being written (`newestIsRunning`) every
        /// message it says is in the line, which names the newest: none of
        /// them is known to be the last until the agent says the answer is
        /// done.
        mutating func answerLines(_ rows: [Row], liveStart: LiveStart?, newestIsRunning: Bool,
                                  foldAll: Bool) {
            // The rows of the answer being gathered, after its opening row.
            var answer: [Int] = []
            // Rows before the first message read belong to an answer that
            // opened above the loaded history: they fold with compact view.
            var chatOnly = false

            func finish(running: Bool) {
                defer { answer = [] }
                guard foldAll || chatOnly else {
                    for i in answer {
                        switch rows[i] {
                        case .invisible, .turnBoundary, .thought, .toolResult: continue
                        default: lastDrawnOutside = max(lastDrawnOutside, i)
                        }
                    }
                    return
                }
                agentTurn = !chatOnly
                var lineEnd = answer.count
                if !running {
                    // The final message is the newest turn's: a turn the
                    // agent started on its own (claude's reply to one event
                    // of its Monitor tool) ends the scan once words are in
                    // hand. A notice after the words came after the final
                    // message, and is drawn after it.
                    var k = answer.count
                    var endsInWords = false
                    scan: while k > 0 {
                        switch rows[answer[k - 1]] {
                        case .invisible: k -= 1
                        case .words, .outcome: k -= 1; endsInWords = true
                        case .notice where !endsInWords, .turnBoundary where !endsInWords: k -= 1
                        default: break scan
                        }
                    }
                    if endsInWords { lineEnd = k }
                }
                for i in answer[..<lineEnd] {
                    switch rows[i] {
                    case .split: drawnOutside(i)
                    case .invisible, .turnBoundary: continue
                    case .thought(let text): thought(i, text)
                    case .toolUse(let name, let title, let input, let resultText, let didFail):
                        tool(i, name: name, title: title, input: input,
                             resultText: resultText, failed: didFail)
                    case .toolResult: result(i)
                    case .words(let text): said(i, text, message: true)
                    case .notice(let text): said(i, text)
                    case .outcome(let text): said(i, text, error: true)
                    case .turnStart, .answerStart: drawnOutside(i)
                    }
                }
                close()
                for i in answer[lineEnd...] {
                    switch rows[i] {
                    case .invisible, .turnBoundary: continue
                    default: lastDrawnOutside = max(lastDrawnOutside, i)
                    }
                }
            }

            for (i, row) in rows.enumerated() {
                if let liveStart, i == liveStart.row {
                    finish(running: false)
                    chatOnly = liveStart.chatOnly
                }
                switch row {
                case .turnStart(let open):
                    finish(running: false)
                    chatOnly = open
                    lastDrawnOutside = i
                case .answerStart:
                    finish(running: false)
                    lastDrawnOutside = i
                default:
                    answer.append(i)
                }
            }
            finish(running: newestIsRunning)
        }
    }

    // MARK: - What the line says

    /// The words for a step while its group is live, or nil when the
    /// step has nothing readable to say (a thought with no text) — the
    /// line then reads "Sipping…", as it did before the first step.
    static func livePhrase(for step: Step) -> String? {
        switch step {
        case .thought(let headline):
            return headline.isEmpty ? nil : headline
        case .search(let query):
            return query.isEmpty
                ? String(localized: "Searching the web",
                         comment: "Activity line while a web search runs and its terms are unknown")
                : String(localized: "Searching the web for “\(query)”",
                         comment: "Activity line while a web search runs; placeholder is the search terms")
        case .read(let url):
            let host = host(of: url)
            return host.isEmpty
                ? String(localized: "Reading a page",
                         comment: "Activity line while a page is opened and its address is unknown")
                : String(localized: "Reading \(host)",
                         comment: "Activity line while a page or a file is opened; placeholder is the site (python.org) or the file's name")
        case .find(let pattern, let url):
            return String(localized: "Looking for “\(pattern)” on \(host(of: url))",
                          comment: "Activity line while codex searches inside a page; placeholders are the text looked for and the site")
        case .tool(let title):
            return String(localized: "Using \(title)",
                          comment: "Activity line while a tool runs; placeholder is the tool's name")
        case .readFile(let path):
            let name = fileName(path)
            return name.isEmpty
                ? String(localized: "Reading a file",
                         comment: "Activity line while the agent opens a file whose name is unknown")
                : String(localized: "Reading \(name)",
                         comment: "Activity line while a page or a file is opened; placeholder is the site (python.org) or the file's name")
        case .edit(let paths):
            return paths.count == 1
                ? String(localized: "Editing \(fileName(paths[0]))",
                         comment: "Activity line while the agent changes a file; placeholder is the file's name")
                : String(localized: "Editing files",
                         comment: "Activity line while the agent changes files it does not name one by one")
        case .command(let text):
            let line = commandLine(text)
            return line.isEmpty
                ? String(localized: "Running a command",
                         comment: "Activity line while the agent runs a shell command it does not show")
                : String(localized: "Running \(line)",
                         comment: "Activity line while the agent runs a shell command; placeholder is the command")
        case .findInFiles(let pattern):
            return pattern.isEmpty
                ? String(localized: "Searching the files",
                         comment: "Activity line while the agent searches its files for something it does not name")
                : String(localized: "Searching for “\(pattern)”",
                         comment: "Activity line while the agent searches its files; placeholder is the pattern")
        case .agent(let description):
            return description.isEmpty
                ? String(localized: "Running an agent",
                         comment: "Activity line while the agent runs a subagent")
                : String(localized: "Running an agent: \(description)",
                         comment: "Activity line while the agent runs a subagent; placeholder is the task it was given")
        case .todo:
            return String(localized: "Updating the to-do list",
                          comment: "Activity line while the agent updates its to-do list")
        case .question:
            return String(localized: "Asking you a question",
                          comment: "Activity line: the agent's question waits on its card for an answer")
        case .plan:
            return String(localized: "Asking you to review a plan",
                          comment: "Activity line: the agent's plan waits on its card for a review")
        }
    }

    /// What a live line says: its newest member's words — a message's or
    /// a notice's first line, else the newest step's (`livePhrase(for:)`).
    /// Nil when that has nothing readable to say: the line then reads
    /// "Sipping…".
    static func livePhrase(of group: Group) -> String? {
        if let words = group.words { return words.isEmpty ? nil : words }
        return group.steps.last.flatMap(livePhrase(for:))
    }

    /// What a group did, counted. Pages are DISTINCT addresses opened —
    /// a page fetched twice was read once — and codex's find-in-page
    /// looks inside a page it already opened, so it adds none, unless
    /// no page was opened in the group at all (it still read one).
    ///
    /// Files are counted the same way: a file read twice was read once,
    /// a file changed twice was changed once. A change that names no file
    /// (codex's file change) counts as one file of its own.
    struct Summary: Equatable {
        var thoughts = 0
        var searches = 0
        var pages = 0
        var tools = 0
        var edits = 0
        var commands = 0
        var filesRead = 0
        var fileSearches = 0
        var agents = 0
        /// The agent's questions answered on a card, and plans reviewed.
        var questions = 0
        var plans = 0
        /// The agent's messages inside the line (compact view).
        var messages = 0
        var failures = 0
    }

    static func summary(of steps: [Step], failures: Int = 0, messages: Int = 0) -> Summary {
        var summary = Summary()
        var pages: Set<String> = []
        var looked = false
        var read: Set<String> = []
        var unnamedReads = 0
        var changed: Set<String> = []
        var unnamedEdits = 0
        for step in steps {
            switch step {
            case .thought: summary.thoughts += 1
            case .search: summary.searches += 1
            case .read(let url): pages.insert(url)
            case .find: looked = true
            case .tool, .todo: summary.tools += 1
            case .readFile(let path):
                if path.isEmpty { unnamedReads += 1 } else { read.insert(path) }
            case .edit(let paths):
                if paths.isEmpty { unnamedEdits += 1 } else { changed.formUnion(paths) }
            case .command: summary.commands += 1
            case .findInFiles: summary.fileSearches += 1
            case .agent: summary.agents += 1
            case .question: summary.questions += 1
            case .plan: summary.plans += 1
            }
        }
        summary.pages = pages.isEmpty && looked ? 1 : pages.count
        summary.filesRead = read.count + unnamedReads
        summary.edits = changed.count + unnamedEdits
        summary.messages = messages
        summary.failures = failures
        return summary
    }

    /// The settled line — ONE rule for every agent: the parts that
    /// apply, always in this order, joined by " · ". A thought is
    /// "Thought" however many there were; the others are counted — the
    /// agent's messages after its steps, the word Kimi Code's terminal and
    /// the Codex app count them by — and a step that failed is said last,
    /// so a closed line never hides one.
    static func summaryText(_ summary: Summary) -> String {
        var parts: [String] = []
        if summary.thoughts > 0 {
            parts.append(String(localized: "Thought",
                                comment: "Settled activity line: the model thought before answering"))
        }
        if summary.edits == 1 {
            parts.append(String(localized: "Edited 1 file",
                                comment: "Settled activity line: the agent changed one file"))
        } else if summary.edits > 1 {
            parts.append(String(localized: "Edited \(summary.edits) files",
                                comment: "Settled activity line: the agent changed several files; placeholder is the count"))
        }
        if summary.commands == 1 {
            parts.append(String(localized: "Ran 1 command",
                                comment: "Settled activity line: the agent ran one shell command"))
        } else if summary.commands > 1 {
            parts.append(String(localized: "Ran \(summary.commands) commands",
                                comment: "Settled activity line: the agent ran several shell commands; placeholder is the count"))
        }
        if summary.filesRead == 1 {
            parts.append(String(localized: "Read 1 file",
                                comment: "Settled activity line: the agent opened one file"))
        } else if summary.filesRead > 1 {
            parts.append(String(localized: "Read \(summary.filesRead) files",
                                comment: "Settled activity line: the agent opened several files; placeholder is the count"))
        }
        // Claude Code's own words for a Grep or a Glob ("searched for N
        // patterns") — "searched the web" is the lookup below.
        if summary.fileSearches == 1 {
            parts.append(String(localized: "Searched for 1 pattern",
                                comment: "Settled activity line: the agent searched its files once (a grep or a glob)"))
        } else if summary.fileSearches > 1 {
            parts.append(String(localized: "Searched for \(summary.fileSearches) patterns",
                                comment: "Settled activity line: the agent searched its files several times; placeholder is the count"))
        }
        if summary.searches == 1 {
            parts.append(String(localized: "Searched the web",
                                comment: "Settled activity line: one web search"))
        } else if summary.searches > 1 {
            parts.append(String(localized: "Searched the web \(summary.searches) times",
                                comment: "Settled activity line: several web searches; placeholder is the count"))
        }
        if summary.pages == 1 {
            parts.append(String(localized: "Read 1 page",
                                comment: "Settled activity line: one web page opened"))
        } else if summary.pages > 1 {
            parts.append(String(localized: "Read \(summary.pages) pages",
                                comment: "Settled activity line: several web pages opened; placeholder is the count"))
        }
        if summary.agents == 1 {
            parts.append(String(localized: "Ran 1 agent",
                                comment: "Settled activity line: the agent ran one subagent"))
        } else if summary.agents > 1 {
            parts.append(String(localized: "Ran \(summary.agents) agents",
                                comment: "Settled activity line: the agent ran several subagents; placeholder is the count"))
        }
        if summary.tools == 1 {
            parts.append(String(localized: "Used 1 tool",
                                comment: "Settled activity line: one other tool ran"))
        } else if summary.tools > 1 {
            parts.append(String(localized: "Used \(summary.tools) tools",
                                comment: "Settled activity line: several other tools ran; placeholder is the count"))
        }
        if summary.questions == 1 {
            parts.append(String(localized: "1 question",
                                comment: "Settled activity line: one question asked on a card, with its answer"))
        } else if summary.questions > 1 {
            parts.append(String(localized: "\(summary.questions) questions",
                                comment: "Settled activity line: questions asked on cards; placeholder is the count"))
        }
        if summary.plans == 1 {
            parts.append(String(localized: "1 plan",
                                comment: "Settled activity line: one plan put to the user for review"))
        } else if summary.plans > 1 {
            parts.append(String(localized: "\(summary.plans) plans",
                                comment: "Settled activity line: plans put to the user; placeholder is the count"))
        }
        if summary.messages == 1 {
            parts.append(String(localized: "1 message",
                                comment: "Settled activity line: the line holds one of the agent's messages, said between its steps"))
        } else if summary.messages > 1 {
            parts.append(String(localized: "\(summary.messages) messages",
                                comment: "Settled activity line: the line holds several of the agent's messages, said between its steps; placeholder is the count"))
        }
        if summary.failures > 0 {
            parts.append(String(localized: "\(summary.failures) failed",
                                comment: "Settled activity line, last part: how many of the steps ended in an error; placeholder is the count"))
        }
        return parts.joined(separator: " · ")
    }

    /// The SF Symbol leading a settled line: a light bulb when the group
    /// only thought; a globe when it looked things up — in a Chat only
    /// turn, any tool it ran is a lookup — and the tool chip's own wrench
    /// when an agent turn worked on the Mac: its files, a command, a
    /// subagent, any other tool. A line that holds only the conversation —
    /// the agent's messages, its questions and plans put to the user —
    /// leads with a speech bubble.
    static func symbol(for summary: Summary, agentTurn: Bool = false) -> String {
        let work = summary.edits + summary.commands + summary.filesRead
            + summary.fileSearches + summary.agents + (agentTurn ? summary.tools : 0)
        if work > 0 { return "wrench.and.screwdriver" }
        if summary.searches + summary.pages + summary.tools > 0 { return "globe" }
        let said = summary.messages + summary.questions + summary.plans
        return summary.thoughts == 0 && said > 0 ? "text.bubble" : "lightbulb"
    }

    // MARK: - Who draws the agent's name

    /// One transcript row, reduced to what the name rule reads.
    enum NameRow: Equatable {
        /// A message the user sent. It opens a turn and the agent's answer
        /// to it; `chatOnly` says whether that turn ran in Chat only.
        case turnStart(chatOnly: Bool)
        /// Another row in the user column — a notice, a reply sent into
        /// the running turn, a `!` command's output. The agent's rows
        /// after it are an answer of their own, in the same turn.
        case userColumn
        /// The agent's words: a bubble whose header IS the name.
        case words
        /// A tool call drawn on its own (a chip).
        case chip
        /// An activity line, at the row it is drawn at.
        case line
        /// A note of the agent's — interrupted, compaction, an error. It
        /// neither takes the name nor ends the answer.
        case note
        /// Draws nothing here: a member of a line that is not where the
        /// line is drawn, a result folded into its chip, plumbing.
        case silent
    }

    struct Names: Equatable {
        /// Rows that carry the name: a chip or a line has it drawn above
        /// it, a bubble keeps its header.
        var named: Set<Int> = []
        /// The agent's words whose bubble draws NO header.
        var quiet: Set<Int> = []
        /// The newest answer has drawn nothing yet and its name is owed:
        /// it goes over the "Sipping…" row, so nothing moves when the
        /// first step lands in that row's place.
        var waitingNamed = false
    }

    /// Who draws the agent's name. Inside an answer drawn compact — every
    /// turn with `compact` on, a Chat only turn always — the name is drawn
    /// ONCE, above the first thing the answer draws ON SCREEN (a line, a
    /// chip, or its words: `onScreen` says which rows the display window
    /// draws, and an answer whose top is above the window is named at the
    /// window's top), and the answer's later words draw no header. Every
    /// other answer keeps the old rule whatever the window: each bubble has
    /// its header, and a chip carries the name only when it opens the
    /// answer.
    static func names(_ rows: [NameRow], compact: Bool,
                      liveStart: LiveStart? = nil,
                      onScreen: [Bool]? = nil) -> Names {
        var out = Names()
        var once = compact
        var named = false
        for (i, listed) in rows.enumerated() {
            if let liveStart, i == liveStart.row {
                once = compact || liveStart.chatOnly
                named = false
            }
            // The user column is structure, drawn or not; the agent's own
            // rows above the window take no part in a compact answer.
            var row = listed
            if once, let onScreen, i < onScreen.count, !onScreen[i] {
                switch listed {
                case .words, .chip, .line, .note: row = .silent
                case .turnStart, .userColumn, .silent: break
                }
            }
            switch row {
            case .turnStart(let chatOnly):
                once = compact || chatOnly
                named = false
            case .userColumn:
                named = false
            case .words:
                if !named {
                    out.named.insert(i)
                    named = true
                } else if once {
                    out.quiet.insert(i)
                }
            case .chip, .line:
                if !named {
                    out.named.insert(i)
                    named = true
                }
            case .note, .silent:
                break
            }
        }
        out.waitingNamed = once && !named
        return out
    }
}
