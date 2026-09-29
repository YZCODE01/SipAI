// AgentComposer.swift
// Compact bottom composer for Claude Code sessions, modeled on the
// Claude desktop input bar: a short auto-growing input card with the
// send button inline, and a quiet control strip underneath —
//
//   left:  permission-mode chip · root folder · schedule · add files
//   right: model · effort · context-usage ring
//
// Used by AgentSessionView in both draft mode (everything editable,
// folder changes allowed until the first send) and existing-session
// mode (folder fixed; mode/model/effort still apply per send).

import SwiftUI
import AppKit

// MARK: - Composer

struct AgentComposer: View {
    @Binding var draft: String
    /// Which CLI the open session belongs to — an
    /// `AgentManager.registry` key. Drives the per-agent option
    /// catalogs (see `isCodex`).
    var agentKey: String = "claude_code"
    var sending: Bool
    /// External Claude Code process mid-turn on this session's JSONL.
    /// Send disabled, typing allowed.
    var externalBusy: Bool = false
    /// The external writer is a headless `-p` run this app can kill
    /// (an orphan from a relaunch). Enables the Stop button for
    /// external turns; false leaves it visible but disabled — the
    /// turn belongs to another terminal and stops there.
    var externalStoppable: Bool = false
    var placeholder: String
    /// Every session id the app lists; the text box draws each one it
    /// holds on a grey token (`SessionIdTokens`).
    var sessionIdTokens: Set<String> = []

    /// Mode / model / effort selections. Owned by AgentSessionView so
    /// they survive the draft→existing transition and persist to config.
    @Binding var options: AgentLaunchOptions
    /// What claude has said about fast mode on this session — its state,
    /// a refused call's sentence, and the speed the newest call ran at
    /// (`ClaudeFastModeReport`). Empty for the other agents. The switch
    /// is the request, this is the outcome, and the chip shows both.
    var fastModeReport = ClaudeFastModeReport()
    /// The account claude runs on, when known — on a plan fast mode is
    /// paid from usage credits, on an API key at a higher rate. nil off
    /// claude.
    var claudeAccount: PlanAccountKind? = nil

    /// Files staged for the next message — the chat page's mechanism,
    /// offered while the mode chip is on Chat only, where the `+` and a
    /// drop ATTACH instead of inserting paths (the agent has no tools to
    /// read a path with). Owned by `AgentSessionView`, like the draft
    /// text, and stashed with it. `onStageFiles` is the one door both
    /// routes go through, so a drop refuses what the picker refuses.
    var attachments: [ChatAttachment] = []
    var onStageFiles: (([URL]) -> Void)? = nil
    var onRemoveAttachment: ((UUID) -> Void)? = nil
    /// What the last attach refused or cut short — the chat page's
    /// banner, drawn above the card until dismissed or the next attach.
    var attachmentNotice: String? = nil
    var onDismissAttachmentNotice: (() -> Void)? = nil

    /// Working directory shown in the folder control.
    var folder: URL
    /// True only while the session is an unsent draft.
    var folderEditable: Bool
    var onFolderChange: (URL) -> Void

    /// Custom group a draft started from a group header's + belongs to,
    /// or nil. A task created here inherits it, the same way it already
    /// inherits `folder`: both describe the draft the user is standing
    /// in, and a task made from "Work"'s page landing under Ungrouped
    /// reads as a bug rather than a rule.
    var customGroup: String? = nil

    /// Whether the schedule control appears at all. True only for
    /// drafts — a session that already exists can't retroactively
    /// become a scheduled task, so offering the control there was a
    /// dead end.
    var scheduleAvailable: Bool = true

    /// Set when the open session is a run of a scheduled task: the
    /// task's name and when this run happened. Rendered as a quiet
    /// read-only tag next to the (equally read-only) folder control.
    var scheduledRunInfo: (name: String, time: Date)? = nil

    /// One-click "summarize this session into a note" — mirrors the
    /// notebook button on the chat input card. nil hides the control
    /// (nothing to summarize / no note pipeline in this context).
    /// nil closure hides the note button entirely; the String? argument
    /// is nil for a direct note or the note-prompt box's instructions.
    var onGenerateNote: ((String?) -> Void)? = nil
    /// Note-prompt chooser popover (Settings → Display "Show note prompt").
    @State private var showingNoteOptions: Bool = false
    var noteGenerating: Bool = false
    /// False dims the button: empty session or no chat model configured.
    var canGenerateNote: Bool = true

    /// Cmd+F over this transcript, owned by `AgentSessionView`. nil in
    /// contexts with no transcript to search (the scheduled-task
    /// panel's own composer), which hides the control.
    var find: TranscriptFindState? = nil
    /// False dims the find button — an empty transcript has nothing to
    /// search. Dimmed rather than removed, so the row's controls never
    /// move under the pointer.
    var canFind: Bool = true

    /// Tokens of context on the newest API call — the input side,
    /// cached prefix included. 0 = nothing recorded yet (chip hidden).
    var contextTokens: Int

    /// The window that number sits in, resolved by the session view
    /// from the model SELECTED in the chip beside this one
    /// (`ContextWindowResolver`). nil = this machine cannot state a
    /// window for that model, and the chip shows the count instead of a
    /// percentage rather than dividing by a guess. Display-only;
    /// nothing is ever launched with it.
    var contextWindowTokens: Int? = nil

    /// When the in-flight turn started, or nil if none is running.
    /// Non-nil makes the turn clock count up live.
    ///
    /// A Date rather than a pre-computed elapsed value on purpose: the
    /// chip owns its own ticking (see `TurnClockChip`), so a running
    /// turn costs one small view redraw per second instead of a
    /// re-render of this whole column — the same reason
    /// `AgentSessionView` does not observe the runner at all.
    var turnStartedAt: Date? = nil

    /// Seconds the latest finished turn took — the value the chip rests
    /// on. Either the same clock read at claude's `result` event for a
    /// turn this app ran, or the transcript's newest finished turn for
    /// one it didn't (see `AgentSessionView.displayTurnDuration`). With
    /// `turnStartedAt` nil too, the chip is hidden.
    var lastTurnDuration: Double? = nil

    var onSend: () -> Void
    var onStop: () -> Void
    /// Fired after a scheduled task is created, with its directory
    /// name, so the sidebar lists it at once and then rescans.
    var onScheduleCreated: (String) -> Void

