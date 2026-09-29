import Foundation
import Darwin
import Synchronization

/// Captures a stack sample of this process when the main thread stops
/// answering, and does nothing else.
///
/// A hang leaves nothing behind: no crash report, no `.hang` file, and
/// by the time anyone reaches for `sample` the app has been force-quit.
/// The one artefact that names a hang's mechanism is a stack of every
/// thread taken WHILE it is hung, so this takes that stack itself and
/// writes it under `~/Library/Logs/SipAI/`.
///
/// It never intervenes. It does not kill, cancel, finalize, notify or
/// flip any status — a watchdog that "recovers" has been the bug here
/// twice already (see CLAUDE.md, "A turn ends when the CHILD dies").
/// The only process it ever signals is its own `sample` child.
///
/// Shape: a plain pthread — not GCD, not Swift concurrency, either of
/// which may be the thing that is wedged — PINGS the main run loop
/// every `pollInterval` seconds (a `CFRunLoopSource` it signals, plus
/// `CFRunLoopWakeUp`; neither allocates) and reads back an atomic the
/// source's perform bumps. An idle main thread wakes, answers and
/// sleeps again; a hung one never answers, and after `threshold`
/// seconds of silence the watchdog spawns
/// `/usr/bin/sample <pid> 5 1 -mayDie -file <path>`. The ping is what
/// separates idle from hung: an idle loop does not cycle on its own,
/// so a heartbeat that merely counted passes read every quiet moment
/// as a hang (measured on the onboarding screen). Debug builds only:
/// `sample` needs `task_for_pid`, which the hardened runtime refuses; a
/// Release capture has to walk the stacks in-process, allocation-free,
/// and is a separate piece of work.
///
/// Debug-only environment knobs, for the harness and for a manual run:
/// `SIPAI_HANG_THRESHOLD` / `SIPAI_HANG_GRACE` (seconds) override the
/// defaults, `SIPAI_HANG_TEST=<n>` blocks the main thread for n seconds
/// ten seconds after launch so the whole path can be watched end to
/// end, and `HOME` decides where the log directory lives.
enum HangCapture {

    /// Seconds without a main-run-loop beat before a capture. Activity
    /// Monitor says "Not Responding" at about five; `ShellEnvironment`
    /// may legitimately hold the main thread for up to ~12 s once, at
    /// launch, which the grace below also covers.
    static let defaultThreshold: Double = 12
    /// How often the watchdog looks.
    static let pollInterval: Double = 2
    /// Seconds after `start()` during which nothing is judged.
    static let defaultLaunchGrace: Double = 15
    /// Captures per launch. Each is a few hundred kilobytes to a few
    /// megabytes; the app never deletes them.
    static let capturesPerLaunch = 5

    enum Action: Equatable {
        /// The main thread moved, or the process itself was stopped
        /// (debugger pause, system sleep): a new episode starts.
        case resetEpisode
        /// Idle past the threshold, not yet captured this episode,
        /// budget left.
        case capture
        case none
    }

    /// The whole verdict, as a pure function so it can be driven with
    /// no thread, no run loop and no `sample` — the same rule as
    /// `ScheduledTaskScheduler.decide`.
    ///
    /// `overshoot` is the poll having taken far longer than asked: the
    /// process was not scheduled (Xcode's Pause, a sleeping Mac), which
    /// is not a hang and must not spend a capture.
    nonisolated static func decide(beatMoved: Bool,
                                   overshoot: Bool,
                                   idleFor: Double,
                                   threshold: Double,
                                   captured: Bool,
                                   count: Int) -> Action {
        if beatMoved || overshoot { return .resetEpisode }
        if idleFor >= threshold, !captured, count < capturesPerLaunch {
            return .capture
        }
        return .none
    }

#if DEBUG
    // MARK: - Debug implementation

    private static let beat = Atomic<UInt64>(0)
    private static let started = Atomic<Bool>(false)
    private static var pingSource: CFRunLoopSource?

