// LatexSymbols.swift
// LaTeX symbol translation: a substitution table, `\mathbb`,
// superscripts and subscripts (all-or-nothing — see `mappedWholly`),
// `\frac{a}{b}` → `(a)/(b)`, the
// `\[…\]` / `\(…\)` / `$…$` / `$$…$$` strippers, and the
// `\text`/`\mathrm`/`\mathbf`/`\left`/`\right`/`\big`/`\Big` removers.
// Called from `MarkdownRenderer` on non-code text so that `\pi`, `\sqrt`,
// `x^2`, `H_2O`, and friends show up as real Unicode symbols.

import Foundation

enum LatexSymbols {

    /// Literal-substring LaTeX → Unicode map. Matched as raw
    /// substrings, not regex — several keys ARE prefixes of longer keys (`\subset` /
    /// `\subseteq`, `\cdot` / `\cdots`, `\in` / `\int`), so matching
    /// goes through `orderedSubstitutions` below, never this table
    /// directly. Declaration order here is purely for readability.
    private static let substitutions: [(String, String)] = [
        // Greek lowercase
        ("\\pi", "π"), ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"),
        ("\\delta", "δ"), ("\\theta", "θ"), ("\\lambda", "λ"), ("\\sigma", "σ"),
        ("\\phi", "φ"), ("\\omega", "ω"), ("\\epsilon", "ε"), ("\\varepsilon", "ε"),
        ("\\mu", "μ"), ("\\nu", "ν"), ("\\rho", "ρ"), ("\\tau", "τ"),
        ("\\chi", "χ"), ("\\psi", "ψ"), ("\\eta", "η"), ("\\kappa", "κ"),
        ("\\zeta", "ζ"), ("\\iota", "ι"), ("\\xi", "ξ"),
        // Greek uppercase
        ("\\Gamma", "Γ"), ("\\Delta", "Δ"), ("\\Theta", "Θ"), ("\\Lambda", "Λ"),
        ("\\Xi", "Ξ"), ("\\Pi", "Π"), ("\\Phi", "Φ"), ("\\Psi", "Ψ"),
        ("\\Omega", "Ω"), ("\\Sigma", "Σ"),
        // Operators and relations
        ("\\infty", "∞"), ("\\sum", "Σ"), ("\\int", "∫"), ("\\partial", "∂"),
        ("\\times", "×"), ("\\cdot", "·"), ("\\pm", "±"), ("\\leq", "≤"),
        ("\\geq", "≥"), ("\\neq", "≠"), ("\\approx", "≈"), ("\\nabla", "∇"),
        ("\\propto", "∝"), ("\\equiv", "≡"), ("\\sim", "∼"), ("\\neg", "¬"),
        ("\\wedge", "∧"), ("\\vee", "∨"), ("\\implies", "⟹"), ("\\iff", "⟺"),
        ("\\prod", "∏"), ("\\cong", "≅"), ("\\perp", "⊥"), ("\\parallel", "∥"),
        ("\\angle", "∠"), ("\\therefore", "∴"), ("\\because", "∵"),
        ("\\oplus", "⊕"), ("\\otimes", "⊗"),
        // Arrows
        ("\\rightarrow", "→"), ("\\leftarrow", "←"), ("\\leftrightarrow", "↔"),
        ("\\Rightarrow", "⇒"), ("\\Leftarrow", "⇐"),
        // Set theory
        ("\\forall", "∀"), ("\\exists", "∃"), ("\\in", "∈"), ("\\notin", "∉"),
        ("\\subset", "⊂"), ("\\supset", "⊃"), ("\\subseteq", "⊆"),
        ("\\supseteq", "⊇"), ("\\cup", "∪"), ("\\cap", "∩"), ("\\emptyset", "∅"),
        // Brackets and misc
        ("\\langle", "⟨"), ("\\rangle", "⟩"), ("\\sqrt", "√"),
        ("\\dots", "…"), ("\\cdots", "⋯"),
    ]

