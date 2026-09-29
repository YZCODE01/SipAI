// Stand-ins for the app types around the subjects under test, so the
// harness compiles the REAL tailer (`AgentSessionTailer.swift`, with its
// writer probes), the REAL three readers and the REAL `StreamEvent`
// (extracted from AgentRunner.swift by run.sh) rather than a paraphrase
// of them. Only the members those files call exist, and none of them
// carries a rule this harness measures. Taken from AgentSessionFork's
// stubs, less the four types compiled for real here.
//
// `SipaiPaths` is redirected into a throwaway directory, and nothing
// here reaches a real agent store: every CLI this harness runs does so
// under a home it created.
//
// Nothing here is part of the app target.
import Foundation

struct ScheduledTaskDefinition: Equatable {
    var name: String
    var description: String
    var workingDirectory: URL? = nil
    var agent: String = "claude_code"
    static func read(name: String, skillFile: URL) -> ScheduledTaskDefinition? { nil }
}

/// Both halves the compiled files reach for: the interrupted marker
/// (readers) and the child environment (the app-server client). The
/// real builder merges the app's search paths and the login shell's
/// PATH, strips `DYLD_*` and overlays the proxy variables; the harness
/// runs from a shell, so the shell's PATH is the honest stand-in, and
/// `extraEnvironment` is how a test points codex at a throwaway home.
enum AgentRunner {
    static let interruptedByUserMessage = "Interrupted"
    nonisolated(unsafe) static var extraEnvironment: [String: String] = [:]

    static func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let dirs = ["/usr/bin", "/bin", "/usr/sbin", "/sbin",
                    "/usr/local/bin", "/opt/homebrew/bin"]
        let existing = env["PATH"] ?? ""
        env["PATH"] = dirs.joined(separator: ":")
            + (existing.isEmpty ? "" : ":" + existing)
        for key in env.keys where key.hasPrefix("DYLD_") { env.removeValue(forKey: key) }
        for (key, value) in extraEnvironment { env[key] = value }
        return env
    }
}

enum SipaiPaths {
    nonisolated(unsafe) static var dataDir: URL =
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sipai-externalturnwatch-harness")

    static var configFile: URL { dataDir.appendingPathComponent("config.json") }
    static var generalSystemPromptFile: URL {
        dataDir.appendingPathComponent("system_prompt.md")
    }

    static func ensureDataDir() {
        try? FileManager.default.createDirectory(at: dataDir,
                                                 withIntermediateDirectories: true)
    }
}

enum ShellEnvironment {
    static func resolve(_ name: String) -> String? { nil }
    static func resolveIfCaptured(_ name: String) -> String? { nil }
    static func prepare() async {}
}

enum AppTheme: String { case system, light, dark }
enum AppLanguage: String {
    case english = "en"
    static var effective: AppLanguage { .english }
    var localizationCode: String { rawValue }
}
enum FontTier: String { case compact, standard, large }
enum AgentGroupMode: String { case none, folder, task }

/// `binaryPath` answers nil, so `CodexCatalog.setContextWindow` and
/// `refreshFromCodex` never spawn from inside the catalog here; the
/// client is driven DIRECTLY by the test, with a binary it names.
enum AgentManager {
    nonisolated static func binaryPath(for key: String) -> String? { nil }
}
