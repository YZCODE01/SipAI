// Headless verification for in-app note editing. See run.sh.
//
// Not part of the app target — this directory sits outside SipAI/.
//
// The editor autosaves, which means every rule below fails SILENTLY
// when it breaks: the user keeps typing, sees no error, and finds out
// later that a title reverted or a header field went missing. So the
// rules that are easy to get wrong are exercised here against a
// throwaway notes directory:
//
//   * the metadata header survives a body edit BYTE FOR BYTE, including
//     fields `parse` does not model
//   * an edit that changes the H1 re-syncs the header's `Title:`, so the
//     sidebar and the page cannot disagree
//   * a header that declares NO title is left alone (the H1 fallback is
//     already right, and inserting one would pin the name)
//   * an identical save is a no-op — it must not bump mtime, because the
//     sidebar sorts on it and rows that reorder under the cursor make
//     clicks look dead
//   * the first-H1 scan skips fenced code blocks (a "# install deps"
//     inside a ``` block is not a title)
//   * staged text survives the view being torn down, and a FAILED write
//     keeps it for the retry instead of dropping the user's writing
//   * delete discards staged text rather than resurrecting the file
//   * rename lands a staged edit first, so the two cannot undo each other
//
// What this cannot reach: the SwiftUI half — the Edit/Preview toggle,
// the debounce timer, and NoteView's onDisappear. Those are asserted by
// construction (the debounce is a convenience over `stageEdit`, which
// is synchronous) and by running the app.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "  ok   " : "  FAIL ") + label + (detail.isEmpty ? "" : " — \(detail)"))
    if !ok { failures += 1 }
}

let fm = FileManager.default

func resetFixture() {
    try? fm.removeItem(at: SipaiPaths.root)
    try? fm.createDirectory(at: SipaiPaths.notesDir, withIntermediateDirectories: true)
}

@discardableResult
func writeNote(_ slug: String, _ content: String) -> URL {
    let url = SipaiPaths.notesDir.appendingPathComponent("\(slug).md")
    try? content.write(to: url, atomically: true, encoding: .utf8)
    return url
}

func readNote(_ slug: String) -> String {
    (try? String(contentsOf: SipaiPaths.notesDir.appendingPathComponent("\(slug).md"),
                 encoding: .utf8)) ?? ""
}

