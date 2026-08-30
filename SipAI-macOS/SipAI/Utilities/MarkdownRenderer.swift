// MarkdownRenderer.swift
// Hand-rolled block + inline markdown renderer. A full markdown
// library would be overkill — the supported subset is small:
//   • Fenced code blocks (with an optional dim language label above).
//   • Headings `# … ######` (H1 bold+underline, H2 bold, H3–H6 bold).
//   • Horizontal rules (`---`, `***`, `___`).
//   • Unordered + ordered lists, with 2- / 4-space nested indent.
//   • Blockquotes, nested via repeated `>`.
//   • Inline code, bold, italic, URLs (auto-linked).
//   • LaTeX symbols via `LatexSymbols.translate` (pre-pass on non-code).
//
// The public API is `MarkdownRenderer.render(_:)` returning `some View`,
// so `MessageBubble` doesn't need to know anything about block-level
// layout.

import SwiftUI
import AppKit

// MARK: - Style tokens (single source of truth)

enum ChatMarkdownStyle {
    /// Set to false to switch the chat label colour back to bold
    /// yellow. Brand blue is the default because yellow on a light
    /// window background is too low-contrast.
    static let useBrandBlue = true
    static var label: Color { useBrandBlue ? ChatDesign.blue : .yellow }

    /// Sky-blue for inline code.
    static let inlineCode = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 160/255, green: 220/255, blue: 245/255, alpha: 1)
            : NSColor(srgbRed: 135/255, green: 206/255, blue: 235/255, alpha: 1)
    }))

    /// Dim secondary — blockquote bars, dividers, code-block body, language
    /// label. Adaptive so it stays legible in both appearances.
    static let dim = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 160/255, green: 160/255, blue: 168/255, alpha: 0.72)
            : NSColor(srgbRed: 134/255, green: 134/255, blue: 139/255, alpha: 0.72)
    }))

    /// Diff green. Sourced by the agent session view's diff rows
    /// (`AgentSessionView.toolBodyText`).
    static let diffAdded = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 133/255, green: 232/255, blue: 157/255, alpha: 1) // #85E89D
            : NSColor(srgbRed:  34/255, green: 134/255, blue:  58/255, alpha: 1) // #22863A
    }))

    /// Diff red.
    static let diffRemoved = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 249/255, green: 117/255, blue: 131/255, alpha: 1) // #F97583
            : NSColor(srgbRed: 179/255, green:  29/255, blue:  40/255, alpha: 1) // #B31D28
    }))

    /// Soft grey fill for the user-message block, adaptive to the
    /// current appearance.
    static let userBlockBg = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed:  42/255, green:  42/255, blue:  44/255, alpha: 1) // #2A2A2C
            : NSColor(srgbRed: 242/255, green: 242/255, blue: 244/255, alpha: 1) // #F2F2F4
    }))
}

// MARK: - Public renderer

enum MarkdownRenderer {

    /// Render a Markdown string to a view that stacks block-level
    /// elements vertically. Callers that want tighter vertical rhythm
    /// (e.g. per-turn compact lists) can pass `compactSpacing = true`.
    ///
    /// `| a | b |` pipe tables are laid out as real grid views.
    @ViewBuilder
    static func render(_ text: String,
                       compactSpacing: Bool = false) -> some View {
        let blocks = parse(text)
        // `source` rides along ONLY as the cache key for the search
        // pass's per-block displayed text (`displayedTexts`). Nothing
        // renders from it.
        MarkdownBlockList(blocks: blocks, source: text,
                          compactSpacing: compactSpacing)
    }

    // MARK: - Displayed text (what search counts in)

    /// The text this renderer will actually DRAW for `source`, block by
    /// block, in draw order.
    ///
    /// Not the source: `**bold**` is drawn as `bold`, LaTeX is
    /// translated, inline-code spans are re-injected byte-exact. A find
    /// bar that counted the source would report matches inside syntax
    /// the reader cannot see and miss the translations they can — see
    /// `SearchMatching`, which owns that rule.
    ///
    /// Order and content here are the CONTRACT with `MarkdownBlockList`:
    /// the k-th match of this array is the k-th match the highlighter
    /// tints. A block rendered but not represented here (or the reverse)
    /// desynchronises the counter from the highlights.
    fileprivate static func displayedTexts(_ blocks: [Block]) -> [String] {
        var out: [String] = []
        for block in blocks {
            switch block {
            case .heading(_, let t),
                 .paragraph(let t),
                 .bulletItem(_, let t),
                 .blockquote(_, let t):
                out.append(displayedInline(t))
            case .orderedItem(_, _, let t):
                // The number is a marker view, not searchable text.
                out.append(displayedInline(t))
            case .codeBlock(_, let body):
                // The language chip above the code is a label, not
                // content — `CodeBlockView` does not highlight it either.
                out.append(body)
            case .table(let header, _, let rows):
                out.append(tableDisplayedText(header: header, rows: rows))
            case .horizontalRule, .blank, .displayMath:
                // Draws no text a find bar could tint. A display
                // equation is typeset glyphs, so counting its LaTeX
                // would name matches the reader cannot see and cannot
                // be stepped to — the shape `SearchMatching` exists to
                // forbid. Still emitted, so this array stays
                // index-aligned with `blocks` — MarkdownBlockList walks
                // them together.
                out.append("")
            }
        }
        return out
    }

