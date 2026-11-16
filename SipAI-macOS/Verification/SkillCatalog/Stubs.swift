// Stubs.swift — what SkillCatalog.swift reaches for outside the skill
// model, for `Verification/SkillCatalog`. The model's own stand-ins are
// `Verification/KimiCode/Stubs.swift`, compiled beside this (run.sh
// steers its `AgentManager.binaryPath` to the table below).
//
// Nothing here starts a process, and nothing here is part of the app.

import Foundation

/// What the harness steers, and what the stand-ins record.
enum CatalogHarness {
    /// The agent tools "installed": none, until the harness names one.
    nonisolated(unsafe) static var binaries: [String: String] = [:]
    /// The claude version "installed": not read, until the harness says.
    nonisolated(unsafe) static var claudeVersion: CLIVersion? = nil

    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: UInt64 = 250_000_000
    nonisolated(unsafe) private static var log: [String] = []

    /// How long the stand-in app-server call holds a read in flight.
    static var hold: UInt64 {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }

    /// The folders a read asked codex about, in order.
    static var asked: [String] { lock.withLock { log } }
    static func note(_ folder: String) { lock.withLock { log.append(folder) } }
    static func forget() { lock.withLock { log = [] } }
    static func reads(of folder: URL) -> Int {
        let path = folder.path
        return asked.filter { $0 == path }.count
    }
}

struct CLIVersion: Equatable, Comparable {
    let components: [Int]
    static func parse(_ text: String) -> CLIVersion? {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        return parts.isEmpty ? nil : CLIVersion(components: parts)
    }
    static func < (a: CLIVersion, b: CLIVersion) -> Bool { a.components.lexicographicallyPrecedes(b.components) }
}

enum AgentCLIProbe {
    static let terminateGrace: TimeInterval = 1
    nonisolated static func stop(_ p: Process) { if p.isRunning { p.terminate() } }
}

/// The app-server call a read makes for codex's own listing — here a
/// record of the folder asked about and a wait, standing in for the
/// seconds a real listing takes. It answers nothing, which the catalog
/// reads as "codex did not answer": the folders' own account stands.
enum CodexAppServerCall {
    static let answerId = 2
    nonisolated static func run(binary: String, request: String) async -> [String: Any]? {
        if let object = (try? JSONSerialization.jsonObject(with: Data(request.utf8))) as? [String: Any],
           let params = object["params"] as? [String: Any],
           let folder = (params["cwds"] as? [String])?.first {
            CatalogHarness.note(folder)
        }
        try? await Task.sleep(nanoseconds: CatalogHarness.hold)
        return nil
    }
}

extension AgentManager {
    static func installedClaudeVersion() -> CLIVersion? { CatalogHarness.claudeVersion }
}
