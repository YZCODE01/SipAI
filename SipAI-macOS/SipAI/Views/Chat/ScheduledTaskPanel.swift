// ScheduledTaskPanel.swift
// The key-information header shown above a scheduled task's transcript.
//
// Collapsed it is one line: what the task is, when it next runs, and how
// the last run went. Expanded it shows every setting the unattended run
// will use, and Edit makes them all revisable.
//
// A saved edit applies to every UPCOMING run and to no run already in
// flight. That falls out of the design rather than being enforced: the
// scheduler re-reads each definition from disk on every tick, so the
// next fire always picks up the current file, while a run already
// executing is a subprocess that was handed its prompt at spawn time.
//
// Editing writes the whole definition back through
// `ScheduledTaskDefinition.write`, which preserves frontmatter keys this
// app doesn't own — Claude Desktop writes into the same directory and
// must not lose its fields because the description was changed here.

import AppKit
import SwiftUI

struct ScheduledTaskPanel: View {
    let task: ScheduledAgentTask

    /// How the panel is being shown.
    ///
    /// `.banner` is the collapsible strip above a transcript. `.page` is
    /// the whole centre pane, what the task's row opens — with or
    /// without runs: there is no transcript to caption and nothing to
    /// send, so the settings ARE the page and the form is always open.
    enum Presentation { case banner, page }
    var presentation: Presentation = .banner

    /// True when the panel is the topmost thing in the window and must
    /// therefore keep clear of the traffic lights.
    ///
    /// The window is `.hiddenTitleBar`, so the buttons float over the
    /// content at roughly x 13–68, y 13–27. BOTH presentations step
    /// around them VERTICALLY — the row starts below y 27 and keeps the
    /// card's own leading gutter. The clearance is padding INSIDE the
    /// header, never a spacer above the card: a spacer would paint
    /// window background over the card, where padding keeps the card's
    /// background running to the window edge with the buttons simply
    /// floating on it, as on every other hidden-title-bar surface.
    var atWindowTop: Bool = false

    /// Vertical room that clears the window buttons (they end at y 27).
    private static let trafficLightClearance: CGFloat = 30

    /// True only when the traffic lights actually sit over THIS panel.
    ///
    /// They live at window x 13–68, and the panel is inside the centre
    /// pane — which starts after the sidebar, never narrower than its
    /// 190-pt minimum. So with the sidebar open the buttons float over
    /// the SIDEBAR and the card needs no clearance at all. Reserving it
    /// unconditionally would put a visible band of empty card above
    /// the title in the common case; the clearance is only real chrome
    /// when the sidebar is hidden and the pane runs to x 0.
    private var needsTrafficLightClearance: Bool {
        atWindowTop && !appState.leftSidebarVisible
    }

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var agents: AgentManager
    @EnvironmentObject var config: ConfigManager
    @EnvironmentObject var scheduler: ScheduledTaskScheduler
    /// Same shared catalog the composer's pickers read, so a mode or
    /// effort level Anthropic adds appears in both places at once.
    @ObservedObject private var capabilities = ClaudeCapabilities.shared
    @ObservedObject private var codexCatalog = CodexCatalog.shared
    @ObservedObject private var kimiCatalog = KimiCatalog.shared
    @ObservedObject private var skillCatalog = SkillCatalog.shared
    /// The installed CLIs' versions decide which modes the Mode picker
    /// offers, as they do the composer's.
    @ObservedObject private var cliMonitor = AgentCLIUpdateMonitor.shared
    @State private var showingSkillPicker = false

    /// The font tier. The panel sits outside the transcript's re-scope —
    /// above it as a banner, or as the whole page — so every size here
    /// is the design-size convention: `.sipFont` for type, and
    /// `SipFont.ratio` for the frames and the HORIZONTAL gaps around it,
    /// so a larger tier grows the whole card rather than cramming bigger
    /// text into the Default tier's spacing. The traffic-light clearance
    /// is the one fixed measure: the window's buttons do not scale.
    @Environment(\.sipFontScale) private var fontScale
    @Environment(\.sipLineSpacingFactor) private var lineSpacingFactor
    private var ratio: CGFloat { SipFont.ratio(fontScale) }

    /// The space between two wrapped lines of the card's text — the
    /// tier's own line spacing over its 12 pt body, set once on the whole
    /// card, the prompt box included. Without it the card kept the
    /// system's tight leading beside a transcript and a composer that
    /// both spread their lines with the tier.
    private var bodyLineSpacing: CGFloat {
        SipFont.lineSpacing(12, fontScale: fontScale, lineSpacingFactor: lineSpacingFactor)
    }

    /// Multiplier for the card's VERTICAL gaps: its body's line pitch at
    /// this tier over Default's (`SipFont.gapScale`), exactly 1 at
    /// Default. The line spacing grows faster than the type, so gaps
    /// scaled by the type alone would leave a wrapped line farther from
    /// its own row than the next row is.
    private var rhythm: CGFloat {
        SipFont.gapScale(12, fontScale: fontScale, lineSpacingFactor: lineSpacingFactor)
    }

    /// Which CLI this task fires under — the frontmatter's `agent`,
    /// which `ScheduledTaskScheduler.fire` now honours.
    private var isCodexTask: Bool { taskAgentKey == "codex" }
    /// A kimi task's modes are kimi's own — Default, Ask When Needed,
    /// Never Ask, Plan — and a kimi with no front end runs headless
    /// whatever is picked, so there the Mode picker is a readout
    /// (`modeIsReadout`). Kimi takes its effort through the environment,
    /// so that picker stays either way. See `AgentLaunchOptions.kimiFlags`.
    private var isKimiTask: Bool { taskAgentKey == "kimi" }
    /// Named, never "not codex and not kimi": a task of an agent this app
    /// has no code for would otherwise be offered claude's efforts and
    /// fast mode.
    private var isClaudeTask: Bool { taskAgentKey == "claude_code" }

    /// The task's agent, as the registry keys it: its file's, or — for a
    /// task whose file is gone — its runs' (`ScheduledAgentTask.agent`).
    private var taskAgentKey: String { task.definition?.agent ?? task.agent }

    /// The task's agent as the user labels it — every sentence names it so.
    private var taskAgentName: String {
        config.agentLabel(for: taskAgentKey,
                          defaultName: AgentManager.registry.first { $0.key == taskAgentKey }?.name
                              ?? "Claude Code")
    }

    /// Whether the panel is open. Global rather than per-task: it is a
    /// preference about how much chrome the user wants above their
    /// transcripts, not a fact about one task.
    @AppStorage("scheduledTaskPanelExpanded") private var expanded: Bool = false

    @State private var editing = false
    /// Whether the Schedule field is showing its pickers rather than its
    /// one-line summary. Reset by `seedDraft()` (open / switch / cancel)
    /// and by `save()`, so the form always opens on the summary.
    @State private var editingSchedule = false
    /// The definition being edited. Seeded on appear and whenever the
    /// panel switches to a different task — never from an incoming
    /// `task` refresh mid-edit, which would discard what is being typed
    /// every time the sidebar rescans.
    @State private var draft = ScheduledTaskDefinition(name: "", description: "")
    /// Structured form of `draft.scheduleExpression` — what the pickers
    /// bind to. Seeded with the draft; see `scheduleTimingBinding`.
    @State private var timing = ScheduleTiming()
    @State private var saveError: String? = nil
    /// Renaming the task from its own title, on the page. The name is one
    /// value — this, the banner editor's Name field and the sidebar's
    /// ⋮ → Rename all write the SKILL.md `description:`, so all three
    /// stay in step by construction.
    @State private var editingName = false
    @State private var nameDraft = ""
    @FocusState private var nameFieldFocused: Bool
    /// Re-read once a minute so "next run" and "in 3 minutes" stay true
    /// while the panel sits open.
    @State private var now = Date()
    /// What a claude task with no model runs as: claude's configured
    /// default for the task's folder (`ClaudeModelCatalog
    /// .configuredDefaultModel`). Cached per task and per folder, the
    /// composer's way — the effort picker reads it on every body pass,
    /// and the read is a few small files.
    @State private var claudeConfiguredDefault: String? = nil

