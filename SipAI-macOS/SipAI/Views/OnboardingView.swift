// OnboardingView.swift
// First launch: the welcome page, and nothing after it. Get started
// records that onboarding is complete and lands in the main window —
// the chat page explains how a model is added, and the sidebar's ADD
// AGENTS row leads to Settings → Agent Guide for the command-line
// tools. Shown by ContentView while `config.needsOnboarding` is true.

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

    @State private var getStartedHovered: Bool = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            welcomeView
        }
        .onAppear { agents.reload(config: config) }
    }

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

            Text("Your AI, your way.")
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
                    desc: String(localized: "Chat with GPT, Claude, and more with your API keys.",
                                 comment: "Onboarding welcome bullet detail")
                )
                featureRow(
                    icon: "terminal",
                    title: String(localized: "Better local AI agent management",
                                  comment: "Onboarding welcome bullet title"),
                    // Labels through `agentLabel`, so a renamed agent is
                    // renamed here too; a String expression, never an
                    // interpolated Text literal.
                    desc: String(localized: "Run \(agentNamesJoined) from one window, on your subscription or API key.",
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
            .frame(maxWidth: 420, alignment: .leading)

            Spacer().frame(height: 36)

            // Get started button — 14pt font, 49/11 padding
            Button {
                finish()
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
