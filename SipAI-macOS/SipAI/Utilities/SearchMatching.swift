// SearchMatching.swift
// The one place that decides what "a match" is, shared by the global
// palette (ContentView's toolbar) and the per-conversation find bars.
//
// Two rules hold this together, and both exist because a counter that
// disagrees with the highlights is worse than no counter at all:
//
//   1. **One comparison, everywhere.** Every count and every highlight
//      goes through `SearchMatching`, with the same options
//      (`.caseInsensitive` + `.diacriticInsensitive`) and the same nil
//      locale. A second spelling of "contains" anywhere in the feature
//      is how "3 of 47" comes to name a match nothing tinted.
//
//   2. **Matching is defined on DISPLAYED text, never on source.** The
//      transcript shows markdown *rendered* — `**bold**` reaches the
//      screen as `bold`, `_x` as a subscript, an inline-code span byte
//      exact. Counting the source would find matches inside syntax the
//      reader cannot see, and would miss the LaTeX translations they
//      can. `MarkdownRenderer.plainText` produces exactly the string
//      the renderer will draw, in draw order, and the find engines
//      count in that.
//
// Matches are NON-OVERLAPPING and left-to-right, so the k-th match of a
// row is the same k on both sides of the feature.

import SwiftUI
import AppKit

// MARK: - Matching

enum SearchMatching {

    /// The comparison every part of search uses. Diacritic-insensitive
    /// so a query typed without accents finds accented text — the
    /// behaviour of Spotlight and of every macOS find bar.
    static let options: String.CompareOptions = [.caseInsensitive,
                                                 .diacriticInsensitive]

    /// Every non-overlapping occurrence of `query` in `text`, in order.
    /// Empty query = no matches (never "everything").
    static func occurrences(of query: String,
                            in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let r = text.range(of: query, options: options,
                                 range: cursor..<text.endIndex) {
            found.append(r)
            // A zero-width result would spin forever. Foundation does
            // not produce one for a non-empty needle, but the guard
            // costs nothing and the loop is unbounded without it.
            cursor = r.upperBound > r.lowerBound
                ? r.upperBound
                : text.index(after: r.lowerBound)
        }
        return found
    }

    /// How many times `query` occurs in `text`. Same walk as
    /// `occurrences`, without building the ranges.
    static func count(of query: String, in text: String) -> Int {
        guard !query.isEmpty, !text.isEmpty else { return 0 }
        var n = 0
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let r = text.range(of: query, options: options,
                                 range: cursor..<text.endIndex) {
            n += 1
            cursor = r.upperBound > r.lowerBound
                ? r.upperBound
                : text.index(after: r.lowerBound)
        }
        return n
    }

    /// A short window of `text` around its first match, for a result
    /// row's one-line preview. Returns nil when there is no match.
    ///
    /// The returned range is in the returned SNIPPET's coordinates, not
    /// the source's — the caller renders the snippet and nothing else.
    static func snippet(of query: String, in text: String,
                        before: Int = 32,
                        after: Int = 120) -> (text: String,
                                              match: Range<String.Index>)? {
        guard let first = text.range(of: query, options: options) else {
            return nil
        }
        // Collapse whitespace so a snippet lifted out of an indented
        // code block or a wrapped paragraph reads as one line.
        let lead = text[..<first.lowerBound].suffix(before)
        let tail = text[first.upperBound...].prefix(after)
        let head = collapsed(String(lead))
        let body = String(text[first])
        let rest = collapsed(String(tail))
        let ellipsisLead = first.lowerBound > text.startIndex && lead.count == before
        let ellipsisTail = tail.endIndex < text.endIndex

        // Assembled WHOLE before any index is taken. A `String.Index`
        // is invalidated by mutating its string, so measuring the match
        // position by appending and reading `endIndex` as it goes
        // returns indices into a string that no longer exists.
        let prefix = (ellipsisLead ? "…" : "") + head
        let out = prefix + body + rest + (ellipsisTail ? "…" : "")
        // `limitedBy`, not a bare offset. Concatenation can MERGE
        // grapheme clusters across a seam — a piece ending in a base
        // letter and the next beginning with a combining mark become
        // one Character — so `out.count` is not always the sum of the
        // pieces' counts, and a bare `index(_:offsetBy:)` past the end
        // traps. A snippet is decoration; it must never be able to
        // bring down a search.
        guard let matchStart = out.index(out.startIndex, offsetBy: prefix.count,
                                         limitedBy: out.endIndex),
              let matchEnd = out.index(matchStart, offsetBy: body.count,
                                       limitedBy: out.endIndex)
        else {
            return (out, out.startIndex..<out.startIndex)
        }
        return (out, matchStart..<matchEnd)
    }

