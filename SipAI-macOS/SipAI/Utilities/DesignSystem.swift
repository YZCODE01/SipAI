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

    /// The grey a sidebar row fades in under the pointer
    /// (`SidebarRowBackground`). A tint, so what it looks like depends on
    /// what it is drawn over: on the sidebar's `surface` it comes out
    /// #424244 in dark and #E8E8E9 in light.
    static let rowHover = Color.gray.opacity(0.2)

    /// The grey behind a session id in the agent composer
    /// (`SessionIdTokens`): the sidebar row's hover grey, spelled once.
    /// The composer's box is the same `surface` the sidebar is, so the
    /// same tint comes out the same colour in both places.
    ///
    /// An NSColor, because AppKit draws it, in the text view's own
    /// background pass — and built through `NSColor(Color)`, which stays
    /// dynamic. `NSColor.systemGray.withAlphaComponent(0.2)` does not: it
    /// is frozen in whatever appearance is current when the static is
    /// first read, and would draw dark mode's grey in light mode.
    static let sessionIdTokenFill = NSColor(rowHover)

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

    // MARK: - Page rhythm

    /// The band between the top bar and a page's content. An agent
    /// session keeps it above its transcript, a note above its title bar
    /// and Settings above its column, so on every page the content
    /// starts — and scrolls away — at the same line, never up against
    /// the bar.
    static let pageTopBand: CGFloat = 44

    /// The scrolling content's own inset inside that band. A transcript's
    /// first row and a Settings section's first line both sit
    /// `pageTopBand + pageContentInset` below the top bar when the page is
    /// at its top.
    static let pageContentInset: CGFloat = 16
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

/// Type sizes derived from the tier. Two conventions ride the one
/// `\.sipFontScale` environment value, and every size in the app is
/// one or the other:
///
/// * **Design-size** — `scaled(base, fontScale)` normalises the tier
///   multiplier so the Default tier lands EXACTLY on the size the view
///   was designed with, and only the other tiers move. The sidebar,
///   both composers, their chips and popovers, Settings and the notes
///   editor use this, through `.sipFont(_:)` or `scaled` directly.
/// * **Transcript** — the two transcript hosts RE-SCOPE the environment
///   to `contentScale`, and every row inside them multiplies raw
///   (`14 * fontScale`), which lands on `sidebarRow` at Default. Inside
///   that re-scope `scaled` / `.sipFont` come out 1/1.1 too small:
///   they read a value that has already been divided down. Rows there
///   keep multiplying raw, like their neighbours — or, for a number
///   that is the size the row shows at Default rather than one on the
///   renderer's 14-base, `N * contentRatio(fontScale)`.
///
/// The sidebar deliberately runs more compact than chat content, with a
/// three-step hierarchy at the Default tier — 13 pt row names, 12 pt
/// SECTION HEADERS (semibold caps at 12 carry the optical mass of a
/// regular 13), 11 pt hints/metadata.
enum SipFont {
    /// `base` at the Default tier, scaled proportionally on the others.
    static func scaled(_ base: CGFloat, _ fontScale: CGFloat) -> CGFloat {
        base * fontScale / FontTier.standard.scale
    }

    /// The tier's multiplier over Default — for FRAMES that bound
    /// design-size text (a text box's height clamp, a fixed control-row
    /// height), which must grow with the text or clip it.
    static func ratio(_ fontScale: CGFloat) -> CGFloat {
        fontScale / FontTier.standard.scale
    }

    /// `ratio` INSIDE a transcript re-scope, where the environment
    /// value is a `contentScale` rather than the tier's: exactly 1 at
    /// Default. For a row there whose number is the size it SHOWS at
    /// Default (a 12 pt timestamp, a 13 pt spinner caption, a frame),
    /// `12 * contentRatio(fontScale)` keeps that size at Default and
    /// scales with the transcript — where `12 * fontScale` would render
    /// 7 % smaller at Default, because the renderer's own rows are
    /// stated on a 14-base that lands on 13.
    static func contentRatio(_ contentScale: CGFloat) -> CGFloat {
        contentScale / self.contentScale(FontTier.standard.scale)
    }

