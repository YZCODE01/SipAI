// Headless check of the note render path — what "Save as PDF" and the
// note Preview pane both go through.
//
// Nothing here is part of the app target.
import Foundation

var failures = 0
var checks = 0

func section(_ t: String) { print("\n\(t)") }

func ok(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        let d = detail()
        print("  FAIL \(label)\(d.isEmpty ? "" : "\n         " + d)")
    }
}

func html(_ md: String) -> String { NoteHTML.bodyHTML(md) }

// ---------------------------------------------------------------------
section("1. LaTeX reaches KaTeX untranslated")
// The whole reason this path exists. If anyone routes a note through
// `MarkdownInline.attributed`, `LatexSymbols.translate` turns \frac into
// "(a)/(b)" and \pi into "π" BEFORE KaTeX sees it, and every one of
// these fails.
do {
    let h = html("$$\\frac{a+b}{c}$$")
    ok("display \\frac survives verbatim", h.contains("\\frac{a+b}{c}"), h)
    ok("not degraded to (a+b)/(c)", !h.contains("(a+b)/(c)"), h)
    ok("wrapped as a display node", h.contains("data-display=\"1\""), h)

    let p = html("The area is $A = \\pi r^2$ today.")
    ok("inline math is a node", p.contains("data-display=\"0\""), p)
    ok("\\pi not substituted", p.contains("\\pi") && !p.contains("π"), p)

    let nested = html("$$\\frac{\\frac{1}{2}}{x+1}$$")
    ok("nested \\frac intact", nested.contains("\\frac{\\frac{1}{2}}{x+1}"), nested)
}

// ---------------------------------------------------------------------
section("2. Every display spelling is recognised")
do {
    ok("$$…$$ one line", html("$$x^2$$").contains("data-display=\"1\""))
    ok("\\[…\\] one line", html("\\[x^2\\]").contains("data-display=\"1\""))

    let multi = html("$$\n\\int_0^1 x\\,dx\n$$")
    ok("$$…$$ across lines", multi.contains("data-display=\"1\"") && multi.contains("\\int_0^1"), multi)

    let env = html("\\begin{align}\ny &= mx \\\\\nz &= 2y\n\\end{align}")
    ok("bare \\begin{align} block", env.contains("data-display=\"1\"") && env.contains("\\begin{align}"), env)

    let cases = html("\\begin{pmatrix} a & b \\end{pmatrix}")
    ok("bare \\begin{pmatrix} block", cases.contains("data-display=\"1\""), cases)

    // An unterminated $$ is somebody's prose, not the start of maths
    // that swallows the rest of the note.
    let stray = html("Cost is $$5 for the first one\n\nAnd a second paragraph.")
    ok("unterminated $$ stays prose", !stray.contains("sipai-math") && stray.contains("second paragraph"), stray)

    let unknownEnv = html("\\begin{itemize}\n\\item one\n\\end{itemize}")
    ok("non-maths environment left alone", !unknownEnv.contains("sipai-math"), unknownEnv)
}

// ---------------------------------------------------------------------
section("3. Currency is not mathematics")
do {
    let money = html("Prices are $5 and $10 each.")
    ok("$5 and $10 is not a math node", !money.contains("sipai-math"), money)

    let mixed = html("It costs $5, and $x = 1$ holds.")
    ok("real inline math still found", mixed.contains("data-display=\"0\""), mixed)
}

// ---------------------------------------------------------------------
section("4. Code shields maths, maths never shields code")
do {
    let fence = html("```swift\nlet s = \"$x^2$\"\n```")
    ok("fenced code has no math node", !fence.contains("sipai-math"), fence)
    ok("fenced code kept literally", fence.contains("$x^2$"), fence)
    ok("language label rendered", fence.contains("sipai-lang") && fence.contains("swift"), fence)

    let inline = html("Use `$x$` for inline maths.")
    ok("inline code has no math node", !inline.contains("sipai-math"), inline)
    ok("inline code rendered as <code>", inline.contains("<code>$x$</code>"), inline)

    let snake = html("The `tool_use` block and x_1 here.")
    ok("snake_case in code untouched", snake.contains("tool_use"), snake)
}

