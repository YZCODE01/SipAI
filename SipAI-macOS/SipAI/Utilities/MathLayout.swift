// MathLayout.swift
// Atom tree → positioned boxes, following the rules TeX lays out
// mathematics by, with the numbers taken from the font's own `MATH`
// table (`MathFont.swift`) rather than invented.
//
// A box carries WIDTH, ASCENT and DESCENT rather than a frame, because
// mathematics is assembled about a baseline and about the AXIS — the
// height a fraction bar, a relation and a growing delimiter all centre
// on. Everything vertical here is measured from the baseline, positive
// upward, and the view flips once at the end.
//
// Heights come from INK, not from line metrics: a box's job is to say
// how much room the marks in it actually occupy, and every glyph in a
// font shares one ascent.

import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - Boxes

final class MathBox {
    struct Child {
        var dx: CGFloat
        /// Positive is UP, so a subscript's offset reads as negative.
        var dy: CGFloat
        var box: MathBox
    }

    struct GlyphRun {
        var glyphs: [CGGlyph]
        var positions: [CGPoint]
        var font: CTFont
        /// Drawn in the error tint. Reserved for a command this parser
        /// does not implement — the reader is told, rather than shown a
        /// confident wrong reading.
        var isError = false
    }

    enum Content {
        case empty
        case runs([GlyphRun])
        /// Filled rectangle, relative to this box's baseline origin.
        case rule(CGRect)
        /// Stroked rectangle — the frame `\boxed` draws.
        case frame(CGRect, CGFloat)
        case children([Child])
    }

    var width: CGFloat = 0
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    /// Slant overhang of the last glyph. A superscript that ignores it
    /// collides with the letter it belongs to.
    var italicCorrection: CGFloat = 0
    var content: Content = .empty

    init() {}

    static func spacer(_ width: CGFloat) -> MathBox {
        let box = MathBox()
        box.width = width
        return box
    }

    /// Assemble children already positioned relative to a shared
    /// baseline, taking the union of their extents.
    static func stack(_ children: [Child]) -> MathBox {
        let box = MathBox()
        box.content = .children(children)
        var maxX: CGFloat = 0
        for child in children {
            box.ascent = max(box.ascent, child.dy + child.box.ascent)
            box.descent = max(box.descent, child.box.descent - child.dy)
            maxX = max(maxX, child.dx + child.box.width)
        }
        box.width = maxX
        return box
    }

    var height: CGFloat { ascent + descent }
}

// MARK: - Style

enum MathStyle {
    case display, text, script, scriptScript

    var isDisplay: Bool { self == .display }

    /// The style a superscript, subscript or limit is set in.
    var scriptStyle: MathStyle {
        switch self {
        case .display, .text: return .script
        case .script, .scriptScript: return .scriptScript
        }
    }

    /// A fraction sets its parts one step smaller.
    var fractionStyle: MathStyle {
        switch self {
        case .display: return .text
        case .text: return .script
        case .script, .scriptScript: return .scriptScript
        }
    }

    /// Whether inter-atom spacing that TeX marks text-style-only is
    /// suppressed.
    var suppressesWideSpacing: Bool {
        self == .script || self == .scriptScript
    }

    func fontSize(base: CGFloat, constants: MathConstants) -> CGFloat {
        switch self {
        case .display, .text: return base
        case .script: return base * constants.scriptPercentScaleDown
        case .scriptScript: return base * constants.scriptScriptPercentScaleDown
        }
    }
}

// MARK: - Typesetter

/// Lays a parsed `MathList` out at a given point size.
///
/// nil from `layout` means the math font is unavailable — never that the
/// expression was unsupported, which is what makes the caller's fallback
/// a font question and not a content one.
struct MathTypesetter {

    let resource: MathFontResource
    /// Point size of the base style.
    let baseSize: CGFloat

    private var constants: MathConstants { resource.constants }

    init?(size: CGFloat) {
        guard let resource = MathFontResource.shared else { return nil }
        self.resource = resource
        self.baseSize = size
    }

    /// TeX's `\delimiterfactor` / `\delimitershortfall`: a delimiter
    /// covers at least 90% of what it wraps, or comes within 5pt of it,
    /// whichever asks for less.
    private let delimiterFactor: CGFloat = 0.901
    private var delimiterShortfall: CGFloat { baseSize * 0.4 }

    // MARK: Entry point

