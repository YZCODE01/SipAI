// Stubs.swift — the minimum the REAL AgentSessionGrouping.swift and
// ConfigManager.swift need to compile outside the app target.
//
// Both files under test are compiled whole; only their neighbours are
// faked, each with just the members the two read. Same trick as
// Verification/CustomGroupPlus and Verification/ComposerModelChip.
// Nothing here is part of the product: this directory sits outside
// SipAI/ and the Xcode project never references it.
//
// `SipaiPaths` points into a throwaway directory: this harness must
// never read or write the real ~/Library/Application Support/SipAI.

import Foundation

// MARK: - From AgentSession.swift

enum AgentSessionOrigin: Hashable {
    case user
    case scheduled
    case subagent
}

struct AgentSession: Identifiable, Hashable {
    let id: String
    var title: String = ""
    var lastUserMessageAt: Date? = nil
    var modifiedAt: Date = Date()
    var projectPath: URL? = nil
    var origin: AgentSessionOrigin = .user

    var activityAt: Date { lastUserMessageAt ?? modifiedAt }
}

struct ScheduledAgentTask: Identifiable, Hashable {
    let name: String
    var description: String = ""
    var workingDirectory: URL? = nil
    var sessions: [AgentSession] = []

    var id: String { name }
    var lastActive: Date? { sessions.first?.activityAt }
}

// MARK: - What ConfigManager.swift reaches for

enum SipaiPaths {
    /// Set by main.swift before anything touches config.
    nonisolated(unsafe) static var dataDir: URL =
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sipai-sidebar-menus-harness")

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

enum AgentManager {
    nonisolated static func binaryPath(for key: String) -> String? { nil }
}

enum AgentSessionScanner {
    nonisolated static func lastLaunchOptions(of url: URL)
    -> (permissionMode: String?, model: String?, effort: String?, fastMode: Bool?) {
        (nil, nil, nil, nil)
    }

    /// `CodexCatalog` reads a rollout's head through this. The codex
    /// store below is a folder that does not exist, so no rollout is
    /// ever handed here.
    nonisolated static func head(of url: URL, count: Int) -> Data? { nil }
}

enum KimiSessionScanner {
    static var sessionRoot: URL {
        SipaiPaths.dataDir.appendingPathComponent("no-kimi-store", isDirectory: true)
    }
    static var configFile: URL {
        sessionRoot.appendingPathComponent("config.toml")
    }
    static var storeExists: Bool { false }
}

enum CodexSessionScanner {
    static var sessionRoot: URL {
        SipaiPaths.dataDir.appendingPathComponent("no-codex-store", isDirectory: true)
    }

    /// The walk over that missing store finds no file to name.
    static func rolloutStem(_ name: String) -> String? { nil }
}

enum CodexModelListRefresh {
    static func run(binary: String) async -> Bool { false }
    static func answer(binary: String) async -> [String: Any]? { nil }
}

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

extension CodexConfigRead {
    static func run(binary: String, cwd: String) async
    -> (config: [String: Any]?, requirements: [String: Any]?) { (nil, nil) }
}
