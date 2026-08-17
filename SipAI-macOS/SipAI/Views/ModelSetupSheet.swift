// ModelSetupSheet.swift
// The dedicated model-configuration window, opened from the composer's
// model selector ("Add Model") — deliberately NOT the Settings sheet.
// Mirrors the onboarding flow in miniature, and loops:
//   choose provider → API key (skipped when already known / local) →
//   tick models → "+ Add more models" starts the loop again.
//
// Model picks persist the moment they are toggled; the first model ever
// chosen becomes the default (ConfigManager.upsertModel fills an empty
// default), changeable later via each row's ⋯ menu. "Done" — the
// lower-right button — just closes the window: by then everything the
// user ticked is already saved and shows up in the model selector.

import SwiftUI

@MainActor
struct ModelSetupSheet: View {
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case provider, custom, apiKey, models }
    @State private var phase: Phase = .provider
    /// Provider queued behind the Remove Provider confirmation — the
    /// stored API key is unrecoverable, so a one-click delete from a
    /// hover menu was too easy to hit by accident.
    @State private var confirmingProviderRemoval: ProviderConfig? = nil

    // Provider step
    @State private var provider: BuiltinProvider? = nil
    @State private var providerSearch: String = ""

    // Custom provider step
    @State private var customName: String = ""
    @State private var customURL: String = ""

    // API key step
    @State private var apiKeyText: String = ""
    @State private var envVarText: String = ""
    @State private var keyError: String? = nil
    /// Endpoint choice for multi-region providers (Qwen, Moonshot,
    /// MiniMax, Volcengine, Z.AI).
    @State private var selectedRegionURL: String = ""
    /// "Other…" region entry: a region code when the provider has a
    /// URL template (none ship today), else a full base URL.
    @State private var useCustomRegion: Bool = false
    @State private var customRegionText: String = ""
    /// "Advanced → Endpoint" for every provider that shows no region
    /// picker. Hosted providers rarely need it; a self-hosted one
    /// (LiteLLM, a proxy) is unreachable without it.
    @State private var endpointText: String = ""
    @State private var showEndpointField: Bool = false

    // Manual model-ID verification.
    @State private var isVerifyingManual: Bool = false
    @State private var manualVerifyMessage: String? = nil
    /// Set when verification errored (network/auth, NOT "not found") —
    /// enables "Add anyway", since the model might still be real.
    @State private var unverifiedManualId: String? = nil

    // Models step
    @State private var fetchedModels: [String] = []
    @State private var isFetching: Bool = false
    @State private var fetchError: String? = nil
    @State private var manualModelId: String = ""
    @State private var selectedApiStyle: String = "openai"
    /// Shown in place of a model list for a provider that publishes
    /// none. Not an error — the fetch
    /// that would have produced one is never made.
    @State private var noListNote: String? = nil
    /// Rejection notice for providers whose `/models` is public, where
    /// a filled list is no evidence the key works (`ProviderKeyCheck`).
    @State private var keyCheckMessage: String? = nil
    @State private var keyCheckTask: Task<Void, Never>? = nil
    /// Providers already probed in this run of the flow — the check
    /// costs a request, and one answer covers every model ticked.
    @State private var keyCheckedProviders: Set<String> = []
    /// Whether the list shows every fetched model or just the newest
    /// few. Providers return their whole back catalog; the tail is
    /// noise for picking a model in 2026, so it hides behind
    /// "Show all N models".
    @State private var showAllFetched: Bool = false

    /// How many of the (newest-first) fetched models show by default.
    private static let fetchedCap = 15

    /// Invalidation for in-flight /models fetches: each fetch snapshots
    /// this counter and discards its result — list, error and spinner
    /// updates alike — if a newer fetch (or a provider switch) has
    /// bumped it since. Without it a slow stale response lands after
    /// "Change provider" and overwrites the newer list, so ticking a
    /// row persists the wrong provider's model id.
    @State private var fetchGeneration: Int = 0
    @State private var fetchTask: Task<Void, Never>? = nil

    private var visibleFetchedModels: [String] {
        showAllFetched ? fetchedModels : Array(fetchedModels.prefix(Self.fetchedCap))
    }

    // ↑ / ↓ / Return list navigation (see ListKeyMonitor).
    @State private var keyMonitor = ListKeyMonitor()
    @State private var providerHighlight: Int = 0
    @State private var modelHighlight: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !config.models.isEmpty {
                        configuredModelsSection
                    }
                    phaseSection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            Divider()
            bottomBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 500, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { dismiss() }
        .onAppear { keyMonitor.install(handleListKey) }
        .onDisappear { keyMonitor.remove() }
        .alert(
            // String expression, not an interpolated Text literal: a
            // custom provider's name is user text and would be markdown-
            // parsed by that overload.
            Text(String(localized: "Remove \(confirmingProviderRemoval?.name ?? "")?",
                        comment: "Title of the Remove Provider confirmation")),
            isPresented: Binding(
                get: { confirmingProviderRemoval != nil },
                set: { if !$0 { confirmingProviderRemoval = nil } }
            )
        ) {
            Button(role: .destructive) {
                if let pc = confirmingProviderRemoval {
                    config.removeProvider(key: pc.key)
                }
                confirmingProviderRemoval = nil
            } label: {
                Text("Remove", comment: "Confirm removing the provider")
            }
            Button(role: .cancel) {
                confirmingProviderRemoval = nil
            } label: {
                Text("Cancel", comment: "Cancel the provider removal")
            }
        } message: {
            Text("Its stored API key is deleted permanently. Its models stay and can be re-linked by adding the provider again.",
                 comment: "Body of the Remove Provider confirmation")
        }
    }

    /// Keyboard list navigation: arrows move the highlight of whichever
    /// list the current phase shows; Return activates the highlighted
    /// row (select a provider / toggle a model). Return inside the
    /// manual-ID field keeps its own submit.
    private func handleListKey(_ key: ListKeyMonitor.Key,
                               whileEditing: Bool) -> Bool {
        switch phase {
        case .provider:
            let rows = navProviders
            guard !rows.isEmpty else { return false }
            switch key {
            case .down:
                providerHighlight = min(providerHighlight + 1, rows.count - 1)
                return true
            case .up:
                providerHighlight = max(providerHighlight - 1, 0)
                return true
            case .ret:
                // Deliberately also while the search field is focused —
                // type to filter, Return to take the highlighted row.
                guard rows.indices.contains(providerHighlight) else { return false }
                selectProvider(rows[providerHighlight])
                return true
            }
        case .models:
            guard !isFetching, !fetchedModels.isEmpty else { return false }
            switch key {
            case .down:
                // Arrowing past the visible cap reveals the rest.
                if !showAllFetched,
                   modelHighlight + 1 >= visibleFetchedModels.count,
                   fetchedModels.count > visibleFetchedModels.count {
                    showAllFetched = true
                }
                modelHighlight = min(modelHighlight + 1,
                                     visibleFetchedModels.count - 1)
                return true
            case .up:
                modelHighlight = max(modelHighlight - 1, 0)
                return true
            case .ret:
                if whileEditing { return false }
                guard fetchedModels.indices.contains(modelHighlight) else { return false }
                let id = fetchedModels[modelHighlight]
                toggleModel(id, added: config.model(for: id)?.providerKey == provider?.key)
                return true
            }
        case .custom, .apiKey:
            return false
        }
    }

    /// Arrow-navigable provider rows, in exactly the order they render.
    private var navProviders: [BuiltinProvider] { filteredCloudProviders }

    /// Providers that can take more models with one click: anything in
    /// config with working credentials that ALREADY HAS a model. A
    /// provider whose setup never reached one — a key pasted, the fetch
    /// failed, the sheet closed — is not something to add "more" models
    /// from, and offering it as configured misreports a setup that never
    /// finished. It waits in the catalog list below instead, where
    /// picking it again keeps the stored key.
    ///
    /// This reads CONFIG, not the catalog, so a provider that has since
    /// been retired from the offer list (a local server, GitHub Copilot)
    /// still appears here for whoever already set it up.
    private var quickAddProviders: [ProviderConfig] {
        // Image models count too: a provider set up for image generation
        // is genuinely configured, and its key is reachable from here.
        let withModels = Set(config.models.map(\.providerKey))
            .union(config.imageModels.map(\.providerKey))
        return config.providers.filter { pc in
            withModels.contains(pc.key)
                && (pc.apiKey?.isEmpty == false
                    || pc.envVar?.isEmpty == false
                    // A retired local server has no key and never needed
                    // one; its rows must not vanish from this list.
                    || pc.baseURL.hasPrefix("http://"))
        }
    }

    /// Base URLs this app itself wrote as provider defaults — the ONLY
    /// stored URLs `quickPick` may rewrite. Mirrors
    /// `ConfigManager.migrateStaleProviderDefaults`; every other stored
    /// URL is a deliberate choice ("Other…" regions, template-expanded
    /// codes like Bedrock ap-south-2) and must survive "Add more
    /// models" untouched.
    private static let staleDefaultBaseURLs: [String: String] = [
        "qwen":        "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "moonshot":    "https://api.moonshot.cn/v1",
        "huggingface": "https://api-inference.huggingface.co/v1",
        "bedrock":     "https://bedrock-runtime.us-east-1.amazonaws.com",
        "vercel":      "https://api.vercel.ai/v1",
        "xiaomi":      "https://api.mimo.xiaomi.com/v1",
        "zai":         "https://api.zai.chat/v1",
    ]

    /// "Add more models from X": straight to the model list, stored
    /// credentials as-is.
    private func quickPick(_ pc: ProviderConfig) {
        let p: BuiltinProvider
        if let cat = BuiltinProviderCatalog.find(pc.key) {
            // Heal drifted apiStyle/auth fields from the catalog while
            // keeping the user's credentials AND base URL — the stored
            // URL is a deliberate choice, and resetting anything not in
            // the region list clobbered "Other…"/template-expanded
            // regions on every visit. The one exception is a known
            // stale default this app itself wrote (staleDefaultBaseURLs
            // above), and even that stays when it doubles as a
            // legitimate region choice (Qwen's Beijing endpoint) — the
            // once-only philosophy of migrateStaleProviderDefaults.
            let isStaleDefault = pc.baseURL == Self.staleDefaultBaseURLs[pc.key]
                && !cat.regions.contains { $0.baseURL == pc.baseURL }
            let keepURL = isStaleDefault ? cat.baseURL : pc.baseURL
            if pc.baseURL != keepURL || pc.apiStyle != cat.apiStyle
                || pc.authHeader != cat.authHeader
                || pc.authPrefix != cat.authPrefix {
                var refreshed = cat.toProviderConfig(apiKey: pc.apiKey)
                refreshed.envVar = pc.envVar
                refreshed.baseURL = keepURL
                config.upsertProvider(refreshed)
            }
            p = cat.withBaseURL(keepURL)
        } else {
            p = BuiltinProvider(
                key: pc.key, name: pc.name, baseURL: pc.baseURL,
                apiStyle: pc.apiStyle, envVar: pc.envVar ?? "",
                authHeader: pc.authHeader, authPrefix: pc.authPrefix
            )
        }
        resetFlowState(for: p)
        goToModels()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Chat Models", comment: "Model setup window title")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(SipDesign.textPrimary)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundColor(SipDesign.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        switch phase {
        case .provider:
            return String(localized: "Choose a provider to add models from.",
                          comment: "Model setup subtitle on the provider step")
        case .custom:
            return String(localized: "Point SipAI at any OpenAI-compatible server.",
                          comment: "Model setup subtitle on the custom-provider step")
        case .apiKey:
            return String(localized: "Enter your API key for \(provider?.name ?? "the provider").",
                          comment: "Model setup subtitle on the API key step")
        case .models:
            return String(localized: "Tick the models you want. The first model you pick becomes the default.",
                          comment: "Model setup subtitle on the model-picking step")
        }
    }

    // MARK: - Configured models ("Your models")

    private var configuredModelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your models", comment: "Model setup: header of the configured-models list")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(SipDesign.textSecondary)
                .textCase(.uppercase)
            VStack(spacing: 6) {
                ForEach(config.models) { m in
                    configuredModelRow(m)
                }
            }
        }
    }

    private func configuredModelRow(_ m: ModelConfig) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(m.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SipDesign.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(providerDisplayName(m.providerKey))
                    .font(.system(size: 11))
                    .foregroundColor(SipDesign.textSecondary)
            }
            Spacer(minLength: 8)
            if m.id == config.defaultModel {
                Text("default", comment: "Chip marking the default model")
                    .font(.system(size: 11))
                    .foregroundColor(SipDesign.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(SipDesign.cardSelectedBg)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            ModelRowActionsMenu(model: m)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SipDesign.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Phase area

    @ViewBuilder
    private var phaseSection: some View {
        switch phase {
        case .provider: providerSection
        case .custom: customSection
        case .apiKey: apiKeySection
        case .models: modelsSection
        }
    }

    // MARK: Phase 1 — provider list

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // One-click continuation for providers that already have
            // working credentials — the full pick-provider → key flow
            // below is only for providers not yet configured.
            if !quickAddProviders.isEmpty {
                VStack(spacing: 6) {
                    ForEach(quickAddProviders) { pc in
                        HStack(spacing: 0) {
                            Button {
                                quickPick(pc)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundColor(SipDesign.blue)
                                    Text("Add more models from \(pc.name)",
                                         comment: "Model setup: one-click row for an already-configured provider")
                                        .font(.system(size: 13))
                                        .foregroundColor(SipDesign.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(SipDesign.textHint)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 38)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            // ⋯ outside the row button (nested SwiftUI
                            // buttons both fire): removes the provider
                            // and its stored key — its models stay, and
                            // deleting those is the model rows' own ⋯.
                            RowEllipsisMenu {
                                Button(role: .destructive) {
                                    confirmingProviderRemoval = pc
                                } label: {
                                    Text("Remove Provider",
                                         comment: "Model setup: quick-row menu — delete the provider and its stored key, keeping its models")
                                }
                            }
                            .padding(.trailing, 8)
                        }
                        .background(SipDesign.cardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.bottom, 4)
            }

            if quickAddProviders.isEmpty {
                Text("Add models from", comment: "Model setup: header above the provider list")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(SipDesign.textSecondary)
                    .textCase(.uppercase)
            } else {
                Text("Or set up a new provider", comment: "Model setup: provider list header when configured providers are offered above")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(SipDesign.textSecondary)
                    .textCase(.uppercase)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(SipDesign.textHint)
                TextField(String(localized: "Search providers",
                                 comment: "Model setup: provider search placeholder"),
                          text: $providerSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(SipDesign.textPrimary)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(SipDesign.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(SipDesign.borderLight, lineWidth: 1)
            )

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        providerListBody
                    }
                }
                .onChange(of: providerHighlight) { _, idx in
                    let rows = navProviders
                    if rows.indices.contains(idx) {
                        proxy.scrollTo("prov-\(rows[idx].key)")
                    }
                }
            }
            .frame(height: 250)
            .background(SipDesign.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(SipDesign.borderLight, lineWidth: 1)
            )
        }
        .onChange(of: providerSearch) { _, _ in
            providerHighlight = 0
        }
    }

    @ViewBuilder
    private var providerListBody: some View {
                    ForEach(filteredCloudProviders) { p in
                        providerRow(p)
                    }
                    if providerSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                        providerSectionHeader(String(
                            localized: "Other",
                            comment: "Model setup: provider list section header"))
                        Button {
                            customName = ""
                            customURL = ""
                            withAnimation { phase = .custom }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 12))
                                    .foregroundColor(SipDesign.blue)
                                Text("Custom (name & URL)",
                                     comment: "Model setup: row that opens the custom-provider form")
                                    .font(.system(size: 13))
                                    .foregroundColor(SipDesign.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(SipDesign.textHint)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 38)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
    }

    private func providerSectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(SipDesign.textSecondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func providerRow(_ p: BuiltinProvider) -> some View {
        let highlighted = navProviders.indices.contains(providerHighlight)
            && navProviders[providerHighlight].key == p.key
        return Button {
            selectProvider(p)
        } label: {
            HStack(spacing: 8) {
                Text(BuiltinProviderCatalog.localizedName(p))
                    .font(.system(size: 13))
                    .foregroundColor(SipDesign.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(SipDesign.textHint)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .contentShape(Rectangle())
            .background(highlighted ? SipDesign.cardSelectedBg : Color.clear)
            .overlay(
                Rectangle()
                    .fill(SipDesign.borderLight.opacity(0.5))
                    .frame(height: 1),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
        .id("prov-\(p.key)")
    }

    /// Cloud providers sorted alphabetically, filtered by search query.
    private var filteredCloudProviders: [BuiltinProvider] {
        let cloud = BuiltinProviderCatalog.cloudSorted
        let q = providerSearch.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return cloud }
        return cloud.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// Reset every per-provider field for a fresh pick. The env var is
    /// only ever a PLACEHOLDER hint — pre-filling it as real text would
    /// make the field look already configured while satisfying nothing.
    private func resetFlowState(for p: BuiltinProvider) {
        provider = p
        // Invalidate any fetch still in flight for the previous provider
        // — its late result must not overwrite this provider's state.
        fetchTask?.cancel()
        fetchGeneration += 1
        keyError = nil
        apiKeyText = ""
        envVarText = ""
        fetchedModels = []
        fetchError = nil
        manualModelId = ""
        selectedApiStyle = "openai"
        showAllFetched = false
        isVerifyingManual = false
        manualVerifyMessage = nil
        unverifiedManualId = nil
        noListNote = nil
        keyCheckTask?.cancel()
        keyCheckMessage = nil
        // A previously chosen region sticks; a stored URL outside the
        // list re-opens as an "Other…" entry; otherwise the default.
        useCustomRegion = false
        customRegionText = ""
        selectedRegionURL = p.baseURL
        let stored = config.provider(for: p.key)?.baseURL
        // The endpoint field carries whatever is stored, and OPENS
        // itself when that is not the catalog default — a customized
        // endpoint hidden behind a disclosure reads as though the
        // provider were pointed at its usual host.
        endpointText = stored ?? p.baseURL
        showEndpointField = (stored != nil && stored != p.baseURL)
        if !p.regions.isEmpty, let stored {
            if p.regions.contains(where: { $0.baseURL == stored }) {
                selectedRegionURL = stored
            } else if stored != p.baseURL {
                useCustomRegion = true
                customRegionText = stored
            }
        } else if p.regions.isEmpty, p.regionURLTemplate != nil {
            // A URL to complete, not a region to pick: the field is the
            // only way through, so it is open from the start and carries
            // whatever was completed last time.
            useCustomRegion = true
            if let stored, stored != p.baseURL { customRegionText = stored }
        }
    }

    /// The endpoint the current region choice resolves to; empty when
    /// "Other…" is selected but nothing has been typed yet.
    private var effectiveRegionURL: String {
        guard let p = provider else { return "" }
        if useCustomRegion { return p.customRegionBaseURL(customRegionText) }
        return selectedRegionURL.isEmpty ? p.baseURL : selectedRegionURL
    }

    /// Whether this provider's endpoint is chosen from a list (or
    /// completed from a template) rather than typed freely.
    private var showsRegionUI: Bool {
        guard let p = provider else { return false }
        return p.regions.count > 1 || p.regionURLTemplate != nil
    }

    /// The base URL this step will actually store — the region choice
    /// where there is one, the Advanced endpoint otherwise. Every
    /// caller reads THIS rather than one of the two halves, so the two
    /// input shapes cannot disagree about what was set up.
    private var resolvedBaseURL: String {
        guard let p = provider else { return "" }
        if showsRegionUI { return effectiveRegionURL }
        let typed = endpointText.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? p.baseURL : typed
    }

    private func isValidHTTPBaseURL(_ string: String) -> Bool {
        BuiltinProviderCatalog.isValidHTTPBaseURL(string)
    }

    private func selectProvider(_ p: BuiltinProvider) {
        resetFlowState(for: p)
        // Every provider passes through the key page — picking one and
        // landing straight on models read as a broken step. Stored
        // credentials just make an empty Continue mean "keep what I
        // have", and the page is also where the endpoint is set.
        withAnimation { phase = .apiKey }
    }

    private func goToModels() {
        withAnimation { phase = .models }
        startModelFetch()
    }

    /// Cancel-and-replace wrapper around `loadModels` so at most one
    /// fetch is ever live — the generation guard in `loadModels`
    /// discards whatever a superseded call still delivers.
    private func startModelFetch() {
        fetchTask?.cancel()
        fetchTask = Task { await loadModels() }
    }

    // MARK: Phase 1b — custom provider

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledField(
                String(localized: "Provider name", comment: "Model setup: custom provider name label"),
                placeholder: String(localized: "e.g. My Server",
                                    comment: "Model setup: custom provider name placeholder"),
                text: $customName
            )
            labeledField(
                String(localized: "API base URL", comment: "Model setup: custom provider URL label"),
                placeholder: String(localized: "e.g. https://api.example.com/v1",
                                    comment: "Model setup: custom provider URL placeholder"),
                text: $customURL
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func continueFromCustom() {
        let name = customName.trimmingCharacters(in: .whitespaces)
        let url = customURL.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !url.isEmpty else { return }
        let key = BuiltinProviderCatalog
            .uniqueCustomProviderKey(for: name, config: config)
        let custom = BuiltinProvider(
            key: key, name: name, baseURL: url,
            apiStyle: "openai", envVar: "",
            authHeader: "Authorization", authPrefix: "Bearer "
        )
        // Full reset, not a hand-picked subset: the endpoint field (and
        // every other per-provider field) would otherwise still hold
        // the PREVIOUS provider's value, and `resolvedBaseURL` reads it.
        resetFlowState(for: custom)
        // resetFlowState seeds the endpoint from what is STORED under
        // this key; the URL just typed here is newer and has to win.
        endpointText = url
        withAnimation { phase = .apiKey }
    }


    // MARK: Phase 2 — API key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Region FIRST — only the user knows which region their key
            // belongs to, so it must be picked before anything is tried.
            regionSection
            endpointSection

            VStack(alignment: .leading, spacing: 6) {
                Text("API Key from \(provider?.name ?? "Provider")",
                     comment: "Model setup: API key field label naming the provider")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SipDesign.textPrimary)
                FocusClearingField(
                    placeholder: String(localized: "Paste your API key",
                                        comment: "Model setup: API key placeholder"),
                    text: $apiKeyText,
                    secure: true
                )
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(SipDesign.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(SipDesign.borderLight, lineWidth: 1)
                )
                // Which key, for the providers where "your API key" is
                // genuinely ambiguous — Z.AI issues one per platform,
                // and only one of them takes yours.
                if let note = provider?.keyFieldNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(SipDesign.textHint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 12) {
                Rectangle().fill(SipDesign.borderLight).frame(height: 1)
                Text("or", comment: "Model setup: divider between key and env-var fields")
                    .font(.system(size: 12))
                    .foregroundColor(SipDesign.textHint)
                Rectangle().fill(SipDesign.borderLight).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Use environment variable",
                     comment: "Model setup: env var field label")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SipDesign.textPrimary)
                FocusClearingField(
                    placeholder: envVarPlaceholder,
                    text: $envVarText
                )
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(SipDesign.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(SipDesign.borderLight, lineWidth: 1)
                )
            }

            if let err = keyError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }

            // Credentials already on file. Worth saying out loud: a
            // provider with no models yet is not offered in the
            // quick-add list, so this screen is where its owner lands
            // every time — with both fields blank, and nothing else on
            // the page admitting a key is stored. It is also the only
            // place to delete that key.
            if storedCredentialsExist, let p = provider,
               let existing = config.provider(for: p.key) {
                HStack(spacing: 10) {
                    Text("A key is already stored — leave both fields empty to keep it.",
                         comment: "Model setup: stored-credentials notice on the API key step")
                        .font(.system(size: 11))
                        .foregroundColor(SipDesign.textHint)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        confirmingProviderRemoval = existing
                    } label: {
                        Text("Remove", comment: "Model setup: delete the stored key on the API key step")
                            .font(.system(size: 11))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Endpoint choice for providers hosted in several regions (Qwen,
    /// Moonshot) — keys are region-bound, so the wrong endpoint
    /// 401s a perfectly good key.
    ///
    /// A URL template with NO region list means something different:
    /// the endpoint is a path the user must COMPLETE, not one of
    /// several to choose between. No shipping provider takes that
    /// path since Bedrock and the Cloudflare gateway were retired,
    /// but the shape recurs. That case renders the field alone —
    /// radio rows and an "Other…" escape make no sense when there is
    /// exactly one thing to type.
    @ViewBuilder
    private var regionSection: some View {
        if let p = provider, p.regions.count > 1 || p.regionURLTemplate != nil {
            let completesPath = p.regions.isEmpty
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if completesPath {
                        Text("Endpoint", comment: "Model setup: header above the field that completes a provider's URL")
                    } else {
                        Text("Region", comment: "Model setup: region picker header")
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(SipDesign.textPrimary)
                if !completesPath {
                    ForEach(p.regions, id: \.baseURL) { region in
                        let picked = !useCustomRegion && selectedRegionURL == region.baseURL
                        Button {
                            useCustomRegion = false
                            selectedRegionURL = region.baseURL
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                                    .foregroundColor(picked ? SipDesign.blue : SipDesign.textSecondary)
                                    .font(.system(size: 13))
                                Text(region.label)
                                    .font(.system(size: 12.5))
                                    .foregroundColor(SipDesign.textPrimary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    // Manual entry: a bare region code for template
                    // providers, a full URL otherwise.
                    Button {
                        useCustomRegion = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: useCustomRegion ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(useCustomRegion ? SipDesign.blue : SipDesign.textSecondary)
                                .font(.system(size: 13))
                            Text("Other…", comment: "Model setup: manual region entry option")
                                .font(.system(size: 12.5))
                                .foregroundColor(SipDesign.textPrimary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if useCustomRegion {
                    FocusClearingField(
                        placeholder: completesPath
                            ? String(localized: "account-tag/gateway-name",
                                     comment: "Model setup: placeholder for the path that completes a gateway URL")
                            : (p.regionURLTemplate != nil
                               ? String(localized: "Region code, e.g. eu-west-3",
                                        comment: "Model setup: custom region code placeholder")
                               : String(localized: "https://…",
                                        comment: "Model setup: custom region URL placeholder")),
                        text: $customRegionText
                    )
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(SipDesign.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(SipDesign.borderLight, lineWidth: 1)
                    )
                    // Indented under the radio rows it belongs to —
                    // except when it IS the section (nothing to align
                    // beneath).
                    .padding(.leading, completesPath ? 0 : 21)
                    // Raw text becomes the base URL verbatim when no
                    // template expands it — refuse non-URLs here
                    // instead of storing "beijing".
                    if !customRegionText.trimmingCharacters(in: .whitespaces).isEmpty,
                       !isValidHTTPBaseURL(effectiveRegionURL) {
                        Text(completesPath
                             ? String(localized: "Enter your account tag and gateway name, like account-tag/gateway-name.",
                                      comment: "Model setup: invalid entry in the URL-completion field")
                             : (p.regionURLTemplate != nil
                                ? String(localized: "Enter a region code like eu-west-3, or a full https:// URL.",
                                         comment: "Model setup: invalid custom region entry for a template provider")
                                : String(localized: "Enter a full URL starting with http:// or https://.",
                                         comment: "Model setup: custom region text is not a usable URL")))
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .padding(.leading, completesPath ? 0 : 21)
                    }
                }
            }
        }
    }

    /// Free-text endpoint for every provider the region picker does not
    /// already cover. Folded away by default — a hosted provider's URL
    /// is not a decision most people have to make — but always present:
    /// without it a self-hosted proxy anywhere but the default URL
    /// could only be reached by re-adding it as a custom provider.
    @ViewBuilder
    private var endpointSection: some View {
        if let p = provider, !showsRegionUI {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation { showEndpointField.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showEndpointField ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Endpoint", comment: "Model setup: disclosure for the provider's base URL")
                            .font(.system(size: 12, weight: .semibold))
                        if !showEndpointField {
                            Text(resolvedBaseURL)
                                .font(.system(size: 11))
                                .foregroundColor(SipDesign.textHint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(SipDesign.textPrimary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showEndpointField {
                    FocusClearingField(
                        placeholder: p.baseURL,
                        text: $endpointText
                    )
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(SipDesign.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(SipDesign.borderLight, lineWidth: 1)
                    )
                    if !isValidHTTPBaseURL(resolvedBaseURL) {
                        Text("Enter a full URL starting with http:// or https://.",
                             comment: "Model setup: the endpoint field holds something that is not a URL")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                }
            }
        }
    }

    /// The provider's usual variable name, as a hint only.
    private var envVarPlaceholder: String {
        if let suggestion = provider?.envVar, !suggestion.isEmpty {
            return String(localized: "e.g. \(suggestion)",
                          comment: "Model setup: env var placeholder showing the provider's usual variable")
        }
        return String(localized: "e.g. OPENAI_API_KEY",
                      comment: "Model setup: generic env var placeholder")
    }

    /// True when the picked provider already carries usable credentials
    /// in config — a stored key or an env var name.
    private var storedCredentialsExist: Bool {
        guard let p = provider,
              let existing = config.provider(for: p.key) else { return false }
        return existing.apiKey?.isEmpty == false
            || existing.envVar?.isEmpty == false
    }

    private func continueFromApiKey() {
        guard let p = provider else { return }
        keyError = nil
        let trimmedKey = apiKeyText.trimmingCharacters(in: .whitespaces)
        let trimmedEnv = envVarText.trimmingCharacters(in: .whitespaces)

        let effective = resolvedBaseURL
        // A raw "Other…" entry is stored verbatim as the base URL —
        // refuse anything that isn't an http(s) URL ("beijing" would
        // fail every request with an opaque unsupported-URL error).
        if useCustomRegion, !isValidHTTPBaseURL(effective) {
            keyError = p.regions.isEmpty && p.regionURLTemplate != nil
                ? String(localized: "Complete the endpoint above before continuing.",
                         comment: "Model setup: URL-completion field empty or unusable at save time")
                : String(localized: "The region entry must be a full URL starting with http:// or https://.",
                         comment: "Model setup: custom region text rejected at save time")
            return
        }
        // Same rule for the Advanced endpoint — it is stored verbatim
        // too, so it may not be saved as anything but a URL.
        if !showsRegionUI, !isValidHTTPBaseURL(effective) {
            keyError = String(localized: "The endpoint must be a full URL starting with http:// or https://.",
                              comment: "Model setup: endpoint field rejected at save time")
            showEndpointField = true
            return
        }
        let regionURL = effective.isEmpty ? p.baseURL : effective

        guard !trimmedKey.isEmpty || !trimmedEnv.isEmpty else {
            // A plain-HTTP endpoint is a local server and has no key to
            // give. This is the path Ollama and friends take now that
            // the "Local Model Providers" section is gone.
            if !storedCredentialsExist,
               BuiltinProviderCatalog.endpointNeedsNoKey(regionURL) {
                var pc = p.toProviderConfig(apiKey: nil)
                pc.baseURL = regionURL
                config.upsertProvider(pc)
                provider = p.withBaseURL(regionURL)
                goToModels()
                return
            }
            if storedCredentialsExist, let existing = config.provider(for: p.key) {
                // Empty fields on an already-configured provider mean
                // "keep the stored credentials" — but a changed region
                // must still be written.
                var refreshed = p.toProviderConfig(apiKey: existing.apiKey)
                refreshed.envVar = existing.envVar
                refreshed.baseURL = regionURL
                config.upsertProvider(refreshed)
                provider = p.withBaseURL(regionURL)
                goToModels()
            } else {
                keyError = String(localized: "Enter an API key or an environment variable name.",
                                  comment: "Model setup: API key validation error")
            }
            return
        }

        // Store whatever was given — a pasted key, an env var name, or
        // both. The name deliberately does NOT have to resolve in this
        // process: a GUI app launched from the Dock never sees shell
        // exports, and the key lookup is env-first at request time.
        var pc = p.toProviderConfig(apiKey: trimmedKey.isEmpty ? nil : trimmedKey)
        pc.envVar = trimmedEnv.isEmpty ? nil : trimmedEnv
        pc.baseURL = regionURL
        config.upsertProvider(pc)
        // Fetching and verification must hit the chosen region too.
        provider = p.withBaseURL(regionURL)
        goToModels()
    }

    // MARK: Phase 3 — pick models (multi-choice)

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Models from \(provider?.name ?? "")",
                     comment: "Model setup: header above the fetched model list")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(SipDesign.textSecondary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    startAnotherProvider()
                } label: {
                    Text("Change provider",
                         comment: "Model setup: go back to the provider list without adding")
                        .font(.system(size: 12))
                        .foregroundColor(SipDesign.textSecondary)
                }
                .buttonStyle(.plain)
            }

            if isFetching {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Fetching models…",
                         comment: "Model setup: shown while the /models call runs")
                        .font(.system(size: 12))
                        .foregroundColor(SipDesign.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            } else if !fetchedModels.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleFetchedModels, id: \.self) { id in
                                fetchedModelRow(id)
                            }
                            if !showAllFetched,
                               fetchedModels.count > Self.fetchedCap {
                                Button {
                                    showAllFetched = true
                                } label: {
                                    HStack {
                                        Text("Show all \(fetchedModels.count) models",
                                             comment: "Model setup: reveal the older fetched models")
                                            .font(.system(size: 12.5))
                                            .foregroundColor(SipDesign.blue)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(height: 36)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .onChange(of: modelHighlight) { _, idx in
                        if fetchedModels.indices.contains(idx) {
                            proxy.scrollTo("model-\(fetchedModels[idx])")
                        }
                    }
                }
                .frame(height: 190)
                .background(SipDesign.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(SipDesign.borderLight, lineWidth: 1)
                )
            } else if let note = noListNote {
                // Information, not a failure: nothing went wrong, this
                // provider simply has no list to show.
                Label {
                    Text(note)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.system(size: 12))
                .foregroundColor(SipDesign.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let e = fetchError {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(e)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    // Region switch in place: only the user knows which
                    // region their key belongs to, and this is the
                    // moment they find out the current one is wrong.
                    if let p = provider, p.regions.count > 1 {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(p.regions, id: \.baseURL) { region in
                                Button {
                                    switchRegion(region)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: provider?.baseURL == region.baseURL
                                              ? "largecircle.fill.circle" : "circle")
                                            .foregroundColor(provider?.baseURL == region.baseURL
                                                             ? SipDesign.blue : SipDesign.textSecondary)
                                            .font(.system(size: 13))
                                        // .label, like the setup-phase
                                        // picker — .name drops the region
                                        // code, where there is one, or
                                        // the two pickers would name the
                                        // same endpoint differently.
                                        Text(region.label)
                                            .font(.system(size: 12.5))
                                            .foregroundColor(SipDesign.textPrimary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    // Providers move their API hosts, and a base URL
                    // this app shipped with can simply be out of date —
                    // which looks exactly like a bad key from here.
                    // Worth saying, because "edit the endpoint" is not
                    // a thing most people would think to try.
                    Text("The endpoint may not be up to date — editing it could solve this.",
                         comment: "Model setup: hint next to a failed model fetch")
                        .font(.system(size: 11))
                        .foregroundColor(SipDesign.textHint)
                        .fixedSize(horizontal: false, vertical: true)
                    // The two things that actually fix a failed fetch,
                    // offered where it failed. Without this the only
                    // route back to the credentials would be Back → the
                    // provider list → find the row again.
                    HStack(spacing: 12) {
                        Button {
                            startModelFetch()
                        } label: {
                            Text("Try again", comment: "Model setup: refetch the model list")
                                .font(.system(size: 12))
                        }
                        Button {
                            editKeyAndEndpoint()
                        } label: {
                            Text("Edit key or endpoint",
                                 comment: "Model setup: go back to the key/endpoint page for this provider")
                                .font(.system(size: 12))
                        }
                    }
                }
            }

            if !isFetching {
                HStack(spacing: 8) {
                    TextField(String(localized: "Or enter a model ID, e.g. gpt-4o",
                                     comment: "Model setup: manual model entry placeholder"),
                              text: $manualModelId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .onSubmit { addManualModel() }
                        .disabled(isVerifyingManual)
                    Button {
                        addManualModel()
                    } label: {
                        if isVerifyingManual {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Add", comment: "Model setup: add the manually typed model ID")
                                .font(.system(size: 13))
                        }
                    }
                    .disabled(isVerifyingManual
                              || manualModelId.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let message = manualVerifyMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if let pending = unverifiedManualId {
                            Button {
                                // saveManualModel clears the message on
                                // success and replaces it when the id
                                // collides with another provider's entry.
                                saveManualModel(pending)
                            } label: {
                                Text("Add \(pending) anyway",
                                     comment: "Model setup: save the model even though verification failed")
                                    .font(.system(size: 11))
                            }
                        }
                    }
                }

                if let warning = keyCheckMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Label {
                            Text(warning)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        // A rejected key is fixed on the page before
                        // this one, so say so with a button.
                        Button {
                            editKeyAndEndpoint()
                        } label: {
                            Text("Edit key or endpoint",
                                 comment: "Model setup: go back to the key/endpoint page for this provider")
                                .font(.system(size: 11))
                        }
                    }
                }

                if provider?.key == "openai" {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Style", comment: "Model setup: OpenAI API style header")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(SipDesign.textPrimary)
                        apiStyleRadioRow(String(localized: "Chat Completions (standard)",
                                                comment: "Model setup: OpenAI chat completions style"),
                                         value: "openai")
                        apiStyleRadioRow(String(localized: "Responses API (advanced)",
                                                comment: "Model setup: OpenAI responses style"),
                                         value: "openai-responses")
                        Text("Applies to models you tick from now on.",
                             comment: "Model setup: OpenAI API style hint")
                            .font(.system(size: 11))
                            .foregroundColor(SipDesign.textHint)
                    }
                    .padding(.top, 2)
                }

                Button {
                    startAnotherProvider()
                } label: {
                    HStack {
                        Spacer()
                        Text("+ Add more models",
                             comment: "Model setup: restart the flow with another provider")
                            .font(.system(size: 13))
                            .foregroundColor(SipDesign.textSecondary)
                        Spacer()
                    }
                    .frame(height: 38)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                            .foregroundColor(SipDesign.borderLight)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }

    private func fetchedModelRow(_ id: String) -> some View {
        let added = config.model(for: id)?.providerKey == provider?.key
        let highlighted = fetchedModels.indices.contains(modelHighlight)
            && fetchedModels[modelHighlight] == id
        return Button {
            toggleModel(id, added: added)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: added ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(added ? SipDesign.blue : SipDesign.textHint)
                Text(id)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundColor(SipDesign.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if id == config.defaultModel {
                    Text("default", comment: "Chip marking the default model")
                        .font(.system(size: 11))
                        .foregroundColor(SipDesign.blue)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(Rectangle())
            .background(
                added ? SipDesign.cardSelectedBg
                    : (highlighted ? Color.gray.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(highlighted ? SipDesign.blue : Color.clear,
                                  lineWidth: 1)
                    .padding(1)
            )
        }
        .buttonStyle(.plain)
        .id("model-\(id)")
    }

    private func toggleModel(_ id: String, added: Bool) {
        guard let p = provider else { return }
        if added {
            config.removeModel(id: id)
            if appState.activeModel == id {
                appState.activeModel = config.defaultModel
            }
        } else {
            // Config models are keyed by bare id — ticking "llama3" here
            // must not silently rewire an existing "llama3" configured
            // under another provider (a second tick would then delete
            // that entry outright).
            if let existing = config.model(for: id), existing.providerKey != p.key {
                manualVerifyMessage = String(
                    localized: "\(id) is already configured under \(providerDisplayName(existing.providerKey)) — remove it there first.",
                    comment: "Model setup: refusing to tick a model id that already exists under a different provider")
                unverifiedManualId = nil
                return
            }
            config.upsertModel(id: id, name: id, providerKey: p.key,
                               apiStyle: apiStyleForNewModels)
            if appState.activeModel == nil {
                appState.activeModel = config.defaultModel
            }
            startKeyCheckIfNeeded(for: p, modelId: id)
        }
    }

    /// Probe the key on providers that list models publicly — there the
    /// fetch above proved only that the SERVER is up. Fire-and-forget:
    /// the model stays ticked either way, because a rejected key is
    /// fixed by going Back, not by silently undoing the user's pick.
    private func startKeyCheckIfNeeded(for p: BuiltinProvider, modelId: String) {
        guard ProviderKeyCheck.isNeeded(for: p),
              !keyCheckedProviders.contains(p.key) else { return }
        keyCheckedProviders.insert(p.key)
        let key = config.apiKey(for: p.key) ?? ""
        let style = apiStyleForNewModels
        keyCheckTask?.cancel()
        keyCheckTask = Task {
            let message = await ProviderKeyCheck.rejectionMessage(
                provider: p, apiStyle: style, apiKey: key, modelId: modelId)
            // Same staleness rule as the fetch: a provider switch
            // mid-probe makes this answer somebody else's.
            guard !Task.isCancelled, provider?.key == p.key else { return }
            keyCheckMessage = message
        }
    }

    /// Verify a typed model ID with a 1-token probe before saving,
    /// which is what keeps typos from becoming dead config entries.
    /// "Not found" refuses; any other failure (network, quota) offers
    /// "Add anyway".
    private func addManualModel() {
        guard let p = provider, !isVerifyingManual else { return }
        let id = manualModelId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        manualVerifyMessage = nil
        unverifiedManualId = nil
        isVerifyingManual = true
        let style = apiStyleForNewModels
        Task {
            let rawKey = config.apiKey(for: p.key) ?? ""
            let key = rawKey.isEmpty ? "local" : rawKey
            let verdict = await ModelVerifier.verify(
                provider: p, apiStyle: style, apiKey: key, modelId: id)
            // A provider switch mid-verify invalidates this probe —
            // saving would attach the id to the wrong provider.
            // (resetFlowState already reset isVerifyingManual.)
            guard provider?.key == p.key else { return }
            isVerifyingManual = false
            switch verdict {
            case .ok:
                saveManualModel(id)
            case .notFound(let detail):
                manualVerifyMessage = String(
                    localized: "Model not found: \(id). \(detail)",
                    comment: "Model setup: manual ID rejected by the provider")
            case .error(let message):
                manualVerifyMessage = String(
                    localized: "Could not verify \(id) — \(message)",
                    comment: "Model setup: manual ID verification failed for a non-model reason")
                unverifiedManualId = id
            }
        }
    }

    private func saveManualModel(_ id: String) {
        guard let p = provider else { return }
        // Same bare-id collision guard as toggleModel — a manual entry
        // must not rewire another provider's model either.
        if let existing = config.model(for: id), existing.providerKey != p.key {
            manualVerifyMessage = String(
                localized: "\(id) is already configured under \(providerDisplayName(existing.providerKey)) — remove it there first.",
                comment: "Model setup: refusing to tick a model id that already exists under a different provider")
            unverifiedManualId = nil
            return
        }
        config.upsertModel(id: id, name: id, providerKey: p.key,
                           apiStyle: apiStyleForNewModels)
        if appState.activeModel == nil {
            appState.activeModel = config.defaultModel
        }
        manualModelId = ""
        manualVerifyMessage = nil
        unverifiedManualId = nil
    }

    private var apiStyleForNewModels: String {
        guard let p = provider else { return "openai" }
        if p.key == "openai" { return selectedApiStyle }
        return p.apiStyle == "anthropic" ? "anthropic" : "openai"
    }

    private func apiStyleRadioRow(_ label: String, value: String) -> some View {
        Button {
            selectedApiStyle = value
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selectedApiStyle == value ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selectedApiStyle == value ? SipDesign.blue : SipDesign.textSecondary)
                    .font(.system(size: 13))
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundColor(SipDesign.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadModels() async {
        guard let p = provider else { return }
        // Snapshot for the stale-response guard below: a slow fetch
        // must not land after "Change provider" and overwrite the newer
        // provider's list.
        fetchGeneration += 1
        let generation = fetchGeneration
        isFetching = true
        fetchError = nil
        fetchedModels = []
        noListNote = nil
        modelHighlight = 0
        showAllFetched = false

        let key = config.apiKey(for: p.key) ?? ""
        // A missing key is diagnosable without a network call — name
        // the exact variable that came up empty. Local servers are
        // exempt: they have no key, and never did.
        if key.isEmpty, !BuiltinProviderCatalog.endpointNeedsNoKey(p.baseURL) {
            if let env = config.provider(for: p.key)?.envVar, !env.isEmpty {
                fetchError = String(localized: "No API key: $\(env) is empty in both this app and your login shell. Fix the variable (then relaunch SipAI), or go back and paste a key.",
                                    comment: "Model setup: stored env var resolves to nothing")
            } else {
                fetchError = String(localized: "No API key stored for \(p.name). Go back and enter one.",
                                    comment: "Model setup: provider has no credentials")
            }
            isFetching = false
            return
        }

        // A provider with no list is not sent to fetch one. The call
        // would fail by construction, and a red error is the wrong way
        // to say "this provider needs the id typed" — the note goes up
        // with the field already carrying an example.
        if !p.listsModels {
            isFetching = false
            noListNote = BuiltinProviderCatalog.noListNote(for: p)
            if manualModelId.isEmpty, let example = p.exampleModelId {
                manualModelId = example
            }
            return
        }

        let result = await ModelFetcher.fetchDetailed(provider: p, apiKey: key)
        // Discard stale results — including spinner and error updates —
        // once a newer fetch or a provider switch has superseded this
        // call; the newer call owns all of that state now.
        guard !Task.isCancelled, generation == fetchGeneration,
              provider?.key == p.key else { return }
        isFetching = false
        fetchedModels = result.ids
        if let failure = result.failure {
            var message = String(localized: "Could not fetch models from \(p.name) — \(failure) Check the API key or environment variable, or enter a model ID manually below.",
                                 comment: "Model setup: fetch failed with a concrete reason")
            if p.regions.count > 1 {
                message += " " + String(localized: "Keys are region-bound — pick your key's region below and try again.",
                                        comment: "Model setup: fetch-failure hint for multi-region providers")
            }
            if let hint = BuiltinProviderCatalog.setupHints[p.key] {
                message += " " + hint
            }
            fetchError = message
        } else if result.ids.isEmpty {
            fetchError = String(localized: "\(p.name) listed no chat models. Enter a model ID manually below.",
                                comment: "Model setup: healthy response but empty list")
        }
    }

    /// Flip a multi-region provider to another endpoint after a failed
    /// fetch: persists the choice (with the stored credentials) so chat
    /// requests follow the same endpoint, then refetches.
    private func switchRegion(_ region: ProviderRegion) {
        guard let p = provider else { return }
        let updated = p.withBaseURL(region.baseURL)
        provider = updated
        selectedRegionURL = region.baseURL
        useCustomRegion = false
        if let existing = config.provider(for: p.key) {
            var refreshed = updated.toProviderConfig(apiKey: existing.apiKey)
            refreshed.envVar = existing.envVar
            config.upsertProvider(refreshed)
        }
        startModelFetch()
    }

    /// "+ Add more models" / "Change provider": everything ticked so far
    /// is already saved, so restarting the loop is just going back to
    /// the provider list.
    private func startAnotherProvider() {
        // "Change provider" stays clickable mid-fetch — kill the fetch
        // so its late result cannot bleed into the next provider.
        fetchTask?.cancel()
        fetchGeneration += 1
        isFetching = false
        provider = nil
        providerSearch = ""
        providerHighlight = 0
        withAnimation { phase = .provider }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            if phase != .provider {
                Button {
                    goBack()
                } label: {
                    Text("Back", comment: "Model setup: back button")
                        .font(.system(size: 13))
                        .foregroundColor(SipDesign.textSecondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button {
                primaryAction()
            } label: {
                Text(primaryLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
                    .background(primaryEnabled ? SipDesign.blue : SipDesign.blue.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(!primaryEnabled)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var primaryLabel: String {
        switch phase {
        case .provider, .models:
            return String(localized: "Done", comment: "Model setup: close the window")
        case .custom, .apiKey:
            return String(localized: "Continue", comment: "Model setup: advance to the next step")
        }
    }

    private var primaryEnabled: Bool {
        switch phase {
        case .provider, .models:
            return true
        case .custom:
            return !customName.trimmingCharacters(in: .whitespaces).isEmpty
                && !customURL.trimmingCharacters(in: .whitespaces).isEmpty
        case .apiKey:
            // "Other…" region selected but not filled in yet — nothing
            // sensible to continue to. And a raw entry (no template to
            // expand a bare code through) is stored verbatim as the
            // base URL, so it must parse as an http(s) URL.
            if useCustomRegion,
               effectiveRegionURL.isEmpty || !isValidHTTPBaseURL(effectiveRegionURL) {
                return false
            }
            if !showsRegionUI, !isValidHTTPBaseURL(resolvedBaseURL) { return false }
            // A typed env-var NAME counts — it need not resolve in this
            // process (Dock-launched apps don't see shell exports). And
            // a provider that already has stored credentials may
            // continue with both fields empty (= keep what's stored).
            return !apiKeyText.trimmingCharacters(in: .whitespaces).isEmpty
                || !envVarText.trimmingCharacters(in: .whitespaces).isEmpty
                || storedCredentialsExist
                // A local server has no key to type.
                || BuiltinProviderCatalog.endpointNeedsNoKey(resolvedBaseURL)
        }
    }

    private func primaryAction() {
        switch phase {
        case .provider, .models:
            if appState.activeModel == nil {
                appState.activeModel = config.defaultModel
            }
            dismiss()
        case .custom:
            continueFromCustom()
        case .apiKey:
            continueFromApiKey()
        }
    }

    private func goBack() {
        keyError = nil
        providerHighlight = 0
        switch phase {
        case .provider:
            break
        case .custom, .apiKey:
            withAnimation { phase = .provider }
        case .models:
            // ONE step back, to the key and endpoint — not all the way
            // to the provider list. This is the escape hatch from a
            // failed fetch: the credentials or the endpoint are what
            // need fixing, and the list is still one click away through
            // "Change provider" in the header above.
            editKeyAndEndpoint()
        }
    }

    /// Return to the key/endpoint page for the SAME provider, carrying
    /// its stored values. Deliberately not `resetFlowState`: that would
    /// throw away the region choice and the endpoint that were just
    /// used, which are exactly what the user came back to adjust.
    private func editKeyAndEndpoint() {
        guard provider != nil else { return }
        // A fetch still in flight must not land on the page the user
        // just left, or its error appears over the key they are typing.
        fetchTask?.cancel()
        fetchGeneration += 1
        isFetching = false
        keyError = nil
        // Empty means "keep what is stored" — pre-filling a stored
        // secret into a visible field is not something to do casually.
        apiKeyText = ""
        envVarText = ""
        if !showsRegionUI { showEndpointField = true }
        withAnimation { phase = .apiKey }
    }

    // MARK: - Small helpers

    private func labeledField(_ label: String, placeholder: String,
                              text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(SipDesign.textPrimary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(SipDesign.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(SipDesign.borderLight, lineWidth: 1)
                )
        }
    }

    private func providerDisplayName(_ key: String) -> String {
        if let p = BuiltinProviderCatalog.find(key) {
            return BuiltinProviderCatalog.localizedName(p)
        }
        return config.provider(for: key)?.name ?? key.capitalized
    }
}

// MARK: - Shared ⋯ menu for configured-model rows

/// "Set Default / Delete" menu shown next to every configured model —
/// in the setup window above AND in the composer's model selector.
/// One view so the active-model bookkeeping cannot diverge between the
/// two surfaces.
struct ModelRowActionsMenu: View {
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var appState: AppState
    let model: ModelConfig

    var body: some View {
        RowEllipsisMenu {
            Button {
                let previousDefault = config.defaultModel
                config.setDefaultModel(model.id)
                // The selector label follows the default unless the user
                // has explicitly switched to some other model.
                if appState.activeModel == nil || appState.activeModel == previousDefault {
                    appState.activeModel = model.id
                }
            } label: {
                Text("Set Default", comment: "Model row menu: make this the default model")
            }
            .disabled(model.id == config.defaultModel)
            Divider()
            Button(role: .destructive) {
                config.removeModel(id: model.id)
                if appState.activeModel == model.id {
                    appState.activeModel = config.defaultModel
                }
            } label: {
                Text("Delete", comment: "Model row menu: remove this model")
            }
        }
    }
}
