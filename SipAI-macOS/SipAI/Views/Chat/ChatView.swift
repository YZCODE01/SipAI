// ChatView.swift
// Center pane: empty-state (logo + banner + centered input) or message list + bottom input.

import SwiftUI

extension Notification.Name {
    /// Posted by the sidebar after an in-place rename so an open ChatView
    /// can refresh its stale `liveTitle` (userInfo: slug, project, title).
    static let sipChatRenamed = Notification.Name("sipChatRenamed")
}

// MARK: - Adaptive design constants

enum ChatDesign {
    static let blue = Color(red: 37/255, green: 99/255, blue: 235/255) // #2563EB — brand, unchanged

    // Adaptive colors via NSColor.dynamicProvider
    static let textPrimary = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 229/255, green: 229/255, blue: 231/255, alpha: 1) // #E5E5E7
            : NSColor(red: 29/255, green: 29/255, blue: 31/255, alpha: 1)    // #1D1D1F
    }))
    static let textSecondary = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 142/255, green: 142/255, blue: 147/255, alpha: 1) // #8E8E93
            : NSColor(red: 134/255, green: 134/255, blue: 139/255, alpha: 1) // #86868B
    }))
    static let textHint = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 99/255, green: 99/255, blue: 102/255, alpha: 1)   // #636366
            : NSColor(red: 174/255, green: 174/255, blue: 178/255, alpha: 1) // #AEAEB2
    }))
    static let border = Color(nsColor: .separatorColor)
    static let cardBg = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 44/255, green: 44/255, blue: 46/255, alpha: 1)    // #2C2C2E
            : NSColor(red: 249/255, green: 250/255, blue: 251/255, alpha: 1) // #F9FAFB
    }))
}

// The sampled geometry and the follow rule are shared with the agent
// transcript — `Utilities/TranscriptFollow.swift`. Keep it that way:
// a second spelling of the rule here would have to be kept in step by
// hand.

/// Sizing for the empty-state tagline against its two caps: the text box
/// may be at most `maxWidth` wide (what's left of 75% of the input card
/// after the logo) and at most `maxHeight` tall (80% of the logo).
///
/// The order the constraints give way in follows the hero's spec: at the
/// base font the text first GROWS IN WIDTH to the cap (it simply hasn't
/// wrapped yet), then IN HEIGHT by wrapping onto more lines, and only
/// when even that exceeds the height cap does the FONT step down. The
/// loop below is that rule verbatim — try each size at full wrap width,
/// keep the first whose wrapped height fits.
///
/// `width` is the measured wrap width (+2 pt of float slack), so the
/// display frame hugs the text and the hero pair centres as a unit.
/// Fixing the frame at the measured width cannot re-wrap the text:
/// every line fits inside it by construction, and greedy line breaking
/// at any width between the longest line and the cap breaks identically.
///
/// Internal (not fileprivate) so the headless verification harness can
/// exercise it — same precedent as `MarkdownRenderer.parseTableCells`.
enum TaglineFit {
    static let baseFontSize: CGFloat = 28
    /// Floor before truncation. 100 CJK characters at the default card
    /// width fit at ~12 pt; below 11 the hero reads as fine print.
    static let minFontSize: CGFloat = 11

    struct Result: Equatable {
        var fontSize: CGFloat
        /// Wrap width for the display frame, ≤ the cap.
        var width: CGFloat
        /// Rows that fit the height cap at `fontSize` — the truncation
        /// guard for the floor case (extreme: narrow pane + 100 CJK).
        var lineLimit: Int
    }

    static func fit(_ text: String,
                    maxWidth: CGFloat,
                    maxHeight: CGFloat) -> Result {
        let subject = text.isEmpty ? " " : text
        var size = baseFontSize
        while size > minFontSize {
            let measured = measure(subject, fontSize: size, wrapWidth: maxWidth)
            if measured.height <= maxHeight {
                return Result(fontSize: size,
                              width: min(maxWidth, measured.width + 2),
                              lineLimit: lineCapacity(fontSize: size,
                                                      maxHeight: maxHeight))
            }
            size -= 1
        }
        let measured = measure(subject, fontSize: minFontSize, wrapWidth: maxWidth)
        return Result(fontSize: minFontSize,
                      width: min(maxWidth, measured.width + 2),
                      lineLimit: lineCapacity(fontSize: minFontSize,
                                              maxHeight: maxHeight))
    }

    /// Whole lines of this font that fit under the cap.
    static func lineCapacity(fontSize: CGFloat, maxHeight: CGFloat) -> Int {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let lineHeight = font.ascender - font.descender + font.leading
        return max(1, Int(maxHeight / lineHeight))
    }

