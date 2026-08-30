// MathParser.swift
// TeX source → an atom tree the layout pass can typeset.
//
// The grammar is the subset a language model actually emits: scripts,
// fractions, radicals, `\left…\right` groups, accents, over/underbraces,
// the matrix and alignment environments, `\text`, the alphabet commands
// and a symbol table. Anything outside it survives as a visible unknown
// rather than derailing the expression around it — a reply is a whole
// derivation, and one unsupported command must not cost the reader the
// other forty lines.
//
// Two rules carry most of the correctness:
//
//   * An ARGUMENT is a braced group or exactly one token. `\mathbf w`
//     and `\widetilde\varphi` are the spellings models emit far more
//     often than the braced ones, and a rule that only accepts
//     `\mathbf{w}` leaves the command on screen.
//   * Nothing is matched with a regex. Every argument here can contain
//     another one, and `[^}]+` cannot nest: it is what turns
//     `x^{\frac{1}{\sigma-1}}` into `x^\frac{1{σ-1}}` — not a degraded
//     rendering of the input but a different expression.

import CoreGraphics
import Foundation

// MARK: - Tree

/// TeX's atom classes. They decide inter-atom spacing and nothing else,
/// which is why a minus sign has to know whether it is subtraction
/// (binary) or a negation (ordinary).
enum MathClass {
    case ordinary, largeOperator, binary, relation, open, close, punctuation, inner
}

typealias MathList = [MathAtom]

struct MathAtom {
    indirect enum Kind {
        /// Characters to set as-is. Already mapped into the alphabet
        /// they belong to.
        case glyphs(String)
        /// Numerator over denominator. `bar == false` is `\binom`.
        case fraction(numerator: MathList, denominator: MathList, bar: Bool)
        case radical(index: MathList?, radicand: MathList)
        /// `\left…\right`. An empty delimiter string is `\left.`.
        case delimited(left: String, body: MathList, right: String)
        /// A combining or spacing accent centred over the base.
        case accent(String, MathList)
        /// A rule or brace above or below the base, with an optional
        /// label beyond it (`\underbrace{x}_{n}` puts `n` under the
        /// brace, not under the whole atom).
        case overUnder(OverUnder)
        case boxed(MathList)
        /// Upright prose inside mathematics. Spaces are significant.
        case text(String)
        /// Explicit spacing, in EM.
        case space(CGFloat)
        case table(MathTableNode)
        /// A brace group kept as its own unit so scripts attach to all
        /// of it.
        case list(MathList)
        /// A command this parser does not implement, drawn in the error
        /// tint with its backslash. Honest beats silently wrong.
        case unknown(String)
    }

    struct OverUnder {
        enum Ornament { case bar, brace, arrow }
        let ornament: Ornament
        let above: Bool
        let base: MathList
    }

    var kind: Kind
    var mathClass: MathClass = .ordinary
    var sub: MathList?
    var sup: MathList?
    /// Large operators only. nil takes the symbol's own default —
    /// `\sum` sets its scripts above and below in display style, `\int`
    /// keeps them at the side.
    var limits: Bool?

    init(_ kind: Kind, _ mathClass: MathClass = .ordinary) {
        self.kind = kind
        self.mathClass = mathClass
    }
}

/// A matrix, `cases`, or an alignment environment.
struct MathTableNode {
    enum Alignment { case leading, center, trailing }
    let rows: [[MathList]]
    /// Per-column alignment, cycled if there are more columns than
    /// entries. `aligned` alternates right/left, which is what puts the
    /// `=` signs of successive lines under each other.
    let alignments: [Alignment]
    let left: String?
    let right: String?
    /// Extra column gap in EM. Alignment environments set their columns
    /// tight against each other; matrices need air.
    let columnGap: CGFloat
}

// MARK: - Parser

enum MathParser {

    /// Parse `source` as one math expression. Returns nil only when the
    /// input is empty or nothing survives it — an unsupported command
    /// yields an `.unknown` atom, not a failure.
    static func parse(_ source: String) -> MathList? {
        var scanner = Scanner(Array(source))
        let list = scanner.parseList(stopAt: [])
        return list.isEmpty ? nil : list
    }

    // MARK: Scanner

    /// How deep a group may nest before braces are read as ordinary
    /// characters.
    ///
    /// `parseList` recurses per `{`, and so does the layout that walks
    /// what it builds. Real mathematics nests a handful of levels;
    /// a line of nothing but `{` recurses once per character, and a long
    /// enough one runs the stack out. A reply is untrusted input.
    private static let maxDepth = 48

