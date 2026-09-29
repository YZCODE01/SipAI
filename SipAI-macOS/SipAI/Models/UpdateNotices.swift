// UpdateNotices.swift
// SipAI macOS — how an available update is shown, and how an update
// that happened by itself is told.
//
// Neither is a banner. An update on offer — or a SipAI update waiting
// to install — puts a download badge beside "Settings" in the sidebar
// and beside "Updates" inside Settings, until the user has looked at
// that pane. An update that has HAPPENED says so for a few seconds in
// place of the sidebar's wordmark: a command-line tool updated by any
// route SipAI can see, and SipAI itself after the relaunch that
// installed it (and, while an install waits for a running turn, that
// it will).
//
// Both rules are pure, so a harness drives them with no timer, no
// window and no network:
//
//   * The BADGE is keyed on (item, VERSION). Looking at Settings →
//     Updates marks every item on offer as seen at its version, and
//     only a version not yet seen raises the badge again — a newer
//     release, or a tool whose automatic update did not land.
//   * The ANNOUNCEMENTS are a queue. One line shows for a fixed time;
//     a line that arrives meanwhile waits, and takes over the moment
//     that time is up. The wordmark does not come back in between.

import AppKit
import Combine
import Foundation

// MARK: - The badge

/// One update on offer: SipAI itself, or one command-line tool.
struct UpdateBadgeItem: Equatable, Hashable {
    /// `app`, or `cli:<agent key>`.
    let key: String
    /// The version on offer. The badge is keyed on it, so a newer
    /// release is news even after the one before it was seen.
    let version: String

    static func app(version: String) -> UpdateBadgeItem {
        UpdateBadgeItem(key: "app", version: version)
    }

    /// SipAI's install, held for a running turn — its own key, so the
    /// badge comes back for it even where the release it installs was
    /// already seen: the way to install it at once (Install Now) is in
    /// the pane the badge points at.
    static func appInstall(version: String) -> UpdateBadgeItem {
        UpdateBadgeItem(key: "app.install", version: version)
    }