    @EnvironmentObject var config: ConfigManager
    @ObservedObject private var caps = ClaudeCapabilities.shared
    @ObservedObject private var codexCaps = CodexCatalog.shared
    @ObservedObject private var kimiCaps = KimiCatalog.shared
    /// The installed versions the Chat only gate reads (`ChatOnlyGate`).
    @ObservedObject private var cliUpdates = AgentCLIUpdateMonitor.shared
    /// A file drag over the input card while Chat only is on, for the
    /// border tint the chat card draws for the same thing.
    @State private var dropTargeted = false
    /// The TIER scale: this composer is a sibling of the transcript,
    /// outside its content re-scope, so every size here is the
    /// design-size convention (`SipFont.scaled` / `.sipFont`).
    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.sipLineSpacingFactor) private var lineSpacingFactor

    @State private var inputHeight: CGFloat = 30
    @State private var showingModePopover = false
    @State private var showingModelPopover = false
    @State private var showingEffortPopover = false
    @State private var showingSchedulePopover = false
    /// Armed schedule settings. While `enabled`, the send button
    /// creates a scheduled task from the input box's text instead of
    /// running a live turn. Lives here (not in the popover) so the
    /// fields survive the popover's transient dismissal while the user
    /// types the prompt.
    @State private var scheduleDraft = ScheduleDraft()
    /// Validation / creation failure shown inside the popover.
    @State private var scheduleError: String? = nil
    @State private var creatingTask = false
    /// Transient "✓ Scheduled task created" notice above the card.
    @State private var scheduleNotice: String? = nil
    /// What a claude send with no `--model` runs as, read from claude's
    /// own configuration for this folder (`ClaudeModelCatalog
    /// .configuredDefaultModel`). Cached per appearance and per folder:
    /// the chip's resting title reads it on every body pass.
    @State private var configuredDefault: String? = nil

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the row is OFFERED for this composer's agent — the
    /// installed CLI names what the mode relies on. Below the gate the
    /// chip reads Default and a saved pick is ignored (the host applies
    /// the same verdict to the send).
    private var chatOnlyOffered: Bool { ChatOnlyGate.offered(agentKey: agentKey) }

    /// The chip's state, as it applies: Chat only only where it is
    /// offered. Every Chat only decision below reads THIS, not the raw
    /// option, so a saved pick on an older CLI changes nothing on screen.
    private var chatOnlyActive: Bool { options.chatOnly && chatOnlyOffered }

    /// A saved Chat only pick whose gate has not been read yet — the
    /// moments after launch, or after the CLI changed. The chip reads
    /// Default meanwhile, but the pick stands, and a send now would run
    /// an agent turn, with the agent's tools, on a message meant as a
    /// chat. So Send waits for the verdict, and says why.
    private var chatOnlyPending: Bool {
        options.chatOnly && !ChatOnlyGate.settled(agentKey: agentKey)
    }

    private var canSend: Bool {
        // An attached file is a message on its own, as on the chat page.
        (hasText || (chatOnlyActive && !attachments.isEmpty))
            && !sending && !externalBusy && !chatOnlyPending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = scheduleNotice {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .sipFont(11)
                        .foregroundStyle(.green)
                    Text(notice)
                        .sipFont(12)
                        .foregroundColor(SipDesign.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
            if scheduleDraft.enabled && scheduleAvailable {
                armedScheduleBanner
            }
            if let notice = attachmentNotice, chatOnlyActive {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .sipFont(11)
                        .foregroundStyle(.orange)
                    // A file name is user content: a String expression,
                    // never an interpolated literal.
                    Text(notice)
                        .sipFont(12)
                        .foregroundColor(SipDesign.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        onDismissAttachmentNotice?()
                    } label: {
                        Image(systemName: "xmark")
                            .sipFont(9, weight: .bold)
                            .foregroundColor(SipDesign.textHint)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Dismiss",
                                 comment: "Close button of the attachment notice above the agent composer"))
                }
                .transition(.opacity)
            }
            if chatOnlyPending {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "hourglass")
                        .sipFont(11)
                        .foregroundStyle(.orange)
                    // String expression: the agent label is user-set.
                    Text(String(localized: "Checking whether \(agentName) offers Chat only. Send waits for the answer — pick another mode to send now.",
                                comment: "Above the agent composer: a saved Chat only pick is held until the installed CLI's support for it has been read; placeholder is the agent's name"))
                        .sipFont(12)
                        .foregroundColor(SipDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
                // A read that failed is asked again once, here; a switch
                // away and back asks again after that.
                .onAppear {
                    caps.ensureLoaded()
                    codexCaps.ensureLoaded()
                    kimiCaps.ensureLoaded()
                }
            }
            if let hint = slashCommandHint {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "info.circle.fill")
                        .sipFont(11)
                        .foregroundStyle(.orange)
                    // String expression, never an interpolated literal:
                    // the agent label is user-set and that overload
                    // markdown-parses.
                    Text(hint)
                        .sipFont(12)
                        .foregroundColor(SipDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
            inputCard
            controlRow
        }
        .onAppear {
            caps.ensureLoaded()
            codexCaps.ensureLoaded()
            kimiCaps.ensureLoaded()
            refreshConfiguredDefault()
            if !isCodex && !isKimi { caps.refreshUsageCreditsBlock() }
            if isCodex { codexCaps.refreshSpeedSettings(forFolder: codexFolder) }
            // "Other models" is anchored on what each alias resolves
            // to NOW; every appearance re-derives it from the current
            // inputs (cheap, idempotent) rather than trusting a
            // section computed at some earlier harvest.
            if !isCodex && !isKimi {
                ClaudeModelCatalog.refreshOtherModels(config: config)
            }
        }
        .onChange(of: folder) { _, _ in
            refreshConfiguredDefault()
            if isCodex { codexCaps.refreshSpeedSettings(forFolder: codexFolder) }
        }
        .onChange(of: scheduleAvailable) { _, available in
            // Disarm when the composer moves somewhere scheduling
            // doesn't exist (draft → existing migration, or switching
            // to an existing session). The armed @State otherwise
            // survives the transition and hijacks Send with no visible
            // banner, button, or popover anchor to disarm it.
            if !available { scheduleDraft = ScheduleDraft() }
        }
        .animation(.easeInOut(duration: 0.15), value: hasText)
        .animation(.easeInOut(duration: 0.15), value: sending)
        .animation(.easeInOut(duration: 0.15), value: externalBusy)
        .animation(.easeInOut(duration: 0.2), value: scheduleNotice)
        .animation(.easeInOut(duration: 0.15), value: slashCommandHint)
    }

    // MARK: Slash-command hint

    /// Shown when this composer's CLI would treat a leading slash as
    /// ordinary prose — see `AgentSlashCommands.resolvesLocally`, which
    /// owns the rule and is measured per agent. Measured on codex:
    /// `/model` spent 89k input tokens and four web searches answering
    /// a question about models that nobody asked.
    ///
    /// It states a fact and does not block. A real prompt may open with
    /// a slash, and the sentence reads correctly for that case too —
    /// which is what makes a non-blocking hint the right shape here.
    private var slashCommandHint: String? {
        guard AgentSlashCommands.resolvesLocally(agentKey: agentKey) == false,
              AgentSlashCommands.leadingCommand(in: draft) != nil
        else { return nil }
        return String(
            localized: "\(agentName) has slash commands only in its own terminal. This will be sent as an ordinary message.",
            comment: "Composer hint when a codex/kimi draft opens with a slash command; placeholder is the agent label")
    }

    // MARK: Input card

    /// The box's type: 14 pt at Default, with the tier's line spacing
    /// between wrapped lines — the same rule the transcript's prose
    /// follows, so the box shares its rhythm.
    private var inputFontSize: CGFloat { SipFont.scaled(14, fontScale) }
    private var inputLineSpacing: CGFloat { inputFontSize * lineSpacingFactor }

    private var inputCard: some View {
        VStack(spacing: 0) {
            if chatOnlyActive, !attachments.isEmpty, let onRemoveAttachment {
                // The chat page's strip: each chip is the receipt for an
                // attach and carries the only control that removes it.
                AttachmentChipRow(attachments: attachments, onRemove: onRemoveAttachment,
                                  frameRatio: SipFont.ratio(fontScale))
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(placeholder)
                            .foregroundColor(SipDesign.textHint)
                            .sipFont(14)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                    GrowingTextField(
                        text: $draft,
                        measuredHeight: $inputHeight,
                        onSubmit: { if canSend { handleSendTapped() } },
                        spellChecking: config.display.spellCheck,
                        // Chat only: a dropped file ATTACHES, through the
                        // same door as the +; every other row keeps
                        // AppKit's own answer, the path typed in.
                        onDropFiles: chatOnlyActive ? onStageFiles : nil,
                        onDropTargeted: chatOnlyActive ? { dropTargeted = $0 } : nil,
                        fontSize: inputFontSize,
                        lineSpacing: inputLineSpacing,
                        sessionIdTokens: sessionIdTokens
                    )
                    // Rests at roughly two lines tall, grows with the text.
                    // The clamp scales with the type, or a larger tier
                    // shows fewer lines of a box that is meant to show ~3.
                    .frame(height: min(max(inputHeight, 60 * SipFont.ratio(fontScale)),
                                       140 * SipFont.ratio(fontScale)))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                }
                sendButton
                    .padding(.trailing, 8)
                    .padding(.bottom, 7)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(SipDesign.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(dropTargeted && chatOnlyActive ? SipDesign.blue : SipDesign.borderLight,
                                lineWidth: dropTargeted && chatOnlyActive ? 2 : 1)
                )
        )
        // A drop on the card OUTSIDE the text view (the strip, the
        // padding) — the text view forwards its own. Chat only alone:
        // everywhere else a dropped path is meant to be typed in, and
        // a card-level target would swallow the drop before the text
        // view saw it.
        .onDrop(of: [.fileURL], isTargeted: chatOnlyActive ? $dropTargeted : .constant(false)) { providers in
            guard chatOnlyActive, let onStageFiles else { return false }
            // Collected into ONE batch before staging — per-provider
            // delivery stages a multi-file drop as several batches, and
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
                onStageFiles(collected)
            }
            return true
        }
        .animation(.easeInOut(duration: 0.12), value: dropTargeted)
    }

    @ViewBuilder
    private var sendButton: some View {
        if sending || externalBusy {
            // ANY in-flight turn shows the Stop shape — a disabled
            // grey SEND arrow during an external turn would read as
            // a stop button ignoring every click. Stop is enabled
            // for our own turn and for an orphaned `-p` writer we
            // can kill; a turn running in another terminal keeps the
            // shape but disabled — it stops where it runs.
            let stoppable = sending || externalStoppable
            Button(action: onStop) {
                Image(systemName: "stop.circle.fill")
                    .sipFont(22)
                    .foregroundColor(SipDesign.textHint)
                    .opacity(stoppable ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!stoppable)
            .help(stoppable
                  ? String(localized: "Stop", comment: "Composer stop button tooltip")
                  : String(localized: "Running in another terminal — stop it from there",
                           comment: "Composer stop button tooltip when the turn belongs to another terminal"))
        } else {
            Button(action: handleSendTapped) {
                Image(systemName: scheduleArmed
                      ? "calendar.circle.fill" : "arrow.up.circle.fill")
                    .sipFont(22)
                    .foregroundColor(canSend && !creatingTask
                                     ? SipDesign.blue : SipDesign.textHint)
            }
            .buttonStyle(.plain)
            .disabled(!canSend || creatingTask)
            .help(scheduleArmed
                  ? String(localized: "Create the scheduled task from this prompt",
                           comment: "Composer send button tooltip while scheduling is armed")
                  : String(localized: "Send to \(agentName)",
                           comment: "Composer send button tooltip; placeholder is the agent label"))
        }
    }

    /// Armed AND applicable here. Every schedule-branch decision must
    /// use this, not `scheduleDraft.enabled` alone — the raw flag can
    /// linger from a context that had the schedule button.
    private var scheduleArmed: Bool {
        scheduleDraft.enabled && scheduleAvailable
    }

    /// While the schedule toggle is on, send means "create the
    /// scheduled task"; otherwise it is a normal live send.
    private func handleSendTapped() {
        if scheduleArmed {
            createScheduledTask()
        } else {
            onSend()
        }
    }

    // MARK: Control strip

    private var controlRow: some View {
        HStack(spacing: 8) {
            // Left group opens on the folder — the one control that
            // says WHERE this session runs. Mode sits with the other
            // per-turn settings on the right (model · effort · mode).
            HoverHighlight(hint: String(localized: "Folder",
                                        comment: "Instant hover hint for the root-folder control")) {
                folderControl
            }
            if let info = scheduledRunInfo {
                // Same instant hint every other control in this row uses.
                // `.help()` alone was invisible here: the system tooltip
                // is delayed and this row's neighbours all answer
                // immediately, so a hover that produced nothing for a
                // second read as "no hint". `highlight: false` — the tag
                // is read-only, and a fill would imply a button.
                HoverHighlight(
                    hint: String(
                        localized: "Latest run finished at \(Self.fullTimestamp(info.time))",
                        comment: "Instant hover hint on the scheduled-run time tag"),
                    highlight: false
                ) {
                    scheduledRunTag(info)
                }
            }
            if scheduleAvailable {
                HoverHighlight(hint: String(localized: "Schedule",
                                            comment: "Instant hover hint for the schedule button")) {
                    scheduleButton
                }
            }
            HoverHighlight(hint: chatOnlyActive
                           ? String(localized: "Attach file",
                                    comment: "Instant hover hint for the add-files button in Chat only")
                           : String(localized: "Add file",
                                    comment: "Instant hover hint for the add-files button")) {
                addFilesButton
            }
            if onGenerateNote != nil && config.display.showNoteAgent {
                HoverHighlight(hint: String(localized: "Note",
                                            comment: "Instant hover hint for the session-note button")) {
                    noteButton
                }
            }
            // Find — beside the note button, in this row's own idiom
            // (`HoverHighlight`: grey fill plus the instant hint every
            // neighbour answers with; a delayed `.help()` tooltip here
            // reads as no hint at all).
            if let find {
                HoverHighlight(hint: String(localized: "Find",
                                            comment: "Instant hover hint for the transcript find button")) {
                    findButton(find)
                }
            }
            Spacer(minLength: 12)
            HoverHighlight(hint: String(localized: "Model",
                                        comment: "Instant hover hint for the model picker")) {
                modelButton
            }
            if showsEffortChip {
                HoverHighlight(hint: String(localized: "Effort",
                                            comment: "Instant hover hint for the effort picker")) {
                    effortButton
                }
            }
            if isKimi && !chatOnlyOffered {
                // A statement, not a choice: `highlight: false` so it
                // doesn't read as a button, and the hint says WHY there
                // is nothing to pick. With Chat only offered the slot is
                // a two-row picker instead (Auto-approve · Chat only).
                HoverHighlight(
                    hint: KimiCapabilities.autoApproveHint(agentName: agentName),
                    highlight: false
                ) {
                    autoApproveChip
                }
            } else {
                HoverHighlight(hint: chatOnlyActive
                               ? chatOnlyHint
                               : String(localized: "Mode",
                                        comment: "Instant hover hint for the permission-mode chip")) {
                    modeChip
                }
            }
            // The turn clock, between the pickers and the token count:
            // counts up live while a turn runs, then freezes on that
            // turn's total. Hidden only when neither is true — a fresh
            // session with nothing run yet shows nothing here.
            //
            // The hint rides HoverHighlight like every other control in
            // this row, NOT `.help()`: the system tooltip is delayed,
            // and next to neighbours that answer instantly a hover that
            // produces nothing for a second reads as "no hint at all".
            // `highlight: false` — the chip is a readout, and a fill
            // would imply a button.
            if turnStartedAt != nil || (lastTurnDuration ?? 0) > 0 {
                HoverHighlight(hint: turnClockHint, highlight: false,
                               hintAlignment: .trailing) {
                    TurnClockChip(startedAt: turnStartedAt,
                                  finished: lastTurnDuration)
                }
            }
            // Hidden until the first usage arrives (mid-first-turn,
            // from the first assistant event) — "0%" says nothing.
            //
            // The hint rides HoverHighlight like the clock chip beside
            // it and every other control in this row, NOT `.help()`:
            // the system tooltip is delayed, and next to neighbours
            // that answer instantly a hover that produces nothing for a
            // second reads as "no hint at all" — which is exactly how
            // the previous counter's `.help()` read. `highlight:
            // false` — a readout, and a fill would imply a button.
            if config.display.showTokenAgent && contextTokens > 0 {
                // Codex sessions get a "?" after the window figure: the
                // number codex enforces is a third of what OpenAI
                // advertises for the same model, and the Help card the
                // glyph opens is the only place that says why. The other
                // agents' windows are the model's own — nothing to
                // explain, so no glyph.
                HoverHighlight(hint: ContextUsageChip.hoverText(
                                    contextTokens: contextTokens,
                                    windowTokens: contextWindowTokens),
                               highlight: false,
                               hintAlignment: .trailing,
                               hintAccessory: contextWindowHelpGlyph) {
                    ContextUsageChip(contextTokens: contextTokens,
                                     windowTokens: contextWindowTokens)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    /// The "?" in the context chip's hint — codex only, and only once
    /// a window is known (the hint then names the figure the glyph
    /// explains). nil leaves the hint exactly as every other agent's.
    private var contextWindowHelpGlyph: ((@escaping () -> Void) -> AnyView)? {
        guard isCodex, let window = contextWindowTokens, window > 0 else { return nil }
        let label = String(
            localized: "Why \(ContextUsageFormat.compact(window))? Opens Help",
            comment: "Accessibility label of the context chip's help glyph; placeholder is the window as a compact token count")
        return { collapse in
            AnyView(HintHelpGlyph(accessibilityLabel: label) {
                // The bubble is folded BEFORE the sheet opens: a view
                // under a sheet gets no hover-exit, so left alone the
                // hint would still be floating there when the sheet
                // closed.
                collapse()
                HelpTopic.codexContextWindow.open()
            })
        }
    }

    // MARK: Turn clock

    /// Counting form: "05s", "13m 02s", "2h 04m 09s". The seconds part
    /// is ALWAYS two digits, and so are the minutes once hours are on
    /// screen.
    ///
    /// Zero-padded because the chip is read while it counts.
    /// `monospacedDigit()` fixes the width of a digit; only padding
    /// fixes the NUMBER of them. Unpadded, the string loses a character
    /// every time the seconds roll past 59 ("4m 59s" → "5m 0s") and
    /// takes it back nine seconds later, so everything to the right of
    /// the chip shifts twice a minute for the whole of a long turn.
    ///
    /// Deliberately not `AgentRendering.formatTime`, which is shared
    /// with the chat spinner and the transcript's result row — neither
    /// wants padding, and both are written once rather than counted
    /// through.
    static func clockText(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        if total < 60 { return String(format: "%02ds", total) }
        if total < 3600 {
            return String(format: "%dm %02ds", total / 60, total % 60)
        }
        return String(format: "%dh %02dm %02ds",
                      total / 3600, (total % 3600) / 60, total % 60)
    }

    /// Resting form — the same shape, except that a sub-second turn
    /// keeps one decimal instead of reading as a flat "00s". Only ever
    /// shown frozen, so its width changing costs nothing.
    static func durationText(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "%.1fs", seconds) : clockText(seconds)
    }

    private var turnClockHint: String {
        if let started = turnStartedAt {
            return String(localized: "This turn has been running for \(Self.durationText(Date().timeIntervalSince(started)))",
                          comment: "Instant hover hint on the composer's turn clock while a turn is running")
        }
        return String(localized: "Latest agent response took \(Self.durationText(lastTurnDuration ?? 0))",
                      comment: "Instant hover hint on the composer's turn clock after a turn finishes")
    }

    // MARK: Mode chip

    /// True when this composer drives a codex session. The mode and
    /// effort catalogs are per-CLI: claude's permission modes are not
    /// valid codex sandbox values and vice versa, so offering one
    /// agent's list for the other builds a flag its CLI rejects.
    private var isCodex: Bool { agentKey == "codex" }

    /// True when this composer drives a Kimi Code session. Kimi takes
    /// the same reasoning one step further: its headless mode accepts
    /// NEITHER a permission mode nor an effort level — passing one is a
    /// startup error, not a no-op — so those two controls are replaced
    /// by a readout and hidden respectively rather than offering
    /// choices that cannot be sent. See `AgentLaunchOptions.kimiFlags`.
    private var isKimi: Bool { agentKey == "kimi" }

    /// The composer's agent under whatever name the user gave it in
    /// Settings. Every user-visible sentence names the agent through
    /// this — a hardcoded "Claude Code" would name the wrong agent on
    /// a codex session.
    private var agentName: String {
        let fallback = AgentManager.registry
            .first { $0.key == agentKey }?.name ?? "Claude Code"
        return config.agentLabel(for: agentKey, defaultName: fallback)
    }

    /// The chip's title: Chat only where it is in force, else the
    /// agent's mode, else Default (kimi: its auto-approve readout).
    private var selectedModeTitle: String {
        if chatOnlyActive { return Self.chatOnlyTitle }
        if isKimi { return KimiCapabilities.autoApproveTitle }
        if let name = options.permissionMode {
            return isCodex ? CodexCapabilities.title(for: name)
                           : AgentPermissionMode(name: name).title
        }
        return String(localized: "Default",
                      comment: "Mode chip label when no permission mode override is set")
    }

    /// The row's name — one key, used by the chip, the rows and the
    /// Help card alike.
    static var chatOnlyTitle: String {
        String(localized: "Chat only",
               comment: "Mode chip row: a turn with no file or command tools, only web lookups, drawing on the user's plan")
    }

    /// The Chat only row, offered first among the overrides — the same
    /// row on every agent, its subtitle naming the agent through the
    /// label.
    private var chatOnlyRow: ComposerOptionRow {
        ComposerOptionRow(
            value: ChatOnlyMode.rowValue,
            title: Self.chatOnlyTitle,
            subtitle: String(localized: "\(agentName) can look things up on the web but can't read or change files. Attach files with +.",
                             comment: "Hint under the Chat only mode row; placeholder is the agent label"))
    }

    private var modeRows: [ComposerOptionRow] {
        let defaultRow = ComposerOptionRow(
            value: nil,
            title: String(localized: "Default",
                          comment: "Permission-mode menu row — no override"),
            subtitle: isCodex
                ? String(localized: "\(agentName) decides, using your codex config",
                         comment: "Hint for the no-override sandbox row on a codex session; placeholder is the agent label")
                : String(localized: "\(agentName) decides; approvals appear here",
                         comment: "Hint for the no-override permission mode row; placeholder is the agent label"))
        let overrides = chatOnlyOffered ? [chatOnlyRow] : []
        if isKimi {
            // Kimi's own mode cannot be chosen (`--prompt` refuses one),
            // so its list is the auto-approve readout — now a row — and
            // Chat only.
            let autoRow = ComposerOptionRow(
                value: nil,
                title: KimiCapabilities.autoApproveTitle,
                subtitle: String(localized: "\(agentName) approves its own tool calls on a headless run",
                                 comment: "Hint under the kimi Auto-approve mode row; placeholder is the agent label"))
            return [autoRow] + overrides
        }
        if isCodex {
            return [defaultRow] + overrides + CodexCapabilities.modePresets.map {
                ComposerOptionRow(value: $0.value,
                                  title: CodexCapabilities.title(for: $0.value),
                                  subtitle: $0.hint)
            }
        }
        return [defaultRow] + overrides + caps.permissionModes.map {
            ComposerOptionRow(value: $0.name, title: $0.title, subtitle: $0.hint)
        }
    }

    /// No resting background — flat like the other controls, with the
    /// grey coming only from the shared hover treatment. A non-default
    /// mode is signalled by the blue text alone; Chat only reads blue
    /// like any override.
    private var modeChip: some View {
        Button {
            showingModePopover = true
        } label: {
            Text(selectedModeTitle)
                .sipFont(11, weight: .semibold)
                .foregroundColor(options.permissionMode == nil && !chatOnlyActive
                                 ? SipDesign.textSecondary : SipDesign.blue)
                .padding(.vertical, 3)
                .padding(.horizontal, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingModePopover, arrowEdge: .bottom) {
            ComposerOptionList(rows: modeRows,
                               selected: chatOnlyActive
                                   ? ChatOnlyMode.rowValue : options.permissionMode) { value in
                // One writer for both fields — see `ChatOnlyMode.select`.
                ChatOnlyMode.select(value, into: &options)
                showingModePopover = false
            }
        }
    }

    /// The mode chip's Kimi stand-in while Chat only is not offered:
    /// the same slot, same type size, but a readout. Secondary colour
    /// like an unset chip — nothing has been overridden here, because
    /// nothing can be.
    private var autoApproveChip: some View {
        Text(KimiCapabilities.autoApproveTitle)
            .sipFont(11, weight: .semibold)
            .foregroundColor(SipDesign.textSecondary)
            .padding(.vertical, 3)
            .padding(.horizontal, 5)
    }

    /// The chip's hover while Chat only is in force: which pool the
    /// turn draws on, per agent, and on a kimi draft the one thing that
    /// differs about its first turn. Through the label, every sentence.
    private var chatOnlyHint: String {
        var hint: String
        // A tool signed in with an API key is billed per token for Chat
        // only too; naming a plan there would misstate who pays.
        if UsageMonitor.shared.accounts[agentKey] == .apiKey {
            hint = String(localized: "Billed to the API key \(agentName) is signed in with",
                          comment: "Hover on the mode chip while Chat only is on, for an agent signed in with an API key; placeholder is the agent label")
        } else if isCodex {
            hint = String(localized: "Uses your \(agentName) limits",
                          comment: "Hover on the mode chip while Chat only is on, codex; placeholder is the agent label")
        } else if isKimi {
            hint = String(localized: "Uses your \(agentName) membership",
                          comment: "Hover on the mode chip while Chat only is on, kimi; placeholder is the agent label")
        } else {
            hint = String(localized: "Uses your \(agentName) plan",
                          comment: "Hover on the mode chip while Chat only is on, claude; placeholder is the agent label")
        }
        if isKimi && folderEditable {
            hint += " " + String(localized: "The first message of a new session arrives all at once; later ones stream.",
                                 comment: "Hover on the mode chip while Chat only is on, appended on a kimi draft")
        }
        return hint
    }

    // MARK: Folder control

    private var folderDisplayName: String {
        var name = folder.lastPathComponent
        if name.isEmpty { name = folder.path }
        // String-level middle truncation: a layout-level maxWidth frame
        // would reserve its full width even for short names, leaving a
        // gap in the control strip.
        if name.count > 24 {
            name = "\(name.prefix(11))…\(name.suffix(11))"
        }
        return name
    }

    @ViewBuilder
    private var folderControl: some View {
        if folderEditable {
            Menu {
                Section((folder.path as NSString).abbreviatingWithTildeInPath) {
                    Button {
                        pickFolder()
                    } label: {
                        Text("Choose Folder…",
                             comment: "Folder menu item — open the directory picker")
                    }
                    if let last = config.agentLastCwd(for: agentKey),
                       last != folder.path {
                        Button {
                            onFolderChange(URL(fileURLWithPath: last, isDirectory: true))
                        } label: {
                            // String(localized:) then verbatim Text —
                            // an _underscored_ folder name must not be
                            // markdown-italicized.
                            Text(String(localized: "Use Last: \((last as NSString).abbreviatingWithTildeInPath)",
                                        comment: "Folder menu item — reuse the previously used folder"))
                        }
                    }
                }
            } label: {
                controlLabel(icon: "folder", text: folderDisplayName)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            controlLabel(icon: "folder", text: folderDisplayName)
        }
    }

    /// Read-only marker for a scheduled-task run: when this session last
    /// finished a turn, sitting right beside the fixed folder. Not a
    /// button — the run already happened; there is nothing to configure.
    ///
    /// The time is the session transcript's last write, so it tracks
    /// continued conversation too: sending into a scheduled run's
    /// session moves it to that turn's finish. (`AgentManager` rescans
    /// on turn end so the value can't sit on the previous turn.)
    private func scheduledRunTag(_ info: (name: String, time: Date)) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "timer")
                .sipFont(11, weight: .medium)
                .foregroundColor(SipDesign.textSecondary)
            Text(info.time.formatted(
                .dateTime.month(.abbreviated).day().hour().minute()))
                .sipFont(11)
                .foregroundColor(SipDesign.textSecondary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        // Without a shape there is nothing to hover: this row is an icon
        // and a label over a transparent background, and SwiftUI hit-tests
        // only drawn content — so the tooltip could fire on the glyphs
        // themselves at best, and not at all in the gaps and padding
        // around them. `.help` needs a hit-testable area, not just a frame.
        .contentShape(Rectangle())
        // The visible hint comes from the enclosing HoverHighlight, so
        // no `.help()` here — two tooltips for one tag is noise. VoiceOver
        // still gets the full sentence.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            localized: "Latest run of “\(info.name)” finished at \(Self.fullTimestamp(info.time))",
            comment: "Accessibility label on the run-time tag shown for scheduled-task sessions"))
    }

    /// Long form for the tooltip — the chip itself is abbreviated, so
    /// hovering should answer the year/seconds question it can't.
    private static func fullTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose",
                              comment: "Folder picker confirm button")
        panel.message = String(localized: "Select the project directory for this \(agentName) session",
                               comment: "Folder picker explanatory text; placeholder is the agent label")
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onFolderChange(url)
    }

    // MARK: Schedule

    /// The mode a scheduled (unattended) run will use: the chip's
    /// selection, or bypassPermissions when the chip is on Default —
    /// claude's interactive default would stall a cron run on its
    /// first approval.
    private var effectiveScheduleMode: String {
        // Chat only never reaches a task: it is not a permission mode,
        // and `options.permissionMode` is nil while it is on, so a task
        // scheduled from a Chat only composer gets the agent's
        // unattended default below — an agent task, with tools.
        // Kimi writes NO mode into the task file. There is no unattended
        // default to pick because there is no attended one either — its
        // headless runs already approve every tool call, and any value
        // written here would be a flag its CLI refuses to start with.
        // An empty string is dropped by `ScheduledTaskDefinition.write`.
        if isKimi { return "" }
        return options.permissionMode
            ?? (isCodex ? CodexCapabilities.unattendedDefaultMode
                        : "bypassPermissions")
    }

    /// Chip label for the mode an unattended run would use.
    private var effectiveScheduleModeTitle: String {
        if isKimi { return KimiCapabilities.autoApproveTitle }
        return isCodex ? CodexCapabilities.title(for: effectiveScheduleMode)
                       : AgentPermissionMode(name: effectiveScheduleMode).title
    }

    private var scheduleButton: some View {
        Button {
            showingSchedulePopover = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar.badge.clock")
                    .sipFont(12, weight: .medium)
                    .foregroundColor(scheduleDraft.enabled
                                     ? SipDesign.blue : SipDesign.textSecondary)
                if scheduleDraft.enabled {
                    Text(scheduleDraft.summary)
                        .sipFont(11)
                        .foregroundColor(SipDesign.blue)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingSchedulePopover, arrowEdge: .bottom) {
            SchedulePopover(
                schedule: $scheduleDraft,
                errorText: $scheduleError,
                // FULL path, not `folderDisplayName`. The chip shows only
                // the last component, and this caption is the last thing
                // read before send — two sibling folders can differ by
                // one grey word, and picking the wrong one silently
                // sends every unattended run to the wrong folder.
                folderPath: (folder.path as NSString).abbreviatingWithTildeInPath,
                modeTitle: effectiveScheduleModeTitle
            )
        }
    }

    /// Shown above the input card while the toggle is armed, so it is
    /// obvious the next send schedules instead of running.
    private var armedScheduleBanner: some View {
        Button {
            showingSchedulePopover = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar.badge.clock")
                    .sipFont(11)
                    .foregroundColor(SipDesign.blue)
                // The FOLDER is named here, not just in the popover. This
                // banner is the last thing read before send, and the
                // folder is the one setting that silently sends every
                // future unattended run somewhere the user did not mean
                // — it is worth the second line.
                Text(hasText
                     ? String(localized: "Send creates scheduled task “\(scheduleDraft.displayName)” in \(scheduleFolderLabel) — \(scheduleDraft.summary)",
                              comment: "Banner above the input while scheduling is armed and a prompt is typed")
                     : String(localized: "Scheduling armed — type the task prompt below, then send",
                              comment: "Banner above the input while scheduling is armed and the input is empty"))
                    .sipFont(12)
                    .foregroundColor(SipDesign.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(scheduleFolderLabel)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Open schedule options",
                     comment: "Tooltip for the armed-schedule banner"))
        .transition(.opacity)
    }

    /// Tilde path of the folder the task will run in — the value that
    /// actually goes into the task's `cwd:`, so the banner and the file
    /// can never disagree.
    private var scheduleFolderLabel: String {
        (folder.path as NSString).abbreviatingWithTildeInPath
    }

    /// Send-path for an armed schedule: validate the fields, write the
    /// task (SKILL.md + crontab) off-main, then reset the toggle and
    /// clear the input like a normal send.
    private func createScheduledTask() {
        guard !creatingTask else { return }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        if ScheduledTaskCreator.slugify(scheduleDraft.name).isEmpty {
            scheduleError = String(localized: "Give the task a name.",
                                   comment: "Schedule validation: missing name")
            showingSchedulePopover = true
            return
        }
        // A bad cron, or a one-time moment the clock has passed while
        // the popover sat open — the same words the task card shows.
        if let problem = scheduleDraft.timing.problem() {
            scheduleError = problem
            showingSchedulePopover = true
            return
        }
        guard let schedule = scheduleDraft.expression, !schedule.isEmpty else { return }
        let request = ScheduledTaskCreator.Request(
            rawName: scheduleDraft.name,
            description: scheduleDraft.taskDescription,
            schedule: schedule,
            prompt: prompt,
            cwd: folder,
            mode: effectiveScheduleMode,
            model: options.model,
            effort: options.effort,
            // The speed rides with the model it belongs to: claude's
            // switch only where the model takes it, codex's as its switch
            // shows it (`codexTaskSpeedPick`).
            fastMode: !isCodex && !isKimi && options.fastMode
                && fastModeSupported(forModel: options.model),
            serviceTier: isCodex ? codexTaskSpeedPick : nil,
            agent: agentKey
        )
        creatingTask = true
        scheduleError = nil
        Task { @MainActor in
            let outcome: Result<ScheduledTaskCreator.Success, Error> = await Task
                .detached(priority: .userInitiated) {
                    Result { try ScheduledTaskCreator.create(request) }
                }.value
            creatingTask = false
            switch outcome {
            case .success(let success):
                // `success.name` is the slugged DIRECTORY name, which
                // is what the scanner reports as the task's name and
                // what the sidebar files it under — so this key matches
                // the row before that row exists. A group deleted while
                // the popover was open fails the membership test and
                // the task is simply unfiled, rather than config
                // keeping a pointer to a group that is gone.
                if let group = customGroup,
                   config.agentCustomGroups(for: agentKey).contains(group) {
                    config.setAgentSessionGroup(
                        group,
                        for: AgentListItem.groupItemKey(
                            forScheduledTaskName: success.name))
                }
                draft = ""
                scheduleDraft = ScheduleDraft()
                showingSchedulePopover = false
                onScheduleCreated(success.name)
                let created = success.name
                scheduleNotice = String(
                    localized: "Scheduled task “\(created)” created — \(scheduleDraftSummaryAfterCreate(schedule))",
                    comment: "Transient notice after creating a scheduled task")
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    scheduleNotice = nil
                }
            case .failure(let error):
                scheduleError = error.localizedDescription
                showingSchedulePopover = true
            }
        }
    }

    /// Human summary for the success notice, computed from the schedule
    /// we just submitted (the draft has already been reset by then).
    private func scheduleDraftSummaryAfterCreate(_ schedule: String) -> String {
        ScheduleDraft.describe(schedule: schedule)
    }

    // MARK: Add files

    private var addFilesButton: some View {
        Button {
            addFiles()
        } label: {
            controlLabel(icon: "plus", text: nil)
        }
        .buttonStyle(.plain)
    }

    // MARK: Session note

    private var noteButton: some View {
        Button {
            if config.display.showNotePrompt {
                showingNoteOptions = true
            } else {
                onGenerateNote?(nil)
            }
        } label: {
            if noteGenerating {
                // The same box the icon occupies, scaled with it, or the
                // row shifts by a few points while a note generates.
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 22 * SipFont.ratio(fontScale),
                           height: 18 * SipFont.ratio(fontScale))
            } else {
                controlLabel(icon: "note.text", text: nil)
                    .opacity(canGenerateNote ? 1 : 0.4)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canGenerateNote || noteGenerating)
        .help(canGenerateNote
              ? String(localized: "Generate a note from this session",
                       comment: "Tooltip for the session-note button")
              : String(localized: "Needs at least one turn and a chat model (Settings → Chat models)",
                       comment: "Tooltip for the session-note button when disabled"))
        .popover(isPresented: $showingNoteOptions, arrowEdge: .top) {
            NoteOptionsPopover(isPresented: $showingNoteOptions,
                               onGenerate: { onGenerateNote?($0) })
        }
    }

    // MARK: Find

    private func findButton(_ find: TranscriptFindState) -> some View {
        Button {
            if find.isOpen { find.close() } else { find.open() }
        } label: {
            controlLabel(icon: "magnifyingglass", text: nil)
                .opacity(canFind ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!canFind)
        .help(canFind
              ? String(localized: "Find in this session",
                       comment: "Tooltip for the transcript find button")
              : String(localized: "Nothing to search in this session yet",
                       comment: "Tooltip for the transcript find button when the transcript is empty"))
    }

    /// The agent reads files itself, so attaching = referencing the
    /// paths in the prompt text — except in Chat only, where it has no
    /// tools to read a path with and the file travels WITH the message
    /// instead, through the chat page's mechanism.
    private func addFiles() {
        if chatOnlyActive, let onStageFiles {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.prompt = String(localized: "Attach",
                                  comment: "Confirm button of the chat attachment picker")
            panel.message = String(localized: "Attached files are sent with your message",
                                   comment: "File picker explanatory text for the agent composer in Chat only")
            panel.directoryURL = folder
            guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
            onStageFiles(panel.urls)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add",
                              comment: "File picker confirm button for the composer")
        panel.message = String(localized: "Selected paths are inserted into your message for \(agentName) to read",
                               comment: "File picker explanatory text for the composer; placeholder is the agent label")
        panel.directoryURL = folder
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let quoted = panel.urls.map { url -> String in
            let p = url.path
            return p.contains(" ") ? "'\(p)'" : p
        }
        var text = draft
        if !text.isEmpty && !text.hasSuffix(" ") && !text.hasSuffix("\n") {
            text += " "
        }
        draft = text + quoted.joined(separator: " ")
    }

    // MARK: Model / effort pickers

    private var modelRows: [ComposerOptionRow] {
        if isKimi {
            // Kimi slugs are literal, like codex's — no alias layer to
            // resolve and no version to derive, so they show as
            // recorded. The list can legitimately be EMPTY (nothing
            // configured, nothing run yet): "Default" alone is the
            // honest offer, where a hardcoded fallback list would name
            // models `--model` may reject.
            return [ComposerOptionRow(
                value: nil,
                title: String(localized: "Default",
                              comment: "Model menu row — kimi's default model"),
                // Kimi's own `display_name` for whatever `default_model`
                // points at, the same way the codex row names its
                // default rather than printing a raw slug.
                subtitle: kimiCaps.defaultModel.map(kimiCaps.displayName(forModel:)))]
            + kimiCaps.models.map {
                ComposerOptionRow(value: $0.slug, title: $0.displayName,
                                  subtitle: nil)
            }
        }
        if isCodex {
            // Codex model ids are literal (`gpt-5.6-sol`) — there is no
            // alias layer to resolve and no version to derive, so they
            // are shown as recorded. Running them through
            // `ClaudeModelDisplay` would rename them; offering claude's
            // ALIASES here would put `-m opus` on a codex command line.
            return [ComposerOptionRow(
                value: nil,
                title: String(localized: "Default",
                              comment: "Model menu row — codex's default model"),
                // What a send with no explicit pick actually runs as,
                // in this folder, as codex's own config resolves it —
                // the codex counterpart of claude's configured-default
                // subtitle, and named the same way its own row would be.
                subtitle: codexCaps.defaultModel(forFolder: codexFolder).map { slug in
                    codexCaps.models.first { $0.slug == slug }?
                        .displayName ?? slug
                })]
            + codexCaps.models.map {
                ComposerOptionRow(value: $0.slug, title: $0.displayName,
                                  subtitle: nil)
            }
        }
        var rows = [ComposerOptionRow(
            value: nil,
            title: String(localized: "Default",
                          comment: "Model menu row — claude's default model"),
            // What a send with no --model runs as: claude's own
            // configured default first, else what such a send was last
            // observed to resolve to ("Fable 5").
            subtitle: claudeDefaultName)]
        rows += caps.modelAliases.map { alias in
            ComposerOptionRow(value: alias,
                              title: rememberedName(forAlias: alias),
                              subtitle: nil)
        }
        // "Other models": per family, the previous version this Mac
        // has run and the installed claude still names — offered under
        // its FULL id, which `--model` takes verbatim. Ordered by the
        // alias rows above so the section reads in the same sequence.
        // Grouped by the family the alias NAMES — the casing table's
        // word, else the installed catalog's (`family(ofAlias:)`), the
        // same rule that admitted the row. Grouped on the table alone,
        // a family only the binary names would have a row and no place
        // to draw it. One row per id: a family with two aliases lists
        // its previous version once.
        let catalog = ClaudeModelCatalog.installedCatalog()
        var listed: Set<String> = []
        let others = caps.modelAliases.flatMap { alias -> [ClaudeOtherModel] in
            guard let family = ClaudeModelCatalog.family(ofAlias: alias, catalog: catalog)
            else { return [] }
            return caps.otherModels.filter {
                $0.family == family && listed.insert($0.fullId).inserted
            }
        }
        if !others.isEmpty {
            rows.append(.header(String(localized: "Other models",
                                       comment: "Model menu section header: previous model versions the CLI still offers")))
            rows += others.map {
                ComposerOptionRow(value: $0.fullId,
                                  title: $0.displayName,
                                  subtitle: nil)
            }
        }
        return rows
    }

    /// The Default row's subtitle and the chip's resting title for
    /// claude: the configured default, read the way the codex and kimi
    /// rows read theirs, else what a Default send resolves to — the
    /// family a Default send was last observed to run, at the version
    /// the installed binary resolves that family to now.
    private var claudeDefaultName: String? {
        if let configured = configuredDefault, !configured.isEmpty {
            return rememberedName(forAlias: configured)
        }
        return config.resolvedModelId(forAlias: "")
            .map { ClaudeModelCatalog.displayName(forId: $0) }
    }

    private func refreshConfiguredDefault() {
        guard !isCodex, !isKimi else { return }
        let found = ClaudeModelCatalog.configuredDefaultModel(cwd: folder)
        if found != configuredDefault { configuredDefault = found }
    }

    // MARK: Fast mode

    /// Whether the model in force can take a faster speed.
    ///
    /// Claude: the model's own `fast_mode` capability in the installed
    /// binary's catalog (`ClaudeCapabilities.fastModeSupported`), which
    /// does not mark every Opus — and never through a cloud provider
    /// (`claudeCloudProvider`). A model nothing resolves is allowed,
    /// and claude then reports on it itself.
    /// Codex: the model advertises a service tier and codex's
    /// `fast_mode` feature is on. Kimi: never.
    private func fastModeSupported(forModel value: String?) -> Bool {
        if isKimi { return false }
        if isCodex { return codexCaps.offersSpeed(forModel: value, folder: codexFolder) }
        if claudeCloudProvider != nil { return false }
        let id = config.resolvedClaudeModelId(picked: value,
                                              configuredDefault: configuredDefault)
        return caps.fastModeSupported(forModelId: id) ?? true
    }

    /// The cloud provider the child's environment switches claude onto
    /// (Bedrock, Vertex, Foundry), if any. Claude offers fast mode on
    /// Anthropic's own API alone, so any of them rules it out for every
    /// model. Cached reads of the environment and claude's settings.
    private var claudeCloudProvider: String? {
        ClaudeModelCatalog.childEnvironmentFacts().provider
    }

    private var fastModeTitle: String { ClaudeFastModeWords.title }

    /// Claude's cached reason usage credits are unavailable — only
    /// meaningful on a Claude plan, where fast mode is paid from them.
    private var claudeCreditsBlock: String? {
        guard claudeAccount?.isPlan == true else { return nil }
        return caps.usageCreditsBlock
    }

    /// What the switch's calls actually get — `ClaudeFastMode.verdict`
    /// over what claude reported and what it has cached.
    private var claudeFastVerdict: ClaudeFastMode.Verdict {
        ClaudeFastMode.verdict(
            requested: options.fastMode && fastModeSupported(forModel: options.model),
            report: fastModeReport, creditsBlock: claudeCreditsBlock)
    }

    /// The folder codex resolves this composer's config in — its speed
    /// and its default model (`CodexCatalog.speedSettings(forFolder:)`).
    private var codexFolder: String { folder.path }

    /// Codex's speed for this composer's model: the tier a send runs at
    /// (nil = standard), under codex's own interactive rule.
    private var codexEffectiveTier: String? {
        codexCaps.effectiveServiceTier(for: options, folder: codexFolder)
    }

    /// The tier codex's Fast mode switch turns on for this model — nil
    /// when the model advertises none, or codex's `fast_mode` feature is
    /// off (codex then drops every tier, even one on the command line).
    private var codexFastTier: CodexServiceTier? {
        guard codexCaps.speedSettings(forFolder: codexFolder).featureEnabled else { return nil }
        return codexCaps.fastTier(forModel: options.model, folder: codexFolder)
    }

    /// Whether codex's Fast mode switch reads on: the model advertises a
    /// tier the switch can name, and the send runs at a faster one. The
    /// chip's bolt, its hover and a task scheduled from here read this
    /// same answer, so a configured tier on a model codex's catalog does
    /// not list — one the switch cannot offer, and one codex judges by
    /// itself — lights nothing anywhere.
    private var codexFastOn: Bool {
        codexFastTier != nil && CodexSpeed.isFaster(codexEffectiveTier)
    }

    /// A faster tier in codex's own words for this model ("2x speed,
    /// increased usage"), its name when it carries none, the id when the
    /// model's catalog does not list it.
    private func codexTierDescription(_ tier: String) -> String {
        guard let known = codexCaps.serviceTier(id: tier, forModel: options.model,
                                                folder: codexFolder) else { return tier }
        return known.description.isEmpty ? known.name : known.description
    }

    /// What the chip's hover says about speed: for codex, the faster
    /// tier the next send runs at; for claude, what its calls actually
    /// get. Nothing for kimi, or while the switch is off.
    private var fastModeHint: String? {
        if isKimi { return nil }
        if isCodex {
            guard codexFastOn, let tier = codexEffectiveTier else { return nil }
            return String(localized: "Fast mode is on · \(codexTierDescription(tier))",
                          comment: "Model chip hover: codex's fast mode is on for the next turn; the placeholder is codex's own description of the tier (“2x speed, increased usage”)")
        }
        switch claudeFastVerdict {
        case .off:
            return nil
        case .requested:
            return String(localized: "Fast mode requested",
                          comment: "Model chip hover: the switch is on and the agent has not yet reported a state")
        case .running:
            return String(localized: "Fast mode is on · the last reply ran fast",
                          comment: "Model chip hover: the newest API call ran in fast mode")
        case .notServing(let why):
            return String(localized: "Fast mode requested, but not running · \(ClaudeFastModeWords.notServing(why))",
                          comment: "Model chip hover: fast mode is switched on, but the calls run at standard speed; the placeholder says why")
        }
    }

    /// The chip's glyph: a bolt while a faster speed is what runs, a
    /// struck-through bolt while claude's switch is on and its calls
    /// run at standard speed anyway.
    private var fastModeIcon: String? {
        if isKimi { return nil }
        if isCodex {
            return codexFastOn ? "bolt.fill" : nil
        }
        switch claudeFastVerdict {
        case .off: return nil
        case .notServing: return "bolt.slash.fill"
        case .requested, .running: return "bolt.fill"
        }
    }

    /// Under the model rows: one Fast mode switch — claude's opt-in, or
    /// codex's Fast tier. Nothing for kimi, which has no such mode: its
    /// faster option is a separate high-speed MODEL, listed with the rest.
    @ViewBuilder
    private var fastModeFooter: some View {
        if isCodex {
            codexFastModeSwitch
        } else if !isKimi {
            let supported = fastModeSupported(forModel: options.model)
            fastModeSwitch(
                isOn: Binding(get: { options.fastMode && supported },
                              set: { options.fastMode = $0 }),
                enabled: supported,
                lines: ClaudeFastModeWords.lines(
                    supported: supported, cloudProvider: claudeCloudProvider != nil,
                    agentName: agentName, account: claudeAccount,
                    creditsBlock: claudeCreditsBlock, verdict: claudeFastVerdict))
        }
    }

    /// Codex's Fast mode, the switch codex's own compact picker draws: on
    /// runs the model's Fast tier, off pins standard (`default`) — so off
    /// holds even where codex's config turns a tier on by itself. Until
    /// it is flipped, it shows what codex itself would run here (its
    /// config for this folder, else the model's default) and says so.
    @ViewBuilder
    private var codexFastModeSwitch: some View {
        let fast = codexFastTier
        let on = codexFastOn
        fastModeSwitch(
            isOn: Binding(get: { on }, set: { turnOn in
                var updated = options
                updated.serviceTier = turnOn ? fast?.id : CodexSpeed.standard
                // A value saved before codex had a speed choice here is
                // superseded by any flip.
                updated.fastMode = false
                options = updated
            }),
            enabled: fast != nil,
            lines: codexFastModeLines(fast: fast, on: on))
    }

    /// The codex speed a task scheduled from here keeps — the speed the
    /// switch shows (`CodexSpeed.carriedToTask`).
    private var codexTaskSpeedPick: String? {
        CodexSpeed.carriedToTask(pick: codexCaps.speedPick(for: options, folder: codexFolder),
                                 effective: codexFastOn ? codexEffectiveTier : nil)
    }

    private func codexFastModeLines(fast: CodexServiceTier?, on: Bool) -> [String] {
        guard let fast else {
            return [codexCaps.speedSettings(forFolder: codexFolder).featureEnabled
                    ? String(localized: "Not offered for this model",
                             comment: "Model menu switch subtitle: the selected model has no fast mode")
                    : String(localized: "Turned off in \(agentName)'s config (features.fast_mode)",
                             comment: "Codex speed: the fast_mode feature is disabled in the user's codex config; placeholder is the agent label")]
        }
        var lines = [fast.description.isEmpty ? fast.name : fast.description]
        if on, codexCaps.speedPick(for: options, folder: codexFolder) == nil {
            lines.append(String(localized: "On by default in \(agentName)",
                                comment: "Fast mode switch: on because codex itself turns it on here — its config, or the model's own default — and not because it was picked; the placeholder is the agent label"))
        }
        return lines
    }

    /// The one switch both agents draw: the title, and each line under it
    /// wrapped at a fixed width. A popover takes its size when it opens,
    /// and a line that lengthens after that — the credits verdict is
    /// re-read as the menu opens — would otherwise be cut short.
    private func fastModeSwitch(isOn: Binding<Bool>, enabled: Bool,
                                lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 4)
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(fastModeTitle)
                        .sipFont(13)
                        .foregroundColor(SipDesign.textPrimary)
                    ForEach(lines, id: \.self) { line in
                        Text(verbatim: line)
                            .sipFont(11)
                            .foregroundColor(SipDesign.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 230 * SipFont.ratio(fontScale), alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
    }

    /// Alias row/chip title carrying the version the alias resolves to
    /// here ("opus" → "Opus 5") — read off the installed claude's own
    /// alias table, with what this machine has observed the alias run
    /// as the fallback, never hand-maintained. Bare alias name only
    /// when nothing on this machine names that family.
    private func rememberedName(forAlias alias: String) -> String {
        config.rememberedModelName(forAlias: alias)
    }

    /// Chip label: the CHOICE in force, named as what the next send
    /// will run. An alias pick names the alias's current resolution;
    /// a concrete pick names itself. The id the session last ran under
    /// (`modelFullId`) is the hover's, not the title's — after a CLI
    /// update it names a model the next send will not run.
    private var modelChipTitle: String {
        if isKimi {
            if let picked = options.model, !picked.isEmpty {
                // Kimi's own display name; a model newer than the
                // config we read shows as its slug.
                return kimiCaps.displayName(forModel: picked)
            }
            // Same rule as the other two chips: name what the default
            // resolves to rather than the bare word "Model".
            if let fallback = kimiCaps.defaultModel, !fallback.isEmpty {
                return kimiCaps.displayName(forModel: fallback)
            }
            return String(localized: "Model",
                          comment: "Model menu label when no override is set")
        }
        if isCodex {
            if let picked = options.model, !picked.isEmpty {
                // Prefer codex's own display name ("GPT-5.5"); a model
                // newer than its catalog shows as its slug.
                return codexCaps.models.first { $0.slug == picked }?
                    .displayName ?? picked
            }
            // Same rule as claude's chip: name what the default
            // resolves to here rather than the bare word "Model".
            if let fallback = codexCaps.defaultModel(forFolder: codexFolder) {
                return codexCaps.models.first { $0.slug == fallback }?
                    .displayName ?? fallback
            }
            return String(localized: "Model",
                          comment: "Model menu label when no override is set")
        }
        if let picked = options.model, !picked.isEmpty {
            return rememberedName(forAlias: picked)
        }
        // No override: name what a Default send runs as — claude's own
        // configured default, else what such a send resolves to here.
        if let name = claudeDefaultName, !name.isEmpty {
            return name
        }
        return String(localized: "Model",
                      comment: "Model menu label when no override is set")
    }

    /// The exact ids on hover — the display name is derived, the ids
    /// are the ground truth: for an alias, what it resolves to now and
    /// (when different) what the session last ran under; for a
    /// concrete pick, the id itself. Names the variable when an
    /// environment override decided the resolution, and, when the fast
    /// switch is in play, what became of it.
    private var modelHelp: String {
        var base: String
        if isCodex || isKimi {
            base = options.modelFullId
                ?? options.model
                ?? String(localized: "Model",
                          comment: "Model menu label when no override is set")
        } else {
            base = claudeModelHelp
        }
        guard let fast = fastModeHint else { return base }
        return base + " · " + fast
    }

    private var claudeModelHelp: String {
        let picked = options.model ?? ""
        if ClaudeModelDisplay.isFullId(picked) { return picked }
        // The alias in force: the pick, else the configured default,
        // else claude's own Default ("").
        let alias: String
        if !picked.isEmpty {
            alias = picked
        } else if let configured = configuredDefault, !configured.isEmpty {
            alias = configured
        } else {
            alias = ""
        }
        // A configured default that is itself a full id names itself,
        // like a concrete pick.
        if ClaudeModelDisplay.isFullId(alias) { return alias }
        guard let resolved = config.resolvedModel(forAlias: alias) else {
            return options.modelFullId
                ?? (picked.isEmpty
                    ? String(localized: "Model",
                             comment: "Model menu label when no override is set")
                    : picked)
        }
        var parts: [String] = [alias.isEmpty ? resolved.id : "\(alias) → \(resolved.id)"]
        if resolved.source == .environment {
            // The Default resolves through the family its observed id
            // records, so that is the family whose variable spoke.
            let family = alias.isEmpty
                ? (ClaudeModelDisplay.familyAlias(of: config.agentModelFullId(forAlias: "") ?? "") ?? "")
                : ClaudeModelDisplay.splitVariant(alias).id
            if !family.isEmpty {
                parts.append(String(localized: "set by \(ClaudeModelCatalog.ChildEnvironmentFacts.overrideVariable(forFamily: family))",
                                    comment: "Model chip hover: the environment variable that decided which model the alias resolves to"))
            }
        }
        if let last = options.modelFullId, !last.isEmpty,
           ClaudeModelDisplay.splitVariant(last).id
               != ClaudeModelDisplay.splitVariant(resolved.id).id {
            parts.append(String(localized: "last ran as \(last)",
                                comment: "Model chip hover: the model id this session's previous turn actually ran under, when it differs from what the alias resolves to now"))
        }
        return parts.joined(separator: " · ")
    }

    private var modelButton: some View {
        Button {
            // The credits verdict the switch's line states moves with
            // every claude API response; two stats when it has not.
            if !isCodex && !isKimi { caps.refreshUsageCreditsBlock() }
            // Codex's answer for this folder, fresh for the choice the
            // menu is about to state.
            if isCodex { codexCaps.refreshSpeedSettings(forFolder: codexFolder, force: true) }
            showingModelPopover = true
        } label: {
            trailingMenuLabel(modelChipTitle, icon: fastModeIcon)
        }
        .buttonStyle(.plain)
        .help(modelHelp)
        .popover(isPresented: $showingModelPopover, arrowEdge: .bottom) {
            ComposerOptionList(rows: modelRows, selected: options.model, onPick: { value in
                // One assignment → one onChange: the picked alias replaces
                // both the flag value and the recorded-id display.
                var updated = options
                updated.model = value
                updated.modelFullId = nil
                // Every agent's levels are per model, so a model change
                // can strand an effort the new model does not accept —
                // picking `gpt-5.5` while `ultra` was selected would send
                // `-c model_reasoning_effort=ultra` for a model whose
                // catalog stops at `xhigh`, a kimi model that publishes
                // no levels would keep a KIMI_MODEL_THINKING_EFFORT the
                // picker no longer shows, and claude runs Haiku with no
                // effort at all. The picker stops OFFERING it at that
                // point, so leaving it set means sending a value the
                // user can no longer even see.
                //
                // Safe for claude while its catalog is still loading: an
                // unread catalog answers the WHOLE list, never an empty
                // one, so nothing is cleared on a guess.
                if let effort = updated.effort, !effort.isEmpty,
                   !effortLevels(forModel: value).contains(effort) {
                    updated.effort = nil
                }
                // Same rule for the fast switch: a model that does not
                // offer it must not carry a request the picker no
                // longer shows — claude's own toggle turns itself off
                // on a model switch for the same reason.
                if updated.fastMode, !fastModeSupported(forModel: value) {
                    updated.fastMode = false
                }
                // And for codex's speed: a tier the new model does not
                // advertise goes back to Default. Standard is a speed
                // every model has.
                if isCodex, let tier = updated.serviceTier,
                   tier != CodexSpeed.standard,
                   codexCaps.serviceTier(id: tier, forModel: value, folder: codexFolder) == nil {
                    updated.serviceTier = nil
                }
                options = updated
                showingModelPopover = false
            }, footer: { fastModeFooter })
        }
    }

    /// Shared with the scheduled-task panel — see `AgentEffort`.
    private static func effortDisplayName(_ level: String) -> String {
        AgentEffort.displayName(level)
    }

    /// Faster → smarter, same axis claude's own /effort gauge uses.
    private var effortRows: [ComposerOptionRow] {
        [ComposerOptionRow(
            value: nil,
            title: String(localized: "Default",
                          comment: "Effort menu row — claude's default effort"),
            // Kimi records a `default_effort` per model, so this row can
            // name what it resolves to ("Max") the way the model menu's
            // Default row names the model. Codex's and claude's catalogs
            // carry a per-model default as well, but it is not their
            // last word (codex's config and claude's served settings
            // outrank it), so it is not named here.
            subtitle: isKimi
                ? kimiCaps.defaultEffort(forModel: options.model)
                    .map(Self.effortDisplayName)
                : nil)]
        // Levels are PER MODEL for all three agents — codex's catalog
        // says `gpt-5.6-terra` accepts `ultra` where `gpt-5.5` stops at
        // `xhigh`, kimi's config lists `support_efforts` per model, and
        // claude's catalog gives Haiku no effort at all — so the list
        // follows the model this composer would actually send with.
        // Every list arrives already ordered fast → deep.
        + effortLevels.map {
            ComposerOptionRow(value: $0, title: Self.effortDisplayName($0), subtitle: nil)
        }
    }

    /// This agent's effort levels, fast → deep.
    private var effortLevels: [String] { effortLevels(forModel: options.model) }

    private func effortLevels(forModel model: String?) -> [String] {
        if isKimi { return kimiCaps.effortLevels(forModel: model) }
        if isCodex {
            // The model a send runs as — the pick, else the model codex's
            // config names in this folder.
            let slug = (model?.isEmpty == false) ? model
                : codexCaps.defaultModel(forFolder: codexFolder)
            return codexCaps.effortLevels(forModel: slug)
        }
        // The model a send runs as — the pick, else claude's configured
        // default, else its Default — read off the catalog the installed
        // binary resolves through (`ClaudeModelCatalog.effortLevels`).
        return caps.effortLevels(forModelId: config.resolvedClaudeModelId(
            picked: model, configuredDefault: configuredDefault))
    }

    /// Kimi and claude publish levels PER MODEL, and some of their
    /// models take none (a kimi model with no `support_efforts`,
    /// claude's Haiku) — so for those two an empty list is a real
    /// answer ("this model has no levels"), and a picker offering
    /// nothing but "Default" is a dead control. Kimi's own UI shows the
    /// levels only "when available for the selected model"; claude's
    /// shows Haiku none. Neither list is empty on a guess: an unread
    /// claude catalog answers the whole list.
    ///
    /// Not codex: its list is never empty (an unknown model gets the
    /// union), so the chip always shows there.
    private var showsEffortChip: Bool {
        isCodex || !effortLevels.isEmpty
    }

    private var effortButton: some View {
        Button {
            showingEffortPopover = true
        } label: {
            // "Default", not "Effort" — the chip states the CHOICE in
            // force, exactly as the mode chip does. A chip that names
            // its own control reads as though nothing had been decided.
            trailingMenuLabel(options.effort.map(Self.effortDisplayName)
                              ?? String(localized: "Default",
                                        comment: "Effort menu label when no override is set"))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingEffortPopover, arrowEdge: .bottom) {
            ComposerOptionList(rows: effortRows, selected: options.effort) { value in
                options.effort = value
                showingEffortPopover = false
            }
        }
    }

    // MARK: Small shared pieces

    private func controlLabel(icon: String, text: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .sipFont(12, weight: .medium)
                .foregroundColor(SipDesign.textSecondary)
            if let text = text {
                Text(text)
                    .sipFont(11)
                    .foregroundColor(SipDesign.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
    }

    private func trailingMenuLabel(_ text: String,
                                   icon: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .sipFont(9, weight: .semibold)
                    .foregroundColor(SipDesign.textSecondary)
            }
            Text(text)
                .sipFont(11, weight: .medium)
                .foregroundColor(SipDesign.textSecondary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
    }

}

/// Grey rounded hover backdrop for the control-strip items — the same
/// look the sidebar rows use (`SidebarRowBackground`), re-owned here
/// so each control keeps its own hover state inside the strip. When
/// `hint` is set, a small label floats above the control for exactly
/// as long as the cursor is over it — deliberately not `.help()`,
/// whose system tooltip appears late and lingers.
private struct HoverHighlight<Content: View>: View {
    var hint: String? = nil
    /// Read-only surfaces pass false: they still get the instant hint,
    /// but no fill — a highlight on something that cannot be clicked
    /// reads as a button that does nothing.
    var highlight: Bool = true
    /// Where the hint sits over its control. Centred by default; the
    /// controls at the strip's RIGHT end pass `.trailing`, because a
    /// hint wider than a small chip overhangs it on both sides, and on
    /// that side there is only the window's 60 pt margin to overhang
    /// into — the last letters of a centred hint land past the window
    /// edge and are simply not drawn. Trailing keeps the hint's right
    /// edge on the control's, so it grows leftward over the strip.
    var hintAlignment: HorizontalAlignment = .center
    /// A control drawn INSIDE the hint bubble after its text — the
    /// context chip's "?". Its presence changes what the bubble is:
    /// hit-testable, and held up while the cursor is over it or for a
    /// moment after leaving the control, so the pointer can cross the
    /// gap between the two. Without one the bubble is exactly what
    /// every other hint in the strip is — untouchable, gone on leave.
    ///
    /// A BUILDER rather than a view: it is handed `collapse`, which
    /// folds the bubble at once. A control whose click opens a sheet
    /// must call it first — a view under a sheet is not sent a
    /// hover-exit, so without it the bubble would still be floating
    /// over the chip when the sheet closed.
    var hintAccessory: ((@escaping () -> Void) -> AnyView)? = nil
    @ViewBuilder var content: Content
    /// Cursor over the control.
    @State private var hovered = false
    /// Cursor over the bubble — only ever true with an accessory.
    @State private var bubbleHovered = false
    /// The bubble's own state, which lags the two hovers by
    /// `hintHold` on the way OUT and never on the way in. Only consulted
    /// with an accessory; a plain hint follows `hovered` directly.
    @State private var held = false
    @State private var hideWork: DispatchWorkItem? = nil

    /// How long the bubble outlives the cursor leaving both the control
    /// and the bubble. The gap between them is about 17 pt; crossing
    /// it takes a fraction of this.
    private var hintHold: TimeInterval { 0.25 }

    private var showsHint: Bool {
        hintAccessory == nil ? hovered : held
    }

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered && highlight ? Color.gray.opacity(0.2) : Color.clear)
            )
            .overlay(alignment: Alignment(horizontal: hintAlignment,
                                          vertical: .top)) {
                if showsHint, let hint = hint {
                    HStack(spacing: 4) {
                        Text(hint)
                            .sipFont(10.5, weight: .medium)
                            .foregroundColor(SipDesign.textPrimary)
                        if let hintAccessory {
                            hintAccessory(collapseHint)
                        }
                    }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(SipDesign.surfaceMuted)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(SipDesign.borderLight, lineWidth: 1)
                                )
                        )
                        .fixedSize()
                        .offset(y: -26)
                        .onHover { inside in
                            bubbleHovered = inside
                            updateHold()
                        }
                        .allowsHitTesting(hintAccessory != nil)
                }
            }
            .onHover { hovering in
                hovered = hovering
                updateHold()
            }
    }

    /// In at once, out after `hintHold` — cancelled by either hover
    /// coming back. The work item is the whole state machine.
    private func updateHold() {
        guard hintAccessory != nil else { return }
        if hovered || bubbleHovered {
            hideWork?.cancel()
            hideWork = nil
            held = true
        } else if held, hideWork == nil {
            let work = DispatchWorkItem {
                held = false
                hideWork = nil
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hintHold, execute: work)
        }
    }

    /// Fold the bubble now, and forget both hovers: the accessory's
    /// click is about to cover this view with a sheet, after which no
    /// exit event will arrive for either. The next hover-enter starts
    /// the cycle again.
    private func collapseHint() {
        hideWork?.cancel()
        hideWork = nil
        bubbleHovered = false
        hovered = false
        held = false
    }
}

