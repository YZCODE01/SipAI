// CodeBlockActions.swift
// What a fenced code block's two corner buttons do — Copy, and Save as a
// file — plus the small corner button itself, which a sent message's own
// copy and branch buttons share.
//
// The text rules are pure (no view, no panel), so the headless harness
// (`Verification/CodeBlockActions`) holds them directly: what a copy
// carries, what a saved file holds, what the Save panel suggests calling
// it.

import AppKit
import SwiftUI

// MARK: - Text and file-name rules

enum CodeBlockExport {

    /// The block's text as the clipboard gets it: byte-exact, minus ONE
    /// trailing newline. A fenced body ends in the newline before its
    /// closing fence, and a command pasted into a terminal with that
    /// newline attached runs the moment it lands.
    static func copyText(_ body: String) -> String {
        body.hasSuffix("\n") ? String(body.dropLast()) : body
    }

    /// The block's text as a saved file holds it: what Copy carries, ending
    /// in a newline the way text files do. A blank line the block itself
    /// ends with is kept; an empty block saves an empty file.
    static func fileText(_ body: String) -> String {
        let text = copyText(body)
        return text.isEmpty ? "" : text + "\n"
    }

    /// The extension for a fence's language word, looked up without case.
    /// A language the table does not name saves as plain text — the
    /// panel's name field can change it either way.
    static func fileExtension(forLanguage language: String) -> String {
        extensions[language.lowercased()] ?? "txt"
    }

    /// What the Save panel suggests: the conversation's name as a file
    /// name, with the language's extension. A Dockerfile or a Makefile
    /// keeps the name its tool looks for instead.
    static func suggestedFileName(title: String?, language: String) -> String {
        let lower = language.lowercased()
        if let fixed = fixedNames[lower] { return fixed }
        let stem = title.flatMap(fileStem)
            ?? String(localized: "Untitled",
                      comment: "Default name the Save panel suggests for a code block when the conversation has no title")
        return stem + "." + fileExtension(forLanguage: lower)
    }

    /// Longest stem suggested; a longer title is cut at a word boundary.
    static let maxStemLength = 60

    /// A title reduced to something a file can be called, or nil when
    /// nothing usable is left. `/` and `:` cannot appear in a macOS file
    /// name, line breaks and control characters become spaces, a leading
    /// dot would hide the file, and a trailing "…" is only the sidebar's
    /// truncation mark.
    static func fileStem(_ title: String) -> String? {
        var cleaned = ""
        for ch in title {
            if ch == "/" || ch == ":" {
                cleaned.append("-")
            } else if ch.isNewline
                        || ch.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                cleaned.append(" ")
            } else {
                cleaned.append(ch)
            }
        }
        var stem = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        stem = trimmedEnds(stem)
        guard !stem.isEmpty else { return nil }
        if stem.count > maxStemLength {
            let head = String(stem.prefix(maxStemLength))
            if let space = head.lastIndex(of: " "),
               head.distance(from: head.startIndex, to: space) >= maxStemLength / 2 {
                stem = String(head[..<space])
            } else {
                stem = head
            }
            stem = trimmedEnds(stem)
        }
        return stem.isEmpty ? nil : stem
    }

    /// Spaces, dots and truncation marks off both ends.
    private static func trimmedEnds(_ s: String) -> String {
        var out = Substring(s)
        let edge: (Character) -> Bool = { $0 == " " || $0 == "." || $0 == "…" }
        while let first = out.first, edge(first) { out = out.dropFirst() }
        while let last = out.last, edge(last) { out = out.dropLast() }
        return String(out)
    }

    private static let fixedNames: [String: String] = [
        "dockerfile": "Dockerfile",
        "makefile": "Makefile",
    ]

    private static let extensions: [String: String] = {
        var map: [String: String] = [:]
        func add(_ ext: String, _ names: String...) {
            for name in names { map[name] = ext }
        }
        add("txt", "", "text", "txt", "plaintext", "plain", "output", "console", "terminal")
        add("md", "markdown", "md")
        add("sh", "bash", "sh", "shell", "zsh", "shellscript")
        add("fish", "fish")
        add("ps1", "powershell", "ps1", "pwsh")
        add("bat", "bat", "batch", "cmd")
        add("py", "python", "py", "python3")
        add("swift", "swift")
        add("js", "javascript", "js", "node")
        add("mjs", "mjs")
        add("ts", "typescript", "ts")
        add("jsx", "jsx")
        add("tsx", "tsx")
        add("json", "json")
        add("jsonc", "jsonc")
        add("yaml", "yaml")
        add("yml", "yml")
        add("toml", "toml")
        add("ini", "ini")
        add("xml", "xml")
        add("html", "html", "htm")
        add("css", "css")
        add("scss", "scss")
        add("svg", "svg")
        add("sql", "sql")
        add("graphql", "graphql", "gql")
        add("proto", "proto", "protobuf")
        add("c", "c")
        add("h", "h")
        add("cpp", "cpp", "c++", "cc", "cxx")
        add("hpp", "hpp")
        add("cs", "csharp", "cs", "c#")
        add("m", "objc", "objective-c", "objectivec", "matlab")
        add("java", "java")
        add("kt", "kotlin", "kt")
        add("scala", "scala")
        add("go", "go", "golang")
        add("rs", "rust", "rs")
        add("rb", "ruby", "rb")
        add("php", "php")
        add("pl", "perl", "pl")
        add("lua", "lua")
        add("r", "r")
        add("dart", "dart")
        add("hs", "haskell", "hs")
        add("ex", "elixir", "ex")
        add("jl", "julia", "jl")
        add("tex", "latex", "tex")
        add("bib", "bibtex", "bib")
        add("diff", "diff")
        add("patch", "patch")
        add("csv", "csv")
        add("tsv", "tsv")
        add("log", "log")
        add("vue", "vue")
        add("svelte", "svelte")
        add("tf", "terraform", "tf", "hcl")
        add("mmd", "mermaid")
        return map
    }()
}

