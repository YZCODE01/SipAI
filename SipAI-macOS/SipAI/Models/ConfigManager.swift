// ConfigManager.swift
// Reads and writes the Mac app's config.json
// (~/Library/Application Support/SipAI/config.json).

import Foundation

/// A loosely-typed wrapper over config.json. We deliberately keep this as
/// raw JSON dictionaries because the schema is open-ended and we want full
/// round-trip preservation of unknown keys.
struct ProviderConfig: Identifiable, Hashable {
    var key: String          // e.g. "openai", "anthropic", or a custom key
    var name: String         // display name
    var baseURL: String
    var apiStyle: String     // "openai" | "openai-responses" | "anthropic"
    var apiKey: String?
    var envVar: String?
    var authHeader: String   // default "Authorization"
    var authPrefix: String   // default "Bearer "
    var id: String { key }
}

struct ModelConfig: Identifiable, Hashable {
    var id: String           // model id (key in config.models)
    var name: String         // display name
    var providerKey: String
    var apiStyle: String?    // optional override
}

struct RoleConfig: Identifiable, Hashable {
    var name: String
    var prompt: String
    var id: String { name }
}

struct ImageModelConfig: Identifiable, Hashable {
    var id: String           // model id, e.g. "dall-e-3", "gpt-image-1"
    var name: String         // display name
    var providerKey: String  // "openai", "google", "xai", ...
}

struct DisplaySettings {
    // Chatbox affordance toggles. Defaults per design: token counters,
    // note buttons (both surfaces) and the note-prompt chooser on, the
    // project/role chips off.
    var showProjectName: Bool = false
    var showRole: Bool = false
    var showNoteChat: Bool = true
    var showNoteAgent: Bool = true
    /// When on, the note button offers "Direct note" / "Add prompt…"
    /// instead of generating immediately.
    var showNotePrompt: Bool = true
    /// Agent sessions only — chat sessions no longer have a counter.
    var showTokenAgent: Bool = true
    /// The sidebar's brand lockup (mark + "SipAI" wordmark). On by
    /// default; off gives the sections column the ~76 pt the lockup
    /// occupies, which matters most on short windows.
    var showSidebarBrand: Bool = true
    var spellCheck: Bool = true
    // This struct models the display keys the app READS; it is not the
    // whole `display` dict. `setDisplay` merges into the stored dict
    // rather than rebuilding it, so a key nothing here knows about is
    // carried through untouched. Do not "clean up" unknown keys on
    // load — one toggle flipped in Settings would then drop a setting
    // this app simply has no opinion about.
    var userLabel: String = DisplaySettings.defaultUserLabel
    var aiLabel: String = DisplaySettings.defaultAILabel
    /// Per-agent custom labels keyed by agent key (e.g. "claude_code").
    /// Empty string or missing key falls back to the agent's default name
    /// supplied by the caller (see `ConfigManager.agentLabel(for:defaultName:)`).
    var agentLabels: [String: String] = [:]
    /// Font size tier raw value (see `FontTier`); malformed values fall
    /// back to `.standard` in `ConfigManager.fontTier`.
    var fontTier: String = FontTier.standard.rawValue
    /// The empty-state hero line next to the logo. Any language, capped
    /// at `taglineCharLimit` grapheme clusters; the empty string never
    /// persists (saving empty restores the default) so the hero always
    /// has something on screen to click and edit.
    var tagline: String = DisplaySettings.defaultTagline

    static let defaultTagline = "My AI, My Way."
    static let taglineCharLimit = 100

    /// LOCALIZED, and computed for the same reason `defaultRoles` is:
    /// this is a word the user reads above their own messages, not a
    /// wire value, and a stored `static let` would resolve before the
    /// bundle's language is the one on screen. It is only ever a
    /// DEFAULT — `user_label` is written to config.json when the user
    /// edits or resets the field, and is that user's data from then on.
    ///
    /// `defaultAILabel` stays "AI": it reads the same in both languages
    /// and is already what a Chinese UI would call it.
    static var defaultUserLabel: String {
        String(localized: "You",
               comment: "Default label shown above the user's own messages")
    }
    static let defaultAILabel = "AI"
    static let labelCharLimit = 25

    /// Every spelling the app itself would produce for the user label:
    /// the source string, plus each shipped localization of it.
    ///
    /// Needed because `user_label` is written on EVERY `setDisplay`
    /// call, so any install that has ever flipped a Display switch,
    /// edited the tagline or opened Labels has the default frozen into
    /// config.json in whatever language was on screen at the time.
    /// Without this, localizing the default would reach only installs
    /// that had never touched Settings — a real config on the author's
    /// machine already carried `"user_label": "You"`.
    ///
    /// A stored value in this set means the user never CHOSE a label, so
    /// it is ignored on load and dropped on save and the localized
    /// default applies again — the same "old configs converge" rule the
    /// retired keys in `setDisplay` follow. Anything else is the user's
    /// own word and is kept exactly as they typed it.
    ///
    /// A `let` is correct despite `defaultUserLabel` being computed:
    /// this enumerates ALL localizations rather than resolving the
    /// current one, so it does not depend on the language in force.
    static let userLabelDefaultSpellings: Set<String> = {
        var out: Set<String> = ["You"]
        for code in Bundle.main.localizations {
            guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { continue }
            out.insert(bundle.localizedString(forKey: "You", value: "You",
                                              table: "Localizable"))
        }
        return out
    }()

    /// True when a stored label is merely some language's default.
    static func userLabelIsDefault(_ value: String) -> Bool {
        userLabelDefaultSpellings.contains(value.trimmingCharacters(in: .whitespaces))
    }
}

@MainActor
final class ConfigManager: ObservableObject {
    @Published private(set) var raw: [String: Any] = [:]

    @Published private(set) var providers: [ProviderConfig] = []
    @Published private(set) var models: [ModelConfig] = []
    @Published private(set) var imageModels: [ImageModelConfig] = []
    @Published private(set) var roles: [RoleConfig] = []
    @Published private(set) var defaultModel: String? = nil
    /// Explicit model choice for note generation (raw `note_model` key).
    /// Views resolve through `noteGeneratingModel`, never this directly.
    @Published private(set) var noteModel: String? = nil
    @Published private(set) var dedicatedFolder: String? = nil
    @Published private(set) var display: DisplaySettings = DisplaySettings()

    /// Agent keys the user has already been notified about.
    @Published private(set) var seenAgents: [String] = []

    /// Appearance override (system / light / dark). Persisted under the
    /// `theme` JSON key; missing or malformed values fall back to
    /// `.system`. Live application happens through `AppState.theme`,
    /// seeded from here on launch.
    @Published private(set) var appTheme: AppTheme = .system

