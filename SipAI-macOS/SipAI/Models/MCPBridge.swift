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
// "Allow Always" hands claude back its OWN suggestion for the call — the
// rule its terminal offers as "don't ask again for …" — so claude applies
// and matches it itself (`ClaudePermissionUpdate`). The suggestions reach
// this bridge through a PermissionRequest hook (approver.py run with
// `--permission-context`), since the approve tool is never given them.
// Claude runs that hook AT THE SAME TIME as it asks the approve tool, so
// the two arrive in either order and are matched up here
// (`fileSuggestions`). With no suggestion for a call, and for "Deny
// Always", the decision is remembered here instead: a per-scope
// cache[(toolName, signature)] → allow/deny consulted before a new
// request ever reaches the UI (`lookupCache`), which answers the very
// same call without a card.
//
// An MCP server's own request for input — a form, a link to open — comes
// the same way from claude's Elicitation hook (approver.py run with
// `--elicitation`), and is drawn as codex's are (`McpElicitation`).

import Foundation
import AppKit
import CryptoKit
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

/// What becomes of a question an agent asks in the middle of a turn —
/// decided by the turn that asked it (`MCPBridge.questionPolicy`).
enum MCPQuestionPolicy: Equatable {
    /// Show the question card; the turn waits for the user.
    case ask
    /// Non-stop is on for the turn: declined at once with
    /// `AgentQuestionReplies.nonStop`.
    case nonStop
    /// No turn of this app can take an answer: declined with
    /// `AgentQuestionReplies.unanswerable`.
    case unanswerable
}

/// One in-flight approval awaiting the user's click. Reference type.
///
/// Two front ends ask for one:
///
/// * claude's approver: the socket-handler thread creates it, hands it to
///   the bridge which posts it on MainActor, and then blocks on
///   `semaphore` until the UI calls `resolve(requestId:verdict:)`. The
///   verdict + semaphore fields are internal so the handler thread can
///   read them after signalling.
/// * an agent's own interactive protocol (codex's app-server, kimi's
///   ACP): its turn driver creates it with a `presentation` and a
///   `respond` closure, and the bridge calls that closure exactly once
///   with what became of the card (`CardResolution`).
final class MCPApprovalRequest: Identifiable, @unchecked Sendable {
    let id: String                // request_id from the wire, or "<agent>:<uuid>" for another front end
    let sessionId: String?        // from SIPAI_SESSION_ID env when it's a dashed UUID
    let taskUuid: String?         // from SIPAI_SESSION_ID env when it's 32 hex chars
    let toolName: String
    let toolInput: [String: Any]

    /// The agent whose turn asked.
    let agentKey: String

    /// How a request from an agent's own front end is drawn; nil for
    /// claude's approver, whose card follows from the tool name and input.
    let presentation: CardPresentation?

    /// Whether the question policy decides this request — a question, a
    /// question whose form could not be read, or what an MCP server asks
    /// itself: a link to open, a yes-or-no. Non-stop declines them all; an
    /// approval waits with or without it.
    let asksQuestion: Bool

    /// Whether the turn that asked waits on this card. False for a question
    /// an agent asked without stopping (codex's `request_user_input_async`):
    /// the agent works on while it is up, so it never holds the turn clock
    /// (`AgentRunner.syncUserWait`). Claude's approver asks nothing that
    /// way.
    let turnWaits: Bool

    /// Hands what became of the card back to the agent's own front end —
    /// exactly once, on the main actor. nil for claude's approver, which
    /// is answered over its socket once `semaphore` is signalled.
    fileprivate let respond: (@MainActor (CardResolution) -> Void)?

    /// Set by the bridge as the request is answered; a second answer — a
    /// double click, Stop racing a click — finds it set and does nothing.
    fileprivate var delivered = false

    /// Whether this request came from claude's approver.
    var isFromApprover: Bool { presentation == nil }

    var permissionContent: PermissionCardContent? {
        if case .permission(let content) = presentation { return content }
        return nil
    }

    var planContent: PlanCardContent? {
        if case .plan(let content) = presentation { return content }
        return nil
    }

    var linkContent: LinkCardContent? {
        if case .link(let content) = presentation { return content }
        return nil
    }

    /// The one spelling of "this request is drawn as a plan card".
    var isPlanCard: Bool {
        planContent != nil || (isFromApprover && toolName == MCPBridge.planApprovalTool)
    }

    /// The questions of an `AskUserQuestion` call, parsed once as the
    /// request arrives. Non-nil exactly when the request is drawn as a
    /// question card rather than an approval card.
    let question: AgentQuestionForm?

    var isQuestion: Bool { question != nil }

    /// What "Allow Always" does for this call: claude's own suggestions
    /// for it, as its PermissionRequest hook reported them. Empty when
    /// claude suggested nothing (its terminal then offers no "don't ask
    /// again" either), when the hook did not run, and for the moment
    /// between the card appearing and the hook's report landing; "Allow
    /// Always" then remembers the exact call in SipAI. Written on the
    /// main actor only (`MCPBridge.fileSuggestions`).
    fileprivate(set) var alwaysOffer: [ClaudePermissionUpdate] = []

    /// What this call's suggestions are filed under, or nil for a call
    /// that has no Always — a question, a plan.
    let suggestionKey: String?

    /// Signalled by `resolve(...)` once the user clicks a button (or
    /// on shutdown, which forces a deny). The handler thread waits on
    /// this before writing the JSON response back over the socket.
    fileprivate let semaphore = DispatchSemaphore(value: 0)

    /// Written by `resolve(...)` on MainActor under `_stateLock`, read
    /// by the handler thread after `semaphore.wait()`. Default deny
    /// covers the "listener shutdown before resolution" case.
    fileprivate var verdict: MCPVerdict = .deny

    /// A deny's own words, handed to claude as the tool's result (the
    /// one channel a deny has). nil sends the generic "Denied by SipAI."
    fileprivate var denyMessage: String?

