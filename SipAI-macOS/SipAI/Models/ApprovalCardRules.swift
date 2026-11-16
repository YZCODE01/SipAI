// ApprovalCardRules.swift
// The rules behind the cards an agent's turn waits on — the permission
// card, the plan card and the question card: which keys reach a card and
// where the arrow keys move on it, what approving a plan offers, and
// what "Allow Always" remembers.
//
// Foundation only, and free of the bridge and the views, so the
// verification harnesses compile these rules on their own.

import Foundation

// MARK: - Keys

/// A key a waiting card answers to: the arrows move its highlighted
/// choice, Return takes it.
enum CardKey: Equatable {
    case up, down, left, right, activate
}

/// What has the keyboard when a key arrives while a card is waiting.
enum CardKeyResponder: Equatable {
    /// Nothing is being edited: the window itself, or text that can only
    /// be selected.
    case none
    /// The session's own message box, with nothing in it.
    case emptyComposer
    /// The session's message box with text in it, or an input method
    /// composing into it.
    case composing
    /// A text field inside the card that owns the keys — the plan card's
    /// "what to change", the question card's own answer.
    case cardField(isEmpty: Bool)
    /// Any other text being edited — a find field, a rename field.
    case otherText
}

/// Whether a key pressed while a card waits is the card's or the text's.
///
/// A card must never take a key out of text the user is typing: a Return
/// meant for a half-written message would otherwise approve a command.
/// So the keys are the card's only while nothing is being edited — or
/// while the session's own message box is EMPTY, where the arrows and
/// Return do nothing else.
enum CardKeyRouting {
    /// How long a card has to have been on screen before Return answers
    /// it. A key already on its way when the card appeared was aimed at
    /// something else, and must not approve what nobody has read.
    static let settle: TimeInterval = 0.3

    static func delivers(_ key: CardKey, to responder: CardKeyResponder,
                         cardAge: TimeInterval, isRepeat: Bool) -> Bool {
        switch responder {
        case .composing, .otherText:
            return false
        case .cardField(let isEmpty):
            // Return is the field's own: it submits the card. The
            // vertical arrows have nothing to do in a one-line field, so
            // they leave it; the horizontal ones move its caret — except
            // in an empty field, where there is no caret to move and the
            // card's highlight moves instead.
            switch key {
            case .activate: return false
            case .up, .down: return true
            case .left, .right: return isEmpty
            }
        case .none, .emptyComposer:
            // A held-down Return answers one card, not every card that
            // follows it.
            if key == .activate { return cardAge >= settle && !isRepeat }
            return true
        }
    }
}

/// The choices of a card as the arrow keys move through them: rows of
/// choices, in the order they are drawn.
struct CardChoiceGrid<Choice: Hashable> {
    let rows: [[Choice]]

    /// Where the highlight goes from `choice` on `key`. It stops at the
    /// edges rather than wrapping, so holding an arrow ends somewhere
    /// predictable.
    func moved(from choice: Choice, by key: CardKey) -> Choice {
        let rows = self.rows.filter { !$0.isEmpty }
        guard let r = rows.firstIndex(where: { $0.contains(choice) }),
              let c = rows[r].firstIndex(of: choice) else {
            return rows.last?.last ?? choice
        }
        // One row reads as a list whichever way it is laid out, so the
        // vertical arrows walk it too.
        if rows.count == 1 {
            switch key {
            case .left, .up: return rows[r][max(0, c - 1)]
            case .right, .down: return rows[r][min(rows[r].count - 1, c + 1)]
            case .activate: return choice
            }
        }
        switch key {
        case .left:
            return rows[r][max(0, c - 1)]
        case .right:
            return rows[r][min(rows[r].count - 1, c + 1)]
        case .up, .down:
            let target = key == .up ? r - 1 : r + 1
            guard rows.indices.contains(target) else { return choice }
            // Rows of one width keep the column. Into a row of another
            // width the highlight lands on its last choice — the rows are
            // drawn trailing, and the last is the one that carries on.
            if rows[target].count == rows[r].count { return rows[target][c] }
            return rows[target][rows[target].count - 1]
        case .activate:
            return choice
        }
    }
}

