import Foundation

/// An answer the user had started on a card the agent's turn did not wait
/// on — codex's question asked without stopping — handed back when the
/// card went (`AgentQuestionForm.unsentAnswersText`), for the session's
/// message box.
enum UnsentAnswers {
    /// The box with the answer back in it: after what is typed there, a
    /// blank line between, as Codex's own terminal appends a recovered
    /// answer. A box that holds a command (`!…`, `/name`) gets the answer
    /// first instead: appended, it would be sent as part of the command —
    /// Codex escapes the command to keep the message a message, and SipAI
    /// has no escape for one.
    static func boxText(_ answers: String, over typing: String) -> String {
        if typing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return answers }
        if ShellCommandInput.command(in: typing) != nil
            || AgentSlashCommands.leadingCommand(in: typing) != nil {
            return answers + "\n\n" + typing
        }
        return typing + "\n\n" + answers
    }
}