    func layout(_ list: MathList, style: MathStyle) -> MathBox {
        var children: [MathBox.Child] = []
        var x: CGFloat = 0
        var previousClass: MathClass? = nil
        var lastItalic: CGFloat = 0

        for atom in list {
            let box = layout(atom: atom, style: style)
            if let previousClass {
                x += MathSpacing.between(previousClass, atom.mathClass,
                                         script: style.suppressesWideSpacing)
                    * style.fontSize(base: baseSize, constants: constants)
            }
            children.append(.init(dx: x, dy: 0, box: box))
            x += box.width
            lastItalic = box.italicCorrection
            previousClass = atom.mathClass
        }

        let assembled = MathBox.stack(children)
        assembled.width = x
        assembled.italicCorrection = lastItalic
        return assembled
    }

    // MARK: One atom

    private func layout(atom: MathAtom, style: MathStyle) -> MathBox {
        let nucleus = layoutNucleus(atom, style: style)
        guard atom.sub != nil || atom.sup != nil else { return nucleus }
        if usesLimits(atom, style: style) {
            return attachLimits(to: nucleus, atom: atom, style: style)
        }
        return attachScripts(to: nucleus, atom: atom, style: style)
    }

    /// Scripts sit above and below only for a large operator that asks
    /// for it, and only in display style — `\sum_{i=1}^{n}` inline would
    /// otherwise pull the line apart.
    private func usesLimits(_ atom: MathAtom, style: MathStyle) -> Bool {
        guard let limits = atom.limits else { return false }
        guard limits else { return false }
        // A large operator only stacks its scripts in display style;
        // `\overset` and friends always do, whatever the style.
        return style.isDisplay || atom.mathClass != .largeOperator
    }

    private func layoutNucleus(_ atom: MathAtom, style: MathStyle) -> MathBox {
        let size = style.fontSize(base: baseSize, constants: constants)
        switch atom.kind {
        case .glyphs(let text):
            if atom.mathClass == .largeOperator {
                return largeOperatorBox(text, style: style)
            }
            return glyphBox(text, size: size)
        case .text(let text):
            return glyphBox(text, size: size, preserveSpaces: true)
        case .unknown(let text):
            return glyphBox(text, size: size, isError: true)
        case .space(let em):
            return .spacer(em * size)
        case .list(let inner):
            return layout(inner, style: style)
        case .fraction(let numerator, let denominator, let bar):
            return fractionBox(numerator, denominator, bar: bar, style: style)
        case .radical(let index, let radicand):
            return radicalBox(index: index, radicand: radicand, style: style)
        case .delimited(let left, let body, let right):
            return delimitedBox(left: left, body: body, right: right, style: style)
        case .accent(let mark, let base):
            return accentBox(mark: mark, base: base, style: style)
        case .overUnder(let spec):
            return overUnderBox(spec, style: style)
        case .boxed(let inner):
            return boxedBox(inner, style: style)
        case .table(let table):
            return tableBox(table, style: style)
        }
    }

    // MARK: Glyph runs

    /// A run of characters set in the math font, measured by its ink.
    ///
    /// A character the math font lacks falls back to the system font
    /// rather than drawing `.notdef`: a missing glyph is a hollow box on
    /// screen, and it takes the reader's eye more surely than the
    /// character it replaced would have.
    private func glyphBox(_ text: String,
                          size: CGFloat,
                          preserveSpaces: Bool = false,
                          isError: Bool = false) -> MathBox {
        let box = MathBox()
        guard !text.isEmpty else { return box }
        let mathFont = resource.font(size: size)
        let fallbackFont = CTFontCreateWithName(
            NSFont.systemFont(ofSize: size).fontName as CFString, size, nil)

        var runs: [MathBox.GlyphRun] = []
        var current: [CGGlyph] = []
        var currentPositions: [CGPoint] = []
        var currentIsFallback = false
        var x: CGFloat = 0
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        var lastGlyph: CGGlyph? = nil

        func flush() {
            guard !current.isEmpty else { return }
            runs.append(.init(glyphs: current,
                              positions: currentPositions,
                              font: currentIsFallback ? fallbackFont : mathFont,
                              isError: isError))
            current = []
            currentPositions = []
        }

        for scalar in text.unicodeScalars {
            if scalar == " " && !preserveSpaces { continue }
            var glyph = resource.glyph(for: scalar)
            var usesFallback = false
            if glyph == nil {
                var utf16 = Array(String(scalar).utf16)
                var out = [CGGlyph](repeating: 0, count: utf16.count)
                if CTFontGetGlyphsForCharacters(fallbackFont, &utf16, &out, utf16.count),
                   let first = out.first, first != 0 {
                    glyph = first
                    usesFallback = true
                }
            }
            guard let glyph else { continue }
            if usesFallback != currentIsFallback {
                flush()
                currentIsFallback = usesFallback
            }
            let font = usesFallback ? fallbackFont : mathFont
            var one = [glyph]
            let advance = CTFontGetAdvancesForGlyphs(font, .horizontal, &one, nil, 1)
            let ink = CTFontGetBoundingRectsForGlyphs(font, .default, &one, nil, 1)
            current.append(glyph)
            currentPositions.append(CGPoint(x: x, y: 0))
            if !ink.isNull && ink.height > 0 {
                minY = min(minY, ink.minY)
                maxY = max(maxY, ink.maxY)
            }
            x += advance
            lastGlyph = usesFallback ? nil : glyph
        }
        flush()

        box.width = x
        box.ascent = maxY > -CGFloat.greatestFiniteMagnitude ? maxY : 0
        box.descent = minY < CGFloat.greatestFiniteMagnitude ? -minY : 0
        box.descent = max(box.descent, 0)
        box.content = .runs(runs)
        if let lastGlyph {
            box.italicCorrection = resource.italicCorrection(lastGlyph) * size
        }
        return box
    }

