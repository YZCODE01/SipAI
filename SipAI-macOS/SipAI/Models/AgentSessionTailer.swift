// AgentSessionTailer.swift
// DispatchSource-based monitor that tails a single Claude Code session
// JSONL and streams new NDJSON records out as `StreamEvent`s via a
// MainActor callback.
//
// Ownership: one tailer per live `AgentRunner`. The runner suspends
// the tailer for the duration of its own `claude -p` subprocess run
// and resumes it at the current EOF afterwards so records the
// subprocess just wrote aren't re-rendered.
//
// External-in-progress tracking follows one canonical rule set: the
// flag may flip false ONLY on a result record, an assistant record
// with a terminating stop_reason, a system record with a turn-end
// subtype, or the synthetic "[Request interrupted by user…]" user
// message. Metadata records and mid-turn narration carry no signal.
// Three fallbacks close the gaps, all on the 3s sweep: the
// ~/.claude/sessions status files force TRUE while a busy record's
// pid lives; the same store saying "not busy" for the session (plus
// 3s of JSONL quiet) is the canonical tie-breaker that flips FALSE;
// and a 300s staleness guard covers writers that die leaving no
// status record at all. Do NOT reintroduce text-only/tool_use
// heuristics here — they would un-gate Send mid-external-turn.

import Foundation
import Darwin

final class AgentSessionTailer: @unchecked Sendable {

    // MARK: - Callbacks

    /// Called on the MainActor with all StreamEvents parsed from one
    /// read burst. The runner appends them in a single mutation —
    /// per-line delivery would schedule one MainActor task and one
    /// SwiftUI re-render per JSONL line, saturating the main thread
    /// whenever a fast external turn streams.
    private let onEvents: @MainActor ([StreamEvent]) -> Void

    /// Called on the MainActor whenever the internal `externalInProgress`
    /// flag transitions. Not fired if the new value equals the old.
    private let onExternalInProgressChange: @MainActor (Bool) -> Void

    // MARK: - Fixed config

    /// JSONL path being tailed.
    let fileURL: URL

    /// cwd used as a fallback when a system.init event carries no `cwd`.
    private let fallbackCwd: URL

    /// How long of silence before `externalInProgress` is force-cleared
    /// even without an explicit "turn complete" assistant message.
    private static let staleAfter: TimeInterval = 300.0

    // MARK: - State (all accesses on `queue`)

    private let queue: DispatchQueue

    /// Open fd for reads. `-1` when not open.
    private var fd: Int32 = -1

    /// DispatchSource watching fd for `.extend` events.
    private var source: DispatchSourceFileSystemObject?

    /// Fallback polling source when we couldn't open the fd at start
    /// time (file doesn't exist yet).
    private var fallbackTimer: DispatchSourceTimer?

    /// Staleness sweep timer. Fires every 10s; clears
    /// `externalInProgress` after `staleAfter` of quiet.
    private var staleTimer: DispatchSourceTimer?

    /// Byte offset we've read up to in the file. Reset by `resume(atOffset:)`.
    private var offset: UInt64 = 0

    /// Partial-line buffer for NDJSON splits that straddle a read
    /// chunk. Kept as raw bytes: a read() can end mid-UTF-8-sequence,
    /// and decoding must only ever happen on complete lines.
    private var leftoverData = Data()

    /// `true` while the DispatchSource has been suspended via
    /// `suspend()`. Prevents double-suspend (which would underflow
    /// DispatchSource's suspend count and crash on later resume).
    private var isSuspended: Bool = false

    /// `true` once `stop()` has run. Guards against re-entry.
    private var isStopped: Bool = false

    /// Current externalInProgress flag. Read and written on `queue`.
    private var externalInProgress: Bool = false

    /// Last time we saw *any* activity from the tailed file.
    private var lastActivityAt: Date = .distantPast

    /// True once claude's status store has ever named this session
    /// during this tailer's life. It distinguishes "this claude writes
    /// heartbeats and its one just disappeared" (writer gone) from
    /// "nothing here writes heartbeats at all" (no signal either way) —
    /// see the `.unknown` branch of the sweep.
    private var sawStatusRecord: Bool = false

