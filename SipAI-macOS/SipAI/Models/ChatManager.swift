// ChatManager.swift
// Loads, saves, lists, and mutates conversation files under the Mac app's
// data directory (~/Library/Application Support/SipAI/).
// File format:
//   { "last_response_id": ..., "title": ..., "slug": ..., "project": ...,
//     "model": ..., "last_user_message_at": ISO-8601?,
//     "messages": [ {role, content, model?, time?, files?}, ... ] }

import Foundation

/// ISO-8601 for the chat files' `last_user_message_at`. Written plain,
/// read leniently: a value carrying fractional seconds — from a hand
/// edit, or a future writer — must not silently cost the chat its
/// timestamp. Same shape the agent transcripts stamp records with.
enum ChatDateFormat {
    private static let plain = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func string(from date: Date) -> String { plain.string(from: date) }

    static func date(from raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return plain.date(from: raw) ?? fractional.date(from: raw)
    }
}

struct ChatMessage: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var role: String          // "user" | "assistant" | "system"
    var content: String
    var model: String?        // assistant only
    var time: Double?         // assistant only — seconds
    var tokens: Int?          // assistant only — provider-reported usage (input+output) for the turn
    var files: String?        // user only — files indicator string ("a.txt, b.png")

    enum CodingKeys: String, CodingKey {
        case role, content, model, time, tokens, files
    }

    /// `id` is settable so views that re-CONSTRUCT a ChatMessage inside
    /// `body` (the agent transcript) can pass their row's stable id —
    /// synthesized Equatable includes `id`, so a fresh UUID per render
    /// pass would make every bubble compare "changed" on every streamed
    /// burst, and SwiftUI could never skip the markdown subtree.
    init(id: UUID = UUID(), role: String, content: String,
         model: String? = nil, time: Double? = nil,
         tokens: Int? = nil, files: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.model = model
        self.time = time
        self.tokens = tokens
        self.files = files
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        time = try c.decodeIfPresent(Double.self, forKey: .time)
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens)
        files = try c.decodeIfPresent(String.self, forKey: .files)
    }
}

struct StoredChat: Codable, Identifiable {
    var slug: String
    var title: String
    var project: String?           // project slug, nil = root
    var model: String?
    var lastResponseId: String?
    var messages: [ChatMessage]
    /// File mtime, filled on load. Bumped by ANY save — a rename, a
    /// model change, a reply landing minutes after the question — so it
    /// is not what the sidebar shows or sorts by.
    var modified: Date = Date()
    /// When the user last sent a message into this chat. Persisted, so
    /// it survives the reply that lands after it and every unrelated
    /// save; nil for chats written before this field existed, which is
    /// what `activityAt` falls back for.
    var lastUserMessageAt: Date?

    var id: String { (project ?? "") + "/" + slug }

    /// The one timestamp the sidebar shows and orders by — same
    /// contract as `AgentSession.activityAt`, and the same reason: one
    /// value, so the printed time and the row's position cannot
    /// disagree.
    var activityAt: Date { lastUserMessageAt ?? modified }

    enum CodingKeys: String, CodingKey {
        case slug, title, project, model, messages
        case lastResponseId = "last_response_id"
        case lastUserMessageAt = "last_user_message_at"
    }

    init(slug: String, title: String, project: String? = nil,
         model: String? = nil, lastResponseId: String? = nil,
         messages: [ChatMessage], modified: Date = Date(),
         lastUserMessageAt: Date? = nil) {
        self.slug = slug
        self.title = title
        self.project = project
        self.model = model
        self.lastResponseId = lastResponseId
        self.messages = messages
        self.modified = modified
        self.lastUserMessageAt = lastUserMessageAt
    }

    /// Hand-rolled purely so a malformed `last_user_message_at` costs
    /// the TIMESTAMP and not the CHAT. Decoding it as a `Date` through
    /// any strategy throws on garbage, and `loadChatFile` turns a throw
    /// into nil — one bad character in one field would have dropped the
    /// whole conversation out of the sidebar.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        title = try c.decode(String.self, forKey: .title)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        lastResponseId = try c.decodeIfPresent(String.self,
                                               forKey: .lastResponseId)
        messages = try c.decode([ChatMessage].self, forKey: .messages)
        lastUserMessageAt = ChatDateFormat.date(
            from: try? c.decodeIfPresent(String.self,
                                         forKey: .lastUserMessageAt))
    }
}

