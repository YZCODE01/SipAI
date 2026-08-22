// NotesSection.swift
// Sidebar section listing notes from NotesManager. Each row carries a
// vertical kebab menu (••• rotated) at the trailing edge that hovers
// independently of the row body and exposes Rename / Save as / Delete.
// Tapping the row body routes the center column to NoteView via
// AppState.openNoteId.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NotesSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var notes: NotesManager
    @Environment(\.sipFontScale) private var fontScale

    @Binding var expanded: Bool

    var body: some View {
        DisclosureSection(
            title: String(localized: "Notes",
                          comment: "Sidebar section header for AI-generated notes"),
            isExpanded: $expanded
        ) {
            if notes.notes.isEmpty {
                emptyRow
            } else {
                ForEach(notes.notes) { note in
                    NoteRow(note: note)
                }
            }
        }
    }

    private var emptyRow: some View {
        HStack {
            Text("No notes yet.",
                 comment: "Notes section: empty placeholder")
                .font(.system(size: SipFont.sidebarHint(fontScale)))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// Single note row: clickable body + trailing ⋮ menu. Uses the shared
/// `RowEllipsisMenu` so the dots sit at exactly the same x-position as
/// chat and session rows (18 pt frame + 4 pt trailing). The title swaps
/// for an in-place rename field via the menu's Rename item.
struct NoteRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var notes: NotesManager
    @Environment(\.sipFontScale) private var fontScale

    let note: StoredNote

    @State private var showingDeleteConfirm: Bool = false
    @State private var editingTitle = false
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool
    /// Message from the last failed export, or nil. A save panel that
    /// closes and produces no file reads as the app ignoring the click,
    /// so the reason is shown rather than dropped.
    @State private var exportFailure: String? = nil
    @State private var exporting: Bool = false

    var body: some View {
        Group {
            if editingTitle {
                renameRow
            } else {
                normalRow
            }
        }
        .confirmationDialog(
            String(localized: "Delete this note?",
                   comment: "Confirmation dialog title for note deletion"),
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete",
                          comment: "Confirmation button"),
                   role: .destructive) {
                if appState.openNoteId == note.id {
                    appState.openNoteId = nil
                }
                notes.deleteNote(slug: note.slug)
            }
            Button(String(localized: "Cancel",
                          comment: "Cancel button"),
                   role: .cancel) { }
        } message: {
            Text(note.title)
        }
        .alert(String(localized: "Couldn't save the note",
                      comment: "Alert title when a note export fails"),
               isPresented: Binding(get: { exportFailure != nil },
                                    set: { if !$0 { exportFailure = nil } })) {
            Button(String(localized: "OK", comment: "Alert dismiss button")) {
                exportFailure = nil
            }
        } message: {
            // verbatim: the message is an error string, not a template —
            // the interpolating overload would markdown-parse it.
            Text(verbatim: exportFailure ?? "")
        }
    }

    // MARK: Rows

    private var normalRow: some View {
        let selected = appState.openNoteId == note.id
        return HStack(spacing: 0) {
            // Body — clicking opens the note in the center column.
            Button {
                appState.openNoteId = note.id
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "note.text")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(note.title)
                        .font(.system(size: SipFont.sidebarRow(fontScale)))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 8)
                .padding(.trailing, 2)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RowEllipsisMenu { menuItems }
                .padding(.trailing, 4)
        }
        .sidebarRowBackground(selected: selected)
        .contextMenu { menuItems }
    }

    /// The title swapped for a text field in place — no dialog. Only
    /// Enter saves; Escape OR clicking anywhere else abandons the edit
    /// and the original name stays. Mirrors `SidebarChatRow.renameRow`.
    private var renameRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "note.text")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("", text: $renameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: SipFont.sidebarRow(fontScale)))
                .focused($renameFocused)
                .onSubmit { commitRename() }
                .onExitCommand { editingTitle = false }
                .onChange(of: renameFocused) { _, focused in
                    // Click-away = regret. The Enter path has already
                    // ended editing, so this is a no-op after a commit.
                    if focused {
                        FocusedFieldSelection.selectAll()
                    } else {
                        editingTitle = false
                    }
                }
                .onAppear { renameFocused = true }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.18))
        )
        // Clicks that don't move key focus (rows, buttons, empty
        // space) — see EditFieldClickAway.
        .editFieldClickAway { editingTitle = false }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button {
            renameDraft = note.title
            editingTitle = true
        } label: {
            Text("Rename", comment: "Note row menu item — edits in place")
        }
        Button {
            saveAsMarkdown()
        } label: {
            Label(String(localized: "Save as Markdown…",
                         comment: "Note kebab menu item"),
                  systemImage: "arrow.down.circle")
        }
        Button {
            saveAsPDF()
        } label: {
            Label(String(localized: "Save as PDF…",
                         comment: "Note kebab menu item"),
                  systemImage: "doc.richtext")
        }
        .disabled(exporting)
        Divider()
        Button(role: .destructive) {
            showingDeleteConfirm = true
        } label: {
            Label(String(localized: "Delete",
                         comment: "Note kebab menu item"),
                  systemImage: "trash")
        }
    }

    private func commitRename() {
        guard editingTitle else { return }
        editingTitle = false
        let name = renameDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != note.title else { return }
        notes.renameNote(slug: note.slug, newTitle: name)
    }

    /// Save panel shared by both formats. Returns nil when the user
    /// cancels.
    private func destination(extension ext: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(note.slug).\(ext)"
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.title = String(localized: "Save Note",
                             comment: "NSSavePanel title for saving a note to a file")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func saveAsMarkdown() {
        guard let dest = destination(extension: "md",
                                     type: UTType(filenameExtension: "md") ?? .plainText)
        else { return }
        if !notes.exportNote(slug: note.slug, to: dest) {
            exportFailure = String(localized: "The file could not be written.",
                                   comment: "Export failure: the destination refused the write")
        }
    }

    private func saveAsPDF() {
        guard let dest = destination(extension: "pdf", type: .pdf) else { return }
        exporting = true
        Task { @MainActor in
            defer { exporting = false }
            do {
                try await notes.exportPDF(slug: note.slug, to: dest)
            } catch {
                exportFailure = error.localizedDescription
            }
        }
    }
}
