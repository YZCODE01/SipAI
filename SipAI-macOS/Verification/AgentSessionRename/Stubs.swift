// Stand-in for the one KimiSessionScanner helper
// AgentSessionRename.swift calls, copied verbatim from KimiSessions.swift
// so the harness exercises the real rename code, not a paraphrase.
//
// The store root is resolved the same way the shipping scanner resolves
// it — through `KIMI_CODE_HOME` — which is also how run.sh points this
// harness at a throwaway directory instead of a real ~/.kimi-code.
import Foundation

enum KimiSessionScanner {
    static var home: URL {
        let env = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code", isDirectory: true)
    }

    static var sessionRoot: URL {
        home.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Walk up from a wire file to the `<sessionId>/` directory that
    /// owns it — verbatim from the shipping scanner.
    static func sessionDirectory(of url: URL) -> URL? {
        let rootPath = sessionRoot.standardizedFileURL.path
        var candidate = url.standardizedFileURL
        // At most a handful of hops: sessions/<key>/<id>/agents/main/f.
        for _ in 0..<8 {
            let parent = candidate.deletingLastPathComponent()
            let grand = parent.deletingLastPathComponent()
            if grand.standardizedFileURL.path == rootPath {
                return candidate
            }
            if parent.path == candidate.path { return nil }  // hit "/"
            candidate = parent
        }
        return nil
    }
}