    private struct Scanner {
        let chars: [Character]
        var i = 0
        /// Group nesting level. Reached only by malformed input.
        var depth = 0
        /// Alphabet in force for bare letters. Alphabet commands take an
        /// argument, so this is only pushed for the length of one.
        var alphabet: MathAlphabet = .italic

        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool { i >= chars.count }
        func peek(_ ahead: Int = 0) -> Character? {
            let j = i + ahead
            return j < chars.count ? chars[j] : nil
        }

        /// What ends the current list.
        struct Stop: OptionSet {
            let rawValue: Int
            static let closeBrace = Stop(rawValue: 1 << 0)
            static let right = Stop(rawValue: 1 << 1)
            static let cell = Stop(rawValue: 1 << 2)   // `&` and `\\`
            static let end = Stop(rawValue: 1 << 3)    // `\end{…}`
        }

        /// Why the last `parseList` returned. Read by the environment
        /// and `\left…\right` parsers, which need to know whether their
        /// terminator arrived or the input simply ran out.
        var stopReason: String = ""

        mutating func parseList(stopAt stop: Stop) -> MathList {
            var list = MathList()
            stopReason = ""
            while !atEnd {
                guard let c = peek() else { break }

                if c == "}" {
                    if stop.contains(.closeBrace) { i += 1; stopReason = "}"; return list }
                    // A stray close brace is not worth losing the rest
                    // of the expression over.
                    i += 1
                    continue
                }
                if c == "&", stop.contains(.cell) { i += 1; stopReason = "&"; return list }
                if c == "^" || c == "_" {
                    i += 1
                    let script = parseArgument()
                    attachScript(script, superscript: c == "^", to: &list)
                    continue
                }
                if c == "'" {
                    // Primes are superscripts, and repeat: `f''`.
                    var count = 0
                    while peek() == "'" { count += 1; i += 1 }
                    let mark = String(repeating: "\u{2032}", count: count)
                    attachScript([MathAtom(.glyphs(mark))], superscript: true, to: &list)
                    continue
                }
                if c == "{" {
                    i += 1
                    guard depth < MathParser.maxDepth else { continue }
                    depth += 1
                    let inner = parseList(stopAt: .closeBrace)
                    depth -= 1
                    list.append(MathAtom(.list(inner)))
                    continue
                }
                if c == "\\" {
                    let command = readCommand()
                    if command == "right", stop.contains(.right) {
                        stopReason = "right"; return list
                    }
                    if command == "end", stop.contains(.end) {
                        stopReason = "end:" + readBracedName(); return list
                    }
                    if command == "\\", stop.contains(.cell) {
                        // An optional `[2pt]` line-space argument rides
                        // on the row break; nothing here uses it.
                        skipOptionalBracket()
                        stopReason = "\\\\"; return list
                    }
                    appendCommand(command, to: &list)
                    continue
                }
                i += 1
                if let atom = atomForCharacter(c, previous: list.last) {
                    list.append(atom)
                }
            }
            return list
        }

        // MARK: Scripts

        private mutating func attachScript(_ script: MathList,
                                           superscript: Bool,
                                           to list: inout MathList) {
            // A script with no base (`^2` after a `{`-less start, or a
            // second `_` on the same atom) gets an empty one rather than
            // being dropped.
            if list.isEmpty
                || (superscript && list[list.count - 1].sup != nil)
                || (!superscript && list[list.count - 1].sub != nil) {
                list.append(MathAtom(.list([])))
            }
            if superscript { list[list.count - 1].sup = script }
            else { list[list.count - 1].sub = script }
        }

        /// A braced group, or exactly one token. This is the rule that
        /// makes `\mathbf w` and `\widetilde\varphi` work.
        private mutating func parseArgument() -> MathList {
            skipSpaces()
            guard let c = peek() else { return [] }
            if c == "{" {
                i += 1
                guard depth < MathParser.maxDepth else { return [] }
                depth += 1
                defer { depth -= 1 }
                return parseList(stopAt: .closeBrace)
            }
            if c == "\\" {
                var one = MathList()
                appendCommand(readCommand(), to: &one)
                return one
            }
            i += 1
            return atomForCharacter(c, previous: nil).map { [$0] } ?? []
        }