// MARK: - The permission card

/// The four answers of a permission card, in the two rows they are drawn
/// in. Allow is the one Return takes until an arrow moves the highlight.
enum ToolApprovalChoice: String, Hashable {
    case denyAlways, allowAlways, deny, allow

    static let grid = CardChoiceGrid<ToolApprovalChoice>(
        rows: [[.denyAlways, .allowAlways], [.deny, .allow]])
    static let initial = ToolApprovalChoice.allow
}

// MARK: - The plan card

/// One answer to a finished plan, in claude's own terms: an approval
/// names the mode the session carries on in, as claude's terminal asks
/// it ("Yes, and use auto mode", "Yes, auto-accept edits", "Yes, manually
/// approve edits"); the other answer is to keep planning.
struct PlanApprovalChoice: Equatable, Identifiable {
    enum Kind: String, Hashable {
        case keepPlanning, manual, acceptEdits, auto, bypass
    }

    let kind: Kind
    /// The mode claude is switched to as it leaves plan mode — a
    /// `setMode` riding the approval. nil for keep planning.
    let setMode: String?
    /// That mode as the composer's chip spells it, which the session's
    /// chip moves to. nil leaves the chip alone.
    let chipMode: String?

    var id: String { kind.rawValue }
}

enum PlanApprovalOptions {
    /// The answers a plan card offers, in the order they are drawn: keep
    /// planning first, then the approvals by growing autonomy.
    ///
    /// * `listedModes` — the modes the installed claude lists; a mode it
    ///   does not list is never offered.
    /// * `modeBeforePlan` — the mode the turn was in before it entered
    ///   plan mode; nil when it was launched on Plan. Bypass is offered
    ///   only from a turn that was already in it: claude refuses the
    ///   switch from any other.
    static func choices(listedModes: [String], modeBeforePlan: String?) -> [PlanApprovalChoice] {
        var out = [PlanApprovalChoice(kind: .keepPlanning, setMode: nil, chipMode: nil)]
        out.append(PlanApprovalChoice(kind: .manual, setMode: "default",
                                      chipMode: PlanApprovalModes.askBeforeEdits(in: listedModes)))
        if listedModes.contains("acceptEdits") {
            out.append(PlanApprovalChoice(kind: .acceptEdits, setMode: "acceptEdits",
                                          chipMode: "acceptEdits"))
        }
        if listedModes.contains("auto") {
            out.append(PlanApprovalChoice(kind: .auto, setMode: "auto", chipMode: "auto"))
        }
        if modeBeforePlan == "bypassPermissions" {
            out.append(PlanApprovalChoice(kind: .bypass, setMode: "bypassPermissions",
                                          chipMode: "bypassPermissions"))
        }
        return out
    }

    /// The answer Return takes until an arrow moves the highlight: back
    /// to the mode the turn planned out of when that is on offer, else
    /// accept-edits — the approval every claude offers — else manual.
    static func initial(among choices: [PlanApprovalChoice], modeBeforePlan: String?) -> PlanApprovalChoice.Kind {
        let kinds = Set(choices.map(\.kind))
        let returning: PlanApprovalChoice.Kind?
        switch modeBeforePlan {
        case "bypassPermissions": returning = .bypass
        case "auto": returning = .auto
        case "acceptEdits": returning = .acceptEdits
        case "default", "manual": returning = .manual
        default: returning = nil
        }
        if let returning, kinds.contains(returning) { return returning }
        if kinds.contains(.acceptEdits) { return .acceptEdits }
        return .manual
    }
}

