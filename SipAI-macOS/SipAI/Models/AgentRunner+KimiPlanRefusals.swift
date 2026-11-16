import Foundation

extension AgentRunner {
    /// A kimi turn has ended: read how the session's own record says it
    /// ended (`KimiPlanRefusal`) and keep what that says about the plan's
    /// models, for the model menu. Only a turn that began with this one
    /// counts, so an earlier turn's answer is never taken for its own.
    /// The read is a bounded tail, off the main actor.
    func noteKimiPlanRefusals(turnBegan: Date?) {
        guard agentKey == "kimi", let wire = sessionFileURL,
              let account = UsageMonitor.shared.accounts["kimi"]?.kimiRefusalAccount else { return }
        Task.detached(priority: .utility) {
            guard let tail = AgentSessionScanner.boundedTail(of: wire, budget: 1024 * 1024),
                  let verdict = KimiPlanRefusal.verdict(wireTail: tail, since: turnBegan)
            else { return }
            KimiPlanRefusals.apply(verdict, account: account)
        }
    }
}

extension PlanAccountKind {
    /// The Kimi account a refused model is remembered for (`KimiPlanRefusals`):
    /// its kind. Signed out or unread, none.
    var kimiRefusalAccount: String? {
        switch self {
        case .plan: return "plan"
        case .apiKey: return "apiKey"
        case .signedOut, .unknown: return nil
        }
    }
}
