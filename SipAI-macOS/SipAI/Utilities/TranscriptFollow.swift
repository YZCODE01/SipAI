// TranscriptFollow.swift
// The "when the content grows under a reader who was already at the end,
// stay at the end" engine, shared by the agent transcript
// (`RunnerStreamView`) and the chat message list (`ChatView`).
//
// The rule lives ONCE, here, and both views drive it. Nothing here
// touches SwiftUI state: the caller asks what to do with a sample and
// performs the scroll itself — which is also what lets the rule be
// exercised headlessly, with no view attached.
//
// WHY THERE IS A BUDGET
//
// Both call sites issue their snap from INSIDE a geometry observer, so
// every snap comes back as another sample. The two other guards —
// "only when the content grew" and "only when the scroll can actually
// move" — are both satisfied indefinitely when the tail of the stack
// is lazy: `ScrollViewHelper.prefetch` realizes rows as the snap moves
// the viewport, `LazyStack.measureEstimates` re-estimates the total
// height, and the new height reads as fresh growth — layout feeding
// itself. Each snap writes `ScrollPosition`, which is `@State`, which
// re-runs the whole transcript body; once one pass overruns the frame
// budget the app never catches up and has to be force-quit. That is
// the freeze.
//
// So the engine may issue at most `snapBudget` snaps off its own output.
// The budget is restored by REAL input — a hand on the wheel, a new
// event, a history swap, a send — which is exactly the set of things
// that legitimately mean "move again". A clamped transcript sits a few
// points short of the end until the next of those, which is a failure
// mode nobody can see; the alternative is a hung app.
//
// Do not "simplify" the budget away by tightening the growth threshold
// instead. Growth is real — the rows genuinely are getting taller. What
// is not real is that it was the READER's content that grew.

import Foundation
import SwiftUI

/// The two numbers the follow rule depends on, sampled together from one
/// `ScrollGeometry` so they can never disagree.
///
/// Sampling them together is the point. Whether the end of the content
/// moved away because the CONTENT grew or because the READER scrolled is
/// the whole question, and it can only be answered by comparing a height
/// and a distance from the SAME instant.
struct TranscriptGeometry: Equatable {
    /// Total height of the scrolled content.
    var contentHeight: CGFloat
    /// Points between the bottom of the visible area and the end of the
    /// content. 0 = flush with the newest row. SIGNED: a NEGATIVE value
    /// means the viewport sits PAST the end of the content, showing
    /// nothing. Clamping this at zero would make that state
    /// indistinguishable from "at the end" — which is precisely how a
    /// transcript can sit blank with nothing noticing.
    var distanceFromEnd: CGFloat

    init(contentHeight: CGFloat, distanceFromEnd: CGFloat) {
        self.contentHeight = contentHeight
        self.distanceFromEnd = distanceFromEnd
    }

    init(_ geo: ScrollGeometry) {
        self.contentHeight = geo.contentSize.height
        self.distanceFromEnd = geo.contentSize.height - geo.visibleRect.maxY
    }
}

/// What the caller should do about one sample.
enum TranscriptFollowAction: Equatable {
    case none
    case snapToEnd
}

/// Follow-mode state for one scroll view.
///
/// Deliberately a CLASS held in plain `@State`, not a set of `@State`
/// values: none of this is rendered — the views read it only from event
/// handlers — so mutating it must not invalidate the transcript body.
/// These fields flip on nearly every scroll sample; as rendered state
/// they would re-render the whole column each time.
///
/// One instance per scroll view identity. The agent transcript re-mints
/// its view identity per session (`.id(runner.key)`), so each session
/// gets a fresh engine — which is what makes the one-shot clamp log
/// below at most one line per session opened.
@MainActor
final class TranscriptFollow {

    // MARK: - Thresholds

    /// How close to the end still counts as "following" — slack for a
    /// snap that lands a few points short while rows settle.
    private static let followThreshold: CGFloat = 120

    /// How close the reader has to come BACK before following resumes
    /// after they left it. The two thresholds are deliberately
    /// different: leaving and returning are different questions, and
    /// answering both with 120 pt makes a small deliberate scroll-up
    /// undo itself on the next burst.
    private static let resumeThreshold: CGFloat = 24

    /// Movement below this is measurement noise, not a reader pushing
    /// back against the stream.
    private static let readerIntentSlop: CGFloat = 4

    /// Snaps allowed off the engine's OWN output before it stops and
    /// waits for real input. See the file header. Three rather than one
    /// because a legitimate content swap can genuinely need a couple of
    /// passes to settle as rows realize at their true heights.
    static let snapBudget = 3

    /// Two samples closer than this in BOTH axes are the same place at
    /// the same size — a snap issued for one cannot achieve anything
    /// the other did not. The cheap fast path in front of the budget.
    private static let latchSlop: CGFloat = 8

    // MARK: - State

    /// True while the viewport shows (or nearly shows) the end of the
    /// content — the guard for follow-the-stream snapping.
    private(set) var isNearBottom = true

    /// True while the READER'S OWN gesture is driving the scroll —
    /// wheel, trackpad, drag, and the deceleration that follows the
    /// fingers leaving. `.animating` is deliberately NOT in here: that
    /// phase is one of OUR scrolls settling, i.e. the app moving, and
    /// counting it as intent would let the engine read its own snaps as
    /// the reader scrolling.
    private(set) var readerIsScrolling = false

    /// True while one of OUR OWN snaps is settling (`.animating`).
    /// Separate from `readerIsScrolling` on purpose: it must never
    /// influence the follow VERDICT (that would be the engine reading
    /// its own movement as intent), but it must suppress ISSUING
    /// another snap, which is the re-entrant edge.
    private(set) var appIsScrolling = false

