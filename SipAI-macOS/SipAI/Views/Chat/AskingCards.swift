// AskingCards.swift
// The cards a codex or kimi turn waits on in the modes that can ask — the
// permission card and the plan-review card — drawn from what the agent's
// OWN protocol sends (`MCPApprovalRequest.presentation`): its question,
// the call it wants to make, and the answers it offers, every one in its
// own words. An MCP server's link to open (`AgentLinkCard`) is here too,
// whichever agent relays it. Claude's cards (`ApprovalCards.swift`) are left as they are;
// these share their frame, their buttons and their keyboard
// (`ApprovalCardKeys`), so a card looks and answers the same whichever
// agent asked. A question from any agent is drawn by `AgentQuestionCard`.
//
// Everything the agent wrote is drawn with `Text(verbatim:)`.

import SwiftUI
import AppKit

// MARK: - The permission card

/// A call an agent asks permission for, answered with one of the agent's
/// own answers. What an answer keeps, and for how long, is the agent's
/// business: "for this session" is remembered by the agent, never by
/// SipAI's exact-call cache. The answers are drawn in one row, or in the
/// rows the card sets out (`PermissionCardContent.rows`).
struct AgentPermissionCard: View {
    let request: MCPApprovalRequest
    let content: PermissionCardContent
    /// Only the newest card takes the keys, and shows where they are.
    let ownsKeys: Bool
    let keys: ApprovalCardKeys
    /// An answer moved the session to a mode the chip follows.
    let onModeAdopted: (String) -> Void

    @EnvironmentObject private var mcpBridge: MCPBridge
    @Environment(\.sipFontScale) private var fontScale
    @State private var selection: String
    /// The card's rows did not fit it and are drawn as one column.
    @State private var stacked = false

    init(request: MCPApprovalRequest, content: PermissionCardContent,
         ownsKeys: Bool, keys: ApprovalCardKeys,
         onModeAdopted: @escaping (String) -> Void) {
        self.request = request
        self.content = content
        self.ownsKeys = ownsKeys
        self.keys = keys
        self.onModeAdopted = onModeAdopted
        _selection = State(initialValue: CardChoiceLayout.initial(content.choices) ?? "")
    }

    // Inside the transcript's re-scope: sizes are stated as shown at
    // Default and multiplied by the content ratio.
    private var ratio: CGFloat { SipFont.contentRatio(fontScale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 13 * ratio, weight: .semibold))
                    .foregroundColor(.orange)
                Group {
                    if let prompt = content.prompt {
                        Text(verbatim: prompt)
                    } else {
                        Text("Permission request", comment: "Approval card title")
                    }
                }
                .font(.system(size: 13 * ratio, weight: .semibold))
                .foregroundColor(ChatDesign.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if !request.toolName.isEmpty {
                    Text(verbatim: request.toolName)
                        .font(.system(size: 12 * ratio, weight: .semibold, design: .monospaced))
                        .foregroundColor(ChatDesign.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(ChatDesign.cardBg))
                }
            }
            CardPreviewView(preview: content.preview, ratio: ratio)
            if !content.notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(content.notes, id: \.self) { line in
                        Text(verbatim: line)
                            .font(.system(size: 12 * ratio))
                            .foregroundColor(ChatDesign.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            if content.rows != nil {
                CardChoiceRows(rows: CardChoiceLayout.rows(content.choices, arranged: content.rows),
                               selection: selection, ownsKeys: ownsKeys, ratio: ratio,
                               stacked: $stacked) { choose($0) }
            } else {
                CardChoiceRow(choices: content.choices, selection: selection,
                              ownsKeys: ownsKeys, ratio: ratio) { choose($0) }
            }
        }
        .approvalCardFrame()
        .onReceive(keys.pressed) { press in
            guard press.card == request.id else { return }
            if press.key == .activate {
                choose(selection)
            } else {
                // The keys walk what is drawn: the rows, or the column they
                // fell back to.
                selection = CardChoiceLayout.grid(content.choices, arranged: content.rows,
                                                  stacked: stacked)
                    .moved(from: selection, by: press.key)
            }
        }
    }

    private func choose(_ id: String) {
        guard let choice = content.choices.first(where: { $0.id == id }) else { return }
        mcpBridge.choose(requestId: request.id, optionId: choice.id)
        if let mode = choice.adoptsMode { onModeAdopted(mode) }
    }
}

