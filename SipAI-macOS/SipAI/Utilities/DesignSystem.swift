// DesignSystem.swift
// Shared design tokens for SipAI: colors (with light/dark variants), applied
// across onboarding and the rest of the UI. The shared palette every view
// references.
//
// This and `ChatDesign` (Views/Chat/ChatView.swift) are the ONLY palettes.
// Do not reintroduce a shadow palette: an unreferenced token is not a
// spare, it is the next inconsistency.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Project-wide design tokens.
///
/// All colors are adaptive where a dark-mode variant matters, so any text or
/// surface that uses these tokens automatically re-renders correctly when the
/// user flips between light and dark mode.
enum SipDesign {

    // MARK: - Brand

    /// Primary brand accent — intentionally the same in both light and dark mode.
    static let blue = Color(red: 37/255, green: 99/255, blue: 235/255) // #2563EB

    /// Pointer-over shade of `blue`, one step down the same ramp
    /// (#2563EB is Tailwind blue-600, this is blue-700). Fixed in both
    /// appearances for the same reason `blue` is: it sits on a filled
    /// button whose label is always white.
    static let blueHover = Color(red: 29/255, green: 78/255, blue: 216/255) // #1D4ED8

    // MARK: - Helper

    /// Build a SwiftUI `Color` that resolves to `light` in aqua appearance and
    /// `dark` in darkAqua.
    private static func dyn(_ name: String, light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: name, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }))
    }

    // MARK: - Text

    /// Primary label color. #1D1D1F in light, near-white in dark.
    /// 0.95 opacity softens against the background.
    static let textPrimary = dyn("SipAITextPrimary",
        light: NSColor(srgbRed: 29/255,  green: 29/255,  blue: 31/255,  alpha: 1),
        dark:  NSColor(srgbRed: 245/255, green: 245/255, blue: 247/255, alpha: 1)
    ).opacity(0.95)

    /// Secondary label color — subtitles, descriptions. #86868B in light.
    static let textSecondary = dyn("SipAITextSecondary",
        light: NSColor(srgbRed: 134/255, green: 134/255, blue: 139/255, alpha: 1),
        dark:  NSColor(srgbRed: 160/255, green: 160/255, blue: 168/255, alpha: 1)
    ).opacity(0.95)

    /// Tertiary hint color — placeholder text, low-emphasis captions. #AEAEB2 in light.
    static let textHint = dyn("SipAITextHint",
        light: NSColor(srgbRed: 174/255, green: 174/255, blue: 178/255, alpha: 1),
        dark:  NSColor(srgbRed: 120/255, green: 120/255, blue: 128/255, alpha: 1)
    )

    // MARK: - Surfaces

    /// Primary surface — cards, text fields, elevated panels. White in light,
    /// elevated dark-grey panel in dark.
    static let surface = dyn("SipAISurface",
        light: NSColor.white,
        dark:  NSColor(srgbRed: 44/255, green: 44/255, blue: 46/255, alpha: 1)
    )

    /// Slightly tinted surface for softer containers like saved-model rows. #F9FAFB in light.
    static let surfaceMuted = dyn("SipAISurfaceMuted",
        light: NSColor(srgbRed: 249/255, green: 250/255, blue: 251/255, alpha: 1),
        dark:  NSColor(srgbRed: 58/255,  green: 58/255,  blue: 60/255,  alpha: 1)
    )

    /// Legacy alias for `surfaceMuted`, kept for existing call sites.
    static let cardBg = surfaceMuted

    // MARK: - Borders

    /// Standard 1px border / divider stroke. #E5E7EB in light.
    static let borderLight = dyn("SipAIBorder",
        light: NSColor(srgbRed: 229/255, green: 231/255, blue: 235/255, alpha: 1),
        dark:  NSColor(srgbRed: 72/255,  green: 72/255,  blue: 76/255,  alpha: 1)
    )

    // MARK: - Accent tints

    /// Selected-state background — light blue in light, muted dark-blue in dark.
    static let cardSelectedBg = dyn("SipAICardSelectedBg",
        light: NSColor(srgbRed: 240/255, green: 246/255, blue: 255/255, alpha: 1), // #F0F6FF
        dark:  NSColor(srgbRed: 30/255,  green: 45/255,  blue: 80/255,  alpha: 1)
    )

    /// Background for circular feature icons. #EBF3FE in light.
    static let iconCircleBg = dyn("SipAIIconBg",
        light: NSColor(srgbRed: 235/255, green: 243/255, blue: 254/255, alpha: 1),
        dark:  NSColor(srgbRed: 30/255,  green: 45/255,  blue: 80/255,  alpha: 1)
    )

    /// Neutral chip / badge background. #F0F0F0 in light.
    static let chipBg = dyn("SipAIChipBg",
        light: NSColor(srgbRed: 240/255, green: 240/255, blue: 240/255, alpha: 1),
        dark:  NSColor(srgbRed: 62/255,  green: 62/255,  blue: 66/255,  alpha: 1)
    )

    // MARK: - Search highlights

    /// Every match of the current find query. A wash, not a solid fill:
    /// it goes UNDER body text that keeps its own colour (links stay
    /// blue, inline code stays sky), so it has to tint without
    /// competing.
    static let searchMatch = dyn("SipAISearchMatch",
        light: NSColor(srgbRed: 255/255, green: 214/255, blue: 10/255,  alpha: 0.45),
        dark:  NSColor(srgbRed: 255/255, green: 214/255, blue: 10/255,  alpha: 0.30)
    )

    /// The one match the "3 of 47" counter is naming right now. Stronger
    /// AND a different hue — with one shade for both, stepping through
    /// matches would move a highlight the eye cannot follow.
    static let searchMatchActive = dyn("SipAISearchMatchActive",
        light: NSColor(srgbRed: 255/255, green: 138/255, blue: 0/255, alpha: 0.75),
        dark:  NSColor(srgbRed: 255/255, green: 149/255, blue: 0/255, alpha: 0.65)
    )
}

