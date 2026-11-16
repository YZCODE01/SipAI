// SkillPicker.swift
// The skill chip's popover, and the list the scheduled-task panel picks a
// task's skills from.
//
// Two faces. With nothing chosen the chip opens straight onto the PICKER:
// the agent's skills for every folder, the session folder's own, then a
// group for each subfolder of it that has skills, each with a checkbox,
// and nothing changes until Done. With skills chosen it opens onto the
// SUMMARY — only the chosen ones, each with where it stands (in the
// conversation, going with the next message, or not loadable here) —
// and Edit turns it back into the picker with the choices ticked.
//
// An agent that takes one skill per message (`SkillAgent
// .oneSkillPerMessage`) picks ONE: ticking another replaces it, and a
// line says why.

import SwiftUI

/// The picker: the skills one agent can load, grouped Global, This
/// folder and each subfolder, ticked in the order they were chosen.
struct SkillPickerList: View {
    let agentLabel: String
    /// The agent takes one skill per message: one may be ticked.
    var oneAtATime: Bool = false
    /// The session folder's name, for the second group's header.
    let folderName: String?
    /// nil while the folder's skills are still being read.
    let choices: [SkillChoice]?
    @Binding var ticked: [String]
    /// Lower-cased names already in the conversation — unticking one of
    /// those earns a line saying what that does and does not undo.
    var held: Set<String> = []
    var onOpenSettings: (() -> Void)? = nil

    @State private var query = ""
    @Environment(\.sipFontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: String(localized: "Skills · \(agentLabel)",
                                      comment: "Skill picker title; placeholder is the agent label"))
                    .sipFont(13, weight: .semibold)
                    .foregroundColor(SipDesign.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .sipFont(11)
                        .foregroundColor(SipDesign.textSecondary)
                    SearchField(text: $query,
                                placeholder: String(localized: "Search",
                                                    comment: "Placeholder of the skill picker's search field"),
                                fontSize: SipFont.scaled(12, fontScale))
                        .frame(width: 110 * SipFont.ratio(fontScale),
                               height: 16 * SipFont.ratio(fontScale))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(SipDesign.rowHover))
            }
            .padding(.horizontal, 6)

            Divider()

            if oneAtATime {
                Text(verbatim: String(localized: "\(agentLabel) loads one skill per message, so you can pick one at a time.",
                                      comment: "Skill picker note for an agent whose front end takes one skill per message (Kimi Code); placeholder is the agent label"))
                    .sipFont(11)
                    .foregroundColor(SipDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }

            if let choices {
                if choices.isEmpty && orphans(among: choices).isEmpty {
                    emptyState
                } else {
                    list(choices)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Reading skills…",
                                comment: "Skill picker while the folder's skills are being read"))
                        .sipFont(12)
                        .foregroundColor(SipDesign.textSecondary)
                }
                .padding(10)
            }

            if !unloadedHeld.isEmpty {
                Text(String(localized: "Unticked skills stop loading. What they already put in the conversation stays there.",
                            comment: "Skill picker note when a skill that is already loaded is unticked"))
                    .sipFont(11)
                    .foregroundColor(SipDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
    }

    /// Picks the conversation already holds that are no longer ticked.
    private var unloadedHeld: [String] {
        let tickedKeys = Set(ticked.map { $0.lowercased() })
        return held.filter { !tickedKeys.contains($0) }.sorted()
    }

    private func matches(_ choice: SkillChoice) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return choice.name.localizedCaseInsensitiveContains(q)
            || choice.description.localizedCaseInsensitiveContains(q)
    }

    /// Ticked names this agent has no skill for here — one deleted, or
    /// taken from the agent, since it was chosen; a new session's
    /// default that belongs to another folder. Each is listed, ticked
    /// and dimmed, so it can be UNticked: a list of the available skills
    /// alone would leave a choice like that with no way out of the chip.
    private func orphans(among choices: [SkillChoice]) -> [SkillChoice] {
        let known = Set(choices.map { $0.name.lowercased() })
        var seen = Set<String>()
        return ticked.compactMap { name in
            let key = name.lowercased()
            guard !known.contains(key), seen.insert(key).inserted else { return nil }
            return SkillChoice(name: name, description: "", scope: .global, sourceLabel: nil,
                               unavailable: String(localized: "Not available in this folder",
                                                   comment: "Skill chip summary: a chosen skill this folder does not have"),
                               codexPath: nil)
        }
    }

    @ViewBuilder
    private func list(_ choices: [SkillChoice]) -> some View {
        let global = choices.filter { $0.scope == .global && $0.subfolder == nil && matches($0) }
        let local = choices.filter { $0.scope == .folder && $0.subfolder == nil && matches($0) }
        let below = subfolderGroups(choices.filter { $0.subfolder != nil && matches($0) })
        let gone = orphans(among: choices).filter(matches)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !global.isEmpty {
                    header(String(localized: "Global",
                                  comment: "Skill picker group: skills for every folder"))
                    ForEach(global) { row($0) }
                }
                if !local.isEmpty {
                    header(folderName.map {
                        String(localized: "This folder · \($0)",
                               comment: "Skill picker group: the session folder's skills; placeholder is the folder name")
                    } ?? String(localized: "This folder",
                                comment: "Skill picker group: the session folder's skills"))
                    ForEach(local) { row($0) }
                }
                // A subfolder's skills: the session is not started with
                // them, and whether this send can load one is each row's
                // own (`SkillSubfolderReach`).
                ForEach(below, id: \.path) { group in
                    header(String(localized: "Subfolder · \(group.name)",
                                  comment: "Skill picker group: the skills of a folder below the session's folder; placeholder is that folder's path from the session's folder, e.g. packages/web"))
                    ForEach(group.choices) { row($0) }
                }
                if !gone.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(gone) { row($0) }
                    }
                    .padding(.top, global.isEmpty && local.isEmpty && below.isEmpty ? 0 : 8)
                }
                if global.isEmpty && local.isEmpty && below.isEmpty && gone.isEmpty {
                    Text(String(localized: "No skill matches.",
                                comment: "Skill picker: the search found nothing"))
                        .sipFont(12)
                        .foregroundColor(SipDesign.textSecondary)
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 340 * SipFont.ratio(fontScale))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The subfolder choices, one group per subfolder in the order the
    /// walk found them (nearest first).
    private func subfolderGroups(_ choices: [SkillChoice]) -> [(path: String, name: String, choices: [SkillChoice])] {
        var out: [(path: String, name: String, choices: [SkillChoice])] = []
        for choice in choices {
            guard let path = choice.subfolder else { continue }
            if let i = out.firstIndex(where: { $0.path == path }) {
                out[i].choices.append(choice)
            } else {
                out.append((path, choice.subfolderName ?? (path as NSString).lastPathComponent, [choice]))
            }
        }
        return out
    }

    private func header(_ title: String) -> some View {
        Text(verbatim: title)
            .sipFont(11, weight: .semibold)
            .foregroundColor(SipDesign.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func row(_ choice: SkillChoice) -> some View {
        SkillPickerRow(choice: choice,
                       isTicked: ticked.contains { $0.lowercased() == choice.name.lowercased() },
                       onToggle: { toggle(choice) })
    }

    private func toggle(_ choice: SkillChoice) {
        let key = choice.name.lowercased()
        if let index = ticked.firstIndex(where: { $0.lowercased() == key }) {
            ticked.remove(at: index)
        } else if oneAtATime {
            ticked = [choice.name]
        } else {
            ticked.append(choice.name)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: String(localized: "\(agentLabel) has no skills here yet.",
                                  comment: "Skill picker when the agent has no skills; placeholder is the agent label"))
                .sipFont(12)
                .foregroundColor(SipDesign.textPrimary)
            if let onOpenSettings {
                LinkButton(title: String(localized: "Open Settings → Agent Skills",
                                         comment: "Skill picker button that opens the skill manager"),
                           size: 12, action: onOpenSettings)
            }
        }
        .padding(10)
    }
}

