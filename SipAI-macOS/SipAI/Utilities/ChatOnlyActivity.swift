// ChatOnlyActivity.swift
// How a Chat only turn is drawn: the model's thoughts and web lookups
// collapse into ONE line under the question. While the turn runs, the
// line names the newest step; once the agent's words follow, it settles
// into a one-line summary that opens, on a click, into the steps.
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
        /// A message the user sent. It opens a turn, and `chatOnly` says
        /// whether that turn ran in Chat only — which is what decides
        /// whether its steps collapse at all. Every other turn draws its
        /// rows exactly as it always has.
        case turnStart(chatOnly: Bool)
        /// A drawn row that is not a step: the agent's own words, an
        /// error, an interrupted or compaction marker, a notice in the
        /// user column. It ends a group. Words said between two lookups
        /// stay where the model said them, so a turn that talks between
        /// lookups draws one line on either side of the sentence.
        case boundary
        /// A readable thought.
        case thought(String)
        /// A tool call. `title` is the renderer's display name, which
        /// names a tool that is not a web lookup; `resultText` is its
        /// paired result's text, when it has landed.
        case toolUse(name: String, title: String, input: [String: Any],
                     resultText: String?)
        /// A tool's result. Drawn inside its call's chip (or as an
        /// orphan chip), so it joins the group its call is in.
        case toolResult
        /// Draws nothing — session plumbing, the turn's totals. It
        /// neither starts nor ends a group.
        case invisible
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
            return .tool(title: title)
        }
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
        for raw in thought.split(whereSeparator: \.isNewline) {
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
        /// after it, and its turn is running.
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

    /// Collapse every maximal run of thoughts and tool rows inside a
    /// Chat only turn into one group.
    ///
    /// Only a turn the user sent in Chat only is touched: outside one a
    /// thought is not drawn at all (the readers keep none there, and
    /// this treats a stray one as invisible) and a tool row stays the
    /// chip it always was. A run with no step in it — nothing but a
    /// result whose call fell outside the rows — is not a group either:
    /// there would be nothing to say on its line.
    ///
    /// A code-mode script immediately followed by a codex lookup is that
    /// lookup's container, whatever its text shows: codex records the
    /// search right after the script that ran it, and a reopened script
    /// is summarised to its first 80 characters, which a leading
    /// `// @exec: {…}` pragma can fill before `tools.` appears.
    static func plan(_ rows: [Row], turnRunning: Bool,
                     liveStart: LiveStart? = nil) -> Plan {
        var groups: [Group] = []
        var groupOfRow: [Int: Int] = [:]
        var inChatOnly = false
        var members: [Int] = []
        var steps: [Step] = []
        // The newest row drawn OUTSIDE a group. A group after it is the
        // newest thing on screen.
        var lastDrawnOutside = -1
        // The newest member was a script counted as a step of its own.
        var scriptStepLast = false

        func close() {
            defer { members = []; steps = []; scriptStepLast = false }
            guard !members.isEmpty else { return }
            guard !steps.isEmpty else {
                lastDrawnOutside = max(lastDrawnOutside, members.last ?? -1)
                return
            }
            let index = groups.count
            for member in members { groupOfRow[member] = index }
            groups.append(Group(members: members, steps: steps))
        }

        for (i, row) in rows.enumerated() {
            if let liveStart, i == liveStart.row {
                close()
                inChatOnly = liveStart.chatOnly
            }
            switch row {
            case .turnStart(let chatOnly):
                close()
                inChatOnly = chatOnly
                lastDrawnOutside = i
            case .boundary:
                close()
                lastDrawnOutside = i
            case .invisible:
                continue
            case .thought(let text):
                guard inChatOnly else { continue }
                members.append(i)
                scriptStepLast = false
                steps.append(.thought(headline: headline(of: text)))
            case .toolUse(let name, let title, let input, let resultText):
                guard inChatOnly else { lastDrawnOutside = i; continue }
                if scriptStepLast, codexWebToolNames.contains(name) {
                    steps.removeLast()
                }
                scriptStepLast = false
                members.append(i)
                if let step = step(forToolNamed: name, title: title, input: input,
                                   resultText: resultText) {
                    steps.append(step)
                    if name == "exec", case .tool = step { scriptStepLast = true }
                }
            case .toolResult:
                guard inChatOnly else { continue }
                members.append(i)
                scriptStepLast = false
            }
        }
        close()

        let live: Bool = {
            guard turnRunning, let tail = groups.last?.members.last else { return false }
            return tail > lastDrawnOutside
        }()
        return Plan(groups: groups, groupOfRow: groupOfRow, lastGroupIsLive: live)
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
                         comment: "Chat only activity line while a web search runs and its terms are unknown")
                : String(localized: "Searching the web for “\(query)”",
                         comment: "Chat only activity line while a web search runs; placeholder is the search terms")
        case .read(let url):
            let host = host(of: url)
            return host.isEmpty
                ? String(localized: "Reading a page",
                         comment: "Chat only activity line while a page is opened and its address is unknown")
                : String(localized: "Reading \(host)",
                         comment: "Chat only activity line while a page is opened; placeholder is the site, like python.org")
        case .find(let pattern, let url):
            return String(localized: "Looking for “\(pattern)” on \(host(of: url))",
                          comment: "Chat only activity line while codex searches inside a page; placeholders are the text looked for and the site")
        case .tool(let title):
            return String(localized: "Using \(title)",
                          comment: "Chat only activity line while a tool runs; placeholder is the tool's name")
        }
    }

    /// The newest step's words, for a live group.
    static func livePhrase(of group: Group) -> String? {
        group.steps.last.flatMap(livePhrase(for:))
    }

    /// What a group did, counted. Pages are DISTINCT addresses opened —
    /// a page fetched twice was read once — and codex's find-in-page
    /// looks inside a page it already opened, so it adds none, unless
    /// no page was opened in the group at all (it still read one).
    struct Summary: Equatable {
        var thoughts = 0
        var searches = 0
        var pages = 0
        var tools = 0
    }

    static func summary(of steps: [Step]) -> Summary {
        var summary = Summary()
        var pages: Set<String> = []
        var looked = false
        for step in steps {
            switch step {
            case .thought: summary.thoughts += 1
            case .search: summary.searches += 1
            case .read(let url): pages.insert(url)
            case .find: looked = true
            case .tool: summary.tools += 1
            }
        }
        summary.pages = pages.isEmpty && looked ? 1 : pages.count
        return summary
    }

    /// The settled line — ONE rule for every agent: the parts that
    /// apply, always in this order, joined by " · ". A thought is
    /// "Thought" however many there were; the others are counted.
    static func summaryText(_ summary: Summary) -> String {
        var parts: [String] = []
        if summary.thoughts > 0 {
            parts.append(String(localized: "Thought",
                                comment: "Settled Chat only activity line: the model thought before answering"))
        }
        if summary.searches == 1 {
            parts.append(String(localized: "Searched the web",
                                comment: "Settled Chat only activity line: one web search"))
        } else if summary.searches > 1 {
            parts.append(String(localized: "Searched the web \(summary.searches) times",
                                comment: "Settled Chat only activity line: several web searches; placeholder is the count"))
        }
        if summary.pages == 1 {
            parts.append(String(localized: "Read 1 page",
                                comment: "Settled Chat only activity line: one web page opened"))
        } else if summary.pages > 1 {
            parts.append(String(localized: "Read \(summary.pages) pages",
                                comment: "Settled Chat only activity line: several web pages opened; placeholder is the count"))
        }
        if summary.tools == 1 {
            parts.append(String(localized: "Used 1 tool",
                                comment: "Settled Chat only activity line: one other tool ran"))
        } else if summary.tools > 1 {
            parts.append(String(localized: "Used \(summary.tools) tools",
                                comment: "Settled Chat only activity line: several other tools ran; placeholder is the count"))
        }
        return parts.joined(separator: " · ")
    }

    /// The SF Symbol leading a settled line: a globe when the group
    /// looked anything up, a light bulb when it only thought.
    static func symbol(for summary: Summary) -> String {
        summary.searches + summary.pages + summary.tools > 0 ? "globe" : "lightbulb"
    }
}
