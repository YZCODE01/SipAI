// NoteWebView.swift
// The note Preview pane, and the PDF exporter behind "Save as PDF".
//
// Both drive one `WKWebView` over the document `NoteHTML` builds, so a
// PDF is by construction the page the reader was just looking at. KaTeX
// is bundled and staged on disk — nothing here ever reaches the network,
// and the navigation policy below enforces that rather than trusting it.
//
// This is used for NOTES only. The chat and agent transcripts keep the
// SwiftUI `MarkdownRenderer`: they stream, they are searched with
// per-row highlight ordinals, and they re-render several times a second
// — none of which a web view is the right shape for. A note is a static
// document nobody searches in place, which is what makes this affordable
// here and nowhere else.

import SwiftUI
import WebKit
import AppKit
import CoreGraphics

// MARK: - Bundled KaTeX

/// Stages the bundled KaTeX assets somewhere a `file://` web view can
/// read them, and writes the generated HTML alongside.
///
/// The staging copy exists because `loadFileURL(_:allowingReadAccessTo:)`
/// grants read access to ONE directory subtree: the HTML and the assets
/// it references have to live under a shared root, and the app bundle is
/// not writable. It is re-derivable, so it goes in the temporary
/// directory rather than Application Support — nothing here is user data
/// and the factory reset has no business knowing about it.
enum KaTeXAssets {

    enum StagingError: Error { case missingBundleResources }

    private static var stagedRoot: URL?

    /// Directory holding `katex.min.css`, `katex.min.js` and `fonts/`.
    /// Copied on first use and reused for the rest of the launch.
    static func stagedDirectory() throws -> URL {
        if let root = stagedRoot,
           FileManager.default.fileExists(atPath: root.appendingPathComponent("katex.min.js").path) {
            return root
        }
        guard let bundled = Bundle.main.url(forResource: "katex", withExtension: nil) else {
            throw StagingError.missingBundleResources
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("SipAI-note-render", isDirectory: true)
        // A stale copy from a previous version would keep serving old
        // assets for the life of the install, so the tree is replaced
        // rather than merged.
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(atPath: bundled.path) {
            try fm.copyItem(at: bundled.appendingPathComponent(item),
                            to: root.appendingPathComponent(item))
        }
        // The bootstrap rides as a file, not an inline <script>, so the
        // document's CSP can refuse inline script outright — see
        // `NoteHTML.renderScript`.
        try NoteHTML.renderScript.write(
            to: root.appendingPathComponent("sipai-render.js"),
            atomically: true, encoding: .utf8)
        stagedRoot = root
        return root
    }

    /// Write `html` into the staging directory under `name` and return
    /// both the file and the root that has to be granted read access.
    static func write(html: String, name: String) throws -> (file: URL, root: URL) {
        let root = try stagedDirectory()
        let file = root.appendingPathComponent(name)
        try html.write(to: file, atomically: true, encoding: .utf8)
        return (file, root)
    }
}

// MARK: - Shared web-view plumbing

/// Navigation policy shared by the preview and the exporter.
///
/// Only the staged `file://` document may load. A clicked link is handed
/// to the system browser and only if its scheme passes the same gate the
/// SwiftUI renderer applies — a note is untrusted content and `[label]`
/// hides where a link actually goes, so `file:`, `smb:` and app schemes
/// must never reach `NSWorkspace`.
class NoteWebNavigationDelegate: NSObject, WKNavigationDelegate {

    var onFinish: (() -> Void)?

    /// The ONE document this view may load. Set by whoever performs the
    /// load, nil for the `loadHTMLString` fallback (which navigates to
    /// about:blank and must load no file at all). Content cannot
    /// navigate today — it has no script of its own and writes no forms
    /// — so this is the backstop that keeps a bare `.isFileURL` check
    /// from ever becoming a read of an arbitrary local path if one of
    /// those facts changes.
    var allowedFile: URL?

