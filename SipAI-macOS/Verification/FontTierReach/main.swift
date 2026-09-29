// Headless check of the font-size tier's reach and of the transcript's
// vertical rhythm.
//
// Four passes:
//
//   1. The rules, against the REAL DesignSystem.swift: the design-size
//      convention lands exactly on the design size at Default; the
//      sidebar helpers, the transcript's content scale and `scaled`
//      agree at every tier; the frame ratio and the control-size step
//      are monotonic; the transcript gap multiplier is exactly 1 at
//      Default and grows with the tier.
//
//   2. The typography helper on a bare NSTextView (TextKit lays out
//      without a window): the laid-out height grows with the point size
//      and again with the line spacing, the typing attributes carry
//      both, a re-apply with the same values is a no-op, and the
//      spacing survives the host replacing the whole string — which is
//      what `updateNSView` does on every binding change.
//
//   3. The rendered rhythm, through the REAL `MarkdownRenderer.render`
//      hosted in an NSHostingView at a fixed width with the environment
//      set per tier: the gap between two paragraphs, and between two
//      list items, measured as height(both) − height(each). Against
//      the wrapped-line spacing the renderer applies inside a block,
//      the paragraph gap must stay larger and the list gap no smaller —
//      the inversion the fix exists for. Default's gaps must equal the
//      pre-fix constants, so that tier is pinned unchanged.
//
//  3b. Settings → Help, through its REAL answer, card and rhythm
//      (extracted from SettingsView.swift): an answer's line pitch is the
//      tier's own for 13 pt prose at every tier, and a card pads its
//      question by at least a wrapped line's gap. A fixed 3 pt spacing
//      held every answer to single spacing in Large text mode.
//
//   4. Structural, over the REAL view files: every representable text
//      field declares its point size with no default (a fifth text view
//      cannot opt out silently), applies the helper from both hooks and
//      never reads `layoutManager` (which drops a text view into
//      TextKit 1 for good); no literal point size survives in the
//      surfaces the tier now reaches; the two hosts' message stacks no
//      longer carry a constant gap; and the help sentence promising the
//      new reach exists, with its Chinese value.
//
//   5. Rendered, in a window (SKIP without a GUI session): a text view
//      styled by the real helper with the tier's line spacing, a word
//      marked misspelled on its middle line, drawn to a bitmap — the
//      red dots must sit within 3 px under that word's baseline. Under
//      TextKit 1 the same view draws them at the bottom of the line
//      fragment, in the gap; run.sh maps a window-server hang to SKIP.
//
// Nothing here is part of the app target: this directory sits outside
// SipAI/, so these files are never compiled into the product.

import SwiftUI
import AppKit

let sourceRoot = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

var failures: [String] = []

func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    if ok {
        print("  ok    \(label)")
    } else {
        let extra = detail()
        print("  FAIL  \(label)\(extra.isEmpty ? "" : " — \(extra)")")
        failures.append(label)
    }
}

func fmt(_ v: CGFloat) -> String { String(format: "%.2f", v) }

// MARK: - Pass 1: the rules

print("1. the rules (real DesignSystem.swift)")

let tiers = FontTier.allCases
check(tiers.count == 4, "four tiers", "\(tiers.count)")
check(FontTier.standard.scale != 1.0,
      "Default is not the unit scale — the normalisation exists for a reason")

for base: CGFloat in [9, 10.5, 11, 12, 13, 14, 16] {
    let atDefault = SipFont.scaled(base, FontTier.standard.scale)
    check(abs(atDefault - base) < 0.0001,
          "scaled(\(base)) at Default is exactly \(base)", fmt(atDefault))
}
for t in tiers {
    let s = t.scale
    check(abs(SipFont.sidebarRow(s) - SipFont.scaled(13, s)) < 0.0001,
          "\(t.rawValue): sidebarRow == scaled(13)")
    check(abs(SipFont.sidebarHeader(s) - SipFont.scaled(12, s)) < 0.0001,
          "\(t.rawValue): sidebarHeader == scaled(12)")
    check(abs(SipFont.sidebarHint(s) - SipFont.scaled(11, s)) < 0.0001,
          "\(t.rawValue): sidebarHint == scaled(11)")
    check(abs(SipFont.contentScale(s) * SipFont.transcriptBodyBase - SipFont.sidebarRow(s)) < 0.0001,
          "\(t.rawValue): transcript body (14 × contentScale) == sidebarRow")
    check(abs(SipFont.ratio(s) * 30 - SipFont.scaled(30, s)) < 0.0001,
          "\(t.rawValue): ratio × frame == scaled(frame)")
}
check(abs(SipFont.ratio(FontTier.standard.scale) - 1) < 0.0001, "ratio(Default) == 1")
check(abs(SipFont.contentRatio(SipFont.contentScale(FontTier.standard.scale)) - 1) < 0.0001,
      "contentRatio(Default's content scale) == 1")
