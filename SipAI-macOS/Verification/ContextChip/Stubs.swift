// Stand-ins for the app types the readers under test touch, so the
// harness compiles the REAL scanners and parsers rather than a
// paraphrase of them. Only the members they call exist, and each
// answers "no signal" — none of them is what this harness measures.
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

/// The runner is not compiled here; the readers only need the event
/// shapes and the one string the interrupted marker uses.
struct StreamEvent {
    let kind: StreamEventKind
    let contextTokens: Int?
    let isSystemNotice: Bool
    let fastModeState: String?
    let modelContextWindows: [String: Int]?

    init(kind: StreamEventKind, contextTokens: Int? = nil,
         isSystemNotice: Bool = false, fastModeState: String? = nil,
         modelContextWindows: [String: Int]? = nil) {
        self.kind = kind
        self.contextTokens = contextTokens
        self.isSystemNotice = isSystemNotice
        self.fastModeState = fastModeState
        self.modelContextWindows = modelContextWindows
    }
}

enum StreamEventKind {
    case userMessage(text: String)
    case assistantText(text: String)
    case toolUse(toolUseId: String, name: String, input: [String: Any])
    case toolResult(toolUseId: String, output: String, isError: Bool)
    case systemInit(sessionId: String, model: String, cwd: String)
    case result(durationMs: Int, totalCostUSD: Double?, numTurns: Int,
                inputTokens: Int, outputTokens: Int)
    case compaction(preTokens: Int?, postTokens: Int?)
    case error(message: String)
    case interrupted(message: String)
}

enum AgentRunner {
    static let interruptedByUserMessage = "Interrupted"
}

// --- App-level neighbours of ConfigManager / AgentLaunchOptions ---
//
// The window rules under test live beside the model catalogs, so those
// two files are compiled in for real. These are the types they touch
// and this harness does not measure.
//
// `SipaiPaths` is redirected into a throwaway directory: this harness
// must never read or write the real
// ~/Library/Application Support/SipAI/config.json.

enum SipaiPaths {
    nonisolated(unsafe) static var dataDir: URL =
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sipai-contextchip-harness")

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
}

enum AppTheme: String { case system, light, dark }
enum AppLanguage: String {
    case english = "en"
    static var effective: AppLanguage { .english }
    var localizationCode: String { rawValue }
}
enum FontTier: String { case compact, standard, large }
enum AgentGroupMode: String { case none, folder, task }

/// Nothing here starts a process; the binary-table pass hands its path
/// to `ClaudeModelCatalog` directly.
enum AgentManager {
    nonisolated static func binaryPath(for key: String) -> String? { nil }
}


/// The app-server refresh `CodexCatalog.refreshFromCodex` runs — a
/// process spawn, which no harness performs. `binaryPath` answers nil
/// here anyway, so the catalog never reaches it.
enum CodexModelListRefresh {
    static func run(binary: String) async -> Bool { false }
}