        // MARK: Characters

        private mutating func skipSpaces() {
            while let c = peek(), c == " " || c == "\t" || c == "\n" { i += 1 }
        }

        /// `previous` decides whether `-` and `+` are binary or a sign:
        /// TeX makes an operator ordinary when nothing precedes it or
        /// what precedes it is itself an operator, a relation or an
        /// opening delimiter.
        private func atomForCharacter(_ c: Character, previous: MathAtom?) -> MathAtom? {
            if c == " " || c == "\t" || c == "\n" { return nil }
            if c.isNumber { return MathAtom(.glyphs(String(c))) }
            if let letter = MathAlphabets.map(c, to: alphabet) {
                return MathAtom(.glyphs(letter))
            }
            switch c {
            case "+", "-", "*", "/", "\u{2212}":
                let glyph = c == "-" ? "\u{2212}" : (c == "*" ? "\u{2217}" : String(c))
                let binary = MathSpacing.startsBinaryContext(previous)
                return MathAtom(.glyphs(glyph), binary ? .binary : .ordinary)
            case "=", "<", ">":
                return MathAtom(.glyphs(String(c)), .relation)
            case "(", "[":
                return MathAtom(.glyphs(String(c)), .open)
            case ")", "]":
                return MathAtom(.glyphs(String(c)), .close)
            case ",", ";":
                return MathAtom(.glyphs(String(c)), .punctuation)
            case "|":
                return MathAtom(.glyphs("|"), .ordinary)
            case "!", "?", ".", ":", "\"":
                return MathAtom(.glyphs(String(c)))
            default:
                return MathAtom(.glyphs(String(c)))
            }
        }

        // MARK: Commands

        /// The command name after a backslash. A single non-letter is a
        /// command in its own right (`\,`, `\{`, `\\`).
        private mutating func readCommand() -> String {
            i += 1  // the backslash
            guard let first = peek() else { return "" }
            if !first.isLetter {
                i += 1
                return String(first)
            }
            var name = ""
            while let c = peek(), c.isLetter { name.append(c); i += 1 }
            return name
        }

        private mutating func readBracedName() -> String {
            skipSpaces()
            guard peek() == "{" else { return "" }
            i += 1
            var name = ""
            while let c = peek(), c != "}" { name.append(c); i += 1 }
            if peek() == "}" { i += 1 }
            return name
        }

        private mutating func skipOptionalBracket() {
            let save = i
            skipSpaces()
            guard peek() == "[" else { i = save; return }
            while let c = peek(), c != "]" { i += 1 }
            if peek() == "]" { i += 1 }
        }

        /// Raw text of a braced group, with no math parsing. `\text` and
        /// `\operatorname` need the characters, spaces included.
        private mutating func readRawArgument() -> String {
            skipSpaces()
            guard peek() == "{" else {
                // A single token, so `\text x` is not a parse failure.
                guard let c = peek() else { return "" }
                i += 1
                return String(c)
            }
            i += 1
            var depth = 1
            var out = ""
            while let c = peek() {
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth == 0 { i += 1; break }
                }
                if c == "\\", let next = peek(1) {
                    // Inside prose, `\ ` is a space and `\%` is a percent.
                    i += 2
                    out.append(next == " " ? " " : next)
                    continue
                }
                out.append(c)
                i += 1
            }
            return out
        }

