//
//  geometry.swift — the logo renditions' shape rules, read off the PNGs.
//
//  Every rule here fails silently. A rendition with margin under the cup
//  still draws, still swaps with the appearance, and still passes a build —
//  it just floats the mark off the wordmark's baseline. An @2x that is not
//  exactly twice its @1x lays out differently on a Retina display than on a
//  1x one, and the machine that renders the asset usually only has one of
//  those. A light/dark pair that disagrees on size shifts the lockup sideways
//  when the appearance changes.
//
//  Usage: geometry.swift <SipAI-Logo-N.imageset> [...]
//
import Foundation
import CoreGraphics
import ImageIO

var failures: [String] = []
func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String) {
    if ok { print("  PASS  \(what)") } else {
        print("  FAIL  \(what)")
        print("        → \(detail())")
        failures.append(what)
    }
}

struct Bitmap {
    let w: Int, h: Int
    let alpha: [UInt8]
    let luma: [UInt8]                      // over white, so 255 is "nothing drawn"

    init?(_ url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let W = cg.width, H = cg.height
        w = W; h = H
        var rgba = [UInt8](repeating: 0, count: W * H * 4)
        rgba.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8,
                                bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        }
        var a = [UInt8](repeating: 0, count: W * H)
        var l = [UInt8](repeating: 0, count: W * H)
        for i in 0..<(W * H) {
            let r = Int(rgba[i * 4]), g = Int(rgba[i * 4 + 1]), b = Int(rgba[i * 4 + 2])
            let al = Int(rgba[i * 4 + 3])
            a[i] = UInt8(al)
            // premultiplied over white: c + 255 * (1 - a)
            let over = { (c: Int) in min(255, c + 255 - al) }
            l[i] = UInt8((over(r) * 299 + over(g) * 587 + over(b) * 114) / 1000)
        }
        alpha = a; luma = l
    }

    /// Rows/columns of transparent padding on each side.
    var margins: (top: Int, bottom: Int, left: Int, right: Int) {
        func rowEmpty(_ y: Int) -> Bool { (0..<w).allSatisfy { alpha[y * w + $0] < 8 } }
        func colEmpty(_ x: Int) -> Bool { (0..<h).allSatisfy { alpha[$0 * w + x] < 8 } }
        var t = 0; while t < h, rowEmpty(t) { t += 1 }
        var b = 0; while b < h, rowEmpty(h - 1 - b) { b += 1 }
        var l = 0; while l < w, colEmpty(l) { l += 1 }
        var r = 0; while r < w, colEmpty(w - 1 - r) { r += 1 }
        return (t, b, l, r)
    }

    /// No corner may be painted. The mark reaches all four edges, but never
    /// into a corner — the straw's tip and the glass's base are the extremes
    /// and both stop short of one.
    var backgroundIsTransparent: Bool {
        [0, (w - 1), (h - 1) * w, (h - 1) * w + (w - 1)].allSatisfy { alpha[$0] < 8 }
    }

    /// Mean luma of the drawn pixels, over white. Low is dark ink.
    var inkLuma: Double {
        var sum = 0.0, n = 0.0
        for i in 0..<(w * h) where alpha[i] > 128 { sum += Double(luma[i]); n += 1 }
        return n > 0 ? sum / n : 255
    }

    /// Fraction of pixels whose coverage differs from another bitmap's.
    func coverageMismatch(_ other: Bitmap) -> Double {
        guard other.w == w, other.h == h else { return 1 }
        var off = 0
        for i in 0..<(w * h) where abs(Int(alpha[i]) - Int(other.alpha[i])) > 24 { off += 1 }
        return Double(off) / Double(w * h)
    }
}

for arg in CommandLine.arguments.dropFirst() {
    let dir = URL(fileURLWithPath: arg, isDirectory: true)
    let n = dir.lastPathComponent
        .replacingOccurrences(of: "SipAI-Logo-", with: "")
        .replacingOccurrences(of: ".imageset", with: "")
    print("\(dir.lastPathComponent)")

    var loaded: [String: Bitmap] = [:]
    for theme in ["light", "dark"] {
        for (key, file) in [("1x", "\(theme)_\(n).png"), ("2x", "\(theme)_\(n)@2x.png")] {
            guard let bm = Bitmap(dir.appendingPathComponent(file)) else {
                check(false, "\(file) loads", "missing or unreadable")
                continue
            }
            loaded["\(theme)\(key)"] = bm
        }
    }
    guard let l1 = loaded["light1x"], let l2 = loaded["light2x"],
          let d1 = loaded["dark1x"], let d2 = loaded["dark2x"] else { continue }

    // 1. Transparent background, and tight at the bottom and the left.
    //
    // The transparency is what makes the crop mean anything: an opaque
    // background has no margin to measure, so it reads as tight while still
    // painting a plate over whatever the mark is sitting on.
    //
    // The bottom is the alignment: the sidebar puts the wordmark's baseline
    // on the image's BOTTOM EDGE, so a transparent row under the cup lifts
    // the glass off the S by exactly that much. The left is the inset: the
    // header's leading padding is measured against the artwork, so margin
    // there pushes the mark off the chevrons below it.
    for (label, bm) in [("light@1x", l1), ("light@2x", l2), ("dark@1x", d1), ("dark@2x", d2)] {
        check(bm.backgroundIsTransparent, "\(label) has a transparent background",
              "the corners are opaque — the rendition carries a background plate")
        let m = bm.margins
        check(m.bottom == 0 && m.left == 0,
              "\(label) is cropped tight at the bottom and the left",
              "bottom \(m.bottom) px, left \(m.left) px of transparent margin")
    }

    // 2. @2x is exactly twice @1x.
    for (theme, one, two) in [("light", l1, l2), ("dark", d1, d2)] {
        check(two.w == one.w * 2 && two.h == one.h * 2,
              "\(theme) @2x is exactly twice @1x",
              "\(one.w)x\(one.h) vs \(two.w)x\(two.h)")
    }

    // 3. The appearance swap moves nothing. Same geometry, recoloured — so
    //    the two renditions differ in COLOUR and agree on COVERAGE.
    for (scale, a, b) in [("@1x", l1, d1), ("@2x", l2, d2)] {
        let mismatch = a.coverageMismatch(b)
        check(a.w == b.w && a.h == b.h && mismatch < 0.02,
              "light and dark \(scale) are pixel-registered",
              "\(a.w)x\(a.h) vs \(b.w)x\(b.h), \(String(format: "%.1f%%", mismatch * 100)) of pixels differ in coverage")
    }

    // 4. Each theme is drawn for the surface it lands on: the app's light
    //    surface is white and its dark one is #2C2C2E, so light-theme ink
    //    must be dark and dark-theme ink light. Getting this backwards is
    //    invisible in the catalog and invisible in a build.
    check(l2.inkLuma < 190, "light rendition is drawn in dark ink",
          "mean luma of the painted pixels is \(Int(l2.inkLuma)) — too pale for a white surface")
    check(d2.inkLuma > 150, "dark rendition is drawn in light ink",
          "mean luma of the painted pixels is \(Int(d2.inkLuma)) — too dark for #2C2C2E")
    print("")
}

if failures.isEmpty {
    print("geometry: all checks passed")
    exit(0)
}
print("geometry: \(failures.count) failed")
exit(1)
