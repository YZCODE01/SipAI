// AgentQuestions.swift
// The rules behind a question an agent asks in the middle of a turn:
// what SipAI can draw, how an answer is spelled back to the agent, what
// the agent is told when nobody answers, and how the composer's turn
// clock leaves out the time a turn spends waiting on the user.
//
// Foundation only, and free of the bridge and the views, so the
// verification harnesses compile these rules on their own.
//
// Claude Code's `AskUserQuestion` reaches SipAI through the approver
// (`MCPBridge`) like any other tool call. The answer travels back in the
// permission-prompt result: an allow whose `updatedInput` is the tool's
// own input plus an `answers` map — claude's "answers collected by the
// permission component" — keyed by the exact question text. An allow
// WITHOUT that map reads to the agent as "The user did not answer the
// questions."

import Foundation

// MARK: - The form

/// One `AskUserQuestion` call, as far as SipAI can draw it: one to a few
/// questions, each a choice between labelled options.
///
/// `init?(toolInput:)` answers nil for anything the card cannot show
/// faithfully, and the bridge then declines the call with
/// `AgentQuestionReplies.unreadable` at once — a card that cannot be
/// drawn must never hold a turn open.
struct AgentQuestionForm: Equatable {

    struct Option: Equatable {
        let label: String
        let description: String
        /// Optional text the agent attaches to show what the option
        /// means (a mockup, a snippet). Drawn verbatim, never parsed.
        let preview: String?
    }

    struct Question: Equatable {
        /// Exactly as the agent wrote it: it is the KEY the answer is
        /// filed under, so it is never trimmed or rewritten.
        let text: String
        /// A short label for the question ("Auth method"); may be empty.
        let header: String
        let options: [Option]
        let multiSelect: Bool
        /// The agent's own id for the question, where its protocol files
        /// answers by id rather than by text (codex). nil for claude.
        var id: String? = nil
        /// Whether the user may answer in their own words. Claude always
        /// takes them; another agent's question may not.
        var allowsOther: Bool = true
        /// The agent marked the answer secret: typed into a field that
        /// does not show it, and never written anywhere but the reply.
        var isSecret: Bool = false
        /// The form cannot be sent without an answer here — a field an MCP
        /// server's form requires. Every other agent's question is
        /// optional: one answer anywhere sends the card.
        var required: Bool = false
        /// What the user's own words must be to count as an answer — an
        /// MCP server's number or text field. nil takes any words.
        var words: WordsRule? = nil
        /// How many options a multiple choice takes — an MCP server's
        /// `minItems` and `maxItems`. nil: any number.
        var minPicks: Int? = nil
        var maxPicks: Int? = nil

        /// Whether `count` picks are as many as the question takes.
        func picksFit(_ count: Int) -> Bool {
            count >= max(1, minPicks ?? 1) && count <= (maxPicks ?? Int.max)
        }

        /// What a multiple choice with bounds takes, said on the card; nil
        /// for one without, which says "Choose any that apply".
        var picksHint: String? {
            let low = (minPicks ?? 0) > 1 ? minPicks : nil
            switch (low, maxPicks) {
            case let (low?, high?):
                return String(localized: "Choose \(low) to \(high)",
                              comment: "Line under a multiple choice of an MCP server's form that takes between two numbers of options (placeholders)")
            case let (low?, nil):
                return String(localized: "Choose at least \(low)",
                              comment: "Line under a multiple choice of an MCP server's form that takes at least this many options (placeholder)")
            case let (nil, high?):
                return String(localized: "Choose at most \(high)",
                              comment: "Line under a multiple choice of an MCP server's form that takes at most this many options (placeholder)")
            case (nil, nil):
                return nil
            }
        }
    }

    let questions: [Question]

    /// Who asks, where it is not the agent: the MCP server whose form this
    /// is (`McpElicitation`). The card's title and its notification name
    /// it, its message stands above the questions, and the card can be
    /// sent once every field the form requires has an answer.
    private(set) var asker: String? = nil
    /// The asker's own words above the questions.
    private(set) var message: String = ""
    /// What the card starts with — an MCP server's default answers.
    private(set) var initialAnswers: [String: AgentQuestionAnswer] = [:]

    var isMcpForm: Bool { asker != nil }

    /// Whether the card offers Skip and "Chat about this". Both answer
    /// the agent in words of SipAI's own, which claude's protocol carries;
    /// another agent's may carry only a dismissal, or nothing.
    private(set) var offersSkip = true
    private(set) var offersChat = true

