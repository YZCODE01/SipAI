// NoteView.swift
// Center-column renderer for a selected note from NotesManager, with an
// Edit/Preview toggle over the note's markdown SOURCE. Mirrors
// AgentSessionView's overall layout (top spacer + title bar + divider +
// scrollable content). Title bar shows model + date pills when the
// note's metadata header carried them.
//
// Editing writes the BODY only; NotesManager puts the metadata header
// back. Saving is autosave — see `scheduleSave`.

import SwiftUI
import AppKit

struct NoteView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var notes: NotesManager
    @EnvironmentObject var config: ConfigManager
    /// Drives the preview's palette. The web view is a document of our
    /// own making, so it has to be told the appearance rather than
    /// inheriting one.
    @Environment(\.colorScheme) private var colorScheme

    /// Markdown source being edited. Meaningful only while
    /// `loadedNoteId` names the note on screen.
    @State private var draft: String = ""
    /// The note `draft` was loaded from — the identity its text belongs
    /// to, never `appState.openNoteId`. Same rule as
    /// `ChatView.loadedChatSlug`: by the time an `onChange` fires,
    /// appState already names the INCOMING note, so staging under it
    /// files one note's text on another.
    @State private var loadedNoteId: String? = nil
    @State private var editing: Bool = false
    /// Debounced writer, cancelled and re-armed on every keystroke so
    /// the file is touched once the typing stops rather than per
    /// character. It is a convenience, not the guarantee — the text is
    /// staged on `NotesManager` synchronously, so nothing depends on
    /// this task getting to run.
    @State private var saveTask: Task<Void, Never>? = nil

    /// How long the typing has to stop before the note is written.
    private static let saveDebounce: Duration = .milliseconds(800)

    private var note: StoredNote? {
        guard let id = appState.openNoteId else { return nil }
        return notes.notes.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 44)
            titleBar
            Divider().opacity(0.3)
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: appState.openNoteId) { _, _ in switchNote() }
        // The outgoing text is already staged on the manager under its
        // own slug, so this hands over nothing and cannot lose anything
        // by reading stale @State — the whole reason the buffer lives
        // there.
        .onDisappear { flush() }
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 12))
                .foregroundColor(ChatDesign.textSecondary)
            Text(note?.title ?? String(localized: "Note",
                                       comment: "Placeholder title when the note can't be resolved"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ChatDesign.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if saveFailed {
                saveFailureBadge
            }
            if let model = note?.model, !model.isEmpty {
                pill(text: model)
            }
            if let date = note?.date {
                pill(text: Self.dateFormatter.string(from: date))
            }
            if note != nil {
                editToggle
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var editToggle: some View {
        Button {
            if editing { endEditing() } else { beginEditing() }
        } label: {
            Image(systemName: editing ? "eye" : "square.and.pencil")
                .font(.system(size: 12))
                .foregroundColor(editing ? ChatDesign.blue : ChatDesign.textSecondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(editing
              ? String(localized: "Preview",
                       comment: "Note title bar: leave the editor and show the rendered note")
              : String(localized: "Edit",
                       comment: "Note title bar: edit the note's markdown source"))
    }

    /// Shown only while the last write to THIS note failed. Silence is
    /// the dangerous outcome here — the editor autosaves, so a user with
    /// no error on screen has every reason to believe their edits landed.
    private var saveFailureBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text("Couldn't save",
                 comment: "Note title bar: the note's file could not be written")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(.orange)
        .help(String(localized: "SipAI could not write this note's file. Your changes are still here — they will be saved again on the next edit.",
                     comment: "Tooltip explaining the note save failure badge"))
    }

    private func pill(text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(ChatDesign.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(ChatDesign.cardBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(ChatDesign.border, lineWidth: 1)
                    )
            )
    }

    private var saveFailed: Bool {
        guard let slug = note?.slug else { return false }
        return notes.lastSaveFailure == slug
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let note = note {
            if editing {
                NoteSourceEditor(text: $draft,
                                 onEscape: endEditing,
                                 spellChecking: config.display.spellCheck)
                    .onChange(of: draft) { _, text in
                        // The identity `draft` belongs to, NOT whatever
                        // the router now points at. `switchNote` clears
                        // both `loadedNoteId` and `draft`, and if SwiftUI
                        // were ever to run this before the editor leaves
                        // the tree, an unguarded stage would file an
                        // EMPTY body — i.e. erase a note — under the
                        // incoming slug. Same reason `ChatView` saves
                        // through `loadedChatSlug`.
                        guard loadedNoteId == note.slug else { return }
                        // Stage FIRST, synchronously: from here on the
                        // text survives this view being torn down.
                        notes.stageEdit(slug: note.slug, body: text)
                        scheduleSave(slug: note.slug)
                    }
            } else {
                // Rendered by `NoteHTML` in a web view rather than by
                // the SwiftUI `MarkdownRenderer`, so that LaTeX is laid
                // out for real instead of approximated with Unicode
                // symbols — and so the PDF export, which renders the
                // same document, cannot disagree with what is on screen.
                NoteWebView(markdown: note.bodyContent,
                            metadata: NoteHTML.Metadata(title: note.title,
                                                        model: note.model,
                                                        date: note.date),
                            dark: colorScheme == .dark)
            }
        } else {
            VStack {
                Spacer()
                Text("Note not found.",
                     comment: "Shown when the selected note has been deleted or moved")
                    .font(.system(size: 13))
                    .foregroundColor(ChatDesign.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Edit lifecycle

    private func beginEditing() {
        guard let note = note else { return }
        // `bodyContent` is authoritative: every path out of the editor
        // flushes, so nothing can be staged-but-unwritten at this point.
        // The fallback covers the one case that could be — a write that
        // failed, whose text is deliberately kept staged for a retry.
        draft = notes.pendingBody(slug: note.slug) ?? note.bodyContent
        loadedNoteId = note.slug
        editing = true
    }

    private func endEditing() {
        flush()
        editing = false
    }

    /// Re-arm the debounce. Cancelling first is what makes it a debounce
    /// rather than one write per keystroke.
    private func scheduleSave(slug: String) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            notes.flushPendingEdit(slug: slug)
        }
    }

    private func flush() {
        saveTask?.cancel()
        saveTask = nil
        notes.flushPendingEdits()
    }

    /// Note → note switch. NoteView SURVIVES this (the router keeps the
    /// same view type), so `onDisappear` never fires and this is the
    /// only place the outgoing note gets written.
    private func switchNote() {
        flush()
        editing = false
        // Order matters: dropping the identity BEFORE blanking the text
        // is what makes the guard in the editor's `onChange` able to
        // reject the blanking. Reversed, the guard would still be armed
        // on the outgoing note and would let it through.
        loadedNoteId = nil
        draft = ""
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Source editor

/// Full-pane NSTextView over a note's markdown source.
///
/// Deliberately NOT `MultilineTextField`: there Enter SENDS, which in a
/// note editor would be unusable. Enter inserts a newline here and
/// Escape returns to the preview — safe to bind, because the text is
/// already staged and Escape therefore discards nothing.
///
/// Monospaced on purpose: this is the source, and `**bold**`, list
/// dashes and fence backticks are what the user is aiming at.
private struct NoteSourceEditor: NSViewRepresentable {
    @Binding var text: String
    var onEscape: () -> Void
    /// `DisplaySettings.spellCheck`, passed by the owning view.
    var spellChecking: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.string = text
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textColor = NSColor.labelColor
        tv.insertionPointColor = NSColor.labelColor
        // Prose, not code: the usual editor autocorrections would fight
        // markdown punctuation (smart quotes inside a fence, a dash
        // turned into an em dash at the head of a list item).
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        TextInputSpellChecking.apply(spellChecking, to: tv)
        tv.textContainer?.lineFragmentPadding = 0
        // Matches the preview's 20/16 padding so the text does not shift
        // sideways when the toggle is flipped.
        tv.textContainerInset = NSSize(width: 20, height: 16)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        // The editor REPLACES something the user just clicked a button
        // to reach; it must not need a second click. Deferred because
        // there is no window, and so no responder chain, during
        // makeNSView.
        DispatchQueue.main.async { [weak tv] in
            guard let tv, let window = tv.window else { return }
            window.makeFirstResponder(tv)
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // The coordinator keeps the struct it was made with, so Escape
        // and every keystroke's write-back would drive a snapshot of the
        // host taken when this editor was built. Same rule, same reason,
        // as `SearchField`.
        context.coordinator.parent = self
        guard let tv = nsView.documentView as? NSTextView else { return }
        // Only an EXTERNAL change reaches here — typing sets the binding
        // from the coordinator, so the strings already agree. Assigning
        // `string` collapses the selection, so the insertion point is
        // put back where it was rather than at the top.
        TextInputSpellChecking.apply(spellChecking, to: tv)
        guard tv.string != text else { return }
        let caret = tv.selectedRange().location
        tv.string = text
        tv.setSelectedRange(NSRange(location: min(caret, (text as NSString).length),
                                    length: 0))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteSourceEditor
        init(_ parent: NoteSourceEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }
    }
}
