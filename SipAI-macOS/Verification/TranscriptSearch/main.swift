// Headless checks for the search feature's one load-bearing rule:
//
//     the counter and the highlights must describe the same matches.
//
// "3 of 47" is only worth printing if match 3 is a thing the reader can
// see and 47 is how many there are. Everything below pins one half of
// that: what `MarkdownRenderer.plainText` counts in (the DRAWN text,
// not the source), and how `SearchHighlightSlot` splits a row's matches
// across the pieces that draw them.
//
// Section 7 pins a different property of the same renderer, kept here
// because this harness already compiles the real one: which URL schemes
// a rendered link may carry. That rule fails silently in both
// directions — a refused link simply is not clickable, and a widened
// set simply is — so nothing but a check like this reports on it.
//
// Run after touching SearchMatching.swift or MarkdownRenderer.swift.
//
//   ./run.sh

import Foundation
import SwiftUI

var failures = 0

func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func equal<T: Equatable>(_ label: String, _ got: T, _ want: T) {
    check(label, got == want, "got \(got), want \(want)")
}

// MARK: - 1. Matching semantics

print("\n1. SearchMatching")

equal("plain count", SearchMatching.count(of: "the", in: "the theme of the day"), 3)
equal("case-insensitive", SearchMatching.count(of: "THE", in: "The theme"), 2)
equal("diacritic-insensitive",
      SearchMatching.count(of: "cafe", in: "café and cafe"), 2)
equal("empty query matches nothing",
      SearchMatching.count(of: "", in: "anything"), 0)
equal("empty text", SearchMatching.count(of: "x", in: ""), 0)

// Non-overlapping, left to right — the k-th match must mean the same
// thing to the counter and to the highlighter.
equal("non-overlapping", SearchMatching.count(of: "aa", in: "aaaa"), 2)
let ranges = SearchMatching.occurrences(of: "aa", in: "aaaa")
check("occurrences are disjoint and ordered",
      ranges.count == 2 && ranges[0].upperBound <= ranges[1].lowerBound)

// A repeated single character used to be the shape that could spin the
// cursor forever if the advance were ever computed wrong.
equal("dense repeats terminate",
      SearchMatching.count(of: "a", in: String(repeating: "a", count: 500)), 500)

// MARK: - 2. Snippets

print("\n2. Snippets")

// The returned range must index the RETURNED string. It is built by
// assembling pieces, and a String.Index taken before an append points
// into a string that no longer exists — the bug this pins.
let long = String(repeating: "filler ", count: 40)
    + "needle" + String(repeating: " trailing", count: 40)
if let snip = SearchMatching.snippet(of: "needle", in: long) {
    check("snippet range is valid in the snippet",
          snip.match.lowerBound >= snip.text.startIndex
              && snip.match.upperBound <= snip.text.endIndex)
    equal("snippet range covers the match",
          String(snip.text[snip.match]).lowercased(), "needle")
    check("snippet is elided on both sides",
          snip.text.hasPrefix("…") && snip.text.hasSuffix("…"),
          snip.text)
} else {
    failures += 1
    print("  FAIL snippet returned nil for a text that matches")
}

if let head = SearchMatching.snippet(of: "start", in: "start of the line here") {
    check("no leading ellipsis at the start of the text",
          !head.text.hasPrefix("…"), head.text)
    equal("range still covers the match",
          String(head.text[head.match]), "start")
}

// A match inside a wrapped / indented block must come back as one line.
if let flat = SearchMatching.snippet(of: "needle", in: "a\n\tb needle c\nd") {
    check("snippet collapses newlines and tabs",
          !flat.text.contains("\n") && !flat.text.contains("\t"), flat.text)
}

check("no snippet without a match",
      SearchMatching.snippet(of: "absent", in: "nothing here") == nil)

// MARK: - 3. What search counts in: DRAWN text, not source

print("\n3. MarkdownRenderer.plainText")

equal("bold markers are not searchable",
      SearchMatching.count(of: "*", in: MarkdownRenderer.plainText("**bold**")), 0)