    /// A table's cells in the order `MarkdownTableView` draws them:
    /// header row first, then each body row, every row padded (and
    /// truncated) to the grid's column count exactly as the view does.
    private static func tableDisplayedText(header: [String],
                                           rows: [[String]]) -> String {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return "" }
        func line(_ cells: [String]) -> String {
            (0..<columns).map { c in
                c < cells.count ? displayedInline(cells[c]) : ""
            }.joined(separator: "\n")
        }
        return ([line(header)] + rows.map(line)).joined(separator: "\n")
    }

    private static func displayedInline(_ text: String) -> String {
        // Scale only sets fonts, never characters, so the default is
        // fine here — this string is measured, not drawn.
        String(MarkdownInline.attributed(text).characters)
    }

    /// Everything `source` draws, joined. What a find bar counts a row's
    /// matches in.
    ///
    /// Blocks are joined by a newline, and the find field is
    /// single-line, so no query can straddle two blocks — which is what
    /// lets `MarkdownBlockList` hand each block a simple running offset.
    static func plainText(_ source: String) -> String {
        let key = ParseKey(text: source)
        plainTextLock.lock()
        let hit = plainTextCache[key]
        plainTextLock.unlock()
        if let hit { return hit }
        let value = displayedTexts(parse(source)).joined(separator: "\n")
        plainTextLock.lock()
        if plainTextCache.count >= parseCacheLimit {
            let drop = max(1, parseCacheLimit / parseCacheEvictionShare)
            for stale in plainTextOrder.prefix(drop) {
                plainTextCache.removeValue(forKey: stale)
            }
            plainTextOrder.removeFirst(min(drop, plainTextOrder.count))
        }
        if plainTextCache.updateValue(value, forKey: key) == nil {
            plainTextOrder.append(key)
        }
        plainTextLock.unlock()
        return value
    }

    /// Per-block displayed text, cached by source. Same eviction shape
    /// as `parseCache` and, like it, only ever populated while something
    /// is actually searching — a transcript with no find bar open never
    /// touches this.
    fileprivate static func cachedDisplayedTexts(_ source: String,
                                                 blocks: [Block]) -> [String] {
        let key = ParseKey(text: source)
        plainTextLock.lock()
        let hit = blockTextCache[key]
        plainTextLock.unlock()
        if let hit { return hit }
        let value = displayedTexts(blocks)
        plainTextLock.lock()
        if blockTextCache.count >= parseCacheLimit {
            let drop = max(1, parseCacheLimit / parseCacheEvictionShare)
            for stale in blockTextOrder.prefix(drop) {
                blockTextCache.removeValue(forKey: stale)
            }
            blockTextOrder.removeFirst(min(drop, blockTextOrder.count))
        }
        if blockTextCache.updateValue(value, forKey: key) == nil {
            blockTextOrder.append(key)
        }
        plainTextLock.unlock()
        return value
    }

    private static var plainTextCache: [ParseKey: String] = [:]
    private static var plainTextOrder: [ParseKey] = []
    private static var blockTextCache: [ParseKey: [String]] = [:]
    private static var blockTextOrder: [ParseKey] = []
    /// Separate from `parseCacheLock` so a search-side fill can't block
    /// a render-side parse, and vice versa.
    private static let plainTextLock = NSLock()

    // MARK: - Block model

    /// Equatable, with the list keyed by position (`ForEach id:
    /// \.offset`): identical blocks at identical offsets let SwiftUI
    /// skip child re-evaluation entirely. A computed
    /// `var id: UUID { UUID() }` would mint a NEW identity on every
    /// access and defeat every one of those skips.
    /// Internal rather than fileprivate so `NoteHTML` can render the
    /// same block structure to HTML — one block parser for the note
    /// Preview, the note PDF and the chat transcript.
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(text: String)
        case horizontalRule
        case bulletItem(indent: Int, text: String)
        case orderedItem(indent: Int, number: String, text: String)
        case blockquote(depth: Int, text: String)
        case codeBlock(language: String, body: String)
        case table(header: [String], alignments: [TableAlignment], rows: [[String]])
        /// A display equation, typeset by `MathTypesetter` rather than
        /// drawn as text. The LaTeX rides verbatim: it is the source the
        /// renderer needs and the string "Copy LaTeX" hands back.
        case displayMath(latex: String)
        case blank
    }

    enum TableAlignment: Equatable {
        case leading, center, trailing
    }

    // MARK: - Parser

    /// Memo for `parse`. Every visible bubble re-renders on every
    /// streamed burst (≥4 Hz while a session runs). Message text is
    /// immutable once appended, so a by-text cache turns all of that
    /// into hits. Bounded (chat-delta streaming writes one-off prefix
    /// keys; eviction keeps them from piling up). Main-thread only,
    /// like the SwiftUI bodies that call it.
    /// The key is the source text alone. Anything that is ever allowed
    /// to change the parse OUTPUT has to become part of this key in the
    /// same commit that introduces it, or the same text parsed two ways
    /// returns whichever result landed here first.
    private struct ParseKey: Hashable {
        let text: String
    }
    private static var parseCache: [ParseKey: [Block]] = [:]
    /// Insertion order, oldest first — the eviction queue.
    private static var parseCacheOrder: [ParseKey] = []
    /// Must hold SEVERAL sessions' visible rows at once: a limit only
    /// one transcript wide would make big sessions evict each other on
    /// every switch, so "instant revisit" would still re-parse every
    /// row cold.
    private static let parseCacheLimit = 512
    /// How much of the cache one overflow drops. A WHOLESALE clear
    /// would turn the limit into a cliff: a session whose visible
    /// window alone approaches the limit (a transcript expanded by
    /// "Show earlier" holds hundreds of rows) would evict its own
    /// rows, and every one of them is then re-parsed on the very next
    /// render pass — at streaming's 4 passes a second, on the main
    /// thread. Dropping the oldest quarter instead keeps the rows
    /// actually on screen (the most recently parsed) resident, so an
    /// overflow costs a slice instead of everything.
    private static let parseCacheEvictionShare = 4
    /// Guards `parseCache`: render passes parse on the main thread,
    /// and `prewarm` fills the cache from the history loader's
    /// background task so a session's first frame is cache hits
    /// instead of dozens of cold parses (a visible delay at open).
    private static let parseCacheLock = NSLock()

    static func parse(_ source: String) -> [Block] {
        let key = ParseKey(text: source)
        parseCacheLock.lock()
        let hit = parseCache[key]
        parseCacheLock.unlock()
        if let hit { return hit }
        let blocks = parseUncached(source)
        parseCacheLock.lock()
        if parseCache.count >= parseCacheLimit {
            let drop = max(1, parseCacheLimit / parseCacheEvictionShare)
            for stale in parseCacheOrder.prefix(drop) {
                parseCache.removeValue(forKey: stale)
            }
            parseCacheOrder.removeFirst(min(drop, parseCacheOrder.count))
        }
        if parseCache.updateValue(blocks, forKey: key) == nil {
            parseCacheOrder.append(key)
        }
        parseCacheLock.unlock()
        return blocks
    }

    /// Parse `texts` into the cache off the render path. Call from a
    /// background task before content first renders.
    static func prewarm(_ texts: [String]) {
        for t in texts { _ = parse(t) }
    }

    /// Two-stage parse: pull fenced code blocks out first (so their body
    /// is never touched by block/inline transforms), then walk the
    /// remaining lines classifying each one.
    private static func parseUncached(_ source: String) -> [Block] {
        // Normalise CRLF → LF so every downstream check works uniformly.
        let normalised = source.replacingOccurrences(of: "\r\n", with: "\n")
        let (skeleton, codeBlocks) = extractFencedCodeBlocks(normalised)

        var blocks: [Block] = []
        let lines = skeleton.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // Code-block placeholder — reinsert the original block here.
            if let idx = codeBlockIndex(in: line), idx < codeBlocks.count {
                let cb = codeBlocks[idx]
                blocks.append(.codeBlock(language: cb.language, body: cb.body))
                i += 1
                continue
            }

            // Display math: `$$…$$`, `\[…\]`, or a bare
            // `\begin{aligned}`. Detected before everything else so a
            // multi-line equation never reaches the paragraph merger,
            // which would glue its lines together with spaces and hand
            // the result to the inline pass as prose.
            if let (latex, next) = MathDelimiters.displayMath(lines, from: i) {
                blocks.append(.displayMath(latex: latex))
                i = next
                continue
            }

            // Pipe table: a `| … | … |` row whose next line is the
            // `|---|:---:|` separator. Consumes every following pipe
            // row. Detected before everything else so the rows never
            // reach the paragraph merger.
            if i + 1 < lines.count,
               let header = parseTableCells(line),
               header.count >= 2,
               let aligns = parseTableSeparator(lines[i + 1],
                                                columns: header.count) {
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count, let cells = parseTableCells(lines[j]) {
                    rows.append(cells)
                    j += 1
                }
                blocks.append(.table(header: header,
                                     alignments: aligns,
                                     rows: rows))
                i = j
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            blocks.append(classifyLine(line, trimmed: trimmed))
            i += 1
        }

        return mergeAdjacentParagraphs(blocks)
    }

    /// Single-line classification, in priority order. Everything that
    /// needs lookahead (code placeholders, tables) is handled by the
    /// caller before this runs.
    private static func classifyLine(_ line: String, trimmed: String) -> Block {
        // Blank line → paragraph gap.
        if trimmed.isEmpty { return .blank }

        // Horizontal rule (`---`, `***`, `___`, ≥3 of the same).
        if isHorizontalRule(trimmed) { return .horizontalRule }

        // Headings: count leading `#`, then one space, then text.
        if let (level, content) = parseHeading(trimmed) {
            return .heading(level: level, text: content)
        }

        // Blockquote: leading `>`s (nesting depth = count), optional space.
        if let (depth, rest) = parseBlockquote(line) {
            return .blockquote(depth: depth, text: rest)
        }

        // Ordered list: `1.`, `2.`, … with optional leading indent.
        if let (indent, number, content) = parseOrderedItem(line) {
            return .orderedItem(indent: indent, number: number, text: content)
        }

        // Bullet list: `-` or `*` with optional leading indent. Must
        // NOT be matched for an emphasis-style `*italic*` that happens
        // to start a paragraph; `parseBulletItem` enforces a space
        // after the marker to disambiguate.
        if let (indent, content) = parseBulletItem(line) {
            return .bulletItem(indent: indent, text: content)
        }

        return .paragraph(text: line)
    }

    // MARK: - Table parsing

    /// Split one `| a | b |` row into trimmed cell strings, or nil when
    /// the line isn't a pipe row. Requires the leading `|` — that's how
    /// every LLM emits GFM tables, and it keeps prose containing a bare
    /// `|` from being misread. `\|` escapes survive as literal pipes.
    /// Internal (not fileprivate) so the headless verification harness
    /// can exercise the pure parsing layer.
    static func parseTableCells(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return nil }
        let sentinel = "\u{E002}"
        let protected = trimmed.replacingOccurrences(of: "\\|", with: sentinel)
        var parts = protected.components(separatedBy: "|")
        // Leading/trailing `|` produce empty first/last fragments.
        if parts.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            parts.removeFirst()
        }
        if parts.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            parts.removeLast()
        }
        guard !parts.isEmpty else { return nil }
        return parts.map {
            $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: sentinel, with: "|")
        }
    }

    /// Parse the `|---|:---:|` separator row into per-column alignments.
    /// Column count must match the header exactly — a mismatch means the
    /// two lines only look like a table, and misreading prose as a table
    /// is worse than missing one.
    static func parseTableSeparator(_ line: String,
                                    columns: Int) -> [TableAlignment]? {
        guard let cells = parseTableCells(line), cells.count == columns else {
            return nil
        }
        var aligns: [TableAlignment] = []
        for cell in cells {
            var body = Substring(cell)
            let left = body.hasPrefix(":")
            if left { body = body.dropFirst() }
            let right = body.hasSuffix(":")
            if right { body = body.dropLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else {
                return nil
            }
            switch (left, right) {
            case (true, true): aligns.append(.center)
            case (false, true): aligns.append(.trailing)
            default: aligns.append(.leading)
            }
        }
        return aligns
    }

    /// Folds consecutive `.paragraph` lines (no intervening `.blank`)
    /// into a single joined paragraph so line-wrapped prose renders as
    /// one Text view rather than N short lines.
    private static func mergeAdjacentParagraphs(_ blocks: [Block]) -> [Block] {
        var out: [Block] = []
        var buffer: [String] = []

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            out.append(.paragraph(text: buffer.joined(separator: " ")))
            buffer.removeAll(keepingCapacity: true)
        }

        for b in blocks {
            if case .paragraph(let t) = b {
                buffer.append(t.trimmingCharacters(in: .whitespaces))
            } else {
                flushBuffer()
                out.append(b)
            }
        }
        flushBuffer()
        return out
    }

    // MARK: - Fenced code extraction

    fileprivate struct ExtractedCode { let language: String; let body: String }

    /// Replace every ` ```lang\n…\n``` ` with a Private-Use-Area
    /// sentinel `U+E000 CB{index} U+E000` so downstream passes can treat
    /// the placeholder as an opaque line. Unclosed fences eat the rest
    /// of the input as code.
    private static func extractFencedCodeBlocks(_ source: String)
    -> (skeleton: String, blocks: [ExtractedCode]) {
        var blocks: [ExtractedCode] = []
        var out = ""
        var remaining = Substring(source)
        let fence = "```"

        while let openRange = remaining.range(of: fence) {
            if openRange.lowerBound > remaining.startIndex {
                out += remaining[remaining.startIndex..<openRange.lowerBound]
            }
            let afterFence = openRange.upperBound
            var lang = ""
            var bodyStart = afterFence
            if let nl = remaining[afterFence...].firstIndex(of: "\n") {
                let rawLang = remaining[afterFence..<nl]
                    .trimmingCharacters(in: .whitespaces)
                // Only the first whitespace-separated token is the
                // language.
                lang = rawLang.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                bodyStart = remaining.index(after: nl)
            }
            if let closeRange = remaining[bodyStart...].range(of: fence) {
                let body = String(remaining[bodyStart..<closeRange.lowerBound])
                let idx = blocks.count
                blocks.append(ExtractedCode(language: lang, body: body))
                out += "\n\u{E000}CB\(idx)\u{E000}\n"
                remaining = remaining[closeRange.upperBound...]
                // Consume an optional newline right after the closing
                // fence so we don't emit a phantom blank paragraph.
                if remaining.first == "\n" {
                    remaining = remaining.dropFirst()
                }
            } else {
                // Unclosed — treat the rest as code.
                let body = String(remaining[bodyStart...])
                let idx = blocks.count
                blocks.append(ExtractedCode(language: lang, body: body))
                out += "\n\u{E000}CB\(idx)\u{E000}\n"
                remaining = remaining[remaining.endIndex...]
            }
        }
        out += remaining
        return (out, blocks)
    }

    /// If `line` is a lone `U+E000 CB{index} U+E000` placeholder
    /// (possibly with surrounding whitespace) return `index`.
    private static func codeBlockIndex(in line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let sentinel: Character = "\u{E000}"
        guard trimmed.first == sentinel, trimmed.last == sentinel else { return nil }
        let inner = trimmed.dropFirst().dropLast()
        guard inner.hasPrefix("CB") else { return nil }
        return Int(inner.dropFirst(2))
    }

    // MARK: - Per-line classifiers

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        guard let first = trimmed.first, "-*_".contains(first) else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    private static func parseHeading(_ trimmed: String)
    -> (level: Int, text: String)? {
        var hashes = 0
        for ch in trimmed {
            if ch == "#" { hashes += 1; continue }
            break
        }
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let content = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return (hashes, content)
    }

    private static func parseBlockquote(_ line: String)
    -> (depth: Int, text: String)? {
        // Allow optional leading whitespace in front of the `>`s.
        var i = line.startIndex
        while i < line.endIndex && (line[i] == " " || line[i] == "\t") {
            i = line.index(after: i)
        }
        guard i < line.endIndex, line[i] == ">" else { return nil }
        var depth = 0
        while i < line.endIndex && line[i] == ">" {
            depth += 1
            i = line.index(after: i)
        }
        // Optional single space after the last `>`.
        if i < line.endIndex, line[i] == " " {
            i = line.index(after: i)
        }
        return (depth, String(line[i...]))
    }

    private static func parseOrderedItem(_ line: String)
    -> (indent: Int, number: String, text: String)? {
        var indent = 0
        var i = line.startIndex
        while i < line.endIndex, line[i] == " " {
            indent += 1
            i = line.index(after: i)
        }
        let rest = line[i...]
        var j = rest.startIndex
        while j < rest.endIndex, rest[j].isNumber {
            j = rest.index(after: j)
        }
        guard j > rest.startIndex,
              j < rest.endIndex,
              rest[j] == "."
        else { return nil }
        let numberEnd = rest.index(after: j)
        guard numberEnd < rest.endIndex, rest[numberEnd] == " " else { return nil }
        let num = String(rest[rest.startIndex..<j])
        let content = String(rest[rest.index(after: numberEnd)...])
        return (indent, num, content)
    }

    private static func parseBulletItem(_ line: String)
    -> (indent: Int, text: String)? {
        var indent = 0
        var i = line.startIndex
        while i < line.endIndex, line[i] == " " {
            indent += 1
            i = line.index(after: i)
        }
        guard i < line.endIndex else { return nil }
        let marker = line[i]
        guard marker == "-" || marker == "*" else { return nil }
        let afterMarker = line.index(after: i)
        // Require a space after the marker so `*italic*` isn't caught.
        guard afterMarker < line.endIndex, line[afterMarker] == " " else { return nil }
        let content = String(line[line.index(after: afterMarker)...])
        return (indent, content)
    }
}

