// Headless check of the native math typesetter that CHAT and AGENT
// transcripts render display equations with — the font layer, the
// parser, the layout, and the block segmentation that routes an
// equation to it in the first place.
//
// Notes do not come through here: they go to KaTeX in a web view (see
// Verification/NoteExport). The inline Unicode approximation has its own
// harness (Verification/LatexSymbols).
//
// Nothing here is part of the app target.
import AppKit
import CoreText
import Foundation

var failures = 0, checks = 0
func section(_ t: String) { print("\n\(t)") }
func ok(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition { print("  ok   \(label)") }
    else {
        failures += 1
        let d = detail()
        print("  FAIL \(label)" + (d.isEmpty ? "" : "\n         \(d)"))
    }
}
func eq<T: Equatable>(_ label: String, _ got: T, _ want: T) {
    ok(label, got == want, "expected \(want)\n         got      \(got)")
}

// Equations lifted from a real reply. Between them they use the whole
// command set a derivation-heavy conversation reaches for.
let realEquations: [String] = [
    "C_v(q,\\varphi;\\mathbf w) = \\frac{c(\\mathbf w)}{\\varphi}q,",
    "\\ell(\\varphi)=f+\\frac{q}{\\varphi}",
    "q=\\varphi(\\ell-f),\\qquad \\ell\\geq f.",
    "Q=\\left[\\int_{\\omega\\in\\Omega} q(\\omega)^{\\rho}\\,d\\omega\\right]^{1/\\rho},\\qquad 0<\\rho<1",
    "\\widetilde\\varphi=\\left[\\frac{1}{1-G(\\varphi^*)}\\int_{\\varphi^*}^{\\infty}\\varphi^{\\sigma-1}g(\\varphi)\\,d\\varphi\\right]^{\\frac{1}{\\sigma-1}}",
    "\\boxed{\\ \\pi(\\varphi)=\\frac{r(\\varphi)}{\\sigma}-f\\ }",
    "MC(\\varphi)=\\frac{w}{\\varphi}.",
    "\\begin{aligned} \\text{Trade} &\\Longrightarrow \\text{selection} \\\\ &\\Longrightarrow \\text{reallocation} \\end{aligned}",
    "\\underbrace{a+b+c}_{\\text{three terms}}",
    "\\sum_{i=1}^{n} x_i^2 = \\prod_{k}\\sqrt{\\frac{a_k}{b_k}}",
    "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}",
    "\\begin{cases} x & \\text{if } x>0 \\\\ 0 & \\text{otherwise} \\end{cases}",
]

// MARK: - 1. The font layer

section("1. The typographic constants come from the font, not from guesses")
guard let resource = MathFontResource.shared else {
    print("  FAIL STIX Two Math is missing or carries no MATH table.")
    print("       Expected /System/Library/Fonts/Supplemental/STIXTwoMath.otf.")
    print("       Without it every display equation falls back to text —")
    print("       degraded, but not broken. The rest of this harness needs it.")
    exit(1)
}
let c = resource.constants
ok("the font resolves and carries a MATH table", true)
eq("units per em", resource.unitsPerEm, 1000)
// Ranges, not exact values: a macOS font update may move these by a
// hair. What they catch is a WRONG OFFSET in the table reader, which
// does not move a value slightly — it reads a different field entirely
// and yields something absurd.
ok("axis height is plausible", (0.15...0.40).contains(c.axisHeight), "got \(c.axisHeight)")
ok("fraction rule is a hairline", (0.02...0.15).contains(c.fractionRuleThickness),
   "got \(c.fractionRuleThickness)")
ok("script scale is a reduction", (0.55...0.85).contains(c.scriptPercentScaleDown),
   "got \(c.scriptPercentScaleDown)")
ok("scriptscript is smaller still",
   c.scriptScriptPercentScaleDown < c.scriptPercentScaleDown,
   "got \(c.scriptScriptPercentScaleDown) vs \(c.scriptPercentScaleDown)")
ok("a display operator is at least an em tall",
   (1.0...3.0).contains(c.displayOperatorMinHeight), "got \(c.displayOperatorMinHeight)")
ok("the radical kern after the degree is negative — the index tucks in",
   c.radicalKernAfterDegree < 0, "got \(c.radicalKernAfterDegree)")

// Growing delimiters are the reason this reads the MATH table at all.
if let paren = resource.glyph(for: "(") {
    let variants = resource.variants(paren, vertical: true)
    ok("'(' has size variants", variants.count >= 3, "got \(variants.count)")
    ok("variants are ordered smallest first",
       zip(variants, variants.dropFirst()).allSatisfy { $0.advance <= $1.advance })
    ok("'(' has a repeatable assembly for very tall content",
       resource.assembly(paren, vertical: true) != nil)
} else {
    ok("'(' has size variants", false, "no glyph for '('")
}

// MARK: - 2. The parser

section("2. Arguments nest, and one token is an argument")

func atoms(_ latex: String) -> MathList {
    MathParser.parse(latex) ?? []
}