// MARK: - Font size tiers

/// User-selectable font sizing (Settings → Display → Font Size). Applies
/// to sidebar list names and chat/agent content. `scale` multiplies the
/// base sizes the views were designed with ("Small" IS the original
/// design); line spacing grows with the tier, and Large-text mode adds a
/// full extra line height — i.e. double line spacing.
enum FontTier: String, CaseIterable, Identifiable {
    case small
    case standard = "default"
    case larger
    case xlarge

    var id: String { rawValue }

    var localizedName: LocalizedStringKey {
        switch self {
        case .small: return "Small"
        case .standard: return "Default"
        case .larger: return "Larger"
        case .xlarge: return "Large text mode"
        }
    }

    /// Multiplier applied to base font sizes.
    var scale: CGFloat {
        switch self {
        case .small: return 1.0
        case .standard: return 1.1
        case .larger: return 1.25
        case .xlarge: return 1.45
        }
    }

    /// Extra spacing between wrapped lines, as a fraction of the scaled
    /// font size. 1.2 ≈ one full line height on top of the normal one.
    var lineSpacingFactor: CGFloat {
        switch self {
        case .small: return 0.10
        case .standard: return 0.18
        case .larger: return 0.40
        case .xlarge: return 1.2
        }
    }
}

/// Type sizes that don't simply track the chat-content bases. The
/// sidebar deliberately runs more compact than chat content, with a
/// three-step hierarchy at the Default tier — 13 pt row names, 12 pt
/// SECTION HEADERS (semibold caps at 12 carry the optical mass of a
/// regular 13), 11 pt hints/metadata — scaling proportionally on the
/// other tiers (the division normalizes the tier multiplier so Default
/// lands exactly on the design size).
enum SipFont {
    /// Sidebar row/name size — 13 pt at the Default tier.
    static func sidebarRow(_ fontScale: CGFloat) -> CGFloat {
        13 * fontScale / FontTier.standard.scale
    }
    /// Sidebar section-header size (semibold, uppercased) — 12 pt at
    /// the Default tier.
    static func sidebarHeader(_ fontScale: CGFloat) -> CGFloat {
        12 * fontScale / FontTier.standard.scale
    }
    /// Sidebar placeholder/status/metadata size — 11 pt at the Default
    /// tier.
    static func sidebarHint(_ fontScale: CGFloat) -> CGFloat {
        11 * fontScale / FontTier.standard.scale
    }

