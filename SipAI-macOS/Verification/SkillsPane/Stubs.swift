// Stubs.swift — stand-ins for the app types the Skills pane, its sheets
// and the chip's popover reference, so the REAL view files compile
// outside the app target. Each carries only what those files read; the
// catalog stub holds a fixture snapshot and records the writes asked of
// it (the real catalog's logic is `Verification/Skills`').
//
// Nothing in this directory is part of the app target.

import SwiftUI
import Combine

struct DisplaySettings { var spellCheck = true }

@MainActor
final class ConfigManager: ObservableObject {
    @Published var display = DisplaySettings()
    var preloads: [String: [String]] = [:]
    func agentLabel(for key: String, defaultName: String) -> String { defaultName }
    func agentSkillPreloads(for agent: String) -> [String] { preloads[agent] ?? [] }
    func setAgentSkillPreload(_ name: String, on: Bool, for agent: String) {
        var list = preloads[agent] ?? []
        if on { if !list.contains(name) { list.append(name) } } else { list.removeAll { $0 == name } }
        preloads[agent] = list
        objectWillChange.send()
    }
}

enum AgentPresence: Equatable { case listed, hiddenByUser, notSignedIn, notInstalled, pending }

struct AgentInfo: Identifiable {
    let key: String
    let name: String
    var id: String { key }
}

struct AgentSession: Identifiable {
    let id: String
    var projectPath: URL?
    var activityAt: Date
}

@MainActor
final class AgentManager: ObservableObject {
    static let registry = [AgentInfo(key: "claude_code", name: "Claude Code"),
                           AgentInfo(key: "codex", name: "Codex"),
                           AgentInfo(key: "kimi", name: "Kimi Code")]
    var listed: Set<String> = ["claude_code", "codex", "kimi"]
    @Published var sessions: [AgentSession] = []
    func presence(for key: String) -> AgentPresence { listed.contains(key) ? .listed : .notInstalled }
}

@MainActor
final class AppState: ObservableObject {
    @Published var skillsFolder: URL? = nil
    var skillsFolderChosen = false
    @Published var skillGroupsToggled: Set<String> = []
    var openAgentSessionId: String? = nil
    @Published var settingsSection: String? = nil
    func openSettings(_ section: Any) {}
}

@MainActor
final class SidebarNotices {
    static let shared = SidebarNotices()
    func setSheetPresented(_ up: Bool) {}
}

@MainActor
final class SkillCatalog: ObservableObject {
    static let shared = SkillCatalog()
    @Published var snapshots: [String: SkillSnapshot] = [:]
    @Published var loading: Set<String> = []
    @Published var revision = 0
    /// The subfolders with skills, by the folder they are below — the
    /// fixture's, where the real catalog's walk would put them.
    @Published var subfolders: [String: SkillSubfolders] = [:]
    @Published var waiting: Set<String> = []
    /// What was asked of the catalog, with the folder each ask was for
    /// ("in <its last component>", "in -" for none).
    var calls: [String] = []
    /// The subfolders the page asked to have read, one list an ask — an
    /// empty one lets go of what was waiting.
    var subfoldersAsked: [[String]] = []
    /// The folders the page asked to have looked below.
    var walksAsked: [String] = []

    static func key(_ folder: URL?) -> String { folder?.standardizedFileURL.path ?? "" }
    func snapshot(folder: URL?) -> SkillSnapshot? { snapshots[Self.key(folder)] }
    func subfolders(of folder: URL?) -> SkillSubfolders? { folder.flatMap { subfolders[Self.key($0)] } }
    func findSubfolders(of folder: URL) { walksAsked.append(folder.path) }
    func ensureLoaded(folder: URL?, maxAge: TimeInterval = 60) {}
    func ensureLoaded(folders: [URL], maxAge: TimeInterval = 60) { subfoldersAsked.append(folders.map(\.path)) }
    func refresh(folder: URL?) async { calls.append("refresh in \(Self.place(folder))") }
    static func place(_ folder: URL?) -> String { folder?.lastPathComponent ?? "-" }
    func reviewShare(row: SkillRow, with agent: String, folder: URL?) async -> SkillShareReview? {
        calls.append("review share \(row.name) \(agent) in \(Self.place(folder))")
        return SkillShareReview(plan: SkillSharePlan(), check: SkillShareCheck())
    }
    func reviewFix(row: SkillRow, for agent: String, folder: URL?) async -> SkillShareCheck? {
        calls.append("review fix \(row.name) \(agent) in \(Self.place(folder))"); return SkillShareCheck()
    }
    func reviewRemove(row: SkillRow, from agent: String, folder: URL?) async -> SkillSharePlan? {
        calls.append("review remove \(row.name) \(agent) in \(Self.place(folder))"); return SkillSharePlan()
    }
    func share(row: SkillRow, with agent: String, check: SkillShareCheck, folder: URL?) async -> String? {
        calls.append("share \(row.name) \(agent)"); return nil
    }
    func remove(row: SkillRow, from agent: String, folder: URL?) async -> String? {
        calls.append("remove \(row.name) \(agent)"); return nil
    }
    func fix(row: SkillRow, check: SkillShareCheck, folder: URL?) async -> String? {
        calls.append("fix \(row.name)"); return nil
    }
    func setState(row: SkillRow, agent: String, state: SkillState, folder: URL?, label: String) async -> String? {
        calls.append("state \(row.name) \(agent) \(state)"); return nil
    }
    func delete(row: SkillRow, folder: URL?) async -> String? { calls.append("delete \(row.name)"); return nil }
    func create(name: String, description: String, body: String, onlyWhenCalled: Bool,
                scope: SkillScope, agents: [String], folder: URL?) async -> String? { nil }
    func edit(row: SkillRow, expected: String, description: String, body: String,
              onlyWhenCalled: Bool?, folder: URL?) async -> String? { nil }
    func refusal(of plan: SkillSharePlan, folder: URL?) async -> String? { nil }
    func importFolder(_ source: URL, name: String, scope: SkillScope, agents: [String],
                      folder: URL?) async -> String? { nil }
    nonisolated static func describe(_ error: SkillOpError) -> String { error.sentence }
    nonisolated static func switchRefusal(row: SkillRow, agent: String, label: String) -> String? {
        SkillSwitchRule.refusal(row: row, agent: agent, label: label)
    }
}
