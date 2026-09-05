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

    /// Mode / model / effort selections. Owned by AgentSessionView so
    /// they survive the draft→existing transition and persist to config.
    @Binding var options: AgentLaunchOptions
    /// Claude's own report of whether its newest turn here ran fast
    /// ("on" / "off" / "cooldown"); nil before any turn, and always nil
    /// for the other agents. The switch below is an intent, this is
    /// the outcome, and the chip's hover names both.
    var fastModeState: String? = nil

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
    /// Fired after a scheduled task is created so the sidebar reloads.
    var onScheduleCreated: () -> Void

    @EnvironmentObject var config: ConfigManager
    @ObservedObject private var caps = ClaudeCapabilities.shared
    @ObservedObject private var codexCaps = CodexCatalog.shared
    @ObservedObject private var kimiCaps = KimiCatalog.shared

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

    private var canSend: Bool {
        hasText && !sending && !externalBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = scheduleNotice {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundColor(SipDesign.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
            if scheduleDraft.enabled && scheduleAvailable {
                armedScheduleBanner
            }
            if let hint = slashCommandHint {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    // String expression, never an interpolated literal:
                    // the agent label is user-set and that overload
                    // markdown-parses.
                    Text(hint)
                        .font(.system(size: 12))
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
        }
        .onChange(of: folder) { _, _ in refreshConfiguredDefault() }
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

    private var inputCard: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(placeholder)
                        .foregroundColor(SipDesign.textHint)
                        .font(.system(size: 14))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                GrowingTextField(
                    text: $draft,
                    measuredHeight: $inputHeight,
                    onSubmit: { if canSend { handleSendTapped() } },
                    spellChecking: config.display.spellCheck
                )
                // Rests at roughly two lines tall, grows with the text.
                .frame(height: min(max(inputHeight, 60), 140))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            sendButton
                .padding(.trailing, 8)
                .padding(.bottom, 7)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(SipDesign.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(SipDesign.borderLight, lineWidth: 1)
                )
        )
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
                    .font(.system(size: 22))
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
                    .font(.system(size: 22))
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
            HoverHighlight(hint: String(localized: "Add file",
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
            if isKimi {
                // A statement, not a choice: `highlight: false` so it
                // doesn't read as a button, and the hint says WHY there
                // is nothing to pick.
                HoverHighlight(
                    hint: KimiCapabilities.autoApproveHint(agentName: agentName),
                    highlight: false
                ) {
                    autoApproveChip
                }
            } else {
                HoverHighlight(hint: String(localized: "Mode",
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
                HoverHighlight(hint: ContextUsageChip.hoverText(
                                    contextTokens: contextTokens,
                                    windowTokens: contextWindowTokens),
                               highlight: false,
                               hintAlignment: .trailing) {
                    ContextUsageChip(contextTokens: contextTokens,
                                     windowTokens: contextWindowTokens)
                }
            }
        }
        .padding(.horizontal, 4)
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

    private var selectedModeTitle: String {
        if let name = options.permissionMode {
            return isCodex ? CodexCapabilities.title(for: name)
                           : AgentPermissionMode(name: name).title
        }
        return String(localized: "Default",
                      comment: "Mode chip label when no permission mode override is set")
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
        if isCodex {
            return [defaultRow] + CodexCapabilities.modePresets.map {
                ComposerOptionRow(value: $0.value,
                                  title: CodexCapabilities.title(for: $0.value),
                                  subtitle: $0.hint)
            }
        }
        return [defaultRow] + caps.permissionModes.map {
            ComposerOptionRow(value: $0.name, title: $0.title, subtitle: $0.hint)
        }
    }

    /// No resting background — flat like the other controls, with the
    /// grey coming only from the shared hover treatment. A non-default
    /// mode is signalled by the blue text alone.
    private var modeChip: some View {
        Button {
            showingModePopover = true
        } label: {
            Text(selectedModeTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(options.permissionMode == nil
                                 ? SipDesign.textSecondary : SipDesign.blue)
                .padding(.vertical, 3)
                .padding(.horizontal, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingModePopover, arrowEdge: .bottom) {
            ComposerOptionList(rows: modeRows,
                               selected: options.permissionMode) { value in
                options.permissionMode = value
                showingModePopover = false
            }
        }
    }

    /// The mode chip's Kimi stand-in: the same slot, same type size,
    /// but a readout. Secondary colour like an unset chip — nothing has
    /// been overridden here, because nothing can be.
    private var autoApproveChip: some View {
        Text(KimiCapabilities.autoApproveTitle)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(SipDesign.textSecondary)
            .padding(.vertical, 3)
            .padding(.horizontal, 5)
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
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(SipDesign.textSecondary)
            Text(info.time.formatted(
                .dateTime.month(.abbreviated).day().hour().minute()))
                .font(.system(size: 11))
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(scheduleDraft.enabled
                                     ? SipDesign.blue : SipDesign.textSecondary)
                if scheduleDraft.enabled {
                    Text(scheduleDraft.summary)
                        .font(.system(size: 11))
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
                    .font(.system(size: 11))
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
                    .font(.system(size: 12))
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
        guard let cron = scheduleDraft.cronExpression, !cron.isEmpty else {
            scheduleError = String(localized: "That isn't a valid 5-field cron expression (minute hour day month weekday).",
                                   comment: "Schedule validation: bad cron")
            showingSchedulePopover = true
            return
        }
        let request = ScheduledTaskCreator.Request(
            rawName: scheduleDraft.name,
            description: scheduleDraft.taskDescription,
            cron: cron,
            prompt: prompt,
            cwd: folder,
            mode: effectiveScheduleMode,
            model: options.model,
            effort: options.effort,
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
                onScheduleCreated()
                let created = success.name
                scheduleNotice = String(
                    localized: "Scheduled task “\(created)” created — \(scheduleDraftSummaryAfterCreate(cron))",
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

    /// Human summary for the success notice, computed from the cron we
    /// just submitted (the draft has already been reset by then).
    private func scheduleDraftSummaryAfterCreate(_ cron: String) -> String {
        ScheduleDraft.describe(cron: cron)
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
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 22, height: 18)
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

    /// Claude Code reads files itself, so attaching = referencing the
    /// paths in the prompt text.
    private func addFiles() {
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
                // read from the user's own config.toml — the codex
                // counterpart of claude's observed-default subtitle,
                // and named the same way its own row would be.
                subtitle: codexCaps.defaultModel.map { slug in
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
        let others = caps.modelAliases.flatMap { alias in
            caps.otherModels.filter {
                $0.family == ClaudeModelDisplay.parts(of: alias).family
            }
        }
        if !others.isEmpty {
            rows.append(.header(String(localized: "Other models",
                                       comment: "Model menu section header: previous model versions the CLI still offers")))
            rows += others.map {
                ComposerOptionRow(value: $0.fullId,
                                  title: ClaudeModelDisplay.name(for: $0.fullId),
                                  subtitle: nil)
            }
        }
        return rows
    }

    /// The Default row's subtitle and the chip's resting title for
    /// claude: the configured default, read the way the codex and kimi
    /// rows read theirs, else the observed one.
    private var claudeDefaultName: String? {
        if let configured = configuredDefault, !configured.isEmpty {
            return rememberedName(forAlias: configured)
        }
        return config.agentModelFullId(forAlias: "")
            .map { ClaudeModelDisplay.name(for: $0) }
    }

    private func refreshConfiguredDefault() {
        guard !isCodex, !isKimi else { return }
        let found = ClaudeModelCatalog.configuredDefaultModel(cwd: folder)
        if found != configuredDefault { configuredDefault = found }
    }

    // MARK: Fast mode

    /// Whether the model in force can take the fast switch.
    ///
    /// Claude's fast mode is Opus-only — measured: another model
    /// reports `model_not_allowed`, and claude's own toggle says
    /// "Switching to other models turns off fast mode". A family this
    /// cannot read (an alias with no family word, a Default whose
    /// resolution has never been observed) is allowed, and claude then
    /// reports the state itself. Codex offers it only where the model's
    /// catalog entry advertises a service tier; kimi never.
    private func fastModeSupported(forModel value: String?) -> Bool {
        if isKimi { return false }
        if isCodex { return codexCaps.fastTier(forModel: value) != nil }
        let effective: String? = {
            if let value, !value.isEmpty { return value }
            if let configured = configuredDefault, !configured.isEmpty {
                return configured
            }
            return config.agentModelFullId(forAlias: "")
        }()
        guard let effective,
              let family = ClaudeModelDisplay.parts(of: effective).family
        else { return true }
        return family == "opus"
    }

    private var fastModeTitle: String {
        String(localized: "Fast mode",
               comment: "Model menu switch: the agent's faster inference mode")
    }

    private func fastModeSubtitle(supported: Bool) -> String? {
        guard supported else {
            return String(localized: "Not offered for this model",
                          comment: "Model menu switch subtitle: the selected model has no fast mode")
        }
        if isCodex, let tier = codexCaps.fastTier(forModel: options.model) {
            // Codex's own words for its tier ("Fast · 1.5x speed,
            // increased usage") — tool-derived text, never a literal.
            return tier.description.isEmpty
                ? tier.name
                : tier.name + " · " + tier.description
        }
        return String(localized: "Applies to Opus models",
                      comment: "Model menu switch subtitle: claude's fast mode is Opus-only")
    }

    /// What the chip's hover says about fast mode: the outcome claude
    /// reported when there is one, else the intent. Nothing for kimi,
    /// and nothing at all while the switch is off and no turn has
    /// reported a state.
    private var fastModeHint: String? {
        guard !isKimi, options.fastMode || fastModeState != nil else { return nil }
        switch fastModeState {
        case "on":
            return String(localized: "Fast mode is on",
                          comment: "Model chip hover: claude reported fast mode active")
        case "cooldown":
            return String(localized: "Fast mode is cooling down after a rate limit",
                          comment: "Model chip hover: claude reported fast mode paused after a rate limit")
        case "off":
            return String(localized: "Fast mode is off",
                          comment: "Model chip hover: claude reported fast mode inactive")
        default:
            return options.fastMode
                ? String(localized: "Fast mode requested",
                         comment: "Model chip hover: the switch is on and the agent has not yet reported a state")
                : nil
        }
    }

    /// The switch under the model rows. Claude and codex only; disabled
    /// with the reason as its subtitle for a model that does not offer
    /// it, and cleared when such a model is picked (see the picker).
    @ViewBuilder
    private var fastModeFooter: some View {
        if !isKimi {
            let supported = fastModeSupported(forModel: options.model)
            Divider().padding(.vertical, 4)
            Toggle(isOn: Binding(
                get: { options.fastMode && supported },
                set: { options.fastMode = $0 }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(fastModeTitle)
                        .font(.system(size: 13))
                        .foregroundColor(SipDesign.textPrimary)
                    if let subtitle = fastModeSubtitle(supported: supported) {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(SipDesign.textSecondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!supported)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
    }

    /// Alias row/chip title carrying the version the alias resolves to
    /// here ("opus" → "Opus 5") — observed from system.init events and
    /// from what Claude Code already recorded on this machine
    /// (`ClaudeModelCatalog`), never hand-maintained. Bare alias name
    /// only when nothing on this machine names that family.
    private func rememberedName(forAlias alias: String) -> String {
        config.rememberedModelName(forAlias: alias)
    }

    /// Chip label. The full id recorded by the session wins — it carries
    /// the version ("Opus 5") the bare picker alias can't ("Opus").
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
            if let fallback = codexCaps.defaultModel, !fallback.isEmpty {
                return codexCaps.models.first { $0.slug == fallback }?
                    .displayName ?? fallback
            }
            return String(localized: "Model",
                          comment: "Model menu label when no override is set")
        }
        if let full = options.modelFullId, !full.isEmpty {
            return ClaudeModelDisplay.name(for: full)
        }
        if let picked = options.model, !picked.isEmpty {
            return rememberedName(forAlias: picked)
        }
        // No override: name what a Default send runs as — claude's own
        // configured default, else what such a send last resolved to.
        if let name = claudeDefaultName, !name.isEmpty {
            return name
        }
        return String(localized: "Model",
                      comment: "Model menu label when no override is set")
    }

    /// The exact recorded id on hover — the display name is derived,
    /// the id is the ground truth — and, when the fast switch is in
    /// play, what became of it.
    private var modelHelp: String {
        let base = options.modelFullId
            ?? options.model
            ?? String(localized: "Model",
                      comment: "Model menu label when no override is set")
        guard let fast = fastModeHint else { return base }
        return base + " · " + fast
    }

    private var modelButton: some View {
        Button {
            showingModelPopover = true
        } label: {
            trailingMenuLabel(modelChipTitle,
                              icon: options.fastMode ? "bolt.fill" : nil)
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
                // Codex's AND kimi's levels are per-model, so a model
                // change can strand an effort the new model does not
                // accept — picking `gpt-5.5` while `ultra` was selected
                // would send `-c model_reasoning_effort=ultra` for a
                // model whose catalog stops at `xhigh`, and picking a
                // kimi model that publishes no levels would leave a
                // KIMI_MODEL_THINKING_EFFORT the picker no longer
                // shows. The picker stops OFFERING it at that point, so
                // leaving it set means sending a value the user can no
                // longer even see.
                //
                // Claude is excluded on purpose: its list does not vary
                // by model, so an empty one means "catalog still
                // loading", and clearing on that would drop a choice
                // the user made.
                if isCodex || isKimi, let effort = updated.effort, !effort.isEmpty,
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
            // Default row names the model. The other two publish no such
            // value, and inventing one would be a guess about someone
            // else's default.
            subtitle: isKimi
                ? kimiCaps.defaultEffort(forModel: options.model)
                    .map(Self.effortDisplayName)
                : nil)]
        // Codex's levels are PER MODEL — its catalog says `gpt-5.6-terra`
        // accepts `ultra` where `gpt-5.5` stops at `xhigh` — so the list
        // follows the model this composer would actually send with.
        // Kimi's are not: its override bypasses the per-model support
        // list and clamps instead of erroring, so one union is correct
        // there (see `KimiCapabilities.effortLevels`).
        // Every list arrives already ordered fast → deep.
        + effortLevels.map {
            ComposerOptionRow(value: $0, title: Self.effortDisplayName($0), subtitle: nil)
        }
    }

    /// This agent's effort levels, fast → deep.
    private var effortLevels: [String] { effortLevels(forModel: options.model) }

    private func effortLevels(forModel model: String?) -> [String] {
        if isKimi { return kimiCaps.effortLevels(forModel: model) }
        if isCodex { return codexCaps.effortLevels(forModel: model) }
        return caps.effortLevels
    }

    /// Kimi publishes thinking levels PER MODEL, and some of its models
    /// publish none — so for kimi alone an empty list is a real answer
    /// ("this model has no levels"), and a picker offering nothing but
    /// "Default" is a dead control. Kimi's own UI shows the levels only
    /// "when available for the selected model"; this matches it.
    ///
    /// Deliberately not generalised to the other two: their lists are
    /// empty only while a catalog is still loading, where hiding the
    /// chip would be a flicker rather than an answer.
    private var showsEffortChip: Bool {
        !isKimi || !effortLevels.isEmpty
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
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(SipDesign.textSecondary)
            if let text = text {
                Text(text)
                    .font(.system(size: 11))
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
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(SipDesign.textSecondary)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
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
    @ViewBuilder var content: Content
    @State private var hovered = false

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered && highlight ? Color.gray.opacity(0.2) : Color.clear)
            )
            .overlay(alignment: Alignment(horizontal: hintAlignment,
                                          vertical: .top)) {
                if hovered, let hint = hint {
                    Text(hint)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(SipDesign.textPrimary)
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
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovering in hovered = hovering }
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
                        .font(.system(size: 11, weight: .semibold))
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
                        .font(.system(size: 13))
                        .foregroundColor(SipDesign.textPrimary)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(SipDesign.textSecondary)
                    }
                }
                Spacer(minLength: 12)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
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
                .font(.system(size: 9))
            Text(verbatim: timeStr)
                .font(.system(size: 11))
                // Fixed-width digits: without this the whole control
                // strip shuffles sideways every single second.
                .monospacedDigit()
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
            .font(.system(size: 11))
            // One constant colour regardless of occupancy — this
            // states a fact, it does not warn.
            .foregroundColor(.orange)
            .monospacedDigit()
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.font = NSFont.systemFont(ofSize: 14)
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
        if tv.string != text {
            tv.string = text
            context.coordinator.reportHeight(of: tv)
        }
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
        func reportHeight(of tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height
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

    /// The 5-field cron for the current selection; nil for an invalid
    /// custom expression.
    var cronExpression: String? { timing.cronExpression }

    /// Short human summary ("every day at 9:00 AM") for the banner and
    /// the armed schedule chip.
    var summary: String { timing.summary }

    /// Name shown in the armed banner before creation.
    var displayName: String {
        let slug = ScheduledTaskCreator.slugify(name)
        return slug.isEmpty
            ? String(localized: "unnamed", comment: "Placeholder task name in the armed banner")
            : slug
    }

    /// Human rendering of a cron the composer just submitted (used for
    /// the success notice, after the draft has been reset). Delegates to
    /// the same parser the scheduler fires on, so the confirmation can
    /// never describe a different schedule from the one that will run.
    static func describe(cron: String) -> String {
        CronSchedule.parse(cron)?.localizedDescriptionText ?? cron
    }
}

// MARK: - Schedule popover

/// Toggle + timing fields for the composer's armed-schedule mode. The
/// task prompt is typed in the composer's input box, and folder / mode
/// / model / effort come from the control strip — this popover only
/// owns the on/off switch, the name, and the timing.
private struct SchedulePopover: View {
    @Binding var schedule: ScheduleDraft
    @Binding var errorText: String?
    /// Shown in the caption so it's clear which folder/mode the task
    /// will inherit from the strip. The FULL tilde path — a scheduled
    /// task runs unattended, so the folder has to be unambiguous at the
    /// moment of creation, not merely recognizable.
    let folderPath: String
    let modeTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $schedule.enabled.animation(.easeInOut(duration: 0.15))) {
                Text("Run on a schedule",
                     comment: "Schedule popover toggle label")
                    .font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if schedule.enabled {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(
                        String(localized: "Task name (e.g. daily-review)",
                               comment: "Schedule popover name field placeholder"),
                        text: $schedule.name
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                    TextField(
                        String(localized: "Description (optional)",
                               comment: "Schedule popover description field placeholder"),
                        text: $schedule.taskDescription
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                    // The toggle above already IS "no schedule", so the
                    // frequency list doesn't repeat the option; the hint
                    // is redundant next to the caption block below.
                    ScheduleTimingEditor(timing: $schedule.timing,
                                         offersManual: false,
                                         showsHint: false)

                    if let errorText = errorText {
                        Text(errorText)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Type the task prompt in the input box, then press send to create.",
                             comment: "Schedule popover caption — where the prompt comes from")
                        Text(String(localized: "Runs in \(folderPath) · \(modeTitle) mode — from the bar below.",
                                    comment: "Schedule popover caption — settings inherited from the control strip"))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .help(folderPath)
                    }
                    .font(.system(size: 11))
                    .foregroundColor(SipDesign.textHint)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
