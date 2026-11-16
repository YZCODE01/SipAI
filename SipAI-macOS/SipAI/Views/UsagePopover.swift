// UsagePopover.swift
// The toolbar's T window: one card per agent CLI that is signed in to a
// plan, each showing what that plan reports — refreshed at the click, by
// the CLI's own process (see PlanUsage.swift). "Learn more" in its header
// and "Use it" on a codex reset line close it and open Settings → Usage,
// which draws the same cards with more room (UsagePane.swift); the
// pieces the two share live here.
//
// Presented as an OVERLAY under its button, the way the search palette
// is, over a click-anywhere-else scrim. Escape closes it too.
//
// The footer is the only thing here that moves without a click: the
// "Updated just now" line ages in a leaf `TimelineView`, the shape
// `TurnClockChip` uses and for the same reason — nothing above it may
// re-render on the clock.

import SwiftUI

struct UsagePopover: View {
    @EnvironmentObject var config: ConfigManager
    @ObservedObject private var monitor = UsageMonitor.shared
    @Environment(\.sipFontScale) private var fontScale
    @FocusState private var focused: Bool

    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            content
            Divider().opacity(0.4)
            footer
        }
        .frame(width: min(400 * SipFont.ratio(fontScale), 560))
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(SipDesign.surface)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(SipDesign.borderLight, lineWidth: 1)
        )
        // Focus is what lets Escape reach a view with no text field in
        // it; the ring it would draw is not wanted on a card.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onAppear {
            focused = true
            monitor.refresh()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Plan usage", comment: "Title of the toolbar plan-usage window")
                .sipFont(13, weight: .semibold)
                .foregroundColor(SipDesign.textPrimary)
            LinkButton(title: String(localized: "Learn more",
                                     comment: "Plan-usage window: link beside its title that opens Settings → Usage"),
                       size: 12, action: openUsageSection)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Settings → Usage, where the details and codex's reset are. The
    /// window closes first: it is an overlay of the main window, and
    /// Settings replaces the pane under it.
    private func openUsageSection() {
        isPresented = false
        NotificationCenter.default.post(name: .openSettingsTab, object: nil,
                                        userInfo: [SettingsView.Tab.userInfoKey: SettingsView.Tab.usage.rawValue])
    }

    @ViewBuilder
    private var content: some View {
        if monitor.cards.isEmpty {
            Text("No agent on this Mac is signed in to a plan.",
                 comment: "Plan-usage window body when no agent CLI runs on a subscription")
                .sipFont(12)
                .foregroundColor(SipDesign.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(monitor.cards, id: \.agentKey) { card in
                    PlanUsageCardView(card: card, refreshing: monitor.refreshing,
                                      onUseResets: openUsageSection)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("For API usage, check your provider's developer platform.",
                 comment: "Plan-usage window footer: API usage is not shown here")
                .sipFont(11)
                .foregroundColor(SipDesign.textHint)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                UsageStatusLine(refreshing: monitor.refreshing, updatedAt: monitor.updatedAt, size: 11)
                Spacer()
                UsageRefreshButton(refreshing: monitor.refreshing, size: 11) { monitor.refresh() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Shared with Settings → Usage

/// Where the reading stands: a spinner while the tools are asked, then
/// the age of the last answer.
struct UsageStatusLine: View {
    var refreshing: Bool
    var updatedAt: Date?
    var size: CGFloat
    @Environment(\.sipFontScale) private var fontScale

    var body: some View {
        HStack(spacing: 6) {
            if refreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14 * SipFont.ratio(fontScale), height: 14 * SipFont.ratio(fontScale))
                Text("Updating…", comment: "Plan-usage window footer while the CLIs are being asked")
                    .sipFont(size)
                    .foregroundColor(SipDesign.textSecondary)
            } else if let updatedAt {
                UsageUpdatedLabel(updatedAt: updatedAt, size: size)
            } else {
                Text("Not updated yet", comment: "Plan-usage window footer before any answer arrived")
                    .sipFont(size)
                    .foregroundColor(SipDesign.textSecondary)
            }
        }
    }
}

/// The ↻ that asks every tool again. Lifts under the pointer like the
/// app's other icon buttons; does nothing while a reading runs.
struct UsageRefreshButton: View {
    var refreshing: Bool
    var size: CGFloat
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.sipFontScale) private var fontScale

    var body: some View {
        let lit = hovered && !refreshing
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: SipFont.scaled(size, fontScale), weight: .medium))
                .foregroundColor(lit ? SipDesign.textPrimary : SipDesign.textSecondary)
                .frame(width: (size + 9) * SipFont.ratio(fontScale),
                       height: (size + 9) * SipFont.ratio(fontScale))
                .background(RoundedRectangle(cornerRadius: 5).fill(lit ? SipDesign.rowHover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(refreshing)
        .onHover { hovered = $0 }
        .help(String(localized: "Ask again now",
                     comment: "Tooltip on the plan-usage window's refresh button"))
    }
}

// MARK: - "Updated just now"

/// Ages the last completion: "Updated just now" under a minute, then
/// the sidebar's abbreviated relative form so the two read alike. A
/// leaf `TimelineView` on a one-minute period anchored to the stamp,
/// so the flip lands on the boundary the number is counting.
struct UsageUpdatedLabel: View {
    var updatedAt: Date
    var size: CGFloat = 11

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        TimelineView(.periodic(from: updatedAt, by: 60)) { context in
            Text(verbatim: Self.text(updatedAt: updatedAt, now: context.date))
                .sipFont(size)
                .foregroundColor(SipDesign.textSecondary)
        }
    }

    static func text(updatedAt: Date, now: Date) -> String {
        if now.timeIntervalSince(updatedAt) < 60 {
            return String(localized: "Updated just now",
                          comment: "Plan-usage window footer within a minute of the last answer")
        }
        let relative = relativeFormatter.localizedString(for: updatedAt, relativeTo: now)
        return String(localized: "Updated \(relative)",
                      comment: "Plan-usage window footer; placeholder is a relative time such as '3 min. ago'")
    }
}

// MARK: - One agent's card

struct PlanUsageCardView: View {
    /// The window draws a card whole, small; Settings → Usage draws the
    /// title line itself (with the tool's page beside it) and the figures
    /// a size up, the Settings pages' text size.
    enum Style { case window, settings }

    let card: PlanUsageCard
    /// Whether a read is in flight — a card with nothing to show yet
    /// then carries a spinner rather than a bare title.
    var refreshing: Bool
    var style: Style = .window
    /// The window's codex reset line ends in "Use it", which opens
    /// Settings → Usage, where the reset is used: a glance is the wrong
    /// place for something that cannot be undone.
    var onUseResets: (() -> Void)? = nil
    @EnvironmentObject var config: ConfigManager
    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.sipLineSpacingFactor) private var lineSpacingFactor

    /// Rows and notes; the reset beside a row and a split under it one
    /// size down.
    private var textSize: CGFloat { style == .window ? 11 : 12 }
    private var smallSize: CGFloat { textSize - 1 }

    /// A vertical gap stated at Default. Settings → Usage sets the tier's
    /// line spacing, which a wrapped label or note takes, so there the
    /// gaps grow at the tier's line pitch — a fixed gap would put a
    /// label's own second line farther away than the next row at the
    /// larger tiers. The window keeps its own small rhythm.
    private func vGap(_ points: CGFloat) -> CGFloat {
        guard style == .settings else { return points }
        return points * SipFont.gapScale(textSize, fontScale: fontScale, lineSpacingFactor: lineSpacingFactor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: vGap(6)) {
            if style == .window { header }
            if let failure = card.failure {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .sipFont(smallSize)
                    Text(verbatim: failure)
                        .sipFont(textSize)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(.orange)
            }
            if card.hasFigures {
                // Only the figures dim: a stale number reads as stale,
                // while the title and a failure line stay legible.
                figures.opacity(card.stale ? 0.55 : 1)
            } else if refreshing, card.failure == nil {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 14 * SipFont.ratio(fontScale), height: 14 * SipFont.ratio(fontScale))
                    Text("Updating…", comment: "Plan-usage window footer while the CLIs are being asked")
                        .sipFont(textSize)
                        .foregroundColor(SipDesign.textHint)
                }
            }
            if let onUseResets, let count = card.codex?.resetsAvailable, count > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: Self.resetCountText(count))
                        .sipFont(textSize)
                        .foregroundColor(SipDesign.textHint)
                    Text(verbatim: "·")
                        .sipFont(textSize)
                        .foregroundColor(SipDesign.textHint)
                    LinkButton(title: String(localized: "Use it",
                                             comment: "Plan-usage window: link after the Codex reset count that opens Settings → Usage, where a reset is used"),
                               size: textSize, action: onUseResets)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(verbatim: config.agentLabel(for: card.agentKey,
                                             defaultName: card.defaultName))
                .sipFont(12, weight: .semibold)
                .foregroundColor(SipDesign.textPrimary)
            Text(verbatim: "·")
                .sipFont(12)
                .foregroundColor(SipDesign.textHint)
            Text(verbatim: Self.planLabel(for: card))
                .sipFont(12)
                .foregroundColor(SipDesign.textSecondary)
            Spacer()
        }
    }

    @ViewBuilder
    private var figures: some View {
        VStack(alignment: .leading, spacing: vGap(6)) {
            if !card.rows.isEmpty {
                Grid(alignment: .leading,
                     horizontalSpacing: style == .settings ? 8 * SipFont.ratio(fontScale) : 8,
                     verticalSpacing: vGap(5)) {
                    ForEach(Array(card.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(verbatim: Self.label(for: row))
                                .sipFont(textSize)
                                .foregroundColor(SipDesign.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .gridColumnAlignment(.leading)
                            UsageBar(fraction: row.fraction, severity: row.severity)
                                .frame(maxWidth: .infinity)
                                .frame(minWidth: 60 * SipFont.ratio(fontScale))
                            Text(verbatim: Self.value(for: row))
                                .monospacedDigit()
                                .sipFont(textSize)
                                .foregroundColor(SipDesign.textPrimary)
                                .gridColumnAlignment(.trailing)
                            Text(verbatim: Self.reset(for: row))
                                .sipFont(smallSize)
                                .foregroundColor(SipDesign.textHint)
                                .gridColumnAlignment(.trailing)
                        }
                        // Under the bar, as kimi's own /usage draws it.
                        if let split = row.split {
                            GridRow {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                Text(verbatim: Self.splitText(split))
                                    .sipFont(smallSize)
                                    .foregroundColor(SipDesign.textHint)
                                    .gridCellColumns(3)
                            }
                        }
                    }
                }
            }
            if let raw = card.rawText {
                Text(verbatim: raw)
                    .font(.system(size: SipFont.scaled(textSize - 0.5, fontScale), design: .monospaced))
                    .foregroundColor(SipDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ForEach(Array(card.notes.enumerated()), id: \.offset) { _, note in
                Text(verbatim: Self.text(for: note))
                    .sipFont(textSize)
                    .foregroundColor(SipDesign.textHint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "1 free limit reset available" / "3 free limit resets available".
    static func resetCountText(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "1 free limit reset available",
                          comment: "Plan-usage note: one Codex rate-limit reset credit")
        }
        return String(localized: "\(count) free limit resets available",
                      comment: "Plan-usage note: Codex rate-limit reset credits; placeholder is the count")
    }

    /// The plan as the CLI names it: claude's tier, codex's
    /// `planType`, kimi's membership.
    static func planLabel(for card: PlanUsageCard) -> String {
        switch card.agentKey {
        case "claude_code":
            if let name = card.planName {
                return String(localized: "\(name) plan",
                              comment: "Plan-usage card subtitle for a Claude subscription tier; placeholder is the tier ('Max', 'Pro')")
            }
            return String(localized: "Subscription",
                          comment: "Plan-usage card subtitle for a Claude subscription of unknown tier")
        case "codex":
            if let name = card.planName {
                return String(localized: "ChatGPT \(name)",
                              comment: "Plan-usage card subtitle for a Codex ChatGPT account; placeholder is the plan type")
            }
            return "ChatGPT"
        case "kimi":
            // The membership's name as kimi gives it (`KimiMembership`).
            if let name = card.planName {
                return String(
                    localized: "Membership · \(name)",
                    comment: "Plan-usage card subtitle for a Kimi membership; placeholder is Kimi's name for it")
            }
            return String(localized: "Membership",
                          comment: "Plan-usage card subtitle for a Kimi Code membership")
        default:
            return String(localized: "Plan",
                          comment: "Plan-usage card subtitle fallback")
        }
    }

    /// Claude's labels and kimi's quota rows are the tool's own words,
    /// translated where the window knows them; codex rows and kimi's older
    /// summary / limits rows are named by their window, with the model or
    /// quota name in front when there is one.
    static func label(for row: PlanUsageRow) -> String {
        let windowName = row.window.map(windowLabel)
        guard let label = row.label, !label.isEmpty else {
            return windowName ?? ""
        }
        if let windowName {
            return "\(label) · \(windowName)"
        }
        return knownLabel(label)
    }

    private static func knownLabel(_ label: String) -> String {
        switch label {
        case "5h limit":
            return String(localized: "5h limit",
                          comment: "Plan-usage row: Kimi Code's 5-hour limit, in kimi's own words")
        case "Weekly limit":
            return String(localized: "Weekly limit",
                          comment: "Plan-usage row: Kimi Code's weekly limit, in kimi's own words")
        case "Monthly limit":
            return String(localized: "Monthly limit",
                          comment: "Plan-usage row: the Kimi membership's monthly limit, in kimi's own words")
        default:
            break
        }
        if label == "Current session" {
            return String(localized: "Current session",
                          comment: "Plan-usage row: Claude's 5-hour window")
        }
        if label == "Current week (all models)" {
            return String(localized: "Current week (all models)",
                          comment: "Plan-usage row: Claude's weekly window over every model")
        }
        if label.hasPrefix("Current week ("), label.hasSuffix(")") {
            let family = String(label.dropFirst("Current week (".count).dropLast())
            return String(localized: "Current week (\(family))",
                          comment: "Plan-usage row: Claude's weekly window for one model family; placeholder is the family ('Opus', 'Sonnet only')")
        }
        return label
    }

    static func windowLabel(_ window: PlanWindow) -> String {
        switch (window.unit, window.duration) {
        case (.week, 1):
            return String(localized: "Weekly", comment: "Plan-usage row: a one-week window")
        case (.day, 1):
            return String(localized: "Daily", comment: "Plan-usage row: a one-day window")
        case (.week, let n):
            return String(localized: "\(n)-week", comment: "Plan-usage row: an n-week window")
        case (.day, let n):
            return String(localized: "\(n)-day", comment: "Plan-usage row: an n-day window")
        case (.hour, let n):
            return String(localized: "\(n)-hour", comment: "Plan-usage row: an n-hour window")
        case (.minute, let n):
            return String(localized: "\(n)-minute", comment: "Plan-usage row: an n-minute window")
        }
    }

    static func value(for row: PlanUsageRow) -> String {
        if let percent = row.percent { return "\(percent)%" }
        if let used = row.used, let limit = row.limit {
            return ofText(used.formatted(), limit.formatted())
        }
        return ""
    }

    /// "120 of 500": an amount used of a limit, both already formatted.
    static func ofText(_ used: String, _ limit: String) -> String {
        String(localized: "\(used) of \(limit)",
               comment: "Plan-usage row value as counts; placeholders are the used and the limit")
    }

    private static let resetStyle = Date.FormatStyle()
        .month(.abbreviated).day().hour().minute()

    static func reset(for row: PlanUsageRow) -> String {
        if let text = row.resetText, !text.isEmpty {
            return String(localized: "resets \(text)",
                          comment: "Plan-usage row reset, as the CLI phrased it; placeholder is the CLI's own text")
        }
        if let date = row.resetDate {
            return String(localized: "resets \(date.formatted(resetStyle))",
                          comment: "Plan-usage row reset; placeholder is a date and time")
        }
        return ""
    }

    static func text(for note: PlanUsageNote) -> String {
        switch note {
        case .usageCredits(let used, let limit, let exponent, let currency, let enabled, let reason):
            // The figures are a month's SPEND against a spending limit,
            // not a balance, so they are shown only while credits are on
            // — as claude's own /usage shows them. Printed beside "off",
            // a spend below the limit reads as money still to spend on an
            // account whose credits are used up.
            guard enabled else {
                guard let reason, !reason.isEmpty else {
                    return String(localized: "Usage credits: off",
                                  comment: "Plan-usage note: Claude's usage credits are unavailable and claude gave no reason")
                }
                return String(localized: "Usage credits: off — \(ClaudeFastModeWords.credits(reason))",
                              comment: "Plan-usage note: Claude's usage credits are unavailable; the placeholder says why (“your usage credits are used up”)")
            }
            let scale = pow(10.0, Double(exponent))
            let usedText = (Double(used) / scale).formatted(.currency(code: currency))
            let limitText = (Double(limit) / scale).formatted(.currency(code: currency))
            return String(localized: "Usage credits: \(usedText) / \(limitText) spent this month",
                          comment: "Plan-usage note: Claude's usage credits; placeholders are the amount spent this month and the monthly spending limit")
        case .extraUsage(let used, let limit, let balance, let currency):
            // Kimi's three figures, as its own /usage lists them.
            let usedText = (Double(used) / 100).formatted(.currency(code: currency))
            let balanceText = (Double(balance) / 100).formatted(.currency(code: currency))
            guard let limit else {
                return String(localized: "Extra Usage: used this month \(usedText) · no monthly limit · balance \(balanceText)",
                              comment: "Plan-usage note: Kimi's Extra Usage wallet with no monthly limit set; placeholders are the amount used this month and the balance. \"Extra Usage\" is Kimi's own name for it")
            }
            let limitText = (Double(limit) / 100).formatted(.currency(code: currency))
            return String(localized: "Extra Usage: used this month \(usedText) · monthly limit \(limitText) · balance \(balanceText)",
                          comment: "Plan-usage note: Kimi's Extra Usage wallet; placeholders are the amount used this month, the monthly limit and the balance. \"Extra Usage\" is Kimi's own name for it")
        case .noUsageData:
            return String(localized: "No usage data available.",
                          comment: "Plan-usage card: Kimi Code answered, with nothing to show — kimi's own words")
        }
    }

    /// Kimi's monthly split, in kimi's own words ("kimi 30% · code 15%").
    static func splitText(_ split: PlanUsageSplit) -> String {
        String(localized: "kimi \(split.kimiPercent)% · code \(split.codePercent)%",
               comment: "Plan-usage row: under Kimi Code's monthly limit, how much of it Kimi and Kimi Code each used, in kimi's own words; placeholders are percentages")
    }
}

// MARK: - The bar

/// A quiet capsule: neutral fill, the percentage beside it is the
/// figure. Where the tool grades the row itself (claude's server sends a
/// severity per row), its grade colours the bar; elsewhere one tint
/// change at 80 %, none for 100 % beyond the number.
struct UsageBar: View {
    var fraction: Double?
    var severity: PlanUsageSeverity? = nil
    @Environment(\.sipFontScale) private var fontScale

    private var tint: Color {
        let neutral = SipDesign.textSecondary.opacity(0.7)
        switch severity {
        case .critical: return .red
        case .warning: return .orange
        case .normal: return neutral
        case nil: return (fraction ?? 0) >= 0.8 ? .orange : neutral
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(SipDesign.borderLight)
                if let fraction {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
        }
        .frame(height: 5 * SipFont.ratio(fontScale))
    }
}
