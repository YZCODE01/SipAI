// ZoomCommands.swift
// View → Zoom In / Zoom Out / Actual Size: Settings → Display → Zoom one
// size at a time, from anywhere in the app.

import SwiftUI
import AppKit

/// What the zoom items read and move: the one size setting.
@MainActor
protocol ZoomSetting: ObservableObject {
    var fontTier: FontTier { get }
    func setFontTier(_ tier: FontTier)
}

/// One press of Zoom In, Zoom Out or Actual Size.
enum ZoomStep {
    case zoomIn, zoomOut, actualSize

    /// The size this step goes to from `tier`, or nil where there is none
    /// — the largest size for Zoom In, the smallest for Zoom Out, Default
    /// for Actual Size.
    func target(from tier: FontTier) -> FontTier? {
        switch self {
        case .zoomIn: return tier.zoomedIn
        case .zoomOut: return tier.zoomedOut
        case .actualSize: return tier == .actualSize ? nil : .actualSize
        }
    }
}

extension ZoomSetting {
    /// Takes `step` from the size in force NOW; false where there is no
    /// step to take.
    @discardableResult
    func zoom(_ step: ZoomStep) -> Bool {
        guard let target = step.target(from: fontTier) else { return false }
        setFontTier(target)
        return true
    }
}

/// The three View-menu items. They move the ONE size setting, so the
/// picker in Settings → Display always names the size on screen; a zoom
/// of their own on top would compound with it, and Settings would name a
/// size nobody sees.
///
/// The items OBSERVE the setting rather than being handed its value, and
/// each action steps from the size in force when it runs: a menu built
/// from the App's body is not rebuilt each time an object the App holds
/// changes, so a value handed in goes stale and a press would step from the
/// size the menu was built at.
struct ZoomMenuItems<Setting: ZoomSetting>: View {
    @ObservedObject var setting: Setting

    var body: some View {
        let tier = setting.fontTier
        Button(String(localized: "Zoom In",
                      comment: "View menu: one size larger — text and line spacing (Settings → Display → Zoom)")) {
            setting.zoom(.zoomIn)
        }
        // Drawn as ⌘+; the keys themselves are `ZoomKeys`'.
        .keyboardShortcut("+", modifiers: .command)
        .disabled(ZoomStep.zoomIn.target(from: tier) == nil)

        Button(String(localized: "Zoom Out",
                      comment: "View menu: one size smaller — text and line spacing (Settings → Display → Zoom)")) {
            setting.zoom(.zoomOut)
        }
        .keyboardShortcut("-", modifiers: .command)
        .disabled(ZoomStep.zoomOut.target(from: tier) == nil)

        Button(String(localized: "Actual Size",
                      comment: "View menu: back to the Default size (Settings → Display → Zoom)")) {
            setting.zoom(.actualSize)
        }
        .keyboardShortcut("0", modifiers: .command)
        .disabled(ZoomStep.actualSize.target(from: tier) == nil)
    }
}

/// The zoom keys, answered by a local monitor before the menu sees them.
///
/// Two reasons. A menu shortcut is matched by the character
/// the key types, and + takes Shift on most keyboards: the ⌘+ item answers
/// ⌘⇧= and the keypad's +, never plain ⌘=, the key people press. And
/// SwiftUI does not refresh a menu item's greyed state on every change of
/// the setting (not at all while the app is in the background), so a
/// shortcut left to the menu can be swallowed by an item greyed for the
/// size before — a quick Zoom In, Zoom Out at the smallest size. Here every
/// press steps from the size in force. Where there is no step to take, the
/// key goes on to the menu, as a greyed-out item would leave it.
enum ZoomKeys {
    private static var monitor: Any?

    /// Installed once, for the life of the app. `zoom` answers whether
    /// there was a step to take.
    static func install(zoom: @escaping @MainActor (ZoomStep) -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let step = step(for: event) else { return event }
            // Local monitors fire on the main thread.
            return MainActor.assumeIsolated { zoom(step) } ? nil : event
        }
    }

    /// ⌘ with =, + (Shift allowed, as + needs it on most keyboards), − or
    /// 0, the keypad's included; Caps Lock aside, nothing else held.
    static func step(for event: NSEvent) -> ZoomStep? {
        let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        switch event.charactersIgnoringModifiers {
        case "=" where held == .command: return .zoomIn
        case "+" where held == .command || held == [.command, .shift]: return .zoomIn
        case "-" where held == .command: return .zoomOut
        case "0" where held == .command: return .actualSize
        default: return nil
        }
    }
}