// The failure this replaced: `[^}]+` matched to the FIRST `}` and took
// half the fraction with it, printing `x^\frac{1{σ-1}}` — not a degraded
// rendering of the input but a different expression.
let nested = atoms("x^{\\frac{1}{\\sigma-1}}")
eq("a fraction in a superscript is one atom with one script", nested.count, 1)
if let sup = nested.first?.sup, sup.count == 1, case .fraction = sup[0].kind {
    ok("and the script IS the fraction", true)
} else {
    ok("and the script IS the fraction", false, "got \(nested.first?.sup as Any)")
}

let bare = atoms("\\mathbf w")
if bare.count == 1, case .list(let inner) = bare[0].kind, inner.count == 1,
   case .glyphs(let g) = inner[0].kind {
    eq("a bare argument reaches the alphabet command", g, "\u{1D430}")
} else {
    ok("a bare argument reaches the alphabet command", false, "got \(bare)")
}

let delimited = atoms("\\left( \\frac{a}{b} \\right)")
if delimited.count == 1, case .delimited(let l, _, let r) = delimited[0].kind {
    eq("\\left…\\right is one atom, opener kept", l, "(")
    eq("…and its closer", r, ")")
} else {
    ok("\\left…\\right is one atom", false, "got \(delimited)")
}

let table = atoms("\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}")
if table.count == 1, case .table(let t) = table[0].kind {
    eq("an environment is one table atom with two rows", t.rows.count, 2)
    eq("…and two columns", t.rows[0].count, 2)
    eq("aligned puts the relation column on the left edge",
       t.alignments[1], MathTableNode.Alignment.leading)
} else {
    ok("an environment is one table atom", false, "got \(table)")
}

let unknown = atoms("\\notarealcommand")
if unknown.count == 1, case .unknown(let name) = unknown[0].kind {
    eq("an unimplemented command survives as itself", name, "\\notarealcommand")
} else {
    ok("an unimplemented command survives as itself", false, "got \(unknown)")
}

// A minus is subtraction or a sign depending on what precedes it, and
// the two are spaced differently.
if case .binary = atoms("a-b")[1].mathClass {
    ok("a-b spaces its minus as subtraction", true)
} else { ok("a-b spaces its minus as subtraction", false) }
if case .ordinary = atoms("-b")[0].mathClass {
    ok("a leading minus is a sign, not an operator", true)
} else { ok("a leading minus is a sign, not an operator", false) }

section("3. Every command a real conversation used is implemented")
// An `.unknown` atom draws in the error tint. Nothing in the corpus
// below may produce one: that IS the bug this work exists to fix.
func unknowns(_ list: MathList) -> [String] {
    var found: [String] = []
    func walk(_ l: MathList) {
        for atom in l {
            switch atom.kind {
            case .unknown(let n): found.append(n)
            case .list(let i), .boxed(let i): walk(i)
            case .fraction(let n, let d, _): walk(n); walk(d)
            case .radical(let i, let b): if let i { walk(i) }; walk(b)
            case .delimited(_, let b, _): walk(b)
            case .accent(_, let b): walk(b)
            case .overUnder(let o): walk(o.base)
            case .table(let t): for row in t.rows { for cell in row { walk(cell) } }
            case .glyphs, .text, .space: break
            }
            if let s = atom.sub { walk(s) }
            if let s = atom.sup { walk(s) }
        }
    }
    walk(list)
    return found
}
for equation in realEquations {
    let found = unknowns(atoms(equation))
    ok("no unknown command in: \(equation.prefix(46))", found.isEmpty,
       "unimplemented: \(found.joined(separator: " "))")
}

// MARK: - 4. Layout

section("4. Layout puts things where TeX puts them")
guard let display = MathTypesetter(size: 20), let text = MathTypesetter(size: 20) else {
    print("  FAIL could not build a typesetter"); exit(1)
}
func box(_ latex: String, _ style: MathStyle = .display,
         _ t: MathTypesetter = display) -> MathBox {
    t.layout(atoms(latex), style: style)
}

// Everything must have finite, non-negative extent — a NaN anywhere in
// the box tree propagates into a frame and takes the whole transcript
// down with it.
for equation in realEquations {
    let b = box(equation)
    let sane = b.width.isFinite && b.ascent.isFinite && b.descent.isFinite
        && b.width > 0 && b.ascent > 0 && b.descent >= 0
    ok("finite, positive extent: \(equation.prefix(40))", sane,
       "w=\(b.width) a=\(b.ascent) d=\(b.descent)")
}

let plain = box("a")
let fraction = box("\\frac{a}{b}")
ok("a fraction is taller than its parts",
   fraction.ascent + fraction.descent > (plain.ascent + plain.descent) * 1.8,
   "\(fraction.ascent + fraction.descent) vs \(plain.ascent + plain.descent)")
ok("a fraction reaches below the baseline", fraction.descent > plain.descent)

let smallParen = box("(a)")
let bigParen = box("\\left(\\frac{\\frac{a}{b}}{c}\\right)")
ok("a delimiter grows with what it wraps",
   bigParen.ascent > smallParen.ascent * 1.6,
   "\(bigParen.ascent) vs \(smallParen.ascent)")

