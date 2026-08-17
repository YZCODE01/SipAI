// TranscriptFind.swift
// The per-conversation find bar — Cmd+F over the open chat or agent
// session — and the state behind it. Shared by `ChatView` and
// `AgentSessionView` so the counter, the keys and the highlight rules
// cannot drift between the two centre-pane transcripts.
//
// The contract with the renderer, in one line: a row's k-th match is
// `rowBases[row] + k`, counted in `MarkdownRenderer.plainText` order,
// and that is exactly the ordinal `SearchHighlightSlot` tints. Both
// sides go through `SearchMatching`, so "3 of 47" always names a match
// the reader can see.
//
// Three rules that are not obvious from the code:
//
// * The state object is owned by the HOST view, not by the bar — the
//   composer's search button toggles it, a global-search result seeds
//   it, and the transcript scrolls off it. A bar-owned query would die
//   with the bar.
// * `refresh` takes a CLOSURE, never an array. Building the searchable
//   rows means running every visible turn's markdown through
//   `plainText`; with a find bar closed (the overwhelmingly common
//   case) that closure is never called at all.
// * Navigation is a NONCE, not a position. Asking for "the same match
//   again" has to move the scroll view — after the reader scrolls away
//   and presses ↓, or after a jump landed on a row the window had to
//   grow to reach — and an `onChange(of: activeIndex)` cannot see a
//   request that does not change the index.

import SwiftUI
import AppKit

// MARK: - Search field

/// A single-line search field that hands ↑ / ↓ / Return / Escape to the
/// caller instead of letting AppKit swallow them.
///
/// SwiftUI's `TextField` cannot do this on macOS: its field editor
/// consumes the arrow keys for caret movement, so `.onKeyPress` on any
/// ancestor never sees them.
/// The commands arrive here as `moveUp:` / `moveDown:`, exactly the way
/// `MultilineTextField` already takes `insertNewline:` and
/// `cancelOperation:`.
///
/// Shared by the find bar and the global palette so both keyboards
/// behave identically; a second spelling of this is how one of them
/// would come to answer a key the other ignores.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 13
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    /// Return. `shift` is true for Shift+Return, which every find bar
    /// on this platform reads as "previous".
    var onSubmit: (_ shift: Bool) -> Void = { _ in }
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.font = NSFont.systemFont(ofSize: fontSize)
        field.placeholderString = placeholder
        field.stringValue = text
        // An NSTextField's intrinsic width is its TEXT's width, so
        // without these it hugs the query and the row's layout moves on
        // every keystroke. Low both ways = "take whatever the HStack
        // has left, and give it back when the window narrows".
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow,
                                                      for: .horizontal)
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        // Deferred: the view has no window during makeNSView, so there
        // is no responder chain to join yet. Same reason
        // `MultilineTextField.autoFocus` defers.
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // The closures capture the host's current state, so the
        // coordinator has to be re-pointed at the fresh struct or the
        // keys would drive a stale snapshot of it.
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown()
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                let shift = NSApp.currentEvent?.modifierFlags
                    .contains(.shift) ?? false
                parent.onSubmit(shift)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Model

/// One searchable row of a transcript. `text` is what the row DRAWS,
/// in draw order — see `MarkdownRenderer.plainText`.
struct FindableRow {
    let id: UUID
    let text: String
}

/// One match, in document order.
struct FindMatch: Equatable {
    let rowId: UUID
    /// Position of the row in the transcript's full row list — what
    /// tells the host how far back to grow its render window.
    let rowIndex: Int
    /// Which match this is WITHIN its row.
    let ordinalInRow: Int
}

@MainActor
final class TranscriptFindState: ObservableObject {
    @Published var isOpen: Bool = false
    @Published var query: String = ""
    @Published private(set) var matches: [FindMatch] = []
    @Published private(set) var activeIndex: Int = 0
    /// Bumped on every "go to the active match" request, including a
    /// repeat of the current one. The host scrolls on this, not on
    /// `activeIndex` — see the header.
    @Published private(set) var jumpNonce: Int = 0

