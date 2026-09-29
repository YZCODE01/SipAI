// Stubs.swift — the minimum the kimi readers need to compile outside
// the app target.
//
// Same trick as Verification/AgentSessionFork/Stubs.swift: the REAL
// KimiSessions.swift / KimiEventParsing.swift / AgentSession.swift are
// compiled, and only their few app-level neighbours are faked. Nothing
// here is part of the product — this directory sits outside SipAI/ and
// the Xcode project never references it.
//
// If a stub below has to grow a behaviour, that is a signal the reader
// under test has picked up a dependency it should not have.

import Foundation

// MARK: - From AgentRunner.swift

/// The runner's live event type. `KimiEventParser` builds these.
struct StreamEvent: Identifiable {
    let id: UUID
    let timestamp: Date
    let kind: StreamEventKind
    let contextTokens: Int?
    var isSystemNotice: Bool = false
    /// The real one carries claude's `fast_mode_state` and the reason
    /// beside it on every init/result event, and each main-loop call's
    /// `usage.speed` — the parser passes all three, so the stub must
    /// take them.
    var fastModeState: String? = nil
    var fastModeDisabledReason: String? = nil
    var callSpeed: String? = nil
    /// Likewise claude's own per-model context windows, which its
    /// `result` event carries.
    var modelContextWindows: [String: Int]? = nil
    /// And the tailer hands a codex or kimi user row's attachment names
    /// through; the Chat only flag rides the same initializer.
    var attachedFiles: [String] = []
    var chatOnlyTurn: Bool = false

    init(kind: StreamEventKind, contextTokens: Int? = nil,
         isSystemNotice: Bool = false, fastModeState: String? = nil,
         fastModeDisabledReason: String? = nil, callSpeed: String? = nil,
         modelContextWindows: [String: Int]? = nil,
         attachedFiles: [String] = [],
         chatOnlyTurn: Bool = false) {
        self.attachedFiles = attachedFiles
        self.chatOnlyTurn = chatOnlyTurn
        self.isSystemNotice = isSystemNotice
        self.fastModeState = fastModeState
        self.fastModeDisabledReason = fastModeDisabledReason
        self.callSpeed = callSpeed
        self.modelContextWindows = modelContextWindows
        self.id = UUID()
        self.timestamp = Date()
        self.kind = kind
        self.contextTokens = contextTokens
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
    case error(message: String)
    case interrupted(message: String)
    case compaction(preTokens: Int?, postTokens: Int?)
}

// MARK: - From ScheduledTaskDefinition.swift

/// `ScheduledAgentTaskScanner` (in AgentSession.swift) parses task
/// folders through this. The kimi readers never touch it; it exists
/// only so AgentSession.swift compiles.
struct ScheduledTaskDefinition: Equatable {
    var name: String = ""
    var description: String = ""
    var scheduleExpression: String = ""
    var workingDirectory: URL?
    var mode: String?
    var model: String?
    var effort: String?
    var agent: String = "claude_code"
    var enabled: Bool = true
    var catchUpMissed: Bool = true
    var prompt: String = ""

    static func read(name: String, skillFile: URL) -> ScheduledTaskDefinition? {
        nil
    }
}

// MARK: - App services the catalogs reach for

/// `ClaudeCapabilities.ensureLoaded` scrapes `claude --help` through
/// this. The harness never calls it — nothing here starts a process.
enum AgentManager {
    nonisolated static func binaryPath(for key: String) -> String? { nil }
}

/// `ClaudeModelCatalog` writes learned alias→id mappings through the
/// real ConfigManager. In-memory here: the harness exercises the kimi
/// readers, and the claude catalog only has to link.
@MainActor
final class ConfigManager {
    private var fullIds: [String: String] = [:]
    private var observed: [String] = []
    func learnAgentModelFullIds(_ found: [String: String]) {
        for (k, v) in found { fullIds[k] = v }
    }
    func agentModelFullId(forAlias alias: String) -> String? { fullIds[alias] }
    func setAgentModelFullId(_ id: String, forAlias alias: String) {
        fullIds[alias] = id
    }
    func agentModelObservedIds() -> [String] { observed }
    func learnAgentModelObservedIds(_ ids: [String]) {
        for id in ids where !observed.contains(id) { observed.append(id) }
    }
}

/// `ClaudeModelCatalog.configuredDefaultModel` asks the login shell's
/// capture for `ANTHROPIC_MODEL` through this. No shell here.
enum ShellEnvironment {
    static func resolveIfCaptured(_ name: String) -> String? { nil }
}


/// The app-server refresh `CodexCatalog.refreshFromCodex` runs — a
/// process spawn, which no harness performs. `binaryPath` answers nil
/// here anyway, so the catalog never reaches it.
enum CodexModelListRefresh {
    static func run(binary: String) async -> Bool { false }
    static func answer(binary: String) async -> [String: Any]? { nil }
}

/// The config write `CodexCatalog.setContextWindow` runs — also a
/// process spawn, also unreachable here since `binaryPath` is nil.
enum CodexConfigWrite {
    enum Outcome: Equatable {
        case written(version: String?, filePath: String?, overriddenBy: String?)
        case refused(code: String?, message: String)
        case unavailable
    }
    static func run(binary: String, keyPath: String, value: Int?) async -> Outcome {
        .unavailable
    }
}

/// The folder read `CodexCatalog.refreshSpeedSettings` sends — a spawn
/// as well, and unreachable for the same reason. The request builder
/// and the answer's parse are the real ones, in AgentLaunchOptions.swift.
extension CodexConfigRead {
    static func run(binary: String, cwd: String) async -> [String: Any]? { nil }
}
