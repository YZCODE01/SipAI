// AgentRPCTurn.swift
// A turn an agent runs through its OWN interactive protocol — codex's
// app-server, kimi's ACP server — rather than through its one-shot
// headless command. These are the front ends through which an agent can
// ASK the user something mid-turn: a permission, a plan to review, a
// question. The asking modes run their turns this way, and so does
// Default wherever the installed CLI has the front end — a scheduled run
// in such a mode included; the modes that never ask and Chat only keep the
// headless command.
//
// The work is split in two, and the line between them is the point:
//
//  * the DRIVER (`AgentRPCTurn`, one per agent) speaks the protocol — the
//    handshake, the session, the message, the agent's requests and
//    notifications — and turns what it hears into transcript events and
//    cards;
//  * the RUNNER (`AgentRPCHost`) owns the child: spawning it, draining
//    its output, Stop, and the end of the turn. A turn still ends when
//    the CHILD dies, exactly as a headless turn does.

import Foundation

/// The driver's half of a turn over JSON-RPC.
@MainActor
protocol AgentRPCTurn: AnyObject {
    /// The child's arguments after its binary.
    var arguments: [String] { get }

    /// Variables laid over the child's environment, last — after the
    /// environment every agent child gets.
    var environment: [String: String] { get }

    /// Whether the child's stdout is a terminal. A JSON line through a
    /// terminal comes back with a carriage return (and, first time, a
    /// few control bytes), which the peer strips; a pipe is used where
    /// the agent was measured to write its lines unbuffered.
    var stdoutIsTerminal: Bool { get }

    /// Speak the turn, from the handshake to the turn's end. Return once
    /// the protocol is done with the turn: the runner then closes the
    /// child's stdin, and a child that reads until EOF exits. Never kills
    /// anything — that is the runner's.
    func run(peer: JSONRPCLinePeer, host: AgentRPCHost) async

    /// Stop was pressed: tell the agent in its own protocol, and say how
    /// long it may take to wind down before the child is killed. Cards
    /// have already been answered as cancelled by then.
    func interrupt(peer: JSONRPCLinePeer) -> TimeInterval

    /// How long the child may take to exit once the protocol is done with
    /// the turn and its stdin has closed, before it is stopped. Read at
    /// that moment: an agent that has cleaning up of its own to do first —
    /// work it started in the background — says so here, since a child
    /// stopped mid-way leaves that work running with nobody to end it.
    var exitGrace: TimeInterval { get }

    /// A message the user sent while the turn runs, handed to it in the
    /// agent's own protocol: nil once the agent took it, else the agent's
    /// words for why not ("" when it gave none, or cannot take one).
    func steer(text: String, peer: JSONRPCLinePeer) async -> String?

    /// Stop one piece of background work the turn waits on, by the id it
    /// was listed under (`BackgroundTaskEntry.id`). False when it could
    /// not be asked.
    func stopBackgroundTask(id: String, peer: JSONRPCLinePeer) async -> Bool
}

enum AgentRPCTurnDefaults {
    /// A child with nothing to clean up exits in tens of milliseconds.
    static let exitGrace: TimeInterval = 3
}

/// How a turn over JSON-RPC ends once its child is gone — one rule for
/// every driver.
enum AgentRPCTurnEnd {
    enum Outcome: Equatable {
        /// It ended well, or the user stopped it (Stop has its own row).
        case ended
        /// The driver ended it on a failure it has already put on the
        /// transcript (`AgentRPCHost.noteTurnFailed`): the turn ends as
        /// failed, in those words — what a scheduled run records — and no
        /// second row is drawn.
        case failedAsSaid(String)
        /// The child went before its protocol was done with the turn: a
        /// turn cut short whatever the exit code — a server that leaves
        /// quietly mid-conversation finished nothing either — said in the
        /// child's own words where it left any.
        case cutShort(String)
    }

    /// - Parameters:
    ///   - protocolDone: the driver returned while its conversation was
    ///     still open, so the protocol was done with the turn.
    ///   - driverFailure: what the driver last reported the turn failed on.
    ///   - childReport: the child's own words on its way out, else its exit
    ///     code — asked for only when the child cut the turn short.
    static func outcome(protocolDone: Bool, stopped: Bool, driverFailure: String?,
                        childReport: () -> String) -> Outcome {
        if stopped { return .ended }
        if protocolDone { return driverFailure.map(Outcome.failedAsSaid) ?? .ended }
        return .cutShort(childReport())
    }
}