    /// Sidebar row/name size — 13 pt at the Default tier.
    static func sidebarRow(_ fontScale: CGFloat) -> CGFloat {
        scaled(13, fontScale)
    }
    /// Sidebar section-header size (semibold, uppercased) — 12 pt at
    /// the Default tier.
    static func sidebarHeader(_ fontScale: CGFloat) -> CGFloat {
        scaled(12, fontScale)
    }
    /// Sidebar placeholder/status/metadata size — 11 pt at the Default
    /// tier.
    static func sidebarHint(_ fontScale: CGFloat) -> CGFloat {
        scaled(11, fontScale)
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

    /// AppKit controls take no arbitrary point size, so beside scaled
    /// labels they STEP: a row's label and its switch never diverge by
    /// more than one size step.
    static func controlSize(_ fontScale: CGFloat) -> ControlSize {
        controlSize(fontScale, base: .regular)
    }

    /// The same stepping for a control DESIGNED at another size — a
    /// `.small` switch or button at Default goes one step down on Small
    /// and one up on Large text mode, exactly as a regular one does.
    static func controlSize(_ fontScale: CGFloat, base: ControlSize) -> ControlSize {
        let steps: [ControlSize] = [.mini, .small, .regular, .large, .extraLarge]
        guard let at = steps.firstIndex(of: base) else { return base }
        if fontScale < FontTier.standard.scale { return steps[max(at - 1, 0)] }
        if fontScale >= FontTier.xlarge.scale { return steps[min(at + 1, steps.count - 1)] }
        return base
    }

    // MARK: Transcript rhythm

    /// The markdown renderer's body base; every transcript row is a
    /// multiple of it at the re-scoped `fontScale`.
    static let transcriptBodyBase: CGFloat = 14

    /// One line's height in the system font — ascender to descender,
    /// leading included — which is what a wrapped line advances by
    /// before any `lineSpacing` is added.
    ///
    /// Memoised: every transcript row asks on every body pass, and the
    /// font lookup behind it costs about a microsecond. Four tiers
    /// times a handful of bases is the whole population; the bound
    /// only guards against a stray fractional size growing it.
    static func lineHeight(_ pointSize: CGFloat) -> CGFloat {
        lineHeightLock.lock()
        defer { lineHeightLock.unlock() }
        if let cached = lineHeightCache[pointSize] { return cached }
        let font = NSFont.systemFont(ofSize: pointSize)
        let height = font.ascender - font.descender + font.leading
        if lineHeightCache.count >= 64 { lineHeightCache.removeAll(keepingCapacity: true) }
        lineHeightCache[pointSize] = height
        return height
    }
    private static var lineHeightCache: [CGFloat: CGFloat] = [:]
    private static let lineHeightLock = NSLock()

    /// Baseline-to-baseline distance inside a wrapped paragraph: the
    /// line's own height plus the tier's line spacing.
    static func linePitch(pointSize: CGFloat, lineSpacingFactor: CGFloat) -> CGFloat {
        lineHeight(pointSize) + pointSize * lineSpacingFactor
    }

    /// Multiplier for every FIXED vertical gap in a transcript — between
    /// paragraphs, between list items, around headings and code, and
    /// between messages — as a function of the environment pair a
    /// transcript row already reads (the RE-SCOPED `fontScale` and the
    /// line-spacing factor).
    ///
    /// SwiftUI's `lineSpacing` is added between consecutive lines of one
    /// `Text` and nowhere else (measured: a five-line paragraph grows by
    /// four spacings, two stacked paragraphs meet with no gap), so a gap
    /// stated in constant points does not move with the tier while the
    /// wrapped lines around it do. At the larger tiers that inverts the
    /// hierarchy — a wrapped line sits farther from its own paragraph
    /// than the next paragraph does. Scaling every gap by the tier's
    /// line PITCH over Default's keeps the whole rhythm in one ratio;
    /// Default is exactly 1 by construction.
    static func transcriptGapScale(fontScale: CGFloat, lineSpacingFactor: CGFloat) -> CGFloat {
        let pitch = linePitch(pointSize: transcriptBodyBase * fontScale,
                              lineSpacingFactor: lineSpacingFactor)
        return pitch / defaultTranscriptPitch
    }

    /// The Default tier's transcript line pitch — the denominator of
    /// `transcriptGapScale`. Computed from the same two rules the
    /// numerator uses, so it cannot drift from them.
    private static let defaultTranscriptPitch: CGFloat = linePitch(
        pointSize: transcriptBodyBase * contentScale(FontTier.standard.scale),
        lineSpacingFactor: FontTier.standard.lineSpacingFactor)

    // MARK: Design-size rhythm

    /// The space between two wrapped lines of design-size text whose
    /// Default size is `base`: the tier's factor over the SCALED size —
    /// the rule the two composers' text boxes follow, and the one the
    /// transcript follows at its own sizes.
    static func lineSpacing(_ base: CGFloat, fontScale: CGFloat,
                            lineSpacingFactor: CGFloat) -> CGFloat {
        scaled(base, fontScale) * lineSpacingFactor
    }

    /// Multiplier for the VERTICAL gaps of a design-size surface whose
    /// body text is `base` at Default: that body's line pitch at this tier
    /// over its pitch at Default, exactly 1 at Default. The design-size
    /// twin of `transcriptGapScale`, and for the same reason — scaling a
    /// gap by the font alone leaves it behind the line spacing, which
    /// grows faster, until a wrapped line sits farther from its own row
    /// than the next row does.
    static func gapScale(_ base: CGFloat, fontScale: CGFloat,
                         lineSpacingFactor: CGFloat) -> CGFloat {
        linePitch(pointSize: scaled(base, fontScale), lineSpacingFactor: lineSpacingFactor)
            / linePitch(pointSize: base, lineSpacingFactor: FontTier.standard.lineSpacingFactor)
    }
}

/// `.font(.system(size:weight:design:))` at the DESIGN-SIZE convention:
/// `size` is what the view shows at the Default tier, scaled on the
/// others. For every surface outside a transcript re-scope — see
/// `SipFont` for why it must not be used inside one.
private struct SipScaledFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    @Environment(\.sipFontScale) private var fontScale