    /// TextKit measurement in the hero's own attributes (semibold,
    /// −0.5 kern to match `.tracking(-0.5)`).
    static func measure(_ text: String,
                        fontSize: CGFloat,
                        wrapWidth: CGFloat) -> CGSize {
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .kern: -0.5,
            ])
        let rect = attributed.boundingRect(
            with: CGSize(width: wrapWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }
}

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var chats: ChatManager
    @EnvironmentObject var agents: AgentManager
    @EnvironmentObject var notesManager: NotesManager

    @State private var draft: String = ""
    /// Identity `draft` was typed under, and the stash target on the
    /// NEXT switch. nil until the first appear — see `syncComposerDraft`
    /// for why that distinction is load-bearing. The stash itself lives
    /// on AppState, which outlives this view; ContentView's router
    /// replaces ChatView outright whenever an agent session or a note is
    /// opened, so a view-owned draft was gone by the time the user came
    /// back.
    @State private var loadedDraftKey: String? = nil
    /// Born at the bottom edge, so a chat opens on its newest message
    /// in its first painted frame. This view is NOT re-created per
    /// chat, so a switch re-issues the request explicitly.
    @State private var chatScrollPosition = ScrollPosition(edge: .bottom)
    /// The follow rule, shared with the agent transcript. A class in
    /// plain `@State` — nothing it holds is rendered, so mutating it
    /// must not invalidate this body.
    @State private var follow = TranscriptFollow(label: "chat")
    /// How many of the newest messages render. The message stack is
    /// laid out EAGERLY (see the ScrollView's note below), so this is
    /// the knob that bounds that cost. Smaller step than the agent
    /// transcript's `historyDisplayCap` (+200): one chat row is a whole
    /// turn, where one transcript row is a single tool call.
    /// Reset per chat by `reloadFromAppState`; this view is reused
    /// across chats rather than re-created, so nothing else resets it.
    @State private var messageDisplayCap = 40
    @State private var liveMessages: [ChatMessage] = []
    @State private var liveTitle: String = ""
    /// `last_user_message_at` of the loaded chat, carried in live state
    /// because `persistChat` rebuilds the `StoredChat` on every save.
    @State private var liveLastUserMessageAt: Date? = nil
    /// Identity (slug + project) of the chat `liveMessages`/`liveTitle`
    /// belong to. Persisting keys off THIS, never `appState.openChat*`:
    /// by the time `.onChange` fires, appState already points at the
    /// incoming chat, and saving live state under its slug would copy
    /// one conversation's content into another's file.
    @State private var loadedChatSlug: String? = nil
    @State private var loadedChatProject: String? = nil
    @State private var errorBanner: String? = nil
    @State private var infoBanner: String? = nil
    @State private var noteGenerating: Bool = false
    /// Files staged for the NEXT send — picked with the + button or
    /// dropped onto the composer. Loaded at stage time, so what is
    /// here is already known to be sendable.
    @State private var pendingAttachments: [ChatAttachment] = []
    /// The sent message currently open for editing, and its draft text.
    /// Held HERE rather than inside the row: this view rebuilds its
    /// message list on every reload, and a half-typed edit must not
    /// depend on one row surviving. Reset by `reloadFromAppState` on a
    /// real chat switch, so an edit can't follow the user to another
    /// conversation.
    @State private var editingMessageId: UUID? = nil
    @State private var editDraft: String = ""
    /// Tagline editing (empty-state hero). The draft is discarded by
    /// anything other than Save — Cancel, Escape, clicking elsewhere,
    /// or navigating away (this view's @State dies with the route).
    @State private var editingTagline = false
    @State private var taglineDraft = ""
    @State private var taglineHovered = false
    @FocusState private var taglineFocused: Bool
    /// Live width of the empty state, for the "75% of the chatbox"
    /// rule — the card is `min(640, pane − 40)` wide, so the cap can't
    /// be a constant on narrow panes.
    @State private var emptyStateWidth: CGFloat = 0
    /// Cmd+F over this conversation. Owned here, not by the bar: the
    /// composer's button toggles it and a global-search result seeds
    /// it, so it has to outlive the bar's own appearance. Every message
    /// is resident (`liveMessages`), so unlike the agent transcript
    /// this one always searches the WHOLE chat.
    @StateObject private var find = TranscriptFindState()
    @Environment(\.sipFontScale) private var fontScale

    private var apiClient: APIClient { APIClient(config: config) }

    /// Whether THIS chat has a reply in flight — asked of the manager,
    /// never held here.
    ///
    /// The router replaces this view on every detour, so a view-owned
    /// flag describes the pane rather than the turn: it comes back
    /// false for a chat whose turn is still running, leaving the
    /// composer idle, the clock stopped and Stop with nothing to stop.
    /// Deriving it means returning to a chat mid-turn shows the turn.
    private var sending: Bool {
        guard let slug = loadedChatSlug, !slug.isEmpty else { return false }
        return chats.isChatInFlight(slug: slug, project: loadedChatProject)
    }

    /// The in-flight turn's own start time, so the "Sipping… (m:ss)"
    /// clock counts from the send rather than from whenever this view
    /// happened to be created.
    private var turnStartedAt: Date? {
        guard let slug = loadedChatSlug, !slug.isEmpty else { return nil }
        return chats.chatTurn(slug: slug, project: loadedChatProject)?.startedAt
    }

    private var isEmptyState: Bool {
        liveMessages.isEmpty && !sending
    }

    /// The newest `messageDisplayCap` messages — the eagerly laid-out
    /// window. Everything older is one "Show earlier" click away.
    private var displayedMessages: ArraySlice<ChatMessage> {
        liveMessages.suffix(messageDisplayCap)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isEmptyState {
                emptyStateView
            } else {
                chatMessagesView
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Transcript text tracks the sidebar row size, exactly like the
        // agent session view — the two center columns must not differ.
        .environment(\.sipFontScale, SipFont.contentScale(fontScale))
        // Cmd+F. A zero-size invisible button rather than an app-level
        // menu command: the shortcut has to reach the conversation that
        // is actually on screen, and the router replaces this view
        // whenever that changes.
        .background {
            Button {
                if find.isOpen { find.close() } else { find.open() }
                refreshFind()
            } label: { Color.clear }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
            .disabled(liveMessages.isEmpty)
        }
        .onAppear {
            reloadFromAppState()
            consumePendingFind()
        }
        .onChange(of: appState.openChatSlug) { _, _ in reloadFromAppState() }
        .onChange(of: appState.openChatProject) { _, _ in reloadFromAppState() }
        .onChange(of: appState.pendingFindQuery) { _, _ in consumePendingFind() }
        // Every keystroke goes straight to the store — see
        // `stashComposerDraft`. This is deliberately NOT an
        // `.onDisappear` stash: unsent text must not depend on a
        // teardown callback firing, in order, with live state still
        // readable.
        .onChange(of: draft) { _, _ in stashComposerDraft() }
        .onDisappear {
            // Same file-exists guard as the switch-time save: a chat
            // deleted outside the app (Finder, sync) must not be
            // resurrected just because a note or session was opened.
            guard !liveMessages.isEmpty else { return }
            if let slug = loadedChatSlug {
                let url = SipaiPaths.chatStateFile(slug: slug, project: loadedChatProject)
                guard FileManager.default.fileExists(atPath: url.path) else { return }
            }
            persistCurrentChat()
        }
        // A reply (or a failure) delivered to this chat by the manager,
        // possibly while the user was looking at something else. The
        // reply is already on disk — this is what puts it on screen
        // without making the user switch away and back to see it.
        .onReceive(NotificationCenter.default.publisher(for: .sipChatMessagesChanged)) { note in
            guard let slug = note.userInfo?["slug"] as? String,
                  slug == loadedChatSlug,
                  (note.userInfo?["project"] as? String ?? "")
                      == (loadedChatProject ?? "") else { return }
            reloadMessagesFromDisk()
            applyTurnOutcome()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sipChatRenamed)) { note in
            // Keep the title bar (and the next persist) in sync when the
            // open chat is renamed from the sidebar — a stale `liveTitle`
            // would silently write the old name back on the next save.
            guard let slug = note.userInfo?["slug"] as? String,
                  slug == loadedChatSlug,
                  (note.userInfo?["project"] as? String ?? "") == (loadedChatProject ?? ""),
                  let title = note.userInfo?["title"] as? String else { return }
            liveTitle = title
        }
    }

    // MARK: - Empty state (centered logo + banner + input)

    // MARK: Hero metrics

    private static let heroLogoHeight: CGFloat = 67
    private static let heroSpacing: CGFloat = 12
    /// Rendered width of the logo at its fixed height, from the asset's
    /// own aspect ratio (square fallback if the asset ever goes missing).
    private static let heroLogoWidth: CGFloat = {
        guard let image = NSImage(named: "SipAI-Logo-67"),
              image.size.height > 0 else { return heroLogoHeight }
        return image.size.width * (heroLogoHeight / image.size.height)
    }()

    /// The input card's rendered width — its 640 cap, or the pane minus
    /// the card's own 20-pt margins when the pane is narrower. The
    /// tagline's width rule is phrased against THIS ("the chatbox"),
    /// not the pane.
    private var heroCardWidth: CGFloat {
        emptyStateWidth > 0 ? min(640, max(0, emptyStateWidth - 40)) : 640
    }

    /// Wrap cap for the tagline: 75% of the card, minus the logo and
    /// the gap — floored so a pathological pane can't drive it to zero.
    private var taglineMaxTextWidth: CGFloat {
        max(60, 0.75 * heroCardWidth - Self.heroLogoWidth - Self.heroSpacing)
    }

    /// Height cap: 80% of the logo.
    private var taglineMaxTextHeight: CGFloat { 0.8 * Self.heroLogoHeight }

    private var emptyStateView: some View {
        VStack(spacing: 0) {
            Spacer()

            // Horizontal layout: logo on the left, tagline on the right.
            // `.bottom` keeps the text's last row on the cup's bottom
            // edge however many rows the tagline wraps to; the size caps
            // and their give-way order live in `TaglineFit`.
            HStack(alignment: .bottom, spacing: Self.heroSpacing) {
                // Size-matched rendition — see LeftSidebar's brand header.
                Image("SipAI-Logo-67")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: Self.heroLogoHeight)

                if editingTagline {
                    taglineEditor
                } else {
                    taglineDisplay
                }
            }
            // The editor's Save/Cancel hang BELOW the hero's bounds, into
            // the region later siblings (banners) occupy — and later
            // siblings sit above earlier ones in a VStack's z-order.
            // Lift the hero while editing so the buttons stay clickable.
            .zIndex(editingTagline ? 1 : 0)

            // Subtitle shown only when no chat model is configured —
            // distinguishes agent-only mode from an empty install.
            if !config.hasChatModel {
                Spacer().frame(height: 16)
                Group {
                    if agents.hasInstalledAgent {
                        Text("Agent-only mode — pick an agent session from the sidebar, or add a chat model in Settings → Models.",
                             comment: "Empty-state subtitle shown when no chat model is configured but an agent CLI is installed.")
                    } else {
                        Text("No chat model configured. Add one in Settings → Models.",
                             comment: "Empty-state subtitle shown when no chat model and no agent CLI is available.")
                    }
                }
                .font(.system(size: 13))
                .foregroundColor(ChatDesign.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .padding(.horizontal, 20)
            }

            Spacer().frame(height: 40)

            // Banners must render here too — a send that fails while
            // the chat is still empty (no model configured) otherwise
            // showed nothing at all.
            bannerStack

            // Centered unified input card. While the tagline is being
            // edited the card is inert — a click on it is "clicked
            // somewhere else", which cancels the edit (the click falls
            // through to the catcher on the container's background).
            UnifiedInputCard(
                draft: $draft,
                sending: sending,
                noteGenerating: $noteGenerating,
                // Empty state: nothing to summarise and nothing to
                // find, so both controls are dimmed by the same flag.
                canGenerateNote: !liveMessages.isEmpty,
                find: find,
                onSend: send,
                onStop: stopSending,
                onUpload: handleUpload,
                attachments: pendingAttachments,
                onRemoveAttachment: removeAttachment,
                onDropFiles: stageAttachments,
                onGenerateNote: generateNote,
                onSelectProject: changeProject,
                onToggleFind: { refreshFind() }
            )
            .allowsHitTesting(!editingTagline)
            .frame(maxWidth: 640)
            .padding(.horizontal, 20)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Click-away = cancel. Only mounted while editing, so the
            // rest of the time the empty state has no tap target at
            // all. Clicks on the disabled card and on the page's dead
            // space both land here.
            if editingTagline {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { cancelTaglineEdit() }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width },
                          action: { emptyStateWidth = $0 })
    }

    // MARK: - Tagline hero

    private var taglineDisplay: some View {
        let fit = TaglineFit.fit(config.display.tagline,
                                 maxWidth: taglineMaxTextWidth,
                                 maxHeight: taglineMaxTextHeight)
        return Text(verbatim: config.display.tagline)
            .font(.system(size: fit.fontSize, weight: .semibold))
            .tracking(-0.5)
            .foregroundColor(SipDesign.textPrimary)
            .lineLimit(fit.lineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: fit.width, alignment: .bottomLeading)
            .background(
                // Negative padding inflates the hover wash beyond the
                // text without adding layout size — the hero must not
                // shift a pixel on hover.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(taglineHovered ? 0.14 : 0))
                    .padding(-6)
            )
            .animation(.easeInOut(duration: 0.12), value: taglineHovered)
            .contentShape(Rectangle())
            .onHover { taglineHovered = $0 }
            .onTapGesture { beginTaglineEdit() }
            .help(String(localized: "Click to write your own tagline",
                         comment: "Tooltip on the empty-state hero text"))
            .accessibilityAddTraits(.isButton)
    }

    private var taglineEditor: some View {
        // Sized live against the DRAFT, so the font steps down mid-edit
        // exactly as the saved result will render. The frame stays at
        // the full cap while editing — a box that tracked the text
        // width would slide the logo on every keystroke.
        let fit = TaglineFit.fit(taglineDraft,
                                 maxWidth: taglineMaxTextWidth,
                                 maxHeight: taglineMaxTextHeight)
        return TextField(String(localized: "Your tagline",
                                comment: "Placeholder in the empty-state tagline editor"),
                         text: $taglineDraft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: fit.fontSize, weight: .semibold))
            .foregroundColor(SipDesign.textPrimary)
            .focused($taglineFocused)
            .onSubmit { saveTagline() }
            .onExitCommand { cancelTaglineEdit() }
            .frame(width: taglineMaxTextWidth, alignment: .leading)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(SipDesign.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(SipDesign.borderLight, lineWidth: 1)
            )
            // Save / Cancel + the counter hang under the editor box,
            // right-aligned to it — an overlay, so they track the box as
            // it grows and never re-centre the hero. bottomTrailing +
            // offset rather than a VStack row: making them part of the
            // layout would drag the FIELD's bottom off the cup's bottom
            // edge (the HStack aligns whole-view bottoms).
            .overlay(alignment: .bottomTrailing) {
                taglineEditButtons
                    .offset(y: 34)
            }
            .onAppear { taglineFocused = true }
            .onChange(of: taglineFocused) { _, focused in
                // Focus moved into some other field without Save —
                // same outcome as clicking elsewhere. Save's own click
                // doesn't land here: buttons don't take key focus, and
                // by the time the field unmounts `editingTagline` is
                // already false.
                if focused {
                    // The whole text arrives selected, so replacing it
                    // is one keystroke — same as the rename fields.
                    FocusedFieldSelection.selectAll()
                } else if editingTagline {
                    cancelTaglineEdit()
                }
            }
            .onChange(of: taglineDraft) { _, new in
                // Enforce shape, not content: taglines are one line of
                // any language, so newlines flatten to spaces and the
                // count caps at the limit. Mutate only on violation —
                // rewriting the binding on every keystroke breaks IME
                // composition (CJK input goes through marked text).
                var text = new
                if text.contains("\n") {
                    text = text.replacingOccurrences(of: "\n", with: " ")
                }
                if text.count > DisplaySettings.taglineCharLimit {
                    text = String(text.prefix(DisplaySettings.taglineCharLimit))
                }
                if text != new { taglineDraft = text }
            }
    }

    /// Save / Cancel + counter for the tagline edit, hung under the
    /// editor box's lower-right corner (see the editor's overlay).
    private var taglineEditButtons: some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(taglineDraft.count)/\(DisplaySettings.taglineCharLimit)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundColor(SipDesign.textHint)
            Button {
                cancelTaglineEdit()
            } label: {
                Text("Cancel", comment: "Tagline editor button")
                    .font(.system(size: 12))
            }
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            Button {
                saveTagline()
            } label: {
                Text("Save", comment: "Tagline editor button")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func beginTaglineEdit() {
        guard !editingTagline else { return }
        taglineDraft = config.display.tagline
        editingTagline = true
    }

    private func cancelTaglineEdit() {
        editingTagline = false
        taglineFocused = false
    }

    private func saveTagline() {
        guard editingTagline else { return }
        var text = taglineDraft
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > DisplaySettings.taglineCharLimit {
            text = String(text.prefix(DisplaySettings.taglineCharLimit))
        }
        // Saving empty restores the default — a blank hero would leave
        // nothing on screen to click, a dead end.
        let final = text.isEmpty ? DisplaySettings.defaultTagline : text
        config.setDisplay { $0.tagline = final }
        editingTagline = false
        taglineFocused = false
    }

    /// Error + info banners, shared by the empty state and the message
    /// list so failures are visible in both.
    @ViewBuilder
    private var bannerStack: some View {
        if let err = errorBanner {
            bannerView(icon: "exclamationmark.triangle", color: .red, text: err) {
                errorBanner = nil
            }
        }
        if let info = infoBanner {
            bannerView(icon: "info.circle", color: SipDesign.blue, text: info) {
                infoBanner = nil
            }
        }
    }

    // MARK: - Chat messages state (scrollable messages + bottom input)

    private var chatMessagesView: some View {
        VStack(spacing: 0) {
            // Chat title bar. Project and role indicators moved into the
            // input card's chips (ProjectSelector / RoleSelector).
            HStack {
                Text(liveTitle.isEmpty ? String(localized: "New Chat", comment: "Default chat title") : liveTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SipDesign.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 90)
            .padding(.top, 8)
            .padding(.bottom, 8)

            // Find bar — under the title, above everything else, so it
            // never covers the composer or the newest turn.
            if find.isOpen {
                FindBar(find: find)
                    .padding(.horizontal, 90)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }

            // Error/info banners
            bannerStack

            // Message list. Same positioning contract as the agent
            // transcript (see AgentSessionView's bottom-follow notes):
            // the scroll view is BORN at its bottom edge, and the only
            // rule afterwards is "content grew under a reader who was
            // already at the end → stay at the end". No scrollTo(id:)
            // into lazy content, no deferred hop to let rows realise.
            //
            // The stack is a plain VStack, NOT a LazyVStack — the same
            // rule as `AgentSessionView.transcriptStack`. A lazy stack
            // does not know its own height until its rows realise, so
            // the bottom edge the scroll view is born at is an ESTIMATE,
            // and the follow rule above is judging growth against a
            // number that moves as rows realise. Eager rows make the
            // height exact, so there is no estimate to be wrong.
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if liveMessages.count > messageDisplayCap {
                        Button {
                            messageDisplayCap += 40
                        } label: {
                            Text(String(localized: "Show earlier — \(liveMessages.count - messageDisplayCap) older messages",
                                        comment: "Button above a truncated chat; placeholder is the hidden message count"))
                                .font(.system(size: 12))
                                .foregroundColor(ChatDesign.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(displayedMessages, id: \.id) { msg in
                        Group {
                            if editingMessageId == msg.id {
                                BranchEditor(
                                    text: $editDraft,
                                    // A reply can start while the editor
                                    // is open (the composer is still
                                    // live below it) and `send()` refuses
                                    // to overlap turns — so the branch
                                    // would be created and then never
                                    // sent into. Hold the button instead.
                                    busy: sending,
                                    explanation: String(
                                        localized: "Starts a new chat from this point. This one is kept as it is.",
                                        comment: "Explanation under the branch editor in a chat"),
                                    onCreate: { createChatBranch(from: msg.id) },
                                    onCancel: cancelMessageEdit
                                )
                            } else {
                                MessageBubble(
                                    message: displayMessage(msg),
                                    onEdit: canBranch(from: msg)
                                        ? { beginMessageEdit(msg) } : nil,
                                    editHint: String(
                                        localized: "Create a new chat branch from here",
                                        comment: "Tooltip for the branch pencil on a sent chat message")
                                )
                            }
                        }
                        .id(msg.id)
                        // This row's slice of the find: the query plus
                        // how many matches precede it. `.inactive` — and
                        // free — whenever the bar is closed.
                        .environment(\.sipSearchSlot, find.slot(forRow: msg.id))
                    }
                    if sending, let startedAt = turnStartedAt {
                        TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
                            let elapsed = AgentRendering.formatTime(
                                context.date.timeIntervalSince(startedAt)
                            )
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Sipping\u{2026} (\(elapsed))",
                                     comment: "Shown while waiting for the model")
                                    .font(.system(size: 13))
                                    .foregroundColor(SipDesign.textSecondary)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 16)
            }
            .scrollPosition($chatScrollPosition)
            .onScrollGeometryChange(for: TranscriptGeometry.self) { geo in
                TranscriptGeometry(geo)
            } action: { old, new in
                if follow.geometryChanged(from: old, to: new) == .snapToEnd {
                    chatScrollPosition.scrollTo(edge: .bottom)
                }
            }
            // Who is moving the scroll view, asked of the scroll view
            // itself — geometry deltas can say the end moved but never
            // whose hand did it.
            .onScrollPhaseChange { _, phase, context in
                if follow.phaseChanged(to: phase,
                                       geometry: TranscriptGeometry(context.geometry)) {
                    chatScrollPosition.scrollTo(edge: .bottom)
                }
            }
            .onChange(of: liveMessages.count) { _, _ in
                // Real content — restores the geometry path's snap
                // budget so a streaming reply keeps following.
                follow.noteInput()
                refreshFind()
            }
            .onChange(of: appState.openChatSlug) { _, _ in
                // A different conversation entirely — always its end.
                follow.forceFollow()
                chatScrollPosition.scrollTo(edge: .bottom)
            }
            .onChange(of: sending) { _, isSending in
                // A send is always user-initiated, so this one is
                // unconditional: you should see your own message and
                // the progress row under it even if you had scrolled
                // up to reread something first. (The agent transcript
                // does the same via its runner-status change.)
                //
                // Not while a find is anchored: the reader is standing
                // on a match, and yanking them to the end of the chat
                // is the same interruption the follow engine was taught
                // not to make.
                guard isSending, !find.isAnchored else { return }
                follow.forceFollow()
                withAnimation { chatScrollPosition.scrollTo(edge: .bottom) }
            }
            .onChange(of: find.query) { _, _ in
                // Incremental find: each keystroke re-counts, and the
                // move to match 1 lands once the typing settles — see
                // `requestJumpSettled`.
                refreshFind()
                find.requestJumpSettled()
            }
            .onChange(of: find.isOpen) { _, open in
                refreshFind()
                if !open {
                    // Closing returns the reader to where a transcript
                    // always belongs.
                    follow.forceFollow()
                    chatScrollPosition.scrollTo(edge: .bottom)
                }
            }
            .onChange(of: find.jumpNonce) { _, _ in
                jumpToActiveMatch(proxy)
            }
            }

            // Bottom unified input card — same margins as the agent
            // session's composer (AgentSessionView.inputArea).
            UnifiedInputCard(
                draft: $draft,
                sending: sending,
                noteGenerating: $noteGenerating,
                canGenerateNote: !liveMessages.isEmpty,
                find: find,
                onSend: send,
                onStop: stopSending,
                onUpload: handleUpload,
                attachments: pendingAttachments,
                onRemoveAttachment: removeAttachment,
                onDropFiles: stageAttachments,
                onGenerateNote: generateNote,
                onSelectProject: changeProject,
                onToggleFind: { refreshFind() }
            )
            .padding(.horizontal, 60)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Banner helper

    private func bannerView(icon: String, color: Color, text: String, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color.opacity(0.8))
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(SipDesign.textPrimary)
            Spacer()
            Button("Dismiss") { onDismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SipDesign.textSecondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(color.opacity(0.15), lineWidth: 1)
                )
        )
        .padding(.horizontal, 90)
        .padding(.bottom, 8)
    }

    // MARK: - Find in conversation

    /// Recompute the match list. Every message is resident here, so a
    /// chat's counter always describes the WHOLE conversation — unlike
    /// the agent transcript, which reads a bounded tail and has to say
    /// so.
    ///
    /// The closure is only run when a query is live (`refresh` guards
    /// it), which is what keeps `plainText` off the render path of a
    /// chat nobody is searching.
    private func refreshFind() {
        find.refresh {
            // Counted on what the transcript DRAWS: an inlined
            // attachment is stripped from the bubble, so a match
            // inside one would be a number with nothing to tint.
            liveMessages.map {
                FindableRow(id: $0.id,
                            text: MarkdownRenderer.plainText(
                                ChatAttachment.strippingInlineBlocks(from: $0.content)))
            }
        }
    }

    /// Bring the active match on screen, growing the rendered window
    /// first when the match is older than it.
    private func jumpToActiveMatch(_ proxy: ScrollViewProxy) {
        guard let match = find.activeMatch else { return }
        // The window is a SUFFIX, so what matters is the match's
        // distance from the newest message.
        let fromEnd = liveMessages.count - match.rowIndex
        // Restores the follow engine's snap budget — our own jump
        // produces geometry samples, and the engine must be able to
        // spend them. The sample itself is what takes the transcript
        // out of follow mode, so nothing pulls back to the end.
        follow.noteInput()
        guard fromEnd > messageDisplayCap else {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(match.rowId, anchor: .center)
            }
            return
        }
        messageDisplayCap = fromEnd + 5
        // The row does not exist until the widened window has been laid
        // out; an id scrolled to in the same pass resolves to nothing.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(match.rowId, anchor: .center)
            }
        }
    }

    /// Adopt a query handed over by a global-search result.
    ///
    /// The match pass is DEFERRED one runloop turn: the route that
    /// carried this query may still be settling, and matching against
    /// the outgoing conversation's messages would land the reader on a
    /// match in the wrong chat.
    private func consumePendingFind() {
        guard let query = appState.pendingFindQuery, !query.isEmpty else { return }
        // Only when a chat is actually the open route. This view is
        // also the router's fallback (the empty welcome state), and
        // eating the query there would strand a session's find.
        guard appState.openChatSlug != nil else { return }
        appState.pendingFindQuery = nil
        find.open(seed: query)
        DispatchQueue.main.async {
            refreshFind()
            find.requestJump()
        }
    }

    // MARK: - Attachments

    /// Stage files for the next message. Shared by the + button and by
    /// a drop onto the composer, so both refuse the same things in the
    /// same words.
    ///
    /// Every file is read, decoded and measured HERE rather than at
    /// send. A file the app cannot use is something to learn while
    /// still picking files; the same refusal at send costs a typed
    /// message and produces no reply.
    private func stageAttachments(_ urls: [URL]) {
        var refused: [String] = []
        var staged = false
        for url in urls where url.isFileURL {
            guard pendingAttachments.count < AttachmentLimits.maxPerMessage else {
                refused.append(AttachmentError.tooMany.localizedDescription)
                break
            }
            // The same file dropped twice is one attachment.
            guard !pendingAttachments.contains(where: { $0.url == url }) else { continue }
            do {
                pendingAttachments.append(try ChatAttachment.load(url))
                staged = true
            } catch {
                refused.append(error.localizedDescription)
            }
        }
        if !refused.isEmpty {
            errorBanner = refused.joined(separator: "\n")
        }
        // The chips are the receipt for a successful attach. The banner
        // is spent only on what a chip cannot show — that a file was
        // cut short, which changes what the model will actually read.
        // PDFs and text files have DIFFERENT ceilings (a PDF's text is
        // billed once, an inlined file rides every later turn), so the
        // sentence is grouped per ceiling rather than naming one number
        // that is wrong for half the files.
        if staged {
            let cut = pendingAttachments.filter { $0.textTruncated }
            if !cut.isEmpty {
                let byCap = Dictionary(grouping: cut) { a in
                    if case .pdf = a.kind { return AttachmentLimits.pdfTextCharLimit }
                    return AttachmentLimits.textCharLimit
                }
                infoBanner = byCap.sorted { $0.key < $1.key }.map { cap, files in
                    String(
                        localized: "Only the first \(cap / 1000)k characters of \(files.map(\.name).joined(separator: ", ")) are sent.",
                        comment: "Banner: an attached file was truncated to the inline limit")
                }.joined(separator: "\n")
            }
        }
    }

    private func handleUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Attach",
                              comment: "Confirm button of the chat attachment picker")
        panel.message = String(localized: "Select files to attach to your message",
                               comment: "Prompt of the chat attachment picker")
        guard panel.runModal() == .OK else { return }
        stageAttachments(panel.urls)
    }

    private func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// The message body as it will be STORED, and therefore replayed on
    /// every later turn: text attachments inlined ahead of what the
    /// user typed, so a follow-up question about the file still has the
    /// file. Images and PDFs are deliberately absent — they ride the
    /// one request that carries them (see `ChatAttachment`).
    private func outgoingContent(for text: String) -> String {
        let blocks = pendingAttachments.compactMap { a -> String? in
            guard a.isText, let t = a.text else { return nil }
            return ChatAttachment.inlineBlock(name: a.name, text: t,
                                              truncated: a.textTruncated)
        }
        guard !blocks.isEmpty else { return text }
        return blocks.joined(separator: "\n\n") + "\n\n" + text
    }

    /// A stored message as the transcript DRAWS it: inlined attachment
    /// blocks removed. The paperclip line under the bubble already
    /// names the files, and a 50k-character dump between the reader and
    /// their own question is a wall to scroll past.
    ///
    /// Display only — the stored message keeps the block, which is what
    /// makes the follow-up turn work. `refreshFind` applies the same
    /// transform, or the counter would name matches nothing tints.
    private func displayMessage(_ m: ChatMessage) -> ChatMessage {
        guard m.role == "user" else { return m }
        let stripped = ChatAttachment.strippingInlineBlocks(from: m.content)
        guard stripped != m.content else { return m }
        return ChatMessage(id: m.id, role: m.role, content: stripped,
                           model: m.model, time: m.time, tokens: m.tokens,
                           files: m.files)
    }

    // MARK: - Data loading & sending

    /// Stash the outgoing chat's unsent text and restore the incoming
    /// chat's — the same contract `AgentSessionView` keeps for sessions,
    /// and for the same reason: a half-written message must survive
    /// clicking away, and must never follow the user into a different
    /// conversation.
    ///
    /// Keyed off the LOADED identity, never `appState.openChat*`: by the
    /// time this runs the routing fields already name the incoming chat,
    /// so stashing under them would file the outgoing text on the wrong
    /// conversation — the same trap `persistChat` documents.
    ///
    /// A nil `loadedDraftKey` means "first pass of a freshly created
    /// view", which has no outgoing text to stash. Stashing the empty
    /// composer under the incoming key there would delete the very draft
    /// this is about to restore.
    private func syncComposerDraft() {
        // A session, a note or a new-session draft taking the centre
        // pane NILS `openChatSlug` on its way in (AppState's didSet).
        // That is not the user opening a new chat, and re-keying on it
        // would leave `loadedDraftKey` pointing at the new-chat slot —
        // so the next write-through stash would file this chat's text
        // there, erasing whatever was actually typed for a new chat.
        // Whether SwiftUI delivers that onChange before the teardown or
        // not is not something to depend on; this makes the two orders
        // equivalent.
        //
        // `openScheduledTaskName` belongs in this list too: a task with
        // no runs yet opens `AgentSessionView` on that field ALONE
        // (ContentView's router tests for it), with no session id to
        // trip the first guard. Without it, clicking such a task re-keys
        // this view onto the new-chat slot on its way out — exactly the
        // hole the guard exists to close.
        guard appState.openAgentSessionId == nil,
              appState.openNoteId == nil,
              appState.openScheduledTaskName == nil,
              appState.pendingClaudeSessionDraft == nil else { return }
        let newKey = AppState.chatDraftKey(slug: appState.openChatSlug,
                                           project: appState.openChatProject)
        if let old = loadedDraftKey, old != newKey {
            appState.setComposerDraft(draft, for: old)
        }
        if loadedDraftKey != newKey {
            draft = appState.composerDraft(for: newKey)
            loadedDraftKey = newKey
        }
    }

    /// Write the live text through to the store on every change, so the
    /// store is ALWAYS current.
    ///
    /// A teardown stash would make a half-written message depend on one
    /// callback firing with `@State` still readable — and when that
    /// read comes back as the initial "", `setComposerDraft("")` does
    /// not merely fail to save, it DELETES the key and takes the
    /// stashed text with it. Same rule, same reasoning, as
    /// `AgentSessionView.stashComposerDraft`.
    private func stashComposerDraft() {
        guard let key = loadedDraftKey else { return }
        appState.setComposerDraft(draft, for: key)
    }

    private func reloadFromAppState() {
        syncComposerDraft()
        // Save the outgoing chat under ITS OWN identity before loading the
        // incoming one. Never key this write off `appState.openChat*` —
        // those already point at the incoming chat, and writing the old
        // live state under the new slug would overwrite the clicked
        // chat's file with the previous conversation.
        let sameChat = loadedChatSlug == appState.openChatSlug
            && loadedChatProject == appState.openChatProject
        if !sameChat, !liveMessages.isEmpty, let oldSlug = loadedChatSlug {
            // Skip when the file is gone — the chat was deleted or moved,
            // and persisting would resurrect it at the old address.
            let oldURL = SipaiPaths.chatStateFile(slug: oldSlug, project: loadedChatProject)
            if FileManager.default.fileExists(atPath: oldURL.path) {
                persistChat(slug: oldSlug, project: loadedChatProject)
            }
        }
        if let slug = appState.openChatSlug,
           let chat = chats.loadChat(slug: slug, project: appState.openChatProject) {
            liveMessages = chat.messages
            liveTitle = chat.title
            // Carried through the live state because every save
            // REBUILDS the StoredChat from these fields — dropping it
            // here would erase the stamp on the next unrelated save
            // (a rename, a project move, the switch-time write).
            liveLastUserMessageAt = chat.lastUserMessageAt
            if let m = chat.model { appState.activeModel = m }
        } else {
            liveMessages = []
            liveTitle = ""
            liveLastUserMessageAt = nil
        }
        // Transient PANE state belongs to the OUTGOING chat: without
        // this reset the incoming chat inherits the old chat's error
        // banner and its half-open find.
        //
        // The turn itself is no longer in this list. `sending` and
        // `turnStartedAt` are read off `ChatManager`, so they follow
        // the CHAT rather than the pane — an incoming chat with a live
        // turn correctly shows the spinner, and an incoming chat
        // without one correctly does not.
        if !sameChat {
            errorBanner = nil
            infoBanner = nil
            pendingAttachments = []
            // A find belongs to the conversation it was typed for. A
            // query left standing would count matches in a chat nobody
            // asked it about — and the arrival from a global-search
            // result re-opens it a runloop turn later anyway
            // (`consumePendingFind`), so this cannot fight that.
            find.close()
            // An open edit belongs to the message it was opened on. A
            // row id from another conversation can never match here, but
            // leaving it set would arm `canBranch`'s guard against a
            // chat that has no edit in progress.
            editingMessageId = nil
            editDraft = ""
            // An expanded window belongs to the chat it was expanded
            // in — carrying it over would make an unrelated chat open
            // with hundreds of eager rows.
            messageDisplayCap = 40
        }
        loadedChatSlug = appState.openChatSlug
        loadedChatProject = appState.openChatProject
        // Anything the chat's last turn left unsaid — a truncation, a
        // Stop, a failure that landed while this conversation was off
        // screen. Consumed here so it is shown once, on the chat it
        // belongs to, whichever view instance gets there first.
        applyTurnOutcome()
    }

    /// Re-read the open chat's messages after the manager delivered
    /// something into it. Messages only: the draft, the find, the
    /// expanded window and any open edit belong to the pane and have
    /// not changed.
    private func reloadMessagesFromDisk() {
        guard let slug = loadedChatSlug,
              let chat = chats.loadChat(slug: slug, project: loadedChatProject)
        else { return }
        liveMessages = chat.messages
        liveLastUserMessageAt = chat.lastUserMessageAt
    }

    /// Show what the chat's last turn left behind, then forget it — an
    /// outcome describes one turn, and must neither be shown twice nor
    /// follow the user into the next conversation.
    private func applyTurnOutcome() {
        guard let slug = loadedChatSlug, !slug.isEmpty,
              let outcome = chats.consumeTurnOutcome(slug: slug,
                                                     project: loadedChatProject)
        else { return }
        switch outcome {
        case .truncated:
            infoBanner = String(
                localized: "Response may be incomplete \u{2014} the model reached its output limit.",
                comment: "Truncation warning")
        case .interrupted:
            infoBanner = String(
                localized: "Interrupted — the reply was stopped before it arrived.",
                comment: "Chat banner after the user stops an in-flight reply")
        case .failed(let message):
            errorBanner = message
        }
    }

    /// Move the open chat to another project (nil = root "Chats") — the
    /// project chip's action. The loaded identity is re-keyed BEFORE
    /// publishing to appState, so the `.onChange` reload sees an
    /// already-consistent pair and the switch-time save can't write the
    /// outgoing content back to the old (now-moved) address. A chat that
    /// has never been persisted has no file to move — retargeting the
    /// pending identity is enough; the first persist files it there.
    private func changeProject(to target: String?) {
        guard target != loadedChatProject else { return }
        if let slug = loadedChatSlug, !slug.isEmpty {
            guard let moved = chats.moveChat(slug: slug,
                                             project: loadedChatProject,
                                             toProject: target) else { return }
            loadedChatSlug = moved.slug
            loadedChatProject = moved.project
            appState.openChatSlug = moved.slug
            appState.openChatProject = moved.project
        } else {
            loadedChatProject = target
            appState.openChatProject = target
        }
        // The chat's ADDRESS changed, not the conversation — re-key the
        // draft in step so the reload this triggers sees no switch and
        // leaves whatever is half-typed alone. The text has to be
        // CARRIED, not just re-keyed: `draft` doesn't change here, so
        // no `onChange` fires, so the store would otherwise keep the
        // text filed under an address that no longer exists.
        let previousKey = loadedDraftKey
        loadedDraftKey = AppState.chatDraftKey(slug: loadedChatSlug,
                                               project: loadedChatProject)
        stashComposerDraft()
        if let previousKey, previousKey != loadedDraftKey {
            appState.setComposerDraft("", for: previousKey)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // An image with no words is a legitimate message — "what is
        // this?" is implied by the act of attaching it.
        guard !text.isEmpty || !pendingAttachments.isEmpty, !sending else { return }

        guard let modelId = appState.activeModel ?? config.defaultModel else {
            if agents.hasInstalledAgent {
                errorBanner = String(
                    localized: "To chat with a model provider, add one in Settings → Models. For agent sessions, use the sidebar.",
                    comment: "Send-time error when no chat model is configured but an agent CLI is available.")
            } else {
                errorBanner = String(
                    localized: "No chat model configured. Add one in Settings → Models.",
                    comment: "Send-time error when no chat model and no agent CLI is available.")
            }
            return
        }

        var userMessage = ChatMessage(role: "user", content: outgoingContent(for: text))
        if !pendingAttachments.isEmpty {
            // The one trace an image leaves on disk, and the key the
            // CLI writes and reads for the same purpose.
            userMessage.files = pendingAttachments.map(\.name).joined(separator: ", ")
        }
        // Images and PDFs ride THIS request and are never stored, so
        // they have to be carried into the turn separately. The text
        // ones are already inside `userMessage.content`; sending them
        // again here would put every attached file in twice.
        let sentAttachments = pendingAttachments.filter { !$0.isText }
        pendingAttachments = []
        liveMessages.append(userMessage)
        // What the sidebar shows and orders by. Stamped HERE, at the
        // send, not by the save that follows: the reply's own save
        // lands minutes later and every unrelated save (rename,
        // project move, switching away) writes the file too.
        liveLastUserMessageAt = Date()
        // Remember which chat this turn belongs to — the user may click
        // another chat while the reply is in flight.
        let targetSlug = persistCurrentChat()
        let targetProject = loadedChatProject
        draft = ""
        // Drop the stashed copy too, or switching away and back would
        // resurrect the just-sent text into the composer.
        stashComposerDraft()
        errorBanner = nil
        infoBanner = nil
        // Whatever the PREVIOUS turn left unsaid is settled — this one
        // supersedes it, and an outcome that outlived its turn would
        // surface under the new reply.
        chats.clearTurnOutcome(slug: targetSlug, project: targetProject)

        let systemPrompt: String
        if let role = appState.activeRole {
            systemPrompt = role.prompt
        } else {
            let general = config.loadGeneralSystemPrompt()
            systemPrompt = general.isEmpty ? "You are a helpful assistant." : general
        }
        let snapshot = liveMessages
        let startedAt = Date()

        // NOTHING in here may write this view's `@State`, and nothing
        // may read it to decide where the reply goes. The centre-pane
        // router destroys this view the moment the user clicks a
        // session or a note, and a destroyed view's `@State` still
        // reads back the values it held when it died — so a
        // `loadedChatSlug == targetSlug` test passes for a view nobody
        // is looking at, and the reply is appended to a state box that
        // renders nowhere and then written over the live file. The turn
        // outlives the pane; its result must be addressed to the CHAT.
        let task = Task { @MainActor in
            // Every exit from here — reply, error, Stop — releases the
            // row and the sidebar's activity dot.
            defer { chats.endTurn(slug: targetSlug, project: targetProject) }
            do {
                let result = try await apiClient.sendChat(
                    messages: snapshot,
                    modelId: modelId,
                    systemPrompt: systemPrompt,
                    attachments: sentAttachments
                )
                let reply = ChatMessage(role: "assistant", content: result.text, model: modelId, time: result.time,
                                        tokens: result.usage.map { $0.input + $0.output })
                chats.appendAssistantReply(reply,
                                           slug: targetSlug,
                                           project: targetProject,
                                           outcome: result.truncated ? .truncated : nil)
            } catch {
                // User pressed Stop — not an error, but not silence
                // either: say the reply was interrupted, in the neutral
                // banner voice. Either way the verdict is stored
                // against the chat, so it is still there to be read if
                // the user was elsewhere when it landed.
                chats.noteTurnOutcome(error is CancellationError
                                        ? .interrupted
                                        : .failed(error.localizedDescription),
                                      slug: targetSlug, project: targetProject)
            }
        }
        // Registered AFTER the handle exists and BEFORE the task can
        // run: a task enqueued from the main actor cannot start until
        // this synchronous body yields, so the turn is never in flight
        // without the manager knowing, and `endTurn` can never race
        // ahead of the `beginTurn` it undoes.
        chats.beginTurn(slug: targetSlug, project: targetProject,
                        startedAt: startedAt, task: task)
    }

    // MARK: - Branching from an earlier message

    /// Whether this row offers the branch pencil. User messages only,
    /// and not while a reply is in flight — the branch inherits the
    /// conversation as it stands, and "as it stands" is not a settled
    /// question mid-turn.
    private func canBranch(from message: ChatMessage) -> Bool {
        message.role == "user" && !sending && editingMessageId == nil
    }

    private func beginMessageEdit(_ message: ChatMessage) {
        editDraft = message.content
        editingMessageId = message.id
    }

    private func cancelMessageEdit() {
        editingMessageId = nil
        editDraft = ""
    }

    /// Fork the conversation at `messageId`: everything ABOVE it becomes
    /// a new chat, the edited text is sent into that chat, and this one
    /// is left exactly as it was.
    ///
    /// The identity dance is the one `changeProject` documents and
    /// `persistChat` warns about, for the same reason: `loadedChatSlug`
    /// is what saves are keyed off, so it must name the BRANCH before
    /// `appState` does — otherwise the reload that the routing change
    /// triggers would write this chat's live content into the branch's
    /// file, which is exactly how two chats become clones of each other.
    private func createChatBranch(from messageId: UUID) {
        let text = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let index = liveMessages.firstIndex(where: { $0.id == messageId })
        else { return }

        // Whatever is on screen belongs to THIS chat — write it before
        // the identity moves.
        if !liveMessages.isEmpty {
            persistChat(slug: loadedChatSlug ?? "", project: loadedChatProject)
        }

        let prefix = Array(liveMessages[..<index])
        // A branch off the very first message has no shared history at
        // all, so it is simply a new chat — and must title itself from
        // the message being sent, not inherit a name for a conversation
        // it shares nothing with. `persistChat` derives a title from the
        // first user message whenever the title is empty.
        let branchTitle = prefix.isEmpty
            ? ""
            : String(localized: "\(liveTitle) (branch)",
                     comment: "Title of a chat branched from another; placeholder is the original title")
        let branch = chats.saveChat(StoredChat(
            slug: "",
            title: branchTitle,
            project: loadedChatProject,
            model: appState.activeModel,
            lastResponseId: nil,
            messages: prefix,
            lastUserMessageAt: Date()
        ))

        // Adopt the branch as the loaded identity FIRST (see above), and
        // carry the composer draft with it — the text isn't changing, so
        // no `onChange` will fire to re-file it.
        let previousDraftKey = loadedDraftKey
        loadedChatSlug = branch.slug
        loadedChatProject = branch.project
        liveMessages = prefix
        liveTitle = branch.title
        liveLastUserMessageAt = branch.lastUserMessageAt
        messageDisplayCap = 40
        loadedDraftKey = AppState.chatDraftKey(slug: branch.slug,
                                               project: branch.project)
        stashComposerDraft()
        if let previousDraftKey, previousDraftKey != loadedDraftKey {
            appState.setComposerDraft("", for: previousDraftKey)
        }

        cancelMessageEdit()
        appState.openChatSlug = branch.slug
        appState.openChatProject = branch.project

        // Straight down the ordinary send path, so attachments, usage
        // accounting, the turn clock and the in-flight identity capture
        // all behave exactly as they do for a typed message.
        draft = text
        send()
    }

    /// Stop button: cancel the in-flight request. URLSession surfaces
    /// that as URLError(.cancelled); `postJSON` normalizes it to
    /// CancellationError, and the turn answers with the "Interrupted"
    /// banner instead of an error.
    ///
    /// Asked of the manager, not of a handle held here — this view may
    /// have been created long after the send, which is exactly the case
    /// where a view-held handle is nil and Stop does nothing.
    private func stopSending() {
        guard let slug = loadedChatSlug, !slug.isEmpty else { return }
        chats.stopChatTurn(slug: slug, project: loadedChatProject)
    }

    /// Summarise the current chat into a note via the active model and persist
    /// it through `NotesManager`. The new note is auto-opened in the center
    /// column on success. `extraPrompt` (the note-prompt box) rides along in
    /// the generation request and is recorded in the note's metadata.
    private func generateNote(extraPrompt: String? = nil) {
        guard !noteGenerating else { return }
        let msgs = liveMessages
        if msgs.isEmpty {
            errorBanner = String(
                localized: "Nothing to summarise — chat is empty.",
                comment: "Error shown when the note button is clicked on an empty chat")
            return
        }
        guard let modelId = config.noteGeneratingModel
                ?? appState.activeModel ?? config.defaultModel else {
            errorBanner = String(
                localized: "No chat model configured. Add one in Settings → Models.",
                comment: "Error shown when generating a note without a configured model")
            return
        }

        noteGenerating = true
        errorBanner = nil
        infoBanner = String(
            localized: "📝 Generating note…",
            comment: "Banner shown while a note is being generated")

        var transcript = NotesManager.formatTranscript(
            msgs,
            userLabel: config.display.userLabel,
            aiLabel: config.display.aiLabel)
        let extra = extraPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let extra, !extra.isEmpty {
            transcript += "\n\nAdditional instructions from the user for this note: \(extra)"
        }
        let chatTitle = liveTitle.isEmpty ? "untitled" : liveTitle
        let snapshot = [ChatMessage(role: "user", content: transcript)]
        let client = apiClient

        Task { @MainActor in
            do {
                let result = try await client.sendChat(
                    messages: snapshot,
                    modelId: modelId,
                    systemPrompt: NotesManager.notePromptSystem
                )
                if let stored = notesManager.createNote(
                    content: result.text,
                    sourceTitle: chatTitle,
                    modelId: modelId,
                    extraInstructions: extra
                ) {
                    noteGenerating = false
                    infoBanner = String(
                        localized: "✓ Note saved: \(stored.title)",
                        comment: "Banner shown when a note is successfully created")
                    appState.openNoteId = stored.id
                } else {
                    noteGenerating = false
                    errorBanner = String(
                        localized: "Failed to write note to disk.",
                        comment: "Error shown when note persistence fails")
                }
            } catch {
                noteGenerating = false
                errorBanner = String(
                    localized: "Note generation failed: \(error.localizedDescription)",
                    comment: "Error banner shown when note generation throws")
            }
        }
    }

    @discardableResult
    private func persistCurrentChat() -> String {
        persistChat(slug: loadedChatSlug ?? "", project: loadedChatProject)
    }

    /// Write the live state to the given chat file. An empty slug means
    /// "brand-new chat": a slug is generated from the title, recorded as
    /// the loaded identity, and — when this view is the open chat —
    /// published to `appState` so the sidebar selects it.
    @discardableResult
    private func persistChat(slug: String, project: String?) -> String {
        // A chat with a turn in flight is the MANAGER's to write. This
        // view has nothing legitimate to add mid-turn — `send()` refuses
        // to overlap turns and `canBranch` holds the edit pencil — so
        // the only thing a write from here can carry is a conversation
        // that predates the reply, and this path runs on every switch,
        // every teardown and every rename. Left unguarded it silently
        // erases a reply that has already been delivered.
        //
        // The turn's own writes go through `ChatManager`, which re-reads
        // the file; a model or title change made mid-turn is picked up
        // by the next persist after it ends.
        if !slug.isEmpty, chats.isChatInFlight(slug: slug, project: project) {
            return slug
        }
        var title = liveTitle
        if title.isEmpty {
            let firstUser = liveMessages.first(where: { $0.role == "user" })?.content ?? "chat"
            let words = firstUser.split(separator: " ").prefix(5).joined(separator: " ")
            title = String(words)
            liveTitle = title
        }
        let chat = StoredChat(
            slug: slug,
            title: title,
            project: project,
            model: appState.activeModel,
            lastResponseId: nil,
            messages: liveMessages,
            lastUserMessageAt: liveLastUserMessageAt
        )
        let saved = chats.saveChat(chat)
        if slug.isEmpty {
            loadedChatSlug = saved.slug
            loadedChatProject = saved.project
            if appState.openChatSlug == nil {
                appState.openChatSlug = saved.slug
                appState.openChatProject = saved.project
            }
        }
        return saved.slug
    }
}