    /// Far past what claude asks for (it refuses more than four
    /// questions, or more than four options, itself). The bounds only
    /// keep an absurd input from producing an absurd card.
    static let maxQuestions = 8
    static let maxOptions = 12

    init?(toolInput: [String: Any]) {
        guard let raw = toolInput["questions"] as? [Any],
              !raw.isEmpty, raw.count <= Self.maxQuestions else { return nil }
        var questions: [Question] = []
        var texts = Set<String>()
        for item in raw {
            guard let q = item as? [String: Any],
                  let text = q["question"] as? String,
                  !Self.isBlank(text), texts.insert(text).inserted else { return nil }
            // Only choice questions. Open-ended and number questions are
            // a host option claude leaves off for SipAI's launch; one
            // arriving anyway is declined rather than half-drawn.
            if let kind = q["kind"] {
                guard (kind as? String) == "choice" else { return nil }
            }
            guard let rawOptions = q["options"] as? [Any],
                  rawOptions.count >= 2, rawOptions.count <= Self.maxOptions else { return nil }
            var options: [Option] = []
            var labels = Set<String>()
            for rawOption in rawOptions {
                guard let o = rawOption as? [String: Any],
                      let label = o["label"] as? String,
                      !Self.isBlank(label), labels.insert(label).inserted else { return nil }
                let preview = (o["preview"] as? String).flatMap { Self.isBlank($0) ? nil : $0 }
                options.append(Option(label: label,
                                      description: (o["description"] as? String) ?? "",
                                      preview: preview))
            }
            questions.append(Question(text: text,
                                      header: (q["header"] as? String) ?? "",
                                      options: options,
                                      multiSelect: (q["multiSelect"] as? Bool) ?? false))
        }
        self.questions = questions
    }

    /// A form an agent's own front end sent (codex's `request_user_input`,
    /// kimi's elicitation), already read into questions by its driver.
    /// The same bounds as claude's, and the same verdict for anything the
    /// card cannot draw: nil. A question may come with no options only
    /// when the user's own answer is allowed — it is then a free answer.
    init?(questions: [Question], offersSkip: Bool, offersChat: Bool) {
        guard !questions.isEmpty, questions.count <= Self.maxQuestions else { return nil }
        var texts = Set<String>()
        for question in questions {
            guard !Self.isBlank(question.text), texts.insert(question.text).inserted,
                  question.options.count <= Self.maxOptions,
                  !question.options.isEmpty || question.allowsOther else { return nil }
            var labels = Set<String>()
            for option in question.options {
                guard !Self.isBlank(option.label), labels.insert(option.label).inserted else {
                    return nil
                }
            }
        }
        self.questions = questions
        self.offersSkip = offersSkip
        self.offersChat = offersChat
    }

    /// An MCP server's form, read into one question per field
    /// (`McpElicitation.card`). The same bounds as any form; its Skip
    /// declines the form, and it has no "Chat about this" — nothing the
    /// user says reaches the model through a server's form.
    init?(mcpFields questions: [Question], asker: String, message: String,
          initialAnswers: [String: AgentQuestionAnswer]) {
        guard var form = AgentQuestionForm(questions: questions, offersSkip: true,
                                           offersChat: false) else { return nil }
        form.asker = asker
        form.message = message
        form.initialAnswers = initialAnswers
        self = form
    }

    private static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The input claude runs the tool with once the user has answered:
    /// the original input with every key kept, plus `answers`, plus the
    /// picked option's `preview` under `annotations` where it had one
    /// (claude then quotes it back to the model as "selected preview").
    /// Unanswered questions are simply absent, which claude reads as
    /// "left unanswered". Both maps are the user's alone: anything under
    /// those keys in the agent's own input is replaced, never merged.
    func updatedInput(original: [String: Any],
                      answers: [String: AgentQuestionAnswer]) -> [String: Any] {
        var out = original
        var map: [String: String] = [:]
        var annotations: [String: [String: String]] = [:]
        for question in questions {
            guard let answer = answers[question.text],
                  let value = answer.value(for: question) else { continue }
            map[question.text] = value
            if let preview = answer.pickedPreview(for: question) {
                annotations[question.text] = ["preview": preview]
            }
        }
        out["answers"] = map
        out.removeValue(forKey: "annotations")
        if !annotations.isEmpty { out["annotations"] = annotations }
        return out
    }

