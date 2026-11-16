// CompressedRollouts — codex's compressed rollouts read the way a plain
// one is.
//
// A codex rollout nobody has touched for a while is kept as
// `<name>.jsonl.zst` — one zstd frame, its decoded size stated in the
// header, no checksum, the modification time kept — with the `.jsonl`
// removed (on the Mac this was measured on: 377 of 443 rollouts, every
// one older than a week; which codex compresses them is the desktop
// app's, read in its bundle, not watched). A reader that lists `.jsonl` alone lost every
// one of those sessions: from the sidebar, from their tasks' runs, from
// search, and as a branch's inherited history. Codex unpacks a rollout
// back to `<name>.jsonl` the moment it loads the thread again — a resume,
// a fork, a listing of its turns — byte for byte, removes the `.zst`, and
// appends there (measured on codex 0.164.0, token-free).
//
// So: the bundled zstd decoder reads the committed fixture to its known
// text (1), the scanner and every reader treat a compressed rollout as
// the plain one it holds (2), a file in both forms is one session, and a
// URL read before codex packed or unpacked it still reads (3), a branch
// whose parent is compressed inherits from it (4), the runner's watcher
// follows the plain file a compressed one unpacks into, from the decoded
// size (5), with no decoder a compressed file stays out (6), and the app
// installs the decoder and names its licence (7).
//
// `fixtures/rollout-…jsonl.zst` is a synthetic rollout in codex's record
// shapes (no real session), compressed once with zstd 1.5.7
// (`zstd -19 --no-check`): entropy-coded, which the frames this harness
// builds itself are not. The others are built here from RAW blocks — the
// format's own way of storing bytes as they are — so no compressor is
// needed on the Mac that runs it.
//
// Nothing here is part of the app target.
import Foundation
#if !PREFIX
import CryptoKit
#endif

var checks = 0
var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if ok {
        print("  ok    \(label)")
    } else {
        failures += 1
        let d = detail()
        print("  FAIL  \(label)\(d.isEmpty ? "" : " — \(d)")")
    }
}

let fm = FileManager.default
let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let checkout = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
// Under ~/Library/Caches, never a temp root: a rollout whose folder is a
// temp root is a probe, and the scanner drops it.
let sandbox = fm.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/sipai-compressed-\(UUID().uuidString)", isDirectory: true)
try! fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
let project = sandbox.appendingPathComponent("project", isDirectory: true)
try! fm.createDirectory(at: project, withIntermediateDirectories: true)
// `CodexSessionScanner.sessionRoot` derives from the home Foundation
// reports, which honours CFFIXED_USER_HOME — set before its first use.
setenv("CFFIXED_USER_HOME", sandbox.path, 1)
let day = sandbox.appendingPathComponent(".codex/sessions/2026/01/02", isDirectory: true)
try! fm.createDirectory(at: day, withIntermediateDirectories: true)
let outside = sandbox.appendingPathComponent("outside", isDirectory: true)
try! fm.createDirectory(at: outside, withIntermediateDirectories: true)

func finish() -> Never {
    try? fm.removeItem(at: sandbox)
    print("\n\(checks - failures)/\(checks) checks passed")
    exit(failures == 0 ? 0 : 1)
}

#if !PREFIX
SessionFileCompression.decoder = ZstdFileDecoder.open
SessionFileCompression.statedSize = ZstdFileDecoder.statedSize
#endif

// MARK: - Building rollouts and frames

