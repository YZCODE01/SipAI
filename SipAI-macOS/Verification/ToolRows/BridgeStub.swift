// BridgeStub.swift — what the renderer needs beside the readers.
//
// `AgentRendering.swift` names the question tool by the bridge's constant;
// the bridge itself needs the app. Section 5 reads the real constant, so
// this one cannot drift from it unnoticed.

enum MCPBridge {
    static let questionTool = "AskUserQuestion"
}
