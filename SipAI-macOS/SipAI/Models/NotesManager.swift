// NotesManager.swift
// Lists, loads, creates, EDITS, deletes, and exports notes stored under
// ~/Library/Application Support/SipAI/notes/<slug>.md.
//
// Note files all have an optional metadata header on line 1:
//   <!-- Title: ... | Source: ... | Model: ... | Date: ... | Instructions: ... -->
// followed by a blank line, then the markdown body (which typically opens
// with an H1 matching the title).
//
// Notes written by hand, or by other tools, land in the same folder and
// show up here without duplication. Files that lack the header are still
// loaded — title falls back to a body-level H1, then to the file's slug.

import Foundation

/// What a write to a note file actually did. The editor autosaves, so
/// "nothing happened" has three very different meanings — the text was
/// identical, the note is gone, or the disk refused — and only the last
/// may be reported to the user or retried. Collapsing them into a Bool
/// is how a failed save becomes silent.
enum NoteWriteOutcome {
    case written
    case unchanged
    case missing
    case failed
}

/// Why an export could not be produced. Thrown rather than collapsed
/// into a Bool: "Save as PDF" opens a save panel and then appears to do
/// nothing, so the reason has to survive as far as the message shown.
enum NoteExportError: LocalizedError {
    case missing

    var errorDescription: String? {
        switch self {
        case .missing:
            return String(localized: "That note no longer exists.",
                          comment: "Export failure: the note was deleted or moved")
        }
    }
}

struct StoredNote: Identifiable, Hashable {
    var slug: String           // filename stem (without ".md")
    var title: String          // resolved: header → body H1 → slug
    var source: String?        // chat title at time of generation
    var model: String?         // model id used to generate
    var date: Date?            // from header
    var instructions: String?  // optional /note(...) extras from header
    var content: String        // full file contents (header + body)
    var bodyContent: String    // body only, header stripped, for in-app display
    var modifiedAt: Date       // file mtime — drives sidebar sort order
    var fileURL: URL
    /// Line 1 verbatim when the file carries a metadata header, else nil.
    /// Held so a body edit can put the header back BYTE FOR BYTE rather
    /// than re-composing it from the fields above — `parse` models five
    /// keys and a hand-written note may carry others, which a rebuild
    /// would silently drop.
    var header: String?
    /// The header's own `Title:`, which is NOT the same thing as the
    /// resolved `title` (that falls back to a body H1, then the slug).
    /// An edit may only re-sync a title the header actually declares —
    /// see `updateNoteBody`.
    var headerTitle: String?

    var id: String { slug }
}

@MainActor
final class NotesManager: ObservableObject {
    /// All notes discovered under the notes folder, sorted newest-first
    /// (by file mtime, not the metadata `Date:` field, since the latter
    /// can be missing or stale on user-edited files).
    @Published private(set) var notes: [StoredNote] = []

    // MARK: - Reload / load

