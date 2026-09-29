// Stubs.swift — the one app type the extracted task code and the REAL
// grouping file read, so both compile outside the app target.
//
// It carries only the members the task row, its scanner and the
// bucketer read. Nothing here is part of the product: this directory
// sits outside SipAI/ and the Xcode project never names it.

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
    var scheduledTaskName: String? = nil
    var agentKey: String = "claude_code"

    var activityAt: Date { lastUserMessageAt ?? modifiedAt }
}
