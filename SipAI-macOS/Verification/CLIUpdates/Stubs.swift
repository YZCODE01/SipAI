// Stand-ins for the three app types the extracted probe reaches for, so
// the REAL parsing, fingerprinting and version-reading code can run
// without a window, a config file or an agent CLI on PATH.
//
// Nothing here restates a rule under test. `binaryPath` is a lookup the
// test drives, `buildEnvironment` is a minimal PATH, and `prepare` has
// nothing to capture — the real versions of all three are exercised by
// the app, and by the structural pass in main.swift that reads them.

import Foundation

enum AgentManager {
    /// agent key → absolute path, filled in per test.
    static var binaries: [String: String] = [:]
    static func binaryPath(for key: String) -> String? { binaries[key] }
}

enum AgentRunner {
    /// The real one merges `AgentManager.searchPaths` and the login
    /// shell's PATH into the process environment, then strips `DYLD_*`
    /// and overlays the proxy variables. Only the PATH part is
    /// reproducible without the app, and it is not optional: codex's
    /// binary is a Node shim, so a PATH without `node` on it makes
    /// `codex --version` fail to run at all — which is precisely the
    /// gap the real builder exists to close for a GUI app that
    /// inherits launchd's environment. The harness runs from a shell,
    /// so the shell's own PATH is the honest stand-in.
    ///
    /// That the real builder does the other two things is checked
    /// structurally in main.swift, by reading it.
    static func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let dirs = ["/usr/bin", "/bin", "/usr/sbin", "/sbin",
                    "/usr/local/bin", "/opt/homebrew/bin"]
        let existing = env["PATH"] ?? ""
        env["PATH"] = dirs.joined(separator: ":")
            + (existing.isEmpty ? "" : ":" + existing)
        for key in env.keys where key.hasPrefix("DYLD_") { env.removeValue(forKey: key) }
        return env
    }
}

enum ShellEnvironment {
    static func prepare() async {}
}
