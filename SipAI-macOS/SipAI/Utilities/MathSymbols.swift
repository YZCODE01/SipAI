// MathSymbols.swift
// The command → character tables `MathParser` reads. The alphabet
// mapping lives next door in `MathAlphabets.swift`.
//
// The math font is the authority on shape, so nothing here may be a
// character a math font would set upright by accident: lowercase Greek
// reaches this table already in its ITALIC spelling (U+1D6FC…), because
// U+03B1 is the upright alpha in a math font and would silently
// contradict every italic Latin variable beside it.

import CoreGraphics
import Foundation

// MARK: - Symbols

enum MathSymbols {

    struct Entry {
        let glyph: String
        let mathClass: MathClass
        /// Large operators only: whether scripts default above/below.
        let limits: Bool?
        init(_ glyph: String, _ mathClass: MathClass = .ordinary, limits: Bool? = nil) {
            self.glyph = glyph
            self.mathClass = mathClass
            self.limits = limits
        }
    }

    /// Delimiter-sizing words. They take no argument — the delimiter
    /// that FOLLOWS is what they size — so the word alone is dropped and
    /// the delimiter keeps its place. A renderer that also dropped the
    /// delimiter would silently unbalance the expression.
    static let sizingCommands: Set<String> = [
        "big", "Big", "bigg", "Bigg",
        "bigl", "Bigl", "biggl", "Biggl",
        "bigr", "Bigr", "biggr", "Biggr",
        "bigm", "Bigm", "biggm", "Biggm",
    ]

    /// Explicit spacing, in EM.
    static let spaces: [String: CGFloat] = [
        ",": 3.0 / 18, ":": 4.0 / 18, ";": 5.0 / 18, "!": -3.0 / 18,
        " ": 1.0 / 3, "quad": 1, "qquad": 2,
        "thinspace": 3.0 / 18, "medspace": 4.0 / 18, "thickspace": 5.0 / 18,
        "negthinspace": -3.0 / 18, "enspace": 0.5,
    ]

    /// Accents, as the COMBINING mark to centre over the base. The
    /// stretchy `\wide…` forms fall back to the same mark: one that does
    /// not span a wide base is better than a command name on screen.
    static let accents: [String: String] = [
        "hat": "\u{0302}", "widehat": "\u{0302}",
        "tilde": "\u{0303}", "widetilde": "\u{0303}",
        "bar": "\u{0304}", "overbar": "\u{0304}",
        "dot": "\u{0307}", "ddot": "\u{0308}", "dddot": "\u{20DB}",
        "check": "\u{030C}", "breve": "\u{0306}",
        "acute": "\u{0301}", "grave": "\u{0300}",
        "mathring": "\u{030A}", "overleftrightarrow": "\u{20E1}",
    ]

    /// Multi-letter operator names, set upright.
    static let namedOperators: [String: (name: String, limits: Bool)] = [
        "sin": ("sin", false), "cos": ("cos", false), "tan": ("tan", false),
        "cot": ("cot", false), "sec": ("sec", false), "csc": ("csc", false),
        "arcsin": ("arcsin", false), "arccos": ("arccos", false),
        "arctan": ("arctan", false), "sinh": ("sinh", false),
        "cosh": ("cosh", false), "tanh": ("tanh", false), "coth": ("coth", false),
        "exp": ("exp", false), "ln": ("ln", false), "log": ("log", false),
        "lg": ("lg", false), "arg": ("arg", false), "deg": ("deg", false),
        "dim": ("dim", false), "hom": ("hom", false), "ker": ("ker", false),
        "bmod": ("mod", false), "mod": ("mod", false), "pmod": ("mod", false),
        "lim": ("lim", true), "limsup": ("lim sup", true),
        "liminf": ("lim inf", true), "max": ("max", true), "min": ("min", true),
        "sup": ("sup", true), "inf": ("inf", true), "det": ("det", true),
        "gcd": ("gcd", true), "Pr": ("Pr", true), "argmax": ("arg max", true),
        "argmin": ("arg min", true),
    ]

