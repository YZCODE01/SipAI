// OnboardingView.swift
// First launch: the welcome page, and nothing after it. Get started
// records that onboarding is complete and lands in the main window —
// the chat page explains how a model is added, and the sidebar's ADD
// AGENTS row leads to Settings → Agent Initialization for the
// command-line tools. Shown by ContentView while `config.needsOnboarding` is true.

import SwiftUI

@MainActor
struct OnboardingView: View {
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var agents: AgentManager

    /// Explicit finish signal. ContentView latches the onboarding
    /// decision, so a config write cannot flip its gate — the ONLY way
    /// to leave this page is this callback.
    var onComplete: () -> Void = {}

    var body: some View {
        WelcomePage(agentNames: agentNamesJoined, onGetStarted: finish)
            .onAppear { agents.reload(config: config) }
    }

    /// "Claude Code, Codex and Kimi Code" through the labels and the
    /// existing list joiner.
    private var agentNamesJoined: String {
        let names = AgentManager.registry.map {
            config.agentLabel(for: $0.key, defaultName: $0.name)
        }
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return String(localized: "\(names.dropLast().joined(separator: ", ")) and \(last)",
                      comment: "Joins the last agent name onto the list of the others: “A, B and C”")
    }

    /// Get started: onboarding is complete the moment it is clicked.
    /// The installed CLIs are marked seen in the same save, so the
    /// command-line app's "agent detected" nudge does not repeat.
    private func finish() {
        config.completeOnboarding(installedAgents: agents.installedAgents.map(\.key))
        if appState.activeModel == nil {
            appState.activeModel = config.defaultModel
        }
        onComplete()
    }
}

/// The welcome page as drawn, from plain values. It is laid out the way
/// macOS lays out a welcome: the system's own text styles at their own
/// line heights, plain symbols in SipAI's blue, and the system's large
/// button. Sizes stay fixed — the page runs before the Display font size
/// exists.
struct WelcomePage: View {
    /// The agents' names, already joined into one phrase.
    let agentNames: String
    let onGetStarted: () -> Void

    @State private var getStartedHovered = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()

                // Tight-cropped asset, drawn at its own size — see
                // LeftSidebar's brand header.
                Image("SipAI-Logo-86")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 86)

                Spacer().frame(height: 14)

                Text("Welcome to SipAI")
                    .font(.largeTitle.weight(.bold))
                    .foregroundColor(SipDesign.textPrimary)

                Spacer().frame(height: 4)

                Text("Your AI, your way.")
                    .font(.title3)
                    .foregroundColor(SipDesign.textSecondary)

                Spacer().frame(height: 28)

                VStack(alignment: .leading, spacing: 16) {
                    // `featureRow` takes plain `String`s, so a bare literal at the
                    // call site reaches SwiftUI's non-localizing `Text(_: String)`
                    // overload and ships in English whatever the language. These
                    // are localized HERE, where the literal still exists.
                    featureRow(
                        icon: "globe",
                        title: String(localized: "All providers, one app",
                                      comment: "Onboarding welcome bullet title"),
                        desc: String(localized: "Chat with GPT, Claude, and more with your API keys.",
                                     comment: "Onboarding welcome bullet detail")
                    )
                    featureRow(
                        icon: "terminal",
                        title: String(localized: "Better local AI agent management",
                                      comment: "Onboarding welcome bullet title"),
                        // A String expression, never an interpolated Text
                        // literal: the names are the user's own labels.
                        desc: String(localized: "Run \(agentNames) from one window, on your subscription or API key.",
                                     comment: "Onboarding welcome bullet detail; placeholder is the joined list of agent names")
                    )
                    featureRow(
                        icon: "checkmark.shield",
                        title: String(localized: "Your data, your control",
                                      comment: "Onboarding welcome bullet title"),
                        desc: String(localized: "No sign-up required, no data collection, no tracking from the app. Your data is just between you and the AI.",
                                     comment: "Onboarding welcome bullet detail")
                    )
                }
                .frame(width: 400, alignment: .leading)

                Spacer().frame(height: 30)

                Button(action: onGetStarted) {
                    Text("Get Started")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(getStartedHovered ? SipDesign.blueHover : SipDesign.blue)
                .keyboardShortcut(.defaultAction)
                .onHover { getStartedHovered = $0 }

                Spacer()
            }
            // Single flexible frame so top/bottom Spacer() actually expand in tall
            // windows. Chaining a second .frame(maxWidth:) here would give the
            // VStack an intrinsic height and collapse the Spacers.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
    }

    private func featureRow(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(SipDesign.blue)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(SipDesign.textPrimary)
                Text(desc)
                    .font(.body)
                    .foregroundColor(SipDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
