// UpdaterAvailability.swift
// SipAI macOS — may THIS copy of SipAI offer itself an update?
//
// SipAI is open source. Anyone can clone the repo and ⌘R, and the copy
// they get is theirs — built from their checkout, possibly with their
// own changes in it. Offering that copy a download signed by us would
// be offering to overwrite their work with ours. Worse, it wouldn't
// even succeed: Sparkle refuses to install an update whose signing
// identity disagrees with the running app's, so the whole exchange
// ends in an error dialog that reads like a bug.
//
// The distinguishing fact is the TEAM IDENTIFIER, and it is exactly
// the fact `CLAUDE.md` already documents from the other direction:
// a self-signed certificate carries no team (`TeamIdentifier=not set`),
// which is why hardened runtime + library validation rejects the debug
// dylib. Only a certificate issued by Apple to an enrolled developer
// carries one. So:
//
//   * A distribution build, signed Developer ID  → has a team → updates.
//   * A build signed to run locally, which is what a fresh clone gets
//     → ad hoc, no team → does not update.
//   * A build signed with a self-signed certificate → no team either
//     → does not update.
//
// That needs no build setting to be remembered, no version constant to
// drift, and no `#if DEBUG` (which a Release build from a fork would
// walk straight past).
//
// A contributor with an Apple developer account of their OWN would pass
// this check on a Release build. Sparkle's own signature comparison
// catches that one, and it is rare enough not to be worth a second
// mechanism here.
//
// The verdict is a pure function of (team identifier, override) so it
// can be exercised headlessly, the same way
// `ScheduledTaskScheduler.decide` and `TranscriptFollow` are — see
// `Verification/SparkleUpdate/run.sh`.

import Foundation
import Security

enum UpdaterAvailability {

    /// Set to `1` to run the updater in a build that could not
    /// otherwise have one. ONLY for the verification harness, which has
    /// to drive a real update between two locally-signed builds long
    /// before a Developer ID certificate is in the picture.
    ///
    /// Ignored on a distribution-signed build (see `verdict`), so the
    /// most it can do is let a locally-built copy ask an appcast for an
    /// update — and every answer to that question still has to carry a
    /// valid EdDSA signature before Sparkle will act on it.
    static let forceEnableEnvironmentVariable = "SIPAI_UPDATER_FORCE_ENABLED"

    /// Appcast URL for the harness to point the updater at. Read only
    /// when the verdict is `.forcedForTesting` — see
    /// `UpdateController.feedURLString(for:)`.
    static let feedOverrideEnvironmentVariable = "SIPAI_UPDATER_FEED_URL"

    enum Verdict: Equatable {
        /// Signed by an enrolled developer — the ordinary shipped case.
        case enabled
        /// Enabled by the environment override; harness only.
        case forcedForTesting
        /// Built locally or by someone else. No updater, no UI beyond a
        /// sentence explaining why.
        case notDistributionSigned

        var allowsUpdates: Bool { self != .notDistributionSigned }
    }

    // MARK: - The rule

    /// Pure, so the harness can ask it every question without a bundle,
    /// a keychain or a network.
    static func verdict(teamIdentifier: String?, forceEnabled: Bool) -> Verdict {
        // The override applies ONLY to builds that could not otherwise
        // update themselves — the harness's whole job is to exercise
        // the path a locally-signed build cannot reach. On a
        // distribution-signed build it is ignored outright: an
        // environment variable must never be able to re-point a
        // shipped copy's updater at someone else's feed, even one it
        // would refuse every download from (a hostile feed can still
        // suppress real updates and choose the release notes shown).
        if forceEnabled, (teamIdentifier ?? "").isEmpty {
            return .forcedForTesting
        }
        // An empty string is what an ad-hoc signature reports where an
        // unsigned binary reports nothing at all. Neither is a team.
        guard let team = teamIdentifier, !team.isEmpty else {
            return .notDistributionSigned
        }
        return .enabled
    }

    // MARK: - The live reading

    /// Cached: the answer cannot change while the process runs, and the
    /// Settings pane asks on every redraw.
    private static let liveVerdict: Verdict = {
        let forced = ProcessInfo.processInfo
            .environment[forceEnableEnvironmentVariable] == "1"
        return verdict(teamIdentifier: runningTeamIdentifier(),
                       forceEnabled: forced)
    }()

    static var current: Verdict { liveVerdict }

    /// The team identifier on the RUNNING process's signature, or nil
    /// when there isn't one.
    ///
    /// Read off the running code rather than off `Bundle.main`'s path:
    /// the question is what this process was allowed to be, not what
    /// happens to be sitting at that path now.
    static func runningTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }

        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
