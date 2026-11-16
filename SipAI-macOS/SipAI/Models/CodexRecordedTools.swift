// CodexRecordedTools.swift
// What a Codex tool row is made of, on both of codex's feeds — the live
// items (`codex exec --json`, the app-server) and the session file's
// records — so a row reads the same while the turn runs and after a
// reopen.
//
// Codex's code mode runs a script (an `exec` call) that calls the real
// tools inside it. The live feed sends what the script ran as items of
// their own — a command, a file change, a search, an image viewed — and
// never the script. The session file keeps the script as the model's call,
// and what it ran as `item_completed` records in the shape of those items.
// A direct call (`exec_command`, `apply_patch`, `view_image`) is recorded
// the same way, its record carrying the call's own id. So a reopen draws
// the records, and draws a call only where codex recorded nothing for it:
// an older codex wrote no command records, and its scripts are all there
// is of what ran.

import Foundation

/// A Codex tool row's input, in ONE shape whichever feed the row came off.
enum CodexToolInput {
    /// The row names codex gives a file change: `codex exec`'s item type
    /// and its older spelling.
    static let fileChangeNames: Set<String> = ["file_change", "patch_apply"]

    /// A file change's files, from a live item's `changes`: `codex exec`
    /// lists `{path, kind}`, and the app-server's list comes through
    /// `CodexAppServer.execItem` in that shape with each file's `diff` and
    /// `move_path` beside. Sorted by path, as `fileChange(fromRecordChanges:)`
    /// is: the record keeps the files as a map, whose order does not
    /// survive reading it.
    static func fileChange(fromItemChanges raw: Any?) -> [String: Any] {
        let changes: [[String: Any]] = (raw as? [Any] ?? []).compactMap { entry in
            guard let change = entry as? [String: Any],
                  let path = change["path"] as? String, !path.isEmpty else { return nil }
            var out: [String: Any] = ["path": path, "kind": change["kind"] as? String ?? "update"]
            if let moved = change["move_path"] as? String, !moved.isEmpty { out["move_path"] = moved }
            if let diff = change["diff"] as? String { out["diff"] = diff }
            return out
        }
        return ["changes": changes.sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }]
    }

    /// The same files from the session file's record, which maps each
    /// path to what happened to it: `{type: "add", content}`, `{type:
    /// "update", unified_diff, move_path}`, `{type: "delete", content}`.
    /// The live item's `diff` is the added file's content and the edited
    /// file's unified diff, which is what this hands on under that name.
    static func fileChange(fromRecordChanges raw: Any?) -> [String: Any] {
        let map = raw as? [String: Any] ?? [:]
        let changes: [[String: Any]] = map.keys.sorted().compactMap { path in
            guard !path.isEmpty, let change = map[path] as? [String: Any] else { return nil }
            var out: [String: Any] = ["path": path, "kind": change["type"] as? String ?? "update"]
            if let moved = change["move_path"] as? String, !moved.isEmpty { out["move_path"] = moved }
            if let diff = (change["unified_diff"] as? String) ?? (change["content"] as? String) {
                out["diff"] = diff
            }
            return out
        }
        return ["changes": changes]
    }

    /// A command as the session file's record keeps it — `[shell, flag,
    /// command]`, the command codex ran inside a login shell — as the
    /// command alone: what the live row shows once `CodexEventParser`
    /// takes the same wrapper off the live item's string.
    static func command(fromRecordCommand raw: Any?) -> String {
        if let text = raw as? String { return text }
        let parts = (raw as? [Any] ?? []).compactMap { $0 as? String }
        if parts.count == 3, shells.contains(parts[0]), parts[1] == "-lc" || parts[1] == "-c" {
            return parts[2]
        }
        return parts.joined(separator: " ")
    }

    private static let shells: Set<String> = ["/bin/zsh", "/bin/bash", "/bin/sh", "zsh", "bash", "sh"]

    /// The row an image codex viewed is drawn as (`view_image`, called
    /// directly or from a script): the app-server's `imageView` item, in
    /// exec's spelling — `codex exec` itself prints none — and the
    /// session file's `ImageView` record.
    static let imageViewName = "image_view"

    /// The viewed file as the live item names it — a plain path — from the
    /// record, which names it as a `file://` URL.
    static func imagePath(fromRecordPath raw: Any?) -> String {
        guard let text = raw as? String else { return "" }
        guard text.hasPrefix("file://") else { return text }
        if let url = URL(string: text), url.isFileURL { return url.path }
        let rest = String(text.dropFirst("file://".count))
        return rest.removingPercentEncoding ?? rest
    }
}

