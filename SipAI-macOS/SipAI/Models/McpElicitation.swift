// McpElicitation.swift
// An MCP server asking the user for input in the middle of one of its
// tool calls — MCP's `elicitation/create` — as the agents relay it:
//
//  * codex, in Default and Plan, as its app-server's
//    `mcpServer/elicitation/request`. The same request carries codex's own
//    question before it runs an MCP tool that may change something: a form
//    with no fields whose `_meta` names the approval
//    (`codex_approval_kind: "mcp_tool_call"`). `codex exec` declines a
//    server's forms and links itself;
//  * claude, through its Elicitation hook — SipAI's approver run with
//    `--elicitation` — whose answer claude hands the server. Under `-p`
//    with no hook, claude cancels every one;
//  * kimi's MCP client declares no elicitation, so no server asks it.
//
// Foundation only, and free of the bridge, the drivers and the views, so
// the harnesses compile it with the rules it leans on.
//
// What this file decides:
//
//  * the card a request becomes (`card(for:sessionNote:alwaysNote:)`): a
//    form → the question card, one page per field; a form with no fields →
//    the server's yes-or-no, drawn on the permission card but a QUESTION
//    (`PermissionCardContent.asker`), which Non-stop declines; codex's
//    approval of an MCP tool → a permission card in codex's words, with
//    the answers codex lists — "Always allow" among them, which codex
//    itself saves in its own settings — laid out as Claude's permission
//    card lays out its four; a link → the link card; anything
//    else → nil, declined unseen, as codex's own terminal declines what it
//    cannot draw;
//  * the answer each card's resolution is (`answer(for:to:)`): `action`
//    and, for an accepted form, `content` typed as the form's schema types
//    each field. A server reads its answer against that schema, so a
//    number goes back as a number and a choice as the value it listed,
//    never as the title on screen.

import Foundation

enum McpElicitation {

    // MARK: - The request

    /// One request, as an agent relays it.
    struct Request {
        var serverName: String
        var message: String
        /// "form" or "url"; any other mode is one this file does not draw.
        var mode: String
        var requestedSchema: [String: Any]?
        var url: String?
        /// Codex's own `_meta`: which of its approvals rides the request,
        /// and how long an approval may be kept (`persist`).
        var meta: [String: Any]?
        /// The order the server listed the form's fields in, where the
        /// relay kept it (claude's hook input, read by the approver). A
        /// parsed JSON object has no order of its own.
        var fieldOrder: [String]? = nil

        /// Codex's `mcpServer/elicitation/request`.
        init?(codexParams params: [String: Any]) {
            guard let server = params["serverName"] as? String,
                  let mode = params["mode"] as? String else { return nil }
            serverName = server
            message = params["message"] as? String ?? ""
            self.mode = mode
            requestedSchema = params["requestedSchema"] as? [String: Any]
            url = params["url"] as? String
            meta = params["_meta"] as? [String: Any]
        }

        /// Claude's Elicitation hook input. A missing mode is a form, as in
        /// MCP itself.
        init?(claudeHook input: [String: Any], fieldOrder: [String]? = nil) {
            guard let server = input["mcp_server_name"] as? String else { return nil }
            serverName = server
            message = input["message"] as? String ?? ""
            mode = input["mode"] as? String ?? "form"
            requestedSchema = input["requested_schema"] as? [String: Any]
            url = input["url"] as? String
            meta = nil
            self.fieldOrder = fieldOrder
        }
    }

    // MARK: - The card

    /// One field of a form, as its answer is typed back.
    struct Field: Equatable {
        enum Kind: Equatable {
            case text
            case number(integer: Bool)
            /// Yes or no: the question's first option is yes.
            case boolean
            /// One of these values, in the options' order.
            case choice([String])
            /// Any of these values, in the options' order.
            case choices([String])
        }
        let key: String
        let kind: Kind
    }

    /// What a request is drawn as.
    enum Card {
        /// Fields to fill in: the question card, one page per field.
        /// `fields[i]` is `form.questions[i]`.
        case form(AgentQuestionForm, fields: [Field])
        /// A yes-or-no. `toolApproval`: codex's own approval of an MCP tool,
        /// accepted with no content; otherwise a server's form with no
        /// fields, accepted with an empty one.
        case permission(PermissionCardContent, toolApproval: Bool)
        /// A link to open in the browser.
        case link(LinkCardContent)

