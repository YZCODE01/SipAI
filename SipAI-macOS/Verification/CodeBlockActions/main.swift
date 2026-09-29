// Headless checks for fenced code blocks: how the REAL block parser reads
// fences, what the corner buttons copy and save, that long lines wrap,
// and the wiring in the views. See run.sh for why each part exists.
//
// Nothing in this directory is part of the app target.

import AppKit
import SwiftUI

let root = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

var passed = 0
var failed = 0

func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    if ok {
        passed += 1
        print("PASS  \(label)")
    } else {
        failed += 1
        print("FAIL  \(label)")
        let d = detail()
        if !d.isEmpty { print("      \(d)") }
    }
}

func section(_ title: String) { print("\n== \(title)") }

/// Blocks as short strings, so an expectation reads like the source.
func describe(_ blocks: [MarkdownRenderer.Block]) -> [String] {
    blocks.map { block in
        switch block {
        case .heading(let level, let text): return "h\(level):\(text)"
        case .paragraph(let text): return "p:\(text)"
        case .horizontalRule: return "hr"
        case .bulletItem(let indent, let text): return "li\(indent):\(text)"
        case .orderedItem(let indent, let number, let text): return "ol\(indent).\(number):\(text)"
        case .blockquote(let depth, let text): return "q\(depth):\(text)"
        case .codeBlock(let language, let body): return "code[\(language)]:\(body.debugDescription)"
        case .table: return "table"
        case .displayMath(let latex): return "math:\(latex)"
        case .blank: return "blank"
        }
    }
}

func expectParse(_ label: String, _ source: String, _ expected: [String]) {
    let got = describe(MarkdownRenderer.parse(source))
    check(got == expected, label, "got      \(got)\n      expected \(expected)")
}

func readSource(_ relative: String) -> String {
    (try? String(contentsOfFile: root + "/" + relative, encoding: .utf8)) ?? ""
}

/// The text of `struct <name>` out of a file: from its declaration to the
/// first closing brace in column 0.
func structText(_ name: String, in file: String) -> String {
    guard let start = file.range(of: "struct \(name)") else { return "" }
    let rest = file[start.lowerBound...]
    guard let end = rest.range(of: "\n}\n") else { return String(rest) }
    return String(rest[..<end.upperBound])
}

