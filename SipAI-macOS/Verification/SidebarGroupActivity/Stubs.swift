// Stubs.swift — the two row types `AgentSessionGrouping.swift` reads,
// so the REAL grouping file compiles outside the app target.
//
// Each stub carries only the members the bucketer and the order rule
// read; the same pair `CustomGroupPlus` stubs. If one of these has to
// grow a behaviour, the grouping rules have picked up a dependency
// they should not have. Nothing here is part of the product: this
// directory sits outside SipAI/ and the Xcode project never names it.

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
