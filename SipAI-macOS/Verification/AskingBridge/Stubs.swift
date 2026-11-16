// Stand-ins for the app types MCPBridge.swift touches, so the harness
// compiles the REAL bridge rather than a paraphrase of it.
//
// `SipaiPaths.mcpDir` is redirected into the harness's throwaway
// directory: this harness must never bind, replace or remove the running
// app's own socket under ~/Library/Application Support/SipAI/mcp.
//
// Nothing here is part of the app target.
import Foundation

enum SipaiPaths {
    static var mcpDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ASKING_HARNESS_MCP_DIR"]!,
            isDirectory: true)
    }
}