    private func isAllowedLoad(_ url: URL) -> Bool {
        guard let allowed = allowedFile else {
            return !url.isFileURL && url.absoluteString == "about:blank"
        }
        // The temp directory reaches WebKit through its /private
        // spelling, so compare resolved paths, not URLs.
        return url.isFileURL
            && url.standardizedFileURL.resolvingSymlinksInPath().path
                == allowed.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel); return
        }
        if navigationAction.navigationType == .linkActivated {
            if let safe = MarkdownInline.safeLink(url.absoluteString) {
                NSWorkspace.shared.open(safe)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(isAllowedLoad(url) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?()
    }
}

enum NoteWebFactory {
    static func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // KaTeX is JavaScript, so this cannot be switched off. Every
        // other door is shut instead: the CSP forbids network fetches,
        // the navigation policy cancels non-file loads, and every span
        // of note text is escaped before it reaches the document.
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.suppressesIncrementalRendering = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    /// Poll the page's readiness flag, set once every expression is laid
    /// out and the web fonts have loaded. Waiting on the flag rather
    /// than on `didFinish` is what stops a PDF being taken of a page
    /// whose equations are still un-rendered boxes.
    static func whenReady(_ web: WKWebView,
                          timeout: TimeInterval = 8,
                          then done: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            web.evaluateJavaScript(
                "document.documentElement.getAttribute('data-sipai-ready')"
            ) { value, _ in
                if (value as? String) == "1" { done(true); return }
                guard Date() < deadline else { done(false); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { poll() }
            }
        }
        poll()
    }
}

// MARK: - Preview pane

struct NoteWebView: NSViewRepresentable {
    let markdown: String
    let metadata: NoteHTML.Metadata
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let delegate = NoteWebNavigationDelegate()
        /// The document currently loaded. `updateNSView` runs on every
        /// body pass, so reloading unconditionally would restart the
        /// page — and throw away the reader's scroll position — several
        /// times a second.
        var loadedHTML: String?
    }

    func makeNSView(context: Context) -> WKWebView {
        let web = NoteWebFactory.makeWebView()
        web.navigationDelegate = context.coordinator.delegate
        load(web, coordinator: context.coordinator)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        load(web, coordinator: context.coordinator)
    }

    private func load(_ web: WKWebView, coordinator: Coordinator) {
        let html = NoteHTML.document(markdown: markdown,
                                     metadata: metadata,
                                     dark: dark,
                                     forPrint: false)
        guard coordinator.loadedHTML != html else { return }
        coordinator.loadedHTML = html
        guard let staged = try? KaTeXAssets.write(html: html, name: "preview.html") else {
            // Losing the staged assets must not blank the note. Render
            // the same document with no KaTeX rather than nothing: the
            // prose is intact and the expressions show as their source.
            coordinator.delegate.allowedFile = nil
            web.loadHTMLString(html, baseURL: nil)
            return
        }
        coordinator.delegate.allowedFile = staged.file
        web.loadFileURL(staged.file, allowingReadAccessTo: staged.root)
    }
}

// MARK: - PDF export

enum NotePDFExporter {