    /// Matches preceding each row, by row id. The renderer's `base`.
    private(set) var rowBases: [UUID: Int] = [:]

    /// True once there is something to step through — the state the
    /// transcript uses to stop its own follow-to-end snaps from
    /// yanking the reader off a match mid-turn.
    var isAnchored: Bool { isOpen && !matches.isEmpty }

    var activeMatch: FindMatch? {
        guard matches.indices.contains(activeIndex) else { return nil }
        return matches[activeIndex]
    }

    // MARK: Lifecycle

    /// Open the bar, optionally seeded (a global-search result hands its
    /// own query down this way). Re-opening with no seed keeps the last
    /// query, which is what every find bar on this platform does.
    func open(seed: String? = nil) {
        if let seed, seed != query { query = seed }
        isOpen = true
    }

    func close() {
        isOpen = false
        matches = []
        rowBases = [:]
        activeIndex = 0
        // A settled-jump in flight would otherwise fire into a closed
        // bar and scroll the transcript for a query nobody is looking
        // at any more.
        jumpDebounce?.cancel()
        jumpDebounce = nil
    }

    // MARK: Navigation

    func next() {
        guard !matches.isEmpty else { return }
        activeIndex = (activeIndex + 1) % matches.count
        jumpNonce &+= 1
    }

    func previous() {
        guard !matches.isEmpty else { return }
        activeIndex = (activeIndex - 1 + matches.count) % matches.count
        jumpNonce &+= 1
    }

    /// Re-issue the current match without moving. Used after the host
    /// grows its render window so the target row exists to scroll to.
    func requestJump() {
        guard !matches.isEmpty else { return }
        jumpNonce &+= 1
    }

    /// Jump once the typing settles.
    ///
    /// Incremental find re-counts on every keystroke, and each recount
    /// puts the selection back on match 1 — which on a long transcript
    /// can be far enough back that reaching it grows the eager render
    /// window substantially. Doing that per keystroke would make typing
    /// a query cost one growth per character; this makes it cost one
    /// per query.
    func requestJumpSettled() {
        jumpDebounce?.cancel()
        guard !matches.isEmpty else { return }
        jumpDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.requestJump()
        }
    }

    private var jumpDebounce: Task<Void, Never>?

    // MARK: Recompute

    /// Rebuild the match list. `build` is only called when there is
    /// actually something to search for.
    ///
    /// The active match is preserved by IDENTITY (row + ordinal within
    /// the row), not by index: a turn streaming in above shifts every
    /// later index, and re-clamping on the number alone would walk the
    /// selection down the transcript on its own.
    func refresh(rows build: () -> [FindableRow]) {
        guard isOpen, !query.isEmpty else {
            if !matches.isEmpty || !rowBases.isEmpty {
                matches = []
                rowBases = [:]
                activeIndex = 0
            }
            return
        }
        let previous = activeMatch
        var found: [FindMatch] = []
        var bases: [UUID: Int] = [:]
        for (index, row) in build().enumerated() {
            bases[row.id] = found.count
            let n = SearchMatching.count(of: query, in: row.text)
            guard n > 0 else { continue }
            for k in 0..<n {
                found.append(FindMatch(rowId: row.id, rowIndex: index,
                                       ordinalInRow: k))
            }
        }
        rowBases = bases
        guard found != matches else { return }
        matches = found
        if let previous,
           let same = found.firstIndex(where: {
               $0.rowId == previous.rowId
                   && $0.ordinalInRow == previous.ordinalInRow
           }) {
            activeIndex = same
        } else {
            // The match set changed out from under the selection — a
            // new query, or a row that was trimmed away. Start at the
            // FIRST match, so the counter opens on "1 of 47" the way
            // every find bar on this platform does; a counter that
            // opens on its own total reads as though it had already
            // been walked to the end.
            //
            // The cost this has to avoid is the jump, not the count:
            // match 1 can be far enough back that reaching it grows the
            // transcript's eager render window a long way. That is why
            // the query-driven jump is DEBOUNCED
            // (`requestJumpSettled`) — one growth per settled query
            // rather than one per keystroke.
            activeIndex = 0
        }
    }

    // MARK: Rendering

    /// What the given row should tint. `.inactive` — the free path —
    /// whenever nothing is being searched.
    func slot(forRow id: UUID) -> SearchHighlightSlot {
        guard isOpen, !query.isEmpty, !matches.isEmpty else { return .inactive }
        return SearchHighlightSlot(
            highlight: SearchHighlight(query: query, activeOrdinal: activeIndex),
            base: rowBases[id] ?? 0
        )
    }

    /// "3 of 47", or the empty-result wording. Never a bare number: the
    /// position alone reads as a total.
    var counterText: String {
        if query.isEmpty { return "" }
        if matches.isEmpty {
            return String(localized: "No results",
                          comment: "Find bar counter when the query matches nothing")
        }
        return String(localized: "\(activeIndex + 1) of \(matches.count)",
                      comment: "Find bar counter: current match of total")
    }
}

