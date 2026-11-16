import Foundation

// A message box line that starts with `!` is the user's own shell command,
// as each CLI's terminal reads one — Claude Code's bash mode, Codex's `!`,
// Kimi Code's shell mode: run directly, with no model, no approval and no
// sandbox, and its output joins the conversation. SipAI runs it through
// the CLI's own route and draws what the CLI records, so a `!` typed here
// does what the same line does in that CLI's terminal.
//
// Foundation only: the harnesses compile this file on its own.

/// A draft read as a shell command.
enum ShellCommandInput {
    /// The command a draft holds, or nil when it is not one: the draft's
    /// first character past leading blanks is `!`, and words follow it.
    /// A lone `!` is no command — there is nothing to run.
    static func command(in draft: some StringProtocol) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("!") else { return nil }
        let command = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    /// The row a command is drawn as, live and reopened alike: one spelling,
    /// so a mid-turn reload's cut and the find pipeline match it.
    static func display(_ command: String) -> String { "!" + command }

    /// How the transcript draws a command's row: a code block holding the
    /// line as `display` spells it, so markdown never reads it and a
    /// backtick in it cannot end the block (the fence outruns every run of
    /// backticks inside). Search counts the row in the same text.
    static func markdown(_ display: String) -> String {
        var longest = 0, run = 0
        for character in display {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "\n" + display + "\n" + fence
    }

    /// The command a row drawn by `display` holds.
    static func command(fromDisplay text: String) -> String? {
        guard text.hasPrefix("!") else { return nil }
        let command = String(text.dropFirst())
        return command.isEmpty ? nil : command
    }
}

/// One transcript row of a `!` command: the line, or what it printed.
enum ShellCommandRow: Equatable {
    case command(String)
    case output(ShellCommandOutput)
}

/// What a shell command left, as its agent reports it.
struct ShellCommandOutput: Equatable, Hashable {
    var stdout: String
    var stderr: String
    /// Nil when the agent did not say.
    var exitCode: Int?
    /// The command was stopped before it finished.
    var interrupted: Bool = false
    /// The agent refused to run it, in its own words.
    var notRun: String? = nil

    /// The text drawn and searched: what the command printed, its error
    /// stream after its output.
    var text: String {
        [stdout, stderr]
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The agent says the command failed without giving an exit code
    /// (kimi's record).
    var reportedFailure: Bool = false

    /// What the transcript draws of `text`: its first `displayLineCap`
    /// lines and `displayCharacterCap` characters, and whether anything was
    /// left out. A command that printed megabytes laid out whole would hold
    /// the main thread — each terminal shows a long output cut short too —
    /// so this reads no further than the caps.
    var shown: (text: String, cut: Bool) {
        var out = ""
        var lines = 1
        var characters = 0
        for part in [stdout, stderr] {
            var body = Substring(part)
            while let first = body.first, first.isNewline { body = body.dropFirst() }
            while let last = body.last, last.isNewline { body = body.dropLast() }
            guard !body.isEmpty else { continue }
            if !out.isEmpty {
                lines += 1
                guard lines <= Self.displayLineCap else { return (out, true) }
                out.append("\n")
            }
            for character in body {
                if character.isNewline {
                    lines += 1
                    guard lines <= Self.displayLineCap else { return (out, true) }
                }
                guard characters < Self.displayCharacterCap else { return (out, true) }
                out.append(character)
                characters += 1
            }
        }
        return (out, false)
    }

    static let displayLineCap = 200
    static let displayCharacterCap = 20_000

    /// A command that ran and failed: a non-zero exit code it was not
    /// stopped with, or the agent's own word that it failed.
    var failed: Bool {
        guard !interrupted, notRun == nil else { return false }
        if reportedFailure { return true }
        guard let exitCode else { return false }
        return exitCode != 0
    }
}

/// What SipAI says about a `!` command itself.
enum ShellCommandWords {
    /// Above the box, for a draft that runs as a shell command.
    static func runsInShell(agentName: String) -> String {
        String(localized: "Runs in your shell, as in \(agentName)’s terminal: no model, no approval. \(agentName) sees the output.",
               comment: "Composer hint when a draft starts with ! and SipAI runs it as the user's own shell command; placeholder is the agent label")
    }

