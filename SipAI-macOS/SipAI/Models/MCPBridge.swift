// MCPBridge.swift
// Runs a Unix-domain socket listener that the MCP "approver" server
// (approver.py, spawned by Claude Code on demand) connects to whenever
// Claude wants to use a tool that requires user approval.
//
// Lifecycle: lazy — ensureRuntime() is called from AgentRunner.runOnce
// right before spawning `claude -p …`. On first call it:
//   1. Writes the bundled approver.py to ~/Library/Application Support/
//      SipAI/mcp/approver.py (and config.json pointing at it).
//   2. Binds the UDS listener at
//      ~/Library/Application Support/SipAI/mcp/approver.sock
//      and spawns the accept loop on a background queue.
//
// All state mutations touching @Published (pending[], alias[]) hop to
// MainActor via DispatchQueue.main.async before writing, since the
// listener/handler threads are off-main.
//
// "Allow Always" / "Deny Always" write a per-scope
// cache[(toolName, signature)] → allow/deny that is consulted before a
// new request ever reaches the UI (`lookupCache`), so a remembered
// decision answers immediately without a card.

import Foundation
import AppKit
import UserNotifications

// MARK: - Verdict + ApprovalRequest

/// Terminal verdict the UI returns for a pending approval.
/// `allowAlways` / `denyAlways` are collapsed to `allow` / `deny` on
/// the wire — the always-variants additionally write the cache, but
/// the verdict Claude Code sees is always plain allow/deny.
enum MCPVerdict: String {
    case allow
    case deny
    case allowAlways = "allow_always"
    case denyAlways = "deny_always"

    var wireVerdict: String {
        switch self {
        case .allow, .allowAlways: return "allow"
        case .deny, .denyAlways: return "deny"
        }
    }
}

/// One in-flight approval awaiting the user's click. Reference type —
/// the socket-handler thread creates it, hands it to the bridge which
/// posts it on MainActor, and then blocks on `semaphore` until the UI
/// calls `resolve(requestId:verdict:)`. The verdict + semaphore fields
/// are internal so the handler thread can read them after signalling.
final class MCPApprovalRequest: Identifiable, @unchecked Sendable {
    let id: String                // request_id from the wire
    let sessionId: String?        // from SIPAI_SESSION_ID env when it's a dashed UUID
    let taskUuid: String?         // from SIPAI_SESSION_ID env when it's 32 hex chars
    let toolName: String
    let toolInput: [String: Any]

    /// Signalled by `resolve(...)` once the user clicks a button (or
    /// on shutdown, which forces a deny). The handler thread waits on
    /// this before writing the JSON response back over the socket.
    fileprivate let semaphore = DispatchSemaphore(value: 0)

    /// Written by `resolve(...)` on MainActor under `_stateLock`, read
    /// by the handler thread after `semaphore.wait()`. Default deny
    /// covers the "listener shutdown before resolution" case.
    fileprivate var verdict: MCPVerdict = .deny

    init(id: String, sessionId: String?, taskUuid: String?,
         toolName: String, toolInput: [String: Any]) {
        self.id = id
        self.sessionId = sessionId
        self.taskUuid = taskUuid
        self.toolName = toolName
        self.toolInput = toolInput
    }

    /// Best-effort single-line preview of the tool input for card display.
    var inputPreview: String {
        MCPBridge.previewInput(toolName: toolName, input: toolInput)
    }
}

// MARK: - Cache types

/// Terminal cached verdict. Narrower than `MCPVerdict` because the
/// cache never stores "always" — those are UI intents collapsed to a
/// plain allow/deny when written.
enum MCPCacheVerdict: String {
    case allow
    case deny
}

/// Composite cache key: a tool name plus the normalized signature of
/// its input. Hashable via synthesized conformance.
struct MCPCacheKey: Hashable {
    let toolName: String
    let signature: String
}

// MARK: - MCPBridge

@MainActor
final class MCPBridge: ObservableObject {

    /// All currently-unresolved approvals. Views filter to the ones
    /// matching their session and render them as inline cards.
    @Published private(set) var pending: [MCPApprovalRequest] = []

    /// task_uuid → session_id mapping, populated by AgentRunner once
    /// a system.init event reveals the real session id. Consumed by
    /// the cache-merge path in `registerAlias` and by `scopeKey` /
    /// `lookupCache` when resolving approval scope.
    @Published private(set) var alias: [String: String] = [:]

