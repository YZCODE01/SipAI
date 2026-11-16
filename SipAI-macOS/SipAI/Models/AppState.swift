// AppState.swift
// Shared, observable UI state for the app.

import AppKit
import Foundation
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    /// The APPLICATION's appearance for this choice — nil for System, so
    /// macOS decides. The window's root sets it as `NSApp.appearance`.
    ///
    /// Never SwiftUI's `.preferredColorScheme`. That preference reaches
    /// only the window it is set in, so an alert run on its own, a file
    /// panel, a menu and Sparkle's windows keep the Mac's look under Light
    /// or Dark. And set back to nil it leaves the window's views on the
    /// scheme they had: the window returns to the Mac's look, but SwiftUI
    /// keeps the old scheme through every redraw until something such as
    /// the window losing focus makes it read the window's look again — so
    /// choosing System appears to do nothing. Every window inherits the
    /// app's appearance, and a change of it — back to nil included —
    /// reaches every view at once.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var localizedName: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// The app's UI language.
///
/// There is deliberately no `.system` case, and no `\.locale`
/// environment override anywhere. macOS resolves an app's language from
/// the intersection of the user's preferred-language list and the
/// bundle's declared localizations, and the only supported way to
/// override that per app is the `AppleLanguages` key in the app's own
/// UserDefaults domain — which is exactly what System Settings →
/// General → Language & Region → Applications writes.
///
/// `.environment(\.locale, …)` is NOT that mechanism. It is read by
/// SwiftUI `Text` at best, and never by `String(localized:)`, by
/// AppKit's open/save panels, or by the `static` `DateFormatter`s in
/// the sidebar. Driving the picker through it would split the UI down
/// the middle by which API each string happens to use.
///
/// Because `AppleLanguages` is read at launch, switching requires a
/// relaunch. `LanguagePane` says so and offers to do it.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english
    case chinese

    var id: String { rawValue }

    /// The bundle localization this choice selects — must match a
    /// folder in `knownRegions` / the string catalog.
    var localizationCode: String {
        switch self {
        case .english: return "en"
        case .chinese: return "zh-Hans"
        }
    }

    /// Language names are written in their OWN language, always — a
    /// reader looking for their language must be able to recognise it
    /// without already being able to read the current one. So this is a
    /// plain `String` and never goes through the string catalog.
    var endonym: String {
        switch self {
        case .english: return "English"
        case .chinese: return "中文"
        }
    }

    /// The choice matching a bundle localization code, or nil for one
    /// we don't ship.
    static func matching(localizationCode code: String) -> AppLanguage? {
        let lower = code.lowercased()
        if lower == "en" || lower.hasPrefix("en-") { return .english }
        if lower.hasPrefix("zh") { return .chinese }
        return nil
    }

    /// What the bundle ACTUALLY resolved to for this launch. This is the
    /// truth the UI is currently rendering in, whatever config.json says
    /// — they disagree for exactly one launch after a switch, before the
    /// relaunch lands.
    static var effective: AppLanguage {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return matching(localizationCode: code) ?? .english
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var leftSidebarVisible: Bool = true

    @Published var theme: AppTheme = .system

    /// The language the picker is showing. Seeded from `ConfigManager`
    /// at launch, which in turn seeds from the bundle's own resolution
    /// on a first run. Changing it does not re-render anything — the
    /// switch lands on relaunch (see `AppLanguage`).
    @Published var language: AppLanguage = .effective

    /// Currently-open chat slug + project (nil project = root chat). nil = no chat open yet.
    /// Setting this non-nil clears any open agent session (mutually exclusive
    /// with `openAgentSessionId`).
    @Published var openChatSlug: String? = nil {
        didSet {
            guard openChatSlug != nil else { return }
            if openAgentSessionId != nil { openAgentSessionId = nil }
            if openAgentSessionPath != nil { openAgentSessionPath = nil }
            if openScheduledTaskName != nil { openScheduledTaskName = nil }
            if openNoteId != nil { openNoteId = nil }
            if pendingClaudeSessionDraft != nil { pendingClaudeSessionDraft = nil }
        }
    }
    @Published var openChatProject: String? = nil

    /// Currently-open Claude Code agent session (UUID = filename stem).
    /// Setting this non-nil clears any open chat (mutually exclusive with
    /// `openChatSlug`).
    @Published var openAgentSessionId: String? = nil {
        didSet {
            guard openAgentSessionId != nil else { return }
            if openChatSlug != nil { openChatSlug = nil }
            if openChatProject != nil { openChatProject = nil }
            if openNoteId != nil { openNoteId = nil }
            if pendingClaudeSessionDraft != nil { pendingClaudeSessionDraft = nil }
        }
    }
    /// Absolute path to the open agent session's JSONL, for history lookups
    /// that don't want to re-resolve through `AgentManager.sessions`.
    @Published var openAgentSessionPath: URL? = nil

    /// Name of the scheduled task whose key-information panel is showing
    /// — above a run's transcript, or as the task's whole page — or nil.
    ///
    /// Deliberately NOT mutually exclusive with `openAgentSessionId`:
    /// opening a run from under its task shows the run *and* the task's
    /// panel, and clicking between that task's runs keeps the panel up.
    /// The sidebar is what clears it — a row that isn't one of the task's
    /// runs sets it to nil as it opens. The chat / note / draft routes
    /// clear it too, since those replace the centre pane outright.
    ///
    /// The task's own row sets this with `openAgentSessionId` nil — the
    /// task's page — which is why `ContentView.centerPane` tests for it
    /// explicitly.
    @Published var openScheduledTaskName: String? = nil

    /// Holds a nascent Claude Code session before its first message is
    /// sent. While non-nil, `ContentView` routes the center column to
    /// `AgentSessionView` in draft mode (empty transcript, input box
    /// ready). On first successful send `AgentSessionView` clears this
    /// field and sets `openAgentSessionId` + `openAgentSessionPath`,
    /// transitioning to the real session.
    @Published var pendingClaudeSessionDraft: ClaudeSessionDraft? = nil {
        didSet {
            guard pendingClaudeSessionDraft != nil else { return }
            if openChatSlug != nil { openChatSlug = nil }
            if openChatProject != nil { openChatProject = nil }
            if openAgentSessionId != nil { openAgentSessionId = nil }
            if openAgentSessionPath != nil { openAgentSessionPath = nil }
            if openScheduledTaskName != nil { openScheduledTaskName = nil }
            if openNoteId != nil { openNoteId = nil }
        }
    }

    /// Currently-open note (slug = filename stem). Setting this non-nil
    /// clears any open chat or agent session (mutually exclusive with
    /// `openChatSlug` and `openAgentSessionId`).
    @Published var openNoteId: String? = nil {
        didSet {
            guard openNoteId != nil else { return }
            if openChatSlug != nil { openChatSlug = nil }
            if openChatProject != nil { openChatProject = nil }
            if openAgentSessionId != nil { openAgentSessionId = nil }
            if openAgentSessionPath != nil { openAgentSessionPath = nil }
            if openScheduledTaskName != nil { openScheduledTaskName = nil }
            if pendingClaudeSessionDraft != nil { pendingClaudeSessionDraft = nil }
        }
    }

    /// Query handed forward to the conversation the router is ABOUT to
    /// open, so a global-search result arrives with its find bar
    /// already open on the text that produced the row.
    ///
    /// Set immediately before one of the routing fields above, and
    /// consumed — and cleared — by whichever centre-pane view takes the
    /// route. It has to travel through AppState rather than as an
    /// argument because ContentView's router creates the destination
    /// view fresh; there is nothing to hand a parameter to.
    @Published var pendingFindQuery: String? = nil

    /// The Settings section on screen, or nil.
    ///
    /// Settings is a LAYER over the routing fields above, never one of
    /// them: while this is set the sidebar lists the settings sections
    /// and the centre pane shows this one, and the fields are left
    /// exactly as they were. Leaving Settings therefore lands on
    /// whatever was open, and a route that changes meanwhile (a note
    /// that finished generating, a task's new run) is simply there on
    /// the way back.
    ///
    /// Nothing in the routing fields' `didSet`s clears it. The user
    /// leaves through the sidebar, or by opening something from outside
    /// Settings — a search result, a notification — and those call sites
    /// close it themselves. `startNewChat()` in particular must not: the
    /// factory reset runs it on its PARTIAL-failure path too, where
    /// closing Settings would take down the view whose alert is the only
    /// report of what survived the wipe.
    @Published var settingsSection: SettingsView.Tab? = nil

    /// Open Settings on `section`, with the sidebar in view: the sections
    /// and the way back live there, and a deep link (the composer's
    /// context-chip "?", the chat page's "Learn more") can arrive while
    /// it is hidden.
    func openSettings(_ section: SettingsView.Tab) {
        settingsSection = section
        if !leftSidebarVisible { leftSidebarVisible = true }
    }

    /// Settings → Agent Skills: the folder whose own skills the pane lists
    /// beside the global ones — nil for the global ones alone. Kept here,
    /// not in the pane, because the pane is rebuilt on every visit;
    /// `skillsFolderChosen` tells "the user chose the global skills" from
    /// "nothing chosen yet", when the pane picks the open session's
    /// folder.
    @Published var skillsFolder: URL? = nil
    var skillsFolderChosen = false
    /// Settings → Agent Skills: the section and group headers whose fold the
    /// user has flipped from its default (plugin and built-in groups
    /// start folded, everything else open).
    @Published var skillGroupsToggled: Set<String> = []

    /// Settings → Agent Skills back as a new install has it: nothing chosen,
    /// nothing folded. For the factory reset — the folder chosen before
    /// it is held here, in memory, and the page writes the folder it
    /// shows into the browse history the reset has just cleared.
    func forgetSkillsPage() {
        skillsFolder = nil
        skillsFolderChosen = false
        skillGroupsToggled = []
    }

    /// Whether one of the main window's own overlays is up — the menu
    /// over the sidebar's Settings row, the search palette, the
    /// plan-usage window. Each is drawn IN the window, over the pane,
    /// and takes the keyboard for itself while it shows. The cards a
    /// turn waits on read their keys through a local event monitor
    /// (`ApprovalCardKeys`), which sees a key BEFORE the window
    /// dispatches it to such an overlay — and under a focused SwiftUI
    /// view the first responder is the hosting view, as it is when
    /// nothing has focus, so the overlay cannot be told from an idle
    /// window by asking the window. It is told here instead: written by
    /// `ContentView`, which owns the three, and read at key time only —
    /// not `@Published`, since nothing renders from it.
    var overlayHoldsKeys = false

    /// Currently-selected model id (key in config.json `models`).
    @Published var activeModel: String? = nil

    /// Active AI role (nil = no role, use default system prompt).
    @Published var activeRole: RoleConfig? = nil

    // MARK: - Composer drafts

    /// Unsent composer text, keyed by where it was typed. Half-written
    /// messages are the user's work: clicking around the app must never
    /// throw one away, and it must never follow the user into a
    /// different conversation either (one Return would send it to the
    /// wrong place).
    ///
    /// This lives on AppState — which exists for as long as the app
    /// does — rather than in the views, because ContentView's centre-pane
    /// router tears `ChatView` / `AgentSessionView` / `NoteView` down on
    /// every detour between them. `@State` there dies with each switch,
    /// so a draft would survive clicking between sessions but not a
    /// single trip to a chat and back.
    ///
    /// In memory only, deliberately: drafts live until the user clears
    /// them or the app quits.
    ///
    /// NOT `@Published`. Views own the live text and write it through here
    /// on every change; publishing each write would re-render the whole
    /// window for a bookkeeping write. (Same reasoning as
    /// `AgentManager.historyCache`.)
    private var composerDrafts: [String: String] = [:]

    /// Draft key for a chat. An empty slug is the unsent new chat, which
    /// gets its own slot so text typed before the first send survives a
    /// detour too.
    static func chatDraftKey(slug: String?, project: String?) -> String {
        "chat:\(project ?? "")/\(slug ?? "")"
    }

    /// Draft key for an agent transcript. `transcriptKey` is the session
    /// id, or — before the first send reveals one — the key of the place
    /// the new session was started from (`NewSessionPlace.draftKey`); the
    /// prefix keeps the two id spaces from colliding with chat slugs.
    static func agentDraftKey(_ transcriptKey: String?) -> String {
        "agent:\(transcriptKey ?? "")"
    }

    func composerDraft(for key: String) -> String {
        composerDrafts[key] ?? ""
    }

    /// Files staged in an agent composer, keyed like the text and for
    /// the same reason: a staged file is the user's work and must survive
    /// a detour. Same store rules — written on every change, empty
    /// removes, not `@Published`.
    private var composerAttachments: [String: [AgentAttachment]] = [:]

    func composerAttachments(for key: String) -> [AgentAttachment] {
        composerAttachments[key] ?? []
    }

    func setComposerAttachments(_ attachments: [AgentAttachment], for key: String) {
        if attachments.isEmpty {
            composerAttachments.removeValue(forKey: key)
        } else {
            composerAttachments[key] = attachments
        }
    }

    /// Stash (or, for empty text, forget) one identity's unsent message.
    func setComposerDraft(_ text: String, for key: String) {
        if text.isEmpty {
            composerDrafts.removeValue(forKey: key)
        } else {
            composerDrafts[key] = text
        }
    }

    /// A conversation moved to a new address: its unsent text goes with
    /// it, REPLACING whatever the new address held, and nothing stays
    /// behind. A chat's address is its (group, slug), and both halves
    /// are reused — the next chat to take the old address must not find
    /// this one's text waiting there.
    func moveComposerDraft(from oldKey: String, to newKey: String) {
        guard oldKey != newKey else { return }
        setComposerDraft(composerDraft(for: oldKey), for: newKey)
        setComposerDraft("", for: oldKey)
    }

    /// A chat group is deleted with every chat in it: their unsent text
    /// goes too — the group's new-chat slot included, which is
    /// `chatDraftKey` with an empty slug, i.e. this very prefix.
    func dropComposerDrafts(inChatGroup group: String) {
        let prefix = Self.chatDraftKey(slug: "", project: group)
        composerDrafts = composerDrafts.filter { !$0.key.hasPrefix(prefix) }
    }

    /// The schedule set up on an unsent new session (the composer's
    /// calendar control), keyed like the text, for the same reason and
    /// under the same rules: written on every change, dropped once back
    /// to untouched, not `@Published`. Only a new session's key ever
    /// holds one — a session that exists cannot become a task.
    private var composerSchedules: [String: ScheduleDraft] = [:]

    func composerSchedule(for key: String) -> ScheduleDraft {
        composerSchedules[key] ?? ScheduleDraft()
    }

    func setComposerSchedule(_ schedule: ScheduleDraft, for key: String) {
        if schedule == ScheduleDraft() {
            composerSchedules.removeValue(forKey: key)
        } else {
            composerSchedules[key] = schedule
        }
    }

    /// What an unsent new session's skill chip was set to, and what was
    /// changed on its mode / model / effort / speed chips (chip by chip,
    /// `NewSessionChipEdits`), keyed like its text — by the place it was
    /// started from (`NewSessionPlace`). The new session itself
    /// (`pendingClaudeSessionDraft`) is dropped the moment anything else
    /// opens, so what was set on it is kept here, where the next new
    /// session started from the same + finds it, as it finds the text.
    /// Nil where nothing was set: the new session's chips then start from
    /// its place's memory, and its skills are the agent's pinned ones. An
    /// empty skill list is a choice of its own.
    private var newSessionSkillPicks: [String: [String]] = [:]
    private var newSessionChipEdits: [String: NewSessionChipEdits] = [:]

    func newSessionSkillPicks(for key: String) -> [String]? {
        newSessionSkillPicks[key]
    }

    func setNewSessionSkillPicks(_ picks: [String]?, for key: String) {
        newSessionSkillPicks[key] = picks
    }

    func newSessionChipEdits(for key: String) -> NewSessionChipEdits? {
        newSessionChipEdits[key]
    }

    func setNewSessionChipEdits(_ edits: NewSessionChipEdits?, for key: String) {
        newSessionChipEdits[key] = edits
    }

    /// Forget every unsent message, and what was set up beside it. Only
    /// the factory reset calls this: drafts are deliberately kept through
    /// every ordinary navigation, and they live in RAM alone, so wiping
    /// the data directory cannot reach them. Without this a "reset to
    /// first run" hands the very first composer the user opens a
    /// half-written message from the install they just erased.
    func clearComposerDrafts() {
        composerDrafts.removeAll()
        composerAttachments.removeAll()
        composerSchedules.removeAll()
        newSessionSkillPicks.removeAll()
        newSessionChipEdits.removeAll()
    }

    /// Clear all four routing fields so the center column shows the empty
    /// `ChatView` welcome state. Use this anywhere the user asks to
    /// "start fresh" (sidebar New Chat, post-delete navigation, factory
    /// reset). Centralized here so call sites can't forget one of the
    /// fields.
    func startNewChat() {
        openAgentSessionId = nil
        openAgentSessionPath = nil
        openScheduledTaskName = nil
        openChatSlug = nil
        openChatProject = nil
        openNoteId = nil
        pendingClaudeSessionDraft = nil
        // A find handed forward by a search result belongs to the route
        // it was handed to. Starting fresh cancels that route, so the
        // query must not survive to open a find bar on an empty chat.
        pendingFindQuery = nil
    }

    // MARK: - New sessions by place

    /// A custom group was renamed. Groups are keyed by name, and so is
    /// the unsent new session of each one's + (`NewSessionPlace.custom`):
    /// what it holds moves to the new name, REPLACING what the new name
    /// held, and nothing stays behind — the next group given the old name
    /// must not find it. A new session of that group on screen moves too;
    /// its page adopts the new key (`AgentSessionView`'s place identity).
    func renameNewSessionGroup(_ old: String, to new: String, agentKey: String) {
        guard old != new else { return }
        let from = Self.agentDraftKey(NewSessionPlace.custom(old).draftKey(agentKey: agentKey))
        let to = Self.agentDraftKey(NewSessionPlace.custom(new).draftKey(agentKey: agentKey))
        moveComposerDraft(from: from, to: to)
        setComposerAttachments(composerAttachments(for: from), for: to)
        setComposerAttachments([], for: from)
        setComposerSchedule(composerSchedule(for: from), for: to)
        composerSchedules.removeValue(forKey: from)
        newSessionSkillPicks[to] = newSessionSkillPicks.removeValue(forKey: from)
        newSessionChipEdits[to] = newSessionChipEdits.removeValue(forKey: from)
        if pendingClaudeSessionDraft?.agentKey == agentKey,
           pendingClaudeSessionDraft?.place == .custom(old) {
            pendingClaudeSessionDraft?.place = .custom(new)
        }
    }

    /// Forget the unsent new sessions of `agentKey`'s custom groups that
    /// are gone: a group deleted with one waiting has no + left to reach
    /// it, and the next group given its name must not inherit it. The new
    /// session on screen is left alone — it is the user's, whatever
    /// happens to its group.
    func dropNewSessions(ofGroupsNotIn groups: [String], agentKey: String) {
        let prefix = Self.agentDraftKey(NewSessionPlace.customKeyPrefix(agentKey: agentKey))
        let open = pendingClaudeSessionDraft.map {
            Self.agentDraftKey($0.place.draftKey(agentKey: $0.agentKey))
        }
        func gone(_ key: String) -> Bool {
            key.hasPrefix(prefix) && key != open
                && !groups.contains(String(key.dropFirst(prefix.count)))
        }
        composerDrafts = composerDrafts.filter { !gone($0.key) }
        composerAttachments = composerAttachments.filter { !gone($0.key) }
        composerSchedules = composerSchedules.filter { !gone($0.key) }
        newSessionSkillPicks = newSessionSkillPicks.filter { !gone($0.key) }
        newSessionChipEdits = newSessionChipEdits.filter { !gone($0.key) }
    }
}
