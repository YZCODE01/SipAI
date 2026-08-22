// AgentSessionGrouping.swift
// What an agent's sidebar section shows: which TIER it is in at all
// (`AgentSectionTier`), and how its list is bucketed once there is one
// — None / Folder / Date / State / Custom. Grouping state lives in this
// app's own config.json.
//
// Two things about the buckets worth knowing before changing them:
//
// * There is no pinned "Active" section — liveness is an inline dot on
//   the row itself — so a working session lands in a real state bucket
//   (Waiting for approval / Working / …) rather than being lifted out
//   of the list.
// * Folder headers show the immediate parent's name, not the full tilde
//   path; a sidebar has room for one folder name (see `detail` below).

import Foundation

// MARK: - Section tier

/// What an agent's sidebar section can DO right now, derived from three
/// facts the section already holds.
///
/// One value answers all three of the questions that used to be asked
/// separately — the header suffix, which body row renders, and whether
/// the grouping menu is offered — so they cannot contradict each other.
/// They did: the header appended "(read only)" whenever the agent was
/// not ready, directly above a body row saying the CLI is not installed.
/// On a machine with no Claude Code and no session store, that is a
/// section claiming to hold sessions it cannot drive while holding none
/// at all.
///
/// Read-only is a claim about ROWS: sessions that list, open and read
/// but cannot be sent to. An agent with nothing to list has nothing to
/// be read-only about, whatever its credentials are doing — so the
/// suffix is earned by rows, not by the absence of a binary.
enum AgentSectionTier {
    /// CLI installed and signed in: new sessions, sends, hand-offs.
    case interactive
    /// Rows to read, no way to drive them — the CLI is missing, or it
    /// is present without working auth. Sessions a desktop app wrote
    /// land here on a machine that never installed the CLI.
    case readOnly
    /// CLI present, auth missing, nothing synced yet. Nothing to read;
    /// what the user needs is the sign-in step.
    case notConfigured
    /// No CLI and no sessions. The section stays in the sidebar to say
    /// the agent is supported and what to install, and says nothing
    /// about reading.
    case unavailable

    /// `isReady` is installed AND signed in (`AgentManager.isAgentReady`);
    /// `hasRows` counts scheduled tasks as well as regular sessions,
    /// since a task's runs are rows too.
    ///
    /// Rows outrank the binary deliberately: an agent whose CLI lost its
    /// auth still lists everything it recorded, and that list is the
    /// point of the tier.
    static func resolve(isReady: Bool,
                        isInstalled: Bool,
                        hasRows: Bool) -> AgentSectionTier {
        if isReady { return .interactive }
        if hasRows { return .readOnly }
        return isInstalled ? .notConfigured : .unavailable
    }

    /// Whether the section header names the tier — only `.readOnly`
    /// does. The other two non-interactive tiers say more in one body
    /// sentence than a two-word suffix could, and a suffix promising
    /// readable sessions over a section that lists none is simply false.
    var namesTierInTitle: Bool { self == .readOnly }

    /// Grouping is a READ operation, so it is offered wherever there is
    /// something to group — and to an installed agent whose first
    /// session has not landed yet, so the choice is already made when
    /// one does.
    var offersGrouping: Bool { self != .unavailable }
}

// MARK: - Mode

/// How an agent's list is bucketed. Raw values are what
/// `agent_group_mode` persists; do not rename them.
enum AgentGroupMode: String, CaseIterable, Identifiable {
    case none
    case folder
    case date
    case state
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:
            return String(localized: "None",
                          comment: "Grouping mode — one flat list, newest first")
        case .folder:
            return String(localized: "Folder",
                          comment: "Grouping mode — by working directory")
        case .date:
            return String(localized: "Date",
                          comment: "Grouping mode — by last activity")
        case .state:
            return String(localized: "State",
                          comment: "Grouping mode — by what the session is doing")
        case .custom:
            return String(localized: "Custom",
                          comment: "Grouping mode — by user-named groups")
        }
    }
}

// MARK: - State buckets

/// What a row is doing, for `state` grouping. Ordered most-urgent first:
/// an approval is blocking the user, so it outranks a turn that is simply
/// still running.
enum AgentGroupState: String {
    case awaitingApproval
    case working
    case runningElsewhere
    case scheduled
    case idle

    var order: Int {
        switch self {
        case .awaitingApproval: return 0
        case .working: return 1
        case .runningElsewhere: return 2
        case .scheduled: return 3
        case .idle: return 4
        }
    }

