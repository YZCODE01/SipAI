// Stand-ins for the app types the update monitor reaches for, so the
// REAL monitor — its rows, its re-stat, its finish and its announcement
// — runs without a window, a config file or a real agent CLI.
//
// Nothing here restates a rule under test. Detection is the app's own
// test (an executable file where the tool should be), pointed at a temp
// folder; the relearn hooks only count their calls; the release
// endpoint is served in-process.

import Combine
import Foundation

struct AgentInfo: Equatable, Identifiable {
    let key: String
    let name: String
    let cmd: String
    let storeDir: String
    var id: String { key }
}

@MainActor
final class AgentManager: ObservableObject {
    nonisolated static let registry: [AgentInfo] = [
        AgentInfo(key: "claude_code", name: "Claude Code", cmd: "claude", storeDir: ""),
        AgentInfo(key: "codex", name: "Codex", cmd: "codex", storeDir: ""),
        AgentInfo(key: "kimi", name: "Kimi Code", cmd: "kimi", storeDir: ""),
    ]

    /// The one folder the harness installs its tools into.
    nonisolated(unsafe) static var binDir = ""

    /// The app's test, over the harness's folder: an executable file
    /// named after the tool. npm retiring the link is what makes this
    /// answer nil mid-update.
    nonisolated static func binaryPath(for key: String) -> String? {
        guard let agent = registry.first(where: { $0.key == key }) else { return nil }
        let full = binDir + "/" + agent.cmd
        return FileManager.default.isExecutableFile(atPath: full) ? full : nil
    }

    @Published var inFlightSends: Set<String> = []
    @Published var externalInFlightSessions: Set<String> = []
    func hasTurnInFlight(agentKey: String) -> Bool { false }
}

@MainActor
final class ConfigManager {
    func agentLabel(for key: String, defaultName: String) -> String { defaultName }
}

@MainActor
final class UsageMonitor {
    static let shared = UsageMonitor()
    func noteBinaryChanged(agentKey: String) {}
}

@MainActor
final class ClaudeCapabilities {
    static let shared = ClaudeCapabilities()
    private(set) var reloads = 0
    func reloadAfterBinaryChange() { reloads += 1 }
}

@MainActor
enum ClaudeModelCatalog {
    static func forgetHarvest() {}
    static func refreshObservedNames(config: ConfigManager, sessionURLs: [URL]) {}
}

/// Counts the relearns: one per update that landed, none for a binary
/// that is merely missing mid-update.
@MainActor
final class CodexCatalog {
    static let shared = CodexCatalog()
    private(set) var reloads = 0
    func reloadAfterBinaryChange() { reloads += 1 }
}

struct AgentInstallSource {
    var isOwnedBySipAI: Bool { false }
    /// The real rule names Homebrew for claude's casks and kimi's
    /// formula (`Verification/AgentGuide` pins it); the tools this
    /// harness installs are its own files, managed by nobody.
    func managedBy(agentKey: String) -> String? { nil }
    static func current(agentKey: String) -> AgentInstallSource? { nil }
}

/// Claude's channel is read from these files (`AgentCLIRelease
/// .claudeChannel`); none here, so the check reads npm's `latest` —
/// the path the in-process registry below answers.
enum PlanAccountDetector {
    nonisolated static var claudeSettingsFiles: [URL] { [] }
}

@MainActor
final class AgentGuideActions {
    static let shared = AgentGuideActions()
    @discardableResult
    func updateOwnedCodex(latest: CLIVersion) -> Bool { false }
}

enum KimiSessionScanner {
    static var home: URL { URL(fileURLWithPath: "/nonexistent-kimi-home") }
}

enum AgentRunner {
    static func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        for key in env.keys where key.hasPrefix("DYLD_") { env.removeValue(forKey: key) }
        return env
    }
}

enum ShellEnvironment {
    static func prepare() async {}
}

/// Answers the npm registry's `/latest` in-process, so the release check
/// that raises the row's Update button needs no network. Each package
/// answers its own version, keyed on the path the release table asks.
final class FakeRegistry: URLProtocol {
    nonisolated(unsafe) static var latest: [String: String] = [
        "/@openai/codex/": "0.157.1",
        "/@anthropic-ai/claude-code/": "2.1.283",
    ]
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "registry.npmjs.org"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let version = Self.latest.first { path.contains($0.key) }?.value ?? "0.0.0"
        let body = Data("{\"version\":\"\(version)\"}".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