// MARK: - The plan-review card

/// A finished plan an agent asks the user to review, with the agent's own
/// answers for it, each approval naming the mode the session continues in
/// (`PlanContinue`), as Claude Code's own plan dialog does. With one
/// approval it is drawn once per mode; with several — alternative
/// approaches the agent offers — the approach is picked first and the mode
/// next, with Back between the two. No line for what to change: neither
/// protocol carries words with a plan answer, so the user says it in the
/// composer.
struct AgentPlanReviewCard: View {
    let request: MCPApprovalRequest
    let content: PlanCardContent
    let ownsKeys: Bool
    let keys: ApprovalCardKeys
    /// An answer moved the session to a mode the chip follows.
    let onModeAdopted: (String) -> Void

    @EnvironmentObject private var mcpBridge: MCPBridge
    @Environment(\.sipFontScale) private var fontScale
    @State private var selection: String
    /// The approach picked in the first step, while the mode is asked for.
    @State private var approach: CardChoice? = nil

    init(request: MCPApprovalRequest, content: PlanCardContent,
         ownsKeys: Bool, keys: ApprovalCardKeys,
         onModeAdopted: @escaping (String) -> Void) {
        self.request = request
        self.content = content
        self.ownsKeys = ownsKeys
        self.keys = keys
        self.onModeAdopted = onModeAdopted
        _selection = State(initialValue: CardChoiceLayout.initial(PlanContinue.first(content)) ?? "")
    }

    private var ratio: CGFloat { SipFont.contentRatio(fontScale) }

    /// The answers on screen: the first step's, or the mode step's.
    private var choices: [CardChoice] {
        if let approach { return PlanContinue.second(after: approach, in: content) }
        return PlanContinue.first(content)
    }

