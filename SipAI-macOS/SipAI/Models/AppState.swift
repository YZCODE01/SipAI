// AppState.swift
// Shared, observable UI state for the app.

import Foundation
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
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
    /// NOT `@Published`. Views own the live text and write here only when
    /// the identity changes or the view goes away; publishing every stash
    /// would re-render the whole window for a bookkeeping write. (Same
    /// reasoning as `AgentManager.historyCache`.)
    private var composerDrafts: [String: String] = [:]

    /// Draft key for a chat. An empty slug is the unsent new chat, which
    /// gets its own slot so text typed before the first send survives a
    /// detour too.
    static func chatDraftKey(slug: String?, project: String?) -> String {
        "chat:\(project ?? "")/\(slug ?? "")"
    }

    /// Draft key for an agent transcript. `transcriptKey` is the session
    /// id, or `draft:<uuid>` before the first send reveals one; the
    /// prefix keeps the two id spaces from colliding with chat slugs.
    static func agentDraftKey(_ transcriptKey: String?) -> String {
        "agent:\(transcriptKey ?? "")"
    }

    func composerDraft(for key: String) -> String {
        composerDrafts[key] ?? ""
    }

    /// Files staged in an agent composer's Chat only mode, keyed like
    /// the text and for the same reason: a staged file is the user's
    /// work and must survive a detour. Same store rules — written on
    /// every change, empty removes, not `@Published`.
    private var composerAttachments: [String: [ChatAttachment]] = [:]

    func composerAttachments(for key: String) -> [ChatAttachment] {
        composerAttachments[key] ?? []
    }

    func setComposerAttachments(_ attachments: [ChatAttachment], for key: String) {
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

    /// Forget every unsent message. Only the factory reset calls this:
    /// drafts are deliberately kept through every ordinary navigation,
    /// and they live in RAM alone, so wiping the data directory cannot
    /// reach them. Without this a "reset to first run" hands the very
    /// first composer the user opens a half-written message from the
    /// install they just erased.
    func clearComposerDrafts() {
        composerDrafts.removeAll()
        composerAttachments.removeAll()
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
}
