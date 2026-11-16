import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Link syntax

/// `[words](target)` as the transcript's inline pass reads it, the target
/// either in angle brackets (CommonMark's form for a target holding spaces
/// or parentheses — `[Report](</My Project/Report (final).md>)`) or bare.
/// Group 1 is the words, group 2 an angle-bracket target, group 3 a bare
/// one. `MarkdownInline` and `LinkTargetShield` read links by this one
/// pattern, so the text the LaTeX pass skips is exactly the text later
/// read as a link target.
enum MarkdownLinkSyntax {
    static let pattern = #"\[([^\]]+)\]\((?:<([^<>\n]*)>|([^)]+))\)"#
    static let regex: NSRegularExpression = {
        // A constant pattern: it compiles, or every link in the app is broken in every build.
        try! NSRegularExpression(pattern: pattern)
    }()

    /// The target of a match of `regex`, angle brackets off.
    static func target(of match: NSTextCheckingResult, in text: NSString) -> String {
        let angle = match.range(at: 2)
        if angle.location != NSNotFound { return text.substring(with: angle) }
        return text.substring(with: match.range(at: 3))
    }
}

/// Keeps link targets out of the LaTeX pass. `LatexSymbols.translate` reads
/// `^2` as a superscript and `a_b` as a subscript wherever they stand, so a
/// target that went through it pointed somewhere else: a path no longer
/// named its file, and `https://example.com/x^2` became a link to `…/x²`.
enum LinkTargetShield {
    private static let mark: Character = "\u{E002}"

    /// `text` with every link's target replaced by a numbered sentinel,
    /// and the targets in order. A sentinel already in the text is taken
    /// out first: it would be read back as a target the text never held.
    static func shield(_ text: String) -> (text: String, targets: [String]) {
        let clean = text.unicodeScalars.contains("\u{E002}")
            ? String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\u{E002}" }))
            : text
        // Every visible message is drawn several times a second while a
        // turn streams; text with no link skips the pattern.
        guard clean.contains("](") else { return (clean, []) }
        let ns = clean as NSString
        let matches = MarkdownLinkSyntax.regex.matches(in: clean, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (clean, []) }
        var out = ""
        var targets: [String] = []
        var cursor = 0
        for match in matches {
            // The parenthesised part, angle brackets included: everything after `](`.
            let words = match.range(at: 1)
            let open = words.location + words.length + 2
            let end = match.range.location + match.range.length - 1
            guard open <= end else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: open - cursor))
            out += "\(mark)LT\(targets.count)\(mark)"
            targets.append(ns.substring(with: NSRange(location: open, length: end - open)))
            cursor = end
        }
        out += ns.substring(from: cursor)
        return (out, targets)
    }

    /// The targets put back where `shield` took them from.
    static func restore(_ text: String, targets: [String]) -> String {
        guard !targets.isEmpty else { return text }
        var out = text
        for (index, target) in targets.enumerated() {
            out = out.replacingOccurrences(of: "\(mark)LT\(index)\(mark)", with: target)
        }
        return out
    }
}

// MARK: - The target

/// A markdown link whose target is a file on this Mac rather than a web
/// address: `[words](/full/path:12)`, `[words](</path with spaces/a.md>)`,
/// `[words](relative/path.md)`. Codex's own instructions tell its model to
/// cite every file it mentions in the first two shapes; Claude Code writes
/// the third.
///
/// The words alone would hide where the link goes, so the path is drawn
/// after them the way Codex's terminal prints it: relative to the session's
/// folder when the file is inside it, as written otherwise. What is drawn
/// is also what find counts, so every reader of the displayed text goes
/// through `displayed(base:)`.
struct FileLinkTarget: Equatable {
    /// The target as the reply wrote it, angle brackets off and percent
    /// escapes decoded — what is shown after the words.
    let written: String
    /// `written` without its line number (`:12`, `:12:5`, `#L12`,
    /// `#L12C5`): the line is shown and not used.
    let path: String