    func body(content: Content) -> some View {
        content.font(.system(size: SipFont.scaled(size, fontScale),
                             weight: weight, design: design))
    }
}

extension View {
    /// Tier-scaled system font; `size` is the Default-tier point size.
    func sipFont(_ size: CGFloat,
                 weight: Font.Weight = .regular,
                 design: Font.Design = .default) -> some View {
        modifier(SipScaledFont(size: size, weight: weight, design: design))
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

// MARK: - Text-input typography

/// Font and line spacing for the app's own NSTextView surfaces, driven
/// by the font tier the way `TextInputSpellChecking` is driven by its
/// switch — and called from BOTH `makeNSView` and `updateNSView`, for
/// the same reason: the tier is changed behind a sheet that does not
/// tear the composer down.
///
/// Idempotent by comparison, not by caller discipline: `updateNSView`
/// runs on every keystroke, and re-setting a text view's font resets
/// its selection and closes the current undo group, so nothing is
/// written unless the point size or the line spacing actually differs.
@MainActor
enum TextInputTypography {
    /// Applies `pointSize` / `lineSpacing` to the view's font, its
    /// default paragraph style, its typing attributes and the text
    /// already in its storage. Returns whether anything changed, so a
    /// self-sizing host can re-measure.
    @discardableResult
    static func apply(pointSize: CGFloat,
                      lineSpacing: CGFloat,
                      monospaced: Bool = false,
                      to textView: NSTextView) -> Bool {
        let font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
            : NSFont.systemFont(ofSize: pointSize)
        // The face is compared as well as the size: a stock text view
        // comes up in Helvetica, and a size that happened to match would
        // otherwise keep it.
        let sameFont = textView.font.map {
            $0.fontName == font.fontName && abs($0.pointSize - pointSize) < 0.01
        } ?? false
        let sameSpacing = abs((textView.defaultParagraphStyle?.lineSpacing ?? -1) - lineSpacing) < 0.01
        guard !(sameFont && sameSpacing) else { return false }

        let mutable = NSMutableParagraphStyle()
        mutable.setParagraphStyle(textView.defaultParagraphStyle ?? .default)
        mutable.lineSpacing = lineSpacing
        // Immutable once shared: the same object goes into the view,
        // its typing attributes and every character of its storage.
        let style = mutable.copy() as! NSParagraphStyle

        // `font` on a plain-text view restyles the whole storage; the
        // paragraph style does not follow it, so the storage is
        // restyled explicitly — text already typed must not keep the
        // old spacing under new typing attributes.
        textView.font = font
        textView.defaultParagraphStyle = style
        textView.typingAttributes[.font] = font
        textView.typingAttributes[.paragraphStyle] = style
        if let storage = textView.textStorage, storage.length > 0 {
            let all = NSRange(location: 0, length: storage.length)
            storage.addAttribute(.paragraphStyle, value: style, range: all)
        }
        return true
    }
}

// MARK: - Session-id tokens

/// A session id the agent composer draws on a grey token — what the
/// session row's "Copy session ID" puts on the pasteboard, wherever it
/// lands in the box. Drawn, never stored: the box's text stays the id's
/// own characters, so the message sent is exactly what is on screen and
/// a draft survives a detour as the plain text it is.
///
/// A token is a run of id characters EQUAL to the id of a session this
/// app lists — never merely shaped like one. A UUID inside a pasted error
/// message is not a session and must not look like one.
enum SessionIdTokens {
    /// Every id the three CLIs mint is one run of these: claude and codex
    /// write a UUID, kimi `session_<uuid>`. Bounded on both sides by
    /// anything else, so an id inside a longer run of id characters is
    /// not that id, and an id inside a path segment still is.
    private static let candidate = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{16,}(?![A-Za-z0-9_-])")

    /// The tokens in `text`, in order, as UTF-16 ranges — the unit
    /// TextKit counts in.
    static func ranges(in text: String, known: Set<String>) -> [NSRange] {
        guard !known.isEmpty, !text.isEmpty else { return [] }
        let ns = text as NSString
        return candidate
            .matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map(\.range)
            .filter { known.contains(ns.substring(with: $0)) }
    }

    /// What the row's menu item copies: the id alone, as plain text, so
    /// it pastes bare into a terminal (`claude --resume …`) and into
    /// anything else. The grey is this app's drawing of an id, not a
    /// style the id carries.
    static func copy(_ id: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(id, forType: .string)
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
                if editor.bounds.contains(point) {
                    #if DEBUG
                    SidebarDropDiagnostics.log("rename click-away: inside the focused editor, kept")
                    #endif
                    return event
                }
            }
            #if DEBUG
            SidebarDropDiagnostics.log("rename click-away: CANCEL — first responder \(String(describing: event.window?.firstResponder.map { type(of: $0) })), event \(event.type.rawValue) at \(event.locationInWindow)")
            #endif
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
        let accepted = info.hasItemsConforming(to: [.plainText])
        #if DEBUG
        // The first call AppKit's routing makes on whichever target it
        // chose — the only line that tells "no target was reached"
        // from "a target refused" (SidebarDropDiagnostics).
        SidebarDropDiagnostics.log("validateDrop on \(payloadPrefix)\(itemId) → \(accepted)")
        #endif
        return accepted
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let provider = info.itemProviders(for: [.plainText]).first else {
            #if DEBUG
            SidebarDropDiagnostics.log("dropEntered on \(payloadPrefix)\(itemId): no plain-text provider")
            #endif
            return
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String,
                  payload.hasPrefix(payloadPrefix) else {
                #if DEBUG
                SidebarDropDiagnostics.log("dropEntered on \(payloadPrefix)\(itemId): payload \(String(describing: object)) does not carry this prefix")
                #endif
                return
            }
            let dragged = String(payload.dropFirst(payloadPrefix.count))
            Task { @MainActor in
                guard dragged != itemId,
                      let from = order.firstIndex(of: dragged),
                      let to = order.firstIndex(of: itemId) else {
                    #if DEBUG
                    SidebarDropDiagnostics.log("dropEntered on \(payloadPrefix)\(itemId): dragged=\(dragged) from=\(String(describing: order.firstIndex(of: dragged))) to=\(String(describing: order.firstIndex(of: itemId))) → no move")
                    #endif
                    return
                }
                #if DEBUG
                SidebarDropDiagnostics.log("dropEntered on \(payloadPrefix)\(itemId): moving \(dragged) \(from)→\(to)")
                #endif
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

#if DEBUG
/// Capture for the intermittent sidebar reorder failure — a drag image
/// that appears while nothing ever moves, on one attempt and not the
/// next. Every mechanism that can be reproduced outside the app
/// reorders correctly, so the failing moment has to be caught inside
/// it: `dumpDestinations` logs, as a drag STARTS, every NSView in the
/// window registered as a drop destination (SwiftUI makes one per
/// `.onDrop`; AppKit resolves overlapping siblings by z-order), and
/// `log` marks each step of the routing path. Debug builds only;
/// nothing here changes behaviour. Read the lines in Xcode's console
/// after a drag that failed.
enum SidebarDropDiagnostics {
    static func dumpDestinations(reason: String) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let content = window.contentView else { return }
        let mouse = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        var lines: [String] = []
        func walk(_ v: NSView) {
            if !v.registeredDraggedTypes.isEmpty {
                let f = v.convert(v.bounds, to: nil)
                let z = v.superview?.subviews.firstIndex(where: { $0 === v }) ?? -1
                lines.append("  z\(z) \(type(of: v)) frame=(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))) hidden=\(v.isHiddenOrHasHiddenAncestor)\(f.contains(mouse) ? " <mouse>" : "")")
            }
            for s in v.subviews { walk(s) }
        }
        walk(content)
        NSLog("SipAI drop-diag [%@] mouse=(%d,%d) %d destination(s)\n%@",
              reason, Int(mouse.x), Int(mouse.y), lines.count,
              lines.joined(separator: "\n"))
    }

    static func log(_ line: String) {
        NSLog("SipAI drop-diag %@", line)
    }
}
#endif

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
///
/// The beat is the fill's alpha, read off the clock — never a view
/// opacity animated from `onAppear`. So the pulse is drawn exactly the
/// way `UnreadDot` is, the same 6 pt circle with a different fill, and
/// the two cannot land at different heights when they sit side by side
/// (`GroupActivityDots`). A repeating animation started as a view
/// appears also carries whatever else changes in that update with it —
/// the way a pulse can drift where a steady dot does not — and a clock
/// has no transaction to carry anything. Every pulse in the sidebar
/// reads the same clock, so they beat together.
struct ActivityDot: View {
    /// What the dot says to VoiceOver. Also the spoken VALUE of a folded
    /// session-group header drawing one, whose own label replaces the
    /// dot's — one sentence for both, so they cannot drift apart.
    static var accessibilityText: String {
        String(localized: "Session is running",
               comment: "Accessibility label for the sidebar activity dot")
    }

    /// Half a beat: full to faint, or faint back to full.
    static let halfBeat: TimeInterval = 0.8
    /// The alpha at the faint end of the beat.
    static let faintest: Double = 0.4

    /// The dot's alpha at `date`: 1 at the top of every beat, `faintest`
    /// at its foot, eased in and out between.
    static func alpha(at date: Date) -> Double {
        let halves = date.timeIntervalSinceReferenceDate / halfBeat
        let phase = halves - 2 * (halves / 2).rounded(.down)   // 0 ..< 2
        let x = phase <= 1 ? phase : 2 - phase                  // 0 → 1 → 0
        let eased = x * x * (3 - 2 * x)
        return 1 - (1 - faintest) * eased
    }

    var body: some View {
        // Thirty steps a second is smooth for a 6 pt dot fading over
        // 0.8 s, and costs a third of a display-rate animation.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            Circle()
                .fill(Color.orange.opacity(Self.alpha(at: context.date)))
                .frame(width: 6, height: 6)
        }
        .accessibilityLabel(Self.accessibilityText)
    }
}

/// The steady form of `ActivityDot`: the run FINISHED and the session —
/// or the chat — has not been opened since. The pulse's size, holding
/// still — in the pulse's place on a session or chat row, beside it on a
/// row that stands for several (`GroupActivityDots`) — so the row still
/// says "look here" without claiming anything is running. It goes when
/// the user opens the row (`AgentManager.noteOpenSession`,
/// `ChatManager.noteOpenChat`), never on a timer.
///
/// Blue — the mode chip's `SipDesign.blue`, the badge's colour for news —
/// never the pulse's orange. The pulse runs between full and 40 %
/// opacity, so at the top of every beat an orange pulse IS a steady
/// orange dot, and the two could only be told apart by watching one for
/// a second.
///
/// The same circle as `ActivityDot`, drawn the same way — a 6 pt frame
/// and a fill — so a pair of them lines up by construction. A view of its
/// own all the same: the two say different things to VoiceOver.
struct UnreadDot: View {
    /// Also the spoken VALUE of a folded header drawing one — one
    /// sentence for both, like `ActivityDot.accessibilityText`.
    static var accessibilityText: String {
        String(localized: "Finished, not opened yet",
               comment: "Accessibility label for the sidebar's steady dot — a run finished and the session (or chat) has not been opened since")
    }

    var body: some View {
        Circle()
            .fill(SipDesign.blue)
            .frame(width: 6, height: 6)
            .accessibilityLabel(Self.accessibilityText)
    }
}

/// What a row standing for OTHER rows says about them: the pulse while
/// one of them is running, the steady dot while one of them finished and
/// has not been opened, and BOTH, pulse first, when both are true. A
/// group routinely holds a running session beside a finished one nobody
/// has opened, and a pulse drawn alone would hide the second until the
/// first had finished too.
///
/// One view for every such row — a folded agent or chat group's title
/// line, a collapsed section's header, a scheduled task's row (for its
/// runs) — so the pair keeps one order and one gap wherever it is drawn.
/// The caller decides WHETHER to draw it (a header only while folded or
/// collapsed, and every caller only when one of the two is true, so a row
/// with nothing to say spends no spacing on an empty view); this decides
/// what.
///
/// The gap is 8 pt — more than a dot's own width, so the pair reads as
/// two signals rather than one smudge.
struct GroupActivityDots: View {
    /// The space between the pulse and the steady dot.
    static let spacing: CGFloat = 8

    let live: Bool
    let unread: Bool

    var body: some View {
        HStack(spacing: Self.spacing) {
            if live {
                ActivityDot()
            }
            if unread {
                UnreadDot()
            }
        }
        .fixedSize()
    }

    /// The same statement for a header whose own accessibility label
    /// replaces the dots': each dot's own sentence, pulse first, in the
    /// shape VoiceOver already reads a header that keeps its children's.
    static func accessibilityText(live: Bool, unread: Bool) -> String {
        var parts: [String] = []
        if live { parts.append(ActivityDot.accessibilityText) }
        if unread { parts.append(UnreadDot.accessibilityText) }
        return parts.joined(separator: ", ")
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
                          : (hovered ? SipDesign.rowHover : Color.clear))
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

    /// The rows a capped list shows, in order, and how many the cap holds
    /// back. A row `exempt` answers yes for — one with a dot, running or
    /// finished and unopened — is always shown and does not spend the
    /// cap: the cap is for rows with nothing new to show, and a dot
    /// behind "Show all" would be a dot nobody sees.
    ///
    /// `overflow` is counted whether or not the list is `revealed`, since
    /// the row under it is a toggle that has to be able to say "Show
    /// less" from a list showing everything.
    static func visible<Row>(_ rows: [Row], revealed: Bool,
                             exempt: (Row) -> Bool) -> (rows: [Row], overflow: Int) {
        var shown: [Row] = []
        var spent = 0
        var overflow = 0
        for row in rows {
            if exempt(row) {
                shown.append(row)
            } else if spent < limit {
                shown.append(row)
                spent += 1
            } else {
                overflow += 1
                if revealed { shown.append(row) }
            }
        }
        return (shown, overflow)
    }
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
    // Design-size: the labels beside it read the tier, and a key field
    // frozen at 13 pt beside a 17 pt label is the one row in the form
    // that ignores Font Size.
    @Environment(\.sipFontScale) private var fontScale

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty && !focused {
                Text(placeholder)
                    .font(.system(size: SipFont.scaled(13, fontScale), design: .monospaced))
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
            .font(.system(size: SipFont.scaled(13, fontScale), design: .monospaced))
            .focused($focused)
        }
    }
}
