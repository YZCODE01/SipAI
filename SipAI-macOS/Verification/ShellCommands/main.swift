// A `!` command in SipAI does what the same line does in the agent's own
// terminal: the user's shell command, run directly — no model, no approval,
// no sandbox — and its output joins the conversation.
//
//   Claude Code: claude's own headless message for it (`bash_command`) runs
//   the command and prints the terminal's two rows back; SipAI then hands
//   claude those rows as user messages, the input one asking for nothing,
//   and claude answers unless its setting `respondToBashCommands` says not
//   to. Output past `bashOutputMaxChars` goes in claude's own long-output
//   form.
//   Codex: `thread/shellCommand` over its app-server — a turn of its own,
//   no model request, recorded as a `<user_shell_command>` user message.
//   Kimi Code: no route an app may use — the composer says `!` is sent as
//   an ordinary message — but its terminal's records are drawn.
//
// 1. the rules, pure; 2. the readers over each CLI's measured record shapes;
// 3. the real claude and 4. the real codex, token-free, through the stand-in
// endpoint; 5. the wiring, read off the sources.

import Foundation

var failures = 0
var skips = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        print("  ok    \(name)")
    } else {
        failures += 1
        print("  FAIL  \(name)")
        let d = detail()
        if !d.isEmpty { print("        \(d)") }
    }
}
func skip(_ name: String, _ why: String) {
    skips += 1
    print("  SKIP  \(name) — \(why)")
}

let sourceRoot = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let standIn = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("shellharness-\(UUID().uuidString.prefix(8))")
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
// The codex scanner's store is under the home folder, read once: a
// throwaway home, set before anything reads it, keeps the user's own
// sessions out of the title check.
let fakeHome = scratch.appendingPathComponent("home")
try? FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
setenv("CFFIXED_USER_HOME", fakeHome.path, 1)

// MARK: - 1. The rules

print("1. The rules")

check("a draft whose first character is ! holds a command",
      ShellCommandInput.command(in: "!ls -la") == "ls -la"
      && ShellCommandInput.command(in: "  !echo hi\n") == "echo hi"
      && ShellCommandInput.command(in: "! git status") == "git status")
check("a lone !, a ! later in the line, or a message with no ! is no command",
      ShellCommandInput.command(in: "!") == nil && ShellCommandInput.command(in: "!   ") == nil
      && ShellCommandInput.command(in: "hello !x") == nil && ShellCommandInput.command(in: "ls") == nil)
check("the row spells the command one way, live and reopened, and gives it back",
      ShellCommandInput.display("ls") == "!ls" && ShellCommandInput.command(fromDisplay: "!ls") == "ls")
check("the row is drawn as a code block whose fence outruns every backtick in it",
      ShellCommandInput.markdown("!echo hi") == "```\n!echo hi\n```"
      && ShellCommandInput.markdown("!echo ```x```") == "````\n!echo ```x```\n````")

let bashLine = ClaudeShellCommand.bashCommandLine("echo hi")
let bashObject = (try? JSONSerialization.jsonObject(with: Data(bashLine.utf8))) as? [String: Any]
check("claude's own message for a ! command, one line",
      bashObject?["type"] as? String == "bash_command" && bashObject?["command"] as? String == "echo hi"
      && bashLine.hasSuffix("\n") && bashLine.filter { $0 == "\n" }.count == 1, bashLine)