    /// Nil for a target that names no file: a web address or any other
    /// scheme (those go through `MarkdownInline.safeLink`), an anchor, a
    /// protocol-relative address, an empty target.
    init?(_ raw: String) {
        var target = raw.trimmingCharacters(in: .whitespaces)
        if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
        guard !target.isEmpty, !target.hasPrefix("#"), !target.hasPrefix("//"),
              Self.match(Self.scheme, in: target) == nil
        else { return nil }
        let decoded = target.contains("%") ? (target.removingPercentEncoding ?? target) : target
        let line = Self.match(Self.lineNumber, in: decoded)
        let path = line.map { String(decoded[..<$0.lowerBound]) } ?? decoded
        guard !path.isEmpty else { return nil }
        self.written = decoded
        self.path = path
    }

    /// `name:` ahead of any slash is a URL's scheme — except `name:12`,
    /// which is a file and its line.
    private static let scheme = #"^[A-Za-z][A-Za-z0-9+.-]*:(?!\d+(?::\d+)?$)"#
    private static let lineNumber = #"(?::\d+(?::\d+)?|#L\d+(?:C\d+)?)$"#

    private static func match(_ pattern: String, in text: String) -> Range<String.Index>? {
        text.range(of: pattern, options: .regularExpression)
    }

    /// The file's absolute path: as written, from the home folder for
    /// `~/…`, or from `base` (the session's folder) for a relative path.
    /// Nil for a relative path with no folder to read it from.
    func resolvedPath(base: String?) -> String? {
        if path == "~" || path.hasPrefix("~/") {
            return Self.normalized(NSHomeDirectory() + path.dropFirst())
        }
        if path.hasPrefix("/") { return Self.normalized(path) }
        guard let base, base.hasPrefix("/") else { return nil }
        return Self.normalized(base + "/" + path)
    }

    /// What is drawn after the words: an absolute path inside `base`
    /// relative to it, anything else as written (Codex's terminal does
    /// the same, and keeps the line number in both).
    func displayed(base: String?) -> String {
        guard path.hasPrefix("/"), let base, base.hasPrefix("/"),
              let inside = Self.relative(Self.normalized(path), to: Self.normalized(base))
        else { return written }
        return inside + written.dropFirst(path.count)
    }

    /// `.` and `..` folded and repeated slashes merged, by the spelling
    /// alone. Asking the file system here (`standardizingPath`, or
    /// `URL(fileURLWithPath:)` without `isDirectory`) would wait on it
    /// from inside a view body, for a path untrusted text chose.
    static func normalized(_ absolute: String) -> String {
        var parts: [Substring] = []
        for part in absolute.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `path` below `base`, either spelled with or without `/private`
    /// (a temp folder reaches one side resolved and the other not).
    private static func relative(_ path: String, to base: String) -> String? {
        func dropPrivate(_ s: String) -> String {
            s.hasPrefix("/private/") ? String(s.dropFirst("/private".count)) : s
        }
        for (p, b) in [(path, base), (dropPrivate(path), dropPrivate(base))] where p.hasPrefix(b + "/") {
            return String(p.dropFirst(b.count + 1))
        }
        return nil
    }
}

extension FileLinkTarget {
    /// The words, then the path in brackets, as `MarkdownInline` draws a
    /// file link: the words in the link colour and underlined, the path in
    /// the quieter colour, both one link. A file found missing is greyed
    /// and its link says so (`FileLinkURL.hotspotBehavior`). A relative
    /// path with no folder to read it from is no link: the words as they
    /// are, the path after them as text.
    func attributed(words: String, base: String?) -> AttributedString {
        var head = AttributedString(words)
        var tail = AttributedString(" (\(displayed(base: base)))")
        tail.foregroundColor = ChatDesign.textSecondary
        guard let resolved = resolvedPath(base: base) else { return head + tail }
        let missing = FileLinkPresence.shared.state(of: resolved) == .missing
        guard let url = FileLinkURL.make(path: resolved, missing: missing) else { return head + tail }
        head.link = url
        tail.link = url
        if missing {
            head.foregroundColor = ChatDesign.textSecondary
        } else {
            head.foregroundColor = ChatDesign.blue
            head.underlineStyle = Text.LineStyle.single
        }
        return head + tail
    }
}

// MARK: - The link

/// How a file link travels inside the app: under a scheme of its own, so
/// it is never handed to the system as a `file:` URL, which macOS opens
/// with whatever claims the file — launching an app or mounting a disk
/// image. `FileLinkOpener` is the one reader that acts on it.
enum FileLinkURL {
    static let scheme = "sipai-file"