    /// `substitutions` sorted longest-key-first at use, so a shorter
    /// command can never shadow a longer one it prefixes (`\subset`
    /// firing inside `\subseteq` would leave "⊂eq"). Sorting here
    /// rather than hand-ordering the table means future additions
    /// can't regress the ordering.
    private static let orderedSubstitutions: [(String, String)] =
        substitutions.sorted { $0.0.count > $1.0.count }

    /// `\mathbb{X}` → ℝ/ℕ/ℤ/ℚ/ℂ.
    private static let mathbb: [Character: Character] = [
        "R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ",
    ]

    /// Superscript character map.
    private static let superscript: [Character: Character] = {
        let from = Array("0123456789+-=()ni")
        let to = Array("⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱ")
        return Dictionary(uniqueKeysWithValues: zip(from, to))
    }()

    /// Subscript character map.
    private static let `subscript`: [Character: Character] = {
        let from = Array("0123456789+-=()aeioujkrstx")
        let to = Array("₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑᵢₒᵤⱼₖᵣₛₜₓ")
        return Dictionary(uniqueKeysWithValues: zip(from, to))
    }()

    /// Run every transformation — symbol substitution, superscripts,
    /// subscripts, `\frac`, math-delimiter stripping — in order.
    static func translate(_ input: String) -> String {
        var t = input

        // 1. Literal substrings from the LATEX dict, longest key first.
        for (from, to) in orderedSubstitutions {
            t = t.replacingOccurrences(of: from, with: to)
        }

        // 2. \mathbb{X} — the closure receives the capture group (the
        //    bare letter).
        t = regexReplace(t, pattern: #"\\mathbb\{([A-Z])\}"#) { match in
            guard let first = match.first,
                  let mapped = mathbb[first] else { return nil }
            return String(mapped)
        }

        // 3. Superscripts: ^x, then ^{…}
        //
        //    The BARE form runs FIRST, and the order is load-bearing.
        //    It cannot reach inside a braced group — `{` is not in its
        //    character class — but it CAN reach the fallback spelling
        //    the braced rule emits when a group is unmappable. Run the
        //    other way round, `e^{-x^2}` falls back to `e^-x^2` and the
        //    bare rule then lifts the `-` and the `2` independently,
        //    producing `e⁻x²`: the exact confident-but-wrong rendering
        //    the fallback exists to avoid.
        t = regexReplace(t, pattern: #"\^([0-9n+\-])"#) { match in
            translate(match, using: superscript)
        }
        t = regexReplace(t, pattern: #"\^\{([^}]+)\}"#) { match in
            mappedWholly(match, using: superscript) ?? "^" + match
        }

        // 4. Subscripts: _x, then _{…} — same ordering rule as above.
        //
        //    Bare _x only in a MATH context: the char before the
        //    underscore must be a single standalone (Latin/Greek)
        //    letter, and the subscript must not continue as a word.
        //    Unguarded, ordinary snake_case prose would be mangled —
        //    tool_use → toolᵤse, old_string → oldₛtring.
        t = regexReplace(
            t,
            pattern: #"(?<![A-Za-z0-9α-ωΑ-Ω][A-Za-zα-ωΑ-Ω])(?<=[A-Za-zα-ωΑ-Ω])_([0-9aeioujkrstx])(?![a-z])"#
        ) { match in
            translate(match, using: `subscript`)
        }
        t = regexReplace(t, pattern: #"_\{([^}]+)\}"#) { match in
            mappedWholly(match, using: `subscript`) ?? "_" + match
        }

        // 5. \frac{a}{b} → (a)/(b)
        t = regexReplaceGroups(t,
                               pattern: #"\\frac\{([^}]+)\}\{([^}]+)\}"#) { pieces in
            guard pieces.count == 2 else { return nil }
            return "(\(pieces[0]))/(\(pieces[1]))"
        }

        // 6. Strip math delimiters — keep the content.
        t = stripDelimiters(t, open: #"\\\["#, close: #"\\\]"#, dotAll: true)
        t = stripDelimiters(t, open: #"\\\("#, close: #"\\\)"#, dotAll: false)
        t = regexReplace(t,
                          pattern: #"(?<!\$)\$(?!\$)(.+?)(?<!\$)\$(?!\$)"#,
                          dotAll: false) { match in match }
        t = regexReplace(t,
                          pattern: #"\$\$(.+?)\$\$"#,
                          dotAll: true) { match in match }

        // 7. Drop presentation-only TeX control words.
        //    A command that WRAPS its argument has to lose its BRACES
        //    with it: removing the word alone leaves `\mathbf{v}` on
        //    screen as `{v}`, which reads as a set, not a vector.
        t = regexReplace(
            t,
            pattern: #"\\(?:text|mathrm|mathbf)\{([^{}]*)\}"#,
            dotAll: false
        ) { inner in inner }
        //    Delimiter sizing takes no argument — `\left(` is a bare
        //    word in front of the delimiter it sizes — so for these the
        //    word alone is what goes.
        t = regexReplace(t,
                          pattern: #"\\(left|right|bigg|Bigg|big|Big)\b"#,
                          dotAll: false) { _ in "" }

        return t
    }

    // MARK: - Helpers

    /// Map EVERY character, or none of them.
    ///
    /// A partial conversion is worse than no conversion: there is no
    /// subscript `m`, so a per-character pass renders `x_{max}` as
    /// `xmₐₓ` — which reads as a different expression rather than as an
    /// unsupported one, and runs the subscript into the base. nil means
    /// "leave this legible instead", and the caller falls back to the
    /// flat `x_max` spelling.
    ///
    /// The BARE `^x` / `_x` forms need no such guard: their patterns
    /// already admit only characters the maps cover.
    private static func mappedWholly(_ s: String,
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

    /// Apply a per-character lookup, passing through anything not found.
    private static func translate(_ s: String,
                                  using map: [Character: Character]) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        for ch in s {
            out.append(map[ch] ?? ch)
        }
        return out
    }

    /// Regex replacement with a callback over the first capture group.
    /// If the callback returns nil, the original match is left in place.
    private static func regexReplace(_ input: String,
                                     pattern: String,
                                     dotAll: Bool = false,
                                     _ transform: (String) -> String?)
    -> String {
        var options: NSRegularExpression.Options = []
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
            return input
        }
        let ns = input as NSString
        var result = ""
        var cursor = 0
        let matches = re.matches(in: input,
                                 range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let whole = m.range
            if whole.location > cursor {
                result += ns.substring(with: NSRange(location: cursor,
                                                    length: whole.location - cursor))
            }
            let groupIndex = m.numberOfRanges > 1 ? 1 : 0
            let groupRange = m.range(at: groupIndex)
            let groupText: String = groupRange.location == NSNotFound
                ? ""
                : ns.substring(with: groupRange)
            if let replaced = transform(groupText) {
                result += replaced
            } else {
                result += ns.substring(with: whole)
            }
            cursor = whole.location + whole.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor,
                                                 length: ns.length - cursor))
        }
        return result
    }

    /// Multi-group variant of `regexReplace` for `\frac{a}{b}` and similar.
    private static func regexReplaceGroups(_ input: String,
                                           pattern: String,
                                           dotAll: Bool = false,
                                           _ transform: ([String]) -> String?)
    -> String {
        var options: NSRegularExpression.Options = []
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
            return input
        }
        let ns = input as NSString
        var result = ""
        var cursor = 0
        let matches = re.matches(in: input,
                                 range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let whole = m.range
            if whole.location > cursor {
                result += ns.substring(with: NSRange(location: cursor,
                                                    length: whole.location - cursor))
            }
            var pieces: [String] = []
            for i in 1..<m.numberOfRanges {
                let r = m.range(at: i)
                pieces.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            if let replaced = transform(pieces) {
                result += replaced
            } else {
                result += ns.substring(with: whole)
            }
            cursor = whole.location + whole.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor,
                                                 length: ns.length - cursor))
        }
        return result
    }

    /// Remove delimiter sequences, keeping the content between them.
    /// `open` / `close` are regex patterns. Used for `\[ … \]`, `\( … \)`.
    private static func stripDelimiters(_ input: String,
                                        open: String,
                                        close: String,
                                        dotAll: Bool) -> String {
        let pattern = "\(open)(.+?)\(close)"
        return regexReplace(input, pattern: pattern, dotAll: dotAll) { match in
            match
        }
    }
}