/// The "?" inside the context chip's hint on a codex session. A plain
/// glyph that fills and takes the accent on hover, with a pointing
/// hand — the one thing in the strip's hints that can be clicked, and
/// it has to look it.
private struct HintHelpGlyph: View {
    let accessibilityLabel: String
    let action: () -> Void
    @State private var hovered = false
    /// At most one outstanding cursor push — same guard as the
    /// sidebar's resize handle.
    @State private var cursorPushed = false

    var body: some View {
        Button {
            // The click opens a sheet over this window, and a view
            // covered by a sheet is not promised a hover-exit — so the
            // cursor is restored here, before the sheet, not left to it.
            setPointingHand(false)
            hovered = false
            action()
        } label: {
            Image(systemName: hovered ? "questionmark.circle.fill" : "questionmark.circle")
                .sipFont(11, weight: .medium)
                .foregroundColor(hovered ? SipDesign.blue : SipDesign.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside
            setPointingHand(inside)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private func setPointingHand(_ active: Bool) {
        if active, !cursorPushed {
            NSCursor.pointingHand.push()
            cursorPushed = true
        } else if !active, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}

/// One row in a `ComposerOptionList`. `value` nil is the "Default"
/// (no-flag) choice.
private struct ComposerOptionRow: Identifiable {
    let value: String?
    let title: String
    let subtitle: String?
    /// A section label ("Other models"): drawn, never picked.
    var isHeader: Bool = false
    var id: String { isHeader ? "__header__" + title : (value ?? "__default__") }

    static func header(_ title: String) -> ComposerOptionRow {
        ComposerOptionRow(value: nil, title: title, subtitle: nil, isHeader: true)
    }
}

/// Custom dropdown body for the mode / model / effort pickers. A plain
/// popover list instead of `Menu` so rows can highlight grey on hover
/// (NSMenu rows always flash the blue accent) and carry a dimmer
/// second line for behavior hints. `footer` sits under the rows —
/// the model menu's fast switch; the others pass nothing.
private struct ComposerOptionList<Footer: View>: View {
    let rows: [ComposerOptionRow]
    let selected: String?
    let onPick: (String?) -> Void
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                // The Default row sits apart from the real values,
                // like the old menu's divider.
                if index == 1 {
                    Divider().padding(.vertical, 4)
                }
                if row.isHeader {
                    Text(row.title)
                        .sipFont(11, weight: .semibold)
                        .foregroundColor(SipDesign.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 3)
                } else {
                    ComposerOptionRowButton(
                        row: row,
                        selected: row.value == selected,
                        action: { onPick(row.value) }
                    )
                }
            }
            footer()
        }
        .padding(6)
        .frame(minWidth: 230, alignment: .leading)
    }
}

extension ComposerOptionList where Footer == EmptyView {
    init(rows: [ComposerOptionRow], selected: String?,
         onPick: @escaping (String?) -> Void) {
        self.rows = rows
        self.selected = selected
        self.onPick = onPick
        self.footer = { EmptyView() }
    }
}

private struct ComposerOptionRowButton: View {
    let row: ComposerOptionRow
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .sipFont(13)
                        .foregroundColor(SipDesign.textPrimary)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .sipFont(11)
                            .foregroundColor(SipDesign.textSecondary)
                    }
                }
                Spacer(minLength: 12)
                if selected {
                    Image(systemName: "checkmark")
                        .sipFont(11, weight: .semibold)
                        .foregroundColor(SipDesign.blue)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Color.gray.opacity(0.2) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in hovered = hovering }
    }
}

