// UsagePane.swift
// Settings → Usage: what each listed agent's plan reports — the figures
// the toolbar's T window shows, read by the same UsageMonitor — with what
// only a page has room for: Claude Code's own account of what is using
// the limits, Codex's credits, spend cap, resets and token history, and a
// link to each tool's own usage page. An agent on an API key gets one
// line and its provider's page. A codex limit reset is used here, through
// codex's own app-server, after codex's own confirmation.
//
// Nothing here polls. The figures are asked for when the section appears
// — unless a reading finished in the last minute, so "Learn more" from a
// window that has just read them starts nothing — and on ↻. The only
// clock is the status line's leaf TimelineView.

import SwiftUI
import AppKit

struct UsagePane: View {
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var agents: AgentManager
    @ObservedObject private var monitor = UsageMonitor.shared
    @ObservedObject private var updates = AgentCLIUpdateMonitor.shared
    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.sipLineSpacingFactor) private var lineSpacingFactor

    /// Read off the MainActor as the section appears and when an account
    /// changes, never in a body pass: where claude's key is billed (a
    /// cloud provider, or a host other than Anthropic's API, has no
    /// Anthropic page), and the provider kimi runs its key on.
    @State private var claude = ClaudeRoute()
    @State private var kimiKeyProviderId: String?

    /// What claude's child environment says about where a key is billed.
    private struct ClaudeRoute: Equatable {
        var cloudProvider: String?
        var baseURL: String?
    }

    private enum Block: Identifiable {
        case plan(PlanUsageCard)
        case apiKey(AgentInfo)

        var id: String {
            switch self {
            case .plan(let card): return card.agentKey
            case .apiKey(let agent): return agent.key
            }
        }
    }

    /// One block per listed agent, in registry order: a plan's card, or
    /// an API key's line. An agent whose account kind is not read yet has
    /// none — the window shows none for it either.
    private var blocks: [Block] {
        agents.listedAgents.compactMap { agent in
            switch monitor.accounts[agent.key] {
            case .plan?:
                return monitor.cards.first { $0.agentKey == agent.key }.map(Block.plan)
            case .apiKey?:
                return .apiKey(agent)
            default:
                return nil
            }
        }
    }

    private var rhythm: CGFloat {
        SipFont.gapScale(12, fontScale: fontScale, lineSpacingFactor: lineSpacingFactor)
    }

    /// A vertical gap stated at Default, at the tier's line pitch.
    private func gap(_ points: CGFloat) -> CGFloat { points * rhythm }

    var body: some View {
        let blocks = self.blocks
        VStack(alignment: .leading, spacing: gap(12)) {
            intro(showsReading: monitor.refreshing || blocks.contains {
                if case .plan = $0 { return true }
                return false
            })
            if agents.listedAgents.isEmpty {
                Text("No agent is set up yet. Install and sign in to one in Settings → Agent Initialization.",
                     comment: "Settings → Usage when no agent is listed")
                    .sipFont(12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(blocks) { block in
                Divider().padding(.vertical, 4)
                switch block {
                case .plan(let card): planBlock(card)
                case .apiKey(let agent): apiKeyBlock(agent)
                }
            }
            Divider().padding(.vertical, 4)
            Text("Chats are billed per token to your API keys. Each provider's dashboard shows their usage and cost.",
                 comment: "Settings → Usage, last line: chats are not on a plan")
                .sipFont(12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // The tier's line spacing, once, for every wrapped line.
        .lineSpacing(SipFont.lineSpacing(12, fontScale: fontScale, lineSpacingFactor: lineSpacingFactor))
        .onAppear {
            monitor.refreshIfStale()
            monitor.loadCodexHistory(installedCodex: updates.installed["codex"])
            Task { await readAccountFacts() }
        }
        .onChange(of: monitor.accounts) { _, _ in
            monitor.loadCodexHistory(installedCodex: updates.installed["codex"])
            Task { await readAccountFacts() }
        }
        // A codex version read after the section appeared.
        .onChange(of: updates.installed["codex"]) { _, version in
            monitor.loadCodexHistory(installedCodex: version)
        }
        // A confirmation or an outcome is not left up for the next visit.
        .onDisappear { monitor.cancelReset() }
    }

    // MARK: The section's head

    private func intro(showsReading: Bool) -> some View {
        VStack(alignment: .leading, spacing: gap(6)) {
            Text("Usage", comment: "Settings pane header")
                .sipFont(14, weight: .semibold)
            Text("What each agent's plan reports, asked of the agent's own tool on this Mac. No tokens are spent.",
                 comment: "Settings → Usage, under its header")
                .sipFont(12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if showsReading {
                HStack(spacing: 6) {
                    UsageStatusLine(refreshing: monitor.refreshing, updatedAt: monitor.updatedAt, size: 12)
                    UsageRefreshButton(refreshing: monitor.refreshing, size: 12) { monitor.refresh() }
                }
            }
        }
    }

    // MARK: An agent's title line

    /// The agent's name and what it runs on, with the tool's own page at
    /// the right — or under the name, where the column is too narrow for
    /// both on one line.
    private func blockTitle(agentKey: String, defaultName: String, detail: String,
                            page: URL?) -> some View {
        let name = config.agentLabel(for: agentKey, defaultName: defaultName)
        let link = page.flatMap { PlanUsagePages.opensSafely($0, agentKey: agentKey) ? $0 : nil }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                titleWords(name: name, detail: detail)
                Spacer(minLength: 12)
                if let link { pageLink(link, agentKey: agentKey) }
            }
            VStack(alignment: .leading, spacing: gap(4)) {
                titleWords(name: name, detail: detail)
                if let link { pageLink(link, agentKey: agentKey) }
            }
        }
    }

    private func titleWords(name: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: name)
                .sipFont(14, weight: .semibold)
                .foregroundColor(SipDesign.textPrimary)
            Text(verbatim: "·")
                .sipFont(14)
                .foregroundColor(SipDesign.textHint)
            Text(verbatim: detail)
                .sipFont(14)
                .foregroundColor(SipDesign.textSecondary)
        }
    }

    private func pageLink(_ page: URL, agentKey: String) -> some View {
        let site = page.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
        return LinkButton(
            title: String(localized: "Open usage on \(site)",
                          comment: "Settings → Usage: link to the agent's own usage page in the browser; placeholder is the site, such as claude.ai"),
            size: 12, leavesApp: true) {
                // Checked again at the click: nothing opens that is not
                // https on one of the agent's own hosts.
                if PlanUsagePages.opensSafely(page, agentKey: agentKey) {
                    NSWorkspace.shared.open(page)
                }
            }
    }

    // MARK: A plan

    private func planBlock(_ card: PlanUsageCard) -> some View {
        VStack(alignment: .leading, spacing: gap(8)) {
            blockTitle(agentKey: card.agentKey, defaultName: card.defaultName,
                       detail: PlanUsageCardView.planLabel(for: card),
                       page: PlanUsagePages.page(agentKey: card.agentKey, onPlan: true,
                                                 claudeCloudProvider: nil,
                                                 kimiRegion: card.kimiRegion,
                                                 kimiKeyProviderId: nil))
            PlanUsageCardView(card: card, refreshing: monitor.refreshing, style: .settings)
            if card.agentKey == "claude_code", let text = card.contributing {
                ClaudeContributingView(text: text)
                    .opacity(card.stale ? 0.55 : 1)
            }
            if card.agentKey == "codex" {
                codexDetail(card)
            }
        }
    }

    // MARK: Codex

    @ViewBuilder
    private func codexDetail(_ card: PlanUsageCard) -> some View {
        if let detail = card.codex {
            accountLines(detail).opacity(card.stale ? 0.55 : 1)
            resets(detail)
        }
        codexHistory
    }

    @ViewBuilder
    private func accountLines(_ detail: CodexAccountDetail) -> some View {
        VStack(alignment: .leading, spacing: gap(4)) {
            if let reached = detail.reached, let sentence = CodexUsageAnswer.reachedSentence(reached) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .sipFont(11)
                    Text(verbatim: sentence)
                        .sipFont(12)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(.orange)
            }
            if detail.unlimited {
                Text("Credits: unlimited",
                     comment: "Settings → Usage: the Codex account's credits have no limit")
                    .sipFont(12)
                    .foregroundColor(SipDesign.textSecondary)
            } else if let balance = detail.balance {
                Text(verbatim: String(localized: "Credits: \(Self.amount(balance))",
                                      comment: "Settings → Usage: the Codex account's credits balance, as codex states it"))
                    .sipFont(12)
                    .foregroundColor(SipDesign.textSecondary)
            }
            if let cap = detail.spendCap {
                spendCapLine(cap)
            }
        }
    }

    /// "Workspace spend cap · 125.5 of 500 · resets Oct 30, 9:00 PM",
    /// wrapping as one sentence.
    private func spendCapLine(_ cap: CodexSpendCap) -> some View {
        var line = Text("Workspace spend cap",
                        comment: "Settings → Usage: a spend cap the Codex workspace sets, followed by how much of it is used")
        line = line + Text(verbatim: " · " + PlanUsageCardView.ofText(Self.amount(cap.used),
                                                                      Self.amount(cap.limit)))
        let reset = PlanUsageCardView.reset(for: PlanUsageRow(label: nil, window: nil, percent: nil,
                                                              used: nil, limit: nil, resetText: nil,
                                                              resetDate: cap.resetsAt))
        if !reset.isEmpty { line = line + Text(verbatim: " · " + reset) }
        return line
            .sipFont(12)
            .foregroundColor(SipDesign.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A decimal as codex states it ("480.7707625000"), to two places;
    /// anything that is not a number stays as written.
    private static func amount(_ text: String) -> String {
        guard let value = Double(text), value.isFinite else { return text }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    // MARK: Codex's resets

    @ViewBuilder
    private func resets(_ detail: CodexAccountDetail) -> some View {
        let listed = detail.resets ?? []
        if detail.resetsAvailable > 0 || !listed.isEmpty || hasResetOutcome {
            VStack(alignment: .leading, spacing: gap(6)) {
                Text("Usage limit resets",
                     comment: "Settings → Usage: heading of the Codex limit resets, in codex's own words")
                    .sipFont(12, weight: .semibold)
                    .foregroundColor(SipDesign.textPrimary)
                if detail.resetsAvailable > 0 {
                    Text(verbatim: PlanUsageCardView.resetCountText(detail.resetsAvailable))
                        .sipFont(12)
                        .foregroundColor(SipDesign.textSecondary)
                }
                if !listed.isEmpty {
                    ForEach(listed) { credit in
                        resetRow(creditId: credit.id, title: credit.title,
                                 description: credit.description, expiresAt: credit.expiresAt)
                    }
                } else if detail.resetsAvailable > 0 {
                    // Codex knows the count alone: the request names no
                    // reset, and codex's backend picks the next one.
                    resetRow(creditId: nil, title: nil, description: nil, expiresAt: nil)
                }
                if detail.resetsAvailable > 0 || !listed.isEmpty,
                   CodexResetConsume.needsNewerCodex(installedCodex: updates.installed["codex"]) {
                    Text(verbatim: String(localized: "Update \(agents.agentLabel(for: "codex")) to use a reset here.",
                                          comment: "Settings → Usage: the installed Codex is too old to use a limit reset from SipAI; placeholder is the Codex label"))
                        .sipFont(12)
                        .foregroundColor(SipDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                resetOutcome
            }
        }
    }

    private func resetRow(creditId: String?, title: String?, description: String?,
                          expiresAt: Date?) -> some View {
        let offered = CodexResetConsume.offered(installedCodex: updates.installed["codex"])
        return VStack(alignment: .leading, spacing: gap(6)) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: gap(2)) {
                    Text(verbatim: title ?? String(localized: "Usage limit reset",
                                                   comment: "Settings → Usage: one Codex limit reset that codex names nothing, in codex's own words"))
                        .sipFont(12)
                        .foregroundColor(SipDesign.textPrimary)
                    if let description {
                        Text(verbatim: description)
                            .sipFont(12)
                            .foregroundColor(SipDesign.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let expiresAt {
                        Text(verbatim: String(localized: "Expires \(expiresAt.formatted(date: .abbreviated, time: .shortened))",
                                              comment: "Settings → Usage: when a Codex limit reset can no longer be used; placeholder is a date and time"))
                            .sipFont(11)
                            .foregroundColor(SipDesign.textHint)
                    }
                }
                Spacer(minLength: 12)
                if offered, !isConfirming(creditId) {
                    // Not while the figures are read again: right after a
                    // reset is used, the list still holds it until the
                    // reading lands.
                    Button(String(localized: "Use reset…",
                                  comment: "Settings → Usage: button that asks to use a Codex limit reset; codex's confirmation follows")) {
                        monitor.askToUseReset(creditId: creditId)
                    }
                    .sipFont(12)
                    .disabled(isRunning || monitor.refreshing)
                }
            }
            if isConfirming(creditId) {
                confirmation(creditId: creditId)
            } else if case .running(let running) = monitor.resetStep, running == creditId {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 14 * SipFont.ratio(fontScale), height: 14 * SipFont.ratio(fontScale))
                    Text("Resetting your usage...",
                         comment: "Settings → Usage: a Codex limit reset is being used, in codex's own words")
                        .sipFont(12)
                        .foregroundColor(SipDesign.textSecondary)
                }
            }
        }
    }

    /// Codex's own confirmation — its words, its two answers. Using a
    /// reset cannot be undone, so nothing answers it but a click: no
    /// default button, no Return.
    private func confirmation(creditId: String?) -> some View {
        VStack(alignment: .leading, spacing: gap(8)) {
            Text("Use this reset?",
                 comment: "Settings → Usage: Codex's own confirmation before a limit reset is used")
                .sipFont(12, weight: .semibold)
                .foregroundColor(SipDesign.textPrimary)
            HStack(spacing: 8) {
                Button {
                    monitor.cancelReset()
                } label: {
                    Text("No, go back",
                         comment: "Settings → Usage: Codex's own answer that keeps the limit reset")
                }
                .sipFont(12)
                .keyboardShortcut(.cancelAction)
                Button {
                    monitor.useReset(creditId: creditId)
                } label: {
                    Text("Yes, use reset",
                         comment: "Settings → Usage: Codex's own answer that uses the limit reset; it cannot be undone")
                }
                .sipFont(12)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(10 * SipFont.ratio(fontScale))
        .background(RoundedRectangle(cornerRadius: 8).fill(SipDesign.rowHover.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(SipDesign.borderLight, lineWidth: 1))
    }

    /// Codex's answer, in its words, until the section is left or another
    /// attempt starts. Under the list rather than on a row: the reset it
    /// used is gone from the list once the figures are read again.
    @ViewBuilder
    private var resetOutcome: some View {
        if case .finished(_, let outcome) = monitor.resetStep {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: Self.mark(for: outcome.tone))
                    .sipFont(11)
                Text(verbatim: outcome.sentence)
                    .sipFont(12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(outcome.tone == .problem ? .orange : SipDesign.textSecondary)
        }
    }

    private static func mark(for tone: CodexResetConsume.Outcome.Tone) -> String {
        switch tone {
        case .done: return "checkmark.circle"
        case .info: return "info.circle"
        case .problem: return "exclamationmark.triangle"
        }
    }

    private func isConfirming(_ creditId: String?) -> Bool {
        if case .confirming(let confirming) = monitor.resetStep { return confirming == creditId }
        return false
    }

    private var isRunning: Bool {
        if case .running = monitor.resetStep { return true }
        return false
    }

    /// Codex's answer stays up after the reset it used has left the list.
    private var hasResetOutcome: Bool {
        if case .finished = monitor.resetStep { return true }
        return false
    }

    // MARK: Codex's history

    /// Codex's own overview, in its order: the five figures, then the year
    /// of token activity.
    @ViewBuilder
    private var codexHistory: some View {
        if let history = monitor.codexHistory {
            VStack(alignment: .leading, spacing: gap(12)) {
                CodexHistoryFigures(history: history)
                VStack(alignment: .leading, spacing: gap(6)) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Token activity",
                             comment: "Settings → Usage: heading of the Codex account's tokens per day, codex's own term")
                            .sipFont(12, weight: .semibold)
                            .foregroundColor(SipDesign.textPrimary)
                        Text(verbatim: "·")
                            .sipFont(12)
                            .foregroundColor(SipDesign.textHint)
                        Text("Last 12 months",
                             comment: "Settings → Usage: what the Codex token activity calendar covers, codex's own term")
                            .sipFont(12)
                            .foregroundColor(SipDesign.textSecondary)
                    }
                    if history.reportsDays {
                        TokenActivityCalendar(model: CodexActivityCalendar.make(history, today: Date()))
                    } else {
                        Text("Token activity history unavailable",
                             comment: "Settings → Usage: Codex sent no days of token activity, codex's own words")
                            .sipFont(12)
                            .foregroundColor(SipDesign.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else if let failure = monitor.codexHistoryFailure {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "exclamationmark.triangle")
                    .sipFont(11)
                Text(verbatim: failure)
                    .sipFont(12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(.orange)
        }
    }

    // MARK: An API key

    private func apiKeyBlock(_ agent: AgentInfo) -> some View {
        let cloud = agent.key == "claude_code" ? claude.cloudProvider : nil
        let page = PlanUsagePages.page(agentKey: agent.key, onPlan: false,
                                       claudeCloudProvider: cloud, claudeBaseURL: claude.baseURL,
                                       kimiRegion: nil, kimiKeyProviderId: kimiKeyProviderId)
        return VStack(alignment: .leading, spacing: gap(6)) {
            blockTitle(agentKey: agent.key, defaultName: agent.name,
                       detail: cloud.map(Self.cloudName)
                        ?? String(localized: "API key", comment: "Settings → Usage: the agent runs on an API key"),
                       page: page)
            Text(verbatim: Self.apiKeySentence(cloud: cloud != nil, hasPage: page != nil))
                .sipFont(12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func apiKeySentence(cloud: Bool, hasPage: Bool) -> String {
        if cloud {
            return String(localized: "Billed through your cloud provider. Its console shows the usage and cost.",
                          comment: "Settings → Usage: the agent runs through Amazon Bedrock, Google Vertex AI or Microsoft Foundry")
        }
        if hasPage {
            return String(localized: "An API key has no plan limits to show here: it is billed per token, and its usage and cost are on the provider's page.",
                          comment: "Settings → Usage: the agent runs on an API key; a link to the provider's page is beside it")
        }
        return String(localized: "An API key has no plan limits to show here: it is billed per token by the platform that issued it.",
                      comment: "Settings → Usage: the agent runs on an API key from a platform SipAI has no page for")
    }

    /// The cloud's product name, as each vendor writes it.
    private static func cloudName(_ provider: String) -> String {
        switch provider {
        case "bedrock": return "Amazon Bedrock"
        case "vertex": return "Google Vertex AI"
        case "foundry": return "Microsoft Foundry"
        default: return provider
        }
    }

    /// The facts the API-key lines need, read off the MainActor.
    private func readAccountFacts() async {
        let kimiFile = KimiSessionScanner.configFile
        let facts = await Task.detached(priority: .utility) { () -> (ClaudeRoute, String?) in
            let env = ClaudeModelCatalog.childEnvironmentFacts()
            let base = (try? String(contentsOf: kimiFile, encoding: .utf8))
                .flatMap(KimiConfigProviders.keyedBaseURL(configText:))
            return (ClaudeRoute(cloudProvider: env.provider, baseURL: env.baseURL),
                    base.flatMap { AgentSignIn.kimiKeyProvider(forBaseURL: $0)?.id })
        }.value
        if claude != facts.0 { claude = facts.0 }
        if kimiKeyProviderId != facts.1 { kimiKeyProviderId = facts.1 }
    }
}

/// Claude Code's "What's contributing to your limits usage?" block: its
/// heading and note, then its periods as one table — every word claude's
/// (`ClaudeContributing`), laid out as the page lays out its other
/// figures. A block in a shape SipAI does not read is shown as claude
/// wrote it.
private struct ClaudeContributingView: View {
    let text: String
    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.sipLineSpacingFactor) private var lineSpacingFactor

    private func gap(_ points: CGFloat) -> CGFloat {
        points * SipFont.gapScale(12, fontScale: fontScale, lineSpacingFactor: lineSpacingFactor)
    }

    var body: some View {
        if let block = ClaudeContributing.parse(text) {
            VStack(alignment: .leading, spacing: gap(6)) {
                Text(verbatim: block.heading)
                    .sipFont(12, weight: .semibold)
                    .foregroundColor(SipDesign.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(block.notes.enumerated()), id: \.offset) { _, note in
                    Text(verbatim: note)
                        .sipFont(12)
                        .foregroundColor(SipDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !block.periods.isEmpty {
                    table(block.periods)
                        .padding(.top, gap(2))
                }
            }
            .textSelection(.enabled)
        } else {
            Text(verbatim: text)
                .font(.system(size: SipFont.scaled(11, fontScale), design: .monospaced))
                .foregroundColor(SipDesign.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// The periods in one box, each opening on a band with its counts.
    private func table(_ periods: [ClaudeContributing.Period]) -> some View {
        let inset = 10 * SipFont.ratio(fontScale)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(periods.enumerated()), id: \.offset) { index, period in
                if index > 0 { Divider() }
                header(period, inset: inset)
                Divider()
                VStack(alignment: .leading, spacing: gap(4)) {
                    ForEach(Array(period.rows.enumerated()), id: \.offset) { _, row in
                        rowViews(row)
                    }
                }
                .padding(.horizontal, inset)
                .padding(.vertical, gap(6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SipDesign.borderLight, lineWidth: 1))
    }

    private func header(_ period: ClaudeContributing.Period, inset: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: period.title)
                .sipFont(12, weight: .semibold)
                .foregroundColor(SipDesign.textPrimary)
            Spacer(minLength: 0)
            if let detail = period.detail {
                Text(verbatim: detail)
                    .sipFont(12)
                    .foregroundColor(SipDesign.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, inset)
        .padding(.vertical, gap(5))
        .background(Color.gray.opacity(0.08))
    }

    @ViewBuilder
    private func rowViews(_ row: ClaudeContributing.Row) -> some View {
        switch row {
        case .share(let percent, let text):
            line(percent: percent, text: text)
        case .top(let title, let items, let more):
            VStack(alignment: .leading, spacing: gap(3)) {
                line(percent: nil, text: title, isTitle: true)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    line(percent: item.percent, text: item.name)
                }
                if let more {
                    line(percent: nil, text: more)
                }
            }
            .padding(.top, gap(4))
        }
    }

    /// The percent right-aligned in a column as wide as "100%", then
    /// claude's words.
    private func line(percent: Int?, text: String, isTitle: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10 * SipFont.ratio(fontScale)) {
            ZStack(alignment: .trailing) {
                Text(verbatim: "100%").hidden()
                if let percent {
                    Text(verbatim: "\(percent)%")
                        .foregroundColor(SipDesign.textPrimary)
                }
            }
            .sipFont(12)
            .monospacedDigit()
            Text(verbatim: text)
                .sipFont(12, weight: isTitle ? .medium : .regular)
                .foregroundColor(isTitle ? SipDesign.textPrimary : SipDesign.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Codex's five figures, as its terminal's usage overview gives them:
/// each value over its name, in codex's order, "—" for one codex does
/// not state. Five across where they fit, else three or two to a row.
private struct CodexHistoryFigures: View {
    let history: CodexUsageHistory
    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.sipLineSpacingFactor) private var lineSpacingFactor

    private struct Figure {
        var value: String
        var label: String
    }

    private func gap(_ points: CGFloat) -> CGFloat {
        points * SipFont.gapScale(12, fontScale: fontScale, lineSpacingFactor: lineSpacingFactor)
    }

    private var figures: [Figure] {
        func tokens(_ value: Int64?) -> String {
            value.map { $0.formatted(.number.notation(.compactName)) } ?? "—"
        }
        return [
            Figure(value: tokens(history.lifetimeTokens),
                   label: String(localized: "Lifetime tokens",
                                 comment: "Settings → Usage: every token the Codex account has used, codex's own term")),
            Figure(value: tokens(history.peakDailyTokens),
                   label: String(localized: "Peak tokens",
                                 comment: "Settings → Usage: the most tokens the Codex account used in one day, codex's own term")),
            Figure(value: history.longestRunningTurnSec.map(Self.duration) ?? "—",
                   label: String(localized: "Longest chat",
                                 comment: "Settings → Usage: how long the Codex account's longest single turn ran, codex's own term")),
            Figure(value: history.currentStreakDays.map(Self.days) ?? "—",
                   label: String(localized: "Current streak",
                                 comment: "Settings → Usage: consecutive days the Codex account was used up to today, codex's own term")),
            Figure(value: history.longestStreakDays.map(Self.days) ?? "—",
                   label: String(localized: "Longest streak",
                                 comment: "Settings → Usage: the most consecutive days the Codex account was used, codex's own term")),
        ]
    }

    var body: some View {
        let figures = self.figures
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16 * SipFont.ratio(fontScale)) {
                ForEach(Array(figures.enumerated()), id: \.offset) { _, figure in
                    tile(figure)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            rows(figures, perRow: 3)
            rows(figures, perRow: 2)
        }
    }

    private func rows(_ figures: [Figure], perRow: Int) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 24 * SipFont.ratio(fontScale),
             verticalSpacing: gap(10)) {
            ForEach(Array(stride(from: 0, to: figures.count, by: perRow)), id: \.self) { start in
                GridRow {
                    ForEach(start..<min(start + perRow, figures.count), id: \.self) { index in
                        tile(figures[index])
                    }
                }
            }
        }
    }

    private func tile(_ figure: Figure) -> some View {
        VStack(alignment: .leading, spacing: gap(1)) {
            Text(verbatim: figure.value)
                .sipFont(14, weight: .semibold)
                .foregroundColor(SipDesign.textPrimary)
            Text(verbatim: figure.label)
                .sipFont(11)
                .foregroundColor(SipDesign.textSecondary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    /// "8h 32m", "45m", "3h", "12s" — codex's terminal's own rule, whole
    /// minutes and never rounded up, in the Mac's language.
    static func duration(_ seconds: Int64) -> String {
        let span = Duration.seconds(max(seconds, 0))
        if seconds < 60 {
            return span.formatted(.units(allowed: [.seconds], width: .narrow, zeroValueUnits: .show(length: 1)))
        }
        return span.formatted(.units(allowed: [.hours, .minutes], width: .narrow,
                                     fractionalPart: .hide(rounded: .down)))
    }

    static func days(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "1 day", comment: "Settings → Usage: a streak of one day")
        }
        return String(localized: "\(count) days", comment: "Settings → Usage: a streak of several days; placeholder is the count")
    }
}

/// Codex's year of token activity (`CodexActivityCalendar`): a square a
/// day, darker for more tokens, under the months and beside every other
/// weekday's name, with codex's Less … More key below. Pointing at a
/// square names its day and its tokens exactly, at once — in a bubble of
/// the app's own hint style, never a system tooltip, which appears late.
///
/// One Canvas draws all 364 squares, and one hover handler finds the
/// square under the pointer: a view per square would lay out and track
/// the pointer 364 times. Squares sit on whole points, so they stay
/// crisp on a 1x display.
private struct TokenActivityCalendar: View {
    let model: CodexActivityCalendar
    private var calendar: Calendar { model.calendar }
    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.colorScheme) private var colorScheme
    @State private var width: CGFloat = 0
    @State private var hovered: Spot?

    /// A square by its place in the drawing: the column among those shown,
    /// and the weekday row.
    private struct Spot: Equatable {
        var column: Int
        var row: Int
    }

    /// Where everything sits at a width: the weekday names' column, the
    /// month names' row, and the squares on whole points.
    struct Metrics {
        var labelWidth: CGFloat
        var labelSize: CGFloat
        var monthHeight: CGFloat
        var pitch: CGFloat
        var cell: CGFloat
        var shown: Int
        var legendGap: CGFloat
        var legendHeight: CGFloat

        var gridTop: CGFloat { monthHeight }
        var gridWidth: CGFloat { CGFloat(shown) * pitch - (pitch - cell) }
        var gridHeight: CGFloat { 7 * pitch - (pitch - cell) }
        var height: CGFloat { gridTop + gridHeight + legendGap + legendHeight }

        /// A square by its column among those shown and its weekday row.
        func rect(column: Int, row: Int) -> CGRect {
            CGRect(x: labelWidth + CGFloat(column) * pitch,
                   y: gridTop + CGFloat(row) * pitch,
                   width: cell, height: cell)
        }
    }

    /// The rows that carry their weekday's name: Monday, Wednesday and
    /// Friday. Codex's terminal names every row; a name on every row would
    /// not fit a row's height here. The week starts on Sunday, as codex's
    /// does (`CodexActivityCalendar.days`), so those are rows 1, 3 and 5.
    static func namedRows(_ calendar: Calendar) -> [Int] {
        (0..<7).filter { [2, 4, 6].contains(weekday(row: $0, calendar)) }
    }

    /// The calendar's weekday number (1 is Sunday) of a row.
    static func weekday(row: Int, _ calendar: Calendar) -> Int {
        (calendar.firstWeekday - 1 + row) % 7 + 1
    }

    static func weekdayName(row: Int, _ calendar: Calendar) -> String {
        let symbols = calendar.shortWeekdaySymbols
        guard symbols.count == 7 else { return "" }
        return symbols[weekday(row: row, calendar) - 1]
    }

    static func metrics(width: CGFloat, fontScale: CGFloat, calendar: Calendar) -> Metrics {
        let ratio = SipFont.ratio(fontScale)
        let labelSize = SipFont.scaled(10, fontScale)
        let font = NSFont.systemFont(ofSize: labelSize)
        let names = namedRows(calendar).map {
            (weekdayName(row: $0, calendar) as NSString).size(withAttributes: [.font: font]).width
        }
        let labelWidth = ((names.max() ?? 0) + 6 * ratio).rounded(.up)
        let lineHeight = SipFont.lineHeight(labelSize)
        let usable = max(width - labelWidth, 0)
        // As codex's terminal does, a column too narrow for every week
        // keeps the newest ones.
        let weeks = CodexActivityCalendar.weekCount
        let shown = max(1, min(weeks, Int(usable / (7 * ratio))))
        let pitch = max(4, min((14 * ratio).rounded(), (usable / CGFloat(shown)).rounded(.down)))
        let spacing = max(1, (pitch * 0.18).rounded())
        let cell = pitch - spacing
        return Metrics(labelWidth: labelWidth, labelSize: labelSize,
                       monthHeight: (lineHeight + 3 * ratio).rounded(.up),
                       pitch: pitch, cell: cell, shown: shown,
                       legendGap: (8 * ratio).rounded(),
                       legendHeight: max(lineHeight, cell).rounded(.up))
    }

    private func metrics(width: CGFloat) -> Metrics {
        Self.metrics(width: width, fontScale: fontScale, calendar: calendar)
    }

    /// Codex's own steps of its accent over the page for the four grades,
    /// and of the text colour for a day with none.
    private func fill(_ level: Int) -> Color {
        switch level {
        case 1: return SipDesign.blue.opacity(0.22)
        case 2: return SipDesign.blue.opacity(0.42)
        case 3: return SipDesign.blue.opacity(0.68)
        case 4: return SipDesign.blue
        default: return SipDesign.textPrimary.opacity(colorScheme == .dark ? 0.14 : 0.18)
        }
    }

    private func cell(at spot: Spot, _ m: Metrics) -> CodexActivityCalendar.Cell? {
        let column = model.weeks.count - m.shown + spot.column
        guard model.weeks.indices.contains(column), (0..<7).contains(spot.row) else { return nil }
        return model.weeks[column][spot.row]
    }

    private func spot(at point: CGPoint, _ m: Metrics) -> Spot? {
        let x = point.x - m.labelWidth, y = point.y - m.gridTop
        guard x >= 0, y >= 0 else { return nil }
        let spot = Spot(column: Int(x / m.pitch), row: Int(y / m.pitch))
        guard spot.column < m.shown, spot.row < 7, cell(at: spot, m) != nil else { return nil }
        return spot
    }

    var body: some View {
        WidthDrivenHeight(heightForWidth: { metrics(width: $0).height },
                          idealWidth: 640 * SipFont.ratio(fontScale)) {
            Canvas { context, size in
                draw(in: &context, metrics(width: size.width))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // Written only when the square changes: every move inside one
        // square would otherwise redraw all of them.
        .onContinuousHover(coordinateSpace: .local) { phase in
            var next: Spot?
            if case .active(let point) = phase { next = spot(at: point, metrics(width: width)) }
            if next != hovered { hovered = next }
        }
        // The bubble is always there and only shown over a square: an
        // overlay placed by its alignment guides inside an `if` is drawn
        // at the corner instead, its guides ignored.
        .overlay(alignment: .topLeading) {
            let m = metrics(width: width)
            let day = hovered.flatMap { cell(at: $0, m) }
            let target = hovered.map { m.rect(column: $0.column, row: $0.row) } ?? .zero
            let lift = 4 * SipFont.ratio(fontScale)
            bubble(day)
                .opacity(day == nil ? 0 : 1)
                .alignmentGuide(.leading) { d in
                    -min(max(target.midX - d.width / 2, 0), max(width - d.width, 0))
                }
                .alignmentGuide(.top) { d in -(target.minY - d.height - lift) }
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Token activity",
                                 comment: "Settings → Usage: heading of the Codex account's tokens per day, codex's own term"))
    }

    private func bubble(_ day: CodexActivityCalendar.Cell?) -> some View {
        let ratio = SipFont.ratio(fontScale)
        return HStack(spacing: 4) {
            Text(verbatim: day.map { CodexActivityCalendar.tokensText($0.tokens) } ?? "")
                .sipFont(10.5, weight: .semibold)
                .foregroundColor(SipDesign.textPrimary)
            Text(verbatim: "·")
                .sipFont(10.5)
                .foregroundColor(SipDesign.textHint)
            Text(verbatim: day.map { CodexActivityCalendar.dayText($0.date, calendar: calendar) } ?? "")
                .sipFont(10.5)
                .foregroundColor(SipDesign.textSecondary)
        }
        .padding(.horizontal, 6 * ratio)
        .padding(.vertical, 2.5 * ratio)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(SipDesign.surfaceMuted)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(SipDesign.borderLight, lineWidth: 1))
        )
        .fixedSize()
    }

    private func draw(in context: inout GraphicsContext, _ m: Metrics) {
        let font = Font.system(size: m.labelSize)
        let first = model.weeks.count - m.shown
        let radius = max(1, (m.cell * 0.2).rounded())

        // Month names over the columns codex names them over, unless one
        // would run into the name before it or past the squares.
        var nameEnd: CGFloat = -.infinity
        for column in model.monthColumns where column >= first {
            guard let day = model.weeks[column].first ?? nil else { continue }
            let name = context.resolve(Text(verbatim: Self.monthName(day.date, calendar: calendar))
                .font(font).foregroundColor(SipDesign.textSecondary))
            let x = m.labelWidth + CGFloat(column - first) * m.pitch
            let width = name.measure(in: CGSize(width: 200, height: 100)).width
            guard x >= nameEnd + 4, x + width <= m.labelWidth + m.gridWidth else { continue }
            context.draw(name, at: CGPoint(x: x, y: 0), anchor: .topLeading)
            nameEnd = x + width
        }

        for row in Self.namedRows(calendar) {
            let name = context.resolve(Text(verbatim: Self.weekdayName(row: row, calendar))
                .font(font).foregroundColor(SipDesign.textSecondary))
            let y = m.gridTop + CGFloat(row) * m.pitch + m.cell / 2
            context.draw(name, at: CGPoint(x: 0, y: y), anchor: .leading)
        }

        for column in 0..<m.shown {
            for row in 0..<7 {
                let spot = Spot(column: column, row: row)
                guard let day = cell(at: spot, m) else { continue }
                context.fill(Path(roundedRect: m.rect(column: column, row: row), cornerRadius: radius),
                             with: .color(fill(day.level)))
            }
        }
        if let spot = hovered, cell(at: spot, m) != nil {
            context.stroke(Path(roundedRect: m.rect(column: spot.column, row: spot.row).insetBy(dx: -1, dy: -1),
                                cornerRadius: radius + 1),
                           with: .color(SipDesign.textPrimary), lineWidth: 1.5)
        }

        // Less □ ▪ ■ ■ More, right under the squares' right edge.
        let less = context.resolve(Text("Less", comment: "Settings → Usage: the light end of the Codex token activity key, codex's own word")
            .font(font).foregroundColor(SipDesign.textSecondary))
        let more = context.resolve(Text("More", comment: "Settings → Usage: the dark end of the Codex token activity key, codex's own word")
            .font(font).foregroundColor(SipDesign.textSecondary))
        let bound = CGSize(width: 200, height: 100)
        let lessWidth = less.measure(in: bound).width, moreWidth = more.measure(in: bound).width
        let spacing = m.pitch - m.cell
        let gap = 4 * SipFont.ratio(fontScale)
        let keyWidth = lessWidth + gap + 5 * m.cell + 4 * spacing + gap + moreWidth
        let middle = m.gridTop + m.gridHeight + m.legendGap + m.legendHeight / 2
        var x = m.labelWidth + m.gridWidth - keyWidth
        context.draw(less, at: CGPoint(x: x, y: middle), anchor: .leading)
        x += lessWidth + gap
        for level in 0...4 {
            let square = CGRect(x: x, y: (middle - m.cell / 2).rounded(), width: m.cell, height: m.cell)
            context.fill(Path(roundedRect: square, cornerRadius: radius), with: .color(fill(level)))
            x += m.cell + spacing
        }
        x += gap - spacing
        context.draw(more, at: CGPoint(x: x, y: middle), anchor: .leading)
    }

    private static func monthName(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}

/// Hands its one view the width it is offered and takes the height that
/// view needs at that width, so a drawing whose height follows its width
/// is laid out once — never measured, then corrected a frame later.
private struct WidthDrivenHeight: Layout {
    let heightForWidth: (CGFloat) -> CGFloat
    let idealWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let offered = proposal.width ?? idealWidth
        let width = offered.isFinite ? offered : idealWidth
        return CGSize(width: width, height: heightForWidth(width))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}