// MARK: - Unified Input Card

/// A single rounded-rect card containing the text field, + button,
/// notebook button, model selector, and send button.
/// Mimics the Claude desktop app's input box design.
struct UnifiedInputCard: View {
    @EnvironmentObject var config: ConfigManager

    @Binding var draft: String
    /// Read-only: the turn belongs to `ChatManager`, not to this card
    /// and not to the pane it sits in.
    var sending: Bool
    @Binding var noteGenerating: Bool
    /// True when the chat has at least one message — i.e. there's something
    /// to summarise. Used to dim the notebook button.
    var canGenerateNote: Bool
    /// Cmd+F state for this conversation, owned by `ChatView`. The
    /// button beside the note icon toggles it; the bar itself renders
    /// at the top of the pane.
    @ObservedObject var find: TranscriptFindState
    var onSend: () -> Void
    /// Cancels the in-flight send — wired to the stop icon that
    /// replaces the send button while `sending` is true.
    var onStop: () -> Void
    var onUpload: () -> Void
    /// Files staged for the next send, drawn as removable chips above
    /// the text field.
    var attachments: [ChatAttachment]
    var onRemoveAttachment: (UUID) -> Void
    /// Files dropped anywhere on this card. The host loads them — a
    /// drop and the + button must refuse the same things the same way.
    var onDropFiles: ([URL]) -> Void
    /// nil = direct note; non-nil = the user's extra instructions from
    /// the note-prompt box.
    var onGenerateNote: (String?) -> Void
    /// Moves the chat to the picked project (nil = root "Chats") — see
    /// `ChatView.changeProject(to:)`, which owns the identity re-keying.
    var onSelectProject: (String?) -> Void
    /// Fired after the find button flips `find.isOpen`, so the host can
    /// build the match list. The card cannot do it itself — the rows
    /// are the host's.
    var onToggleFind: () -> Void

