// AgentRendering.swift
// Pure formatting helpers for stream-json rendering: tool-input and
// tool-result summaries, path shortening, truncation, edit line
// ranges, durations, and the per-tool body renderers.
//
// These produce plain strings / structured rows that the SwiftUI agent
// session view turns into styled Text views — no ANSI escapes.

import Foundation

// MARK: - Constants

enum AgentRenderingLimits {
    /// Cap for a one-line streamed summary.
    static let streamTrunc = 80
    /// Cap for tool_input rendering in full mode.
    static let fullToolLines = 200
    /// Cap for tool_result body in full mode.
    static let fullResultLines = 20
}

enum AgentRendering {

    // MARK: - Shared scalar helpers

    /// Collapse newlines, trim, ellipsize past `n` chars.
    static func truncate(_ s: String, _ n: Int = AgentRenderingLimits.streamTrunc) -> String {
        let collapsed = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if collapsed.count <= n { return collapsed }
        let head = String(collapsed.prefix(n - 1))
        return head + "…"
    }

    /// Replace a leading `$HOME` with `~`.
    static func shortenPath(_ p: String) -> String {
        guard !p.isEmpty else { return "" }
        let home = NSHomeDirectory()
        if p.hasPrefix(home) {
            return "~" + String(p.dropFirst(home.count))
        }
        return p
    }