// MARK: - Chat only gate

/// The MainActor wrapper of `ChatOnlyAvailability.offered`, over what
/// the app's scrapers hold right now: claude's `--help` (`Claude
/// Capabilities`), codex's version (`AgentCLIUpdateMonitor`) and
/// feature list (`CodexCatalog`), kimi's version. The composer and the
/// session view both read it, so the chip and the send cannot disagree.
/// Views that draw it observe the three publishers, so the row appears
/// the moment a scrape lands.
enum ChatOnlyGate {
    @MainActor static func offered(agentKey: String) -> Bool {
        ChatOnlyAvailability.offered(
            agent: agentKey,
            claudeHelp: ClaudeCapabilities.shared.chatOnlyHelp,
            codexVersion: AgentCLIUpdateMonitor.shared.installed["codex"]?.text,
            codexFeatures: CodexCatalog.shared.featureNames,
            kimiVersion: AgentCLIUpdateMonitor.shared.installed["kimi"]?.text)
    }

    /// Whether `offered` is a verdict yet rather than "not read yet".
    @MainActor static func settled(agentKey: String) -> Bool {
        ChatOnlyAvailability.isSettled(
            agent: agentKey,
            claudeHelp: ClaudeCapabilities.shared.chatOnlyHelp,
            codexVersion: AgentCLIUpdateMonitor.shared.installed["codex"]?.text,
            codexFeatures: CodexCatalog.shared.featureNames,
            kimiVersion: AgentCLIUpdateMonitor.shared.installed["kimi"]?.text)
    }
}