    private static func collapsed(_ s: String) -> String {
        s.split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
    }
}

// MARK: - Highlight spec

/// What a transcript is currently searching for, and which match of the
/// whole transcript is the CURRENT one.
///
/// `activeOrdinal` counts matches across the entire conversation in
/// document order, so a row can tell "one of my matches is the active
/// one" from its own slice alone (see `SearchHighlightSlot`) without
/// knowing anything about its neighbours.
struct SearchHighlight: Equatable {
    var query: String = ""
    /// Index into the transcript's full match list; -1 while none is
    /// selected (an empty query, or a query with no matches).
    var activeOrdinal: Int = -1

    static let inactive = SearchHighlight()

    var isActive: Bool { !query.isEmpty }
}

/// One row's (or one block's) view of the search: the query plus how
/// many matches precede it in the transcript. The k-th match found here
/// is the transcript's `base + k`.
///
/// Passed DOWN as a value rather than read from the environment at each
/// leaf, because `base` differs per row and per block within a row —
/// an environment write per block would be a write per markdown
/// paragraph on every render pass.
struct SearchHighlightSlot: Equatable {
    var highlight: SearchHighlight = .inactive
    var base: Int = 0

    static let inactive = SearchHighlightSlot()

    var isActive: Bool { highlight.isActive }
    var query: String { highlight.query }

    /// The same search, `n` matches further along.
    func advanced(by n: Int) -> SearchHighlightSlot {
        SearchHighlightSlot(highlight: highlight, base: base + n)
    }
}

// MARK: - Environment

private struct SipSearchSlotKey: EnvironmentKey {
    static let defaultValue: SearchHighlightSlot = .inactive
}

extension EnvironmentValues {
    /// The active find, as seen by whatever row this is. Set per ROW by
    /// the transcript (the row's `base` is its offset into the match
    /// list); leaves read it and thread their own block offsets on top.
    ///
    /// Defaults to `.inactive`, so nothing outside a find bar's reach
    /// pays anything and no view has to be told search exists.
    var sipSearchSlot: SearchHighlightSlot {
        get { self[SipSearchSlotKey.self] }
        set { self[SipSearchSlotKey.self] = newValue }
    }
}

// MARK: - Applying a highlight

extension AttributedString {
    /// Tint this string's occurrences of the slot's query and report how
    /// many there were, so the caller can advance the slot for whatever
    /// it renders next.
    ///
    /// Only `backgroundColor` is written. Touching the foreground would
    /// flatten the inline-code and link colours the renderer just set —
    /// and a match inside a link must stay recognisably a link.
    ///
    /// Ranges are collected FIRST and applied in REVERSE. `AttributedString`
    /// documents its indices as invalidated by mutation, and while an
    /// attribute-only write does not move characters, walking and
    /// mutating in one pass takes that on trust. Collect-then-reverse
    /// needs no such assumption: nothing is read after the first write,
    /// and each write lies before every range still to come.
    @discardableResult
    mutating func applySearchHighlight(_ slot: SearchHighlightSlot) -> Int {
        guard slot.isActive else { return 0 }
        let query = slot.query
        var ranges: [Range<AttributedString.Index>] = []
        var cursor = startIndex
        while cursor < endIndex,
              let r = self[cursor...].range(of: query,
                                            options: SearchMatching.options) {
            ranges.append(r)
            cursor = r.upperBound > r.lowerBound
                ? r.upperBound
                : characters.index(after: r.lowerBound)
        }
        for (k, r) in ranges.enumerated().reversed() {
            self[r].backgroundColor = slot.base + k == slot.highlight.activeOrdinal
                ? SipDesign.searchMatchActive
                : SipDesign.searchMatch
        }
        return ranges.count
    }

    /// Convenience for the plain-text surfaces (code blocks, tool body
    /// rows, result lines) that have no attributed form of their own.
    static func highlighting(_ text: String,
                             slot: SearchHighlightSlot) -> (AttributedString, Int) {
        var attr = AttributedString(text)
        let n = attr.applySearchHighlight(slot)
        return (attr, n)
    }
}
