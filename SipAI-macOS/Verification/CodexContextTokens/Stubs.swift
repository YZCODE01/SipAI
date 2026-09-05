// Minimal stand-ins for the app types CodexSessions.swift references,
// so the harness can compile and exercise the REAL scanner rather than
// a paraphrase of it. Copied from AgentSession.swift; only the members
// CodexSessions.swift actually touches are kept.
//
// Nothing here is part of the app target.
import Foundation

enum AgentSessionOrigin: Hashable {
    case user
    case scheduled
    case subagent
}

struct AgentSession: Identifiable, Hashable {
    let id: String
    let fileURL: URL
    let title: String
    let modifiedAt: Date
    var lastUserMessageAt: Date? = nil
    let projectPath: URL?
    let scheduledTaskName: String?
    var agentKey: String = "claude_code"
    var origin: AgentSessionOrigin = .user
    var titleIsFallback: Bool = false
    var isEmptyShell: Bool = false

    var activityAt: Date { lastUserMessageAt ?? modifiedAt }
}

struct AgentSessionHistoryItem: Identifiable, Hashable {
    let id: UUID = UUID()
    let kind: Kind
    var recordUuid: String? = nil

    enum Kind {
        case userText(String)
        case assistantText(String)
        case toolUse(id: String, name: String, input: [String: Any])
        case toolResult(toolUseId: String, content: String, isError: Bool)
        case interrupted(message: String)
        case compaction(preTokens: Int?, postTokens: Int?)
    }

    static func == (lhs: AgentSessionHistoryItem,
                    rhs: AgentSessionHistoryItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum AgentSessionScanner {
    /// Verbatim from AgentSession.swift — the bounded, lossy-decoded
    /// tail read every scanner in this app goes through. The budget IS
    /// the thing under test for `lastContextTokens`, so this one must
    /// stay a real copy, not a whole-file read.
    static func boundedTail(of url: URL, budget: Int = 256 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(budget) ? size - UInt64(budget) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: budget) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func isScratchLocation(_ url: URL?) -> Bool {
        guard let url else { return false }
        let path = url.standardizedFileURL.path
        for root in ["/tmp/", "/private/tmp/", "/var/tmp/", "/var/folders/"] {
            if path.hasPrefix(root) { return true }
        }
        return false
    }

    static func cachedLastUserMessageDate(
        of url: URL, size: UInt64, mtime: Date,
        read: (URL) -> Date?
    ) -> Date? {
        read(url)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func isoDate(_ value: Any?) -> Date? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    /// The shared scheduled-task name regex lives on the claude scanner;
    /// CodexSessionScanner calls it so both file the marker one way.
    static func extractScheduledTaskName(from text: String) -> String? {
        let pattern = "<scheduled-task\\s+name=([\"'])(.+?)\\1"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text,
                                    range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 2), in: text) else { return nil }
        return String(text[r])
    }
}
