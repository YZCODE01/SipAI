// NoteHTML.swift
// Converts a note's Markdown body into a self-contained HTML document,
// for BOTH the note Preview pane and PDF export. One converter, so the
// PDF cannot disagree with what the reader was just looking at.
//
// Math is why this exists. `MarkdownRenderer` translates LaTeX into
// Unicode symbols, which reads well for `$\pi r^2$` and falls apart on
// anything structural — nested `\frac`, matrices, `\begin{align}`,
// limits set above and below. Here the LaTeX is shielded from every
// other pass and handed to KaTeX untouched, so it is laid out for real.
//
// BLOCK structure is `MarkdownRenderer.parse`, deliberately: headings,
// lists, tables, quotes and fences must not drift between a note and a
// chat. Only the inline pass is separate, because the shared one
// (`MarkdownInline.attributed`) runs `LatexSymbols.translate` and would
// destroy the LaTeX before KaTeX ever saw it.
//
// Nothing from the note reaches the document as markup. Every span of
// note text is HTML-escaped and the only tags in the output are the ones
// written here — a note is model-generated and hand-editable, so it is
// treated as untrusted input.

import Foundation

enum NoteHTML {

    // MARK: - Shielding sentinels

    /// Private-use delimiters for shielded spans. Code, math and links
    /// are lifted out BEFORE the text is escaped and put back AFTER the
    /// emphasis pass, so no later rule can see a backtick, a dollar or a
    /// URL. These characters survive `escape` untouched and neither
    /// Markdown nor LaTeX can produce them.
    private static let sOpen = "\u{E010}"
    private static let sClose = "\u{E011}"

    private static func token(_ kind: String, _ index: Int) -> String {
        "\(sOpen)\(kind)\(index)\(sClose)"
    }

    /// LaTeX environments that stand on their own as display math when
    /// they appear at the top level, i.e. not already wrapped in `$$`.
    /// Models emit these bare constantly.
    private static let displayEnvironments: Set<String> = [
        "equation", "equation*", "align", "align*", "aligned",
        "gather", "gather*", "gathered", "alignat", "alignat*",
        "multline", "multline*", "split", "array",
        "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix",
        "smallmatrix", "cases", "dcases", "subarray",
    ]

    // MARK: - Entry point

    struct Metadata {
        var title: String
        var model: String?
        var date: Date?
    }

    /// Full HTML document. `katexHref` is the directory-relative prefix
    /// the KaTeX assets sit at (they are staged next to the written HTML
    /// file, so this is normally empty).
    static func document(markdown: String,
                         metadata: Metadata,
                         dark: Bool,
                         forPrint: Bool) -> String {
        // A PDF carries its own title block, and a note's opening H1 IS
        // its title by construction (`createNote` derives one from the
        // other), so printing both puts the name on the page twice.
        // On screen the title lives in the window's title bar, which is
        // a different surface, so the H1 stays.
        let source = forPrint
            ? strippingLeadingHeading(markdown, matching: metadata.title)
            : markdown
        let body = bodyHTML(source)
        let heading = headerHTML(metadata, forPrint: forPrint)
        // `user-scalable` and the viewport tag are deliberately absent:
        // this is a fixed-width document in a web view we size ourselves.
        return """
        <!DOCTYPE html>
        <html lang="en" data-theme="\(dark ? "dark" : "light")">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; \
        style-src 'unsafe-inline' file:; script-src file:; \
        font-src file:; img-src 'none'; connect-src 'none'; base-uri 'none'">
        <title>\(escape(metadata.title))</title>
        <link rel="stylesheet" href="katex.min.css">
        <style>\(css(forPrint: forPrint))</style>
        </head>
        <body class="\(forPrint ? "print" : "screen")">
        <main id="sipai-note">
        \(heading)\(body)
        </main>
        <script src="katex.min.js"></script>
        <script src="sipai-render.js"></script>
        </body>
        </html>
        """
    }

    // MARK: - Body

