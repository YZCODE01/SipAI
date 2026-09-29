import Foundation
import Darwin

// Drives the REAL `makeDrainingLineSource` — extracted from
// Models/AgentRunner.swift by run.sh, never copied — over two pipes at
// once. This is the property the stderr reader was moved onto the
// helper for: one reader parked on a silent descriptor must not delay
// another by a single millisecond. The iterator it replaced
// (`FileHandle.bytes.lines`) delivered the second pipe's line only when
// the first pipe CLOSED — measured at 2 s late on this machine.

var failures = 0
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("  \(ok ? "PASS" : "FAIL")  \(label)")
    if !detail.isEmpty { print("        \(detail)") }
    if !ok { failures += 1 }
}

final class Owner {}

/// A pipe with its read end non-blocking, as the readers set it.
func makePipe() -> (read: Int32, write: Int32) {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { fatalError("pipe failed") }
    _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL, 0) | O_NONBLOCK)
    return (fds[0], fds[1])
}

func writeAll(_ fd: Int32, _ s: String) {
    let bytes = Array(s.utf8)
    var off = 0
    while off < bytes.count {
        let n = bytes[off...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        if n <= 0 { fatalError("write failed") }
        off += n
    }
}

let lock = NSLock()
var linesA: [String] = [], linesB: [String] = []
var endsA = 0, endsB = 0
var tailA = Data(), tailB = Data()
var bArrivedAt: Double = -1
let t0 = Date()
func ms() -> Double { Date().timeIntervalSince(t0) * 1000 }

let a = makePipe(), b = makePipe()
let owner = Owner()

print("The shared draining helper, two readers side by side")

let sourceA = Extracted.makeDrainingLineSource(
    fd: a.read, label: "verify.a", owner: owner,
    onLine: { l in lock.lock(); linesA.append(l); lock.unlock() },
    onEnd: { t in lock.lock(); endsA += 1; tailA = t; lock.unlock() })
let sourceB = Extracted.makeDrainingLineSource(
    fd: b.read, label: "verify.b", owner: owner,
    onLine: { l in lock.lock(); linesB.append(l); if bArrivedAt < 0 { bArrivedAt = ms() }; lock.unlock() },
    onEnd: { t in lock.lock(); endsB += 1; tailB = t; lock.unlock() })
sourceA.resume()
sourceB.resume()

// 1. A is silent; a line into B must arrive at once — not when A ends.
Thread.sleep(forTimeInterval: 0.2)
let wroteAt = ms()
writeAll(b.write, "hello\n")
var waited = 0
while waited < 100 {          // up to 5 s
    Thread.sleep(forTimeInterval: 0.05); waited += 1
    lock.lock(); let got = !linesB.isEmpty; lock.unlock()
    if got { break }
}
lock.lock(); let latency = bArrivedAt - wroteAt; let gotB = linesB; lock.unlock()
check(gotB == ["hello"] && latency >= 0 && latency < 500,
      "a line on the second pipe arrives while the first is parked",
      gotB.isEmpty ? "never arrived" : "\(gotB) after \(Int(latency)) ms")

// 2. A line split across two writes is delivered once, whole; the
//    partial half is never delivered on its own.
writeAll(a.write, "half-")
Thread.sleep(forTimeInterval: 0.15)
lock.lock(); let early = linesA; lock.unlock()
writeAll(a.write, "and-half\r\n")
Thread.sleep(forTimeInterval: 0.15)
lock.lock(); let joined = linesA; lock.unlock()
check(early.isEmpty && joined == ["half-and-half\r"],
      "a line split across reads is delivered whole, and only once complete",
      "before newline: \(early); after: \(joined) (the helper keeps a trailing CR; the stderr consumer strips it)")

// 3. A newline-less tail reaches onEnd exactly once, at EOF; an empty
//    pipe's end delivers an empty tail. Both exactly once.
writeAll(a.write, "fatal: no newline")
close(a.write)
close(b.write)
Thread.sleep(forTimeInterval: 0.3)
lock.lock()
let eA = endsA, eB = endsB
let tA = String(data: tailA, encoding: .utf8) ?? "<bad utf8>", tB = tailB
lock.unlock()
check(eA == 1 && tA == "fatal: no newline",
      "a newline-less last message reaches onEnd, once, at EOF",
      "onEnd fired \(eA)× with '\(tA)'")
check(eB == 1 && tB.isEmpty,
      "an empty tail is delivered as empty, once",
      "onEnd fired \(eB)× with \(tB.count) bytes")

// 4. A source whose owner is gone cancels itself on its next wake and
//    still reports its end exactly once.
let c = makePipe()
var endsC = 0
var weakOwner: Owner? = Owner()
let sourceC = Extracted.makeDrainingLineSource(
    fd: c.read, label: "verify.c", owner: weakOwner,
    onLine: { _ in },
    onEnd: { _ in lock.lock(); endsC += 1; lock.unlock() })
sourceC.resume()
weakOwner = nil
writeAll(c.write, "anyone there?\n")
Thread.sleep(forTimeInterval: 0.3)
lock.lock(); let eC = endsC; lock.unlock()
check(eC == 1, "a source whose owner was deallocated cancels itself, ending once",
      "onEnd fired \(eC)×")
close(c.write)

print(failures == 0
      ? "\nAll concurrency checks passed."
      : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