    /// Above the box, where the agent offers no way to run one.
    static func sentAsMessage(agentName: String) -> String {
        String(localized: "\(agentName) runs ! commands only in its own terminal. This will be sent as an ordinary message.",
               comment: "Composer hint when a draft starts with ! and the agent has no way for SipAI to run it as a shell command; placeholder is the agent label")
    }

    /// Above the box while the installed tool has not been read: Send
    /// waits for it.
    static func checking(agentName: String) -> String {
        String(localized: "Checking whether the installed \(agentName) can run ! commands. Send waits for the answer.",
               comment: "Composer hint when a draft starts with ! and the installed agent's version has not been read yet; placeholder is the agent label")
    }

    /// Above the box, and the runner's error, where the installed tool is
    /// older than the route needs: Send waits.
    static func needsNewer(agentName: String) -> String {
        String(localized: "Running a ! command needs a newer \(agentName). Update it in Settings → Updates.",
               comment: "Composer hint and runner error: a ! command needs a newer version of the agent; placeholder is the agent label")
    }
}

// MARK: - Claude Code

/// Claude Code's `!`, bridged: claude runs the command through its own
/// headless message for it, given the command line claude's terminal builds
/// (`ClaudeTerminalShell`), then SipAI hands claude the two rows its
/// terminal writes for a `!` command (`Verification/ShellCommands` drives
/// both halves through the real claude).
///
/// * `{"type":"bash_command","command":…,"cwd":…}` on claude's stream-json
///   input runs the command "verbatim, without the model and without
///   permission checks" in a one-shot `/bin/sh -c` beside the conversation,
///   in `cwd` (the session's folder when omitted), and claude prints two
///   rows back: `<bash-input>…`, then `<bash-stdout>…</bash-stdout>
///   <bash-stderr>…</bash-stderr><bash-exit-code>N</bash-exit-code>`. It
///   keeps nothing — the conversation never sees the command, and no
///   request reaches the model. Closing claude's input while the command
///   runs interrupts it (`[interrupted]`, exit 130).
/// * Claude's terminal then adds a `<bash-input>` user message and a
///   `<bash-stdout>…</bash-stdout><bash-stderr>…</bash-stderr>` one, and
///   asks the model to answer unless the setting `respondToBashCommands`
///   is false — when it adds a hidden note first and asks nothing. SipAI
///   hands claude the same rows as the text blocks of ONE message on its
///   input — `shouldQuery: false` when claude should not answer — with the
///   same effect: one model request carrying the output, or none and the
///   next message carrying it. One message, because claude joins messages
///   that wait in its input into one record when they arrive together —
///   written as separate messages, the rows would be kept in a shape that
///   depends on timing. The model reads either alike: messages of one role
///   in a row reach it as one.
/// * The rows are the terminal's own shape (`terminalOutput`): the command
///   line as typed; a command that succeeds has all it printed in the
///   output row, trailing blank space cut, or "(Bash completed with no
///   output)"; one that fails has it all in the error row and an empty
///   output row; no exit code either way. `&`, `<` and `>` are escaped in
///   the two output rows (never quotes), never in the command line.
///
/// The message needs claude's input held open, which `ClaudeSteer` gates
/// (`ShellCommandSupport`); a claude from that floor up carries it.
enum ClaudeShellCommand {
    /// Claude's own headless message for a `!` command, run in `cwd` (the
    /// session's folder when nil).
    static func bashCommandLine(_ command: String, cwd: String? = nil) -> String {
        var message: [String: Any] = ["type": "bash_command", "command": command]
        if let cwd { message["cwd"] = cwd }
        return line(message)
    }

    /// A user message on claude's stream-json input. `query: false` adds it
    /// to the conversation without starting a model request.
    static func userLine(_ text: String, query: Bool) -> String {
        userLine(content: text, query: query)
    }

    /// The rows of one `!` command as one message: each row a text block.
    static func rowsLine(_ rows: [String], query: Bool) -> String {
        userLine(content: rows.map { ["type": "text", "text": $0] }, query: query)
    }

    private static func userLine(content: Any, query: Bool) -> String {
        var object: [String: Any] = ["type": "user",
                                     "message": ["role": "user", "content": content],
                                     "parent_tool_use_id": NSNull(),
                                     "session_id": ""]
        if !query { object["shouldQuery"] = false }
        return line(object)
    }