    /// On allow: a permission mode claude switches the session to as it
    /// runs the tool (`updatedPermissions` setMode). Measured: an
    /// ExitPlanMode allowed with `acceptEdits` leaves plan mode straight
    /// into accept-edits, and the turn's next edit runs without asking. nil leaves the mode to claude — after an
    /// ExitPlanMode, the mode it was in before planning (Default for a
    /// session launched on Plan).
    fileprivate var modeOnAllow: String?

    /// On allow: the input the tool runs with instead of the one claude
    /// proposed — an answered question's input with its `answers`. nil
    /// runs the tool with its input unchanged.
    fileprivate var inputOnAllow: [String: Any]?

    /// On allow: the permission changes claude makes as it runs the tool
    /// — the `alwaysOffer`, when the answer was "Allow Always".
    fileprivate var permissionsOnAllow: [ClaudePermissionUpdate] = []

    init(id: String, sessionId: String?, taskUuid: String?,
         toolName: String, toolInput: [String: Any],
         question: AgentQuestionForm? = nil,
         suggestionKey: String? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.taskUuid = taskUuid
        self.toolName = toolName
        self.toolInput = toolInput
        self.question = question
        self.suggestionKey = suggestionKey
        self.agentKey = "claude_code"
        self.presentation = nil
        self.asksQuestion = toolName == MCPBridge.questionTool
        self.turnWaits = true
        self.respond = nil
    }