/// The permission modes a plan approval names, in the spelling the
/// installed claude's `--help` lists — the chip's own vocabulary. Newer
/// builds list `manual` for the mode their transcripts record as
/// `default`; older builds list `default`.
enum PlanApprovalModes {
    /// Accept-edits as the chip spells it, or nil when the installed
    /// claude lists no such mode.
    static func acceptEdits(in modes: [String]) -> String? {
        modes.contains("acceptEdits") ? "acceptEdits" : nil
    }

    /// The ask-before-each-edit mode as the chip spells it. nil when
    /// neither spelling is listed, and the chip is then left alone.
    static func askBeforeEdits(in modes: [String]) -> String? {
        if modes.contains("manual") { return "manual" }
        if modes.contains("default") { return "default" }
        return nil
    }
}

/// The words a plan the user sends back hands to the agent — the tool's
/// result, read VERBATIM. English, and never catalog keys: the model
/// reads them, the user never does.
enum PlanReplies {
    /// Keep planning, nothing said: stop and wait for the next message.
    static let keepPlanning =
        "The user has not approved this plan and wants to keep planning. "
        + "End your turn now with a short reply — they will say what to "
        + "change in their next message. Stay in plan mode, and do not "
        + "call ExitPlanMode again until they ask for it."

    /// Keep planning, with what to change: revise inside this turn.
    static func keepPlanning(feedback: String) -> String {
        let said = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return keepPlanning }
        return "The user has not approved this plan and wants it changed. "
            + "They said:\n\n" + said + "\n\n"
            + "Stay in plan mode, revise the plan to take this into account, "
            + "and call ExitPlanMode again when the revised plan is ready."
    }
}

// MARK: - What "Allow Always" remembers

/// One change to claude's permissions that "Allow Always" makes: claude's
/// OWN suggestion for the call it is asking about — what its terminal
/// offers as "Yes, and don't ask again for …" — handed back unchanged, so
/// claude applies and matches it itself. Matching a remembered command in
/// SipAI instead would mean re-implementing claude's shell parsing, and a
/// looser copy of it is how `git status && rm -rf x` passes for
/// `git status`.
struct ClaudePermissionUpdate: Equatable {
    struct Rule: Equatable {
        let toolName: String
        /// nil covers every call of the tool.
        let ruleContent: String?
    }

    enum Change: Equatable {
        /// `addRules`, allow: calls matching these rules stop asking.
        case rules([Rule])
        /// `addDirectories`: the tools may work in these folders too.
        case directories([String])
        /// `setMode acceptEdits`: every edit is accepted from here on.
        case acceptEdits
    }

    let change: Change
    /// Where claude keeps it: `session` — the running process, gone with
    /// the turn — or the working folder's own settings
    /// (`localSettings`, `projectSettings`), which claude writes itself
    /// and reads back in every later session there.
    let destination: String

    var isSessionScoped: Bool { destination == "session" }

    /// Never `userSettings`: a grant that holds in every folder on the
    /// Mac is more than one click on a card should make, and claude does
    /// not suggest one.
    static let destinations: Set<String> = ["session", "localSettings", "projectSettings"]
    /// Far past what claude suggests for one call; the bounds only keep
    /// an absurd input from producing an absurd card.
    static let maxItems = 16
    static let maxLength = 4_000

    /// One of claude's permission updates, or nil for any shape SipAI
    /// does not pass on: a deny or an ask rule, a mode other than
    /// accept-edits, a destination it does not know.
    init?(wire: Any?) {
        guard let obj = wire as? [String: Any],
              let destination = obj["destination"] as? String,
              Self.destinations.contains(destination) else { return nil }
        func bounded(_ s: String) -> Bool { !s.isEmpty && s.count <= Self.maxLength }
        switch obj["type"] as? String {
        case "addRules":
            guard (obj["behavior"] as? String) == "allow",
                  let raw = obj["rules"] as? [Any],
                  !raw.isEmpty, raw.count <= Self.maxItems else { return nil }
            var rules: [Rule] = []
            for item in raw {
                guard let rule = item as? [String: Any],
                      let tool = rule["toolName"] as? String, bounded(tool) else { return nil }
                let content = rule["ruleContent"]
                if content == nil || content is NSNull {
                    rules.append(Rule(toolName: tool, ruleContent: nil))
                } else if let text = content as? String, bounded(text) {
                    rules.append(Rule(toolName: tool, ruleContent: text))
                } else {
                    return nil
                }
            }
            change = .rules(rules)
        case "addDirectories":
            guard let raw = obj["directories"] as? [Any],
                  !raw.isEmpty, raw.count <= Self.maxItems else { return nil }
            var directories: [String] = []
            for item in raw {
                guard let path = item as? String, bounded(path) else { return nil }
                directories.append(path)
            }
            change = .directories(directories)
        case "setMode":
            guard (obj["mode"] as? String) == "acceptEdits" else { return nil }
            change = .acceptEdits
        default:
            return nil
        }
        self.destination = destination
    }

