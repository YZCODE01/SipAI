// MathAlphabets.swift
// Bare letter → the shape mathematics is set in.
//
// Variables are ITALIC and operator names are UPRIGHT — that difference
// is what tells `dx` (a differential of x) from `\text{dx}` (two
// letters) — and both come from Unicode's Mathematical Alphanumeric
// Symbols block rather than from a second font file, so one font covers
// a whole expression and nothing has to be matched across families.
//
// Read by the display typesetter (`MathParser`) and, for the alphabets
// whose Unicode forms are legible in prose, by the inline approximation
// (`LatexSymbols`).

import Foundation

/// Which alphabet a run of letters is drawn from. Applied while parsing
/// — it maps to real Unicode — so the layout pass only ever sees
/// characters.
enum MathAlphabet {
    case italic, upright, bold, boldItalic, blackboard, script, fraktur, sansSerif, monospace
}

// MARK: - Alphabets

enum MathAlphabets {

    /// The alphabet command → target. `\mathit` is not the same as the
    /// default: it italicises a multi-letter run, where the default
    /// treats each letter as its own variable.
    static func command(_ name: String) -> MathAlphabet? {
        switch name {
        case "mathrm", "mathnormal_upright": return .upright
        case "mathit": return .italic
        case "mathbf", "boldsymbol", "bm", "pmb": return .bold
        case "mathbfit", "mathbfsf": return .boldItalic
        case "mathbb", "Bbb": return .blackboard
        case "mathcal", "mathscr": return .script
        case "mathfrak": return .fraktur
        case "mathsf": return .sansSerif
        case "mathtt": return .monospace
        default: return nil
        }
    }

    /// One character in `alphabet`, or nil when the character is not a
    /// letter (digits and punctuation are not re-shaped, except in the
    /// alphabets that define them).
    static func map(_ c: Character, to alphabet: MathAlphabet) -> String? {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else {
            return nil
        }
        let v = scalar.value
        let isUpper = v >= 65 && v <= 90
        let isLower = v >= 97 && v <= 122
        let isDigit = v >= 48 && v <= 57
        guard isUpper || isLower || isDigit else { return nil }

        switch alphabet {
        case .upright:
            return isDigit || isUpper || isLower ? String(c) : nil
        case .italic:
            guard !isDigit else { return String(c) }
            // Italic lowercase h is unassigned in the block; Unicode
            // routes it to PLANCK CONSTANT, and a font that has one has
            // the other.
            if c == "h" { return "\u{210E}" }
            return offset(v, upper: 0x1D434, lower: 0x1D44E, isUpper: isUpper)
        case .bold:
            if isDigit { return offsetDigit(v, base: 0x1D7CE) }
            return offset(v, upper: 0x1D400, lower: 0x1D41A, isUpper: isUpper)
        case .boldItalic:
            guard !isDigit else { return offsetDigit(v, base: 0x1D7CE) }
            return offset(v, upper: 0x1D468, lower: 0x1D482, isUpper: isUpper)
        case .blackboard:
            if isDigit { return offsetDigit(v, base: 0x1D7D8) }
            if isUpper, let exception = blackboardExceptions[c] { return String(exception) }
            return offset(v, upper: 0x1D538, lower: 0x1D552, isUpper: isUpper)
        case .script:
            guard !isDigit else { return String(c) }
            if let exception = scriptExceptions[c] { return String(exception) }
            return offset(v, upper: 0x1D49C, lower: 0x1D4B6, isUpper: isUpper)
        case .fraktur:
            guard !isDigit else { return String(c) }
            if let exception = frakturExceptions[c] { return String(exception) }
            return offset(v, upper: 0x1D504, lower: 0x1D51E, isUpper: isUpper)
        case .sansSerif:
            if isDigit { return offsetDigit(v, base: 0x1D7E2) }
            return offset(v, upper: 0x1D5A0, lower: 0x1D5BA, isUpper: isUpper)
        case .monospace:
            if isDigit { return offsetDigit(v, base: 0x1D7F6) }
            return offset(v, upper: 0x1D670, lower: 0x1D68A, isUpper: isUpper)
        }
    }

    /// Every letter of `s`, mapped. Characters with no mapping (spaces,
    /// punctuation) pass through.
    static func mapString(_ s: String, to alphabet: MathAlphabet) -> String {
        s.map { map($0, to: alphabet) ?? String($0) }.joined()
    }

    private static func offset(_ v: UInt32, upper: UInt32, lower: UInt32,
                               isUpper: Bool) -> String? {
        let base = isUpper ? upper : lower
        let index = isUpper ? v - 65 : v - 97
        guard let scalar = Unicode.Scalar(base + index) else { return nil }
        return String(Character(scalar))
    }

    private static func offsetDigit(_ v: UInt32, base: UInt32) -> String? {
        guard let scalar = Unicode.Scalar(base + (v - 48)) else { return nil }
        return String(Character(scalar))
    }

    /// Letters Unicode assigned before the block existed, so the block
    /// leaves holes where they are.
    private static let blackboardExceptions: [Character: Character] = [
        "C": "\u{2102}", "H": "\u{210D}", "N": "\u{2115}", "P": "\u{2119}",
        "Q": "\u{211A}", "R": "\u{211D}", "Z": "\u{2124}",
    ]
    private static let scriptExceptions: [Character: Character] = [
        "B": "\u{212C}", "E": "\u{2130}", "F": "\u{2131}", "H": "\u{210B}",
        "I": "\u{2110}", "L": "\u{2112}", "M": "\u{2133}", "R": "\u{211B}",
        "e": "\u{212F}", "g": "\u{210A}", "o": "\u{2134}",
    ]
    private static let frakturExceptions: [Character: Character] = [
        "C": "\u{212D}", "H": "\u{210C}", "I": "\u{2111}", "R": "\u{211C}",
        "Z": "\u{2128}",
    ]
}
