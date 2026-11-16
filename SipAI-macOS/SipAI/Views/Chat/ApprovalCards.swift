// ApprovalCards.swift
// The cards a claude turn waits on at the end of its transcript — the
// permission card and the plan card — and the keyboard they share with
// the question card (`AgentQuestionCard`): the arrow keys move a card's
// highlighted choice and Return takes it. The highlighted choice is the
// one drawn filled, so what Return will do is always on screen.
//
// The rules themselves — which keys reach a card, where an arrow moves,
// what a plan approval offers, what "Allow Always" remembers — are in
// `Models/ApprovalCardRules.swift`.

import SwiftUI
import AppKit
import Combine

// MARK: - The keyboard

/// A text view that gives a waiting card the arrow keys and Return while
/// it is empty — the session's own message box, where those keys do
/// nothing else. A text view that does not say so keeps every key.
protocol CardKeyYielding: AnyObject {
    var yieldsCardKeys: Bool { get }
}

/// Arrow keys and Return for the newest card of the transcript on screen.
///
/// A local key-down monitor, because the keys have to reach the card
/// whatever has focus: the message box keeps Return for itself whenever
/// it is first responder, so a default-button shortcut alone would answer
/// a card only after a click somewhere else. Which presses are the card's
/// is `CardKeyRouting`'s rule; this class only reads the state that rule
/// is asked about.
///
/// Cards listen to `pressed` with `.onReceive`, whose handler is rebuilt
/// on every body pass — a handler stored here instead would drive the
/// card as it stood when it appeared.
final class ApprovalCardKeys {
    struct Press: Equatable {
        let card: String
        let key: CardKey
    }

    let pressed = PassthroughSubject<Press, Never>()

    /// The request id of the card that owns the keys — the newest one —
    /// and when it took them.
    private(set) var activeCard: String?
    private var activeSince = Date.distantPast

    /// A text field inside the active card is being edited.
    var editingCardField = false

    /// The window the transcript is drawn in. Keys aimed at any other
    /// window — a sheet, a popover, the usage window — are not a card's.
    weak var window: NSWindow?

    /// Whether the end of the transcript, where the cards are, is on
    /// screen. A card scrolled out of sight must not be answered by a
    /// key: the reader would be approving what they are not looking at.
    var cardIsInView: () -> Bool = { true }

    /// Whether an overlay of the transcript's own window has the keyboard
    /// — the menu over the sidebar's Settings row, the search palette,
    /// the plan-usage window. Each takes the arrows and Return for itself
    /// through the window's own dispatch, which a local monitor is
    /// consulted BEFORE; and under a focused SwiftUI view the first
    /// responder is the hosting view, as it is when nothing has focus, so
    /// `responder(in:)` cannot tell such an overlay from an idle window.
    /// It is told instead (`AppState.overlayHoldsKeys`). Without this the
    /// Return that picks a settings section allowed the tool call waiting
    /// behind the menu's scrim.
    var overlayHasKeys: () -> Bool = { false }

    private var monitor: Any?

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func setActiveCard(_ id: String?) {
        guard id != activeCard else { return }
        activeCard = id
        activeSince = Date()
        editingCardField = false
    }

    /// The active card has just put up answers nobody has read — the next
    /// step of the same card. Return waits for them as it waits for a new
    /// card (`CardKeyRouting.settle`): a second Return on the heels of the
    /// first must not answer the step it brought up.
    func resettle() {
        activeSince = Date()
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors fire on the main thread.
            guard let self, self.consumes(event) else { return event }
            return nil
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func key(for event: NSEvent) -> CardKey? {
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 36, 76: return .activate
        default: return nil
        }
    }

    /// Whether the event is the active card's, in which case it has been
    /// handed to it.
    func consumes(_ event: NSEvent) -> Bool {
        guard let card = activeCard, let key = Self.key(for: event) else { return false }
        // Shift+Return is a newline in the message box, and a modified
        // arrow is a selection or a system shortcut.
        guard event.modifierFlags
            .intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        guard let window, event.window === window, window.attachedSheet == nil else { return false }
        guard cardIsInView(), !overlayHasKeys() else { return false }
        guard CardKeyRouting.delivers(key, to: responder(in: window),
                                      cardAge: Date().timeIntervalSince(activeSince),
                                      isRepeat: event.isARepeat) else { return false }
        pressed.send(Press(card: card, key: key))
        return true
    }