    // MARK: - Init

    init(fileURL: URL,
         fallbackCwd: URL,
         onEvents: @escaping @MainActor ([StreamEvent]) -> Void,
         onExternalInProgressChange: @escaping @MainActor (Bool) -> Void) {
        self.fileURL = fileURL
        self.fallbackCwd = fallbackCwd
        self.onEvents = onEvents
        self.onExternalInProgressChange = onExternalInProgressChange
        self.queue = DispatchQueue(
            label: "sipai.tailer.\(UUID().uuidString)",
            qos: .utility
        )
    }

    deinit {
        // Last-resort cleanup if the owner forgot to call stop().
        // deinit implies zero references, so no queue races are
        // possible; cancel() is thread-safe, and a suspended source
        // must be resumed before release or libdispatch traps. The
        // source's cancel handler closes the fd it captured by value.
        staleTimer?.cancel()
        fallbackTimer?.cancel()
        if let s = source {
            s.cancel()
            if isSuspended { s.resume() }
        } else if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    // MARK: - Lifecycle

    /// Open the fd, wire the DispatchSource, and start watching at
    /// `initialOffset`. Safe to call once per instance. If the file
    /// can't be opened (e.g. it doesn't exist yet), falls back to a
    /// 0.5s polling timer that retries the open.
    func start(initialOffset: UInt64) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.source == nil, !self.isStopped else { return }
            self.offset = initialOffset
            self.lastActivityAt = Date()
            self.installStaleTimer()
            if !self.openAndInstallSource() {
                self.installFallbackTimer()
            }
        }
    }

    /// Pause the DispatchSource. Idempotent; safe to call multiple
    /// times. No-op while the fallback timer is active — the fallback
    /// polling respects `isSuspended` too.
    func suspend() {
        queue.async { [weak self] in
            guard let self = self, !self.isStopped else { return }
            if self.isSuspended { return }
            // Deliver anything already parsed before our own subprocess
            // starts appending — a coalesce timer firing mid-turn would
            // otherwise append these OLDER external rows after the
            // turn's newer stdout events.
            self.flushPendingEvents()
            self.isSuspended = true
            if let s = self.source { s.suspend() }
        }
    }

    /// Unpause + update byte offset. Clears the leftover buffer so a
    /// mid-line straddle from before the suspend can't corrupt the
    /// new read. Idempotent.
    func resume(atOffset newOffset: UInt64) {
        queue.async { [weak self] in
            guard let self = self, !self.isStopped else { return }
            self.offset = newOffset
            self.leftoverData.removeAll()
            if self.isSuspended {
                self.isSuspended = false
                if let s = self.source { s.resume() }
            }
            // If the fallback timer is running (fd never opened), try
            // opening again now — the file may have appeared.
            if self.source == nil && self.fallbackTimer != nil {
                if self.openAndInstallSource() {
                    self.fallbackTimer?.cancel()
                    self.fallbackTimer = nil
                }
            }
            // Kick a read immediately so we catch up on anything
            // written while we were suspended.
            self.handleExtend()
        }
    }

    /// Cancel the DispatchSource and close the fd. Idempotent.
    /// Captures self STRONGLY on purpose: the hot-path caller is
    /// `AgentRunner.deinit`, so a weak capture would usually find the
    /// tailer already deallocated and never cancel the kqueue-registered
    /// source — leaving the deinit fd close to race a live source
    /// (undefined behavior once the fd number is recycled). The block
    /// just extends the tailer's life until cleanup has actually run.
    func stop() {
        queue.async { self.stopFromQueue() }
    }

    // MARK: - Source installation

    /// Open the fd and install the DispatchSource. Returns `true` on
    /// success. Runs on `queue`.
    private func openAndInstallSource() -> Bool {
        let opened = open(fileURL.path, O_RDONLY | O_NONBLOCK)
        if opened < 0 {
            return false
        }
        fd = opened
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            let mask = src.data
            if mask.contains(.delete) || mask.contains(.rename) {
                // File went away — nothing we can do. Stop cleanly.
                self.stopFromQueue()
                return
            }
            self.handleExtend()
        }
        // The handler owns closing the fd, captured by VALUE: a [weak
        // self] capture no-ops when cancellation runs during/after
        // deinit, leaving the descriptor open (and deinit closing it
        // directly would race a still-registered kqueue source).
        let ownedFd = fd
        src.setCancelHandler {
            close(ownedFd)
        }
        source = src
        if isSuspended {
            // Installed while logically suspended (the fallback open
            // raced a runner suspend): leave the source unresumed so
            // our own subprocess's records aren't double-rendered.
            // `resume(atOffset:)` activates it and kicks the catch-up
            // read — resuming here as well would over-resume the
            // source, which libdispatch traps on.
            return true
        }
        src.resume()
        // Catch up on any bytes already past `offset`.
        handleExtend()
        return true
    }

    /// Poll every 0.5s trying to `open(2)` the file. Used only when
    /// the fd failed to open at start time. Runs on `queue`.
    private func installFallbackTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(500),
                   repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in
            guard let self = self, !self.isStopped else { return }
            if self.source != nil { return }  // already installed
            if self.openAndInstallSource() {
                self.fallbackTimer?.cancel()
                self.fallbackTimer = nil
            }
        }
        fallbackTimer = t
        t.resume()
    }

    /// Periodic sweep, every 3s. Three jobs:
    /// 1. Consult claude's own `~/.claude/sessions/<pid>.json` status
    ///    records, which anchor the busy verdict: a live
    ///    busy record forces the flag TRUE even while the JSONL is
    ///    quiet (long tool call), and keeps refreshing the activity
    ///    clock so the staleness guard can't fire mid-turn.
    /// 2. The 3s status-file tie-breaker: records exist for the session
    ///    and none is busy-under-a-live-pid — claude's own statement
    ///    that the turn is over. One 3s beat of JSONL quiet guards
    ///    against racing a late end-of-turn flush. Without this the
    ///    flag would linger TRUE for up to `staleAfter` after every
    ///    external turn (composer gated, banner stuck).
    /// 3. Clear the flag after `staleAfter` of silence when the store
    ///    says nothing about the session at all — the fallback for
    ///    writers that died without a canonical end-of-turn marker.
    private func installStaleTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(3),
                   repeating: .seconds(3),
                   leeway: .seconds(1))
        t.setEventHandler { [weak self] in
            guard let self = self, !self.isStopped else { return }
            // Suspended means OUR OWN runner is mid-turn on this file.
            // Its claude subprocess writes the same busy records an
            // external one would — status files prove busyness, never
            // ownership — so the sweep must stay quiet until resume.
            if self.isSuspended { return }
            let sid = self.fileURL.deletingPathExtension().lastPathComponent
            let verdict = ClaudeSessionStatusStore.verdict(sessionId: sid)
            if verdict != .unknown { self.sawStatusRecord = true }
            switch verdict {
            case .busy:
                self.lastActivityAt = Date()
                self.setExternalInProgress(true)
            case .idle:
                guard self.externalInProgress,
                      Date().timeIntervalSince(self.lastActivityAt) >= 3.0
                else { return }
                self.setExternalInProgress(false)
            case .unknown:
                // Nothing in the store mentions this session. If we
                // watched a live writer here earlier, its heartbeat
                // disappearing means the process is GONE — claude
                // removes the file on exit — so the turn is over now,
                // not in five minutes. This is the stopped/crashed
                // orphan: killed mid-turn, it never writes the
                // end-of-turn record that normally clears the flag, so
                // without this the row kept its activity dot for the
                // whole staleness window after Stop.
                let quiet = Date().timeIntervalSince(self.lastActivityAt)
                let timeout = self.sawStatusRecord ? 3.0 : Self.staleAfter
                guard self.externalInProgress, quiet >= timeout else { return }
                self.setExternalInProgress(false)
            }
        }
        staleTimer = t
        t.resume()
    }

    /// stop() variant that skips the `async` jump — safe because it's
    /// already running on `queue`.
    private func stopFromQueue() {
        if isStopped { return }
        isStopped = true
        pendingEvents.removeAll()
        pendingProgressDelivery = nil
        flushScheduled = false
        if let t = staleTimer { t.cancel(); staleTimer = nil }
        if let t = fallbackTimer { t.cancel(); fallbackTimer = nil }
        if let s = source {
            // The source's cancel handler closes the fd (captured by
            // VALUE at install time) — don't close it here or we'd
            // race the handler. DispatchSource requires a suspended
            // source to be resumed before cancel can actually fire.
            s.cancel()
            if isSuspended {
                isSuspended = false
                s.resume()
            }
            source = nil
            fd = -1  // ownership passed to the cancel handler
        } else if fd >= 0 {
            // No source was ever installed — close fd directly.
            close(fd)
            fd = -1
        }
    }

    // MARK: - Reading

    /// A catch-up read must stay BOUNDED: a resume whose offset lags
    /// far behind EOF (worst case a transient stat failure feeding
    /// offset 0 on a multi-hundred-MB transcript) would otherwise read
    /// the whole file into memory and deliver it as one giant batch.
    /// Same bounded-lossy-tail rule as every other reader here.
    private static let catchUpByteCap: UInt64 = 4 * 1024 * 1024

    /// Pull bytes from `offset` to current EOF and parse any complete
    /// lines. Runs on `queue`.
    private func handleExtend() {
        guard fd >= 0 else { return }
        // Re-derive EOF each wake-up. A file that SHRANK (rewrite /
        // compaction) would leave `offset` past EOF and silently wedge
        // the tailer for the rest of the session; a file that grew far
        // past the cap gets a lossy tail window instead of a whole-file
        // read. After either jump the first (partial) line fails JSON
        // parse and is skipped — the drop-partial-leading-line rule.
        let eof = lseek(fd, 0, SEEK_END)
        if eof >= 0 {
            let size = UInt64(eof)
            if size < offset {
                offset = size
                leftoverData.removeAll()
            } else if size - offset > Self.catchUpByteCap {
                offset = size - Self.catchUpByteCap
                leftoverData.removeAll()
            }
        }
        _ = lseek(fd, off_t(offset), SEEK_SET)
        // 64 KB: a single tool-heavy record can exceed 4 KB many times
        // over, and a small buffer turned one catch-up into dozens of
        // read() round-trips.
        let bufSize = 64 * 1024
        var buf = [UInt8](repeating: 0, count: bufSize)
        var accumulated = Data()
        while true {
            let n = buf.withUnsafeMutableBufferPointer {
                read(fd, $0.baseAddress, bufSize)
            }
            if n > 0 {
                accumulated.append(buf, count: n)
                offset += UInt64(n)
                if n < bufSize { break }
            } else if n == 0 {
                break
            } else {
                // n < 0 — EAGAIN on non-blocking fd, or a real error.
                // Either way, stop for this wake-up.
                break
            }
        }
        guard !accumulated.isEmpty else { return }
        processData(accumulated)
    }

    /// Append the fresh bytes, split on `\n` BYTES, and decode only
    /// complete lines. A read() that ends inside a multi-byte UTF-8
    /// character must not throw the batch away (a whole-chunk
    /// `String(data:)` decode returns nil there and would lose every
    /// record in the read, desyncing `leftover` by a line).
    /// Runs on `queue`.
    private func processData(_ incoming: Data) {
        leftoverData.append(incoming)
        var batch: [StreamEvent] = []
        // Cursor walk with ONE tail copy at the end — a per-line
        // `removeSubrange` at the buffer front would memmove the
        // whole remainder for every line (O(bytes × lines) on a large
        // catch-up read).
        var cursor = leftoverData.startIndex
        while let nl = leftoverData[cursor...].firstIndex(of: 0x0A) {
            let lineData = leftoverData.subdata(in: cursor..<nl)
            cursor = nl + 1
            guard let raw = String(data: lineData, encoding: .utf8)
            else { continue }  // corrupt single line — skip it alone
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Pre-decode once for progress tracking. The parser will
            // decode again internally — cheap enough that it's not
            // worth complicating the parser's API to share state.
            guard let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any]
            else { continue }

            lastActivityAt = Date()
            applyProgressTransition(forRawRecord: obj)

            batch.append(contentsOf: AgentEventParser.parse(
                line: trimmed,
                fallbackCwd: fallbackCwd,
                includeUserMessages: true))
        }
        if cursor > leftoverData.startIndex {
            leftoverData = Data(leftoverData[cursor...])
        }
        // Coalesced MainActor delivery (see `scheduleFlush`). Liveness
        // transitions above already ran in order on `queue`.
        guard !batch.isEmpty else { return }
        pendingEvents.append(contentsOf: batch)
        scheduleFlush()
    }

    /// Minimum spacing between MainActor deliveries. A fast external
    /// writer extends the file many times per second; even with
    /// per-burst batching that meant one whole-transcript SwiftUI
    /// re-render per burst — enough to wedge the app for the length of
    /// the external turn when a big session is open. 4 Hz keeps the
    /// stream visibly live while bounding render work.
    private static let uiFlushInterval: TimeInterval = 0.25

    /// Parsed events awaiting delivery. Runs on `queue`.
    private var pendingEvents: [StreamEvent] = []
    /// Liveness state awaiting delivery (nil = no change since the
    /// last flush). Coalesced WITH the events: a catch-up burst's
    /// records legitimately alternate live/ended many times, and
    /// firing one MainActor publish per flip re-rendered the sidebar
    /// and composer dozens of times per read burst. Only the burst's
    /// FINAL state matters to the UI. Runs on `queue`.
    private var pendingProgressDelivery: Bool? = nil
    private var flushScheduled = false
    private var lastFlushAt = Date.distantPast

    /// Deliver immediately when we haven't flushed recently (a fresh
    /// turn's first records show instantly); otherwise arm one timer
    /// for the remainder of the interval. Runs on `queue`.
    private func scheduleFlush() {
        if flushScheduled { return }
        let elapsed = Date().timeIntervalSince(lastFlushAt)
        if elapsed >= Self.uiFlushInterval {
            flushPendingEvents()
            return
        }
        flushScheduled = true
        queue.asyncAfter(
            deadline: .now() + (Self.uiFlushInterval - elapsed)
        ) { [weak self] in
            guard let self = self, !self.isStopped else { return }
            self.flushScheduled = false
            self.flushPendingEvents()
        }
    }

    private func flushPendingEvents() {
        let events = pendingEvents
        let progress = pendingProgressDelivery
        guard !events.isEmpty || progress != nil else { return }
        lastFlushAt = Date()
        pendingEvents = []
        pendingProgressDelivery = nil
        let onEvents = onEvents
        let onProgress = onExternalInProgressChange
        // ONE MainActor task for both, events first: the liveness flip
        // (whose false edge triggers the view's turn-end rescan) must
        // land after the burst that ended the turn — separate
        // unstructured tasks had no ordering guarantee.
        Task { @MainActor in
            if !events.isEmpty { onEvents(events) }
            if let p = progress { onProgress(p) }
        }
    }

    /// Stop reasons that end a turn.
    static let terminatingStopReasons: Set<String> = [
        "end_turn", "max_tokens", "stop_sequence", "refusal",
    ]

    /// System-record subtypes that end a turn.
    static let turnEndSystemSubtypes: Set<String> = [
        "turn_duration", "stop_hook_summary", "away_summary",
    ]

    /// Apply the canonical turn-liveness rules. Runs on `queue`.
    private func applyProgressTransition(forRawRecord obj: [String: Any]) {
        if let state = Self.progressState(forRawRecord: obj) {
            setExternalInProgress(state)
        }
    }

    /// True = turn live, false = turn ended (CANONICAL markers only),
    /// nil = no signal (metadata records, non-allowlisted system
    /// subtypes — claude writes those mid-turn, so treating them as
    /// "ended" flickers the lock banner through a live turn).
    static func progressState(forRawRecord obj: [String: Any]) -> Bool? {
        switch (obj["type"] as? String) ?? "" {
        case "result":
            return false
        case "system":
            if let sub = obj["subtype"] as? String,
               turnEndSystemSubtypes.contains(sub) {
                return false
            }
            return nil
        case "assistant":
            let msg = (obj["message"] as? [String: Any]) ?? [:]
            if let stop = msg["stop_reason"] as? String,
               terminatingStopReasons.contains(stop) {
                return false
            }
            // Null or non-terminating stop_reason: mid-turn, whether
            // the content is narration text or tool_use blocks.
            return true
        case "user":
            // A tool_result round-trip means the turn is live.
            // NSNull-safe: a JSON null must read as ABSENT, not as
            // present — see the parent_tool_use_id note in
            // AgentEventParsing.
            if obj["toolUseResult"] != nil,
               !(obj["toolUseResult"] is NSNull) { return true }
            // A compaction summary is a user-role record the agent
            // wrote mid-turn. It is not the user starting one, and
            // reading it as such flips this session to "live" whenever
            // a summary lands.
            if (obj["isCompactSummary"] as? Bool) == true { return nil }
            let msg = (obj["message"] as? [String: Any]) ?? [:]
            if let arr = msg["content"] as? [Any], !arr.isEmpty {
                let allToolResults = arr.allSatisfy { block in
                    (block as? [String: Any])?["type"] as? String == "tool_result"
                }
                if allToolResults { return true }
            }
            // META cleaner: liveness must treat a record that is ONLY
            // command/system wrappers as no-signal — the display
            // cleaner keeps command text and would read claude's own
            // bookkeeping as the user starting a turn.
            let text = AgentSessionScanner.cleanSessionMetaText(
                AgentSessionScanner.extractText(
                    fromContent: msg["content"] ?? ""))
            if text.hasPrefix("[Request interrupted by user") { return false }
            // Real user text starts a turn; wrapper-only records
            // (system-reminder etc., injected mid-turn) are no signal.
            return text.isEmpty ? nil : true
        default:
            return nil
        }
    }

    /// Flip `externalInProgress` and queue the MainActor delivery.
    /// No-op if the value is unchanged. Delivery rides the coalesced
    /// event flush (see `pendingProgressDelivery`) instead of firing
    /// its own task per flip. Runs on `queue`.
    private func setExternalInProgress(_ new: Bool) {
        if externalInProgress == new { return }
        externalInProgress = new
        pendingProgressDelivery = new
        scheduleFlush()
    }
}

