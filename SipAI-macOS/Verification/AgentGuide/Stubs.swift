// Stand-ins for the app types the extracted rules and transports
// touch, so the harness compiles the REAL rules, parsers, sessions
// and probes rather than a paraphrase of them. Only the members they
// call exist, and none of them carries a rule this harness measures.
//
// `AgentCLIProbe`, `CodexAppServerCall`, `AgentCLIRelease`, the
// version types and `TomlScalar` are NOT stubbed: run.sh extracts them
// verbatim from the shipping files, and PlanUsage.swift is compiled
// whole. Nothing here is part of the app target.
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
    static var loginShell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }
    static func loginShellPathDirectories() -> [String] { [] }
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

// The scheduler's `decide` is extracted verbatim into this shell; the
// two windows are the shipping constants (checked by run.sh against
// the source).
struct TaskSchedule {
    let slots: [Date]
    /// A recurring stand-in; the one-time rule is pinned by
    /// `Verification/ScheduleOnce` over the real `TaskSchedule`.
    var isOneTime = false
    func previousFireDate(onOrBefore now: Date, calendar: Calendar) -> Date? {
        slots.filter { $0 <= now }.max()
    }
}
struct ScheduledTaskDefinition {
    var enabled = true
    var schedule: TaskSchedule? = nil
    var catchUpMissed = false
    /// One stand-in schedule; what counts as a CHANGE of schedule is
    /// pinned by `Verification/ScheduleOnce` over the real definition.
    var scheduleInForce: String { enabled && schedule != nil ? "stand-in" : "" }
}
struct ScheduledTaskRunState {
    var lastSlot: Date? = nil
    var scheduleInForce: String? = nil
}