/// A chat turn in flight, owned by `ChatManager` rather than by the
/// view that started it.
struct ChatTurn {
    /// When the turn began — the composer's clock reads this, so it
    /// survives the view being replaced mid-turn.
    let startedAt: Date
    /// The unstructured send task. Retained so Stop can cancel it;
    /// `URLSession` honours cooperative cancellation. Releasing this
    /// handle does NOT cancel the task, which is what lets a reply
    /// asked for and then walked away from still arrive.
    let task: Task<Void, Never>
}

/// How a chat turn ended, for whichever view opens the chat next.
enum ChatTurnOutcome: Equatable {
    /// The model hit its output limit.
    case truncated
    /// The user pressed Stop.
    case interrupted
    /// Anything else, already localized for display.
    case failed(String)
}

extension Notification.Name {
    /// Posted by `ChatManager` after a chat's messages change behind
    /// the open view's back — a reply delivered to a conversation the
    /// user may or may not still be looking at. An open `ChatView`
    /// answers it by re-reading that chat.
    ///
    /// A notification rather than a `@Published` read by the view: the
    /// delivery has to reach whichever `ChatView` INSTANCE is showing
    /// the chat, and the router mints a new one on every detour. Same
    /// shape, and same reason, as `.sipChatRenamed`.
    static let sipChatMessagesChanged =
        Notification.Name("sipChatMessagesChanged")
}

@MainActor
final class ChatManager: ObservableObject {
    @Published private(set) var rootChats: [StoredChat] = []     // sorted newest first
    @Published private(set) var projectChats: [String: [StoredChat]] = [:]

    /// Chat turns in flight, by `liveKey`. The agent side's counterpart
    /// is `AgentManager.inFlightSends` + `AgentRunner`, and this exists
    /// for the same reason: the sidebar has to be able to ask "is this
    /// one working right now?" about a conversation it is not showing —
    /// and the turn has to survive the pane the user started it from.
    ///
    /// None of this can live on `ChatView`. That view is replaced by
    /// the centre-pane router on any detour, so a turn started in a
    /// chat and then walked away from outlives the view that started
    /// it. A view-owned flag answers "no" for every chat except the
    /// one on screen; a view-owned RESULT is worse — see
    /// `appendAssistantReply`.
    @Published private(set) var liveTurns: [String: ChatTurn] = [:]

    /// What a finished turn left behind for whichever view opens the
    /// chat next. Kept off the view for the same reason as the turn
    /// itself: a reply that arrives truncated, is stopped, or fails
    /// while the user is looking at something else has to be able to
    /// say so when they come back, instead of leaving a question
    /// sitting there with no answer and no explanation.
    @Published private(set) var turnOutcomes: [String: ChatTurnOutcome] = [:]

    /// Identity of one chat for the live set — the same (project, slug)
    /// pair every save, draft and reply-delivery is keyed by. A chat
    /// that has never been persisted has no slug and cannot be in the
    /// set; `send()` registers it after the first persist, which is
    /// where its slug is minted.
    static func liveKey(slug: String, project: String?) -> String {
        "\(project ?? "")/\(slug)"
    }

    func isChatInFlight(slug: String, project: String?) -> Bool {
        liveTurns[Self.liveKey(slug: slug, project: project)] != nil
    }

    /// The in-flight turn for a chat, if any — the composer reads its
    /// `startedAt` for the "Sipping… (m:ss)" clock, so the clock keeps
    /// the turn's own start time across a detour rather than restarting
    /// at zero with a freshly created view.
    func chatTurn(slug: String, project: String?) -> ChatTurn? {
        liveTurns[Self.liveKey(slug: slug, project: project)]
    }

    /// Register a turn. Callers pass the identity they CAPTURED at send
    /// time and hand the same one back when the turn ends, however it
    /// ends — a marker cleared by whatever identity happens to be open
    /// would strand the row of a chat the user has since left.
    func beginTurn(slug: String, project: String?,
                   startedAt: Date, task: Task<Void, Never>) {
        liveTurns[Self.liveKey(slug: slug, project: project)] =
            ChatTurn(startedAt: startedAt, task: task)
    }

    func endTurn(slug: String, project: String?) {
        liveTurns.removeValue(forKey: Self.liveKey(slug: slug, project: project))
    }

    /// Stop button. Reaches the turn through the manager rather than a
    /// view-held handle, so it works from a `ChatView` created AFTER
    /// the send — which is what the user gets back when they return to
    /// a chat they left mid-turn.
    func stopChatTurn(slug: String, project: String?) {
        liveTurns[Self.liveKey(slug: slug, project: project)]?.task.cancel()
    }

