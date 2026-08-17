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
            let fp = shortenPath((inp["file_path"] as? String) ?? "")
            if let off = asInt(inp["offset"]), let lim = asInt(inp["limit"]) {
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
            let fp = (inp["file_path"] as? String) ?? (inp["notebook_path"] as? String) ?? ""
            return shortenPath(fp)
        case "Bash":
            let desc = (inp["description"] as? String) ?? (inp["command"] as? String) ?? ""
            return truncate(desc, 60)
        case "TodoWrite":
            let todos = (inp["todos"] as? [Any]) ?? []
            return "\(todos.count) todos"
        case "WebFetch":
            return truncate((inp["url"] as? String) ?? "", 60)
        case "WebSearch":
            return truncate((inp["query"] as? String) ?? "", 60)
        case "Task":
            return truncate((inp["description"] as? String) ?? "", 60)
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

    /// Display name used in the header: Edit/MultiEdit → "Update".
    ///
    /// Codex names its tool rows after its own stdout item types
    /// (`command_execution`), so those are mapped to the same
    /// vocabulary claude's rows use rather than shown raw.
    static func displayToolName(_ name: String) -> String {
        if let codex = CodexCapabilities.toolDisplay(for: name) {
            return codex.title
        }
        return (name == "Edit" || name == "MultiEdit") ? "Update" : name
    }

    /// SF Symbol for a tool's activity chip in the normal (desktop-style)
    /// session view. Falls back to a generic wrench; MCP tools get the
    /// plug-in puzzle piece.
    static func toolSymbol(_ name: String) -> String {
        if name.hasPrefix("mcp__") { return "puzzlepiece.extension" }
        if let codex = CodexCapabilities.toolDisplay(for: name) {
            return codex.symbol
        }
        switch name {
        case "Bash", "BashOutput", "KillShell": return "terminal"
        case "Edit", "MultiEdit", "NotebookEdit": return "pencil"
        case "Write": return "square.and.pencil"
        case "Read": return "doc.text"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "person.2"
        case "TodoWrite": return "checklist"
        case "ExitPlanMode", "EnterPlanMode": return "map"
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

    /// Produce per-tool body rows for full-mode rendering. Empty array
    /// means "no body — header alone is enough".
    static func fullToolBody(name: String, input: [String: Any]) -> [ToolBodyRow] {
        let rows: [ToolBodyRow]
        switch name {
        case "Bash":
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
        case "WebSearch":
            rows = []
        case "WebFetch":
            rows = renderWebFetch(input)
        case "Task":
            rows = renderTaskInput(input)
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

    private static func renderGenericInput(_ ti: [String: Any]) -> [ToolBodyRow] {
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
