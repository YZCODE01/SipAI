// UpdateNotices.swift
// SipAI macOS — what is on offer to update, and the turns that wait
// while SipAI updates a tool.
//
// An update on offer — or a SipAI update waiting to install — puts a
// download badge beside "Settings" in the sidebar and beside "Updates"
// inside Settings, until the user has looked at that pane; the same
// items stand beside the sidebar's logo with an Update button until
// they are used or closed (`SidebarNotices`).
//
// The badge's rule is pure, so a harness drives it with no timer, no
// window and no network: it is keyed on (item, VERSION). Looking at
// Settings → Updates marks every item on offer as seen at its version,
// and only a version not yet seen raises the badge again — a newer
// release, or a tool whose automatic update did not land.

import Combine
import Foundation

// MARK: - The badge

/// One update on offer: SipAI itself, or one command-line tool.
struct UpdateBadgeItem: Equatable, Hashable {
    /// `app`, `app.install`, or `cli:<agent key>`.
    let key: String
    /// The version on offer. The badge is keyed on it, so a newer
    /// release is news even after the one before it was seen. SipAI's
    /// release is keyed on its build number, which is what Sparkle
    /// compares.
    let version: String
    /// What a person calls it: SipAI, or the tool's label.
    var name: String = ""
    /// The version as a person reads it — "1.0.6" where `version` is a
    /// build number.
    var shownVersion: String = ""
    /// The tool's update ran and the version did not move.
    var failed: Bool = false
    /// Why, where the tool said why in words SipAI knows; nil otherwise.
    var failure: CLIUpdateFailure? = nil

    static let appKey = "app"
    static let appInstallKey = "app.install"

    enum Kind: Equatable {
        /// SipAI's own release, found by Sparkle.
        case app
        /// SipAI's install, held for a running turn.
        case appInstall
        /// A command-line tool's release.
        case cli(agentKey: String)
    }

    var kind: Kind {
        switch key {
        case Self.appKey: return .app
        case Self.appInstallKey: return .appInstall
        default: return .cli(agentKey: key.hasPrefix("cli:") ? String(key.dropFirst(4)) : key)
        }
    }

    /// SipAI's release on offer: keyed on its build number, read as its
    /// version.
    static func app(version: String, display: String? = nil) -> UpdateBadgeItem {
        UpdateBadgeItem(key: appKey, version: version,
                        name: "SipAI", shownVersion: display ?? version)
    }

    /// SipAI's install, held for a running turn — its own key, so the
    /// badge comes back for it even where the release it installs was
    /// already seen: the way to install it at once (Install Now) is in
    /// the pane the badge points at, and on the bubble beside the logo.
    static func appInstall(version: String) -> UpdateBadgeItem {
        UpdateBadgeItem(key: appInstallKey, version: version,
                        name: "SipAI", shownVersion: version)
    }

    /// A tool's release on offer, under the label the user gave the tool.
    /// A known cause is a failure whatever `failed` says.
    static func cli(agentKey: String, version: String,
                    name: String = "", failed: Bool = false,
                    failure: CLIUpdateFailure? = nil) -> UpdateBadgeItem {
        UpdateBadgeItem(key: "cli:" + agentKey, version: version,
                        name: name.isEmpty ? agentKey : name,
                        shownVersion: version, failed: failed || failure != nil,
                        failure: failure)
    }
}

/// Why a tool's update did not land, where the tool's updater says so in
/// words SipAI knows. Read off what the updater printed, and keyed on the
/// tool: the same words from another tool name nothing.
enum CLIUpdateFailure: Equatable, Hashable {
    /// Claude Code stopped its own download. Its updater gives one download
    /// `claudeDownloadLimitMinutes` and then fails the update with
    /// `claudeDownloadTimedOutSentence`; SipAI's own limit for an update is
    /// longer, so it never comes into it, and a slow connection fails every
    /// Claude Code update the same way.
    case claudeDownloadTimedOut

    /// How long Claude Code's updater gives one download.
    static let claudeDownloadLimitMinutes = 10
    /// What it prints when that runs out. A stalled download (no data for
    /// two minutes) fails in other words, and is not this.
    static let claudeDownloadTimedOutSentence = "Download timed out: exceeded the total deadline"