    /// The note body as HTML, with no surrounding document. Split out so
    /// the verification harness can exercise it without a web view.
    static func bodyHTML(_ markdown: String) -> String {
        // The sentinels are private-use characters no legitimate note
        // contains — but a note is untrusted, and PUA characters are
        // valid UTF-8 that round-trips through the .md file. Stripped
        // up front so content can never FORGE a sentinel and address
        // the span arrays with an index of its own choosing.
        let source = markdown
            .replacingOccurrences(of: sOpen, with: "")
            .replacingOccurrences(of: sClose, with: "")
        var fences: [(language: String, body: String)] = []
        var display: [String] = []
        let shielded = shieldBlockSpans(source, fences: &fences, display: &display)
        let blocks = MarkdownRenderer.parse(shielded)
        return render(blocks, fences: fences, display: display)
    }

    /// Drop the body's opening H1 when it just repeats `title`.
    /// Anything else — a different heading, or none — is left alone.
    static func strippingLeadingHeading(_ markdown: String,
                                        matching title: String) -> String {
        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var lines = markdown.components(separatedBy: "\n")
        var i = 0
        while i < lines.count,
              lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
        guard i < lines.count else { return markdown }
        let candidate = lines[i].trimmingCharacters(in: .whitespaces)
        guard candidate.hasPrefix("# "),
              norm(String(candidate.dropFirst(2))) == norm(title)
        else { return markdown }
        lines.removeSubrange(0...i)
        return lines.joined(separator: "\n")
    }

    private static func headerHTML(_ meta: Metadata, forPrint: Bool) -> String {
        // On screen the note's title and pills already sit in the title
        // bar above the web view, so repeating them would show the title
        // twice. In a PDF there is no title bar and the file has to
        // stand on its own.
        guard forPrint else { return "" }
        var parts: [String] = []
        if let model = meta.model, !model.isEmpty { parts.append(escape(model)) }
        if let date = meta.date {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            parts.append(escape(f.string(from: date)))
        }
        let sub = parts.isEmpty
            ? ""
            : "<p class=\"sipai-meta\">\(parts.joined(separator: " · "))</p>\n"
        return "<header class=\"sipai-head\">\n<h1 class=\"sipai-title\">"
            + escape(meta.title) + "</h1>\n" + sub + "</header>\n"
    }

    // MARK: - Block-level shielding