let rowsLine = ClaudeShellCommand.rowsLine(["<bash-input>x</bash-input>", "<bash-stdout>y</bash-stdout><bash-stderr></bash-stderr>"], query: false)
let rowsObject = (try? JSONSerialization.jsonObject(with: Data(rowsLine.utf8))) as? [String: Any]
let rowsBlocks = ((rowsObject?["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
check("a ! command's rows go to claude as the text blocks of ONE message — claude keeps that whole",
      rowsBlocks.count == 2 && rowsBlocks.allSatisfy { $0["type"] as? String == "text" }
      && rowsObject?["shouldQuery"] as? Bool == false, rowsLine)
let quietLine = ClaudeShellCommand.userLine("x", query: false)
let askingLine = ClaudeShellCommand.userLine("x", query: true)
check("a row handed over asks for no model request only when told so",
      quietLine.contains("\"shouldQuery\":false") && !askingLine.contains("shouldQuery")
      && quietLine.contains("\"type\":\"user\""), quietLine)
check("as claude's terminal records them (measured, 2.1.312): the command line as typed, the output rows with &, < and > escaped — never quotes",
      ClaudeShellCommand.inputRow("echo '<a> & \"b\"' >&2") == "<bash-input>echo '<a> & \"b\"' >&2</bash-input>"
      && ClaudeShellCommand.outputRow(stdout: "<a> \"q\"", stderr: "x & y")
         == "<bash-stdout>&lt;a&gt; \"q\"</bash-stdout><bash-stderr>x &amp; y</bash-stderr>")
// The terminal's record of a result (measured on its own terminal, 2.1.312):
// all printed as one stream, in the output row when it succeeds (trailing
// blank space cut) and in the error row when it fails, no exit code.
let succeeded = ClaudeShellCommand.terminalOutput(merged: "out\nerr\n", exitCode: 0, folderResetTo: nil)
check("a command that succeeds: all it printed in the output row, trailing blank space cut",
      succeeded == ShellCommandOutput(stdout: "out\nerr", stderr: "", exitCode: nil) && !succeeded.failed)
let failedRecord = ClaudeShellCommand.terminalOutput(merged: "out\nerr\n", exitCode: 3, folderResetTo: nil)
check("a command that fails: all of it in the error row, the output row empty, read as failed, no exit code",
      failedRecord.stdout == "" && failedRecord.stderr == "out\nerr\n" && failedRecord.failed
        && failedRecord.exitCode == nil)
let resetRecord = ClaudeShellCommand.terminalOutput(merged: "", exitCode: 0, folderResetTo: "/w")
check("a command that left the session's folder: the terminal's note in the error row",
      resetRecord.stdout == "" && resetRecord.stderr == "\nShell cwd was reset to /w" && !resetRecord.failed
        && resetRecord.text == "Shell cwd was reset to /w")
check("a failed command's long output: its head and claude's words for the lines left out",
      ClaudeShellCommand.errorText("a\nb\nc\nd", cap: 3) == "a\nb\n\n... [3 lines truncated] ..."
        && ClaudeShellCommand.errorText("short", cap: 30) == "short")
check("reading the terminal's record: its no-output words are no output, an empty output row is a failure",
      ClaudeShellCommand.recordOutput(fromRow: "<bash-stdout>(Bash completed with no output)</bash-stdout><bash-stderr></bash-stderr>")
        .map { $0.text == "" && !$0.failed } == true
      && ClaudeShellCommand.recordOutput(fromRow: "<bash-stdout></bash-stdout><bash-stderr>boom\n</bash-stderr>")
        .map { $0.failed && $0.text == "boom" } == true
      && ClaudeShellCommand.recordOutput(fromRow: "<bash-stdout></bash-stdout><bash-stderr></bash-stderr>")?.failed == true
      && ClaudeShellCommand.recordOutput(fromRow: "<bash-stdout>HI</bash-stdout><bash-stderr></bash-stderr>")?.failed == false)

// How claude's terminal runs the command (read in its code, measured
// against its terminal): the shell, the startup file, the input.
let executables: Set<String> = ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/bash", "/usr/local/bin/fish"]
func pick(_ environment: [String: String]) -> String? {
    ClaudeTerminalShell.shell(environment: environment, isExecutable: executables.contains)
}
check("the shell: CLAUDE_CODE_SHELL, then SHELL, when it names bash or zsh and runs; else zsh, bash first under a bash SHELL",
      pick(["SHELL": "/bin/zsh"]) == "/bin/zsh"
      && pick(["SHELL": "/bin/zsh", "CLAUDE_CODE_SHELL": "/opt/homebrew/bin/bash"]) == "/opt/homebrew/bin/bash"
      && pick(["SHELL": "/usr/local/bin/fish"]) == "/bin/zsh"
      && pick(["SHELL": "/usr/local/bin/fish", "PATH": "/opt/homebrew/bin:/usr/bin"]) == "/bin/zsh"
      && pick(["SHELL": "/no/such/bash"]) == "/bin/bash"
      && pick(["CLAUDE_CODE_SHELL": "/no/such/zsh", "SHELL": "/bin/bash"]) == "/bin/bash"
      && ClaudeTerminalShell.shell(environment: [:], isExecutable: { _ in false }) == nil)
check("the startup file: ~/.zshrc, ~/.bashrc, else ~/.profile",
      ClaudeTerminalShell.startupFile(shell: "/bin/zsh", home: "/h") == "/h/.zshrc"
      && ClaudeTerminalShell.startupFile(shell: "/bin/bash", home: "/h") == "/h/.bashrc"
      && ClaudeTerminalShell.startupFile(shell: "/bin/sh", home: "/h") == "/h/.profile")
check("input from /dev/null unless the command brings its own: a here-document or a `<` from a file",
      ClaudeTerminalShell.keepsInput("cat <<EOF\nhi\nEOF") && ClaudeTerminalShell.keepsInput("cat <<'EOF'\nhi\nEOF")
      && ClaudeTerminalShell.keepsInput("cat <<-END\n\thi\nEND") && ClaudeTerminalShell.keepsInput("wc -l < notes.txt")
      && !ClaudeTerminalShell.keepsInput("read x; echo $x") && !ClaudeTerminalShell.keepsInput("echo $((1 << 2))")
      && !ClaudeTerminalShell.keepsInput("diff <(ls a) <(ls b)") && !ClaudeTerminalShell.keepsInput("ls -la"))
let terminalLine = ClaudeTerminalShell.commandLine("ls 'my dir' && echo it's", shell: "/bin/zsh",
                                                   home: "/Users/example-user", folderFile: "/tmp/f")
check("the terminal's command line: a login shell, the startup file first, claude's PATH, eval with no input, the folder written back",
      terminalLine.hasPrefix("SIPAI_CLAUDE_PATH=\"$PATH\" exec '/bin/zsh' -c -l '")
      && terminalLine.contains("source '\"'\"'/Users/example-user/.zshrc'\"'\"' < /dev/null")
      && terminalLine.contains("setopt NO_EXTENDED_GLOB NO_BARE_GLOB_QUAL")
      && terminalLine.contains("exec 2>&1") && terminalLine.contains(" < /dev/null && pwd -P >| ")
      && !terminalLine.contains("\n"), terminalLine)
check("…bash expands aliases and turns extglob off; a here-document keeps its input",
      ClaudeTerminalShell.commandLine("ls", shell: "/bin/bash", home: "/h", folderFile: "/f").contains("shopt -s expand_aliases")
      && ClaudeTerminalShell.commandLine("ls", shell: "/bin/bash", home: "/h", folderFile: "/f").contains("shopt -u extglob")
      && !ClaudeTerminalShell.commandLine("cat <<EOF\nx\nEOF", shell: "/bin/zsh", home: "/h", folderFile: "/f")
            .contains("EOF'\"'\"' < /dev/null"))
check("the next folder: kept inside the session's folder, back at it otherwise with the terminal's note, unchanged after a failure",
      ClaudeTerminalShell.nextFolder(reported: "/w/sub", current: nil, sessionFolder: "/w", maintainsSessionFolder: false) == ("/w/sub", false)
      && ClaudeTerminalShell.nextFolder(reported: "/w", current: "/w/sub", sessionFolder: "/w", maintainsSessionFolder: false) == (nil, false)
      && ClaudeTerminalShell.nextFolder(reported: "/tmp", current: "/w/sub", sessionFolder: "/w", maintainsSessionFolder: false) == (nil, true)
      && ClaudeTerminalShell.nextFolder(reported: "/wx", current: nil, sessionFolder: "/w", maintainsSessionFolder: false) == (nil, true)
      && ClaudeTerminalShell.nextFolder(reported: nil, current: "/w/sub", sessionFolder: "/w", maintainsSessionFolder: false) == ("/w/sub", false)
      && ClaudeTerminalShell.nextFolder(reported: "/w/sub", current: nil, sessionFolder: "/w", maintainsSessionFolder: true) == (nil, false))
check("claude's environment: its settings' env blocks, a later file winning; a switch is on as claude reads one",
      ClaudeTerminalShell.settingsEnvironment([settings(["env": ["SHELL": "/bin/bash", "X": true]]),
                                               settings(["env": ["SHELL": "/bin/zsh"]])]) == ["SHELL": "/bin/zsh", "X": "true"]
      && ClaudeTerminalShell.isOn("1") && ClaudeTerminalShell.isOn(" TRUE ") && ClaudeTerminalShell.isOn("on")
      && !ClaudeTerminalShell.isOn("0") && !ClaudeTerminalShell.isOn(nil) && !ClaudeTerminalShell.isOn("enabled"))

// Rows as claude printed them back (measured on 2.1.312).
let measuredOut = ClaudeShellCommand.output(fromRow:
    "<bash-stdout>&lt;a&gt; &amp; \"b\"</bash-stdout><bash-stderr>err &lt;x&gt;</bash-stderr><bash-exit-code>0</bash-exit-code>")
check("an output row claude printed back reads as the command printed it",
      measuredOut?.stdout == "<a> & \"b\"" && measuredOut?.stderr == "err <x>" && measuredOut?.exitCode == 0,
      "\(String(describing: measuredOut))")
let failedOut = ClaudeShellCommand.output(fromRow:
    "<bash-stdout></bash-stdout><bash-stderr>ls: /no/such/path: No such file or directory</bash-stderr><bash-exit-code>1</bash-exit-code>")
check("a failing command keeps its error and its exit code, and reads as failed",
      failedOut?.failed == true && failedOut?.exitCode == 1 && failedOut?.stderr.hasPrefix("ls:") == true)
let stoppedOut = ClaudeShellCommand.output(fromRow:
    "<bash-stdout></bash-stdout><bash-stderr>[interrupted]</bash-stderr><bash-exit-code>130</bash-exit-code>")
check("a command stopped mid-run reads as stopped, not as failed",
      stoppedOut?.interrupted == true && stoppedOut?.failed == false && stoppedOut?.stderr == "")
check("the terminal's own row has no exit code, and still reads",
      ClaudeShellCommand.output(fromRow: "<bash-stdout>HI</bash-stdout><bash-stderr></bash-stderr>")?.stdout == "HI")
check("a record holding a ! command reads in both shapes: a row per record, or the rows as one record's blocks",
      ClaudeShellCommand.rows(fromContent: "<bash-input>ls</bash-input>") == [.command("ls")]
      && ClaudeShellCommand.rows(fromContent: [["type": "text", "text": ClaudeShellCommand.quietNote],
                                                ["type": "text", "text": "<bash-input>ls</bash-input>"],
                                                ["type": "text", "text": "<bash-stdout>a</bash-stdout><bash-stderr></bash-stderr>"]])
         == [.command("ls"), .output(ShellCommandOutput(stdout: "a", stderr: "", exitCode: nil))]
      && ClaudeShellCommand.rows(fromContent: [["type": "text", "text": "<bash-input>ls</bash-input>"],
                                                ["type": "text", "text": "and a question"]]) == nil
      && ClaudeShellCommand.rows(fromContent: "hello") == nil)
check("an input row reads back as its command: claude's as typed, kimi's escaped (&, <, > and \") with newlines around it",
      ClaudeShellCommand.command(fromRow: "<bash-input>echo 'a <b> & c' >&2</bash-input>") == "echo 'a <b> & c' >&2"
      && ClaudeShellCommand.command(fromRow: "<bash-input>\necho &quot;&lt;a&gt;&quot; &amp;&amp; x\n</bash-input>",
                                    unescaping: true) == "echo \"<a>\" && x"
      && ClaudeShellCommand.command(fromRow: "hello") == nil)

func settings(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}
check("claude's output cap: 30,000 by default, its own setting clamped to 4,000–128,000, a later file winning",
      ClaudeShellCommand.outputCap(settings: []) == 30_000
      && ClaudeShellCommand.outputCap(settings: [settings(["bashOutputMaxChars": 1_000])]) == 4_000
      && ClaudeShellCommand.outputCap(settings: [settings(["bashOutputMaxChars": 500_000])]) == 128_000
      && ClaudeShellCommand.outputCap(settings: [settings(["bashOutputMaxChars": 50_000]),
                                                 settings(["bashOutputMaxChars": 8_000])]) == 8_000)
check("claude answers a ! command unless respondToBashCommands is false, a later file winning",
      ClaudeShellCommand.responds(settings: [])
      && !ClaudeShellCommand.responds(settings: [settings(["respondToBashCommands": false])])
      && ClaudeShellCommand.responds(settings: [settings(["respondToBashCommands": false]),
                                                settings(["respondToBashCommands": true])]))
check("sizes in claude's words", ClaudeShellCommand.sizeText(38_894) == "38KB"
      && ClaudeShellCommand.sizeText(2_000) == "2KB" && ClaudeShellCommand.sizeText(500) == "500 bytes",
      ClaudeShellCommand.sizeText(38_894))
// `seq 1 8000`, whose long-output form claude was measured to write.
let seq = (1...8000).map(String.init).joined(separator: "\n") + "\n"
let persisted = ClaudeShellCommand.modelStdout(seq, cap: 30_000, savedPath: "/S/tool-results/abc.txt")
check("past the cap, claude's own long-output form, as measured: the size, the path, a 2 KB preview of whole lines",
      persisted.hasPrefix("<persisted-output>\nOutput too large (38KB). Full output saved to: /S/tool-results/abc.txt\n\nPreview (first 2KB):\n1\n2\n")
      && persisted.hasSuffix("\n526\n527\n...\n</persisted-output>"),
      String(persisted.prefix(160)) + " … " + String(persisted.suffix(60)))
check("…handed over as it is, never escaped",
      ClaudeShellCommand.outputRow(stdout: persisted, stderr: "").hasPrefix("<bash-stdout><persisted-output>"))
let truncated = ClaudeShellCommand.modelStdout(seq, cap: 30_000, savedPath: nil)
check("with no file to point at, claude's own form for output it could not save: the head alone",
      truncated.hasPrefix("<truncated-output>\nOutput too large (38KB). It could not be saved, so only the first ")
      && truncated.hasSuffix("\n</truncated-output>"))
check("output within the cap goes whole", ClaudeShellCommand.modelStdout("short", cap: 30_000, savedPath: nil) == "short")
// What the transcript draws of an output: its start, bounded.
let shortOut = ShellCommandOutput(stdout: "a\nb\n", stderr: "warn\n", exitCode: 0)
check("a short output is drawn whole: its output, then its error stream",
      shortOut.shown.text == shortOut.text && shortOut.shown.text == "a\nb\nwarn" && !shortOut.shown.cut)
let longOut = ShellCommandOutput(stdout: seq, stderr: "", exitCode: 0).shown
check("a long output is drawn as its first \(ShellCommandOutput.displayLineCap) lines, and says it was cut",
      longOut.cut && longOut.text.split(separator: "\n").count == ShellCommandOutput.displayLineCap
        && longOut.text.hasSuffix("\n200") && longOut.text.hasPrefix("1\n2\n"),
      "\(longOut.text.split(separator: "\n").count) lines, ends \(longOut.text.suffix(8))")
let wideOut = ShellCommandOutput(stdout: String(repeating: "x", count: 5_000_000), stderr: "", exitCode: 0).shown
check("…and one long line as its first \(ShellCommandOutput.displayCharacterCap) characters",
      wideOut.cut && wideOut.text.count == ShellCommandOutput.displayCharacterCap)
let bothOut = ShellCommandOutput(stdout: (1...199).map(String.init).joined(separator: "\n"),
                                 stderr: "e1\ne2", exitCode: 1).shown
check("…counting the error stream's lines with the output's",
      bothOut.cut && bothOut.text.hasSuffix("\n199\ne1"), String(bothOut.text.suffix(12)))
let rereadPersisted = ClaudeShellCommand.output(fromRow: ClaudeShellCommand.outputRow(stdout: persisted, stderr: ""))
let rereadTruncated = ClaudeShellCommand.output(fromRow: ClaudeShellCommand.outputRow(stdout: truncated, stderr: ""))
check("reopened, a long output's row reads as claude's words inside its form — the size, the file, the preview — never the form's tags",
      rereadPersisted?.text.hasPrefix("Output too large (38KB). Full output saved to: /S/tool-results/abc.txt") == true
        && rereadPersisted?.text.hasSuffix("\n527\n...") == true
        && rereadTruncated?.text.hasPrefix("Output too large (38KB). It could not be saved") == true
        && rereadTruncated?.text.contains("truncated-output") == false,
      "\(String(describing: rereadPersisted?.text.prefix(80))) / \(String(describing: rereadTruncated?.text.suffix(40)))")

// Codex's record, in the shape codex 0.165.0 wrote it (measured).
let codexRecord = """
<user_shell_command>
<command>
echo HELLO_BANG; touch /tmp/x
</command>
<result>
Exit code: 0
Duration: 0.0268 seconds
Output:
HELLO_BANG

</result>
</user_shell_command>
"""
let codexRead = CodexShellCommand.record(fromText: codexRecord)
check("codex's record of a ! command reads as its command and its output",
      codexRead?.command == "echo HELLO_BANG; touch /tmp/x" && codexRead?.output.stdout == "HELLO_BANG"
      && codexRead?.output.exitCode == 0, "\(String(describing: codexRead))")
let codexAborted = CodexShellCommand.record(fromText: """
<user_shell_command>
<command>
sleep 30
</command>
<result>
Exit code: -1
Duration: 0.0001 seconds
Output:
command aborted by user
</result>
</user_shell_command>
""")
check("…and one stopped with turn/interrupt reads as stopped", codexAborted?.output.interrupted == true)
check("codex's live item of the user's own shell command is told apart from the model's",
      CodexShellCommand.isUserShell(["type": "commandExecution", "source": "userShell"])
      && !CodexShellCommand.isUserShell(["type": "commandExecution", "source": "agent"]))
let codexItem = CodexShellCommand.output(fromItem: ["type": "commandExecution", "aggregatedOutput": "HI\n",
                                                    "exitCode": 3, "status": "failed"], stopped: false)
check("…and its completed item reads as its output and exit code", codexItem.stdout == "HI\n" && codexItem.failed)

// Kimi's records, in the shape kimi 2.4.0 wrote them (measured).
check("kimi's record of a ! command's input and output",
      KimiShellCommand.row(origin: ["kind": "shell_command", "phase": "input"],
                           text: "<bash-input>\necho HI\n</bash-input>") == .command("echo HI")
      && {
          if case .output(let o)? = KimiShellCommand.row(origin: ["kind": "shell_command", "phase": "output", "isError": true],
                                                          text: "<bash-stdout></bash-stdout><bash-stderr>boom</bash-stderr>") {
              return o.failed && o.stderr == "boom"
          }
          return false
      }()
      && KimiShellCommand.row(origin: ["kind": "user"], text: "<bash-input>x</bash-input>") == nil)

// What Send does with a `!` line, by what the app has read of the tool.
func verdict(_ agent: String, claude: String? = nil, listed: Bool? = nil, codex: String? = nil) -> ShellCommandVerdict? {
    ShellCommandSupport.verdict(agentKey: agent, claudeVersion: claude, claudeReplayListed: listed, codexVersion: codex)
}
check("claude runs one where its input can be held open; unread, it waits; older, it waits for an update",
      verdict("claude_code", claude: "2.1.312", listed: true) == .runs
        && verdict("claude_code", claude: ClaudeSteer.floor, listed: true) == .runs
        && verdict("claude_code") == .pending
        && verdict("claude_code", claude: "2.1.312") == .pending
        && verdict("claude_code", listed: true) == .pending
        && verdict("claude_code", claude: "2.1.309", listed: true) == .needsNewer
        && verdict("claude_code", claude: "2.1.312", listed: false) == .needsNewer)
check("codex runs one from the oldest codex measured; unread, it waits; older, it waits for an update",
      verdict("codex", codex: "0.165.0") == .runs && verdict("codex", codex: "0.170.2") == .runs
        && verdict("codex") == .pending
        && verdict("codex", codex: "0.164.0") == .needsNewer && verdict("codex", codex: "0.159.3") == .needsNewer)
check("kimi offers apps no route: sent as a message; an agent nobody measured: no claim at all",
      verdict("kimi") == .noRoute && verdict("someday") == nil)

// MARK: - 2. The readers

print("\n2. The readers")

func writeLines(_ objects: [[String: Any]], to url: URL) {
    let text = objects.compactMap {
        (try? JSONSerialization.data(withJSONObject: $0)).map { String(decoding: $0, as: UTF8.self) }
    }.joined(separator: "\n") + "\n"
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

func describe(_ items: [AgentSessionHistoryItem]) -> [String] {
    items.map { item in
        switch item.kind {
        case .userText(let t): return (item.shellCommand ? "shell:" : (item.isSystemNotice ? "notice:" : "user:")) + t
        case .assistantText(let t): return "assistant:" + t
        case .shellOutput(let o): return "output:" + o.text + (o.failed ? " (failed)" : "")
        case .toolUse(_, let name, _): return "tool:" + name
        case .toolResult: return "result"
        case .error(let m): return "error:" + m
        case .interrupted: return "interrupted"
        case .compaction: return "compaction"
        case .thinking: return "thinking"
        }
    }
}

// Claude: a ! claude answered, then one it did not (the hidden note, the
// rows, and claude's own "No response requested.").
let claudeFile = scratch.appendingPathComponent("claude.jsonl")
var parent: String? = nil
var claudeRecords: [[String: Any]] = []
func claudeRecord(_ type: String, _ content: Any, model: String? = nil) {
    let uuid = UUID().uuidString.lowercased()
    var message: [String: Any] = ["role": type == "user" ? "user" : "assistant", "content": content]
    if let model { message["model"] = model }
    claudeRecords.append(["type": type, "uuid": uuid, "parentUuid": parent ?? NSNull(),
                          "sessionId": "s", "cwd": "/tmp", "timestamp": "2026-10-29T10:00:00Z",
                          "message": message])
    parent = uuid
}
claudeRecord("user", "hello")
claudeRecord("assistant", [["type": "text", "text": "hi"]], model: "claude-x")
// In the shape claude's terminal writes them (measured, 2.1.312): the
// command line as typed, the output escaped, a failure in the error row,
// a silent success in claude's own words.
claudeRecord("user", "<bash-input>ls & echo</bash-input>")
claudeRecord("user", "<bash-stdout>a &lt;b&gt;</bash-stdout><bash-stderr></bash-stderr>")
claudeRecord("assistant", [["type": "text", "text": "Got it"]], model: "claude-x")
claudeRecord("user", ClaudeShellCommand.quietNote)
claudeRecord("user", "<bash-input>pwd</bash-input>")
claudeRecord("user", "<bash-stdout>/tmp</bash-stdout><bash-stderr></bash-stderr>")
claudeRecord("assistant", [["type": "text", "text": "No response requested."]], model: "<synthetic>")
claudeRecord("user", ClaudeShellCommand.quietNote)
claudeRecord("user", "<bash-input>ls /nope</bash-input>")
claudeRecord("user", "<bash-stdout></bash-stdout><bash-stderr>ls: /nope: No such file or directory\n</bash-stderr>")
claudeRecord("assistant", [["type": "text", "text": "No response requested."]], model: "<synthetic>")
claudeRecord("user", ClaudeShellCommand.quietNote)
claudeRecord("user", "<bash-input>cd sub</bash-input>")
claudeRecord("user", "<bash-stdout>(Bash completed with no output)</bash-stdout><bash-stderr></bash-stderr>")
claudeRecord("assistant", [["type": "text", "text": "No response requested."]], model: "<synthetic>")
// SipAI's shape: one record, the rows as its blocks.
claudeRecord("user", [["type": "text", "text": "<bash-input>whoami</bash-input>"],
                      ["type": "text", "text": "<bash-stdout>me</bash-stdout><bash-stderr></bash-stderr>"]])
claudeRecord("assistant", [["type": "text", "text": "You are me."]], model: "claude-x")
writeLines(claudeRecords, to: claudeFile)
let claudeRows = describe(AgentSessionScanner.readHistory(of: claudeFile))
check("claude's reader: a ! command is its row and its output, the answer after them",
      claudeRows == ["user:hello", "assistant:hi", "shell:!ls & echo", "output:a <b>", "assistant:Got it",
                     "shell:!pwd", "output:/tmp",
                     "shell:!ls /nope", "output:ls: /nope: No such file or directory (failed)",
                     "shell:!cd sub", "output:",
                     "shell:!whoami", "output:me", "assistant:You are me."],
      "\(claudeRows)")
// The live parser, for a ! run in claude's own terminal while SipAI watches.
let liveRows = claudeRecords.compactMap { record -> String? in
    guard let data = try? JSONSerialization.data(withJSONObject: record) else { return nil }
    let events = AgentEventParser.parse(line: String(decoding: data, as: UTF8.self),
                                        fallbackCwd: URL(fileURLWithPath: "/tmp"), includeUserMessages: true)
    let rows = events.compactMap { event -> String? in
        switch event.kind {
        case .userMessage(let t) where event.shellCommand: return "shell:" + t
        case .shellOutput(let o): return "output:" + o.text
        default: return nil
        }
    }
    return rows.isEmpty ? nil : rows.joined(separator: " | ")
}
check("…and the live feed reads them the same way",
      liveRows == ["shell:!ls & echo", "output:a <b>", "shell:!pwd", "output:/tmp",
                   "shell:!ls /nope", "output:ls: /nope: No such file or directory",
                   "shell:!cd sub", "output:",
                   "shell:!whoami | output:me"], "\(liveRows)")

check("a session is titled by its first ! command, never by what it printed — and the output alone starts no turn",
      AgentSessionScanner.cleanSessionMetaText(
          "<bash-input>ls</bash-input>\n<bash-stdout>secret.txt</bash-stdout><bash-stderr>warn</bash-stderr>") == "ls"
      && AgentSessionScanner.cleanSessionMetaText("<bash-stdout>out</bash-stdout><bash-stderr></bash-stderr>") == "")

// Codex: one ! command, as codex 0.165.0 recorded it.
let codexFile = scratch.appendingPathComponent("rollout-2026-10-29T10-00-00-00000000-0000-0000-0000-000000000001.jsonl")
writeLines([
    ["timestamp": "2026-10-29T10:00:00Z", "type": "session_meta",
     "payload": ["id": "00000000-0000-0000-0000-000000000001", "cwd": "/tmp", "originator": "sipai"]],
    ["timestamp": "2026-10-29T10:00:00Z", "type": "event_msg", "payload": ["type": "task_started", "turn_id": "t1"]],
    ["timestamp": "2026-10-29T10:00:00Z", "type": "event_msg",
     "payload": ["type": "item_completed", "turn_id": "t1",
                 "item": ["type": "CommandExecution", "source": "user_shell", "aggregated_output": "HELLO_BANG\n",
                          "exit_code": 0]]],
    ["timestamp": "2026-10-29T10:00:00Z", "type": "response_item",
     "payload": ["type": "message", "role": "user",
                 "content": [["type": "input_text", "text": codexRecord]]]],
    ["timestamp": "2026-10-29T10:00:00Z", "type": "event_msg", "payload": ["type": "task_complete", "turn_id": "t1"]],
], to: codexFile)
let codexRows = describe(CodexSessionScanner.readHistory(of: codexFile))
check("codex's reader: a ! command is its row and its output, its record never drawn as text",
      codexRows == ["shell:!echo HELLO_BANG; touch /tmp/x", "output:HELLO_BANG"], "\(codexRows)")

// Kimi: one ! command from kimi's terminal, failing.
let kimiFile = scratch.appendingPathComponent("wire.jsonl")
writeLines([
    ["type": "context.append_message", "agentId": "main",
     "message": ["role": "user", "content": [["type": "text", "text": "<bash-input>\nfalse\n</bash-input>"]],
                 "toolCalls": [], "origin": ["kind": "shell_command", "phase": "input"]]],
    ["type": "context.append_message", "agentId": "main",
     "message": ["role": "user",
                 "content": [["type": "text", "text": "<bash-stdout></bash-stdout><bash-stderr>nope</bash-stderr>"]],
                 "toolCalls": [], "origin": ["kind": "shell_command", "phase": "output", "isError": true]]],
], to: kimiFile)
let kimiRows = describe(KimiSessionScanner.readHistory(of: kimiFile))
check("kimi's reader: a ! command from its terminal is its row and its output, failed as kimi says",
      kimiRows == ["shell:!false", "output:nope (failed)"], "\(kimiRows)")

// Titles: a session a ! command opened is named as its row reads, for all
// three — never by what the command printed — and what it printed is not
// the user's latest act.
func claudeTitle(_ first: Any) -> String {
    let file = scratch.appendingPathComponent("title-\(UUID().uuidString).jsonl")
    parent = nil
    claudeRecords = []
    claudeRecord("user", first)
    claudeRecord("assistant", [["type": "text", "text": "Listed."]], model: "claude-x")
    writeLines(claudeRecords, to: file)
    return AgentSessionScanner.inspectSession(from: file, decodedProjectPath: nil).title
}
let titledTerminal = claudeTitle("<bash-input>ls -la</bash-input>")
let titledSipAI = claudeTitle([["type": "text", "text": ClaudeShellCommand.quietNote],
                               ["type": "text", "text": "<bash-input>whoami</bash-input>"],
                               ["type": "text", "text": "<bash-stdout>secret</bash-stdout><bash-stderr></bash-stderr>"]])
check("claude: a session a ! command opened is named \"!command\", in the terminal's shape and in SipAI's",
      titledTerminal == "!ls -la" && titledSipAI == "!whoami", "\(titledTerminal) / \(titledSipAI)")
let codexDay = CodexSessionScanner.sessionRoot.appendingPathComponent("2026/10/29")
try? FileManager.default.createDirectory(at: codexDay, withIntermediateDirectories: true)
let codexTitleId = "00000000-0000-4000-8000-0000000000aa"
writeLines([
    ["timestamp": "2026-10-29T10:00:00Z", "type": "session_meta",
     "payload": ["id": codexTitleId, "cwd": "/Users/Shared", "originator": "codex_cli_rs"]],
    ["timestamp": "2026-10-29T10:00:00Z", "type": "response_item",
     "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": codexRecord]]]],
], to: codexDay.appendingPathComponent("rollout-2026-10-29T10-00-00-\(codexTitleId).jsonl"))
let codexTitle = CodexSessionScanner.sessionRoot.path.hasPrefix(fakeHome.path)
    ? CodexSessionScanner.scan().first { $0.id == codexTitleId }?.title : "(not the throwaway store)"
check("codex: a session a ! command opened is named \"!command\"",
      codexTitle == "!echo HELLO_BANG; touch /tmp/x", "\(String(describing: codexTitle))")
let kimiHome = scratch.appendingPathComponent("kimi-home")
let kimiSession = kimiHome.appendingPathComponent("sessions/wd_project_000000000000/session_title_probe")
try? FileManager.default.createDirectory(at: kimiSession.appendingPathComponent("agents/main"),
                                         withIntermediateDirectories: true)
try? JSONSerialization.data(withJSONObject: ["id": "session_title_probe", "cwd": "/Users/Shared"])
    .write(to: kimiSession.appendingPathComponent("state.json"))
let kimiWire = kimiSession.appendingPathComponent("agents/main/wire.jsonl")
writeLines([
    ["type": "context.append_message", "agentId": "main", "time": "2026-10-29T10:00:00Z",
     "message": ["role": "user", "content": [["type": "text", "text": "<bash-input>\nls -la\n</bash-input>"]],
                 "toolCalls": [], "origin": ["kind": "shell_command", "phase": "input"]]],
    ["type": "context.append_message", "agentId": "main", "time": "2026-10-29T11:00:00Z",
     "message": ["role": "user",
                 "content": [["type": "text", "text": "<bash-stdout>secret.txt</bash-stdout><bash-stderr></bash-stderr>"]],
                 "toolCalls": [], "origin": ["kind": "shell_command", "phase": "output"]]],
], to: kimiWire)
setenv("KIMI_CODE_HOME", kimiHome.path, 1)
let kimiTitle = KimiSessionScanner.scan().first { $0.id == "session_title_probe" }?.title
unsetenv("KIMI_CODE_HOME")
check("kimi: a session its terminal opened with a ! command is named \"!command\"",
      kimiTitle == "!ls -la", "\(String(describing: kimiTitle))")
let kimiLatest = KimiSessionScanner.lastUserMessageDate(of: kimiWire)
check("kimi: the session's time is the command's, not its output's",
      kimiLatest == ISO8601DateFormatter().date(from: "2026-10-29T10:00:00Z"), "\(String(describing: kimiLatest))")

// MARK: - Shared: the stand-in and line readers

/// A child's stdout, a line at a time.
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var all: [String] = []
    func feed(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            all.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
    }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return all }
}