// ---------------------------------------------------------------------
section("5. A note cannot write markup")
// Notes are model-generated and hand-editable. Everything from the note
// is escaped; the only tags in the output are the ones NoteHTML writes.
do {
    let evil = html("<script>alert(1)</script> and <b>bold</b>")
    ok("no raw <script>", !evil.contains("<script>"), evil)
    ok("no raw <b>", !evil.contains("<b>"), evil)
    ok("escaped instead", evil.contains("&lt;script&gt;"), evil)

    let img = html("<img src=x onerror=alert(1)>")
    ok("no raw <img", !img.lowercased().contains("<img"), img)

    let attr = html("[label](https://example.com/\"onmouseover=\"alert(1))")
    ok("quotes in a href escaped", !attr.contains("\"onmouseover=\"alert"), attr)

    let inMath = html("$$<script>x</script>$$")
    ok("markup inside maths escaped too", !inMath.contains("<script>"), inMath)
}

// ---------------------------------------------------------------------
section("6. Link schemes are gated, labels are kept")
do {
    let good = html("A [link](https://example.com) here.")
    ok("https becomes an anchor", good.contains("<a href=\"https://example.com\">link</a>"), good)

    let bad = html("A [bad](file:///etc/passwd) here.")
    ok("file: gets no anchor", !bad.contains("<a href"), bad)
    ok("…but keeps its label", bad.contains("bad"), bad)

    let mail = html("[write](mailto:a@b.com)")
    ok("mailto allowed", mail.contains("<a href=\"mailto:a@b.com\">"), mail)

    let js = html("[x](javascript:alert(1))")
    ok("javascript: refused", !js.contains("<a href"), js)

    let bare = html("See https://example.com/x for more.")
    ok("bare URL auto-linked", bare.contains("<a href=\"https://example.com/x\">"), bare)
}

// ---------------------------------------------------------------------
section("7. Block structure matches the shared parser")
do {
    let h = html("# One\n## Two\n")
    ok("h1", h.contains("<h1>One</h1>"), h)
    ok("h2", h.contains("<h2>Two</h2>"), h)

    let list = html("- a\n  - b\n- c\n")
    ok("ul opened", list.contains("<ul>"), list)
    ok("nested ul", list.components(separatedBy: "<ul>").count - 1 >= 2, list)
    ok("lists closed", list.components(separatedBy: "<ul>").count
                       == list.components(separatedBy: "</ul>").count, list)

    let ol = html("3. three\n4. four\n")
    ok("ol honours start", ol.contains("<ol start=\"3\">"), ol)

    let quote = html("> quoted\n")
    ok("blockquote", quote.contains("<blockquote>") && quote.contains("</blockquote>"), quote)

    let table = html("| a | b |\n|---|--:|\n| 1 | 2 |\n")
    ok("table head", table.contains("<th>a</th>"), table)
    ok("right alignment carried", table.contains("text-align:right"), table)
    ok("table body", table.contains("<td>1</td>"), table)

    let rule = html("---\n")
    ok("horizontal rule", rule.contains("<hr>"), rule)

    let emph = html("**bold** and *italic*")
    ok("bold", emph.contains("<strong>bold</strong>"), emph)
    ok("italic", emph.contains("<em>italic</em>"), emph)
}

// ---------------------------------------------------------------------
section("8. A printed note names itself once")
do {
    let stripped = NoteHTML.strippingLeadingHeading("# My Note\n\nBody.", matching: "My Note")
    ok("matching H1 dropped", !stripped.contains("# My Note") && stripped.contains("Body."), stripped)

    let kept = NoteHTML.strippingLeadingHeading("# Other\n\nBody.", matching: "My Note")
    ok("different H1 kept", kept.contains("# Other"), kept)

    let none = NoteHTML.strippingLeadingHeading("Just text.", matching: "My Note")
    ok("no heading, no change", none == "Just text.", none)

    let doc = NoteHTML.document(markdown: "# My Note\n\nBody.",
                                metadata: .init(title: "My Note", model: "m", date: nil),
                                dark: false, forPrint: true)
    ok("print doc has one title block", doc.components(separatedBy: "My Note").count - 1 <= 3, "")
    ok("print doc carries the model", doc.contains("sipai-meta") && doc.contains("m"), "")

    let screen = NoteHTML.document(markdown: "# My Note\n\nBody.",
                                   metadata: .init(title: "My Note", model: "m", date: nil),
                                   dark: false, forPrint: false)
    // The CSS always DEFINES .sipai-head; what must be absent on
    // screen is the element itself.
    ok("screen doc has no header block",
       !screen.contains("<header class=\"sipai-head\">"), "")
    ok("screen doc keeps the body H1", screen.contains("<h1>My Note</h1>"), "")
    ok("dark attribute honoured",
       NoteHTML.document(markdown: "x", metadata: .init(title: "t", model: nil, date: nil),
                         dark: true, forPrint: false).contains("data-theme=\"dark\""))
}