equal("the bold WORD is",
      SearchMatching.count(of: "bold", in: MarkdownRenderer.plainText("**bold**")), 1)
equal("heading hashes are not searchable",
      SearchMatching.count(of: "#", in: MarkdownRenderer.plainText("# Title")), 0)
equal("bullet markers are not searchable",
      SearchMatching.count(of: "-", in: MarkdownRenderer.plainText("- item")), 0)

// Inline code reaches the screen byte-exact — the shielding rule the
// renderer's header is about. Searching an identifier must find it.
equal("inline code is searchable verbatim",
      SearchMatching.count(of: "session_id",
                           in: MarkdownRenderer.plainText("call `session_id` now")), 1)
check("inline code is not LaTeX-mangled",
      MarkdownRenderer.plainText("`tool_use`").contains("tool_use"),
      MarkdownRenderer.plainText("`tool_use`"))

// A fenced block's CONTENT is searched; its language caption is a
// label, and `CodeBlockView` does not highlight it — so counting it
// would be a match with no highlight.
let fenced = """
```swift
let swiftValue = 1
```
"""
equal("code block body is searched",
      SearchMatching.count(of: "swiftValue", in: MarkdownRenderer.plainText(fenced)), 1)
equal("the language caption is not",
      SearchMatching.count(of: "swift", in: MarkdownRenderer.plainText(fenced)), 1)

// Blocks are joined by a newline, so no single-line query can straddle
// two of them — which is what lets each block take a simple running
// offset.
let twoBlocks = "alpha\n\nbeta"
equal("no match straddles a block boundary",
      SearchMatching.count(of: "alphabeta", in: MarkdownRenderer.plainText(twoBlocks)), 0)

// Tables: every cell is drawn, so every cell is counted — header row
// first, then body rows, which is the order the grid draws them.
let table = """
| Name | Value |
| --- | --- |
| alpha | 1 |
| beta | 2 |
"""
let tableText = MarkdownRenderer.plainText(table)
equal("table header cells are searched",
      SearchMatching.count(of: "Name", in: tableText), 1)
equal("table body cells are searched",
      SearchMatching.count(of: "alpha", in: tableText), 1)
check("table cells are newline-separated, not run together",
      !tableText.contains("alpha1"), tableText)

// Repeat reads must agree — `plainText` is cached, and a cache that
// answered differently on a hit would desynchronise the counter from
// the highlights on the second render pass.
equal("cached read agrees with the first",
      MarkdownRenderer.plainText(table), tableText)

// MARK: - 4. Ordinal arithmetic

print("\n4. Highlight slots")

func backgrounds(_ attr: AttributedString) -> [Color?] {
    attr.runs.map { $0.backgroundColor }
}

// A row with three matches, the second of which is the transcript's
// active one.
let slot = SearchHighlightSlot(
    highlight: SearchHighlight(query: "x", activeOrdinal: 4),
    base: 3)
var attr = AttributedString("x-x-x")
let applied = attr.applySearchHighlight(slot)
equal("every occurrence is tinted", applied, 3)
let tinted = backgrounds(attr).compactMap { $0 }
equal("three tinted runs", tinted.count, 3)
equal("exactly one is the ACTIVE shade",
      tinted.filter { $0 == SipDesign.searchMatchActive }.count, 1)
check("the active one is the second (base 3 + 1 == 4)",
      tinted.count == 3 && tinted[1] == SipDesign.searchMatchActive)

// The same row when the active match belongs to some other row.
var elsewhere = AttributedString("x-x-x")
elsewhere.applySearchHighlight(SearchHighlightSlot(
    highlight: SearchHighlight(query: "x", activeOrdinal: 99), base: 3))
equal("no active shade when the active match is elsewhere",
      backgrounds(elsewhere).compactMap { $0 }
          .filter { $0 == SipDesign.searchMatchActive }.count, 0)

// Inactive costs nothing and changes nothing.
var untouched = AttributedString("x-x-x")
equal("inactive slot tints nothing",
      untouched.applySearchHighlight(.inactive), 0)