/// The calls a reopen of a Codex session holds back until codex says what
/// they ran — one per `CodexSessionScanner.RolloutDecoder`, fed the calls,
/// their outputs, codex's records and the turn's end.
///
/// - A record of a command, a file change or an image viewed is a row (the
///   live item's), and a call the record speaks for — by its id for a
///   direct call; for a script, any such record, or a search's, that lands
///   while it is open — is not.
/// - A call codex recorded nothing for is drawn where it ran: once its
///   output has landed, at the next call or the agent's next words. One
///   whose output says it still runs (a background terminal, a script
///   that yielded) waits for its record, or for the turn's end.
/// - A script that calls no tool (`tools.…`) is never drawn: the live feed
///   sends nothing for one.
/// - Codex's own plumbing — `wait` on a script, `sleep`, `write_stdin` —
///   is never a row; the live feed sends no item for any of them.
struct CodexRecordedTools {
    private struct Held {
        let callId: String
        let row: AgentSessionHistoryItem
        let isScript: Bool
        let drivesTools: Bool
        var finished = false
        var running = false
    }

    private var held: [Held] = []
    /// Direct calls drawn as their own row because their output landed with
    /// no record: a record that comes after all adds its output to that row.
    private var drawnCalls: Set<String> = []
    /// Set by a reader that starts past the file's start — the watcher of a
    /// turn run elsewhere, which starts where the reading of the file it
    /// joins ended — until the turn's end. A call made before it started was
    /// drawn by that reading, so a record of one is not a row of its own:
    /// drawn here as well, the session showed the command twice.
    var joinedMidTurn = false

    init() {}

    /// Item kinds codex records that are not a tool's work.
    private static let notToolItems: Set<String> = [
        "UserMessage", "AgentMessage", "Reasoning", "ContextCompaction",
        "EnteredReviewMode", "ExitedReviewMode", "Plan", "HookPrompt",
    ]

    /// Codex's own calls that are never a row. Its tools carry no namespace
    /// (`sleep` its `clock` one); an MCP server's tool of the same name
    /// carries the server's, and is drawn.
    static func isPlumbing(name: String, namespace: String?) -> Bool {
        switch name {
        case "wait", "write_stdin": return namespace == nil
        case "sleep": return namespace == nil || namespace == "clock"
        default: return false
        }
    }

    /// The calls whose work codex records as an item of its own: the
    /// code-mode script, and the direct command, patch and image calls.
    static func isRecorded(name: String, namespace: String?) -> Bool {
        namespace == nil && ["exec", "exec_command", "apply_patch", "view_image"].contains(name)
    }

    /// Hold a call until codex says what it ran.
    mutating func hold(callId: String, row: AgentSessionHistoryItem, isScript: Bool, input: String) {
        held.append(Held(callId: callId, row: row, isScript: isScript,
                         drivesTools: !isScript || input.contains("tools.")))
    }

    /// A call's output has landed — a string, or the content items a
    /// script's output is kept as. A still-running one keeps waiting:
    /// codex's own words to the model for a command left in a background
    /// terminal, and for a script that yielded.
    mutating func output(callId: String, raw: Any?) {
        guard let index = held.firstIndex(where: { $0.callId == callId }) else { return }
        let text = (raw as? String) ?? (raw as? [Any] ?? [])
            .compactMap { ($0 as? [String: Any])?["text"] as? String }
            .joined(separator: "\n")
        held[index].finished = true
        held[index].running = text.contains("Script running with cell ID")
            || text.contains("Process running with session ID")
    }

