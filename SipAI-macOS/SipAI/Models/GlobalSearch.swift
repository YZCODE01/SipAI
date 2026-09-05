// GlobalSearch.swift
// The toolbar magnifying glass: one query across every chat, every
// note, and every agent session this machine has — message BODIES, not
// just titles.
//
// The cost is entirely on the session side. Chats and notes are already
// resident (small); the agent transcripts run to hundreds of MB, and
// reading them is what this file is arranged around:
//
// * **Newest first, streamed.** Documents are searched in activity
//   order and results are delivered in batches, so the sessions most
//   likely to be wanted appear while the long tail is still being read.
//   Nothing waits for the whole corpus.
// * **One MainActor hop per batch**, never per result. Same rule as
//   `AgentSessionTailer.processData`: a hop per row is a re-render per
//   row, and the palette re-renders its whole list on each.
// * **Extraction is cached by (size, mtime)** and evicted LRU under a
//   byte budget. Refining a query — which is what typing IS — then
//   costs a substring scan over hot text instead of hundreds of MB
//   of JSON.
//   A file whose bytes changed is re-read, because its cache entry
//   describes a file that no longer exists.
// * **Every read stays bounded.** `searchByteBudget` is deliberately
//   larger than the 8 MB the transcript reader uses (the point is to
//   find things off the end of the loaded window) and still a bound —
//   see `AgentSessionScanner.readHistory`.
//
// Cancellation is per keystroke: a new query cancels the running task
// before starting, so a slow corpus can never deliver a stale answer
// over a fresh one.

import Foundation
import SwiftUI

// MARK: - Targets and results

/// Where a result lives — everything the router needs to open it.
enum SearchTarget: Equatable {
    case chat(slug: String, project: String?)
    case note(slug: String)
    case session(id: String, fileURL: URL, agentKey: String)
}

/// One conversation, note or session that matched.
struct GlobalSearchResult: Identifiable, Equatable {
    let id: String
    let target: SearchTarget
    let title: String
    /// Folder, project, or agent label — whatever tells two same-named
    /// rows apart.
    let subtitle: String
    /// Text around the FIRST match, with that match's range inside the
    /// snippet (not inside the source).
    let snippet: String
    let snippetMatch: Range<String.Index>
    let matchCount: Int
    let activityAt: Date

    /// Which list this row belongs under.
    let section: SearchSection

    static func == (lhs: GlobalSearchResult, rhs: GlobalSearchResult) -> Bool {
        lhs.id == rhs.id && lhs.matchCount == rhs.matchCount
            && lhs.snippet == rhs.snippet
    }
}

/// Result grouping. Sessions carry their agent key so the palette can
/// name the section with the user's own label for that CLI — no
/// user-visible sentence in this app names an agent outright.
enum SearchSection: Equatable, Hashable {
    case chats
    case notes
    case sessions(agentKey: String)

    /// Fixed display order; sessions sort among themselves by agent key
    /// so the list never reshuffles between queries.
    var rank: Int {
        switch self {
        case .chats: return 0
        case .notes: return 1
        case .sessions: return 2
        }
    }
}

// MARK: - Document seeds

/// A searchable thing, as snapshotted on the MainActor before the
/// search goes off-main. Chats and notes carry their body inline (they
/// are already in memory); a session carries only its file, because
/// reading it is the expensive part that must not happen here.
struct SearchDocumentSeed {
    let target: SearchTarget
    let title: String
    let subtitle: String
    let activityAt: Date
    let section: SearchSection
    /// Resident text, or nil when the body has to be read from `fileURL`.
    let body: String?
    let fileURL: URL?

    var id: String {
        switch target {
        case .chat(let slug, let project): return "chat:\(project ?? "")/\(slug)"
        case .note(let slug): return "note:\(slug)"
        case .session(let id, _, _): return "session:\(id)"
        }
    }
}

// MARK: - Extraction

enum SearchTextExtractor {

    /// Tail budget for indexing. Bigger than the transcript reader's
    /// 8 MB on purpose — global search exists to find what the loaded
    /// window cannot — and still a bound.
    static let searchByteBudget = 64 * 1024 * 1024

    /// Per-record cap on flattened tool input. A single `Write` call
    /// can carry an entire file; without a cap one record could
    /// dominate the document (and the cache).
    private static let perRecordCap = 64 * 1024