    /// The sample the last snap was issued for.
    private var latched: TranscriptGeometry?

    /// Snaps issued since the last real input.
    private var snapsSinceInput = 0

    /// One clamp report per instance — the diagnosis if the freeze this
    /// file exists to prevent is ever seen, and silence otherwise.
    private var loggedClamp = false

    /// Names this engine in the clamp log ("transcript" / "chat").
    private let label: String

    init(label: String) {
        self.label = label
    }

    // MARK: - Input

    /// Real input happened — a hand on the wheel, a new event, a
    /// history swap, a send. Restores the snap budget and clears the
    /// latch: the transcript legitimately needs to move again.
    func noteInput() {
        latched = nil
        snapsSinceInput = 0
    }

    /// "Go to the end, and mean it." For the unconditional callers: a
    /// send, a session switch, a finished history load. Follow mode is
    /// re-entered whatever the reader had done before.
    func forceFollow() {
        isNearBottom = true
        noteInput()
    }

    // MARK: - Sampling

    /// Fold one geometry sample into the follow verdict and answer
    /// whether to snap.
    func geometryChanged(from old: TranscriptGeometry,
                         to new: TranscriptGeometry) -> TranscriptFollowAction {
        // Content grew: rows realising at their true heights after the
        // first layout pass, a turn streaming in, a history swap.
        let growth = max(0, new.contentHeight - old.contentHeight)
        let grew = growth > 0.5

        // Split this sample's change into its two causes. The end of
        // the content can move away from the viewport because the
        // CONTENT grew or because the READER scrolled, and only the
        // second is intent — but BOTH can happen in one sample, and
        // while a turn streams almost every sample carries growth.
        //
        // Growth can only account for the distance the end ACTUALLY
        // moved away; whatever is left over is the reader's own hand.
        // Capping the subtraction that way also keeps growth that lands
        // ABOVE the viewport ("Show earlier") from being subtracted out
        // of a distance it never added to — which would manufacture a
        // bogus "at the end" verdict for a reader who just asked to see
        // OLDER rows.
        let movedAway = max(0, new.distanceFromEnd - old.distanceFromEnd)
        let readerDistance = new.distanceFromEnd - min(growth, movedAway)
        let pushingBack = readerIsScrolling
            && readerDistance > old.distanceFromEnd + Self.readerIntentSlop

        // Leaving and rejoining the stream are asymmetric, and that
        // asymmetry IS the fix for the page feeling springy. A
        // deliberate push-back leaves follow mode at once, whatever the
        // distance; getting it back means coming back to the end.
        if pushingBack {
            isNearBottom = false
        } else if isNearBottom {
            isNearBottom = readerDistance <= Self.followThreshold
        } else {
            isNearBottom = readerDistance <= Self.resumeThreshold
        }

        // Stranded past the end — the viewport is showing space that no
        // longer has content behind it, i.e. a blank page. Deliberately
        // OUTSIDE the budget: it is not a follow decision but a repair
        // of a broken state, and it cannot run away, because it demands
        // a fresh SHRINK every time and the content can only shrink so
        // far. Gating on the shrink is also what keeps an overscroll
        // bounce (which moves the viewport, not the content) from
        // triggering it and fighting the rubber band.
        if new.contentHeight < old.contentHeight - 0.5, new.distanceFromEnd < -1 {
            return .snapToEnd
        }

        // Follow, but never against a hand already on the wheel, never
        // on top of our own settling animation, and never with a scroll
        // that cannot move anything.
        guard grew, isNearBottom,
              !readerIsScrolling, !appIsScrolling,
              new.distanceFromEnd > 0.5
        else { return .none }
        return claimSnap(at: new) ? .snapToEnd : .none
    }

    /// Fold one scroll-phase change in, and answer whether the caller
    /// should take up the slack now that a gesture has ended.
    ///
    /// WHO is scrolling comes from here, never from the geometry. A
    /// sample can say the end moved; it can never say whose hand did it.
    func phaseChanged(to phase: ScrollPhase,
                      geometry: TranscriptGeometry) -> Bool {
        let reader = phase == .tracking
            || phase == .interacting
            || phase == .decelerating
        if reader != readerIsScrolling { readerIsScrolling = reader }
        appIsScrolling = (phase == .animating)
        // A hand on the wheel is the least ambiguous input there is.
        if reader { noteInput() }

        // Gesture over. The geometry path deliberately let the stream
        // run ahead while the reader was moving, so if they finished
        // still at the end, take up that slack now — once, on a real
        // user event, not on a timer. Through the budget like every
        // other snap: this is the other half of the loop, where the
        // snap's own `.animating` settles back to `.idle` still short
        // of the end and asks for another.
        guard phase == .idle, isNearBottom,
              geometry.distanceFromEnd > 0.5
        else { return false }
        return claimSnap(at: geometry)
    }

    // MARK: - Budget

    private func claimSnap(at geo: TranscriptGeometry) -> Bool {
        if let latched,
           abs(geo.contentHeight - latched.contentHeight) < Self.latchSlop,
           abs(geo.distanceFromEnd - latched.distanceFromEnd) < Self.latchSlop {
            return false
        }
        guard snapsSinceInput < Self.snapBudget else {
            if !loggedClamp {
                loggedClamp = true
                NSLog("SipAI[%@]: follow engine clamped after %d self-driven snaps (h=%.0f d=%.1f). Re-follows on the next event or gesture.",
                      label, Self.snapBudget,
                      geo.contentHeight, geo.distanceFromEnd)
            }
            return false
        }
        latched = geo
        snapsSinceInput += 1
        return true
    }
}