    /// Persistent-for-the-session cache of "always"-decisions.
    /// Outer key is a scope (session_id if known, else task_uuid).
    /// Inner key is (toolName, normalized signature).
    /// Value is the verdict to replay on future requests matching the
    /// key. In-memory only — cleared on app restart.
    @Published private(set) var cache: [String: [MCPCacheKey: MCPCacheVerdict]] = [:]

    /// Set by `SipAIApp.onAppear` to a closure that answers "is this
    /// approval's session currently in the foreground?" The bridge
    /// uses this to decide whether to fire a macOS notification — if
    /// the user is already looking at the session, the inline card
    /// alone is enough.
    /// Returns true when NSApp is active AND the visible session
    /// matches the approval's session_id (or task_uuid via draft).
    /// nil defaults to false (always notify) so the bridge remains
    /// useful before the hook is wired.
    var isApprovalFocused: ((MCPApprovalRequest) -> Bool)?

    // MARK: Paths (computed once at init)

    private let mcpDir: URL
    private let approverPath: URL
    private let configPath: URL
    private let socketPath: URL

    // MARK: Listener state

    private var listenerStarted = false
    private var listenerSocket: Int32 = -1
    private var shuttingDown = false

    /// Canonical MCP server name / tool name, must match the approver.py
    /// constants and the `--permission-prompt-tool mcp__<server>__<tool>`
    /// argument format Claude Code expects.
    private static let serverName = "sipai"
    private static let toolName = "approve"
    static var permissionPromptToolName: String {
        "mcp__\(serverName)__\(toolName)"
    }

    /// Built-in tools that exist to run interactive UI inside Claude
    /// Code's OWN terminal front-end, and therefore cannot work here.
    /// Resolved without an approval card — see `handleConnection`.
    ///
    /// Deliberately a minimal set: auto-denying a tool the user might
    /// legitimately want is worse than showing a card.
    nonisolated static let nonInteractiveTools: Set<String> = [
        "AskUserQuestion",
    ]

    // MARK: Init

    init() {
        self.mcpDir = SipaiPaths.mcpDir
        self.approverPath = mcpDir.appendingPathComponent("approver.py")
        self.configPath = mcpDir.appendingPathComponent("config.json")
        self.socketPath = mcpDir.appendingPathComponent("approver.sock")
    }

    // MARK: - Lifecycle

    /// Idempotent — safe to call from every `AgentRunner.runOnce`. On
    /// the first call it writes the runtime files and binds the UDS
    /// listener. Subsequent calls early-out.
    func ensureRuntime() throws {
        try FileManager.default.createDirectory(at: mcpDir,
                                                withIntermediateDirectories: true)
        try installApproverFile()
        try writeConfigFile()
        if !listenerStarted {
            try unlinkStaleSocket()
            try startListener()
            listenerStarted = true
        }
    }

    /// Force-denies every outstanding request and closes the listener.
    /// Called on app quit from `SipAIApp` so pending handler threads
    /// wake up cleanly instead of hanging on the semaphore.
    func shutdown() {
        shuttingDown = true
        // Release each pending semaphore; handler threads will see
        // the default `.deny` verdict.
        for req in pending { req.semaphore.signal() }
        pending.removeAll()
        // Close listener socket; accept loop exits.
        if listenerSocket >= 0 {
            _ = Darwin.close(listenerSocket)
            listenerSocket = -1
        }
        // Remove stale socket file.
        try? FileManager.default.removeItem(at: socketPath)
    }

    // MARK: - Runtime installation

