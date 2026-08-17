// Minimal stand-ins for the two AgentSessionScanner helpers
// AgentSessionFork.swift calls, copied verbatim from AgentSession.swift
// so the harness exercises the real fork code, not a paraphrase.
import Foundation

enum AgentSessionScanner {
    static func boundedTail(of url: URL, budget: Int = 256 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(budget) ? size - UInt64(budget) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: budget) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func cleanUserText(_ text: String) -> String {
        var s = text
        for p in ["<scheduled-task[^>]*>[\\s\\S]*?</scheduled-task>",
                  "<system-reminder>[\\s\\S]*?</system-reminder>",
                  "<local-command-caveat>[\\s\\S]*?</local-command-caveat>",
                  "<[^>]+>"] {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractText(fromContent content: Any) -> String {
        if let s = content as? String {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let arr = content as? [Any] {
            var parts: [String] = []
            for block in arr {
                if let dict = block as? [String: Any],
                   dict["type"] as? String == "text",
                   let t = dict["text"] as? String { parts.append(t) }
                else if let s = block as? String { parts.append(s) }
            }
            return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(describing: content).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
