// LatexSymbols.swift
// LaTeX → Unicode approximation for INLINE mathematics in chat and
// agent transcripts.
//
// Display equations do NOT come through here: they are a
// `MarkdownRenderer.Block` of their own and are typeset by
// `MathTypesetter`, which draws real fraction bars and stacked limits.
// What is left for this file is `\(…\)` and `$…$` inside a sentence —
// a symbol, a subscript, the odd quotient — where the value of staying
// TEXT is that the paragraph remains one selectable, searchable run.
// Notes bypass this entirely and go to KaTeX.
//
// It is a SCANNER, not a set of regexes, and that is the whole point.
// Every argument here can contain another one, and `[^}]+` cannot nest:
// matching `^{…}` up to the first `}` is what turned
// `x^{\frac{1}{\sigma-1}}` into `x^\frac{1{σ-1}}` — not a degraded
// rendering of the input but a different expression, stated with the
// same confidence as a correct one.
//
// An ARGUMENT is a braced group or exactly one token, because
// `\mathbf w` and `\widetilde\varphi` are spellings models emit at
// least as often as the braced ones.

import Foundation

enum LatexSymbols {

    /// Run every transformation: strip the math delimiters, then walk
    /// the source substituting symbols, scripts, fractions, roots,
    /// accents and the presentation-only commands.
    static func translate(_ input: String) -> String {
        var scanner = Scanner(Array(stripDelimiters(input)))
        return scanner.run()
    }

    /// How deep an argument may nest before the source is shown as-is.
    ///
    /// Every argument is translated by a fresh scanner over its own
    /// text, so an UNTERMINATED group takes the whole remainder as its
    /// argument and hands it down one level. A line of nothing but
    /// `^{^{^{…` therefore recurses once per opener over a string that
    /// barely shrinks: quadratic work on the main thread, and a stack
    /// that a long enough line runs out of. Real mathematics does not
    /// approach this; garbage and hostile input do, and both arrive from
    /// the same place a reply does.
    private static let maxDepth = 48

    // MARK: - Delimiters