    var groupLabel: String {
        switch self {
        case .awaitingApproval:
            return String(localized: "Waiting for approval",
                          comment: "State group — session has a pending MCP approval")
        case .working:
            return String(localized: "Working",
                          comment: "State group — session is mid-turn in SipAI")
        case .runningElsewhere:
            return String(localized: "Running in another terminal",
                          comment: "State group — an external Claude Code process owns the turn")
        case .scheduled:
            return String(localized: "Scheduled",
                          comment: "State group — scheduled task definitions")
        case .idle:
            return String(localized: "Sessions",
                          comment: "State group — everything not currently doing anything")
        }
    }
}

// MARK: - List items

/// One top-level row of the Claude Code list: a scheduled-task parent or
/// a regular session. The sidebar sorts these into a single chronological
/// stream and then hands them to `AgentSessionGrouping.buckets`.
enum AgentListItem: Identifiable, Hashable {
    case scheduled(ScheduledAgentTask)
    case regular(AgentSession)

    var id: String {
        switch self {
        case .scheduled(let task): return "scheduled:\(task.id)"
        case .regular(let session): return "session:\(session.id)"
        }
    }

    var title: String {
        switch self {
        case .scheduled(let task): return task.description
        case .regular(let session): return session.title
        }
    }

    /// When this row's owner last SPOKE to it — the last user message
    /// for a session, the last prompt a schedule fired for a task —
    /// or nil for a scheduled task that has never run. Date grouping
    /// keeps nil in its own bucket rather than filing a never-run task
    /// under some arbitrary month.
    ///
    /// Deliberately not the file's mtime: this value is both printed
    /// on the row and used to order it, and mtime keeps moving for as
    /// long as the agent works, so a session left running pinned
    /// itself to the top of its group for the length of the turn.
    var activityDate: Date? {
        switch self {
        case .scheduled(let task): return task.lastActive
        case .regular(let session): return session.activityAt
        }
    }

    /// Sort key. Never-run tasks sink to the bottom of the stream.
    var sortDate: Date { activityDate ?? .distantPast }

    var isSpawnedSubagent: Bool {
        switch self {
        case .scheduled: return false
        case .regular(let session): return session.origin == .subagent
        }
    }

    /// Directory this row belongs to. A scheduled task uses the `cwd:`
    /// from its SKILL.md, falling back to where its newest run actually
    /// ran — a task whose frontmatter omits cwd would otherwise land in
    /// "No directory" even though every one of its runs has a folder.
    var folderURL: URL? {
        switch self {
        case .scheduled(let task):
            return task.workingDirectory ?? task.sessions.first?.projectPath
        case .regular(let session):
            return session.projectPath
        }
    }

    /// Key a custom-group assignment is stored under: sessions key off
    /// their id (so a renamed session keeps its group), scheduled tasks
    /// off their name behind a `sched:` prefix that keeps the two id
    /// spaces apart.
    var groupItemKey: String {
        switch self {
        case .scheduled(let task): return "sched:\(task.name)"
        case .regular(let session): return session.id
        }
    }
}

// MARK: - Groups

/// One rendered group: a header plus the rows under it.
struct AgentSessionGroup: Identifiable {
    /// Stable identity, and what collapsed state is written against.
    /// Never empty except in `.none` mode, which draws no header.
    let key: String
    let label: String
    /// Dim trailing text on the header — in folder mode the *immediate*
    /// parent's name, so two folders called `work` stay distinguishable.
    /// Only the parent name, not the whole path: a sidebar header has room
    /// for one folder name, and head-truncating a full path there reads as
    /// broken ("…ktop/Some Project Name"). The full tilde path is one
    /// hover away, in `tooltip`.
    let detail: String
    /// Full tilde path behind the header, surfaced as a tooltip.
    let tooltip: String
    let items: [AgentListItem]

    var id: String { key }
}

enum AgentSessionGrouping {

    /// Keys that cannot collide with a user's group name or a real path.
    /// Non-empty on purpose: collapsed state is a list of keys, and "" is
    /// indistinguishable from "no key", which would leave these two the
    /// only headers that cannot fold.
    static let ungroupedKey = "\u{0}ungrouped"
    static let noDirectoryKey = "\u{0}nodir"

