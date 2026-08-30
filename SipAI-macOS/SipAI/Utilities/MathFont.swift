// MathFont.swift
// The typographic constants a TeX layout needs, read from the math
// font's own OpenType `MATH` table rather than guessed.
//
// macOS ships STIX Two Math in `/System/Library/Fonts/Supplemental`, and
// it carries a full `MATH` table: fraction-bar thickness, the axis every
// relation and fraction centres on, script shift/gap minima, radical
// parameters, and the size VARIANTS that let a delimiter grow to fit
// what it wraps. Reading those is what separates a typeset equation from
// a scaled-up glyph.
//
// Every value here is normalised to EM at parse time and multiplied by
// the point size at use, so one parse serves every font size on screen.
//
// The font is not assumed present: `MathFontResource.shared` is nil when
// the family is missing, and `MathTypesetter` answers nil in turn — the
// caller then falls back to the Unicode approximation
// (`LatexSymbols.translate`), which is what chats rendered before this
// existed. A missing system font degrades the drawing, never the text.

import AppKit
import CoreText
import Foundation

// MARK: - Resource

/// A math font plus its parsed `MATH` table. One instance per launch.
final class MathFontResource {

    /// PostScript name of the math font. Its family ("STIX Two Math")
    /// is not enough — `NSFont(name:)` on a family name that resolves
    /// nowhere silently hands back a substitute, and a substitute has no
    /// `MATH` table.
    static let postScriptName = "STIXTwoMath-Regular"

    /// nil when the font is missing or carries no `MATH` table. Resolved
    /// once; a font cannot be installed into a running process's font
    /// list without a notification this class does not observe, and
    /// re-probing per equation would cost a font lookup per frame.
    static let shared: MathFontResource? = MathFontResource()

    /// Sized at 1 pt so `CTFontCreateCopyWithAttributes` can scale it to
    /// whatever a caller needs. Glyph ids are size-independent.
    let baseFont: CTFont
    let unitsPerEm: CGFloat
    let constants: MathConstants
    private let table: MathTable

    private init?() {
        let font = CTFontCreateWithName(Self.postScriptName as CFString, 1, nil)
        // A name that resolves nowhere yields a substitute under a
        // DIFFERENT PostScript name, so identity is the check — not
        // whether a font came back.
        guard (CTFontCopyPostScriptName(font) as String) == Self.postScriptName,
              let data = CTFontCopyTable(font,
                                         CTFontTableTag(kCTFontTableMATH),
                                         CTFontTableOptions(rawValue: 0))
        else { return nil }
        let upem = CGFloat(CTFontGetUnitsPerEm(font))
        guard upem > 0, let parsed = MathTable(data: data as Data) else { return nil }
        self.baseFont = font
        self.unitsPerEm = upem
        self.table = parsed
        self.constants = MathConstants(raw: parsed.constants, unitsPerEm: upem)
    }

    /// The math font at `size`.
    func font(size: CGFloat) -> CTFont {
        CTFontCreateCopyWithAttributes(baseFont, size, nil, nil)
    }

    /// Glyph for a single character, or nil when the font has none.
    /// A surrogate pair (the Mathematical Alphanumeric block is all
    /// above the BMP) is one glyph from two UTF-16 units, which is why
    /// this asks for the whole scalar's `utf16` rather than one unit.
    func glyph(for scalar: Unicode.Scalar) -> CGGlyph? {
        var utf16 = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(baseFont, &utf16, &glyphs, utf16.count),
              let first = glyphs.first, first != 0
        else { return nil }
        return first
    }

    /// Italic correction in EM. A superscript that follows a slanted
    /// glyph has to clear the overhang, or it collides with the letter
    /// it belongs to.
    func italicCorrection(_ glyph: CGGlyph) -> CGFloat {
        (table.italicCorrection[glyph].map { CGFloat($0) } ?? 0) / unitsPerEm
    }

    /// Where an accent centres over this glyph, in EM from the glyph's
    /// origin. nil means "no opinion" and the caller centres on the
    /// advance instead.
    func topAccentAttachment(_ glyph: CGGlyph) -> CGFloat? {
        table.topAccentAttachment[glyph].map { CGFloat($0) / unitsPerEm }
    }