    /// UI language. Persisted under the `language` JSON key; a missing
    /// or malformed value (including the legacy `"system"`) falls back
    /// to whatever the bundle resolved to for this launch.
    ///
    /// This is a RECORD of the choice, not the thing that applies it —
    /// `setLanguage` writes `AppleLanguages`, and the bundle reads that
    /// at the next launch. See `AppLanguage`.
    @Published private(set) var appLanguage: AppLanguage = .effective

    /// True if the user has been through setup at least once (has seen_agents or providers).
    var hasCompletedSetup: Bool {
        !seenAgents.isEmpty || !providers.isEmpty
    }

    /// True if at least one chat model is configured with a resolvable default.
    var hasChatModel: Bool {
        !models.isEmpty && defaultModel != nil
    }

    // MARK: - Loading & saving

    /// Config must be readable before the FIRST body evaluation:
    /// ContentView's onboarding gate and the window min-size both read
    /// it, and an empty `raw` there briefly mounts onboarding on every
    /// launch of a configured install.
    init() {
        reload()
    }

    func reload() {
        raw = Self.loadRaw()
        migrateStaleProviderDefaults()
        rebuildDerived()
    }

    /// Revision of the stale-default table already applied to this
    /// config. BUMP IT whenever an entry is added below, and stamp the
    /// new entry with the bumped number: the flag records what has run,
    /// so an entry added later would never fire on the installs that
    /// already stamped the old value if this stayed a boolean.
    private static let providerDefaultsRevision = 3

    /// Base URLs this app itself once wrote as provider defaults and
    /// has since corrected. Rewritten to the current default ONCE, then
    /// never again — the flag matters because some old URLs (Qwen's
    /// Beijing endpoint) are legitimate REGION choices going forward,
    /// and a later deliberate pick must not be clobbered on every
    /// launch.
    private static let staleDefaultBaseURLs: [String: (old: String, new: String, revision: Int)] = [
        "qwen":        ("https://dashscope.aliyuncs.com/compatible-mode/v1",
                        "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", 1),
        "huggingface": ("https://api-inference.huggingface.co/v1",
                        "https://router.huggingface.co/v1", 1),
        "bedrock":     ("https://bedrock-runtime.us-east-1.amazonaws.com",
                        "https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1", 1),
        "vercel":      ("https://api.vercel.ai/v1",
                        "https://ai-gateway.vercel.sh/v1", 1),
        "xiaomi":      ("https://api.mimo.xiaomi.com/v1",
                        "https://api.xiaomimimo.com/v1", 1),
        "zai":         ("https://api.zai.chat/v1",
                        "https://api.z.ai/api/paas/v4", 1),
        // Moonshot's CN endpoint was this app's default before Moonshot
        // had a region picker, so a stored .cn URL is a default nobody
        // chose — and it 401s every key issued on platform.moonshot.ai.
        // Once-only as ever: a China user who picks .cn back keeps it.
        "moonshot":    ("https://api.moonshot.cn/v1",
                        "https://api.moonshot.ai/v1", 2),
    ]

    /// Providers the catalog MERGED into another — old key → surviving
    /// key, with the revision that folds it. `glm` and `zai` were two
    /// rows for one vendor (open.bigmodel.cn and z.ai), and are now one
    /// provider with those two endpoints as regions.
    private static let mergedProviderKeys: [String: (into: String, revision: Int)] = [
        "glm": (into: "zai", revision: 3),
    ]

    private func migrateStaleProviderDefaults() {
        let flagKey = "provider_defaults_migrated"
        let applied = raw[flagKey] as? Int ?? 0
        if applied >= Self.providerDefaultsRevision { return }
        raw[flagKey] = Self.providerDefaultsRevision
        var providers = (raw["providers"] as? [String: [String: Any]]) ?? [:]
        var models = (raw["models"] as? [String: [String: Any]]) ?? [:]
        var changed = false
        var modelsChanged = false
        for (key, urls) in Self.staleDefaultBaseURLs where urls.revision > applied {
            guard var entry = providers[key],
                  (entry["base_url"] as? String) == urls.old else { continue }
            entry["base_url"] = urls.new
            providers[key] = entry
            changed = true
        }
        // Fold a merged provider's entry onto the surviving key, models
        // included — the base URL travels UNTOUCHED, because the old
        // provider's endpoint is precisely one of the new one's regions.
        //
        // If BOTH keys are configured the fold is skipped entirely:
        // that is two real accounts with two real keys, and merging them
        // would silently throw one away. The old entry then just stops
        // being offered in the provider list while its stored key, its
        // name and its models keep working — the read side
        // (`builtInProviders`) still knows every retired key.
        for (old, merge) in Self.mergedProviderKeys where merge.revision > applied {
            guard var entry = providers[old], providers[merge.into] == nil else { continue }
            // The NAME follows the catalog, or the quick-add row keeps
            // offering "Add more models from GLM Models" for a provider
            // every other surface now calls Z.AI (GLM).
            if let merged = BuiltinProviderCatalog.find(merge.into) {
                entry["name"] = merged.name
            }
            providers[merge.into] = entry
            providers.removeValue(forKey: old)
            changed = true
            for (id, var m) in models where (m["provider"] as? String) == old {
                m["provider"] = merge.into
                models[id] = m
                modelsChanged = true
            }
        }
        if changed { raw["providers"] = providers }
        if modelsChanged { raw["models"] = models }
        saveRaw()
    }