        var presentation: CardPresentation {
            switch self {
            case .form: return .question
            case .permission(let content, _): return .permission(content)
            case .link(let content): return .link(content)
            }
        }

        var question: AgentQuestionForm? {
            if case .form(let form, _) = self { return form }
            return nil
        }
    }

    /// The answers on a permission card, by the ids codex's own terminal
    /// gives them.
    enum ChoiceId {
        static let accept = "accept"
        static let acceptForSession = "accept_session"
        static let acceptAlways = "accept_always"
        static let decline = "decline"
        static let cancel = "cancel"
    }

    /// Codex's `_meta` keys (its `mcp_approval_meta`).
    private enum Meta {
        static let approvalKind = "codex_approval_kind"
        static let toolCall = "mcp_tool_call"
        static let persist = "persist"
        static let persistSession = "session"
        static let persistAlways = "always"
        static let toolDescription = "tool_description"
        static let toolParams = "tool_params"
        static let toolParamsDisplay = "tool_params_display"
    }

    /// The card a request becomes, or nil to decline it unseen: a mode or a
    /// form this file does not draw (codex's own `openai/form`, a field of
    /// a type MCP does not define, more fields or options than a card
    /// holds), or one of codex's tool suggestions, which codex's own
    /// terminal answers by installing or switching on a ChatGPT app.
    ///
    /// `sessionNote` goes under a card that offers "Allow for this
    /// session" and `alwaysNote` under one that offers "Always allow": what
    /// each keeps, and for how long, which is the relay's to say — one line
    /// each, as Claude's card says what its "Allow Always" keeps.
    static func card(for request: Request, sessionNote: String? = nil,
                     alwaysNote: String? = nil) -> Card? {
        switch request.mode {
        case "url":
            guard let url = request.url, !url.isEmpty else { return nil }
            return .link(LinkCardContent(asker: request.serverName, message: request.message,
                                         url: url, opens: opensSafely(url)))
        case "form":
            let schema = request.requestedSchema ?? [:]
            let properties = schema["properties"] as? [String: Any] ?? [:]
            let kind = request.meta?[Meta.approvalKind] as? String
            if properties.isEmpty {
                if kind == Meta.toolCall {
                    return .permission(toolApprovalCard(request, sessionNote: sessionNote,
                                                        alwaysNote: alwaysNote),
                                       toolApproval: true)
                }
                // Codex's other approvals (a tool suggestion, a browser
                // sign-in) are its apps'; a server's own form with no fields
                // is a plain yes-or-no.
                guard kind == nil else { return nil }
                return .permission(confirmCard(request), toolApproval: false)
            }
            // A form with fields is the server's own, or codex's approval
            // of a tool that asks for more than yes or no; codex's other
            // approvals are its apps'.
            guard kind == nil || kind == Meta.toolCall,
                  let read = form(properties: properties,
                                  required: schema["required"] as? [String] ?? [],
                                  order: request.fieldOrder,
                                  asker: request.serverName, message: request.message)
            else { return nil }
            return .form(read.form, fields: read.fields)
        default:
            return nil
        }
    }

