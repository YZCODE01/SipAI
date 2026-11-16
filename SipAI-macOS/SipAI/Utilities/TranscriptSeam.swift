// TranscriptSeam.swift
// Where a read of a session's transcript meets the runner's live buffer.
//
// The agent transcript draws two lists, one above the other: a READ of
// the session's file (`AgentSessionView.historicalItems` — the history
// cache's copy first, then the file itself) and the runner's LIVE buffer
// (`AgentRunner.events`) — what the runner has streamed since a read last
// emptied it: the turn running now, and any turn that ended while the
// session stayed on screen. The two have to meet exactly. A turn in
// neither is missing from the page; a turn in both is drawn twice. And
// the page draws ONE run of rows across them (`window`): a row hidden
// between two drawn ones is a gap nobody asked for.
//
// The rules live here, and the view and the runner apply them. Nothing
// here touches view or runner state, which is what lets them run
// headless against the real readers (`Verification/TranscriptReopen`).

import Foundation

enum TranscriptSeam {

    /// Whether a reload reads the transcript. It does, every time but one:
    /// the draft→session flip of the conversation already on screen
    /// (`AgentSessionView.reload(migratedFromDraft:)`). There the live
    /// buffer holds the whole session — the file has nothing it lacks —
    /// and a read would replace rows only the buffer holds: the error row
    /// of a first turn that failed, an answer the agent never recorded.
    ///
    /// An empty page while a turn runs is NOT that case and must not be
    /// taken for it. The session view is built afresh after every detour
    /// (a chat, a note, Settings), and a draft or a task page leaves it
    /// empty as well; the buffer may then hold the running turn alone, and
    /// a skipped read draws the page from the new question down, every
    /// earlier turn missing until the session is opened again.
    static func readsTranscript(draftFlip: Bool, historyOnScreen: Bool,
                                turnRunning: Bool, liveRows: Int) -> Bool {
        !(draftFlip && !historyOnScreen && (turnRunning || liveRows > 0))
    }

    /// Where the running turn begins in the live buffer: the index of the
    /// message it opened with (`AgentRunner.send`). Nil without one, and
    /// once the buffer's front trim has cut that message away.
    static func runningTurnStart(in events: [StreamEvent], opening: UUID?) -> Int? {
        guard let opening else { return nil }
        return events.firstIndex { $0.id == opening }
    }

    /// A read, cut where the running turn begins, and whether it held that
    /// turn's opening record to cut at. The running turn is the live
    /// buffer's to draw — its records are not all on disk yet — so a read
    /// that holds its start would draw that part twice.
    ///
    /// `runningTurnText` is the turn's message as the buffer drew it, and
    /// nil unless the buffer still holds it: cut where the buffer no longer
    /// begins, a long turn would lose its middle, and drawing part of it
    /// twice is the lesser fault. The record is matched in the readers' own
    /// spellings — `cleanUserText` sweeps a bare `<…>`, `strippedTaskMarker`
    /// a scheduled run's marker and codex's skill mentions — newest first,
    /// since the running turn's is the newest message.
    static func cut(_ read: [AgentSessionHistoryItem], runningTurnText: String?)
    -> (items: [AgentSessionHistoryItem], heldRunningTurn: Bool) {
        guard let sent = runningTurnText else { return (read, false) }
        let spellings: Set<String> = [
            sent,
            AgentSessionScanner.cleanUserText(sent),
            CodexSessionScanner.strippedTaskMarker(sent),
        ]
        guard let at = read.lastIndex(where: { item in
            if case .userText(let t) = item.kind { return spellings.contains(t) }
            return false
        }) else { return (read, false) }
        return (Array(read[..<at]), true)
    }

    /// What the live buffer keeps once a read is on the page.
    enum LiveBuffer: Equatable {
        /// No turn is running, and the read holds every turn the buffer
        /// streamed (`AgentRunner.clearEvents`).
        case nothing
        /// The running turn alone (`AgentRunner.dropTurnsBeforeRunningTurn`).
        case runningTurn
        case everything
    }

    /// A read OF THE FILE that held the running turn's opening record was
    /// taken after every earlier turn had ended, so it holds them all, and
    /// a buffer keeping them too would draw them twice. The history cache's
    /// copy may predate turns the buffer holds — the read of the file that
    /// follows it settles the seam — and a read that did not reach the
    /// running turn says nothing about the turns before it.
    static func liveBuffer(turnRunning: Bool, readFromFile: Bool,
                           readHeldRunningTurn: Bool) -> LiveBuffer {
        guard turnRunning else { return .nothing }
        return readFromFile && readHeldRunningTurn ? .runningTurn : .everything
    }

    /// Whether a read of the file has to be taken again rather than land:
    /// it began under a turn of ours that has ended, or given way to
    /// another, by the time it lands (the turns told apart by when each
    /// began). Such a read can stop short of that turn's last records, and
    /// landed with no turn running it empties the live buffer that drew
    /// them — the turn's end gone from the page until it is opened again.
    static func readIsStale(turnStartAtRead: Date?, turnStartNow: Date?) -> Bool {
        turnStartAtRead != nil && turnStartNow != turnStartAtRead
    }

    // MARK: - The window drawn

    /// Live rows the window keeps while it slides with a streaming turn.
    /// Every row is laid out eagerly (`RunnerStreamView.transcriptStack`),
    /// so this bounds what each streamed row's re-render costs.
    static let liveRows = 150

    /// How far a HELD window may grow under a streaming turn before it
    /// slides again: the eager cost a reader away from the end may run up,
    /// the size of one "Show earlier".
    static let heldGrowth = 200

