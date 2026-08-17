// Minimal stand-ins for the app types the search files reference, so
// the harness can exercise the REAL matcher and the REAL markdown
// renderer rather than a paraphrase of either.
//
// Only the members those files actually touch are kept. `SipDesign`
// and the two environment keys come from the real DesignSystem.swift,
// which the harness compiles; `ChatDesign` lives in ChatView.swift and
// would drag a whole view in, so its two used colours are stubbed here.
//
// Nothing in this directory is part of the app target.

import SwiftUI
import AppKit

enum ChatDesign {
    static let blue = Color.blue
    static let textPrimary = Color.primary
}