    var body: some View {
        let plan = content.plan.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "map")
                    .font(.system(size: 13 * ratio, weight: .semibold))
                    .foregroundColor(.orange)
                Text("Plan ready for review",
                     comment: "Plan card title: an agent session in plan mode finished its plan and waits for the user's approval")
                    .font(.system(size: 13 * ratio, weight: .semibold))
                    .foregroundColor(ChatDesign.textPrimary)
                Spacer(minLength: 8)
            }
            if !plan.isEmpty {
                MarkdownRenderer.render(plan)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(ChatDesign.cardBg.opacity(0.5))
                    )
            }
            if let path = content.filePath, !path.isEmpty {
                Text(String(localized: "Saved as \((path as NSString).abbreviatingWithTildeInPath)",
                            comment: "Plan card: the file the plan was saved to; placeholder is its path"))
                    .font(.system(size: 12 * ratio))
                    .foregroundColor(ChatDesign.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let approach {
                Text(String(localized: "Continue “\(approach.label)” in which mode?",
                            comment: "Plan card, second step: the approach the user picked (placeholder, in the agent's words) is carried out in the mode picked next"))
                    .font(.system(size: 12 * ratio))
                    .foregroundColor(ChatDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CardChoiceRow(choices: choices, selection: selection,
                          ownsKeys: ownsKeys, ratio: ratio) { choose($0) }
        }
        .approvalCardFrame()
        .onReceive(keys.pressed) { press in
            guard press.card == request.id else { return }
            if press.key == .activate {
                choose(selection)
            } else {
                selection = CardChoiceLayout.grid(choices)
                    .moved(from: selection, by: press.key)
            }
        }
    }

    private func choose(_ id: String) {
        if id == PlanContinue.backId {
            let picked = approach?.id
            approach = nil
            selection = picked ?? CardChoiceLayout.initial(PlanContinue.first(content)) ?? ""
            keys.resettle()
            return
        }
        guard let choice = choices.first(where: { $0.id == id }) else { return }
        if approach == nil, PlanContinue.asksForMode(choice, in: content) {
            approach = choice
            selection = CardChoiceLayout.initial(PlanContinue.second(after: choice, in: content)) ?? ""
            // New answers under the same card: Return waits for them to
            // be read, as for a card that has just appeared.
            keys.resettle()
            return
        }
        mcpBridge.choose(requestId: request.id, optionId: choice.id)
        if let mode = choice.adoptsMode { onModeAdopted(mode) }
    }
}

// MARK: - A link an MCP server asks to have opened

/// A link an MCP server asks the user to open — to sign in somewhere, or to
/// finish a step there — while its tool call waits. The way Claude Code's
/// own dialog asks it: the link shown whole, "Open in browser" first; once
/// it is open, "I’m done, continue" answers the server, and the link can be
/// opened again. Decline (what Esc takes) refuses it. A link SipAI will not
/// open (`LinkCardContent.opens`) is shown with Decline alone.
struct AgentLinkCard: View {
    let request: MCPApprovalRequest
    let content: LinkCardContent
    let ownsKeys: Bool
    let keys: ApprovalCardKeys

    @EnvironmentObject private var mcpBridge: MCPBridge
    @Environment(\.sipFontScale) private var fontScale
    @State private var opened = false
    @State private var selection: String

    private static let openId = "open"

    init(request: MCPApprovalRequest, content: LinkCardContent,
         ownsKeys: Bool, keys: ApprovalCardKeys) {
        self.request = request
        self.content = content
        self.ownsKeys = ownsKeys
        self.keys = keys
        _selection = State(initialValue: content.opens ? Self.openId : LinkCardContent.declineId)
    }

    private var ratio: CGFloat { SipFont.contentRatio(fontScale) }

    /// The answers on screen: before the link is opened, and after.
    private var choices: [CardChoice] {
        let decline = CardChoice(id: LinkCardContent.declineId,
                                 label: String(localized: "Decline",
                                               comment: "Button on the card for an MCP server's form: send the server no answer"),
                                 role: .decline)
        guard content.opens else { return [decline] }
        let open = CardChoice(id: Self.openId,
                              label: opened
                                ? String(localized: "Open again",
                                         comment: "Button on the card for a link an MCP server asks to have opened: open it in the browser once more — Claude Code's own words")
                                : String(localized: "Open in browser",
                                         comment: "Button on the card for a link an MCP server asks to have opened — Claude Code's own words"),
                              role: opened ? .other : .accept)
        guard opened else { return [open, decline] }
        let done = CardChoice(id: LinkCardContent.acceptId,
                              label: String(localized: "I’m done, continue",
                                            comment: "Button on the card for a link an MCP server asked to have opened, once it is open: tell the server the step in the browser is done — Claude Code's own words"),
                              role: .accept)
        return [done, open, decline]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 13 * ratio, weight: .semibold))
                    .foregroundColor(.orange)
                Text(verbatim: McpElicitation.Words.wantsLink(content.asker))
                    .font(.system(size: 13 * ratio, weight: .semibold))
                    .foregroundColor(ChatDesign.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }
            if !content.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: content.message)
                    .font(.system(size: 13 * ratio))
                    .foregroundColor(ChatDesign.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            // The link whole, as it would be opened.
            Text(verbatim: AgentQuestionCard.capped(content.url))
                .font(.system(size: 12 * ratio, design: .monospaced))
                .foregroundColor(ChatDesign.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(ChatDesign.cardBg.opacity(0.5)))
            if !content.opens {
                Text("SipAI won’t open this link: it opens only https links it can show exactly as they would open.",
                     comment: "Note on the card for a link an MCP server asks to have opened, when SipAI will not open it")
                    .font(.system(size: 12 * ratio))
                    .foregroundColor(ChatDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CardChoiceRow(choices: choices, selection: selection,
                          ownsKeys: ownsKeys, ratio: ratio) { choose($0) }
        }
        .approvalCardFrame()
        .onReceive(keys.pressed) { press in
            guard press.card == request.id else { return }
            if press.key == .activate {
                choose(selection)
            } else {
                selection = CardChoiceLayout.grid(choices).moved(from: selection, by: press.key)
            }
        }
    }

    private func choose(_ id: String) {
        switch id {
        case Self.openId:
            guard content.opens, let url = URL(string: content.url) else { return }
            NSWorkspace.shared.open(url)
            let first = !opened
            opened = true
            selection = LinkCardContent.acceptId
            // New answers under the same card: Return waits for them to be
            // read, as for a card that has just appeared.
            if first { keys.resettle() }
        case LinkCardContent.acceptId, LinkCardContent.declineId:
            mcpBridge.choose(requestId: request.id, optionId: id)
        default:
            break
        }
    }
}

// MARK: - Carrying out a plan