// MARK: - Fast mode words

/// Every sentence SipAI says about claude's fast mode and the usage
/// credits it is paid from, spelled once: the composer's switch and
/// chip, the scheduled-task card and the usage window all read these,
/// so the same state is never described two ways.
enum ClaudeFastModeWords {
    static var title: String {
        String(localized: "Fast mode",
               comment: "Model menu switch: the agent's faster inference mode")
    }

    /// Why the switch is not offered: the provider, else the model.
    static func unsupported(cloudProvider: Bool) -> String {
        cloudProvider
            ? String(localized: "Only available on the Anthropic API directly",
                     comment: "Fast mode status: not offered through a cloud provider or gateway")
            : String(localized: "Not offered for this model",
                     comment: "Model menu switch subtitle: the selected model has no fast mode")
    }

    /// Claude's cached reason the usage credits are unavailable, with
    /// what that means for fast mode.
    static func needsCredits(_ code: String) -> String {
        String(localized: "Needs usage credits · \(credits(code))",
               comment: "Model menu switch subtitle: fast mode on a Claude plan is paid from usage credits, which are unavailable; the placeholder says why")
    }

    /// The lines under the switch, in order: what fast mode costs on this
    /// account (or why it is not offered), then what stands in its way
    /// right now — or, while it is on, what the last reply got. Drawn in
    /// both of the switch's states, so the cost is said before it is
    /// turned on and the reason after.
    static func lines(supported: Bool, cloudProvider: Bool, agentName: String,
                      account: PlanAccountKind?, creditsBlock: String?,
                      verdict: ClaudeFastMode.Verdict) -> [String] {
        guard supported else { return [unsupported(cloudProvider: cloudProvider)] }
        var lines = [cost(account: account, agentName: agentName)]
        switch verdict {
        case .off:
            if let block = creditsBlock {
                lines.append(String(localized: "Right now, \(credits(block))",
                                    comment: "Fast mode switch, while off: why it could not run now; the placeholder is the reason (“your usage credits are used up”)"))
            }
        case .requested:
            break
        case .running:
            lines.append(String(localized: "The last reply ran fast",
                                comment: "Fast mode switch, while on: the newest API call ran in fast mode"))
        case .notServing(let why):
            lines.append(status(why))
        }
        return lines
    }

