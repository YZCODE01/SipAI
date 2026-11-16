// Stubs.swift — the minimum the three readers need to compile outside
// the app target.
//
// Same trick as Verification/KimiCode/Stubs.swift, minus the live event
// type: `StreamEvent` / `StreamEventKind` are EXTRACTED from
// AgentRunner.swift by run.sh, so the live buffer this harness models is
// the shipping one. Nothing here is part of the product — this directory
// sits outside SipAI/ and the Xcode project never references it.
//
// If a stub below has to grow a behaviour, that is a signal the code
// under test has picked up a dependency it should not have.

import Foundation

// MARK: - From ScheduledTaskDefinition.swift

/// `ScheduledAgentTaskScanner` (in AgentSession.swift) parses task folders
/// through this. The readers never touch it.
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

/// The catalogs ask for a CLI's path through this. Nil: nothing here
/// starts a process.
enum AgentManager {
    nonisolated static func binaryPath(for key: String) -> String? { nil }
}

/// `ClaudeModelCatalog` writes learned alias→id mappings through the real
/// ConfigManager. In-memory here: the catalogs only have to link.
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

/// No login shell here.
enum ShellEnvironment {
    static func resolveIfCaptured(_ name: String) -> String? { nil }
}

/// The codex catalog's process spawns — unreachable, since `binaryPath`
/// answers nil.
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