check("inactive slot leaves the string alone",
      backgrounds(untouched).allSatisfy { $0 == nil })

// `advanced(by:)` is what walks a row's pieces (chip title → summary →
// body rows → result rows) and a markdown row's blocks.
let base = SearchHighlightSlot(
    highlight: SearchHighlight(query: "q", activeOrdinal: 7), base: 5)
equal("advancing moves only the base", base.advanced(by: 2).base, 7)
equal("advancing preserves the query", base.advanced(by: 2).query, "q")
equal("advancing preserves the active ordinal",
      base.advanced(by: 2).highlight.activeOrdinal, 7)

// Chained advances across pieces must land where a single advance by
// the total would — the property the piece walk depends on.
equal("chained advances compose",
      base.advanced(by: 2).advanced(by: 3).base,
      base.advanced(by: 5).base)

// Diacritic folding must survive into the highlighter, or a query that
// COUNTS 1 would tint 0.
var accented = AttributedString("café")
equal("highlighter folds diacritics like the counter does",
      accented.applySearchHighlight(SearchHighlightSlot(
          highlight: SearchHighlight(query: "cafe", activeOrdinal: 0), base: 0)),
      SearchMatching.count(of: "cafe", in: "café"))

// MARK: - 5. Counter/highlight agreement, end to end

print("\n5. Counter and highlighter agree")

// For every source and query below, what the find bar would COUNT for
// the row must equal what the renderer would TINT across that row's
// blocks. Both sides are exercised through their real implementations.
let corpus: [(String, String)] = [
    ("plain paragraph with needle in it", "needle"),
    ("**bold needle** and _italic needle_", "needle"),
    ("# needle heading\n\nbody needle", "needle"),
    ("- needle one\n- needle two\n- three", "needle"),
    ("> quoted needle here", "needle"),
    ("```\nneedle in code\n```", "needle"),
    ("| a | needle |\n| --- | --- |\n| needle | b |", "needle"),
    ("mixed `needle` and **needle** and plain needle", "needle"),
    ("nothing to find here", "needle"),
    ("Needle NEEDLE needle", "needle"),
]
for (source, query) in corpus {
    let counted = SearchMatching.count(of: query,
                                       in: MarkdownRenderer.plainText(source))
    // The highlighter's view of the same row: tint each drawn piece and
    // total what it reports.
    var tintedTotal = 0
    var running = SearchHighlightSlot(
        highlight: SearchHighlight(query: query, activeOrdinal: 0), base: 0)
    for piece in MarkdownRenderer.plainText(source).components(separatedBy: "\n") {
        var a = AttributedString(piece)
        let n = a.applySearchHighlight(running)
        tintedTotal += n
        running = running.advanced(by: n)
    }
    equal("counted == tinted for “\(query)” in \(source.prefix(28))…",
          tintedTotal, counted)
}

// MARK: - 6. The counter starts at 1

