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

// MARK: - 8. A link to a file on this Mac

print("\n8. File links")

// Codex's own instructions tell its model to cite every file it mentions
// as `[words](/full/path:12)`, the target in angle brackets when the path
// holds spaces; Claude Code writes the relative form. The path is drawn
// after the words, as Codex's terminal prints it, so the destination is
// never hidden behind them — and what is drawn is what find counts.
let audit = "[Detailed audit report](</Users/example-user/My Project/verification/AUDIT.txt>)"
check("a file link draws its words and then its path",
      MarkdownRenderer.plainText(audit)
        == "Detailed audit report (/Users/example-user/My Project/verification/AUDIT.txt)",
      MarkdownRenderer.plainText(audit))
let paren = "[Report (final).md](</Users/example-user/My Project/Report (final).md>)"
check("an angle-bracket target may hold a parenthesis",
      MarkdownRenderer.plainText(paren)
        == "Report (final).md (/Users/example-user/My Project/Report (final).md)",
      MarkdownRenderer.plainText(paren))
check("a relative target with no folder to read it from is shown as text",
      MarkdownRenderer.plainText("[notes](docs/notes.md)") == "notes (docs/notes.md)",
      MarkdownRenderer.plainText("[notes](docs/notes.md)"))
check("a percent-escaped target is shown decoded",
      MarkdownRenderer.plainText("[a](Results/Quantitative%20Analysis.pdf)")
        == "a (Results/Quantitative Analysis.pdf)",
      MarkdownRenderer.plainText("[a](Results/Quantitative%20Analysis.pdf)"))
check("a line number stays in the shown path",
      MarkdownRenderer.plainText("[app.py](/Users/example-user/proj/app.py:12)")
        == "app.py (/Users/example-user/proj/app.py:12)",
      MarkdownRenderer.plainText("[app.py](/Users/example-user/proj/app.py:12)"))
let fileRun = MarkdownInline.attributed(audit).runs.compactMap { $0.link }.first
check("an absolute file link is a link, under the app's own scheme",
      fileRun?.scheme == "sipai-file", fileRun?.absoluteString ?? "no link")
// Web links, anchors and every scheme the gate refuses are unchanged.
check("a web link draws its words alone",
      MarkdownRenderer.plainText("[docs](https://example.com/docs)") == "docs")
check("an anchor is not a file", MarkdownRenderer.plainText("[top](#top)") == "top")
check("a protocol-relative address is not a file", MarkdownRenderer.plainText("[x](//example.com)") == "x")
check("a refused scheme still loses its target",
      MarkdownRenderer.plainText("[open](file:///Applications/Calculator.app)") == "open")
check("an angle-bracket web link becomes a link",
      MarkdownInline.attributed("[docs](<https://example.com/docs>)").runs.compactMap { $0.link }.first?.host
        == "example.com")

// What the folder changes: a path inside it is drawn relative to it, the
// way Codex's terminal prints it; outside it, as written; a relative
// target is read from it. Find counts the same drawing.
let projectFolder = "/Users/example-user/My Project"
func drawnPath(_ md: String, _ folder: String?) -> String { MarkdownRenderer.plainText(md, fileBase: folder) }
check("inside the folder, the path is relative to it",
      drawnPath(audit, projectFolder) == "Detailed audit report (verification/AUDIT.txt)", drawnPath(audit, projectFolder))
check("outside the folder, as written",
      drawnPath("[n](/Users/example-user/other/n.md)", projectFolder) == "n (/Users/example-user/other/n.md)")
check("the folder itself is shown whole, as Codex's terminal shows it",
      drawnPath("[p](/Users/example-user/My Project)", projectFolder) == "p (/Users/example-user/My Project)")
check("a temp folder's /private spelling still reads as inside",
      drawnPath("[t](/private/var/folders/xy/T/run/a.txt)", "/var/folders/xy/T/run") == "t (a.txt)",
      drawnPath("[t](/private/var/folders/xy/T/run/a.txt)", "/var/folders/xy/T/run"))
check("the line number stays after the relative path",
      drawnPath("[app.py](/Users/example-user/My Project/src/app.py:12)", projectFolder) == "app.py (src/app.py:12)")
check("plainText with the folder is what the drawing draws",
      drawnPath(audit, projectFolder) == String(MarkdownInline.attributed(audit, fileBase: projectFolder).characters))