for t in tiers {
    check(abs(SipFont.contentRatio(SipFont.contentScale(t.scale)) - SipFont.ratio(t.scale)) < 0.0001,
          "\(t.rawValue): contentRatio inside a re-scope == ratio outside it")
}

let scales = tiers.map(\.scale)
check(zip(scales, scales.dropFirst()).allSatisfy { $0 < $1 }, "tier scales strictly increase")
let factors = tiers.map(\.lineSpacingFactor)
check(zip(factors, factors.dropFirst()).allSatisfy { $0 < $1 }, "line-spacing factors strictly increase")

let sizes = tiers.map { SipFont.controlSize($0.scale) }
check(sizes[0] == .small, "Small → .small controls")
check(sizes[1] == .regular, "Default → .regular controls")
check(sizes[2] == .regular, "Larger → .regular controls")
check(sizes[3] == .large, "Large text mode → .large controls")

let gapDefault = SipFont.transcriptGapScale(
    fontScale: SipFont.contentScale(FontTier.standard.scale),
    lineSpacingFactor: FontTier.standard.lineSpacingFactor)
check(abs(gapDefault - 1) < 0.0001, "transcriptGapScale(Default) == 1 exactly", fmt(gapDefault))
let gaps = tiers.map {
    SipFont.transcriptGapScale(fontScale: SipFont.contentScale($0.scale),
                               lineSpacingFactor: $0.lineSpacingFactor)
}
check(zip(gaps, gaps.dropFirst()).allSatisfy { $0 < $1 },
      "transcriptGapScale strictly increases with the tier",
      gaps.map(fmt).joined(separator: " / "))
check(gaps[3] > 2, "Large text mode more than doubles the gaps", fmt(gaps[3]))
check(SipFont.lineHeight(14) > 14 && SipFont.lineHeight(14) < 20,
      "lineHeight(14) is a plausible system-font line", fmt(SipFont.lineHeight(14)))
print("        gap multipliers: " + zip(tiers, gaps).map { "\($0.rawValue) \(fmt($1))" }.joined(separator: ", "))

// MARK: - Pass 2: the typography helper on a bare NSTextView

print("2. TextInputTypography on a bare NSTextView")

let long = "The quick brown fox jumps over the lazy dog and keeps on running across the wide open field until the sun goes down behind the hills."

func laidOutHeight(_ tv: NSTextView) -> CGFloat {
    guard let lm = tv.layoutManager, let tc = tv.textContainer else { return -1 }
    lm.ensureLayout(for: tc)
    return lm.usedRect(for: tc).height
}

// The helper is @MainActor (it drives an NSTextView); top-level code
// here is not, so the pass runs inside an assumed-isolated block.
MainActor.assumeIsolated {
    let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 160, height: 40))
    tv.isRichText = false
    tv.string = long
    check(TextInputTypography.apply(pointSize: 14, lineSpacing: 0, to: tv),
          "first apply reports a change")
    let h14 = laidOutHeight(tv)
    check(!TextInputTypography.apply(pointSize: 14, lineSpacing: 0, to: tv),
          "re-apply with the same values reports no change")
    check(abs(laidOutHeight(tv) - h14) < 0.01, "…and lays out identically")
    check(TextInputTypography.apply(pointSize: 18, lineSpacing: 0, to: tv),
          "a larger point size reports a change")
    let h18 = laidOutHeight(tv)
    check(h18 > h14, "…and the text lays out taller", "\(fmt(h14)) → \(fmt(h18))")
    check(tv.font?.pointSize == 18, "the view's font follows", "\(tv.font?.pointSize ?? -1)")
    check(TextInputTypography.apply(pointSize: 18, lineSpacing: 10, to: tv),
          "added line spacing reports a change")
    let h18s = laidOutHeight(tv)
    check(h18s > h18 + 10, "…and the text lays out taller again", "\(fmt(h18)) → \(fmt(h18s))")
    check((tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.lineSpacing == 10,
          "typing attributes carry the line spacing")
    check((tv.typingAttributes[.font] as? NSFont)?.pointSize == 18,
          "typing attributes carry the font")
    check(tv.defaultParagraphStyle?.lineSpacing == 10, "default paragraph style carries it")
    tv.string = long + " " + long
    let hReplaced = laidOutHeight(tv)
    check(hReplaced > h18s, "a replaced string lays out taller", fmt(hReplaced))
    tv.string = long
    check(abs(laidOutHeight(tv) - h18s) < 0.01,
          "…and the original text comes back at the SPACED height — the spacing survived `string =`",
          "\(fmt(laidOutHeight(tv))) vs \(fmt(h18s))")
    check(!TextInputTypography.apply(pointSize: 18, lineSpacing: 10, to: tv),
          "…and a re-apply after the replacement is still a no-op")
    // An EMPTY box is the composer's usual state, and `updateNSView`
    // re-applies per keystroke: a font that did not read back from an
    // empty view would make every one of those a real write.
    let empty = NSTextView(frame: NSRect(x: 0, y: 0, width: 160, height: 40))
    empty.isRichText = false
    check(TextInputTypography.apply(pointSize: 15, lineSpacing: 4, to: empty),
          "empty box: first apply reports a change")
    check(!TextInputTypography.apply(pointSize: 15, lineSpacing: 4, to: empty),
          "empty box: re-apply is a no-op")
    empty.string = long
    let typedStyle = empty.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    check(typedStyle?.lineSpacing == 4, "text typed into an empty box carries the spacing",
          "\(typedStyle?.lineSpacing ?? -1)")
    check(empty.font?.pointSize == 15, "…and the font")
    let mono = NSTextView(frame: NSRect(x: 0, y: 0, width: 160, height: 40))
    mono.isRichText = false
    mono.string = "code"
    TextInputTypography.apply(pointSize: 13, lineSpacing: 0, monospaced: true, to: mono)
    check(mono.font?.isFixedPitch == true, "monospaced request yields a fixed-pitch font")
    // A stock view comes up in Helvetica 12; asking for the system font
    // at exactly 12 must still swap the face.
    let stock = NSTextView(frame: NSRect(x: 0, y: 0, width: 160, height: 40))
    stock.isRichText = false
    let stockSize = stock.font?.pointSize ?? 12
    check(TextInputTypography.apply(pointSize: stockSize, lineSpacing: 0, to: stock),
          "a size-matched request still replaces the stock face")
    check(stock.font?.fontName == NSFont.systemFont(ofSize: stockSize).fontName,
          "…with the system font", stock.font?.fontName ?? "nil")
}