extension AgentRPCTurn {
    var exitGrace: TimeInterval { AgentRPCTurnDefaults.exitGrace }
    /// A front end that takes no message mid-turn (kimi's ACP refuses a
    /// second prompt while one runs): the message waits for the turn's end.
    func steer(text: String, peer: JSONRPCLinePeer) async -> String? { "" }
    func stopBackgroundTask(id: String, peer: JSONRPCLinePeer) async -> Bool { false }
}

/// What a driver may do to its runner — only while its turn is the
/// runner's own: once a turn is superseded or stopped, nothing it emits
/// reaches the transcript and every card it asks for is answered
/// cancelled at once.
@MainActor
protocol AgentRPCHost: AnyObject {
    var cwd: URL { get }
    /// The session the turn resumes, or nil for a new one.
    var sessionId: String? { get }
    /// Whether the driver's turn is still the runner's, and not stopped.
    var turnIsLive: Bool { get }

    /// A new session's id, the moment the agent names it.
    func adoptSession(id: String)

    /// Events for the transcript — the path a parsed stdout line takes,
    /// so the chips, the clock and the context chip treat them alike.
    func emit(_ events: [StreamEvent])

    /// The state of the connection, in the agent's own words
    /// ("Reconnecting… 2/5"); nil clears it. Never a transcript row.
    func setNotice(_ text: String?)

    /// The context chip's numbers, from the agent's own usage report.
    func noteContextUsage(tokens: Int, window: Int?)

    /// Put a card in front of the user. Its `respond` is called exactly
    /// once — with the user's answer, or with a decline or a cancel when
    /// nobody can answer. Returns the bridge's id for the card, through
    /// which the driver withdraws it when the agent resolves it itself.
    @discardableResult
    func present(_ card: AgentCardRequest) -> String?

    /// The agent resolved a card itself; it goes without an answer.
    func withdraw(cardId: String)

    /// The turn ended on a plan the agent proposes and has no way to ask
    /// about itself (codex's Plan mode): offer the user to carry it out.
    func offerPlanFollowUp(_ plan: String)

    /// A skill the turn's message was drawn as loading was not loaded
    /// after all — the agent did not know it, or could not be told where
    /// it is (`names` nil: every skill the message names). Its row stops
    /// naming it, so the conversation is not taken to hold it.
    func retractSkillLoads(_ names: [String]?)

    /// The turn failed, and the driver has said why on the transcript, in
    /// `message`. Without this the turn ends as a success once its
    /// protocol is done — the agents' own front ends answer a failed turn
    /// as an ordinary end — and a scheduled run is recorded "done" under
    /// an error row (`AgentRPCTurnEnd`).
    func noteTurnFailed(_ message: String)

    /// The background work the turn is waiting on now that its answer has
    /// landed — the transcript's line naming it; empty when it waits on
    /// none. State, never a row.
    func setAwaitedBackgroundTasks(_ tasks: [BackgroundTaskEntry])

    /// Whether the turn takes a message steered into it right now — while
    /// the agent works on it, and not while it waits on background work or
    /// runs a review or a compaction. State, never a row.
    func setSteerable(_ on: Bool)

    /// The agent took a message steered into the turn (`text`, as it was
    /// sent): the moment its row belongs in the transcript.
    func steerTaken(text: String)

    /// The agent is summarising the conversation, as asked (`/compact`).
    /// The same state a compaction the agent starts by itself shows.
    func setCompacting(_ on: Bool)

    /// What the agent said, opening the session, about the faster speed the
    /// turn asks for (`asked`): `served` false when it runs the turn without
    /// it. State, never a row — the model chip's bolt says it.
    func noteSpeed(asked: String, served: Bool)
}

extension AgentRPCHost {
    func offerPlanFollowUp(_ plan: String) {}
    func retractSkillLoads(_ names: [String]?) {}
    func noteTurnFailed(_ message: String) {}
    func setAwaitedBackgroundTasks(_ tasks: [BackgroundTaskEntry]) {}
    func setSteerable(_ on: Bool) {}
    func steerTaken(text: String) {}
    func setCompacting(_ on: Bool) {}
    func noteSpeed(asked: String, served: Bool) {}
}

/// A card a driver asks its runner to show.
struct AgentCardRequest {
    /// What the card's badge names — the agent's own tool name.
    var toolName: String
    var toolInput: [String: Any] = [:]
    var presentation: CardPresentation
    /// A question's form; nil with a `.question` presentation means the
    /// agent's form could not be read, and it is declined unread.
    var question: AgentQuestionForm? = nil
    /// Whether the turn waits on the card. False for a question the agent
    /// asked without stopping: it works on while the card is up, and an
    /// answer reaches it only while its turn runs.
    var turnWaits: Bool = true
    var respond: @MainActor (CardResolution) -> Void
}