    /// Size variants for a stretchy glyph, smallest first, as
    /// (glyph, advance-in-EM). `advance` is the measurement ALONG the
    /// stretch axis — height for a vertical variant — not the glyph's
    /// horizontal advance.
    func variants(_ glyph: CGGlyph, vertical: Bool) -> [(glyph: CGGlyph, advance: CGFloat)] {
        let raw = vertical ? table.verticalVariants[glyph] : table.horizontalVariants[glyph]
        guard let raw else { return [] }
        return raw.variants.map { ($0.glyph, CGFloat($0.advance) / unitsPerEm) }
    }

    /// Repeatable assembly for a glyph that has to grow past its largest
    /// variant — the stacked pieces of a very tall brace or paren.
    func assembly(_ glyph: CGGlyph, vertical: Bool) -> MathGlyphAssembly? {
        let raw = vertical ? table.verticalVariants[glyph] : table.horizontalVariants[glyph]
        guard let assembly = raw?.assembly else { return nil }
        return MathGlyphAssembly(
            parts: assembly.parts.map {
                MathGlyphAssembly.Part(glyph: $0.glyph,
                                       startConnector: CGFloat($0.startConnector) / unitsPerEm,
                                       endConnector: CGFloat($0.endConnector) / unitsPerEm,
                                       fullAdvance: CGFloat($0.fullAdvance) / unitsPerEm,
                                       isExtender: $0.isExtender)
            },
            minConnectorOverlap: CGFloat(table.minConnectorOverlap) / unitsPerEm)
    }

    /// Typographic extent of a glyph run in EM, measured from the
    /// font's own outlines rather than from line metrics: a math box's
    /// height is the INK it contains, and CTLine's ascent is the same
    /// for every character in the font.
    func inkBounds(_ glyphs: [CGGlyph]) -> CGRect {
        guard !glyphs.isEmpty else { return .zero }
        var mutable = glyphs
        let rect = CTFontGetBoundingRectsForGlyphs(
            baseFont, .default, &mutable, nil, mutable.count)
        return rect.isNull ? .zero : rect
    }

    /// Total advance of a glyph run in EM.
    func advance(_ glyphs: [CGGlyph]) -> CGFloat {
        guard !glyphs.isEmpty else { return 0 }
        var mutable = glyphs
        return CTFontGetAdvancesForGlyphs(baseFont, .horizontal, &mutable, nil, mutable.count)
    }
}

/// A stretchy glyph built from repeated pieces.
struct MathGlyphAssembly {
    struct Part {
        let glyph: CGGlyph
        let startConnector: CGFloat
        let endConnector: CGFloat
        let fullAdvance: CGFloat
        let isExtender: Bool
    }
    let parts: [Part]
    let minConnectorOverlap: CGFloat
}

// MARK: - Constants

/// `MathConstants`, normalised to EM. Names are the OpenType ones so the
/// layout code reads against the spec.
struct MathConstants {
    let scriptPercentScaleDown: CGFloat
    let scriptScriptPercentScaleDown: CGFloat
    let displayOperatorMinHeight: CGFloat
    let axisHeight: CGFloat
    let accentBaseHeight: CGFloat
    let subscriptShiftDown: CGFloat
    let subscriptTopMax: CGFloat
    let subscriptBaselineDropMin: CGFloat
    let superscriptShiftUp: CGFloat
    let superscriptShiftUpCramped: CGFloat
    let superscriptBottomMin: CGFloat
    let superscriptBaselineDropMax: CGFloat
    let subSuperscriptGapMin: CGFloat
    let superscriptBottomMaxWithSubscript: CGFloat
    let spaceAfterScript: CGFloat
    let upperLimitGapMin: CGFloat
    let upperLimitBaselineRiseMin: CGFloat
    let lowerLimitGapMin: CGFloat
    let lowerLimitBaselineDropMin: CGFloat
    let stackTopDisplayStyleShiftUp: CGFloat
    let stackBottomDisplayStyleShiftDown: CGFloat
    let stackDisplayStyleGapMin: CGFloat
    let fractionNumeratorShiftUp: CGFloat
    let fractionNumeratorDisplayStyleShiftUp: CGFloat
    let fractionDenominatorShiftDown: CGFloat
    let fractionDenominatorDisplayStyleShiftDown: CGFloat
    let fractionNumeratorGapMin: CGFloat
    let fractionNumDisplayStyleGapMin: CGFloat
    let fractionRuleThickness: CGFloat
    let fractionDenominatorGapMin: CGFloat
    let fractionDenomDisplayStyleGapMin: CGFloat
    let overbarVerticalGap: CGFloat
    let overbarRuleThickness: CGFloat
    let overbarExtraAscender: CGFloat
    let underbarVerticalGap: CGFloat
    let underbarRuleThickness: CGFloat
    let underbarExtraDescender: CGFloat
    let radicalVerticalGap: CGFloat
    let radicalDisplayStyleVerticalGap: CGFloat
    let radicalRuleThickness: CGFloat
    let radicalExtraAscender: CGFloat
    let radicalKernBeforeDegree: CGFloat
    let radicalKernAfterDegree: CGFloat
    let radicalDegreeBottomRaisePercent: CGFloat

