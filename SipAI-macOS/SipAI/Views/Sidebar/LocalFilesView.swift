// LocalFilesView.swift
// Disclosure view for the user's dedicated folder + chats/ + notes/
// subfolders. Collapsed it shows the folder names; expanding lists the
// files inside.

import SwiftUI

struct LocalFilesView: View {
    @EnvironmentObject var config: ConfigManager
    @Binding var expanded: Bool
    @State private var chatsExpanded: Bool = false
    @State private var notesExpanded: Bool = false

    private var folderURL: URL? {
        guard let p = config.dedicatedFolder else { return nil }
        return URL(fileURLWithPath: p)
    }

    var body: some View {
        guard let folder = folderURL else { return AnyView(EmptyView()) }
        let chatsFolder = Self.resolveSubfolder(in: folder, literalName: "chats",
                                                marker: SipaiPaths.markerChats)
        let notesFolder = Self.resolveSubfolder(in: folder, literalName: "notes",
                                                marker: SipaiPaths.markerNotes)
        return AnyView(
            VStack(alignment: .leading, spacing: 2) {
                DisclosureSection(title: folder.lastPathComponent, isExpanded: $expanded) {
                    if let chatsURL = chatsFolder {
                        SubFolderView(folder: chatsURL, expanded: $chatsExpanded)
                            .padding(.leading, 8)
                    }
                    if let notesURL = notesFolder {
                        SubFolderView(folder: notesURL, expanded: $notesExpanded)
                            .padding(.leading, 8)
                    }
                }
            }
        )
    }

    /// Locate a dedicated-folder subfolder, surviving Finder renames.
    /// Marker first: a subfolder may carry a hidden `.sipai_chats` /
    /// `.sipai_notes` file, so scan the dedicated folder's immediate
    /// subdirectories for one containing the marker; fall back to the
    /// literal name.
    private static func resolveSubfolder(in parent: URL, literalName: String,
                                         marker: String) -> URL? {
        let fm = FileManager.default
        if let children = try? fm.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey]) {
            for child in children {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: child.path, isDirectory: &isDir),
                      isDir.boolValue,
                      fm.fileExists(atPath: child.appendingPathComponent(marker).path)
                else { continue }
                return child
            }
        }
        let literal = parent.appendingPathComponent(literalName, isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: literal.path, isDirectory: &isDir), isDir.boolValue {
            return literal
        }
        return nil
    }
}

struct SubFolderView: View {
    /// The resolved folder to list — already recovered from a possible
    /// Finder rename by `LocalFilesView.resolveSubfolder`.
    let folder: URL
    @Binding var expanded: Bool
    @Environment(\.sipFontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(folder.lastPathComponent)
                        .font(.system(size: SipFont.sidebarRow(fontScale)))
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sidebarRowBackground()

            if expanded {
                ForEach(filesInside(), id: \.self) { url in
                    LocalFileRow(url: url)
                }
            }
        }
    }

    private func filesInside() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// One file inside a Local Files subfolder. Extracted so each row can hold
/// its own `@State private var hovered` for the shared sidebar hover style.
struct LocalFileRow: View {
    let url: URL
    @State private var hovered: Bool = false
    @Environment(\.sipFontScale) private var fontScale

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.system(size: SipFont.sidebarRow(fontScale)))
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, 16)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovered ? Color.gray.opacity(0.2) : Color.clear)
        )
        .onHover { hovering in hovered = hovering }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
    }
}