    /// Substitute `\.sipFontScale` for message transcripts (chat AND
    /// agent sessions): derived so the shared markdown renderer's 14 pt
    /// base lands exactly on `sidebarRow` — transcript text is never
    /// larger than the row names in the sidebar (13 pt at Default;
    /// tool/output rows land one step lower at ~12 pt). Changing
    /// `sidebarRow`'s base moves all of them together.
    static func contentScale(_ fontScale: CGFloat) -> CGFloat {
        sidebarRow(fontScale) / 14
    }
}

private struct SipFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

private struct SipLineSpacingFactorKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0.10
}

extension EnvironmentValues {
    /// Multiplier for base font sizes, injected from the configured
    /// `FontTier` at the ContentView root.
    var sipFontScale: CGFloat {
        get { self[SipFontScaleKey.self] }
        set { self[SipFontScaleKey.self] = newValue }
    }
    /// Extra line spacing as a fraction of the scaled font size, for
    /// multi-line chat/agent text.
    var sipLineSpacingFactor: CGFloat {
        get { self[SipLineSpacingFactorKey.self] }
        set { self[SipLineSpacingFactorKey.self] = newValue }
    }
}

// MARK: - Spell checking

/// Spelling squiggles for the app's own NSTextView surfaces, driven by
/// `DisplaySettings.spellCheck`. Contract in CLAUDE.md, "Typo check".
@MainActor
enum TextInputSpellChecking {
    static func apply(_ enabled: Bool, to textView: NSTextView) {
        textView.isGrammarCheckingEnabled = false
        guard textView.isContinuousSpellCheckingEnabled != enabled else { return }
        textView.toggleContinuousSpellChecking(nil)
    }
}

// MARK: - In-place edit field behaviours

/// Select the whole text of the field that currently has key focus —
/// the standard macOS rename behaviour, where typing replaces the old
/// name wholesale. Deferred one runloop so the `@FocusState` write that
/// is making the field first responder has landed; macOS routes field
/// editing through a shared NSTextView (the window's field editor), so
/// that is the responder to talk to.
///
/// Call from `.onChange(of: <focus state>)` when it flips true, not
/// from `onAppear` — on appear the responder often isn't installed yet.
@MainActor
enum FocusedFieldSelection {
    static func selectAll() {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.selectAll(nil)
        }
    }
}

/// "Click anywhere else ends the edit." The rename rows already cancel
/// on FOCUS loss, but on macOS most clicks never move key focus —
/// plain buttons, sidebar rows and empty space all leave the field
/// first responder — so click-away needed its own ears. A local
/// mouse-down monitor lives exactly as long as the field row does; a
/// press anywhere outside the field editor's bounds (any window)
/// cancels, and the click then proceeds normally, so "click another
/// chat" both cancels the rename and opens that chat.
struct EditFieldClickAway: ViewModifier {
    /// Called on the main thread, after the current event returns.
    let onOutsideClick: () -> Void
    @State private var monitor: Any? = nil

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { event in
            if let editor = event.window?.firstResponder as? NSTextView {
                let point = editor.convert(event.locationInWindow, from: nil)
                if editor.bounds.contains(point) { return event }
            }
            // Deferred so a click that lands on a commit control (the
            // rename rows have none today, but the pattern shouldn't
            // booby-trap one) runs its action before the cancel.
            DispatchQueue.main.async { onOutsideClick() }
            return event
        }
    }

    private func remove() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

extension View {
    /// See `EditFieldClickAway`. Attach to an in-place edit field's row;
    /// the monitor's lifetime is the row's.
    func editFieldClickAway(_ onOutsideClick: @escaping () -> Void) -> some View {
        modifier(EditFieldClickAway(onOutsideClick: onOutsideClick))
    }
}

// MARK: - Sidebar drag-to-reorder