    /// The hidden note claude's terminal puts above a `!` command it does
    /// not ask the model to answer, in claude's words. The readers drop it
    /// with its tag (`AgentSessionScanner.cleanUserText`).
    static let quietNote = "<local-command-caveat>The command below was run directly in "
        + "Claude Code, not sent to you as a request, and its output goes straight to the "
        + "user. It's recorded here as context for later messages.</local-command-caveat>"

    /// The input row claude's terminal writes: the command as typed, never
    /// escaped (its output rows are).
    static func inputRow(_ command: String) -> String {
        "<bash-input>" + command + "</bash-input>"
    }

    // MARK: The terminal's record

    /// What claude's terminal records as the output of a command that
    /// succeeded and printed nothing.
    static let noOutputText = "(Bash completed with no output)"

    /// The note claude's terminal adds to the error row when a command left
    /// the session's folder and the next one starts back there.
    static func folderResetNote(_ folder: String) -> String {
        "\nShell cwd was reset to " + folder
    }

    /// A command's result in the shape claude's terminal records it: all it
    /// printed (`merged`, its two streams as one) in the output row when it
    /// succeeded — trailing blank space cut — with the folder note, if any,
    /// in the error row; all of it in the error row, the output row empty,
    /// when it failed. No exit code. What SipAI draws is this same shape,
    /// so a row reads the same live and reopened.
    static func terminalOutput(merged: String, exitCode: Int?, folderResetTo: String?) -> ShellCommandOutput {
        guard exitCode == 0 else {
            var output = ShellCommandOutput(stdout: "", stderr: merged, exitCode: nil)
            output.reportedFailure = true
            return output
        }
        var end = merged.endIndex
        while end > merged.startIndex, merged[merged.index(before: end)].isWhitespace {
            end = merged.index(before: end)
        }
        return ShellCommandOutput(stdout: String(merged[..<end]),
                                  stderr: folderResetTo.map(folderResetNote) ?? "",
                                  exitCode: nil)
    }

    /// The error row's text for a failed command past `cap` characters: its
    /// head and claude's own words for the lines left out.
    static func errorText(_ text: String, cap: Int) -> String {
        guard text.count > cap else { return text }
        let head = text.prefix(cap)
        let rest = text[head.endIndex...]
        let dropped = rest.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } + 1
        return String(head) + "\n\n... [\(dropped) lines truncated] ..."
    }

    /// The output row claude's terminal writes. `stdout` is the model's
    /// copy — `modelStdout` decides it — and is escaped here unless it is
    /// claude's own long-output form, which goes in as it is.
    static func outputRow(stdout: String, stderr: String) -> String {
        let out = stdout.hasPrefix(persistedOpen) || stdout.hasPrefix(truncatedOpen)
            ? stdout : escape(stdout)
        return "<bash-stdout>" + out + "</bash-stdout><bash-stderr>" + escape(stderr) + "</bash-stderr>"
    }

    // MARK: Long output

    /// How many characters of a command's output the model gets inline:
    /// claude's setting `bashOutputMaxChars`, default 30,000, clamped to
    /// 4,000–128,000 as claude clamps it. `settings` in the order claude
    /// applies them (user, project, project-local) — a later file wins.
    static func outputCap(settings: [Data]) -> Int {
        var cap = defaultCap
        for data in settings {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let value = obj["bashOutputMaxChars"] as? NSNumber else { continue }
            cap = min(max(value.intValue, 4_000), 128_000)
        }
        return cap
    }
    static let defaultCap = 30_000

    /// Whether claude answers a `!` command: its setting
    /// `respondToBashCommands`, default true, a later file winning.
    static func responds(settings: [Data]) -> Bool {
        var responds = true
        for data in settings {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let value = obj["respondToBashCommands"] as? Bool else { continue }
            responds = value
        }
        return responds
    }

