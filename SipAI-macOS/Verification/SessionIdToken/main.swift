// "Copy session ID", and the grey token a session id becomes in the agent
// composer.
//
// 1. the token rule (`SessionIdTokens.ranges`): a run of id characters
//    EQUAL to a listed session's id — never merely UUID-shaped;
// 2. the grey: it IS the sidebar row's hover grey, spelled once and
//    dynamic in both appearances, over the same `surface` the sidebar
//    draws it on — and it shows on the composer's box;
// 3. the REAL GrowingTextField (extracted from AgentComposer.swift) and
//    the REAL DropForwardingTextView (from MessageInput.swift), hosted in
//    an offscreen window and rendered: the grey is the sidebar hover's
//    pixel for pixel, sits behind the id and nowhere else, hugs the
//    glyphs at Large text mode's line spacing, follows an edit, takes no
//    second coat where two ids' margins overlap, carries no spelling
//    dots — and the chat card's MultilineTextField draws none of it;
// 4. the copy: the id alone, as plain text, pasted back into the real
//    field from a PRIVATE pasteboard (the user's clipboard is never
//    touched) and drawn as a token;
// 5. the wiring and the string, read off the sources.
//
// Nothing here is part of the app target.

import AppKit
import SwiftUI

var failures: [String] = []
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("  ok    \(label)") }
    else {
        let extra = detail()
        print("  FAIL  \(label)\(extra.isEmpty ? "" : " — \(extra)")")
        failures.append(label)
    }
}
func note(_ text: String) { print("        \(text)") }
func section(_ t: String) { print("\n\(t)") }

