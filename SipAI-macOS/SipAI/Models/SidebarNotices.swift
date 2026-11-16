// SidebarNotices.swift
// SipAI macOS — the bubble beside the sidebar's logo: what it says, for
// how long, in which order, and what a click on it does.
//
// The bubble takes the wordmark's place, centred on the logo, as tall as
// its line or two and never taller than the logo (`SidebarBrandLockup`),
// and holds two kinds of notice:
//
//   * An update ON OFFER stays: SipAI's own (a release Sparkle found, or
//     an install held for a running turn) and each command-line tool's,
//     with an Update (or Install Now) button and a ×. The offers are what
//     the Settings badge counts (`UpdateBadge.items`), less what the user
//     closed or acted on at that version — so a newer release comes back,
//     and so does the same release once an update of it has failed.
//   * Something that HAPPENED shows for a few seconds and goes: a card
//     waiting on the user (10 s), a chat or agent turn that ended while
//     the user was looking elsewhere (5 s), an update that landed (5 s).
//     These queue, one at a time and each its full time, and take the
//     update on offer's place; it comes back once they have gone.
//
// A line or two at the session titles' size holds little, so every notice
// carries a short line and its whole sentence: the hover, and what
// VoiceOver reads.
//
// The queue, the words and the rule for which offer shows are pure, so a
// harness drives them with no window, no clock and no app
// (`Verification/SidebarNotices`). The driver reaches nothing of the app
// but the badge: what keeps a notice true, what a click opens and what an
// Update button runs are closures installed at launch.

import AppKit
import Combine
import Foundation

// MARK: - A notice that happened

/// What a notice that happened is about: what a click on it opens, and
/// what has to stay true for it to stay up.
enum SidebarNoticeTarget: Hashable {
    /// An agent session, by its id.
    case session(String)
    /// A chat, by the (slug, chat group) pair every save and reply is
    /// addressed by.
    case chat(slug: String, project: String?)
}

struct SidebarNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A card of a session waits on the user — a permission, a plan,
        /// a question, an MCP server's form or link.
        case needsAction
        /// A turn ended with its answer.
        case finished
        /// A turn ended on an error.
        case failed
        /// An update of SipAI or of a tool landed.
        case updated
    }

    let id = UUID()
    let kind: Kind
    /// The short line the bubble draws, wrapping onto a second where it
    /// must.
    let line: String
    /// The whole sentence: the bubble's hover, and what VoiceOver reads.
    let sentence: String
    /// What a click opens; nil for a notice that opens nothing.
    var target: SidebarNoticeTarget? = nil
    /// The card a needs-action notice is about, for one whose session has
    /// no id to address yet.
    var requestId: String? = nil
    /// When it happened.
    var postedAt = Date()

    /// How long it stays once it shows: a card waiting on the user
    /// longer than news.
    var duration: TimeInterval {
        kind == .needsAction ? SidebarNotices.actionDuration : SidebarNotices.newsDuration
    }

    /// Two notices with one key say one thing, and the second is not
    /// queued: one update seen by two routes at once (the Update button's
    /// own finish and the re-stat that notices the new binary), a
    /// session's second card behind its first, a turn that ends twice
    /// while the first is still being said.
    var key: String {
        switch kind {
        case .needsAction:
            return "action:" + (target.map(Self.describe) ?? requestId ?? line)
        case .finished, .failed:
            return "turn:" + (target.map(Self.describe) ?? line)
        case .updated:
            return "updated:" + line
        }
    }

    /// A turn's end held back while nobody could see the logo, for longer
    /// than `SidebarNotices.heldTurnLimit`, is no longer "just": coming
    /// back to SipAI after the night's scheduled runs would otherwise play
    /// them one after another, five seconds each. Its steady dot says the
    /// same and stays. A card still waiting, and an update that landed,
    /// are said however long they waited.
    func isStale(at now: Date) -> Bool {
        (kind == .finished || kind == .failed)
            && now.timeIntervalSince(postedAt) > SidebarNotices.heldTurnLimit
    }

    private static func describe(_ target: SidebarNoticeTarget) -> String {
        switch target {
        case .session(let id): return "session:" + id
        case .chat(let slug, let project): return "chat:" + (project ?? "") + "/" + slug
        }
    }

    // MARK: Made from what happened

    /// A card of an agent session waits on the user.
    static func needsAction(agent: String, group: String?,
                            sessionId: String?, requestId: String) -> SidebarNotice {
        let words = SidebarNoticeWords.needsAction(agent: agent, group: group)
        return SidebarNotice(kind: .needsAction, line: words.line, sentence: words.sentence,
                             target: sessionId.map { .session($0) }, requestId: requestId)
    }

    /// An agent session's turn ended while the user was elsewhere.
    static func agentTurnEnded(agent: String, group: String?,
                               sessionId: String, failed: Bool) -> SidebarNotice {
        let words = SidebarNoticeWords.agentTurnEnded(agent: agent, group: group, failed: failed)
        return SidebarNotice(kind: failed ? .failed : .finished, line: words.line,
                             sentence: words.sentence, target: .session(sessionId))
    }

    /// A chat's reply landed — or failed to — while the user was elsewhere.
    static func chatTurnEnded(provider: String, group: String?,
                              slug: String, project: String?, failed: Bool) -> SidebarNotice {
        let words = SidebarNoticeWords.chatTurnEnded(provider: provider, group: group, failed: failed)
        return SidebarNotice(kind: failed ? .failed : .finished, line: words.line,
                             sentence: words.sentence, target: .chat(slug: slug, project: project))
    }

    /// SipAI, or a tool, has just been updated.
    static func updated(name: String, version: String) -> SidebarNotice {
        let words = SidebarNoticeWords.updated(name: name, version: version)
        return SidebarNotice(kind: .updated, line: words.line, sentence: words.sentence)
    }
}