    /// Whether at least one question has an answer.
    func hasAnyAnswer(_ answers: [String: AgentQuestionAnswer]) -> Bool {
        questions.contains { answers[$0.text]?.value(for: $0) != nil }
    }

    /// What Submit needs: an MCP server's form once every field it
    /// requires has an answer and nothing typed breaks a field's rule;
    /// any other agent's questions once one of them has an answer.
    func canSubmit(_ answers: [String: AgentQuestionAnswer]) -> Bool {
        guard isMcpForm else { return hasAnyAnswer(answers) }
        for question in questions {
            let answer = answers[question.text]
            if answer?.isUnfit(for: question) == true { return false }
            if question.required, answer?.value(for: question) == nil { return false }
        }
        return true
    }
}

// MARK: - An answer

/// What the user has chosen for one question so far.
struct AgentQuestionAnswer: Equatable {
    /// Labels picked. Only labels the question offers ever count.
    var labels: [String] = []
    /// The "Other" field's text.
    var otherText: String = ""
    /// Whether the "Other" answer is picked: INSTEAD of a label on a
    /// single-select question, in addition to them on a multi-select one.
    var otherPicked: Bool = false

    /// The answer as claude takes it, or nil while the question is
    /// unanswered.
    ///
    /// A multi-select answer is ONE string, the picks joined with ", " in
    /// the order the options are listed: claude recognises that as picked
    /// labels, and it reads to the model as written. An array would work
    /// too, but reaches the model joined with a bare comma.
    func value(for question: AgentQuestionForm.Question) -> String? {
        let other = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
        let picked = question.options.map(\.label).filter { labels.contains($0) }
        if question.multiSelect {
            let items = picked + (otherPicked && !other.isEmpty ? [other] : [])
            guard !items.isEmpty, question.picksFit(items.count) else { return nil }
            return items.joined(separator: ", ")
        }
        if otherPicked {
            guard !other.isEmpty, question.words?.accepts(other) ?? true else { return nil }
            return other
        }
        return picked.first
    }

    /// Whether what stands in the answer breaks its question's rule: typed
    /// words that are not what the field takes, or more or fewer picks than
    /// it allows. Such an answer is no answer, and a form that holds one
    /// cannot be sent — sent anyway, the words would be dropped unsaid.
    func isUnfit(for question: AgentQuestionForm.Question) -> Bool {
        let other = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
        if otherPicked, !other.isEmpty, let rule = question.words, !rule.accepts(other) {
            return true
        }
        if question.multiSelect {
            let count = question.options.filter { labels.contains($0.label) }.count
                + (otherPicked && !other.isEmpty ? 1 : 0)
            return count > 0 && !question.picksFit(count)
        }
        return false
    }

    /// The preview of the one option picked on a single-select question.
    func pickedPreview(for question: AgentQuestionForm.Question) -> String? {
        guard !question.multiSelect, !otherPicked,
              let label = labels.first(where: { l in question.options.contains { $0.label == l } })
        else { return nil }
        return question.options.first { $0.label == label }?.preview
    }
}

/// A question card's state between renders — its answers and the page it
/// shows — kept by the bridge, per request, so a card the user leaves
/// half-answered comes back as they left it.
struct AgentQuestionDraft: Equatable {
    var answers: [String: AgentQuestionAnswer] = [:]
    var page: Int = 0
}

// MARK: - An answer the card did not send

