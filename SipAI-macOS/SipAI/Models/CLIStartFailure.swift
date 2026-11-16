import Foundation

/// The line a command-line tool stopped with when it could not start.
///
/// A tool that cannot start answers `--version` — and every other command
/// — with an error and a non-zero exit. npm installs a tool's macOS program
/// as an OPTIONAL package, and a download of it that fails ends the install
/// with no error at all: what npm leaves is a launcher that throws on every
/// start, in Node's shape — the file and line, the source, a caret, the
/// error ("Error: Missing optional dependency @openai/codex-darwin-arm64.
/// Reinstall Codex: npm install -g @openai/codex@latest"), the stack, and
/// last Node's own version ("Node.js v22.12.0"). The error line is the one
/// that says why, and usually what to do; the last line names Node, not the
/// tool.
///
/// One-line places (the usage card, a transcript row) show `reason(in:)`;
/// Settings → Updates keeps the whole output under Details.
enum CLIStartFailure {
    /// The longest line shown in a one-line place. The error a launcher
    /// throws, its remedy included, is far shorter.
    static let lineCap = 300

    /// The line of `output` that says why the tool stopped: the first line
    /// labelled as an error ("Error: …", "error: …", "TypeError: …",
    /// "fatal: …"), else the last line with words in it. nil when the
    /// output holds none.
    static func reason(in output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let line = lines.first(where: isErrorLabelled) ?? lines.last else { return nil }
        return line.count > lineCap ? String(line.prefix(lineCap)) + "…" : line
    }

    /// A single word naming an error, then a colon. A path
    /// ("file:///…:108") or a stack frame ("at f (file:…)") is none.
    static func isErrorLabelled(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let label = line[..<colon]
        guard !label.isEmpty, label.allSatisfy(\.isLetter) else { return false }
        let word = label.lowercased()
        return word.hasSuffix("error") || word == "fatal"
    }
}
