// Minimal stand-ins for the app types the renderer references, so the
// harness can exercise the REAL `MarkdownRenderer` rather than a
// paraphrase of it. `SipDesign`, `SipFont` and the two environment keys
// come from the real DesignSystem.swift, which the harness compiles;
// `ChatDesign` lives in ChatView.swift and would drag a whole view in,
// so its three used colours are stubbed here — the same stub
// TranscriptSearch uses.
//
// Nothing in this directory is part of the app target.

import SwiftUI
import AppKit

enum ChatDesign {
    static let blue = Color.blue
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
}