    /// Codex's question before it runs an MCP tool, in its words: its own
    /// sentence, what the call passes, and its answers. The two that keep
    /// the approval are offered where codex lists them (`_meta.persist`):
    /// "Allow for this session", which codex keeps in the running process,
    /// and "Always allow", which codex writes into the settings that set the
    /// server up (`approval_mode = "approve"`), so the tool stops asking
    /// wherever codex runs.
    ///
    /// The answers are laid out as Claude's permission card lays out its
    /// four: the ones that keep the approval on the top row, Cancel and
    /// Allow below them, and Allow — where Return starts — at the bottom
    /// right, with "Always allow" straight above it where Claude's card has
    /// "Allow Always".
    private static func toolApprovalCard(_ request: Request, sessionNote: String?,
                                         alwaysNote: String?) -> PermissionCardContent {
        let allow = CardChoice(id: ChoiceId.accept, label: Words.allow, role: .accept)
        let cancel = CardChoice(id: ChoiceId.cancel, label: Words.cancel, role: .decline)
        var keeps: [CardChoice] = []
        var notes: [String] = []
        if offers(Meta.persistSession, in: request.meta) {
            keeps.append(CardChoice(id: ChoiceId.acceptForSession, label: Words.allowForSession,
                                    role: .acceptForSession))
            if let sessionNote { notes.append(sessionNote) }
        }
        if offers(Meta.persistAlways, in: request.meta) {
            keeps.append(CardChoice(id: ChoiceId.acceptAlways, label: Words.alwaysAllow,
                                    role: .acceptForSession))
            if let alwaysNote { notes.append(alwaysNote) }
        }
        let params = paramsText(request.meta)
        let description = (request.meta?[Meta.toolDescription] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preview: CardPreview = !params.isEmpty ? .text(params)
            : (description.isEmpty ? .nothing : .text(description))
        return PermissionCardContent(
            prompt: request.message.isEmpty ? nil : request.message, preview: preview,
            notes: notes, choices: [allow] + keeps + [cancel],
            rows: [keeps.map(\.id), [cancel.id, allow.id]].filter { !$0.isEmpty })
    }

    /// A server's form with no fields: a yes-or-no in the server's own
    /// words, under a title naming it — the server's question, which
    /// Non-stop declines (`asker`). Nothing on it is kept: a kept answer is
    /// codex's, for its own approvals, and a server's question has none
    /// whatever its own `_meta` says.
    private static func confirmCard(_ request: Request) -> PermissionCardContent {
        let choices = [
            CardChoice(id: ChoiceId.accept, label: Words.allow, role: .accept),
            CardChoice(id: ChoiceId.decline, label: Words.deny, role: .decline),
            CardChoice(id: ChoiceId.cancel, label: Words.cancel, role: .other),
        ]
        let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return PermissionCardContent(
            prompt: Words.requestsInput(request.serverName),
            preview: message.isEmpty ? .nothing : .text(request.message),
            choices: choices, asker: request.serverName)
    }

    /// Whether codex lists `mode` among the ways the approval may be kept
    /// (`_meta.persist`: a list, or one name).
    private static func offers(_ mode: String, in meta: [String: Any]?) -> Bool {
        if let list = meta?[Meta.persist] as? [Any] {
            return list.contains { ($0 as? String) == mode }
        }
        return (meta?[Meta.persist] as? String) == mode
    }

    /// What an MCP tool call passes, one line per argument: codex's own
    /// display list where it sends one, else the arguments by name.
    private static func paramsText(_ meta: [String: Any]?) -> String {
        if let shown = meta?[Meta.toolParamsDisplay] as? [Any], !shown.isEmpty {
            return shown.compactMap { raw -> String? in
                guard let entry = raw as? [String: Any] else { return nil }
                let name = (entry["display_name"] as? String) ?? (entry["name"] as? String) ?? ""
                guard !name.isEmpty else { return nil }
                return name + ": " + spelled(entry["value"])
            }.joined(separator: "\n")
        }
        guard let params = meta?[Meta.toolParams] as? [String: Any] else { return "" }
        return params.keys.sorted().map { $0 + ": " + spelled(params[$0]) }.joined(separator: "\n")
    }

    /// A value as a line shows it: text as it is, anything else as compact
    /// JSON.
    private static func spelled(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let value, JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value],
                                                     options: [.sortedKeys, .withoutEscapingSlashes])
        else { return value.map { "\($0)" } ?? "" }
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    // MARK: - A form