    /// The model's copy of a command's output: whole up to `cap`; past it,
    /// claude's own long-output form — the whole output in a file of the
    /// session's `tool-results` folder (`savedPath`) and a 2 KB preview of
    /// whole lines ("Output too large (38KB). Full output saved to: …",
    /// "Preview (first 2KB):", the lines, "..."). With no file to
    /// point at (`savedPath` nil — a new session has no folder yet), claude's
    /// own form for output it could not save: the first `cap` characters.
    static func modelStdout(_ stdout: String, cap: Int, savedPath: String?) -> String {
        guard stdout.count > cap else { return stdout }
        let size = sizeText(stdout.utf8.count)
        guard let savedPath else {
            let head = String(stdout.prefix(cap))
            return truncatedOpen + "\nOutput too large (\(size)). It could not be saved, so only the first "
                + "\(sizeText(head.utf8.count)) are shown; the rest was dropped. If the tool can page or "
                + "filter its results, call it again for the part you need.\n\n" + escape(head)
                + "\n" + truncatedClose
        }
        // Claude's terminal hands its long-output form over unescaped,
        // preview included; `outputRow` keeps it so.
        let (preview, more) = previewLines(stdout, limit: previewBytes)
        return persistedOpen + "\nOutput too large (\(size)). Full output saved to: \(savedPath)\n\n"
            + "Preview (first \(sizeText(previewBytes))):\n" + preview
            + (more ? "\n...\n" : "\n") + persistedClose
    }

