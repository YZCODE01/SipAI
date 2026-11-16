// JSONRPCLinePeer.swift
// One JSON-RPC 2.0 conversation with a child process over its stdin and
// stdout, one JSON value per line — the shape of codex's app-server and
// kimi's ACP server, the two front ends through which those agents can
// ASK the user something mid-turn.
//
// Foundation only, and free of the runner and the bridge, so the
// verification harnesses compile it on its own.
//
// Three kinds of message arrive, and each is handled differently:
//
//  * a response to a request of ours (`id` + `result`/`error`) resumes
//    whoever is awaiting it;
//  * a notification (`method`, no `id`) goes to `onNotification`;
//  * a request FROM the other side (`method` + `id`) goes to the handler
//    registered for its method, with an `Inbound` it answers exactly
//    once — and a method nobody handles is answered -32601 at once, so a
//    request this side does not know can never hold the other side's turn
//    open.
//
// Everything that arrives is handed on through ONE ordered `deliver`
// closure, in arrival order: the runner passes `DispatchQueue.main.async`,
// which is FIFO. A turn's last text chunk can therefore never be
// overtaken by the response that ends the turn, as it could through a
// `Task` per line.

import Foundation

final class JSONRPCLinePeer: @unchecked Sendable {

    /// An id as the other side wrote it — echoed back exactly, number or
    /// string, since a reply under the wrong type is a reply to nothing.
    enum ID: Hashable {
        case number(Int64)
        case string(String)

        init?(_ raw: Any?) {
            if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                self = .number(number.int64Value)
            } else if let text = raw as? String {
                self = .string(text)
            } else {
                return nil
            }
        }