// MARK: - Row text memo

/// Searchable text per transcript row, memoised by row identity.
///
/// Exists for one case: a find bar left OPEN while a turn streams. Every
/// appended event re-runs `refresh`, and rebuilding a row's text means
/// re-running `AgentRendering.fullToolResultBody` over tool output that
/// can be tens of kilobytes — on the MainActor, four times a second, for
/// every row on screen. Rows are immutable once created (history items
/// are parsed once; `AgentRunner` only ever appends to `events`), so the
/// work is pure waste. With the memo a streamed event costs one build.
///
/// A CLASS held in plain `@State`, like `TranscriptFollow`: nothing it
/// holds is rendered, so mutating it must not invalidate the transcript
/// body.
///
/// Bounded by `replace`, called at the end of every build with exactly
/// the rows that still exist — so a cap-trimmed event's entry goes with
/// it and the memo can never outgrow the transcript.
@MainActor
final class TranscriptRowTextCache {
    /// A tool chip's searchable text INCLUDES the result folded into
    /// it, and that result arrives after the call. `resolved`
    /// distinguishes the two states of one row; a result is claimed
    /// exactly once (`toolPairing.claim` refuses to overwrite), so it
    /// can never change again after that.
    struct Key: Hashable {
        let id: UUID
        let resolved: Bool
    }

    private var texts: [Key: String] = [:]

    func text(for key: Key, build: () -> String) -> String {
        if let hit = texts[key] { return hit }
        let value = build()
        texts[key] = value
        return value
    }

    /// Drop everything the caller did not just ask for.
    func replace(with fresh: [Key: String]) {
        texts = fresh
    }
}

// MARK: - Find bar

/// The bar itself: field · counter · previous · next · close. Lives at
/// the TOP of the pane, under the title, where every find bar on this
/// platform lives — and where it can never cover the composer or the
/// newest turn.
struct FindBar: View {
    @ObservedObject var find: TranscriptFindState

    /// Set when the transcript on screen is not the whole conversation,
    /// so the counter cannot be read as "in this session". Rendered as
    /// a quiet second line with its own action.
    var scopeNote: String? = nil
    var widenTitle: String? = nil
    var onWiden: (() -> Void)? = nil
    /// True while a widen is being read off disk.
    var widening: Bool = false

    @State private var closeHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(SipDesign.textSecondary)

                // AppKit-backed: a SwiftUI `TextField` eats ↑/↓ in its
                // field editor, so the step keys never reach any
                // handler on this view. See `SearchField`.
                SearchField(
                    text: $find.query,
                    placeholder: String(
                        localized: "Find in conversation",
                        comment: "Placeholder in the per-conversation find field"),
                    onMoveUp: { find.previous() },
                    onMoveDown: { find.next() },
                    onSubmit: { shift in shift ? find.previous() : find.next() },
                    onCancel: { find.close() }
                )
                .frame(minWidth: 120, maxWidth: 320, minHeight: 18)