    /// The file name claude gives a saved output: nine lowercase letters and
    /// digits, `.txt`.
    static func savedOutputName() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<9).map { _ in alphabet.randomElement()! }) + ".txt"
    }

    static let previewBytes = 2_000
    static let persistedOpen = "<persisted-output>"
    static let persistedClose = "</persisted-output>"
    static let truncatedOpen = "<truncated-output>"
    static let truncatedClose = "</truncated-output>"

    /// The first whole lines of `text` within `limit` bytes, and whether
    /// any of it was left out.
    static func previewLines(_ text: String, limit: Int) -> (String, Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        var out = ""
        var used = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let cost = line.utf8.count + (out.isEmpty ? 0 : 1)
            if used + cost > limit { break }
            out += (out.isEmpty ? "" : "\n") + line
            used += cost
        }
        if out.isEmpty { out = String(String(decoding: Array(text.utf8.prefix(limit)), as: UTF8.self)) }
        return (out, true)
    }

    /// A size the way claude words one: "38KB" for 38,894 bytes.
    static func sizeText(_ bytes: Int) -> String {
        if bytes < 1_024 { return "\(bytes) bytes" }
        let units = ["KB", "MB", "GB"]
        var value = Double(bytes) / 1_024
        var unit = 0
        while value >= 1_024, unit < units.count - 1 { value /= 1_024; unit += 1 }
        let rounded = (value * 10).rounded() / 10
        let number = rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        return number + units[unit]
    }

    // MARK: Reading claude's rows

    /// The command of an input row, or nil for any other text. Claude's
    /// terminal writes it as typed; kimi's escapes it (`unescaping`).
    static func command(fromRow text: String, unescaping: Bool = false) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<bash-input>"), trimmed.hasSuffix("</bash-input>") else { return nil }
        let inner = String(trimmed.dropFirst("<bash-input>".count).dropLast("</bash-input>".count))
        let command = (unescaping ? unescape(inner) : inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    /// An output row as claude's terminal records it (no exit code): its
    /// no-output words are no output, and an empty output row is a command
    /// that failed — one that succeeds always has its output or those words
    /// there.
    static func recordOutput(fromRow text: String) -> ShellCommandOutput? {
        guard var output = output(fromRow: text) else { return nil }
        guard output.exitCode == nil, !output.interrupted, output.notRun == nil else { return output }
        if output.stdout == noOutputText {
            output.stdout = ""
        } else if output.stdout.isEmpty {
            output.reportedFailure = true
        }
        return output
    }

    /// What an output row says, or nil for any other text. A row the
    /// headless message answers with when it does not run the command
    /// carries "Not run: …" as its only error text.
    static func output(fromRow text: String) -> ShellCommandOutput? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<bash-stdout>") || trimmed.hasPrefix("<bash-stderr>") else { return nil }
        let stdout = unwrappedLongOutput(section("bash-stdout", in: trimmed) ?? "")
        let stderr = section("bash-stderr", in: trimmed) ?? ""
        let exit = section("bash-exit-code", in: trimmed)
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var output = ShellCommandOutput(stdout: stdout, stderr: stderr, exitCode: exit)
        let error = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if error == "[interrupted]" {
            output.interrupted = true
            output.stderr = ""
        } else if error.hasPrefix("Not run:"), stdout.isEmpty {
            output.notRun = error
            output.stderr = ""
        }
        return output
    }

    /// A long output as the row keeps it — claude's own long-output form —
    /// read as claude's words inside it: the size, where the whole output
    /// is saved, the preview. The wrapper's tags are claude's, never drawn.
    static func unwrappedLongOutput(_ stdout: String) -> String {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [(persistedOpen, persistedClose), (truncatedOpen, truncatedClose)]
        where trimmed.hasPrefix(open) && trimmed.hasSuffix(close) {
            return String(trimmed.dropFirst(open.count).dropLast(close.count))
                .trimmingCharacters(in: .newlines)
        }
        return stdout
    }

    /// The inner text of the first `<tag>…</tag>` pair, unescaped.
    private static func section(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return unescape(String(text[open.upperBound..<close.lowerBound]))
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Undoes claude's escaping (`&`, `<`, `>`) and kimi's (the same, and `"`).
    static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The rows of a user record that holds a `!` command, in either shape
    /// claude keeps one: a record per row (its terminal's), or one record of
    /// text blocks (SipAI's). The hidden note draws nothing. Nil when any
    /// block is something else — that record is a message.
    static func rows(fromContent content: Any) -> [ShellCommandRow]? {
        let texts: [String]
        if let text = content as? String {
            texts = [text]
        } else if let blocks = content as? [[String: Any]],
                  blocks.allSatisfy({ $0["type"] as? String == "text" }) {
            texts = blocks.compactMap { $0["text"] as? String }
        } else {
            return nil
        }
        var rows: [ShellCommandRow] = []
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == quietNote { continue }
            if let command = command(fromRow: trimmed) {
                rows.append(.command(command))
            } else if let output = recordOutput(fromRow: trimmed) {
                rows.append(.output(output))
            } else {
                return nil
            }
        }
        return rows.isEmpty ? nil : rows
    }

    /// The text of the user row a stdout line carries, or nil for any other
    /// line: the row claude prints back for a `!` command it ran.
    static func userRowText(line: String) -> String? {
        guard line.contains("\"type\":\"user\""), let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["type"] as? String == "user",
              let message = obj["message"] as? [String: Any]
        else { return nil }
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// Claude's answer to a message that started no model request, which
    /// claude writes after the two quiet rows of a `!` it does not answer:
    /// bookkeeping, not words of claude's — never a row.
    static let noResponseText = "No response requested."

    private static func line(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

// MARK: - Claude Code's terminal shell

/// How Claude Code's own terminal runs a `!` command, which SipAI hands to
/// claude's headless message for it — that message by itself runs a plain
/// `/bin/sh -c`, with no startup file, no folder carried over and its input
/// left open:
///
/// * the shell is `CLAUDE_CODE_SHELL`, then `SHELL`, when it names bash or
///   zsh and can run; else zsh, then bash (bash first when `SHELL` names
///   bash), found on the PATH or in /bin, /usr/bin, /usr/local/bin,
///   /opt/homebrew/bin;
/// * it runs as a login shell (`-c -l`) with the user's startup file
///   (`~/.zshrc`, `~/.bashrc`, else `~/.profile`) taken in first, its own
///   output discarded — claude keeps a snapshot of what that file defines;
///   here the file itself — then claude's own PATH, zsh's
///   `NO_EXTENDED_GLOB NO_BARE_GLOB_QUAL` (bash: `extglob` off, aliases
///   expanded);
/// * the command goes through `eval` — an alias the startup file defines
///   only expands in a line read after it — with its input from
///   `/dev/null` unless it brings its own (a here-document, a `<`);
/// * its two output streams are one, as the terminal reads them;
/// * after a command that succeeds, the folder it ended in is written to a
///   file (`pwd -P`), and the next `!` starts there while it is inside the
///   session's folder (`nextFolder`).
enum ClaudeTerminalShell {
    static let searchFolders = ["/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]

    /// The shell the terminal runs a command in, or nil when none can run.
    static func shell(environment: [String: String], isExecutable: (String) -> Bool) -> String? {
        let named = [environment["CLAUDE_CODE_SHELL"], environment["SHELL"]]
            .compactMap { $0 }
            .filter { $0.contains("bash") || $0.contains("zsh") }
        let bashFirst = environment["SHELL"]?.contains("bash") == true
        func onPath(_ name: String) -> String? {
            (environment["PATH"] ?? "").split(separator: ":")
                .map { "\($0)/\(name)" }
                .first(where: isExecutable)
        }
        let order = bashFirst ? ["bash", "zsh"] : ["zsh", "bash"]
        let candidates = named
            + [onPath(order[0])].compactMap { $0 }
            + order.flatMap { name in searchFolders.map { "\($0)/\(name)" } }
            + [onPath(order[1])].compactMap { $0 }
        return candidates.first(where: isExecutable)
    }

    /// The startup file the terminal takes the user's aliases, functions and
    /// options from.
    static func startupFile(shell: String, home: String) -> String {
        let name = shell.contains("zsh") ? ".zshrc" : shell.contains("bash") ? ".bashrc" : ".profile"
        return (home as NSString).appendingPathComponent(name)
    }

    /// Whether the command brings its own input — a here-document, or a
    /// `<` from a file — so it keeps it.
    static func keepsInput(_ command: String) -> Bool {
        func matches(_ pattern: String) -> Bool {
            command.range(of: pattern, options: .regularExpression) != nil
        }
        // A shift (`1 << 2`, `$((a << b))`) is no here-document.
        let shift = matches(#"\d\s*<<\s*\d"#) || matches(#"\[\[\s*\d+\s*<<\s*\d+\s*\]\]"#)
            || matches(#"\$\(\(.*<<.*\)\)"#)
        let hereDocument = !shift && matches(#"<<-?\s*(?:(['"]?)(\w+)\1|\\(\w+))"#)
        let fromFile = matches(#"(?:^|[\s;&|])<(?![<(])\s*\S+"#)
        return hereDocument || fromFile
    }

    /// The command line claude's headless message runs: the terminal's,
    /// with the folder the command ends in written to `folderFile`.
    static func commandLine(_ command: String, shell: String, home: String, folderFile: String) -> String {
        let zsh = shell.contains("zsh"), bash = shell.contains("bash")
        let startup = quoted(startupFile(shell: shell, home: home))
        let steps: [String?] = [
            "{ [ -r \(startup) ] && source \(startup) < /dev/null; } >/dev/null 2>&1",
            bash ? "shopt -s expand_aliases" : nil,
            "export PATH=\"$SIPAI_CLAUDE_PATH\"",
            "unset SIPAI_CLAUDE_PATH",
            zsh ? "setopt NO_EXTENDED_GLOB NO_BARE_GLOB_QUAL 2>/dev/null"
                : bash ? "shopt -u extglob 2>/dev/null" : nil,
            "{ \\builtin unalias -- 'unsetenv'; \\builtin unset -f -- 'unsetenv'; } >/dev/null 2>&1",
            "exec 2>&1",
            "eval \(quoted(command))\(keepsInput(command) ? "" : " < /dev/null")"
                + " && pwd -P >| \(quoted(folderFile))",
        ]
        let script = steps.compactMap { $0 }.joined(separator: "; ")
        return "SIPAI_CLAUDE_PATH=\"$PATH\" exec \(quoted(shell)) -c -l \(quoted(script))"
    }

    /// Where the next `!` starts, after a command run in `current` reported
    /// `reported` (nil when it failed, so its folder was not recorded):
    /// the reported folder while it is the session's folder or inside it;
    /// back at the session's folder otherwise, with the terminal's note
    /// (`resetNote`). Nil means the session's folder. With claude's
    /// `CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR` on, every command starts
    /// there and nothing is said.
    static func nextFolder(reported: String?, current: String?, sessionFolder: String,
                           maintainsSessionFolder: Bool) -> (folder: String?, resetNote: Bool) {
        if maintainsSessionFolder { return (nil, false) }
        guard let reported else { return (current, false) }
        if reported == sessionFolder { return (nil, false) }
        if reported.hasPrefix(sessionFolder.hasSuffix("/") ? sessionFolder : sessionFolder + "/") {
            return (reported, false)
        }
        return (nil, true)
    }

    /// The `env` blocks of claude's settings files, later files winning —
    /// claude puts them in its own environment, which its commands run in.
    static func settingsEnvironment(_ settings: [Data]) -> [String: String] {
        var environment: [String: String] = [:]
        for data in settings {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let block = object["env"] as? [String: Any] else { continue }
            for (name, value) in block {
                if let text = value as? String {
                    environment[name] = text
                } else if let number = value as? NSNumber {
                    environment[name] = CFGetTypeID(number) == CFBooleanGetTypeID()
                        ? (number.boolValue ? "true" : "false") : number.stringValue
                }
            }
        }
        return environment
    }

    /// Claude's rule for a switch in its environment being on.
    static func isOn(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "on"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

// MARK: - Codex

/// Codex's `!`, through its app-server (`Verification/ShellCommands`
/// drives it through the real codex):
///
/// * `thread/shellCommand {threadId, command}` answers `{}` and runs the
///   command as a turn of its own — `turn/started`, a `commandExecution`
///   item with `source: "userShell"` (its output deltas, then the completed
///   item with `aggregatedOutput` and `exitCode`), `turn/completed` — with
///   no model request, outside the sandbox whatever the thread's mode, in
///   the user's login shell. The thread must be loaded first.
/// * The rollout keeps it as a user message, `<user_shell_command>` with
///   the command, the exit code, the duration and the output, and the model
///   reads that with the next message. Codex starts no turn by itself.
/// * `turn/interrupt` stops it: "command aborted by user", exit code -1.
///   Codex ends only its own child, as in its terminal.
enum CodexShellCommand {
    static func params(threadId: String, command: String) -> [String: Any] {
        ["threadId": threadId, "command": command]
    }

    /// An item of the user's own shell command.
    static func isUserShell(_ item: [String: Any]) -> Bool {
        item["type"] as? String == "commandExecution" && item["source"] as? String == "userShell"
    }

    /// What a completed item says. Codex merges the command's two streams
    /// into one, so all of it is the output.
    static func output(fromItem item: [String: Any], stopped: Bool) -> ShellCommandOutput {
        let exit = (item["exitCode"] as? NSNumber)?.intValue
        var output = ShellCommandOutput(stdout: item["aggregatedOutput"] as? String ?? "",
                                        stderr: "", exitCode: exit)
        if stopped, exit == -1 {
            output.interrupted = true
            output.stdout = ""
        }
        return output
    }

    /// A rollout user message that is a `!` command's record, read: the
    /// command and what it left. Nil for any other text.
    static func record(fromText text: String) -> (command: String, output: ShellCommandOutput)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<user_shell_command>"),
              let command = section("command", in: trimmed)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty
        else { return nil }
        let result = section("result", in: trimmed) ?? ""
        var exit: Int?
        var body = ""
        var inOutput = false
        for line in result.split(separator: "\n", omittingEmptySubsequences: false) {
            if inOutput {
                body += (body.isEmpty ? "" : "\n") + line
            } else if line.hasPrefix("Exit code:") {
                exit = Int(line.dropFirst("Exit code:".count).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("Output:") {
                inOutput = true
                let rest = line.dropFirst("Output:".count).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { body = rest }
            }
        }
        var output = ShellCommandOutput(stdout: body.trimmingCharacters(in: .newlines),
                                        stderr: "", exitCode: exit)
        if exit == -1, output.stdout == "command aborted by user" {
            output.interrupted = true
            output.stdout = ""
        }
        return (command, output)
    }

    private static func section(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }
}

// MARK: - Kimi Code

/// Kimi Code's `!` has no route for an app: `kimi acp` sends `!…` to the
/// model as a message, and `kimi web` offers no request that runs one —
/// the one route that reaches it is a test-only switch kimi tells
/// production callers to leave off. So a Kimi session's `!` is sent as an
/// ordinary message, and the composer says so.
///
/// Kimi's terminal keeps a `!` it ran as two user records with
/// `origin.kind: "shell_command"` — `phase: "input"` holding
/// `<bash-input>…</bash-input>`, `phase: "output"` holding claude's own
/// `<bash-stdout>…</bash-stdout><bash-stderr>…</bash-stderr>` shape
/// (`isError` on a failure), every row escaped (`&`, `<`, `>` and `"`) —
/// which the reader draws as Claude's.
enum KimiShellCommand {
    /// A record's row: the command of an input record, or the output of an
    /// output record; nil for any other message.
    static func row(origin: [String: Any]?, text: String) -> ShellCommandRow? {
        guard origin?["kind"] as? String == "shell_command" else { return nil }
        switch origin?["phase"] as? String {
        case "input":
            return ClaudeShellCommand.command(fromRow: text, unescaping: true).map(ShellCommandRow.command)
        case "output":
            guard var output = ClaudeShellCommand.output(fromRow: text) else { return nil }
            if origin?["isError"] as? Bool == true { output.reportedFailure = true }
            return .output(output)
        default:
            return nil
        }
    }
}