// MARK: - Pass 3: the rendered rhythm through the real renderer

print("3. rendered gaps through the real MarkdownRenderer, per tier")

let renderWidth: CGFloat = 300

func hostedHeight<V: View>(_ view: V) -> CGFloat {
    let host = NSHostingView(rootView: view.frame(width: renderWidth))
    host.frame = NSRect(x: 0, y: 0, width: renderWidth, height: 0)
    return host.fittingSize.height
}

func renderedHeight(_ markdown: String, tier: FontTier) -> CGFloat {
    hostedHeight(MarkdownRenderer.render(markdown)
        .environment(\.sipFontScale, SipFont.contentScale(tier.scale))
        .environment(\.sipLineSpacingFactor, tier.lineSpacingFactor))
}

/// One line of body text at the tier, as SwiftUI lays it out — the
/// height every one-line block below contains, whatever the renderer
/// wraps around it.
func singleLine(tier: FontTier) -> CGFloat {
    hostedHeight(Text(verbatim: "x")
        .font(.system(size: SipFont.transcriptBodyBase * SipFont.contentScale(tier.scale)))
        .fixedSize(horizontal: false, vertical: true))
}

/// The VISIBLE space between two one-line blocks: two of them minus one
/// of them minus the line the second one adds. Padding a block carries
/// on its own outside is counted, a spacer between them is counted, and
/// the text itself is not — so this is the distance the eye reads.
func visibleGap(_ one: String, _ two: String, tier: FontTier) -> CGFloat {
    renderedHeight(two, tier: tier) - renderedHeight(one, tier: tier) - singleLine(tier: tier)
}

/// The hosting view reports whole points, so a gap read through it is
/// exact to ±1. The inversion this pass exists for is 4 pt at Larger
/// and 18 pt at Large text mode — far outside that.
let rounding: CGFloat = 1.0

for t in tiers {
    let bodySize = SipFont.transcriptBodyBase * SipFont.contentScale(t.scale)
    // The renderer's own rule for the gap between wrapped lines of one
    // block (`.lineSpacing(14 * fontScale * lineSpacingFactor)`); pass 4
    // pins that the source still states it, so this restatement cannot
    // drift from it unnoticed.
    let wrappedGap = bodySize * t.lineSpacingFactor
    let paragraphGap = visibleGap("x", "x\n\nx", tier: t)
    let bulletGap = visibleGap("- x", "- x\n- x", tier: t)
    let numberedGap = visibleGap("1. x", "1. x\n2. x", tier: t)
    let quoteGap = visibleGap("> x", "> x\n> x", tier: t)
    print("        \(t.rawValue): wrapped \(fmt(wrappedGap))  paragraph \(fmt(paragraphGap))  bullet \(fmt(bulletGap))  numbered \(fmt(numberedGap))  quote \(fmt(quoteGap))")
    check(paragraphGap > wrappedGap + rounding,
          "\(t.rawValue): paragraphs sit farther apart than wrapped lines",
          "\(fmt(paragraphGap)) vs \(fmt(wrappedGap))")
    check(bulletGap >= wrappedGap - rounding,
          "\(t.rawValue): bullets sit no closer than wrapped lines",
          "\(fmt(bulletGap)) vs \(fmt(wrappedGap))")
    check(abs(numberedGap - bulletGap) < rounding,
          "\(t.rawValue): numbered items keep the bullet gap")
    check(quoteGap >= wrappedGap - rounding,
          "\(t.rawValue): blockquote lines sit no closer than wrapped lines",
          "\(fmt(quoteGap)) vs \(fmt(wrappedGap))")
    if t == .standard {
        // The pre-fix constants: paragraph 2 + 6 + 2, list 1 + 1 —
        // floored at the wrapped-line gap, which is 0.3 pt more.
        check(abs(paragraphGap - 10) < rounding,
              "Default paragraph gap is the design's 10 pt", fmt(paragraphGap))
        check(abs(bulletGap - max(2, wrappedGap)) < rounding,
              "Default bullet gap is the design's 2 pt, floored at the wrapped-line gap",
              fmt(bulletGap))
    }
}
let gapSmall = visibleGap("x", "x\n\nx", tier: .small)
let gapXL = visibleGap("x", "x\n\nx", tier: .xlarge)
check(gapXL > gapSmall * 2, "Large text mode's paragraph gap is over twice Small's",
      "\(fmt(gapSmall)) → \(fmt(gapXL))")