func mtime(_ slug: String) -> Date? {
    let p = SipaiPaths.notesDir.appendingPathComponent("\(slug).md").path
    return (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date
}

// Everything on NotesManager is @MainActor; this harness has no run
// loop, so it drives it on the main actor directly.
@MainActor
func run() {

    // MARK: 1 — the header survives a body edit, unmodelled fields included

    print("\n1. Metadata header preservation")
    resetFixture()
    // `Project:` and `Tags:` are fields `parse` knows nothing about. A
    // save that RE-COMPOSED the header from the parsed fields would drop
    // them; only putting line 1 back verbatim keeps them.
    let full = """
    <!-- Title: Quarterly Plan | Source: planning chat | Model: claude-opus-5 | \
    Date: 2026-08-15 09:30 | Instructions: keep it short | Project: acme | Tags: a,b -->

    # Quarterly Plan

    Original body.
    """
    writeNote("quarterly-plan", full)
    let m = NotesManager()
    m.reload()
    check("note loaded", m.notes.count == 1, "\(m.notes.count) found")

    var outcome = m.updateNoteBody(slug: "quarterly-plan",
                                   newBody: "# Quarterly Plan\n\nEdited body.")
    check("edit reported .written", outcome == .written, "\(outcome)")
    let after = readNote("quarterly-plan")
    check("header line unchanged",
          after.components(separatedBy: "\n").first == full.components(separatedBy: "\n").first)
    check("unmodelled Project: survived", after.contains("Project: acme"))
    check("unmodelled Tags: survived", after.contains("Tags: a,b"))
    check("body replaced", after.contains("Edited body.") && !after.contains("Original body."))
    check("model pill still resolves", m.loadNote(slug: "quarterly-plan")?.model == "claude-opus-5")
    check("date still parses", m.loadNote(slug: "quarterly-plan")?.date != nil)

    // MARK: 2 — an edited H1 re-titles the note

    print("\n2. H1 → header Title re-sync")
    outcome = m.updateNoteBody(slug: "quarterly-plan",
                               newBody: "# Annual Plan\n\nEdited body.")
    check("edit reported .written", outcome == .written, "\(outcome)")
    check("header Title followed the H1",
          readNote("quarterly-plan").contains("Title: Annual Plan"))
    check("resolved title followed too",
          m.loadNote(slug: "quarterly-plan")?.title == "Annual Plan")
    check("other header fields untouched",
          readNote("quarterly-plan").contains("Source: planning chat")
          && readNote("quarterly-plan").contains("Project: acme"))
    check("slug (filename) did NOT change", m.notes.first?.slug == "quarterly-plan")

    // Removing the H1 entirely must not blank the name.
    m.updateNoteBody(slug: "quarterly-plan", newBody: "Just prose, no heading.")
    check("no H1 leaves the title alone",
          m.loadNote(slug: "quarterly-plan")?.title == "Annual Plan")

    // MARK: 3 — a header with no Title: is left alone

    print("\n3. A header that declares no Title keeps falling back")
    resetFixture()
    writeNote("untitled-header", """
    <!-- Source: some chat | Model: claude-opus-5 -->

    # From The Heading

    Body.
    """)
    let m3 = NotesManager()
    m3.reload()
    check("title came from the H1", m3.notes.first?.title == "From The Heading")
    m3.updateNoteBody(slug: "untitled-header", newBody: "# A New Heading\n\nBody.")
    check("no Title: was inserted", !readNote("untitled-header").contains("Title:"))
    check("title still tracks the H1",
          m3.loadNote(slug: "untitled-header")?.title == "A New Heading")

    // MARK: 4 — an identical save is a no-op

    print("\n4. Byte-identical save does not touch the file")
    resetFixture()
    writeNote("stable", "<!-- Title: Stable -->\n\n# Stable\n\nBody.")
    let m4 = NotesManager()
    m4.reload()
    let body = m4.notes.first!.bodyContent
    let before = mtime("stable")
    // Coarse filesystem timestamps would hide a rewrite that happened
    // inside the same second.
    Thread.sleep(forTimeInterval: 1.1)
    let same = m4.updateNoteBody(slug: "stable", newBody: body)
    check("reported .unchanged", same == .unchanged, "\(same)")
    check("mtime not bumped", mtime("stable") == before,
          "\(String(describing: before)) → \(String(describing: mtime("stable")))")

    // MARK: 5 — a header-less note stays header-less

    print("\n5. Header-less notes round-trip")
    resetFixture()
    writeNote("plain", "# Plain Note\n\nHand written, no header.")
    let m5 = NotesManager()
    m5.reload()
    check("title from H1", m5.notes.first?.title == "Plain Note")
    m5.updateNoteBody(slug: "plain", newBody: "# Plain Note\n\nEdited.")
    check("no header invented", !readNote("plain").hasPrefix("<!--"))
    check("body written", readNote("plain") == "# Plain Note\n\nEdited.")

    // MARK: 6 — the H1 scan skips fenced code

    print("\n6. Fenced code is not a heading")
    resetFixture()
    writeNote("fenced", """
    ```bash
    # install deps
    npm install
    ```

    # Real Title

    Body.
    """)
    let m6 = NotesManager()
    m6.reload()
    check("title is the real H1, not the shell comment",
          m6.notes.first?.title == "Real Title",
          m6.notes.first?.title ?? "nil")
    check("firstHeading agrees",
          NotesManager.firstHeading(in: "```\n# not a title\n```\n# Yes") == "Yes")
    // Rename must not overwrite the comment inside the fence either.
    m6.renameNote(slug: "fenced", newTitle: "Renamed")
    check("rename left the fenced comment alone",
          readNote("fenced").contains("# install deps"))
    check("rename hit the real H1", readNote("fenced").contains("# Renamed"))

    // MARK: 7 — staged text survives a teardown

    print("\n7. Staged edits survive the view going away")
    resetFixture()
    writeNote("staged", "<!-- Title: Staged -->\n\n# Staged\n\nBefore.")
    let m7 = NotesManager()
    m7.reload()
    // What NoteView does on each keystroke. No disk yet.
    m7.stageEdit(slug: "staged", body: "# Staged\n\nAfter.")
    check("nothing written yet", readNote("staged").contains("Before."))
    check("staged text readable back", m7.pendingBody(slug: "staged")?.contains("After.") == true)
    // What onDisappear / quit does — note it hands over NO text.
    m7.flushPendingEdits()
    check("flush wrote it", readNote("staged").contains("After."))
    check("staged copy dropped", m7.pendingBody(slug: "staged") == nil)

    // MARK: 8 — delete discards, it does not resurrect

    print("\n8. Delete discards staged text")
    resetFixture()
    writeNote("doomed", "<!-- Title: Doomed -->\n\n# Doomed\n\nBody.")
    let m8 = NotesManager()
    m8.reload()
    m8.stageEdit(slug: "doomed", body: "# Doomed\n\nTyped just before deleting.")
    m8.deleteNote(slug: "doomed")
    m8.flushPendingEdits()
    check("file stayed deleted",
          !fm.fileExists(atPath: SipaiPaths.notesDir.appendingPathComponent("doomed.md").path))
    check("nothing left staged", m8.pendingBody(slug: "doomed") == nil)

    // MARK: 9 — a failed write keeps the text and says so

    print("\n9. A write that fails is reported, and retried")
    resetFixture()
    writeNote("locked", "<!-- Title: Locked -->\n\n# Locked\n\nBefore.")
    let m9 = NotesManager()
    m9.reload()
    check("no failure yet", m9.lastSaveFailure == nil)
    // atomically: writes a temp file in the same directory and renames,
    // so a read-only directory is enough to fail the write.
    try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: SipaiPaths.notesDir.path)
    m9.stageEdit(slug: "locked", body: "# Locked\n\nAfter.")
    let failed = m9.flushPendingEdit(slug: "locked")
    check("reported .failed", failed == .failed, "\(failed)")
    check("failure published for the right slug", m9.lastSaveFailure == "locked",
          m9.lastSaveFailure ?? "nil")
    check("text KEPT for the retry", m9.pendingBody(slug: "locked")?.contains("After.") == true)
    // Unlock and let the next flush land it.
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: SipaiPaths.notesDir.path)
    let retried = m9.flushPendingEdit(slug: "locked")
    check("retry succeeded", retried == .written, "\(retried)")
    check("failure cleared", m9.lastSaveFailure == nil)
    check("edit is on disk", readNote("locked").contains("After."))

    // MARK: 10 — rename and a staged edit cannot undo each other

    print("\n10. Rename lands a staged edit first")
    resetFixture()
    writeNote("racy", "<!-- Title: Old Name | Model: m -->\n\n# Old Name\n\nBody.")
    let m10 = NotesManager()
    m10.reload()
    m10.stageEdit(slug: "racy", body: "# Old Name\n\nBody plus a new sentence.")
    m10.renameNote(slug: "racy", newTitle: "New Name")
    check("the staged sentence is not lost",
          readNote("racy").contains("Body plus a new sentence."))
    check("the rename stuck in the header", readNote("racy").contains("Title: New Name"))
    check("the rename stuck in the H1", readNote("racy").contains("# New Name"))
    check("resolved title is the new one", m10.loadNote(slug: "racy")?.title == "New Name")
    // And nothing staged is left to re-apply the old heading afterwards.
    m10.flushPendingEdits()
    check("no late flush undid it", m10.loadNote(slug: "racy")?.title == "New Name")

    try? fm.removeItem(at: SipaiPaths.root)
}

MainActor.assumeIsolated { run() }

print("")
if failures == 0 {
    print("All note-editing checks passed.")
    exit(0)
} else {
    print("\(failures) check(s) FAILED.")
    exit(1)
}