    /// A request from an agent's own front end. Its id is minted here, never
    /// the protocol's own: a JSON-RPC id is a small number unique to one
    /// connection, and drafts, notes, notifications and the keyboard are
    /// all keyed on this one. A question whose form could not be read
    /// passes `question: nil` with `asksQuestion: true`, and is declined.
    init(agentKey: String, sessionId: String?, taskUuid: String?,
         toolName: String, toolInput: [String: Any] = [:],
         presentation: CardPresentation,
         question: AgentQuestionForm? = nil,
         turnWaits: Bool = true,
         respond: @escaping @MainActor (CardResolution) -> Void) {
        self.id = "\(agentKey):\(UUID().uuidString)"
        self.sessionId = sessionId
        self.taskUuid = taskUuid
        self.toolName = toolName
        self.toolInput = toolInput
        self.question = question
        self.suggestionKey = nil
        self.agentKey = agentKey
        self.presentation = presentation
        switch presentation {
        case .question, .link: self.asksQuestion = true
        case .permission(let content): self.asksQuestion = content.asker != nil
        case .plan: self.asksQuestion = false
        }
        self.turnWaits = turnWaits
        self.respond = respond
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

    /// Set by `SipAIApp.onAppear`: told of every card the moment it is
    /// appended — the same moment the macOS notification is decided — so
    /// the bubble beside the sidebar's logo can say a session needs the
    /// user. A request answered before it was appended (declined, cancelled
    /// at shutdown) is never shown, and never told.
    var onRequestShown: ((MCPApprovalRequest) -> Void)?

    /// Whether a question is shown to the user, answered with Non-stop's
    /// words, or declined because no turn of this app can take an answer.
    /// Set by `AgentManager.configure(bridge:config:)`, which knows the
    /// runners; nil declines every question as unanswerable.
    var questionPolicy: ((MCPApprovalRequest) -> MCPQuestionPolicy)?

    /// An agent's name as the user set it in Settings → Labels, by agent
    /// key, for the notifications. Set by `AgentManager`; nil reads as the
    /// agent key itself.
    var agentLabel: ((String) -> String)?

    /// The approver's per-server tool-call limit in milliseconds, written
    /// into its MCP config as `timeout` — or nil to write none. Claude
    /// abandons a permission prompt its server has been silent on for 30
    /// minutes (and says so as the tool's result) unless the server's
    /// entry raises that limit; a card the user has not reached yet is
    /// exactly such a silent call. Asked on every config write, so a
    /// claude update is picked up by the next turn. Set by `AgentManager`,
    /// which knows the installed claude's version: a claude that does not
    /// know the key is never handed it.
    var approverCallTimeoutMs: (() -> Int?)?

    /// Whether the turns this bridge serves are launched with the
    /// PermissionRequest hook that reports claude's own suggestions for a
    /// call (`launchSettings`). Set by `AgentManager`, which knows the
    /// installed claude's version: a claude not measured to run the hook
    /// is launched without it, and "Allow Always" then remembers the
    /// exact call in SipAI — never a hook key a claude may refuse.
    var reportsPermissionSuggestions: (() -> Bool)?

    /// Whether the turns this bridge serves are launched with the
    /// Elicitation hook that puts an MCP server's forms and links on a
    /// card (`launchSettings`). Set by `AgentManager`, which knows the
    /// installed claude's version: below the oldest claude measured to run
    /// the hook under `-p`, nothing is added and claude cancels every such
    /// request itself, as it always has.
    var bridgesMcpForms: (() -> Bool)?

    /// The suggestions claude's hook reported for calls whose approval
    /// request has not arrived yet (`fileSuggestions`).
    private let suggestions = PermissionSuggestionStore()

    /// The session-scoped grants "Allow Always" made, per scope (the
    /// session id, or a draft's task uuid until it has one). Claude keeps
    /// such a grant in the running process alone, and every turn is a
    /// process of its own, so each later turn of the session is launched
    /// with them (`launchSettings`). In memory only, like `cache`: a
    /// relaunch asks again.
    private var sessionGrants: [String: [ClaudePermissionUpdate]] = [:]

    /// A question card's answers so far, per request id. Kept here rather
    /// than in the card: the centre pane replaces the session view on
    /// every detour to a chat or a note, and a card rebuilt from nothing
    /// would drop what the user had picked. Written on every change,
    /// dropped when the request is resolved. Deliberately not
    /// `@Published` — a pick must not re-render every view holding the
    /// bridge.
    private(set) var questionDrafts: [String: AgentQuestionDraft] = [:]

    /// Store a card's state while its request is still pending.
    func setQuestionDraft(_ draft: AgentQuestionDraft, for requestId: String) {
        guard pending.contains(where: { $0.id == requestId }) else { return }
        questionDrafts[requestId] = draft
    }

    /// What the user has typed into a card's own text field so far — the
    /// plan card's "what to change" — per request id. Here for the same
    /// reason as `questionDrafts`, under the same rules: written on every
    /// change, dropped with the request, not `@Published`.
    private(set) var cardNotes: [String: String] = [:]

    func setCardNote(_ note: String, for requestId: String) {
        guard pending.contains(where: { $0.id == requestId }) else { return }
        cardNotes[requestId] = note.isEmpty ? nil : note
    }

    // MARK: Paths (computed once at init)

    private let mcpDir: URL
    private let approverPath: URL
    private let configPath: URL
    private let socketPath: URL

    // MARK: Listener state

    private var listenerStarted = false
    private var listenerSocket: Int32 = -1
    private var shuttingDown = false

    /// The socket file this process bound, by device and inode. Every
    /// copy of SipAI on a Mac shares `mcp/` — the installed copy, a build
    /// run from Xcode, a harness's staged copy — so the path alone does
    /// not say whose socket is there.
    private var boundSocket: SocketFileIdentity?

    /// Canonical MCP server name / tool name, must match the approver.py
    /// constants and the `--permission-prompt-tool mcp__<server>__<tool>`
    /// argument format Claude Code expects.
    private static let serverName = "sipai"
    private static let toolName = "approve"
    static var permissionPromptToolName: String {
        "mcp__\(serverName)__\(toolName)"
    }

    /// Claude's question tool. It reaches the approver like any other
    /// tool call — in every permission mode but dontAsk, Bypass
    /// included, since claude asks the user for it whatever the mode —
    /// and is answered through the same permission-prompt result: an
    /// allow whose input carries the user's `answers`. Drawn as a
    /// question card; see `handleConnection` and `AgentQuestionForm`.
    nonisolated static let questionTool = "AskUserQuestion"

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
        // Every pending request is answered: an approver's handler thread
        // sees the default `.deny` verdict, another front end hears
        // `.cancelled`. State first, answers last.
        let open = pending
        pending.removeAll()
        questionDrafts.removeAll()
        cardNotes.removeAll()
        for req in open { deliver(req, .cancelled) }
        // Close listener socket; accept loop exits.
        if listenerSocket >= 0 {
            _ = Darwin.close(listenerSocket)
            listenerSocket = -1
        }
        // Remove the socket file only if it is still the one THIS process
        // bound. A copy that never ran an agent turn bound nothing, and a
        // copy whose socket another copy has since replaced no longer
        // owns the path; deleting it anyway cuts the other copy's
        // approval cards off until that copy is relaunched — a Sparkle
        // relaunch, or `end-to-end.sh`'s staged copy quitting, does that
        // to whichever SipAI is left running.
        if let ours = boundSocket, SocketFileIdentity(path: socketPath.path) == ours {
            try? FileManager.default.removeItem(at: socketPath)
        }
        boundSocket = nil
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
        var server: [String: Any] = [
            "type": "stdio",
            "command": "/usr/bin/env",
            "args": ["python3", approverPath.path],
            "env": [
                "SIPAI_APPROVER_SOCKET": socketPath.path,
            ],
        ]
        // A card can wait on the user for as long as they take; see
        // `approverCallTimeoutMs`.
        if let timeout = approverCallTimeoutMs?() {
            server["timeout"] = timeout
        }
        let config: [String: Any] = [
            "mcpServers": [
                Self.serverName: server
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
        boundSocket = SocketFileIdentity(path: socketPath.path)
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
            // A peer can be gone by the time it is answered — claude ends
            // a hook the moment its prompt is answered, and takes its MCP
            // servers down with it when it is stopped. A write to such a
            // socket raises SIGPIPE, which ends THIS process unless the
            // socket is told not to.
            var noSigPipe: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                           socklen_t(MemoryLayout<Int32>.size))
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
        if kind == "permission_context" {
            // Claude's own suggestions for a call, from its
            // PermissionRequest hook. No answer goes back: the hook
            // decides nothing and waits for nothing.
            let offer = ClaudePermissionSuggestions.sanitized(obj["suggestions"])
            if !offer.isEmpty, let tool = obj["tool_name"] as? String, !tool.isEmpty {
                let key = PermissionSuggestionStore.key(
                    sessionId: obj["session_id"] as? String,
                    taskUuid: obj["task_uuid"] as? String,
                    toolName: tool,
                    toolInput: (obj["tool_input"] as? [String: Any]) ?? [:])
                DispatchQueue.main.async { [weak self] in
                    self?.fileSuggestions(offer, for: key)
                }
            }
            return
        }
        if kind == "elicitation_request" {
            answerElicitation(fd: fd, message: obj)
            return
        }
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

        // A question is drawn as a question card and answered through the
        // same permission-prompt result as an approval: an allow whose
        // input carries the user's `answers`. Its form is parsed here,
        // off the main thread. A form the card cannot draw still becomes
        // a request — the turn that asked is consulted first, so a turn
        // running Non-stop gets Non-stop's words rather than "ask in text".
        let isQuestion = toolName == Self.questionTool

        // Build the request and hand it to MainActor for UI display.
        let req = MCPApprovalRequest(
            id: requestId,
            sessionId: sessionId,
            taskUuid: taskUuid,
            toolName: toolName,
            toolInput: toolInput,
            question: isQuestion ? AgentQuestionForm(toolInput: toolInput) : nil,
            // A question has no Always, and neither has a plan.
            suggestionKey: isQuestion || toolName == Self.planApprovalTool
                ? nil
                : PermissionSuggestionStore.key(
                    sessionId: sessionId, taskUuid: taskUuid,
                    toolName: toolName, toolInput: toolInput)
        )

        // Cache-hit fast path: if we have a cached always-decision for
        // this (scope, tool, signature), answer immediately without
        // bothering the UI. Scope resolution: session_id wins, else
        // alias[task_uuid] or task_uuid itself. Never for a question: it
        // is answered each time it is asked, and its card has no Always.
        if !isQuestion {
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
        }

        // Post to MainActor — `enqueue` appends to `pending`, which drives
        // the UI, and announces it, in one step (see there). The cards'
        // buttons resolve through `resolve(requestId:verdict:)` /
        // `answerQuestion`, which set req.verdict and signal req.semaphore.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                // Bridge gone; let the handler fall through to default deny.
                req.semaphore.signal()
                return
            }
            self.enqueue(req)
        }

