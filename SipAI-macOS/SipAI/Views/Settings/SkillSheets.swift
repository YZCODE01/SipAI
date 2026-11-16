// SkillSheets.swift
// Settings → Agent Skills' sheets and popovers: a new or edited skill, adding
// one from a folder or an archive, and the detail a skill's name opens.

import SwiftUI
import AppKit

// MARK: - Requests

enum SkillEditorRequest: Identifiable {
    case new
    case edit(SkillRow)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let row): return "edit:" + row.id
        }
    }
}

struct SkillImportRequest: Identifiable {
    /// A folder holding SKILL.md.
    let source: URL
    /// A scratch folder an archive was unpacked into, removed when the
    /// sheet closes.
    let cleanUp: URL?
    /// What to suggest calling it when its SKILL.md gives no name and
    /// its folder's is not one to go by.
    var fallbackName: String? = nil
    var id: String { source.path }
}

// MARK: - New / edit

struct SkillEditorSheet: View {
    let request: SkillEditorRequest
    /// The listed agents and their labels, in column order.
    let agentLabels: [(String, String)]
    let folder: URL?
    /// What "only this folder" is called: the folder a folder skill is
    /// saved for (`SkillsPane.scopeName`).
    let scopeName: String?
    /// Whether "only this folder" is a choice here (`SkillsPane
    /// .offersFolderScope`).
    let offersFolderScope: Bool
    /// Called once the sheet is done: a sentence when the pane should
    /// say something went wrong after the sheet closed, else nil.
    let onFinish: (String?) -> Void

    @EnvironmentObject var config: ConfigManager
    @ObservedObject private var catalog = SkillCatalog.shared
    @Environment(\.sipFontScale) private var fontScale

    @State private var name = ""
    @State private var summary = ""
    @State private var instructions = ""
    @State private var onlyWhenCalled = false
    /// The box as the sheet opened on it. It shows "SKILL.md says so OR
    /// Codex's file says so", so only a box the user CHANGED is written:
    /// saved as found, it copied the one file's word into the other.
    @State private var onlyWhenCalledAtOpen = false
    @State private var scope: SkillScope = .global
    @State private var useWith: Set<String> = []
    /// The file as read when the sheet opened — an edit is refused if it
    /// has changed since.
    @State private var expected: String? = nil
    @State private var saving = false
    @State private var error: String? = nil
    @State private var loaded = false

    private var editing: SkillRow? {
        if case .edit(let row) = request { return row }
        return nil
    }