/// "Implement this plan?" — what codex's terminal asks once a Plan turn has
/// ended on a plan (`AgentRunner.planFollowUp`), with the mode the plan is
/// carried out in named on each answer, as Claude Code's plan dialog names
/// it (`CodexAppServer.planFollowUpChoices`). No turn waits on it, so it is
/// not a bridge request: the clock does not pause for it, the sidebar does
/// not say the session waits, nothing is notified. It shares the cards'
/// frame, buttons and keyboard; the plan itself is already in the
/// transcript above it.
struct CodexPlanFollowUpCard: View {
    /// The card's id on the shared keyboard.
    let cardId: String
    let choices: [CardChoice]
    let ownsKeys: Bool
    let keys: ApprovalCardKeys
    /// The mode the plan is carried out in, as the chip spells it.
    let onImplement: (String) -> Void
    let onStay: () -> Void

    @Environment(\.sipFontScale) private var fontScale
    @State private var selection: String

    init(cardId: String, choices: [CardChoice], ownsKeys: Bool, keys: ApprovalCardKeys,
         onImplement: @escaping (String) -> Void, onStay: @escaping () -> Void) {
        self.cardId = cardId
        self.choices = choices
        self.ownsKeys = ownsKeys
        self.keys = keys
        self.onImplement = onImplement
        self.onStay = onStay
        _selection = State(initialValue: CardChoiceLayout.initial(choices) ?? "")
    }

    private var ratio: CGFloat { SipFont.contentRatio(fontScale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "map")
                    .font(.system(size: 13 * ratio, weight: .semibold))
                    .foregroundColor(.orange)
                Text(verbatim: CodexAppServer.Words.implementPlanTitle)
                    .font(.system(size: 13 * ratio, weight: .semibold))
                    .foregroundColor(ChatDesign.textPrimary)
                Spacer(minLength: 8)
            }
            CardChoiceRow(choices: choices, selection: selection,
                          ownsKeys: ownsKeys, ratio: ratio) { choose($0) }
        }
        .approvalCardFrame()
        .onReceive(keys.pressed) { press in
            guard press.card == cardId else { return }
            if press.key == .activate {
                choose(selection)
            } else {
                selection = CardChoiceLayout.grid(choices).moved(from: selection, by: press.key)
            }
        }
    }

    private func choose(_ id: String) {
        let picked = PlanContinue.split(id)
        if picked.answer == CodexAppServer.implementAnswer, let mode = picked.mode {
            onImplement(mode)
        } else {
            onStay()
        }
    }
}

// MARK: - Shared pieces

/// An agent's answers in one row while it fits, a column of equal-width
/// answers when the tier or the window makes them wider than the card.
/// Only the card that owns the keys draws its highlighted answer filled;
/// Esc takes the first plain refusal.
private struct CardChoiceRow: View {
    let choices: [CardChoice]
    let selection: String
    let ownsKeys: Bool
    let ratio: CGFloat
    let choose: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                buttons(filling: false)
            }
            VStack(alignment: .trailing, spacing: 6) {
                buttons(filling: true)
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func buttons(filling: Bool) -> some View {
        let escape = CardChoiceLayout.cancel(choices)
        ForEach(choices) { choice in
            CardChoiceButton(highlighted: ownsKeys && selection == choice.id) {
                choose(choice.id)
            } label: {
                Text(verbatim: choice.label)
                    .font(.system(size: (Self.isLight(choice.role) ? 12 : 13) * ratio,
                                  weight: choice.role == .accept ? .semibold
                                      : (Self.isLight(choice.role) ? .regular : .medium)))
                    .frame(minWidth: 72, maxWidth: filling ? .infinity : nil)
            }
            .keyboardShortcut(ownsKeys && choice.id == escape ? .cancelAction : nil)
        }
    }

    /// The answers that go further than this one call take the lighter
    /// weight, as Claude's "Always" buttons do.
    static func isLight(_ role: CardChoiceRole) -> Bool {
        role == .acceptForSession || role == .declineForSession
    }
}

/// An agent's answers in the rows its card sets out, drawn as Claude's
/// permission card draws its four: each row to the right, each column as
/// wide as its widest answer, a shorter row in the right-hand columns.
/// Rows wider than the card fall back to one column of equal-width answers
/// in the order the rows read, and `stacked` says which is on screen — the
/// arrow keys walk what is drawn. Esc takes the first plain refusal.
private struct CardChoiceRows: View {
    let rows: [[CardChoice]]
    let selection: String
    let ownsKeys: Bool
    let ratio: CGFloat
    @Binding var stacked: Bool
    let choose: (String) -> Void

