// Stand-ins for the two things ChatManager.swift touches outside
// itself — the data directory and the config its unread replies are
// kept in — so the REAL file can be compiled and run without an
// Application Support directory.
//
// Nothing here is part of the app target — this directory sits outside
// SipAI/, so these files are never compiled into the product.
import Foundation
import Combine

/// The real SipaiPaths resolves Application Support. The harness must
/// never touch the user's actual chats, so this stand-in points at a
/// throwaway root. `slugify` is copied VERBATIM from the original —
/// `saveChat` mints filenames through it, so a paraphrase here would
/// test a slug the app never produces.
enum SipaiPaths {
    static var root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sipai-chat-turn-harness", isDirectory: true)

    static var dataDir: URL { root }

    static func chatStateFile(slug: String, project: String?) -> URL {
        var dir = dataDir
        if let project { dir = dir.appendingPathComponent(project, isDirectory: true) }
        return dir.appendingPathComponent("\(slug).json")
    }

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

/// The config's four unread-reply members, as plain set operations:
/// what ChatManager asks of it, recorded so the harness can read back
/// what the REAL manager decided. The storage — the cap, the JSON — is
/// ConfigManager's own and is not under test here.
final class ConfigManager: ObservableObject {
    @Published private(set) var chatUnreadKeys: Set<String> = []

    func markChatUnread(key: String, at date: Date = Date()) {
        chatUnreadKeys.insert(key)
    }
    func clearChatUnread(key: String) {
        chatUnreadKeys.remove(key)
    }
    func moveChatUnread(from old: String, to new: String) {
        guard chatUnreadKeys.remove(old) != nil else { return }
        chatUnreadKeys.insert(new)
    }
    func pruneChatUnread(keeping existing: Set<String>) {
        chatUnreadKeys = chatUnreadKeys.intersection(existing)
    }
}
