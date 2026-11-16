// The wiring of an agent session's attachment chips, READ off the views
// and the string catalog (see run.sh). Never restates a rule the code
// holds: it asks the code where the rule lives.

import Foundation

var failures = 0
var checks = 0

func check(_ label: String, _ condition: @autoclosure () -> Bool) {
    checks += 1
    if condition() {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label)")
        failures += 1
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "../..",
               isDirectory: true)
func read(_ relative: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)) ?? ""
}

let composer = read("SipAI/Views/Chat/AgentComposer.swift")
let view = read("SipAI/Views/Chat/AgentSessionView.swift")
let input = read("SipAI/Views/Chat/MessageInput.swift")
let chatView = read("SipAI/Views/Chat/ChatView.swift")
let appState = read("SipAI/Models/AppState.swift")
let catalog = read("SipAI/Resources/Localizable.xcstrings")
check("the sources were found", !composer.isEmpty && !view.isEmpty && !input.isEmpty && !catalog.isEmpty)

/// The body of `func name(` up to the next `func ` at the same indent.
func body(of name: String, in text: String) -> String {
    guard let start = text.range(of: "func \(name)(") else { return "" }
    let rest = text[start.upperBound...]
    let end = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    func ")
    return String(rest[..<(end?.lowerBound ?? rest.endIndex)])
}

print("  · the composer: one look in every mode")
check("the chip strip is drawn whatever the mode",
      composer.contains("if !attachments.isEmpty, let onRemoveAttachment {")
        && !composer.contains("if chatOnlyActive, !attachments.isEmpty, let onRemoveAttachment"))
check("… through the chat page's chip row, each chip stating what the mode in force sends",
      composer.contains("AttachmentChipRow(items: attachments.map { $0.chipItem(agentName: agentName, chatOnly: chatOnlyActive) }"))
check("a drop on the text box attaches in every mode — AppKit never types the path in",
      composer.contains("onDropFiles: onStageFiles,")
        && !composer.contains("onDropFiles: chatOnlyActive ? onStageFiles : nil"))
check("a drop on the card around it attaches in every mode",
      composer.contains(".onDrop(of: [.fileURL], isTargeted: $dropTargeted)")
        && !composer.contains("chatOnlyActive ? $dropTargeted"))
check("the card lights up under a drag in every mode",
      composer.contains(".stroke(dropTargeted ? SipDesign.blue : SipDesign.borderLight,"))
let addFiles = body(of: "addFiles", in: composer)
check("the + stages what it picks through the one door a drop takes",
      addFiles.contains("onStageFiles(panel.urls)"))
check("… and never types a path into the message",
      !addFiles.contains("draft =") && !composer.contains("Selected paths are inserted"))
check("… offering folders where the agent reads them itself",
      addFiles.contains("panel.canChooseDirectories = !chatOnlyActive"))
check("the + reads Attach file in every mode",
      !composer.contains("String(localized: \"Add file\""))
check("an attached file alone can be sent in every mode",
      composer.contains("(hasText || !attachments.isEmpty)"))
check("what an attach refused is said in every mode",
      composer.contains("if let notice = attachmentNotice {"))
check("a scheduled task takes the files' paths into its prompt",
      composer.contains("AgentAttachment.taskPrompt(draft, with: attachments)"))

print("  · the session view: what goes with the message")
check("staged files are the agent composer's own kind",
      view.contains("@State private var stagedAttachments: [AgentAttachment] = []"))
check("the + and a drop stage by the mode's rule",
      view.contains("AgentAttachment.staging(urls, onto: stagedAttachments,")
        && view.contains("chatOnly: chatOnlyInForce,"))
let handleSend = body(of: "handleSend", in: view)
check("a send carries the staged files in every mode",
      handleSend.contains("let attaching = stagedAttachments")
        && !handleSend.contains("sending.chatOnly ? stagedAttachments : []"))
check("outside Chat only the paths ride after the words",
      handleSend.contains("outgoingText(for: typed, chatOnly: sending.chatOnly)")
        && view.contains("AttachmentInline.appendingReferences(stagedAttachments.map(\\.reference),"))
check("files staged as paths are read the moment Chat only is in force for their session — the chip, the gate, a session opened",
      view.contains(".onChange(of: stagedPathsAwaitChatOnly)")
        && view.contains("chatOnlyInForce && transcriptKey != nil && loadedDraftKey == transcriptKey")
        && !view.contains(".onChange(of: chatOnlyInForce)"))
check("an attach note is shown only in the mode it was made under",
      view.contains("@State private var attachmentNotice: String? = nil")
        && view.contains("@State private var attachmentNoticeIsChatOnly = false")
        && view.contains("attachmentNotice: attachmentNoticeIsChatOnly == chatOnlyInForce ? attachmentNotice : nil,"))
check("… the mode noted wherever a note is made",
      view.components(separatedBy: "attachmentNotice = attachNotice(").count - 1 == 2
        && view.contains("attachmentNoticeIsChatOnly = chatOnlyInForce")
        && view.contains("attachmentNoticeIsChatOnly = true"))
check("… and a Chat only send never goes out with a path the agent cannot open",
      handleSend.contains("if sending.chatOnly, !loadStagedFilesForChatOnly() { return }"))
check("a sent message clears the chips — and so does one held while a turn runs",
      handleSend.contains("clearSentComposer(clearsAttachments: !attaching.isEmpty)")
        && handleSend.components(separatedBy: "clearSentComposer(clearsAttachments: !attaching.isEmpty)").count - 1 == 2
        && body(of: "clearSentComposer", in: view).contains("stagedAttachments = []"))
check("a scheduled task created from the composer clears them too",
      view.range(of: "onScheduleCreated: {").map {
          view[$0.upperBound...].prefix(400).contains("stagedAttachments = []")
      } ?? false)
check("the chips survive a detour, stashed on every change",
      view.contains(".onChange(of: stagedAttachments) { _, _ in stashComposerAttachments() }")
        && appState.contains("private var composerAttachments: [String: [AgentAttachment]] = [:]"))
check("the paperclip line rides both the history row and the live row",
      view.contains("attachedFiles: item.attachedFiles") && view.contains("attachedFiles: event.attachedFiles"))

print("  · the chip row is the chat page's")
check("the row draws chip items", input.contains("struct AttachmentChipRow: View {\n    let items: [AttachmentChipItem]"))
check("the chat page still hands it its own files", chatView.contains("AttachmentChipRow(attachments:"))
check("the chip's name width and ✕ follow the font size",
      input.contains(".frame(maxWidth: 160 * frameRatio, alignment: .leading)")
        && input.contains(".frame(width: 14 * frameRatio, height: 14 * frameRatio)"))

print("  · the strings")
func entry(_ key: String) -> Substring? {
    let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    guard let r = catalog.range(of: "\"\(escaped)\" : {") else { return nil }
    return catalog[r.upperBound...].prefix(900)
}
for key in ["%@ — %@ reads the file itself",
            "%@ — %@ reads the folder itself",
            "%@ is a folder. Chat only attaches files, not folders.",
            "Select files or folders to attach. %@ reads them itself.",
            "Attach file"] {
    check("catalog: \"\(key.prefix(52))\" has a zh-Hans value", entry(key)?.contains("\"zh-Hans\"") == true)
}
for gone in ["Add file",
             "Selected paths are inserted into your message for %@ to read",
             "%@ — images can only be attached in Chat only mode."] {
    check("catalog: the retired \"\(gone.prefix(48))\" is gone", entry(gone) == nil)
}

print("\n  \(checks - failures)/\(checks) wiring checks passed")
exit(failures == 0 ? 0 : 1)