// MARK: - Block list view

private struct MarkdownBlockList: View {
    let blocks: [MarkdownRenderer.Block]
    /// Cache key for the per-block displayed text the search pass needs.
    /// Never rendered — see `MarkdownRenderer.render`.
    let source: String
    let compactSpacing: Bool

    /// This ROW's slice of the active find: the query, which match is
    /// current, and how many matches precede the row. `.inactive`
    /// whenever no find bar is open, which is the overwhelmingly common
    /// case and costs nothing.
    @Environment(\.sipSearchSlot) private var searchSlot

    /// Where each block's matches start, counted from the row's own
    /// base. Empty (and never computed) unless a query is live.
    private var blockSlots: [SearchHighlightSlot] {
        guard searchSlot.isActive else { return [] }
        let texts = MarkdownRenderer.cachedDisplayedTexts(source, blocks: blocks)
        var slots: [SearchHighlightSlot] = []
        slots.reserveCapacity(blocks.count)
        var running = 0
        for text in texts {
            slots.append(searchSlot.advanced(by: running))
            running += SearchMatching.count(of: searchSlot.query, in: text)
        }
        return slots
    }

    var body: some View {
        let slots = blockSlots
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                let slot = index < slots.count ? slots[index] : .inactive
                switch block {
                case .heading(let level, let text):
                    HeadingBlock(level: level, text: text, slot: slot)
                case .paragraph(let text):
                    MarkdownInlineText(text, slot: slot)
                        .padding(.vertical, paragraphGap)
                case .horizontalRule:
                    Rectangle()
                        .fill(SipDesign.borderLight.opacity(0.6))
                        .frame(height: 1)
                        .padding(.vertical, 6)
                case .bulletItem(let indent, let text):
                    ListRow(marker: marker(for: indent),
                            indent: indent,
                            text: text,
                            slot: slot)
                case .orderedItem(let indent, let number, let text):
                    ListRow(marker: "\(number).",
                            indent: indent,
                            text: text,
                            markerWidth: 20,
                            slot: slot)
                case .blockquote(let depth, let text):
                    BlockquoteRow(depth: depth, text: text, slot: slot)
                case .codeBlock(let lang, let body):
                    CodeBlockView(language: lang, code: body, slot: slot)
                        .padding(.vertical, 4)
                case .table(let header, let alignments, let rows):
                    MarkdownTableView(header: header,
                                      alignments: alignments,
                                      rows: rows,
                                      slot: slot)
                        .padding(.vertical, 6)
                case .displayMath(let latex):
                    MathDisplayBlock(latex: latex)
                        .padding(.vertical, 6)
                case .blank:
                    Spacer().frame(height: 6)
                }
            }
        }
    }

    private var paragraphGap: CGFloat { compactSpacing ? 1 : 2 }

    private func marker(for indent: Int) -> String {
        // 2-space or 4-space indent → nested bullet: nesting is
        // detected by leading-space count.
        indent >= 2 ? "◦" : "•"
    }
}

