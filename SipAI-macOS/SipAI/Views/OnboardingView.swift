// OnboardingView.swift
// First-time setup wizard for the Mac app.
//   Welcome → Choose Provider → API Key → Default Model → Add Models
// Shown by ContentView whenever the user has zero models configured.

import SwiftUI

// BuiltinProvider, BuiltinProviderCatalog and ModelFetcher live in
// Models/ProviderCatalog.swift — shared with ModelSetupSheet.

// MARK: - Onboarding view

@MainActor
struct OnboardingView: View {
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var agents: AgentManager

    /// Explicit finish signal. ContentView latches the onboarding
    /// decision, so mid-wizard config writes cannot flip its gate —
    /// the ONLY way to leave the wizard is this callback (fired by
    /// Finish and by the agent-sessions Skip path).
    var onComplete: () -> Void = {}

    enum Step: Int, CaseIterable {
        case welcome = -1       // no progress dots
        case chooseProvider = 0
        case apiKey = 1
        case defaultModel = 2
        case addModels = 3

        /// Dotted steps, i.e. everything but the welcome page. The
        /// progress row and the dot-tap jump both read this, so adding
        /// or removing a step cannot leave a stale dot count behind.
        static var wizardCount: Int {
            allCases.filter { $0.rawValue >= 0 }.count
        }
    }

    @State private var step: Step = .welcome

    // Provider + API key state
    @State private var selectedProvider: BuiltinProvider? = nil
    @State private var apiKeyText: String = ""
    @State private var envVarText: String = ""
    @State private var keyError: String? = nil
    @State private var providerSearch: String = ""

    // Provider list collapse state
    @State private var providerListCollapsed: Bool = false

    // Pointer-over state for the wizard's one-off buttons. Row hover
    // lives in `hoverFill`, which carries its own per-row flag; these
    // are the buttons there is exactly one of on a page.
    @State private var getStartedHovered: Bool = false
    @State private var backHovered: Bool = false
    @State private var continueHovered: Bool = false
    @State private var changeProviderHovered: Bool = false
    @State private var skipHovered: Bool = false
    @State private var addModelHovered: Bool = false

    // Custom provider state
    @State private var showCustomProvider: Bool = false
    @State private var customName: String = ""
    @State private var customURL: String = ""

    // Image model management
    @State private var showImageModels: Bool = false

    // Model state
    @State private var fetchedModels: [String] = []
    @State private var manualModelId: String = ""
    @State private var pickedModelId: String? = nil
    @State private var isFetching: Bool = false
    @State private var fetchError: String? = nil
    @State private var selectedApiStyle: String = "openai"
    /// Invalidation for in-flight /models fetches: each fetch snapshots
    /// this counter and discards its result — list, error and spinner
    /// updates alike — if a newer fetch (or a provider switch) has
    /// bumped it since. Without it a slow stale response lands after
    /// the user switched provider and overwrites the newer list.
    @State private var fetchGeneration: Int = 0
    @State private var fetchTask: Task<Void, Never>? = nil

    // Add more models state (step 4 inline adding)
    @State private var isAddingModel: Bool = false
    @State private var addProvider: BuiltinProvider? = nil
    @State private var addApiKey: String = ""
    @State private var addEnvVar: String = ""
    @State private var addFetchedModels: [String] = []
    @State private var addPickedModelId: String? = nil
    @State private var addIsFetching: Bool = false
    @State private var addSubStep: AddSubStep = .provider
    /// Same stale-response guard as `fetchGeneration`, for the inline
    /// add-model flow's own fetches.
    @State private var addFetchGeneration: Int = 0
    @State private var addFetchTask: Task<Void, Never>? = nil

    enum AddSubStep { case provider, apiKey, model }

    // ↑ / ↓ / Return list navigation (see ListKeyMonitor).
    @State private var keyMonitor = ListKeyMonitor()
    @State private var providerHighlight: Int = 0
    @State private var modelHighlight: Int = 0

    /// The fetched list arrives newest-first; only the newest few show
    /// by default, with the back catalog behind "Show all N models".
    @State private var showAllFetched: Bool = false
    private static let fetchedCap = 15

    /// Endpoint choice for multi-region providers (Qwen, Moonshot,
    /// MiniMax, Volcengine, Z.AI).
    @State private var selectedRegionURL: String = ""
    /// "Other…" region entry: a region code when the provider has a
    /// URL template (none ship today), else a full base URL.
    @State private var useCustomRegion: Bool = false
    @State private var customRegionText: String = ""

    /// The endpoint the region choice resolves to; empty when "Other…"
    /// is selected but not filled in yet.
    private var effectiveRegionURL: String {
        guard let p = selectedProvider else { return "" }
        if useCustomRegion { return p.customRegionBaseURL(customRegionText) }
        return selectedRegionURL.isEmpty ? p.baseURL : selectedRegionURL
    }

    /// Whether this provider's endpoint is chosen from a list (or
    /// completed from a template) rather than typed freely.
    private var showsRegionUI: Bool {
        guard let p = selectedProvider else { return false }
        return p.regions.count > 1 || p.regionURLTemplate != nil
    }

    /// The base URL this step will actually store — the region choice
    /// where there is one, the Advanced endpoint otherwise. Mirrors
    /// `ModelSetupSheet.resolvedBaseURL`; both surfaces must store the
    /// same thing for the same input.
    private var resolvedBaseURL: String {
        guard let p = selectedProvider else { return "" }
        if showsRegionUI { return effectiveRegionURL }
        let typed = endpointText.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? p.baseURL : typed
    }

    private func isValidHTTPBaseURL(_ string: String) -> Bool {
        BuiltinProviderCatalog.isValidHTTPBaseURL(string)
    }

    // Manual model-ID verification.
    @State private var isVerifyingManual: Bool = false
    @State private var manualVerifyMessage: String? = nil
    @State private var unverifiedManualId: String? = nil
    /// Manual ids that passed verification (or were explicitly kept via
    /// "Use anyway") for the CURRENT provider — the only ids outside
    /// `fetchedModels` that `saveModelAndContinue` may accept.
    @State private var verifiedManualIds: Set<String> = []

    private var visibleFetchedModels: [String] {
        showAllFetched ? fetchedModels : Array(fetchedModels.prefix(Self.fetchedCap))
    }

    /// Whether the manual model-ID field has been asked for. The field
    /// is an escape hatch from the fetched list, so it stays out of the
    /// way until "Enter model ID manually" is clicked — except when
    /// there is no list to escape from (fetch failed or returned
    /// nothing), where it is the only way through the step.
    @State private var showManualEntry: Bool = false

    /// "Advanced → Endpoint" for providers with no region picker. Every
    /// provider gets one: a hosted URL is rarely worth changing, but a
    /// self-hosted proxy (LiteLLM) is unreachable without it.
    @State private var endpointText: String = ""
    @State private var showEndpointField: Bool = false
    /// Shown in place of a model list for a provider that publishes
    /// none — not an error.
    @State private var noListNote: String? = nil
    /// Rejection notice for providers whose `/models` is public, where
    /// a filled list is no evidence the key works (`ProviderKeyCheck`).
    @State private var keyCheckMessage: String? = nil
    @State private var keyCheckTask: Task<Void, Never>? = nil
    @State private var keyCheckedProviders: Set<String> = []

    // Inline "Add another model" flow — the same four concerns again,
    // because that flow is a second, independent copy of the steps.
    @State private var addEndpointText: String = ""
    @State private var addManualModelId: String = ""
    @State private var addNoListNote: String? = nil
    @State private var addKeyCheckMessage: String? = nil
    @State private var addIsVerifyingManual: Bool = false
    @State private var addManualVerifyMessage: String? = nil
    /// Set when the inline flow's probe failed for a non-model reason —
    /// enables "Add anyway", since the id may still be real.
    @State private var addUnverifiedManualId: String? = nil

    // Keyboard focus
    @FocusState private var focusedField: FocusField?
    enum FocusField: Hashable { case apiKey, envVar, manualModel, addApiKey, addEnvVar }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

            if step == .welcome {
                welcomeView
                    .transition(.opacity)
            } else {
                wizardView
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
        .onAppear {
            agents.reload(config: config)
            keyMonitor.install(handleListKey)
        }
        .onDisappear { keyMonitor.remove() }
    }