    /// Deliver a reply to the chat that asked for it.
    ///
    /// Re-reads the chat FROM DISK rather than writing a snapshot the
    /// caller was holding: the view that sent the message may have been
    /// destroyed by the router mid-turn, and its `@State` still reads
    /// back the values it held when it died — so a snapshot-based
    /// delivery writes a stale conversation over the live file, and the
    /// reply lands in a state box nothing renders. Disk is the
    /// authority, and this is the ONLY path a reply takes, whether or
    /// not the sending view survived.
    ///
    /// A chat deleted while its turn was in flight has nowhere to put
    /// the reply, and must not be resurrected by it.
    func appendAssistantReply(_ message: ChatMessage,
                              slug: String, project: String?,
                              outcome: ChatTurnOutcome? = nil) {
        guard var chat = loadChat(slug: slug, project: project) else { return }
        chat.messages.append(message)
        saveChat(chat)
        if let outcome { noteTurnOutcome(outcome, slug: slug, project: project) }
        else { announceMessagesChanged(slug: slug, project: project) }
    }

    /// Record how a turn ended, and wake the open chat so it can say
    /// so. Posting on this path too means an error or a Stop reaches
    /// the pane by the same route a reply does.
    ///
    /// Addressed to the CHAT exactly as the reply is: a conversation
    /// deleted or moved away mid-turn takes its outcome with it.
    /// Without the guard the banner is filed under a (project, slug)
    /// the chat no longer owns, and surfaces under whatever chat next
    /// takes that name.
    func noteTurnOutcome(_ outcome: ChatTurnOutcome,
                         slug: String, project: String?) {
        guard loadChat(slug: slug, project: project) != nil else { return }
        turnOutcomes[Self.liveKey(slug: slug, project: project)] = outcome
        announceMessagesChanged(slug: slug, project: project)
    }

    /// Read and clear — an outcome describes one turn and must not be
    /// shown twice, nor follow the user into the next conversation.
    func consumeTurnOutcome(slug: String, project: String?) -> ChatTurnOutcome? {
        turnOutcomes.removeValue(forKey: Self.liveKey(slug: slug, project: project))
    }

    func clearTurnOutcome(slug: String, project: String?) {
        turnOutcomes.removeValue(forKey: Self.liveKey(slug: slug, project: project))
    }

    private func announceMessagesChanged(slug: String, project: String?) {
        NotificationCenter.default.post(
            name: .sipChatMessagesChanged, object: nil,
            userInfo: ["slug": slug, "project": project as Any])
    }

    func reload() {
        let fm = FileManager.default
        let dir = SipaiPaths.dataDir
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            rootChats = []; projectChats = [:]; return
        }
        var roots: [StoredChat] = []
        var perProject: [String: [StoredChat]] = [:]