    fileprivate init(raw: MathTable.RawConstants, unitsPerEm: CGFloat) {
        func em(_ v: Int) -> CGFloat { CGFloat(v) / unitsPerEm }
        // The two script percentages and the degree-raise percentage are
        // ratios already; everything else is design units.
        scriptPercentScaleDown = CGFloat(raw.scriptPercentScaleDown) / 100
        scriptScriptPercentScaleDown = CGFloat(raw.scriptScriptPercentScaleDown) / 100
        radicalDegreeBottomRaisePercent = CGFloat(raw.radicalDegreeBottomRaisePercent) / 100
        displayOperatorMinHeight = em(raw.displayOperatorMinHeight)
        let v = raw.values
        func at(_ i: Int) -> CGFloat { i < v.count ? em(v[i]) : 0 }
        axisHeight = at(1)
        accentBaseHeight = at(2)
        subscriptShiftDown = at(4)
        subscriptTopMax = at(5)
        subscriptBaselineDropMin = at(6)
        superscriptShiftUp = at(7)
        superscriptShiftUpCramped = at(8)
        superscriptBottomMin = at(9)
        superscriptBaselineDropMax = at(10)
        subSuperscriptGapMin = at(11)
        superscriptBottomMaxWithSubscript = at(12)
        spaceAfterScript = at(13)
        upperLimitGapMin = at(14)
        upperLimitBaselineRiseMin = at(15)
        lowerLimitGapMin = at(16)
        lowerLimitBaselineDropMin = at(17)
        stackTopDisplayStyleShiftUp = at(19)
        stackBottomDisplayStyleShiftDown = at(21)
        stackDisplayStyleGapMin = at(23)
        fractionNumeratorShiftUp = at(28)
        fractionNumeratorDisplayStyleShiftUp = at(29)
        fractionDenominatorShiftDown = at(30)
        fractionDenominatorDisplayStyleShiftDown = at(31)
        fractionNumeratorGapMin = at(32)
        fractionNumDisplayStyleGapMin = at(33)
        fractionRuleThickness = at(34)
        fractionDenominatorGapMin = at(35)
        fractionDenomDisplayStyleGapMin = at(36)
        overbarVerticalGap = at(39)
        overbarRuleThickness = at(40)
        overbarExtraAscender = at(41)
        underbarVerticalGap = at(42)
        underbarRuleThickness = at(43)
        underbarExtraDescender = at(44)
        radicalVerticalGap = at(45)
        radicalDisplayStyleVerticalGap = at(46)
        radicalRuleThickness = at(47)
        radicalExtraAscender = at(48)
        radicalKernBeforeDegree = at(49)
        radicalKernAfterDegree = at(50)
    }
}

// MARK: - Binary table reader

/// Minimal `MATH` table reader: constants, italic correction, top-accent
/// attachment and the vertical/horizontal glyph variants.
///
/// Every read is bounds-checked and a short or malformed table yields
/// nil rather than a trap. This parses a SYSTEM font today, but a font
/// file is data from disk either way, and a reader that traps on
/// truncation is one corrupted font away from an unlaunchable app.
private struct MathTable {

    struct RawConstants {
        var scriptPercentScaleDown = 0
        var scriptScriptPercentScaleDown = 0
        var displayOperatorMinHeight = 0
        var radicalDegreeBottomRaisePercent = 0
        /// The 51 `MathValueRecord` values, in spec order starting at
        /// `mathLeading`.
        var values: [Int] = []
    }

    struct VariantRecord { let glyph: CGGlyph; let advance: Int }
    struct AssemblyPart {
        let glyph: CGGlyph
        let startConnector: Int
        let endConnector: Int
        let fullAdvance: Int
        let isExtender: Bool
    }
    struct Assembly { let parts: [AssemblyPart] }
    struct Construction { let variants: [VariantRecord]; let assembly: Assembly? }

    let constants: RawConstants
    let italicCorrection: [CGGlyph: Int]
    let topAccentAttachment: [CGGlyph: Int]
    let verticalVariants: [CGGlyph: Construction]
    let horizontalVariants: [CGGlyph: Construction]
    let minConnectorOverlap: Int