// MARK: - Claude status files

/// Every claude process drops a `~/.claude/sessions/<pid>.json`
/// heartbeat carrying
/// `{sessionId, status, pid, updatedAt}`. A "busy" record whose pid is
/// still alive is claude's own statement that a turn is running —
/// authoritative for busyness (never for ownership) even when the
/// session JSONL is momentarily quiet.
enum ClaudeSessionStatusStore {
    static var sessionsDir: String {
        NSString(string: "~/.claude/sessions").expandingTildeInPath
    }

    /// Three-way read of the status store for one session. Cheap: the
    /// directory holds one small JSON per claude process.
    enum Verdict {
        /// A busy record under a live pid — a turn is running.
        case busy
        /// Records mention the session but none is busy-and-alive —
        /// claude's own statement that the turn is over (or that the
        /// writing process died).
        case idle
        /// Nothing in the store mentions the session — no signal
        /// either way (old claude, cleaned directory).
        case unknown
    }

    /// One matching heartbeat, digested. `busy` is the pivotal bit —
    /// see `recordIsBusy` for what counts.
    struct SessionRecord {
        let pid: Int32
        let busy: Bool
        /// True when the record carries NO `status` field at all — the
        /// `claude -p` / SDK shape (`entrypoint: "sdk-cli"`). Such a
        /// process exists only for the span of its one turn, which is
        /// what makes it safely stoppable from here.
        let statusless: Bool
        let entrypoint: String?
    }

