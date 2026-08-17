// SipaiPaths.swift
// Filesystem paths for SipAI's own data, all of it under
// ~/Library/Application Support/SipAI/. The agents' session stores are
// NOT in here — those belong to the agent CLIs and are read in place.

import Foundation

enum SipaiPaths {
    /// `~/Library/Application Support/SipAI/` — standard macOS location for
    /// per-user app data. Created on first launch by `ensureDataDir()`.
    static var dataDir: URL {
        let fm = FileManager.default
        if let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                        in: .userDomainMask,
                                        appropriateFor: nil,
                                        create: true) {
            return appSupport.appendingPathComponent("SipAI", isDirectory: true)
        }
        // Fallback if Application Support is somehow unavailable.
        let home = fm.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/SipAI", isDirectory: true)
    }

    static var configFile: URL { dataDir.appendingPathComponent("config.json") }
    static var metaFile: URL { dataDir.appendingPathComponent("meta.json") }
    static var generalSystemPromptFile: URL { dataDir.appendingPathComponent("system_prompt.txt") }
    static var notesDir: URL { dataDir.appendingPathComponent("notes", isDirectory: true) }

    /// ~/Library/Application Support/SipAI/mcp/ — home for the MCP
    /// approver runtime files (approver.py, config.json, approver.sock).
    /// Kept inside this app's own data directory so nothing else can
    /// collide with it on the UDS bind.
    static var mcpDir: URL {
        dataDir.appendingPathComponent("mcp", isDirectory: true)
    }

    /// Markers used to recover from folder renames inside a user-chosen
    /// "dedicated folder". READ-ONLY here: `LocalFilesView` locates the
    /// `chats/` and `notes/` subfolders by marker rather than by name,
    /// so a rename in Finder doesn't break the link. Nothing in this
    /// app writes them.
    static let markerChats = ".sipai_chats"
    static let markerNotes = ".sipai_notes"

    static func ensureDataDir() {
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    static func chatStateFile(slug: String, project: String?) -> URL {
        if let p = project, !p.isEmpty {
            return dataDir.appendingPathComponent(p, isDirectory: true)
                .appendingPathComponent("\(slug).json")
        }
        return dataDir.appendingPathComponent("\(slug).json")
    }

    /// Slug-ify a title for use as a chat filename.
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