    init?(data: Data) {
        let bytes = [UInt8](data)
        let r = Reader(bytes)
        // MATH header: version(4) + three Offset16.
        guard let constantsOffset = r.u16(4),
              let glyphInfoOffset = r.u16(6),
              let variantsOffset = r.u16(8),
              let parsedConstants = Self.readConstants(r, at: constantsOffset)
        else { return nil }
        constants = parsedConstants

        var italic: [CGGlyph: Int] = [:]
        var accent: [CGGlyph: Int] = [:]
        if glyphInfoOffset != 0 {
            // MathGlyphInfo: italicsCorrectionInfo, topAccentAttachment,
            // extendedShapeCoverage, kernInfo.
            if let off = r.u16(glyphInfoOffset), off != 0 {
                italic = Self.readValueByGlyph(r, at: glyphInfoOffset + off)
            }
            if let off = r.u16(glyphInfoOffset + 2), off != 0 {
                accent = Self.readValueByGlyph(r, at: glyphInfoOffset + off)
            }
        }
        italicCorrection = italic
        topAccentAttachment = accent

        var vertical: [CGGlyph: Construction] = [:]
        var horizontal: [CGGlyph: Construction] = [:]
        var overlap = 0
        if variantsOffset != 0,
           let minOverlap = r.u16(variantsOffset),
           let vertCoverage = r.u16(variantsOffset + 2),
           let horizCoverage = r.u16(variantsOffset + 4),
           let vertCount = r.u16(variantsOffset + 6),
           let horizCount = r.u16(variantsOffset + 8) {
            overlap = minOverlap
            vertical = Self.readConstructions(r,
                                              base: variantsOffset,
                                              arrayOffset: variantsOffset + 10,
                                              count: vertCount,
                                              coverageOffset: vertCoverage)
            horizontal = Self.readConstructions(r,
                                                base: variantsOffset,
                                                arrayOffset: variantsOffset + 10 + vertCount * 2,
                                                count: horizCount,
                                                coverageOffset: horizCoverage)
        }
        verticalVariants = vertical
        horizontalVariants = horizontal
        minConnectorOverlap = overlap
    }

    // MARK: Sections

    private static func readConstants(_ r: Reader, at offset: Int) -> RawConstants? {
        guard offset != 0,
              let scriptPct = r.i16(offset),
              let scriptScriptPct = r.i16(offset + 2),
              let subFormulaMin = r.u16(offset + 4),
              let displayOpMin = r.u16(offset + 6)
        else { return nil }
        _ = subFormulaMin
        // 51 MathValueRecords {int16 value, Offset16 device}. The device
        // tables are ppem-specific corrections for hinted rasterisation
        // and are deliberately ignored — this draws vector outlines.
        var values: [Int] = []
        values.reserveCapacity(51)
        for i in 0..<51 {
            guard let value = r.i16(offset + 8 + i * 4) else { return nil }
            values.append(value)
        }
        guard let degreeRaise = r.i16(offset + 8 + 51 * 4) else { return nil }
        var c = RawConstants()
        c.scriptPercentScaleDown = scriptPct
        c.scriptScriptPercentScaleDown = scriptScriptPct
        c.displayOperatorMinHeight = displayOpMin
        c.radicalDegreeBottomRaisePercent = degreeRaise
        c.values = values
        return c
    }

    /// `MathItalicsCorrectionInfo` and `MathTopAccentAttachment` share a
    /// shape: a coverage table plus a parallel array of MathValueRecords.
    private static func readValueByGlyph(_ r: Reader, at offset: Int) -> [CGGlyph: Int] {
        guard let coverageOffset = r.u16(offset),
              let count = r.u16(offset + 2),
              coverageOffset != 0
        else { return [:] }
        let glyphs = readCoverage(r, at: offset + coverageOffset)
        var out: [CGGlyph: Int] = [:]
        for (index, glyph) in glyphs.enumerated() where index < count {
            if let value = r.i16(offset + 4 + index * 4) { out[glyph] = value }
        }
        return out
    }

    private static func readConstructions(_ r: Reader,
                                          base: Int,
                                          arrayOffset: Int,
                                          count: Int,
                                          coverageOffset: Int) -> [CGGlyph: Construction] {
        guard coverageOffset != 0 else { return [:] }
        let glyphs = readCoverage(r, at: base + coverageOffset)
        var out: [CGGlyph: Construction] = [:]
        for (index, glyph) in glyphs.enumerated() where index < count {
            guard let off = r.u16(arrayOffset + index * 2), off != 0,
                  let construction = readConstruction(r, at: base + off)
            else { continue }
            out[glyph] = construction
        }
        return out
    }

