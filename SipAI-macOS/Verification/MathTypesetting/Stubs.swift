// `MarkdownRenderer` and `MathDisplayBlock` reach for `ChatDesign`,
// which lives in ChatView.swift and would drag a whole view — and the
// app's whole model layer — in behind it. Its two used colours are
// stubbed here.
//
// Nothing in this directory is part of the app target.

import SwiftUI
import AppKit

enum ChatDesign {
    static let blue = Color.blue
    static let textPrimary = Color.primary
}