MainActor.assumeIsolated {

    // MARK: §1 Fences — the shapes blocks have always been drawn with

    section("§1a Well-formed fences keep the shape they have always had")
    // Each expectation is what the parser produced before fences followed
    // CommonMark (run.sh's control pass confirms it against that tree): a
    // blank line before every block, one after a block that ends the text.
    expectParse("text, block, text",
                "text\n```\ncode\n```\nmore",
                ["p:text", "blank", "code[]:\"code\\n\"", "p:more"])
    expectParse("a block that ends the text",
                "text\n```\ncode\n```",
                ["p:text", "blank", "code[]:\"code\\n\"", "blank"])
    expectParse("a block that ends the text, trailing newline",
                "text\n```\ncode\n```\n",
                ["p:text", "blank", "code[]:\"code\\n\"", "blank"])
    expectParse("a block that opens the text, blank line after",
                "```\ncode\n```\n\nmore",
                ["blank", "code[]:\"code\\n\"", "blank", "p:more"])
    expectParse("a block that opens the text",
                "```\ncode\n```\nmore",
                ["blank", "code[]:\"code\\n\"", "p:more"])
    expectParse("unclosed (a reply still streaming)",
                "text\n```py\nprint(1)",
                ["p:text", "blank", "code[py]:\"print(1)\"", "blank"])
    expectParse("unclosed, trailing newline",
                "text\n```py\nprint(1)\n",
                ["p:text", "blank", "code[py]:\"print(1)\\n\"", "blank"])
    expectParse("two blocks back to back",
                "```\na\n```\n```\nb\n```",
                ["blank", "code[]:\"a\\n\"", "blank", "code[]:\"b\\n\"", "blank"])
    expectParse("a blank line before the fence",
                "text\n\n```\ncode\n```",
                ["p:text", "blank", "blank", "code[]:\"code\\n\"", "blank"])
    expectParse("an empty block",
                "```\n```",
                ["blank", "code[]:\"\"", "blank"])
    expectParse("the language is the info string's first word",
                "```python title=x\ncode\n```",
                ["blank", "code[python]:\"code\\n\"", "blank"])
    expectParse("CRLF line ends",
                "```py\r\nprint(1)\r\n```",
                ["blank", "code[py]:\"print(1)\\n\"", "blank"])
    expectParse("blank lines inside a block survive",
                "```\na\n\n  b\n```",
                ["blank", "code[]:\"a\\n\\n  b\\n\"", "blank"])

    section("§1b Fences the parser used to misread")
    expectParse("a Markdown file holding a code block, in a four-backtick fence, is ONE block",
                "Here is the file:\n\n````markdown\n# Title\n\n```bash\nls -la\n```\n\nMore text\n````\n\nAfter the file.",
                ["p:Here is the file:", "blank", "blank",
                 "code[markdown]:\"# Title\\n\\n```bash\\nls -la\\n```\\n\\nMore text\\n\"",
                 "blank", "p:After the file."])
    expectParse("a tilde fence is a fence",
                "Before\n\n~~~python\nprint(1)\n~~~\n\nAfter",
                ["p:Before", "blank", "blank", "code[python]:\"print(1)\\n\"", "blank", "p:After"])
    expectParse("three backticks inside a sentence are text, not a fence",
                "Wrap code in ``` fences.\nSecond line of prose.\n\nThird paragraph.",
                ["p:Wrap code in ``` fences. Second line of prose.", "blank", "p:Third paragraph."])
    expectParse("three backticks inside a table cell do not swallow the rest",
                "| a | b |\n|---|---|\n| x | loses ``` fences |\n\n## After\n\ntext",
                ["table", "blank", "h2:After", "blank", "p:text"])
    expectParse("a fence inside a list item: its indentation is not part of the code",
                "1. Run this:\n   ```bash\n   make\n   ```\n2. Then this.",
                ["ol0.1:Run this:", "blank", "code[bash]:\"make\\n\"", "ol0.2:Then this."])
    expectParse("a fence line WITH a language does not close a block",
                "```markdown\n```bash\nls\n```\n```",
                ["blank", "code[markdown]:\"```bash\\nls\\n\"", "blank", "code[]:\"\"", "blank"])
    expectParse("a backtick fence whose info string holds a backtick is inline code",
                "```js let x = 1```\nnext",
                ["p:```js let x = 1``` next"])
    expectParse("a closer indented four past the opener is content",
                "```\nline\n    ```\n```",
                ["blank", "code[]:\"line\\n    ```\\n\"", "blank"])
    expectParse("a longer closing fence closes",
                "```\ncode\n`````",
                ["blank", "code[]:\"code\\n\"", "blank"])
    expectParse("backticks do not close a tilde block",
                "~~~\n```\ncode\n~~~",
                ["blank", "code[]:\"```\\ncode\\n\"", "blank"])
    expectParse("an opening line alone (still streaming) holds no code yet",
                "text\n```py",
                ["p:text", "blank", "code[py]:\"\"", "blank"])

    section("§1c Only the parser writes a block placeholder")
    // A block is stood in for by a sentinel line while the rest of the
    // text is parsed. Text holding that sentinel itself — a reply, a
    // synced note — was read back as a placeholder: `CB-1` indexed the
    // block list at -1 and trapped, every time the text was drawn.
    expectParse("a forged placeholder with a negative index is text, and no crash",
                "before\n\u{E000}CB-1\u{E000}\nafter",
                ["p:before CB-1 after"])
    expectParse("a forged placeholder naming a real block does not repeat it",
                "```\ncode\n```\n\u{E000}CB0\u{E000}",
                ["blank", "code[]:\"code\\n\"", "p:CB0"])
    expectParse("a sentinel inside a code block stays in the code",
                "```\n\u{E000}CB0\u{E000}\n```",
                ["blank", "code[]:\"\u{E000}CB0\u{E000}\\n\"", "blank"])

    // MARK: §4 Long lines wrap (the REAL CodeBlockView)

    section("§4 Long lines wrap instead of running off the window")
    func size(_ code: String, width: CGFloat, tier: FontTier) -> CGSize {
        let view = CodeBlockView(language: "text", code: code)
            .environment(\.sipFontScale, SipFont.contentScale(tier.scale))
        let host = NSHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: width, height: 100_000))
    }
    let token = String(repeating: "x", count: 400) + "\n"
    let prose = Array(repeating: "wrapping prose", count: 18).joined(separator: " ") + "\n"
    for tier in FontTier.allCases {
        let one = size("short\n", width: 500, tier: tier)
        let two = size("short\nshort\n", width: 500, tier: tier)
        let longToken = size(token, width: 500, tier: tier)
        let longProse = size(prose, width: 500, tier: tier)
        check(longToken.width <= 500.5 && longToken.height > two.height,
              "\(tier): a 400-character unbroken line stays inside 500 pt and wraps",
              "size \(longToken), two-line block \(two)")
        check(longProse.width <= 500.5 && longProse.height > one.height,
              "\(tier): a long line of words wraps",
              "size \(longProse), one-line block \(one)")
    }

    // MARK: §2–§3, §5–§6 — need CodeBlockActions.swift