/// User-arranged ordering for sidebar lists (top-level sections, chat
/// groups, agent session groups). One mechanism, three surfaces:
///
/// * `apply` resolves a persisted id order against whatever items
///   actually exist right now — ordered ids first (in their saved
///   positions), never-ordered items after them in their natural order.
///   A section that comes back (codex reinstalled) or a brand-new group
///   simply appends; a stale id in the saved order is ignored.
/// * `SidebarReorderDropDelegate` is the per-row drop target. The drag
///   payload is a namespaced string ("section:notes",
///   "chatgroup:<slug>", …), so the payload itself says which surface
///   it belongs to — a delegate ignores drags from any other surface
///   (and foreign text from other apps) by prefix, and no
///   which-row-is-dragging state needs to be threaded anywhere.
/// * Reordering is LIVE: each time the drag crosses a row, the new
///   order is written through the binding (and persisted by its
///   setter). A drop released outside any target therefore still keeps
///   the order the user saw — there is no separate commit step to miss.
enum SidebarOrdering {
    /// Internal (not fileprivate): every sidebar surface orders its
    /// groups through this one function — LeftSidebar, ChatListView
    /// and AgentSessionsSection all call it.
    static func apply<T>(_ items: [T],
                         order: [String],
                         id: (T) -> String) -> [T] {
        guard !order.isEmpty else { return items }
        var rank: [String: Int] = [:]
        for (index, key) in order.enumerated() where rank[key] == nil {
            rank[key] = index
        }
        return items.enumerated()
            .sorted { a, b in
                switch (rank[id(a.element)], rank[id(b.element)]) {
                case let (ra?, rb?): return ra < rb
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.offset < b.offset
                }
            }
            .map(\.element)
    }
}

/// See `SidebarOrdering`. `order`'s getter must return the ids in their
/// CURRENT displayed order (resolved, not just the persisted array —
/// items the user never dragged are in there too); its setter persists.
struct SidebarReorderDropDelegate: DropDelegate {
    /// Bare id of the row this delegate sits on (no prefix).
    let itemId: String
    /// Namespace of this surface, e.g. `"section:"`. Only payloads
    /// carrying it can reorder here.
    let payloadPrefix: String
    @Binding var order: [String]

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String,
                  payload.hasPrefix(payloadPrefix) else { return }
            let dragged = String(payload.dropFirst(payloadPrefix.count))
            Task { @MainActor in
                guard dragged != itemId,
                      let from = order.firstIndex(of: dragged),
                      let to = order.firstIndex(of: itemId) else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    order.move(fromOffsets: IndexSet(integer: from),
                               toOffset: to > from ? to + 1 : to)
                }
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        // The reorder already happened (and persisted) on the way here;
        // accepting just ends the drag without the fly-back animation.
        info.hasItemsConforming(to: [.plainText])
    }
}

/// Set on a top-level sidebar section wrapper so `DisclosureSection`
/// makes its HEADER the drag handle for reordering whole sections.
/// Carried through the environment because the sections construct their
/// own DisclosureSection internally — a parameter would mean plumbing
/// through every section type for one row's modifier.
private struct SidebarSectionDragPayloadKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var sidebarSectionDragPayload: String? {
        get { self[SidebarSectionDragPayloadKey.self] }
        set { self[SidebarSectionDragPayloadKey.self] = newValue }
    }
}

// MARK: - Live-row activity dot

/// A small pulsing orange dot indicating a row's conversation is
/// currently working — an agent runner streaming a turn, or a chat
/// waiting on a reply.
///
/// Shared by both sidebar lists on purpose: the two sit in one column,
/// so "this one is live" has to look the same in each. It lives here
/// rather than in either section for the same reason `relativeFormatter`
/// is duplicated with a comment pointing at its twin — one sidebar, one
/// vocabulary.
struct ActivityDot: View {
    @State private var pulse: Bool = false

    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 6, height: 6)
            .opacity(pulse ? 0.4 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .accessibilityLabel(String(
                localized: "Session is running",
                comment: "Accessibility label for the sidebar activity dot"))
    }
}

// MARK: - Optional tooltip

