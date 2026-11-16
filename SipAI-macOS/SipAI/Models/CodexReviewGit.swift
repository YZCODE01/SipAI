// CodexReviewGit.swift
// What codex's review picker lists to review: the session folder's local
// branches and its recent commits, read with git.

import Foundation

/// The branches and commits `/review` offers in a codex session — what
/// codex's own terminal lists in its review picker — read off the session's
/// folder with git, through the probe every CLI read goes through (the
/// environment an agent child gets, a ceiling, off the main thread).
enum CodexReviewGit {
    struct Commit: Identifiable, Equatable {
        let sha: String
        let subject: String
        var id: String { sha }
        var shortSha: String { String(sha.prefix(7)) }
    }

    /// How many recent commits the picker lists, newest first.
    static let commitLimit = 100

    /// Local branches: the repository's default first, then the most
    /// recently committed to. Empty where git cannot answer — no git, no
    /// repository.
    nonisolated static func branches(in folder: URL) async -> [String] {
        guard let git = await binary(),
              let listing = await run(git, ["for-each-ref", "--sort=-committerdate",
                                            "--format=%(refname:short)", "refs/heads"], in: folder)
        else { return [] }
        let originHead = await run(git, ["symbolic-ref", "--quiet", "--short",
                                         "refs/remotes/origin/HEAD"], in: folder)
        return orderedBranches(listing, originHead: originHead)
    }

    /// The folder's recent commits, newest first.
    nonisolated static func commits(in folder: URL) async -> [Commit] {
        guard let git = await binary(),
              let log = await run(git, ["log", "-n", String(commitLimit),
                                        "--pretty=format:%H%x1f%s"], in: folder)
        else { return [] }
        return parseCommits(log)
    }

    /// One branch name per line, in the listing's order, with the
    /// repository's default moved first: the branch `origin/HEAD` names,
    /// else `main`, else `master`.
    nonisolated static func orderedBranches(_ listing: String, originHead: String?) -> [String] {
        var names: [String] = []
        for line in listing.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        var preferred: [String] = []
        if let head = originHead?.trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty {
            preferred.append(head.hasPrefix("origin/") ? String(head.dropFirst("origin/".count)) : head)
        }
        preferred += ["main", "master"]
        if let first = preferred.first(where: { names.contains($0) }),
           let index = names.firstIndex(of: first) {
            names.remove(at: index)
            names.insert(first, at: 0)
        }
        return names
    }

    /// `git log --pretty=format:%H%x1f%s`: the full sha, a unit separator,
    /// the subject — one commit per line. A line that is not a sha is not a
    /// commit.
    nonisolated static func parseCommits(_ log: String) -> [Commit] {
        var commits: [Commit] = []
        for line in log.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            let sha = parts[0].trimmingCharacters(in: .whitespaces)
            guard sha.count >= 7, sha.allSatisfy(\.isHexDigit) else { continue }
            let subject = parts.count > 1 ? String(parts[1]) : ""
            commits.append(Commit(sha: sha, subject: subject))
        }
        return commits
    }

    /// git, where it can answer: one on the PATH an agent child gets — never
    /// `/usr/bin/git` itself, which on a Mac without the developer tools
    /// offers to install them instead of answering — else the developer
    /// tools' own, where they are installed.
    nonisolated static func binary() async -> String? {
        let fm = FileManager.default
        for dir in AgentManager.searchPaths where dir != "/usr/bin" {
            let path = (dir as NSString).appendingPathComponent("git")
            if fm.isExecutableFile(atPath: path) { return path }
        }
        let selected = await AgentCLIProbe.run(binary: "/usr/bin/xcode-select", arguments: ["-p"],
                                               ceiling: 5, outputCap: 4096, onSpawn: { _ in })
        guard selected.exitCode == 0 else { return nil }
        let developer = selected.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (developer as NSString).appendingPathComponent("usr/bin/git")
        return !developer.isEmpty && fm.isExecutableFile(atPath: path) ? path : nil
    }

    /// git's answer, or nil where it did not answer cleanly. Never asks for
    /// a password, and takes no lock a git running beside it could find
    /// busy.
    private nonisolated static func run(_ git: String, _ arguments: [String],
                                        in folder: URL) async -> String? {
        let result = await AgentCLIProbe.run(
            binary: git, arguments: arguments, ceiling: 10, outputCap: 512 * 1024,
            extraEnvironment: ["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"],
            currentDirectory: folder.path, onSpawn: { _ in })
        return result.exitCode == 0 ? result.output : nil
    }
}