    /// Why the calls are not getting fast mode, as the switch's own line —
    /// `notServing` without its "Needs usage credits" lead, which the
    /// cost line above it already says.
    static func status(_ why: ClaudeFastMode.Why) -> String {
        if case .credits(let code) = why {
            return String(localized: "Not running · \(credits(code))",
                          comment: "Fast mode switch, while on: it is not running; the placeholder is the reason (“your usage credits are used up”)")
        }
        return notServing(why)
    }

    /// What fast mode costs on this account. On a Claude plan it is paid
    /// from usage credits ALONE — never from the plan's own limits, even
    /// with plan usage left (Anthropic's fast mode documentation).
    static func cost(account: PlanAccountKind?, agentName: String) -> String {
        switch account {
        case .plan?:
            return String(localized: "\(agentName) fast mode is paid only from usage credits.",
                          comment: "Fast mode switch on a Claude plan: fast mode is paid from usage credits alone, never from the plan's own limits; the placeholder is the agent label")
        case .apiKey?:
            return String(localized: "Billed at a higher rate than standard",
                          comment: "Model menu switch subtitle: on an API key, fast mode is billed at a higher per-token rate")
        default:
            return String(localized: "Same model, faster output",
                          comment: "Model menu switch subtitle: what fast mode is, when the account kind is not known")
        }
    }

