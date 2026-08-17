// ProjectManager.swift
// Reads/writes meta.json under the Mac app's data directory.
// Schema: { "projects": { slug: name } }.

import Foundation

struct ProjectInfo: Identifiable, Hashable {
    var slug: String
    var name: String
    var id: String { slug }
}

@MainActor
final class ProjectManager: ObservableObject {
    @Published private(set) var projects: [ProjectInfo] = []

    func reload() {
        guard let data = try? Data(contentsOf: SipaiPaths.metaFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dict = obj["projects"] as? [String: String] else {
            projects = []; return
        }
        projects = dict.map { ProjectInfo(slug: $0.key, name: $0.value) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func save(_ dict: [String: String]) {
        SipaiPaths.ensureDataDir()
        let payload: [String: Any] = ["projects": dict]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: SipaiPaths.metaFile, options: .atomic)
        }
        reload()
    }

    private func currentDict() -> [String: String] {
        Dictionary(uniqueKeysWithValues: projects.map { ($0.slug, $0.name) })
    }

    /// Directory names under dataDir that belong to the app itself,
    /// never to a project. A project slugged "notes" would point at the
    /// notes store — deleting it would erase every user note — and
    /// "mcp" holds the live approver socket.
    private static let reservedSlugs: Set<String> = ["notes", "mcp"]

    @discardableResult
    func createProject(name: String) -> ProjectInfo {
        var dict = currentDict()
        var slug = SipaiPaths.slugify(name)
        let base = slug
        var c = 2
        while dict[slug] != nil || Self.reservedSlugs.contains(slug) {
            slug = "\(base)-\(c)"; c += 1
        }
        dict[slug] = name
        save(dict)
        try? FileManager.default.createDirectory(
            at: SipaiPaths.dataDir.appendingPathComponent(slug, isDirectory: true),
            withIntermediateDirectories: true)
        return ProjectInfo(slug: slug, name: name)
    }

    func renameProject(slug: String, newName: String) {
        var dict = currentDict()
        dict[slug] = newName
        save(dict)
    }

    func deleteProject(slug: String) {
        var dict = currentDict()
        dict.removeValue(forKey: slug)
        save(dict)
        // Never delete the app's own directories, even if a legacy
        // meta.json somehow carries a reserved slug.
        guard !Self.reservedSlugs.contains(slug) else { return }
        let dir = SipaiPaths.dataDir.appendingPathComponent(slug, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    func name(for slug: String?) -> String? {
        guard let s = slug else { return nil }
        return projects.first(where: { $0.slug == s })?.name
    }
}