    /// Keyboard list navigation: arrows move the highlight of whichever
    /// list the current step shows; Return takes the highlighted row.
    /// On the model step a second Return (row already picked) falls
    /// through to the Continue button.
    private func handleListKey(_ key: ListKeyMonitor.Key,
                               whileEditing: Bool) -> Bool {
        switch step {
        case .chooseProvider:
            guard !providerListCollapsed else { return false }
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
                guard rows.indices.contains(providerHighlight) else { return false }
                selectProvider(rows[providerHighlight])
                return true
            }
        case .defaultModel:
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
                if pickedModelId == id { return false }
                pickedModelId = id
                manualModelId = ""
                return true
            }
        default:
            return false
        }
    }

    /// Arrow-navigable provider rows, in exactly the order they render.
    private var navProviders: [BuiltinProvider] { filteredCloudProviders }

    // MARK: - Welcome page (no dots, no traffic lights)

    private var welcomeView: some View {
        VStack(spacing: 0) {
            Spacer()

            // The 12pt spacer sits *above* the logo inside the centered content stack
            Spacer().frame(height: 12)

            // Logo — tight-cropped asset, drawn at 86pt.
            // Size-matched rendition — see LeftSidebar's brand header.
            Image("SipAI-Logo-86")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: 86)

            // Larger breathing room between logo and title
            Spacer().frame(height: 12)

            Text("Welcome to SipAI")
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(SipDesign.textPrimary)
                .tracking(-0.4)

            Text("Your AI chat, your way.")
                .font(.system(size: 14))
                .foregroundColor(SipDesign.textSecondary)

            Spacer().frame(height: 32)

            // Feature bullets
            VStack(alignment: .leading, spacing: 18) {
                // `featureRow` takes plain `String`s, so a bare literal at the
                // call site reaches SwiftUI's non-localizing `Text(_: String)`
                // overload and ships in English whatever the language. These
                // are localized HERE, where the literal still exists.
                featureRow(
                    icon: "globe",
                    title: String(localized: "All providers, one app",
                                  comment: "Onboarding welcome bullet title"),
                    desc: String(localized: "Chat with GPT, Claude, Kimi, and more in one place with your API keys.",
                                 comment: "Onboarding welcome bullet detail")
                )
                featureRow(
                    icon: "terminal",
                    title: String(localized: "Better local AI agent management",
                                  comment: "Onboarding welcome bullet title"),
                    desc: String(localized: "Manage all your local AI agentic sessions inside one app with efficient workflows.",
                                 comment: "Onboarding welcome bullet detail")
                )
                featureRow(
                    icon: "checkmark.shield",
                    title: String(localized: "Your data, your control",
                                  comment: "Onboarding welcome bullet title"),
                    desc: String(localized: "No sign-up required, no data collection, no tracking from the app. Your data is just between you and the AI.",
                                 comment: "Onboarding welcome bullet detail")
                )
            }
            .frame(maxWidth: 420, alignment: .leading)

            Spacer().frame(height: 36)

            // Get started button — 14pt font, 49/11 padding
            Button {
                withAnimation { step = .chooseProvider }
            } label: {
                Text("Get started")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 49)
                    .padding(.vertical, 11)
                    .background(getStartedHovered ? SipDesign.blueHover : SipDesign.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
            .onHover { getStartedHovered = $0 }

            Spacer()
        }
        // Single flexible frame so top/bottom Spacer() actually expand in tall
        // windows. Chaining a second .frame(maxWidth:) here would give the
        // VStack an intrinsic height and collapse the Spacers.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private func featureRow(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(SipDesign.iconCircleBg)
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(SipDesign.blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SipDesign.textPrimary)
                Text(desc)
                    .font(.system(size: 12.5))
                    .foregroundColor(SipDesign.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Wizard container (steps 1–5 with progress dots)

    private var wizardView: some View {
        VStack(spacing: 0) {
            // Content area — single flexible frame so inner Spacer()s expand.
            Group {
                switch step {
                case .welcome: EmptyView()
                case .chooseProvider: providerStepView
                case .apiKey: apiKeyStepView
                case .defaultModel: modelStepView
                case .addModels: addModelsStepView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom bar — 32pt side inset, 48pt from frame bottom
            bottomBar
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
        }
        .ignoresSafeArea()
    }

    private var bottomBar: some View {
        // ZStack ensures dots are mathematically centered regardless of
        // Back/Continue widths (HStack + Spacer would drift off-center).
        ZStack {
            HStack(spacing: 0) {
                if step != .chooseProvider {
                    Button("Back") { goBack() }
                        .buttonStyle(.plain)
                        .foregroundColor(backHovered ? SipDesign.textPrimary
                                                     : SipDesign.textSecondary)
                        .font(.system(size: 14))
                        .onHover { backHovered = $0 }
                }
                Spacer()
                Button {
                    handleContinue()
                } label: {
                    Text(step == .addModels ? "Finish" : "Continue")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 10)
                        // A disabled Continue still receives hover events,
                        // so the shade is gated on the same flag that
                        // gates the click.
                        .background(continueEnabled
                                    ? (continueHovered ? SipDesign.blueHover : SipDesign.blue)
                                    : SipDesign.blue.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!continueEnabled)
                .onHover { continueHovered = $0 && continueEnabled }
                .keyboardShortcut(.return, modifiers: [])
            }

            // Centered progress dots — future dots are stroke-only #D1D5DB
            HStack(spacing: 8) {
                ForEach(0..<Step.wizardCount, id: \.self) { i in
                    let isCurrent = i == step.rawValue
                    let isCompleted = i < step.rawValue
                    Group {
                        if isCompleted || isCurrent {
                            Circle().fill(SipDesign.blue)
                        } else {
                            // Adaptive unselected-dot stroke — #D1D5DB in light,
                            // lighter grey in dark so the dots stay visible.
                            Circle().strokeBorder(SipDesign.borderLight, lineWidth: 1)
                        }
                    }
                    .frame(width: isCurrent ? 10 : 8, height: isCurrent ? 10 : 8)
                    .onTapGesture {
                        guard i < step.rawValue, let target = Step(rawValue: i) else { return }
                        if target == .chooseProvider { providerListCollapsed = false }
                        withAnimation { step = target }
                    }
                }
            }
        }
    }

    // MARK: - Step 1: Choose Provider

    /// Agents worth pitching on this page: not yet seen, AND runnable.
    /// `unseenAgents` alone also counts store-only agents (sessions on
    /// disk, no CLI on PATH), which land in the read-only tier — the
    /// hint promises interaction "without an additional API key" and
    /// the Skip button promises a usable app, and neither is true of a
    /// session store nobody can send to.
    private var hintAgents: [AgentInfo] {
        agents.unseenAgents.filter { agents.isAgentInstalled($0.key) }
    }

    private var providerStepView: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("Choose your chat provider")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(SipDesign.textPrimary)

            Text("Select a provider to get started.")
                .font(.system(size: 13))
                .foregroundColor(SipDesign.textSecondary)

            // Agent CLI detection hint
            if !hintAgents.isEmpty {
                let names = hintAgents.map(\.name)
                let nameStr = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
                VStack(alignment: .leading, spacing: 4) {
                    Text("💡 \(nameStr) detected. You can directly interact with \(names.count == 1 ? names[0] : "them") from SipAI without an additional API key.")
                        .font(.system(size: 12.5))
                        .foregroundColor(SipDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(width: 420, alignment: .leading)
                .background(SipDesign.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.top, 12)
            }

            Spacer().frame(height: 20)

            if providerListCollapsed, let p = selectedProvider {
                // ── Collapsed: selected provider card ──
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(BuiltinProviderCatalog.localizedName(p))
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(SipDesign.textPrimary)
                            Text(p.baseURL)
                                .font(.system(size: 11))
                                .foregroundColor(SipDesign.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(SipDesign.blue)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .frame(width: 420)
                .background(SipDesign.cardSelectedBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(SipDesign.blue, lineWidth: 2)
                )

                Spacer().frame(height: 12)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { providerListCollapsed = false }
                } label: {
                    Text("Change provider")
                        .font(.system(size: 13))
                        .foregroundColor(changeProviderHovered ? SipDesign.textPrimary
                                                               : SipDesign.textSecondary)
                }
                .buttonStyle(.plain)
                .onHover { changeProviderHovered = $0 }
            } else {
                // ── Expanded: search bar + provider list ──

                // Search bar — 420×40
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(SipDesign.textHint)
                    TextField("Search providers", text: $providerSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(SipDesign.textPrimary)
                }
                .padding(.horizontal, 14)
                .frame(width: 420, height: 40)
                .background(SipDesign.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(SipDesign.borderLight, lineWidth: 1)
                )

                Spacer().frame(height: 12)

                // Scrollable list with sections, clipped to 260pt
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            // Cloud providers (no section header)
                            ForEach(filteredCloudProviders) { p in
                                providerListRow(p)
                            }
                            // Image Models + Custom
                            if providerSearch.isEmpty {
                                providerSectionHeader("Other")
                                providerActionRow("Image Models", icon: "photo") {
                                    showImageModels = true
                                }
                                providerActionRow("Custom (name & URL)", icon: "plus.circle") {
                                    showCustomProvider = true
                                }
                            }
                        }
                    }
                    .onChange(of: providerHighlight) { _, idx in
                        let rows = navProviders
                        if rows.indices.contains(idx) {
                            proxy.scrollTo("prov-\(rows[idx].key)")
                        }
                    }
                    .onChange(of: providerSearch) { _, _ in
                        providerHighlight = 0
                    }
                }
                .frame(width: 420, height: 260)
                .background(SipDesign.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(SipDesign.borderLight, lineWidth: 1)
                )
            }

            // "Skip — agent sessions only" button. Gated on an agent CLI
            // being INSTALLED, not on `unseenAgents`: the button is the
            // only way out of the wizard without an API key, so it must
            // not depend on whether a first-run hint was dismissed, and
            // it must not offer a mode that would open read-only.
            if agents.hasInstalledAgent {
                Spacer().frame(height: 16)

                Button {
                    skipToAgentSessions()
                } label: {
                    Text("Skip — agent sessions only")
                        .font(.system(size: 13))
                        .foregroundColor(skipHovered ? SipDesign.textPrimary
                                                     : SipDesign.textSecondary)
                }
                .buttonStyle(.plain)
                .onHover { skipHovered = $0 }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showCustomProvider) {
            customProviderSheet
        }
        .sheet(isPresented: $showImageModels) {
            imageModelSheet
        }
    }

    // MARK: - Custom Provider Sheet

    private var customProviderSheet: some View {
        VStack(spacing: 16) {
            Text("Custom Provider")
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Provider name")
                    .font(.system(size: 12))
                    .foregroundColor(SipDesign.textSecondary)
                TextField("e.g. My Server", text: $customName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API base URL")
                    .font(.system(size: 12))
                    .foregroundColor(SipDesign.textSecondary)
                TextField("e.g. https://api.example.com/v1", text: $customURL)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    showCustomProvider = false
                    customName = ""
                    customURL = ""
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
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
                    selectProvider(custom)
                    // selectProvider seeds the endpoint from what is
                    // STORED under this key; the URL just typed here is
                    // newer than that and has to win.
                    endpointText = url
                    showCustomProvider = false
                    customName = ""
                    customURL = ""
                    withAnimation { step = .apiKey }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    customName.trimmingCharacters(in: .whitespaces).isEmpty ||
                    customURL.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 380)
    }

    // MARK: - Image Model Sheet

    private var imageModelSheet: some View {
        VStack(spacing: 16) {
            Text("Image Models")
                .font(.system(size: 16, weight: .semibold))

            Text("Configure image generation models.")
                .font(.system(size: 13))
                .foregroundColor(SipDesign.textSecondary)

            VStack(spacing: 0) {
                imageModelCatalogRow(provider: "openai", providerName: "OpenAI (GPT Image)", models: [
                    ("gpt-image-1.5",    "best quality"),
                    ("gpt-image-1",      "balanced"),
                    ("gpt-image-1-mini", "fast, cheap"),
                ])
                imageModelCatalogRow(provider: "google", providerName: "Google (Imagen)", models: [
                    ("imagen-3.0-generate-002", "Imagen 3"),
                ])
            }
            .background(SipDesign.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(SipDesign.borderLight, lineWidth: 1)
            )

            Text("Image models require an API key from the same provider.\nYou can also set these up later in Settings.")
                .font(.system(size: 11))
                .foregroundColor(SipDesign.textHint)
                .multilineTextAlignment(.center)

            Button("Done") {
                showImageModels = false
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 400)
    }

    private func imageModelCatalogRow(provider: String, providerName: String, models: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(providerName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(SipDesign.textSecondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(models, id: \.0) { mid, desc in
                let isAdded = config.imageModels.contains(where: { $0.id == mid })
                Button {
                    if isAdded {
                        config.removeImageModel(id: mid)
                    } else {
                        config.upsertImageModel(id: mid, name: mid, providerKey: provider)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mid).font(.system(size: 13))
                            Text(desc).font(.system(size: 11)).foregroundColor(SipDesign.textHint)
                        }
                        Spacer()
                        if isAdded {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(SipDesign.blue)
                        } else {
                            Image(systemName: "plus.circle")
                                .foregroundColor(SipDesign.textHint)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Cloud providers sorted alphabetically, filtered by search query.
    private var filteredCloudProviders: [BuiltinProvider] {
        let cloud = BuiltinProviderCatalog.cloudSorted
        let q = providerSearch.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return cloud }
        return cloud.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private func providerSectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(SipDesign.textSecondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func providerActionRow(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(SipDesign.blue)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(SipDesign.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(SipDesign.textHint)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .overlay(
                Rectangle()
                    .fill(SipDesign.borderLight.opacity(0.6))
                    .frame(height: 1),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
        .hoverFill()
    }

    private func providerListRow(_ p: BuiltinProvider) -> some View {
        let isSelected = selectedProvider?.key == p.key
        let highlighted = navProviders.indices.contains(providerHighlight)
            && navProviders[providerHighlight].key == p.key
        return Button {
            selectProvider(p)
        } label: {
            HStack(spacing: 0) {
                Text(BuiltinProviderCatalog.localizedName(p))
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? SipDesign.blue : SipDesign.textPrimary)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(SipDesign.blue)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(isSelected ? SipDesign.cardSelectedBg
                        : (highlighted ? Color.gray.opacity(0.12) : Color.clear))
            .overlay(
                Rectangle()
                    .fill(SipDesign.borderLight.opacity(0.6))
                    .frame(height: 1),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
        .hoverFill()
        .id("prov-\(p.key)")
    }

    private func selectProvider(_ p: BuiltinProvider) {
        selectedProvider = p
        // Same rule as the model list: the keyboard cursor follows the
        // pointer, or its grey stays on the row it was last on and shows
        // up next to the blue one when the list is reopened with
        // "Change provider". A custom provider isn't in the list, so
        // there is nothing to move to.
        if let idx = navProviders.firstIndex(where: { $0.key == p.key }) {
            providerHighlight = idx
        }
        apiKeyText = ""
        // The provider's usual variable is only a placeholder hint —
        // pre-filled text would read as "already configured".
        envVarText = ""
        keyError = nil
        selectedRegionURL = p.baseURL
        // A URL template with no region list is a path to COMPLETE, not
        // a choice — the field is the only way through, so it opens
        // straight away. No shipping provider takes that path now.
        useCustomRegion = p.regions.isEmpty && p.regionURLTemplate != nil
        customRegionText = ""
        // The endpoint field carries what is stored and OPENS itself
        // when that is not the catalog default — a customized endpoint
        // hidden behind a disclosure reads as the usual host.
        let storedURL = config.provider(for: p.key)?.baseURL
        endpointText = storedURL ?? p.baseURL
        showEndpointField = (storedURL != nil && storedURL != p.baseURL)
        noListNote = nil
        keyCheckTask?.cancel()
        keyCheckMessage = nil
        isVerifyingManual = false
        manualVerifyMessage = nil
        unverifiedManualId = nil
        // A provider switch invalidates every trace of the previous
        // provider's model step. A stale pick would otherwise survive to
        // saveModelAndContinue and store provider A's model id under
        // provider B (404 on every chat); loadModels only auto-picks
        // when pickedModelId is nil, so it never healed itself.
        fetchTask?.cancel()
        fetchGeneration += 1
        pickedModelId = nil
        fetchedModels = []
        manualModelId = ""
        fetchError = nil
        verifiedManualIds = []
        modelHighlight = 0
        showAllFetched = false
        showManualEntry = false
        withAnimation(.easeInOut(duration: 0.2)) { providerListCollapsed = true }
    }

    // MARK: - Step 2: API Key

    private var apiKeyStepView: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("Enter your API key")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(SipDesign.textPrimary)

            Text("for \(BuiltinProviderCatalog.localizedName(selectedProvider, fallback: "Provider"))")
                .font(.system(size: 13))
                .foregroundColor(SipDesign.blue)

            Spacer().frame(height: 32)

            VStack(alignment: .leading, spacing: 0) {
                // Region FIRST — only the user knows which region their
                // key belongs to; the wrong endpoint 401s a good key.
                if let p = selectedProvider,
                   p.regions.count > 1 || p.regionURLTemplate != nil {
                    // A template with no region list means the URL is a
                    // path to COMPLETE, not one of several endpoints to
                    // choose between — so the field stands alone. No
                    // shipping provider takes that path now.
                    let completesPath = p.regions.isEmpty
                    Text(completesPath ? "Endpoint" : "Region")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(SipDesign.textPrimary)
                    Spacer().frame(height: 6)
                    VStack(alignment: .leading, spacing: 8) {
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
                                            .font(.system(size: 14))
                                        Text(region.label)
                                            .font(.system(size: 13))
                                            .foregroundColor(SipDesign.textPrimary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            Button {
                                useCustomRegion = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: useCustomRegion ? "largecircle.fill.circle" : "circle")
                                        .foregroundColor(useCustomRegion ? SipDesign.blue : SipDesign.textSecondary)
                                        .font(.system(size: 14))
                                    Text("Other…")
                                        .font(.system(size: 13))
                                        .foregroundColor(SipDesign.textPrimary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if useCustomRegion {
                            FocusClearingField(
                                placeholder: completesPath
                                    ? "account-tag/gateway-name"
                                    : (p.regionURLTemplate != nil
                                       ? "Region code, e.g. eu-west-3" : "https://…"),
                                text: $customRegionText
                            )
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(SipDesign.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(SipDesign.borderLight, lineWidth: 1)
                            )
                            .padding(.leading, completesPath ? 0 : 22)
                            // Raw text becomes the base URL verbatim when
                            // no template expands it — refuse non-URLs
                            // here instead of storing "beijing".
                            if !customRegionText.trimmingCharacters(in: .whitespaces).isEmpty,
                               !isValidHTTPBaseURL(effectiveRegionURL) {
                                Text(completesPath
                                     ? "Enter your account tag and gateway name, like account-tag/gateway-name."
                                     : (p.regionURLTemplate != nil
                                        ? "Enter a region code like eu-west-3, or a full https:// URL."
                                        : "Enter a full URL starting with http:// or https://."))
                                    .font(.system(size: 11))
                                    .foregroundColor(.red)
                                    .padding(.leading, completesPath ? 0 : 22)
                            }
                        }
                    }
                    Spacer().frame(height: 16)
                }

                // Free-text endpoint for everything the region picker
                // above does not cover. Folded away by default; open
                // when the stored URL is not the catalog default.
                if let p = selectedProvider, !showsRegionUI {
                    Button {
                        withAnimation { showEndpointField.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showEndpointField ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Endpoint")
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
                        Spacer().frame(height: 6)
                        FocusClearingField(placeholder: p.baseURL, text: $endpointText)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .background(SipDesign.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(SipDesign.borderLight, lineWidth: 1)
                            )
                        if !isValidHTTPBaseURL(resolvedBaseURL) {
                            Text("Enter a full URL starting with http:// or https://.")
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                                .padding(.top, 4)
                        }
                    }
                    Spacer().frame(height: 16)
                }

                // API Key field
                Text("API Key from \(BuiltinProviderCatalog.localizedName(selectedProvider, fallback: "Provider"))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SipDesign.textPrimary)
                Spacer().frame(height: 6)
                FocusClearingField(placeholder: String(localized: "Paste your API key"),
                                   text: $apiKeyText,
                                   secure: true)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(SipDesign.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(SipDesign.borderLight, lineWidth: 1)
                    )

                // Which key — Z.AI issues one per platform, and only
                // one of them takes yours.
                if let note = selectedProvider?.keyFieldNote {
                    Spacer().frame(height: 6)
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(SipDesign.textHint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer().frame(height: 16)

                // "or" divider
                HStack(spacing: 12) {
                    Rectangle().fill(SipDesign.borderLight).frame(height: 1)
                    Text("or")
                        .font(.system(size: 12))
                        .foregroundColor(SipDesign.textHint)
                    Rectangle().fill(SipDesign.borderLight).frame(height: 1)
                }

                Spacer().frame(height: 16)

                // Environment variable field
                Text("Use environment variable")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SipDesign.textPrimary)
                Spacer().frame(height: 6)
                FocusClearingField(placeholder: envVarPlaceholder,
                                   text: $envVarText)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(SipDesign.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(SipDesign.borderLight, lineWidth: 1)
                    )

                Spacer().frame(height: 12)

                // Hint
                if let p = selectedProvider {
                    Text("Get your API key from \(apiKeyHint(for: p.key))")
                        .font(.system(size: 11))
                        .foregroundColor(SipDesign.textSecondary)
                }

                if let err = keyError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: 420)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The provider's usual variable name, offered as a hint only.
    private var envVarPlaceholder: String {
        if let suggestion = selectedProvider?.envVar, !suggestion.isEmpty {
            return "e.g. \(suggestion)"
        }
        return "e.g. OPENAI_API_KEY"
    }

    private func apiKeyHint(for key: String) -> String {
        switch key {
        case "openai": return "platform.openai.com"
        case "anthropic": return "console.anthropic.com"
        case "google": return "aistudio.google.com"
        case "deepseek": return "platform.deepseek.com"
        case "groq": return "console.groq.com"
        case "mistral": return "console.mistral.ai"
        case "xai": return "console.x.ai"
        default: return "your provider's dashboard"
        }
    }

    // MARK: - Step 3: Default Model

    private var modelStepView: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("Set your default chat model")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(SipDesign.textPrimary)

            Text("for \(BuiltinProviderCatalog.localizedName(selectedProvider, fallback: "Provider"))")
                .font(.system(size: 13))
                .foregroundColor(SipDesign.textSecondary)

            Spacer().frame(height: 20)

            if isFetching {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Fetching models…")
                        .font(.system(size: 13))
                        .foregroundColor(SipDesign.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            } else if !fetchedModels.isEmpty {
                // Scrollable model list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleFetchedModels, id: \.self) { id in
                                modelRow(id)
                            }

                            if !showAllFetched,
                               fetchedModels.count > Self.fetchedCap {
                                Button {
                                    showAllFetched = true
                                } label: {
                                    HStack {
                                        Text("Show all \(fetchedModels.count) models")
                                            .font(.system(size: 13))
                                            .foregroundColor(SipDesign.blue)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .hoverFill()
                            }

                            // Manual entry row — reveals the field below.
                            // Stays visible once open so a second click
                            // re-focuses the field rather than the row
                            // disappearing under the pointer.
                            Button {
                                showManualEntry = true
                                // The field is CREATED by this state
                                // change, so it cannot take focus in the
                                // same pass — ask once it has been laid
                                // out.
                                DispatchQueue.main.async { focusedField = .manualModel }
                            } label: {
                                HStack {
                                    Text("Enter model ID manually")
                                        .font(.system(size: 13))
                                        .foregroundColor(SipDesign.blue)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .hoverFill()
                        }
                    }
                    .onChange(of: modelHighlight) { _, idx in
                        if fetchedModels.indices.contains(idx) {
                            proxy.scrollTo("model-\(fetchedModels[idx])")
                        }
                    }
                }
                .frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(SipDesign.borderLight, lineWidth: 1)
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    // Information, not a failure: this provider simply
                    // publishes no list, so no fetch was attempted.
                    if let note = noListNote {
                        Label(note, systemImage: "info.circle")
                            .foregroundColor(SipDesign.textSecondary)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let e = fetchError {
                        Label(e, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                            .font(.system(size: 12))
                    }
                    Text("Enter a model ID below.")
                        .foregroundColor(SipDesign.textSecondary)
                        .font(.system(size: 13))
                    // The other half of the escape hatch: if the fetch
                    // failed, the key or the endpoint is what needs
                    // fixing, and the field for both is one step back.
                    if fetchError != nil {
                        Text("The endpoint may not be up to date — editing it could solve this.")
                            .font(.system(size: 11))
                            .foregroundColor(SipDesign.textHint)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Edit key or endpoint") {
                            fetchTask?.cancel()
                            fetchGeneration += 1
                            isFetching = false
                            apiKeyText = ""
                            envVarText = ""
                            if !showsRegionUI { showEndpointField = true }
                            withAnimation { step = .apiKey }
                        }
                        .font(.system(size: 12))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Manual model entry — verified with a 1-token probe before
            // it counts, so a typo cannot become the default model.
            // Shown on request, or unconditionally when there is no
            // fetched list (the "Enter a model ID below." branch above
            // has no button to offer).
            if showManualEntry || (!isFetching && fetchedModels.isEmpty) {
                HStack(spacing: 8) {
                    // No placeholder: an example id reads as a value
                    // that is already filled in. The label is carried
                    // for VoiceOver only.
                    TextField("", text: $manualModelId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .accessibilityLabel(Text("Model ID"))
                        .focused($focusedField, equals: .manualModel)
                        .onSubmit { verifyAndUseManualModel() }
                        .disabled(isVerifyingManual)
                    if isVerifyingManual {
                        ProgressView().controlSize(.small)
                    } else if !manualModelId.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Use") {
                            verifyAndUseManualModel()
                        }
                        .font(.system(size: 13))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            }

            if let message = manualVerifyMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if let pending = unverifiedManualId {
                        // String expression, not an interpolated literal:
                        // that overload markdown-parses, and model ids
                        // carry active characters (meta-llama/Llama-3.1_8B).
                        Button(String(localized: "Use \(pending) anyway",
                                      comment: "Keep an unverified manually typed model id")) {
                            verifiedManualIds.insert(pending)
                            pickedModelId = pending
                            manualVerifyMessage = nil
                            unverifiedManualId = nil
                        }
                        .font(.system(size: 11))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }

            if let warning = keyCheckMessage {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }

            // API Style (OpenAI only)
            if selectedProvider?.key == "openai" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("API Style")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(SipDesign.textPrimary)

                    VStack(alignment: .leading, spacing: 8) {
                        radioRow("Chat Completions (standard)", value: "openai", selected: $selectedApiStyle)
                        radioRow("Responses API (advanced)", value: "openai-responses", selected: $selectedApiStyle)
                    }

                    Text("Required for some models like GPT-5.4 Pro")
                        .font(.system(size: 11))
                        .foregroundColor(SipDesign.textHint)
                }
                .padding(.top, 14)
            }

            Spacer()
        }
        .frame(maxWidth: 420, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }

    private func modelRow(_ id: String) -> some View {
        let highlighted = fetchedModels.indices.contains(modelHighlight)
            && fetchedModels[modelHighlight] == id
        return VStack(spacing: 0) {
            Button {
                pickedModelId = id
                manualModelId = ""
                // Move the keyboard cursor to what the pointer just
                // picked. Left behind, its grey sits on whatever row it
                // was last on — row 0 at first paint, which the auto-pick
                // makes blue and the click then unmasks — and two shaded
                // rows read as two selections. Indexes into
                // `fetchedModels`, not the visible slice, because that is
                // what the arrow keys walk.
                if let idx = fetchedModels.firstIndex(of: id) {
                    modelHighlight = idx
                }
            } label: {
                HStack {
                    Text(id)
                        .font(.system(size: 13))
                        .foregroundColor(pickedModelId == id ? SipDesign.blue : SipDesign.textPrimary)
                    Spacer()
                    if pickedModelId == id {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(SipDesign.blue)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(pickedModelId == id ? SipDesign.cardSelectedBg
                            : (highlighted ? Color.gray.opacity(0.12) : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverFill()
            Divider().padding(.leading, 16)
        }
        .id("model-\(id)")
    }

    private func radioRow(_ label: String, value: String, selected: Binding<String>) -> some View {
        Button {
            selected.wrappedValue = value
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected.wrappedValue == value ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected.wrappedValue == value ? SipDesign.blue : SipDesign.textSecondary)
                    .font(.system(size: 14))
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(SipDesign.textPrimary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 4: Add More Models

    private var addModelsStepView: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("Your chat models")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(SipDesign.textPrimary)

            Text("Add more chat models from the same or different providers.")
                .font(.system(size: 13))
                .foregroundColor(SipDesign.textSecondary)

            Spacer().frame(height: 24)

            // Configured models list
            VStack(spacing: 8) {
                ForEach(config.models) { m in
                    OnboardingModelRow(
                        model: m,
                        providerLabel: providerDisplayName(m.providerKey)
                    )
                }
            }

            // The inline flow's key probe reports HERE rather than in
            // the panel, which is already closed by the time it answers.
            if let warning = addKeyCheckMessage {
                Spacer().frame(height: 12)
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer().frame(height: 16)

            // Add another model button (or inline flow)
            if isAddingModel {
                inlineAddModelView
            } else {
                Button {
                    isAddingModel = true
                    addSubStep = .provider
                    addProvider = nil
                    addApiKey = ""
                    addEnvVar = ""
                    addEndpointText = ""
                    addFetchedModels = []
                    addPickedModelId = nil
                    addManualModelId = ""
                    addNoListNote = nil
                    addManualVerifyMessage = nil
                    addUnverifiedManualId = nil
                    addKeyCheckMessage = nil
                } label: {
                    HStack {
                        Spacer()
                        Text("+ Add another model")
                            .font(.system(size: 13))
                            .foregroundColor(addModelHovered ? SipDesign.textPrimary
                                                             : SipDesign.textSecondary)
                        Spacer()
                    }
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(addModelHovered ? Color.gray.opacity(0.08) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                            .foregroundColor(addModelHovered ? SipDesign.textHint
                                                             : SipDesign.borderLight)
                    )
                    // The strip is mostly Spacer — without this only the
                    // label itself would take the click.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { addModelHovered = $0 }
            }

            Spacer()
        }
        .frame(maxWidth: 420, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }

    private var inlineAddModelView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            switch addSubStep {
            case .provider:
                Text("Select provider")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SipDesign.textSecondary)
                ScrollView {
                    VStack(spacing: 4) {
                        // Same order as the provider step: alphabetical.
                        ForEach(BuiltinProviderCatalog.cloudSorted) { p in
                            addProviderRow(p)
                        }
                    }
                }
                .frame(maxHeight: 160)

            case .apiKey:
                Text("API key for \(BuiltinProviderCatalog.localizedName(addProvider, fallback: ""))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SipDesign.textSecondary)
                SecureField("Paste API key", text: $addApiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($focusedField, equals: .addApiKey)

                if let note = addProvider?.keyFieldNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(SipDesign.textHint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Endpoint. Always shown here rather than hidden behind
                // a disclosure: this flow has no region picker at all,
                // so for Qwen, Moonshot, Z.AI or a self-hosted proxy
                // it is the ONLY way to reach the right host.
                Text("Endpoint")
                    .font(.system(size: 11))
                    .foregroundColor(SipDesign.textSecondary)
                TextField(addProvider?.baseURL ?? "", text: $addEndpointText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                if !addEndpointText.trimmingCharacters(in: .whitespaces).isEmpty,
                   !isValidHTTPBaseURL(addEndpointText.trimmingCharacters(in: .whitespaces)) {
                    Text("Enter a full URL starting with http:// or https://.")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }

                // The same either/or the main API-key step offers. A
                // variable NAME is enough on its own — `apiKey(for:)`
                // resolves it ahead of any stored key at request time,
                // and it need not resolve in THIS process (a
                // Dock-launched app sees no shell exports).
                HStack(spacing: 10) {
                    Rectangle().fill(SipDesign.borderLight).frame(height: 1)
                    Text("or")
                        .font(.system(size: 11))
                        .foregroundColor(SipDesign.textHint)
                    Rectangle().fill(SipDesign.borderLight).frame(height: 1)
                }
                Text("Use environment variable")
                    .font(.system(size: 11))
                    .foregroundColor(SipDesign.textSecondary)
                TextField(addEnvVarPlaceholder, text: $addEnvVar)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($focusedField, equals: .addEnvVar)

                Button("Continue") {
                    saveAddProvider()
                    addSubStep = .model
                    addFetchTask?.cancel()
                    addFetchTask = Task { await loadModelsForAdd() }
                }
                // Both fields empty is allowed when there is already
                // something to keep — otherwise coming back here just
                // to change the ENDPOINT would demand the key be
                // retyped, and it is not on screen to copy.
                .disabled((addApiKey.trimmingCharacters(in: .whitespaces).isEmpty
                           && addEnvVar.trimmingCharacters(in: .whitespaces).isEmpty
                           && !addProviderHasStoredCredentials
                           && !BuiltinProviderCatalog.endpointNeedsNoKey(addResolvedBaseURL))
                          || !isValidHTTPBaseURL(addResolvedBaseURL))
                .font(.system(size: 13))

            case .model:
                Text("Select model from \(BuiltinProviderCatalog.localizedName(addProvider, fallback: ""))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SipDesign.textSecondary)
                if addIsFetching {
                    ProgressView().controlSize(.small)
                } else {
                    // No list to pick from — this provider publishes
                    // none, or the fetch came back empty.
                    if let note = addNoListNote {
                        Label(note, systemImage: "info.circle")
                            .font(.system(size: 11))
                            .foregroundColor(SipDesign.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // Same hint as the other two surfaces: a base
                        // URL this app shipped with can be out of date,
                        // and that looks like a bad key from here.
                        Text("The endpoint may not be up to date — editing it could solve this.")
                            .font(.system(size: 11))
                            .foregroundColor(SipDesign.textHint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Only when there is something in it — an empty
                    // 120pt box under "publishes no model list" reads
                    // as a list that failed to load.
                    if !addFetchedModels.isEmpty {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(addFetchedModels, id: \.self) { id in
                                Button {
                                    addPickedModelId = id
                                } label: {
                                    HStack {
                                        Text(id).font(.system(size: 12, design: .monospaced))
                                        Spacer()
                                        if addPickedModelId == id {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11))
                                                .foregroundColor(SipDesign.blue)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(addPickedModelId == id ? SipDesign.cardSelectedBg : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .hoverFill(cornerRadius: 6)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                    }

                    // Manual entry, verified with the same 1-token
                    // probe the main step uses, so a typo cannot become
                    // a configured model here either.
                    HStack(spacing: 6) {
                        TextField("Or enter a model ID", text: $addManualModelId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .disabled(addIsVerifyingManual)
                            .onSubmit { verifyAndAddManualModel() }
                        if addIsVerifyingManual {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Add") { verifyAndAddManualModel() }
                                .font(.system(size: 12))
                                .disabled(addManualModelId
                                    .trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    if let message = addManualVerifyMessage {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if let pending = addUnverifiedManualId {
                            // String expression, not an interpolated
                            // literal: that overload markdown-parses,
                            // and model ids carry active characters.
                            Button(String(localized: "Add \(pending) anyway",
                                          comment: "Keep an unverified model id in the inline add flow")) {
                                addPickedModelId = pending
                                addUnverifiedManualId = nil
                                saveAddModel(alreadyProbed: true)
                            }
                            .font(.system(size: 11))
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Add Model") {
                            saveAddModel()
                        }
                        .disabled(addPickedModelId == nil)
                        .font(.system(size: 13))
                        // Without this there is NO way back to the key
                        // from here: an already-configured provider
                        // skips the key sub-step on the way in, so a
                        // stored key that turns out to be wrong could
                        // only be fixed by leaving the wizard.
                        Button("Change key or endpoint") {
                            addFetchTask?.cancel()
                            addIsFetching = false
                            addApiKey = ""
                            addEnvVar = ""
                            addEndpointText = addProvider?.baseURL ?? ""
                            addSubStep = .apiKey
                        }
                        .font(.system(size: 12))
                    }
                }
            }

            Button("Cancel") {
                isAddingModel = false
            }
            .font(.system(size: 12))
            .foregroundColor(SipDesign.textSecondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(SipDesign.borderLight, lineWidth: 1)
        )
    }

    /// One provider row in the inline "Add another model" flow.
    private func addProviderRow(_ p: BuiltinProvider) -> some View {
        Button {
            addProvider = p
            // Deliberately NOT seeded with `p.envVar`. The field is
            // visible now, and a suggested name sitting in it reads as
            // already configured — the reason the main API-key step
            // clears it too — and here it would additionally arm
            // Continue with a value nobody typed.
            addEnvVar = ""
            addManualModelId = ""
            addNoListNote = nil
            addKeyCheckMessage = nil
            // The endpoint field carries what is stored, or the
            // provider's default.
            addEndpointText = config.provider(for: p.key)?.baseURL ?? p.baseURL
            // Already-configured providers reuse their stored key —
            // and their stored ENDPOINT.
            if let existing = config.provider(for: p.key) {
                addProvider = p.withBaseURL(existing.baseURL)
                addSubStep = .model
                addFetchTask?.cancel()
                addFetchTask = Task { await loadModelsForAdd() }
            } else {
                addSubStep = .apiKey
            }
        } label: {
            HStack {
                Text(BuiltinProviderCatalog.localizedName(p)).font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(SipDesign.textHint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 6)
    }

    /// The add-flow's env-var hint — the provider's usual variable name,
    /// offered as a placeholder only (mirrors `envVarPlaceholder`).
    private var addEnvVarPlaceholder: String {
        if let suggestion = addProvider?.envVar, !suggestion.isEmpty {
            return "e.g. \(suggestion)"
        }
        return "e.g. OPENAI_API_KEY"
    }

    // MARK: - Navigation logic

    private var continueEnabled: Bool {
        switch step {
        case .welcome: return true
        case .chooseProvider: return selectedProvider != nil
        case .apiKey:
            // "Other…" region selected but not filled in yet — or filled
            // with something that cannot serve as a base URL (no
            // template to expand it, and it isn't an http(s) URL).
            if useCustomRegion,
               effectiveRegionURL.isEmpty || !isValidHTTPBaseURL(effectiveRegionURL) {
                return false
            }
            if !showsRegionUI, !isValidHTTPBaseURL(resolvedBaseURL) { return false }
            // A typed env-var NAME counts — it need not resolve in this
            // process (Dock-launched apps don't see shell exports).
            let hasKey = !apiKeyText.trimmingCharacters(in: .whitespaces).isEmpty
            let hasEnv = !envVarText.trimmingCharacters(in: .whitespaces).isEmpty
            // A plain-HTTP endpoint is a local server with no key to
            // type — the path Ollama and friends take now that the
            // "Local Model Providers" section is gone.
            return hasKey || hasEnv
                || BuiltinProviderCatalog.endpointNeedsNoKey(resolvedBaseURL)
        case .defaultModel:
            // Only a verified (or explicitly kept-anyway) pick counts —
            // raw manual text must pass through verification first.
            return pickedModelId != nil
        case .addModels:
            // Deleting is possible on this step, so "at least one model"
            // is not implied by having arrived here — and finishing
            // with none leaves an app that cannot chat, with onboarding
            // already marked complete behind it.
            return !config.models.isEmpty
        }
    }

    private func handleContinue() {
        switch step {
        case .welcome:
            withAnimation { step = .chooseProvider }
        case .chooseProvider:
            guard selectedProvider != nil else { return }
            // Every provider passes through the key page; skipping it
            // reads as a broken step, and it is also where the endpoint
            // is set.
            withAnimation { step = .apiKey }
        case .apiKey:
            saveProviderAndContinue()
        case .defaultModel:
            saveModelAndContinue()
        case .addModels:
            finishSetup()
        }
    }

    private func goBack() {
        switch step {
        case .welcome: break
        case .chooseProvider: withAnimation { step = .welcome }
        case .apiKey:
            providerListCollapsed = false
            withAnimation { step = .chooseProvider }
        case .defaultModel: withAnimation { step = .apiKey }
        case .addModels: withAnimation { step = .defaultModel }
        }
    }

    // MARK: - Save logic

    private func saveProviderAndContinue() {
        guard let p = selectedProvider else { return }
        keyError = nil

        let trimmedKey = apiKeyText.trimmingCharacters(in: .whitespaces)
        let trimmedEnv = envVarText.trimmingCharacters(in: .whitespaces)

        let region = resolvedBaseURL
        guard !trimmedKey.isEmpty || !trimmedEnv.isEmpty
                || BuiltinProviderCatalog.endpointNeedsNoKey(region) else {
            keyError = "Please enter an API key or an environment variable name."
            return
        }

        // A raw "Other…" entry is stored verbatim as the base URL —
        // refuse anything that isn't an http(s) URL ("beijing" would
        // fail every request with an opaque unsupported-URL error).
        if useCustomRegion, !isValidHTTPBaseURL(region) {
            keyError = p.regions.isEmpty && p.regionURLTemplate != nil
                ? "Complete the endpoint above before continuing."
                : "The region entry must be a full URL starting with http:// or https://."
            return
        }
        // Same rule for the Advanced endpoint — stored verbatim too.
        if !showsRegionUI, !isValidHTTPBaseURL(region) {
            keyError = "The endpoint must be a full URL starting with http:// or https://."
            showEndpointField = true
            return
        }

        // Store whatever was given — a pasted key, an env var name, or
        // both. The name deliberately does NOT have to resolve in this
        // process: a GUI app launched from the Dock never sees shell
        // exports, and the key lookup is env-first at request time.
        var pc = p.toProviderConfig(apiKey: trimmedKey.isEmpty ? nil : trimmedKey)
        pc.envVar = trimmedEnv.isEmpty ? nil : trimmedEnv
        if !region.isEmpty { pc.baseURL = region }
        config.upsertProvider(pc)
        // Fetching and verification must hit the chosen region too.
        if !region.isEmpty {
            selectedProvider = p.withBaseURL(region)
        }

        withAnimation { step = .defaultModel }
        fetchTask?.cancel()
        fetchTask = Task { await loadModels() }
    }

    private func loadModels() async {
        guard let p = selectedProvider else { return }
        // Snapshot for the stale-response guard below: a slow fetch must
        // not land after the user switched provider and overwrite the
        // newer list (or auto-pick the wrong provider's model).
        fetchGeneration += 1
        let generation = fetchGeneration
        isFetching = true
        fetchError = nil
        fetchedModels = []
        modelHighlight = 0
        showAllFetched = false

        let key = config.apiKey(for: p.key) ?? ""
        // Local servers are exempt: they have no key, and never did.
        if key.isEmpty, !BuiltinProviderCatalog.endpointNeedsNoKey(p.baseURL) {
            if let env = config.provider(for: p.key)?.envVar, !env.isEmpty {
                fetchError = "No API key: $\(env) is empty in both this app and your login shell. Fix the variable (then relaunch SipAI), or go back and paste a key."
            } else {
                fetchError = "No API key stored for \(p.name). Go back and enter one."
            }
            isFetching = false
            return
        }

        // A provider with no list is not sent to fetch one — the note
        // takes the list's place and the id is typed. See
        // `BuiltinProvider.listsModels`.
        if !p.listsModels {
            isFetching = false
            noListNote = BuiltinProviderCatalog.noListNote(for: p)
            showManualEntry = true
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
              selectedProvider?.key == p.key else { return }
        isFetching = false
        fetchedModels = result.ids
        if let failure = result.failure {
            var message = "Could not fetch models — \(failure) Check the API key or environment variable, or enter a model ID manually."
            if p.regions.count > 1 {
                message += " Keys are region-bound — if yours belongs to a different region, go back and choose it under Region."
            }
            if let hint = BuiltinProviderCatalog.setupHints[p.key] {
                message += " " + hint
            }
            fetchError = message
        } else if result.ids.isEmpty {
            fetchError = "\(p.name) listed no chat models. Enter a model ID manually."
        } else if pickedModelId == nil {
            pickedModelId = result.ids.first
        }
        // On a provider that lists models publicly the fetch above
        // proved only that the server is up — probe the key itself.
        if let id = pickedModelId { startKeyCheckIfNeeded(for: p, modelId: id) }
    }

    /// Probe the key on providers whose `/models` is public. Mirrors
    /// `ModelSetupSheet.startKeyCheckIfNeeded`: fire-and-forget, once
    /// per provider, and it never un-picks the model — a rejected key
    /// is fixed by going Back, not by undoing a choice.
    private func startKeyCheckIfNeeded(for p: BuiltinProvider, modelId: String) {
        guard ProviderKeyCheck.isNeeded(for: p),
              !keyCheckedProviders.contains(p.key) else { return }
        keyCheckedProviders.insert(p.key)
        let key = config.apiKey(for: p.key) ?? ""
        let style = (p.key == "openai") ? selectedApiStyle
            : (p.apiStyle == "anthropic" ? "anthropic" : "openai")
        keyCheckTask?.cancel()
        keyCheckTask = Task {
            let message = await ProviderKeyCheck.rejectionMessage(
                provider: p, apiStyle: style, apiKey: key, modelId: modelId)
            guard !Task.isCancelled, selectedProvider?.key == p.key else { return }
            keyCheckMessage = message
        }
    }

    private func saveModelAndContinue() {
        guard let p = selectedProvider else { return }
        let id = (pickedModelId ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        // Belt and braces for stale picks: the id must be one of THIS
        // provider's fetched models, or a manual entry that passed
        // verification (or was explicitly kept) — never a leftover from
        // a previously selected provider.
        guard fetchedModels.contains(id) || verifiedManualIds.contains(id) else {
            pickedModelId = nil
            return
        }

        let style: String?
        if p.key == "openai" {
            style = selectedApiStyle
        } else if p.apiStyle == "anthropic" {
            style = "anthropic"
        } else {
            style = "openai"
        }

        config.upsertModel(id: id, name: id, providerKey: p.key, apiStyle: style)
        config.setDefaultModel(id)
        appState.activeModel = id

        withAnimation { step = .addModels }
    }

    /// The endpoint the inline add flow will store — typed value, else
    /// the provider's default. Mirrors `resolvedBaseURL`.
    private var addResolvedBaseURL: String {
        let typed = addEndpointText.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? (addProvider?.baseURL ?? "") : typed
    }

    /// Whether the inline flow's provider already has credentials on
    /// file — which is what lets both fields be left empty.
    private var addProviderHasStoredCredentials: Bool {
        guard let p = addProvider, let existing = config.provider(for: p.key) else {
            return false
        }
        return existing.apiKey?.isEmpty == false || existing.envVar?.isEmpty == false
    }

    private func saveAddProvider() {
        guard let p = addProvider else { return }
        let trimmedKey = addApiKey.trimmingCharacters(in: .whitespaces)
        let trimmedEnv = addEnvVar.trimmingCharacters(in: .whitespaces)
        // Either channel is enough, exactly as in
        // `saveProviderAndContinue`.
        let url = addResolvedBaseURL
        guard isValidHTTPBaseURL(url) else { return }
        let existing = config.provider(for: p.key)
        // Empty fields with something already stored mean "keep it" —
        // the same rule the model-setup sheet applies, so a return trip
        // to change only the endpoint does not wipe the key.
        if trimmedKey.isEmpty && trimmedEnv.isEmpty, addProviderHasStoredCredentials {
            var refreshed = p.toProviderConfig(apiKey: existing?.apiKey)
            refreshed.envVar = existing?.envVar
            refreshed.baseURL = url
            config.upsertProvider(refreshed)
            addProvider = p.withBaseURL(url)
            return
        }
        // A local server has no key to give; everything else needs one
        // of the two channels filled in.
        guard !trimmedKey.isEmpty || !trimmedEnv.isEmpty
                || BuiltinProviderCatalog.endpointNeedsNoKey(url) else { return }
        var pc = p.toProviderConfig(apiKey: trimmedKey.isEmpty ? nil : trimmedKey)
        pc.envVar = trimmedEnv.isEmpty ? nil : trimmedEnv
        pc.baseURL = url
        config.upsertProvider(pc)
        // Fetching and verification must hit the endpoint that was just
        // stored, not the catalog default this flow started from.
        addProvider = p.withBaseURL(url)
    }

    private func loadModelsForAdd() async {
        guard let p = addProvider else { return }
        addFetchGeneration += 1
        let generation = addFetchGeneration
        addIsFetching = true
        addNoListNote = nil
        addManualVerifyMessage = nil
        // A provider with no list is not sent to fetch one.
        if !p.listsModels {
            addIsFetching = false
            addFetchedModels = []
            addPickedModelId = nil
            addNoListNote = BuiltinProviderCatalog.noListNote(for: p)
            if addManualModelId.isEmpty, let example = p.exampleModelId {
                addManualModelId = example
            }
            return
        }
        let key = config.apiKey(for: p.key) ?? ""
        let ids = await ModelFetcher.fetch(provider: p, apiKey: key)
        // Discard a stale response: landing after the user restarted
        // the add flow with another provider would auto-pick the wrong
        // provider's model id (and saveAddModel would persist it).
        guard !Task.isCancelled, generation == addFetchGeneration,
              addProvider?.key == p.key else { return }
        addFetchedModels = ids
        addPickedModelId = ids.first
        addIsFetching = false
        if ids.isEmpty {
            addNoListNote = "\(p.name) listed no chat models. Enter a model ID below."
        }
    }

    /// Persist the inline flow's pick and close the panel.
    ///
    /// `alreadyProbed` is true when the id came from
    /// `verifyAndAddManualModel`, which has just made the very request
    /// the key check would make — probing twice would spend a second
    /// call to learn what the first already answered.
    private func saveAddModel(alreadyProbed: Bool = false) {
        guard let p = addProvider, let mid = addPickedModelId else { return }
        let style: String? = (p.apiStyle == "anthropic") ? "anthropic" : "openai"
        config.upsertModel(id: mid, name: mid, providerKey: p.key, apiStyle: style)
        if !alreadyProbed { startAddKeyCheck(for: p, modelId: mid) }
        isAddingModel = false
    }

    /// The public-list key probe for the inline flow. Its answer lands
    /// on the STEP, not in the panel: saving closes the panel, so a
    /// notice rendered inside it would be torn down before it could be
    /// read. Shares `keyCheckedProviders` with the main step — one
    /// probe per provider is enough for the whole wizard.
    private func startAddKeyCheck(for p: BuiltinProvider, modelId: String) {
        guard ProviderKeyCheck.isNeeded(for: p),
              !keyCheckedProviders.contains(p.key) else { return }
        keyCheckedProviders.insert(p.key)
        let key = config.apiKey(for: p.key) ?? ""
        let style = p.apiStyle == "anthropic" ? "anthropic" : "openai"
        Task {
            let message = await ProviderKeyCheck.rejectionMessage(
                provider: p, apiStyle: style, apiKey: key, modelId: modelId)
            guard !Task.isCancelled else { return }
            addKeyCheckMessage = message
        }
    }

    /// Manual model id for the inline flow, verified before it counts —
    /// the same probe `verifyAndUseManualModel` makes for the main step.
    private func verifyAndAddManualModel() {
        guard let p = addProvider, !addIsVerifyingManual else { return }
        let id = addManualModelId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        addManualVerifyMessage = nil
        // Cleared with the message it belongs to: left standing, the
        // "Add … anyway" button would offer the PREVIOUS id under the
        // new one's error.
        addUnverifiedManualId = nil
        addIsVerifyingManual = true
        let style = p.apiStyle == "anthropic" ? "anthropic" : "openai"
        Task {
            let rawKey = config.apiKey(for: p.key) ?? ""
            let verdict = await ModelVerifier.verify(
                provider: p, apiStyle: style,
                apiKey: rawKey.isEmpty ? "local" : rawKey, modelId: id)
            // A provider switch mid-probe makes this answer somebody
            // else's — the same staleness rule as the fetch.
            guard addProvider?.key == p.key else { return }
            addIsVerifyingManual = false
            switch verdict {
            case .ok:
                addPickedModelId = id
                saveAddModel(alreadyProbed: true)
            case .notFound(let detail):
                addManualVerifyMessage = "Model not found: \(id). \(detail)"
            case .error(let message):
                // Not "wrong id" — a network or quota answer, so the
                // model may well be real. Offer it, exactly as the main
                // step does, instead of saving something unverified
                // behind the user's back.
                addManualVerifyMessage = "Could not verify \(id) — \(message)"
                addUnverifiedManualId = id
            }
        }
    }

    /// Verify a typed model ID with a 1-token probe before it becomes
    /// the picked model.
    private func verifyAndUseManualModel() {
        guard let p = selectedProvider, !isVerifyingManual else { return }
        let id = manualModelId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        manualVerifyMessage = nil
        unverifiedManualId = nil
        isVerifyingManual = true
        let style: String
        if p.key == "openai" {
            style = selectedApiStyle
        } else {
            style = p.apiStyle == "anthropic" ? "anthropic" : "openai"
        }
        Task {
            let rawKey = config.apiKey(for: p.key) ?? ""
            let key = rawKey.isEmpty ? "local" : rawKey
            let verdict = await ModelVerifier.verify(
                provider: p, apiStyle: style, apiKey: key, modelId: id)
            // A provider switch mid-verify invalidates this probe —
            // accepting it would pick an id for the wrong provider.
            // (selectProvider already reset isVerifyingManual.)
            guard selectedProvider?.key == p.key else { return }
            isVerifyingManual = false
            switch verdict {
            case .ok:
                verifiedManualIds.insert(id)
                pickedModelId = id
            case .notFound(let detail):
                manualVerifyMessage = "Model not found: \(id). \(detail)"
            case .error(let message):
                manualVerifyMessage = "Could not verify \(id) — \(message)"
                unverifiedManualId = id
            }
        }
    }

    private func skipToAgentSessions() {
        // Mark all installed agents as seen so hints don't repeat
        agents.markAllInstalledSeen(config: config)
        config.reload()
        if appState.activeModel == nil {
            appState.activeModel = config.defaultModel
        }
        onComplete()
    }

    private func finishSetup() {
        config.reload()
        // Ensure active model survives the view transition
        if appState.activeModel == nil {
            appState.activeModel = config.defaultModel
        }
        onComplete()
    }

    private func providerDisplayName(_ key: String) -> String {
        if let p = BuiltinProviderCatalog.find(key) {
            return BuiltinProviderCatalog.localizedName(p)
        }
        return config.provider(for: key)?.name ?? key.capitalized
    }
}

// MARK: - Configured-model row ("Your models" step)

/// One already-configured model on the "Your models" step, with the same
/// two actions Settings' `ModelSettingsRow` offers — Set default and
/// Delete — including its `activeModel` bookkeeping and its delete
/// confirmation, in this page's own row styling.
///
/// A struct rather than a `func` on `OnboardingView` so each row owns the
/// hover state of its own two buttons; one flag on the parent would light
/// every row's buttons at once.
private struct OnboardingModelRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var config: ConfigManager

    let model: ModelConfig
    let providerLabel: String

    @State private var setDefaultHovered = false
    @State private var deleteHovered = false
    @State private var confirmingDelete = false

    private var isDefault: Bool { config.defaultModel == model.id }

    var body: some View {
        HStack(spacing: 0) {
            Text(model.name)
                .font(.system(size: 14))
                .foregroundColor(SipDesign.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                // Same either/or slot as Settings: the tag when this IS
                // the default, the button that makes it one when it isn't.
                if isDefault {
                    Text("default")
                        .font(.system(size: 11))
                        .foregroundColor(SipDesign.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(SipDesign.cardSelectedBg)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Button {
                        let previousDefault = config.defaultModel
                        config.setDefaultModel(model.id)
                        // Same bookkeeping as ModelSettingsRow: the
                        // composer label follows the default unless the
                        // user explicitly switched to another model.
                        if appState.activeModel == nil
                            || appState.activeModel == previousDefault {
                            appState.activeModel = model.id
                        }
                    } label: {
                        Text("Set default")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(SipDesign.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(setDefaultHovered ? Color.gray.opacity(0.2)
                                                            : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { setDefaultHovered = $0 }
                }

                Text(providerLabel)
                    .font(.system(size: 11))
                    .foregroundColor(SipDesign.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(SipDesign.chipBg)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Button {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(deleteHovered ? .red : SipDesign.textSecondary)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(deleteHovered ? Color.red.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { deleteHovered = $0 }
                .accessibilityLabel(Text("Delete model"))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(SipDesign.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .alert(
            String(localized: "Delete \(model.name)?",
                   comment: "Title of the model delete confirmation, names the model"),
            isPresented: $confirmingDelete
        ) {
            Button(role: .destructive) {
                // `removeModel` re-points `default_model` at the next
                // model, or drops the key when that was the last one.
                config.removeModel(id: model.id)
                if appState.activeModel == model.id {
                    appState.activeModel = config.defaultModel
                }
            } label: {
                Text("Delete", comment: "Confirm deleting the model")
            }
            Button(role: .cancel) { } label: {
                Text("Cancel", comment: "Dismiss the model delete confirmation")
            }
        }
    }
}