    static func make(path: String, missing: Bool) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.path = path
        if missing { parts.query = "missing" }
        return parts.url
    }

    /// The absolute path a file link names; nil for every other URL.
    static func path(of url: URL) -> String? {
        guard url.scheme == scheme,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.path.hasPrefix("/")
        else { return nil }
        return parts.path
    }

    static func isMissing(_ url: URL) -> Bool {
        path(of: url) != nil && URLComponents(url: url, resolvingAgainstBaseURL: false)?.query == "missing"
    }

    /// Whether `text` holds a file link.
    static func appears(in text: AttributedString) -> Bool {
        text.runs[\.link].contains { link, _ in link?.scheme == scheme }
    }

    /// What a file link's region does: the pointing hand, and the full
    /// path on hover (what is drawn may be relative); for a file found
    /// missing, no hand, no click, and "File not found". Any other link is
    /// left as `LinkPointers` draws it.
    static let hotspotBehavior: (URL) -> LinkHotspotBehavior = { url in
        guard let path = path(of: url) else { return LinkHotspotBehavior() }
        guard !isMissing(url) else { return LinkHotspotBehavior(follows: false, help: notFoundHelp) }
        return LinkHotspotBehavior(help: path)
    }

    private static var notFoundHelp: String {
        String(localized: "File not found",
               comment: "Hover text on a link in a reply to a file that is not on this Mac")
    }
}

// MARK: - Is the file there

/// Whether a file link's file is there, asked off the main thread and
/// remembered for a while. A look at the file system can wait — on an
/// automounted path under `/net`, on a stale network share — and the path
/// comes from text nobody vetted, so a view body never asks it directly:
/// it draws a link it has not heard about as present, and redraws when
/// the answer lands (`redrawsOnFilePresence`).
final class FileLinkPresence: @unchecked Sendable {
    static let shared = FileLinkPresence()
    static let changed = Notification.Name("SipAIFileLinkPresenceChanged")

    enum State: Equatable { case unknown, present, missing }

    private let lock = NSLock()
    private var known: [String: (state: State, at: Date)] = [:]
    private var asking: Set<String> = []
    private var announcing = false
    /// One look at a time: a look that hangs holds up the others, which
    /// then draw as present, rather than tying up a thread each.
    private let queue = DispatchQueue(label: "SipAI.FileLinkPresence", qos: .utility)
    private let freshFor: TimeInterval = 10
    private let limit = 2048

    /// The last answer for `path` (`.unknown` before the first), and a
    /// fresh look started when that answer is old.
    func state(of path: String) -> State {
        lock.lock()
        defer { lock.unlock() }
        let entry = known[path]
        let stale = entry.map { Date().timeIntervalSince($0.at) > freshFor } ?? true
        if stale, !asking.contains(path) {
            asking.insert(path)
            queue.async { [weak self] in self?.look(at: path) }
        }
        return entry?.state ?? .unknown
    }

    private func look(at path: String) {
        let state: State = FileManager.default.fileExists(atPath: path) ? .present : .missing
        lock.lock()
        asking.remove(path)
        // A link not heard about is drawn as present, so only a change
        // from what was drawn is worth a redraw.
        let drawn = known[path]?.state ?? .present
        if known.count >= limit { known.removeAll(keepingCapacity: true) }
        known[path] = (state, Date())
        let announce = drawn != state && !announcing
        if announce { announcing = true }
        lock.unlock()
        guard announce else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.announcing = false
            self.lock.unlock()
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }
}

// MARK: - A click

/// What a click on a file link does, decided when it is clicked. A
/// document opens in its default app; anything that would run, install or
/// mount when opened is only shown in Finder — the words a reply put on a
/// link may say anything, and an agent's reply can be steered by what it
/// read.
enum FileLinkAction: Equatable {
    /// A document, in its default app.
    case open(URL)
    /// Text macOS has no viewer for, or one that cannot read it (`.ts` is
    /// an MPEG-2 stream to macOS, and `.rs` nothing at all), in the default
    /// app for plain text — shown, never run.
    case openAsText(URL)
    /// Selected in a Finder window, not opened.
    case reveal(URL)
    /// A folder, opened in Finder.
    case showFolder(URL)
    case missing

