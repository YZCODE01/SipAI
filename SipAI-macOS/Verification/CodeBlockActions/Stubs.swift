// `ChatDesign` lives in ChatView.swift, which would drag a whole view —
// and the app's model layer — in behind it. The renderer and the corner
// button read three of its colours; they are stood in for here.
//
// Nothing in this directory is part of the app target.

import SwiftUI
import AppKit

enum ChatDesign {
    static let blue = Color.blue
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
}