    @State private var plusHovered: Bool = false
    @State private var noteHovered: Bool = false
    @State private var showingNoteOptions: Bool = false
    /// A file drag is over the card. Drawn as a border tint, so the
    /// drop has a target the user can see before they let go.
    @State private var dropTargeted: Bool = false

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// An attached file is a message on its own — the send arrow must
    /// appear for one even with an empty text field.
    private var hasSomethingToSend: Bool { hasText || !attachments.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if !attachments.isEmpty {
                AttachmentChipRow(attachments: attachments, onRemove: onRemoveAttachment)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }
            // Text field area — 2/3 of the original 32/140 pt frame; the
            // placeholder offsets track the scroll-view padding (4 pt) +
            // the NSTextView's vertical inset (2 pt, see MessageInput).
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("How can I help you today?")
                        .foregroundColor(SipDesign.textHint)
                        .font(.system(size: 14))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
                MultilineTextField(text: $draft,
                                   onSubmit: onSend,
                                   spellChecking: config.display.spellCheck,
                                   onDropFiles: onDropFiles,
                                   onDropTargeted: { dropTargeted = $0 })
                    .frame(minHeight: 21, maxHeight: 93)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }

            // Bottom toolbar row inside the card
            HStack(spacing: 8) {
                // + upload button (left)
                Button {
                    onUpload()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(plusHovered ? Color.gray.opacity(0.2) : Color.clear)
                        )
                        .onHover { hovering in
                            plusHovered = hovering
                        }
                }
                .buttonStyle(.plain)
                .help("Attach files")

