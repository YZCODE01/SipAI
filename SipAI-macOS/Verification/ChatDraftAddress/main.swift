// A chat's unsent text is filed under the chat's ADDRESS — its group and
// its slug — and both halves are reused: a slug is minted from the title,
// so a deleted chat's slug goes to the next chat opening with the same
// words, and a moved chat's old address is free for the next chat given
// it. Before this, a deleted chat's half-written message appeared in the
// next such chat's composer right after its first send, and a chat moved
// from the sidebar lost its half-written message to its old address.
//
// 1. the store (`AppState`'s composer-draft section, EXTRACTED from the
//    shipping file): a move carries the text and leaves nothing behind,
//    replacing whatever the new address held; a group's deletion takes
//    its chats' text and its new-chat slot, and nothing else;
// 2. the wiring, read off ChatView.swift and ChatListView.swift: a new
//    chat's first save re-keys onto its minted address BEFORE publishing
//    it, every address change goes through one re-key, a chat whose file
//    is gone files no text, and the sidebar's move / delete / group
//    delete carry or drop it.
//
// Nothing here is part of the app target.

import Foundation

var failures: [String] = []
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("  ok    \(label)") }
    else {
        let extra = detail()
        print("  FAIL  \(label)\(extra.isEmpty ? "" : " — \(extra)")")
        failures.append(label)
    }
}
func section(_ t: String) { print("\n\(t)") }