extension View {
    /// `.help()`, but only when there is something to say.
    ///
    /// A nil/empty tooltip is not the same as no tooltip: `.help("")`
    /// still installs a tracking area, so a row that has nothing to
    /// explain would answer a hover with an empty box. Callers that
    /// derive a hint from data (a subagent row, a folder path) hand the
    /// optional straight through instead of branching at each site.
    @ViewBuilder
    func help(ifPresent text: String?) -> some View {
        if let text, !text.isEmpty {
            self.help(text)
        } else {
            self
        }
    }
}

// MARK: - Sidebar row background (hover + selection)

/// Layered background for sidebar buttons. Selected rows always show the
/// accent tint; non-selected rows fade in a subtle gray on hover. Matches
/// the sidebar's Settings row and RootChatsSection's New Chat row.
struct SidebarRowBackground: ViewModifier {
    let selected: Bool
    let cornerRadius: CGFloat
    @State private var hovered: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(selected
                          ? Color.accentColor.opacity(0.18)
                          : (hovered ? Color.gray.opacity(0.2) : Color.clear))
            )
            .onHover { hovering in hovered = hovering }
    }
}

extension View {
    /// Apply the standard sidebar hover/selection background.
    /// `selected` defaults to false (use for buttons that have no
    /// selection concept like section headers and the "Show all" button).
    /// `cornerRadius` defaults to 6 for inner row buttons; pass 8 for
    /// top-level full-width buttons (the Settings and New Chat rows).
    func sidebarRowBackground(selected: Bool = false,
                              cornerRadius: CGFloat = 6) -> some View {
        modifier(SidebarRowBackground(selected: selected,
                                      cornerRadius: cornerRadius))
    }
}

// MARK: - Pointer feedback for flat list rows

/// Fades a neutral tint in under a row while the pointer is over it.
///
/// Distinct from `SidebarRowBackground` on purpose: these rows are
/// square, full-width and hairline-divided (the onboarding / model-setup
/// provider lists), and they already paint a selection or keyboard-
/// highlight background of their own. This one paints BEHIND that, so a
/// selected row keeps its accent tint and a keyboard-highlighted row
/// simply reads a shade stronger when the pointer is also on it.
///
/// The `@State` lives in the modifier rather than the enclosing view
/// because the rows come out of a `ForEach` — one flag in the parent
/// would light the whole list at once.
struct HoverFill: ViewModifier {
    var opacity: Double = 0.08
    var cornerRadius: CGFloat = 0
    @State private var hovered: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(hovered ? Color.gray.opacity(opacity) : Color.clear)
            )
            .onHover { hovered = $0 }
    }
}

extension View {
    /// Neutral pointer-over tint for flat list rows. Defaults are the
    /// provider-list values: square corners, and a shade lighter than
    /// the 0.12 keyboard highlight so the two stay tellable apart.
    func hoverFill(opacity: Double = 0.08,
                   cornerRadius: CGFloat = 0) -> some View {
        modifier(HoverFill(opacity: opacity, cornerRadius: cornerRadius))
    }
}

// MARK: - Row plus button (+)

/// The + action button on sidebar headers (folder session groups, the
/// Projects section). Same 18-pt frame and hover treatment as
/// `RowEllipsisMenu` so inline row affordances read as one family — and
/// line up in one trailing column.
struct RowPlusButton: View {
    let label: String
    let action: () -> Void
    @State private var hovered: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovered ? .primary : .secondary)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hovered ? Color.gray.opacity(0.28) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Show all / show less row

/// How many rows a sidebar list shows before `SidebarShowMoreRow` takes
/// over — per GROUP wherever the list is grouped, so no one group can
/// crowd the others out of the column.
///
/// One number for the whole sidebar: the agent sessions, the chats and
/// the chat groups sit in a single scrolling column, and two different
/// caps in there read as a bug in whichever list is longer.
enum SidebarRowCap {
    static let limit = 10
}