let sourceRoot = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let renderDir = ProcessInfo.processInfo.environment["SESSION_ID_TOKEN_RENDER"]
func source(_ rel: String) -> String {
    (try? String(contentsOf: sourceRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

let claude = "842ff5d1-c577-4904-a834-d1bc09d33aee"
let codex = "019a3f2e-7c1b-7d2e-9f00-aabbccddeeff"
let kimi = "session_5e4dbfb4-94de-41d9-8f13-4f0e56955b32"
// Letters and digits mixed, like a real id: the checker leaves a run of
// mostly digits alone, and a control it never marks proves nothing.
let unknown = "9c1ab3de-f077-4e2a-b5c4-8d2ef3a91bcd"
let known: Set<String> = [claude, codex, kimi]

func tokens(_ text: String) -> [String] {
    let ns = text as NSString
    return SessionIdTokens.ranges(in: text, known: known).map { ns.substring(with: $0) }
}

// MARK: - 1. The rule

section("1. which runs are tokens")
check("a claude id is a token", tokens("Read \(claude) please") == [claude])
check("a codex id is a token", tokens("see \(codex).") == [codex])
check("a kimi id is ONE token, prefix and all", tokens("\(kimi) says") == [kimi])
check("a UUID no listed session has is not a token", tokens("request \(unknown) failed").isEmpty)
check("the bare uuid of a kimi id is not a token unless it is an id itself",
      tokens(String(kimi.dropFirst("session_".count))).isEmpty)
check("an id inside a longer run of id characters is not that id",
      tokens("x\(claude)").isEmpty && tokens("\(claude)x").isEmpty && tokens("\(claude)-extra").isEmpty)
check("an id inside a path segment still is",
      tokens("~/.claude/projects/-Users-me-Desktop/\(claude).jsonl") == [claude])
check("quotes, parentheses and backticks bound it",
      tokens("\"\(claude)\" (\(codex)) `\(kimi)`") == [claude, codex, kimi])
check("every occurrence, in order", tokens("\(codex) then \(claude) then \(codex)") == [codex, claude, codex])
let wide = "中文 🎉 é \(claude)"
let wideRange = SessionIdTokens.ranges(in: wide, known: known).first
check("ranges are UTF-16, the unit TextKit counts in",
      wideRange.map { (wide as NSString).substring(with: $0) } == claude,
      wideRange.map { "\($0)" } ?? "nil")
check("no listed sessions, no tokens", SessionIdTokens.ranges(in: claude, known: []).isEmpty)

// MARK: - 2. The grey

section("2. the grey: the sidebar row's hover")

typealias RGB = (Double, Double, Double)
func rgba(_ color: NSColor, _ appearance: NSAppearance.Name) -> (rgb: RGB, alpha: Double) {
    var out: (rgb: RGB, alpha: Double) = ((0, 0, 0), 0)
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        let c = color.usingColorSpace(.sRGB)!
        out = ((Double(c.redComponent) * 255, Double(c.greenComponent) * 255, Double(c.blueComponent) * 255),
               Double(c.alphaComponent))
    }
    return out
}
func rgb(_ color: NSColor, _ appearance: NSAppearance.Name) -> RGB { rgba(color, appearance).rgb }
func distance(_ a: RGB, _ b: RGB) -> Double {
    max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
}
func over(_ fg: RGB, _ alpha: Double, _ bg: RGB) -> RGB {
    (bg.0 + (fg.0 - bg.0) * alpha, bg.1 + (fg.1 - bg.1) * alpha, bg.2 + (fg.2 - bg.2) * alpha)
}
func hex(_ c: RGB) -> String {
    String(format: "#%02X%02X%02X", Int(c.0.rounded()), Int(c.1.rounded()), Int(c.2.rounded()))
}

// Where the row and the token spell their grey, and what each is drawn on.
let design = source("SipAI/Utilities/DesignSystem.swift")
var rowBackground = ""
if let start = design.range(of: "struct SidebarRowBackground: ViewModifier"),
   let end = design.range(of: "\n}\n", range: start.upperBound..<design.endIndex) {
    rowBackground = String(design[start.lowerBound..<end.upperBound])
}
check("a sidebar row fades in `SipDesign.rowHover` under the pointer",
      rowBackground.contains("(hovered ? SipDesign.rowHover : Color.clear)"))
check("the token's fill is that same grey, spelled once",
      design.contains("static let sessionIdTokenFill = NSColor(rowHover)"))
check("the sidebar's rows sit on `surface`",
      source("SipAI/Views/Sidebar/LeftSidebar.swift").contains(".background(SipDesign.surface)"))
check("…and so does the composer's box, so the one tint comes out one colour in both",
      source("SipAI/Views/Chat/AgentComposer.swift")
        .contains(#/RoundedRectangle\(cornerRadius: 12\)\s*\.fill\(SipDesign\.surface\)/#))

let hoverDark = rgba(NSColor(SipDesign.rowHover), .darkAqua)
let hoverLight = rgba(NSColor(SipDesign.rowHover), .aqua)
let tokenDark = rgba(SipDesign.sessionIdTokenFill, .darkAqua)
let tokenLight = rgba(SipDesign.sessionIdTokenFill, .aqua)
check("dark: the token resolves to the hover's grey, alpha included",
      distance(tokenDark.rgb, hoverDark.rgb) < 0.5 && abs(tokenDark.alpha - hoverDark.alpha) < 0.005,
      "\(tokenDark) vs \(hoverDark)")
check("light: the token resolves to the hover's grey, alpha included",
      distance(tokenLight.rgb, hoverLight.rgb) < 0.5 && abs(tokenLight.alpha - hoverLight.alpha) < 0.005,
      "\(tokenLight) vs \(hoverLight)")
check("…and follows the appearance: light and dark resolve apart",
      distance(tokenDark.rgb, tokenLight.rgb) >= 5, "\(tokenDark.rgb) / \(tokenLight.rgb)")
// The trap the spelling avoids, measured: an alpha variant of a system
// colour is resolved once, at creation, and stays that way.
var frozen = NSColor.clear
NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
    frozen = NSColor.systemGray.withAlphaComponent(0.2)
}
check("the trap is real: `systemGray.withAlphaComponent` made in light still reads light in dark",
      distance(rgb(frozen, .darkAqua), hoverLight.rgb) < 0.5
        && distance(rgb(frozen, .darkAqua), hoverDark.rgb) >= 5,
      "\(rgb(frozen, .darkAqua))")

let boxDark = rgb(NSColor(SipDesign.surface), .darkAqua)
let boxLight = rgb(NSColor(SipDesign.surface), .aqua)
let onBoxDark = over(tokenDark.rgb, tokenDark.alpha, boxDark)
let onBoxLight = over(tokenLight.rgb, tokenLight.alpha, boxLight)
note("on the box: dark \(hex(onBoxDark)) over \(hex(boxDark)), light \(hex(onBoxLight)) over \(hex(boxLight))")
check("dark: it shows on the composer's box a step LIGHTER — the hover's lift, not a recess",
      onBoxDark.0 >= boxDark.0 + 15, "\(onBoxDark) over \(boxDark)")
check("light: it shows on the composer's box a step darker",
      onBoxLight.0 <= boxLight.0 - 15, "\(onBoxLight) over \(boxLight)")
check("the colours DesignSystem's comment names are the composites",
      hex(onBoxDark) == "#424244" && hex(onBoxLight) == "#E8E8E9"
        && design.contains("#424244 in dark and #E8E8E9 in light"),
      "\(hex(onBoxDark)), \(hex(onBoxLight))")

// MARK: - 3. The real field, rendered

section("3. the real GrowingTextField, rendered offscreen")

struct AgentBox: View {
    @State var text: String
    @State var height: CGFloat = 40
    let tokens: Set<String>
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let spell: Bool
    var width: CGFloat = 440
    var body: some View {
        GrowingTextField(text: $text, measuredHeight: $height, onSubmit: {},
                         spellChecking: spell, fontSize: fontSize,
                         lineSpacing: lineSpacing, sessionIdTokens: tokens)
            .frame(width: width, height: 150)
            .padding(10)
            .background(SipDesign.surface)
            // A sidebar row's hover, drawn the way the row draws it —
            // SwiftUI filling `SipDesign.rowHover` on `surface` — in the
            // same window as the token: a bitmap's colour space shifts
            // every value, so the token is compared with THIS, never with
            // numbers.
            .overlay(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 6).fill(SipDesign.rowHover)
                    .frame(width: 20, height: 20)
            }
    }
}

/// The sidebar hover's colour and the box's, as this bitmap holds them.
func rendered(_ rep: NSBitmapImageRep) -> (token: (Double, Double, Double), box: (Double, Double, Double)) {
    (sRGB(rep, rep.pixelsWide - 10, rep.pixelsHigh - 10) ?? (0, 0, 0), sRGB(rep, 4, rep.pixelsHigh - 4) ?? (0, 0, 0))
}

struct ChatBox: View {
    @State var text: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    var body: some View {
        MultilineTextField(text: $text, onSubmit: {}, spellChecking: true,
                           fontSize: fontSize, lineSpacing: lineSpacing)
            .frame(width: 440, height: 150)
            .padding(10)
            .background(SipDesign.surface)
    }
}

final class Stage {
    let window: NSWindow
    let host: NSView
    init<V: View>(_ view: V, appearance: NSAppearance.Name, width: CGFloat = 460) {
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: 170),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 170)
        window.contentView = hosting
        host = hosting
        window.orderFrontRegardless()
        pump(0.3)
    }
    var textView: NSTextView? { find(host) }
    private func find(_ v: NSView) -> NSTextView? {
        if let t = v as? NSTextView { return t }
        for s in v.subviews { if let t = find(s) { return t } }
        return nil
    }
    func render(_ name: String) -> NSBitmapImageRep? {
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let renderDir {
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: renderDir).appendingPathComponent("\(name).png"))
        }
        return rep
    }
    /// A rect in the text view's coordinates, as bitmap pixel bounds.
    func pixels(_ rect: NSRect, of tv: NSView, in rep: NSBitmapImageRep) -> (x: Range<Int>, y: Range<Int>) {
        let r = host.convert(rect, from: tv)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let top = host.isFlipped ? r.minY : host.bounds.height - r.maxY
        let x0 = max(0, Int((r.minX * scale).rounded(.up)))
        let x1 = min(rep.pixelsWide, Int((r.maxX * scale).rounded(.down)))
        let y0 = max(0, Int((top * scale).rounded(.up)))
        let y1 = min(rep.pixelsHigh, Int(((top + r.height) * scale).rounded(.down)))
        return (x0..<max(x0, x1), y0..<max(y0, y1))
    }
    func close() { window.orderOut(nil) }
}

