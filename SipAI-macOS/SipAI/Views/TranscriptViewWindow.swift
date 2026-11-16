// TranscriptViewWindow.swift
// How agent sessions are drawn: the toolbar's window (an icon between the
// search glyph and the plan-usage coin), the View menu's Agent Session
// Compact View item, and the words both share with Settings → Display. One
// setting behind all three, `DisplaySettings.agentCompactView`.
//
// The window is presented as an OVERLAY under its button, the way the
// search palette and the plan-usage window are, over a click-anywhere-else
// scrim. Escape closes it too.

import SwiftUI

/// What the switch and the menu item read and move: the one setting.
@MainActor
protocol CompactViewSetting: ObservableObject {
    var agentCompactView: Bool { get }
    func setAgentCompactView(_ on: Bool)
}

/// The words, spelled once for the window, the menu and the toolbar button.
enum CompactViewWords {
    /// The window's title, and its button's tooltip and VoiceOver name —
    /// one string, so the two can never say different things.
    static var title: String {
        String(localized: "Agent session view",
               comment: "Title of the toolbar window that sets how agent sessions are drawn; also the tooltip and VoiceOver name of its toolbar button")
    }

    static var switchLabel: String {
        String(localized: "Compact view",
               comment: "Switch in the toolbar's agent session window and in Settings → Display → Agent sessions: draw each of the agent's answers as one line, its final message under it")
    }

    static var description: String {
        String(localized: "Shows each answer’s thinking, tool calls and messages as one line, with its final message under it. Click a line to see its steps.",
               comment: "Line under the Compact view switch (toolbar window and Settings → Display)")
    }

    /// Says what it is — a way of viewing — and what it applies to. A
    /// name that opens on "Compact" reads as an action on a session: in
    /// the agents' own words to compact is to summarise a conversation
    /// (`/compact`).
    static var menuItem: String {
        String(localized: "Agent Session Compact View",
               comment: "View menu item with a checkmark: the Compact view switch for every agent session (Settings → Display → Agent sessions); a way of viewing sessions, not an action that summarises them")
    }
}

/// The toolbar's window: a title, the switch and the line saying what it
/// does.
struct TranscriptViewWindow<Setting: CompactViewSetting>: View {
    @ObservedObject var setting: Setting
    @Binding var isPresented: Bool
    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.sipLineSpacingFactor) private var lineSpacingFactor
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: CompactViewWords.title)
                .sipFont(13, weight: .semibold)
                .foregroundColor(SipDesign.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider().opacity(0.4)
            // The tier's rhythm for the wrapped line: its line spacing, and
            // the gap above it by its line pitch (`SipFont.gapScale`).
            VStack(alignment: .leading,
                   spacing: 6 * SipFont.gapScale(12, fontScale: fontScale,
                                                 lineSpacingFactor: lineSpacingFactor)) {
                HStack {
                    Text(verbatim: CompactViewWords.switchLabel)
                        .sipFont(13)
                        .foregroundColor(SipDesign.textPrimary)
                    Spacer()
                    Toggle(isOn: Binding(
                        get: { setting.agentCompactView },
                        set: { setting.setAgentCompactView($0) }
                    )) {
                        Text(verbatim: CompactViewWords.switchLabel)
                    }
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                Text(verbatim: CompactViewWords.description)
                    .sipFont(12)
                    .foregroundColor(SipDesign.textSecondary)
                    .lineSpacing(SipFont.lineSpacing(12, fontScale: fontScale,
                                                     lineSpacingFactor: lineSpacingFactor))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        // A switch steps with the tier rather than scaling with it.
        .controlSize(SipFont.controlSize(fontScale))
        .frame(width: min(300 * SipFont.ratio(fontScale), 480))
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(SipDesign.surface)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(SipDesign.borderLight, lineWidth: 1)
        )
        // Focus is what lets Escape reach the window; the ring it would
        // draw is not wanted on a card.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onAppear { focused = true }
    }
}

/// View → Agent Session Compact View, with a checkmark.
///
/// It OBSERVES the setting, for `ZoomMenuItems`' reason: a menu built from
/// the App's body is not rebuilt each time an object the App holds
/// changes. And a press flips the value in force when it runs, whatever
/// the item last drew: SwiftUI does not refresh a menu item on every
/// change, and a toggle that set the opposite of a stale checkmark would
/// set what is already there.
struct CompactViewMenuItem<Setting: CompactViewSetting>: View {
    @ObservedObject var setting: Setting

    var body: some View {
        Toggle(CompactViewWords.menuItem, isOn: Binding(
            get: { setting.agentCompactView },
            set: { _ in setting.setAgentCompactView(!setting.agentCompactView) }
        ))
        .keyboardShortcut("o", modifiers: [.command, .control])
    }
}