    private static func loadRaw() -> [String: Any] {
        guard let data = try? Data(contentsOf: SipaiPaths.configFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private func saveRaw() {
        SipaiPaths.ensureDataDir()
        guard let data = try? JSONSerialization.data(
                withJSONObject: raw,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        try? data.write(to: SipaiPaths.configFile, options: .atomic)
        // config.json holds API keys. ~/Library is already 0700, but an
        // atomic write creates the file at the umask default (0644) —
        // tighten to owner-only as defense in depth.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: SipaiPaths.configFile.path)
    }

    private func rebuildDerived() {
        defaultModel = raw["default_model"] as? String
        noteModel = raw["note_model"] as? String
        dedicatedFolder = raw["dedicated_folder"] as? String

        providers = (raw["providers"] as? [String: [String: Any]] ?? [:]).map { (key, dict) in
            ProviderConfig(
                key: key,
                name: dict["name"] as? String ?? key.capitalized,
                baseURL: dict["base_url"] as? String ?? Self.builtInBaseURL(for: key) ?? "",
                apiStyle: dict["api_style"] as? String ?? Self.builtInApiStyle(for: key) ?? "openai",
                apiKey: dict["api_key"] as? String,
                envVar: dict["env_var"] as? String ?? Self.builtInEnvVar(for: key),
                authHeader: dict["auth_header"] as? String ?? Self.builtInAuthHeader(for: key) ?? "Authorization",
                authPrefix: dict["auth_prefix"] as? String ?? Self.builtInAuthPrefix(for: key) ?? "Bearer "
            )
        }.sorted { $0.name < $1.name }

        models = (raw["models"] as? [String: [String: Any]] ?? [:]).map { (id, dict) in
            ModelConfig(
                id: id,
                name: dict["name"] as? String ?? id,
                providerKey: dict["provider"] as? String ?? "",
                apiStyle: dict["api_style"] as? String
            )
        }.sorted { $0.name < $1.name }

        imageModels = (raw["image_models"] as? [String: [String: Any]] ?? [:]).map { (id, dict) in
            ImageModelConfig(
                id: id,
                name: dict["name"] as? String ?? id,
                providerKey: dict["provider"] as? String ?? ""
            )
        }.sorted { $0.name < $1.name }

        if let arr = raw["roles"] as? [[String: Any]] {
            roles = arr.compactMap {
                guard let n = $0["name"] as? String, let p = $0["prompt"] as? String else { return nil }
                return RoleConfig(name: n, prompt: p)
            }
        } else {
            // No "roles" key at all = fresh install → the built-in
            // starter role. The first save — even of an empty list —
            // writes the key and takes over.
            roles = Self.defaultRoles
        }

        let d = raw["display"] as? [String: Any] ?? [:]
        var s = DisplaySettings()
        s.showProjectName = d["projn"] as? Bool ?? false
        s.showRole = d["role_disp"] as? Bool ?? false
        // The legacy one-switch-per-feature keys ("note_disp" /
        // "token_disp") seed both per-surface values once, then the
        // split keys take over.
        let legacyNote = d["note_disp"] as? Bool
        let legacyToken = d["token_disp"] as? Bool
        s.showNoteChat = d["note_chat"] as? Bool ?? legacyNote ?? true
        s.showNoteAgent = d["note_agent"] as? Bool ?? legacyNote ?? true
        s.showNotePrompt = d["note_prompt"] as? Bool ?? true
        s.showTokenAgent = d["token_agent"] as? Bool ?? legacyToken ?? true
        s.showSidebarBrand = d["sidebar_brand"] as? Bool ?? true
        s.spellCheck = d["spell_check"] as? Bool ?? true
        // A stored value that is only some language's default is not a
        // choice — leave `userLabel` on the localized default.
        if let ul = (d["user_label"] as? String)?.trimmingCharacters(in: .whitespaces),
           !ul.isEmpty, !DisplaySettings.userLabelIsDefault(ul) {
            s.userLabel = ul
        }
        if let al = (d["ai_label"] as? String)?.trimmingCharacters(in: .whitespaces), !al.isEmpty {
            s.aiLabel = al
        }
        s.agentLabels = (d["agent_labels"] as? [String: String]) ?? [:]
        s.fontTier = (d["font_tier"] as? String) ?? FontTier.standard.rawValue
        if let tl = d["tagline"] as? String,
           !tl.trimmingCharacters(in: .whitespaces).isEmpty {
            // Re-clamp on load — the file is hand-editable.
            s.tagline = String(tl.prefix(DisplaySettings.taglineCharLimit))
        }
        display = s

        seenAgents = (raw["seen_agents"] as? [String]) ?? []

        if let s = raw["theme"] as? String, let t = AppTheme(rawValue: s) {
            appTheme = t
        } else {
            appTheme = .system
        }

        // A missing key is a first run, and the legacy "system" value is
        // an install from before the picker had real languages. Both
        // adopt whatever the bundle resolved to for THIS launch — which
        // on an untouched install is the user's own Mac language. That
        // is the whole of "default to the system language": macOS has
        // already made the choice, we only record it.
        //
        // No `AppleLanguages` write here. Seeding must not turn an
        // inherited default into an explicit override, or a user who
        // later switches macOS to Chinese would stay pinned to English
        // by a decision they never made.
        if let s = raw["language"] as? String, let l = AppLanguage(rawValue: s) {
            appLanguage = l
        } else {
            appLanguage = .effective
        }
    }

    // MARK: - Mutations

    func setDefaultModel(_ id: String) {
        raw["default_model"] = id
        saveRaw(); rebuildDerived()
    }

    /// Persist the note-generation model. nil clears the explicit choice
    /// (notes fall back to the default chat model).
    func setNoteModel(_ id: String?) {
        if let id, !id.isEmpty {
            raw["note_model"] = id
        } else {
            raw.removeValue(forKey: "note_model")
        }
        saveRaw(); rebuildDerived()
    }

    /// The model notes are generated with: the explicit choice while it
    /// still exists in `models`, else the default chat model.
    var noteGeneratingModel: String? {
        if let id = noteModel, model(for: id) != nil { return id }
        return defaultModel
    }

    func setDisplay(_ block: (inout DisplaySettings) -> Void) {
        var s = display
        block(&s)
        var d = (raw["display"] as? [String: Any]) ?? [:]
        // Retired command-hint toggles — drop stale keys so old
        // configs converge instead of carrying them forever.
        d.removeValue(forKey: "coml")
        d.removeValue(forKey: "comh")
        d["projn"] = s.showProjectName
        d["role_disp"] = s.showRole
        d.removeValue(forKey: "note_disp")
        d.removeValue(forKey: "token_disp")
        // Retired with the chat token counter — drop the key so old
        // configs converge instead of carrying it forever.
        d.removeValue(forKey: "token_chat")
        d["note_chat"] = s.showNoteChat
        d["note_agent"] = s.showNoteAgent
        d["note_prompt"] = s.showNotePrompt
        d["token_agent"] = s.showTokenAgent
        d["sidebar_brand"] = s.showSidebarBrand
        d["spell_check"] = s.spellCheck
        // `d` starts from the stored dict, so any key this app does not
        // model passes through this save untouched — which is the point.
        // Written only when the user actually picked a word. Writing the
        // default would freeze one language's spelling into a file the
        // CLI shares — and the CLI falls back to "You" on a missing key,
        // which is what it already shows on a fresh install.
        if DisplaySettings.userLabelIsDefault(s.userLabel) {
            d.removeValue(forKey: "user_label")
        } else {
            d["user_label"] = s.userLabel
        }
        d["ai_label"] = s.aiLabel
        d["agent_labels"] = s.agentLabels
        d["font_tier"] = s.fontTier
        d["tagline"] = s.tagline
        raw["display"] = d
        saveRaw(); rebuildDerived()
    }

    /// The configured font tier, defaulting to `.standard` for missing
    /// or malformed stored values.
    var fontTier: FontTier {
        FontTier(rawValue: display.fontTier) ?? .standard
    }

    /// Returns the user-customised label for an agent (e.g. `"claude_code"`),
    /// or the supplied `defaultName` if none is set or the stored value is
    /// blank after trimming.
    func agentLabel(for agentKey: String, defaultName: String) -> String {
        let stored = display.agentLabels[agentKey]?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return stored.isEmpty ? defaultName : stored
    }

    /// Persist a custom agent label. Pass an empty string (after trimming)
    /// to clear the customisation — subsequent `agentLabel(for:defaultName:)`
    /// calls fall back to the supplied default.
    func setAgentLabel(_ label: String, for agentKey: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        var d = (raw["display"] as? [String: Any]) ?? [:]
        var m = (d["agent_labels"] as? [String: String]) ?? [:]
        if trimmed.isEmpty {
            m.removeValue(forKey: agentKey)
        } else {
            m[agentKey] = trimmed
        }
        d["agent_labels"] = m
        raw["display"] = d
        saveRaw(); rebuildDerived()
    }

    func setDedicatedFolder(_ path: String?) {
        if let p = path { raw["dedicated_folder"] = p } else { raw.removeValue(forKey: "dedicated_folder") }
        saveRaw(); rebuildDerived()
    }

    func upsertModel(id: String, name: String, providerKey: String, apiStyle: String?) {
        var m = (raw["models"] as? [String: [String: Any]]) ?? [:]
        var entry: [String: Any] = ["provider": providerKey, "name": name]
        if let s = apiStyle { entry["api_style"] = s }
        m[id] = entry
        raw["models"] = m
        if defaultModel == nil { raw["default_model"] = id }
        saveRaw(); rebuildDerived()
    }

    func removeModel(id: String) {
        var m = (raw["models"] as? [String: [String: Any]]) ?? [:]
        m.removeValue(forKey: id)
        raw["models"] = m
        if defaultModel == id {
            // Deleting the last model must DROP the key — a wrapped nil
            // is not valid JSON and would silently abort the whole save.
            if let next = m.keys.sorted().first {
                raw["default_model"] = next
            } else {
                raw.removeValue(forKey: "default_model")
            }
        }
        saveRaw(); rebuildDerived()
    }

    func upsertProvider(_ p: ProviderConfig) {
        var prov = (raw["providers"] as? [String: [String: Any]]) ?? [:]
        var entry: [String: Any] = [
            "name": p.name,
            "base_url": p.baseURL,
            "api_style": p.apiStyle,
            "auth_header": p.authHeader,
            "auth_prefix": p.authPrefix,
        ]
        if let k = p.apiKey, !k.isEmpty { entry["api_key"] = k }
        if let e = p.envVar, !e.isEmpty { entry["env_var"] = e }
        prov[p.key] = entry
        raw["providers"] = prov
        saveRaw(); rebuildDerived()
    }

    func removeProvider(key: String) {
        var prov = (raw["providers"] as? [String: [String: Any]]) ?? [:]
        prov.removeValue(forKey: key)
        raw["providers"] = prov
        saveRaw(); rebuildDerived()
    }

    func upsertImageModel(id: String, name: String, providerKey: String) {
        var m = (raw["image_models"] as? [String: [String: Any]]) ?? [:]
        m[id] = ["name": name, "provider": providerKey]
        raw["image_models"] = m
        if raw["default_image_model"] == nil { raw["default_image_model"] = id }
        saveRaw(); rebuildDerived()
    }

    func removeImageModel(id: String) {
        var m = (raw["image_models"] as? [String: [String: Any]]) ?? [:]
        m.removeValue(forKey: id)
        raw["image_models"] = m
        if (raw["default_image_model"] as? String) == id {
            // Deleting the last image model must DROP the key — a wrapped
            // nil bridges to NSNull, so a persisted null makes
            // `upsertImageModel`'s `== nil` check fail and later-added
            // models never auto-promote to default.
            if let next = m.keys.sorted().first {
                raw["default_image_model"] = next
            } else {
                raw.removeValue(forKey: "default_image_model")
            }
        }
        saveRaw(); rebuildDerived()
    }

    func setRoles(_ list: [RoleConfig]) {
        raw["roles"] = list.map { ["name": $0.name, "prompt": $0.prompt] }
        saveRaw(); rebuildDerived()
    }

    /// The built-in starter role. Surfaced whenever config.json has no
    /// "roles" key; never written to disk until the user saves.
    ///
    /// ONE role, deliberately: a single worked example says what a role
    /// is, and "Add Role" is right there.
    ///
    /// LOCALIZED, and computed rather than stored for that reason: this
    /// is example copy the user reads and edits, not a wire value, so a
    /// Chinese install must not open on an English prompt. The name is
    /// `RoleConfig.id`, so once the user saves, the localized name IS
    /// the identity — it is user data from that point and never
    /// re-resolves. A `static let` would freeze the resolution at first
    /// touch, which is before the pane that shows it exists.
    static var defaultRoles: [RoleConfig] {
        [
            RoleConfig(
                name: String(localized: "Code Reviewer",
                             comment: "Name of the built-in starter role shipped on a fresh install"),
                prompt: String(localized: "You are a senior code reviewer. When the user shares code, analyze it for: bugs and logic errors, security vulnerabilities, performance issues, readability and style. Be specific — reference line numbers when possible. Suggest concrete fixes. If the code is good, say so briefly. If no code is shared, ask for it.",
                               comment: "System prompt of the built-in starter role shipped on a fresh install")),
        ]
    }

    /// Persist the appearance override. No-op when unchanged to avoid a
    /// round-trip write on every launch.
    func setTheme(_ theme: AppTheme) {
        guard appTheme != theme else { return }
        appTheme = theme
        raw["theme"] = theme.rawValue
        saveRaw()
    }

    /// Persist the language choice AND arm it for the next launch.
    ///
    /// Two writes, deliberately: `config.json` is what the picker reads
    /// back, and `AppleLanguages` in our own UserDefaults domain is what
    /// the BUNDLE reads when it resolves localizations at launch. This
    /// is the same key System Settings → General → Language & Region →
    /// Applications writes, so the two controls agree instead of
    /// fighting. Nothing takes effect until the app restarts —
    /// `LanguagePane` is what tells the user so.
    ///
    /// No-op when unchanged, to avoid a round-trip write on every
    /// launch.
    func setLanguage(_ language: AppLanguage) {
        guard appLanguage != language else { return }
        appLanguage = language
        raw["language"] = language.rawValue
        saveRaw()
        UserDefaults.standard.set([language.localizationCode],
                                  forKey: "AppleLanguages")
    }

    func addSeenAgents(_ keys: [String]) {
        var seen = (raw["seen_agents"] as? [String]) ?? []
        for k in keys where !seen.contains(k) {
            seen.append(k)
        }
        raw["seen_agents"] = seen
        saveRaw(); rebuildDerived()
    }

    // MARK: - Per-agent state (last cwd, custom session names)

    /// Retrieve the most recently used working directory for an agent
    /// (e.g. `"claude_code"`). Returns the absolute path with tilde
    /// expansion already applied; nil if never set.
    func agentLastCwd(for agentKey: String) -> String? {
        let agents = (raw["agents"] as? [String: [String: Any]]) ?? [:]
        guard let entry = agents[agentKey],
              let path = entry["last_cwd"] as? String,
              !path.isEmpty
        else { return nil }
        return (path as NSString).expandingTildeInPath
    }

    /// Persist the most recently used working directory for an agent.
    /// Stored with `~` abbreviation if under home so config.json stays
    /// portable.
    func setAgentLastCwd(_ url: URL, for agentKey: String) {
        var agents = (raw["agents"] as? [String: [String: Any]]) ?? [:]
        var entry = agents[agentKey] ?? [:]
        entry["last_cwd"] = (url.path as NSString).abbreviatingWithTildeInPath
        agents[agentKey] = entry
        raw["agents"] = agents
        saveRaw(); rebuildDerived()
    }

    /// Last-used launch options (permission mode / model / effort) for
    /// an agent's composer. Seeds every new composer; nil fields mean
    /// "claude's default" and emit no flag.
    func agentLaunchOptions(for agentKey: String) -> AgentLaunchOptions {
        let agents = (raw["agents"] as? [String: [String: Any]]) ?? [:]
        guard let prefs = agents[agentKey]?["launch_prefs"] as? [String: String] else {
            return AgentLaunchOptions()
        }
        func field(_ key: String) -> String? {
            let v = prefs[key]?.trimmingCharacters(in: .whitespaces)
            return (v?.isEmpty == false) ? v : nil
        }
        return AgentLaunchOptions(
            permissionMode: field("mode"),
            model: field("model"),
            effort: field("effort")
        )
    }

    /// Persist the composer's launch options so the next session starts
    /// from the same choices. Nil fields are stored as absent keys.
    func setAgentLaunchOptions(_ options: AgentLaunchOptions, for agentKey: String) {
        var agents = (raw["agents"] as? [String: [String: Any]]) ?? [:]
        var entry = agents[agentKey] ?? [:]
        var prefs: [String: String] = [:]
        if let mode = options.permissionMode, !mode.isEmpty { prefs["mode"] = mode }
        if let model = options.model, !model.isEmpty { prefs["model"] = model }
        if let effort = options.effort, !effort.isEmpty { prefs["effort"] = effort }
        entry["launch_prefs"] = prefs
        agents[agentKey] = entry
        raw["agents"] = agents
        saveRaw(); rebuildDerived()
    }

    /// Look up a user-set display name for a Claude Code session by id.
    /// Returns nil when the session has never been renamed; callers fall
    /// back to the JSONL-derived title.
    func agentSessionDisplayName(for sessionId: String) -> String? {
        let map = (raw["agent_session_names"] as? [String: String]) ?? [:]
        let v = map[sessionId]?.trimmingCharacters(in: .whitespaces)
        return (v?.isEmpty == false) ? v : nil
    }

    /// Persist (or clear) a custom display name for a session.
    /// Pass nil or empty string to clear.
    func setAgentSessionDisplayName(_ name: String?, for sessionId: String) {
        var map = (raw["agent_session_names"] as? [String: String]) ?? [:]
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            map.removeValue(forKey: sessionId)
        } else {
            map[sessionId] = trimmed
        }
        raw["agent_session_names"] = map
        saveRaw(); rebuildDerived()
    }

    // MARK: - Session branches

    /// Where a branched session came from: the session it was forked out
    /// of, and the transcript record the fork was cut at.
    ///
    /// Kept in OUR config rather than in the branch's transcript,
    /// because the transcript belongs to Claude Code — writing a SipAI
    /// marker record into a file three other clients read is not ours to
    /// do. The consequence is that lineage is per-machine and disappears
    /// if the config is reset; the branch itself is a perfectly ordinary
    /// session either way, which is the point.
    func agentSessionBranchSource(for sessionId: String)
    -> (sourceId: String, recordUuid: String)? {
        guard !sessionId.isEmpty else { return nil }
        let map = (raw["agent_session_branches"] as? [String: [String: String]]) ?? [:]
        guard let entry = map[sessionId],
              let from = entry["from"], !from.isEmpty else { return nil }
        return (sourceId: from, recordUuid: entry["at"] ?? "")
    }

    /// Record that `sessionId` is a branch of `source`, cut at
    /// `recordUuid`.
    func setAgentSessionBranch(source: String, recordUuid: String,
                               for sessionId: String) {
        guard !sessionId.isEmpty, !source.isEmpty else { return }
        var map = (raw["agent_session_branches"] as? [String: [String: String]]) ?? [:]
        map[sessionId] = ["from": source, "at": recordUuid]
        raw["agent_session_branches"] = map
        saveRaw(); rebuildDerived()
    }

    // MARK: - Per-session launch options (the composer's explicit picks)

    /// The user's explicit composer picks (mode / model / effort) for
    /// one session, or nil when they never touched the chips there.
    /// Explicit picks outlive session switches: reopening seeds from
    /// here first and falls back to the transcript's newest recorded
    /// values only when the user never chose. Without this, an EXTERNAL
    /// writer (the same session driven from a terminal) records ITS
    /// mode in the transcript and the reopen re-derive silently flipped
    /// the user's "Auto" chip to "Manual".
    func agentSessionLaunchOptions(for sessionId: String) -> AgentLaunchOptions? {
        guard !sessionId.isEmpty else { return nil }
        let map = (raw["agent_session_launch_prefs"] as? [String: [String: String]]) ?? [:]
        guard let prefs = map[sessionId] else { return nil }
        func field(_ key: String) -> String? {
            let v = prefs[key]?.trimmingCharacters(in: .whitespaces)
            return (v?.isEmpty == false) ? v : nil
        }
        return AgentLaunchOptions(
            permissionMode: field("mode"),
            model: field("model"),
            effort: field("effort"),
            modelFullId: field("model_full_id")
        )
    }

    /// Persist the composer's launch options against a session id.
    /// `model_full_id` rides along for display continuity (the chip's
    /// versioned name); it is still never emitted as a flag.
    func setAgentSessionLaunchOptions(_ options: AgentLaunchOptions,
                                      for sessionId: String) {
        guard !sessionId.isEmpty else { return }
        var map = (raw["agent_session_launch_prefs"] as? [String: [String: String]]) ?? [:]
        var prefs: [String: String] = [:]
        if let mode = options.permissionMode, !mode.isEmpty { prefs["mode"] = mode }
        if let model = options.model, !model.isEmpty { prefs["model"] = model }
        if let effort = options.effort, !effort.isEmpty { prefs["effort"] = effort }
        if let fullId = options.modelFullId, !fullId.isEmpty {
            prefs["model_full_id"] = fullId
        }
        map[sessionId] = prefs
        raw["agent_session_launch_prefs"] = map
        saveRaw(); rebuildDerived()
    }

    // MARK: - Agent session grouping
    //
    // Four JSON keys:
    //   agent_group_mode      {agent_key: mode}
    //   agent_custom_groups   {agent_key: [names, in display order]}
    //   agent_session_groups  {item_key: group_name}   — item_key is a
    //                         session id, or "sched:<task name>"
    //   agent_group_collapsed {agent_key: {mode: [folded group keys]}}
    //
    // All four live in this app's own config.json, never in the agent's
    // session files: naming a group is our concept, not theirs.

    func agentGroupMode(for agentKey: String) -> AgentGroupMode {
        guard !agentKey.isEmpty else { return .none }
        let map = (raw["agent_group_mode"] as? [String: String]) ?? [:]
        return AgentGroupMode(rawValue: map[agentKey] ?? "") ?? .none
    }

    func setAgentGroupMode(_ mode: AgentGroupMode, for agentKey: String) {
        guard !agentKey.isEmpty else { return }
        var map = (raw["agent_group_mode"] as? [String: String]) ?? [:]
        map[agentKey] = mode.rawValue
        raw["agent_group_mode"] = map
        saveRaw(); rebuildDerived()
    }

    /// The user's own group names, in the order they created them.
    func agentCustomGroups(for agentKey: String) -> [String] {
        guard !agentKey.isEmpty else { return [] }
        let map = (raw["agent_custom_groups"] as? [String: [String]]) ?? [:]
        return (map[agentKey] ?? []).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Create a group and return the stored name. A case-insensitive match
    /// returns the existing name instead of creating a near-duplicate, so
    /// "work" typed twice cannot become two buckets.
    @discardableResult
    func addAgentCustomGroup(_ name: String, for agentKey: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !agentKey.isEmpty, !trimmed.isEmpty else { return nil }
        var groups = agentCustomGroups(for: agentKey)
        if let existing = groups.first(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return existing
        }
        groups.append(trimmed)
        var map = (raw["agent_custom_groups"] as? [String: [String]]) ?? [:]
        map[agentKey] = groups
        raw["agent_custom_groups"] = map
        saveRaw(); rebuildDerived()
        return trimmed
    }

    /// Rename in place — display order, every assignment, and the folded
    /// state all follow the group to its new name.
    @discardableResult
    func renameAgentCustomGroup(_ old: String,
                                to new: String,
                                for agentKey: String) -> Bool {
        let trimmed = new.trimmingCharacters(in: .whitespaces)
        guard !agentKey.isEmpty, !trimmed.isEmpty else { return false }
        let groups = agentCustomGroups(for: agentKey)
        guard groups.contains(old) else { return false }
        if trimmed != old, groups.contains(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return false
        }
        var groupMap = (raw["agent_custom_groups"] as? [String: [String]]) ?? [:]
        groupMap[agentKey] = groups.map { $0 == old ? trimmed : $0 }
        raw["agent_custom_groups"] = groupMap

        var assignments = (raw["agent_session_groups"] as? [String: String]) ?? [:]
        for (key, value) in assignments where value == old {
            assignments[key] = trimmed
        }
        raw["agent_session_groups"] = assignments

        var collapsed = (raw["agent_group_collapsed"] as? [String: [String: [String]]]) ?? [:]
        if var perAgent = collapsed[agentKey], let folded = perAgent["custom"] {
            perAgent["custom"] = folded.map { $0 == old ? trimmed : $0 }
            collapsed[agentKey] = perAgent
            raw["agent_group_collapsed"] = collapsed
        }
        saveRaw(); rebuildDerived()
        return true
    }

    /// Drop a group. Its members become Ungrouped — no session is touched.
    func deleteAgentCustomGroup(_ name: String, for agentKey: String) {
        guard !agentKey.isEmpty else { return }
        var groupMap = (raw["agent_custom_groups"] as? [String: [String]]) ?? [:]
        groupMap[agentKey] = agentCustomGroups(for: agentKey).filter { $0 != name }
        raw["agent_custom_groups"] = groupMap
        var assignments = (raw["agent_session_groups"] as? [String: String]) ?? [:]
        for (key, value) in assignments where value == name {
            assignments.removeValue(forKey: key)
        }
        raw["agent_session_groups"] = assignments
        saveRaw(); rebuildDerived()
    }

    /// Every custom-group assignment, keyed by `AgentListItem.groupItemKey`.
    var agentSessionGroupAssignments: [String: String] {
        (raw["agent_session_groups"] as? [String: String]) ?? [:]
    }

    func agentSessionGroup(for itemKey: String) -> String? {
        guard !itemKey.isEmpty else { return nil }
        return agentSessionGroupAssignments[itemKey]
    }

    /// File an item into a group. Pass nil to un-file it.
    func setAgentSessionGroup(_ name: String?, for itemKey: String) {
        guard !itemKey.isEmpty else { return }
        var map = agentSessionGroupAssignments
        if let name = name, !name.isEmpty {
            map[itemKey] = name
        } else {
            map.removeValue(forKey: itemKey)
        }
        raw["agent_session_groups"] = map
        saveRaw(); rebuildDerived()
    }

    /// Last full model id each picker alias RESOLVED to on this machine
    /// ("opus" → "claude-opus-5"), observed from our own runners'
    /// system.init events — never hand-maintained, per the repo rule
    /// that model lists are scraped, not tabled (a hardcoded
    /// alias→version map would drift the day a new model ships).
    /// Key "" records what claude's DEFAULT model resolved to.
    /// Display-only: feeds the composer's versioned model names.
    func agentModelFullId(forAlias alias: String) -> String? {
        let map = (raw["agent_model_full_ids"] as? [String: String]) ?? [:]
        return map[alias]
    }

    /// Display name for a picker alias, carrying the version the alias
    /// resolves to on THIS machine ("opus" → "Opus 5"). A bare alias
    /// carries no version of its own, so `ClaudeModelDisplay.name` alone
    /// can only ever answer "Opus" — the version has to come from the
    /// observed id map.
    ///
    /// Lives here, not on a view, because more than one surface shows a
    /// model name for a stored alias (the composer's chip and rows, the
    /// scheduled-task panel's "Runs as"), and two copies of this rule
    /// would drift — the panel and the composer naming the same task's
    /// model differently.
    func rememberedModelName(forAlias alias: String) -> String {
        if let full = agentModelFullId(forAlias: alias), !full.isEmpty {
            return ClaudeModelDisplay.name(for: full)
        }
        // A variant alias ("opus[1m]") shares its family's version; the
        // learned map is keyed by the plain family word.
        let (base, variant) = ClaudeModelDisplay.splitVariant(alias)
        if !variant.isEmpty,
           let full = agentModelFullId(forAlias: base), !full.isEmpty {
            return ClaudeModelDisplay.name(for: full + variant)
        }
        return ClaudeModelDisplay.name(for: alias)
    }

    func setAgentModelFullId(_ fullId: String, forAlias alias: String) {
        guard !fullId.isEmpty else { return }
        var map = (raw["agent_model_full_ids"] as? [String: String]) ?? [:]
        guard map[alias] != fullId else { return }
        map[alias] = fullId
        raw["agent_model_full_ids"] = map
        saveRaw()
    }

    /// Merge HARVESTED alias→id pairs (`ClaudeModelCatalog`), writing an
    /// alias only when it has no id yet or the harvested one names a
    /// strictly newer version. An alias means "latest model of that
    /// family", so a newer sighting anywhere on this machine supersedes
    /// an older learned one — that is what un-sticks a row left on a
    /// stale version ("Opus 4.8") after the alias itself moved on.
    /// Live system.init observations keep overwriting unconditionally
    /// (`setAgentModelFullId`): they are ground truth for what the alias
    /// resolved to on the run that just happened. One save for the whole
    /// merge — this runs at launch, alongside everything else starting up.
    func learnAgentModelFullIds(_ harvested: [String: String]) {
        var map = (raw["agent_model_full_ids"] as? [String: String]) ?? [:]
        var changed = false
        for (alias, fullId) in harvested where !alias.isEmpty && !fullId.isEmpty {
            if let known = map[alias], !known.isEmpty,
               !Self.preferHarvested(fullId, over: known) { continue }
            guard map[alias] != fullId else { continue }
            map[alias] = fullId
            changed = true
        }
        guard changed else { return }
        raw["agent_model_full_ids"] = map
        saveRaw()
    }

    /// Whether a freshly harvested id should replace the one on record
    /// for an alias.
    ///
    /// Upgrade-only by version, because an alias means the LATEST model
    /// of its family. The tie-break exists because version alone does
    /// not order every pair: `claude-opus-5` and `claude-opus-5[1m]`
    /// are the same model and compare EQUAL (`isNewer` reads digits,
    /// and a variant is not one), yet a normal machine records both
    /// spellings. Without a rule, whichever spelling the harvest
    /// reached first would stick forever — the id behind an alias
    /// settled by scan order. Prefer the unadorned spelling.
    ///
    /// This orders the HARVEST only. A live `system.init` still
    /// overwrites unconditionally (`setAgentModelFullId`): that is
    /// ground truth for the run that just happened, variant included.
    private static func preferHarvested(_ fresh: String, over known: String) -> Bool {
        if ClaudeModelDisplay.isNewer(fresh, than: known) { return true }
        if ClaudeModelDisplay.isNewer(known, than: fresh) { return false }
        return ClaudeModelDisplay.splitVariant(fresh).variant.isEmpty
            && !ClaudeModelDisplay.splitVariant(known).variant.isEmpty
    }

    /// Group keys the user has folded away. Stored per mode: folding a
    /// folder away must not also fold "Today" away in date mode.
    func agentCollapsedGroups(for agentKey: String,
                              mode: AgentGroupMode) -> Set<String> {
        guard !agentKey.isEmpty else { return [] }
        let all = (raw["agent_group_collapsed"] as? [String: [String: [String]]]) ?? [:]
        return Set(all[agentKey]?[mode.rawValue] ?? [])
    }

    func setAgentGroupCollapsed(_ collapsed: Bool,
                                group key: String,
                                for agentKey: String,
                                mode: AgentGroupMode) {
        guard !agentKey.isEmpty, !key.isEmpty else { return }
        var all = (raw["agent_group_collapsed"] as? [String: [String: [String]]]) ?? [:]
        var perAgent = all[agentKey] ?? [:]
        var folded = perAgent[mode.rawValue] ?? []
        if collapsed {
            guard !folded.contains(key) else { return }
            folded.append(key)
        } else {
            folded.removeAll { $0 == key }
        }
        perAgent[mode.rawValue] = folded
        all[agentKey] = perAgent
        raw["agent_group_collapsed"] = all
        saveRaw(); rebuildDerived()
    }

    // MARK: - Sidebar drag ordering

    /// Persisted orders for the three drag-to-reorder surfaces (see
    /// `SidebarOrdering`). Each stores ids in display order; resolution
    /// against what actually exists happens at render time, so a stale
    /// id is harmless and a new item simply appends.

    var sidebarSectionOrder: [String] {
        (raw["sidebar_section_order"] as? [String]) ?? []
    }

    func setSidebarSectionOrder(_ order: [String]) {
        raw["sidebar_section_order"] = order
        saveRaw()
    }

    var chatGroupOrder: [String] {
        (raw["chat_group_order"] as? [String]) ?? []
    }

    func setChatGroupOrder(_ order: [String]) {
        raw["chat_group_order"] = order
        saveRaw()
    }

    /// Per agent, PER MODE — the same sessions bucket into different
    /// groups under Folder / State / Custom, so one shared order would
    /// scramble whichever mode the drag didn't happen in.
    func agentGroupOrder(for agentKey: String,
                         mode: AgentGroupMode) -> [String] {
        guard !agentKey.isEmpty else { return [] }
        let all = (raw["agent_group_order"] as? [String: [String: [String]]]) ?? [:]
        return all[agentKey]?[mode.rawValue] ?? []
    }

    func setAgentGroupOrder(_ order: [String],
                            for agentKey: String,
                            mode: AgentGroupMode) {
        guard !agentKey.isEmpty else { return }
        var all = (raw["agent_group_order"] as? [String: [String: [String]]]) ?? [:]
        var perAgent = all[agentKey] ?? [:]
        perAgent[mode.rawValue] = order
        all[agentKey] = perAgent
        raw["agent_group_order"] = all
        saveRaw()
    }

    // MARK: - System prompt helpers

    func loadGeneralSystemPrompt() -> String {
        (try? String(contentsOf: SipaiPaths.generalSystemPromptFile, encoding: .utf8)) ?? ""
    }

    func saveGeneralSystemPrompt(_ text: String) {
        SipaiPaths.ensureDataDir()
        try? text.write(to: SipaiPaths.generalSystemPromptFile, atomically: true, encoding: .utf8)
    }

    // MARK: - API key resolution

    /// Returns an API key for a provider — env var first, then stored key.
    /// Env vars resolve through ShellEnvironment, so exports living in
    /// ~/.zshrc work the way they do in a terminal even though a
    /// Dock-launched app never inherits them.
    func apiKey(for providerKey: String) -> String? {
        if let p = providers.first(where: { $0.key == providerKey }) {
            if let env = p.envVar, let v = ShellEnvironment.resolve(env) {
                return v
            }
            return p.apiKey
        }
        // Fallback: built-in env vars even if the provider isn't in config yet.
        if let env = Self.builtInEnvVar(for: providerKey),
           let v = ShellEnvironment.resolve(env) {
            return v
        }
        return nil
    }

    func provider(for key: String) -> ProviderConfig? {
        providers.first { $0.key == key }
    }

    func model(for id: String) -> ModelConfig? {
        models.first { $0.id == id }
    }

    // MARK: - Built-in provider defaults (read side)

    /// Fills in fields an existing config entry does not carry, and
    /// fabricates a provider for a model whose provider was never
    /// written (`APIClient.fallbackProvider`).
    ///
    /// Deliberately a SUPERSET of `BuiltinProviderCatalog`, which is the
    /// offer side: the six local servers, `github`, `glm`, `openrouter`,
    /// `bedrock` and `cloudflare` are no longer offered, but an install
    /// that configured one before still has models pointing at it, and
    /// dropping the key here would strip those entries of their name,
    /// endpoint and auth on the next load. Retiring a provider must
    /// never break the chats it already serves.
    static let builtInProviders: [String: (name: String, baseURL: String, apiStyle: String, env: String, authHeader: String, authPrefix: String)] = [
        "openai":     ("OpenAI",            "https://api.openai.com/v1",                               "openai",    "OPENAI_API_KEY",    "Authorization", "Bearer "),
        "anthropic":  ("Anthropic",         "https://api.anthropic.com/v1",                            "anthropic", "ANTHROPIC_API_KEY", "x-api-key",     ""),
        "google":     ("Google (Gemini)",   "https://generativelanguage.googleapis.com/v1beta/openai", "openai",    "GOOGLE_API_KEY",    "Authorization", "Bearer "),
        "deepseek":   ("DeepSeek",          "https://api.deepseek.com/v1",                             "openai",    "DEEPSEEK_API_KEY",  "Authorization", "Bearer "),
        "groq":       ("Groq",              "https://api.groq.com/openai/v1",                          "openai",    "GROQ_API_KEY",      "Authorization", "Bearer "),
        "mistral":    ("Mistral",           "https://api.mistral.ai/v1",                               "openai",    "MISTRAL_API_KEY",   "Authorization", "Bearer "),
        "xai":        ("xAI (Grok)",        "https://api.x.ai/v1",                                    "openai",    "XAI_API_KEY",       "Authorization", "Bearer "),
        "minimax":    ("MiniMax",           "https://api.minimax.chat/v1",                             "openai",    "MINIMAX_API_KEY",   "Authorization", "Bearer "),
        "moonshot":   ("Moonshot AI (Kimi)","https://api.moonshot.ai/v1",                              "openai",    "MOONSHOT_API_KEY",  "Authorization", "Bearer "),
        "qwen":       ("Qwen / Model Studio","https://dashscope-intl.aliyuncs.com/compatible-mode/v1","openai",    "DASHSCOPE_API_KEY", "Authorization", "Bearer "),
        "together":   ("Together AI",       "https://api.together.xyz/v1",                             "openai",    "TOGETHER_API_KEY",  "Authorization", "Bearer "),
        "perplexity": ("Perplexity",        "https://api.perplexity.ai",                               "openai",    "PERPLEXITY_API_KEY","Authorization", "Bearer "),
        "nvidia":     ("NVIDIA",            "https://integrate.api.nvidia.com/v1",                     "openai",    "NVIDIA_API_KEY",    "Authorization", "Bearer "),
        "huggingface":("Hugging Face",      "https://router.huggingface.co/v1",                        "openai",    "HF_TOKEN",          "Authorization", "Bearer "),
        "openrouter": ("OpenRouter",        "https://openrouter.ai/api/v1",                            "openai",    "OPENROUTER_API_KEY","Authorization", "Bearer "),
        "ollama":     ("Ollama",            "http://127.0.0.1:11434/v1",                               "openai",    "",                  "Authorization", "Bearer "),
        "lmstudio":   ("LM Studio",         "http://127.0.0.1:1234/v1",                                "openai",    "",                  "Authorization", "Bearer "),
        "vllm":       ("vLLM",              "http://127.0.0.1:8000/v1",                                "openai",    "",                  "Authorization", "Bearer "),
        "sglang":     ("SGLang",            "http://127.0.0.1:30000/v1",                               "openai",    "",                  "Authorization", "Bearer "),
        "jan":        ("Jan",               "http://127.0.0.1:1337/v1",                                "openai",    "",                  "Authorization", "Bearer "),
        "gpt4all":    ("GPT4All",           "http://127.0.0.1:4891/v1",                                "openai",    "",                  "Authorization", "Bearer "),
        "litellm":    ("LiteLLM",           "http://localhost:4000/v1",                                "openai",    "LITELLM_API_KEY",   "Authorization", "Bearer "),
        "bedrock":    ("Amazon Bedrock",    "https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1","openai",   "AWS_BEARER_TOKEN_BEDROCK", "Authorization", "Bearer "),
        "vercel":     ("Vercel AI Gateway", "https://ai-gateway.vercel.sh/v1",                         "openai",    "AI_GATEWAY_API_KEY","Authorization", "Bearer "),
        "cloudflare": ("Cloudflare AI Gateway","https://gateway.ai.cloudflare.com/v1",                 "openai",    "CLOUDFLARE_API_KEY","Authorization", "Bearer "),
        "github":     ("GitHub Copilot",    "https://api.githubcopilot.com",                           "openai",    "GITHUB_TOKEN",      "Authorization", "Bearer "),
        "glm":        ("GLM Models",        "https://open.bigmodel.cn/api/paas/v4",                    "openai",    "GLM_API_KEY",       "Authorization", "Bearer "),
        "venice":     ("Venice AI",         "https://api.venice.ai/api/v1",                            "openai",    "VENICE_API_KEY",    "Authorization", "Bearer "),
        "volcengine": ("Volcengine (Doubao)","https://ark.cn-beijing.volces.com/api/v3",               "openai",    "VOLCENGINE_API_KEY","Authorization", "Bearer "),
        "xiaomi":     ("Xiaomi",            "https://api.xiaomimimo.com/v1",                           "openai",    "XIAOMI_API_KEY",    "Authorization", "Bearer "),
        "zai":        ("Z.AI (GLM)",        "https://api.z.ai/api/paas/v4",                            "openai",    "ZAI_API_KEY",       "Authorization", "Bearer "),
        "qianfan":    ("Qianfan",           "https://qianfan.baidubce.com/v2",                         "openai",    "QIANFAN_API_KEY",  "Authorization", "Bearer "),
    ]

    static func builtInBaseURL(for key: String) -> String? { builtInProviders[key]?.baseURL }
    static func builtInApiStyle(for key: String) -> String? { builtInProviders[key]?.apiStyle }
    static func builtInEnvVar(for key: String) -> String? {
        let v = builtInProviders[key]?.env
        return (v?.isEmpty == false) ? v : nil
    }
    static func builtInAuthHeader(for key: String) -> String? { builtInProviders[key]?.authHeader }
    static func builtInAuthPrefix(for key: String) -> String? { builtInProviders[key]?.authPrefix }
}
