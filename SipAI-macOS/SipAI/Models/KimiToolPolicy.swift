// KimiToolPolicy.swift
// The one per-session, per-turn tool control kimi's print mode has:
// `sessions/<bucket>/<id>/tool-policy/state.json` =
// `{"disabledTools": [names…]}`, read by every `--prompt` turn.
//
// This is the third place SipAI writes into an agent's private store
// (`AgentSessionFork` and `AgentSessionRename` are the first two), and
// it is held to the same standard: the agent's own format, the smallest
// thing that works, restored afterwards, and REFUSED when the file's
// shape is not the measured one — a format that moved fails loud and
// never rewrites a file it cannot read.
//
// Measured on kimi-code 2.0.1 over a throwaway `KIMI_CODE_HOME` against a
// fake local provider (the harness reproduces every line):
//
//   * A file SipAI wrote with the session's tool names → the next
//     `--prompt --session` turn sent 0 tools (10 KB against 85 KB). A
//     Chat only turn lists every name but the web lookups it keeps
//     (`chatOnlyKeeps`), so it sends just those.
//   * `["*"]` is NOT honoured (the normal tool set comes back), so the
//     names must be spelled out — from the session's own
//     `llm.tools_snapshot` wire record, the newest one of an ORDINARY
//     turn: a Chat only turn records a snapshot of its kept web tools
//     alone (an empty one where it kept none), and "newest" alone would
//     hand the next Chat only turn that short list.
//   * Removing the file restores the tools.
//   * Kimi's own server writes the same file when a prompt carries
//     `disabled_tools`, and the file OUTLIVES the server — a later
//     `--prompt` turn honoured it — which is what makes a restore
//     mandatory: a session left with the file would be tool-less in the
//     user's terminal too. The restore is journaled in SipAI's config
//     BEFORE the write and healed at launch and on session open.
//   * A name the model does not currently offer is tolerated (a
//     26-name file on a 25-tool model → 0 tools), which is what lets the
//     written list be the UNION of the snapshot and the measured list.
//
// Pure over paths and bytes — no MainActor, no config — so the harness
// compiles it alone.

import Foundation

enum KimiToolPolicy {

    /// Every tool kimi-code 2.0.1 offers a print-mode session with
    /// image input available and no search provider (with one,
    /// `WebSearch` joins — see `chatOnlyKeeps`). The FALLBACK when no
    /// snapshot can be read
    /// (a session born through the server has no snapshot before its
    /// first prompt; a session born elsewhere may have a truncated
    /// wire), and the tripwire the harness compares a real snapshot
    /// against — a kimi that adds a tool fails the run, not the user.
    static let fallbackNames: [String] = [
        "Agent", "AgentSwarm", "AskUserQuestion", "Bash", "CreateGoal",
        "CronCreate", "CronDelete", "CronList", "Edit", "EnterPlanMode",
        "ExitPlanMode", "FetchURL", "GetGoal", "Glob", "Grep", "Read",
        "ReadMediaFile", "SetGoalBudget", "Skill", "TaskList", "TaskOutput",
        "TaskStop", "TodoList", "UpdateGoal", "WaitFor", "Write",
    ]

    /// The tools a Chat only turn KEEPS: looking things up on the web,
    /// what any chat uses to answer a question about now. `WebSearch`
    /// is offered only where kimi has a search provider — a kimi login
    /// (the managed provider's OAuth) or a `[services.moonshot_search]`
    /// section in config.toml — which is why the measured list above
    /// does not name it; `FetchURL` is offered everywhere, and fetches
    /// only public http(s) URLs (read out of kimi's own fetcher: another
    /// scheme is refused, and so is a host that is, or resolves to, a
    /// private or loopback address).
    static let chatOnlyKeeps: Set<String> = ["WebSearch", "FetchURL"]

    /// The one key the measured file carries.
    static let key = "disabledTools"

