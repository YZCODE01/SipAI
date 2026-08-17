// Stand-ins for the app types ConfigManager references, so the REAL
// ConfigManager.swift and ProviderCatalog.swift can be compiled and
// exercised outside the app target.
//
// Only the shape matters here — none of these is under test. The two
// files that ARE under test are compiled verbatim from SipAI/Models/.
//
// `SipaiPaths` is redirected into a throwaway directory: this harness
// must never read or write the real
// ~/Library/Application Support/SipAI/config.json.

import Foundation

enum SipaiPaths {
    /// Set by main.swift before anything touches config.
    nonisolated(unsafe) static var dataDir: URL =
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sipai-provider-harness")

    static var configFile: URL { dataDir.appendingPathComponent("config.json") }
    static var generalSystemPromptFile: URL { dataDir.appendingPathComponent("system_prompt.md") }

    static func ensureDataDir() {
        try? FileManager.default.createDirectory(at: dataDir,
                                                 withIntermediateDirectories: true)
    }
}

enum ShellEnvironment {
    /// The harness never wants a real shell export to decide a test.
    static func resolve(_ name: String) -> String? { nil }
}

enum AppTheme: String { case system, light, dark }
enum AppLanguage: String {
    case english = "en"
    static var effective: AppLanguage { .english }
    var localizationCode: String { rawValue }
}
enum FontTier: String { case compact, standard, large }
enum AgentGroupMode: String { case none, folder, task }

struct AgentLaunchOptions: Equatable {
    var permissionMode: String? = nil
    var model: String? = nil
    var effort: String? = nil
    var modelFullId: String? = nil
}

enum ClaudeModelDisplay {
    static func name(for id: String) -> String { id }
    static func splitVariant(_ id: String) -> (base: String, variant: String) {
        (id, "")
    }
    static func isNewer(_ a: String, than b: String) -> Bool { false }
}