    /// Remove `\[…\]`, `\(…\)`, `$…$` and `$$…$$`, keeping the content.
    ///
    /// This runs before the scanner so `\(` is never read as a command
    /// named `(`.
    private static func stripDelimiters(_ input: String) -> String {
        var t = input
        t = strip(t, open: #"\\\["#, close: #"\\\]"#, dotAll: true)
        t = strip(t, open: #"\\\("#, close: #"\\\)"#, dotAll: false)
        t = regexReplace(t,
                         pattern: #"(?<!\$)\$(?!\$)(.+?)(?<!\$)\$(?!\$)"#,
                         dotAll: false) { $0 }
        t = regexReplace(t, pattern: #"\$\$(.+?)\$\$"#, dotAll: true) { $0 }
        return t
    }

    private static func strip(_ input: String,
                              open: String,
                              close: String,
                              dotAll: Bool) -> String {
        regexReplace(input, pattern: "\(open)(.+?)\(close)", dotAll: dotAll) { $0 }
    }

    /// Regex replacement over the first capture group. nil from the
    /// callback leaves the original match in place.
    private static func regexReplace(_ input: String,
                                     pattern: String,
                                     dotAll: Bool = false,
                                     _ transform: (String) -> String?) -> String {
        var options: NSRegularExpression.Options = []
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
            return input
        }
        let ns = input as NSString
        var result = ""
        var cursor = 0
        for m in re.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            let whole = m.range
            if whole.location > cursor {
                result += ns.substring(with: NSRange(location: cursor,
                                                    length: whole.location - cursor))
            }
            let groupIndex = m.numberOfRanges > 1 ? 1 : 0
            let groupRange = m.range(at: groupIndex)
            let groupText = groupRange.location == NSNotFound
                ? ""
                : ns.substring(with: groupRange)
            result += transform(groupText) ?? ns.substring(with: whole)
            cursor = whole.location + whole.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor,
                                                 length: ns.length - cursor))
        }
        return result
    }

    // MARK: - Scanner

    private struct Scanner {
        let chars: [Character]
        var i = 0
        var out = ""
        /// Nesting level of the argument this scanner is translating.
        let depth: Int

        init(_ chars: [Character], depth: Int = 0) {
            self.chars = chars
            self.depth = depth
        }

        private func peek(_ ahead: Int = 0) -> Character? {
            let j = i + ahead
            return j >= 0 && j < chars.count ? chars[j] : nil
        }

        mutating func run() -> String {
            while i < chars.count {
                switch chars[i] {
                case "\\": command()
                case "^": script(superscript: true)
                case "_": script(superscript: false)
                default:
                    out.append(chars[i])
                    i += 1
                }
            }
            return out
        }

        // MARK: Arguments

        /// A braced group or exactly one token, as SOURCE. The caller
        /// decides whether to translate it or to read its characters.
        private mutating func rawArgument() -> String {
            while let c = peek(), c == " " { i += 1 }
            guard let c = peek() else { return "" }
            if c == "{" {
                i += 1
                var braces = 1
                var inner = ""
                while let c = peek() {
                    if c == "{" { braces += 1 }
                    if c == "}" {
                        braces -= 1
                        if braces == 0 { i += 1; break }
                    }
                    inner.append(c)
                    i += 1
                }
                return inner
            }
            if c == "\\" {
                var token = "\\"
                i += 1
                if let first = peek(), !first.isLetter {
                    token.append(first)
                    i += 1
                    return token
                }
                while let c = peek(), c.isLetter { token.append(c); i += 1 }
                return token
            }
            i += 1
            return String(c)
        }

        /// A `[…]` argument, or nil. `\sqrt[3]{x}`.
        private mutating func rawBracketArgument() -> String? {
            let save = i
            while let c = peek(), c == " " { i += 1 }
            guard peek() == "[" else { i = save; return nil }
            i += 1
            var brackets = 1
            var inner = ""
            while let c = peek() {
                if c == "[" { brackets += 1 }
                if c == "]" {
                    brackets -= 1
                    if brackets == 0 { i += 1; break }
                }
                inner.append(c)
                i += 1
            }
            return inner
        }

        private mutating func translatedArgument() -> String {
            LatexSymbols.translateFragment(rawArgument(), depth: depth + 1)
        }

        // MARK: Scripts

        /// `^{…}` / `_{…}`, and the bare one-character forms.
        ///
        /// A braced script converts WHOLLY or not at all: there is no
        /// subscript `m`, so mapping character by character renders
        /// `x_{max}` as `xmₐₓ` — the unmapped letters run into the base
        /// and the result reads as a different expression rather than an
        /// unsupported one. The flat `x_max` is the honest fallback.
        private mutating func script(superscript: Bool) {
            let marker: Character = superscript ? "^" : "_"
            let map = superscript ? LatexSymbols.superscript : LatexSymbols.subscriptMap

            // Bare form: one character, and only where it cannot be
            // prose. Unguarded, ordinary snake_case is mangled —
            // tool_use → toolᵤse, old_string → oldₛtring.
            if let next = peek(1), next != "{" {
                let allowed = superscript
                    ? "0123456789n+-".contains(next)
                    : (LatexSymbols.bareSubscriptable.contains(next)
                        && subscriptContextIsMath())
                if allowed, let mapped = map[next] {
                    out.append(mapped)
                    i += 2
                    return
                }
                out.append(marker)
                i += 1
                return
            }

            i += 1  // the marker
            let raw = rawArgument()
            if let whole = LatexSymbols.mappedWholly(raw, using: map) {
                out.append(whole)
            } else {
                // The argument is translated on the way out, so a
                // fraction or a symbol inside an unmappable script still
                // reads — `^{\frac{1}{\sigma-1}}` becomes `^(1)/(σ-1)`,
                // not `^\frac{1{σ-1}}`.
                out.append(marker)
                out += LatexSymbols.translateFragment(raw, depth: depth + 1)
            }
        }

        /// Whether a bare `_x` is mathematics rather than an identifier:
        /// the character before the underscore must be a standalone
        /// letter, and the subscript must not continue as a word.
        private func subscriptContextIsMath() -> Bool {
            guard let previous = peek(-1), previous.isLetter else { return false }
            if let beforeThat = peek(-2), beforeThat.isLetter || beforeThat.isNumber {
                return false
            }
            if let after = peek(2), after.isLowercase, after.isLetter { return false }
            return true
        }

        // MARK: Commands

        private mutating func command() {
            i += 1  // the backslash
            guard let first = peek() else { out.append("\\"); return }

            if !first.isLetter {
                i += 1
                if let literal = LatexSymbols.singleCharacterCommands[first] {
                    out += literal
                    return
                }
                out.append("\\")
                out.append(first)
                return
            }

            var name = ""
            while let c = peek(), c.isLetter { name.append(c); i += 1 }
            emit(command: name)
        }

        private mutating func emit(command name: String) {
            // Wrapping commands lose their BRACES with the word: drop
            // the word alone and `\mathbf{v}` shows as `{v}`, which
            // reads as a set rather than a vector.
            if LatexSymbols.transparentCommands.contains(name) {
                out += translatedArgument()
                return
            }
            if let alphabet = LatexSymbols.alphabetCommands[name] {
                out += MathAlphabets.mapString(translatedArgument(), to: alphabet)
                return
            }
            if let mark = LatexSymbols.accentMarks[name] {
                // A combining mark attaches to the character BEFORE it,
                // so it follows the argument rather than preceding it.
                out += translatedArgument() + mark
                return
            }
            if let spacing = LatexSymbols.spacingCommands[name] {
                out += spacing
                return
            }

            switch name {
            case "frac", "dfrac", "tfrac", "cfrac":
                let numerator = translatedArgument()
                let denominator = translatedArgument()
                out += "(\(numerator))/(\(denominator))"
                return
            case "binom", "dbinom", "tbinom":
                let n = translatedArgument()
                let k = translatedArgument()
                out += "C(\(n), \(k))"
                return
            case "sqrt":
                let index = rawBracketArgument()
                let body = translatedArgument()
                if let index,
                   let raised = LatexSymbols.mappedWholly(index,
                                                          using: LatexSymbols.superscript) {
                    out += raised
                }
                out += "√(\(body))"
                return
            case "left", "right":
                // These take no argument — the delimiter that follows is
                // what they size, so the word alone goes. `\left.` and
                // `\right.` name NO delimiter, and the dot has to go
                // with the word or it lands on screen as a full stop.
                if peek() == "." { i += 1 }
                return
            case "begin", "end":
                _ = rawArgument()
                return
            case "tag":
                out += " (" + translatedArgument() + ")"
                return
            case "label":
                _ = rawArgument()
                return
            case "operatorname", "text", "mathrm":
                // Handled by `transparentCommands`; listed here so a
                // later edit that removes one from that set fails loudly
                // rather than silently printing the command.
                out += translatedArgument()
                return
            default:
                break
            }

            if LatexSymbols.droppedCommands.contains(name) { return }
            if let glyph = LatexSymbols.substitutions[name] {
                out += glyph
                return
            }
            // Unknown: the source is what it is. Printing it is honest;
            // guessing at it is not.
            out += "\\" + name
        }
    }

    /// Translate a fragment with the delimiters already gone.
    private static func translateFragment(_ source: String, depth: Int) -> String {
        guard !source.isEmpty else { return "" }
        guard depth < maxDepth else { return source }
        var scanner = Scanner(Array(source), depth: depth)
        return scanner.run()
    }

    // MARK: - Command tables

    /// Presentation-only wrappers: the argument survives, the command
    /// does not.
    private static let transparentCommands: Set<String> = [
        "text", "textrm", "textnormal", "textup", "mathrm", "mathnormal",
        "mbox", "operatorname", "ensuremath", "boxed", "substack",
        "phantom", "textbf", "textit", "mathit", "boldsymbol", "bm",
        "mathbf", "mathsf", "mathtt", "displaystyle", "textstyle",
        "scriptstyle", "scriptscriptstyle",
    ]

    /// Alphabet commands whose Unicode forms are legible in prose.
    /// `\mathbf` is deliberately NOT here: the bold Latin block is
    /// outside the BMP and falls back to a serif face, which puts one
    /// serif letter in the middle of a sans-serif sentence. Display
    /// equations, which are set in a math font throughout, get the real
    /// alphabet from `MathParser`.
    private static let alphabetCommands: [String: MathAlphabet] = [
        "mathbb": .blackboard, "Bbb": .blackboard,
        "mathcal": .script, "mathscr": .script,
        "mathfrak": .fraktur,
    ]

    /// Accents, as the COMBINING mark that follows the base character.
    private static let accentMarks: [String: String] = [
        "hat": "\u{0302}", "widehat": "\u{0302}",
        "tilde": "\u{0303}", "widetilde": "\u{0303}",
        "bar": "\u{0304}", "overline": "\u{0304}",
        "dot": "\u{0307}", "ddot": "\u{0308}",
        "check": "\u{030C}", "breve": "\u{0306}",
        "acute": "\u{0301}", "grave": "\u{0300}",
        "mathring": "\u{030A}", "vec": "\u{20D7}",
        "underline": "\u{0332}",
    ]

    /// Explicit spacing. `\!` is negative in TeX and has no text
    /// equivalent, so it contributes nothing rather than a space that
    /// would widen what it was written to tighten.
    private static let spacingCommands: [String: String] = [
        "quad": "  ", "qquad": "    ",
        "thinspace": " ", "medspace": " ", "thickspace": " ",
        "enspace": " ", "negthinspace": "", "hspace": " ",
    ]

    /// A backslash followed by one non-letter.
    private static let singleCharacterCommands: [Character: String] = [
        ",": " ", ";": " ", ":": " ", "!": "", " ": " ",
        "%": "%", "$": "$", "#": "#", "&": "&", "_": "_",
        "{": "{", "}": "}", "\\": "\n", "|": "\u{2016}",
    ]

    /// Commands that contribute nothing to a text rendering: delimiter
    /// sizing (the delimiter itself stays), alignment bookkeeping, and
    /// numbering directives.
    private static let droppedCommands: Set<String> = [
        "big", "Big", "bigg", "Bigg",
        "bigl", "Bigl", "biggl", "Biggl",
        "bigr", "Bigr", "biggr", "Biggr",
        "bigm", "Bigm", "biggm", "Biggm",
        "limits", "nolimits", "nonumber", "notag", "hline", "noalign",
        "small", "large", "Large", "huge", "nobreak", "allowbreak",
    ]

    /// Characters a bare `_x` may lift, i.e. exactly those the subscript
    /// map covers.
    private static let bareSubscriptable = "0123456789aeioujkrstx"

    /// Superscript character map.
    fileprivate static let superscript: [Character: Character] = {
        let from = Array("0123456789+-=()ni")
        let to = Array("⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱ")
        return Dictionary(uniqueKeysWithValues: zip(from, to))
    }()

    /// Subscript character map.
    fileprivate static let subscriptMap: [Character: Character] = {
        let from = Array("0123456789+-=()aeioujkrstx")
        let to = Array("₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑᵢₒᵤⱼₖᵣₛₜₓ")
        return Dictionary(uniqueKeysWithValues: zip(from, to))
    }()

    /// Map EVERY character, or none of them. nil means "leave this
    /// legible instead", and the caller falls back to the flat spelling.
    fileprivate static func mappedWholly(_ s: String,
                                         using map: [Character: Character]) -> String? {
        guard !s.isEmpty else { return nil }
        var out = String()
        out.reserveCapacity(s.count)
        for ch in s {
            guard let mapped = map[ch] else { return nil }
            out.append(mapped)
        }
        return out
    }

    // MARK: - Symbol table

    /// Command name (no backslash) → character. Keyed rather than
    /// substring-matched: the scanner reads a whole command name before
    /// looking here, so a shorter name can no longer fire inside a
    /// longer one and there is no ordering to get wrong.
    private static let substitutions: [String: String] = [
        // Greek, lowercase. `\epsilon` is the LUNATE one and `\phi` the
        // straight one — LaTeX names them the opposite way round from
        // what the spellings suggest.
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "varkappa": "ϰ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "omicron": "ο", "pi": "π", "varpi": "ϖ", "rho": "ρ",
        "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ",
        "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ",
        "psi": "ψ", "omega": "ω",
        // Greek, uppercase.
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Letterlike.
        "ell": "ℓ", "hbar": "ℏ", "hslash": "ℏ", "wp": "℘",
        "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "beth": "ℶ",
        "imath": "ı", "jmath": "ȷ", "prime": "′", "degree": "°",
        // Operators and relations.
        "infty": "∞", "sum": "∑", "prod": "∏", "coprod": "∐",
        "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "partial": "∂", "nabla": "∇", "times": "×", "div": "÷",
        "cdot": "·", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆",
        "circ": "∘", "bullet": "∙", "leq": "≤", "le": "≤",
        "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈",
        "equiv": "≡", "cong": "≅", "simeq": "≃", "sim": "∼",
        "propto": "∝", "ll": "≪", "gg": "≫", "prec": "≺", "succ": "≻",
        "neg": "¬", "lnot": "¬", "wedge": "∧", "vee": "∨",
        "oplus": "⊕", "ominus": "⊖", "otimes": "⊗", "odot": "⊙",
        "oslash": "⊘", "perp": "⊥", "parallel": "∥", "mid": "∣",
        "nmid": "∤", "models": "⊨", "vdash": "⊢", "dashv": "⊣",
        "angle": "∠", "therefore": "∴", "because": "∵",
        "bigcup": "⋃", "bigcap": "⋂", "bigoplus": "⨁", "bigotimes": "⨂",
        "bigvee": "⋁", "bigwedge": "⋀", "bigsqcup": "⨆",
        "sqcup": "⊔", "sqcap": "⊓", "uplus": "⊎", "amalg": "⨿",
        "setminus": "∖", "backslash": "∖", "diamond": "⋄",
        "triangleleft": "◁", "triangleright": "▷", "triangle": "△",
        "square": "□", "dagger": "†", "ddagger": "‡",
        "leqslant": "⩽", "geqslant": "⩾", "asymp": "≍", "doteq": "≐",
        "triangleq": "≜", "coloneqq": "≔",
        // Arrows.
        "rightarrow": "→", "to": "→", "leftarrow": "←", "gets": "←",
        "leftrightarrow": "↔", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "Leftrightarrow": "⇔", "iff": "⟺", "implies": "⟹",
        "impliedby": "⟸", "longrightarrow": "⟶", "longleftarrow": "⟵",
        "longleftrightarrow": "⟷", "Longrightarrow": "⟹",
        "Longleftarrow": "⟸", "Longleftrightarrow": "⟺",
        "mapsto": "↦", "longmapsto": "⟼", "hookrightarrow": "↪",
        "hookleftarrow": "↩", "uparrow": "↑", "downarrow": "↓",
        "updownarrow": "↕", "Uparrow": "⇑", "Downarrow": "⇓",
        "nearrow": "↗", "searrow": "↘", "swarrow": "↙", "nwarrow": "↖",
        "rightharpoonup": "⇀", "rightleftharpoons": "⇌",
        "xrightarrow": "⟶", "xleftarrow": "⟵",
        // Set theory.
        "forall": "∀", "exists": "∃", "nexists": "∄", "in": "∈",
        "notin": "∉", "ni": "∋", "subset": "⊂", "supset": "⊃",
        "subseteq": "⊆", "supseteq": "⊇", "subsetneq": "⊊",
        "supsetneq": "⊋", "cup": "∪", "cap": "∩", "emptyset": "∅",
        "varnothing": "∅", "top": "⊤", "bot": "⊥",
        // Named operators, set as words.
        "sin": "sin", "cos": "cos", "tan": "tan", "cot": "cot",
        "sec": "sec", "csc": "csc", "arcsin": "arcsin",
        "arccos": "arccos", "arctan": "arctan", "sinh": "sinh",
        "cosh": "cosh", "tanh": "tanh", "coth": "coth", "exp": "exp",
        "ln": "ln", "log": "log", "lg": "lg", "arg": "arg",
        "deg": "deg", "dim": "dim", "hom": "hom", "ker": "ker",
        "lim": "lim", "limsup": "lim sup", "liminf": "lim inf",
        "max": "max", "min": "min", "sup": "sup", "inf": "inf",
        "det": "det", "gcd": "gcd", "Pr": "Pr", "bmod": "mod",
        "mod": "mod", "pmod": "mod",
        // Brackets and punctuation.
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋",
        "lceil": "⌈", "rceil": "⌉", "lbrace": "{", "rbrace": "}",
        "lbrack": "[", "rbrack": "]", "lvert": "|", "rvert": "|",
        "lVert": "‖", "rVert": "‖",
        "dots": "…", "ldots": "…", "cdots": "⋯", "vdots": "⋮",
        "ddots": "⋱", "checkmark": "✓", "flat": "♭", "sharp": "♯",
    ]
}