    /// Bucket `items` (already sorted — insertion order is preserved
    /// inside each group) into display groups.
    ///
    /// Folder and date groups are ordered by their most recent row;
    /// custom groups follow the order the user created them in with
    /// Ungrouped last; state groups use `AgentGroupState.order`. Empty
    /// groups are dropped in every mode — deleting a group's last
    /// session removes its header too. (Custom groups stay in config;
    /// they just don't render while empty.)
    static func buckets(_ items: [AgentListItem],
                        mode: AgentGroupMode,
                        state: (AgentListItem) -> AgentGroupState = { _ in .idle },
                        customGroups: [String] = [],
                        assignments: [String: String] = [:],
                        now: Date = Date()) -> [AgentSessionGroup] {
        struct Bucket {
            let label: String
            let detail: String
            let tooltip: String
            var items: [AgentListItem]
        }
        var buckets: [String: Bucket] = [:]
        var keyOrder: [String] = []
        var fixedOrder: [String: Int] = [:]

        func bucket(_ key: String,
                    _ label: String,
                    detail: String = "",
                    tooltip: String = "",
                    add item: AgentListItem?) {
            if buckets[key] == nil {
                buckets[key] = Bucket(label: label, detail: detail,
                                      tooltip: tooltip, items: [])
                keyOrder.append(key)
            }
            if let item = item {
                buckets[key]?.items.append(item)
            }
        }

        if mode == .custom {
            for (index, name) in customGroups.enumerated() {
                fixedOrder[name] = index
                bucket(name, name, add: nil)
            }
            fixedOrder[ungroupedKey] = customGroups.count
        }

        for item in items {
            switch mode {
            case .none:
                bucket("", "", add: item)
            case .folder:
                if let url = item.folderURL {
                    let path = url.standardizedFileURL.path
                    let name = url.standardizedFileURL.lastPathComponent
                    bucket(path,
                           name.isEmpty ? path : name,
                           detail: parentName(url),
                           tooltip: parentLabel(url),
                           add: item)
                } else {
                    bucket(noDirectoryKey,
                           String(localized: "No directory",
                                  comment: "Folder group for rows with no known directory"),
                           add: item)
                }
            case .date:
                let bucketed = dateBucket(for: item.activityDate, now: now)
                bucket(bucketed.key, bucketed.label, add: item)
            case .state:
                let rowState = state(item)
                fixedOrder[rowState.rawValue] = rowState.order
                bucket(rowState.rawValue, rowState.groupLabel, add: item)
            case .custom:
                let assigned = assignments[item.groupItemKey]
                if let name = assigned, customGroups.contains(name) {
                    bucket(name, name, add: item)
                } else {
                    // An assignment naming a group that no longer exists
                    // (hand-edited config) reads as unfiled rather than
                    // conjuring a group back into being.
                    bucket(ungroupedKey,
                           String(localized: "Ungrouped",
                                  comment: "Custom-group bucket for rows the user has not filed"),
                           add: item)
                }
            }
        }

        func newest(_ key: String) -> Date? {
            buckets[key]?.items.compactMap(\.activityDate).max()
        }

        let ordered = keyOrder.sorted { lhs, rhs in
            let lhsOrder = fixedOrder[lhs] ?? Int.max
            let rhsOrder = fixedOrder[rhs] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            switch (newest(lhs), newest(rhs)) {
            case let (left?, right?):
                if left != right { return left > right }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        return ordered.compactMap { key in
            guard let found = buckets[key], !found.items.isEmpty else { return nil }
            let ranked = found.items.filter { !$0.isSpawnedSubagent }
                + found.items.filter(\.isSpawnedSubagent)
            return AgentSessionGroup(key: key,
                                     label: found.label,
                                     detail: found.detail,
                                     tooltip: found.tooltip,
                                     items: ranked)
        }
    }

    // MARK: - Labels

    /// Full tilde-shortened parent directory — the header's tooltip.
    static func parentLabel(_ url: URL) -> String {
        let parent = url.standardizedFileURL.deletingLastPathComponent().path
        guard !parent.isEmpty, parent != "/" else { return parent }
        return (parent as NSString).abbreviatingWithTildeInPath
    }

    /// The immediate parent's name, which is what a sidebar header has room
    /// for. "~" when the folder sits directly in the home directory, rather
    /// than the account's short name.
    static func parentName(_ url: URL) -> String {
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        let path = parent.path
        guard !path.isEmpty, path != "/" else { return path }
        if path == FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.path {
            return "~"
        }
        let name = parent.lastPathComponent
        return name.isEmpty ? path : name
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    /// Today / Yesterday / Previous 7 days / Previous 30 days / month.
    /// A future timestamp (clock skew) reads as today rather than
    /// "-1 days".
    static func dateBucket(for date: Date?, now: Date) -> (key: String, label: String) {
        guard let date = date else {
            return ("undated",
                    String(localized: "No activity yet",
                           comment: "Date group for scheduled tasks that have never run"))
        }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 {
            return ("today", String(localized: "Today", comment: "Date group"))
        }
        if days == 1 {
            return ("yesterday", String(localized: "Yesterday", comment: "Date group"))
        }
        if days < 7 {
            return ("prev7",
                    String(localized: "Previous 7 days", comment: "Date group"))
        }
        if days < 30 {
            return ("prev30",
                    String(localized: "Previous 30 days", comment: "Date group"))
        }
        let parts = calendar.dateComponents([.year, .month], from: date)
        let key = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        return (key, monthFormatter.string(from: date))
    }
}