func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return condition()
}

func which(_ name: String) -> String? {
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let path = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return nil
}

func startStandIn(records: URL) -> (Process, Int)? {
    guard !standIn.isEmpty, FileManager.default.fileExists(atPath: standIn) else { return nil }
    try? FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", "-I", standIn, records.path, "--port", "0"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    let lines = Lines()
    out.fileHandleForReading.readabilityHandler = { lines.feed($0.availableData) }
    guard (try? p.run()) != nil else { return nil }
    guard waitFor(10, { lines.snapshot.contains { $0.hasPrefix("PORT=") } }),
          let port = lines.snapshot.first(where: { $0.hasPrefix("PORT=") }).flatMap({ Int($0.dropFirst(5)) })
    else { p.terminate(); return nil }
    return (p, port)
}

/// A folder as a process inside it reports it: every link resolved,
/// `/private` included (realpath(3); Foundation's resolving drops `/private`).
func physicalPath(_ url: URL) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    return realpath(url.path, &buffer).map { String(cString: $0) } ?? url.path
}

func requestCount(_ records: URL) -> Int {
    ((try? FileManager.default.contentsOfDirectory(atPath: records.path)) ?? []).filter { $0.hasSuffix(".json") }.count
}
func requestText(_ records: URL) -> String {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: records.path)) ?? []).sorted()
    return names.compactMap { try? String(contentsOf: records.appendingPathComponent($0), encoding: .utf8) }
        .joined(separator: "\n")
}

