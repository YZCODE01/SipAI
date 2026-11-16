// The rules behind an agent session's attachment chips, driven over
// throwaway files: compiled with the REAL AttachmentInline.swift and
// ChatAttachment.swift (see run.sh). Never touches an agent's store.

import AppKit
import Foundation

var failures = 0
var checks = 0

func check(_ label: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition() {
        print("  ok   \(label)")
    } else {
        let d = detail()
        print("  FAIL \(label)" + (d.isEmpty ? "" : " — \(d)"))
        failures += 1
    }
}

let fm = FileManager.default
let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("sipai-agentfilechips-\(UUID().uuidString.prefix(8))", isDirectory: true)
try! fm.createDirectory(at: scratch, withIntermediateDirectories: true)

@discardableResult
func write(_ name: String, _ data: Data) -> URL {
    let url = scratch.appendingPathComponent(name)
    try! data.write(to: url)
    return url
}
func writeText(_ name: String, _ text: String) -> URL { write(name, Data(text.utf8)) }
func folder(_ name: String) -> URL {
    let url = scratch.appendingPathComponent(name, isDirectory: true)
    try! fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A real one-pixel PNG: Chat only decodes what it stages.
let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

let notes = writeText("notes.md", "# Notes\nALPHA LINE\n")
let src = folder("src")
let blob = write("blob.zip", Data([0x50, 0x4b, 0x03, 0x04, 0, 0, 0, 0, 0xff]))
let pic = write("pic.png", onePixelPNG)
let unknown = writeText("strange.zzqx", "plain enough\n")
let pdfName = writeText("paper.pdf", "not really a pdf")
// Over the text ceiling: a reference never reads it, Chat only refuses it.
let big: URL = {
    let url = scratch.appendingPathComponent("big.log")
    fm.createFile(atPath: url.path, contents: nil)
    let h = try! FileHandle(forWritingTo: url)
    let line = Data(String(repeating: "x", count: 1023).appending("\n").utf8)
    for _ in 0..<(AttachmentLimits.textMaxBytes / 1024 + 8) { h.write(line) }
    try! h.close()
    return url
}()
let link = scratch.appendingPathComponent("link.md")
try! fm.createSymbolicLink(at: link, withDestinationURL: notes)
let missing = scratch.appendingPathComponent("gone.txt")
let a150 = writeText("a.txt", String(repeating: "a", count: 150_000))
let b150 = writeText("b.txt", String(repeating: "b", count: 150_000))
let app = folder("Tool.app")

let agent = "Example Agent"
func tilde(_ url: URL) -> String { (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath }
func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1 }

// MARK: - The marker

print("  · the path marker, and what the readers make of it")
let ref = AttachmentInline.FileReference(name: "notes.md", path: "/Users/example-user/proj/notes.md", isFolder: false)
let marker = AttachmentInline.referenceMarker(ref)
check("a marker names its file through the readers' parser",
      AttachmentInline.names(in: "Look\n\n" + marker) == ["notes.md"])
check("a marker is stripped from what a bubble draws",
      AttachmentInline.stripping("Look at this\n\n" + marker) == "Look at this")
check("the path rides the marker, in full", marker.contains("path=\"/Users/example-user/proj/notes.md\""), marker)
check("a file's marker carries no folder mark", !marker.contains("folder="))
let folderMarker = AttachmentInline.referenceMarker(.init(name: "src", path: "/tmp/p/src", isFolder: true))
check("a folder's marker says it is a folder", folderMarker.contains("folder=\"true\""), folderMarker)
// The tag alone is not enough: a model can take a bare tag naming a path
// for an attachment it cannot open. So the marker says, in words, where
// the file is and to open it from there — and carries none of its content.
check("a marker tells the model, in words, where the file is and to open it from there",
      marker.contains("The user attached the file /Users/example-user/proj/notes.md.")
        && marker.contains("open it from that path") && !marker.contains("\n"), marker)
check("… a folder's, to look in it",
      folderMarker.contains("The user attached the folder /tmp/p/src.") && folderMarker.contains("look in it at that path"),
      folderMarker)
check("… and none of those words reach a bubble",
      AttachmentInline.stripping("Look\n\n" + marker + "\n" + folderMarker) == "Look")

let hostile = AttachmentInline.FileReference(name: "a\"b&<c>.md", path: "/tmp/x \"y\"/a&b<c>.md", isFolder: false)
let hostileMarker = AttachmentInline.referenceMarker(hostile)
check("a quote, an ampersand or a bracket in a name or a path is escaped",
      hostileMarker.contains("path=\"/tmp/x &quot;y&quot;/a&amp;b&lt;c&gt;.md\""), hostileMarker)
check("an escaped name still reads back whole",
      AttachmentInline.names(in: hostileMarker) == ["a\"b&<c>.md"])
let breakout = AttachmentInline.FileReference(name: "x", path: "/tmp/</sipai-attachment>/x", isFolder: false)
let breakoutText = "words\n\n" + AttachmentInline.referenceMarker(breakout) + " TAIL"
check("a path holding the closing tag cannot end the marker early",
      AttachmentInline.stripping(breakoutText) == "words\n\n TAIL", AttachmentInline.stripping(breakoutText))
check("… and names only its own file", AttachmentInline.names(in: breakoutText) == ["x"])

print("  · the message an agent receives")
let two = [ref, AttachmentInline.FileReference(name: "src", path: "/tmp/p/src", isFolder: true)]
let composed = AttachmentInline.appendingReferences(two, to: "Review these")
check("the user's words come first", composed.hasPrefix("Review these\n\n<sipai-attachment"), composed)
check("one marker per file, one per line",
      composed.components(separatedBy: "\n").filter { $0.hasPrefix(AttachmentInline.openPrefix) }.count == 2, composed)
check("what the bubble draws is the words alone", AttachmentInline.stripping(composed) == "Review these")
check("the paperclip line names both, in order",
      AttachmentInline.names(in: composed) == ["notes.md", "src"], "\(AttachmentInline.names(in: composed))")
let command = AttachmentInline.appendingReferences([ref], to: "/review the change")
check("a message that opens on a command still opens on it", command.hasPrefix("/review the change\n\n"), command)
let skill = AttachmentInline.appendingReferences([ref], to: "/skill:tidy now")
check("a kimi skill command still leads the text", skill.hasPrefix("/skill:tidy now"), skill)
let alone = AttachmentInline.appendingReferences([ref], to: "  \n")
check("files alone: the markers and nothing above them",
      alone == marker && AttachmentInline.stripping(alone).isEmpty, alone)
check("no files: the words, trimmed", AttachmentInline.appendingReferences([], to: " hi \n") == "hi")

// MARK: - Staging a reference

print("  · a reference: what the file is, never what it holds")
do {
    let file = try AgentAttachment.reference(notes)
    check("a file is staged by its name", file.name == "notes.md")
    check("… as a file", !file.isFolder && !file.isPackage)
    check("… with its size on disk", file.byteCount == size(notes), "\(String(describing: file.byteCount))")
    check("… and nothing read", file.loaded == nil)
    check("its reference is its own path", file.reference.path == notes.standardizedFileURL.path)
} catch { check("a file stages as a reference", false, "\(error)") }
do {
    let dir = try AgentAttachment.reference(src)
    check("a folder stages as a folder, with no size", dir.isFolder && dir.byteCount == nil)
    check("a folder's reference says so", dir.reference.isFolder)
} catch { check("a folder stages as a reference", false, "\(error)") }
do {
    let linked = try AgentAttachment.reference(link)
    check("a symlink is kept as picked — the agent opens the path chosen",
          linked.url.path == link.standardizedFileURL.path && linked.name == "link.md", linked.url.path)
    // A link's own size is the length of the path it holds; the chip
    // states the size of the file the agent will open through it.
    check("… and its chip states the size of the file it points at, not the link's own",
          linked.byteCount == size(notes), "\(String(describing: linked.byteCount)) vs \(size(notes))")
} catch { check("a symlink stages", false, "\(error)") }
if (try? app.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true {
    do {
        let appLink = scratch.appendingPathComponent("ToolLink.app")
        try fm.createSymbolicLink(at: appLink, withDestinationURL: app)
        let linkedApp = try AgentAttachment.reference(appLink)
        check("a link to a package is drawn as the package is, one file",
              linkedApp.isPackage && linkedApp.chipItem(agentName: agent, chatOnly: false).icon != "folder",
              "isPackage \(linkedApp.isPackage)")
    } catch { check("a link to a package stages", false, "\(error)") }
}
do {
    _ = try AgentAttachment.reference(missing)
    check("a file that is not there is refused", false)
} catch {
    check("a file that is not there is refused, by name",
          error.localizedDescription.contains("gone.txt"), error.localizedDescription)
}
let newline = writeText("two\nlines.txt", "x")
if let file = try? AgentAttachment.reference(newline) {
    check("a newline in a file's name does not reach the chip", !file.name.contains("\n"), file.name)
}

print("  · the chip")
func chip(_ url: URL) -> AttachmentChipItem? {
    try? AgentAttachment.reference(url).chipItem(agentName: agent, chatOnly: false)
}
let noteChip = chip(notes)
check("a text file's chip is the chat page's text icon", noteChip?.icon == "doc.plaintext", noteChip?.icon ?? "nil")
check("… beside its size",
      noteChip?.detail == ByteCountFormatter.string(fromByteCount: Int64(size(notes)), countStyle: .file))
check("… and its hover names where it is and who reads it",
      noteChip?.hint == "\(tilde(notes)) — \(agent) reads the file itself", noteChip?.hint ?? "nil")
check("an image's chip is the chat page's image icon", chip(pic)?.icon == "photo")
check("a PDF's chip is the chat page's document icon", chip(pdfName)?.icon == "doc.richtext")
check("a file of a type the Mac does not know gets the plain document icon", chip(unknown)?.icon == "doc")
check("an archive gets the plain document icon", chip(blob)?.icon == "doc")
let folderChip = chip(src)
check("a folder's chip is a folder, with no size", folderChip?.icon == "folder" && folderChip?.detail == nil)
check("… and its hover says the agent reads the folder",
      folderChip?.hint == "\(tilde(src)) — \(agent) reads the folder itself", folderChip?.hint ?? "nil")
if let pkg = try? AgentAttachment.reference(app), pkg.isPackage {
    check("a package (an app) is drawn as one file, not a folder", pkg.chipItem(agentName: agent, chatOnly: false).icon != "folder")
}
if let file = try? AgentAttachment.reference(notes) {
    check("a chip carries its staged file's id — ✕ removes that file", file.chipItem(agentName: agent, chatOnly: false).id == file.id)
}

// MARK: - Staging per mode

print("  · outside Chat only: paths, never read")
let noImages: (String) -> String? = { _ in nil }
let outside = AgentAttachment.staging([notes, src, blob, big, pic], onto: [], chatOnly: false, imageRefusal: noImages)
check("files, a folder, an archive, a huge log and an image all stage",
      outside.staged.count == 5 && outside.refused.isEmpty, "\(outside.staged.map(\.name)) \(outside.refused)")
check("… none of them read", outside.staged.allSatisfy { $0.loaded == nil })
let twice = AgentAttachment.staging([notes, notes], onto: [], chatOnly: false, imageRefusal: noImages)
check("the same file twice is one chip", twice.staged.count == 1)
let again = AgentAttachment.staging([notes], onto: twice.staged, chatOnly: false, imageRefusal: noImages)
check("… and attaching it again adds nothing", again.staged.count == 1 && again.refused.isEmpty)
let slashed = URL(fileURLWithPath: src.path + "/", isDirectory: true)
let bare = URL(fileURLWithPath: src.path, isDirectory: false)
let folderTwice = AgentAttachment.staging([slashed, bare], onto: [], chatOnly: false, imageRefusal: noImages)
check("a folder is one chip, with or without a slash at the end of its URL",
      folderTwice.staged.count == 1, "\(folderTwice.staged.map(\.url.absoluteString))")
let many = (0..<(AttachmentLimits.maxPerMessage + 1)).map { writeText("f\($0).txt", "\($0)") }
let capped = AgentAttachment.staging(many, onto: [], chatOnly: false, imageRefusal: noImages)
check("the chat page's file count holds: \(AttachmentLimits.maxPerMessage) a message",
      capped.staged.count == AttachmentLimits.maxPerMessage
        && capped.refused == [AttachmentError.tooMany.localizedDescription], "\(capped.staged.count) \(capped.refused)")
let gone = AgentAttachment.staging([missing], onto: [], chatOnly: false, imageRefusal: noImages)
check("a file that is not there is refused with its name",
      gone.staged.isEmpty && gone.refused.first?.contains("gone.txt") == true, "\(gone.refused)")

print("  · in Chat only: read the chat page's way")
let inside = AgentAttachment.staging([notes, src, blob, big, pic], onto: [], chatOnly: true, imageRefusal: noImages)
check("a text file and an image are loaded",
      inside.staged.map(\.name) == ["notes.md", "pic.png"] && inside.staged.allSatisfy { $0.loaded != nil },
      "\(inside.staged.map(\.name))")
check("a text file's content is what travels", inside.staged.first?.loaded?.text?.contains("ALPHA LINE") == true)
check("a folder is refused, by name", inside.refused.contains { $0.contains("src") && $0.contains("folder") },
      "\(inside.refused)")
check("a binary file and a file over the ceiling are refused in the chat page's words",
      inside.refused.contains { $0.contains("blob.zip") } && inside.refused.contains { $0.contains("big.log") },
      "\(inside.refused)")
let refusedImage = AgentAttachment.staging([pic], onto: [], chatOnly: true, imageRefusal: { "\($0): NO IMAGE CHANNEL" })
check("an image the session has no channel for is refused in the session's words",
      refusedImage.staged.isEmpty && refusedImage.refused == ["pic.png: NO IMAGE CHANNEL"], "\(refusedImage.refused)")
let overCap = AgentAttachment.staging([a150, b150], onto: [], chatOnly: true, imageRefusal: noImages)
check("the message's attached-text ceiling holds",
      overCap.staged.map(\.name) == ["a.txt"]
        && overCap.refused.count == 1
        && overCap.refused[0].contains("\(AttachmentInline.perMessageCharCap / 1000)k"), "\(overCap.refused)")
if let loadedNote = inside.staged.first, let loaded = loadedNote.loaded {
    let item = loadedNote.chipItem(agentName: agent, chatOnly: true)
    check("under Chat only a file read for it shows the chat page's chip",
          item.icon == loaded.chipItem.icon && item.detail == loaded.chipItem.detail && item.hint == loaded.chipItem.hint,
          item.hint)
    check("… its hover saying the text goes in the message",
          item.hint == "notes.md — \(loaded.sizeLabel), its text is included in the message", item.hint)
    check("… under the staged file's own id", item.id == loadedNote.id)
    // Out of Chat only the same file goes as its path, whatever was read.
    let outsideItem = loadedNote.chipItem(agentName: agent, chatOnly: false)
    check("out of Chat only the same file's chip names its path and who reads it — only the path travels there",
          outsideItem.hint == "\(tilde(notes)) — \(agent) reads the file itself"
            && outsideItem.detail == ByteCountFormatter.string(fromByteCount: Int64(size(notes)), countStyle: .file),
          outsideItem.hint)
}
if let loadedPic = inside.staged.first(where: { $0.name == "pic.png" }) {
    check("… an image too: its path chip, with the size on disk, not the resized copy's",
          loadedPic.chipItem(agentName: agent, chatOnly: false).hint == "\(tilde(pic)) — \(agent) reads the file itself")
}
// A PDF travels as its TEXT in an agent's Chat only message (an agent
// message has no document part), so its chip says that.
let textPDF: URL = {
    let url = scratch.appendingPathComponent("brief.pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    ctx.beginPage(mediaBox: &box)
    let line = NSAttributedString(string: "PDF BODY LINE", attributes: [.font: NSFont.systemFont(ofSize: 14)])
    let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(line), CFRange(),
                                         CGPath(rect: CGRect(x: 40, y: 40, width: 500, height: 700), transform: nil), nil)
    CTFrameDraw(frame, ctx)
    ctx.endPage()
    ctx.closePDF()
    return url
}()
let pdfStaged = AgentAttachment.staging([textPDF], onto: [], chatOnly: true, imageRefusal: noImages)
if let pdf = pdfStaged.staged.first, let loaded = pdf.loaded {
    let item = pdf.chipItem(agentName: agent, chatOnly: true)
    check("a PDF read for Chat only: the document icon, and its hover says its TEXT goes in the message",
          item.icon == "doc.richtext"
            && item.hint == "brief.pdf — \(loaded.sizeLabel), its text is included in the message", item.hint)
} else {
    check("a PDF with a text layer stages under Chat only", false, "\(pdfStaged.refused)")
}

print("  · switching into Chat only")
let switched = AgentAttachment.loadingForChatOnly(outside.staged, imageRefusal: noImages)
check("what Chat only can carry is read now",
      switched.staged.map(\.name) == ["notes.md", "pic.png"] && switched.staged.allSatisfy { $0.loaded != nil },
      "\(switched.staged.map(\.name))")
check("what it cannot comes off, each with its reason",
      switched.refused.count == 3
        && switched.refused.contains { $0.contains("src") }
        && switched.refused.contains { $0.contains("blob.zip") }
        && switched.refused.contains { $0.contains("big.log") }, "\(switched.refused)")
check("a staged file keeps its id across the switch",
      switched.staged.first?.id == outside.staged.first?.id)
let reloaded = AgentAttachment.loadingForChatOnly(inside.staged, imageRefusal: noImages)
check("a file already loaded is not read again",
      reloaded.refused.isEmpty
        && zip(reloaded.staged, inside.staged).allSatisfy { $0.loaded?.id == $1.loaded?.id })
if let aRef = try? AgentAttachment.reference(a150),
   let bLoaded = AgentAttachment.staging([b150], onto: [], chatOnly: true, imageRefusal: noImages).staged.first {
    let mixed = AgentAttachment.loadingForChatOnly([aRef, bLoaded], imageRefusal: noImages)
    check("the ceiling counts every file already loaded, wherever it stands in the row",
          mixed.staged.map(\.name) == ["b.txt"] && mixed.refused.count == 1, "\(mixed.staged.map(\.name)) \(mixed.refused)")
}
if let plain = outside.staged.first, let loaded = switched.staged.first {
    check("a file loaded on the switch is a change the composer's stash sees", plain != loaded)
}

// MARK: - A scheduled task

print("  · a scheduled task's prompt")
let staged2 = outside.staged.prefix(2).map { $0 }
let prompt = AgentAttachment.taskPrompt("Check these files", with: staged2)
check("the words, then each path on a line of its own",
      prompt == "Check these files\n\n\(notes.standardizedFileURL.path)\n\(src.standardizedFileURL.path)", prompt)
check("files alone: the paths", AgentAttachment.taskPrompt(" ", with: [staged2[0]]) == notes.standardizedFileURL.path)
check("no files: the words, trimmed", AgentAttachment.taskPrompt(" hi \n", with: []) == "hi")

// MARK: - The chat page's chip is unchanged

print("  · the chat page's chips")
if let text = try? ChatAttachment.load(notes) {
    let item = text.chipItem
    check("a chat page text chip reads as it did",
          item.icon == "doc.plaintext" && item.detail == text.sizeLabel
            && item.hint == "notes.md — \(text.sizeLabel), its text is included in the message", item.hint)
}
if let image = try? ChatAttachment.load(pic) {
    check("a chat page image chip reads as it did",
          image.chipItem.icon == "photo"
            && image.chipItem.hint == "pic.png — \(image.sizeLabel), sent as an image with this message")
}

// MARK: - The real CLIs, token-free

// Each installed CLI runs ONE ordinary turn against the fake local model
// endpoint (ChatOnlyMode's fake_server.py: records every request, answers
// "OK") under a throwaway home, sent the message the composer builds. What
// reached the model, and what the CLI wrote into its own transcript, are
// read back: a CLI that rewrote the marker would leave the agent without
// the path, or a reopened session without its paperclip line.
print("  · the real CLIs pass the marker through (fake endpoint, throwaway homes)")

let env = ProcessInfo.processInfo.environment
let serverScript = env["SIPAI_AFC_SERVER"] ?? "../ChatOnlyMode/fake_server.py"

func skip(_ label: String, _ why: String) { print("  SKIP \(label) — \(why)") }

/// A CLI where an install puts it, else on the harness's own PATH.
func binary(_ name: String) -> String? {
    let home = fm.homeDirectoryForCurrentUser.path
    let dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.kimi-code/bin"]
        + (env["PATH"] ?? "").split(separator: ":").map(String.init)
    return dirs.map { "\($0)/\(name)" }.first { fm.isExecutableFile(atPath: $0) }
}

/// Run to completion, bounded; stdin closed (codex exec reads a prompt
/// from an open stdin and would wait for it).
func run(_ path: String, _ args: [String], cwd: URL, environment: [String: String],
         timeout: TimeInterval = 120) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    var e = env
    // Nothing of the session running the harness may steer the CLI: no
    // dynamic-linker setting, no claude setting, no provider override.
    for key in e.keys where key.hasPrefix("DYLD_") || key.hasPrefix("CLAUDE") || key.hasPrefix("ANTHROPIC_") {
        e.removeValue(forKey: key)
    }
    for (k, v) in environment { e[k] = v }
    p.environment = e
    p.currentDirectoryURL = cwd
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "\(error)") }
    var data = Data()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue(label: "harness.read").async {
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
    if p.isRunning { p.terminate() }
    p.waitUntilExit()
    _ = done.wait(timeout: .now() + 5)
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// The fake endpoint, one per CLI, recording into its own directory.
final class FakeServer {
    let recordDir: URL
    let port: Int
    private let process: Process

    init?() {
        let dir = scratch.appendingPathComponent("server-\(UUID().uuidString.prefix(6))", isDirectory: true)
        recordDir = dir.appendingPathComponent("rec", isDirectory: true)
        try? fm.createDirectory(at: recordDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [serverScript, recordDir.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        process = p
        var text = ""
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !text.contains("\n") {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.05) } else { text += String(decoding: chunk, as: UTF8.self) }
        }
        guard let r = text.range(of: "PORT="), let found = Int(text[r.upperBound...].prefix { $0.isNumber }) else {
            p.terminate()
            return nil
        }
        port = found
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    /// Every recorded request body, oldest first.
    func bodies() -> [Any] {
        let names = ((try? fm.contentsOfDirectory(atPath: recordDir.path)) ?? []).sorted()
        return names.compactMap { name in
            guard let data = try? Data(contentsOf: recordDir.appendingPathComponent(name)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj["body"]
        }
    }
}

/// Every string anywhere in a JSON value — however a CLI nests the
/// message, and whatever it escapes on the way to disk.
func strings(in value: Any) -> [String] {
    if let s = value as? String { return [s] }
    if let a = value as? [Any] { return a.flatMap(strings(in:)) }
    if let d = value as? [String: Any] { return d.values.flatMap(strings(in:)) }
    return []
}

/// The strings of every JSONL record under `root` whose name passes `keep`.
func recordedStrings(under root: URL, keep: (String) -> Bool) -> [String] {
    guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    var found: [String] = []
    for case let url as URL in walker where keep(url.lastPathComponent) {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) {
                found += strings(in: obj)
            }
        }
    }
    return found
}

let words = "Summarise the attached notes."
let attached = try! AgentAttachment.reference(notes)
let wire = AttachmentInline.appendingReferences([attached.reference], to: words)
let wireMarker = AttachmentInline.referenceMarker(attached.reference)

/// One agent's turn, read back: the request, then the transcript.
func throughCLI(_ label: String, sent: (status: Int32, out: String), server: FakeServer,
                transcript: [String]) {
    let sentToModel = server.bodies().flatMap(strings(in:)).contains { $0.contains(wire) }
    check("\(label) hands the model the words and the marker unchanged", sentToModel,
          "exit \(sent.status): \(sent.out.suffix(300))")
    let recorded = transcript.filter { $0.contains(wireMarker) }
    check("\(label) records the marker in its own transcript", !recorded.isEmpty)
    if let message = recorded.first(where: { $0.contains(words) }) {
        check("\(label)'s record reads back as the words, the file on the paperclip line",
              AttachmentInline.stripping(message) == words && AttachmentInline.names(in: message) == ["notes.md"],
              AttachmentInline.stripping(message))
    }
}

let workdir = scratch.appendingPathComponent("work", isDirectory: true)
try! fm.createDirectory(at: workdir, withIntermediateDirectories: true)

if !fm.fileExists(atPath: serverScript) {
    skip("the real CLIs", "no fake endpoint at \(serverScript)")
} else {
    if let claude = binary("claude"), let server = FakeServer() {
        let home = scratch.appendingPathComponent("claude-home", isDirectory: true)
        try! fm.createDirectory(at: home, withIntermediateDirectories: true)
        let result = run(claude, ["-p", wire, "--output-format", "stream-json", "--verbose"], cwd: workdir,
                         environment: ["CLAUDE_CONFIG_DIR": home.path,
                                       "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(server.port)",
                                       "ANTHROPIC_API_KEY": "sk-ant-harness-junk"])
        throughCLI("claude", sent: result, server: server,
                   transcript: recordedStrings(under: home.appendingPathComponent("projects")) { $0.hasSuffix(".jsonl") })
        server.stop()
    } else { skip("claude", "not installed, or the fake endpoint did not start") }

    if let codex = binary("codex"), let server = FakeServer() {
        let home = scratch.appendingPathComponent("codex-home", isDirectory: true)
        try! fm.createDirectory(at: home, withIntermediateDirectories: true)
        try! """
        model_provider = "fake"
        model = "gpt-5.5"

        [model_providers.fake]
        name = "fake"
        base_url = "http://127.0.0.1:\(server.port)"
        wire_api = "responses"

        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let result = run(codex, ["exec", "--json", "--skip-git-repo-check", wire], cwd: workdir,
                         environment: ["CODEX_HOME": home.path])
        throughCLI("codex", sent: result, server: server,
                   transcript: recordedStrings(under: home.appendingPathComponent("sessions")) {
                       $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl")
                   })
        server.stop()
    } else { skip("codex", "not installed, or the fake endpoint did not start") }

    if let kimi = binary("kimi"), let server = FakeServer() {
        let home = scratch.appendingPathComponent("kimi-home", isDirectory: true)
        try! fm.createDirectory(at: home, withIntermediateDirectories: true)
        try! """
        default_model = "fake/fake-model"

        [providers.fake]
        base_url = "http://127.0.0.1:\(server.port)/v1"
        type = "openai"
        api_key = "junk"

        [models."fake/fake-model"]
        provider = "fake"
        model = "fake-model"
        max_context_size = 262144
        capabilities = [ "tool_use" ]

        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let result = run(kimi, ["--prompt", wire, "--output-format", "stream-json"], cwd: workdir,
                         environment: ["KIMI_CODE_HOME": home.path])
        throughCLI("kimi", sent: result, server: server,
                   transcript: recordedStrings(under: home.appendingPathComponent("sessions")) { $0 == "wire.jsonl" })
        server.stop()
    } else { skip("kimi", "not installed, or the fake endpoint did not start") }
}

// MARK: - Live: one real turn per installed CLI (SIPAI_AFC_LIVE=1)

// Spends one short turn per tool, from the user's own login (a plan, or
// an API key where the tool uses one), at the lowest effort: claude on
// `haiku`, codex and kimi on their default model unless the run names one
// (`SIPAI_AFC_LIVE_CODEX_MODEL`, `SIPAI_AFC_LIVE_KIMI_MODEL`). What it asks: does each
// model OPEN the file a marker names, and answer from it? The file sits
// two folders below the working folder, so only the marker's path leads
// straight to it. The folder is under /tmp, a system temp root — NOT the
// harness's TMPDIR — so SipAI files the sessions as scratch and lists none
// of them; each tool keeps them in its own store, and their ids are printed.
if env["SIPAI_AFC_LIVE"] == "1" {
    print("  · live: each real CLI opens the file a marker names (one short turn each)")
    let liveRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("sipai-afc-live-\(UUID().uuidString.prefix(6))", isDirectory: true)
    let liveWork = liveRoot.appendingPathComponent("work", isDirectory: true)
    let archive = liveWork.appendingPathComponent("docs/archive", isDirectory: true)
    try! fm.createDirectory(at: archive, withIntermediateDirectories: true)
    let liveNote = archive.appendingPathComponent("meeting-notes.md")
    try! "The design review moved to Thursday at 15:40, in the Juniper room.\n"
        .write(to: liveNote, atomically: true, encoding: .utf8)
    let liveText = AttachmentInline.appendingReferences(
        [try! AgentAttachment.reference(liveNote).reference], to: "What does the attached file say?")
    func objects(_ out: String) -> [[String: Any]] {
        out.split(separator: "\n").compactMap { line in
            guard let start = line.firstIndex(of: "{") else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(line[start...].utf8)) as? [String: Any]
        }
    }
    func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    /// One tool's turn: the tool calls it made, in order, and its answer.
    func judge(_ label: String, calls: [String], answer: String, extra: String) {
        check("\(label) opens the file the marker names", calls.contains { $0.contains("meeting-notes.md") },
              calls.isEmpty ? "no tool call; it answered: \(answer.prefix(300))" : calls.joined(separator: " | ").prefix(400).description)
        check("\(label) answers from the file", answer.lowercased().contains("juniper"), String(answer.prefix(300)))
        print("  note \(label): first tool call \(calls.first.map { String($0.prefix(160)) } ?? "none"); \(extra)")
    }

    if let claude = binary("claude") {
        let r = run(claude, ["-p", liveText, "--output-format", "stream-json", "--verbose", "--model", "haiku"],
                    cwd: liveWork, environment: [:], timeout: 240)
        var calls: [String] = []
        var answer = "", usage = "", sid = ""
        for o in objects(r.out) {
            switch o["type"] as? String {
            case "system": sid = (o["session_id"] as? String) ?? sid
            case "assistant":
                let content = ((o["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
                for block in content where block["type"] as? String == "tool_use" {
                    calls.append("\(block["name"] as? String ?? "?") \(json(block["input"] ?? [:]))")
                }
            case "result":
                answer = (o["result"] as? String) ?? ""
                let u = (o["usage"] as? [String: Any]) ?? [:]
                let input = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
                usage = "\(input) input + \((u["output_tokens"] as? Int) ?? 0) output tokens"
                    + ((o["total_cost_usd"] as? Double).map { String(format: ", claude's estimate $%.4f", $0) } ?? "")
            default: break
            }
        }
        judge("claude (haiku)", calls: calls, answer: answer,
              extra: "\(usage); session \(sid), exit \(r.status)")
    } else { skip("live claude", "not installed") }

    if let codex = binary("codex") {
        var args = ["exec", "--json", "--skip-git-repo-check", "-c", "model_reasoning_effort=\"low\""]
        if let model = env["SIPAI_AFC_LIVE_CODEX_MODEL"], !model.isEmpty { args += ["-m", model] }
        let r = run(codex, args + [liveText], cwd: liveWork, environment: [:], timeout: 240)
        var calls: [String] = []
        var answer = "", usage = "", tid = ""
        for o in objects(r.out) {
            switch o["type"] as? String {
            case "thread.started": tid = (o["thread_id"] as? String) ?? tid
            case "item.completed":
                let item = (o["item"] as? [String: Any]) ?? [:]
                switch item["type"] as? String {
                case "agent_message": answer += (item["text"] as? String) ?? ""
                case "reasoning", "user_message", nil: break
                default: calls.append("\(item["type"] as? String ?? "?") \(json(item).prefix(300))")
                }
            case "turn.completed":
                let u = (o["usage"] as? [String: Any]) ?? [:]
                usage = "\((u["input_tokens"] as? Int) ?? 0) input (\((u["cached_input_tokens"] as? Int) ?? 0) cached) + \((u["output_tokens"] as? Int) ?? 0) output tokens"
            default: break
            }
        }
        judge("codex (\(env["SIPAI_AFC_LIVE_CODEX_MODEL"] ?? "its default model"), low effort)", calls: calls,
              answer: answer, extra: "\(usage); thread \(tid), exit \(r.status)")
    } else { skip("live codex", "not installed") }

    if let kimi = binary("kimi") {
        var args = ["--prompt", liveText, "--output-format", "stream-json"]
        if let model = env["SIPAI_AFC_LIVE_KIMI_MODEL"], !model.isEmpty { args += ["--model", model] }
        let r = run(kimi, args, cwd: liveWork, environment: ["KIMI_MODEL_THINKING_EFFORT": "low"], timeout: 240)
        var calls: [String] = []
        var answer = "", sid = ""
        for o in objects(r.out) {
            if o["type"] as? String == "session.resume_hint" { sid = (o["session_id"] as? String) ?? sid }
            guard o["role"] as? String == "assistant" else { continue }
            for call in (o["tool_calls"] as? [[String: Any]]) ?? [] {
                let function = (call["function"] as? [String: Any]) ?? [:]
                calls.append("\(function["name"] as? String ?? "?") \(function["arguments"] as? String ?? "")")
            }
            if let text = o["content"] as? String { answer += text }
            for part in (o["content"] as? [[String: Any]]) ?? [] where part["type"] as? String == "text" {
                answer += (part["text"] as? String) ?? ""
            }
        }
        // Kimi prints no usage on stdout; its wire records one per step.
        var tokens = 0
        let kimiHome = env["KIMI_CODE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
        if !sid.isEmpty, let walker = fm.enumerator(at: kimiHome.appendingPathComponent("sessions"),
                                                    includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.lastPathComponent == "wire.jsonl"
                && url.path.contains("/\(sid)/") {
                for o in objects((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                where o["type"] as? String == "usage.record" {
                    let u = (o["usage"] as? [String: Any]) ?? [:]
                    tokens += u.values.compactMap { $0 as? Int }.reduce(0, +)
                }
            }
        }
        judge("kimi (\(env["SIPAI_AFC_LIVE_KIMI_MODEL"] ?? "its default model"), low effort)", calls: calls,
              answer: answer, extra: "\(tokens) tokens in all; session \(sid), exit \(r.status)")
    } else { skip("live kimi", "not installed") }
    try? fm.removeItem(at: liveRoot)
}

try? fm.removeItem(at: scratch)
print("\n  \(checks - failures)/\(checks) rule checks passed")
exit(failures == 0 ? 0 : 1)