    private static func readConstruction(_ r: Reader, at offset: Int) -> Construction? {
        guard let assemblyOffset = r.u16(offset),
              let variantCount = r.u16(offset + 2)
        else { return nil }
        var variants: [VariantRecord] = []
        variants.reserveCapacity(variantCount)
        for i in 0..<variantCount {
            guard let glyph = r.u16(offset + 4 + i * 4),
                  let advance = r.u16(offset + 6 + i * 4)
            else { break }
            variants.append(VariantRecord(glyph: CGGlyph(glyph), advance: advance))
        }
        var assembly: Assembly? = nil
        if assemblyOffset != 0 {
            let a = offset + assemblyOffset
            // GlyphAssembly: italicsCorrection (MathValueRecord, 4 bytes)
            // then partCount, then 10-byte part records.
            if let partCount = r.u16(a + 4) {
                var parts: [AssemblyPart] = []
                parts.reserveCapacity(partCount)
                for i in 0..<partCount {
                    let p = a + 6 + i * 10
                    guard let glyph = r.u16(p),
                          let start = r.u16(p + 2),
                          let end = r.u16(p + 4),
                          let full = r.u16(p + 6),
                          let flags = r.u16(p + 8)
                    else { break }
                    parts.append(AssemblyPart(glyph: CGGlyph(glyph),
                                              startConnector: start,
                                              endConnector: end,
                                              fullAdvance: full,
                                              isExtender: flags & 0x0001 != 0))
                }
                if !parts.isEmpty { assembly = Assembly(parts: parts) }
            }
        }
        return Construction(variants: variants, assembly: assembly)
    }

    /// Most glyph entries one coverage table may contribute. A range
    /// list is bounded by the file only in how many ranges it declares,
    /// not in how much work they add up to — see `readCoverage`.
    private static let coverageEntryCeiling = 1 << 18

    /// Glyph ids in coverage order — which IS the index into every
    /// parallel array in this table.
    private static func readCoverage(_ r: Reader, at offset: Int) -> [CGGlyph] {
        guard let format = r.u16(offset), let count = r.u16(offset + 2) else { return [] }
        switch format {
        case 1:
            var out: [CGGlyph] = []
            out.reserveCapacity(count)
            for i in 0..<count {
                guard let g = r.u16(offset + 4 + i * 2) else { break }
                out.append(CGGlyph(g))
            }
            return out
        case 2:
            // Ranges carry their own start index, so the result has to
            // be placed by index rather than appended.
            //
            // The inner walk is the one place in this reader where the
            // WORK is not bounded by the table's size: every field here
            // is a `u16`, so a font may declare 65535 ranges of 65536
            // glyphs each — 4.3 billion insertions into a dictionary
            // whose keys cannot exceed 131070 by construction, i.e.
            // billions of overwrites of the same slots. This parse runs
            // on the MainActor the first time an equation is drawn, so
            // the cost of a hostile or corrupt font is a frozen window
            // rather than a bad glyph, and every read below it would
            // still have been in bounds. `coverageEntryCeiling` is far
            // above anything a real font asks for — STIX Two Math's
            // largest coverage spends 2652 — and is twice the number of
            // distinct entries the result can hold.
            var byIndex: [Int: CGGlyph] = [:]
            var placed = 0
            ranges: for i in 0..<count {
                let rec = offset + 4 + i * 6
                guard let start = r.u16(rec),
                      let end = r.u16(rec + 2),
                      let startIndex = r.u16(rec + 4),
                      end >= start
                else { break }
                for g in start...end {
                    byIndex[startIndex + g - start] = CGGlyph(g)
                    placed += 1
                    if placed >= coverageEntryCeiling { break ranges }
                }
            }
            guard let highest = byIndex.keys.max() else { return [] }
            return (0...highest).map { byIndex[$0] ?? 0 }
        default:
            return []
        }
    }

    // MARK: Bounds-checked cursor

    private struct Reader {
        let bytes: [UInt8]
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 1 < bytes.count else { return nil }
            return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }
        func i16(_ offset: Int) -> Int? {
            guard let raw = u16(offset) else { return nil }
            return Int(Int16(bitPattern: UInt16(raw)))
        }
    }
}
