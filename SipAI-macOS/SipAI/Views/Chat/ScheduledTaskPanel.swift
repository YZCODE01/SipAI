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
    private var isCodexTask: Bool { task.definition?.agent == "codex" }
    /// Kimi tasks carry no MODE: its headless runs refuse the flag and
    /// auto-approve on their own, so that one picker is replaced by a
    /// readout rather than offering a value that would be written to
    /// the file and then rejected at fire time. Effort is a different
    /// story — kimi grades thinking and takes the level through the
    /// environment, so that picker stays. See
    /// `AgentLaunchOptions.kimiFlags`.
    private var isKimiTask: Bool { task.definition?.agent == "kimi" }

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
                                     comment: "Scheduled-task detail label: permission mode"),
                              runtimeText(def))
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
        if isCodexTask { return codexCatalog.effortLevels(forModel: draft.model) }
        return capabilities.effortLevels(forModelId: config.resolvedClaudeModelId(
            picked: draft.model, configuredDefault: claudeConfiguredDefault))
    }

    private func refreshClaudeConfiguredDefault() {
        guard !isCodexTask, !isKimiTask else { return }
        let found = ClaudeModelCatalog.configuredDefaultModel(cwd: draft.workingDirectory)
        if found != claudeConfiguredDefault { claudeConfiguredDefault = found }
    }

    private func runtimeText(_ def: ScheduledTaskDefinition) -> String {
        let codex = def.agent == "codex"
        let kimi = def.agent == "kimi"
        if kimi {
            // No mode — the summary opens with the auto-approve
            // statement instead — but kimi does have an effort, and it
            // reaches its runs through the environment rather than the
            // command line (`KimiCapabilities.effortEnvVar`).
            var parts = [KimiCapabilities.autoApproveTitle]
            if let model = def.model, !model.isEmpty {
                parts.append(kimiCatalog.displayName(forModel: model))
            }
            if let effort = def.effort, !effort.isEmpty {
                parts.append(AgentEffort.displayName(effort))
            }
            return parts.joined(separator: " · ")
        }
        // A codex task with no explicit mode has no "default" preset to
        // name, and `CodexCapabilities.title(for: "")` answers "" — the
        // summary would open with a stray separator.
        let modeTitle: String
        if codex {
            let mode = def.mode ?? ""
            modeTitle = mode.isEmpty
                ? String(localized: "Default",
                         comment: "Scheduled-task summary: codex sandbox left at its default")
                : CodexCapabilities.title(for: mode)
        } else {
            modeTitle = AgentPermissionMode(name: def.mode ?? "default").title
        }
        var parts: [String] = [modeTitle]
        if let model = def.model, !model.isEmpty {
            // Frontmatter stores the picker ALIAS ("opus"), which carries
            // no version — `ClaudeModelDisplay.name` on it can only ever
            // answer "Opus". The version comes from the ids this machine
            // has observed the alias resolve to, exactly as the composer's
            // model chip does. Codex ids are literal and have no alias
            // layer, so they print as recorded.
            parts.append(codex ? model
                               : config.rememberedModelName(forAlias: model))
        }
        if let effort = def.effort, !effort.isEmpty {
            // Through `AgentEffort.displayName` like every other surface
            // that prints a level — a raw "xhigh" here would sit next
            // to the editor's own "XHigh".
            parts.append(AgentEffort.displayName(effort))
        }
        if let speed = runtimeSpeedText(def, codex: codex) {
            parts.append(speed)
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
                    HStack(spacing: 8 * ratio) {
                        // Per-agent catalogs. A codex task offered claude's
                        // permission modes would be saved with a mode its
                        // CLI has no idea about, and claude's model aliases
                        // would put `-m opus` on a codex command line.
                        //
                        // No "Chat only" row here, on purpose: a scheduled
                        // task is unattended agent work, and the composer's
                        // Chat only is a per-turn shape with no file tools — a
                        // task that could not read the folder it was pointed
                        // at would run to nothing. `ScheduledTaskCreator
                        // .Request` carries no such field, and a task
                        // scheduled from a Chat only composer gets the
                        // agent's unattended default.
                        if isKimiTask {
                            // A readout in the picker's place — the same
                            // reason the composer swaps kimi's mode chip
                            // for one: an option its CLI refuses must not
                            // be offered, and a control that silently does
                            // nothing is worse than no control.
                            Text(verbatim: KimiCapabilities.autoApproveTitle)
                                .foregroundStyle(.secondary)
                                .help(KimiCapabilities.autoApproveHint(
                                    agentName: config.agentLabel(
                                        for: "kimi", defaultName: "Kimi Code")))
                        } else {
                            Picker("", selection: modeBinding) {
                                if isCodexTask {
                                    ForEach(CodexCapabilities.modePresets, id: \.value) { preset in
                                        Text(verbatim: CodexCapabilities.title(for: preset.value))
                                            .tag(preset.value)
                                    }
                                } else {
                                    ForEach(capabilities.permissionModes) { mode in
                                        Text(verbatim: mode.title).tag(mode.name)
                                    }
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 150 * ratio)
                        }
                        Picker("", selection: modelBinding) {
                            Text("Default model",
                                 comment: "Scheduled-task editor: no explicit model").tag("")
                            if isCodexTask {
                                ForEach(codexCatalog.models) { model in
                                    Text(verbatim: model.displayName).tag(model.slug)
                                }
                            } else if isKimiTask {
                                // Kimi's own display names, like codex's —
                                // no alias layer to resolve into a versioned
                                // name, but the generated slugs carry their
                                // provider (`kimi-for-coding/k3`) and read
                                // as paths without this.
                                ForEach(kimiCatalog.models) { model in
                                    Text(verbatim: model.displayName)
                                        .tag(model.slug)
                                }
                            } else {
                                ForEach(capabilities.modelAliases, id: \.self) { alias in
                                    // Versioned, same as the composer's rows.
                                    Text(verbatim: config.rememberedModelName(forAlias: alias))
                                        .tag(alias)
                                }
                                // The composer's "Other models" section,
                                // so a task can pin the previous version
                                // of a family the same way a session can.
                                if !capabilities.otherModels.isEmpty {
                                    Section(header: Text("Other models",
                                                         comment: "Model menu section header: previous model versions the CLI still offers")) {
                                        ForEach(capabilities.otherModels) { model in
                                            Text(verbatim: model.displayName)
                                                .tag(model.fullId)
                                        }
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 150 * ratio)
                        // Hidden for a model that takes no levels (a kimi
                        // model with no `support_efforts`, claude's Haiku),
                        // exactly as the composer hides its chip — see
                        // `AgentComposer.showsEffortChip`.
                        if isCodexTask || !taskEffortLevels.isEmpty {
                            Picker("", selection: optionalBinding($draft.effort)) {
                                Text("Default effort",
                                     comment: "Scheduled-task editor: no explicit effort").tag("")
                                ForEach(taskEffortLevels, id: \.self) { level in
                                    // Same casing as the composer's rows —
                                    // a raw "xhigh" here would sit two
                                    // panes from the composer's "XHigh".
                                    Text(verbatim: AgentEffort.displayName(level))
                                        .tag(level)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 150 * ratio)
                        }
                        Spacer(minLength: 0)
                    }
                    speedControl
                }
                .sipFont(12)
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
                if draft.fastMode, !isCodexTask, !isKimiTask,
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

    /// Permission mode defaults to "default" rather than empty: an
    /// unattended run with no mode prompts on every tool and then hangs
    /// forever with nobody to answer.
    private var modeBinding: Binding<String> {
        Binding(
            get: { draft.mode ?? "default" },
            set: { draft.mode = $0 }
        )
    }

    // MARK: - Speed

    /// The folder a run of this definition works in — the scheduler's
    /// own fallback when none is set, so the card asks codex about the
    /// folder the run will actually start in.
    private static func runFolder(_ def: ScheduledTaskDefinition) -> String {
        (def.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser).path
    }

    /// Under the Runs as pickers: one Fast mode checkbox — claude's opt-in
    /// or codex's Fast tier, the composer's switch over the task's own
    /// model and folder. Kimi has no such mode.
    @ViewBuilder
    private var speedControl: some View {
        if isCodexTask {
            codexFastModeRow
        } else if !isKimiTask {
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

    /// Codex's Fast mode, the composer's switch: checked runs the model's
    /// Fast tier, unchecked pins standard (`default`) — so it holds even
    /// where codex's config turns a tier on. Until it is flipped it shows
    /// what the run gets by itself (`CodexSpeed.scheduled`: the config's
    /// tier for the task's folder, never the model's own default).
    private var codexFastModeRow: some View {
        let folder = Self.runFolder(draft)
        let featureEnabled = codexCatalog.speedSettings(forFolder: folder).featureEnabled
        let fast = featureEnabled ? codexCatalog.fastTier(forModel: draft.model, folder: folder) : nil
        let on = fast != nil && CodexSpeed.isFaster(
            codexCatalog.scheduledServiceTier(pick: draft.serviceTier,
                                              forModel: draft.model, folder: folder))
        var lines: [String]
        if let fast {
            lines = [fast.description.isEmpty ? fast.name : fast.description]
            if on, CodexSpeed.normalized(draft.serviceTier) == nil {
                lines.append(String(localized: "On by default in \(codexName)",
                                    comment: "Fast mode switch: on because codex itself turns it on here — its config, or the model's own default — and not because it was picked; the placeholder is the agent label"))
            }
        } else {
            lines = [featureEnabled
                     ? String(localized: "Not offered for this model",
                              comment: "Model menu switch subtitle: the selected model has no fast mode")
                     : String(localized: "Turned off in \(codexName)'s config (features.fast_mode)",
                              comment: "Codex speed: the fast_mode feature is disabled in the user's codex config; placeholder is the agent label")]
        }
        return fastModeCheckbox(
            isOn: Binding(get: { on }, set: { turnOn in
                draft.serviceTier = turnOn ? fast?.id : CodexSpeed.standard
            }),
            enabled: fast != nil, lines: lines)
    }

    /// The card's Fast mode checkbox, like its other switches, with each
    /// line under it wrapped.
    private func fastModeCheckbox(isOn: Binding<Bool>, enabled: Bool,
                                  lines: [String]) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1 * rhythm) {
                Text(verbatim: ClaudeFastModeWords.title)
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
        } else if !isKimiTask {
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