    /// A big operator, in the display size the font provides for it.
    private func largeOperatorBox(_ text: String, style: MathStyle) -> MathBox {
        let size = style.fontSize(base: baseSize, constants: constants)
        guard style.isDisplay,
              let scalar = text.unicodeScalars.first,
              text.unicodeScalars.count == 1,
              let glyph = resource.glyph(for: scalar)
        else {
            let box = glyphBox(text, size: size)
            return centreOnAxis(box, size: size)
        }
        let target = constants.displayOperatorMinHeight * size
        let chosen = verticalVariant(for: glyph, atLeast: target, size: size) ?? .glyph(glyph)
        let box = boxForStretchy(chosen, size: size, vertical: true)
        box.italicCorrection = resource.italicCorrection(glyph) * size
        return centreOnAxis(box, size: size)
    }

    /// Shift a box so its ink centres on the math axis — where an
    /// integral sign and a summation sign belong relative to the line.
    private func centreOnAxis(_ box: MathBox, size: CGFloat) -> MathBox {
        let axis = constants.axisHeight * size
        let centre = (box.ascent - box.descent) / 2
        let shift = axis - centre
        guard abs(shift) > 0.01 else { return box }
        let shifted = MathBox.stack([.init(dx: 0, dy: shift, box: box)])
        shifted.width = box.width
        shifted.italicCorrection = box.italicCorrection
        return shifted
    }

    // MARK: Scripts

    private func attachScripts(to nucleus: MathBox,
                               atom: MathAtom,
                               style: MathStyle) -> MathBox {
        let size = style.fontSize(base: baseSize, constants: constants)
        let scriptStyle = style.scriptStyle
        let supBox = atom.sup.map { layout($0, style: scriptStyle) }
        let subBox = atom.sub.map { layout($0, style: scriptStyle) }

        var children: [MathBox.Child] = [.init(dx: 0, dy: 0, box: nucleus)]
        let italic = nucleus.italicCorrection
        var width = nucleus.width

        switch (supBox, subBox) {
        case (.some(let sup), .none):
            let u = max(constants.superscriptShiftUp * size,
                        nucleus.ascent - constants.superscriptBaselineDropMax * size,
                        constants.superscriptBottomMin * size + sup.descent)
            children.append(.init(dx: nucleus.width + italic, dy: u, box: sup))
            width = nucleus.width + italic + sup.width + constants.spaceAfterScript * size
        case (.none, .some(let sub)):
            let v = max(constants.subscriptShiftDown * size,
                        nucleus.descent + constants.subscriptBaselineDropMin * size,
                        sub.ascent - constants.subscriptTopMax * size)
            children.append(.init(dx: nucleus.width, dy: -v, box: sub))
            width = nucleus.width + sub.width + constants.spaceAfterScript * size
        case (.some(let sup), .some(let sub)):
            var u = max(constants.superscriptShiftUp * size,
                        nucleus.ascent - constants.superscriptBaselineDropMax * size,
                        constants.superscriptBottomMin * size + sup.descent)
            var v = max(constants.subscriptShiftDown * size,
                        nucleus.descent + constants.subscriptBaselineDropMin * size)
            // The two must not close up on each other, and pushing them
            // apart is shared between them so neither runs into the line
            // above or below.
            let gap = (u - sup.descent) - (sub.ascent - v)
            let minGap = constants.subSuperscriptGapMin * size
            if gap < minGap {
                v += minGap - gap
                let overshoot = constants.superscriptBottomMaxWithSubscript * size
                    - (u - sup.descent)
                if overshoot > 0 {
                    u += overshoot
                    v -= overshoot
                }
            }
            children.append(.init(dx: nucleus.width + italic, dy: u, box: sup))
            children.append(.init(dx: nucleus.width, dy: -v, box: sub))
            width = nucleus.width + max(italic + sup.width, sub.width)
                + constants.spaceAfterScript * size
        case (.none, .none):
            return nucleus
        }

        let box = MathBox.stack(children)
        box.width = width
        return box
    }