    private var columns: Int { rows.map(\.count).max() ?? 0 }

    var body: some View {
        // `ViewThatFits` brings only the alternative it draws on screen, so
        // each one's `onAppear` is what tells the keys which it is.
        ViewThatFits(in: .horizontal) {
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(0..<(columns - rows[row].count), id: \.self) { _ in
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                        ForEach(rows[row]) { button($0) }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onAppear { stacked = false }
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(rows.flatMap { $0 }) { button($0) }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onAppear { stacked = true }
        }
    }

    private func button(_ choice: CardChoice) -> some View {
        let light = CardChoiceRow.isLight(choice.role)
        let escape = CardChoiceLayout.cancel(rows.flatMap { $0 })
        return CardChoiceButton(highlighted: ownsKeys && selection == choice.id) {
            choose(choice.id)
        } label: {
            Text(verbatim: choice.label)
                .font(.system(size: (light ? 12 : 13) * ratio,
                              weight: choice.role == .accept ? .semibold : (light ? .regular : .medium)))
                // Claude's card's least width for an answer; past it, the
                // whole width of the answer's column.
                .frame(minWidth: 88, maxWidth: .infinity)
        }
        .keyboardShortcut(ownsKeys && choice.id == escape ? .cancelAction : nil)
    }
}

/// What a permission card shows of the call: a command with where and
/// why, the edits it would make, or the agent's own description.
private struct CardPreviewView: View {
    let preview: CardPreview
    let ratio: CGFloat

    /// A diff is cut short past this many lines, with a line saying so.
    private static let diffLineCap = 60

    var body: some View {
        switch preview {
        case .nothing:
            EmptyView()
        case .command(let command, let cwd, let reason):
            VStack(alignment: .leading, spacing: 6) {
                box(Text(verbatim: AgentQuestionCard.capped(command))
                        .font(.system(size: 13 * ratio, design: .monospaced)))
                if let cwd, !cwd.isEmpty {
                    Label {
                        Text(verbatim: (cwd as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .font(.system(size: 12 * ratio))
                    .foregroundColor(ChatDesign.textSecondary)
                }
                reasonLine(reason)
            }
        case .fileChanges(let changes, let reason):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                    VStack(alignment: .leading, spacing: 4) {
                        // The kind where the agent names one (codex: add,
                        // delete, update); kimi sends the path alone.
                        Text(verbatim: [change.kind, (change.path as NSString).abbreviatingWithTildeInPath]
                            .filter { !$0.isEmpty }.joined(separator: "  "))
                            .font(.system(size: 12 * ratio, weight: .semibold, design: .monospaced))
                            .foregroundColor(ChatDesign.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !change.diff.isEmpty {
                            box(diffLines(change.diff))
                        }
                    }
                }
                reasonLine(reason)
            }
        case .text(let text):
            box(Text(verbatim: AgentQuestionCard.capped(text))
                    .font(.system(size: 13 * ratio)))
        }
    }

    @ViewBuilder
    private func reasonLine(_ reason: String?) -> some View {
        if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(verbatim: reason)
                .font(.system(size: 12 * ratio))
                .foregroundColor(ChatDesign.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func box<Content: View>(_ content: Content) -> some View {
        content
            .foregroundColor(ChatDesign.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(ChatDesign.cardBg.opacity(0.5)))
    }

    private func diffLines(_ diff: String) -> some View {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let shown = Array(lines.prefix(Self.diffLineCap))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line.isEmpty ? " " : line)
                    .font(.system(size: 12 * ratio, design: .monospaced))
                    .foregroundColor(Self.colour(of: line))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if lines.count > shown.count {
                Text(String(localized: "… \(lines.count - shown.count) more lines",
                            comment: "Last line of a diff cut short on an approval card; placeholder is how many lines are not shown"))
                    .font(.system(size: 12 * ratio))
                    .foregroundColor(ChatDesign.textSecondary)
            }
        }
    }

    private static func colour(of line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
            return ChatDesign.textSecondary
        }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return ChatDesign.textPrimary
    }
}
