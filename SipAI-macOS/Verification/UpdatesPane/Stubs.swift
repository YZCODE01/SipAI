// Stubs.swift — stand-ins for the app types Settings → Updates reads, so
// the REAL pane compiles outside the app target. What is under test is
// compiled whole (DesignSystem.swift, UpdaterAvailability.swift) or
// EXTRACTED by text by run.sh (the pane itself, from SettingsView.swift)
// — never copied here.
//
// Each stub carries only what the pane reads, as plain settable values:
// main.swift puts them in the state a release copy and a locally built
// copy are in. The command-line tool rows are the Updates harnesses'
// business (`Verification/CLIUpdates`); here the list is empty and the
// row a placeholder.
//
// Nothing in this directory is part of the app target.

import SwiftUI
import Combine

/// `UpdateController`'s published surface, as the pane reads it.
@MainActor
final class UpdateController: ObservableObject {
    struct AvailableUpdate: Equatable {
        let version: String
        let display: String
    }

    var availability: UpdaterAvailability.Verdict = .enabled
    @Published var canCheckForUpdates = false
    @Published var lastUpdateCheckDate: Date?
    @Published var automaticallyChecksForUpdates = false
    @Published var availableUpdate: AvailableUpdate?
    @Published var heldUpdateVersion: String?

    var isWaitingForQuietMoment: Bool { heldUpdateVersion != nil }
    var currentVersion = "1.0.4"
    var currentBuild = "5"

    private(set) var checks = 0
    func checkForUpdates() { checks += 1 }
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) { automaticallyChecksForUpdates = enabled }
    func installNow() {}
}

final class ConfigManager: ObservableObject {}
final class AgentManager: ObservableObject {}

struct AgentInfo: Identifiable, Hashable {
    let key: String
    let name: String
    var id: String { key }
}

@MainActor
final class AgentCLIUpdateMonitor: ObservableObject {
    static let shared = AgentCLIUpdateMonitor()
    @Published var installedAgents: [AgentInfo] = []
    @Published var hiddenAgents: Set<String> = []
    @Published var remoteChecksEnabled = true
    @Published var autoUpdateEnabled = false
    func setRemoteChecksEnabled(_ on: Bool) { remoteChecksEnabled = on }
    func setAutoUpdateEnabled(_ on: Bool) { autoUpdateEnabled = on }
    func paneAppeared() {}
}

@MainActor
final class UpdateBadge: ObservableObject {
    static let shared = UpdateBadge()
    @Published private(set) var items: [String] = []
    func markSeen() {}
}

/// Never drawn: the tool list is empty in every render.
struct CLIUpdateRow: View {
    let agent: AgentInfo
    var body: some View { Text(verbatim: agent.name) }
}
