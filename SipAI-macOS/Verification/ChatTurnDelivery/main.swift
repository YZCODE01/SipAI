// Headless verification for chat-turn delivery. See run.sh.
//
// Not part of the app target — this directory sits outside SipAI/.
//
// The rule this pins: a chat turn OUTLIVES the pane it was started
// from, so its result must be addressed to the CHAT and must be
// written by re-reading the file — never by a snapshot the sender was
// holding.
//
// The centre-pane router destroys ChatView on every detour to a
// session or a note. Measured on a SwiftUI probe of that teardown:
// the unstructured send Task is NOT cancelled, `.onChange` does NOT
// fire on the way out, and the destroyed view's `@State` still reads
// back the values it held when it died. So a completion handler that
// asks "is my chat still the open one?" gets YES from a view nobody is
// looking at, appends the reply to a state box that renders nowhere,
// and writes that stale conversation over the live file — losing the
// reply outright once the live pane saves next.
//
// Two passes:
//
//   1. Behavioural, against the REAL ChatManager over a throwaway data
//      directory: delivery re-reads from disk, a deleted chat is not
//      resurrected, turns and outcomes are keyed per (slug, project),
//      Stop reaches the task, and an outcome is consumed exactly once.
//
//   2. Structural, over the REAL ChatView.swift: the view must hold no
//      send-task handle, must not decide delivery by comparing its own
//      `loadedChatSlug`, must derive `sending` from the manager, and
//      must refuse to persist a chat whose turn is in flight. Those
//      four are the shape of the bug, and none of them is reachable
//      headlessly — ChatView needs a window.
//
// Run it after any change to the chat send path.

import Foundation

let sourceRoot = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

var failures: [String] = []

func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        print("  ok    \(label)")
    } else {
        let extra = detail()
        print("  FAIL  \(label)" + (extra.isEmpty ? "" : " — \(extra)"))
        failures.append(label)
    }
}

let fm = FileManager.default

func resetFixture() {
    try? fm.removeItem(at: SipaiPaths.root)
    try? fm.createDirectory(at: SipaiPaths.root, withIntermediateDirectories: true)
}

func contents(_ slug: String, _ project: String? = nil) -> [String] {
    guard let data = try? Data(contentsOf: SipaiPaths.chatStateFile(slug: slug, project: project)),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let msgs = obj["messages"] as? [[String: Any]] else { return [] }
    return msgs.map { ($0["content"] as? String) ?? "?" }
}