    /// The update as claude takes it back in a permission result.
    var wire: [String: Any] {
        switch change {
        case .rules(let rules):
            return ["type": "addRules", "behavior": "allow", "destination": destination,
                    "rules": rules.map { rule -> [String: Any] in
                        var out: [String: Any] = ["toolName": rule.toolName]
                        if let content = rule.ruleContent { out["ruleContent"] = content }
                        return out
                    }]
        case .directories(let directories):
            return ["type": "addDirectories", "directories": directories,
                    "destination": destination]
        case .acceptEdits:
            return ["type": "setMode", "mode": "acceptEdits", "destination": destination]
        }
    }
}

enum ClaudePermissionSuggestions {
    /// The suggestions of one call as SipAI passes them on. Anything
    /// that is not a list yields none, and an entry of a shape SipAI does
    /// not pass on is left out — "Allow Always" then offers less, never
    /// something claude did not suggest.
    static func sanitized(_ raw: Any?) -> [ClaudePermissionUpdate] {
        guard let list = raw as? [Any], list.count <= ClaudePermissionUpdate.maxItems else { return [] }
        return list.compactMap { ClaudePermissionUpdate(wire: $0) }
    }

    /// A rule as claude's settings spell it: the tool alone, or
    /// `Tool(content)` with the content's backslashes and parentheses
    /// escaped — claude's own spelling, which its rule parser undoes.
    static func ruleString(_ rule: ClaudePermissionUpdate.Rule) -> String {
        guard let content = rule.ruleContent, !content.isEmpty else { return rule.toolName }
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
        return "\(rule.toolName)(\(escaped))"
    }

    /// What a card names a rule by: a shell command by its pattern, a
    /// fetch by its site, anything else by claude's own spelling of the
    /// rule.
    static func displayName(of rule: ClaudePermissionUpdate.Rule) -> String {
        guard let content = rule.ruleContent, !content.isEmpty else { return rule.toolName }
        switch rule.toolName {
        case "Bash":
            return content
        case "WebFetch" where content.hasPrefix("domain:"):
            return String(content.dropFirst("domain:".count))
        default:
            return ruleString(rule)
        }
    }

    /// The session-scoped grants of a session as a `permissions` block
    /// for claude's settings, or nil when there are none. Claude keeps a
    /// session-scoped update in the running process only, and every turn
    /// SipAI sends is a process of its own — so SipAI hands those grants
    /// to each later turn of the session, or "Always" would last one
    /// turn. What claude saved to a settings file it reads back itself.
    static func replaySettings(_ updates: [ClaudePermissionUpdate]) -> [String: Any]? {
        var allow: [String] = []
        var directories: [String] = []
        for update in updates where update.isSessionScoped {
            switch update.change {
            case .rules(let rules):
                for rule in rules {
                    let text = ruleString(rule)
                    if !allow.contains(text) { allow.append(text) }
                }
            case .directories(let paths):
                for path in paths where !directories.contains(path) { directories.append(path) }
            case .acceptEdits:
                // A mode is the chip's to carry: the next turn is launched in it.
                break
            }
        }
        var out: [String: Any] = [:]
        if !allow.isEmpty { out["allow"] = allow }
        if !directories.isEmpty { out["additionalDirectories"] = directories }
        return out.isEmpty ? nil : out
    }
}