    private func attachLimits(to nucleus: MathBox,
                              atom: MathAtom,
                              style: MathStyle) -> MathBox {
        let size = style.fontSize(base: baseSize, constants: constants)
        let scriptStyle = style.scriptStyle
        let upper = atom.sup.map { layout($0, style: scriptStyle) }
        let lower = atom.sub.map { layout($0, style: scriptStyle) }

        let width = max(nucleus.width, max(upper?.width ?? 0, lower?.width ?? 0))
        var children: [MathBox.Child] = [
            .init(dx: (width - nucleus.width) / 2, dy: 0, box: nucleus)
        ]
        if let upper {
            let rise = max(constants.upperLimitBaselineRiseMin * size + upper.descent,
                           nucleus.ascent + constants.upperLimitGapMin * size + upper.descent)
            children.append(.init(dx: (width - upper.width) / 2, dy: rise, box: upper))
        }
        if let lower {
            let drop = max(constants.lowerLimitBaselineDropMin * size + lower.ascent,
                           nucleus.descent + constants.lowerLimitGapMin * size + lower.ascent)
            children.append(.init(dx: (width - lower.width) / 2, dy: -drop, box: lower))
        }
        let box = MathBox.stack(children)
        box.width = width
        return box
    }

    // MARK: Fractions

    private func fractionBox(_ numerator: MathList,
                             _ denominator: MathList,
                             bar: Bool,
                             style: MathStyle) -> MathBox {
        let size = style.fontSize(base: baseSize, constants: constants)
        let partStyle = style.fractionStyle
        let num = layout(numerator, style: partStyle)
        let den = layout(denominator, style: partStyle)
        let axis = constants.axisHeight * size
        let thickness = bar ? constants.fractionRuleThickness * size : 0

        var numShift: CGFloat
        var denShift: CGFloat
        var numGapMin: CGFloat
        var denGapMin: CGFloat
        if bar {
            numShift = (style.isDisplay ? constants.fractionNumeratorDisplayStyleShiftUp
                                        : constants.fractionNumeratorShiftUp) * size
            denShift = (style.isDisplay ? constants.fractionDenominatorDisplayStyleShiftDown
                                        : constants.fractionDenominatorShiftDown) * size
            numGapMin = (style.isDisplay ? constants.fractionNumDisplayStyleGapMin
                                         : constants.fractionNumeratorGapMin) * size
            denGapMin = (style.isDisplay ? constants.fractionDenomDisplayStyleGapMin
                                         : constants.fractionDenominatorGapMin) * size
        } else {
            numShift = constants.stackTopDisplayStyleShiftUp * size
            denShift = constants.stackBottomDisplayStyleShiftDown * size
            numGapMin = constants.stackDisplayStyleGapMin * size
            denGapMin = constants.stackDisplayStyleGapMin * size
        }

        // The bar has thickness, so both gaps are measured to its edges,
        // not to the axis.
        let barTop = axis + thickness / 2
        let barBottom = axis - thickness / 2
        let numGap = (numShift - num.descent) - barTop
        if numGap < numGapMin { numShift += numGapMin - numGap }
        let denGap = barBottom - (den.ascent - denShift)
        if denGap < denGapMin { denShift += denGapMin - denGap }

        // A little air either side, or the bar ends flush with the
        // widest term and reads as an underline.
        let padding = size * 0.12
        let contentWidth = max(num.width, den.width)
        let width = contentWidth + 2 * padding

        var children: [MathBox.Child] = [
            .init(dx: (width - num.width) / 2, dy: numShift, box: num),
            .init(dx: (width - den.width) / 2, dy: -denShift, box: den),
        ]
        if bar {
            let rule = MathBox()
            rule.width = width
            rule.content = .rule(CGRect(x: 0, y: barBottom, width: width, height: thickness))
            rule.ascent = barTop
            rule.descent = max(0, -barBottom)
            children.append(.init(dx: 0, dy: 0, box: rule))
        }
        let box = MathBox.stack(children)
        box.width = width
        return box
    }