        private mutating func appendCommand(_ command: String, to list: inout MathList) {
            // --- Structure ---------------------------------------------------
            switch command {
            case "frac", "dfrac", "tfrac", "cfrac":
                let num = parseArgument()
                let den = parseArgument()
                list.append(MathAtom(.fraction(numerator: num, denominator: den, bar: true)))
                return
            case "binom", "dbinom", "tbinom":
                let num = parseArgument()
                let den = parseArgument()
                let inner = MathAtom(.fraction(numerator: num, denominator: den, bar: false))
                list.append(MathAtom(.delimited(left: "(", body: [inner], right: ")"), .inner))
                return
            case "sqrt":
                // `\sqrt[3]{x}`. The index is read by its own scanner —
                // `]` is an ordinary character to `parseList`, so it
                // cannot be used as a stop token.
                let index = parseBracketArgument()
                let body = parseArgument()
                list.append(MathAtom(.radical(index: index, radicand: body)))
                return
            case "left":
                let left = readDelimiter()
                let body = parseList(stopAt: [.right, .end])
                let right = stopReason == "right" ? readDelimiter() : ""
                list.append(MathAtom(.delimited(left: left, body: body, right: right), .inner))
                return
            case "middle":
                _ = readDelimiter()
                return
            case "begin":
                let env = readBracedName()
                if let table = parseEnvironment(env) { list.append(table) }
                return
            case "boxed":
                list.append(MathAtom(.boxed(parseArgument())))
                return
            case "overline":
                list.append(MathAtom(.overUnder(.init(ornament: .bar, above: true,
                                                      base: parseArgument()))))
                return
            case "underline":
                list.append(MathAtom(.overUnder(.init(ornament: .bar, above: false,
                                                      base: parseArgument()))))
                return
            case "overbrace", "underbrace":
                // A brace's label belongs UNDER (or over) the brace, not
                // at the corner of the group — TeX makes these operators
                // that take limits, and a plain script puts
                // `\underbrace{a+b}_{\text{two}}` half a line to the
                // right of what it labels.
                var braced = MathAtom(.overUnder(.init(ornament: .brace,
                                                       above: command == "overbrace",
                                                       base: parseArgument())))
                braced.limits = true
                list.append(braced)
                return
            case "overrightarrow", "overleftarrow", "vec":
                let base = parseArgument()
                if command == "vec", base.count == 1 {
                    list.append(MathAtom(.accent("\u{20D7}", base)))
                } else {
                    list.append(MathAtom(.overUnder(.init(ornament: .arrow, above: true,
                                                          base: base))))
                }
                return
            case "text", "textrm", "textnormal", "mbox", "operatorname", "operatorname*":
                let raw = readRawArgument()
                let type: MathClass = command.hasPrefix("operatorname") ? .largeOperator : .ordinary
                var atom = MathAtom(.text(raw), type)
                if type == .largeOperator { atom.limits = false }
                list.append(atom)
                return
            case "textbf":
                list.append(MathAtom(.glyphs(MathAlphabets.mapString(readRawArgument(), to: .bold))))
                return
            case "textit":
                list.append(MathAtom(.glyphs(MathAlphabets.mapString(readRawArgument(), to: .italic))))
                return
            case "tag":
                let raw = readRawArgument()
                list.append(MathAtom(.space(1.5)))
                list.append(MathAtom(.text("(" + raw + ")")))
                return
            case "label", "nonumber", "notag", "limits", "nolimits",
                 "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle",
                 "hline", "noalign", "phantom", "ensuremath", "small", "large":
                // Accepted and ignored. `\limits` / `\nolimits` after a
                // large operator are honoured below by the operator
                // itself, so reaching here means they had no base.
                if command == "phantom" { _ = parseArgument() }
                if command == "ensuremath" { list.append(contentsOf: parseArgument()) }
                return
            case "substack":
                let body = parseArgument()
                list.append(MathAtom(.list(body)))
                return
            case "stackrel", "overset":
                let over = parseArgument()
                let base = parseArgument()
                var atom = MathAtom(.list(base), base.first?.mathClass ?? .ordinary)
                atom.sup = over
                atom.limits = true
                list.append(atom)
                return
            case "underset":
                let under = parseArgument()
                let base = parseArgument()
                var atom = MathAtom(.list(base), base.first?.mathClass ?? .ordinary)
                atom.sub = under
                atom.limits = true
                list.append(atom)
                return
            default:
                break
            }

            // --- Alphabets ---------------------------------------------------
            if let target = MathAlphabets.command(command) {
                let saved = alphabet
                alphabet = target
                let inner = parseArgument()
                alphabet = saved
                list.append(MathAtom(.list(inner)))
                return
            }

            // --- Accents -----------------------------------------------------
            if let accent = MathSymbols.accents[command] {
                list.append(MathAtom(.accent(accent, parseArgument())))
                return
            }

            // --- Spacing -----------------------------------------------------
            if let width = MathSymbols.spaces[command] {
                list.append(MathAtom(.space(width)))
                return
            }

            // --- Delimiter sizing --------------------------------------------
            // `\big(` and friends take no argument: the delimiter that
            // follows is what they size. Dropping the word and keeping
            // the delimiter is honest at every size this renders at.
            if MathSymbols.sizingCommands.contains(command) {
                return
            }

            // --- Named operators ---------------------------------------------
            if let named = MathSymbols.namedOperators[command] {
                var atom = MathAtom(.text(named.name), .largeOperator)
                atom.limits = named.limits
                // An explicit `\limits` / `\nolimits` overrides the
                // symbol's default.
                atom.limits = readLimitsOverride() ?? atom.limits
                list.append(atom)
                return
            }

            // --- Symbols ------------------------------------------------------
            if let symbol = MathSymbols.table[command] {
                var atom = MathAtom(.glyphs(symbol.glyph), symbol.mathClass)
                if symbol.mathClass == .binary,
                   MathSpacing.startsBinaryContext(list.last) == false {
                    atom.mathClass = .ordinary
                }
                if symbol.mathClass == .largeOperator {
                    atom.limits = readLimitsOverride() ?? symbol.limits
                }
                list.append(atom)
                return
            }

            list.append(MathAtom(.unknown("\\" + command)))
        }

