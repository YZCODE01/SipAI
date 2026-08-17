// MessageBubble.swift
// One message in the chat list: a bold label (e.g. `You:`) above the
// body, with no avatar icon — the label is coloured in the SipAI brand
// blue and the body is Markdown-rendered. User messages are wrapped in
// a soft grey block.
// The optional `assistantLabelOverride` lets the agent session column
// show the agent name (e.g. "Claude Code") in place of the generic AI
// label.
//
// Pointing at a message you SENT lifts its block and reveals a copy
// button in its lower-right corner — and, where the host offers one, a
// pencil that branches the conversation from that message. Only user
// messages carry either: the grey block already draws their bounds, so
// the affordances have an edge to sit on and a hover tint has something
// to tint. This view is shared by ChatView and the agent transcript, so
// both get it from one place.

import AppKit
import SwiftUI

struct MessageBubble: View {
    @EnvironmentObject var config: ConfigManager
    @Environment(\.sipFontScale) private var fontScale
    let message: ChatMessage

    /// Pointer is inside this message's block.
    @State private var hovering = false
    /// Copy landed — the button shows a checkmark for a moment so the
    /// click has an answer. Reverts on a timer rather than on hover-out:
    /// the confirmation should be visible without moving the mouse.
    @State private var copied = false

    /// Optional override for the assistant-side label. When nil (chat use),
    /// falls back to `config.display.aiLabel`. Pass a non-nil value from
    /// the agent session view so assistant rows show the agent name
    /// instead.
    var assistantLabelOverride: String? = nil

    /// Optional override for the user-side label. The agent session view
    /// passes one for harness-injected notices, which are user-role
    /// records the user never typed.
    var userLabelOverride: String? = nil

    /// Begin editing this message in order to branch from it. Nil means
    /// the host offers no branching here — a chat with nothing to fork
    /// yet, a read-only codex transcript, a session whose turn is still
    /// running — and the pencil simply isn't drawn. Editing itself is
    /// NOT this view's state: the caller swaps the bubble for a
    /// `BranchEditor`, because a transcript row is re-rendered on every
    /// streamed event and re-created wholesale by a history swap, and
    /// half-typed text must not depend on this view surviving either.
    var onEdit: (() -> Void)? = nil
    /// Tooltip for the pencil. The two hosts branch into different
    /// things ("session" vs "chat"), so the wording is theirs to supply.
    var editHint: String? = nil

    private var isUser: Bool { message.role == "user" }

    private var labelText: String {
        if isUser { return userLabelOverride ?? config.display.userLabel }
        return assistantLabelOverride ?? config.display.aiLabel
    }

    var body: some View {
        if isUser {
            userContent
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                // Hover tint goes in the BACKGROUND layer, stacked on the
                // block fill. Drawn as an overlay it would sit on top of
                // the text and wash it out.
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(ChatMarkdownStyle.userBlockBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.primary.opacity(hovering ? 0.05 : 0))
                        )
                )
                .overlay(alignment: .bottomTrailing) { hoverActions }
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onHover { inside in
                    hovering = inside
                    // Leaving resets the confirmation, so the next visit
                    // shows the copy glyph rather than a stale checkmark.
                    if !inside { copied = false }
                }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            assistantContent
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Hover actions (edit · copy)

    /// Lower-right corner of the block, only while pointed at. Sized and
    /// inset to sit inside the block's own padding, so they overlap the
    /// last line only when that line runs the full width.
    @ViewBuilder
    private var hoverActions: some View {
        if hovering {
            HStack(spacing: 4) {
                if let onEdit {
                    // Left of copy: branching is the bigger act.
                    iconButton(
                        systemName: "square.and.pencil",
                        tinted: false,
                        hint: editHint ?? String(
                            localized: "Create a new branch from here",
                            comment: "Default tooltip for the branch-from-here pencil on a sent message"),
                        action: onEdit
                    )
                }
                iconButton(
                    systemName: copied ? "checkmark" : "doc.on.doc",
                    tinted: copied,
                    hint: String(localized: "Copy this message",
                                 comment: "Tooltip for the copy button on a sent message"),
                    action: copyMessage
                )
            }
            .padding(6)
            .transition(.opacity)
        }
    }

