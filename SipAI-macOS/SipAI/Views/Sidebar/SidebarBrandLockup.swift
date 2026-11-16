// SidebarBrandLockup.swift
// SipAI macOS — the logo and the wordmark at the top of the sidebar, and
// the bubble that takes the wordmark's place while there is something to
// say (`SidebarNotices`).
//
// Plain values in, closures out, so a harness renders the real lockup
// headless (`Verification/SidebarNotices`); the sidebar feeds it.

import SwiftUI

/// The logo and the wordmark — or, while there is something to say, the
/// bubble beside the cup.
///
/// The imageset carries separate light/dark renditions, so the catalog
/// swaps them with the effective appearance on its own.
///
/// Leading is 14 — the same line the section headers sit on (8 from the
/// section's own inset + 6 from DisclosureSection's). The rendition is
/// tight-cropped, so the FRAME's inset is the artwork's inset and no
/// compensation is needed; a rendition that reintroduced transparent
/// margin would have to be measured and subtracted here, which is how this
/// drifted off the chevrons before.
///
/// `.lastTextBaseline` puts the wordmark's BASELINE on the image's bottom
/// edge (a non-text view's baseline is its bottom), and the crop puts the
/// GLASS'S BASE on that same edge — so the cup and the S land on one line
/// and only the p's descender reaches below it. Both halves are
/// load-bearing: transparent margin under the cup floats it off the
/// baseline just as surely as swapping this for `.bottom`, which would
/// hang the descender off the glass and lift the cap-height letters clear
/// of it.
///
/// The wordmark's FRAME is laid out always, and drawn by nothing: what
/// shows — the wordmark or the bubble — is an overlay on that frame. The
/// header keeps the height the mark gives it, so a notice moves nothing
/// below it: a bubble grows no taller than the mark, inside its height.
///
/// The wordmark-to-mark ratio is 28/54 (0.519). Keep the wordmark on that
/// scale if the mark's height changes again.
struct SidebarBrandLockup: View {
    /// The mark — the asset catalog's in the app; a harness hands in the
    /// rendition it measures.
    var logo: Image = Image("SipAI-Logo-54")
    /// Settings → Display → Show notifications beside the logo. Checked
    /// here as well as where notices are queued, so switching it off takes
    /// a bubble already on screen away at once.
    let showsNotices: Bool
    /// The notice that happened, on screen.
    let notice: SidebarNotice?
    /// The update on offer, drawn while no notice is.
    let offer: UpdateBadgeItem?
    /// Why the offer's button cannot be used now — a running turn of that
    /// tool — or nil when it can.
    var offerBlockedReason: String? = nil
    var onOpen: (SidebarNotice) -> Void = { _ in }
    var onOfferAction: (UpdateBadgeItem) -> Void = { _ in }
    var onOfferClose: (UpdateBadgeItem) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The mark's height, straw included — and the tallest a bubble grows.
    /// A bubble's middle is the mark's middle: one line is a short bubble
    /// there, and more lines grow it toward the straw's tip and the glass's
    /// base alike (`SidebarBubbleMetrics`).
    static let logoHeight: CGFloat = 54
    /// Between the mark and whatever stands beside it, the wordmark or the
    /// bubble.
    static let markGap: CGFloat = 10
    static let leadingInset: CGFloat = 14
    static let trailingInset: CGFloat = 12
    /// Past the lockup's own trailing inset, so the bubble ends where the
    /// … dots of the rows below end: `RowEllipsisMenu`'s 18-pt box ends
    /// 12 pt in from the sidebar's edge (its row's 4 + the section's 8),
    /// and the dots, side by side in the middle of it, end 4 pt inside
    /// that.
    static let bubbleTrailingInset: CGFloat = 4

    /// The bubble's fill: the running turn clock's colour (`TurnClockChip`
    /// draws its count in it), referenced rather than copied. A light sky
    /// blue in both appearances, so the text on it is black.
    static var bubbleFill: Color { ChatMarkdownStyle.inlineCode }