    private func installApproverFile() throws {
        let fm = FileManager.default
        guard let src = Bundle.main.url(forResource: "approver",
                                        withExtension: "py"),
              let fresh = try? Data(contentsOf: src) else {
            // The bundle can be unreadable while a rebuild replaces the
            // app on disk under a running instance. A copy installed by
            // an earlier launch is still valid — keep serving it rather
            // than failing every send until the app is relaunched.
            if fm.fileExists(atPath: approverPath.path) { return }
            throw MCPBridgeError.approverResourceMissing
        }
        // Byte-identical means nothing to do — and rewriting only on
        // change, atomically, means there is never a moment with no
        // approver on disk for a claude that is starting up.
        if let existing = try? Data(contentsOf: approverPath),
           existing == fresh {
            return
        }
        try fresh.write(to: approverPath, options: .atomic)
        // Make the script executable — not strictly required since
        // claude invokes `python3 approver.py` via the config's
        // `command`/`args`.
        try? fm.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: approverPath.path)
    }

    private func writeConfigFile() throws {
        // `command` is `/usr/bin/env python3` rather than a specific
        // interpreter path so the user's chosen Python 3 wins (a
        // developer with multiple Pythons installed might have
        // /opt/homebrew/bin/python3 ahead of /usr/bin/python3).
        let config: [String: Any] = [
            "mcpServers": [
                Self.serverName: [
                    "type": "stdio",
                    "command": "/usr/bin/env",
                    "args": ["python3", approverPath.path],
                    "env": [
                        "SIPAI_APPROVER_SOCKET": socketPath.path,
                    ],
                ]
            ]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: configPath, options: .atomic)
    }

    private func unlinkStaleSocket() throws {
        if FileManager.default.fileExists(atPath: socketPath.path) {
            try FileManager.default.removeItem(at: socketPath)
        }
    }

    // MARK: - Listener

    private func startListener() throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw MCPBridgeError.socketCreateFailed(errno)
        }
        // Build sockaddr_un.
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.path.utf8CString
        // sockaddr_un.sun_path is 104 bytes on macOS; refuse if we'd overflow.
        // Capture the size into a local so the withUnsafeMutablePointer
        // closure below doesn't re-access `addr.sun_path` while the
        // exclusive borrow is live (Swift's exclusivity rule).
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        if pathBytes.count > sunPathSize {
            _ = Darwin.close(fd)
            throw MCPBridgeError.socketPathTooLong(socketPath.path)
        }
        // Copy the path bytes into sun_path.
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self,
                                  capacity: sunPathSize) { dst in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(dst, src.baseAddress, pathBytes.count)
                }
            }
        }

        // bind()
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindResult != 0 {
            let saved = errno
            _ = Darwin.close(fd)
            throw MCPBridgeError.socketBindFailed(saved)
        }

        // listen()
        if Darwin.listen(fd, 8) != 0 {
            let saved = errno
            _ = Darwin.close(fd)
            throw MCPBridgeError.socketListenFailed(saved)
        }

        listenerSocket = fd
        let queue = DispatchQueue(label: "sipai.mcp.listener",
                                  qos: .userInitiated)
        queue.async { [weak self] in
            self?.acceptLoop(fd: fd)
        }
    }

    // Runs on the listener queue. Accepts connections until the socket
    // is closed (shutdown sets listenerSocket to -1 and closes fd).
    nonisolated private func acceptLoop(fd: Int32) {
        while true {
            var peer = sockaddr_un()
            var len: socklen_t = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &peer) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(fd, sockPtr, &len)
                }
            }
            if client < 0 {
                // accept returns -1 when the listening socket is closed;
                // that's the shutdown path.
                return
            }
            // Same-user only. The socket already sits under ~/Library
            // (mode 0700), but if those permissions are ever loosened a
            // connection from another uid must still be refused: an
            // approval card is a question about THIS user's agent turn,
            // and only this user may see or answer it.
            var peerUid: uid_t = 0
            var peerGid: gid_t = 0
            if getpeereid(client, &peerUid, &peerGid) != 0 || peerUid != getuid() {
                _ = Darwin.close(client)
                continue
            }
            let handlerQueue = DispatchQueue(label: "sipai.mcp.handler",
                                             qos: .userInitiated)
            handlerQueue.async { [weak self] in
                self?.handleConnection(fd: client)
            }
        }
    }

    // Runs on a per-connection queue. Reads one request line, resolves
    // a verdict (by posting to MainActor and waiting on the request's
    // semaphore), writes the response, closes.
    nonisolated private func handleConnection(fd: Int32) {
        defer { _ = Darwin.close(fd) }
        guard let line = readLineFromSocket(fd: fd) else { return }
        guard let obj = parseRequestLine(line) else {
            sendDenyResponse(fd: fd, requestId: "",
                             message: "SipAI approver: invalid JSON on wire.")
            return
        }
        let requestId = (obj["request_id"] as? String) ?? UUID().uuidString
        let kind = obj["kind"] as? String
        if kind != "approval_request" {
            sendDenyResponse(fd: fd, requestId: requestId,
                             message: "SipAI approver: unexpected request kind.")
            return
        }
        let toolName = (obj["tool_name"] as? String) ?? ""
        let toolInput = (obj["tool_input"] as? [String: Any]) ?? [:]
        if toolName.isEmpty {
            sendDenyResponse(fd: fd, requestId: requestId,
                             message: "SipAI approver: missing tool_name.")
            return
        }
        let sessionId = obj["session_id"] as? String
        let taskUuid = obj["task_uuid"] as? String

        // A tool that can only be answered by an interactive front-end
        // never reaches the UI. `AskUserQuestion` renders its options
        // in Claude Code's OWN terminal front-end; under `claude -p`
        // there is none, so it arrives on this socket like any other
        // tool — and however an approval card were answered, the tool
        // would still come back "The user did not answer the
        // questions". A card would interrupt the user to decide
        // nothing, while reading as if it WERE the question.
        //
        // Answer it here instead, and say why. A deny `message` is
        // handed back to claude as the tool's result, which is the one
        // channel this protocol gives us — so the agent learns
        // immediately to put the question in its reply, where the
        // composer can answer it.
        if Self.nonInteractiveTools.contains(toolName) {
            sendDenyResponse(
                fd: fd, requestId: requestId,
                message: "SipAI runs Claude Code headlessly (claude -p), so "
                    + "\(toolName) has no interface to collect an answer and "
                    + "will always come back unanswered. Do not retry it — ask "
                    + "the user in your reply text instead; they answer in the "
                    + "composer.")
            return
        }

        // Build the request and hand it to MainActor for UI display.
        let req = MCPApprovalRequest(
            id: requestId,
            sessionId: sessionId,
            taskUuid: taskUuid,
            toolName: toolName,
            toolInput: toolInput
        )

        // Cache-hit fast path: if we have a cached always-decision for
        // this (scope, tool, signature), answer immediately without
        // bothering the UI. Scope resolution: session_id wins, else
        // alias[task_uuid] or task_uuid itself.
        var cachedVerdict: MCPCacheVerdict?
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                cachedVerdict = self.lookupCache(req)
            }
        }
        if let cached = cachedVerdict {
            let wire = (cached == .allow) ? "allow" : "deny"
            let updated: [String: Any]? = (cached == .allow) ? toolInput : nil
            let message: String? = (cached == .deny) ? "Denied by SipAI (remembered)." : nil
            sendResponse(fd: fd, requestId: requestId, verdict: wire,
                         updatedInput: updated, message: message)
            return
        }

        // Post to MainActor — appends to `pending`, which drives the UI.
        // The UI's Allow/Deny button calls `resolve(requestId:verdict:)`
        // which sets req.verdict and signals req.semaphore.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.shuttingDown else {
                // Bridge gone; let the handler fall through to default deny.
                req.semaphore.signal()
                return
            }
            self.pending.append(req)
        }

        // Fire a macOS notification if the user isn't looking at this
        // session. Harmless if notifications are denied — the inline
        // card still appears as the primary surface.
        DispatchQueue.main.async { [weak self] in
            self?.maybePostNotification(for: req)
        }

        // Block until resolved (or shutdown forces default .deny).
        req.semaphore.wait()

        // Send the response.
        let wireVerdict = req.verdict.wireVerdict
        let updatedInput: [String: Any]? = wireVerdict == "allow" ? toolInput : nil
        let message: String? = wireVerdict == "deny" ? "Denied by SipAI." : nil
        sendResponse(fd: fd, requestId: requestId,
                     verdict: wireVerdict,
                     updatedInput: updatedInput,
                     message: message)
    }

    // MARK: - UI callback — resolve a pending request

    /// Called from the SwiftUI Allow/Deny/Allow-Always/Deny-Always
    /// buttons. Sets the verdict, removes from pending, and signals
    /// the semaphore so the handler thread proceeds to write the
    /// wire response. For the Always variants, also writes the
    /// `(toolName, signature)` → verdict mapping into the cache under
    /// the approval's scope so future matching requests short-circuit.
    func resolve(requestId: String, verdict: MCPVerdict) {
        guard let idx = pending.firstIndex(where: { $0.id == requestId }) else {
            return
        }
        let req = pending[idx]
        req.verdict = verdict
        pending.remove(at: idx)
        req.semaphore.signal()

        if verdict == .allowAlways || verdict == .denyAlways {
            writeCacheEntry(req: req,
                            cached: verdict == .allowAlways ? .allow : .deny)
        }

        // Dismiss the notification we posted for this request (if any).
        dismissNotification(for: req.id)
    }

    /// Force-deny every pending approval belonging to one session (or,
    /// for a not-yet-migrated draft, its task_uuid). Called when the
    /// turn that asked is stopped or its claude exits: a dead claude
    /// can never consume the answer, so leaving the cards up leaves
    /// ghost questions whose Allow/Deny buttons do nothing meaningful.
    /// Deliberately never writes the always-cache — this is cleanup,
    /// not a user verdict.
    func cancelPending(sessionId: String?, taskUuid: String?) {
        let sid = sessionId ?? ""
        let tuid = taskUuid ?? ""
        guard !sid.isEmpty || !tuid.isEmpty else { return }
        var kept: [MCPApprovalRequest] = []
        var removed = false
        for req in pending {
            let reqSid = req.sessionId ?? ""
            let reqTuid = req.taskUuid ?? ""
            let matches = (!sid.isEmpty && reqSid == sid)
                || (!tuid.isEmpty && reqTuid == tuid)
                // A request filed under a draft's task_uuid belongs to
                // the session that uuid migrated to.
                || (!sid.isEmpty && !reqTuid.isEmpty && alias[reqTuid] == sid)
            if matches {
                req.verdict = .deny
                req.semaphore.signal()
                dismissNotification(for: req.id)
                removed = true
            } else {
                kept.append(req)
            }
        }
        if removed { pending = kept }
    }

    /// Commit an always-decision to the per-scope cache.
    private func writeCacheEntry(req: MCPApprovalRequest,
                                 cached: MCPCacheVerdict) {
        let scope = scopeKey(sessionId: req.sessionId, taskUuid: req.taskUuid)
        guard !scope.isEmpty else { return }
        let key = MCPCacheKey(
            toolName: req.toolName,
            signature: Self.signature(toolName: req.toolName,
                                      toolInput: req.toolInput)
        )
        var scopeEntries = cache[scope] ?? [:]
        scopeEntries[key] = cached
        cache[scope] = scopeEntries
    }

    /// Scope-resolution for cache lookup: session_id wins; otherwise
    /// alias[task_uuid] if it's been registered; otherwise task_uuid
    /// itself. Empty string is returned when neither id is set.
    private func scopeKey(sessionId: String?, taskUuid: String?) -> String {
        if let s = sessionId, !s.isEmpty { return s }
        if let t = taskUuid, !t.isEmpty {
            return alias[t] ?? t
        }
        return ""
    }

    /// Look up a cached always-decision for a pending request. Checked
    /// scopes, in order: the request's session_id, the request's
    /// task_uuid directly, and the alias-resolved task_uuid →
    /// session_id mapping. First hit wins.
    fileprivate func lookupCache(_ req: MCPApprovalRequest) -> MCPCacheVerdict? {
        let key = MCPCacheKey(
            toolName: req.toolName,
            signature: Self.signature(toolName: req.toolName,
                                      toolInput: req.toolInput)
        )
        if let sid = req.sessionId, !sid.isEmpty,
           let v = cache[sid]?[key] {
            return v
        }
        if let tu = req.taskUuid, !tu.isEmpty {
            if let v = cache[tu]?[key] { return v }
            if let aliased = alias[tu], let v = cache[aliased]?[key] {
                return v
            }
        }
        return nil
    }

    // MARK: - Alias

    /// Called from AgentRunner when a draft's system.init reveals the
    /// real session id. Records the mapping AND migrates any cache
    /// entries that accumulated under the task_uuid scope into the new
    /// session_id scope so Allow Always decisions made on a draft
    /// continue to apply after the draft becomes an existing session.
    func registerAlias(taskUuid: String, sessionId: String) {
        guard !taskUuid.isEmpty, !sessionId.isEmpty,
              taskUuid != sessionId, alias[taskUuid] != sessionId
        else { return }
        alias[taskUuid] = sessionId

        // Cache migration: move any entries from the task_uuid scope
        // to the session_id scope. Existing session_id entries win on
        // collision (the user's most recent context takes priority).
        if let taskEntries = cache.removeValue(forKey: taskUuid) {
            var sessionEntries = cache[sessionId] ?? [:]
            for (k, v) in taskEntries where sessionEntries[k] == nil {
                sessionEntries[k] = v
            }
            cache[sessionId] = sessionEntries
        }
    }

    // MARK: - Claude Code integration helpers

    /// Extra args to pass to `claude -p …` so Claude Code routes
    /// permission prompts through our approver.
    func argsForClaude() -> [String] {
        return [
            "--mcp-config", configPath.path,
            "--permission-prompt-tool", Self.permissionPromptToolName,
        ]
    }

    /// Environment-overlay for the `claude` subprocess.
    ///
    /// `SIPAI_SESSION_ID` is read by approver.py and forwarded in the
    /// wire request. Claude Code inherits this env from its own parent
    /// process when it spawns the approver as a stdio MCP server.
    ///
    /// For an existing session, pass the dashed UUID; for a draft, pass
    /// a 32-char hex task_uuid the runner generates on first send.
    func environmentOverlay(sessionIdOrTaskUuid: String) -> [String: String] {
        return [
            "SIPAI_SESSION_ID": sessionIdOrTaskUuid,
            "SIPAI_APPROVER_SOCKET": socketPath.path,
        ]
    }

    // MARK: - Signature normalization (cache keys)

    /// Transient keys stripped before hashing — they would otherwise
    /// defeat the cache.
    nonisolated private static let transientKeys: Set<String> = [
        "timestamp", "ts", "request_id", "nonce", "trace_id",
    ]

    /// Normalize a tool input for cache keying, so the same call
    /// resolves to the same remembered decision.
    nonisolated static func signature(toolName: String, toolInput: [String: Any]) -> String {
        var obj: [String: Any] = toolInput.filter { !transientKeys.contains($0.key) }
        switch toolName {
        case "Bash":
            obj = ["command": (toolInput["command"] as? String) ?? ""]
        case "Read", "Edit", "Write":
            obj = ["file_path": (toolInput["file_path"] as? String) ?? ""]
        default:
            // Drop any string values >500 chars.
            for (k, v) in obj {
                if let s = v as? String, s.count > 500 {
                    obj.removeValue(forKey: k)
                }
            }
        }
        // sort_keys=True equivalent; use JSONSerialization's .sortedKeys.
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return "" }
        return str
    }

    // MARK: - Input preview (used by the card UI)

    nonisolated static func previewInput(toolName: String, input: [String: Any]) -> String {
        func trunc(_ s: String, _ n: Int) -> String {
            if s.count <= n { return s }
            return String(s.prefix(n - 1)) + "…"
        }
        switch toolName {
        case "Bash":
            return trunc((input["command"] as? String) ?? "", 260)
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            return trunc((input["file_path"] as? String) ?? "", 200)
        case "Glob", "Grep":
            let pattern = (input["pattern"] as? String) ?? ""
            let path = (input["path"] as? String) ?? ""
            if !path.isEmpty { return trunc("\(pattern)  in  \(path)", 260) }
            return trunc(pattern, 260)
        case "WebFetch":
            return trunc((input["url"] as? String) ?? "", 260)
        case "WebSearch":
            return trunc((input["query"] as? String) ?? "", 260)
        default:
            if let data = try? JSONSerialization.data(
                withJSONObject: input, options: [.sortedKeys]),
               let s = String(data: data, encoding: .utf8) {
                return trunc(s, 260)
            }
            return ""
        }
    }

    // MARK: - Wire I/O (socket helpers)

    /// Read until newline (or EOF). Returns nil on error / empty.
    nonisolated private func readLineFromSocket(fd: Int32) -> String? {
        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { ptr in
                Darwin.recv(fd, ptr.baseAddress, ptr.count, 0)
            }
            if n <= 0 { break }
            buf.append(contentsOf: chunk.prefix(n))
            if buf.contains(0x0A) { break }  // '\n'
        }
        if buf.isEmpty { return nil }
        // Cut at first newline, decode UTF-8.
        if let nlIdx = buf.firstIndex(of: 0x0A) {
            buf = Array(buf[..<nlIdx])
        }
        return String(bytes: buf, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private func parseRequestLine(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    nonisolated private func sendResponse(fd: Int32, requestId: String,
                                          verdict: String,
                                          updatedInput: [String: Any]?,
                                          message: String?) {
        var body: [String: Any] = [
            "v": 1,
            "request_id": requestId,
            "verdict": verdict,
        ]
        if let u = updatedInput {
            body["updated_input"] = u
        } else {
            body["updated_input"] = NSNull()
        }
        if let m = message {
            body["message"] = m
        } else {
            body["message"] = NSNull()
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: body, options: [.withoutEscapingSlashes])
        else { return }
        var payload = data
        payload.append(0x0A)  // '\n'
        payload.withUnsafeBytes { rawBuf in
            _ = Darwin.send(fd, rawBuf.baseAddress, rawBuf.count, 0)
        }
    }

    nonisolated private func sendDenyResponse(fd: Int32, requestId: String, message: String) {
        sendResponse(fd: fd, requestId: requestId, verdict: "deny",
                     updatedInput: nil, message: message)
    }

    // MARK: - Notifications

    /// Identifier prefix so we can dismiss a specific request's
    /// notification on resolution. One notification per request id.
    private static let notificationIdentifierPrefix = "sipai.mcp.approval."

    /// Tracks whether we've already asked for notification permission
    /// so we don't spam the authorization API.
    private var didRequestNotificationPermission = false

    /// Post a macOS notification for `req` if the user isn't currently
    /// looking at this session. Called on MainActor from the handler
    /// thread right after appending to pending. Best-effort — if
    /// notifications are denied by the user, does nothing (the inline
    /// card is still the primary surface).
    fileprivate func maybePostNotification(for req: MCPApprovalRequest) {
        // Skip if a caller-provided closure confirms the session is
        // already in focus. Nil = always notify (safe default).
        if let isFocused = isApprovalFocused, isFocused(req) {
            return
        }

        // Lazy authorization — ask the first time we'd actually post.
        if !didRequestNotificationPermission {
            didRequestNotificationPermission = true
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound]) { _, _ in
                    // Result is fire-and-forget; the post below will
                    // be silently dropped by the system if denied.
                }
        }

        let content = UNMutableNotificationContent()
        content.title = String(
            localized: "Claude Code permission needed",
            comment: "Notification title for a pending MCP approval")
        content.body = String(
            localized: "Allow ‘\(req.toolName)’ · \(notificationPreview(for: req))",
            comment: "Notification body: tool name + short preview")
        content.sound = .default
        content.userInfo = [
            "kind": "mcp-approval",
            "requestId": req.id,
            "sessionId": req.sessionId ?? "",
            "taskUuid": req.taskUuid ?? "",
        ]

        let identifier = Self.notificationIdentifierPrefix + req.id
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil)  // fire immediately
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Remove a request's notification (if any) from Notification
    /// Center once it's resolved. Avoids leaving stale banners the
    /// user could still click on after the inline card is gone.
    private func dismissNotification(for requestId: String) {
        let identifier = Self.notificationIdentifierPrefix + requestId
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [identifier])
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Short-form preview for the notification body. Truncates
    /// aggressively since the banner has limited horizontal space.
    private func notificationPreview(for req: MCPApprovalRequest) -> String {
        let full = Self.previewInput(toolName: req.toolName,
                                     input: req.toolInput)
        if full.count > 80 {
            return String(full.prefix(77)) + "…"
        }
        return full
    }
}

// MARK: - Errors

enum MCPBridgeError: LocalizedError {
    case approverResourceMissing
    case socketCreateFailed(Int32)
    case socketPathTooLong(String)
    case socketBindFailed(Int32)
    case socketListenFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .approverResourceMissing:
            return "SipAI's bundled approver.py is missing. Reinstall the app."
        case .socketCreateFailed(let e):
            return "Could not create MCP socket (errno \(e))."
        case .socketPathTooLong(let p):
            return "MCP socket path too long: \(p)"
        case .socketBindFailed(let e):
            return "Could not bind MCP socket (errno \(e)). Another SipAI may be running."
        case .socketListenFailed(let e):
            return "Could not listen on MCP socket (errno \(e))."
        }
    }
}