    private func responder(in window: NSWindow) -> CardKeyResponder {
        // Text that can only be selected — a transcript paragraph the
        // reader clicked into — edits nothing, so it keeps no key.
        guard let text = window.firstResponder as? NSTextView, text.isEditable else { return .none }
        // An input method composing is text on its way in, whatever the
        // string says so far.
        let isEmpty = text.string.isEmpty && !text.hasMarkedText()
        if let box = text as? CardKeyYielding, box.yieldsCardKeys {
            return isEmpty ? .emptyComposer : .composing
        }
        return editingCardField ? .cardField(isEmpty: isEmpty) : .otherText
    }
}

/// Reports the window a view is drawn in.
struct CardWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ReportingView)?.onWindow = onWindow
    }

    private final class ReportingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}

// MARK: - Shared pieces

/// Hover feedback for a card's buttons. They keep their system bezels
/// (the highlighted one is `.borderedProminent` — a custom style would
/// mean re-drawing that), so the cue is a slight lift + brighten on top
/// of the bezel rather than a background wash behind it, which reads as a
/// halo around a bezel's edges. `lifted` holds the same lift on the
/// choice the keyboard is on.
struct ApprovalButtonHover: ViewModifier {
    var lifted = false
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovered || lifted ? 1.04 : 1)
            .brightness(hovered || lifted ? 0.05 : 0)
            .animation(.easeOut(duration: 0.12), value: hovered || lifted)
            .onHover { hovered = $0 }
    }
}

/// One choice of a card. The highlighted choice — the one Return takes —
/// is drawn filled and lifted; every other is a plain bordered button. A
/// click takes a choice wherever the highlight is, and pointing at one
/// never moves the highlight: a card can appear under a resting pointer.
struct CardChoiceButton<Label: View>: View {
    let highlighted: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Group {
            if highlighted {
                Button(action: action, label: label).buttonStyle(.borderedProminent)
            } else {
                Button(action: action, label: label).buttonStyle(.bordered)
            }
        }
        .modifier(ApprovalButtonHover(lifted: highlighted))
    }
}

extension View {
    /// The frame every card that holds a turn shares.
    func approvalCardFrame() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.orange.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                    )
            )
    }
}

// MARK: - The permission card

/// A tool call claude asks permission for: Allow / Deny, each once or
/// "Always".
///
/// "Allow Always" does what claude's own terminal does on "Yes, and don't
/// ask again for …": it hands claude back the rule claude itself suggests
/// for the call (`MCPApprovalRequest.alwaysOffer`), and the line under
/// the command says what that is. With no suggestion for the call it
/// remembers this exact call for the session, and says that instead.
struct ToolApprovalCard: View {
    let request: MCPApprovalRequest
    /// The folder the session runs in: a skill is looked up by its name
    /// among THAT folder's skills (`SkillDirectory`). No default — a card
    /// that looks a name up in no folder shows whichever project's skill
    /// of that name was read last, tools line and all.
    let folder: URL?
    /// Only the newest card takes the keys, and shows where they are.
    let ownsKeys: Bool
    let keys: ApprovalCardKeys
    /// "Allow Always" switched the session to a mode the chip follows.
    let onModeAdopted: (String) -> Void

    @EnvironmentObject private var mcpBridge: MCPBridge
    @Environment(\.sipFontScale) private var fontScale
    @State private var selection = ToolApprovalChoice.initial

    // Inside the transcript's re-scope: sizes are stated as shown at
    // Default and multiplied by the content ratio.
    private var ratio: CGFloat { SipFont.contentRatio(fontScale) }

    /// Claude's Skill tool: the model wants to load a skill whose own
    /// file grants it tools, which is what makes claude ask.
    private var isSkill: Bool { request.toolName == "Skill" }