    /// Lift fenced code and display math out of the source, leaving a
    /// lone sentinel paragraph in place of each.
    ///
    /// Fences go FIRST: a `$$` inside a code sample is code, not math.
    /// Each sentinel is written with a blank line on either side so
    /// `mergeAdjacentParagraphs` cannot glue it to the prose around it.
    private static func shieldBlockSpans(
        _ source: String,
        fences: inout [(language: String, body: String)],
        display: inout [String]
    ) -> String {
        var out: [String] = []
        let lines = source.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // --- Fenced code -------------------------------------------------
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fenceMark = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(fenceMark) { i += 1; break }
                    body.append(lines[i])
                    i += 1
                }
                fences.append((language, body.joined(separator: "\n")))
                out.append("")
                out.append(token("F", fences.count - 1))
                out.append("")
                continue
            }

            // --- Display math ------------------------------------------------
            if let (latex, next) = displayMath(lines, from: i) {
                display.append(latex)
                out.append("")
                out.append(token("D", display.count - 1))
                out.append("")
                i = next
                continue
            }

            out.append(line)
            i += 1
        }
        return out.joined(separator: "\n")
    }

    /// A display-math run starting at `index`, plus the line to resume
    /// from. Handles `$$…$$`, `\[…\]` and a bare `\begin{env}…\end{env}`,
    /// each of which may be one line or many.
    private static func displayMath(_ lines: [String],
                                    from index: Int) -> (String, Int)? {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

        func gather(open: String, close: String) -> (String, Int)? {
            guard trimmed.hasPrefix(open) else { return nil }
            let afterOpen = String(trimmed.dropFirst(open.count))
            // Opener and closer on the same line.
            if let r = afterOpen.range(of: close, options: .backwards),
               r.upperBound == afterOpen.endIndex, !afterOpen.isEmpty {
                let inner = String(afterOpen[..<r.lowerBound])
                return (inner.trimmingCharacters(in: .whitespacesAndNewlines), index + 1)
            }
            var body: [String] = afterOpen.isEmpty ? [] : [afterOpen]
            var j = index + 1
            while j < lines.count {
                let t = lines[j].trimmingCharacters(in: .whitespaces)
                if let r = t.range(of: close) {
                    let head = String(t[..<r.lowerBound])
                    if !head.isEmpty { body.append(head) }
                    return (body.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines), j + 1)
                }
                body.append(lines[j])
                j += 1
            }
            // Unterminated: not math. Leaving it as prose keeps a stray
            // `$$` in someone's writing from swallowing the rest of the
            // note.
            return nil
        }

        if let hit = gather(open: "$$", close: "$$") { return hit }
        if let hit = gather(open: "\\[", close: "\\]") { return hit }

        // Bare \begin{env} … \end{env}
        if trimmed.hasPrefix("\\begin{"),
           let closeBrace = trimmed.firstIndex(of: "}") {
            let start = trimmed.index(trimmed.startIndex, offsetBy: 7)
            let env = String(trimmed[start..<closeBrace])
            guard displayEnvironments.contains(env) else { return nil }
            let terminator = "\\end{\(env)}"
            if trimmed.contains(terminator) {
                return (trimmed, index + 1)
            }
            var body: [String] = [lines[index]]
            var j = index + 1
            while j < lines.count {
                body.append(lines[j])
                if lines[j].contains(terminator) {
                    return (body.joined(separator: "\n"), j + 1)
                }
                j += 1
            }
            return nil
        }
        return nil
    }

    // MARK: - Block rendering

    private static func render(_ blocks: [MarkdownRenderer.Block],
                               fences: [(language: String, body: String)],
                               display: [String]) -> String {
        var out: [String] = []
        // Open list levels, innermost last. `indent` from the parser is
        // a SPACE COUNT, so a level is two spaces.
        var listStack: [(tag: String, level: Int)] = []
        var quoteDepth = 0

        func closeLists(toLevel level: Int) {
            while let top = listStack.last, top.level > level {
                out.append("</\(top.tag)>")
                listStack.removeLast()
            }
        }
        func closeAllLists() { closeLists(toLevel: -1) }
        func closeQuotes(to depth: Int) {
            while quoteDepth > depth {
                out.append("</blockquote>")
                quoteDepth -= 1
            }
        }

        for block in blocks {
            switch block {
            case .bulletItem, .orderedItem:
                break
            default:
                closeAllLists()
            }
            if case .blockquote = block {} else { closeQuotes(to: 0) }

            switch block {
            case .blank:
                continue

            case .heading(let level, let text):
                if let idx = sentinelIndex(text, kind: "D"),
                   display.indices.contains(idx) {
                    out.append(displayHTML(display[idx]))
                } else {
                    let l = min(max(level, 1), 6)
                    out.append("<h\(l)>\(inlineHTML(text))</h\(l)>")
                }

            case .paragraph(let text):
                let t = text.trimmingCharacters(in: .whitespaces)
                if let idx = sentinelIndex(t, kind: "F"),
                   fences.indices.contains(idx) {
                    out.append(fenceHTML(fences[idx]))
                } else if let idx = sentinelIndex(t, kind: "D"),
                          display.indices.contains(idx) {
                    out.append(displayHTML(display[idx]))
                } else if !t.isEmpty {
                    out.append("<p>\(inlineHTML(text))</p>")
                }

            case .horizontalRule:
                out.append("<hr>")

            case .bulletItem(let indent, let text):
                let level = indent / 2
                closeLists(toLevel: level)
                if listStack.last?.level != level || listStack.last?.tag != "ul" {
                    if listStack.last?.level == level { 
                        out.append("</\(listStack.removeLast().tag)>")
                    }
                    out.append("<ul>")
                    listStack.append(("ul", level))
                }
                out.append("<li>\(inlineHTML(text))</li>")

            case .orderedItem(let indent, let number, let text):
                let level = indent / 2
                closeLists(toLevel: level)
                if listStack.last?.level != level || listStack.last?.tag != "ol" {
                    if listStack.last?.level == level {
                        out.append("</\(listStack.removeLast().tag)>")
                    }
                    // Honour the author's first number rather than
                    // renumbering from 1.
                    let start = Int(number).map { $0 == 1 ? "" : " start=\"\($0)\"" } ?? ""
                    out.append("<ol\(start)>")
                    listStack.append(("ol", level))
                }
                out.append("<li>\(inlineHTML(text))</li>")

            case .blockquote(let depth, let text):
                let d = max(1, depth)
                while quoteDepth < d { out.append("<blockquote>"); quoteDepth += 1 }
                closeQuotes(to: d)
                let t = text.trimmingCharacters(in: .whitespaces)
                if let idx = sentinelIndex(t, kind: "D"),
                   display.indices.contains(idx) {
                    out.append(displayHTML(display[idx]))
                } else if !t.isEmpty {
                    out.append("<p>\(inlineHTML(text))</p>")
                }

            case .codeBlock(let language, let body):
                out.append(fenceHTML((language, body)))

            case .table(let header, let alignments, let rows):
                out.append(tableHTML(header: header, alignments: alignments, rows: rows))
            }
        }
        closeAllLists()
        closeQuotes(to: 0)
        return out.joined(separator: "\n")
    }

    /// The shielded-span index carried by `text`, when the whole string
    /// is exactly one sentinel of `kind`.
    private static func sentinelIndex(_ text: String, kind: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix(sOpen + kind), t.hasSuffix(sClose) else { return nil }
        let digits = t.dropFirst(sOpen.count + kind.count).dropLast(sClose.count)
        return Int(digits)
    }

    private static func fenceHTML(_ fence: (language: String, body: String)) -> String {
        let label = fence.language.isEmpty
            ? ""
            : "<div class=\"sipai-lang\">\(escape(fence.language))</div>"
        return "<div class=\"sipai-code\">\(label)<pre><code>"
            + escape(fence.body) + "</code></pre></div>"
    }

    /// A display-math node. The LaTeX rides as escaped TEXT and is read
    /// back with `textContent` in the page, so nothing in it can be
    /// markup — and KaTeX receives the original characters.
    private static func displayHTML(_ latex: String) -> String {
        "<div class=\"sipai-math\" data-display=\"1\">\(escape(latex))</div>"
    }

    private static func tableHTML(header: [String],
                                  alignments: [MarkdownRenderer.TableAlignment],
                                  rows: [[String]]) -> String {
        func style(_ i: Int) -> String {
            guard i < alignments.count else { return "" }
            switch alignments[i] {
            case .leading: return ""
            case .center: return " style=\"text-align:center\""
            case .trailing: return " style=\"text-align:right\""
            }
        }
        var out = "<table>\n<thead>\n<tr>"
        for (i, cell) in header.enumerated() {
            out += "<th\(style(i))>\(inlineHTML(cell))</th>"
        }
        out += "</tr>\n</thead>\n<tbody>\n"
        for row in rows {
            out += "<tr>"
            for (i, cell) in row.enumerated() {
                out += "<td\(style(i))>\(inlineHTML(cell))</td>"
            }
            out += "</tr>\n"
        }
        return out + "</tbody>\n</table>"
    }

    // MARK: - Inline rendering

    /// One line of inline Markdown as HTML, in this order:
    ///   1. shield inline code, then inline math, then links
    ///   2. escape everything that is left
    ///   3. bold / italic on the escaped remainder
    ///   4. put the shielded spans back as real elements
    ///
    /// Shielding before escaping is what lets a URL keep its `&` and a
    /// LaTeX span keep its backslashes; escaping before emphasis is what
    /// stops a note writing its own tags.
    static func inlineHTML(_ text: String) -> String {
        var codes: [String] = []
        var maths: [String] = []
        var links: [(label: String, href: String?)] = []

        var t = shieldPattern(text, pattern: #"`([^`\n]+)`"#, kind: "C") { m in
            codes.append(m[0]); return codes.count - 1
        }
        t = shieldPattern(t, pattern: #"\\\((.+?)\\\)"#, kind: "M") { m in
            maths.append(m[0]); return maths.count - 1
        }
        // Inline `$…$`: no whitespace just inside either delimiter, no
        // `$` or newline within. That is what keeps "$5 and $10 each"
        // from reading as math.
        t = shieldPattern(t, pattern: #"(?<![\\$])\$(?!\s)([^$\n]+?)(?<!\s)\$(?!\$)"#, kind: "M") { m in
            maths.append(m[0]); return maths.count - 1
        }
        t = shieldPattern(t, pattern: #"\[([^\]\n]+)\]\(([^)\s]+)\)"#, kind: "L") { m in
            links.append((label: m[0], href: gatedHref(m[1])))
            return links.count - 1
        }
        t = shieldPattern(t, pattern: #"(?<![\w@])https?://[^\s<>)\]]+"#, kind: "L") { m in
            links.append((label: m[0], href: gatedHref(m[0])))
            return links.count - 1
        }

        t = escape(t)
        t = regexReplace(t, pattern: #"\*\*(.+?)\*\*"#) { "<strong>\($0[0])</strong>" }
        t = regexReplace(t, pattern: #"(?<!\*)\*([^\s*](?:.*?[^\s*])?)\*(?!\*)"#) { "<em>\($0[0])</em>" }

        for (i, code) in codes.enumerated() {
            t = t.replacingOccurrences(of: token("C", i),
                                       with: "<code>\(escape(code))</code>")
        }
        for (i, math) in maths.enumerated() {
            t = t.replacingOccurrences(
                of: token("M", i),
                with: "<span class=\"sipai-math\" data-display=\"0\">\(escape(math))</span>")
        }
        for (i, link) in links.enumerated() {
            let inner = escape(link.label)
            // A refused scheme keeps its LABEL and loses the
            // destination, matching `MarkdownInline.safeLink`. Dropping
            // the run would delete text the reader can see.
            let html = link.href.map {
                "<a href=\"\(escape($0))\">\(inner)</a>"
            } ?? inner
            t = t.replacingOccurrences(of: token("L", i), with: html)
        }
        return t
    }

    /// http / https / mailto only — the same gate the SwiftUI renderer
    /// applies, reached through the same function so widening one can
    /// never widen only one of them.
    private static func gatedHref(_ raw: String) -> String? {
        MarkdownInline.safeLink(raw)?.absoluteString
    }

    // MARK: - Text helpers

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 16)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Replace each match with a sentinel, handing the capture groups to
    /// `store` and using its return value as the sentinel index.
    private static func shieldPattern(_ input: String,
                                      pattern: String,
                                      kind: String,
                                      store: ([String]) -> Int) -> String {
        regexReplace(input, pattern: pattern) { groups in
            token(kind, store(groups))
        }
    }

    /// Rewrite every match of `pattern`, passing the capture groups (or
    /// the whole match when the pattern has none) to `build`.
    private static func regexReplace(_ input: String,
                                     pattern: String,
                                     _ build: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        let matches = re.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var out = ""
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                out += ns.substring(with: NSRange(location: cursor,
                                                 length: m.range.location - cursor))
            }
            var groups: [String] = []
            if m.numberOfRanges > 1 {
                for g in 1..<m.numberOfRanges {
                    let r = m.range(at: g)
                    groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
                }
            } else {
                groups = [ns.substring(with: m.range)]
            }
            out += build(groups)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }
}

