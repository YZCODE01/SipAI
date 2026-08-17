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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
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
        if tv.string != text {
            tv.string = text
        }
        TextInputSpellChecking.apply(spellChecking, to: tv)
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