let relativeLink = MarkdownInline.attributed("[notes](docs/notes.md)", fileBase: projectFolder).runs.compactMap { $0.link }.first
check("with a folder, a relative target is a link to the file in it",
      relativeLink.flatMap(FileLinkURL.path(of:)) == "/Users/example-user/My Project/docs/notes.md",
      relativeLink?.absoluteString ?? "no link")
check("without one, it is no link",
      MarkdownInline.attributed("[notes](docs/notes.md)").runs.allSatisfy { $0.link == nil })

// The target, read as the reply wrote it.
check("~ reads from the home folder",
      FileLinkTarget("~/notes/a.md")?.resolvedPath(base: nil) == NSHomeDirectory() + "/notes/a.md")
check("a name and a line number is a file, not a scheme",
      FileLinkTarget("app.py:12")?.path == "app.py")
check("#L12 is a line number too", FileLinkTarget("/x/app.py#L12C4")?.path == "/x/app.py")
check("dot segments fold by spelling alone",
      FileLinkTarget("/a/./b/../c.txt")?.resolvedPath(base: nil) == "/a/c.txt")
check("a scheme names no file", FileLinkTarget("mailto:a@example.com") == nil
      && FileLinkTarget("vscode://file/x") == nil && FileLinkTarget("file:///x") == nil)
for odd in ["/Users/example-user/My Project/a b?.txt", "/tmp/100%/c#d.md", "/tmp/日本語/ノート.md"] {
    let url = FileLinkURL.make(path: odd, missing: false)
    check("the app's link carries ‘\(odd)’ whole", url.flatMap(FileLinkURL.path(of:)) == odd,
          url?.absoluteString ?? "nil")
}

// A link target skips the LaTeX pass: `^2` and `a_b` stay as written.
check("a web link's address keeps its ^2",
      MarkdownInline.attributed("[w](https://example.com/a_b/x^2)").runs.compactMap { $0.link }.first?.path
        == "/a_b/x^2")
check("a file link's path keeps its a_b",
      MarkdownInline.attributed("[w](/tmp/a_b/x_y.md)").runs.compactMap { $0.link }.first
        .flatMap(FileLinkURL.path(of:)) == "/tmp/a_b/x_y.md")
check("the words still go through it", MarkdownRenderer.plainText("[x^2](https://example.com)") == "x²")
check("a sentinel planted in the text is not read back as a target",
      MarkdownRenderer.plainText("a \u{E002}LT0\u{E002} b [w](https://example.com)") == "a LT0 b w")

