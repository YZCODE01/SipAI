// ShellEnvironment.swift
// Resolves environment variables the way a terminal user expects.
//
// A GUI app launched from the Dock inherits launchd's minimal
// environment — NOT the exports in ~/.zshrc — so an OPENAI_API_KEY
// that "works in my terminal" is invisible to the app's own
// ProcessInfo.
// Like VS Code, we spawn the user's login shell once, capture its
// environment, and consult that snapshot whenever the process
// environment comes up empty. The snapshot is cached for the app's
// lifetime and warmed up at launch so lookups stay instant.

import Foundation

enum ShellEnvironment {
    /// Guards `cache` + `capturing` only — never held across the
    /// capture itself, which takes up to ~12 s worst case. Callers that
    /// arrive mid-capture wait on the condition for the one in-flight
    /// result instead of spawning a second shell (or stalling anything
    /// else that merely wants the lock for bookkeeping).
    private static let condition = NSCondition()
    private static var cache: [String: String]?
    private static var capturing = false

    /// Env-var lookup: this process first, then the login shell's
    /// captured environment. Empty values count as absent.
    static func resolve(_ name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        if let v = ProcessInfo.processInfo.environment[n], !v.isEmpty { return v }
        if let v = snapshot()[n], !v.isEmpty { return v }
        return nil
    }

    /// `resolve`, but never blocking: the process environment first,
    /// then the login shell's capture ONLY if it is already in hand.
    /// For readers on the MainActor that must not wait out a shell
    /// startup — the composer reads `ANTHROPIC_MODEL` through this on
    /// every appearance. Answers nil while the capture is pending;
    /// `warmUp()` at launch keeps that window to the app's first
    /// seconds.
    static func resolveIfCaptured(_ name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        if let v = ProcessInfo.processInfo.environment[n], !v.isEmpty { return v }
        condition.lock()
        let captured = cache
        condition.unlock()
        if let v = captured?[n], !v.isEmpty { return v }
        return nil
    }

    /// The login shell's own `PATH`, split into directories. Empty
    /// until the capture lands, and it NEVER waits for one — agent
    /// detection reads this from the MainActor every few seconds, and
    /// `resolve`'s blocking first call would freeze the UI for the
    /// length of a shell startup (the same hazard `prepare()` exists to
    /// keep off the spawn path). `warmUp()` at launch plus that
    /// re-detection tick is what makes "empty for now" self-correcting.
    ///
    /// Deliberately NOT `resolve("PATH")`: this process ALWAYS has a
    /// PATH — launchd's minimal one — so a process-environment-first
    /// lookup would answer with it every time and never consult the
    /// shell at all, which is the entire point of asking here.
    static func loginShellPathDirectories() -> [String] {
        condition.lock()
        let captured = cache
        condition.unlock()
        guard let path = captured?["PATH"], !path.isEmpty else { return [] }
        return path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    /// Capture the shell environment off the main thread at launch so
    /// the first real lookup doesn't pay the shell-startup cost.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = snapshot() }
    }

    /// Wait for the capture WITHOUT blocking the caller's thread.
    ///
    /// `resolve` blocks — up to ~12 s worst case while a login shell
    /// starts — and one of its callers is the agent-spawn path, which
    /// runs on the MainActor. `warmUp()` at launch normally has the
    /// snapshot in hand long before anyone sends, but "normally" is not
    /// a guarantee: a send in the app's first moments would otherwise
    /// freeze the entire UI for the length of a shell startup. Await
    /// this first and every later `resolve` on that path is a cache
    /// read. Returns immediately once the capture has happened.
    static func prepare() async {
        if captured() { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = snapshot()
                cont.resume()
            }
        }
    }

    /// Whether the capture is already in hand. Never blocks on it and
    /// never starts one — the lock is held only for the field read.
    private static func captured() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return cache != nil
    }

    /// Capture once, then cached. The first caller runs the capture
    /// with the lock RELEASED; everyone else either waits for that
    /// single capture or gets a pure cache read.
    private static func snapshot() -> [String: String] {
        condition.lock()
        while cache == nil && capturing {
            condition.wait()
        }
        if let cached = cache {
            condition.unlock()
            return cached
        }
        capturing = true
        condition.unlock()

        let loaded = captureLoginShellEnvironment()

        condition.lock()
        cache = loaded
        capturing = false
        condition.broadcast()
        condition.unlock()
        return loaded
    }

    /// `$SHELL -ilc '/usr/bin/env -0'`, with a unique marker printed on
    /// both sides so rc files that echo to stdout can't corrupt the
    /// parse (their output lands before the first marker). Interactive
    /// AND login, because API keys overwhelmingly live in ~/.zshrc.
    /// Bounded by a timeout; returns [:] on any failure — resolution
    /// then simply falls back to the process environment.
    private static func captureLoginShellEnvironment() -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__SIPAI_ENV_\(UUID().uuidString)__"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", "printf '%s' '\(marker)'; /usr/bin/env -0; printf '%s' '\(marker)'"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        // EOF instead of a hang for any rc file that reads stdin.
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }

        // Bounded non-blocking read loop, all on this thread — NOT
        // `readDataToEndOfFile` on a helper thread. EOF needs every
        // copy of the pipe's write end closed, and a background
        // grandchild spawned by an rc file inherits one; Process has
        // no public way to make the shell a process-group leader we
        // could SIGKILL wholesale, so killing the shell alone may
        // never produce EOF. An end-of-file read could then outlive
        // the grace window (leaked blocked thread + unsynchronized
        // `data` race). Here the deadline, not EOF, is what guarantees
        // the read stops, and `data` never leaves this thread.
        let fd = out.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var data = Data()
        let bufSize = 64 * 1024
        var buf = [UInt8](repeating: 0, count: bufSize)
        var deadline = ProcessInfo.processInfo.systemUptime + 8
        var killedShell = false
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                if killedShell { break }  // grace over — give up on EOF
                // A shell stuck in some rc prompt. Kill it (only the
                // shell — see above), then grant a short grace so
                // already-buffered output can still drain.
                kill(p.processIdentifier, SIGKILL)
                killedShell = true
                deadline = ProcessInfo.processInfo.systemUptime + 4
                continue
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waitMs = Int32((min(remaining, 1.0) * 1000).rounded(.up))
            guard poll(&pfd, 1, waitMs) > 0 else { continue }  // timeout / EINTR
            let n = buf.withUnsafeMutableBufferPointer {
                read(fd, $0.baseAddress, bufSize)
            }
            if n > 0 {
                data.append(buf, count: n)
            } else if n == 0 {
                break  // EOF — every write end closed
            } else if errno != EAGAIN && errno != EINTR {
                // Unrecoverable read error. Make sure the shell is dead
                // so waitUntilExit below can't hang, keep what we have.
                if !killedShell { kill(p.processIdentifier, SIGKILL) }
                break
            }
        }
        p.waitUntilExit()  // shell exited or was SIGKILLed — reap it

        guard let text = String(data: data, encoding: .utf8),
              let first = text.range(of: marker),
              let last = text.range(of: marker, options: .backwards),
              first.upperBound <= last.lowerBound
        else { return [:] }

        var env: [String: String] = [:]
        for entry in text[first.upperBound..<last.lowerBound].split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<eq])
            guard !key.isEmpty else { continue }
            env[key] = String(entry[entry.index(after: eq)...])
        }
        return env
    }
}