    private func iconButton(systemName: String,
                            tinted: Bool,
                            hint: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tinted ? SipDesign.blue : ChatDesign.textSecondary)
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(SipDesign.borderLight, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(hint)
        .accessibilityLabel(hint)
    }

    private func copyMessage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.content, forType: .string)
        copied = true
        // Explicit MainActor: a View's methods are not isolated the way
        // its body is, so the state write after the sleep needs saying.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }

    @ViewBuilder
    private var userContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            MarkdownRenderer.render(message.content)
        }
    }

    @ViewBuilder
    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            MarkdownRenderer.render(message.content)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Text(labelText)
                .font(.system(size: 13 * fontScale, weight: .semibold))
                .foregroundColor(ChatMarkdownStyle.label)
            if !isUser, let model = message.model {
                Text(model)
                    .font(.system(size: 12))
                    .foregroundColor(ChatDesign.textSecondary)
                if let t = message.time {
                    Text(String(format: "· %.1fs", t))
                        .font(.system(size: 12))
                        .foregroundColor(ChatDesign.textHint)
                }
            }
            if isUser, let f = message.files, !f.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "paperclip")
                    Text(f)
                }
                .font(.system(size: 12))
                .foregroundColor(ChatDesign.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Branch editor

/// A sent message, opened for editing so the conversation can be
/// branched from it. Takes the place of the `MessageBubble` for that one
/// row — same grey block, same label, so the row keeps its position in
/// the transcript and the edit reads as happening *in* the conversation.
///
/// The text is a Binding because it lives on the HOST view, not here:
/// this row is re-rendered on every streamed event and re-created by a
/// history swap, and a half-typed edit must survive both. Same reason
/// `expandedToolResults` lives on `AgentSessionView` rather than on the
/// rows it describes.
///
/// Enter creates the branch, Shift+Enter adds a line, Escape cancels —
/// the idiom of every other inline editor in this app (the sidebar's
/// rename row, the empty-state tagline). No dialog, no confirmation:
/// nothing here destroys anything, since a branch leaves the original
/// conversation untouched.
struct BranchEditor: View {
    @EnvironmentObject var config: ConfigManager
    @Environment(\.sipFontScale) private var fontScale

    @Binding var text: String
    /// The fork is being written / the branch is starting. Both buttons
    /// go inert rather than vanishing, so the row doesn't resize under
    /// the pointer mid-click.
    var busy: Bool = false
    /// Sentence under the buttons explaining where the branch will go.
    /// The two hosts branch into different things, so the wording is
    /// theirs.
    var explanation: String
    var onCreate: () -> Void
    var onCancel: () -> Void

    private var canCreate: Bool {
        !busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(config.display.userLabel)
                .font(.system(size: 13 * fontScale, weight: .semibold))
                .foregroundColor(ChatMarkdownStyle.label)

            MultilineTextField(
                text: $text,
                onSubmit: { if canCreate { onCreate() } },
                onCancel: onCancel,
                autoFocus: true,
                spellChecking: config.display.spellCheck
            )
            // Grows with the message up to a point, then scrolls — a
            // long prompt must not push the buttons off screen.
            .frame(minHeight: 44, maxHeight: 260)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(SipDesign.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(SipDesign.borderLight, lineWidth: 1)
            )

            HStack(spacing: 8) {
                Text(explanation)
                    .font(.system(size: 11))
                    .foregroundColor(ChatDesign.textHint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if busy {
                    ProgressView().controlSize(.small)
                }
                Button(action: onCancel) {
                    Text("Cancel", comment: "Button that abandons a message edit without branching")
                        .font(.system(size: 12))
                }
                .controlSize(.small)
                .disabled(busy)
                Button(action: onCreate) {
                    Text("Create Branch",
                         comment: "Button that forks the conversation from the edited message")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canCreate)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(ChatMarkdownStyle.userBlockBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(SipDesign.blue.opacity(0.35), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