    /// A form's fields read into the question card's pages, or nil when a
    /// field is of a type MCP does not define or the card cannot hold the
    /// form. The order: the relay's, where it kept one; else the required
    /// fields as the form lists them, then the rest by name.
    static func form(properties: [String: Any], required: [String], order: [String]?,
                     asker: String, message: String)
    -> (form: AgentQuestionForm, fields: [Field])? {
        let requiredSet = Set(required)
        let keys: [String] = {
            let known = Set(properties.keys)
            if let order, Set(order) == known, order.count == known.count { return order }
            let first = required.filter { known.contains($0) }
            var seen = Set<String>()
            let firstUnique = first.filter { seen.insert($0).inserted }
            return firstUnique + properties.keys.filter { !requiredSet.contains($0) }.sorted()
        }()
        var questions: [AgentQuestionForm.Question] = []
        var fields: [Field] = []
        var initial: [String: AgentQuestionAnswer] = [:]
        var texts = Set<String>()
        for key in keys {
            guard let property = properties[key] as? [String: Any],
                  let read = field(key: key, property: property, required: requiredSet.contains(key),
                                   several: keys.count > 1)
            else { return nil }
            var question = read.question
            // Answers are filed by a question's words, so two fields asked
            // in the same words are told apart by their names.
            if !texts.insert(question.text).inserted {
                question = rewritten(question, text: question.text + " (" + key + ")")
                guard texts.insert(question.text).inserted else { return nil }
            }
            if let answer = read.initial { initial[question.text] = answer }
            questions.append(question)
            fields.append(read.field)
        }
        guard let form = AgentQuestionForm(mcpFields: questions, asker: asker, message: message,
                                           initialAnswers: initial)
        else { return nil }
        return (form, fields)
    }

    private static func rewritten(_ q: AgentQuestionForm.Question, text: String) -> AgentQuestionForm.Question {
        var out = AgentQuestionForm.Question(text: text, header: q.header, options: q.options,
                                             multiSelect: q.multiSelect, id: q.id,
                                             allowsOther: q.allowsOther, isSecret: q.isSecret)
        out.required = q.required
        out.words = q.words
        out.minPicks = q.minPicks
        out.maxPicks = q.maxPicks
        return out
    }

    /// One field: its page on the card, how its answer is typed, and the
    /// answer it starts with (the schema's `default`).
    private static func field(key: String, property: [String: Any], required: Bool, several: Bool)
    -> (question: AgentQuestionForm.Question, field: Field, initial: AgentQuestionAnswer?)? {
        let title = nonBlank(property["title"] as? String) ?? key
        let description = nonBlank(property["description"] as? String)
        // The page asks the description where there is one, under the
        // title; a field with none asks its title.
        let text = description ?? title
        let header = (description != nil || several) ? title : ""
        let type = property["type"] as? String
        func question(options: [AgentQuestionForm.Option], multi: Bool, other: Bool)
        -> AgentQuestionForm.Question {
            var q = AgentQuestionForm.Question(text: text, header: header, options: options,
                                               multiSelect: multi, id: key, allowsOther: other)
            q.required = required
            return q
        }
        func options(_ titled: [(value: String, title: String)]) -> [AgentQuestionForm.Option] {
            titled.map { AgentQuestionForm.Option(label: $0.title, description: "", preview: nil) }
        }

        switch type {
        case "string":
            if let titled = constOptions(property["oneOf"]) ?? enumOptions(property) {
                let q = question(options: options(titled), multi: false, other: false)
                let picked = (property["default"] as? String)
                    .flatMap { d in titled.first { $0.value == d }?.title }
                return (q, Field(key: key, kind: .choice(titled.map(\.value))),
                        picked.map { AgentQuestionAnswer(labels: [$0]) })
            }
            var q = question(options: [], multi: false, other: true)
            let format = (property["format"] as? String).flatMap(WordsRule.TextFormat.init(rawValue:))
            let minLength = (property["minLength"] as? NSNumber)?.intValue
            let maxLength = (property["maxLength"] as? NSNumber)?.intValue
            if format != nil || minLength != nil || maxLength != nil {
                q.words = .text(minLength: minLength, maxLength: maxLength, format: format)
            }
            let initial = nonBlank(property["default"] as? String)
                .map { AgentQuestionAnswer(otherText: $0, otherPicked: true) }
            return (q, Field(key: key, kind: .text), initial)
        case "number", "integer":
            let integer = type == "integer"
            var q = question(options: [], multi: false, other: true)
            q.words = .number(integer: integer,
                              minimum: (property["minimum"] as? NSNumber)?.doubleValue,
                              maximum: (property["maximum"] as? NSNumber)?.doubleValue)
            let initial = (property["default"] as? NSNumber).map { number -> AgentQuestionAnswer in
                let value = number.doubleValue
                let words = Int(exactly: value).map(String.init) ?? String(value)
                return AgentQuestionAnswer(otherText: words, otherPicked: true)
            }
            return (q, Field(key: key, kind: .number(integer: integer)), initial)
        case "boolean":
            let q = question(options: [AgentQuestionForm.Option(label: Words.yes, description: "", preview: nil),
                                       AgentQuestionForm.Option(label: Words.no, description: "", preview: nil)],
                             multi: false, other: false)
            let initial = (property["default"] as? Bool)
                .map { AgentQuestionAnswer(labels: [$0 ? Words.yes : Words.no]) }
            return (q, Field(key: key, kind: .boolean), initial)
        case "array":
            let items = property["items"] as? [String: Any] ?? [:]
            guard let titled = constOptions(items["anyOf"]) ?? enumOptions(items) else { return nil }
            var q = question(options: options(titled), multi: true, other: false)
            q.minPicks = (property["minItems"] as? NSNumber)?.intValue
            q.maxPicks = (property["maxItems"] as? NSNumber)?.intValue
            let picked = (property["default"] as? [Any] ?? []).compactMap { raw -> String? in
                guard let value = raw as? String else { return nil }
                return titled.first { $0.value == value }?.title
            }
            return (q, Field(key: key, kind: .choices(titled.map(\.value))),
                    picked.isEmpty ? nil : AgentQuestionAnswer(labels: picked))
        default:
            return nil
        }
    }