    /// Everything the hung-path needs, built before any hang so the
    /// capture allocates as little as it can: `sample`'s argv as C
    /// strings, a path buffer it fills in place, the spawn attributes
    /// and file actions.
    private static var argv: [UnsafeMutablePointer<CChar>?] = []
    private static var envp: [UnsafeMutablePointer<CChar>?] = []
    private static var pathBuffer: UnsafeMutablePointer<CChar>?
    private static let pathCapacity = 1024
    private static var dirPrefix: [CChar] = []
    private static var attr: posix_spawnattr_t? = nil
    private static var actions: posix_spawn_file_actions_t? = nil
    private static var threshold = defaultThreshold
    private static var launchGrace = defaultLaunchGrace

    /// Call once, on the main thread, early in launch.
    static func start() {
        guard !started.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let env = ProcessInfo.processInfo.environment
        if let t = env["SIPAI_HANG_THRESHOLD"].flatMap(Double.init), t > 0 { threshold = t }
        if let g = env["SIPAI_HANG_GRACE"].flatMap(Double.init), g >= 0 { launchGrace = g }

        // ~/Library/Logs/SipAI — outside the data directory (and so
        // outside the factory reset's sweep); a stack carries no user
        // content. HOME is honoured so a harness can redirect it.
        let home = env["HOME"] ?? NSHomeDirectory()
        let dir = (home as NSString).appendingPathComponent("Library/Logs/SipAI")
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        dirPrefix = Array((dir + "/hang-").utf8CString)
        pathBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: pathCapacity)
        pathBuffer?.initialize(repeating: 0, count: pathCapacity)

        let words: [String] = ["/usr/bin/sample", String(getpid()), "5", "1", "-mayDie", "-file"]
        argv = words.map { strdup($0) }
        argv.append(pathBuffer)
        argv.append(nil)
        envp = [strdup("PATH=/usr/bin:/bin"), nil]