// MARK: - Heading

private struct HeadingBlock: View {
    let level: Int
    let text: String
    var slot: SearchHighlightSlot = .inactive
    @Environment(\.sipFontScale) private var fontScale

    var body: some View {
        var attr = MarkdownInline.attributed(text, scale: fontScale)
        attr.applySearchHighlight(slot)
        let (size, weight, underline, topPad): (CGFloat, Font.Weight, Bool, CGFloat) = {
            switch level {
            case 1: return (18 * fontScale, .bold, true, 10)
            case 2: return (16 * fontScale, .bold, false, 8)
            default: return (14 * fontScale, .bold, false, 4)
            }
        }()
        var styled = attr
        styled.font = Font.system(size: size, weight: weight)
        if underline { styled.underlineStyle = Text.LineStyle.single }
        return Text(styled)
            .foregroundColor(ChatDesign.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, topPad)
            .padding(.bottom, 2)
    }
}

// MARK: - List row

private struct ListRow: View {
    let marker: String
    let indent: Int
    let text: String
    var markerWidth: CGFloat = 14
    var slot: SearchHighlightSlot = .inactive
    @Environment(\.sipFontScale) private var fontScale

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(marker)
                .font(.system(size: 14 * fontScale))
                .foregroundColor(ChatDesign.textPrimary)
                .frame(width: markerWidth * fontScale, alignment: .leading)
            MarkdownInlineText(text, slot: slot)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(12 + indent * 6))
        .padding(.vertical, 1)
    }
}

