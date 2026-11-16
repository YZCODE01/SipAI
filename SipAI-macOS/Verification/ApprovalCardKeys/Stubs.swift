// Stand-ins for the app types the cards and the bridge touch, so the
// harness compiles the REAL cards, the REAL key monitor and the REAL
// MCPBridge rather than a paraphrase of them.
//
// `SipaiPaths.mcpDir` is redirected into the harness's throwaway
// directory: this harness must never bind, replace or remove the running
// app's own socket under ~/Library/Application Support/SipAI/mcp.
// `ChatDesign` lives in ChatView.swift and would drag a whole view in, so
// the colours the cards and the renderer use are stubbed here.
//
// Nothing here is part of the app target.
import SwiftUI
import AppKit

enum SipaiPaths {
    static var mcpDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CARDKEYS_HARNESS_MCP_DIR"]!,
            isDirectory: true)
    }
}

enum ChatDesign {
    static let blue = Color.blue
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let cardBg = Color.gray.opacity(0.15)
}

/// `CodexPlanFollowUpCard` takes its title from codex's rules file, which
/// leans on the whole launch-options layer, and its answers from the caller.
/// What is under test here is the card's KEYBOARD; the answers themselves
/// are pinned where the real file is compiled
/// (Verification/CodexAppServerBridge). These are in their shape: the
/// answer's id carries the mode (`PlanContinue`).
enum CodexAppServer {
    enum Words {
        static var implementPlanTitle: String { "Implement this plan?" }
    }
    static let implementAnswer = "implement"
    static var harnessFollowUpChoices: [CardChoice] {
        [CardChoice(id: PlanContinue.id(answer: implementAnswer, mode: ""),
                    label: "Yes, implement in Default", role: .accept, adoptsMode: ""),
         CardChoice(id: PlanContinue.id(answer: implementAnswer, mode: "workspace-write"),
                    label: "Yes, implement in Workspace Write", role: .other, adoptsMode: "workspace-write"),
         CardChoice(id: "stay", label: "No, stay in Plan mode", role: .decline)]
    }
}
