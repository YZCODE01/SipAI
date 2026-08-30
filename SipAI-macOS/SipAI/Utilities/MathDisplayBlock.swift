// MathDisplayBlock.swift
// The view a `.displayMath` block renders as, plus the cache that keeps
// typesetting off the streaming path.
//
// A transcript re-renders several times a second while a reply streams,
// and every visible block's body runs on each pass. Parsing and laying
// out an equation on every one of those would be the same mistake the
// markdown parse cache exists to prevent, so a laid-out box is memoised
// by (source, point size) and every later pass is a dictionary hit.
//
// Nothing here is asynchronous. A display equation is drawn in the same
// pass as the paragraph above it, which is the whole reason this is a
// native typesetter and not an image service.

import AppKit
import SwiftUI

// MARK: - View

struct MathDisplayBlock: View {
    let latex: String

    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.colorScheme) private var colorScheme

    /// Width this block was last OFFERED. Read off the full-width
    /// container, which reports the proposal rather than what the
    /// equation drew — measuring the equation would let a wide one
    /// report its own width as the width available to it and never come
    /// back down.
    @State private var availableWidth: CGFloat = 0

    /// Display equations are set a little larger than body text, the way
    /// a printed page sets them.
    private var pointSize: CGFloat { 16 * fontScale }

    /// Below this the type is too small to read, so the equation scrolls
    /// instead of shrinking further.
    private static let minimumScale: CGFloat = 0.55

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .center)
            // An equation is laid out at its natural width, which can
            // exceed the pane. `maxWidth: .infinity` keeps it from
            // WIDENING the transcript, and this keeps it from drawing
            // over the paragraphs beside it in the pass before the width
            // is known. Nothing is ever hidden waiting for geometry —
            // that is how a transcript gets stranded blank.
            .clipped()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                availableWidth = width
            }
            .contextMenu {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(latex, forType: .string)
                } label: {
                    Label(String(localized: "Copy LaTeX",
                                 comment: "Context-menu item on a typeset equation; copies its LaTeX source"),
                          systemImage: "doc.on.doc")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let box = MathRenderCache.shared.box(for: latex, size: pointSize) {
            typeset(box)
        } else {
            // No math font, or nothing parsed out of the source. The
            // Unicode approximation is what chats rendered before this
            // existed, so the floor never drops below where it was.
            MarkdownInlineText(latex)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func typeset(_ box: MathBox) -> some View {
        let natural = CGSize(width: box.width, height: box.height)
        let raw = availableWidth > 0 ? availableWidth / max(natural.width, 1) : 1
        let scale = max(Self.minimumScale, min(1, raw))
        let drawn = CGSize(width: natural.width * scale, height: natural.height * scale)
        let canvas = MathCanvas(box: box, ink: ink, errorInk: Self.errorInk)
            .frame(width: natural.width, height: natural.height)
            .scaleEffect(scale, anchor: .center)
            .frame(width: drawn.width, height: drawn.height)

        if availableWidth > 0 && drawn.width > availableWidth {
            // Past the readable floor. Scrolling keeps every term
            // reachable; shrinking further would keep none of them
            // legible. A horizontal scroll view takes the width it is
            // offered rather than its content's, so this cannot feed
            // back into the measurement above.
            ScrollView(.horizontal) { canvas }
                .scrollIndicators(.hidden)
                .frame(height: drawn.height)
        } else {
            canvas
        }
    }

    /// Resolved against the scheme this view is drawing in rather than
    /// against whatever appearance happens to be current inside the
    /// canvas's draw call.
    private var ink: CGColor {
        var resolved = NSColor.textColor.cgColor
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)?
            .performAsCurrentDrawingAppearance {
                resolved = NSColor(ChatDesign.textPrimary).cgColor
            }
        return resolved
    }

    /// The tint an unimplemented command is drawn in — the same red the
    /// note renderer gives KaTeX's own parse errors, so one kind of
    /// failure reads one way across the app. Fixed in both appearances,
    /// like that one.
    private static let errorInk = CGColor(srgbRed: 179 / 255, green: 29 / 255,
                                          blue: 40 / 255, alpha: 1)
}

// MARK: - Canvas

/// Draws one laid-out box. Split out so the drawing closure captures a
/// box and two colours and nothing else — a `Canvas` closure that closed
/// over the whole view would re-run for every unrelated state change.
private struct MathCanvas: View {
    let box: MathBox
    let ink: CGColor
    let errorInk: CGColor

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            context.withCGContext { cg in
                cg.saveGState()
                cg.textMatrix = .identity
                // Boxes are measured from a baseline with Y pointing UP;
                // the canvas hands over a Y-DOWN context. One flip here
                // is what lets every measurement above stay in the
                // orientation the typography is described in.
                cg.translateBy(x: 0, y: box.ascent)
                cg.scaleBy(x: 1, y: -1)
                box.draw(in: cg, color: ink, errorColor: errorInk)
                cg.restoreGState()
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Cache

/// Laid-out equations, keyed by source and point size.
///
/// Bounded and evicted in slices rather than cleared wholesale: a
/// wholesale clear turns the limit into a cliff, where a transcript
/// whose visible window alone approaches it evicts its own rows and
/// re-lays every one of them on the very next render pass.
final class MathRenderCache {
    static let shared = MathRenderCache()

    private struct Key: Hashable {
        let latex: String
        /// Quantised: a font-scale multiplication lands on values that
        /// differ in the last bits, and an unquantised key would make
        /// every pass a miss.
        let size: Int
    }

    private var boxes: [Key: MathBox?] = [:]
    private var order: [Key] = []
    private let lock = NSLock()
    private let limit = 256
    private let evictionShare = 4

    /// nil when the math font is missing or nothing parsed — the caller
    /// falls back to text. A nil is CACHED, so a source that cannot be
    /// typeset is not re-parsed on every render pass.
    func box(for latex: String, size: CGFloat) -> MathBox? {
        let key = Key(latex: latex, size: Int((size * 4).rounded()))
        lock.lock()
        if let hit = boxes[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let quantised = CGFloat(key.size) / 4
        var value: MathBox? = nil
        if let typesetter = MathTypesetter(size: quantised),
           let list = MathParser.parse(latex) {
            let box = typesetter.layout(list, style: .display)
            // A box with no extent draws nothing; the text fallback at
            // least shows the reader what was there.
            if box.width > 0 && box.height > 0 { value = box }
        }

        lock.lock()
        if boxes.count >= limit {
            let drop = max(1, limit / evictionShare)
            for stale in order.prefix(drop) { boxes.removeValue(forKey: stale) }
            order.removeFirst(min(drop, order.count))
        }
        if boxes.updateValue(value, forKey: key) == nil { order.append(key) }
        lock.unlock()
        return value
    }
}