// MARK: - Pass 3b: the Help section's rhythm, rendered

print("3b. Settings → Help, rendered per tier (real HelpRhythm / FAQAnswer / FAQCard)")

/// HelpPane sets the tier's line spacing ONCE at its root; these hosts
/// put the same modifier around the real answer and card, and pass 4
/// pins that the pane's root still spells it — so what is measured is
/// what the pane draws.
struct HelpAnswerInPane: View {
    let text: String
    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.sipLineSpacingFactor) private var lineSpacingFactor
    var body: some View {
        FAQAnswer(text: text)
            .lineSpacing(HelpRhythm.lineSpacing(fontScale, lineSpacingFactor))
    }
}

struct HelpClosedCardInPane: View {
    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.sipLineSpacingFactor) private var lineSpacingFactor
    var body: some View {
        FAQCard(question: "Q", isOpen: false, toggle: {}) { EmptyView() }
            .lineSpacing(HelpRhythm.lineSpacing(fontScale, lineSpacingFactor))
    }
}

/// The tier's own rule for 13 pt design-size prose, drawn directly: the
/// reference an answer is held to, measured the same way so the hosting
/// view's whole-point rounding falls on both alike.
struct TierProse: View {
    let text: String
    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.sipLineSpacingFactor) private var lineSpacingFactor
    var body: some View {
        Text(verbatim: text)
            .sipFont(13)
            .lineSpacing(SipFont.lineSpacing(13, fontScale: fontScale, lineSpacingFactor: lineSpacingFactor))
            .fixedSize(horizontal: false, vertical: true)
    }
}

func atTier<V: View>(_ view: V, _ t: FontTier) -> CGFloat {
    hostedHeight(view
        .environment(\.sipFontScale, t.scale)
        .environment(\.sipLineSpacingFactor, t.lineSpacingFactor))
}

/// Baseline to baseline inside one paragraph: three lines minus one,
/// over the two steps between them.
func pitch<V: View>(_ make: (String) -> V, _ t: FontTier) -> CGFloat {
    (atTier(make("x\nx\nx"), t) - atTier(make("x"), t)) / 2
}

for t in tiers {
    let answerPitch = pitch({ HelpAnswerInPane(text: $0) }, t)
    let rulePitch = pitch({ TierProse(text: $0) }, t)
    let wrappedGap = SipFont.lineSpacing(13, fontScale: t.scale, lineSpacingFactor: t.lineSpacingFactor)
    let questionLine = atTier(Text(verbatim: "Q").sipFont(13, weight: .medium), t)
    let questionPad = (atTier(HelpClosedCardInPane(), t) - questionLine) / 2
    print("        \(t.rawValue): answer pitch \(fmt(answerPitch)) (the tier's \(fmt(rulePitch)))  question pad \(fmt(questionPad))  wrapped-line gap \(fmt(wrappedGap))")
    check(abs(answerPitch - rulePitch) <= 0.5,
          "\(t.rawValue): a Help answer spaces its lines as the tier does",
          "\(fmt(answerPitch)) vs \(fmt(rulePitch))")
    check(questionPad >= wrappedGap,
          "\(t.rawValue): a Help card pads its question by at least a wrapped line's gap",
          "\(fmt(questionPad)) vs \(fmt(wrappedGap))")
    if t == .standard {
        check(abs(questionPad - 10) <= 0.5,
              "Default Help card keeps its design's 10 pt question padding", fmt(questionPad))
    }
}

// MARK: - Pass 4: structural, over the real views

print("4. structural (real sources)")

func codeOnly(_ line: String) -> String {
    guard let marker = line.range(of: "//") else { return line }
    return String(line[line.startIndex..<marker.lowerBound])
}

func lines(of relative: String) -> [String]? {
    let url = URL(fileURLWithPath: sourceRoot + "/" + relative)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        check(false, "read \(relative)")
        return nil
    }
    return text.components(separatedBy: "\n")
}