func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

func sRGB(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (Double, Double, Double)? {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
    return (Double(c.redComponent) * 255, Double(c.greenComponent) * 255, Double(c.blueComponent) * 255)
}
/// Share of the pixels in a box that are the token's grey.
func tokenShare(_ rep: NSBitmapImageRep, _ box: (x: Range<Int>, y: Range<Int>),
                fill: (Double, Double, Double)) -> Double {
    var hit = 0, all = 0
    for y in box.y { for x in box.x {
        all += 1
        if let p = sRGB(rep, x, y), distance(p, fill) <= 2.5 { hit += 1 }
    } }
    return all == 0 ? 0 : Double(hit) / Double(all)
}
/// Pixels in a box that sit in a SOLID patch of the token's grey — the
/// pixel and its eight neighbours all match. The grey lies between the
/// box and the text colour, so a glyph's antialiased edge passes through
/// it one pixel at a time; only a painted token makes a patch.
func solidPixels(_ rep: NSBitmapImageRep, _ box: (x: Range<Int>, y: Range<Int>),
                 fill: (Double, Double, Double)) -> Int {
    func hit(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
              let p = sRGB(rep, x, y) else { return false }
        return distance(p, fill) <= 2.5
    }
    var n = 0
    for y in box.y { for x in box.x where hit(x, y) {
        if (-1...1).allSatisfy({ dy in (-1...1).allSatisfy { dx in hit(x + dx, y + dy) } }) { n += 1 }
    } }
    return n
}
/// The commonest colour in a box — inside a token, its fill.
func commonest(_ rep: NSBitmapImageRep, _ box: (x: Range<Int>, y: Range<Int>)) -> (Double, Double, Double)? {
    var counts: [String: (n: Int, c: (Double, Double, Double))] = [:]
    for y in box.y { for x in box.x {
        guard let p = sRGB(rep, x, y) else { continue }
        let key = "\(Int(p.0.rounded())),\(Int(p.1.rounded())),\(Int(p.2.rounded()))"
        counts[key, default: (0, p)].n += 1
    } }
    return counts.values.max { $0.n < $1.n }?.c
}
func redPixels(_ rep: NSBitmapImageRep, _ box: (x: Range<Int>, y: Range<Int>)) -> Int {
    var n = 0
    for y in box.y { for x in box.x {
        if let p = sRGB(rep, x, y), p.0 > 128, p.0 > p.1 + 50, p.0 > p.2 + 50 { n += 1 }
    } }
    return n
}

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)
    let defaultSize = SipFont.scaled(14, FontTier.standard.scale)
    let largeSize = SipFont.scaled(14, FontTier.xlarge.scale)

    var renderedTokenDark: (Double, Double, Double)? = nil
    for (name, tag) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
        // (a) Default: one line, the id in the middle of a sentence.
        let text = "Read session \(claude) and say what it decided."
        let stage = Stage(AgentBox(text: text, tokens: known, fontSize: defaultSize,
                                   lineSpacing: defaultSize * FontTier.standard.lineSpacingFactor,
                                   spell: false), appearance: name)
        guard let tv = stage.textView as? DropForwardingTextView, let rep = stage.render("default-\(tag)") else {
            check("\(tag): the real text view was built and rendered", false); continue
        }
        let rects = tv.sessionIdTokenRects()
        let (fill, box) = rendered(rep)
        if name == .darkAqua { renderedTokenDark = fill }
        check("\(tag): the sidebar's hover and the box render as two different greys",
              distance(fill, box) >= 5, "hover \(fill), box \(box)")
        check("\(tag): the field is the shipping DropForwardingTextView, handed the ids",
              tv.sessionIdTokens == known)
        check("\(tag): one token, on one line", rects.count == 1, "\(rects)")
        if let token = rects.first {
            let inside = stage.pixels(token.insetBy(dx: 2, dy: 2), of: tv, in: rep)
            let share = tokenShare(rep, inside, fill: fill)
            check("\(tag): the grey fills the token", share > 0.4, String(format: "%.0f%%", share * 100))
            let body = commonest(rep, inside)
            check("\(tag): …and it IS a sidebar row's hover, pixel for pixel",
                  body.map { distance($0, fill) <= 1.0 } ?? false,
                  "token \(String(describing: body)), hover \(fill)")
            // The words before it, on the same line.
            let before = NSRect(x: tv.textContainerOrigin.x, y: token.minY,
                                width: token.minX - tv.textContainerOrigin.x - 4, height: token.height)
            let outside = solidPixels(rep, stage.pixels(before.insetBy(dx: 0, dy: 2), of: tv, in: rep), fill: fill)
            check("\(tag): and nothing around it", outside == 0, "\(outside) px of solid grey")
            let font = tv.font!
            check("\(tag): the token hugs the glyphs",
                  abs(token.height - (font.ascender - font.descender) - font.pointSize * 0.12) < 0.5,
                  "\(token.height) for a \(font.pointSize) pt face")
            // An edit before the id moves its token with it.
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.insertText("Please ", replacementRange: NSRange(location: 0, length: 0))
            pump(0.2)
            let moved = tv.sessionIdTokenRects().first
            let rep2 = stage.render("edited-\(tag)")
            check("\(tag): an edit before the id moves its token",
                  moved.map { $0.minX > token.minX + 20 } ?? false,
                  "\(String(describing: moved?.minX)) after \(token.minX)")
            if let moved, let rep2 {
                let share2 = tokenShare(rep2, stage.pixels(moved.insetBy(dx: 2, dy: 2), of: tv, in: rep2), fill: fill)
                check("\(tag): …and the grey is drawn where it moved to", share2 > 0.4,
                      String(format: "%.0f%%", share2 * 100))
            }
        }
        stage.close()

        // (b) Large text mode: the id wraps; the gap between its lines is
        // line spacing, and stays clear.
        let large = Stage(AgentBox(text: "Read session \(claude) now", tokens: known,
                                   fontSize: largeSize,
                                   lineSpacing: largeSize * FontTier.xlarge.lineSpacingFactor,
                                   spell: false), appearance: name)
        if let tv = large.textView as? DropForwardingTextView, let rep = large.render("large-\(tag)") {
            let fill = rendered(rep).token
            let rects = tv.sessionIdTokenRects().sorted { $0.minY < $1.minY }
            check("\(tag): at Large text mode the id wraps onto two tokens", rects.count == 2, "\(rects)")
            if rects.count == 2 {
                let gap = NSRect(x: rects[1].minX, y: rects[0].maxY + 1,
                                 width: rects[1].width, height: rects[1].minY - rects[0].maxY - 2)
                check("\(tag): the line spacing between them is NOT grey",
                      gap.height > 4 && tokenShare(rep, large.pixels(gap, of: tv, in: rep), fill: fill) < 0.02,
                      "gap \(gap.height) pt")
            }
        } else {
            check("\(tag): the Large text mode field rendered", false)
        }
        large.close()

        // (c) Two ids a space apart: their margins overlap, and the grey
        // is a tint — the overlap must take it once, not twice. Sized so
        // the overlap spans whole pixels; the first id ends and the second
        // starts on a digit, whose ink stays inside its own advance.
        let first = "sessA-fedcba9876543210", second = "0123456789abcdef-sessB"
        let pairSize = defaultSize * 2
        let pair = Stage(AgentBox(text: "\(first) \(second)", tokens: [first, second],
                                  fontSize: pairSize,
                                  lineSpacing: pairSize * FontTier.standard.lineSpacingFactor,
                                  spell: false, width: 760),
                         appearance: name, width: 780)
        if let tv = pair.textView as? DropForwardingTextView, let rep = pair.render("pair-\(tag)") {
            let fill = rendered(rep).token
            let rects = tv.sessionIdTokenRects().sorted { $0.minX < $1.minX }
            if rects.count == 2, rects[0].maxX > rects[1].minX {
                let overlap = NSRect(x: rects[1].minX, y: rects[0].minY + rects[0].height * 0.3,
                                     width: rects[0].maxX - rects[1].minX, height: rects[0].height * 0.4)
                let px = pair.pixels(overlap, of: tv, in: rep)
                note("\(tag): the two tokens overlap by \(String(format: "%.1f", overlap.width)) pt, \(px.x.count) whole pixel column(s)")
                let once = tokenShare(rep, px, fill: fill)
                check("\(tag): two ids a space apart: the overlap takes ONE coat of the grey, not two",
                      px.x.count >= 1 && once > 0.95, String(format: "%.0f%% of it is the hover grey", once * 100))
            } else {
                check("\(tag): two ids a space apart overlap by their margins", false, "\(rects)")
            }
        } else {
            check("\(tag): the two-id field rendered", false)
        }
        pair.close()
    }

    // (c) Spelling: a token never carries the checker's red dots.
    section("3b. spelling on a token")
    /// Red pixels on the first line (the listed id) and on the rest (an
    /// unknown UUID and a plain misspelling), after the REAL continuous
    /// checker has run over the text, the way typing drives it.
    func spellingDots(tokens: Set<String>, render name: String) -> (first: Int, rest: Int)? {
        let text = "known \(claude)\nother \(unknown) teh"
        let stage = Stage(AgentBox(text: text, tokens: tokens, fontSize: defaultSize,
                                   lineSpacing: defaultSize * FontTier.standard.lineSpacingFactor,
                                   spell: true), appearance: .aqua)
        defer { stage.close() }
        guard let tv = stage.textView as? DropForwardingTextView else { return nil }
        stage.window.makeFirstResponder(tv)
        tv.checkTextInDocument(nil)
        pump(1.5)
        guard let rep = stage.render(name) else { return nil }
        // Line boxes from the text itself, not from a token — the control
        // run has none.
        let font = tv.font!
        let line = font.ascender - font.descender + tv.defaultParagraphStyle!.lineSpacing
        let origin = tv.textContainerOrigin
        let first = NSRect(x: 0, y: origin.y, width: tv.bounds.width, height: line + 2)
        let rest = NSRect(x: 0, y: origin.y + line + 2, width: tv.bounds.width, height: line * 2)
        return (redPixels(rep, stage.pixels(first, of: tv, in: rep)),
                redPixels(rep, stage.pixels(rest, of: tv, in: rep)))
    }
    if let withTokens = spellingDots(tokens: known, render: "spelling"),
       let without = spellingDots(tokens: [], render: "spelling-no-tokens") {
        check("the checker ran: an unknown UUID and a misspelling carry dots", withTokens.rest > 0,
              "\(withTokens.rest) red px")
        check("a listed id — a token — carries none", withTokens.first == 0, "\(withTokens.first) red px")
        check("…and the same id in a box with no tokens DOES (the delegate is what keeps them off)",
              without.first > 0, "\(without.first) red px")
    } else {
        check("the spelling fields rendered", false)
    }

    // (d) The chat card's field: untouched.
    let chat = Stage(ChatBox(text: "Read session \(claude) please", fontSize: defaultSize,
                             lineSpacing: defaultSize * FontTier.standard.lineSpacingFactor), appearance: .darkAqua)
    if let tv = chat.textView as? DropForwardingTextView, let rep = chat.render("chat-card") {
        check("the chat card's field is handed no ids", tv.sessionIdTokens.isEmpty)
        let box = chat.pixels(tv.bounds.insetBy(dx: 2, dy: 2), of: tv, in: rep)
        let solid = renderedTokenDark.map { solidPixels(rep, box, fill: $0) }
        check("…and draws no grey anywhere", solid == 0, "\(String(describing: solid)) px of solid grey")
    } else {
        check("the chat card's field rendered", false)
    }
    chat.close()

    // MARK: - 4. Copy and paste

    section("4. the copy, and pasting it back")
    let pb = NSPasteboard(name: NSPasteboard.Name("SipAISessionIdTokenTest-\(UUID().uuidString)"))
    SessionIdTokens.copy(kimi, to: pb)
    check("the pasteboard carries the id alone", pb.string(forType: .string) == kimi,
          pb.string(forType: .string) ?? "nil")
    check("…as plain text only — no rich flavour to carry a style into another app",
          pb.availableType(from: [.rtf, .rtfd, .html]) == nil, "\(pb.types ?? [])")
    let paste = Stage(AgentBox(text: "Look at ", tokens: known, fontSize: defaultSize,
                               lineSpacing: defaultSize * FontTier.standard.lineSpacingFactor,
                               spell: false), appearance: .darkAqua)
    if let tv = paste.textView as? DropForwardingTextView {
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        let read = tv.readSelection(from: pb, type: .string)
        pump(0.2)
        check("pasted into the real field", read && tv.string == "Look at \(kimi)", tv.string)
        // It ENDS the text, where TextKit reports the segment twice.
        let pasted = tv.sessionIdTokenRects()
        check("…one token, though TextKit reports an id that ends the text twice",
              pasted.count == 1, "\(pasted)")
        if let rep = paste.render("pasted"), let token = pasted.first {
            let inside = paste.pixels(token.insetBy(dx: 2, dy: 2), of: tv, in: rep)
            let fill = rendered(rep).token
            let share = tokenShare(rep, inside, fill: fill)
            check("…and drawn as a token", share > 0.4, String(format: "%.0f%%", share * 100))
            let body = commonest(rep, inside)
            check("…in one coat of the hover grey, not two",
                  body.map { distance($0, fill) <= 1.0 } ?? false,
                  "token \(String(describing: body)), hover \(fill)")
        } else {
            check("…and drawn as a token", false, "no token rect")
        }
    }
    paste.close()
    pb.releaseGlobally()
}