// MARK: - Blockquote

private struct BlockquoteRow: View {
    let depth: Int
    let text: String
    var slot: SearchHighlightSlot = .inactive

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<max(depth, 1), id: \.self) { _ in
                Rectangle()
                    .fill(ChatMarkdownStyle.dim.opacity(0.55))
                    .frame(width: 2)
                    .padding(.trailing, 6)
            }
            MarkdownInlineText(text, slot: slot)
                .foregroundColor(ChatMarkdownStyle.dim)
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .padding(.vertical, 1)
    }
}

// MARK: - Inline text view

/// Single-line-ish inline Markdown renderer. Applies LaTeX symbol
/// translation, then builds an `AttributedString` with inline code,
/// bold, italic, and auto-linked URLs.
struct MarkdownInlineText: View {
    private let source: String
    /// This block's slice of the active find. Defaulted, so the two
    /// call sites outside a searchable transcript need not know.
    private let slot: SearchHighlightSlot
    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.sipLineSpacingFactor) private var lineSpacingFactor

    init(_ text: String, slot: SearchHighlightSlot = .inactive) {
        self.source = text
        self.slot = slot
    }

    private var attributed: AttributedString {
        var attr = MarkdownInline.attributed(source, scale: fontScale)
        attr.applySearchHighlight(slot)
        return attr
    }

    var body: some View {
        Text(attributed)
            .font(.system(size: 14 * fontScale))
            .lineSpacing(14 * fontScale * lineSpacingFactor)
            .foregroundColor(ChatDesign.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

// MARK: - Inline formatter core

enum MarkdownInline {
    /// Build the `AttributedString` for one line of inline Markdown,
    /// in this order:
    ///   1. LaTeX symbol translation (non-code).
    ///   2. Extract inline-code spans into placeholders.
    ///   3. Bold, italic, URL parsing on the remaining text.
    ///   4. Re-inject inline-code spans with the sky-blue monospace style.
    /// `scale` is the font-tier multiplier (`\.sipFontScale`) — static
    /// helpers can't read the environment, so callers pass it through.
    static func attributed(_ text: String, scale: CGFloat = 1) -> AttributedString {
        // Shield inline code FIRST — backticked identifiers must reach
        // the screen byte-exact (`session_id` would otherwise render
        // as "sessionᵢd", `x^2` as "x²"). LaTeX then runs on the
        // non-code skeleton only, honoring this file's header
        // contract. The \u{E001}ICn\u{E001}
        // sentinels are untouchable by every LaTeX rule (all need
        // backslashes, ^, _, or $).
        let (skeleton, codeSpans) = extractInlineCode(text)
        let translated = LatexSymbols.translate(skeleton)

        // Parse bold / italic / links into a sequence of styled runs.
        var runs = emphasisRuns(in: translated)
        // Re-inject inline-code runs in place.
        runs = reinjectCodeSpans(runs, spans: codeSpans)

        var attr = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if run.bold {
                piece.font = Font.system(size: 14 * scale, weight: .semibold)
            }
            if run.italic {
                let base = piece.font ?? Font.system(size: 14 * scale)
                piece.font = base.italic()
            }
            if run.code {
                piece.font = Font.system(size: 13 * scale, design: .monospaced)
                piece.foregroundColor = ChatMarkdownStyle.inlineCode
            }
            if let url = run.link {
                piece.link = url
                piece.underlineStyle = Text.LineStyle.single
                piece.foregroundColor = ChatDesign.blue
            }
            attr.append(piece)
        }
        return attr
    }

    private struct Run {
        var text: String
        var bold: Bool = false
        var italic: Bool = false
        var code: Bool = false
        var link: URL? = nil
    }

    // MARK: Inline code extraction

    /// Pull every `` `code` `` into a numbered sentinel so the emphasis
    /// pass doesn't see backticks at all.
    private static func extractInlineCode(_ text: String)
    -> (skeleton: String, spans: [String]) {
        var spans: [String] = []
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "`" {
                let after = text.index(after: i)
                if let close = text[after...].firstIndex(of: "`") {
                    let inside = String(text[after..<close])
                    let idx = spans.count
                    spans.append(inside)
                    out += "\u{E001}IC\(idx)\u{E001}"
                    i = text.index(after: close)
                    continue
                }
            }
            out.append(text[i])
            i = text.index(after: i)
        }
        return (out, spans)
    }

    // MARK: Emphasis + link parsing

    private struct Pattern {
        let regex: NSRegularExpression
        let build: (NSTextCheckingResult, NSString) -> Run
    }

    /// Schemes a rendered link may carry. Everything here is inert until
    /// the user acts on it in a browser or a mail client.
    ///
    /// Nothing this renderer draws is trusted: a model's reply, a note,
    /// and above all an agent's TOOL RESULT — which is whatever the
    /// agent's last web fetch or file read happened to return. In
    /// `[label](url)` the label is arbitrary text, so the destination is
    /// not visible before the click, and macOS hands any other scheme
    /// straight to whichever app claims it: `file:` LAUNCHES an
    /// application bundle or mounts a disk image, `smb:` offers this
    /// machine's credentials to a remote host, and an app's own scheme
    /// drives that app with no prompt at all.
    ///
    /// A refused link keeps its LABEL and loses its destination, which
    /// is what every markdown host does with a scheme it will not
    /// follow. Dropping the run entirely would delete text the reader
    /// can see, and that is how a sanitizer becomes a bug report.
    private static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    /// A URL for `piece.link`, or nil when the scheme is not one this
    /// app is willing to hand to the system.
    static func safeLink(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(),
              allowedLinkSchemes.contains(scheme)
        else { return nil }
        return url
    }

    /// Compiled once at first access and reused for every `emphasisRuns`
    /// call.
    private static let compiledPatterns: [Pattern] = [
        Pattern(
            regex: try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#),
            build: { m, ns in
                let label = ns.substring(with: m.range(at: 1))
                let urlStr = ns.substring(with: m.range(at: 2))
                return Run(text: label, link: safeLink(urlStr))
            }
        ),
        Pattern(
            regex: try! NSRegularExpression(pattern: #"https?://[^\s)]+"#),
            build: { m, ns in
                let whole = ns.substring(with: m.range)
                // Through the same gate as `[label](url)`, though this
                // pattern already spells out its schemes: one rule, so
                // widening the regex can never widen what is clickable.
                return Run(text: whole, link: safeLink(whole))
            }
        ),
        Pattern(
            regex: try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#),
            build: { m, ns in
                Run(text: ns.substring(with: m.range(at: 1)), bold: true)
            }
        ),
        // Italic: non-greedy, require non-space inside.
        Pattern(
            regex: try! NSRegularExpression(pattern: #"(?<!\*)\*([^\s*](?:.*?[^\s*])?)\*(?!\*)"#),
            build: { m, ns in
                Run(text: ns.substring(with: m.range(at: 1)), italic: true)
            }
        ),
    ]

    /// Parse bold / italic / links (both `[text](url)` and bare
    /// `https?://…`) into styled runs. Inline-code placeholders pass
    /// through unchanged and are swapped back in by `reinjectCodeSpans`.
    private static func emphasisRuns(in text: String) -> [Run] {
        let ns = text as NSString
        let patterns = compiledPatterns

        var runs: [Run] = []
        var cursor = 0

        while cursor < ns.length {
            let searchRange = NSRange(location: cursor, length: ns.length - cursor)
            var best: (NSTextCheckingResult, Pattern)? = nil
            for p in patterns {
                if let m = p.regex.firstMatch(in: text, range: searchRange) {
                    if let current = best {
                        if m.range.location < current.0.range.location {
                            best = (m, p)
                        }
                    } else {
                        best = (m, p)
                    }
                }
            }
            guard let (match, pattern) = best else {
                runs.append(Run(text: ns.substring(with: searchRange)))
                break
            }
            if match.range.location > cursor {
                let pre = NSRange(location: cursor,
                                  length: match.range.location - cursor)
                runs.append(Run(text: ns.substring(with: pre)))
            }
            runs.append(pattern.build(match, ns))
            cursor = match.range.location + match.range.length
        }
        return runs
    }

    // MARK: Code re-injection

    /// Walk `runs` and split any `text` fragment that contains a
    /// `\u{E001}IC{idx}\u{E001}` sentinel into a sequence of runs with
    /// the code piece rendered monospace + sky-blue.
    private static func reinjectCodeSpans(_ runs: [Run],
                                          spans: [String]) -> [Run] {
        guard !spans.isEmpty else { return runs }
        var out: [Run] = []
        for var run in runs {
            // Don't split links / already-styled runs that somehow carry
            // a sentinel — treat the sentinel as opaque text in that
            // corner case by just substituting back.
            if run.link != nil {
                if !run.text.contains("\u{E001}") { out.append(run); continue }
                run.text = restore(run.text, spans: spans)
                out.append(run)
                continue
            }
            let pieces = split(run.text, spans: spans)
            for piece in pieces {
                var child = run
                child.text = piece.text
                if piece.isCode { child.code = true; child.italic = false; child.bold = false }
                out.append(child)
            }
        }
        return out
    }

    private struct Piece { let text: String; let isCode: Bool }

    private static func split(_ text: String, spans: [String]) -> [Piece] {
        // Build the pattern with Swift interpolation so the Private-Use
        // sentinel codepoints are embedded as real characters. A raw
        // string `#"..."#` would pass the literal `\u{E001}` through to
        // NSRegularExpression, which doesn't understand that form.
        let pattern = "\u{E001}IC(\\d+)\u{E001}"
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            return [Piece(text: text, isCode: false)]
        }
        let ns = text as NSString
        var pieces: [Piece] = []
        var cursor = 0
        let matches = re.matches(in: text,
                                 range: NSRange(location: 0, length: ns.length))
        for m in matches {
            if m.range.location > cursor {
                pieces.append(Piece(
                    text: ns.substring(with: NSRange(location: cursor,
                                                    length: m.range.location - cursor)),
                    isCode: false))
            }
            let idxStr = ns.substring(with: m.range(at: 1))
            if let idx = Int(idxStr), idx < spans.count {
                pieces.append(Piece(text: spans[idx], isCode: true))
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            pieces.append(Piece(
                text: ns.substring(with: NSRange(location: cursor,
                                                length: ns.length - cursor)),
                isCode: false))
        }
        return pieces
    }

    private static func restore(_ text: String, spans: [String]) -> String {
        var out = text
        for (i, span) in spans.enumerated() {
            out = out.replacingOccurrences(of: "\u{E001}IC\(i)\u{E001}", with: span)
        }
        return out
    }
}

// MARK: - Code block view

struct CodeBlockView: View {
    let language: String
    let code: String
    /// Code IS searched — a path or an identifier is the likeliest
    /// thing anyone looks for in an agent transcript. The language
    /// label above it is not: it is a caption, not content, and
    /// `MarkdownRenderer.displayedTexts` leaves it out to match.
    var slot: SearchHighlightSlot = .inactive
    @Environment(\.sipFontScale) private var fontScale

    private var body_: AttributedString {
        AttributedString.highlighting(code, slot: slot).0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language)
                    .font(.system(size: 11 * fontScale, weight: .semibold, design: .monospaced))
                    .foregroundColor(ChatMarkdownStyle.dim)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(body_)
                    .font(.system(size: 13 * fontScale, design: .monospaced))
                    .foregroundColor(ChatDesign.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .textSelection(.enabled)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.12))
        )
    }
}