    /// Whole-conversation plain text for one session file.
    ///
    /// Goes through the SAME `readHistory` the transcript uses, rather
    /// than a second JSONL walk. Three schemas already need three
    /// readers; a fourth spelling of "what is in this file" is how the
    /// two sides of search come to disagree about what exists.
    static func sessionText(at url: URL, agentKey: String) -> String {
        let items: [AgentSessionHistoryItem]
        switch agentKey {
        case "codex":
            items = CodexSessionScanner.readHistory(
                of: url, maxTurns: .max, byteBudget: searchByteBudget)
        case "kimi":
            items = KimiSessionScanner.readHistory(
                of: url, maxTurns: .max, byteBudget: searchByteBudget)
        default:
            items = AgentSessionScanner.readHistory(
                of: url, maxTurns: .max, byteBudget: searchByteBudget)
        }
        return flatten(items)
    }

    /// History items as one searchable string, in transcript order.
    static func flatten(_ items: [AgentSessionHistoryItem]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(items.count)
        for item in items {
            switch item.kind {
            case .userText(let text), .assistantText(let text):
                parts.append(text)
            case .toolUse(_, let name, let input):
                var piece = AgentRendering.displayToolName(name)
                let flat = flattenInput(input)
                if !flat.isEmpty { piece += "\n" + flat }
                parts.append(piece)
            case .toolResult(_, let content, _):
                parts.append(String(content.prefix(perRecordCap)))
            case .interrupted(let message):
                parts.append(message)
            case .compaction:
                // The row's text is composed at RENDER time from
                // localized strings, so there is nothing here that a
                // query could match against what is on screen. Matching
                // is defined on DISPLAYED text; the alternative is a
                // result that highlights nothing.
                break
            }
        }
        return parts.joined(separator: "\n")
    }

    /// A tool call's arguments as text. Keys are included: `file_path`
    /// is as likely a thing to look for as its value.
    private static func flattenInput(_ input: [String: Any]) -> String {
        var out = ""
        // Sorted so the same call always flattens the same way — an
        // unordered walk would change the snippet between two searches
        // of the same session.
        for key in input.keys.sorted() {
            guard out.count < perRecordCap else { break }
            out += key + ": " + describe(input[key]) + "\n"
        }
        return String(out.prefix(perRecordCap))
    }

    private static func describe(_ value: Any?) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return a.map { describe($0) }.joined(separator: " ")
        case let d as [String: Any]:
            return d.keys.sorted()
                .map { "\($0): " + describe(d[$0]) }
                .joined(separator: " ")
        default: return ""
        }
    }
}

// MARK: - Extracted-text cache

/// Extracted session text, keyed by file identity `(size, mtime)` and
/// bounded by total bytes.
///
/// The identity is the same pair `cachedLastUserMessageDate` keys on:
/// a file whose size and mtime are unchanged cannot have changed
/// content in any way this app produces, and one that HAS changed must
/// be re-read rather than answered from a description of a file that no
/// longer exists.
///
/// Lock-guarded rather than actor-isolated because it is read from the
/// search task's own thread, in a tight loop, and an actor hop per
/// document would cost more than the substring scan it guards.
final class SessionTextCache {
    static let shared = SessionTextCache()

    private struct Entry {
        let size: UInt64
        let mtime: Date
        let text: String
    }

    private var entries: [URL: Entry] = [:]
    /// Insertion/refresh order, oldest first — the eviction queue.
    private var order: [URL] = []
    private var bytes: Int = 0
    private let lock = NSLock()

    /// Sized so the sessions anyone actually revisits stay hot while
    /// the tail is re-read on demand.
    private let byteBudget = 48 * 1024 * 1024

    func text(for url: URL, agentKey: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast

        lock.lock()
        if let hit = entries[url], hit.size == size, hit.mtime == mtime {
            lock.unlock()
            return hit.text
        }
        lock.unlock()

        // Read OUTSIDE the lock: this is the multi-second part, and
        // holding the lock across it would serialise every concurrent
        // reader behind the slowest file.
        let text = SearchTextExtractor.sessionText(at: url, agentKey: agentKey)

        lock.lock()
        if let existing = entries[url] {
            bytes -= existing.text.utf8.count
            order.removeAll { $0 == url }
        }
        entries[url] = Entry(size: size, mtime: mtime, text: text)
        order.append(url)
        bytes += text.utf8.count
        while bytes > byteBudget, let oldest = order.first, order.count > 1 {
            if let dropped = entries.removeValue(forKey: oldest) {
                bytes -= dropped.text.utf8.count
            }
            order.removeFirst()
        }
        lock.unlock()
        return text
    }
}

// MARK: - Engine