extension AgentQuestionForm {
    /// What the user had put into this card and not sent, in the shape
    /// Codex's own terminal hands an unsent answer back to its message box
    /// when the turn that asked ends: each answered question quoted, a blank
    /// line, the answer; the questions a blank line apart, in the card's
    /// order. An answer is what the card would send — a chosen option, the
    /// user's own words — else words typed while nothing was chosen. Nil
    /// when nothing was put in.
    ///
    /// Only a card the turn does not wait on can be left like this: its
    /// question goes unanswered when the turn ends (`MCPBridge.withdraw`)
    /// or is stopped, and without this what the user had started is lost
    /// with the card.
    func unsentAnswersText(_ draft: AgentQuestionDraft) -> String? {
        var parts: [String] = []
        for question in questions {
            guard let answer = draft.answers[question.text] else { continue }
            let given = answer.value(for: question) ?? answer.otherText
            let text = given.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            parts.append(Self.quoted(question.text) + "\n\n" + text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// A question as Codex's terminal quotes it above an answer it hands
    /// back: its first 512 bytes, cut on a character boundary with "…"
    /// after the cut; a terminal's escape sequences and every control
    /// character but a line break and a tab left out; each line led by
    /// "> " — a blank one by ">" alone.
    static func quoted(_ question: String) -> String {
        var kept = String.UnicodeScalarView()
        var bytes = 0
        var cut = false
        for scalar in question.unicodeScalars {
            let size = String(scalar).utf8.count
            if bytes + size > 512 { cut = true; break }
            kept.append(scalar)
            bytes += size
        }
        let text = printable(String(kept))
        // The lines a line break ends, the last one with or without it: a
        // question that ends on a break has no empty line after it.
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        var quoted = lines.map { line in
            line.allSatisfy(\.isWhitespace) ? ">" + line : "> " + line
        }.joined(separator: "\n")
        if quoted.isEmpty { quoted = "> " }
        if cut { quoted += "…" }
        return quoted
    }

    /// `text` without what a terminal would act on: an escape sequence
    /// (ESC [ … through its final byte, or ESC alone) and every control
    /// character but a line break and a tab — a carriage return included,
    /// so a Windows line end reads as one break.
    private static func printable(_ text: String) -> String {
        let finalBytes: ClosedRange<Unicode.Scalar> = "@"..."~"
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            i += 1
            if scalar == "\u{1B}" {
                guard i < scalars.count, scalars[i] == "[" else { continue }
                i += 1
                while i < scalars.count, !finalBytes.contains(scalars[i]) { i += 1 }
                i += 1
                continue
            }
            if scalar.properties.generalCategory == .control, scalar != "\n", scalar != "\t" { continue }
            out.append(scalar)
        }
        return String(out)
    }
}

// MARK: - Typed answers

/// What the words typed into an MCP server's field must be: a number, or
/// text of a length or in a format. The server reads the answer as its
/// schema types it, so words that do not fit are no answer: the card says
/// what the field takes (`hint`) and is not sent while they stand.
enum WordsRule: Equatable {
    case number(integer: Bool, minimum: Double?, maximum: Double?)
    case text(minLength: Int?, maxLength: Int?, format: TextFormat?)

    /// The formats an MCP form's text may ask for.
    enum TextFormat: String {
        case email, uri, date
        case dateTime = "date-time"
    }

    /// Whether `words` (trimmed, not empty) are what the field takes.
    func accepts(_ words: String) -> Bool {
        switch self {
        case .number(let integer, let minimum, let maximum):
            guard let value = Self.number(words, integer: integer) else { return false }
            if let minimum, value < minimum { return false }
            if let maximum, value > maximum { return false }
            return true
        case .text(let minLength, let maxLength, let format):
            // JSON Schema counts a string's length in code points.
            let length = words.unicodeScalars.count
            if let minLength, length < minLength { return false }
            if let maxLength, length > maxLength { return false }
            return format.map { Self.fits(words, format: $0) } ?? true
        }
    }

    /// The words as the number they spell: digits, an optional sign, a
    /// fraction and an exponent where the field is not whole — never a
    /// hex float, an infinity or a NaN, which `Double(_:)` also reads.
    static func number(_ words: String, integer: Bool) -> Double? {
        let pattern = integer ? #"^[+-]?\d+$"# : #"^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$"#
        guard words.range(of: pattern, options: .regularExpression) != nil,
              let value = Double(words), value.isFinite else { return nil }
        // A whole number has to fit the integer it is sent as.
        if integer, Int(exactly: value) == nil { return nil }
        return value
    }

    private static func fits(_ words: String, format: TextFormat) -> Bool {
        switch format {
        case .email:
            return words.range(of: #"^[^\s@]+@[^\s@]+$"#, options: .regularExpression) != nil
        case .uri:
            guard !words.contains(where: \.isWhitespace),
                  let url = URL(string: words), let scheme = url.scheme else { return false }
            return !scheme.isEmpty
        case .date:
            guard words.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
            else { return false }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            return formatter.date(from: words) != nil
        case .dateTime:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if formatter.date(from: words) != nil { return true }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: words) != nil
        }
    }

    /// One line saying what the field takes, or nil with nothing to say: a
    /// text with no bounds and no format.
    var hint: String? {
        var parts: [String] = []
        switch self {
        case .number(let integer, let minimum, let maximum):
            parts.append(integer
                ? String(localized: "A whole number",
                         comment: "Line under a field of an MCP server's form that takes a whole number")
                : String(localized: "A number",
                         comment: "Line under a field of an MCP server's form that takes a number"))
            switch (minimum.map(Self.spelled), maximum.map(Self.spelled)) {
            case let (low?, high?):
                parts.append(String(localized: "From \(low) to \(high)",
                                    comment: "Line under a number field of an MCP server's form: the lowest and the highest number it takes (placeholders)"))
            case let (low?, nil):
                parts.append(String(localized: "At least \(low)",
                                    comment: "Line under a number field of an MCP server's form: the lowest number it takes (placeholder)"))
            case let (nil, high?):
                parts.append(String(localized: "At most \(high)",
                                    comment: "Line under a number field of an MCP server's form: the highest number it takes (placeholder)"))
            case (nil, nil):
                break
            }
        case .text(let minLength, let maxLength, let format):
            switch format {
            case .email?:
                parts.append(String(localized: "An email address",
                                    comment: "Line under a field of an MCP server's form that takes an email address"))
            case .uri?:
                parts.append(String(localized: "A web address",
                                    comment: "Line under a field of an MCP server's form that takes a web address (a URI)"))
            case .date?:
                parts.append(String(localized: "A date, as YYYY-MM-DD",
                                    comment: "Line under a field of an MCP server's form that takes a date; YYYY-MM-DD is the format to type"))
            case .dateTime?:
                parts.append(String(localized: "A date and time, as YYYY-MM-DDTHH:MM:SSZ",
                                    comment: "Line under a field of an MCP server's form that takes a date and time; the format to type follows"))
            case nil:
                break
            }
            // A required field is never empty, so a minimum of one says
            // nothing worth a line.
            let low = (minLength ?? 0) > 1 ? minLength : nil
            switch (low, maxLength) {
            case let (low?, high?):
                parts.append(String(localized: "\(low) to \(high) characters",
                                    comment: "Line under a text field of an MCP server's form: how long the answer may be (placeholders)"))
            case let (low?, nil):
                parts.append(String(localized: "At least \(low) characters",
                                    comment: "Line under a text field of an MCP server's form: the shortest answer it takes (placeholder)"))
            case let (nil, high?):
                parts.append(String(localized: "At most \(high) characters",
                                    comment: "Line under a text field of an MCP server's form: the longest answer it takes (placeholder)"))
            case (nil, nil):
                break
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A bound as the user types it: a whole number without a fraction,
    /// any other as Swift spells it.
    private static func spelled(_ value: Double) -> String {
        if let whole = Int(exactly: value) { return String(whole) }
        return String(value)
    }
}

// MARK: - The keyboard on a question card

/// One place the keyboard can be on a question card's page: an option,
/// the user's own answer, or one of the buttons under them.
enum AgentQuestionStop: Hashable {
    case option(Int)
    case other
    case skip, chat, previous, primary
}

enum AgentQuestionKeys {
    /// The stops of one page in the rows the arrow keys move through:
    /// each option on a row of its own, the user's own answer under
    /// them, and the buttons side by side on the last.
    static func grid(for form: AgentQuestionForm, page: Int) -> CardChoiceGrid<AgentQuestionStop> {
        guard form.questions.indices.contains(page) else {
            return CardChoiceGrid(rows: [[.skip, .chat, .primary]])
        }
        let question = form.questions[page]
        var rows = question.options.indices.map { [AgentQuestionStop.option($0)] }
        if question.allowsOther { rows.append([.other]) }
        var buttons: [AgentQuestionStop] = []
        if form.offersSkip { buttons.append(.skip) }
        if form.offersChat { buttons.append(.chat) }
        if page > 0 { buttons.append(.previous) }
        buttons.append(.primary)
        rows.append(buttons)
        return CardChoiceGrid(rows: rows)
    }

    /// Where the keyboard starts on a page: its first option while the
    /// question is open, the main button once it has its answer — so
    /// Return on an answered card sends it.
    static func entry(for form: AgentQuestionForm, page: Int,
                      answers: [String: AgentQuestionAnswer]) -> AgentQuestionStop {
        guard form.questions.indices.contains(page) else { return .primary }
        let question = form.questions[page]
        return answers[question.text]?.value(for: question) == nil
            ? firstStop(for: form, page: page) : .primary
    }

    /// A page's first stop: its first option, or the user's own answer
    /// on a question that offers no options.
    static func firstStop(for form: AgentQuestionForm, page: Int) -> AgentQuestionStop {
        guard form.questions.indices.contains(page),
              form.questions[page].options.isEmpty else { return .option(0) }
        return .other
    }

    /// The first question after `page` that has no answer yet, or nil
    /// when every later one has.
    static func nextOpen(after page: Int, in form: AgentQuestionForm,
                         answers: [String: AgentQuestionAnswer]) -> Int? {
        form.questions.indices.first { index in
            index > page
                && answers[form.questions[index].text]?.value(for: form.questions[index]) == nil
        }
    }

    /// Whether a horizontal arrow at this stop turns the page rather
    /// than moving along a row: on an option or the user's own answer,
    /// where a row holds one stop and left and right have nowhere to go.
    static func turnsPage(at stop: AgentQuestionStop) -> Bool {
        switch stop {
        case .option, .other: return true
        case .skip, .chat, .previous, .primary: return false
        }
    }
}

// MARK: - What the agent is told when nobody answers

/// The words a declined question hands back to the agent — its tool
/// result, read VERBATIM (a deny's message is the one channel the
/// permission-prompt protocol gives). English, and never catalog keys:
/// the model reads them, the user never does.
enum AgentQuestionReplies {
    /// Non-stop is on for this turn — the composer's switch, or a scheduled
    /// task's box. Wins over every other reason, so a turn running Non-stop
    /// is never told to wait for an answer or to ask in text.
    static let nonStop =
        "The user has turned on Non-stop, so SipAI does not show them questions "
        + "during this turn. Do not call AskUserQuestion again in this turn. "
        + "Choose what you judge best, say in one line which option you chose "
        + "and why, and continue with the task; the user can redirect you when "
        + "the turn ends."

    /// The user pressed Skip on the card.
    static let skipped =
        "The user skipped these questions without answering. Choose what you "
        + "judge best, say in one line which option you chose and why, and "
        + "continue with the task."

    /// The call could not be drawn (`AgentQuestionForm` answered nil).
    static let unreadable =
        "SipAI could not display these questions, so the user has not seen them. "
        + "Do not retry AskUserQuestion with this input. Ask in your reply text "
        + "instead; the user answers in the composer."

    /// No turn of this app owns the call — a claude left running by an
    /// earlier launch of SipAI, or a turn already being stopped.
    static let unanswerable =
        "No one can answer these questions in SipAI right now, so the user has "
        + "not seen them. Do not retry AskUserQuestion. Ask in your reply text "
        + "instead; the user answers in the composer."

    /// The words for a question declined without a card.
    static func words(for decline: CardDecline) -> String {
        switch decline {
        case .nonStop: return nonStop
        case .unreadable: return unreadable
        case .unanswerable: return unanswerable
        }
    }

    /// The user chose to talk the questions over rather than answer
    /// them. The agent is told what was asked and what had been answered
    /// so far, and to ask what they want to clarify — which ends its
    /// turn, so the user replies in the composer.
    static func chat(about form: AgentQuestionForm,
                     answers: [String: AgentQuestionAnswer]) -> String {
        var lines = [
            "The user wants to talk these questions over before answering them. "
            + "They may have more context to give, or questions of their own. "
            + "Do not retry AskUserQuestion yet: end your turn by asking what "
            + "they would like to clarify, take their reply into account, and "
            + "ask again afterwards if it still matters.",
            "",
            "Questions asked:",
        ]
        for question in form.questions {
            lines.append("- \"\(question.text)\"")
            if let value = answers[question.text]?.value(for: question) {
                lines.append("  Answer so far: \(value)")
            } else {
                lines.append("  (no answer yet)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - The turn clock's pause

/// Time a turn spends waiting on the user — a question to answer, a plan
/// to approve, a permission to give — left out of the composer's turn
/// clock, which counts the agent's working time. Kept beside the turn's
/// start instant rather than folded into it, because the start instant
/// also dates the turn elsewhere.
struct TurnPause: Equatable {
    /// Seconds of pauses that have ended.
    var total: TimeInterval = 0
    /// When the pause in progress began; nil while the clock runs.
    var since: Date? = nil

    var isPaused: Bool { since != nil }

    mutating func pause(at now: Date) {
        if since == nil { since = now }
    }

    mutating func resume(at now: Date) {
        guard let started = since else { return }
        total += max(0, now.timeIntervalSince(started))
        since = nil
    }

    /// The turn's working time at `now`: wall-clock since `startedAt`,
    /// less every pause — the one still in progress included, since a turn
    /// stopped while a card is up is stamped before the card is cleared.
    func activeElapsed(startedAt: Date, now: Date) -> TimeInterval {
        let open = since.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return max(0, now.timeIntervalSince(startedAt) - total - open)
    }
}
