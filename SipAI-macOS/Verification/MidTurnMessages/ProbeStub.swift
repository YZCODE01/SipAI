// What CodexReviewGit leans on from the app, for the harness: the search
// path an agent child gets — here the harness's own PATH — and a runner
// that runs a binary to its end and hands back what it printed.

import Foundation

extension AgentManager {
    nonisolated static var searchPaths: [String] {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    }
}

enum AgentCLIProbe {
    struct RunResult {
        let exitCode: Int32?
        let output: String
        var processGroup: pid_t? = nil
    }

    nonisolated static func run(binary: String, arguments: [String], ceiling: TimeInterval,
                                outputCap: Int, extraEnvironment: [String: String] = [:],
                                currentDirectory: String? = nil,
                                ceilingYields: (() -> Bool)? = nil,
                                onSpawn: @escaping (Process) -> Void) async -> RunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: binary)
                p.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                for (name, value) in extraEnvironment { environment[name] = value }
                p.environment = environment
                if let currentDirectory { p.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
                p.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch {
                    continuation.resume(returning: RunResult(exitCode: nil, output: "\(error)"))
                    return
                }
                onSpawn(p)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                continuation.resume(returning: RunResult(exitCode: p.terminationStatus,
                                                         output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