// ---------------------------------------------------------------------
section("9. The document is self-contained and offline")
do {
    let doc = NoteHTML.document(markdown: "$x$", metadata: .init(title: "t", model: nil, date: nil),
                                dark: false, forPrint: false)
    ok("references bundled css", doc.contains("href=\"katex.min.css\""), "")
    ok("references bundled js", doc.contains("src=\"katex.min.js\""), "")
    ok("references the staged bootstrap", doc.contains("src=\"sipai-render.js\""), "")
    ok("no remote origin", !doc.contains("http://") && !doc.contains("https://"), "")
    ok("CSP blocks network", doc.contains("connect-src 'none'"), "")
    // The bootstrap rides as a FILE precisely so the CSP can refuse
    // inline script: an escaping failure may put markup on the page
    // but can never run code. Only style-src keeps 'unsafe-inline'.
    ok("CSP refuses inline script",
       doc.contains("script-src file:") && !doc.contains("script-src 'unsafe-inline'"), "")
    ok("no inline script body", !doc.contains("window.__sipaiReady"), "")
    ok("readiness flag published by the bootstrap",
       NoteHTML.renderScript.contains("data-sipai-ready"), "")
}

// ---------------------------------------------------------------------
section("9b. A note cannot forge a shielding sentinel")
do {
    // The sentinels are private-use characters, and a note is untrusted
    // UTF-8 that can simply contain them. Un-sanitized, a forged "D9"
    // sentinel with no real display math subscripted an empty array —
    // a crash on every preview and export of that note, forever.
    let out = NoteHTML.bodyHTML("\u{E010}D9\u{E011}")
    ok("forged display sentinel is inert", !out.contains("sipai-math"), out)
    let out2 = NoteHTML.bodyHTML("before\n\n\u{E010}F3\u{E011}\n\nafter")
    ok("forged fence sentinel is inert", !out2.contains("sipai-code"), out2)
    // An IN-BOUNDS forgery must not duplicate a real span either.
    let out3 = NoteHTML.bodyHTML("$$x^2$$\n\n\u{E010}D0\u{E011}")
    ok("in-bounds forgery cannot replay a real span",
       out3.components(separatedBy: "sipai-math").count - 1 == 1, out3)
    ok("forged sentinel in a quote is inert",
       !NoteHTML.bodyHTML("> \u{E010}D7\u{E011}").contains("sipai-math"), "")
    ok("forged sentinel in a heading is inert",
       !NoteHTML.bodyHTML("# \u{E010}D7\u{E011}").contains("sipai-math"), "")
}

// ---------------------------------------------------------------------
section("10. Page breaks land between blocks")
do {
    // 684pt of printable height per page.
    func layout(_ spans: [(CGFloat, CGFloat)], _ total: CGFloat) -> NotePDFExporter.Layout {
        NotePDFExporter.Layout(total: total, blocks: spans.map { (top: $0.0, bottom: $0.1) })
    }
    // Three blocks, the third starting past the first page boundary.
    let l = layout([(0, 300), (320, 600), (620, 900)], 900)
    let pages = NotePDFExporter.pageRanges(l)
    ok("splits into two pages", pages.count == 2, "\(pages)")
    ok("first page ends in the gap after block 2",
       pages.first.map { $0.upperBound > 600 && $0.upperBound < 620 } ?? false, "\(pages)")
    ok("pages are contiguous",
       pages.count < 2 || pages[0].upperBound == pages[1].lowerBound, "\(pages)")
    ok("last page reaches the end", pages.last?.upperBound == 900, "\(pages)")

    let short = NotePDFExporter.pageRanges(layout([(0, 100)], 100))
    ok("one short block is one page", short.count == 1 && short[0].upperBound == 100, "\(short)")

    // A single block taller than a page has to be sliced rather than
    // looped on.
    let tall = NotePDFExporter.pageRanges(layout([(0, 2000)], 2000))
    ok("oversized block is sliced", tall.count >= 3, "\(tall)")
    ok("slices stay in bounds", tall.allSatisfy { $0.upperBound <= 2000.5 }, "\(tall)")

    ok("empty document yields nothing", NotePDFExporter.pageRanges(layout([], 0)).isEmpty)
}

// ---------------------------------------------------------------------
print("")
if failures == 0 {
    print("All \(checks) note-export checks passed.")
} else {
    print("\(failures) of \(checks) note-export checks FAILED.")
    exit(1)
}