    static func read(agentKey: String, output: String) -> CLIUpdateFailure? {
        if agentKey == "claude_code", output.contains(claudeDownloadTimedOutSentence) {
            return .claudeDownloadTimedOut
        }
        return nil
    }
}

enum UpdateBadgeRules {

    /// Whether any update on offer has not been seen at its version.
    static func isOwed(_ items: [UpdateBadgeItem], seen: [String: String]) -> Bool {
        items.contains { seen[$0.key] != $0.version }
    }

    /// What has been seen once Settings → Updates has shown `items`.
    ///
    /// Entries for items no longer on offer are kept. They cost one
    /// short string each, and nothing reads them unless the same item
    /// comes back — at which point a different version is news and the
    /// same one is not.
    static func seen(afterViewing items: [UpdateBadgeItem],
                     previously: [String: String]) -> [String: String] {
        var next = previously
        for item in items { next[item.key] = item.version }
        return next
    }
}

/// The badge's state: what is on offer, what has been seen, and the one
/// verdict the two views draw from.
///
/// Fed from two sides that know nothing of each other — Sparkle's
/// delegate (`UpdateController`) for SipAI itself, and the CLI monitor's
/// `publish()` for the tools — and cleared from exactly one place: the
/// Updates pane being on screen.
@MainActor
final class UpdateBadge: ObservableObject {

    static let shared = UpdateBadge()

    /// Seen versions, item key → version. Mac-only UI state, so
    /// UserDefaults rather than config.json — the CLI shares that file
    /// and has no use for this. Registered in
    /// `FactoryReset.userDefaultsKeys`.
    static let seenDefaultsKey = "updateBadgeSeen"

    /// Every update on offer right now, SipAI's own first.
    @Published private(set) var items: [UpdateBadgeItem] = []

    /// Whether the badge is drawn.
    @Published private(set) var isOwed = false

    private let defaults: UserDefaults
    private var appItems: [UpdateBadgeItem] = []
    private var cliItems: [UpdateBadgeItem] = []
    private var seen: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seen = defaults.dictionary(forKey: Self.seenDefaultsKey) as? [String: String] ?? [:]
    }

    /// SipAI's own: the release on offer, and an install held for a
    /// running turn. Empty when neither.
    func setAppItems(_ items: [UpdateBadgeItem]) {
        guard items != appItems else { return }
        appItems = items
        recompute()
    }

    /// The command-line tools' updates.
    func setCLIItems(_ items: [UpdateBadgeItem]) {
        guard items != cliItems else { return }
        cliItems = items
        recompute()
    }

    /// Settings → Updates is on screen: everything it lists has been
    /// seen at its version.
    func markSeen() {
        let next = UpdateBadgeRules.seen(afterViewing: items, previously: seen)
        guard next != seen else { return }
        seen = next
        defaults.set(seen, forKey: Self.seenDefaultsKey)
        recompute()
    }

    /// A factory reset removed the key; the copy in memory goes with it,
    /// or the badge would keep answering from the install just erased.
    func forgetSeen() {
        seen = [:]
        recompute()
    }

    private func recompute() {
        let all = appItems + cliItems
        if all != items { items = all }
        let owed = UpdateBadgeRules.isOwed(all, seen: seen)
        if owed != isOwed { isOwed = owed }
    }
}

// MARK: - Turns that wait for an update

/// Turns sent while their tool is being updated, per agent key. A turn
/// suspends in `wait` and is resumed by `release` when that update
/// ends; the monitor owns one of these and says when a tool is busy.
@MainActor
final class UpdateWaitList {
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Suspends until `release(key)` — or returns at once when `busy`
    /// is already false. The question and the registration happen in
    /// ONE MainActor step (the continuation's body runs synchronously),
    /// so a release landing between them cannot be missed.
    func wait(for key: String, while busy: () -> Bool) async {
        guard busy() else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting[key, default: []].append(continuation)
        }
    }

    /// Resume every turn waiting on this key. A no-op when none is.
    func release(_ key: String) {
        guard let turns = waiting.removeValue(forKey: key) else { return }
        for continuation in turns { continuation.resume() }
    }

    /// How many turns wait on this key — for the harness.
    func count(for key: String) -> Int { waiting[key]?.count ?? 0 }
}