    /// The next call, or the agent's words: what finished with nothing
    /// recorded for it is drawn where it ran.
    mutating func boundary() -> [AgentSessionHistoryItem] {
        var out: [AgentSessionHistoryItem] = []
        var kept: [Held] = []
        for call in held {
            if call.finished, !call.running {
                if let row = draw(call) { out.append(row) }
            } else {
                kept.append(call)
            }
        }
        held = kept
        return out
    }

    /// The turn has ended (or a reading of the file has): everything still
    /// held is drawn, so nothing that ran is lost. What follows is read from
    /// its start.
    mutating func turnEnded() -> [AgentSessionHistoryItem] {
        let out = held.compactMap { draw($0) }
        held = []
        joinedMidTurn = false
        return out
    }

    /// One of codex's `item_completed` records: the rows it draws, or nil
    /// for a record that is not a command or a file change (its reader
    /// reads it as before — a search's is a row of the reader's own, which
    /// takes the place of the script it ran in).
    mutating func record(_ item: [String: Any]) -> [AgentSessionHistoryItem]? {
        guard let type = item["type"] as? String, !Self.notToolItems.contains(type) else { return nil }
        let id = item["id"] as? String ?? ""
        let name: String
        let input: [String: Any]
        let output: String
        let failed: Bool
        switch type {
        case "CommandExecution":
            // The user's own `!` command: drawn from the message codex keeps
            // of it, never as the agent's.
            if (item["source"] as? String) == "user_shell" { return [] }
            name = "command_execution"
            input = ["command": CodexToolInput.command(fromRecordCommand: item["command"])]
            output = item["aggregated_output"] as? String ?? ""
            let exit = (item["exit_code"] as? NSNumber)?.intValue ?? 0
            failed = (item["status"] as? String) == "failed" || exit != 0
        case "FileChange":
            name = "file_change"
            input = CodexToolInput.fileChange(fromRecordChanges: item["changes"])
            failed = (item["status"] as? String) == "failed"
            output = failed ? (item["stderr"] as? String ?? "") : ""
        case "ImageView":
            name = CodexToolInput.imageViewName
            input = ["path": CodexToolInput.imagePath(fromRecordPath: item["path"])]
            output = ""
            failed = false
        default:
            // A search's record is drawn by the reader, in place of the
            // script that ran it. A record of anything else no row is drawn
            // from (an image viewed, an MCP tool, a subagent) leaves the
            // script alone: dropped there, a script that did only that
            // would vanish from the reopened session.
            if CodexSessionScanner.isWebSearchItem(item) { held.removeAll { $0.isScript } }
            return nil
        }
        let seen = drawnCalls.contains(id) || held.contains { $0.isScript || $0.callId == id }
        held.removeAll { $0.isScript || $0.callId == id }
        if !seen, joinedMidTurn { return [] }
        let rowId = id.isEmpty ? UUID().uuidString : id
        let result = AgentSessionHistoryItem(
            kind: .toolResult(toolUseId: rowId, content: output, isError: failed))
        if drawnCalls.contains(id) { return [result] }
        return [AgentSessionHistoryItem(kind: .toolUse(id: rowId, name: name, input: input)), result]
    }

    private mutating func draw(_ call: Held) -> AgentSessionHistoryItem? {
        guard call.drivesTools else { return nil }
        if !call.isScript { drawnCalls.insert(call.callId) }
        return call.row
    }
}

extension CodexSessionScanner.RolloutDecoder {
    /// The end of a reading of the file: what its last turn still held is
    /// drawn. A reader that reads the file to its end calls this after the
    /// last line; a watcher of a turn running elsewhere is told by the
    /// turn's own end.
    mutating func finish() -> [AgentSessionHistoryItem] {
        recordedTools.turnEnded()
    }
}