    /// The rows the transcript draws: one contiguous run from `top` to the
    /// newest row, over the read and the live buffer below it. Two windows
    /// capped separately and stacked — the read's newest rows, then the
    /// buffer's — hide the buffer's oldest rows BETWEEN them once a turn
    /// outgrows its cap, and every long turn does: a "Show earlier" in the
    /// middle of the page, earlier turns drawn above it, the running
    /// turn's own question hidden inside it.
    struct Window: Equatable {
        /// Index over read + buffer of the first row drawn; every row above
        /// it is behind "Show earlier".
        let top: Int
        let historyShown: Int
        let liveShown: Int
    }

    /// - earlierRows: rows drawn above the newest live rows — the read's
    ///   window at open (no live rows yet), 200 more per "Show earlier".
    /// - heldTop: the first drawn row, as an index over read + buffer,
    ///   while the reader is away from the end; nil while they follow it.
    ///
    /// - draws: whether a row (an index over read + buffer) is drawn on
    ///   its own; when given, every count above is in DRAWN rows. A folded
    ///   transcript (compact view) is mostly rows that draw nothing there —
    ///   a tool result in its call's chip, the steps of a line, which
    ///   counts once — and counted as rows, its window held the newest
    ///   answer or two above "Show earlier — N older rows".
    ///
    /// Following the end, the window SLIDES: each new row pushes the oldest
    /// drawn one out at the top, unseen at the bottom. Held, it does not —
    /// a row removed above the rows on screen moves them up by its height,
    /// so a sliding window drags what the reader is reading away under
    /// them — until it has grown by `heldGrowth`. A held window never draws
    /// fewer rows than a sliding one would.
    static func window(historyCount h: Int, liveCount b: Int,
                       earlierRows: Int, heldTop: Int?,
                       draws: ((Int) -> Bool)? = nil) -> Window {
        let n = h + b
        var top: Int
        if let draws {
            let liveDrawn = (h..<n).reduce(0) { $0 + (draws($1) ? 1 : 0) }
            let size = min(liveDrawn, liveRows) + max(0, earlierRows)
            let sliding = start(holding: size, before: n, draws)
            top = sliding
            if let held = heldTop {
                top = min(sliding, max(held, start(holding: size + heldGrowth, before: n, draws)))
            }
        } else {
            let size = min(b, liveRows) + max(0, earlierRows)
            let sliding = max(0, n - size)
            top = sliding
            if let held = heldTop {
                top = min(sliding, max(held, n - (size + heldGrowth)))
            }
        }
        top = min(max(0, top), n)
        return Window(top: top,
                      historyShown: max(0, h - top),
                      liveShown: b - max(0, top - h))
    }

    /// The first row of the shortest run ending before `n` that holds
    /// `count` drawn rows — always a drawn row, so a line, which is drawn
    /// at its first member, is never cut — or 0 when fewer are drawn.
    static func start(holding count: Int, before n: Int, _ draws: (Int) -> Bool) -> Int {
        guard count > 0 else { return n }
        var held = 0
        var i = n
        while i > 0 {
            i -= 1
            if draws(i) {
                held += 1
                if held == count { return i }
            }
        }
        return 0
    }

    /// How many rows in `range` are drawn.
    static func drawnCount(_ range: Range<Int>, _ draws: (Int) -> Bool) -> Int {
        range.reduce(0) { $0 + (draws($1) ? 1 : 0) }
    }

    enum HoldChange: Equatable { case none, hold, letGo }

    /// What one scroll sample does to the window's hold. A reader who has
    /// left the end holds it at its first drawn row (`heldRowOnPage`: a
    /// held row whose place the view can still name — `heldIndex`). They
    /// let it go once AT the end, not merely back in follow mode: at the
    /// end the scroll view clamps and nothing on screen moves as the
    /// window slides, where a snap still animating down, or a hand on the
    /// wheel inside the follow slack, would see the rows above it go.
    static func holdChange(following: Bool, distanceFromEnd: Double,
                           heldRowOnPage: Bool) -> HoldChange {
        if following { return heldRowOnPage && distanceFromEnd <= 1 ? .letGo : .none }
        return heldRowOnPage ? .none : .hold
    }

    /// Where the held row is: by its id while that names a row, else by
    /// its distance from the newest row as last seen. Every history row's
    /// id is minted per parse, so a read landing while the window is held
    /// — a wider read behind "Show earlier", a read taken again after its
    /// turn ended — leaves the id naming nothing. The distance survives
    /// it: what a read changes lies ABOVE the held row (rows a wider read
    /// adds, turns moved from the live buffer into the history), and what
    /// streams in lands below it. A window given no held row in that pass
    /// slides, and takes the rows above the reader with it.
    static func heldIndex(resolved: Int?, fromEnd: Int?, rowCount: Int) -> Int? {
        if let resolved { return resolved }
        guard let fromEnd else { return nil }
        return min(max(0, rowCount - fromEnd), rowCount)
    }

    /// `earlierRows` after "Show earlier": 200 more rows above the first
    /// row drawn (`top`), counted from that row rather than added to the
    /// last count — a held window has grown past its count, and 200 added
    /// to the count reveals that much less, or nothing. Never fewer than
    /// 200 more than before: a click made while an earlier click's wider
    /// read is still being taken keeps its 200 for the rows that read
    /// lands, which the window then draws at once.
    static func earlierRowsAfterShowEarlier(top: Int, earlierRows: Int,
                                            historyCount h: Int, liveCount b: Int) -> Int {
        max(earlierRows + 200, h + b - top + 200 - min(b, liveRows))
    }
}
