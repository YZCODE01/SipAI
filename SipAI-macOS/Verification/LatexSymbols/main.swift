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
eq("sum limits still convert", "\\sum_{i=1}^{n}", "Σᵢ₌₁ⁿ")
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

print("")
if failures == 0 { print("All \(checks) LaTeX-translation checks passed.") }
else { print("\(failures) of \(checks) LaTeX-translation checks FAILED."); exit(1) }
