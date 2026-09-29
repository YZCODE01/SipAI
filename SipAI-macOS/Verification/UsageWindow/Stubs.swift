// Stand-ins for the app types PlanUsage.swift touches, so the harness
// compiles the REAL detector, parsers, probes and monitor rather than
// a paraphrase of them. Only the members they call exist, and none of
// them carries a rule this harness measures.
//
// `AgentCLIProbe` and `CodexAppServerCall` are NOT stubbed: run.sh
// extracts them verbatim from AgentCLIUpdates.swift, so the live
// section drives the real spawn path. `TomlScalar` is extracted the
// same way from AgentLaunchOptions.swift.
//
// Nothing here is part of the app target.
import Foundation

struct AgentInfo: Identifiable, Hashable {
    let key: String
    let name: String
    let cmd: String
    let storeDir: String
    var id: String { key }
}

enum AgentManager {
    nonisolated static let registry: [AgentInfo] = [
        AgentInfo(key: "claude_code", name: "Claude Code", cmd: "claude", storeDir: ".claude/projects"),
        AgentInfo(key: "codex", name: "Codex", cmd: "codex", storeDir: ".codex/sessions"),
        AgentInfo(key: "kimi", name: "Kimi Code", cmd: "kimi", storeDir: ".kimi-code/sessions"),
    ]

    /// The harness's own resolution: the login shell's PATH plus the
    /// usual install directories, so the live section finds the same
    /// binaries the app would.
    nonisolated static func binaryPath(for key: String) -> String? {
        guard let agent = registry.first(where: { $0.key == key }) else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.kimi-code/bin"]
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(agent.cmd)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

enum AgentRunner {
    nonisolated static func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("DYLD_") { env[key] = nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.kimi-code/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? ""]).joined(separator: ":")
        return env
    }
}

enum ShellEnvironment {
    static func prepare() async {}
}

enum KimiSessionScanner {
    static var home: URL {
        let env = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code", isDirectory: true)
    }
    static var configFile: URL { home.appendingPathComponent("config.toml") }
}