                // Notebook button (generate a note from the current chat).
                // Conditionally emitted — a hidden control must leave no
                // gap in the row, so the HStack simply reflows.
                if config.display.showNoteChat {
                    Button {
                        if config.display.showNotePrompt {
                            showingNoteOptions = true
                        } else {
                            onGenerateNote(nil)
                        }
                    } label: {
                        ZStack {
                            if noteGenerating {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.75)
                            } else {
                                Image(systemName: "note.text")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(canGenerateNote ? AnyShapeStyle(.secondary)
                                                                     : AnyShapeStyle(SipDesign.textHint))
                            }
                        }
                        .frame(width: 22, height: 22)
                        .padding(2)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill((noteHovered && canGenerateNote && !noteGenerating)
                                      ? Color.gray.opacity(0.2)
                                      : Color.clear)
                        )
                        .onHover { hovering in
                            noteHovered = hovering
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canGenerateNote || noteGenerating)
                    .help(canGenerateNote
                          ? String(localized: "Generate a note from this conversation",
                                   comment: "Tooltip for the notebook button")
                          : String(localized: "Send at least one message to generate a note",
                                   comment: "Tooltip when the notebook button is disabled"))
                    .popover(isPresented: $showingNoteOptions, arrowEdge: .top) {
                        NoteOptionsPopover(isPresented: $showingNoteOptions,
                                           onGenerate: onGenerateNote)
                    }
                }

                // Find — beside the note button, in that button's own
                // idiom (same 22-pt glyph box, same grey rounded hover
                // fill). Unconditional: unlike the note button it has
                // no Settings → Display toggle, and an empty chat only
                // dims it rather than removing it, so the control never
                // moves under the pointer.
                ChatFindToggle(find: find, enabled: canGenerateNote)
                    .onChange(of: find.isOpen) { _, _ in onToggleFind() }

                // Project + role chips — each hides itself when its
                // Settings → Display toggle is off.
                ProjectSelector(onSelect: onSelectProject)
                RoleSelector()

                Spacer()

                // Model selector (right)
                ModelSelector()

                // Send button — visible only when there's text. Its
                // LAYOUT box is pinned to the row height below; the
                // 24-pt glyph just overdraws the box by a couple of
                // points. Without the pin, the glyph was the tallest
                // thing in the row, so the whole card grew the moment
                // the arrow appeared (and the .animation(value: hasText)
                // animated the growth) — typing must never resize the box.
                if hasSomethingToSend && !sending {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(SipDesign.blue)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("Send message")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                } else if sending {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(SipDesign.textHint)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                }
            }
            // Fixed: the tallest PERMANENT control (the 22+4 pt note
            // button). Controls that come and go must fit inside it.
            .frame(height: 26)
            .padding(.horizontal, 10)
            .padding(.bottom, 5)
            .padding(.top, 0)
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(SipDesign.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(dropTargeted ? SipDesign.blue : SipDesign.borderLight,
                                lineWidth: dropTargeted ? 2 : 1)
                )
        )
        // The WHOLE card is the drop target, text field included — a
        // file dragged at a composer is aimed at the message, not at a
        // particular few points of it.
        //
        // This handler covers the card AROUND the text field only. The
        // text view itself is the deepest view registered for file
        // drags, so it wins every drop aimed at the box the user is
        // actually looking at, and no ancestor drop target can take
        // that away from it. It therefore forwards those to
        // `onDropFiles` itself — see `DropForwardingTextView`. Both
        // routes end in the same host closure, so a drop stages what
        // the + button stages, wherever it lands.
        //
        // `public.file-url` read through the item provider, not
        // `dropDestination(for: URL.self)`: a Finder drag always
        // carries that type, and this is the door it is guaranteed to
        // arrive at.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            // The providers resolve on their own queues and in no
            // fixed order, so the collection is locked and the handoff
            // waits for all of them. Delivering per provider would
            // stage a multi-file drop as several separate batches, and
            // each batch's refusals would overwrite the last one's.
            let lock = NSLock()
            var collected: [URL] = []
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL {
                        lock.lock(); collected.append(url); lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                guard !collected.isEmpty else { return }
                onDropFiles(collected)
            }
            return true
        }
        .animation(.easeInOut(duration: 0.15), value: hasSomethingToSend)
        .animation(.easeInOut(duration: 0.15), value: sending)
        .animation(.easeInOut(duration: 0.15), value: noteGenerating)
        .animation(.easeInOut(duration: 0.12), value: dropTargeted)
    }
}

