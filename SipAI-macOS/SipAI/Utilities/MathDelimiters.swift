// MathDelimiters.swift
// Where a display equation starts and stops.
//
// One rule, two readers: the note pipeline (`NoteHTML`, which lifts each
// equation out before the markdown parse and hands it to KaTeX) and the
// chat/agent renderer (`MarkdownRenderer`, which turns it into a
// `.displayMath` block for the native typesetter). A second spelling of
// this is how one marker comes to be filed two ways, so both callers
// come here.

import Foundation

enum MathDelimiters {

    /// Environments that stand on their own as display math when they
    /// appear at the top level, i.e. not already wrapped in `$$`. Models
    /// emit these bare constantly.
    static let displayEnvironments: Set<String> = [
        "equation", "equation*", "align", "align*", "aligned",
        "gather", "gather*", "gathered", "alignat", "alignat*",
        "multline", "multline*", "split", "array",
        "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix",
        "smallmatrix", "cases", "dcases", "subarray",
    ]

    /// A display-math run starting at `index`, plus the line to resume
    /// from. Handles `$$…$$`, `\[…\]` and a bare `\begin{env}…\end{env}`,
    /// each of which may be one line or many.
    ///
    /// An UNTERMINATED opener is not math. Treating it as math would let
    /// a stray `$$` in someone's writing swallow everything after it.
    static func displayMath(_ lines: [String],
                            from index: Int) -> (latex: String, next: Int)? {
        guard lines.indices.contains(index) else { return nil }
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
}