// MARK: - Save

/// The Save panel for one block. The user chooses the folder and the
/// name; nothing is written anywhere they did not pick. The panel remembers
/// the last folder on its own, and the name field accepts any extension.
@MainActor
enum CodeBlockSaving {
    static func save(_ body: String, language: String, title: String?) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Save Code",
                             comment: "Title of the Save panel for a code block")
        panel.nameFieldStringValue = CodeBlockExport.suggestedFileName(title: title,
                                                                       language: language)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(CodeBlockExport.fileText(body).utf8).write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "The file could not be written.",
                                       comment: "Export failure: the destination refused the write")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

// MARK: - Hover wiring

/// True while the pointer is over a code block. A sent message reads it
/// to hide its own corner buttons meanwhile: a message that ENDS in a
/// code block would otherwise draw two button pairs a few points apart in
/// the same corner, and the pair for the thing under the pointer is the
/// block's.
struct CodeBlockHoverPreference: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct SipCodeFileTitleKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The name of the conversation a code block sits in, as the sidebar
    /// shows it — what the Save panel names the file after. Nil suggests
    /// "Untitled".
    var sipCodeFileTitle: String? {
        get { self[SipCodeFileTitleKey.self] }
        set { self[SipCodeFileTitleKey.self] = newValue }
    }
}

// MARK: - Corner button

/// The small square button in the lower-right corner of a sent message
/// and of a code block, shown while the pointer is over its owner. A fixed
/// 22 × 20 at every Font Size tier, like the other hover icons (see
/// `SipFont`). Pointing at the button itself lifts it a step, so it is
/// plain which of two neighbouring buttons a click will reach.
struct CornerIconButton: View {
    let systemName: String
    /// Brand blue: an action that just landed (a copy's checkmark).
    var tinted: Bool = false
    let hint: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tinted
                                 ? SipDesign.blue
                                 : (hovered ? ChatDesign.textPrimary : ChatDesign.textSecondary))
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(hovered ? 0.09 : 0))
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(SipDesign.borderLight, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: hovered)
        .help(hint)
        .accessibilityLabel(hint)
    }
}
