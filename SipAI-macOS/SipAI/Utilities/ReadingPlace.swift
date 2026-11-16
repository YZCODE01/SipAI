// ReadingPlace.swift
// Keeps the line being read under the top of the visible area when the
// text size changes while a transcript is on screen (View → Zoom In /
// Zoom Out / Actual Size), for the agent transcript and the chat message
// list.
//
// A size change re-lays out every row, and the scroll view keeps its
// OFFSET: the rows above the reader grow or shrink, and what sits under
// the top edge is some other part of the conversation. A reader at the
// end is the follow engine's case (`TranscriptFollow` keeps the end); a
// reader anywhere else is this file's. Which of the two a reader is, is
// judged on the layout BEFORE the change: a page that shrinks can clamp a
// reader mid-page to the end, and judged after, their line would be lost.

import Foundation
import SwiftUI

/// Where the top edge of the visible area sits, said as a row and a point
/// in it.
struct ReadingAnchor: Equatable {
    let id: UUID
    /// The edge's place in the row as a share of the row's height, 0 at
    /// its top. A share rather than points: the row re-wraps at another
    /// size, and the same share is the same line of it.
    let share: CGFloat
    /// Points from the edge down to the row's top when the edge falls in
    /// the gap above it, where `share` is 0.
    let lead: CGFloat

    /// The row under `top`, else the first row below it. Frames are in
    /// the scrolled content's coordinates, the scroll offset's own.
    static func at(top: CGFloat, frames: [UUID: CGRect]) -> ReadingAnchor? {
        var below: (id: UUID, minY: CGFloat)?
        for (id, frame) in frames {
            if frame.minY <= top, top < frame.maxY {
                let share = frame.height > 0 ? (top - frame.minY) / frame.height : 0
                return ReadingAnchor(id: id, share: share, lead: 0)
            }
            if frame.minY > top, below.map({ frame.minY < $0.minY }) ?? true {
                below = (id, frame.minY)
            }
        }
        return below.map { ReadingAnchor(id: $0.id, share: 0, lead: $0.minY - top) }
    }

    /// Where the top edge goes so the same point of the same row is under
    /// it, given the row's frame after the change.
    func top(in frame: CGRect) -> CGFloat {
        lead > 0 ? frame.minY - lead : frame.minY + share * frame.height
    }
}

/// One scroll sample for the follow engine and for `ReadingPlace`, read
/// together: two observers run in no promised order, so a follow verdict
/// read beside a separate edge sample can be a sample old — and a single
/// jump (a find match, a restored place) is a single sample.
struct ScrollSample: Equatable {
    var geometry: TranscriptGeometry
    var edge: ReadingPlace.Edge

    init(_ geo: ScrollGeometry) {
        geometry = TranscriptGeometry(geo)
        edge = ReadingPlace.Edge(top: geo.visibleRect.minY, offset: geo.contentOffset.y)
    }
}

/// The rows' frames and the visible area's top as the scroll view last
/// laid them out, and the anchor carried across a change of size.
///
/// A CLASS in plain `@State`, like `TranscriptFollow`: nothing here is
/// drawn, and it is written on every layout of every row — as rendered
/// state it would re-render the whole transcript each time.
///
/// A change is told by the SIZE each report was made at, never by the
/// order reports arrive in: the scroll view can report the new content
/// height before the rows report their new frames, and reading either as
/// the first word of the change would mix two layouts. So the
/// anchor is taken at the first report of a new size, before that report
/// is stored — from rows and an edge that are all still the old layout.
@MainActor
final class ReadingPlace {
    /// Named on the scrolled content, so a row's frame in it stays put
    /// while the reader scrolls and is in the scroll offset's coordinates.
    nonisolated static let space = "sipai.readingPlace"

    struct Size: Equatable {
        var fontScale: CGFloat
        var lineSpacing: CGFloat
    }

    /// The visible area's top in the content's coordinates and the scroll
    /// offset, sampled together from one `ScrollGeometry`.
    struct Edge: Equatable {
        var top: CGFloat
        var offset: CGFloat
    }

    private var size: Size?
    private var frames: [UUID: CGRect] = [:]
    /// The visible area's top, in the content's coordinates.
    private var top: CGFloat = 0
    /// How far the scroll offset sits above that top — 0 unless the
    /// scroll view is inset — so a top can be turned back into an offset.
    private var offsetShift: CGFloat = 0
    private var pending: (anchor: ReadingAnchor, size: Size)?
    /// The follow engine's verdict with the last edge: true while the
    /// reader follows the end, which the follow engine keeps by itself.
    private var following = true

    /// A row's frame, laid out at `size`. Answers the scroll offset to go
    /// to when this is the row being read across a change of size.
    func noteFrame(_ id: UUID, _ frame: CGRect, size: Size) -> CGFloat? {
        switchIfNeeded(to: size)
        frames[id] = frame
        guard let carried = pending, carried.anchor.id == id, carried.size == size else { return nil }
        pending = nil
        return carried.anchor.top(in: frame) - offsetShift
    }

    /// Where the visible area is, as the scroll view laid it out at `size`,
    /// and whether the reader follows the end there.
    func noteEdge(_ edge: Edge, following: Bool, size: Size) {
        switchIfNeeded(to: size)
        top = edge.top
        offsetShift = edge.top - edge.offset
        self.following = following
    }

    /// A row left the stack.
    func forget(_ id: UUID) { frames[id] = nil }

    /// The reader's own hand on the wheel: where to go is theirs now.
    func readerScrolled() { pending = nil }

    private func switchIfNeeded(to new: Size) {
        guard new != size else { return }
        defer { size = new }
        // The first report of all: nothing was laid out before it. And a
        // reader following the end is the follow engine's to keep there.
        guard size != nil, !following else {
            pending = nil
            return
        }
        pending = ReadingAnchor.at(top: top, frames: frames).map { ($0, new) }
    }
}

extension View {
    /// Reports this row's frame to `place` — in the content's coordinates,
    /// which do not move while the reader scrolls, so this runs when the
    /// stack is laid out and never per scrolled frame — and scrolls with
    /// `restore` when the row is the one being read across a change of
    /// size.
    ///
    /// The frame is read from a clear BACKGROUND, never from the row
    /// itself. A transcript holds rows that draw nothing (a tool result
    /// folded into its call's chip, a turn's start and end markers), and
    /// asking for a geometry on such a row makes it a laid-out child of
    /// zero size, which its stack then gives its spacing: one empty gap
    /// per such row between the messages. A background is laid out only
    /// where the row draws something, at the row's own frame.
    func readingPlaceRow(_ id: UUID, place: ReadingPlace, size: ReadingPlace.Size,
                         restore: @escaping (CGFloat) -> Void) -> some View {
        background {
            Color.clear
                .allowsHitTesting(false)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(ReadingPlace.space))
                } action: { frame in
                    if let offset = place.noteFrame(id, frame, size: size) { restore(offset) }
                }
                .onDisappear { place.forget(id) }
        }
    }
}
