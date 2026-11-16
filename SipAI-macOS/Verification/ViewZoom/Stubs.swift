// The one thing MarkdownRenderer.swift reads that lives in a view file.
//
// `ChatDesign` sits in ChatView.swift, so compiling the real one would
// pull in most of the app. Nothing checked here reads these colours —
// the stand-in exists only so the REAL renderer, which the note document
// is built with, will compile.
//
// Nothing in this directory is part of the app target.
import SwiftUI

enum ChatDesign {
    static let blue = Color.blue
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
}