    enum ExportError: LocalizedError {
        case renderTimedOut
        case measurementFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .renderTimedOut:
                return String(localized: "The note took too long to lay out.",
                              comment: "PDF export failure reason")
            case .measurementFailed:
                return String(localized: "The note could not be measured for printing.",
                              comment: "PDF export failure reason")
            case .writeFailed:
                return String(localized: "The PDF could not be written.",
                              comment: "PDF export failure reason")
            }
        }
    }

    // US Letter, half-inch margins two ways.
    private static let paper = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 54
    private static var contentWidth: CGFloat { paper.width - margin * 2 }
    private static var contentHeight: CGFloat { paper.height - margin * 2 }

    /// Refuses to spend forever on a pathological document. A note this
    /// long is not something anyone is reading on paper.
    private static let pageLimit = 400

    /// Pagination is done HERE rather than by WebKit's own print path.
    ///
    /// `WKWebView.printOperation` cannot be used: measured on this
    /// platform it never converges — with every combination of
    /// pagination mode, view frame and window placement it span forever
    /// and wrote a PDF that passed 470 MB while still growing, on
    /// content one page tall, and did the same for a plain paragraph
    /// document with no KaTeX in it. `createPDF` is sound, so the page
    /// breaks are chosen here and each page is captured with an explicit
    /// `rect`.
    ///
    /// Breaks land in the GAP between two top-level blocks, so a page
    /// never ends inside a paragraph, a table or an equation — the thing
    /// a naive fixed-height slice gets wrong.
    @MainActor
    static func export(markdown: String,
                       metadata: NoteHTML.Metadata,
                       to destination: URL) async throws {
        let html = NoteHTML.document(markdown: markdown,
                                     metadata: metadata,
                                     dark: false,      // paper is white
                                     forPrint: true)

        let web = NoteWebFactory.makeWebView()
        web.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        let delegate = NoteWebNavigationDelegate()
        web.navigationDelegate = delegate

        // Hosted in an offscreen window because layout — the thing being
        // waited on — does not run for a view with no window.
        let window = NSWindow(contentRect: web.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }

        var stagedFile: URL?
        if let staged = try? KaTeXAssets.write(html: html, name: "export.html") {
            stagedFile = staged.file
            delegate.allowedFile = staged.file
            web.loadFileURL(staged.file, allowingReadAccessTo: staged.root)
        } else {
            delegate.allowedFile = nil
            web.loadHTMLString(html, baseURL: nil)
        }
        // The staged copy of the note's HTML is needed only for the
        // length of the export; a preview rewrites its own file per
        // open, but nothing would rewrite this one until the next
        // export, so it is removed rather than left in the temp dir.
        defer { if let stagedFile { try? FileManager.default.removeItem(at: stagedFile) } }

        guard await waitForReady(web, delegate: delegate) else {
            throw ExportError.renderTimedOut
        }
        guard let layout = await measure(web) else {
            throw ExportError.measurementFailed
        }

        var slices: [Data] = []
        for range in pageRanges(layout) {
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: 0, y: range.lowerBound,
                                 width: contentWidth,
                                 height: range.upperBound - range.lowerBound)
            if let data = try? await web.pdf(configuration: config) {
                slices.append(data)
            }
        }
        guard !slices.isEmpty else { throw ExportError.writeFailed }
        try compose(slices, to: destination)
    }

    // MARK: Readiness and measurement

    @MainActor
    private static func waitForReady(_ web: WKWebView,
                                     delegate: NoteWebNavigationDelegate) async -> Bool {
        await withCheckedContinuation { continuation in
            var resumed = false
            func finish(_ value: Bool) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            delegate.onFinish = { NoteWebFactory.whenReady(web) { finish($0) } }
            // A load that never finishes must not hang the export.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { finish(false) }
        }
    }

    /// Internal, not private: `pageRanges` is the one piece of the
    /// exporter that is pure arithmetic, and it stays reachable so it can
    /// be exercised without a web view.
    struct Layout {
        var total: CGFloat
        /// Top and bottom of every top-level block, relative to the
        /// content's own origin.
        var blocks: [(top: CGFloat, bottom: CGFloat)]
    }

    /// Ask the page where its blocks begin and end. A block taller than
    /// half a page is descended into, so one long table or list cannot
    /// force a mostly-empty page ahead of it.
    private static let measureScript = """
    (function () {
      var root = document.getElementById('sipai-note');
      if (!root) { return '{}'; }
      var origin = root.getBoundingClientRect().top;
      var spans = [];
      function walk(el, depth) {
        for (var i = 0; i < el.children.length; i++) {
          var c = el.children[i];
          var b = c.getBoundingClientRect();
          if (b.height <= 0) { continue; }
          if (b.height > 340 && depth < 3 && c.children.length > 1) {
            walk(c, depth + 1);
          } else {
            spans.push([b.top - origin, b.bottom - origin]);
          }
        }
      }
      walk(root, 0);
      return JSON.stringify({
        h: root.getBoundingClientRect().height,
        blocks: spans
      });
    })()
    """

    @MainActor
    private static func measure(_ web: WKWebView) async -> Layout? {
        guard let raw = try? await web.evaluateJavaScript(measureScript) as? String,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = obj["h"] as? Double
        else { return nil }
        let spans = (obj["blocks"] as? [[Double]] ?? []).compactMap {
            $0.count == 2 ? (top: CGFloat($0[0]), bottom: CGFloat($0[1])) : nil
        }
        return Layout(total: CGFloat(total), blocks: spans)
    }

    // MARK: Page breaks

    /// Greedy packing: fill a page with whole blocks, then break in the
    /// whitespace before the first block that would not fit.
    ///
    /// The break is placed BETWEEN two blocks rather than on a block's
    /// bottom edge, because a bottom edge is where a blockquote's rule
    /// or a code block's border still is — slicing exactly there leaves
    /// a stray line at the top of the next page.
    static func pageRanges(_ layout: Layout) -> [Range<CGFloat>] {
        let total = layout.total
        guard total > 0 else { return [] }
        let blocks = layout.blocks.sorted { $0.top < $1.top }

        var pages: [Range<CGFloat>] = []
        var start: CGFloat = 0

        while start < total - 0.5, pages.count < pageLimit {
            let limit = start + contentHeight
            // Everything that is left fits on this page.
            if limit >= total {
                pages.append(start..<total)
                break
            }
            var end = limit
            // The block a fixed cut at `limit` would slice through, and
            // the last one that ends cleanly before it.
            let overflowing = blocks.first { $0.top < limit && $0.bottom > limit }
            let lastFitting = blocks.last { $0.top >= start - 0.5 && $0.bottom <= limit }
            if let over = overflowing, let fit = lastFitting, fit.bottom > start + 1 {
                let gapTop = fit.bottom
                let gapBottom = max(gapTop, over.top)
                end = gapTop + (gapBottom - gapTop) / 2
            }
            // A single block taller than a whole page has no gap to
            // break in, so it is sliced at the page edge — the one case
            // where a cut can land inside content. `end` is already
            // `limit` for it, and for a page nothing overflows.
            if end <= start + 1 { end = limit }
            pages.append(start..<end)
            start = end
        }
        return pages.isEmpty ? [0..<total] : pages
    }

    // MARK: Composition

    /// Draw each captured slice onto its own US Letter page.
    private static func compose(_ slices: [Data], to destination: URL) throws {
        var mediaBox = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(url: destination as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw ExportError.writeFailed }

        var drew = false
        for data in slices {
            guard let provider = CGDataProvider(data: data as CFData),
                  let doc = CGPDFDocument(provider),
                  let page = doc.page(at: 1) else { continue }
            let box = page.getBoxRect(.mediaBox)
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // Slices hang from the top of the printable area, so a short
            // final page does not float in the middle of the sheet.
            ctx.translateBy(x: margin, y: paper.height - margin - box.height)
            ctx.drawPDFPage(page)
            ctx.restoreGState()
            ctx.endPDFPage()
            drew = true
        }
        ctx.closePDF()
        guard drew else {
            try? FileManager.default.removeItem(at: destination)
            throw ExportError.writeFailed
        }
    }
}