// MARK: - Stylesheet and bootstrap

extension NoteHTML {

    /// Page styling. The screen palette tracks `ChatDesign`; the print
    /// palette is always the light one, because a PDF is a document and
    /// nobody wants a dark rectangle on paper.
    static func css(forPrint: Bool) -> String {
        """
        :root {
          --fg: #1d1d1f; --dim: #86868b; --rule: #e5e7eb;
          --bg: #ffffff; --code-bg: #f6f7f9; --link: #2563eb;
          --quote: #d1d5db;
        }
        html[data-theme="dark"] {
          --fg: #f5f5f7; --dim: #a0a0a8; --rule: #48484c;
          --bg: #1e1e1e; --code-bg: #2c2c2e; --link: #6ea8ff;
          --quote: #5a5a5f;
        }
        * { box-sizing: border-box; }
        html, body { margin: 0; padding: 0; background: var(--bg); }
        body {
          color: var(--fg);
          font: 14px/1.62 -apple-system, BlinkMacSystemFont, "SF Pro Text",
                "Helvetica Neue", Helvetica, Arial, sans-serif;
          -webkit-font-smoothing: antialiased;
          overflow-wrap: break-word;
        }
        #sipai-note { padding: \(forPrint ? "0" : "16px 20px 40px"); }
        h1, h2, h3, h4, h5, h6 {
          line-height: 1.3; font-weight: 600; margin: 1.4em 0 0.5em;
        }
        h1 { font-size: 1.5em; }
        h2 { font-size: 1.28em; }
        h3 { font-size: 1.12em; }
        h4, h5, h6 { font-size: 1em; }
        #sipai-note > h1:first-child,
        #sipai-note > *:first-child { margin-top: 0; }
        p { margin: 0.62em 0; }
        a { color: var(--link); text-decoration: underline; }
        hr { border: 0; border-top: 1px solid var(--rule); margin: 1.5em 0; }
        ul, ol { margin: 0.55em 0; padding-left: 1.65em; }
        li { margin: 0.22em 0; }
        li > p { margin: 0.2em 0; }
        blockquote {
          margin: 0.8em 0; padding: 0.1em 0 0.1em 0.95em;
          border-left: 3px solid var(--quote); color: var(--dim);
        }
        code {
          font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
          font-size: 0.9em;
          background: var(--code-bg); border-radius: 4px; padding: 0.12em 0.34em;
        }
        .sipai-code {
          margin: 0.85em 0; background: var(--code-bg);
          border: 1px solid var(--rule); border-radius: 8px; overflow: hidden;
        }
        .sipai-lang {
          font: 11px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
          color: var(--dim); padding: 8px 12px 0; text-transform: lowercase;
        }
        .sipai-code pre {
          margin: 0; padding: 10px 12px 12px; overflow-x: auto;
        }
        .sipai-code code {
          background: none; padding: 0; font-size: 12.5px; line-height: 1.5;
        }
        table {
          border-collapse: collapse; margin: 0.9em 0; font-size: 0.95em;
          display: block; overflow-x: auto; max-width: 100%;
        }
        th, td {
          border: 1px solid var(--rule); padding: 5px 10px; text-align: left;
        }
        th { background: var(--code-bg); font-weight: 600; }
        .sipai-head { margin-bottom: 1.4em; }
        .sipai-title { margin: 0 0 0.25em; font-size: 1.75em; }
        .sipai-meta { margin: 0; color: var(--dim); font-size: 0.86em; }
        /* A wide equation scrolls rather than forcing the page wider. */
        .katex-display { margin: 0.95em 0; overflow-x: auto; overflow-y: hidden;
                         padding: 2px 0; }
        .katex { font-size: 1.05em; }
        .sipai-math-error { color: #b31d28; font-family: ui-monospace, monospace; }
        @media print {
          #sipai-note { padding: 0; }
          .sipai-code, blockquote, table, .katex-display { break-inside: avoid; }
          h1, h2, h3, h4, h5, h6 { break-after: avoid; }
          a { color: var(--fg); }
        }
        """
    }