/// The row at the end of a capped sidebar list — an agent section's
/// session groups, the Chats section, each chat group. One component so
/// every capped list in the sidebar speaks with one voice, and so the
/// two directions can never drift apart in wording.
///
/// The reveal is a TOGGLE, not a latch. A one-way "Show all" is how a cap
/// meant to keep the column scannable gets switched off for the rest of
/// the app's run by one exploratory click, with nothing on screen
/// offering a way back — which reads exactly like the cap not being
/// there at all.
///
/// `indent` is where the label starts. 8 pt puts it on the rows' own
/// leading edge, which is right for a LIST-level button; a per-group copy
/// passes the group's row indent plus 20 (a 14-pt glyph + the row's 6-pt
/// spacing) so it lines up with the row TITLES above it and reads as the
/// last row of that group rather than as the first of the next one.
struct SidebarShowMoreRow: View {
    /// Rows beyond the cap. Callers don't render this at 0.
    let overflow: Int
    /// Whether those rows are on screen right now.
    let revealed: Bool
    var indent: CGFloat = 8
    let action: () -> Void
    @Environment(\.sipFontScale) private var fontScale

    var body: some View {
        Button(action: action) {
            HStack {
                Group {
                    if revealed {
                        Text("Show less",
                             comment: "Sidebar: re-apply the row cap on a list that was expanded")
                    } else {
                        // Count what is ACTUALLY hidden — a plain total
                        // both understates multi-group trims and
                        // overstates single-group ones.
                        Text("Show all (\(overflow) more)",
                             comment: "Sidebar: reveal the rows the cap hid")
                    }
                }
                .font(.system(size: SipFont.sidebarRow(fontScale)))
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.leading, indent)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarRowBackground()
    }
}

// MARK: - Row ellipsis menu (⋮)

/// The three-vertical-dot action button on sidebar rows. Sits OUTSIDE
/// the row's own Button (SwiftUI nested buttons both fire), highlights
/// on hover like every other sidebar affordance, and opens the menu
/// items the caller supplies — Delete / Rename / Move to, typically.
struct RowEllipsisMenu<Items: View>: View {
    @ViewBuilder var items: () -> Items
    @State private var hovered: Bool = false

    var body: some View {
        Menu {
            items()
        } label: {
            // SF Symbols has no vertical ellipsis; rotate the
            // horizontal one.
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovered ? .primary : .secondary)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hovered ? Color.gray.opacity(0.28) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help(String(localized: "Actions",
                     comment: "Tooltip for the per-row ⋮ actions menu"))
        .accessibilityLabel(String(
            localized: "Row actions",
            comment: "Accessibility label for the per-row ⋮ actions menu"))
    }
}

/// Local key-down monitor giving ↑ / ↓ / Return list navigation to
/// views built on ScrollView + button rows, where SwiftUI has no
/// focus-free arrow handling. Arrows are delivered even while a text
/// field is being edited (Spotlight-style: type to filter, arrow to
/// move); Return is delivered with `whileEditing` so callers can leave
/// a field's own submit behavior alone. The handler returns true to
/// consume the event; anything unhandled proceeds normally, so default
/// buttons and Escape keep working.
final class ListKeyMonitor {
    enum Key { case up, down, ret }
    private var token: Any?

    func install(_ handler: @escaping @MainActor (Key, _ whileEditing: Bool) -> Bool) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let key: Key
            switch event.keyCode {
            case 125: key = .down
            case 126: key = .up
            case 36, 76: key = .ret
            default: return event
            }
            guard event.modifierFlags
                .intersection([.command, .option, .control]).isEmpty
            else { return event }
            // The field editor is an NSTextView whenever any text field
            // has keyboard focus.
            let editing = NSApp.keyWindow?.firstResponder is NSTextView
            // Local monitors fire on the main thread.
            let handled = MainActor.assumeIsolated { handler(key, editing) }
            return handled ? nil : event
        }
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

/// A plain text / secure field whose placeholder hides the moment the
/// field gains FOCUS, not only once text exists. The native prompt
/// stays visible while an empty field is being edited, which in a form
/// full of key names reads as pre-filled text. Monospaced, because
/// every caller today takes an API key or an environment-variable
/// name.
struct FocusClearingField: View {
    let placeholder: String
    @Binding var text: String
    var secure: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty && !focused {
                Text(placeholder)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(SipDesign.textHint)
                    .lineLimit(1)
                    .allowsHitTesting(false)
            }
            Group {
                if secure {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .focused($focused)
        }
    }
}