/// The notices that happened, as a value: the one on screen, since when,
/// and what waits behind it.
///
/// `scale` multiplies every duration — 1 in the app; a harness shortens
/// the clock with it.
struct SidebarNoticeQueue: Equatable {
    private(set) var current: SidebarNotice?
    private(set) var shownAt: Date?
    private(set) var waiting: [SidebarNotice] = []

    /// Shows at once when nothing is showing; otherwise waits its turn.
    mutating func enqueue(_ notice: SidebarNotice, now: Date) {
        if current == nil {
            current = notice
            shownAt = now
        } else {
            waiting.append(notice)
        }
    }

    /// When the notice on screen has had its time. nil when none shows.
    func endsAt(scale: Double = 1) -> Date? {
        guard let current, let shownAt else { return nil }
        return shownAt.addingTimeInterval(current.duration * scale)
    }

    /// Whether a notice saying this is on screen or waiting.
    func holds(key: String) -> Bool {
        current?.key == key || waiting.contains { $0.key == key }
    }

    /// Once the notice on screen has had ITS time, the next waiting one
    /// takes its place DIRECTLY, with a full turn of its own counted from
    /// the moment it appears; only an empty queue gives the place back.
    /// Before that moment nothing changes, so a wake-up that comes early
    /// cannot cut a notice short.
    mutating func advance(now: Date, scale: Double = 1) {
        guard let end = endsAt(scale: scale), now >= end else { return }
        takeDown(now: now)
    }

    /// The notice on screen goes now — a click opened what it names, or
    /// it stopped being true — and the next one takes its place.
    mutating func takeDown(now: Date) {
        guard current != nil else { return }
        if waiting.isEmpty {
            current = nil
            shownAt = nil
        } else {
            current = waiting.removeFirst()
            shownAt = now
        }
    }

    /// Drops what is no longer true — a card answered, a session opened.
    /// A waiting notice leaves the line; the one on screen gives its
    /// place to the next at once.
    mutating func keep(where isTrue: (SidebarNotice) -> Bool, now: Date) {
        waiting.removeAll { !isTrue($0) }
        if let current, !isTrue(current) { takeDown(now: now) }
    }
}

// MARK: - An update on offer

