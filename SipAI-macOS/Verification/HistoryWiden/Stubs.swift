// Minimal stand-ins for the app types AgentSession.swift touches
// outside the code under test, so the harness compiles the REAL
// scanner rather than a paraphrase. Only the members it calls exist,
// and both functions answer "no signal": the functions that consult
// them (`endsMidTurn`, `lastTurnDurationSeconds`, the scheduled-task
// scan) are not what this harness exercises — `readHistory` never
// touches either. `AgentLaunchOptions` is only a type a new session's
// draft carries; the harness builds no draft.
//
// Nothing here is part of the app target.
import Foundation

enum AgentSessionTailer {
    static let terminatingStopReasons: Set<String> = []
    static func progressState(forRawRecord obj: [String: Any]) -> Bool? {
        nil
    }
}

struct ScheduledTaskDefinition: Equatable {
    var name: String
    var description: String
    var workingDirectory: URL? = nil
    var agent: String = "claude_code"

    static func read(name: String, skillFile: URL) -> ScheduledTaskDefinition? {
        nil
    }
}

struct AgentLaunchOptions: Hashable {}
