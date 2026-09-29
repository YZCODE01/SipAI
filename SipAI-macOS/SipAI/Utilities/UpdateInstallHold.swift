// UpdateInstallHold.swift
// SipAI macOS — what happens to an update whose install lands while an
// agent turn is running.
//
// Sparkle asks the updater delegate, ONCE per install, whether the
// relaunch may be postponed, and hands over the block that resumes it.
// Answering YES is silent on Sparkle's side: it returns before the
// first call that reaches its UI, and the "Install and Relaunch" button
// the user has just clicked has already had its handler cleared, so
// the window it sits in is inert from that click on. Everything that
// makes the postponement visible, endable and safe to quit through is
// therefore ours — and it is small enough to state as one rule.
//
// This is that rule: (state, event) → (next state, effect). The
// controller is its only driver and performs the effects; nothing here
// touches Sparkle, a window, a timer or a runner, which is what lets
// `Verification/SparkleUpdate/run.sh` compile it alone and ask it every
// question — the same way `UpdaterAvailability.verdict` is exercised.
//
// Three things it exists to make impossible:
//
//   * invoking Sparkle's block twice (a poll tick after the user chose
//     Interrupt, or a click on Install Now after the poll already won);
//   * invoking it on the way out of a quit, so an explicit ⌘Q during
//     the hold ends in Sparkle's own install-on-quit and NOT a relaunch;
//   * a failed install leaving the controller parked in `installing`
//     with the next update session unable to start a hold.

enum UpdateInstallHold {

    enum State: Equatable {
        case idle
        /// Sparkle has been answered YES and the choice sheet is up. The
        /// block is stored; no poll runs.
        case asking
        /// The user chose to wait. The poll runs until no turn is in
        /// flight, or a button ends the hold early.
        case holding
        /// The block has been invoked. Nothing may invoke it again.
        case installing
    }

    enum Event: Equatable {
        /// Sparkle's `shouldPostponeRelaunchForUpdate`, with the number
        /// of agent turns in flight at that moment.
        case installRequested(runningTurns: Int)
        /// The sheet's default button.
        case choseWait
        /// The sheet's other button.
        case choseInterrupt
        /// The poll saw no turn running.
        case quietMoment
        /// The Settings pane's "Install Now".
        case installNow
        /// `applicationShouldTerminate` — any quit, ours or Sparkle's.
        case quitRequested
        /// Sparkle's update cycle ended: a relaunch on the way, its own
        /// error alert acknowledged, or the session dismissed.
        case sessionEnded
    }

    enum Effect: Equatable {
        /// Answer Sparkle NO — nothing is running, install as asked.
        case proceed
        /// Answer Sparkle YES, keep the block, present the choice.
        case ask
        /// Show the wait, close Sparkle's inert window, start the poll.
        case beginHold
        /// Stop the poll and invoke the block, exactly once.
        case invokeInstall
        /// Stop the poll and drop the block without invoking it.
        case abandon
        case none
    }

    static func reduce(_ state: State, _ event: Event) -> (State, Effect) {
        switch event {
        case .installRequested(let runningTurns):
            // Sent at the start of an install and nowhere else, so it is
            // also the reset for whatever a previous session left behind.
            return runningTurns > 0 ? (.asking, .ask) : (.idle, .proceed)

        case .choseWait:
            return state == .asking ? (.holding, .beginHold) : (state, .none)

        case .choseInterrupt:
            return state == .asking ? (.installing, .invokeInstall) : (state, .none)

        case .quietMoment, .installNow:
            // From `holding` ONLY. A tick that outlives the hold, or one
            // that fires while the sheet is still up, does nothing.
            return state == .holding ? (.installing, .invokeInstall) : (state, .none)

        case .quitRequested:
            switch state {
            case .asking, .holding:
                return (.idle, .abandon)
            case .idle, .installing:
                // Sparkle's own quit request passes through the app's
                // delegate too, and must not undo the install it is
                // part of.
                return (state, .none)
            }

        case .sessionEnded:
            return (.idle, .abandon)
        }
    }
}
