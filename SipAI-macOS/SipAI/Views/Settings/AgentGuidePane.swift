// AgentGuidePane.swift
// Settings → Agent Guide: why a command-line tool is needed, and one
// card per supported agent with the one thing it needs next — Install,
// Sign In, or (installed and signed in) Delete — plus the checkbox
// that hides it and the sheets each action asks through. Updating a
// tool is NOT here: that row lives beside the app's own update
// controls, under Settings → Updates, so this pane reads the installed
// version and makes no claim about a newer one. State comes from
// `AgentManager.presence(for:)`, `UsageMonitor.shared.accounts`,
// `AgentCLIUpdateMonitor.shared` and `AgentGuideActions.shared`; every
// sentence is made here, from catalog keys.

import SwiftUI
import AppKit

struct AgentGuidePane: View {
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var agents: AgentManager
    @ObservedObject private var cliUpdates = AgentCLIUpdateMonitor.shared
    @ObservedObject private var actions = AgentGuideActions.shared
    @Environment(\.sipFontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Guide", comment: "Settings pane header")
                .sipFont(14, weight: .semibold)

            intro

            Divider().opacity(0.3).padding(.vertical, 2)

            // This pane installs, signs in and out, deletes and hides.
            // Updating a tool lives with the app's own update controls,
            // so a card names the installed version and points there
            // rather than carrying a second update surface. Only once
            // there is a tool to update: with nothing installed the
            // pointer names a section the Updates pane does not draw.
            if !agents.installedAgents.isEmpty {
                Text("Updating these tools is in Settings → Updates.",
                     comment: "Agent Guide: pointer to where the agent CLI update rows live")
                    .sipFont(12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(AgentManager.registry) { agent in
                    AgentGuideCard(agent: agent)
                        .environmentObject(config)
                        .environmentObject(agents)
                }
            }
            .padding(.top, 4)
        }
        // Re-reads the installed versions — which a card names — and
        // asks each installed tool who it is signed in as. The release
        // endpoints are NOT asked here: no claim on this pane rests on
        // one, and a periodic request that leaves the machine belongs
        // to the pane carrying its switch.
        .onAppear {
            actions.configure(agents: agents, config: config)
            cliUpdates.guideAppeared()
            actions.probeInstalled()
        }
    }