    /// Reads the file system: call it off the main thread.
    static func decide(path: String) -> FileLinkAction {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        let real = url.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isRegularFileKey, .contentTypeKey]
        guard let values = try? real.resourceValues(forKeys: keys) else { return .missing }
        if values.isDirectory == true {
            let runs = values.isPackage == true || values.contentType.map(runsWhenOpened) == true
            return runs ? .reveal(url) : .showFolder(real)
        }
        guard values.isRegularFile == true, let type = values.contentType, !runsWhenOpened(type) else {
            return .reveal(url)
        }
        if opensAsDocument(type) {
            if type.conforms(to: .audiovisualContent), looksLikeText(real) { return .openAsText(real) }
            return .open(real)
        }
        return looksLikeText(real) ? .openAsText(real) : .reveal(url)
    }

    /// An app, a script, an installer, a disk image, an archive: what
    /// opening starts something rather than shows something.
    static func runsWhenOpened(_ type: UTType) -> Bool {
        [UTType.application, .executable, .script, .package, .bundle, .diskImage, .archive]
            .contains { type.conforms(to: $0) }
    }

    /// Types whose default app shows them. Plain text, never text at
    /// large: a configuration profile is XML (so text) and its default app
    /// installs it.
    static func opensAsDocument(_ type: UTType) -> Bool {
        [UTType.plainText, .json, .yaml, .html, .rtf, .pdf, .image, .audiovisualContent]
            .contains { type.conforms(to: $0) }
    }

    /// UTF-8 with no NUL in its first 8 KB (a character cut at the end of
    /// the read is still text).
    static func looksLikeText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8192) else { return false }
        guard !head.contains(0) else { return false }
        for cut in 0...min(3, head.count) where String(data: head.dropLast(cut), encoding: .utf8) != nil {
            return true
        }
        return false
    }
}

/// Acts on a file link a reply drew: decides off the main thread, then
/// opens or shows the file.
enum FileLinkOpener {
    static func open(_ url: URL) {
        guard let path = FileLinkURL.path(of: url) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let action = FileLinkAction.decide(path: path)
            DispatchQueue.main.async { perform(action) }
        }
    }

    private static func perform(_ action: FileLinkAction) {
        let workspace = NSWorkspace.shared
        switch action {
        case .open(let url):
            if !workspace.open(url) { workspace.activateFileViewerSelecting([url]) }
        case .openAsText(let url):
            guard let editor = workspace.urlForApplication(toOpen: .plainText) else {
                workspace.activateFileViewerSelecting([url])
                return
            }
            workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        case .reveal(let url):
            workspace.activateFileViewerSelecting([url])
        case .showFolder(let url):
            workspace.selectFile(nil, inFileViewerRootedAtPath: url.path)
        case .missing:
            NSSound.beep()
        }
    }
}

// MARK: - Views

private struct FileLinkBaseKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The folder a reply's relative file links are read from: the agent
    /// session's own folder, set on its transcript. Nil in a chat and a
    /// note, where a relative link is shown as text.
    var sipFileLinkBase: String? {
        get { self[FileLinkBaseKey.self] }
        set { self[FileLinkBaseKey.self] = newValue }
    }
}

private struct FileLinkHandling: ViewModifier {
    @Environment(\.openURL) private var outer

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                if FileLinkURL.path(of: url) != nil {
                    FileLinkOpener.open(url)
                } else {
                    outer(url)
                }
                return .handled
            })
            .environment(\.linkHotspotBehavior, FileLinkURL.hotspotBehavior)
    }
}

extension View {
    /// File links drawn in this view open through `FileLinkOpener`, and
    /// their regions follow `FileLinkURL.hotspotBehavior`; every other link
    /// goes where the `openURL` around this view sends it.
    func opensFileLinks() -> some View {
        modifier(FileLinkHandling())
    }

    /// Draws `text` again when a file one of its links names is found
    /// there or missing (`FileLinkPresence` answers after the first
    /// drawing). `tick` is the view's own state, read by its body.
    @ViewBuilder
    func redrawsOnFilePresence(_ text: AttributedString, tick: Binding<Int>) -> some View {
        if FileLinkURL.appears(in: text) {
            onReceive(NotificationCenter.default.publisher(for: FileLinkPresence.changed)) { _ in
                tick.wrappedValue &+= 1
            }
        } else {
            self
        }
    }
}