        for url in entries {
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                // Project folder — every .json inside is a chat
                let slug = name
                if let inner = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) {
                    for f in inner where f.pathExtension == "json" {
                        if let chat = Self.loadChatFile(at: f) { perProject[slug, default: []].append(chat) }
                    }
                }
            } else if url.pathExtension == "json" {
                if name == "meta.json" || name == "config.json" || name == "usage.json" { continue }
                if let chat = Self.loadChatFile(at: url) { roots.append(chat) }
            }
        }

        // Newest-first on the same value the row PRINTS (`activityAt`),
        // not on mtime: a reply landing minutes after the question, a
        // rename, or a model change all bump mtime without the user
        // having said anything.
        roots.sort { $0.activityAt > $1.activityAt }
        for k in perProject.keys {
            perProject[k]?.sort { $0.activityAt > $1.activityAt }
        }
        self.rootChats = roots
        self.projectChats = perProject
    }

    private static func loadChatFile(at url: URL) -> StoredChat? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            var chat = try JSONDecoder().decode(StoredChat.self, from: data)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let m = attrs?[.modificationDate] as? Date { chat.modified = m }
            return chat
        } catch {
            return nil
        }
    }

    /// Load a chat by slug + project. Returns nil if missing.
    func loadChat(slug: String, project: String?) -> StoredChat? {
        Self.loadChatFile(at: SipaiPaths.chatStateFile(slug: slug, project: project))
    }

    /// Save a chat to disk. Generates a unique slug if needed.
    @discardableResult
    func saveChat(_ chat: StoredChat) -> StoredChat {
        var c = chat
        if c.slug.isEmpty {
            c.slug = uniqueSlug(SipaiPaths.slugify(c.title), project: c.project)
        }
        if let proj = c.project {
            try? FileManager.default.createDirectory(
                at: SipaiPaths.dataDir.appendingPathComponent(proj, isDirectory: true),
                withIntermediateDirectories: true)
        }
        let url = SipaiPaths.chatStateFile(slug: c.slug, project: c.project)
        var payload: [String: Any] = [
            "last_response_id": c.lastResponseId as Any,
            "title": c.title,
            "slug": c.slug,
            "project": c.project as Any,
            "model": c.model as Any,
            "messages": c.messages.map { msg -> [String: Any] in
                var d: [String: Any] = ["role": msg.role, "content": msg.content]
                if let m = msg.model { d["model"] = m }
                if let t = msg.time { d["time"] = t }
                if let f = msg.files { d["files"] = f }
                // Per-turn usage must survive reload — the "…k tokens"
                // counter sums these on load (ChatView), and the decoder
                // reads the key back.
                if let tok = msg.tokens { d["tokens"] = tok }
                return d
            },
        ]
        // Omitted rather than written null when unknown, so the
        // byte-identical check below still recognises an untouched
        // legacy chat and leaves its mtime alone.
        if let at = c.lastUserMessageAt {
            payload["last_user_message_at"] = ChatDateFormat.string(from: at)
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]) {
            // Skip byte-identical rewrites. ChatView persists the outgoing
            // chat on every switch; writing unchanged bytes would bump the
            // file's mtime, and reload() sorts newest-first — or merely
            // LEAVING a chat would hoist it to the top, reordering the
            // sidebar under the cursor. sortedKeys keeps serialization
            // deterministic so this comparison is meaningful.
            if let existing = try? Data(contentsOf: url), existing == data {
                return c
            }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                // Callers treat the returned chat as persisted, so a
                // swallowed failure must at least leave a trace — and
                // destructive follow-ups (moveChat) re-verify the file
                // on disk before deleting the source.
                NSLog("SipAI saveChat: failed to write %@: %@",
                      url.path, error.localizedDescription)
            }
        }
        c.modified = Date()
        reload()
        return c
    }

    func deleteChat(slug: String, project: String?) {
        // The turn dies with the chat. Left alone, the (project, slug)
        // key outlives the file: `uniqueSlug` checks only disk, so a
        // new chat given the same title mints the SAME slug and
        // inherits the spinner, a Stop wired to a dead conversation —
        // and, when the in-flight task delivers, the deleted
        // conversation's reply.
        teardownTurn(slug: slug, project: project)
        let url = SipaiPaths.chatStateFile(slug: slug, project: project)
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    /// Cancel and forget a chat's live turn, and drop any unconsumed
    /// outcome. For delete and move, where the (project, slug) key is
    /// about to stop meaning this conversation.
    private func teardownTurn(slug: String, project: String?) {
        let key = Self.liveKey(slug: slug, project: project)
        liveTurns[key]?.task.cancel()
        liveTurns.removeValue(forKey: key)
        turnOutcomes.removeValue(forKey: key)
    }

    func renameChat(slug: String, project: String?, newTitle: String) {
        guard var chat = loadChat(slug: slug, project: project) else { return }
        chat.title = newTitle
        saveChat(chat)
    }

    /// Move a chat between the root scope and a project (or between two
    /// projects). Returns the stored chat at its new location — the slug
    /// changes when the target scope already has one by that name — or
    /// nil when there was nothing to do.
    @discardableResult
    func moveChat(slug: String, project: String?,
                  toProject: String?) -> StoredChat? {
        guard project != toProject,
              var chat = loadChat(slug: slug, project: project) else {
            return nil
        }
        // Same teardown as deleteChat, same reason: this vacates the
        // old (project, slug) for reuse, and the in-flight reply could
        // not follow the chat anyway — delivery re-reads the OLD key
        // and finds nothing. Cancelling is the honest version of that.
        teardownTurn(slug: slug, project: project)
        let oldURL = SipaiPaths.chatStateFile(slug: slug, project: project)
        chat.project = toProject
        if FileManager.default.fileExists(
            atPath: SipaiPaths.chatStateFile(slug: chat.slug,
                                             project: toProject).path) {
            chat.slug = uniqueSlug(chat.slug, project: toProject)
        }
        let saved = saveChat(chat)   // writes the new location
        // saveChat swallows write failures (every autosave routes through
        // it) — but a move is destructive, so verify the destination
        // actually landed before removing the source. Otherwise keep the
        // original file and report nothing done.
        let newURL = SipaiPaths.chatStateFile(slug: saved.slug,
                                              project: saved.project)
        guard FileManager.default.fileExists(atPath: newURL.path) else {
            reload()
            return nil
        }
        try? FileManager.default.removeItem(at: oldURL)
        reload()
        return saved
    }

    private func uniqueSlug(_ base: String, project: String?) -> String {
        var slug = base
        var counter = 2
        while FileManager.default.fileExists(atPath: SipaiPaths.chatStateFile(slug: slug, project: project).path) {
            slug = "\(base)-\(counter)"
            counter += 1
        }
        return slug
    }
}