@MainActor
func behavioural() async {
    print("\n1. Delivery, against the real ChatManager")
    resetFixture()
    let chats = ChatManager()

    // A chat as it stands the moment the user hits send.
    let seeded = chats.saveChat(StoredChat(
        slug: "", title: "Question about kettles", model: "gpt-5",
        messages: [ChatMessage(role: "user", content: "u1")],
        lastUserMessageAt: Date(timeIntervalSince1970: 1_000_000)))
    let slug = seeded.slug

    // --- Disk is the authority, not a caller's snapshot.
    chats.appendAssistantReply(ChatMessage(role: "assistant", content: "a1"),
                               slug: slug, project: nil)
    check("a reply is appended to the stored conversation",
          contents(slug) == ["u1", "a1"], "\(contents(slug))")

    // Something else moves the file on while a turn is in flight — the
    // exact case a snapshot-based write would silently undo.
    if var moved = chats.loadChat(slug: slug, project: nil) {
        moved.messages.append(ChatMessage(role: "user", content: "u2"))
        chats.saveChat(moved)
    }
    chats.appendAssistantReply(ChatMessage(role: "assistant", content: "a2"),
                               slug: slug, project: nil)
    check("delivery re-reads the file rather than writing a snapshot",
          contents(slug) == ["u1", "a1", "u2", "a2"], "\(contents(slug))")

    // --- Fields the round-trip must not drop.
    let reloaded = chats.loadChat(slug: slug, project: nil)
    check("the round-trip keeps the chat's model",
          reloaded?.model == "gpt-5", "\(reloaded?.model ?? "nil")")
    check("the round-trip keeps last_user_message_at",
          reloaded?.lastUserMessageAt == Date(timeIntervalSince1970: 1_000_000),
          "\(String(describing: reloaded?.lastUserMessageAt))")

    // --- A chat deleted mid-turn must not be resurrected by its reply.
    let doomed = chats.saveChat(StoredChat(slug: "", title: "Doomed",
                                           messages: [ChatMessage(role: "user", content: "u")]))
    chats.deleteChat(slug: doomed.slug, project: nil)
    chats.appendAssistantReply(ChatMessage(role: "assistant", content: "late"),
                               slug: doomed.slug, project: nil)
    check("a chat deleted mid-turn is not resurrected by its reply",
          !fm.fileExists(atPath: SipaiPaths.chatStateFile(slug: doomed.slug, project: nil).path))

    // --- The open pane hears about it.
    var heard: [String: String] = [:]
    let token = NotificationCenter.default.addObserver(
        forName: .sipChatMessagesChanged, object: nil, queue: .main) { note in
            heard["slug"] = note.userInfo?["slug"] as? String
            heard["project"] = note.userInfo?["project"] as? String ?? ""
        }
    defer { NotificationCenter.default.removeObserver(token) }

    chats.appendAssistantReply(ChatMessage(role: "assistant", content: "a3"),
                               slug: slug, project: nil)
    check("a delivered reply announces its chat by slug + project",
          heard["slug"] == slug && heard["project"] == "", "\(heard)")

    heard = [:]
    chats.noteTurnOutcome(.failed("boom"), slug: slug, project: nil)
    check("a turn that fails announces on the same channel",
          heard["slug"] == slug, "\(heard)")

    print("\n2. Turn bookkeeping")

    // --- Keyed per (slug, project): two chats can share a slug.
    try? fm.createDirectory(at: SipaiPaths.root.appendingPathComponent("work"),
                            withIntermediateDirectories: true)
    let idle = Task<Void, Never> { while !Task.isCancelled { await Task.yield() } }
    chats.beginTurn(slug: "notes", project: nil, startedAt: Date(), task: idle)
    check("a turn marks the chat it was started on",
          chats.isChatInFlight(slug: "notes", project: nil))
    check("a same-named chat in a group is NOT marked",
          !chats.isChatInFlight(slug: "notes", project: "work"))

    let started = Date(timeIntervalSince1970: 500_000)
    chats.beginTurn(slug: "kettle", project: nil, startedAt: started, task: idle)
    check("the turn carries its own start time, not the pane's",
          chats.chatTurn(slug: "kettle", project: nil)?.startedAt == started)

    // --- Stop reaches the task from the manager.
    let stoppable = Task<Void, Never> {
        while !Task.isCancelled { await Task.yield() }
    }
    chats.beginTurn(slug: "stopme", project: nil, startedAt: Date(), task: stoppable)
    chats.stopChatTurn(slug: "stopme", project: nil)
    await stoppable.value
    check("Stop cancels the turn through the manager", stoppable.isCancelled)

    chats.endTurn(slug: "notes", project: nil)
    check("ending a turn clears the sidebar's activity flag",
          !chats.isChatInFlight(slug: "notes", project: nil))
    check("ending one chat's turn leaves another's alone",
          chats.isChatInFlight(slug: "kettle", project: nil))
    idle.cancel()

    print("\n3. Outcomes")
    // An outcome is addressed to the CHAT, exactly as a reply is, so
    // the fixture needs a real one on disk.
    let kettle = chats.saveChat(StoredChat(slug: "", title: "Kettle outcomes",
                                           messages: [ChatMessage(role: "user", content: "u")]))
    chats.noteTurnOutcome(.truncated, slug: kettle.slug, project: nil)
    check("an outcome is stored against its chat",
          chats.consumeTurnOutcome(slug: kettle.slug, project: nil) == .truncated)
    check("and is consumed exactly once — never shown twice",
          chats.consumeTurnOutcome(slug: kettle.slug, project: nil) == nil)
    chats.noteTurnOutcome(.failed("nope"), slug: kettle.slug, project: nil)
    check("an outcome does not leak onto another chat",
          chats.consumeTurnOutcome(slug: kettle.slug, project: "work") == nil)
    chats.clearTurnOutcome(slug: kettle.slug, project: nil)
    check("a fresh send clears what the previous turn left unsaid",
          chats.consumeTurnOutcome(slug: kettle.slug, project: nil) == nil)
    chats.deleteChat(slug: kettle.slug, project: nil)
    chats.noteTurnOutcome(.failed("late"), slug: kettle.slug, project: nil)
    check("an outcome for a chat that no longer exists is dropped",
          chats.consumeTurnOutcome(slug: kettle.slug, project: nil) == nil)

    print("\n4. Delete and move tear the turn down")
    // The (project, slug) key must not outlive the file: `uniqueSlug`
    // checks only disk, so a new chat given the same title mints the
    // SAME slug — and would inherit the spinner, a Stop wired to a
    // dead conversation, and the deleted conversation's reply when the
    // in-flight task delivers.
    let doomed2 = chats.saveChat(StoredChat(slug: "", title: "Doomed II",
                                            messages: [ChatMessage(role: "user", content: "q")]))
    let victim = Task<Void, Never> { while !Task.isCancelled { await Task.yield() } }
    chats.beginTurn(slug: doomed2.slug, project: nil, startedAt: Date(), task: victim)
    chats.noteTurnOutcome(.truncated, slug: doomed2.slug, project: nil)
    chats.deleteChat(slug: doomed2.slug, project: nil)
    await victim.value
    check("deleting a chat cancels its live turn", victim.isCancelled)
    check("deleting a chat clears its in-flight flag",
          !chats.isChatInFlight(slug: doomed2.slug, project: nil))
    let successor = chats.saveChat(StoredChat(slug: "", title: "Doomed II",
                                              messages: [ChatMessage(role: "user", content: "fresh")]))
    check("a successor chat re-mints the vacated slug", successor.slug == doomed2.slug,
          successor.slug)
    check("and inherits neither spinner nor outcome",
          !chats.isChatInFlight(slug: successor.slug, project: nil)
              && chats.consumeTurnOutcome(slug: successor.slug, project: nil) == nil)

    let mover = chats.saveChat(StoredChat(slug: "", title: "Mover",
                                          messages: [ChatMessage(role: "user", content: "m")]))
    let movingTask = Task<Void, Never> { while !Task.isCancelled { await Task.yield() } }
    chats.beginTurn(slug: mover.slug, project: nil, startedAt: Date(), task: movingTask)
    _ = chats.moveChat(slug: mover.slug, project: nil, toProject: "work")
    await movingTask.value
    check("moving a chat cancels the turn keyed to its old home", movingTask.isCancelled)
    check("the old key is vacated by the move",
          !chats.isChatInFlight(slug: mover.slug, project: nil))

    try? fm.removeItem(at: SipaiPaths.root)
}

