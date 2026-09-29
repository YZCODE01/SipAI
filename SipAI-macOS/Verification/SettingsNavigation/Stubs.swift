// Stubs.swift — stand-ins for the app types SettingsNavigation.swift and
// the Settings page reference, so the REAL files compile outside the app
// target. What is under test is compiled whole (SettingsNavigation.swift,
// SettingsPageLayout.swift, DesignSystem.swift) or EXTRACTED by text by
// run.sh (AppState's settings members, the section enum, the page's
// body, the prompt pane and its buttons, the download badge's glyph) —
// never copied here.
//
// Each stub carries only what those files read. The managers are empty:
// the factory reset they are handed to is itself a stub that records its
// calls, because the real wipe is `Verification/FactoryReset`'s.
//
// Nothing in this directory is part of the app target.

import SwiftUI
import Combine

/// `RoleConfig` as ConfigManager.swift declares it — the shape the real
/// `PromptAndRolesPane` (extracted by run.sh) builds and reads.
struct RoleConfig: Identifiable, Hashable {
    var name: String
    var prompt: String
    var id: String { name }
}

/// What the prompt pane reads and writes, and nothing else: one starter
/// role with a prompt of the starter's length, an empty system prompt.
final class ConfigManager: ObservableObject {
    @Published private(set) var roles: [RoleConfig] = [
        RoleConfig(name: "Code Reviewer",
                   prompt: String(repeating: "A role's prompt runs a few sentences long. ", count: 8))
    ]
    private var generalPrompt = ""
    func loadGeneralSystemPrompt() -> String { generalPrompt }
    func saveGeneralSystemPrompt(_ text: String) { generalPrompt = text }
    func setRoles(_ list: [RoleConfig]) { roles = list }
}
final class ProjectManager: ObservableObject {}
final class ChatManager: ObservableObject {}
final class NotesManager: ObservableObject {}
final class AgentManager: ObservableObject {}
final class ScheduledTaskScheduler: ObservableObject {}

@MainActor
enum FactoryReset {
    static var calls = 0
    static var result: [String] = []

    static func perform(config: ConfigManager,
                        projects: ProjectManager,
                        chats: ChatManager,
                        notes: NotesManager?,
                        agents: AgentManager?,
                        scheduler: ScheduledTaskScheduler?,
                        appState: AppState) -> [String] {
        calls += 1
        return result
    }
}

/// The download badge's model: the glyph (extracted from LeftSidebar.swift)
/// reads `isOwed` and nothing else.
@MainActor
final class UpdateBadge: ObservableObject {
    static let shared = UpdateBadge()
    @Published var isOwed = false
}