@MainActor
final class GlobalSearchEngine: ObservableObject {
    @Published private(set) var results: [GlobalSearchResult] = []
    @Published private(set) var isSearching: Bool = false
    /// Documents examined / total, so a long first pass can say so
    /// rather than looking stalled.
    @Published private(set) var scanned: Int = 0
    @Published private(set) var total: Int = 0
    /// The query the CURRENT `results` answer — not what is in the
    /// field. The two differ while a search is in flight, and the
    /// palette needs the former to avoid captioning stale rows with a
    /// new query.
    @Published private(set) var settledQuery: String = ""

    private var task: Task<Void, Never>?

    /// How many results are collected before the first MainActor
    /// delivery, and per delivery after. Small enough that the first
    /// screenful appears immediately, large enough that a corpus-wide
    /// sweep is not one re-render per hit.
    private let batchSize = 8

    /// Hard cap on the result list. A one-letter query matches nearly
    /// everything, and a list nobody can read is not worth the memory
    /// or the re-renders. The palette says when this bites.
    private let resultCap = 200

    func cancel() {
        task?.cancel()
        task = nil
        isSearching = false
    }

    func reset() {
        cancel()
        results = []
        scanned = 0
        total = 0
        settledQuery = ""
    }

    /// Run `query` over `seeds` (already snapshotted by the caller).
    func search(_ query: String, seeds: [SearchDocumentSeed]) {
        cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            scanned = 0
            total = 0
            settledQuery = ""
            return
        }
        results = []
        scanned = 0
        total = seeds.count
        settledQuery = trimmed
        isSearching = true

        task = Task { [batchSize, resultCap] in
            for await chunk in Self.chunks(query: trimmed, seeds: seeds,
                                           batchSize: batchSize,
                                           resultCap: resultCap) {
                if Task.isCancelled { break }
                // ONE MainActor delivery per chunk, results and progress
                // together — a hop per result is a whole-list re-render
                // per result, and the two arriving separately would let
                // the palette render a count its rows disagree with.
                if !chunk.results.isEmpty {
                    results.append(contentsOf: chunk.results)
                }
                scanned = chunk.scanned
            }
            guard !Task.isCancelled else { return }
            scanned = seeds.count
            isSearching = false
        }
    }

    private struct SearchChunk {
        var results: [GlobalSearchResult] = []
        var scanned: Int = 0
    }

    /// The corpus sweep, off-main, yielding as it goes. Ordering is the
    /// caller's (newest first), so the first chunk holds the sessions
    /// most likely to be wanted.
    private static func chunks(query: String,
                               seeds: [SearchDocumentSeed],
                               batchSize: Int,
                               resultCap: Int) -> AsyncStream<SearchChunk> {
        AsyncStream { continuation in
            let work = Task.detached(priority: .userInitiated) {
                var batch: [GlobalSearchResult] = []
                var emitted = 0
                var scanned = 0
                // Progress must move even across a long run of
                // non-matching documents, or a corpus sweep that
                // matches nothing reads as a hang.
                var sinceYield = 0
                for seed in seeds {
                    if Task.isCancelled { break }
                    scanned += 1
                    sinceYield += 1
                    let body: String
                    if let resident = seed.body {
                        body = resident
                    } else if let url = seed.fileURL,
                              case .session(_, _, let agentKey) = seed.target {
                        body = SessionTextCache.shared.text(for: url,
                                                            agentKey: agentKey)
                    } else {
                        body = ""
                    }
                    let count = SearchMatching.count(of: query, in: body)
                    if count > 0,
                       let snip = SearchMatching.snippet(of: query, in: body) {
                        batch.append(GlobalSearchResult(
                            id: seed.id,
                            target: seed.target,
                            title: seed.title,
                            subtitle: seed.subtitle,
                            snippet: snip.text,
                            snippetMatch: snip.match,
                            matchCount: count,
                            activityAt: seed.activityAt,
                            section: seed.section))
                        emitted += 1
                    }
                    if batch.count >= batchSize || sinceYield >= 24 {
                        continuation.yield(SearchChunk(results: batch,
                                                       scanned: scanned))
                        batch = []
                        sinceYield = 0
                    }
                    if emitted >= resultCap { break }
                }
                continuation.yield(SearchChunk(results: batch, scanned: scanned))
                continuation.finish()
            }
            // Cancelling the consumer (a new keystroke) has to stop the
            // producer, or a slow sweep keeps reading files for a query
            // nobody is waiting on any more.
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Whether the result list was truncated by `resultCap`.
    var hitResultCap: Bool { results.count >= resultCap }
}