// Top-level code already runs on the main thread; this just says so to
// the compiler, since TranscriptFindState is @MainActor.
MainActor.assumeIsolated {
    print("\n6. Find state")

    let find = TranscriptFindState()
    let rows = [
        FindableRow(id: UUID(), text: "needle one"),
        FindableRow(id: UUID(), text: "nothing"),
        FindableRow(id: UUID(), text: "needle two needle three"),
    ]
    find.open()
    find.query = "needle"
    find.refresh { rows }

    equal("all matches found across rows", find.matches.count, 3)
    // The reported bug: a fresh query opened on "3 of 3" — the counter
    // reading as though it had already been walked to the end.
    equal("a fresh query starts at the FIRST match", find.activeIndex, 0)
    equal("counter reads 1 of N", find.counterText, "1 of 3")

    find.next()
    equal("next steps forward", find.counterText, "2 of 3")
    find.next()
    equal("next again", find.counterText, "3 of 3")
    find.next()
    equal("next wraps to the first", find.counterText, "1 of 3")
    find.previous()
    equal("previous wraps to the last", find.counterText, "3 of 3")

    // Row bases are what the highlighter splits a row's matches on.
    equal("first row's base", find.rowBases[rows[0].id], 0)
    equal("third row's base is past the first row's match",
          find.rowBases[rows[2].id], 1)
    equal("a row with no matches still has a base",
          find.rowBases[rows[1].id], 1)

    // A NEW query resets to the first match, not to wherever the last
    // one had been walked to.
    find.next()  // move off the first match
    find.query = "two"
    find.refresh { rows }
    equal("a changed query starts at the first match again",
          find.counterText, "1 of 1")

    // No matches must not read as a position.
    find.query = "absent"
    find.refresh { rows }
    equal("empty result set says so", find.counterText, "No results")
    check("no active match to jump to", find.activeMatch == nil)
    check("an inactive row gets an inactive slot",
          !find.slot(forRow: rows[0].id).isActive)

    // Closing forgets everything — a query left standing would count
    // matches in a conversation nobody asked it about.
    find.query = "needle"
    find.refresh { rows }
    find.close()
    equal("closing clears the matches", find.matches.count, 0)
    check("closing clears the row bases", find.rowBases.isEmpty)

    // A closed bar never runs its row builder — the property that keeps
    // all of this off the streaming path.
    var built = false
    find.refresh { built = true; return rows }
    check("a closed find never builds its rows", !built)
}

// MARK: - 7. Which links the renderer is willing to make clickable

print("\n7. MarkdownInline.safeLink")

// Nothing the renderer draws is trusted. A model's reply, a note, and
// above all an agent TOOL RESULT — whatever the agent's last web fetch
// returned — all arrive here as markdown. In `[label](url)` the label
// is arbitrary text, so the destination is invisible until after the
// click, and macOS hands an unrecognised scheme to whichever app claims
// it with no prompt of its own.
//
// A refused link keeps its LABEL and loses only its destination, which
// is what every markdown host does with a scheme it will not follow.

for allowed in ["https://example.com/x",
                "http://localhost:11434/v1",
                "HTTPS://Example.COM",          // scheme match is case-insensitive
                "mailto:someone@example.com"] {
    check("\(allowed) stays clickable",
          MarkdownInline.safeLink(allowed) != nil)
}

// Each of these does something on this Mac if the system is handed it:
// `file:` launches an app bundle or mounts an image, `smb:` offers
// credentials to a remote host, `shortcuts:` runs a saved workflow, and
// an app's own scheme drives that app.
for refused in ["file:///Applications/Calculator.app",
                "file:///Users/me/Downloads/installer.dmg",
                "javascript:alert(1)",
                "smb://attacker.example/share",
                "ssh://root@attacker.example",
                "shortcuts://run-shortcut?name=Wipe",
                "x-apple-helpbook://x",
                "data:text/html;base64,PHNjcmlwdD4=",
                "vnc://attacker.example",
                "ftp://attacker.example/x"] {
    check("\(refused) is not clickable",
          MarkdownInline.safeLink(refused) == nil)
}

// A scheme-less or unparseable target is not a link either.
for junk in ["/Users/me/notes.md", "not a url", "", "   ", "//example.com"] {
    check("‘\(junk)’ is not clickable", MarkdownInline.safeLink(junk) == nil)
}

// End to end through the renderer, which is where it actually matters:
// a refused destination must not take the visible text with it.
let disguised = "[https://docs.example.com](file:///Applications/Calculator.app)"
check("a refused link keeps its label on screen",
      MarkdownRenderer.plainText(disguised).contains("https://docs.example.com"),
      MarkdownRenderer.plainText(disguised))
check("and does not print the refused target",
      !MarkdownRenderer.plainText(disguised).contains("Calculator.app"),
      MarkdownRenderer.plainText(disguised))

// MARK: - Verdict

print("")
if failures == 0 {
    print("PASS — counter and highlights agree")
    exit(0)
} else {
    print("FAIL — \(failures) check(s) failed")
    exit(1)
}
