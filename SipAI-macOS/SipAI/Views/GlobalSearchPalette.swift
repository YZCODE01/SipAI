// GlobalSearchPalette.swift
// The toolbar magnifying glass's dropdown: one field over every chat,
// note and agent session, grouped by kind, with a snippet per row.
//
// Presented as an OVERLAY anchored under its button rather than as a
// sheet or a new window, so the conversation the reader was in stays on
// screen behind it — the whole point of searching is usually to get
// back to something adjacent to what you are already looking at.
//
// Keyboard is the primary interface: ↑/↓ move the selection, Return
// opens it, Escape closes. A single-line `TextField` does not consume
// the arrows, so `onKeyPress` on the container sees them while the
// caret stays in the field and typing continues to refine.
//
// Opening a row hands its query forward through
// `AppState.pendingFindQuery`, so the destination lands with its own
// find bar open on the same text — the palette's snippet and the
// transcript's first highlight are then the same match.

import SwiftUI

struct GlobalSearchPalette: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var chats: ChatManager
    @EnvironmentObject var agents: AgentManager
    @EnvironmentObject var notesManager: NotesManager

    @Binding var isPresented: Bool

    @StateObject private var engine = GlobalSearchEngine()
    @State private var query: String = ""
    @State private var selection: Int = 0
    /// Bumped ONLY by the keyboard. The results list scrolls on this,
    /// never on `selection` itself.
    ///
    /// Pointing at a row also selects it (so the row about to be
    /// clicked is the highlighted one), and scrolling drags rows under
    /// a stationary cursor — so a scroll-on-selection would re-centre
    /// every row the pointer passes over and fight the wheel. A change
    /// can say WHAT moved, never WHOSE hand moved it. Ask the input,
    /// not the state.
    @State private var keyboardNonce: Int = 0
    @State private var seeds: [SearchDocumentSeed] = []
    /// Debounce token. Typing must not launch a corpus sweep per
    /// keystroke — each one cancels the last, and only a pause runs.
    @State private var debounce: Task<Void, Never>?

    private static let debounceNanos: UInt64 = 220_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            if !engine.settledQuery.isEmpty || engine.isSearching {
                Divider().opacity(0.4)
                resultsArea
            }
        }
        .frame(width: 540)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(SipDesign.surface)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(SipDesign.borderLight, lineWidth: 1)
        )
        .onAppear {
            seeds = buildSeeds()
        }
        .onDisappear {
            debounce?.cancel()
            engine.cancel()
        }
        .onChange(of: query) { _, new in
            selection = 0
            debounce?.cancel()
            let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                engine.reset()
                return
            }
            debounce = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.debounceNanos)
                guard !Task.isCancelled else { return }
                engine.search(trimmed, seeds: seeds)
            }
        }
    }

    // MARK: - Field

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SipDesign.textSecondary)
            // AppKit-backed: a SwiftUI `TextField` consumes ↑/↓ in its
            // field editor, so no ancestor handler ever sees them and
            // the list could not be driven from the keyboard at all.
            // See `SearchField`.
            SearchField(
                text: $query,
                placeholder: String(
                    localized: "Search chats, notes and sessions",
                    comment: "Placeholder in the global search field"),
                fontSize: 15,
                onMoveUp: { move(-1) },
                onMoveDown: { move(1) },
                onSubmit: { _ in openSelected() },
                onCancel: { isPresented = false }
            )
            .frame(maxWidth: .infinity, minHeight: 20)
            if engine.isSearching {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(SipDesign.textHint)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear", comment: "Global search tooltip"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsArea: some View {
        if flatResults.isEmpty {
            emptyRow
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        ForEach(orderedSections, id: \.self) { section in
                            sectionHeader(section)
                            ForEach(indices(in: section), id: \.self) { index in
                                row(flatResults[index], index: index)
                                    .id(index)
                            }
                        }
                        footer
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 420)
                // Keyboard moves only — see `keyboardNonce`.
                .onChange(of: keyboardNonce) { _, _ in
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
        }
    }

    private var emptyRow: some View {
        HStack {
            Text(engine.isSearching
                 ? String(localized: "Searching \(engine.scanned) of \(engine.total)…",
                          comment: "Global search progress; placeholders are counts")
                 : String(localized: "No matches for “\(engine.settledQuery)”",
                          comment: "Global search empty state; placeholder is the query"))
                .font(.system(size: 12))
                .foregroundColor(SipDesign.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var footer: some View {
        if engine.isSearching {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text(String(localized: "Searching \(engine.scanned) of \(engine.total)…",
                            comment: "Global search progress; placeholders are counts"))
                    .font(.system(size: 11))
                    .foregroundColor(SipDesign.textHint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        } else if engine.hitResultCap {
            // A truncated list that does not SAY it is truncated reads
            // as "that is everything".
            Text(String(localized: "Showing the first \(flatResults.count) — narrow the search for more.",
                        comment: "Global search notice when the result list is capped"))
                .font(.system(size: 11))
                .foregroundColor(SipDesign.textHint)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
    }

    private func sectionHeader(_ section: SearchSection) -> some View {
        Text(sectionTitle(section))
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(SipDesign.textHint)
            .textCase(.uppercase)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ result: GlobalSearchResult, index: Int) -> some View {
        GlobalSearchRow(
            result: result,
            selected: index == selection,
            onOpen: { open(result) },
            onHover: { if $0 { selection = index } }
        )
    }

    // MARK: - Grouping

    /// Results in DISPLAY order — sections in fixed rank, rows within a
    /// section newest first. The flat array is what ↑/↓ walks, so it
    /// must be the order the eye sees.
    private var flatResults: [GlobalSearchResult] {
        var out: [GlobalSearchResult] = []
        for section in orderedSections {
            out.append(contentsOf: engine.results.filter { $0.section == section })
        }
        return out
    }

    private var orderedSections: [SearchSection] {
        var seen: [SearchSection] = []
        for r in engine.results where !seen.contains(r.section) {
            seen.append(r.section)
        }
        return seen.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return sectionTitle(a).localizedCaseInsensitiveCompare(sectionTitle(b))
                == .orderedAscending
        }
    }

    private func indices(in section: SearchSection) -> [Int] {
        flatResults.indices.filter { flatResults[$0].section == section }
    }

    /// Never names an agent outright — the label is the user's, from
    /// Settings → Labels, exactly as the sidebar sections are.
    private func sectionTitle(_ section: SearchSection) -> String {
        switch section {
        case .chats:
            return String(localized: "Chats",
                          comment: "Global search section header")
        case .notes:
            return String(localized: "Notes",
                          comment: "Global search section header")
        case .sessions(let key):
            let fallback = AgentManager.registry
                .first { $0.key == key }?.name ?? "Claude Code"
            return config.agentLabel(for: key, defaultName: fallback)
        }
    }

    // MARK: - Keyboard

    private func move(_ delta: Int) {
        guard !flatResults.isEmpty else { return }
        selection = (selection + delta + flatResults.count) % flatResults.count
        // The nonce, not the selection, is what the list scrolls on.
        keyboardNonce &+= 1
    }

    private func openSelected() {
        guard flatResults.indices.contains(selection) else { return }
        open(flatResults[selection])
    }

    // MARK: - Routing

    private func open(_ result: GlobalSearchResult) {
        // The query goes first so it is already in place when the
        // routing field's didSet swaps the centre pane.
        //
        // NOT for a note: `NoteView` has no find bar, so nothing there
        // would consume the query — and an unconsumed one is picked up
        // by the next chat or session opened, which would land a find
        // bar on a conversation nobody searched.
        if case .note = result.target {
            appState.pendingFindQuery = nil
        } else {
            appState.pendingFindQuery = engine.settledQuery
        }
        switch result.target {
        case .chat(let slug, let project):
            appState.openChatSlug = slug
            appState.openChatProject = project
        case .note(let slug):
            appState.openNoteId = slug
        case .session(let id, let url, _):
            appState.openAgentSessionId = id
            appState.openAgentSessionPath = url
            // Assigned after the session, whose didSet leaves this
            // field alone: a result opened from search is not a run of
            // whatever task the last click was looking at.
            appState.openScheduledTaskName = nil
        }
        isPresented = false
    }

    // MARK: - Seeds

    /// Snapshot the corpus on the MainActor. Chats and notes carry
    /// their text inline — both stores are already fully resident —
    /// while a session carries only its file, because reading hundreds
    /// of MB of JSONL is exactly what must not happen here.
    ///
    /// Sorted newest-first, which is the order the engine sweeps in and
    /// therefore the order results arrive.
    private func buildSeeds() -> [SearchDocumentSeed] {
        var out: [SearchDocumentSeed] = []

        let allChats = chats.rootChats + chats.projectChats.values.flatMap { $0 }
        for chat in allChats {
            out.append(SearchDocumentSeed(
                target: .chat(slug: chat.slug, project: chat.project),
                title: chat.title.isEmpty
                    ? String(localized: "New Chat", comment: "Default chat title")
                    : chat.title,
                subtitle: chat.project ?? String(localized: "Chats",
                                                 comment: "Global search subtitle for a root chat"),
                activityAt: chat.activityAt,
                section: .chats,
                body: chat.messages.map(\.content).joined(separator: "\n"),
                fileURL: nil))
        }

        for note in notesManager.notes {
            out.append(SearchDocumentSeed(
                target: .note(slug: note.slug),
                title: note.title,
                subtitle: note.source ?? String(localized: "Notes",
                                                comment: "Global search subtitle for a note"),
                activityAt: note.modifiedAt,
                section: .notes,
                body: note.bodyContent,
                fileURL: nil))
        }

        for session in agents.sessions where !session.isEmptyShell {
            out.append(SearchDocumentSeed(
                target: .session(id: session.id, fileURL: session.fileURL,
                                 agentKey: session.agentKey),
                title: session.title,
                subtitle: folderLabel(session),
                activityAt: session.activityAt,
                section: .sessions(agentKey: session.agentKey),
                body: nil,
                fileURL: session.fileURL))
        }

        return out.sorted { $0.activityAt > $1.activityAt }
    }

    private func folderLabel(_ session: AgentSession) -> String {
        guard let path = session.projectPath?.path else {
            return session.scheduledTaskName ?? ""
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Row

/// One result. Its own view so the hover highlight has state to live in
/// and so a re-render of the list does not re-evaluate every row's
/// snippet attribution.
private struct GlobalSearchRow: View {
    let result: GlobalSearchResult
    let selected: Bool
    let onOpen: () -> Void
    let onHover: (Bool) -> Void

    @State private var hovered = false

    /// The snippet with its match tinted the same yellow the transcript
    /// uses, so the row and the page it opens read as one thing.
    private var snippet: AttributedString {
        var attr = AttributedString(result.snippet)
        if let lower = AttributedString.Index(result.snippetMatch.lowerBound,
                                              within: attr),
           let upper = AttributedString.Index(result.snippetMatch.upperBound,
                                              within: attr) {
            attr[lower..<upper].backgroundColor = SipDesign.searchMatch
        }
        return attr
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: result.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(SipDesign.textPrimary)
                        .lineLimit(1)
                    if !result.subtitle.isEmpty {
                        Text(verbatim: result.subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(SipDesign.textHint)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 6)
                    Text(result.matchCount == 1
                         ? String(localized: "1 match",
                                  comment: "Global search row: single match")
                         : String(localized: "\(result.matchCount) matches",
                                  comment: "Global search row: match count"))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(SipDesign.textHint)
                }
                Text(snippet)
                    .font(.system(size: 11))
                    .foregroundColor(SipDesign.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? SipDesign.cardSelectedBg
                                   : (hovered ? Color.gray.opacity(0.12) : Color.clear))
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside
            onHover(inside)
        }
    }
}