    // MARK: Radicals

    private func radicalBox(index: MathList?,
                            radicand: MathList,
                            style: MathStyle) -> MathBox {
        let size = style.fontSize(base: baseSize, constants: constants)
        let body = layout(radicand, style: style)
        let gap = (style.isDisplay ? constants.radicalDisplayStyleVerticalGap
                                   : constants.radicalVerticalGap) * size
        let ruleThickness = constants.radicalRuleThickness * size
        let target = body.height + gap + ruleThickness

        guard let radicalScalar = Unicode.Scalar(0x221A),
              let radicalGlyph = resource.glyph(for: radicalScalar) else {
            return body
        }
        let chosen = verticalVariant(for: radicalGlyph, atLeast: target, size: size)
            ?? .glyph(radicalGlyph)
        let sign = boxForStretchy(chosen, size: size, vertical: true)

        // The rule continues the radical's own top edge across the
        // radicand, so the sign is placed by where its INK top has to
        // land rather than by a baseline of its own.
        let desiredTop = body.ascent + gap + ruleThickness
        let signShift = desiredTop - sign.ascent

        var children: [MathBox.Child] = [
            .init(dx: 0, dy: signShift, box: sign),
            .init(dx: sign.width, dy: 0, box: body),
        ]

        let rule = MathBox()
        rule.width = sign.width + body.width
        rule.content = .rule(CGRect(x: sign.width,
                                    y: desiredTop - ruleThickness,
                                    width: body.width,
                                    height: ruleThickness))
        rule.ascent = desiredTop
        rule.descent = 0
        children.append(.init(dx: 0, dy: 0, box: rule))

        var box = MathBox.stack(children)
        box.width = sign.width + body.width
        box.ascent = max(box.ascent, desiredTop + constants.radicalExtraAscender * size)

        if let index {
            let degree = layout(index, style: .scriptScript)
            let raise = constants.radicalDegreeBottomRaisePercent * box.height
            let kernBefore = constants.radicalKernBeforeDegree * size
            let kernAfter = constants.radicalKernAfterDegree * size
            // `radicalKernAfterDegree` is negative — the degree tucks
            // into the radical's own hook.
            let degreeWidth = max(0, kernBefore + degree.width + kernAfter)
            let shifted = MathBox.stack([
                .init(dx: kernBefore, dy: -box.descent + raise, box: degree),
                .init(dx: degreeWidth, dy: 0, box: box),
            ])
            shifted.width = degreeWidth + box.width
            box = shifted
        }
        return box
    }

    // MARK: Delimiters

    private func delimitedBox(left: String,
                              body: MathList,
                              right: String,
                              style: MathStyle) -> MathBox {
        let size = style.fontSize(base: baseSize, constants: constants)
        let inner = layout(body, style: style)
        let axis = constants.axisHeight * size
        let reach = max(inner.ascent - axis, inner.descent + axis)
        let target = max(reach * 2 * delimiterFactor, reach * 2 - delimiterShortfall)

        var children: [MathBox.Child] = []
        var x: CGFloat = 0
        if let leftBox = delimiterBox(left, height: target, size: size) {
            children.append(.init(dx: 0, dy: 0, box: leftBox))
            x += leftBox.width
        }
        children.append(.init(dx: x, dy: 0, box: inner))
        x += inner.width
        if let rightBox = delimiterBox(right, height: target, size: size) {
            children.append(.init(dx: x, dy: 0, box: rightBox))
            x += rightBox.width
        }
        let box = MathBox.stack(children)
        box.width = x
        return box
    }

    /// One delimiter, grown to `height` and centred on the axis. nil for
    /// `\left.` — an omitted delimiter takes no space at all.
    private func delimiterBox(_ delimiter: String,
                              height: CGFloat,
                              size: CGFloat) -> MathBox? {
        guard !delimiter.isEmpty else { return nil }
        guard let scalar = delimiter.unicodeScalars.first,
              delimiter.unicodeScalars.count == 1,
              let glyph = resource.glyph(for: scalar) else {
            return glyphBox(delimiter, size: size)
        }
        let chosen = verticalVariant(for: glyph, atLeast: height, size: size) ?? .glyph(glyph)
        let box = boxForStretchy(chosen, size: size, vertical: true)
        return centreOnAxis(box, size: size)
    }

    // MARK: Accents