enum UpdateOfferRules {

    /// What closing (or acting on) an offer records against its key: its
    /// version, and whether it is an update that failed — so a newer
    /// release comes back, and so does the same release once an update
    /// of it has failed (the failure is news the user has not seen).
    static func token(_ item: UpdateBadgeItem) -> String {
        item.failed ? item.version + "|failed" : item.version
    }

    /// The one offer the bubble shows: the first of `items` not closed at
    /// its token. SipAI's release is passed over while its install is
    /// held: the held install says the same thing, with Install Now.
    static func shown(_ items: [UpdateBadgeItem], closed: [String: String]) -> UpdateBadgeItem? {
        let held = items.contains { $0.key == UpdateBadgeItem.appInstallKey }
        return items.first { item in
            !(held && item.key == UpdateBadgeItem.appKey) && closed[item.key] != token(item)
        }
    }

    /// The record once `item` has been closed or acted on.
    static func closing(_ item: UpdateBadgeItem, in closed: [String: String]) -> [String: String] {
        var next = closed
        next[item.key] = token(item)
        return next
    }
}

// MARK: - The words

/// Every sentence a notice says, short and whole. Agents and providers
/// arrive by the names the user sees (the label from Settings → Labels, a
/// provider's display name); nothing here spells one.
///
/// The article belongs to "session", "agent session" and "chat session",
/// never to the name: "a" or "an" before a name is decided by how the name
/// SOUNDS ("an NVIDIA chat"), which nothing here can read off its letters.
enum SidebarNoticeWords {

    static func needsAction(agent: String, group: String?) -> (line: String, sentence: String) {
        guard let group else {
            return (String(localized: "\(agent) needs you",
                           comment: "Sidebar notice beside the logo, one short line: a card of an agent session waits on the user (a permission, a plan, a question); placeholder is the agent's label"),
                    String(localized: "A session with \(agent) needs your action.",
                           comment: "Sidebar notice beside the logo, the whole sentence (its hover and VoiceOver): a card of an agent session waits on the user; placeholder is the agent's label"))
        }
        return (String(localized: "\(agent) · \(group) needs you",
                       comment: "Sidebar notice beside the logo, one short line: a card of an agent session waits on the user; placeholders are the agent's label and the sidebar group the session is under"),
                String(localized: "A session with \(agent) under the “\(group)” group needs your action.",
                       comment: "Sidebar notice beside the logo, the whole sentence (its hover and VoiceOver): a card of an agent session waits on the user; placeholders are the agent's label and the sidebar group the session is under"))
    }

    static func agentTurnEnded(agent: String, group: String?,
                               failed: Bool) -> (line: String, sentence: String) {
        switch (group, failed) {
        case (nil, false):
            return (String(localized: "\(agent) finished",
                           comment: "Sidebar notice beside the logo, one short line: an agent session's turn ended with its answer while the user was elsewhere; placeholder is the agent's label"),
                    String(localized: "An agent session with \(agent) just finished its response.",
                           comment: "Sidebar notice beside the logo, the whole sentence: an agent session's turn ended with its answer; placeholder is the agent's label"))
        case (let group?, false):
            return (String(localized: "\(agent) · \(group) finished",
                           comment: "Sidebar notice beside the logo, one short line: an agent session's turn ended with its answer while the user was elsewhere; placeholders are the agent's label and the sidebar group the session is under"),
                    String(localized: "An agent session with \(agent) under the “\(group)” group just finished its response.",
                           comment: "Sidebar notice beside the logo, the whole sentence: an agent session's turn ended with its answer; placeholders are the agent's label and the sidebar group the session is under"))
        case (nil, true):
            return (String(localized: "\(agent) failed",
                           comment: "Sidebar notice beside the logo, one short line: an agent session's turn ended on an error while the user was elsewhere; placeholder is the agent's label"),
                    String(localized: "An agent session with \(agent) ended with an error.",
                           comment: "Sidebar notice beside the logo, the whole sentence: an agent session's turn ended on an error; placeholder is the agent's label"))
        case (let group?, true):
            return (String(localized: "\(agent) · \(group) failed",
                           comment: "Sidebar notice beside the logo, one short line: an agent session's turn ended on an error while the user was elsewhere; placeholders are the agent's label and the sidebar group the session is under"),
                    String(localized: "An agent session with \(agent) under the “\(group)” group ended with an error.",
                           comment: "Sidebar notice beside the logo, the whole sentence: an agent session's turn ended on an error; placeholders are the agent's label and the sidebar group the session is under"))
        }
    }