private struct SkillPickerRow: View {
    let choice: SkillChoice
    let isTicked: Bool
    let onToggle: () -> Void
    @State private var hovered = false
    @Environment(\.sipFontScale) private var fontScale

    var body: some View {
        let available = choice.unavailable == nil
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: isTicked ? "checkmark.square.fill" : "square")
                    .sipFont(13)
                    .foregroundColor(isTicked ? SipDesign.blue : SipDesign.textSecondary)
                Text(verbatim: choice.name)
                    .sipFont(13)
                    .foregroundColor(available ? SipDesign.textPrimary : SipDesign.textHint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let reason = choice.unavailable {
                    Text(verbatim: reason)
                        .sipFont(11)
                        .foregroundColor(SipDesign.textHint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if let label = choice.sourceLabel {
                    Text(verbatim: SkillLabels.source(label))
                        .sipFont(11)
                        .foregroundColor(SipDesign.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(hovered && available ? SipDesign.rowHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A skill that cannot be loaded here can still be UNticked: a
        // pick made before it was switched off must be removable.
        .disabled(!available && !isTicked)
        .onHover { hovered = $0 }
        .help(choice.unavailable ?? choice.description)
    }
}

/// The chip's popover: the summary of what is chosen, or the picker.
struct SkillChipPopover: View {
    let agentLabel: String
    /// The agent takes one skill per message (`SkillAgent.oneSkillPerMessage`).
    var oneAtATime: Bool = false
    let folderName: String?
    let choices: [SkillChoice]?
    let picks: [String]
    let statuses: [String: SkillPickStatus]
    let held: Set<String>
    let onDone: ([String]) -> Void
    let onClose: () -> Void
    var onOpenSettings: (() -> Void)? = nil

    @State private var editing: Bool
    @State private var ticked: [String]
    @Environment(\.sipFontScale) private var fontScale

    init(agentLabel: String, oneAtATime: Bool = false, folderName: String?, choices: [SkillChoice]?,
         picks: [String], statuses: [String: SkillPickStatus], held: Set<String>,
         onDone: @escaping ([String]) -> Void, onClose: @escaping () -> Void,
         onOpenSettings: (() -> Void)? = nil) {
        self.agentLabel = agentLabel
        self.oneAtATime = oneAtATime
        self.folderName = folderName
        self.choices = choices
        self.picks = picks
        self.statuses = statuses
        self.held = held
        self.onDone = onDone
        self.onClose = onClose
        self.onOpenSettings = onOpenSettings
        _editing = State(initialValue: picks.isEmpty)
        _ticked = State(initialValue: oneAtATime ? Array(picks.prefix(1)) : picks)
    }

    var body: some View {
        Group {
            if editing {
                picker
            } else {
                summary
            }
        }
        .padding(8)
        .frame(width: 320 * SipFont.ratio(fontScale), alignment: .leading)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkillPickerList(agentLabel: agentLabel, oneAtATime: oneAtATime, folderName: folderName,
                            choices: choices, ticked: $ticked,
                            held: held.intersection(Set(picks.map { $0.lowercased() })),
                            onOpenSettings: onOpenSettings)
            HStack(spacing: 8) {
                Spacer()
                Button(String(localized: "Cancel", comment: "Skill picker: close without changing the choice")) {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "Done", comment: "Skill picker: keep the ticked skills")) {
                    onDone(ticked)
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(SipFont.controlSize(fontScale))
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Chosen skills", comment: "Skill chip summary title"))
                .sipFont(13, weight: .semibold)
                .foregroundColor(SipDesign.textPrimary)
                .padding(.horizontal, 6)
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                ForEach(picks, id: \.self) { pick in
                    summaryRow(pick, statuses[pick] ?? .nextMessage)
                }
            }
            Text(String(localized: "Each one loads once, with your next message, and again only if the agent drops it while summarising the conversation.",
                        comment: "Skill chip summary: how preloading works"))
                .sipFont(11)
                .foregroundColor(SipDesign.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
            HStack {
                Spacer()
                Button(String(localized: "Edit", comment: "Skill chip summary: change the chosen skills")) {
                    editing = true
                }
                .controlSize(SipFont.controlSize(fontScale))
            }
        }
    }

    private func summaryRow(_ name: String, _ status: SkillPickStatus) -> some View {
        HStack(spacing: 8) {
            Group {
                switch status {
                case .loaded:
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                case .nextMessage:
                    Image(systemName: "circle.dashed").foregroundColor(SipDesign.textSecondary)
                case .unavailable:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                }
            }
            .sipFont(12)
            Text(verbatim: name)
                .sipFont(13)
                .foregroundColor(SipDesign.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(verbatim: Self.statusText(status))
                .sipFont(11)
                .foregroundColor(SipDesign.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    static func statusText(_ status: SkillPickStatus) -> String {
        switch status {
        case .loaded:
            return String(localized: "Loaded", comment: "Skill chip summary: the skill is in the conversation")
        case .nextMessage:
            return String(localized: "Loads with your next message",
                          comment: "Skill chip summary: the skill goes with the next message")
        case .unavailable(let reason):
            return reason
        }
    }
}

/// Words for where a skill comes from.
enum SkillLabels {
    static func source(_ label: String) -> String {
        switch label {
        case "Plugin": return String(localized: "Plugin", comment: "Skill source: an agent plugin's skill")
        case "Built-in": return String(localized: "Built-in", comment: "Skill source: a skill the agent ships with")
        case "claude.ai": return "claude.ai"
        default: return label
        }
    }
}

/// The task panel's picker: the same list, with Cancel and Done, for a
/// task's agent in the task's folder.
struct SkillListPopover: View {
    let agentLabel: String
    var oneAtATime: Bool = false
    let folderName: String?
    let choices: [SkillChoice]?
    let onDone: ([String]) -> Void
    let onClose: () -> Void

    @State private var ticked: [String]
    @Environment(\.sipFontScale) private var fontScale

    init(agentLabel: String, oneAtATime: Bool = false, folderName: String?, choices: [SkillChoice]?,
         picks: [String], onDone: @escaping ([String]) -> Void, onClose: @escaping () -> Void) {
        self.agentLabel = agentLabel
        self.oneAtATime = oneAtATime
        self.folderName = folderName
        self.choices = choices
        self.onDone = onDone
        self.onClose = onClose
        // An agent that takes one skill opens on one, whatever the file
        // listed: a hand-written task naming two showed both ticked under
        // "you can pick one at a time", and Done saved both.
        _ticked = State(initialValue: oneAtATime ? Array(picks.prefix(1)) : picks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkillPickerList(agentLabel: agentLabel, oneAtATime: oneAtATime, folderName: folderName,
                            choices: choices, ticked: $ticked)
            HStack(spacing: 8) {
                Spacer()
                Button(String(localized: "Cancel", comment: "Skill picker: close without changing the choice")) {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "Done", comment: "Skill picker: keep the ticked skills")) {
                    onDone(ticked)
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(SipFont.controlSize(fontScale))
        }
        .padding(8)
        .frame(width: 320 * SipFont.ratio(fontScale), alignment: .leading)
    }
}