// MARK: - 3. The real claude

print("\n3. The real claude, through the stand-in endpoint (token-free)")

/// One claude process on its stream-json input, as SipAI starts one for a
/// `!` command.
final class Claude {
    let process = Process()
    let input = Pipe()
    let lines = Lines()
    init?(binary: String, home: URL, port: Int, work: URL, resume: String?, extra: [String] = []) {
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                             "--verbose", "--replay-user-messages", "--model", "haiku"]
            + extra
            + (resume.map { ["--resume", $0] } ?? [])
        process.currentDirectoryURL = work
        process.environment = ["HOME": home.path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "",
                               "CLAUDE_CONFIG_DIR": home.appendingPathComponent("cfg").path,
                               "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)",
                               "ANTHROPIC_API_KEY": "sk-ant-harness-junk",
                               "CLAUDE_CODE_MAX_RETRIES": "0",
                               "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"]
        process.standardInput = input
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let lines = self.lines
        out.fileHandleForReading.readabilityHandler = { lines.feed($0.availableData) }
        guard (try? process.run()) != nil else { return nil }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
    func write(_ line: String) { try? input.fileHandleForWriting.write(contentsOf: Data(line.utf8)) }
    func finish() {
        try? input.fileHandleForWriting.close()
        if !waitFor(30, { !self.process.isRunning }) { process.terminate() }
    }
    /// The output row claude printed back for the `!` command, read by the
    /// rules SipAI reads it with.
    var output: ShellCommandOutput? {
        for line in lines.snapshot {
            if let text = ClaudeShellCommand.userRowText(line: line),
               let output = ClaudeShellCommand.output(fromRow: text) { return output }
        }
        return nil
    }
    /// Every output row claude printed back, in order.
    var outputs: [ShellCommandOutput] {
        lines.snapshot.compactMap { line in
            ClaudeShellCommand.userRowText(line: line).flatMap(ClaudeShellCommand.output(fromRow:))
        }
    }
    func results() -> [Int] {
        lines.snapshot.compactMap { line in
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["type"] as? String == "result" else { return nil }
            return (obj["num_turns"] as? NSNumber)?.intValue
        }
    }
    var sessionId: String? {
        for line in lines.snapshot {
            if let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
               obj["type"] as? String == "system", let id = obj["session_id"] as? String, !id.isEmpty { return id }
        }
        return nil
    }
}