        var json: Any {
            switch self {
            case .number(let n): return NSNumber(value: n)
            case .string(let s): return s
            }
        }
    }

    enum Failure: Error, Equatable {
        /// The other side answered with an error object.
        case remote(code: Int, message: String)
        /// The conversation is over: the child's stdout ended, or this
        /// side closed it.
        case closed(String)
        case timedOut
        case cancelled
    }

    /// A request the other side sent. It waits for exactly one reply; a
    /// second is ignored, and so is a reply after the conversation ended.
    final class Inbound: @unchecked Sendable {
        let id: ID
        let method: String
        let params: Any?
        private weak var peer: JSONRPCLinePeer?
        private let lock = NSLock()
        private var answered = false

        fileprivate init(id: ID, method: String, params: Any?, peer: JSONRPCLinePeer) {
            self.id = id
            self.method = method
            self.params = params
            self.peer = peer
        }

        var isAnswered: Bool { lock.withLock { answered } }

        func reply(_ result: Any) {
            guard claim() else { return }
            peer?.write(["jsonrpc": "2.0", "id": id.json, "result": result])
        }

        func fail(code: Int, message: String) {
            guard claim() else { return }
            peer?.write(["jsonrpc": "2.0", "id": id.json,
                         "error": ["code": code, "message": message]])
        }

        private func claim() -> Bool {
            lock.withLock {
                if answered { return false }
                answered = true
                return true
            }
        }
    }

    /// JSON-RPC's own code for "no such method".
    static let methodNotFound = -32601

    private let lock = NSLock()
    private let writeQueue: DispatchQueue
    private let writeFD: Int32
    private let deliver: (@escaping () -> Void) -> Void
    private var nextId: Int64 = 1
    private var waiting: [Int64: (Result<Any?, Failure>) -> Void] = [:]
    private var handlers: [String: (Inbound) -> Void] = [:]
    private var closedReason: String?
    private var writingFinished = false

    /// Notifications from the other side, delivered in arrival order.
    var onNotification: ((String, Any?) -> Void)?

    /// A line that is not JSON — a child that writes something else to
    /// its stdout. Never answered; its text is the caller's to keep.
    var onUnparsed: ((String) -> Void)?

    /// - Parameters:
    ///   - writing: the child's stdin, written as a raw descriptor and
    ///     closed by `finishWriting`/`close`. It is told not to raise
    ///     SIGPIPE: a write to a child that has gone must fail, never end
    ///     this process.
    ///   - deliver: how work reaches the caller, in order. The runner
    ///     passes `{ DispatchQueue.main.async(execute: $0) }`.
    init(label: String, writing fd: Int32,
         deliver: @escaping (@escaping () -> Void) -> Void) {
        self.writeFD = fd
        self.deliver = deliver
        self.writeQueue = DispatchQueue(label: "\(label).write", qos: .userInitiated)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    }

    /// The delivery the app uses: the main queue, which runs blocks in the
    /// order they were queued. The work is only ever run there, which is
    /// what lets it cross queues unchecked.
    static func deliverOnMainQueue(_ work: @escaping () -> Void) {
        let box = Work(run: work)
        DispatchQueue.main.async { box.run() }
    }

    private struct Work: @unchecked Sendable {
        let run: () -> Void
    }

    // MARK: Registering

    /// Answer the other side's `method` requests. Register before the
    /// child can send one; an unregistered method is refused.
    func handle(_ method: String, _ handler: @escaping (Inbound) -> Void) {
        lock.withLock { handlers[method] = handler }
    }

    var isClosed: Bool { lock.withLock { closedReason != nil } }

    // MARK: Reading

    /// One line of the child's stdout. Call from ONE serial context — the
    /// reader's queue — in the order the lines arrived.
    func receive(line: String) {
        guard let object = Self.decode(line) else {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                deliver { [weak self] in self?.onUnparsed?(text) }
            }
            return
        }
        if let batch = object as? [Any] {
            for item in batch { receive(object: item) }
        } else {
            receive(object: object)
        }
    }

    /// The child's stdout ended: nothing more can be answered, and every
    /// request still awaiting an answer fails — after whatever arrived
    /// before the end has been delivered.
    func receiveEOF() {
        deliver { [weak self] in self?.close(reason: "the child's output ended") }
    }

    private func receive(object: Any) {
        guard let message = object as? [String: Any] else { return }
        let method = message["method"] as? String
        let rawId = message["id"]
        let hasId = rawId != nil && !(rawId is NSNull)

        if let method, hasId, let id = ID(rawId) {
            // A request from the other side.
            let params = message["params"]
            deliver { [weak self] in
                guard let self, !self.isClosed else { return }
                let inbound = Inbound(id: id, method: method, params: params, peer: self)
                if let handler = self.lock.withLock({ self.handlers[method] }) {
                    handler(inbound)
                } else {
                    inbound.fail(code: Self.methodNotFound, message: "Method not found: \(method)")
                }
            }
            return
        }
        if let method {
            let params = message["params"]
            deliver { [weak self] in
                guard let self, !self.isClosed else { return }
                self.onNotification?(method, params)
            }
            return
        }
        if hasId, message["result"] != nil || message["error"] != nil {
            guard let key = Self.ownId(rawId) else { return }
            let result: Result<Any?, Failure>
            if let error = message["error"] as? [String: Any] {
                result = .failure(.remote(code: (error["code"] as? NSNumber)?.intValue ?? 0,
                                          message: (error["message"] as? String) ?? ""))
            } else {
                let value = message["result"]
                result = .success(value is NSNull ? nil : value)
            }
            deliver { [weak self] in self?.complete(key, result) }
        }
    }

    /// One of OUR ids, as the other side echoed it: a number, or a
    /// number written as a string by a lenient server.
    private static func ownId(_ raw: Any?) -> Int64? {
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.int64Value
        }
        if let text = raw as? String { return Int64(text) }
        return nil
    }

    /// The JSON value on a line — tolerating what a terminal does to a
    /// line on its way through: a carriage return at the end, and control
    /// bytes in front of the first one (`^D^H^H`). Whatever precedes the
    /// first `{` or `[` is not JSON-RPC.
    static func decode(_ line: String) -> Any? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let text = trimmed[start...]
        return try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    // MARK: Asking

    /// Send a request and wait for its answer. `timeout` nil waits for as
    /// long as the conversation lasts; a cancelled task stops waiting.
    func request(_ method: String, params: Any? = nil,
                 timeout: TimeInterval? = nil) async throws -> Any? {
        let id: Int64 = lock.withLock {
            let next = nextId
            nextId += 1
            return next
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
                let refused: String? = lock.withLock {
                    if let reason = closedReason { return reason }
                    waiting[id] = { result in
                        switch result {
                        case .success(let value): cont.resume(returning: value)
                        case .failure(let failure): cont.resume(throwing: failure)
                        }
                    }
                    return nil
                }
                if let reason = refused {
                    cont.resume(throwing: Failure.closed(reason))
                    return
                }
                // Cancelled before the handler could see the waiter.
                if Task.isCancelled {
                    complete(id, .failure(.cancelled))
                    return
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.complete(id, .failure(.timedOut))
                    }
                }
                write(["jsonrpc": "2.0", "id": NSNumber(value: id), "method": method,
                       "params": params ?? [String: Any]()])
            }
        } onCancel: {
            complete(id, .failure(.cancelled))
        }
    }

    /// Send a notification; nothing comes back.
    func notify(_ method: String, params: Any? = nil) {
        write(["jsonrpc": "2.0", "method": method, "params": params ?? [String: Any]()])
    }

    /// Exactly one of {answer, close, cancel, timeout} completes a request.
    private func complete(_ id: Int64, _ result: Result<Any?, Failure>) {
        let waiter = lock.withLock { waiting.removeValue(forKey: id) }
        waiter?(result)
    }

    // MARK: Writing and ending

    fileprivate func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.withoutEscapingSlashes]) else {
            return
        }
        data.append(0x0A)
        writeQueue.async { [weak self] in
            guard let self else { return }
            guard !self.lock.withLock({ self.writingFinished }) else { return }
            if !Self.writeAll(data, to: self.writeFD) {
                self.deliver { [weak self] in self?.close(reason: "the child's input is closed") }
            }
        }
    }

    /// `write(2)` until every byte is out, through partial writes and
    /// signals. False on any other failure — EPIPE above all: the child
    /// has gone.
    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var base = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, base, left)
                if n > 0 {
                    base = base.advanced(by: n)
                    left -= n
                    continue
                }
                if n < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    /// Close the child's stdin once everything already written has gone
    /// out. A child that reads requests until EOF takes this as "done".
    func finishWriting() {
        writeQueue.async { [weak self] in
            guard let self else { return }
            let first: Bool = self.lock.withLock {
                if self.writingFinished { return false }
                self.writingFinished = true
                return true
            }
            if first { _ = Darwin.close(self.writeFD) }
        }
    }

    /// End the conversation: every request still awaiting an answer fails
    /// with `reason`, later messages are dropped, later replies are not
    /// written, and the child's stdin is closed. Idempotent.
    func close(reason: String) {
        let waiters: [(Result<Any?, Failure>) -> Void] = lock.withLock {
            if closedReason != nil { return [] }
            closedReason = reason
            let all = Array(waiting.values)
            waiting.removeAll()
            return all
        }
        for waiter in waiters { waiter(.failure(.closed(reason))) }
        finishWriting()
    }
}
