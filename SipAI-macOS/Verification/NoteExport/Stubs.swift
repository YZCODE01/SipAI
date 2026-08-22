// The one thing MarkdownRenderer.swift reads that lives in a view file.
//
// `ChatDesign` sits in ChatView.swift, so compiling the real one would
// pull in most of the app. Nothing here reaches the output being
// checked: `NoteHTML` writes its own CSS and never consults these — the
// stand-in exists only so the REAL block parser will compile.
//
// Nothing in this directory is part of the app target.
import SwiftUI

enum ChatDesign {
    static let blue = Color(red: 37/255, green: 99/255, blue: 235/255)
    static let textPrimary = Color.primary
}
