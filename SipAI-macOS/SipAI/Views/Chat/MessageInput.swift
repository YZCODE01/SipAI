// MessageInput.swift
// The chat cards' text input. `AgentComposer.GrowingTextField` is the
// auto-growing twin used by the agent composer.

import SwiftUI
import AppKit

/// NSTextView wrapper for multi-line input in a fixed-height viewport.
/// Enter sends, Shift+Enter inserts a newline.
struct MultilineTextField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    /// Escape. Optional so the composer — where Escape means nothing —
    /// keeps AppKit's default behaviour; the inline branch editor passes
    /// it so abandoning an edit works the way every other inline editor
    /// in this app does (see the sidebar's rename row).
    var onCancel: (() -> Void)? = nil
    /// Take key focus on appear. For an editor that REPLACES something
    /// the user just clicked, which must not need a second click.
    var autoFocus: Bool = false
    /// `DisplaySettings.spellCheck`, passed by the owning view.
    var spellChecking: Bool
    /// Files dropped ON THE TEXT FIELD, handed to the host so a drag
    /// stages exactly what the + button stages. Set by the chat card;
    /// nil in the inline editors, where a dragged path is still typed
    /// in — see `DropForwardingTextView` for why interception, and not
    /// a filter, is what takes the drag off NSTextView.
    var onDropFiles: (([URL]) -> Void)? = nil
    /// Whether a file drag is currently over the text field, so the
    /// card can draw the same highlight it draws for the rest of its
    /// area. Without it the border tint dies over the one part of the
    /// card most drops are aimed at.
    var onDropTargeted: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = Self.makeScrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        applyDropHandlers(to: tv)
        tv.font = NSFont.systemFont(ofSize: 14)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textColor = NSColor.labelColor
        tv.insertionPointColor = NSColor.labelColor
        // The chat input card places the scroll view 8 pt from the leading
        // edge and 4 pt from the top, while its placeholder uses
        // 14 pt / 6 pt. Make the native offsets explicit so typed text
        // and the insertion point share that exact origin (8+6 = 14,
        // 4+2 = 6).
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = NSSize(width: 6, height: 2)
        TextInputSpellChecking.apply(spellChecking, to: tv)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        if autoFocus {
            // Deferred: the view has no window during makeNSView, so
            // there is no responder chain to join yet.
            DispatchQueue.main.async { [weak tv] in
                guard let tv, let window = tv.window else { return }
                window.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: tv.string.count,
                                            length: 0))
            }
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // The coordinator keeps the struct it was made with, so Enter
        // would drive a snapshot of the host taken when this text view
        // was built. `onSubmit` closes over the caller's guard — the
        // branch editor's `canCreate` reads a plain `busy` property —
        // and a frozen copy of that guard is a send key that is dead
        // when it should fire, or fires when it should be dead. Same
        // rule, same reason, as `SearchField`.
        context.coordinator.parent = self
        guard let tv = nsView.documentView as? NSTextView else { return }
        // Same rule, same reason: a drop closure captured when the text
        // view was BUILT stages into whatever the host looked like then.
        applyDropHandlers(to: tv)
        if tv.string != text {
            tv.string = text
        }
        TextInputSpellChecking.apply(spellChecking, to: tv)
    }

    /// `NSTextView.scrollableTextView()` builds the scroll view, the
    /// TextKit stack and a dozen layout properties at once. Hand-rolling
    /// that to get a subclass in drifts from it — measured, seven
    /// properties out, the text container's size among them. Build the
    /// stock stack and swap ONLY the document view, inheriting the
    /// configuration AppKit just made.
    private static func makeScrollableTextView() -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let stock = scroll.documentView as? NSTextView,
              let container = stock.textContainer else { return scroll }
        let tv = DropForwardingTextView(frame: stock.frame,
                                        textContainer: container)
        tv.autoresizingMask = stock.autoresizingMask
        tv.isVerticallyResizable = stock.isVerticallyResizable
        tv.isHorizontallyResizable = stock.isHorizontallyResizable
        tv.minSize = stock.minSize
        tv.maxSize = stock.maxSize
        tv.isRichText = stock.isRichText
        tv.usesFontPanel = stock.usesFontPanel
        scroll.documentView = tv
        return scroll
    }

    private func applyDropHandlers(to textView: NSTextView) {
        guard let tv = textView as? DropForwardingTextView else { return }
        tv.onDropFiles = onDropFiles
        tv.onDropTargeted = onDropTargeted
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineTextField
        init(_ parent: MultilineTextField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shift {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)),
               let onCancel = parent.onCancel {
                onCancel()
                return true
            }
            return false
        }
    }
}