    /// One process-wide timer rather than an inline publisher: an
    /// inline `Timer.publish(…)` inside `onReceive` is rebuilt on every
    /// body pass, so each render tears down a timer and starts another.
    private static let minuteTick = Timer
        .publish(every: 60, on: .main, in: .common)
        .autoconnect()

    private var definition: ScheduledTaskDefinition? { task.definition }
    private var runState: ScheduledTaskRunState? { scheduler.states[task.name] }
    private var isRunning: Bool { scheduler.isRunning(task.name) }

    var body: some View {
        Group {
            switch presentation {
            case .banner:
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if expanded {
                        Divider().opacity(0.5)
                        if editing {
                            editor
                        } else {
                            details
                        }
                    }
                }
                .background(SipDesign.cardBg)
                .overlay(alignment: .bottom) { Divider().opacity(0.6) }
            case .page:
                pageBody
            }
        }
        // System controls — the pickers, checkboxes and text fields —
        // take no arbitrary point size, so beside the scaled labels they
        // STEP, once, here (`SipFont.controlSize`).
        .controlSize(SipFont.controlSize(fontScale))
        // Every wrapped line on the card — the prompt, a long folder, a
        // status or an error, and the prompt box itself (a TextEditor
        // takes it too) — spaced the way the tier spaces every other
        // paragraph in the window.
        .lineSpacing(bodyLineSpacing)
        .onAppear {
            seedDraft()
            refreshClaudeConfiguredDefault()
            refreshSpeedSources()
            // What the Mode picker's rows rest on — each read a no-op once
            // it has landed for the installed binary.
            ScheduledTaskScheduler.readModeGates()
            // The page exists to be edited; opening it in a read-only
            // view behind an Edit button would be a click for nothing.
            if presentation == .page { editing = definition != nil }
        }
        .onChange(of: task.name) { _, _ in
            // A different task took over the panel: abandon any edit
            // rather than carrying one task's text into another's file.
            editing = presentation == .page && definition != nil
            editingName = false
            saveError = nil
            seedDraft()
            refreshClaudeConfiguredDefault()
            refreshSpeedSources()
        }
        .onChange(of: draft.workingDirectory) { _, _ in
            refreshClaudeConfiguredDefault()
            refreshSpeedSources()
        }
        .onChange(of: definition) { previous, current in
            // The same task's file changed underneath us — a save landing,
            // the scan finishing, or a hand edit. Adopt it, but ONLY when
            // the form still matches what it was seeded from: a reseed
            // over half-typed changes would discard the user's edits.
            guard let current = current else { return }
            if previous.map({ writesSameFile(draft, $0) }) ?? true {
                draft = current
                timing = ScheduleTiming(schedule: current.scheduleExpression)
            } else if !formHasNameField {
                // Kept for its unsaved edits, a form with no Name field
                // still takes the file's name. Save writes the whole
                // definition, so a name the form does not show — the old
                // one, after a rename from the sidebar's ⋮ menu — would go
                // back over the new one with nothing on screen saying so.
                draft.description = current.description
            }
        }
        .onReceive(Self.minuteTick) { now = $0 }
    }

    // MARK: - Page presentation

    private var pageBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader
            Divider().opacity(0.6)
            ScrollView {
                Group {
                    if definition == nil {
                        orphanNotice
                            .padding(.horizontal, 20 * ratio)
                            .padding(.top, 16 * rhythm)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            // A failed Run now is the only feedback this
                            // page can give about why nothing happened;
                            // without it the run just silently isn't there.
                            if let error = runState?.lastError,
                               runState?.lastOutcome == "error" {
                                Text(verbatim: error)
                                    .sipFont(12)
                                    .foregroundColor(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 20 * ratio)
                                    .padding(.top, 14 * rhythm)
                            }
                            editor
                        }
                    }
                }
                .frame(maxWidth: 760 * ratio, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10 * ratio) {
            Image(systemName: "timer")
                .sipFont(15)
                .foregroundColor(isRunning ? SipDesign.blue : SipDesign.textSecondary)
            VStack(alignment: .leading, spacing: 2 * rhythm) {
                if editingName {
                    nameField(fontSize: 17)
                } else {
                    // The pencil sits beside the name it edits, not with
                    // the actions at the far end: it renames the task and
                    // does nothing else, and over there it read as an edit
                    // button for the whole page. The name gives way to it
                    // on a narrow pane.
                    HStack(spacing: 4 * ratio) {
                        Text(verbatim: task.description)
                            .sipFont(17, weight: .semibold)
                            .foregroundColor(SipDesign.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if definition != nil {
                            renameButton
                                .fixedSize()
                                // Centred on the name, and kept out of the
                                // row's baseline: the pencil's own baseline
                                // sits above the name's, and as the stack's
                                // first it lifted Run now 2 px off the
                                // title's line (measured).
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                        }
                    }
                }
                Text(verbatim: statusLine)
                    .sipFont(12)
                    .foregroundColor(statusIsWarning ? .orange : SipDesign.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8 * ratio)
            headerActions
        }
        .padding(.horizontal, 20 * ratio)
        // 34 clears the window's buttons, which do not scale.
        .padding(.top, needsTrafficLightClearance ? 34 : 4 * rhythm)
        .padding(.bottom, 12 * rhythm)
        .frame(maxWidth: 800 * ratio, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var orphanNotice: some View {
        Text("This task's definition was deleted. Its past runs are still listed here.",
             comment: "Scheduled-task panel body for an orphaned task")
            .sipFont(12)
            .foregroundColor(SipDesign.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8 * ratio) {
            if editingName {
                HStack(spacing: 7 * ratio) {
                    // Matches the chevron + icon columns so the field
                    // opens exactly where the title was.
                    Color.clear.frame(width: 9 * ratio, height: 1)
                    Image(systemName: "timer")
                        .sipFont(12)
                        .foregroundColor(isRunning ? SipDesign.blue : SipDesign.textSecondary)
                    nameField(fontSize: 13)
                }
            } else {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7 * ratio) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .sipFont(9, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 9 * ratio)
                    Image(systemName: "timer")
                        .sipFont(12)
                        .foregroundColor(isRunning ? SipDesign.blue : SipDesign.textSecondary)
                    VStack(alignment: .leading, spacing: 1 * rhythm) {
                        Text(verbatim: task.description)
                            .sipFont(13, weight: .semibold)
                            .foregroundColor(SipDesign.textPrimary)
                            .lineLimit(1)
                        Text(verbatim: statusLine)
                            .sipFont(11)
                            .foregroundColor(statusIsWarning
                                             ? .orange : SipDesign.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded
                ? String(localized: "Collapse task details",
                         comment: "Accessibility hint for the scheduled-task panel chevron")
                : String(localized: "Expand task details",
                         comment: "Accessibility hint for the scheduled-task panel chevron"))
            }

            headerActions
        }
        // Same 14-pt gutter the details and the editor use, so the
        // title sits over its own card's content rather than over the
        // transcript's text column.
        .padding(.horizontal, 14 * ratio)
        .padding(.top, needsTrafficLightClearance ? Self.trafficLightClearance : 8 * rhythm)
        .padding(.bottom, 8 * rhythm)
    }

    /// The page's pencil, beside the task's name — the page's one way to
    /// rename, so its form has no Name field (`formHasNameField`). The
    /// banner is the other way round: collapsed, the card is a status
    /// line with one action on it; expanded, its Edit button opens a form
    /// whose first field IS Name, and a second, differently shaped way to
    /// change the same value on the same card is just a thing to explain.
    /// Only for a task with a definition — an orphan has no file left to
    /// write, so a rename would be a no-op.
    private var renameButton: some View {
        Button {
            beginNameEdit()
        } label: {
            Image(systemName: "pencil")
                .sipFont(12, weight: .medium)
        }
        .buttonStyle(PanelActionButtonStyle())
        .help(String(localized: "Rename this task",
                     comment: "Tooltip for the rename button in the scheduled-task panel"))
        .accessibilityLabel(String(localized: "Rename this task",
                                   comment: "Accessibility label for the rename button in the scheduled-task panel"))
    }

    /// Run now, plus Pause/Resume on the page, where there is room for
    /// it. Nothing here for an orphan — there is no file left to act on.
    @ViewBuilder
    private var headerActions: some View {
        if isRunning {
            ProgressView().controlSize(.small).scaleEffect(0.6 * ratio)
                .frame(width: 18 * ratio)
        } else if let def = definition {
            HStack(spacing: 2 * ratio) {
                if presentation == .page {
                    Button {
                        togglePaused(def)
                    } label: {
                        Text(def.enabled
                             ? String(localized: "Pause",
                                      comment: "Scheduled-task panel button: stop firing")
                             : String(localized: "Resume",
                                      comment: "Scheduled-task panel button: start firing"))
                            .sipFont(12, weight: .medium)
                    }
                    .buttonStyle(PanelActionButtonStyle())
                }
                Button {
                    // On the page, the run it starts takes the page's
                    // place; above a run, the pane stays on that run.
                    scheduler.runNow(def, fromTaskPage: presentation == .page)
                } label: {
                    Text("Run now", comment: "Scheduled-task panel button")
                        .sipFont(presentation == .page ? 12 : 11,
                                 weight: .medium)
                }
                .buttonStyle(PanelActionButtonStyle())
                .help(String(localized: "Run this task once, right now. Does not affect the schedule.",
                             comment: "Tooltip for the scheduled-task Run now button"))
                // Run now runs the SAVED task, so it steps aside while the
                // form on screen holds unsaved edits: pressed then, it
                // would run the old version, and on the page the switch
                // to the run would drop the edits. Hidden in place, not
                // removed, so the title and Pause do not shift on the
                // first keystroke.
                .opacity(hasUnsavedEditsOnScreen ? 0 : 1)
                .allowsHitTesting(!hasUnsavedEditsOnScreen)
                .disabled(hasUnsavedEditsOnScreen)
                .accessibilityHidden(hasUnsavedEditsOnScreen)
            }
        }
    }

    /// One line under the title: paused / no schedule / next run, and
    /// the last outcome when there is something worth saying about it.
    private var statusLine: String {
        guard let def = definition else {
            return String(localized: "Definition deleted — past runs only",
                          comment: "Scheduled-task status: the SKILL.md is gone")
        }
        if isRunning {
            return String(localized: "Running now",
                          comment: "Scheduled-task status: a run is in flight")
        }
        var parts: [String] = []
        // Set when the first part already says the one run was missed,
        // so the generic "missed a run" below does not say it twice.
        var namedTheMiss = false
        if !def.enabled {
            parts.append(String(localized: "Paused",
                                comment: "Scheduled-task status: firing is off"))
        } else if def.hasUnparseableSchedule {
            parts.append(String(localized: "Unrecognized schedule “\(def.scheduleExpression)”",
                                comment: "Scheduled-task status: cron could not be parsed"))
        } else if let schedule = def.schedule {
            // A one-time task has no "next" once its moment has passed:
            // it says how that moment went, read off the same record the
            // scheduler writes (`ScheduledTaskScheduler.oneTimeStatus`).
            if case .once(let moment) = schedule,
               let passed = oneTimeStatusText(moment, missed: &namedTheMiss) {
                parts.append(passed)
            } else if let next = schedule.nextFireDate(after: now) {
                parts.append(String(localized: "Next run \(Self.relative(next, from: now))",
                                    comment: "Scheduled-task status: when it fires next"))
            } else {
                parts.append(schedule.localizedDescriptionText)
            }
        } else {
            parts.append(String(localized: "No schedule — runs only when you press Run now",
                                comment: "Scheduled-task status: task has no cron expression"))
        }
        if let state = runState {
            if let missed = state.lastMissedSlot {
                // Passed over while the previous run was still going is
                // not "missed" in the sense the Missed runs row describes
                // — catch-up never makes it up — so it says why.
                if state.lastMissedWhileRunning == true {
                    parts.append(String(localized: "skipped a run \(Self.relative(missed, from: now)) — the previous run was still going",
                                        comment: "Scheduled-task status: a slot came while the task's previous run was still going, so it was passed over rather than run late; placeholder is relative (“20 minutes ago”)"))
                } else if !namedTheMiss {
                    parts.append(String(localized: "missed a run \(Self.relative(missed, from: now))",
                                        comment: "Scheduled-task status: a slot passed without running"))
                }
            } else if state.lastOutcome == "error" {
                parts.append(String(localized: "last run failed",
                                    comment: "Scheduled-task status: previous run errored"))
            }
        }
        return parts.joined(separator: " · ")
    }

    /// The status of a one-time task whose moment has come — nil while it
    /// is still ahead, where the ordinary "Next run in …" applies.
    private func oneTimeStatusText(_ moment: Date, missed: inout Bool) -> String? {
        switch ScheduledTaskScheduler.oneTimeStatus(at: moment, state: runState, now: now) {
        case .upcoming:
            return nil
        case .due:
            return String(localized: "Due \(Self.relative(moment, from: now))",
                          comment: "Scheduled-task status: a one-time run's moment has passed and it has not started yet; placeholder is relative (“2 minutes ago”)")
        case .ran:
            let ranAt = max(runState?.lastFiredAt ?? moment, moment)
            return String(localized: "Ran once \(Self.relative(ranAt, from: now))",
                          comment: "Scheduled-task status: a one-time task has had its run; placeholder is relative (“2 hours ago”)")
        case .missed:
            missed = true
            return String(localized: "Missed its one run \(Self.relative(moment, from: now))",
                          comment: "Scheduled-task status: a one-time task's moment passed while SipAI was closed, too long ago to catch up; placeholder is relative (“3 days ago”)")
        }
    }

    private var statusIsWarning: Bool {
        guard let def = definition else { return true }
        if def.hasUnparseableSchedule { return true }
        if runState?.lastMissedSlot != nil { return true }
        if runState?.lastOutcome == "error" { return true }
        return !def.enabled
    }

    // MARK: - Read-only details

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 10 * rhythm) {
            if let def = definition {
                // Rows never sit closer than one wrapped line inside a
                // row — a long folder path wraps.
                LazyVGrid(columns: [
                    GridItem(.fixed(96 * ratio), alignment: .topTrailing),
                    GridItem(.flexible(), alignment: .topLeading),
                ], alignment: .leading, spacing: max(6 * rhythm, bodyLineSpacing)) {
                    detailRow(String(localized: "Schedule",
                                     comment: "Scheduled-task detail label"),
                              scheduleText(def))
                    if let next = def.enabled ? def.schedule?.nextFireDate(after: now) : nil {
                        detailRow(String(localized: "Next run",
                                         comment: "Scheduled-task detail label"),
                                  Self.absolute(next))
                    }
                    detailRow(String(localized: "Folder",
                                     comment: "Scheduled-task detail label"),
                              def.workingDirectory?.path
                              ?? String(localized: "Home folder",
                                        comment: "Scheduled-task detail: no cwd recorded"))
                    detailRow(String(localized: "Runs as",
                                     comment: "Scheduled-task detail label: the model, effort and mode each run uses"),
                              runtimeText(def))
                    if !def.skills.isEmpty, !def.chatOnly {
                        detailRow(String(localized: "Skills",
                                         comment: "Scheduled-task detail label: skills each run loads"),
                                  def.skills.joined(separator: ", "))
                    }
                    detailRow(String(localized: "Missed runs",
                                     comment: "Scheduled-task detail label"),
                              def.catchUpMissed
                              ? String(localized: "Run when SipAI next opens",
                                       comment: "Scheduled-task detail: catch-up on")
                              : String(localized: "Skipped",
                                       comment: "Scheduled-task detail: catch-up off"))
                    if let last = lastRunText {
                        detailRow(String(localized: "Last run",
                                         comment: "Scheduled-task detail label"), last)
                    }
                }
                .sipFont(12)

                if let error = runState?.lastError, runState?.lastOutcome == "error" {
                    Text(verbatim: error)
                        .sipFont(11)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Prompt", comment: "Scheduled-task detail section header")
                    .sipFont(11, weight: .semibold)
                    .foregroundColor(SipDesign.textSecondary)
                ScrollView {
                    Text(verbatim: def.prompt)
                        .sipFont(12)
                        .foregroundColor(SipDesign.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                // Tall enough for the same number of lines at any tier.
                .frame(maxHeight: 140 * rhythm)

                HStack(spacing: 2 * ratio) {
                    Button {
                        seedDraft()
                        editing = true
                    } label: {
                        Text("Edit", comment: "Scheduled-task panel button")
                            .sipFont(11, weight: .medium)
                    }
                    .buttonStyle(PanelActionButtonStyle())
                    Button {
                        togglePaused(def)
                    } label: {
                        Text(def.enabled
                             ? String(localized: "Pause",
                                      comment: "Scheduled-task panel button: stop firing")
                             : String(localized: "Resume",
                                      comment: "Scheduled-task panel button: start firing"))
                            .sipFont(11, weight: .medium)
                    }
                    .buttonStyle(PanelActionButtonStyle())
                    Spacer()
                    Text(verbatim: task.name)
                        .sipFont(10)
                        .foregroundColor(SipDesign.textHint)
                        .help(String(localized: "Task folder name — the task's permanent identity",
                                     comment: "Tooltip for the task slug in the panel"))
                }
            } else {
                Text("This task's definition was deleted. Its past runs are still listed here.",
                     comment: "Scheduled-task panel body for an orphaned task")
                    .sipFont(12)
                    .foregroundColor(SipDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14 * ratio)
        .padding(.top, 10 * rhythm)
        .padding(.bottom, 12 * rhythm)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        Group {
            Text(verbatim: label)
                .foregroundColor(SipDesign.textSecondary)
            Text(verbatim: value)
                .foregroundColor(SipDesign.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scheduleText(_ def: ScheduledTaskDefinition) -> String {
        if def.scheduleExpression.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "None",
                          comment: "Scheduled-task detail: no schedule set")
        }
        guard let schedule = def.schedule else {
            return String(localized: "“\(def.scheduleExpression)” — not a valid cron expression",
                          comment: "Scheduled-task detail: unparseable cron")
        }
        // Plain language only, no raw cron alongside — two spellings
        // read as two answers to one question. `localizedDescriptionText`
        // already falls back to the raw expression for shapes it can't
        // phrase faithfully, so nothing is hidden.
        return schedule.localizedDescriptionText
    }

    /// Plain-language rendering of the schedule the FORM is holding —
    /// the draft, not the file, so an unsaved change made through
    /// Change is what the summary describes.
    private var draftScheduleSummary: String {
        let raw = draft.scheduleExpression.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty {
            return String(localized: "No schedule — runs only when you press Run now",
                          comment: "Scheduled-task editor: schedule summary when nothing fires the task")
        }
        guard let schedule = TaskSchedule.parse(raw) else {
            return String(localized: "“\(raw)” — not a valid cron expression",
                          comment: "Scheduled-task editor: schedule summary for an unparseable expression")
        }
        return schedule.localizedDescriptionText
    }

    /// This task's agent's effort levels, fast → deep. Mirrors the
    /// composer's `effortLevels` — the two pickers are the only places a
    /// level is chosen, and they must offer the same set.
    private var taskEffortLevels: [String] {
        if isKimiTask { return kimiCatalog.effortLevels(forModel: draft.model) }
        if isCodexTask {
            // The model a run runs as — the pick, else the model codex's
            // config names in the task's folder — as the composer reads it.
            let slug = (draft.model?.isEmpty == false) ? draft.model
                : codexCatalog.defaultModel(forFolder: Self.runFolder(draft))
            return codexCatalog.effortLevels(forModel: slug)
        }
        guard isClaudeTask else { return [] }
        return capabilities.effortLevels(forModelId: config.resolvedClaudeModelId(
            picked: draft.model, configuredDefault: claudeConfiguredDefault))
    }

    private func refreshClaudeConfiguredDefault() {
        guard isClaudeTask else { return }
        let found = ClaudeModelCatalog.configuredDefaultModel(cwd: draft.workingDirectory)
        if found != claudeConfiguredDefault { claudeConfiguredDefault = found }
    }

    /// The Runs as line: model · effort · mode, the composer's order, each
    /// named as the composer's chips name it — and the speed and Non-stop
    /// where a run gets them. A model or effort left on Default goes
    /// unsaid; the mode is always said.
    private func runtimeText(_ def: ScheduledTaskDefinition) -> String {
        let codex = def.agent == "codex"
        let kimi = def.agent == "kimi"
        let mode = AgentAskingMode.taskMode(agentKey: def.agent, fileMode: def.mode)
        var parts: [String] = []
        if let model = def.model, !model.isEmpty {
            // Frontmatter stores claude's picker ALIAS ("opus"), which
            // carries no version — the version comes from what the alias
            // resolves to, exactly as the composer's model chip names it.
            // Codex's and kimi's ids are literal, named by their catalogs.
            if codex {
                parts.append(codexCatalog.models.first { $0.slug == model }?.displayName ?? model)
            } else if kimi {
                parts.append(kimiCatalog.displayName(forModel: model))
            } else {
                parts.append(config.rememberedModelName(forAlias: model))
            }
        }
        if let effort = def.effort, !effort.isEmpty {
            // Through `AgentEffort.displayName` like every other surface
            // that prints a level — a raw "xhigh" here would sit next
            // to the editor's own "XHigh".
            parts.append(AgentEffort.displayName(effort))
        }
        parts.append(AgentMenus.modeTitle(agentKey: def.agent, mode: mode,
                                          chatOnly: def.chatOnly,
                                          frontEnd: AskingModeGate.frontEnd(agentKey: def.agent)))
        if let speed = runtimeSpeedText(def, codex: codex) {
            parts.append(speed)
        }
        if def.nonStop,
           AgentAskingMode.asksQuestions(agentKey: def.agent, mode: mode, chatOnly: def.chatOnly,
                                         frontEndOffered: AskingModeGate.frontEnd(agentKey: def.agent)
                                            != .unavailable,
                                         kimiDefaultPermission: kimiCatalog.defaultPermissionMode) {
            parts.append(AgentComposer.nonStopTitle)
        }
        return parts.joined(separator: " · ")
    }

    /// The speed a run of this definition gets, for the summary line —
    /// said only when it is faster than standard, since that is what
    /// costs more; standard goes unsaid, like the default model. Codex's
    /// is named only where the model advertises the tier, the checkbox's
    /// own gate: a configured tier on a model the catalog does not list
    /// is codex's to judge, and the checkbox says nothing is offered.
    private func runtimeSpeedText(_ def: ScheduledTaskDefinition, codex: Bool) -> String? {
        if codex {
            let folder = Self.runFolder(def)
            guard let tier = codexCatalog.scheduledServiceTier(pick: def.serviceTier,
                                                               forModel: def.model,
                                                               folder: folder),
                  CodexSpeed.isFaster(tier),
                  let known = codexCatalog.serviceTier(id: tier, forModel: def.model,
                                                       folder: folder)
            else { return nil }
            return known.name
        }
        guard def.fastMode, claudeTaskTakesFastMode(model: def.model) else { return nil }
        guard claudeCreditsBlock != nil else { return ClaudeFastModeWords.title }
        return String(localized: "Fast mode (needs usage credits)",
                      comment: "Scheduled-task summary: the task asks for claude's fast mode, which the account's usage credits cannot pay for at the moment")
    }

    private var lastRunText: String? {
        guard let state = runState, let firedAt = state.lastFiredAt else { return nil }
        let when = Self.absolute(firedAt)
        switch state.lastOutcome {
        case "done":
            return String(localized: "\(when) — succeeded",
                          comment: "Scheduled-task detail: last run outcome")
        case "error":
            return String(localized: "\(when) — failed",
                          comment: "Scheduled-task detail: last run outcome")
        case "running":
            return String(localized: "\(when) — running",
                          comment: "Scheduled-task detail: last run outcome")
        default:
            return when
        }
    }

    // MARK: - Editor

    /// Whether the form edits the task's name. Above a run it does — the
    /// banner has no other way to rename. On the page it does not: the
    /// pencil beside the title renames, and a second control for the same
    /// value right under it is one too many, so the page's form opens on
    /// Schedule.
    private var formHasNameField: Bool { presentation == .banner }

    @ViewBuilder
    private var editor: some View {
        VStack(alignment: .leading, spacing: 10 * rhythm) {
            if formHasNameField {
                field(String(localized: "Name", comment: "Scheduled-task editor field label")) {
                    TextField("", text: $draft.description)
                        .textFieldStyle(.roundedBorder)
                        .sipFont(12)
                }
            }

            field(String(localized: "Schedule", comment: "Scheduled-task editor field label")) {
                // Reads as one plain sentence until you ask to change it,
                // the same shape the Folder row below uses. The chips
                // are a row of choices plus a hint — worth their room
                // while you are setting a time, pure noise when the form
                // was opened to fix a typo in the prompt.
                //
                // Behind Change they are the same chips the composer
                // offers at creation — revising a time must never demand
                // hand-writing cron for a value picked from a menu.
                if editingSchedule {
                    ScheduleTimingEditor(timing: scheduleTimingBinding,
                                         offersManual: true)
                } else {
                    HStack(spacing: 6 * ratio) {
                        Text(verbatim: draftScheduleSummary)
                            .sipFont(12)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4 * ratio)
                        // The panel's own action style, as Edit and Run
                        // now use: `.borderless` gives no hover at all on
                        // macOS, so this read as a static label.
                        Button {
                            editingSchedule = true
                        } label: {
                            Text("Change",
                                 comment: "Scheduled-task editor: reveal the schedule pickers")
                                .sipFont(11, weight: .medium)
                        }
                        .buttonStyle(PanelActionButtonStyle())
                    }
                }
            }

            field(String(localized: "Folder", comment: "Scheduled-task editor field label")) {
                HStack(spacing: 6 * ratio) {
                    Text(verbatim: draft.workingDirectory?.path
                         ?? String(localized: "Home folder",
                                   comment: "Scheduled-task editor: no cwd set"))
                        .sipFont(12)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 4 * ratio)
                    Button {
                        chooseFolder()
                    } label: {
                        Text("Choose…", comment: "Scheduled-task editor folder button")
                            .sipFont(11, weight: .medium)
                    }
                    .buttonStyle(PanelActionButtonStyle())
                }
            }

            field(String(localized: "Runs as", comment: "Scheduled-task editor field label")) {
                VStack(alignment: .leading, spacing: 6 * rhythm) {
                    // The composer's three chips in the composer's order —
                    // model, effort, mode — each listing exactly the
                    // composer's rows (`AgentMenus`), names only: the
                    // explanations stay in the composer's menus. Per agent,
                    // so a codex task is never offered claude's modes, and
                    // claude's aliases never reach a codex command line.
                    HStack(alignment: .top, spacing: 10 * ratio) {
                        pickerColumn(String(localized: "Model",
                                            comment: "Scheduled-task editor: caption over the model picker")) {
                            menuPicker(rows: modelRows, selection: modelBinding)
                        }
                        // Hidden for a model that takes no levels (a kimi
                        // model with no `support_efforts`, claude's Haiku),
                        // exactly as the composer hides its chip — see
                        // `AgentComposer.showsEffortChip`.
                        if isCodexTask || !taskEffortLevels.isEmpty {
                            pickerColumn(String(localized: "Effort",
                                                comment: "Scheduled-task editor: caption over the effort picker")) {
                                menuPicker(rows: AgentMenus.effortRows(levels: taskEffortLevels,
                                                                       defaultSubtitle: nil),
                                           selection: optionalBinding($draft.effort))
                            }
                        }
                        pickerColumn(String(localized: "Mode",
                                            comment: "Scheduled-task editor: caption over the mode picker")) {
                            if modeIsReadout {
                                // A statement where the installed kimi can
                                // run nothing but its headless Never Ask —
                                // the composer's readout, for its reason.
                                Text(verbatim: KimiCapabilities.neverAskTitle)
                                    .foregroundStyle(.secondary)
                                    .help(KimiCapabilities.neverAskHint(
                                        agentName: config.agentLabel(
                                            for: "kimi", defaultName: "Kimi Code")))
                            } else {
                                menuPicker(rows: modeRows, selection: modeBinding)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    speedControl
                    nonStopControl
                }
                .sipFont(12)
            }

            // A Chat only run loads no skills (`ScheduledTaskScheduler.fire`),
            // as a Chat only send from the composer loads none.
            if !draft.chatOnly {
                field(String(localized: "Skills", comment: "Scheduled-task editor field label")) {
                    skillsField
                }
            }

            Toggle(isOn: $draft.catchUpMissed) {
                Text("Run a missed schedule when SipAI next opens",
                     comment: "Scheduled-task editor toggle")
                    .sipFont(12)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $draft.enabled) {
                Text("Active", comment: "Scheduled-task editor toggle: firing enabled")
                    .sipFont(12)
            }
            .toggleStyle(.checkbox)

            field(String(localized: "Prompt", comment: "Scheduled-task editor field label")) {
                TextEditor(text: $draft.prompt)
                    .sipFont(12)
                    // The same number of lines at any tier: the box grows
                    // with the pitch the card's line spacing gives them.
                    .frame(minHeight: 120 * rhythm, maxHeight: 220 * rhythm)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(SipDesign.borderLight, lineWidth: 1)
                    )
            }

            if let saveError = saveError {
                Text(verbatim: saveError)
                    .sipFont(11)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6 * ratio) {
                Button {
                    save()
                } label: {
                    Text("Save", comment: "Scheduled-task editor button")
                        .sipFont(11, weight: .medium)
                }
                .buttonStyle(.borderedProminent)
                // Designed small; steps with the tier like every other
                // system control on the card.
                .controlSize(SipFont.controlSize(fontScale, base: .small))
                .disabled(!canSave || !isDirty)
                Button {
                    // On the page the form is the whole view, so there is
                    // nothing to collapse back to — Cancel restores the
                    // saved values instead of closing.
                    if presentation == .banner { editing = false }
                    saveError = nil
                    seedDraft()
                } label: {
                    Text(presentation == .page
                         ? String(localized: "Revert",
                                  comment: "Scheduled-task editor button: discard unsaved edits")
                         : String(localized: "Cancel",
                                  comment: "Scheduled-task editor button"))
                        .sipFont(11)
                }
                .buttonStyle(PanelActionButtonStyle())
                // Cancel is the ONLY way out of the banner's edit mode,
                // so it can never be disabled there — gating it on
                // `isDirty` would trap anyone who presses Edit and then
                // changes nothing. On the page it is a pure Revert (the
                // form is the whole view), so with nothing to revert it
                // has nothing to do.
                .disabled(presentation == .page && !isDirty)
                Spacer()
                Text("Applies to every upcoming run",
                     comment: "Scheduled-task editor footnote")
                    .sipFont(10)
                    .foregroundColor(SipDesign.textHint)
            }
        }
        .padding(.horizontal, (presentation == .page ? 20 : 14) * ratio)
        .padding(.top, (presentation == .page ? 14 : 10) * rhythm)
        .padding(.bottom, (presentation == .page ? 28 : 12) * rhythm)
    }

    /// True when the form differs from what is on disk. Keeps Save and
    /// Revert inert until there is something to save or discard, and
    /// Run now out of the way meanwhile.
    private var isDirty: Bool {
        guard let def = definition else { return false }
        return !writesSameFile(draft, def)
    }

    /// Whether the form would write the file back unchanged — the test
    /// for "unsaved", rather than field-by-field equality. A save trims
    /// the prompt and tidies the header values, so a form compared field
    /// by field still differed from the file after its own save (a prompt
    /// ending in a newline, say): Save stayed lit, Run now stayed hidden,
    /// and the form stopped adopting later changes to the file.
    private func writesSameFile(_ form: ScheduledTaskDefinition,
                                _ file: ScheduledTaskDefinition) -> Bool {
        Self.writesSameFile(form, file, formHasNameField: formHasNameField)
    }

    /// The rule itself, pure. A form with no Name field reads the name as
    /// the file's: the pencil writes a rename the moment it is made, so it
    /// is not an unsaved edit while the rescan catches up — counted as
    /// one, it would light Save and hide Run now over a form showing
    /// nothing changed.
    static func writesSameFile(_ form: ScheduledTaskDefinition,
                               _ file: ScheduledTaskDefinition,
                               formHasNameField: Bool) -> Bool {
        var form = form
        if !formHasNameField { form.description = file.description }
        return form.fileContents() == file.fileContents()
    }

    /// Unsaved edits the user can SEE: always on the page, where the form
    /// is the page; above a run, only while its editor is open — a
    /// collapsed strip gives no reason for a button to have gone.
    private var hasUnsavedEditsOnScreen: Bool {
        guard isDirty else { return false }
        return presentation == .page || (expanded && editing)
    }

    private func field<Content: View>(_ label: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3 * rhythm) {
            Text(verbatim: label)
                .sipFont(11, weight: .semibold)
                .foregroundColor(SipDesign.textSecondary)
            content()
        }
    }

    /// A `nil`-able frontmatter value as a non-optional picker
    /// selection: "" is the absent case, which is exactly what the
    /// writer omits from the file.
    private func optionalBinding(_ source: Binding<String?>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    /// The skills each run loads, and the picker that chooses them —
    /// the composer's list, for the task's agent in the task's folder,
    /// its subfolders' as the task's mode reaches them. A Kimi task loads
    /// one (`SkillAgent.oneSkillPerMessage`).
    private var skillsField: some View {
        let taskFolder = draft.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        let agent = draft.agent
        let frontEnd = AskingModeGate.frontEnd(agentKey: agent)
        return VStack(alignment: .leading, spacing: 4 * rhythm) {
            HStack(alignment: .firstTextBaseline, spacing: 8 * ratio) {
                Text(verbatim: draft.skills.isEmpty
                     ? String(localized: "None", comment: "Scheduled-task editor: no skills")
                     : draft.skills.joined(separator: ", "))
                    .foregroundColor(draft.skills.isEmpty ? SipDesign.textSecondary : SipDesign.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer(minLength: 4 * ratio)
                Button {
                    skillCatalog.ensureLoaded(folder: taskFolder, maxAge: 20)
                    skillCatalog.loadSubfolders(below: taskFolder)
                    showingSkillPicker = true
                } label: {
                    Text("Choose…", comment: "Scheduled-task editor: pick the task's skills")
                        .sipFont(11, weight: .medium)
                }
                .buttonStyle(PanelActionButtonStyle())
                .popover(isPresented: $showingSkillPicker, arrowEdge: .bottom) {
                    SkillListPopover(
                        agentLabel: config.agentLabel(
                            for: agent,
                            defaultName: AgentManager.registry.first { $0.key == agent }?.name ?? agent),
                        oneAtATime: SkillAgent.oneSkillPerMessage(agent),
                        folderName: taskFolder.lastPathComponent,
                        choices: skillCatalog.snapshot(folder: taskFolder) == nil
                            ? nil : skillCatalog.choices(
                                agent: agent, folder: taskFolder,
                                codexSend: AskingModeGate.subfolderSkillSend(
                                    agentKey: agent,
                                    mode: AgentAskingMode.taskMode(agentKey: agent, fileMode: draft.mode),
                                    chatOnly: draft.chatOnly),
                                kimiCanLoad: frontEnd != .unavailable),
                        picks: draft.skills,
                        onDone: { picked in
                            draft.skills = picked
                            showingSkillPicker = false
                        },
                        onClose: { showingSkillPicker = false })
                }
            }
            Text("Each run loads them with its prompt. A run whose skill is missing or switched off doesn’t start.",
                 comment: "Scheduled-task editor: how a task's skills work")
                .sipFont(11)
                .foregroundColor(SipDesign.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sipFont(12)
    }

    /// The model picker's selection. A pick that strands the effort — a
    /// level the new model does not take — clears it, the composer's
    /// rule and for its reason: the effort picker stops OFFERING the
    /// level, and one nobody can see must not be saved into the file
    /// and sent at fire time. Only a pick does this; seeding the form
    /// never does, so a catalog still loading cannot drop a saved level.
    private var modelBinding: Binding<String> {
        Binding(
            get: { draft.model ?? "" },
            set: { value in
                draft.model = value.isEmpty ? nil : value
                if let effort = draft.effort, !effort.isEmpty,
                   !taskEffortLevels.contains(effort) {
                    draft.effort = nil
                }
                // The speed too, for the same reason: a fast mode the
                // new model has none of, a tier it does not advertise.
                if draft.fastMode, isClaudeTask,
                   !claudeTaskTakesFastMode(model: draft.model) {
                    draft.fastMode = false
                }
                if isCodexTask, let tier = CodexSpeed.normalized(draft.serviceTier),
                   tier != CodexSpeed.standard,
                   codexCatalog.serviceTier(id: tier, forModel: draft.model,
                                            folder: Self.runFolder(draft)) == nil {
                    draft.serviceTier = nil
                }
            }
        )
    }

    /// The Mode picker's selection (`AgentAskingMode.taskPickerValue`): ""
    /// is the list's first row, `ChatOnlyMode.rowValue` Chat only, else the
    /// mode as the chip spells it — read off the task FILE's mode the way a
    /// run reads it (`taskMode`: a kimi task with none is Never Ask). One
    /// writer for the mode and Chat only (`ChatOnlyMode.select`); a pick is
    /// stored as the file spells it (`taskFileMode`). A value for a row no
    /// longer offered shows as Default, and the file keeps it until a row
    /// is picked.
    private var modeBinding: Binding<String> {
        Binding(
            get: {
                AgentAskingMode.taskPickerValue(
                    agentKey: taskAgentKey, fileMode: draft.mode, chatOnly: draft.chatOnly,
                    frontEnd: taskFrontEnd, listedModes: capabilities.permissionModes.map(\.name))
            },
            set: { value in
                var options = AgentLaunchOptions()
                ChatOnlyMode.select(value.isEmpty ? nil : value, into: &options)
                draft.chatOnly = options.chatOnly
                // Chat only carries no mode.
                draft.mode = options.chatOnly ? nil
                    : AgentAskingMode.taskFileMode(agentKey: taskAgentKey,
                                                   mode: options.permissionMode,
                                                   frontEnd: taskFrontEnd)
            }
        )
    }

    /// Whether the installed CLI has its own front end — what the Mode
    /// rows, and Default's runs, rest on for codex and kimi.
    private var taskFrontEnd: AgentAskingMode.Availability {
        AskingModeGate.frontEnd(agentKey: taskAgentKey)
    }

    /// The composer's mode rows for the task's agent (`AgentMenus`), and
    /// the task's own mode where the installed CLI no longer offers it —
    /// shown, so the picker never stands blank over a value in the file
    /// (the run then fails with words; `ScheduledTaskScheduler.modeVerdict`).
    private var modeRows: [AgentMenuRow] {
        var rows = AgentMenus.modeRows(
            agentKey: taskAgentKey, agentName: taskAgentName,
            chatOnlyOffered: ChatOnlyGate.offered(agentKey: taskAgentKey),
            askingModesOffered: AskingModeGate.offered(agentKey: taskAgentKey) ?? [],
            claudeModes: capabilities.permissionModes, frontEnd: taskFrontEnd)
        let current = modeBinding.wrappedValue
        if !rows.contains(where: { ($0.value ?? "") == current && !$0.isHeader }) {
            rows.append(AgentMenuRow(
                value: current,
                title: AgentMenus.modeTitle(agentKey: taskAgentKey,
                                            mode: current == ChatOnlyMode.rowValue || current.isEmpty
                                                ? nil : current,
                                            chatOnly: current == ChatOnlyMode.rowValue,
                                            frontEnd: taskFrontEnd),
                subtitle: nil))
        }
        return rows
    }

    /// Where the installed kimi can run nothing but its headless Never Ask,
    /// the Mode picker is a readout, as the composer's chip is — unless the
    /// task's file names something else (a mode or Chat only this kimi
    /// cannot run): its run fails saying "pick another mode", and the
    /// picker, with Never Ask in it, is where that is done.
    private var modeIsReadout: Bool {
        isKimiTask && taskFrontEnd == .unavailable && !ChatOnlyGate.offered(agentKey: "kimi")
            && modeBinding.wrappedValue.isEmpty
    }

    /// The composer's model rows for the task's agent (`AgentMenus`), and
    /// the task's own model where the list does not name it.
    private var modelRows: [AgentMenuRow] {
        var rows = AgentMenus.modelRows(agentKey: taskAgentKey, config: config,
                                        codexFolder: Self.runFolder(draft),
                                        claudeDefaultName: nil)
        let current = draft.model ?? ""
        if !current.isEmpty, !rows.contains(where: { $0.value == current && !$0.isHeader }) {
            rows.append(AgentMenuRow(value: current, title: current, subtitle: nil))
        }
        return rows
    }

    /// A caption over one of the Runs as pickers, in the composer's words
    /// for its chips — three pickers that each read "Default" need them.
    private func pickerColumn<Content: View>(_ caption: String,
                                             @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2 * rhythm) {
            Text(verbatim: caption)
                .sipFont(11)
                .foregroundColor(SipDesign.textSecondary)
            content()
        }
    }

    /// A picker over the composer's rows, names only: a section label
    /// ("Other models") opens a section, and the selection is the row's
    /// value ("" for Default).
    private func menuPicker(rows: [AgentMenuRow], selection: Binding<String>) -> some View {
        let sections = Self.sections(rows)
        return Picker("", selection: selection) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                if let header = section.header {
                    Section(header: Text(verbatim: header)) {
                        ForEach(section.rows) { row in
                            Text(verbatim: row.title).tag(row.value ?? "")
                        }
                    }
                } else {
                    ForEach(section.rows) { row in
                        Text(verbatim: row.title).tag(row.value ?? "")
                    }
                }
            }
        }
        .labelsHidden()
        .frame(maxWidth: 170 * ratio)
    }

    /// The rows split at their section labels.
    private static func sections(_ rows: [AgentMenuRow])
    -> [(header: String?, rows: [AgentMenuRow])] {
        var out: [(header: String?, rows: [AgentMenuRow])] = [(nil, [])]
        for row in rows {
            if row.isHeader {
                out.append((row.title, []))
            } else {
                out[out.count - 1].rows.append(row)
            }
        }
        return out.filter { !$0.rows.isEmpty }
    }

    // MARK: - Non-stop

    /// Under Fast mode: the composer's Non-stop switch as a checkbox, with
    /// the composer's own line under it. A run is Non-stop only when this
    /// is ticked. Drawn where the agent can ask a question in some mode
    /// (claude always; codex and kimi where a mode that asks is offered),
    /// and greyed, unticked, in a mode that never asks — the pick is kept.
    @ViewBuilder
    private var nonStopControl: some View {
        let asks = AgentAskingMode.asksQuestions(
            agentKey: taskAgentKey,
            mode: AgentAskingMode.taskMode(agentKey: taskAgentKey, fileMode: draft.mode),
            chatOnly: draft.chatOnly, frontEndOffered: taskFrontEnd != .unavailable,
            kimiDefaultPermission: kimiCatalog.defaultPermissionMode)
        let offered = taskAgentKey == "claude_code"
            || (taskAgentKey == "codex" && taskFrontEnd == .offered)
            || (AskingModeGate.offered(agentKey: taskAgentKey) ?? []).contains {
                AgentAskingMode.asksQuestions(agentKey: taskAgentKey, mode: $0, chatOnly: false)
            }
        if offered {
            checkboxRow(
                title: AgentComposer.nonStopTitle,
                isOn: Binding(get: { draft.nonStop && asks }, set: { draft.nonStop = $0 }),
                enabled: asks,
                lines: [draft.chatOnly
                        ? String(localized: "Chat only turns never stop to ask.",
                                 comment: "Mode menu Non-stop switch subtitle while Chat only is picked: such a turn cannot ask the user a question")
                        : asks
                        ? AskingModeGate.nonStopLine(agentName: taskAgentName)
                        : String(localized: "\(taskAgentName) never stops to ask questions in this mode.",
                                 comment: "Mode menu Non-stop switch subtitle while the picked mode is one in which the agent cannot ask the user a question; placeholder is the agent label")])
        }
    }

    // MARK: - Speed

    /// The folder a run of this definition works in — the scheduler's
    /// own fallback when none is set, so the card asks codex about the
    /// folder the run will actually start in.
    private static func runFolder(_ def: ScheduledTaskDefinition) -> String {
        (def.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser).path
    }

    /// Under the Runs as pickers: claude's Fast mode checkbox, or codex's
    /// speed checkboxes — the composer's switches over the task's own
    /// model and folder. Kimi has no such mode.
    @ViewBuilder
    private var speedControl: some View {
        if isCodexTask {
            let folder = Self.runFolder(draft)
            ForEach(codexCatalog.speedSwitches(forModel: draft.model, folder: folder),
                    id: \.tier.id) { speed in
                codexSpeedRow(speed, folder: folder)
            }
        } else if isClaudeTask {
            claudeFastModeRow
        }
    }

    /// Claude's switch, with the composer's lines under it — what fast
    /// mode costs, then what stands in its way. A task has no live
    /// report, so the lines judge the switch against claude's cached
    /// credits verdict alone.
    private var claudeFastModeRow: some View {
        let supported = claudeTaskTakesFastMode(model: draft.model)
        let requested = draft.fastMode && supported
        return fastModeCheckbox(
            isOn: Binding(get: { requested }, set: { draft.fastMode = $0 }),
            enabled: supported,
            lines: ClaudeFastModeWords.lines(
                supported: supported, cloudProvider: claudeOnCloudProvider,
                agentName: config.agentLabel(for: "claude_code", defaultName: "Claude Code"),
                account: UsageMonitor.shared.accounts["claude_code"],
                creditsBlock: claudeCreditsBlock,
                verdict: ClaudeFastMode.verdict(requested: requested,
                                                report: ClaudeFastModeReport(),
                                                creditsBlock: claudeCreditsBlock)))
    }

    /// One of codex's speed checkboxes, the composer's switch: checked
    /// runs that speed, unchecked pins standard (`default`) — so it holds
    /// even where codex's config turns a speed on — and checking one
    /// unchecks the other. Until one is flipped they show what the run
    /// gets by itself (`CodexSpeed.scheduled`: the config's tier for the
    /// task's folder, never the model's own default).
    private func codexSpeedRow(_ speed: CodexSpeed.SpeedSwitch, folder: String) -> some View {
        let running = codexCatalog.scheduledServiceTier(pick: draft.serviceTier,
                                                        forModel: draft.model, folder: folder)
        let on = speed.offered && CodexSpeed.isFaster(running)
            && CodexSpeed.normalized(running) == speed.tier.id
        return checkboxRow(
            title: speed.isFast ? ClaudeFastModeWords.title : speed.tier.name,
            isOn: Binding(get: { on }, set: { turnOn in
                draft.serviceTier = turnOn ? speed.tier.id : CodexSpeed.standard
            }),
            enabled: speed.enabled,
            lines: CodexSpeedWords.lines(speed, on: on,
                                         picked: CodexSpeed.normalized(draft.serviceTier) != nil,
                                         agentName: codexName))
    }

    /// The card's Fast mode checkbox, like its other switches, with each
    /// line under it wrapped.
    private func fastModeCheckbox(isOn: Binding<Bool>, enabled: Bool,
                                  lines: [String]) -> some View {
        checkboxRow(title: ClaudeFastModeWords.title, isOn: isOn, enabled: enabled, lines: lines)
    }

    /// One of the card's switches as a checkbox — Fast mode, Non-stop —
    /// with each line under it wrapped.
    private func checkboxRow(title: String, isOn: Binding<Bool>, enabled: Bool,
                             lines: [String]) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1 * rhythm) {
                Text(verbatim: title)
                    .sipFont(12)
                ForEach(lines, id: \.self) { line in
                    Text(verbatim: line)
                        .sipFont(11)
                        .foregroundColor(SipDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!enabled)
    }

    private var codexName: String {
        config.agentLabel(for: "codex", defaultName: "Codex")
    }

    /// Whether a claude task's model takes fast mode — the composer's
    /// rule over the task's own model: the installed claude's catalog,
    /// and never through a cloud provider.
    private func claudeTaskTakesFastMode(model: String?) -> Bool {
        guard !claudeOnCloudProvider else { return false }
        let id = config.resolvedClaudeModelId(picked: model,
                                              configuredDefault: claudeConfiguredDefault)
        return capabilities.fastModeSupported(forModelId: id) ?? true
    }

    private var claudeOnCloudProvider: Bool {
        ClaudeModelCatalog.childEnvironmentFacts().provider != nil
    }

    /// Claude's cached reason usage credits are unavailable — only on a
    /// Claude plan, where fast mode is paid from them.
    private var claudeCreditsBlock: String? {
        guard UsageMonitor.shared.accounts["claude_code"]?.isPlan == true else { return nil }
        return capabilities.usageCreditsBlock
    }

    /// What the speed control reads, asked for the task's own agent and
    /// folder: codex's catalog and its answer for the folder, claude's
    /// cached credits verdict. Each is a stat or two when nothing moved.
    private func refreshSpeedSources() {
        if isCodexTask {
            codexCatalog.ensureLoaded()
            codexCatalog.refreshSpeedSettings(forFolder: Self.runFolder(draft))
        } else if isClaudeTask {
            capabilities.refreshUsageCreditsBlock()
        }
    }

    /// The chips' value, kept alongside `draft` rather than derived
    /// from it on every pass: an in-progress custom expression has no
    /// valid cron to derive a structure back from, and re-deriving would
    /// throw away which mode the user is in the moment they clear the
    /// field.
    ///
    /// A valid selection is written straight through to the definition;
    /// an invalid one leaves the last good expression in place and
    /// blocks Save via `canSave`, so a half-typed cron can never reach
    /// the file that drives unattended runs.
    private var scheduleTimingBinding: Binding<ScheduleTiming> {
        Binding(
            get: { timing },
            set: { updated in
                timing = updated
                if let expression = updated.expression {
                    draft.scheduleExpression = expression
                }
            }
        )
    }

    private var canSave: Bool {
        definition != nil
            && timing.isValid
            && !pastMomentChosen
            && !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A one-time moment behind the clock may STAY in the file — that is
    /// how a task that has had its run reads, and a prompt edit on it
    /// must still save — but it may not be CHOSEN: a task saved with a
    /// new moment in the past would never fire, and would say nothing.
    private var pastMomentChosen: Bool {
        guard let def = definition,
              draft.scheduleExpression != def.scheduleExpression else { return false }
        return timing.problem() != nil
    }

    // MARK: - Rename in place

    /// The title swapped for a text field where it stands. Enter saves;
    /// Escape or clicking anywhere else abandons the edit and the
    /// original name stays — the same contract the sidebar's inline
    /// rename keeps, so both places behave identically.
    private func nameField(fontSize: CGFloat) -> some View {
        TextField("", text: $nameDraft)
            .textFieldStyle(.plain)
            .sipFont(fontSize, weight: .semibold)
            .foregroundColor(SipDesign.textPrimary)
            .focused($nameFieldFocused)
            .onSubmit { commitNameEdit() }
            .onExitCommand { editingName = false }
            .onChange(of: nameFieldFocused) { _, focused in
                // Click-away = regret. The Enter path clears the flag
                // before focus drops, so this is a no-op after a commit.
                if focused {
                    FocusedFieldSelection.selectAll()
                } else {
                    editingName = false
                }
            }
            .onAppear { nameFieldFocused = true }
            .padding(.horizontal, 6 * ratio)
            .padding(.vertical, 3 * ratio)
            .background(
                RoundedRectangle(cornerRadius: 6 * ratio)
                    .fill(Color.gray.opacity(0.18))
            )
            // Clicks that don't move key focus (rows, buttons, empty
            // space) — see EditFieldClickAway.
            .editFieldClickAway { editingName = false }
    }

    private func beginNameEdit() {
        nameDraft = task.description
        editingName = true
    }

    /// Writes the same `description:` the sidebar's ⋮ → Rename writes —
    /// one name, one place in the file, so a rename from either side
    /// shows up on the other.
    private func commitNameEdit() {
        guard editingName else { return }
        editingName = false
        let name = nameDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != task.description,
              let def = definition else { return }
        // Carry it into the open form too. Without this, a rename made
        // while the editor is open would be undone by the next Save,
        // which writes the whole definition from `draft`.
        draft.description = name
        var updated = def
        updated.description = name
        persist(updated)
    }

    // MARK: - Actions

    private func seedDraft() {
        draft = definition
            ?? ScheduledTaskDefinition(name: task.name, description: task.description)
        timing = ScheduleTiming(schedule: draft.scheduleExpression)
        // Whatever the pickers were showing described the OUTGOING
        // draft; the form re-opens on the summary of the new one.
        editingSchedule = false
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = draft.workingDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.workingDirectory = url
    }

    private func togglePaused(_ def: ScheduledTaskDefinition) {
        var updated = def
        updated.enabled.toggle()
        // The form follows the click. On the page the editor is always
        // open beside this button, and a draft holding unsaved edits is
        // not reseeded when the file changes — left alone, its Active
        // checkbox would still show the old value, and the next Save
        // would quietly write it back over the pause.
        draft.enabled = updated.enabled
        persist(updated)
    }

    private func save() {
        // The button's enabled state is drawn a render ago, and the clock
        // can pass a one-time moment in between — so a refusal here says
        // why, rather than leaving a click that does nothing.
        if pastMomentChosen, let problem = timing.problem() {
            saveError = problem
            return
        }
        guard canSave else { return }
        var updated = draft
        // The directory name is the identity; the editor never offers it,
        // but a seeded draft from an orphan could carry the wrong one.
        updated.name = task.name
        if updated.description.trimmingCharacters(in: .whitespaces).isEmpty {
            updated.description = task.name
        }
        updated.scheduleExpression = updated.scheduleExpression
            .trimmingCharacters(in: .whitespaces)
        persist(updated)
        editing = false
        // The page's form stays open after a save (it is the whole
        // view), so collapse the pickers back to the saved summary
        // rather than leaving them open over a settled value.
        editingSchedule = false
    }

    private func persist(_ def: ScheduledTaskDefinition) {
        let skillFile = task.skillFileURL
        saveError = nil
        // File write off the main actor, matching the contract every
        // other scheduled-task mutation follows.
        Task.detached(priority: .userInitiated) {
            let ok = ScheduledTaskCreator.update(def, skillFile: skillFile)
            await MainActor.run {
                if ok {
                    agents.reloadSessions()
                } else {
                    saveError = String(
                        localized: "Could not write the task file at \(skillFile.path).",
                        comment: "Scheduled-task editor error: SKILL.md write failed")
                }
            }
        }
    }

    // MARK: - Date text

    private static func absolute(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }

    private static func relative(_ date: Date, from reference: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: reference)
    }
}

// MARK: - Action button style

/// Borderless text action with a hover (and pressed) background, matching
/// the composer's `HoverHighlight` fill so the two read as one system.
///
/// `.buttonStyle(.borderless)` gives no hover feedback at all on
/// macOS, which would leave Edit / Pause / Run now reading as static
/// labels — nothing to tell the user they are clickable until they
/// click.
///
/// The hover state lives in a nested View, not on the style struct: a
/// `ButtonStyle` is not a `View`, so `@State` declared on it is never
/// installed and never updates.
private struct PanelActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration)
    }

    // Deliberately NOT named `Body`: that is ButtonStyle's own associated
    // type, and a nested type of that name binds it to this struct,
    // which then contradicts `makeBody`'s opaque `some View` return.
    fileprivate struct HoverLabel: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        /// The label's type scales with the tier; the box around it has
        /// to scale with it, or a larger tier crams bigger text into the
        /// Default tier's button.
        @Environment(\.sipFontScale) private var fontScale
        @State private var hovered = false

        var body: some View {
            let ratio = SipFont.ratio(fontScale)
            configuration.label
                .foregroundColor(isEnabled ? SipDesign.blue : SipDesign.textHint)
                .padding(.horizontal, 7 * ratio)
                .padding(.vertical, 3 * ratio)
                .background(
                    RoundedRectangle(cornerRadius: 6 * ratio)
                        .fill(fill)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6 * ratio))
                .onHover { hovering in
                    // Never leave a disabled control looking live.
                    hovered = hovering && isEnabled
                }
                .animation(.easeOut(duration: 0.12), value: hovered)
        }

        private var fill: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return Color.gray.opacity(0.3) }
            return hovered ? Color.gray.opacity(0.2) : .clear
        }
    }
}
