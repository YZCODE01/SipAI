// AgentQuestionCard.swift
// The card an agent's mid-turn question is answered on — claude's
// `AskUserQuestion`, codex's and kimi's questions, and an MCP server's
// form (`McpElicitation`) — drawn at the end of the transcript beside the
// approval cards, and answered through the bridge
// (`MCPBridge.answerQuestion`). The turn waits on it: its Stop button
// stays, and the composer's clock holds still until the answer goes back.
// The one exception is a question codex asked WITHOUT stopping
// (`MCPApprovalRequest.turnWaits` false): codex works on while it is up,
// the clock runs, and the card says so.
//
// An MCP server's form is the server's, not the agent's: the title names
// the server, its message stands under it, a typed field says what it
// takes, Submit waits for every field the form requires, and Skip is
// Decline — the server gets no answer.
//
// Several questions show ONE AT A TIME, their headers as tabs: the
// transcript only ever scrolls to its bottom edge, so a card taller than
// the pane would open with its first question above the fold.
//
// The keyboard works it the way claude's own terminal does: ↑ / ↓ move
// through a question's options and on to the buttons, ← / → turn to the
// previous or the next question, and Return takes whatever is
// highlighted — it picks the option, or presses the button
// (`ApprovalCardKeys`, `AgentQuestionKeys`).
//
// Everything the agent wrote is drawn with `Text(verbatim:)` — a
// question, a label, a description or a preview is model output, and
// must never be read as markdown or as a localization key.

import SwiftUI
import AppKit

struct AgentQuestionCard: View {
    let request: MCPApprovalRequest
    let form: AgentQuestionForm
    /// The agent under the user's own label (Settings → Labels).
    let agentName: String
    /// Only the newest card takes the keys, and shows where they are.
    let ownsKeys: Bool
    let keys: ApprovalCardKeys

    @EnvironmentObject private var mcpBridge: MCPBridge
    @Environment(\.sipFontScale) private var fontScale

    /// The answers so far and the page on screen — seeded from the
    /// bridge, which keeps them for as long as the request is pending, so
    /// a card rebuilt after a detour comes back as it was left.
    @State private var draft: AgentQuestionDraft
    /// Where the keyboard is on the page: the stop Return takes.
    @State private var stop: AgentQuestionStop
    @FocusState private var otherFocused: Bool

    init(request: MCPApprovalRequest, form: AgentQuestionForm, agentName: String,
         ownsKeys: Bool, keys: ApprovalCardKeys, savedDraft: AgentQuestionDraft?) {
        self.request = request
        self.form = form
        self.agentName = agentName
        self.ownsKeys = ownsKeys
        self.keys = keys
        let draft = savedDraft ?? AgentQuestionDraft(answers: form.initialAnswers)
        _draft = State(initialValue: draft)
        let page = min(max(0, draft.page), form.questions.count - 1)
        _stop = State(initialValue: AgentQuestionKeys.entry(for: form, page: page,
                                                            answers: draft.answers))
    }

    // Inside the transcript's re-scope: sizes are stated as shown at
    // Default and multiplied by the content ratio, like the plan card's.
    private var ratio: CGFloat { SipFont.contentRatio(fontScale) }
    private var page: Int { min(max(0, draft.page), form.questions.count - 1) }
    private var isLastPage: Bool { page == form.questions.count - 1 }
    private var canSubmit: Bool { form.canSubmit(draft.answers) }