let stacked = box("\\sum_{i=1}^{n}", .display)
let beside = box("\\sum_{i=1}^{n}", .text, text)
ok("a sum stacks its limits in display style",
   stacked.width < beside.width, "\(stacked.width) vs \(beside.width)")
ok("…and is taller for it", stacked.ascent > beside.ascent)
let integral = box("\\int_{0}^{1}", .display)
ok("an integral keeps its limits at the side even in display style",
   integral.width > box("\\int", .display).width * 1.3)

let accented = box("\\hat{x}")
let unaccented = box("x")
eq("an accent takes no width", accented.width, unaccented.width)
ok("…and raises the box", accented.ascent > unaccented.ascent)

let root = box("\\sqrt{\\frac{a}{b}}")
ok("a radical is at least as tall as what it covers",
   root.ascent > fraction.ascent, "\(root.ascent) vs \(fraction.ascent)")

let matrix = box("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}")
ok("a 2×2 matrix is wider than one entry", matrix.width > box("a").width * 3)
ok("…and taller than one row", matrix.ascent + matrix.descent > plain.ascent * 3)

// Script style tightens: the same expression set as a superscript is
// smaller than on the baseline.
let inScript = display.layout(atoms("a+b"), style: .script)
let onBaseline = display.layout(atoms("a+b"), style: .display)
ok("script style is smaller", inScript.width < onBaseline.width * 0.85,
   "\(inScript.width) vs \(onBaseline.width)")

// MARK: - 5. Segmentation

section("5. A display equation becomes its own block")
let document = """
Prose before.

\\[
C_v(q,\\varphi) = \\frac{c}{\\varphi}q
\\]

Prose after with \\(\\varphi\\) inline.

```
$$ not math, this is code $$
```

$$ x = 1 $$

\\[ never closed
"""
let blocks = MarkdownRenderer.parse(document)
var mathBlocks: [String] = []
for b in blocks { if case .displayMath(let latex) = b { mathBlocks.append(latex) } }
eq("two display equations found", mathBlocks.count, 2)
if mathBlocks.count == 2 {
    ok("the multi-line one keeps its lines",
       mathBlocks[0].contains("\\frac{c}{\\varphi}") && mathBlocks[0].contains("C_v"),
       mathBlocks[0])
    ok("the delimiters are gone", !mathBlocks[0].contains("\\["))
    eq("a one-line $$…$$ works too", mathBlocks[1], "x = 1")
}
var paragraphs: [String] = []
for b in blocks { if case .paragraph(let t) = b { paragraphs.append(t) } }
ok("a `$$` inside a fenced block is code, not math",
   !paragraphs.contains { $0.contains("not math") })
ok("an unterminated `\\[` stays prose",
   paragraphs.contains { $0.contains("never closed") }, "\(paragraphs)")
ok("inline math is left in its paragraph",
   paragraphs.contains { $0.contains("\\varphi") })

// The counter and the highlights are one contract. A display equation
// draws typeset GLYPHS, so counting its LaTeX would name matches the
// reader cannot see and cannot be stepped to — the shape
// `SearchMatching` exists to forbid. So none of the source reaches the
// searched text, while the prose around it is untouched.
let searched = MarkdownRenderer.plainText(document)
ok("a display equation's source is not searchable text",
   !searched.contains("frac") && !searched.contains("C_v"), searched)
eq("prose on either side still is",
   SearchMatching.count(of: "Prose", in: searched), 2)
eq("and so does inline math, translated",
   SearchMatching.count(of: "\u{03C6}", in: searched), 1)

// MARK: - Optional rendering

if ProcessInfo.processInfo.environment["MATH_RENDER"] != nil {
    let out = renderSheet(realEquations, typesetter: display)
    print("\nwrote \(out)")
}

func renderSheet(_ equations: [String], typesetter: MathTypesetter) -> String {
    let laid = equations.map { typesetter.layout(atoms($0), style: .display) }
    let pad: CGFloat = 24
    let width = (laid.map(\.width).max() ?? 100) + pad * 2
    let height = laid.reduce(pad) { $0 + $1.height + pad }
    let scale: CGFloat = 2
    guard let ctx = CGContext(data: nil,
                              width: Int(width * scale), height: Int(height * scale),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return "(no context)" }
    ctx.scaleBy(x: scale, y: scale)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.textMatrix = .identity
    var y = height - pad
    for b in laid {
        y -= b.ascent
        ctx.saveGState()
        ctx.translateBy(x: pad, y: y)
        // A bitmap context is already Y-up, so no flip is needed here —
        // the app's canvas is Y-down and flips once (`MathCanvas`).
        b.draw(in: ctx,
               color: CGColor(gray: 0.1, alpha: 1),
               errorColor: CGColor(srgbRed: 0.7, green: 0.11, blue: 0.16, alpha: 1))
        ctx.restoreGState()
        y -= b.descent + pad
    }
    let path = NSTemporaryDirectory() + "sipai-math.png"
    if let image = ctx.makeImage(),
       let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
    return path
}

print("")
if failures == 0 { print("All \(checks) math-typesetting checks passed.") }
else { print("\(failures) of \(checks) math-typesetting checks FAILED."); exit(1) }