func transcript(_ home: URL, _ sessionId: String) -> URL? {
    let root = home.appendingPathComponent("cfg/projects")
    guard let found = FileManager.default.enumerator(atPath: root.path)?
        .compactMap({ $0 as? String }).first(where: { $0.hasSuffix("\(sessionId).jsonl") }) else { return nil }
    return root.appendingPathComponent(found)
}

if let claude = which("claude") {
    let home = scratch.appendingPathComponent("claude-home")
    let work = scratch.appendingPathComponent("claude-work")
    let records = scratch.appendingPathComponent("claude-requests")
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: home.appendingPathComponent("cfg"), withIntermediateDirectories: true)
    if let (server, port) = startStandIn(records: records) {
        defer { server.terminate() }
        let marker = work.appendingPathComponent("ran")
        let command = "echo 'HELLO <SHELL> & co'; printf x > \(marker.path)"

        // A ! claude answers: the terminal's default.
        if let c = Claude(binary: claude, home: home, port: port, work: work, resume: nil) {
            c.write(ClaudeShellCommand.bashCommandLine(command))
            let printed = waitFor(20) { c.output != nil }
            check("claude runs the command through its own message, with no model request",
                  printed && FileManager.default.fileExists(atPath: marker.path) && requestCount(records) == 0,
                  "printed: \(printed), requests: \(requestCount(records))")
            let output = c.output
            check("…and prints back the row SipAI reads, the command's output whole",
                  output?.stdout.contains("HELLO <SHELL> & co") == true && output?.exitCode == 0,
                  "\(String(describing: output))")
            if let output {
                c.write(ClaudeShellCommand.rowsLine([
                    ClaudeShellCommand.inputRow(command),
                    ClaudeShellCommand.outputRow(stdout: ClaudeShellCommand.modelStdout(output.stdout, cap: 30_000, savedPath: nil),
                                                 stderr: output.stderr)], query: true))
            }
            let answered = waitFor(30) { c.results().contains { $0 >= 1 } }
            check("handed the terminal's rows, claude answers once, the command's output in the request",
                  answered && requestCount(records) == 1 && c.results().count == 1
                  && requestText(records).contains("HELLO &lt;SHELL&gt; &amp; co"),
                  "results \(c.results()), requests \(requestCount(records))")
            c.finish()
            if let sid = c.sessionId, let file = transcript(home, sid) {
                let rows = describe(AgentSessionScanner.readHistory(of: file))
                check("reopened, the session reads as the command, its output and the answer",
                      rows.first == "shell:!" + command && rows.dropFirst().first == "output:HELLO <SHELL> & co"
                      && rows.contains(where: { $0.hasPrefix("assistant:") }), "\(rows)")
            } else {
                check("claude saved the session", false)
            }
        } else {
            check("claude starts", false)
        }

        // A ! claude does not answer (respondToBashCommands false).
        let before = requestCount(records)
        if let c = Claude(binary: claude, home: home, port: port, work: work, resume: nil) {
            c.write(ClaudeShellCommand.bashCommandLine("echo QUIET_ONE"))
            _ = waitFor(20) { c.output != nil }
            let output = c.output ?? ShellCommandOutput(stdout: "", stderr: "", exitCode: nil)
            c.write(ClaudeShellCommand.rowsLine([
                ClaudeShellCommand.quietNote,
                ClaudeShellCommand.inputRow("echo QUIET_ONE"),
                ClaudeShellCommand.outputRow(stdout: output.stdout, stderr: output.stderr)], query: false))
            _ = waitFor(20) { !c.results().isEmpty }
            Thread.sleep(forTimeInterval: 1)
            check("not answered: no model request, one empty result for the message",
                  requestCount(records) == before && c.results() == [0],
                  "results \(c.results()), requests \(requestCount(records) - before)")
            c.finish()
            // What the runner draws off claude's output, parsed as the runner
            // parses it: the rows are SipAI's own (the command's row, the
            // output under it), so nothing of claude's may add to them.
            let live = c.lines.snapshot.flatMap { AgentEventParser.parse(line: $0, fallbackCwd: work) }
                .filter {
                    switch $0.kind {
                    case .assistantText, .userMessage, .shellOutput, .error: return true
                    default: return false
                    }
                }
            check("…and live, claude's output draws nothing beside SipAI's own rows — no \"No response requested.\"",
                  live.isEmpty, "\(live.map(\.kind))")
            if let sid = c.sessionId, let file = transcript(home, sid) {
                let rows = describe(AgentSessionScanner.readHistory(of: file))
                check("reopened: the command and its output, no hidden note, no \"No response requested.\"",
                      rows == ["shell:!echo QUIET_ONE", "output:QUIET_ONE"], "\(rows)")
                // The next message carries it to the model.
                if let next = Claude(binary: claude, home: home, port: port, work: work, resume: sid) {
                    next.write(ClaudeShellCommand.userLine("what did it print?", query: true))
                    _ = waitFor(30) { next.results().contains { $0 >= 1 } }
                    next.finish()
                    check("…and the next message's request carries the output",
                          requestCount(records) == before + 1 && requestText(records).contains("QUIET_ONE"))
                }
            } else {
                check("claude saved the quiet session", false)
            }
        }

        // Chat only: claude keeps only its web tools, and a ! command still
        // runs, as it would in claude's terminal — the command is the
        // user's, not a tool of the model's. Its answer stays Chat only.
        let chatOnlyArgs = ChatOnlyArgv.claudeToolsWebOnly + ChatOnlyArgv.claudeWebPreapproved
            + ChatOnlyArgv.claudeNoMCP + ChatOnlyArgv.claudePersona
        let beforeChatOnly = requestCount(records)
        if let c = Claude(binary: claude, home: home, port: port, work: work, resume: nil, extra: chatOnlyArgs) {
            c.write(ClaudeShellCommand.bashCommandLine("echo CHAT_ONLY_SHELL"))
            _ = waitFor(20) { c.output != nil }
            check("in Chat only, claude still runs a ! command, with no model request",
                  c.output?.stdout.contains("CHAT_ONLY_SHELL") == true && requestCount(records) == beforeChatOnly,
                  "\(String(describing: c.output)), requests \(requestCount(records) - beforeChatOnly)")
            if let output = c.output {
                c.write(ClaudeShellCommand.rowsLine([
                    ClaudeShellCommand.inputRow("echo CHAT_ONLY_SHELL"),
                    ClaudeShellCommand.outputRow(stdout: output.stdout, stderr: output.stderr)], query: true))
            }
            _ = waitFor(30) { c.results().contains { $0 >= 1 } }
            c.finish()
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: records.path)) ?? [])
                .filter { $0.hasSuffix(".json") }.sorted()
            let newest = names.last.flatMap { try? Data(contentsOf: records.appendingPathComponent($0)) }
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let body = newest?["body"] as? [String: Any]
            let tools = ((body?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            let bodyText = newest.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            check("…and its answer is a Chat only request: the output in it, no tool that touches files",
                  requestCount(records) == beforeChatOnly + 1 && bodyText.contains("CHAT_ONLY_SHELL")
                      && !tools.isEmpty && Set(tools).isSubset(of: Set(ChatOnlyArgv.claudeWebTools + ["DeferredToolPlaceholder"])),
                  "requests \(requestCount(records) - beforeChatOnly), tools \(tools)")
        } else {
            check("claude starts in Chat only", false)
        }

        // Claude's own message by itself runs a plain /bin/sh: no startup
        // file, no folder carried over, its input left open — the tripwire:
        // were claude to run it the terminal's way itself, SipAI's command
        // line would be doubled up and this section would say so.
        try? FileManager.default.createDirectory(at: work.appendingPathComponent("sub"),
                                                 withIntermediateDirectories: true)
        if let c = Claude(binary: claude, home: home, port: port, work: work, resume: nil) {
            for (command, rows) in [("echo shell=$0", 1), ("cd sub", 2), ("pwd", 3)] {
                c.write(ClaudeShellCommand.bashCommandLine(command))
                _ = waitFor(20) { c.outputs.count >= rows }
            }
            c.write(ClaudeShellCommand.bashCommandLine("read x; echo READ_DONE"))
            let answeredWhileOpen = waitFor(3) { c.outputs.count >= 4 }
            c.finish()
            let outs = c.outputs
            check("claude's own message by itself: a plain /bin/sh, a cd that does not carry over, its input left open",
                  outs.count == 4 && outs[0].stdout.contains("shell=/bin/sh")
                    && outs[2].stdout.trimmingCharacters(in: .whitespacesAndNewlines) == physicalPath(work)
                    && !answeredWhileOpen && outs[3].interrupted,
                  "answered while open: \(answeredWhileOpen), \(outs.map(\.text))")
        }

        // The terminal's command line, as SipAI hands it over: the user's
        // shell with its startup file (an alias and a function there), the
        // folder a command ends in written back and the next one started
        // there, no input, the two streams as one — what claude's terminal
        // does (measured on its terminal, 2.1.312).
        try? """
        alias sipaiprobealias='echo ALIAS_RAN'
        sipaiprobefunc() { echo FUNC_RAN; }

        """.write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        if let c = Claude(binary: claude, home: home, port: port, work: work, resume: nil) {
            var folder: String? = nil
            var reported: [String?] = []
            let steps = ["echo shell=$0; sipaiprobealias; sipaiprobefunc", "cd sub", "pwd",
                         "read x; echo READ_DONE", "echo out; echo err >&2; exit 3"]
            for (n, command) in steps.enumerated() {
                let file = scratch.appendingPathComponent("folder-\(n)").path
                c.write(ClaudeShellCommand.bashCommandLine(
                    ClaudeTerminalShell.commandLine(command, shell: "/bin/zsh", home: home.path, folderFile: file),
                    cwd: folder ?? physicalPath(work)))
                _ = waitFor(n == 3 ? 4 : 20) { c.outputs.count >= n + 1 }
                let said = (try? String(contentsOfFile: file, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                reported.append(said)
                let output = c.outputs.count > n ? c.outputs[n] : nil
                folder = ClaudeTerminalShell.nextFolder(
                    reported: output?.exitCode == 0 ? said : nil, current: folder,
                    sessionFolder: physicalPath(work), maintainsSessionFolder: false).folder
            }
            c.finish()
            let outs = c.outputs
            check("the terminal's way: the user's own shell, with the aliases and functions of its startup file",
                  outs.count >= 1 && outs[0].stdout.contains("shell=/bin/zsh")
                    && outs[0].stdout.contains("ALIAS_RAN") && outs[0].stdout.contains("FUNC_RAN"),
                  "\(outs.map(\.text))")
            check("…a cd carried over to the next ! command, inside the session's folder",
                  outs.count >= 3 && reported.count >= 2 && reported[1] == physicalPath(work) + "/sub"
                    && outs[2].stdout.trimmingCharacters(in: .whitespacesAndNewlines) == physicalPath(work) + "/sub",
                  "reported \(reported), \(outs.map(\.text))")
            check("…no input: a command that reads it gets none and goes on",
                  outs.count >= 4 && outs[3].stdout.contains("READ_DONE") && outs[3].exitCode == 0,
                  "\(outs.map(\.text))")
            check("…its two streams as one, in order, and a failure's exit code to tell success from failure by",
                  outs.count == 5 && outs[4].stdout.contains("out\nerr") && outs[4].exitCode == 3
                    && reported.count == 5 && reported[4] == nil
                    && ClaudeShellCommand.terminalOutput(merged: outs[4].stdout, exitCode: outs[4].exitCode,
                                                         folderResetTo: nil).stderr.contains("out\nerr"),
                  "\(outs.map { "\($0.exitCode.map(String.init) ?? "-"): \($0.text)" })")
        }

        // `claude --cloud "task"` through the same route: no terminal window.
        if let c = Claude(binary: claude, home: home, port: port, work: work, resume: nil) {
            c.write(ClaudeShellCommand.bashCommandLine("claude --cloud \"probe task\""))
            _ = waitFor(30) { c.output != nil }
            c.finish()
            check("`claude --cloud \"task\"` gets claude's own answer: it needs a terminal window",
                  c.output?.text.contains("--cloud requires an interactive terminal") == true,
                  "\(String(describing: c.output))")
        }
    } else {
        skip("the real claude", "the stand-in endpoint did not start")
    }
} else {
    skip("the real claude", "claude is not installed")
}

// MARK: - 4. The real codex

print("\n4. The real codex, through the stand-in endpoint (token-free)")

if let codex = which("codex") {
    let home = scratch.appendingPathComponent("codex-home")
    let work = scratch.appendingPathComponent("codex-work")
    let records = scratch.appendingPathComponent("codex-requests")
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    if let (server, port) = startStandIn(records: records) {
        defer { server.terminate() }
        try? """
        model_provider = "fake"
        model = "gpt-5.5"

        [model_providers.fake]
        name = "fake"
        base_url = "http://127.0.0.1:\(port)"
        wire_api = "responses"

        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: codex)
        p.arguments = ["app-server"]
        p.currentDirectoryURL = work
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = home.path
        p.environment = env
        let input = Pipe(), out = Pipe()
        p.standardInput = input
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let lines = Lines()
        out.fileHandleForReading.readabilityHandler = { lines.feed($0.availableData) }
        if (try? p.run()) != nil {
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            func send(_ object: [String: Any]) {
                guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
                try? input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
            }
            func objects() -> [[String: Any]] {
                lines.snapshot.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            }
            func answer(_ id: Int) -> [String: Any]? {
                objects().first { ($0["id"] as? NSNumber)?.intValue == id && $0["method"] == nil }
            }
            send(["id": 1, "method": "initialize",
                  "params": ["clientInfo": ["name": "sipai-harness", "version": "0"]]])
            _ = waitFor(20) { answer(1) != nil }
            send(["method": "initialized"])
            send(["id": 2, "method": "thread/start", "params": ["cwd": work.path]])
            _ = waitFor(20) { answer(2) != nil }
            let threadId = ((answer(2)?["result"] as? [String: Any])?["thread"] as? [String: Any])?["id"] as? String
            if let threadId {
                send(["id": 3, "method": "thread/shellCommand",
                      "params": CodexShellCommand.params(threadId: threadId, command: "echo HELLO_SHELL")])
                let done = waitFor(30) { objects().contains { $0["method"] as? String == "turn/completed" } }
                let accepted = (answer(3)?["result"] as? [String: Any]) != nil
                let item = objects().first {
                    $0["method"] as? String == "item/completed"
                        && CodexShellCommand.isUserShell(($0["params"] as? [String: Any])?["item"] as? [String: Any] ?? [:])
                }.flatMap { ($0["params"] as? [String: Any])?["item"] as? [String: Any] }
                check("codex takes thread/shellCommand and runs it as a turn of its own",
                      accepted && done, "accepted \(accepted), turn completed \(done)")
                let output = item.map { CodexShellCommand.output(fromItem: $0, stopped: false) }
                check("…its item of the user's own shell command reads as the command's output",
                      output?.stdout.contains("HELLO_SHELL") == true && output?.exitCode == 0,
                      "\(String(describing: item))")
                check("…with no model request", requestCount(records) == 0, "\(requestCount(records)) requests")
            } else {
                check("codex starts a thread", false, "\(String(describing: answer(2)))")
            }
            try? input.fileHandleForWriting.close()
            if !waitFor(15, { !p.isRunning }) { p.terminate() }
            let sessions = home.appendingPathComponent("sessions")
            let rollout = FileManager.default.enumerator(atPath: sessions.path)?
                .compactMap { $0 as? String }.first { $0.hasSuffix(".jsonl") }
            if let rollout {
                let rows = describe(CodexSessionScanner.readHistory(of: sessions.appendingPathComponent(rollout)))
                check("reopened, codex's record reads as the command and its output",
                      rows == ["shell:!echo HELLO_SHELL", "output:HELLO_SHELL"], "\(rows)")
            } else {
                check("codex saved the shell command's turn", false)
            }
            // A new session whose first message is a `!` command is adopted
            // when codex takes the command, so the thread it made must take
            // the next message in a process of its own — and the model must
            // read the command's output with it.
            if let threadId, rollout != nil {
                let q = Process()
                q.executableURL = URL(fileURLWithPath: codex)
                q.arguments = ["app-server"]
                q.currentDirectoryURL = work
                q.environment = env
                let input2 = Pipe(), out2 = Pipe()
                q.standardInput = input2
                q.standardOutput = out2
                q.standardError = FileHandle.nullDevice
                let lines2 = Lines()
                out2.fileHandleForReading.readabilityHandler = { lines2.feed($0.availableData) }
                if (try? q.run()) != nil {
                    _ = fcntl(input2.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    func send2(_ object: [String: Any]) {
                        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
                        try? input2.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
                    }
                    func objects2() -> [[String: Any]] {
                        lines2.snapshot.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                    }
                    func answer2(_ id: Int) -> [String: Any]? {
                        objects2().first { ($0["id"] as? NSNumber)?.intValue == id && $0["method"] == nil }
                    }
                    send2(["id": 1, "method": "initialize",
                           "params": ["clientInfo": ["name": "sipai-harness", "version": "0"]]])
                    _ = waitFor(20) { answer2(1) != nil }
                    send2(["method": "initialized"])
                    send2(["id": 2, "method": "thread/resume", "params": ["threadId": threadId]])
                    _ = waitFor(20) { answer2(2) != nil }
                    let resumed = (answer2(2)?["result"] as? [String: Any]) != nil
                    check("a thread a ! command made opens again in another process",
                          resumed, "\(String(describing: answer2(2)))")
                    if resumed {
                        send2(["id": 3, "method": "turn/start",
                               "params": ["threadId": threadId,
                                          "input": [["type": "text", "text": "What did it print?"]]]])
                        _ = waitFor(30) { objects2().contains { $0["method"] as? String == "turn/completed" } }
                        check("…and the next message's request carries the command and its output",
                              requestText(records).contains("echo HELLO_SHELL")
                                  && requestText(records).contains("Output:\\nHELLO_SHELL"),
                              "\(requestCount(records)) request(s)")
                    }
                    try? input2.fileHandleForWriting.close()
                    if !waitFor(15, { !q.isRunning }) { q.terminate() }
                } else {
                    check("codex app-server starts again", false)
                }
            }
        } else {
            check("codex app-server starts", false)
        }
    } else {
        skip("the real codex", "the stand-in endpoint did not start")
    }

    // What Help says of a Codex session's ! command: exactly as in codex's
    // own terminal, which runs it the same way — a login zsh (not .zshrc,
    // so no alias from it), the folder not kept, no input (measured on
    // codex's terminal as on this route).
    let shellHome = scratch.appendingPathComponent("codex-shell-home")
    let userHome = scratch.appendingPathComponent("codex-shell-user")
    let shellWork = scratch.appendingPathComponent("codex-shell-work")
    for dir in [shellHome, userHome, shellWork.appendingPathComponent("sub")] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    try? "alias sipaiprobealias='echo ALIAS_RAN'\n".write(to: userHome.appendingPathComponent(".zshrc"),
                                                          atomically: true, encoding: .utf8)
    try? """
    model_provider = "fake"
    model = "gpt-5.5"

    [model_providers.fake]
    name = "fake"
    base_url = "http://127.0.0.1:9"
    wire_api = "responses"

    """.write(to: shellHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    let r = Process()
    r.executableURL = URL(fileURLWithPath: codex)
    r.arguments = ["app-server"]
    r.currentDirectoryURL = shellWork
    var shellEnv = ProcessInfo.processInfo.environment
    shellEnv["CODEX_HOME"] = shellHome.path
    shellEnv["HOME"] = userHome.path
    shellEnv["SHELL"] = "/bin/zsh"
    r.environment = shellEnv
    let input3 = Pipe(), out3 = Pipe()
    r.standardInput = input3
    r.standardOutput = out3
    r.standardError = FileHandle.nullDevice
    let lines3 = Lines()
    out3.fileHandleForReading.readabilityHandler = { lines3.feed($0.availableData) }
    if (try? r.run()) != nil {
        _ = fcntl(input3.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        func send3(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            try? input3.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
        }
        func objects3() -> [[String: Any]] {
            lines3.snapshot.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
        func answer3(_ id: Int) -> [String: Any]? {
            objects3().first { ($0["id"] as? NSNumber)?.intValue == id && $0["method"] == nil }
        }
        send3(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "sipai-harness", "version": "0"]]])
        _ = waitFor(20) { answer3(1) != nil }
        send3(["method": "initialized"])
        send3(["id": 2, "method": "thread/start", "params": ["cwd": shellWork.path]])
        _ = waitFor(20) { answer3(2) != nil }
        let tid = ((answer3(2)?["result"] as? [String: Any])?["thread"] as? [String: Any])?["id"] as? String
        var items: [ShellCommandOutput] = []
        if let tid {
            for (n, command) in ["cd sub", "pwd", "sipaiprobealias", "read x; echo READ_DONE"].enumerated() {
                send3(["id": 10 + n, "method": "thread/shellCommand",
                       "params": CodexShellCommand.params(threadId: tid, command: command)])
                _ = waitFor(15) {
                    objects3().filter { $0["method"] as? String == "turn/completed" }.count >= n + 1
                }
                let completed = objects3().compactMap { message -> [String: Any]? in
                    guard message["method"] as? String == "item/completed",
                          let item = (message["params"] as? [String: Any])?["item"] as? [String: Any],
                          CodexShellCommand.isUserShell(item) else { return nil }
                    return item
                }
                if completed.count == n + 1, let last = completed.last {
                    items.append(CodexShellCommand.output(fromItem: last, stopped: false))
                }
            }
        }
        try? input3.fileHandleForWriting.close()
        if !waitFor(15, { !r.isRunning }) { r.terminate() }
        let folder = physicalPath(shellWork)
        check("Help's account of a Codex session's ! command: a cd that does not carry over, no alias from .zshrc, no input",
              items.count == 4 && items[1].stdout.trimmingCharacters(in: .whitespacesAndNewlines) == folder
                && items[2].exitCode == 127 && items[3].stdout.contains("READ_DONE") && items[3].exitCode == 0,
              "\(items.map { "\($0.exitCode.map(String.init) ?? "-"): \($0.text)" })")
    } else {
        check("codex app-server starts for the shell checks", false)
    }
} else {
    skip("the real codex", "codex is not installed")
}

// MARK: - 5. The wiring

print("\n5. The wiring")

func source(_ path: String) -> String {
    (try? String(contentsOf: sourceRoot.appendingPathComponent(path), encoding: .utf8)) ?? ""
}
let runner = source("SipAI/Models/AgentRunner.swift")
let driver = source("SipAI/Models/CodexAppServerTurn.swift")
let page = source("SipAI/Views/Chat/AgentSessionView.swift")
let composer = source("SipAI/Views/Chat/AgentComposer.swift")
let options = source("SipAI/Models/AgentLaunchOptions.swift")

check("the runner runs a ! command: claude's own message first, the terminal's rows after it",
      runner.contains("func runShellCommand(") && runner.contains("ClaudeShellCommand.bashCommandLine(")
      && runner.contains("ClaudeShellCommand.inputRow(") && runner.contains("ClaudeShellCommand.outputRow(")
      && runner.contains("ClaudeShellCommand.responds(") && runner.contains("ClaudeShellCommand.outputCap("))
check("…given the terminal's command line once claude's environment is known, in the folder the last one ended in",
      runner.contains("ClaudeTerminalShell.commandLine(") && runner.contains("ClaudeTerminalShell.shell(")
      && runner.contains("claudeStdinLine = claudeShellLine(shell.command, environment: env)")
      && runner.contains("ClaudeTerminalShell.nextFolder(") && runner.contains("claudeShellFolder = next.folder"))
check("…and the result handed over, and drawn, in the terminal's own record shape",
      runner.contains("ClaudeShellCommand.terminalOutput(") && runner.contains("ClaudeShellCommand.noOutputText")
      && runner.contains("ClaudeShellCommand.errorText(") && runner.contains("appendShellOutputRow(output)"))
check("…passing over the empty results of the rows that asked for nothing, as a skill load's",
      runner.contains("pendingShellResults > 0, case .result(_, _, let turns, _, _) = event.kind, turns == 0"))
check("codex's driver sends thread/shellCommand and draws the user's own command as its output",
      driver.contains("\"thread/shellCommand\"") && driver.contains("CodexShellCommand.isUserShell(item)"))
check("the runner asks the one rule for what the installed tool can do",
      runner.contains("enum ShellCommandRoute") && runner.contains("ShellCommandSupport.verdict("))
let handleSend = page.range(of: "private func handleSend()")
let shellAt = page.range(of: "if let command = typedShellCommand")
let codexAt = page.range(of: "if let command = typedCodexCommand")
check("Send runs a ! command before anything else reads the box",
      handleSend != nil && shellAt != nil && codexAt != nil
      && shellAt!.lowerBound > handleSend!.lowerBound && shellAt!.lowerBound < codexAt!.lowerBound)
check("…and the composer says what Send will do, by the same rule, and holds Send while the line cannot run",
      composer.contains("ShellCommandRoute.verdict(agentKey: agentKey)") && composer.contains("&& !shellCommandWaits")
      && page.contains("ShellCommandRoute.verdict(agentKey: sessionAgentKey)")
      && page.contains("case .pending, .needsNewer:\n                return"))
check("a ! command typed during a turn waits for its end, never steered in as words",
      options.contains("codexCommand == nil && shellCommand == nil"))
check("a ! row offers no pencil", page.contains("&& !shellCommand)"))
check("the transcript draws and searches a long output's start, never the whole of it",
      page.contains("CodeBlockView(language: \"\", code: shown.text, slot: slot)")
        && page.contains("add(item.id) { output.shown.text }")
        && page.contains("add(event.id) { output.shown.text }")
        && !page.contains("code: output.text"))
let shellRows = [StreamEvent(kind: .userMessage(text: "!ls"), shellCommand: true),
                 StreamEvent(kind: .shellOutput(ShellCommandOutput(stdout: "a", stderr: "", exitCode: 0)))]
check("the waiting row stays up past a ! command's output, until the agent answers — the one walk (WaitingRow)",
      WaitingRow.awaitsAgent(shellRows, compactionIsOutput: false)
        && WaitingRow.awaitsAgent(shellRows, compactionIsOutput: true)
        && !WaitingRow.awaitsAgent(shellRows + [StreamEvent(kind: .assistantText(text: "Listed."))],
                                   compactionIsOutput: false)
        && page.contains("WaitingRow.awaitsAgent(runner.events, compactionIsOutput: false)"))
check("a message held during a ! command is offered no Steer into it: claude works on the command only once its rows are handed over for an answer",
      runner.contains("case .systemInit: claudeWorking = claudeShell?.awaitingOutput != true; refreshSteerable()")
        && runner.contains("if responds { claudeWorking = true; refreshSteerable() }"))

print("")
if failures == 0 {
    print("PASS — \(skips) skipped")
    exit(0)
}
print("FAIL — \(failures) check(s)")
exit(1)