    static func chatTurnEnded(provider: String, group: String?,
                              failed: Bool) -> (line: String, sentence: String) {
        switch (group, failed) {
        case (nil, false):
            return (String(localized: "\(provider) chat finished",
                           comment: "Sidebar notice beside the logo, one short line: a chat's reply landed while the user was elsewhere; placeholder is the model provider's name"),
                    String(localized: "A chat session with \(provider) just finished its response.",
                           comment: "Sidebar notice beside the logo, the whole sentence: a chat's reply landed; placeholder is the model provider's name"))
        case (let group?, false):
            return (String(localized: "\(provider) chat · \(group) finished",
                           comment: "Sidebar notice beside the logo, one short line: a chat's reply landed while the user was elsewhere; placeholders are the model provider's name and the chat group"),
                    String(localized: "A chat session with \(provider) under the “\(group)” group just finished its response.",
                           comment: "Sidebar notice beside the logo, the whole sentence: a chat's reply landed; placeholders are the model provider's name and the chat group"))
        case (nil, true):
            return (String(localized: "\(provider) chat failed",
                           comment: "Sidebar notice beside the logo, one short line: a chat's turn ended on an error while the user was elsewhere; placeholder is the model provider's name"),
                    String(localized: "A chat session with \(provider) ended with an error.",
                           comment: "Sidebar notice beside the logo, the whole sentence: a chat's turn ended on an error; placeholder is the model provider's name"))
        case (let group?, true):
            return (String(localized: "\(provider) chat · \(group) failed",
                           comment: "Sidebar notice beside the logo, one short line: a chat's turn ended on an error while the user was elsewhere; placeholders are the model provider's name and the chat group"),
                    String(localized: "A chat session with \(provider) under the “\(group)” group ended with an error.",
                           comment: "Sidebar notice beside the logo, the whole sentence: a chat's turn ended on an error; placeholders are the model provider's name and the chat group"))
        }
    }

    static func updated(name: String, version: String) -> (line: String, sentence: String) {
        (String(localized: "\(name) updated to \(version)",
                comment: "Sidebar notice beside the logo, one short line: a command-line tool (or SipAI itself) has just been updated; placeholders are the tool's label and the new version"),
         String(localized: "\(name) just updated to \(version)",
                comment: "Sidebar notice beside the logo, the whole sentence (its hover and VoiceOver): a command-line tool (or SipAI itself) has just been updated; placeholders are the tool's label and the new version number"))
    }