/// One rollout record as codex writes it — `ordinal` among the first
/// keys, where the readers' fast path looks for it.
func record(_ ordinal: Int, _ ts: String, _ type: String, _ payload: [String: Any]) -> String {
    let obj: [String: Any] = ["ordinal": ordinal, "payload": payload, "timestamp": ts, "type": type]
    let data = try! JSONSerialization.data(withJSONObject: obj,
                                           options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

struct Built {
    var text: String
    var turnIds: [String]
    /// The ordinal each turn's `task_started` carries.
    var turnOrdinals: [Int]
}

/// A rollout of `turns` turns: the meta record, then per turn its start,
/// the user's words, an answer, a token count and its end.
func rollout(id: String, turns: Int, words: String, meta extra: [String: Any] = [:],
             firstOrdinal: Int = 0, minuteBase: Int = 10) -> Built {
    var lines: [String] = []
    var ordinal = firstOrdinal
    var meta: [String: Any] = ["id": id, "cwd": project.path]
    for (k, v) in extra { meta[k] = v }
    lines.append(record(ordinal, "2026-01-02T03:04:05.000Z", "session_meta", meta)); ordinal += 1
    var ids: [String] = []
    var ordinals: [Int] = []
    for t in 1...turns {
        let ts = String(format: "2026-01-02T03:%02d:00.000Z", minuteBase + t)
        let turnId = "\(id.prefix(8))-turn-\(t)"
        ids.append(turnId)
        ordinals.append(ordinal)
        lines.append(record(ordinal, ts, "event_msg",
                            ["type": "task_started", "turn_id": turnId])); ordinal += 1
        lines.append(record(ordinal, ts, "response_item",
                            ["type": "message", "role": "user",
                             "content": [["type": "input_text", "text": "\(words) \(t)"]]])); ordinal += 1
        lines.append(record(ordinal, ts, "response_item",
                            ["type": "message", "role": "assistant",
                             "content": [["type": "output_text", "text": "Answer to \(words) \(t)"]]])); ordinal += 1
        lines.append(record(ordinal, ts, "event_msg",
                            ["type": "token_count",
                             "info": ["last_token_usage": ["input_tokens": 500 + t, "total_tokens": 520 + t],
                                      "model_context_window": 258400]])); ordinal += 1
        lines.append(record(ordinal, ts, "event_msg",
                            ["type": "task_complete", "turn_id": turnId, "duration_ms": 3000 + t])); ordinal += 1
    }
    return Built(text: lines.joined(separator: "\n") + "\n", turnIds: ids, turnOrdinals: ordinals)
}

/// A zstd frame of RAW blocks holding `data` — any zstd decoder reads it.
/// `statesSize: false` leaves the decoded size out of the header, as a
/// streaming compressor that was not told it does. The blocks are small
/// by default, so a block header falls inside every line: a reader that
/// takes the file's bytes as text — as one that knows no zstd would —
/// parses nothing out of it, as out of a real (entropy-coded) frame.
func rawFrame(_ data: Data, statesSize: Bool = true, blockSize: Int = 61) -> Data {
    var out = Data([0x28, 0xB5, 0x2F, 0xFD])
    // Frame header: an 8-byte content size or none; not single-segment,
    // so a window descriptor follows — 2 MiB, codex's own.
    out.append(statesSize ? 0xC0 : 0x00)
    out.append(UInt8(11 << 3))
    if statesSize {
        var size = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
    }
    let block = min(blockSize, 128 * 1024)
    var offset = 0
    repeat {
        let n = min(block, data.count - offset)
        let last: UInt32 = offset + n >= data.count ? 1 : 0
        let header = UInt32(n) << 3 | last        // block type 0: raw
        out.append(contentsOf: [UInt8(header & 0xFF), UInt8((header >> 8) & 0xFF),
                                UInt8((header >> 16) & 0xFF)])
        out.append(data.subdata(in: offset..<(offset + n)))
        offset += n
    } while offset < data.count
    return out
}

/// A frame of `blocks` RLE blocks of 128 KiB each: a few hundred bytes
/// that decode to `blocks` × 128 KiB.
func rleFrame(blocks: Int, byte: UInt8) -> Data {
    var out = Data([0x28, 0xB5, 0x2F, 0xFD, 0x00, UInt8(11 << 3)])
    for b in 0..<blocks {
        let header = UInt32(128 * 1024) << 3 | (1 << 1) | (b == blocks - 1 ? 1 : 0)
        out.append(contentsOf: [UInt8(header & 0xFF), UInt8((header >> 8) & 0xFF),
                                UInt8((header >> 16) & 0xFF), byte])
    }
    return out
}

func rolloutName(_ id: String) -> String { "rollout-2026-01-02T03-04-05-\(id).jsonl" }

@discardableResult
func writeCompressed(_ text: String, id: String, in dir: URL = day,
                     statesSize: Bool = true) -> URL {
    let url = dir.appendingPathComponent(rolloutName(id) + ".zst")
    try! rawFrame(Data(text.utf8), statesSize: statesSize).write(to: url)
    return url
}

@discardableResult
func writePlain(_ text: String, name: String, in dir: URL = day) -> URL {
    let url = dir.appendingPathComponent(name)
    try! Data(text.utf8).write(to: url)
    return url
}

/// What a history read draws, row by row — ids are minted per read, so
/// rows are compared by what they say.
func rows(_ items: [AgentSessionHistoryItem]) -> [String] {
    items.map { item in
        switch item.kind {
        case .userText(let t): return "U:\(t)"
        case .assistantText(let t): return "A:\(t)"
        case .toolUse(_, let name, _): return "T:\(name)"
        case .toolResult(_, let content, _): return "R:\(content.prefix(40))"
        default: return "?"
        }
    }
}

func id(_ n: Int) -> String { String(format: "019e2222-0000-7000-8000-%012d", n) }

// MARK: - 1. The bundled decoder

#if !PREFIX
print("1. the bundled zstd decoder")
let fixtureId = "019e1111-2222-7333-8444-555566667777"
let fixtureFile = fixtures.appendingPathComponent(rolloutName(fixtureId) + ".zst")
func decodeAll(_ url: URL, chunk: Int, limit: UInt64 = SessionFileCompression.decodedLimit) -> Data {
    guard let reader = SessionFileReader.open(url, limit: limit) else { return Data() }
    defer { reader.close() }
    var data = Data()
    while true {
        let c = reader.read(upToCount: chunk)
        if c.isEmpty { break }
        data.append(c)
    }
    return data
}
let fixtureText = decodeAll(fixtureFile, chunk: 1 << 20)
let digest = SHA256.hash(data: fixtureText).map { String(format: "%02x", $0) }.joined()
check("the committed fixture (entropy-coded, zstd 1.5.7 -19) decodes to its known text",
      digest == "a8830c128e72b6dcb620af0c9803b456f6abd43490c749de513d2f0a125c9746",
      "\(fixtureText.count) bytes, sha256 \(digest)")
check("its stated size is read off the frame header (63,065 bytes)",
      ZstdFileDecoder.statedSize(fixtureFile) == 63065,
      "\(String(describing: ZstdFileDecoder.statedSize(fixtureFile)))")
check("read 777 bytes at a time, it decodes to the same text",
      decodeAll(fixtureFile, chunk: 777) == fixtureText)

let rawText = Data((0..<300_000).map { UInt8(32 + $0 % 90) })
let rawStated = outside.appendingPathComponent("raw-stated.zst")
try! rawFrame(rawText, blockSize: 128 * 1024).write(to: rawStated)
let rawUnstated = outside.appendingPathComponent("raw-unstated.zst")
try! rawFrame(rawText, statesSize: false).write(to: rawUnstated)
check("a frame of raw blocks (three of the largest, 300 KB) decodes exactly",
      decodeAll(rawStated, chunk: 4096) == rawText)
check("a frame that states no size: none is claimed, and the text is counted",
      ZstdFileDecoder.statedSize(rawUnstated) == nil
        && AgentSessionScanner.contentSize(of: rawUnstated) == 300_000,
      "\(String(describing: AgentSessionScanner.contentSize(of: rawUnstated)))")

// zstd decodes a block whole, so a file cut off mid-frame reads up to
// its last whole block: the raw frame has three, the fixture one.
let rawBytes = try! Data(contentsOf: rawStated)
let rawCut = outside.appendingPathComponent("raw-cut.zst")
try! rawBytes.prefix(rawBytes.count * 6 / 10).write(to: rawCut)
let rawCutText = decodeAll(rawCut, chunk: 1 << 16)
check("a file cut off mid-frame decodes to a prefix of its text, no more",
      !rawCutText.isEmpty && rawCutText.count < rawText.count && rawText.starts(with: rawCutText),
      "\(rawCutText.count) of \(rawText.count) bytes")
let fixtureBytes = try! Data(contentsOf: fixtureFile)
let cut = outside.appendingPathComponent("cut.zst")
try! fixtureBytes.prefix(fixtureBytes.count * 6 / 10).write(to: cut)
let cutText = decodeAll(cut, chunk: 1 << 16)
check("…and one cut inside its only block decodes to nothing, never to garbage",
      fixtureText.starts(with: cutText), "\(cutText.count) bytes")
let garbage = outside.appendingPathComponent("garbage.zst")
try! Data("not a zstd frame at all\n".utf8).write(to: garbage)
check("a file that is no frame decodes to nothing", decodeAll(garbage, chunk: 4096).isEmpty)
let bomb = outside.appendingPathComponent("bomb.zst")
try! rleFrame(blocks: 64, byte: 0x41).write(to: bomb)
check("a frame built to expand (\(try! Data(contentsOf: bomb).count) bytes → 8 MiB) stops at the read's limit",
      decodeAll(bomb, chunk: 1 << 20, limit: 1 << 20).count == 1 << 20
        && decodeAll(bomb, chunk: 1 << 20).count == 8 << 20)
#endif

// MARK: - 2. The store

print("\n2. a compressed rollout in the store is the session it holds")
let a = rollout(id: id(1), turns: 4, words: "compressed question")
let aZst = writeCompressed(a.text, id: id(1))
let aPlainTwin = writePlain(a.text, name: rolloutName(id(1)), in: outside)
let scanned = CodexSessionScanner.scan()
let aRow = scanned.first { $0.id == id(1) }
check("the scanner lists it", aRow != nil, "listed: \(scanned.map(\.id))")
check("…with its folder, its title and when its owner last spoke",
      aRow?.projectPath?.path == project.path
        && aRow?.title == "compressed question 1"
        && aRow?.lastUserMessageAt == CodexSessionScanner.lastUserMessageDate(of: aPlainTwin),
      "\(String(describing: aRow?.projectPath?.path)) · \(String(describing: aRow?.title)) · \(String(describing: aRow?.lastUserMessageAt))")
check("…as its compressed file", aRow?.fileURL.lastPathComponent == aZst.lastPathComponent)
let aRows = rows(CodexSessionScanner.readHistory(of: aZst))
check("its history reads as its plain twin's",
      !aRows.isEmpty && aRows == rows(CodexSessionScanner.readHistory(of: aPlainTwin)),
      "\(aRows.count) rows")
let ctx = CodexSessionScanner.lastContextInfo(of: aZst)
check("its context figure and window", ctx.tokens == 504 && ctx.window == 258400,
      "\(ctx)")
let turn = CodexSessionScanner.latestTurn(of: aZst)
check("its newest turn, ended, with codex's duration",
      turn?.open == false && turn?.seconds == 3.004, "\(String(describing: turn))")
check("its turn ids, oldest first, read through the file",
      CodexSessionScanner.turnIds(of: aZst) == a.turnIds)
check("its extent is the text it holds",
      CodexSessionScanner.historyExtent(of: aZst) == UInt64(a.text.utf8.count),
      "\(CodexSessionScanner.historyExtent(of: aZst)) vs \(a.text.utf8.count)")
check("a delete finds it (left behind, it would bring the session back)",
      CodexSessionScanner.rolloutFiles(forSessionId: id(1)).contains(aZst))
check("the lookup by id finds it",
      CodexSessionScanner.rolloutFile(namedForId: id(1)) == aZst)
#if !PREFIX
let fixtureInStore = day.appendingPathComponent(rolloutName(fixtureId) + ".zst")
try! fm.copyItem(at: fixtureFile, to: fixtureInStore)
let fixtureTwin = writePlain(String(decoding: fixtureText, as: UTF8.self),
                             name: rolloutName(fixtureId), in: outside)
let fixtureRow = CodexSessionScanner.scan().first { $0.id == fixtureId }
check("the entropy-coded fixture lists, with the title its plain twin derives",
      fixtureRow?.title.hasPrefix("Compressed fixture question 1:") == true
        && fixtureRow?.projectPath?.path == "/opt/sipai-demo/project",
      "\(String(describing: fixtureRow?.title))")
check("…and reads as its plain twin",
      rows(CodexSessionScanner.readHistory(of: fixtureInStore))
        == rows(CodexSessionScanner.readHistory(of: fixtureTwin))
        && CodexSessionScanner.lastContextInfo(of: fixtureInStore).tokens == 1888)
#endif

// MARK: - 3. Both forms, and a URL read before codex moved the file

print("\n3. a file packed and unpacked is one session, and an old URL still reads")
let b = rollout(id: id(2), turns: 2, words: "both forms")
let bMore = rollout(id: id(2), turns: 3, words: "both forms")
let bZst = writeCompressed(b.text, id: id(2))
let bPlain = writePlain(bMore.text, name: rolloutName(id(2)))
let bRows = CodexSessionScanner.scan().filter { $0.id == id(2) }
check("listed once, as the plain file codex writes to",
      bRows.count == 1 && bRows.first?.fileURL.lastPathComponent == bPlain.lastPathComponent,
      "\(bRows.map(\.fileURL.lastPathComponent))")
check("the lookup by id and by history id take the plain file",
      CodexSessionScanner.rolloutFile(namedForId: id(2))?.lastPathComponent == bPlain.lastPathComponent
        && CodexSessionScanner.historyFile(forId: id(2))?.lastPathComponent == bPlain.lastPathComponent)
// Codex unpacks: the compressed file goes, the plain one holds its text
// and the turn that followed.
try! fm.removeItem(at: bZst)
check("a URL to the compressed file, read after codex unpacked it, reads the plain file",
      rows(CodexSessionScanner.readHistory(of: bZst)).contains("U:both forms 3"))
let c = rollout(id: id(3), turns: 2, words: "packed later")
let cPlainURL = day.appendingPathComponent(rolloutName(id(3)))
writeCompressed(c.text, id: id(3))
check("a URL to the plain file, read after it was packed, reads the compressed one",
      rows(CodexSessionScanner.readHistory(of: cPlainURL)).contains("U:packed later 2"))
#if !PREFIX
check("the size the watcher measures from follows the file: the decoded text, then the plain file",
      AgentSessionScanner.contentSize(of: cPlainURL) == UInt64(c.text.utf8.count)
        && AgentSessionScanner.contentSize(of: bZst) == UInt64(bMore.text.utf8.count))
#endif

// MARK: - 4. A branch of a compressed session

print("\n4. a branch whose parent is compressed inherits from it")
let parent = rollout(id: id(4), turns: 3, words: "parent turn")
writeCompressed(parent.text, id: id(4))
let cutOrdinal = parent.turnOrdinals[2]
let branch = rollout(id: id(5), turns: 1, words: "branch turn",
                     meta: ["forked_from_id": id(4), "forked_from_ordinal_exclusive": cutOrdinal],
                     firstOrdinal: cutOrdinal, minuteBase: 30)
let branchURL = writePlain(branch.text, name: rolloutName(id(5)))
let branchRows = rows(CodexSessionScanner.readHistory(of: branchURL))
check("the branch draws the parent's turns below the cut, then its own",
      branchRows.filter { $0.hasPrefix("U:") }
        == ["U:parent turn 1", "U:parent turn 2", "U:branch turn 1"],
      "\(branchRows.filter { $0.hasPrefix("U:") })")
if let origin = CodexSessionScanner.forkOrigin(of: branchURL) {
    check("the turns a branch is cut on include the inherited ones",
          CodexSessionScanner.inheritedTurnIds(for: origin) == Array(parent.turnIds.prefix(2)))
} else {
    check("the branch's head names its parent", false)
}
let parentPrefix = parent.text.components(separatedBy: "\n").prefix(cutOrdinal)
    .map { $0 + "\n" }.joined()
check("its extent counts the parent's text below the cut",
      CodexSessionScanner.historyExtent(of: branchURL)
        == UInt64(branch.text.utf8.count + parentPrefix.utf8.count),
      "\(CodexSessionScanner.historyExtent(of: branchURL))")

// MARK: - 5. The watcher follows the file codex unpacks into

#if !PREFIX
print("\n5. the watcher follows the plain file, from the decoded size")
@discardableResult
func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
}
final class Watch {
    var texts: [String] = []
    var tailer: AgentSessionTailer!
    init(_ url: URL, offset: UInt64) {
        tailer = AgentSessionTailer(
            fileURL: url, fallbackCwd: project,
            format: .codex(threadId: "", sessionRoot: CodexSessionScanner.sessionRoot),
            openRetry: .milliseconds(100),
            onEvents: { [weak self] batch in
                for event in batch {
                    switch event.kind {
                    case .userMessage(let t), .assistantText(let t): self?.texts.append(t)
                    default: break
                    }
                }
            },
            onExternalInProgressChange: { _ in })
        tailer.start(initialOffset: offset)
    }
}
func unpackAndAppend(_ text: String, id: String) {
    let plain = day.appendingPathComponent(rolloutName(id))
    let more = record(9_000, "2026-01-02T04:00:00.000Z", "response_item",
                      ["type": "message", "role": "user",
                       "content": [["type": "input_text", "text": "follow-up question"]]])
        + "\n" + record(9_001, "2026-01-02T04:00:01.000Z", "response_item",
                        ["type": "message", "role": "assistant",
                         "content": [["type": "output_text", "text": "follow-up answer"]]]) + "\n"
    try? fm.removeItem(at: day.appendingPathComponent(rolloutName(id) + ".zst"))
    try! Data((text + more).utf8).write(to: plain)
}
for (n, fromStart) in [(6, false), (7, true)] {
    let w = rollout(id: id(n), turns: 2, words: "watched")
    let zst = writeCompressed(w.text, id: id(n))
    let offset = fromStart ? 0 : (AgentSessionScanner.contentSize(of: zst) ?? 0)
    let watch = Watch(SessionFileCompression.unpacked(zst), offset: offset)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    unpackAndAppend(w.text, id: id(n))
    waitUntil(5) { watch.texts.contains("follow-up answer") }
    if fromStart {
        check("control: watched from the start, the old turns come back as new",
              watch.texts.contains("watched 1"), "\(watch.texts)")
    } else {
        check("only the turn codex appended arrives",
              watch.texts == ["follow-up question", "follow-up answer"], "\(watch.texts)")
    }
    watch.tailer.stop()
}
#endif

// MARK: - 6. With no decoder

#if !PREFIX
print("\n6. with no decoder a compressed file stays out")
SessionFileCompression.decoder = nil
SessionFileCompression.statedSize = nil
let d = rollout(id: id(8), turns: 1, words: "no decoder")
let dZst = writeCompressed(d.text, id: id(8))
check("not listed (the name alone would make a session with no folder and no title)",
      !CodexSessionScanner.scan().contains { $0.id == id(8) })
check("and its readers read nothing",
      CodexSessionScanner.readHistory(of: dZst).isEmpty
        && AgentSessionScanner.boundedTail(of: dZst) == nil)
SessionFileCompression.decoder = ZstdFileDecoder.open
SessionFileCompression.statedSize = ZstdFileDecoder.statedSize
#endif

// MARK: - 7. The app's half, read off its sources

#if !PREFIX
print("\n7. the app installs the decoder and ships its licence")
func source(_ path: String) -> String {
    (try? String(contentsOf: checkout.appendingPathComponent(path), encoding: .utf8)) ?? ""
}
let app = source("SipAI-macOS/SipAI/SipAIApp.swift")
check("SipAIApp installs the decoder and the stated size",
      app.contains("SessionFileCompression.decoder = ZstdFileDecoder.open")
        && app.contains("SessionFileCompression.statedSize = ZstdFileDecoder.statedSize"))
let pbx = source("SipAI-macOS/SipAI.xcodeproj/project.pbxproj")
check("the project compiles the decoder and its Swift side",
      pbx.contains("/* sipai_zstd.c in Sources */,") && pbx.contains("/* ZstdFileDecoder.swift in Sources */,"))
check("both of the app's configurations take the bridging header",
      pbx.components(separatedBy: "SWIFT_OBJC_BRIDGING_HEADER = \"SipAI/SipAI-Bridging-Header.h\";").count == 3)
let runner = source("SipAI-macOS/SipAI/Models/AgentRunner.swift")
check("the runner watches the plain file a compressed rollout unpacks into",
      runner.contains("let watched = compressed ? SessionFileCompression.unpacked(url) : url")
        && runner.contains("fileURL: watched,"))
check("…from the size of the text, in the plain file's bytes",
      runner.contains("AgentSessionScanner.contentSize(of: url) ?? 0"))
let view = source("SipAI-macOS/SipAI/Views/Chat/AgentSessionView.swift")
check("the transcript's partiality verdict weighs the decoded size",
      view.contains("? AgentSessionScanner.contentSize(of: file)"))
let codexSessions = source("SipAI-macOS/SipAI/Models/CodexSessions.swift")
let savedTier = codexSessions.components(separatedBy: "static func savedServiceTier(of url: URL)")
    .dropFirst().first.map { String($0.prefix(700)) } ?? ""
check("the saved-speed reader weighs a rollout's TEXT size, like every other codex reader (a compressed file is a quarter of its text)",
      !savedTier.isEmpty && savedTier.contains("AgentSessionScanner.contentSize(of: url)")
        && !savedTier.contains("attributesOfItem"))
let md = source("THIRD-PARTY-LICENSES.md")
let txt = source("SipAI-macOS/SipAI/Resources/THIRD-PARTY-LICENSES.txt")
let licence = source("SipAI-macOS/SipAI/Vendor/zstd/LICENSE")
check("zstd's licence travels with the source and with the app",
      !licence.isEmpty && md.contains("Zstandard") && txt.contains("Zstandard")
        && md.contains("Copyright (c) Meta Platforms, Inc. and affiliates.")
        && txt.contains("Copyright (c) Meta Platforms, Inc. and affiliates."))
#endif

finish()