        // Block until resolved (or shutdown forces default .deny).
        req.semaphore.wait()

        // Send the response.
        let wireVerdict = req.verdict.wireVerdict
        let updatedInput: [String: Any]? = wireVerdict == "allow"
            ? (req.inputOnAllow ?? toolInput) : nil
        let message: String? = wireVerdict == "deny"
            ? (req.denyMessage ?? "Denied by SipAI.") : nil
        var updatedPermissions: [[String: Any]] = []
        if wireVerdict == "allow" {
            if let mode = req.modeOnAllow { updatedPermissions.append(Self.setModePermission(mode)) }
            updatedPermissions.append(contentsOf: req.permissionsOnAllow.map(\.wire))
        }
        sendResponse(fd: fd, requestId: requestId,
                     verdict: wireVerdict,
                     updatedInput: updatedInput,
                     message: message,
                     updatedPermissions: updatedPermissions)
    }

    /// Claude's own shape for "switch this session to `mode`", as its
    /// permission-prompt result carries it in `updatedPermissions`.
    nonisolated static func setModePermission(_ mode: String) -> [String: Any] {
        ["type": "setMode", "mode": mode, "destination": "session"]
    }

    // MARK: - Plan approval (ExitPlanMode)

    /// The tool a planning turn ends on. Under `claude -p` it arrives on
    /// this socket like any other tool, carrying the whole plan
    /// (`plan`, the markdown claude read back from its plan file, and
    /// `planFilePath`); the transcript answers it with a plan card
    /// rather than a generic permission card.
    nonisolated static let planApprovalTool = "ExitPlanMode"

    /// What "No, keep planning" with nothing typed tells the model. A
    /// deny's message is handed to claude verbatim as the tool's result
    /// (measured), so this is the whole instruction: stop, stay in plan
    /// mode, and let the user say what to change in the composer. With
    /// words typed the card sends `PlanReplies.keepPlanning(feedback:)`
    /// instead. One English constant, not a catalog key — it is read by
    /// the model, never shown in the UI.
    nonisolated static let keepPlanningMessage = PlanReplies.keepPlanning

    // MARK: - One way in

    /// Hand a request to the user — or decline it at once — in ONE
    /// main-actor step, whichever front end asked: claude's approver (the
    /// socket door) or an agent's own protocol (its turn driver). A
    /// question's fate is decided in the same step that would append it,
    /// so no card can appear for a turn that has meanwhile turned Non-stop
    /// on or been stopped, and nothing is announced that was never
    /// appended. A card that cannot be drawn is declined here and never
    /// half-drawn: it must not hold a turn open.
    func enqueue(_ req: MCPApprovalRequest) {
        guard !shuttingDown else {
            deliver(req, .cancelled)
            return
        }
        if !req.isFromApprover, !Self.isDrawable(req) {
            deliver(req, .declined(.unreadable))
            return
        }
        if req.asksQuestion, let refusal = questionRefusal(for: req) {
            req.verdict = .deny
            req.denyMessage = AgentQuestionReplies.words(for: refusal)
            deliver(req, .declined(refusal))
            return
        }
        // Suggestions that arrived ahead of their request.
        if let key = req.suggestionKey {
            req.alwaysOffer = suggestions.take(key)
        }
        pending.append(req)
        // Fire a macOS notification if the user isn't looking at this
        // session. Harmless if notifications are denied — the inline
        // card still appears as the primary surface.
        maybePostNotification(for: req)
        onRequestShown?(req)
    }

    /// Whether a request from an agent's own front end can be drawn: a
    /// permission or plan card with answers the card can show. A question
    /// is judged by the question policy, with its form.
    nonisolated static func isDrawable(_ req: MCPApprovalRequest) -> Bool {
        switch req.presentation {
        case .permission(let content): return CardChoiceLayout.isDrawable(content.choices)
        case .plan(let content): return CardChoiceLayout.isDrawable(content.choices)
        case .question, .link, .none: return true
        }
    }

    /// The one way a request is ever answered, exactly once: an approver's
    /// handler thread is woken to write its socket reply, another front
    /// end's driver is handed the resolution. Callers settle the bridge's
    /// own state first — the pending list, drafts, notes, the notification
    /// — so a driver that enqueues or withdraws from inside its responder
    /// finds that state already true.
    private func deliver(_ req: MCPApprovalRequest, _ resolution: CardResolution) {
        guard !req.delivered else { return }
        req.delivered = true
        req.respond?(resolution)
        req.semaphore.signal()
    }

    // MARK: - UI callback — resolve a pending request

    /// Called from the SwiftUI Allow/Deny/Allow-Always/Deny-Always
    /// buttons of claude's cards. Sets the verdict, removes from pending,
    /// and signals the semaphore so the handler thread proceeds to write
    /// the wire response.
    ///
    /// "Allow Always" hands claude its own suggestion for the call
    /// (`alwaysOffer`) to apply as it runs the tool; with none on offer,
    /// and for "Deny Always", the `(toolName, signature)` → verdict
    /// mapping is written into the cache under the approval's scope, so
    /// the very same call is answered here next time.
    ///
    /// `message` replaces a deny's generic words; `setMode` rides an
    /// allow as the mode claude switches the session to. Both exist for
    /// the plan card, and neither is ever cached.
    func resolve(requestId: String, verdict: MCPVerdict,
                 message: String? = nil, setMode: String? = nil) {
        guard let req = pending.first(where: { $0.id == requestId }),
              req.isFromApprover else {
            return
        }
        finish(req, verdict: verdict, message: message, setMode: setMode,
               resolution: .chose(verdict.rawValue))
    }

    /// One of the answers an agent's own card offers was picked. The
    /// agent applies it — and remembers it, for an answer that says
    /// "for this session" — itself: nothing is written to the exact-call
    /// cache, which answers claude's approver alone.
    func choose(requestId: String, optionId: String) {
        guard let req = pending.first(where: { $0.id == requestId }),
              !req.isFromApprover else { return }
        finish(req, verdict: .deny, resolution: .chose(optionId))
    }

    /// The agent resolved a request itself — answered on another client,
    /// or dropped with its turn — so it no longer waits: the card goes,
    /// and no answer is sent. Returns what the user had started on a
    /// question the turn did not wait on (`unsentAnswers`), for the
    /// session's message box.
    @discardableResult
    func withdraw(requestId: String) -> String? {
        guard let idx = pending.firstIndex(where: { $0.id == requestId }),
              !pending[idx].isFromApprover else { return nil }
        let req = pending.remove(at: idx)
        let unsent = unsentAnswers(of: req)
        questionDrafts[req.id] = nil
        cardNotes[req.id] = nil
        dismissNotification(for: req.id)
        req.delivered = true
        return unsent
    }

    /// What the user had put into a question card the turn does not wait
    /// on (codex's question asked without stopping) and not sent, as
    /// Codex's own terminal hands it back when the turn that asked ends.
    /// Nil for every other card: one the turn waits on cannot be left
    /// behind by its turn, and its answer goes nowhere else.
    private func unsentAnswers(of req: MCPApprovalRequest) -> String? {
        guard !req.turnWaits, let form = req.question,
              let draft = questionDrafts[req.id] else { return nil }
        return form.unsentAnswersText(draft)
    }

    /// The one way a request the user answers leaves `pending`: the
    /// verdict and its riders set, the card gone, the notification
    /// withdrawn, and then the answer delivered. A second call for the
    /// same request — a double click, a field's Return beside a default
    /// button — finds nothing pending and does nothing.
    ///
    /// The verdict and its riders are what claude's approver writes back;
    /// `resolution` is what another front end's driver is handed. Each
    /// reads its own and ignores the other.
    private func finish(_ req: MCPApprovalRequest, verdict: MCPVerdict,
                        message: String? = nil, setMode: String? = nil,
                        inputOnAllow: [String: Any]? = nil,
                        resolution: CardResolution) {
        guard let idx = pending.firstIndex(where: { $0 === req }) else { return }
        req.verdict = verdict
        req.denyMessage = message
        req.modeOnAllow = setMode
        req.inputOnAllow = inputOnAllow
        if verdict == .allowAlways, !req.alwaysOffer.isEmpty {
            // Claude applies its own rule, and matches later calls
            // against it itself — nothing is remembered here, except the
            // grants claude keeps in the running process alone, which the
            // session's later turns are launched with.
            req.permissionsOnAllow = req.alwaysOffer
            rememberSessionGrants(req.alwaysOffer.filter(\.isSessionScoped), for: req)
        }
        pending.remove(at: idx)
        questionDrafts[req.id] = nil
        cardNotes[req.id] = nil

        if req.isFromApprover,
           verdict == .denyAlways || (verdict == .allowAlways && req.alwaysOffer.isEmpty) {
            writeCacheEntry(req: req,
                            cached: verdict == .allowAlways ? .allow : .deny)
        }

        // Dismiss the notification we posted for this request (if any).
        dismissNotification(for: req.id)
        deliver(req, resolution)
    }

    // MARK: - Questions (AskUserQuestion)

    /// Answer a question card. Claude runs the tool with its own input
    /// plus the user's `answers`, and tells the model what was chosen;
    /// another agent's driver spells the answers its own way.
    func answerQuestion(requestId: String, answers: [String: AgentQuestionAnswer]) {
        guard let req = pending.first(where: { $0.id == requestId }),
              let form = req.question else { return }
        finish(req, verdict: .allow,
               inputOnAllow: req.isFromApprover
                   ? form.updatedInput(original: req.toolInput, answers: answers) : nil,
               resolution: .answered(answers))
    }

    /// Skip a question card: the agent is told to choose for itself and
    /// carry on — in SipAI's words where its protocol carries them, and
    /// as its own "not answered" where it does not.
    func skipQuestion(requestId: String) {
        guard let req = pending.first(where: { $0.id == requestId }),
              req.isQuestion else { return }
        finish(req, verdict: .deny, message: AgentQuestionReplies.skipped,
               resolution: .skipped)
    }

    /// "Chat about this" on a question card: the agent is told what was
    /// asked and answered so far, and to ask what the user wants to
    /// clarify — in its reply, which ends the turn. Claude's alone: it
    /// rides a deny's message, a channel other agents' protocols lack.
    func chatAboutQuestion(requestId: String, answers: [String: AgentQuestionAnswer]) {
        guard let req = pending.first(where: { $0.id == requestId }),
              req.isFromApprover,
              let form = req.question else { return }
        finish(req, verdict: .deny,
               message: AgentQuestionReplies.chat(about: form, answers: answers),
               resolution: .skipped)
    }

    /// Non-stop was turned on while a turn's question was on screen: the
    /// question is declined with Non-stop's words, and the turn goes on.
    /// Approval cards of the same turn are left alone — Non-stop is about
    /// questions only.
    func declineQuestions(sessionId: String?, taskUuid: String?) {
        let owned = pending.filter {
            $0.asksQuestion && belongs($0, toSession: sessionId, taskUuid: taskUuid)
        }
        for req in owned {
            finish(req, verdict: .deny, message: AgentQuestionReplies.nonStop,
                   resolution: .declined(.nonStop))
        }
    }

    /// Why a question is declined without a card, or nil to show it.
    /// Non-stop comes first: whatever else is true of the call, a turn
    /// running Non-stop — the composer's switch, a scheduled task's box —
    /// is told to decide and go on, never to wait or to ask in text.
    private func questionRefusal(for req: MCPApprovalRequest) -> CardDecline? {
        switch questionPolicy?(req) ?? .unanswerable {
        case .nonStop: return .nonStop
        case .unanswerable: return .unanswerable
        // A question whose form could not be read. A link and a server's
        // yes-or-no have no form to read.
        case .ask:
            let hasForm = req.isFromApprover || req.presentation == .question
            return hasForm && req.question == nil ? .unreadable : nil
        }
    }

    // MARK: - Which session a request belongs to

    /// Whether a request tagged (`requestSessionId`, `requestTaskUuid`)
    /// belongs to the runner identified by (`sessionId`, `taskUuid`).
    /// ONE rule, for everything that matches a request to a session:
    /// the transcript's card filter, Stop's cleanup (`cancelPending`),
    /// the notification hook and the notification click.
    ///
    /// A request carries whatever `SIPAI_SESSION_ID` its child was
    /// spawned with, and a child's environment never changes. A new
    /// session's FIRST turn is spawned from a draft, so every approval of
    /// that turn arrives tagged with the draft's task uuid, although
    /// claude's `system.init` names the real session id in its first
    /// second and the runner adopts it. Matching on the session id alone
    /// would hide every first-turn card: nothing would draw it, the turn
    /// would wait on it forever, and Stop would be the only way out.
    /// Plan mode would meet that almost every time, because its one
    /// approval (ExitPlanMode) ends a planning turn that is usually the
    /// session's first.
    nonisolated static func request(sessionId requestSessionId: String?,
                                    taskUuid requestTaskUuid: String?,
                                    belongsToSession sessionId: String?,
                                    taskUuid: String?,
                                    alias: [String: String]) -> Bool {
        let reqSid = requestSessionId ?? ""
        let reqTuid = requestTaskUuid ?? ""
        let sid = sessionId ?? ""
        let tuid = taskUuid ?? ""
        if !sid.isEmpty, reqSid == sid { return true }
        if !tuid.isEmpty, reqTuid == tuid { return true }
        // A request filed under a draft's task uuid belongs to the
        // session that uuid migrated to — for a caller that knows the
        // session but not the uuid (a notification, another runner).
        if !sid.isEmpty, !reqTuid.isEmpty, alias[reqTuid] == sid { return true }
        return false
    }

    /// `request(sessionId:taskUuid:belongsToSession:taskUuid:alias:)`
    /// against this bridge's alias map.
    func belongs(_ req: MCPApprovalRequest, toSession sessionId: String?,
                 taskUuid: String?) -> Bool {
        Self.request(sessionId: req.sessionId, taskUuid: req.taskUuid,
                     belongsToSession: sessionId, taskUuid: taskUuid,
                     alias: alias)
    }

    /// The pending requests one runner's transcript draws.
    func pending(forSession sessionId: String?, taskUuid: String?) -> [MCPApprovalRequest] {
        pending.filter { belongs($0, toSession: sessionId, taskUuid: taskUuid) }
    }

    /// The session a request belongs to, when it is known: its own id,
    /// or the session its task uuid migrated to. nil for a request whose
    /// draft has not announced a session yet.
    func owningSessionId(of req: MCPApprovalRequest) -> String? {
        if let sid = req.sessionId, !sid.isEmpty { return sid }
        if let tuid = req.taskUuid, !tuid.isEmpty, let sid = alias[tuid] { return sid }
        return nil
    }

    /// Force-deny every pending approval belonging to one session (or,
    /// for a not-yet-migrated draft, its task_uuid). Called when the
    /// turn that asked is stopped or its claude exits: a dead claude
    /// can never consume the answer, so leaving the cards up leaves
    /// ghost questions whose Allow/Deny buttons do nothing meaningful.
    /// Deliberately never writes the always-cache — this is cleanup,
    /// not a user verdict. Returns what the user had started on the
    /// questions among them the turn did not wait on (`unsentAnswers`),
    /// in the order they were asked.
    @discardableResult
    func cancelPending(sessionId: String?, taskUuid: String?) -> [String] {
        let sid = sessionId ?? ""
        let tuid = taskUuid ?? ""
        guard !sid.isEmpty || !tuid.isEmpty else { return [] }
        var kept: [MCPApprovalRequest] = []
        var removed: [MCPApprovalRequest] = []
        var unsent: [String] = []
        for req in pending {
            if belongs(req, toSession: sessionId, taskUuid: taskUuid) {
                req.verdict = .deny
                if let text = unsentAnswers(of: req) { unsent.append(text) }
                questionDrafts[req.id] = nil
                cardNotes[req.id] = nil
                dismissNotification(for: req.id)
                removed.append(req)
            } else {
                kept.append(req)
            }
        }
        guard !removed.isEmpty else { return [] }
        pending = kept
        for req in removed { deliver(req, .cancelled) }
        return unsent
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
        // The same move for the grants a first turn made under its
        // draft's uuid: the session's next turn asks for them by its id.
        if let granted = sessionGrants.removeValue(forKey: taskUuid) {
            var mine = sessionGrants[sessionId] ?? []
            for grant in granted where !mine.contains(grant) { mine.append(grant) }
            sessionGrants[sessionId] = mine
        }
    }

    // MARK: - Claude's suggestions ("Allow Always")

    /// File the suggestions claude's hook reported for one call. Claude
    /// runs the hook and asks the approve tool at the same time, so
    /// either can arrive first: a request already waiting takes them —
    /// its card redraws to say what "Allow Always" will do — and
    /// otherwise they are kept for the request to take as it arrives.
    /// Both halves run here, on the main actor, so neither order can
    /// lose them.
    private func fileSuggestions(_ offer: [ClaudePermissionUpdate], for key: String) {
        if let req = pending.first(where: { $0.suggestionKey == key && $0.alwaysOffer.isEmpty }) {
            // The request is a reference: changing it does not change
            // `pending`, so the cards are told by hand.
            objectWillChange.send()
            req.alwaysOffer = offer
        } else {
            suggestions.put(offer, for: key)
        }
    }

    // MARK: - Session grants ("Allow Always", across turns)

    /// Keep the session-scoped grants an "Allow Always" made, under the
    /// approval's scope, for the session's later turns.
    private func rememberSessionGrants(_ grants: [ClaudePermissionUpdate],
                                       for req: MCPApprovalRequest) {
        guard !grants.isEmpty else { return }
        let scope = scopeKey(sessionId: req.sessionId, taskUuid: req.taskUuid)
        guard !scope.isEmpty else { return }
        var mine = sessionGrants[scope] ?? []
        for grant in grants where !mine.contains(grant) { mine.append(grant) }
        sessionGrants[scope] = mine
    }

    /// The session-scoped grants made so far in one session.
    func sessionGrants(sessionId: String?, taskUuid: String?) -> [ClaudePermissionUpdate] {
        var out: [ClaudePermissionUpdate] = []
        var scopes: [String] = []
        if let sid = sessionId, !sid.isEmpty { scopes.append(sid) }
        if let tuid = taskUuid, !tuid.isEmpty {
            scopes.append(tuid)
            if let aliased = alias[tuid] { scopes.append(aliased) }
        }
        for scope in scopes {
            for grant in sessionGrants[scope] ?? [] where !out.contains(grant) { out.append(grant) }
        }
        return out
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

    /// What a turn's `--settings` carries for the bridge, to be MERGED
    /// into the one `--settings` value of the launch
    /// (`ClaudeSettingsArgv.merging` — claude reads only the last of two):
    ///
    /// * the PermissionRequest hook that reports claude's suggestions for
    ///   each call it is about to ask about (approver.py run with
    ///   `--permission-context`), when the installed claude is known to
    ///   run it. It decides nothing, and claude's own hooks from the
    ///   user's settings still run beside it;
    /// * the session-scoped grants "Allow Always" made in earlier turns
    ///   of this session, as a `permissions` block;
    /// * the Elicitation hook that puts an MCP server's form or link on a
    ///   card (approver.py run with `--elicitation`), when the installed
    ///   claude is known to run it. Under `-p` claude has no dialog for one
    ///   and cancels it unless a hook answers.
    ///
    /// Empty when there is none of them.
    func launchSettings(sessionId: String?, taskUuid: String?) -> [String: Any] {
        var settings: [String: Any] = [:]
        var hooks: [String: Any] = [:]
        if reportsPermissionSuggestions?() == true {
            hooks["PermissionRequest"] = [[
                "matcher": "",
                "hooks": [[
                    "type": "command",
                    "command": Self.permissionContextCommand(approverPath: approverPath.path,
                                                             socketPath: socketPath.path),
                    // Seconds. The hook only hands over a few hundred
                    // bytes; a stuck one must not hold the turn.
                    "timeout": 10,
                ]],
            ]]
        }
        if bridgesMcpForms?() == true {
            hooks["Elicitation"] = [[
                "matcher": "",
                "hooks": [[
                    "type": "command",
                    "command": Self.elicitationCommand(approverPath: approverPath.path,
                                                       socketPath: socketPath.path),
                    // Seconds. The hook waits on the user for as long as
                    // they take, and claude cancels the server's request
                    // the moment it runs out. As long as the approver's
                    // own call limit, and kept under the 2^31 ms a timer
                    // can hold — past that one fires at once.
                    "timeout": Self.elicitationHookTimeout,
                ]],
            ]]
        }
        if !hooks.isEmpty { settings["hooks"] = hooks }
        if let permissions = ClaudePermissionSuggestions.replaySettings(
            sessionGrants(sessionId: sessionId, taskUuid: taskUuid)) {
            settings["permissions"] = permissions
        }
        return settings
    }

    /// The hook's command line. Claude runs it through a shell, so both
    /// paths are quoted — Application Support has a space in it. The
    /// socket is named outright rather than left to the environment: the
    /// approver's own entry names it in its MCP config, and the hook has
    /// no such entry.
    nonisolated static func permissionContextCommand(approverPath: String,
                                                     socketPath: String) -> String {
        "SIPAI_APPROVER_SOCKET=\(shellQuoted(socketPath)) /usr/bin/env python3 "
            + "\(shellQuoted(approverPath)) --permission-context"
    }

    /// The Elicitation hook's command line, spelled like the
    /// PermissionRequest hook's.
    nonisolated static func elicitationCommand(approverPath: String, socketPath: String) -> String {
        "SIPAI_APPROVER_SOCKET=\(shellQuoted(socketPath)) /usr/bin/env python3 "
            + "\(shellQuoted(approverPath)) --elicitation"
    }

    /// How long, in seconds, claude lets the Elicitation hook wait.
    nonisolated static let elicitationHookTimeout = 100_000

    nonisolated static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
        case "Skill":
            // The skill, and what the model handed it.
            let skill = SkillRecords.skillToolName(name: toolName, input: input) ?? ""
            let args = ((input["args"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return trunc(args.isEmpty ? skill : "\(skill)  \(args)", 260)
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
                                          message: String?,
                                          updatedPermissions: [[String: Any]]? = nil) {
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
        // Optional, and only on allow: approver.py passes it through as
        // claude's `updatedPermissions`. An older approver ignores it.
        if let p = updatedPermissions, !p.isEmpty {
            body["updated_permissions"] = p
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

    // MARK: - An MCP server's request, from claude's Elicitation hook

    /// An MCP server's form or link, from claude's Elicitation hook
    /// (approver.py run with `--elicitation`): put on a card like any
    /// agent's (`McpElicitation`), and the answer written back for the
    /// hook to hand claude — `{action, content?}`. One SipAI does not draw
    /// is declined at once. The handler thread waits for as long as the
    /// user takes, within the timeout `launchSettings` gives the hook; a
    /// quit answers `cancel`, as claude's own dialog does on Esc.
    nonisolated private func answerElicitation(fd: Int32, message obj: [String: Any]) {
        let hookInput = obj["hook_input"] as? [String: Any] ?? [:]
        let order = (obj["field_order"] as? [Any])?.compactMap { $0 as? String }
        guard let request = McpElicitation.Request(claudeHook: hookInput, fieldOrder: order),
              let card = McpElicitation.card(for: request) else {
            sendElicitationAnswer(fd: fd, .decline)
            return
        }
        let box = ElicitationAnswerBox()
        let req = MCPApprovalRequest(
            agentKey: "claude_code",
            sessionId: obj["session_id"] as? String,
            taskUuid: obj["task_uuid"] as? String,
            toolName: request.serverName, toolInput: hookInput,
            presentation: card.presentation, question: card.question,
            respond: { resolution in box.set(McpElicitation.answer(for: resolution, to: card)) })
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                req.semaphore.signal()
                return
            }
            self.enqueue(req)
        }
        req.semaphore.wait()
        sendElicitationAnswer(fd: fd, box.value ?? .cancel)
    }

    nonisolated private func sendElicitationAnswer(fd: Int32, _ answer: McpElicitation.Answer) {
        var body: [String: Any] = ["v": 1, "action": answer.action]
        if let content = answer.content { body["content"] = content }
        guard let data = try? JSONSerialization.data(
            withJSONObject: body, options: [.withoutEscapingSlashes])
        else { return }
        var payload = data
        payload.append(0x0A)  // '\n'
        payload.withUnsafeBytes { rawBuf in
            _ = Darwin.send(fd, rawBuf.baseAddress, rawBuf.count, 0)
        }
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
        let text = Self.notificationText(for: req,
                                          agent: agentLabel?(req.agentKey) ?? req.agentKey)
        content.title = text.title
        content.body = text.body
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

    /// A notification's words for a request: the agent under the user's
    /// own label, never a name spelled here.
    nonisolated static func notificationText(for req: MCPApprovalRequest,
                                             agent: String) -> (title: String, body: String) {
        // What an MCP server asks itself — a form, a link, a yes-or-no: the
        // server asks, in its own words.
        if let form = req.question, let server = form.asker {
            return (McpElicitation.Words.requestsInput(server), bannerLine(form.message))
        }
        if let link = req.linkContent {
            return (McpElicitation.Words.wantsLink(link.asker), bannerLine(link.message))
        }
        if let content = req.permissionContent, let server = content.asker {
            var words = ""
            if case .text(let message) = content.preview { words = message }
            return (McpElicitation.Words.requestsInput(server), bannerLine(words))
        }
        if let form = req.question {
            // A question is not a permission: the banner asks it.
            return (String(localized: "\(agent) has a question",
                           comment: "Title of the card on which the user answers the agent's question, and of the notification announcing it; placeholder is the agent label"),
                    bannerLine(form.questions.first?.text ?? ""))
        }
        let title = String(localized: "\(agent) permission needed",
                           comment: "Notification title for an agent's pending approval request; placeholder is the agent label")
        // A plan is not a tool call to allow: its preview would be the
        // first characters of a JSON object holding the whole plan.
        if req.isPlanCard {
            return (title, String(localized: "A plan is ready for your review",
                                  comment: "Notification body: an agent session in plan mode finished its plan and waits for approval"))
        }
        let preview = bannerLine(notificationPreview(for: req))
        return (title, String(localized: "Allow ‘\(req.toolName)’ · \(preview)",
                              comment: "Notification body: tool name + short preview"))
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

    /// One line of at most 80 characters, for a banner.
    nonisolated private static func bannerLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > 80 ? String(flat.prefix(77)) + "…" : flat
    }

    /// The call a banner names: claude's input preview, or what another
    /// agent's card shows of it.
    nonisolated private static func notificationPreview(for req: MCPApprovalRequest) -> String {
        switch req.permissionContent?.preview {
        case .command(let command, _, _)?:
            return command
        case .fileChanges(let changes, _)?:
            return changes.map(\.path).joined(separator: ", ")
        case .text(let text)?:
            return text
        case .nothing?:
            return ""
        case nil:
            return previewInput(toolName: req.toolName, input: req.toolInput)
        }
    }
}

/// The answer to an MCP server's request, handed from the main actor —
/// where the card is answered — to the socket thread that waits to write
/// it.
private final class ElicitationAnswerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: McpElicitation.Answer?

    func set(_ answer: McpElicitation.Answer) { lock.withLock { self.answer = answer } }
    var value: McpElicitation.Answer? { lock.withLock { answer } }
}

// MARK: - Suggestions waiting for their request

/// Claude's suggestions for calls whose approval request has not arrived
/// yet. Keyed by the turn's identity, the tool and a digest of its input,
/// so a request finds its own call's suggestions whatever order several
/// calls arrive in. Guards itself, though the bridge only touches it on
/// the main actor. Bounded in count and in time — an entry whose request
/// never comes (the call was answered without a card) must not pile up.
final class PermissionSuggestionStore: @unchecked Sendable {
    private struct Entry {
        let key: String
        let offer: [ClaudePermissionUpdate]
        let at: Date
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    static let capacity = 64
    static let lifetime: TimeInterval = 120

    nonisolated static func key(sessionId: String?, taskUuid: String?,
                                toolName: String, toolInput: [String: Any]) -> String {
        let input = (try? JSONSerialization.data(withJSONObject: toolInput,
                                                 options: [.sortedKeys])) ?? Data()
        let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        return [sessionId ?? "", taskUuid ?? "", toolName, digest].joined(separator: "\u{1F}")
    }

    func put(_ offer: [ClaudePermissionUpdate], for key: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.key == key || now.timeIntervalSince($0.at) > Self.lifetime }
        entries.append(Entry(key: key, offer: offer, at: now))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// The suggestions filed under `key`, removed: one request takes them.
    func take(_ key: String, now: Date = Date()) -> [ClaudePermissionUpdate] {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { now.timeIntervalSince($0.at) > Self.lifetime }
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return [] }
        return entries.remove(at: index).offer
    }
}

// MARK: - Whose socket is at the path

/// A file's identity, device and inode, read with `lstat` so the path
/// itself is judged and never what a link at it points to. A socket
/// another process bound after ours is a new inode at the same path.
struct SocketFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    /// Nil when nothing is at the path.
    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
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
