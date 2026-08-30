// Headless check of the LaTeX → Unicode translator used by CHAT and
// AGENT transcripts. Notes do not come through here — they go to KaTeX
// (see Verification/NoteExport).
//
// Nothing here is part of the app target.
import Foundation

var failures = 0, checks = 0
func section(_ t: String) { print("\n\(t)") }
func eq(_ label: String, _ input: String, _ expected: String) {
    checks += 1
    let got = LatexSymbols.translate(input)
    if got == expected {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)\n         in       \(input)\n         expected \(expected)\n         got      \(got)")
    }
}
func has(_ label: String, _ input: String, _ predicate: (String) -> Bool) {
    checks += 1
    let got = LatexSymbols.translate(input)
    if predicate(got) { print("  ok   \(label)") }
    else { failures += 1; print("  FAIL \(label)\n         in  \(input)\n         got \(got)") }
}

section("1. A braced script converts wholly, or not at all")
// Partial mapping is the bug: there is no subscript `m`, so the old
// per-character pass turned x_{max} into xmₐₓ — a different expression,
// with the unmapped letters run into the base.
eq("x_{max} falls back to a flat spelling", "x_{max}", "x_max")
eq("v_{initial} likewise", "v_{initial}", "v_initial")
eq("T_{eff} likewise", "T_{eff}", "T_eff")
eq("fully-mappable subscript still converts", "x_{i}", "xᵢ")
eq("digits still convert", "x_{12}", "x₁₂")
// `\sum` is the N-ARY SUMMATION operator (U+2211), not GREEK CAPITAL
// LETTER SIGMA (U+03A3). They look alike at a glance and are different
// characters: one is an operator, the other is a letter a reply may
// separately be using as a variable.
eq("sum limits still convert", "\\sum_{i=1}^{n}", "\u{2211}ᵢ₌₁ⁿ")
eq("uppercase has no subscript form", "x_{N}", "x_N")
eq("mixed case falls back", "x_{aB}", "x_aB")

eq("superscript falls back when unmappable", "x^{ab}", "x^ab")
eq("fully-mappable superscript converts", "x^{2}", "x²")
eq("multi-digit superscript converts", "x^{12}", "x¹²")
eq("nested superscript falls back rather than lying", "e^{-x^2}", "e^-x²")

section("2. A wrapping command loses its braces with it")
// Dropping the word alone left `\mathbf{v}` showing as `{v}`.
eq("\\mathbf keeps only its argument", "\\mathbf{v}", "v")
eq("\\mathrm likewise", "\\mathrm{d}", "d")
eq("\\text likewise", "\\text{if}", "if")
eq("two in one line", "\\mathbf{v} \\cdot \\mathbf{w}", "v · w")
has("no stray braces left", "\\mathbf{v} + \\mathbf{w}") { !$0.contains("{") && !$0.contains("}") }
eq("an empty argument leaves nothing", "\\text{}", "")

section("3. Delimiter sizing still drops the word alone")
// These take no braces: `\left(` sizes the paren that follows it.
eq("\\left / \\right", "\\left( x \\right)", "( x )")
eq("\\big", "\\big[ y \\big]", "[ y ]")
eq("\\bigg is not truncated to \\big", "\\bigg( z \\bigg)", "( z )")
eq("\\Bigg likewise", "\\Bigg| z \\Bigg|", "| z |")

section("4. Prose is still not mathematics")
// The guards that keep snake_case identifiers intact.
eq("snake_case untouched", "tool_use", "tool_use")
eq("longer identifier untouched", "old_string and new_string",
   "old_string and new_string")
eq("bare subscript after a lone letter still works", "H_2O", "H₂O")
eq("a word is not a base", "sample_1", "sample_1")

section("5. What already worked keeps working")
eq("greek", "\\pi", "π")
eq("longest key wins", "\\subseteq", "⊆")
eq("blackboard", "\\mathbb{R}", "ℝ")
eq("fraction", "\\frac{a}{b}", "(a)/(b)")
eq("inline delimiters stripped", "$x + 1$", "x + 1")
eq("display delimiters stripped", "$$x + 1$$", "x + 1")
eq("area formula", "A = \\pi r^2", "A = π r²")

section("6. Arguments nest, because every one of them can contain another")
// `[^}]+` cannot nest. Matching `^{…}` up to the FIRST `}` took half the
// fraction with it and produced `x^\\frac{1{σ-1}}` — not a degraded
// rendering of the input but a different expression.
eq("a fraction inside a superscript", "x^{\\frac{1}{\\sigma-1}}", "x^(1)/(σ-1)")
eq("a fraction inside a fraction", "\\frac{\\frac{a}{b}}{c}", "((a)/(b))/(c)")
eq("a script inside a script", "x_{a_{i}}", "x_aᵢ")
has("no brace survives a nested fraction", "\\frac{1}{1-G(\\varphi^{*})}") {
    !$0.contains("{") && !$0.contains("}")
}

section("7. An argument is a braced group OR one token")
// `\mathbf w` and `\widetilde\varphi` are spellings models emit at
// least as often as the braced ones. Accepting only `\mathbf{w}` left
// the command on screen.
eq("bare argument to a wrapping command", "\\mathbf w", "w")
eq("bare argument to an accent", "\\widetilde\\varphi", "φ\u{0303}")
eq("braced argument to an accent", "\\bar{x}", "x\u{0304}")
eq("the sequence from a real reply", "F(\\mathbf w)=wf,\\qquad c(\\mathbf w)=w",
   "F(w)=wf,     c(w)=w")

section("8. Symbols a real conversation actually used")
// Measured on a 43 KB reply: 47 distinct commands, of which the old
// table covered 27. `\varphi` alone occurred 348 times and printed
// verbatim.
eq("varphi", "\\varphi", "φ")
eq("ell", "\\ell", "ℓ")
eq("Longrightarrow", "\\Longrightarrow", "⟹")
eq("qquad is space, not a word", "a\\qquad b", "a     b")
eq("boxed keeps its content", "\\boxed{x=1}", "x=1")
eq("tag reads as a number", "x=1\\tag{3}", "x=1 (3)")
// `\epsilon` is the LUNATE one and `\phi` the straight one — LaTeX
// names both the opposite way round from what the spellings suggest.
eq("phi is the straight one", "\\phi", "ϕ")
eq("varphi is the loopy one", "\\varphi", "φ")
eq("epsilon is lunate", "\\epsilon", "ϵ")
eq("varepsilon is not", "\\varepsilon", "ε")

section("9. A root takes its argument with it")
// `\sqrt` used to be a plain substitution, so the braces it wraps were
// left on screen: `\sqrt{x}` rendered as `√{x}`.
eq("square root", "\\sqrt{x+1}", "√(x+1)")
eq("nth root", "\\sqrt[3]{x}", "³√(x)")
has("no brace survives a root", "\\sqrt{\\frac{a}{b}}") {
    !$0.contains("{") && !$0.contains("}")
}

section("10. An unknown command is shown, never guessed at")
eq("unknown command survives verbatim", "\\notacommand", "\\notacommand")


print("")
if failures == 0 { print("All \(checks) LaTeX-translation checks passed.") }
else { print("\(failures) of \(checks) LaTeX-translation checks FAILED."); exit(1) }