#if CODE_BLOCK_ACTIONS
    section("§2 What Copy and Save carry")
    check(CodeBlockExport.copyText("ls -la\n") == "ls -la",
          "Copy drops the newline before the closing fence (a pasted command must not run by itself)")
    check(CodeBlockExport.copyText("a\n\n") == "a\n", "Copy drops ONE trailing newline, no more")
    check(CodeBlockExport.copyText("a") == "a", "a body with no trailing newline is copied whole")
    check(CodeBlockExport.copyText("") == "", "an empty block copies nothing")
    check(CodeBlockExport.copyText("  def f():\n\treturn 1\n") == "  def f():\n\treturn 1",
          "indentation and tabs are byte-exact")
    check(CodeBlockExport.fileText("a") == "a\n", "a saved file ends in a newline")
    check(CodeBlockExport.fileText("a\n") == "a\n", "…exactly one")
    check(CodeBlockExport.fileText("a\n\n") == "a\n\n", "…keeping a blank line the block itself ends with")
    check(CodeBlockExport.fileText("") == "", "an empty block saves an empty file")

    section("§3 What the Save panel suggests")
    let ext = CodeBlockExport.fileExtension(forLanguage:)
    check(ext("python") == "py" && ext("Python") == "py" && ext("py") == "py", "python → .py, any case")
    check(ext("markdown") == "md" && ext("md") == "md", "markdown → .md")
    check(ext("text") == "txt" && ext("") == "txt" && ext("plaintext") == "txt", "text, none → .txt")
    check(ext("bash") == "sh" && ext("zsh") == "sh" && ext("shell") == "sh", "shells → .sh")
    check(ext("json") == "json" && ext("swift") == "swift" && ext("typescript") == "ts"
          && ext("c++") == "cpp" && ext("yaml") == "yaml", "common languages")
    check(ext("brainfudge") == "txt", "a language the table does not name saves as .txt")
    let name = CodeBlockExport.suggestedFileName(title:language:)
    check(name("I am writing a prompt and I would like…", "text") == "I am writing a prompt and I would like.txt",
          "named after the conversation, truncation mark dropped",
          name("I am writing a prompt and I would like…", "text"))
    check(name(nil, "python") == "Untitled.py", "no title → Untitled")
    check(name("   ", "python") == "Untitled.py", "a blank title → Untitled")
    check(name("a/b: c", "text") == "a-b- c.txt", "/ and : cannot be in a file name",
          name("a/b: c", "text"))
    check(name("..hidden", "text") == "hidden.txt", "a leading dot would hide the file",
          name("..hidden", "text"))
    check(name("line one\nline two", "text") == "line one line two.txt", "line breaks become spaces")
    check(name("x", "dockerfile") == "Dockerfile" && name("x", "makefile") == "Makefile",
          "a Dockerfile and a Makefile keep the names their tools look for")
    let long = name(String(repeating: "word ", count: 40), "text")
    check(long.count <= 64 && long.hasSuffix("word.txt"),
          "a long title is cut at a word boundary", long)

    section("§5 Wiring in the views")
    let renderer = readSource("SipAI/Utilities/MarkdownRenderer.swift")
    let codeView = structText("CodeBlockView", in: renderer)
    check(codeView.contains(".overlay(alignment: .bottomTrailing)"),
          "the buttons are an overlay at the block's lower right (no row changes height)")
    check(!codeView.contains("ScrollView(.horizontal"), "code no longer scrolls sideways")
    check(codeView.contains("CodeBlockHoverPreference.self"), "a block reports that the pointer is over it")
    let bubble = readSource("SipAI/Views/Chat/MessageBubble.swift")
    check(bubble.contains("onPreferenceChange(CodeBlockHoverPreference.self"),
          "a sent message listens for a hovered code block inside it")
    check(bubble.contains("hovering && !codeBlockHovered"),
          "…and hides its own corner buttons meanwhile (innermost wins)")
    check(bubble.contains("CornerIconButton(") && !bubble.contains("func iconButton("),
          "the message's buttons are the shared corner button (one spelling)")
    check(readSource("SipAI/Views/Chat/ChatView.swift").contains(".environment(\\.sipCodeFileTitle"),
          "a chat names saved code after itself")
    check(readSource("SipAI/Views/Chat/AgentSessionView.swift").contains(".environment(\\.sipCodeFileTitle"),
          "an agent session names saved code after itself")
    let actions = readSource("SipAI/Utilities/CodeBlockActions.swift")
    check(actions.contains("NSSavePanel()") && !actions.contains("downloadsDirectory"),
          "Save asks where, and writes nowhere the user did not choose")

    section("§6 Strings")
    let catalogPath = root + "/SipAI/Resources/Localizable.xcstrings"
    let catalog = (try? Data(contentsOf: URL(fileURLWithPath: catalogPath)))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let strings = catalog?["strings"] as? [String: Any] ?? [:]
    for key in ["Copy code", "Save as a file…", "Save Code", "Untitled"] {
        let zh = ((((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?["zh-Hans"]
                   as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        check(!(zh ?? "").isEmpty, "catalog has “\(key)” with a Chinese translation", "zh-Hans: \(zh ?? "missing")")
    }
#else
    print("\nPRE-FIX  CodeBlockActions.swift is absent — §2, §3, §5 and §6 not compiled")
#endif
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