        /// `\limits` or `\nolimits` directly after a large operator.
        private mutating func readLimitsOverride() -> Bool? {
            let save = i
            skipSpaces()
            guard peek() == "\\" else { i = save; return nil }
            let probe = i
            let command = readCommand()
            if command == "limits" { return true }
            if command == "nolimits" { return false }
            i = probe
            return nil
        }

        /// A `[...]` argument, parsed as mathematics. Used by `\sqrt`.
        private mutating func parseBracketArgument() -> MathList? {
            skipSpaces()
            guard peek() == "[" else { return nil }
            i += 1
            var depth = 1
            var inner: [Character] = []
            while let c = peek() {
                if c == "[" { depth += 1 }
                if c == "]" {
                    depth -= 1
                    if depth == 0 { i += 1; break }
                }
                inner.append(c)
                i += 1
            }
            var sub = Scanner(inner)
            sub.alphabet = alphabet
            let list = sub.parseList(stopAt: [])
            return list.isEmpty ? nil : list
        }

        /// The delimiter after `\left` / `\right`. `.` means "none".
        private mutating func readDelimiter() -> String {
            skipSpaces()
            guard let c = peek() else { return "" }
            if c == "\\" {
                let command = readCommand()
                if command == "." { return "" }
                if let symbol = MathSymbols.table[command] { return symbol.glyph }
                if command == "\\" { return "\\" }
                return ""
            }
            i += 1
            if c == "." { return "" }
            return String(c)
        }

        // MARK: Environments

        private mutating func parseEnvironment(_ env: String) -> MathAtom? {
            let base = env.hasSuffix("*") ? String(env.dropLast()) : env
            // `array` and `tabular` lead with a column spec.
            var explicitAlignments: [MathTableNode.Alignment]? = nil
            if base == "array" || base == "tabular" {
                let spec = readBracedName()
                let parsed = spec.compactMap { ch -> MathTableNode.Alignment? in
                    switch ch {
                    case "l": return .leading
                    case "c": return .center
                    case "r": return .trailing
                    default: return nil
                    }
                }
                if !parsed.isEmpty { explicitAlignments = parsed }
            }

            var rows: [[MathList]] = []
            var row: [MathList] = []
            var finished = false
            while !atEnd && !finished {
                let cell = parseList(stopAt: [.cell, .end])
                row.append(cell)
                switch stopReason {
                case "&":
                    continue
                case "\\\\":
                    rows.append(row); row = []
                default:
                    // `\end{…}`, or the input ran out.
                    rows.append(row); row = []
                    finished = true
                }
            }
            // A trailing `\\` before `\end` leaves a row of empty cells.
            if let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
            guard !rows.isEmpty else { return nil }

            let style = MathEnvironments.style(for: base)
            if style.alternating {
                // `x &= y` has to set as `x = y`, spacing and all. The
                // `&` splits the list, so the `=` opens its cell and a
                // relation with nothing before it gets no space — which
                // is why amsmath's own template puts an empty group
                // there. This is that empty group.
                rows = rows.map { row in
                    row.enumerated().map { index, cell in
                        index > 0 && !cell.isEmpty ? [MathAtom(.list([]))] + cell : cell
                    }
                }
            }
            let columns = rows.map(\.count).max() ?? 1
            let alignments = explicitAlignments ?? style.alignments(columns: columns)
            let table = MathTableNode(rows: rows,
                                      alignments: alignments,
                                      left: style.left,
                                      right: style.right,
                                      columnGap: style.columnGap)
            return MathAtom(.table(table), style.left == nil ? .ordinary : .inner)
        }
    }
}