    /// Whether the keyboard's place is drawn at `candidate`.
    private func isOn(_ candidate: AgentQuestionStop) -> Bool {
        ownsKeys && stop == candidate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if form.questions.count > 1 {
                tabs
            }
            questionPage(form.questions[page])
            // One row while it fits, two when the tier or the window
            // makes the buttons wider than the card.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    asideButtons
                    Spacer(minLength: 8)
                    pageButtons
                }
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 8) { pageButtons }
                    HStack(spacing: 8) { asideButtons }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .approvalCardFrame()
        // Written on every change, never on the way out: the view can be
        // torn down by a detour without a last callback.
        .onChange(of: draft) { _, new in
            mcpBridge.setQuestionDraft(new, for: request.id)
        }
        .onChange(of: otherFocused) { _, focused in
            if ownsKeys { keys.editingCardField = focused }
            if focused { stop = .other }
        }
        .onReceive(keys.pressed) { press in
            guard press.card == request.id else { return }
            handle(press.key)
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 13 * ratio, weight: .semibold))
                    .foregroundColor(.orange)
                Text(title)
                    .font(.system(size: 13 * ratio, weight: .semibold))
                    .foregroundColor(ChatDesign.textPrimary)
                Spacer(minLength: 8)
            }
            // A question the agent asked without stopping: the turn goes
            // on while the card is up, and the card goes when it ends.
            if !request.turnWaits {
                Text(String(localized: "\(agentName) keeps working while you answer.",
                            comment: "Line under the title of a question card the agent's turn does not wait on — Codex asked without stopping and works on; placeholder is the agent label"))
                    .font(.system(size: 12 * ratio))
                    .foregroundColor(ChatDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // An MCP server's form: what the server says it is for.
            if form.isMcpForm,
               !form.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: form.message)
                    .font(.system(size: 13 * ratio))
                    .foregroundColor(ChatDesign.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
        }
    }

    private var title: String {
        if let server = form.asker { return McpElicitation.Words.requestsInput(server) }
        return form.questions.count == 1
            ? String(localized: "\(agentName) has a question",
                     comment: "Title of the card on which the user answers the agent's question, and of the notification announcing it; placeholder is the agent label")
            : String(localized: "\(agentName) has \(form.questions.count) questions",
                     comment: "Title of the card on which the user answers the agent's questions; placeholders are the agent label and how many questions it asks")
    }

    /// One pill per question — its header, or its number when the agent
    /// gave none — ticked once answered. The page on screen is blue.
    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(Array(form.questions.enumerated()), id: \.offset) { index, question in
                let current = index == page
                let answered = draft.answers[question.text]?.value(for: question) != nil
                Button {
                    go(to: index, landingOn: nil)
                } label: {
                    HStack(spacing: 4) {
                        if answered {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9 * ratio, weight: .bold))
                        }
                        Text(verbatim: tabTitle(question, index: index))
                            .font(.system(size: 11 * ratio, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(current ? SipDesign.blue : ChatDesign.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(current ? SipDesign.blue.opacity(0.14) : ChatDesign.cardBg)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(current ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    private func tabTitle(_ question: AgentQuestionForm.Question, index: Int) -> String {
        let header = question.header.trimmingCharacters(in: .whitespacesAndNewlines)
        return header.isEmpty
            ? String(localized: "Question \(index + 1)",
                     comment: "Tab of a card holding several of the agent's questions, when the question has no short header; placeholder is its number")
            : header
    }

    private func questionPage(_ question: AgentQuestionForm.Question) -> some View {
        let answer = draft.answers[question.text] ?? AgentQuestionAnswer()
        return VStack(alignment: .leading, spacing: 8) {
            // With one question there are no tabs to carry its header.
            if form.questions.count == 1,
               !question.header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: question.header)
                    .font(.system(size: 11 * ratio, weight: .semibold))
                    .foregroundColor(ChatDesign.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(ChatDesign.cardBg))
            }
            Text(verbatim: question.text)
                .font(.system(size: 13 * ratio, weight: .medium))
                .foregroundColor(ChatDesign.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if question.multiSelect {
                Group {
                    if let bounds = question.picksHint {
                        Text(verbatim: bounds)
                    } else {
                        Text("Choose any that apply",
                             comment: "Line under a question of the agent's on which several options may be picked")
                    }
                }
                .font(.system(size: 11 * ratio))
                .foregroundColor(ChatDesign.textSecondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(question.options.enumerated()), id: \.element.label) { index, option in
                    optionRow(option, at: index, in: question,
                              picked: answer.labels.contains(option.label)
                                  && (question.multiSelect || !answer.otherPicked))
                }
                // Claude always takes the user's own words; another agent's
                // question may not, and then has no such row.
                if question.allowsOther {
                    otherRow(question, answer: answer)
                }
                // What an MCP server's typed field takes — a number, a
                // length, a format — said before anything is typed, so the
                // card never has to report a refusal after the fact.
                if let hint = question.words?.hint {
                    Text(verbatim: hint)
                        .font(.system(size: 11 * ratio))
                        .foregroundColor(answer.isUnfit(for: question) ? .orange : ChatDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                }
            }
            if let preview = answer.pickedPreview(for: question) {
                previewBox(preview)
            }
        }
    }

    /// The keyboard's place on a row: a blue outline, where a button
    /// would be drawn filled.
    private func rowOutline(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(on ? SipDesign.blue : Color.clear, lineWidth: 1.5)
    }

    private func optionRow(_ option: AgentQuestionForm.Option, at index: Int,
                           in question: AgentQuestionForm.Question,
                           picked: Bool) -> some View {
        let on = isOn(.option(index))
        return Button {
            // A click ticks the option; the keyboard then stands on the
            // main button when several may be ticked, so Return after a
            // few clicks sends the card rather than un-ticking the last.
            // (A single choice moves on by itself.)
            stop = question.multiSelect ? .primary : .option(index)
            pick(option.label, in: question)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Self.glyph(multi: question.multiSelect, on: picked))
                    .font(.system(size: 13 * ratio))
                    .foregroundColor(picked ? SipDesign.blue : ChatDesign.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: option.label)
                        .font(.system(size: 13 * ratio, weight: picked ? .semibold : .regular))
                        .foregroundColor(ChatDesign.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !option.description.isEmpty {
                        Text(verbatim: option.description)
                            .font(.system(size: 12 * ratio))
                            .foregroundColor(ChatDesign.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(picked ? SipDesign.blue.opacity(0.10)
                          : (on ? SipDesign.rowHover : Color.clear))
            )
            .overlay(rowOutline(on))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    /// The user's own answer. Typing into it picks it — instead of an
    /// option on a single-select question, beside them on a multi-select
    /// one — and Return in it does what the card's main button does.
    private func otherRow(_ question: AgentQuestionForm.Question,
                          answer: AgentQuestionAnswer) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                stop = .other
                toggleOther(in: question)
            } label: {
                Image(systemName: Self.glyph(multi: question.multiSelect, on: answer.otherPicked))
                    .font(.system(size: 13 * ratio))
                    .foregroundColor(answer.otherPicked ? SipDesign.blue : ChatDesign.textSecondary)
            }
            .buttonStyle(.plain)
            otherField(question)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13 * ratio))
                .focused($otherFocused)
                .onSubmit { primaryAction() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(rowOutline(isOn(.other)))
    }

    /// The field for the user's own words — one that does not show them
    /// when the agent marked the answer secret.
    @ViewBuilder
    private func otherField(_ question: AgentQuestionForm.Question) -> some View {
        let placeholder = !question.options.isEmpty
            ? String(localized: "Or type your own answer",
                     comment: "Placeholder of the free-text field under the options of the agent's question")
            : (form.isMcpForm && !question.required
                ? String(localized: "Type your answer (optional)",
                         comment: "Placeholder of a field of an MCP server's form that may be left empty — codex's own words")
                : String(localized: "Type your answer",
                         comment: "Placeholder of the field where the user answers an agent's question that offers no options"))
        if question.isSecret {
            SecureField(placeholder, text: otherText(for: question))
        } else {
            TextField(placeholder, text: otherText(for: question))
        }
    }

    /// The picked option's preview — a mockup or a snippet the agent
    /// attached — verbatim, in a box, cut short past a screenful.
    private func previewBox(_ preview: String) -> some View {
        Text(verbatim: Self.capped(preview))
            .font(.system(size: 12 * ratio, design: .monospaced))
            .foregroundColor(ChatDesign.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(ChatDesign.cardBg.opacity(0.5))
            )
    }

    /// The two ways out that are not an answer: let the agent choose, or
    /// talk it over first — each only where the agent's protocol carries
    /// it (`AgentQuestionForm.offersSkip`, `offersChat`).
    @ViewBuilder
    private var asideButtons: some View {
        if form.offersSkip {
            CardChoiceButton(highlighted: isOn(.skip)) {
                activate(.skip)
            } label: {
                Group {
                    if form.isMcpForm {
                        Text("Decline",
                             comment: "Button on the card for an MCP server's form: send the server no answer")
                    } else {
                        Text("Skip",
                             comment: "Question card button: do not answer; the agent chooses for itself and carries on")
                    }
                }
                .font(.system(size: 13 * ratio, weight: .medium))
                .frame(minWidth: 72)
            }
            .help(form.isMcpForm
                  ? String(localized: "The server gets no answer, and its tool goes on without one",
                           comment: "Tooltip of the Decline button on the card for an MCP server's form")
                  : String(localized: "\(agentName) chooses for itself and carries on",
                           comment: "Tooltip of the Skip button on the agent's question card; placeholder is the agent label"))
        }
        if form.offersChat {
            CardChoiceButton(highlighted: isOn(.chat)) {
                activate(.chat)
            } label: {
                Text("Chat about this",
                     comment: "Question card button: do not answer yet; the agent asks what the user wants to clarify and the turn ends there")
                    .font(.system(size: 13 * ratio, weight: .medium))
            }
            .help(String(localized: "\(agentName) asks what you’d like to clarify before you answer",
                         comment: "Tooltip of the Chat about this button on the agent's question card; placeholder is the agent label"))
        }
    }

    @ViewBuilder
    private var pageButtons: some View {
        if page > 0 {
            CardChoiceButton(highlighted: isOn(.previous)) {
                activate(.previous)
            } label: {
                Text("Previous",
                     comment: "Question card button: show the previous question")
                    .font(.system(size: 13 * ratio, weight: .medium))
                    .frame(minWidth: 72)
            }
        }
        // The main button — filled only while Return would press it.
        if isLastPage {
            CardChoiceButton(highlighted: isOn(.primary)) {
                activate(.primary)
            } label: {
                Text("Submit",
                     comment: "Question card button: send the answers to the agent")
                    .font(.system(size: 13 * ratio, weight: .semibold))
                    .frame(minWidth: 88)
            }
            .disabled(!canSubmit)
        } else {
            CardChoiceButton(highlighted: isOn(.primary)) {
                activate(.primary)
            } label: {
                Text("Next",
                     comment: "Question card button: show the next question")
                    .font(.system(size: 13 * ratio, weight: .semibold))
                    .frame(minWidth: 88)
            }
        }
    }

    // MARK: Keys

    private func handle(_ key: CardKey) {
        let grid = AgentQuestionKeys.grid(for: form, page: page)
        switch key {
        case .activate:
            activate(stop)
        case .left, .right:
            if AgentQuestionKeys.turnsPage(at: stop) {
                let target = page + (key == .left ? -1 : 1)
                guard form.questions.indices.contains(target) else { return }
                go(to: target, landingOn: AgentQuestionKeys.firstStop(for: form, page: target))
            } else {
                stop = grid.moved(from: stop, by: key)
            }
        case .up, .down:
            let next = grid.moved(from: stop, by: key)
            stop = next
            // In and out of the field with the keyboard's place: arriving
            // on the user's own answer puts the cursor in it, as claude's
            // terminal does, and an arrow leaves it again.
            otherFocused = next == .other
        }
    }

    /// What Return — or a click — does at a stop.
    private func activate(_ target: AgentQuestionStop) {
        let question = form.questions[page]
        switch target {
        case .option(let index):
            guard question.options.indices.contains(index) else { return }
            pick(question.options[index].label, in: question)
        case .other:
            otherFocused = true
        case .skip:
            mcpBridge.skipQuestion(requestId: request.id)
        case .chat:
            mcpBridge.chatAboutQuestion(requestId: request.id, answers: draft.answers)
        case .previous:
            go(to: page - 1, landingOn: nil)
        case .primary:
            primaryAction()
        }
    }

    // MARK: Actions

    private func pick(_ label: String, in question: AgentQuestionForm.Question) {
        otherFocused = false
        var answer = draft.answers[question.text] ?? AgentQuestionAnswer()
        if question.multiSelect {
            if let index = answer.labels.firstIndex(of: label) {
                answer.labels.remove(at: index)
            } else {
                answer.labels.append(label)
            }
        } else {
            answer.labels = [label]
            answer.otherPicked = false
        }
        draft.answers[question.text] = answer
        // A single choice is made in one go: on to the next question
        // still open, after a beat that shows the pick.
        if !question.multiSelect { advanceSoon(from: page) }
    }

    private func toggleOther(in question: AgentQuestionForm.Question) {
        var answer = draft.answers[question.text] ?? AgentQuestionAnswer()
        answer.otherPicked.toggle()
        if answer.otherPicked, !question.multiSelect { answer.labels = [] }
        draft.answers[question.text] = answer
    }

    private func otherText(for question: AgentQuestionForm.Question) -> Binding<String> {
        Binding(
            get: { draft.answers[question.text]?.otherText ?? "" },
            set: { text in
                var answer = draft.answers[question.text] ?? AgentQuestionAnswer()
                answer.otherText = text
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    answer.otherPicked = true
                    if !question.multiSelect { answer.labels = [] }
                }
                draft.answers[question.text] = answer
            })
    }

    /// Show another question. `landingOn` is where the keyboard goes
    /// there; nil puts it where a page opens — its first option, or the
    /// main button once the question has its answer.
    private func go(to index: Int, landingOn: AgentQuestionStop?) {
        let target = min(max(0, index), form.questions.count - 1)
        otherFocused = false
        draft.page = target
        stop = landingOn ?? AgentQuestionKeys.entry(for: form, page: target, answers: draft.answers)
    }

    /// After a single choice: the next question still open, or — with
    /// none left — the main button, so a second Return sends the card.
    private func advanceSoon(from origin: Int) {
        let stopAtPick = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            // The user may have moved on by hand meanwhile — to another
            // question, or to another answer of this one: an arrow pressed
            // inside the beat means the pick is being corrected, and moving
            // the keyboard to the main button (or the page) under it would
            // send, on the next Return, the answer being corrected.
            guard draft.page == origin, stop == stopAtPick else { return }
            if let next = AgentQuestionKeys.nextOpen(after: origin, in: form, answers: draft.answers) {
                go(to: next, landingOn: AgentQuestionKeys.firstStop(for: form, page: next))
            } else {
                stop = .primary
            }
        }
    }

    /// The main button, and Return in the free-text field: on to the next
    /// question, or send.
    private func primaryAction() {
        if isLastPage { submit() } else { go(to: page + 1, landingOn: nil) }
    }

    private func submit() {
        guard canSubmit else { return }
        mcpBridge.answerQuestion(requestId: request.id, answers: draft.answers)
    }

    // MARK: Rules

    static func glyph(multi: Bool, on: Bool) -> String {
        multi
            ? (on ? "checkmark.square.fill" : "square")
            : (on ? "largecircle.fill.circle" : "circle")
    }

    /// A preview is the agent's text: kept to a screenful — 24 lines and
    /// 2,000 characters — with an ellipsis where it was cut.
    static func capped(_ text: String) -> String {
        var out = String(text.prefix(2000))
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 24 { out = lines.prefix(24).joined(separator: "\n") }
        return out.count < text.count ? out + "\n…" : out
    }
}
