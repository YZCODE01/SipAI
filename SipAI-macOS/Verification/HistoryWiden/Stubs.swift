// Minimal stand-ins for the two app types AgentSession.swift touches
// outside the code under test, so the harness compiles the REAL
// scanner rather than a paraphrase. Only the members it calls exist,
// and both answer "no signal": the functions that consult them
// (`endsMidTurn`, `lastTurnDurationSeconds`, the scheduled-task scan)
// are not what this harness exercises — `readHistory` never touches
// either.
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