    /// An update on offer: the name and the version on the line — the
    /// Update button beside them says the rest. An update that failed for
    /// a cause the tool stated says that cause on the line instead, and
    /// the tool and the version in the sentence: the line is what is read,
    /// and "did not update" alone leaves the user to guess at the cause.
    static func offer(_ item: UpdateBadgeItem) -> (line: String, sentence: String) {
        let line = item.name + " " + item.shownVersion
        let name = item.name, version = item.shownVersion
        switch item.kind {
        case .appInstall:
            return (line, String(localized: "SipAI \(version) will install once the running turn finishes.",
                                 comment: "Sidebar notice beside the logo, the whole sentence (its hover and VoiceOver) of SipAI's update held for a running agent turn — the user chose to wait; placeholder is the new version"))
        case .app, .cli:
            if item.failure == .claudeDownloadTimedOut {
                // The cause alone, in the fewest words: at the sidebar's
                // default width a bubble holds a word or two per line, and
                // anything longer is cut before it reaches the cause.
                let minutes = CLIUpdateFailure.claudeDownloadLimitMinutes
                return (String(localized: "\(minutes)-min timeout",
                               comment: "Sidebar notice beside the logo, one short line (a word or two per line fit): Claude Code's update did not land because Claude Code stopped its own download at its time limit; the whole sentence is on hover. Placeholder is the limit in minutes"),
                        String(localized: "\(name) did not update to \(version): its download timed out. \(name) stops a download that takes longer than \(minutes) minutes.",
                               comment: "Sidebar notice beside the logo, the whole sentence (its hover and VoiceOver): Claude Code's update did not land because Claude Code itself stops a download that takes longer than its time limit; its Update button tries again. Placeholders are the tool's label, the version, the tool's label again and the limit in minutes"))
            }
            if item.failed {
                return (line, String(localized: "\(name) did not update to \(version).",
                                     comment: "Sidebar notice beside the logo, the whole sentence of a tool's update that ran and did not land; its Update button tries again. Placeholders are the tool's label and the version"))
            }
            return (line, String(localized: "\(name) \(version) is available.",
                                 comment: "Sidebar notice beside the logo, the whole sentence (its hover and VoiceOver) of an update on offer; placeholders are SipAI or the tool's label, and the new version"))
        }
    }

    /// The offer's button, as its hover and VoiceOver name it.
    static func offerAction(_ item: UpdateBadgeItem) -> String {
        switch item.kind {
        case .appInstall:
            return String(localized: "Install SipAI \(item.shownVersion) now. The running turn is stopped first.",
                          comment: "Sidebar notice beside the logo: hover and accessibility label of the button that installs SipAI's held update at once; placeholder is the new version")
        case .app, .cli:
            return String(localized: "Update \(item.name) to \(item.shownVersion)",
                          comment: "Sidebar notice beside the logo: hover and accessibility label of the update button; placeholders are SipAI or the tool's label, and the new version")
        }
    }
}

// MARK: - The driver

/// Drives the bubble: the queue on the clock, the offer the badge feeds,
/// and what each publishes for the sidebar to draw.
@MainActor
final class SidebarNotices: ObservableObject {

    static let shared = SidebarNotices()

    /// A card waiting on the user stays this long.
    nonisolated static let actionDuration: TimeInterval = 10
    /// A turn that ended, and an update that landed, stay this long.
    nonisolated static let newsDuration: TimeInterval = 5
    /// How long a turn's end may wait to be seen (`SidebarNotice.isStale`).
    nonisolated static let heldTurnLimit: TimeInterval = 120

    /// Offers closed or acted on, item key → `UpdateOfferRules.token`.
    /// Mac-only UI state, so UserDefaults; registered in
    /// `FactoryReset.userDefaultsKeys`.
    static let closedDefaultsKey = "sidebarNoticeClosed"

    /// The notice that happened, on screen — nil when none is.
    @Published private(set) var current: SidebarNotice?
    /// The update on offer, drawn once no notice is — nil when none is.
    @Published private(set) var offer: UpdateBadgeItem?

    /// Settings → Display → Show notifications beside the logo. Off,
    /// nothing is queued, shown or spoken.
    var isEnabled: () -> Bool = { true }
    /// Whether a notice still says something true: its card still waits
    /// and nobody is looking at it, its session or chat has not been
    /// opened. Asked when a held notice is about to start, and whenever a
    /// `watch`ed signal fires.
    var isStillTrue: (SidebarNotice) -> Bool = { _ in true }
    /// Opens what a clicked notice names.
    var open: (SidebarNoticeTarget) -> Void = { _ in }
    /// Runs an offer's button; true when something started, which is what
    /// takes the offer down (a start refused leaves it standing).
    var performOffer: (UpdateBadgeItem) -> Bool = { _ in false }

    /// Whether the sheet that is up hides the logo — asked only while one
    /// is. Installed by the sidebar's lockup, which knows where it is
    /// drawn (`sheetCovers(_:)`). Until one is (no lockup drawn, or a
    /// harness), a sheet counts as hiding it.
    ///
    /// A sheet is not taken to hide the logo just by being up. Settings is
    /// a mode of the main window that keeps the logo at the top of the
    /// sidebar, and every manual update is run from there; held until a
    /// sheet closed, a manual update would not be said when it landed.
    var sheetCoversLockup: @MainActor () -> Bool = { true }