    /// Why claude's fast mode is not what the calls get, in one line.
    /// A refusal is claude's own sentence, drawn as it wrote it.
    static func notServing(_ why: ClaudeFastMode.Why) -> String {
        switch why {
        case .refused(let text):
            return text
        case .cooldown:
            return String(localized: "Paused after a rate limit · resumes by itself",
                          comment: "Fast mode status: paused after a rate limit; the agent turns it back on when the pause ends")
        case .disabled(let code):
            return disabled(code)
        case .reportedOff:
            return String(localized: "Reported off for this model",
                          comment: "Fast mode status: the agent reported fast mode off and gave no reason")
        case .credits(let code):
            return needsCredits(code)
        case .ranStandard:
            return String(localized: "The last reply ran at standard speed",
                          comment: "Fast mode status: fast mode was requested but the newest API call ran at standard speed")
        }
    }

    /// Why usage credits are unavailable, from the reason code claude
    /// caches. The codes are claude's; the sentences are ours.
    static func credits(_ code: String) -> String {
        switch code {
        case "out_of_credits":
            return String(localized: "your usage credits are used up",
                          comment: "Why usage credits are unavailable: the balance is exhausted")
        case "org_spend_cap_reached", "org_level_disabled_until":
            return String(localized: "the usage credit limit is reached",
                          comment: "Why usage credits are unavailable: the spending limit is reached")
        case "org_level_disabled", "org_service_level_disabled":
            return String(localized: "your organization has turned usage credits off",
                          comment: "Why usage credits are unavailable: disabled by the organization")
        case "member_level_disabled":
            return String(localized: "usage credits are turned off for your account",
                          comment: "Why usage credits are unavailable: disabled for this member")
        case "seat_tier_level_disabled", "seat_tier_zero_credit_limit",
             "member_zero_credit_limit", "group_zero_credit_limit":
            return String(localized: "your plan has no usage credits",
                          comment: "Why usage credits are unavailable: the plan or seat includes none")
        case "overage_not_provisioned", "no_limits_configured":
            return String(localized: "usage credits are not turned on",
                          comment: "Why usage credits are unavailable: never enabled")
        default:
            return String(localized: "usage credits are unavailable",
                          comment: "Why usage credits are unavailable: a reason this app does not know")
        }
    }

    /// Claude's `fast_mode_disabled_reason`, in a sentence. An unknown
    /// code is shown as it came.
    static func disabled(_ code: String) -> String {
        switch code {
        case "extra_usage_disabled":
            return String(localized: "Needs usage credits",
                          comment: "Fast mode status: fast mode is paid from usage credits, which are not available")
        case "free":
            return String(localized: "Needs a paid subscription",
                          comment: "Fast mode status: the account's plan does not include fast mode")
        case "preference":
            return String(localized: "Turned off by your organization",
                          comment: "Fast mode status: the organization disabled fast mode")
        case "model_not_allowed":
            return String(localized: "Its model is not among your organization's allowed models",
                          comment: "Fast mode status: the organization's model allow-list excludes the fast mode model")
        case "not_first_party":
            return String(localized: "Only available on the Anthropic API directly",
                          comment: "Fast mode status: not offered through a cloud provider or gateway")
        case "network_error":
            return String(localized: "Could not be checked · network error",
                          comment: "Fast mode status: the availability check failed on the network")
        default:
            return String(localized: "Unavailable (\(code))",
                          comment: "Fast mode status: a reason code this app does not know, shown as the agent sent it")
        }
    }
}

// MARK: - Turn clock

/// The composer strip's turn clock: counts up once a second while a
/// turn runs, then holds that turn's total until the next one starts.
/// Same typographic voice as the token counter beside it.
///
/// The ticking is sealed inside one small leaf view: `TimelineView`
/// redraws THIS chip and nothing above it. A 1 Hz tick anywhere in the
/// transcript would re-render the whole transcript every second of
/// every turn — on top of the re-render each streamed event already
/// causes.
///
/// `startedAt` non-nil means running. Deliberately a Date rather than
/// an elapsed number, so the caller never has to tick.
///
/// External turns tick too, from the transcript's OWN record stamp
/// (`AgentSessionScanner.lastTurnStartDate` → the runner's
/// `externalTurnStartedAt`) — the writer's records carry timestamps,
/// so the clock is read, never invented. When even that is unknown
/// the chip simply rests. The resting value is broader still: it
/// comes from the transcript when the app didn't run the turn, so an
/// old session shows what its last turn took.
struct TurnClockChip: View {
    /// Start of the in-flight turn, or nil when nothing is running.
    var startedAt: Date?
    /// Seconds the last finished turn took; shown while idle.
    var finished: Double?

    var body: some View {
        Group {
            if let startedAt {
                // `.periodic` anchored to the turn's own start, so the
                // digit flips on the second boundary the number is
                // actually counting — not on whenever the view appeared.
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    label(seconds: max(0, context.date.timeIntervalSince(startedAt)),
                          running: true)
                }
            } else if let finished, finished > 0 {
                label(seconds: finished, running: false)
            }
        }
    }

    /// Running is tinted; idle is quiet. The colour is the whole
    /// "something is happening" signal now that the spinner row is
    /// gone, so it has to differ from the readouts either side of it.
    private func label(seconds: Double, running: Bool) -> some View {
        // Counting → always the padded form, so the very first frame is
        // "00s" and the width never moves. Resting → the form that can
        // still say "0.4s" for a turn that failed instantly.
        let timeStr = running
            ? AgentComposer.clockText(seconds)
            : AgentComposer.durationText(seconds)
        return HStack(spacing: 3) {
            Image(systemName: "clock")
                .sipFont(9)
            Text(verbatim: timeStr)
                // Fixed-width digits: without this the whole control
                // strip shuffles sideways every single second.
                .monospacedDigit()
                .sipFont(11)
        }
        // Running borrows the transcript's inline-code accent, so the
        // live clock reads as the same "machine speaking" blue as the
        // `code spans` above it. Referenced, not copied: change it
        // there and this follows.
        .foregroundColor(running
                         ? ChatMarkdownStyle.inlineCode
                         : SipDesign.textSecondary)
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .accessibilityLabel(running
            ? String(localized: "Running for \(timeStr)",
                     comment: "Accessibility label for the composer's turn clock while running")
            : String(localized: "Latest agent response took \(timeStr)",
                     comment: "Accessibility label for the composer's turn clock after a turn"))
    }
}

// MARK: - Token counter

/// How full the session's context window is — "39%" in the composer's
/// control strip, with the numbers behind it on hover.
///
/// A PERCENTAGE, not a token count, and the two are not
/// interchangeable. The number this divides is the context footprint of
/// the newest API call, which legitimately goes DOWN — at a compaction
/// most visibly, and by a few percent at most turn boundaries. Shown as
/// a count that reads as a running total, a drop reads as a bug; shown
/// as a gauge, it reads as what it is. It is also the metric each
/// agent's own terminal shows for the same session (claude's
/// "N% context used", kimi's status bar), so the two agree.
///
/// Agent sessions only — chats carry no chip at all (their turns often
/// record no usage, and a number that appears for some chats and not
/// others is worse than none). The call site gates visibility behind
/// Settings → "Show context usage".
struct ContextUsageChip: View {
    /// Tokens of context on the newest call: the INPUT side, cached
    /// prefix included, without that call's own reply.
    var contextTokens: Int
    /// The window `contextTokens` sits in, or nil when this machine
    /// cannot state one for the model in question. nil is not a
    /// fallback to a constant — see `label`.
    var windowTokens: Int?