        // The child inherits NOTHING of ours — not a PTY master, not a
        // socket, not a pipe — and starts with default signal
        // dispositions. stdio goes to /dev/null: its report is the file.
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT
                                              | POSIX_SPAWN_SETSIGDEF
                                              | POSIX_SPAWN_SETSIGMASK))
        // Every disposition back to default and nothing blocked: an
        // ignored signal survives exec and a thread's mask is inherited
        // by what it spawns, and neither is `sample`'s business.
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        posix_spawn_file_actions_init(&actions)
        for fd: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null",
                                             fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }

        // The heartbeat's other half: a version-0 source on the main
        // run loop, in the common modes so a modal panel or menu
        // tracking still answers. The watchdog signals it; the main
        // thread performs it — one relaxed increment — if and only if
        // it can still run its loop.
        var context = CFRunLoopSourceContext()
        context.perform = { _ in HangCapture.beat.wrappingAdd(1, ordering: .relaxed) }
        pingSource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
        if let pingSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), pingSource, CFRunLoopMode.commonModes)
        }

        var attrs = pthread_attr_t()
        pthread_attr_init(&attrs)
        pthread_attr_setstacksize(&attrs, 256 * 1024)
        pthread_attr_setdetachstate(&attrs, PTHREAD_CREATE_DETACHED)
        var tid: pthread_t?
        pthread_create(&tid, &attrs, { _ in
            HangCapture.watch()
            return nil
        }, nil)
        pthread_attr_destroy(&attrs)

        if let v = env["SIPAI_HANG_TEST"], let seconds = UInt32(v), seconds > 0 {
            // A real block of the real main thread, through the real
            // observer and the real spawn.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                sleep(seconds)
            }
        }
    }

    /// Uptime that does not advance while the machine sleeps.
    private static func now() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    private static func watch() {
        // Named so a reader of the capture can tell this thread from
        // the ones it is there to record.
        pthread_setname_np("SipAI.HangCapture")
        pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0)
        var lastBeat = beat.load(ordering: .relaxed)
        var lastMove = now()
        var lastPoll = lastMove
        let armedAt = lastMove + launchGrace
        var episodeCaptured = false
        var count = 0
        while true {
            // Ask, then wait for the answer. Signalling a source and
            // waking a run loop are flag-and-message operations: no
            // allocation, nothing the main thread has to be free for.
            if let pingSource {
                CFRunLoopSourceSignal(pingSource)
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            usleep(UInt32(pollInterval * 1_000_000))
            let t = now()
            let overshoot = (t - lastPoll) > pollInterval * 2
            lastPoll = t
            let b = beat.load(ordering: .relaxed)
            let moved = b != lastBeat
            lastBeat = b
            if t < armedAt { lastMove = t; continue }
            switch decide(beatMoved: moved, overshoot: overshoot,
                          idleFor: t - lastMove, threshold: threshold,
                          captured: episodeCaptured, count: count) {
            case .resetEpisode:
                lastMove = t
                episodeCaptured = false
            case .capture:
                capture(idleFor: t - lastMove)
                episodeCaptured = true
                count += 1
            case .none:
                break
            }
        }
    }

    /// Runs on the watchdog thread while the main thread is hung. Two
    /// lines to stderr — `write(2)`, not NSLog: under Xcode os_log is
    /// forwarded synchronously through another process, and this must
    /// not depend on that channel — and one `sample` child, reaped.
    private static func capture(idleFor: Double) {
        guard let path = pathBuffer else { return }
        // <dir>/hang-<yyyyMMdd-HHmmss>.txt, written in place.
        var t = time(nil)
        var parts = tm()
        localtime_r(&t, &parts)
        dirPrefix.withUnsafeBufferPointer { src in
            _ = strlcpy(path, src.baseAddress, pathCapacity)
        }
        let used = strlen(path)
        _ = strftime(path + used, pathCapacity - used, "%Y%m%d-%H%M%S.txt", &parts)

        writeErr("SipAI: main thread unresponsive for ")
        writeErr(Int(idleFor))
        writeErr(" s — sampling to ")
        writeErrC(path)
        writeErr("\n")

        var child: pid_t = 0
        let rc = argv.withUnsafeMutableBufferPointer { av in
            envp.withUnsafeMutableBufferPointer { ev in
                posix_spawn(&child, "/usr/bin/sample", &actions, &attr,
                            av.baseAddress, ev.baseAddress)
            }
        }
        guard rc == 0 else {
            writeErr("SipAI: could not spawn sample (errno ")
            writeErr(Int(rc))
            writeErr(")\n")
            return
        }
        // 5 s of sampling plus symbolication; bounded at 30 s, then the
        // one process this thread ever signals.
        var status: Int32 = 0
        var waited = 0
        while waited < 60 {
            let r = waitpid(child, &status, WNOHANG)
            if r == child { break }
            if r < 0 && errno != EINTR { break }
            usleep(500_000)
            waited += 1
        }
        if waited >= 60 {
            kill(child, SIGKILL)
            waitpid(child, &status, 0)
        }
        // WEXITSTATUS / WTERMSIG by hand: the macros are not imported.
        if status & 0x7f == 0 {
            writeErr("SipAI: sample exited ")
            writeErr(Int((status >> 8) & 0xff))
        } else {
            writeErr("SipAI: sample died on signal ")
            writeErr(Int(status & 0x7f))
        }
        writeErr("\n")
    }

    private static func writeErr(_ s: StaticString) {
        s.withUTF8Buffer { buf in _ = write(2, buf.baseAddress, buf.count) }
    }

    private static func writeErrC(_ cString: UnsafePointer<CChar>) {
        _ = write(2, cString, strlen(cString))
    }

    /// A number, in ASCII, with no allocation.
    private static func writeErr(_ value: Int) {
        var digits: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &digits) { buf in
            var v = value.magnitude
            var i = buf.count
            repeat {
                i -= 1
                buf[i] = UInt8(ascii: "0") + UInt8(v % 10)
                v /= 10
            } while v > 0 && i > 1
            if value < 0 { i -= 1; buf[i] = UInt8(ascii: "-") }
            _ = write(2, buf.baseAddress! + i, buf.count - i)
        }
    }
#else
    static func start() {}
#endif
}