// MARK: - Note options popover

/// Content of the note button's popover when Settings → Display's
/// "Show note prompt" is on: generate directly, or open a small
/// instructions box first. A popover floats beside the button without
/// taking over the window, so the conversation stays readable while the
/// prompt is typed. Shared by the chat card and the agent composer.
struct NoteOptionsPopover: View {
    @Binding var isPresented: Bool
    /// Called with nil for a direct note, or the user's instructions.
    var onGenerate: (String?) -> Void

    private enum Stage { case options, prompt }
    @State private var stage: Stage = .options
    @State private var promptText: String = ""
    @FocusState private var promptFocused: Bool

    var body: some View {
        switch stage {
        case .options:
            VStack(alignment: .leading, spacing: 0) {
                SelectorPopoverRow(
                    title: String(localized: "Direct note",
                                  comment: "Note options row — generate the note immediately"),
                    selected: false
                ) {
                    isPresented = false
                    onGenerate(nil)
                }
                SelectorPopoverRow(
                    title: String(localized: "Add prompt…",
                                  comment: "Note options row — add instructions before generating"),
                    selected: false
                ) {
                    stage = .prompt
                }
            }
            .padding(.vertical, 4)
        case .prompt:
            VStack(alignment: .leading, spacing: 8) {
                Text("Note instructions",
                     comment: "Header of the note prompt box")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SipDesign.textSecondary)
                TextField(String(localized: "e.g. Focus on the decisions and open questions",
                                 comment: "Placeholder in the note prompt box"),
                          text: $promptText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(3...6)
                    .frame(width: 240)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(SipDesign.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(SipDesign.borderLight, lineWidth: 1)
                    )
                    .focused($promptFocused)
                    .onAppear { promptFocused = true }
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
                        onGenerate(trimmed.isEmpty ? nil : trimmed)
                    } label: {
                        Text("Generate", comment: "Confirm button of the note prompt box")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
    }
}