    private let defaults: UserDefaults
    private let scale: Double
    private var queue = SidebarNoticeQueue()
    private var wakeUp: Task<Void, Never>?

    /// Notices that arrived while nobody could see the logo, in order.
    /// They join the queue — and their time starts — the moment someone
    /// can: a turn that ends while another app is in front would
    /// otherwise spend its seconds where nobody is looking.
    private var deferred: [SidebarNotice] = []
    private var appActive = true
    /// A sheet (Add Model, the Agent Guide's, the Skills page's) is up
    /// over the main window.
    private var sheetPresented = false
    private var activityWatch: [NSObjectProtocol] = []
    private var watches: [AnyCancellable] = []

    private var offerItems: [UpdateBadgeItem] = []
    private var closed: [String: String]
    private var badgeWatch: AnyCancellable?
    /// Off while `init` takes the badge's first answer: what is on offer
    /// at launch is not news, and the switch that could silence it is
    /// installed only after the driver exists.
    private var speaksOffers = false

    /// `scale` multiplies every duration; `badge` is the badge whose items
    /// are on offer.
    init(defaults: UserDefaults = .standard,
         badge: UpdateBadge? = nil,
         scale: Double = 1) {
        self.defaults = defaults
        self.scale = scale
        closed = defaults.dictionary(forKey: Self.closedDefaultsKey) as? [String: String] ?? [:]
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
        // `@Published` delivers the NEW value in its willSet, so the items
        // are taken from the argument, never read back off the badge.
        badgeWatch = (badge ?? UpdateBadge.shared).$items.sink { [weak self] items in
            MainActor.assumeIsolated { self?.setOfferItems(items) }
        }
        speaksOffers = true
    }

    // MARK: Something happened

    /// Queue a notice — or hold it until the user can see the logo. A
    /// notice saying what one showing, waiting or held already says is
    /// not queued twice: one update can be seen by two routes at once,
    /// and saying it twice is not more true.
    func post(_ notice: SidebarNotice) {
        guard isEnabled(), !queue.holds(key: notice.key),
              !deferred.contains(where: { $0.key == notice.key }) else { return }
        guard logoInView else {
            deferred.append(notice)
            return
        }
        queue.enqueue(notice, now: Date())
        sync()
    }

    /// A click on the notice on screen: what it names opens, and the
    /// notice goes — it has been read.
    func click(_ notice: SidebarNotice) {
        guard notice.id == queue.current?.id, let target = notice.target else { return }
        open(target)
        queue.takeDown(now: Date())
        sync()
    }

    /// Takes down what stopped being true — on screen, waiting, or held.
    func revalidate() {
        deferred.removeAll { !isStillTrue($0) }
        let before = queue.current?.id
        queue.keep(where: isStillTrue, now: Date())
        if queue.current?.id != before { sync() }
    }