    private var showsBubble: Bool {
        showsNotices && (notice != nil || offer != nil)
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: Self.markGap) {
            logo
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: Self.logoHeight)
                // Decorative: the wordmark beside it already carries the
                // name, and without this VoiceOver reads the asset NAME
                // ("SipAI-Logo-54") and then the text.
                .accessibilityHidden(true)
            Self.wordmark
                .hidden()
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leadingLastTextBaseline) {
                    // Each candidate brings its own baseline: the
                    // wordmark's is its text's, a bubble's is set half
                    // the mark's height below its middle (`BubbleSlot`)
                    // — so the bubble's middle is the mark's middle,
                    // however many lines it holds.
                    ZStack(alignment: .leadingLastTextBaseline) {
                        if showsBubble {
                            // A notice takes the offer's place while it
                            // shows; the offer rolls back in once it has
                            // gone. Drawn under the notice instead, an
                            // offer with more lines would show above and
                            // below it.
                            if let notice {
                                SidebarNoticeBubble(notice: notice, onOpen: onOpen)
                                    .modifier(BubbleSlot())
                                    // A new identity per notice, so the
                                    // next one rolls in over the last
                                    // rather than replacing its text in
                                    // place.
                                    .id(notice.id)
                                    .transition(transition)
                            } else if let offer {
                                UpdateOfferBubble(item: offer,
                                                  blockedReason: offerBlockedReason,
                                                  onAction: onOfferAction,
                                                  onClose: onOfferClose)
                                    .modifier(BubbleSlot())
                                    .id("offer:" + offer.key + ":" + UpdateOfferRules.token(offer))
                                    .transition(transition)
                            }
                        } else {
                            Self.wordmark
                                .transition(transition)
                        }
                    }
                }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.85), value: animationKey)
        .padding(.leading, Self.leadingInset)
        .padding(.trailing, Self.trailingInset)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    /// What changing animates: the notice on screen and the update on
    /// offer, each by its identity.
    private var animationKey: [String] {
        [showsBubble ? "on" : "off",
         notice?.id.uuidString ?? "",
         offer.map { $0.key + ":" + UpdateOfferRules.token($0) } ?? ""]
    }

    static var wordmark: some View {
        Text(verbatim: "SipAI")
            .font(.system(size: 28, weight: .semibold))
            .tracking(-0.4)
            .foregroundStyle(.primary)
    }

    /// In from below, out through the top, softened by a blur — the header
    /// rolls like a departures board, whichever of the three is replacing
    /// which. With Reduce Motion on, a plain cross-fade.
    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: BrandRoll(offset: 14, blur: 3, opacity: 0),
                                 identity: BrandRoll(offset: 0, blur: 0, opacity: 1)),
            removal: .modifier(active: BrandRoll(offset: -14, blur: 3, opacity: 0),
                               identity: BrandRoll(offset: 0, blur: 0, opacity: 1)))
    }
}

/// Where a bubble stands: as tall as its own lines, ending where the …
/// dots below end, its middle on the mark's middle — its baseline half the
/// mark's height below that middle, on the wordmark's baseline, the glass's
/// base. The height is the bubble's, never the one the wordmark's frame
/// offers: that frame is shorter than two lines.
private struct BubbleSlot: ViewModifier {
    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, SidebarBrandLockup.bubbleTrailingInset)
            .alignmentGuide(.lastTextBaseline) {
                $0[VerticalAlignment.center] + SidebarBrandLockup.logoHeight / 2
            }
    }
}

private struct BrandRoll: ViewModifier {
    let offset: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

// MARK: - The bubbles

/// A bubble's type and measures at one font size. The text is the session
/// titles' font — `SipFont.sidebarRow`, regular weight — following Settings
/// → Display. The bubble is as tall as its lines: one line a short stadium,
/// more lines growing it from the mark's middle both ways, never taller
/// than the mark with its straw (`maxHeight`); past that the text is cut.
///
/// A plain value of the font scale, so a harness reads every size's
/// numbers (`Verification/SidebarNotices`).
struct SidebarBubbleMetrics {
    /// Above and below the text. Fixed, like the height it has to fit in:
    /// any more, and at the largest font size two lines no longer fit.
    static let verticalPadding: CGFloat = 5
    /// Before the text, and after a notice's.
    static let horizontalPadding: CGFloat = 12
    /// The tallest a bubble grows: the mark, straw included.
    static var maxHeight: CGFloat { SidebarBrandLockup.logoHeight }