    static func cli(agentKey: String, version: String) -> UpdateBadgeItem {
        UpdateBadgeItem(key: "cli:" + agentKey, version: version)
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

// MARK: - The announcements

/// One line for the sidebar's header.
struct UpdateAnnouncement: Identifiable, Equatable {
    let id = UUID()
    /// Final and localized: the caller composes it with the agent's
    /// label, the way every sentence naming an agent is composed.
    let text: String
}

/// The queue behind the header, as a value: what shows, since when, and
/// what waits.
struct UpdateAnnouncementQueue: Equatable {
    private(set) var current: UpdateAnnouncement?
    private(set) var shownAt: Date?
    private(set) var waiting: [UpdateAnnouncement] = []

    /// Shows at once when nothing is showing; otherwise waits its turn.
    mutating func enqueue(_ item: UpdateAnnouncement, now: Date) {
        if current == nil {
            current = item
            shownAt = now
        } else {
            waiting.append(item)
        }
    }

    /// When the line on screen has had its time. nil when none shows.
    func endsAt(duration: TimeInterval) -> Date? {
        shownAt.map { $0.addingTimeInterval(duration) }
    }

    /// Whether this sentence is on screen or waiting.
    func holds(text: String) -> Bool {
        current?.text == text || waiting.contains { $0.text == text }
    }

    /// Once the line on screen has had its time, the next waiting line
    /// takes its place DIRECTLY, with a full turn of its own counted
    /// from the moment it appears; only an empty queue brings the
    /// wordmark back. Before that moment nothing changes, so a wake-up
    /// that comes early cannot cut a line short.
    mutating func advance(now: Date, duration: TimeInterval) {
        guard let shownAt, now >= shownAt.addingTimeInterval(duration) else { return }
        if waiting.isEmpty {
            current = nil
            self.shownAt = nil
        } else {
            current = waiting.removeFirst()
            self.shownAt = now
        }
    }
}

/// Drives the queue on the clock and publishes the line on screen.
@MainActor
final class UpdateAnnouncer: ObservableObject {

    static let shared = UpdateAnnouncer()

    /// How long one line stays in place of the wordmark.
    nonisolated static let defaultDuration: TimeInterval = 5

    /// The line on screen, or nil for the wordmark.
    @Published private(set) var current: UpdateAnnouncement?

    /// Settings → Display → Show update messages. Installed at launch
    /// (the setting lives in config, which this file does not reach);
    /// off, nothing is queued, shown or spoken.
    var isEnabled: () -> Bool = { true }

    let duration: TimeInterval
    private var queue = UpdateAnnouncementQueue()
    private var wakeUp: Task<Void, Never>?

    /// Lines that arrived while nobody could see the logo, in order. They
    /// join the queue — and their five seconds start — the moment someone
    /// can: an update made in Terminal is usually noticed while Terminal
    /// is in front, and one made from Settings → Updates can land behind
    /// the Settings sheet on a narrow window.
    private var deferred: [String] = []
    private var appActive = true
    /// A sheet (Settings, Add Model) is up over the main window.
    private var sheetPresented = false
    private var activityWatch: [NSObjectProtocol] = []

    /// Whether the sheet that is up hides the logo — asked only while one
    /// is. Installed by the sidebar's lockup, which knows where it is
    /// drawn (`sheetCovers(_:)`). Until one is (no lockup drawn, or a
    /// harness), a sheet counts as hiding it.
    ///
    /// A sheet is not taken to hide the logo just by being up. Settings
    /// is a centred sheet some 720 pt wide, so on most windows the
    /// sidebar — logo and all — stays in plain view beside it; and every
    /// manual update is run from there, with Settings open. Holding each
    /// line until the sheet closed meant no manual update was ever said
    /// when it landed: the logo stayed "SipAI" in front of the user
    /// watching it, and the line played later, once, wherever they were
    /// looking after closing Settings.
    var sheetCoversLockup: @MainActor () -> Bool = { true }

    init(duration: TimeInterval = UpdateAnnouncer.defaultDuration) {
        self.duration = duration
        appActive = NSApp?.isActive ?? true
        let center = NotificationCenter.default
        activityWatch = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAppActive(true) }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAppActive(false) }
            },
        ]
    }

    /// Whether the user can see the logo: SipAI in front, and no sheet
    /// over the logo itself.
    private var logoInView: Bool {
        appActive && !(sheetPresented && sheetCoversLockup())
    }

    /// Queue a line — or hold it until the user can see the logo.
    /// The same sentence already showing, waiting or held is not queued
    /// twice: one update can be seen by two routes at once (the Update
    /// button's own finish, and the re-stat that notices the new
    /// binary), and saying it twice is not more true.
    func announce(_ text: String) {
        guard isEnabled(), !queue.holds(text: text), !deferred.contains(text) else { return }
        guard logoInView else {
            deferred.append(text)
            return
        }
        queue.enqueue(UpdateAnnouncement(text: text), now: Date())
        sync()
    }

    /// SipAI came to the front, or went behind another app.
    func setAppActive(_ active: Bool) {
        appActive = active
        releaseDeferred()
    }

    /// A sheet (Settings, Add Model) was presented over the main window,
    /// or dismissed.
    func setSheetPresented(_ presented: Bool) {
        sheetPresented = presented
        releaseDeferred()
    }

    /// Whether a sheet attached to `lockup`'s window overlaps it on
    /// screen — the lockup's own view, so the test is exactly the area
    /// the line would be drawn in.
    ///
    /// A lockup in no window cannot be seen, so it counts as covered. A
    /// sheet reported up but not attached yet — the moment it is being
    /// presented — counts as covering too: that is the rule this
    /// replaced, and the safe side of an unanswerable question.
    static func sheetCovers(_ lockup: NSView) -> Bool {
        guard let window = lockup.window else { return true }
        let sheets = window.sheets.filter(\.isVisible)
        guard !sheets.isEmpty else { return true }
        let onScreen = window.convertToScreen(lockup.convert(lockup.bounds, to: nil))
        return sheets.contains { $0.frame.intersects(onScreen) }
    }

    private func releaseDeferred() {
        guard logoInView, !deferred.isEmpty else { return }
        let lines = deferred
        deferred = []
        // A line switched off meanwhile is dropped, not shown late.
        guard isEnabled() else { return }
        let now = Date()
        for text in lines where !queue.holds(text: text) {
            queue.enqueue(UpdateAnnouncement(text: text), now: now)
        }
        sync()
    }

    /// Publish what the queue says is on screen, and wake up when that
    /// has had its time.
    ///
    /// Once a line has started, its clock runs whether or not the header
    /// is drawn: a hidden sidebar lets it pass unseen, and a line is not
    /// paused because the user switched apps mid-way. Only a line's
    /// START waits for the logo to be in view (`announce`).
    private func sync() {
        if current != queue.current {
            current = queue.current
            // Not for a line queued before the switch went off: the
            // header hides it, and VoiceOver must not read it out.
            if let line = current, isEnabled() { Self.speak(line.text) }
        }
        wakeUp?.cancel()
        guard let end = queue.endsAt(duration: duration) else {
            wakeUp = nil
            return
        }
        let delay = max(end.timeIntervalSinceNow, 0.01)
        wakeUp = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.queue.advance(now: Date(), duration: self.duration)
            self.sync()
        }
    }

    /// VoiceOver reads the line as it appears: it is on screen for a few
    /// seconds, and nothing else in the app says it.
    private static func speak(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app,
                             notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
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