    /// What SipAI runs and what has to come first, how installing and
    /// signing in work, then the one rule for the sidebar. The cards
    /// below name each agent, so the intro does not.
    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            introParagraph(Text("SipAI runs each supported provider's own command-line tool on this Mac and shows its sessions in the sidebar. You must have access to a provider before you can use its tool in SipAI — some AI providers aren't available in every country or region.",
                                comment: "Agent Guide intro, first paragraph: what SipAI runs, and that access to the provider comes first"))
            introParagraph(Text("You can install a tool below or in Terminal. Either way, SipAI notices within a few seconds. Sign In opens the provider's own sign-in page. The tool keeps its own login, just as it does in Terminal.",
                                comment: "Agent Guide intro, second paragraph: installing and signing in"))
            introParagraph(Text("Only providers that are installed and signed in appear in the sidebar.",
                                comment: "Agent Guide intro, closing sentence"))
        }
    }

    private func introParagraph(_ text: Text) -> some View {
        text
            .sipFont(12)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - One agent's card

struct AgentGuideCard: View {
    let agent: AgentInfo
    /// For the theme alone: the sheets below are separate NSWindows and
    /// do not reliably inherit the main window's forced appearance.
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var agents: AgentManager
    @ObservedObject private var cliUpdates = AgentCLIUpdateMonitor.shared
    @ObservedObject private var actions = AgentGuideActions.shared
    @ObservedObject private var usage = UsageMonitor.shared
    @Environment(\.sipFontScale) private var fontScale

    @State private var showingSignIn = false
    @State private var showingInstall = false
    @State private var confirmingDelete = false
    @State private var confirmingSignOut = false
    @State private var showingFailure = false
    @State private var claudeCode = ""

    // Sign-in sheet state
    @State private var method: AgentSignIn.Method = .subscription
    @State private var apiKey = ""
    /// Kimi's site — the sheet's first question. nil until the user picks
    /// one or kimi answered which it would use (`AgentGuideActions
    /// .kimiRegion`); Continue waits for it.
    @State private var kimiSite: KimiSite? = nil
    @State private var kimiProviderId = AgentSignIn.kimiKeyProviders[0].id

    private var key: String { agent.key }

    /// No user-visible sentence names an agent outright.
    private var label: String {
        config.agentLabel(for: agent.key, defaultName: agent.name)
    }

    private var presence: AgentPresence { agents.presence(for: key) }
    private var progress: AgentGuideActions.Progress? { actions.progress[key] }
    /// One of this card's three sheets is up. They hang off the main
    /// window, so the update announcer is told: a line beside the logo
    /// waits while a sheet covers it (`UpdateAnnouncer.sheetCoversLockup`).
    /// One sheet is up at a time app-wide (a sheet is modal to its
    /// window), so a plain report per card cannot clobber another's.
    private var sheetUp: Bool {
        showingSignIn || showingInstall || actions.browserStep?.agentKey == key
    }
    private var isBusy: Bool { progress != nil || cliUpdates.updateInFlight(key) }
    private var isHidden: Bool { presence == .hiddenByUser }
    private var isSignedIn: Bool { presence == .listed || presence == .hiddenByUser }

    /// A turn in flight for this agent, ours or another terminal's —
    /// the test the Update button already makes. Delete and Sign out
    /// wait for it; Install and Sign In never do.
    private var hasRunningTurn: Bool {
        if agents.runners.values.contains(where: {
            $0.agentKey == agent.key && $0.status.isRunning
        }) { return true }
        return agents.externalInFlightSessions.contains { id in
            agents.sessions.first(where: { $0.id == id })?.agentKey == agent.key
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if isSignedIn {
                    Toggle(isOn: Binding(
                        get: { !isHidden },
                        set: { agents.setHidden(!$0, for: key) }
                    )) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(String(localized: "Show \(label) in SipAI. Unticked, it stays installed and signed in on this Mac, but its sessions leave the sidebar and search, its scheduled tasks stop running, and nothing about it is shown or checked until you tick it again.",
                                 comment: "Agent Guide: hover on the show/hide checkbox; placeholder is the agent's name"))
                } else {
                    // Keeps the label column aligned with ticked rows.
                    Color.clear.frame(width: 14, height: 14)
                }

                Text(verbatim: label)
                    .sipFont(13, weight: .medium)
                    .frame(width: 130 * SipFont.ratio(fontScale), alignment: .leading)

                Text(verbatim: cliUpdates.installed[key]?.text ?? "")
                    .monospacedDigit()
                    .sipFont(13)
                    .foregroundStyle(.secondary)
                    .frame(width: 78 * SipFont.ratio(fontScale), alignment: .leading)

                Spacer(minLength: 8)

                primaryButton
            }

            secondLine

            if let failure = actions.failures[key], !failure.isEmpty {
                failureView(failure)
            }
        }
        .opacity(isHidden ? 0.55 : 1)
        .sheet(isPresented: $showingSignIn) {
            signInSheet.preferredColorScheme(appState.theme.colorScheme)
        }
        .sheet(isPresented: $showingInstall) {
            installSheet.preferredColorScheme(appState.theme.colorScheme)
        }
        .sheet(item: browserStepBinding) { step in
            browserSheet(step).preferredColorScheme(appState.theme.colorScheme)
        }
        .onChange(of: sheetUp) { _, up in UpdateAnnouncer.shared.setSheetPresented(up) }
        // Torn down with a sheet up — a notification click closes
        // Settings underneath it — the sheet goes with the card, and so
        // must the report, or every later line waits on a sheet that is
        // gone.
        .onDisappear { if sheetUp { UpdateAnnouncer.shared.setSheetPresented(false) } }
        .alert(String(localized: "Delete \(label) from this Mac?",
                      comment: "Agent Guide: title of the delete confirmation; placeholder is the agent's name"),
               isPresented: $confirmingDelete) {
            Button(role: .destructive) {
                if let plan = deletePlan { actions.delete(agentKey: key, plan: plan) }
            } label: {
                Text("Delete", comment: "Confirm deleting a custom session group")
            }
            Button(role: .cancel) { } label: {
                Text("Cancel", comment: "Dismiss the delete-group confirmation")
            }
        } message: {
            Text(verbatim: deleteSentence)
        }
        .alert(String(localized: "Sign out of \(label) on this Mac?",
                      comment: "Agent Guide: title of the sign-out confirmation; placeholder is the agent's name"),
               isPresented: $confirmingSignOut) {
            Button(role: .destructive) {
                actions.signOut(agentKey: key)
            } label: {
                Text("Sign out", comment: "Agent Guide: sign-out link and confirm button")
            }
            Button(role: .cancel) { } label: {
                Text("Cancel", comment: "Dismiss the delete-group confirmation")
            }
        } message: {
            Text(signOutSentence)
        }
    }

    // MARK: Line 1 — the primary button

    @ViewBuilder
    private var primaryButton: some View {
        if let progress {
            Button {
                cancel(progress)
            } label: {
                Text("Cancel", comment: "Updates pane: stop the running CLI updater")
            }
            .sipFont(12)
            .disabled(progress.phase == .probing || progress.phase == .signingOut)
        } else {
            switch presence {
            case .notInstalled:
                if AgentInstallRoute.route(agentKey: key) != nil {
                    Button {
                        showingInstall = true
                    } label: {
                        Text("Install", comment: "Agent Guide: install the agent's command-line tool")
                    }
                    .sipFont(12)
                    .disabled(isBusy)
                }
            case .notSignedIn:
                Button {
                    method = AgentSignIn.routes(agentKey: key).first?.method ?? .subscription
                    apiKey = ""
                    if key == "kimi" {
                        // What kimi itself would use: a saved login's site,
                        // else the site it was installed from. Nothing when
                        // kimi did not answer — the user picks.
                        selectKimiSite(KimiSite(region: actions.kimiRegion))
                    }
                    showingSignIn = true
                } label: {
                    Text("Sign In", comment: "Agent Guide: sign the agent's command-line tool in")
                }
                .sipFont(12)
                .disabled(isBusy)
            case .listed, .hiddenByUser:
                if deletePlan != nil {
                    Button {
                        confirmingDelete = true
                    } label: {
                        Text("Delete", comment: "Confirm deleting a custom session group")
                    }
                    .sipFont(12)
                    .disabled(isBusy || hasRunningTurn)
                    .help(hasRunningTurn
                          ? String(localized: "Finish the running turn before removing this tool.",
                                   comment: "Agent Guide: why Delete is disabled")
                          : "")
                }
            case .pending:
                EmptyView()
            }
        }
    }

    private func cancel(_ progress: AgentGuideActions.Progress) {
        switch progress.phase {
        case .awaitingBrowserConfirmation, .waitingForBrowser, .signingIn:
            actions.cancelSignIn(agentKey: key)
        case .lookingUpVersion, .downloading, .installing, .deleting:
            actions.cancelInstall(agentKey: key)
        case .probing, .signingOut:
            break
        }
    }

    // MARK: Line 2 — status or progress

    @ViewBuilder
    private var secondLine: some View {
        HStack(spacing: 6) {
            if let progress {
                ProgressView().controlSize(.small)
                Text(verbatim: progressSentence(progress))
                    .sipFont(12)
                    .foregroundStyle(.secondary)
                if key == "claude_code", progress.phase == .waitingForBrowser {
                    // Claude prints "Paste code here if prompted": the
                    // field is the answer to that prompt, and nothing
                    // else.
                    TextField(String(localized: "Code from the page, if it shows one",
                                     comment: "Agent Guide: placeholder of the field for claude's pasted sign-in code"),
                              text: $claudeCode)
                        .textFieldStyle(.roundedBorder)
                        .sipFont(12)
                        .frame(width: 220)
                        .onSubmit {
                            actions.submitClaudeCode(claudeCode)
                            claudeCode = ""
                        }
                }
            } else {
                Text(verbatim: statusSentence)
                    .sipFont(12)
                    .foregroundStyle(.secondary)
                if isSignedIn {
                    Button {
                        confirmingSignOut = true
                    } label: {
                        Text("Sign out", comment: "Agent Guide: sign-out link and confirm button")
                            .sipFont(12)
                            .underline()
                            .foregroundStyle(hasRunningTurn ? Color.secondary : SipDesign.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy || hasRunningTurn)
                    .help(hasRunningTurn
                          ? String(localized: "Finish the running turn before signing out.",
                                   comment: "Agent Guide: why Sign out is disabled")
                          : "")
                }
                if case .unknown(let path) = installSource, presence != .notInstalled {
                    Text(String(localized: "Installed somewhere SipAI does not manage (\(path)). Remove it the way it was installed.",
                                comment: "Agent Guide: the install source could not be detected, so no Delete is offered; placeholder is the binary's path"))
                        .sipFont(11)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 24)
    }

    private var statusSentence: String {
        switch presence {
        case .notInstalled:
            return String(localized: "Not installed", comment: "Agent Guide status line")
        case .pending:
            return String(localized: "Checking…", comment: "Agent Guide status line while the first account read is in flight")
        case .notSignedIn:
            return String(localized: "Installed · not signed in", comment: "Agent Guide status line")
        case .listed, .hiddenByUser:
            return String(localized: "Signed in — \(accountDescription)",
                          comment: "Agent Guide status line; placeholder describes the account (a plan name, or API key)")
        }
    }

    /// The account, in the words the usage window already uses:
    /// "%@ plan" / "Subscription" for claude, "ChatGPT %@" for codex,
    /// "Membership" for kimi, "API key" for a key — and for kimi, which
    /// site or platform it is signed in on (`kimiAccountSite`): kimi.com
    /// and kimi.ai are separate services.
    private var accountDescription: String {
        let kind = actions.probed[key] ?? usage.accounts[key] ?? .unknown
        switch kind {
        case .apiKey:
            if key == "claude_code" {
                // A Console login and a key from the environment or a
                // settings `apiKeyHelper` both bill per token, and the
                // verdict does not tell them apart (`auth status`
                // reports both as an API key in force).
                return String(localized: "API billing — Anthropic Console or an API key",
                              comment: "Agent Guide: claude runs on an API-billed account — a Console login, or an API key from its environment or settings")
            }
            if key == "kimi", let platform = actions.kimiAccountSite {
                return String(localized: "API key (\(platform))",
                              comment: "Agent Guide: kimi runs on an API key; placeholder is the platform the key is from, e.g. platform.moonshot.cn")
            }
            return String(localized: "API key", comment: "Agent Guide: the tool runs on an API key")
        case .plan(let name):
            switch key {
            case "codex":
                if let name { return String(localized: "ChatGPT \(name)", comment: "Plan-usage card subtitle for a codex plan; placeholder is the plan type") }
                return String(localized: "Subscription", comment: "Plan-usage card subtitle when the plan has no tier name")
            case "kimi":
                if let site = actions.kimiAccountSite {
                    return String(localized: "Membership (\(site))",
                                  comment: "Agent Guide: a Kimi Code membership; placeholder is the site it is signed in on, kimi.com or kimi.ai")
                }
                return String(localized: "Membership", comment: "Plan-usage card subtitle for a Kimi Code membership")
            default:
                if let name { return String(localized: "\(name) plan", comment: "Plan-usage card subtitle; placeholder is the plan tier") }
                return String(localized: "Subscription", comment: "Plan-usage card subtitle when the plan has no tier name")
            }
        case .signedOut, .unknown:
            return String(localized: "Subscription", comment: "Plan-usage card subtitle when the plan has no tier name")
        }
    }

    private func progressSentence(_ progress: AgentGuideActions.Progress) -> String {
        switch progress.phase {
        case .probing:
            return String(localized: "Checking…", comment: "Agent Guide status line while the first account read is in flight")
        case .lookingUpVersion:
            return String(localized: "Looking up the latest version…", comment: "Agent Guide progress: fetching the version to install")
        case .downloading:
            switch key {
            case "codex":
                return String(localized: "Downloading OpenAI's release package…", comment: "Agent Guide progress: codex's package is downloading")
            default:
                return String(localized: "Downloading \(vendorName)'s installer…",
                              comment: "Agent Guide progress: the vendor's installer script is downloading; placeholder is the vendor")
            }
        case .installing:
            return String(localized: "Installing…", comment: "Agent Guide progress: the installer is running")
        case .awaitingBrowserConfirmation:
            return String(localized: "Ready to open \(progress.detail ?? "")…",
                          comment: "Agent Guide progress: the browser notice is up; placeholder is the host")
        case .waitingForBrowser:
            return String(localized: "Waiting for you to finish signing in in the browser…", comment: "Agent Guide progress: a browser sign-in is open")
        case .signingIn:
            return String(localized: "Signing in…", comment: "Agent Guide progress: a key sign-in is running")
        case .signingOut:
            return String(localized: "Signing out…", comment: "Agent Guide progress: the tool's sign-out is running")
        case .deleting:
            return String(localized: "Removing…", comment: "Agent Guide progress: the tool is being removed")
        }
    }

    /// The vendor a sentence names — a company, not the agent label.
    private var vendorName: String {
        switch key {
        case "claude_code": return "Anthropic"
        case "codex": return "OpenAI"
        case "kimi": return "Moonshot"
        default: return label
        }
    }

    private func failureView(_ failure: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Did not complete", comment: "Agent Guide: an install, sign-in, sign-out or delete did not achieve its result")
                    .sipFont(12)
                    .foregroundStyle(.orange)
                Button {
                    showingFailure.toggle()
                } label: {
                    Text("Details", comment: "Updates pane: show the updater's own output")
                }
                .sipFont(12)
            }
            if showingFailure {
                Text(verbatim: failure)
                    .sipFont(11, design: .monospaced)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.10))
                    )
            }
        }
        .padding(.leading, 24)
    }

    // MARK: Install source and the delete plan

    private var installSource: AgentInstallSource? {
        AgentInstallSource.current(agentKey: key)
    }

    private var deletePlan: [AgentDeletePlan.Step]? {
        guard let source = installSource else { return nil }
        return AgentDeletePlan.make(agentKey: key, source: source,
                                    home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// The delete alert: the consequence, with the DETECTED route in
    /// the middle clause.
    private var deleteSentence: String {
        let route: String
        switch installSource {
        case .native(let directory)?:
            if key == "kimi" {
                route = String(localized: "the install under \(directory)/bin",
                               comment: "Agent Guide delete clause: kimi's native layout; placeholder is the install directory")
            } else {
                route = String(localized: "the native install under ~/.local/bin and \(directory)",
                               comment: "Agent Guide delete clause: claude's native layout; placeholder is the versions directory")
            }
        case .sipai(let directory)?:
            route = String(localized: "the copy SipAI installed under \(directory)",
                           comment: "Agent Guide delete clause: a codex SipAI installed; placeholder is its directory")
        case .npm(let prefix, let package)?:
            route = String(localized: "the npm package \(package) under \(prefix)",
                           comment: "Agent Guide delete clause: an npm global install; placeholders are the package and the prefix")
        case .brew(_, let cask)?:
            route = String(localized: "the Homebrew package \(cask)",
                           comment: "Agent Guide delete clause: a Homebrew cask or formula; placeholder is the package name")
        case .brewFormula(_, let formula)?:
            route = String(localized: "the Homebrew package \(formula)",
                           comment: "Agent Guide delete clause: a Homebrew cask or formula; placeholder is the package name")
        default:
            route = ""
        }
        let store: String
        switch key {
        case "codex": store = "~/.codex"
        case "kimi": store = "~/.kimi-code"
        default: store = "~/.claude"
        }
        return String(localized: "This removes the \(label) command-line tool, the same as uninstalling it in Terminal — here, \(route). Its sessions, settings and sign-in stay in \(store) and are back the moment you reinstall. Nothing else on your Mac is changed.",
                      comment: "Agent Guide: body of the delete confirmation; placeholders are the agent's name, the detected install route, and the tool's own data folder")
    }

    private var signOutSentence: String {
        if key == "kimi", let kind = usage.accounts[key], kind == .apiKey {
            return String(localized: "Its sessions stay on disk; its section leaves the sidebar until you sign in again. Every API-key provider is removed from kimi's config.toml through kimi's own command, with the model aliases that referenced them.",
                          comment: "Agent Guide: body of the sign-out confirmation for a key-based kimi")
        }
        return String(localized: "Its sessions stay on disk; its section leaves the sidebar until you sign in again.",
                      comment: "Agent Guide: body of the sign-out confirmation")
    }

    // MARK: Sheets

    private var browserStepBinding: Binding<AgentGuideActions.BrowserStep?> {
        Binding(
            get: { actions.browserStep?.agentKey == key ? actions.browserStep : nil },
            set: { if $0 == nil, actions.browserStep?.agentKey == key { actions.cancelBrowser() } }
        )
    }

    /// Sheet 1: how to sign in. For kimi the SITE comes first: kimi.com
    /// and kimi.ai are separate services, and both the membership route
    /// (which site's device page opens) and the key route (which
    /// platform issued the key) depend on it.
    private var signInSheet: some View {
        let routes = AgentSignIn.routes(agentKey: key,
                                        kimiRegion: (kimiSite ?? .mainlandCN).rawValue)
        return VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Sign in to \(label)",
                        comment: "Agent Guide: title of the sign-in method sheet; placeholder is the agent's name"))
                .sipFont(15, weight: .semibold)

            if key == "kimi" {
                kimiSiteQuestion
            }

            Text("How do you want to sign in?", comment: "Agent Guide: question on the sign-in method sheet")
                .sipFont(13)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(routes, id: \.method) { route in
                    methodRow(route)
                }
            }

            if method == .apiKey {
                if key == "kimi", let site = kimiSite {
                    // Only the chosen site's providers: a key works only
                    // on the platform that issued it.
                    Picker(selection: $kimiProviderId) {
                        ForEach(site.keyProviders) { provider in
                            Text(verbatim: "\(provider.name) — \(provider.platform)").tag(provider.id)
                        }
                    } label: {
                        Text("Provider", comment: "Agent Guide: picker of the kimi key-based provider")
                            .sipFont(12)
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 420, alignment: .leading)
                }
                SecureField(String(localized: "Paste the key",
                                   comment: "Agent Guide: placeholder of the API key field"),
                            text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
            }

            HStack {
                Spacer()
                Button {
                    showingSignIn = false
                } label: {
                    Text("Cancel", comment: "Dismiss the delete-group confirmation")
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    showingSignIn = false
                    actions.signIn(agentKey: key, method: method, apiKey: apiKey,
                                   region: (kimiSite ?? .mainlandCN).rawValue,
                                   kimiProviderId: kimiProviderId)
                    apiKey = ""
                } label: {
                    Text("Continue", comment: "Onboarding/setup: advance to the next step")
                }
                .keyboardShortcut(.defaultAction)
                .disabled((method == .apiKey && apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                          || (key == "kimi" && kimiSite == nil))
            }
        }
        .padding(20)
        .frame(width: 520)
        .controlSize(SipFont.controlSize(fontScale))
    }

    private func methodRow(_ route: AgentSignIn.Route) -> some View {
        radioRow(text: methodDescription(route), selected: method == route.method) {
            method = route.method
        }
    }

    /// One choice of a sheet's question — a sign-in method, a kimi site.
    private func radioRow(text: String, selected: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .sipFont(13)
                    .foregroundStyle(selected ? SipDesign.blue : Color.secondary)
                Text(verbatim: text)
                    .sipFont(12)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Kimi's site, asked first on the sign-in sheet: the question, the
    /// two sites, and why it matters. Install does not ask — see
    /// `AgentInstallRoute.route`.
    private var kimiSiteQuestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which site is your account or key from?",
                 comment: "Agent Guide: the first question on the Kimi Code sign-in sheet")
                .sipFont(13)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(KimiSite.allCases) { site in
                    radioRow(text: kimiSiteLabel(site), selected: kimiSite == site) {
                        selectKimiSite(site)
                    }
                }
            }
            Text("kimi.com and kimi.ai are separate services — pick the one you signed up on.",
                 comment: "Agent Guide: under the Kimi Code site choice; the two sites keep separate accounts, memberships and keys")
                .sipFont(12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func kimiSiteLabel(_ site: KimiSite) -> String {
        switch site {
        case .mainlandCN:
            return String(localized: "Mainland China (kimi.com)", comment: "Agent Guide: kimi region choice")
        case .global:
            return String(localized: "Global (kimi.ai)", comment: "Agent Guide: kimi region choice")
        }
    }

    /// Pick a sign-in site; a key provider of the other site gives way to
    /// this site's first.
    private func selectKimiSite(_ site: KimiSite?) {
        kimiSite = site
        guard let site else { return }
        if !site.keyProviders.contains(where: { $0.id == kimiProviderId }) {
            kimiProviderId = site.keyProviders.first?.id ?? kimiProviderId
        }
    }

    private func methodDescription(_ route: AgentSignIn.Route) -> String {
        switch (key, route.method) {
        case ("claude_code", .subscription):
            return String(localized: "Claude subscription — Pro or Max. Opens claude.com in your browser.",
                          comment: "Agent Guide sign-in choice")
        case ("claude_code", .console):
            return String(localized: "Anthropic Console — API usage billing. Opens platform.claude.com in your browser.",
                          comment: "Agent Guide sign-in choice")
        case ("codex", .subscription):
            return String(localized: "ChatGPT plan — Plus, Pro, Business or Enterprise. Opens auth.openai.com in your browser.",
                          comment: "Agent Guide sign-in choice")
        case ("codex", .apiKey):
            return String(localized: "API key — paste a key from platform.openai.com.",
                          comment: "Agent Guide sign-in choice")
        case ("kimi", .subscription):
            if kimiSite == nil {
                return String(localized: "Kimi Code membership — opens the site you pick and shows a code to confirm there.",
                              comment: "Agent Guide sign-in choice, before a Kimi Code site is picked")
            }
            return String(localized: "Kimi Code membership — opens \(route.host) and shows a code to confirm there.",
                          comment: "Agent Guide sign-in choice; placeholder is the site's sign-in page, www.kimi.com or www.kimi.ai")
        case ("kimi", .apiKey):
            return String(localized: "API key — paste a key from the provider picked below.",
                          comment: "Agent Guide sign-in choice")
        default:
            return route.method.rawValue
        }
    }

    /// Sheet 2: the notice before the browser opens.
    private func browserSheet(_ step: AgentGuideActions.BrowserStep) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Continue in your browser", comment: "Agent Guide: title of the browser notice sheet")
                .sipFont(15, weight: .semibold)
            Text(String(localized: "You're about to be taken to \(step.host) to sign in. Finish there and come back to SipAI — the row updates by itself. The tool stores its own login on this Mac; SipAI never sees your password or a token.",
                        comment: "Agent Guide: body of the browser notice; placeholder is the website's host"))
                .sipFont(13)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let code = step.userCode {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: code)
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Compare this code with the one the page shows",
                         comment: "Agent Guide: under kimi's device code on the browser notice")
                        .sipFont(12)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button {
                    actions.cancelBrowser()
                } label: {
                    Text("Cancel", comment: "Dismiss the delete-group confirmation")
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    actions.continueBrowser()
                } label: {
                    Text("Continue", comment: "Onboarding/setup: advance to the next step")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .controlSize(SipFont.controlSize(fontScale))
    }

    /// The install confirmation: what runs, from where, what changes.
    private var installSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Install \(label)?",
                        comment: "Agent Guide: title of the install confirmation; placeholder is the agent's name"))
                .sipFont(15, weight: .semibold)
            Text(verbatim: installSentence)
                .sipFont(13)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing else on your Mac is changed.",
                 comment: "Agent Guide: closing line of every install confirmation")
                .sipFont(13)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button {
                    showingInstall = false
                } label: {
                    Text("Cancel", comment: "Dismiss the delete-group confirmation")
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    showingInstall = false
                    actions.install(agentKey: key)
                } label: {
                    Text("Install", comment: "Agent Guide: install the agent's command-line tool")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .controlSize(SipFont.controlSize(fontScale))
    }

    private var installSentence: String {
        switch key {
        case "claude_code":
            return String(localized: "SipAI downloads Anthropic's installer from claude.ai and runs it. It installs to ~/.local/bin and may add that folder to your shell's PATH so Terminal finds it too. About 200 MB.",
                          comment: "Agent Guide: install confirmation body for Claude Code")
        case "codex":
            return String(localized: "SipAI downloads OpenAI's release package (about 120 MB) from github.com/openai/codex, checks it against OpenAI's checksum file, and installs it under ~/.local/share/sipai/codex with a codex command in ~/.local/bin — adding that folder to your shell's PATH if Terminal does not see it yet. SipAI keeps this copy up to date from the same place; if you would rather have Homebrew or npm manage it, install it there yourself and SipAI will use that copy instead.",
                          comment: "Agent Guide: install confirmation body for Codex")
        case "kimi":
            return String(localized: "SipAI downloads Moonshot's installer from code.kimi.com and runs it. It installs to ~/.kimi-code/bin and adds that folder to your shell's PATH.",
                          comment: "Agent Guide: install confirmation body for Kimi Code")
        default:
            return ""
        }
    }
}
