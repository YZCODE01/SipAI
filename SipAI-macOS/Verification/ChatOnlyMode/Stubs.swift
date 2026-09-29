// Stand-ins for the app types the subjects under test touch, so the
// harness compiles the REAL rules, readers, policy file, server driver
// and `KimiWebServerCall` rather than a paraphrase of them. Only the
// members they call exist, and none of them carries a rule this
// harness measures.
//
// `SipaiPaths` is redirected into a throwaway directory: this harness
// must never read or write the real
// ~/Library/Application Support/SipAI/config.json — and nothing here
// may reach the real ~/.codex, ~/.claude or ~/.kimi-code either; every
// CLI spawn runs under a home the test created (`AgentRunner
// .extraEnvironment` + the real `KIMI_CODE_HOME` / `CODEX_HOME` /
// `CLAUDE_CONFIG_DIR` variables the CLIs honour).
//
// Nothing here is part of the app target.
import Foundation

enum AgentSessionTailer {
    static let terminatingStopReasons: Set<String> = []
    static func progressState(forRawRecord obj: [String: Any]) -> Bool? { nil }
}

struct ScheduledTaskDefinition: Equatable {
    var name: String
    var description: String
    var workingDirectory: URL? = nil
    var agent: String = "claude_code"
    static func read(name: String, skillFile: URL) -> ScheduledTaskDefinition? { nil }
}

enum ClaudeSessionStatusStore {
    enum Verdict { case busy, idle, unknown }
    static func verdict(sessionId: String) -> Verdict { .unknown }
}

struct StreamEvent {
    let kind: StreamEventKind
    let contextTokens: Int?
    let isSystemNotice: Bool
    let fastModeState: String?
    let fastModeDisabledReason: String?
    let callSpeed: String?
    let modelContextWindows: [String: Int]?
    let attachedFiles: [String]

    init(kind: StreamEventKind, contextTokens: Int? = nil,
         isSystemNotice: Bool = false, fastModeState: String? = nil,
         fastModeDisabledReason: String? = nil, callSpeed: String? = nil,
         modelContextWindows: [String: Int]? = nil,
         attachedFiles: [String] = []) {
        self.kind = kind
        self.contextTokens = contextTokens
        self.isSystemNotice = isSystemNotice
        self.fastModeState = fastModeState
        self.fastModeDisabledReason = fastModeDisabledReason
        self.callSpeed = callSpeed
        self.modelContextWindows = modelContextWindows
        self.attachedFiles = attachedFiles
    }
}

enum StreamEventKind {
    case userMessage(text: String)
    case assistantText(text: String)
    case thinking(text: String)
    case toolUse(toolUseId: String, name: String, input: [String: Any])
    case toolResult(toolUseId: String, output: String, isError: Bool)
    case systemInit(sessionId: String, model: String, cwd: String)
    case result(durationMs: Int, totalCostUSD: Double?, numTurns: Int,
                inputTokens: Int, outputTokens: Int)
    case compaction(preTokens: Int?, postTokens: Int?)
    case error(message: String)
    case interrupted(message: String)
}

struct AgentInfo: Identifiable, Hashable {
    let key: String
    let name: String
    let cmd: String
    let storeDir: String
    var id: String { key }
}

/// The registry the compiled files name agents from, and a REAL binary
/// lookup (the shell's PATH plus the usual install directories) so the
/// CLI sections find the same binaries the app would.
enum AgentManager {
    nonisolated static let registry: [AgentInfo] = [
        AgentInfo(key: "claude_code", name: "Claude Code", cmd: "claude", storeDir: ".claude/projects"),
        AgentInfo(key: "codex", name: "Codex", cmd: "codex", storeDir: ".codex/sessions"),
        AgentInfo(key: "kimi", name: "Kimi Code", cmd: "kimi", storeDir: ".kimi-code/sessions"),
    ]

    nonisolated static func binaryPath(for key: String) -> String? {
        guard let agent = registry.first(where: { $0.key == key }) else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                 "\(home)/.kimi-code/bin", "\(home)/.npm-global/bin"]
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(agent.cmd)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// The child environment the compiled files build spawns with. The
/// real builder merges the app's search paths and the login shell's
/// PATH, strips `DYLD_*` and overlays the proxy variables; the harness
/// runs from a shell, so the shell's PATH is the honest stand-in, and
/// `extraEnvironment` is how a test points a CLI at a throwaway home.
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
            .appendingPathComponent("sipai-chatonly-harness")

    static var configFile: URL { dataDir.appendingPathComponent("config.json") }
    static var generalSystemPromptFile: URL {
        dataDir.appendingPathComponent("system_prompt.md")
    }
    static var chatOnlyInstructionsFile: URL {
        dataDir.appendingPathComponent("chat-only-instructions.md")
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
