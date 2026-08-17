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

/// The lockup, copied structurally from `LeftSidebar`'s brand header. Keep
/// the metrics in step with it — this measures what it is given, so a stale
/// copy here passes while the sidebar drifts.
struct Lockup: View {
    let mark: NSImage
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            Image(nsImage: mark)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: 54)
            Text(verbatim: "SipAI")
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(.black)
            Spacer()
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(width: 268)
        .background(Color.white)
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
    guard let mark = bundle.image(forResource: "SipAI-Logo-54") else {
        return fail("SipAI-Logo-54 missing from the bundle")
    }

    let scale: CGFloat = 4
    let renderer = ImageRenderer(content: Lockup(mark: mark))
    renderer.scale = scale
    guard let cg = renderer.cgImage else { return fail("ImageRenderer produced nothing") }

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
    return 0
}

exit(MainActor.assumeIsolated { run() })