    /// `60s → "1m 0s"`, `3600s → "1h 0m 0s"`, else `{s}s`.
    static func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return "\(h)h \(m)m \(sec)s"
    }

    // MARK: - Tool input summary (single-line header)

    /// One-line summary of a tool call's input, for a collapsed row.
    static func summarizeToolInput(name: String, input: [String: Any]) -> String {
        let inp = input
        switch name {
        case "Read":
            // Claude names the file `file_path` and the lines `offset` /
            // `limit`; Kimi Code names them `path` and `line_offset` /
            // `n_lines`.
            let fp = shortenPath((inp["file_path"] as? String) ?? (inp["path"] as? String) ?? "")
            func span(_ offset: String, _ count: String) -> (Int, Int)? {
                guard let off = asInt(inp[offset]), let lim = asInt(inp[count]) else { return nil }
                return (off, lim)
            }
            if let (off, lim) = span("offset", "limit") ?? span("line_offset", "n_lines") {
                // Values come straight from session JSONL — clamp
                // instead of trapping on a corrupt offset near Int.max
                // (display value only).
                let (end, overflowed) = off.addingReportingOverflow(lim)
                return "\(fp), lines \(off)-\(overflowed ? Int.max : end)"
            }
            return fp
        case "Grep", "Glob":
            let pat = truncate((inp["pattern"] as? String) ?? "", 40)
            let path = shortenPath((inp["path"] as? String) ?? "")
            return "\"\(pat)\"" + (path.isEmpty ? "" : ", \(path)")
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let fp = (inp["file_path"] as? String) ?? (inp["notebook_path"] as? String)
                ?? (inp["path"] as? String) ?? ""
            return shortenPath(fp)
        case "file_change", "patch_apply":
            // Codex's file change: one file by its path, as an Edit row;
            // several by their names.
            let paths = fileChanges(inp).compactMap { $0["path"] as? String }
            if paths.count == 1 { return shortenPath(paths[0]) }
            return truncate(paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "), 60)
        case "web_search", "web_search_call":
            // Codex spells a lookup's terms, page or find-in-page as one
            // value: `query` on the live feed, `command` reopened.
            return truncate((inp["query"] as? String) ?? (inp["command"] as? String) ?? "", 60)
        case "image_view", "view_image":
            // An image codex viewed: `path` on its item and its record;
            // `command` on a reopened call codex kept no record of.
            return shortenPath((inp["path"] as? String) ?? (inp["command"] as? String) ?? "")
        case "Bash":
            let desc = (inp["description"] as? String) ?? (inp["command"] as? String) ?? ""
            return truncate(desc, 60)
        case "TodoWrite":
            let todos = (inp["todos"] as? [Any]) ?? []
            return "\(todos.count) todos"
        case "WebFetch", "FetchURL":
            return truncate((inp["url"] as? String) ?? "", 60)
        case "WebSearch":
            return truncate((inp["query"] as? String) ?? "", 60)
        case "Task":
            return truncate((inp["description"] as? String) ?? "", 60)
        case "Skill":
            // The skill the model loaded, and what it handed it.
            let skill = SkillRecords.skillToolName(name: name, input: inp) ?? ""
            let args = ((inp["args"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return truncate(args.isEmpty ? skill : skill + " — " + args, 60)
        case "ExitPlanMode":
            // The plan's own title — its first heading or line. A bounded
            // split: this runs per visible row per render pass, and the
            // plan is the whole document.
            let plan = (inp["plan"] as? String) ?? ""
            for raw in plan.split(separator: "\n", maxSplits: 8,
                                  omittingEmptySubsequences: true) {
                let line = raw.drop(while: { $0 == "#" || $0 == " " })
                    .trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { return truncate(line, 60) }
            }
            return ""
        case MCPBridge.questionTool:
            // The first question itself — the input's only top-level value
            // is an array, which the generic rule below would reduce to a
            // key name.
            let questions = (inp["questions"] as? [[String: Any]]) ?? []
            let first = truncate((questions.first?["question"] as? String) ?? "", 60)
            return questions.count > 1 ? "\(first) (+\(questions.count - 1) more)" : first
        default:
            // Unknown tools (MCP tools, codex tool calls): the value is
            // what tells the reader something — a bare key list doesn't.
            for key in ["description", "summary", "command", "cmd",
                        "message", "query", "path", "url", "prompt"] {
                if let v = inp[key] as? String, !v.isEmpty {
                    return truncate(v, 60)
                }
            }
            for value in inp.values {
                if let v = value as? String, !v.isEmpty {
                    return truncate(v, 60)
                }
            }
            let keys = Array(inp.keys.prefix(3))
            return keys.joined(separator: ", ")
        }
    }

    /// A tool row's title. Where the row's name is SipAI's own word for
    /// it, the word follows SipAI's language: Codex's events carry only a
    /// machine label (`command_execution`, `file_change`, `imageView`), so
    /// SipAI names them as Claude's rows read, and shows Claude's Edit as
    /// "Update", its terminal's word. A tool shown by its own name — `Read`,
    /// `Bash`, an MCP tool's — keeps it in every language. Each word has a
    /// key of its own: the catalog's plain "Update" is the update button's
    /// word, and reads differently there.
    static func displayToolName(_ name: String) -> String {
        switch name {
        case "command_execution":
            return String(localized: "tool.title.shell", defaultValue: "Shell",
                          comment: "Title of a tool row: a command Codex ran")
        case "file_change", "patch_apply", "Edit", "MultiEdit":
            return String(localized: "tool.title.update", defaultValue: "Update",
                          comment: "Title of a tool row: files the agent edited")
        case "web_search", "web_search_call":
            return String(localized: "tool.title.search", defaultValue: "Search",
                          comment: "Title of a tool row: a web search Codex ran")
        case "image_view", "view_image":
            // Codex's terminal's own words for it.
            return String(
                localized: "tool.title.viewed-image", defaultValue: "Viewed image",
                comment: "Title of a tool row: an image Codex looked at; the file's path is beside it")
        case "todo_list":
            return String(localized: "tool.title.todo", defaultValue: "Todo",
                          comment: "Title of a tool row: Codex's to-do list")
        case MCPBridge.questionTool:
            return String(localized: "tool.title.question", defaultValue: "Question",
                          comment: "Title of a tool row: a question the agent asked the user")
        case "mcp_tool_call":
            // The protocol's name, the same in every language.
            return "MCP"
        default:
            return name
        }
    }

    /// SF Symbol for a tool's activity chip in the normal (desktop-style)
    /// session view. Falls back to a generic wrench; MCP tools get the
    /// plug-in puzzle piece.
    static func toolSymbol(_ name: String) -> String {
        if name.hasPrefix("mcp__") { return "puzzlepiece.extension" }
        switch name {
        case "Bash", "BashOutput", "KillShell", "command_execution": return "terminal"
        case "Edit", "MultiEdit", "NotebookEdit", "file_change", "patch_apply": return "pencil"
        case "Write": return "square.and.pencil"
        case "Read": return "doc.text"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch", "FetchURL", "web_search", "web_search_call": return "globe"
        case "Task", "Agent": return "person.2"
        case "TodoWrite", "todo_list": return "checklist"
        case "Skill": return "book.closed"
        case "ExitPlanMode", "EnterPlanMode": return "map"
        case "image_view", "view_image": return "photo"
        case "mcp_tool_call": return "puzzlepiece.extension"
        case MCPBridge.questionTool: return "questionmark.bubble"
        default: return "wrench.and.screwdriver"
        }
    }

    // MARK: - Tool result summary (compact-mode arrow line)

    /// One-line summary of a tool result. Allocation-free on big inputs:
    /// this runs per visible collapsed row per render pass, and
    /// `components(separatedBy:)` would materialize EVERY line of a
    /// multi-MB result just to produce "N lines".
    static func summarizeToolResult(_ content: String) -> String {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "(no output)" }
        var newlines = 0
        for ch in text.utf8 where ch == 0x0A { newlines += 1 }
        if newlines == 0 { return truncate(text) }
        let firstLine = String(text[..<(text.firstIndex(of: "\n") ?? text.endIndex)])
        if newlines + 1 > 3 || text.count > 200 { return "\(newlines + 1) lines" }
        return truncate(firstLine)
    }

    // MARK: - Full-mode body rows

    /// One body row beneath a tool_use header, produced by the per-tool
    /// renderers. Colour is applied by the SwiftUI view layer.
    struct ToolBodyRow: Identifiable, Equatable {
        enum Style {
            case plain      // ChatDesign.textPrimary
            case dim        // ChatDesign.textSecondary
            case diffAdd    // green
            case diffRemove // red
            case bold       // textPrimary + bold
        }
        /// Position of the row within its produced array, assigned by
        /// `reindexed` in the public producers. Rows are rebuilt inside
        /// view body on every render, so a per-instance UUID here would
        /// make ForEach tear down and re-create every row on each
        /// streamed line; a position-derived id is stable across
        /// rebuilds and still unique within any one ForEach, even for
        /// identical text.
        var id = 0
        let text: String
        let style: Style
        let monospaced: Bool
    }

    /// Stamp position-derived ids onto a produced row array — see
    /// `ToolBodyRow.id`.
    private static func reindexed(_ rows: [ToolBodyRow]) -> [ToolBodyRow] {
        var out = rows
        for i in out.indices { out[i].id = i }
        return out
    }

    /// The summary beside a row's title, from its input — and, for a
    /// Codex lookup that names its terms only once it has ended (a search
    /// run through codex's code mode starts with none), from the result.
    static func toolSummary(name: String, input: [String: Any], resultOutput: String?) -> String {
        let summary = summarizeToolInput(name: name, input: input)
        guard summary.isEmpty, codexLookupNames.contains(name), let output = resultOutput else { return summary }
        return truncate(output, 60)
    }

    /// The rows under a row's input once its result is in. A Codex lookup's
    /// result is its own terms, already beside its title, an image Codex
    /// viewed went to the model, and a Codex file change says nothing
    /// beyond the files its body names: none draws a line of its own, where
    /// any other result says "(no output)".
    static func toolResultRows(name: String, output: String) -> [ToolBodyRow] {
        if codexLookupNames.contains(name) || name == CodexToolInput.imageViewName { return [] }
        if CodexToolInput.fileChangeNames.contains(name),
           output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }
        return fullToolResultBody(output)
    }

    /// Codex's web lookups: the live feed's item and a reopened call.
    private static let codexLookupNames: Set<String> = ["web_search", "web_search_call"]

    /// Produce per-tool body rows for full-mode rendering. Empty array
    /// means "no body — header alone is enough".
    static func fullToolBody(name: String, input: [String: Any]) -> [ToolBodyRow] {
        let rows: [ToolBodyRow]
        switch name {
        case "Bash", "command_execution":
            rows = renderBashInput(input)
        case "Read":
            rows = []  // header already has the path-with-line-range summary
        case "Write":
            rows = renderWriteInput(input)
        case "Edit", "MultiEdit":
            rows = renderEditInput(input)
        case "Glob", "Grep":
            rows = renderPatternInput(input)
        case "TodoWrite":
            rows = renderTodoWrite(input)
        case "WebSearch", "web_search", "web_search_call", "image_view", "view_image":
            rows = []
        case "file_change", "patch_apply":
            rows = renderFileChanges(input)
        case "WebFetch", "FetchURL":
            rows = renderWebFetch(input)
        case "Task":
            rows = renderTaskInput(input)
        case "ExitPlanMode":
            rows = renderPlanInput(input)
        case MCPBridge.questionTool:
            rows = renderQuestionInput(input)
        default:
            rows = renderGenericInput(input)
        }
        return reindexed(rows)
    }

    // MARK: - Per-tool body renderers

    private static func renderBashInput(_ ti: [String: Any]) -> [ToolBodyRow] {
        let cmd = ((ti["command"] as? String) ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        let desc = ((ti["description"] as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        var rows: [ToolBodyRow] = []
        if !desc.isEmpty {
            rows.append(ToolBodyRow(text: "# \(desc)", style: .dim, monospaced: true))
        }
        if cmd.isEmpty {
            rows.append(ToolBodyRow(text: "(no command)", style: .plain, monospaced: true))
            return rows
        }
        let rawLines = cmd.components(separatedBy: "\n")
        let cap = AgentRenderingLimits.fullToolLines
        let shown = Array(rawLines.prefix(cap))
        if let first = shown.first {
            rows.append(ToolBodyRow(text: "$ \(first)", style: .plain, monospaced: true))
        }
        for extra in shown.dropFirst() {
            rows.append(ToolBodyRow(text: "  \(extra)", style: .plain, monospaced: true))
        }
        if rawLines.count > cap {
            let dropped = rawLines.count - cap
            rows.append(ToolBodyRow(text: "… (\(dropped) more lines)", style: .dim, monospaced: true))
        }
        return rows
    }

    private static func renderWriteInput(_ ti: [String: Any]) -> [ToolBodyRow] {
        let path = (ti["file_path"] as? String) ?? (ti["path"] as? String) ?? "(no path)"
        let content = (ti["content"] as? String) ?? ""
        let nLines: Int = {
            if content.isEmpty { return 0 }
            let nl = content.reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
            return nl + (content.hasSuffix("\n") ? 0 : 1)
        }()
        let size = humanBytes(content.lengthOfBytes(using: .utf8))
        var rows: [ToolBodyRow] = []
        rows.append(ToolBodyRow(text: "\(path)  (\(nLines) lines, \(size))",
                                 style: .dim, monospaced: true))
        rows.append(ToolBodyRow(text: "", style: .dim, monospaced: true))
        if isBinaryText(content) {
            rows.append(ToolBodyRow(text: "[binary content, \(size)]",
                                     style: .dim, monospaced: true))
            return rows
        }
        let preview = content.isEmpty ? [] : Array(content.components(separatedBy: "\n").prefix(5))
        for ln in preview {
            rows.append(ToolBodyRow(text: "  \(ln)", style: .plain, monospaced: true))
        }
        let rest = nLines - preview.count
        if rest > 0 {
            rows.append(ToolBodyRow(text: "[\(rest) more lines]",
                                     style: .dim, monospaced: true))
        }
        return rows
    }

    private static func renderEditInput(_ ti: [String: Any]) -> [ToolBodyRow] {
        let path = (ti["file_path"] as? String) ?? (ti["path"] as? String) ?? "(no path)"
        let old = (ti["old_string"] as? String) ?? ""
        let new = (ti["new_string"] as? String) ?? ""
        var rows: [ToolBodyRow] = []
        rows.append(ToolBodyRow(text: path, style: .plain, monospaced: true))
        rows.append(ToolBodyRow(text: "", style: .plain, monospaced: true))

        // Summary line
        let added = new.components(separatedBy: "\n").count - (new.isEmpty ? 1 : 0)
        let removed = old.components(separatedBy: "\n").count - (old.isEmpty ? 1 : 0)
        let located = findEditLineRange(path: path, oldString: old, newString: new)
        let summary: String
        if let (start, end, which) = located {
            let span = (start == end) ? "line \(start)" : "lines \(start)–\(end)"
            if which == .old {
                if removed > 0, added > 0 {
                    summary = "Replacing \(span) (\(removed) → \(added) lines)"
                } else if added > 0, removed == 0 {
                    summary = "Inserting \(added) line(s) at line \(start)"
                } else if removed > 0, added == 0 {
                    summary = "Removing \(span) (\(removed) line(s))"
                } else {
                    summary = "No change"
                }
            } else {
                if removed > 0, added > 0 {
                    summary = "Replaced (now \(span), \(removed) → \(added) lines)"
                } else if added > 0, removed == 0 {
                    summary = "Inserted \(added) line(s) (now at \(span))"
                } else if removed > 0, added == 0 {
                    summary = "Removed \(removed) line(s) (was near \(span))"
                } else {
                    summary = "No change"
                }
            }
        } else {
            let nounA = added == 1 ? "line" : "lines"
            let nounR = removed == 1 ? "line" : "lines"
            summary = "Added \(added) \(nounA), removed \(removed) \(nounR)"
        }
        rows.append(ToolBodyRow(text: summary, style: .dim, monospaced: true))
        rows.append(ToolBodyRow(text: "", style: .plain, monospaced: true))

        // Diff
        var diff: [ToolBodyRow] = []
        for ln in old.components(separatedBy: "\n") {
            diff.append(ToolBodyRow(text: "- \(ln)", style: .diffRemove, monospaced: true))
        }
        for ln in new.components(separatedBy: "\n") {
            diff.append(ToolBodyRow(text: "+ \(ln)", style: .diffAdd, monospaced: true))
        }
        let cap = AgentRenderingLimits.fullToolLines
        if diff.count > cap {
            rows.append(contentsOf: diff.prefix(cap))
            let remaining = diff.count - cap
            rows.append(ToolBodyRow(
                text: "… [diff truncated — \(remaining) more diff lines]",
                style: .dim, monospaced: true))
        } else {
            rows.append(contentsOf: diff)
        }
        return rows
    }

    private static func renderPatternInput(_ ti: [String: Any]) -> [ToolBodyRow] {
        // Header already carries pattern + path; body shows extras only.
        var rows: [ToolBodyRow] = []
        let extras = ti.keys.filter { $0 != "pattern" && $0 != "path" }.prefix(4)
        for k in extras {
            var vs = String(describing: ti[k] ?? "")
            if vs.count > 120 { vs = String(vs.prefix(117)) + "..." }
            rows.append(ToolBodyRow(text: "\(k): \(vs)", style: .dim, monospaced: true))
        }
        return rows
    }

    private static func renderTodoWrite(_ ti: [String: Any]) -> [ToolBodyRow] {
        let todos = (ti["todos"] as? [Any]) ?? []
        if todos.isEmpty {
            return [ToolBodyRow(text: "(no todos)", style: .dim, monospaced: false)]
        }
        var rows: [ToolBodyRow] = []
        for item in todos {
            guard let t = item as? [String: Any] else { continue }
            let state = (t["status"] as? String) ?? "pending"
            let content = ((t["content"] as? String) ?? "")
                .trimmingCharacters(in: .whitespaces)
            let marker: String = {
                switch state {
                case "in_progress": return "◐"
                case "completed":   return "☒"
                default:            return "☐"
                }
            }()
            let style: ToolBodyRow.Style = {
                switch state {
                case "in_progress": return .bold
                case "completed":   return .dim
                default:            return .plain
                }
            }()
            rows.append(ToolBodyRow(text: "\(marker) \(content)",
                                     style: style, monospaced: false))
        }
        return rows
    }

    private static func renderWebFetch(_ ti: [String: Any]) -> [ToolBodyRow] {
        let prompt = ((ti["prompt"] as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return [] }
        let preview = prompt.count <= 200 ? prompt : String(prompt.prefix(200)) + "…"
        return [ToolBodyRow(text: preview, style: .dim, monospaced: false)]
    }

    private static func renderTaskInput(_ ti: [String: Any]) -> [ToolBodyRow] {
        let prompt = ((ti["prompt"] as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return [] }
        let allLines = prompt.components(separatedBy: "\n")
        let cap = AgentRenderingLimits.fullResultLines
        let shown = Array(allLines.prefix(cap))
        var rows = shown.map { ToolBodyRow(text: $0, style: .dim, monospaced: false) }
        if allLines.count > cap {
            let extra = allLines.count - cap
            rows.append(ToolBodyRow(text: "… (\(extra) more lines)",
                                     style: .dim, monospaced: false))
        }
        return rows
    }

    /// ExitPlanMode carries the whole plan: claude reads its plan file
    /// back into the tool's input (`plan`, `planFilePath`). The generic
    /// body clips every string over 200 characters, which would leave an
    /// approved plan unreadable in the transcript — so it is drawn as
    /// text, capped like any tool body, under the file it was saved to.
    private static func renderPlanInput(_ ti: [String: Any]) -> [ToolBodyRow] {
        let plan = ((ti["plan"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [ToolBodyRow] = []
        if let path = ti["planFilePath"] as? String, !path.isEmpty {
            rows.append(ToolBodyRow(text: shortenPath(path), style: .dim, monospaced: true))
            if !plan.isEmpty {
                rows.append(ToolBodyRow(text: "", style: .dim, monospaced: false))
            }
        }
        guard !plan.isEmpty else { return rows }
        let allLines = plan.components(separatedBy: "\n")
        let cap = AgentRenderingLimits.fullToolLines
        rows += allLines.prefix(cap).map {
            ToolBodyRow(text: $0, style: .plain, monospaced: false)
        }
        if allLines.count > cap {
            rows.append(ToolBodyRow(text: "… (\(allLines.count - cap) more lines)",
                                     style: .dim, monospaced: false))
        }
        return rows
    }

    /// An agent's questions as the user saw them: each question, then its
    /// options. The answers are claude's own tool result, drawn below.
    /// Anything not in the shape of a question falls back to the generic
    /// JSON rows, so a call that could not be drawn as a card still shows
    /// what it asked.
    private static func renderQuestionInput(_ ti: [String: Any]) -> [ToolBodyRow] {
        guard let questions = ti["questions"] as? [[String: Any]], !questions.isEmpty else {
            return renderGenericInput(ti)
        }
        var rows: [ToolBodyRow] = []
        for (index, question) in questions.enumerated() {
            if index > 0 {
                rows.append(ToolBodyRow(text: "", style: .dim, monospaced: false))
            }
            rows.append(ToolBodyRow(text: (question["question"] as? String) ?? "",
                                    style: .bold, monospaced: false))
            for option in (question["options"] as? [[String: Any]]) ?? [] {
                let label = (option["label"] as? String) ?? ""
                let description = (option["description"] as? String) ?? ""
                rows.append(ToolBodyRow(
                    text: description.isEmpty ? "• \(label)" : "• \(label) — \(description)",
                    style: .dim, monospaced: false))
            }
        }
        return rows
    }

    /// Codex's file change, file by file: what happened to it, in codex's
    /// own words, then its diff — an added file's lines as additions, a
    /// deleted file's as removals, an edited file's unified diff as it is.
    /// `codex exec`'s item names the files without their diffs.
    private static func renderFileChanges(_ ti: [String: Any]) -> [ToolBodyRow] {
        var rows: [ToolBodyRow] = []
        var diffLines = 0
        var hidden = 0
        let cap = AgentRenderingLimits.fullToolLines
        for (index, change) in fileChanges(ti).enumerated() {
            let path = shortenPath((change["path"] as? String) ?? "")
            let kind = (change["kind"] as? String) ?? "update"
            if index > 0 { rows.append(ToolBodyRow(text: "", style: .dim, monospaced: true)) }
            let headline = fileChangeHeadline(kind: kind, path: path, movedTo: change["move_path"] as? String)
            rows.append(ToolBodyRow(text: headline, style: .dim, monospaced: true))
            var diff = (change["diff"] as? String) ?? ""
            while diff.hasSuffix("\n") { diff.removeLast() }
            guard !diff.isEmpty else { continue }
            for line in diff.components(separatedBy: "\n") {
                guard diffLines < cap else { hidden += 1; continue }
                diffLines += 1
                switch kind {
                case "add": rows.append(ToolBodyRow(text: "+" + line, style: .diffAdd, monospaced: true))
                case "delete": rows.append(ToolBodyRow(text: "-" + line, style: .diffRemove, monospaced: true))
                default: rows.append(unifiedDiffRow(line))
                }
            }
        }
        if hidden > 0 {
            rows.append(ToolBodyRow(text: "… [diff truncated — \(hidden) more diff lines]",
                                    style: .dim, monospaced: true))
        }
        return rows
    }

    /// A Codex file change's files, from its row's input.
    private static func fileChanges(_ ti: [String: Any]) -> [[String: Any]] {
        (ti["changes"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    /// What happened to one file — "Added", "Edited", "Deleted", the
    /// words codex's own terminal uses — and where it moved to.
    private static func fileChangeHeadline(kind: String, path: String, movedTo: String?) -> String {
        switch kind {
        case "add":
            return String(
                localized: "Added \(path)",
                comment: "A file Codex created, in its tool row; the argument is the file's path")
        case "delete":
            return String(
                localized: "Deleted \(path)",
                comment: "A file Codex deleted, in its tool row; the argument is the file's path")
        default:
            if let movedTo, !movedTo.isEmpty {
                let target = shortenPath(movedTo)
                return String(
                    localized: "Edited \(path) → \(target)",
                    comment: "A file Codex edited and moved, in its tool row; the arguments are its old and new paths")
            }
            return String(
                localized: "Edited \(path)",
                comment: "A file Codex edited, in its tool row; the argument is the file's path")
        }
    }

    /// One line of a unified diff in the diff's colours: additions green,
    /// removals red, the hunk headers and file names dim.
    private static func unifiedDiffRow(_ line: String) -> ToolBodyRow {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") || line.hasPrefix("\\") {
            return ToolBodyRow(text: line, style: .dim, monospaced: true)
        }
        if line.hasPrefix("+") { return ToolBodyRow(text: line, style: .diffAdd, monospaced: true) }
        if line.hasPrefix("-") { return ToolBodyRow(text: line, style: .diffRemove, monospaced: true) }
        return ToolBodyRow(text: line, style: .plain, monospaced: true)
    }

    private static func renderGenericInput(_ ti: [String: Any]) -> [ToolBodyRow] {
        // A call with no arguments has nothing to show: printed, the empty
        // input reads as a body of `{` and `}` that says nothing.
        guard !ti.isEmpty else { return [] }
        // Clip long string values before serialising.
        var clipped: [String: Any] = [:]
        for (k, v) in ti {
            if let s = v as? String, s.count > 200 {
                clipped[k] = "..."
            } else {
                clipped[k] = v
            }
        }
        let rendered: String = {
            if JSONSerialization.isValidJSONObject(clipped),
               let data = try? JSONSerialization.data(
                withJSONObject: clipped,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return String(describing: clipped)
        }()
        let rawLines = rendered.components(separatedBy: "\n")
        let cap = AgentRenderingLimits.fullToolLines
        var rows = rawLines.prefix(cap).map {
            ToolBodyRow(text: $0, style: .plain, monospaced: true)
        }
        if rawLines.count > cap {
            let dropped = rawLines.count - cap
            rows.append(ToolBodyRow(text: "… (\(dropped) more lines)",
                                     style: .dim, monospaced: true))
        }
        return rows
    }

    // MARK: - Tool result body (full mode)

    /// Per-ROW character cap. A line-count cap alone would let a
    /// single-line multi-MB result (minified JSON, base64, curl body)
    /// through as ONE row — megabytes laid out in a main-thread Text.
    private static let rowCharCap = 2000

    private static func cappedRow(_ text: String, style: ToolBodyRow.Style,
                                  monospaced: Bool) -> ToolBodyRow {
        if text.count <= rowCharCap {
            return ToolBodyRow(text: text, style: style, monospaced: monospaced)
        }
        let hidden = text.count - rowCharCap
        return ToolBodyRow(
            text: text.prefix(rowCharCap) + " … (+\(hidden) chars)",
            style: style, monospaced: monospaced)
    }

    /// The expanded tool-result body, as rows.
    static func fullToolResultBody(_ content: String) -> [ToolBodyRow] {
        var rstripped = content
        while rstripped.hasSuffix("\n") { rstripped.removeLast() }
        if rstripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [ToolBodyRow(text: "↳ (no output)", style: .dim, monospaced: true)]
        }
        let lines = rstripped.components(separatedBy: "\n")
        let cap = AgentRenderingLimits.fullResultLines
        if lines.count <= cap {
            return reindexed(lines.map {
                cappedRow($0, style: .dim, monospaced: true)
            })
        }
        let head = lines.prefix(14)
        let tail = lines.suffix(4)
        let hidden = lines.count - 18
        var rows = head.map { cappedRow($0, style: .dim, monospaced: true) }
        rows.append(ToolBodyRow(text: "… (\(hidden) hidden lines) …",
                                 style: .dim, monospaced: true))
        rows.append(contentsOf: tail.map {
            cappedRow($0, style: .dim, monospaced: true)
        })
        return reindexed(rows)
    }

    // MARK: - Internals

    /// Locate a 1-based line span for an Edit's `old_string`
    /// (preferred) or `new_string` (fallback) in the file on disk.
    enum EditSpanSource { case old, new }

    /// Memo for `findEditLineRange`. The lookup reads the target file
    /// off disk and is reached from SwiftUI body (via `fullToolBody`)
    /// on every render pass while an Edit chip is expanded — repeat
    /// renders must be pure cache hits or big files / dead network
    /// mounts stutter the UI. The tool_use id never reaches this layer,
    /// so the key is (path, old/new-string hashes). Misses (nil) are
    /// cached too: a missing file must not be re-stat'd per render.
    /// Bounded by clearing wholesale past `editRangeCacheLimit`
    /// entries. Main-thread only (like the SwiftUI views that call it).
    private struct EditRangeKey: Hashable {
        let path: String
        let oldHash: Int
        let newHash: Int
    }
    private static let editRangeCacheLimit = 200
    private static var editRangeCache:
        [EditRangeKey: (start: Int, end: Int, which: EditSpanSource)?] = [:]

    static func findEditLineRange(path: String,
                                  oldString: String,
                                  newString: String)
    -> (start: Int, end: Int, which: EditSpanSource)? {
        guard !path.isEmpty else { return nil }
        let key = EditRangeKey(path: path,
                               oldHash: oldString.hashValue,
                               newHash: newString.hashValue)
        if let cached = editRangeCache[key] { return cached }
        let computed = computeEditLineRange(path: path,
                                            oldString: oldString,
                                            newString: newString)
        if editRangeCache.count >= editRangeCacheLimit {
            editRangeCache.removeAll(keepingCapacity: true)
        }
        editRangeCache[key] = computed
        return computed
    }

    /// The uncached lookup — first render of an Edit pays this once.
    private static func computeEditLineRange(path: String,
                                             oldString: String,
                                             newString: String)
    -> (start: Int, end: Int, which: EditSpanSource)? {
        let resolved = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)),
              let content = String(data: data, encoding: .utf8)
        else { return nil }

        func locate(_ needle: String) -> (Int, Int)? {
            guard !needle.isEmpty, let range = content.range(of: needle) else {
                return nil
            }
            let before = content[content.startIndex..<range.lowerBound]
            let start = before.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
            let nlInNeedle = needle.reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
            return (start, start + nlInNeedle)
        }
        if let (s, e) = locate(oldString) {
            return (s, e, .old)
        }
        if let (s, e) = locate(newString) {
            return (s, e, .new)
        }
        return nil
    }

    /// Binary-content heuristic: >10% non-printable-and-not-whitespace
    /// in the first 4kB.
    private static func isBinaryText(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let sample = String(s.prefix(4000))
        var bad = 0
        for ch in sample.unicodeScalars {
            if ch == "\n" || ch == "\r" || ch == "\t" { continue }
            // CharacterSet.letters etc. aren't quite right: what is
            // wanted is the ASCII printable range, plus anything
            // Unicode considers printable.
            let printable = !(ch.value < 0x20 || ch.value == 0x7F)
            if !printable { bad += 1 }
        }
        return bad > max(16, sample.count / 10)
    }

    private static func humanBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        var f = Double(n)
        for unit in ["KB", "MB", "GB"] {
            f /= 1024
            if f < 1024 { return String(format: "%.1f %@", f, unit) }
        }
        return String(format: "%.1f TB", f)
    }

    private static func asInt(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String, let i = Int(s) { return i }
        return nil
    }
}