/// The lines of the block starting at `start`, by brace depth. A
/// declaration may spend several lines on its signature before the
/// first `{`, so the count only ends once a brace has been seen.
func block(of lines: [String], from start: Int) -> [String] {
    var depth = 0
    var opened = false
    var out: [String] = []
    for line in lines[start...] {
        out.append(line)
        let opens = line.filter { $0 == "{" }.count
        if opens > 0 { opened = true }
        depth += opens
        depth -= line.filter { $0 == "}" }.count
        if opened && depth <= 0 { break }
    }
    return out
}

/// Every representable text field: `fontSize:` declared with no default,
/// and the typography helper applied from BOTH hooks.
func checkRepresentable(_ name: String, in relative: String) {
    guard let src = lines(of: relative) else { return }
    guard let start = src.firstIndex(where: {
        codeOnly($0).contains("struct \(name): NSViewRepresentable")
    }) else {
        check(false, "\(name) found in \(relative)")
        return
    }
    let body = block(of: src, from: start)
    let decl = body.first { codeOnly($0).contains("var fontSize: CGFloat") }
    check(decl != nil && !codeOnly(decl!).contains("="),
          "\(name) declares fontSize with no default")
    for hook in ["makeNSView", "updateNSView"] {
        guard let at = body.firstIndex(where: { codeOnly($0).contains("func \(hook)") }) else {
            check(false, "\(name) has \(hook)")
            continue
        }
        let hookBody = block(of: body, from: at)
        check(hookBody.contains { codeOnly($0).contains("TextInputTypography.apply") },
              "\(name).\(hook) applies TextInputTypography")
    }
    check(!body.contains { codeOnly($0).contains("NSFont.systemFont(ofSize: 14)")
                          || codeOnly($0).contains("NSFont.monospacedSystemFont(ofSize: 13") },
          "\(name) sets no literal font of its own")
    // Reading `layoutManager` on a stock text view flips it into
    // TextKit 1 for good, where a paragraph lineSpacing puts the
    // spelling underline in the gap under the word (pass 5 measures
    // it). The only permitted spelling is the fallback for a view
    // that is ALREADY TextKit 1: the `else if` after `textLayoutManager`.
    let reads = body.filter { codeOnly($0).contains(".layoutManager") }
    check(reads.allSatisfy { codeOnly($0).contains("else if let") },
          "\(name) never reads layoutManager (except as the TextKit 1 fallback)",
          "\(reads.count) read(s)")
}

checkRepresentable("GrowingTextField", in: "SipAI/Views/Chat/AgentComposer.swift")
checkRepresentable("MultilineTextField", in: "SipAI/Views/Chat/MessageInput.swift")
checkRepresentable("NoteSourceEditor", in: "SipAI/Views/Notes/NoteView.swift")