    var body: some View {
        // The visible hint comes from the enclosing HoverHighlight at
        // the call site, so no `.help()` here — two tooltips for one
        // readout is noise, and the system one arrives a second late.
        Text(verbatim: label)
            .monospacedDigit()
            .sipFont(11)
            // One constant colour regardless of occupancy — this
            // states a fact, it does not warn.
            .foregroundColor(.orange)
            .accessibilityLabel(accessibilityText)
    }

    /// The percentage when a window is known, else the raw count.
    ///
    /// Falling back to a COUNT rather than to a percentage over an
    /// assumed window is the whole rule: a percentage is a claim about
    /// how much room is left, and stating it over a guessed denominator
    /// is a specific wrong claim, where a count is merely less
    /// informative. (The constant this replaced assumed 200,000 for
    /// every claude session, and every model in the picker has a 1M
    /// window — it read 100% at 20% full.)
    private var label: String {
        guard let window = windowTokens, window > 0 else {
            return String(localized: "\(ContextUsageFormat.compact(contextTokens)) tokens",
                          comment: "Composer context chip when no window is known")
        }
        return "\(ContextUsageFormat.percent(contextTokens, of: window))%"
    }

    /// The one sentence behind the percentage. Static so the call site
    /// can hand it to the strip's shared hover label without a second
    /// copy of the rule.
    static func hoverText(contextTokens: Int, windowTokens: Int?) -> String {
        guard let window = windowTokens, window > 0 else {
            return String(localized: "Context now \(ContextUsageFormat.compact(contextTokens)) tokens (window not yet known)",
                          comment: "Hover on the composer context chip when no window is known")
        }
        return String(localized: "Context now \(ContextUsageFormat.compact(contextTokens)) of \(ContextUsageFormat.compact(window)) tokens",
                      comment: "Hover on the composer context chip")
    }

    private var accessibilityText: String {
        guard let window = windowTokens, window > 0 else {
            return Self.hoverText(contextTokens: contextTokens,
                                  windowTokens: windowTokens)
        }
        return String(
            localized: "Context window \(ContextUsageFormat.percent(contextTokens, of: window)) percent used",
            comment: "Accessibility label for the context usage chip")
    }
}

// MARK: - Growing text field

/// NSTextView wrapper that reports its content height so the composer
/// can hug a single line and grow with the text (clamped by the
/// caller). Enter sends, Shift+Enter inserts a newline — same contract
/// as `MultilineTextField`, which keeps its fixed-viewport behavior
/// for the chat cards.
struct GrowingTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    var onSubmit: () -> Void
    /// `DisplaySettings.spellCheck`, passed by the owning view.
    var spellChecking: Bool
    /// Files dropped ON THE TEXT FIELD, handed to the host so a drag
    /// stages exactly what the + button stages. Set by the composer
    /// while its mode chip is on Chat only; nil everywhere else, where a
    /// dragged path is still typed in — see `DropForwardingTextView` for
    /// why interception, and not a filter, is what takes the drag off
    /// NSTextView. Re-pointed in `updateNSView` with the rest of the
    /// host, since the chip moves while this view stands.
    var onDropFiles: (([URL]) -> Void)? = nil
    var onDropTargeted: ((Bool) -> Void)? = nil
    /// The tier-scaled point size and the spacing between wrapped
    /// lines, passed by the owning view — in POINTS, so this view does
    /// not have to know which scaling convention its host is under.
    /// No defaults, the `spellChecking` rule: a text view cannot fall
    /// out of the tier by omission.
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    /// The ids drawn on a grey token when they appear in the box — every
    /// session the app lists (`AgentManager.knownSessionIds`), so an id
    /// copied from a row's "Copy session ID" reads as one wherever it is
    /// pasted. Applied in `updateNSView` too: a scan lands, and the list
    /// grows, while this view stands.
    var sessionIdTokens: Set<String> = []

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = DropForwardingTextView.makeForwardingScrollView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        applyDropHandlers(to: tv)
        (tv as? DropForwardingTextView)?.sessionIdTokens = sessionIdTokens
        TextInputTypography.apply(pointSize: fontSize, lineSpacing: lineSpacing, to: tv)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textColor = NSColor.labelColor
        tv.insertionPointColor = NSColor.labelColor
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = NSSize(width: 6, height: 6)
        TextInputSpellChecking.apply(spellChecking, to: tv)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScrollElasticity = .none
        return scroll
    }

    private func applyDropHandlers(to textView: NSTextView) {
        guard let tv = textView as? DropForwardingTextView else { return }
        tv.onDropFiles = onDropFiles
        tv.onDropTargeted = onDropTargeted
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // The coordinator is made ONCE and keeps whatever struct it was
        // handed, so it has to be re-pointed at the fresh one or Enter
        // drives a snapshot of the composer taken when this text view
        // was built. `onSubmit` closes over `canSend`, which reads
        // `sending` and `externalBusy` — plain stored properties, frozen
        // at that instant. A composer BORN mid-turn (the router rebuilds
        // this view on every detour to a chat or a note, so returning to
        // a running session is the ordinary way to reach it) therefore
        // has a permanently dead Enter key while the send button — whose
        // `disabled` is re-evaluated every body pass — keeps working.
        // The reverse is worse: born idle, Enter still sends after an
        // EXTERNAL turn starts, putting a second writer on the session.
        // Same rule, same reason, as `SearchField`.
        context.coordinator.parent = self
        guard let tv = nsView.documentView as? NSTextView else { return }
        // Same rule, same reason: a drop closure captured when the text
        // view was BUILT stages into whatever the host looked like then
        // — and here the closure is nil or not depending on a chip the
        // user moves while this view stands.
        applyDropHandlers(to: tv)
        (tv as? DropForwardingTextView)?.sessionIdTokens = sessionIdTokens
        var remeasure = false
        if tv.string != text {
            tv.string = text
            remeasure = true
        }
        // Both hooks, like the spell-check switch: the tier is changed
        // behind a sheet that leaves this view standing. A change here
        // moves every line, so the reported height must follow.
        if TextInputTypography.apply(pointSize: fontSize, lineSpacing: lineSpacing, to: tv) {
            remeasure = true
            // The tokens hug the glyphs, and the glyphs just changed size.
            tv.needsDisplay = true
        }
        if remeasure { context.coordinator.reportHeight(of: tv) }
        TextInputSpellChecking.apply(spellChecking, to: tv)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextField
        init(_ parent: GrowingTextField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            reportHeight(of: tv)
        }

        /// Measure the laid-out text and push the height up. Deferred a
        /// runloop so we never mutate SwiftUI state mid view-update.
        ///
        /// Through `textLayoutManager`, never `layoutManager`: reading
        /// the latter on a stock text view silently drops it into
        /// TextKit 1 compatibility mode for good, and under TextKit 1 a
        /// paragraph `lineSpacing` — which this box carries from the
        /// font tier — draws the spelling underline at the BOTTOM of
        /// the line fragment, in the gap under the word rather than
        /// under it (measured: 11 px low for a 12 pt spacing; TextKit 2
        /// keeps it 1 px under the baseline). The two managers report
        /// the same used height for every shape of text, so nothing
        /// but the generation changes.
        func reportHeight(of tv: NSTextView) {
            let used: CGFloat
            if let tlm = tv.textLayoutManager {
                tlm.ensureLayout(for: tlm.documentRange)
                used = tlm.usageBoundsForTextContainer.height
            } else if let lm = tv.layoutManager, let tc = tv.textContainer {
                // Already TextKit 1 (nothing here puts it there); the
                // fallback keeps the box growing rather than frozen.
                lm.ensureLayout(for: tc)
                used = lm.usedRect(for: tc).height
            } else {
                return
            }
            let height = ceil(used + tv.textContainerInset.height * 2)
            if abs(height - parent.measuredHeight) > 0.5 {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.measuredHeight = height
                }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shift {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            }
            return false
        }

        /// No spelling dots on a session-id token. The checker reads a
        /// whole id — hyphens, digits and all — as ONE misspelled word,
        /// so with Typo check on every pasted id would carry a red
        /// underline from end to end.
        func textView(_ textView: NSTextView, shouldSetSpellingState value: Int,
                      range affectedCharRange: NSRange) -> Int {
            guard value != 0,
                  let tv = textView as? DropForwardingTextView,
                  tv.sessionIdTokenRanges.contains(where: {
                      NSIntersectionRange($0, affectedCharRange).length > 0
                  })
            else { return value }
            return 0
        }
    }
}

// MARK: - Schedule model

/// The composer's armed-schedule settings. `enabled` is the toggle;
/// while on, the composer's send button creates a scheduled task from
/// the input box's text. Folder, permission mode, model and effort are
/// deliberately NOT here — they come from the control strip so the
/// user never picks them twice.
struct ScheduleDraft: Equatable {
    var enabled: Bool = false
    var name: String = ""
    var taskDescription: String = ""
    /// When it runs. The same value the scheduled-task card edits, so
    /// the choices offered at creation and the choices offered later
    /// cannot drift apart — see `ScheduleTimingEditor`.
    var timing = ScheduleTiming()

    /// The `schedule:` value for the current selection — cron, or a
    /// one-time `once …`; nil for an invalid custom expression.
    var expression: String? { timing.expression }

    /// Short human summary ("every day at 9:00 AM", "once, tomorrow at
    /// 9:00 AM") for the banner and the armed schedule chip.
    var summary: String { timing.summary }

    /// Name shown in the armed banner before creation.
    var displayName: String {
        let slug = ScheduledTaskCreator.slugify(name)
        return slug.isEmpty
            ? String(localized: "unnamed", comment: "Placeholder task name in the armed banner")
            : slug
    }

    /// Human rendering of a schedule the composer just submitted (used
    /// for the success notice, after the draft has been reset).
    /// Delegates to the same parser the scheduler fires on, so the
    /// confirmation can never describe a different schedule from the
    /// one that will run.
    static func describe(schedule: String) -> String {
        TaskSchedule.parse(schedule)?.localizedDescriptionText ?? schedule
    }
}

// MARK: - Schedule popover

/// Toggle + timing fields for the composer's armed-schedule mode. The
/// task prompt is typed in the composer's input box, and folder / mode
/// / model / effort / speed come from the control strip — this popover
/// only owns the on/off switch, the name, and the timing.
private struct SchedulePopover: View {
    @Binding var schedule: ScheduleDraft
    @Binding var errorText: String?
    /// Shown in the caption so it's clear which folder/mode the task
    /// will inherit from the strip. The FULL tilde path — a scheduled
    /// task runs unattended, so the folder has to be unambiguous at the
    /// moment of creation, not merely recognizable.
    let folderPath: String
    let modeTitle: String
    /// A popover inherits its presenter's environment, so this is the
    /// tier scale the composer reads.
    @Environment(\.sipFontScale) private var fontScale

    var body: some View {
        let ratio = SipFont.ratio(fontScale)
        VStack(alignment: .leading, spacing: 10 * ratio) {
            Toggle(isOn: $schedule.enabled.animation(.easeInOut(duration: 0.15))) {
                Text("Run on a schedule",
                     comment: "Schedule popover toggle label")
                    .sipFont(13, weight: .semibold)
            }
            .toggleStyle(.switch)
            .controlSize(SipFont.controlSize(fontScale, base: .small))

            if schedule.enabled {
                VStack(alignment: .leading, spacing: 8 * ratio) {
                    TextField(
                        String(localized: "Task name (e.g. daily-review)",
                               comment: "Schedule popover name field placeholder"),
                        text: $schedule.name
                    )
                    .textFieldStyle(.roundedBorder)
                    .sipFont(12)

                    TextField(
                        String(localized: "Description (optional)",
                               comment: "Schedule popover description field placeholder"),
                        text: $schedule.taskDescription
                    )
                    .textFieldStyle(.roundedBorder)
                    .sipFont(12)

                    // The toggle above already IS "no schedule", so the
                    // frequency chips don't repeat the option; the hint
                    // is redundant next to the caption block below.
                    ScheduleTimingEditor(timing: $schedule.timing,
                                         offersManual: false,
                                         showsHint: false)

                    if let errorText = errorText {
                        Text(errorText)
                            .sipFont(11)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 3 * ratio) {
                        Text("Type the task prompt in the input box, then press send to create.",
                             comment: "Schedule popover caption — where the prompt comes from")
                        Text(String(localized: "Runs in \(folderPath) · \(modeTitle) mode — from the bar below.",
                                    comment: "Schedule popover caption — settings inherited from the control strip"))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .help(folderPath)
                    }
                    .sipFont(11)
                    .foregroundColor(SipDesign.textHint)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // Scaled with the type: the frequency and time chips wrap to the
        // width they are given, and a fixed 300 pt would hand the
        // largest tier a column of one-chip rows.
        .padding(14 * ratio)
        .frame(width: 300 * ratio)
    }
}