// MARK: - One --settings argument

/// Claude takes ONE `--settings` value: given two, it reads the last and
/// drops the other without a word. So what the bridge adds is merged
/// into the value a launch already carries.
enum ClaudeSettingsArgv {
    /// `argv` with `extra` merged into its `--settings` JSON — or with a
    /// `--settings` pair appended when it carries none. `extra` empty
    /// returns `argv` untouched. A `--settings` value that is not a JSON
    /// object (a file path) is left alone and nothing is added: replacing
    /// it would drop what it says.
    static func merging(_ extra: [String: Any], into argv: [String]) -> [String] {
        guard !extra.isEmpty else { return argv }
        var out = argv
        if let flag = out.lastIndex(of: "--settings"), flag + 1 < out.count {
            guard let data = out[flag + 1].data(using: .utf8),
                  let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let merged = serialized(merge(extra, into: existing)) else { return argv }
            out[flag + 1] = merged
            return out
        }
        guard let value = serialized(extra) else { return argv }
        out.append(contentsOf: ["--settings", value])
        return out
    }

    /// Objects merge key by key and lists are joined; any other value of
    /// `extra` replaces the one it meets.
    private static func merge(_ extra: [String: Any], into base: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in extra {
            if let a = out[key] as? [String: Any], let b = value as? [String: Any] {
                out[key] = merge(b, into: a)
            } else if let a = out[key] as? [Any], let b = value as? [Any] {
                out[key] = a + b
            } else {
                out[key] = value
            }
        }
        return out
    }