// MARK: - Structural pass over the real view

func structural() {
    print("\n4. ChatView, read from source")
    let path = sourceRoot + "/SipAI/Views/Chat/ChatView.swift"
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
        check("ChatView.swift is readable", false, path)
        return
    }
    // CODE only. Every rule below is also DESCRIBED in a comment a line
    // or two from the code that keeps it — the reason it is there is
    // half the value — and a scan that reads prose reports the
    // explanation of a bug as the bug. Whole-line comments only, so a
    // `https://` inside a string literal survives.
    let src = raw.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")

    // The whole bug in one line: a handle in @State dies with the view,
    // so Stop from a view created after the send stops nothing.
    check("ChatView holds no send-task handle in @State",
          !src.contains("@State private var sendTask"))

    // A destroyed view's @State still reads back its last values, so
    // this comparison answers YES for a pane nobody is looking at.
    check("delivery is not decided by comparing the view's own identity",
          !src.contains("loadedChatSlug == targetSlug"))

    check("the reply is delivered through the manager",
          src.contains("chats.appendAssistantReply("))
    check("Stop routes through the manager",
          src.contains("chats.stopChatTurn("))
    check("the turn is registered with the manager",
          src.contains("chats.beginTurn(") && src.contains("chats.endTurn("))

    // Derived, so returning to a chat mid-turn still shows the turn.
    check("`sending` is derived from the manager, not stored",
          !src.contains("@State private var sending")
            && src.contains("chats.isChatInFlight(slug: slug, project: loadedChatProject)"))
    check("the turn clock reads the turn's own start time",
          !src.contains("@State private var turnStartedAt")
            && src.contains("chats.chatTurn(slug: slug, project: loadedChatProject)?.startedAt"))

    // Without this the reply lands on disk and the next save from the
    // pane — a switch, a teardown, a second send — writes over it.
    if let range = src.range(of: "private func persistChat(") {
        let body = String(src[range.lowerBound...].prefix(1400))
        check("persistChat refuses to write a chat whose turn is in flight",
              body.contains("chats.isChatInFlight(slug: slug, project: project)"))
    } else {
        check("persistChat is present", false)
    }

    // The pane must not clear a flag that describes the chat.
    if let range = src.range(of: "private func reloadFromAppState()") {
        let body = String(src[range.lowerBound...].prefix(2600))
        check("a chat switch no longer clears the turn flag",
              !body.contains("sending = false"))
    }

    check("an open chat re-reads itself when the manager delivers",
          src.contains(".sipChatMessagesChanged"))
}

await behavioural()
structural()

print("")
if failures.isEmpty {
    print("All chat-turn delivery checks passed.")
} else {
    print("\(failures.count) FAILED:")
    for f in failures { print("  - \(f)") }
    exit(1)
}