    /// Command → character. Lowercase Greek arrives already italic
    /// because a math font sets U+03B1 UPRIGHT, which would put an
    /// upright alpha next to an italic x in the same expression.
    static let table: [String: Entry] = {
        var t: [String: Entry] = [:]

        // Greek, lowercase (italic by TeX convention).
        let lowerGreek: [(String, UInt32)] = [
            ("alpha", 0x1D6FC), ("beta", 0x1D6FD), ("gamma", 0x1D6FE),
            ("delta", 0x1D6FF), ("varepsilon", 0x1D700), ("zeta", 0x1D701),
            ("eta", 0x1D702), ("theta", 0x1D703), ("iota", 0x1D704),
            ("kappa", 0x1D705), ("lambda", 0x1D706), ("mu", 0x1D707),
            ("nu", 0x1D708), ("xi", 0x1D709), ("omicron", 0x1D70A),
            ("pi", 0x1D70B), ("rho", 0x1D70C), ("varsigma", 0x1D70D),
            ("sigma", 0x1D70E), ("tau", 0x1D70F), ("upsilon", 0x1D710),
            ("varphi", 0x1D711), ("chi", 0x1D712), ("psi", 0x1D713),
            ("omega", 0x1D714),
            // The variant shapes, which TeX names the other way round
            // from what their spelling suggests: `\epsilon` is the
            // lunate one and `\phi` is the straight one.
            ("epsilon", 0x1D716), ("vartheta", 0x1D717), ("varkappa", 0x1D718),
            ("phi", 0x1D719), ("varrho", 0x1D71A), ("varpi", 0x1D71B),
        ]
        for (name, scalar) in lowerGreek {
            if let u = Unicode.Scalar(scalar) { t[name] = Entry(String(Character(u))) }
        }
        // Greek, uppercase — upright, as TeX sets them.
        let upperGreek: [(String, String)] = [
            ("Gamma", "\u{0393}"), ("Delta", "\u{0394}"), ("Theta", "\u{0398}"),
            ("Lambda", "\u{039B}"), ("Xi", "\u{039E}"), ("Pi", "\u{03A0}"),
            ("Sigma", "\u{03A3}"), ("Upsilon", "\u{03A5}"), ("Phi", "\u{03A6}"),
            ("Psi", "\u{03A8}"), ("Omega", "\u{03A9}"),
        ]
        for (name, glyph) in upperGreek { t[name] = Entry(glyph) }

        // Ordinary symbols.
        let ordinary: [(String, String)] = [
            ("ell", "\u{2113}"), ("hbar", "\u{210F}"), ("hslash", "\u{210F}"),
            ("imath", "\u{1D6A4}"), ("jmath", "\u{1D6A5}"), ("wp", "\u{2118}"),
            ("Re", "\u{211C}"), ("Im", "\u{2111}"), ("aleph", "\u{2135}"),
            ("beth", "\u{2136}"), ("infty", "\u{221E}"), ("partial", "\u{1D715}"),
            ("nabla", "\u{2207}"), ("forall", "\u{2200}"), ("exists", "\u{2203}"),
            ("nexists", "\u{2204}"), ("emptyset", "\u{2205}"),
            ("varnothing", "\u{2205}"), ("neg", "\u{00AC}"), ("lnot", "\u{00AC}"),
            ("top", "\u{22A4}"), ("bot", "\u{22A5}"), ("angle", "\u{2220}"),
            ("triangle", "\u{25B3}"), ("square", "\u{25A1}"),
            ("degree", "\u{00B0}"), ("prime", "\u{2032}"),
            ("dots", "\u{2026}"), ("ldots", "\u{2026}"), ("cdots", "\u{22EF}"),
            ("vdots", "\u{22EE}"), ("ddots", "\u{22F1}"),
            ("dagger", "\u{2020}"), ("ddagger", "\u{2021}"),
            ("checkmark", "\u{2713}"), ("clubsuit", "\u{2663}"),
            ("flat", "\u{266D}"), ("sharp", "\u{266F}"),
            ("%", "%"), ("$", "$"), ("#", "#"), ("&", "&"), ("_", "_"),
            ("{", "{"), ("}", "}"), ("|", "\u{2016}"),
        ]
        for (name, glyph) in ordinary { t[name] = Entry(glyph) }

        // Binary operators.
        let binary: [(String, String)] = [
            ("times", "\u{00D7}"), ("div", "\u{00F7}"), ("pm", "\u{00B1}"),
            ("mp", "\u{2213}"), ("cdot", "\u{22C5}"), ("ast", "\u{2217}"),
            ("star", "\u{22C6}"), ("circ", "\u{2218}"), ("bullet", "\u{2219}"),
            ("oplus", "\u{2295}"), ("ominus", "\u{2296}"), ("otimes", "\u{2297}"),
            ("oslash", "\u{2298}"), ("odot", "\u{2299}"), ("cup", "\u{222A}"),
            ("cap", "\u{2229}"), ("uplus", "\u{228E}"), ("sqcup", "\u{2294}"),
            ("sqcap", "\u{2293}"), ("vee", "\u{2228}"), ("wedge", "\u{2227}"),
            ("setminus", "\u{2216}"), ("backslash", "\u{2216}"),
            ("triangleleft", "\u{25C1}"), ("triangleright", "\u{25B7}"),
            ("diamond", "\u{22C4}"), ("amalg", "\u{2A3F}"), ("wr", "\u{2240}"),
        ]
        for (name, glyph) in binary { t[name] = Entry(glyph, .binary) }

        // Relations.
        let relations: [(String, String)] = [
            ("leq", "\u{2264}"), ("le", "\u{2264}"), ("geq", "\u{2265}"),
            ("ge", "\u{2265}"), ("neq", "\u{2260}"), ("ne", "\u{2260}"),
            ("equiv", "\u{2261}"), ("approx", "\u{2248}"), ("cong", "\u{2245}"),
            ("simeq", "\u{2243}"), ("sim", "\u{223C}"), ("propto", "\u{221D}"),
            ("ll", "\u{226A}"), ("gg", "\u{226B}"), ("leqslant", "\u{2A7D}"),
            ("geqslant", "\u{2A7E}"), ("prec", "\u{227A}"), ("succ", "\u{227B}"),
            ("preceq", "\u{2AAF}"), ("succeq", "\u{2AB0}"),
            ("subset", "\u{2282}"), ("supset", "\u{2283}"),
            ("subseteq", "\u{2286}"), ("supseteq", "\u{2287}"),
            ("subsetneq", "\u{228A}"), ("supsetneq", "\u{228B}"),
            ("in", "\u{2208}"), ("notin", "\u{2209}"), ("ni", "\u{220B}"),
            ("mid", "\u{2223}"), ("nmid", "\u{2224}"), ("parallel", "\u{2225}"),
            ("perp", "\u{22A5}"), ("models", "\u{22A8}"), ("vdash", "\u{22A2}"),
            ("dashv", "\u{22A3}"), ("asymp", "\u{224D}"), ("doteq", "\u{2250}"),
            ("triangleq", "\u{225C}"), ("coloneqq", "\u{2254}"),
            ("therefore", "\u{2234}"), ("because", "\u{2235}"),
            ("rightarrow", "\u{2192}"), ("to", "\u{2192}"),
            ("leftarrow", "\u{2190}"), ("gets", "\u{2190}"),
            ("leftrightarrow", "\u{2194}"), ("Rightarrow", "\u{21D2}"),
            ("Leftarrow", "\u{21D0}"), ("Leftrightarrow", "\u{21D4}"),
            ("iff", "\u{27FA}"), ("implies", "\u{27F9}"), ("impliedby", "\u{27F8}"),
            ("longrightarrow", "\u{27F6}"), ("longleftarrow", "\u{27F5}"),
            ("longleftrightarrow", "\u{27F7}"), ("Longrightarrow", "\u{27F9}"),
            ("Longleftarrow", "\u{27F8}"), ("Longleftrightarrow", "\u{27FA}"),
            ("mapsto", "\u{21A6}"), ("longmapsto", "\u{27FC}"),
            ("hookrightarrow", "\u{21AA}"), ("hookleftarrow", "\u{21A9}"),
            ("uparrow", "\u{2191}"), ("downarrow", "\u{2193}"),
            ("updownarrow", "\u{2195}"), ("Uparrow", "\u{21D1}"),
            ("Downarrow", "\u{21D3}"), ("nearrow", "\u{2197}"),
            ("searrow", "\u{2198}"), ("swarrow", "\u{2199}"),
            ("nwarrow", "\u{2196}"), ("rightharpoonup", "\u{21C0}"),
            ("rightleftharpoons", "\u{21CC}"), ("xrightarrow", "\u{27F6}"),
            ("xleftarrow", "\u{27F5}"),
        ]
        for (name, glyph) in relations { t[name] = Entry(glyph, .relation) }

        // Large operators. `\int` keeps its scripts at the side even in
        // display style; the others move them above and below.
        let operators: [(String, String, Bool)] = [
            ("sum", "\u{2211}", true), ("prod", "\u{220F}", true),
            ("coprod", "\u{2210}", true), ("bigcup", "\u{22C3}", true),
            ("bigcap", "\u{22C2}", true), ("bigvee", "\u{22C1}", true),
            ("bigwedge", "\u{22C0}", true), ("bigoplus", "\u{2A01}", true),
            ("bigotimes", "\u{2A02}", true), ("bigodot", "\u{2A00}", true),
            ("biguplus", "\u{2A04}", true), ("bigsqcup", "\u{2A06}", true),
            ("int", "\u{222B}", false), ("iint", "\u{222C}", false),
            ("iiint", "\u{222D}", false), ("oint", "\u{222E}", false),
            ("oiint", "\u{222F}", false),
        ]
        for (name, glyph, limits) in operators {
            t[name] = Entry(glyph, .largeOperator, limits: limits)
        }

        // Delimiters.
        let opens: [(String, String)] = [
            ("langle", "\u{27E8}"), ("lfloor", "\u{230A}"), ("lceil", "\u{2308}"),
            ("lbrace", "{"), ("lbrack", "["), ("lvert", "|"), ("lVert", "\u{2016}"),
        ]
        for (name, glyph) in opens { t[name] = Entry(glyph, .open) }
        let closes: [(String, String)] = [
            ("rangle", "\u{27E9}"), ("rfloor", "\u{230B}"), ("rceil", "\u{2309}"),
            ("rbrace", "}"), ("rbrack", "]"), ("rvert", "|"), ("rVert", "\u{2016}"),
        ]
        for (name, glyph) in closes { t[name] = Entry(glyph, .close) }

        return t
    }()
}