// MARK: - Table view

/// GFM pipe table rendered as a bordered grid — header row semibold over
/// a tinted band, hairline separators between body rows, per-column
/// alignment from the `:---:` markers, and inline markdown inside every
/// cell. Cells wrap rather than forcing the table wide; every column is
/// width-flexible so the table spans the message column the way Claude
/// Desktop's tables do.
private struct MarkdownTableView: View {
    let header: [String]
    let alignments: [MarkdownRenderer.TableAlignment]
    let rows: [[String]]
    var slot: SearchHighlightSlot = .inactive
    @Environment(\.sipFontScale) private var fontScale

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    /// Matches preceding each cell, in the order this grid draws them:
    /// header row first, then each body row, left to right, every row
    /// padded to `columnCount`. Mirrors
    /// `MarkdownRenderer.tableDisplayedText` exactly — the two are one
    /// contract, and a change to either belongs in both.
    ///
    /// Row 0 is the HEADER; body row `r` is `bases[r + 1]`.
    private var cellBases: [[Int]] {
        guard slot.isActive else { return [] }
        let all = [header] + rows
        var out: [[Int]] = []
        var running = 0
        for line in all {
            var bases: [Int] = []
            bases.reserveCapacity(columnCount)
            for c in 0..<columnCount {
                bases.append(running)
                guard c < line.count else { continue }
                running += SearchMatching.count(
                    of: slot.query,
                    in: String(MarkdownInline.attributed(line[c]).characters))
            }
            out.append(bases)
        }
        return out
    }

