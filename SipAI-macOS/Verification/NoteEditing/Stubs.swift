// Stand-ins for the two things NotesManager.swift touches outside
// itself, so the REAL file can be compiled and run without a window or
// an Application Support directory.
//
// Nothing here is part of the app target — this directory sits outside
// SipAI/, so these files are never compiled into the product.
import Foundation

/// The real SipaiPaths resolves Application Support. The harness must
/// never touch the user's actual notes, so this stand-in points at a
/// throwaway root. `slugify` is copied VERBATIM from the original —
/// `createNote` derives filenames through it, so a paraphrase here
/// would test a slug the app never produces.
enum SipaiPaths {
    static var root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sipai-note-editing-harness", isDirectory: true)

    static var dataDir: URL { root }
    static var notesDir: URL { dataDir.appendingPathComponent("notes", isDirectory: true) }

    static func slugify(_ title: String) -> String {
        let lowered = title.lowercased().trimmingCharacters(in: .whitespaces)
        let cleaned = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        var s = String(cleaned)
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.replacingOccurrences(of: " ", with: "-")
        s = s.replacingOccurrences(of: "_", with: "-")
        while s.hasPrefix("-") { s.removeFirst() }
        while s.hasSuffix("-") { s.removeLast() }
        if s.isEmpty { s = "untitled" }
        if s.count > 60 { s = String(s.prefix(60)) }
        return s
    }
}

/// Only `formatTranscript` reads this, and only for `role`/`content`.
struct ChatMessage {
    var role: String
    var content: String
}