    func reload() {
        let fm = FileManager.default
        let dir = SipaiPaths.notesDir
        guard fm.fileExists(atPath: dir.path),
              let entries = try? fm.contentsOfDirectory(
                  at: dir,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles])
        else {
            notes = []
            return
        }
        var loaded: [StoredNote] = []
        for url in entries where url.pathExtension == "md" {
            guard let note = Self.load(url: url) else { continue }
            loaded.append(note)
        }
        loaded.sort { $0.modifiedAt > $1.modifiedAt }
        notes = loaded
    }

    /// Read and parse ONE note file. nil for a dot-file or an unreadable
    /// one, matching `reload`'s skip.
    private static func load(url: URL) -> StoredNote? {
        let slug = url.deletingPathExtension().lastPathComponent
        guard !slug.hasPrefix(".") else { return nil }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parsed = parse(content: content, slug: slug)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
        return StoredNote(
            slug: slug,
            title: parsed.title,
            source: parsed.source,
            model: parsed.model,
            date: parsed.date,
            instructions: parsed.instructions,
            content: content,
            bodyContent: parsed.body,
            modifiedAt: mtime,
            fileURL: url,
            header: parsed.header,
            headerTitle: parsed.headerTitle
        )
    }

    /// Re-read ONE note from disk and re-sort, instead of rescanning the
    /// folder. The editor autosaves while the user is still typing, and
    /// `reload` reads every note file whole — a targeted refresh keeps
    /// that cost off the editing path. Falls back to a full reload when
    /// the file has gone (or was never listed), so a note deleted under
    /// us cannot linger.
    private func refresh(slug: String) {
        guard let idx = notes.firstIndex(where: { $0.slug == slug }),
              let updated = Self.load(url: notes[idx].fileURL) else {
            reload()
            return
        }
        notes[idx] = updated
        notes.sort { $0.modifiedAt > $1.modifiedAt }
    }

    func loadNote(slug: String) -> StoredNote? {
        notes.first(where: { $0.slug == slug })
    }

    /// Retitle a note in place (the slug/filename stays). Rewrites the
    /// metadata header's `Title:` field AND the first body H1 — the
    /// resolved title falls back H1-first when the header is missing,
    /// so both must agree. Files with neither get a minimal header
    /// prepended.
    @discardableResult
    func renameNote(slug: String, newTitle: String) -> Bool {
        // Land any in-flight body edit FIRST. This rewrites the file from
        // `note.content`, so a staged edit that flushed afterwards would
        // be written against the pre-rename header — and its own H1 sync
        // would then undo the rename.
        flushPendingEdit(slug: slug)
        guard let note = loadNote(slug: slug) else { return false }
        var lines = note.content.components(separatedBy: "\n")
        var changed = false

        if let first = lines.first,
           let rewritten = Self.headerSettingTitle(first, to: newTitle) {
            lines[0] = rewritten
            changed = true
        }

        // Retitle the first H1 OUTSIDE fenced code blocks only. A note that
        // opens with a ``` fence can contain "# install deps"-style shell
        // comments, and a naive first-"# "-line scan would overwrite
        // those with the new title.
        if let i = Self.firstHeadingIndex(in: lines) {
            lines[i] = "# \(newTitle)"
            changed = true
        }

        if !changed {
            lines.insert("", at: 0)
            lines.insert("<!-- Title: \(newTitle) -->", at: 0)
        }

        do {
            try lines.joined(separator: "\n")
                .write(to: note.fileURL, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        reload()
        return true
    }

    // MARK: - Editing

    /// Body text typed into the note editor but not yet on disk, keyed by
    /// slug.
    ///
    /// It lives HERE, on an object that outlives every centre-pane view,
    /// rather than in `NoteView.@State` — `ContentView`'s router tears
    /// that view down on every detour to a chat or a session, which is
    /// the same reason composer drafts live on `AppState`. The payoff is
    /// that a flush never has to read a torn-down view's state: the
    /// manager already holds the text, so `onDisappear` only has to say
    /// "now", not "here is what to write".
    ///
    /// NOT `@Published`: the editor owns the live text, and republishing
    /// per keystroke would re-render the window for a bookkeeping write.
    private var pendingBodies: [String: String] = [:]

    /// Slug whose last write FAILED, or nil. Published because a silent
    /// failure here loses the user's writing — the editor says so, and
    /// the staged text is kept for the next flush to retry.
    @Published private(set) var lastSaveFailure: String? = nil

    /// Record a keystroke. Cheap by design — one dictionary write, no
    /// disk, no publish. `flushPendingEdit` is what reaches the file.
    func stageEdit(slug: String, body: String) {
        pendingBodies[slug] = body
    }

    /// Text staged for `slug` but not yet written, if any.
    func pendingBody(slug: String) -> String? { pendingBodies[slug] }

    /// Write one staged body out, dropping the staged copy unless the
    /// disk refused it.
    @discardableResult
    func flushPendingEdit(slug: String) -> NoteWriteOutcome {
        guard let body = pendingBodies[slug] else { return .unchanged }
        let outcome = updateNoteBody(slug: slug, newBody: body)
        // A FAILED write keeps the staged text: the next flush retries
        // it, where dropping it would throw the user's writing away over
        // a transient disk error. Every other outcome is settled.
        if outcome != .failed { pendingBodies.removeValue(forKey: slug) }
        return outcome
    }

    /// Flush everything staged. The quit path and `NoteView`'s teardown
    /// both call this, neither of which knows which note was being
    /// edited.
    func flushPendingEdits() {
        for slug in pendingBodies.keys.sorted() {
            flushPendingEdit(slug: slug)
        }
    }

    /// Throw staged text away unwritten. Only the factory reset calls
    /// this: an unsaved edit is user data held in RAM, so wiping the
    /// data directory cannot reach it, and a later flush would put a
    /// file back into the folder the reset just emptied.
    func discardPendingEdits() {
        pendingBodies.removeAll()
        lastSaveFailure = nil
    }

    /// Replace a note's BODY, keeping its metadata header.
    ///
    /// The editor only ever showed the body, so everything else in the
    /// file is ours to preserve verbatim — writing the whole `content`
    /// instead would let a stray keystroke break the header and take the
    /// title, the model and the date pills with it.
    @discardableResult
    func updateNoteBody(slug: String, newBody: String) -> NoteWriteOutcome {
        guard let note = loadNote(slug: slug) else { return .missing }

        // The reader sees the H1, not an HTML comment, so a body edit
        // that retitles the note wins over a now-stale header `Title:`.
        // Only ever a RE-sync: a header that declares no title is left
        // alone, because the resolved title already falls back to the H1
        // and inserting one would pin the name against every later edit.
        var header = note.header
        if let line = note.header,
           let declared = note.headerTitle,
           // An empty `Title:` is not a declared one — the note is
           // already named by its H1, so there is nothing to re-sync.
           !declared.isEmpty,
           let heading = Self.firstHeading(in: newBody),
           !heading.isEmpty,
           heading != declared,
           let rewritten = Self.headerSettingTitle(line, to: heading) {
            header = rewritten
        }

        let content = header.map { $0 + "\n\n" + newBody } ?? newBody

        // A save that changes nothing must not touch the file: `reload`
        // and `refresh` sort newest-first on mtime, so an identical
        // rewrite would jump the row to the top of the Notes section for
        // nothing, and rows that reorder under the cursor make clicks
        // look dead. Same rule as `ChatManager.saveChat`.
        guard content != note.content else {
            if lastSaveFailure == slug { lastSaveFailure = nil }
            return .unchanged
        }

        do {
            try content.write(to: note.fileURL, atomically: true, encoding: .utf8)
        } catch {
            lastSaveFailure = slug
            return .failed
        }
        if lastSaveFailure == slug { lastSaveFailure = nil }
        refresh(slug: slug)
        return .written
    }

    // MARK: - Create / delete / export

    /// Persist a freshly-generated note. The H1 of `content` (if present)
    /// becomes the title; otherwise we fall back to `sourceTitle`. Returns
    /// the resulting `StoredNote`, or nil on disk-write failure.
    @discardableResult
    func createNote(content: String,
                    sourceTitle: String,
                    modelId: String,
                    extraInstructions: String? = nil) -> StoredNote? {
        // 1. Title resolution: H1 of body, else fall back to chat title.
        var titleFromBody: String? = nil
        for line in content.components(separatedBy: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("# ") {
                titleFromBody = String(s.dropFirst(2))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
                break
            }
        }
        let resolvedTitle = (titleFromBody?.isEmpty == false ? titleFromBody! : sourceTitle)

        // 2. Find a unique slug.
        let baseSlug = SipaiPaths.slugify(resolvedTitle)
        let folder = SipaiPaths.notesDir
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var slug = baseSlug
        var url = folder.appendingPathComponent("\(slug).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            slug = "\(baseSlug)-\(counter)"
            url = folder.appendingPathComponent("\(slug).md")
            counter += 1
        }

        // 3. Compose metadata header + body and write.
        let dateStr = Self.timestamp()
        var metaParts = [
            "Title: \(resolvedTitle)",
            "Source: \(sourceTitle.isEmpty ? "untitled" : sourceTitle)",
            "Model: \(modelId)",
            "Date: \(dateStr)"
        ]
        if let extra = extraInstructions, !extra.isEmpty {
            metaParts.append("Instructions: \(extra)")
        }
        let header = "<!-- " + metaParts.joined(separator: " | ") + " -->\n\n"
        let fullContent = header + content
        do {
            try fullContent.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        reload()
        return notes.first(where: { $0.slug == slug })
    }

    func deleteNote(slug: String) {
        // Deliberately DISCARDED, not flushed: writing an edit to a file
        // the user just asked to delete would re-create it.
        pendingBodies.removeValue(forKey: slug)
        if lastSaveFailure == slug { lastSaveFailure = nil }
        guard let note = notes.first(where: { $0.slug == slug }) else { return }
        try? FileManager.default.removeItem(at: note.fileURL)
        reload()
    }

    /// Copy a note's full file contents (including metadata header) to a
    /// user-chosen destination. Returns true on success.
    @discardableResult
    func exportNote(slug: String, to destination: URL) -> Bool {
        // Export what is on SCREEN, not what happened to reach disk in
        // the last second of typing.
        flushPendingEdit(slug: slug)
        guard let note = notes.first(where: { $0.slug == slug }) else { return false }
        do {
            try note.content.write(to: destination, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Render a note to PDF at `destination`.
    ///
    /// Goes through the same `NoteHTML` document the Preview pane draws,
    /// so the file is the page the reader was just looking at — that
    /// agreement is the whole reason the two share a converter. Only the
    /// BODY is passed: the metadata header is a SipAI storage detail and
    /// is re-emitted as a real title block, never dumped as an HTML
    /// comment into the document.
    func exportPDF(slug: String, to destination: URL) async throws {
        // Export what is on SCREEN, exactly as the markdown path does.
        flushPendingEdit(slug: slug)
        guard let note = notes.first(where: { $0.slug == slug }) else {
            throw NoteExportError.missing
        }
        try await NotePDFExporter.export(
            markdown: note.bodyContent,
            metadata: NoteHTML.Metadata(title: note.title,
                                        model: note.model,
                                        date: note.date),
            to: destination)
    }

    // MARK: - Header parsing

    private struct Parsed {
        var title: String
        var source: String?
        var model: String?
        var date: Date?
        var instructions: String?
        var body: String
        var header: String?
        var headerTitle: String?
    }

    private static func parse(content: String, slug: String) -> Parsed {
        let lines = content.components(separatedBy: "\n")
        var header: String? = nil
        var headerTitle: String? = nil
        var source: String? = nil
        var model: String? = nil
        var date: Date? = nil
        var instructions: String? = nil
        var bodyStart = 0

        // One-line header: "<!-- Title: ... | ... -->". Both delimiters are
        // located on the ORIGINAL line — a fixed `offsetBy: 4` slice would
        // mis-parse indented headers and, on a first line like "<!-->"
        // (where the closer overlaps the opener), build an invalid range
        // and trap on every reload. A malformed header must never
        // crash: the guard just skips header parsing and the fallback
        // chain below (body H1 → slug) still produces a title.
        if let first = lines.first,
           first.trimmingCharacters(in: .whitespaces).hasPrefix("<!--"),
           let open = first.range(of: "<!--"),
           let close = first.range(of: "-->"),
           close.lowerBound >= open.upperBound {
            let inner = String(first[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let parts = inner.components(separatedBy: " | ")
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm"
            for part in parts {
                guard let colon = part.firstIndex(of: ":") else { continue }
                let key = String(part[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(part[part.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                switch key {
                case "Title":        headerTitle = value
                case "Source":       source = value
                case "Model":        model = value
                case "Date":         date = df.date(from: value)
                case "Instructions": instructions = value
                default: break
                }
            }
            header = first
            bodyStart = 1
            // Skip the customary blank line right after the header.
            if bodyStart < lines.count,
               lines[bodyStart].trimmingCharacters(in: .whitespaces).isEmpty {
                bodyStart += 1
            }
        }

        let body = lines[bodyStart...].joined(separator: "\n")

        // Title fallback chain: header → body H1 → slug. The H1 scan is
        // the fence-aware one `renameNote` already needed: a note whose
        // body opens with a ``` block must not take "# install deps"
        // from inside it for its name.
        let resolvedTitle: String
        if let h = headerTitle, !h.isEmpty {
            resolvedTitle = h
        } else {
            let bodyH1 = firstHeading(in: body)
            resolvedTitle = (bodyH1?.isEmpty == false ? bodyH1! : slug)
        }

        return Parsed(
            title: resolvedTitle,
            source: source,
            model: model,
            date: date,
            instructions: instructions,
            body: body,
            header: header,
            headerTitle: headerTitle
        )
    }

    // MARK: - Header / heading helpers
    //
    // One spelling each, shared by `parse`, `renameNote` and
    // `updateNoteBody`.

    /// Index of the first ATX H1 in `lines` that is NOT inside a fenced
    /// code block, or nil. Safe to run over a whole file: a metadata
    /// header is neither a fence nor a heading.
    static func firstHeadingIndex(in lines: [String]) -> Int? {
        var inFence = false
        for i in lines.indices {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if !inFence, trimmed.hasPrefix("# ") { return i }
        }
        return nil
    }

    /// Text of the first H1 outside a fence, trimmed, or nil.
    static func firstHeading(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let i = firstHeadingIndex(in: lines) else { return nil }
        return String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst(2))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Rewrite the `Title:` field of a one-line metadata header (adding
    /// it when absent), preserving every other field verbatim. nil when
    /// `line` is not a header, which is the caller's signal to prepend
    /// one.
    ///
    /// The delimiters are located on the ORIGINAL line for the same
    /// reason `parse` does it: a fixed `dropFirst(4)`/`dropLast(3)`
    /// slice mis-reads an indented header, and on a degenerate `<!-->`
    /// it builds an invalid range and traps.
    static func headerSettingTitle(_ line: String, to title: String) -> String? {
        guard line.trimmingCharacters(in: .whitespaces).hasPrefix("<!--"),
              let open = line.range(of: "<!--"),
              let close = line.range(of: "-->"),
              close.lowerBound >= open.upperBound
        else { return nil }
        let inner = String(line[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        var parts = inner.components(separatedBy: " | ").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if let i = parts.firstIndex(where: { $0.hasPrefix("Title:") }) {
            parts[i] = "Title: \(title)"
        } else {
            parts.insert("Title: \(title)", at: 0)
        }
        return "<!-- " + parts.joined(separator: " | ") + " -->"
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }

    // MARK: - Note generation primitives

    /// System prompt used when summarising a chat into a note. The one
    /// copy: the input card's note icon is the only caller today, and
    /// any future note-generating surface must reference this constant
    /// rather than re-inline the text, or the two drift.
    static let notePromptSystem = """
    You are a note-taking assistant. Convert the following conversation into \
    a well-organized note in Markdown format. \
    Begin the note with a single top-level heading ('# Title') that concisely \
    captures the main topic of the note — the title should be 3-8 words, \
    descriptive, and use plain Title Case (no quotes, no trailing punctuation). \
    After the title, structure the body with clear headings, subheadings, and \
    bullet points where appropriate. Extract the key information, insights, \
    decisions, and action items. Remove conversational filler and focus on \
    substance. The note should be useful as a standalone reference — someone \
    reading it should understand the topic without needing the original chat.\
    \n\n\
    Write the note in the same language as the conversation. Detect the \
    primary language used in the conversation and write the entire note in \
    that language — headings, subheadings, bullet points, everything. Do \
    not translate to English unless the conversation is already in English.
    """

    /// Render a chat transcript in the same `Label: text` form the typed
    /// `/note` command uses, so the model sees identical input.
    static func formatTranscript(_ messages: [ChatMessage],
                                 userLabel: String,
                                 aiLabel: String) -> String {
        messages.map { msg in
            let label = msg.role == "user" ? userLabel : aiLabel
            return "\(label): \(msg.content)"
        }.joined(separator: "\n\n")
    }
}