    /// Re-asks `isStillTrue` whenever `signal` fires — a card answered, a
    /// session opened. Delivered a run-loop turn later: `@Published` fires
    /// in willSet, before the value it announces is stored.
    func watch(_ signal: AnyPublisher<Void, Never>) {
        watches.append(signal
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.revalidate() }
            })
    }

    // MARK: Where the user is looking

    /// Whether the user can see the logo: SipAI in front, and no sheet
    /// over the logo itself.
    private var logoInView: Bool {
        appActive && !(sheetPresented && sheetCoversLockup())
    }

    /// SipAI came to the front, or went behind another app.
    func setAppActive(_ active: Bool) {
        appActive = active
        releaseDeferred()
    }

    /// A sheet was presented over the main window, or dismissed.
    func setSheetPresented(_ presented: Bool) {
        sheetPresented = presented
        releaseDeferred()
    }

    /// Whether a sheet attached to `lockup`'s window overlaps it on
    /// screen — the lockup's own view: the place the bubble is drawn in,
    /// and its margins.
    ///
    /// A lockup in no window cannot be seen, so it counts as covered. A
    /// sheet reported up but not attached yet — the moment it is being
    /// presented — counts as covering too: the safe side of a question
    /// that cannot be answered yet.
    static func sheetCovers(_ lockup: NSView) -> Bool {
        guard let window = lockup.window else { return true }
        let sheets = window.sheets.filter(\.isVisible)
        guard !sheets.isEmpty else { return true }
        let onScreen = window.convertToScreen(lockup.convert(lockup.bounds, to: nil))
        return sheets.contains { $0.frame.intersects(onScreen) }
    }

    /// Held notices start, in the order they came — those switched off, no
    /// longer true, or too old to be news meanwhile are dropped, never
    /// shown late.
    private func releaseDeferred() {
        guard logoInView, !deferred.isEmpty else { return }
        let held = deferred
        deferred = []
        guard isEnabled() else { return }
        let now = Date()
        for notice in held where isStillTrue(notice) && !notice.isStale(at: now)
            && !queue.holds(key: notice.key) {
            queue.enqueue(notice, now: now)
        }
        sync()
    }

    /// Publish what the queue says is on screen, and wake up when that has
    /// had its time.
    ///
    /// Once a notice has started, its clock runs whether or not the bubble
    /// is drawn: a hidden sidebar lets it pass unseen, and a notice is not
    /// paused because the user switched apps mid-way. Only a notice's
    /// START waits for the logo to be in view (`post`).
    private func sync() {
        if current != queue.current {
            current = queue.current
            // Not for a notice queued before the switch went off: the
            // bubble hides it, and VoiceOver must not read it out.
            if let notice = current, isEnabled() { Self.speak(notice.sentence) }
        }
        wakeUp?.cancel()
        guard let end = queue.endsAt(scale: scale) else {
            wakeUp = nil
            return
        }
        let delay = max(end.timeIntervalSinceNow, 0.01)
        wakeUp = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.queue.advance(now: Date(), scale: self.scale)
            self.sync()
        }
    }

    // MARK: An update on offer

    private func setOfferItems(_ items: [UpdateBadgeItem]) {
        offerItems = items
        recomputeOffer()
    }

    /// The offer's button: an update starts, SipAI's window opens, or the
    /// held install goes ahead — and the offer goes with it. One that
    /// could not start stays, so the button is not left to look as if it
    /// had done something.
    func act(on item: UpdateBadgeItem) {
        guard performOffer(item) else { return }
        record(item)
    }

    /// The ×: this offer goes until a newer version — or a failed update
    /// of this one — is on offer.
    func close(_ item: UpdateBadgeItem) {
        record(item)
    }

    /// An offer that is news again whatever was closed before: SipAI's
    /// install held for a running turn, offered anew each time the user
    /// chooses to wait.
    func reopen(key: String) {
        guard closed.removeValue(forKey: key) != nil else { return }
        defaults.set(closed, forKey: Self.closedDefaultsKey)
        recomputeOffer()
    }

    /// A factory reset removed the key; the copy in memory goes with it.
    func forgetClosed() {
        closed = [:]
        recomputeOffer()
    }

    private func record(_ item: UpdateBadgeItem) {
        closed = UpdateOfferRules.closing(item, in: closed)
        defaults.set(closed, forKey: Self.closedDefaultsKey)
        recomputeOffer()
    }

    private func recomputeOffer() {
        let next = UpdateOfferRules.shown(offerItems, closed: closed)
        guard next != offer else { return }
        let isNew = next.map { UpdateOfferRules.token($0) != offer.map(UpdateOfferRules.token)
                               || $0.key != offer?.key } ?? false
        offer = next
        if isNew, speaksOffers, let next, isEnabled() {
            Self.speak(SidebarNoticeWords.offer(next).sentence)
        }
    }

    /// VoiceOver reads a notice as it appears: nothing else in the app
    /// says it.
    private static func speak(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app,
                             notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