    /// The skill being asked for, as the skill manager last read it in
    /// the session's folder — for its description and the tools it
    /// grants. Nil when no read has seen it; the card then shows what
    /// the request says alone.
    private var skillRow: SkillRow? {
        guard let name = SkillRecords.skillToolName(name: request.toolName,
                                                     input: request.toolInput) else { return nil }
        return SkillDirectory.lookup(name, SkillAgent.claude, folder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isSkill ? "book.closed" : "hand.raised")
                    .font(.system(size: 13 * ratio, weight: .semibold))
                    .foregroundColor(.orange)
                Group {
                    if isSkill {
                        Text("Load a skill?",
                             comment: "Approval card title when the model asks to load a skill")
                    } else {
                        Text("Permission request",
                             comment: "Approval card title")
                    }
                }
                .font(.system(size: 13 * ratio, weight: .semibold))
                .foregroundColor(ChatDesign.textPrimary)
                Spacer(minLength: 8)
                Text(verbatim: request.toolName)
                    .font(.system(size: 12 * ratio, weight: .semibold, design: .monospaced))
                    .foregroundColor(ChatDesign.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(ChatDesign.cardBg)
                    )
            }
            if !request.inputPreview.isEmpty {
                Text(verbatim: request.inputPreview)
                    .font(.system(size: 13 * ratio, design: .monospaced))
                    .foregroundColor(ChatDesign.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(ChatDesign.cardBg.opacity(0.5))
                    )
            }
            if isSkill, let skill = skillRow {
                VStack(alignment: .leading, spacing: 3) {
                    if !skill.description.isEmpty {
                        Text(verbatim: skill.description)
                            .font(.system(size: 12 * ratio))
                            .foregroundColor(ChatDesign.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let tools = skill.frontmatter.allowedTools, !tools.isEmpty {
                        Text(verbatim: String(localized: "While it runs it may use \(tools) without asking.",
                                              comment: "Skill approval card: the tools a skill grants; placeholder is the tool list"))
                            .font(.system(size: 12 * ratio))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let real = skill.realPath {
                        Text(verbatim: (real as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11 * ratio))
                            .foregroundColor(ChatDesign.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Self.alwaysLines(for: request.alwaysOffer), id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12 * ratio))
                        .foregroundColor(ChatDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    button(.denyAlways)
                        .help(String(localized: "Deny this exact call for the rest of this session",
                                     comment: "Tooltip of the Deny Always button on a permission card"))
                    button(.allowAlways)
                }
                HStack(spacing: 8) {
                    button(.deny)
                        .keyboardShortcut(ownsKeys ? .cancelAction : nil)
                    button(.allow)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .approvalCardFrame()
        .onReceive(keys.pressed) { press in
            guard press.card == request.id else { return }
            if press.key == .activate {
                choose(selection)
            } else {
                selection = ToolApprovalChoice.grid.moved(from: selection, by: press.key)
            }
        }
    }

    private func button(_ choice: ToolApprovalChoice) -> some View {
        let always = choice == .denyAlways || choice == .allowAlways
        // Only the card that owns the keys shows a highlight: a filled
        // button on any other would promise a Return it does not get.
        return CardChoiceButton(highlighted: ownsKeys && selection == choice) {
            choose(choice)
        } label: {
            Self.title(of: choice)
                .font(.system(size: (always ? 12 : 13) * ratio,
                              weight: always ? .regular : (choice == .allow ? .semibold : .medium)))
                .frame(minWidth: 88)
        }
    }

    private static func title(of choice: ToolApprovalChoice) -> Text {
        switch choice {
        case .denyAlways:
            return Text("Deny Always",
                        comment: "Approval card button — remember deny for matching future calls")
        case .allowAlways:
            return Text("Allow Always",
                        comment: "Approval card button — remember allow for matching future calls")
        case .deny:
            return Text("Deny", comment: "Approval card deny button — one-shot")
        case .allow:
            return Text("Allow", comment: "Approval card allow button — one-shot")
        }
    }

    private func choose(_ choice: ToolApprovalChoice) {
        switch choice {
        case .allow:
            mcpBridge.resolve(requestId: request.id, verdict: .allow)
        case .deny:
            mcpBridge.resolve(requestId: request.id, verdict: .deny)
        case .denyAlways:
            mcpBridge.resolve(requestId: request.id, verdict: .denyAlways)
        case .allowAlways:
            let switchesToAcceptEdits = request.alwaysOffer.contains { $0.change == .acceptEdits }
            mcpBridge.resolve(requestId: request.id, verdict: .allowAlways)
            // Claude is in accept-edits from here on; the next turn is
            // launched from the chip, so the chip has to say so too.
            if switchesToAcceptEdits { onModeAdopted("acceptEdits") }
        }
    }

    /// What "Allow Always" will do for a call: one line per kind of
    /// change, in the order claude lists them, each rule named once.
    static func alwaysLines(for offer: [ClaudePermissionUpdate]) -> [String] {
        guard !offer.isEmpty else {
            return [String(localized: "Allow Always: don’t ask again for this exact call in this session",
                           comment: "Line on a permission card saying what the Allow Always button remembers when the agent suggests no rule for the call")]
        }
        var sessionRules: [String] = []
        var folderRules: [String] = []
        var directories: [String] = []
        var acceptsEdits = false
        for update in offer {
            switch update.change {
            case .rules(let rules):
                for rule in rules {
                    let name = "“" + ClaudePermissionSuggestions.displayName(of: rule) + "”"
                    if update.isSessionScoped {
                        if !sessionRules.contains(name) { sessionRules.append(name) }
                    } else if !folderRules.contains(name) {
                        folderRules.append(name)
                    }
                }
            case .directories(let paths):
                for path in paths.map(tildePath) where !directories.contains(path) {
                    directories.append(path)
                }
            case .acceptEdits:
                acceptsEdits = true
            }
        }
        var lines: [String] = []
        if !folderRules.isEmpty {
            let names = folderRules.joined(separator: ", ")
            lines.append(String(localized: "Allow Always: don’t ask again for \(names) in this folder",
                                comment: "Line on a permission card saying what the Allow Always button remembers: a rule saved to the working folder's settings; placeholder is the rule, e.g. a command pattern"))
        }
        if !sessionRules.isEmpty {
            let names = sessionRules.joined(separator: ", ")
            lines.append(String(localized: "Allow Always: don’t ask again for \(names) in this session",
                                comment: "Line on a permission card saying what the Allow Always button remembers: a rule kept for the session; placeholder is the rule, e.g. a command pattern"))
        }
        if !directories.isEmpty {
            let names = directories.joined(separator: ", ")
            lines.append(String(localized: "Allow Always: also allow access to \(names)",
                                comment: "Line on a permission card saying what the Allow Always button allows: working in one more folder; placeholder is the folder path"))
        }
        if acceptsEdits {
            lines.append(String(localized: "Allow Always: accept every edit in this session",
                                comment: "Line on a permission card saying what the Allow Always button does for an edit: the session switches to accepting edits without asking"))
        }
        return lines
    }

    private static func tildePath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - The plan card

/// The end of a planning turn, asked the way claude's own terminal asks
/// it: an approval that names the mode the session carries on in, or
/// "No, keep planning" — with a line for what to change, which claude
/// then revises the plan to inside the same turn.
///
/// That line belongs to "No, keep planning", as it does in the terminal:
/// the highlight arriving on that answer puts the cursor in the field,
/// and a click in the field moves the highlight to it.
///
/// The plan is drawn from the request itself: claude reads its plan file
/// back into the tool's input (`plan`, `planFilePath`). No "Always": a
/// plan is approved once.
struct PlanApprovalCard: View {
    let request: MCPApprovalRequest
    /// The agent under the user's own label (Settings → Labels).
    let agentName: String
    let ownsKeys: Bool
    let keys: ApprovalCardKeys
    /// The modes the installed claude lists, and the mode this turn was
    /// in before it planned — what `PlanApprovalOptions` builds the
    /// answers from.
    let listedModes: [String]
    let modeBeforePlan: String?
    /// An approval switched the session to a mode the chip follows.
    let onModeAdopted: (String) -> Void

    @EnvironmentObject private var mcpBridge: MCPBridge
    @Environment(\.sipFontScale) private var fontScale
    @State private var selection: PlanApprovalChoice.Kind
    /// What to change — seeded from the bridge, which keeps it while the
    /// request is pending, so a card rebuilt after a detour comes back
    /// as it was left.
    @State private var feedback: String
    @FocusState private var feedbackFocused: Bool

    init(request: MCPApprovalRequest, agentName: String, ownsKeys: Bool,
         keys: ApprovalCardKeys, listedModes: [String], modeBeforePlan: String?,
         savedNote: String?, onModeAdopted: @escaping (String) -> Void) {
        self.request = request
        self.agentName = agentName
        self.ownsKeys = ownsKeys
        self.keys = keys
        self.listedModes = listedModes
        self.modeBeforePlan = modeBeforePlan
        self.onModeAdopted = onModeAdopted
        let note = savedNote ?? ""
        _feedback = State(initialValue: note)
        let choices = PlanApprovalOptions.choices(listedModes: listedModes,
                                                  modeBeforePlan: modeBeforePlan)
        _selection = State(initialValue: note.isEmpty
            ? PlanApprovalOptions.initial(among: choices, modeBeforePlan: modeBeforePlan)
            : .keepPlanning)
    }

    private var ratio: CGFloat { SipFont.contentRatio(fontScale) }
    private var choices: [PlanApprovalChoice] {
        PlanApprovalOptions.choices(listedModes: listedModes, modeBeforePlan: modeBeforePlan)
    }

    var body: some View {
        let plan = ((request.toolInput["plan"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (request.toolInput["planFilePath"] as? String) ?? ""
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
            if !path.isEmpty {
                Text(String(localized: "Saved as \((path as NSString).abbreviatingWithTildeInPath)",
                            comment: "Plan card: the file the plan was saved to; placeholder is its path"))
                    .font(.system(size: 12 * ratio))
                    .foregroundColor(ChatDesign.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            TextField(String(localized: "Tell \(agentName) what to change",
                             comment: "Placeholder of the text field on a plan card where the user says what to change before choosing to keep planning; placeholder is the agent label"),
                      text: $feedback)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13 * ratio))
                .focused($feedbackFocused)
                // Return in the field is "No, keep planning" with what it
                // holds: the field is that answer's own.
                .onSubmit { choose(.keepPlanning) }
            // A row while it fits; a column of equal-width answers when
            // the tier or the window makes them wider than the card.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    buttons(filling: false)
                }
                VStack(alignment: .trailing, spacing: 6) {
                    buttons(filling: true)
                }
                // As wide as the widest answer, and no wider.
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .approvalCardFrame()
        // Written on every change, never on the way out: the view can be
        // torn down by a detour without a last callback.
        .onChange(of: feedback) { _, new in
            mcpBridge.setCardNote(new, for: request.id)
        }
        .onChange(of: feedbackFocused) { _, focused in
            if ownsKeys { keys.editingCardField = focused }
            if focused { selection = .keepPlanning }
        }
        .onReceive(keys.pressed) { press in
            guard press.card == request.id else { return }
            if press.key == .activate {
                choose(selection)
            } else {
                let next = CardChoiceGrid(rows: [choices.map(\.kind)])
                    .moved(from: selection, by: press.key)
                selection = next
                // In and out of the field with the highlight.
                feedbackFocused = next == .keepPlanning
            }
        }
    }

    private var feedbackIsBlank: Bool {
        feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func buttons(filling: Bool) -> some View {
        ForEach(choices) { choice in
            let highlighted = ownsKeys && selection == choice.kind
            if choice.kind == .keepPlanning {
                // Esc keeps planning — but not over words half typed,
                // which it would send as they stand.
                button(choice, highlighted: highlighted, filling: filling)
                    .keyboardShortcut(ownsKeys && feedbackIsBlank ? .cancelAction : nil)
            } else {
                button(choice, highlighted: highlighted, filling: filling)
            }
        }
    }

    private func button(_ choice: PlanApprovalChoice, highlighted: Bool, filling: Bool) -> some View {
        CardChoiceButton(highlighted: highlighted) {
            choose(choice.kind)
        } label: {
            Self.title(of: choice.kind)
                .font(.system(size: 13 * ratio, weight: .medium))
                .frame(minWidth: 88, maxWidth: filling ? .infinity : nil)
        }
    }

    /// Claude's own wording for each answer.
    private static func title(of kind: PlanApprovalChoice.Kind) -> Text {
        switch kind {
        case .keepPlanning:
            return Text("No, keep planning",
                        comment: "Plan card button: do not approve the plan; the agent keeps planning, revising the plan if the user typed what to change")
        case .manual:
            return Text("Yes, manually approve edits",
                        comment: "Plan card button: approve the plan; the agent asks before each edit")
        case .acceptEdits:
            return Text("Yes, auto-accept edits",
                        comment: "Plan card button: approve the plan; the agent's edits are accepted without asking")
        case .auto:
            return Text("Yes, and use auto mode",
                        comment: "Plan card button: approve the plan and carry on in the agent's auto mode, where routine actions run without asking")
        case .bypass:
            return Text("Yes, and bypass permissions",
                        comment: "Plan card button: approve the plan and carry on with every permission check bypassed, as the turn was before it planned")
        }
    }

    private func choose(_ kind: PlanApprovalChoice.Kind) {
        guard let choice = choices.first(where: { $0.kind == kind }),
              let mode = choice.setMode else {
            keepPlanning()
            return
        }
        mcpBridge.resolve(requestId: request.id, verdict: .allow, setMode: mode)
        // Claude carries on in that mode; the next turn is launched from
        // the chip, so the chip moves with it.
        if let chip = choice.chipMode { onModeAdopted(chip) }
    }

    private func keepPlanning() {
        mcpBridge.resolve(requestId: request.id, verdict: .deny,
                          message: PlanReplies.keepPlanning(feedback: feedback))
    }
}