// MARK: - 5. Wiring and the string

section("5. wiring (read off the sources)")
let rows = source("SipAI/Views/Sidebar/AgentSessionsSection.swift")
if let start = rows.range(of: "private func sessionMenuItems"),
   let end = rows.range(of: "private func groupSubmenu", range: start.upperBound..<rows.endIndex) {
    let menu = String(rows[start.lowerBound..<end.lowerBound])
    check("the session row's menu offers \"Copy session ID\"", menu.contains(#"Text("Copy session ID""#))
    check("…copying the row's own session id", menu.contains("SessionIdTokens.copy(session.id)"))
    let copyAt = menu.range(of: "Copy session ID")!.lowerBound
    check("…after Rename and Add to Group, before the divider and Delete",
          menu.range(of: "Rename")!.lowerBound < copyAt
            && menu.range(of: "groupSubmenu(for:")!.lowerBound < copyAt
            && menu.range(of: "Divider()")!.lowerBound > copyAt)
} else {
    check("the session row's menu was found", false)
}
if let start = rows.range(of: "private func taskMenuItems") {
    let rest = String(rows[start.lowerBound...].prefix(1500))
    check("a scheduled TASK's menu has no session id to copy", !rest.contains("Copy session ID"))
}
let composer = source("SipAI/Views/Chat/AgentComposer.swift")
check("the composer hands its field the ids", composer.contains("sessionIdTokens: sessionIdTokens\n"))
check("the field applies them when built AND on every update",
      composer.components(separatedBy: "(tv as? DropForwardingTextView)?.sessionIdTokens = sessionIdTokens").count - 1 == 2)
check("the field's delegate keeps spelling off a token",
      composer.contains("shouldSetSpellingState value: Int") && composer.contains("sessionIdTokenRanges.contains"))
check("the session view hands down every listed session's id",
      source("SipAI/Views/Chat/AgentSessionView.swift").contains("sessionIdTokens: agents.knownSessionIds"))
check("the manager keeps that set beside `sessions`",
      source("SipAI/Models/AgentManager.swift").contains("didSet { knownSessionIds = Set(sessions.map(\\.id)) }"))
let input = source("SipAI/Views/Chat/MessageInput.swift")
if let start = input.range(of: "struct MultilineTextField"),
   let end = input.range(of: "// MARK: - File drops on the text field") {
    check("the chat card's field never sets tokens (scope: the agent composer only)",
          !input[start.lowerBound..<end.lowerBound].contains("sessionIdTokens"))
}
// A capture redraws the whole view, so it cannot show that an edit asks
// for the redraw a moved token needs; the hooks that ask are read here.
check("an edit, a new text and a new width each ask for a redraw",
      input.contains("override func didChangeText()") && input.contains("override var string: String")
        && input.contains("override func setFrameSize") && input.contains("if !sessionIdTokens.isEmpty { needsDisplay = true }"))
check("the token drawing never reads layoutManager (TextKit 1 trap)",
      !input.contains(".layoutManager") && input.contains("textLayoutManager"))

let catalog = (try? JSONSerialization.jsonObject(with: Data(contentsOf:
    sourceRoot.appendingPathComponent("SipAI/Resources/Localizable.xcstrings")))) as? [String: Any]
let entry = ((catalog?["strings"] as? [String: Any])?["Copy session ID"]) as? [String: Any]
let zh = (((entry?["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
check("the catalog carries the string with its Chinese", zh == "复制会话 ID", zh ?? "nil")

print("")
if failures.isEmpty {
    print("PASS")
} else {
    print("FAILED (\(failures.count)):")
    for f in failures { print("  - \(f)") }
    exit(1)
}