/// No literal `.font(.system(size: <number>` left in a file the tier
/// now reaches. A literal there is a size the tier cannot move.
func checkNoLiteralFonts(in relative: String, allowing allowed: Int = 0) {
    guard let src = lines(of: relative) else { return }
    let literal = try! NSRegularExpression(pattern: #"\.font\(\.system\(size:\s*[0-9]"#)
    let hits = src.enumerated().filter { _, line in
        let code = codeOnly(line)
        return literal.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
    }
    check(hits.count <= allowed,
          "\(relative): no literal point sizes" + (allowed > 0 ? " beyond the \(allowed) deliberate" : ""),
          "\(hits.count) found, first at line \(hits.first.map { $0.offset + 1 } ?? 0)")
}

checkNoLiteralFonts(in: "SipAI/Views/Chat/AgentComposer.swift")
checkNoLiteralFonts(in: "SipAI/Views/Chat/MessageInput.swift")
checkNoLiteralFonts(in: "SipAI/Views/Chat/ModelSelector.swift")
checkNoLiteralFonts(in: "SipAI/Views/Chat/TranscriptFind.swift")
checkNoLiteralFonts(in: "SipAI/Views/Settings/SettingsView.swift")
// The menu over the Settings row and the sidebar's list of sections
// while Settings is open: sidebar rows, on the sidebar's own sizes.
checkNoLiteralFonts(in: "SipAI/Views/Settings/SettingsNavigation.swift")
checkNoLiteralFonts(in: "SipAI/Views/ModelSetupSheet.swift")
// The scheduled-task page: once exempted as "window chrome", which it
// never was — as a banner it is a form above the transcript, and for a
// task that has not run it IS the centre pane.
checkNoLiteralFonts(in: "SipAI/Views/Chat/ScheduledTaskPanel.swift")
checkNoLiteralFonts(in: "SipAI/Views/Chat/ScheduleTimingEditor.swift")
if let panel = lines(of: "SipAI/Views/Chat/ScheduledTaskPanel.swift") {
    let code = panel.map(codeOnly)
    check(code.contains { $0.contains("@Environment(\\.sipFontScale)") },
          "ScheduledTaskPanel reads the tier scale itself")
    check(code.contains { $0.contains(".controlSize(SipFont.controlSize(fontScale))") },
          "ScheduledTaskPanel steps its system controls with the tier")
    check(!code.contains { $0.contains(".controlSize(.small)") && !$0.contains("ProgressView") },
          "ScheduledTaskPanel pins no button to the Default tier's control size")
    // `.borderless` draws no hover at all on macOS: Change and Choose…
    // read as static labels beside Edit / Run now, which highlight.
    check(!code.contains { $0.contains(".buttonStyle(.borderless)") },
          "every ScheduledTaskPanel text button has the panel's hover style")
    // The gaps scale with the type, so the whole card grows at a larger
    // tier; a literal padding or stack spacing is a gap that does not.
    let fixedGap = try! NSRegularExpression(
        pattern: #"(\.padding\(\.(horizontal|vertical|top|bottom), [0-9]+\)|spacing: [1-9][0-9]*[,)])"#)
    let gaps = code.filter { fixedGap.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    check(gaps.isEmpty, "ScheduledTaskPanel: no unscaled gaps", "\(gaps.count) found: \(gaps.first ?? "")")
}
if let session = lines(of: "SipAI/Views/Chat/AgentSessionView.swift") {
    check(!session.map(codeOnly).joined().isEmpty
            && !session.contains { $0.contains("the panel is window chrome") },
          "AgentSessionView no longer calls the task panel window chrome")
}

/// The chat card and its popover live in ChatView.swift beside the
/// hero, whose 28 pt title is paired with the logo on purpose; only
/// the card's own structs are held to the rule. The chips it hosts
/// are covered by their own files above.
if let src = lines(of: "SipAI/Views/Chat/ChatView.swift") {
    let literal = try! NSRegularExpression(pattern: #"\.font\(\.system\(size:\s*[0-9]"#)
    for name in ["UnifiedInputCard", "NoteOptionsPopover"] {
        guard let start = src.firstIndex(where: { codeOnly($0).contains("struct \(name):") }) else {
            check(false, "\(name) found in ChatView.swift")
            continue
        }
        let body = block(of: src, from: start)
        let hits = body.filter { line in
            let code = codeOnly(line)
            return literal.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
        }
        check(hits.isEmpty, "ChatView.\(name): no literal point sizes", "\(hits.count) found")
    }
    check(!src.contains { codeOnly($0).contains("spacing: 12)") && codeOnly($0).contains("VStack(alignment: .leading") },
          "ChatView's message stack no longer carries a constant gap")
    // The content re-scope covers the message list ALONE, so the card
    // below it reads the tier scale like the agent composer does.
    let rescopes = src.filter { codeOnly($0).contains(".environment(\\.sipFontScale, SipFont.contentScale(fontScale))") }
    check(rescopes.count == 1, "ChatView re-scopes the content scale exactly once", "\(rescopes.count)")
    if let start = src.firstIndex(where: { codeOnly($0).contains("struct UnifiedInputCard:") }) {
        let body = block(of: src, from: start)
        check(body.contains { codeOnly($0).contains("@Environment(\\.sipFontScale)") },
              "UnifiedInputCard reads the tier scale itself")
        check(body.contains { codeOnly($0).contains("fontSize: inputFontSize") },
              "UnifiedInputCard feeds its text field a point size")
    }
}

/// MessageBubble sits INSIDE the transcript re-scope, so nothing in it
/// may use `.sipFont` (it would read a value already divided down).
/// Its header meta and the branch editor are stated at the size they
/// show at DEFAULT, so they multiply `SipFont.contentRatio` — 1 there —
/// rather than the raw `fontScale` the renderer's 14-base rows use;
/// the branch editor's box is fed that too, with the transcript's own
/// line spacing. The hover icon buttons are chrome in a fixed 22 × 20
/// box and keep their literal.
if let src = lines(of: "SipAI/Views/Chat/MessageBubble.swift") {
    let literal = try! NSRegularExpression(pattern: #"\.font\(\.system\(size:\s*[0-9.]+[,)]"#)
    var outsideIcon: [String] = []
    if let iconAt = src.firstIndex(where: { codeOnly($0).contains("private func iconButton(") }) {
        let icon = Set(block(of: src, from: iconAt))
        outsideIcon = src.filter { !icon.contains($0) }
    } else {
        outsideIcon = src
    }
    let hits = outsideIcon.filter { line in
        let code = codeOnly(line)
        return literal.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
    }
    check(hits.isEmpty, "MessageBubble: every size outside the icon buttons is tier-scaled",
          "\(hits.count) literal")
    check(!src.contains { codeOnly($0).contains(".sipFont(") },
          "MessageBubble never uses .sipFont (it is inside the re-scope)")
    check(src.contains { codeOnly($0).contains("fontSize: 14 * SipFont.contentRatio(fontScale)") },
          "BranchEditor's box keeps its Default size and scales with the transcript")
    check(src.contains { codeOnly($0).contains("lineSpacing: 14 * fontScale * lineSpacingFactor") },
          "BranchEditor's box takes the transcript's line spacing")
    // A Default-sized row multiplied raw renders 7 % under at Default.
    // The bubble's two LABELS ("You" / the agent name, semibold) are on
    // the renderer's raw convention and always were; nothing else in
    // the file may be, or its Default size moved.
    let rawSize = try! NSRegularExpression(pattern: #"size:\s*1[0-9]\s*\*\s*fontScale[,)]"#)
    let raw = src.filter { line in
        let code = codeOnly(line)
        return rawSize.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
    }
    check(raw.count == 2 && raw.allSatisfy { $0.contains("weight: .semibold") },
          "MessageBubble's only raw-multiplied sizes are its two semibold labels",
          "\(raw.count) raw sites")
}

/// Pass 3 restates the renderer's wrapped-line rule as its reference;
/// this pins that the source still states it, so the two cannot drift
/// apart unnoticed.
if let src = lines(of: "SipAI/Utilities/MarkdownRenderer.swift") {
    check(src.contains { codeOnly($0).contains(".lineSpacing(14 * fontScale * lineSpacingFactor)") },
          "renderer's wrapped-line rule is the one pass 3 measures against")
    check(src.contains { codeOnly($0).contains("MarkdownRowPad.points(") },
          "list and blockquote rows pad through the floored rule")
}

if let src = lines(of: "SipAI/Views/Chat/AgentSessionView.swift") {
    let constant = src.enumerated().filter {
        codeOnly($0.element).contains("VStack(alignment: .leading, spacing: 12)")
    }
    check(constant.isEmpty, "AgentSessionView's transcript stacks no longer carry a constant gap",
          "line \(constant.first.map { $0.offset + 1 } ?? 0)")
}

if let src = lines(of: "SipAI/Utilities/MarkdownRenderer.swift") {
    guard let start = src.firstIndex(where: { codeOnly($0).contains("VStack(alignment: .leading, spacing: 0)") }) else {
        check(false, "renderer block stack found"); exit(1)
    }
    let stack = block(of: src, from: start)
    // A bare number closed by `)` is a gap the tier cannot move;
    // `6 * gap` is not.
    let literalPad = try! NSRegularExpression(pattern: #"\.padding\(\.vertical,\s*[0-9.]+\)"#)
    // `Spacer().frame(height:)` is a gap; a rule's `.frame(height: 1)`
    // is its thickness.
    let literalSpacer = try! NSRegularExpression(pattern: #"Spacer\(\)\.frame\(height:\s*[0-9.]+\)"#)
    let hits = stack.filter { line in
        let code = codeOnly(line)
        let r = NSRange(code.startIndex..., in: code)
        return literalPad.firstMatch(in: code, range: r) != nil
            || literalSpacer.firstMatch(in: code, range: r) != nil
    }
    check(hits.isEmpty, "renderer block stack: every vertical gap is scaled", "\(hits.count) literal gaps")
}

/// Settings → Help is prose, so it takes the whole rhythm like the
/// scheduled-task page: the tier's line spacing set once at the pane's
/// root, and no gap in the section a constant. A fixed `.lineSpacing(3)`
/// held every answer to single spacing in Large text mode.
if let settings = lines(of: "SipAI/Views/Settings/SettingsView.swift") {
    if let start = settings.firstIndex(where: { codeOnly($0).contains("struct HelpPane: View {") }),
       let end = settings.firstIndex(where: { $0.contains("// MARK: - Shared hover buttons") }),
       start < end {
        let help = settings[start..<end].map(codeOnly)
        func hits(_ pattern: String) -> [String] {
            let re = try! NSRegularExpression(pattern: pattern)
            return help.filter { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        }
        let fixedSpacing = hits(#"\.lineSpacing\(\s*[0-9.]+\s*\)"#)
        check(fixedSpacing.isEmpty, "Help: no line spacing of its own — the tier's, set once at the pane's root",
              "\(fixedSpacing.count): \(fixedSpacing.first ?? "")")
        let fixedGaps = hits(#"(\.padding\(\.(horizontal|vertical|top|bottom|leading|trailing), [0-9.]+\)|[sS]pacing: [1-9][0-9.]*[,)]|\.frame\(width: [0-9.]+[,)]|cornerRadius: [0-9.]+\))"#)
        check(fixedGaps.isEmpty, "Help: no unscaled gaps", "\(fixedGaps.count): \(fixedGaps.first ?? "")")
        check(help.contains { $0.contains(".lineSpacing(HelpRhythm.lineSpacing(fontScale, lineSpacingFactor))") },
              "HelpPane sets the tier's line spacing at its root — what pass 3b measures under")
        check(help.contains { $0.contains("SipFont.lineSpacing(bodySize, fontScale: fontScale, lineSpacingFactor: lineSpacingFactor)") }
              && help.contains { $0.contains("SipFont.gapScale(bodySize, fontScale: fontScale, lineSpacingFactor: lineSpacingFactor)") },
              "HelpRhythm is the tier's own rule for the section's body size")
        check(help.contains { $0.contains("FAQAnswer(text: answer)") }
              && help.contains { $0.contains("FAQAnswer(text: text)") },
              "every Help paragraph, the Codex card's included, is the one FAQAnswer")
    } else {
        check(false, "the Help section found in SettingsView.swift")
    }
}

/// The Settings help sentence names the new reach, in both languages.
if let catalog = try? String(contentsOfFile: sourceRoot + "/SipAI/Resources/Localizable.xcstrings", encoding: .utf8) {
    let old = "Applies to the sidebar and chat/agent content."
    let new = "Applies to the sidebar, the conversation, the text box and its controls, notes, and Settings."
    check(!catalog.contains(old), "old font-size help sentence removed from the catalog")
    if let range = catalog.range(of: new) {
        let after = catalog[range.upperBound...].prefix(600)
        check(after.contains("zh-Hans") && after.contains("\"translated\""),
              "new font-size help sentence has a zh-Hans value")
    } else {
        check(false, "new font-size help sentence is in the catalog")
    }
    if let settings = lines(of: "SipAI/Views/Settings/SettingsView.swift") {
        check(settings.contains { $0.contains(new) }, "SettingsView states the new help sentence")
        check(!settings.contains { $0.contains(old) }, "SettingsView no longer states the old one")
    }
}

print("")
if failures.isEmpty {
    print("PASS (passes 1–4)")
} else {
    print("FAILED (\(failures.count)):")
    for f in failures { print("  - \(f)") }
    exit(1)
}

// MARK: - Pass 5: the spelling underline under the tier's line spacing (GUI)

print("5. spelling underline under line spacing (needs a window)")

/// Renders three lines — the middle one a lone word marked misspelled —
/// through the REAL helper and returns how far below that word's
/// baseline the red dots start. The word has no descender, so its
/// lowest ink row IS its baseline.
@MainActor
func underlineGap(forceTextKit1: Bool, lineSpacing: CGFloat) -> Int? {
    let scroll = NSTextView.scrollableTextView()
    let tv = scroll.documentView as! NSTextView
    if forceTextKit1 { _ = tv.layoutManager }
    tv.isRichText = false
    tv.drawsBackground = true
    tv.backgroundColor = .white
    tv.textColor = .black
    tv.textContainer?.lineFragmentPadding = 0
    tv.textContainerInset = NSSize(width: 6, height: 6)
    TextInputTypography.apply(pointSize: 14, lineSpacing: lineSpacing, to: tv)
    tv.string = "first line here\ntesst\nthird line here"
    tv.setSpellingState(NSAttributedString.SpellingState.spelling.rawValue,
                        range: (tv.string as NSString).range(of: "tesst"))
    scroll.frame = NSRect(x: 0, y: 0, width: 240, height: 160)
    let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 160),
                       styleMask: [.titled], backing: .buffered, defer: false)
    win.contentView = scroll
    win.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    tv.display()
    guard let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds) else { return nil }
    tv.cacheDisplay(in: tv.bounds, to: rep)
    win.orderOut(nil)
    var blackRows: [Int] = [], redRows: [Int] = []
    for y in 0..<rep.pixelsHigh {
        var black = false, red = false
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
            if r < 0.35 && g < 0.35 && b < 0.35 { black = true }
            if r > 0.5 && r > g + 0.2 && r > b + 0.2 { red = true }
        }
        if black { blackRows.append(y) }
        if red { redRows.append(y) }
    }
    var clusters: [[Int]] = []
    for y in blackRows {
        if let last = clusters.last?.last, y == last + 1 { clusters[clusters.count - 1].append(y) }
        else { clusters.append([y]) }
    }
    guard clusters.count >= 3, let firstRed = redRows.first else { return nil }
    let scale = Int(CGFloat(rep.pixelsWide) / tv.bounds.width)
    return (firstRed - clusters[1].last!) / max(scale, 1)
}

var guiFailures = 0
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // Large text mode's spacing on the composer's 14 pt base: the
    // widest gap the tier can produce, so the drift is unmissable.
    let spacing = SipFont.scaled(14, FontTier.xlarge.scale) * FontTier.xlarge.lineSpacingFactor
    guard let tk2 = underlineGap(forceTextKit1: false, lineSpacing: spacing) else {
        print("  FAIL  could not render the TextKit 2 text view"); guiFailures += 1; return
    }
    let okTK2 = tk2 <= 3
    print("  \(okTK2 ? "ok   " : "FAIL ")  TextKit 2 + \(String(format: "%.1f", spacing)) pt spacing: dots start \(tk2) px under the word")
    if !okTK2 { guiFailures += 1 }
    if let tk1 = underlineGap(forceTextKit1: true, lineSpacing: spacing) {
        // Information, not a check: this is AppKit's behaviour, and the
        // day it changes nothing in the app is wrong.
        print("        (TextKit 1, the same view after reading layoutManager: \(tk1) px — the trap pass 4 guards)")
    }
}
if guiFailures == 0 {
    print("PASS")
} else {
    print("FAILED (\(guiFailures)) in pass 5")
    exit(1)
}
