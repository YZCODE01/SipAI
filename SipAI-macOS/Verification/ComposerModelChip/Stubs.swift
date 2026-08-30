// Stand-ins for the app types the two files under test happen to
// reference, so the REAL ConfigManager.swift and AgentLaunchOptions.swift
// can be compiled and exercised outside the app target.
//
// Only the shape matters here — none of these is under test. Same trick
// as Verification/ProviderCatalog/Stubs.swift, with one difference: the
// real `ClaudeModelDisplay` is compiled in (it is half of what this
// harness checks), so it is NOT faked here.
//
// `SipaiPaths` is redirected into a throwaway directory. This harness
// must never read or write the real
// ~/Library/Application Support/SipAI/config.json — the map it exercises
// is the one that decides what every model picker in the app is named.

import Foundation

enum SipaiPaths {
    /// Set by main.swift before anything touches config.
    nonisolated(unsafe) static var dataDir: URL =
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sipai-modelchip-harness")

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

/// `ClaudeCapabilities.ensureLoaded` scrapes `claude --help` through
/// this. Nothing here starts a process.
enum AgentManager {
    nonisolated static func binaryPath(for key: String) -> String? { nil }
}

/// `ClaudeModelCatalog.harvest` reads a session's newest recorded
/// launch options through this. The harvest tests here pass their ids
/// in directly, so no file is ever opened.
enum AgentSessionScanner {
    nonisolated static func lastLaunchOptions(of url: URL)
    -> (permissionMode: String?, model: String?, effort: String?) {
        (nil, nil, nil)
    }
}

/// `KimiCatalog` reads kimi's own config through this. Pointed at a
/// path that does not exist: the kimi catalog is not what this harness
/// is about, and it must not read the user's real store.
enum KimiSessionScanner {
    static var sessionRoot: URL {
        SipaiPaths.dataDir.appendingPathComponent("no-kimi-store", isDirectory: true)
    }
    static var configFile: URL {
        sessionRoot.appendingPathComponent("config.toml")
    }
    static var storeExists: Bool { false }
}

/// `CodexCatalog` walks codex's rollouts through this. Same reasoning
/// as `KimiSessionScanner` above — pointed away from the real store.
enum CodexSessionScanner {
    static var sessionRoot: URL {
        SipaiPaths.dataDir.appendingPathComponent("no-codex-store", isDirectory: true)
    }
}