    private var nameProblem: String? {
        guard editing == nil else { return nil }
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return nil }
        if !SkillName.isValid(n) {
            return String(localized: "Use lowercase letters, digits and single hyphens, up to 64 characters.",
                          comment: "Skills: the name rule, shown under the name field")
        }
        if SkillNameCheck.isTaken(n, scope: scope, agents: useWith, in: catalog.snapshot(folder: folder)?.rows ?? []) {
            return String(localized: "A skill with this name is already here.",
                          comment: "Skills: the name is taken")
        }
        return nil
    }

    private var canSave: Bool {
        guard !saving, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if editing != nil { return expected != nil }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty && nameProblem == nil && !useWith.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: editing.map { String(localized: "Edit “\($0.name)”",
                                                comment: "Skills: edit sheet title; placeholder is the skill name") }
                 ?? String(localized: "New Skill", comment: "Skills: new skill sheet title"))
                .sipFont(15, weight: .semibold)

            if editing == nil {
                field(String(localized: "Name", comment: "Skills: name field label")) {
                    TextField(String(localized: "review-pr", comment: "Skills: example skill name placeholder"),
                              text: $name)
                        .textFieldStyle(.roundedBorder)
                        .sipFont(13)
                    if let nameProblem {
                        Text(verbatim: nameProblem)
                            .sipFont(11)
                            .foregroundColor(.orange)
                    } else if !name.isEmpty {
                        Text(verbatim: callLine(name.trimmingCharacters(in: .whitespaces)))
                            .sipFont(11)
                            .foregroundColor(SipDesign.textSecondary)
                    }
                }
            }

            field(String(localized: "Description", comment: "Skills: description field label")) {
                TextField(String(localized: "What it does, and when to use it",
                                 comment: "Skills: description placeholder"),
                          text: $summary, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .sipFont(13)
                Text("The agent reads this to decide when the skill applies.",
                     comment: "Skills: why the description matters")
                    .sipFont(11)
                    .foregroundColor(SipDesign.textSecondary)
            }

            field(String(localized: "Instructions", comment: "Skills: body field label")) {
                NoteSourceEditor(text: $instructions,
                                 onEscape: { if !saving { onFinish(nil) } },
                                 spellChecking: config.display.spellCheck,
                                 fontSize: SipFont.scaled(13, fontScale))
                    .frame(height: 220 * SipFont.ratio(fontScale))
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .stroke(SipDesign.borderLight, lineWidth: 1))
            }

            if editing == nil {
                field(String(localized: "Use with", comment: "Skills: which agents get the new skill")) {
                    HStack(spacing: 14) {
                        ForEach(agentLabels, id: \.0) { agent, label in
                            Toggle(label, isOn: Binding(
                                get: { useWith.contains(agent) },
                                set: { if $0 { useWith.insert(agent) } else { useWith.remove(agent) } }))
                                .toggleStyle(.checkbox)
                                .sipFont(13)
                        }
                    }
                }
                if let folder, offersFolderScope {
                    Picker(String(localized: "Where", comment: "Skills: global or folder skill"),
                           selection: $scope) {
                        Text("Every folder", comment: "Skills scope: global").tag(SkillScope.global)
                        Text(verbatim: String(localized: "Only \(scopeName ?? folder.lastPathComponent)",
                                              comment: "Skills scope: the chosen folder; placeholder is its name"))
                            .tag(SkillScope.folder)
                    }
                    .pickerStyle(.segmented)
                    .sipFont(13)
                }
            }

            Toggle(String(localized: "Only when I call it", comment: "Skills: the model never uses it on its own"),
                   isOn: $onlyWhenCalled)
                .toggleStyle(.checkbox)
                .sipFont(13)
            Text("The agent never uses it on its own; you start it by name.",
                 comment: "Skills: what only-when-called means")
                .sipFont(11)
                .foregroundColor(SipDesign.textSecondary)

            // A skill several agents use is ONE set of files: saving it
            // changes it for every one of them, and the user is told so
            // before the Save.
            if let sharedWith = sharedLine {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle")
                        .sipFont(11)
                        .foregroundColor(SipDesign.textSecondary)
                    Text(verbatim: sharedWith)
                        .sipFont(12)
                        .foregroundColor(SipDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let error {
                Text(verbatim: error)
                    .sipFont(12)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                // Not while the write is under way: closed then, the
                // sheet took the write's answer with it — a refusal was
                // said to nobody.
                Button(String(localized: "Cancel", comment: "Skills: close the sheet")) { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button(editing == nil
                       ? String(localized: "Create", comment: "Skills: create the new skill")
                       : String(localized: "Save", comment: "Skills: save the edited skill")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 560 * SipFont.ratio(fontScale))
        .controlSize(SipFont.controlSize(fontScale))
        .onAppear(perform: load)
    }

    /// The line an edit of a skill several listed agents use carries:
    /// their files are one, so a save is theirs too. Nil for a new skill
    /// and for one only one agent has.
    private var sharedLine: String? {
        guard let row = editing else { return nil }
        let users = agentLabels.filter { row.entries[$0.0] != nil }.map(\.1)
        guard users.count > 1 else { return nil }
        return String(localized: "\(ListFormatter.localizedString(byJoining: users)) use this skill. Saving changes it for each of them.",
                      comment: "Skills: edit sheet note for a skill two or more agents use; placeholder lists the agents")
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .sipFont(12, weight: .medium)
                .foregroundColor(SipDesign.textSecondary)
            content()
        }
    }

    /// How each ticked agent's user will call it.
    private func callLine(_ name: String) -> String {
        let calls = agentLabels.filter { useWith.contains($0.0) }
            .map { "\($0.1): \(SkillAgent.invocation(of: name, agent: $0.0))" }
        return calls.joined(separator: "   ")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let row = editing {
            summary = row.description
            instructions = row.frontmatter.body.trimmingCharacters(in: .newlines)
            onlyWhenCalled = row.frontmatter.disableModelInvocation
                || row.entries.values.contains { $0.codexImplicitOff }
            if let real = row.realPath {
                // The reader the save compares with: it keeps a
                // byte-order mark that Foundation's own read drops.
                expected = SkillFileOps.readText((real as NSString).appendingPathComponent("SKILL.md"))
                if let text = expected {
                    // The form shows what THIS read holds, never the row
                    // the pane last scanned: the save is checked against
                    // this text, so a form filled from an older scan (or
                    // from the scan's bounded read of a long file) would
                    // pass that check and write its older words over
                    // whatever the file gained since.
                    let now = SkillFrontmatter.parse(text)
                    summary = now.description
                    instructions = now.body.trimmingCharacters(in: .newlines)
                    let policy = try? String(
                        contentsOfFile: (real as NSString).appendingPathComponent(SkillCodexPolicy.relativePath),
                        encoding: .utf8)
                    onlyWhenCalled = now.disableModelInvocation
                        || !SkillCodexPolicy.allowsImplicitInvocation(yaml: policy)
                } else {
                    error = SkillCatalog.describe(.notASkill(real))
                }
            }
            onlyWhenCalledAtOpen = onlyWhenCalled
        } else {
            useWith = Set(agentLabels.map(\.0))
        }
    }

    private func save() {
        saving = true
        error = nil
        let description = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = instructions
        Task {
            let failure: String?
            if let row = editing, let expected {
                failure = await catalog.edit(row: row, expected: expected, description: description, body: body,
                                             onlyWhenCalled: onlyWhenCalled == onlyWhenCalledAtOpen ? nil : onlyWhenCalled,
                                             folder: folder)
            } else {
                let agents = agentLabels.map(\.0).filter { useWith.contains($0) }
                failure = await catalog.create(name: name.trimmingCharacters(in: .whitespaces),
                                               description: description, body: body,
                                               onlyWhenCalled: onlyWhenCalled,
                                               scope: offersFolderScope ? scope : .global,
                                               agents: agents, folder: folder)
            }
            saving = false
            if let failure {
                error = failure
            } else {
                onFinish(nil)
            }
        }
    }
}

// MARK: - Add from a folder or an archive

struct SkillImportSheet: View {
    let request: SkillImportRequest
    let agentLabels: [(String, String)]
    let folder: URL?
    let scopeName: String?
    let offersFolderScope: Bool
    let onFinish: (String?) -> Void

    @ObservedObject private var catalog = SkillCatalog.shared
    @Environment(\.sipFontScale) private var fontScale

    @State private var name = ""
    @State private var summary = ""
    @State private var scripts = 0
    @State private var scope: SkillScope = .global
    @State private var useWith: Set<String> = []
    @State private var saving = false
    @State private var error: String? = nil
    @State private var loaded = false

    private var nameProblem: String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        if !SkillName.isValid(n) {
            return String(localized: "Use lowercase letters, digits and single hyphens, up to 64 characters.",
                          comment: "Skills: the name rule, shown under the name field")
        }
        if SkillNameCheck.isTaken(n, scope: scope, agents: useWith, in: catalog.snapshot(folder: folder)?.rows ?? []) {
            return String(localized: "A skill with this name is already here.",
                          comment: "Skills: the name is taken")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Skill", comment: "Skills: import sheet title")
                .sipFont(15, weight: .semibold)
            Text(verbatim: (request.source.path as NSString).abbreviatingWithTildeInPath)
                .sipFont(11)
                .foregroundColor(SipDesign.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name", comment: "Skills: name field label")
                    .sipFont(12, weight: .medium)
                    .foregroundColor(SipDesign.textSecondary)
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .sipFont(13)
                    .accessibilityLabel(Text("Name", comment: "Skills: name field label"))
                if let nameProblem {
                    Text(verbatim: nameProblem).sipFont(11).foregroundColor(.orange)
                }
            }
            if !summary.isEmpty {
                Text(verbatim: summary)
                    .sipFont(12)
                    .foregroundColor(SipDesign.textPrimary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.shield")
                    .sipFont(12)
                    .foregroundColor(.orange)
                Text(verbatim: scripts > 1
                     ? String(localized: "It contains \(scripts) scripts an agent can run. Only add skills from sources you trust.",
                              comment: "Skills: import warning with scripts; placeholder is how many")
                     : scripts == 1
                     ? String(localized: "It contains a script an agent can run. Only add skills from sources you trust.",
                              comment: "Skills: import warning with one script")
                     : String(localized: "A skill tells an agent what to do. Only add skills from sources you trust.",
                              comment: "Skills: import warning without scripts"))
                    .sipFont(12)
                    .foregroundColor(SipDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Use with", comment: "Skills: which agents get the new skill")
                    .sipFont(12, weight: .medium)
                    .foregroundColor(SipDesign.textSecondary)
                HStack(spacing: 14) {
                    ForEach(agentLabels, id: \.0) { agent, label in
                        Toggle(label, isOn: Binding(
                            get: { useWith.contains(agent) },
                            set: { if $0 { useWith.insert(agent) } else { useWith.remove(agent) } }))
                            .toggleStyle(.checkbox)
                            .sipFont(13)
                    }
                }
            }
            if let folder, offersFolderScope {
                Picker(String(localized: "Where", comment: "Skills: global or folder skill"),
                       selection: $scope) {
                    Text("Every folder", comment: "Skills scope: global").tag(SkillScope.global)
                    Text(verbatim: String(localized: "Only \(scopeName ?? folder.lastPathComponent)",
                                          comment: "Skills scope: the chosen folder; placeholder is its name"))
                        .tag(SkillScope.folder)
                }
                .pickerStyle(.segmented)
                .sipFont(13)
            }

            if let error {
                Text(verbatim: error).sipFont(12).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                // Not while the copy is under way: closing removes the
                // folder an archive was unpacked into, from under it.
                Button(String(localized: "Cancel", comment: "Skills: close the sheet")) { close(nil) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button(String(localized: "Add", comment: "Skills: add the skill")) { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || name.isEmpty || nameProblem != nil || useWith.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480 * SipFont.ratio(fontScale))
        .controlSize(SipFont.controlSize(fontScale))
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        useWith = Set(agentLabels.map(\.0))
        let file = request.source.appendingPathComponent("SKILL.md")
        let text = SkillFileOps.readText(file.path) ?? ""
        let fm = SkillFrontmatter.parse(text)
        summary = fm.description
        name = SkillName.suggestion(fm.name ?? request.fallbackName ?? request.source.lastPathComponent)
        scripts = SkillFileOps.scriptCount(in: request.source)
    }

    private func add() {
        saving = true
        error = nil
        let agents = agentLabels.map(\.0).filter { useWith.contains($0) }
        Task {
            let failure = await catalog.importFolder(request.source,
                                                     name: name.trimmingCharacters(in: .whitespaces),
                                                     scope: offersFolderScope ? scope : .global,
                                                     agents: agents, folder: folder)
            saving = false
            if let failure { error = failure } else { close(nil) }
        }
    }

    private func close(_ message: String?) {
        if let scratch = request.cleanUp { try? FileManager.default.removeItem(at: scratch) }
        onFinish(message)
    }
}

// MARK: - Unpacking an archive

enum SkillArchive {
    struct Unpacked {
        /// The folder holding SKILL.md.
        let skill: URL
        /// The scratch folder it sits in, to remove afterwards.
        let scratch: URL
    }

    enum Outcome {
        case success(Unpacked)
        case failure(String)
    }

    /// The most an archive may unpack to.
    static let maxUnpackedBytes: Int64 = 200 * 1024 * 1024

    /// Unpack a .zip or .skill into a scratch folder and find the skill
    /// in it — at the top, or in its one folder. Refused before anything
    /// is written: an archive that would unpack past `maxUnpackedBytes`,
    /// or whose entries name a path outside the folder.
    static func unpack(_ archive: URL) async -> Outcome {
        await Task.detached(priority: .userInitiated) { () -> Outcome in
            guard let listing = run("/usr/bin/unzip", ["-Z", "-t", archive.path]),
                  let total = unpackedBytes(fromTotals: listing) else {
                return .failure(String(localized: "That file isn’t a zip archive SipAI can read.",
                                       comment: "Skills: an archive that could not be listed"))
            }
            guard total <= maxUnpackedBytes else {
                return .failure(String(localized: "That archive unpacks to more than 200 MB, which is too large for a skill.",
                                       comment: "Skills: an archive refused for its unpacked size"))
            }
            let names = (run("/usr/bin/unzip", ["-Z1", archive.path]) ?? "")
                .split(separator: "\n").map(String.init)
            guard !names.contains(where: { $0.hasPrefix("/") || $0.split(separator: "/").contains("..") }) else {
                return .failure(String(localized: "That archive names files outside its own folder, so SipAI didn’t open it.",
                                       comment: "Skills: an archive refused for path traversal"))
            }
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("sipai-skill-\(UUID().uuidString)", isDirectory: true)
            do { try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true) }
            catch { return .failure(error.localizedDescription) }
            guard run("/usr/bin/ditto", ["-x", "-k", archive.path, scratch.path]) != nil else {
                try? FileManager.default.removeItem(at: scratch)
                return .failure(String(localized: "That archive couldn’t be unpacked.",
                                       comment: "Skills: unpacking an archive failed"))
            }
            // The listing's total is the archive's own word for its size;
            // what landed is measured, so one that understated itself
            // never reaches the library.
            guard unpackedSize(of: scratch) <= maxUnpackedBytes else {
                try? FileManager.default.removeItem(at: scratch)
                return .failure(String(localized: "That archive unpacks to more than 200 MB, which is too large for a skill.",
                                       comment: "Skills: an archive refused for its unpacked size"))
            }
            // An entry's NAME was checked above; a link's TARGET is not in
            // the listing. A `SKILL.md` that is a link to a file anywhere
            // on the Mac would be read by an agent as the skill.
            guard SkillFileOps.linksLeaving(scratch).isEmpty else {
                try? FileManager.default.removeItem(at: scratch)
                return .failure(String(localized: "That archive names files outside its own folder, so SipAI didn’t open it.",
                                       comment: "Skills: an archive refused for path traversal"))
            }
            if let skill = findSkill(in: scratch) {
                return .success(Unpacked(skill: skill, scratch: scratch))
            }
            try? FileManager.default.removeItem(at: scratch)
            return .failure(String(localized: "There is no SKILL.md in that archive.",
                                   comment: "Skills: an archive without a skill"))
        }.value
    }

    /// `unzip -Z -t`'s last line: "N files, X bytes uncompressed, …".
    static func unpackedBytes(fromTotals text: String) -> Int64? {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" })
        for (i, w) in words.enumerated() where w == "bytes" && i > 0 {
            if i + 1 < words.count, words[i + 1] == "uncompressed" {
                return Int64(words[i - 1])
            }
        }
        return nil
    }

    /// The bytes a folder's files hold, links not followed.
    static func unpackedSize(of folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func findSkill(in scratch: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: scratch.appendingPathComponent("SKILL.md").path) { return scratch }
        let children = ((try? fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        guard children.count == 1, let only = children.first,
              fm.fileExists(atPath: only.appendingPathComponent("SKILL.md").path) else { return nil }
        return only
    }

    /// A tool's stdout, or nil when it failed.
    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Detail

/// What a skill's name opens: where its files are, which agents have it
/// and how each calls it, and what in it only some agents understand.
struct SkillDetailView: View {
    let row: SkillRow
    /// The agents the page lists. One that is not listed is not spoken
    /// for: its line, and "doesn't load it", were drawn for a Kimi Code
    /// that is not installed.
    let agents: [String]
    let label: (String) -> String
    @Environment(\.sipFontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: row.name)
                .sipFont(14, weight: .semibold)
            if !row.description.isEmpty {
                Text(verbatim: row.description)
                    .sipFont(12)
                    .foregroundColor(SipDesign.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let real = row.realPath {
                detailLine(String(localized: "Files", comment: "Skills detail: where the real folder is"),
                           (real as NSString).abbreviatingWithTildeInPath)
            }
            ForEach(agents, id: \.self) { agent in
                if let entry = row.entries[agent] {
                    detailLine(label(agent), agentLine(entry, agent: agent))
                }
            }
            ForEach(featureLines, id: \.self) { line in
                Text(verbatim: line)
                    .sipFont(11)
                    .foregroundColor(SipDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(problemLines, id: \.self) { line in
                Text(verbatim: line)
                    .sipFont(11)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 400 * SipFont.ratio(fontScale), alignment: .leading)
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: title)
                .sipFont(11, weight: .semibold)
                .foregroundColor(SipDesign.textSecondary)
            Text(verbatim: value)
                .sipFont(12)
                .foregroundColor(SipDesign.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func agentLine(_ entry: SkillEntry, agent: String) -> String {
        let call = String(localized: "Call it with \(SkillAgent.invocation(of: entry.name, agent: agent))",
                          comment: "Skills detail: how an agent's user calls a skill; placeholder is the command")
        let place: String
        if entry.isLink {
            place = String(localized: "Linked at \((entry.entryPath as NSString).abbreviatingWithTildeInPath)",
                           comment: "Skills detail: an agent has the skill through a link; placeholder is a path")
        } else if entry.entryPath.isEmpty {
            place = String(localized: "Managed by the agent",
                           comment: "Skills detail: a skill an agent reported with no folder")
        } else {
            place = String(localized: "In \((entry.entryPath as NSString).abbreviatingWithTildeInPath)",
                           comment: "Skills detail: an agent holds the skill's folder itself; placeholder is a path")
        }
        // How to call it, where it can be called: not a link to nothing,
        // a skill the agent skips, or one only the model may use.
        let callable = !row.problems.contains(.brokenLink) && row.notLoaded(by: agent) == nil
            && !(agent == SkillAgent.claude && !entry.frontmatter.userInvocable)
        return callable ? place + " · " + call : place
    }

    private var featureLines: [String] {
        var out: [String] = []
        if let tools = row.frontmatter.allowedTools, !tools.isEmpty {
            out.append(String(localized: "Lets \(label(SkillAgent.claude)) use \(tools) without asking while it runs. Other agents ignore this.",
                              comment: "Skills detail: allowed-tools; placeholders are the agent label and the tool list"))
        }
        if row.frontmatter.runsForked {
            out.append(String(localized: "Runs as its own task in \(label(SkillAgent.claude)), so it can’t be preloaded — type its command instead.",
                              comment: "Skills detail: context fork; placeholder is the agent label"))
        }
        if !row.frontmatter.userInvocable {
            out.append(String(localized: "\(label(SkillAgent.claude)) offers it to the model only; you can’t call it by name there.",
                              comment: "Skills detail: user-invocable false; placeholder is the agent label"))
        }
        return out
    }

    private var problemLines: [String] {
        var out: [String] = []
        if row.problems.contains(.clash) {
            out.append(String(localized: "Another skill with this name reaches the same agent, which uses only one of them. Rename or delete one.",
                              comment: "Skills detail: a name clash"))
        }
        if row.problems.contains(.brokenLink) {
            out.append(String(localized: "Its link points at a folder that is gone. Delete it to clean up.",
                              comment: "Skills detail: a broken link"))
        }
        for agent in agents {
            if let why = row.notLoaded(by: agent) {
                out.append(SkillFormat.notLoadedSentence(label(agent), why))
            }
        }
        return out
    }
}