// MARK: - Environments

enum MathEnvironments {
    struct Style {
        let left: String?
        let right: String?
        let columnGap: CGFloat
        let alternating: Bool
        let allCentered: Bool

        func alignments(columns: Int) -> [MathTableNode.Alignment] {
            if allCentered { return Array(repeating: .center, count: max(columns, 1)) }
            if alternating {
                // Right, left, right, left… — what puts the relation
                // signs of successive lines under one another.
                return (0..<max(columns, 1)).map { $0 % 2 == 0 ? .trailing : .leading }
            }
            return Array(repeating: .leading, count: max(columns, 1))
        }
    }

    static func style(for env: String) -> Style {
        switch env {
        case "pmatrix": return Style(left: "(", right: ")", columnGap: 0.7, alternating: false, allCentered: true)
        case "bmatrix": return Style(left: "[", right: "]", columnGap: 0.7, alternating: false, allCentered: true)
        case "Bmatrix": return Style(left: "{", right: "}", columnGap: 0.7, alternating: false, allCentered: true)
        case "vmatrix": return Style(left: "|", right: "|", columnGap: 0.7, alternating: false, allCentered: true)
        case "Vmatrix": return Style(left: "\u{2016}", right: "\u{2016}", columnGap: 0.7, alternating: false, allCentered: true)
        case "matrix", "smallmatrix", "array", "tabular":
            return Style(left: nil, right: nil, columnGap: 0.7, alternating: false, allCentered: true)
        case "cases", "dcases":
            // Left-aligned under a single growing brace: the shape of a
            // piecewise definition.
            return Style(left: "{", right: nil, columnGap: 1.0, alternating: false, allCentered: false)
        case "aligned", "align", "alignat", "split", "eqnarray":
            return Style(left: nil, right: nil, columnGap: 0, alternating: true, allCentered: false)
        default:
            // `gathered`, `gather`, `equation`, and anything unmodelled:
            // one centred column is the least surprising fallback.
            return Style(left: nil, right: nil, columnGap: 0.7, alternating: false, allCentered: true)
        }
    }
}

// MARK: - Spacing rules

enum MathSpacing {
    /// TeX's inter-atom spacing, in EM. `nil` where the pair cannot
    /// occur. The values that only apply outside script styles are
    /// filtered by `between(_:_:script:)`.
    private static let thin: CGFloat = 3.0 / 18
    private static let medium: CGFloat = 4.0 / 18
    private static let thick: CGFloat = 5.0 / 18

    /// Space between two adjacent atoms. `script` suppresses the pairs
    /// TeX marks as text-style-only, which is why a subscript reads
    /// tighter than the same expression on the baseline.
    static func between(_ left: MathClass, _ right: MathClass, script: Bool) -> CGFloat {
        switch (left, right) {
        case (.ordinary, .largeOperator), (.largeOperator, .ordinary),
             (.largeOperator, .largeOperator), (.close, .largeOperator):
            return thin
        case (.ordinary, .binary), (.binary, .ordinary),
             (.binary, .open), (.close, .binary),
             (.binary, .largeOperator), (.largeOperator, .binary),
             (.binary, .inner), (.inner, .binary):
            return script ? 0 : medium
        case (.ordinary, .relation), (.relation, .ordinary),
             (.relation, .open), (.close, .relation),
             (.relation, .largeOperator), (.largeOperator, .relation),
             (.relation, .inner), (.inner, .relation):
            return script ? 0 : thick
        case (.punctuation, _):
            return script ? 0 : thin
        case (.ordinary, .inner), (.inner, .ordinary),
             (.inner, .open), (.close, .inner),
             (.inner, .inner), (.largeOperator, .inner),
             (.inner, .largeOperator), (.close, .ordinary),
             (.inner, .punctuation):
            return script ? 0 : thin
        default:
            return 0
        }
    }

    /// Whether a `+`/`-` following `previous` is a binary operator.
    /// Nothing, an operator, a relation, an opening delimiter or a
    /// punctuation mark all make the next sign a unary one.
    static func startsBinaryContext(_ previous: MathAtom?) -> Bool {
        guard let previous else { return false }
        switch previous.mathClass {
        case .ordinary, .close, .inner: return true
        case .binary, .relation, .open, .punctuation, .largeOperator: return false
        }
    }
}