    private static func serialized(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Cards an agent's own front end asks for

/// How a request an agent sends through its OWN interactive protocol —
/// codex's app-server, kimi's ACP — is drawn. Claude's approver needs
/// none of this: its cards are derived from the tool name and input.
///
/// Every word on such a card is the agent's own: codex's sentences as its
/// terminal writes them, kimi's option names as kimi sends them. The card
/// draws them; it never paraphrases them.
enum CardPresentation: Equatable {
    case permission(PermissionCardContent)
    case plan(PlanCardContent)
    case question
    case link(LinkCardContent)
}

/// A link an MCP server asks the user to open in the browser — to sign in
/// somewhere, or to finish a step there — before its tool goes on. The
/// answers are the card's own: "accept" once the user has opened it and
/// says they are done, "decline" to refuse.
struct LinkCardContent: Equatable {
    /// The MCP server that asks — named in the card's title.
    let asker: String
    /// The server's own words about the link.
    let message: String
    /// The link exactly as it would be opened.
    let url: String
    /// Whether SipAI opens it (`McpElicitation.opensSafely`). A link it
    /// will not open is still shown, so the user can see what was asked,
    /// and Decline is the only answer.
    let opens: Bool

    static let acceptId = "accept"
    static let declineId = "decline"
}

/// A permission card: what the agent asks, what it wants to do, and the
/// answers it offers.
struct PermissionCardContent: Equatable {
    /// The agent's own question ("Would you like to run the following
    /// command?"), or nil for the card's generic title.
    let prompt: String?
    let preview: CardPreview
    /// Lines under the preview — what an answer keeps, and for how long.
    var notes: [String] = []
    let choices: [CardChoice]
    /// The rows the answers are drawn in, top to bottom, by id — or nil for
    /// one row in the agent's order. A card that sets rows is laid out as
    /// Claude's permission card is (`ToolApprovalChoice.grid`).
    var rows: [[String]]? = nil
    /// The MCP server that asks this yes-or-no itself, or nil for an
    /// agent's own permission. A server's yes-or-no is a QUESTION, drawn on
    /// the permission card: Non-stop declines it, and its notification
    /// names the server.
    var asker: String? = nil
}

/// What a permission card shows of the call it asks about.
enum CardPreview: Equatable {
    case nothing
    case command(String, cwd: String?, reason: String?)
    case fileChanges([CardFileChange], reason: String?)
    case text(String)
}

struct CardFileChange: Equatable {
    let path: String
    /// "add", "delete" or "update", as the agent names it.
    let kind: String
    let diff: String
}

/// A finished plan the agent asks the user to review, with the answers
/// the agent offers for it.
struct PlanCardContent: Equatable {
    let plan: String
    let filePath: String?
    let choices: [CardChoice]
    /// The modes an approval can continue in, as Claude Code's own plan
    /// dialog offers them (`PlanContinue`): each one's id is the mode's
    /// spelling (`CardChoice.adoptsMode`), its label the mode's name.
    /// Empty: the approvals are drawn as the agent sends them.
    var continueModes: [CardChoice] = []
}

/// An approval that also names the mode the session continues in — the
/// plan answers on codex's and kimi's cards, which their own front ends do
/// not offer and Claude Code's plan dialog does ("Yes, and use auto mode").
/// The answer goes back to the agent as its own, and the mode is applied
/// right after it, so the rest of the turn already runs in it. Its id
/// carries both, joined by a character no agent's id contains.
enum PlanContinue {
    static let separator: Character = "\u{1F}"

    static func id(answer: String, mode: String) -> String {
        answer + String(separator) + mode
    }

    /// The agent's own answer, and the mode an id names (nil: none).
    static func split(_ id: String) -> (answer: String, mode: String?) {
        guard let at = id.firstIndex(of: separator) else { return (id, nil) }
        return (String(id[..<at]), String(id[id.index(after: at)...]))
    }

    /// The id of "Back", the second step's way back to the first.
    static let backId = String(separator) + "back"

    /// "Approve, then Ask When Needed": the agent's own word for the
    /// approval, then the mode.
    static func label(answer: String, mode: String) -> String {
        String(localized: "\(answer), then \(mode)",
               comment: "Plan card answer: approve the plan with the agent's own word for it (first placeholder), then continue in the mode named (second placeholder)")
    }

    /// One approval that names a mode. The plain acceptance Return starts
    /// on is the mode marked `.accept` — the one the turn was sent in —
    /// else the first; the rest weigh less.
    static func choices(approval: CardChoice, modes: [CardChoice]) -> [CardChoice] {
        let preferred = modes.firstIndex { $0.role == .accept } ?? 0
        return modes.enumerated().map { index, mode in
            CardChoice(id: id(answer: approval.id, mode: mode.id),
                       label: label(answer: approval.label, mode: mode.label),
                       role: index == preferred ? .accept : .other,
                       adoptsMode: mode.adoptsMode ?? mode.id)
        }
    }

    /// The answers a plan card draws first. With modes to continue in and
    /// ONE approval, the approval is drawn once per mode; with several
    /// approvals (alternative approaches the agent offers), each is drawn
    /// as the agent sends it and the mode is asked for next (`second`).
    static func first(_ content: PlanCardContent) -> [CardChoice] {
        let approvals = content.choices.filter { $0.role == .accept }
        guard !content.continueModes.isEmpty, approvals.count == 1,
              let approval = approvals.first else { return content.choices }
        return content.choices.flatMap { choice -> [CardChoice] in
            choice.id == approval.id
                ? choices(approval: choice, modes: content.continueModes) : [choice]
        }
    }

    /// Whether picking `choice` among `first` asks for the mode next.
    static func asksForMode(_ choice: CardChoice, in content: PlanCardContent) -> Bool {
        !content.continueModes.isEmpty && choice.role == .accept
            && PlanContinue.split(choice.id).mode == nil
    }

    /// The second step after an approval among several: the approval once
    /// per mode, and Back (what Esc takes).
    static func second(after approval: CardChoice, in content: PlanCardContent) -> [CardChoice] {
        choices(approval: approval, modes: content.continueModes)
            + [CardChoice(id: backId,
                          label: String(localized: "Back",
                                        comment: "Plan card answer: back from choosing the mode to choosing the approach"),
                          role: .decline)]
    }
}

/// One answer an agent offers on its own card.
struct CardChoice: Equatable, Hashable, Identifiable {
    /// The agent's own id for the answer — what goes back on the wire.
    let id: String
    /// The answer as the agent words it. Drawn verbatim.
    let label: String
    let role: CardChoiceRole
    /// The mode the session's chip moves to once this is chosen, for the
    /// session alone — an approved plan leaves plan mode. nil leaves the
    /// chip alone.
    var adoptsMode: String? = nil
}

/// What an answer amounts to, whatever the agent calls it: where the
/// keyboard starts, what Esc takes, how heavily it is drawn.
enum CardChoiceRole: Equatable, Hashable {
    case accept, acceptForSession, decline, declineForSession, other
}

enum CardChoiceLayout {
    /// The answers in the rows a card sets out, when those hold every answer
    /// exactly once; otherwise in one row, in the agent's order — an answer
    /// left out of the rows could be neither seen nor chosen.
    static func rows(_ choices: [CardChoice], arranged: [[String]]? = nil) -> [[CardChoice]] {
        guard let arranged else { return [choices] }
        let byId = Dictionary(choices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = arranged.map { $0.compactMap { byId[$0] } }.filter { !$0.isEmpty }
        let ids = rows.flatMap { $0.map(\.id) }
        guard ids.count == choices.count, Set(ids) == Set(choices.map(\.id)) else { return [choices] }
        return rows
    }

    /// The answers as the arrow keys move through them. `stacked`: the rows
    /// did not fit the card and are drawn as one column, in the order they
    /// read — which the keys then walk.
    static func grid(_ choices: [CardChoice], arranged: [[String]]? = nil,
                     stacked: Bool = false) -> CardChoiceGrid<String> {
        let drawn = rows(choices, arranged: arranged).map { $0.map(\.id) }
        return CardChoiceGrid(rows: stacked ? [drawn.flatMap { $0 }] : drawn)
    }

    /// Where Return starts until an arrow moves it: the first plain
    /// acceptance, as a permission card starts on Allow.
    static func initial(_ choices: [CardChoice]) -> String? {
        (choices.first { $0.role == .accept } ?? choices.first)?.id
    }

    /// What Esc takes: the first plain refusal. nil binds Esc to nothing.
    static func cancel(_ choices: [CardChoice]) -> String? {
        choices.first { $0.role == .decline }?.id
    }

    /// Far past what any agent offers; the bound only keeps an absurd
    /// request from producing an absurd card.
    static let maxChoices = 12

    /// Whether a card can be drawn with these answers: at least one, ids
    /// and labels non-blank, ids unique. A card that cannot be drawn is
    /// declined at once — it must never hold a turn open.
    static func isDrawable(_ choices: [CardChoice]) -> Bool {
        guard !choices.isEmpty, choices.count <= maxChoices else { return false }
        var ids = Set<String>()
        for choice in choices {
            let blank = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !blank(choice.id), !blank(choice.label), ids.insert(choice.id).inserted else {
                return false
            }
        }
        return true
    }
}

/// What became of a card an agent's own front end asked for — handed back
/// to that agent's driver, which spells it in its own protocol.
enum CardResolution: Equatable {
    /// The user picked one of the agent's own answers.
    case chose(String)
    /// The user answered the questions, keyed by question text.
    case answered([String: AgentQuestionAnswer])
    /// The user skipped the questions.
    case skipped
    /// Declined without a card (`CardDecline`).
    case declined(CardDecline)
    /// The turn ended under the card: Stop, the child gone, a quit.
    case cancelled
}

/// Why a request is declined without the user seeing a card.
enum CardDecline: Equatable {
    /// Non-stop is on for the turn: questions are not shown.
    case nonStop
    /// The card cannot be drawn.
    case unreadable
    /// No turn of this app can take an answer.
    case unanswerable
}
