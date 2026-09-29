// SettingsPageLayout.swift
// Where a Settings section sits in the centre pane. Pure, so its rules
// run headless (Verification/SettingsNavigation).

import CoreGraphics

/// The Settings page's column: centred in the centre pane, never wider
/// than `widest`, with the section's content left-aligned inside it.
///
/// The panes mix wrapping prose with rows of FIXED width — a label's
/// editor, a tool's update row, an Agent Guide card — and were drawn for
/// a column at least `narrowest` wide. Below that a row runs past the
/// column's edge and past the window's, taking its buttons with it, so
/// the column stops shrinking there and the page scrolls sideways
/// instead. Before the column gives up any width the gutters give way,
/// from `roomy` down to `tight`.
///
/// Widths are stated at the Default font tier and scale with the type
/// (`ratio` is `SipFont.ratio`), because every pane's text does. Every
/// result is a whole number of points: a fractional column leaves a
/// sub-point residue in the layout that shifts glyphs as the window is
/// resized — the same reason the sidebar's width is rounded.
struct SettingsPageLayout: Equatable {
    /// The widest the column gets, at Default.
    static let widest: CGFloat = 640
    /// The narrowest the column gets, at Default.
    static let narrowest: CGFloat = 420
    /// The gutter either side while the pane has room.
    static let roomy: CGFloat = 32
    /// The gutter either side once the column is at its narrowest.
    static let tight: CGFloat = 12

    /// The width the section is laid out in.
    let columnWidth: CGFloat
    /// The space either side of the column. Any width the pane has
    /// beyond the column and its two gutters is centring, not gutter.
    let gutter: CGFloat
    /// The padding left of the column: its gutter plus half the
    /// centring. `leading + columnWidth + trailing` is the pane's width
    /// whenever the column fits.
    let leading: CGFloat
    /// The padding right of the column: its gutter plus the other half
    /// of the centring — the odd point, when there is one, so the
    /// column's own left edge stays on a whole point.
    let trailing: CGFloat
    /// The column and its gutters do not fit the pane: the page scrolls
    /// sideways rather than clip a row.
    let scrollsHorizontally: Bool

    init(viewport: CGFloat, ratio: CGFloat) {
        let ratio = ratio.isFinite && ratio > 0 ? ratio : 1
        let widest = (Self.widest * ratio).rounded()
        let narrowest = (Self.narrowest * ratio).rounded()
        let viewport = viewport.isFinite ? max(0, viewport.rounded(.down)) : 0
        let column = min(widest, max(narrowest, viewport - 2 * Self.roomy))
        let gutter = max(Self.tight, min(Self.roomy, ((viewport - column) / 2).rounded(.down)))
        let centring = max(0, viewport - column - 2 * gutter)
        self.columnWidth = column
        self.gutter = gutter
        self.leading = gutter + (centring / 2).rounded(.down)
        self.trailing = gutter + centring - (centring / 2).rounded(.down)
        self.scrollsHorizontally = column + 2 * gutter > viewport
    }
}