// MARK: - File drops on the text field

/// The text view behind `MultilineTextField`, and it exists for one
/// reason: to take file drags away from NSTextView's own handler, which
/// answers a dropped file by typing its PATH in as characters.
///
/// Filtering the view's dragged types does NOT do it, however carefully.
/// A fresh text view is registered for nothing, and AppKit registers the
/// whole set — `NSFilenamesPboardType` and `public.url` included — when
/// the view enters a window and takes first responder. Any filter applied
/// while building the view is therefore already undone by the time
/// anything can be dropped on it, and NSTextView is then the deepest
/// registered view under the pointer, so it wins the drag outright and an
/// ancestor's drop target never sees the file.
///
/// So the drop is INTERCEPTED here and handed to the host, which stages it
/// through the same path the + button uses. A drag that carries no file
/// URL falls through to `super` untouched, so dragging TEXT keeps working;
/// and with `onDropFiles` nil this is a stock NSTextView, which is what
/// the inline editors want — there, a dragged path is the point.
final class DropForwardingTextView: NSTextView {
    /// Set = this view stages files. nil = leave file drags to AppKit.
    var onDropFiles: (([URL]) -> Void)?
    /// Reports a file drag entering and leaving, for the host's highlight.
    var onDropTargeted: ((Bool) -> Void)?

    /// File URLs on the drag's pasteboard, or empty for every other drag.
    /// `urlReadingFileURLsOnly` is what keeps a link dragged out of a
    /// browser being typed in as text, which is what it should do.
    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        guard onDropFiles != nil else { return [] }
        let objects = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !droppedFiles(sender).isEmpty else {
            return super.draggingEntered(sender)
        }
        onDropTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !droppedFiles(sender).isEmpty else {
            return super.draggingUpdated(sender)
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargeted?(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDropTargeted?(false)
        super.draggingEnded(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !droppedFiles(sender).isEmpty else {
            return super.prepareForDragOperation(sender)
        }
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        guard !files.isEmpty else { return super.performDragOperation(sender) }
        onDropTargeted?(false)
        onDropFiles?(files)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onDropTargeted?(false)
        super.concludeDragOperation(sender)
    }
}

// MARK: - Attachment chips

/// The files staged for the next message, drawn above the composer's
/// text field. Each chip names the file, its size and what it will
/// become, and carries the only control that removes it.
///
/// A chip is the RECEIPT for an attach. Before this row existed the
/// only feedback was a dismissible banner, so picking a file and seeing
/// nothing change was indistinguishable from the button not working.
struct AttachmentChipRow: View {
    let attachments: [ChatAttachment]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment) { onRemove(attachment.id) }
                }
            }
            .padding(.vertical, 1)
        }
        // The row must never grow the card: a long list scrolls
        // sideways rather than pushing the text field down the screen.
        .frame(height: 26)
    }
}

private struct AttachmentChip: View {
    let attachment: ChatAttachment
    let onRemove: () -> Void

    @State private var hovering = false

    private var icon: String {
        switch attachment.kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .text: return "doc.plaintext"
        }
    }

    /// The hover title states what the model will actually receive.
    /// The distinction is invisible otherwise and it decides whether a
    /// later turn still knows about the file.
    private var hint: String {
        switch attachment.kind {
        case .image:
            return String(localized: "\(attachment.name) — \(attachment.sizeLabel), sent as an image with this message",
                          comment: "Tooltip for an attached image chip")
        case .pdf:
            return String(localized: "\(attachment.name) — \(attachment.sizeLabel), sent as a document with this message",
                          comment: "Tooltip for an attached PDF chip")
        case .text:
            return String(localized: "\(attachment.name) — \(attachment.sizeLabel), its text is included in the message",
                          comment: "Tooltip for an attached text file chip")
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(SipDesign.textSecondary)
            Text(verbatim: attachment.name)
                .font(.system(size: 11))
                .foregroundColor(SipDesign.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)
            Text(verbatim: attachment.sizeLabel)
                .font(.system(size: 10))
                .foregroundColor(SipDesign.textHint)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(hovering ? SipDesign.textPrimary : SipDesign.textHint)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Remove attachment",
                         comment: "Tooltip for the ✕ on an attachment chip"))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(SipDesign.chipBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(SipDesign.borderLight, lineWidth: 1)
                )
        )
        .onHover { hovering = $0 }
        .help(hint)
    }
}