    private func cellSlot(_ bases: [[Int]], row: Int, column: Int) -> SearchHighlightSlot {
        guard slot.isActive, row < bases.count, column < bases[row].count else {
            return .inactive
        }
        return slot.advanced(by: bases[row][column])
    }

    var body: some View {
        let bases = cellBases
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { c in
                    cell(pad(header)[c], column: c, isHeader: true,
                         slot: cellSlot(bases, row: 0, column: c))
                        .background(ChatMarkdownStyle.userBlockBg)
                }
            }
            ForEach(rows.indices, id: \.self) { r in
                Divider()
                    .overlay(SipDesign.borderLight.opacity(r == 0 ? 0.9 : 0.5))
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { c in
                        cell(pad(rows[r])[c], column: c, isHeader: false,
                             slot: cellSlot(bases, row: r + 1, column: c))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SipDesign.borderLight.opacity(0.8), lineWidth: 1)
        )
    }

    /// Ragged rows happen (LLMs drop a trailing cell); pad to the grid's
    /// column count so every GridRow lines up.
    private func pad(_ cells: [String]) -> [String] {
        cells.count >= columnCount
            ? cells
            : cells + Array(repeating: "", count: columnCount - cells.count)
    }

    private func alignment(for column: Int) -> Alignment {
        guard column < alignments.count else { return .topLeading }
        switch alignments[column] {
        case .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
        }
    }

    private func cell(_ text: String, column: Int, isHeader: Bool,
                      slot: SearchHighlightSlot = .inactive) -> some View {
        var attr = MarkdownInline.attributed(text, scale: fontScale)
        if isHeader {
            attr.font = Font.system(size: 13 * fontScale, weight: .semibold)
        }
        attr.applySearchHighlight(slot)
        return Text(attr)
            .font(.system(size: 13 * fontScale))
            .foregroundColor(ChatDesign.textPrimary)
            .multilineTextAlignment(
                column < alignments.count && alignments[column] == .center
                    ? .center
                    : (column < alignments.count && alignments[column] == .trailing
                        ? .trailing : .leading)
            )
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: alignment(for: column))
    }
}
