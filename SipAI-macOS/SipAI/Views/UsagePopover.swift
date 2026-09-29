// UsagePopover.swift
// The toolbar coin's dropdown: one card per agent CLI that is signed in
// to a plan, each showing what that plan reports — refreshed at the
// click, by the CLI's own process (see PlanUsage.swift).
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
        HStack {
            Text("Plan usage", comment: "Title of the toolbar plan-usage window")
                .sipFont(13, weight: .semibold)
                .foregroundColor(SipDesign.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
                    PlanUsageCardView(card: card, refreshing: monitor.refreshing)
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
                if monitor.refreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                    Text("Updating…", comment: "Plan-usage window footer while the CLIs are being asked")
                        .sipFont(11)
                        .foregroundColor(SipDesign.textSecondary)
                } else if let updatedAt = monitor.updatedAt {
                    UsageUpdatedLabel(updatedAt: updatedAt)
                } else {
                    Text("Not updated yet", comment: "Plan-usage window footer before any answer arrived")
                        .sipFont(11)
                        .foregroundColor(SipDesign.textSecondary)
                }
                Spacer()
                Button {
                    monitor.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: SipFont.scaled(11, fontScale), weight: .medium))
                        .foregroundColor(SipDesign.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(monitor.refreshing)
                .help(String(localized: "Ask again now",
                             comment: "Tooltip on the plan-usage window's refresh button"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - "Updated just now"

/// Ages the last completion: "Updated just now" under a minute, then
/// the sidebar's abbreviated relative form so the two read alike. A
/// leaf `TimelineView` on a one-minute period anchored to the stamp,
/// so the flip lands on the boundary the number is counting.
struct UsageUpdatedLabel: View {
    var updatedAt: Date

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        TimelineView(.periodic(from: updatedAt, by: 60)) { context in
            Text(verbatim: Self.text(updatedAt: updatedAt, now: context.date))
                .sipFont(11)
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
    let card: PlanUsageCard
    /// Whether a read is in flight — a card with nothing to show yet
    /// then carries a spinner rather than a bare title.
    var refreshing: Bool
    @EnvironmentObject var config: ConfigManager
    @Environment(\.sipFontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let failure = card.failure {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .sipFont(10)
                    Text(verbatim: failure)
                        .sipFont(11)
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
                        .frame(width: 14, height: 14)
                    Text("Updating…", comment: "Plan-usage window footer while the CLIs are being asked")
                        .sipFont(11)
                        .foregroundColor(SipDesign.textHint)
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
            Text(verbatim: planLabel)
                .sipFont(12)
                .foregroundColor(SipDesign.textSecondary)
            Spacer()
        }
    }

    @ViewBuilder
    private var figures: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !card.rows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                    ForEach(Array(card.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(verbatim: Self.label(for: row))
                                .sipFont(11)
                                .foregroundColor(SipDesign.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .gridColumnAlignment(.leading)
                            UsageBar(fraction: row.fraction)
                                .frame(maxWidth: .infinity)
                                .frame(minWidth: 60)
                            Text(verbatim: Self.value(for: row))
                                .monospacedDigit()
                                .sipFont(11)
                                .foregroundColor(SipDesign.textPrimary)
                                .gridColumnAlignment(.trailing)
                            Text(verbatim: Self.reset(for: row))
                                .sipFont(10)
                                .foregroundColor(SipDesign.textHint)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
            if let raw = card.rawText {
                Text(verbatim: raw)
                    .font(.system(size: SipFont.scaled(10.5, fontScale), design: .monospaced))
                    .foregroundColor(SipDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ForEach(Array(card.notes.enumerated()), id: \.offset) { _, note in
                Text(verbatim: Self.text(for: note))
                    .sipFont(11)
                    .foregroundColor(SipDesign.textHint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The plan as the CLI names it: claude's tier, codex's
    /// `planType`, kimi's membership.
    private var planLabel: String {
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
            return String(localized: "Membership",
                          comment: "Plan-usage card subtitle for a Kimi Code membership")
        default:
            return String(localized: "Plan",
                          comment: "Plan-usage card subtitle fallback")
        }
    }

    /// Claude's labels are its own words, translated where the window
    /// knows them; codex and kimi rows are named by their window, with
    /// the model or quota name in front when there is one.
    static func label(for row: PlanUsageRow) -> String {
        let windowName = row.window.map(windowLabel)
        guard let label = row.label, !label.isEmpty else {
            return windowName ?? ""
        }
        if let windowName {
            return "\(label) · \(windowName)"
        }
        return claudeLabel(label)
    }

    private static func claudeLabel(_ label: String) -> String {
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
            return String(localized: "\(used.formatted()) of \(limit.formatted())",
                          comment: "Plan-usage row value as counts; placeholders are the used and the limit")
        }
        return ""
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
        case .freeResets(let count):
            if count == 1 {
                return String(localized: "1 free limit reset available",
                              comment: "Plan-usage note: one Codex rate-limit reset credit")
            }
            return String(localized: "\(count) free limit resets available",
                          comment: "Plan-usage note: Codex rate-limit reset credits; placeholder is the count")
        case .extraUsage(let balance, let total, let currency):
            let balanceText = (Double(balance) / 100).formatted(.currency(code: currency))
            let totalText = (Double(total) / 100).formatted(.currency(code: currency))
            return String(localized: "Extra usage: \(balanceText) of \(totalText) left",
                          comment: "Plan-usage note: Kimi's extra-usage wallet; placeholders are the balance and the total")
        }
    }
}

// MARK: - The bar

/// A quiet capsule: neutral fill, the percentage beside it is the
/// figure. One tint change at 80 %, none for 100 % beyond the number.
struct UsageBar: View {
    var fraction: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(SipDesign.borderLight)
                if let fraction {
                    Capsule()
                        .fill(fraction >= 0.8 ? Color.orange : SipDesign.textSecondary.opacity(0.7))
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
        }
        .frame(height: 5)
    }
}