    private func accentBox(mark: String, base: MathList, style: MathStyle) -> MathBox {
        let size = style.fontSize(base: baseSize, constants: constants)
        let baseBox = layout(base, style: style)
        guard let scalar = mark.unicodeScalars.first,
              mark.unicodeScalars.count == 1,
              let glyph = resource.glyph(for: scalar) else { return baseBox }
        let font = resource.font(size: size)
        var one = [glyph]
        let ink = CTFontGetBoundingRectsForGlyphs(font, .default, &one, nil, 1)
        guard !ink.isNull, ink.width > 0 else { return baseBox }

        // A COMBINING mark carries no advance and draws to the LEFT of
        // the pen, so neither its origin nor its advance says where it
        // will land. Everything here is measured from its INK: the glyph
        // is nudged so the box starts at the ink's left edge, and the
        // box is then placed so the ink's BOTTOM sits on the base.
        // Placed by origin instead, the mark appears up and to the left
        // of the letter it belongs to and reads as a stray symbol.
        let markBox = MathBox()
        markBox.width = ink.width
        markBox.ascent = ink.maxY
        markBox.descent = max(0, -ink.minY)
        markBox.content = .runs([.init(glyphs: [glyph],
                                       positions: [CGPoint(x: -ink.minX, y: 0)],
                                       font: font)])

        // Where the accent centres: the font's own attachment point for
        // a single glyph, the middle of the box otherwise. A slanted
        // letter's visual centre is not its advance's centre.
        var centre = baseBox.width / 2
        if case .runs(let runs) = baseBox.content,
           runs.count == 1, runs[0].glyphs.count == 1,
           let attachment = resource.topAccentAttachment(runs[0].glyphs[0]) {
            centre = attachment * size
        }

        // A tall base carries its accent up with it; a short one must
        // not pull it below the height accents sit at, or the bars of
        // `\bar x` and `\bar X` disagree inside one expression.
        let inkBottom = max(baseBox.ascent, constants.accentBaseHeight * size)
        let box = MathBox.stack([
            .init(dx: 0, dy: 0, box: baseBox),
            .init(dx: centre - ink.width / 2, dy: inkBottom - ink.minY, box: markBox),
        ])
        box.width = baseBox.width
        box.italicCorrection = baseBox.italicCorrection
        return box
    }

    // MARK: Over / under ornaments

    private func overUnderBox(_ spec: MathAtom.OverUnder, style: MathStyle) -> MathBox {
        let size = style.fontSize(base: baseSize, constants: constants)
        let base = layout(spec.base, style: style)
        let gap = (spec.above ? constants.overbarVerticalGap
                              : constants.underbarVerticalGap) * size
        let thickness = (spec.above ? constants.overbarRuleThickness
                                    : constants.underbarRuleThickness) * size

        var ornament: MathBox
        switch spec.ornament {
        case .bar:
            let rule = MathBox()
            rule.width = base.width
            rule.ascent = thickness
            rule.content = .rule(CGRect(x: 0, y: 0, width: base.width, height: thickness))
            ornament = rule
        case .brace:
            ornament = stretchedHorizontally(spec.above ? 0x23DE : 0x23DF,
                                             to: base.width, size: size)
        case .arrow:
            ornament = stretchedHorizontally(0x27F6, to: base.width, size: size)
        }

        let dy: CGFloat = spec.above
            ? base.ascent + gap + ornament.descent
            : -(base.descent + gap + ornament.ascent)
        let box = MathBox.stack([
            .init(dx: 0, dy: 0, box: base),
            .init(dx: max(0, (base.width - ornament.width) / 2), dy: dy, box: ornament),
        ])
        box.width = max(base.width, ornament.width)
        if spec.above {
            box.ascent += constants.overbarExtraAscender * size
        } else {
            box.descent += constants.underbarExtraDescender * size
        }
        return box
    }

    private func stretchedHorizontally(_ codePoint: UInt32,
                                       to width: CGFloat,
                                       size: CGFloat) -> MathBox {
        guard let scalar = Unicode.Scalar(codePoint),
              let glyph = resource.glyph(for: scalar) else { return MathBox() }
        let chosen = horizontalVariant(for: glyph, atLeast: width, size: size)
            ?? .glyph(glyph)
        return boxForStretchy(chosen, size: size, vertical: false)
    }

    // MARK: Boxed

    private func boxedBox(_ inner: MathList, style: MathStyle) -> MathBox {
        let size = style.fontSize(base: baseSize, constants: constants)
        let body = layout(inner, style: style)
        let pad = size * 0.28
        let thickness = constants.overbarRuleThickness * size
        let frame = MathBox()
        frame.width = body.width + 2 * pad
        frame.ascent = body.ascent + pad
        frame.descent = body.descent + pad
        frame.content = .frame(CGRect(x: 0,
                                      y: -body.descent - pad,
                                      width: body.width + 2 * pad,
                                      height: body.height + 2 * pad),
                               thickness)
        let box = MathBox.stack([
            .init(dx: 0, dy: 0, box: frame),
            .init(dx: pad, dy: 0, box: body),
        ])
        box.width = frame.width
        return box
    }