    /// A "busy" record older than this is ignored: a live interactive
    /// claude refreshes its heartbeat continuously, so an ancient one
    /// is crash residue whose pid may have been recycled.
    private static let busyRecordMaxAge: TimeInterval = 24 * 3600

    static func verdict(sessionId: String) -> Verdict {
        let records = sessionRecords(sessionId: sessionId)
        if records.contains(where: { $0.busy }) { return .busy }
        return records.isEmpty ? .unknown : .idle
    }

    /// All heartbeats naming this session, freshness- and pid-checked.
    static func sessionRecords(sessionId: String) -> [SessionRecord] {
        guard !sessionId.isEmpty else { return [] }
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: sessionsDir) else { return [] }
        var out: [SessionRecord] = []
        for name in names where name.hasSuffix(".json") {
            let path = (sessionsDir as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: path),
                  let rec = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  rec["sessionId"] as? String == sessionId
            else { continue }
            let pid = pidValue(rec["pid"])
            out.append(SessionRecord(
                pid: pid,
                busy: recordIsBusy(rec, path: path, pid: pid),
                statusless: !(rec["status"] is String),
                entrypoint: rec["entrypoint"] as? String
            ))
        }
        return out
    }

    /// Does this heartbeat prove a turn is RUNNING?
    ///
    /// Two shapes qualify, both requiring a fresh record under a live
    /// pid that still looks like an agent process:
    ///
    ///  * `status == "busy"` — an interactive claude mid-turn. Its
    ///    `"idle"` counterpart is the explicit turn-over statement.
    ///  * NO `status` field at all — `claude -p` / SDK runs
    ///    (`entrypoint: "sdk-cli"`) never write one, and such a
    ///    process only exists while its one turn runs, so record +
    ///    live pid IS mid-turn. "Record exists but not busy" must
    ///    never read as idle: the activity dot would flap on every
    ///    JSONL-quiet stretch of a turn (long tool call), the 3 s
    ///    sweep flipping the flag false and the next append flipping
    ///    it back. Only an explicit non-busy status — or every
    ///    recorded pid being dead — says the turn is over.
    private static func recordIsBusy(_ rec: [String: Any],
                                     path: String, pid: Int32) -> Bool {
        if let status = rec["status"] as? String {
            guard status == "busy" else { return false }
        } else if rec["entrypoint"] as? String == "cli" {
            // Belt: an interactive claude writes busy/idle explicitly,
            // so a status-less "cli" record carries no busy signal.
            return false
        }
        guard recordAge(rec, path: path) <= busyRecordMaxAge else {
            return false
        }
        // Fail-safe direction: an unverifiable pid counts as busy, so a
        // sysctl hiccup can never silently un-live a running session.
        return pidMatchesRecord(pid: pid, record: rec, strict: false)
    }

    /// Seconds since the record was refreshed: `updatedAt` (ms epoch)
    /// when present, else the heartbeat file's own mtime — the sdk-cli
    /// shape carries no updatedAt at all.
    private static func recordAge(_ rec: [String: Any], path: String) -> TimeInterval {
        var updatedMs: Double = 0
        switch rec["updatedAt"] {
        case let n as Double: updatedMs = n
        case let n as Int: updatedMs = Double(n)
        case let s as String: updatedMs = Double(s) ?? 0
        default: break
        }
        if updatedMs > 0 {
            return max(0, Date().timeIntervalSince1970 - updatedMs / 1000.0)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let mtime = attrs[.modificationDate] as? Date {
            return max(0, Date().timeIntervalSince(mtime))
        }
        return 0
    }

    /// pid of an external writer this app may STOP: a fresh busy
    /// record in the headless `-p` / SDK shape. Interactive terminal
    /// claudes (entrypoint "cli") return nil — stopping those belongs
    /// to their own terminal, so the composer disables Stop instead.
    static func stoppableExternalPid(sessionId: String) -> Int32? {
        sessionRecords(sessionId: sessionId)
            .first(where: { $0.busy && $0.statusless && $0.entrypoint != "cli" })?
            .pid
    }

    /// Re-verification at signal time: the pid must still be a live
    /// agent process whose heartbeat names this session — a bare pid
    /// number can be recycled between the button render and the click.
    /// STRICT, unlike the busy check: this one leads to a `kill`, so
    /// "can't tell" must mean "don't".
    static func pidStillOwnsSession(pid: Int32, sessionId: String) -> Bool {
        guard pid > 0, !sessionId.isEmpty else { return false }
        let path = (sessionsDir as NSString)
            .appendingPathComponent("\(pid).json")
        guard let data = FileManager.default.contents(atPath: path),
              let rec = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              rec["sessionId"] as? String == sessionId
        else { return false }
        return pidMatchesRecord(pid: pid, record: rec, strict: true)
    }

    /// JSON `pid` field → Int32 (0 when absent or malformed).
    static func pidValue(_ raw: Any?) -> Int32 {
        switch raw {
        case let n as Int:    return Int32(clamping: n)
        case let n as Int32:  return n
        case let d as Double: return Int32(clamping: Int(d))
        case let s as String: return Int32(s) ?? 0
        default:              return 0
        }
    }

    /// `kill(pid, 0)` probe. EPERM means "exists but not ours" — alive.
    static func pidAlive(_ raw: Any?) -> Bool {
        pidAlive(pidValue(raw))
    }

    static func pidAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Does live pid `pid` still belong to the claude that WROTE this
    /// heartbeat? The question a bare `kill(pid, 0)` cannot answer:
    /// after a crash the record lingers and its pid number can be
    /// recycled by an unrelated process.
    ///
    /// The primary evidence is the process's own START TIME, not its
    /// name. A recycled pid necessarily belongs to a process that
    /// started AFTER the record was written, so "started no later
    /// than this record's `startedAt`" settles it — and unlike a name
    /// it cannot be spoofed by how claude presents itself.
    ///
    /// That matters here specifically: claude's binary is version-NAMED
    /// (`~/.local/share/claude/versions/<version>`) and it rewrites its
    /// process title, so `p_comm` on a live claude reads as the bare
    /// version string. A name check would therefore reject every
    /// running claude and read as idle. Path matching is kept only as
    /// the fallback for records with no `startedAt` (it still
    /// recognises both install shapes: the `…/claude/versions/…` path
    /// and the npm `node` shim).
    ///
    /// `strict` picks the direction to fail in: the busy check passes
    /// false (unverifiable → assume busy, never un-live a running
    /// session), while anything that leads to a `kill` passes true.
    static func pidMatchesRecord(pid: Int32, record: [String: Any],
                                 strict: Bool) -> Bool {
        guard pid > 0, pidAlive(pid) else { return false }
        if let recordStart = recordStartedAtSeconds(record),
           let procStart = processStartTime(pid) {
            // Slack absorbs the ordinary gap between exec and the
            // record being written — the process starts, then
            // registers its session.
            return procStart <= recordStart + 120
        }
        if let path = executablePath(pid)?.lowercased() {
            return path.contains("/claude") || path.hasSuffix("/node")
        }
        return !strict
    }

    /// `startedAt` (ms since epoch) → seconds, when the record has one.
    private static func recordStartedAtSeconds(_ rec: [String: Any]) -> Double? {
        let raw: Double?
        switch rec["startedAt"] {
        case let n as Double: raw = n
        case let n as Int:    raw = Double(n)
        case let s as String: raw = Double(s)
        default:              raw = nil
        }
        guard let ms = raw, ms > 0 else { return nil }
        return ms / 1000.0
    }

    /// Wall-clock start time of `pid` (`kinfo_proc.kp_proc.p_starttime`),
    /// or nil when the process is gone or unreadable.
    private static func processStartTime(_ pid: Int32) -> Double? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = mib.withUnsafeMutableBufferPointer { mibPtr in
            sysctl(mibPtr.baseAddress, UInt32(mibPtr.count), &info, &size, nil, 0)
        }
        guard rc == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000.0
    }

    /// Real executable path (`proc_pidpath`) — immune to the process
    /// title rewriting that makes `p_comm` useless for claude.
    private static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }
}