    /// The gap between two lines as a share of the type's size — ONE share
    /// at every font size, so the gap grows evenly with the text: the
    /// largest that lets the largest size still hold two lines inside
    /// `maxHeight`. The sizes' own line spacing cannot be the rule here:
    /// Large text mode's doubles it, and two lines would be taller than the
    /// mark — the bubble would never hold a second line at that size.
    static let lineSpacingShare: CGFloat = {
        let largest = SipFont.sidebarRow(FontTier.allCases.map(\.scale).max() ?? FontTier.standard.scale)
        return max(0, (maxHeight - 2 * verticalPadding - 2 * line(largest)) / largest)
    }()

    /// The session titles' size.
    let textSize: CGFloat
    /// A line as SwiftUI lays text out: the font's line height rounded up
    /// to a whole point, so two lines are exactly twice one.
    let lineHeight: CGFloat
    /// Between two lines: `lineSpacingShare` of the type's size.
    let lineSpacing: CGFloat
    /// As many lines as fit inside `maxHeight`.
    let maxLines: Int
    /// A button's glyph.
    let glyphSize: CGFloat

    init(fontScale: CGFloat) {
        let size = SipFont.sidebarRow(fontScale)
        let line = Self.line(size)
        let spacing = size * Self.lineSpacingShare
        // The largest size's two lines fill `maxHeight` exactly; the
        // tolerance keeps a rounding error in the share from costing them.
        var lines = 1
        while lines < 8, Self.height(lines: lines + 1, line: line, spacing: spacing) <= Self.maxHeight + 0.001 {
            lines += 1
        }
        textSize = size
        lineHeight = line
        lineSpacing = spacing
        maxLines = lines
        glyphSize = SipFont.scaled(11, fontScale)
    }

    /// A bubble holding `lines` lines.
    func height(lines: Int) -> CGFloat {
        Self.height(lines: lines, line: lineHeight, spacing: lineSpacing)
    }

    private static func height(lines: Int, line: CGFloat, spacing: CGFloat) -> CGFloat {
        CGFloat(lines) * line + CGFloat(max(lines - 1, 0)) * spacing + 2 * verticalPadding
    }

    private static func line(_ size: CGFloat) -> CGFloat { ceil(SipFont.lineHeight(size)) }

    var oneLineHeight: CGFloat { height(lines: 1) }
    /// A one-line bubble is a stadium; a taller one keeps its round ends as
    /// corners, the way a message bubble grows.
    var cornerRadius: CGFloat { oneLineHeight / 2 }
    /// A button's circle — and the circle its hover fills — inside a
    /// one-line bubble with 3 pt above and below,
    var buttonSize: CGFloat { oneLineHeight - 6 }
    /// and as far from the bubble's end, so the × sits in the round end.
    var buttonInset: CGFloat { (oneLineHeight - buttonSize) / 2 }
}

/// A notice that happened: its glyph and its line or two. One that names a
/// session or a chat is a button that opens it.
struct SidebarNoticeBubble: View {
    let notice: SidebarNotice
    var onOpen: (SidebarNotice) -> Void = { _ in }
    @Environment(\.sipFontScale) private var fontScale
    @State private var hovered = false

    var body: some View {
        if notice.target != nil {
            Button { onOpen(notice) } label: { face(clickable: true) }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .accessibilityAddTraits(.isButton)
        } else {
            face(clickable: false)
        }
    }