    // MARK: Tables

    private func tableBox(_ table: MathTableNode, style: MathStyle) -> MathBox {
        let size = style.fontSize(base: baseSize, constants: constants)
        // Rows of an environment are set in the enclosing style, so a
        // display equation's matrix keeps display-sized fractions.
        let cellStyle: MathStyle = style == .display ? .display : style
        let laid = table.rows.map { row in row.map { layout($0, style: cellStyle) } }
        let columns = laid.map(\.count).max() ?? 0
        guard columns > 0 else { return MathBox() }

        var columnWidths = [CGFloat](repeating: 0, count: columns)
        for row in laid {
            for (c, cell) in row.enumerated() {
                columnWidths[c] = max(columnWidths[c], cell.width)
            }
        }
        let gap = table.columnGap * size
        let rowGap = size * 0.35

        // Stack rows about their own baselines, then centre the whole
        // stack on the axis so a matrix sits where a symbol would.
        var rowBoxes: [MathBox] = []
        for row in laid {
            var children: [MathBox.Child] = []
            var x: CGFloat = 0
            for c in 0..<columns {
                let cell = c < row.count ? row[c] : MathBox()
                let slot = columnWidths[c]
                let dx: CGFloat
                switch table.alignments[min(c, table.alignments.count - 1)] {
                case .leading: dx = 0
                case .center: dx = (slot - cell.width) / 2
                case .trailing: dx = slot - cell.width
                }
                children.append(.init(dx: x + dx, dy: 0, box: cell))
                x += slot + (c == columns - 1 ? 0 : gap)
            }
            let rowBox = MathBox.stack(children)
            rowBox.width = x
            // An empty row still occupies a line.
            rowBox.ascent = max(rowBox.ascent, size * 0.5)
            rowBox.descent = max(rowBox.descent, size * 0.2)
            rowBoxes.append(rowBox)
        }

        var children: [MathBox.Child] = []
        var y: CGFloat = 0
        for (index, row) in rowBoxes.enumerated() {
            if index > 0 { y -= rowGap + row.ascent }
            children.append(.init(dx: 0, dy: y, box: row))
            y -= row.descent
        }
        let stacked = MathBox.stack(children)
        stacked.width = rowBoxes.map(\.width).max() ?? 0
        let centred = centreOnAxis(stacked, size: size)

        guard table.left != nil || table.right != nil else { return centred }
        let height = max(centred.ascent - constants.axisHeight * size,
                         centred.descent + constants.axisHeight * size) * 2
        var wrapped: [MathBox.Child] = []
        var x: CGFloat = 0
        if let left = table.left,
           let leftBox = delimiterBox(left, height: height, size: size) {
            wrapped.append(.init(dx: 0, dy: 0, box: leftBox))
            x += leftBox.width + size * 0.15
        }
        wrapped.append(.init(dx: x, dy: 0, box: centred))
        x += centred.width
        if let right = table.right,
           let rightBox = delimiterBox(right, height: height, size: size) {
            wrapped.append(.init(dx: x, dy: 0, box: rightBox))
            x += rightBox.width
        }
        let box = MathBox.stack(wrapped)
        box.width = x
        return box
    }

    // MARK: Stretchy glyph selection

    private enum Stretchy {
        case glyph(CGGlyph)
        case assembled(MathGlyphAssembly, CGFloat)
    }

    private func verticalVariant(for glyph: CGGlyph,
                                 atLeast target: CGFloat,
                                 size: CGFloat) -> Stretchy? {
        let variants = resource.variants(glyph, vertical: true)
        for variant in variants where variant.advance * size >= target {
            return .glyph(variant.glyph)
        }
        if let assembly = resource.assembly(glyph, vertical: true) {
            return .assembled(assembly, target)
        }
        return variants.last.map { .glyph($0.glyph) }
    }

    private func horizontalVariant(for glyph: CGGlyph,
                                   atLeast target: CGFloat,
                                   size: CGFloat) -> Stretchy? {
        let variants = resource.variants(glyph, vertical: false)
        for variant in variants where variant.advance * size >= target {
            return .glyph(variant.glyph)
        }
        if let assembly = resource.assembly(glyph, vertical: false) {
            return .assembled(assembly, target)
        }
        return variants.last.map { .glyph($0.glyph) }
    }

