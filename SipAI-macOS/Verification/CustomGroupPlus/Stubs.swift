// Stubs.swift — the minimum `AgentSessionGrouping.swift` needs to
// compile outside the app target.
//
// The REAL grouping file is compiled; only its two row types are
// faked, and each carries just the members the bucketer reads. Same
// trick as Verification/KimiCode/Stubs.swift. Nothing here is part of
// the product: this directory sits outside SipAI/ and the Xcode
// project never references it.
//
// If a stub below has to grow a behaviour, that is a signal the
// grouping rules have picked up a dependency they should not have.

import Foundation

// MARK: - From AgentSession.swift

enum AgentSessionOrigin: Hashable {
    case user
    case scheduled
    case subagent
}

struct AgentSession: Identifiable, Hashable {
    let id: String
    var title: String = ""
    var lastUserMessageAt: Date? = nil
    var modifiedAt: Date = Date()
    var projectPath: URL? = nil
    var origin: AgentSessionOrigin = .user

    var activityAt: Date { lastUserMessageAt ?? modifiedAt }
}

struct ScheduledAgentTask: Identifiable, Hashable {
    let name: String
    var description: String = ""
    var workingDirectory: URL? = nil
    var sessions: [AgentSession] = []

    var id: String { name }
    var lastActive: Date? { sessions.first?.activityAt }
}
