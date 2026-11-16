import Foundation

/// A Kimi model Moonshot refused for the plan, read off the session's own
/// record, for the model menu to say so.
///
/// Kimi Code's plans include different models — Moonshot's own rule — and
/// a turn on one the plan lacks ends on Moonshot's 403 "Your current
/// subscription does not have access to <id>." Nothing kimi lists says
/// which models a plan has: its model list carries no plan field. So the
/// menu learns it from that answer, which kimi keeps verbatim in the
/// session's record — `turn.ended reason: failed` with `error.code`
/// `provider.auth_error` and `error.details.statusCode` 403 — beside the
/// turn's `llm.request` records, each naming the model and the alias it
/// ran under. The model's row stays pickable (a plan changes), and the
/// mark goes the next time that alias answers a turn.
enum KimiPlanRefusal {
    struct Verdict: Equatable {
        /// Aliases whose model Moonshot refused for the plan.
        var refused: Set<String> = []
        /// Aliases that answered a turn that ended normally.
        var answered: Set<String> = []
    }

    /// The model Moonshot's sentence names, or nil for any other words —
    /// the 256K context cap included: the plan has that model, up to a
    /// size, and the row must not say otherwise.
    nonisolated static func refusedModel(in message: String) -> String? {
        let prefix = "Your current subscription does not have access to "
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(prefix) else { return nil }
        var id = String(text.dropFirst(prefix.count))
        if id.hasSuffix(".") { id.removeLast() }
        guard !id.isEmpty, !id.contains(where: \.isWhitespace) else { return nil }
        return id
    }

    /// What the newest turn of a record's tail that ENDED says, when that
    /// turn began at or after `since` (kimi's `time`, ms since 1970): the
    /// aliases Moonshot refused for the plan, or the aliases that answered
    /// a turn that completed. nil when no such turn ended, or it ended
    /// some other way (stopped): it says nothing about the plan.
    nonisolated static func verdict(wireTail: String, since: Date?) -> Verdict? {
        let floor = since.map { $0.timeIntervalSince1970 * 1000 }
        var models: [String: String] = [:]
        var began: Double? = nil
        var latest: Verdict? = nil
        // Only lines naming one of the three records are parsed.
        let markers = ["\"turn.prompt\"", "\"llm.request\"", "\"turn.ended\""]
        for line in wireTail.split(separator: "\n") where markers.contains(where: { line.contains($0) }) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                continue
            }
            if KimiSessionScanner.turnPromptId(obj) != nil {
                models = [:]
                began = (obj["time"] as? NSNumber)?.doubleValue
            } else if (obj["type"] as? String) == "llm.request",
                      (obj["agentId"] as? String) == "main",
                      let alias = obj["modelAlias"] as? String, !alias.isEmpty,
                      let model = obj["model"] as? String {
                models[alias] = model
            } else if KimiSessionScanner.turnEnded(obj) {
                if let floor, (began ?? 0) < floor { continue }
                latest = endVerdict(obj, models: models)
            }
        }
        return latest
    }

    nonisolated private static func endVerdict(_ obj: [String: Any], models: [String: String]) -> Verdict? {
        if let reason = KimiSessionScanner.failedTurnReason(obj) {
            let error = obj["error"] as? [String: Any]
            let status = ((error?["details"] as? [String: Any])?["statusCode"] as? NSNumber)?.intValue
            guard (error?["code"] as? String) == "provider.auth_error", status == 403,
                  let id = refusedModel(in: reason) else { return Verdict() }
            return Verdict(refused: Set(models.filter { $0.value == id }.keys), answered: [])
        }
        guard (obj["reason"] as? String) == "completed" else { return nil }
        return Verdict(refused: [], answered: Set(models.keys))
    }
}

/// The marks, kept in UserDefaults for the one Kimi account they were
/// learned on — named by its kind ("plan", "apiKey"): another kind of
/// sign-in is another account, none of these is shown for it, and its own
/// first verdict replaces them. One small dictionary, read when the model
/// menu is built and written when a kimi turn ends.
enum KimiPlanRefusals {
    static let defaultsKey = "kimiPlanRefusedModels"

    nonisolated static func refused(account: String?, defaults: UserDefaults = .standard) -> Set<String> {
        guard let account, let stored = defaults.dictionary(forKey: defaultsKey),
              (stored["account"] as? String) == account else { return [] }
        return Set(stored["aliases"] as? [String] ?? [])
    }

    nonisolated static func apply(_ verdict: KimiPlanRefusal.Verdict, account: String?,
                                  defaults: UserDefaults = .standard) {
        guard let account else { return }
        var aliases = refused(account: account, defaults: defaults)
        aliases.subtract(verdict.answered)
        aliases.formUnion(verdict.refused)
        if aliases.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(["account": account, "aliases": aliases.sorted()], forKey: defaultsKey)
        }
    }

    /// The model menu's note under a model Moonshot refused for the plan.
    /// The row stays pickable: a plan changes, and the note goes when the
    /// model answers.
    nonisolated static func rowNote(forAlias alias: String, refused: Set<String>) -> String? {
        guard refused.contains(alias) else { return nil }
        return String(
            localized: "Your plan doesn't include this model",
            comment: "Model menu row subtitle: Moonshot refused this Kimi model for the plan")
    }

    /// Default's subtitle — the default model's name — saying so too when
    /// that model is one Moonshot refused: every message sent on Default
    /// runs it.
    nonisolated static func defaultSubtitle(name: String, alias: String, refused: Set<String>) -> String {
        guard refused.contains(alias) else { return name }
        return String(
            localized: "\(name) — your plan doesn't include it",
            comment: "Model menu: Default row subtitle; placeholder is the Kimi model")
    }
}