    /// Box for a chosen stretchy form. An assembly repeats its extender
    /// parts until it reaches the target, which is how a brace grows
    /// past its largest cut variant without being scaled — a scaled
    /// brace thins its own strokes.
    private func boxForStretchy(_ stretchy: Stretchy,
                                size: CGFloat,
                                vertical: Bool) -> MathBox {
        let font = resource.font(size: size)
        switch stretchy {
        case .glyph(let glyph):
            var one = [glyph]
            let advance = CTFontGetAdvancesForGlyphs(font, .horizontal, &one, nil, 1)
            let ink = CTFontGetBoundingRectsForGlyphs(font, .default, &one, nil, 1)
            let box = MathBox()
            box.width = advance
            box.ascent = ink.isNull ? 0 : ink.maxY
            box.descent = ink.isNull ? 0 : max(0, -ink.minY)
            box.content = .runs([.init(glyphs: [glyph],
                                       positions: [.zero],
                                       font: font)])
            return box

        case .assembled(let assembly, let target):
            let overlap = assembly.minConnectorOverlap * size
            let extenders = assembly.parts.filter(\.isExtender)
            let fixedAdvance = assembly.parts
                .filter { !$0.isExtender }
                .reduce(0) { $0 + $1.fullAdvance * size }
            let extenderAdvance = extenders.reduce(0) { $0 + $1.fullAdvance * size }
            let joints = max(assembly.parts.count - 1, 1)
            var repeats = 1
            if extenderAdvance > overlap {
                // Each added copy contributes its advance less one
                // overlap.
                let deficit = target - (fixedAdvance + extenderAdvance
                    - CGFloat(joints) * overlap)
                if deficit > 0 {
                    repeats += Int(ceil(deficit / (extenderAdvance - overlap)))
                }
            }
            repeats = min(repeats, 64)

            var glyphs: [CGGlyph] = []
            var positions: [CGPoint] = []
            var cursor: CGFloat = 0
            var maxCross: CGFloat = 0
            for part in assembly.parts {
                let copies = part.isExtender ? repeats : 1
                for _ in 0..<copies {
                    var one = [part.glyph]
                    let ink = CTFontGetBoundingRectsForGlyphs(font, .default, &one, nil, 1)
                    if vertical {
                        // Parts are listed bottom to top and drawn from
                        // their own baselines, so each is offset to sit
                        // where the run has reached.
                        positions.append(CGPoint(x: 0, y: cursor - (ink.isNull ? 0 : ink.minY)))
                        maxCross = max(maxCross, ink.isNull ? 0 : ink.width)
                    } else {
                        positions.append(CGPoint(x: cursor - (ink.isNull ? 0 : ink.minX), y: 0))
                        maxCross = max(maxCross, ink.isNull ? 0 : ink.height)
                    }
                    glyphs.append(part.glyph)
                    cursor += part.fullAdvance * size - overlap
                }
            }
            cursor += overlap

            let box = MathBox()
            box.content = .runs([.init(glyphs: glyphs, positions: positions, font: font)])
            if vertical {
                var one = [assembly.parts[0].glyph]
                let advance = CTFontGetAdvancesForGlyphs(font, .horizontal, &one, nil, 1)
                box.width = advance
                box.ascent = cursor
                box.descent = 0
            } else {
                box.width = cursor
                box.ascent = maxCross
                box.descent = 0
            }
            return box
        }
    }
}

// MARK: - Drawing

extension MathBox {
    /// Draw into a context whose origin is this box's baseline-left and
    /// whose Y axis points UP.
    func draw(in context: CGContext, color: CGColor, errorColor: CGColor) {
        switch content {
        case .empty:
            return
        case .runs(let runs):
            for run in runs {
                context.setFillColor(run.isError ? errorColor : color)
                var glyphs = run.glyphs
                var positions = run.positions
                CTFontDrawGlyphs(run.font, &glyphs, &positions, glyphs.count, context)
            }
        case .rule(let rect):
            context.setFillColor(color)
            context.fill(rect)
        case .frame(let rect, let thickness):
            context.setStrokeColor(color)
            context.setLineWidth(thickness)
            context.stroke(rect.insetBy(dx: thickness / 2, dy: thickness / 2))
        case .children(let children):
            for child in children {
                context.saveGState()
                context.translateBy(x: child.dx, y: child.dy)
                child.box.draw(in: context, color: color, errorColor: errorColor)
                context.restoreGState()
            }
        }
    }
}