    /// `[{const, title}]` — a titled choice. nil when absent or malformed.
    private static func constOptions(_ raw: Any?) -> [(value: String, title: String)]? {
        guard let list = raw as? [Any], !list.isEmpty else { return nil }
        var out: [(value: String, title: String)] = []
        for entry in list {
            guard let option = entry as? [String: Any], let value = option["const"] as? String
            else { return nil }
            out.append((value, nonBlank(option["title"] as? String) ?? value))
        }
        return out
    }

    /// `enum` (with the older `enumNames` as its titles) — an untitled or
    /// a legacy titled choice.
    private static func enumOptions(_ schema: [String: Any]) -> [(value: String, title: String)]? {
        guard let values = schema["enum"] as? [Any], !values.isEmpty else { return nil }
        let names = schema["enumNames"] as? [Any] ?? []
        var out: [(value: String, title: String)] = []
        for (index, raw) in values.enumerated() {
            guard let value = raw as? String else { return nil }
            let name = index < names.count ? nonBlank(names[index] as? String) : nil
            out.append((value, name ?? value))
        }
        return out
    }

    // MARK: - A link

    /// Whether SipAI opens a link a server asks to have opened: an https
    /// link with a host and no user name or password in it, every
    /// character of it plain printable ASCII — so what the card shows is
    /// exactly what the browser is handed — and no longer than a browser
    /// is safely handed. Codex's own terminal opens https links alone.
    static func opensSafely(_ url: String) -> Bool {
        guard url.utf8.count <= 2048,
              url.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }),
              let parts = URLComponents(string: url),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil
        else { return false }
        return true
    }

    // MARK: - The answer

    /// What goes back to the server.
    struct Answer {
        /// "accept", "decline" or "cancel".
        let action: String
        /// An accepted form's fields, typed; nil for every other answer.
        let content: [String: Any]?
        /// How long an accepted approval holds, in codex's terms: "session"
        /// (codex keeps it in the running process) or "always" (codex
        /// writes it into its settings).
        let persist: String?

        static let decline = Answer(action: "decline", content: nil, persist: nil)
        static let cancel = Answer(action: "cancel", content: nil, persist: nil)
    }

    /// The answer a card's resolution is. Stop, a quit and the turn ending
    /// under the card are `cancel`; Decline, Non-stop and a card nobody can
    /// answer are `decline`; an answered form whose answers do not fit it
    /// — which the card does not let the user send — is declined rather
    /// than sent half-typed.
    static func answer(for resolution: CardResolution, to card: Card) -> Answer {
        switch resolution {
        case .cancelled:
            return .cancel
        case .skipped, .declined:
            return .decline
        case .chose(let id):
            switch (card, id) {
            case (.link, LinkCardContent.acceptId):
                return Answer(action: "accept", content: nil, persist: nil)
            case (.permission(_, let toolApproval), ChoiceId.accept):
                return Answer(action: "accept", content: toolApproval ? nil : [:], persist: nil)
            case (.permission(_, let toolApproval), ChoiceId.acceptForSession):
                return Answer(action: "accept", content: toolApproval ? nil : [:],
                              persist: Meta.persistSession)
            case (.permission(_, let toolApproval), ChoiceId.acceptAlways):
                return Answer(action: "accept", content: toolApproval ? nil : [:],
                              persist: Meta.persistAlways)
            case (_, ChoiceId.decline):
                return .decline
            default:
                return .cancel
            }
        case .answered(let answers):
            guard case .form(let form, let fields) = card,
                  let content = content(form: form, fields: fields, answers: answers)
            else { return .decline }
            return Answer(action: "accept", content: content, persist: nil)
        }
    }

    /// An answered form's fields as the server's schema types them: text as
    /// typed, a number as a number, yes or no as a boolean, a choice as the
    /// value the server listed. nil when a required field has no answer or
    /// an answer breaks its field's rule.
    static func content(form: AgentQuestionForm, fields: [Field],
                        answers: [String: AgentQuestionAnswer]) -> [String: Any]? {
        guard form.canSubmit(answers), fields.count == form.questions.count else { return nil }
        var content: [String: Any] = [:]
        for (question, field) in zip(form.questions, fields) {
            guard let answer = answers[question.text],
                  let value = answer.value(for: question) else { continue }
            let picked = question.options.enumerated()
                .filter { answer.labels.contains($0.element.label) }.map(\.offset)
            switch field.kind {
            case .text:
                content[field.key] = value
            case .number(let integer):
                guard let number = WordsRule.number(value, integer: integer) else { return nil }
                if integer {
                    guard let whole = Int(exactly: number) else { return nil }
                    content[field.key] = whole
                } else {
                    content[field.key] = number
                }
            case .boolean:
                guard let index = picked.first else { return nil }
                content[field.key] = index == 0
            case .choice(let values):
                guard let index = picked.first, index < values.count else { return nil }
                content[field.key] = values[index]
            case .choices(let values):
                content[field.key] = picked.filter { $0 < values.count }.map { values[$0] }
            }
        }
        return content
    }

    // MARK: - Words

    /// The card's words. Codex's terminal's for its approvals; the form's
    /// title and the link card's answers are Claude Code's own ("MCP server
    /// “…” requests your input", "Open in browser", "I’m done, continue"),
    /// and the link's title follows the form's shape.
    enum Words {
        static var allow: String {
            String(localized: "Allow", comment: "Approval card allow button — one-shot")
        }
        static var allowForSession: String {
            String(localized: "Allow for this session",
                   comment: "Answer on the card for an MCP server's request: allow it, and the same again until the session's process ends — codex's own words")
        }
        static var alwaysAllow: String {
            String(localized: "Always allow",
                   comment: "Answer on Codex's card before it runs an MCP tool: allow it, and Codex saves the approval in its own settings so the tool never asks again — codex's own words")
        }
        static var deny: String {
            String(localized: "Deny", comment: "Approval card deny button — one-shot")
        }
        static var cancel: String {
            String(localized: "Cancel", comment: "Cancel button")
        }
        static var yes: String {
            String(localized: "Yes", comment: "Option of a yes-or-no field on an MCP server's form")
        }
        static var no: String {
            String(localized: "No", comment: "Option of a yes-or-no field on an MCP server's form")
        }
        static func requestsInput(_ server: String) -> String {
            String(localized: "MCP server “\(server)” requests your input",
                   comment: "Title of the card for an MCP server's form, and of its notification; placeholder is the server's name")
        }
        static func wantsLink(_ server: String) -> String {
            String(localized: "MCP server “\(server)” wants to open a link",
                   comment: "Title of the card for a link an MCP server asks the user to open, and of its notification; placeholder is the server's name")
        }
    }

    private static func nonBlank(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