    /// `<sessionDir>/tool-policy/state.json`.
    static func disabledFile(sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("tool-policy", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    // MARK: - Names

    /// The `tools[].name` of the newest `llm.tools_snapshot` record in a
    /// wire that names a tool Chat only does NOT keep — the newest
    /// ORDINARY turn's — or nil when the wire holds none. A Chat only
    /// turn records its kept web tools alone (or nothing), and taking
    /// that for the session's list would leave on every tool the
    /// measured list does not name. A bounded tail read, like
    /// `KimiSessionScanner.lastContextTokens`; a snapshot is written per
    /// turn and the newest sits near the end.
    static func names(fromWire url: URL, budget: Int = 4 * 1024 * 1024) -> [String]? {
        guard let text = boundedTail(of: url, budget: budget) else { return nil }
        var newest: [String]? = nil
        text.enumerateLines { line, _ in
            // Cheap pre-filter; correctness comes from the parse.
            guard line.contains("llm.tools_snapshot") else { return }
            guard let data = line.trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  obj["type"] as? String == "llm.tools_snapshot",
                  let tools = obj["tools"] as? [[String: Any]]
            else { return }
            let found = tools.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
            if found.contains(where: { !chatOnlyKeeps.contains($0) }) { newest = found }
        }
        return newest
    }

    /// The newest ordinary-turn snapshot in the whole store, for a session
    /// that has none of its own: the wires under `root/*/*/agents/main/`,
    /// newest by modification date first, read until one answers.
    /// Bounded — at most `limit` wires are opened.
    static func newestNames(inStore root: URL, limit: Int = 12) -> [String]? {
        let fm = FileManager.default
        guard let buckets = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return nil }
        var wires: [(URL, Date)] = []
        for bucket in buckets {
            guard let sessions = try? fm.contentsOfDirectory(
                at: bucket, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for session in sessions where !session.lastPathComponent.hasPrefix(".") {
                let wire = session.appendingPathComponent("agents/main/wire.jsonl")
                guard let attrs = try? fm.attributesOfItem(atPath: wire.path),
                      let modified = attrs[.modificationDate] as? Date
                else { continue }
                wires.append((wire, modified))
            }
        }
        wires.sort { $0.1 > $1.1 }
        for (wire, _) in wires.prefix(limit) {
            if let found = names(fromWire: wire) { return found }
        }
        return nil
    }

    /// What is written: the session's snapshot (else the store's, else
    /// nothing) UNIONED with the measured list, less the web lookups
    /// Chat only keeps, sorted, deduplicated. A name the model does not
    /// offer is harmless (measured), and the union means a tool the
    /// snapshot happened to omit — `ReadMediaFile` on a text-only model
    /// — is still off if kimi offers it later.
    static func namesToDisable(sessionSnapshot: [String]?, storeSnapshot: [String]?) -> [String] {
        var set = Set(fallbackNames)
        if let own = sessionSnapshot {
            set.formUnion(own)
        } else if let store = storeSnapshot {
            set.formUnion(store)
        }
        return set.subtracting(chatOnlyKeeps).sorted()
    }

    // MARK: - The file's shape

    /// Exactly `{"disabledTools":[…]}`, the measured shape.
    static func encode(names: [String]) -> Data {
        // JSONSerialization escapes `/` and reorders nothing here (one
        // key); written compact, the way kimi writes it.
        (try? JSONSerialization.data(withJSONObject: [key: names])) ?? Data()
    }

    /// The names out of a file, or nil when the bytes are not the
    /// measured shape — one JSON object, one key, an array of strings.
    /// nil is a REFUSAL upstream, never an empty list: a shape this
    /// reader does not know is a file it must not rewrite.
    static func decode(_ data: Data) -> [String]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj.count == 1,
              let raw = obj[key] as? [Any]
        else { return nil }
        var names: [String] = []
        for item in raw {
            guard let name = item as? String else { return nil }
            names.append(name)
        }
        return names
    }

    // MARK: - Capture / write / restore

    /// What was there BEFORE the write, so it can be put back.
    enum RestoreRecord: Equatable {
        /// No file — the restore removes ours.
        case absent
        /// The file's exact bytes — the restore writes them back.
        case content(String)
    }

    enum Capture: Equatable {
        case record(RestoreRecord)
        /// A file is there and its shape is not the measured one. The
        /// send is refused; nothing is written.
        case unknownShape
    }

    static func capture(at file: URL) -> Capture {
        guard let data = try? Data(contentsOf: file) else { return .record(.absent) }
        guard decode(data) != nil, let text = String(data: data, encoding: .utf8)
        else { return .unknownShape }
        return .record(.content(text))
    }

    /// Write the policy file. The directory is made if missing (a
    /// session that never carried a policy has no `tool-policy/`).
    static func write(names: [String], to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(names: names).write(to: file, options: .atomic)
    }

    /// Put back what `capture` saw. Idempotent: restoring `.absent` over
    /// a missing file is a no-op, and restoring content over identical
    /// bytes rewrites nothing.
    static func restore(_ record: RestoreRecord, at file: URL) throws {
        let fm = FileManager.default
        switch record {
        case .absent:
            if fm.fileExists(atPath: file.path) {
                try fm.removeItem(at: file)
            }
        case .content(let text):
            let data = Data(text.utf8)
            if let existing = try? Data(contentsOf: file), existing == data { return }
            try fm.createDirectory(at: file.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
    }

    // MARK: - Journal codec

    /// The record as config stores it (`kimi_tool_policy_restores`:
    /// session id → this dictionary). Two spellings, no third.
    static func encodeRecord(_ record: RestoreRecord) -> [String: String] {
        switch record {
        case .absent: return ["state": "absent"]
        case .content(let text): return ["state": "content", "content": text]
        }
    }

    static func decodeRecord(_ dict: [String: String]) -> RestoreRecord? {
        switch dict["state"] {
        case "absent": return .absent
        case "content": return dict["content"].map { .content($0) }
        default: return nil
        }
    }

    // MARK: - Helpers

    /// The tail of a file up to `budget` bytes, decoded lossily — the
    /// same rule every store read in this app follows, restated here so
    /// this file has no dependency on the scanners.
    private static func boundedTail(of url: URL, budget: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(budget) ? size - UInt64(budget) : 0
        do {
            try handle.seek(toOffset: start)
            guard let data = try handle.readToEnd() else { return "" }
            var text = String(decoding: data, as: UTF8.self)
            // A cut that landed mid-line: drop the partial first line.
            if start > 0, let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            return text
        } catch {
            return nil
        }
    }
}
