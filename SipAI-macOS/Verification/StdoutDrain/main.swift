import Foundation
import Darwin

// Pins the OS behaviour that AgentRunner.readStdout's rules rest on.
//
// Nothing here imports the app, and nothing here is the app's loop: the
// CODE rules are checked by run.sh against Models/AgentRunner.swift
// itself, so this file can never drift into being a second, passing
// copy of a loop the product no longer has. What it measures is the
// PTY and the dispatch source — the two things the rules are claims
// about, and the two things a macOS upgrade can move underneath them.

var failures = 0

func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("  \(ok ? "PASS" : "FAIL")  \(label)")
    if !detail.isEmpty { print("        \(detail)") }
    if !ok { failures += 1 }
}

/// A child writing `lines` lines down a PTY, exactly as AgentRunner
/// spawns one: slave handed to the child, parent's copy closed, master
/// non-blocking.
func spawnOnPTY(lines: Int) -> (master: Int32, process: Process) {
    var master: Int32 = 0
    var slave: Int32 = 0
    guard openpty(&master, &slave, nil, nil, nil) == 0 else {
        fatalError("openpty failed")
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "i=0; while [ $i -lt \(lines) ]; do "
                   + "echo \"line $i payload payload payload\"; i=$((i+1)); done"]
    p.standardOutput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { fatalError("spawn failed: \(error)") }
    close(slave)
    _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK)
    return (master, p)
}

enum Loop { case shortReadBreak, drainToEAGAIN }

struct Outcome {
    var bytes = 0
    var lines = 0
    var reads = 0
    var shortReads = 0
    var handlerCalls = 0
    var cancelled = false
    var childStillRunning = true
    var stalled = false
}

/// Drive one PTY child through `loop`, optionally injecting a single
/// EINTR at read number `injectEINTRAt` (0 = never). Returns when the
/// stream ends or when nothing has moved for ~2 s.
func run(loop: Loop, lines: Int, injectEINTRAt: Int = 0,
         slowByMicroseconds: UInt32 = 0) -> Outcome {
    let bufSize = 4096
    let (master, child) = spawnOnPTY(lines: lines)
    let lock = NSLock()
    var o = Outcome()
    var readSeq = 0

    let q = DispatchQueue(label: "verify.stdout", qos: .userInitiated)
    let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: q)
    source.setEventHandler {
        var buf = [UInt8](repeating: 0, count: bufSize)
        var atEnd = false
        lock.lock(); o.handlerCalls += 1; lock.unlock()
        if slowByMicroseconds > 0 { usleep(slowByMicroseconds) }
        while true {
            lock.lock(); readSeq += 1; let seq = readSeq; lock.unlock()
            var n = 0
            var err: Int32 = 0
            if seq == injectEINTRAt {
                n = -1; err = EINTR       // interrupted; no data consumed
            } else {
                (n, err) = buf.withUnsafeMutableBufferPointer { ptr in
                    let r = read(master, ptr.baseAddress, bufSize)
                    return (r, r < 0 ? errno : 0)
                }
            }
            if n > 0 {
                lock.lock()
                o.bytes += n
                o.reads += 1
                if n < bufSize { o.shortReads += 1 }
                o.lines += buf.prefix(n).reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
                lock.unlock()
                if loop == .shortReadBreak, n < bufSize { break }
                continue
            }
            if n == 0 { atEnd = true; break }
            if loop == .drainToEAGAIN, err == EINTR { continue }
            if err == EAGAIN || err == EWOULDBLOCK { break }
            atEnd = true
            break
        }
        if atEnd {
            lock.lock(); o.cancelled = true; lock.unlock()
            source.cancel()
        }
    }
    source.resume()

    var last = -1
    var quiet = 0
    for _ in 0..<80 {
        Thread.sleep(forTimeInterval: 0.05)
        lock.lock(); let bytes = o.bytes, done = o.cancelled; lock.unlock()
        quiet = (bytes == last) ? quiet + 1 : 0
        last = bytes
        if done && !child.isRunning { break }
        if quiet > 40 { lock.lock(); o.stalled = true; lock.unlock(); break }
    }
    lock.lock()
    o.childStillRunning = child.isRunning
    let result = o
    lock.unlock()
    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    source.cancel()
    close(master)
    return result
}

print("PTY + dispatch-source behaviour behind AgentRunner.readStdout")

// 1. A short read is the NORM on a PTY master, so it cannot be read as
//    "the descriptor is drained".
let drained = run(loop: .drainToEAGAIN, lines: 1500)
check(drained.lines == 1500,
      "draining to EAGAIN delivers every line",
      "\(drained.lines)/1500 lines, \(drained.bytes) bytes")
check(drained.shortReads > drained.reads / 2,
      "short reads are the norm on a PTY master",
      "\(drained.shortReads) of \(drained.reads) reads came back short "
      + "(~\(drained.reads > 0 ? drained.bytes / drained.reads : 0) bytes each)")

// 2. Under-draining is SLOW, not fatal: the source re-arms while bytes
//    remain. This is why the short-read break was survivable for so
//    long — and why the hang cannot be blamed on it.
let behind = run(loop: .shortReadBreak, lines: 1500, slowByMicroseconds: 4000)
check(!behind.stalled && behind.lines == 1500,
      "a reader falling behind still finishes — the source re-arms",
      "\(behind.lines)/1500 lines over \(behind.handlerCalls) wakes")

// 3. The child's exit is an n == 0 read, not an errno.
let (m, p) = spawnOnPTY(lines: 1)
p.waitUntilExit()
Thread.sleep(forTimeInterval: 0.2)
var probe = [UInt8](repeating: 0, count: 4096)
let (eofN, eofErr): (Int, Int32) = probe.withUnsafeMutableBufferPointer { ptr in
    let r = read(m, ptr.baseAddress, 4096)
    return (r, r < 0 ? errno : 0)
}
close(m)
check(eofN == 0,
      "a dead child's PTY master reads 0, and that is the one true EOF",
      "n=\(eofN) errno=\(eofErr)")

// 4. The regression itself: one EINTR classified as end-of-stream
//    cancels the reader under a LIVE child, and nothing else is left to
//    drain it — the child blocks in write() and the turn never ends.
let interrupted = run(loop: .shortReadBreak, lines: 1500, injectEINTRAt: 5)
check(interrupted.stalled && interrupted.childStillRunning,
      "EINTR-as-EOF strands a live child (the shape of the field hang)",
      "reader cancelled=\(interrupted.cancelled), "
      + "child running=\(interrupted.childStillRunning), "
      + "\(interrupted.lines)/1500 lines delivered")

let retried = run(loop: .drainToEAGAIN, lines: 1500, injectEINTRAt: 5)
check(!retried.stalled && retried.lines == 1500 && !retried.childStillRunning,
      "retrying EINTR carries the same turn to completion",
      "\(retried.lines)/1500 lines, child exited=\(!retried.childStillRunning)")

print(failures == 0
      ? "\nAll PTY behaviour checks passed."
      : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