                // Reads as a total, so it is never a bare number.
                Text(find.counterText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(find.matches.isEmpty && !find.query.isEmpty
                                     ? SipDesign.textHint
                                     : SipDesign.textSecondary)
                    .lineLimit(1)
                    // Fixed slot: the string changes length on every
                    // step ("9 of 47" → "10 of 47"), and without this
                    // the two arrows beside it shuffle sideways as the
                    // reader holds the key down.
                    .frame(minWidth: 62, alignment: .trailing)

                stepButton(symbol: "chevron.up",
                           hint: String(localized: "Previous match",
                                        comment: "Find bar tooltip"),
                           shortcut: KeyEquivalent("g"),
                           modifiers: [.command, .shift],
                           action: find.previous)
                stepButton(symbol: "chevron.down",
                           hint: String(localized: "Next match",
                                        comment: "Find bar tooltip"),
                           shortcut: KeyEquivalent("g"),
                           modifiers: [.command],
                           action: find.next)

                Button {
                    find.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(closeHovered
                                         ? SipDesign.textPrimary
                                         : SipDesign.textSecondary)
                        .frame(width: 20, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(closeHovered ? Color.gray.opacity(0.2) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { closeHovered = $0 }
                .help(String(localized: "Close find",
                             comment: "Find bar tooltip"))

                Spacer(minLength: 0)
            }

            if let scopeNote {
                HStack(spacing: 6) {
                    Text(scopeNote)
                        .font(.system(size: 11))
                        .foregroundColor(SipDesign.textHint)
                    if widening {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else if let onWiden, let widenTitle {
                        Button(action: onWiden) {
                            Text(widenTitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(SipDesign.blue)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(SipDesign.surfaceMuted)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(SipDesign.borderLight, lineWidth: 1)
                )
        )
    }

    private func stepButton(symbol: String,
                            hint: String,
                            shortcut: KeyEquivalent,
                            modifiers: EventModifiers,
                            action: @escaping () -> Void) -> some View {
        StepButton(symbol: symbol, hint: hint, disabled: find.matches.isEmpty,
                   action: action)
            .keyboardShortcut(shortcut, modifiers: modifiers)
    }
}

/// One of the two step arrows. Its own view so the hover fill has
/// somewhere to live (`@State` cannot go in a `func` in the parent).
private struct StepButton: View {
    let symbol: String
    let hint: String
    let disabled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(disabled ? SipDesign.textHint
                                          : (hovered ? SipDesign.textPrimary
                                                     : SipDesign.textSecondary))
                .frame(width: 20, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered && !disabled ? Color.gray.opacity(0.2) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovered = $0 }
        .help(hint)
    }
}

// MARK: - Composer toggle

/// The magnifying glass that opens the find bar, in the CHAT input
/// card's bottom row — same shape, padding and grey hover fill as the
/// note button it sits beside (`UnifiedInputCard`), because that is the
/// idiom of that row.
struct ChatFindToggle: View {
    @ObservedObject var find: TranscriptFindState
    let enabled: Bool
    @State private var hovered = false

    var body: some View {
        Button {
            if find.isOpen { find.close() } else { find.open() }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(enabled ? AnyShapeStyle(.secondary)
                                         : AnyShapeStyle(SipDesign.textHint))
                .frame(width: 22, height: 22)
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovered && enabled ? Color.gray.opacity(0.2) : Color.clear)
                )
                .onHover { hovered = $0 }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled
              ? String(localized: "Find in this conversation",
                       comment: "Tooltip for the chat find button")
              : String(localized: "Send a message first — there is nothing to search yet",
                       comment: "Tooltip for the chat find button when the chat is empty"))
    }
}