    /// Lays every shielded expression out with KaTeX, then reports the
    /// page ready.
    ///
    /// The LaTeX is read back with `textContent`, so what KaTeX receives
    /// is exactly what the note held — the escaping done on the Swift
    /// side is undone by the parser, not by a second pass here.
    /// `throwOnError: false` makes a broken expression render in red
    /// instead of aborting the whole page, so one bad line cannot cost
    /// the reader the rest of the note.
    ///
    /// Served as a FILE (`sipai-render.js`, staged by `KaTeXAssets`
    /// next to the document), not inlined: that is what lets the CSP
    /// omit `'unsafe-inline'` from `script-src`, so even a complete
    /// escaping failure could put markup on the page but never run a
    /// script. Only `style-src` keeps `'unsafe-inline'` — the document
    /// carries its stylesheet inline, and KaTeX styles its output with
    /// inline styles.
    static var renderScript: String {
        """
        window.__sipaiReady = (async function () {
          var nodes = document.querySelectorAll('.sipai-math');
          for (var i = 0; i < nodes.length; i++) {
            var el = nodes[i];
            var src = el.textContent;
            try {
              katex.render(src, el, {
                displayMode: el.getAttribute('data-display') === '1',
                throwOnError: false,
                strict: 'ignore'
              });
            } catch (e) {
              el.classList.add('sipai-math-error');
              el.textContent = src;
            }
          }
          if (document.fonts && document.fonts.ready) {
            try { await document.fonts.ready; } catch (e) {}
          }
          document.documentElement.setAttribute('data-sipai-ready', '1');
          var n = document.getElementById('sipai-note');
          return n ? Math.ceil(n.getBoundingClientRect().height) : 0;
        })();
        """
    }
}
