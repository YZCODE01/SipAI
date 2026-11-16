// What the real DisplayPane reads beyond DesignSystem.swift, AppTheme and
// DisplaySettings: the two managers it reads and writes through, as plain
// holders, and the Compact view switch's words.
//
// Nothing in this directory is part of the app target.
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var theme: AppTheme = .system
}

@MainActor
final class ConfigManager: ObservableObject {
    @Published private(set) var display = DisplaySettings()
    @Published private(set) var appTheme: AppTheme = .system

    var fontTier: FontTier { FontTier(rawValue: display.fontTier) ?? .standard }

    func setDisplay(_ block: (inout DisplaySettings) -> Void) { block(&display) }
    func setFontTier(_ tier: FontTier) { setDisplay { $0.fontTier = tier.rawValue } }
    func setTheme(_ theme: AppTheme) { appTheme = theme }
}

enum CompactViewWords {
    static var switchLabel: String { "Compact view" }
}