    private func face(clickable: Bool) -> some View {
        let metrics = SidebarBubbleMetrics(fontScale: fontScale)
        let shape = RoundedRectangle(cornerRadius: metrics.cornerRadius)
        return HStack(alignment: .top, spacing: 6) {
            // Centred on the first line, however many follow, and laid out
            // one line tall: the raised hand is taller than a line at some
            // sizes, and would make that bubble taller than its lines.
            Image(systemName: glyph)
                .font(.system(size: metrics.textSize))
                .frame(height: metrics.lineHeight)
            Text(verbatim: notice.line)
                .font(.system(size: metrics.textSize))
                .lineSpacing(metrics.lineSpacing)
                .lineLimit(metrics.maxLines)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.black)
        .padding(.horizontal, SidebarBubbleMetrics.horizontalPadding)
        .padding(.vertical, SidebarBubbleMetrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(SidebarBrandLockup.bubbleFill))
        // The hover: the fill deepens, as a row's grey appears.
        .overlay(shape.fill(Color.black.opacity(clickable && hovered ? 0.1 : 0)))
        .contentShape(shape)
        .help(notice.sentence)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notice.sentence)
    }

    /// The raised hand is the user's own sign for "needs your action".
    private var glyph: String {
        switch notice.kind {
        case .needsAction: return "hand.raised.fill"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .updated: return "arrow.down.circle.fill"
        }
    }
}

/// An update on offer: the name and the version, the button that updates
/// (or installs), and the ×.
struct UpdateOfferBubble: View {
    let item: UpdateBadgeItem
    var blockedReason: String? = nil
    var onAction: (UpdateBadgeItem) -> Void = { _ in }
    var onClose: (UpdateBadgeItem) -> Void = { _ in }
    @Environment(\.sipFontScale) private var fontScale

    var body: some View {
        let words = SidebarNoticeWords.offer(item)
        let metrics = SidebarBubbleMetrics(fontScale: fontScale)
        // The text's line or two decide the height; the buttons, smaller
        // than one line, stay on the bubble's middle.
        HStack(spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                if item.failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: metrics.textSize))
                        .frame(height: metrics.lineHeight)
                }
                Text(verbatim: words.line)
                    .font(.system(size: metrics.textSize))
                    .lineSpacing(metrics.lineSpacing)
                    .lineLimit(metrics.maxLines)
                    .truncationMode(.tail)
            }
            .padding(.vertical, SidebarBubbleMetrics.verticalPadding)
            .help(words.sentence)
            Spacer(minLength: 4)
            NoticeIconButton(systemName: "arrow.down.circle",
                             label: SidebarNoticeWords.offerAction(item),
                             disabledReason: blockedReason,
                             metrics: metrics) {
                onAction(item)
            }
            NoticeIconButton(systemName: "xmark",
                             label: String(localized: "Close",
                                           comment: "Sidebar notice beside the logo: hover and accessibility label of the × that hides an update on offer until a newer version is out"),
                             metrics: metrics) {
                onClose(item)
            }
        }
        .foregroundStyle(Color.black)
        .padding(.leading, SidebarBubbleMetrics.horizontalPadding)
        .padding(.trailing, metrics.buttonInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: metrics.cornerRadius).fill(SidebarBrandLockup.bubbleFill))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(words.sentence)
    }
}

/// A round glyph button inside a bubble. Under the pointer its circle
/// fills, the bubble's version of the sidebar's hover grey; a disabled one
/// is dimmed and says why on hover.
private struct NoticeIconButton: View {
    let systemName: String
    /// What it does: its hover, and its VoiceOver name.
    let label: String
    /// Why it cannot be used now; nil when it can.
    var disabledReason: String? = nil
    /// The bubble's measures: the glyph's size and the circle's.
    let metrics: SidebarBubbleMetrics
    let action: () -> Void
    @State private var hovered = false

    private var enabled: Bool { disabledReason == nil }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: metrics.glyphSize, weight: .bold))
                .frame(width: metrics.buttonSize, height: metrics.buttonSize)
                .background(Circle().fill(Color.black.opacity(enabled && hovered ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .help(disabledReason ?? label)
        .accessibilityLabel(label)
        .accessibilityHint(disabledReason ?? "")
    }
}