let sourceRoot = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
func source(_ rel: String) -> String {
    (try? String(contentsOf: sourceRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

// MARK: - 1. The store

section("1. the draft store (AppState, extracted)")
MainActor.assumeIsolated {
    let app = AppState()
    let root = { (slug: String?) in AppState.chatDraftKey(slug: slug, project: nil) }
    let work = { (slug: String?) in AppState.chatDraftKey(slug: slug, project: "work") }
    let work2 = { (slug: String?) in AppState.chatDraftKey(slug: slug, project: "work-2") }

    check("a chat's key is its group and its slug",
          root("hello") == "chat:/hello" && work("hello") == "chat:work/hello")
    check("the unsent new chat has a slot of its own per group",
          root(nil) == "chat:/" && work("") == "chat:work/")

    app.setComposerDraft("half-written", for: root("hello"))
    app.moveComposerDraft(from: root("hello"), to: work("hello"))
    check("a move carries the text to the new address", app.composerDraft(for: work("hello")) == "half-written")
    check("…and leaves nothing at the old one", app.composerDraft(for: root("hello")).isEmpty)

    app.setComposerDraft("a deleted chat's words", for: root("greeting"))
    app.setComposerDraft("", for: root("other"))
    app.moveComposerDraft(from: root("other"), to: root("greeting"))
    check("a move REPLACES what the new address held — an empty box stays empty",
          app.composerDraft(for: root("greeting")).isEmpty,
          app.composerDraft(for: root("greeting")))

    app.setComposerDraft("mine", for: root("same"))
    app.moveComposerDraft(from: root("same"), to: root("same"))
    check("a move onto the same address keeps the text", app.composerDraft(for: root("same")) == "mine")

    app.setComposerDraft("in work", for: work("a"))
    app.setComposerDraft("new chat in work", for: work(nil))
    app.setComposerDraft("in work-2", for: work2("a"))
    app.setComposerDraft("at root", for: root("a"))
    app.dropComposerDrafts(inChatGroup: "work")
    check("deleting a group drops its chats' text", app.composerDraft(for: work("a")).isEmpty
            && app.composerDraft(for: work("hello")).isEmpty)
    check("…and its new-chat slot", app.composerDraft(for: work(nil)).isEmpty)
    check("…and nothing of a group whose name merely starts the same",
          app.composerDraft(for: work2("a")) == "in work-2")
    check("…nor of the root chats", app.composerDraft(for: root("a")) == "at root")
}

// MARK: - 2. The wiring

section("2. the wiring (read off the sources)")

let chatView = source("SipAI/Views/Chat/ChatView.swift")
func body(of signature: String, in text: String) -> String? {
    guard let start = text.range(of: signature) else { return nil }
    // To the next declaration at the same indentation.
    let rest = text[start.upperBound...]
    let end = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    func ") ?? rest.range(of: "\n}")
    return String(text[start.lowerBound..<(end?.lowerBound ?? text.endIndex)])
}

if let persist = body(of: "private func persistChat(slug: String, project: String?) -> String", in: chatView),
   let mint = persist.range(of: "if slug.isEmpty {") {
    let firstSave = String(persist[mint.lowerBound...])
    let rekey = firstSave.range(of: "rekeyComposerDraft(to: AppState.chatDraftKey(slug: saved.slug")
    let publish = firstSave.range(of: "appState.openChatSlug = saved.slug")
    check("a new chat's first save re-keys its text onto the minted address",
          rekey != nil, "no re-key in the first-save branch")
    check("…BEFORE publishing the address (the reload it triggers must find this chat's text)",
          rekey != nil && publish != nil && rekey!.lowerBound < publish!.lowerBound)
} else {
    check("persistChat's first-save branch was found", false)
}
if let rekey = body(of: "private func rekeyComposerDraft(to newKey: String)", in: chatView) {
    check("the re-key CARRIES the live text and clears the old address",
          rekey.contains("stashComposerDraft()") && rekey.contains(#"appState.setComposerDraft("", for: previousKey)"#))
} else {
    check("ChatView has one re-key helper", false)
}
check("every address change goes through it — a move, a branch, a first save",
      chatView.components(separatedBy: "rekeyComposerDraft(to: AppState.chatDraftKey(").count - 1 == 3)
check("no hand-rolled copy of the re-key is left", !chatView.contains("previousDraftKey"))
if let sync = body(of: "private func syncComposerDraft()", in: chatView) {
    check("a chat whose file is gone files no text under its old address",
          sync.contains("appState.setComposerDraft(loadedChatIsGone ? \"\" : draft, for: old)"))
}
if let gone = chatView.range(of: "private var loadedChatIsGone: Bool") {
    let text = String(chatView[gone.lowerBound...].prefix(400))
    check("…judged by the chat's own file, and never true for the unsent new chat",
          text.contains("SipaiPaths.chatStateFile(slug: slug, project: loadedChatProject)")
            && text.contains("guard let slug = loadedChatSlug, !slug.isEmpty else { return false }"))
} else {
    check("loadedChatIsGone exists", false)
}

let list = source("SipAI/Views/Sidebar/ChatListView.swift")
if let move = body(of: "private func move(to targetProject: String?)", in: list) {
    let carry = move.range(of: "appState.moveComposerDraft(")
    let route = move.range(of: "appState.openChatSlug = moved.slug")
    check("the sidebar's move carries the text to the chat's new address",
          carry != nil && move.contains("to: AppState.chatDraftKey(slug: moved.slug, project: moved.project)"))
    check("…before routing the open chat there", carry != nil && route != nil && carry!.lowerBound < route!.lowerBound)
} else {
    check("the sidebar's move was found", false)
}
if let delete = body(of: "private func deleteChat()", in: list) {
    check("the sidebar's delete drops the chat's text",
          delete.contains(#"appState.setComposerDraft("#) && delete.contains("AppState.chatDraftKey(slug: chat.slug, project: chat.project)"))
}
if let group = body(of: "private func deleteProject(_ project: ProjectInfo)", in: list) {
    check("deleting a chat group drops its chats' text",
          group.contains("appState.dropComposerDrafts(inChatGroup: project.slug)"))
}

print("")
if failures.isEmpty {
    print("PASS")
} else {
    print("FAILED (\(failures.count)):")
    for f in failures { print("  - \(f)") }
    exit(1)
}