// Is the file there: asked off the main thread; a missing file is greyed,
// its link says so, its region says "File not found" and takes no click.
let fileTree = FileManager.default.temporaryDirectory.appendingPathComponent("sipai-filelinks-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: fileTree, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: fileTree) }
let presentFile = fileTree.appendingPathComponent("here.txt").path
FileManager.default.createFile(atPath: presentFile, contents: Data("hi\n".utf8))
let goneFile = fileTree.appendingPathComponent("gone.txt").path
_ = FileLinkPresence.shared.state(of: presentFile)
_ = FileLinkPresence.shared.state(of: goneFile)
var presenceHeard = false
let presenceObserver = NotificationCenter.default.addObserver(forName: FileLinkPresence.changed, object: nil,
                                                      queue: .main) { _ in presenceHeard = true }
let presenceDeadline = Date().addingTimeInterval(5)
while FileLinkPresence.shared.state(of: goneFile) != .missing, Date() < presenceDeadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
NotificationCenter.default.removeObserver(presenceObserver)
check("a file that is there reads as present", FileLinkPresence.shared.state(of: presentFile) == .present)
check("a missing one reads as missing", FileLinkPresence.shared.state(of: goneFile) == .missing)
check("finding it missing is announced, so the drawing redraws", presenceHeard)
let missingLink = MarkdownInline.attributed("[gone](\(goneFile))").runs.compactMap { $0.link }.first
check("a missing file's link is marked missing", missingLink.map(FileLinkURL.isMissing) == true)
// How it is drawn: the words in the link colour, underlined; the path in
// the quieter colour, not underlined (SwiftUI underlines a link run only
// when asked); both one link.
let styledRuns = Array(MarkdownInline.attributed("[report](\(presentFile))").runs)
let wordsRun = styledRuns.first
let pathRun = styledRuns.last
check("the words are the link colour, underlined",
      wordsRun?.foregroundColor == ChatDesign.blue && wordsRun?.underlineStyle != nil)
check("the path is the quieter colour, not underlined",
      pathRun?.foregroundColor == ChatDesign.textSecondary && pathRun?.underlineStyle == nil)
check("words and path are one link", styledRuns.count == 2 && wordsRun?.link == pathRun?.link,
      "\(styledRuns.count) runs")
let missingWords = MarkdownInline.attributed("[gone](\(goneFile))").runs.first
check("a missing file's words are greyed, not underlined",
      missingWords?.foregroundColor == ChatDesign.textSecondary && missingWords?.underlineStyle == nil)
let missingBehavior = missingLink.map(FileLinkURL.hotspotBehavior)
check("its region takes no click and says File not found",
      missingBehavior?.follows == false && missingBehavior?.help == "File not found")
let presentBehavior = FileLinkURL.hotspotBehavior(FileLinkURL.make(path: presentFile, missing: false)!)
check("a present file's region follows and shows the full path",
      presentBehavior.follows && presentBehavior.help == presentFile)
check("a web link's region is left as it was",
      FileLinkURL.hotspotBehavior(URL(string: "https://example.com")!) == LinkHotspotBehavior())

// What a click does, decided at click time over real files: a document
// opens in its default app; whatever would run, install or mount is only
// shown in Finder; a folder opens; text macOS has no viewer for opens as
// text.
func makeFile(_ name: String, _ body: String = "text\n", executable: Bool = false) -> String {
    let path = fileTree.appendingPathComponent(name).path
    FileManager.default.createFile(atPath: path, contents: Data(body.utf8),
                                   attributes: executable ? [.posixPermissions: 0o755] : nil)
    return path
}
func clickAction(_ path: String) -> String {
    switch FileLinkAction.decide(path: path) {
    case .open: return "open"
    case .openAsText: return "text"
    case .reveal: return "reveal"
    case .showFolder: return "folder"
    case .missing: return "missing"
    }
}
for name in ["report.txt", "notes.md", "data.json", "table.csv", "page.html"] {
    check("\(name) opens in its default app", clickAction(makeFile(name)) == "open", clickAction(makeFile(name)))
}
for name in ["run.py", "go.sh", "start.command", "app.js"] {
    check("\(name) is shown in Finder, never opened", clickAction(makeFile(name)) == "reveal", clickAction(makeFile(name)))
}
check("an executable with no extension is shown in Finder",
      clickAction(makeFile("tool", "#!/bin/sh\necho hi\n", executable: true)) == "reveal")
check("a configuration profile opens as text, never in its installer",
      clickAction(makeFile("p.mobileconfig", "<?xml version=\"1.0\"?><plist></plist>\n")) == "text")
check("a .ts file (an MPEG-2 stream to macOS) that holds text opens as text",
      clickAction(makeFile("main.ts", "export const x = 1\n")) == "text")
check("text of a type macOS does not know opens as text", clickAction(makeFile("lib.rs", "fn main() {}\n")) == "text")
check("a binary of a type macOS does not know is shown in Finder",
      clickAction(makeFile("blob.bin1", "\u{0}\u{1}\u{2}")) == "reveal")
check("a zip is shown in Finder", clickAction(makeFile("a.zip", "PK\u{3}\u{4}")) == "reveal")
let appBundle = fileTree.appendingPathComponent("Fake.app/Contents/MacOS")
try? FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: true)
check("an app is shown in Finder, never launched", clickAction(fileTree.appendingPathComponent("Fake.app").path) == "reveal")
let plainFolder = fileTree.appendingPathComponent("plain folder")
try? FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)
check("a folder opens in Finder", clickAction(plainFolder.path) == "folder")
check("a missing file is missing", clickAction(goneFile) == "missing")
let linkToApp = fileTree.appendingPathComponent("innocent.txt")
try? FileManager.default.createSymbolicLink(at: linkToApp, withDestinationURL: fileTree.appendingPathComponent("Fake.app"))
check("a link named like text that leads to an app is shown in Finder", clickAction(linkToApp.path) == "reveal")
let linkToText = fileTree.appendingPathComponent("alias.txt")
try? FileManager.default.createSymbolicLink(at: linkToText, withDestinationURL: URL(fileURLWithPath: presentFile))
check("a link to a text file opens it", clickAction(linkToText.path) == "open")

// MARK: - Verdict

print("")
if failures == 0 {
    print("PASS — counter and highlights agree")
    exit(0)
} else {
    print("FAIL — \(failures) check(s) failed")
    exit(1)
}
