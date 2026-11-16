// LiveRuns.swift — the plumbing section 6 drives the real CLIs with: the
// stand-in model endpoint, a child run to its end, and a `codex app-server`
// conversation. Nothing here reads a row; main.swift does.

import Foundation

/// Lines as they arrive on a pipe, from any thread.
final class LineCollector {
    private let lock = NSLock()
    private var pending = Data()
    private var lines: [String] = []

    func take(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

func jsonObject(_ text: String) -> [String: Any]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let start = trimmed.firstIndex(of: "{") else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(trimmed[start...].utf8))) as? [String: Any]
}

func jsonLine(_ object: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

/// A folder of its own under the temporary directory, by its real path:
/// codex and kimi each record the folder they ran in resolved.
func scratchFolder(_ name: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("toolrows-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    guard let resolved = realpath(url.path, nil) else { return url }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

/// The environment a CLI runs in here: this one's, less anything that
/// would point it at the user's own store.
let isolatedEnvironment: [String: String] = ProcessInfo.processInfo.environment.filter {
    !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("KIMI") && !$0.key.hasPrefix("CODEX")
}

/// The ChatOnlyMode stand-in, answering `flag`'s scripted route; its port.
func startStandIn(_ server: String, flag: String, script: [[String: Any]], in dir: URL) -> (Process, String)? {
    guard FileManager.default.fileExists(atPath: server) else { return nil }
    let record = dir.appendingPathComponent("requests"), scriptFile = dir.appendingPathComponent("script.json")
    try? FileManager.default.createDirectory(at: record, withIntermediateDirectories: true)
    guard let data = try? JSONSerialization.data(withJSONObject: script),
          (try? data.write(to: scriptFile)) != nil else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-I", server, record.path, flag, scriptFile.path]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    var pending = Data()
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        let chunk = out.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        pending.append(chunk)
        let text = String(decoding: pending, as: UTF8.self)
        if let range = text.range(of: #"PORT=(\d+)"#, options: .regularExpression) {
            return (process, String(text[range].dropFirst(5)))
        }
    }
    process.terminate()
    return nil
}

/// Run `binary` to its end (bounded), stdin at EOF as SipAI hands it; its
/// stdout lines.
func runToEnd(_ binary: String, _ arguments: [String], cwd: URL, env: [String: String],
              limit: TimeInterval) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    process.environment = env
    process.standardInput = FileHandle.nullDevice
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    let lines = LineCollector()
    out.fileHandleForReading.readabilityHandler = { lines.take($0.availableData) }
    guard (try? process.run()) != nil else { return [] }
    let deadline = Date().addingTimeInterval(limit)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    if process.isRunning {
        process.terminate()
        Thread.sleep(forTimeInterval: 1)
    }
    Thread.sleep(forTimeInterval: 0.3)
    out.fileHandleForReading.readabilityHandler = nil
    lines.take(out.fileHandleForReading.readDataToEndOfFile())
    return lines.all
}

/// Files under `root` whose name starts with `prefix`.
func files(startingWith prefix: String, under root: URL) -> [URL] {
    let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
    return all.filter { $0.lastPathComponent.hasPrefix(prefix) }
}

/// One `codex app-server` conversation, a line at a time.
final class AppServerConversation {
    private let process = Process()
    private let input = Pipe()
    private let output = LineCollector()
    private var nextId = 1

    init?(codex: String, cwd: URL, env: [String: String]) {
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = ["app-server"]
        process.currentDirectoryURL = cwd
        process.environment = env
        process.standardInput = input
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let collector = output
        out.fileHandleForReading.readabilityHandler = { collector.take($0.availableData) }
        guard (try? process.run()) != nil else { return nil }
    }

    /// Everything codex has said so far, in order.
    var received: [[String: Any]] { output.all.compactMap(jsonObject) }

    func notify(_ method: String) {
        send(["jsonrpc": "2.0", "method": method, "params": [String: Any]()])
    }

    /// A request, and codex's answer to it — nil past `limit`.
    func request(_ method: String, _ params: [String: Any], limit: TimeInterval = 30) -> [String: Any]? {
        let id = nextId
        nextId += 1
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return wait(limit: limit) { ($0["id"] as? Int) == id && $0["method"] == nil }
    }

    /// The first thing codex said that `matches`, or nil past `limit`.
    func wait(limit: TimeInterval, until matches: ([String: Any]) -> Bool) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if let found = received.first(where: matches) { return found }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    /// stdin closed, as SipAI ends a conversation; the child waited for.
    func close() {
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate() }
    }

    private func send(_ object: [String: Any]) {
        input.fileHandleForWriting.write(Data((jsonLine(object) + "\n").utf8))
    }
}
