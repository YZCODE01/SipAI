//
//  probe.swift — does the glass's base land on the wordmark's baseline?
//
//  The sidebar's brand lockup is an `HStack(alignment: .lastTextBaseline)` of
//  the mark and the word "SipAI". A non-text view's baseline is its BOTTOM
//  EDGE, so the alignment only reads as "the cup sits on the S" while the
//  rendition is cropped tight to the glass — transparent margin under the cup
//  floats it off the line, silently, and nothing in the layout complains.
//
//  This builds that HStack with the REAL asset out of the built app's
//  Assets.car, renders it offscreen, and measures the two bottoms in pixels.
//
import SwiftUI
import AppKit

/// The lockup, copied structurally from `LeftSidebar`'s brand header
/// (`SidebarBrandLockup`). Keep the metrics in step with it — this
/// measures what it is given, so a stale copy here passes while the
/// sidebar drifts.
///
/// The wordmark's frame is laid out always and drawn by nothing; what
/// shows — the wordmark, or an update line — is an overlay on that
/// frame, aligned on its last baseline.
struct Lockup: View {
    let mark: NSImage
    var message: String? = nil
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            Image(nsImage: mark)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: 54)
            Self.wordmark
                .hidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leadingLastTextBaseline) {
                    if let message {
                        Text(verbatim: message)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.black)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Self.wordmark
                    }
                }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(width: 268)
        .background(Color.white)
    }

    static var wordmark: some View {
        Text(verbatim: "SipAI")
            .font(.system(size: 28, weight: .semibold))
            .tracking(-0.4)
            .foregroundStyle(.black)
    }
}

@MainActor
func run() -> Int32 {
    func fail(_ msg: String) -> Int32 {
        FileHandle.standardError.write("\(msg)\n".data(using: .utf8)!)
        return 2
    }

    guard CommandLine.arguments.count > 1 else { return fail("usage: probe.swift <path to SipAI.app>") }
    guard let bundle = Bundle(path: CommandLine.arguments[1]) else {
        return fail("cannot open app bundle at \(CommandLine.arguments[1])")
    }
    // The catalog is appearance-keyed, and this measures ink against a WHITE
    // background — so the light rendition is the only one it can see. On a
    // machine set to Dark Mode the lookup would otherwise hand back the
    // near-white dark rendition and every row would read as blank ("found no
    // mark"), which is a property of the tester's Appearance setting and not
    // of the asset. Section 1 has already pinned the two renditions as
    // pixel-registered, so measuring the light one measures both.
    let aqua = NSAppearance(named: .aqua)!
    var resolved: NSImage?
    var rendered: CGImage?
    // The update lines, both shapes: one row, and a wrap whose LAST row
    // is what must sit on the glass. Capitals and figures only on that
    // row, so its lowest ink IS the baseline (no descender to allow for).
    let oneLine = "CODEX 0.157.0"
    let twoLines = "CLAUDE CODE HAS BEEN\nUPDATED TO 2.1.290"
    var renderedLines: [String: CGImage] = [:]
    let scale: CGFloat = 4
    aqua.performAsCurrentDrawingAppearance {
        guard let mark = bundle.image(forResource: "SipAI-Logo-54") else { return }
        resolved = mark
        let renderer = ImageRenderer(content: Lockup(mark: mark))
        renderer.scale = scale
        rendered = renderer.cgImage
        for line in [oneLine, twoLines] {
            let r = ImageRenderer(content: Lockup(mark: mark, message: line))
            r.scale = scale
            renderedLines[line] = r.cgImage
        }
    }
    guard let mark = resolved else {
        return fail("SipAI-Logo-54 missing from the bundle")
    }
    guard let cg = rendered else { return fail("ImageRenderer produced nothing") }

    // Read it back as 8-bit grey. Row 0 of the buffer is the TOP.
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h)
    buf.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    let ink: (Int, Int) -> Bool = { x, y in buf[y * w + x] < 170 }

    func lowestInkRow(_ xs: Range<Int>) -> Int? {
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in xs where ink(x, y) { return y }
        }
        return nil
    }

    // The mark occupies the leading inset plus its own width; the wordmark
    // starts after it. Split on the mark's rendered right edge.
    let markWidth = 54 * mark.size.width / mark.size.height
    let split = min(w - 1, Int(((14 + markWidth + 5) * scale).rounded()))

    guard let cupBottom = lowestInkRow(Int(14 * scale)..<split) else { return fail("found no mark") }
    guard let wordBottom = lowestInkRow(split..<w) else { return fail("found no wordmark") }

    // "SipAI" has a descender, which legitimately hangs below the baseline,
    // so the S is measured on its own: it is the first glyph, and the first
    // blank column after it ends it.
    var sRight = w
    var seenS = false
    for x in split..<w {
        var column = false
        for y in 0..<h where ink(x, y) { column = true; break }
        if column { seenS = true } else if seenS { sRight = x; break }
    }
    guard let sBottom = lowestInkRow(split..<sRight) else { return fail("found no S") }

    let delta = Double(sBottom - cupBottom) / Double(scale)
    print(String(format: "mark %.0fx54 pt   cup base row %d   S bottom row %d   delta %+.2f pt",
                 markWidth, cupBottom, sBottom, delta))
    print(String(format: "wordmark bottom row %d — the p's descender, %+.2f pt below the cup",
                 wordBottom, Double(wordBottom - cupBottom) / Double(scale)))

    // A round letterform overshoots the baseline it sits on; that overshoot
    // is typographic, not misalignment. Past a point is the asset drifting.
    let tolerance = 1.0
    guard abs(delta) <= tolerance else {
        print("FAIL  \(delta) pt apart — check the rendition for transparent margin under the cup")
        return 1
    }
    print("PASS  the glass's base and the S sit on one line (within \(tolerance) pt)")

    // The update line takes the wordmark's place: its LAST row lands on
    // the glass's base, and the header keeps its height, so nothing in
    // the sidebar below it moves while a line shows.
    var failed = false
    for line in [oneLine, twoLines] {
        guard let img = renderedLines[line] else { return fail("ImageRenderer produced nothing for \(line)") }
        guard img.height == h, img.width == w else {
            print("FAIL  a line changed the header's size: \(img.width)x\(img.height) against \(w)x\(h) px")
            failed = true
            continue
        }
        var lbuf = [UInt8](repeating: 0, count: w * h)
        lbuf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var lowest: Int? = nil
        search: for y in stride(from: h - 1, through: 0, by: -1) {
            for x in split..<w where lbuf[y * w + x] < 170 { lowest = y; break search }
        }
        guard let lineBottom = lowest else { return fail("found no ink for \(line)") }
        let d = Double(lineBottom - cupBottom) / Double(scale)
        let rows = line.contains("\n") ? "two-row" : "one-row"
        if abs(d) <= tolerance {
            print(String(format: "PASS  a %@ update line ends on the glass's base (%+.2f pt), header size unchanged", rows, d))
        } else {
            print(String(format: "FAIL  a %@ update line ends %+.2f pt off the glass's base", rows, d))
            failed = true
        }
    }
    return failed ? 1 : 0
}

exit(MainActor.assumeIsolated { run() })
